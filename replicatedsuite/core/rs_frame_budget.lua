------------------------------------------------------------------------
-- Replicated Suite - Frame Budget Broker
--
-- Central soft-budget policy for Suite-owned periodic work.
--
-- The broker does NOT replace Domain runtimes and does NOT own an OnUpdate.
-- In v1 the Suite scheduler is the active budget execution Authority. The
-- broker API is intentionally reusable by professional runtimes, but those
-- independent native OnUpdate hosts are migrated incrementally rather than
-- being force-wired here. Critical/user-action work (P0/P1)
-- is never dropped. Lower-priority work may be deferred, with bounded
-- starvation protection so background maintenance cannot remain stuck.
--
-- Hot-path rules:
--   * no diagnostic log writes per Request(); only bounded counters;
--   * no full-table scans per frame;
--   * no wall-clock dependency; native frame delta is the pressure signal;
--   * no task callback is executed here.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite

local PRIORITY = { P0=0, P1=1, P2=2, P3=3, P4=4, P5=5 }
local PRESSURE_RANK = { Normal=0, Busy=1, Heavy=2, Critical=3 }
local BACKLOG_PRESSURE = {
    Normal="Normal", Delayed="Busy", ["Heavy Backlog"]="Heavy", Critical="Critical",
}

-- Credits are intentionally conservative and measured in abstract work units,
-- not milliseconds. This keeps the policy deterministic on RU clients where a
-- reliable Lua execution timer is not guaranteed. A task may later declare a
-- higher cost via Scheduler:SetCost without changing its business behavior.
local PROFILE = {
    Normal   = { credits=10, maxExecutions=10 },
    Busy     = { credits=8,  maxExecutions=8  },
    Heavy    = { credits=5,  maxExecutions=6  },
    Critical = { credits=3,  maxExecutions=4  },
}

local MAX_DEFER_FRAMES = { [0]=0, [1]=0, [2]=3, [3]=5, [4]=8, [5]=12 }
local STARVATION_LATE_RATIO = { [0]=0, [1]=0, [2]=1.5, [3]=2.0, [4]=3.0, [5]=4.0 }
local MAX_OWNER_STATS = 96

local function Finite(value, fallback)
    value = tonumber(value)
    if value == nil or value ~= value or value == math.huge or value == -math.huge then return fallback end
    return value
end

local function NormalizePriority(value)
    if type(value) == "string" then value = PRIORITY[string.upper(value)] end
    value = math.floor(Finite(value, 3))
    if value < 0 then return 0 end
    if value > 5 then return 5 end
    return value
end

local function NormalizeCost(value)
    value = math.floor(Finite(value, 1))
    if value < 1 then return 1 end
    if value > 8 then return 8 end
    return value
end

local function DtPressure(dtMs)
    local dt = math.max(0, Finite(dtMs, 0))
    if dt >= 70 then return "Critical" end
    if dt >= 40 then return "Heavy" end
    if dt >= 24 then return "Busy" end
    return "Normal"
end

local function MaxPressure(a, b)
    a, b = tostring(a or "Normal"), tostring(b or "Normal")
    if (PRESSURE_RANK[b] or 0) > (PRESSURE_RANK[a] or 0) then return b end
    return a
end

S.FrameBudget = {
    Version = "1.0",
    frameSerial = 0,
    current = {
        pressure="Normal", frameDtMs=0, pendingBefore=0,
        creditsTotal=10, creditsRemaining=10, maxExecutions=10,
        granted=0, deferred=0, criticalGranted=0, starvationRuns=0,
    },
    previous = nil,
    totals = { frames=0, requests=0, granted=0, deferred=0, criticalGranted=0, starvationRuns=0 },
    ownerStats = {}, ownerCount = 0,
}
local B = S.FrameBudget

function B:BeginFrame(frameDtMs, backlogHealth, pendingBefore)
    local dt = math.max(0, Finite(frameDtMs, 0))
    local pressure = MaxPressure(DtPressure(dt), BACKLOG_PRESSURE[tostring(backlogHealth or "Normal")] or "Normal")
    local profile = PROFILE[pressure] or PROFILE.Normal

    local old = self.current
    self.previous = {
        serial = self.frameSerial,
        pressure = old.pressure,
        frameDtMs = old.frameDtMs,
        pendingBefore = old.pendingBefore,
        pendingAfter = old.pendingAfter,
        creditsTotal = old.creditsTotal,
        creditsRemaining = old.creditsRemaining,
        maxExecutions = old.maxExecutions,
        granted = old.granted,
        deferred = old.deferred,
        criticalGranted = old.criticalGranted,
        starvationRuns = old.starvationRuns,
    }

    self.frameSerial = self.frameSerial + 1
    self.current = {
        serial = self.frameSerial,
        pressure = pressure,
        frameDtMs = dt,
        pendingBefore = math.max(0, math.floor(Finite(pendingBefore, 0))),
        pendingAfter = 0,
        creditsTotal = profile.credits,
        creditsRemaining = profile.credits,
        maxExecutions = profile.maxExecutions,
        granted = 0,
        deferred = 0,
        criticalGranted = 0,
        starvationRuns = 0,
    }
    self.totals.frames = (tonumber(self.totals.frames) or 0) + 1
    return pressure
end

function B:_OwnerStats(owner)
    owner = tostring(owner or "unknown")
    if owner == "" then owner = "unknown" end
    local stats = self.ownerStats[owner]
    if stats ~= nil then return stats, owner end
    if self.ownerCount >= MAX_OWNER_STATS then
        owner = "other"
        stats = self.ownerStats[owner]
        if stats ~= nil then return stats, owner end
    end
    stats = { requests=0, granted=0, deferred=0, starvationRuns=0, criticalGranted=0, maxConsecutiveDefers=0 }
    self.ownerStats[owner] = stats
    self.ownerCount = self.ownerCount + 1
    return stats, owner
end

function B:Request(owner, priority, costUnits, deferCount, lateRatio)
    local p = NormalizePriority(priority)
    local cost = NormalizeCost(costUnits)
    local current = self.current
    local stats = self:_OwnerStats(owner)
    -- Accept the early table form for compatibility, but the scheduler uses
    -- direct scalar arguments so the per-frame hot path allocates no options
    -- table.
    if type(deferCount) == "table" then
        local options = deferCount
        deferCount = options.deferCount
        lateRatio = options.lateRatio
    end

    self.totals.requests = (tonumber(self.totals.requests) or 0) + 1
    stats.requests = (tonumber(stats.requests) or 0) + 1

    -- P0/P1 are correctness/user-action lanes. They are accounted but never
    -- denied by the soft budget. If they exceed the remaining credits, the
    -- deficit is visible in diagnostics instead of changing game behavior.
    if p <= 1 then
        current.granted = current.granted + 1
        current.criticalGranted = current.criticalGranted + 1
        current.creditsRemaining = math.max(0, current.creditsRemaining - cost)
        self.totals.granted = self.totals.granted + 1
        self.totals.criticalGranted = self.totals.criticalGranted + 1
        stats.granted = stats.granted + 1
        stats.criticalGranted = stats.criticalGranted + 1
        return true, "critical"
    end

    deferCount = math.max(0, math.floor(Finite(deferCount, 0)))
    lateRatio = math.max(0, Finite(lateRatio, 0))
    if deferCount > (tonumber(stats.maxConsecutiveDefers) or 0) then stats.maxConsecutiveDefers = deferCount end

    local executionRoom = current.granted < current.maxExecutions
    local creditRoom = current.creditsRemaining >= cost
    if executionRoom and creditRoom then
        current.granted = current.granted + 1
        current.creditsRemaining = current.creditsRemaining - cost
        self.totals.granted = self.totals.granted + 1
        stats.granted = stats.granted + 1
        return true, "budget"
    end

    -- One starvation escape per rendered frame. This is deliberately bounded:
    -- allowing every old task to escape together would recreate the hitch the
    -- broker exists to prevent.
    local starving = deferCount >= (MAX_DEFER_FRAMES[p] or 8)
        or lateRatio >= (STARVATION_LATE_RATIO[p] or 3.0)
    if starving and current.starvationRuns < 1 then
        current.granted = current.granted + 1
        current.starvationRuns = current.starvationRuns + 1
        current.creditsRemaining = math.max(0, current.creditsRemaining - cost)
        self.totals.granted = self.totals.granted + 1
        self.totals.starvationRuns = self.totals.starvationRuns + 1
        stats.granted = stats.granted + 1
        stats.starvationRuns = stats.starvationRuns + 1
        return true, "starvation"
    end

    current.deferred = current.deferred + 1
    self.totals.deferred = self.totals.deferred + 1
    stats.deferred = stats.deferred + 1
    return false, executionRoom and "credits" or "execution_cap"
end

function B:EndFrame(pendingAfter)
    self.current.pendingAfter = math.max(0, math.floor(Finite(pendingAfter, 0)))
end

function B:Describe()
    local c = self.current or {}
    local rows = {}
    for owner, stats in pairs(self.ownerStats or {}) do
        if (tonumber(stats.deferred) or 0) > 0 or (tonumber(stats.starvationRuns) or 0) > 0 then
            rows[#rows + 1] = {
                owner=owner, requests=tonumber(stats.requests) or 0, granted=tonumber(stats.granted) or 0,
                deferred=tonumber(stats.deferred) or 0, starvationRuns=tonumber(stats.starvationRuns) or 0,
                maxConsecutiveDefers=tonumber(stats.maxConsecutiveDefers) or 0,
            }
        end
    end
    table.sort(rows, function(a, b)
        if a.deferred ~= b.deferred then return a.deferred > b.deferred end
        if a.starvationRuns ~= b.starvationRuns then return a.starvationRuns > b.starvationRuns end
        return tostring(a.owner) < tostring(b.owner)
    end)
    while #rows > 8 do table.remove(rows) end

    return {
        version = tostring(self.Version or "?"), serial = tonumber(c.serial) or 0,
        pressure = tostring(c.pressure or "Normal"), frameDtMs = tonumber(c.frameDtMs) or 0,
        pendingBefore = tonumber(c.pendingBefore) or 0, pendingAfter = tonumber(c.pendingAfter) or 0,
        creditsTotal = tonumber(c.creditsTotal) or 0, creditsRemaining = tonumber(c.creditsRemaining) or 0,
        maxExecutions = tonumber(c.maxExecutions) or 0, granted = tonumber(c.granted) or 0,
        deferred = tonumber(c.deferred) or 0, criticalGranted = tonumber(c.criticalGranted) or 0,
        starvationRuns = tonumber(c.starvationRuns) or 0,
        totals = {
            frames=tonumber(self.totals.frames) or 0, requests=tonumber(self.totals.requests) or 0,
            granted=tonumber(self.totals.granted) or 0, deferred=tonumber(self.totals.deferred) or 0,
            criticalGranted=tonumber(self.totals.criticalGranted) or 0, starvationRuns=tonumber(self.totals.starvationRuns) or 0,
        },
        topDeferred = rows,
    }
end

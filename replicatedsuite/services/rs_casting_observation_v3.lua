------------------------------------------------------------------------
-- Replicated Suite V3 - Casting Observation Domain
--
-- Shared read-only casting facts for player/target/targettarget/watchtarget.
-- The four-unit scope set is the proven wbdebuff fact model
-- (jumpblackdragon.lua:115-129 checks target -> targettarget -> player ->
-- watchtarget in that order); Boss mechanic rules depend on all of them
-- because losing the target mid-mechanic must not kill the cast fact.
-- Consumers declare which scopes they need; the service owns the only
-- UnitCastingInfo polling task and stops it when the last lease is released.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Services = S.Services or {}

local C = {
    Id = "v3.casting_observation",
    version = 2,
    taskName = "v3_casting_observation_refresh",
    snapshots = { player = nil, target = nil, targettarget = nil, watchtarget = nil },
    revision = 0,
    nativeReads = 0,
    readFailures = 0,
    intervalMs = nil,
    scopes = { player = false, target = false, targettarget = false, watchtarget = false },
}
C.presentationBoundary = "service_only"
C.DemandScopedPollingContractVersion = 1
S.Services.CastingObservationV3 = C

local CAST_SCOPES = { "player", "target", "targettarget", "watchtarget" }
local CAST_SCOPE_SET = { player = true, target = true, targettarget = true, watchtarget = true }

local function Clamp(value, minimum, maximum)
    value = math.floor(tonumber(value) or minimum)
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

local function CopyCast(value)
    if type(value) ~= "table" then return nil end
    return {
        casting = value.casting == true,
        spellName = tostring(value.spellName or ""),
        currMs = math.max(0, math.floor(tonumber(value.currMs) or 0)),
        totalMs = math.max(1, math.floor(tonumber(value.totalMs) or 1)),
        remainingMs = math.max(0, math.floor(tonumber(value.remainingMs) or 0)),
        at = math.max(0, tonumber(value.at) or 0),
        revision = math.max(0, math.floor(tonumber(value.revision) or 0)),
    }
end

local function SameCast(a, b)
    if a == nil and b == nil then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    return a.spellName == b.spellName and a.totalMs == b.totalMs
        and math.abs((tonumber(a.currMs) or 0) - (tonumber(b.currMs) or 0)) < 40
end

local function NowMs() return math.max(0, tonumber(S.NowMs and S.NowMs()) or 0) end

function C:_Read(scope)
    if S.Api == nil or type(S.Api.CallCapability) ~= "function" then
        self.readFailures = self.readFailures + 1
        return nil
    end
    local unitApi = rawget(_G, "X2Unit")
    if unitApi == nil then
        self.readFailures = self.readFailures + 1
        return nil
    end
    self.nativeReads = self.nativeReads + 1
    local ok, info = S.Api:CallCapability("X2Unit:UnitCastingInfo", unitApi, "UnitCastingInfo", scope)
    if ok ~= true then
        self.readFailures = self.readFailures + 1
        return nil
    end
    -- No showTargetCastingTime gate: wbdebuff (the proven real-machine
    -- implementation) consumes UnitCastingInfo without consulting that field
    -- (jumpblackdragon.lua:115-121), so its semantics on the current RU client
    -- are unproven and gating on it silently killed the whole target cast
    -- channel. An empty spellName stays the only rejection.
    if type(info) ~= "table" or info.spellName == nil or tostring(info.spellName) == "" then return nil end
    local currMs = math.max(0, math.floor(tonumber(info.currCastingTime) or 0))
    local totalMs = math.max(1, math.floor(tonumber(info.castingTime) or 1))
    return {
        casting = true,
        spellName = tostring(info.spellName),
        currMs = currMs,
        totalMs = totalMs,
        remainingMs = math.max(0, totalMs - currMs),
        at = NowMs(),
    }
end

function C:Refresh(reason)
    if self.Demand == nil or (tonumber(self.Demand.count) or 0) <= 0 then return true end
    local changed = false
    for _, scope in ipairs(CAST_SCOPES) do
        if self.scopes[scope] == true then
            local nextCast = self:_Read(scope)
            local oldCast = self.snapshots[scope]
            if SameCast(oldCast, nextCast) ~= true then
                self.revision = self.revision + 1
                if nextCast ~= nil then nextCast.revision = self.revision end
                self.snapshots[scope] = nextCast
                changed = true
                if S.Events ~= nil and type(S.Events.Publish) == "function" then
                    S.Events:Publish("v3.casting.updated", scope, self.revision, tostring(reason or "refresh"))
                end
            elseif nextCast ~= nil and oldCast ~= nil then
                -- Keep timing fresh without generating an update edge for tiny
                -- clock deltas; consumers reading the cache still see progress.
                nextCast.revision = oldCast.revision
                self.snapshots[scope] = nextCast
            end
        elseif self.snapshots[scope] ~= nil then
            self.snapshots[scope] = nil
            changed = true
        end
    end
    return true, changed
end

function C:Get(scope)
    scope = tostring(scope or "")
    if CAST_SCOPE_SET[scope] ~= true then return nil end
    return CopyCast(self.snapshots[scope])
end

function C:AcquireConsumer(token, options)
    if self.Demand == nil then return false, "casting demand unavailable" end
    return self.Demand:Acquire(token, options, "casting_consumer")
end

function C:ReleaseConsumer(token)
    if self.Demand == nil then return false, "casting demand unavailable" end
    if self.Demand:Has(token) ~= true then return true end
    return self.Demand:Release(token, "casting_consumer")
end

function C:_Desired(after)
    local scopes = { player = false, target = false, targettarget = false, watchtarget = false }
    local interval = 1000
    for _, options in pairs(type(after) == "table" and type(after.consumers) == "table" and after.consumers or {}) do
        if type(options) == "table" then
            if options.player == true then scopes.player = true end
            if options.target ~= false then scopes.target = true end
            if options.targettarget == true then scopes.targettarget = true end
            if options.watchtarget == true then scopes.watchtarget = true end
            interval = math.min(interval, Clamp(options.intervalMs, 50, 1000))
        end
    end
    return scopes, interval
end

function C:_StopTask()
    if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(self.taskName) end
    self.intervalMs = nil
    return true
end

function C:_StartTask(scopes, interval)
    if S.Scheduler == nil or type(S.Scheduler.AddTask) ~= "function" then return false, "Casting Scheduler 不可用" end
    self:_StopTask()
    self.scopes = {
        player = scopes.player == true, target = scopes.target == true,
        targettarget = scopes.targettarget == true, watchtarget = scopes.watchtarget == true,
    }
    self.intervalMs = Clamp(interval, 50, 1000)
    local added = S.Scheduler:AddTask(self.taskName, self.intervalMs, function()
        return C:Refresh("scheduled")
    end, false, self, "P2", 1)
    if added ~= true then self.intervalMs = nil; return false, "Casting 观察任务创建失败" end
    if type(S.Scheduler.SetTaskModule) == "function" then S.Scheduler:SetTaskModule(self.taskName, self.Id, false) end
    self:Refresh("lease_reconcile")
    return true
end

function C:GetHealth()
    return {
        ok = self.Demand ~= nil,
        consumers = self.Demand and self.Demand.count or 0,
        intervalMs = self.intervalMs,
        player = self.scopes.player == true,
        target = self.scopes.target == true,
        targettarget = self.scopes.targettarget == true,
        watchtarget = self.scopes.watchtarget == true,
        revision = self.revision,
        nativeReads = self.nativeReads,
        readFailures = self.readFailures,
    }
end

if S.Demand == nil or type(S.Demand.Create) ~= "function" then error("Demand unavailable for CastingObservationV3") end
local demand, demandErr = S.Demand:Create({
    id = C.Id,
    owner = C,
    projectionOwner = C,
    projectionConsumersField = "consumers",
    projectionCountField = "consumerCount",
    normalize = function(options)
        options = type(options) == "table" and options or {}
        local player = options.player == true
        local target = options.target ~= false
        if player ~= true and target ~= true then target = true end
        return { player = player, target = target,
            targettarget = options.targettarget == true, watchtarget = options.watchtarget == true,
            intervalMs = Clamp(options.intervalMs, 50, 1000), purpose = tostring(options.purpose or "generic") }
    end,
    reconcile = function(_, before, after)
        local beforeCount = tonumber(before and before.count) or 0
        local afterCount = tonumber(after and after.count) or 0
        if afterCount <= 0 then
            C:_StopTask()
            C.scopes = { player = false, target = false, targettarget = false, watchtarget = false }
            C.snapshots = { player = nil, target = nil, targettarget = nil, watchtarget = nil }
            return true
        end
        local scopes, interval = C:_Desired(after)
        local needsRestart = beforeCount <= 0 or C.intervalMs ~= interval
            or C.scopes.player ~= scopes.player or C.scopes.target ~= scopes.target
        if needsRestart then return C:_StartTask(scopes, interval) end
        return true
    end,
    quiesce = function()
        C:_StopTask()
        C.scopes = { player = false, target = false, targettarget = false, watchtarget = false }
        C.snapshots = { player = nil, target = nil, targettarget = nil, watchtarget = nil }
        return true
    end,
})
if demand == nil then error(demandErr) end
C.Demand = demand

------------------------------------------------------------------------
-- Replicated Suite - Single monotonic OnUpdate scheduler v3
-- Author: Replicated
--
-- One private driver owns elapsed time for the whole Suite. Services may add
-- low-frequency jobs, but they never attach their own OnUpdate handlers.
--
-- Runtime priorities are intentionally compatible with the old AddTask call:
-- callers that omit priority remain P3. Under pressure we defer lower-priority
-- refresh work instead of dropping critical facts. Professional DPS keeps its
-- proven event pipeline; this scheduler governs Suite-owned periodic work.
------------------------------------------------------------------------

if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite

S.Scheduler = {
    version = 3,
    driver = nil, running = false, tasks = {}, taskModules = {}, transientTaskModules = {}, dueScratch = {},
    backlog = { health="Normal", pending=0, maxLateMs=0, maxLateRatio=0, executedLastFrame=0, deferredByBudget=0 },
}
local Scheduler = S.Scheduler

local PRIORITY = { P0=0, P1=1, P2=2, P3=3, P4=4, P5=5 }
local FALLBACK_HEALTH_BUDGET = { Normal=10, Delayed=8, ["Heavy Backlog"]=6, Critical=4 }
local BACKGROUND_MIN_INTERVAL_MS = 50
local INTERACTIVE_MIN_INTERVAL_MS = 16
-- Frame-cadence lane: intervals below the 16 ms interactive floor are allowed
-- (down to 1 ms). A 1 ms request is intentionally never clamped upward; the
-- single OnUpdate driver simply runs the task on every rendered frame. Callers
-- MUST remove these tasks when the surface they feed is hidden.
local HIGHFREQUENCY_MIN_INTERVAL_MS = 1

local function ReadDeltaMs(dt)
    local elapsed = tonumber(dt) or 0
    if elapsed ~= elapsed or elapsed == math.huge or elapsed == -math.huge or elapsed < 0 then return 0 end
    if elapsed > 0 and elapsed < 1 then elapsed = elapsed * 1000 end
    return elapsed
end

local function NormalizeDelta(dt)
    -- Scheduler work remains capped after a client freeze: a large catch-up
    -- burst would turn one hitch into several more. Performance telemetry uses
    -- ReadDeltaMs separately and therefore never hides the actual stall.
    return math.min(ReadDeltaMs(dt), 1000)
end

local function NormalizePriority(value)
    if type(value) == "string" then value = PRIORITY[string.upper(value)] end
    value = math.floor(tonumber(value) or 3)
    if value < 0 then return 0 end
    if value > 5 then return 5 end
    return value
end


local function NormalizeCost(value)
    value = math.floor(tonumber(value) or 1)
    if value < 1 then return 1 end
    if value > 8 then return 8 end
    return value
end

local function ClassifyBacklog(pending, maxLateRatio)
    pending = tonumber(pending) or 0
    maxLateRatio = tonumber(maxLateRatio) or 0
    if pending >= 24 or maxLateRatio >= 4.0 then return "Critical" end
    if pending >= 12 or maxLateRatio >= 2.0 then return "Heavy Backlog" end
    if pending >= 6 or maxLateRatio >= 0.75 then return "Delayed" end
    return "Normal"
end

local function CompareDueNames(a, b)
    local ta, tb = Scheduler.tasks[a], Scheduler.tasks[b]
    if ta == nil then return false end
    if tb == nil then return true end
    local pa, pb = NormalizePriority(ta.priority), NormalizePriority(tb.priority)
    if pa ~= pb then return pa < pb end
    local da, db = tonumber(ta.dueSinceMs) or 0, tonumber(tb.dueSinceMs) or 0
    if da ~= db then return da < db end
    return tostring(a) < tostring(b)
end

local function AddTaskInternal(self, name, intervalMs, callback, runImmediately, owner, priority, costUnits, lane)
    if type(name) ~= "string" or name == "" or type(callback) ~= "function" then return false end
    lane = (lane == "interactive" and "interactive") or (lane == "highfrequency" and "highfrequency") or "background"
    local minimum = lane == "interactive" and INTERACTIVE_MIN_INTERVAL_MS
        or (lane == "highfrequency" and HIGHFREQUENCY_MIN_INTERVAL_MS or BACKGROUND_MIN_INTERVAL_MS)
    local interval = math.max(minimum, tonumber(intervalMs)
        or (lane == "interactive" and INTERACTIVE_MIN_INTERVAL_MS or (lane == "highfrequency" and HIGHFREQUENCY_MIN_INTERVAL_MS or 1000)))
    local moduleId = self.taskModules[tostring(name)] or "suite"
    self.tasks[name] = {
        intervalMs = interval, callback = callback, lane = lane,
        elapsedMs = runImmediately == true and interval or 0, enabled = true,
        owner = owner, failureCount = 0, priority = NormalizePriority(priority),
        costUnits = NormalizeCost(costUnits), deferCount = 0,
        budgetOwner = tostring(moduleId) .. ":" .. tostring(name),
        pending = runImmediately == true, dueSinceMs = runImmediately == true and (S.NowMs and S.NowMs() or 0) or nil,
    }
    return true
end

function Scheduler:AddTask(name, intervalMs, callback, runImmediately, owner, priority, costUnits)
    return AddTaskInternal(self, name, intervalMs, callback, runImmediately, owner, priority, costUnits, "background")
end

-- High-frequency input sampling is explicitly separated from ordinary periodic
-- work.  Only bounded user interactions (drag/resize/scroll) should use this
-- lane; tasks must be removed when the gesture ends.  This keeps the Suite on
-- one OnUpdate authority without silently turning every service into a 16 ms job.
function Scheduler:AddInteractiveTask(name, intervalMs, callback, runImmediately, owner, priority, costUnits)
    return AddTaskInternal(self, name, intervalMs, callback, runImmediately, owner, priority or "P0", costUnits or 1, "interactive")
end

-- Frame-cadence visual lane (unit lines / head markers / cast bars). Accepts
-- intervals down to 1 ms and never silently raises them; the frame loop still
-- decides actual execution cadence. Tasks here are excluded from backlog-health
-- classification because a 1 ms task is by construction "late" every frame and
-- must not poison the shared health telemetry of the other lanes.
function Scheduler:AddHighFrequencyTask(name, intervalMs, callback, runImmediately, owner, priority, costUnits)
    return AddTaskInternal(self, name, intervalMs, callback, runImmediately, owner, priority or "P1", costUnits or 1, "highfrequency")
end

-- Bounded one-shot work on the frame-cadence lane (delay floor 1 ms). Used when
-- a visual reaction must not wait the 50 ms background one-shot floor.
function Scheduler:AddHighFrequencyOneShot(name, delayMs, callback, owner, priority, costUnits)
    if type(name) ~= "string" or name == "" or type(callback) ~= "function" then return false end
    local scheduler = self
    return self:AddHighFrequencyTask(name, math.max(HIGHFREQUENCY_MIN_INTERVAL_MS, tonumber(delayMs) or HIGHFREQUENCY_MIN_INTERVAL_MS), function()
        scheduler:RemoveTask(name)
        return callback()
    end, false, owner, priority or "P1", costUnits or 1)
end

local function TaskInterval(task)
    local lane = type(task) == "table" and task.lane or "background"
    local minimum = lane == "interactive" and INTERACTIVE_MIN_INTERVAL_MS
        or (lane == "highfrequency" and HIGHFREQUENCY_MIN_INTERVAL_MS or BACKGROUND_MIN_INTERVAL_MS)
    return math.max(minimum, tonumber(task and task.intervalMs) or 1000)
end

-- Bounded one-shot work shares the same single scheduler driver. The task is
-- removed BEFORE user code runs so callback failure/re-entry can never leave a
-- zombie timer behind. This is intended for UI notifications, delayed commits
-- and other finite work; Feature periodic jobs should keep using AddTask.
function Scheduler:AddOneShot(name, delayMs, callback, owner, priority, costUnits)
    if type(name) ~= "string" or name == "" or type(callback) ~= "function" then return false end
    local scheduler = self
    return self:AddTask(name, math.max(50, tonumber(delayMs) or 50), function()
        scheduler:RemoveTask(name)
        return callback()
    end, false, owner, priority or "P3", costUnits or 1)
end

function Scheduler:RemoveTask(name)
    name = tostring(name or "")
    self.tasks[name] = nil
    -- Static task->module mappings are registered once and intentionally survive
    -- ordinary stop/start cycles. Dynamic callers opt into transient ownership so
    -- unique one-shot names cannot leak metadata for the whole client session.
    if self.transientTaskModules[name] == true then
        self.transientTaskModules[name] = nil
        self.taskModules[name] = nil
    end
    return true
end

function Scheduler:SetTaskModule(name, moduleId, transient)
    name, moduleId = tostring(name or ""), tostring(moduleId or "")
    if name == "" or moduleId == "" then return false end
    self.taskModules[name] = moduleId
    if transient == true then self.transientTaskModules[name] = true else self.transientTaskModules[name] = nil end
    local task = self.tasks[name]
    if task ~= nil then task.budgetOwner = moduleId .. ":" .. name end
    return true
end

function Scheduler:SetCost(name, costUnits)
    local task = self.tasks[tostring(name or "")]
    if task == nil then return false end
    task.costUnits = NormalizeCost(costUnits)
    return true
end

function Scheduler:RemoveOwner(owner)
    if owner == nil then return 0 end
    local names = {}
    for name, task in pairs(self.tasks) do
        if task.owner == owner then names[#names + 1] = name end
    end
    for _, name in ipairs(names) do self:RemoveTask(name) end
    return #names
end

function Scheduler:SetEnabled(name, enabled)
    local task = self.tasks[name]
    if task ~= nil then
        task.enabled = enabled == true
        if task.enabled ~= true then task.pending = false; task.dueSinceMs = nil; task.deferCount = 0 end
    end
end

function Scheduler:SetPriority(name, priority)
    local task = self.tasks[name]
    if task == nil then return false end
    task.priority = NormalizePriority(priority)
    return true
end

function Scheduler:RunTask(name)
    local task = self.tasks[name]
    if task == nil or task.enabled ~= true then return false end
    local moduleId = self.taskModules[tostring(name)] or "suite"
    local token = S.PerformanceMonitor and S.PerformanceMonitor:Begin("task:" .. tostring(name), moduleId) or nil
    local ok, err = xpcall(task.callback, S.SafeTraceback)
    if S.PerformanceMonitor ~= nil then S.PerformanceMonitor:End(token) end
    if ok then task.failureCount = 0; return true end
    task.failureCount = (tonumber(task.failureCount) or 0) + 1
    S.LastSchedulerError = { task = tostring(name), error = tostring(err or "unknown"), failures = task.failureCount }
    if task.failureCount >= 3 then
        task.enabled = false
        task.pending = false
        task.dueSinceMs = nil
        S.WarnOnce("scheduler_fault:" .. tostring(name), "后台任务已安全暂停：" .. tostring(name))
    end
    return false
end

function Scheduler:DescribeBacklog()
    local b = self.backlog or {}
    return {
        health = tostring(b.health or "Normal"), pending = tonumber(b.pending) or 0,
        maxLateMs = tonumber(b.maxLateMs) or 0, maxLateRatio = tonumber(b.maxLateRatio) or 0,
        executedLastFrame = tonumber(b.executedLastFrame) or 0,
        deferredByBudget = tonumber(b.deferredByBudget) or 0,
    }
end

function Scheduler:GetHealth()
    local activeTasks, moduleMappings, transientMappings, transientOrphans = 0, 0, 0, 0
    for _ in pairs(self.tasks or {}) do activeTasks = activeTasks + 1 end
    for _ in pairs(self.taskModules or {}) do moduleMappings = moduleMappings + 1 end
    for name in pairs(self.transientTaskModules or {}) do
        transientMappings = transientMappings + 1
        if self.tasks[name] == nil then transientOrphans = transientOrphans + 1 end
    end
    return {
        version = self.version, running = self.running == true, activeTasks = activeTasks,
        moduleMappings = moduleMappings, transientMappings = transientMappings, transientOrphans = transientOrphans,
    }
end

function Scheduler:Start()
    if self.running == true then return true end
    local factory = S.NativeObjectFactory
    local driver = type(factory) == "table" and type(factory.CreateEmptyWidget) == "function"
        and factory:CreateEmptyWidget(S.PhysicalId("scheduler"), "UIParent") or nil
    if driver == nil then
        S.SafeChat("统一调度器创建失败。")
        return false
    end
    if driver.SetExtent ~= nil then driver:SetExtent(1, 1) end
    if driver.AddAnchor ~= nil then driver:AddAnchor("TOPLEFT", "UIParent", 0, 0) end
    if driver.Show ~= nil then driver:Show(true) end
    self.driver = driver
    self.running = true
    local generation = S.Generation

    if type(driver.SetHandler) ~= "function" then
        if driver.Show ~= nil then pcall(function() driver:Show(false) end) end
        self.driver = nil
        self.running = false
        S.SafeChat("统一调度器缺少更新回调。")
        return false
    end
    local handlerOk, handlerResult = pcall(function()
        return driver:SetHandler("OnUpdate", function(_, dt)
        if S.Generation ~= generation or Scheduler.running ~= true then return end
        local rawElapsed = ReadDeltaMs(dt)
        local elapsed = NormalizeDelta(dt)
        if elapsed <= 0 then return end
        if S.PerformanceMonitor ~= nil then S.PerformanceMonitor:BeginFrame(rawElapsed, 0) end
        if S.AdvanceClock ~= nil then S.AdvanceClock(elapsed) end
        local now = S.NowMs and S.NowMs() or 0

        -- First only update timing state. A callback may remove/add tasks, so
        -- never execute while iterating the authoritative table. Reuse the
        -- scratch array: this handler runs every frame and must not create a
        -- fresh table/comparator closure when no task is due.
        local dueNames = Scheduler.dueScratch
        for index = #dueNames, 1, -1 do dueNames[index] = nil end
        local pendingCount, maxLateMs, maxLateRatio = 0, 0, 0
        for name, task in pairs(Scheduler.tasks) do
            if task.enabled == true then
                local interval = TaskInterval(task)
                task.intervalMs = interval
                task.elapsedMs = math.min(interval * 8, (tonumber(task.elapsedMs) or 0) + elapsed)
                if task.elapsedMs >= interval then
                    if task.pending ~= true then
                        task.pending = true
                        task.dueSinceMs = now
                    end
                    dueNames[#dueNames + 1] = name
                    -- High-frequency tasks are due every frame by construction;
                    -- counting their lateness would permanently poison the
                    -- shared backlog health classification.
                    if task.lane ~= "highfrequency" then
                        pendingCount = pendingCount + 1
                        local lateMs = math.max(0, task.elapsedMs - interval)
                        local lateRatio = lateMs / interval
                        if lateMs > maxLateMs then maxLateMs = lateMs end
                        if lateRatio > maxLateRatio then maxLateRatio = lateRatio end
                    end
                end
            end
        end

        if #dueNames > 1 then table.sort(dueNames, CompareDueNames) end

        local health = ClassifyBacklog(pendingCount, maxLateRatio)
        local frameBudget = S.FrameBudget
        if frameBudget ~= nil and type(frameBudget.BeginFrame) == "function" then
            frameBudget:BeginFrame(rawElapsed, health, pendingCount)
        end
        local fallbackBudget = FALLBACK_HEALTH_BUDGET[health] or 8
        local executed, deferredByBudget = 0, 0
        for _, name in ipairs(dueNames) do
            local task = Scheduler.tasks[name]
            if task ~= nil and task.enabled == true and task.pending == true then
                local interval = TaskInterval(task)
                local lateMs = math.max(0, (tonumber(task.elapsedMs) or interval) - interval)
                local lateRatio = lateMs / interval
                local allowed = executed < fallbackBudget
                if frameBudget ~= nil and type(frameBudget.Request) == "function" then
                    allowed = frameBudget:Request(task.budgetOwner or tostring(name), task.priority, task.costUnits, task.deferCount, lateRatio) == true
                end
                if allowed then
                    -- Consume one periodic occurrence. We intentionally do not run
                    -- multiple catch-up callbacks in one frame after a hitch.
                    task.elapsedMs = math.max(0, (tonumber(task.elapsedMs) or interval) - interval)
                    task.pending = false
                    task.dueSinceMs = nil
                    task.deferCount = 0
                    Scheduler:RunTask(name)
                    executed = executed + 1
                else
                    task.deferCount = math.min(64, (tonumber(task.deferCount) or 0) + 1)
                    deferredByBudget = deferredByBudget + 1
                end
            end
        end
        local backlog = Scheduler.backlog
        backlog.health = health
        backlog.pending = math.max(0, pendingCount - executed)
        backlog.maxLateMs = maxLateMs
        backlog.maxLateRatio = maxLateRatio
        backlog.executedLastFrame = executed
        backlog.deferredByBudget = deferredByBudget
        if frameBudget ~= nil and type(frameBudget.EndFrame) == "function" then frameBudget:EndFrame(backlog.pending) end
        if S.PerformanceMonitor ~= nil then S.PerformanceMonitor:EndFrame(rawElapsed, backlog.pending) end
        end)
    end)
    if handlerOk ~= true or handlerResult == false then
        if driver.Show ~= nil then pcall(function() driver:Show(false) end) end
        self.driver = nil
        self.running = false
        S.SafeChat("统一调度器更新回调绑定失败。")
        return false
    end
    return true
end

function Scheduler:Stop()
    self.running = false
    self.tasks = {}
    for name in pairs(self.transientTaskModules or {}) do self.taskModules[name] = nil end
    self.transientTaskModules = {}
    for index = #(self.dueScratch or {}), 1, -1 do self.dueScratch[index] = nil end
    self.backlog = { health="Normal", pending=0, maxLateMs=0, maxLateRatio=0, executedLastFrame=0, deferredByBudget=0 }
    local driver = self.driver
    if driver ~= nil then
        if type(driver.ReleaseHandler) == "function" then
            pcall(function() driver:ReleaseHandler("OnUpdate") end)
        end
        if driver.Show ~= nil then pcall(function() driver:Show(false) end) end
    end
    self.driver = nil
end

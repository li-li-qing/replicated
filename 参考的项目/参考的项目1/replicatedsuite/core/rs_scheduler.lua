------------------------------------------------------------------------
-- Replicated Suite - Single monotonic OnUpdate scheduler
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
    driver = nil, running = false, tasks = {}, taskModules = {}, dueScratch = {},
    backlog = { health="Normal", pending=0, maxLateMs=0, maxLateRatio=0, executedLastFrame=0 },
}
local Scheduler = S.Scheduler

local PRIORITY = { P0=0, P1=1, P2=2, P3=3, P4=4, P5=5 }
local HEALTH_BUDGET = { Normal=10, Delayed=8, ["Heavy Backlog"]=6, Critical=4 }

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

function Scheduler:AddTask(name, intervalMs, callback, runImmediately, owner, priority)
    if type(name) ~= "string" or name == "" or type(callback) ~= "function" then return false end
    local interval = math.max(50, tonumber(intervalMs) or 1000)
    self.tasks[name] = {
        intervalMs = interval, callback = callback,
        elapsedMs = runImmediately == true and interval or 0, enabled = true,
        owner = owner, failureCount = 0, priority = NormalizePriority(priority),
        pending = runImmediately == true, dueSinceMs = runImmediately == true and (S.NowMs and S.NowMs() or 0) or nil,
    }
    return true
end

function Scheduler:RemoveTask(name)
    self.tasks[name] = nil
end

function Scheduler:SetTaskModule(name, moduleId)
    name, moduleId = tostring(name or ""), tostring(moduleId or "")
    if name == "" or moduleId == "" then return false end
    self.taskModules[name] = moduleId
    return true
end

function Scheduler:RemoveOwner(owner)
    if owner == nil then return 0 end
    local removed = 0
    for name, task in pairs(self.tasks) do
        if task.owner == owner then self.tasks[name] = nil; removed = removed + 1 end
    end
    return removed
end

function Scheduler:SetEnabled(name, enabled)
    local task = self.tasks[name]
    if task ~= nil then
        task.enabled = enabled == true
        if task.enabled ~= true then task.pending = false; task.dueSinceMs = nil end
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
    }
end

function Scheduler:Start()
    if self.running == true then return true end
    local driver = UIParent:CreateWidget("emptywidget", S.PhysicalId("scheduler"), "UIParent")
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
        S.SafeChat("统一调度器缺少 OnUpdate Handler。")
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
                local interval = math.max(50, tonumber(task.intervalMs) or 1000)
                task.intervalMs = interval
                task.elapsedMs = math.min(interval * 8, (tonumber(task.elapsedMs) or 0) + elapsed)
                if task.elapsedMs >= interval then
                    if task.pending ~= true then
                        task.pending = true
                        task.dueSinceMs = now
                    end
                    pendingCount = pendingCount + 1
                    local lateMs = math.max(0, task.elapsedMs - interval)
                    local lateRatio = lateMs / interval
                    if lateMs > maxLateMs then maxLateMs = lateMs end
                    if lateRatio > maxLateRatio then maxLateRatio = lateRatio end
                    dueNames[#dueNames + 1] = name
                end
            end
        end

        if #dueNames > 1 then table.sort(dueNames, CompareDueNames) end

        local health = ClassifyBacklog(pendingCount, maxLateRatio)
        local budget = HEALTH_BUDGET[health] or 8
        local executed = 0
        for _, name in ipairs(dueNames) do
            if executed >= budget then break end
            local task = Scheduler.tasks[name]
            if task ~= nil and task.enabled == true and task.pending == true then
                local interval = math.max(50, tonumber(task.intervalMs) or 1000)
                -- Consume one periodic occurrence. We intentionally do not run
                -- multiple catch-up callbacks in one frame after a hitch.
                task.elapsedMs = math.max(0, (tonumber(task.elapsedMs) or interval) - interval)
                task.pending = false
                task.dueSinceMs = nil
                Scheduler:RunTask(name)
                executed = executed + 1
            end
        end
        local backlog = Scheduler.backlog
        backlog.health = health
        backlog.pending = math.max(0, pendingCount - executed)
        backlog.maxLateMs = maxLateMs
        backlog.maxLateRatio = maxLateRatio
        backlog.executedLastFrame = executed
        if S.PerformanceMonitor ~= nil then S.PerformanceMonitor:EndFrame(rawElapsed, backlog.pending) end
        end)
    end)
    if handlerOk ~= true or handlerResult == false then
        if driver.Show ~= nil then pcall(function() driver:Show(false) end) end
        self.driver = nil
        self.running = false
        S.SafeChat("统一调度器 OnUpdate 绑定失败。")
        return false
    end
    return true
end

function Scheduler:Stop()
    self.running = false
    self.tasks = {}
    for index = #(self.dueScratch or {}), 1, -1 do self.dueScratch[index] = nil end
    self.backlog = { health="Normal", pending=0, maxLateMs=0, maxLateRatio=0, executedLastFrame=0 }
    local driver = self.driver
    if driver ~= nil then
        if type(driver.ReleaseHandler) == "function" then
            pcall(function() driver:ReleaseHandler("OnUpdate") end)
        end
        if driver.Show ~= nil then pcall(function() driver:Show(false) end) end
    end
    self.driver = nil
end

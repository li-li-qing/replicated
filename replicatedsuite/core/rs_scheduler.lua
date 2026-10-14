------------------------------------------------------------------------
-- Replicated Suite · 单一调度器
-- 作者：Replicated
-- QQ群：1104129461
--
-- 单一私有 OnUpdate 驱动拥有全 Suite 已逝时间；Service 可增加低频任务，不能安装自身 OnUpdate。省略 priority
-- 的旧 AddTask 调用仍为 P3；压力下延后低优先级刷新，不丢关键事实。专业 DPS 保持已有事件流水线，此 Scheduler
-- 只管理 Suite 周期工作。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite

S.Scheduler = {
    version = 3,
    -- 调度器独占执行 Authority，Epoch 隔离同 Generation 重启。
    -- Owner 手动暂停与异常熔断必须分离；不改变业务 Store、Native API 或现有任务调用签名。
    runEpoch = 0, lifecycleContractVersion = 1,
    driver = nil, running = false, tasks = {}, taskModules = {}, transientTaskModules = {}, dueScratch = {},
    backlog = { health="Normal", pending=0, maxLateMs=0, maxLateRatio=0, executedLastFrame=0, deferredByBudget=0 },
}
local Scheduler = S.Scheduler

local PRIORITY = { P0=0, P1=1, P2=2, P3=3, P4=4, P5=5 }
local FALLBACK_HEALTH_BUDGET = { Normal=10, Delayed=8, ["Heavy Backlog"]=6, Critical=4 }
local BACKGROUND_MIN_INTERVAL_MS = 50
local INTERACTIVE_MIN_INTERVAL_MS = 16
-- 帧节奏通道允许低于 16ms 交互下限，最小 1ms；1ms 请求不向上夹紧，单一 OnUpdate 每个渲染帧运行任务。表面隐
-- 藏时调用者必须移除相应任务。
local HIGHFREQUENCY_MIN_INTERVAL_MS = 1

local function ReadDeltaMs(dt)
    local elapsed = tonumber(dt) or 0
    if elapsed ~= elapsed or elapsed == math.huge or elapsed == -math.huge or elapsed < 0 then return 0 end
    if elapsed > 0 and elapsed < 1 then elapsed = elapsed * 1000 end
    return elapsed
end

local function NormalizeDelta(dt)
    -- 客户端冻结后 Scheduler 仍限制单帧工作量，避免追赶突发把一次卡顿扩成多次。Performance 独立使用
    -- ReadDeltaMs，不隐藏真实停顿。
    return math.min(ReadDeltaMs(dt), 1000)
end

-- 非法数值不得进入排序/计时/预算；与 FrameBudget 的有限数规则一致。
-- 正常有限值仍按旧上下限处理；NaN/Inf 回到安全默认，不让一个调用者污染整帧。
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

local function ClassifyBacklog(pending, maxLateRatio)
    pending = tonumber(pending) or 0
    maxLateRatio = tonumber(maxLateRatio) or 0
    if pending >= 24 or maxLateRatio >= 4.0 then return "Critical" end
    if pending >= 12 or maxLateRatio >= 2.0 then return "Heavy Backlog" end
    if pending >= 6 or maxLateRatio >= 0.75 then return "Delayed" end
    return "Normal"
end

-- 排序固定的任务实例而不是可被回调替换的 name；同名新任务必须等下一帧。
-- Scratch 数组只保存实例引用且每帧清空，不创建每帧表/比较闭包，也不延长 Owner 生命周期。
local function CompareDueTasks(a, b)
    local pa, pb = a.priority, b.priority
    -- （2026-10-03）P0/P1 先行，普通任务保持原优先级；只有 Broker 认定已饥饿的
    -- P2..P5 按本次等待起点轮转，否则高频 P2 会每帧独占逃生名额，实际候选/视觉任务数十秒不执行。
    if pa<=1 or pb<=1 then
        if pa~=pb then return pa<pb end
    elseif a.starvationDue~=b.starvationDue then return a.starvationDue==true
    elseif a.starvationDue~=true and pa~=pb then return pa<pb end
    local da, db = tonumber(a.dueSinceMs) or 0, tonumber(b.dueSinceMs) or 0
    if da ~= db then return da < db end
    if pa~=pb then return pa<pb end -- 同一等待时刻仍以优先级打破平局；没有随机排序或额外执行配额。
    return a.name < b.name
end

local function AddTaskInternal(self, name, intervalMs, callback, runImmediately, owner, priority, costUnits, lane)
    if type(name) ~= "string" or name == "" or type(callback) ~= "function" then return false end
    lane = (lane == "interactive" and "interactive") or (lane == "highfrequency" and "highfrequency") or "background"
    local minimum = lane == "interactive" and INTERACTIVE_MIN_INTERVAL_MS
        or (lane == "highfrequency" and HIGHFREQUENCY_MIN_INTERVAL_MS or BACKGROUND_MIN_INTERVAL_MS)
    local interval = math.max(minimum, Finite(intervalMs,
        lane == "interactive" and INTERACTIVE_MIN_INTERVAL_MS or (lane == "highfrequency" and HIGHFREQUENCY_MIN_INTERVAL_MS or 1000)))
    local moduleId = self.taskModules[tostring(name)] or "suite"
    self.tasks[name] = {
        -- name 仅作索引，table 身份才是本次注册的执行凭证；Owner 的暂停不由熔断器接管。
        name = name, intervalMs = interval, callback = callback, lane = lane,
        elapsedMs = runImmediately == true and interval or 0, enabled = true, manuallyDisabled = false,
        owner = owner, failureCount = 0, failureTotal = 0, runCount = 0, priority = NormalizePriority(priority),
        costUnits = NormalizeCost(costUnits), deferCount = 0,
        lastRunAtMs = nil, lastSuccessAtMs = nil, lastErrorAtMs = nil, lastError = nil,
        budgetOwner = tostring(moduleId) .. ":" .. tostring(name),
        pending = runImmediately == true, dueSinceMs = runImmediately == true and (S.NowMs and S.NowMs() or 0) or nil,
    }
    return true
end

function Scheduler:AddTask(name, intervalMs, callback, runImmediately, owner, priority, costUnits)
    return AddTaskInternal(self, name, intervalMs, callback, runImmediately, owner, priority, costUnits, "background")
end

-- 高频输入采样与普通周期任务分开；仅拖动、缩放、滚动等有界用户交互使用此通道，手势结束必须移除任务。维持单
-- 一 OnUpdate，不能让每个 Service 静默变成 16ms 任务。
function Scheduler:AddInteractiveTask(name, intervalMs, callback, runImmediately, owner, priority, costUnits)
    return AddTaskInternal(self, name, intervalMs, callback, runImmediately, owner, priority or "P0", costUnits or 1, "interactive")
end

-- 帧节奏视觉通道用于单位连线、头顶标记、施法条，接收最低 1ms 且不静默抬高，实际节奏仍由帧循环决定。任务不参
-- 与 backlog 健康分类，因为 1ms 任务每帧必然迟到，不能污染其他通道共享遥测。
function Scheduler:AddHighFrequencyTask(name, intervalMs, callback, runImmediately, owner, priority, costUnits)
    return AddTaskInternal(self, name, intervalMs, callback, runImmediately, owner, priority or "P1", costUnits or 1, "highfrequency")
end

-- 帧节奏通道上的有界一次任务最小延迟 1ms，用于不能等待后台 50ms 下限的视觉反应。
function Scheduler:AddHighFrequencyOneShot(name, delayMs, callback, owner, priority, costUnits)
    if type(name) ~= "string" or name == "" or type(callback) ~= "function" then return false end
    -- 旧 one-shot 闭包无权删除后来同名任务；先验证注册实例，再移除，再调业务。
    -- 允许业务回调安全地重新注册同名任务；返回值/Owner/优先级兼容原接口。
    local scheduler, registeredTask = self, nil
    local added = self:AddHighFrequencyTask(name, math.max(HIGHFREQUENCY_MIN_INTERVAL_MS, Finite(delayMs, HIGHFREQUENCY_MIN_INTERVAL_MS)), function()
        if registeredTask == nil or scheduler.tasks[name] ~= registeredTask then return false end
        scheduler:RemoveTask(name)
        return callback()
    end, false, owner, priority or "P1", costUnits or 1)
    if added == true then registeredTask = self.tasks[name] end
    return added
end

local function TaskInterval(task)
    local lane = type(task) == "table" and task.lane or "background"
    local minimum = lane == "interactive" and INTERACTIVE_MIN_INTERVAL_MS
        or (lane == "highfrequency" and HIGHFREQUENCY_MIN_INTERVAL_MS or BACKGROUND_MIN_INTERVAL_MS)
    return math.max(minimum, Finite(task and task.intervalMs, 1000))
end

-- 显式设置只调整现有任务的间隔/视觉通道，保留实例、回调、模块与断路器状态；不重建任务或新增 OnUpdate。
-- 高频选项只能由绘制设置入口使用；业务扫描、原生写操作及其冷却不得通过本接口提速。
function Scheduler:SetTaskInterval(name, intervalMs, highFrequency)
    local task=self.tasks[name]
    local value=tonumber(intervalMs)
    if not task or not value or value~=value or value<1 or value>60000 then return false,"invalid_task_interval" end
    if highFrequency==true then task.lane="highfrequency" end
    task.intervalMs=math.floor(value)
    task.elapsedMs=math.min(tonumber(task.elapsedMs) or 0,TaskInterval(task))
    return true
end

-- 有界一次任务共用同一 Scheduler，用户回调执行前先删除任务，防止异常或重入遗留僵尸计时器。用于 UI 通知、延
-- 迟提交等有限工作；Feature 周期任务继续 AddTask。
function Scheduler:AddOneShot(name, delayMs, callback, owner, priority, costUnits)
    if type(name) ~= "string" or name == "" or type(callback) ~= "function" then return false end
    -- 与高频 one-shot 共用实例所有权规则，旧闭包不能撤销同名后继任务。
    local scheduler, registeredTask = self, nil
    local added = self:AddTask(name, math.max(50, Finite(delayMs, 50)), function()
        if registeredTask == nil or scheduler.tasks[name] ~= registeredTask then return false end
        scheduler:RemoveTask(name)
        return callback()
    end, false, owner, priority or "P3", costUnits or 1)
    if added == true then registeredTask = self.tasks[name] end
    return added
end

function Scheduler:RemoveTask(name)
    name = tostring(name or "")
    self.tasks[name] = nil
    -- 静态 task->module 映射登记一次并跨普通 stop/start 保留；动态调用者须选择瞬态所有权，避免唯一一次任务
    -- 名称泄漏整会话元数据。
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
        -- Owner 显式暂停优先于后台异常恢复；保留 fault 信息供只读诊断。
        -- 显式恢复只清本次熔断窗口，不清累计 failureTotal/resumeCount，避免掩盖历史故障。
        task.manuallyDisabled = enabled ~= true
        task.enabled = enabled == true
        if task.enabled ~= true then task.pending = false; task.dueSinceMs = nil; task.deferCount = 0
        elseif task.faultedAtMs ~= nil then task.faultedAtMs = nil; task.failureCount = 0 end
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
    local now = S.NowMs and S.NowMs() or 0
    task.runCount = (tonumber(task.runCount) or 0) + 1
    task.lastRunAtMs = now
    local moduleId = self.taskModules[tostring(name)] or "suite"
    local token = S.PerformanceMonitor and S.PerformanceMonitor:Begin("task:" .. tostring(name), moduleId) or nil
    local ok, err = xpcall(task.callback, S.SafeTraceback)
    if S.PerformanceMonitor ~= nil then S.PerformanceMonitor:End(token) end
    if ok then
        task.failureCount = 0
        task.lastSuccessAtMs = now
        return true
    end
    task.failureCount = (tonumber(task.failureCount) or 0) + 1
    task.failureTotal = (tonumber(task.failureTotal) or 0) + 1
    task.lastErrorAtMs = now
    task.lastError = tostring(err or "unknown")
    S.LastSchedulerError = { task = tostring(name), error = task.lastError, failures = task.failureCount }
    if task.failureCount >= 3 then
        -- 触发熔断仍保留有界自动恢复；暂时原生错误不能让视觉任务永久冻结而仅有一条聊天警告。退避从 2s 倍增
        -- 至 60s，上限使持续故障每分钟最多尝试一次，暂时原因可自愈。
        task.enabled = false
        task.pending = false
        task.dueSinceMs = nil
        task.faultedAtMs = (S.NowMs and S.NowMs() or 0)
        task.resumeCount = (tonumber(task.resumeCount) or 0) + 1
        S.WarnOnce("scheduler_fault:" .. tostring(name), "后台任务连续异常已暂停，将自动退避重启：" .. tostring(name))
    end
    return false
end

local function FaultResumeDelayMs(resumeCount)
    -- 恢复窗口从 2s 开始，按 4s/8s/16s/32s 倍增，上限 60s。
    local shift = math.max(0, math.min((tonumber(resumeCount) or 1) - 1, 5))
    return math.min(60000, 2000 * (2 ^ shift))
end

function Scheduler:RecoverFaultedTasks(now)
    local recovered = 0
    for _, task in pairs(self.tasks) do
        -- 只有熔断器暂停的任务可自动恢复；手动暂停即使保留 fault 证据也不得重启。
        if task.enabled ~= true and task.manuallyDisabled ~= true and task.faultedAtMs ~= nil
            and (tonumber(now) or 0) - task.faultedAtMs >= FaultResumeDelayMs(task.resumeCount) then
            task.enabled = true
            task.faultedAtMs = nil
            task.failureCount = 0
            task.elapsedMs = 0
            recovered = recovered + 1
        end
    end
    if recovered > 0 then
        self.faultResumes = (tonumber(self.faultResumes) or 0) + recovered
    end
    return recovered
end

-- 公开任务遥测只读；Diagnostics 不得访问任务表 callback/owner。快照仅暴露生命周期与性能事实，执行权威保持私有。
function Scheduler:GetTaskState(name)
    name = tostring(name or "")
    local task = self.tasks[name]
    if task == nil then return { name=name, registered=false } end
    return {
        -- 只读区分手动暂停与熔断暂停，不暴露 callback/Owner 或触发恢复。
        name=name, registered=true, enabled=task.enabled == true, manuallyDisabled=task.manuallyDisabled == true, lane=tostring(task.lane or "background"),
        intervalMs=tonumber(task.intervalMs) or 0, priority=tonumber(task.priority) or 3,
        pending=task.pending == true, runCount=tonumber(task.runCount) or 0,
        elapsedMs=tonumber(task.elapsedMs) or 0,dueSinceMs=task.dueSinceMs,deferCount=tonumber(task.deferCount) or 0,starvationDue=task.pending==true and task.starvationDue==true, -- 只读等待证据，让 TXT 能区分未到期、连续被预算延期和已满足公
                                                                                                                                                                                    -- 平执行阈值；已执行任务不能保留“仍在等待”的标志。
        failureCount=tonumber(task.failureCount) or 0, failureTotal=tonumber(task.failureTotal) or 0,
        faultedAtMs=tonumber(task.faultedAtMs), resumeCount=tonumber(task.resumeCount) or 0,
        lastRunAtMs=tonumber(task.lastRunAtMs), lastSuccessAtMs=tonumber(task.lastSuccessAtMs),
        lastErrorAtMs=tonumber(task.lastErrorAtMs), lastError=task.lastError,
    }
end
Scheduler.TaskStateDiagnosticsContractVersion = 1

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
        lifecycleContractVersion = self.lifecycleContractVersion, -- 只读执行隔离契约，不改变任务状态。
        faultResumes = tonumber(self.faultResumes) or 0,
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
    -- 不能只比较 Generation；同代重启后，无法解绑的旧 Native driver 仍可能回调。
    self.runEpoch = self.runEpoch + 1
    local epoch = self.runEpoch
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
        if S.Generation ~= generation or Scheduler.running ~= true or Scheduler.driver ~= driver or Scheduler.runEpoch ~= epoch then return end
        local rawElapsed = ReadDeltaMs(dt)
        local elapsed = NormalizeDelta(dt)
        if elapsed <= 0 then return end
        if S.PerformanceMonitor ~= nil then S.PerformanceMonitor:BeginFrame(rawElapsed, 0) end
        if S.AdvanceClock ~= nil then S.AdvanceClock(elapsed) end
        local now = S.NowMs and S.NowMs() or 0

        -- 先只更新时间状态；回调可添加或移除任务，不能在遍历权威表时执行。复用 scratch 数组，逐帧处理器在没
        -- 有到期任务时不新建表或比较器闭包。
        local dueTasks = Scheduler.dueScratch
        for index = #dueTasks, 1, -1 do dueTasks[index] = nil end
        Scheduler:RecoverFaultedTasks(now)
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
                    dueTasks[#dueTasks + 1] = task
                    local budget=S.FrameBudget
                    task.starvationDue=budget~=nil and type(budget.IsStarving)=="function"
                        and budget:IsStarving(task.priority,task.deferCount,math.max(0,task.elapsedMs-interval)/interval)==true -- 同一 due 集合内缓存排序键，判定仍归 Broker。
                    -- 比较器不修改统计或读取时钟；高频任务每帧必然到期，不计迟到，避免污染共享 backlog 健康分类。
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

        if #dueTasks > 1 then table.sort(dueTasks, CompareDueTasks) end
        local dueCount = #dueTasks

        local health = ClassifyBacklog(pendingCount, maxLateRatio)
        local frameBudget = S.FrameBudget
        if frameBudget ~= nil and type(frameBudget.BeginFrame) == "function" then
            frameBudget:BeginFrame(rawElapsed, health, pendingCount)
        end
        local fallbackBudget = FALLBACK_HEALTH_BUDGET[health] or 8
        local executed, deferredByBudget = 0, 0
        for index = 1, dueCount do
            -- 回调可 Stop/Start/RemoveOwner；旧帧不得读取新代 scratch 或提交旧遥测。
            if S.Generation ~= generation or Scheduler.runEpoch ~= epoch or Scheduler.driver ~= driver or Scheduler.running ~= true then break end
            local task = dueTasks[index]
            local name = task and task.name
            if task ~= nil and Scheduler.tasks[name] == task and task.enabled == true and task.pending == true then
                local interval = TaskInterval(task)
                local lateMs = math.max(0, (tonumber(task.elapsedMs) or interval) - interval)
                local lateRatio = lateMs / interval
                local allowed = executed < fallbackBudget
                if frameBudget ~= nil and type(frameBudget.Request) == "function" then
                    allowed = frameBudget:Request(task.budgetOwner or tostring(name), task.priority, task.costUnits, task.deferCount, lateRatio, task.lane) == true
                end
                if allowed then
                    -- 消费一次周期发生；卡顿后同帧不执行多次追赶回调。
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
        -- 中途重载也必须结束旧帧；仅清理仍属本 Epoch 的 scratch，不碰重启后的工作集。
        if S.Generation ~= generation or Scheduler.runEpoch ~= epoch or Scheduler.driver ~= driver or Scheduler.running ~= true then
            if Scheduler.runEpoch == epoch then
                for index = 1, dueCount do dueTasks[index] = nil end
            end
            return
        end
        -- HF 执行不能减掉普通任务积压；回调取消/替换的任务也不再算 pending。
        -- 仅二次检查本帧 due 快照，边统计边清引用；不重新全扫描 tasks，不保留已释放 Owner。
        local pendingAfter = 0
        for index = 1, dueCount do
            local task = dueTasks[index]
            if task ~= nil and Scheduler.tasks[task.name] == task and task.enabled == true
                and task.pending == true and task.lane ~= "highfrequency" then pendingAfter = pendingAfter + 1 end
            dueTasks[index] = nil
        end
        local backlog = Scheduler.backlog
        backlog.health = health
        backlog.pending = pendingAfter
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
    -- 先撤销旧帧/旧 Native 闭包权限；即使当前业务回调同步重启也不能续跑旧快照。
    self.runEpoch = self.runEpoch + 1
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

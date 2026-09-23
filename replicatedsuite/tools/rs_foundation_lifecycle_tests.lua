------------------------------------------------------------------------
-- 底层生命周期回归：真实 Events / Scheduler / RefreshCoordinator；仅 Native
-- Host、单调时钟、遥测为替身。开发期独立入口，不进 toc.g，不读取用户存档。
-- Authority：取消属于 Owner，分发/任务执行属于 Core；替身不实现被测调度逻辑。
-- 维护：这些测试证明同步回调中的重入/释放边界，不等同 RU 真机或网络验收。
------------------------------------------------------------------------
local passed, failed = 0, 0
local function Test(name, callback)
    local ok, err = xpcall(callback, function(e) return tostring(e) .. "\n" .. debug.traceback() end)
    if ok then passed = passed + 1; print("PASS foundation-lifecycle " .. name)
    else failed = failed + 1; print("FAIL foundation-lifecycle " .. name .. ": " .. tostring(err)) end
end
local function Equal(actual, expected, message)
    assert(actual == expected, (message or "unexpected value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
local function Boot()
    local clock, hosts, diagnostics = 0, {}, {}
    local S = { Generation = 1, SafeTraceback = function(e) return tostring(e) end }
    ReplicatedSuite = S
    S.NowMs = function() return clock end
    S.AdvanceClock = function(dt) clock = clock + dt end
    S.PhysicalId = function(id) return id end
    S.SafeChat = function() end
    S.WarnOnce = function() end
    local function CreateHost()
        local host = { handlers = {}, registered = {} }
        function host:SetHandler(name, callback) self.handlers[name] = callback; return true end
        function host:RegisterEvent(name) self.registered[name] = true; return true end
        -- 故意不提供 ReleaseHandler/UnregisterEvent，覆盖 RU 能力缺失与迟到回调。
        function host:Show() return true end
        function host:SetExtent() return true end
        function host:AddAnchor() return true end
        hosts[#hosts + 1] = host
        return host
    end
    S.NativeObjectFactory = { CreateWindow = CreateHost, CreateEmptyWidget = CreateHost }
    S.DiagnosticsManager = {
        RateLimited = function(_, level, source, code, _, message, context)
            diagnostics[#diagnostics + 1] = { level = level, source = source, code = code, message = message, context = context }
        end,
    }
    dofile("core/rs_events.lua")
    dofile("core/rs_scheduler.lua")
    dofile("core/rs_refresh_coordinator.lua")
    local function Tick(dt)
        local driver = assert(S.Scheduler.driver, "scheduler driver required")
        driver.handlers.OnUpdate(driver, dt or 50)
    end
    return S, Tick, hosts, diagnostics
end

-- 取消与快照：新增订阅从下一次事件开始；已取消订阅不能消费在途事件。
for _, native in ipairs({ false, true }) do
    local mode = native and "native" or "internal"
    local subscribe = native and "Subscribe" or "SubscribeInternal"
    local unsubscribe = native and "Unsubscribe" or "UnsubscribeInternal"
    local release = native and "UnsubscribeOwner" or "UnsubscribeInternalOwner"
    local publish = native and "Dispatch" or "Publish"
    Test(mode .. " unsubscribe before turn fences callback", function()
        local S = Boot(); local E, owner, called = S.Events, {}, 0
        E[subscribe](E, "test", {}, function() E[unsubscribe](E, "test", owner) end)
        E[subscribe](E, "test", owner, function() called = called + 1 end)
        E[publish](E, "test")
        Equal(called, 0, "released listener executed from old list")
    end)
    Test(mode .. " owner release before turn fences callback", function()
        local S = Boot(); local E, owner, called = S.Events, {}, 0
        E[subscribe](E, "test", {}, function() E[release](E, owner) end)
        E[subscribe](E, "test", owner, function() called = called + 1 end)
        E[publish](E, "test")
        Equal(called, 0, "released owner received event")
    end)
    Test(mode .. " new subscriber waits for next event", function()
        local S = Boot(); local E, added, called = S.Events, false, 0
        E[subscribe](E, "test", {}, function()
            if not added then added = true; E[subscribe](E, "test", {}, function() called = called + 1 end) end
        end)
        E[publish](E, "test"); Equal(called, 0)
        E[publish](E, "test"); Equal(called, 1)
    end)
    Test(mode .. " release and resubscribe cannot revive old listener", function()
        local S = Boot(); local E, owner, changed, oldCalls, newCalls = S.Events, {}, false, 0, 0
        E[subscribe](E, "test", {}, function()
            if not changed then
                changed = true; E[release](E, owner)
                E[subscribe](E, "test", owner, function() newCalls = newCalls + 1 end)
            end
        end)
        E[subscribe](E, "test", owner, function() oldCalls = oldCalls + 1 end)
        E[publish](E, "test"); Equal(oldCalls, 0); Equal(newCalls, 0)
        E[publish](E, "test"); Equal(newCalls, 1)
    end)
    Test(mode .. " Stop fences in-flight snapshot", function()
        local S = Boot(); local E, called = S.Events, 0
        E[subscribe](E, "test", {}, function() E:Stop() end)
        E[subscribe](E, "test", {}, function() called = called + 1 end)
        E[publish](E, "test"); Equal(called, 0, "stopped event bus kept delivering")
    end)
    Test(mode .. " owner-first nil-preserving delivery", function()
        local S = Boot(); local E, owner, called = S.Events, {}, 0
        E[subscribe](E, "test", owner, function(actualOwner, ...)
            Equal(actualOwner, owner); Equal(select("#", ...), 4)
            local a, b, c, d = ...; Equal(a, 7); Equal(b, nil); Equal(c, false); Equal(d, nil)
            called = called + 1
        end)
        E[publish](E, "test", 7, nil, false, nil); Equal(called, 1)
    end)
    Test(mode .. " failing callback does not skip healthy subscribers", function()
        local S = Boot(); local E, called = S.Events, 0
        E[subscribe](E, "test", {}, function() error("injected listener failure") end)
        E[subscribe](E, "test", {}, function() called = called + 1 end)
        E[publish](E, "test"); Equal(called, 1)
    end)
end
Test("native old host remains fenced across same-generation restart", function()
    local S = Boot(); local E, called = S.Events, 0
    E:Subscribe("test", {}, function() end); assert(E:Start())
    local oldHost = E.host
    E:Stop(); E:Subscribe("test", {}, function() called = called + 1 end); assert(E:Start())
    oldHost.handlers.OnEvent(oldHost, "test"); Equal(called, 0, "old host became live after restart")
    E.host.handlers.OnEvent(E.host, "test"); Equal(called, 1)
end)
Test("internal nested publish respects cancellation", function()
    local S = Boot(); local E, owner, nested, called = S.Events, {}, false, 0
    E:SubscribeInternal("test", {}, function()
        if not nested then nested = true; E:UnsubscribeInternalOwner(owner); E:Publish("test") end
    end)
    E:SubscribeInternal("test", owner, function() called = called + 1 end)
    E:Publish("test"); Equal(called, 0)
end)

Test("manual pause overrides fault auto-recovery", function()
    local S = Boot(); local Q = S.Scheduler
    assert(Q:AddTask("fault", 50, function() error("injected fault") end))
    for _ = 1, 3 do assert(not Q:RunTask("fault")) end
    assert(Q:GetTaskState("fault").faultedAtMs ~= nil)
    Q:SetEnabled("fault", false); Q:RecoverFaultedTasks(100000)
    Equal(Q:GetTaskState("fault").enabled, false, "explicit pause was overridden")
end)
Test("fault still auto-recovers when owner did not pause", function()
    local S = Boot(); local Q = S.Scheduler
    Q:AddTask("fault", 50, function() error("injected fault") end)
    for _ = 1, 3 do Q:RunTask("fault") end
    Equal(Q:RecoverFaultedTasks(1999), 0); Equal(Q:RecoverFaultedTasks(2000), 1)
    Equal(Q:GetTaskState("fault").enabled, true)
end)
Test("explicit resume clears breaker window but retains cumulative failures", function()
    local S = Boot(); local Q, broken = S.Scheduler, true
    Q:AddTask("fault", 50, function() if broken then error("injected fault") end end)
    for _ = 1, 3 do Q:RunTask("fault") end
    Q:SetEnabled("fault", false); broken = false; Q:SetEnabled("fault", true)
    Equal(Q:GetTaskState("fault").faultedAtMs, nil, "manual resume kept stale breaker")
    Equal(Q:GetTaskState("fault").failureTotal, 3); assert(Q:RunTask("fault"))
end)
Test("same-name replacement waits for next frame", function()
    local S, Tick = Boot(); local Q, called = S.Scheduler, 0
    Q:AddOneShot("a", 50, function()
        Q:AddTask("b", 50, function() called = called + 1 end, true)
    end, nil, "P0")
    Q:AddTask("b", 50, function() error("old task must be replaced") end, true)
    assert(Q:Start()); Tick(50); Equal(called, 0, "new task consumed old task's due slot")
    Tick(50); Equal(called, 1)
end)
Test("old scheduler driver stays fenced after same-generation restart", function()
    local S = Boot(); local Q, called = S.Scheduler, 0
    assert(Q:Start()); local oldDriver = Q.driver
    Q:Stop(); Q:AddTask("new", 50, function() called = called + 1 end, true); assert(Q:Start())
    oldDriver.handlers.OnUpdate(oldDriver, 50); Equal(called, 0, "old driver executed new tasks")
    Q.driver.handlers.OnUpdate(Q.driver, 50); Equal(called, 1)
end)
Test("restart inside callback cannot reuse remaining due slots", function()
    local S, Tick = Boot(); local Q, called = S.Scheduler, 0
    Q:AddOneShot("a", 50, function()
        Q:Stop(); Q:AddTask("b", 50, function() called = called + 1 end, true); assert(Q:Start())
    end, nil, "P0")
    Q:AddTask("b", 50, function() error("old b must not execute") end, true)
    assert(Q:Start()); Tick(50); Equal(called, 0)
    Equal(Q:DescribeBacklog().executedLastFrame, 0, "old frame overwrote restarted telemetry")
    Tick(50); Equal(called, 1)
end)
Test("highfrequency execution does not erase deferred background backlog", function()
    local S, Tick = Boot(); local Q, finalPending = S.Scheduler, nil
    S.FrameBudget = {
        BeginFrame = function() end,
        Request = function(_, _, priority) return priority == 1 end,
        EndFrame = function(_, pending) finalPending = pending end,
    }
    Q:AddHighFrequencyTask("visual", 1, function() end, true)
    Q:AddTask("background", 50, function() error("budget must defer background") end, true)
    assert(Q:Start()); Tick(50)
    Equal(Q:DescribeBacklog().pending, 1, "visual execution subtracted background backlog")
    Equal(finalPending, 1); Equal(Q:DescribeBacklog().deferredByBudget, 1)
end)
Test("task numeric inputs are finite before sorting and scheduling", function()
    local S = Boot(); local Q = S.Scheduler
    Q:AddTask("nan", 0/0, function() end, false, nil, 0/0, 0/0)
    local task = Q.tasks.nan
    Equal(task.priority, 3, "NaN priority escaped normalization")
    Equal(task.intervalMs, 1000); Equal(task.costUnits, 1)
    Q:SetPriority("nan", math.huge); Q:SetCost("nan", math.huge)
    Equal(task.priority, 3); Equal(task.costUnits, 1)
end)
Test("one-shot removes before callback and preserves self-reschedule", function()
    local S = Boot(); local Q, called = S.Scheduler, 0
    Q:AddOneShot("one", 50, function()
        assert(not Q:GetTaskState("one").registered)
        Q:AddOneShot("one", 50, function() called = called + 1 end)
    end)
    assert(Q:RunTask("one")); assert(Q:GetTaskState("one").registered)
    assert(Q:RunTask("one")); Equal(called, 1); assert(not Q:GetTaskState("one").registered)
end)
Test("owner release clears transient task mapping", function()
    local S = Boot(); local Q, owner = S.Scheduler, {}
    Q:AddTask("one", 50, function() end, true, owner)
    Q:SetTaskModule("one", "test", true)
    Equal(Q:RemoveOwner(owner), 1); Equal(Q:GetHealth().transientOrphans, 0)
    Equal(Q:GetHealth().transientMappings, 0)
end)

Test("continuous refresh requests cannot starve default deadline", function()
    local S, Tick = Boot(); local R, owner, called = S.RefreshCoordinator, {}, 0
    assert(S.Scheduler:Start())
    for _ = 1, 80 do
        assert(R:Request({ owner = owner, key = "quest", delayMs = 200, callback = function() called = called + 1 end }))
        Tick(50)
    end
    assert(called >= 3, "continuous stream postponed every refresh: " .. tostring(called))
end)
Test("explicit maximum wait caps trailing debounce", function()
    local S, Tick = Boot(); local R, owner, called = S.RefreshCoordinator, {}, 0
    assert(S.Scheduler:Start())
    for _ = 1, 7 do
        R:Request({ owner = owner, key = "test", delayMs = 200, maxWaitMs = 300, callback = function() called = called + 1 end })
        Tick(50)
    end
    assert(called >= 1, "requested maxWaitMs ignored")
end)
Test("short burst remains trailing-edge and carries latest callback and reasons", function()
    local S, Tick = Boot(); local R, owner, called = S.RefreshCoordinator, {}, 0
    assert(S.Scheduler:Start())
    R:Request({ owner = owner, key = "test", reason = "first", delayMs = 200, callback = function() error("old callback") end })
    Tick(50)
    R:Request({ owner = owner, key = "test", reason = "last", delayMs = 200, callback = function(reasons, latest)
        assert(reasons.first and reasons.last); Equal(latest, "last"); called = called + 1
    end })
    for _ = 1, 3 do Tick(50) end
    Equal(called, 0); Tick(50); Equal(called, 1)
    Equal(R:Describe().pending, 0); Equal(S.Scheduler:GetHealth().transientMappings, 0)
end)
Test("cancelled refresh callback is inert even when retained", function()
    local S = Boot(); local R, owner, called = S.RefreshCoordinator, {}, 0
    R:Request({ owner = owner, key = "test", callback = function() called = called + 1 end })
    local name; for key in pairs(S.Scheduler.tasks) do name = key end
    local callback = S.Scheduler.tasks[name].callback
    assert(R:Cancel(owner, "test")); callback()
    Equal(called, 0, "cancelled state retained execution authority")
end)
Test("callback can request next refresh without losing new state", function()
    local S = Boot(); local R, owner, called = S.RefreshCoordinator, {}, 0
    R:Request({ owner = owner, key = "test", callback = function()
        R:Request({ owner = owner, key = "test", callback = function() called = called + 1 end })
    end })
    local first; for key in pairs(S.Scheduler.tasks) do first = key end
    assert(S.Scheduler:RunTask(first)); Equal(R:Describe().pending, 1)
    local second; for key in pairs(S.Scheduler.tasks) do second = key end
    assert(second ~= first); assert(S.Scheduler:RunTask(second)); Equal(called, 1); Equal(R:Describe().pending, 0)
end)
Test("cancel owner preserves other owner's refresh", function()
    local S = Boot(); local R, a, b, called = S.RefreshCoordinator, {}, {}, 0
    R:Request({ owner = a, key = "test", callback = function() error("cancelled owner") end })
    R:Request({ owner = b, key = "test", callback = function() called = called + 1 end })
    Equal(R:CancelOwner(a), 1); Equal(R:Describe().pending, 1)
    local name; for key in pairs(S.Scheduler.tasks) do name = key end
    assert(S.Scheduler:RunTask(name)); Equal(called, 1)
end)
Test("missing scheduler retains synchronous fallback", function()
    local S = Boot(); local called = 0; S.Scheduler = nil
    assert(S.RefreshCoordinator:Request({ key = "test", callback = function() called = called + 1 end }))
    Equal(called, 1); Equal(S.RefreshCoordinator:Describe().pending, 0)
end)
-- 保留旧闭包是故障注入：旧 one-shot 不得删除后来同名任务，Native 延迟回调无生命周期信任权。
for _, method in ipairs({ "AddOneShot", "AddHighFrequencyOneShot" }) do
    Test(method .. " retained old callback cannot remove replacement", function()
        local S = Boot(); local Q, oldCalls, newCalls = S.Scheduler, 0, 0
        Q[method](Q, "one", 50, function() oldCalls = oldCalls + 1 end)
        local old = Q.tasks.one.callback
        Q[method](Q, "one", 50, function() newCalls = newCalls + 1 end)
        old(); Equal(oldCalls, 0); assert(Q:GetTaskState("one").registered, "old callback deleted replacement")
        assert(Q:RunTask("one")); Equal(newCalls, 1)
    end)
end
Test("refresh stream faster than delay floor still drains", function()
    local S, Tick = Boot(); local R, owner, called = S.RefreshCoordinator, {}, 0
    assert(S.Scheduler:Start())
    for _ = 1, 250 do
        R:Request({ owner = owner, key = "test", delayMs = 200, callback = function() called = called + 1 end })
        Tick(16)
    end
    assert(called >= 3, "delay floor repeatedly reset the expired deadline: " .. tostring(called))
end)
Test("cancelled same-frame owner cannot create zombie scheduler work", function()
    local S, Tick = Boot(); local E, Q, owner, ran = S.Events, S.Scheduler, {}, 0
    E:SubscribeInternal("close", {}, function() E:UnsubscribeInternalOwner(owner); Q:RemoveOwner(owner) end)
    E:SubscribeInternal("close", owner, function()
        Q:AddTask("zombie", 50, function() ran = ran + 1 end, true, owner)
    end)
    assert(Q:Start()); E:Publish("close"); Tick(50)
    Equal(ran, 0); assert(not Q:GetTaskState("zombie").registered)
end)
Test("refresh cancellation does not trust a non-cancellable timer transport", function()
    local S = Boot(); local retained, called, owner = nil, 0, {}
    -- 故障注入：运输层无法真正取消回调；Coordinator 必须独立撤销 owner+key 状态。
    S.Scheduler = { RemoveTask = function() end, AddOneShot = function(_, _, _, callback) retained = callback; return true end }
    S.RefreshCoordinator:Request({ owner = owner, key = "test", callback = function() called = called + 1 end })
    assert(S.RefreshCoordinator:Cancel(owner, "test")); retained()
    Equal(called, 0, "timer transport retained authority after coordinator cancel")
end)
-- 重载故障注入：即便上层未走完整 Stop，Generation 改变也必须中止在途工作。
for _, native in ipairs({ false, true }) do
    Test((native and "native" or "internal") .. " generation change fences remaining listeners", function()
        local S = Boot(); local E, called = S.Events, 0
        local subscribe = native and "Subscribe" or "SubscribeInternal"
        local publish = native and "Dispatch" or "Publish"
        E[subscribe](E, "reload", {}, function() S.Generation = S.Generation + 1 end)
        E[subscribe](E, "reload", {}, function() called = called + 1 end)
        E[publish](E, "reload"); Equal(called, 0)
    end)
end
Test("generation change inside a task aborts old frame", function()
    local S, Tick = Boot(); local Q, called = S.Scheduler, 0
    Q:AddOneShot("a", 50, function() S.Generation = S.Generation + 1 end, nil, "P0")
    Q:AddTask("b", 50, function() called = called + 1 end, true)
    assert(Q:Start()); Tick(50); Equal(called, 0)
end)
print("FOUNDATION LIFECYCLE RESULT " .. passed .. " passed / " .. failed .. " failed (" .. _VERSION .. ")")
if failed > 0 then error("foundation lifecycle failures: " .. failed) end

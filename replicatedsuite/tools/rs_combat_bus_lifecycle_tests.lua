-- Replicated Suite · 战斗总线租约与订阅同步回归
-- 真实 Demand / Events / CombatBus；Native 宿主仅提供受控释放失败。
-- 强制静默撤销的是旧订阅执行权，后来消费者重启总线不能唤醒旧回调；不读写玩家 UDF。
local passed, failed = 0, 0
local function Test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then passed = passed + 1; print('PASS combat-bus-lifecycle ' .. name)
    else failed = failed + 1; print('FAIL combat-bus-lifecycle ' .. name .. ': ' .. tostring(err)) end
end
local function Copy(value)
    if type(value) ~= 'table' then return value end
    local out = {}; for key, item in pairs(value) do out[key] = Copy(item) end; return out
end
local function Boot()
    local h = { failRelease = false }
    local S = { Generation = 7, Services = {}, Utils = { DeepCopy = Copy }, SafeTraceback = debug.traceback,
        NowMs = function() return 1000 end, PhysicalId = function(id) return id end }
    ReplicatedSuite = S
    S.NativeObjectFactory = { CreateWindow = function()
        local host = { handlers = {} }
        function host:SetHandler(key, callback) self.handlers[key] = callback; return true end
        function host:ReleaseHandler(key) self.handlers[key] = nil; return true end
        function host:RegisterEvent() return true end
        function host:UnregisterEvent(name) return not (h.failRelease and name == 'COMBAT_MSG') end
        function host:Show() return true end
        return host
    end }
    S.Services.UnitIdentityV3 = { IsPlayerName = function(_, name) return name == 'Self' end,
        RefreshPlayerIdentity = function() return { name = 'Self' } end }
    dofile('core/rs_demand.lua'); dofile('core/rs_events.lua'); assert(S.Events:Start())
    dofile('services/rs_combat_event_bus_v3.lua')
    h.S, h.bus = S, S.Services.CombatEventBusV3
    function h:Emit() return self.bus:_OnCombatRaw('private', nil, 'SPELL_DAMAGE', 'Self', 'Victim', 11, 'Hit', 0, 10, true) end
    return h
end
for _, force in ipairs({ false, true }) do
    Test((force and 'forced' or 'ordinary global') .. ' clear cannot revive previous subscribers on restart', function()
        local h = Boot(); local Q = h.bus; local a, b, c, old, fresh = {}, {}, {}, 0, 0
        assert(Q:Subscribe(a, function() old = old + 1 end, { scope = 'self' }))
        assert(Q:Subscribe(b, function() old = old + 1 end, { scope = 'self' }))
        if force then assert(Q.demand:ForceQuiesce('test')) else assert(h.S.Demand:ClearAll('test')) end
        assert(Q.demand.count == 0)
        assert(Q:Subscribe(c, function() fresh = fresh + 1 end, { scope = 'self' })); h:Emit()
        assert(old == 0 and fresh == 1, 'restart reactivated callbacks whose demand was already revoked')
        assert(Q.subscriberCount == 1 and #Q.subscriberOrder == 1, 'revoked callback records retained ownership')
    end)
end
Test('caller can finish releasing after Bus demand was globally quiesced', function()
    local h = Boot(); local Q, owner = h.bus, {}
    assert(Q:Subscribe(owner, function() end)); assert(Q.demand:ForceQuiesce('test'))
    assert(Q:Unsubscribe(owner), 'upper service cannot acknowledge an already revoked subscription')
    assert(Q:Unsubscribe(owner)); assert(Q.subscriberCount == 0 and next(Q.subscribers) == nil)
end)
Test('real analytics releases and restarts after its Bus subscription was revoked', function()
    local h = Boot(); local Q = h.bus
    dofile('services/rs_combat_analytics_v3.lua')
    local analytics = h.S.Services.CombatAnalyticsV3
    assert(analytics:RegisterMetric({ id = 'lifecycle', OnFact = function() return false end }))
    assert(analytics:AcquireConsumer('test', { metrics = { 'lifecycle' } }))
    assert(analytics.busSubscribed and Q.subscribers[analytics])
    assert(Q.demand:ForceQuiesce('global_child_cleanup'))
    assert(analytics:ReleaseConsumer('test'), 'real upper service stayed stuck on a revoked child token')
    assert(not analytics.busSubscribed and not analytics.Demand:Has('test'))
    assert(analytics:AcquireConsumer('test', { metrics = { 'lifecycle' } }))
    local before = analytics.factsReceived; h:Emit()
    assert(analytics.factsReceived == before + 1 and Q.subscriberCount == 1)
    assert(analytics:ReleaseConsumer('test')); assert(Q.subscriberCount == 0)
end)
Test('quiesce in callback cancels the in-flight tail and new subscribers wait', function()
    local h = Boot(); local Q = h.bus; local a, b, c, tail, fresh = {}, {}, {}, 0, 0
    assert(Q:Subscribe(a, function()
        assert(Q.demand:ForceQuiesce('in_callback'))
        assert(Q:Subscribe(c, function() fresh = fresh + 1 end))
    end))
    assert(Q:Subscribe(b, function() tail = tail + 1 end))
    h:Emit(); assert(tail == 0 and fresh == 0, 'old snapshot delivered to revoked/new owner')
    h:Emit(); assert(fresh == 1 and tail == 0)
end)
Test('failed ordinary release preserves the subscriber for transaction rollback and retry', function()
    local h = Boot(); local Q, owner, called = h.bus, {}, 0
    assert(Q:Subscribe(owner, function() called = called + 1 end))
    h.failRelease = true; assert(Q:Unsubscribe(owner) == false)
    assert(Q.subscriberCount == 1 and Q.demand.count == 1 and Q.subscribers[owner].active)
    h:Emit(); assert(called == 1, 'ordinary failed release cancelled the restored owner')
    h.failRelease = false; assert(Q:Unsubscribe(owner)); assert(Q.subscriberCount == 0 and Q.demand.count == 0)
end)
Test('failed forced release revokes callback authority and can retry Native cleanup', function()
    local h = Boot(); local Q, owner, called = h.bus, {}, 0
    assert(Q:Subscribe(owner, function() called = called + 1 end)); local old = Q.subscribers[owner]
    h.failRelease = true; assert(Q.demand:ForceQuiesce('test') == false)
    assert(not old.active and Q.subscriberCount == 0 and Q.demand.needsQuiesce, 'failed force cleanup retained executable owner')
    assert(Q:Subscribe({}, function() end) == false, 'restart bypassed pending Native cleanup')
    h.failRelease = false; assert(Q.demand:Clear('retry')); assert(Q:Unsubscribe(owner))
    assert(Q:Subscribe({}, function() end)); h:Emit(); assert(called == 0)
end)
Test('resubscribing the same owner does not reuse a revoked record', function()
    local h = Boot(); local Q, owner, oldCalls, newCalls = h.bus, {}, 0, 0
    assert(Q:Subscribe(owner, function() oldCalls = oldCalls + 1 end)); local old = Q.subscribers[owner]
    assert(Q.demand:ForceQuiesce('test'))
    assert(Q:Subscribe(owner, function() newCalls = newCalls + 1 end)); h:Emit()
    assert(Q.subscribers[owner] ~= old and not old.active, 'new demand reused revoked execution authority')
    assert(oldCalls == 0 and newCalls == 1)
end)
print('COMBAT BUS LIFECYCLE RESULT ' .. passed .. ' passed / ' .. failed .. ' failed (' .. _VERSION .. ')')
if failed > 0 then error('combat bus lifecycle failures: ' .. failed) end

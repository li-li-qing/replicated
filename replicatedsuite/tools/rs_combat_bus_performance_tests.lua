-- Replicated Suite · 战斗总线热路分配与重入回归
-- 真实 Demand / Events / CombatBus，仅以受控 Native 宿主代替游戏；不读写玩家存档。
-- 小突发只核对瞬时垃圾和借用事实契约，不运行长 CPU 基准，也不推断 RU 实机帧率。
local passed, failed = 0, 0
local sourcePath = arg and arg[1] or 'services/rs_combat_event_bus_v3.lua'
local function Test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    collectgarbage('restart') -- 分配断言失败也必须恢复 GC，避免影响后续契约回归。
    if ok then passed = passed + 1; print('PASS combat-bus-performance ' .. name)
    else failed = failed + 1; print('FAIL combat-bus-performance ' .. name .. ': ' .. tostring(err)) end
end
local function Copy(value)
    if type(value) ~= 'table' then return value end
    local out = {}; for key, item in pairs(value) do out[key] = Copy(item) end; return out
end
local function Boot(callbacks)
    local h = { at = 1000, ready = true, owners = {} }
    local S = { Generation = 1, Services = {}, Utils = { DeepCopy = Copy }, SafeTraceback = debug.traceback,
        NowMs = function() return h.at end, PhysicalId = function(id) return id end }
    ReplicatedSuite = S
    S.NativeObjectFactory = { CreateWindow = function()
        local host = { handlers = {} }
        function host:SetHandler(key, callback) self.handlers[key] = callback; return true end
        function host:ReleaseHandler(key) self.handlers[key] = nil; return true end
        function host:RegisterEvent() return true end
        function host:UnregisterEvent() return true end
        function host:Show() return true end
        return host
    end }
    S.Services.UnitIdentityV3 = { IsPlayerName = function(_, name) return name == 'Self' end,
        IsPlayerIdentityReady = function() return h.ready end, RefreshPlayerIdentity = function() return nil end }
    dofile('core/rs_demand.lua'); dofile('core/rs_events.lua'); assert(S.Events:Start())
    dofile(sourcePath)
    h.S, h.bus = S, S.Services.CombatEventBusV3
    for index, callback in ipairs(callbacks or {}) do
        local owner = { Id = 'consumer_' .. index }; h.owners[index] = owner
        assert(h.bus:Subscribe(owner, callback, { scope = 'self' }))
    end
    return h
end
local function Fact(amount)
    return { schemaVersion = 1, sequence = 1, receivedAt = 1000, transport = 'private', category = 'damage',
        kind = 'spell_damage', amount = amount or 10, sourceName = 'Self', targetName = 'Victim',
        rawAbilityId = 11, rawEventType = 'SPELL_DAMAGE', sourceKind = 'PLAYER', targetKind = 'PLAYER' }
end
local function Measure(run)
    collectgarbage('collect'); collectgarbage('stop')
    local before = collectgarbage('count'); run()
    local delta = collectgarbage('count') - before; collectgarbage('restart')
    return delta
end

Test('warm dispatch does not allocate a protected closure for each consumer', function()
    local called = 0; local callback = function() called = called + 1 end
    local h = Boot({ callback, callback, callback }); local Q, fact = h.bus, Fact()
    for _ = 1, 20 do Q:_DispatchFact(fact) end
    local delta = Measure(function() for _ = 1, 2000 do Q:_DispatchFact(fact) end end)
    print(string.format('BUS_DISPATCH_ALLOC rows=2000 consumers=3 transient_kib=%.3f', delta))
    assert(delta < 32, 'per-consumer closure garbage still scales with rows: ' .. delta .. ' KiB')
    assert(called == 6060 and Q.delivered == 6060 and Q.received == 2020)
end)
Test('ready global ingress keeps an empty journal without per-row replacement', function()
    local h = Boot({ function() end }); local Q = h.bus
    local delta = Measure(function()
        for _ = 1, 2000 do Q:_OnGlobalCombat('UI', nil, 'SPELL_DAMAGE', 'Self', 'Victim', 11, 'Hit', 0, 10, true) end
    end)
    print(string.format('BUS_EMPTY_JOURNAL_ALLOC rows=2000 transient_kib=%.3f', delta))
    assert(delta < 16, 'empty journal garbage still scales with rows: ' .. delta .. ' KiB')
    assert(Q.globalSelfFiltered == 2000 and Q.journalHead == 1 and #Q.journal == 0 and Q.journalReplayed == 0)
end)
Test('all public fact fields are restored after a mutating callback error', function()
    local fields = { 'schemaVersion', 'sequence', 'receivedAt', 'transport', 'kind', 'category', 'environmental', 'amount',
        'sourceName', 'targetName', 'sourceId', 'targetId', 'sourceKind', 'targetKind', 'abilityName', 'boundRole', 'boundConfidence',
        'rawUnitId', 'rawEventType', 'rawAbilityId', 'rawDamageType', 'rawEffectType', 'rawIsActive',
        'rawMore1', 'rawMore2', 'rawMore3', 'rawMore4', 'rawMore5', 'subjectName', 'rawNotice2', 'rawNotice3', 'rawNotice4', 'rawNotice5',
        'auraType', 'auraId', 'auraName', 'auraEvidence' }
    local fact, seen = Fact(), 0; local expected = Copy(fact)
    local h = Boot({ function(_, row) for _, field in ipairs(fields) do row[field] = 'bad' end; error('expected callback failure') end,
        function(_, row) for _, field in ipairs(fields) do assert(row[field] == expected[field], 'corrupted ' .. field) end; seen = seen + 1 end })
    h.bus:_DispatchFact(fact); h.bus:_DispatchFact(fact)
    assert(seen == 2 and h.bus.callbackErrors == 2 and h.bus.factMutationErrors == 2 and h.bus.dispatchDepth == 0)
end)
Test('nested dispatch beyond the retained depth keeps every outer callback and fact', function()
    local Q, depth, seen = nil, 0, 0
    local h = Boot({ function(_, fact)
        local amount = fact.amount
        if depth < 12 then depth = depth + 1; Q:_DispatchFact(Fact(amount + 1)); depth = depth - 1 end
        assert(fact.amount == amount, 'nested callback overwrote the outer borrowed fact')
        fact.amount = -1
    end, function(_, fact) assert(fact.amount == 10 + depth); seen = seen + 1 end })
    Q = h.bus; local fact = Fact(); Q:_DispatchFact(fact)
    assert(seen == 13 and fact.amount == 10 and Q.factMutationErrors == 13 and Q.callbackErrors == 0 and Q.dispatchDepth == 0)
end)
Test('replacement callback is selected independently by a nested dispatch', function()
    local h = Boot(); local Q, owner, trace, depth = h.bus, {}, {}, 0
    assert(Q:Subscribe(owner, function(_, fact)
        trace[#trace + 1] = 'outer:' .. fact.amount
        assert(Q:Subscribe(owner, function(_, nested) trace[#trace + 1] = 'new:' .. nested.amount end))
        depth = depth + 1; Q:_DispatchFact(Fact(20)); depth = depth - 1
        assert(depth == 0 and fact.amount == 10)
    end))
    Q:_DispatchFact(Fact()); Q:_DispatchFact(Fact(30))
    assert(table.concat(trace, ',') == 'outer:10,new:20,new:30' and Q.callbackErrors == 0)
end)
Test('quiesce and restart inside a callback cancel old tails while nested work uses new owners', function()
    local h = Boot(); local Q, first, tail, fresh, oldCalls, newCalls = h.bus, {}, {}, {}, 0, 0
    assert(Q:Subscribe(first, function(_, fact)
        assert(Q.demand:ForceQuiesce('in_callback'))
        assert(Q:Subscribe(fresh, function(_, row) assert(row.amount == 20 or row.amount == 30); newCalls = newCalls + 1 end))
        Q:_DispatchFact(Fact(20)); fact.rawMore1 = 'bad'
    end))
    assert(Q:Subscribe(tail, function() oldCalls = oldCalls + 1 end))
    local fact = Fact(); Q:_DispatchFact(fact); Q:_DispatchFact(Fact(30))
    assert(oldCalls == 0 and newCalls == 2 and fact.rawMore1 == nil and Q.callbackErrors == 0 and Q.dispatchDepth == 0)
end)
Test('unsubscribe during a callback prevents the cancelled tail immediately', function()
    local h = Boot(); local Q, first, tail, cancelled, seen = h.bus, {}, {}, 0, 0
    assert(Q:Subscribe(first, function() assert(Q:Unsubscribe(tail)); seen = seen + 1 end))
    assert(Q:Subscribe(tail, function() cancelled = cancelled + 1 end))
    Q:_DispatchFact(Fact()); Q:_DispatchFact(Fact())
    assert(cancelled == 0 and seen == 2 and Q.subscriberCount == 1 and Q.callbackErrors == 0)
end)
Test('private and global facts still respect each subscriber scope', function()
    local called = 0; local h = Boot({ function() called = called + 1 end }); local Q, fact = h.bus, Fact()
    Q:_DispatchFact(fact); fact.transport = 'global:UI'; Q:_DispatchFact(fact)
    assert(called == 1 and Q.delivered == 1 and Q.scopeFiltered == 1 and Q.dispatchDepth == 0)
end)
Test('completed success and error dispatches retain no borrowed payload or revoked owner', function()
    local h = Boot(); local Q = h.bus; local weak = setmetatable({}, { __mode = 'v' })
    local owner, fact = {}, Fact(); fact.rawMore1 = {}; weak[1], weak[2], weak[3] = fact, fact.rawMore1, owner
    assert(Q:Subscribe(owner, function() error('expected failure') end)); Q:_DispatchFact(fact)
    assert(Q:Unsubscribe(owner)); fact, owner = nil, nil
    collectgarbage('collect'); collectgarbage('collect')
    assert(weak[1] == nil and weak[2] == nil and weak[3] == nil, 'reusable invocation retained a completed object')
    local clean = 0; assert(Q:Subscribe({}, function(_, row) assert(row.rawMore1 == nil); clean = clean + 1 end))
    fact = Fact(); weak[4] = fact; Q:_DispatchFact(fact); fact = nil
    collectgarbage('collect'); collectgarbage('collect')
    assert(clean == 1 and Q.dispatchDepth == 0 and weak[4] == nil, 'successful invocation retained a completed fact')
end)
Test('cold journal still replays queued rows and clears exhausted storage once', function()
    local h = Boot({ function() end }); local Q = h.bus; h.ready = false
    Q:_OnGlobalCombat('UI', nil, 'SPELL_DAMAGE', 'Self', 'First', 11, 'Hit', 0, 10, true)
    Q:_OnGlobalCombat('UIParent', nil, 'SPELL_DAMAGE', 'Self', 'Second', 11, 'Hit', 0, 20, true)
    assert(Q.journalQueued == 2 and #Q.journal == 2 and Q.globalSelfFiltered == 0)
    h.ready = true; local ok, replayed = Q:_FlushPreIdentityJournal(h.at)
    assert(ok and replayed == 2 and Q.journalReplayed == 2 and Q.globalSelfFiltered == 2 and #Q.journal == 0)
    local empty = Q.journal; ok, replayed = Q:_FlushPreIdentityJournal(h.at)
    assert(ok and replayed == 0 and Q.journal == empty, 'already empty journal was replaced again')
end)
Test('cold journal expiry preserves dropped counters without replay', function()
    local h = Boot({ function() end }); local Q = h.bus; h.ready = false
    Q:_OnGlobalCombat('UI', nil, 'SPELL_DAMAGE', 'Self', 'Victim', 11, 'Hit', 0, 10, true)
    h.at = 3000; h.ready = true; local ok, replayed = Q:_FlushPreIdentityJournal(h.at)
    assert(ok and replayed == 0 and Q.journalDropped == 1 and Q.journalDroppedCurrent == 1 and #Q.journal == 0 and Q.journalHead == 1)
end)
print('COMBAT BUS PERFORMANCE RESULT ' .. passed .. ' passed / ' .. failed .. ' failed (' .. _VERSION .. ')')
if failed > 0 then error('combat bus performance failures: ' .. failed) end

------------------------------------------------------------------------
-- Replicated Suite · 战斗分析热路分配与隔离回归
-- 维护：真实 Demand / Analytics，原生订阅为替身；只测 Lua 分配与事实隔离，不推断 RU 帧率。
-- 不进 TOC、不读取玩家存档；允许用固定小空间复用临时工作区，但不能保留事实引用或改变统计口径。
------------------------------------------------------------------------
local passed, failed = 0, 0
local function Copy(value)
    if type(value) ~= 'table' then return value end
    local out = {}; for key, item in pairs(value) do out[key] = Copy(item) end; return out
end
local function Test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then passed = passed + 1; print('PASS combat-dispatch-performance ' .. name)
    else failed = failed + 1; print('FAIL combat-dispatch-performance ' .. name .. ': ' .. tostring(err)) end
end
local function Boot(callbacks, path)
    ReplicatedSuite = { Generation = 1, Services = {}, Utils = { DeepCopy = Copy }, SafeTraceback = debug.traceback, NowMs = function() return 1000 end }
    local S = ReplicatedSuite
    S.Services.CombatEventBusV3 = { Subscribe = function() return true end, Unsubscribe = function() return true end }
    dofile('core/rs_demand.lua'); dofile(path or 'services/rs_combat_analytics_v3.lua')
    local A, ids = S.Services.CombatAnalyticsV3, {}
    A.collectionScope = 'all'
    for i, callback in ipairs(callbacks) do
        local id = 'perf_' .. i; ids[i] = id
        assert(A:RegisterMetric({ id = id, order = i, OnFact = callback }))
    end
    assert(A:AcquireConsumer('test', { metrics = ids }))
    return A
end
local function Fact(amount)
    return { schemaVersion = 1, sequence = 1, receivedAt = 1000, transport = 'private', category = 'damage',
        kind = 'spell_damage', amount = amount or 10, sourceName = 'Self', targetName = 'Victim',
        rawAbilityId = 11, rawEventType = 'SPELL_DAMAGE', sourceKind = 'PLAYER', targetKind = 'PLAYER' }
end
Test('warm dispatch allocation stays bounded across a long six-metric burst', function()
    local noop = function() return false end
    local A = Boot({ noop, noop, noop, noop, noop, noop }); local fact = Fact()
    for _ = 1, 20 do A:_DispatchFact(fact) end
    collectgarbage('collect'); collectgarbage('stop')
    local before, started = collectgarbage('count'), os.clock()
    for _ = 1, 10000 do A:_DispatchFact(fact) end
    local delta, elapsed = collectgarbage('count') - before, os.clock() - started
    collectgarbage('restart')
    print(string.format('DISPATCH_BENCH events=10000 metrics=6 elapsed_ms=%.3f transient_kib=%.3f', elapsed * 1000, delta))
    assert(delta < 256, 'per-event temporary garbage still scales with the burst: ' .. delta .. ' KiB')
    assert(A.metricDispatches == 10020 * 6 and A.factsReceived == 10020)
end)
Test('mutation and errors are isolated before the next metric', function()
    local seen = 0
    local A = Boot({ function(_, f) f.amount = 999; f.rawMore5 = 'bad'; error('expected failure') end,
        function(_, f) assert(f.amount == 10 and f.rawMore5 == nil); seen = seen + 1; return false end })
    local fact = Fact(); A:_DispatchFact(fact); A:_DispatchFact(fact)
    assert(seen == 2 and fact.amount == 10 and fact.rawMore5 == nil and A.metricErrors == 2 and A.metricMutations == 2)
end)
Test('all public protection fields survive a mutating consumer', function()
    local fields = { 'schemaVersion', 'sequence', 'receivedAt', 'transport', 'kind', 'category', 'environmental', 'amount',
        'sourceName', 'targetName', 'sourceId', 'targetId', 'sourceKind', 'targetKind', 'abilityName', 'boundRole', 'boundConfidence',
        'rawUnitId', 'rawEventType', 'rawAbilityId', 'rawDamageType', 'rawEffectType', 'rawIsActive',
        'rawMore1', 'rawMore2', 'rawMore3', 'rawMore4', 'rawMore5', 'subjectName', 'rawNotice2', 'rawNotice3', 'rawNotice4', 'rawNotice5',
        'auraType', 'auraId', 'auraName', 'auraEvidence' }
    local fact = Fact(); local original = Copy(fact); local seen = false
    local A = Boot({ function(_, f) for _, key in ipairs(fields) do f[key] = 'corrupt' end; return false end,
        function(_, f) for _, key in ipairs(fields) do assert(f[key] == original[key], 'corrupted field: ' .. key) end; seen = true; return false end })
    A:_DispatchFact(fact); assert(seen and A.metricMutations == 1)
end)
Test('nested dispatch keeps separate protection snapshots even beyond the retained workspace bound', function()
    local A, depth, seen = nil, 0, 0
    A = Boot({ function(_, f)
        local original = f.amount
        if depth < 12 then depth = depth + 1; A:_DispatchFact(Fact(original + 1)); depth = depth - 1 end
        f.amount = -1
        return false
    end, function(_, f) assert(f.amount == 10 + depth, 'nested snapshot overwrote outer fact'); seen = seen + 1; return false end })
    local fact = Fact(); A:_DispatchFact(fact)
    assert(seen == 13 and fact.amount == 10 and A.metricMutations == 13)
end)
Test('reused dispatch cannot carry optional fields from an earlier fact', function()
    local seen = 0
    local A = Boot({ function(_, f) f.rawMore1 = 'bad'; f.rawNotice2 = 'bad'; f.auraId = 999; return false end,
        function(_, f) seen = seen + 1; if seen == 1 then assert(f.rawMore1 == 5 and f.rawNotice2 == 'old' and f.auraId == 1)
            else assert(f.rawMore1 == nil and f.rawNotice2 == nil and f.auraId == nil) end; return false end })
    local first = Fact(); first.rawMore1, first.rawNotice2, first.auraId = 5, 'old', 1
    A:_DispatchFact(first); A:_DispatchFact(Fact()); assert(seen == 2)
end)
Test('completed workspaces retain neither facts nor arbitrary payload objects', function()
    local A = Boot({ function() return false end }); local weak = setmetatable({}, { __mode = 'v' })
    local fact = Fact(); fact.rawMore1 = {}; weak[1], weak[2] = fact, fact.rawMore1
    A:_DispatchFact(fact); fact = nil; collectgarbage('collect'); collectgarbage('collect')
    assert(weak[1] == nil and weak[2] == nil, 'dispatch retained a borrowed Native payload')
end)
print('COMBAT DISPATCH PERFORMANCE RESULT ' .. passed .. ' passed / ' .. failed .. ' failed (' .. _VERSION .. ')')
if failed > 0 then error('combat dispatch performance failures: ' .. failed) end

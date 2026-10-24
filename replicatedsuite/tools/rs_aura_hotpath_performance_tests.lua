------------------------------------------------------------------------
-- Replicated Suite · Aura热路径回归（开发期，不进入TOC）
-- 中文维护：复用PVP宿主和真实Aura/Metadata/Demand/Feature，Native仅给确定事实。
-- 分配门禁检查一次192行观察的helper函数实例有界，避免逐行临时闭包重新进入热路径。
-- Lua5.1离线行为/分配证据不等同于RU实机性能。
------------------------------------------------------------------------
local Host = dofile('tools/rs_pvp_hud_test_host.lua')
local passed, failed = 0, 0
local function Test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then passed = passed + 1; print('PASS aura-hotpath ' .. name)
    else failed = failed + 1; print('FAIL aura-hotpath ' .. name .. ': ' .. tostring(err)) end
end
local function Copy(value)
    if type(value) ~= 'table' then return value end
    local out = {}; for key, item in pairs(value) do out[key] = Copy(item) end; return out
end
local function Boot(count, generation)
    local h, S, F = Host({})
    S.Generation = generation or S.Generation
    S.NowMs = function() return h.now or 1000 end
    h.reads, h.tipReads, h.failCount = 0, 0, false
    h.facts = { buff = {}, debuff = {}, hidden = {} }
    for _, lane in ipairs({ 'buff', 'debuff', 'hidden' }) do
        for index = 1, count or 0 do
            h.facts[lane][index] = {
                buff_id = (lane == 'buff' and 1000 or lane == 'debuff' and 2000 or 3000) + index,
                name = lane .. index, iconPath = lane .. index .. '.dds',
                stack = index % 3 + 1, timeLeft = 12000 + index,
            }
        end
    end
    X2Unit, X2Ability = {}, {}
    S.Api.Call = function(_, host, method, unit, index)
        h.reads = h.reads + 1
        local lane = method:find('Hidden', 1, true) and 'hidden'
            or (method:find('DeBuff', 1, true) and 'debuff' or 'buff')
        if method:find('Count', 1, true) then
            if h.failCount then return false, nil end
            return true, #h.facts[lane]
        end
        if method:find('Tooltip', 1, true) then h.tipReads = h.tipReads + 1 end
        return true, h.facts[lane][index]
    end
    S.Api.CallCapability = function() error('unexpected metadata Native lookup') end
    dofile('services/rs_buff_metadata_v3.lua')
    dofile('services/rs_aura_observation_v3.lua')
    local A = S.Services.AuraObservationV3
    assert(A:AcquireConsumer('aura-hotpath', {}))
    return h, S, F, A
end
local all = { buff = true, debuff = true, hidden = true, limit = 64, ttlMs = 120 }
local function Read(A, options)
    local snapshot = assert(A:GetSnapshot('target', options or all))
    local map, coverage = A:GetStatusMap(snapshot, options or all)
    return map, coverage, snapshot
end
local function Row(id, data, tooltip, extra, tooltipExtra)
    return { effectId = id, data = data, tooltip = tooltip, extra = extra, tooltipExtra = tooltipExtra }
end
local function Snapshot(rows)
    return { buff = { available = true, complete = true, reliable = true, rows = rows } }
end
local onlyBuff = { buff = true, debuff = false, hidden = false }

Test('192-row scan and normalization use bounded helper instances and unchanged Native budget', function()
    local h, S, F, A = Boot(64)
    local functions, count = {}, 0
    debug.sethook(function(event)
        if event ~= 'call' then return end
        local info = debug.getinfo(2, 'fS')
        if info.what == 'Lua' and info.source:find('rs_aura_observation_v3.lua', 1, true)
            and not functions[info.func] then
            functions[info.func] = true; count = count + 1
        end
    end, 'c')
    local ok, map, coverage = pcall(Read, A)
    debug.sethook()
    assert(ok, map)
    assert(h.reads == 195 and h.tipReads == 0, 'Native budget changed: ' .. tostring(h.reads))
    assert(coverage.rows == 192 and coverage.available and coverage.complete and coverage.reliable)
    assert(map[1001].name == 'buff1' and map[2064].stack == 2 and map[3064].sources.hidden)
    print('AURA_HELPER_INSTANCES rows=192 instances=' .. count .. ' nativeReads=' .. h.reads)
    assert(count <= 32, 'per-row helper closures grew to ' .. count .. ' instances')
end)

Test('number and string aliases keep primary precedence and precise fallback semantics', function()
    local _, S, F, A = Boot(0)
    local map = A:GetStatusMap(Snapshot({
        Row(11, { stack = 8, timeLeft = 9, name = 'data', path = 'data.dds' },
            { stack = 0, stackCount = 7, timeLeft = 0, time_left = 20, name = 'tip', icon = 'tip.dds' }),
        Row(12, { count = '2', remainingTime = '31', buffName = 'data fallback', texture = 'fallback.dds' },
            { stack = false, stackCount = 'bad', timeLeft = false, time_left = 'bad', name = '', buffName = false, path = false, iconPath = '' }),
        Row(13, false, { count = '4', remain_time = '-99', buffName = 'tooltip', skill_icon = 'tooltip.dds' }),
        Row(14, { stack = 'bad', count = '5', timeLeft = 'bad', remainTime = '17', name = 'data', path = 'data.dds' }, false),
        Row(15, { name = '15', path = 'tail.dds' }, {}, { 'tail name' }, { 'other name' }),
    }), onlyBuff)
    assert(map[11].stack == 0 and map[11].timeLeft == 0 and map[11].name == 'tip' and map[11].iconPath == 'tip.dds')
    assert(map[12].stack == 2 and map[12].timeLeft == 31 and map[12].name == 'data fallback' and map[12].iconPath == 'fallback.dds')
    assert(map[13].stack == 4 and map[13].timeLeft == -99 and map[13].name == 'tooltip' and map[13].iconPath == 'tooltip.dds')
    assert(map[14].stack == 5 and map[14].timeLeft == 17 and map[15].name == 'tail name')
end)

Test('effect ID aliases preserve first truthy field before numeric conversion and tooltip fallback', function()
    local _, S, F, A = Boot(0)
    local rows = {
        Row(nil, { buff_id = 'bad', effectId = 999 }, { buff_id = '21', name = 'tip21', icon = '21.dds' }),
        Row(nil, { buff_id = false, buffId = '22', effectId = 998, name = 'data22', icon = '22.dds' }),
        Row(nil, { buff_id = 0, buffId = 997, name = 'zero', icon = '0.dds' }, { buff_id = 23 }),
        Row(nil, false, { buff_type = '24', name = 'tip24', icon = '24.dds' }),
        Row(nil, { buff_id = '', effectId = 996 }, { effect_id = '25', name = 'tip25', icon = '25.dds' }),
    }
    local map = A:GetStatusMap(Snapshot(rows), onlyBuff)
    assert(map[21] and map[22] and map[0] and map[24] and map[25])
    assert(not map[999] and not map[998] and not map[997] and not map[996] and not map[23])
end)

Test('duplicate IDs preserve source mask max stack longest known time and unknown coverage', function()
    local _, S, F, A = Boot(0)
    local snapshot = Snapshot({ Row(31, { name = 'first', icon = 'first.dds', stack = 2, timeLeft = 100 }) })
    snapshot.debuff = { available = true, complete = false, reliable = false,
        rows = { Row(31, { name = 'second', icon = 'second.dds', stack = 5, timeLeft = 200 }) } }
    snapshot.hidden = { available = true, complete = true, reliable = true,
        rows = { Row(31, { name = 'third', icon = 'third.dds', stack = 3 }) } }
    local map, meta = A:GetStatusMap(snapshot, all)
    assert(map[31].sourceMask == 7 and map[31].sources.buff and map[31].sources.debuff and map[31].sources.hidden)
    assert(map[31].stack == 5 and map[31].timeLeft == 200 and map[31].timeKnown and map[31].name == 'first')
    assert(meta.available and not meta.complete and not meta.reliable and meta.rows == 3)
    local unknown = A:EvaluateRequiredEffects(snapshot, { 32 }, all)
    assert(unknown.ok == nil and #unknown.missing == 1)
end)

Test('TTL boundaries limits and same-clock force retain every required native scan', function()
    local h, S, F, A = Boot(4)
    local options = { buff = true, debuff = false, hidden = false, limit = 2, ttlMs = 120 }
    local first = A:GetSnapshot('player', options); assert(h.reads == 3 and not first.buff.complete)
    A:GetSnapshot('player', options); assert(h.reads == 3)
    h.now = 1120; A:GetSnapshot('player', options); assert(h.reads == 3)
    options.limit = 4; A:GetSnapshot('player', options); assert(h.reads == 8)
    h.now = 1241; A:GetSnapshot('player', options); assert(h.reads == 13)
    options.ttlMs = 0; A:GetSnapshot('player', options); assert(h.reads == 13)
    options.forceRefresh = true; A:GetSnapshot('player', options); assert(h.reads == 18)
end)

Test('same-clock events and target rebind sample new status immediately', function()
    local h, S, F, A = Boot(2)
    assert(F:EnsureStoreLoaded()); F.enabled = true
    assert(F:RefreshScope('target'))
    local before = h.reads
    h.facts.buff[1].buff_id, h.facts.buff[1].name = 77777, 'new'
    assert(F:RefreshScope('target', true)); assert(h.reads > before)
    local found = false
    for _, row in ipairs(F.projections.target) do if row.id == 77777 then found = true end end
    assert(found)
    before = h.reads; h.facts.buff[1].buff_id = 88888; F.targetInvalidated = true
    assert(F:RefreshScope('target')); assert(h.reads > before and F.targetInvalidated == false)
    found = false
    for _, row in ipairs(F.projections.target) do
        if row.id == 88888 then found = true end
        assert(row.id ~= 77777, 'old target status survived rebind')
    end
    assert(found)
    h.failCount = true
    assert(F:RefreshScope('target', true)); assert(#F.projections.target == 0 and #F.laneData.target.buffRows == 0)
    assert(not F.coverage.target.available and not F.coverage.target.reliable)
end)

Test('metadata negative results recover through Remember and source aliases remain detached', function()
    local h, S, F, A = Boot(0)
    local M = S.Services.BuffMetadataV3
    M:_Store(41, false)
    local unknown = A:GetStatusMap(Snapshot({ Row(41, {}) }), onlyBuff)
    assert(unknown[41].name == '41' and unknown[41].iconPath == '')
    local observed = A:GetStatusMap(Snapshot({ Row(41, { buffName = 'observed', texture = 'observed.dds' }) }), onlyBuff)
    local resolved = A:GetStatusMap(Snapshot({ Row(41, {}) }), onlyBuff)
    assert(observed[41].name == 'observed' and resolved[41].iconPath == 'observed.dds')
    resolved[41].name = 'mutated'; resolved[41].sources.buff = false
    local again = A:GetStatusMap(Snapshot({ Row(41, {}) }), onlyBuff)
    assert(again[41].name == 'observed' and again[41].sources.buff)
    assert(h.reads == 0 and M.nativeLookups == 0)
end)

Test('snapshots metadata and status maps are detached and last consumer clears the generation', function()
    local h, S, F, A = Boot(2)
    local map, meta, snapshot = Read(A)
    map[1001].sources.buff = false; map[1001].name = 'outside'
    snapshot.buff.rows[1].data.name = 'outside'; snapshot.buff.rows[1].effectId = -1
    local nextMap, _, nextSnapshot = Read(A)
    assert(nextMap[1001].sources.buff and nextMap[1001].name == 'buff1')
    assert(nextSnapshot.buff.rows[1].data.name == 'buff1' and nextSnapshot.buff.rows[1].effectId == 1001)
    local cached = S.Services.BuffMetadataV3:GetCached(1001); cached.name = 'outside'
    assert(S.Services.BuffMetadataV3:GetCached(1001).name == 'buff1')
    assert(A:AcquireConsumer('second', {})); assert(A:ReleaseConsumer('aura-hotpath')); assert(A.cacheCount == 1)
    assert(A:ReleaseConsumer('second')); assert(A.cacheCount == 0 and next(A.cache) == nil)
    assert(A:GetSnapshot('target', all) == nil)
    local oldGeneration = S.Generation
    S.Generation = oldGeneration + 1
    local acquired, err = A:AcquireConsumer('old-generation', {})
    assert(acquired == false and err == 'stale demand generation' and A.cacheCount == 0)
    local nextHost, nextS, nextF, nextA = Boot(1, oldGeneration + 1)
    assert(nextA ~= A and nextA.cacheCount == 0 and next(nextA.cache) == nil)
    assert(nextA.Demand.generation == nextS.Generation and nextS.Generation ~= oldGeneration)
    assert(A.cacheCount == 0, 'old service cache revived during new host generation')
    local newMap = Read(nextA); assert(newMap[1001] and not newMap[1002])
    assert(nextA.Demand:ForceQuiesce('test_reload', 'retiring generation'))
    assert(nextA.cacheCount == 0 and nextA.Demand.count == 0 and nextA:GetSnapshot('target', all) == nil)
end)

print(string.format('AURA HOTPATH RESULT %d passed / %d failed', passed, failed))
if failed > 0 then os.exit(1) end

-- Replicated Suite · Aura归一化读取回归（开发期，不进入TOC）
-- 真实Lua5.1加载Aura/Metadata/Demand/Healer，只替换原生事实；
-- combined读取必须省去公开快照逐行副本，同时保留旧链的字段、尾部返回和生命周期语义。
-- RS_AURA_NORMALIZED_BASELINE可指定改前Aura源码，进行逐字段独立基线及短基准对照。
local Host = dofile('tools/rs_pvp_hud_test_host.lua')
local passed, failed = 0, 0
local function Test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then passed = passed + 1; print('PASS aura-normalized ' .. name)
    else failed = failed + 1; print('FAIL aura-normalized ' .. name .. ': ' .. tostring(err)) end
end
local function Equal(a, b, path)
    path = path or 'result'
    assert(type(a) == type(b), path .. ' type mismatch ' .. type(a) .. '/' .. type(b))
    if type(a) ~= 'table' then assert(a == b, path .. ': ' .. tostring(a) .. '/' .. tostring(b)); return end
    for key, value in pairs(a) do Equal(value, b[key], path .. '.' .. tostring(key)) end
    for key in pairs(b) do assert(a[key] ~= nil, path .. ' unexpected key ' .. tostring(key)) end
end
local function Boot(count, source)
    local h, S = Host({})
    S.NowMs = function() return h.now or 1000 end
    h.reads, h.tipReads, h.metadataReads = 0, 0, 0
    h.facts = { buff = {}, debuff = {}, hidden = {} }
    h.counts, h.fail, h.denied = {}, {}, {}
    for _, lane in ipairs({ 'buff', 'debuff', 'hidden' }) do
        for index = 1, count or 0 do
            h.facts[lane][index] = { data = {
                buff_id = (lane == 'buff' and 1000 or lane == 'debuff' and 2000 or 3000) + index,
                name = lane .. index, iconPath = lane .. index .. '.dds',
                stack = index % 3 + 1, timeLeft = 12000 + index,
            } }
        end
    end
    X2Unit, X2Ability = {}, {}
    S.Api.IsCapabilityAllowed = function(_, key) return not h.denied[key] end
    S.Api.Call = function(_, host, method, unit, index)
        h.reads = h.reads + 1
        if h.onRead then h.onRead(method, unit, index) end
        if h.fail[method] then return false, nil end
        local lane = method:find('Hidden', 1, true) and 'hidden'
            or (method:find('DeBuff', 1, true) and 'debuff' or 'buff')
        if method:find('Count', 1, true) then return true, h.counts[lane] or #h.facts[lane] end
        local row = h.facts[lane][index] or {}
        if method:find('Tooltip', 1, true) then
            h.tipReads = h.tipReads + 1
            local extra = row.tooltipExtra or {}
            return true, row.tooltip, nil, extra[1], extra[2], extra[3]
        end
        local extra = row.extra or {}
        return true, row.data, nil, extra[1], extra[2], extra[3]
    end
    S.Api.CallCapability = function() h.metadataReads = h.metadataReads + 1; return false, nil end
    dofile('services/rs_buff_metadata_v3.lua')
    dofile(source or 'services/rs_aura_observation_v3.lua')
    dofile('features/combat/healer/rs_healer_aura_bridge.lua')
    local A, B = S.Services.AuraObservationV3, S.Features.HealerAuraBridge
    assert(A:AcquireConsumer('normalized-test', {}))
    return h, S, A, B
end
local all = { buff = true, debuff = true, hidden = true, limit = 64, ttlMs = 120 }
local onlyBuff = { buff = true, debuff = false, hidden = false, limit = 64, ttlMs = 120 }
local baseline = os.getenv('RS_AURA_NORMALIZED_BASELINE')
local function OldRead(A, unit, options)
    local snapshot, err = A:GetSnapshot(unit or 'target', options or all)
    if not snapshot then return nil, nil, nil, err end
    local map, meta = A:GetStatusMap(snapshot, options or all)
    return map, meta, snapshot
end
local function NewRead(A, unit, options)
    assert(type(A.GetUnitStatusMap) == 'function', 'combined detached status read unavailable')
    return A:GetUnitStatusMap(unit or 'target', options or all)
end
local function Headers(snapshot)
    local out = { unitId = snapshot.unitId, at = snapshot.at, revision = snapshot.revision }
    for _, lane in ipairs({ 'buff', 'debuff', 'hidden' }) do
        if snapshot[lane] then
            out[lane] = {}
            for key, value in pairs(snapshot[lane]) do if key ~= 'rows' then out[lane][key] = value end end
        end
    end
    return out
end
local function CompareFixture(configure, options)
    local oldH, oldS, oldA = Boot(0, baseline)
    local newH, newS, newA = Boot(0)
    configure(oldH, oldS, oldA); configure(newH, newS, newA)
    local oldMap, oldMeta, oldSnapshot, oldErr = OldRead(oldA, 'target', options)
    local map, meta, summary, err = NewRead(newA, 'target', options)
    Equal(map, oldMap, 'map'); Equal(meta, oldMeta, 'meta'); Equal(err, oldErr, 'error')
    Equal(summary, Headers(oldSnapshot), 'summary')
    Equal(newH.reads, oldH.reads, 'Native reads'); Equal(newH.tipReads, oldH.tipReads, 'tooltip reads')
    Equal(newH.metadataReads, oldH.metadataReads, 'metadata reads')
    return map, meta, summary
end

local function Measure(label, A, read, options, count)
    read(A, 'target', options)
    collectgarbage('collect'); collectgarbage('stop')
    local before, started = collectgarbage('count'), os.clock()
    for _ = 1, count do read(A, 'target', options) end
    local elapsed, allocated = os.clock() - started, collectgarbage('count') - before
    collectgarbage('restart'); collectgarbage('collect')
    print(string.format('AURA_NORMALIZED_BENCH %s iterations=%d elapsed=%.6f allocatedKB=%.2f', label, count, elapsed, allocated))
    return elapsed, allocated
end
-- 先观察旧链的暖读和完整新扫描，RED阶段也能保存改前分配/耗时证据。
do
    local h, S, A = Boot(64, baseline)
    Measure('old-warm-192', A, OldRead, all, 160)
    Measure('old-cold-192', A, OldRead, { buff = true, debuff = true, hidden = true, limit = 64, forceRefresh = true }, 80)
end

Test('combined read normalizes 192 rows with unchanged scans and scalar detached headers', function()
    local h, S, A = Boot(64)
    local map, meta, summary, err = NewRead(A)
    assert(not err and map[1001].name == 'buff1' and map[3064].sources.hidden)
    assert(meta.rows == 192 and meta.available and meta.complete and meta.reliable)
    assert(h.reads == 195 and h.tipReads == 0 and h.metadataReads == 0)
    assert(summary.buff.count == 64 and summary.buff.rows == nil and summary.at == 1000)
    for _, header in pairs(summary) do
        if type(header) == 'table' then
            for key, value in pairs(header) do assert(type(value) ~= 'table', 'nested cache alias ' .. tostring(key)) end
        end
    end
end)

Test('combined read keeps first truthy ID conversion aliases zero and false priority', function()
    local map = CompareFixture(function(h)
        h.facts.buff = {
            { data = { buff_id = 'bad', effectId = 999 }, tooltip = { buff_id = 21, name = 'tip21', icon = '21.dds', stack = 0, stackCount = 9, timeLeft = 0 } },
            { data = { buff_id = false, buffId = 22, name = 'data22', icon = '22.dds', stack = 8, timeLeft = 90 } },
            { data = { buff_id = 0, buffId = 997, name = 'zero', icon = '0.dds' } },
            { data = false, tooltip = { buff_type = 24, buffName = 'tip24', texture = '24.dds', count = '4', remain_time = '-99' } },
            { data = { buff_id = '', effectId = 996 }, tooltip = { effect_id = 25, name = 'tip25', icon = '25.dds' } },
            { data = { buff_id = 26, count = '5', remainingTime = '31', buffName = 'data fallback', texture = '26.dds' },
              tooltip = { stack = false, stackCount = 'bad', timeLeft = false, time_left = 'bad', name = '', buffName = false, path = false, iconPath = '' } },
        }
    end, onlyBuff)
    assert(map[21].stack == 0 and map[21].timeLeft == 0 and map[0].name == 'zero')
    assert(map[24].stack == 4 and map[24].timeLeft == -99 and map[26].stack == 5 and map[26].name == 'data fallback')
    assert(not map[999] and not map[997] and not map[996])
end)

Test('native nested and sparse extras retain CopyShallow length and fallback semantics', function()
    local map = CompareFixture(function(h)
        h.facts.buff = {
            { data = { buff_id = 41, icon = '41.dds' }, extra = { {}, 'after nested', 'third' } },
            { data = { buff_id = 42, icon = '42.dds' }, extra = { '123', {}, 'third name' } },
            { data = { buff_id = 43, icon = '43.dds' }, extra = { {}, {}, 'third name' } },
            { data = { buff_id = 44, icon = '44.dds' }, extra = { nil, 'sparse name', nil } },
            { data = { buff_id = 45, icon = '45.dds' }, extra = { 'icon.dds', { name = 'nested' }, 'third name' },
              tooltip = { buff_id = 45 }, tooltipExtra = { 'tooltip tail' } },
            { data = { buff_id = 46, icon = '46.dds', nested = { name = 'private' } }, extra = { {} },
              tooltip = { buff_id = 46 }, tooltipExtra = { {}, 'tooltip after nested', 'tail' } },
        }
    end, onlyBuff)
    -- 旧链浅复制会丢掉尾部返回中的表，Lua5.1的稀疏长度会令这些名字不可见。
    assert(map[41].name == '41' and map[43].name == '43' and map[46].name == '46')
end)

Test('duplicates retain source merging partial rows and unknown unavailable coverage', function()
    local map, meta = CompareFixture(function(h)
        h.facts.buff = { { data = { buff_id = 51, name = 'first', icon = 'first.dds', stack = 2, timeLeft = 100 } } }
        h.facts.debuff = {
            { data = { buff_id = 51, name = 'second', icon = 'second.dds', stack = 5, timeLeft = 200 } },
            { data = { buff_id = 52, name = 'outside limit' } },
        }
        h.facts.hidden = { { data = { buff_id = 51, name = 'third', icon = 'third.dds', stack = 3 } } }
    end, { buff = true, debuff = true, hidden = true, limit = 1 })
    assert(map[51].sourceMask == 7 and map[51].stack == 5 and map[51].timeLeft == 200 and map[51].name == 'first')
    assert(meta.available and not meta.complete and not meta.reliable and meta.rows == 3)
    CompareFixture(function(h)
        h.fail.UnitDeBuffCount = true
        h.facts.buff = { { data = nil }, { data = false } }
        h.facts.hidden = { { data = { buff_id = 53, name = 'hidden', icon = '53.dds' } } }
    end, all)
end)

Test('gated lanes failed rows and metadata negative results keep old Native cadence', function()
    CompareFixture(function(h)
        h.denied['X2Unit:UnitHiddenBuffCount'] = true
        h.fail.UnitBuff = true
        h.facts.buff = {
            { tooltip = { buff_id = 61, name = 'fallback61', icon = '61.dds' } },
            { tooltip = { buff_id = 62, name = 'fallback62', icon = '62.dds' } },
        }
        h.facts.debuff = { { data = { buff_id = 63 } }, { data = { buff_id = 64 }, tooltip = false } }
    end, all)
    local h, S, A = Boot(0)
    h.facts.buff = { { data = { buff_id = 65 } } }
    local first = NewRead(A, 'target', onlyBuff)
    assert(first[65].name == '65' and first[65].iconPath == '' and h.metadataReads == 3)
    NewRead(A, 'target', onlyBuff); assert(h.metadataReads == 3)
    h.facts.buff[1] = { data = { buff_id = 65, name = 'observed', icon = '65.dds' } }
    local recovered = NewRead(A, 'target', { buff = true, debuff = false, forceRefresh = true })
    assert(recovered[65].name == 'observed' and S.Services.BuffMetadataV3:GetCached(65).iconPath == '65.dds')
    assert(h.metadataReads == 3)
end)

Test('shared collection preserves TTL limit widening same-clock force and negative cache', function()
    local h, S, A = Boot(4)
    local opts = { buff = true, debuff = false, hidden = false, limit = 2, ttlMs = 120 }
    local _, meta, summary = NewRead(A, 'target', opts)
    assert(h.reads == 3 and not meta.complete and summary.revision == 1)
    OldRead(A, 'target', opts); NewRead(A, 'target', opts); assert(h.reads == 3)
    h.now = 1120; NewRead(A, 'target', opts); assert(h.reads == 3)
    opts.limit = 4; NewRead(A, 'target', opts); assert(h.reads == 8)
    h.now = 1241; NewRead(A, 'target', opts); assert(h.reads == 13)
    opts.ttlMs = 0; NewRead(A, 'target', opts); assert(h.reads == 13)
    opts.forceRefresh = true; NewRead(A, 'target', opts); assert(h.reads == 18)
    h.fail.UnitBuffCount = true; NewRead(A, 'target', opts); assert(h.reads == 19)
    opts.forceRefresh = false; NewRead(A, 'target', opts); assert(h.reads == 19)
    h.now = 1242; NewRead(A, 'target', opts); assert(h.reads == 20)
end)

Test('public defaults errors and arbitrary GetStatusMap snapshots keep their contract', function()
    local h, S, A = Boot(1)
    local map, meta, summary = NewRead(A, 'target', {})
    assert(map[1001] and not map[2001] and meta.lanes == 1 and summary.debuff.count == 1)
    local noMap, noMeta, noSummary = NewRead(A, 'target', { buff = false, debuff = false, hidden = false })
    assert(next(noMap) == nil and not noMeta.available and not noMeta.reliable and noMeta.lanes == 0)
    local invalid, invalidMeta, invalidSummary, invalidErr = A:GetUnitStatusMap('', all)
    assert(not invalid and not invalidMeta and not invalidSummary and invalidErr == 'unit id required')
    local synthetic = A:GetStatusMap({ buff = { available = true, complete = true, reliable = true, rows = {
        { effectId = 81, data = { name = 'synthetic', icon = '81.dds' }, extra = { {}, 'direct extra' } },
        { effectId = 82, data = { icon = '82.dds' }, extra = { {}, 'raw extra' } },
    } } }, onlyBuff)
    assert(synthetic[81].name == 'synthetic' and synthetic[82].name == 'raw extra')
end)

Test('maps headers public overrides and metadata callbacks cannot mutate cached facts', function()
    local h, S, A = Boot(2)
    local map, meta, summary = NewRead(A)
    map[1001].sources.buff = false; map[1001].name = 'external'; meta.rows = -1
    summary.at = -1; summary.buff.count = -1; summary.buff.available = false
    A.GetSnapshot = function() error('combined exposed cache through GetSnapshot override') end
    A.GetStatusMap = function() error('combined exposed cache through GetStatusMap override') end
    local again, againMeta, againSummary = NewRead(A)
    assert(again[1001].sources.buff and again[1001].name == 'buff1' and againMeta.rows == 6)
    assert(againSummary.buff.count == 2 and againSummary.at == 1000)
    local M = S.Services.BuffMetadataV3
    local oldRemember, nested = M.Remember, false
    M.Remember = function(self, id, name, icon)
        if not nested then
            nested = true
            local reentered = NewRead(A, 'watchtarget', onlyBuff)
            reentered[1001].name = 'reentrant mutation'
        end
        return oldRemember(self, id, name, icon)
    end
    local reentered = NewRead(A)
    assert(reentered[1001].name == 'buff1' and nested)
end)

Test('same-unit metadata reentry cannot mix later force scans into an earlier read', function()
    local h, S, A = Boot(2)
    local M = S.Services.BuffMetadataV3
    local oldRemember, nested, inner = M.Remember, false
    M.Remember = function(self, id, name, icon)
        if not nested then
            nested = true
            h.facts.buff[1].data.buff_id = 901
            h.facts.debuff[1].data.buff_id = 902
            h.facts.hidden[1].data.buff_id = 903
            inner = NewRead(A, 'target', { buff = true, debuff = true, hidden = true, forceRefresh = true })
        end
        return oldRemember(self, id, name, icon)
    end
    local outer, meta, summary = NewRead(A)
    assert(inner[901] and inner[902] and inner[903])
    assert(outer[1001] and outer[2001] and outer[3001] and not outer[901] and not outer[902] and not outer[903])
    assert(summary.revision == 1 and meta.rows == 6)
    local latest, _, latestSummary = NewRead(A)
    assert(latest[901] and latest[902] and latest[903] and latestSummary.revision == 2)
end)

Test('Healer opts into combined reads with old host fallback and Stop ForceQuiesce cleanup', function()
    local h, S, A, B = Boot(2)
    assert(B:Start('test'))
    local oldSnapshot, oldStatus = A.GetSnapshot, A.GetStatusMap
    A.GetSnapshot = function() error('healer should use combined read') end
    A.GetStatusMap = function() error('healer should use combined read') end
    local map, coverage, err = B:Read('target', all)
    assert(not err and map[1001] and coverage.rows == 6 and coverage.buffCount == 2 and coverage.revision == 1)
    A.GetSnapshot, A.GetStatusMap = oldSnapshot, oldStatus
    A.GetUnitStatusMap = nil
    local fallback, fallbackCoverage = B:Read('target', all)
    Equal(fallback, map); Equal(fallbackCoverage, coverage)
    assert(B:Stop('test')); assert(A.cacheCount == 1)
    assert(A:ReleaseConsumer('normalized-test')); assert(A.cacheCount == 0)
    assert(B:Read('target') == nil)
    local h2, S2, A2 = Boot(1)
    NewRead(A2)
    assert(A2.Demand:ForceQuiesce('test', 'test'))
    local absent, absentMeta, absentSummary, absentErr = NewRead(A2)
    assert(not absent and not absentMeta and not absentSummary and absentErr == 'aura service has no consumer')
    assert(A2.cacheCount == 0)
end)

Test('combined warm reads lower allocation and full scans preserve native budget', function()
    local oldH, oldS, oldA = Boot(64, baseline)
    local newH, newS, newA = Boot(64)
    local oldTime, oldAlloc = Measure('compare-old-warm-192', oldA, OldRead, all, 160)
    local newTime, newAlloc = Measure('combined-warm-192', newA, NewRead, all, 160)
    assert(newH.reads == oldH.reads and newH.reads == 195)
    assert(newAlloc < oldAlloc * 0.70, 'combined warm reads did not remove snapshot copies')
    local cold = { buff = true, debuff = true, hidden = true, limit = 64, forceRefresh = true }
    oldTime, oldAlloc = Measure('compare-old-cold-192', oldA, OldRead, cold, 80)
    newTime, newAlloc = Measure('combined-cold-192', newA, NewRead, cold, 80)
    assert(newH.reads == oldH.reads and newAlloc < oldAlloc * 0.85)
    -- os.clock粒度和主机抖动不作严苛耗时断言；比值留作审查证据。
end)

print(string.format('AURA NORMALIZED RESULT %d passed / %d failed', passed, failed))
if failed > 0 then os.exit(1) end

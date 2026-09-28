------------------------------------------------------------------------
-- Phase 3 Batch A 契约测试（2026-09-29，core-feature-decoupling-1）
--
-- 目的：证明「把 RaidReadiness 的契约门禁从 Foundation 搬到 Feature 的 acceptance 文件」是**无损搬迁**，
-- 而且是**严格加强**。对照关系：
--
--   core/rs_foundation_gate.lua（已删除）
--     raid_readiness_v3_contract      （blocker）
--     raid_readiness_runtime_scope    （warning）
--   → features/combat/raid_readiness/rs_raid_readiness_acceptance.lua
--     v3_m16_14_raid_readiness_contract（sequence case；失败 → sequence_harness blocker）
--
-- 本文件用**最小离线替身**直接驱动 acceptance 注册的那个 case，逐个触发搬迁过程中补齐的三个强度点：
--   1. 实现未注册（F = nil）—— 旧 acceptance 会静默 return，等于“没有检查”；现在必须失败。
--   2. dormant roster lease    —— Foundation 原判定要求，旧 acceptance 只查了 auraHeld。
--   3. scan 缺 roster / aura 缺 scan —— Foundation 原判定的依赖顺序，旧 acceptance 完全没有。
-- 另外做一条静态断言：core/*.lua 不得再出现点名 RaidReadiness 的硬编码访问。
--
-- 这是纯离线契约测试：不读写用户 UDF，不声明任何 RU 实机行为。
------------------------------------------------------------------------
local passed, failed = 0, 0
local function Test(name, fn)
    local ok, err = pcall(fn)
    if ok then passed = passed + 1; print('PASS coredc ' .. name)
    else failed = failed + 1; print('FAIL coredc ' .. name .. ': ' .. tostring(err)) end
end

local CASE_ID = 'v3_m16_14_raid_readiness_contract'

-- 构造一个“完全合规”的最小环境；用 overrides 逐项打破。
local function Boot(overrides)
    overrides = type(overrides) == 'table' and overrides or {}
    local cases = {}
    local S = {
        Features = {},
        SafeTraceback = debug and debug.traceback or function(m) return m end,
        FoundationGate = {},
    }
    function S.FoundationGate:RegisterSequenceCase(id, fn) cases[tostring(id)] = fn; return true end
    S.FeatureRegistry = { Get = function(_, id) if id ~= 'combat_raid_readiness' then return nil end
        return { status = 'migrated_m16_14', lifecycle = 'on_demand_scan', authority = 'v3.raid_readiness',
            widgetCapable = false, settingsCapable = true, defaultEnabled = false } end }
    S.Persistence = { Scope = { Account = 'Account' },
        GetStore = function(_, id) if id ~= 'v3.raid_readiness' then return nil end
            return { owner = 'v3.raid_readiness', scope = 'Account', schemaVersion = 1 } end }
    S.FeatureRuntime = { IsImplemented = function(_, id) return id == 'combat_raid_readiness' end }
    S.Services = {
        TeamRosterV3 = { version = 4, AcquireConsumer = function() end, GetSnapshot = function() end },
        AuraObservationV3 = { version = 2, GetSnapshot = function() end, GetStatusMap = function() end,
            EvaluateRequiredEffects = function() end, AcquireConsumer = function() end },
    }
    S.UIV3 = { PageHost = { factories = { ['combat.raid_readiness'] = function() end } } }
    S.NativeContract = { GetApi = function(_, ns) if ns ~= 'TEAM' then return nil end
        return { id = 38, nativeName = 'X2Team' } end }

    local feature = {
        StoreId = 'v3.raid_readiness',
        GetSettings = function() end, ApplySettingRaw = function() end, EnsureStoreLoaded = function() end,
        RunScan = function() end, AcquireAuraLease = function() end, ReleaseAuraLease = function() end,
        Demand = {}, Commands = { ApplySettingFromBinding = function() end, MarkStoreDirty = function() end },
        Authority = { version = 1, StartScan = function() end, CancelScan = function() end,
            GetRows = function() end, GetSummary = function() end },
        consumerCount = 1, rosterHeld = false, auraHeld = false, scanning = false,
    }
    if overrides.noFeature == true then feature = nil end
    for key, value in pairs(overrides.feature or {}) do feature[key] = value end
    -- 注意：Lua 里 `{ RunScan = nil }` 是**空表**，根本不会删键 —— 删字段必须走这两个显式开关。
    if overrides.dropFeatureFn ~= nil then feature[overrides.dropFeatureFn] = nil end
    if overrides.dropCommand ~= nil then feature.Commands[overrides.dropCommand] = nil end
    if overrides.dropAuthorityFn ~= nil then feature.Authority[overrides.dropAuthorityFn] = nil end
    S.Features.RaidReadiness = feature

    ReplicatedSuite = S
    dofile('features/combat/raid_readiness/rs_raid_readiness_acceptance.lua')
    return cases, S
end

local function RunCase(cases)
    local fn = cases[CASE_ID]
    assert(type(fn) == 'function', 'RaidReadiness acceptance case not registered')
    return fn()
end

Test('acceptance 无条件注册 case（实现缺失也必须注册并失败）', function()
    local cases = Boot({ noFeature = true })
    assert(type(cases[CASE_ID]) == 'function', 'case must register even when the Feature is missing')
    local ok, reason = RunCase(cases)
    assert(ok == false, 'missing implementation must fail')
    assert(tostring(reason) == 'implementation_not_registered', 'reason=' .. tostring(reason))
end)

Test('合规实现通过（搬迁后判定未被误伤）', function()
    local cases = Boot(nil)
    local ok, reason = RunCase(cases)
    assert(ok == true, 'compliant feature must pass, got ' .. tostring(reason))
end)

Test('RunScan 缺失 → feature_contract（Foundation 原判定之一）', function()
    local cases = Boot({ dropFeatureFn = 'RunScan' })
    local ok, reason = RunCase(cases)
    assert(ok == false and tostring(reason) == 'feature_contract', 'reason=' .. tostring(reason))
end)

Test('Authority.CancelScan 缺失 → authority_contract（Foundation 原判定之一）', function()
    local cases = Boot({ dropAuthorityFn = 'CancelScan' })
    local ok, reason = RunCase(cases)
    assert(ok == false and tostring(reason) == 'authority_contract', 'reason=' .. tostring(reason))
end)

Test('无 consumer 时不得持有 roster lease（旧 acceptance 漏检，搬迁补齐）', function()
    local cases = Boot({ feature = { consumerCount = 0, rosterHeld = true } })
    local ok, reason = RunCase(cases)
    assert(ok == false and tostring(reason) == 'dormant_roster_lease', 'reason=' .. tostring(reason))
end)

Test('scanning 必须同时持有 roster（旧 acceptance 漏检，搬迁补齐）', function()
    local cases = Boot({ feature = { consumerCount = 1, scanning = true, rosterHeld = false } })
    local ok, reason = RunCase(cases)
    assert(ok == false and tostring(reason) == 'scan_without_roster_lease', 'reason=' .. tostring(reason))
end)

Test('持有 aura 必须正在 scanning（旧 acceptance 漏检，搬迁补齐）', function()
    local cases = Boot({ feature = { consumerCount = 1, auraHeld = true, scanning = false } })
    local ok, reason = RunCase(cases)
    assert(ok == false and tostring(reason) == 'aura_without_scan', 'reason=' .. tostring(reason))
end)

Test('TeamRosterV3 版本回退 → roster_contract', function()
    local cases = Boot(nil)
    ReplicatedSuite.Services.TeamRosterV3.version = 3
    local ok, reason = RunCase(cases)
    assert(ok == false and tostring(reason) == 'roster_contract', 'reason=' .. tostring(reason))
end)

Test('静态：core/*.lua 不得再点名 RaidReadiness 的硬编码访问', function()
    local core = assert(io.open('core/rs_foundation_gate.lua', 'rb'))
    local text = core:read('*a'); core:close()
    assert(text:find('S.Features.RaidReadiness', 1, true) == nil,
        'Foundation must not hard-code the RaidReadiness implementation any more')
    assert(text:find('combat_raid_readiness', 1, true) == nil,
        'Foundation must not hard-code the raid readiness feature id either')
end)

print(string.format('CORE-FEATURE-DECOUPLING RESULT %d passed / %d failed', passed, failed))
if failed > 0 then error('core/feature decoupling regressions: ' .. tostring(failed)) end

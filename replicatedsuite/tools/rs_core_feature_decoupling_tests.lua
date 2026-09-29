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

------------------------------------------------------------------------
-- Phase 3 Batch B：DeathReview（core/rs_foundation_gate.lua 的
-- death_review_v3_contract + death_review_runtime_scope 已删除）
--
-- 该 Feature 的 acceptance 本来就比 Foundation 更严（多查 store.lifetime、migrate 的**实际归一化结果**、
-- Framework2/schema2 零值省略的真实恢复执行 probe、record/index 预算探针），所以本批的搬迁补齐点主要是
-- “实现缺失不再静默 return”。这里用最小替身证明 case 真的在跑，并覆盖 Foundation 原有的一处判定。
------------------------------------------------------------------------
local DEATH_CASE = 'v3_m15_2h_death_review_contract'

local function BootDeath(overrides)
    overrides = type(overrides) == 'table' and overrides or {}
    local cases = {}
    local S = { Features = {}, SafeTraceback = debug and debug.traceback or function(m) return m end, FoundationGate = {} }
    function S.FoundationGate:RegisterSequenceCase(id, fn) cases[tostring(id)] = fn; return true end
    S.FeatureRegistry = { Get = function(_, id)
        if id ~= 'combat_death_review' then return nil end
        return { status = 'migrated_m15_2', lifecycle = 'independent', authority = 'v3.death_review',
            widgetCapable = true, settingsCapable = true, defaultEnabled = false } end }
    S.Persistence = { Scope = { Account = 'Account' }, Lifetime = { Permanent = 'Permanent' },
        HistoricalCanonicalRecoveryContractVersion = 3, KnownLegacyCanonicalRecoveryContractVersion = 1,
        GetStore = function() return nil end }
    S.FeatureRuntime = { IsImplemented = function(_, id) return id == 'combat_death_review' end }
    S.UIV3 = { PageHost = { factories = {} }, WidgetHost = { GetSpec = function() return nil end } }
    local F = { StoreId = 'v3.death_review' }
    if overrides.noFeature == true then F = nil end
    S.Features.DeathReview = F
    ReplicatedSuite = S
    dofile('features/combat/death_review/rs_death_review_acceptance.lua')
    return cases
end

Test('DeathReview：实现未注册时仍注册 case 并失败（搬迁补齐）', function()
    local cases = BootDeath({ noFeature = true })
    assert(type(cases[DEATH_CASE]) == 'function', 'case must register even when the Feature is missing')
    local ok, reason = cases[DEATH_CASE]()
    assert(ok == false and tostring(reason) == 'implementation_not_registered', 'reason=' .. tostring(reason))
end)

Test('DeathReview：Index Store 缺失 → store_contract（Foundation 原判定之一）', function()
    local cases = BootDeath(nil)
    local ok, reason = cases[DEATH_CASE]()
    assert(ok == false and tostring(reason) == 'store_contract', 'reason=' .. tostring(reason))
end)

Test('DeathReview：静态 —— core/*.lua 不得再点名该 Feature', function()
    local f = assert(io.open('core/rs_foundation_gate.lua', 'rb'))
    local text = f:read('*a'); f:close()
    assert(text:find('S.Features.DeathReview', 1, true) == nil, 'Foundation must not hard-code DeathReview')
    assert(text:find('combat_death_review', 1, true) == nil, 'Foundation must not hard-code the death review feature id')
end)

------------------------------------------------------------------------
-- Phase 3 Batch C：life_bonds
-- （core/rs_foundation_gate.lua 里 5 条点名 life_bonds 实现的契约版本条件已删除）
--
-- 该 Feature 的 acceptance 不仅覆盖原判定，而且**更严**：DropdownPresentationContractVersion
-- Foundation 只要 >=1，acceptance 要求 >=2。下面专门用“=1”做区分度证据：旧判定放行、新 Authority 拒绝。
-- 搬迁补齐点同样是“实现缺失不再静默 return”。
------------------------------------------------------------------------
local BONDS_CASE = 'v3_m1_bonds'

local function BootBonds(overrides)
    overrides = type(overrides) == 'table' and overrides or {}
    local cases = {}
    local S = { Features = {}, SafeTraceback = debug and debug.traceback or function(m) return m end, FoundationGate = {} }
    function S.FoundationGate:RegisterSequenceCase(id, fn) cases[tostring(id)] = fn; return true end
    S.FeatureRegistry = { Get = function(_, id)
        if id ~= 'life_bonds' then return nil end
        return { authority = 'v3.life.bonds' } end }
    -- 本批只覆盖到「静态契约块」为止：acceptance 在 IsEnabled ~= true 时会提前返回 true，
    -- 其后的 consumer/projection 运行时检查不属于本批搬迁范围，也不在离线宿主里模拟。
    S.FeatureRuntime = { IsImplemented = function(_, id) return id == 'life_bonds' end,
        IsEnabled = function() return false end }
    S.Persistence = { GetStore = function() return { owner = 'v3.life.bonds', rebuildCanonicalForIntegrity = function() end } end }
    S.UIV3 = { PageHost = { factories = { ['life.bonds'] = function() end } },
        WidgetHost = { GetSpec = function(_, id) if id == 'life.bonds' then return {} end return nil end } }
    local function fn() end
    local F = {
        storeId = 'v3.life.bonds',
        MultiContinentSnapshotContractVersion = 3, ResidentBoardFamilyContractVersion = 1,
        AuroriaMaterialContractVersion = 1, DropdownPresentationContractVersion = 2,
        GetDisplayOrderKey = fn, GetFilterMask = fn, GetDuplicateMode = fn,
        Commands = { Refresh = fn, SetDisplayOrder = fn, SetFilterMask = fn, SetDuplicateMode = fn,
            SetSortMode = fn, SetContinentOrder = fn, SetBondFilterOption = fn, SetDuplicatePriority = fn,
            SelectRow = fn, GetSelectedRow = fn, GetRow = fn, MarkStoreDirty = fn, SetWidgetWindowState = fn },
    }
    if overrides.noFeature == true then F = nil end
    for key, value in pairs(overrides.feature or {}) do F[key] = value end
    S.Features.Bonds = F
    ReplicatedSuite = S
    dofile('features/life/bonds/rs_bonds_acceptance.lua')
    return cases
end

Test('life_bonds：实现未注册时仍注册 case 并失败（搬迁补齐）', function()
    local cases = BootBonds({ noFeature = true })
    assert(type(cases[BONDS_CASE]) == 'function', 'case must register even when the Feature is missing')
    local ok, reason = cases[BONDS_CASE]()
    assert(ok == false and tostring(reason) == 'implementation_not_registered', 'reason=' .. tostring(reason))
end)

Test('life_bonds：完备实现通过（搬迁未误伤）', function()
    local cases = BootBonds(nil)
    local ok, reason = cases[BONDS_CASE]()
    assert(ok == true, 'compliant feature must pass, got ' .. tostring(reason))
end)

Test('life_bonds：DropdownPresentationContractVersion=1 必须被拒（新 Authority 严于旧判定）', function()
    -- 旧 Foundation 判定的下限是 >=1，这一形态会被放行；acceptance 要求 >=2，必须拒绝。
    local cases = BootBonds({ feature = { DropdownPresentationContractVersion = 1 } })
    local ok, reason = cases[BONDS_CASE]()
    assert(ok == false and tostring(reason) == 'presentation_command_contract', 'reason=' .. tostring(reason))
end)

Test('life_bonds：MultiContinentSnapshotContractVersion=2 必须被拒', function()
    local cases = BootBonds({ feature = { MultiContinentSnapshotContractVersion = 2 } })
    local ok, reason = cases[BONDS_CASE]()
    assert(ok == false and tostring(reason) == 'presentation_command_contract', 'reason=' .. tostring(reason))
end)

Test('life_bonds：静态 —— core/*.lua 不得再点名该 Feature', function()
    local f = assert(io.open('core/rs_foundation_gate.lua', 'rb'))
    local text = f:read('*a'); f:close()
    assert(text:find('S.Features.Bonds', 1, true) == nil, 'Foundation must not hard-code life_bonds')
    assert(text:find('S.Features and S.Features.Bonds', 1, true) == nil, 'Foundation must not hard-code life_bonds')
end)

------------------------------------------------------------------------
-- Phase 3 Batch D：life_tasks / life_activities / combat_gear 的悬浮窗命令面
-- （core/rs_foundation_gate.lua 的 v3_presentation_feature_api_contract 整块已删除）
--
-- 原先 Foundation 点名三个业务 Feature 的实现表，各查一条 Commands 命令是否存在。
-- 三处判定现在分别由各自 acceptance 覆盖（tasks: presentation_command_contract；
-- activities: 同类命令面检查；gear: quick_button_snap_settings_contract）。
-- 搬迁补齐点一致：实现缺失时旧 acceptance 静默 return = 没有检查。
------------------------------------------------------------------------
local function BootForMissingFeature(featureKey, acceptancePath)
    local cases = {}
    local S = { Features = {}, FoundationGate = {},
        SafeTraceback = debug and debug.traceback or function(m) return m end }
    function S.FoundationGate:RegisterSequenceCase(id, fn) cases[tostring(id)] = fn; return true end
    S.Features[featureKey] = nil -- 故意让实现缺失：这是本批要证明的场景
    ReplicatedSuite = S
    dofile(acceptancePath)
    return cases
end

local BatchDMissing = {
    { key = 'Tasks', case = 'v3_m1_tasks', path = 'features/life/tasks/rs_task_acceptance.lua' },
    { key = 'Activities', case = 'v3_m1_activities', path = 'features/life/activities/rs_activity_acceptance.lua' },
    { key = 'Gear', case = 'v3_m4_gear_screen_buttons', path = 'features/combat/gear/rs_gear_acceptance.lua' },
}

for _, item in ipairs(BatchDMissing) do
    Test('BatchD ' .. item.key .. '：实现未注册时仍注册 case 并失败（搬迁补齐）', function()
        local cases = BootForMissingFeature(item.key, item.path)
        assert(type(cases[item.case]) == 'function', item.case .. ' must register even when the Feature is missing')
        local ok, reason = cases[item.case]()
        assert(ok == false and tostring(reason) == 'implementation_not_registered', 'reason=' .. tostring(reason))
    end)
end

Test('BatchD 静态：core/*.lua 不得再点名这三个 Feature', function()
    local f = assert(io.open('core/rs_foundation_gate.lua', 'rb'))
    local text = f:read('*a'); f:close()
    -- 注意：搬迁说明注释里会写出被删掉的 check id，所以这里必须匹配**真正的 AddCheck 调用**，
    -- 而不是名字出现（否则注释会把自己的说明文字判成违规）。
    assert(text:find('AddCheck(report, "v3_presentation_feature_api_contract"', 1, true) == nil,
        'the removed presentation API contract must not come back')
    -- 只断言**本批删掉的**内容：那两个 Command 名在 Foundation 里已无任何合法用处。
    -- Tasks / Activities 的实现表访问在 Batch E 范围里仍合法存在，这里不越界断言。
    for _, pattern in ipairs({ 'SetWidgetWindowState', 'ResetQuickSnapSettings' }) do
        assert(text:find(pattern, 1, true) == nil, 'Foundation still references: ' .. pattern)
    end
end)

------------------------------------------------------------------------
-- Phase 3 Batch E：观察契约（combat_target_monitor / combat_buff_cap / Treasure / Fishing）
-- （core/rs_foundation_gate.lua 的 v3_dynamic_observation_contract 整块已删除）
--
-- 这四个 Feature 原先**没有 acceptance**，所以本批是"先建 Authority 再删旧分支"：
-- 为每个新建 rs_*_acceptance.lua 承载观察契约，并让它成为原判定的严格超集。
-- 两个"更严"点：旧判定允许空 topic（消费方无法订阅），也不要求 Demand 存在
-- （没有 Demand 就没有订阅生命周期，topic 形同虚设）。
------------------------------------------------------------------------
local ObservationFeatures = {
    { key = 'combat_target_monitor', case = 'v3_combat_target_monitor_observation_contract',
        path = 'features/combat/target_monitor/rs_target_monitor_acceptance.lua' },
    { key = 'combat_buff_cap', case = 'v3_combat_buff_cap_observation_contract',
        path = 'features/combat/buff_cap/rs_buff_cap_acceptance.lua' },
    { key = 'Treasure', case = 'v3_life_treasure_observation_contract',
        path = 'features/life/treasure/rs_treasure_acceptance.lua' },
    { key = 'Fishing', case = 'v3_life_fishing_observation_contract',
        path = 'features/life/fishing/rs_fishing_acceptance.lua' },
}

local function BootObservation(item, feature)
    local cases = {}
    local S = { Features = {}, FoundationGate = {},
        SafeTraceback = debug and debug.traceback or function(m) return m end }
    function S.FoundationGate:RegisterSequenceCase(id, fn) cases[tostring(id)] = fn; return true end
    if feature ~= nil then S.Features[item.key] = feature end
    ReplicatedSuite = S
    dofile(item.path)
    return cases
end

local function GoodObservation()
    return { ObservationContractVersion = 1, UpdateTopic = 'v3.test.topic',
        Demand = { Acquire = function() end, Release = function() end } }
end

for _, item in ipairs(ObservationFeatures) do
    Test('BatchE ' .. item.key .. '：实现未注册 → case 仍注册且失败', function()
        local cases = BootObservation(item, nil)
        assert(type(cases[item.case]) == 'function', item.case .. ' must register even when missing')
        local ok, reason = cases[item.case]()
        assert(ok == false and tostring(reason) == 'implementation_not_registered', 'reason=' .. tostring(reason))
    end)

    Test('BatchE ' .. item.key .. '：合规观察契约通过（搬迁未误伤）', function()
        local ok, reason = BootObservation(item, GoodObservation())[item.case]()
        assert(ok == true, 'compliant feature must pass, got ' .. tostring(reason))
    end)

    Test('BatchE ' .. item.key .. '：空 UpdateTopic 必须被拒（新 Authority 严于旧判定）', function()
        local feature = GoodObservation(); feature.UpdateTopic = ''
        local ok, reason = BootObservation(item, feature)[item.case]()
        assert(ok == false and tostring(reason) == 'observation_update_topic_empty', 'reason=' .. tostring(reason))
    end)

    Test('BatchE ' .. item.key .. '：Demand 缺失必须被拒（新 Authority 严于旧判定）', function()
        local feature = GoodObservation(); feature.Demand = nil
        local ok, reason = BootObservation(item, feature)[item.case]()
        assert(ok == false and tostring(reason) == 'demand_missing', 'reason=' .. tostring(reason))
    end)
end

Test('BatchE 静态：core/*.lua 不得再点名这四份观察契约', function()
    local f = assert(io.open('core/rs_foundation_gate.lua', 'rb'))
    local text = f:read('*a'); f:close()
    assert(text:find('AddCheck(report, "v3_dynamic_observation_contract"', 1, true) == nil,
        'the removed observation contract must not come back')
    -- 只断言本批删除的三个（Fishing 的实现表访问在 Batch F 的 truth 契约里仍合法存在）。
    for _, pattern in ipairs({ 'S.Features and S.Features.combat_target_monitor',
        'S.Features and S.Features.combat_buff_cap', 'S.Features and S.Features.Treasure' }) do
        assert(text:find(pattern, 1, true) == nil, 'Foundation still references: ' .. pattern)
    end
end)

------------------------------------------------------------------------
-- Phase 3 Batch F：life_fishing 的 Auto-R 事务契约 + tools_reinforce_analysis 的运行时阻塞真值
-- （core/rs_foundation_gate.lua 的 v3_feature_truth_contract 里那两段点名断言已删除；
--  该 AddCheck 的 Registry 真值表循环保持原样）
--
-- 一个 Feature 是把契约**追加**进已存在的 acceptance（fishing），另一个是**新建** acceptance（reinforce）。
------------------------------------------------------------------------
local FISHING_PATH = 'features/life/fishing/rs_fishing_acceptance.lua'
local REINFORCE_PATH = 'features/tools/reinforce_analysis/rs_reinforce_analysis_acceptance.lua'
local FISHING_AUTO_R = 'v3_life_fishing_auto_r_transaction_contract'
local REINFORCE_CASE = 'v3_tools_reinforce_analysis_runtime_block_contract'

local function BootTruth(key, path, feature, services)
    local cases = {}
    local S = { Features = {}, Services = services or {}, FoundationGate = {},
        SafeTraceback = debug and debug.traceback or function(m) return m end }
    function S.FoundationGate:RegisterSequenceCase(id, fn) cases[tostring(id)] = fn; return true end
    if feature ~= nil then S.Features[key] = feature end
    ReplicatedSuite = S
    dofile(path)
    return cases
end

local function FishingTruthFeature()
    return { HotkeyRuntimeBlocked = false, HotkeyContractVersion = 3 }
end

local function FishingHotkeyService(version)
    return { TransactionContractVersion = version == nil and 3 or version }
end

Test('BatchF life_fishing：Auto-R 契约 —— 实现未注册时仍注册 case 并失败', function()
    local cases = BootTruth('Fishing', FISHING_PATH, nil)
    assert(type(cases[FISHING_AUTO_R]) == 'function', 'case must register even when the Feature is missing')
    local ok, reason = cases[FISHING_AUTO_R]()
    assert(ok == false and tostring(reason) == 'implementation_not_registered', 'reason=' .. tostring(reason))
end)

Test('BatchF life_fishing：Auto-R 契约 —— 合规通过（搬迁未误伤）', function()
    local cases = BootTruth('Fishing', FISHING_PATH, FishingTruthFeature(),
        { FishingHotkeyV3 = FishingHotkeyService() })
    local ok, reason = cases[FISHING_AUTO_R]()
    assert(ok == true, 'compliant contract must pass, got ' .. tostring(reason))
end)

Test('BatchF life_fishing：Auto-R 被硬阻塞必须失败', function()
    local feature = FishingTruthFeature(); feature.HotkeyRuntimeBlocked = true
    local cases = BootTruth('Fishing', FISHING_PATH, feature, { FishingHotkeyV3 = FishingHotkeyService() })
    local ok, reason = cases[FISHING_AUTO_R]()
    assert(ok == false and tostring(reason) == 'auto_r_hard_blocked', 'reason=' .. tostring(reason))
end)

Test('BatchF life_fishing：热键契约版本回退必须失败', function()
    local feature = FishingTruthFeature(); feature.HotkeyContractVersion = 2
    local cases = BootTruth('Fishing', FISHING_PATH, feature, { FishingHotkeyV3 = FishingHotkeyService() })
    local ok, reason = cases[FISHING_AUTO_R]()
    assert(ok == false and tostring(reason) == 'hotkey_contract_version', 'reason=' .. tostring(reason))
end)

Test('BatchF life_fishing：独立热键事务服务缺失/版本不足必须失败', function()
    local cases = BootTruth('Fishing', FISHING_PATH, FishingTruthFeature(), nil)
    local ok, reason = cases[FISHING_AUTO_R]()
    assert(ok == false and tostring(reason) == 'fishing_hotkey_service_missing', 'reason=' .. tostring(reason))
    local cases2 = BootTruth('Fishing', FISHING_PATH, FishingTruthFeature(),
        { FishingHotkeyV3 = FishingHotkeyService(2) })
    local ok2, reason2 = cases2[FISHING_AUTO_R]()
    assert(ok2 == false and tostring(reason2) == 'hotkey_transaction_contract_version', 'reason=' .. tostring(reason2))
end)

Test('BatchF tools_reinforce_analysis：实现未注册时仍注册 case 并失败', function()
    local cases = BootTruth('tools_reinforce_analysis', REINFORCE_PATH, nil)
    assert(type(cases[REINFORCE_CASE]) == 'function', 'case must register even when the Feature is missing')
    local ok, reason = cases[REINFORCE_CASE]()
    assert(ok == false and tostring(reason) == 'implementation_not_registered', 'reason=' .. tostring(reason))
end)

Test('BatchF tools_reinforce_analysis：显式声明硬阻塞才通过', function()
    local okFeature, reasonFeature = BootTruth('tools_reinforce_analysis', REINFORCE_PATH,
        { SlotProbeRuntimeBlocked = true })[REINFORCE_CASE]()
    assert(okFeature == true, 'declared block must pass, got ' .. tostring(reasonFeature))
end)

Test('BatchF tools_reinforce_analysis：未声明硬阻塞必须失败', function()
    local ok, reason = BootTruth('tools_reinforce_analysis', REINFORCE_PATH,
        { SlotProbeRuntimeBlocked = false })[REINFORCE_CASE]()
    assert(ok == false and tostring(reason) == 'slot_probe_runtime_block_missing', 'reason=' .. tostring(reason))
end)

Test('BatchF 静态：core/*.lua 不得再点名这两处真值契约', function()
    local f = assert(io.open('core/rs_foundation_gate.lua', 'rb'))
    local text = f:read('*a'); f:close()
    -- 注意：v3_feature_truth_contract 这个 AddCheck **仍然保留**（它同时承载 Registry 真值表），
    -- 所以只能断言“被删掉的那两条失败原因串 / 那个被读走的标志”不再出现。
    assert(text:find('life_fishing:auto_r_transaction', 1, true) == nil,
        'the removed fishing auto-R truth check must not come back')
    assert(text:find('tools_reinforce_analysis:slot_probe_runtime_block', 1, true) == nil,
        'the removed reinforce truth check must not come back')
    assert(text:find('SlotProbeRuntimeBlocked', 1, true) == nil,
        'Foundation must not read the reinforce runtime-block flag any more')
    assert(text:find('FishingHotkeyV3', 1, true) == nil,
        'Foundation must not read the fishing hotkey service any more')
end)

------------------------------------------------------------------------
-- Phase 3 Batch G：Core 诊断不再按 id 读业务 Feature
--   新增 core/rs_feature_health_providers.lua（Feature 自注册的“投影取值表”），
--   core/rs_diagnostics.lua 的 6 处按 id 访问全部改为按用途名取值。
--   这也是 §25.2 descriptor 里 RuntimeHealthProvider 字段的第一个实际用例。
------------------------------------------------------------------------
local FHP_PATH = 'core/rs_feature_health_providers.lua'

local function BootFHP()
    local S = { Generation = 1 }
    ReplicatedSuite = S
    dofile(FHP_PATH)
    return S.FeatureHealthProviders
end

Test('BatchG 取值表：注册后可取值，未注册为 nil', function()
    local R = BootFHP()
    assert(type(R) == 'table' and tonumber(R.ContractVersion) == 1, 'registry contract version changed')
    assert(R:Get('missing_key') == nil, 'unregistered key must read nil')
    assert(R:Has('missing_key') == false, 'unregistered key must not report Has')
    assert(R:Register('k', function() return { rows = 3 } end) == true, 'register must succeed')
    assert(type(R:Get('k')) == 'table' and R:Get('k').rows == 3, 'registered provider must be called')
    assert(R:Has('k') == true, 'registered key must report Has')
end)

Test('BatchG 取值表：无效注册被拒', function()
    local R = BootFHP()
    assert(R:Register('', function() end) == false, 'empty key must be rejected')
    assert(R:Register('k', nil) == false, 'non-function provider must be rejected')
end)

Test('BatchG 取值表：provider 抛错隔离为 nil 并计数（单模块坏掉不拖垮整份快照）', function()
    local R = BootFHP()
    R:Register('boom', function() error('provider exploded') end)
    assert(R:Get('boom') == nil, 'a throwing provider must degrade to nil instead of breaking the snapshot')
    local described = R:Describe()
    assert(tonumber(described.errors) >= 1 and described.lastErrorKey == 'boom', 'throwing provider must be counted')
end)

Test('BatchG 取值表：重复注册以最后一次为准（重载语义）', function()
    local R = BootFHP()
    R:Register('same', function() return 'first' end)
    R:Register('same', function() return 'second' end)
    assert(R:Get('same') == 'second', 'last registration must win')
    assert(tonumber(R:Describe().registered) == 1, 'duplicate key must not be counted twice')
end)

Test('BatchG 静态：core 诊断不得再按 id 读业务 Feature', function()
    local f = assert(io.open('core/rs_diagnostics.lua', 'rb'))
    local text = f:read('*a'); f:close()
    assert(text:find('S.Features.', 1, true) == nil,
        'core/rs_diagnostics.lua must not access the feature implementation table any more')
end)

Test('BatchG 静态：五个投影由各自 Feature 文件注册', function()
    local expected = {
        { path = 'features/combat/buff_display/rs_buff_display_feature.lua',
            keys = { 'buff_display_health', 'buff_hud_calibration' } },
        { path = 'features/combat/unit_lines/rs_unit_lines_feature.lua', keys = { 'unit_lines_diagnostics' } },
        { path = 'features/combat/boss_alerts/rs_boss_alerts_feature.lua', keys = { 'boss_alerts_diagnostics' } },
        { path = 'features/combat/death_review/rs_death_review_feature.lua', keys = { 'death_review_health' } },
    }
    for _, item in ipairs(expected) do
        local f = assert(io.open(item.path, 'rb'))
        local text = f:read('*a'); f:close()
        assert(text:find('FeatureHealthProviders', 1, true) ~= nil, item.path .. ' must register its projection')
        for _, key in ipairs(item.keys) do
            assert(text:find('"' .. key .. '"', 1, true) ~= nil, item.path .. ' must register key ' .. key)
        end
    end
end)

Test('BatchG 静态：诊断侧确实改用了取值表的用途名', function()
    local f = assert(io.open('core/rs_diagnostics.lua', 'rb'))
    local text = f:read('*a'); f:close()
    for _, key in ipairs({ 'buff_hud_calibration', 'unit_lines_diagnostics', 'buff_display_health',
        'boss_alerts_diagnostics', 'death_review_health' }) do
        assert(text:find('Get("' .. key .. '")', 1, true) ~= nil, 'diagnostics must read key ' .. key)
    end
end)

Test('BatchG 静态：取值表已登记进 toc.g 且排在诊断之前', function()
    local f = assert(io.open('toc.g', 'rb'))
    local text = f:read('*a'); f:close()
    local registry = text:find('core/rs_feature_health_providers.lua', 1, true)
    local diagnostics = text:find('core/rs_diagnostics.lua', 1, true)
    assert(registry ~= nil, 'the registry must be in toc.g')
    assert(diagnostics ~= nil and registry < diagnostics, 'the registry must load before diagnostics')
end)

------------------------------------------------------------------------
-- Phase 3 Batch H：v3_combat_life_usability_contract 里的四个业务 Feature 判定
--   boss_alerts / unit_lines / range_assist 三个**新建** acceptance；
--   buff_display 是给已存在的 acceptance **追加**一个 observation 契约 case。
--   同一条 AddCheck 里的 Service / UIV3 契约（screenProjection / alerts / visualGuides /
--   lifeWidgets / trade-bonds widget）保持原样不动 —— 它们不是 Feature 债。
------------------------------------------------------------------------
local ContractCases = {
    { key = 'combat_boss_alerts', path = 'features/combat/boss_alerts/rs_boss_alerts_acceptance.lua',
        case = 'v3_combat_boss_alerts_hud_contract',
        good = { HudContractVersion = 4, RealtimeFactBridgeContractVersion = 2, _bossDiag = {} },
        fields = { { 'HudContractVersion', 2 }, { 'RealtimeFactBridgeContractVersion', 1 } } },
    { key = 'combat_unit_lines', path = 'features/combat/unit_lines/rs_unit_lines_acceptance.lua',
        case = 'v3_combat_unit_lines_visual_guide_contract',
        good = { VisualGuideContractVersion = 5, AdaptiveDensityContractVersion = 2, SmoothRefreshContractVersion = 1,
            FrontHemisphereContractVersion = 1, ProjectionConsistencyContractVersion = 1 },
        fields = { { 'VisualGuideContractVersion', 5 }, { 'AdaptiveDensityContractVersion', 2 },
            { 'SmoothRefreshContractVersion', 1 }, { 'FrontHemisphereContractVersion', 1 },
            { 'ProjectionConsistencyContractVersion', 1 } } },
    { key = 'combat_range_assist', path = 'features/combat/range_assist/rs_range_assist_acceptance.lua',
        case = 'v3_combat_range_assist_visual_guide_contract',
        good = { VisualGuideContractVersion = 9, WorldSpaceContractVersion = 3, ProjectionFactsContractVersion = 7,
            AnchorCalibrationContractVersion = 2, MetricDistanceContractVersion = 1 },
        fields = { { 'VisualGuideContractVersion', 9 }, { 'WorldSpaceContractVersion', 3 },
            { 'ProjectionFactsContractVersion', 7 }, { 'AnchorCalibrationContractVersion', 2 },
            { 'MetricDistanceContractVersion', 1 } } },
}

local function CopyTable(source)
    local out = {}
    for key, value in pairs(source or {}) do out[key] = value end
    return out
end

for _, item in ipairs(ContractCases) do
    Test('BatchH ' .. item.key .. '：实现未注册 → case 仍注册且失败', function()
        local cases = BootTruth(item.key, item.path, nil)
        assert(type(cases[item.case]) == 'function', item.case .. ' must register even when missing')
        local ok, reason = cases[item.case]()
        assert(ok == false and tostring(reason) == 'implementation_not_registered', 'reason=' .. tostring(reason))
    end)

    Test('BatchH ' .. item.key .. '：合规契约通过（搬迁未误伤）', function()
        local ok, reason = BootTruth(item.key, item.path, CopyTable(item.good))[item.case]()
        assert(ok == true, 'compliant feature must pass, got ' .. tostring(reason))
    end)

    for _, field in ipairs(item.fields) do
        Test('BatchH ' .. item.key .. '：' .. field[1] .. ' 回退到 ' .. tostring(field[2] - 1) .. ' 必须被拒', function()
            local feature = CopyTable(item.good)
            feature[field[1]] = field[2] - 1
            local ok, reason = BootTruth(item.key, item.path, feature)[item.case]()
            assert(ok == false, field[1] .. ' below the floor must be rejected')
            assert(tostring(reason) ~= '' and reason ~= nil, 'rejection must carry a reason')
        end)
    end
end

Test('BatchH combat_buff_display：观察契约 —— 实现未注册时失败', function()
    local cases = BootTruth('BuffDisplay', 'features/combat/buff_display/rs_buff_display_acceptance.lua', nil)
    local case = 'v3_combat_buff_display_observation_contract'
    assert(type(cases[case]) == 'function', 'observation case must register even when missing')
    local ok, reason = cases[case]()
    assert(ok == false and tostring(reason) == 'implementation_not_registered', 'reason=' .. tostring(reason))
end)

Test('BatchH combat_buff_display：观察契约 —— 合规通过 / health 不可用 / 版本回退', function()
    local path = 'features/combat/buff_display/rs_buff_display_acceptance.lua'
    local case = 'v3_combat_buff_display_observation_contract'
    local okGood, reasonGood = BootTruth('BuffDisplay', path,
        { GetHealth = function() return { observationContractVersion = 2 } end })[case]()
    assert(okGood == true, 'compliant observation contract must pass, got ' .. tostring(reasonGood))

    local okNoHealth, reasonNoHealth = BootTruth('BuffDisplay', path, {})[case]()
    assert(okNoHealth == false and tostring(reasonNoHealth) == 'health_unavailable', 'reason=' .. tostring(reasonNoHealth))

    local okOld, reasonOld = BootTruth('BuffDisplay', path,
        { GetHealth = function() return { observationContractVersion = 1 } end })[case]()
    assert(okOld == false and tostring(reasonOld) == 'observation_contract_version', 'reason=' .. tostring(reasonOld))
end)

Test('BatchH 静态：core/*.lua 不得再点名这四个 Feature，且 buff_observation 判定已撤', function()
    local f = assert(io.open('core/rs_foundation_gate.lua', 'rb'))
    local text = f:read('*a'); f:close()
    -- 断言用**带点号/带引号的精确形态**，理由是：
    --   * 带点号 -> 只匹配“读该 Feature 实现表的字段”，不会误伤 screenProjection 侧的同名字段
    --     （例如 UnitProjectionConsistencyContractVersion 是 Service 的、不是 unit_lines 的）；
    --   * 带引号 -> 不会把搬迁说明注释里的裸词判成违规。
    for _, pattern in ipairs({ 'bossAlerts.', 'unitLines.', 'rangeAssist.', 'buffDisplay2.', 'buffHealth2.',
        '"buff_observation"' }) do
        assert(text:find(pattern, 1, true) == nil, 'Foundation still references: ' .. pattern)
    end
    -- 还必须挡住“用完整实现表访问把判定回填回去”这条路径：只断言字段名不够 ——
    -- 例如重新写 `local unitLines = <实现表>.combat_unit_lines` 就绕过了上面的点号断言。
    -- （BuffDisplay 不在这一组里 —— 它在 §25.6.9 的另一处判定里仍有合法引用，留待后续批次。）
    for _, pattern in ipairs({ 'S.Features.combat_unit_lines', 'S.Features.combat_boss_alerts',
        'S.Features.combat_range_assist' }) do
        assert(text:find(pattern, 1, true) == nil, 'Foundation must not read the feature table for: ' .. pattern)
    end
    -- 这几个契约字段在 Foundation 里已无任何合法用处，可作无歧义断言。
    for _, field in ipairs({ 'HudContractVersion', 'RealtimeFactBridgeContractVersion',
        'AdaptiveDensityContractVersion', 'FrontHemisphereContractVersion',
        'WorldSpaceContractVersion', 'ProjectionFactsContractVersion', 'MetricDistanceContractVersion' }) do
        assert(text:find(field, 1, true) == nil, 'Foundation still references contract field: ' .. field)
    end
end)

------------------------------------------------------------------------
-- Phase 3 Batch I：tools_auction / tools_market_analysis / tools_craft
--   三个 Feature 原先都没有 acceptance；它们的契约散在 Foundation 的三个 AddCheck 里
--   （v3_auction_query_contract / v3_auction_sidecar_contract / v3_auction_workspace_contract /
--    v3_craft_user_selection_contract / v3_craft_sidecar_contract）。
--   **同一条 AddCheck 里的 Service / UIV3 契约留在 Foundation** —— 它们不是 Feature 债。
------------------------------------------------------------------------
local ToolCases = {
    { key = 'tools_auction', path = 'features/tools/auction/rs_auction_acceptance.lua',
        case = 'v3_tools_auction_contract',
        good = { AuctionQueryContractVersion = 1, SidecarPreferenceContractVersion = 1,
            IsSidecarEnabled = function() return true end,
            Commands = { Search = function() end, SetSidecarEnabled = function() end,
                RenameFavorite = function() end, MoveFavorite = function() end,
                RemoveFavoriteByKeyword = function() end, ClearFavorites = function() end } },
        checks = {
            { label = 'AuctionQueryContractVersion 回退', mutate = function(f) f.AuctionQueryContractVersion = 0 end },
            { label = '缺少 Search 命令', mutate = function(f) f.Commands.Search = nil end },
            { label = 'SidecarPreferenceContractVersion 回退', mutate = function(f) f.SidecarPreferenceContractVersion = 0 end },
            { label = '缺少 SetSidecarEnabled 命令', mutate = function(f) f.Commands.SetSidecarEnabled = nil end },
            { label = '缺少收藏 CRUD 命令', mutate = function(f) f.Commands.ClearFavorites = nil end },
        } },
    { key = 'tools_market_analysis', path = 'features/tools/market_analysis/rs_market_analysis_acceptance.lua',
        case = 'v3_tools_market_analysis_contract',
        good = { AuctionQueryContractVersion = 1, Commands = { Search = function() end } },
        checks = {
            { label = 'AuctionQueryContractVersion 回退', mutate = function(f) f.AuctionQueryContractVersion = 0 end },
            { label = '缺少 Search 命令', mutate = function(f) f.Commands.Search = nil end },
        } },
    { key = 'tools_craft', path = 'features/tools/craft/rs_craft_acceptance.lua',
        case = 'v3_tools_craft_contract',
        good = { CraftUserSelectionContractVersion = 1, CraftSidecarContractVersion = 1,
            Commands = { SelectRecipe = function() end, SetAutoSidecar = function() end } },
        checks = {
            { label = 'CraftUserSelectionContractVersion 回退', mutate = function(f) f.CraftUserSelectionContractVersion = 0 end },
            { label = '缺少 SelectRecipe 命令', mutate = function(f) f.Commands.SelectRecipe = nil end },
            { label = 'CraftSidecarContractVersion 回退', mutate = function(f) f.CraftSidecarContractVersion = 0 end },
            { label = '缺少 SetAutoSidecar 命令', mutate = function(f) f.Commands.SetAutoSidecar = nil end },
        } },
}

local function DeepCopySmall(source)
    local out = {}
    for key, value in pairs(source or {}) do
        if type(value) == 'table' then
            local nested = {}
            for innerKey, innerValue in pairs(value) do nested[innerKey] = innerValue end
            out[key] = nested
        else
            out[key] = value
        end
    end
    return out
end

for _, item in ipairs(ToolCases) do
    Test('BatchI ' .. item.key .. '：实现未注册 → case 仍注册且失败', function()
        local cases = BootTruth(item.key, item.path, nil)
        assert(type(cases[item.case]) == 'function', item.case .. ' must register even when missing')
        local ok, reason = cases[item.case]()
        assert(ok == false and tostring(reason) == 'implementation_not_registered', 'reason=' .. tostring(reason))
    end)

    Test('BatchI ' .. item.key .. '：合规契约通过（搬迁未误伤）', function()
        local ok, reason = BootTruth(item.key, item.path, DeepCopySmall(item.good))[item.case]()
        assert(ok == true, 'compliant feature must pass, got ' .. tostring(reason))
    end)

    for _, check in ipairs(item.checks) do
        Test('BatchI ' .. item.key .. '：' .. check.label .. ' 必须被拒', function()
            local feature = DeepCopySmall(item.good)
            check.mutate(feature)
            local ok, reason = BootTruth(item.key, item.path, feature)[item.case]()
            assert(ok == false, check.label .. ' must be rejected')
            assert(reason ~= nil and tostring(reason) ~= '', 'rejection must carry a reason')
        end)
    end
end

Test('BatchI 静态：core/*.lua 不得再点名这三个 Feature（同时覆盖两种回填形态）', function()
    local f = assert(io.open('core/rs_foundation_gate.lua', 'rb'))
    local text = f:read('*a'); f:close()
    -- ① 完整实现表访问串（防“把判定整体搬回去”）
    for _, pattern in ipairs({ 'S.Features.tools_auction', 'S.Features.tools_market_analysis',
        'S.Features.tools_craft' }) do
        assert(text:find(pattern, 1, true) == nil, 'Foundation must not read the feature table for: ' .. pattern)
    end
    -- ② 带点号的字段访问（防“复述契约”）
    for _, pattern in ipairs({ 'AuctionQueryContractVersion', 'SidecarPreferenceContractVersion',
        'CraftUserSelectionContractVersion', 'CraftSidecarContractVersion' }) do
        assert(text:find(pattern, 1, true) == nil, 'Foundation still references contract field: ' .. pattern)
    end
    -- 已删除的判定壳子不得回来（auctionQueryOk 仍然合法存在 —— 它现在还承载 Service 侧契约）
    for _, pattern in ipairs({ 'craftSelectionOk', 'craftAssistant' }) do
        assert(text:find(pattern, 1, true) == nil, 'removed binding must not come back: ' .. pattern)
    end
end)

------------------------------------------------------------------------
-- Phase 3 Batch J：Gear 的快速启动意图契约
--   （core/rs_foundation_gate.lua 的 v3_quick_surface_reload_reconcile_contract 里的 Feature 部分已删除；
--     FeatureRuntime 侧的启动意图契约版本留在 Foundation —— 那是 Core 自己的框架，不是 Feature 债）
------------------------------------------------------------------------
local GEAR_QUICK_PATH = 'features/combat/gear/rs_gear_acceptance.lua'
local GEAR_QUICK_CASE = 'v3_m4_gear_quick_startup_intent_contract'

local function GearQuickFeature()
    return { QuickStartupIntentContractVersion = 1, GetStartupEnableIntent = function() end,
        OnStartupEnableIntentCommitted = function() end, ShouldShowQuickButtons = function() return false end }
end

Test('BatchJ Gear：实现未注册 → case 仍注册且失败', function()
    local cases = BootTruth('Gear', GEAR_QUICK_PATH, nil)
    assert(type(cases[GEAR_QUICK_CASE]) == 'function', 'case must register even when missing')
    local ok, reason = cases[GEAR_QUICK_CASE]()
    assert(ok == false and tostring(reason) == 'implementation_not_registered', 'reason=' .. tostring(reason))
end)

Test('BatchJ Gear：合规契约通过（搬迁未误伤）', function()
    local ok, reason = BootTruth('Gear', GEAR_QUICK_PATH, GearQuickFeature())[GEAR_QUICK_CASE]()
    assert(ok == true, 'compliant feature must pass, got ' .. tostring(reason))
end)

Test('BatchJ Gear：契约版本回退 / 缺任一函数都必须被拒', function()
    local function Reject(mutate, label)
        local feature = GearQuickFeature()
        mutate(feature)
        local ok, reason = BootTruth('Gear', GEAR_QUICK_PATH, feature)[GEAR_QUICK_CASE]()
        assert(ok == false, label .. ' must be rejected')
        assert(reason ~= nil and tostring(reason) ~= '', 'rejection must carry a reason')
    end
    Reject(function(f) f.QuickStartupIntentContractVersion = 0 end, '契约版本回退')
    Reject(function(f) f.GetStartupEnableIntent = nil end, '缺 GetStartupEnableIntent')
    Reject(function(f) f.OnStartupEnableIntentCommitted = nil end, '缺 OnStartupEnableIntentCommitted')
    Reject(function(f) f.ShouldShowQuickButtons = nil end, '缺 ShouldShowQuickButtons')
end)

Test('BatchJ 静态：core/*.lua 不得再点名 Gear 的快速启动意图（同时覆盖两种回填形态）', function()
    local f = assert(io.open('core/rs_foundation_gate.lua', 'rb'))
    local text = f:read('*a'); f:close()
    -- ① 完整实现表访问串
    assert(text:find('S.Features.Gear', 1, true) == nil, 'Foundation must not read the Gear feature table')
    -- ② 带点号的字段访问 / 已删除的判定壳子
    for _, pattern in ipairs({ 'gearFeature', 'QuickStartupIntentContractVersion', 'GetStartupEnableIntent',
        'OnStartupEnableIntentCommitted', 'ShouldShowQuickButtons' }) do
        assert(text:find(pattern, 1, true) == nil, 'Foundation still references: ' .. pattern)
    end
    -- FeatureRuntime 侧的契约必须**保留**（它是 Core 框架，不是 Feature 债）
    assert(text:find('StartupEnableIntentContractVersion', 1, true) ~= nil,
        'the FeatureRuntime startup-intent contract must stay in Foundation')
end)

------------------------------------------------------------------------
-- Phase 3 Batch K：combat_team_tools 的角色契约 + 视觉/标记契约
--   （core/rs_foundation_gate.lua 的两条判定 v3_team_role_contract /
--     v3_team_visual_marker_contract 里的 Feature 部分已删除）
--   **同一条判定里的 Service / Data / UIV3 契约留在 Foundation**（TeamRosterV3 的团队边沿 settle、
--     静态职责目录及两个已确认职业组合、TeamSacOverlay 的呈现契约）—— 这不是 Feature 债。
------------------------------------------------------------------------
local TEAM_PATH = 'features/combat/team_tools/rs_team_tools_acceptance.lua'
local TEAM_ROLE_CASE = 'v3_combat_team_tools_role_contract'
local TEAM_VISUAL_CASE = 'v3_combat_team_tools_visual_marker_contract'

local function TeamToolsFeature()
    return {
        TeamRoleContractVersion = 2, AutoRoleContractVersion = 3,
        AutoRoleCatalogContractVersion = 2, AutoRoleRosterLeaseContractVersion = 1,
        TeamVisualContractVersion = 2, TeamMarkerSnapshotContractVersion = 1,
        TeamSacContractVersion = 2, AutoRoleDefaultOnContractVersion = 1,
        Commands = { SetRole = function() end, SetSacHighlightEnabled = function() end,
            SaveRaidMarkers = function() end, RestoreRaidMarkers = function() end,
            ClearSavedRaidMarkers = function() end },
    }
end

Test('BatchK team_tools：实现未注册 → 两个 case 都注册且失败', function()
    local cases = BootTruth('combat_team_tools', TEAM_PATH, nil)
    for _, name in ipairs({ TEAM_ROLE_CASE, TEAM_VISUAL_CASE }) do
        assert(type(cases[name]) == 'function', name .. ' must register even when missing')
        local ok, reason = cases[name]()
        assert(ok == false and tostring(reason) == 'implementation_not_registered', 'reason=' .. tostring(reason))
    end
end)

Test('BatchK team_tools：合规契约两个 case 都通过（搬迁未误伤）', function()
    for _, name in ipairs({ TEAM_ROLE_CASE, TEAM_VISUAL_CASE }) do
        local ok, reason = BootTruth('combat_team_tools', TEAM_PATH, TeamToolsFeature())[name]()
        assert(ok == true, name .. ' must pass for a compliant feature, got ' .. tostring(reason))
    end
end)

Test('BatchK team_tools：角色契约的每一项回退都必须被拒', function()
    local fields = { { 'TeamRoleContractVersion', 2 }, { 'AutoRoleContractVersion', 3 },
        { 'AutoRoleCatalogContractVersion', 2 }, { 'AutoRoleRosterLeaseContractVersion', 1 } }
    for _, field in ipairs(fields) do
        local feature = TeamToolsFeature()
        feature[field[1]] = field[2] - 1
        local ok, reason = BootTruth('combat_team_tools', TEAM_PATH, feature)[TEAM_ROLE_CASE]()
        assert(ok == false, field[1] .. ' below the floor must be rejected')
        assert(reason ~= nil and tostring(reason) ~= '', 'rejection must carry a reason')
    end
    local feature = TeamToolsFeature(); feature.Commands.SetRole = nil
    local ok, reason = BootTruth('combat_team_tools', TEAM_PATH, feature)[TEAM_ROLE_CASE]()
    assert(ok == false and tostring(reason) == 'set_role_command', 'reason=' .. tostring(reason))
end)

Test('BatchK team_tools：视觉/标记契约的每一项回退与缺命令都必须被拒', function()
    local fields = { { 'TeamVisualContractVersion', 2 }, { 'TeamMarkerSnapshotContractVersion', 1 },
        { 'TeamSacContractVersion', 2 }, { 'AutoRoleDefaultOnContractVersion', 1 } }
    for _, field in ipairs(fields) do
        local feature = TeamToolsFeature()
        feature[field[1]] = field[2] - 1
        local ok, reason = BootTruth('combat_team_tools', TEAM_PATH, feature)[TEAM_VISUAL_CASE]()
        assert(ok == false, field[1] .. ' below the floor must be rejected')
        assert(reason ~= nil and tostring(reason) ~= '', 'rejection must carry a reason')
    end
    for _, name in ipairs({ 'SetSacHighlightEnabled', 'SaveRaidMarkers', 'RestoreRaidMarkers', 'ClearSavedRaidMarkers' }) do
        local feature = TeamToolsFeature(); feature.Commands[name] = nil
        local ok, reason = BootTruth('combat_team_tools', TEAM_PATH, feature)[TEAM_VISUAL_CASE]()
        assert(ok == false, 'missing ' .. name .. ' must be rejected')
        assert(reason ~= nil and tostring(reason) ~= '', 'rejection must carry a reason')
    end
end)

Test('BatchK 静态：core/*.lua 不得再点名 team_tools，但 Service/Data/UIV3 侧必须保留', function()
    local f = assert(io.open('core/rs_foundation_gate.lua', 'rb'))
    local text = f:read('*a'); f:close()
    -- ① 完整实现表访问串
    assert(text:find('S.Features.combat_team_tools', 1, true) == nil,
        'Foundation must not read the team_tools feature table')
    -- ② 带点号的字段访问 / 已删除的判定壳子
    for _, pattern in ipairs({ 'teamTools.', 'TeamRoleContractVersion', 'AutoRoleContractVersion',
        'AutoRoleCatalogContractVersion', 'AutoRoleRosterLeaseContractVersion', 'TeamVisualContractVersion',
        'TeamMarkerSnapshotContractVersion', 'TeamSacContractVersion', 'AutoRoleDefaultOnContractVersion',
        'SetSacHighlightEnabled', 'SaveRaidMarkers', 'RestoreRaidMarkers', 'ClearSavedRaidMarkers' }) do
        assert(text:find(pattern, 1, true) == nil, 'Foundation still references: ' .. pattern)
    end
    -- 边界：这三侧的契约**必须留在 Foundation**（主语是 Service/Data/UIV3，不是 Feature）
    for _, pattern in ipairs({ 'TeamRosterV3', 'TeamEdgeSettleContractVersion', 'TeamAutoRoleCatalog',
        'TeamSacOverlay', 'TeamSacPresentationContractVersion' }) do
        assert(text:find(pattern, 1, true) ~= nil, 'the non-Feature counterpart must stay in Foundation: ' .. pattern)
    end
    -- 只查“字符串还在”不够 —— 还要确认判定**确实仍由 Service 侧推导**：
    -- 否则把整行改成 `local teamRoleOk = true`（搬太多）也能骗过上面那条。
    assert(text:find('local teamRoleOk = type(teamRoster) == "table"', 1, true) ~= nil,
        'teamRoleOk must still be derived from the TeamRoster service contract')
    assert(text:find('local teamVisualOk = type(teamSacOverlay) == "table"', 1, true) ~= nil,
        'teamVisualOk must still be derived from the TeamSacOverlay UI contract')
end)

------------------------------------------------------------------------
-- Phase 3 Batch L：Activities / Tasks 的 Persistence 契约组
--   （Foundation 里 v3_activity_persistence_recovery_contract 的 Feature 部分、
--     v3_feature_persistence_mutation_contract、v3_task_persistence_stable_codec_contract 已处置）
--   **Store 侧的 activityStore 契约留在 Foundation** —— 那是 Core 的 Persistence 边界。
--   活动侧还有一个「下限取齐」动作：KnownLegacyCanonicalRecoveryContractVersion 从 1 提到 3。
------------------------------------------------------------------------
local ACTIVITY_PATH = 'features/life/activities/rs_activity_acceptance.lua'
local TASK_PATH = 'features/life/tasks/rs_task_acceptance.lua'
local TASK_PERSIST_CASE = 'v3_life_tasks_persistence_contract'

local function ActivityFeature()
    return {
        StoreId = 'v3.activities',
        Authority = { ActivityTimelineSortContractVersion = 2, PriorityStageSortContractVersion = 1,
            GetTimelineRows = function() end, GetLiveRows = function() end },
        PersistenceStoreSchemaContractVersion = 8, PersistenceWindowCanonicalContractVersion = 1,
        KnownLegacyCanonicalRecoveryContractVersion = 3,
        TransportV1ZeroOmissionRecoveryContractVersion = 1,
        PersistenceMutationContractVersion = 2,
        Commands = { MarkStoreDirty = function() end, SetWidgetWindowState = function() end },
    }
end

local function BootActivity(overrides)
    local feature = ActivityFeature()
    for key, value in pairs(overrides or {}) do
        if key == 'Authority' then
            for innerKey, innerValue in pairs(value) do feature.Authority[innerKey] = innerValue end
        else
            feature[key] = value
        end
    end
    local cases = {}
    local S = { Features = { Activities = feature }, SafeTraceback = debug and debug.traceback or function(m) return m end,
        FoundationGate = {} }
    function S.FoundationGate:RegisterSequenceCase(id, fn) cases[tostring(id)] = fn; return true end
    S.FeatureRegistry = { Get = function(_, id)
        if id ~= 'life_activities' then return nil end
        return { status = 'migrated_m1', authority = 'v3.activity' } end }
    S.FeatureRuntime = { IsImplemented = function() return true end, IsEnabled = function() return false end }
    S.Persistence = { GetStore = function() return { owner = 'v3.activities', schemaVersion = 8,
        rebuildCanonicalForIntegrity = function() end, recoverKnownLegacyCanonical = function() end,
        allowIntegrityUpgrade = true } end }
    ReplicatedSuite = S
    dofile(ACTIVITY_PATH)
    return cases['v3_m1_activities']
end

Test('BatchL 活动：KnownLegacyCanonicalRecoveryContractVersion 下限已取齐到 3', function()
    -- 本批把该契约的下限从 1 提到 3（与原判定取齐）。2 必须被拒绝 —— 这是“取齐”的证据点。
    local okBad, reasonBad = BootActivity({ KnownLegacyCanonicalRecoveryContractVersion = 2 })()
    assert(okBad == false and tostring(reasonBad) == 'store_contract', 'reason=' .. tostring(reasonBad))
    -- 3 不得因为这个契约被拒。注：本宿主没有模拟 case 后段的 Service/UIV3 依赖，
    -- 所以这里只断言“失败原因不是 store_contract”，而不是断言整个 case 通过 ——
    -- 其余依赖链属于运行期，不在本批搬迁范围内。
    local _, reasonGood = BootActivity({})()
    assert(tostring(reasonGood) ~= 'store_contract',
        'contract version 3 must not be rejected by the store contract, got ' .. tostring(reasonGood))
end)

Test('BatchL 活动：排序分带 / Transport v1 零值恢复 / 持久化变更契约都必须被查', function()
    local cases = {
        { label = '排序分带契约', overrides = { Authority = { PriorityStageSortContractVersion = 0 } },
            reason = 'activity_priority_stage_sort_contract_version' },
        { label = 'Transport v1 零值恢复契约', overrides = { TransportV1ZeroOmissionRecoveryContractVersion = 0 },
            reason = 'activity_transport_v1_zero_omission_recovery_contract_version' },
        { label = '持久化变更契约', overrides = { PersistenceMutationContractVersion = 1 },
            reason = 'activity_persistence_mutation_contract_version' },
    }
    for _, item in ipairs(cases) do
        local ok, reason = BootActivity(item.overrides)()
        assert(ok == false and tostring(reason) == item.reason,
            item.label .. ' expected ' .. item.reason .. ', got ' .. tostring(reason))
    end
end)

Test('BatchL 任务：Persistence 契约 case 的三态', function()
    local cases = BootTruth('Tasks', TASK_PATH, nil)
    assert(type(cases[TASK_PERSIST_CASE]) == 'function', 'case must register even when missing')
    local okMissing, reasonMissing = cases[TASK_PERSIST_CASE]()
    assert(okMissing == false and tostring(reasonMissing) == 'implementation_not_registered',
        'reason=' .. tostring(reasonMissing))

    local okGood, reasonGood = BootTruth('Tasks', TASK_PATH,
        { PersistenceMutationContractVersion = 2, PersistenceCodecVersion = 2 })[TASK_PERSIST_CASE]()
    assert(okGood == true, 'compliant task persistence contract must pass, got ' .. tostring(reasonGood))

    local okMutation, reasonMutation = BootTruth('Tasks', TASK_PATH,
        { PersistenceMutationContractVersion = 1, PersistenceCodecVersion = 2 })[TASK_PERSIST_CASE]()
    assert(okMutation == false and tostring(reasonMutation) == 'task_persistence_mutation_contract_version',
        'reason=' .. tostring(reasonMutation))

    local okCodec, reasonCodec = BootTruth('Tasks', TASK_PATH,
        { PersistenceMutationContractVersion = 2, PersistenceCodecVersion = 1 })[TASK_PERSIST_CASE]()
    assert(okCodec == false and tostring(reasonCodec) == 'task_persistence_codec_version',
        'reason=' .. tostring(reasonCodec))
end)

Test('BatchL 静态：core/*.lua 不得再点名 Activities/Tasks，但 Store 侧必须保留', function()
    local f = assert(io.open('core/rs_foundation_gate.lua', 'rb'))
    local text = f:read('*a'); f:close()
    -- ① 完整实现表访问串
    for _, pattern in ipairs({ 'S.Features.Activities', 'S.Features.Tasks' }) do
        assert(text:find(pattern, 1, true) == nil, 'Foundation must not read the feature table for: ' .. pattern)
    end
    -- ② 带点号的字段访问 / 已删除的判定壳子
    for _, pattern in ipairs({ 'activities.', 'tasks.', 'persistenceMutationOk', 'taskCodecOk',
        'PriorityStageSortContractVersion', 'TransportV1ZeroOmissionRecoveryContractVersion',
        'PersistenceMutationContractVersion', 'PersistenceCodecVersion' }) do
        assert(text:find(pattern, 1, true) == nil, 'Foundation still references: ' .. pattern)
    end
    -- ③ Store 侧（Core 的 Persistence 边界）必须保留，且推导链仍在
    assert(text:find('local activityRecoveryOk = type(activityStore) == "table"', 1, true) ~= nil,
        'the Store-side recovery judgement must remain derived from activityStore')
    for _, pattern in ipairs({ 'recoverKnownLegacyCanonical', 'allowIntegrityUpgrade' }) do
        assert(text:find(pattern, 1, true) ~= nil, 'the Store-side contract must stay in Foundation: ' .. pattern)
    end
end)

------------------------------------------------------------------------
-- Phase 3 Batch M：BuffDisplay 的 HUD 校准/健康聚合段
--   （core/rs_foundation_gate.lua 的 buff_display_v3_statusmap_contract 里的 Feature 条件已删除，
--     buff_display_v3_runtime_scope 改为读取 Feature 自注册的 health 投影）
--   **Store 侧（两个 Store）、UIV3 侧（HeadMarkers / HudCalibration）、FeatureRegistry 元数据、
--     页面与悬浮窗注册全部保留在 Foundation**
--   搬迁前先做了契约覆盖差集扫描：发现 2 个字段只在 Foundation 存在（已补进 acceptance）。
------------------------------------------------------------------------
local BUFF_PATH = 'features/combat/buff_display/rs_buff_display_feature.lua'
local BUFF_ACC = 'features/combat/buff_display/rs_buff_display_acceptance.lua'

local function BuffContractFeature()
    local names = { 'BuffHeadMarkerContractVersion', 'GearScoreApiContractVersion',
        'HudCalibrationContractVersion', 'HudLayoutPageMeasureContractVersion', 'HudLayoutStoreContractVersion',
        'LayoutAuthorityContractVersion', 'LayoutPersistenceBoundaryContractVersion',
        'ManagementProjectionContractVersion', 'Schema5DualHudMigrationContractVersion',
        'Schema6TrackingMigrationContractVersion', 'Schema7GearScoreFormatMigrationContractVersion',
        'Schema8KnownTransport4IncidentRecoveryContractVersion', 'Schema8TrackingScopeMigrationContractVersion',
        'Schema8Transport4RecoveryProbeContractVersion',
        'Schema8Transport5DistanceXOmissionRecoveryContractVersion', 'Schema8Transport5RecoveryContractVersion',
        'Schema8Transport5ScopedPrefixRecoveryContractVersion', 'TargetDefaultTemplateContractVersion' }
    local feature = { HudLayoutStoreId = 'v3.buff_display.layout', TransferFormatVersion = 3 }
    for index, name in ipairs(names) do feature[name] = index end
    return feature
end

Test('BatchM 静态：契约版本投影已注册且暴露 20 项（可观察性不降级）', function()
    -- 注意：不能 dofile 真文件 —— buff_display 的 feature 文件需要完整启动环境，离线宿主加载不了。
    -- 所以这里做静态核对：注册块存在、键名正确、字段数 20、实现缺失时降级为 nil。
    local f = assert(io.open(BUFF_PATH, 'rb'))
    local text = f:read('*a'); f:close()
    assert(text:find('buff_display_contract_versions', 1, true) ~= nil, 'the projection must be registered')
    assert(text:find('if type(feature) ~= "table" then return nil end', 1, true) ~= nil,
        'the projection must degrade to nil when the implementation is missing')
    -- 直接在注册块里数字段：19 个 N(feature...) + 1 个布尔字段 = 20
    local _, versions = text:gsub('N%(feature%.', '')
    local _, boolField = text:gsub('hudLayoutStoreIdMatches', '')
    assert(versions + boolField == 20,
        'projection must expose 20 entries, got ' .. tostring(versions + boolField))
end)

Test('BatchM 静态：core 不得再按 id 读 BuffDisplay（两种回填形态都查）', function()
    local f = assert(io.open('core/rs_foundation_gate.lua', 'rb'))
    local text = f:read('*a'); f:close()
    assert(text:find('S.Features.BuffDisplay', 1, true) == nil,
        'Foundation must not read the BuffDisplay feature table')
    -- 裸标识符的字段访问（排除 Store / Meta / Page / Widget / Health / Contracts 这些合法局部名）
    local bare = 0
    for _ in text:gmatch('buffDisplay%.[A-Za-z_]') do bare = bare + 1 end
    assert(bare == 0, 'Foundation must not dereference the bare buffDisplay binding, found ' .. tostring(bare))
end)

Test('BatchM 静态：非 Feature 侧必须保留，且推导链仍在', function()
    local f = assert(io.open('core/rs_foundation_gate.lua', 'rb'))
    local text = f:read('*a'); f:close()
    for _, pattern in ipairs({ 'v3.buff_display.layout', 'buffDisplayStore',
        'rebuildCanonicalForIntegrity', 'recoverKnownLegacyCanonical',
        'BuffIconFontSizeContractVersion', 'buffHudCalibration.version', 'GetDiagnostics' }) do
        assert(text:find(pattern, 1, true) ~= nil, 'non-Feature counterpart must stay: ' .. pattern)
    end
    -- 推导链：两个 Store 的判定仍从 Store 侧对象推导，而不是被换成常量
    assert(text:find('local buffDisplayLayoutStore = S.Persistence', 1, true) ~= nil,
        'layout store judgement must stay derived from Persistence')
    -- detail 必须改从投影取值（否则就是把可观察性降级成常量）
    assert(text:find('buff_display_contract_versions', 1, true) ~= nil,
        'detail must read the contract-version projection')
    assert(text:find('BuffContract("schema8Transport5Recovery")', 1, true) ~= nil,
        'detail must resolve contract versions through the projection')
end)

Test('BatchM 静态：acceptance 已补齐两条只存在于 Foundation 的契约', function()
    local f = assert(io.open(BUFF_ACC, 'rb'))
    local text = f:read('*a'); f:close()
    assert(text:find('Schema8Transport4RecoveryProbeContractVersion', 1, true) ~= nil,
        'acceptance must carry the transport-v4 probe recovery contract')
    assert(text:find('Schema8KnownTransport4IncidentRecoveryContractVersion', 1, true) ~= nil,
        'acceptance must carry the known transport-v4 incident recovery contract')
    -- 下限取齐：LayoutAuthorityContractVersion 在两边都必须是 >= 3
    assert(text:find('(tonumber(F.LayoutAuthorityContractVersion) or 0) < 3', 1, true) ~= nil,
        'acceptance must keep the stricter layout-authority floor (>= 3)')
end)

------------------------------------------------------------------------
-- Phase 3 Batch N：tools_bag 的动作契约
--   （core/rs_foundation_gate.lua 的 EvaluateBagActionContract 里 36 条 Feature Require 已删除；
--     InventorySnapshotV3 / BagQuickOverlay / BusinessPagesContract 的 Service/UIV3 侧保留在 Foundation）
--   本批用脚本从 Foundation 机械生成 acceptance（25 个契约版本下限 + 10 条命令），避免手抄 36 条出错。
------------------------------------------------------------------------
local BAG_PATH = 'features/tools/bag/rs_bag_acceptance.lua'
local BAG_CASE = 'v3_tools_bag_action_contract'

local function BagFeature()
    -- 下限清单与 acceptance 逐条对齐（25 项），避免 stub 少字段导致误报。
    local feature = {
        BagMoveContractVersion = 8,
        BatchLifecycleContractVersion = 5,
        NativeWindowQuickContractVersion = 7,
        ReloadQuickObserverContractVersion = 3,
        ResponsiveWindowObserverContractVersion = 1,
        ProductBlacklistUxContractVersion = 1,
        BlacklistNameMetadataContractVersion = 1,
        BlacklistExplicitLookupContractVersion = 1,
        RUFourValueWindowVisibilityContractVersion = 2,
        NativeVisibilityShapeContractVersion = 1,
        SurfaceVisibilitySplitContractVersion = 1,
        StorageSessionBagSurfaceContractVersion = 1,
        BagActionPhysicalReadAuthorityContractVersion = 1,
        VisiblePresenterRetryContractVersion = 1,
        DynamicSourceResolutionContractVersion = 3,
        QuickIdentityFallbackContractVersion = 1,
        BagTaskMutexContractVersion = 2,
        QuickRunSelfHealContractVersion = 1,
        QuickTwoButtonContractVersion = 1,
        QuickReasonVisibilityContractVersion = 1,
        QuickStatusTimestampContractVersion = 1,
        InventorySnapshotContractVersion = 1,
        GroupedIntentQueueContractVersion = 1,
        FullStorageContinuationContractVersion = 1,
        BatchTargetAutoContractVersion = 1,
    }
    feature.Commands = { QuickWithdraw = function() end, QuickDeposit = function() end,
        QuickCancel = function() end, ResolveAndAddBlacklistItem = function() end,
        AddGlobalBlacklistItem = function() end, RemoveGlobalBlacklistItem = function() end,
        SetBatchCategory = function() end, SetBatchTarget = function() end,
        SetBatchLimit = function() end, DepositCategoryCurrent = function() end }
    return feature
end

Test('BatchN tools_bag：实现未注册 → case 仍注册且失败', function()
    local cases = BootTruth('tools_bag', BAG_PATH, nil)
    assert(type(cases[BAG_CASE]) == 'function', 'case must register even when missing')
    local ok, reason = cases[BAG_CASE]()
    assert(ok == false and tostring(reason) == 'implementation_not_registered', 'reason=' .. tostring(reason))
end)

Test('BatchN tools_bag：合规契约通过（36 条搬迁未误伤）', function()
    local ok, reason = BootTruth('tools_bag', BAG_PATH, BagFeature())[BAG_CASE]()
    assert(ok == true, 'compliant feature must pass, got ' .. tostring(reason))
end)

Test('BatchN tools_bag：契约回退与缺命令必须被拒', function()
    local function Reject(mutate, label)
        local feature = BagFeature()
        mutate(feature)
        local ok, reason = BootTruth('tools_bag', BAG_PATH, feature)[BAG_CASE]()
        assert(ok == false, label .. ' must be rejected')
        assert(reason ~= nil and tostring(reason) ~= '', 'rejection must carry a reason')
    end
    Reject(function(f) f.BagMoveContractVersion = 7 end, 'bag.move_v8 下限')
    Reject(function(f) f.BatchLifecycleContractVersion = 4 end, 'bag.batch_lifecycle_v5 下限')
    Reject(function(f) f.Commands = nil end, '命令表缺失')
    Reject(function(f) f.Commands.QuickWithdraw = nil end, '缺 QuickWithdraw')
    Reject(function(f) f.Commands.DepositCategoryCurrent = nil end, '缺 DepositCategoryCurrent')
end)

Test('BatchN 静态：core 不得再点名 tools_bag，但 Service/UIV3 侧必须保留且推导链仍在', function()
    local f = assert(io.open('core/rs_foundation_gate.lua', 'rb'))
    local text = f:read('*a'); f:close()
    -- ① 完整实现表访问串 / 已删除的判定壳子
    for _, pattern in ipairs({ 'S.Features.tools_bag', 'bagTools', 'bag.move_v8', 'bag.batch_lifecycle_v5',
        'command.QuickWithdraw', 'command.DepositCategoryCurrent' }) do
        assert(text:find(pattern, 1, true) == nil, 'Foundation still references: ' .. pattern)
    end
    -- ② 非 Feature 侧必须保留（Service / UIV3）
    for _, pattern in ipairs({ 'InventorySnapshotV3', 'PhysicalBagAuthorityContractVersion',
        'BagQuickOverlay', 'BusinessPagesContract', 'pages.bag_product_ux_v2' }) do
        assert(text:find(pattern, 1, true) ~= nil, 'non-Feature counterpart must stay: ' .. pattern)
    end
    -- ③ 推导链：判定必须仍由 Service 侧推导，不能被改成常量

    assert(text:find('Require(type(inventorySnapshot) == "table", "inventory.service")', 1, true) ~= nil,
        'the inventory-side judgement chain must remain')
end)

print(string.format('CORE-FEATURE-DECOUPLING RESULT %d passed / %d failed', passed, failed))
if failed > 0 then error('core/feature decoupling regressions: ' .. tostring(failed)) end

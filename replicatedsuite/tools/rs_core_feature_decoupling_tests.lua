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

print(string.format('CORE-FEATURE-DECOUPLING RESULT %d passed / %d failed', passed, failed))
if failed > 0 then error('core/feature decoupling regressions: ' .. tostring(failed)) end

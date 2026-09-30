------------------------------------------------------------------------
-- 重构复核回归：真实 FoundationGate + TOC 顺序 + 通用存档 apply。
-- 只在离线 runner 执行；不会装进游戏 TOC，不读取用户存档。
-- 2026-09-30：先在提交包观察失败，再修复，避免只测试假的注册器。
------------------------------------------------------------------------
local passed, failed = 0, 0
local function Test(name, fn)
    local ok, err = pcall(fn)
    if ok then passed = passed + 1; print('PASS livegate ' .. name)
    else failed = failed + 1; print('FAIL livegate ' .. name .. ': ' .. tostring(err)) end
end
local function Boot()
    ReplicatedSuite = { Features = {}, SafeTraceback = debug.traceback }
    dofile('core/rs_foundation_gate.lua')
    return ReplicatedSuite, ReplicatedSuite.FoundationGate
end
local function Find(report, id)
    for _, row in ipairs(report.checks or {}) do if row.id == id then return row end end
end
local function LiveResult(g, id)
    local report = g:Run({ skipSequences = true })
    local row = Find(report, 'runtime_contract:' .. id)
    assert(row, 'live diagnostic omitted ' .. id)
    return row, report
end
local function Toc()
    local f = assert(io.open('toc.g', 'rb'))
    local text = f:read('*a'); f:close()
    local paths = {}
    for line in text:gmatch('[^\r\n]+') do
        local path = line:match('^%s*([^#%s].-%.lua)%s*$')
        if path then paths[#paths + 1] = path end
    end
    return paths
end
Test('fresh TOC registers all three Buff cases after gate construction', function()
    ReplicatedSuite = { Features = {}, SafeTraceback = debug.traceback }
    for _, path in ipairs(Toc()) do
        if path == 'core/rs_foundation_gate.lua' or path == 'features/combat/buff_display/rs_buff_display_acceptance.lua' then dofile(path) end
    end
    local g = ReplicatedSuite.FoundationGate
    for _, id in ipairs({'v3_m16_18_4_buff_display_statusmap_contract', 'v3_m16_18_buff_display_plate_geometry', 'v3_combat_buff_display_observation_contract'}) do
        assert(type(g.sequenceCases[id]) == 'function', 'fresh TOC lost ' .. id)
    end
end)
Test('skipSequences still reports explicitly registered read-only contracts', function()
    local s, g = Boot()
    local fullRuns, readRuns = 0, 0
    g:RegisterSequenceCase('sentinel', function(readOnly)
        if readOnly == true then readRuns = readRuns + 1; return false, 'missing_live_dependency' end
        fullRuns = fullRuns + 1; return true
    end, { runtime = true })
    g:RegisterSequenceCase('destructive', function() error('must never execute in live diagnostics') end)
    local row, report = LiveResult(g, 'sentinel')
    assert(row.ok == false and row.severity == 'blocker' and row.detail == 'missing_live_dependency')
    assert(readRuns == 1 and fullRuns == 0, 'live diagnostic executed destructive path')
    assert(report.sequences.skipped == true and report.sequences.failed == 0)
    assert(report.runtimeContracts.total == 1 and report.runtimeContracts.failed == 1)
end)
Test('runtime cases require explicit true; exceptions retain root cause and do not stop other checks', function()
    local s, g = Boot()
    g:RegisterSequenceCase('nil_result', function() return nil, 'missing_return' end, { runtime = true })
    g:RegisterSequenceCase('error_result', function() error('read_only_fault') end, { runtime = true })
    g:RegisterSequenceCase('valid_result', function() return true, 'valid_contract' end, { runtime = true })
    local row, report = LiveResult(g, 'nil_result')
    assert(row.ok == false and row.detail == 'missing_return')
    assert(Find(report, 'runtime_contract:error_result').detail:find('read_only_fault', 1, true))
    assert(Find(report, 'runtime_contract:valid_result').ok == true)
    assert(report.runtimeContracts.total == 3 and report.runtimeContracts.failed == 2 and report.runtimeContracts.passed == 1)
end)
Test('duplicate registration does not duplicate checks and can revoke runtime opt-in', function()
    local s, g = Boot()
    g:RegisterSequenceCase('replace', function() return false end, { runtime = true })
    g:RegisterSequenceCase('replace', function() return true end, { runtime = true })
    local row, report = LiveResult(g, 'replace')
    assert(row.ok and report.runtimeContracts.total == 1 and #g.sequenceOrder == 1)
    g:RegisterSequenceCase('replace', function() error('revoked callback must stay offline') end)
    report = g:Run({ skipSequences = true })
    assert(Find(report, 'runtime_contract:replace') == nil and report.runtimeContracts.total == 0)
end)
Test('BuildCopyText and normal live report preserve migrated failure evidence', function()
    local s, g = Boot()
    g:RegisterSequenceCase('copy_marker', function() return false, 'copy_reason' end, { runtime = true })
    g:BuildCopyText(true)
    local row = Find(g.last, 'runtime_contract:copy_marker')
    assert(row and row.ok == false and row.detail == 'copy_reason', 'copy path bypassed migrated contracts')
end)
Test('missing DPS still registers its contract and fails closed', function()
    local s, g = Boot()
    dofile('features/combat/dps/rs_dps_acceptance.lua')
    assert(type(g.sequenceCases.v3_m16_dps_shared_analytics_contract) == 'function', 'missing DPS hid all checks')
    local row = LiveResult(g, 'v3_m16_dps_shared_analytics_contract')
    assert(not row.ok and row.detail == 'implementation_not_registered')
end)
Test('missing Buff implementation reports clear failure, not silent omission', function()
    local s, g = Boot()
    dofile('features/combat/buff_display/rs_buff_display_acceptance.lua')
    local row = LiveResult(g, 'v3_m16_18_4_buff_display_statusmap_contract')
    assert(not row.ok and row.detail == 'implementation_not_registered')
end)
Test('task persistence version regression is visible through real player diagnostic', function()
    local s, g = Boot()
    s.Features.Tasks = { PersistenceMutationContractVersion = 1, PersistenceCodecVersion = 2 }
    dofile('features/life/tasks/rs_task_acceptance.lua')
    local row = LiveResult(g, 'v3_life_tasks_persistence_contract')
    assert(not row.ok and row.detail == 'task_persistence_mutation_contract_version')
    s.Features.Tasks.PersistenceMutationContractVersion = 2
    row = LiveResult(g, 'v3_life_tasks_persistence_contract')
    assert(row.ok, row.detail)
end)
Test('enabled task live contract never acquires consumers or refreshes the authority', function()
    local s, g = Boot()
    local calls = 0
    local function forbidden() calls = calls + 1; error('diagnostic must remain read-only') end
    s.Features.Tasks = { StoreId = 'v3.tasks', ApiDependencies = {'QUEST'},
        PersistenceMutationContractVersion = 2, PersistenceCodecVersion = 2,
        Commands = { MarkStoreDirty = forbidden, SetWidgetWindowState = forbidden },
        AcquireConsumer = forbidden, ReleaseConsumer = forbidden,
        Authority = { Refresh = forbidden }, consumerCount = 0 }
    s.FeatureRegistry = { Get = function() return {status='migrated_m1',authority='v3.tasks'} end }
    s.FeatureRuntime = {IsImplemented=function() return true end, IsEnabled=function() return true end}
    s.Persistence = {GetStore=function() return {owner='v3.tasks',schemaVersion=1} end}
    s.Services = {QuestProgressV3={GetProgress=forbidden,GetGroupDetail=forbidden,GetHealth=forbidden}}
    s.UIV3 = {PageHost={factories={['life.tasks']=forbidden}}, WidgetHost={GetSpec=function() return {} end}}
    dofile('features/life/tasks/rs_task_acceptance.lua')
    -- Isolate Feature-owned checks from unrelated Foundation dependencies in this minimal boundary host.
    local report = {checks={},blockers=0,warnings=0}
    g:RunRuntimeContracts(report)
    local row = Find(report, 'runtime_contract:v3_m1_tasks')
    assert(row and row.ok, row and row.detail or 'task live contract absent')
    assert(calls == 0 and s.Features.Tasks.consumerCount == 0)
    local ok = pcall(g.sequenceCases.v3_m1_tasks)
    assert(not ok and calls == 1, 'offline sequence was accidentally disabled too')
end)
local function NewStoredFeature(defaults, state, keys)
    local stores = {}
    local s = { Features={}, Persistence={Scope={Account='Account'}, Lifetime={Permanent='Permanent'},V3KeyPrefix='test_'},
        FeatureRuntime={RegisterImplementation=function() return true end},Demand={Create=function() return {} end} }
    function s.Persistence:GetStore(id) return stores[id] end
    function s.Persistence:RegisterV3Store(spec) stores[spec.id] = spec; return spec end
    ReplicatedSuite = s
    dofile('features/shared/rs_feature_slice_factory.lua')
    local f = s.FeatureSliceFactory.NewFeature('regression_only', {default=defaults,state=state,persistentKeys=keys,read=function() return {} end})
    return stores[f.storeId], f
end
Test('empty old save restores boolean false default instead of nil', function()
    local store, f = NewStoredFeature({enabled=false}, {enabled=true})
    store.apply({})
    assert(f.State.enabled == false, 'false default was lost to Lua and/or fallback')
    assert(store.get().enabled == false, 'get/apply boolean contract drift')
end)
Test('stored false overrides true default; zero and empty string remain valid', function()
    local store, f = NewStoredFeature({enabled=true,count=10,text='default'}, {})
    store.apply({enabled=false,count=0,text=''})
    assert(f.State.enabled == false and f.State.count == 0 and f.State.text == '')
end)
Test('nullable keys clear old selection and default tables are deep-copied', function()
    local defaults = {options={visible=false, nested={n=1}}}
    local store, f = NewStoredFeature(defaults, {selected='old'}, {'selected'})
    store.apply({})
    assert(f.State.selected == nil and f.State.options.visible == false)
    f.State.options.nested.n = 99
    assert(defaults.options.nested.n == 1, 'default table alias')
    local value = {options={visible=false,nested={n=2}}}
    store.apply(value); f.State.options.nested.n = 88
    assert(value.options.nested.n == 2, 'stored table alias')
end)
Test('real TOC retains all 27 migrated runtime checks even with missing implementations', function()
    local s, g = Boot()
    for _, path in ipairs(Toc()) do
        if path:match('^features/.*_acceptance%.lua$') then dofile(path) end
    end
    local required = {
        'v3_life_trade_detail_favorites_contract', 'v3_life_treasure_observation_contract',
        'v3_m1_bonds', 'v3_m1_tasks', 'v3_life_tasks_persistence_contract', 'v3_m1_activities',
        'v3_life_fishing_observation_contract', 'v3_life_fishing_auto_r_transaction_contract',
        'v3_tools_auction_contract', 'v3_tools_craft_contract', 'v3_tools_bag_action_contract',
        'v3_tools_market_analysis_contract', 'v3_tools_reinforce_analysis_runtime_block_contract',
        'v3_m16_18_healer_visual_consumers_contract', 'v3_combat_target_monitor_observation_contract',
        'v3_m16_18_4_buff_display_statusmap_contract', 'v3_combat_buff_display_observation_contract',
        'v3_m4_gear_quick_startup_intent_contract', 'v3_m16_14_raid_readiness_contract',
        'v3_combat_team_tools_role_contract', 'v3_combat_team_tools_visual_marker_contract',
        'v3_m16_dps_shared_analytics_contract', 'v3_combat_range_assist_visual_guide_contract',
        'v3_combat_boss_alerts_hud_contract', 'v3_combat_buff_cap_observation_contract',
        'v3_combat_unit_lines_visual_guide_contract', 'v3_m15_2h_death_review_contract',
    }
    local report = g:Run({skipSequences=true})
    assert(report.runtimeContracts.total == #required and report.runtimeContracts.failed == #required)
    for _, id in ipairs(required) do
        local row = Find(report, 'runtime_contract:' .. id)
        assert(row and not row.ok and row.detail == 'implementation_not_registered', id .. ' silently omitted or wrong failure')
    end
    for _, id in ipairs({'v3_m16_dps_skill_proxy_source','v3_m15_2h_death_review_widget_close','v3_m16_18_buff_display_plate_geometry'}) do
        assert(type(g.sequenceCases[id]) == 'function', 'original offline sequence removed: ' .. id)
        assert(Find(report, 'runtime_contract:' .. id) == nil, 'destructive/expensive sequence became a live check: ' .. id)
    end
end)
Test('Buff live contract skips synthetic recovery hooks but continues checking declarations', function()
    local s, g = Boot()
    local calls = 0
    local function hook() calls=calls+1; error('synthetic_recovery_touched') end
    local store = {owner='v3.buff_display',schemaVersion=8,transportVersion=3,
        rebuildCanonicalForIntegrity=hook,recoverKnownLegacyCanonical=hook,migrate=hook}
    local layout = {owner='v3.buff_display.layout',schemaVersion=1,transportVersion=3}
    s.Features.BuffDisplay = {Id='combat_buff_display',StoreId='v3.buff_display',
        HudLayoutStoreId='v3.buff_display.layout',SettingsStoreId='v3.buff_display.settings',
        TrackingManifestStoreId='v3.buff_display.tracking.manifest',TrackingPersistenceContractVersion=1,
        LegacyStoreWriteProhibitedContractVersion=1,GetDefaultSettingsSnapshot=function() return {} end}
    s.FeatureRegistry = {Get=function() return {status='migrated_m16_18',lifecycle='demand_scoped',authority='v3.buff_display',widgetCapable=true,settingsCapable=true} end}
    s.FeatureRuntime = {IsImplemented=function() return true end}
    s.Persistence = {GetStore=function(_, id)
        if id=='v3.buff_display' then return store end
        if id=='v3.buff_display.layout' then return layout end
        return {owner=id}
    end}
    s.Utils = {DeepCopy=function(v) return v end}
    dofile('features/combat/buff_display/rs_buff_display_acceptance.lua')
    local fn=g.sequenceCases.v3_m16_18_4_buff_display_statusmap_contract
    local ok,reason=fn(true)
    assert(not ok and reason=='classification_service_contract', 'runtime stopped at wrong contract: '..tostring(reason))
    assert(calls==0,'runtime recovery hook executed')
    assert(not pcall(fn) and calls==1,'original offline probe was accidentally removed')
end)
Test('DeathReview live contract skips synthetic recovery and retains lifecycle checking', function()
    local s,g=Boot()
    local calls=0
    local function hook() calls=calls+1; error('synthetic_death_recovery_touched') end
    local store={owner='v3.death_review',scope='Account',lifetime='Permanent',schemaVersion=2,
        rebuildCanonicalForIntegrity=hook,recoverKnownLegacyCanonical=hook,encode=hook,
        migrate=function() return {widgetWindow={width=470,height=330,minimized=false,locked=false,userMoved=false,overallOpacity=0.96}} end}
    s.Features.DeathReview={StoreId='v3.death_review',PersistenceIndexSchemaContractVersion=2,
        PersistenceCanonicalWindowContractVersion=7,PersistenceKnownLegacyRecoveryContractVersion=5,
        PersistenceSchema2Framework2RecoveryContractVersion=2,PersistenceTransportV1ZeroOmissionRecoveryContractVersion=2,
        PersistenceIndexCodecVersion=1,WidgetWindowSizePolicy={}}
    s.FeatureRegistry={Get=function() return {status='migrated_m15_2',lifecycle='independent',authority='v3.death_review',widgetCapable=true,settingsCapable=true} end}
    s.FeatureRuntime={IsImplemented=function() return true end}
    s.Persistence={Scope={Account='Account'},Lifetime={Permanent='Permanent'},HistoricalCanonicalRecoveryContractVersion=3,
        KnownLegacyCanonicalRecoveryContractVersion=1,GetStore=function() return store end}
    dofile('features/combat/death_review/rs_death_review_acceptance.lua')
    local fn=g.sequenceCases.v3_m15_2h_death_review_contract
    local ok,reason=fn(true)
    assert(not ok and reason=='lifecycle_contract','runtime stopped at wrong contract: '..tostring(reason))
    assert(calls==0,'runtime recovery probe executed')
    assert(not pcall(fn) and calls==1,'original offline recovery probe was accidentally removed')
end)
Test('Trade mixed-version and missing command regressions are rejected by live gate, without quoting or refreshing', function()
    local s,g=Boot()
    local calls=0
    local function forbidden() calls=calls+1; error('live trade gate invoked command') end
    local f={MultiRowQuoteJobsContractVersion=1,QuoteTerminalRefreshContractVersion=2,
        MaterialPriceCacheContractVersion=1,BackgroundMaterialRevalidateContractVersion=1,EconomicsRevisionContractVersion=1,
        AutoRefreshBackgroundLeaseContractVersion=2,AutoRefreshRuntimeContractVersion=1,
        Authority={version=6,TradePayoutProjectionContractVersion=1,AutoRefreshWatchdogContractVersion=3,
            RatioFastPublishContractVersion=2,RouteRefreshRetryContractVersion=2,SingleFlightLatestRouteContractVersion=1,RequestTimeoutContractVersion=1},
        GetFavoriteItems=forbidden,GetRow=forbidden,Commands={}}
    for _,key in ipairs({'ToggleCurrentFavorite','SelectFavorite','SetSortMode','SelectRow','QuoteRowMaterials','QuotePendingMaterials','CancelQuoteRowMaterials'}) do f.Commands[key]=forbidden end
    s.Features.Trade=f
    dofile('features/life/trade/rs_trade_acceptance.lua')
    local row=LiveResult(g,'v3_life_trade_detail_favorites_contract');assert(row.ok,row.detail)
    for _,key in ipairs({'MultiRowQuoteJobsContractVersion','MaterialPriceCacheContractVersion','BackgroundMaterialRevalidateContractVersion','EconomicsRevisionContractVersion','AutoRefreshRuntimeContractVersion'}) do
        local before=f[key]; f[key]=0
        row=LiveResult(g,'v3_life_trade_detail_favorites_contract')
        assert(not row.ok and row.detail==key..'_floor','old '..key..' not rejected in live report')
        f[key]=before
    end
    f.Authority.AutoRefreshWatchdogContractVersion=2
    row=LiveResult(g,'v3_life_trade_detail_favorites_contract')
    assert(not row.ok and row.detail=='Authority.AutoRefreshWatchdogContractVersion_floor')
    f.Authority.AutoRefreshWatchdogContractVersion=3;f.Commands.QuoteRowMaterials=nil
    row=LiveResult(g,'v3_life_trade_detail_favorites_contract');assert(not row.ok and row.detail=='command.QuoteRowMaterials')
    assert(calls==0,'checking version/commands executed business operations')
end)
Test('Bonds live gate validates Auroria contract while leaving active consumers and selection untouched', function()
    local s,g=Boot()
    local calls=0
    local function forbidden() calls=calls+1; error('live Bonds gate modified runtime') end
    local f={storeId='v3.life.bonds',MultiContinentSnapshotContractVersion=3,ResidentBoardFamilyContractVersion=1,
        AuroriaMaterialContractVersion=1,DropdownPresentationContractVersion=2,
        GetDisplayOrderKey=forbidden,GetFilterMask=forbidden,GetDuplicateMode=forbidden,
        AcquireConsumer=forbidden,ReleaseConsumer=forbidden,Authority={Refresh=forbidden},Commands={}}
    for _,key in ipairs({'Refresh','SetDisplayOrder','SetFilterMask','SetDuplicateMode','SetSortMode','SetContinentOrder',
        'SetBondFilterOption','SetDuplicatePriority','SelectRow','GetSelectedRow','GetRow','MarkStoreDirty','SetWidgetWindowState'}) do f.Commands[key]=forbidden end
    s.Features.Bonds=f
    s.FeatureRegistry={Get=function() return {authority='v3.life.bonds'} end}
    s.FeatureRuntime={IsImplemented=function() return true end,IsEnabled=function() return true end}
    s.Persistence={GetStore=function() return {owner='v3.life.bonds',rebuildCanonicalForIntegrity=forbidden} end}
    s.UIV3={PageHost={factories={['life.bonds']=forbidden}},WidgetHost={GetSpec=function() return {} end}}
    dofile('features/life/bonds/rs_bonds_acceptance.lua')
    local function Check()
        local report={checks={},blockers=0,warnings=0};g:RunRuntimeContracts(report)
        return assert(Find(report,'runtime_contract:v3_m1_bonds'))
    end
    local row=Check();assert(row.ok,row.detail)
    f.ResidentBoardFamilyContractVersion=0;row=Check();assert(not row.ok and row.detail=='presentation_command_contract')
    f.ResidentBoardFamilyContractVersion=1;f.Commands.SelectRow=nil
    row=Check();assert(not row.ok and row.detail=='presentation_command_contract')
    assert(calls==0,'Bonds live gate acquired/refreshed/selected/rebuilt')
end)
print(string.format('REFACTOR LIVE GATE TESTS: %d passed, %d failed', passed, failed))
assert(failed == 0, 'refactor live gate regression failure')

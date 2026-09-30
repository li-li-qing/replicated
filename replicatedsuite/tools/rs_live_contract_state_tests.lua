------------------------------------------------------------------------
-- 2026-09-30，live-contract-state-1：实机两个误报的真实状态回归。
-- 只在 tools 运行，不进入 TOC。加载真实 Boss Feature、Buff Store/Feature/目录、
-- UI 声明和 FoundationGate；仅 Native、磁盘、宿主时钟与观察事实使用离线替身。
-- 禁止给“合规替身”手填 _bossDiag 或把生产 Catalog 降为 v1 来制造通过。
-- 修复前必须复现 boss_diagnostics_projection_missing / schema8_tracking_modules_missing。
------------------------------------------------------------------------
local passed, failed = 0, 0
local BOSS_CASE = 'v3_combat_boss_alerts_hud_contract'
local BUFF_CASE = 'v3_m16_18_4_buff_display_statusmap_contract'
local H = dofile('tools/rs_udf_numeric_test_host.lua')
local function Test(name, fn)
    local ok, err = pcall(fn)
    if ok then passed = passed + 1; print('PASS live-state ' .. name)
    else failed = failed + 1; print('FAIL live-state ' .. name .. ': ' .. tostring(err)) end
end
local function ReadCase(S, id)
    -- 与玩家诊断相同的只读分发；不运行完整/有副作用的 sequence。
    local report = { checks = {}, blockers = 0, warnings = 0 }
    S.FoundationGate:RunRuntimeContracts(report)
    for _, row in ipairs(report.checks) do
        if row.id == 'runtime_contract:' .. id then return row, report end
    end
    error('runtime contract not registered: ' .. id)
end
local function Expect(S, id, ok, reason)
    local row = ReadCase(S, id)
    assert(row.ok == ok, tostring(row.detail) .. ' (expected ok=' .. tostring(ok) .. ')')
    if reason then assert(row.detail == reason, 'expected ' .. reason .. ', got ' .. tostring(row.detail)) end
    if not ok then assert(row.severity == 'blocker', 'real failures must remain blockers') end
    return row
end
local function BootBoss()
    local S, P, disk = H.Boot()
    local calls = { acquires = 0, releases = 0, reads = 0, hides = 0 }
    S.NowMs = function() return 1000 end
    for _, key in ipairs({'CastingObservationV3', 'AuraObservationV3'}) do
        local service = { consumers = {} }
        function service:AcquireConsumer(token) calls.acquires = calls.acquires + 1; self.consumers[token] = true; return true end
        function service:ReleaseConsumer(token) calls.releases = calls.releases + 1; self.consumers[token] = nil; return true end
        S.Services[key] = service
    end
    function S.Services.CastingObservationV3:GetCoverage() calls.reads = calls.reads + 1; return {available=true} end
    function S.Services.CastingObservationV3:Get() calls.reads = calls.reads + 1; return {casting=false} end
    function S.Services.AuraObservationV3:GetSnapshot() calls.reads = calls.reads + 1; return {} end
    function S.Services.AuraObservationV3:GetStatusMap() calls.reads = calls.reads + 1; return {}, {available=true,complete=true,reliable=true} end
    S.Services.Alerts = { HideOwner = function() calls.hides = calls.hides + 1; return true end }
    dofile('core/rs_feature_health_providers.lua')
    dofile('data/rs_boss_alerts.lua')
    dofile('features/shared/rs_feature_slice_factory.lua')
    dofile('features/combat/boss_alerts/rs_boss_alerts_feature.lua')
    dofile('core/rs_foundation_gate.lua')
    dofile('features/combat/boss_alerts/rs_boss_alerts_acceptance.lua')
    return S, assert(S.Features.combat_boss_alerts), calls, disk
end
local function BootBuff()
    local h, S, F = dofile('tools/rs_pvp_hud_test_host.lua')({noRenderer=true})
    dofile('core/rs_utils.lua'); dofile('core/rs_reuse.lua')
    dofile('features/rs_feature_registry.lua')
    -- 宿主提供“已注册/关闭”状态；不手填任何被检查的 Feature 版本/能力字段。
    function S.FeatureRuntime:IsImplemented(id) return id == F.Id end
    function S.FeatureRuntime:IsEnabled() return false end
    dofile('features/combat/buff_display/rs_buff_display_alias_store.lua')
    dofile('features/combat/buff_display/rs_buff_display_transfer_v2.lua')
    dofile('services/rs_aura_observation_v3.lua')
    S.UIV3Design = {} -- 只登记页面，不创建 Native 控件。
    dofile('presentation/v3/widgets/rs_v3_widget_host.lua')
    dofile('presentation/v3/shell/rs_v3_page_host.lua')
    dofile('presentation/v3/widgets/rs_v3_buff_display_widget.lua')
    dofile('presentation/v3/widgets/rs_v3_buff_head_markers.lua')
    dofile('presentation/v3/widgets/rs_v3_buff_hud_calibration.lua')
    dofile('presentation/v3/pages/rs_v3_buff_display_page.lua')
    dofile('core/rs_foundation_gate.lua')
    dofile('features/combat/buff_display/rs_buff_display_acceptance.lua')
    return S, F, h
end
local function BossSnapshot(S, F, calls, disk)
    return H.Copy({state=F.State,enabled=F.enabled,consumerCount=F.consumerCount,
        started=F._bossObservationStarted,diag=F._bossDiag,tasks=S.Scheduler.tasks,
        events=S.Events.listeners,calls=calls,reads=disk.reads,writes=disk.writes,clears=disk.clears,
        providerCalls=S.FeatureHealthProviders.calls,providerErrors=S.FeatureHealthProviders.errors})
end

Test('real cold disabled Boss passes without allocating diagnostic state or acquiring resources', function()
    local S, F, calls, disk = BootBoss()
    assert(F.enabled == false and F._bossDiag == nil and (F.consumerCount or 0) == 0)
    assert(S.FeatureHealthProviders:Has('boss_alerts_diagnostics'))
    local before = BossSnapshot(S,F,calls,disk)
    for _ = 1, 3 do Expect(S,BOSS_CASE,true) end
    assert(H.Eq(before,BossSnapshot(S,F,calls,disk)), 'diagnosis mutated dormant Boss')
end)
Test('enabled Boss with HUD disabled remains legitimately unobserved', function()
    local S,F,calls,disk = BootBoss()
    F.State.hudEnabled = false
    assert(F:Enable('test_hud_off'))
    assert(F.enabled and F.consumerCount > 0 and F._bossObservationStarted ~= true and F._bossDiag == nil)
    local before=BossSnapshot(S,F,calls,disk)
    Expect(S,BOSS_CASE,true)
    assert(H.Eq(before,BossSnapshot(S,F,calls,disk)) and calls.acquires==0)
end)
Test('real Boss enable-disable-enable retains the lazy lifecycle and diagnostic results', function()
    local S,F,calls,disk=BootBoss()
    assert(F:Enable('test_on'))
    assert(F._bossObservationStarted and type(F._bossDiag)=='table' and calls.acquires==2)
    local before=BossSnapshot(S,F,calls,disk)
    Expect(S,BOSS_CASE,true)
    assert(H.Eq(before,BossSnapshot(S,F,calls,disk)), 'active diagnosis changed counters or leases')
    assert(type(S.FeatureHealthProviders:Get('boss_alerts_diagnostics'))=='table')
    assert(F:GetProjection().realtime==true)
    assert(F:Disable('test_off'))
    assert(not F.enabled and F._bossObservationStarted==false and F.consumerCount==0)
    assert(S.Scheduler.tasks.v3_business_boss_alert_observe==nil and calls.releases==2)
    Expect(S,BOSS_CASE,true)
    assert(F:Enable('test_again')); Expect(S,BOSS_CASE,true)
    assert(calls.acquires==4 and calls.releases==2)
end)
Test('active Boss with missing diagnostic state still blocks', function()
    local S,F=BootBoss(); assert(F:Enable('test_on')); F._bossDiag=nil
    Expect(S,BOSS_CASE,false,'boss_diagnostics_projection_missing')
end)
Test('dormant Boss with malformed existing diagnostic state still blocks', function()
    local S,F=BootBoss(); F._bossDiag='corrupt'
    Expect(S,BOSS_CASE,false,'boss_diagnostics_projection_invalid')
end)
Test('Boss with absent diagnostic provider is not treated as dormant success', function()
    local S,F=BootBoss(); assert(F:Enable('test_on'))
    S.FeatureHealthProviders.providers.boss_alerts_diagnostics=nil
    Expect(S,BOSS_CASE,false,'boss_diagnostics_provider_missing')
end)
Test('Boss with missing provider registry fails even with diagnostic state present', function()
    local S,F=BootBoss(); assert(F:Enable('test_on')); S.FeatureHealthProviders=nil
    Expect(S,BOSS_CASE,false,'boss_diagnostics_provider_missing')
end)
Test('Boss provider registry must retain callable lookup and presence checks', function()
    for _,key in ipairs({'Has','Get'})do
        local S,F=BootBoss(); assert(F:Enable('test_on'))
        S.FeatureHealthProviders[key]=nil
        Expect(S,BOSS_CASE,false,'boss_diagnostics_provider_missing')
    end
end)
Test('Boss below HUD and observation version floors still blocks when disabled', function()
    for _,sample in ipairs({{'HudContractVersion',1,'hud_contract_version'}, {'RealtimeFactBridgeContractVersion',0,'realtime_fact_bridge_contract_version'}})do
        local S,F=BootBoss(); F[sample[1]]=sample[2]; Expect(S,BOSS_CASE,false,sample[3])
    end
end)

Test('real current Buff catalog v2 passes without rewriting its import watermark', function()
    local S,F=BootBuff(); local catalog=S.Data.StatusTrackingCatalogV3
    assert(catalog.version==2 and catalog.ByEffectId[853].introducedVersion==2, 'must load real v2 fixture')
    Expect(S,BUFF_CASE,true)
    assert(catalog.version==2 and catalog.ByEffectId[853].introducedVersion==2)
end)
Test('compatible data revisions are not confused with schema or transfer versions', function()
    for _,version in ipairs({1,2,3})do
        local S=BootBuff(); S.Data.StatusTrackingCatalogV3.version=version
        Expect(S,BUFF_CASE,true)
        assert(S.Data.StatusTrackingCatalogV3.version==version)
    end
end)
Test('Buff player diagnostic stays read-only for dormant and active-state fixtures', function()
    for _,active in ipairs({false,true})do
        local S,F,h=BootBuff()
        -- 状态边界样本，不伪装启用过真实 Native HUD。只读条件在两种形态下均须成立。
        F.enabled=active; F.consumerCount=active and 1 or 0; F.auraHeld=active
        local calls=0
        local function Forbidden() calls=calls+1; error('runtime diagnostic attempted a write, load, refresh or lease') end
        for _,key in ipairs({'LoadData','SaveData','ClearData'})do S.Api[key]=Forbidden end
        for _,key in ipairs({'AcquireConsumer','ReleaseConsumer','Refresh','RefreshScope','EnsureStoreLoaded','CaptureManagementFreeze'})do F[key]=Forbidden end
        for key in pairs(F.Commands)do F.Commands[key]=Forbidden end
        local store=S.Persistence:GetStore('v3.buff_display')
        store.rebuildCanonicalForIntegrity=Forbidden; store.recoverKnownLegacyCanonical=Forbidden; store.migrate=Forbidden
        local before=H.Copy({state=F.State,tasks=S.Scheduler.tasks,events=S.Events.listeners,catalog=S.Data.StatusTrackingCatalogV3,
            reads=h.io.reads,writes=h.io.writes,consumerCount=F.consumerCount,auraHeld=F.auraHeld})
        for _=1,3 do Expect(S,BUFF_CASE,true) end
        local after={state=F.State,tasks=S.Scheduler.tasks,events=S.Events.listeners,catalog=S.Data.StatusTrackingCatalogV3,
            reads=h.io.reads,writes=h.io.writes,consumerCount=F.consumerCount,auraHeld=F.auraHeld}
        assert(calls==0 and H.Eq(before,after),'runtime diagnosis changed Buff state, catalog or resources')
    end
end)
Test('missing Buff catalog retains an explicit blocker', function()
    local S=BootBuff(); S.Data.StatusTrackingCatalogV3=nil
    Expect(S,BUFF_CASE,false,'schema8_tracking_catalog_missing')
end)
Test('invalid Buff catalog revision remains rejected with specific evidence', function()
    local values={0,-1,1.5,'2',false,math.huge,-math.huge,0/0}
    for _,version in ipairs(values)do
        local S=BootBuff(); S.Data.StatusTrackingCatalogV3.version=version
        local row=Expect(S,BUFF_CASE,false)
        assert(row.detail:find('schema8_tracking_catalog_version_invalid:',1,true)==1,row.detail)
    end
    local S=BootBuff(); S.Data.StatusTrackingCatalogV3.version=nil
    Expect(S,BUFF_CASE,false,'schema8_tracking_catalog_version_invalid:nil')
end)
Test('catalog indexes cannot be replaced by a version-only stub', function()
    for _,key in ipairs({'ByEffectId','ByKey','Packs','PackOrder'})do
        local S=BootBuff(); S.Data.StatusTrackingCatalogV3[key]=nil
        Expect(S,BUFF_CASE,false,'schema8_tracking_catalog_index_missing:'..key)
    end
end)
Test('missing management/import/preview code remains a blocker', function()
    for _,key in ipairs({'GetManagementProjection','CaptureManagementFreeze','ImportBuiltinPack','PreviewImport'})do
        local S,F=BootBuff()
        if key=='ImportBuiltinPack' or key=='PreviewImport' then F.Commands[key]=nil else F[key]=nil end
        Expect(S,BUFF_CASE,false,'schema8_tracking_modules_missing')
    end
end)
Test('Buff tracking schema and transfer format floors are not relaxed', function()
    local S,F=BootBuff(); S.Persistence:GetStore('v3.buff_display').schemaVersion=7
    Expect(S,BUFF_CASE,false,'store_contract')
    S,F=BootBuff(); F.TransferFormatVersion=2
    Expect(S,BUFF_CASE,false,'schema8_tracking_modules_missing')
    S,F=BootBuff(); F.Schema8TrackingScopeMigrationContractVersion=0
    Expect(S,BUFF_CASE,false,'feature_contract')
end)
Test('normal skipSequences diagnostic keeps both real features registered and passes all three runtime contracts', function()
    local S=BootBuff()
    dofile('core/rs_feature_health_providers.lua')
    dofile('data/rs_boss_alerts.lua')
    dofile('features/shared/rs_feature_slice_factory.lua')
    dofile('features/combat/boss_alerts/rs_boss_alerts_feature.lua')
    dofile('features/combat/boss_alerts/rs_boss_alerts_acceptance.lua')
    -- 只断言此集成宿主拥有的三条业务契约；其余 Core 依赖不在此宿主范围内。
    -- 不把受控宿主的 report.status 冒充整个 RU 客户端健康。
    local report=S.FoundationGate:Run({skipSequences=true})
    assert(report.sequences.skipped==true)
    assert(report.runtimeContracts.total==3 and report.runtimeContracts.passed==3
        and report.runtimeContracts.failed==0, 'real-feature runtime contracts still failed')
    assert(S.Features.combat_boss_alerts._bossDiag==nil, 'normal diagnostics created fake Boss observations')
    assert(S.Data.StatusTrackingCatalogV3.version==2, 'normal diagnostics rewrote catalog revision')
end)
print(string.format('LIVE CONTRACT STATE TESTS: %d passed, %d failed (runtime=%s)',passed,failed,_VERSION))
if failed>0 then error('live contract state tests failed: '..failed) end

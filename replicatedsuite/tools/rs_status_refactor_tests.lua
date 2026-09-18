-- 中文维护注释：仅开发期执行的真实 Lua 模块回归，不进入 TOC。
-- Native 游戏事实由合成样本注入；不把此结果当作 RU 返回形态/布局实机证明。
local passed, failed = 0, 0
local function Test(name, run)
    local ok, err = pcall(run)
    if ok then passed = passed + 1; print('PASS ' .. name)
    else failed = failed + 1; print('FAIL ' .. name .. ': ' .. tostring(err)) end
end
local function Copy(v)
    if type(v) ~= 'table' then return v end
    local r = {}; for k,x in pairs(v) do r[k] = Copy(x) end; return r
end
local function Equal(a,b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= 'table' then return a == b end
    for k,v in pairs(a) do if not Equal(v,b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end
ReplicatedSuite = { Features={}, Services={}, Utils={DeepCopy=Copy}, UI={CreateWindowShell=function() end}, RSUI={} }
local S = ReplicatedSuite
S.FeatureRuntime = { RegisterImplementation=function() return true end, IsEnabled=function() return true end }
dofile('data/rs_data_registry.lua')
dofile('data/rs_skill_effects.lua')
dofile('data/rs_combat_ability_catalog.lua')
dofile('data/ids/rs_buff_ids.lua')
dofile('data/ids/rs_plates_ids.lua')
dofile('services/rs_status_classification_v3.lua')
dofile('data/rs_status_tracking_catalog.lua')
local C = S.Services.StatusClassificationV3
Test('registry resource kind is not polarity', function()
    assert(S.GameIds.Buff.ById[21].resourceKind == 'buff')
    assert(S.GameIds.Buff.ById[21].effectCategory == 'unknown')
end)
Test('native debuff outranks static registry', function()
    assert(C:ClassifyEntry({id=21,sources={debuff=true}},{}).category == 'debuff')
end)
Test('unknown and hidden-only stay unknown', function()
    assert(C:ClassifyId(987654321,{}).category == 'unknown')
    assert(C:ClassifyEntry({id=987654321,sources={hidden=true}},{}).category == 'unknown')
end)
Test('manual classification outranks native lane', function()
    assert(C:ClassifyEntry({id=21,sources={debuff=true}},{[21]='buff'}).category == 'buff')
end)
-- Use the real persistence and floating-state normalizers, not test versions.
dofile('core/rs_persistence.lua')
dofile('core/rs_demand.lua')
dofile('ui/framework/rs_ui_floating_surface.lua')
dofile('features/combat/buff_display/rs_buff_display_store.lua')
dofile('features/combat/buff_display/rs_buff_display_projection.lua')
dofile('features/combat/buff_display/rs_buff_display_feature.lua')
dofile('features/combat/buff_display/rs_buff_display_management.lua')
local transfer=loadfile('features/combat/buff_display/rs_buff_display_transfer_v2.lua'); if transfer then transfer() end
local F = S.Features.BuffDisplay
local store = S.Persistence:GetStore('v3.buff_display')
assert(store, 'real store registration failed')
Test('schema8 defaults contain scoped auto dual HUD and full gear format', function()
    local d = store.default()
    assert(F.SchemaVersion == 8)
    assert(type(d.settings.tracked.player)=='table' and type(d.settings.tracked.target)=='table')
    assert(type(d.settings.tracked.player.auto)=='table' and type(d.settings.tracked.target.auto)=='table')
    assert(type(d.settings.targetLayout.components)=='table')
    assert(d.settings.info.gearScoreFormat=='full' and d.settings.targetLayout.info.gearScoreFormat=='full')
end)
Test('auto tracked native debuff enters debuff HUD only', function()
    local settings=F:GetDefaultSettingsSnapshot(); settings.tracked.player.auto={21}
    local rows=F.ProjectStatusMap({[21]={id=21,sources={debuff=true},timeLeft=1000}}, {available=true,complete=true,reliable=true},settings,'player',384)
    assert(#rows==1 and rows[1].tracked==true and rows[1].category=='debuff')
    local hud=F.ProjectPlates({buffRows={},debuffRows=rows},settings,nil,'player')
    assert(#hud.debuffs==1 and #hud.buffs==0)
end)
Test('management freeze API exists and live rows remain independent', function()
    assert(type(F.CaptureManagementFreeze)=='function', 'complete session freeze missing')
end)

Test('schema5 historical canonical matches frozen .208 goldens', function()
    for _,fixture in ipairs(dofile('tools/rs_status_schema5_fixtures.lua')) do
        local old,domain=store.rebuildCanonicalForIntegrity(Copy(fixture.raw),fixture.fingerprint,nil,
            {__rsmeta={store='v3.buff_display',owner='v3.buff_display',framework=3,schema=5,transportVersion=2}})
        assert(Equal(old,fixture.canonical),fixture.name..' canonical changed')
        assert(S.Persistence:FingerprintCanonicalValue(store,old)==fixture.fingerprint,fixture.name..' old hash changed')
        local upgraded=store.migrate(domain,5,8)
        assert(Equal(upgraded.settings.tracked.player.buff,fixture.canonical.settings.tracked.buff))
        assert(Equal(upgraded.settings.tracked.player.debuff,fixture.canonical.settings.tracked.debuff))
        assert(Equal(upgraded.settings.tracked.target.buff,fixture.canonical.settings.tracked.buff))
        assert(Equal(upgraded.settings.tracked.target.debuff,fixture.canonical.settings.tracked.debuff))
        assert(Equal(upgraded.settings.classification,fixture.canonical.settings.classification))
        local target=Copy(upgraded.settings.targetLayout);target.components.cooldowns=nil
        local expectedTarget=Copy(fixture.canonical.settings.targetLayout)
        assert(target.info.gearScoreFormat=='full','schema5 target format migration')
        target.info.gearScoreFormat=nil
        assert(Equal(target,expectedTarget),'target HUD changed')
        assert(upgraded.settings.info.gearScoreFormat=='full','schema5 player format migration')
        assert(upgraded.settings.freezeEnabled==false and #upgraded.settings.tracked.player.auto==0 and #upgraded.settings.tracked.target.auto==0)
        assert(Equal(store.migrate(upgraded,8,8),upgraded),'schema8 not idempotent')
    end
end)
Test('historical hook rejects wrong identity and future generation', function()
    local old=store.rebuildCanonicalForIntegrity({},'bogus',nil,{__rsmeta={store='other',owner='v3.buff_display',framework=3,schema=5}})
    assert(old==nil)
    old=store.rebuildCanonicalForIntegrity({},'bogus',nil,{__rsmeta={store='v3.buff_display',owner='v3.buff_display',framework=3,schema=9}})
    assert(old==nil)
end)
Test('catalog includes 393 effects 14 trees and empty joy', function()
    local c=S.Data.StatusTrackingCatalogV3
    assert(c.counts.effects==393,'effect count '..tostring(c.counts.effects))
    assert(c.counts.trees==14 and c.counts.skills==464)
    assert(c.Packs['tree:joy'] and #c.Packs['tree:joy'].entries==0)
    assert(#c.Packs.control.entries>0)
    assert(c.ByEffectId[21].category=='unknown')
end)
local disk={};local writes=0
S.Api={LoadData=function(_,key) return Copy(disk[key]) end,
    SaveData=function(_,key,value) writes=writes+1;disk[key]=Copy(value);return true end}
assert(F:EnsureStoreLoaded())
local function Reset()
    store.apply(store.default());F:InvalidateSettingsCache();F:ClearFrozenRows()
end
Test('builtin import is single durable transaction and persistent auto', function()
    Reset();local before=writes
    local ok,err=F:ImportBuiltinPack('all',false);assert(ok,err)
    assert(writes==before+1,'more than one durable write')
    assert(#F.State.settings.tracked.player.auto==393 and #F.State.settings.tracked.target.auto==393)
    assert(#F.State.settings.tracked.player.buff==0 and #F.State.settings.tracked.player.debuff==0
        and #F.State.settings.tracked.target.buff==0 and #F.State.settings.tracked.target.debuff==0)
    local count=#F.State.settings.tracked.player.auto
    assert(F:ImportBuiltinPack('all',false))
    assert(#F.State.settings.tracked.player.auto==count and #F.State.settings.tracked.target.auto==count)
end)
Test('untracking auto remains removed after supplement and normalization', function()
    assert(F:SetTrackedId(21,'debuff',false))
    assert(not F:IsTrackedId(21))
    assert(F:ImportBuiltinPack('all',true))
    assert(not F:IsTrackedId(21),'supplement re-added removed entry')
    store.apply(store.get());assert(not F:IsTrackedId(21))
end)
Test('manual classification no longer owns scoped tracking placement', function()
    Reset();assert(F:SetTrackedId(21,'auto',true));local before=Copy(F.State.settings.tracked)
    assert(F:SetClassification(21,'debuff'));assert(Equal(F.State.settings.tracked,before),'classification moved tracking channels')
    assert(F:ClearClassification(21));assert(Equal(F.State.settings.tracked,before),'clear classification moved tracking channels')
end)
Test('capacity failure rolls back entire library import', function()
    Reset();for i=1,1024 do F.State.settings.tracked.player.auto[i]=100000+i end
    F:InvalidateSettingsCache();local before=store.get()
    local ok=F:ImportBuiltinPack('all',false)
    assert(not ok);assert(Equal(store.get(),before),'partial import survived rollback')
end)
Test('freeze captures all scopes independent of live HUD and releases lease', function()
    Reset();local leases=0;local facts={player={[21]={id=21,name='p-debuff',sources={debuff=true},timeLeft=900}},
        target={[82]={id=82,name='t-buff',sources={buff=true},timeLeft=600},[987654]={id=987654,name='t-hidden',sources={hidden=true}}}}
    S.Services.AuraObservationV3={
        AcquireConsumer=function() leases=leases+1;return true end,
        ReleaseConsumer=function() leases=leases-1;return true end,
        GetSnapshot=function(_,scope,opts) assert(opts.limit>=64);return {unitId=scope,scope=scope,at=101,revision=1} end,
        GetStatusMap=function(_,snapshot) return facts[snapshot.scope],{available=true,complete=true,reliable=true} end}
    assert(F:CaptureManagementFreeze());assert(leases==0)
    local rows=F:GetManagementProjection({view='frozen'});assert(#rows==3)
    assert(F:GetManagementFreezeState().count==3)
    facts.player={};facts.target={};assert(F:RefreshScope('player'));assert(F:RefreshScope('target'))
    assert(#F.laneData.player.debuffRows==0 and #F.laneData.target.buffRows==0)
    assert(#F:GetManagementProjection({view='frozen'})==3,'live tick changed freeze')
    assert(F:SetTrackedId(21,'debuff',true));assert(F:SetTrackedId(21,'debuff',false))
    assert(#F:GetManagementProjection({view='frozen'})==3,'untrack removed captured row')
    assert(F:ClearFrozenRows());assert(#F:GetManagementProjection({view='live'})==0)
end)
Test('tracked view contains inactive entries and uses revision cache', function()
    Reset();assert(F:SetTrackedId(21,'auto',true))
    local rows,key=F:GetManagementProjection({view='tracked'})
    assert(#rows==1 and rows[1].name~='21' and rows[1].trackedBucket=='multi'
        and rows[1].trackedText:find('自身·自动',1,true) and rows[1].trackedText:find('目标·自动',1,true))
    local second,key2=F:GetManagementProjection({view='tracked'})
    assert(rows==second and key==key2)
end)
Test('v3 rejects malformed input and retains scoped auto in text round-trip',function()
    assert(F.TransferFormatVersion==3,'v3 parser missing')
    Reset();assert(F:SetTrackedId(21,'auto',true))
    local text=F:SerializeExport(F:ExportAll())
    local parsed=F:ParseImportText(text)
    assert(#parsed.errors==0,parsed.errors[1])
    assert(parsed.data.tracked.player.auto[1]==21 and parsed.data.tracked.target.auto[1]==21)
    local bad=F:ParseImportText('FORMAT=replicatedsuite.buff_display.v2\nAUTO=21,bad')
    assert(#bad.errors>0)
    local before=store.get();local ok=F:ImportAll(bad.data,'merge')
    assert(not ok and Equal(before,store.get()))
end)
-- 中文维护注释：以下反例保护覆盖导入、UI 事件与管理/HUD 边界，不用成功样本掩盖拒绝路径。
Test('metadata-only and unknown-only imports cannot clear selections',function()
    Reset();assert(F:SetTrackedId(21,'auto',true))
    for _,text in ipairs({'FORMAT=replicatedsuite.buff_display.v2','FUTURE_FIELD=1','# comment only'}) do
        local parsed=F:ParseImportText(text)
        assert(#parsed.errors>0,'metadata-only accepted: '..text)
        local before=store.get();assert(not F:ImportAll(parsed.data,'overwrite'))
        assert(Equal(before,store.get()))
    end
end)
Test('direct malformed import objects reject without partial mutation',function()
    Reset();assert(F:SetTrackedId(21,'auto',true))
    for _,data in ipairs({{tracked='broken'},{tracked={auto='broken'}},{trackedCooldowns=5},{classification=false}}) do
        local before=store.get();assert(not F:ImportAll(data,'overwrite'),'malformed object accepted')
        assert(Equal(before,store.get()))
    end
end)
Test('classification conflict rejects while explicit buff and debuff channels may coexist',function()
    local conflict=F:ParseImportText('CLASSIFICATION=21:buff\nCLASSIFICATION=21:debuff');assert(#conflict.errors>0,'classification conflict silently resolved')
    local dual=F:ParseImportText('BUFF=21\nDEBUFF=21');assert(#dual.errors==0,dual.errors[1])
    assert(dual.data.tracked.player.buff[1]==21 and dual.data.tracked.player.debuff[1]==21
        and dual.data.tracked.target.buff[1]==21 and dual.data.tracked.target.debuff[1]==21)
end)
Test('tracking-only overwrite preserves both HUD layouts and supports v1',function()
    Reset();F.State.settings.plate.x=41;F.State.settings.targetLayout.plate.x=-92;F:InvalidateSettingsCache()
    assert(F:SetTrackedId(21,'auto',true));assert(F:SetTrackedCooldownId(24113,'skill',true))
    local before=F.Commands:GetHudCalibrationSnapshot()
    local text=F:SerializeExport(F:ExportAll('tracking'));local parsed=F:ParseImportText(text)
    assert(#parsed.errors==0,parsed.errors[1]);assert(F:ImportAll(parsed.data,'overwrite'))
    assert(Equal(before,F.Commands:GetHudCalibrationSnapshot()),'tracking import altered HUD')
    local v1=F:ParseImportText('VERSION=5\nBUFF=21\nDEBUFF=82\nCLASSIFICATION=82:debuff')
    assert(#v1.errors==0,v1.errors[1]);assert(F:ImportAll(v1.data,'overwrite'))
    assert(F:IsTrackedId(21,'buff') and F:IsTrackedId(82,'debuff')
        and #F.State.settings.tracked.player.auto==0 and #F.State.settings.tracked.target.auto==0
        and F:IsTrackedChannel(21,'player','buff') and F:IsTrackedChannel(21,'target','buff'))
end)
Test('current management facts survive old category visibility settings',function()
    Reset();F.State.settings.showDebuffs=false;F:InvalidateSettingsCache()
    S.Services.AuraObservationV3={GetSnapshot=function() return {revision=44,at=99} end,
        GetStatusMap=function() return {[21]={id=21,sources={debuff=true}}},{available=true,complete=true,reliable=true} end}
    assert(F:RefreshScope('player'));assert(#F.projections.player==1,'management lost native Debuff')
    assert(#F.laneData.player.debuffRows==0,'old HUD visibility setting changed')
end)
Test('freeze API failures always release temporary consumers',function()
    Reset();local leases=0
    S.Services.AuraObservationV3={AcquireConsumer=function() leases=leases+1;return true end,
        ReleaseConsumer=function() leases=leases-1;return true end,
        GetSnapshot=function() error('synthetic native failure') end,GetStatusMap=function() end}
    assert(not F:CaptureManagementFreeze());assert(leases==0 and not F:GetManagementFreezeState().active)
end)
Test('management health exposes schema catalog and explicit unfinished cooldown',function()
    local health=F:GetHealth()
    assert(health.schemaVersion==8 and type(health.management)=='table' and type(health.management.tracked.player)=='table')
    assert(health.management.catalog.effectCount==393)
    assert(health.management.cooldownRuntime=='not_implemented','reserved selections must not imply native support')
end)
-- 中文维护注释：以下使用真实 Persistence 的元数据封印、物理传输、LoadStore/SaveStore 链。
-- 合成 schema5 样本的 canonical/hash 来自未修改 .208，不等同真实玩家存档采集。
local function Envelope(fixture)
    local P=S.Persistence
    local raw={payload=Copy(fixture.raw),__rsmeta={framework=P.FrameworkVersion,store=store.id,owner=store.owner,
        contractVersion=store.contractVersion,lifetime=store.lifetime,scope=store.scope,schema=5,
        transportVersion=P.TransportContractVersion,reliabilityContract=P.ReliabilityContractVersion,
        integrityVersion=P.IntegrityContractVersion,encodedFingerprint=fixture.fingerprint,envelopeIntegrityVersion=P.EnvelopeIntegrityContractVersion}}
    raw.__rsmeta.envelopeFingerprint=assert(P:FingerprintEnvelopeIntegrity(raw))
    return assert(P:EncodePhysicalEnvelope(raw))
end
Test('schema5 loads through real integrity verifier and restamps schema8',function()
    Reset();local P=S.Persistence;local key=assert(P:ResolveStoreKey(store))
    local fixture=dofile('tools/rs_status_schema5_fixtures.lua')[2]
    disk[key]=Envelope(fixture)
    local ok,_,err=P:LoadStore(store.id,{discardDirty=true,discardUnverified=true,revalidateTerminal=true})
    assert(ok,err);F:InvalidateSettingsCache()
    assert(Equal(F.State.settings.tracked.player.buff,fixture.canonical.settings.tracked.buff))
    assert(Equal(F.State.settings.tracked.player.debuff,fixture.canonical.settings.tracked.debuff))
    assert(Equal(F.State.settings.tracked.target.buff,fixture.canonical.settings.tracked.buff))
    assert(Equal(F.State.settings.tracked.target.debuff,fixture.canonical.settings.tracked.debuff))
    assert(F.State.settings.targetLayout.plate.x==fixture.canonical.settings.targetLayout.plate.x)
    assert(not store.writeFenced)
    local saved,saveErr=P:SaveStore(store.id,{force=true});assert(saved,saveErr)
    local decoded=assert(P:DecodePhysicalEnvelope(disk[key]));assert(decoded.__rsmeta.schema==8)
    assert(decoded.__rsmeta.encodedFingerprint==P:FingerprintCanonicalValue(store,store.get()))
end)
Test('unknown old fingerprint fails closed and protects original disk bytes',function()
    Reset();local P=S.Persistence;local key=assert(P:ResolveStoreKey(store))
    local fixture=Copy(dofile('tools/rs_status_schema5_fixtures.lua')[2]);fixture.fingerprint='00000000'
    disk[key]=Envelope(fixture);local original=Copy(disk[key])
    local ok,_,err=P:LoadStore(store.id,{discardDirty=true,discardUnverified=true,revalidateTerminal=true})
    assert(not ok and store.writeFenced==true,tostring(err))
    assert(not F:ImportBuiltinPack('all',false),'write fence bypassed')
    assert(Equal(disk[key],original),'rejected old payload overwritten')
    -- 恢复测试隔离环境，使用合法旧 envelope 重新验证，而不是直接关闭 Core 写保护。
    disk[key]=Envelope(dofile('tools/rs_status_schema5_fixtures.lua')[1])
    local repaired,_,repairErr=P:LoadStore(store.id,{discardDirty=true,discardUnverified=true,revalidateTerminal=true})
    assert(repaired,repairErr);F:InvalidateSettingsCache()
end)
Test('durable save failure rolls back entire imported selection',function()
    Reset();local before=store.get();local save=S.Api.SaveData
    S.Api.SaveData=function() return false,'synthetic disk unavailable' end
    local ok=F:ImportBuiltinPack('all',false);S.Api.SaveData=save
    assert(not ok);assert(Equal(before,store.get()),'failed write left changed choices')
end)
Test('projection fallback never promotes hidden unknown to buff',function()
    local original=S.Services.StatusClassificationV3;S.Services.StatusClassificationV3=nil
    local rows=F.ProjectStatusMap({[123]={id=123,sources={hidden=true}}},{available=true},{},'player',128)
    S.Services.StatusClassificationV3=original
    assert(rows[1].category=='unknown')
end)
Test('unsupported HUD metadata alone cannot overwrite tracking',function()
    local parsed=F:ParseImportText('HUDFUTURE=some_data')
    assert(#parsed.errors>0,'unknown HUD key interpreted as empty overwrite')
end)
Test('static tracked cache survives interleaved live page and widget reads',function()
    Reset();assert(F:ImportBuiltinPack('all',false))
    local tracked=F:GetManagementProjection({view='tracked'})
    F:GetManagementProjection({view='live'})
    local again=F:GetManagementProjection({view='tracked'})
    assert(again==tracked,'live consumer evicted 393-row static cache')
end)
Test('v2 full round-trip preserves custom dual HUD and tracking',function()
    Reset();assert(F:SetTrackedId(21,'auto',true));assert(F:SetTrackedId(82,'debuff',true))
    F.State.settings.plate.x=31;F.State.settings.targetLayout.plate.x=-94
    F.State.settings.targetLayout.components.mainHand.x=17
    F.State.settings.components.buffs.spacing=9;F:InvalidateSettingsCache()
    local before=store.get().settings;local text=F:SerializeExport(F:ExportAll())
    local parsed=F:ParseImportText(text);assert(#parsed.errors==0,parsed.errors[1])
    local ok,err=F:ImportAll(parsed.data,'overwrite');assert(ok,err)
    assert(Equal(before,store.get().settings),'full round-trip changed domain')
end)
Test('floating tracked cache survives a differently filtered tracked page',function()
    Reset();assert(F:ImportBuiltinPack('all',false))
    local rows=F:GetTrackedList()
    F:GetManagementProjection({view='tracked',filter='tracked_buff'})
    assert(F:GetTrackedList()==rows,'same-view page filter evicted floating cache')
end)
local uiHost=dofile('tools/rs_status_ui_test_host.lua')(S)
Test('page builds four tabs and browses inactive tracked entries',function()
    Reset();assert(F:SetTrackedId(21,'auto',true))
    local page,err=uiHost:Build();assert(page,err)
    assert(#uiHost.widgets.v3_buff_display_tabs.items==4)
    assert(#uiHost.widgets.v3_buff_display_tab_switcher.children==4)
    assert(uiHost.widgets.v3_buff_manage_view.spec.set('tracked'))
    assert(#uiHost.widgets.v3_buff_display_tracking_table.items==1)
    assert(page:SwitchTab('library'));assert(page.activeTab=='library','programmatic switch did not update model')
    -- 当前默认推荐并集包含隐藏/特殊状态；旧all包仍单独保持393职业效果兼容。
    assert(#uiHost.widgets.v3_buff_library_table.items==#S.Data.StatusTrackingCatalogV3.Packs.recommended.entries)
    assert(uiHost.widgets.v3_buff_library_pack.spec.set('all'))
    assert(#uiHost.widgets.v3_buff_library_table.items==393)
    assert(uiHost.widgets.v3_buff_library_pack.spec.set('tree:joy'))
    assert(uiHost.widgets.v3_buff_library_import.enabled==false)
end)
Test('text import requires preview then confirmation without early write',function()
    Reset();local page=assert(uiHost:Build());local before=writes
    uiHost.edit.text='AUTO=21'
    assert(uiHost.widgets.v3_buff_display_transfer_import.onClick())
    assert(writes==before and not F:IsTrackedId(21),'preview wrote to Store')
    assert(uiHost.widgets.v3_buff_display_transfer_import.onClick())
    assert(writes==before+1 and F:IsTrackedId(21),'confirmation did not commit once')
end)
Test('unavailable multiline input disables all text actions',function()
    uiHost.nativeEnabled=false;local page=assert(uiHost:Build());uiHost.nativeEnabled=true
    for _,id in ipairs({'v3_buff_display_transfer_export','v3_buff_display_transfer_import','v3_buff_export_tracking','v3_buff_display_transfer_clear'}) do
        assert(uiHost.widgets[id].enabled==false,id..' left active')
    end
end)
-- 中文维护注释：补充真实持久化/页面构建边界回归，不改变上述原有验收。
dofile('tools/rs_persistence_integrity_regressions.lua')({S=S,Test=Test,Copy=Copy,Equal=Equal,F=F,store=store,disk=disk})
-- 维护：只读故障取证与摘要分段回归；不能把它们当作存档恢复验收。
dofile('tools/rs_persistence_evidence_tests.lua')({S=S,Test=Test,Copy=Copy,Equal=Equal,store=store,disk=disk})
print(string.format('RESULT %d passed / %d failed (%s)',passed,failed,_VERSION))
if failed>0 then error('regression suite failed') end

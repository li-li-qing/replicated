-- Maintenance: real Feature/Store/metadata service; Native facts, clock and UI are
-- controlled adapters. These assertions are not an RU-client acceptance claim.
local passed,failed=0,0
local function Test(name,fn) local ok,err=pcall(fn);if ok then passed=passed+1;print('PASS '..name) else failed=failed+1;print('FAIL '..name..': '..tostring(err)) end end
local function Copy(v) if type(v)~='table' then return v end;local t={};for k,x in pairs(v) do t[k]=Copy(x) end;return t end
local function Equal(a,b) if type(a)~=type(b) then return false end;if type(a)~='table' then return a==b end;for k,v in pairs(a) do if not Equal(v,b[k]) then return false end end;for k in pairs(b) do if a[k]==nil then return false end end;return true end
ReplicatedSuite={Features={},Services={},Utils={DeepCopy=Copy},UI={CreateWindowShell=function() end},RSUI={},Generation=1,SafeTraceback=function(e) return tostring(e) end}
local S=ReplicatedSuite
S.FeatureRuntime={RegisterImplementation=function() return true end,IsEnabled=function() return true end}
S.Events={handlers={},SubscribeOptional=function(self,event,owner,fn) self.handlers[event]=fn;return true end,SubscribeInternal=function() return true end,UnsubscribeInternalOwner=function() end,UnsubscribeOwner=function() end,Publish=function() end}
local tasks={}
S.Scheduler={tasks=tasks,RemoveTask=function(_,key) tasks[key]=nil;return true end,AddTask=function(_,key,ms,fn) tasks[key]={fn=fn,interval=ms};return true end,AddOneShot=function(_,key,ms,fn) tasks[key]={fn=fn,interval=ms};return true end,SetTaskModule=function() end}
local function Pump() local n=0;while tasks.v3_buff_management_metadata and n<100 do local job=tasks.v3_buff_management_metadata;tasks.v3_buff_management_metadata=nil;job.fn();n=n+1 end;assert(n<100,'metadata queue did not stop') end
for _,file in ipairs({'data/rs_data_registry.lua','data/rs_skill_effects.lua','data/rs_combat_ability_catalog.lua','data/ids/rs_buff_ids.lua','data/ids/rs_plates_ids.lua','services/rs_status_classification_v3.lua','data/rs_status_tracking_catalog.lua','core/rs_persistence.lua','core/rs_demand.lua','ui/framework/rs_ui_floating_surface.lua','features/combat/buff_display/rs_buff_display_store.lua','features/combat/buff_display/rs_buff_display_projection.lua','features/combat/buff_display/rs_buff_display_feature.lua','features/combat/buff_display/rs_buff_display_management.lua','features/combat/buff_display/rs_buff_display_transfer_v2.lua'}) do dofile(file) end
local disk,writes={},0
S.Api={LoadData=function(_,k) return Copy(disk[k]) end,SaveData=function(_,k,v) writes=writes+1;disk[k]=Copy(v);return true end}
local F=S.Features.BuffDisplay;local store=S.Persistence:GetStore('v3.buff_display');assert(F:EnsureStoreLoaded())
local facts,leases,now,scans={},0,100,0
local function Fact(id,category) return {id=id,name='effect-'..id,iconPath='icons/'..id..'.dds',sources={[category]=true},timeLeft=20} end
local function Reset()
    F.enabled=false;F.consumerCount=0;F.auraHeld=false;F.Demand:ForceClear();F.eventSubscribed=false
    if F.SetManagementPageActive then F:SetManagementPageActive(false) end
    store.apply(store.default());F:InvalidateSettingsCache();F:ClearFrozenRows();F.projections={player={},target={}};F.coverage={};F.laneData={player={},target={}}
    facts={player={},target={}};now=100;leases=0;scans=0
    for k in pairs(tasks) do tasks[k]=nil end
    S.Services.AuraObservationV3={AcquireConsumer=function() leases=leases+1;return true end,ReleaseConsumer=function() leases=leases-1;return true end,
        GetSnapshot=function(_,scope,opts) scans=scans+1;return {unitId=scope,scope=scope,at=now,revision=now,opts=opts} end,
        GetStatusMap=function(_,snapshot) return facts[snapshot.scope],{available=true,complete=true,reliable=true} end}
end
local function Find(rows,id,scope) for _,row in ipairs(rows) do if row.id==id and (not scope or row.scope==scope) then return row end end end
Test('retention captures later arrivals and keeps expired player and target effects',function()
    Reset();assert(F:CaptureManagementFreeze());facts.player[21]=Fact(21,'debuff');facts.target[82]=Fact(82,'buff');now=120
    assert(F:RefreshScope('player'));assert(F:RefreshScope('target'));facts.player={};facts.target={};now=140
    assert(F:RefreshScope('player'));assert(F:RefreshScope('target'))
    local rows=F:GetManagementProjection({view='frozen'});assert(#rows==2,'new arrivals were discarded');assert(Find(rows,21,'player').present==false)
    assert(#F.laneData.player.debuffRows==0 and #F.laneData.target.buffRows==0,'retained history leaked to HUD')
end)
Test('capture does not erase prior records when called again',function()
    Reset();facts.player[21]=Fact(21,'buff');assert(F:CaptureManagementFreeze());facts.player={};facts.target[82]=Fact(82,'debuff');assert(F:CaptureManagementFreeze())
    assert(#F:GetManagementProjection({view='frozen'})==2,'capture silently replaced history')
end)
Test('clear captured records is explicit and continues recording',function()
    Reset();facts.player[21]=Fact(21,'buff');assert(F:CaptureManagementFreeze());facts.player={};assert(F:ResetManagementCapture())
    assert(F:GetManagementFreezeState().active and F:GetManagementFreezeState().count==0)
    facts.target[82]=Fact(82,'debuff');F:RefreshScope('target');assert(F:GetManagementFreezeState().count==1)
end)
Test('duplicates use scope effect identity not repeated event rows',function()
    Reset();facts.player[21]=Fact(21,'buff');facts.target[21]=Fact(21,'buff');F:CaptureManagementFreeze()
    for i=1,8 do now=now+50;F:RefreshScope('player');F:RefreshScope('target') end
    assert(F:GetManagementFreezeState().count==2)
    local rev=F:GetManagementFreezeState().revision;F:RefreshScope('player');assert(F:GetManagementFreezeState().revision==rev,'unchanged capture invalidated cache')
end)
Test('retention survives unrelated API failure and reports incomplete coverage',function()
    Reset();facts.player[21]=Fact(21,'debuff');F:CaptureManagementFreeze();S.Services.AuraObservationV3.GetSnapshot=function() return nil,'native unavailable' end
    assert(not F:RefreshScope('player'));assert(F:GetManagementFreezeState().count==1);assert(F:GetManagementFreezeState().coverage.player.available==false)
end)
Test('retention capacity is bounded without evicting earliest observations',function()
    Reset();F:CaptureManagementFreeze()
    for batch=1,12 do facts.player={};for i=1,192 do local id=(batch-1)*192+i;facts.player[id]=Fact(id,'buff') end;F:RefreshScope('player') end
    local state=F:GetManagementFreezeState();assert(state.count<=2048 and state.overflow==true);assert(Find(F:GetManagementProjection({view='frozen'}),1),'old evidence evicted')
end)
Test('aura event captures subinterval effect before delayed polling',function()
    Reset();F:Enable();F.State.settings.headEnabled=false;assert(F:AcquireConsumer('page:buff_display'));assert(F:CaptureManagementFreeze());F:_StartEvents()
    facts.player[21]=Fact(21,'debuff');assert(S.Events.handlers.DEBUFF_UPDATE());facts.player={};now=101;assert(S.Events.handlers.DEBUFF_UPDATE())
    assert(Find(F:GetManagementProjection({view='frozen'}),21),'event was debounced until effect vanished')
end)
Test('capture cadence is 50ms and ignores HUD category visibility switches',function()
    Reset();F.enabled=true;F.consumerCount=1;F.auraHeld=true;F.State.settings.showBuffs=false;F.State.settings.showDebuffs=false;F.State.settings.headEnabled=false;F:CaptureManagementFreeze();F:ReconcileLanes()
    assert(tasks[F.taskName] and tasks[F.taskName].interval==50,'capture blocked by HUD policy')
    assert(F:ClearFrozenRows());F:ReconcileLanes();assert(not tasks[F.taskName],'unfreeze kept fast capture lane')
end)
Test('recommended catalog includes every effect but excludes unfinished cooldowns',function()
    local catalog=S.Data.StatusTrackingCatalogV3;local pack=catalog.Packs.recommended;assert(pack,'recommended pack missing');local ids={}
    for _,row in ipairs(pack.entries) do assert(row.kind=='effect');assert(not ids[row.id]);ids[row.id]=true end
    for id in pairs(catalog.ByEffectId) do assert(ids[id],'effect missing from one click pack') end
end)
local host=dofile('tools/rs_status_ui_test_host.lua')(S)
Test('library has icon cells and no confusing supplement button',function()
    Reset();assert(host:Build());local columns=host.widgets.v3_buff_library_table.spec.columns;local icon
    for _,c in ipairs(columns) do if c.cellType=='icon' then icon=c end end
    assert(icon and icon.field=='iconPath','icon column missing');assert(host.widgets.v3_buff_library_supplement==nil)
end)
Test('one click import clears filters and opens actual tracked selection list',function()
    Reset();local page=assert(host:Build());page.managementFilter='hidden';page.filterText='not found';page:SwitchTab('library');local before=writes
    assert(host.widgets.v3_buff_library_import.onClick());assert(writes==before+1)
    assert(page.activeTab=='track' and page.managementView=='tracked' and page.managementFilter=='all' and page.filterText=='','import left user looking at unrelated current-state rows')
    local rows=host.widgets.v3_buff_display_tracking_table.items;assert(#rows==#S.Data.StatusTrackingCatalogV3.Packs.recommended.entries)
    for _,row in ipairs(rows) do assert(row.tracked and F:IsTrackedId(row.id)) end
end)
Test('one click import error is shown without navigating or losing existing selection',function()
    Reset();assert(F:SetTrackedId(21,'auto',true));local page=assert(host:Build());page:SwitchTab('library');local before=store.get();local save=S.Api.SaveData;S.Api.SaveData=function() return false,'disk unavailable' end
    assert(not host.widgets.v3_buff_library_import.onClick());S.Api.SaveData=save
    assert(page.activeTab=='library' and Equal(before,store.get()))
    assert(host.widgets.v3_buff_library_hint.text:find('失败',1,true),'no explicit failure feedback')
end)
Test('import then reload retains selections and a removed item stays removed',function()
    Reset();assert(F:ImportBuiltinPack('recommended',false));local n=#F:GetManagementProjection({view='tracked'});assert(n>393)
    assert(F:SetTrackedId(21,'auto',false));assert(S.Persistence:Flush('v3.buff_display'))
    F.StoreLoaded=false;S.Persistence:GetStore('v3.buff_display').loaded=false;assert(F:EnsureStoreLoaded());assert(not F:IsTrackedId(21));assert(#F:GetManagementProjection({view='tracked'})==n-1)
end)
Test('row binding queues metadata only and batch uses shared resolver',function()
    Reset();local reads=0;S.Services.BuffMetadataV3={GetCached=function() end,GetInfo=function(_,id) reads=reads+1;return {iconPath='icons/'..id..'.dds',name='native'} end}
    local page=assert(host:Build());F:SetManagementPageActive(true);page:SwitchTab('library')
    local tableNode=host.widgets.v3_buff_library_table;local item=tableNode.items[1];assert(type(tableNode.spec.bindRow)=='function')
    tableNode.spec.bindRow({},item);assert(reads==0,'native read in render callback');assert(tasks.v3_buff_management_metadata);Pump();assert(reads==1)
end)
Test('cached catalogue icons available without per frame lookups',function()
    Reset();local reads=0;S.Services.BuffMetadataV3={GetCached=function(_,id) return {iconPath='icons/'..id..'.dds'} end,GetInfo=function() reads=reads+1;return {iconPath='bad'} end}
    local rows=F:GetManagementProjection({view='library',pack='all'});assert(rows[1].iconPath=='icons/'..rows[1].id..'.dds');assert(reads==0)
end)
Test('metadata work bounded per batch and cancelled when page is hidden',function()
    Reset();local reads=0;S.Services.BuffMetadataV3={GetCached=function() end,GetInfo=function() reads=reads+1;return {iconPath='icon.dds'} end};F:SetManagementPageActive(true)
    for id=1,1000 do F:QueueManagementMetadata(id) end
    local job=assert(tasks.v3_buff_management_metadata);tasks.v3_buff_management_metadata=nil;job.fn();assert(reads<=8)
    F:SetManagementPageActive(false);assert(not tasks.v3_buff_management_metadata);assert(F:GetManagementHealth().metadata.queued==0)
end)
-- Shared resolver edge cases exposed by the new catalogue consumer.
Test('metadata continues beyond empty native shape to a valid icon',function()
    dofile('services/rs_buff_metadata_v3.lua');X2Ability={};local M=S.Services.BuffMetadataV3;local count=0
    S.Api.CallCapability=function(_,_,_,_,_,level) count=count+1;if level==0 then return true,{} end;return true,{iconPath='ok.dds'} end
    local info=M:GetInfo(21);assert(info and info.iconPath=='ok.dds');assert(count==2)
end)
Test('metadata observed icon upgrades an earlier name only entry',function()
    dofile('services/rs_buff_metadata_v3.lua');local M=S.Services.BuffMetadataV3;assert(M:Remember(21,'known name',''));assert(M:Remember(21,'known name','observed.dds'));assert(M:GetCached(21).iconPath=='observed.dds')
end)
Test('metadata misses obey the same bounded eviction as positive entries',function()
    dofile('services/rs_buff_metadata_v3.lua');local M=S.Services.BuffMetadataV3;X2Ability=nil
    for i=1,800 do M:GetInfo(i) end
    local count=0;for _ in pairs(M.cache) do count=count+1 end;assert(count<=M.cacheMax and M.cacheCount<=M.cacheMax,'negative cache exceeded budget')
end)
Test('navigation marks confirmed visual tools complete without changing runtime capabilities',function()
    dofile('features/rs_feature_registry.lua')
    for _,id in ipairs({'combat_unit_lines','combat_range_assist'}) do local row=S.FeatureRegistry:Get(id);assert(row.navigationDevelopmentState=='complete' and not row.navigationIncomplete);assert(row.status=='migrated_partial','technical capability limits rewritten') end
end)

Test('icon request upgrades cached name through one bounded native probe',function()
    dofile('services/rs_buff_metadata_v3.lua');local M=S.Services.BuffMetadataV3;X2Ability={};local count=0
    assert(M:Remember(21,'cached',''));S.Api.CallCapability=function() count=count+1;return true,{iconPath='resolved.dds'} end
    assert(not M:HasCached(21,true),'name only falsely treated as resolved icon')
    assert(M:GetInfo(21,true).iconPath=='resolved.dds');assert(M:GetInfo(21,true).iconPath=='resolved.dds' and count==1)
end)
Test('name only or string tooltip does not block later icon candidate',function()
    dofile('services/rs_buff_metadata_v3.lua');local M=S.Services.BuffMetadataV3;X2Ability={};local count=0
    S.Api.CallCapability=function(_,_,_,_,_,level) count=count+1;if level==0 then return true,'tooltip name' end;return true,{path={},iconPath='fallback.dds'} end
    assert(M:GetInfo(21,true).iconPath=='fallback.dds');assert(count==2)
end)
Test('missing icon probe is cached and does not retry each row bind',function()
    dofile('services/rs_buff_metadata_v3.lua');local M=S.Services.BuffMetadataV3;X2Ability={};local count=0
    S.Api.CallCapability=function() count=count+1;return true,{name='valid name'} end
    local info=M:GetInfo(21,true);assert(info and info.name=='valid name');assert(count==3 and M:HasCached(21,true))
    M:GetInfo(21,true);assert(count==3)
end)
Test('metadata completion refreshes library while feature disabled',function()
    Reset();local enabled=S.FeatureRuntime.IsEnabled;S.FeatureRuntime.IsEnabled=function() return false end
    local events=S.Events;local listeners={}
    -- 维护：仿真也必须保留真实EventBus的owner-first参数，不能再掩盖页面reason错位。
    S.Events={SubscribeInternal=function(_,name,owner,fn) listeners[owner]=fn end,UnsubscribeInternalOwner=function(_,owner) listeners[owner]=nil end,Publish=function(_,name,reason) for owner,fn in pairs(listeners) do fn(owner,reason) end end}
    local cached={};S.Services.BuffMetadataV3={HasCached=function(_,id) return cached[id]~=nil end,GetCached=function(_,id) return cached[id] end,GetInfo=function(_,id) cached[id]={iconPath='ready.dds'};return cached[id] end}
    local page=assert(host:Build());assert(page:OnActivated());page:SwitchTab('library');local view=host.widgets.v3_buff_library_table;local item=view.items[1];view.spec.bindRow({},item)
    Pump();assert(view.items[1].iconPath=='ready.dds','disabled Feature prevented static catalogue refresh')
    page:OnDeactivated();S.Events=events;S.FeatureRuntime.IsEnabled=enabled
end)
Test('metadata callbacks from hidden generation cannot act after reopening',function()
    Reset();local reads=0;S.Services.BuffMetadataV3={GetInfo=function() reads=reads+1 end};F:SetManagementPageActive(true);F:QueueManagementMetadata(21)
    local stale=assert(tasks.v3_buff_management_metadata).fn;F:SetManagementPageActive(false);F:SetManagementPageActive(true);F:QueueManagementMetadata(82)
    stale();assert(reads==0,'stale callback drained newer page queue');assert(tasks.v3_buff_management_metadata)
end)
Test('stopping capture and disabling release the existing aura lifecycle',function()
    Reset();F:Enable();F.State.settings.headEnabled=false;assert(F:AcquireConsumer('page:buff_display'));assert(F:CaptureManagementFreeze())
    facts.player[21]=Fact(21,'buff');F:Refresh('test',true);assert(F:GetManagementFreezeState().count==1)
    assert(F:Disable('test'));assert(not F:GetManagementFreezeState().active);assert(not tasks[F.taskName]);assert(leases==0)
end)
Test('capture reads both scopes without altering stored layout or tracing lists',function()
    Reset();local before=store.get();facts.player[21]=Fact(21,'buff');facts.target[82]=Fact(82,'debuff');local saved=writes
    assert(F:CaptureManagementFreeze());F:RefreshScope('player');F:ResetManagementCapture();F:ClearFrozenRows()
    assert(Equal(before,store.get()) and writes==saved,'capture was persisted')
end)
Test('shared aura force refresh bypasses same timestamp cache only when requested',function()
    Reset();dofile('services/rs_aura_observation_v3.lua');local A=S.Services.AuraObservationV3;assert(A:AcquireConsumer('test',{}));local reads=0
    A._ScanLane=function() reads=reads+1;return {available=true,reliable=true,complete=true,rows={},count=0,scanned=0,limit=128} end
    A:GetSnapshot('player',{buff=true,debuff=false,hidden=false,ttlMs=0});A:GetSnapshot('player',{buff=true,debuff=false,hidden=false,ttlMs=0});assert(reads==1)
    A:GetSnapshot('player',{buff=true,debuff=false,hidden=false,ttlMs=0,forceRefresh=true});assert(reads==2);assert(A:ReleaseConsumer('test'))
end)


Test('capture owns an explicit lease and survives closing the management page',function()
    Reset();F:Enable();F.State.settings.headEnabled=false;assert(F:AcquireConsumer('page:buff_display'));assert(F:CaptureManagementFreeze())
    assert(F:ReleaseConsumer('page:buff_display'));assert(F:GetManagementFreezeState().active and F.consumerCount>0,'hiding page destroyed capture')
    facts.player[21]=Fact(21,'buff');F:Refresh('page_hidden',true);assert(F:GetManagementFreezeState().count==1)
    assert(F:ClearFrozenRows());assert(F.consumerCount==0 and leases==0 and not tasks[F.taskName])
end)
Test('incomplete observation never says previously observed status disappeared',function()
    Reset();facts.player[21]=Fact(21,'buff');F:CaptureManagementFreeze();F:ObserveManagementRows('player',{}, {available=false,complete=false,reliable=false},101)
    assert(Find(F:GetManagementProjection({view='frozen'}),21).present==true,'incomplete scan fabricated disappearance')
end)
Test('newly observed shared metadata invalidates inactive tracked icon cache',function()
    Reset();dofile('services/rs_buff_metadata_v3.lua');local M=S.Services.BuffMetadataV3;assert(F:SetTrackedId(21,'auto',true));local first=F:GetManagementProjection({view='tracked'})
    assert(M:Remember(21,'name','observed.dds'));local second=F:GetManagementProjection({view='tracked'})
    assert(first~=second and second[1].iconPath=='observed.dds')
end)


Test('diagnostic report exposes committed tracking and retention without native reads',function()
    Reset();assert(F:ImportBuiltinPack('recommended',false));F:CaptureManagementFreeze();dofile('core/rs_diagnostics.lua');local before=scans
    local row;for _,v in ipairs(S.DiagnosticsManager:BuildFeatureStatusRows()) do if v.id=='buff_display' then row=v end end
    assert(row and row.tracking and row.tracking.patch=='status-retain-library-1','tracking evidence missing')
    assert(row.tracking.auto==397 and row.tracking.lastImport.ok==true and row.tracking.capture.active==true)
    assert(scans==before,'diagnostic performed native scan')
end)

-- 兼容边界：默认推荐库仅含状态，但旧技能CD收藏包仍可选，不能被新的成功导航隐藏。
Test('legacy cooldown library imports remain visible in the cooldown collection view',function()
    Reset();local page=assert(host:Build());page.libraryPack='cooldown:skill';page:SwitchTab('library')
    assert(host.widgets.v3_buff_library_import.onClick())
    assert(page.activeTab=='track' and page.managementView=='cooldowns','old cooldown package hidden by import navigation')
    assert(#host.widgets.v3_buff_display_tracking_table.items>0)
    for _,row in ipairs(host.widgets.v3_buff_display_tracking_table.items) do assert(row.tracked and row.kind=='skill') end
end)

print(string.format('CAPTURE LIBRARY RESULT %d passed / %d failed (%s)',passed,failed,_VERSION));if failed>0 then error('capture/library regression failed') end

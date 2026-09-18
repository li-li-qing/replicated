-- Maintenance: enemy loadout regression. Real Feature/Store/projection; Native facts, clock and UI are
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

dofile('data/rs_team_auto_role_catalog.lua')
Test('live target type icons do not require tracking',function()
    Reset();facts.target[716]=Fact(716,'buff');facts.target[4899]=Fact(4899,'hidden');assert(F:RefreshScope('target'))
    local p=F:GetPlatesProjection('target');assert(p.mainHand and p.offHand,'target loadout missing')
    assert(p.mainHand.name=='双持' and p.offHand.name=='皮甲');assert(p.mainHand.icon=='icons/4899.dds')
    assert(p.mainHand.source=='observed_buff' and p.offHand.buffId==716)
    assert(p.mainHand.gradeIconPath=='','buff type must never invent equipment grade')
end)
Test('shield and two handed IDs are distinct',function()
    for id,name in pairs({[8226]='盾牌',[8227]='双手'}) do
        Reset();facts.target[id]=Fact(id,'buff');F:RefreshScope('target')
        local p=F:GetPlatesProjection('target');assert(p.mainHand and p.mainHand.name==name)
    end
end)
Test('armor compatibility IDs resolve by central catalog',function()
    for id,name in pairs({[714]='布甲',[740]='板甲',[16551]='布甲',[16552]='皮甲',[16553]='板甲'}) do
        Reset();facts.target[id]=Fact(id,'buff');F:RefreshScope('target');assert(F:GetPlatesProjection('target').offHand.name==name)
    end
end)
Test('duplicate aliases of same type are not conflicts',function()
    Reset();facts.target[716]=Fact(716,'buff');facts.target[16552]=Fact(16552,'hidden');F:RefreshScope('target')
    assert(F:GetPlatesProjection('target').offHand.name=='皮甲')
end)
Test('conflicting types fail closed instead of inventing equipment',function()
    Reset();facts.target[8226]=Fact(8226,'buff');facts.target[8227]=Fact(8227,'hidden');F:RefreshScope('target')
    local p=F:GetPlatesProjection('target');assert(p.mainHand==nil,'conflicting weapon type displayed')
    assert(F.laneData.target.targetLoadout.weaponConflict==true,'conflict evidence absent')
end)
Test('debuff ID collision does not identify equipment',function()
    Reset();facts.target[716]=Fact(716,'debuff');F:RefreshScope('target');assert(F:GetPlatesProjection('target').offHand==nil)
end)
Test('unknown and vanished effects remove type icons',function()
    Reset();facts.target[716]=Fact(716,'buff');F:RefreshScope('target');facts.target={[987654]=Fact(987654,'buff')}
    F:RefreshScope('target');assert(F:GetPlatesProjection('target').offHand==nil)
end)
Test('read failure cannot retain old enemy equipment type',function()
    Reset();facts.target[716]=Fact(716,'buff');F:RefreshScope('target')
    S.Services.AuraObservationV3.GetSnapshot=function()return nil,'unavailable'end
    F:RefreshScope('target');assert(F:GetPlatesProjection('target').offHand==nil,'stale target type leaked')
end)
Test('missing icon does not invent a texture or item identity',function()
    Reset();facts.target[716]=Fact(716,'buff');facts.target[716].iconPath=nil;F:RefreshScope('target')
    local p=F:GetPlatesProjection('target');assert(p.offHand and p.offHand.name=='皮甲' and p.offHand.icon=='')
end)
Test('self actual equipment remains authoritative',function()
    Reset();facts.player[716]=Fact(716,'buff');F.laneData.player.mainHand={name='Actual sword',icon='sword.dds',gradeIconPath='grade.dds'}
    F:RefreshScope('player');local p=F:GetPlatesProjection('player');assert(p.mainHand.name=='Actual sword' and p.mainHand.gradeIconPath=='grade.dds')
end)
Test('equipment lane never reads foreign equipment and preserves derived facts',function()
    Reset();facts.target[716]=Fact(716,'buff');facts.target[8226]=Fact(8226,'buff');F:RefreshScope('target');F.consumerCount=1
    F:EquipmentTick();local p=F:GetPlatesProjection('target');assert(p.offHand and p.mainHand,'equipment lane cleared observed types')
end)
Test('class projection carries role icon without changing class name',function()
    local p=F.ProjectPlates({class={name='My class',icon='role.dds',key='test'}},{})
    assert(p.class.value=='My class' and p.class.icon=='role.dds')
end)
Test('metadata role icon resolves exact existing class key',function()
    Reset();F.consumerCount=1;F.State.settings.headEnabled=true
    X2Unit={};X2Locale={LocalizeUiText=function()end};COMBINED_ABILITY_NAME_TEXT=1
    S.Api.CallCapability=function(_,cap,obj,method,...)
        if method=='GetTargetAbilityTemplates' then return true,{{index=5},{index=3},{index=4}} end
        if method=='LocalizeUiText' then return true,'Localized class' end
        return false
    end
    F:MetadataTick();local p=F:GetPlatesProjection('player')
    assert(p.class and p.class.icon=='ui/icon/icon_skill_adamant15.dds','exact Tank icon missing')
    assert(p.class.value=='Localized class')
end)
Test('unknown class key stays text only and clears prior icon',function()
    Reset();F.consumerCount=1;F.State.settings.headEnabled=true;X2Unit={};X2Locale={LocalizeUiText=function()end};COMBINED_ABILITY_NAME_TEXT=1
    F.laneData.player.class={name='Localized class',icon='old.dds',key='old'}
    S.Api.CallCapability=function(_,cap,obj,method,...)
        if method=='GetTargetAbilityTemplates' then return true,{{index=91},{index=92},{index=93}} end
        if method=='LocalizeUiText' then return true,'Localized class' end
        return false
    end
    F:MetadataTick();local p=F:GetPlatesProjection('player');assert(p.class and not p.class.icon,'same name retained stale role icon')
end)
print(string.format('ENEMY_LOADOUT_RESULT passed=%d failed=%d',passed,failed));assert(failed==0,'enemy loadout regression failed')

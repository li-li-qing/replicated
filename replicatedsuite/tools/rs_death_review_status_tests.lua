-- 真实 Authority/Aura 投影/Store/Core；Native 读取、时钟和调度边界采用明确模型。
local passed, failed = 0, 0
local function Copy(v) if type(v)~='table' then return v end local o={};for k,x in pairs(v) do o[k]=Copy(x) end;return o end
local function Test(name,fn) local ok,err=pcall(fn);if ok then passed=passed+1;print('PASS death-status '..name) else failed=failed+1;print('FAIL death-status '..name..': '..tostring(err)) end end
local function Boot(disk)
    local h={disk=Copy(disk or {}),at=4000,tasks={},reads=0,lookups={}}
    ADDON={LoadData=function(_,k)return Copy(h.disk[k])end,SaveData=function(_,k,v)h.disk[k]=Copy(v);return true end,ClearData=function(_,k)h.disk[k]=nil;return true end}
    ReplicatedSuite={Features={},Services={},RSUI={},UI={CreateWindowShell=function()error('Native UI unavailable')end},NowMs=function()return h.at end,SafeTraceback=debug.traceback}
    local s=ReplicatedSuite
    dofile('core/rs_utils.lua');dofile('core/rs_reuse.lua');dofile('core/rs_demand.lua');dofile('core/rs_api.lua');dofile('core/rs_api_capabilities.lua')
    dofile('core/rs_persistence_transport.lua');dofile('core/rs_persistence.lua');dofile('ui/framework/rs_ui_floating_surface.lua')
    dofile('features/combat/death_review/rs_death_review_store.lua')
    local f=s.Features.DeathReview;assert(f:EnsureStoreLoaded());f.enabled=true;f.auraConsumerHeld=true
    s.Services.UnitIdentityV3={IsPlayerName=function(_,name)return name=='Me'end}
    s.Services.SkillMetadataV3={GetSkillInfo=function(_,id)h.lookups[#h.lookups+1]=id;return {iconPath='skill/'..id..'.dds'}end}
    dofile('services/rs_aura_observation_v3.lua')
    local aura=s.Services.AuraObservationV3
    h.actualSnapshotRead=aura.GetSnapshot
    function aura:GetSnapshot(_,options) h.reads=h.reads+1;h.options=options;return Copy(h.snapshot) end
    s.Scheduler={AddOneShot=function(_,id,delay,fn)h.tasks[id]=fn;return true end,RemoveTask=function(_,id)h.tasks[id]=nil;return true end}
    dofile('features/combat/death_review/rs_death_review_authority.lua')
    function h:Lane(id,name,path,time) return {available=true,reliable=true,complete=true,count=1,rows={{effectId=id,data={name=name,path=path,stack=2,timeLeft=time}}}} end
    h.snapshot={buff=h:Lane(11,'护盾','buff.dds',8000),debuff=h:Lane(22,'流血','debuff.dds',3000)}
    function h:Damage(kind,id,time) h.at=time or h.at;f.Authority:OnCombatFact({kind=kind,category='damage',targetName='Me',sourceName='Enemy',abilityName='Test',amount=321,rawAbilityId=id,receivedAt=h.at,sequence=1}) end
    return h,s,f,s.Persistence
end
Test('both lanes keep icon stack and millisecond duration',function()
    local h,s,f=Boot();assert(f.Authority:SampleDebuffs(4000,true));assert(h.options.buff==true)
    local r=f.Authority:FinalizeDeath(5000,2)
    assert(#r.buffs==1 and #r.debuffs==1);assert(r.buffs[1].path=='buff.dds' and r.debuffs[1].timeLeft==3000)
    assert(r.statusSnapshot.time==4000 and r.statusSnapshot.buff=='complete')
end)
Test('death notification freezes before post-death empty reads and pending samples',function()
    local h,s,f=Boot();assert(f.Authority:SampleDebuffs(4000,true));h.at=5000
    f.Authority:OnCombatFact({kind='death_notice',subjectName='Me',receivedAt=5000,sequence=2})
    h.snapshot={buff={available=true,reliable=true,complete=true,rows={}},debuff={available=true,reliable=true,complete=true,rows={}}}
    assert(f.Authority:SampleDebuffs(5010,true));assert(h.tasks.death_review_finalize());local r=f.Authority:GetRecord()
    assert(#r.buffs==1 and r.statusSnapshot.time==4000,'post-death cleared snapshot replaced frozen capture')
    assert(h.reads==1,'death performed another Native scan')
end)
Test('unavailable and truncated lanes never claim a verified empty state',function()
    local h,s,f=Boot();h.snapshot.buff.available=false;h.snapshot.debuff.complete=false;h.snapshot.debuff.reliable=false
    assert(f.Authority:SampleDebuffs(4000,true));local r=f.Authority:FinalizeDeath(5000,2)
    assert(r.statusSnapshot.buff=='unavailable' and r.statusSnapshot.debuff=='partial');assert(#r.buffs==0 and #r.debuffs==1)
end)
Test('no pre-death capture is unknown and never borrows a future sample',function()
    local h,s,f=Boot();assert(f.Authority:SampleDebuffs(5100,true));local r=f.Authority:FinalizeDeath(5000,2)
    assert(#r.buffs==0 and #r.debuffs==0 and r.statusSnapshot.buff=='uncollected')
end)
Test('skill icons resolve only verified spell IDs outside combat dispatch',function()
    local h,s,f=Boot();h:Damage('melee_damage',123,4100);h:Damage('spell_damage',456,4300)
    assert(#h.lookups==0,'Native metadata read inside combat callback');local r=f.Authority:FinalizeDeath(5000,2)
    assert(r.events[1].abilityId==nil and r.events[2].abilityId==456);assert(r.events[2].iconPath=='skill/456.dds')
    assert(#h.lookups==1);local rows=f.Authority:GetTimelineRows();assert(rows[2].iconPath=='skill/456.dds')
end)
Test('new record icons and statuses survive a real cold roundtrip',function()
    local h,s,f,p=Boot();h:Damage('spell_damage',456,4000);assert(f.Authority:SampleDebuffs(4000,true));local r=f.Authority:FinalizeDeath(5000,2)
    assert(f.Authority.volatileRecord==nil,'record did not persist')
    local h2,s2,f2=Boot(h.disk);local loaded=assert(f2:LoadRecord(f.State.history.entries[1].storageId))
    assert(loaded.buffs[1].path==r.buffs[1].path and loaded.events[1].iconPath==r.events[1].iconPath)
end)
Test('schema1 disk fingerprint remains valid and missing buff capture stays missing',function()
    local h,s,f,p=Boot()
    -- 旧分片是 schema1 默认 payload 外壳，canonical 为原始 schema1 normalize 结果。
    local id=assert(f:EnsureRecordStore(1));local old=p:GetStore(id)
    old.schemaVersion=1;old.encode=nil;old.decode=nil;old.migrate=function(v)return Copy(v)end
    assert(f:CommitDeathRecord({serial=1,time=4000,events={{time=4000,source='A',ability='B',amount=1}},debuffs={{effectId=22,name='Legacy',stack=1,path='old.dds'}}}))
    local oldRecord=Copy(f.Records[1]);local h2,s2,f2,p2=Boot(h.disk);local r=assert(f2:LoadRecord(1))
    assert(r.schemaVersion==1 and r.buffs==nil and r.statusSnapshot==nil and r.debuffs[1].path=='old.dds')
    assert(p2:GetStore('v3.death_review.record.1').writeFenced~=true)
    assert(s2.Utils.DeepEqual==nil or s2.Utils.DeepEqual(r,oldRecord))
end)
Test('96 mixed damage rows plus 32 buffs and 32 debuffs fit the native shard budget',function()
    local h,s,f,p=Boot();local events,buffs,debuffs={},{},{}
    for i=1,96 do local id=i%8;events[i]={time=4000+i,source='Enemy '..id,ability='混合伤害技能 '..id,abilityId=456+id,iconPath='ui/icon/skill_mixed_damage_'..id..'.dds',amount=321} end
    for i=1,32 do buffs[i]={effectId=i,name='死亡前增益 '..i,stack=1,timeLeft=10000,path='ui/icon/buff_death_review_'..i..'.dds'};debuffs[i]={effectId=100+i,name='死亡前减益 '..i,stack=2,timeLeft=3000,path='ui/icon/debuff_death_review_'..i..'.dds'} end
    local ok,r=f:CommitDeathRecord({schemaVersion=2,serial=1,time=5000,events=events,buffs=buffs,debuffs=debuffs,statusSnapshot={time=4000,buff='complete',debuff='complete'}})
    assert(ok,tostring(r));local st=p:GetStore('v3.death_review.record.1');assert(st.lastNativeByteEstimate<14336,tostring(st.lastNativeByteEstimate));assert(#r.events==96 and #r.debuffs==32 and #r.buffs==32)
    local _,_,reloaded=Boot(h.disk);local cold=assert(reloaded:LoadRecord(1));assert(#cold.events==96 and #cold.buffs==32 and cold.debuffs[32].path==r.debuffs[32].path)
end)
Test('status lifecycle events defer and coalesce reads then release on shutdown',function()
    local h,s,f=Boot();f.enabled=false;f.auraConsumerHeld=false
    local listeners={};s.Events={SubscribeOptional=function(_,event,owner,fn)listeners[event]={owner,fn};return true end,
        UnsubscribeOwner=function(_,owner)for event,row in pairs(listeners)do if row[1]==owner then listeners[event]=nil end end end}
    local aura=s.Services.AuraObservationV3;aura.AcquireConsumer=function()return true end;aura.ReleaseConsumer=function()return true end
    s.Services.CombatEventBusV3={Subscribe=function()return true end,Unsubscribe=function()return true end}
    s.FeatureRuntime={RegisterImplementation=function()return true end}
    dofile('features/combat/death_review/rs_death_review_feature.lua')
    assert(f:Enable());assert(h.reads==0 and listeners.BUFF_UPDATE and listeners.DEBUFF_UPDATE)
    assert(h.tasks[f.Authority.debuffSampleTask]());h.tasks[f.Authority.debuffSampleTask]=nil
    h.at=4100;listeners.BUFF_UPDATE[2](f);listeners.DEBUFF_UPDATE[2](f);assert(h.reads==1)
    h.at=4200;assert(h.tasks[f.Authority.debuffSampleTask]());assert(h.reads==2)
    h.at=4300;listeners.BUFF_UPDATE[2](f);assert(f:Disable())
    assert(next(listeners)==nil and next(h.tasks)==nil and not f.auraConsumerHeld)
end)
Test('codec tampering is fenced and does not apply corrupt status rows',function()
    local h,s,f,p=Boot();assert(f.Authority:SampleDebuffs(4000,true));f.Authority:FinalizeDeath(5000,2)
    local st=p:GetStore('v3.death_review.record.1');local raw=assert(p:DecodePhysicalEnvelope(h.disk[st.resolvedKey]))
    if type(raw.buffs)=='table' then raw.buffs[1]='11,9999,2,8000,1' else raw.buffs='11,9999,2,8000,1' end
    h.disk[st.resolvedKey]=assert(p:EncodePhysicalEnvelope(raw))
    local h2,s2,f2,p2=Boot(h.disk);local r,err=f2:LoadRecord(1)
    assert(r==nil and p2:GetStore(st.id).writeFenced,'invalid dictionary pointer was accepted')
end)
Test('scheduler rejection never falls back to native reads inside combat dispatch',function()
    local h,s,f=Boot();s.Scheduler.AddOneShot=function()return false end
    h:Damage('spell_damage',456,4000)
    assert(h.reads==0 and #h.lookups==0 and f.Authority.debuffDeferFailures==1)
end)
Test('status-change edge bypasses a fresh empty shared Aura cache',function()
    local h,s,f=Boot();local aura=s.Services.AuraObservationV3
    aura.GetSnapshot=h.actualSnapshotRead;aura.Demand.count=1
    aura._ScanLane=function(_,_,lane)return Copy(h.snapshot[lane])end
    h.at=5000;h.snapshot.buff.rows={};h.snapshot.buff.count=0
    assert(aura:GetSnapshot('player',{buff=true,debuff=true,buffLimit=32,debuffLimit=32}))
    h.at=5020;h.snapshot.buff=h:Lane(11,'New shield','shield.dds',8000)
    assert(f.Authority:RequestDebuffSample(nil,true));assert(h.tasks[f.Authority.debuffSampleTask]())
    local r=f.Authority:FinalizeDeath(5060,2);assert(#r.buffs==1 and r.buffs[1].name=='New shield','fresh shared cache swallowed status event')
end)
print('DEATH_REVIEW_STATUS: '..passed..' pass / '..failed..' fail (Native modeled)');assert(failed==0)

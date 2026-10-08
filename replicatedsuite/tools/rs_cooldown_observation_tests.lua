-- CooldownObservationV3/V4 offline contract tests. PASS proves the corrected
-- architecture: Buff/Aura ids are not cooldown ids, normal runtime has no
-- CombatEventBus dependency, and only Native X2Skill cooldown getters own the
-- countdown. It does not claim every RU live Skill id is known statically.
unpack=unpack or table.unpack
ReplicatedSuite={Generation=1,Services={},Data={},NowMs=function() return ReplicatedSuite._now or 0 end,SafeTraceback=function(e)return tostring(e)end}
local S=ReplicatedSuite
S._now=1000
S.Events={published={}}
function S.Events:Publish(topic,key,revision) self.published[#self.published+1]={topic=topic,key=key,revision=revision} end
S.Scheduler={tasks={}}
function S.Scheduler:AddTask(name,interval,cb,immediate,owner,priority,cost)
    self.tasks[name]={cb=cb,interval=interval,immediate=immediate,owner=owner,priority=priority,cost=cost}
    return true
end
function S.Scheduler:RemoveTask(name) self.tasks[name]=nil;return true end
function S.Scheduler:SetTaskModule() return true end
S.Data.StatusTrackingCatalogV3={
    ByKey={
        ["cooldown:skill:100"]={name="Wing Test"},
        ["cooldown:mate:200"]={name="Mate Test"},
    },
    ByEffectId={ [555]={id=555,name="Aura Only",skillIds={}} },
    BySkillId={ [100]={} },
}
S.Services.SkillMetadataV3={}
function S.Services.SkillMetadataV3:GetSkillInfo(id,name)
    if id==100 then return {name=name~="" and name or "Wing Test",iconPath="ui/icon/test_100.dds",resolved=true,source="x2skill_info"} end
    if id==200 then return {name=name~="" and name or "Mate Test",iconPath="ui/icon/test_200.dds",resolved=true,source="x2skill_info"} end
    if id==555 then return {name="Aura Only",iconPath="ui/icon/unknown.dds",resolved=false,source="fallback"} end
    return {name=name~="" and name or ("Skill "..id),iconPath="ui/icon/unknown.dds",resolved=false,source="fallback"}
end
local skillRemain,mateRide,mateBattle=0,0,0
local failSkill,failMate=false,false
S.Api={}
function S.Api:CallCapability(_,_,method,id,ignore,mateType)
    assert(ignore==true,"GCD must be ignored")
    if method=="GetCooldown" then
        if failSkill then return false,nil,"skill unavailable" end
        return true,skillRemain,nil,30000
    end
    if method=="GetMateCooldown" then
        if failMate then return false,nil,"mate unavailable" end
        if mateType==1 then return true,mateRide,nil,90000 end
        if mateType==2 then return true,mateBattle,nil,90000 end
    end
    return false,nil,"unexpected api call"
end
S.Demand={}
function S.Demand:Create(spec)
    local L={count=0,consumers={}}
    function L:Has(token)return self.consumers[token]~=nil end
    local function copyConsumers(source)local out={};for k,v in pairs(source)do out[k]=v end;return out end
    function L:Acquire(token,options)
        local before={count=self.count,consumers=copyConsumers(self.consumers)}
        self.consumers[token]=spec.normalize and spec.normalize(options) or options
        self.count=0;for _ in pairs(self.consumers)do self.count=self.count+1 end
        return spec.reconcile(self,before,{count=self.count,consumers=self.consumers})
    end
    function L:Release(token)
        local before={count=self.count,consumers=copyConsumers(self.consumers)}
        self.consumers[token]=nil
        self.count=0;for _ in pairs(self.consumers)do self.count=self.count+1 end
        return spec.reconcile(self,before,{count=self.count,consumers=self.consumers})
    end
    return L
end

dofile("services/rs_cooldown_observation_v3.lua")
local C=S.Services.CooldownObservationV3
assert(C.version==5 and C.NativeSkillIdContractVersion==1 and C.AutomaticDiscoveryContractVersion==1,"corrected cooldown contracts missing")
local health=C:GetHealth()
assert(health.eventIndependent==true and health.subscribed==false and health.busScope=="none","cooldown runtime must not depend on CombatEventBus")
assert(health.idContract=="skill_id_only","cooldown id namespace must be explicit")
local parsedRemain,parsedTotal=C:ParseCooldownResult(false,1400,30000,nil)
assert(parsedRemain==1400 and parsedTotal==30000,"return parser must tolerate wrapper fields")

local valid,detail=C:ValidateSkillId(100,"skill")
assert(valid==true and detail.resolved==true,"known Skill id must validate")
local effectOk,effectErr=C:ValidateSkillId(555,"mate")
assert(effectOk==false and string.find(tostring(effectErr),"Buff/Effect ID",1,true)~=nil,"known Effect-only id must be rejected for CD tracking")
local unknownOk,unknownDetail=C:ValidateSkillId(999,"mate")
assert(unknownOk==true and unknownDetail.resolved==false,"unknown ids remain probeable because static catalog is incomplete")

assert(C:AcquireConsumer("test",{skillIds={100},mateIds={200}}))
assert(C.taskActive==false,"READY ids must not use active lane")
assert(C.probeTaskActive==true and S.Scheduler.tasks[C.probeTaskName],"tracked Skill ids need Native READY probe")
assert(C:GetHealth().probeIntervalMs==250,"corrected event-independent probe cadence missing")

-- No combat event is emitted. Native getters alone discover a running wing CD.
skillRemain=25000
S.Scheduler.tasks[C.probeTaskName].cb()
local rows=C:GetActiveRows()
assert(#rows==1 and rows[1].id==100 and rows[1].idType=="skill" and rows[1].remainingMs==25000)
assert(C.taskActive==true and S.Scheduler.tasks[C.taskName],"positive Native observation must arm active lane")

-- Mate type is learned only from a positive GetMateCooldown observation.
mateBattle=88000
S.Scheduler.tasks[C.probeTaskName].cb()
rows=C:GetActiveRows()
assert(#rows==2 and C.mateTypeById[200]==2,"battle mate type must be Native-proven")
assert(C.probeHits>=2,"Native probes should record both active cooldowns")

-- Complete both. No pending/event fast path should exist afterwards.
skillRemain,mateBattle=0,0
S.Scheduler.tasks[C.taskName].cb()
rows=C:GetActiveRows()
assert(#rows==0 and C.taskActive==false,"completed cooldowns must release active task")
health=C:GetHealth()
assert(health.pending==0 and health.pendingMaxAttempts==0,"legacy combat-event pending lane must stay removed")

-- Native failure is Unknown, not Ready; stale countdown comes only from the last
-- successful Native snapshot and naturally expires.
skillRemain=15000
S.Scheduler.tasks[C.probeTaskName].cb()
rows=C:GetActiveRows();assert(#rows==1 and rows[1].remainingMs==15000)
failSkill=true;S._now=6000
S.Scheduler.tasks[C.taskName].cb()
rows=C:GetActiveRows()
assert(#rows==1 and rows[1].authority=="LocalNativeSnapshot" and rows[1].stale==true)
assert(rows[1].remainingMs==10000,"snapshot must age from Native remaining/time")
S._now=17000
S.Scheduler.tasks[C.taskName].cb()
rows=C:GetActiveRows()
assert(#rows==0 and C.estimatedExpirations==1,"snapshot must naturally expire")
failSkill=false;skillRemain=0

assert(C:ReleaseConsumer("test"))
assert(C.trackedCount==0 and C.taskActive==false and C.probeTaskActive==false,"last release must drop runtime work")
assert(S.Scheduler.tasks[C.taskName]==nil and S.Scheduler.tasks[C.probeTaskName]==nil,"release must remove scheduler tasks")
assert(next(C.metadata)==nil and next(C.mateTypeById)==nil and next(C.nativeEvidence)==nil,"release must clear ephemeral caches")

assert(C:AcquireConsumer("empty",{skillIds={},mateIds={}}))
assert(C.trackedCount==0 and C.taskActive==false and C.probeTaskActive==false,"empty selection must stay zero-cost")
assert(C:ReleaseConsumer("empty"))

-- 中文维护注释（2026-09-28，native-dependency-ownership-4，FND-016 收口）：
-- 本段新增 X2Skill lazy ownership 覆盖。上面所有断言运行时 S.ApiImports 不存在，服务按 fail-soft
-- 记录 imports_unavailable 并继续工作（这正是“诊断环境不该假造导入能力”的期望行为）。
-- 这里显式提供 Imports 替身，证明：
--   (1) 第一个 consumer 进入时服务自己取得 X2Skill owner；
--   (2) 幂等，不重复 AcquireApi；
--   (3) 导入失败保持 fail-soft，消费需求仍然建立。
local acquireCalls={}
S.ApiImports={}
function S.ApiImports:AcquireApi(owner,name)
    acquireCalls[#acquireCalls+1]={owner=owner,name=name}
    if self.failNext then return false,"synthetic_import_failure" end
    return true
end
C.nativeSkillLease,C.nativeSkillLeaseState,C.nativeSkillLeaseError=false,"idle",nil
assert(C:AcquireConsumer("lease",{skillIds={},mateIds={}}),"consumer acquire must not depend on native import")
assert(C.nativeSkillLease==true and C.nativeSkillLeaseState=="acquired","lazy X2Skill owner not acquired")
assert(#acquireCalls==1 and acquireCalls[1].owner=="service.cooldown_observation_v3" and acquireCalls[1].name=="X2Skill",
    "X2Skill must be acquired once by the service itself: "..tostring(acquireCalls[1] and acquireCalls[1].name))
assert(C:GetHealth().nativeSkillLease==true and C:GetHealth().nativeSkillLeaseState=="acquired","lease not surfaced in health")
assert(C:AcquireConsumer("lease2",{skillIds={},mateIds={}}))
assert(#acquireCalls==1,"acquired lease must be idempotent")
assert(C:ReleaseConsumer("lease2"))
assert(C:ReleaseConsumer("lease"))

C.nativeSkillLease,C.nativeSkillLeaseState,C.nativeSkillLeaseError=false,"idle",nil
S.ApiImports.failNext=true
assert(C:AcquireConsumer("leasefail",{skillIds={},mateIds={}}),"native import failure must stay fail-soft")
assert(C.nativeSkillLease==false and C.nativeSkillLeaseState=="failed","failed import must stay recorded")
assert(tostring(C:GetHealth().nativeSkillLeaseError):find("synthetic_import_failure",1,true)~=nil,"failure reason lost")
assert(C:ReleaseConsumer("leasefail"))
print("COOLDOWN_OBSERVATION_V5 MANUAL CONTRACT PASS")

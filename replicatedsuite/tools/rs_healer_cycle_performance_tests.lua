-- Replicated Suite · 治疗周期名单复用回归
-- 真实 Store/Roster/Recommendation/HealthRuntime/Feature，Native 仅给明确桩事实。
-- 计数约束未变化名单的复制量；同时验证职责提交、公开隔离、生命周期与 Aura unknown，不证明 RU 帧率。
local passed, failed = 0, 0
local function Test(name, callback)
    local ok, err = xpcall(callback, debug.traceback)
    if ok then passed=passed+1; print("PASS healer-cycle " .. name)
    else failed=failed+1; print("FAIL healer-cycle " .. name .. ": " .. tostring(err)) end
end
local Host = dofile("tools/rs_gear_page_test_host.lua")

-- 只替换外部名单/Native/调度边界；计数包装仍执行真实 GetSnapshot 深复制。
local function CountSnapshots(h, roster)
    local original = roster.GetSnapshot
    roster.GetSnapshot = function(self)
        h.snapshots = h.snapshots + 1
        h.memberRowCopies = h.memberRowCopies + #self.members
        return original(self)
    end
end
local function Boot(count)
    local h=Host({width=1280,height=768}); h.page:OnDeactivated()
    local S=h.S
    dofile("core/rs_demand.lua")
    h.now, h.role, h.partial, h.snapshots, h.memberRowCopies = 10000, 2, false, 0, 0
    h.shared = {revision=1,members={}}
    for i=1,(count or 100) do
        h.shared.members[i]={name="Member "..i,unitToken="team_"..i,
            teamIndex=i<=50 and 1 or 2,memberIndex=((i-1)%50)+1}
    end
    S.NowMs=function() return h.now end
    S.Services.TeamRosterV3={GetSnapshot=function() return S.Utils.DeepCopy(h.shared) end}
    local tasks={}
    S.Scheduler={AddTask=function(_,name,_,callback) tasks[name]=callback; return true end,
        RemoveTask=function(_,name) tasks[name]=nil; return true end}
    X2Unit, X2Team = {}, {}
    local function NativeRead(_,capability,host,method)
        if method=="GetRole" then return true,h.role end
        if method=="UnitHealth" then return true,400 end
        if method=="UnitMaxHealth" then return true,1000 end
        if method=="UnitDistance" then return true,10 end
        error("unexpected capability "..tostring(capability))
    end
    S.Features.HealerAuraBridge={ReadAccurate=function()
        if h.partial then return nil,{available=true,complete=false,reliable=false},"partial aura" end
        return {[25875]={id=25875,stack=1,timeLeft=1000,timeKnown=true,sourceMask=1}},
            {available=true,complete=true,reliable=true,scannedAt=h.now,source="aura_v3"}
    end}
    for _,path in ipairs({
        "features/combat/healer/rs_healer_store.lua",
        "features/combat/healer/rs_healer_roster_v3.lua",
        "features/combat/healer/rs_healer_recommendation_v3.lua",
        "features/combat/healer/rs_healer_health_v3.lua",
        "features/combat/healer/rs_healer_feature.lua",
    }) do dofile(path) end
    local F=S.Features.Healer; assert(F:EnsureStoreLoaded())
    S.Api.CallCapability=NativeRead
    F.State.settings.roleScoringEnabled=false
    local R,D,H=F.Roster,F.Recommendation,F.HealthRuntime
    assert(R:SyncFromShared("test",false)); CountSnapshots(h,R)
    return h,S,F,R,D,H,tasks
end
local function FinishStatus(H, now)
    H:StartStatusCycle(now)
    while H.status.active do H:RunStatusSlice() end
end
local function FinishHealth(H, now)
    H:StartHealthCycle(now)
    while H.health.active do H:RunHealthSlice() end
end
local function FinishRoles(R)
    while not R:RunRoleSlice() do end
end

Test("100 unchanged members are copied once across 20 cycle starts",function()
    local h,S,F,R,D,H=Boot(100)
    for i=1,10 do
        H:StartStatusCycle(h.now); H:StartHealthCycle(h.now)
        assert(#H.health.members==100 and #H.status.members==100)
        assert(H.health.members~=H.status.members and H.health.members~=R.members)
        assert(H.health.members[1]~=R.members[1],"borrowed mutable roster authority")
        H:AbortCycles()
    end
    print("COUNT healer-cycle starts=20 snapshots="..h.snapshots.." memberRowCopies="..h.memberRowCopies)
    assert(h.snapshots==1 and h.memberRowCopies==100,"unchanged roster copied "..h.snapshots.." times")
end)

Test("completed publications retain the private roster without clearing its rows",function()
    local h,S,F,R,D,H=Boot(100)
    FinishStatus(H,h.now); FinishHealth(H,h.now)
    assert(#D.recommendations==100 and D.recommendations[1].name=="Member 1")
    h.now=h.now+500; FinishStatus(H,h.now); FinishHealth(H,h.now)
    assert(#D.recommendations==100 and #H.health.members==0 and #H.status.members==0)
    assert(h.snapshots==1 and h.memberRowCopies==100)
end)

Test("same identities reordered and removed members refresh the next cycle",function()
    local h,S,F,R,D,H=Boot(100)
    H:StartHealthCycle(h.now); local old=H.health.members[1]
    h.shared.members[1],h.shared.members[100]=h.shared.members[100],h.shared.members[1]
    local ok,err,changed=R:SyncFromShared("reorder",false)
    assert(ok and changed==false)
    H:StartStatusCycle(h.now)
    assert(H.status.members[1].name=="Member 100" and H.health.members[1]==old and old.name=="Member 1")
    table.remove(h.shared.members,100); assert(R:SyncFromShared("remove",false))
    H:StartHealthCycle(h.now)
    assert(#H.health.members==99 and H.health.members[1].name=="Member 100")
    assert(h.snapshots==3 and h.memberRowCopies==299)
end)

Test("empty roster replaces cached members and clears committed recommendations",function()
    local h,S,F,R,D,H=Boot(1)
    FinishStatus(H,h.now); FinishHealth(H,h.now); assert(#D.recommendations==1)
    h.shared.members={}; assert(R:SyncFromShared("empty",false))
    FinishStatus(H,h.now); FinishHealth(H,h.now)
    assert(#D.recommendations==0 and next(D.healthSnapshot)==nil)
    assert(#H.health.members==0 and #H.status.members==0 and h.snapshots==2)
end)

Test("new names and scoring setting changes invalidate current runtime facts",function()
    local h,S,F,R,D,H=Boot(1)
    H:StartHealthCycle(h.now)
    h.shared.members[1].name="Renamed"; assert(R:SyncFromShared("rename",false))
    H:StartHealthCycle(h.now); assert(H.health.members[1].name=="Renamed")
    F.State.settings.roleOverrides.Renamed=3; H.running=true
    assert(H:OnScoringPolicyChanged("role_override"))
    H:StartHealthCycle(h.now)
    assert(H.health.members[1].role==3 and h.snapshots==3)
end)

Test("role slices cannot publish partial roles and completion replaces cached facts",function()
    local h,S,F,R,D,H=Boot(100)
    H:StartHealthCycle(h.now); local old=H.health.members[1]
    local revision=R.revision
    F.State.settings.roleScoringEnabled=true; h.now=h.now+6000
    H.running=true; H.statusGeneration=1; H:Step()
    assert(R:IsReady()==false and R.revision==revision and h.snapshots==1)
    assert(old.role==5 and R.members[1].role==4,"cached role changed during partial scan")
    assert(type(R.GetRevision)=="function" and R:GetRevision()==nil,"partial roster allowed caching")
    FinishRoles(R); assert(R.revision>revision)
    H:AbortCycles(); H:StartHealthCycle(h.now)
    assert(H.health.members[1].role==4 and old.role==5 and h.snapshots==2)
end)

Test("disabling role scoring during a role slice advances committed revision",function()
    local h,S,F,R,D,H=Boot(20)
    F.State.settings.roleScoringEnabled=true; assert(R:SyncFromShared("roles",true)); FinishRoles(R)
    H:StartHealthCycle(h.now); assert(H.health.members[1].role==4)
    local revision=R.revision
    h.now=h.now+6000; h.role=1; assert(R:RefreshRolesIfDue()); assert(not R:RunRoleSlice())
    F.State.settings.roleScoringEnabled=false; F.State.settings.roleOverrides["Member 1"]=3
    assert(R:RunRoleSlice() and R:IsReady())
    assert(R.revision>revision,"role-disabled commit did not invalidate cached roles")
    H:StartHealthCycle(h.now)
    assert(H.health.members[1].role==3 and h.snapshots==2)
end)

Test("invalidating readiness prevents reuse until the roster commits again",function()
    local h,S,F,R,D,H=Boot(1)
    H:StartHealthCycle(h.now); local revision=R.revision
    R:Invalidate("test")
    assert(R:IsReady()==false and R.revision>revision)
    assert(type(R.GetRevision)=="function" and R:GetRevision()==nil)
    h.shared.members[1].name="After invalidation"; assert(R:SyncFromShared("resync",false))
    H:StartHealthCycle(h.now)
    assert(H.health.members[1].name=="After invalidation" and h.snapshots==2)
end)

Test("equal revision on a replacement roster cannot reuse the previous domain",function()
    local h,S,F,R,D,H=Boot(1)
    H:StartHealthCycle(h.now); local old=H.health.members[1]
    h.shared.members[1].name="Replacement"
    dofile("features/combat/healer/rs_healer_roster_v3.lua")
    local replacement=F.Roster; assert(replacement:SyncFromShared("replacement",false))
    assert(replacement.revision==R.revision); CountSnapshots(h,replacement)
    H:StartHealthCycle(h.now)
    assert(H.health.members[1].name=="Replacement" and old.name=="Member 1" and h.snapshots==2)
end)

Test("legacy hosts without revision support keep fresh detached snapshots",function()
    local h,S,F,R,D,H=Boot(1)
    H:StartHealthCycle(h.now); local getRevision=R.GetRevision; R.GetRevision=nil
    R.members[1].name="Legacy live fact"
    H:StartStatusCycle(h.now); assert(H.status.members[1].name=="Legacy live fact")
    H:StartHealthCycle(h.now); assert(H.health.members[1].name=="Legacy live fact")
    assert(h.snapshots==3 and H.health.members[1]~=R.members[1])
    R.GetRevision=getRevision
    H:StartHealthCycle(h.now); assert(H.health.members[1].name=="Legacy live fact" and h.snapshots==4)
    H:StartStatusCycle(h.now); assert(h.snapshots==4)
end)

-- 递归检查真正的公开输出，防止未来把 member 引用塞入推荐/覆盖/详情结果而泄漏私有缓存。
local function AssertNoMembers(value, members, seen)
    if type(value)~="table" then return end
    assert(not members[value],"public output leaked runtime member reference")
    seen=seen or {}; if seen[value] then return end; seen[value]=true
    for key,item in pairs(value) do AssertNoMembers(key,members,seen); AssertNoMembers(item,members,seen) end
end
Test("public roster and every recommendation output isolate runtime member rows",function()
    local h,S,F,R,D,H=Boot(2)
    FinishStatus(H,h.now); H:StartHealthCycle(h.now)
    local privateMembers={}; local first=H.health.members[1]
    for _,member in ipairs(H.health.members) do privateMembers[member]=true end
    local public=F:GetRosterProjection(); public.members[1].name="Caller mutation"
    assert(first.name=="Member 1" and R.members[1].name=="Member 1")
    while H.health.active do H:RunHealthSlice() end
    local projection,roster=F:GetRaidOverlayProjection()
    for _,output in ipairs({F:GetProjection(100),F:GetMemberDetail(first.key),projection,roster,
        D:GetProjection(100),D:GetMemberProjection(first.key),D:GetRaidDisplayProjection(R:GetSnapshot().members),
        D.recommendations,D.unavailable}) do AssertNoMembers(output,privateMembers) end
    projection.rows[1].key="Caller mutation"; roster.members[1].name="Caller mutation"
    H:StartHealthCycle(h.now); assert(H.health.members[1].name=="Member 1")
end)

Test("abort retains private rows while Reset and Stop release them before restart",function()
    local h,S,F,R,D,H,tasks=Boot(1)
    H:StartHealthCycle(h.now)
    local weak=setmetatable({H.health.members[1]},{__mode="v"})
    H:AbortCycles(); collectgarbage("collect")
    assert(weak[1]~=nil,"Abort discarded reusable accurate roster")
    H:StartStatusCycle(h.now); assert(h.snapshots==1)
    H:Reset("test",true); collectgarbage("collect")
    assert(weak[1]==nil,"Reset retained private runtime roster")
    H:StartHealthCycle(h.now); assert(h.snapshots==2)
    weak[1]=H.health.members[1]; H.running=true
    assert(H:Stop("test")); collectgarbage("collect")
    assert(weak[1]==nil and tasks[H.taskName]==nil,"Stop retained private runtime roster")
    assert(H:Start("restart") and tasks[H.taskName])
    FinishStatus(H,h.now); FinishHealth(H,h.now)
    assert(#D.recommendations==1 and h.snapshots==3)
    assert(H:Stop("finished"))
end)

Test("partial Aura keeps last accurate status and cannot become missing protection",function()
    local h,S,F,R,D,H=Boot(1)
    FinishStatus(H,h.now); local key=R.members[1].key; local known=D:GetStatusRow(key)
    h.now=h.now+1000; h.partial=true
    FinishStatus(H,h.now); assert(D:GetStatusRow(key)==known)
    FinishHealth(H,h.now)
    assert(#D.recommendations==0 and #D.unavailable==1 and D.unavailable[1].reason=="状态读取暂不可用")
    assert(h.snapshots==1,"Aura partial must not trigger roster copying")
    h.partial=false; h.now=h.now+1000; FinishStatus(H,h.now); FinishHealth(H,h.now)
    assert(#D.recommendations==1 and D.recommendations[1].hasProtection and h.snapshots==1)
end)

print(string.format("HEALER CYCLE RESULT %d passed / %d failed",passed,failed))
if failed>0 then os.exit(1) end

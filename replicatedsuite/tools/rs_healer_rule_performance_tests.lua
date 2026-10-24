------------------------------------------------------------------------
-- Replicated Suite · 治疗规则临时分配回归
-- 真实 Lua 5.1 Store/Recommendation/HealthRuntime；Native 只采用明确桩模型。
-- 计数验证未消费的匹配数组与重复色表，不把离线结果解释为 RU 帧率。
------------------------------------------------------------------------
local passed, failed = 0, 0
local function Test(name, callback)
    local ok, err = xpcall(callback, debug.traceback)
    if ok then passed=passed+1; print("PASS healer-rule " .. name)
    else failed=failed+1; print("FAIL healer-rule " .. name .. ": " .. tostring(err)) end
end
local Host = dofile("tools/rs_gear_page_test_host.lua")
local function Boot()
    local h=Host({width=1280,height=768}); h.page:OnDeactivated()
    local S=h.S
    dofile("features/combat/healer/rs_healer_store.lua")
    dofile("features/combat/healer/rs_healer_recommendation_v3.lua")
    local F=S.Features.Healer; assert(F:EnsureStoreLoaded())
    return S,F,F.Recommendation
end
local function Upvalue(fn, wanted)
    for index=1,100 do
        local name,value=debug.getupvalue(fn,index)
        if name==nil then break end
        if name==wanted then return index,value end
    end
    error("missing helper "..wanted)
end
local function Member(index)
    return {key="member:"..index,unitToken="team_"..index,name="Member "..index,
        teamIndex=index<=50 and 1 or 2,raidIndex=1,memberIndex=((index-1)%50)+1,isSelf=false,role=1}
end
local function Health(percent)
    return {currentHealth=percent*10,maxHealth=1000,healthPercent=percent,
        missingHealth=1000-percent*10,distance=10}
end
local function Status(stack, remaining, source)
    return {stack=stack or 1,timeKnown=remaining~=nil,timeLeft=remaining,sourceMask=source or 1}
end
local function Rule(S,F,changes)
    local rule=S.Utils.DeepCopy(F:GetSettings().rules[1])
    rule.ids={101,102}; rule.simpleDisplayGroup=false
    for key,value in pairs(changes or {}) do rule[key]=value end
    return rule
end

Test("100 members and 12 display groups do not return unused match arrays", function()
    local S,F,D=Boot(); local rules={}
    for r=1,12 do
        local ids={}; for i=1,8 do ids[i]=r*100+i end
        rules[r]=Rule(S,F,{ids=ids,simpleDisplayGroup=true})
    end
    F.State.settings.rules=rules
    local index,original=Upvalue(D.Evaluate,"RuleMatches")
    local calls,arrays=0,0
    debug.setupvalue(D.Evaluate,index,function(...)
        calls=calls+1
        local result,unused=original(...)
        if type(unused)=="table" then arrays=arrays+1 end
        return result,unused
    end)
    local members={}
    for i=1,100 do
        local member=Member(i); members[i]=member
        D:Evaluate(member,Health(100),{}, {},1000)
        D.healthSnapshot[member.key]=Health(100)
    end
    local projection=D:GetRaidDisplayProjection(members)
    assert(calls==2400 and #projection.rows==100,"expected both real rule paths")
    print("COUNT healer-rule predicates="..calls.." returnedMatchArrays="..arrays)
    assert(arrays==0,"unused match arrays allocated: "..arrays)
end)

Test("100 detached overlay colors require one color table per row", function()
    local S,F,D=Boot(); local members={}
    for i=1,100 do
        local member=Member(i); members[i]=member
        D.healthSnapshot[member.key]=Health(85)
        D.recommendations[i]=assert(D:Evaluate(member,Health(85),{}, {},1000))
    end
    local index,original=Upvalue(D.GetRaidDisplayProjection,"CopyColor")
    local copies=0
    debug.setupvalue(D.GetRaidDisplayProjection,index,function(...)
        copies=copies+1; return original(...)
    end)
    local projection=D:GetRaidDisplayProjection(members)
    print("COUNT healer-rule overlayRows="..#projection.rows.." colorTables="..copies)
    assert(#projection.rows==100 and copies==100,"duplicated color copies: "..copies)
    assert(projection.rows[1].color~=D.recommendations[1].color)
end)

Test("multi ID any and all retain stack source and remaining time rules", function()
    local S,F,D=Boot()
    local template=S.Utils.DeepCopy(F:GetSettings().rules[1])
    local cases={
        {"any first",{matchMode=1},{[101]=Status(2,1000)},true},
        {"any last",{matchMode=1},{[102]=Status(2,1000)},true},
        {"any absent",{matchMode=1},{},false},
        {"all present",{matchMode=2},{[101]=Status(2,1000),[102]=Status(2,1000)},true},
        {"all missing",{matchMode=2},{[101]=Status(2,1000)},false},
        {"stack low",{minStacks=3},{[101]=Status(2,1000)},false},
        {"stack boundary",{minStacks=2},{[101]=Status(2,1000)},true},
        {"remaining low",{minRemainingMs=1001},{[101]=Status(2,1000)},false},
        {"remaining boundary",{minRemainingMs=1000},{[101]=Status(2,1000)},true},
        {"unknown accepted",{unknownRemainingValid=true},{[101]=Status(2,nil)},true},
        {"unknown rejected",{unknownRemainingValid=false},{[101]=Status(2,nil)},false},
        {"wrong source",{sourceMode=2},{[101]=Status(2,1000,1)},false},
        {"debuff source",{sourceMode=2},{[101]=Status(2,1000,2)},true},
        {"hidden source",{sourceMode=3},{[101]=Status(2,1000,4)},true},
        {"disabled",{enabled=false},{[101]=Status(2,1000)},false},
        {"empty ids",{ids={}},{[101]=Status(2,1000)},false},
        {"health gate",{healthRangeEnabled=true,healthMin=51},{[101]=Status(2,1000)},false},
        {"distance gate",{distanceMode=2,customDistance=9},{[101]=Status(2,1000)},false},
    }
    for _,case in ipairs(cases) do
        F.State.settings.rules={S.Utils.DeepCopy(template)}
        F.State.settings.rules={Rule(S,F,case[2])}
        local candidate=assert(D:Evaluate(Member(1),Health(50),case[3],{},1000))
        assert(candidate.hasProtection==case[4],case[1])
    end
end)

Test("ANY stops after the first valid ID while ALL still validates later IDs", function()
    local S,F,D=Boot(); local _,matches=Upvalue(D.Evaluate,"RuleMatches")
    local rule=Rule(S,F,{matchMode=1}); local reads=0
    local statuses=setmetatable({}, {__index=function(_,id)
        reads=reads+1
        if id==101 then return Status(1,1000) end
        return nil
    end})
    assert(matches(F:GetSettings(),rule,statuses,60,10) and reads==1)
    rule.matchMode=2; reads=0
    assert(not matches(F:GetSettings(),rule,statuses,60,10) and reads==2)
end)

Test("exclusion force rescue and display priority retain visible behavior", function()
    local S,F,D=Boot(); local member=Member(1); local statuses={[101]=Status(1,1000)}
    F.State.settings.rules={Rule(S,F,{name="exclude",effectType=3,excludeDisplayMode=2})}
    local candidate,unavailable=D:Evaluate(member,Health(60),statuses,{},1000)
    assert(candidate==nil and unavailable.reason=="exclude")
    F.State.settings.enterThreshold=50
    F.State.settings.rules={Rule(S,F,{name="rescue",effectType=4,rescuePriority=80,
        simpleDisplayGroup=true,displayPriority=90,color={r=0.1,g=0.2,b=0.3,a=0.4}})}
    candidate=assert(D:Evaluate(member,Health(85),statuses,{},1000))
    assert(candidate.forceEmergency and candidate.forcePriority==80 and candidate.colorReason=="rescue")
    assert(candidate.visualPriority==4 and candidate.color.r==0.1)
end)

Test("non candidate display priority and tie order retain detached colors", function()
    local S,F,D=Boot(); local member=Member(1)
    local first=Rule(S,F,{name="first",simpleDisplayGroup=true,displayPriority=10,color={r=0.1,g=0.2,b=0.3,a=0.4}})
    local second=Rule(S,F,{name="second",simpleDisplayGroup=true,displayPriority=20,color={r=0.7,g=0.8,b=0.9,a=1}})
    F.State.settings.rules={first,second}
    D.healthSnapshot[member.key]=Health(100)
    D.statusCache[member.key]={statuses={[101]=Status(1,1000)},scannedAt=1000}
    local projection=D:GetRaidDisplayProjection({member})
    assert(#projection.rows==1 and not projection.rows[1].isCandidate and projection.rows[1].colorReason=="second")
    assert(projection.rows[1].color~=second.color)
    projection.rows[1].color.r=-1
    assert(second.color.r==0.7 and D:GetRaidDisplayProjection({member}).rows[1].color.r==0.7)
    second.displayPriority=10
    assert(D:GetRaidDisplayProjection({member}).rows[1].colorReason=="first")
    D.statusCache[member.key]={statuses={},scannedAt=1100}
    assert(#D:GetRaidDisplayProjection({member},{proximityMode=false}).rows==0)
end)

Test("candidate colors isolate current output source and later readers", function()
    local S,F,D=Boot(); local member=Member(1)
    local candidate=assert(D:Evaluate(member,Health(50),{}, {},1000))
    D:Publish({[member.key]=Health(50)},{candidate},{},{},{})
    local one=D:GetRaidDisplayProjection({member}); local two=D:GetRaidDisplayProjection({member})
    assert(one.rows[1].color~=candidate.color and one.rows[1].color~=two.rows[1].color)
    one.rows[1].color.r=-1
    assert(candidate.color.r>=0 and two.rows[1].color.r>=0)
    candidate.color.r=0.25
    assert(two.rows[1].color.r~=0.25 and D:GetRaidDisplayProjection({member}).rows[1].color.r==0.25)
end)

local function RuntimeModel()
    local S,F,D=Boot(); local member=Member(1); local tasks={}
    F.Roster={GetSnapshot=function() return {members={S.Utils.DeepCopy(member)}} end,
        SyncFromShared=function() return true end,IsReady=function() return true end,
        RefreshRolesIfDue=function() return false end}
    S.Scheduler={AddTask=function(_,name,_,callback) tasks[name]=callback; return true end,
        RemoveTask=function(_,name) tasks[name]=nil end}
    X2Unit={}
    S.Api={CallCapability=function(_,_,_,method)
        if method=="UnitHealth" then return true,400 end
        if method=="UnitMaxHealth" then return true,1000 end
        if method=="UnitDistance" then return true,10 end
        error("unexpected native read "..tostring(method))
    end}
    local model={partial=true}
    S.Features.HealerAuraBridge={ReadAccurate=function()
        if model.partial then return nil,{available=true,complete=false,reliable=false},"partial aura" end
        return {[25875]=Status(1,1000)},{available=true,complete=true,reliable=true,scannedAt=2000,source="aura_v3"}
    end}
    dofile("features/combat/healer/rs_healer_health_v3.lua")
    return S,F,D,F.HealthRuntime,member,model,tasks
end

Test("unknown partial aura cannot become missing protection", function()
    local S,F,D,H,member=RuntimeModel()
    local known={statuses={[25875]=Status(1,1000)},scannedAt=10}
    D.statusCache[member.key]=known
    H:StartStatusCycle(1000); assert(H:RunStatusSlice())
    assert(D:GetStatusRow(member.key)==known,"partial generation replaced last accurate facts")
    H:StartHealthCycle(1000); assert(H:RunHealthSlice())
    assert(#D.recommendations==0 and #D.unavailable==1)
    assert(D.unavailable[1].reason=="状态读取暂不可用")
end)

Test("runtime stop and restart release derived state and rebuild accurate facts", function()
    local S,F,D,H,member,model,tasks=RuntimeModel(); model.partial=false
    assert(H:Start("test")); assert(tasks[H.taskName])
    H:StartStatusCycle(2000); assert(H:RunStatusSlice())
    H:StartHealthCycle(2000); assert(H:RunHealthSlice())
    assert(#D.recommendations==1 and D.recommendations[1].hasProtection)
    local prior=D:GetRaidDisplayProjection({member})
    assert(H:Stop("test")); assert(tasks[H.taskName]==nil and #D.recommendations==0)
    assert(next(D.statusCache)==nil and next(D.healthSnapshot)==nil)
    assert(H:Start("test_restart")); H:StartStatusCycle(3000); assert(H:RunStatusSlice())
    H:StartHealthCycle(3000); assert(H:RunHealthSlice())
    assert(#D.recommendations==1 and prior.rows[1].color~=D:GetRaidDisplayProjection({member}).rows[1].color)
    assert(H:Stop("test_done"))
end)

print(string.format("HEALER RULE RESULT %d passed / %d failed",passed,failed))
if failed>0 then os.exit(1) end

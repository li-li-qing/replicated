------------------------------------------------------------------------
-- Replicated Suite · 治疗名单快照性能回归
-- 真实 Lua 5.1 Store/Roster/Recommendation/Feature/Presenter + 既有 Native 宿主。
-- 仅验证操作数量、快照隔离与显示契约；不证明 RU 帧率，不进入 toc.g。
------------------------------------------------------------------------
local passed, failed = 0, 0
local function Test(name, callback)
    local ok, err = xpcall(callback, debug.traceback)
    if ok then passed=passed+1; print("PASS healer-roster " .. name)
    else failed=failed+1; print("FAIL healer-roster " .. name .. ": " .. tostring(err)) end
end

local Host = dofile("tools/rs_gear_page_test_host.lua")
local function Boot(count)
    local h=Host({width=1280,height=768}); h.page:OnDeactivated()
    local S=h.S
    UIParent=h.Native(nil,"healer_roster_ui_parent",0,0,1280,768)
    S.UI.TrySetUILayer=function() return true end
    dofile("core/rs_demand.lua")
    for _, path in ipairs({
        "features/combat/healer/rs_healer_store.lua",
        "features/combat/healer/rs_healer_roster_v3.lua",
        "features/combat/healer/rs_healer_recommendation_v3.lua",
        "features/combat/healer/rs_healer_feature.lua",
    }) do dofile(path) end
    local F=S.Features.Healer; assert(F:EnsureStoreLoaded())
    local R,D=F.Roster,F.Recommendation
    for i=1,(count or 100) do
        local member={key="member:"..i,name="Member "..i,unitToken="team_"..i,
            teamIndex=math.floor((i-1)/50)+1,memberIndex=((i-1)%50)+1,isSelf=i==1,role=1}
        R.members[i]=member; R.byKey[member.key]=member
        D.healthSnapshot[member.key]={currentHealth=500,maxHealth=1000,healthPercent=50,distance=10}
        if i<=10 then D.recommendations[i]={key=member.key,rank=i,color={r=1,g=0,b=0,a=0.7}} end
    end
    R.revision=1; D.revision=1
    dofile("presentation/v3/widgets/rs_v3_healer_raid_overlay.lua")
    local P=S.UIV3.HealerRaidOverlay
    F.State.presentation.raid.mode="dual"
    P.settings=F:GetPresentationProjection("raid")
    P.bindings=F:GetEffectivePanelBindings()
    assert(P:EnsurePanels(P.bindings)); P.running=true
    local snapshot=R.GetSnapshot
    h.snapshots,h.memberRowCopies=0,0
    R.GetSnapshot=function(self,...)
        h.snapshots=h.snapshots+1; h.memberRowCopies=h.memberRowCopies+#self.members
        return snapshot(self,...)
    end
    return h,S,F,P,R,D
end

Test("one 100-member refresh copies the roster once", function()
    local h,S,F,P=Boot(100)
    assert(P:RefreshProjection())
    assert(h.snapshots==1,"expected 1 current roster snapshot, got "..h.snapshots)
    assert(h.memberRowCopies==100,"duplicated member copies: "..h.memberRowCopies)
    assert(P.rosterCount==100 and #P.displayRows==100 and #P.candidates==10)
end)

Test("primary projection shape stays unchanged and public snapshots are detached", function()
    local h,S,F,P,R=Boot(100)
    local projection,roster=F:GetRaidOverlayProjection()
    local expected={revision=true,rosterCount=true,candidateCount=true,rows=true}; local keys=0
    for key in pairs(projection) do assert(expected[key],"new primary projection field "..key); keys=keys+1 end
    assert(keys==4 and projection.rosterCount==100 and projection.candidateCount==10)
    assert(type(roster)=="table" and roster.members~=R.members and roster.members[1]~=R.members[1])
    roster.members[1].name="caller mutation"; roster.members[1].memberIndex=49
    projection.rows[1].color.r=-1; projection.rows[1].key="caller mutation"
    assert(R.members[1].name=="Member 1" and R.members[1].memberIndex==1)
    local fresh,freshRoster=F:GetRaidOverlayProjection()
    assert(fresh.rows[1].key=="member:1" and fresh.rows[1].color.r==1)
    assert(freshRoster.members[1].name=="Member 1" and freshRoster.members[1].memberIndex==1)
end)

Test("slot movement and member removal are visible on the next refresh", function()
    local h,S,F,P,R=Boot(100); assert(P:RefreshProjection())
    assert(P.selfSlot.id=="A" and P.selfSlot.index==1)
    R.members[1].memberIndex=31; R.revision=R.revision+1
    assert(P:RefreshProjection()); assert(P.selfSlot.id=="A" and P.selfSlot.index==31)
    assert(not P.panels.A.slots[1].shown and P.panels.A.slots[31].shown)
    table.remove(R.members,1); R.revision=R.revision+1
    assert(P:RefreshProjection()); assert(P.selfSlot==nil and P.rosterCount==99)
end)

Test("absent Recommendation retains current detached roster and empty rows", function()
    local h,S,F,P,R=Boot(100); F.Recommendation=nil
    local projection,roster=F:GetRaidOverlayProjection()
    assert(#projection.rows==0 and projection.rosterCount==100 and projection.candidateCount==0)
    assert(type(roster)=="table" and roster.count==100 and roster.members~=R.members)
    h.snapshots=0; assert(P:RefreshProjection()); assert(h.snapshots==1)
    assert(#P.displayRows==0 and #P.candidates==0 and P.activePanels.A and P.activePanels.B)
end)

Test("legacy primary-only facade falls back to a current detached roster", function()
    local h,S,F,P=Boot(100); local get=F.GetRaidOverlayProjection
    F.GetRaidOverlayProjection=function(self) local projection=get(self); return projection end
    assert(P:RefreshProjection())
    assert(h.snapshots==2 and P.activePanels.A and P.activePanels.B and P.rosterCount==100)
    assert(P.selfSlot.id=="A" and P.selfSlot.index==1)
end)

Test("stopped overlay does not request projections or copy members", function()
    local h,S,F,P=Boot(100); P.running=false
    assert(P:RefreshProjection()==false and h.snapshots==0 and h.memberRowCopies==0)
end)

Test("empty current roster clears old rows ranks slots and panel activity", function()
    local h,S,F,P,R=Boot(100); assert(P:RefreshProjection())
    R.members={}; R.byKey={}; R.revision=R.revision+1; h.snapshots=0
    assert(P:RefreshProjection()); assert(h.snapshots==1)
    assert(P.rosterCount==0 and #P.displayRows==0 and #P.candidates==0 and P.selfSlot==nil)
    assert(next(P.activePanels)==nil)
    for _,panel in pairs(P.panels) do
        assert(not panel.window.shown)
        for i=1,50 do assert(not panel.slots[i].shown and not panel.ranks[i].shown) end
    end
end)

Test("source mutations do not alter returned snapshots or current displayed facts", function()
    local h,S,F,P,R,D=Boot(100); assert(P:RefreshProjection())
    local projection,roster=F:GetRaidOverlayProjection()
    R.members[1].name="New name"; R.members[1].memberIndex=31
    D.recommendations[1].color.r=0.25
    assert(roster.members[1].name=="Member 1" and roster.members[1].memberIndex==1)
    assert(projection.rows[1].color.r==1 and P.displayRows[1].color.r==1)
    assert(P:RefreshProjection()); assert(P.displayRows[1].color.r==0.25 and P.selfSlot.index==31)
end)

Test("nested reads cannot share or poison another caller's temporary snapshot", function()
    local h,S,F,P,R,D=Boot(100)
    local get=D.GetRaidDisplayProjection; local inside=false; local nestedRoster
    D.GetRaidDisplayProjection=function(self,...)
        if not inside then
            inside=true
            local nested; nested,nestedRoster=F:GetRaidOverlayProjection()
            nestedRoster.members[1].memberIndex=49; nested.rows[1].color.r=-1
            inside=false
        end
        return get(self,...)
    end
    local projection,roster=F:GetRaidOverlayProjection()
    assert(h.snapshots==2 and roster~=nestedRoster and roster.members~=nestedRoster.members)
    assert(roster.members[1].memberIndex==1 and projection.rows[1].color.r==1)
    assert(R.members[1].memberIndex==1 and D.recommendations[1].color.r==1)
end)

Test("every publication still performs layout and can retry a rejected anchor", function()
    local h,S,F,P=Boot(100); local layouts,anchors=0,0
    local layout=P.LayoutAll; P.LayoutAll=function(self,...) layouts=layouts+1; return layout(self,...) end
    local anchor=S.UI.SetAnchor; local reject=true
    S.UI.SetAnchor=function(self,...) anchors=anchors+1; if reject then return false end; return anchor(self,...) end
    assert(P:RefreshProjection()); local before=anchors; reject=false
    assert(P:RefreshProjection()); assert(layouts==2 and anchors>before)
    assert(P.panels.A.window.x==0 and P.panels.B.window.x==360)
end)

print(string.format("HEALER ROSTER RESULT %d passed / %d failed",passed,failed))
if failed>0 then os.exit(1) end

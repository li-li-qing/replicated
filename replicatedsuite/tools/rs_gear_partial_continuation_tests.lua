------------------------------------------------------------------------
-- 2026-09-30 gear-partial-continuation-1: real GearV3 transaction tests.
-- Only Native gear/bag/title, time and scheduler are boundary substitutes.
-- No loadout is saved and no game equipment is touched by this offline suite.
------------------------------------------------------------------------
unpack = unpack or table.unpack
local passed, total = 0, 0
local function Test(name, fn)
    total = total + 1
    local ok, err = xpcall(fn, debug.traceback)
    if ok then passed = passed + 1; print('PASS ' .. name)
    else print('FAIL ' .. name .. ': ' .. tostring(err)) end
end
local function Eq(a,b,label) assert(a==b,(label or 'value')..': expected='..tostring(b)..', actual='..tostring(a)) end
local function Copy(v)
    if type(v)~='table' then return v end
    local out={};for k,x in pairs(v) do out[k]=Copy(x) end;return out
end
local function Boot()
    local h={now=1000,bag={},equipped={},calls={},readErrors={},equipReadErrors={},reject={},throw={},noApply={},events={},tasks={}}
    local S={BootError=nil,Services={},Utils={DeepCopy=Copy,Trim=function(v)return tostring(v or ''):match('^%s*(.-)%s*$') end},Api={},Events={},Scheduler={}}
    ReplicatedSuite=S
    S.NowMs=function()return h.now end
    function S.Events:Publish(topic,reason) h.events[#h.events+1]={topic,reason} end
    function S.Scheduler:SetTaskModule()return true end
    function S.Scheduler:AddTask(id,interval,fn) h.tasks[id]=fn;return true end
    function S.Scheduler:RemoveTask(id) h.tasks[id]=nil;return true end
    function S.Api:IsCapabilityAllowed()return true end
    function S.Api:CallCapability(_,obj,method,...)
        if not obj or type(obj[method])~='function' then return false,nil,'unavailable:'..method end
        local ok,a,b,c=pcall(obj[method],obj,...)
        if not ok then return false,nil,tostring(a) end
        return true,a,nil,b,c
    end
    X2Bag={}
    function X2Bag:Capacity()return 12 end
    function X2Bag:GetBagItemInfo(_,slot)
        if h.readErrors[slot] then error('unreadable_bag_'..slot) end
        return Copy(h.bag[slot])
    end
    function X2Bag:EquipBagItem(slot,alternate)
        local item=h.bag[slot]
        h.calls[#h.calls+1]={slot=slot,itemType=item and item.itemType,alternate=alternate}
        if h.throw[slot] then error('equip_exception_'..slot) end
        if h.reject[slot] or not item then return false end
        if not h.noApply[slot] then
            local old=h.equipped[item.equipSlot]
            h.equipped[item.equipSlot],h.bag[slot]=Copy(item),Copy(old)
        end
        if h.afterAction then h:afterAction(slot) end
        return true
    end
    X2Equipment={}
    function X2Equipment:GetEquippedItemTooltipInfo(slot,own)
        Eq(own,true,'loadout selector')
        if h.equipReadErrors[slot] then error('unreadable_equipped_'..slot) end
        return Copy(h.equipped[slot])
    end
    h.effect,h.showing=10,7
    X2Player={}
    function X2Player:PlayerInCombat()
        if h.combatError then error('combat_unknown') end
        return h.inCombat==true
    end
    function X2Player:GetShowingAppellation()return {h.showing,'name'} end
    function X2Player:GetEffectAppellation()return {h.effect,'effect'} end
    function X2Player:ChangeAppellation(show,effect)
        Eq(show,h.showing,'preserve current title name')
        h.titleCalls=(h.titleCalls or 0)+1
        if h.titleReject then return false end
        h.effect=effect;return true
    end
    dofile('services/rs_gear_service_v3.lua')
    h.S,h.G=S,S.Services.GearV3;h.G:SetEnabled(true)
    h.payload={configured=true,items={},title={apply=true,effect={id=20,name='target effect'},showing={id=999}}}
    function h:add(slot,physical,name)
        local wanted={slot=slot,slotName='slot'..slot,name=name or ('target'..slot),grade=5,itemType=1000+slot,modifierSignature='',managed=true,empty=false}
        self.payload.items[#self.payload.items+1]=wanted
        self.bag[physical]={name=wanted.name,itemGrade=5,itemType=wanted.itemType,equipSlot=slot}
        self.equipped[slot]={name='old'..slot,itemGrade=5,itemType=2000+slot,equipSlot=slot}
        return wanted
    end
    h:add(16,1);h:add(1,2);h:add(28,3)
    function h:tick()self.now=self.now+220;self.G:RuntimeTick()end
    function h:run()
        for _=1,180 do if not self.G.runtime.busy then break end;self:tick() end
        Eq(self.G.runtime.busy,false,'bounded transaction completion')
        Eq(self.tasks[self.G.taskName],nil,'lane released')
    end
    function h:start() local ok,err=self.G:Start('test',self.payload);assert(ok,err);return self end
    function h:count(itemType) local n=0;for _,c in ipairs(self.calls)do if c.itemType==itemType then n=n+1 end end;return n end
    function h:partial(code)
        local snap=self.G:GetRuntimeSnapshot()
        Eq(snap.outcome,'partial','honest partial outcome');Eq(snap.skippedCount,1,'one skipped item')
        Eq(snap.skipped[1].code,code,'exact skip reason');Eq(self.effect,20,'title reached')
        Eq(self.equipped[28].itemType,1028,'costume reached')
        return snap
    end
    return h
end
Test('ambiguous armor does not block weapon costume or title',function()
    local h=Boot()
    h.bag[2].evolvingInfo={modifier={{name='strength',value=10}}}
    h.bag[4]=Copy(h.bag[2]);h.bag[4].evolvingInfo.modifier[1].value=20
    h:start():run();h:partial('ambiguous');Eq(h:count(1001),0,'do not guess armor');Eq(h.calls[1].itemType,1016,'weapons first')
end)
Test('unreadable missing armor is skipped with error evidence',function()
    local h=Boot();h.bag[2]=nil;h.readErrors[2]=true
    h:start():run();local snap=h:partial('read_error');assert(snap.skipped[1].reason:find('读取',1,true))
end)
Test('ordinary missing armor still allows the rest',function()
    local h=Boot();h.bag[2]=nil;h:start():run();h:partial('not_found')
end)
Test('native false skips only current item without blind retries',function()
    local h=Boot();h.reject[2]=true;h:start():run();h:partial('action_rejected');Eq(h:count(1001),1)
end)
Test('native exception skips current item and continues',function()
    local h=Boot();h.throw[2]=true;h:start():run();h:partial('action_error');Eq(h:count(1001),1)
end)
Test('verification exhausted stays bounded and reaches costume',function()
    local h=Boot();h.noApply[2]=true;h:start():run();h:partial('verify_failed');Eq(h:count(1001),3,'bounded retry limit')
end)
Test('equipment getter failure is not permission to equip unknown slot',function()
    local h=Boot();h.equipReadErrors[1]=true;h:start():run();h:partial('equipped_read_error');Eq(h:count(1001),0)
end)
Test('bag moves after preflight re-resolve before action',function()
    local h=Boot();h:start();h.bag[5],h.bag[2]=h.bag[2],{name='unrelated',itemGrade=5,itemType=9009,equipSlot=1}
    h:run();Eq(h.equipped[1].itemType,1001);Eq(h:count(9009),0,'never equip stale physical slot');Eq(h.G:GetRuntimeSnapshot().outcome,'complete')
end)
Test('item disappears after preflight is skipped not invoked',function()
    local h=Boot();h:start();h.bag[2]=nil;h:run();h:partial('not_found');Eq(#h.calls,2)
end)
Test('ambiguous replacement after preflight is skipped',function()
    local h=Boot();h:start();h.bag[5],h.bag[6]=Copy(h.bag[2]),Copy(h.bag[2]);h.bag[2]=nil
    h.bag[5].evolvingInfo={modifier={{name='power',value=1}}};h.bag[6].evolvingInfo={modifier={{name='power',value=2}}}
    h:run();h:partial('ambiguous');Eq(h:count(1001),0)
end)
Test('combat state lost is a global safety stop not per-item skip',function()
    local h=Boot();h:start();h.combatError=true;h:tick()
    Eq(h.G.runtime.busy,false);Eq(h.G.runtime.stage,'FAILED');Eq(#h.calls,0);Eq(h.tasks[h.G.taskName],nil)
end)
Test('global timeout still stops the transaction',function()
    local h=Boot();h:start();h.now=h.now+61000;h:tick();Eq(h.G.runtime.stage,'FAILED');Eq(#h.calls,0)
end)
Test('manual cancellation removes lane and cannot continue',function()
    local h=Boot();h:start();h.G:StopRuntime('user cancel');h:tick();Eq(#h.calls,0);Eq(h.tasks[h.G.taskName],nil)
end)
Test('all items unidentifiable no title never reports completed',function()
    local h=Boot();h.bag={};h.payload.title.apply=false
    local ok=h.G:Start('none',h.payload);Eq(ok,false);Eq(h.G.runtime.busy,false);Eq(#h.calls,0);Eq(h.tasks[h.G.taskName],nil)
end)
Test('skip evidence survives completion and snapshots are detached',function()
    local h=Boot();h.reject[2]=true;h:start():run();local snap=h:partial('action_rejected')
    snap.skipped[1].code='tampered';Eq(h.G:GetRuntimeSnapshot().skipped[1].code,'action_rejected')
    h.reject[2]=nil;h:start():run();Eq(h.G:GetRuntimeSnapshot().skippedCount,0);Eq(h.G:GetRuntimeSnapshot().outcome,'complete')
end)
Test('title remains reachable when all gear identification fails',function()
    local h=Boot();h.bag={};h.readErrors[1]=true;h:start():run()
    Eq(h.effect,20);Eq(#h.calls,0);Eq(h.G:GetRuntimeSnapshot().outcome,'partial');Eq(h.G:GetRuntimeSnapshot().skippedCount,3)
end)
Test('title false is not a successful action',function()
    local h=Boot();h.titleReject=true;local ok,reason=h.G:ApplyTitle(h.payload)
    Eq(ok,false);assert(tostring(reason):find('rejected',1,true));Eq(h.effect,10)
end)
Test('combat mode only touches weapon and does not attempt title',function()
    local h=Boot();h.inCombat=true;h:start():run();Eq(#h.calls,1);Eq(h.calls[1].itemType,1016);Eq(h.effect,10)
end)
Test('same two ring copies remain independently equipable',function()
    local h=Boot();h.payload.items={};h.bag={};h.equipped={};h.payload.title.apply=false
    h:add(12,1,'ring');local second=h:add(13,2,'ring');second.itemType=1012;second.alternative=true;h.bag[2].itemType=1012
    h:start():run();Eq(#h.calls,2);Eq(h.calls[2].alternate,true);Eq(h.G:GetRuntimeSnapshot().outcome,'complete')
end)
Test('same name but conflicting stable ItemID is not silently equipped',function()
    local h=Boot();h:start();h.bag[2].itemType=9009
    h:run();h:partial('not_found');Eq(h:count(9009),0)
end)
Test('same equipped name but conflicting ItemID is not already matched',function()
    local h=Boot();h.equipped[1].name=h.bag[2].name
    h:start():run();Eq(h.equipped[1].itemType,1001);Eq(h:count(1001),1)
end)
Test('legacy saved loadout without ItemID still uses its exact name grade fingerprint',function()
    local h=Boot();for _,saved in ipairs(h.payload.items)do saved.itemType=nil end
    h:start():run();Eq(h.G:GetRuntimeSnapshot().outcome,'complete');Eq(#h.calls,3)
end)
print(string.format('GEAR_PARTIAL_CONTINUATION: %d/%d passed (%s)',passed,total,_VERSION))
assert(passed==total,'gear continuation regression failures')

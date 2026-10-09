-- 中文维护（2026-10-09）：真实 Gear 捕获/候选/事务/Store/UI；Native 为可控替身，不代表 RU 大象戒指实机词条已验证。
local passed, failed = 0, 0
local function Test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then passed=passed+1; print('PASS gear-ring '..name) else failed=failed+1; print('FAIL gear-ring '..name..': '..tostring(err)) end
end
local function Copy(v) if type(v)~='table' then return v end; local r={};for k,x in pairs(v)do r[k]=Copy(x)end;return r end
local function Ring(value)
    return {name='充盈的拉玛哈的戒指',itemType=48559,itemGrade=5,evolvingInfo={modifier={{name='力量',value=value},{name='体质',value=20}}}}
end
local function Boot()
    local h={equipped={},bag={},calls={},tasks={},now=1000}
    ReplicatedSuite={Services={},Utils={DeepCopy=Copy,Trim=function(v)return tostring(v or ''):match('^%s*(.-)%s*$')end},Api={},Events={},Scheduler={}}
    local S=ReplicatedSuite;S.NowMs=function()return h.now end
    S.Events.Publish=function()return true end
    S.Scheduler.AddTask=function(_,id,_,fn)h.tasks[id]=fn;return true end
    S.Scheduler.RemoveTask=function(_,id)h.tasks[id]=nil;return true end
    S.Scheduler.SetTaskModule=function()return true end
    S.Api.IsCapabilityAllowed=function()return true end
    S.Api.CallCapability=function(_,_,object,method,...)
        local ok,a,b=pcall(object[method],object,...);if not ok then return false,nil,tostring(a)end
        return true,a,nil,b
    end
    X2Equipment={GetEquippedItemTooltipInfo=function(_,slot,own)assert(own==true);return Copy(h.equipped[slot])end}
    X2Bag={Capacity=function()return 12 end,GetBagItemInfo=function(_,_,slot)return Copy(h.bag[slot])end}
    X2Bag.EquipBagItem=function(_,slot,alternate)
        local item=h.bag[slot];h.calls[#h.calls+1]={slot=slot,alternate=alternate,item=Copy(item)}
        if not item then return false end
        local target=item.equipSlot or (alternate and 13 or 12)
        h.bag[slot],h.equipped[target]=Copy(h.equipped[target]),Copy(item)
        if h.afterAction then h.afterAction(target)end
        return true
    end
    X2Player={PlayerInCombat=function()return false end,GetShowingAppellation=function()return {1,'称号'}end,GetEffectAppellation=function()return {1,'称号'}end}
    dofile('services/rs_gear_service_v3.lua');h.G=S.Services.GearV3;h.G:SetEnabled(true)
    function h:capture()
        local payload,err=self.G:CapturePayload();assert(payload,err);payload.title.apply=false
        self.payload=payload;self.saved={};for _,item in ipairs(payload.items)do self.saved[item.slot]=item end
        return payload
    end
    function h:run()
        local ok,err=self.G:Start('rings',self.payload);assert(ok,err)
        for _=1,100 do if not self.G.runtime.busy then break end;self.now=self.now+220;self.G:RuntimeTick()end
        assert(not self.G.runtime.busy and self.tasks[self.G.taskName]==nil,'transaction did not release')
    end
    return h
end
Test('missing current modifiers cannot satisfy a saved ring',function()
    local h=Boot();h.equipped[12]=Ring(10);h:capture()
    local current=Ring(10);current.evolvingInfo=nil
    assert(not h.G:SavedItemMatchesTooltip(h.saved[12],current),'unknown current attributes accepted')
end)
Test('ring capture records readable attributes and canonical reordered numeric values',function()
    local h=Boot();h.equipped[12]=Ring(10);h:capture()
    local id=h.saved[12].ringIdentity;assert(id and id.version==1 and id.status=='known' and id.summary:find('力量',1,true))
    local same=Ring('10.0');same.evolvingInfo.modifier={same.evolvingInfo.modifier[2],same.evolvingInfo.modifier[1]}
    assert(h.G:SavedItemMatchesTooltip(h.saved[12],same),'attribute order or numeric presentation changed identity')
    assert(not h.G:SavedItemMatchesTooltip(h.saved[12],Ring(11)))
end)
Test('unknown capture is honest and does not change ordinary equipment matching',function()
    local h=Boot();h.equipped[12]=Ring(10);h.equipped[12].evolvingInfo=nil;h:capture()
    assert(h.saved[12].ringIdentity.status=='unknown' and h.saved[12].ringIdentity.reason~='')
    assert(not h.G:SavedItemMatchesTooltip(h.saved[12],h.equipped[12]))
    local armor={slot=1,name='胸甲',grade=5,modifierSignature='strength=10'}
    assert(h.G:SavedItemMatchesTooltip(armor,{name='胸甲',itemGrade=5}),'ring policy affected ordinary armor')
end)
Test('legacy ring cannot silently choose a same-name copy',function()
    local h=Boot();local old={slot=12,name='充盈的拉玛哈的戒指',itemType=48559,grade=5,modifierSignature=''}
    local candidate,reason,code=h.G:FindCandidate(old,{items={h.G:BuildBagCandidate(1,1,Ring(10))}}, {})
    assert(candidate==nil and code=='ring_recapture_required' and reason:find('重新',1,true))
end)
Test('two owned single-wear rings select the saved attributes instead of the first copy',function()
    local h=Boot();h.equipped[12]=Ring(10);h:capture()
    h.equipped[12]=Ring(30);h.bag[1]=Ring(30);h.bag[2]=Ring(10)
    local session=h.G:BuildSession('rings',h.payload)
    assert(#session.queue==1 and #session.blocked==0 and session.queue[1].bagSlot==2,'ring picked by name or physical order')
    h:run();assert(h.G:GetRuntimeSnapshot().outcome=='complete' and #h.calls==1)
    assert(h.G:SavedItemMatchesTooltip(h.saved[12],h.equipped[12]))
end)
Test('indistinguishable bag rings remain ambiguous instead of picking first slot',function()
    local h=Boot();h.equipped[12]=Ring(10);h:capture()
    local candidate,_,code=h.G:FindCandidate(h.saved[12],{items={h.G:BuildBagCandidate(1,1,Ring(10)),h.G:BuildBagCandidate(1,2,Ring(10))}}, {})
    assert(candidate==nil and code=='ring_ambiguous')
end)
Test('partial malformed or sparse modifiers are unknown instead of a shortened signature',function()
    local h=Boot()
    for _,modifiers in ipairs({{{name='力量'}},{{name='力量',value=0/0}},{[1]={name='力量',value=10},[3]={name='体质',value=20}}})do
        h.equipped[12]=Ring(10);h.equipped[12].evolvingInfo.modifier=modifiers;h:capture()
        assert(h.saved[12].ringIdentity.status=='unknown','partial attribute list was accepted')
    end
end)
Test('action-time changed ring is rejected while reachable equipment still applies',function()
    local h=Boot();h.equipped[12]=Ring(10);h.equipped[1]={name='头盔',itemType=80001,itemGrade=5};h:capture()
    h.equipped={};h.bag[1]=Ring(10);h.bag[2]={name='头盔',itemType=80001,itemGrade=5,equipSlot=1}
    local ok,err=h.G:Start('rings',h.payload);assert(ok,err);h.bag[1]=Ring(30)
    for _=1,100 do if not h.G.runtime.busy then break end;h.now=h.now+220;h.G:RuntimeTick()end
    assert(#h.calls==1 and h.calls[1].slot==2 and h.G:GetRuntimeSnapshot().outcome=='partial')
end)
Test('equipment readback missing ring modifiers cannot report success or blindly retry',function()
    local h=Boot();h.equipped[12]=Ring(10);h:capture();h.equipped={};h.bag[1]=Ring(10)
    h.afterAction=function(slot)h.equipped[slot].evolvingInfo=nil end
    h:run();assert(h.G:GetRuntimeSnapshot().outcome=='partial' and #h.calls==1,'unknown readback became success or repeated equip')
end)
Test('ordinary rings without evolving attributes keep the original behavior',function()
    local h=Boot();local saved={slot=13,name='普通戒指',itemType=90001,grade=5,modifierSignature=''}
    assert(h.G:SavedItemMatchesTooltip(saved,{name='普通戒指',itemType=90001,itemGrade=5}))
end)
Test('unreadable same-name bag ring is reported instead of silently ignored',function()
    local h=Boot();h.equipped[12]=Ring(10);h:capture()
    local unknown=Ring(10);unknown.evolvingInfo=nil
    local candidate,reason,code=h.G:FindCandidate(h.saved[12],{items={h.G:BuildBagCandidate(1,1,unknown)}},{})
    assert(candidate==nil and code=='ring_identity_unknown' and reason:find('词条',1,true))
end)
Test('single-wear family cannot occupy both saved ring slots even when one is already matched',function()
    local h=Boot();h.equipped[12]=Ring(10);h:capture()
    local second=Copy(h.saved[12]);second.slot=13;second.slotName='戒指2';second.alternative=true
    second.ringIdentity=h.G:ExtractRingIdentity(Ring(30));h.payload.items[#h.payload.items+1]=second;h.bag[1]=Ring(30)
    local session=h.G:BuildSession('invalid',h.payload)
    assert(#session.queue==0 and #session.blocked==2 and session.blocked[1].code=='ring_unique_conflict')
    assert(h.G:ValidatePayload(h.payload)==false)
end)
Test('saved second ring slot replaces the correct single-wear copy using alternate equip',function()
    local h=Boot();h.equipped[13]=Ring(30);h:capture();h.equipped[13]=Ring(10);h.bag[1]=Ring(30)
    h:run();assert(#h.calls==1 and h.calls[1].alternate and h.G:GetRuntimeSnapshot().outcome=='complete')
end)
Test('real A B store journal preserves ring attributes through fresh reload and refuses failed save',function()
    local PageBoot=dofile('tools/rs_gear_page_test_host.lua');local h=PageBoot()
    X2Equipment.GetEquippedItemTooltipInfo=function(_,slot)if slot==12 then return Ring(10) end end
    local id=assert(h.F.Authority:CreateSet('戒指词条方案'));local draft=assert(h.F.Authority:CaptureDraft(id))
    assert(h.F:SaveDraft(draft));local read=assert(h.F:GetDraft(id));local saved
    for _,item in ipairs(read.items)do if item.slot==12 then saved=item end end
    assert(saved and saved.ringIdentity and saved.ringIdentity.status=='known','journal dropped ring identity')
    local signature=saved.ringIdentity.signature;h.failSave=true
    X2Equipment.GetEquippedItemTooltipInfo=function(_,slot)if slot==12 then return Ring(30) end end
    assert(h.F:SaveDraft(assert(h.F.Authority:CaptureDraft(id)))==false);h.failSave=false
    local fresh=PageBoot({disk=h.disk});local loaded=assert(fresh.F:GetDraft(id));local ring
    for _,item in ipairs(loaded.items)do if item.slot==12 then ring=item end end
    assert(ring and ring.ringIdentity.signature==signature and ring.ringIdentity.summary:find('力量',1,true))
    fresh.page.draft=loaded;fresh.page:RefreshEditor()
    local rows=fresh.page:BuildSlotRows();local row
    for _,item in ipairs(rows)do if item.slot==12 then row=item end end
    assert(row and row.modifierText:find('力量',1,true) and not row.modifierText:find('未记录',1,true))
    assert(fresh.widgets.v3_gear_ring_details.text:find('力量',1,true),'saved attributes invisible in real page')
end)
Test('legacy store payload still loads without fabricated ring identity or automatic rewrite',function()
    local PageBoot=dofile('tools/rs_gear_page_test_host.lua');local h=PageBoot()
    X2Equipment.GetEquippedItemTooltipInfo=function(_,slot)if slot==12 then return Ring(10) end end
    local id=assert(h.F.Authority:CreateSet('旧戒指方案'));local draft=assert(h.F.Authority:CaptureDraft(id))
    for _,item in ipairs(draft.items)do item.ringIdentity=nil end
    assert(h.F:SaveDraft(draft));local fresh=PageBoot({disk=h.disk});local writes=fresh.writes
    local loaded=assert(fresh.F:GetDraft(id));assert(fresh.writes==writes,'legacy read rewrote payload')
    for _,item in ipairs(loaded.items)do if item.slot==12 then assert(item.ringIdentity==nil and fresh.S.Services.GearV3:SavedRingIdentityError(item)) end end
end)
Test('unknown cached candidate for one ring cannot block a different ring in the shared snapshot',function()
    local h=Boot();h.equipped[12]=Ring(10)
    local ordinary=Ring(30);ordinary.name='另一种成长戒指';ordinary.itemType=90001;h.equipped[13]=ordinary;h:capture()
    local unknown=Ring(10);unknown.evolvingInfo=nil
    local snapshot={items={h.G:BuildBagCandidate(1,1,unknown),h.G:BuildBagCandidate(1,2,ordinary)}}
    assert(h.G:FindCandidate(h.saved[12],snapshot,{})==nil)
    local candidate,err=h.G:FindCandidate(h.saved[13],snapshot,{})
    assert(candidate and candidate.slot==2,err or 'unrelated unknown candidate poisoned other ring')
end)
Test('missing item type cannot downgrade captured or legacy rings to name-only matching',function()
    local h=Boot();local incomplete=Ring(10);incomplete.itemType=nil;incomplete.evolvingInfo=nil
    h.equipped[12]=incomplete;h:capture()
    assert(h.saved[12].ringIdentity and h.saved[12].ringIdentity.status=='unknown','capture disguised missing identity as ordinary ring')
    local snapshot={items={h.G:BuildBagCandidate(1,1,Ring(10)),h.G:BuildBagCandidate(1,2,Ring(30))}}
    local candidate,_,code=h.G:FindCandidate(h.saved[12],snapshot,{})
    assert(candidate==nil and code=='ring_identity_unknown')
    h.saved[12].ringIdentity=nil
    candidate,_,code=h.G:FindCandidate(h.saved[12],snapshot,{})
    assert(candidate==nil and code=='ring_recapture_required','legacy missing type selected a same-name ring')
end)
Test('numeric attribute identity retains native precision before string normalization',function()
    local h=Boot();local first,second=1,1.00000000000001
    assert(first~=second and tostring(first)==tostring(second),'fixture must expose Lua numeric tostring precision loss')
    local a,b=h.G:ExtractRingIdentity(Ring(first)),h.G:ExtractRingIdentity(Ring(second))
    assert(a.status=='known' and b.status=='known' and a.signature~=b.signature,'distinct native numeric attributes collapsed')
end)
Test('readback missing ring type or grade stops retries even with a matching bag candidate',function()
    for _,missing in ipairs({'itemType','itemGrade'})do
        local h=Boot();h.equipped[12]=Ring(10);h:capture();h.equipped={};h.bag[1]=Ring(10)
        h.afterAction=function(slot)h.equipped[slot][missing]=nil;h.bag[2]=Ring(10) end
        h:run();local result=h.G:GetRuntimeSnapshot()
        assert(result.outcome=='partial' and #h.calls==1,'missing identity allowed repeated equip or success')
        assert(result.skipped[1].code=='ring_identity_unknown','readback stopped for an unrelated reason')
    end
end)
print('GEAR RING RESULT '..passed..' passed / '..failed..' failed');if failed>0 then error('gear ring failures')end

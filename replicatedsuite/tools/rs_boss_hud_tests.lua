-- 中文维护：仅开发期回归，不进入 toc.g。被测链为真实 Casting/Alerts/Demand/Events/Store/Feature；
-- Native 施法、Aura 快照、磁盘和 Presenter 是可控替身；这些结果不等于 RU 客户端验收。
-- 每例新建 generation，覆盖逐条规则、耐久回读、同机制提示合并、计时与停止后迟到回调。
local passed, failed = 0, 0
local function Test(name, fn)
    local ok, err = pcall(fn)
    if ok then passed = passed + 1; print('PASS boss-alerts ' .. name)
    else failed = failed + 1; print('FAIL boss-alerts ' .. name .. ': ' .. tostring(err)) end
end
local H = dofile('tools/rs_udf_numeric_test_host.lua')
local function Boot(disk)
    local S, P, io = H.Boot(disk)
    local c = { now = 1000, casts = {}, reads = 0, shows = {}, updates = {}, hides = 0,
        debuffs = {}, complete = true, auraReads = 0, rejectShow = false }
    S.SafeTraceback = debug.traceback
    S.NowMs = function() return c.now end
    dofile('core/rs_events.lua'); dofile('core/rs_scheduler.lua')
    X2Unit = { UnitCastingInfo = function(_, scope)
        c.reads = c.reads + 1
        return H.Copy(c.casts[scope])
    end }
    local aura = {}
    aura.Demand = assert(S.Demand:Create({id = 'test:boss:aura', owner = aura}))
    function aura:AcquireConsumer(token, options) return self.Demand:Acquire(token, options) end
    function aura:ReleaseConsumer(token) return self.Demand:Release(token) end
    function aura:GetSnapshot()
        c.auraReads = c.auraReads + 1
        return { map = H.Copy(c.debuffs), complete = c.complete }
    end
    function aura:GetStatusMap(snapshot)
        return snapshot.map, { available = snapshot.complete, complete = snapshot.complete, reliable = snapshot.complete }
    end
    S.Services.AuraObservationV3 = aura
    dofile('services/rs_casting_observation_v3.lua')
    dofile('services/rs_alerts_service.lua')
    local A = S.Services.Alerts
    A:SetPresenter({ Show = function(_, text)
        if c.rejectShow then return false end
        c.shows[#c.shows + 1] = text; return true
    end, UpdateText = function(_, text) c.updates[#c.updates + 1] = text; return true end,
    Hide = function() c.hides = c.hides + 1; return true end })
    assert(A:Start())
    dofile('data/rs_boss_alerts.lua')
    local originalCatalog = H.Copy(S.Data.BossAlerts)
    dofile('features/rs_business_bridge.lua')
    local F = S.Features.combat_boss_alerts
    assert(F:Initialize()); assert(F:Enable())
    c.originalCatalog = originalCatalog
    function c:Cast(scope, current, total, name)
        self.casts[scope] = { spellName = name or 'Smash Earth', currCastingTime = current or 0, castingTime = total or 6000 }
    end
    function c:Step(ms)
        self.now = self.now + (ms or 100)
        S.Services.CastingObservationV3:Refresh('test')
        local task = S.Scheduler.tasks.v3_business_boss_alert_observe
        if task then task.callback() end
    end
    return S, F, c, P, io, A
end
local function Row(F, key)
    for _, row in ipairs(F:GetProjection().rows or {}) do if row.mechanicKey == key then return row end end
    error('missing rule ' .. key)
end
local function Set(F, key, enabled)
    assert(type(F.Commands.SetRuleEnabled) == 'function', 'missing SetRuleEnabled command')
    return F.Commands:SetRuleEnabled(key, enabled)
end

Test('countdown remains visible for entire observed cast not text timeout',function()
    local S,F,c,_,_,A=Boot();c:Cast('target',0,8000);c:Step();c.now=c.now+4000;A:Tick()
    assert(A.currentText~=nil,'8s cast was cut off at 3s');assert(A.labelLastText:match('4$'))
end)
Test('test countdown uses a visible six second sample',function()
    local S,F,c,_,_,A=Boot();assert(F.Commands:TestCountdown());assert(A.labelLastText:match('6$'),'test should start at six')
    c.now=c.now+5000;A:Tick();assert(A.currentText~=nil and A.labelLastText:match('1$'))
end)
Test('new alert repairs deleted timer rather than trusting boolean',function()
    local S,F,c,_,_,A=Boot();assert(F.Commands:TestCountdown());S.Scheduler:RemoveTask('alerts_tick')
    assert(F.Commands:TestCountdown());assert(S.Scheduler:GetTaskState('alerts_tick').registered,'orphaned tickTask flag')
end)
Test('active observer repairs missing countdown task without rearming deadline',function()
    local S,F,c,_,_,A=Boot();c:Cast('target',0,8000);c:Step();local finish=A.countdownEndsAt
    S.Scheduler:RemoveTask('alerts_tick');c:Cast('target',200,8000);c:Step(200)
    assert(S.Scheduler:GetTaskState('alerts_tick').registered,'observer left countdown frozen');assert(A.countdownEndsAt==finish)
end)
Test('unavailable unrelated scope cannot suppress a later known cast',function()
    local S,F,c,_,_,A=Boot();c.casts.watchtarget=false;c:Cast('target',0,6000);c:Step();local count=#c.shows
    c.casts.target={};c:Step();c:Cast('target',0,6000);c:Step()
    assert(#c.shows==count+1,'empty target gap could not end segment due to absent focus')
end)
Test('known interrupted cast is withdrawn by its own observed scope',function()
    local S,F,c,_,_,A=Boot();c.casts.watchtarget=false;c:Cast('target',0,8000);c:Step()
    c.casts.target={};c:Step();assert(A.currentText==nil,'known interrupted countdown left visible')
end)
Test('unlisted cast observation is explicit and never a future cooldown claim',function()
    local S,F,c,_,_,A=Boot();assert(F.Commands:SetShowObservedCasts(true))
    c:Cast('target',0,12000,'Unknown dragon cast');c:Step()
    assert(A.currentText=='读条：Unknown dragon cast','observed cast missing');assert(A.currentAlertKey=='observed:target')
end)
Test('unknown own cast never triggers observed target fallback',function()
    local S,F,c,_,_,A=Boot();assert(F.Commands:SetShowObservedCasts(true));c:Cast('player',0,12000,'Own skill');c:Step()
    assert(A.currentText==nil,'own generic skill polluted boss HUD')
end)
Test('unlisted casts cannot mask known mechanism',function()
    local S,F,c,_,_,A=Boot();assert(F.Commands:SetShowObservedCasts(true))
    c:Cast('target',0,8000,'Smash Earth');c:Cast('watchtarget',0,6000,'Unknown');c:Step()
    assert(A.currentAlertKey=='smash_earth','unlisted observation replaced mechanic')
end)
Test('observed cast disappears when responsible scope becomes idle',function()
    local S,F,c,_,_,A=Boot();assert(F.Commands:SetShowObservedCasts(true));c:Cast('target',0,8000,'Unknown');c:Step()
    c.casts.target={};c:Step();assert(A.currentText==nil,'interrupted observed cast remained on screen')
end)
Test('layout mutation is durable and reconfigures without restarting countdown',function()
    local S,F,c,P,io,A=Boot();local cfg
    A.presenter.ApplyLayout=function(_,v)cfg=v;return true end
    assert(F.Commands:TestCountdown());local deadline=A.countdownEndsAt
    local writes=io.writes;assert(F.Commands:SetHudOffsetX(-80));assert(io.writes>writes,'position not durable')
    assert(cfg and cfg.offsetX==-80,'live HUD layout not reapplied');assert(A.countdownEndsAt==deadline)
    assert(F:GetProjection().hudOffsetX==-80)
end)
Test('failed layout save leaves current layout and state unchanged',function()
    local S,F,c,P,io,A=Boot();local calls=0;A.presenter.ApplyLayout=function()calls=calls+1;return true end
    local old=P.MutateStore;P.MutateStore=function()return false,'blocked'end
    assert(not F.Commands:SetHudOffsetX(77));assert((F:GetProjection().hudOffsetX or 0)==0 and calls==0)
end)
Test('layout reset clears optional fields without replacing rule preferences',function()
    local S,F,c,P,io,A=Boot();assert(F.Commands:SetRuleEnabled('smash_earth',false))
    assert(F.Commands:SetHudOffsetX(-20));assert(F.Commands:SetHudWidth(900));assert(F.Commands:ResetHudLayout())
    assert(F.State.hudOffsetX==nil and F.State.hudWidth==nil);assert(F.State.items.smash_earth==false)
end)
Test('edit mode is ephemeral and disables on feature stop',function()
    local S,F,c,P,io,A=Boot();local edits={}
    A.presenter.EditLayout=function(_,on,cfg,commit)edits[#edits+1]=on;return true end
    local writes=io.writes;assert(F.Commands:SetHudEditing(true));assert(A.editOwnerKey==F.Id)
    assert(F:Disable());assert(A.editOwnerKey==nil and edits[#edits]==false);assert(io.writes==writes)
end)
-- Real scheduler driver + real Presenter. Native widgets/clock only are simulated;
-- unlike earlier tests, no direct Tick call is used for the following cases.
local function Driver()
    local h=dofile('tools/rs_gear_page_test_host.lua')({width=1280,height=768});local S=h.S
    h.page:OnDeactivated();UIParent=h.Native(nil,'UIParent',0,0,1280,768)
    S.PhysicalId=function(id)return id end
    S.NativeObjectFactory={CreateEmptyWidget=function(_,id)return h.Native(UIParent,id,0,0,1,1)end}
    S.Api.GetUiMetrics=function()return 1280,768,1,1280,768 end
    S.UI.TrySetUILayer=function()return true end
    -- Use native SetText/GetText boundary so failures cannot be hidden by the fixture.
    S.UI.SetText=function(_,widget,text)
        local ok,result=pcall(widget.SetText,widget,text);return ok and result~=false
    end
    S.AdvanceClock=function(ms)h.ms=h.ms+ms end
    dofile('services/rs_alerts_service.lua');dofile('presentation/v3/widgets/rs_v3_alert_hud.lua')
    assert(S.Scheduler:Start())
    function h:Pump(ms)for _=1,math.floor(ms/100)do S.Scheduler.driver.events.OnUpdate(S.Scheduler.driver,100)end end
    return h,S.Services.Alerts,S.UIV3.AlertHudV3
end
Test('real driver renders six five four three two one and releases task',function()
    local h,A,P=Driver();assert(A:Push({text='Timer',style='countdown',remainingMs=6000,durationMs=6000}))
    assert(P.label.text=='Timer  6')
    for i=5,1,-1 do h:Pump(1000);assert(P.label.text=='Timer  '..i,'driver did not advance to '..i)end
    h:Pump(1000);assert(not P.visible and not A.currentText and not A.tickTask)
end)
Test('real presenter rejects failed writes instead of caching success',function()
    local h,A,P=Driver();assert(A:Push({text='Timer',style='countdown',remainingMs=6000,durationMs=6000}))
    local set=P.label.SetText;P.label.SetText=function()return false end;h:Pump(1000)
    assert(A.labelLastText=='Timer  6','rejected 5s write was cached as shown')
    P.label.SetText=set;h:Pump(100);assert(P.label.text=='Timer  5','next tick did not repair display')
end)
Test('real presenter reports Show failure and does not leave timer',function()
    local h,A,P=Driver();assert(P:EnsureCreated());P.label.SetText=function()return false end
    local ok=A:Push({text='Rejected',style='countdown',remainingMs=6000,durationMs=6000})
    assert(ok==false and A.currentText==nil and A.tickTask==nil,'native rejection was reported as success')
end)
Test('HUD width and signed offsets use viewport logical coordinates',function()
    local h,A,P=Driver();assert(P:Show('Layout',{fontSize=34,width=500,offsetX=-80,offsetY=40,anchorMode='center'}))
    assert(P.root.width==500 and P.root.x==310 and P.root.y==270,'HUD ignored configured placement')
end)
Test('offscreen HUD clamps into viewport without rewriting saved config',function()
    local h,A,P=Driver();local cfg={width=700,offsetX=99999,offsetY=-99999};assert(P:Show('Layout',cfg))
    assert(P.root.x>=0 and P.root.x+P.root.width<=1280 and P.root.y>=0)
    assert(cfg.offsetX==99999,'Presenter mutated persisted settings')
end)
Test('alert telemetry exposes actual task runs and rendered text',function()
    local h,A,P=Driver();assert(A:Push({text='Timer',style='countdown',remainingMs=6000,durationMs=6000}));h:Pump(2000)
    local d=A:Describe();assert(d.task.registered and d.task.runCount>0 and d.ticks>0)
    assert(d.renderedText=='Timer  4' and d.lastTickAt>0 and d.presenter.patch=='boss-hud-clock-1')
end)

Test('rejected push after timer repair preserves previous alert expiry task',function()
    local S,F,c,_,_,A=Boot();assert(F.Commands:TestCountdown());local expires=A.expiresAt
    S.Scheduler:RemoveTask('alerts_tick');c.rejectShow=true
    assert(not F.Commands:TestBigText());assert(S.Scheduler:GetTaskState('alerts_tick').registered,'previous alert became immortal')
    c.now=expires+1;A:Tick();assert(A.currentText==nil)
end)
local function EditDriver()
    local h,A,P=Driver();local S=h.S
    S.UI.EnsureAlpha=function(_,n,v)n.alpha=v;return true,false end
    S.Layout={GetContext=function()return {logicalWidth=1280,logicalHeight=768,addonScale=1}end,
        GetLogicalRect=function(_,n)return n.x,n.y,n.width,n.height end}
    dofile('ui/framework/rs_ui_windowing.lua');assert(P:EnsureCreated())
    local root=P.root
    function root:EnableDrag(v)self.dragEnabled=v end
    function root:StartMoving()self.moving=true end
    function root:StopMovingOrSizing()self.moving=false end
    function root:GetOffset()return self.x,self.y end
    return h,A,P
end
Test('real Windowing drag commits offsets once and finish restores click through',function()
    local h,A,P=EditDriver();local saved,count=nil,0
    assert(A:SetLayoutEditor('test',true,{width=720},function(x,y,w)
        saved={offsetX=x,offsetY=y,width=w};count=count+1;return A:ConfigureOwner('test',saved)
    end))
    assert(P.root.pickable and P.root.events.OnDragStart);assert(P.root.events.OnDragStart())
    P.root.x,P.root.y=100,160;assert(P.root.events.OnDragStop())
    assert(count==1 and saved.offsetX==-180 and saved.offsetY==-70 and saved.width==720)
    assert(A:SetLayoutEditor('test',false));assert(not P.root.pickable and not P.editing and not P.visible)
    assert(P.root.events.OnDragStart==nil and h.S.RSUI.Windowing.bindings[P.owner]==nil)
end)
Test('rejected drag save restores last confirmed geometry',function()
    local h,A,P=EditDriver();assert(A:SetLayoutEditor('test',true,{width=720},function()return false,'disk rejected'end))
    assert(P.root.events.OnDragStart());P.root.x,P.root.y=100,160;P.root.events.OnDragStop()
    assert(P.root.x==280 and P.root.y==230 and P.lastError=='disk rejected')
    assert(A:SetLayoutEditor('test',false))
end)
Test('edit while countdown active does not freeze or reset seconds',function()
    local h,A,P=EditDriver();assert(A:Push({text='Timer',style='countdown',remainingMs=6000,durationMs=6000,ownerKey='test'}))
    local endAt=A.countdownEndsAt
    assert(A:SetLayoutEditor('test',true,{width=500},function()return true end));h:Pump(2000)
    assert(P.label.text=='Timer  4' and A.countdownEndsAt==endAt)
    assert(A:SetLayoutEditor('test',false));assert(P.visible and not P.root.pickable)
    h:Pump(4000);assert(not P.visible)
end)
Test('stopping during native drag releases mouse capture and preview',function()
    local h,A,P=EditDriver();assert(A:SetLayoutEditor('test',true,{},function()return true end))
    assert(P.root.events.OnDragStart());assert(P.root.moving);A:Stop()
    assert(not P.root.moving and not P.editing and not P.root.pickable and not P.visible)
end)
Test('new alert during native drag does not snap HUD back',function()
    local h,A,P=EditDriver();assert(A:SetLayoutEditor('test',true,{},function()return true end))
    assert(P.root.events.OnDragStart());P.root.x,P.root.y=100,160
    assert(A:Push({text='New cast',style='countdown',remainingMs=6000,durationMs=6000,ownerKey='test'}))
    assert(P.root.x==100 and P.root.y==160,'alert layout interrupted active native drag')
    A:Stop()
end)
Test('late callback from retired editor cannot commit next editor state',function()
    local h,A,P=EditDriver();local writes=0
    assert(A:SetLayoutEditor('test',true,{},function()writes=writes+1;return true end))
    local old=P.controller;assert(A:SetLayoutEditor('test',false))
    assert(A:SetLayoutEditor('test',true,{},function()writes=writes+1;return true end))
    local ok=old.onGeometryChanged(old,100,160);assert(ok==false and writes==0,'stale callback committed new settings')
    A:Stop()
end)
Test('saved signed layout and observed setting survive fresh load',function()
    local S,F,c,P,io,A=Boot();assert(F.Commands:SetHudOffsetX(-80));assert(F.Commands:SetHudOffsetY(40))
    assert(F.Commands:SetHudWidth(600));assert(F.Commands:SetShowObservedCasts(true))
    local S2,F2=Boot(io.disk);local state=F2:GetProjection()
    assert(state.hudOffsetX==-80 and state.hudOffsetY==40 and state.hudWidth==600 and state.showObservedCasts)
end)
Test('three rejected text updates remove misleading frozen label',function()
    local h,A,P=Driver();assert(A:Push({text='Timer',style='countdown',remainingMs=6000,durationMs=6000}))
    P.label.SetText=function()return false end;h:Pump(1300)
    assert(A.currentText==nil and not P.visible and A.presentationFailures>=3)
end)
print(string.format('BOSS_HUD_RESULT passed=%d failed=%d',passed,failed));assert(failed==0,'boss HUD regression failed')

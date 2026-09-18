-- 维护：回归必须经过实际任务与事件队列；连续事件不是测试中直接调用 EquipmentTick。
-- 显示位置用父链计算；Native纹理拒写是明确模型，不代替 RU 的渲染/网络时延测量。
local passed,failed=0,0
local function Test(name,fn)local ok,e=pcall(fn);if ok then passed=passed+1;print('PASS pvp-hud '..name)else failed=failed+1;print('FAIL pvp-hud '..name..': '..tostring(e))end end
local Boot=dofile('tools/rs_pvp_hud_test_host.lua')
Test('continuous aura events cannot erase or postpone weapon invalidation',function()
    local h,S,F=Boot({noRenderer=true});h.weapon='new-weapon.dds'
    h:Event('UNIT_EQUIPMENT_CHANGED')
    for i=1,8 do h:Event('BUFF_UPDATE');h:Step(10)end
    assert(F.laneData.player.mainHand.icon==h.weapon,'weapon still stale after uninterrupted event stream')
end)
Test('equipment and target events both survive the same coalescing window',function()
    local h,S,F=Boot({noRenderer=true});h.facts.target[8227]=h:Fact(8227);h.weapon='twohand.dds'
    h:Event('TARGET_CHANGED');h:Event('UNIT_EQUIPMENT_CHANGED');h:Event('BUFF_UPDATE')
    for i=1,6 do h:Step(10)end
    assert(F.laneData.player.mainHand.icon=='twohand.dds','equipment work overwritten')
    assert(F.laneData.target.targetLoadout.weapon.buffId==8227,'target read overwritten')
    assert(h.lastAuraForce==true,'event edge reused old snapshot')
end)
Test('target invalidation removes all previous identity facts before the next sample',function()
    local h,S,F=Boot({noRenderer=true})
    F.laneData.target.buffRows={{id=716}};F.laneData.target.cast={spellName='old'};F.laneData.target.gearScore=20000
    h:Event('TARGET_CHANGED')
    assert(F.laneData.target.cast==nil and F.laneData.target.gearScore==nil,'old target metadata retained')
    assert(not F.laneData.target.buffRows or #F.laneData.target.buffRows==0,'old target buffs retained')
end)
Test('equipment backstop stays under 200ms and P1, score lane remains bounded',function()
    local h,S,F=Boot({noRenderer=true});local t=S.Scheduler.tasks[F.lanes.equipment.task]
    assert(t.intervalMs<=200 and t.priority==1,'equipment drift backstop can be deprioritized')
end)
Test('motion samples use frame cadence and never rebuild content for position only',function()
    local h,S,F,P=Boot();local t=S.Scheduler.tasks[F.lanes.position.task]
    assert(t.lane=='highfrequency' and t.intervalMs==1 and t.priority==1,'motion waits 50ms/background budget')
    local p=P.metrics.projections;local scans=h.scans;local textures=h.textures
    for i=1,5 do h.points.player[1]=350+i;F:PositionTick()end
    assert(P.metrics.projections==p and h.scans==scans and h.textures==textures,'movement rebuilt data/texture projection')
end)
Test('moving plate writes one parent anchor per visible scope not every icon',function()
    local h,S,F,P=Boot();local before=h.anchors
    h.points.player[1]=370;h.points.target[1]=870;F:PositionTick()
    assert(h.anchors-before<=2,'each child is reanchored on every move')
    assert(P.pools.player.root and P.pools.target.root,'rigid plate root missing')
end)
Test('root movement cannot retint or reload unchanged weapon textures',function()
    local h,S,F,P=Boot();local p=P.pools.player;local chosen
    for _,m in ipairs(p.icons)do if m.root.shown then chosen=m;break end end
    assert(chosen);local x=h:World(chosen.root);local writes=h.textures
    h.points.player[1]=h.points.player[1]+30;F:PositionTick()
    assert(h:World(chosen.root)==x+30,'group did not follow unit exactly')
    assert(h.textures==writes,'motion reloaded textures')
end)
Test('texture rejection cannot cache the new item path as success',function()
    local h,S,F,P=Boot();h.rejectTexture='rejected.dds';h.weapon=h.rejectTexture;F:EquipmentTick();P:VisualTick()
    local seen=false
    for _,m in ipairs(P.pools.player.icons)do
        assert(not(m.root.shown and m.icon.texture=='old-weapon.dds'),'old weapon remains plausible after failed update')
        if m.iconPath=='rejected.dds' then seen=true end
    end
    assert(not seen,'failed texture was cached')
    h.rejectTexture=nil;P:VisualTick();local ok=false
    for _,m in ipairs(P.pools.player.icons)do if m.root.shown and m.icon.texture=='rejected.dds'then ok=true end end
    assert(ok,'texture update never retried')
end)
Test('class icon geometry consumes existing scope x y size alpha independently of text',function()
    local h,S,F,P=Boot();F.laneData.player.class={name='Role',icon='role.dds'}
    P:VisualTick();local info=P.pools.player.info;local textX,textY=h:World(info.root);local x,y=h:World(info.iconRoot)
    -- 维护（hud-default-template-2）：验证绝对赋值带来的相对位移，不把旧默认0当作初始坐标；
    -- 保留真实Renderer/位置/纹理链，尺寸和文字不移动断言不变。
    local c=F.State.settings.components.class;local oldX,oldY=c.x,c.y
    c.x=17;c.y=-9;c.size=24;c.alpha=.6;F:InvalidateSettingsCache();P:VisualTick()
    local nx,ny=h:World(info.iconRoot)
    assert(nx==x+17-oldX and ny==y-9-oldY,'icon ignores calibration offsets')
    assert(info.iconRoot.width==24 and info.iconRoot.alpha==.6,'icon ignores size/opacity')
    assert(h:World(info.root)==textX,'icon calibration moves text')
end)
Test('stop clears pending invalidations and cannot resurrect a swapped icon',function()
    local h,S,F,P=Boot();h:Event('UNIT_EQUIPMENT_CHANGED');assert(F:Disable('test'))
    assert(not S.Scheduler.tasks[F.eventTaskName],'event batch leaked')
    h:Step(100);assert(F.consumerCount==0,'consumer resurrected')
end)
Test('unavailable aura snapshot clears live weapon proof but never substitutes self equipment',function()
    local h,S,F,P=Boot();h.facts.target[8227]=h:Fact(8227);F:Refresh('test',true);P:VisualTick()
    assert(F:GetPlatesProjection('target').mainHand)
    F.State.settings.headShowAll=true;F:InvalidateSettingsCache()
    F.laneData.target.buffRows={{id=716,category='buff',iconPath='buff716.dds',detectionSource='normal'}}
    assert(#F:GetPlatesProjection('target').buffs==1)
    S.Services.AuraObservationV3.GetSnapshot=function()return nil,'native_unavailable' end
    F:Refresh('failure',true);P:VisualTick()
    assert(F:GetPlatesProjection('target').mainHand==nil,'old target weapon proof survived an unreadable snapshot')
    assert(#F:GetPlatesProjection('target').buffs==0)
end)
Test('clear followed by failed add cannot suppress a later return to previous weapon',function()
    local h,S,F,P=Boot();local old=S.UI.SetIconTexture
    S.UI.SetIconTexture=function(self,n,path)if path=='bad.dds'then n.texture=nil;return false end;return old(self,n,path)end
    h.weapon='bad.dds';F:EquipmentTick();P:VisualTick();h.weapon='old-weapon.dds';F:EquipmentTick();P:VisualTick()
    local good=false;for _,m in ipairs(P.pools.player.icons)do if m.root.shown and m.icon.texture=='old-weapon.dds'then good=true end end
    assert(good,'local renderer cache claimed cleared texture still existed')
end)
Test('failed child geometry cannot publish a partially positioned plate',function()
    local h,S,F,P=Boot();local p=P.pools.player
    h.rejectAnchor=p.info.iconRoot;F.laneData.player.class={name='Role',icon='role.dds'};P:VisualTick()
    assert(not p.root.shown,'partially committed geometry left visible')
    h.rejectAnchor=nil;P:VisualTick();assert(p.root.shown,'failed layout never recovered')
end)
Test('position-only frames have two native projections and no data queries',function()
    local h,S,F,P=Boot();local before=h.projectionReads;local scans=h.scans;local items=h.itemReads;local builds=P.motionMetrics.contentBuilds
    for i=1,100 do h.points.player[1]=350+i;h.points.target[1]=850-i;F:PositionTick()end
    assert(h.projectionReads-before==200 and h.scans==scans and h.itemReads==items)
    assert(P.motionMetrics.contentBuilds==builds)
end)
Test('raw viewport clamp is applied once to the group not separately to children',function()
    local h,S,F,P=Boot();F.laneData.target.class={name='Role',icon='role.dds'};P:VisualTick();h.scale=2;h.width=2560;h.height=1440;h.ms=h.ms+251
    h.points.target[1]=2200;F:PositionTick();local p=P.pools.target
    assert(p.screenX>1280,'raw coordinate clamped to scaled UI width')
    h.points.target[1]=2558;F:PositionTick();assert(p.screenX+p.width<=2560)
    for i=1,p.placementCount do local r=p.placements[i];assert(r.widget.x>=0 and r.widget.y>=0)
        assert(r.widget.x+r.w<=p.width and r.widget.y+r.h<=p.height,'parent clips active child')end
end)
Test('projection loss hides one group without touching cached content or querying equipment',function()
    local h,S,F,P=Boot();F.laneData.target.class={name='Role',icon='role.dds'};P:VisualTick();local n=P.motionMetrics.contentBuilds;local reads=h.itemReads
    h.points.target=nil;F:PositionTick();assert(not P.pools.target.root.shown and P.pools.player.root.shown)
    h.points.target={900,350,1};F:PositionTick();assert(P.pools.target.root.shown)
    assert(P.motionMetrics.contentBuilds==n and h.itemReads==reads)
end)
Test('negative depth never falls back to a different screen origin',function()
    local h,S,F,P=Boot();h.points.target[3]=-1;local flexible=0
    S.Services.ScreenProjectionV3.ProjectUnitFlexible=function()flexible=flexible+1;return 1,1,1 end
    F:PositionTick();assert(not P.pools.target.root.shown and flexible==0)
end)
Test('P1 event queue progresses with real scheduler under saturated budget',function()
    local h,S,F,P=Boot();local runs=0
    for i=1,24 do S.Scheduler:AddTask('zz_background_'..i,50,function()runs=runs+1 end,true,'load','P3',8)end
    h.weapon='pressure-weapon.dds';h:Event('UNIT_EQUIPMENT_CHANGED')
    for i=1,30 do h:Event('BUFF_UPDATE');h:Step(8)end
    assert(F:GetPlatesProjection('player').mainHand.icon=='pressure-weapon.dds')
    assert(F:GetHealth().pvp.maxQueueAgeMs<=58,'merged event deadline slipped')
    assert(S.FrameBudget.totals.deferred>0,'fixture never exercised budget denial')
end)
Test('missing equipment event is repaired by the 200ms backstop',function()
    local h,S,F,P=Boot();h.weapon='backstop.dds'
    for i=1,14 do h:Step(16)end
    assert(F:GetPlatesProjection('player').mainHand.icon=='backstop.dds')
end)
Test('target change after equipment queues an earlier deadline and preserves equipment edge',function()
    local h,S,F,P=Boot();h.weapon='urgent.dds';h:Event('UNIT_EQUIPMENT_CHANGED')
    local first=F.pendingDue;h:Step(10);h:Event('TARGET_CHANGED');assert(F.pendingDue<first)
    h:Step(2);assert(F:GetPlatesProjection('player').mainHand.icon=='urgent.dds')
end)
Test('event storm has one pending job and a bounded merged bitset',function()
    local h,S,F,P=Boot();h:Event('UNIT_EQUIPMENT_CHANGED');local due=F.pendingDue
    for i=1,2000 do h:Event('BUFF_UPDATE')end
    local count=0;for k in pairs(F.pendingEdges)do count=count+1 end
    assert(count<=3 and F.pendingDue==due and S.Scheduler.tasks[F.eventTaskName])
    h:Step(51);assert(next(F.pendingEdges)==nil and F.pendingDue==nil)
end)
Test('stale event callback from old epoch cannot write after stop and restart',function()
    local h,S,F,P=Boot();h:Event('UNIT_EQUIPMENT_CHANGED');local cb=S.Scheduler.tasks[F.eventTaskName].callback
    F:_StopEvents();local reads=h.itemReads;F:_StartEvents();cb()
    assert(h.itemReads==reads,'old epoch callback changed new state')
end)
Test('target shield disappears and dual wield arrives without whitelist',function()
    local h,S,F,P=Boot();h.facts.target[8226]=h:Fact(8226);h:Event('BUFF_UPDATE');h:Step(51);h:Step(16)
    assert(F:GetPlatesProjection('target').mainHand.buffId==8226)
    h.facts.target={ [4899]=h:Fact(4899) };h:Event('BUFF_UPDATE');h:Step(51);h:Step(16)
    assert(F:GetPlatesProjection('target').mainHand.buffId==4899)
    h.facts.target={};h:Event('BUFF_UPDATE');h:Step(51);h:Step(16)
    assert(F:GetPlatesProjection('target').mainHand==nil)
end)
Test('unsupported same-type weapon changes are not falsely reported as specific enemy equipment',function()
    local h,S,F,P=Boot();h.facts.target[8227]=h:Fact(8227);F:Refresh('types',true)
    local before=F:GetPlatesProjection('target').mainHand;h.weapon='another-self-weapon.dds';h:Event('UNIT_EQUIPMENT_CHANGED');h:Step(51)
    local after=F:GetPlatesProjection('target').mainHand
    assert(before.buffId==after.buffId and after.source=='observed_buff' and after.icon~=h.weapon)
end)

Test('class name and gear score have independent text geometry while zero offsets preserve row flow',function()
    local h,S,F,P=Boot();F.laneData.player.class={name='Bard',icon='role.dds'};F.laneData.player.gearScore=12345;F.laneData.player.distance=28
    F:InvalidateSettingsCache();P:VisualTick()
    assert(type(P.ComputeInfoItemsLayout)=='function','split info layout API missing')
    local profile=F:GetScopeLayoutSettings('player');profile.info.x=0;profile.info.y=0;profile.components.gearScore.x=0;profile.components.gearScore.y=0;profile.components.distance.x=0;profile.components.distance.y=0
    local base=P.ComputePlateLayout(350,350,profile,0,0,{})
    local plates=F:GetPlatesProjection('player')
    local g0=P.ComputeInfoItemsLayout(plates,profile.info,profile.components,base.bar.centerX,base.info.top,base.info.font,base.scale)
    assert(g0.classText and g0.gearScore and g0.distance,'split items missing')
    assert(g0.classText.x+g0.classText.width<=g0.gearScore.x,'class/gear flow overlaps at zero offset')
    local oldGearX,oldDistanceX=g0.gearScore.x,g0.distance.x
    profile.info.x=31
    local g1=P.ComputeInfoItemsLayout(plates,profile.info,profile.components,base.bar.centerX,base.info.top,base.info.font,base.scale)
    assert(g1.classText.x==g0.classText.x+31,'class name ignores info.x')
    assert(g1.gearScore.x==oldGearX and g1.distance.x==oldDistanceX,'class name movement dragged other info items')
    profile.info.x=0;profile.components.gearScore.x=19
    local g2=P.ComputeInfoItemsLayout(plates,profile.info,profile.components,base.bar.centerX,base.info.top,base.info.font,base.scale)
    assert(g2.gearScore.x==oldGearX+19,'gear score ignores its own x')
    assert(g2.classText.x==g0.classText.x and g2.distance.x==oldDistanceX,'gear score movement dragged sibling info items')
end)
Test('class icon geometry remains independent from split class-name text',function()
    local h,S,F,P=Boot();F.laneData.player.class={name='Bard',icon='role.dds'};F.laneData.player.gearScore=12345
    F:InvalidateSettingsCache();P:VisualTick()
    local info=P.pools.player.info
    assert(info.classTextRoot and info.gearRoot,'split renderer widgets missing')
    local tx,ty=h:World(info.classTextRoot);local ix,iy=h:World(info.iconRoot)
    local c=F.State.settings.components.class;c.x=(c.x or 0)+13;c.y=(c.y or 0)-7
    F:InvalidateSettingsCache();P:VisualTick()
    local ntx,nty=h:World(info.classTextRoot);local nix,niy=h:World(info.iconRoot)
    assert(ntx==tx and nty==ty,'class icon offsets still move class name')
    assert(nix==ix+13 and niy==iy-7,'class icon did not consume its own offsets')
end)
Test('class name visibility and class icon visibility are independent',function()
    local h,S,F,P=Boot();F.laneData.player.class={name='Bard',icon='role.dds'};F.laneData.player.gearScore=12345
    F:InvalidateSettingsCache();P:VisualTick()
    local profile=F:GetScopeLayoutSettings('player')
    local base=P.ComputePlateLayout(350,350,profile,0,0,{})
    local plates=F:GetPlatesProjection('player')
    profile.info.showClass=true;profile.components.class.enabled=false
    local noIcon=P.ComputeInfoItemsLayout(plates,profile.info,profile.components,base.bar.centerX,base.info.top,base.info.font,base.scale)
    assert(noIcon.classText and noIcon.classText.text=='Bard','disabling class icon also hid profession name')
    assert(noIcon.icon==nil,'disabled class icon still rendered')
    profile.components.class.enabled=true;profile.info.showClass=false
    local iconOnly=P.ComputeInfoItemsLayout(plates,profile.info,profile.components,base.bar.centerX,base.info.top,base.info.font,base.scale)
    assert(iconOnly.classText==nil,'hidden profession name still rendered')
    assert(iconOnly.icon=='role.dds','hiding profession name also hid independent class icon')
    profile.info.showClass=true;profile.info.x=0;profile.info.y=0
    local anchored=P.ComputeInfoItemsLayout(plates,profile.info,profile.components,base.bar.centerX,base.info.top,base.info.font,base.scale)
    profile.info.x=27;profile.info.y=11
    local movedName=P.ComputeInfoItemsLayout(plates,profile.info,profile.components,base.bar.centerX,base.info.top+11*base.scale,base.info.font,base.scale)
    assert(movedName.classText.x==anchored.classText.x+27 and movedName.classText.y==anchored.classText.y+11*base.scale,'profession text offsets did not move profession text')
    assert(movedName.iconX==anchored.iconX and movedName.iconY==anchored.iconY,'profession text offsets still moved independent class icon')
end)
print(string.format('PVP_HUD_RESULT passed=%d failed=%d',passed,failed));assert(failed==0,'PVP HUD regression failures')

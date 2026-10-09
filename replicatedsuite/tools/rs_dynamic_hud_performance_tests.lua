-- Real Lua 5.1 Feature/Presentation with Native test doubles; excludes RU FPS claims.
-- Run from replicatedsuite: lua tools/rs_dynamic_hud_performance_tests.lua
local pass,fail=0,0
local function Test(n,fn)local ok,e=xpcall(fn,debug.traceback);if ok then pass=pass+1;print('PASS dynamic-hud '..n)else fail=fail+1;print('FAIL dynamic-hud '..n..': '..tostring(e))end end
local Host=dofile('tools/rs_pvp_hud_test_host.lua')
local function Boot()
 local h,S,F,P=Host({runtimeHud=true})
 F.laneData.target.distance=10.1
 F.State.settings.targetLayout.components.distance.enabled=true
 F.State.settings.targetLayout.info.enabled=true;F.State.settings.targetLayout.info.showDistance=true
 F:InvalidateSettingsCache();P:VisualTick()
 return h,S,F,P
end
local function Signal(S,P,reason)S.Events:Publish('v3.buff_display.plates.updated',reason);P:MotionTick()end
Test('distance values only update label when width is unchanged',function()
 local h,S,F,P=Boot();local b=P.motionMetrics.contentBuilds;local reads=h.scans;local tex=h.textures
 local x,y=h:World(P.pools.target.info.distanceRoot)
 for i=2,9 do F.laneData.target.distance=10+i/10;Signal(S,P,'distance')end
 assert(P.pools.target.info.distanceRoot.text=='10.9m','label lost new distance')
 assert(P.motionMetrics.contentBuilds==b,'distance rebuilt full HUD')
 assert(h.scans==reads and h.textures==tex and h:World(P.pools.target.info.distanceRoot)==x,'distance queried or moved siblings')
 assert(P.pools.target.info.distanceRoot.shown)
end)
Test('distance width edge and missing data relayout safely then resume partial updates',function()
 local h,S,F,P=Boot();local b=P.motionMetrics.contentBuilds
 F.laneData.target.distance=100.1;Signal(S,P,'distance');assert(P.motionMetrics.contentBuilds>b,'width edge lost parent bounds')
 b=P.motionMetrics.contentBuilds;F.laneData.target.distance=100.2;Signal(S,P,'distance');assert(P.motionMetrics.contentBuilds==b)
 F.laneData.target.distance=nil;Signal(S,P,'distance');assert(not P.pools.target.info.distanceRoot.shown)
 F.laneData.target.distance=10.1;Signal(S,P,'distance');assert(P.pools.target.info.distanceRoot.shown)
end)
Test('cast progress only changes fill and text; start finish retain geometry',function()
 local h,S,F,P=Boot();F.State.settings.targetLayout.components.castBar.enabled=true
 F:InvalidateSettingsCache();P:VisualTick();local cast={casting=true,spellName='cast',currMs=100,totalMs=1000}
 F.laneData.target.cast=cast;Signal(S,P,'cast');assert(P.pools.target.cast.root.shown)
 local b=P.motionMetrics.contentBuilds;local bar=P.pools.target.cast;local first=bar.fill.width
 for i=2,8 do cast.currMs=i*100;Signal(S,P,'cast')end
 assert(bar.fill.width>first and P.motionMetrics.contentBuilds==b,'cast progress rebuilt HUD')
 cast.spellName='new cast';Signal(S,P,'cast');assert(bar.text.text=='new cast')
 F.laneData.target.cast=nil;Signal(S,P,'cast');assert(not bar.root.shown)
end)
Test('full data changes supersede partial dirtiness and invalid target cannot resurrect',function()
 local h,S,F,P=Boot();local b=P.motionMetrics.contentBuilds
 F.laneData.target.distance=10.2;S.Events:Publish('v3.buff_display.plates.updated','distance')
 S.Events:Publish('v3.buff_display.plates.updated','metadata');P:MotionTick();assert(P.motionMetrics.contentBuilds==b+1)
 h.points.target=nil;h:Event('TARGET_CHANGED');F:PositionTick();assert(not P.pools.target.root.shown)
 F.laneData.target.distance=10.3;Signal(S,P,'distance');assert(not P.pools.target.root.shown)
 P:SetCalibrationSuppressed(true);b=P.motionMetrics.contentBuilds;Signal(S,P,'distance');assert(P.motionMetrics.contentBuilds==b)
 P:SetCalibrationSuppressed(false);assert(not P.pools.target.root.shown)
end)
Test('settings revision and disabled distance bypass stale partial geometry',function()
 local h,S,F,P=Boot();local c=F.State.settings.targetLayout.components.distance;c.enabled=false
 F:InvalidateSettingsCache();Signal(S,P,'distance');assert(not P.pools.target.info.distanceRoot.shown)
 c.enabled=true;c.fontSize=20;F:InvalidateSettingsCache();Signal(S,P,'distance');assert(P.pools.target.info.distanceRoot.shown)
end)
Test('rejected partial text cannot be cached as success and next tick retries',function()
 local h,S,F,P=Boot();local widget=P.pools.target.info.distanceRoot;local set=widget.SetText
 widget.SetText=function()return false end;F.laneData.target.distance=10.2;Signal(S,P,'distance')
 assert(not widget.shown and P.pools.target.info.distanceText~='10.2m','rejected text retained plausible old value')
 widget.SetText=set;h.ms=h.ms+60;P:MotionTick();assert(widget.shown and widget.text=='10.2m')
end)
Test('invalidated existing layout cannot apply partial data until full retry',function()
 local h,S,F,P=Boot();P.pools.target.ready=false;local b=P.motionMetrics.contentBuilds
 F.laneData.target.distance=10.2;Signal(S,P,'distance');assert(P.motionMetrics.contentBuilds>b)
end)
Test('recovery before retry deadline restores the hidden distance immediately',function()
 local h,S,F,P=Boot();local widget=P.pools.target.info.distanceRoot;local set=widget.SetText
 widget.SetText=function()return false end;F.laneData.target.distance=10.2;Signal(S,P,'distance');assert(not widget.shown)
 widget.SetText=set;F.laneData.target.distance=10.3;Signal(S,P,'distance')
 assert(widget.shown and widget.text=='10.3m','partial success left distance hidden')
end)
Test('rejected cast fill hides old progress and next partial restores it',function()
 local h,S,F,P=Boot();F.State.settings.targetLayout.components.castBar.enabled=true
 F:InvalidateSettingsCache();F.laneData.target.cast={casting=true,spellName='cast',currMs=100,totalMs=1000};P:VisualTick()
 local bar=P.pools.target.cast;local extent=S.UI.EnsureExtent;local reject=true
 S.UI.EnsureExtent=function(self,w,...)if w==bar.fill and reject then return false,false,'rejected' end;return extent(self,w,...)end
 F.laneData.target.cast.currMs=500;Signal(S,P,'cast');assert(not bar.root.shown,'old progress stayed visible')
 reject=false;F.laneData.target.cast.currMs=600;Signal(S,P,'cast');assert(bar.root.shown,'progress recovery stayed hidden')
end)
Test('rejected full distance layout must recover geometry before showing',function()
 local h,S,F,P=Boot();local widget=P.pools.target.info.distanceRoot;local set=widget.SetText
 F.laneData.target.class={name='example'};F.laneData.target.distance=100.1
 F.State.settings.targetLayout.info.showClass=true;F.State.settings.targetLayout.components.distance.x=500
 F:InvalidateSettingsCache();widget.SetText=function()return false end;P:VisualTick()
 assert(not widget.shown);local b=P.motionMetrics.contentBuilds
 widget.SetText=set;F.laneData.target.distance=100.2;Signal(S,P,'distance')
 assert(P.motionMetrics.contentBuilds>b and widget.shown,'failed full placement was reused')
 assert(P.pools.target.width>=widget.x+widget.width,'restored distance lies outside parent bounds')
end)
Test('idle player cast-only HUD cannot force target dynamic rebuilds',function()
 local h,S,F,P=Boot()
 for _,cfg in pairs(F.State.settings.components)do cfg.enabled=false end
 F.State.settings.components.castBar.enabled=true;F.State.settings.info.enabled=false
 F.laneData.player={};F:InvalidateSettingsCache();P:VisualTick()
 assert(not P.pools.player.ready and P.pools.target.ready)
 local b=P.motionMetrics.contentBuilds
 for i=2,5 do F.laneData.target.distance=10+i/10;Signal(S,P,'distance')end
 assert(P.motionMetrics.contentBuilds==b,'irrelevant empty player HUD rebuilt target distance')
 F.State.settings.targetLayout.components.castBar.enabled=true;F:InvalidateSettingsCache()
 F.laneData.target.cast={casting=true,spellName='target cast',currMs=100,totalMs=1000};P:VisualTick();b=P.motionMetrics.contentBuilds
 F.laneData.target.cast.currMs=200;Signal(S,P,'cast');assert(P.motionMetrics.contentBuilds==b,'absent player cast rebuilt active target cast')
 F.laneData.player.cast={casting=true,spellName='player cast',currMs=100,totalMs=1000};Signal(S,P,'cast')
 assert(P.motionMetrics.contentBuilds>b and P.pools.player.cast.root.shown,'new player cast skipped layout')
end)
local f=assert(io.open('tools/rs_unit_lines_regression_tests.lua','rb'));local src=f:read('*a');f:close()
local setup=assert(src:match('^(.-)Test%(\'native screen success'))
local LineBoot=assert(loadstring(setup..'\nreturn Boot','dynamic_lines_host'))()
Test('line density cannot grow after background pressure recovers and base density remains',function()
 local S,P,G,F,c=LineBoot();local rows={{x1=0,y1=0,x2=2300,y2=1300,pairKey='target'},
 {x1=10,y1=10,x2=2300,y2=1300,pairKey='focus'}, {x1=20,y1=20,x2=2300,y2=1300,pairKey='targettarget'}}
 local projection={pointCount=24,refreshMs=26}
 local normal,bn=G:BuildUnitLineSamplePlan(rows,projection,c.width,c.height,'Normal')
 local critical,bc=G:BuildUnitLineSamplePlan(rows,projection,c.width,c.height,'Critical')
 assert(bn==bc and bn<=176,'backlog recovery still doubles visual budget')
 for i,p in ipairs(normal)do assert(p.count==critical[i].count and p.count>=24)end
 projection.pointCount=160;local large,b=G:BuildUnitLineSamplePlan(rows,projection,c.width,c.height,'Normal')
 for _,p in ipairs(large)do assert(p.count>=160,'user base density was reduced')end
end)
print(string.format('DYNAMIC HUD RESULT %d passed / %d failed',pass,fail));if fail>0 then os.exit(1)end

-- 维护：真实投影/Feature/Demand/Presenter/诊断逻辑；只模拟Native坐标、RSUI写入和调度驱动。
-- 故障依据：2026-09-12 客户端 rows=2/4、(1280,731)->(931,-3345)、partial仍标ok。
-- 这些反例证明代码分支，不声明已复现RU原生投影返回值的全部原因；不读写用户UDF。
local passed,failed=0,0
local function Test(name,fn)
    local ok,err=pcall(fn)
    if ok then passed=passed+1; print('PASS unit-lines '..name)
    else failed=failed+1; print('FAIL unit-lines '..name..': '..tostring(err)) end
end
local H=dofile('tools/rs_udf_numeric_test_host.lua')
local function Boot()
    local c={screen={},world={},native=0,worldReads=0,global=0,width=2559,height=1439,anchors=0,failAnchor=false}
    X2Unit={GetUnitScreenPosition=function(_,token)c.native=c.native+1;local r=c.screen[token];if r then return r[1],r[2],r[3] end end,
        GetUnitWorldPositionByTarget=function(_,token)c.worldReads=c.worldReads+1;local r=c.world[token];if r then return r[1],r[2],r[3] end end}
    UIParent={GetViewCameraPos=function()return {x=0,y=0,z=0}end,
        GetViewCameraDir=function()return {x=0,y=1,z=0}end,GetViewCameraFov=function()return 1.57 end,
        GetScreenWidth=function()return c.width end,GetScreenHeight=function()return c.height end}
    ConvertWorldToScreen=function()c.global=c.global+1;return 500,400,1 end
    local S,P,io=H.Boot()
    S.SafeTraceback=debug.traceback
    S.FeatureRuntime.IsEnabled=function(_,id)return S.Features[id] and S.Features[id].enabled==true end
    S.Scheduler={tasks={},AddHighFrequencyTask=function(self,id,ms,fn)self.tasks[id]={ms=ms,fn=fn};return true end,
        RemoveTask=function(self,id)self.tasks[id]=nil;return true end,SetTaskModule=function()return true end}
    S.Layout={GetContext=function()return {logicalWidth=1280,logicalHeight=768,screenWidth=c.width,screenHeight=c.height,uiScale=0.5,addonScale=1.7}end,
        GetUiParentLocalOrigin=function()return 21,33,true end}
    local UI=S.UI
    UI.CreateOverlayWindow=function()return {visible=false}end
    UI.CreateLabel=function()return {visible=false}end
    UI.SetVisible=function(_,w,v)if not w then return false end;local change=w.visible~=v;w.visible=v;return change end
    UI.EnsureVisible=function(_,w,v)if not w then return false,false,'nil' end;local change=w.visible~=v;w.visible=v;return true,change end
    UI.SetAnchor=function(_,w,parent,x,y)c.anchors=c.anchors+1;if c.failAnchor then return false end;w.x,w.y=x,y;return true end
    UI.EnsureAnchor=function(_,w,parent,x,y)if c.failAnchor then return false,false,'rejected' end;local change=w.x~=x or w.y~=y;if change then c.anchors=c.anchors+1;w.x,w.y=x,y end;return true,change end
    UI.SetFontSize=function()return true end;UI.SetColor=function()return true end
    dofile('services/rs_screen_projection_v3.lua')
    dofile('features/rs_business_bridge.lua')
    dofile('presentation/v3/widgets/rs_v3_combat_visual_guides.lua')
    dofile('core/rs_diagnostics.lua')
    return S,S.Services.ScreenProjectionV3,S.UIV3.CombatVisualGuidesV3,S.Features.combat_unit_lines,c,io
end
local function Row(x1,y1,x2,y2,key)return {x1=x1,y1=y1,x2=x2,y2=y2,pairKey=key or 'target'}end
local function UseRows(F,rows)F.Authority.rows=rows;F.Authority.status='ready' end
Test('native screen success is not dependent on world getter availability',function()
    local S,P,G,F,c=Boot();c.screen.watchtarget={931,340,1}
    local out=P:ProjectUnitBatch({'watchtarget'})
    assert(out.watchtarget.visible==true,'valid native endpoint discarded when world=nil')
    assert(out.watchtarget.x==931 and c.native==1)
end)
Test('deduplicated screen facts survive a partly unavailable world batch',function()
    local S,P,G,F,c=Boot();c.screen.player={1280,731,1};c.screen.target={931,500,1};c.world.player={0,10,0}
    local out=P:ProjectUnitBatch({'player','target','player'})
    assert(out.player.visible and out.target.visible);assert(c.native==2 and c.worldReads==2)
end)
Test('native negative depth cannot be resurrected by world fallback',function()
    local S,P,G,F,c=Boot();c.world.target={1,10,0};c.screen.target={900,500,-1}
    local out=P:ProjectUnitBatch({'target'})
    assert(not out.target.visible and out.target.reason=='behind_camera');assert(c.global==0)
end)
Test('native zero depth remains behind and does not emit a false edge',function()
    local S,P,G,F,c=Boot();c.world.target={1,10,0};c.screen.target={900,500,0}
    local out=P:ProjectUnitBatch({'target'});assert(not out.target.visible and out.target.reason=='behind_camera')
end)
Test('missing world and screen preserve concrete reason instead of generic failure',function()
    local S,P,G,F,c=Boot();local out=P:ProjectUnitBatch({'watchtarget'})
    assert(not out.watchtarget.visible);assert(out.watchtarget.reason~='unit_projection_unavailable')
    assert(out.watchtarget.nativeError and out.watchtarget.worldError,'missing endpoint evidence')
end)
Test('screen NaN without world is rejected rather than becoming coordinate zero',function()
    local S,P,G,F,c=Boot();c.screen.target={0/0,400,1};local out=P:ProjectUnitBatch({'target'})
    assert(not out.target.visible and out.target.x==nil)
end)
Test('strict camera consumer remains fail-closed when world is missing',function()
    local S,P,G,F,c=Boot();c.screen.target={900,400,1}
    local out=P:ProjectUnitBatch({'target'},{requireFrontHemisphere=true});assert(not out.target.visible)
end)
Test('front filter still rejects proven camera-behind points for strict consumers',function()
    local S,P,G,F,c=Boot();c.world.target={1,-10,0};c.screen.target={900,400,1}
    local out=P:ProjectUnitBatch({'target'},{requireFrontHemisphere=true});assert(not out.target.visible and out.target.reason=='behind_camera')
end)
Test('world alias native endpoints remain independent without scale reinterpretation',function()
    local S,P,G,F,c=Boot();c.world.player={0,10,0};c.world.target={0,10,0};c.screen.player={1280,731,1};c.screen.target={931,500,1}
    local out=P:ProjectUnitBatch({'player','target'});assert(out.player.x==1280 and out.target.x==931 and out.target.worldAliased)
end)
Test('reported offscreen line is sampled on visible part, not all 4076 pixels',function()
    local S,P,G=Boot();local r=Row(1280,731,931,-3345)
    local plans,budget,stats=G:BuildUnitLineSamplePlan({r},{pointCount=24,refreshMs=50},2559,1439,'Normal')
    assert(#plans==1 and plans[1].y2>=0 and plans[1].y2<1,'offscreen samples consume point budget')
    assert(plans[1].count<100 and plans[1].length<740)
    assert(r.y2==-3345,'producer row mutated');assert(stats.clippedEdges==1)
end)
Test('clipping preserves segment slope instead of clamping one endpoint',function()
    local S,P,G=Boot();local ps=G:BuildUnitLineSamplePlan({Row(100,100,300,-100)},{},400,300)
    assert(#ps==1 and math.abs(ps[1].x2-200)<0.01 and ps[1].y2==0)
end)
Test('both endpoints outside same edge use no drawable budget',function()
    local S,P,G=Boot();local ps,b,stats=G:BuildUnitLineSamplePlan({Row(-20,20,-10,200)},{},1280,768)
    assert(#ps==0 and stats.outsideEdges==1)
end)
Test('both outside endpoints crossing screen keep the visible segment',function()
    local S,P,G=Boot();local ps=G:BuildUnitLineSamplePlan({Row(-100,100,1500,100)},{},1280,768)
    assert(#ps==1 and ps[1].x1==0 and ps[1].x2==1279)
end)
Test('NaN infinity and overflowing coordinates are rejected before density loop',function()
    local S,P,G=Boot();local ps,b,stats=G:BuildUnitLineSamplePlan({Row(0,0,0/0,100),Row(0,0,math.huge,100),Row(-1e308,0,1e308,100)},{},1280,768)
    assert(#ps==0 and stats.invalidEdges==3)
end)
Test('missing viewport leaves finite native coordinates unchanged',function()
    local S,P,G=Boot();local ps,b,stats=G:BuildUnitLineSamplePlan({Row(1280,731,931,-3345)},{},nil,nil)
    assert(#ps==1 and ps[1].y2==-3345 and stats.viewportKnown==false)
end)
for _,screen in ipairs({{1024,768},{1280,768},{1920,1080},{2559,1439}}) do
 Test('raw screen clipping independent of addon/logical scale '..screen[1]..'x'..screen[2],function()
    local S,P,G,F,c=Boot();c.width,c.height=screen[1],screen[2];G.unitHeld=true;G:EnsureHost('unit')
    UseRows(F,{Row(c.width-30,100,c.width+500,150)})
    assert(G:RenderUnit());assert(G.lastUnitSampling.viewportWidth==c.width and G.lastUnitSampling.viewportHeight==c.height)
    assert(G.lastUnitSampling.visibleEdges==1 and G.lastUnitSampling.clippedEdges==1)
    for _,dot in ipairs(G.unitPools.target)do if dot.root.visible then
        local x=dot.root.x+21;local y=dot.root.y+33
        assert(x>=0 and x<c.width and y>=0 and y<c.height,'wrong logical viewport or host transform')
    end end
 end)
end
Test('empty frame clears old visible sampling and hides all retained dots',function()
    local S,P,G,F,c=Boot();G.unitHeld=true;G:EnsureHost('unit');UseRows(F,{Row(10,10,400,400)});assert(G:RenderUnit())
    assert(G.lastUnitSampling.visibleDots>0);UseRows(F,{});assert(G:RenderUnit())
    assert(G.lastUnitSampling.visibleDots==0 and G.lastUnitSampling.uniquePositions==0 and not G.unitHost.visible)
end)
Test('offscreen frame hides previous pool without creating more widgets',function()
    local S,P,G,F,c=Boot();G.unitHeld=true;G:EnsureHost('unit');UseRows(F,{Row(10,10,400,400)});G:RenderUnit()
    local count=#G.unitPools.target;UseRows(F,{Row(-300,20,-200,200)});assert(G:RenderUnit())
    assert(G.lastUnitSampling.visibleDots==0 and #G.unitPools.target==count and not G.unitHost.visible)
end)
Test('partial feature status is degraded instead of healthy',function()
    local S,P,G,F,c=Boot();F.enabled=true;F.consumerCount=1;F.Diagnostics={drawnRows=2,attemptedPairs=4,lastStatus='partial',lastFailureReason='focus unavailable'}
    G.lastUnitSampling={visibleDots=30,uniquePositions=30}
    local row=S.DiagnosticsManager:BuildFeatureStatusRows()[1];assert(row.id=='unit_lines' and row.verdict=='degraded')
end)
Test('fully clipped drawing is offscreen idle not a broken renderer',function()
    local S,P,G,F,c=Boot();F.enabled=true;F.consumerCount=1;F.Diagnostics={drawnRows=1,attemptedPairs=1,lastStatus='ready'}
    G.lastUnitSampling={visibleDots=0,uniquePositions=0,inputEdges=1,outsideEdges=1,viewportKnown=true}
    local row=S.DiagnosticsManager:BuildFeatureStatusRows()[1];assert(row.verdict=='idle' and not row.text:find('渲染层 0',1,true))
end)
Test('real feature acquires one 50ms task and releases it at final demand',function()
    local S,P,G,F,c,io=Boot();c.screen.player={500,400,1};c.screen.target={800,500,1}
    assert(F:Initialize());assert(F:Enable());F.State.refreshMs=50;F.State.showFocusTarget=false;F.State.showFocusTargetTarget=false;F.State.showTargetTarget=false
    assert(F:AcquireConsumer('test'));assert(F.consumerCount==1 and #F.Authority.rows==1)
    local task=assert(S.Scheduler.tasks.v3_business_unit_lines_refresh);assert(task.ms==50);task.fn()
    assert(F.Diagnostics.endpoints.target.x==800,'current endpoint evidence missing')
    assert(F:ReleaseConsumer('test'));assert(F.consumerCount==0 and S.Scheduler.tasks.v3_business_unit_lines_refresh==nil)
    local n=c.native;task.fn();assert(c.native==n,'stale task performs reads after release')
    assert(io.writes==0 and io.clears==0)
end)
Test('anchor rejection cannot poison cache and must retry unchanged coordinates',function()
    local S,P,G,F,c=Boot();G:EnsureHost('unit');local dot={root={visible=false},renderState={visible=false}}
    c.failAnchor=true;G:PlaceUnitDot(dot,500,400,4,0.8,'target',1,1,1,G:ResolveHostTransform(G.unitHost))
    assert(dot.renderState.x==nil and not dot.root.visible,'rejected anchor cached as success')
    c.failAnchor=false;G:PlaceUnitDot(dot,500,400,4,0.8,'target',1,1,1,G:ResolveHostTransform(G.unitHost))
    assert(dot.root.x==479 and dot.root.y==367 and dot.root.visible)
end)
Test('visibility cache-hit is accepted by presenter',function()
    local S,P,G=Boot();local dot={root={visible=true},renderState={visible=false}}
    G:SetUnitDotVisible(dot,true);assert(dot.renderState.visible==true,'no-op treated as native rejection')
end)
Test('world fallback negative depth is not drawable either',function()
    local S,P,G,F,c=Boot();c.world.target={1,10,0};ConvertWorldToScreen=function()c.global=c.global+1;return 500,400,-3 end
    local out=P:ProjectUnitBatch({'target'});assert(not out.target.visible and out.target.reason=='behind_camera')
end)
Test('legacy native screen return without depth remains usable',function()
    local S,P,G,F,c=Boot();c.screen.target={700,400};local out=P:ProjectUnitBatch({'target'})
    assert(out.target.visible and out.target.x==700 and out.target.depth==1)
end)
Test('on-screen native endpoint never replaced by world camera disagreement',function()
    local S,P,G,F,c=Boot();c.screen.target={333,444,1};c.world.target={1,10,0}
    local out=P:ProjectUnitBatch({'target'});assert(out.target.x==333 and out.target.y==444 and out.target.source=='native_unit')
end)
Test('resolution switch is reflected without stale clipping cache',function()
    local S,P,G,F,c=Boot();G.unitHeld=true;G:EnsureHost('unit');UseRows(F,{Row(1600,100,1800,200)})
    c.width=1280;c.height=768;G:RenderUnit();assert(G.lastUnitSampling.visibleDots==0)
    c.width=1920;c.height=1080;G:RenderUnit();assert(G.lastUnitSampling.visibleDots>0 and G.lastUnitSampling.viewportWidth==1920)
end)
Test('camera getters are not added to default native-unit fast path',function()
    local S,P,G,F,c=Boot();UIParent.GetViewCameraPos=function()error('default path must not read camera')end
    c.world.player={0,10,0};c.world.target={1,10,0};c.screen.player={500,400,1};c.screen.target={800,500,1}
    local out=P:ProjectUnitBatch({'player','target'});assert(out.player.visible and out.target.visible and c.global==0)
end)
Test('four lines keep cadence and pool growth budgets under frame pressure',function()
    local S,P,G,F,c=Boot();G.unitHeld=true;G:EnsureHost('unit');F.State.refreshMs=50
    UseRows(F,{Row(10,10,2000,1000,'target'),Row(20,20,2100,1100,'focus'),Row(30,30,2200,1200,'targettarget'),Row(40,40,2300,1300,'focustarget')})
    S.FrameBudget={current={pressure='Critical'}}
    for i=1,40 do assert(G:RenderUnit());assert(G.lastUnitSampling.poolGrowth<=16 and G.lastUnitSampling.requestedDots<=211)end
    local count=0;for _,pool in pairs(G.unitPools)do assert(#pool<=160);count=count+#pool end
    assert(count<=211 and G.lastUnitSampling.anchorWrites==0)
end)
Test('second identical frame makes no extra position writes',function()
    local S,P,G,F,c=Boot();G.unitHeld=true;G:EnsureHost('unit');UseRows(F,{Row(10,10,200,200)})
    G:RenderUnit();local count=c.anchors;G:RenderUnit();assert(c.anchors==count and G.lastUnitSampling.anchorWrites==0)
end)
Test('clipping rejects degenerate intersection instead of piling a dot at edge',function()
    local S,P,G=Boot();local plans,b,stats=G:BuildUnitLineSamplePlan({Row(-10,-10,0,0)},{},1280,768)
    assert(#plans==0 and stats.shortEdges==1)
end)
Test('all endpoints unavailable still appear in diagnostic report',function()
    local S,P,G,F,c=Boot();F.enabled=true;F.consumerCount=1;F.Authority:Refresh('test')
    local row=S.DiagnosticsManager:BuildFeatureStatusRows()[1]
    assert(row.endpoints and row.endpoints.watchtarget and row.endpoints.watchtarget.nativeError,'down row lost endpoint evidence')
end)
Test('current feature telemetry is captured after native failures, not previous frame',function()
    local S,P,G,F,c=Boot();F.Authority:Refresh('test')
    assert(F.Diagnostics.projection.failures==P:GetHealth().failures and F.Diagnostics.projection.failures>0)
end)
Test('feature disable removes task and presenter hides every visible point',function()
    local S,P,G,F,c=Boot();c.screen.player={500,400,1};c.screen.target={800,500,1}
    F:Initialize();F:Enable();F.State.showFocusTarget=false;F.State.showFocusTargetTarget=false;F.State.showTargetTarget=false
    assert(G:Reconcile('enabled'));assert(G.lastUnitSampling.visibleDots>0)
    assert(F:Disable());assert(G:Reconcile('disabled'));assert(not G.unitHost.visible and G.lastUnitSampling.visibleDots==0)
    assert(S.Scheduler.tasks.v3_business_unit_lines_refresh==nil and not G.unitHeld)
    for _,pool in pairs(G.unitPools)do for _,dot in ipairs(pool)do assert(dot.root.visible==false)end end
end)

Test('deterministic segment sweep preserves viewport bounds and collinearity',function()
    local S,P,G=Boot()
    local seed=12345
    local function Number()seed=(seed*48271)%2147483647;return seed%9000-3500 end
    for i=1,400 do
        local x1,y1,x2,y2=Number(),Number(),Number(),Number()
        local ps,b=G:BuildUnitLineSamplePlan({Row(x1,y1,x2,y2)},{refreshMs=50},1920,1080,'Normal')
        local p=ps[1]
        if p then
            assert(p.x1>=-1e-7 and p.x1<=1919+1e-7 and p.y1>=-1e-7 and p.y1<=1079+1e-7)
            assert(p.x2>=-1e-7 and p.x2<=1919+1e-7 and p.y2>=-1e-7 and p.y2<=1079+1e-7)
            assert(math.abs((p.x1-x1)*(y2-y1)-(p.y1-y1)*(x2-x1))<1e-4)
            assert(math.abs((p.x2-x1)*(y2-y1)-(p.y2-y1)*(x2-x1))<1e-4)
            assert(p.count<=160 and p.count<=b)
        end
    end
end)


Test('accepted unit-line density above legacy 48 remains the configured base density',function()
    local S,P,G,F=Boot()
    assert(F:Initialize())
    assert(F.Commands:SetPointCount(58))
    assert(F.State.pointCount==58,'feature clamped accepted density to '..tostring(F.State.pointCount))
    local plans=G:BuildUnitLineSamplePlan({Row(10,10,600,100,'target')},{pointCount=F.State.pointCount,refreshMs=50},1280,768,'Normal')
    assert(#plans==1 and plans[1].base==58,'presenter base density remained '..tostring(plans[1] and plans[1].base))
end)

Test('unit-line renderer progressively reaches an accepted density above 48',function()
    local S,P,G,F,c=Boot()
    assert(F:Initialize())
    assert(F.Commands:SetPointCount(58))
    assert(F.Commands:SetPairPoints('target',58))
    G.unitHeld=true
    assert(G:EnsureHost('unit'))
    UseRows(F,{Row(10,10,900,100,'target')})
    assert(G:RenderUnit())
    assert(G:RenderUnit())
    assert(#G.unitPools.target>=58,'unit-line pool stopped at '..tostring(#G.unitPools.target))
    assert(G.lastUnitSampling.visibleDots>=58,'unit-line renderer stopped at '..tostring(G.lastUnitSampling.visibleDots)..' visible dots')
end)

Test('accepted range-circle density above legacy 48 survives domain normalization',function()
    local S=Boot()
    local R=assert(S.Features.combat_range_assist)
    assert(R:Initialize())
    assert(R.Commands:AddCircle())
    local circle=assert(R.State.circles[1])
    assert(R.Commands:SetCirclePointCount(circle.id,58))
    circle=assert(R.State.circles[1])
    assert(circle.pointCount==58,'range feature clamped accepted density to '..tostring(circle.pointCount))
end)


Test('range renderer displays every accepted point above the old 48-dot ceiling',function()
    local S,P,G,F,c=Boot()
    local R=assert(S.Features.combat_range_assist)
    c.world.player={0,10,0}
    assert(R:Initialize())
    assert(R.Commands:AddCircle())
    local circle=assert(R.State.circles[1])
    assert(R.Commands:SetCirclePointCount(circle.id,58))
    assert(R.Authority:Refresh('density_regression'))
    local row=assert(R.Authority.rows[1])
    assert(row.renderPointCount==58 and #row.points==58,'feature generated '..tostring(row.renderPointCount)..'/'..tostring(#row.points)..' points')
    G.rangeHeld=true
    assert(G:EnsureHost('range'))
    assert(G:RenderRange())
    assert(G.lastRangeSampling.points==58,'presenter rendered '..tostring(G.lastRangeSampling.points)..' instead of 58')
    local pool=assert(G.rangePools.circle_1)
    assert(#pool>=58,'range pool stopped at '..tostring(#pool))
end)


Test('range total-point budgeting never expands a low-density circle above its requested count',function()
    local S,P,G,F,c=Boot()
    local R=assert(S.Features.combat_range_assist)
    c.world.player={0,10,0}
    assert(R:Initialize())
    assert(R.Commands:AddCircle())
    assert(R.Commands:AddCircle())
    local first=assert(R.State.circles[1])
    local second=assert(R.State.circles[2])
    assert(R.Commands:SetCirclePointCount(first.id,192))
    assert(R.Commands:SetCirclePointCount(second.id,3))
    assert(R.Authority:Refresh('budget_low_density_regression'))
    local secondRow=assert(R.Authority.rows[2])
    assert(secondRow.requestedPointCount==3,'test precondition lost requested density')
    assert(secondRow.renderPointCount<=3,'budgeting expanded requested 3 points to '..tostring(secondRow.renderPointCount))
end)

print('UNIT LINES RESULT '..passed..' passed / '..failed..' failed ('.._VERSION..')')
if failed>0 then error('unit-lines regressions failed: '..failed) end

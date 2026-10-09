-- 维护（2026-09-30）：范围辅助断续刷新回归。真实 Scheduler/FrameBudget/Events/Demand/
-- Feature/Projection/Presenter/ModuleDiagnostics；仅替换 Native 坐标/UI/存储与注册宿主。
-- 反例不声称复现了用户客户端的全部根因；不访问玩家 UDF，不进入 toc.g。
local passed, failed = 0, 0
local function Test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then passed = passed + 1; print('PASS range-continuity ' .. name)
    else failed = failed + 1; print('FAIL range-continuity ' .. name .. ': ' .. tostring(err)) end
end
local H = dofile('tools/rs_udf_numeric_test_host.lua')
local function Circle(id, count)
    return { id=id, name='circle '..id, enabled=true, radius=10, pointCount=count or 24,
        pointSize=4, opacity=0.68, color={0.2,0.82,1} }
end
local function Boot(counts, dormant)
    local c = {now=0, reads=0, created=0, placements=0, failAnchor=false, failShow=false,
        missingWorld=false, native=true, x=0, z=0, cameraZ=5, cameraY=0,
        cameraDir={x=0,y=1,z=-0.1}, fov=1.57, width=2560, height=1440}
    X2Unit = {
        GetUnitWorldPositionByTarget=function(_, token)
            c.reads=c.reads+1
            if token=='player' and not c.missingWorld then return c.x,30,c.z end
        end,
        GetUnitScreenPosition=function(_, token)
            c.reads=c.reads+1
            if token=='player' then return 1280,900,1 end
        end,
        UnitDistance=function() c.reads=c.reads+1; return nil end,
    }
    UIParent = {
        GetViewCameraPos=function()c.reads=c.reads+1;return {x=0,y=c.cameraY,z=c.cameraZ}end,
        GetViewCameraDir=function()c.reads=c.reads+1;return c.cameraDir end,
        GetViewCameraFov=function()c.reads=c.reads+1;return c.fov end,
        GetScreenWidth=function()c.reads=c.reads+1;return c.width end,
        GetScreenHeight=function()c.reads=c.reads+1;return c.height end,
    }
    ConvertWorldToScreen=function(x,y,z)
        c.reads=c.reads+1
        if c.native then return 1280+x*5,800+y*2-z,1 end
    end
    local S, _, disk = H.Boot()
    S.NowMs=function()return c.now end
    S.AdvanceClock=function(dt)c.now=c.now+dt end
    S.SafeChat=function()end
    S.FeatureRuntime.implementations={}
    S.FeatureRuntime.state={}
    function S.FeatureRuntime:RegisterImplementation(id, f)
        self.implementations[id]=f;self.state[id]={initialized=false,enabled=false};return true
    end
    function S.FeatureRuntime:IsEnabled(id)return S.Features[id] and S.Features[id].enabled==true end
    function S.FeatureRuntime:IsImplemented(id)return self.implementations[id]~=nil end
    S.FeatureRegistry={order={'combat_range_assist','combat_unit_lines'},features={}}
    S.FeatureRegistry.features.combat_range_assist={id='combat_range_assist',route='combat.range_assist',name='范围辅助',authority='v3.range_assist',category='combat'}
    S.FeatureRegistry.features.combat_unit_lines={id='combat_unit_lines',route='combat.unit_lines',name='单位连线',authority='v3.unit_lines',category='combat'}
    function S.FeatureRegistry:Get(id)return self.features[id]end
    function S.FeatureRegistry:List()local out={};for _,id in ipairs(self.order)do out[#out+1]=self.features[id]end;return out end
    function S.FeatureRegistry:GetByRoute(route)for _,r in ipairs(self:List())do if r.route==route then return r end end end
    local driver={SetExtent=function()end,AddAnchor=function()end,Show=function()end}
    function driver:SetHandler(_, fn) self.update=fn end
    function driver:ReleaseHandler() self.update=nil end
    S.NativeObjectFactory={CreateEmptyWidget=function()return driver end}
    dofile('core/rs_scheduler.lua')
    dofile('core/rs_frame_budget.lua')
    dofile('core/rs_events.lua')
    dofile('core/rs_module_diagnostics.lua')
    S.Layout={GetContext=function()return {logicalWidth=c.width,logicalHeight=c.height,uiScale=1}end,
        GetUiParentLocalOrigin=function()return 0,0,true end,GetUiEnvironmentRevision=function()return 1,'test' end}
    local UI=S.UI
    UI.CreateOverlayWindow=function() c.created=c.created+1;return {visible=false} end
    UI.CreateLabel=function()c.created=c.created+1;return {visible=false}end
    UI.SetVisible=function(_,w,v)if not w then return false end;local changed=w.visible~=v;w.visible=v;return changed end
    UI.EnsureVisible=function(_,w,v)
        if not w or (c.failShow and v) then return false,false,'rejected' end
        local changed=w.visible~=v;w.visible=v;return true,changed
    end
    UI.EnsureAnchor=function(_,w,parent,x,y)
        if c.failAnchor then return false,false,'rejected' end
        c.placements=c.placements+1;w.x,w.y=x,y;return true,true
    end
    UI.SetFontSize=function()return true end
    UI.SetColor=function()return true end
    UI.NativeVisibleReadback=function(_,w)return w and w.visible or false,w~=nil end
    dofile('services/rs_screen_projection_v3.lua')
    dofile('features/shared/rs_feature_slice_factory.lua')
    dofile('features/shared/rs_shared_bounds.lua')
    dofile('features/combat/unit_lines/rs_unit_lines_feature.lua')
    dofile('features/combat/range_assist/rs_range_assist_feature.lua')
    dofile('presentation/v3/widgets/rs_v3_combat_visual_guides.lua')
    local R=S.Features.combat_range_assist
    local G=S.UIV3.CombatVisualGuidesV3
    if not dormant then
        assert(R:Initialize());assert(R:Enable())
        R.State.circles={}
        for i,count in ipairs(counts or {24}) do R.State.circles[i]=Circle(i,count) end
        S.FeatureRuntime.state[R.Id]={initialized=true,enabled=true}
        assert(G:Reconcile('test_start'))
    end
    assert(S.Scheduler:Start())
    function c:Step(ms)driver.update(driver,ms)end
    return S,R,G,c,disk
end

Test('32ms target does not become every second 33ms frame', function()
    local S,R,G,c=Boot({96})
    for i=1,12 do c:Step(1000/30) end
    assert(R.RangeRefreshHealth.attempts==12,'callback division refreshed only '..tostring(R.RangeRefreshHealth.attempts)..'/12 frames')
end)
Test('48ms target refreshes once per 100ms frame not every 300ms', function()
    local S,R,G,c=Boot({192})
    for i=1,10 do c:Step(100) end
    assert(R.RangeRefreshHealth.attempts==10,'callback division refreshed only '..tostring(R.RangeRefreshHealth.attempts)..'/10 slow frames')
end)
Test('hitch refreshes latest frame immediately without catch-up replay', function()
    local S,R,G,c=Boot({192})
    c:Step(16);local before=R.RangeRefreshHealth.attempts
    c.x=20;c:Step(200)
    assert(R.RangeRefreshHealth.attempts==before+1,'hitch was skipped by callback phase')
    local point=R.Authority.rows[1].points[1]
    assert(point.x==1430,'did not sample current world centre')
    local after=R.RangeRefreshHealth.attempts
    c:Step(16);c:Step(16)
    assert(R.RangeRefreshHealth.attempts==after,'replayed missed time after hitch')
end)
Test('small scheduler jitter does not add a fourth frame at 48ms', function()
    local S,R,G,c=Boot({192})
    for i=1,13 do c:Step(i%2==0 and 15.9 or 16.1) end
    assert(R.RangeRefreshHealth.attempts>=4 and R.RangeRefreshHealth.attempts<=5,'jitter stretched or sped up cadence')
end)
Test('ordinary 16ms callbacks retain three density tiers', function()
    for _,case in ipairs({{24,12},{96,6},{192,4}}) do
        local S,R,G,c=Boot({case[1]})
        for i=1,12 do c:Step(16) end
        assert(R.RangeRefreshHealth.attempts==case[2],case[1]..' tier changed nominal cadence')
        assert(S.Scheduler.tasks.v3_business_range_assist_refresh.intervalMs==16,'new scheduler/tick authority introduced')
    end
end)
Test('density change restarts phase on the next callback', function()
    local S,R,G,c=Boot({192});c:Step(16)
    R.State.circles[1].pointCount=24;c:Step(16)
    assert(R.RangeRefreshHealth.attempts==2 and #R.Authority.rows[1].points==24)
end)
Test('warm frames reuse trigonometric geometry but read current world coordinates', function()
    local S,R,G,c=Boot({96})
    local old=R:GetProjection()
    local sin,cos=math.sin,math.cos;local calls=0
    math.sin=function(x)calls=calls+1;return sin(x)end
    math.cos=function(x)calls=calls+1;return cos(x)end
    local ok,err=pcall(function()
        for i=1,5 do c.x=i;R.Authority:Refresh('warm_test') end
    end)
    math.sin,math.cos=sin,cos
    assert(ok,err);assert(calls==0,'warm frames recomputed '..calls..' trigonometric values')
    assert(R.Authority.rows[1].points[1].x==1355,'cached old world/screen point')
    assert(old.rows[1].points[1].x==1330,'detached projection mutated after new frame')
end)
Test('13 circles cannot round total projection budget above 192', function()
    local counts={};for i=1,13 do counts[i]=24 end
    local S,R,G,c=Boot(counts);local sum=0
    for _,row in ipairs(R.Authority.rows)do sum=sum+row.renderPointCount;assert(row.renderPointCount<=row.requestedPointCount)end
    assert(sum==192,'actual projected point count='..sum)
    for _,circle in ipairs(R.State.circles)do assert(circle.pointCount==24,'budget rewrote persisted density')end
end)
Test('budget keeps minimum triangle and never expands tiny circle', function()
    local S,R,G,c=Boot({192,3});local sum=0
    for _,row in ipairs(R.Authority.rows)do sum=sum+row.renderPointCount;assert(row.renderPointCount>=3 and row.renderPointCount<=row.requestedPointCount)end
    assert(sum==192 and R.Authority.rows[2].renderPointCount==3)
end)
Test('excess circle count keeps configurations and bounds physical work', function()
    local counts={};for i=1,65 do counts[i]=3 end
    local S,R,G,c=Boot(counts);local sum=0
    for _,row in ipairs(R.Authority.rows)do sum=sum+row.renderPointCount end
    assert(sum<=192 and #R.State.circles==65,'excess circle budget must not expand or delete config')
    assert(R:GetHealth().budgetLimitedCircles>=1,'budget omission must be explicit')
end)
Test('geometry cache invalidates on count enabled and configuration replacement', function()
    local S,R,G,c=Boot({24,24})
    R.State.circles[1].pointCount=58;R.State.circles[2].enabled=false
    R.Authority:Refresh('topology_change')
    assert(#R.Authority.rows==1 and #R.Authority.rows[1].points==58)
    R.State.circles={Circle(99,12)};R.State.circles[1].radius=20;c.x=10
    R.Authority:Refresh('replacement');local row=R.Authority.rows[1]
    assert(row.circleId==99 and row.points[1].x==1430 and #row.points==12)
end)
Test('last demand releases geometry and cadence phase without clearing settings', function()
    local S,R,G,c=Boot({192});c:Step(16)
    assert(R:ReleaseConsumer(G.rangeToken));G.rangeHeld=false
    assert(S.Scheduler.tasks.v3_business_range_assist_refresh==nil)
    assert(R.RangeGeometry==nil,'geometry cache retained after release')
    c.now=c.now+5000;assert(G:Reconcile('resume'));c:Step(16)
    assert(#R.State.circles==1 and R:GetHealth().refresh.lastGapMs~=5016,'disabled time counted as runtime stall')
end)
Test('unavailable world frame is recorded despite successful Lua callback', function()
    local S,R,G,c=Boot({24});c:Step(16);c.missingWorld=true;c:Step(16)
    local h=R:GetHealth()
    assert(h.status=='unavailable' and h.visiblePoints==0 and h.projectionFailures>=1)
    assert(h.refresh.failures==0,'Native no-data must not be forged as Lua exception')
    assert(h.lastFrameReason and h.lastFrameReason~='','missing failure cause')
end)
Test('empty frame clears previous render sampling', function()
    local S,R,G,c=Boot({24});assert(G.lastRangeSampling.points>0)
    c.missingWorld=true;c:Step(16)
    assert(G.lastRangeSampling.points==0 and G.lastRangeSampling.circles==0,'stale visible count survived empty frame')
    assert(not G.rangeHost.visible)
end)
Test('anchor rejection cannot be counted as visible placement', function()
    local S,R,G,c=Boot({24});c.failAnchor=true;c.x=20;c:Step(16)
    assert(G.lastRangeSampling.points==0,'rejected anchors reported as visible dots')
    assert(G.lastRangeSampling.placementFailures==24,'placement failure evidence missing')
    c.failAnchor=false;c:Step(16);assert(G.lastRangeSampling.points==24,'failed identical coordinate was not retried')
end)
Test('native Show rejection cannot be counted as visible placement', function()
    local S,R,G,c=Boot({24});G:HideRangePools();c.failShow=true;c:Step(16)
    assert(G.lastRangeSampling.points==0 and G.lastRangeSampling.placementFailures==24,'Show rejection counted as success')
end)
Test('source switches are visible without changing projection formulas', function()
    local S,R,G,c=Boot({24});c.native=false;c:Step(16)
    local h=R:GetHealth();assert(h.projectorSource=='camera' and h.sourceChanges>=1,'native/camera transition evidence missing')
    c.native=true;c:Step(16);assert(R:GetHealth().projectorSource=='native')
end)
Test('module report includes existing store refresh renderer and no Native work', function()
    local S,R,G,c,disk=Boot({24});c:Step(16)
    local reads,created,writes,storeReads=c.reads,c.created,disk.writes,disk.reads
    local report=assert(S.ModuleDiagnosticsHub:BuildReport(R.Id))
    assert(not report:find('featureHealth=not_sampled',1,true),'module still has no health')
    assert(report:find('range-continuity-1',1,true),'patch fingerprint missing')
    assert(report:find('provider.range_render=',1,true),'range render provider missing')
    assert(report:find('v3.business.combat_range_assist',1,true),'store ownership missing')
    assert(c.reads==reads and c.created==created and disk.writes==writes and disk.reads==storeReads,'diagnosis caused Native I/O or render work')
end)
Test('cold capture does not initialize enable acquire or create range resources', function()
    local S,R,G,c,disk=Boot({},true)
    local reads,created,storeReads=c.reads,c.created,disk.reads
    assert(S.ModuleDiagnosticsHub:BuildReport(R.Id))
    assert(R.enabled==false and not R.storeLoaded and (R.consumerCount or 0)==0)
    assert(c.reads==reads and c.created==created and disk.reads==storeReads)
    assert(S.Scheduler.tasks.v3_business_range_assist_refresh==nil)
end)
Test('health snapshots are detached from mutable cadence and batch facts', function()
    local S,R,G,c=Boot({24});c:Step(16)
    local h=R:GetHealth();local attempts=R.RangeRefreshHealth.attempts
    h.refresh.attempts=999;h.batch.native=999
    assert(R.RangeRefreshHealth.attempts==attempts and R:GetHealth().batch.native==24)
end)
Test('all disabled or no circles consume no world or projection reads', function()
    local S,R,G,c=Boot({24})
    R.State.circles[1].enabled=false;local reads=c.reads;c:Step(16)
    assert(c.reads==reads and #R.Authority.rows==0)
    R.State.circles={};reads=c.reads;c:Step(16)
    assert(c.reads==reads and R:GetHealth().circleCount==0 and R:GetHealth().status=='ready')
end)
Test('stalled clock is explicit and cannot freeze a new elapsed-time gate', function()
    local S,R,G,c=Boot({192});S.NowMs=function()return 16 end
    for i=1,10 do c:Step(16) end
    assert(R.RangeRefreshHealth.attempts>=3,'unchanging timestamp froze range refresh')
    assert(R:GetHealth().refresh.clockStatus=='stalled','stalled clock was reported healthy')
end)
Test('missing clock falls back without inventing measured refresh gaps', function()
    local S,R,G,c=Boot({192});S.NowMs=nil
    for i=1,10 do c:Step(16) end
    local h=R:GetHealth()
    assert(h.refresh.attempts>=3 and h.refresh.clockStatus=='unavailable' and h.refresh.lastGapMs==nil)
end)
Test('clock rollback resumes and does not report a negative runtime gap', function()
    local S,R,G,c=Boot({192});c:Step(16);c:Step(16);local attempts=R.RangeRefreshHealth.attempts
    c.now=-10
    for i=1,4 do c:Step(16) end
    local h=R:GetHealth();assert(h.refresh.attempts>attempts and (h.refresh.lastGapMs==nil or h.refresh.lastGapMs>=0))
end)
Test('budget omission is not misreported as Native projection failure', function()
    local counts={};for i=1,65 do counts[i]=3 end
    local S,R,G,c=Boot(counts);local h=R:GetHealth()
    assert(h.status=='partial' and h.budgetLimitedCircles==1)
    assert(h.projectionFailures==0,'budget-only omission counted as projection failure')
end)
Test('refresh exceptions hide old output and recover using the same task', function()
    local S,R,G,c=Boot({24});local service=S.Services.ScreenProjectionV3
    local read=service.GetUnitWorldPosition
    service.GetUnitWorldPosition=function()error('injected world boundary exception')end
    c:Step(16)
    local h=R:GetHealth();assert(h.refresh.failures==1 and h.status=='unavailable' and G.lastRangeSampling.points==0)
    service.GetUnitWorldPosition=read;c:Step(16)
    h=R:GetHealth();assert(h.refresh.failures==1 and h.refresh.consecutiveFailures==0 and h.visiblePoints==24 and G.lastRangeSampling.points==24)
end)
Test('partial pool creation failure hides stale frame and next tick retries', function()
    local S,R,G,c=Boot({24});local create=S.UI.CreateLabel
    S.UI.CreateLabel=function()return nil,'injected label failure' end
    R.State.circles[1].pointCount=58;c:Step(16)
    assert(G.lastRangeSampling.points==0 and G.lastRangeSampling.status=='unavailable' and not G.rangeHost.visible)
    S.UI.CreateLabel=create;c:Step(32)
    assert(G.lastRangeSampling.points==58,'transient pool failure stopped automatic retry')
end)
Test('disable stops Native sampling and releases cache but preserves every setting', function()
    local S,R,G,c=Boot({58,24});local first=R.State.circles[1]
    assert(R:Disable('test_disable'));assert(G:Reconcile('test_disable'))
    local reads=c.reads;for i=1,12 do c:Step(100) end
    assert(c.reads==reads and R.RangeGeometry==nil and R.State.circles[1]==first)
    assert(G.lastRangeSampling.points==0 and not G.rangeHost.visible)
    assert(R:Enable());assert(G:Reconcile('test_enable'));c:Step(16)
    assert(#R.Authority.rows==2 and R.Authority.rows[1].renderPointCount==58)
end)
Test('mixed circle densities stay deterministic and within exact total budget', function()
    local S,R,G,c=Boot({24})
    for case=1,16 do
        local circles,requested={},0
        for i=1,case*4 do local count=3+(case*11+i*17)%190;circles[i]=Circle(i,count);requested=requested+count end
        R.State.circles=circles;R.Authority:Refresh('budget_matrix')
        local sum=0
        for i,row in ipairs(R.Authority.rows)do
            assert(row.renderPointCount>=3 and row.renderPointCount<=circles[i].pointCount)
            sum=sum+row.renderPointCount
        end
        assert(sum==math.min(192,requested),'budget conservation failed at case '..case)
        assert(R.RangeLastBatch.total==sum,'projector received a different point budget')
    end
end)
Test('no target FOV failure hides false-size frame and recovers unchanged settings',function()
    local S,R,G,c,disk=Boot({24,24});c.native=false;c.fov=math.pi/3;c:Step(16)
    local row=R.Authority.rows[1];local x=row.points[1].x
    local writes,created=disk.writes,c.created
    c.fov=nil;c:Step(16)
    assert(G.lastRangeSampling.points==0,'invalid-FOV frame still displayed')
    assert(R:GetHealth().batch.frameErr=='camera_fov_unavailable')
    c.fov=math.pi/3;c:Step(16)
    assert(G.lastRangeSampling.points==48,'valid frame failed to recover')
    assert(math.abs(R.Authority.rows[1].points[1].x-x)<0.00001,'radius did not recover')
    assert(R.State.circles[1].radius==10 and R.State.circles[2].radius==10)
    assert(disk.writes==writes and c.created==created,'projection caused persistence or widget rebuild')
end)
Test('Native whole batch remains usable without a camera FOV',function()
    local S,R,G,c=Boot({24});c.fov=nil;c:Step(16)
    assert(G.lastRangeSampling.points==24 and R:GetHealth().projectorSource=='native')
end)
Test('no target coherent world height change preserves relative ring geometry',function()
    local S,R,G,c=Boot({24});c.native=false;c:Step(16)
    local before=R:GetProjection().rows[1]
    c.z=100;c.cameraZ=105;c:Step(16)
    local after=R:GetProjection().rows[1]
    assert(after.worldRadius==10 and after.projectionScale==1 and before.worldRadius==10)
    for i,point in ipairs(after.points) do
        assert(math.abs(point.x-before.points[i].x)<0.00001 and math.abs(point.y-before.points[i].y)<0.00001,
            'coherent height offset stretched ring at point '..i)
    end
end)
Test('camera evidence is bounded detached and capture does no new Native work',function()
    local S,R,G,c,disk=Boot({24});c.native=false
    for i=1,24 do c.cameraZ=5+i/10;c:Step(500) end
    local h=R:GetHealth();assert(#h.projectionSamples==12,'unbounded/empty evidence')
    assert(h.batch.cameraFov==c.fov and h.batch.cameraPosition.z==c.cameraZ)
    assert(h.metric.lastSample and h.metric.lastSample.worldScaleStatus~='accepted','no target invented calibration')
    h.projectionSamples[1].cameraFov=99;h.metric.projectionScale=99
    assert(R:GetHealth().projectionSamples[1].cameraFov~=99 and R:GetHealth().metric.projectionScale==1)
    local reads,writes=c.reads,disk.writes
    local report=assert(S.ModuleDiagnosticsHub:BuildReport(R.Id))
    assert(report:find('range-projection-stability-1',1,true) and report:find('cameraAnchorDistance',1,true))
    assert(reads==c.reads and writes==disk.writes,'report caused Native or persistence IO')
end)
Test('22-unit circle crossing close camera plane submits only in-viewport dots',function()
    -- 取报告中的 R22/40点、R5/23点、FOV与相机高差；水平朝向为模型输入，非现场完整重放。
    local S,R,G,c,disk=Boot({40,23})
    c.native=false;c.z=118.581;c.cameraZ=123.79;c.cameraY=22.086
    c.cameraDir={x=0,y=0.847,z=-0.531};c.fov=1.82387
    R.State.circles[1].radius=22;R.State.circles[2].radius=5
    local writes=disk.writes;c:Step(32)
    local h=R:GetHealth();local sample=G.lastRangeSampling
    assert(h.batch.cameraRejected>0,'model did not cross camera plane')
    assert(sample.offscreenPoints and sample.offscreenPoints>0,'offscreen projection was counted as visible')
    assert(sample.points>0 and sample.points<sample.requestedPoints,'valid range arcs lost/false-size points retained')
    for _,pool in pairs(G.rangePools) do for _,dot in ipairs(pool) do
        if dot.root.visible then
            assert(dot.root.x>=0 and dot.root.x<=c.width and dot.root.y>=0 and dot.root.y<=c.height,
                'out-of-viewport coordinate reached Native anchor')
        end
    end end
    assert(sample.placementFailures==0 and sample.status=='ready','ordinary culling was reported as a fault')
    assert(R.State.circles[1].radius==22 and R.State.circles[2].radius==5 and writes==disk.writes)
    assert(h.batch.cameraRejectedBehind>0 and h.batch.cameraDirection and h.batch.anchorWorld,'plane evidence missing')
end)
Test('fully offscreen circle clears old pool and never clamps dots to edges',function()
    local S,R,G,c=Boot({24});local projection=R:GetProjection()
    projection.rows[1].points={{x=7425,y=2209},{x=8000,y=2209},{x=9000,y=2209}}
    projection.viewportWidth=c.width;projection.viewportHeight=c.height
    -- 中文维护：屏外注入走Presenter现用的独立绘制快照；断言与输入坐标保持不变。
    R.GetRenderProjection=function()return projection end
    local placements=c.placements;assert(G:RenderRange())
    assert(G.lastRangeSampling.points==0 and G.lastRangeSampling.offscreenPoints==3)
    assert(G.lastRangeSampling.placementFailures==0 and not G.rangeHost.visible)
    assert(c.placements==placements,'clipped points were written/clamped to Native anchors')
end)
Test('invalid range screen coordinates are rejected before Native anchors',function()
    local S,R,G,c=Boot({24});local projection=R:GetProjection()
    projection.rows[1].points={{x=math.huge,y=0},{x=0/0,y=0},{x=100,y=100}}
    R.GetRenderProjection=function()return projection end
    local placements=c.placements;assert(G:RenderRange())
    assert(G.lastRangeSampling.points==1 and G.lastRangeSampling.invalidPoints==2)
    assert(c.placements==placements+1,'non-finite point reached Native anchor')
end)
Test('unknown viewport preserves finite coordinates without guessing logical bounds',function()
    local S,R,G,c=Boot({24});local projection=R:GetProjection()
    projection.rows[1].points={{x=7425,y=2209},{x=8000,y=2209},{x=9000,y=2209}}
    projection.viewportWidth=nil;projection.viewportHeight=nil
    R.GetRenderProjection=function()return projection end
    S.Services.ScreenProjectionV3.GetUiParentViewport=function()return nil,nil end
    assert(G:RenderRange())
    assert(G.lastRangeSampling.points==3 and G.lastRangeSampling.viewportKnown==false)
end)
print('RANGE CONTINUITY RESULT '..passed..' passed / '..failed..' failed ('.._VERSION..')')
if failed>0 then error('range continuity regressions failed: '..failed) end

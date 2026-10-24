------------------------------------------------------------------------
-- 战斗视觉引导性能契约：真实 Feature/Service/Presenter；仅 Native/UI/时钟由宿主替换。
-- 不进 toc，不访问 UDF。操作计数检查每行样式解析，不把离线耗时当成 RU 帧率。
------------------------------------------------------------------------
local passed,failed=0,0
local function Test(name,fn)
    local ok,err=xpcall(fn,debug.traceback)
    if ok then passed=passed+1;print('PASS visual-guides-performance '..name)
    else failed=failed+1;print('FAIL visual-guides-performance '..name..': '..tostring(err))end
end
local H=dofile('tools/rs_udf_numeric_test_host.lua')
local function Boot()
    local c={width=2559,height=1439,originX=0,originY=0,uiScale=1,revision=1,now=0,
        failAnchor=false,failShow=false,failFont=false,anchors=0,fonts=0,shows=0,reads=0,created=0,
        screen={player={300,400,1},target={900,600,1}},world={player={0,10,0},target={10,10,0}}}
    X2Unit={GetUnitScreenPosition=function(_,token)c.reads=c.reads+1;local p=c.screen[token];if p then return p[1],p[2],p[3]end end,
        GetUnitWorldPositionByTarget=function(_,token)c.reads=c.reads+1;local p=c.world[token];if p then return p[1],p[2],p[3]end end}
    UIParent={GetScreenWidth=function()return c.width end,GetScreenHeight=function()return c.height end,
        GetViewCameraPos=function()return{x=0,y=0,z=0}end,GetViewCameraDir=function()return{x=0,y=1,z=0}end,
        GetViewCameraFov=function()return 1.57 end}
    ConvertWorldToScreen=function(x,y,z)return 500+x,400+y,1 end
    local S,_,disk=H.Boot()
    S.NowMs=function()return c.now end
    S.FeatureRuntime.IsEnabled=function(_,id)return S.Features[id]and S.Features[id].enabled==true end
    S.Scheduler={tasks={},AddHighFrequencyTask=function(self,id,ms,fn)self.tasks[id]={ms=ms,fn=fn};return true end,
        RemoveTask=function(self,id)self.tasks[id]=nil;return true end,SetTaskModule=function()return true end}
    S.Layout={GetContext=function()return{screenWidth=c.width,screenHeight=c.height,logicalWidth=c.width/c.uiScale,
        logicalHeight=c.height/c.uiScale,uiScale=c.uiScale,addonScale=1.7}end,
        GetUiParentLocalOrigin=function()return c.originX,c.originY,true end,
        GetUiEnvironmentRevision=function()return c.revision,'test' end}
    local UI=S.UI
    UI.NativeStateCache={}
    UI.CreateOverlayWindow=function()c.created=c.created+1;return{visible=false}end
    UI.CreateLabel=function()c.created=c.created+1;local w={visible=false};UI.NativeStateCache[w]={fontSize=15};return w end
    UI.EnsureVisible=function(_,w,v)
        c.shows=c.shows+1
        if not w or(c.failShow and v)then return false,false,'rejected'end
        local changed=w.visible~=v;w.visible=v;return true,changed
    end
    UI.SetVisible=function(self,w,v)local accepted,changed=self:EnsureVisible(w,v);return accepted and changed end
    UI.EnsureAnchor=function(_,w,parent,x,y)
        c.anchors=c.anchors+1;if c.failAnchor then return false,false,'rejected'end
        local changed=w.x~=x or w.y~=y;w.x,w.y=x,y;return true,changed
    end
    UI.SetAnchor=function(self,...)local accepted=self:EnsureAnchor(...);return accepted end
    UI.SetFontSize=function(_,w,size)
        c.fonts=c.fonts+1;if c.failFont then return false end
        UI.NativeStateCache[w]=UI.NativeStateCache[w]or{};UI.NativeStateCache[w].fontSize=size;w.fontSize=size;return true
    end
    UI.SetColor=function(_,w,r,g,b,a)w.color={r,g,b,a};return true end
    UI.NativeVisibleReadback=function(_,w)return w and w.visible or false,w~=nil end
    UI.InvalidateNativeState=function(_,w)UI.NativeStateCache[w]=nil end
    dofile('services/rs_screen_projection_v3.lua')
    dofile('features/shared/rs_feature_slice_factory.lua')
    dofile('features/shared/rs_shared_bounds.lua')
    dofile('features/combat/unit_lines/rs_unit_lines_feature.lua')
    dofile('features/combat/range_assist/rs_range_assist_feature.lua')
    dofile('presentation/v3/widgets/rs_v3_combat_visual_guides.lua')
    return S,S.UIV3.CombatVisualGuidesV3,S.Features.combat_unit_lines,S.Features.combat_range_assist,c,disk
end
local function UnitRows(F,count)
    F.Authority.status='ready';F.Authority.rows={};F.State.opacity=0.37;F.State.refreshMs=16
    for i,key in ipairs({'target','targettarget','focus','focustarget'})do
        F.State.pairPoints[key]=count or 160;F.State.pairSizes[key]=7
        F.Authority.rows[i]={key='unit_line:'..key,pairKey=key,x1=40,y1=100*i,x2=1200,y2=100*i+20}
    end
end
local function RangeRows(F,count)
    F.Authority.status='ready';F.Authority.rows={};F.State.circles={}
    for i=1,3 do
        F.State.circles[i]={id=i,enabled=true}
        local points={};for j=1,count or 64 do points[j]={x=300+j*2,y=150*i+j}end
        F.Authority.rows[i]={key='self_radius_'..i,circleKey='circle_'..i,points=points,
            pointSize=7,opacity=0.37,color={0.2,0.82,1}}
    end
end
local function Warm(P,kind)
    assert(P:EnsureHost(kind));P[kind=='unit'and'unitHeld'or'rangeHeld']=true
    for i=1,20 do
        if kind=='unit'then assert(P:RenderUnit())else assert(P:RenderRange())end
    end
end
local function CountStyle(fn)
    local min,number=math.min,tonumber
    local sizes,opacity=0,0
    math.min=function(a,b,...)if a==24 and b==7 then sizes=sizes+1 end;return min(a,b,...)end
    tonumber=function(value,...)if value==0.37 then opacity=opacity+1 end;return number(value,...)end
    local ok,err=pcall(fn);math.min,tonumber=min,number;assert(ok,err)
    return sizes,opacity
end
local function NumericStrings(fn)
    local original=tostring;local calls=0
    tostring=function(value)if type(value)=='number'then calls=calls+1 end;return original(value)end
    local ok,err=pcall(fn);tostring=original;assert(ok,err);return calls
end
local function ReferenceUnique(P,c)
    assert(c.originX==0 and c.originY==0)
    local seen,n={},0
    for _,pool in pairs(P.unitPools)do for _,dot in ipairs(pool)do if dot.root.visible then
        local key=tostring(dot.root.x)..','..tostring(dot.root.y)
        if not seen[key]then seen[key]=true;n=n+1 end
    end end end
    return n
end
Test('unit style parsing scales with four rows instead of 640 dots',function()
    local S,P,U=Boot();UnitRows(U);Warm(P,'unit')
    local size,alpha=CountStyle(function()assert(P:RenderUnit())end)
    assert(size<=8 and alpha<=4,'per-dot style parsing size='..size..' opacity='..alpha)
    assert(P.lastUnitSampling.visibleDots==640)
end)
Test('range style parsing scales with three rows instead of 192 dots',function()
    local S,P,U,R=Boot();RangeRows(R);Warm(P,'range')
    local size,alpha=CountStyle(function()assert(P:RenderRange())end)
    assert(size<=3 and alpha<=3,'per-dot style parsing size='..size..' opacity='..alpha)
    assert(P.lastRangeSampling.points==192)
end)
Test('known small viewport avoids per-dot coordinate string diagnostics',function()
    local S,P,U=Boot();UnitRows(U);Warm(P,'unit')
    local calls=NumericStrings(function()assert(P:RenderUnit())end)
    assert(calls<32,'numeric tostring calls='..calls)
end)
Test('deduplication agrees with string reference across rounding duplicates and viewport boundaries',function()
    local S,P,U,R,c=Boot();UnitRows(U,24);Warm(P,'unit')
    for _,wh in ipairs({{2559,1439},{32768,32768},{32769,32769},{65536,65536}})do
        c.width,c.height=wh[1],wh[2]
        for frame=1,10 do
            for i,row in ipairs(U.Authority.rows)do row.x1=-0.75+frame/10;row.x2=c.width+0.75;row.y1=frame/3;row.y2=c.height-0.2 end
            assert(P:RenderUnit());assert(P.lastUnitSampling.uniquePositions==ReferenceUnique(P,c),'unique mismatch '..c.width)
        end
    end
end)
Test('unknown and oversized viewport retain negative coordinate string fallback',function()
    local S,P,U,R,c=Boot();UnitRows(U,24);Warm(P,'unit')
    S.Services.ScreenProjectionV3.GetUiParentViewport=function()return nil,nil end
    for _,row in ipairs(U.Authority.rows)do row.x1=-300.5;row.x2=-100.2;row.y1=-20.7;row.y2=30.1 end
    local calls=NumericStrings(function()assert(P:RenderUnit())end)
    assert(calls>=P.lastUnitSampling.visibleDots*2)
    assert(P.lastUnitSampling.uniquePositions==ReferenceUnique(P,c))
    S.Services.ScreenProjectionV3.GetUiParentViewport=function()return 65536,65536 end
    for _,row in ipairs(U.Authority.rows)do row.x1=0;row.x2=65535;row.y1=32768;row.y2=32768 end
    calls=NumericStrings(function()assert(P:RenderUnit())end)
    assert(calls>=P.lastUnitSampling.visibleDots*2)
    assert(P.lastUnitSampling.uniquePositions==ReferenceUnique(P,c))
end)
Test('runtime style host origin and UI environment changes apply on the next frame',function()
    local S,P,U,R,c=Boot();UnitRows(U,24);RangeRows(R,24);Warm(P,'unit');Warm(P,'range')
    c.originX,c.originY,c.uiScale,c.revision=21,33,0.5,2
    U.State.pairSizes.target=10;U.State.opacity=0.42;U.State.colors.target={0.1,0.2,0.3}
    R.Authority.rows[1].pointSize=2;R.Authority.rows[1].opacity=0.55;R.Authority.rows[1].color={0.6,0.7,0.8}
    assert(P:RenderUnit());assert(P:RenderRange())
    local u,r=P.unitPools.target[1],P.rangePools.circle_1[1]
    assert(u.root.x==19 and u.root.y==67 and u.root.fontSize==40 and u.root.color[1]==0.1 and u.root.color[4]==0.42)
    assert(r.root.x==281 and r.root.y==118 and r.root.fontSize==16 and r.root.color[1]==0.6 and r.root.color[4]==0.55)
end)
Test('anchor visibility and font refusals retry unchanged dots on the next frame',function()
    local S,P,U,R,c=Boot();UnitRows(U,24);RangeRows(R,24);Warm(P,'unit');Warm(P,'range')
    for _,kind in ipairs({'unit','range'})do
        local pool=kind=='unit'and P.unitPools.target or P.rangePools.circle_1
        local dot=pool[1];dot.renderState.x=nil;c.failAnchor=true
        if kind=='unit'then assert(P:RenderUnit())else assert(P:RenderRange())end
        assert(dot.renderState.x==nil and not dot.root.visible)
        c.failAnchor=false;c.failShow=true
        if kind=='unit'then assert(P:RenderUnit())else assert(P:RenderRange())end
        assert(not dot.root.visible and dot.renderState.visible==false)
        c.failShow=false
        if kind=='unit'then assert(P:RenderUnit())else assert(P:RenderRange())end
        assert(dot.root.visible)
        S.UI.NativeStateCache[dot.root].fontSize=15;c.failFont=true
        local attempts=c.fonts
        if kind=='unit'then assert(P:RenderUnit())else assert(P:RenderRange())end
        assert(c.fonts>attempts)
        assert(S.UI.NativeStateCache[dot.root].fontSize==15)
        c.failFont=false;attempts=c.fonts
        if kind=='unit'then assert(P:RenderUnit())else assert(P:RenderRange())end
        assert(c.fonts>attempts and S.UI.NativeStateCache[dot.root].fontSize==31)
    end
end)
Test('public raw placement methods preserve conversion defaults and rejection results',function()
    local S,P,U,R,c=Boot();assert(P:EnsureHost('unit'));assert(P:EnsureHost('range'))
    local u,r={root={visible=false}},{root={visible=false}}
    local transform={originX='21',originY='33'}
    local aw,sw,vw,placed=P:PlaceUnitDot(u,'500','400','7','0.37','target',nil,nil,nil,transform)
    assert(placed and u.root.x==479 and u.root.y==367 and u.root.fontSize==31 and u.root.color[4]==0.37)
    assert(P:PlaceDot(r,'500','400','7','0.37','range',nil,nil,nil,nil,transform))
    assert(r.root.x==479 and r.root.y==367 and r.root.fontSize==31 and r.root.color[4]==0.37)
    c.failAnchor=true;u.renderState.x=nil;r.renderState.x=nil
    aw,sw,vw,placed=P:PlaceUnitDot(u,500,400,7,0.37,'target',nil,nil,nil,transform)
    assert(placed==false and u.renderState.x==nil and not u.root.visible)
    assert(P:PlaceDot(r,500,400,7,0.37,'range',nil,nil,nil,nil,transform)==false and r.renderState.x==nil)
    assert(P:PlaceUnitDot(nil,0,0,4,1)==0 and P:PlaceDot(nil,0,0,4,1)==false)
end)
Test('invalid behind and lost targets never keep old output or skip fresh service reads',function()
    local S,P,U,R,c=Boot();assert(U:Initialize());assert(U:Enable())
    U.State.showTargetTarget=false;U.State.showFocusTarget=false;U.State.showFocusTargetTarget=false
    assert(U:AcquireConsumer('performance_test'));P.unitHeld=true;assert(P:EnsureHost('unit'));assert(P:RenderUnit())
    local reads=c.reads;assert(U.Authority:Refresh('same_frame'));assert(c.reads>reads)
    c.screen.target[3]=-1;assert(U.Authority:Refresh('behind'));assert(P:RenderUnit());assert(P.lastUnitSampling.visibleDots==0)
    c.screen.target=nil;c.world.target=nil;assert(U.Authority:Refresh('lost'));assert(P:RenderUnit());assert(P.lastUnitSampling.visibleDots==0)
    U.Authority.rows={{pairKey='target',x1=0,y1=0,x2=0/0,y2=10},{pairKey='focus',x1=0,y1=0,x2=math.huge,y2=10}}
    assert(P:RenderUnit());assert(P.lastUnitSampling.uniquePositions==0)
end)
Test('release disable and fresh reload retain no prepared style state or visible old pools',function()
    local S,P,U,R,c,disk=Boot();UnitRows(U,24);RangeRows(R,24);Warm(P,'unit');Warm(P,'range')
    P.unitHeld=false;P.rangeHeld=false;assert(P:RenderUnit());assert(P:RenderRange())
    assert(not P.unitHost.visible and not P.rangeHost.visible and P.unitRenderPlanCache==nil)
    for _,pools in ipairs({P.unitPools,P.rangePools})do for _,pool in pairs(pools)do for _,dot in ipairs(pool)do assert(not dot.root.visible)end end end
    assert(U:Initialize());assert(U:Enable());assert(U:AcquireConsumer('performance_test'));assert(U:ReleaseConsumer('performance_test'));assert(U:Disable())
    assert(S.Scheduler.tasks.v3_business_unit_lines_refresh==nil)
    local S2,P2,U2,R2,c2=Boot();assert(P2~=P and P2.unitHeld==false and P2.rangeHeld==false and next(P2.unitPools)==nil)
    UnitRows(U2,24);Warm(P2,'unit');assert(P2.unitPools.target[1].root.fontSize==31)
    assert(disk.writes==0 and disk.clears==0)
end)
print(string.format('VISUAL GUIDES PERFORMANCE RESULT %d passed / %d failed (%s)',passed,failed,_VERSION))
if failed>0 then os.exit(1)end

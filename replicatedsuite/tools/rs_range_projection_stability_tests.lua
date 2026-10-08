-- 维护（2026-10-07）：真实 ScreenProjection；仅替换 Native 相机/单位输入。
-- 反例覆盖无目标时 FOV 默认替换/旧标定重置，以及高度样本越过米标定拒绝。
-- 不读取真实存档，不把模型坐标当作 RU 实机证据。
local passed, failed = 0, 0
local function Test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then passed=passed+1; print('PASS range-stability '..name)
    else failed=failed+1; print('FAIL range-stability '..name..': '..tostring(err)) end
end
local function Near(actual, expected, label)
    assert(type(actual)=='number' and math.abs(actual-expected)<0.00001,
        tostring(label)..' expected '..tostring(expected)..' got '..tostring(actual))
end
local function Boot()
    local c={now=0,fov=math.pi/2,hasTarget=true,target={x=30,y=0,z=0},scale=1.5,reads=0}
    UIParent={GetScreenWidth=function()return 1920 end,GetScreenHeight=function()return 1080 end,
        GetViewCameraPos=function()return {x=0,y=-100,z=5} end,
        GetViewCameraDir=function()return {x=0,y=1,z=0} end,
        GetViewCameraFov=function()return c.fov end}
    X2Unit={GetUnitWorldPositionByTarget=function(_,token)
        if token=='player' then return 0,0,0 end
        if token=='target' and c.hasTarget then return c.target.x,c.target.y,c.target.z end
    end,UnitDistance=function(_,token)
        if token=='target' and c.hasTarget then
            return {distance=math.sqrt(c.target.x^2+c.target.y^2+c.target.z^2)}
        end
    end,GetUnitScreenPosition=function(_,token)
        if token=='player' then return 960,540,1 end
        if token=='target' and c.hasTarget and c.fov then
            -- 完全一致的镜头，仅 Native 相对向量使用可控的坐标比例。
            local factor=540/math.tan(c.fov/2)
            local ax,ay=960,540+4.75/100*factor
            local tx=960+c.target.x/(100+c.target.y)*factor
            local ty=540-(c.target.z-4.75)/(100+c.target.y)*factor
            return 960+(tx-ax)*c.scale,540+(ty-ay)*c.scale,1
        end
    end}
    ReplicatedSuite={Services={},NowMs=function()return c.now end,Api={
        GetUiMetrics=function()return 1920,1080,1,1920,1080 end,
        CallCapability=function(_,cap,obj,method,...)
            c.reads=c.reads+1
            local ok,a,b,d=pcall(obj[method],obj,...)
            if ok then return true,a,nil,b,d end
            return false,nil,tostring(a)
        end,
        CallGlobalCapability=function()return false,nil,'native_unavailable' end,
    }}
    dofile('services/rs_screen_projection_v3.lua')
    local P=ReplicatedSuite.Services.ScreenProjectionV3
    function c:Measure()
        self.now=self.now+500
        return P:GetRangeMetricCalibration({anchorWorld={x=0,y=0,z=0},aspectSafeCamera=true,forceSample=true})
    end
    function c:Ring(scale)
        return P:ProjectWorldBatch({{x=10,y=0,z=0.25},{x=-10,y=0,z=0.25}},
            {easyPullCompat=true,rigidBatch=true,aspectSafeCamera=true,anchorUnit='player',
            anchorWorld={x=0,y=0,z=0.25},metricScreenScale=scale or 1})
    end
    return P,c
end

Test('no target and transient missing FOV cannot draw a different assumed radius',function()
    local P,c=Boot(); c.hasTarget=false
    c.fov=math.pi/3;local before=c:Ring()
    assert(before[1].visible and before[2].visible)
    c.fov=nil;local rows,source,facts=c:Ring()
    assert(rows[1].visible==false and rows[2].visible==false,
        'unknown FOV produced a default-FOV ring with another screen radius')
    assert(facts.frameErr=='camera_fov_unavailable','missing explicit FOV reason')
    c.fov=math.pi/3;local after=c:Ring()
    Near(after[1].x,before[1].x,'recovered point')
end)
Test('no target and changing FOV retain calibrated coordinate scale',function()
    local P,c=Boot();local before=c:Measure();Near(before.projectionScale,1.5,'initial scale')
    c.hasTarget=false;c.fov=math.pi/3
    local after=c:Measure();Near(after.projectionScale,1.5,'FOV changed without target')
    assert(after.projectionScaleStatus=='calibrated','calibration reset despite same coordinate space')
    local rows=c:Ring(after.projectionScale)
    Near(rows[1].x-rows[2].x,108/math.tan(c.fov/2)*1.5,'current camera perspective')
end)
Test('missing FOV does not discard old calibrated scale',function()
    local P,c=Boot();Near(c:Measure().projectionScale,1.5,'initial scale')
    c.hasTarget=false;c.fov=nil;local after=c:Measure()
    Near(after.projectionScale,1.5,'scale during unknown FOV')
    assert(after.lastSample.projectionScaleReason=='camera_fov_unavailable')
end)
Test('high target cannot alter screen scale after world metric rejection',function()
    local P,c=Boot();Near(c:Measure().projectionScale,1.5,'baseline')
    c.target={x=30,y=0,z=40};c.scale=2.5
    for i=1,6 do
        local sample=c:Measure()
        assert(sample.lastSample.worldScaleStatus=='rejected','height metric should be rejected')
        assert(sample.lastSample.projectionScaleStatus~='accepted','height sample changed screen calibration')
        Near(sample.projectionScale,1.5,'retained screen scale')
    end
end)
Test('too close target cannot alter screen scale after metric rejection',function()
    local P,c=Boot();c:Measure();c.target={x=2.5,y=0,z=0};c.scale=2.5
    local after=c:Measure()
    assert(after.lastSample.worldScaleReason=='target_too_close')
    assert(after.lastSample.projectionScaleStatus~='accepted','close sample was accepted')
    Near(after.projectionScale,1.5,'close sample retained scale')
end)
Test('invalid FOV is rejected on the range path',function()
    for _,fov in ipairs({0,-1,math.pi,10}) do
        local P,c=Boot();c.hasTarget=false;c.fov=fov
        local rows,_,facts=c:Ring()
        assert(rows[1].visible==false and facts.frameErr=='camera_fov_invalid','invalid FOV '..tostring(fov)..' was drawn')
    end
end)
Test('ordinary camera zoom continues to change perspective without target',function()
    local P,c=Boot();c.hasTarget=false
    local a=c:Ring();c.fov=math.pi/3;local b=c:Ring()
    Near((b[1].x-b[2].x)/(a[1].x-a[2].x),math.sqrt(3),'perspective ratio')
end)
Test('legacy EasyPull caller keeps its original unavailable-FOV fallback',function()
    local P,c=Boot();c.hasTarget=false;c.fov=nil
    local rows=P:ProjectWorldBatch({{x=10,y=0,z=0.25}}, {easyPullCompat=true})
    assert(rows[1].visible==true,'range-specific validation changed other projector contracts')
end)
Test('batch captures camera and anchor geometry without further Native reads',function()
    local P,c=Boot();c.hasTarget=false
    local _,_,facts=c:Ring()
    Near(facts.cameraFov,math.pi/2,'FOV telemetry')
    Near(facts.cameraAnchorForward,100,'camera anchor forward')
    Near(facts.cameraAnchorDistance,math.sqrt(10000+4.75^2),'camera anchor distance')
    Near(facts.anchorWorldZ,0.25,'anchor height')
    assert(facts.cameraPosition.x==0 and facts.cameraPosition.y==-100 and facts.cameraPosition.z==5)
    local reads=c.reads;P:GetHealth();assert(c.reads==reads,'health getter queried Native')
end)
print('RANGE STABILITY RESULT '..passed..' passed / '..failed..' failed ('.._VERSION..')')
assert(failed==0,tostring(failed)..' range stability regressions')

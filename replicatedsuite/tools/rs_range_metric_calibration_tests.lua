-- 中文维护回归（2026-09-15）：范围辅助的“米”必须以 X2Unit:UnitDistance 为事实 Authority，
-- 世界坐标仅作为几何载体；EasyPull Camera fallback 若与 Native Screen 的焦距尺度不一致，
-- 只能在玩家 Native 锚点周围做整批等比校准，禁止写死倍率或逐点猜测。
local passed, failed = 0, 0
local function Test(name, fn)
    local ok, err = pcall(fn)
    if ok then passed=passed+1; print('PASS range-metric '..name)
    else failed=failed+1; print('FAIL range-metric '..name..': '..tostring(err)) end
end
local function Near(actual, expected, eps, label)
    actual,expected=tonumber(actual),tonumber(expected)
    assert(actual~=nil and expected~=nil,(label or 'value')..' missing')
    assert(math.abs(actual-expected) <= (eps or 0.001),string.format('%s expected %.6f got %.6f',label or 'value',expected,actual))
end

local nowMs = 1000
local screenW, screenH = 1920, 1080
local targetWorldX = 60
local targetDistanceMeters = 30
local nativeTargetX = 1365 -- Camera math gives 1284, so Native vector is exactly 1.25x.
local callCounts = {}

X2Unit = {
    GetUnitWorldPositionByTarget = function(self, token, isLocal)
        if token == 'player' then return 0,0,0,0 end
        if token == 'target' then return targetWorldX,0,0,0 end
        return nil,nil,nil,nil
    end,
    UnitDistance = function(self, token)
        if token == 'target' then return { distance = targetDistanceMeters } end
        return nil
    end,
    GetUnitScreenPosition = function(self, token)
        if token == 'player' then return 960,540,1 end
        if token == 'target' then return nativeTargetX,540,1 end
        return nil,nil,nil
    end,
}
UIParent = {
    GetViewCameraPos = function() return {x=0,y=-100,z=0} end,
    GetViewCameraDir = function() return {x=0,y=1,z=0} end,
    GetViewCameraFov = function() return math.pi/2 end,
    GetScreenWidth = function() return screenW end,
    GetScreenHeight = function() return screenH end,
}
ReplicatedSuite = {
    Services = {}, BootError = nil,
    NowMs = function() return nowMs end,
    Api = {
        GetUiMetrics = function() return screenW,screenH,1,screenW,screenH end,
        CallCapability = function(self, capability, object, method, ...)
            callCounts[capability]=(callCounts[capability] or 0)+1
            local fn=object and object[method]
            if type(fn)~='function' then return false,nil,'missing_method' end
            local ok,a,b,c,d=pcall(fn,object,...)
            if not ok then return false,nil,tostring(a) end
            return true,a,nil,b,c,d
        end,
        CallGlobalCapability = function(self, capability, ...)
            callCounts[capability]=(callCounts[capability] or 0)+1
            return false,nil,'native_projector_unavailable'
        end,
    },
}

dofile('services/rs_screen_projection_v3.lua')
local P=assert(ReplicatedSuite.Services.ScreenProjectionV3)

Test('raw sample converts world units to official game meters',function()
    assert(type(P.MeasureRangeMetricCalibration)=='function','MeasureRangeMetricCalibration missing')
    local sample=assert(P:MeasureRangeMetricCalibration({anchorUnit='player',targetUnit='target',anchorWorld={x=0,y=0,z=0},worldZOffset=0.25}))
    assert(sample.worldScaleStatus=='accepted','world scale not accepted: '..tostring(sample.worldScaleStatus)..'/'..tostring(sample.reason))
    Near(sample.worldUnitsPerMeter,2,0.0001,'worldUnitsPerMeter')
    Near(sample.gameDistanceMeters,30,0.0001,'gameDistanceMeters')
    Near(sample.worldDistanceUnits,60,0.0001,'worldDistanceUnits')
    assert(sample.projectionScaleStatus=='accepted','projection scale not accepted: '..tostring(sample.projectionScaleStatus)..'/'..tostring(sample.projectionScaleReason))
    Near(sample.projectionScale,1.25,0.0001,'projectionScale')
    assert((tonumber(sample.projectionResidualRatio) or 1)<0.001,'projection residual should be ~0')
end)

Test('stable calibration is throttled and keeps bounded samples',function()
    assert(type(P.GetRangeMetricCalibration)=='function','GetRangeMetricCalibration missing')
    nowMs=2000; targetWorldX=60; targetDistanceMeters=30; nativeTargetX=1365
    local a=P:GetRangeMetricCalibration({anchorUnit='player',targetUnit='target',anchorWorld={x=0,y=0,z=0},worldZOffset=0.25,intervalMs=500,forceSample=true})
    Near(a.worldUnitsPerMeter,2,0.0001,'stable world scale #1')
    Near(a.projectionScale,1.25,0.0001,'stable projection scale #1')
    assert(a.worldSampleCount>=1 and a.projectionSampleCount>=1,'sample counters missing')
    local distanceCalls=callCounts['X2Unit:UnitDistance'] or 0

    nowMs=2100; targetWorldX=66; targetDistanceMeters=30; nativeTargetX=1381.8
    local cached=P:GetRangeMetricCalibration({anchorUnit='player',targetUnit='target',anchorWorld={x=0,y=0,z=0},worldZOffset=0.25,intervalMs=500})
    assert((callCounts['X2Unit:UnitDistance'] or 0)==distanceCalls,'throttle still sampled UnitDistance')
    Near(cached.worldUnitsPerMeter,2,0.0001,'cached world scale')
    Near(cached.projectionScale,1.25,0.0001,'cached projection scale')

    nowMs=2600
    local b=P:GetRangeMetricCalibration({anchorUnit='player',targetUnit='target',anchorWorld={x=0,y=0,z=0},worldZOffset=0.25,intervalMs=500})
    assert(b.worldSampleCount==2,'second world sample missing')
    -- bounded median/average-of-middle for [2.0, 2.2]
    Near(b.worldUnitsPerMeter,2.1,0.0001,'stable world median')
end)

Test('projection context change invalidates screen scale but not world scale',function()
    nowMs=3200; screenW=1280; screenH=768
    -- Camera projected lateral delta = 230.4 for x=60 at this viewport; Native delta 253.44 => 1.1x.
    nativeTargetX=640+253.44
    targetWorldX=60; targetDistanceMeters=30
    -- Native player coordinate must follow viewport too.
    X2Unit.GetUnitScreenPosition=function(self,token)
        if token=='player' then return 640,384,1 end
        if token=='target' then return nativeTargetX,384,1 end
        return nil,nil,nil
    end
    local c=P:GetRangeMetricCalibration({anchorUnit='player',targetUnit='target',anchorWorld={x=0,y=0,z=0},worldZOffset=0.25,intervalMs=500})
    Near(c.projectionScale,1.1,0.0001,'context-reset projection scale')
    assert(c.projectionSampleCount==1,'projection samples were not reset on context change')
    assert(c.worldSampleCount>=3,'world samples should survive projection context change')
end)

Test('projection scale measurement is resolution-independent in raw UIParent coordinates',function()
    local cases={{1024,768},{1280,768},{1920,1080},{2560,1440}}
    targetWorldX=60;targetDistanceMeters=30
    for _,size in ipairs(cases) do
        screenW,screenH=size[1],size[2]
        local cx,cy=screenW/2,screenH/2
        local rawDelta=(60/100)*(screenH/2)
        nativeTargetX=cx+rawDelta*1.2
        X2Unit.GetUnitScreenPosition=function(self,token)
            if token=='player' then return cx,cy,1 end
            if token=='target' then return nativeTargetX,cy,1 end
            return nil,nil,nil
        end
        local sample=P:MeasureRangeMetricCalibration({anchorUnit='player',targetUnit='target',anchorWorld={x=0,y=0,z=0},worldZOffset=0.25})
        assert(sample.projectionScaleStatus=='accepted',string.format('%dx%d rejected scale: %s',screenW,screenH,tostring(sample.projectionScaleReason)))
        Near(sample.projectionScale,1.2,0.0001,string.format('%dx%d projectionScale',screenW,screenH))
    end
end)

Test('missing target fails closed to existing calibrated/default values without inventing meters',function()
    nowMs=3600
    local oldWorld,targetDistanceOld,nativeOld=targetWorldX,targetDistanceMeters,nativeTargetX
    targetWorldX=nil; targetDistanceMeters=nil; nativeTargetX=nil
    X2Unit.GetUnitWorldPositionByTarget=function(self,token,isLocal)
        if token=='player' then return 0,0,0,0 end
        return nil,nil,nil,nil
    end
    X2Unit.UnitDistance=function(self,token) return nil end
    X2Unit.GetUnitScreenPosition=function(self,token)
        if token=='player' then return 640,384,1 end
        return nil,nil,nil
    end
    local before=P.rangeMetricCalibration and P.rangeMetricCalibration.worldUnitsPerMeter or 1
    local result=P:GetRangeMetricCalibration({anchorUnit='player',targetUnit='target',anchorWorld={x=0,y=0,z=0},worldZOffset=0.25,intervalMs=250,forceSample=true})
    Near(result.worldUnitsPerMeter,before,0.0001,'missing-target retained world scale')
    assert(result.lastSample and result.lastSample.worldScaleStatus~='accepted','missing target invented an accepted world sample')
    -- restore stubs for following projection test
    targetWorldX=oldWorld or 60; targetDistanceMeters=targetDistanceOld or 30; nativeTargetX=nativeOld or 1365
    X2Unit.GetUnitWorldPositionByTarget=function(self,token,isLocal)
        if token=='player' then return 0,0,0,0 end
        if token=='target' then return targetWorldX,0,0,0 end
        return nil,nil,nil,nil
    end
    X2Unit.UnitDistance=function(self,token) if token=='target' then return {distance=targetDistanceMeters} end return nil end
end)

Test('camera fallback applies one rigid metric screen scale around native player anchor',function()
    nowMs=4000; screenW=1920; screenH=1080
    X2Unit.GetUnitScreenPosition=function(self,token)
        if token=='player' then return 960,540,1 end
        if token=='target' then return 1365,540,1 end
        return nil,nil,nil
    end
    local projected,source,facts=P:ProjectWorldBatch({{x=10,y=0,z=0.25}}, {
        easyPullCompat=true,
        anchorUnit='player',anchorWorld={x=0,y=0,z=0.25},
        metricScreenScale=2,
    })
    assert(source=='easypull_camera','expected camera fallback, got '..tostring(source))
    assert(type(projected[1])=='table' and projected[1].visible==true,'point not visible')
    -- Raw camera delta is 54 px at 1920x1080/FOV90. Translation aligns player, then 2x scale => 108 px.
    Near(projected[1].x,1068,0.01,'scaled screen x')
    Near(projected[1].y,540,0.02,'scaled screen y')
    assert(facts.metricScreenScaleStatus=='applied','metric screen scale not reported applied: '..tostring(facts.metricScreenScaleStatus))
    Near(facts.metricScreenScale,2,0.0001,'facts metric screen scale')
end)

Test('range feature consumes metric calibration without changing persisted meter radius',function()
    local f=assert(io.open('features/rs_business_bridge.lua','r'));local text=f:read('*a');f:close()
    assert(text:find('GetRangeMetricCalibration',1,true),'range feature does not request metric calibration')
    assert(text:find('worldUnitsPerMeter',1,true),'range feature does not expose/use worldUnitsPerMeter')
    assert(text:find('metricScreenScale',1,true),'range feature does not pass metricScreenScale')
    assert(text:find('circle.radius * worldUnitsPerMeter',1,true),'configured meters are not converted to calibrated world units')
end)

print('RANGE METRIC CALIBRATION RESULTS: '..passed..' passed / '..failed..' failed')
assert(failed==0,tostring(failed)..' range metric calibration regressions')

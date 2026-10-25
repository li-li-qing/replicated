-- Replicated Suite · 范围辅助纯几何热路回归
-- 作者：Replicated
-- QQ群：1104129461
-- 真实 Lua 5.1 / Feature / Persistence / Demand；仅替换屏幕投影边界。
-- 运算探针只包裹真实源码的方向乘法与校准状态转换，不改变数值或生产文件。
-- 可用 --source <文件> 验证历史字节，--compare <文件> 输出同负载分配对比。
-- 不进入 toc.g，不注册全量 runner，不声称 RU 客户端帧耗实测。
local H = dofile('tools/rs_udf_numeric_test_host.lua')
local currentPath = 'features/combat/range_assist/rs_range_assist_feature.lua'
local sourcePath, comparePath = currentPath, nil
for i=1,#arg,2 do
    if arg[i]=='--source' then sourcePath=assert(arg[i+1])
    elseif arg[i]=='--compare' then comparePath=assert(arg[i+1])
    else error('unknown argument: '..tostring(arg[i])) end
end
local function Read(path)
    local file=assert(io.open(path,'rb'));local source=file:read('*a');file:close();return source
end
local function LiteralPattern(value) return (value:gsub('(%W)','%%%1')) end
local function Circle(id,count)
    return {id=id,name='circle '..id,enabled=true,radius=10,pointCount=count or 24,
        pointSize=4,opacity=0.68,color={0.2,0.82,1}}
end
local function Boot(path,counts)
    local S=H.Boot()
    local c={x=5,y=30,z=2,scale=1,screenScale=1,width=2560,height=1440,
        worldReads=0,metricReads=0,batchReads=0,multiplies=0,worldStatusReads=0,depthConversions=0,
        now=0,missing=false,camera=false,source='native',throw=false}
    S.NowMs=function() return c.now end
    local service={}
    function service:GetUnitWorldPosition()
        c.worldReads=c.worldReads+1
        if c.throw then error('injected projection exception') end
        if c.missing then return nil,nil,nil,'missing_world' end
        return c.x,c.y,c.z
    end
    function service:GetRangeMetricCalibration(options)
        c.metricReads=c.metricReads+1
        assert(options.anchorWorld.x==c.x and options.anchorWorld.z==c.z,'stale metric anchor')
        if c.onMetric then local fn=c.onMetric;c.onMetric=nil;fn() end
        if c.metricThrows then error('injected metric exception') end
        if c.metricMissing then return nil end
        return {worldUnitsPerMeter=c.scale,projectionScale=c.screenScale,worldScaleStatus='calibrated',
            projectionScaleStatus='calibrated',worldSampleCount=1,projectionSampleCount=1}
    end
    function service:ProjectWorldBatch(points,options)
        c.batchReads=c.batchReads+1
        assert(options.anchorWorld.x==c.x and options.anchorWorld.z==c.z+0.25,'stale batch anchor')
        local out={}
        for i,p in ipairs(points) do
            out[i]={x=p.x*c.screenScale+c.width/2,y=p.y*c.screenScale+c.height/2,
                depth=1,visible=not c.hidden or i%c.hidden~=0}
        end
        if c.onProjected then c.onProjected(out) end
        if c.onBatch then c.onBatch(points) end
        return out,c.source,{at=c.now,total=#points,native=c.camera and 0 or #points,
            camera=c.camera and #points or 0,rigidSource=c.source,viewportWidth=c.width,viewportHeight=c.height,
            metricScreenScaleStatus=c.camera and 'applied' or 'native_or_mixed_skipped'}
    end
    S.Services.ScreenProjectionV3=service
    dofile('features/shared/rs_feature_slice_factory.lua')
    dofile('features/shared/rs_shared_bounds.lua')
    dofile('features/combat/unit_lines/rs_unit_lines_feature.lua')
    local source=Read(path)
    for _,axis in ipairs({'x','y'}) do
        local expression='direction.'..axis..' * worldRadius'
        local replacements
        source,replacements=source:gsub(LiteralPattern(expression),'RSRangeHotpathMultiply(direction.'..axis..', worldRadius)')
        assert(replacements==1,'missing unique direction multiplication probe: '..axis)
    end
    local status='tostring(metricCalibration.worldScaleStatus or "")'
    local replacements
    source,replacements=source:gsub(LiteralPattern(status),'RSRangeHotpathWorldStatus(metricCalibration.worldScaleStatus or "")')
    assert(replacements==1,'missing unique world status probe')
    source,replacements=source:gsub(LiteralPattern('tonumber(screenPoint.depth)'),'RSRangeHotpathDepth(screenPoint.depth)')
    assert(replacements>=1 and replacements<=2,'missing depth conversion probe')
    local chunk=assert(loadstring(source,'@'..path))
    setfenv(chunk,setmetatable({
        RSRangeHotpathMultiply=function(a,b)c.multiplies=c.multiplies+1;return a*b end,
        RSRangeHotpathWorldStatus=function(value)c.worldStatusReads=c.worldStatusReads+1;return tostring(value) end,
        RSRangeHotpathDepth=function(value)c.depthConversions=c.depthConversions+1;return tonumber(value) end,
    },{__index=_G}))
    chunk()
    local R=assert(S.Features.combat_range_assist)
    assert(R:Initialize());assert(R:Enable())
    for i,count in ipairs(counts or {24}) do R.State.circles[i]=Circle(i,count) end
    assert(R:AcquireConsumer('range_hotpath_test'))
    return S,R,c
end
local passed,failed=0,0
local function Test(name,fn)
    local ok,err=xpcall(fn,debug.traceback)
    if ok then passed=passed+1;print('PASS range-hotpath '..name)
    else failed=failed+1;print('FAIL range-hotpath '..name..': '..tostring(err)) end
end
local function Refresh(R,c)
    c.now=c.now+16;assert(R.Authority:Refresh('hotpath_test'))
end
local function Near(a,b) assert(math.abs(a-b)<0.00000001,tostring(a)..' ~= '..tostring(b)) end
Test('warm fixed radii avoid every per-point direction multiplication',function()
    local S,R,c=Boot(sourcePath,{96,96})
    local first=c.multiplies
    for i=1,8 do c.x=i;Refresh(R,c) end
    local warm=c.multiplies-first
    print('COUNT warm_frames=8 points=192 direction_multiplies='..warm..' baseline_expected=3072')
    assert(warm==0,'unchanged radius multiplied '..warm..' cached directions')
    assert(c.worldReads==9 and c.metricReads==9 and c.batchReads==9,'changed sampling cadence')
    Near(R.Authority.rows[1].points[1].x,1298)
end)
Test('calibration verification is one batch operation independent of circles',function()
    local counts={};for i=1,64 do counts[i]=3 end
    local S,R,c=Boot(sourcePath,counts)
    c.worldStatusReads=0;Refresh(R,c)
    print('COUNT circles=64 batch_world_status_reads='..c.worldStatusReads..' baseline_expected=64')
    assert(c.worldStatusReads==1,'batch metric status converted per circle')
    assert(#R.Authority.rows==64 and R.RangeLastBatch.total==192)
end)
Test('positive depth is converted once per projected point without changing acceptance',function()
    local S,R,c=Boot(sourcePath,{192})
    c.depthConversions=0;Refresh(R,c)
    print('COUNT points=192 depth_conversions='..c.depthConversions..' baseline_expected=384')
    assert(c.depthConversions==192,'positive depth converted more than once')
    c.onProjected=function(out)
        out[1].depth='1';out[2].depth='0';out[3].depth='-1';out[4].depth='bad'
        out[5].visible=false;out[6].x='bad';out[7].y='bad';out[8].depth=0/0
    end
    Refresh(R,c);assert(#R.Authority.rows[1].points==185,'point acceptance changed')
    assert(R.Authority.rows[1].points[1].depth=='1','numeric-string depth was normalized into a new public fact')
end)
Test('radius and metric scale update immediately with exact geometry',function()
    local S,R,c=Boot(sourcePath,{24,24})
    local before=c.multiplies
    R.State.circles[1].radius=17.25;Refresh(R,c)
    Near(R.Authority.rows[1].points[1].x,1302.25)
    assert(c.multiplies-before==48,'radius update did not rebuild just its own offsets')
    before=c.multiplies;c.scale=2.5;c.x=11;Refresh(R,c)
    Near(R.Authority.rows[1].points[1].x,1334.125)
    assert(c.multiplies-before==96,'metric update did not rebuild all affected offsets')
    assert(R.Authority.rows[1].radius==17.25 and R.Authority.rows[1].worldRadius==43.125)
end)
Test('topology replacement and in-place density changes retain exact budget',function()
    local S,R,c=Boot(sourcePath,{24,24})
    R.State.circles[1].pointCount=96;R.State.circles[2].enabled=false;Refresh(R,c)
    assert(#R.Authority.rows==1 and #R.Authority.rows[1].points==96)
    R.State.circles={Circle(91,192),Circle(92,3)};Refresh(R,c)
    assert(R.Authority.rows[1].circleId==91 and R.Authority.rows[2].renderPointCount==3)
    assert(R.RangeLastBatch.total==192)
    local old=R.RangeGeometry
    table.insert(R.State.circles,1,Circle(93,3));Refresh(R,c)
    assert(R.RangeGeometry~=old and R.Authority.rows[1].circleId==93 and R.RangeLastBatch.total==192)
end)
Test('position viewport camera scale and styles are sampled on the next frame',function()
    local S,R,c=Boot(sourcePath,{24})
    c.x=75;c.y=42;c.z=20;c.width=1920;c.height=1080;c.screenScale=2;c.camera=true;c.source='camera'
    R.State.circles[1].color[1]=0.9;R.State.circles[1].opacity=0.3;R.State.circles[1].pointSize=8
    Refresh(R,c)
    local row=R.Authority.rows[1];Near(row.points[1].x,1130);Near(row.points[1].y,624)
    assert(row.color[1]==0.9 and row.opacity==0.3 and row.pointSize==8 and row.metricVerified)
    assert(R:GetRenderProjection().viewportWidth==1920 and row.batchSource=='camera')
end)
Test('prior Authority rows and both public snapshots remain isolated across many frames',function()
    local S,R,c=Boot(sourcePath,{24})
    local rows=R.Authority.rows;local held=H.Copy(rows)
    local full,render=R:GetProjection(),R:GetRenderProjection()
    local oldFull,oldRender=H.Copy(full),H.Copy(render)
    for i=1,8 do c.x=i*10;R.State.circles[1].radius=10+i;Refresh(R,c) end
    assert(H.Eq(rows,held),'old Authority rows modified')
    assert(H.Eq(full,oldFull) and H.Eq(render,oldRender),'old public snapshot modified')
    full.rows[1].points[1].x=-1;render.rows[1].points[1].x=-2
    assert(R:GetProjection().rows[1].points[1].x~=-1 and R:GetRenderProjection().rows[1].points[1].x~=-2)
end)
Test('partial points and unavailable world do not retain stale output',function()
    local S,R,c=Boot(sourcePath,{3})
    c.hidden=2;Refresh(R,c)
    assert(R.Authority.status=='partial' and #R.Authority.rows[1].points==2)
    c.missing=true;Refresh(R,c)
    assert(R.Authority.status=='unavailable' and #R.Authority.rows==0)
    c.missing=false;c.hidden=nil;c.x=20;Refresh(R,c)
    assert(R.Authority.status=='ready');Near(R.Authority.rows[1].points[1].x,1310)
end)
Test('metric absent failed and invalid values retain original fallback semantics',function()
    local S,R,c=Boot(sourcePath,{24})
    c.scale=2;Refresh(R,c);assert(R.Authority.rows[1].worldRadius==20)
    for _,mode in ipairs({'metricThrows','metricMissing'}) do
        c[mode]=true;Refresh(R,c)
        assert(R.Authority.rows[1].worldRadius==10 and not R.Authority.rows[1].metricVerified)
        assert(R.RangeMetricFacts.worldScaleStatus=='default');c[mode]=false
    end
    for _,scale in ipairs({0,-2,0/0}) do
        c.scale=scale;Refresh(R,c);assert(R.Authority.rows[1].worldRadius==10)
    end
    S.Services.ScreenProjectionV3.GetRangeMetricCalibration=nil;Refresh(R,c)
    assert(R.Authority.rows[1].worldRadius==10 and not R.Authority.rows[1].metricVerified)
end)
Test('metric callback synchronous reentry does not cache stale radius or facts',function()
    local S,R,c=Boot(sourcePath,{24})
    c.onMetric=function()
        R.State.circles[1].radius=15;c.scale=2
        Refresh(R,c)
    end
    Refresh(R,c)
    local row=R.Authority.rows[1]
    assert(row.radius==15 and row.worldRadius==30 and c.worldReads==3)
    Near(row.points[1].x,1315)
end)
Test('provider mutation of borrowed world rows cannot corrupt private radius offsets',function()
    local S,R,c=Boot(sourcePath,{96,96})
    c.onBatch=function(points)
        for _,point in ipairs(points) do
            point.x,point.y,point.z=-999,-888,-777
            point.offsetX,point.offsetY=-666,-555
        end
    end
    for i=1,3 do
        c.x=i*10;Refresh(R,c)
        Near(R.Authority.rows[1].points[1].x,1280+c.x+10)
        Near(R.Authority.rows[1].points[1].y,720+c.y)
    end
end)
Test('scheduler exception recovery keeps current sampling and clears old output',function()
    local S,R,c=Boot(sourcePath,{24})
    c.throw=true;c.now=c.now+16
    assert(S.Scheduler.tasks.v3_business_range_assist_refresh.fn())
    assert(R.Authority.status=='unavailable' and #R.Authority.rows==0)
    c.throw=false;c.x=25;c.now=c.now+16
    assert(S.Scheduler.tasks.v3_business_range_assist_refresh.fn())
    assert(R.Authority.status=='ready');Near(R.Authority.rows[1].points[1].x,1315)
end)
Test('last release and disable free all geometry without Native work or config loss',function()
    local S,R,c=Boot(sourcePath,{192})
    local settings=R.State.circles
    assert(R:ReleaseConsumer('range_hotpath_test'))
    assert(R.RangeGeometry==nil and S.Scheduler.tasks.v3_business_range_assist_refresh==nil)
    local reads=c.worldReads;assert(R:Refresh());assert(c.worldReads==reads)
    assert(R:AcquireConsumer('range_hotpath_test'));assert(R.RangeGeometry~=nil)
    assert(R:Disable());assert(R.RangeGeometry==nil and R.State.circles==settings)
end)
local function Allocation(path)
    local S,R,c=Boot(path,{96,96})
    for i=1,3 do Refresh(R,c) end
    collectgarbage('collect');collectgarbage('stop')
    local start=collectgarbage('count');local multiplies=c.multiplies
    for i=1,120 do c.x=i;Refresh(R,c) end
    local delta=collectgarbage('count')-start
    collectgarbage('restart')
    return delta,c.multiplies-multiplies
end
local function Differential(path)
    local S,R,c=Boot(path,{96,96})
    local snapshots={}
    for i=1,20 do
        c.x=i*1.25;c.y=30-i/3;c.z=i/4;c.width=2560+i*3;c.height=1440+i
        c.scale=i%4==0 and 2.5 or 1;c.screenScale=i%3==0 and 1.25 or 1
        c.camera=i%2==0;c.source=c.camera and 'camera' or 'native'
        c.hidden=i%5==0 and 2 or nil;c.missing=i==11;c.metricThrows=i==12
        if i==6 then R.State.circles[2].enabled=false end
        if i==8 then R.State.circles[2].enabled=true;R.State.circles[1].pointCount=24 end
        if i==10 then R.State.circles={Circle(19,192),Circle(20,3)} end
        R.State.circles[1].radius=10+i/7;R.State.circles[1].color[1]=i/20
        Refresh(R,c)
        snapshots[i]={rows=H.Copy(R.Authority.rows),full=R:GetProjection(),render=R:GetRenderProjection()}
    end
    return snapshots
end
if comparePath then
    Test('historical and optimized outputs are byte-value equivalent across twenty changing frames',function()
        assert(H.Eq(Differential(comparePath),Differential(sourcePath)),'baseline/current projection mismatch')
    end)
    local before,oldMult=Allocation(comparePath)
    local after,newMult=Allocation(sourcePath)
    print(string.format('MEASURE warm_frames=120 points=192 allocation_KiB_before=%.3f after=%.3f delta=%.3f direction_multiplies_before=%d after=%d',before,after,after-before,oldMult,newMult))
end
print(string.format('RESULT range-hotpath %d passed / %d failed',passed,failed))
os.exit(failed==0 and 0 or 1)

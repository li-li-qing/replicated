-- 中文维护：真实寻宝 Command、Capability cooldown、Scheduler；仅 Native 地图与存档是宿主替身。
local NewHost=dofile('tools/rs_gear_page_test_host.lua')
local TASK='v3_life_treasure_map_request'
local passed=0
local function Boot()
    local h=NewHost();local s=h.S
    h.mapCalls={}
    X2Unit.GetCurrentZoneGroup=function()return 2 end
    X2Map={ShowWorldmapLocation=function(_,zone,x,y,z)
        h.mapCalls[#h.mapCalls+1]={at=h.ms,zone=zone,x=x,y=y,z=z}
        return not h.rejectMap
    end}
    dofile('core/rs_demand.lua');dofile('ui/framework/rs_ui_floating_surface.lua')
    dofile('features/life/shared/rs_life_slice_factory.lua')
    dofile('features/life/treasure/rs_treasure_feature.lua')
    local f=s.Features.Treasure;assert(f:Initialize());assert(f:Enable())
    local a={key='a',worldX=21504,worldY=28672,zoneGroupId=2}
    local b={key='b',worldX=21604,worldY=28772,zoneGroupId=2}
    f.Authority.maps={a,b};f.Authority.selected=a;f.Authority.status='ready'
    function h:RunPending(at)
        self.ms=at;assert(s.Scheduler:RunTask(TASK),'pending map action missing')
    end
    return h,s,f,a,b
end
local function Test(name,fn)fn();passed=passed+1;print('PASS treasure-map '..name)end
Test('55ms remaining queues the explicit action and clears the pending state after success',function()
    local h,s,f=Boot();assert(f.Commands:ShowSelectedOnMap());assert(#h.mapCalls==1)
    h.ms=1195;local ok,err=f.Commands:ShowSelectedOnMap();assert(ok,err)
    assert(#h.mapCalls==1 and f:GetProjection().mapActionPending==true)
    assert(s.Scheduler.tasks[TASK].intervalMs>=55,'official cooldown was shortened')
    h:RunPending(1250);assert(#h.mapCalls==2 and h.mapCalls[2].at==1250)
    assert(not f:GetProjection().mapActionPending and f:GetProjection().lastMapActionError==nil)
    assert(s.Scheduler.tasks[TASK]==nil,'one-shot survived completion')
end)
Test('a changed selection cancels the old pending native write',function()
    local h,s,f,a,b=Boot();assert(f.Commands:ShowSelectedOnMap())
    h.ms=1195;assert(f.Commands:ShowSelectedOnMap());f.Authority.selected=b
    h:RunPending(1250);assert(#h.mapCalls==1 and not f:GetProjection().mapActionPending)
end)
Test('short remaining cooldown does not acquire the background 50ms delay floor',function()
    local h,s,f=Boot();assert(f.Commands:ShowSelectedOnMap());h.ms=1225
    assert(f.Commands:ShowSelectedOnMap());assert(s.Scheduler.tasks[TASK].intervalMs==25)
    h:RunPending(1250);assert(#h.mapCalls==2 and not f:GetProjection().mapActionPending)
end)
Test('several explicit requests coalesce to the most recent map',function()
    local h,s,f,a,b=Boot();assert(f.Commands:ShowSelectedOnMap())
    h.ms=1195;assert(f.Commands:ShowSelectedOnMap());f.Authority.selected=b
    h.ms=1210;assert(f.Commands:ShowSelectedOnMap());h:RunPending(1260)
    assert(#h.mapCalls==2 and h.mapCalls[2].x==b.worldX)
end)
Test('disabling cancels the pending action and never opens the map later',function()
    local h,s,f=Boot();assert(f.Commands:ShowSelectedOnMap());h.ms=1195
    assert(f.Commands:ShowSelectedOnMap());assert(f:Disable('test'))
    assert(s.Scheduler.tasks[TASK]==nil and not f:GetProjection().mapActionPending)
    assert(#h.mapCalls==1)
end)
Test('a rejected deferred native action stays a real error and never loops',function()
    local h,s,f=Boot();assert(f.Commands:ShowSelectedOnMap());h.ms=1195
    assert(f.Commands:ShowSelectedOnMap());h.rejectMap=true;h:RunPending(1250)
    assert(f:GetProjection().lastMapActionError and not f:GetProjection().mapActionPending)
    assert(s.Scheduler.tasks[TASK]==nil and #h.mapCalls==2)
end)
print('TREASURE_MAP_COOLDOWN PASS: '..passed..' cases (Native modeled)')

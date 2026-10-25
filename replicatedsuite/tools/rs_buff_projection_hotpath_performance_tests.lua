-- 状态 HUD 热路径回归：真实 Feature、布局与 Renderer，仅替换 Native/磁盘事实。
-- 网格只缓存相对几何；实时 Buff 行、计时、元数据和 Native 提交仍逐次消费。
-- 使用操作/分配计数，不运行长 CPU 基准；本工具不进入 TOC。
local Host=dofile('tools/rs_pvp_hud_test_host.lua')
local passed,failed=0,0
local function Test(name,fn)
    local ok,err=xpcall(fn,debug.traceback)
    if ok then passed=passed+1;print('PASS buff-projection-hotpath '..name)
    else failed=failed+1;print('FAIL buff-projection-hotpath '..name..': '..tostring(err))end
end
local function Boot(mode,count)
    local h,S,F=Host({runtimeHud=true,noRenderer=true})
    dofile('features/combat/buff_display/rs_buff_display_arrangement.lua')
    dofile('services/rs_status_classification_v3.lua')
    F.State.settings.headShowAll=true
    for _,scope in ipairs({'player','target'})do
        local profile=scope=='target'and F.State.settings.targetLayout or F.State.settings
        profile.components.buffs.maxPerRow=8;profile.components.buffs.maxRows=4
        profile.components.debuffs.maxPerRow=8;profile.components.debuffs.maxRows=4
        F.HudArrangementState[scope].buffs=mode or 'horizontal'
        F.HudArrangementState[scope].debuffs=mode or 'horizontal'
        for id=1,count or 32 do h.facts[scope][id]=h:Fact(id)end
    end
    F:InvalidateSettingsCache();assert(F:Refresh('grid_test',true))
    h.gridCalls,h.gridTables=0,0
    local calculate=F.ComputeHudIconGrid
    F.ComputeHudIconGrid=function(...)
        local grid=calculate(...)
        h.gridCalls=h.gridCalls+1;h.gridTables=h.gridTables+2+#grid.slots
        return grid
    end
    dofile('presentation/v3/widgets/rs_v3_buff_head_markers.lua')
    local R=S.UIV3.BuffHeadMarkersV3;assert(R and R.running);R:VisualTick()
    return h,S,F,R
end
local function GridWork(h,fn)
    local calls,tables=h.gridCalls,h.gridTables
    fn()
    return h.gridCalls-calls,h.gridTables-tables
end
local function VisibleIds(R,scope)
    local ids={}
    for _,marker in ipairs(R.pools[scope].icons)do
        if marker.root.shown then ids[#ids+1]=marker.icon.texture end
    end
    return table.concat(ids,'|')
end
Test('unchanged explicit grids allocate no repeated coordinate tables',function()
    local h,S,F,R=Boot('horizontal')
    local scans,reads,anchors,textures=h.scans,h.projectionReads,h.anchors,h.textures
    local calls,tables=GridWork(h,function()for _=1,3 do R:VisualTick()end end)
    print('BUFF_GRID_WORK calls='..calls..' tables='..tables..' scans='..(h.scans-scans)..
        ' nativeProjection='..(h.projectionReads-reads)..' anchors='..(h.anchors-anchors)..' textures='..(h.textures-textures))
    assert(calls==0 and tables==0,'unchanged grids still allocate coordinates')
    assert(h.scans==scans and h.projectionReads==reads,'rendering read extra Native facts')
    assert(h.anchors==anchors and h.textures==textures,'unchanged grid resubmitted Native geometry/texture')
end)
Test('legacy rows use the detached projection array without per-row slices',function()
    local h,S,F,R=Boot('default',32)
    local arrays={};local get=F.GetPlatesProjection
    F.GetPlatesProjection=function(self,scope,...)
        local plates,rev=get(self,scope,...);arrays[scope]=plates.buffs;return plates,rev
    end
    local rows,slices=0,0
    debug.sethook(function()
        local info=debug.getinfo(2,'nS')
        if info.name=='RenderIconRow' and string.find(info.source,'rs_v3_buff_head_markers.lua',1,true)then
            local _,scope=debug.getlocal(2,1);local _,array=debug.getlocal(2,3)
            rows=rows+1;if array~=arrays[scope]then slices=slices+1 end
        end
    end,'c')
    local ok,err=pcall(function()R:VisualTick()end);debug.sethook();assert(ok,err)
    print('BUFF_LEGACY_ROW_WORK rows='..rows..' sliceTables='..slices)
    assert(rows==8 and slices==0,'legacy renderer still copies every row into a temporary slice')
    assert(R.pools.player.icons[9].icon.texture=='buff9.dds' and R.pools.player.icons[32].icon.texture=='buff32.dds',
        'array range indexing changed row contents')
end)
Test('count changes rebuild only the affected scope then reuse its new grid',function()
    local h,S,F,R=Boot('horizontal')
    h.facts.player[32]=nil;assert(F:RefreshScope('player',true))
    assert(GridWork(h,function()R:VisualTick()end)==1,'count change did not replace one scope grid')
    assert(GridWork(h,function()R:VisualTick()end)==0)
    assert(not string.find(VisibleIds(R,'player'),'buff32.dds',1,true),'removed Buff retained its texture')
end)
Test('settings geometry and orientation changes rebuild then render exact pure coordinates',function()
    local h,S,F,R=Boot('vertical',14)
    local cfg=F.State.settings.components.buffs
    cfg.size=34;cfg.spacing=5;cfg.maxPerRow=5;cfg.maxRows=3;cfg.x=37;cfg.y=-23
    F.State.settings.plateScale=1.25
    F.HudArrangementState.player.buffs='horizontal';F:InvalidateSettingsCache()
    local beforeX=R.pools.player.icons[1].root.x
    assert(GridWork(h,function()R:VisualTick()end)>0)
    assert(R.pools.player.icons[1].root.x~=beforeX,'new settings did not move icons')
    assert(R.pools.player.icons[1].root.width==42,'new scaling did not change icon size')
    assert(GridWork(h,function()R:VisualTick()end)==0)
    local a,b=R.pools.player.icons[1].root,R.pools.player.icons[2].root
    assert(b.x-a.x==48 and b.y==a.y,'horizontal spacing differs from scaled pure geometry')
end)
Test('metadata stack timer and short Buff arrivals use current facts with reused geometry',function()
    local h,S,F,R=Boot('horizontal',8)
    h.facts.player[1].iconPath='fresh.dds';h.facts.player[1].name='Fresh metadata'
    h.facts.player[1].stack=7;h.facts.player[1].timeLeft=200
    assert(F:RefreshScope('player',true));assert(GridWork(h,function()R:VisualTick()end)==0)
    local icon=R.pools.player.icons[1]
    assert(icon.icon.texture=='fresh.dds' and icon.stack.text=='7' and icon.time.text=='0.2')
    h.facts.player[1]=nil;h.facts.player[40]=h:Fact(40);h.facts.player[40].timeLeft=10
    assert(F:RefreshScope('player',true));assert(GridWork(h,function()R:VisualTick()end)==0)
    assert(not string.find(VisibleIds(R,'player'),'fresh.dds',1,true),'expired short Buff remains visible')
    assert(string.find(VisibleIds(R,'player'),'buff40.dds',1,true),'new short Buff was deferred')
end)
Test('classification version override and source changes immediately replace rendered categories',function()
    local h,S,F,R=Boot('horizontal',1)
    local C=S.Services.StatusClassificationV3;C.version=C.version+1
    F.State.settings.classification[1]='debuff';F:InvalidateSettingsCache()
    assert(F:RefreshScope('player',true));R:VisualTick()
    assert(#F.laneData.player.buffRows==0 and #F.laneData.player.debuffRows==1)
    h.facts.player[1].sources={hidden=true};F.State.settings.classification[1]=nil
    C.version=C.version+1;F:InvalidateSettingsCache();assert(F:RefreshScope('player',true));R:VisualTick()
    assert(#F.laneData.player.buffRows==0 and #F.laneData.player.debuffRows==0)
    assert(not string.find(VisibleIds(R,'player'),'buff1.dds',1,true),'unknown classification retained prior row')
end)
Test('failed and partial scans never substitute old Buff rows',function()
    local h,S,F,R=Boot('horizontal',1)
    local A=S.Services.AuraObservationV3;local get=A.GetSnapshot
    A.GetSnapshot=function()return nil,'injected_read_failure'end
    assert(not F:RefreshScope('target',true));R:VisualTick()
    assert(VisibleIds(R,'target')=='','failed scan retained old Buff')
    A.GetSnapshot=get;h.facts.target={[70]=h:Fact(70)}
    A.GetStatusMap=function(_,snap)return h.Copy(h.facts[snap.scope]),{available=true,complete=false,reliable=false}end
    assert(F:RefreshScope('target',true));R:VisualTick()
    assert(VisibleIds(R,'target')=='buff70.dds' and not F.coverage.target.complete)
end)
Test('target invalidation hides immediately and equal size replacement cannot reuse old content',function()
    local h,S,F,R=Boot('horizontal',8)
    h:Event('TARGET_CHANGED');assert(not R.pools.target.root.shown,'old target remained visible on event edge')
    h.facts.target={};for id=41,48 do h.facts.target[id]=h:Fact(id)end
    assert(F:RefreshScope('target',true));R:VisualTick()
    assert(R.pools.target.icons[1].icon.texture=='buff41.dds' and not string.find(VisibleIds(R,'target'),'buff1.dds',1,true))
end)
Test('rejected Native geometry retries even when the pure grid is retained',function()
    local h,S,F,R=Boot('horizontal',8);local p=R.pools.player;local root=p.icons[1].root;local x=root.x
    root.x=x+10;h.rejectAnchor=root
    assert(GridWork(h,function()R:VisualTick()end)==0)
    assert(not p.ready and not p.root.shown,'rejected Native geometry was accepted as cached success')
    h.rejectAnchor=nil;h.ms=h.ms+60
    assert(GridWork(h,function()R:MotionTick()end)==0)
    assert(p.ready and p.root.shown and root.x==x,'cached grid swallowed Native retry')
end)
Test('public grids stay detached and replacing the calculator invalidates private reuse',function()
    local h,S,F,R=Boot('horizontal',8);local calculate=F.ComputeHudIconGrid
    local a=calculate(8,29,2,8,4,false,true);local b=calculate(8,29,2,8,4,false,true)
    assert(a~=b and a.slots~=b.slots and a.slots[1]~=b.slots[1])
    local x=R.pools.player.icons[1].root.x;a.slots[1].x=999999;R:VisualTick()
    assert(R.pools.player.icons[1].root.x==x,'public mutable grid leaked into renderer cache')
    local replacements=0
    F.ComputeHudIconGrid=function(...)replacements=replacements+1;return calculate(...)end
    R:VisualTick();assert(replacements==2,'calculator replacement was hidden by a stale cache')
end)
Test('public full snapshots cannot mutate the next render or current live rows',function()
    local h,S,F,R=Boot('horizontal',8)
    local a=F:GetPlatesProjection('player');local b=F:GetPlatesProjection('player')
    assert(a~=b and a.buffs~=b.buffs and a.buffs[1]~=b.buffs[1] and a.components~=b.components)
    a.buffs[1].iconPath='poison.dds';a.buffs[1].timeText='poison';a.components.buffs.size=99999
    R:VisualTick()
    assert(R.pools.player.icons[1].icon.texture=='buff1.dds' and R.pools.player.icons[1].time.text~='poison')
    assert(F.laneData.player.buffRows[1].iconPath=='buff1.dds' and b.components.buffs.size~=99999)
end)
Test('viewport and unit motion apply current coordinates while relative grids remain reusable',function()
    local h,S,F,R=Boot('vertical',8);local root=R.pools.player.root;local before=root.x
    h.width,h.height=700,500;h.points.player={650,350,1}
    local calls=GridWork(h,function()F:PositionTick();R:VisualTick()end)
    assert(calls==0,'viewport changes rebuilt unchanged relative coordinates')
    assert(root.x~=before,'new viewport/position did not reach HUD')
    for _,marker in ipairs(R.pools.player.icons)do
        if marker.root.shown then local x,y=h:World(marker.root)
            assert(x>=0 and x+marker.root.width<=700 and y>=0 and y+marker.root.height<=500,
                'cached relative grid bypassed current viewport clipping')
        end
    end
end)
Test('count churn replaces a bounded private grid slot and stop drops all grid references',function()
    local h,S,F,R=Boot('horizontal',8);local calculate=F.ComputeHudIconGrid
    local retained=setmetatable({},{__mode='k'})
    F.ComputeHudIconGrid=function(...)local grid=calculate(...);retained[grid]=true;return grid end
    for count=1,24 do
        for _,scope in ipairs({'player','target'})do
            h.facts[scope]={};for id=1,count do h.facts[scope][id]=h:Fact(id)end
            assert(F:RefreshScope(scope,true))
        end
        R:VisualTick()
    end
    collectgarbage('collect');local count=0;for _ in pairs(retained)do count=count+1 end
    assert(count==2,'count churn retained historical grids: '..count)
    assert(R:Stop('bounded_cache_test'));collectgarbage('collect')
    assert(next(retained)==nil,'stop leaked old grids')
end)
Test('unknown revisions preserve uncached behavior and stopping releases retained grids',function()
    local h,S,F,R=Boot('horizontal',8);F.settingsRevision=nil
    assert(GridWork(h,function()R:VisualTick()end)==2)
    assert(GridWork(h,function()R:VisualTick()end)==2)
    F.settingsRevision=20;R:VisualTick();assert(R:Stop('test'))
    assert(GridWork(h,function()assert(R:Start())end)>0,'stop retained private grid references')
    assert(GridWork(h,function()R:VisualTick()end)==0)
    assert(R:Stop('test'));assert(F:ReleaseConsumer('test:observer'))
    assert(F.consumerCount==0 and not F.auraHeld)
end)
print('BUFF_PROJECTION_HOTPATH_RESULT passed='..passed..' failed='..failed..' runtime='.._VERSION)
if failed>0 then os.exit(1)end

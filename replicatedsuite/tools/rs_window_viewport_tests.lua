-- 中文维护：Resolution-independent top-level placement 离线回归。
-- 真实被测代码：Api/Layout/Windowing/WindowShell/FloatingSurface；只有 Native、RSUI 叶节点和磁盘是替身。
-- 测试不进入 toc.g；矩阵使用公式而非生产分辨率魔法表。失败不能标记为 RU 实机通过。
local Boot=dofile('tools/rs_window_viewport_test_host.lua')
local pass,fail=0,0
local function Test(name,fn)
    local ok,err=xpcall(fn,debug.traceback)
    if ok then pass=pass+1;print('PASS viewport '..name) else fail=fail+1;print('FAIL viewport '..name..': '..tostring(err))end
end
local function Eq(a,b,msg)assert(type(a)=='number' and type(b)=='number' and math.abs(a-b)<.00001,(msg or 'not equal')..': '..tostring(a)..' / '..tostring(b))end
local function Finite(n)return type(n)=='number' and n==n and n~=math.huge and n~=-math.huge end
local function Snap(t)
    if type(t)~='table' then return tostring(t) end
    local keys={};for k in pairs(t)do keys[#keys+1]=k end;table.sort(keys)
    local r={};for _,k in ipairs(keys)do r[#r+1]=tostring(k)..'='..Snap(t[k])end;return '{'..table.concat(r,';')..'}'
end
local function Full(c,x,y,w,hh)
    assert(Finite(x) and Finite(y) and Finite(w) and Finite(hh),'non-finite geometry')
    assert(x>=c.safeLeft-.001 and y>=c.safeTop-.001 and x+w<=c.logicalWidth-c.safeRight+.001 and y+hh<=c.logicalHeight-c.safeBottom+.001,
        string.format('not safely visible %.3f,%.3f %.3fx%.3f viewport %.3fx%.3f',x,y,w,hh,c.logicalWidth,c.logicalHeight))
end
local function Save(h,x,y,w,hh)
    local p={width=w,height=hh,userMoved=true};h.S.Layout:GetContext(true);h.S.Layout:StorePlacementRect(p,x,y,w,hh,{mode='free'});return p
end
local function Resolve(h,p,w,hh,reason)
    h.S.Layout:GetContext(true)
    return h.S.Layout:ResolvePlacement(p,w,hh,80,90,{mode='free',topLevel=true,topReachHeight=24,reason=reason})
end
Test('1920 bottom right -> 1024 full title and body',function()
    local h=Boot({layoutOnly=true});local p=Save(h,1470,760,420,286)
    h:Viewport(1024,768);local x,y,w,hh=Resolve(h,p,420,286);Full(h.S.Layout:GetContext(),x,y,w,hh)
end)
Test('2560 x2200 y1200 -> 1024 safety recovery',function()
    local h=Boot({layoutOnly=true});h:Viewport(2560,1440);local p=Save(h,2200,1200,420,286)
    h:Viewport(1024,768);local x,y,w,hh,meta=Resolve(h,p,420,286);Full(h.S.Layout:GetContext(),x,y,w,hh);assert(meta and meta.viewportChanged)
end)
Test('legacy free no viewport recovers title, not bottom body strip',function()
    local h=Boot({layoutOnly=true});h:Viewport(1024,768)
    local x,y,w,hh=Resolve(h,{x=4000,y=-2000,coordinateSpace='logical-free-v2'},1600,900)
    Full(h.S.Layout:GetContext(),x,y,w,hh)
end)
Test('legacy edge huge offsets cannot escape',function()
    local h=Boot({layoutOnly=true});h:Viewport(1024,768)
    local x,y,w,hh=Resolve(h,{anchorH='RIGHT',anchorV='BOTTOM',offsetX=4000,offsetY=2000},420,286)
    Full(h.S.Layout:GetContext(),x,y,w,hh)
end)
Test('legacy scale-only uses recovery not guessed multiplication',function()
    local h=Boot({layoutOnly=true});h:Viewport(1280,768,1)
    local x,y,w,hh,meta=Resolve(h,{x=200,y=150,savedUiScale=.75,coordinateSpace='logical-free-v2'},420,286)
    Eq(x,200);Eq(y,150);assert(meta and meta.placementSource=='legacy_recovery')
end)
Test('same viewport partially offscreen free window is contained without Store mutation',function()
    local h=Boot({layoutOnly=true});local p=Save(h,-183.25,-2.5,420,286);local before=Snap(p)
    for i=1,6 do local x,y,w,hh=Resolve(h,p,420,286);Full(h.S.Layout:GetContext(),x,y,w,hh)end
    assert(Snap(p)==before,'runtime containment rewrote persistent intent')
end)
Test('same viewport severely lost title recovers',function()
    local h=Boot({layoutOnly=true});local p=Save(h,300,-500,420,286)
    local x,y,w,hh=Resolve(h,p,420,286);Full(h.S.Layout:GetContext(),x,y,w,hh)
end)
Test('normalized center formula used once',function()
    local h=Boot({layoutOnly=true});local p=Save(h,600,300,420,286)
    h:Viewport(2560,1440);local x,y=Resolve(h,p,420,286)
    Eq(x,p.normalizedCenterX*2560-210);Eq(y,p.normalizedCenterY*1440-143)
end)
Test('same logical viewport scale change is identity transform plus safety',function()
    local h=Boot({layoutOnly=true});local p=Save(h,400,200,420,286)
    h:Viewport(1920,1080,.75);local x,y,_,_,meta=Resolve(h,p,420,286)
    Eq(x,400);Eq(y,200);assert(meta and meta.viewportChanged,'savedUiScale ignored')
end)
Test('physical-only change triggers fresh context without invented coordinate scaling',function()
    local h=Boot({layoutOnly=true});local L=h.S.Layout;L:PrimeCurrentSignature()
    local old=L.lastSignature;h.sw=2560;h.sh=1440
    assert(L:PollChanges()==true);assert(old~=L.lastSignature);Eq(L:GetContext().logicalWidth,1920)
end)
Test('logical-only change not lost behind rounded physical signature',function()
    local h=Boot({layoutOnly=true});local L=h.S.Layout;L:PrimeCurrentSignature()
    h:Viewport(1800,1000,1,1920,1080);assert(L:PollChanges()==true,'logical dimensions omitted from signature');Eq(L:GetContext().logicalWidth,1800)
end)
Test('malformed finite guard and preferred input immutability',function()
    local h=Boot({layoutOnly=true});h:Viewport(1024,768)
    local values={false,'bad',{},0/0,math.huge,-math.huge}
    for _,v in ipairs(values)do
        local p={x=v,y=v,width=v,height=v,coordinateSpace='logical-free-v2',savedLogicalWidth=v,savedLogicalHeight=v,normalizedCenterX=v,normalizedCenterY=v}
        local before=Snap(p);local x,y,w,hh=Resolve(h,p,v,v);Full(h.S.Layout:GetContext(),x,y,w,hh);assert(Snap(p)==before,'read changed store')
    end
end)
Test('Api metrics rejects NaN infinity and zero extent',function()
    local h=Boot({layoutOnly=true});h:Viewport(0/0,math.huge,math.huge,1920,1080)
    local sw,sh,s,lw,lh=h.S.Api:GetUiMetrics();assert(Finite(sw) and Finite(sh) and Finite(s) and Finite(lw) and Finite(lh) and lw>0 and lh>0)
end)
Test('matrix all 9 viewports x 10 positions x 4 sizes bidirectional',function()
    local h=Boot({layoutOnly=true})
    local viewports={{1024,768},{1280,720},{1280,768},{1366,768},{1600,900},{1920,1080},{2560,1440},{3440,1440},{3840,2160}}
    local sizes={{420,286},{1600,900},{5000,240},{320,3000}}
    local count=0
    for _,from in ipairs(viewports)do for _,to in ipairs(viewports)do if from~=to then
        for _,size in ipairs(sizes)do
            local w,hh=size[1],size[2]
            local spots={{12,12},{from[1]-w-12,12},{12,from[2]-hh-12},{from[1]-w-12,from[2]-hh-12},{(from[1]-w)/2,(from[2]-hh)/2},
                {-w/2,120},{from[1]-96,120},{120,-8},{120,from[2]-24},{4000,-2000}}
            for _,spot in ipairs(spots)do
                h:Viewport(from[1],from[2]);local p=Save(h,spot[1],spot[2],w,hh);local before=Snap(p)
                h:Viewport(to[1],to[2]);local x,y,rw,rh=Resolve(h,p,w,hh);Full(h.S.Layout:GetContext(),x,y,rw,rh);assert(Snap(p)==before)
                count=count+1
            end
        end
    end end end
    print('MATRIX resolution '..count..' cases (all ordered unequal viewport pairs)')
end)
Test('scale matrix .7 .75 .8 1 1.2 1.5 same physical, both directions',function()
    local h=Boot({layoutOnly=true});local scales={.7,.75,.8,1,1.2,1.5};local count=0
    for _,a in ipairs(scales)do for _,b in ipairs(scales)do if a~=b then
        h:Viewport(1920/a,1080/a,a,1920,1080);local p=Save(h,800,400,420,286)
        h:Viewport(1920/b,1080/b,b,1920,1080);local x,y,w,hh=Resolve(h,p,420,286);Full(h.S.Layout:GetContext(),x,y,w,hh)
        Eq(x,p.normalizedCenterX*(1920/b)-210);Eq(y,p.normalizedCenterY*(1080/b)-143);count=count+1
    end end end
    print('MATRIX UI-scale '..count..' cases')
end)
Test('real shell and FloatingSurface fit preferred size without store write',function()
    local h=Boot();h:Viewport(2560,1440);local state=Save(h,1500,580,900,800);local before=Snap(state)
    local surface=h:Surface(state);assert(surface:Show(true));h:Viewport(1024,768);h.S.Layout:GetContext(true);assert(surface:ApplyLayout(true))
    Full(h.S.Layout:GetContext(),surface.window.x,surface.window.y,surface.window.w,surface.window.h)
    assert(Snap(state)==before and h.writes==0,'runtime projection overwrote preferred store')
    h:Viewport(2560,1440);h.S.Layout:GetContext(true);assert(surface:ApplyLayout(true));Eq(surface.window.w,900);Eq(surface.window.h,800);Eq(surface.window.x,1500);Eq(surface.window.y,580)
end)
Test('create/show runtime reads do not normalize mutable Store in place',function()
    local h=Boot();local state={width=420,height=286,userMoved=false};local before=Snap(state)
    local surface=h:Surface(state);surface:GetState();assert(surface:Show(true));assert(Snap(state)==before,'Store mutated on read')
end)
Test('hard reset refreshes context and native diff-cache even same requested rect',function()
    local h=Boot();local state=Save(h,1300,700,420,286);local surface=h:Surface(state);assert(surface:Show(true))
    h:Viewport(1024,768,.75);surface.window.x=9000;surface.window.y=-5000;surface.window.visible=false
    assert(surface:ResetLayout(true));Full(h.S.Layout:GetContext(),surface.window.x,surface.window.y,surface.window.w,surface.window.h)
    assert(surface.window.visible and not state.userMoved and not state.minimized,'reset did not reveal window')
    local x,y=surface.window.x,surface.window.y;surface.window.x=9000;surface.window.y=-9000;surface.window.visible=false
    assert(surface:ResetLayout(true));Eq(surface.window.x,x);Eq(surface.window.y,y);assert(surface.window.visible,'cached visible suppressed native show')
end)
Test('native anchor refusal must reject reset and not report success',function()
    local h=Boot();local state=Save(h,500,300,420,286);local before=Snap(state);local surface=h:Surface(state);assert(surface:Show(true))
    h.rejectAnchor=true;assert(surface:ResetLayout(true)==false,'rejected native placement reported success');h.rejectAnchor=false
    assert(Snap(state)==before,'failed native reset left different Store')
end)
Test('metrics revalidation survives main host absent',function()
    local h=Boot();local surface=h:Surface(Save(h,1400,700,420,286));assert(surface:Show(true));h.S.Layout:PrimeCurrentSignature()
    h:Viewport(1024,768);h.S.Layout:PollChanges();Full(h.S.Layout:GetContext(),surface.window.x,surface.window.y,surface.window.w,surface.window.h)
end)
Test('native logical effective units are not divided by UI scale on drag',function()
    local h=Boot();h:Viewport(1920,1080,.75);local state=Save(h,300,200,420,286);local surface=h:Surface(state);assert(surface:Show(true))
    surface.window.x=500;surface.window.y=320;assert(surface.windowController:CommitGeometry('drag'))
    Eq(state.x,500);Eq(state.y,320);Eq(state.width,420);Eq(state.height,286)
end)
Test('native scaled effective units converted once',function()
    local h=Boot();h:Viewport(1920,1080,.75);h.effective=.75;local state=Save(h,300,200,420,286);local surface=h:Surface(state);assert(surface:Show(true))
    surface.window.x=500;surface.window.y=320;assert(surface.windowController:CommitGeometry('drag'));Eq(state.x,500);Eq(state.y,320)
end)
Test('compact drag preserves preferred normal size',function()
    local h=Boot();local state=Save(h,300,200,420,286);local surface=h:Surface(state);assert(surface:Show(true));assert(surface:SetMinimized(true,true))
    surface.window.x=500;surface.window.y=320;assert(surface.windowController:CommitGeometry('drag'));Eq(state.width,420);Eq(state.height,286)
    Eq(surface.window.w,156);Eq(surface.window.h,30)
end)
Test('fitted drag does not overwrite preferred normal size',function()
    local h=Boot();h:Viewport(2560,1440);local state=Save(h,1000,500,900,1000);local surface=h:Surface(state);surface:Show(true)
    h:Viewport(1024,768);h.S.Layout:GetContext(true);surface:ApplyLayout(true)
    surface.window.x=60;surface.window.y=12;assert(surface.windowController:CommitGeometry('drag'));Eq(state.height,1000)
end)
Test('metrics events bounded, lifecycle storm restarts one settle chain, release owner',function()
    local h=Boot();local L=h.S.Layout;assert(type(L.StartMetricsEvents)=='function','event-driven metrics bridge absent')
    assert(L:StartMetricsEvents());h:Fire('UI_RELOADED');h:Fire('UI_RELOADED')
    local drains=0;while next(h.tasks)~=nil and drains<20 do h:Drain();drains=drains+1 end
    assert(drains==8,'event storm did not collapse into one bounded settle chain: '..tostring(drains))
    L:StopMetricsEvents();local n2=h.samples;h:Fire('UI_RELOADED');h:Drain();assert(h.samples==n2,'released metric owner still samples')
end)
-- 中文维护：第二轮调用链回归，不依赖缺失的旧 gear/UI test host；Main/Host 使用真实代码。
local function BootMain(h,state)
    local S=h.S
    S.UIV3={Router={},PageHost={},ModalHost={},ToastHost={},ShellState=state,ShellSizePolicy={defaultWidth=1040,defaultHeight=700,minWidth=1,minHeight=1}}
    S.UIV3NativeAdapter={
        ApplyRect=function(_,n,owner,x,y,w,hh)local a=S.UI:EnsureAnchor(n,UIParent,x,y,owner);local b=S.UI:EnsureExtent(n,w,hh,owner);return a and b end,
        SetVisible=function(_,n,owner,v)return S.UI:EnsureVisible(n,v,owner)end,
        IsVisible=function(_,n)return n and n.visible==true end,Raise=function()return true end,
        GetExtent=function(_,n)return n.w,n.h end,
    }
    S.UIV3.MarkShellStoreDirty=function()h.writes=h.writes+1;return true end
    dofile('presentation/v3/rs_v3_shell.lua')
    local shell=S.UIV3.Shell
    shell.created=true;shell.window=h.Native(UIParent,'main');shell.root={LayoutIfNeeded=function()return true end}
    return shell
end
Test('content relayout neither samples metrics nor cancels normal drag',function()
    local h=Boot();local state=Save(h,300,200,420,286);local surface=h:Surface(state);surface:Show(true)
    local n=h.samples
    for i=1,100 do surface:ApplyLayout(false)end
    assert(h.samples==n,'content relayout became metrics polling')
    local c=surface.windowController;c:BeginInteraction('drag');surface:ApplyLayout(false)
    assert(not c.pendingPlacement,'ordinary content refresh cancels drag')
    surface.window.x=500;c:EndInteraction();assert(c:CommitGeometry('drag'));Eq(state.x,500)
end)
Test('main shell high low high preferred size and exact position',function()
    local h=Boot();h:Viewport(2560,1440);local state=Save(h,1200,520,1100,850);local before=Snap(state)
    local main=BootMain(h,state);h:Viewport(1024,768);h.S.Layout:GetContext(true)
    local x,y,w,hh=main:ResolveRect();Full(h.S.Layout:GetContext(),x,y,w,hh)
    h:Viewport(2560,1440);h.S.Layout:GetContext(true);x,y,w,hh=main:ResolveRect();Eq(x,1200);Eq(y,520);Eq(w,1100);Eq(hh,850);assert(before==Snap(state))
end)
Test('main hard reset fresh viewport and immediate native repair',function()
    local h=Boot();local state=Save(h,4000,-2000,1600,900);local main=BootMain(h,state);main.window.visible=true
    h:Viewport(1024,768);assert(type(main.ResetLayout)=='function','main hard reset absent');assert(main:ResetLayout(true))
    Full(h.S.Layout:GetContext(),main.window.x,main.window.y,main.window.w,main.window.h);assert(main.window.visible and not state.userMoved and not state.minimized)
end)
Test('WidgetHost reset repairs visibleRequested even inconsistent shell flags',function()
    local h=Boot();local surface=h:Surface(Save(h,600,400,420,286));surface:Show(true)
    dofile('presentation/v3/widgets/rs_v3_widget_host.lua');local host=h.S.UIV3.WidgetHost
    host:Register('sample',{featureId='life_trade',resettable=true})
    host.instances.sample={surface=surface,shell=surface.shell,ResetLayout=function()return surface:ResetLayout(true)end}
    host.visible.sample=true;surface.visible=false;surface.shell.visible=false;surface.window.visible=false;surface.window.x=9999
    assert(host:ResetLayout('sample'));assert(surface.window.visible,'requested-visible window still hidden after Host Reset')
end)
Test('on-demand Host diagnostic no ensurePreferences or Store writes',function()
    local h=Boot();local state=Save(h,300,200,420,286);local surface=h:Surface(state);surface:Show(true)
    dofile('presentation/v3/widgets/rs_v3_widget_host.lua');local host=h.S.UIV3.WidgetHost
    host:Register('sample',{featureId='life_trade',ensurePreferences=function()error('diagnostic loaded Store')end})
    host.instances.sample={surface=surface,shell=surface.shell};host.visible.sample=true
    assert(type(host.GetPlacementDiagnostics)=='function','Host placement diagnostic absent');local before=Snap(state)
    local d=host:GetPlacementDiagnostics('sample');assert(d.windowId and d.visibleRequested and d.nativeVisible and d.recoverable);Eq(d.x,300);assert(Snap(state)==before)
end)
Test('direct WindowShell participates in registry and does not drift',function()
    local h=Boot();h:Viewport(2560,1440)
    local shell=assert(h.S.UI:CreateWindowShell({id='direct',owner='direct_test',width=900,height=800,initialRect={x=1200,y=500,width=900,height=800},appearanceControls=false}))
    shell:Show(true);h.S.Layout:PrimeCurrentSignature();h:Viewport(1024,768);h.S.Layout:PollChanges()
    Full(h.S.Layout:GetContext(),shell.window.x,shell.window.y,shell.window.w,shell.window.h)
    h:Viewport(2560,1440);h.S.Layout:PollChanges();Eq(shell.window.x,1200);Eq(shell.window.y,500);Eq(shell.window.w,900);Eq(shell.window.h,800)
    shell:Destroy();assert(h.S.Layout.floatingRegistry['window_shell:direct']==nil)
end)
Test('native resize calibration frozen before changing extent',function()
    for _,effective in ipairs({1,.75})do
        local h=Boot();h:Viewport(1920,1080,.75);h.effective=effective
        local state=Save(h,300,200,420,286);local surface=h:Surface(state);surface:Show(true)
        local c=surface.windowController;assert(c:BeginInteraction('resize','BOTTOMRIGHT'))
        surface.window.w=560;surface.window.h=410;c:EndInteraction();assert(c:CommitGeometry('resize'));Eq(state.width,560);Eq(state.height,410);Eq(state.x,300)
    end
end)
Test('resize hit surface stays raised and live reflow never reconfigures native sizing capture',function()
    local h=Boot();local state=Save(h,300,200,420,286);local surface=h:Surface(state);surface:Show(true)
    local c=surface.windowController;local handle=assert(c.handles.bottom_right,'bottom-right resize handle missing')
    assert((handle.raiseCount or 0)>0,'resize surface was not raised above late-created content')
    assert(type(handle.drawables)=='table' and handle.drawables[1] and math.abs((handle.drawables[1].a or 0)-0.001)<0.000001,
        'resize handle lacks non-zero transparent hit plane')
    local before=h.resizeConfigCalls
    assert(handle.handlers.OnDragStart(),'resize drag start rejected')
    local afterStart=h.resizeConfigCalls
    assert(afterStart==before,'DragStart unexpectedly reconfigured native resize bounds')
    surface.window.w=520;surface.window.h=360
    assert(c:PulseLiveGeometry(true),'live geometry pulse failed')
    assert(h.resizeConfigCalls==afterStart,'live resize re-entered UseResizing/SetMin/SetMax and can break native capture')
    assert(handle.handlers.OnDragStop(),'resize drag stop rejected')
    assert(h.resizeConfigCalls>afterStart,'DragStop did not restore final resize bounds')
    local wd=h.S.RSUI.Windowing:Describe();assert((wd.resizeStartAttempts or 0)>=1 and (wd.resizeStartRejects or 0)==0)
end)

Test('resize deferred across viewport skips stale Store commit',function()
    local h=Boot();local state=Save(h,1000,500,900,800);local surface=h:Surface(state);surface:Show(true);local before=Snap(state)
    local c=surface.windowController;c:BeginInteraction('resize','BOTTOMRIGHT');h:Viewport(1024,768);h.S.Layout:PollChanges()
    assert(c.pendingPlacement);c:EndInteraction();assert(c:CommitGeometry('resize'));assert(Snap(state)==before)
    Full(h.S.Layout:GetContext(),surface.window.x,surface.window.y,surface.window.w,surface.window.h)
end)
Test('hard reset cancels old native DragStop callbacks',function()
    local h=Boot();local state=Save(h,300,200,420,286);local surface=h:Surface(state);surface:Show(true)
    local c=surface.windowController;assert(c.dragHandle.handlers.OnDragStart());surface.window.x=900
    assert(surface:ResetLayout(true));local before=Snap(state);local writes=h.writes
    c.dragHandle.handlers.OnDragStop();assert(Snap(state)==before and h.writes==writes,'old drag stop rewrote reset')
end)
Test('explicit reset persistence rejection leaves original exact raw Store',function()
    local h=Boot();local state={width=420,height=286,userMoved=false};local before=Snap(state)
    local surface=h:Surface(state,{persist=function()return false,'injected_save_rejection'end});surface:Show(true)
    assert(surface:ResetLayout(true)==false);assert(Snap(state)==before,'rollback normalized absent keys into Store')
end)
Test('whole matrix same viewport free windows stay fully contained without accumulation',function()
    local h=Boot({layoutOnly=true});local views={{1024,768},{1280,720},{1280,768},{1366,768},{1600,900},{1920,1080},{2560,1440},{3440,1440},{3840,2160}}
    local count=0
    for _,v in ipairs(views)do
        h:Viewport(v[1],v[2]);local w,hh=420,286
        local positions={{12,12},{v[1]-w-12,12},{12,v[2]-hh-12},{v[1]-w-12,v[2]-hh-12},{(v[1]-w)/2,(v[2]-hh)/2},{-200,100},{v[1]-80,100},{100,-8},{100,v[2]-18}}
        for _,xy in ipairs(positions)do
            local p=Save(h,xy[1],xy[2],w,hh);local before=Snap(p)
            local x,y,rw,rh=Resolve(h,p,w,hh);Full(h.S.Layout:GetContext(),x,y,rw,rh)
            for i=1,4 do local nx,ny,nw,nh=Resolve(h,p,w,hh);Eq(nx,x);Eq(ny,y);Eq(nw,rw);Eq(nh,rh) end
            assert(Snap(p)==before,'same viewport containment accumulated into Store');count=count+1
        end
    end
    print('MATRIX same-viewport '..count..' contained positions')
end)

-- 中文维护：R 入口和 Gear 是持久屏幕按钮，不套窗口外壳；仍必须消费同一 Layout/Windowing 算法。
local function BootLauncher(h,state)
    local S=h.S;S.UIV3={LauncherState=state};local stores={}
    S.Persistence={Scope={Account='account'},Lifetime={Permanent='permanent'},V3KeyPrefix='v3.',
        GetStore=function(_,id)return stores[id]end,RegisterV3Store=function(_,spec)stores[spec.id]=spec;return true end,
        MarkDirty=function()h.writes=h.writes+1;return not h.rejectPersist,'injected_persist_rejection'end}
    S.RecoveryEntry=h.Native(UIParent,'launcher',300,100,30,30);S.RecoveryEntry.visible=true
    dofile('presentation/v3/rs_v3_launcher_store.lua');return S.UIV3
end
Test('launcher defaults use current viewport, immediate reset invalidates stale cache',function()
    local h=Boot();local v=BootLauncher(h,{userMoved=false});assert(v:ApplyLauncherPlacement());Eq(h.S.RecoveryEntry.x,300);Eq(h.S.RecoveryEntry.y,100)
    h.S.RecoveryEntry.x=9999;h.S.RecoveryEntry.y=-9999;h:Viewport(1024,768)
    assert(v:ResetLauncherPlacement(true));Full(h.S.Layout:GetContext(),h.S.RecoveryEntry.x,h.S.RecoveryEntry.y,30,30)
    Eq(h.S.RecoveryEntry.x,300);Eq(h.S.RecoveryEntry.y,100)
end)
Test('launcher reset native refusal preserves exact Store',function()
    local h=Boot();local state=Save(h,1500,700,30,30);local v=BootLauncher(h,state);v:ApplyLauncherPlacement();local before=Snap(state)
    h.rejectAnchor=true;assert(v:ResetLauncherPlacement(true)==false,'launcher hid native failure');assert(before==Snap(state),'launcher changed Store before geometry acceptance')
end)
Test('launcher no default Store writes during metrics migration or same viewport show',function()
    local h=Boot();local state=Save(h,1500,700,30,30);local v=BootLauncher(h,state);local before=Snap(state)
    v:ApplyLauncherPlacement();h.S.Layout:PrimeCurrentSignature();h:Viewport(1024,768);h.S.Layout:PollChanges()
    Full(h.S.Layout:GetContext(),h.S.RecoveryEntry.x,h.S.RecoveryEntry.y,30,30);assert(before==Snap(state) and h.writes==0)
end)
local function BootGear(h)
    local S=h.S;local spec;local reads=0
    local row={id='1',storageId='one',configured=true,quickPositionCustomized=true,quickX=4000,quickY=-2000,name='gear'}
    local feature={Commands={},GetQuickButtonPolicy=function()return {width=104,height=26}end,
        GetQuickHudProjection=function()return {locked=false}end,GetQuickRows=function()reads=reads+1;return {row}end,
        GetCurrentMatch=function()return nil end}
    function feature.Commands:SetQuickPosition(_,x,y,placement)row.quickX=x;row.quickY=y;h.writes=h.writes+1;return true end
    S.Features={Gear=feature};S.Services={GearV3={GetRuntimeSnapshot=function()return {}end}}
    S.UIV3={WidgetHost={Register=function(_,id,def)spec=def;return true end}}
    S.FeatureRuntime={IsEnabled=function()return false end}
    S.UI.SetText=function(_,n,t)n.text=t;return true end;S.UI.SetButtonActive=function()return true end
    S.UI.CreateButton=function(_,p,id,text,x,y,w,hh)local n=h.Native(p,id,x,y,w,hh);S.UI:EnsureExtent(n,w,hh);S.UI:EnsureAnchor(n,UIParent,x,y);return n end
    dofile('presentation/v3/widgets/rs_v3_gear_widget.lua')
    local instance=spec.create();return instance,row,function()return reads end
end
Test('Gear old extreme x y consumes unified placement and metrics only reflows cached geometry',function()
    local h=Boot();local gear,row,reads=BootGear(h);gear.visible=true
    local record=assert(gear:EnsureButton(row,1));gear.rows={row};record.present=true
    local n=reads();h:Viewport(1024,768);h.S.Layout:GetContext(true);assert(gear:ApplyLayout(true));assert(reads()==n,'resolution called Gear projection scan')
    Full(h.S.Layout:GetContext(),record.button.x,record.button.y,record.button.w,record.button.h);Eq(h.writes,0)
end)
Test('Gear native drag pins units once, reset-era late stop is inert',function()
    local h=Boot();h:Viewport(1920,1080,.75);h.effective=.75;local gear,row=BootGear(h);gear.visible=true
    row.quickX=300;row.quickY=200;local record=assert(gear:EnsureButton(row,1));gear.rows={row}
    assert(record.button.handlers.OnDragStart());Eq(record.geometryUnitScale,.75,'Gear did not freeze calibrated effectiveScale');record.button.x=500;record.button.y=320
    record.button.handlers.OnDragStop();Eq(row.quickX,500);Eq(row.quickY,320);local n=h.writes
    record.button.handlers.OnDragStop();assert(h.writes==n,'late stop re-persisted position')
end)

Test('explicit Show repairs externally displaced native anchor despite matching diff cache',function()
    local h=Boot();local surface=h:Surface(Save(h,300,200,420,286));surface:Show(true);surface.window.x=9000;surface.window.y=-9000
    assert(surface:Show(true));Eq(surface.window.x,300);Eq(surface.window.y,200)
end)
Test('state adapter rejected persistence preserves missing keys exactly',function()
    local h=Boot();local state={width=420,height=286,userMoved=false};local before=Snap(state)
    local adapter=h.S.RSUI.FloatingSurface:CreateStateAdapter({state=state,persist=function()return false,'rejected'end})
    assert(adapter.resetLayout()==false);assert(before==Snap(state),'adapter rollback wrote default fields')
end)
Test('real DiffRenderer explicit false never poisons anchor or extent cache',function()
    local h=Boot();dofile('ui/rs_ui_framework.lua');local UI=h.S.UI
    local n=h.Native(UIParent,'real_diff',300,200,420,286)
    assert(UI:EnsureAnchor(n,UIParent,300,200,'real_diff'));assert(UI:EnsureExtent(n,420,286,'real_diff'))
    n.AddAnchor=function()return false end
    assert(UI:EnsureAnchor(n,UIParent,500,400,'real_diff')==false,'native false anchor accepted')
    assert(UI.NativeStateCache[n].anchorX~=500,'rejected anchor cached')
    n.SetExtent=function()return false end
    assert(UI:EnsureExtent(n,600,500,'real_diff')==false,'native false extent accepted')
    assert(UI.NativeStateCache[n].width~=600,'rejected extent cached')
end)
Test('live Shell chrome failure rolls back native geometry, not only Lua size',function()
    local h=Boot();local surface=h:Surface(Save(h,300,200,420,286));surface:Show(true)
    local shell=surface.shell;local layout=shell.Layout;shell.Layout=function()return false,'injected_chrome_failure'end
    assert(shell:ApplyPlacementRect(500,400,800,600,{},true)==false)
    Eq(shell.window.x,300);Eq(shell.window.y,200);Eq(shell.window.w,420);Eq(shell.window.h,286);shell.Layout=layout
end)
Test('metrics same generation restart ignores old native closure',function()
    local h=Boot();local L=h.S.Layout;L:StartMetricsEvents();h:Drain()
    local old=h.S.Api.metricsHost.handlers.OnScale;L:StopMetricsEvents();L:StartMetricsEvents();h:Drain()
    local n=h.samples;old();Eq(h.samples,n)
end)
Test('same physical resolution scale pairs fit actual windows without Store drift',function()
    for _,pair in ipairs({{.75,1},{1,.75},{.7,1.5},{1.5,.8}})do
        local h=Boot();h:Viewport(1920/pair[1],1080/pair[1],pair[1],1920,1080)
        local state=Save(h,700,300,900,800);local before=Snap(state);local surface=h:Surface(state);surface:Show(true);local initialX,initialY=surface.window.x,surface.window.y
        h.S.Layout:PrimeCurrentSignature();h:Viewport(1920/pair[2],1080/pair[2],pair[2],1920,1080);h.S.Layout:PollChanges()
        Full(h.S.Layout:GetContext(),surface.window.x,surface.window.y,surface.window.w,surface.window.h)
        h:Viewport(1920/pair[1],1080/pair[1],pair[1],1920,1080);h.S.Layout:PollChanges();Eq(surface.window.x,initialX);Eq(surface.window.y,initialY)
        assert(Snap(state)==before and h.writes==0)
    end
end)
Test('oversized semantic minimum runtime fit and addon scale roundtrip',function()
    local h=Boot();local state=Save(h,300,200,1200,900);local before=Snap(state)
    local surface=h:Surface(state,{statePolicy={defaultWidth=1200,defaultHeight=900,minWidth=1100,minHeight=800}});surface:Show(true)
    h.S.Layout:PrimeCurrentSignature();h:Viewport(1024,768);h.S.Layout:PollChanges();Full(h.S.Layout:GetContext(),surface.window.x,surface.window.y,surface.window.w,surface.window.h)
    h.S.AppState.settings.addonScale=1.5;h.S.Layout:PollChanges();Full(h.S.Layout:GetContext(),surface.window.x,surface.window.y,surface.window.w,surface.window.h)
    h.S.AppState.settings.addonScale=1;h:Viewport(1920,1080);h.S.Layout:PollChanges();Eq(surface.window.x,300);Eq(surface.window.y,168);Eq(surface.window.w,1200);Eq(surface.window.h,900)
    assert(Snap(state)==before)
end)
-- Bootstrap 先于 V3；抽取真实私有函数边界以注入启动依赖，不复制任何被测函数实现。
local function BootRecoveryHandlers(h)
    local f=assert(io.open('replicatedsuite.lua','rb'));local source=f:read('*a');f:close()
    local a=assert(source:find('local function ReadRecoveryPosition',1,true));local b=assert(source:find('local function CreateBootstrapRecoveryEntry',a,true))
    local c=assert(source:find('local function InstallRecoveryHandlers',b,true));local d=assert(source:find('function S.ActivateRecoveryEntry',c,true))
    local pre='local S=ReplicatedSuite;local RECOVERY_DRAG_MOVE_EPSILON=2;local RECOVERY_BUTTON_SIZE=30;local function SafeChat()end;local function RecoveryLeftClick()end;local function RecoveryRightClick()end;'
    return assert((loadstring or load)(pre..source:sub(a,b-1)..source:sub(c,d-1)..' return InstallRecoveryHandlers'))()
end
Test('actual bootstrap launcher drag uses frozen logical rect and rejects late stop',function()
    local h=Boot();h:Viewport(1920,1080,.75);h.effective=.75;local state={userMoved=false};BootLauncher(h,state):ApplyLauncherPlacement()
    assert(BootRecoveryHandlers(h)(h.S.RecoveryEntry));local n=h.S.RecoveryEntry
    assert(n.handlers.OnDragStart());Eq(n.rsGeometryUnitScale,.75,'launcher did not freeze calibrated effectiveScale');n.x=500;n.y=320;assert(n.handlers.OnDragStop());Eq(state.offsetX,488);Eq(state.offsetY,308)
    local writes=h.writes;n.handlers.OnDragStop();Eq(writes,h.writes)
end)

Test('calibration drag consumers freeze viewport units and cancel native leases on exit',function()
    local function Read(path)local f=assert(io.open(path,'rb'));local v=f:read('*a');f:close();return v end
    local healer=Read('presentation/v3/widgets/rs_v3_healer_raid_overlay.lua')
    assert(healer:find('GetWindowLogicalRect(root, panel.geometryUnitScale)',1,true),'healer DragStop bypasses pinned logical rect')
    assert(healer:find('panel.geometryUnitScale, panel.dragViewport = nil, nil',1,true),'healer gesture metadata not cleared')
    assert(healer:find('panel.window:StopMovingOrSizing()',1,true),'healer Stop does not cancel native move')
    assert(healer:find('S.UI:EndNativeGeometryLease(panel.window, self.owner)',1,true),'healer Stop leaks geometry lease')
    local hud=Read('presentation/v3/widgets/rs_v3_buff_hud_calibration.lua')
    assert(hud:find('GetWindowLogicalRect(panel,C.panelGeometryUnitScale)',1,true),'HUD panel DragStop bypasses pinned logical rect')
    assert(hud:find('GetWindowLogicalRect(preview,C.previewGeometryUnitScale)',1,true),'HUD preview DragStop bypasses pinned logical rect')
    assert(hud:find('self.panel:StopMovingOrSizing()',1,true) and hud:find('self.preview.root:StopMovingOrSizing()',1,true),'HUD HideOverlay does not cancel native moves')
end)
Test('external native sidecar fallbacks prefer calibrated viewport logical rect',function()
    for _,path in ipairs({'features/rs_business_bridge.lua','services/rs_auction_surface_v3.lua','services/rs_craft_surface_v3.lua'})do
        local f=assert(io.open(path,'rb'));local v=f:read('*a');f:close()
        assert(v:find('S.Layout:ResolveViewportLogicalRect(node)',1,true),path..' still uses uncalibrated external content geometry')
    end
end)
Test('native metrics registration success is not reported as unavailable',function()
    local h=Boot();local ok,err=h.S.Api:StartUiMetricsNotifications(function()end);assert(ok and err==nil)
end)
Test('screen projection host origin calibrates both RU Effective unit modes exactly once',function()
    for _,effective in ipairs({1,.75}) do
        local h=Boot({layoutOnly=true});h:Viewport(1920,1080,.75);h.effective=effective
        local host=h.Native(UIParent,'projection_host_'..tostring(effective),200,100,400,300)
        h.S.UI:EnsureAnchor(host,UIParent,200,100);h.S.UI:EnsureExtent(host,400,300)
        local ox,oy,known=h.S.Layout:GetUiParentLocalOrigin(host)
        assert(known==true,'projection origin unavailable');Eq(ox,200);Eq(oy,100)
        local x,y=h.S.Layout:ScreenPointToWidgetLocal(host,500,300);Eq(x,300);Eq(y,200)
    end
end)
Test('snap target reads share logical units at UI Scale .75',function()
    local h=Boot();h:Viewport(1920,1080,.75);local L=h.S.Layout;L:GetContext(true)
    local n=h.Native(UIParent,'snap_peer',500,300,100,30);n.visible=true;h.S.UI:EnsureAnchor(n,UIParent,500,300);h.S.UI:EnsureExtent(n,100,30)
    L:RegisterScreenSnap('peer',n,{snapGroup='screen_buttons',snapKind='button'})
    local x,y,snap=L:ResolveScreenSnap('active',602,300,100,30,{enabled=true,group='screen_buttons',kind='button',distance=16,gap=0})
    assert(snap,'peer moved to wrong coordinate space');Eq(x,600);Eq(y,300)
end)
Test('real snap native refusal is not reported as committed',function()
    local h=Boot();dofile('ui/rs_ui_framework.lua');local UI=h.S.UI
    local n=h.Native(UIParent,'active_snap',602,300,100,30);n.visible=true
    local peer=h.Native(UIParent,'peer_snap',500,300,100,30);peer.visible=true
    UI:EnsureAnchor(n,UIParent,602,300,'snap');UI:EnsureExtent(n,100,30,'snap');UI:EnsureAnchor(peer,UIParent,500,300,'snap');UI:EnsureExtent(peer,100,30,'snap')
    h.S.Layout:RegisterScreenSnap('peer',peer,{snapGroup='buttons',snapKind='button'})
    n.AddAnchor=function()return false end
    assert(UI:CommitScreenSnap('active',n,{x=602,y=300,width=100,height=30,enabled=true,group='buttons',kind='button',distance=16,gap=0,owner='snap'})==false,'snap ignored native failure')
end)
Test('module diagnostics report auxiliary Shell outside WidgetHost',function()
    local h=Boot();local S=h.S;local surface=h:Surface(Save(h,300,200,420,286));surface:Show(true)
    S.FeatureRegistry={Get=function(_,id)return {id=id,route='system.diagnostics',name='test',authority='diagnostics'}end,List=function()return {}end}
    dofile('core/rs_module_diagnostics.lua');local text=assert(S.ModuleDiagnosticsHub:BuildReport('system_diagnostics'))
    assert(text:find('aux.window_shell:test_surface=',1,true),'auxiliary window omitted from diagnostics')
    assert(text:find('normalizedCenterX=',1,true) and text:find('nativeVisible=true',1,true))
end)
Test('early invalid metrics recover from real root event without a Main Host',function()
    local h=Boot();h:Viewport(0,0,1,0,0);h.S.Layout:GetContext(true)
    local state={width=420,height=286,userMoved=true,x=1800,y=900,coordinateSpace='logical-free-v2'};local before=Snap(state)
    local surface=h:Surface(state);surface:Show(true);h.S.Layout:StartMetricsEvents();h:Drain()
    h:Viewport(1920,1080);h:Fire('ENTERED_WORLD');h:Drain()
    assert(surface.window.x<1920 and surface.window.y<1080);assert(surface:GetPlacementDiagnostics().recoverable and before==Snap(state))
end)
Test('relog late viewport settles without lifecycle event and never rewrites Store',function()
    local h=Boot();local state=Save(h,700,300,420,286);local before=Snap(state)
    -- 中文维护测试：模拟同一分辨率重登。插件先看到一个“合法但临时”的 1024x768 UIParent，
    -- 因此不能靠 metricsReady=true 提前结束恢复；真实 1920x1080 随后静默出现且没有 OnScale/
    -- ENTERED_WORLD。Layout 的有界 settle one-shot 必须自行看到变化，并从原 Store intent 恢复
    -- 精确 x/y；runtime projection 绝不能产生持久化写入或累积漂移。
    h:Viewport(1024,768);h.S.Layout:GetContext(true)
    local surface=h:Surface(state);surface:Show(true)
    assert(math.abs(surface.window.x-700)>.001 or math.abs(surface.window.y-300)>.001,'fixture did not create temporary viewport projection')
    h.S.Layout:StartMetricsEvents();h:Drain()
    h:Viewport(1920,1080)
    h:Drain()
    Eq(surface.window.x,700);Eq(surface.window.y,300)
    assert(Snap(state)==before and h.writes==0,'late startup recovery rewrote persistent placement')
end)
Test('metrics settle is bounded and Stop invalidates queued relog probes',function()
    local h=Boot();local L=h.S.Layout;L:StartMetricsEvents()
    local drains=0
    while next(h.tasks)~=nil and drains<20 do h:Drain();drains=drains+1 end
    assert(drains==8,'startup settle probe budget changed or became unbounded: '..tostring(drains))
    assert(L.metricsNotifications.settleCompleted==true and L.metricsSettlePending~=true,'bounded settle did not complete')
    h:Fire('ENTERED_WORLD');assert(next(h.tasks)~=nil,'lifecycle edge did not restart settle window')
    L:StopMetricsEvents();assert(next(h.tasks)==nil,'Stop left metrics settle work queued')
    local samples=h.samples;h:Drain();Eq(h.samples,samples,'stopped settle callback sampled metrics')
end)
Test('content refresh is cache-only: no native top-level position polling',function()
    local h=Boot();local surface=h:Surface(Save(h,300,200,420,286));surface:Show(true)
    local n=0;local offset=surface.window.GetEffectiveOffset;local get=surface.window.GetOffset
    surface.window.GetEffectiveOffset=function(self)n=n+1;return offset(self)end
    surface.window.GetOffset=function(self)n=n+1;return get(self)end
    for i=1,100 do surface:ApplyLayout(false)end
    Eq(n,0,'content refresh sampled native window position')
end)
Test('free FloatingSurface drag commit cannot persist an offscreen window',function()
    local h=Boot();local state=Save(h,300,200,420,286);local surface=h:Surface(state);assert(surface:Show(true))
    local n=surface.window;local drag=surface.windowController.dragHandle;assert(drag.handlers.OnDragStart());n.x=-350;n.y=900;assert(drag.handlers.OnDragStop())
    Full(h.S.Layout:GetContext(),n.x,n.y,n.w,n.h)
    Full(h.S.Layout:GetContext(),state.x,state.y,n.w,n.h)
end)
print(string.format('VIEWPORT RESULT %d passed / %d failed (%s)',pass,fail,_VERSION))
assert(fail==0,'viewport regression failures: '..fail)

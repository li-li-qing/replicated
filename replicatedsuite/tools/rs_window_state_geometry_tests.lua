------------------------------------------------------------------------
-- Replicated Suite · 展开/缩小、屏幕吸附与分辨率回归（Lua 5.1 离线模型）
-- 作者：Replicated
-- QQ群：1104129461
------------------------------------------------------------------------
local Boot=dofile('tools/rs_window_viewport_test_host.lua')
local pass,fail=0,0
local function Test(name,fn)
    local ok,err=xpcall(fn,debug.traceback)
    if ok then pass=pass+1;print('PASS state geometry '..name)
    else fail=fail+1;print('FAIL state geometry '..name..': '..tostring(err)) end
end
local function Eq(a,b)assert(math.abs(a-b)<.001,tostring(a)..' ~= '..tostring(b))end
local function Copy(t)local n={};for k,v in pairs(t)do n[k]=v end;return n end
local function Viewport(h,w,hh,scale)
    h:Viewport(w,hh,scale)
    -- 生产 metrics 通知在重新布局前刷新上下文；模型显式模拟这一步。
    h.S.Layout:GetContext(true)
end
local function Rect(h,s)
    local x,y,w,hh=h.S.Layout:GetWindowLogicalRect(s.shell.window)
    assert(h.S.Layout:IsRectFullyVisible(x,y,w,hh),string.format('window outside viewport x=%f y=%f w=%f h=%f viewport=%f,%f scale=%f minimized=%s',x,y,w,hh,h.w,h.h,h.scale,tostring(s.shell.minimized)))
    return x,y,w,hh
end
local function Drag(s,x,y)
    local n=s.shell.titleBar.root;assert(n.handlers.OnDragStart())
    s.shell.window.x=x;s.shell.window.y=y;n.handlers.OnDragStop()
end
local function Corner(h,s)
    local x,y,w,hh=Rect(h,s);local c=h.S.Layout:GetContext()
    Eq(x+w,c.logicalWidth-c.safeRight);Eq(y+hh,c.logicalHeight-c.safeBottom)
end
Test('right bottom compact restores fully visible and retains edge through cycles',function()
    local h=Boot();local p={width=620,height=460};local s=h:Surface(p);assert(s:Show(true))
    assert(s:SetMinimized(true));Drag(s,9999,9999);Corner(h,s)
    for i=1,4 do assert(s:SetMinimized(false));Corner(h,s);Eq(s.shell.window.w,620)
        assert(s:SetMinimized(true));Corner(h,s);Eq(s.shell.window.w,s.shell.minimizedWidth)end
    Eq(p.width,620);Eq(p.height,460)
end)
Test('title buttons save actual visible rectangle and cold reload stays exact',function()
    local h=Boot();local p={width=620,height=460};local s=h:Surface(p);assert(s:Show(true));Drag(s,9999,9999)
    assert(s.shell.minimizeButton.onClick());Corner(h,s)
    Eq(p.normalizedCenterX*h.w-p.x,s.shell.window.w/2)
    Eq(p.normalizedCenterY*h.h-p.y,s.shell.window.h/2)
    local saved=Copy(p);local cold=Boot();local reload=cold:Surface(saved);assert(reload:Show(true));Corner(cold,reload)
    Eq(reload.shell.window.x,s.shell.window.x);Eq(reload.shell.window.y,s.shell.window.y)
    assert(reload.shell.titleBar.onClick());Corner(cold,reload);Eq(reload.shell.window.w,620)
end)
Test('close reopen after size switch stays exact',function()
    local h=Boot();local s=h:Surface({width=600,height=420});assert(s:Show(true));Drag(s,9999,9999)
    assert(s:SetMinimized(true));local x,y=Rect(h,s);assert(s:Show(false));assert(s:Show(true))
    local xx,yy=Rect(h,s);Eq(x,xx);Eq(y,yy);Corner(h,s)
end)
Test('screen edge snap threshold all edges and corners for both visible sizes',function()
    for _,minimized in ipairs({false,true})do
        local h=Boot();local s=h:Surface({width=420,height=286,minimized=minimized});assert(s:Show(true))
        local c=h.S.Layout:GetContext();local w,hh=s.shell.window.w,s.shell.window.h
        for _,pt in ipairs({{c.safeLeft+6,300,c.safeLeft,300},{400,c.safeTop+6,400,c.safeTop},
            {h.w-c.safeRight-w-6,300,h.w-c.safeRight-w,300},
            {400,h.h-c.safeBottom-hh-6,400,h.h-c.safeBottom-hh},
            {h.w-c.safeRight-w-6,h.h-c.safeBottom-hh-6,h.w-c.safeRight-w,h.h-c.safeBottom-hh}})do
            Drag(s,pt[1],pt[2]);local x,y=Rect(h,s);Eq(x,pt[3]);Eq(y,pt[4])
        end
        Drag(s,c.safeLeft+20,300);Eq(s.shell.window.x,c.safeLeft+20)
    end
end)
Test('snap only commits on release and native rejection never persists',function()
    local h=Boot();local p={width=420,height=286};local s=h:Surface(p);assert(s:Show(true))
    local n=s.shell.titleBar.root;assert(n.handlers.OnDragStart());s.shell.window.x=18;s.shell.window.y=300
    s.windowController:PulseLiveGeometry();Eq(s.shell.window.x,18);Eq(h.writes,0)
    n.handlers.OnDragStop();Eq(s.shell.window.x,12);Eq(h.writes,1)
    local old=p.x;assert(n.handlers.OnDragStart());s.shell.window.x=600;h.rejectAnchor=true;n.handlers.OnDragStop()
    Eq(p.x,old);Eq(h.writes,1)
end)
Test('resolution and scale matrix retains pinned edges and preferred expanded size',function()
    local count=0;local reloads={}
    for _,scale in ipairs({.75,.8,1,1.25})do for _,minimized in ipairs({false,true})do
        local h=Boot();h:Viewport(3840/scale,2160/scale,scale);h.effective=scale
        local p={width=1600,height=1000,minimized=minimized};local s=h:Surface(p);assert(s:Show(true));Drag(s,99999,99999)
        local saved=Copy(p)
        for _,v in ipairs({{1024,768},{1280,720},{1366,768},{1920,1080},{2560,1440},{3440,1440},{3840,2160}})do
            Viewport(h,v[1]/scale,v[2]/scale,scale);assert(s:ApplyLayout(true));Corner(h,s)
            assert(s:SetMinimized(not minimized));Corner(h,s);assert(s:SetMinimized(minimized));Corner(h,s)
            Eq(p.width,1600);Eq(p.height,1000)
            reloads[#reloads+1]={p=Copy(p),w=v[1]/scale,h=v[2]/scale,scale=scale};count=count+1
        end
        Viewport(h,3840/scale,2160/scale,scale);assert(s:ApplyLayout(true));Corner(h,s)
        if not minimized then Eq(s.shell.window.w,1600);Eq(s.shell.window.h,1000)end
        -- 只读迁移不改 intent；另从原始存档构建，检查尚未切换状态的迁移路径。
        reloads[#reloads+1]={p=saved,w=1280/scale,h=720/scale,scale=scale}
    end end
    -- 每次 Boot 表示冷启动，会替换进程内的 UIParent；冷启动阶段单独执行，避免模拟两个并行客户端。
    for _,r in ipairs(reloads)do
        local cold=Boot();cold:Viewport(r.w,r.h,r.scale);cold.effective=r.scale
        local reload=cold:Surface(r.p);assert(reload:Show(true));Corner(cold,reload);Eq(cold.writes,0)
    end
    print('MATRIX state/resolution/scale '..count..' cases with transitions and cold reload')
end)
Test('very small viewport fits compact and expanded independently without corrupting intent',function()
    local h=Boot();h:Viewport(140,100);local p={width=620,height=460,minimized=true};local s=h:Surface(p)
    assert(s:Show(true));Rect(h,s);Eq(s.shell.window.w,116)
    assert(s:SetMinimized(false));Rect(h,s);Eq(s.shell.window.w,116);Eq(s.shell.window.h,76)
    assert(s:SetMinimized(true));Rect(h,s);Eq(p.width,620);Eq(p.height,460)
    Viewport(h,1920,1080);assert(s:ApplyLayout(true));assert(s:SetMinimized(false));Eq(s.shell.window.w,620);Eq(s.shell.window.h,460)
end)
Test('all four corners survive full-axis fit, cold reload and restore on larger viewport',function()
    local reloads={};local count=0
    local function At(h,s,horizontal,vertical)
        local x,y,w,hh=Rect(h,s);local c=h.S.Layout:GetContext()
        Eq(horizontal=='LEFT' and x or x+w,horizontal=='LEFT' and c.safeLeft or c.logicalWidth-c.safeRight)
        Eq(vertical=='TOP' and y or y+hh,vertical=='TOP' and c.safeTop or c.logicalHeight-c.safeBottom)
    end
    for _,horizontal in ipairs({'LEFT','RIGHT'})do for _,vertical in ipairs({'TOP','BOTTOM'})do
        for _,addonScale in ipairs({.75,1,1.5})do
            local h=Boot();h:Viewport(3840,2160);h.S.AppState.settings.addonScale=addonScale
            local p={width=1600,height=1000};local s=h:Surface(p);assert(s:Show(true))
            Drag(s,horizontal=='LEFT' and -9999 or 9999,vertical=='TOP' and -9999 or 9999);At(h,s,horizontal,vertical)
            Viewport(h,1024,768);assert(s:ApplyLayout(true));At(h,s,horizontal,vertical)
            -- 从拟合状态缩小，再恢复展开，必须保存原边缘，不能把占满视口误判成默认左上。
            assert(s:SetMinimized(true));At(h,s,horizontal,vertical)
            assert(s:SetMinimized(false));At(h,s,horizontal,vertical)
            reloads[#reloads+1]={p=Copy(p),horizontal=horizontal,vertical=vertical,addonScale=addonScale}
            Viewport(h,3840,2160);assert(s:ApplyLayout(true));At(h,s,horizontal,vertical)
            assert(s:SetMinimized(true));At(h,s,horizontal,vertical);assert(s:SetMinimized(false));At(h,s,horizontal,vertical)
            Eq(p.width,1600);Eq(p.height,1000);count=count+1
        end
    end end
    for _,r in ipairs(reloads)do
        local h=Boot();h.S.AppState.settings.addonScale=r.addonScale;h:Viewport(1024,768)
        local s=h:Surface(r.p);assert(s:Show(true));At(h,s,r.horizontal,r.vertical)
        Viewport(h,3840,2160);assert(s:ApplyLayout(true));At(h,s,r.horizontal,r.vertical)
        assert(s:SetMinimized(true));At(h,s,r.horizontal,r.vertical);assert(s:SetMinimized(false));At(h,s,r.horizontal,r.vertical)
    end
    print('MATRIX full-axis edge affinity '..count..' cases, live and cold reload')
end)
Test('free position uses current visible rectangle when migrating resolution',function()
    for _,minimized in ipairs({false,true})do
        local h=Boot();local p={width=620,height=460,minimized=minimized};local s=h:Surface(p);assert(s:Show(true))
        Drag(s,400,240);assert(s:SetMinimized(not minimized));assert(s:SetMinimized(minimized))
        local rx,ry=p.normalizedCenterX,p.normalizedCenterY
        Viewport(h,2560,1440);assert(s:ApplyLayout(true))
        local x,y,w,hh=Rect(h,s);Eq(x,rx*2560-w/2);Eq(y,ry*1440-hh/2)
    end
end)
Test('collapsed title-only shells fit, persist visible dimensions and restore safely',function()
    local h=Boot();local p={width=620,height=460};local s=h:Surface(p,{minimizeMode='collapse',titleHeight=24})
    assert(s:Show(true));Drag(s,9999,9999);assert(s:SetMinimized(true));Corner(h,s)
    Eq(s.shell.window.h,24);Eq(p.normalizedCenterY*h.h-p.y,12)
    assert(s:Show(false));assert(s:Show(true));Corner(h,s);assert(s:SetMinimized(false));Corner(h,s)
end)
Test('viewport visibility tolerates float tails and respects four distinct safe insets',function()
    local h=Boot();local L=h.S.Layout;local c=L:GetContext();c.safeLeft=7;c.safeTop=11;c.safeRight=17;c.safeBottom=23
    assert(L:IsRectFullyVisible(7,11,1920-24+1e-12,1080-34))
    assert(not L:IsRectFullyVisible(7,11,1920-24+.01,1080-34))
    assert(not L:IsRectFullyVisible(7,10,100,100))
    local x,y=L:ResolveWindowEdgeSnap(13,17,420,286);Eq(x,7);Eq(y,11)
end)
Test('failed save on API or title button restores original rectangle and state',function()
    for _,button in ipairs({false,true})do for _,minimized in ipairs({false,true})do
        local reject=false;local h=Boot();local p={width=620,height=460}
        local s=h:Surface(p,{persist=function()return not reject,'save rejected'end});assert(s:Show(true));Drag(s,9999,9999)
        assert(s:SetMinimized(minimized))
        local x,y,w,hh=Rect(h,s);local before=Copy(p);reject=true
        local ok;if button then
            if minimized then ok=s.shell.titleBar.onClick() else ok=s.shell.minimizeButton.onClick() end
        else ok=s:SetMinimized(not minimized) end
        assert(ok==false);assert(s.shell.minimized==minimized and p.minimized==before.minimized)
        local xx,yy,ww,hhh=Rect(h,s);Eq(x,xx);Eq(y,yy);Eq(w,ww);Eq(hh,hhh)
    end end
end)
Test('UI reload repairs each visible size after a switch without persisting drift',function()
    for _,minimized in ipairs({false,true})do
        local h=Boot();local p={width=620,height=460};local s=h:Surface(p);assert(s:Show(true));Drag(s,9999,9999)
        assert(s:SetMinimized(minimized));local x,y,w,hh=Rect(h,s);local writes=h.writes
        h.S.Layout:PrimeCurrentSignature();assert(h.S.Layout:StartMetricsEvents())
        s.shell.window.x=50;s.shell.window.y=60;h:Fire('UI_RELOADED')
        local xx,yy,ww,hhh=Rect(h,s);Eq(x,xx);Eq(y,yy);Eq(w,ww);Eq(hh,hhh);Eq(h.writes,writes)
    end
end)
Test('ordinary independent shell uses same switch and edge snap geometry',function()
    for _,mode in ipairs({'compact','collapse'})do
        local h=Boot();local shell=assert(h.S.UI:CreateWindowShell({id='plain',owner='test',width=620,height=460,
            minimizeMode=mode,appearanceControls=false,footer=false}));assert(shell:Show(true))
        local s={shell=shell};Drag(s,9999,9999);assert(shell:SetMinimized(true,true));Corner(h,s)
        assert(shell:Show(false));assert(shell:Show(true));Corner(h,s)
        assert(shell:SetMinimized(false,true));Corner(h,s);Eq(shell.window.w,620)
    end
end)
Test('shared auxiliary state synchronizes a stale hidden instance before explicit restore',function()
    local h=Boot();local shared={width=620,height=460}
    local function Spec(id)return {id=id,getState=function()return shared end,setState=function(v)shared=v;return true end}end
    local a=h:Surface(shared,Spec('shared_a'));assert(a:Show(true));assert(a:Show(false))
    local b=h:Surface(shared,Spec('shared_b'));assert(b:Show(true));Drag(b,9999,9999)
    assert(b:SetMinimized(true));assert(b:Show(false));assert(shared.minimized and not a.shell.minimized)
    assert(a:SetMinimized(false,false));assert(a:Show(true));assert(not shared.minimized and not a.shell.minimized)
    Corner(h,a);Eq(a.shell.window.w,620);Eq(a.shell.window.h,460)
end)
Test('SetSize save rejection leaves stored state and actual compact rectangle unchanged',function()
    local h=Boot();local reject=false;local p={width=620,height=460}
    local s=h:Surface(p,{persist=function()return not reject,'save rejected'end});assert(s:Show(true));Drag(s,9999,9999)
    assert(s:SetMinimized(true));local x,y,w,hh=Rect(h,s);local before=Copy(p);reject=true
    assert(s:SetSize(700,500,true)==false)
    assert(p.width==before.width and p.height==before.height and p.minimized==before.minimized)
    local xx,yy,ww,hhh=Rect(h,s);Eq(x,xx);Eq(y,yy);Eq(w,ww);Eq(hh,hhh)
end)
Test('same compact state still reads latest shared coordinates before restoring',function()
    local h=Boot();local shared={width=620,height=460,minimized=true}
    local function Spec(id)return {id=id,getState=function()return shared end,setState=function(v)shared=v;return true end}end
    local a=h:Surface(shared,Spec('stale_a'));assert(a:Show(true));Drag(a,1300,300);assert(a:Show(false))
    local b=h:Surface(shared,Spec('stale_b'));assert(b:Show(true));Drag(b,400,200);assert(b:Show(false))
    assert(a:SetMinimized(false,false));assert(a:Show(true));Eq(a.window.x,400);Eq(a.window.y,200)
end)
Test('rejected drag and resize restore Native geometry and leave Store unchanged',function()
    for _,resize in ipairs({false,true})do
        local h=Boot();local reject=false;local p={width=620,height=460}
        local s=h:Surface(p,{persist=function()return not reject,'save rejected'end});assert(s:Show(true));Drag(s,200,200)
        local x,y,w,hh=Rect(h,s);local before=Copy(p);reject=true
        local n=resize and assert(s.windowController.handles.right) or s.shell.titleBar.root
        assert(n.handlers.OnDragStart());s.window.x=600;s.window.y=400
        if resize then s.window.w=700;s.window.h=500;s.windowController:PulseLiveGeometry(true)end
        assert(n.handlers.OnDragStop()==false,'rejected commit reported success')
        local xx,yy,ww,hhh=Rect(h,s);Eq(x,xx);Eq(y,yy);Eq(w,ww);Eq(hh,hhh)
        Eq(p.x,before.x);Eq(p.y,before.y);Eq(p.width,before.width);Eq(p.height,before.height)
        assert(s:Show(false));assert(s:Show(true));local rx,ry=Rect(h,s);Eq(rx,x);Eq(ry,y)
    end
end)
print(string.format('STATE GEOMETRY RESULT %d passed / %d failed (%s)',pass,fail,_VERSION))
assert(fail==0,'state geometry regression failures: '..fail)

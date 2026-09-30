-- 2026-09-30 UI position reload regression. Development only; never in toc.g.
-- Execute the real Layout/Windowing/Shell/Surface. Native reset timing, root units,
-- disk round trips and rejected native writes are fault models, not RU certification.
local Boot = dofile('tools/rs_window_viewport_test_host.lua')
local passed, failed = 0, 0
local function Eq(a,b,label)
    assert(type(a)=='number' and math.abs(a-b)<0.001,(label or 'coordinate')..': '..tostring(a)..' ~= '..tostring(b))
end
local function Copy(t)
    local out={};for k,v in pairs(t) do out[k]=type(v)=='table' and Copy(v) or v end;return out
end
local function Same(a,b)
    for k,v in pairs(a)do if type(v)=='table' then assert(type(b[k])=='table');Same(v,b[k])else assert(b[k]==v,'changed state field '..tostring(k))end end
    for k in pairs(b)do assert(a[k]~=nil,'added state field '..tostring(k))end
end
local function Test(name,fn)
    local ok,err=xpcall(fn,debug.traceback)
    if ok then passed=passed+1;print('PASS reload-position '..name)
    else failed=failed+1;print('FAIL reload-position '..name..'\n'..tostring(err))end
end
local function State(h,x,y,w,hh)
    local p={width=w or 420,height=hh or 286,userMoved=true}
    h.S.Layout:GetContext(true);h.S.Layout:StorePlacementRect(p,x or 300,y or 200,p.width,p.height,{mode='free'})
    return p
end
local function Surface(h,p,id)
    local s=h:Surface(p,{id=id or 'reload_surface'});assert(s:Show(true));return s
end
local function Start(h)h.S.Layout:PrimeCurrentSignature();assert(h.S.Layout:StartMetricsEvents())end
local function Drift(s,dx,dy)s.window.x=s.window.x+(dx or 80);s.window.y=s.window.y+(dy or 24)end
local function Drain(h,n)for _=1,n or 9 do h:Drain()end end

Test('unchanged viewport UI_RELOADED repairs all visible shells without saving',function()
    local h=Boot();local p=State(h,200,160);local q=State(h,740,360)
    local a,b=Surface(h,p,'one'),Surface(h,q,'two');local pa,pb=Copy(p),Copy(q);Start(h)
    Drift(a);Drift(b,125,40);h:Fire('UI_RELOADED')
    Eq(a.window.x,200);Eq(a.window.y,160);Eq(b.window.x,740);Eq(b.window.y,360)
    Same(p,pa);Same(q,pb);Eq(h.writes,0)
end)
Test('late native anchor reset is repaired even when metrics never change',function()
    local h=Boot();local p=State(h,340,220);local s=Surface(h,p);local before=Copy(p);Start(h)
    Drain(h,3);Drift(s,96,32);h:Drain()
    Eq(s.window.x,340);Eq(s.window.y,220);Same(p,before);Eq(h.writes,0)
end)
Test('last bounded settle attempt still verifies native geometry',function()
    local h=Boot();local s=Surface(h,State(h,320,210));Start(h);Drain(h,7);Drift(s,60,0);h:Drain()
    Eq(s.window.x,320);assert(h.S.Layout.metricsNotifications.settleCompleted==true)
    assert(next(h.tasks)==nil,'settle installed an unbounded task')
end)
Test('same-metrics lifecycle repair never takes over an active user drag',function()
    local h=Boot();local p=State(h,300,200);local s=Surface(h,p);Start(h)
    local c=s.windowController;assert(c:BeginInteraction('drag'));s.window.x=440;s.window.y=255
    h:Fire('UI_RELOADED');Drain(h,3);Eq(s.window.x,440);assert(not c.pendingPlacement,'same-metrics repair cancelled user gesture')
    c:EndInteraction();assert(c:CommitGeometry('drag'));Eq(p.x,440);Eq(p.y,255)
    Drain(h);Eq(s.window.x,440);Eq(p.x,440);Eq(h.writes,1)
end)
Test('unchanged healthy geometry does not acquire a permanent poll or rewrite anchors',function()
    local h=Boot();local s=Surface(h,State(h,310,220));local writes=0
    local apply=h.S.RSUI.Windowing.ApplyGeometry
    h.S.RSUI.Windowing.ApplyGeometry=function(self,...)writes=writes+1;return apply(self,...)end
    Start(h);Drain(h);Eq(writes,0);assert(next(h.tasks)==nil);Eq(h.writes,0)
end)
Test('stopped generation rejects queued reconciliation callbacks',function()
    local h=Boot();local s=Surface(h,State(h,300,200));Start(h)
    local old=assert(h.tasks.rsui_metrics_settle);h.S.Layout:StopMetricsEvents();Drift(s,75,20);old()
    Eq(s.window.x,375);Eq(s.window.y,220);assert(next(h.tasks)==nil);Eq(h.writes,0)
end)
Test('native recovery rejection stays observable and does not edit persistent intent',function()
    local h=Boot();local p=State(h,300,200);local s=Surface(h,p);local before=Copy(p);Start(h)
    Drift(s);h.rejectAnchor=true;h:Fire('UI_RELOADED');Same(p,before);Eq(h.writes,0)
    local metrics=h.S.RSUI.Windowing.metrics
    assert((metrics.positionRepairFailures or 0)>0,'native geometry failure was hidden')
    h.rejectAnchor=false;h:Drain();Eq(s.window.x,300)
end)
Test('scale-only change with an unchanged logical canvas cannot shift a minimized window',function()
    local h=Boot();local p=State(h,300,200);local s=Surface(h,p);assert(s:SetMinimized(true,true))
    local before=Copy(p);h.S.Layout:PrimeCurrentSignature();h:Viewport(1920,1080,.8,1536,864);h.S.Layout:PollChanges()
    Eq(s.window.x,300);Eq(s.window.y,200);Same(p,before)
end)
Test('scale-only change also preserves expanded windows last dragged as compact icons',function()
    local h=Boot();local p=State(h,300,200);local s=Surface(h,p);assert(s:SetMinimized(true,true))
    local c=s.windowController;assert(c:BeginInteraction('drag'));s.window.x=600;s.window.y=300;c:EndInteraction();assert(c:CommitGeometry('drag'))
    assert(s:SetMinimized(false,true));local before=Copy(p);h.S.Layout:PrimeCurrentSignature();h:Viewport(1920,1080,.75,1440,810);h.S.Layout:PollChanges()
    Eq(s.window.x,600);Eq(s.window.y,300);Same(p,before)
end)
Test('native same-metrics recovery uses UIParent local units once at nonzero root origin',function()
    for _,unit in ipairs({1,.8}) do
        local h=Boot();h:Viewport(1280,960,.8,1024,768);h.effective=unit;UIParent.x=71;UIParent.y=43
        local p=State(h,310,210);local s=Surface(h,p);Start(h);Drift(s,90,35);h:Fire('UI_RELOADED')
        Eq(s.window.x,310);Eq(s.window.y,210);Eq(h.writes,0)
    end
end)
Test('repeated cold construction preserves source intent rather than accumulating a recovery delta',function()
    local p
    for i=1,12 do
        local h=Boot();h:Viewport(1280,960,.8,1024,768);h.effective=.8
        p=p and Copy(p) or State(h,290,190)
        local before=Copy(p);local s=Surface(h,p);Start(h);Drift(s,80,20);Drain(h)
        Eq(s.window.x,290);Eq(s.window.y,190);Same(p,before);Eq(h.writes,0);h.S.Layout:StopMetricsEvents();s:Destroy()
    end
end)
Test('full-size and compact windows recover independently without changing their sizes',function()
    local h=Boot();local a=Surface(h,State(h,300,200),'expanded');local p=State(h,900,450);p.minimized=true
    local b=Surface(h,p,'compact');local bw,bh=b.window.w,b.window.h;Start(h);Drift(a);Drift(b)
    h:Fire('UI_RELOADED');Eq(a.window.x,300);Eq(a.window.w,420);Eq(b.window.x,900);Eq(b.window.w,bw);Eq(b.window.h,bh)
end)

-- Fixture adapters only; production placement functions are never reimplemented here.
local function Launcher(h)
    local S=h.S;S.UIV3={LauncherState=State(h,300,100,30,30)};local stores={}
    S.Persistence={Scope={Account='account'},Lifetime={Permanent='permanent'},V3KeyPrefix='v3.',
        GetStore=function(_,id)return stores[id]end,RegisterV3Store=function(_,spec)stores[spec.id]=spec;return true end,
        MarkDirty=function()h.writes=h.writes+1;return true end}
    S.RecoveryEntry=h.Native(UIParent,'launcher',300,100,30,30);S.RecoveryEntry.visible=true
    dofile('presentation/v3/rs_v3_launcher_store.lua');assert(S.UIV3:ApplyLauncherPlacement());return S.RecoveryEntry
end
local function Gear(h)
    local S=h.S;local definition;local reads=0
    local row={id='1',storageId='one',configured=true,quickPositionCustomized=true,quickX=300,quickY=200,name='gear'}
    local feature={Commands={},GetQuickButtonPolicy=function()return {width=104,height=26}end,
        GetQuickHudProjection=function()return {locked=false}end,GetQuickRows=function()reads=reads+1;return {row}end,
        GetCurrentMatch=function()return nil end}
    function feature.Commands:SetQuickPosition(_,x,y)row.quickX=x;row.quickY=y;h.writes=h.writes+1;return true end
    S.Features={Gear=feature};S.Services={GearV3={GetRuntimeSnapshot=function()return {}end}}
    S.UIV3={WidgetHost={Register=function(_,id,def)definition=def;return true end}}
    S.FeatureRuntime={IsEnabled=function()return false end}
    S.UI.SetText=function(_,n,t)n.text=t;return true end;S.UI.SetButtonActive=function()return true end
    S.UI.CreateButton=function(_,parent,id,text,x,y,w,hh)local n=h.Native(parent,id,x,y,w,hh);S.UI:EnsureExtent(n,w,hh);S.UI:EnsureAnchor(n,UIParent,x,y);return n end
    dofile('presentation/v3/widgets/rs_v3_gear_widget.lua')
    local instance=definition.create();instance.visible=true
    local record=assert(instance:EnsureButton(row,1));instance.rows={row};record.present=true;record.button.visible=true
    return record,row,function()return reads end
end
Test('independent launcher participates without moving an active native drag',function()
    local h=Boot();local n=Launcher(h);Start(h);n.x=400;n.rsMoving=true;h:Fire('UI_RELOADED');Eq(n.x,400)
    n.rsMoving=false;h:Drain();Eq(n.x,300);Eq(h.writes,0)
end)
Test('independent gear buttons reconcile without feature scans or position saves',function()
    local h=Boot();local r,row,reads=Gear(h);local n=reads();Start(h);r.button.x=390
    h:Fire('UI_RELOADED');Eq(r.button.x,300);Eq(row.quickX,300);Eq(h.writes,0);Eq(reads(),n)
    r.dragging=true;r.button.x=444;h:Drain();Eq(r.button.x,444)
end)
Test('hidden shells and detached windows are not forced visible or rewritten',function()
    local h=Boot();local a=Surface(h,State(h,300,200),'hidden');local b=Surface(h,State(h,700,400),'destroyed')
    Start(h);a:Show(false);local n=b.window;b:Destroy();Drift(a);n.x=790;h:Fire('UI_RELOADED')
    Eq(a.window.x,380);Eq(n.x,790);assert(a.window.visible==false);Eq(h.writes,0)
end)
Test('silent Native anchor failure is not certified by its own diff cache',function()
    local h=Boot();local s=Surface(h,State(h,300,200));Start(h);Drift(s)
    local original=h.S.UI.EnsureAnchor
    h.S.UI.EnsureAnchor=function(self,n,parent,x,y)
        local r=self.NativeStateCache[n] or {};self.NativeStateCache[n]=r;r.anchorParent=parent;r.anchorX=x;r.anchorY=y
        return true,true
    end
    h:Fire('UI_RELOADED');assert((h.S.RSUI.Windowing.metrics.positionRepairFailures or 0)>0);Eq(s.window.x,380)
    h.S.UI.EnsureAnchor=original;h:Drain();Eq(s.window.x,300);Eq(h.writes,0)
end)
Test('missing Native readback does not self-validate from cached anchor fallback',function()
    local h=Boot();local s=Surface(h,State(h,300,200));Start(h);Drift(s);s.window.GetEffectiveOffset=function()error('unavailable')end
    h:Fire('UI_RELOADED');Eq(s.window.x,380);assert((h.S.RSUI.Windowing.metrics.positionReadUnavailable or 0)>0);Eq(h.writes,0)
end)
Test('real DiffRenderer lease cache invalidation and root string anchors remain compatible',function()
    local h=Boot();h:Viewport(1280,960,.8,1024,768);h.effective=.8
    local s=Surface(h,State(h,300,200));local UI=h.S.UI;local W=h.S.RSUI.Windowing
    -- Keep native control creation fixture, load REAL DiffRenderer + lease functions.
    dofile('ui/rs_ui_framework.lua')
    assert(W:ApplyGeometry(s.window,'viewport_test',300,200,420,286,true));Start(h);Drift(s)
    h:Fire('UI_RELOADED');Eq(s.window.x,300);Eq(s.window.y,200)
    assert(UI:BeginNativeGeometryLease(s.window,'viewport_test','drag'));s.window.x=455
    h:Drain();Eq(s.window.x,455);assert(UI:EndNativeGeometryLease(s.window,'viewport_test'))
    assert(UI.NativeStateCache[s.window]==nil,'actual lease must invalidate native mirror')
    assert(W:ApplyGeometry(s.window,'viewport_test',455,200,420,286,true));Drain(h);Eq(s.window.x,455);Eq(h.writes,0)
end)
Test('real rejected native replay retains bounded retry intent but a user command replaces it',function()
    local h=Boot();local s=Surface(h,State(h,300,200));local W=h.S.RSUI.Windowing;dofile('ui/rs_ui_framework.lua')
    assert(W:ApplyGeometry(s.window,'viewport_test',300,200,420,286,true));Start(h);Drift(s)
    local anchor=s.window.AddAnchor;s.window.AddAnchor=function()return false end
    h:Fire('UI_RELOADED');assert(W.metrics.positionRepairFailures>0)
    s.window.AddAnchor=anchor;h:Drain();Eq(s.window.x,300)
    Drift(s);s.window.AddAnchor=function()return false end;h:Fire('UI_RELOADED')
    s.window.AddAnchor=anchor;assert(W:ApplyGeometry(s.window,'viewport_test',550,250,420,286,true))
    Drain(h);Eq(s.window.x,550);Eq(s.window.y,250);Eq(h.writes,0)
end)
Test('on-demand geometry evidence separates saved expected and observed coordinates without writes',function()
    local h=Boot();local p=State(h,300,200);local s=Surface(h,p);Start(h);Drift(s);local before=Copy(p)
    local W=h.S.RSUI.Windowing;assert(type(W.GetPositionDiagnostics)=='function','position evidence provider absent')
    W.ApplyGeometry=function()error('diagnostic attempted geometry repair')end
    local out=W:GetPositionDiagnostics();assert(out.patch=='ui-position-reload-1');Eq(out.total,1)
    local row=out.windows[1];Eq(row.geometry.expected.x,300);Eq(row.geometry.observed.x,380)
    Eq(row.placement.savedX,300);Eq(row.geometry.rawOffset.x,380);assert(row.geometry.drifted==true)
    Same(p,before);Eq(h.writes,0)
    row.geometry.expected.x=999;Eq(h.S.UI.NativeStateCache[s.window].anchorX,300)
end)
Test('ordinary paginated report includes readonly UI position evidence without replaying windows',function()
    local h=Boot();local s=Surface(h,State(h,300,200));Drift(s)
    h.S.DiagnosticsManager={};h.S.FoundationGate={Run=function()return {status='PASS',blockers=0,warnings=0,checks={}}end}
    dofile('core/rs_self_check_report.lua');local D=h.S.DiagnosticsManager
    D.BuildPersistenceFailureReport=function()return {}end;D.GetPersistenceFailureChoices=function()return {}end
    D.BuildFeatureStatusRows=function()return {}end
    h.S.RSUI.Windowing.ApplyGeometry=function()error('report must not fix positions')end
    local text=assert(D:BuildPagedSelfCheckReport())
    assert(text:find('[UI_POSITION]',1,true),'paged report omitted UI position summary')
    assert(text:find('[UI_WINDOW]',1,true),'paged report omitted per-window evidence')
    assert(text:find('ui-position-reload-1',1,true),'patch identifier missing')
    Eq(s.window.x,380);Eq(h.writes,0)
end)


Test('an externally completed retry re-primes the mirror instead of restoring the rejected rollback',function()
    local h=Boot();local s=Surface(h,State(h,300,200));Start(h);Drift(s)
    local native=h.S.UI.EnsureAnchor;local attempts=0
    h.S.UI.EnsureAnchor=function(self,...)attempts=attempts+1;if attempts==1 then return false,false,'one transient rejection' end;return native(self,...)end
    h:Fire('UI_RELOADED');h.S.UI.EnsureAnchor=native
    -- Native's delayed restore completes independently before our next settle.
    s.window.x=300;s.window.y=200;Drain(h)
    Eq(s.window.x,300);Eq(s.window.y,200);Eq(h.S.UI.NativeStateCache[s.window].anchorX,300);Eq(h.writes,0)
end)
Test('one failed placement evidence provider cannot hide other windows',function()
    local h=Boot();Surface(h,State(h,300,200),'evidence_a');Surface(h,State(h,750,400),'evidence_b')
    local registry=h.S.Layout.floatingRegistry
    for _,item in pairs(registry)do if item.widget.x==300 then item.options.getPlacementDiagnostics=function()error('one broken observer')end end end
    local out=h.S.RSUI.Windowing:GetPositionDiagnostics()
    Eq(out.total,2);Eq(#out.windows,2);Eq(out.providerFailures,1)
    Eq(out.windows[2].geometry.expected.x,750);Eq(h.writes,0)
end)
Test('saved diagnostic coordinates update only on real user geometry commit',function()
    local h=Boot();local p=State(h,300,200);local s=Surface(h,p);local c=s.windowController
    assert(c:BeginInteraction('drag'));s.window.x=550;s.window.y=320;c:EndInteraction();assert(c:CommitGeometry('drag'))
    local info=s:GetPlacementDiagnostics();Eq(info.savedX,550);Eq(info.savedY,320)
    Drift(s);Start(h);h:Drain();local after=s:GetPlacementDiagnostics();Eq(after.savedX,550);Eq(h.writes,1)
end)
Test('recovery stays per-generation and finishes all bounded work across a viewport matrix',function()
    for _,dims in ipairs({{1024,768},{1280,768},{1920,1080},{2560,1440}})do
        for _,scale in ipairs({.75,.8,1,1.25})do
            for _,unit in ipairs({1,scale})do
                local h=Boot();h:Viewport(dims[1],dims[2],scale);h.effective=unit
                local p=State(h,200,160);local s=Surface(h,p);local before=Copy(p);Start(h)
                for _=1,8 do Drift(s,64,17);h:Drain();Eq(s.window.x,200);Eq(s.window.y,160)end
                Same(p,before);Eq(h.writes,0);assert(next(h.tasks)==nil)
            end
        end
    end
end)


Test('one physical pixel of UIParent extent rounding cannot move a minimized window by half its old width',function()
    local h=Boot();h:Viewport(1280,960,.8,1024,768);h.effective=.8
    local p=State(h,300,200);local s=Surface(h,p);assert(s:SetMinimized(true,true));local before=Copy(p)
    h.S.Layout:PrimeCurrentSignature()
    for i=1,12 do
        h:Viewport(i%2==1 and 1279 or 1280,i%2==1 and 959 or 960,.8,1024,768)
        h.S.Layout:PollChanges();Eq(s.window.x,300);Eq(s.window.y,200)
    end
    Same(p,before)
end)

print(string.format('RELOAD POSITION RESULT %d passed / %d failed (%s)',passed,failed,_VERSION))
assert(failed==0,'reload-position regression failures: '..failed)

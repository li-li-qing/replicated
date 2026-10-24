------------------------------------------------------------------------
-- Replicated Suite · 主外壳可见性测试
-- 作者：Replicated
-- QQ群：1104129461
--
-- 主窗口显示边沿回归：真实 Shell/Adapter/Diff/Windowing，Native Show 模拟引擎出生定位。
-- 不进入 toc.g；离线通过不等于 RU 客户端实测。
------------------------------------------------------------------------
local Boot = dofile('tools/rs_window_viewport_test_host.lua')
local passed, failed = 0, 0
local function Test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then passed = passed + 1; print('PASS main visibility '..name)
    else failed = failed + 1; print('FAIL main visibility '..name..': '..tostring(err)) end
end
local function Eq(a, b, name)
    assert(type(a)=='number' and math.abs(a-b)<.00001, (name or 'coordinate')..': '..tostring(a)..' / '..tostring(b))
end
local function Main(scale)
    local h = Boot()
    h:Viewport(1920/scale,1080/scale,scale,1920,1080); h.effective = scale
    UIParent.visible = true
    local S = h.S
    dofile('ui/rs_ui_framework.lua')
    dofile('presentation/v3/rs_v3_native_adapter.lua')
    local state = {width=1057.01,height=841.004,userMoved=true}
    S.Layout:GetContext(true)
    S.Layout:StorePlacementRect(state,657.312,167.233,state.width,state.height,{mode='free'})
    S.UIV3 = {Router={},PageHost={},ModalHost={},ToastHost={},ShellState=state,
        ShellSizePolicy={defaultWidth=1040,defaultHeight=700,minWidth=1,minHeight=1}}
    function S.UIV3:MarkShellStoreDirty() h.writes=h.writes+1; return true end
    dofile('presentation/v3/rs_v3_shell.lua')
    local main = S.UIV3.Shell
    main.created=true; main.window=h.Native(UIParent,'v3_shell_root')
    main.root={LayoutIfNeeded=function()return true end}
    main.window.rsUiLogicalId='v3_shell_root'
    assert(S.UI:ClaimNativeAuthority(main.window,main.owner,'strict'))
    local nativeShow = main.window.Show
    main.window.showEdges=0; main.window.showCalls=0; main.window.geometryWrites=0
    local nativeAnchor = main.window.AddAnchor
    function main.window:AddAnchor(...)
        self.geometryWrites=self.geometryWrites+1
        if self.rejectAnchor then return false end
        return nativeAnchor(self,...)
    end
    function main.window:Show(visible)
        self.showCalls=self.showCalls+1
        if visible and self.rejectShow then return false end
        if not visible and self.rejectHide then error('injected_hide_rejection') end
        local edge = visible and not self.visible
        local result = nativeShow(self,visible)
        if edge then
            self.showEdges=self.showEdges+1
            if self.shiftOnShow then self.x=self.x+53; self.y=self.y+29 end
            if self.rejectAfterShow then self.rejectAnchor=true end
        end
        return result
    end
    return h,main,state
end

for _,scale in ipairs({1,.9}) do
    Test('initial native Show relocation is committed before return scale='..scale,function()
        local h,main=Main(scale); main.window.shiftOnShow=true
        assert(main:Open())
        Eq(main.window.x,main.lastRect.x); Eq(main.window.y,main.lastRect.y)
        assert(main:Open()) -- 页面导航再次调用 Open，不能把合法显示边沿计为越权。
        assert(h.S.UI:GetAuthoritySnapshot().violations==0,'Show relocation became an authority blocker')
        assert(h.writes==0,'native Show relocation overwrote saved placement')
        assert(next(h.tasks)==nil,'Show introduced background polling')
    end)
end
Test('hide and reopen reconciles a new Show edge',function()
    local h,main=Main(.9); assert(main:Open()); assert(main:Close('test'))
    main.window.shiftOnShow=true; assert(main:Open())
    Eq(main.window.x,main.lastRect.x); Eq(main.window.y,main.lastRect.y)
    assert(h.S.UI:GetAuthoritySnapshot().violations==0)
end)
Test('Show relocation does not create report anchor blocker on next navigation',function()
    local h,main=Main(.9); main.window.shiftOnShow=true
    assert(main:Open()); assert(main:Open())
    local authority=h.S.UI:GetAuthoritySnapshot()
    assert(authority.violations==0,'v3_shell_root blocker reproduced: anchor='..tostring(authority.byField.anchor))
end)
Test('already visible navigation neither forces geometry nor replays Show',function()
    local h,main=Main(.9); assert(main:Open())
    local writes,edges,calls=main.window.geometryWrites,main.window.showEdges,main.window.showCalls
    for _=1,10 do assert(main:Open()) end
    assert(main.window.geometryWrites==writes,'visible Open rewrote native geometry')
    assert(main.window.showEdges==edges,'visible Open created another Show edge')
    assert(main.window.showCalls==calls,'visible Open replayed native Show')
    assert(h.S.UI:GetAuthoritySnapshot().violations==0)
end)
Test('unexpected visible anchor change remains a strict blocker',function()
    local h,main=Main(.9); assert(main:Open()); main.window.x=main.window.x+53
    assert(main:Open())
    local authority=h.S.UI:GetAuthoritySnapshot()
    assert(authority.violations==1 and authority.byField.anchor==1,'strict anchor detection was weakened')
    Eq(main.window.x,main.lastRect.x)
    assert(main:Open()); assert(h.S.UI:GetAuthoritySnapshot().violations==1,'history was cleared')
end)
Test('native Show rejection remains an error and leaves root hidden',function()
    local h,main=Main(.9); main.window.rejectShow=true
    local ok,err=main:Open()
    assert(ok==false and type(err)=='string','native Show rejection was hidden')
    assert(not main.window.visible and h.writes==0)
end)
Test('post Show geometry rejection fails Open and restores hidden state',function()
    local h,main=Main(.9); main.window.shiftOnShow=true; main.window.rejectAfterShow=true
    local ok,err=main:Open()
    assert(ok==false and type(err)=='string','post Show geometry rejection was hidden')
    assert(not main.window.visible,'failed Show transaction left root visible')
    assert(h.writes==0,'failed Show transaction persisted geometry')
    main.window.rejectAfterShow=false; main.window.rejectAnchor=false
    assert(main:Open()); Eq(main.window.x,main.lastRect.x)
    assert(h.S.UI:GetAuthoritySnapshot().violations==0,'known failed Show edge became strict violation')
end)
Test('failed restore preserves minimized preference without saving',function()
    local h,main,state=Main(.9); state.minimized=true; main.window.rejectAfterShow=true
    assert(main:Open()==false)
    assert(state.minimized and not main.window.visible and h.writes==0,'failed restore changed minimized preference')
end)
Test('rejected visibility rollback remains observable',function()
    local h,main=Main(.9); main.window.rejectAfterShow=true; main.window.rejectHide=true
    local ok,err=main:Open()
    assert(ok==false and err:find('visibility_rollback_rejected',1,true),'rollback rejection was hidden')
    assert(main.window.visible and h.writes==0)
end)
-- 维护：原可见性模型将 MarkShellStoreDirty 直接当成成功写盘，无法暴露立即退出时的位置丢失。
-- 这里加载真实 ShellStore/Persistence/Transport，仅 Native 读写使用内存磁盘，不操作用户存档。
local function PersistentMain(disk)
    local h,main,state=Main(1);h.disk=disk or {};h.diskWrites=0
    local function Copy(value)
        if type(value)~='table' then return value end
        local out={};for key,item in pairs(value)do out[key]=Copy(item)end;return out
    end
    ADDON={LoadData=function(_,key)return Copy(h.disk[key])end,
        SaveData=function(_,key,value)
            if h.rejectSave then return false end
            if h.dropSave then return true end -- Native 接受调用但未保存，必须靠真实回读发现，不能只测显式 false。
            h.diskWrites=h.diskWrites+1;h.disk[key]=Copy(value);return true
        end}
    local S=h.S
    dofile('core/rs_utils.lua');dofile('core/rs_reuse.lua');dofile('core/rs_api_capabilities.lua')
    dofile('core/rs_persistence_transport.lua');dofile('core/rs_persistence.lua')
    dofile('presentation/v3/rs_v3_shell_store.lua');assert(S.UIV3:EnsureShellStoreLoaded())
    return h,main,state
end
-- 补齐 Native 叶能力后运行真实 Windowing 手势；不能只直接调用 CommitWindowGeometry 就认定鼠标释放链已覆盖。
local function AttachMainGesture(h,main)
    local function Leaf(node)
        function node:Enable(value)self.enabled=value;return true end
        function node:EnablePick(value)self.pickable=value;return true end
        return node
    end
    h.S.UI.CreateEmptyWidget=function(_,parent,id,x,y,w,hh)return Leaf(h.Native(parent,id,x,y,w,hh))end
    local handle=Leaf(h.Native(main.window,'immediate_exit_main_handle'))
    main.windowController=assert(h.S.RSUI.Windowing:Attach({id='immediate_exit_main',owner=main.owner,
        window=main.window,dragHandle=handle,locked=h.S.UIV3.ShellState.locked==true,resizable=true,
        boundaryMode='free',minWidth=1,minHeight=1,
        onGeometryChanged=function(...)return main:CommitWindowGeometry(...)end,
        onLiveGeometry=function(...)return main:ApplyInteractiveGeometry(...)end}))
    return handle
end
for _,point in ipairs({{0,0},{-80,40},{450,170}})do
    Test('native drag lock and minimize survive immediate cold boot at '..point[1]..','..point[2],function()
        local h,main,state=PersistentMain();local handle=AttachMainGesture(h,main);assert(main:Open())
        local before=h.diskWrites
        assert(handle.handlers.OnDragStart());main.window.x,main.window.y=point[1],point[2]
        assert(h.diskWrites==before,'drag preview must not write persistence')
        assert(handle.handlers.OnDragStop());assert(main:SetLocked(true,true));assert(main:ToggleMinimized())
        local x,y=state.x,state.y
        assert(h.diskWrites>=before+3,'completed drag/lock/minimize returned before durable saves')
        assert(not h.S.Persistence:GetStore('v3.shell').needsBarrierVerify,'combined exit sequence lacks a readback barrier')
        -- 立即创建新一代宿主，不执行 Scheduler、Stop 或 Flush；精确模拟退出前没有下一帧的边界。
        local cold,restored,saved=PersistentMain(h.disk);local coldHandle=AttachMainGesture(cold,restored)
        assert(restored:ApplyLayout(false));assert(restored:ApplyMinimizedState(false))
        Eq(saved.x,x);Eq(saved.y,y);Eq(restored.window.x,x);Eq(restored.window.y,y)
        assert(saved.locked==true and saved.minimized==true and restored.window.visible==false,'cold startup lost lock/minimize state')
        assert(coldHandle.handlers.OnDragStart()==false,'locked cold-restored window still accepts dragging')
        assert(restored:Open());assert(restored:SetLocked(false,true))
        local _,_,again=PersistentMain(cold.disk)
        Eq(again.x,x);Eq(again.y,y);assert(again.locked==false and again.minimized==false,'restore/unlock not durable before the next exit')
    end)
end
Test('main drag survives cold reload before any persistence heartbeat',function()
    local h,main=PersistentMain();local S=h.S
    assert(main:CommitWindowGeometry(nil,450,170,1040,700,'drag'))
    assert(h.diskWrites==1,'main drag returned before Native SaveData')
    assert(S.Persistence:GetStore('v3.shell').needsBarrierVerify==false,'geometry has no durable readback')
    local _,_,state=PersistentMain(h.disk);Eq(state.x,450);Eq(state.y,170)
end)
Test('main geometry rejects failed save and restores original intent and native rectangle',function()
    local h,main,state=PersistentMain();assert(main:Open());local x,y=main.window.x,main.window.y
    h.rejectSave=true
    local ok=main:CommitWindowGeometry(nil,460,180,1040,700,'drag')
    assert(ok==false,'main geometry reported success after failed persistence')
    assert(state.userMoved==false and state.x==nil and state.y==nil,'rejected placement replaced original intent')
    Eq(main.window.x,x);Eq(main.window.y,y)
end)
Test('main geometry rejects a successful Native call with stale disk readback',function()
    local h,main,state=PersistentMain();assert(main:Open());local x,y=main.window.x,main.window.y
    h.dropSave=true
    local ok=main:CommitWindowGeometry(nil,460,180,1040,700,'drag')
    assert(ok==false,'Native call success was mistaken for durable geometry')
    assert(state.userMoved==false and state.x==nil and state.y==nil)
    Eq(main.window.x,x);Eq(main.window.y,y)
end)
Test('main lock survives immediate cold reload and failed unlock rolls back',function()
    local h,main=PersistentMain();assert(main:SetLocked(true,true))
    assert(h.diskWrites==1,'lock only marked dirty')
    local fresh,restored,state=PersistentMain(h.disk);assert(state.locked==true)
    fresh.rejectSave=true;local ok=restored:SetLocked(false,true)
    assert(ok==false and state.locked==true,'failed unlock was presented as saved')
end)
-- 真实 Windowing 控制器验证“保存失败且 Native 解锁回滚也失败”，不能仅用没有 controller 的 Shell 表掩盖双重故障。
Test('rejected native lock rollback stays visible and can be retried without saving wrong intent',function()
    local h,main,state=PersistentMain();assert(main:Open())
    local function Leaf(node)
        function node:Enable(value)self.enabled=value;return true end
        function node:EnablePick(value)self.pickable=value;return true end
        return node
    end
    h.S.UI.CreateEmptyWidget=function(_,parent,id,x,y,w,hh)return Leaf(h.Native(parent,id,x,y,w,hh))end
    main.windowController=assert(h.S.RSUI.Windowing:Attach({id='real_main_lock',owner=main.owner,window=main.window,
        dragHandle=Leaf(h.Native(main.window,'real_main_handle')),locked=false,resizable=true,minWidth=1,minHeight=1}))
    local resize=main.window.UseResizing
    function main.window:UseResizing(enabled)
        if h.rejectUnlock and enabled then return false end
        return resize(self,enabled)
    end
    h.rejectSave=true;h.rejectUnlock=true
    local ok,err=main:SetLocked(true,true)
    assert(ok==false and tostring(err):find('回滚失败',1,true),'Native rollback rejection was hidden')
    assert(state.locked==false and main:IsLocked()==true,'persisted intent or actual lock feedback was lost')
    h.rejectSave=false;h.rejectUnlock=false
    assert(main:SetLocked(false,true));assert(main.windowController:IsLocked()==false and main:IsLocked()==false)
end)
-- 最小化和从启动器恢复共用同一持久状态，拒写时必须同时恢复窗口可见性，不能只回滚布尔字段。
Test('main minimized state survives reload and rejected transitions restore visibility',function()
    local h,main,state=PersistentMain();assert(main:Open());h.rejectSave=true
    assert(main:ToggleMinimized()==false,'failed minimize was reported as saved')
    assert(state.minimized==false and main.window.visible==true,'failed minimize left window hidden')
    h.rejectSave=false;assert(main:ToggleMinimized())
    local cold,restored,saved=PersistentMain(h.disk);assert(saved.minimized==true)
    cold.rejectSave=true;assert(restored:Open()==false,'failed restore was reported as saved')
    assert(saved.minimized==true and restored.window.visible==false,'failed restore lost minimized intent')
    cold.rejectSave=false;assert(restored:Open());assert(saved.minimized==false)
    local _,_,again=PersistentMain(cold.disk);assert(again.minimized==false,'restore remained queued')
end)
-- 设置叶控件只隔离输入；回调执行真实 Foundation Page -> Shell/App -> Store -> Native 读写链。
local function SettingsControls(h)
    local S=h.S;S.UIV3.Router.Get=function()return nil end
    local ui=dofile('tools/rs_status_ui_test_host.lua')(S)
    local makeButton=S.RSUI.Button
    S.RSUI.Button=function(self,spec)local node=makeButton(self,spec);function node:SetSelected(value)self.selected=value end;return node end
    S.UIV3Design.InfoCard=function(_,parent,spec)local node=ui.Node(spec);function node:SetData()end;return node end
    S.UIV3Design.NumericSetting=function(_,parent,spec)return ui.Node(spec)end
    dofile('presentation/v3/pages/rs_v3_foundation_pages.lua')
    assert(S.UIV3.PageHost.factories['system.settings'](nil,'system.settings'))
    return ui
end
for _,button in ipairs({'v3_settings_center','v3_settings_default_size'})do
    Test('settings layout action rolls back rejected persistence '..button,function()
        local h,main,state=PersistentMain();assert(main:CommitWindowGeometry(nil,430,140,1300,800,'resize'))
        assert(main:Open());local x,y,w,hh=main.window.x,main.window.y,main.window.w,main.window.h
        local ui=SettingsControls(h)
        h.rejectSave=true
        assert(ui.widgets[button].onClick()==false,'setting action ignored failed save')
        assert(state.userMoved==true);Eq(state.width,1300);Eq(state.height,800);Eq(state.x,430);Eq(state.y,140)
        Eq(main.window.x,x);Eq(main.window.y,y);Eq(main.window.w,w);Eq(main.window.h,hh)
    end)
end
-- 显式数值输入和滑块释放共用 set；无需心跳/退出 Flush 即能冷启恢复，拒写不能只留下已应用的新值。
for _,field in ipairs({{'shell_width','width',1250,'shell'},{'shell_height','height',810,'shell'},
    {'ui_scale','addonScale',110,'app'},{'font_scale','fontScale',125,'app'}})do
    for _,mode in ipairs({'cold','reject','stale','binding'})do
        Test('settings final numeric commit '..field[1]..' '..mode,function()
            local h,main,state=PersistentMain();assert(main:Open())
            dofile('core/rs_app_state_v3.lua');assert(h.S.AppState:EnsureLoaded())
            h.S.Layout.RefreshNow=function()return true end -- Native字体/缩放是叶边界；存档和设置回调保持生产实现。
            local ui=SettingsControls(h);local target=field[4]=='app' and h.S.AppState.settings or state
            local before=target[field[2]]
            if mode=='reject' then h.rejectSave=true elseif mode=='stale' then h.dropSave=true end
            local spec=ui.widgets['v3_settings_'..field[1]].spec
            local ok
            if mode=='binding' then
                -- 生产 Binding 必须纳入链路；只调 spec.set 会漏过外层重复 MarkDirty/Flush。
                dofile('ui/framework/rs_ui_binding_v2.lua')
                local factory=spec.storeId and h.S.UI.CreatePersistentSettingBinding or h.S.UI.CreateSettingBinding
                local binding=assert(factory(h.S.UI,spec));local beforeWrites=h.diskWrites
                ok=binding:Set(field[3],true,'input')
                assert(ok and not binding:IsDirty(),'durable final left a stale binding draft')
                assert(h.diskWrites==beforeWrites+1);local savedWrites=h.diskWrites
                assert(h.S.Persistence:Flush());assert(h.diskWrites==savedWrites,'outer binding caused a second Native save')
            else ok=spec.set(field[3])end
            if mode=='reject' or mode=='stale' then
                assert(ok==false,'numeric setting accepted '..mode..' save');Eq(target[field[2]],before)
                return
            end
            assert(ok==true)
            local cold,_,saved=PersistentMain(h.disk);dofile('core/rs_app_state_v3.lua');assert(cold.S.AppState:EnsureLoaded())
            local actual=field[4]=='app' and cold.S.AppState.settings[field[2]] or saved[field[2]]
            Eq(actual,field[4]=='app' and field[3]/100 or field[3],'setting lost before heartbeat')
        end)
    end
end
Test('app scale preview stays memory only and explicit same-value apply is durable',function()
    local h=PersistentMain();dofile('core/rs_app_state_v3.lua');local app=h.S.AppState;assert(app:EnsureLoaded())
    local writes=h.diskWrites
    assert(app:Set('fontScale',1.25,false))
    assert(h.diskWrites==writes,'scale preview unexpectedly wrote persistence')
    assert(app:Set('fontScale',1.25,true));assert(h.diskWrites>writes,'same-value final apply was skipped')
    local cold=PersistentMain(h.disk);dofile('core/rs_app_state_v3.lua');assert(cold.S.AppState:EnsureLoaded())
    Eq(cold.S.AppState.settings.fontScale,1.25)
end)
print(string.format('MAIN VISIBILITY RESULT %d passed / %d failed (%s)',passed,failed,_VERSION))
assert(failed==0,'main visibility regression failures: '..failed)

-- 主窗口显示边沿回归：真实 Shell/Adapter/Diff/Windowing，Native Show 模拟引擎出生定位。
-- 不进入 toc.g；离线通过不等于 RU 客户端实测。
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
print(string.format('MAIN VISIBILITY RESULT %d passed / %d failed (%s)',passed,failed,_VERSION))
assert(failed==0,'main visibility regression failures: '..failed)

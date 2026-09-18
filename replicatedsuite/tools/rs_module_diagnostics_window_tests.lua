-- 共享模块诊断悬浮窗契约：验证单实例、显式采集、固定分页和 CopyBox 生命周期。
local passed,failed=0,0
local function Test(name,fn)local ok,err=pcall(fn);if ok then passed=passed+1;print('PASS module-diag-window '..name)else failed=failed+1;print('FAIL module-diag-window '..name..': '..tostring(err))end end
local function Boot(options)
    options=options or {}
    ReplicatedSuite={Generation=1,RSUI={},UI={},UIV3={},FeatureRegistry={features={
        feature_a={id='feature_a',name='模块A',route='combat.a'},feature_b={id='feature_b',name='模块B',route='life.b'}}}}
    local S=ReplicatedSuite
    function S.FeatureRegistry:Get(id)return self.features[id]end
    local calls={create=0,show=0,capture=0,getPage=0,setText=0,deactivate=0,clear=0,title=0,status=0}
    S.ModuleDiagnosticsHub={}
    function S.ModuleDiagnosticsHub:Capture(id,cap)calls.capture=calls.capture+1;return {id='snap'..calls.capture,moduleId=id,parts=3,session={}}end
    function S.ModuleDiagnosticsHub:GetPage(snap,index)calls.getPage=calls.getPage+1;return snap.moduleId..':PAGE'..index end
    S.UIV3.AuxWindowStoreV3={}
    function S.UIV3.AuxWindowStoreV3:EnsureLoaded()if options.auxLoadFails then return false,'aux_store_corrupt' end;return true end
    function S.UIV3.AuxWindowStoreV3:GetPolicy()return {defaultWidth=700,defaultHeight=520,minWidth=520,minHeight=340}end
    function S.UIV3.AuxWindowStoreV3:GetWindowState()if options.auxGetFails then return nil,'aux_get_failed' end;return {width=700,height=520}end
    function S.UIV3.AuxWindowStoreV3:SetWindowState()if options.auxSetFails then return false,'aux_set_failed' end;return true end
    function S.UIV3.AuxWindowStoreV3:PersistWindow()if options.auxPersistFails then return false,'aux_persist_failed' end;return true end
    local Node=function(spec)
        local n={spec=spec or {},children={},text=spec and spec.text or '',enabled=true,root={rsUiOwner='diag-window'}}
        function n:SetText(v)self.text=v end;function n:SetEnabled(v)self.enabled=v end
        function n:Layout(x,y,w,h)self.x,self.y,self.width,self.height=x,y,w,h;return true end
        if spec and spec.parent and spec.parent.children then spec.parent.children[#spec.parent.children+1]=n end
        if spec and spec.id then calls[spec.id]=n end
        return n
    end
    for _,k in ipairs({'VerticalBox','HorizontalBox','Button','Text','Border'})do S.RSUI[k]=function(_,spec)return Node(spec)end end
    S.RSUI.FloatingSurface={}
    function S.RSUI.FloatingSurface:NormalizeState(value,policy)
        value=type(value)=='table' and value or {}
        policy=type(policy)=='table' and policy or {}
        return {width=value.width or policy.defaultWidth or 700,height=value.height or policy.defaultHeight or 520,
            minimized=value.minimized==true,locked=value.locked==true,overallOpacity=value.overallOpacity or 1,
            backgroundOpacity=value.backgroundOpacity or 1,textOpacity=value.textOpacity or 1,fontScale=value.fontScale or 1,
            userMoved=value.userMoved==true,x=value.x,y=value.y}
    end
    function S.RSUI.FloatingSurface:Create(spec)
        calls.create=calls.create+1
        local content=Node({id='content'})
        local surface={spec=spec,shell={}}
        function surface.shell:SetTitle(v)calls.title=calls.title+1;self.title=v;return true end
        function surface:SetStatus(v)calls.status=calls.status+1;self.status=v;return true end
        function surface:GetContentRoot()return content end
        function surface:Show(v)calls.show=calls.show+1;self.visible=v;return true end
        function surface:Close(reason)self.visible=false;if spec.onClosed then spec.onClosed(self,reason or 'close')end;return true end
        calls.surface=surface;return surface
    end
    S.UI.CreateDiagnosticCopyBox=function(_,spec)
        local box={capacity=3500,text='',active=false}
        function box:GetCapacity()return self.capacity end
        function box:SetPageText(v)calls.setText=calls.setText+1;self.text=v;return true end
        function box:Clear()calls.clear=calls.clear+1;self.text='';return true end
        function box:Deactivate()calls.deactivate=calls.deactivate+1;self.active=false;return true end
        function box:Layout()return true end
        function box:SetVisible()return true end
        calls.copy=box;return box
    end
    dofile('presentation/v3/widgets/rs_v3_module_diagnostics_window.lua')
    return S,S.UIV3.ModuleDiagnosticsWindowV3,calls
end
Test('open is lazy and never auto captures',function()
    local S,W,c=Boot();assert(W:Open('feature_a'));assert(c.create==1 and c.show==1 and c.capture==0);assert(c.surface.shell.title=='模块A · 模块诊断')
end)

Test('diagnostics remains available when aux window persistence is degraded',function()
    local S,W,c=Boot({auxLoadFails=true});local ok,err=W:Open('feature_a')
    assert(ok==true,tostring(err));assert(c.create==1 and c.show==1 and c.capture==0)
end)
Test('aux persist failure degrades to session state without breaking window transaction',function()
    local S,W,c=Boot({auxPersistFails=true});assert(W:Open('feature_a'))
    local spec=c.surface.spec;assert(spec.setState({width=811,height=611},'geometry')==true)
    assert(spec.persist('geometry',0)==true)
    local state=spec.getState();assert(state.width==811 and state.height==611)
    assert(W.auxPersistenceDegraded==true)
end)
Test('generate captures once and next previous only read frozen snapshot',function()
    local S,W,c=Boot();W:Open('feature_a');assert(W:Generate());assert(c.capture==1 and W.pageIndex==1 and c.copy.text=='feature_a:PAGE1')
    assert(W:ShowPage(2));assert(W:ShowPage(3));assert(W:ShowPage(2));assert(c.capture==1 and c.getPage==4)
end)
Test('module switch deactivates copy authority and clears old snapshot',function()
    local S,W,c=Boot();W:Open('feature_a');W:Generate();local d=c.deactivate;assert(W:Open('feature_b'));assert(c.deactivate==d+1);assert(W.snapshot==nil and W.pageIndex==0 and c.copy.text=='')
end)
Test('close deactivates diagnostic copy box',function()
    local S,W,c=Boot();W:Open('feature_a');W:Generate();local d=c.deactivate;assert(W:Close());assert(c.deactivate==d+1 and W.visible==false)
end)
Test('one shared surface is reused across modules',function()
    local S,W,c=Boot();W:Open('feature_a');W:Open('feature_b');W:Open('feature_a');assert(c.create==1)
end)
print('MODULE DIAGNOSTICS WINDOW RESULT '..passed..' passed / '..failed..' failed ('.._VERSION..')')
if failed>0 then error('module diagnostics window failures: '..failed)end

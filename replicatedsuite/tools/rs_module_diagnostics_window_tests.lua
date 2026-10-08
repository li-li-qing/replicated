-- 共享模块诊断悬浮窗契约：验证单实例、显式采集、固定分页和 CopyBox 生命周期。
local passed,failed=0,0
local function Test(name,fn)local ok,err=pcall(fn);if ok then passed=passed+1;print('PASS module-diag-window '..name)else failed=failed+1;print('FAIL module-diag-window '..name..': '..tostring(err))end end
local function Boot(options)
    options=options or {}
    ReplicatedSuite={Generation=1,RSUI={},UI={},UIV3={},FeatureRegistry={features={
        feature_a={id='feature_a',name='模块A',route='combat.a'},feature_b={id='feature_b',name='模块B',route='life.b'}}}}
    local S=ReplicatedSuite
    function S.FeatureRegistry:Get(id)return self.features[id]end
    local calls={create=0,show=0,capture=0,getPage=0,repage=0,setText=0,deactivate=0,clear=0,title=0,status=0,captureCaps={},repageCaps={},actualBytes=0}
    S.ModuleDiagnosticsHub={}
    function S.ModuleDiagnosticsHub:Capture(id,cap)calls.capture=calls.capture+1;calls.captureCaps[#calls.captureCaps+1]=cap;return {id='snap'..calls.capture,moduleId=id,parts=3,report=id..':REPORT',session={capacity=cap,bounds={{offset=0,length=10},{offset=10,length=10},{offset=20,length=10}}}}end
    function S.ModuleDiagnosticsHub:Repage(source,cap)calls.repage=calls.repage+1;calls.repageCaps[#calls.repageCaps+1]=cap;return {id=source.id,moduleId=source.moduleId,parts=2,report=source.report,session={capacity=cap,bounds={{offset=0,length=15},{offset=15,length=15}}}}end
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
        local box={capacity=spec.copyCapacity or 2048,text='',active=false}
        function box:GetCapacity()return self.capacity end
        function box:SetCapacity(v)self.capacity=v;return true end
        function box:SetPageText(v)
            calls.setText=calls.setText+1;self.text=v
            if options.copyWriteFails then calls.actualBytes=tonumber(options.actualBytes) or 0;return false,'readback_mismatch' end
            if options.copyWriteFailsOnce and calls.setText==1 then calls.actualBytes=tonumber(options.actualBytes) or 1200;return false,'readback_mismatch' end
            calls.actualBytes=#v;return true
        end
        function box:GetDiagnostics()return {actualBytes=calls.actualBytes,expectedBytes=#(self.text or ''),readbackFailures=(options.copyWriteFails or options.copyWriteFailsOnce) and 1 or 0}end
        function box:Clear()calls.clear=calls.clear+1;self.text='';return true end
        function box:Deactivate()calls.deactivate=calls.deactivate+1;self.active=false;return true end
        function box:Activate()self.active=true;return true end
        function box:Layout()return true end
        function box:SetVisible()return true end
        calls.copy=box;return box
    end
    if options.realCopyBox then
        -- Production CopyBox + Window, only native edit object is a model.
        -- The existing global report-delivery regression has this same native
        -- focus-clears-buffer boundary; module diagnostics must respect it too.
        GetFocusedWidgetId=function()return calls.focusId end
        S.UI.CreateMultiEditBox=function(_,parent,id)
            local edit={text='',events={},rsNativePhysicalId='native_'..id,rsNativeGeneration=1}
            function edit:SetText(v)self.text=v;self.selected=false;calls.setText=calls.setText+1 end
            function edit:GetText()return self.text end
            function edit:SetReadOnly()end
            function edit:SetCursorOffset()self.selected=false end
            function edit:EnableKeyboard(v)self.keyboard=v;return true end
            function edit:SetFocus()
                calls.focusId=self.rsNativePhysicalId;self.text='';self.selected=false
                if options.rejectFocus then return false end
                return true
            end
            function edit:ClearFocus()calls.focusId=nil end
            calls.edit=edit;return edit
        end
        S.UI.SafeHandler=function(_,edit,event,fn)edit.events[event]=fn;return true end
        dofile('ui/framework/rs_ui_diagnostic_copy_box.lua')
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

Test('short pagination can be restored to normal without recapturing',function()
    local S,W,c=Boot();W:Open('feature_a');assert(W:Generate());assert(c.captureCaps[1]==2048)
    assert(W:RetrySmallerPages());assert(c.capture==1 and c.repage==1);assert(c.repageCaps[1]==1433);assert(W.snapshot.session.capacity==1433)
    assert(W:RestoreNormalPages());assert(c.capture==1 and c.repage==2);assert(c.repageCaps[2]==2048);assert(W.snapshot.session.capacity==2048)
end)
Test('new diagnostic capture reuses proven safe pagination in the same load',function()
    local S,W,c=Boot();W:Open('feature_a');assert(W:Generate());assert(W:RetrySmallerPages());local safe=W.snapshot.session.capacity;assert(safe<2048)
    assert(W:Generate());assert(c.capture==2 and c.captureCaps[2]==safe,'new capture did not reuse safe capacity')
end)
Test('native readback mismatch auto repages the same frozen report without recapture',function()
    local S,W,c=Boot({copyWriteFailsOnce=true,actualBytes=1200});W:Open('feature_a');local ok,err=W:Generate();assert(ok==true,tostring(err))
    assert(c.capture==1,'auto fit recaptured diagnostics')
    assert(c.repage>=1,'auto fit did not repage')
    assert(W.preferredPageCapacity and W.preferredPageCapacity<2048,'auto fit did not remember measured capacity')
    assert(W.snapshot and W.snapshot.session.capacity==W.preferredPageCapacity,'auto fit snapshot/capacity diverged')
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

Test('page controls publish frozen snapshot count after successful capture',function()
    local S,W,c=Boot();W:Open('feature_a');assert(W:Generate())
    local page=c['v3_module_diagnostics_window_page'];local prev=c['v3_module_diagnostics_window_prev'];local nextb=c['v3_module_diagnostics_window_next']
    assert(page and page.text=='1 / 3','page label did not publish 1 / 3: '..tostring(page and page.text))
    assert(prev and prev.enabled==false,'previous should be disabled on first page')
    assert(nextb and nextb.enabled==true,'next should be enabled for multi-page snapshot')
end)
Test('copy verification failure keeps immutable pagination navigable',function()
    local S,W,c=Boot({copyWriteFails=true});W:Open('feature_a');local ok=W:Generate();assert(ok==false,'copy verification fixture must fail')
    local page=c['v3_module_diagnostics_window_page'];local nextb=c['v3_module_diagnostics_window_next']
    assert(W.snapshot and W.snapshot.parts==3,'frozen snapshot was not published')
    assert(W.pageIndex==1,'current frozen page index was not published')
    assert(page and page.text=='1 / 3','failed copy regressed header to '..tostring(page and page.text))
    assert(nextb and nextb.enabled==true,'next page must stay available when only native copy verification failed')
    W.copyBox.SetPageText=function(self,v)self.text=v;return true end
    assert(W:ShowPage(2),'next page should be reachable from the frozen snapshot')
    assert(W.pageIndex==2 and W.copyBox.text=='feature_a:PAGE2')
end)

Test('capture retains copy state before Generate deactivates keyboard',function()
    local S,W,c=Boot();W:Open('feature_a');W:Generate();c.copy.active=true
    c.copy.GetDiagnostics=function(self)return {active=self.active,patch='diagnostic-copy-selection-1'}end
    assert(W:Generate());local d=W:Describe()
    assert(d.copyBeforeCapture and d.copyBeforeCapture.active==true,'pre-capture copy state was discarded')
    local before=d.copyBeforeCapture;assert(W:ShowPage(2));assert(W:Describe().copyBeforeCapture==before,'page changed frozen pre-capture evidence')
end)
Test('module switch drops previous module copy evidence',function()
    local S,W,c=Boot();W:Open('feature_a');W.copyBeforeCapture={active=true}
    assert(W:Open('feature_b'));assert(W:Describe().copyBeforeCapture==nil and W.copyBeforeCapture==nil)
end)
Test('activation failure does not pretend copy-ready or lose report navigation',function()
    local S,W,c=Boot();W:Open('feature_a');c.copy.Activate=function()return false,'focus_rejected' end
    assert(W:Generate());assert(W.snapshot and W.copyPageValid==true,'verified text should remain pageable')
    assert(W:Describe().copyActivationError=='focus_rejected','activation rejection swallowed')
    assert(c.surface.status:find('焦点',1,true),'footer must explain failure rather than say copy-ready')
    assert(W:ShowPage(2) and c.capture==1)
end)
Test('real copy box commits text after focus promotion not before it',function()
    local S,W,c=Boot({realCopyBox=true});assert(W:Open('feature_a'));assert(W:Generate())
    assert(c.edit.text=='feature_a:PAGE1','focus cleared the already-verified report buffer')
    assert(W.copyPageValid==true and W.copyBox:GetDiagnostics().actualBytes==#c.edit.text)
    c.edit.selected=true;c.edit.events.OnClick()
    assert(c.edit.selected and c.edit.text=='feature_a:PAGE1','repeat click destroyed verified copy selection')
end)
Test('real next-page focus promotion cannot erase the frozen page',function()
    local S,W,c=Boot({realCopyBox=true});assert(W:Open('feature_a'));assert(W:Generate())
    c.focusId='next_button';assert(W:ShowPage(2))
    assert(c.edit.text=='feature_a:PAGE2' and c.capture==1,'page focus erased data or caused recapture')
end)
Test('rejected focus still publishes complete text without false activation success',function()
    local S,W,c=Boot({realCopyBox=true,rejectFocus=true});assert(W:Open('feature_a'));assert(W:Generate())
    assert(c.edit.text=='feature_a:PAGE1','failed focus cleared the page after verification')
    assert(W.copyPageValid==true and W.copyActivationError~=nil)
    assert(c.surface.status:find('焦点激活失败',1,true),'focus failure was hidden')
end)
-- 中文维护：导出复用完整快照；Native 正文失败不应迫使用户逐页复制或重新采集业务。
Test('file export uses frozen complete report without editor reads or recapture',function()
    local S,W,c=Boot();assert(W:Open('feature_a'));assert(W:Generate())
    S.DiagnosticsManager={ExportReport=function(_,text,meta)c.exportText=text;c.exportId=meta.id;return true,'saved' end}
    assert(W:ExportFile());assert(c.exportText=='feature_a:REPORT' and c.capture==1)
    assert(c.exportId==W.snapshot.id)
end)
Test('file export captures only on explicit click when no snapshot exists',function()
    local S,W,c=Boot();assert(W:Open('feature_a'))
    S.DiagnosticsManager={ExportReport=function(_,text)c.exportText=text;return true,'saved' end}
    assert(c.capture==0);assert(W:ExportFile());assert(c.capture==1 and c.exportText=='feature_a:REPORT')
end)
-- 中文维护：沿真实模块控制条 -> 共享窗口 -> 创建时绑定的导出回调执行，
-- 模块切换必须清掉旧报告；复制框失败仍能导出当前模块完整的 pending snapshot。
Test('module toolbar export button follows module switches and survives editor failures',function()
    local S,W,c=Boot({copyWriteFails=true,actualBytes=0})
    dofile('presentation/v3/shell/rs_v3_module_controls.lua')
    local exports={}
    S.DiagnosticsManager={ExportReport=function(_,text,meta)exports[#exports+1]=text;return true,'saved' end}
    local controls=S.UIV3.ModuleControlsV3
    local a=assert(controls:Create(nil,'combat.a',S.FeatureRegistry:Get('feature_a')))
    local b=assert(controls:Create(nil,'life.b',S.FeatureRegistry:Get('feature_b')))
    assert(a.diagnostics.spec.onClick() and c.capture==0)
    local button=W.exportButton
    assert(type(button.spec.onClick)=='function','Native creation lacks file export callback')
    assert(W:Generate()==false and type(W.pendingSnapshot or W.snapshot)=='table')
    assert(button.spec.onClick() and exports[1]=='feature_a:REPORT' and c.capture==1)
    assert(b.diagnostics.spec.onClick() and W.pendingSnapshot==nil and W.snapshot==nil)
    assert(W.exportButton==button and c.create==1,'module switch duplicated the shared export window')
    assert(button.spec.onClick() and exports[2]=='feature_b:REPORT' and c.capture==2)
    assert(a.diagnostics.spec.onClick() and button.spec.onClick())
    assert(exports[3]=='feature_a:REPORT' and c.capture==3)
end)
Test('TXT prefers detailed frozen evidence and repeated exports reuse a direct capture',function()
 local S,W,c=Boot();assert(W:Open('feature_a'))
 local capture=S.ModuleDiagnosticsHub.Capture
 S.ModuleDiagnosticsHub.Capture=function(self,...)
  local result=capture(self,...);result.exportReport='FULL_DETAIL';return result
 end
 S.DiagnosticsManager={ExportReport=function(_,text)c.exportText=text;return true,'saved' end}
 assert(W:ExportFile());assert(c.exportText=='FULL_DETAIL' and c.capture==1)
 assert(W:ExportFile());assert(c.exportText=='FULL_DETAIL' and c.capture==1)
end)
print('MODULE DIAGNOSTICS WINDOW RESULT '..passed..' passed / '..failed..' failed ('.._VERSION..')')
if failed>0 then error('module diagnostics window failures: '..failed)end

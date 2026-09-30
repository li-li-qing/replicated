-- 诊断专用复制框契约：验证它不复用普通 Draft/Input LostFocus 生命周期；离线模型不声称 RU 剪贴板 API 存在。
local passed,failed=0,0
local function Test(name,fn)local ok,err=pcall(fn);if ok then passed=passed+1;print('PASS diagnostic-copy-box '..name)else failed=failed+1;print('FAIL diagnostic-copy-box '..name..': '..tostring(err))end end
local function Boot()
    local calls={text=0,keyboard=0,focus=0,clear=0,readonly=0,bindOrdinary=0,extent=0,anchor=0,schedule=0}
    local focusId=nil
    GetFocusedWidgetId=function()return focusId end
    ReplicatedSuite={Generation=5,NowMs=function()return 100 end,UI={}}
    local S=ReplicatedSuite;local UI=S.UI
    S.Scheduler={AddHighFrequencyOneShot=function()calls.schedule=calls.schedule+1;return true end}
    UI.BindDeferredInputActivation=function()calls.bindOrdinary=calls.bindOrdinary+1;return true end
    UI.SafeHandler=function(_,widget,event,fn)widget.handlers[event]=fn;return true end
    UI.CreateMultiEditBox=function(_,parent,id,x,y,w,h,maxLength)
        local e={text='',handlers={},visible=true,keyboard=false,rsUiOwner='diag-owner',rsNativePhysicalId='phys:'..id,rsNativeGeneration=S.Generation}
        function e:SetText(v)calls.text=calls.text+1;self.text=v;self.selected=false end
        function e:GetText()return self.text end
        function e:SetReadOnly(v)calls.readonly=calls.readonly+1;self.readonly=v;return true end
        function e:EnableKeyboard(v)calls.keyboard=calls.keyboard+1;self.keyboard=v;return true end
        function e:SetFocus()calls.focus=calls.focus+1;focusId=self.rsNativePhysicalId;self.selected=false;return true end
        function e:ClearFocus()calls.clear=calls.clear+1;if focusId==self.rsNativePhysicalId then focusId=nil end;return true end
        function e:Show(v)self.visible=v;return true end
        function e:SetExtent(ww,hh)calls.extent=calls.extent+1;self.w,self.h=ww,hh;self.selected=false;return true end
        function e:RemoveAllAnchors()calls.anchor=calls.anchor+1;self.selected=false end
        function e:AddAnchor(_,p,ax,ay)calls.anchor=calls.anchor+1;self.parent=p;self.x,self.y=ax,ay end
        function e:SetCursorOffset(v)self.cursor=v;self.selected=false end
        function e:SelectForTest()assert(self.keyboard and focusId==self.rsNativePhysicalId);self.selected=true end
        function e:CopyForTest()return self.selected and self.keyboard and focusId==self.rsNativePhysicalId and self.readonly~=true and self.text or nil end
        calls.edit=e;return e
    end
    UI.EnsureExtent=function(_,e,w,h)e:SetExtent(w,h);return true,true end
    UI.EnsureAnchor=function(_,e,p,x,y)e:RemoveAllAnchors();e:AddAnchor('TOPLEFT',p,x,y);return true,true end
    dofile('ui/framework/rs_ui_diagnostic_copy_box.lua')
    local box=assert(UI:CreateDiagnosticCopyBox({parent={id='p'},id='diag_copy',owner='diag-owner',width=500,height=300,copyCapacity=3500}))
    return S,UI,box,calls,function()return focusId end
end
Test('construction keeps copy buffer editable and never binds ordinary input lifecycle',function()
    local S,UI,box,c=Boot();assert(c.edit.readonly~=true,'read-only RU multiline boxes cannot reliably select/copy');assert(c.bindOrdinary==0);assert(c.schedule==0)
end)
Test('click selection can copy the frozen page body',function()
    local S,UI,box,c=Boot();assert(box:SetPageText('COPY_ME'));assert(c.edit.handlers.OnClick());c.edit:SelectForTest();assert(c.edit:CopyForTest()=='COPY_ME','copy buffer is not selectable/copyable')
end)
Test('click arms keyboard and focuses exactly once',function()
    local S,UI,box,c,focus=Boot();assert(c.edit.handlers.OnClick());assert(c.edit.keyboard and focus()==c.edit.rsNativePhysicalId);assert(c.focus==1)
end)
Test('late lost focus notification never clears text selection or keyboard',function()
    local S,UI,box,c=Boot();box:SetPageText('ABC');c.edit.handlers.OnClick();c.edit:SelectForTest();local before=c.edit:CopyForTest();assert(before=='ABC')
    for i=1,20 do assert(c.edit.handlers.OnLostFocus()) end
    assert(c.edit:CopyForTest()=='ABC','copy authority lost after delayed lost-focus');assert(c.schedule==0,'diagnostic box scheduled generic focus recheck')
    assert(c.text==1,'lost focus rewrote report text')
end)
Test('same page text and same geometry are diffed',function()
    local S,UI,box,c=Boot();assert(box:SetPageText('PAGE'));local writes=c.text;assert(box:SetPageText('PAGE'));assert(c.text==writes)
    assert(box:Layout(4,4,600,320));local extent,anchor=c.extent,c.anchor;assert(box:Layout(4,4,600,320));assert(c.extent==extent and c.anchor==anchor)
end)
Test('deactivate is the lifecycle boundary that releases keyboard and own focus',function()
    local S,UI,box,c,focus=Boot();box:SetPageText('PAGE');c.edit.handlers.OnClick();c.edit:SelectForTest();assert(box:Deactivate('window_close'))
    assert(not c.edit.keyboard and focus()==nil and c.clear==1);assert(c.edit.text=='PAGE','deactivate must not erase frozen report')
end)
Test('external focus is never cleared on deactivate',function()
    local S,UI,box,c=Boot();c.edit.handlers.OnClick();GetFocusedWidgetId=function()return 'native-chat' end;local clear=c.clear;assert(box:Deactivate('module_switch'));assert(c.clear==clear and not c.edit.keyboard)
end)
Test('telemetry never includes report body',function()
    local S,UI,box,c=Boot();box:SetPageText('SECRET_REPORT_BODY');c.edit.handlers.OnClick();c.edit.handlers.OnLostFocus();local d=box:GetDiagnostics()
    assert(d.text==nil and d.report==nil and d.body==nil and d.textWrites==1 and d.lostFocusNotifications==1)
end)
-- Native boundary deliberately collapses selection on SetFocus, like the existing
-- ordinary report host. This proves we do not depend on redundant focus being harmless.
Test('repeat click does not replay focus or keyboard while selection belongs to this box',function()
    local S,UI,box,c=Boot();box:SetPageText('PERSIST_SELECTION');box:Activate('page_ready');c.edit:SelectForTest()
    local f,k=c.focus,c.keyboard;assert(c.edit.handlers.OnClick())
    assert(c.edit:CopyForTest()=='PERSIST_SELECTION','repeat OnClick destroyed selected report')
    assert(c.focus==f and c.keyboard==k,'repeat activation must perform zero Native focus/keyboard writes')
end)
Test('many duplicate activation notifications do not collapse a selected page',function()
    local S,UI,box,c=Boot();box:SetPageText('ALL_BYTES');box:Activate();c.edit:SelectForTest()
    for i=1,20 do assert(box:Activate('click'));assert(c.edit.handlers.OnLostFocus()) end
    assert(c.edit:CopyForTest()=='ALL_BYTES','selection collapsed by duplicate activation')
    assert(c.schedule==0 and c.text==1)
end)
Test('focus published before keyboard promotion still requires a new SetFocus',function()
    local S,UI,box,c=Boot();GetFocusedWidgetId=function()return c.edit.rsNativePhysicalId end
    c.edit.rsUiKeyboardArmed=false;local f=c.focus
    assert(box:Activate());assert(c.focus==f+1 and c.edit.keyboard,'first promotion skipped edit-mode focus')
end)
Test('known logical focus identity preserves selection without replay',function()
    local S,UI,box,c=Boot();c.edit.rsNativeLogicalId='logical_diag';box:SetPageText('LOGICAL');box:Activate();c.edit:SelectForTest()
    GetFocusedWidgetId=function()return 'logical_diag' end
    local f,k=c.focus,c.keyboard;assert(box:Activate());assert(c.focus==f and c.keyboard==k,'logical focus was not recognised')
end)
Test('external focus requires explicit reacquisition but not another keyboard toggle',function()
    local S,UI,box,c=Boot();box:Activate();GetFocusedWidgetId=function()return 'native_chat' end
    local f,k=c.focus,c.keyboard;assert(box:Activate('click'))
    assert(c.focus==f+1 and c.keyboard==k,'reacquire must not replay keyboard true')
end)
Test('focus query failure never invents an already focused fast path',function()
    local S,UI,box,c=Boot();box:Activate();GetFocusedWidgetId=function()error('focus unavailable')end
    local f=c.focus;assert(box:Activate());assert(c.focus==f+1)
    assert(box:GetDiagnostics().focusKnown==false,'unknown focus must be explicit')
end)
Test('diagnostics distinguishes selected-buffer readiness from clipboard success',function()
    local S,UI,box,c=Boot();box:SetPageText('NO_BODY_EXPORT');box:Activate();box:Activate()
    local d=box:GetDiagnostics();assert(d.patch=='diagnostic-copy-selection-1' and d.focusKnown==true and d.focused==true)
    assert(d.reusedFocus==1 and d.text==nil and d.clipboardVerified==false,'must not claim OS clipboard verification')
end)
Test('retired copy widget cannot rearm from a delayed click',function()
    local S,UI,box,c=Boot();box:Activate();box:Destroy();local f,k=c.focus,c.keyboard
    assert(c.edit.handlers.OnClick()==false,'destroyed box reactivated');assert(c.focus==f and c.keyboard==k)
end)
Test('ordinary-input retirement is also honoured by copy activation',function()
    local S,UI,box,c=Boot();c.edit.rsUiInputLifecycleRetired=true
    assert(box:Activate()==false and c.focus==0 and c.keyboard==0)
end)
Test('rejected keyboard activation and focus failure remain visible failures',function()
    local S,UI,box,c=Boot();c.edit.EnableKeyboard=function()return false end
    assert(box:Activate()==false and c.focus==0)
    assert(box:GetDiagnostics().lastActivationError~=nil,'error evidence omitted')
    S,UI,box,c=Boot();c.edit.SetFocus=function()return false end
    assert(box:Activate()==false and c.edit.rsUiKeyboardArmed==false)
end)
print('DIAGNOSTIC COPY BOX RESULT '..passed..' passed / '..failed..' failed ('.._VERSION..')')
if failed>0 then error('diagnostic copy box failures: '..failed)end

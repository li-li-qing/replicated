-- 维护（report-selection-1）：生产 Page/输入生命周期/Diff/Native handler，
-- 仅替换 UI 原生对象与外部诊断来源。选区/剪贴板是确定性模型，不宣称 RU 实机通过。
-- 模拟同尺寸布局时 Native getter 抖动、迟到失焦通知；无自造键盘事件/API。
local passed,failed=0,0
local function Test(name,run)
    local ok,err=pcall(run)
    if ok then passed=passed+1;print('PASS report-selection '..name)
    else failed=failed+1;print('FAIL report-selection '..name..': '..tostring(err)) end
end
local function Boot()
    local calls={now=0,reads=0,writes=0,checks=0,text=0,focus=0,clear=0,extent=0,anchor=0,cursor=0,keyboard=0}
    UIParent={};GetFocusedWidgetId=function()return calls.focusId end
    ADDON={ChatLog=function()return true end};X2Chat=nil
    ReplicatedSuite={Generation=1,Features={},Services={},RSUI={},NowMs=function()return calls.now end,
        SafeTraceback=function(e)return tostring(e)end,SafeChat=function()return true end,
        Layout={GetContext=function()return {uiScale=1}end}}
    local S=ReplicatedSuite
    -- 维护：按bootstrap的真实入口交给错误环；不假定报告模块会反向覆盖日志函数。
    S.RecordLog=function(level,source,message)
        if S.DiagnosticsManager and S.DiagnosticsManager.CaptureSelfCheckIssue then
            S.DiagnosticsManager:CaptureSelfCheckIssue({level=level,source=source,message=message,at=calls.now})
        end
    end
    for _,f in ipairs({'core/rs_utils.lua','core/rs_reuse.lua','core/rs_api.lua','core/rs_api_capabilities.lua',
        'core/rs_diagnostics.lua','core/rs_scheduler.lua','core/rs_report_copy_transport.lua','core/rs_self_check_report.lua',
        'ui/rs_ui_native_primitives.lua','ui/rs_ui_framework.lua'})do dofile(f)end
    local UI=S.UI;local binder=UI.BindDeferredInputActivation
    local h=dofile('tools/rs_status_ui_test_host.lua')(S);UI.BindDeferredInputActivation=binder
    UI.SetEditBoxFocusVisual=function()return true end
    S.FoundationGate={Run=function()calls.checks=calls.checks+1;return {status='PASS',checks={}}end}
    S.Persistence={stores={}};S.Runtime={Describe=function()return {}end}
    S.ActionRunner={Run=function(_,spec)return spec.execute()end,GetSnapshot=function()return {}end}
    S.DiagnosticsManager.BuildFeatureStatusRows=function()return {}end
    S.UIV3.PageHost.pages={};S.UIV3.PageHost.Describe=function()return {}end
    local Node=h.Node
    local function Component(spec)
        local n=Node(spec);n.owner='v3:report_test';n.root.rsUiOwner=n.owner
        n.root.rsNativeGeneration=S.Generation
        function n.root:GetEffectiveOffset()return 0,0 end
        function n:Layout(x,y,w,ht)self.x=x;self.y=y;self.width=w;self.height=ht;return true end
        return n
    end
    S.RSUI.Border=function(_,spec)return Component(spec)end
    S.UIV3Design.PageRoot=function(_,_,spec)return Component(spec)end
    S.UIV3Design.InfoCard=function(_,_,spec)local n=Component(spec);function n:SetData(v)self.data=v end;return n end
    UI.CreateMultiEditBox=function(_,parent,id,x,y,w,ht)
        local e={text='',visible=true,width=w,height=ht,x=x,y=y,handlers={},keyboard=false,
            rsUiParent=parent,rsUiKeyboardInput=true,rsNativeGeneration=S.Generation,
            rsNativePhysicalId='test_'..id,rsUiLogicalId=id,rsUiOwner=parent.rsUiOwner}
        function e:SetHandler(event,fn)self.handlers[event]=fn end
        function e:SetText(v)calls.text=calls.text+1;self.text=v;self.selected=false end
        function e:GetText()return self.text end
        function e:MaxTextLength()return 3500 end
        function e:SetCursorOffset(v)calls.cursor=calls.cursor+1;self.cursor=v;self.selected=false end
        function e:Show(v)self.visible=v;return v end
        function e:IsVisible()return self.visible end
        function e:SetExtent(width,height)
            calls.extent=calls.extent+1
            if calls.failExtent then error('synthetic_extent_rejected')end
            self.width=width;self.height=height;self.selected=false
        end
        function e:GetWidth()return self.width+(calls.drift and 3 or 0)end
        function e:GetHeight()return self.height end
        function e:GetEffectiveOffset()return self.x+(calls.drift and 3 or 0),self.y end
        function e:RemoveAllAnchors()calls.anchor=calls.anchor+1;self.selected=false end
        function e:AddAnchor(_,p,ax,ay)self.x=ax;self.y=ay;self.rsUiParent=p end
        function e:EnableKeyboard(v)calls.keyboard=calls.keyboard+1;self.keyboard=v;return v end
        function e:EnableFocus(v)self.focusEnabled=v;return v end
        function e:SetFocus()calls.focus=calls.focus+1;calls.focusId=self.rsNativePhysicalId;self.selected=false end
        function e:ClearFocus()calls.clear=calls.clear+1;calls.focusId=nil;self.selected=false end
        function e:SelectForTest()assert(self.keyboard and calls.focusId==self.rsNativePhysicalId);self.selected=true end
        function e:CopyForTest()return self.selected and self.keyboard and calls.focusId==self.rsNativePhysicalId and self.text or nil end
        UI:AdoptWidget(e,e.rsUiOwner,id);UI:ClaimNativeAuthority(e,e.rsUiOwner,'strict')
        UI:PrimeNativeState(e,{width=w,height=ht,anchorParent=parent,anchorX=x,anchorY=y,visible=true})
        h.edit=e;return e
    end
    dofile('presentation/v3/pages/rs_v3_foundation_pages.lua')
    local page=assert(S.UIV3.PageHost.factories['system.diagnostics'](nil,'system.diagnostics'))
    S.UIV3.PageHost.pages['system.diagnostics']=page
    local host=h.widgets.v3_diag_report_host
    assert(host:Layout(0,0,700,300))
    assert(h.widgets.v3_diag_output.onClick())
    return S,UI,page,h,calls,host
end
Test('idle refresh and unchanged viewport cannot rewrite text geometry cursor or focus',function()
    local S,UI,page,h,c,host=Boot();h.edit:SelectForTest();local before=h.edit.text
    local text,focus,extent,anchor,cursor=c.text,c.focus,c.extent,c.anchor,c.cursor
    c.drift=true
    for i=1,20 do c.now=i*1000;page:Refresh();assert(host:Layout(0,0,700,300))end
    assert(h.edit:CopyForTest()==before,'delayed copy lost selection')
    assert(c.text==text and c.focus==focus and c.extent==extent and c.anchor==anchor and c.cursor==cursor,'idle wrote to Native editor')
end)
Test('changed viewport still resizes and failed size transaction is retried',function()
    local S,UI,page,h,c,host=Boot();local old=c.extent
    assert(host:Layout(0,0,800,400));assert(h.edit.width==792 and h.edit.height==392 and c.extent>old)
    c.failExtent=true;host:Layout(0,0,900,450);assert(h.edit.width==792)
    c.failExtent=false;host:Layout(0,0,900,450);assert(h.edit.width==892 and h.edit.height==442)
end)
Test('late lost-focus notification cannot disable the still-owned copy input',function()
    local S,UI,page,h,c=Boot();h.edit:SelectForTest();local before=h.edit.text
    local f,k=c.focus,c.keyboard;c.now=2100;h.edit.handlers.OnLostFocus()
    assert(h.edit:CopyForTest()==before,'still-focused report was disarmed')
    assert(c.focus==f and c.keyboard==k,'guard rewrote focus or keyboard instead of preserving it')
end)
-- Native失焦通知与GetFocusedWidgetId更新可有两种次序；必须用一次性复核区分，
-- 禁止长期保活输入、复位SetFocus或挂周期轮询。这里驱动真实Scheduler任务。
Test('early lost-focus notification disarms after native focus changes without a second event',function()
    local S,UI,page,h,c=Boot();local f,clear=c.focus,c.clear
    h.edit.handlers.OnLostFocus()
    local task=h.edit.rsUiCopyFocusTask
    assert(task and S.Scheduler.tasks[task],'ambiguous focus must schedule one recheck')
    c.focusId='native_chat';S.Scheduler:RunTask(task)
    assert(not h.edit.keyboard and c.focusId=='native_chat' and c.focus==f and c.clear==clear)
    assert(not S.Scheduler.tasks[task] and not h.edit.rsUiCopyFocusTask)
end)
Test('bounded focus recheck preserves late notifications and coalesces duplicate events',function()
    local S,UI,page,h,c=Boot();h.edit:SelectForTest();local body=h.edit.text
    for i=1,12 do h.edit.handlers.OnLostFocus()end
    local task=h.edit.rsUiCopyFocusTask;assert(task,'missing bounded recheck')
    local n=0;for _ in pairs(S.Scheduler.tasks)do n=n+1 end;assert(n==1,'unbounded deferred focus work')
    local f,k=c.focus,c.keyboard;S.Scheduler:RunTask(task)
    assert(h.edit:CopyForTest()==body and c.focus==f and c.keyboard==k)
    assert(not S.Scheduler.tasks[task] and not h.edit.rsUiCopyFocusTask)
end)
Test('hide cancels deferred check and stale callback cannot reactivate input',function()
    local S,UI,page,h,c=Boot();h.edit.handlers.OnLostFocus();local task=h.edit.rsUiCopyFocusTask
    assert(task);local callback=S.Scheduler.tasks[task].callback
    page:OnDeactivated();assert(not S.Scheduler.tasks[task] and not h.edit.rsUiCopyFocusTask)
    local f,k=c.focus,c.keyboard;callback()
    assert(not h.edit.keyboard and c.focus==f and c.keyboard==k)
end)
Test('missing scheduler fails closed on ambiguous lost focus',function()
    local S,UI,page,h,c=Boot();S.Scheduler=nil;h.edit.handlers.OnLostFocus()
    assert(not h.edit.keyboard and not h.edit.rsUiCopyFocusTask)
end)
Test('failed one-shot registration cannot leave copy keyboard armed',function()
    local S,UI,page,h,c=Boot();S.Scheduler.AddHighFrequencyOneShot=function()return false end
    h.edit.handlers.OnLostFocus();assert(not h.edit.keyboard and not h.edit.rsUiCopyFocusTask)
end)
Test('external chat focus releases copy keyboard without stealing or clearing chat',function()
    local S,UI,page,h,c=Boot();local f,clear=c.focus,c.clear
    c.focusId='native_chat';h.edit.handlers.OnLostFocus()
    assert(not h.edit.keyboard and c.focusId=='native_chat' and c.focus==f and c.clear==clear)
end)
Test('unavailable focus identity fails closed rather than arming keyboard indefinitely',function()
    local S,UI,page,h,c=Boot();GetFocusedWidgetId=nil;h.edit.handlers.OnLostFocus()
    assert(not h.edit.keyboard)
end)
Test('ordinary input bindings keep their existing lost-focus policy',function()
    local S,UI,page,h,c=Boot();assert(UI:BindDeferredInputActivation(h.edit,h.edit.rsUiOwner,'ordinary_input'))
    h.edit.handlers.OnLostFocus();assert(not h.edit.keyboard,'copy-only policy leaked to regular input')
end)
Test('repeat click while armed preserves existing selection without extra SetFocus',function()
    local S,UI,page,h,c=Boot();h.edit:SelectForTest();local before=h.edit.text;local f=c.focus
    h.edit.handlers.OnClick();assert(h.edit:CopyForTest()==before and c.focus==f)
end)
Test('hide clears report and releases owned keyboard despite copy-focus guard',function()
    local S,UI,page,h,c=Boot();h.edit:SelectForTest();page:OnDeactivated()
    assert(not h.edit.keyboard and h.edit.text=='' and not h.edit.visible and not page.selfCheckText)
    assert(c.focusId==nil)
end)
Test('hide does not clear external chat focus',function()
    local S,UI,page,h,c=Boot();c.focusId='native_chat';local clear=c.clear
    page:OnDeactivated();assert(c.focusId=='native_chat' and c.clear==clear and not h.edit.keyboard)
end)
Test('old generation callbacks cannot change the next generation',function()
    local S,UI,page,h,c=Boot();local f,k=c.focus,c.keyboard;S.Generation=S.Generation+1
    h.edit.handlers.OnClick();h.edit.handlers.OnLostFocus();assert(c.focus==f and c.keyboard==k)
end)
Test('copy diagnostics are bounded metadata and never contain report body',function()
    local S,UI,page,h,c=Boot();assert(type(page.GetReportInputSnapshot)=='function','copy state provider missing')
    h.edit:SelectForTest();c.now=2001;h.edit.handlers.OnLostFocus()
    local snapshot=page:GetReportInputSnapshot()
    assert(snapshot.patch=='report-selection-1' and snapshot.input.stillFocusedNotifications==1)
    assert(snapshot.input.focused==true and snapshot.input.keyboardArmed==true)
    assert(snapshot.text==nil and snapshot.report==nil and snapshot.raw==nil and snapshot.input.text==nil)
    local text=assert(S.DiagnosticsManager:BuildPagedSelfCheckReport())
    assert(text:find('[REPORT_INPUT]',1,true) and text:find('report-selection-1',1,true))
end)
Test('page next and previous retain report identity and never recapture source data',function()
    local S,UI,page,h,c=Boot()
    S.RecordLog('error','selection_test',('完整诊断证据'):rep(350))
    assert(h.widgets.v3_diag_output_full.onClick());assert(page.selfCheckDelivery.parts>1)
    local checks=c.checks;local text,id=page.selfCheckText,page.selfCheckMeta.id
    assert(h.widgets.v3_diag_report_next.onClick());assert(h.widgets.v3_diag_report_prev.onClick())
    assert(page.selfCheckText==text and page.selfCheckMeta.id==id and c.checks==checks)
end)
print('REPORT SELECTION RESULT '..passed..' passed / '..failed..' failed ('.._VERSION..')')
if failed>0 then error('report-selection failures: '..failed)end

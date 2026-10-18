------------------------------------------------------------------------
-- Replicated Suite · 编辑草稿会话测试
-- 作者：Replicated
-- QQ群：1104129461
--
-- RSUI DraftSession V2 回归使用生产控件及已有有界原生宿主；RU 剪贴板和焦点契约仅模拟明确的宿主状态转换。
------------------------------------------------------------------------
local Base = dofile('tools/rs_gear_page_test_host.lua')
local passed, failed = 0, 0
local function Test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then passed=passed+1; print('PASS draft-session-v2 '..name)
    else failed=failed+1; print('FAIL draft-session-v2 '..name..': '..tostring(err)) end
end

local function NewInput(kind, id, initial, extra)
    local h=Base({width=820,height=680})
    local authority=initial
    local writes=0
    local parent=h.Native(nil,'draft_session_parent_'..id,0,0,420,80)
    local spec={id=id,parent=parent,value=initial,get=function()return authority end,
        set=function(v) writes=writes+1; authority=v; return true end}
    for k,v in pairs(extra or {}) do spec[k]=v end
    local c
    if kind=='numeric' then
        spec.min=0;spec.max=100;spec.step=1;spec.integer=true
        c=assert(h.S.RSUI:NumericInput(spec))
    else
        spec.maxLength=64;spec.allowEmpty=true
        c=assert(h.S.RSUI:TextInput(spec))
    end
    return h,c,function()return authority,writes end
end

local function RealBlur(h,c)
    h.UI.focused=nil
    assert(type(c.root.events.OnLostFocus)=='function','lost-focus handler missing')
    c.root.events.OnLostFocus()
end

-- 真实 Diff/Authority；Native 可修改编辑缓冲而不派发 Lua OnClick，焦点getter不可用。
-- 旧宿主替换 SetText/Activate，不能证明 Native 草稿是否被严格缓存误当外部写入。
local function NewRealDiffInput(id,kind)
    local h,c,state=NewInput(kind or 'numeric',id,24,{draftCommitMode='explicit'})
    local UI=h.UI;dofile('ui/rs_ui_framework.lua')
    local n=c.root
    n.rsUiKeyboardInput=true;n.rsUiKeyboardArmed=false;n.rsNativePhysicalId=id;n.rsUiLogicalId=id;n.rsUiParent=n.parent
    function n:EnableKeyboard(value)self.keyboard=value end
    function n:SetFocus()h.nativeFocusId=id;h.focusWrites=(h.focusWrites or 0)+1 end
    function n:ClearFocus()h.nativeFocusId=nil;h.focusClears=(h.focusClears or 0)+1 end
    -- RU清单明确不允许焦点getter；fixture必须保持与实机相同的缺失能力。
    GetFocusedWidgetId=nil
    assert(UI:AdoptV3Widget(n,c.owner,id));UI:PrimeNativeState(n,{text=n.text,visible=true,enabled=true})
    return h,c,state
end

Test('Native text without OnClick starts the page draft fence before a refresh',function()
    local h,c,state=NewRealDiffInput('native_focus_page_fence')
    h.nativeFocusId=c.id;c.root.text='2'
    assert(h.S.RSUI:HasActiveInputDraftWithin(c),'Native focus did not create the page draft fence')
    assert(c:HasDraftSession() and c:GetDraftValue()=='2','focused Native text was not captured into the draft')
    local value,writes=state();assert(value==24 and writes==0,'focus capture changed business Authority')
    assert((h.focusWrites or 0)==0 and (h.focusClears or 0)==0,'focus capture disturbed Native caret ownership')
    assert(h.UI:GetAuthoritySnapshot().violations==0)
end)

Test('Native text captured by Render survives blur and commits without false violations',function()
    local h,c,state=NewRealDiffInput('native_focus_render')
    h.nativeFocusId=c.id;c.root.text='2';c:Render(nil,'binding_refresh')
    assert(c:HasDraftSession(),'Render preserved one frame but did not establish a draft session')
    h.nativeFocusId=nil;c.root.events.OnLostFocus();c:Render(nil,'binding_refresh')
    assert(c:GetDraftNumber()==2 and c.root.text=='2','Native draft reverted after blur')
    assert(c:CommitAndEndEditing('apply'))
    local value,writes=state();assert(value==2 and writes==1)
    assert(h.UI:GetAuthoritySnapshot().violations==0,'legal Native input was audited as external text')
end)

Test('Native buffer reentry keeps characters typed before Lua observes the edit',function()
    local h,c,state=NewRealDiffInput('native_focus_reentry')
    h.nativeFocusId=c.id;c.root.text='2';c:Render(nil,'binding_refresh')
    h.nativeFocusId=nil;c.root.events.OnLostFocus()
    assert(c:HasDraftSession() and c:GetDraftNumber()==2)
    -- 没有Lua OnClick；Native先取得焦点并接收新字符，接管不能把23写回旧草稿2。
    h.nativeFocusId=c.id;c.root.text='23';c:Render(nil,'binding_refresh')
    assert(c.root.text=='23' and c:GetDraftNumber()==23,'automatic reentry erased new Native typing')
    local value,writes=state();assert(value==24 and writes==0)
    assert(h.S.RSUI:GetInputDraftSessionSnapshot().nativeTextAdoptions==2)
    assert(h.UI:GetAuthoritySnapshot().violations==0)
end)

Test('OnClick after Native adoption retains characters typed during the same edit',function()
    for _,kind in ipairs({'numeric','text'})do
        local h,c,state=NewRealDiffInput('native_focus_late_click_'..kind,kind)
        h.nativeFocusId=c.id;c.root.text='2';c:Render(nil,'binding_refresh')
        assert(c:HasDraftSession())
        c.root.text='23';assert(c.root.events.OnClick(c.root,'LeftButton'))
        assert(c.root.text=='23' and c:GetDraftValue()=='23',kind..' late OnClick erased new Native characters')
        local value,writes=state();assert(value==24 and writes==0)
        assert(h.UI:GetAuthoritySnapshot().violations==0)
    end
end)

Test('TextInput also captures Native text and cancellation remains a legal text transaction',function()
    local h,c,state=NewRealDiffInput('native_focus_text','text')
    h.nativeFocusId=c.id;c.root.text='新草稿';c:Render(nil,'binding_refresh')
    assert(c:HasDraftSession() and c:GetDraftValue()=='新草稿')
    assert(c:CancelEditing('cancel'))
    local value,writes=state();assert(value==24 and writes==0 and c.root.text=='24')
    assert(not c:HasDraftSession() and h.UI:GetAuthoritySnapshot().violations==0)
end)

Test('ordinary label Native writes remain strict Authority violations',function()
    local h,c=NewRealDiffInput('external_label')
    local n=h.Native(nil,'ordinary_label',0,0,80,24)
    assert(h.UI:AdoptV3Widget(n,c.owner,'ordinary_label'))
    h.UI:PrimeNativeState(n,{text='24',visible=true,enabled=true});n.text='2'
    h.UI:SetText(n,'24',c.owner)
    assert(n.text=='24' and h.UI:GetAuthoritySnapshot().violations==1,'label text bypassed strict auditing')
end)

Test('missing focus and missing OnClick preserve typing deletion empty and partial numeric text',function()
    local h,c,state=NewRealDiffInput('native_text_no_events')
    for _,text in ipairs({'2','22','','-','0.','0.5'})do
        c.root.text=text
        for i=1,3 do c:Render(nil,'visual_tick') end
        assert(c.root.text==text and c:GetDraftValue()==text,'ambient refresh erased '..text)
        local value,writes=state();assert(value==24 and writes==0,'ambient draft changed Binding')
    end
    assert((h.focusWrites or 0)==0 and (h.focusClears or 0)==0,'draft observation changed focus')
    assert(c.root.rsUiKeyboardArmed~=true,'draft observation armed the keyboard')
    assert(h.UI:GetAuthoritySnapshot().violations==0)
end)

Test('Apply before ambient refresh reads the latest Native draft even after blur',function()
    local h,c,state=NewRealDiffInput('native_text_action')
    c.root.text='2';c:Render(nil,'visual_tick');c.root.events.OnLostFocus()
    c.root.text='22' -- 实机没有交付新的OnClick，Apply先于下一次刷新。
    assert(c:CommitAndEndEditing('apply'))
    local value,writes=state();assert(value==22 and writes==1,'Apply read an older detached draft')
    assert(c.root.text=='22' and not c:HasDraftSession())
    assert(h.UI:GetAuthoritySnapshot().violations==0)
end)

Test('unchanged editable buffers do not create drafts or block refresh',function()
    local h,c,state=NewRealDiffInput('native_text_unchanged')
    for i=1,3 do assert(not h.S.RSUI:HasActiveInputDraftWithin(c));c:Render(nil,'visual_tick') end
    assert(not c:HasDraftSession())
    local value,writes=state();assert(value==24 and writes==0)
end)

Test('foreign owner hidden ancestor and retired input cannot create Native text drafts',function()
    for _,mode in ipairs({'owner','hidden','retired','stale','disabled','disabled_ancestor'})do
        local h,c=NewRealDiffInput('native_focus_guard_'..mode)
        h.nativeFocusId=c.id;c.root.text='2'
        if mode=='owner'then c.owner='v3:foreign'
        elseif mode=='hidden'then h.UI:PrimeNativeState(c.root.rsUiParent or c.root.parent,{visible=false})
        elseif mode=='retired'then c.root.rsUiInputLifecycleRetired=true
        elseif mode=='stale'then c.root.rsNativeGeneration=h.S.Generation+1
        elseif mode=='disabled_ancestor'then h.UI:PrimeNativeState(c.root.rsUiParent,{enabled=false})
        else h.UI:PrimeNativeState(c.root,{enabled=false})end
        assert(not h.S.RSUI:HasActiveInputDraftWithin(c),'invalid '..mode..' input acquired a draft')
        assert(not c:HasDraftSession())
        assert(not h.UI:AdoptInputDraftText(c.root,c.owner),'invalid '..mode..' passed the commit handoff guard')
    end
end)

Test('failed Native render retries Authority instead of manufacturing a user draft',function()
    for _,kind in ipairs({'numeric','text'})do
        local h,c=NewRealDiffInput('native_write_retry_'..kind,kind)
        assert(c.binding:Set(30,true,'external_update'))
        local set=c.root.SetText;local fail=true
        c.root.SetText=function(self,text)if fail then fail=false;error('one rejected write')end;return set(self,text)end
        c:Render(nil,'binding_refresh')
        assert(c.root.text=='24' and not c:HasDraftSession())
        c:Render(nil,'binding_refresh')
        assert(c.root.text=='30' and not c:HasDraftSession(),kind..' old buffer became a false draft')
    end
end)

Test('retiring Native input removes its draft and every ancestor scope index',function()
    local h,c,state=NewRealDiffInput('native_draft_retire')
    c.root.text='22';c:Render(nil,'visual_tick');assert(c:HasDraftSession())
    local drafts=h.S.RSUI.InputDraftCoordinator
    local scopes={};for _,node in ipairs(c._draftScopes)do scopes[#scopes+1]=node end
    assert(h.UI:RetireInputWidget(c.root,c.owner,'owner_release'))
    assert(not c:HasDraftSession() and drafts.byNative[c.root]==nil)
    for _,node in ipairs(scopes)do assert(not drafts.byScope[node][c],'retired input remained indexed')end
    assert(h.S.RSUI:GetInputDraftSessionSnapshot().active==0)
    local value,writes=state();assert(value==24 and writes==0)
end)

Test('explicit page cancellation after shell hide discards Native input without a false violation',function()
    for _,kind in ipairs({'numeric','text'})do
        local h,c,state=NewRealDiffInput('native_hidden_cancel_'..kind,kind)
        c.root.text='2' -- 还没有刷新或OnClick，Shell已先隐藏。
        h.UI:PrimeNativeState(c.root.rsUiParent,{visible=false})
        c:Render(nil,'binding_refresh')
        assert(c.root.text=='2' and h.UI:GetAuthoritySnapshot().violations==0,'hidden ambient refresh overwrote the buffer')
        h.S.RSUI:CancelInputDraftsWithin(c,'page_deactivated')
        assert(c.root.text=='24' and not c:HasDraftSession())
        assert(h.UI:GetAuthoritySnapshot().violations==0,'explicit hidden cancel was audited as a foreign write')
        local value,writes=state();assert(value==24 and writes==0)
    end
end)

Test('first render initializes input under a hidden page before it is displayed',function()
    local h,c=NewRealDiffInput('native_hidden_initial')
    c.lastRenderedText=nil;c.lastObservedNativeText=nil;c.root.text=''
    h.UI:PrimeNativeState(c.root.rsUiParent,{visible=false})
    c:Render(nil,'initial')
    assert(c.root.text=='24' and c.lastRenderedText=='24' and not c:HasDraftSession())
end)

Test('Enter and legacy blur observe Native typing before any click or Render',function()
    for _,kind in ipairs({'numeric','text'})do
        for _,event in ipairs({'OnEnterPressed','OnLostFocus'})do
            local h,c,state=NewRealDiffInput('native_commit_event_'..kind..event,kind)
            if event=='OnLostFocus' then c.draftCommitMode='blur' end
            c.root.text='22';assert(c.root.events[event]);c.root.events[event]()
            local value,writes=state()
            assert(tostring(value)=='22' and writes==1,kind..' '..event..' missed unobserved Native typing')
            assert(not c:HasDraftSession() and h.UI:GetAuthoritySnapshot().violations==0)
        end
    end
end)

Test('explicit NumericInput lost focus suspends draft without Authority write',function()
    local h,c,state=NewInput('numeric','draft_v2_numeric_explicit',17,{draftCommitMode='explicit'})
    assert(type(c.HasDraftSession)=='function','HasDraftSession API missing')
    assert(type(c.SuspendEditing)=='function','SuspendEditing API missing')
    assert(c:BeginEditing('test'))
    c.root.text='1'
    RealBlur(h,c)
    local authority,writes=state()
    assert(authority==17 and writes==0,'blur wrote Authority: '..tostring(authority)..'/'..tostring(writes))
    assert(c:HasDraftSession()==true,'explicit blur discarded draft session')
    assert(c:IsEditing()==false,'explicit blur must release Native editing ownership')
    assert(c:GetDraftValue()=='1','draft text was not captured on blur: '..tostring(c:GetDraftValue()))
    c:Render(nil,'binding_refresh')
    assert(c.root.text=='1','ambient Render overwrote suspended draft: '..tostring(c.root.text))
end)

Test('explicit NumericInput refocus restores same draft and Apply commits once',function()
    local h,c,state=NewInput('numeric','draft_v2_numeric_refocus',17,{draftCommitMode='explicit'})
    assert(c:BeginEditing('first'))
    c.root.text='1'
    RealBlur(h,c)
    c.root.text='17' -- 模拟未获取焦点时发生的无关原生重绘。
    assert(c:BeginEditing('second'))
    assert(c.root.text=='1','refocus failed to restore Lua-owned draft: '..tostring(c.root.text))
    local ok,err=c:CommitAndEndEditing('apply_button')
    assert(ok==true,tostring(err))
    local authority,writes=state()
    assert(authority==1 and writes==1,'Apply did not commit exactly once: '..tostring(authority)..'/'..tostring(writes))
    assert(c:HasDraftSession()==false,'committed draft session leaked')
end)

Test('TextInput action read sees visible draft before LostFocus commits Binding',function()
    local h,c,state=NewInput('text','draft_v2_text_action','',{draftCommitMode='blur'})
    assert(type(c.GetActionValue)=='function','GetActionValue API missing')
    assert(c:BeginEditing('test'))
    c.root.text='生活方案'
    local authority,writes=state()
    assert(authority=='' and writes==0,'fixture committed before button action')
    assert(c:GetValue()=='','GetValue must remain committed Binding authority')
    assert(c:GetActionValue()=='生活方案','button action did not see visible draft')
end)

Test('explicit TextInput lost focus preserves draft instead of restore Authority',function()
    local h,c,state=NewInput('text','draft_v2_text_explicit','原值',{submitOnLostFocus=false})
    assert(c:BeginEditing('test'))
    c.root.text='草稿'
    RealBlur(h,c)
    local authority,writes=state()
    assert(authority=='原值' and writes==0,'text blur wrote Authority')
    assert(c:HasDraftSession()==true,'text draft discarded')
    assert(c:GetDraftValue()=='草稿','text draft not preserved: '..tostring(c:GetDraftValue()))
    c:Render(nil,'binding_refresh')
    assert(c.root.text=='草稿','text ambient render restored Authority')
end)

Test('switching explicit inputs suspends previous draft without committing it',function()
    local h=Base({width=820,height=680})
    local p=h.Native(nil,'draft_switch_parent',0,0,420,100)
    local a1,a2,w1,w2=10,20,0,0
    local c1=assert(h.S.RSUI:NumericInput({id='draft_switch_1',parent=p,min=0,max=100,step=1,integer=true,draftCommitMode='explicit',
        get=function()return a1 end,set=function(v)w1=w1+1;a1=v;return true end}))
    local c2=assert(h.S.RSUI:NumericInput({id='draft_switch_2',parent=p,min=0,max=100,step=1,integer=true,draftCommitMode='explicit',
        get=function()return a2 end,set=function(v)w2=w2+1;a2=v;return true end}))
    assert(c1:BeginEditing('first'));c1.root.text='11'
    assert(c2:BeginEditing('second'))
    assert(a1==10 and w1==0,'switch auto-committed previous draft')
    assert(c1:HasDraftSession()==true and c1:IsEditing()==false,'previous draft was not suspended')
    assert(c1:GetDraftValue()=='11','previous draft text lost on switch')
    assert(c2:HasDraftSession()==true and c2:IsEditing()==true,'new input did not acquire draft/focus')
end)

Test('legacy blur-mode NumericInput still commits on real blur',function()
    local h,c,state=NewInput('numeric','draft_v2_numeric_blur',17,{draftCommitMode='blur'})
    assert(c:BeginEditing('test'));c.root.text='12';RealBlur(h,c)
    local authority,writes=state()
    assert(authority==12 and writes==1,'legacy blur commit changed: '..tostring(authority)..'/'..tostring(writes))
    assert(type(c.HasDraftSession)~='function' or c:HasDraftSession()==false,'blur-commit session leaked')
end)


local function LoadForms(h)
    if type(h.S.UI.CreateSlider) ~= 'function' then
        h.S.UI.CreateSlider=function(_,parent,id,x,y,w,ht,min,max,step,value)
            local n=h.Native(parent,id,x,y,w,ht);n.value=tonumber(value) or tonumber(min) or 0;n.min,n.max,n.step=min,max,step;n.pickable=true
            function n:GetValue()return self.value end
            function n:SetValue(v)self.value=tonumber(v) or self.value;return true end
            function n:SetRange(a,b,s)self.min,self.max,self.step=a,b,s;return true,true end
            function n:SetValueChangedHandler(fn)self.rsValueChanged=fn end
            return n
        end
    end
    dofile('ui/framework/rs_ui_forms.lua')
end

Test('NumericField Apply button owns explicit draft across blur',function()
    local h=Base({width=820,height=680});LoadForms(h)
    local p=h.Native(nil,'draft_field_apply_parent',0,0,520,90)
    local authority,writes=17,0
    local field=assert(h.S.RSUI:NumericField({id='draft_field_apply',parent=p,min=1,max=100,step=1,integer=true,
        slider=false,applyButton=true,inline=true,get=function()return authority end,set=function(v)writes=writes+1;authority=v;return true end}))
    local c=field.input;assert(c:BeginEditing('test'));c.root.text='1';RealBlur(h,c)
    assert(authority==17 and writes==0,'Apply field committed on blur')
    assert(c:HasDraftSession()==true and c:GetDraftNumber()==1,'Apply field lost suspended draft')
    local ok=field:ApplyDraft('apply_button');assert(ok==true,'ApplyDraft rejected')
    assert(authority==1 and writes==1,'Apply did not commit one authoritative value')
    assert(c:HasDraftSession()==false,'Apply did not close draft')
end)

Test('NumericField slider commit supersedes suspended exact-input draft',function()
    local h=Base({width=820,height=680});LoadForms(h)
    local p=h.Native(nil,'draft_field_slider_parent',0,0,620,90)
    local authority,writes=10,0
    local field=assert(h.S.RSUI:NumericField({id='draft_field_slider',parent=p,min=1,max=100,step=1,integer=true,
        slider=true,applyButton=true,inline=true,get=function()return authority end,set=function(v)writes=writes+1;authority=v;return true end}))
    local c=field.input;assert(c:BeginEditing('test'));c.root.text='11';RealBlur(h,c)
    assert(c:HasDraftSession()==true and authority==10,'setup did not keep suspended draft')
    assert(field.slider:CommitValue(20,'slider'))
    assert(authority==20,'slider failed Authority commit')
    assert(c:HasDraftSession()==false,'slider left stale text draft active')
    assert(c.root.text=='20','slider Authority did not replace exact input: '..tostring(c.root.text))
end)


Test('fixed slider window ignores saved expansion while exact input preserves slower values',function()
    local h=Base({width=820,height=680});LoadForms(h)
    local reads,writes=0,0
    h.S.RSUI.NumericRangeStore={Get=function()reads=reads+1;return 1,2000 end,Set=function()writes=writes+1;return true end}
    local p=h.Native(nil,'fixed_refresh_parent',0,0,620,90);local authority=500
    local field=assert(h.S.RSUI:NumericField({id='fixed_refresh',parent=p,min=1,max=100,hardMin=1,hardMax=60000,fixedSliderRange=true,
        step=1,integer=true,slider=true,applyButton=true,inline=true,get=function()return authority end,set=function(v)authority=v;return true end}))
    local low,high=field:GetPresentationRange();assert(low==1 and high==100 and reads==0 and authority==500)
    assert(field.input:BeginEditing('test'));field.input.root.text='1000';assert(field:ApplyDraft('apply_button'))
    low,high=field:GetPresentationRange();assert(authority==1000 and low==1 and high==100 and writes==0)
    assert(field.slider:CommitValue(1,'slider'));assert(authority==1)
end)

Test('switching away from legacy blur input still commits for compatibility',function()
    local h=Base({width=820,height=680})
    local p=h.Native(nil,'draft_switch_blur_parent',0,0,420,100)
    local a1,w1=10,0
    local c1=assert(h.S.RSUI:NumericInput({id='draft_switch_blur_1',parent=p,min=0,max=100,step=1,integer=true,draftCommitMode='blur',
        get=function()return a1 end,set=function(v)w1=w1+1;a1=v;return true end}))
    local c2=assert(h.S.RSUI:NumericInput({id='draft_switch_blur_2',parent=p,min=0,max=100,step=1,integer=true,draftCommitMode='explicit',
        get=function()return 20 end,set=function()return true end}))
    assert(c1:BeginEditing('first'));c1.root.text='13'
    assert(c2:BeginEditing('second'))
    assert(a1==13 and w1==1,'legacy blur input did not commit on input switch')
    assert(c1:HasDraftSession()==false and c1:IsEditing()==false,'legacy blur session leaked after switch')
end)

Test('DraftSession diagnostics expose state counters but never draft text',function()
    local h,c=NewInput('text','draft_diag_text','authority',{submitOnLostFocus=false})
    assert(c:BeginEditing('diag'));c.root.text='SECRET-DRAFT';RealBlur(h,c)
    local snap=assert(h.S.RSUI:GetInputDraftSessionSnapshot())
    assert(snap.version==3 and snap.active==1 and snap.focused==0,'diagnostic active/focused counts wrong')
    assert(type(snap.ids)=='table' and snap.ids[1]=='draft_diag_text','diagnostic identity missing')
    local function Scan(v)
        if type(v)=='string' then assert(v~='SECRET-DRAFT','diagnostic leaked draft text')
        elseif type(v)=='table' then for _,x in pairs(v)do Scan(x)end end
    end
    Scan(snap)
    c:CancelEditing('diag_cancel')
    local after=h.S.RSUI:GetInputDraftSessionSnapshot()
    assert(after.active==0 and after.cancelled>=1,'cancel did not close diagnostic session')
end)

print('DRAFT SESSION V2 RESULTS: '..passed..' passed / '..failed..' failed')
if failed>0 then error('draft session v2 regressions: '..failed) end

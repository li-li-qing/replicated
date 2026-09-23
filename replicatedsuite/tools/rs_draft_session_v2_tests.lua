-- RSUI DraftSession V2 regression coverage.
-- Uses production controls with the existing bounded Native host; no RU clipboard/focus ABI is faked beyond explicit host state transitions.
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
    c.root.text='17' -- model an unrelated Native repaint while not focused
    assert(c:BeginEditing('second'))
    assert(c.root.text=='1','refocus failed to restore Lua-owned draft: '..tostring(c.root.text))
    local ok,err=c:CommitAndEndEditing('apply_button')
    assert(ok==true,tostring(err))
    local authority,writes=state()
    assert(authority==1 and writes==1,'Apply did not commit exactly once: '..tostring(authority)..'/'..tostring(writes))
    assert(c:HasDraftSession()==false,'committed draft session leaked')
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
    assert(snap.version==2 and snap.active==1 and snap.focused==0,'diagnostic active/focused counts wrong')
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

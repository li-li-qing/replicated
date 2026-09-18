-- 维护（hud-template-copy-2）：回归旧聊天交付丢分隔符及正文、原生容量、延迟复制和关闭。
-- 删除/绕过实际分页或回读，恢复原始V1聊天，翻页重采Draft、写档、定时重写正文均须失败。
local passed,failed=0,0
local Open=dofile('tools/rs_hud_template_copy_test_host.lua')
local function Test(name,fn)
    local ok,err=pcall(fn)
    if ok then passed=passed+1;print('PASS hud-copy '..name)
    else failed=failed+1;print('FAIL hud-copy '..name..': '..tostring(err))end
end
local function Capture(opts)
    local h,S,F,P,C=Open(opts);assert(h:Click());assert(h.edit,'copy editor missing')
    return h,S,F,P,C
end
Test('interactive copy surface uses the shared transient window policy',function()
    local h,S,F,P,C=Capture();assert(C.templateCopy.root.rsUiTransientWindow==true)
end)
Test('raw template never enters formatted chat',function()
    local h=Capture()
    assert(#h.chat<=1,'template body still delivered through chat')
    for _,r in ipairs(h.chat)do assert(not r.text:find('|',1,true) and not r.text:find('plate{',1,true))end
end)
Test('copy report retains all eleven scoped records without rich delimiters',function()
    local h,S,F,P,C=Open();local initial=C:GetDraftSnapshot()
    -- 维护（hud-default-template-2）：验证复制实际微调值，不依赖旧x/y/size为0；指定目标尺寸27。
    local pc,tc=initial.player.components.class,initial.target.components.class
    C:SetComponent('class');C:Nudge(7,-3);C:SetScope('target');C:Nudge(16,-5);C:Adjust('size',27-tc.size)
    assert(h:Click());local r=assert(C.templateCopy,'copy snapshot missing')
    assert(r.text:find(string.format('HUD_TEMPLATE_V2;PLAYER;CLASS;class{x=%d,y=%d',pc.x+7,pc.y-3),1,true))
    assert(r.text:find(string.format('HUD_TEMPLATE_V2;TARGET;CLASS;class{x=%d,y=%d,size=27',tc.x+16,tc.y-5),1,true))
    local _,count=r.text:gsub('HUD_TEMPLATE_V2;','');assert(count==11)
    assert(not r.text:find('|',1,true) and r.text:find('RS-HUD-TEMPLATE-END',1,true))
    assert(h.edit.copyOptions.preserveFocusedSelection==true)
end)
Test('transport pages reconstruct the immutable full body with checksums',function()
    local h,S,F,P,C=Capture({capacity=650})
    local r=C.templateCopy;assert(r.session.parts>1)
    local joined=''
    for i=1,r.session.parts do
        assert(C:ShowTemplateCopyPage(i));local expected=S.ReportCopyTransport:GetTextPage(r.session,i)
        assert(h.edit:GetText()==expected and #expected<=650)
        local bound=r.session.bounds[i];joined=joined..r.session.text:sub(bound.offset+1,bound.offset+bound.length)
    end
    assert(joined==r.session.text)
    assert(r.session.rawCheck==S.ReportCopyTransport:CopyChecksum(r.text))
    assert(r.session.totalCheck==S.ReportCopyTransport:CopyChecksum(joined))
end)
Test('native capacity lie negotiates only before first delivered page',function()
    local h,S,F,P,C=Capture({capacity=3500,actualCapacity=800})
    -- 预留页头余量可能使实际页长小于协商预算；契约是逐字节回读/实际页长，不是预算等于Native容量。
    assert(C.templateCopy.session.capacity<3500 and C.templateCopy.index==1)
    assert(#h.edit.text<=800 and h.edit.text==S.ReportCopyTransport:GetTextPage(C.templateCopy.session,1))
    assert(h.editWrites<=8)
end)
Test('constant corruption is rejected despite matching byte length',function()
    local h,S,F,P,C=Open();h.corruptText=true
    assert(not h:Click());assert(C.templateCopy.failed and not C.templateCopy.session)
    assert(h.edit.text=='' and #h.chat==0 and h.editWrites<=9)
    assert(C.Diagnostics.templateOutputCount==0 and C.Diagnostics.templateOutputFailures==1)
end)
Test('false SetText and invalid GetText do not count as successful delivery',function()
    for _,key in ipairs({'rejectWrite','throwWrite','nonStringRead'})do
        local h,S,F,P,C=Open();h[key]=true;assert(not h:Click());assert(#h.chat==0)
        assert(C.templateCopy.failed and C.Diagnostics.templateOutputCount==0)
    end
end)
Test('later page failure preserves session identity and boundaries',function()
    local h,S,F,P,C=Capture({capacity=800});local r=C.templateCopy
    local session,id,text=r.session,r.id,r.text;h.actualCapacity=520
    assert(not C:ShowTemplateCopyPage(2));assert(r.session==session and r.id==id and r.text==text)
    assert(r.index==1 and r.requested==2 and r.failed and h.edit.text=='')
    assert(not r.previous.enabled and not r.next.enabled)
    h.actualCapacity=800;assert(h:Click('v3_buff_hud_template_retry'))
    assert(r.index==2 and r.session==session and not r.failed)
end)
Test('out of bounds page cannot wrap or rewrite',function()
    local h,S,F,P,C=Capture({capacity=800});local n=h.editWrites;local r=C.templateCopy
    for _,i in ipairs({0,-1,r.session.parts+1,1.5})do assert(not C:ShowTemplateCopyPage(i))end
    assert(h.editWrites==n and r.index==1)
end)
Test('page navigation is detached from later calibration edits and Store',function()
    local h,S,F,P,C=Capture({capacity=800});local r=C.templateCopy;local text=r.text
    local reads,writes,scans=h.reads,h.writes,h.scans
    C:SetComponent('class');C:Nudge(33,12)
    assert(C:ShowTemplateCopyPage(2) and r.text==text)
    assert(h.reads==reads and h.writes==writes and h.scans==scans)
end)
Test('idle calibration refresh does not reset copied selection',function()
    local h,S,F,P,C=Capture();h.edit:SelectForTest()
    local body=h.edit:CopyForTest();local w,g,f=h.editWrites,h.editGeometry,h.focusCalls
    for i=1,20 do h.ms=h.ms+1000;C:RefreshControls()end
    assert(h.edit:CopyForTest()==body and h.editWrites==w and h.editGeometry==g and h.focusCalls==f)
end)
Test('close copy preserves draft but releases text and keyboard',function()
    local h,S,F,P,C=Capture();local before=C:GetDraftSnapshot();local r=C.templateCopy
    assert(h:Click('v3_buff_hud_template_close'))
    assert(C.visible and C.draft.player.components.class.x==before.player.components.class.x)
    assert(not r.visible and not r.root.shown and not h.edit.rsUiKeyboardArmed and not h.edit.shown)
    assert(r.text==nil and r.session==nil and h.edit.text=='')
end)
Test('calibration exit hides copy child and late navigation is inert',function()
    local h,S,F,P,C=Capture({capacity=800});assert(C:Exit(false));local n=h.editWrites
    assert(not C:ShowTemplateCopyPage(2) and not h:Click('v3_buff_hud_template_retry'))
    assert(h.editWrites==n and not h.edit.rsUiKeyboardArmed and not C.templateCopy.visible)
end)
Test('reexport reuses editor and creates a new identity',function()
    local h,S,F,P,C=Capture();local id=C.templateCopy.id;local edit=h.edit
    -- 维护：新报告捕捉相对原值的变化；旧快照仍不可变，控件仍只构建一个。
    local initial=C:GetDraftSnapshot().player.components.class
    C:SetComponent('class');C:Nudge(4,5);assert(h:Click())
    assert(C.templateCopy.id~=id and h.edit==edit and h.editCreates==1 and C.templateCopy.index==1)
    assert(C.templateCopy.text:find(string.format('class{x=%d,y=%d',initial.x+4,initial.y+5),1,true))
end)
Test('different runtime generation rejects old page callbacks',function()
    local h,S,F,P,C=Capture({capacity=800});local n=h.editWrites;S.Generation=S.Generation+1
    assert(not C:ShowTemplateCopyPage(2) and h.editWrites==n)
end)
Test('chat failure cannot invalidate verified editor copy',function()
    for _,mode in ipairs({'missing','false','throw'})do
        local h,S,F,P,C=Open()
        if mode=='missing'then S.SafeChat=nil elseif mode=='false'then S.SafeChat=function()return false end
        else S.SafeChat=function()error('synthetic_chat')end end
        assert(h:Click() and C.templateCopy.index==1)
    end
end)
Test('missing editor transport binding and geometry fail without saving',function()
    for _,kind in ipairs({'noEditor','transport','rejectBinding','rejectGeometry'})do
        local h,S,F,P,C=Open();local w=h.writes
        if kind=='transport'then S.ReportCopyTransport=nil else h[kind]=true end
        assert(not h:Click() and h.writes==w and C.visible and C.draft)
        assert(#h.chat==0 and C.Diagnostics.templateOutputCount==0)
    end
end)
Test('copy panel geometry fits supported logical viewports',function()
    for _,m in ipairs({{2560,1440,1},{1280,768,1},{1024,768,1.25},{1024,768,2}})do
        local h,S,F,P,C=Capture({width=m[1],height=m[2],scale=m[3]});local r=C.templateCopy
        assert(r.root.x>=0 and r.root.y>=0 and r.root.x+r.root.width<=m[1]/m[3] and r.root.y+r.root.height<=m[2]/m[3])
        assert(h.edit.x>=0 and h.edit.y>=0 and h.edit.x+h.edit.width<=r.root.width and h.edit.y+h.edit.height<=r.root.height)
        assert(r.retry.x+r.retry.width<r.close.x and r.previous.x+r.previous.width<r.next.x)
    end
end)
-- 实际UI Primitive/输入/注册器集成，不能以上面的键盘替身通过代替此层验证。
local function RealCapture(opts)
    local h,S,F,P,C=Open(opts);local ui=h:UseRealCopyUi();assert(h:Click())
    return h,S,F,P,C,ui
end
Test('actual primitive registers report as a window and arms exact owned editor',function()
    local h,S,F,P,C,ui=RealCapture();local r=C.templateCopy
    assert(r.root.kind=='window' and r.root.rsUiTransientWindow and r.root.layer=='system')
    assert(r.root.modal==false and r.root.closeOnEscape==false)
    assert(h.edit.rsUiOwner==C.owner and h.edit.rsUiKeyboardArmed and h.edit.keyboard)
    assert(ui:IsInputWidgetFocused(h.edit)==true and ui:GetRegistrySnapshot().duplicates==0)
end)
Test('actual focus late notification preserves selection without reactivation',function()
    local h,S,F,P,C,ui=RealCapture();h.edit:SelectForTest();local before=h.edit:CopyForTest();local f=h.focusCalls
    h.edit.events.OnLostFocus();local name=h.edit.rsUiCopyFocusTask;assert(name)
    S.Scheduler:RunTask(name)
    assert(h.edit:CopyForTest()==before and h.focusCalls==f and not h.edit.rsUiCopyFocusTask)
end)
Test('actual close cancels queued focus check and leaves external chat alone',function()
    local h,S,F,P,C,ui=RealCapture();h.edit.events.OnLostFocus();local name=h.edit.rsUiCopyFocusTask;assert(name)
    h.focusId='external_chat';local clear=h.clearCalls or 0
    assert(C:CloseTemplateCopy())
    assert(h.focusId=='external_chat' and (h.clearCalls or 0)==clear and not h.edit.keyboard)
    assert(not S.Scheduler.tasks[name] and not h.edit.rsUiCopyFocusTask)
end)
Test('actual diff and primitive reuse do not duplicate ids or raise authority violations',function()
    local h,S,F,P,C,ui=RealCapture();local first=h.edit;assert(h:Click())
    assert(h.edit==first and h.editCreates==1 and ui:GetRegistrySnapshot().duplicates==0)
    assert(ui.FrameworkMetrics.authority.violations==0)
end)
Test('actual native editor and public paging negotiate truncation',function()
    local h,S,F,P,C,ui=RealCapture({capacity=3500,actualCapacity=760});local r=C.templateCopy
    for i=1,r.session.parts do assert(C:ShowTemplateCopyPage(i));assert(#h.edit.text<=760)end
    assert(h.edit.keyboard and r.index==r.session.parts)
end)
print(string.format('HUD_TEMPLATE_COPY_RESULT passed=%d failed=%d',passed,failed))
assert(failed==0,'HUD template copy regression')

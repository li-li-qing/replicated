-- 维护：取证报告交付回归；真实 Backend/Page/Codec，Native 仅替换为可控接收端。
-- 不进入 TOC。验证失效交付的复现，不把模拟结果当作 RU 画面/剪贴板实测。
local passed, failed = 0, 0
local function Test(name, fn)
    local ok, err = xpcall(fn,function(err)return tostring(err).."\n"..debug.traceback()end)
    if ok then passed=passed+1;print('PASS delivery '..name) else failed=failed+1;print('FAIL delivery '..name..': '..tostring(err)) end
end
local function Boot(options)
    options=options or {}
    local calls={chat={},copied={},order={},checks=0}
    ADDON={ChatLog=function(_,text)calls.chat[#calls.chat+1]=text;calls.order[#calls.order+1]='chat';return true end}
    X2Chat=nil; CMF_SYSTEM=0;ReplicatedSuite={}
    dofile('replicatedsuite.lua');local S=ReplicatedSuite;S.RSUI={};S.UI={}
    dofile('core/rs_utils.lua');dofile('core/rs_reuse.lua');dofile('core/rs_api.lua');dofile('core/rs_api_capabilities.lua')
    dofile('core/rs_diagnostics.lua')
    local codec=loadfile('core/rs_report_copy_transport.lua');if codec then codec() end
    dofile('core/rs_self_check_report.lua');local D=S.DiagnosticsManager
    D.BuildSelfCheckReport=function(self)
        calls.checks=calls.checks+1
        local text=options.text or 'RS-SELF-CHECK-1\nID=1.9\n测试：完整诊断正文\nRS-SELF-CHECK-END ID=1.9'
        return text,{id='1.9',bytes=#text,check={status='BLOCKED',blockers=2,warnings=2,checks={}},fenced=3,issueCount=6}
    end
    -- 维护：本宿主只替换报告内容，实际Page/文本分页/回读代码保持真实；独立用例使用真实采集器。
    D.BuildPagedSelfCheckReport=function(self) local t,m=self:BuildSelfCheckReport();m.kind='paged';return t,m end
    if options.clipboard then ADDON.SetClipboardText=function(_,text)calls.copied[#calls.copied+1]=text;return nil end end
    return S,D,calls
end
local function Page(S, calls, options)
    options=options or {}
    local h=dofile('tools/rs_status_ui_test_host.lua')(S)
    local originalRoot=S.UIV3Design.PageRoot
    S.UIV3Design.PageRoot=function(_,parent,spec)
        local n=h.Node(type(spec)=='table' and spec or {id=spec});h.rootKind='fill';return n
    end
    S.UIV3Design.ScrollablePageRoot=function(_,parent,spec)
        h.rootKind='snapped';return h.Node(type(spec)=='table' and spec or {id=spec})
    end
    S.UIV3Design.InfoCard=function(_,parent,spec)local n=h.Node(spec);function n:SetData(v)self.data=v end;return n end
    local create=S.UI.CreateMultiEditBox
    S.UI.CreateMultiEditBox=function(...)
        if options.noEditor then return nil,'test_editor_missing' end
        local e=create(...);e.cap=options.cap or 32768;e.shown=false
        function e:SetText(text) self.text=text:sub(1,self.cap);calls.order[#calls.order+1]='set' end
        function e:MaxTextLength()return self.cap end
        function e:Show(v)self.shown=v;return true end
        function e:SetCursorOffset(v)self.cursor=v end
        return e
    end
    S.UI.ActivateInputWidget=function(_,editor)
        if options.focusFails then return false,'test_focus_rejected' end
        h.focused=editor;calls.order[#calls.order+1]='focus';return true
    end
    S.UI.SetExtent=function(_,e,w,ht)e.width=w;e.height=ht;return true end
    S.UI.EnsureExtent=function(_,e,w,ht)e.width=w;e.height=ht;return true,false end
    S.UI.SetAnchor=function()return true end
    S.UI.EnsureAnchor=function()return true,false end
    S.UI.EnsureVisible=function(_,e,v)e.shown=v;return true,false end
    S.UI.DeactivateInputWidget=function(_,editor)h.deactivated=editor;return true end
    S.ActionRunner={Run=function(_,spec)return spec.execute()end}
    dofile('presentation/v3/pages/rs_v3_foundation_pages.lua')
    local root=assert(S.UIV3.PageHost.factories['system.diagnostics'](nil,'system.diagnostics'))
    return root,h
end
Test('bundled ADDON not-allowed clipboard API must stay blocked even when a function is present',function()
    local S,D,calls=Boot({clipboard=true})
    local allowed=S.Api:IsCapabilityAllowed('ADDON:SetClipboardText')
    assert(allowed==false,'SetClipboardText is under Available/not allowed, not Allowed')
    local root,h=Page(S,calls);assert(h.widgets.v3_diag_output.onClick())
    assert(#calls.copied==0,'non-allowed API invoked')
end)
Test('clipboard denied and absent editor must not claim that report is in the editor',function()
    local S,D,calls=Boot();local root,h=Page(S,calls,{noEditor=true})
    assert(h.widgets.v3_diag_output.onClick()==false)
    assert(#calls.chat==1)
    assert(not calls.chat[1]:find('完整报告在页面文本框',1,true),'false delivery claim before editor readiness')
    assert(calls.chat[1]:find('view=failed',1,true),'missing actual failed delivery')
end)
Test('receipt follows editor write readback and explicit-click focus',function()
    local S,D,calls=Boot();local root,h=Page(S,calls)
    assert(h.widgets.v3_diag_output.onClick())
    assert(h.focused==h.edit,'print did not reveal and activate the full report')
    assert(calls.order[#calls.order]=='chat','receipt sent before presentation')
    assert(calls.chat[1]:find('view=plain',1,true))
end)
Test('short clipboard-denied report is visibly available and focus starts at beginning',function()
    local S,D,calls=Boot();local root,h=Page(S,calls)
    assert(h.widgets.v3_diag_output.onClick());assert(h.edit.shown==true and h.edit.cursor==0)
    assert(h.edit.text:find('RS-SELF-CHECK-1',1,true) and h.edit.text:find('RS-SELF-CHECK-END',1,true))
    assert(h.widgets.v3_diag_report_host.spec.slot.size=='fill','report remains a fixed 280px snapped child')
    assert(h.rootKind=='fill','copy viewport can be wholly hidden by item-snapped ScrollBox')
end)
Test('108833-byte report uses verified readable pages without clipboard',function()
    local body=('RAW_STORE v3.buff_display fingerprint_mismatch 1E7F5813>6307A930\n'):rep(2000)
    local tail='\nRS-SELF-CHECK-END ID=1.9'
    local text=('RS-SELF-CHECK-1\nID=1.9\n'..body):sub(1,108833-#tail)..tail
    assert(#text==108833)
    -- 长度在 screenshot 同量级；内容是合成报告，不宣称是用户实档。
    local S,D,calls=Boot({text=text});local root,h=Page(S,calls,{cap=32768})
    assert(h.widgets.v3_diag_output.onClick(),'whole report delivery failed')
    assert(h.edit.text:find('RS-ERROR-PAGE-1',1,true),'large report not encoded')
    assert(#h.edit.text<32768 and #calls.chat==1 and calls.checks==1)
    assert(root.selfCheckText==text,'original snapshot lost')
end)
Test('tiny editor cap reports exact failure instead of claiming fallback success',function()
    local S,D,calls=Boot({text=('failure details'):rep(9000)});local root,h=Page(S,calls,{cap=20})
    assert(h.widgets.v3_diag_output.onClick()==false)
    assert(calls.chat[1]:find('view=failed',1,true));assert(#calls.chat[1]<=400)
end)
Test('focus failure preserves exact text but instructs user to click it',function()
    local S,D,calls=Boot();local root,h=Page(S,calls,{focusFails=true})
    assert(h.widgets.v3_diag_output.onClick());assert(#h.edit.text>0)
    assert(calls.chat[1]:find('点报告框',1,true),'focus failure not actionable')
end)
Test('calling backend without a presenter must not claim a page exists',function()
    local S,D,calls=Boot();local ok,text,meta=D:PrintSelfCheckReport()
    assert(ok and #text>0 and meta.clipboard=='manual')
    assert(calls.chat[1]:find('view=unavailable',1,true))
    assert(not calls.chat[1]:find('完整报告在页面文本框',1,true))
end)
Test('throwing presenter yields one truthful failed receipt and preserves generated report',function()
    local S,D,calls=Boot();local ok,text,meta=D:PrintSelfCheckReport(function()error('test_presenter_fault')end)
    assert(ok and text and meta.presentation and meta.presentation.state=='failed')
    assert(#calls.chat==1 and calls.chat[1]:find('view=failed',1,true))
end)
Test('clipboard blocked reason is retained not discarded',function()
    local S,D,calls=Boot();local ok,text,meta=D:PrintSelfCheckReport()
    assert(ok and type(meta.clipboardError)=='string' and #meta.clipboardError>0)
end)
Test('hiding report releases keyboard and plaintext and encoded content',function()
    local S,D,calls=Boot();local root,h=Page(S,calls);assert(h.widgets.v3_diag_output.onClick());root:OnDeactivated()
    assert(h.edit.text=='' and root.selfCheckText==nil and h.deactivated==h.edit)
    assert(calls.checks==1 and #calls.chat==1)
end)
Test('copy codec rejects invalid inputs and emits explicit format for valid text',function()
    local S=Boot();local C=assert(S.ReportCopyTransport,'copy codec absent')
    local text,err=C:Encode(nil);assert(text==nil and err)
    text,err=C:Encode(string.rep('x',1048577));assert(text==nil and err)
    local encoded=assert(C:Encode('中文 errors\n\0binary'))
    assert(encoded:match('^RS%-REPORT%-COPY%-1\n') and encoded:find('RS-REPORT-COPY-END',1,true))
end)
Test('encode roundtrip fixtures cover real report, unicode, binary, overlapping matches and incompressible data',function()
    local S=Boot();local C=assert(S.ReportCopyTransport,'copy codec absent')
    local random={};local seed=17
    for i=1,70000 do seed=(seed*16807)%2147483647;random[i]=string.char(seed%256)end
    local f=assert(io.open('tools/.self_check_real_evidence.txt','rb'));local actual=f:read('*a');f:close()
    local cases={'', 'a', 'ab', 'abc', 'abcde', ('A'):rep(20000), ('abcde'):rep(30000),
        ('中文测试\r\n'):rep(10000), table.concat(random), actual, actual:rep(3)}
    for i,text in ipairs(cases)do
        local encoded=assert(C:Encode(text))
        local out=assert(io.open('tools/.copy_transport_'..i..'.txt','wb'));out:write(encoded);out:close()
        out=assert(io.open('tools/.copy_transport_'..i..'.bin','wb'));out:write(text);out:close()
        if i==11 then print('COPY METRIC raw='..#text..' encoded='..#encoded);assert(#encoded<=32768,'real-codec repeated report exceeds one-copy budget') end
    end
end)
-- 维护：真实 RSUI Component + Panel + DesignSystem 布局；只替换 Native setters 和字体测量。
-- 不能冒称像素实测，但能捕获“整块ScrollBox隐藏正文”、宿主fill和输入框尺寸不同步。
local function LayoutPage(S,calls)
    local byId={}
    local function Native(parent,id,x,y,w,h)
        local e={parent=parent,id=id,x=x,y=y,width=w,height=h,shown=true,rsUiOwner='v3:diagnostic_layout_test',text=''}
        function e:Show(v)self.shown=v;return true end
        function e:SetText(v)self.text=v end
        function e:GetText()return self.text end
        function e:SetCursorOffset(v)self.cursor=v end
        function e:MaxTextLength()return 32768 end
        function e:SetExtent(w,h)self.width=w;self.height=h end
        return e
    end
    local UI={}
    S.UI=UI
    UI.CreateEmptyWidget=function(_,p,id,x,y,w,h)return Native(p,id,x,y,w,h)end
    UI.CreatePanel=UI.CreateEmptyWidget
    UI.SetExtent=function(_,e,w,h)e.width=w;e.height=h;return true end
    UI.EnsureExtent=function(_,e,w,h)e.width=w;e.height=h;return true,false end
    UI.SetAnchor=function(_,e,parent,x,y)e.parent=parent;e.x=x;e.y=y;return true end
    UI.EnsureAnchor=function(_,e,parent,x,y)e.parent=parent;e.x=x;e.y=y;return true,false end
    UI.EnsureVisible=function(_,e,v)e.shown=v;return true,false end
    UI.EnsureEnabled=function()return true,false end
    UI.EnsurePickable=function()return true,false end
    UI.TryInteractionCall=function()return true end
    UI.SafeHandler=function()return true end
    UI.CreateMultiEditBox=function(_,p,id,x,y,w,h)local e=Native(p,id,x,y,w,h);UI.testEdit=e;return e end
    UI.BindDeferredInputActivation=function()return true end
    UI.ActivateInputWidget=function(_,e)UI.focused=e;return true end
    UI.DeactivateInputWidget=function()UI.focused=nil;return true end
    dofile('ui/framework/rs_ui_component_core.lua')
    dofile('ui/framework/rs_ui_panels.lua')
    dofile('ui/framework/rs_ui_adaptive_panels.lua')
    local R=S.RSUI
    for _,kind in ipairs({'Text','Button'})do
        R:RegisterType(kind,function(spec)
            local n=R:NewComponent(kind,spec,Native(spec.parent,spec.id,0,0,1,1))
            byId[spec.id]=n;n.text=spec.text or '';n.onClick=spec.onClick
            function n:SetText(text)self.text=text;self:InvalidateMeasure('test_text') end
            function n:Measure(w,h)
                local fs=tonumber(spec.fontSize)or 11
                local est=#self.text*fs*0.45;local lines=1
                if spec.overflow=='wrap' and w and w>0 then lines=math.min(spec.maxLines or 20,math.max(1,math.ceil(est/w))) end
                return math.min(w or est,est),lines*(fs+4)
            end
            return n
        end)
        R[kind]=function(self,spec)return self:Create(kind,spec)end
    end
    dofile('ui/design_system/rs_ui_design_system_v3.lua')
    S.UIV3={PageHost={factories={},RegisterFactory=function(self,id,fn)self.factories[id]=fn;return true end}}
    S.ActionRunner={Run=function(_,spec)return spec.execute()end}
    dofile('presentation/v3/pages/rs_v3_foundation_pages.lua')
    local root,err=S.UIV3.PageHost.factories['system.diagnostics'](Native(nil,'external',0,0,1400,900),'system.diagnostics')
    assert(root,err)
    local function Find(node,id)if node.id==id then return node end;for _,child in ipairs(node.children or {})do local hit=Find(child,id);if hit then return hit end end end
    return root,UI,byId,Find
end
Test('actual RSUI layouts keep report visible in small and large page viewports',function()
    local S,D,calls=Boot();local root,UI,buttons,Find=LayoutPage(S,calls)
    local host=assert(Find(root,'v3_diag_report_host'))
    for _,size in ipairs({{500,340},{660,420},{900,600},{1300,800}})do
        root:Layout(0,0,size[1],size[2])
        assert(host.viewportVisible~=false and host.root.shown~=false,'whole report host hidden')
        assert(host.height>50 and host.y+host.height<=size[2]+0.01,'report geometry: viewport='..size[2]..' y='..tostring(host.y)..' h='..tostring(host.height))
        assert(UI.testEdit.width==host.width-8 and UI.testEdit.height==host.height-8,'Native editor missed host resize')
        assert(buttons.v3_diag_output.onClick(),'actual layout report not delivered')
        assert(UI.focused==UI.testEdit)
    end
end)
Test('layout-only resize neither reloads snapshot nor changes existing report text',function()
    local S,D,calls=Boot();local root,UI,buttons=LayoutPage(S,calls)
    root:Layout(0,0,900,600);assert(buttons.v3_diag_output.onClick());local text=UI.testEdit.text
    root:Layout(0,0,660,420);root:Refresh();root:Layout(0,0,1000,600)
    assert(UI.testEdit.text==text and calls.checks==1 and #calls.chat==1)
end)
Test('visible page records layout transaction rejection before emitting receipt',function()
    local S,D,calls=Boot();local root,UI,buttons=LayoutPage(S,calls)
    UI.EnsureExtent=function()return false,false,'test_extent_rejected' end
    root:Layout(0,0,660,420)
    assert(buttons.v3_diag_output.onClick()==false)
    assert(calls.chat[1]:find('code=GEOMETRY_FAILED',1,true))
end)

-- 维护（2026-09-12容量回归）：本次RU截图明确返回native_cap=9215，不能用32KiB mock
-- 或高度重复的合成串证明可交付。替代Native固定9215，正文含不可压缩部分；验证保全整份
-- 快照并借用原“打印”按钮逐段交付。分段不是完整交付，缺任何一段必须由解码器拒绝。
local function VariedReport()
    local parts,seed={},39
    for i=1,29000 do seed=(seed*16807)%2147483647;parts[i]=string.char(33+seed%90) end
    local head='RS-SELF-CHECK-1\nID=1.9\n'..table.concat(parts)..'\n'
    local tail='\nRS-SELF-CHECK-END ID=1.9'
    return (head..('trace integrity_failed v3.life.trade\n'):rep(5000)):sub(1,109147-#tail)..tail
end
Test('screenshot 9215-byte cap delivers first complete part of a varied 109147-byte report',function()
    local text=VariedReport();assert(#text==109147)
    local S,D,calls=Boot({text=text});local root,h=Page(S,calls,{cap=9215})
    assert(h.widgets.v3_diag_output.onClick(),'known cap must not leave an empty TEXT_LIMIT report')
    assert(#h.edit.text<=9215 and h.edit.text:match('^RS%-ERROR%-PAGE%-1;'),'no bounded part envelope')
    assert(h.edit.text:find('RS-ERROR-PAGE-END',1,true) and root.selfCheckText==text)
    assert(root.selfCheckDelivery.parts>1 and root.selfCheckPart==1 and calls.checks==1)
    assert(calls.chat[1]:find('view=part',1,true) and calls.chat[1]:find('part=1/',1,true))
    assert(root.selfCheckMeta.delivered==false and root.selfCheckMeta.partReady==true,'one part falsely marked complete report')
end)
Test('explicit next delivers all pages and previous returns without rereading',function()
    local S,D,calls=Boot({text=VariedReport()});local root,h=Page(S,calls,{cap=9215})
    assert(h.widgets.v3_diag_output.onClick());local session=assert(root.selfCheckDelivery)
    local first=h.edit.text;local total=session.parts;local collected={first}
    local buttons=0;for _,w in pairs(h.widgets)do if w.onClick then buttons=buttons+1 end end
    assert(buttons==4,'explicit pagination actions missing')
    for i=2,total do
        assert(h.widgets.v3_diag_report_next.onClick());assert(root.selfCheckPart==i)
        assert(h.edit.text:find('PAGE='..i..'/'..total,1,true));assert(#h.edit.text<=9215)
        assert(root.selfCheckDelivery==session and calls.checks==1);collected[#collected+1]=h.edit.text
    end
    assert(#calls.chat==1 and root.selfCheckMeta.delivered==false)
    local out=assert(io.open('tools/.copy_parts_ui.txt','wb'));out:write(table.concat(collected,'\n\n'));out:close()
    out=assert(io.open('tools/.copy_parts_ui.bin','wb'));out:write(root.selfCheckText);out:close()
    assert(h.widgets.v3_diag_report_next.onClick()==false,'last page must not wrap')
    for i=total-1,1,-1 do assert(h.widgets.v3_diag_report_prev.onClick())end
    assert(root.selfCheckPart==1 and h.edit.text==first and calls.checks==1,'previous rebuilt evidence')
end)
Test('run check starts a new copy session but refresh and opening do not advance it',function()
    local S,D,calls=Boot({text=VariedReport()});D.RunSelfCheck=function()return {status='BLOCKED',blockers=2,warnings=2,checks={}}end
    local root,h=Page(S,calls,{cap=9215});assert(h.widgets.v3_diag_output.onClick())
    local first=h.edit.text;root:Refresh();root:OnActivated()
    assert(root.selfCheckPart==1 and h.edit.text==first and calls.checks==1)
    assert(h.widgets.v3_diag_full_check.onClick());assert(root.selfCheckDelivery==nil and root.selfCheckText==nil and h.edit.text=='')
    assert(h.widgets.v3_diag_output.onClick());assert(calls.checks==2 and root.selfCheckPart==1)
end)
Test('failed second-part write never skips its index or regenerates the report',function()
    local S,D,calls=Boot({text=VariedReport()});local root,h=Page(S,calls,{cap=9215})
    assert(h.widgets.v3_diag_output.onClick());local original=h.edit.SetText
    function h.edit:SetText(text) original(self,#text>10 and text:sub(1,-2)or text) end
    assert(h.widgets.v3_diag_report_next.onClick()==false,'truncated part was accepted')
    assert(root.selfCheckPart==1 and calls.checks==1 and root.selfCheckDelivery)
    h.edit.SetText=original
    assert(h.widgets.v3_diag_report_next.onClick());assert(root.selfCheckPart==2 and calls.checks==1)
end)
Test('closing multipart view releases encoded snapshot keyboard and part cursor',function()
    local S,D,calls=Boot({text=VariedReport()});local root,h=Page(S,calls,{cap=9215})
    assert(h.widgets.v3_diag_output.onClick());root:OnDeactivated()
    assert(root.selfCheckText==nil and root.selfCheckDelivery==nil and root.selfCheckPart==nil and h.edit.text=='')
    assert(h.deactivated==h.edit and calls.checks==1)
end)
Test('missing native capacity uses a safe bounded fallback and parts instead of assuming 32KiB',function()
    local S,D,calls=Boot({text=VariedReport()});local root,h=Page(S,calls,{cap=9215})
    h.edit.MaxTextLength=nil
    assert(h.widgets.v3_diag_output.onClick());assert(#h.edit.text<=8192 and root.selfCheckDelivery.parts>1)
end)
Test('copy session retains legacy plain and packed envelopes when they fit',function()
    local S=Boot();local T=S.ReportCopyTransport;assert(type(T.BuildDelivery)=='function','capacity-aware delivery missing')
    local session=assert(T:BuildDelivery('short','1.9',9215));assert(session.parts==1 and session.kind=='plain')
    assert(T:GetDeliveryPart(session,1)=='short')
    session=assert(T:BuildDelivery(('abcde'):rep(8000),'1.9',9215))
    assert(session.parts==1 and session.kind=='packed');assert(T:GetDeliveryPart(session,1):match('^RS%-REPORT%-COPY%-1\n'))
end)
Test('multipart serialization preserves all bytes across real-codec and binary fixtures',function()
    local S=Boot();local T=S.ReportCopyTransport;assert(type(T.BuildDelivery)=='function','capacity-aware delivery missing')
    local f=assert(io.open('tools/.self_check_real_evidence.txt','rb'));local real=f:read('*a');f:close()
    local fixtures={VariedReport(),real,table.concat({string.rep('\0\r\n',10000),VariedReport()}),('abc123'):rep(20000)}
    for i,text in ipairs(fixtures)do
        local cap=i==2 and 1024 or 9215
        local delivery=assert(T:BuildDelivery(text,'1.'..i,cap));assert(delivery.parts>1 or i==4)
        local segments={}
        for index=1,delivery.parts do
            local part=assert(T:GetDeliveryPart(delivery,index));assert(#part<=cap);segments[index]=part
        end
        local out=assert(io.open('tools/.copy_parts_'..i..'.txt','wb'));out:write(table.concat(segments,'\n\n'));out:close()
        out=assert(io.open('tools/.copy_parts_'..i..'.bin','wb'));out:write(text);out:close()
        print('PART METRIC fixture='..i..' raw='..#text..' cap='..cap..' parts='..delivery.parts..' encoded='..#delivery.payload)
    end
end)
Test('capacity inputs and part indices are strictly bounded',function()
    local S=Boot();local T=S.ReportCopyTransport;assert(type(T.BuildDelivery)=='function','capacity-aware delivery missing')
    for _,cap in ipairs({0,-1,0/0,math.huge,1.5})do assert(T:BuildDelivery('short','1.1',cap)==nil) end
    assert(T:BuildDelivery(VariedReport(),'1.1',20)==nil)
    local s=assert(T:BuildDelivery(VariedReport(),'1.1',9215))
    for _,index in ipairs({0,-1,s.parts+1,1.5,0/0,math.huge})do assert(T:GetDeliveryPart(s,index)==nil) end
    assert(T:BuildDelivery('short',('id'):rep(100),9215)==nil)
end)


-- 维护（2026-09-12 TEXT_READBACK）：报告的MaxTextLength是声明上限，不是Set/Get往返保证。
-- 以下接收端差异是合成故障注入，不冒称RU真实转换机制；源报告来自同一个快照。
Test('declared 9215 but actual 4096 bytes negotiates exact first part instead of an empty box',function()
    local text=VariedReport();local S,D,calls=Boot({text=text});local root,h=Page(S,calls,{cap=9215})
    local writes=0
    function h.edit:SetText(value) self.text=value:sub(1,4096);writes=writes+1 end
    assert(h.widgets.v3_diag_output.onClick(),'declared limit was mistaken for roundtrip capacity')
    assert(root.selfCheckPart==1 and #h.edit.text<=4096 and root.selfCheckText==text)
    assert(root.selfCheckDelivery.capacity<=4096 and calls.checks==1 and #calls.chat==1)
    assert(writes<=10,'unbounded native retries')
    assert(root.selfCheckMeta.presentation.readback.attempts>=1,'negotiation evidence absent')
end)
Test('newline removing native accepts a flat ASCII frame without removing evidence',function()
    local text=VariedReport();local S,D,calls=Boot({text=text});local root,h=Page(S,calls,{cap=9215})
    function h.edit:SetText(value) self.text=value:gsub('[\r\n]',''):sub(1,9215) end
    assert(h.widgets.v3_diag_output.onClick(),'no newline-independent copy framing')
    assert(h.edit.text:match('^RS%-ERROR%-PAGE%-1;') and root.selfCheckText==text)
    local all={h.edit.text};for i=2,root.selfCheckDelivery.parts do
        assert(h.widgets.v3_diag_report_next.onClick());all[i]=h.edit.text
    end
    local f=assert(io.open('tools/.copy_wire_ui.txt','wb'));f:write(table.concat(all,'\n\n'));f:close()
    f=assert(io.open('tools/.copy_wire_ui.bin','wb'));f:write(text);f:close()
    assert(calls.checks==1,'fallback regenerated evidence')
end)
Test('flat copy framing tolerates only outer transport whitespace not changes to its data',function()
    local S,D,calls=Boot({text=VariedReport()});local root,h=Page(S,calls,{cap=9215})
    function h.edit:SetText(value)
        if value:match('^RS%-ERROR%-PAGE%-1;') then
            self.text=value:gsub('(.)(.)(.)','%1%2%3\r\n')..'\n'
        else self.text=value:gsub('\n','') end
    end
    assert(h.widgets.v3_diag_output.onClick(),'ASCII whitespace framing not negotiated')
    assert(root.selfCheckPart==1 and root.selfCheckText==VariedReport())
    local T=S.ReportCopyTransport
    local payload=assert(T:GetTextPage(root.selfCheckDelivery,1))
    assert(T:VerifyEditorReadback({wire='plain'},payload,(h.edit.text:gsub('[\r\n]',''))))
    local altered=h.edit.text:gsub('^RS','XS',1)
    assert(not T:VerifyEditorReadback({wire='plain'},payload,(altered:gsub('[\r\n]',''))),'non-whitespace change was trusted')
end)
Test('short report converted by native retries in encoded wire not lossy plain normalization',function()
    local text='RS-SELF-CHECK-1\nID=1.9\n实际字段 包含 空格\t\r\nRS-SELF-CHECK-END ID=1.9'
    local S,D,calls=Boot({text=text});local root,h=Page(S,calls,{cap=9215})
    function h.edit:SetText(value) self.text=value:gsub('[\r\n]','') end
    assert(h.widgets.v3_diag_output.onClick(),'short original is not escaped for transformed native')
    assert(h.edit.text:match('^RS%-ERROR%-PAGE%-1;') and root.selfCheckText==text)
    assert(root.selfCheckMeta.delivered==true and root.selfCheckMeta.partReady==false)
    local f=assert(io.open('tools/.copy_wire_short.txt','wb'));f:write(h.edit.text);f:close()
    f=assert(io.open('tools/.copy_wire_short.bin','wb'));f:write(text);f:close()
end)
Test('SetText/GetText disagreement includes lengths types and first mismatch in one receipt',function()
    local S,D,calls=Boot({text=VariedReport()});local root,h=Page(S,calls,{cap=9215});local writes=0
    function h.edit:SetText(value) self.text=value=='' and '' or 'X';writes=writes+1 end
    assert(h.widgets.v3_diag_output.onClick()==false)
    assert(#calls.chat==1 and calls.chat[1]:find('rb=',1,true),'only generic TEXT_READBACK returned')
    assert(calls.chat[1]:find('@1',1,true) and calls.chat[1]:find('END',1,true))
    assert((root.selfCheckPart or 0)==0 and root.selfCheckText and writes<=10)
    assert(root.selfCheckMeta.presentation.readback.received==1)
end)
Test('getter failure and explicit setter rejection are not described as data truncation',function()
    for _,case in ipairs({'getter','setter'})do
        local S,D,calls=Boot({text=VariedReport()});local root,h=Page(S,calls,{cap=9215})
        if case=='getter' then function h.edit:GetText() error('native getter unavailable') end
        else function h.edit:SetText(value) self.text=value;return false end end
        assert(h.widgets.v3_diag_output.onClick()==false)
        local rb=assert(root.selfCheckMeta.presentation.readback,'missing boundary outcome')
        if case=='getter' then assert(rb.readOk==false) else assert(rb.writeRejected==true) end
        assert(calls.chat[1]:find('rb=',1,true))
    end
end)
Test('native write occurs after viewport reveal and focus so focus cannot erase a validated report',function()
    local S,D,calls=Boot();local root,h=Page(S,calls)
    local activate=S.UI.ActivateInputWidget
    S.UI.ActivateInputWidget=function(...)
        local accepted=activate(...);h.edit.text='';return accepted
    end
    assert(h.widgets.v3_diag_output.onClick())
    assert(h.edit.text==S.ReportCopyTransport:GetTextPage(root.selfCheckDelivery,1),'native focus erased text after it was claimed verified')
    local lastSet,lastFocus
    for i,v in ipairs(calls.order) do if v=='set' then lastSet=i elseif v=='focus' then lastFocus=i end end
    assert(lastFocus and lastSet and lastFocus<lastSet)
end)
Test('first failure retries same frozen report and compression is not repeated during negotiation',function()
    local S,D,calls=Boot({text=VariedReport()});local root,h=Page(S,calls,{cap=9215})
    local encodes=0;local encode=S.ReportCopyTransport.Encode
    S.ReportCopyTransport.Encode=function(self,...)encodes=encodes+1;return encode(self,...)end
    function h.edit:SetText(value) self.text=value:sub(1,3000) end
    assert(h.widgets.v3_diag_output.onClick());assert(calls.checks==1 and encodes==0)
    local session=root.selfCheckDelivery;local original=h.edit.SetText
    function h.edit:SetText(value) original(self,#value>10 and value:sub(1,-2) or value)end
    assert(h.widgets.v3_diag_report_next.onClick()==false)
    assert(root.selfCheckDelivery==session and root.selfCheckPart==1 and calls.checks==1 and encodes==0)
end)

print('DELIVERY RESULT '..passed..' passed / '..failed..' failed ('.._VERSION..')')
assert(failed==0,'report delivery regression failures')

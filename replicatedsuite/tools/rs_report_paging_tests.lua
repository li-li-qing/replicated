-- 维护：用户明确要求固定报告+独立上一页/下一页。使用实际报告/传输/Page工厂；只模拟Native。
-- 此测试不在TOC，既不证明RU实机输入框容量，也不解除任何业务Store写保护。
local passed,failed=0,0
local function Test(name,fn)local ok,e=pcall(fn);if ok then passed=passed+1;print('PASS paging '..name)else failed=failed+1;print('FAIL paging '..name..': '..tostring(e))end end
local function Boot(cap)
 local calls={checks=0,reads=0,chats=0,writes=0}
 ReplicatedSuite={};X2Chat=nil;CMF_SYSTEM=0;ADDON={ChatLog=function()calls.chats=calls.chats+1;return true end}
 dofile('replicatedsuite.lua');local S=ReplicatedSuite;S.RSUI={};S.UI={}
 dofile('core/rs_utils.lua');dofile('core/rs_reuse.lua');dofile('core/rs_api.lua');dofile('core/rs_api_capabilities.lua');dofile('core/rs_diagnostics.lua');dofile('core/rs_report_copy_transport.lua');dofile('core/rs_self_check_report.lua')
 S.FoundationGate={Run=function(_,options)assert(options.skipSequences);calls.checks=calls.checks+1;return {status='BLOCKED',blockers=2,warnings=0,checks={{id='fault',ok=false,severity='blocker',detail='FULL_FAULT_REASON'}}}end}
 S.Persistence={stores={},Describe=function()return {fenced=2,total=2}end,BuildRuntimeAcceptanceSnapshot=function()return {}end}
 for _,id in ipairs({'v3.buff_display','v3.death_review'})do S.Persistence.stores[id]={id=id,writeFenced=true,schemaVersion=2,lastError='REAL_INTEGRITY_FAULT',lastIntegrityMismatchEvidence={stampedFingerprint='12345678',actualFingerprint='87654321'}}end
 S.Persistence.BuildFailedStoreEvidenceText=function(_,id)calls.reads=calls.reads+1;return 'RS-PERSIST-EVIDENCE-1\n'..id..'\n'..('完整原档\\片段;'):rep(800)..'\nRS-PERSIST-EVIDENCE-END'end
 local h=dofile('tools/rs_status_ui_test_host.lua')(S)
 S.UIV3Design.PageRoot=function(_,_,spec)return h.Node(spec)end
 S.UIV3Design.InfoCard=function(_,_,spec)local n=h.Node(spec);function n:SetData(v)self.data=v end;return n end
 S.UI.EnsureVisible=function(_,e,v)e:Show(v);return true end
 S.UI.ActivateInputWidget=function()return true end;S.UI.DeactivateInputWidget=function()calls.deactivated=(calls.deactivated or 0)+1;return true end
 S.ActionRunner={Run=function(_,spec)return spec.execute()end}
 dofile('presentation/v3/pages/rs_v3_foundation_pages.lua')
 local root=assert(S.UIV3.PageHost.factories['system.diagnostics'](nil,'system.diagnostics'))
 function h.edit:MaxTextLength()return 9215 end
 function h.edit:SetText(v)self.text=v:gsub('[\r\n]',''):sub(1,cap or 4096)end
 return S,S.DiagnosticsManager,calls,root,h
end
local function Ready(S)assert(type(S.ReportCopyTransport.BuildTextPages)=='function','BuildTextPages missing');assert(type(S.ReportCopyTransport.GetTextPage)=='function','GetTextPage missing')end
local function Data(text)local n=tonumber(text:match(';DATA_BYTES=(%d+);'));local p=assert(text:find(';DATA=',1,true))+6;return text:sub(p,p+n-1)end
local function Unescape(s)return (s:gsub('\\(.)',function(c)return ({n='\n',r='\r',['\\']='\\'})[c] or error('bad escape')end))end
Test('explicit previous and next accompany focused and full report actions',function()
 local S,D,c,r,h=Boot();local n=0;for _,v in pairs(h.widgets)do if v.onClick then n=n+1 end end
 assert(n==5,'expected run/fault/full/previous/next');assert(h.widgets.v3_diag_report_prev.spec.text=='上一页');assert(h.widgets.v3_diag_report_next.spec.text=='下一页')
 assert(c.checks==0 and c.reads==0 and c.chats==0)
end)
Test('normal builder includes all fenced originals without copy budget deletion',function()
 local S,D,c=Boot();assert(type(D.BuildPagedSelfCheckReport)=='function','paged builder missing')
 S.RecordLog('error','test','LONG_ERROR_START'..('中'):rep(1800)..'LONG_ERROR_END')
 local text,m=D:BuildPagedSelfCheckReport();assert(text,m)
 assert(text:find('LONG_ERROR_END',1,true) and text:find('FULL_FAULT_REASON',1,true))
 assert(m.evidenceIncluded==2 and m.evidenceOmitted==0 and c.reads==2 and c.checks==1)
 assert(text:find('v3.buff_display',1,true) and text:find('v3.death_review',1,true));assert(not text:find('copy_budget',1,true))
end)
Test('text pages preserve Chinese newlines slashes and literal marker strings',function()
 local S=Boot();Ready(S);local T=S.ReportCopyTransport;local text=('故障\r\n路径\\test | RS-ERROR-PAGE-END; \n'):rep(260)
 local session,err=T:BuildTextPages(text,3500,'7.9');assert(session,err);assert(session.parts>1)
 local values={};for i=1,session.parts do local page=assert(T:GetTextPage(session,i));assert(#page<=3500 and not page:find('[\r\n]'));values[#values+1]=Data(page)end
 assert(Unescape(table.concat(values))==text)
 assert(T:GetTextPage(session,0)==nil and T:GetTextPage(session,session.parts+1)==nil)
end)
Test('previous next reuse a frozen snapshot and do not read or check again',function()
 local S,D,c,r,h=Boot();assert(h.widgets.v3_diag_output_full.onClick());assert(r.selfCheckDelivery.parts>1)
 local first=h.edit.text;local original=r.selfCheckText;local check,read=c.checks,c.reads
 S.RecordLog('error','later','ERROR_AFTER_CAPTURE')
 assert(h.widgets.v3_diag_report_next.onClick());assert(r.selfCheckPart==2 and h.edit.text~=first)
 assert(h.widgets.v3_diag_report_prev.onClick());assert(r.selfCheckPart==1 and h.edit.text==first)
 assert(r.selfCheckText==original and not original:find('ERROR_AFTER_CAPTURE',1,true))
 assert(c.checks==check and c.reads==read and c.writes==0 and c.chats==1)
end)
Test('print generates a new snapshot on page one instead of secretly moving next',function()
 local S,D,c,r,h=Boot();assert(h.widgets.v3_diag_output_full.onClick());local id=r.selfCheckMeta.id
 assert(h.widgets.v3_diag_report_next.onClick());S.RecordLog('error','test','NEXT_SNAPSHOT_ERROR')
 assert(h.widgets.v3_diag_output_full.onClick());assert(r.selfCheckPart==1 and r.selfCheckMeta.id~=id)
 assert(r.selfCheckText:find('NEXT_SNAPSHOT_ERROR',1,true) and c.checks==2 and c.reads==4)
end)
Test('small receiver negotiates once then all pages keep identical boundaries',function()
 local S,D,c,r,h=Boot(1800);assert(h.widgets.v3_diag_output_full.onClick());assert(r.selfCheckDelivery.capacity<=1800)
 local n=r.selfCheckDelivery.parts;local all={Data(h.edit.text)};local original=r.selfCheckText
 for i=2,n do assert(h.widgets.v3_diag_report_next.onClick());assert(r.selfCheckPart==i and r.selfCheckDelivery.parts==n);all[#all+1]=Data(h.edit.text)end
 assert(Unescape(table.concat(all))==original and c.reads==2 and c.checks==1)
 assert(h.widgets.v3_diag_report_next.onClick()==false and r.selfCheckPart==n,'must not wrap at last page')
end)
Test('navigation failure never advances page or regenerates boundaries',function()
 local S,D,c,r,h=Boot();assert(h.widgets.v3_diag_output_full.onClick());local session=r.selfCheckDelivery
 function h.edit:SetText(v)self.text=v:sub(1,90)end
 assert(h.widgets.v3_diag_report_next.onClick()==false);assert(r.selfCheckPart==1 and r.selfCheckDelivery==session)
 assert(c.checks==1 and c.reads==2)
end)
Test('run and page release discard text but retain captured errors',function()
 local S,D,c,r,h=Boot();S.RecordLog('error','test','KEPT_AFTER_CHECK');assert(h.widgets.v3_diag_output_full.onClick())
 assert(h.widgets.v3_diag_full_check.onClick());assert(r.selfCheckText==nil and r.selfCheckDelivery==nil)
 assert(h.widgets.v3_diag_output_full.onClick());assert(r.selfCheckText:find('KEPT_AFTER_CHECK',1,true));r:OnDeactivated()
 assert(r.selfCheckText==nil and r.selfCheckDelivery==nil and h.edit.text=='')
end)
Test('error capture has a bounded string snapshot independent of info eviction',function()
 local S,D=Boot();S.RecordLog('error','test','START'..('x'):rep(5000)..'END_OF_ERROR')
 for i=1,250 do S.RecordLog('info','healthy','not a failure')end
 local t,m=D:BuildPagedSelfCheckReport();assert(t,m);assert(t:find('END_OF_ERROR',1,true))
end)
Test('same-process addon reload starts a new generation and captures new failures',function()
 local S,D,c,r,h=Boot();S.RecordLog('error','old','OLD_GENERATION_ONLY');local generation=S.Generation
 dofile('replicatedsuite.lua') -- actual bootstrap keeps the VM and increments Generation
 assert(S.Generation==generation+1)
 S.RecordLog('error','boot','NEW_EARLY_FAILURE')
 dofile('core/rs_diagnostics.lua') -- actual reload also reloads the dependencies before this module
 dofile('core/rs_self_check_report.lua')
 local snapshot=S.DiagnosticsManager:GetSelfCheckIssueSnapshot()
 assert(#snapshot.rows==1 and snapshot.rows[1].message=='NEW_EARLY_FAILURE')
 S.RecordLog('error','new','NEW_RUNTIME_FAILURE');assert(#S.DiagnosticsManager:GetSelfCheckIssueSnapshot().rows==2)
end)
Test('safety limits do not truncate pages or accept an invalid index',function()
 local S=Boot();local T=S.ReportCopyTransport
 for _,cap in ipairs({0,20,0/0,math.huge})do assert(T:BuildTextPages('report',cap,'1.1')==nil)end
 local text=('\\'):rep(1048576);local session=assert(T:BuildTextPages(text,512,('a'):rep(48)))
 assert(session.parts==8192)
 assert(#assert(T:GetTextPage(session,1))<=512 and #assert(T:GetTextPage(session,8192))<=512)
 assert(T:BuildTextPages(text..'x',512,'1.1')==nil)
end)
print('REPORT PAGING RESULT '..passed..' passed / '..failed..' failed ('.._VERSION..')')
if failed>0 then error('report paging regressions failed')end

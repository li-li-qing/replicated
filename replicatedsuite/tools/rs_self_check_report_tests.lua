-- 维护：真实 Diagnostics/Bootstrap/API/Page 工厂；仅替换 Native 和外部快照提供者。
-- 不进 TOC。不能据此声称 RU 聊天/剪贴板/布局实机通过，也不生成用户实档恢复结论。
-- 维护：旧测试以SetClipboardText可用为前提，与参考Available/not allowed矛盾；
-- 现在即使测试Native提供同名函数也必须零调用，正文交付以页面回读为准。
local passed, failed = 0, 0
local function Test(name, run)
    local ok,err=pcall(run)
    if ok then passed=passed+1;print('PASS '..name) else failed=failed+1;print('FAIL '..name..': '..tostring(err)) end
end
local function Copy(t) if type(t)~='table' then return t end;local o={};for k,v in pairs(t)do o[k]=Copy(v)end;return o end
local function Boot(options)
    options=options or {}; ReplicatedSuite={}; X2Chat=nil; CMF_SYSTEM=0
    local io={chat={},copies={},reads={},checks=0,writes=0}
    ADDON={ChatLog=function(_,v)io.chat[#io.chat+1]=v;return true end,
        SetClipboardText=function(_,v)io.copies[#io.copies+1]=v;return nil end}
    dofile('replicatedsuite.lua');local S=ReplicatedSuite;S.RSUI={};S.UI={}
    dofile('core/rs_utils.lua');dofile('core/rs_reuse.lua');dofile('core/rs_api.lua');dofile('core/rs_api_capabilities.lua')
    if options.early then S.RecordLog('error','bootstrap','EARLY_BOOT_FAILURE') end
    dofile('core/rs_diagnostics.lua');dofile('core/rs_report_copy_transport.lua')
    local load=loadfile('core/rs_self_check_report.lua');if load then load() end
    local D=S.DiagnosticsManager
    S.BuildTag='v3-m1.16.0.18.208-test';S.Ready=true
    S.FoundationGate={Run=function(self,opt)
        assert(opt.skipSequences==true,'report ran mutation sequences');io.checks=io.checks+1
        local r={status='BLOCKED',blockers=2,warnings=2,checks={
            {id='CURRENT_BLOCKER',ok=false,severity='blocker',detail='ORIGINAL_FULL_REASON'},
            {id='CURRENT_WARNING',ok=false,severity='warning',detail='warning detail'},
            {id='passed',ok=true,severity='blocker',detail='fine'}}}
        self.last=r;return r
    end}
    local ids={'v3.buff_display','v3.death_review','v3.life.trade'}
    S.Persistence={stores={},Describe=function(self)
        local rows={};for _,id in ipairs(ids)do rows[#rows+1]=Copy(self.stores[id])end
        return {total=3,fenced=3,rows=rows,stats={integrityFailures=3}}
    end,BuildRuntimeAcceptanceSnapshot=function()return {fenced=3,ALL='723A8CEB'}end,
    BuildFailedStoreEvidenceText=function(self,id)
        io.reads[id]=(io.reads[id]or 0)+1
        return 'RS-PERSIST-EVIDENCE-1\nSTORE_TEST='..id..'\n'..string.rep('SAMPLE ',100)..'\nRS-PERSIST-EVIDENCE-END'
    end}
    for i,id in ipairs(ids)do S.Persistence.stores[id]={id=id,writeFenced=true,schemaVersion=i,loadStatus='integrity_failed',
        lastError='fingerprint_mismatch:12345678>87654321',lastIntegrityMismatchEvidence={stampedFingerprint='12345678',actualFingerprint='87654321'},
        lastHistoricalRecoveryProbe='schema/sequence=unchanged',lastIntegrityRecoveryTrace='FULL_TRACE_'..id}end
    S.Runtime={Describe=function()return {startupWarnings={{stage='feature_defaults',detail='STARTUP_PROBLEM'}}}end}
    S.UIV3=S.UIV3 or {};S.UIV3.PageHost={Describe=function()return {lastError='OLD_PAGE_ERROR'}end}
    S.ActionRunner={GetSnapshot=function()return {lastError='OLD_ACTION_ERROR',failed=2}end}
    D.BuildPopupPositioningReport=function()return 'POPUP_EVIDENCE' end
    D.BuildBuffHudReport=function()return 'HUD_EVIDENCE' end
    D.BuildFeatureStatusRows=function()return {{id='unit_lines',label='单位连线',verdict='degraded',text='FEATURE_FAILURE'}}end
    return S,D,io
end
local function Ready(D) assert(type(D.RunSelfCheck)=='function','RunSelfCheck missing');assert(type(D.BuildSelfCheckReport)=='function','unified report missing')end
local function Page(S)
    local h=dofile('tools/rs_status_ui_test_host.lua')(S)
    S.UIV3.WidgetHost.Describe=function()return {}end
    S.UIV3Design.PageRoot=function(_,parent,spec)return h.Node(type(spec)=="table" and spec or {id=spec})end
    S.UI.EnsureVisible=function(_,edit,value)edit:Show(value);return true,false end
    S.UIV3Design.ScrollablePageRoot=function(_,parent,spec)return h.Node(type(spec)=="table" and spec or {id=spec})end
    S.UIV3Design.InfoCard=function(_,parent,spec)local n=h.Node(spec);function n:SetData(data)self.data=data end;return n end
    S.UIV3Design.StatusRow=function(_,parent,id)local n=h.Node({id=id});n.valueText=h.Node({});return n end
    S.UI.DeactivateInputWidget=function() h.deactivations=(h.deactivations or 0)+1;return true end
    S.ActionRunner.Run=function(_,spec)return spec.execute()end
    dofile('presentation/v3/pages/rs_v3_foundation_pages.lua')
    local root=assert(S.UIV3.PageHost.factories['system.diagnostics'](nil,'system.diagnostics'))
    return root,h
end
Test('diagnostics has run print and explicitly requested previous next actions',function()
    local S,D=Boot();local root,h=Page(S);local buttons={}
    for _,v in pairs(h.widgets)do if v.onClick then buttons[#buttons+1]=v.spec.text end end
    table.sort(buttons);assert(#buttons==4,'visible action count='..#buttons)
    assert(h.widgets.v3_diag_output.spec.text=='打印自检报告' and h.widgets.v3_diag_full_check.spec.text=='运行自检')
    assert(h.widgets.v3_diag_report_prev.spec.text=='上一页' and h.widgets.v3_diag_report_next.spec.text=='下一页')
end)
Test('opening and activating diagnostics does not run checks read disk or copy',function()
    local S,D,io=Boot();local root,h=Page(S);root:OnActivated();assert(io.checks==0,'page auto-ran check')
    assert(next(io.reads)==nil and #io.copies==0 and #io.chat==0)
end)
Test('run selfcheck is one read-only gate pass without raw reads or chat',function()
    local S,D,io=Boot();Ready(D);local r=assert(D:RunSelfCheck())
    assert(r.blockers==2 and io.checks==1);assert(next(io.reads)==nil and #io.chat==0 and #io.copies==0)
end)
Test('unified report includes all failures previous errors and specialist reports',function()
    local S,D,io=Boot();Ready(D);S.RecordLog('error','gear','OLD_GEAR_FAILURE')
    local text,meta=D:BuildSelfCheckReport();assert(text,meta)
    for _,word in ipairs({'CURRENT_BLOCKER','ORIGINAL_FULL_REASON','CURRENT_WARNING','OLD_GEAR_FAILURE','STARTUP_PROBLEM',
        'OLD_PAGE_ERROR','OLD_ACTION_ERROR','POPUP_EVIDENCE','HUD_EVIDENCE','FEATURE_FAILURE','v3.buff_display','v3.death_review','v3.life.trade'})do
        assert(text:find(word,1,true),'missing '..word)
    end
    assert(text:sub(1,#'RS-SELF-CHECK-1\n')=='RS-SELF-CHECK-1\n' and text:find('RS-SELF-CHECK-END',1,true))
    assert(io.checks==1 and #io.chat==0 and #io.copies==0)
end)
Test('one print builds one snapshot reads each fenced store once returns identical text without non-allowed clipboard calls',function()
    local S,D,io=Boot();Ready(D);assert(type(D.PrintSelfCheckReport)=='function')
    local ok,text,meta=D:PrintSelfCheckReport();assert(ok,text);assert(type(text)=='string')
    assert(io.checks==1 and #io.copies==0 and #io.chat==1)
    for id,n in pairs(io.reads)do assert(n==1,id)end
    assert(io.reads['v3.life.trade']==1 and meta.clipboard=='manual')
    assert(#io.chat[1]<400 and io.chat[1]:find('RS%-CHECK%-3'))
    assert(S.Persistence.stores['v3.life.trade'].writeFenced==true)
end)
Test('early errors and earlier failures survive informational log eviction',function()
    local S,D=Boot({early=true});Ready(D);S.RecordLog('error','scheduler','EARLIER_TASK_ERROR')
    for i=1,350 do S.RecordLog('info','test','harmless '..i)end
    local text=assert(D:BuildSelfCheckReport());assert(text:find('EARLIER_TASK_ERROR',1,true));assert(text:find('EARLY_BOOT_FAILURE',1,true))
    assert(text:find('logDropped=152',1,true),'log coverage loss not disclosed')
end)
Test('repeating the same failure aggregates instead of growing history',function()
    local S,D=Boot();Ready(D)
    for i=1,1000 do S.RecordLog('error','loop','SAME_FAULT') end
    local data=assert(D:GetSelfCheckIssueSnapshot());assert(#data.rows==1 and data.rows[1].count==1000)
end)
Test('error history is bounded and eviction is explicitly reported',function()
    local S,D=Boot();Ready(D)
    for i=1,150 do S.RecordLog('error','loop','different '..i) end
    local data=D:GetSelfCheckIssueSnapshot();assert(#data.rows<=80 and data.evicted>0)
    local text=assert(D:BuildSelfCheckReport());assert(text:find('issueEvicted=',1,true))
end)
Test('run check does not clear previous failure history',function()
    local S,D=Boot();Ready(D);D:Error('module','ERR','BEFORE_CHECK');D:RunSelfCheck();D:RunSelfCheck()
    assert(assert(D:BuildSelfCheckReport()):find('BEFORE_CHECK',1,true))
end)
Test('throwing check is reported without recycling an older READY verdict',function()
    local S,D=Boot();Ready(D);S.FoundationGate.last={status='READY',blockers=0,warnings=0}
    S.FoundationGate.Run=function()error('GATE_EXPLODED')end
    local text,meta=D:BuildSelfCheckReport();assert(text,meta);assert(meta.check.status=='ERROR');assert(text:find('GATE_EXPLODED',1,true))
end)
Test('one faulty diagnostic provider cannot erase other sections or raw evidence',function()
    local S,D,io=Boot();Ready(D);S.UIV3.PageHost.Describe=function()error('PAGE_SNAPSHOT_THROW')end
    local text,meta=D:BuildSelfCheckReport();assert(text,meta)
    assert(text:find('PAGE_SNAPSHOT_THROW',1,true)and text:find('HUD_EVIDENCE',1,true))
    assert(io.reads['v3.life.trade']==1 and meta.partial==true)
end)
Test('one failed raw store remains identified while other stores are collected',function()
    local S,D,io=Boot();Ready(D);local fn=S.Persistence.BuildFailedStoreEvidenceText
    S.Persistence.BuildFailedStoreEvidenceText=function(self,id)if id=='v3.death_review'then error('READ_FAILED')end;return fn(self,id)end
    local text,meta=D:BuildSelfCheckReport();assert(text:find('READ_FAILED',1,true));assert(meta.partial)
    assert(io.reads['v3.life.trade']==1 and io.reads['v3.buff_display']==1)
end)
Test('clipboard unavailable keeps whole report and reports fallback without retry',function()
    local S,D,io=Boot();Ready(D);ADDON.SetClipboardText=nil
    local ok,text,meta=D:PrintSelfCheckReport();assert(ok and #text>1000 and meta.clipboard=='manual')
    assert(#io.copies==0 and #io.chat==1)
end)
Test('non-allowed clipboard function returning false is never invoked',function()
    local S,D,io=Boot();Ready(D);ADDON.SetClipboardText=function(_,v)io.copies[#io.copies+1]=v;return false end
    local ok,text,meta=D:PrintSelfCheckReport();assert(ok and meta.clipboard=='manual');assert(#io.copies==0 and #io.chat==1)
end)
Test('non-allowed throwing clipboard function is never invoked and report remains available',function()
    local S,D,io=Boot();Ready(D);ADDON.SetClipboardText=function()error('COPY_FAILED')end
    local ok,text,meta=D:PrintSelfCheckReport();assert(ok and meta.clipboard=='manual' and type(text)=='string');assert(#io.chat==1)
end)
Test('printing twice does not nest earlier report payload or repeat previous raw data',function()
    local S,D,io=Boot();Ready(D);local ok,first=D:PrintSelfCheckReport();local ok2,text=D:PrintSelfCheckReport();assert(ok and ok2)
    local _,n=text:gsub('RS%-SELF%-CHECK%-1\n','');assert(n==1,'nested report')
    assert(#text<#first+1500 and io.reads['v3.life.trade']==2)
end)
Test('missing backend disables page operation with an explicit error rather than nil failure',function()
    local S,D=Boot();local root,h=Page(S);S.DiagnosticsManager=nil
    local btn=h.widgets.v3_diag_output;local ok,err=btn.onClick();assert(ok==false and type(err)=='string')
end)
Test('default print populates page one without discarding fenced originals',function()
    local S,D,io=Boot();Ready(D);local root,h=Page(S)
    assert(h.widgets.v3_diag_output.onClick());assert(h.edit and h.edit.text==S.ReportCopyTransport:GetTextPage(root.selfCheckDelivery,1) and #io.copies==0)
    -- 维护：新默认先收集全部失败原档，再分页；此处防止倒退为copy_budget丢原档。
    local count=0;for _,n in pairs(io.reads)do count=count+n end
    assert(#io.chat==1 and count==3 and root.selfCheckMeta.kind=='paged')
end)
Test('hiding page clears editor and releases focus without reading another snapshot',function()
    local S,D,io=Boot();Ready(D);local root,h=Page(S);assert(h.widgets.v3_diag_output.onClick())
    root:OnDeactivated();assert(h.edit.text==''and h.deactivations==1)
    local count=0;for _,n in pairs(io.reads)do count=count+n end
    assert(count==3 and #io.copies==0)
end)
Test('native editor truncation is explicitly surfaced and not passed off as complete',function()
    local S,D,io=Boot();Ready(D);local root,h=Page(S)
    h.edit.SetText=function(self,text)self.text=text:sub(1,30)end
    h.widgets.v3_diag_output.onClick()
    -- 维护：不再根据短读猜根因，要求明确失败、真实读回长度，且仍不声称完整交付。
    assert(h.widgets.v3_diag_report_status.text:find('TEXT_READBACK',1,true),'UI failure hidden')
    assert(root.selfCheckMeta.presentation.readback.received==30 and root.selfCheckMeta.delivered==false)
    assert(root.selfCheckText and #root.selfCheckText>30 and #io.copies==0)
end)
Test('clipboard is explicitly denied by the reference section and cannot be a getter probe',function()
    local S,D=Boot();local c=S.ApiCapabilities:Get('ADDON:SetClipboardText')
    assert(c and c.OfficialState=='OfficialDisabled' and c.SideEffectFree~=true and c.Risk=='write','clipboard capability absent or incorrectly probeable')
end)
Test('inactive and healthy stores never get raw evidence reads',function()
    local S,D,io=Boot();Ready(D);for _,st in pairs(S.Persistence.stores)do st.writeFenced=false end
    assert(D:BuildSelfCheckReport());assert(next(io.reads)==nil)
end)
Test('raw evidence overflow refuses whole blocks instead of delivering corrupted exports',function()
    local S,D=Boot();Ready(D);S.Persistence.BuildFailedStoreEvidenceText=function()return string.rep('RAW_UNBOUNDED',100000)end
    local text,meta=D:BuildSelfCheckReport();assert(text and #text<=1048576 and meta.partial)
    assert(text:find('evidence_omitted',1,true))
end)
Test('cyclic diagnostic snapshots terminate with explicit coverage loss',function()
    local S,D=Boot();Ready(D);S.Runtime.Describe=function()local v={};v.self=v;return v end
    local text,meta=D:BuildSelfCheckReport();assert(text and meta.partial and text:find('cycle',1,true))
end)
Test('failed checks at the end of a large healthy checklist retain complete failure details',function()
    local S,D=Boot();Ready(D)
    S.FoundationGate.Run=function(self,opts)
        assert(opts.skipSequences)
        local r={status='BLOCKED',blockers=1,warnings=0,checks={}}
        for i=1,180 do r.checks[#r.checks+1]={id='passing_'..i,ok=true,severity='blocker',detail=string.rep('H',300)} end
        r.checks[#r.checks+1]={id='LAST_IMPORTANT_FAILURE',ok=false,severity='blocker',detail='LAST_REAL_REASON'}
        self.last=r;return r
    end
    local text=assert(D:BuildSelfCheckReport());assert(text:find('LAST_IMPORTANT_FAILURE',1,true) and text:find('LAST_REAL_REASON',1,true))
end)
Test('selfcheck exception is explicitly partial and not a B0 W0 passing receipt',function()
    local S,D,io=Boot();Ready(D);S.FoundationGate.Run=function()error('CHECK_BROKEN')end
    local ok,text,meta=D:PrintSelfCheckReport();assert(ok and meta.partial==true)
    assert(io.chat[1]:find('ERROR',1,true),'receipt disguised failed execution as a passing check')
end)
Test('warn once enters error history using existing warning semantics',function()
    local S,D=Boot();Ready(D);S.WarnOnce('test_warning','WARNING_FROM_NATIVE');S.WarnOnce('test_warning','WARNING_FROM_NATIVE')
    local h=D:GetSelfCheckIssueSnapshot();assert(#h.rows==1 and h.rows[1].level=='warning' and h.rows[1].count==1)
end)
Test('report cannot recursively rebuild itself while a collector is active',function()
    local S,D=Boot();Ready(D);S.Runtime.Describe=function()
        local text,why=D:BuildSelfCheckReport();assert(text==nil and why=='self_check_report_busy');return {nestedBlocked=true}
    end
    assert(D:BuildSelfCheckReport())
end)
Test('read-only report uses three real Store codecs without applying or saving and exports exact raw evidence',function()
    local S,D,io=Boot();Ready(D);S.Features={};S.Services={};S.UI.CreateWindowShell=function()error('must not create HUD')end
    S.FeatureRuntime={RegisterImplementation=function()return true end}
    local disk={};local loadCount,saveCount,clearCount,applyCount=0,0,0,0
    ADDON.LoadData=function(_,key)loadCount=loadCount+1;return Copy(disk[key])end
    ADDON.SaveData=function(_,key,value)saveCount=saveCount+1;disk[key]=Copy(value);return true end
    ADDON.ClearData=function()clearCount=clearCount+1;error('must not clear')end
    dofile('core/rs_demand.lua');dofile('core/rs_persistence.lua');dofile('ui/framework/rs_ui_floating_surface.lua')
    dofile('features/combat/buff_display/rs_buff_display_store.lua');dofile('features/combat/death_review/rs_death_review_store.lua')
    dofile('features/life/rs_life_m16_bundle.lua')
    local P=S.Persistence;local ids={'v3.buff_display','v3.death_review','v3.life.trade'}
    for _,id in ipairs(ids)do
        local st=assert(P:GetStore(id));assert(P:LoadStore(id));st.apply(st.default());assert(P:SaveStore(id,{force=true,verifyAfterSave=true}))
        local key=assert(P:ResolveStoreKey(st));local raw=assert(P:DecodePhysicalEnvelope(Copy(disk[key])))
        raw.__rsmeta.encodedFingerprint='00000000';raw.__rsmeta.envelopeFingerprint=assert(P:FingerprintEnvelopeIntegrity(raw))
        disk[key]=assert(P:EncodePhysicalEnvelope(raw))
        local ok=P:LoadStore(id,{discardDirty=true,discardUnverified=true,revalidateTerminal=true});assert(not ok and st.writeFenced)
        st.apply=function()applyCount=applyCount+1;error('report applied a store')end
    end
    local beforeLoads,beforeSaves=loadCount,saveCount
    local ok,text,meta=D:PrintSelfCheckReport();assert(ok,text);assert(meta.evidenceIncluded==3,'actual evidence not included')
    assert(loadCount-beforeLoads==3 and saveCount==beforeSaves and clearCount==0 and applyCount==0,'report mutated storage or reread raw')
    for _,id in ipairs(ids)do assert(P:GetStore(id).writeFenced) end
    local h=assert(_G.io.open('tools/.self_check_real_evidence.txt','wb'));h:write(text);h:close()
    -- 维护（9215实机容量回归）：上面的真实Store/Native门继续用于整页分段流程，不能
    -- 只验证纯编码器或假BuildReport。故障读入只在第一段发生，后续所有打印都零Save/Apply/Clear。
    -- 维护：默认公开流程即完整失败证据+显式翻页；使用真实BuildPaged，不替换报告生成器。
    local root,host=Page(S)
    function host.edit:MaxTextLength()return 9215 end
    function host.edit:SetText(value)self.text=value:sub(1,9215)end
    beforeLoads,beforeSaves=loadCount,saveCount
    assert(host.widgets.v3_diag_output.onClick())
    local session=assert(root.selfCheckDelivery);assert(session.parts>1,'real evidence fixture must exercise parts')
    local original=root.selfCheckText;local rows={host.edit.text}
    for i=2,session.parts do
        assert(host.widgets.v3_diag_report_next.onClick());rows[#rows+1]=host.edit.text
        assert(root.selfCheckPart==i and #host.edit.text<=9215 and root.selfCheckText==original)
    end
    assert(loadCount-beforeLoads==3 and saveCount==beforeSaves and clearCount==0 and applyCount==0,'part navigation touched Store IO')
    for _,id in ipairs(ids)do assert(P:GetStore(id).writeFenced) end
    h=assert(_G.io.open('tools/.copy_parts_real_flow.txt','wb'));h:write(table.concat(rows,'\n\n'));h:close()
    h=assert(_G.io.open('tools/.copy_parts_real_flow.bin','wb'));h:write(original);h:close()
    -- TEXT_READBACK：继续复用三个真实Store，但让Native声明9215、实际最多4096且删除LF。
    -- 这是联合故障注入，不是实际RU转换的断言。第一次协商和所有翻段都只读同一次快照。
    root:OnDeactivated()
    function host.edit:SetText(value)self.text=value:gsub('[\r\n]',''):sub(1,4096)end
    beforeLoads,beforeSaves=loadCount,saveCount
    assert(host.widgets.v3_diag_output.onClick())
    assert(root.selfCheckDelivery.wire=='error_pages1' and root.selfCheckDelivery.capacity<=4096)
    local flatRows={host.edit.text};local flatOriginal=root.selfCheckText
    for i=2,root.selfCheckDelivery.parts do
        assert(host.widgets.v3_diag_report_next.onClick());flatRows[i]=host.edit.text
        assert(root.selfCheckPart==i and #host.edit.text<=4096 and root.selfCheckText==flatOriginal)
    end
    assert(loadCount-beforeLoads==3 and saveCount==beforeSaves and clearCount==0 and applyCount==0)
    for _,id in ipairs(ids)do assert(P:GetStore(id).writeFenced) end
    h=assert(_G.io.open('tools/.copy_wire_real_flow.txt','wb'));h:write(table.concat(flatRows,'\n'));h:close()
    h=assert(_G.io.open('tools/.copy_wire_real_flow.bin','wb'));h:write(flatOriginal);h:close()

end)
Test('malformed UTF8 from an older truncated log is byte-escaped for clipboard transport',function()
    local S,D=Boot();Ready(D)
    S.RecordLog('error','old_native','broken:'..string.char(228,184)..' tail')
    local text=assert(D:BuildSelfCheckReport())
    assert(not text:find(string.char(228,184)..' tail',1,true),'invalid UTF8 leaked to Native clipboard')
    assert(text:find('\\xE4\\xB8',1,true),'original malformed bytes not explained')
end)
print('SELF CHECK RESULT '..passed..' passed / '..failed..' failed ('.._VERSION..'); Native simulated')
assert(failed==0,'self-check regression failures')

-- 维护：RS-FOCUS-1 兼容格式回归；真实Diagnostics/Core/Page，仅Native和外部诊断Getter模拟。
-- 页面默认必须使用完整的 paged fault report；Focused 仅保留旧工具兼容，不能再次成为用户默认输出。
-- 测试不进TOC，不清除业务Fence，不可将合成Native容量/档案当作RU实机验证。
local passed,failed=0,0
local function Test(name,fn)
    local ok,err=pcall(fn)
    if ok then passed=passed+1;print('PASS focus '..name) else failed=failed+1;print('FAIL focus '..name..': '..tostring(err)) end
end
local function Copy(v) if type(v)~='table' then return v end;local r={};for k,x in pairs(v) do r[k]=Copy(x) end;return r end
local function Boot(real)
    local calls={chats={},reads={},writes=0,checks=0,heavy=0}
    ADDON={ChatLog=function(_,text)calls.chats[#calls.chats+1]=text;return true end};X2Chat=nil;CMF_SYSTEM=0
    ReplicatedSuite={};dofile('replicatedsuite.lua');local S=ReplicatedSuite;S.RSUI={};S.UI={}
    dofile('core/rs_utils.lua');dofile('core/rs_reuse.lua');dofile('core/rs_api.lua');dofile('core/rs_api_capabilities.lua')
    dofile('core/rs_diagnostics.lua');dofile('core/rs_report_copy_transport.lua');dofile('core/rs_self_check_report.lua')
    local D=S.DiagnosticsManager;S.BuildTag='v3-m1.16.0.18.208-target-gear-score-api-default-template';S.Ready=true
    local sourceRows={
        {id='runtime_startup_degradation',ok=false,severity='warning',detail=('degraded=true/first=feature_defaults:combat_buff_display:integrity_failed:'):rep(15)},
        {id='persistence_v2',ok=false,severity='blocker',detail='stores=40/fenced=3'},
        {id='persistence_reliability_v4',ok=false,severity='blocker',detail='integrityFail=3/flushFail=0'},
        {id='persistence_reliability_incidents',ok=false,severity='warning',detail='integrityFail=3/flushFail=0'}}
    S.FoundationGate={Run=function(self,opt)assert(opt.skipSequences);calls.checks=calls.checks+1
        self.last={status='BLOCKED',blockers=2,warnings=2,checks=Copy(sourceRows)};return self.last end}
    local function Heavy() calls.heavy=calls.heavy+1;error('healthy/full diagnostic getter must not run') end
    S.Runtime={Describe=Heavy};S.ActionRunner={GetSnapshot=Heavy};D.BuildBuffHudReport=Heavy;D.BuildPopupPositioningReport=Heavy
    S.Persistence={stores={},Describe=Heavy}
    local rows={
        {'v3.buff_display',5,6,'1E7F5813','6307A930','6623AE99',nil,'candidate',1000},
        {'v3.death_review',2,2,'695423CD','3B54171E','3B54171E',1,'no_candidate',2000},
        {'v3.life.trade',1,1,'6BE9E557','48B0E072','48B0E072',nil,'not_registered',200}}
    for _,r in ipairs(rows) do
        S.Persistence.stores[r[1]]={id=r[1],writeFenced=true,schemaVersion=r[3],loadStatus='integrity_failed',
            encodedBudget={maxNodes=r[9]},lastHistoricalRecoveryHookState=r[8],lastHistoricalRecoveryProbe='schema/sequence=unchanged',
            lastIntegrityMismatchEvidence={storedSchema=r[2],currentSchema=r[3],framework=3,transportVersion=2,codec=r[7],
                stampedFingerprint=r[4],actualFingerprint=r[5],rawFingerprint=r[6]}}
        S.RecordLog('error','persistence','[STORE_INTEGRITY_FAILED] 校验失败 {store='..r[1]..', error='..r[4]..'>'..r[5]..'}')
    end
    S.RecordLog('error','gear','[EQUIP_MISSING] weapon_slot=main_hand')
    S.Persistence.BuildFailedStoreEvidenceText=function(_,id,options)
        calls.reads[#calls.reads+1]=id;assert(options and options.compact==true,'must request compact outer envelope')
        return 'RS-PERSIST-EVIDENCE-1\nBYTES=0\nCHECK=00000000\nT0{}\nRS-PERSIST-EVIDENCE-END'
    end
    if real then
        S.Features={};S.Services={};S.UI.CreateWindowShell=function()error('do not create HUD')end
        S.FeatureRuntime={RegisterImplementation=function()return true end}
        local disk={}
        ADDON.LoadData=function(_,key)calls.reads[#calls.reads+1]=key;return Copy(disk[key])end
        ADDON.SaveData=function(_,key,value)calls.writes=calls.writes+1;disk[key]=Copy(value);return true end
        ADDON.ClearData=function()error('must not clear')end
        dofile('core/rs_demand.lua');dofile('core/rs_persistence.lua');dofile('ui/framework/rs_ui_floating_surface.lua')
        dofile('features/combat/buff_display/rs_buff_display_store.lua');dofile('features/combat/death_review/rs_death_review_store.lua')
        dofile('features/life/rs_life_m16_bundle.lua')
        local P=S.Persistence
        for _,r in ipairs(rows) do
            local st=P:GetStore(r[1]);assert(P:LoadStore(r[1]));st.apply(st.default());assert(P:SaveStore(r[1],{force=true,verifyAfterSave=true}))
            local key=P:ResolveStoreKey(st);local raw=assert(P:DecodePhysicalEnvelope(Copy(disk[key])))
            raw.__rsmeta.encodedFingerprint='00000000';raw.__rsmeta.envelopeFingerprint=assert(P:FingerprintEnvelopeIntegrity(raw))
            disk[key]=assert(P:EncodePhysicalEnvelope(raw))
            local ok=P:LoadStore(r[1],{discardDirty=true,discardUnverified=true,revalidateTerminal=true});assert(not ok and st.writeFenced)
            st.apply=function()error('must not apply')end
        end
        calls.disk=disk;calls.reads={};calls.writes=0
        S.RecordLog('error','gear','[EQUIP_MISSING] weapon_slot=main_hand')
    end
    return S,D,calls
end
local function Focus(D) assert(type(D.BuildFocusedSelfCheckReport)=='function','focused report API missing');return D:BuildFocusedSelfCheckReport() end
local function Page(S,calls,cap)
    local h=dofile('tools/rs_status_ui_test_host.lua')(S)
    S.UIV3Design.PageRoot=function(_,_,spec)return h.Node(spec)end
    S.UIV3Design.InfoCard=function(_,_,spec)local n=h.Node(spec);function n:SetData(v)self.data=v end;return n end
    S.UI.EnsureVisible=function(_,e,v)e:Show(v);return true end
    S.UI.ActivateInputWidget=function()return true end
    S.UI.DeactivateInputWidget=function()return true end
    S.ActionRunner={Run=function(_,spec)return spec.execute()end}
    dofile('presentation/v3/pages/rs_v3_foundation_pages.lua')
    local root=assert(S.UIV3.PageHost.factories['system.diagnostics'](nil,'system.diagnostics'))
    function h.edit:MaxTextLength()return cap or 9215 end
    function h.edit:SetText(v)self.text=v:gsub('[\r\n]',''):sub(1,cap or 4096)end
    return root,h
end
Test('transport decode failure includes physical repair probe in focused store row',function()
    local S,D=Boot();local st=S.Persistence.stores['v3.buff_display']
    st.lastIntegrityMismatchEvidence={}
    st.lastError='transport_decode_failed:transport_vector_missing_chunk_v4'
    st.lastPhysicalTransportRepairProbe=nil
    st.lastPhysicalTransportRepairError='catalog_repair_failed:catalog_count:player.auto:397/401'
    local text=assert(Focus(D))
    assert(text:find('phy=catalog_repair_failed:catalog_count:player.auto:397/401',1,true),'physical repair evidence missing')
end)

Test('successful physical repair probe remains visible when later fingerprint gate blocks the store',function()
    local S,D=Boot();local st=S.Persistence.stores['v3.buff_display']
    st.lastIntegrityMismatchEvidence={storedSchema=8,stampedFingerprint='2FBF9352',actualFingerprint='0EBC870A',rawFingerprint='4FF5DE1D',framework=3,transportVersion=4}
    st.lastError='integrity_failed:fingerprint_mismatch:2FBF9352>0EBC870A'
    st.lastPhysicalTransportRepairOk=true
    st.lastPhysicalTransportRepairProbe='schema8_v4/repairs=6/twin:player.auto/primaryfp=0EBC870A/fallback=catalog_no_candidate:player.auto'
    st.lastPhysicalTransportRepairError=nil
    local text=assert(Focus(D))
    assert(text:find('phy=schema8_v4/repairs=6/twin:player.auto',1,true),'successful physical repair probe hidden after later fingerprint rejection: '..text)
    assert(text:find('fallback=catalog_no_candidate:player.auto',1,true),'fallback evidence missing after later fingerprint rejection: '..text)
end)

Test('focused transport row keeps extended physical recovery evidence for one failed store',function()
    local S,D=Boot();local st=S.Persistence.stores['v3.buff_display']
    st.lastIntegrityMismatchEvidence={}
    st.lastError='transport_decode_failed:transport_vector_missing_chunk_v4'
    st.lastPhysicalTransportRepairProbe=nil
    st.lastPhysicalTransportRepairError='catalog_no_candidate:player.auto|bucket=player.auto/count=393/missing=p25/sameCount=pack:all/mis=p1/disk='..('12345,'):rep(80)..'TRACE_TAIL'
    local text=assert(Focus(D))
    assert(text:find('bucket=player.auto',1,true),'extended physical evidence missing')
    assert(text:find('TRACE_TAIL',1,true),'physical evidence still clipped to the old tiny budget')
    assert(#text<=3500,'focused report exceeded editor page budget')
end)

Test('focused transport row keeps deep two-scope audit beyond old 1500-byte clip',function()
    local S,D=Boot();local st=S.Persistence.stores['v3.buff_display']
    st.lastIntegrityMismatchEvidence={}
    st.lastError='transport_decode_failed:transport_vector_missing_chunk_v4'
    st.lastPhysicalTransportRepairProbe=nil
    st.lastPhysicalTransportRepairError='Pauto=c393/p25/m=1,2,3,4,19/b=5:count10/16/'..('x'):rep(1650)..'/DEEP_TAIL'
    local text=assert(Focus(D))
    assert(text:find('Pauto=c393',1,true),'deep player audit missing')
    assert(text:find('DEEP_TAIL',1,true),'deep physical audit clipped at the old 1500-byte ceiling')
    assert(#text<=3500,'focused report exceeded editor page budget')
end)

Test('default builder keeps three exact store fingerprint groups and is one bounded line',function()
    local S,D,c=Boot();local text,m=Focus(D);assert(text,m)
    assert(text:find('RS-FOCUS-1',1,true)==1 and text:find('RS-FOCUS-END',1,true))
    assert(#text<=3500 and not text:find('[\r\n]'))
    for _,v in ipairs({'v3.buff_display','1E7F5813>6307A930','6623AE99','v3.death_review','695423CD>3B54171E','v3.life.trade','6BE9E557>48B0E072','EQUIP_MISSING'}) do
        assert(text:find(v,1,true),'missing '..v)
    end
    assert(m.kind=='focused' and c.heavy==0 and c.checks==1 and #c.chats==0)
end)
Test('focused path never constructs the full report or healthy snapshots',function()
    local S,D,c=Boot();D.BuildSelfCheckReport=function()error('full report must not be built')end
    for i=1,200 do S.Persistence.stores['healthy.'..i]={id='healthy.'..i,writeFenced=false} end
    local text,m=Focus(D);assert(text,m);assert(c.heavy==0 and #c.reads==1 and c.reads[1]=='v3.life.trade')
    assert(not text:find('healthy.',1,true) and not text:find('[PERSISTENCE]',1,true))
end)
Test('history repeats aggregate and budget omissions are disclosed',function()
    local S,D,c=Boot();for i=1,1000 do S.RecordLog('error','scheduler','[TASK_FAILURE] kept_task_reason')end
    local text=assert(Focus(D));assert(text:find('TASK_FAILURE',1,true) and text:find('x1000',1,true))
    for i=1,100 do S.RecordLog('error','module_'..i,'different '..i..('q'):rep(800))end
    local many,m=Focus(D);assert(#many<=3500 and m.historyOmitted>0 and m.historyEvicted>0)
    assert(many:find('historyOmit=',1,true) and many:find('evicted=',1,true) and many:find('RS-FOCUS-END',1,true))
end)
Test('oversized native evidence is explicitly omitted whole without multipart',function()
    local S,D,c=Boot();S.Persistence.BuildFailedStoreEvidenceText=function(_,id,opt)c.reads[#c.reads+1]=id;return ('x'):rep(50000)end
    local text,m=Focus(D);assert(text,m);assert(#text<=3500 and m.evidenceIncluded==0 and m.evidenceOmitted==3)
    assert(text:find('raw_size_limit',1,true) and not text:find('RS-REPORT-PART',1,true) and #c.reads==1)
end)
Test('read failures do not erase the cached three fault summaries',function()
    local S,D,c=Boot();S.Persistence.BuildFailedStoreEvidenceText=function()error('scope failure')end
    local text,m=Focus(D);assert(text,m);assert(m.evidenceFailed==1)
    assert(text:find('scope failure',1,true) and text:find('6BE9E557>48B0E072',1,true))
end)
Test('gate error remains ERROR and focused collection stays available',function()
    local S,D=Boot();S.FoundationGate.Run=function()error('check_exception')end
    local text,m=Focus(D);assert(text,m);assert(m.check.status=='ERROR' and text:find('check_exception',1,true))
end)
Test('many fences report omissions and never output half a fingerprint',function()
    local S,D=Boot();for i=1,80 do local st=Copy(S.Persistence.stores['v3.life.trade']);st.id='z_extra_'..i;S.Persistence.stores[st.id]=st end
    local text,m=Focus(D);assert(text,m);assert(#text<=3500 and m.storesOmitted>0 and text:find('storeOmit=',1,true))
    for left,right in text:gmatch('fp=([^ ]+)>([^ ]+)') do assert(#left==8 and #right==8) end
end)
Test('default page prints complete paged faults while focused format stays compatibility-only',function()
    local S,D,c=Boot();local root,h=Page(S,c)
    local buttons=0;for _,w in pairs(h.widgets) do if w.onClick then buttons=buttons+1 end end;assert(buttons==5)
    assert(h.widgets.v3_diag_output.onClick());assert(root.selfCheckMeta.kind=='paged','default print must be paged')
    assert(root.selfCheckDelivery.parts>=1 and h.edit.text:find('RS-ERROR-PAGE-END',1,true))
    assert(root.selfCheckText:find('RS-SELF-CHECK-1',1,true) and not root.selfCheckText:find('RS-FOCUS-1',1,true))
    assert(#c.chats==1 and #c.reads==3)
    assert(h.widgets.v3_diag_output_full and type(h.widgets.v3_diag_output_full.onClick)=='function')
end)
Test('printing default paged report twice makes a fresh snapshot rather than advancing',function()
    local S,D,c=Boot();local root,h=Page(S,c);assert(h.widgets.v3_diag_output.onClick());local id=root.selfCheckMeta.id
    assert(h.widgets.v3_diag_output.onClick());assert(root.selfCheckMeta.id~=id and root.selfCheckPart==1)
    assert(c.checks==2 and #c.reads==6 and #c.chats==2)
end)
Test('tiny editor rejects paged delivery rather than passing a partial frame',function()
    local S,D,c=Boot();local root,h=Page(S,c,100)
    assert(h.widgets.v3_diag_output.onClick()==false)
    assert(#c.chats==1)
    assert(root.selfCheckMeta and root.selfCheckMeta.kind=='paged')
end)
Test('paged fault report releases text on hide and run does not read stores',function()
    local S,D,c=Boot();local root,h=Page(S,c);assert(#c.reads==0);assert(h.widgets.v3_diag_output.onClick())
    root:OnDeactivated();assert(h.edit.text=='' and root.selfCheckText==nil)
    local reads=#c.reads;assert(h.widgets.v3_diag_full_check.onClick());assert(#c.reads==reads)
end)
Test('real store compact envelope preserves exact raw values and existing full envelope stays compatible',function()
    local S,D,c=Boot(true);local P=S.Persistence
    local compact=assert(P:BuildFailedStoreEvidenceText('v3.life.trade',{compact=true}))
    local full=assert(P:BuildFailedStoreEvidenceText('v3.life.trade'))
    assert(#compact<#full,'compact wrapper still repeats failure/key/build metadata')
    for name,value in pairs({compact=compact,full=full})do local f=assert(io.open('tools/.focus_evidence_'..name..'.txt','wb'));f:write(value);f:close()end
    assert(c.writes==0)
end)
-- 维护：Focused Builder 仅作为历史兼容入口保留；页面默认禁止依赖它。
Test('focused builder preserves its single trade sample for compatibility tools',function()
    local S,D,c=Boot(true);local before=#c.reads
    local text,meta=Focus(D);assert(text,meta)
    assert(meta.kind=='focused' and meta.evidenceIncluded==1 and meta.evidenceStore=='v3.life.trade')
    assert(#c.reads-before==1 and c.writes==0 and #text<=3500)
    for _,id in ipairs({'v3.buff_display','v3.death_review','v3.life.trade'})do assert(S.Persistence:GetStore(id).writeFenced)end
    local f=assert(io.open('tools/.focus_report.txt','wb'));f:write(text);f:close()
    local evidence=assert(S.Persistence:BuildFailedStoreEvidenceText('v3.life.trade',{compact=true}))
    f=assert(io.open('tools/.focus_report_expected_evidence.txt','wb'));f:write(evidence);f:close()
end)

Test('already-clipped logs and lost capture are disclosed rather than counted as full history',function()
    local S,D=Boot();S.RecordLog('error','old','ERROR:'..('中'):rep(10000));S.SelfCheckCaptureFailures=2
    local text,m=Focus(D);assert(text,m)
    assert(text:find('preclipped=1',1,true) and text:find('captureFail=2',1,true) and m.partial)
end)
Test('missing persistence is reported unavailable rather than healthy zero fences',function()
    local S,D=Boot();S.Persistence=nil
    local text,m=Focus(D);assert(text,m);assert(m.partial and m.providersFailed==1)
    assert(text:find('persistence_unavailable',1,true))
end)
Test('compact evidence still enforces a fenced Store and never reads a healthy Store',function()
    local S,D,c=Boot(true);local st=S.Persistence:GetStore('v3.life.trade');st.writeFenced=false
    local before=#c.reads;local text,err=S.Persistence:BuildFailedStoreEvidenceText(st.id,{compact=true})
    assert(text==nil and err=='store_not_fenced' and #c.reads==before and c.writes==0)
end)
Test('large failing-read context plus many errors fits budget without losing the footer',function()
    local S,D=Boot();S.Persistence.BuildFailedStoreEvidenceText=function()error(('读取失败中文'):rep(300))end
    for i=1,70 do S.RecordLog('error','long_source_'..i,('module traceback 内容 '..i):rep(50))end
    local text,m=Focus(D);assert(text,m);assert(#text<=3500 and text:find('RS-FOCUS-END',1,true) and m.historyOmitted>0)
end)
Test('building a focused report rejects recursive collection and releases guard after errors',function()
    local S,D=Boot();local old=D.BuildPersistenceEvidenceText
    D.BuildPersistenceEvidenceText=function(self,...)
        local nested,err=self:BuildFocusedSelfCheckReport();assert(nested==nil and err=='self_check_report_busy')
        return old(self,...)
    end
    assert(Focus(D));assert(Focus(D))
end)
Test('different healthy registry sizes do not increase printed report bytes',function()
    local S,D=Boot();local first=assert(Focus(D))
    for i=1,300 do S.Persistence.stores['healthy.'..i]={id='healthy.'..i,writeFenced=false}end
    local second=assert(Focus(D));assert(#second==#first)
end)
-- 维护：与现有聚焦报告回归共用真实Builder，不加载任何新的采集通道。
Test('copy-budget raw omission retains per-store numeric facts without a second Native read',function()
    local S,D,c=Boot();S.Persistence.stores['v3.life.trade']=nil
    S.Persistence.BuildFailedStoreEvidenceText=function(_,id)
        c.reads[#c.reads+1]=id
        local out={};for i=1,4500 do out[i]=string.char(33+(i*17+math.floor(i/93))%90)end
        -- 非完整原档不能被假装可附带；本测试确保进入整体超限/省略路径。
        return table.concat(out)..('x'):rep(18000)
    end
    for _,id in ipairs({'v3.buff_display','v3.death_review'})do
        S.Persistence.stores[id].lastWindowNumericEvidence={status='no_match',attempts=18,matches=0,
            fields={normalizedCenterX={raw='0.07412400096654892',canonical='0.07412400096654892',token='0.074124',reason='tested'},
                normalizedCenterY={raw='0.086456000804901123',canonical='0.086456000804901123',token='0.086456',reason='tested'}}}
    end
    local text,m=Focus(D);assert(text,m)
    assert(m.numericEvidenceIncluded==2 and m.evidenceIncluded==0,'numeric facts omitted with raw')
    assert(text:find('N:v3.buff_display',1,true) and text:find('N:v3.death_review',1,true))
    assert(text:find('0.07412400096654892',1,true) and text:find('hits=0',1,true))
    assert(text:find('numeric=2/2',1,true) and text:find('fullDump=not_included',1,true))
    assert(#text<=3500 and #c.reads==1,'no extra reads or bigger report permitted')
end)
Test('large numeric fact rows omit atomically with coverage count',function()
    local S,D,c=Boot()
    for i=1,50 do
        local st=Copy(S.Persistence.stores['v3.death_review']);st.id='extra.'..i
        st.lastWindowNumericEvidence={status='no_match',attempts=32,matches=0,
            fields={normalizedCenterX={raw='0.12345678901234567',canonical='0.12345678901234567',token='0.123457',reason='tested'}}}
        S.Persistence.stores[st.id]=st
    end
    local text,m=Focus(D);assert(text,m)
    assert(type(m.numericEvidenceOmitted)=='number' and m.numericEvidenceOmitted>0 and #text<=3500 and text:find('numericOmit=',1,true))
end)

-- Maintenance: full raw evidence was omitted by the UI budget; the user must receive an
-- explicit file route, not be asked to repeat the same short report. No additional native reads.
Test('oversized evidence advertises the offline udf route without hiding omission',function()
    local S,D,c=Boot();S.Persistence.BuildFailedStoreEvidenceText=function(_,id)
        c.reads[#c.reads+1]=id;return ('x'):rep(50000)
    end
    local text,m=Focus(D);assert(text,m)
    assert(m.evidenceNextStep=='udf_snapshot','missing explicit evidence handoff')
    assert(text:find('next=udf_snapshot',1,true) and m.evidenceIncluded==0 and #c.reads==1)
    assert(#text<=3500 and not text:find('RAW_BEGIN',1,true))
end)
-- 维护：默认打印必须直接保留大故障原档并分页，不能先裁成 Focus；兼容 Focus API 仍可单独测试。
Test('default paged fault report retains oversized failed-store evidence instead of focus clipping it',function()
    local S,D,c=Boot();S.Persistence.BuildFailedStoreEvidenceText=function(_,id)
        c.reads[#c.reads+1]=id;return ('x'):rep(50000)
    end
    local root,h=Page(S,c);assert(h.widgets.v3_diag_output.onClick())
    local buttons=0;for _,w in pairs(h.widgets)do if w.onClick then buttons=buttons+1 end end
    assert(buttons==5 and root.selfCheckMeta.kind=='paged' and #c.reads==3)
    assert(root.selfCheckDelivery.parts>1 and root.selfCheckText:find(('x'):rep(50000),1,true))
end)


print('FOCUS RESULT '..passed..' passed / '..failed..' failed ('.._VERSION..')')
assert(failed==0,'focused report failures')

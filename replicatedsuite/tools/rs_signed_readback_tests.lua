-- 维护（signed-readback-1）：真实 Core/Store/诊断；只将 Native 存盘替换为内存盘。
-- 用户报告只证明 canonical buffs.y=-2 -> 0；以下负数省略/置零是独立故障模型，
-- 不声称已取得用户原档或确定了 RU serializer 的内部实现。测试不加载进游戏 TOC。
local passed, failed = 0, 0
local function Test(name, run)
    local ok, err = pcall(run)
    if ok then passed=passed+1; print('PASS signed-readback '..name)
    else failed=failed+1; print('FAIL signed-readback '..name..': '..tostring(err)) end
end
local function Copy(v)
    if type(v)~='table' then return v end
    local out={}; for k,x in pairs(v) do out[Copy(k)]=Copy(x) end; return out
end
local function Equal(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~='table' then return a==b end
    for k,v in pairs(a) do if not Equal(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end; return true
end
local function NegativeLoss(v, mode)
    if type(v)=='number' and v<0 then if mode=='omit' then return nil end;return 0 end
    if type(v)~='table' then return v end
    local out={}; for k,x in pairs(v) do
        local key=NegativeLoss(k,mode)
        if key~=nil then out[key]=NegativeLoss(x,mode) end
    end; return out
end
local function Boot(options)
    options=options or {}
    local io={disk=Copy(options.disk or {}), reads=0,writes=0,clears=0,now=1000, damage=options.damage,loss=options.loss}
    ADDON={
        LoadData=function(_,k) io.reads=io.reads+1;return Copy(io.disk[k]) end,
        SaveData=function(_,k,v)
            io.writes=io.writes+1
            if io.reject then return false,'synthetic_save_rejection' end
            io.disk[k]=io.loss and NegativeLoss(v,io.loss) or Copy(v)
            if io.damage then io.damage(io.disk[k]) end
            return true
        end,
        ClearData=function() io.clears=io.clears+1;error('must not clear settings') end,
        ChatLog=function() return true end,
    }
    ReplicatedSuite={Features={},Services={},RSUI={},UI={CreateWindowShell=function()end},Generation=1,
        NowMs=function()return io.now end,SafeTraceback=function(e)return tostring(e)end,
        FeatureRuntime={RegisterImplementation=function()return true end},LogBuffer={},LogSequence=0}
    local S=ReplicatedSuite
    S.RecordLog=function(level,source,message)S.LogSequence=S.LogSequence+1;S.LogBuffer[#S.LogBuffer+1]={level=level,source=source,message=message,seq=S.LogSequence,at=io.now}end
    for _,path in ipairs({'core/rs_utils.lua','core/rs_reuse.lua','core/rs_api.lua','core/rs_api_capabilities.lua',
        'core/rs_diagnostics.lua','core/rs_persistence.lua','ui/framework/rs_ui_floating_surface.lua',
        'features/combat/buff_display/rs_buff_display_store.lua','core/rs_report_copy_transport.lua','core/rs_self_check_report.lua'}) do dofile(path) end
    S.FoundationGate={Run=function()return {status='BLOCKED',blockers=1,warnings=1,checks={},sequences={skipped=true}}end}
    S.Runtime={Describe=function()return {}end};S.UIV3={PageHost={Describe=function()return {}end}}
    S.ActionRunner={GetSnapshot=function()return {}end};S.DiagnosticsManager.BuildFeatureStatusRows=function()return {}end
    return S,S.Persistence,S.Features.BuffDisplay,io
end
for _,version in ipairs({3,4}) do
    for _,loss in ipairs({'zero','omit'}) do
        Test('transport '..version..' preserves signed scalars and numeric keys through '..loss, function()
            local _,P=Boot()
            local raw={__rsmeta={framework=3,transportVersion=version},payload={x=-32,y=-2,min=-16777216,
                fractional=-0.125,keys={[-2]='number',['-2']='string',[1]='positive'},zero=0,
                literal='__rs_t3:n-2',positive=2,empty='',off=false}}
            local encoded=assert(P:EncodePhysicalEnvelope(raw))
            assert(encoded.payload.y=='__rs_t3:n-2','negative integer escaped native codec protection')
            assert(encoded.payload.positive==2 and encoded.__rsmeta.transportVersion==version,'routing/positive IDs changed')
            assert(Equal(raw,assert(P:DecodePhysicalEnvelope(NegativeLoss(encoded,loss)))),'signed field/key lost')
        end)
    end
    Test('transport '..version..' still decodes old raw negative integers',function()
        local _,P=Boot(); local raw={__rsmeta={framework=3,transportVersion=version},payload={y=-2,keys={[-32]='old'}}}
        assert(Equal(raw,assert(P:DecodePhysicalEnvelope(raw))))
    end)
end
Test('real HUD apply keeps negative player and target offsets after new generation',function()
    local _,P,F,io=Boot({loss='omit'});assert(F:EnsureStoreLoaded())
    local snapshot=F:GetHudCalibrationSnapshot()
    snapshot.player.components.buffs.y=-2;snapshot.player.components.buffs.x=-21
    snapshot.target.components.buffs.y=-31;snapshot.target.components.buffs.x=-77
    local ok,why=F:PersistHudCalibrationSnapshot(snapshot,'signed-test');assert(ok,why)
    local expected=Copy(F.State);assert(io.writes==1 and io.clears==0)
    local _,fresh,freshF,fio=Boot({disk=io.disk,loss='omit'});assert(freshF:EnsureStoreLoaded())
    assert(Equal(expected,freshF.State),'reload changed unrelated configuration')
    assert(fio.writes==0 and fresh:GetStore('v3.buff_display').schemaVersion==6)
end)
Test('small negative integer encoding remains within original transport version and budgets',function()
    local _,P,F,io=Boot();assert(F:EnsureStoreLoaded())
    local snapshot=F:GetHudCalibrationSnapshot();snapshot.player.components.buffs.y=-400
    assert(F:PersistHudCalibrationSnapshot(snapshot))
    local st=P:GetStore('v3.buff_display')
    assert(st.transportVersion==4 and P.TransportContractVersion==3)
    assert(st.lastPhysicalInspection.ok and st.lastVerifyOk and not st.needsBarrierVerify)
    assert(io.clears==0)
end)
Test('genuine protected-value corruption still fails without clearing or restoring defaults',function()
    local _,P,F,io=Boot({damage=function(raw)raw.payload.settings.components.buffs.y=0 end})
    assert(F:EnsureStoreLoaded());local before=Copy(F.State)
    local snap=F:GetHudCalibrationSnapshot();snap.player.components.buffs.y=-2
    local ok,why=F:PersistHudCalibrationSnapshot(snap)
    assert(not ok and why:find('$.settings.components.buffs.y: number(-2) vs number(0)',1,true),why)
    assert(Equal(before,F.State) and io.clears==0,'failed apply did not preserve in-memory configuration')
    local st=P:GetStore('v3.buff_display');assert(not st.writeFenced and st.needsBarrierVerify and st.lastVerifyOk==false)
end)
local function Failed()
    local S,P,F,io=Boot({damage=function(raw)raw.payload.settings.components.buffs.y=0 end})
    assert(F:EnsureStoreLoaded());local snap=F:GetHudCalibrationSnapshot();snap.player.components.buffs.y=-2
    assert(not F:PersistHudCalibrationSnapshot(snap))
    return S,P,F,io,P:GetStore('v3.buff_display')
end
Test('readback failure is selected even when rollback leaves no load fence or failure counter',function()
    local S,P,F,io,st=Failed()
    assert(st.consecutiveSaveFailures==0 and not st.writeFenced,'test must cover transaction rollback')
    local choices=S.DiagnosticsManager:GetPersistenceFailureChoices()
    assert(#choices==1 and choices[1].value=='v3.buff_display','durable failure disappeared from evidence choices')
    local lines=table.concat(S.DiagnosticsManager:BuildPersistenceFailureReport(),'\n')
    assert(lines:find('failed=1',1,true) and lines:find('fence=0',1,true) and lines:find('readback_failed',1,true))
    assert(lines:find('number(-2) vs number(0)',1,true),'canonical difference absent')
end)
Test('current failure raw evidence reads once and never changes failed state or disk',function()
    local S,P,F,io,st=Failed();local before=Copy(io.disk);local state=Copy(F.State)
    local r,w=io.reads,io.writes;local err=st.lastError
    local evidence,why=P:BuildFailedStoreEvidenceText(st.id,{compact=true})
    assert(evidence,why);assert(evidence:find('RS-PERSIST-EVIDENCE-1',1,true))
    assert(io.reads==r+1 and io.writes==w and io.clears==0 and Equal(before,io.disk) and Equal(state,F.State))
    assert(st.lastError==err and st.lastVerifyOk==false and not st.writeFenced)
end)
Test('paged report attaches durable-failure evidence without rerunning save or repair',function()
    local S,P,F,io,st=Failed();local r,w=io.reads,io.writes
    local text,meta=S.DiagnosticsManager:BuildPagedSelfCheckReport();assert(text,meta)
    assert(meta.evidenceIncluded==1 and meta.evidenceFailed==0 and meta.evidenceOmitted==0,'raw evidence missing')
    assert(meta.fenced==0 and meta.failedStores==1,'load fences confused with failed saves')
    assert(text:find('readback_failed',1,true) and text:find('[RAW_STORE v3.buff_display]',1,true))
    assert(io.reads==r+1 and io.writes==w and io.clears==0)
end)
Test('healthy normal save awaiting barrier is not a failed store and exports nothing',function()
    local S,P,F,io=Boot();assert(F:EnsureStoreLoaded());assert(P:SaveStore('v3.buff_display',{force=true}))
    local st=P:GetStore('v3.buff_display');assert(st.needsBarrierVerify and not st.writeFenced)
    local r=io.reads;assert(#S.DiagnosticsManager:GetPersistenceFailureChoices()==0)
    local value,err=P:BuildFailedStoreEvidenceText(st.id);assert(not value and err=='store_not_fenced')
    assert(io.reads==r)
end)
Test('successful durable retry clears current failure but does not erase incident counters',function()
    local S,P,F,io,st=Failed();local incidents=P.stats.readbackVerifyFailures
    io.damage=nil;local snapshot=F:GetHudCalibrationSnapshot();snapshot.player.components.buffs.y=-2
    assert(F:PersistHudCalibrationSnapshot(snapshot))
    assert(st.lastVerifyOk and not st.needsBarrierVerify and #S.DiagnosticsManager:GetPersistenceFailureChoices()==0)
    assert(P.stats.readbackVerifyFailures==incidents and incidents>0)
end)
Test('missing disk snapshot is reported as evidence failure and not swallowed',function()
    local S,P,F,io,st=Failed();io.disk[st.resolvedKey]=nil
    local text,meta=S.DiagnosticsManager:BuildPagedSelfCheckReport()
    assert(text and meta.evidenceFailed==1 and meta.partial==true and meta.evidenceIncluded==0)
    assert(text:find('evidence_raw_type:nil',1,true))
end)
Test('failure evidence still enforces resolved identity before any read',function()
    local S,P,F,io,st=Failed();st.scope=P.Scope.Character;st.resolvedScopeFingerprint='wrong-character'
    local r=io.reads;local text,why=P:BuildFailedStoreEvidenceText(st.id)
    assert(not text and why:find('evidence_scope:',1,true),why);assert(io.reads==r)
end)
Test('legacy corrupted negative field is not guessed back from checksum',function()
    local _,P,F,io=Boot();assert(F:EnsureStoreLoaded())
    local snap=F:GetHudCalibrationSnapshot();snap.player.components.buffs.y=-2;assert(F:PersistHudCalibrationSnapshot(snap))
    local st=P:GetStore('v3.buff_display');io.disk[st.resolvedKey].payload.settings.components.buffs.y=0
    local _,fresh,freshF,fio=Boot({disk=io.disk});assert(not freshF:EnsureStoreLoaded())
    assert(fresh:GetStore(st.id).writeFenced and fio.writes==0 and fio.clears==0)
end)
-- 维护：成功重新读取合法存档可清除当前错误，但历史连续计数/lastVerify未必归零；
-- 不允许仅凭历史计数越过“只导出当前失败”隐私边界。使用真实Save/Load而非直接清故障标志。
Test('successful verified load suppresses historical save counters from current failure exports',function()
    local S,P,F,io=Boot();assert(F:EnsureStoreLoaded());assert(P:SaveStore('v3.buff_display',{force=true,durable=true}))
    local st=P:GetStore('v3.buff_display');local good=Copy(io.disk[st.resolvedKey])
    io.damage=function(raw)raw.payload.settings.components.buffs.y=99 end
    assert(not P:SaveStore(st.id,{force=true,durable=true}));assert(st.consecutiveSaveFailures>0)
    io.damage=nil;io.disk[st.resolvedKey]=good
    local ok,_,why=P:LoadStore(st.id,{discardDirty=true,discardUnverified=true,revalidateTerminal=true});assert(ok,why)
    assert(st.lastError==nil and not st.needsBarrierVerify and st.consecutiveSaveFailures>0)
    assert(#S.DiagnosticsManager:GetPersistenceFailureChoices()==0,'historical counter exported a healthy load')
    local r=io.reads;local value,err=P:BuildFailedStoreEvidenceText(st.id)
    assert(not value and err=='store_not_fenced' and io.reads==r)
end)
Test('new successful normal write is pending verification rather than a historical readback failure',function()
    local S,P,F,io,st=Failed();io.damage=nil
    assert(P:SaveStore(st.id,{force=true,durable=false}))
    assert(st.needsBarrierVerify and st.lastVerifyOk==false and st.lastError==nil)
    assert(#S.DiagnosticsManager:GetPersistenceFailureChoices()==0,'historical verify flag exported a pending write')
end)
Test('native write failure is evidence even when no load fence is raised',function()
    local S,P,F,io=Boot();assert(F:EnsureStoreLoaded());io.reject=true
    -- 真实Api链路收到Native替身的false，不能因事务回滚没有load fence而漏报。
    local snap=F:GetHudCalibrationSnapshot();snap.player.components.buffs.y=-2
    local ok=F:PersistHudCalibrationSnapshot(snap)
    assert(not ok,'test did not reproduce native write failure')
    assert(#S.DiagnosticsManager:GetPersistenceFailureChoices()==1)
end)
Test('number-token corruption and duplicate decoded keys stay rejected',function()
    local _,P=Boot()
    for _,payload in ipairs({{y='__rs_t3:n-02'},{y='__rs_t3:n-2.0'}, {[-2]='old',['__rs_t3:n-2']='new'}}) do
        local raw={__rsmeta={framework=3,transportVersion=4},payload=payload}
        local value,why=P:DecodePhysicalEnvelope(raw);assert(not value and why)
    end
end)
print('SIGNED READBACK RESULT '..passed..' passed / '..failed..' failed ('.._VERSION..')')
if failed>0 then error('signed-readback failures: '..failed) end

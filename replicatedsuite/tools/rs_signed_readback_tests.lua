-- 维护（2026-09-18，startup-source-recovery）：本文件在故障包中有 10 处未解决的 Git 合并冲突。
-- 已对照用户此前完整 V3 工程恢复有效实现；Authority、调用数据流和存档协议仍由下方原实现负责，
-- 不通过清配置、跳过加载或恢复 Legacy 绕过错误。兼容边界：须与完整 toc.g 及 .18.247 UI 配套；
-- 后续合并必须先检查冲突标记、清单完整性与 Lua 语法，再做运行时验收；注释不增加运行期开销。
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
local function FirstDiff(a,b,path)
    path=path or '$'
    if type(a)~=type(b) then return path..': '..type(a)..' vs '..type(b) end
    if type(a)~='table' then if a~=b then return path..': '..tostring(a)..' vs '..tostring(b) end; return nil end
    for k,v in pairs(a) do local d=FirstDiff(v,b[k],path..'.'..tostring(k));if d then return d end end
    for k in pairs(b) do if a[k]==nil then return path..'.'..tostring(k)..': nil vs '..type(b[k]) end end
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
            if io.damage then io.damage(io.disk[k],k) end
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
for _,version in ipairs({3,4,5}) do
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
    assert(Equal(expected,freshF.State),'reload changed unrelated configuration: '..tostring(FirstDiff(expected,freshF.State) or 'none'))
    assert(fio.writes==0 and fresh:GetStore('v3.buff_display').schemaVersion==8)
end)
Test('HUD calibration save is isolated from the large tracking store and survives main-store scalar drift',function()
    local mainKey='replicated_suite_v1_v3_buff_display'
    local layoutKey='replicated_suite_v1_v3_buff_display_layout'
    local function DamageMain(raw,key)
        if key~=mainKey then return end
        local settings=type(raw)=='table' and type(raw.payload)=='table' and raw.payload.settings or nil
        local distance=type(settings)=='table' and type(settings.components)=='table' and settings.components.distance or nil
        if type(distance)=='table' then distance.x=0 end
    end
    local _,P,F,io=Boot({damage=DamageMain});assert(F:EnsureStoreLoaded())
    local ids={};for i=1,393 do ids[i]=i end
    F.State.settings.tracked.player.auto=Copy(ids);F.State.settings.tracked.target.auto=Copy(ids)
    local snapshot=F:GetHudCalibrationSnapshot()
    snapshot.player.components.distance.x=-1
    snapshot.target=Copy(snapshot.player)
    local writes=io.writes
    local ok,why=F:PersistHudCalibrationSnapshot(snapshot,'hud_calibration_save_exit');assert(ok,why)
    assert(io.writes==writes+1,'HUD calibration must perform exactly one isolated durable write')
    assert(io.disk[layoutKey]~=nil,'dedicated HUD layout Store was not written')
    assert(io.disk[mainKey]==nil,'HUD calibration rewrote monolithic v3.buff_display')
    assert(F.State.settings.components.distance.x==-1 and F.State.settings.targetLayout.components.distance.x==-1,'HUD draft did not commit')
    local _,freshP,freshF,fio=Boot({disk=io.disk,damage=DamageMain});assert(freshF:EnsureStoreLoaded())
    assert(freshF.State.settings.components.distance.x==-1 and freshF.State.settings.targetLayout.components.distance.x==-1,'dedicated layout Store did not override main/default layout on reload')
    assert(fio.writes==0 and freshP:GetStore('v3.buff_display.layout')~=nil,'reload unexpectedly rewrote layout Store')
end)
Test('cold load recovers the proven schema8 transport5 distance.x omission without guessing other fields',function()
    local mainKey='replicated_suite_v1_v3_buff_display'
    local function OmitDistanceX(raw,key)
        if key~=mainKey then return end
        local settings=type(raw)=='table' and type(raw.payload)=='table' and raw.payload.settings or nil
        local distance=type(settings)=='table' and type(settings.components)=='table' and settings.components.distance or nil
        if type(distance)=='table' then distance.x=nil end
    end
    local _,P,F,io=Boot({damage=OmitDistanceX});assert(F:EnsureStoreLoaded())
    F.State.settings.components.distance.x=-1
    -- 模拟 .240 已经发生、而 .241 尚未安装时留下的失败写入：临时撤掉 Store recovery hook，
    -- 让当前测试环境精确生成旧版本的 readback mismatch 磁盘形状；fresh Boot 再由 .241 恢复。
    local st=assert(P:GetStore('v3.buff_display'));local rebuild=st.rebuildCanonicalForIntegrity
    st.rebuildCanonicalForIntegrity=nil
    local ok,why=P:SaveStore('v3.buff_display',{force=true,durable=true,verifyAfterSave=true})
    st.rebuildCanonicalForIntegrity=rebuild
    assert(not ok and why:find('$.settings.components.distance.x: number(-1) vs number(0)',1,true),why)
    assert(io.disk[mainKey]~=nil,'synthetic failed write did not leave the real-world corrupted disk shape')
    local _,freshP,freshF,fio=Boot({disk=io.disk})
    local loaded,loadErr=freshF:EnsureStoreLoaded();assert(loaded,loadErr)
    assert(freshF.State.settings.components.distance.x==-1,'stamped scalar omission was not recovered')
    local freshStore=freshP:GetStore('v3.buff_display')
    assert(not freshStore.writeFenced and freshStore.lastIntegrityStatus=='verified_canonical_recovered_representation','recovery did not stay inside exact canonical proof')
    assert(fio.writes==0,'cold recovery rewrote the monolithic Store')
end)
Test('distance.x omission recovery rejects when any unrelated field also changed',function()
    local mainKey='replicated_suite_v1_v3_buff_display'
    local function DamageTwoFields(raw,key)
        if key~=mainKey then return end
        local settings=type(raw)=='table' and type(raw.payload)=='table' and raw.payload.settings or nil
        local components=type(settings)=='table' and settings.components or nil
        local distance=type(components)=='table' and components.distance or nil
        if type(distance)=='table' then distance.x=nil;distance.y=123 end
    end
    local _,P,F,io=Boot({damage=DamageTwoFields});assert(F:EnsureStoreLoaded())
    F.State.settings.components.distance.x=-1
    local st=assert(P:GetStore('v3.buff_display'));local rebuild=st.rebuildCanonicalForIntegrity
    st.rebuildCanonicalForIntegrity=nil
    local ok=P:SaveStore('v3.buff_display',{force=true,durable=true,verifyAfterSave=true})
    st.rebuildCanonicalForIntegrity=rebuild
    assert(not ok and io.disk[mainKey]~=nil,'failed-write fixture was not created')
    local _,freshP,freshF=Boot({disk=io.disk})
    local loaded=freshF:EnsureStoreLoaded();assert(not loaded,'whole-Store fingerprint must reject x recovery when another field also drifted')
    local failed=freshP:GetStore('v3.buff_display')
    assert(failed.writeFenced and tostring(failed.lastError or ''):find('fingerprint_mismatch',1,true),'unrelated drift bypassed fail-closed integrity')
end)
Test('layout policy and component mutations dirty only the dedicated layout Store',function()
    local _,P,F=Boot();assert(F:EnsureStoreLoaded())
    local main=assert(P:GetStore('v3.buff_display'))
    local layout=P:GetStore('v3.buff_display.layout')
    assert(layout~=nil,'dedicated HUD layout Store missing')
    assert(F:SetSettingValue('headShowAll',true))
    assert(layout.dirty==true and main.dirty~=true,'layout policy mutation touched monolithic Store')
    assert(P:SaveStore('v3.buff_display.layout',{force=true,verifyAfterSave=true}))
    assert(layout.dirty~=true)
    assert(F:SetComponentField('distance','x',-1))
    assert(layout.dirty==true and main.dirty~=true,'component mutation touched monolithic Store')
end)
Test('full layout apply and reset persist through the dedicated layout Store only',function()
    local mainKey='replicated_suite_v1_v3_buff_display'
    local layoutKey='replicated_suite_v1_v3_buff_display_layout'
    local _,P,F,io=Boot();assert(F:EnsureStoreLoaded())
    local snapshot=F:GetLayoutSettingsSnapshot();snapshot.components.distance.x=-1;snapshot.headShowAll=true
    local writes=io.writes
    local ok,why=F:PersistLayoutSettingsSnapshot(snapshot,'layout-editor-apply');assert(ok,why)
    assert(io.writes==writes+1 and io.disk[layoutKey]~=nil and io.disk[mainKey]==nil,'layout apply rewrote monolithic Store')
    assert(type(F.PersistResetLayoutSettings)=='function','durable layout reset boundary missing')
    writes=io.writes;ok,why=F:PersistResetLayoutSettings('layout-reset');assert(ok,why)
    assert(io.writes==writes+1 and io.disk[mainKey]==nil,'layout reset rewrote monolithic Store')
    assert(F.State.settings.components.distance.x==0 and F.State.settings.headShowAll==false,'layout reset did not apply defaults')
end)
Test('small negative integer encoding remains within original transport version and budgets',function()
    local _,P,F,io=Boot();assert(F:EnsureStoreLoaded())
    local snapshot=F:GetHudCalibrationSnapshot();snapshot.player.components.buffs.y=-400
    assert(F:PersistHudCalibrationSnapshot(snapshot))
    local st=P:GetStore('v3.buff_display.layout')
    assert(st.transportVersion==3 and P.TransportContractVersion==3)
    assert(st.lastPhysicalInspection.ok and st.lastVerifyOk and not st.needsBarrierVerify)
    assert(io.clears==0)
end)
Test('genuine protected-value corruption still fails without clearing or restoring defaults',function()
    local layoutKey='replicated_suite_v1_v3_buff_display_layout'
    local _,P,F,io=Boot({damage=function(raw,key) if key==layoutKey then raw.payload.components.buffs.y=0 end end})
    assert(F:EnsureStoreLoaded());local before=Copy(F.State)
    local snap=F:GetHudCalibrationSnapshot();snap.player.components.buffs.y=-2
    local ok,why=F:PersistHudCalibrationSnapshot(snap)
    assert(not ok and why:find('$.components.buffs.y: number(-2) vs number(0)',1,true),why)
    assert(Equal(before,F.State) and io.clears==0,'failed apply did not preserve in-memory configuration')
    local st=P:GetStore('v3.buff_display.layout');assert(not st.writeFenced and st.needsBarrierVerify and st.lastVerifyOk==false)
end)
local function Failed()
    local layoutKey='replicated_suite_v1_v3_buff_display_layout'
    local S,P,F,io=Boot({damage=function(raw,key) if key==layoutKey then raw.payload.components.buffs.y=0 end end})
    assert(F:EnsureStoreLoaded());local snap=F:GetHudCalibrationSnapshot();snap.player.components.buffs.y=-2
    assert(not F:PersistHudCalibrationSnapshot(snap))
    return S,P,F,io,P:GetStore('v3.buff_display.layout')
end
Test('readback failure is selected even when rollback leaves no load fence or failure counter',function()
    local S,P,F,io,st=Failed()
    assert(st.consecutiveSaveFailures==0 and not st.writeFenced,'test must cover transaction rollback')
    local choices=S.DiagnosticsManager:GetPersistenceFailureChoices()
    assert(#choices==1 and choices[1].value=='v3.buff_display.layout','durable failure disappeared from evidence choices')
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
    assert(text:find('readback_failed',1,true) and text:find('[RAW_STORE v3.buff_display.layout]',1,true))
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
Test('corrupted layout negative field is not guessed back from checksum',function()
    local _,P,F,io=Boot();assert(F:EnsureStoreLoaded())
    local snap=F:GetHudCalibrationSnapshot();snap.player.components.buffs.y=-2;assert(F:PersistHudCalibrationSnapshot(snap))
    local st=P:GetStore('v3.buff_display.layout');io.disk[st.resolvedKey].payload.components.buffs.y=0
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
Test('Describe separates current store failures from recovered durable incidents',function()
    local S,P,F,io,st=Failed()
    local active=P:Describe()
    assert(active.currentFailures==1,'active readback failure missing from Describe')
    assert(active.currentFailureKinds.readback_failed==1,'failure kind summary missing')
    local incidents=P.stats.durableVerifyFailures
    io.damage=nil;local snapshot=F:GetHudCalibrationSnapshot();snapshot.player.components.buffs.y=-2
    assert(F:PersistHudCalibrationSnapshot(snapshot))
    local recovered=P:Describe()
    assert(recovered.currentFailures==0,'recovered failure stayed active')
    assert((recovered.currentFailureKinds.readback_failed or 0)==0,'recovered failure kind stayed active')
    assert(P.stats.durableVerifyFailures==incidents and incidents>0,'historical durable incident was erased')
end)
print('SIGNED READBACK RESULT '..passed..' passed / '..failed..' failed ('.._VERSION..')')
if failed>0 then error('signed-readback failures: '..failed) end

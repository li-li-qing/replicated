-- 中文维护注释：开发期回归，不进 TOC。只在 Native SaveData/LoadData 边界注入合成表形，
-- 使用生产 Store/codec/Persistence/PageHost/BuildScope；不是用户实档或 RU 像素布局验收。
-- 损坏样本不重新盖业务指纹，错误校验不得因测试便利被忽略；每个样本结束恢复健康环境。
return function(ctx)
    local S, Test, Copy, Equal = ctx.S, ctx.Test, ctx.Copy, ctx.Equal
    local P, F, store, disk = S.Persistence, ctx.F, ctx.store, ctx.disk
    local fixtures = dofile('tools/rs_status_schema5_fixtures.lua')
    local options = {discardDirty=true, discardUnverified=true, revalidateTerminal=true}
    local function Physical(target, value, schema, fingerprint)
        local raw = target.encode and target.encode(Copy(value)) or {payload=Copy(value)}
        raw.__rsmeta = {framework=3,store=target.id,owner=target.owner,
            contractVersion=target.contractVersion,lifetime=target.lifetime,scope=target.scope,
            schema=schema or target.schemaVersion,transportVersion=2,reliabilityContract=8,
            integrityVersion=4,envelopeIntegrityVersion=1,
            encodedFingerprint=fingerprint or assert(P:FingerprintCanonicalValue(target,P:CanonicalIntegrityValue(target,value)))}
        raw.__rsmeta.envelopeFingerprint=assert(P:FingerprintEnvelopeIntegrity(raw))
        return assert(P:EncodePhysicalEnvelope(raw))
    end
    local function StringKeys(sequence)
        local map={};for i,v in ipairs(sequence) do map[tostring(i)]=v end;return map
    end
    local function WithBuff(raw,run)
        local key=assert(P:ResolveStoreKey(store));local saved=Copy(disk[key]);disk[key]=raw
        local ok,err=pcall(run,key)
        disk[key]=saved
        local restored,_,why=P:LoadStore(store.id,options);assert(restored,why);F:InvalidateSettingsCache()
        assert(ok,err)
    end
    local function SaveAltered(target,key,alter)
        local original=S.Api.SaveData
        S.Api.SaveData=function(self,k,v)
            local payload=Copy(v);if k==key then alter(payload) end
            return original(self,k,payload)
        end
        local ran,ok,err=pcall(P.SaveStore,P,target.id,{force=true,verifyAfterSave=true})
        S.Api.SaveData=original
        assert(ran,ok);return ok,err
    end
    Test('integrity probe distinguishes executed historical hook from missing probe',function()
        WithBuff(Physical(store,fixtures[2].raw,5,'00000000'),function()
            store.lastHistoricalRecoveryProbe='stale/schema7'
            local ok,_,err=P:LoadStore(store.id,options);assert(not ok and store.writeFenced,err)
            assert(store.lastIntegrityRecoveryTrace:find('hist=cand',1,true))
            assert(not tostring(store.lastHistoricalRecoveryProbe):find('hook_not_called',1,true),'executed hook mislabeled')
            assert(tostring(store.lastHistoricalRecoveryProbe):find('schema5',1,true),'schema5 probe missing/stale')
        end)
    end)
    Test('terminal failure memoization keeps evidence and avoids repeat reads',function()
        WithBuff(Physical(store,fixtures[2].raw,5,'00000000'),function()
            assert(not P:LoadStore(store.id,options));local probe=store.lastHistoricalRecoveryProbe
            local original=S.Api.LoadData;local calls=0
            S.Api.LoadData=function(...) calls=calls+1;return original(...) end
            local ran,ok=pcall(P.LoadStore,P,store.id);S.Api.LoadData=original
            assert(ran and not ok and calls==0,'terminal failure re-read disk')
            assert(store.lastHistoricalRecoveryProbe==probe and probe~=nil,'memo lost failure evidence')
        end)
    end)
    Test('schema5 string-index tracked lists recover through exact old fingerprint',function()
        local fixture=fixtures[2];local raw=Physical(store,fixture.raw,5,fixture.fingerprint)
        raw.payload.settings.tracked.buff=StringKeys(raw.payload.settings.tracked.buff)
        raw.payload.settings.tracked.debuff=StringKeys(raw.payload.settings.tracked.debuff)
        WithBuff(raw,function()
            local ok,_,err=P:LoadStore(store.id,options);assert(ok,err)
            assert(Equal(F.State.settings.tracked.buff,fixture.canonical.settings.tracked.buff))
            assert(Equal(F.State.settings.tracked.debuff,fixture.canonical.settings.tracked.debuff))
            assert(F.State.settings.targetLayout.plate.x==fixture.canonical.settings.targetLayout.plate.x)
            assert(F.State.settings.components.buffs.size==47 and not store.writeFenced)
            assert(P:SaveStore(store.id,{force=true,verifyAfterSave=true}));assert(P:LoadStore(store.id,options))
        end)
    end)
    Test('schema6 string-index auto and cooldown selections recover without loss',function()
        local value=store.default();value.settings.tracked.auto={21,82}
        value.settings.trackedCooldowns.skill={123,456};value.settings.trackedCooldowns.mate={789}
        local raw=Physical(store,value)
        raw.payload.settings.tracked.auto=StringKeys(raw.payload.settings.tracked.auto)
        raw.payload.settings.trackedCooldowns.skill=StringKeys(raw.payload.settings.trackedCooldowns.skill)
        raw.payload.settings.trackedCooldowns.mate=StringKeys(raw.payload.settings.trackedCooldowns.mate)
        WithBuff(raw,function()
            local ok,_,err=P:LoadStore(store.id,options);assert(ok,err)
            assert(Equal(F.State.settings.tracked.auto,{21,82}))
            assert(Equal(F.State.settings.trackedCooldowns.skill,{123,456}))
            assert(Equal(F.State.settings.trackedCooldowns.mate,{789}))
        end)
    end)
    Test('durable buff save verifies string-index readback without applying disk to live state',function()
        local value=store.default();value.settings.tracked.auto={21,82}
        WithBuff(Physical(store,value),function(key)
            assert(P:LoadStore(store.id,options));local before=store.get()
            store.lastHistoricalRecoveryProbe='load-evidence'
            local ok,err=SaveAltered(store,key,function(raw)
                raw.payload.settings.tracked.auto=StringKeys(raw.payload.settings.tracked.auto)
            end)
            assert(ok,err);assert(Equal(store.get(),before),'readback mutated live domain')
            assert(store.lastHistoricalRecoveryProbe=='load-evidence','readback polluted load probe')
            assert(store.lastReadbackRepresentationRecovered==true,'exact proof not recorded')
            assert(P:LoadStore(store.id,options));assert(Equal(F.State.settings.tracked.auto,{21,82}))
        end)
    end)
    Test('durable buff readback rejects changed tracked content after key conversion',function()
        local value=store.default();value.settings.tracked.auto={21,82}
        WithBuff(Physical(store,value),function(key)
            assert(P:LoadStore(store.id,options))
            local ok=SaveAltered(store,key,function(raw)
                raw.payload.settings.tracked.auto=StringKeys(raw.payload.settings.tracked.auto)
                raw.payload.settings.tracked.auto['1']=98765
            end)
            assert(not ok and store.lastVerifyOk==false,'changed content passed readback')
        end)
    end)
    Test('readback representation recovery requires explicit opt-in',function()
        local value=store.default();value.settings.tracked.auto={21,82}
        WithBuff(Physical(store,value),function(key)
            assert(P:LoadStore(store.id,options));local enabled=store.recoverReadbackRepresentation
            store.recoverReadbackRepresentation=false
            local ok=SaveAltered(store,key,function(raw)
                raw.payload.settings.tracked.auto=StringKeys(raw.payload.settings.tracked.auto)
            end)
            store.recoverReadbackRepresentation=enabled
            assert(not ok and not store.lastReadbackRepresentationRecovered,'unapproved store used recovery')
        end)
    end)
    Test('readback cannot borrow a candidate from a different stamped fingerprint',function()
        local value=store.default();value.settings.tracked.auto={21,82}
        WithBuff(Physical(store,value),function(key)
            assert(P:LoadStore(store.id,options))
            local ok=SaveAltered(store,key,function(raw)
                raw.payload.settings.tracked.auto=StringKeys(raw.payload.settings.tracked.auto)
                raw.__rsmeta.encodedFingerprint='00000000'
                raw.__rsmeta.envelopeFingerprint=assert(P:FingerprintEnvelopeIntegrity(raw))
            end)
            assert(not ok and not store.lastReadbackRepresentationRecovered,'wrong stamp accepted')
        end)
    end)
    Test('sequence recovery cannot authenticate changed tracked content',function()
        local fixture=fixtures[2];local raw=Physical(store,fixture.raw,5,fixture.fingerprint)
        raw.payload.settings.tracked.buff=StringKeys(raw.payload.settings.tracked.buff)
        raw.payload.settings.tracked.buff['1']=22222
        WithBuff(raw,function(key)
            local before=Copy(disk[key]);local ok=P:LoadStore(store.id,options)
            assert(not ok and store.writeFenced);assert(not F:ImportBuiltinPack('all',false))
            assert(Equal(disk[key],before),'corrupt archive overwritten')
        end)
    end)
    Test('dense sequence helper refuses ambiguous duplicate sparse and oversized keys',function()
        assert(type(P.RebuildDenseSequenceForIntegrity)=='function','strict sequence helper missing')
        for _,case in ipairs({{{[1]=21,['1']=82},1024,'duplicate_index'},
            {{['1']=21,['3']=82},1024,'sparse_sequence'},{{['01']=21},1024,'invalid_index'},
            {{[1]=21,[2]=82},1,'sequence_limit'},{{[0]=21},1024,'invalid_index'}}) do
            local value,err=P:RebuildDenseSequenceForIntegrity(case[1],case[2])
            assert(value==nil and err==case[3],tostring(err))
        end
    end)
    Test('maximum tracked capacity recovers without truncating or reordering',function()
        local value=store.default();local ids={};for i=1,1024 do ids[i]=i+10000 end
        value.settings.tracked.auto=ids;local raw=Physical(store,value)
        raw.payload.settings.tracked.auto=StringKeys(raw.payload.settings.tracked.auto)
        WithBuff(raw,function()
            local ok,_,err=P:LoadStore(store.id,options);assert(ok,err)
            assert(Equal(F.State.settings.tracked.auto,ids))
        end)
    end)
    Test('load metadata rejects wrong owner before recovery even with a sealed envelope',function()
        local raw=Physical(store,fixtures[2].raw,5,fixtures[2].fingerprint)
        raw.__rsmeta.owner='v3.other';raw.__rsmeta.envelopeFingerprint=assert(P:FingerprintEnvelopeIntegrity(raw))
        WithBuff(raw,function(key)
            local before=Copy(disk[key]);local ok=P:LoadStore(store.id,options)
            assert(not ok and store.writeFenced);assert(Equal(disk[key],before))
            assert(store.lastHistoricalRecoveryHookState~='candidate','identity mismatch entered hook')
        end)
    end)
    Test('fenced buff store builds read-only failure page without editors or writes',function()
        WithBuff(Physical(store,fixtures[2].raw,5,'00000000'),function(key)
            assert(not P:LoadStore(store.id,options));local before=Copy(disk[key])
            local host=dofile('tools/rs_status_ui_test_host.lua')(S)
            local page,err=host:Build();assert(page,err)
            assert(page.persistenceUnavailable==true,'failed load looked ready')
            assert(host.widgets.v3_buff_display_tabs==nil,'editors over unread archive')
            assert(host.widgets.v3_buff_persistence_report,'failure evidence action missing')
            assert(page:OnActivated());assert(Equal(disk[key],before) and store.writeFenced)
        end)
    end)
    Test('real PageHost and BuildScope commit the read-only error page without quarantine',function()
        WithBuff(Physical(store,fixtures[2].raw,5,'00000000'),function()
            assert(not P:LoadStore(store.id,options))
            S.SafeTraceback=S.SafeTraceback or function(err) return tostring(err) end
            local floating=S.RSUI.FloatingSurface -- 保留已加载的真实窗口 normalizer，避免宿主替换污染后续 Store 测试。
            dofile('ui/framework/rs_ui_component_core.lua')
            S.RSUI.FloatingSurface=floating
            local host=dofile('tools/rs_status_ui_test_host.lua')(S)
            dofile('presentation/v3/pages/rs_v3_buff_display_page.lua')
            local factory=S.UIV3.PageHost.factories['combat.buff_display']
            dofile('presentation/v3/shell/rs_v3_page_host.lua')
            local H=S.UIV3.PageHost;assert(H:RegisterFactory('combat.buff_display',factory))
            assert(H:Attach(host.Node({id='test_parent'})))
            local ok,err=H:Navigate('combat.buff_display');assert(ok,err)
            assert(H.stats.buildFailures==0 and next(H.failedPages)==nil)
            assert(S.RSUI.metrics.buildTransactionFailures==0 and #S.RSUI.buildScopeStack==0)
            assert(H.pages['combat.buff_display'].persistenceUnavailable and store.writeFenced)
        end)
    end)
    dofile('features/combat/death_review/rs_death_review_store.lua')
    local ds=P:GetStore('v3.death_review');assert(ds);local dr=S.Features.DeathReview
    local deathValue=ds.default()
    deathValue.history={serial=2,entries={
        {serial=1,storageId=1,time=100,clock='01:00:00',windowMs=10000,totalDamage=2100,lethalAmount=1100,eventCount=2,debuffCount=1,lethalSource='synthetic',lethalAbility='hit'},
        {serial=2,storageId=2,time=200,clock='01:00:01',windowMs=10000,totalDamage=3100,lethalAmount=2100,eventCount=3,debuffCount=0,lethalSource='synthetic',lethalAbility='cast'},
    }}
    deathValue.widgetWindow.userMoved=true;deathValue.widgetWindow.coordinateSpace='logical-free-v2'
    deathValue.widgetWindow.x=0;deathValue.widgetWindow.y=44
    local deathKey=assert(P:ResolveStoreKey(ds));local healthyDeath=Physical(ds,deathValue)
    Test('transport2 death index recovers string-index history before lossy decode',function()
        local raw=Copy(healthyDeath);raw.payload.history.entries=StringKeys(raw.payload.history.entries)
        disk[deathKey]=raw;local ok,_,err=P:LoadStore(ds.id,options);assert(ok,err)
        assert(#dr.State.history.entries==2 and dr.State.history.serial==2)
        assert(dr.State.history.entries[1].totalDamage==2100 and dr.State.history.entries[2].storageId==2)
        assert(dr.State.widgetWindow.x==0 and dr.State.widgetWindow.y==44 and not ds.writeFenced)
        assert(P:SaveStore(ds.id,{force=true,verifyAfterSave=true}));assert(P:LoadStore(ds.id,options))
    end)
    Test('durable death index verifies string-index readback without opening record shards',function()
        disk[deathKey]=Copy(healthyDeath);assert(P:LoadStore(ds.id,options));local before=Copy(dr.State)
        local ok,err=SaveAltered(ds,deathKey,function(raw)
            raw.payload.history.entries=StringKeys(raw.payload.history.entries)
        end)
        assert(ok,err);assert(Equal(before,dr.State) and next(dr.RecordStoreIds)==nil)
        assert(ds.lastReadbackRepresentationRecovered)
        assert(P:LoadStore(ds.id,options));assert(#dr.State.history.entries==2)
    end)
    Test('transport2 death history content corruption remains fenced',function()
        local raw=Copy(healthyDeath);raw.payload.history.entries=StringKeys(raw.payload.history.entries)
        raw.payload.history.entries['1'].totalDamage=99999;disk[deathKey]=raw
        local before=Copy(raw);local ok=P:LoadStore(ds.id,options)
        assert(not ok and ds.writeFenced and Equal(disk[deathKey],before))
        disk[deathKey]=Copy(healthyDeath);assert(P:LoadStore(ds.id,options))
    end)
    Test('durable death readback rejects changed summary content',function()
        disk[deathKey]=Copy(healthyDeath);assert(P:LoadStore(ds.id,options))
        local ok=SaveAltered(ds,deathKey,function(raw)
            raw.payload.history.entries=StringKeys(raw.payload.history.entries)
            raw.payload.history.entries['1'].totalDamage=99999
        end)
        assert(not ok and ds.lastVerifyOk==false)
        disk[deathKey]=Copy(healthyDeath);assert(P:LoadStore(ds.id,options))
    end)
    Test('short persistence report includes all failed stores without reading or writing disk',function()
        dofile('core/rs_diagnostics.lua');local D=S.DiagnosticsManager
        assert(type(D.BuildPersistenceFailureReport)=='function','short failure report missing')
        local old={}
        for i=1,3 do
            local id='v3.integrity_report_case_'..i;old[id]=P.stores[id]
            P.stores[id]={id=id,schemaVersion=1,loadStatus='integrity_failed',writeFenced=true,
                lastError='fingerprint_mismatch:00000000>00000001',lastIntegrityRecoveryTrace='hist=cand;known=nil',
                lastHistoricalRecoveryProbe='schema5/base=00000001',lastIntegrityMismatchEvidence={storedSchema=1,stampedFingerprint='00000000'}}
        end
        local load,save=S.Api.LoadData,S.Api.SaveData
        S.Api.LoadData=function() error('report must not load') end;S.Api.SaveData=function() error('report must not save') end
        local ok,lines=pcall(D.BuildPersistenceFailureReport,D)
        S.Api.LoadData,S.Api.SaveData=load,save
        for i=1,3 do local id='v3.integrity_report_case_'..i;P.stores[id]=old[id] end
        assert(ok,lines);assert(type(lines)=='table');local report=table.concat(lines,'\n')
        for i=1,3 do assert(report:find('v3.integrity_report_case_'..i,1,true),'missing failed store '..i) end
        for _,line in ipairs(lines) do assert(#line<=320,'long line risks chat truncation') end
    end)
    Test('short report truncation keeps Chinese error text on UTF8 character boundaries',function()
        local D=S.DiagnosticsManager;local id='v3.report_utf8';local old=P.stores[id]
        P.stores[id]={id=id,schemaVersion=6,writeFenced=true,lastError='A'..string.rep('中',100)}
        local ok,lines=pcall(D.BuildPersistenceFailureReport,D);P.stores[id]=old;assert(ok,lines)
        local found=false
        for _,line in ipairs(lines) do
            local text=line:match('^v3%.report_utf8 reason=(.*)$')
            if text then
                found=true;assert(#line<=320)
                local suffix=text:gsub('^A',''):gsub('%.%.%.$',''):gsub('中','')
                assert(suffix=='','truncation split a UTF8 character')
            end
        end
        assert(found,'failure reason missing')
    end)
    -- 维护：单条复制是新的用户契约；详细 Build 报告仍保留，默认 Print 不再逐行发送。
    Test('persistence report dispatches exactly one entry and propagates chat output failure',function()
        local D=S.DiagnosticsManager;assert(type(D.PrintPersistenceFailureReport)=='function','print report missing')
        local original=S.SafeChat;local lines={}
        S.SafeChat=function(line) lines[#lines+1]=line;return true end
        local ok=D:PrintPersistenceFailureReport();S.SafeChat=original
        assert(ok and #lines==1,'default persistence action must emit one chat entry')
        S.SafeChat=function() return false end
        local failed=D:PrintPersistenceFailureReport();S.SafeChat=original;assert(failed==false)
    end)
end

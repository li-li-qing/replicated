-- 只测诊断/取证，不允许用合成样本声称真实故障存档已修复。
return function(env)
    local S,Test,Copy,Equal,store,disk=env.S,env.Test,env.Copy,env.Equal,env.store,env.disk
    local P=S.Persistence
    local function WithFailure(run)
        local old={};for k,v in pairs(store) do old[k]=v end
        local oldApi=S.Api;local reads,writes=0,0
        local raw={__rsmeta={framework=3,transportVersion=2,schema=5,encodedFingerprint='1E7F5813'},
            payload={a=false,b=0,c='',empty={},ids={[1]=21,['1']=82},text='中文\n\0__rs_t2:s'}}
        store.loaded=true;store.loadStatus='integrity_failed';store.writeFenced=true;store.resolvedKey='evidence_test_key'
        store.lastError='fingerprint_mismatch:1E7F5813>6307A930';store.dirty=false
        S.Api={LoadData=function(_,key) assert(key=='evidence_test_key');reads=reads+1;return raw end,
            SaveData=function() writes=writes+1;error('evidence must not save') end}
        local before=Copy(raw);local flags={store.lastError,store.loadStatus,store.writeFenced,store.dirty}
        local ok,err=pcall(run,raw,function() return reads,writes end)
        local unchanged=Equal(raw,before) and Equal(flags,{store.lastError,store.loadStatus,store.writeFenced,store.dirty})
        S.Api=oldApi;for k in pairs(store) do store[k]=nil end;for k,v in pairs(old) do store[k]=v end
        assert(ok,err);assert(unchanged,'readonly evidence changed input or Store flags')
    end
    Test('raw evidence reads only the selected fenced key without applying defaults',function()
        assert(type(P.BuildFailedStoreEvidenceText)=='function','readonly Core evidence entry missing')
        WithFailure(function(raw,counts)
            local text,err=P:BuildFailedStoreEvidenceText(store.id);assert(text,err)
            local r,w=counts();assert(r==1 and w==0)
            assert(text:find('RS%-PERSIST%-EVIDENCE%-1\n')==1)
            assert(text:find('S4:74657874;'),'raw key missing')
            assert(text:find('D1;') and text:find('S1:31;'),'numeric/string keys collapsed')
            assert(text:find('B0;') and text:find('D0;') and text:find('S0:;') and text:find('T0{}'))
            assert(text:find('E4B8ADE696870A00'),'UTF8/control bytes not preserved')
            local handle=assert(io.open('tools/.evidence_test_sample.txt','wb'));handle:write(text);handle:close()
        end)
    end)
    Test('healthy or unresolved stores cannot be exported by the failure entry',function()
        assert(type(P.BuildFailedStoreEvidenceText)=='function')
        local loaded,fenced,key=store.loaded,store.writeFenced,store.resolvedKey
        local api=S.Api;S.Api={LoadData=function() error('unexpected read') end}
        store.loaded=true;store.writeFenced=false
        local text,err=P:BuildFailedStoreEvidenceText(store.id)
        store.writeFenced=true;store.resolvedKey=nil
        local text2,err2=P:BuildFailedStoreEvidenceText(store.id)
        store.loaded,store.writeFenced,store.resolvedKey=loaded,fenced,key;S.Api=api
        assert(text==nil and err=='store_not_fenced');assert(text2==nil and err2=='store_key_unresolved')
    end)
    Test('evidence load failure and payload rejection do not clear fences',function()
        assert(type(P.BuildFailedStoreEvidenceText)=='function')
        WithFailure(function(raw)
            local api=S.Api;S.Api={LoadData=function() return nil,'native unavailable' end}
            local text,err=P:BuildFailedStoreEvidenceText(store.id);assert(not text and err:find('native unavailable',1,true))
            S.Api=api;raw.payload.bad=0/0
            text,err=P:BuildFailedStoreEvidenceText(store.id);raw.payload.bad=nil
            assert(not text and err:find('invalid_number',1,true))
        end)
    end)
    Test('evidence serializer refuses cycles rather than returning partial text',function()
        assert(type(P.BuildFailedStoreEvidenceText)=='function')
        WithFailure(function(raw)
            raw.payload.loop=raw
            local text,err=P:BuildFailedStoreEvidenceText(store.id);raw.payload.loop=nil
            assert(not text and err:find('cyclic_table',1,true))
        end)
    end)
    Test('diagnostic chat splits UTF8 text losslessly and reports dispatch failure',function()
        local D=S.DiagnosticsManager;assert(type(D.PrintBoundedText)=='function','bounded chat missing')
        local old=S.SafeChat;local sent={}
        S.SafeChat=function(line) assert(#line<=320);sent[#sent+1]=line;return true end
        local source=string.rep('测试中文',100)..'END'
        assert(D:PrintBoundedText(source,'TEST'))
        local bodies={};for _,line in ipairs(sent) do bodies[#bodies+1]=assert(line:match('^%[TEST %d+/%d+%] (.*)$')) end
        assert(table.concat(bodies)==source,'split lost content')
        for _,part in ipairs(bodies) do assert(#part%12==0 or part:sub(-3)=='END','split cut UTF8') end
        S.SafeChat=function() return false end
        local ok=D:PrintBoundedText('x','TEST');S.SafeChat=old
        assert(ok==false,'failed dispatch claimed success')
    end)
    -- 维护：默认动作从多条改为一条；该断言必须约束输出次数，不能只检查拼接后包含 Store。
    Test('usual summary automatically includes all fenced stores without reading disk',function()
        local D=S.DiagnosticsManager;assert(type(D.PrintFoundationSummary)=='function','summary output dispatcher missing')
        WithFailure(function(_,counts)
            local gate,chat=S.FoundationGate,S.SafeChat;local lines={}
            S.FoundationGate={BuildCopyText=function() return string.rep('长摘要',500) end}
            S.SafeChat=function(line) assert(#line<=320);lines[#lines+1]=line;return true end
            local ok,err=D:PrintFoundationSummary();S.FoundationGate,S.SafeChat=gate,chat
            assert(ok,err);assert(#lines==1,'usual summary still emits multiple chat entries');assert(lines[1]:find('RS%-DIAG%-3'))
            assert(table.concat(lines,'\n'):find(store.id,1,true));local r,w=counts();assert(r==0 and w==0)
        end)
    end)
    Test('fenced page exports on explicit click and clears evidence when hidden',function()
        assert(type(P.BuildFailedStoreEvidenceText)=='function')
        WithFailure(function(_,counts)
            local host=dofile('tools/rs_status_ui_test_host.lua')(S)
            local page,err=host:Build();assert(page,err)
            assert(host.widgets.v3_buff_evidence_export,'evidence action missing')
            assert(counts()==0,'page opening read raw saves')
            assert(host.widgets.v3_buff_evidence_export.onClick())
            assert(host.edit.text:find('RS%-PERSIST%-PART%-1'))
            assert(counts()==1);assert(page:OnDeactivated());assert(host.edit.text=='')
        end)
    end)
    Test('missing native editor disables raw evidence export without breaking error page',function()
        local host=dofile('tools/rs_status_ui_test_host.lua')(S);host.nativeEnabled=false
        WithFailure(function(_,counts)
            local page,err=host:Build();assert(page,err)
            assert(host.widgets.v3_buff_evidence_export and host.widgets.v3_buff_evidence_export.enabled==false)
            assert(counts()==0)
        end)
    end)
    Test('character identity change blocks evidence before native read',function()
        WithFailure(function(_,counts)
            local resolve=P.ResolveStoreKey
            store.scope='Character';store.resolvedScopeFingerprint='old_identity'
            P.ResolveStoreKey=function() return 'different_key',nil,'new_identity' end
            local text,err=P:BuildFailedStoreEvidenceText(store.id);P.ResolveStoreKey=resolve
            assert(not text and err:find('scope_binding_key_changed',1,true));assert(counts()==0)
        end)
    end)
    Test('native exception remains a diagnostic error without state mutation',function()
        WithFailure(function()
            S.Api.LoadData=function() error('synthetic native exception') end
            local text,err=P:BuildFailedStoreEvidenceText(store.id)
            assert(not text and err:find('evidence_load_exception',1,true))
        end)
    end)
    Test('large real page output uses one snapshot across copy segments',function()
        WithFailure(function(raw,counts)
            raw.payload.large=string.rep('界',6000)
            local host=dofile('tools/rs_status_ui_test_host.lua')(S)
            local page=assert(host:Build());assert(host.widgets.v3_buff_evidence_export.onClick())
            local chunks={host.edit.text};local guard=0
            while host.widgets.v3_buff_evidence_next.enabled do
                assert(host.widgets.v3_buff_evidence_next.onClick());chunks[#chunks+1]=host.edit.text
                guard=guard+1;assert(guard<16)
            end
            assert(#chunks>1 and counts()==1)
            local handle=assert(io.open('tools/.evidence_test_parts.txt','wb'));handle:write(table.concat(chunks,'\n'));handle:close()
            assert(page:OnDeactivated());raw.payload.large=nil
        end)
    end)
    Test('native editor truncation is detected and evidence cache discarded',function()
        WithFailure(function(_,counts)
            local host=dofile('tools/rs_status_ui_test_host.lua')(S);assert(host:Build())
            function host.edit:SetText(text) self.text=text:sub(1,100) end
            local ok=host.widgets.v3_buff_evidence_export.onClick()
            assert(ok==false and host.edit.text=='' and counts()==1)
            assert(not host.widgets.v3_buff_evidence_next.enabled)
        end)
    end)
    Test('switching evidence store clears prior private text without reloading',function()
        WithFailure(function(_,counts)
            local host=dofile('tools/rs_status_ui_test_host.lua')(S);assert(host:Build())
            assert(host.widgets.v3_buff_evidence_export.onClick())
            assert(host.widgets.v3_buff_evidence_store.spec.set('v3.death_review'))
            assert(host.edit.text=='' and counts()==1)
        end)
    end)
    Test('evidence text size overflow rejects whole result without trimming the store',function()
        WithFailure(function(raw)
            local budget=store.encodedBudget;store.encodedBudget={maxDepth=8,maxNodes=32768,maxStringBytes=524288,maxEntriesPerTable=4096}
            raw.payload.large=string.rep('a',140000)
            local text,err=P:BuildFailedStoreEvidenceText(store.id)
            raw.payload.large=nil;store.encodedBudget=budget
            assert(not text and (err:find('evidence_text_limit',1,true) or err:find('max_string_bytes',1,true)))
        end)
    end)
    Test('hiding evidence reader releases its keyboard ownership without retiring the editor',function()
        WithFailure(function()
            local host=dofile('tools/rs_status_ui_test_host.lua')(S)
            local deactivate=S.UI.DeactivateInputWidget
            S.UI.DeactivateInputWidget=function(_,editor) editor.keyboard=false;return true end
            local page=assert(host:Build());host.edit.keyboard=true
            local ok,err=pcall(function()
                assert(page:OnDeactivated());assert(host.edit.keyboard==false,'hidden evidence still captures keys')
                assert(page:OnActivated());assert(host.edit.visible==true)
            end)
            S.UI.DeactivateInputWidget=deactivate;assert(ok,err)
        end)
    end)
    Test('long error page uses shared scrolling instead of clipping export controls',function()
        WithFailure(function()
            local host=dofile('tools/rs_status_ui_test_host.lua')(S)
            S.UIV3Design.ScrollablePageRoot=function(_,_,spec)
                local node=host.Node(type(spec)=='table' and spec or {id=spec});node.scrollable=true;return node
            end
            local page=assert(host:Build());assert(page.scrollable==true,'export actions can fall below fixed page')
        end)
    end)

    -- 维护：这些样本验证单条聊天的字段选择/预算，不证明用户存档恢复。
    -- Authority：隔离 Core 缓存和 Native 边界；任何 Load/Save/Run/长摘要访问都应导致失败。
    -- 第三个原/新指纹是合成值，不可加入生产恢复白名单或当作用户证据。
    local function WithCompactFixture(run)
        local old={stores=P.stores,gate=S.FoundationGate,chat=S.SafeChat,dispatch=S.DispatchSystemChat,
            api=S.Api,build=S.BuildTag}
        local function Fixture(id,schema,current,stamp,actual,raw,codec)
            return {id=id,schemaVersion=current,loaded=true,writeFenced=true,dirty=false,loadStatus='integrity_failed',
                lastHistoricalRecoveryProbe='schema'..schema..'/sequence=unchanged',lastHistoricalRecoveryHookState='candidate',
                lastError='private-error-player-name',resolvedKey='private-save-key',
                lastIntegrityMismatchEvidence={storedSchema=schema,currentSchema=current,framework=3,transportVersion=2,
                    codec=codec,stampedFingerprint=stamp,actualFingerprint=actual,rawFingerprint=raw}}
        end
        P.stores={
            ['v3.life.trade']=Fixture('v3.life.trade',1,1,'12345678','48B0E000','22334455'),
            ['v3.death_review']=Fixture('v3.death_review',2,2,'695423CD','3B54171E','11223344',1),
            ['v3.buff_display']=Fixture('v3.buff_display',5,6,'1E7F5813','6307A930','6623AE99'),
        }
        S.BuildTag='v3-m1.16.0.18.208-target-gear-score-api-default-template'
        S.FoundationGate={last={blockers=2,warnings=2,status='BLOCKED',checks={
                {id='runtime_startup_degradation',ok=false,severity='blocker',detail='private-error-detail'}}},
            BuildCopyText=function() error('single summary must not build the unbounded report') end,
            Run=function() error('single summary must not run checks') end}
        S.Api={LoadData=function() error('single summary must not load') end,
            SaveData=function() error('single summary must not save') end}
        local lines,dispatches={},0
        S.SafeChat=function(text) lines[#lines+1]=text;return true end
        S.DispatchSystemChat=function() dispatches=dispatches+1;error('unexpected second output path') end
        local ok,err=pcall(run,S.DiagnosticsManager,lines,Fixture,function() return dispatches end)
        P.stores=old.stores;S.FoundationGate=old.gate;S.SafeChat=old.chat;S.DispatchSystemChat=old.dispatch
        S.Api=old.api;S.BuildTag=old.build
        assert(ok,err)
    end
    Test('single chat summary preserves all three fault IDs hashes and schemas without mutations',function()
        WithCompactFixture(function(D,lines)
            local before=Copy(P.stores);local gate=Copy(S.FoundationGate.last)
            assert(D:PrintFoundationSummary());assert(#lines==1,'multi-entry summary')
            local text=lines[1]
            assert(text:find('RS-DIAG-3',1,true) and text:find('B2/W2',1,true) and text:find('F3',1,true))
            assert(text:find('b=v3-m1.16.0.18.208',1,true))
            for id,row in pairs(P.stores) do
                assert(text:find(id,1,true),'missing ID '..id)
                local e=row.lastIntegrityMismatchEvidence
                assert(text:find(e.stampedFingerprint..'>'..e.actualFingerprint,1,true),'missing full fingerprint pair')
                assert(text:find('r'..e.rawFingerprint,1,true),'missing raw proof')
                assert(text:find('s'..e.storedSchema..'>'..row.schemaVersion,1,true),'missing schema pair')
            end
            assert(text:find(' qU',1,true),'sequence=unchanged not represented')
            assert(text:find(' hC',1,true),'candidate is not distinguished from accepted recovery')
            assert(text:sub(-5)=='| END','single-entry tail sentinel missing')
            assert(#text<=288 and #('[上古世纪综合辅助] '..text)<=320,'chat reserve exceeded')
            assert(not text:find('[\r\n]') and not text:find('private',1,true))
            assert(Equal(P.stores,before) and Equal(S.FoundationGate.last,gate),'formatting mutated evidence')
        end)
    end)
    Test('both default diagnostic actions share the same single-entry payload',function()
        WithCompactFixture(function(D,lines)
            assert(D:PrintFoundationSummary());assert(D:PrintPersistenceFailureReport())
            assert(#lines==2 and lines[1]==lines[2],'separate actions do not share the compact format')
        end)
    end)
    Test('single diagnostic is usable with missing foundation and reports unknown counts',function()
        WithCompactFixture(function(D,lines)
            S.FoundationGate=nil
            assert(D:PrintFoundationSummary());assert(#lines==1)
            assert(lines[1]:find('B?/W?',1,true) and lines[1]:find('F3',1,true))
        end)
    end)
    Test('healthy persistence summary retains failed framework check IDs without details',function()
        WithCompactFixture(function(D,lines)
            P.stores={}
            assert(D:PrintFoundationSummary());assert(#lines==1)
            assert(lines[1]:find('F0',1,true) and lines[1]:find('runtime_startup_degradation',1,true))
            assert(not lines[1]:find('private-error-detail',1,true))
        end)
    end)
    Test('single report overflow omits whole stores with an exact visible remaining count',function()
        WithCompactFixture(function(D,lines,Fixture)
            P.stores={}
            for i=1,30 do
                local id=string.format('v3.long_diagnostic_store_%02d',i)
                P.stores[id]=Fixture(id,5,6,'1E7F5813','6307A930','6623AE99',1)
            end
            assert(D:PrintFoundationSummary());assert(#lines==1 and #lines[1]<=288)
            local omitted=tonumber(lines[1]:match('more=(%d+)'));assert(omitted and omitted>0,'silent omission')
            local _,shown=lines[1]:gsub('v3%.long_diagnostic_store_%d+','')
            local _,pairs=lines[1]:gsub('1E7F5813>6307A930','')
            assert(shown+pairs>0 and shown==pairs and shown+omitted==30,'partial record or incorrect omission count')
            assert(lines[1]:find('F30',1,true) and lines[1]:sub(-5)=='| END')
        end)
    end)
    Test('single report preserves unknown fields rather than inventing fingerprints or clean state',function()
        WithCompactFixture(function(D,lines)
            local row=P.stores['v3.buff_display']
            row.lastIntegrityMismatchEvidence={storedSchema=5,stampedFingerprint='bad-value',actualFingerprint='6307A930'}
            row.lastHistoricalRecoveryProbe=nil;row.lastHistoricalRecoveryHookState=nil
            S.FoundationGate.last=nil
            assert(D:PrintFoundationSummary());assert(#lines==1)
            assert(lines[1]:find('B?/W?',1,true) and lines[1]:find('?>6307A930',1,true))
            assert(not lines[1]:find('00000000',1,true))
        end)
    end)
    Test('single report strips control bytes and bounds oversized diagnostic metadata',function()
        WithCompactFixture(function(D,lines)
            S.BuildTag=string.rep('版本\n|\0',100)
            P.stores={one={id=string.rep('test\n|\0',100),writeFenced=true,loadStatus='failed\n|\0',schemaVersion=math.huge}}
            S.FoundationGate.last.blockers=0/0;S.FoundationGate.last.warnings=math.huge
            assert(D:PrintFoundationSummary());assert(#lines==1 and #lines[1]<=288)
            assert(not lines[1]:find('[%c]'),'control byte escaped into chat')
            assert(lines[1]:find('B?/W?',1,true) and lines[1]:sub(-5)=='| END')
        end)
    end)
    Test('single report false dispatch fails once without a fallback duplicate',function()
        WithCompactFixture(function(D,lines,_,dispatches)
            S.SafeChat=function(text) lines[#lines+1]=text;return false end
            local ok=D:PrintFoundationSummary();assert(ok==false and #lines==1 and dispatches()==0)
        end)
    end)
    Test('single report native exception is contained without a fallback duplicate',function()
        WithCompactFixture(function(D,lines,_,dispatches)
            S.SafeChat=function(text) lines[#lines+1]=text;error('synthetic dispatch exception') end
            local ok=D:PrintPersistenceFailureReport();assert(ok==false and #lines==1 and dispatches()==0)
        end)
    end)
    Test('single report uses only the fallback when the primary chat function is unavailable',function()
        WithCompactFixture(function(D,lines)
            S.SafeChat=nil;S.DispatchSystemChat=function(text) lines[#lines+1]=text;return true end
            assert(D:PrintFoundationSummary());assert(#lines==1 and #lines[1]<=288)
        end)
    end)
    Test('single report cannot claim success when all output functions are absent',function()
        WithCompactFixture(function(D,lines)
            S.SafeChat=nil;S.DispatchSystemChat=nil
            local ok,err=D:PrintFoundationSummary();assert(ok==false and type(err)=='string' and #lines==0)
        end)
    end)
    Test('single report byte order is deterministic regardless of store registration order',function()
        WithCompactFixture(function(D,lines)
            assert(D:PrintFoundationSummary())
            local old=P.stores;P.stores={}
            for _,id in ipairs({'v3.buff_display','v3.death_review','v3.life.trade'}) do P.stores[id]=old[id] end
            assert(D:PrintFoundationSummary());assert(lines[1]==lines[2])
        end)
    end)
    Test('real fenced page report button emits one copyable entry without native reads',function()
        WithFailure(function(_,counts)
            local chat=S.SafeChat;local lines={};S.SafeChat=function(text) lines[#lines+1]=text;return true end
            local ok,err=pcall(function()
                local host=dofile('tools/rs_status_ui_test_host.lua')(S);assert(host:Build())
                assert(host.widgets.v3_buff_persistence_report.onClick())
                assert(#lines==1 and lines[1]:find('RS-DIAG-3',1,true))
                local reads,writes=counts();assert(reads==0 and writes==0)
            end)
            S.SafeChat=chat;assert(ok,err)
        end)
    end)

    Test('single report missing persistence registry is unknown rather than zero failures',function()
        WithCompactFixture(function(D,lines)
            local persistence=S.Persistence;S.Persistence=nil
            local ok,err=pcall(function()
                assert(D:PrintFoundationSummary());assert(#lines==1 and lines[1]:find('F?',1,true))
                assert(not lines[1]:find('F0',1,true))
            end)
            S.Persistence=persistence;assert(ok,err)
        end)
    end)
    Test('single report does not silently truncate overflowed framework check IDs',function()
        WithCompactFixture(function(D,lines)
            P.stores={};S.FoundationGate.last.checks={}
            for i=1,20 do S.FoundationGate.last.checks[i]={id='synthetic_long_blocker_check_'..i,ok=false,severity='blocker'} end
            assert(D:PrintFoundationSummary());assert(#lines==1 and #lines[1]<=288)
            local omitted=tonumber(lines[1]:match('checksMore=(%d+)'));assert(omitted and omitted>0)
            local _,shown=lines[1]:gsub('B:synthetic_long_blocker_check_%d+','')
            assert(shown+omitted==20 and lines[1]:sub(-5)=='| END')
        end)
    end)
    Test('single report nil chat return is not treated as confirmed delivery',function()
        WithCompactFixture(function(D,lines,_,dispatches)
            S.SafeChat=function(text) lines[#lines+1]=text end
            local ok=D:PrintFoundationSummary();assert(ok==false and #lines==1 and dispatches()==0)
        end)
    end)

end

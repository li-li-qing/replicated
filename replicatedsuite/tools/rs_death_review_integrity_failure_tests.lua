-- 维护（2026-09-30，death-index-proof-1）：真实 Store/Core + 内存 Native 边界。
-- 所有输入均为合成故障注入，不冒充玩家 3205A259 原档；不写入运行时 TOC。
local passed, failed = 0, 0
local function Test(name, fn)
    local ok, err = pcall(fn)
    if ok then passed=passed+1; print('PASS death-index '..name)
    else failed=failed+1; print('FAIL death-index '..name..': '..tostring(err)) end
end
local function Copy(v)
    if type(v)~='table' then return v end
    local out={}; for k,x in pairs(v) do out[k]=Copy(x) end; return out
end
local function Equal(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~='table' then return a==b end
    for k,v in pairs(a) do if not Equal(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end
    return true
end
local function Boot(disk)
    local host={disk=Copy(disk or {}), reads=0, writes=0, clears=0, saved={}}
    ADDON={LoadData=function(_,key) host.reads=host.reads+1;return Copy(host.disk[key]) end,
        SaveData=function(_,key,value)
            host.writes=host.writes+1;host.saved[#host.saved+1]=key
            host.disk[key]=Copy(value)
            if host.corrupt then host.corrupt(key,host.disk[key]) end
            return true
        end,
        ClearData=function(_,key) host.clears=host.clears+1;host.disk[key]=nil;return true end}
    ReplicatedSuite={Features={},Services={},RSUI={},UI={CreateWindowShell=function()error('no Native UI in tests')end},NowMs=function()return 1000 end,SafeTraceback=debug.traceback}
    dofile('core/rs_utils.lua');dofile('core/rs_reuse.lua');dofile('core/rs_demand.lua')
    dofile('core/rs_api.lua');dofile('core/rs_api_capabilities.lua')
    dofile('core/rs_persistence_transport.lua');dofile('core/rs_persistence.lua')
    dofile('ui/framework/rs_ui_floating_surface.lua')
    dofile('features/combat/death_review/rs_death_review_store.lua')
    local S=ReplicatedSuite
    return S.Features.DeathReview,S.Persistence,host
end
local function Record(n)
    return {serial=n,time=1000+n,clock='12:00:00',windowMs=10000,totalDamage=321,
        lethal={time=1000+n,source='kept-source',ability='kept-ability',amount=321},
        events={{time=1000+n,source='kept-source',ability='kept-ability',amount=321}},debuffs={}}
end
local function Prepare(n)
    local F,P,h=Boot();assert(F:EnsureStoreLoaded())
    assert(F:SetMaxHistoryPersistent(30))
    for i=1,n do assert(F:CommitDeathRecord(Record(i))) end
    return F,P,h,P:GetStore('v3.death_review')
end
local function DamageIndex(P,h,key)
    local raw=assert(P:DecodePhysicalEnvelope(h.disk[key]))
    local entries=raw.payload.history.entries
    local i=#entries
    if i==0 then
        entries[1]={storageId=1,serial=1,time=1,clock='12:00:00',windowMs=10000,
            totalDamage=1,lethalSource='changed',lethalAbility='changed',lethalAmount=1,eventCount=1,debuffCount=0}
    else entries[i]={lethalSource=entries[i].lethalSource,windowMs=entries[i].windowMs} end
    h.disk[key]=assert(P:EncodePhysicalEnvelope(raw))
end
Test('fresh history retains the latest twenty deaths and reloads that default',function()
    local F,P,h=Boot();assert(F:EnsureStoreLoaded())
    assert(h.writes==0,'opening an empty index must not write defaults')
    for i=1,21 do assert(F:CommitDeathRecord(Record(i)))end
    assert(#F.State.history.entries==20 and F.State.history.entries[1].serial==2,'fresh history still trims at ten')
    local F2,P2,h2=Boot(h.disk);assert(F2:EnsureStoreLoaded())
    assert(F2:GetSettings().maxHistory==20 and #F2.State.history.entries==20 and h2.writes==0)
    assert(P2:GetStore('v3.death_review').writeFenced~=true)
end)
Test('saved limits and missing schema2 history setting keep their original canonical',function()
    for _,maximum in ipairs({7,10,30})do
        local F,P,h=Boot();assert(F:EnsureStoreLoaded());assert(F:SetMaxHistoryPersistent(maximum))
        local F2,_,h2=Boot(h.disk);assert(F2:EnsureStoreLoaded())
        assert(F2:GetSettings().maxHistory==maximum and h2.writes==0,'saved history limit was replaced')
    end
    local F,P,h=Boot();assert(F:EnsureStoreLoaded());assert(F:SetMaxHistoryPersistent(10))
    local st=P:GetStore('v3.death_review');local raw=assert(P:DecodePhysicalEnvelope(h.disk[st.resolvedKey]))
    raw.payload.settings.maxHistory=nil
    -- 旧 schema2 canonical 的缺省值是10，声明指纹保留；只重封物理输入的 envelope。
    raw.__rsmeta.envelopeFingerprint=assert(P:FingerprintEnvelopeIntegrity(raw))
    h.disk[st.resolvedKey]=assert(P:EncodePhysicalEnvelope(raw))
    local F2,P2,h2=Boot(h.disk);assert(F2:EnsureStoreLoaded())
    assert(F2:GetSettings().maxHistory==10 and h2.writes==0 and not P2:GetStore(st.id).writeFenced)
end)
Test('incomplete 27th summary stays fenced without a false historical candidate',function()
    local _,P,h,st=Prepare(27);local key=st.resolvedKey;DamageIndex(P,h,key)
    local _,P2,h2=Boot(h.disk);local s=P2:GetStore(st.id)
    local applied=0;local apply=s.apply;s.apply=function(v)applied=applied+1;apply(v)end
    local ok,_,err=P2:LoadStore(st.id)
    assert(ok==false and s.writeFenced and applied==0,err)
    assert(h2.writes==0 and h2.clears==0 and h2.reads==1,'recovery must not scan record shards')
    local probe=tostring(s.lastHistoricalRecoveryProbe)
    assert(probe:find('history=incomplete',1,true),'missing structural evidence: '..probe)
    assert(probe:find('row=27',1,true) and probe:find('rows=27',1,true),probe)
    assert(probe:find('kept=26',1,true) and probe:find('storageId',1,true),probe)
    assert(tostring(s.lastIntegrityRecoveryTrace):find('hist=nil',1,true),'must not emit a mismatching candidate')
end)
Test('string-index candidate is returned only after exact fingerprint proof',function()
    local _,P,_,st=Prepare(2);local raw=st.encode(st.get())
    local rows=raw.payload.history.entries;raw.payload.history.entries={['1']=rows[1],['2']=rows[2]}
    raw.__rsmeta={store=st.id,owner=st.owner,framework=3,schema=2,transportVersion=3,integrityVersion=4}
    local value=st.decode(raw);local current=st.encode(value)
    local before=Copy(raw);local candidate=st.rebuildCanonicalForIntegrity(value,'BAD0BEEF',current,raw)
    assert(candidate==nil,'a wrong full fingerprint must not be returned as a recovery')
    assert(Equal(raw,before),'read-only candidate hook changed input')
end)
Test('exact string-key recovery preserves every summary',function()
    local _,P,h,st=Prepare(3);local expected=st.get();local key=st.resolvedKey
    local raw=assert(P:DecodePhysicalEnvelope(h.disk[key]));local rows=raw.payload.history.entries
    raw.payload.history.entries={};for i,row in ipairs(rows) do raw.payload.history.entries[tostring(i)]=row end
    h.disk[key]=assert(P:EncodePhysicalEnvelope(raw))
    local F2,P2=Boot(h.disk);assert(P2:LoadStore(st.id));assert(Equal(F2.State,expected))
end)
Test('wrong sparse sequence remains fenced',function()
    local _,P,h,st=Prepare(3);local key=st.resolvedKey
    local raw=assert(P:DecodePhysicalEnvelope(h.disk[key]));raw.payload.history.entries[2]=nil
    h.disk[key]=assert(P:EncodePhysicalEnvelope(raw))
    local _,P2,h2=Boot(h.disk);assert(P2:LoadStore(st.id)==false)
    assert(P2:GetStore(st.id).writeFenced and h2.writes==0 and h2.clears==0)
end)
Test('shard readback failure cannot publish an index reference',function()
    local F,P,h,st=Prepare(1);local before=Copy(F.State.history);local oldIndex=Copy(h.disk[st.resolvedKey])
    h.saved={}
    h.corrupt=function(key,physical)
        if key:find('death_review_record_',1,true) then
            local raw=assert(P:DecodePhysicalEnvelope(physical));(raw.payload or raw).totalDamage=123
            h.disk[key]=assert(P:EncodePhysicalEnvelope(raw))
        end
    end
    local ok,err=F:CommitDeathRecord(Record(2))
    assert(ok==false and tostring(err):find('readback',1,true),'corrupt record reported committed: '..tostring(err))
    assert(Equal(F.State.history,before) and Equal(h.disk[st.resolvedKey],oldIndex),'index changed after shard failure')
    assert(#h.saved==1 and h.clears==0,'must stop before index SaveData')
end)
Test('index readback failure rolls RAM back and remains an unverified physical write',function()
    local F,P,h,st=Prepare(1);local before=Copy(F.State.history)
    h.corrupt=function(key) if key==st.resolvedKey then DamageIndex(P,h,key) end end
    local ok,err=F:CommitDeathRecord(Record(2))
    assert(ok==false and tostring(err):find('readback',1,true),'corrupt index reported committed: '..tostring(err))
    assert(Equal(F.State.history,before),'RAM history not rolled back')
    assert(P:GetStoreFailureKind(st)=='readback_failed' and st.needsBarrierVerify,'missing physical failure evidence')
    assert(h.clears==0)
end)
Test('clear-history cannot delete shards before empty-index readback succeeds',function()
    local F,P,h,st=Prepare(2);local before=Copy(F.State.history)
    h.corrupt=function(key) if key==st.resolvedKey then DamageIndex(P,h,key) end end
    local ok=F:ClearHistoryStore()
    assert(ok==false,'empty index was not readback verified')
    assert(h.clears==0,'unverified empty index must not trigger shard deletion')
    assert(Equal(F.State.history,before),'failed clear lost RAM history')
end)
Test('healthy commit and cold reload retain records and settings',function()
    local F,P,h,st=Prepare(3);st.lastVerifyOk=nil;assert(F:CommitDeathRecord(Record(4)))
    local expected=Copy(F.State)
    assert(st.lastVerifyOk==true,'critical index commits must verify immediately')
    local F2,P2,h2=Boot(h.disk);assert(F2:EnsureStoreLoaded());assert(Equal(F2.State,expected))
    for _,row in ipairs(F2.State.history.entries) do
        local record=assert(F2:LoadRecord(row.storageId));assert(record.serial==row.serial and record.totalDamage==321)
    end
    assert(h2.writes==0 and h2.clears==0)
end)
Test('record schema2 retains prior index and write verification gates',function()
    local F,P=Boot();local st=P:GetStore('v3.death_review');local rid=assert(F:EnsureRecordStore(1))
    assert(st.schemaVersion==2 and st.verifyAfterSave==false and st.allowIntegrityUpgrade==true)
    assert(P:GetStore(rid).schemaVersion==2 and P:GetStore(rid).verifyAfterSave==false)
end)
-- 中文维护：复刻本次 Native 截断的 settings 丢失 + 第27行不完整 + 后3行消失。
local function NativeCut(P,h,st)
    local raw=assert(P:DecodePhysicalEnvelope(h.disk[st.resolvedKey]))
    raw.__rsmeta.transportVersion=3
    raw.__rsmeta.envelopeFingerprint=assert(P:FingerprintEnvelopeIntegrity(raw))
    raw.payload.settings=nil
    local rows=raw.payload.history.entries
    for i=28,30 do rows[i]=nil end
    rows[27]={windowMs=rows[27].windowMs,lethalSource=rows[27].lethalSource}
    h.disk[st.resolvedKey]=assert(P:EncodePhysicalEnvelope(raw))
end
Test('native cut recovers only verified shards and rewrites a bounded compact index',function()
    local _,P,h,st=Prepare(30);local expected=st.get();NativeCut(P,h,st)
    local F2,P2,h2=Boot(h.disk);assert(F2:EnsureStoreLoaded())
    local repaired=P2:GetStore(st.id)
    assert(Equal(F2.State,expected) and repaired.writeFenced==false and h2.writes==1)
    assert(tostring(repaired.lastHistoricalRecoveryProbe):find('hits=1',1,true))
    assert(repaired.lastVerifyOk==true,'recovery must verify the physical rewrite before ready')
    assert(repaired.lastNativeByteEstimate<14336 and h2.disk[st.key].__rsmeta.transportVersion==6)
    local F3,P3,h3=Boot(h2.disk);assert(F3:EnsureStoreLoaded())
    assert(Equal(F3.State,expected) and h3.writes==0 and P3:GetStore(st.id).writeFenced==false)
end)
Test('native cut with a missing shard remains fenced without writes',function()
    local _,P,h,st=Prepare(30);NativeCut(P,h,st)
    h.disk[P.V3KeyPrefix..'death_review_record_30']=nil
    local F2,P2,h2=Boot(h.disk);assert(F2:EnsureStoreLoaded()==false)
    assert(P2:GetStore(st.id).writeFenced and h2.writes==0 and h2.clears==0)
end)
Test('failed recovery rewrite readback never publishes feature ready',function()
    local _,P,h,st=Prepare(30);NativeCut(P,h,st)
    local F2,P2,h2=Boot(h.disk)
    h2.corrupt=function(key,physical)
        if key==st.key then physical.payload.history.entries[30]=physical.payload.history.entries[30]:sub(1,-4) end
    end
    assert(F2:EnsureStoreLoaded()==false and F2.StoreLoaded==false)
    assert(P2:GetStore(st.id).lastVerifyOk==false and h2.writes==1)
end)
Test('native cut cannot replace retained data with differing shard data',function()
    local _,P,h,st=Prepare(30);NativeCut(P,h,st)
    local raw=assert(P:DecodePhysicalEnvelope(h.disk[st.key]));raw.payload.history.entries[1].totalDamage=999
    h.disk[st.key]=assert(P:EncodePhysicalEnvelope(raw))
    local F2,P2,h2=Boot(h.disk);assert(F2:EnsureStoreLoaded()==false)
    assert(P2:GetStore(st.id).writeFenced and h2.writes==0)
end)
Test('native budget rejects before touching the previous physical index',function()
    local _,P,h,st=Prepare(3);local before=Copy(h.disk[st.key]);local writes=h.writes
    st.nativeByteBudget=1024
    local ok,err=P:SaveStore(st.id,{verifyAfterSave=true})
    assert(ok==false and tostring(err):find('native_byte_budget_exceeded',1,true))
    assert(h.writes==writes and Equal(before,h.disk[st.key]))
end)
Test('compact physical rows preserve exact types tokens and extra fields',function()
    local F,P=Prepare(1);local T=ReplicatedSuite.PersistenceTransport
    local row=Copy(F.State.history.entries[1]);row.clock='';row.lethalSource='中文\n"\0';row.time=1/3
    local value={row=row,token='__rs_t6:rnot-a-record',legacy='__rs_t3:n5',zero=0,negative=-2,falseValue=false,empty={}}
    assert(Equal(assert(T.DecodeV6(assert(T.EncodeV6(value)))),value))
    row.extra='preserve'
    assert(Equal(assert(T.DecodeV6(assert(T.EncodeV6(row)))),row))
    assert(T.DecodeV6('__rs_t6:r1;2')==nil)
end)
print('DEATH_INDEX_FAILURE_TESTS: '..passed..' passed / '..failed..' failed')
assert(failed==0,'death index integrity regression failures')

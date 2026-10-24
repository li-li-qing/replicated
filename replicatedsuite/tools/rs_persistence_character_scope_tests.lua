------------------------------------------------------------------------
-- Replicated Suite · 角色物理键隔离与只读旧键迁移回归
-- 中文维护：加载真实 Core/Transport，只替换 Native 身份与磁盘为内存；不访问或修改实机 UDF。
-- 新键必须隔离有损姓名，旧键只有完整归属和内容证明通过后才能迁移；旧物理值始终保留。
------------------------------------------------------------------------
local function Copy(value)
    if type(value)~='table' then return value end
    local out={};for k,v in pairs(value)do out[k]=Copy(v)end;return out
end
local function Equal(a,b)
    if type(a)~=type(b)then return false end
    if type(a)~='table'then return a==b end
    for k,v in pairs(a)do if not Equal(v,b[k])then return false end end
    for k in pairs(b)do if a[k]==nil then return false end end
    return true
end
-- 单一宿主支持同代切角与重新建代；writeKeys 证明迁移从不反写旧键，loadErrors 模拟不可认作空档的读取失败。
local function New(identity,disk,scope)
    local h={identity=identity,disk=disk or {},reads=0,writes=0,clears=0,writeKeys={},readKeys={},loadErrors={},applies=0,value={marker='default'}}
    X2Unit={};ReplicatedSuite={SaveKey='audit',NowMs=function()return 1000 end,Api={}}
    local S=ReplicatedSuite
    function S.Api:CallCapability(cap,obj,method,unit)
        assert(cap=='X2Unit:UnitNameWithWorld'and unit=='player');return true,h.identity
    end
    function S.Api:LoadData(key)
        h.reads=h.reads+1;h.readKeys[key]=(h.readKeys[key]or 0)+1
        return Copy(h.disk[key]),h.loadErrors[key]
    end
    function S.Api:SaveData(key,value)
        h.writes=h.writes+1;h.writeKeys[key]=(h.writeKeys[key]or 0)+1
        -- 仅内存故障注入，证明 Native 拒绝和假成功 drop 都不能提前把默认值应用到 Domain。
        if h.saveMode=='reject'then return false,'synthetic write refusal'end
        if h.saveMode~='drop'then h.disk[key]=Copy(value)end;return true
    end
    function S.Api:ClearData(key)
        assert(h.allowClear,'scope regression must not unexpectedly clear data')
        h.clears=h.clears+1;h.disk[key]=nil;return true
    end
    dofile('core/rs_persistence_transport.lua');dofile('core/rs_persistence.lua');h.P=S.Persistence
    h.store=assert(h.P:RegisterV3Store({id='v3.audit',owner='v3.audit',scope=scope or h.P.Scope.Character,lifetime=h.P.Lifetime.Permanent,
        schemaVersion=1,key=h.P.V3KeyPrefix..'identity',budget={maxDepth=5,maxNodes=256,maxStringBytes=4096,maxEntriesPerTable=32},
        get=function()return Copy(h.value)end,apply=function(value)h.applies=h.applies+1;h.value=Copy(value)end,
        default=function()return{marker='default'}end,migrate=function(value)return Copy(value)end}))
    return h
end
local function Key(h)return assert(h.P:ResolveStoreKey('v3.audit'))end
local function LegacyKey(h)
    -- 重现发布前旧算法，而非依赖被测新实现给出旧候选，避免相同错误同时污染测试和生产。
    local token=('world:'..h.identity):lower():gsub('[^%w_%.%-]','_'):gsub('_+','_'):gsub('^_+',''):gsub('_+$',''):sub(1,80)
    return h.P.V3KeyPrefix..'identity_char_'..token
end
local function Save(h,marker)
    assert(h.P:PrepareWrite('v3.audit'));h.value.marker=marker
    local ok,err=h.P:SaveStore('v3.audit',{durable=true});assert(ok,tostring(err))
end
local function SavedLegacy(identity,marker)
    local h=New(identity);assert(h.P:PrepareRead('v3.audit'));Save(h,marker or'A')
    local current,legacy=Key(h),LegacyKey(h)
    if current~=legacy then h.disk[legacy]=Copy(h.disk[current]);h.disk[current]=nil end
    return h,legacy
end
local function Alter(h,key,fn,seal)
    local raw=assert(h.P:DecodePhysicalEnvelope(Copy(h.disk[key])));fn(raw)
    if seal then raw.__rsmeta.envelopeFingerprint=assert(h.P:FingerprintEnvelopeIntegrity(raw))end
    h.disk[key]=assert(h.P:EncodePhysicalEnvelope(raw))
end
local passed,failed=0,0
local function Test(name,fn)
    local ok,err=pcall(fn)
    if ok then passed=passed+1;print('PASS '..name)else failed=failed+1;print('FAIL '..name..': '..tostring(err))end
end
for _,pair in ipairs({{'Chinese','张三','李四'},{'Russian','Иван','Пётр'},
    {'long-prefix',string.rep('a',80)..'x',string.rep('a',80)..'y'}})do
    Test(pair[1]..' independent keys, save and relog',function()
        local a=New(pair[2]);assert(a.P:PrepareRead('v3.audit'));Save(a,'A');local ka=Key(a)
        local b=New(pair[3],a.disk);assert(b.P:PrepareRead('v3.audit'));Save(b,'B');assert(Key(b)~=ka,'identities share one key')
        local aa=New(pair[2],a.disk);assert(aa.P:PrepareRead('v3.audit'));assert(aa.value.marker=='A')
        local bb=New(pair[3],a.disk);assert(bb.P:PrepareRead('v3.audit'));assert(bb.value.marker=='B')
    end)
end
Test('lossless ASCII key is byte-for-byte compatible and reads once',function()
    local h=New('Alice_One-2.World');assert(Key(h)==LegacyKey(h));assert(h.P:PrepareRead('v3.audit'));assert(h.reads==1)
end)
Test('lossy punctuation and underscore collapse receive distinct stable keys',function()
    local h=New('a@b');local a=Key(h);h.identity='a_b';assert(Key(h)~=a)
    h.identity='a__b';assert(Key(h)~=LegacyKey(h));h.identity='a@b';assert(Key(h)==a)
end)
Test('owned stamped legacy migrates only to new key after full load proof',function()
    local a,legacy=SavedLegacy('张三','legacy-A');local before=Copy(a.disk[legacy])
    local b=New('张三',a.disk);assert(Key(b)~=legacy);assert(b.P:PrepareRead('v3.audit'));assert(b.value.marker=='legacy-A')
    assert(b.store.dirty and b.writes==0 and b.store.resolvedKey==Key(b));assert(b.P:Flush())
    assert(b.writeKeys[legacy]==nil and Equal(before,b.disk[legacy]));assert(b.disk[Key(b)])
    local c=New('张三',a.disk);assert(c.P:PrepareRead('v3.audit'));assert(c.value.marker=='legacy-A')
    assert(c.readKeys[legacy]==nil,'new key did not take priority')
end)
Test('trusted foreign legacy remains untouched while second character starts fresh',function()
    local a,legacy=SavedLegacy('张三','A');local before=Copy(a.disk[legacy]);local b=New('李四',a.disk)
    assert(LegacyKey(b)==legacy);assert(b.P:PrepareRead('v3.audit'));assert(b.value.marker=='default');Save(b,'B')
    assert(b.writeKeys[legacy]==nil and Equal(before,b.disk[legacy]))
    local aa=New('张三',a.disk);assert(aa.P:PrepareRead('v3.audit'));assert(aa.value.marker=='A')
    local bb=New('李四',a.disk);assert(bb.P:PrepareRead('v3.audit'));assert(bb.value.marker=='B')
end)
for _,kind in ipairs({'unstamped','scope_stamp_missing','bad_envelope','bad_payload','foreign_bad_payload','read_error'})do
    Test('unprovable legacy fails closed: '..kind,function()
        local a,legacy=SavedLegacy('张三','A')
        if kind=='unstamped'then a.disk[legacy]={marker='old-unowned'}
        elseif kind=='scope_stamp_missing'then Alter(a,legacy,function(raw)raw.__rsmeta.scopeIdentityFingerprint=nil end,true)
        elseif kind=='bad_envelope'then Alter(a,legacy,function(raw)raw.__rsmeta.envelopeFingerprint='BAD' end,false)
        elseif kind~='read_error'then Alter(a,legacy,function(raw)raw.payload.marker='damaged' end,false)end
        local b=New(kind=='foreign_bad_payload'and'李四'or'张三',a.disk);if kind=='read_error'then b.loadErrors[legacy]='offline read failure'end
        local before=Copy(b.disk);local ok=b.P:PrepareRead('v3.audit');assert(not ok,'unverified legacy became defaults or trusted data')
        assert(b.applies==0 and b.writes==0 and b.store.writeFenced and Equal(before,b.disk))
        assert(b.P:SaveStore('v3.audit',{durable=true})==false);assert(b.writes==0)
    end)
end
Test('current new key wins even when stale legacy is malformed',function()
    local h=New('张三');assert(h.P:PrepareRead('v3.audit'));Save(h,'new-A');local legacy=LegacyKey(h)
    assert(Key(h)~=legacy);h.disk[legacy]='malformed stale source'
    local b=New('张三',h.disk);assert(b.P:PrepareRead('v3.audit'));assert(b.value.marker=='new-A');assert(b.readKeys[legacy]==nil)
end)
Test('corrupt current new key never falls back to healthy legacy',function()
    local h,legacy=SavedLegacy('张三','old-A');h.disk[Key(h)]=Copy(h.disk[legacy]);Alter(h,Key(h),function(raw)raw.payload.marker='damaged'end,false)
    local b=New('张三',h.disk);assert(not b.P:PrepareRead('v3.audit'));assert(b.readKeys[legacy]==nil and b.applies==0)
end)
for _,kind in ipairs({'metadata_missing','scope_missing','scope_stamp_missing','owner_wrong','payload_truncated',
    'foreign','bare_legacy_payload','business_stamp_missing','envelope_stamp_missing','all_stamps_missing'})do
    Test('new v2 current archive cannot enter unstamped legacy compatibility: '..kind,function()
        local h=New('张三');assert(h.P:PrepareRead('v3.audit'));Save(h,'A');local key=Key(h)
        -- 只破坏内存当前新键；即便旧候选仍存在，当前键损坏也必须拒绝，不能认空/恢复默认或回读旧源。
        h.disk[LegacyKey(h)]=Copy(h.disk[key])
        if kind=='metadata_missing'then h.disk[key].__rsmeta=nil
        elseif kind=='payload_truncated'then h.disk[key]={payload='truncated'}
        elseif kind=='bare_legacy_payload'then h.disk[key]={marker='legacy-body'}
        elseif kind=='foreign'then
            local foreign=New('李四');assert(foreign.P:PrepareRead('v3.audit'));Save(foreign,'B');h.disk[key]=Copy(foreign.disk[Key(foreign)])
        else Alter(h,key,function(raw)
            if kind=='scope_missing'then raw.__rsmeta.scope=nil
            elseif kind=='scope_stamp_missing'then raw.__rsmeta.scopeIdentityFingerprint=nil
            elseif kind=='owner_wrong'then raw.__rsmeta.owner='v3.foreign'
            elseif kind=='business_stamp_missing'then raw.__rsmeta.encodedFingerprint=nil;raw.__rsmeta.payloadFingerprint=nil
            elseif kind=='envelope_stamp_missing'then raw.__rsmeta.envelopeFingerprint=nil
            elseif kind=='all_stamps_missing'then
                for _,field in ipairs({'reliabilityContract','integrityVersion','encodedFingerprint','payloadFingerprint',
                    'envelopeIntegrityVersion','envelopeFingerprint','scopeBindingContract','scopeIdentityFingerprint'})do raw.__rsmeta[field]=nil end
            end
        end,kind~='envelope_stamp_missing'and kind~='all_stamps_missing')end
        local before=Copy(h.disk);local cold=New('张三',h.disk)
        assert(not cold.P:PrepareRead('v3.audit'),'new v2 current archive silently used unstamped compatibility')
        assert(cold.applies==0 and cold.writes==0 and cold.store.writeFenced and Equal(before,cold.disk))
        assert(cold.readKeys[LegacyKey(cold)]==nil,'damaged current archive fell back to old source')
    end)
end
for _,scope in ipairs({'Character','Account'})do
    Test('plain ASCII and Account retain historical bare archive compatibility: '..scope,function()
        local h=New('Alice',nil,scope);h.disk[Key(h)]={marker='legacy-A'}
        assert(h.P:PrepareRead('v3.audit'));assert(h.value.marker=='legacy-A'and h.writes==0)
    end)
end
for _,field in ipairs({'owner','store','scope','schema','scopeBindingContract','reliabilityContract'})do
    Test('legacy migration refuses incompatible metadata: '..field,function()
        local h,legacy=SavedLegacy('张三','A')
        Alter(h,legacy,function(raw)
            raw.__rsmeta[field]=(field=='owner'or field=='store')and'v3.foreign'
                or(field=='scope'and'Account'or 99)
        end,true)
        local b=New('张三',h.disk);local before=Copy(b.disk)
        assert(not b.P:PrepareRead('v3.audit'));assert(b.applies==0 and b.writes==0 and Equal(before,b.disk))
    end)
end
Test('foreign decoder explicit error cannot authorize a new default archive',function()
    local h=SavedLegacy('张三','A');local b=New('李四',h.disk)
    b.store.decode=function(raw)return Copy(raw.payload),'explicit invalid content'end
    assert(not b.P:PrepareRead('v3.audit'));assert(b.applies==0 and b.writes==0 and b.store.writeFenced)
end)
Test('owned corrupt legacy can still be explicitly rebuilt only into the new key',function()
    local h,legacy=SavedLegacy('张三','A');Alter(h,legacy,function(raw)raw.payload.marker='damaged'end,false)
    local b=New('张三',h.disk);b.store.recoverableReplacement=true;local before=Copy(b.disk[legacy])
    assert(not b.P:PrepareRead('v3.audit'));assert(b.P:CanReplaceCorrupt('v3.audit'))
    local ok,err=b.P:SaveValue('v3.audit',{marker='rebuilt'},{replaceCorrupt=true,allowUnloadedWrite=true,durable=true})
    assert(ok,tostring(err));assert(b.writeKeys[legacy]==nil and Equal(before,b.disk[legacy]))
    local c=New('张三',h.disk);assert(c.P:PrepareRead('v3.audit'));assert(c.value.marker=='rebuilt')
end)
Test('clear after legacy migration cannot resurrect legacy content after cold load',function()
    local h,legacy=SavedLegacy('张三','legacy-A');local b=New('张三',h.disk);b.allowClear=true
    assert(b.P:PrepareRead('v3.audit'));assert(b.P:Flush());local before=Copy(b.disk[legacy])
    local cleared,err=b.P:ClearStore('v3.audit');assert(cleared,tostring(err));assert(b.value.marker=='default')
    assert(b.clears==0 and b.disk[Key(b)]~=nil,'clear removed authoritative new key instead of persisting default proof')
    assert(b.writeKeys[legacy]==nil and Equal(before,b.disk[legacy]));assert(b.store.lastVerifyOk and not b.store.needsBarrierVerify)
    local c=New('张三',h.disk);assert(c.P:PrepareRead('v3.audit'));assert(c.value.marker=='default')
    assert(c.readKeys[legacy]==nil,'cold clear consulted retired legacy source')
end)
for _,mode in ipairs({'reject','drop'})do
    Test('failed clear default proof protects original Domain and both keys: '..mode,function()
        local h,legacy=SavedLegacy('张三','legacy-A');local b=New('张三',h.disk);b.allowClear=true
        assert(b.P:PrepareRead('v3.audit'));assert(b.P:Flush());local before=Copy(b.disk);local applies=b.applies
        b.saveMode=mode;local cleared=b.P:ClearStore('v3.audit');assert(not cleared,'failed default proof reported clear success')
        assert(b.value.marker=='legacy-A'and b.applies==applies and b.clears==0 and Equal(before,b.disk))
        assert(b.store.writeFenced and not b.P:IsStoreLoaded('v3.audit'),'failed clear remained ready for stale writes')
        local c=New('张三',h.disk);assert(c.P:PrepareRead('v3.audit'));assert(c.value.marker=='legacy-A')
    end)
end
Test('clear cannot claim an unstamped legacy source',function()
    local h=New('张三');h.disk[LegacyKey(h)]={marker='legacy-unowned'};h.allowClear=true;local before=Copy(h.disk)
    assert(not h.P:ClearStore('v3.audit'));assert(h.applies==0 and h.writes==0 and h.clears==0 and Equal(before,h.disk))
end)
for _,initialIdentity in ipairs({'张三','Alice'})do
    for _,drift in ipairs({'unavailable','Bob','李四'})do
        Test('clear rechecks complete bound identity before choosing physical path: '..initialIdentity..' -> '..drift,function()
            local source=SavedLegacy(initialIdentity,'original-A');local h=New(initialIdentity,source.disk);h.allowClear=true
            assert(h.P:PrepareRead('v3.audit'));assert(h.P:Flush());local before=Copy(h.disk)
            local reads,writes,applies=h.reads,h.writes,h.applies;local calls=0
            -- PrepareWrite 的两次读取仍是 A；只有清空分支选择时 Native 身份失效或变更，不能退成“无旧候选”。
            function ReplicatedSuite.Api:CallCapability(cap,obj,method,unit)
                assert(cap=='X2Unit:UnitNameWithWorld'and unit=='player');calls=calls+1
                if calls<=2 then return true,initialIdentity end
                return true,drift~='unavailable'and drift or nil
            end
            assert(not h.P:ClearStore('v3.audit'),'identity drift silently selected physical deletion')
            assert(h.clears==0 and h.reads==reads and h.writes==writes and h.applies==applies and Equal(before,h.disk))
            local cold=New(initialIdentity,h.disk);assert(cold.P:PrepareRead('v3.audit'));assert(cold.value.marker=='original-A')
        end)
    end
end
Test('clear Apply failure fences stale Domain after durable default proof',function()
    local h=New('张三');assert(h.P:PrepareRead('v3.audit'));Save(h,'A');h.allowClear=true
    h.store.apply=function()error('synthetic default apply refusal')end
    assert(not h.P:ClearStore('v3.audit'));assert(h.value.marker=='A'and h.store.writeFenced)
    assert(not h.P:MarkDirty('v3.audit',0,'stale_domain'),'failed Apply can overwrite durable default proof')
    local c=New('张三',h.disk);assert(c.P:PrepareRead('v3.audit'));assert(c.value.marker=='default')
end)
Test('clear applyDefault false persists proof and requires later read before mutation',function()
    local h=New('张三');assert(h.P:PrepareRead('v3.audit'));Save(h,'A');h.allowClear=true;local applies=h.applies
    assert(h.P:ClearStore('v3.audit',{applyDefault=false}));assert(h.value.marker=='A'and h.applies==applies)
    assert(not h.P:IsStoreLoaded('v3.audit')and h.store.loadStatus~='empty','old Domain was mislabeled authoritative or disk missing')
    assert(h.P:PrepareRead('v3.audit'));assert(h.value.marker=='default')
end)
for _,pending in ipairs({'dirty','unverified'})do
    Test('explicit clear supersedes pending old state only after default proof: '..pending,function()
        local h=New('张三');assert(h.P:PrepareRead('v3.audit'));Save(h,'A');h.allowClear=true
        if pending=='dirty'then h.value.marker='A-unsaved';assert(h.P:MarkDirty('v3.audit',0,'audit'))
        else h.value.marker='A-unverified';assert(h.P:SaveStore('v3.audit'));assert(h.store.needsBarrierVerify)end
        assert(h.P:ClearStore('v3.audit'));assert(h.value.marker=='default'and not h.store.dirty and not h.store.needsBarrierVerify)
        local c=New('张三',h.disk);assert(c.P:PrepareRead('v3.audit'));assert(c.value.marker=='default')
    end)
end
for _,scope in ipairs({'Character','Account'})do
    Test('plain ASCII and Account clear retain existing physical deletion: '..scope,function()
        local h=New('Alice',nil,scope);assert(h.P:PrepareRead('v3.audit'));Save(h,'A');h.allowClear=true;local writes=h.writes
        assert(h.P:ClearStore('v3.audit'));assert(h.clears==1 and h.writes==writes and h.disk[Key(h)]==nil)
        local c=New('Alice',h.disk,scope);assert(c.P:PrepareRead('v3.audit'));assert(c.value.marker=='default')
    end)
end
Test('dirty character cannot rebind before bound flush',function()
    local h=New('张三');assert(h.P:PrepareRead('v3.audit'));Save(h,'A1');h.value.marker='A2';assert(h.P:MarkDirty('v3.audit',0,'audit'))
    h.identity='李四';assert(not h.P:PrepareWrite('v3.audit'));assert(h.P:Flush());assert(h.P:PrepareRead('v3.audit'));Save(h,'B')
    local a=New('张三',h.disk);assert(a.P:PrepareRead('v3.audit'));assert(a.value.marker=='A2')
    local b=New('李四',h.disk);assert(b.P:PrepareRead('v3.audit'));assert(b.value.marker=='B')
end)
for _,identity in ipairs({false,0,{}})do
    Test('non-string Native identity stays scope pending: '..type(identity),function()
        local h=New(identity);local ok=h.P:PrepareRead('v3.audit');assert(not ok and h.store.loadStatus=='scope_pending')
        assert(h.reads==0 and h.writes==0 and h.applies==0);h.identity='Alice';assert(h.P:PrepareRead('v3.audit'))
    end)
end
Test('nil identity retries safely once Native identity is ready',function()
    local h=New(nil);assert(not h.P:PrepareRead('v3.audit'));assert(h.reads==0 and h.writes==0)
    h.identity='张三';assert(h.P:PrepareRead('v3.audit'));assert(h.value.marker=='default')
end)
print('CHARACTER_SCOPE_RESULT passed='..passed..' failed='..failed..' runtime='.._VERSION)
if failed>0 then error('character scope failures: '..failed)end

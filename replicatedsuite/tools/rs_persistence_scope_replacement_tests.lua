-- Replicated Suite · 角色存档完整替换边界回归
-- 作者：Replicated
-- QQ群：1104129461
-- 使用真实存档和寻宝命令，只替换原生磁盘与角色身份。
-- 错角色、错归属或未来版本的存档必须拒写，原始字节也不能变。
-- 只有归属完整匹配时，才允许显式重建损坏内容；旧角色键迁移另有用例。
local function Copy(value)
    if type(value) ~= 'table' then return value end
    local out={}; for k,v in pairs(value) do out[k]=Copy(v) end; return out
end
local function New(identity,disk)
    local h={identity=identity,disk=disk or {},reads=0,writes=0,applies=0,value={marker='default'}}
    X2Unit={}
    ReplicatedSuite={SaveKey='audit',NowMs=function()return 1000 end,Api={}}
    local S=ReplicatedSuite
    function S.Api:CallCapability(cap,obj,method,unit)
        assert(cap=='X2Unit:UnitNameWithWorld' and unit=='player')
        return true,h.identity
    end
    function S.Api:LoadData(key)h.reads=h.reads+1;return Copy(h.disk[key]) end
    function S.Api:SaveData(key,value)h.writes=h.writes+1;h.disk[key]=Copy(value);return true end
    function S.Api:ClearData()error('audit must never clear data')end
    dofile('core/rs_persistence_transport.lua')
    dofile('core/rs_persistence.lua')
    h.P=S.Persistence
    h.store=assert(h.P:RegisterV3Store({id='v3.audit',owner='v3.audit',scope=h.P.Scope.Character,
        lifetime=h.P.Lifetime.Permanent,schemaVersion=1,key=h.P.V3KeyPrefix..'identity',
        budget={maxDepth=5,maxNodes=256,maxStringBytes=4096,maxEntriesPerTable=32},
        get=function()return Copy(h.value)end,
        apply=function(value)h.applies=h.applies+1;h.value=Copy(value)end,
        default=function()return {marker='default'}end,
        migrate=function(value)return Copy(value)end}))
    return h
end
local passed,failed=0,0
local function Test(name,fn)
    local ok,err=pcall(fn)
    if ok then passed=passed+1;print('PASS '..name)
    else failed=failed+1;print('FAIL '..name..': '..tostring(err))end
end
local function Equal(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~='table' then return a==b end
    for k,v in pairs(a) do if not Equal(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end
    return true
end
local function AttachTreasure(h)
    local S=ReplicatedSuite
    S.LifeSliceFactory={Copy=Copy,Call=function()error('unexpected Native call')end,
        Action=function()error('unexpected Native action')end,PublishFeatureUpdate=function()end}
    h.F={enabled=true,Commands={},ApiDependencies={},Authority={revision=0,maps={}}}
    S.Features={Treasure=h.F}
    dofile('features/life/treasure/rs_treasure_inventory.lua')
    h.I=h.F.Inventory
end
Test('recoverable replacement rejects another character fingerprint without writing',function()
    local a=New('张三@World');assert(a.P:LoadStore('v3.audit')=='empty')
    a.value.marker='A';assert(a.P:SaveStore('v3.audit',{durable=true}))
    local b=New('李四@World',a.disk);b.store.recoverableReplacement=true
    -- 不依赖已修复的有损键碰撞：主动把 A 的健康外壳放入 B 当前键，继续验证身份章阻止完整替换。
    b.disk[assert(b.P:ResolveStoreKey('v3.audit'))]=Copy(a.disk[assert(a.P:ResolveStoreKey('v3.audit'))])
    local loaded,_,loadErr=b.P:LoadStore('v3.audit')
    assert(loaded==false and loadErr=='envelope_integrity_failed:scope_identity_fingerprint')
    local before=Copy(b.disk)
    local saved,saveErr=b.P:SaveValue('v3.audit',{marker='B-reset'},
        {replaceCorrupt=true,allowUnloadedWrite=true,durable=true,reason='treasure_coffer_round_reset_corrupt'})
    assert(saved==false,'foreign identity replacement must be refused')
    assert(b.writes==0 and b.store.writeFenced==true and Equal(before,b.disk),'rejected replacement changed disk')
    local c=New('张三@World',a.disk);local original,_,originalErr=c.P:LoadStore('v3.audit')
    assert(original==true,tostring(originalErr));assert(c.value.marker=='A')
    print('  replace-saved='..tostring(saved)..' writes='..b.writes..' original-owner='..tostring(original))
end)
Test('production Treasure ResetCofferRound refuses collided character inventory',function()
    local a=New('张三@World');AttachTreasure(a);assert(a.I:Initialize())
    a.I.State.boxes['1']={records=0,chunks={},stamp='record-A'}
    assert(a.P:SaveStore(a.I.storeId,{durable=true}))
    local b=New('李四@World',a.disk);AttachTreasure(b)
    -- 生产命令仍面对真正 foreign 当前档，而非新键隔离后应当合法创建的空角色档。
    b.disk[assert(b.P:ResolveStoreKey(b.I.storeId))]=Copy(a.disk[assert(a.P:ResolveStoreKey(a.I.storeId))])
    local ready,loadErr=b.I:Initialize()
    assert(ready==false and loadErr=='envelope_integrity_failed:scope_identity_fingerprint')
    local before=Copy(b.disk)
    local reset,resetErr=b.F.Commands.ResetCofferRound()
    assert(reset==false,'production reset must reject foreign identity')
    assert(b.writes==0 and Equal(before,b.disk),'production rejected reset changed disk')
    local c=New('张三@World',a.disk);AttachTreasure(c)
    local original,originalErr=c.I:Initialize()
    assert(original==true,tostring(originalErr));assert(c.I.State.boxes['1'].stamp=='record-A')
    print('  production-command-reset='..tostring(reset)..' writes='..b.writes..' original-owner='..tostring(original))
end)
local function Saved()
    local h=New('张三@World');h.store.recoverableReplacement=true
    assert(h.P:LoadStore('v3.audit')=='empty');h.value.marker='A'
    assert(h.P:SaveStore('v3.audit',{durable=true}))
    return h,assert(h.P:ResolveStoreKey('v3.audit'))
end
local function Alter(h,key,fn,seal)
    local raw=assert(h.P:DecodePhysicalEnvelope(Copy(h.disk[key])))
    fn(raw)
    if seal then raw.__rsmeta.envelopeFingerprint=assert(h.P:FingerprintEnvelopeIntegrity(raw))end
    h.disk[key]=assert(h.P:EncodePhysicalEnvelope(raw))
end
local replacement={replaceCorrupt=true,allowUnloadedWrite=true,durable=true}
local function Rejected(h,key)
    local before,writes=Copy(h.disk),h.writes
    local allowed=h.P:CanReplaceCorrupt('v3.audit');assert(allowed==false,'unsafe replacement was authorized')
    local saved,err=h.P:SaveValue('v3.audit',{marker='replacement'},replacement)
    assert(saved==false,'unsafe replacement saved: '..tostring(err))
    assert(h.writes==writes and Equal(before,h.disk),'unsafe replacement changed disk')
end
for _,entry in ipairs({{'store','v3.foreign'},{'owner','v3.foreign'},{'scope','Account'},{'lifetime','Daily'},
    {'framework',4},{'contractVersion',4},{'schema',2},{'reliabilityContract',9},
    {'integrityVersion',5},{'envelopeIntegrityVersion',2},{'scopeBindingContract',2}})do
    Test('replacement rejects metadata '..entry[1],function()
        local a,key=Saved();Alter(a,key,function(raw)raw.__rsmeta[entry[1]]=entry[2]end,true)
        local b=New('张三@World',a.disk);b.store.recoverableReplacement=true
        assert(b.P:LoadStore('v3.audit')==false);Rejected(b,key)
    end)
end
Test('future transport is refused without rewriting disk',function()
    local a,key=Saved();a.disk[key].__rsmeta.transportVersion=7
    local b=New('张三@World',a.disk);b.store.recoverableReplacement=true
    assert(b.P:LoadStore('v3.audit')==false);Rejected(b,key)
end)
for _,field in ipairs({'owner','schema','scopeIdentityFingerprint'})do
    Test('transport corruption cannot conceal forbidden '..field,function()
        local a,key=Saved();Alter(a,key,function(raw)
            raw.__rsmeta[field]=field=='schema' and 2 or 'foreign'
        end,true)
        a.disk[key].payload.marker='__rs_t3:unknown'
        local b=New('张三@World',a.disk);b.store.recoverableReplacement=true
        assert(b.P:LoadStore('v3.audit')==false);Rejected(b,key)
    end)
end
Test('same-generation identity switch cannot replace foreign current key',function()
    local h,key=Saved();local before=Copy(h.disk);h.identity='李四@World'
    -- 干净身份切换本身已可安全重新绑定；只有新绑定键内确实存在另一角色档时才应终态拒绝。
    h.disk[assert(h.P:ResolveStoreKey('v3.audit'))]=Copy(h.disk[key]);before=Copy(h.disk)
    assert(h.P:LoadStore('v3.audit')==false);Rejected(h,key);assert(Equal(before,h.disk))
end)
Test('ownership proof from older load is discarded when current raw has no metadata',function()
    local h,key=Saved();h.disk[key]='truncated'
    assert(h.P:LoadStore('v3.audit')==false);Rejected(h,key)
end)
for _,kind in ipairs({'payload','transport','envelope_fingerprint','payload_fingerprint'})do
    Test('same owner content recovery remains valid: '..kind,function()
        local a,key=Saved()
        if kind=='transport' then a.disk[key].payload.marker='__rs_t3:unknown'
        else Alter(a,key,function(raw)
            if kind=='payload' then raw.payload.marker='truncated'
            elseif kind=='envelope_fingerprint' then raw.__rsmeta.envelopeFingerprint='00000000'
            else raw.__rsmeta.encodedFingerprint='00000000'end
        end,kind=='payload_fingerprint')end
        local b=New('张三@World',a.disk);b.store.recoverableReplacement=true
        assert(b.P:LoadStore('v3.audit')==false)
        local reads=b.reads;assert(b.P:CanReplaceCorrupt('v3.audit')==true,'same-owner content not authorized')
        assert(b.reads==reads,'authorization query performed disk IO')
        local saved,err=b.P:SaveValue('v3.audit',{marker='rebuilt'},replacement);assert(saved,tostring(err))
        assert(b.writes==1 and b.store.writeFenced==false and b.store.lastVerifyOk==true)
        local c=New('张三@World',a.disk);assert(c.P:LoadStore('v3.audit')==true);assert(c.value.marker=='rebuilt')
    end)
end
Test('production Treasure reset still rebuilds its own truncated snapshot',function()
    local a=New('张三@World');AttachTreasure(a);assert(a.I:Initialize())
    a.I.State.boxes['1']={records=1,chunks={'1|2|3|1|map\n'},stamp='A'}
    assert(a.P:SaveStore(a.I.storeId,{durable=true}))
    local key=assert(a.P:ResolveStoreKey(a.I.storeId))
    a.disk[key].payload.boxes['1'].chunks[1]='truncated'
    local b=New('张三@World',a.disk);AttachTreasure(b)
    assert(b.I:Initialize()==false);assert(b.P:CanReplaceCorrupt(b.I.storeId)==true)
    local saved,err=b.F.Commands.ResetCofferRound();assert(saved,tostring(err))
    assert(b.writes==1 and b.I.loaded and b.I.State.scanRound and next(b.I.State.boxes)==nil)
end)
print('SCOPE_REPLACEMENT_RESULT passed='..passed..' failed='..failed..' runtime='.._VERSION)
if failed>0 then error('scope replacement regression failures: '..failed)end

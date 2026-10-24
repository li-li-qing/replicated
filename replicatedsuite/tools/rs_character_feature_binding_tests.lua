------------------------------------------------------------------------
-- Replicated Suite · 角色消费者绑定回归
-- 作者：Replicated
-- QQ群：1104129461
-- 中文维护：真实 Core/Transport 与消费者，Native 身份及磁盘为内存替身；同代切角不能沿用上一角色的 loaded 或收入基线。
-- 开发期离线测试，不进入运行时 TOC，也不访问真实 UDF。
------------------------------------------------------------------------
local passed,failed=0,0
local function Copy(v)if type(v)~='table'then return v end;local o={};for k,x in pairs(v)do o[k]=Copy(x)end;return o end
local function Test(name,fn)local ok,e=xpcall(fn,debug.traceback);if ok then passed=passed+1;print('PASS character-feature '..name)else failed=failed+1;print('FAIL character-feature '..name..': '..tostring(e))end end
local function Boot(kind)
    local h={identity='ScopeAlpha',disk={},reads=0,writes=0}
    X2Unit={};ReplicatedSuite={SaveKey='binding_test',NowMs=function()return 1000 end,Api={},Features={},
        FeatureRuntime={RegisterImplementation=function()return true end},
        Utils={GetServerTime=function()return{year=2026,month=10,day=24,hour=12,minute=0}end}}
    local S=ReplicatedSuite;h.S=S
    function S.Api:CallCapability()return true,h.identity end
    function S.Api:LoadData(key)h.reads=h.reads+1;return Copy(h.disk[key])end
    function S.Api:SaveData(key,v)h.writes=h.writes+1;h.disk[key]=Copy(v);return true end
    function S.Api:ClearData()error('binding regression must never clear saves')end
    dofile('core/rs_persistence_transport.lua');dofile('core/rs_persistence.lua');h.P=S.Persistence
    if kind=='ledger' then
        dofile('features/life/rs_daily_ledger.lua');h.F=S.Features.DailyLedger;local f=h.F
        assert(f:EnsureStoreLoaded());f.State.day='2026-10-24'
        f.State.channels.gold.net,f.State.channels.gold.gain,f.State.channels.gold.samples=123,123,1
        assert(h.P:SaveStore(f.StoreId,{durable=true}))
        assert(f:RegisterSource('gold',{id='test-balance',verified=true,evidence='isolated Native receipt',unit='copper',mode='balance'}))
        f.enabled,f.clockAvailable=true,true;f.sessions.gold={sequence=20,value=900}
    else
        S.LifeSliceFactory={Copy=Copy,Call=function()error('unexpected Native inventory read')end,
            Action=function()error('unexpected Native inventory action')end,PublishFeatureUpdate=function()end}
        h.F={Id='life_treasure',enabled=true,Commands={},ApiDependencies={},Authority={revision=0,maps={}}};S.Features.Treasure=h.F
        function h.F.Authority:GetProjection()return{viewKind='maps',status='empty',selected=Copy(self.selected)}end
        dofile('features/life/treasure/rs_treasure_inventory.lua');h.I=h.F.Inventory
        assert(h.I:Initialize());h.I.State.filter='west';h.I.State.boxes['1']={records=0,chunks={},stamp='A'}
        assert(h.P:SaveStore(h.I.storeId,{durable=true}))
    end
    return h
end
Test('daily projection hides old totals while a different identity is current',function()
    local h=Boot('ledger');assert(h.F:GetProjection().rows[1].value==123)
    h.identity='ScopeBeta';local p=h.F:GetProjection()
    assert(p.rows[1].value==nil and p.day==nil,'previous character income is still visible')
end)
Test('daily loaded cache rebinds and clears the previous receipt sequence',function()
    local h=Boot('ledger');h.identity='ScopeBeta';assert(h.F:EnsureStoreLoaded())
    assert(h.F.State.channels.gold.net==0 and h.F.sessions.gold==nil,'daily cache kept previous character state or balance baseline')
end)
Test('first new-character balance does not use another character receipt baseline',function()
    local h=Boot('ledger');h.identity='ScopeBeta'
    assert(h.F:Observe('gold',40,'test-balance',1),'old sequence rejected the new character first receipt')
    assert(h.F.State.channels.gold.net==0,'old balance was counted as new character income')
    assert(h.F:Observe('gold',50,'test-balance',2));assert(h.F.State.channels.gold.net==10)
end)
Test('pending daily identity hides totals without applying defaults or writing data',function()
    local h=Boot('ledger');local reads,writes=h.reads,h.writes;h.identity=nil
    local p=h.F:GetProjection();assert(p.rows[1].value==nil and p.day==nil)
    assert(h.F.State.channels.gold.net==123 and h.reads==reads and h.writes==writes)
end)
Test('returning to a character does not count balance changes across an observation gap',function()
    local h=Boot('ledger');h.F.sources.gold.continuousBalance=true
    h.F.State.channels.gold.balance=900;assert(h.P:SaveStore(h.F.StoreId,{durable=true}))
    h.identity='ScopeBeta';assert(h.F:EnsureStoreLoaded())
    h.identity='ScopeAlpha';assert(h.F:EnsureStoreLoaded())
    assert(h.F:Observe('gold',950,'test-balance',1))
    assert(h.F.State.channels.gold.net==123,'off-character balance gap was counted as observed income')
    assert(h.F.State.channels.gold.coverageGap==true)
end)
Test('projection-only character roundtrip also invalidates old balance receipts',function()
    local h=Boot('ledger');h.F.sources.gold.continuousBalance=true
    h.identity='ScopeBeta';assert(h.F:GetProjection().rows[1].value==nil)
    h.identity='ScopeAlpha';assert(h.F:Observe('gold',950,'test-balance',21))
    assert(h.F.State.channels.gold.net==123,'observed role change did not invalidate old receipt baseline')
end)
Test('treasure loaded cache rebinds instead of returning previous coffer records',function()
    local h=Boot('treasure');h.identity='ScopeBeta';assert(h.I:Initialize())
    assert(h.I.State.filter=='all' and next(h.I.State.boxes)==nil,'treasure cache kept previous character coffer state')
end)
Test('treasure projection rebinds before copying an old catalog selection',function()
    local h=Boot('treasure');h.F.Authority.selected={kind='catalog',worldX=100,worldY=200,count=99}
    h.identity='ScopeBeta';local p=h.F.Authority:GetProjection()
    assert(p.region=='all' and p.selected==nil,'old inventory filter or catalog selection survived character change')
end)
Test('treasure projection drops old character bag rows during inventory rebinding',function()
    local h=Boot('treasure');h.F.Authority.maps={{worldX=100,worldY=200,count=99}}
    h.I:RebuildGroups();h.identity='ScopeBeta';local p=h.F.Authority:GetProjection()
    assert(p.totalMapCount==0 and #p.rows==0,'previous character bag cache was mixed into new inventory')
end)
Test('pending treasure identity preserves storage but cancels stale interaction state',function()
    local h=Boot('treasure');h.I.bound={id='1'};h.I.openRecord={id='1'};h.identity=nil
    local writes=h.writes;assert(h.I:Initialize()==false,'missing identity reused a ready inventory')
    assert(h.I.State.boxes['1'].stamp=='A' and h.writes==writes,'pending scope mutated persistent state')
    assert(h.I.bound==nil and h.I.openRecord==nil,'old character coffer interaction remained active')
end)
print(string.format('CHARACTER FEATURE BINDING RESULT %d passed / %d failed (%s)',passed,failed,_VERSION))
assert(failed==0,'character feature binding failures: '..failed)

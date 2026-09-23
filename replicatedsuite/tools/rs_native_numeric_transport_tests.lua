-- 维护（2026-09-18，startup-source-recovery）：本文件在故障包中有 1 处未解决的 Git 合并冲突。
-- 已对照用户此前完整 V3 工程恢复有效实现；Authority、调用数据流和存档协议仍由下方原实现负责，
-- 不通过清配置、跳过加载或恢复 Legacy 绕过错误。兼容边界：须与完整 toc.g 及 .18.247 UI 配套；
-- 后续合并必须先检查冲突标记、清单完整性与 Lua 语法，再做运行时验收；注释不增加运行期开销。
-- 维护（2026-09-12）：Core已支持物理4，未知版本拒绝样本改5；旧精度/破损拒绝断言保持。
-- 维护：真实取证 fixture + 独立构造的 Native 数值降精度测试。此工具不进 TOC。
-- Authority：生产 Store/Persistence/API 原样加载；仅存储为内存盘，不代表 RU 客户端实测。
-- 原始 fixture 没有修改指纹；数值转换模型是对证据的可复现实验，非客户端源码结论。
local passed,failed=0,0
local function Test(name,fn)
    local ok,err=pcall(fn)
    if ok then passed=passed+1;print('PASS numeric '..name)
    else failed=failed+1;print('FAIL numeric '..name..': '..tostring(err)) end
end
local function Copy(v)
    if type(v)~='table' then return v end
    local t={};for k,x in pairs(v) do t[Copy(k)]=Copy(x) end;return t
end
local function Eq(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~='table' then return a==b end
    for k,v in pairs(a) do if not Eq(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end
    return true
end
local function F32(v)
    if v==0 then return v end
    local sign=v<0 and -1 or 1;v=math.abs(v)
    local _,e=math.frexp(v);local step=2^(math.max(e-24,-149))
    local n=v/step;local f=math.floor(n);local r=n-f
    if r>0.5 or (r==0.5 and f%2==1) then f=f+1 end
    local result=sign*f*step
    -- Lua5.4 harness: Native small integer metadata must print like Lua5.1, not "3.0".
    if result==math.floor(result) then return math.floor(result) end
    return result
end
local function NativeLoss(v)
    if type(v)=='number' then return F32(tonumber(string.format('%.6f',v))) end
    if type(v)~='table' then return v end
    local t={};for k,x in pairs(v) do t[NativeLoss(k)]=NativeLoss(x) end;return t
end
local function Boot(disk,loss)
    local io={disk=disk or {},reads=0,writes=0,clears=0}
    ADDON={LoadData=function(_,k) io.reads=io.reads+1;return Copy(io.disk[k]) end,
        SaveData=function(_,k,v)io.writes=io.writes+1;io.disk[k]=loss and NativeLoss(v) or Copy(v);return true end,
        ClearData=function()io.clears=io.clears+1;error('must not clear saves')end}
    ReplicatedSuite={Features={},Services={},UI={CreateWindowShell=function()error('no native windows')end},RSUI={},
        NowMs=function()return 1000 end,FeatureRuntime={RegisterImplementation=function()return true end}}
    local S=ReplicatedSuite
    dofile('core/rs_utils.lua');dofile('core/rs_reuse.lua');dofile('core/rs_demand.lua')
    dofile('core/rs_api.lua');dofile('core/rs_api_capabilities.lua');dofile('core/rs_persistence.lua')
    dofile('ui/framework/rs_ui_floating_surface.lua')
    dofile('features/combat/buff_display/rs_buff_display_store.lua')
    dofile('features/combat/death_review/rs_death_review_store.lua')
    dofile('features/life/rs_life_m16_bundle.lua')
    return S,S.Persistence,io
end
local fixture=dofile('tools/fixtures/trade_native_numeric_20260912.lua')
local function Actual()
    local S,P,io=Boot(nil,true);local st=P:GetStore(fixture.store);local key=P:ResolveStoreKey(st)
    io.disk[key]=Copy(fixture.raw);return S,P,io,st,key
end
local function FP(P,st,v) return assert(P:FingerprintCanonicalValue(st,assert(P:CanonicalIntegrityValue(st,v)))) end
local function Reseal(P,raw)
    raw.__rsmeta.envelopeFingerprint=assert(P:FingerprintEnvelopeIntegrity(raw));return assert(P:EncodePhysicalEnvelope(raw))
end
Test('actual snapshot independently reproduces both observed current and stored hashes',function()
    local _,P,io,st,key=Actual();local raw=assert(P:DecodePhysicalEnvelope(io.disk[key]))
    assert(P:FingerprintEnvelopeIntegrity(raw)==raw.__rsmeta.envelopeFingerprint)
    assert(FP(P,st,raw.payload)=='48B0E072')
    local c=Copy(raw.payload);c.widgetWindow.normalizedCenterX=0.0903896
    assert(FP(P,st,c)=='6BE9E557' and FP(P,st,c)==raw.__rsmeta.encodedFingerprint)
    assert(Eq(NativeLoss(c),raw.payload),'six fractional digits -> f32 model differs from real snapshot')
end)
Test('actual legacy trade loads via exact numeric token recovery without disk writes',function()
    local _,P,io,st,key=Actual();local old=Copy(io.disk[key]);local ok,_,err=P:LoadStore(st.id)
    assert(ok==true,err);assert(not st.writeFenced)
    assert(st.get().widgetWindow.normalizedCenterX==0.0903896)
    assert(FP(P,st,st.get())=='6BE9E557')
    assert(io.writes==0 and io.clears==0 and Eq(io.disk[key],old),'load mutated original evidence')
    assert(st.dirty and st.lastDirtyReason=='transport_representation_upgrade','must queue lossless format upgrade')
end)
Test('recovered actual trade durable save and fresh reload keep every other field',function()
    local _,P,io,st,key=Actual();assert(P:LoadStore(st.id));local expected=st.get()
    local ok,why=P:SaveStore(st.id,{force=true,durable=true});assert(ok,why)
    assert(io.disk[key].__rsmeta.transportVersion==3)
    local _,fresh,fio=Boot(io.disk,true);local loaded,_,err=fresh:LoadStore(st.id);assert(loaded,err)
    assert(Eq(expected,fresh:GetStore(st.id).get()) and fio.writes==0)
    local before=assert(P:DecodePhysicalEnvelope(fixture.raw)).payload
    expected.widgetWindow.normalizedCenterX=before.widgetWindow.normalizedCenterX
    assert(Eq(before,expected),'unrelated saved preference changed')
end)
for _,kind in ipairs({'route','widget','stamp','owner','schema'}) do
    Test('actual recovery rejects changed '..kind..' without apply or save',function()
        local _,P,io,st,key=Actual();local raw=assert(P:DecodePhysicalEnvelope(io.disk[key]))
        if kind=='route' then raw.payload.toZone=6
        elseif kind=='widget' then raw.payload.widgetWindow.width=390
        elseif kind=='stamp' then raw.__rsmeta.encodedFingerprint='00000000'
        elseif kind=='owner' then raw.__rsmeta.owner='not.trade'
        else raw.__rsmeta.schema=2 end
        io.disk[key]=Reseal(P,raw);local applied=0;st.apply=function()applied=applied+1 end
        local ok=P:LoadStore(st.id)
        assert(not ok and st.writeFenced and applied==0 and io.writes==0 and io.clears==0)
    end)
end
Test('numeric recovery helper is schema and transport gated; never touches transport3',function()
    local _,P,_,st=Actual();assert(type(st.rebuildCanonicalForIntegrity)=='function','missing bridge')
    local raw=assert(P:DecodePhysicalEnvelope(fixture.raw));raw.__rsmeta.transportVersion=3
    local r=st.rebuildCanonicalForIntegrity(raw.payload,'6BE9E557',Copy(raw.payload),raw)
    assert(r==nil)
end)
Test('numeric recovery is general for proven field not a user hash allowlist',function()
    local _,P,io,st,key=Actual();local raw=assert(P:DecodePhysicalEnvelope(fixture.raw))
    raw.payload.fromZone=9;raw.payload.widgetWindow.normalizedCenterX=0.0741236
    raw.__rsmeta.encodedFingerprint=FP(P,st,raw.payload)
    assert(raw.__rsmeta.encodedFingerprint~='6BE9E557')
    io.disk[key]=NativeLoss(Reseal(P,raw));local ok,_,err=P:LoadStore(st.id);assert(ok,err)
    assert(st.get().widgetWindow.normalizedCenterX==0.0741236)
end)
Test('non-normalized fields are not searched or guessed',function()
    local _,P,io,st,key=Actual();local raw=assert(P:DecodePhysicalEnvelope(fixture.raw))
    raw.payload.widgetWindow.backgroundOpacity=0.0712346
    raw.__rsmeta.encodedFingerprint=FP(P,st,raw.payload)
    io.disk[key]=NativeLoss(Reseal(P,raw));assert(not P:LoadStore(st.id))
    assert(st.writeFenced and io.writes==0)
end)
Test('transport3 exact scalar and key preservation under six decimals and f32',function()
    local _,P=Boot()
    assert(P.TransportContractVersion==3,'new physical transport not enabled')
    local values={0,false,'',{},true,0.0903896,0.074123649,1.23456789012345,-0.0903896,1e-20,16777217,9007199254740991,
        '__rs_t3:n0.123','__rs_t3:f','__rs_t2:f','中文',
        { [0.0903896]='float key',[16777217]='large integer key',['16777217']='string key',[1]='sequence'}}
    local raw={__rsmeta={framework=3,transportVersion=3},payload=values}
    local physical=assert(P:EncodePhysicalEnvelope(raw))
    assert(Eq(raw,assert(P:DecodePhysicalEnvelope(NativeLoss(physical)))))
    assert(type(physical.payload[11])=='string' and type(physical.payload[13])=='string')
end)
for _,version in ipairs({1,2}) do
    Test('legacy transport'..version..' stays readable and explicitly encodable',function()
        local _,P=Boot();local raw={__rsmeta={framework=3,transportVersion=version},payload={a=false,b={},c='__rs_t'..version..':f',d=12}}
        assert(Eq(raw,assert(P:DecodePhysicalEnvelope(assert(P:EncodePhysicalEnvelope(raw))))))
    end)
end
for _,token in ipairs({'nNaN','ninf','n1e999','n0x10','n 1','n1.000','wat'}) do
    Test('transport3 rejects malformed numeric or reserved token '..token,function()
        local _,P=Boot();local value,err=P:DecodePhysicalEnvelope({__rsmeta={framework=3,transportVersion=3},payload={a='__rs_t3:'..token}})
        assert(value==nil and err)
    end)
end
Test('transport3 key collision is rejected instead of overwriting user data',function()
    local _,P=Boot();local value,err=P:DecodePhysicalEnvelope({__rsmeta={framework=3,transportVersion=3},payload={a=1,
        ['__rs_t3:sa']=2}})
    assert(value==nil and err=='transport_key_collision_v3',tostring(err))
end)
Test('unsafe physical encode rejects nonfinite values before Native writes',function()
    local _,P,io=Boot();for _,v in ipairs({math.huge,-math.huge,0/0}) do
        local raw,err=P:EncodePhysicalEnvelope({__rsmeta={framework=3,transportVersion=3},payload={n=v}})
        assert(raw==nil and err)
    end;assert(io.writes==0)
end)
for _,id in ipairs({'v3.life.trade','v3.death_review','v3.buff_display'}) do
    Test(id..' future writes survive numeric-loss Native with exact get restored',function()
        local _,P,io=Boot(nil,true);local st=P:GetStore(id);assert(P:LoadStore(id)=='empty')
        local v=st.default();local ww={userMoved=true,coordinateSpace='logical-free-v2',x=33.1234567,y=49.23456789,
            width=600.123456789,height=420.123456789,fontScale=1.12345678,savedLogicalWidth=2560,savedLogicalHeight=1440,
            normalizedCenterX=0.0741236,normalizedCenterY=0.1951234,savedUiScale=1.000000001}
        if id=='v3.buff_display' then v.settings.plate.opacity=0.745612345;v.settings.plateScale=1.12345678;v.widgetWindow=ww
        else v.widgetWindow=ww end
        st.apply(v);local expected=st.get();local ok,err=P:SaveStore(id,{force=true,durable=true});assert(ok,err)
        local _,fresh,newio=Boot(io.disk,true);assert(fresh:LoadStore(id));assert(Eq(expected,fresh:GetStore(id).get()))
        assert(newio.writes==0)
    end)
end
Test('healthy transport2 is not mass-resaved just because new transport exists',function()
    local _,P,io,st,key=Actual();local raw=assert(P:DecodePhysicalEnvelope(fixture.raw))
    raw.__rsmeta.encodedFingerprint=FP(P,st,raw.payload);io.disk[key]=Reseal(P,raw)
    local old=Copy(io.disk[key]);assert(P:LoadStore(st.id))
    assert(not st.dirty and io.writes==0 and Eq(old,io.disk[key]) and io.disk[key].__rsmeta.transportVersion==2)
end)
Test('two lost normalized tokens are not solved by combinatorial search',function()
    local _,P,io,st,key=Actual();local raw=assert(P:DecodePhysicalEnvelope(fixture.raw))
    raw.payload.widgetWindow.normalizedCenterX=0.0741236;raw.payload.widgetWindow.normalizedCenterY=0.0864563
    raw.__rsmeta.encodedFingerprint=FP(P,st,raw.payload);io.disk[key]=NativeLoss(Reseal(P,raw))
    assert(not P:LoadStore(st.id) and st.writeFenced and io.writes==0)
end)
Test('ambiguous candidate hashes remain fenced instead of choosing the first',function()
    local _,P,_,st=Actual();local raw=assert(P:DecodePhysicalEnvelope(fixture.raw))
    local old=P.FingerprintCanonicalValue;P.FingerprintCanonicalValue=function()return '6BE9E557'end
    local before=Copy(raw);local result=st.rebuildCanonicalForIntegrity(raw.payload,'6BE9E557',Copy(raw.payload),raw)
    P.FingerprintCanonicalValue=old;assert(result==nil and Eq(raw,before))
end)
Test('v3 numeric token accepts equivalent C-runtime exponent zero padding',function()
    local _,P=Boot()
    for _,token in ipairs({'9.9999999999999995e-021','1e+020'}) do
        local out,err=P:DecodePhysicalEnvelope({__rsmeta={framework=3,transportVersion=3},payload={v='__rs_t3:n'..token}})
        assert(out and out.payload.v==tonumber(token),err)
    end
end)
Test('v3 rejects unwrapped fractional Native value and unknown future transport',function()
    local _,P=Boot()
    for _,v in ipairs({0.123,16777217}) do
        local out,err=P:DecodePhysicalEnvelope({__rsmeta={framework=3,transportVersion=3},payload={v=v}})
        assert(out==nil and err=='transport_native_number_v3',err)
    end
    assert(P:DecodePhysicalEnvelope({__rsmeta={framework=3,transportVersion=6},payload={}})==nil)
    assert(P:EncodePhysicalEnvelope({__rsmeta={framework=3,transportVersion=6},payload={}})==nil)
end)
Test('physical string budget expansion refuses write instead of truncating numeric tokens',function()
    local _,P,io=Boot();local st=P:RegisterV3Store({id='v3.test.numeric.budget',owner='v3.test',scope=P.Scope.Account,
        lifetime=P.Lifetime.Permanent,key=P.V3KeyPrefix..'numeric_budget',schemaVersion=1,default=function()return {}end,
        get=function()local r={};for i=1,16 do r[i]=0.0903896+i*1e-10 end;return {v=r}end,apply=function()end,
        budget={maxDepth=3,maxNodes=100,maxStringBytes=30,maxEntriesPerTable=20},
        encodedBudget={maxDepth=6,maxNodes=200,maxStringBytes=512,maxEntriesPerTable=30}})
    assert(st);assert(P:LoadStore(st.id)=='empty')
    local ok,err=P:SaveStore(st.id,{force=true,durable=true})
    assert(not ok and io.writes==0 and tostring(err):find('physical_payload_rejected:',1,true),err)
end)
Test('failed repaired save never claims clean durable state or clears old fault data',function()
    local _,P,io,st,key=Actual();assert(P:LoadStore(st.id));local original=ADDON.SaveData
    ADDON.SaveData=function(self,k,v)
        local changed=Copy(v);changed.payload.widgetWindow.normalizedCenterX='__rs_t3:ninvalid'
        return original(self,k,changed)
    end
    local ok,err=P:SaveStore(st.id,{force=true,durable=true})
    assert(not ok and st.needsBarrierVerify and st.dirty and io.clears==0,err)
end)
print('NATIVE NUMERIC RESULT '..passed..' passed / '..failed..' failed ('.._VERSION..')')
assert(failed==0,'native numeric transport failures')

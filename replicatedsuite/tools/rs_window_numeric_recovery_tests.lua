-- 维护（2026-09-12）：物理版本按Store注册策略验收；仍比较完整配置，不放宽业务指纹/重载一致性。
-- 维护：F2合成旧档回归，不进入TOC；共用真实Store/Persistence/API，仅Native为内存盘。
-- 数值降精度模型来自已验证跑商样本，但本文件没有两份F2用户原档，不能声称实机修复。
-- 保留老schema5 golden；期望值按Native读出状态只改已匹配的叶子，不伪称全部浮点精度还原。
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
local function FP(P,st,v) return assert(P:FingerprintCanonicalValue(st,assert(P:CanonicalIntegrityValue(st,v)))) end
local function Reseal(P,raw)
    raw.__rsmeta.envelopeFingerprint=assert(P:FingerprintEnvelopeIntegrity(raw));return assert(P:EncodePhysicalEnvelope(raw))
end

-- 同一已实证数值损失模型注入另外两个真实 Store；这些是合成旧档，不冒充用户原档。
local function Legacy(id,schema,x,y)
    local S,P,io=Boot(nil,true);local st=P:GetStore(id)
    local value
    if id=='v3.buff_display' and schema==5 then value=Copy(dofile('tools/rs_status_schema5_fixtures.lua')[2].canonical)
    else value=st.default() end
    value.widgetWindow={userMoved=true,coordinateSpace='logical-free-v2',x=10,y=30,width=470,height=330,
        savedLogicalWidth=1280,savedLogicalHeight=768,savedUiScale=1,
        normalizedCenterX=x or 0.0741236,normalizedCenterY=y or 0.195123}
    -- 当前共享 normalizer 只用于窗口；schema5 settings 仍使用冻结金样，不被6替换。
    value.widgetWindow=st.migrate(Copy(value)).widgetWindow
    if id=='v3.death_review' then
        value.history={serial=7,entries={{serial=7,storageId=2,deathAt=1000,title='kept',killerName='not erased',totalDamage=333}}}
        value=st.migrate(value)
    end
    local canonical=(id=='v3.buff_display' and schema==5) and Copy(value) or assert(P:CanonicalIntegrityValue(st,value))
    local fp=assert(P:FingerprintCanonicalValue(st,canonical))
    local raw=st.encode and st.encode(Copy(value)) or {payload=Copy(value)}
    raw.__rsmeta={framework=3,store=id,owner=st.owner,contractVersion=st.contractVersion,lifetime=st.lifetime,
        scope=st.scope,schema=schema,transportVersion=2,reliabilityContract=8,integrityVersion=4,
        envelopeIntegrityVersion=1,encodedFingerprint=fp}
    local key=P:ResolveStoreKey(st);io.disk[key]=NativeLoss(Reseal(P,raw))
    return S,P,io,st,key,value,canonical,fp
end
for _,row in ipairs({{'v3.buff_display',5},{'v3.buff_display',6},{'v3.death_review',2}})do
 local id,schema=row[1],row[2]
 Test(id..' schema'..schema..' recovers exactly one fixed6 window field before apply',function()
    local _,P,io,st,key,v,canonical,fp=Legacy(id,schema)
    local old=Copy(io.disk[key]);local raw=assert(P:DecodePhysicalEnvelope(old))
    local seen=st.decode and st.decode(raw) or raw.payload
    assert(P:FingerprintCanonicalValue(st,assert(P:CanonicalIntegrityValue(st,seen)))~=fp,'fault was not injected')
    local ok,_,err=P:LoadStore(id);assert(ok,err)
    assert(not st.writeFenced and st.lastIntegrityFingerprint==fp)
    -- 独立期望取自Native本次读出的Domain，只还原已证明的X；不能声称复原其余丢失精度。
    local expected=Copy(seen);expected.widgetWindow.normalizedCenterX=v.widgetWindow.normalizedCenterX
    assert(Eq(st.get(),st.migrate(expected,schema,st.schemaVersion)),'non-window read state changed')
    assert(io.writes==0 and io.clears==0 and Eq(old,io.disk[key]))
    assert(st.lastWindowNumericEvidence and st.lastWindowNumericEvidence.matches==1)
 end)
 Test(id..' schema'..schema..' durable selected-transport save and fresh load preserve selections/history',function()
    local _,P,io,st,key,v=Legacy(id,schema);assert(P:LoadStore(id))
    local expected=st.get();assert(P:SaveStore(id,{force=true,durable=true}))
    assert(io.disk[key].__rsmeta.transportVersion==(st.transportVersion or P.TransportContractVersion))
    local _,again,newio=Boot(io.disk,true);assert(again:LoadStore(id));assert(Eq(expected,again:GetStore(id).get()))
    assert(newio.writes==0 and newio.clears==0)
 end)
 Test(id..' schema'..schema..' two numeric losses are refused but exact diagnostics remain small',function()
    local _,P,io,st=Legacy(id,schema,0.0741236,0.0864563);assert(not P:LoadStore(id))
    assert(st.writeFenced and io.writes==0 and io.clears==0)
    local e=st.lastWindowNumericEvidence;assert(e and e.matches==0 and e.attempts<=32,'missing bounded number evidence')
    assert(e.fields.normalizedCenterX.raw=='0.07412400096654892','must retain actual read 17g')
    assert(e.fields.normalizedCenterX.token=='0.074124')
 end)
 Test(id..' schema'..schema..' changed unrelated content cannot be repaired by numeric candidates',function()
    local _,P,io,st,key=Legacy(id,schema);local physical=io.disk[key]
    if id=='v3.buff_display' then physical.payload.settings.playerRows=13
    else physical.payload.settings.windowMs=18000 end
    local applied=0;st.apply=function()applied=applied+1 end
    assert(not P:LoadStore(id));assert(st.writeFenced and applied==0 and io.writes==0)
 end)
 Test(id..' schema'..schema..' helper never touches transport3 or another identity',function()
    local _,P,io,st,key,v,canonical,fp=Legacy(id,schema)
    assert(type(P.RebuildFixed6WindowCanonical)=='function','shared helper missing')
    local raw=assert(P:DecodePhysicalEnvelope(io.disk[key]));raw.__rsmeta.transportVersion=3
    assert(P:RebuildFixed6WindowCanonical(st,v,fp,canonical,raw,schema,id=='v3.death_review' and 1 or nil)==nil)
    raw.__rsmeta.transportVersion=2;raw.__rsmeta.owner='wrong'
    assert(P:RebuildFixed6WindowCanonical(st,v,fp,canonical,raw,schema,id=='v3.death_review' and 1 or nil)==nil)
 end)
end
Test('fresh actual loads discard earlier numeric cache and readback preserves load evidence',function()
    local _,P,io,st,key=Legacy('v3.buff_display',6,0.0741236,0.0864563)
    assert(not P:LoadStore(st.id));assert(st.lastWindowNumericEvidence)
    st.lastWindowNumericEvidence={status='stale'};io.disk[key]=nil
    assert(P:LoadStore(st.id,{discardDirty=true,discardUnverified=true,revalidateTerminal=true})=='empty')
    assert(st.lastWindowNumericEvidence==nil,'new read retained previous sample')
end)
Test('ambiguous matches never return a repaired candidate',function()
    local _,P,io,st,key=Legacy('v3.death_review',2)
    local raw=assert(P:DecodePhysicalEnvelope(io.disk[key]));local decoded=assert(st.decode(raw))
    local canonical=assert(P:CanonicalIntegrityValue(st,decoded));local before=Copy(canonical)
    assert(type(P.RebuildFixed6WindowCanonical)=='function')
    local original=P.FingerprintCanonicalValue;P.FingerprintCanonicalValue=function()return '12345678'end
    local out=P:RebuildFixed6WindowCanonical(st,decoded,'12345678',canonical,raw,2,1)
    P.FingerprintCanonicalValue=original
    assert(out==nil and st.lastWindowNumericEvidence.matches>1 and Eq(canonical,before))
end)
Test('small magnitude and normalizer differences are excluded rather than widening search',function()
    local _,P,io,st,key=Legacy('v3.death_review',2,0.0000123456)
    assert(not P:LoadStore(st.id));local e=st.lastWindowNumericEvidence
    assert(e and e.fields.normalizedCenterX.reason=='range' and io.writes==0)
end)
for _,axis in ipairs({'negative_x','positive_y'}) do
 Test('independent '..axis..' six-decimal loss is constrained to one leaf',function()
    local x,y=axis=='negative_x' and -0.0741236 or 0.25,axis=='positive_y' and 0.0641236 or 0.5
    local _,P,io,st,key,v=Legacy('v3.death_review',2,x,y)
    local before=assert(P:DecodePhysicalEnvelope(io.disk[key]));local expected=st.decode(before)
    local field=axis=='negative_x' and 'normalizedCenterX' or 'normalizedCenterY'
    expected.widgetWindow[field]=v.widgetWindow[field]
    assert(P:LoadStore(st.id));assert(Eq(st.get(),st.migrate(expected)))
    assert(st.lastWindowNumericEvidence.field==field and io.writes==0)
 end)
end
Test('normalizer-changing float cannot borrow exact-window recovery',function()
    local _,P,io,st,key,v,canonical,fp=Legacy('v3.death_review',2)
    local raw=assert(P:DecodePhysicalEnvelope(io.disk[key]));local decoded=st.decode(raw)
    local candidate=P:CanonicalIntegrityValue(st,decoded)
    candidate.payload.widgetWindow.normalizedCenterX=0.083
    assert(P:RebuildFixed6WindowCanonical(st,decoded,fp,candidate,raw,2,1)==nil)
    assert(st.lastWindowNumericEvidence.fields.normalizedCenterX.reason=='normalized')
end)
Test('malformed history sequence is not converted into window-only recovery',function()
    local _,P,io,st,key=Legacy('v3.death_review',2)
    local physical=io.disk[key];physical.payload.history.entries={[2]=physical.payload.history.entries[1]}
    assert(not P:LoadStore(st.id) and st.writeFenced and io.writes==0)
    assert(st.lastWindowNumericEvidence==nil,'window helper bypassed sparse-sequence gate')
end)
Test('readback sequence correction preserves cached load numeric evidence',function()
    local _,P,io,st,key=Legacy('v3.buff_display',6)
    local raw=assert(P:DecodePhysicalEnvelope(io.disk[key]));raw.payload.settings.tracked.auto={21,82}
    -- 新合成原章先按已证明的源值计算；未改真实用户fixture。
    local origin=Copy(raw.payload);origin.widgetWindow.normalizedCenterX=0.0741236
    raw.__rsmeta.encodedFingerprint=FP(P,st,origin);io.disk[key]=Reseal(P,raw)
    assert(P:LoadStore(st.id));local evidence=Copy(st.lastWindowNumericEvidence)
    local original=ADDON.SaveData
    ADDON.SaveData=function(self,k,v)
        local r=Copy(v);local ids=r.payload.settings.tracked.auto
        if type(ids)=='table' then local mapped={};for i,x in ipairs(ids)do mapped[tostring(i)]=x end;r.payload.settings.tracked.auto=mapped end
        return original(self,k,r)
    end
    assert(P:SaveStore(st.id,{force=true,durable=true}))
    assert(Eq(evidence,st.lastWindowNumericEvidence),'readback replaced load facts')
end)
Test('maximum index history survives the old-model restoration path',function()
    local _,P,io,st,key,v=Legacy('v3.death_review',2)
    v.settings.maxHistory=30;v.history={serial=30,entries={}}
    for i=1,30 do v.history.entries[i]={serial=i,storageId=i,deathAt=1000+i,killerName='player_'..i,totalDamage=111+i}end
    local raw=st.encode(v);raw.__rsmeta=assert(P:DecodePhysicalEnvelope(io.disk[key])).__rsmeta
    raw.__rsmeta.encodedFingerprint=FP(P,st,v);io.disk[key]=NativeLoss(Reseal(P,raw))
    local before=st.decode(assert(P:DecodePhysicalEnvelope(io.disk[key])))
    assert(P:LoadStore(st.id));assert(#st.get().history.entries==30 and Eq(before.history,st.get().history))
    assert(io.writes==0 and st.lastWindowNumericEvidence.attempts<=32)
end)

Test('diagnostic probe text is not a recovery eligibility authority',function()
    local _,P,io,st=Legacy('v3.death_review',2)
    rawset(st,'lastHistoricalRecoveryProbe',nil)
    setmetatable(st,{__newindex=function(t,k,v)
        if k~='lastHistoricalRecoveryProbe' then rawset(t,k,v) end
    end})
    local ok,_,err=P:LoadStore(st.id);assert(ok,err)
    assert(not st.writeFenced and io.writes==0)
end)

print('F2 NUMERIC RESULT '..passed..' passed / '..failed..' failed ('.._VERSION..')')
assert(failed==0,'f2 numeric tests failed')

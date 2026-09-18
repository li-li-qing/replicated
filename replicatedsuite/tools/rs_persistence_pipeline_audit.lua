-- 中文维护注释（2026-09-12）：三个真实 Store 的公共读写契约回归，仅开发期执行，不进 TOC。
-- 原因：既有测试替代了 S.Api，且只覆盖 actual~=expected 分支，未验证 metadata 业务章。
-- Authority：生产 Persistence/Store/Utils/API/能力门均原样加载，仅 ADDON.Native 边界为内存盘。
-- 所有 fixture 都是合成值；带重新封印的旧指纹仅用于暴露验证器矛盾，不代表用户实档根因。
-- 数据流：real get -> canonical -> transport -> fake Native -> real readback -> fresh boot LoadStore。
-- 兼容/风险：保留真实原指纹拒绝语义；测试不得给未知用户 Hash 加白名单或打开恢复后门。
local passed, failed = 0, 0
local function Test(name, run)
    local ok, err = pcall(run)
    if ok then passed=passed+1;print('PASS '..name)
    else failed=failed+1;print('FAIL '..name..': '..tostring(err)) end
end
local function Copy(v)
    if type(v)~='table' then return v end
    local r={};for k,x in pairs(v) do r[Copy(k)]=Copy(x) end;return r
end
local function Equal(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~='table' then return a==b end
    for k,v in pairs(a) do if not Equal(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end
    return true
end
local function Boot(disk)
    disk=disk or {}
    local io={disk=disk,loads=0,saves=0,applyCalls=0}
    ADDON={
        LoadData=function(_,key) io.loads=io.loads+1;return Copy(disk[key]) end,
        SaveData=function(_,key,value)
            io.saves=io.saves+1;local physical=Copy(value)
            if io.transform then physical=io.transform(physical,key) end
            disk[key]=physical;return true
        end,
    }
    ReplicatedSuite={Features={},Services={},UI={CreateWindowShell=function() error("audit must not build native window") end},RSUI={},NowMs=function()return 1000 end,
        FeatureRuntime={RegisterImplementation=function()return true end}}
    local S=ReplicatedSuite
    dofile('core/rs_utils.lua');dofile('core/rs_reuse.lua');dofile('core/rs_demand.lua')
    dofile('core/rs_api.lua');dofile('core/rs_api_capabilities.lua');dofile('core/rs_persistence.lua')
    dofile('ui/framework/rs_ui_floating_surface.lua')
    dofile('features/combat/buff_display/rs_buff_display_store.lua')
    dofile('features/combat/death_review/rs_death_review_store.lua')
    dofile('features/life/rs_life_m16_bundle.lua')
    return S,S.Persistence,io
end
local IDS={'v3.life.trade','v3.death_review','v3.buff_display'}
local function Sample(store)
    local v=store.default()
    if store.id=='v3.life.trade' then
        v.fromZone=1;v.toZone=4;v.sortMode='name';v.ratioMode='full';v.commerceMode='off'
        v.favorites={{fromZone=1,toZone=4},{fromZone=4,toZone=5}}
        v.widgetVisible=true;v.widgetWindow={width=410,height=306,userMoved=true,
            coordinateSpace='logical-free-v2',x=0,y=70.25,locked=false,minimized=false,
            overallOpacity=0.75,backgroundOpacity=1,textOpacity=1,fontScale=1,
            savedLogicalWidth=1280,savedLogicalHeight=768,normalizedCenterX=0.5,normalizedCenterY=0.25}
    elseif store.id=='v3.death_review' then
        v.settings.autoShow=false;v.settings.showDebuffs=false;v.settings.maxHistory=10
        v.history={serial=1,entries={{serial=1,storageId=1,time=125,clock='01:02:03',windowMs=10000,
            totalDamage=12345,lethalSource='合成测试',lethalAbility='测试技能',lethalAmount=5000,eventCount=2,debuffCount=1}}}
        v.widgetWindow.userMoved=true;v.widgetWindow.coordinateSpace='logical-free-v2'
        v.widgetWindow.x=0;v.widgetWindow.y=70.25;v.widgetWindow.overallOpacity=0.75
    else
        v.settings.tracked.player.buff={21,82};v.settings.tracked.player.debuff={123};v.settings.tracked.player.auto={456}
        v.settings.tracked.target.buff={21,82};v.settings.tracked.target.debuff={123};v.settings.tracked.target.auto={456}
        v.settings.trackedCooldowns.skill={789};v.settings.trackedCooldowns.mate={987}
        v.settings.components.buffs.x=-20;v.settings.targetLayout.components.buffs.x=40
        v.settings.components.buffs.alpha=0.75
    end
    return v
end
local function Ready(id,custom)
    local S,P,io=Boot();local st=assert(P:GetStore(id));local status,_,err=P:LoadStore(id)
    assert(status=='empty',err);st.apply(custom==false and st.default() or Sample(st))
    local expected=st.get();local ok,why=P:SaveStore(id,{force=true,verifyAfterSave=true})
    assert(ok,why);return S,P,io,st,expected,assert(P:ResolveStoreKey(st))
end
local function Reseal(P,raw)
    raw.__rsmeta.envelopeFingerprint=assert(P:FingerprintEnvelopeIntegrity(raw))
    return assert(P:EncodePhysicalEnvelope(raw))
end
local function WrongStamp(P,physical)
    local raw=assert(P:DecodePhysicalEnvelope(Copy(physical)))
    raw.__rsmeta.encodedFingerprint=raw.__rsmeta.encodedFingerprint=='00000000' and '00000001' or '00000000'
    return Reseal(P,raw)
end
local function Fingerprint(P,st,v)
    return assert(P:FingerprintCanonicalValue(st,assert(P:CanonicalIntegrityValue(st,Copy(v)))))
end
local function ProtectApply(st,io)
    local apply=st.apply;st.apply=function(...) io.applyCalls=io.applyCalls+1;return apply(...) end
end
for _,id in ipairs(IDS) do
    Test(id..' default durable round-trip across fresh addon registration',function()
        local _,P,io,st,expected,key=Ready(id,false)
        local saved=Copy(io.disk[key]);local fp=Fingerprint(P,st,expected)
        local _,fresh,newio=Boot(io.disk);local target=fresh:GetStore(id)
        local ok,_,err=fresh:LoadStore(id);assert(ok,err)
        assert(not target.writeFenced and fp==Fingerprint(fresh,target,target.get()))
        assert(newio.saves==0 and Equal(saved,io.disk[key]),'healthy reload wrote disk')
    end)
    Test(id..' custom data round-trip uses real API capability gate',function()
        local S,P,io,st,expected,key=Ready(id)
        assert(S.ApiCapabilities:IsAllowed('ADDON:LoadData') and S.ApiCapabilities:IsAllowed('ADDON:SaveData'))
        local raw=assert(P:DecodePhysicalEnvelope(io.disk[key]))
        assert(raw.__rsmeta.encodedFingerprint==Fingerprint(P,st,expected))
        local _,fresh,newio=Boot(io.disk);local ok,_,err=fresh:LoadStore(id);assert(ok,err)
        assert(Equal(fresh:GetStore(id).get(),expected),'custom data changed across reload')
        assert(newio.saves==0)
    end)
    Test(id..' canonical is detached pure and codec-round-trip stable',function()
        local _,P,_,st,expected=Ready(id);local input=Copy(expected)
        local c=assert(P:CanonicalIntegrityValue(st,input));assert(Equal(input,expected),'normalizer mutated input')
        local domain=st.decode and assert(st.decode(Copy(c))) or c
        local cc=assert(P:CanonicalIntegrityValue(st,domain))
        assert(Equal(c,cc),'encode/decode not idempotent')
        c.__audit_marker=1;assert(st.get().__audit_marker==nil,'canonical aliases live state')
    end)
    Test(id..' valid readback is read-only and does not call apply',function()
        local _,P,io,st,expected,key=Ready(id);ProtectApply(st,io)
        local disk=Copy(io.disk);local saves=io.saves;local before=st.get()
        assert(P:VerifyPersistedValue(st,expected,key))
        assert(Equal(io.disk,disk) and Equal(st.get(),before) and io.saves==saves and io.applyCalls==0)
    end)
    Test(id..' resealed stale business stamp must fail readback',function()
        local _,P,io,st,expected,key=Ready(id);io.disk[key]=WrongStamp(P,io.disk[key]);ProtectApply(st,io)
        local disk=Copy(io.disk);local saves=io.saves
        local ok,err=P:VerifyPersistedValue(st,expected,key)
        assert(not ok,'readback accepted a stale business stamp although fresh LoadStore rejects it')
        assert(tostring(err):find('readback_stamped_fingerprint_mismatch:',1,true),tostring(err))
        assert(st.lastVerifyOk==false and st.lastVerifyFingerprint==nil)
        assert(Equal(io.disk,disk) and io.saves==saves and io.applyCalls==0,'verification changed data')
    end)
    Test(id..' same stale stamp still fails fresh load without apply or overwrite',function()
        local _,P,io,_,_,key=Ready(id);io.disk[key]=WrongStamp(P,io.disk[key]);local disk=Copy(io.disk)
        local _,fresh,newio=Boot(io.disk);local st=fresh:GetStore(id);ProtectApply(st,newio)
        local ok,_,err=fresh:LoadStore(id)
        assert(not ok and st.writeFenced and tostring(err):find('fingerprint_mismatch:',1,true),err)
        assert(Equal(io.disk,disk) and newio.saves==0 and newio.applyCalls==0)
    end)
    Test(id..' durable save cannot report success with stale stamped metadata',function()
        local _,P,io,st=Ready(id)
        io.transform=function(raw)return WrongStamp(P,raw) end
        local ok,err=P:SaveStore(id,{force=true,durable=true})
        assert(not ok,'durable write confirmed an archive which next load will reject')
        assert(st.needsBarrierVerify and st.lastVerifyOk==false,'failed proof lost barrier obligation')
        assert(tostring(err):find('readback_stamped_fingerprint_mismatch:',1,true),err)
    end)
    Test(id..' reload barrier rejects stale stamp and keeps verification obligation',function()
        local _,P,io,st,_,key=Ready(id)
        -- 普通设置走延后回读路径；模拟一份业务内容一致但旧章/有效元数据封印的存档。
        assert(P:SaveStore(id,{force=true}));assert(st.needsBarrierVerify)
        io.disk[key]=WrongStamp(P,io.disk[key]);local before=Copy(io.disk);local saves=io.saves
        local ok=P:Flush(st.owner)
        assert(not ok,'reload barrier incorrectly cleared verification for stale stamp')
        assert(st.needsBarrierVerify and st.lastBarrierVerifyOk==false)
        assert(Equal(io.disk,before) and io.saves==saves,'barrier rewrote archive during proof')
    end)
    Test(id..' wrong stamp cannot invoke candidate recovery on matching body',function()
        local _,P,io,st,expected,key=Ready(id)
        io.disk[key]=WrongStamp(P,io.disk[key]);local calls=0
        st.recoverReadbackRepresentation=true
        st.rebuildCanonicalForIntegrity=function()calls=calls+1;error('must not recover wrong stamp') end
        assert(not P:VerifyPersistedValue(st,expected,key),'wrong stamp accepted')
        assert(calls==0)
    end)
    Test(id..' business mutation remains rejected with intact old stamp',function()
        local _,P,io,st,expected,key=Ready(id)
        local raw=assert(P:DecodePhysicalEnvelope(io.disk[key]))
        if id=='v3.life.trade' then raw.payload.fromZone=20
        elseif id=='v3.death_review' then raw.payload.settings.windowMs=6000
        else raw.payload.settings.tracked.player.auto={555} end
        io.disk[key]=assert(P:EncodePhysicalEnvelope(raw))
        assert(not P:VerifyPersistedValue(st,expected,key),'changed business accepted')
    end)
    Test(id..' intact current disk cannot prove a different expected value',function()
        local _,P,_,st,expected,key=Ready(id)
        if id=='v3.life.trade' then expected.fromZone=20
        elseif id=='v3.death_review' then expected.settings.windowMs=6000
        else expected.settings.tracked.player.auto={555} end
        assert(not P:VerifyPersistedValue(st,expected,key),'wrong expected domain accepted')
    end)
    Test(id..' unsealed metadata and wrong owner rejected before business proof',function()
        local _,P,io,st,expected,key=Ready(id);local saved=Copy(io.disk[key])
        io.disk[key].__rsmeta.encodedFingerprint='00000000'
        local ok,err=P:VerifyPersistedValue(st,expected,key)
        assert(not ok and tostring(err):find('envelope_fingerprint_mismatch',1,true),err)
        local raw=assert(P:DecodePhysicalEnvelope(saved));raw.__rsmeta.owner='v3.wrong_owner'
        io.disk[key]=Reseal(P,raw);ok,err=P:VerifyPersistedValue(st,expected,key)
        assert(not ok and err=='readback_metadata_owner',err)
    end)
    Test(id..' recognized v2 encoded-payload readback contract still passes',function()
        local _,P,io,st,expected,key=Ready(id);local raw=assert(P:DecodePhysicalEnvelope(io.disk[key]))
        raw.__rsmeta.integrityVersion=2
        raw.__rsmeta.encodedFingerprint=assert(P:FingerprintEncodedPayload(raw,st.encodedBudget))
        io.disk[key]=Reseal(P,raw)
        local ok,err=P:VerifyPersistedValue(st,expected,key);assert(ok,err)
    end)
end
Test('transport2 exactly preserves false zero empty table escaped strings and mixed key types',function()
    local _,P=Boot()
    local raw={__rsmeta={framework=3,transportVersion=2},payload={a=false,b=0,c='',d={},
        e='__rs_t2:f',f='__rs_t1:s',g={ [1]='number',['1']='string',[0]=false },h='中文\0终'}}
    assert(Equal(raw,assert(P:DecodePhysicalEnvelope(assert(P:EncodePhysicalEnvelope(raw))))))
end)
print(string.format('PIPELINE RESULT %d passed / %d failed (%s); synthetic Native only',passed,failed,_VERSION))
if failed>0 then error('persistence pipeline audit failed') end

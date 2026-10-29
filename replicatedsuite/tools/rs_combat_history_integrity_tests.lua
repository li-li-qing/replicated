-- Replicated Suite · 战斗历史完整性测试
-- 作者：Replicated
-- QQ群：1104129461
-- 使用真实 Persistence 和生产 Store；固定封装由改动前的生产代码生成。
-- 仅使用构造的内存磁盘，不读写玩家文件；迁移测试必须保留旧指纹。
local passed,failed=0,0
local function Test(name,fn)
    local ok,err=xpcall(fn,debug.traceback)
    if ok then passed=passed+1;print('PASS combat-history '..name)
    else failed=failed+1;print('FAIL combat-history '..name..': '..tostring(err))end
end
local function Boot(options)
    local h=dofile('tools/rs_gear_page_test_host.lua')(options);local S=h.S
    S.Features.CombatAnalytics={}
    S.Services.CombatAnalyticsV3={RegisterMetric=function()return true end,GetCollectionScope=function()return 'self'end}
    S.Utils.GetServerTime=function()return {year=2026,month=10,day=7,hour=8,minute=30}end
    dofile('features/combat/analytics/rs_combat_personal_history.lua')
    dofile('features/combat/analytics/rs_combat_analytics_store.lua')
    h.F=S.Features.CombatAnalytics;h.H=h.F.PersonalHistory;h.P=S.Persistence
    h.store=h.P:GetStore(h.H.StoreId);h.key=assert(h.P:ResolveStoreKey(h.store))
    return h
end
local function NoNpc(row)
    assert(row.npcKills==nil and row.inferredNpcKills==nil and row.recordedNpcKills==nil,'retired NPC counters exposed')
end
Test('genuine schema1 migrates without losing any old counts',function()
    local h=Boot();h.disk[h.key]=dofile('tools/fixtures/combat_history_schema1_20261007.lua')
    local stamped=h.disk[h.key].__rsmeta.encodedFingerprint;local clears=h.clears
    assert(h.H:EnsureLoaded());assert(not h.store.writeFenced,'valid old history fenced')
    local t=h.H:GetProjection().totals
    assert(t.kills==2 and t.deaths==2 and t.damage==700 and t.assists==9 and t.inferredKills==1,'old inferred kill is included in confirmed history')
    assert(h.H.state.totals.kills==3,'read-only history projection rewrote original saved counts')
    NoNpc(t)
    assert(stamped=='14ACCE46','frozen pre-change fixture stamp changed')
    local revision=h.H.revision
    assert(h.H:Record({inferredKills=1,inferredNpcKills=1})==false and h.H.revision==revision,'new inference still changes history')
    assert(h.H:Record({npcKills=2})==false and h.H.revision==revision,'retired NPC counter dirtied history')
    assert(h.H:Record({kills=1}));assert(h.P:SaveStore(h.H.StoreId,{reason='offline_roundtrip',durable=true}))
    assert(h.disk[h.key].__rsmeta.schema==6) -- 原章验证后写入当前版本；冻结旧 fixture 本身不改。
    h.store.loaded=false;h.H.loaded=false;assert(h.H:EnsureLoaded())
    local p=h.H:GetProjection({fromDate='2026-10-07',toDate='2026-10-07'})
    assert(p.totals.kills==3 and p.totals.assists==9)
    assert(p.rows[1].kills==3 and h.H.state.totals.kills==4,'daily projection or original aggregate changed')
    NoNpc(p.totals);NoNpc(p.rows[1]);assert(h.clears==clears,'migration cleared old history')
end)
Test('retired honor kill preference authenticates unchanged and only exposes confirmed kills',function()
    local h=Boot();local f,p=h.F,h.P;assert(f:EnsureStoreLoaded())
    local store=p:GetStore(f.StoreId);local key=assert(p:ResolveStoreKey(store))
    f.State.selectedValues.kills='honorKills';f.State.honorKillAmounts={19,21,86}
    assert(p:SaveStore(f.StoreId,{durable=true}));local fingerprint=h.disk[key].__rsmeta.encodedFingerprint
    store.loaded=false;assert(f:EnsureStoreLoaded() and not store.writeFenced)
    assert(f:GetStatisticsCountKey()=='kills' and f:GetStatisticsCountTitle()=='击杀玩家')
    assert(f:GetSelectedValueKey('kills')=='kills' and f:GetAnalyticsSettings().selectedValues.kills=='kills')
    assert(f.State.selectedValues.kills=='honorKills' and f:IsAnalyticsValueKey('kills','honorKills')==false)
    assert(p:SaveStore(f.StoreId,{durable=true}) and h.disk[key].__rsmeta.encodedFingerprint==fingerprint,'public fallback rewrote old canonical')
end)
Test('changed old payload cannot pass the historical integrity hook',function()
    local h=Boot();local raw=dofile('tools/fixtures/combat_history_schema1_20261007.lua')
    raw.payload.totals.kills=99
    -- 传输封装有效但业务指纹错误时，历史恢复钩子仍必须拒绝该数据。
    raw.__rsmeta.envelopeFingerprint=assert(h.P:FingerprintEnvelopeIntegrity(raw))
    h.disk[h.key]=raw
    local ok=h.H:EnsureLoaded();assert(ok~=true and h.store.writeFenced,'corrupt history accepted')
    local writes=h.writes
    assert(h.H:Record({kills=1})~=true and h.writes==writes and h.clears==0,'fenced history overwritten')
end)
Test('schema1 recovery cannot import unverified honor counters excluded from its old stamp',function()
    local h=Boot();local raw=dofile('tools/fixtures/combat_history_schema1_20261007.lua')
    raw.payload.totals.honorParticipations=777
    raw.payload.days['2026-10-07'].honorParticipations=777
    raw.payload.totals.honorKills=777
    raw.payload.days['2026-10-07'].honorKills=777
    raw.__rsmeta.envelopeFingerprint=assert(h.P:FingerprintEnvelopeIntegrity(raw))
    h.disk[h.key]=raw;assert(h.H:EnsureLoaded())
    assert(h.H.state.totals.honorParticipations==nil and h.H.state.days['2026-10-07'].honorParticipations==nil,
        'old integrity recovery trusted a field not covered by the old canonical stamp')
    assert(h.H.state.totals.honorKills==nil and h.H.state.days['2026-10-07'].honorKills==nil)
    assert(h.H:GetProjection().totals.kills==2 and raw.__rsmeta.encodedFingerprint=='14ACCE46')
end)
Test('honor rule edits persist including empty arrays and roll back a rejected commit',function()
    local h=Boot();h.S.Services.CombatAnalyticsV3.SetStatisticsPolicy=function()return true end
    dofile('features/combat/analytics/rs_combat_analytics_feature.lua')
    local f,p=h.F,h.P;assert(f:EnsureStoreLoaded())
    local store=p:GetStore(f.StoreId)
    assert(f.Commands:AddHonorKillAmount(100))
    assert(p:SaveStore(f.StoreId,{durable=true}));store.loaded=false;assert(f:EnsureStoreLoaded())
    assert(f:IsHonorKillAmount(100) and f:IsHonorKillAmount(19))
    local mark=p.MarkDirty;p.MarkDirty=function()return false,'reject queue'end
    assert(f.Commands:RemoveHonorKillAmount(100)==false)
    p.MarkDirty=mark;assert(f:IsHonorKillAmount(100),'rejected mutation changed match rules')
    for _,amount in ipairs(f:GetHonorKillAmounts())do assert(f.Commands:RemoveHonorKillAmount(amount)) end
    assert(p:SaveStore(f.StoreId,{durable=true}));store.loaded=false;assert(f:EnsureStoreLoaded())
    assert(#f:GetHonorKillAmounts()==0 and not f:IsHonorKillAmount(84),'empty array was lost by persistence')
    local copier=h.S.Utils.DeepCopy;h.S.Utils.DeepCopy=nil
    local public=f:GetAnalyticsSettings();public.honorKillAmounts[1]=84;h.S.Utils.DeepCopy=copier
    assert(#f:GetHonorKillAmounts()==0,'fallback settings projection aliased the match list')
end)
Test('genuine schema2 hides NPC fields while preserving storage and player inference rules',function()
    local h=Boot();local raw=dofile('tools/fixtures/combat_history_schema2_npc_retired_20261007.lua')
    assert(raw.__rsmeta.encodedFingerprint=='2783EEFD','frozen pre-removal stamp changed')
    h.disk[h.key]=raw;assert(h.H:EnsureLoaded() and not h.store.writeFenced)
    local all=h.H:GetProjection()
    assert(all.totals.kills==3 and all.rows[1].kills==3 and all.archive.kills==0,'player inference subtraction changed')
    NoNpc(all.totals);NoNpc(all.rows[1]);NoNpc(all.archive)
    local filtered=h.H:GetProjection({fromDate='2026-10-07',toDate='2026-10-07'})
    assert(filtered.totals.kills==3,'range subtracted old inference twice');NoNpc(filtered.totals)
    NoNpc(h.H:GetProjection({fromDate='invalid'}).totals)
    assert(h.H.state.totals.kills==6 and h.H.state.totals.npcKills==9 and h.clears==0,'projection rewrote raw old history')
    local revision=h.H.revision;local writes=h.writes
    assert(h.H:Record({npcKills=100})==false and h.H.revision==revision and h.writes==writes,'retired counter remains active')
    assert(h.H:Record({kills=1,npcKills=100}))
    assert(h.P:SaveStore(h.H.StoreId,{reason='retirement_roundtrip',durable=true}))
    h.store.loaded=false;h.H.loaded=false;assert(h.H:EnsureLoaded() and not h.store.writeFenced)
    assert(h.H.state.totals.kills==7 and h.H.state.totals.npcKills==9 and h.H.state.totals.inferredNpcKills==4)
    assert(h.H.state.days['2026-10-07'].npcKills==7 and h.H.state.archive.npcKills==2 and h.clears==0,'retired fields lost on save')
    NoNpc(h.H:GetProjection().totals)
end)
Test('retired NPC counter corruption remains protected on schema2 reload',function()
    local h=Boot();local raw=dofile('tools/fixtures/combat_history_schema2_npc_retired_20261007.lua')
    raw.payload.totals.npcKills=400
    raw.__rsmeta.envelopeFingerprint=assert(h.P:FingerprintEnvelopeIntegrity(raw));h.disk[h.key]=raw
    h.store.loaded=false;h.H.loaded=false
    assert(h.H:EnsureLoaded()~=true and h.store.writeFenced,'schema2 NPC corruption accepted')
    NoNpc(h.H:GetProjection().totals);assert(h.clears==0)
end)
Test('genuine NPC preference has a public fallback without rewriting canonical data',function()
    local h=Boot();local store=h.P:GetStore(h.F.StoreId);local key=assert(h.P:ResolveStoreKey(store))
    local raw=dofile('tools/fixtures/combat_settings_schema2_npc_retired_20261007.lua')
    assert(raw.__rsmeta.encodedFingerprint=='192360B1','frozen settings stamp changed')
    h.disk[key]=raw;assert(h.F:EnsureStoreLoaded() and not store.writeFenced)
    assert(h.F.State.selectedValues.kills=='npcKills','canonical preference rewritten on read')
    assert(h.F:GetSelectedValueKey('kills')=='kills' and h.F:GetAnalyticsSettings().selectedValues.kills=='kills','retired preference has no public fallback')
    local copier=h.S.Utils.DeepCopy;h.S.Utils.DeepCopy=nil
    local fallback=h.F:GetAnalyticsSettings();h.S.Utils.DeepCopy=copier
    assert(fallback.selectedValues.kills=='kills' and h.F.State.selectedValues.kills=='npcKills','fallback getter rewrote canonical preference')
    assert(h.F:ApplyStoreRaw('selectedValue','kills','npcKills')==false,'retired option accepted')
    assert(h.P:SaveStore(h.F.StoreId,{reason='retirement_roundtrip',durable=true}))
    assert(h.disk[key].__rsmeta.encodedFingerprint=='192360B1','unrelated save changed old canonical preference')
    store.loaded=false;assert(h.F:EnsureStoreLoaded() and not store.writeFenced)
    assert(h.F:ApplyStoreRaw('selectedValue','kills','deaths'));assert(h.P:SaveStore(h.F.StoreId,{reason='current_view',durable=true}))
    store.loaded=false;assert(h.F:EnsureStoreLoaded() and h.F:GetSelectedValueKey('kills')=='deaths')
    assert(h.clears==0)
end)
Test('recorded date catalog survives filtering and durable reload without inventing unknown dates',function()
    local h=Boot();assert(h.H:EnsureLoaded())
    for _,sample in ipairs({{5,2,3},{7,5,1},{9,3,2}}) do
        h.S.Utils.GetServerTime=function()return {year=2026,month=10,day=sample[1],hour=8,minute=30}end
        h.ms=h.ms+1500;assert(h.H:Record({kills=sample[2],deaths=sample[3]}))
    end
    h.S.Utils.GetServerTime=function()return nil end
    h.ms=h.ms+1500;assert(h.H:Record({kills=4,deaths=6}))
    assert(h.P:SaveStore(h.H.StoreId,{reason='daily_dates_roundtrip',durable=true}))
    h.store.loaded=false;h.H.loaded=false;assert(h.H:EnsureLoaded())
    local reads,writes,revision=h.reads,h.writes,h.H.revision
    local p=h.H:GetProjection({fromDate='2026-10-07',toDate='2026-10-07'})
    assert(p.dateOptions and #p.dateOptions==3,'date picker needs the complete recorded-date catalog')
    assert(p.dateOptions[1]=='2026-10-09' and p.dateOptions[3]=='2026-10-05','catalog must be sorted and exclude unknown')
    assert(#p.rows==1 and p.rows[1].date=='2026-10-07' and p.totals.kills==5 and p.totals.deaths==1)
    p.dateOptions[1]='invalid';assert(h.H.state.days['2026-10-09'],'UI catalog must not alias persistent state')
    local all=h.H:GetProjection()
    assert(all.rows[1].date=='2026-10-09' and all.rows[#all.rows].date=='unknown','undated totals must follow the dated rows')
    assert(all.totals.kills==14 and all.totals.deaths==12,'date query must preserve all historical counts')
    assert(h.reads==reads and h.writes==writes and h.H.revision==revision,'date catalog projection must stay read-only')
end)
local function TruncatedHistory(h)
    local raw=dofile('tools/fixtures/combat_history_truncated_20261028.lua')
    local _,_,scope=h.P:ResolveStoreKey(h.store)
    raw.__rsmeta.scopeIdentityFingerprint=scope
    raw.__rsmeta.envelopeFingerprint=assert(h.P:FingerprintEnvelopeIntegrity(raw))
    return raw
end
Test('16383-byte native truncation recovers the exact original history and resaves compactly',function()
    local h=Boot();h.disk[h.key]=TruncatedHistory(h)
    assert(h.H:EnsureLoaded(),'proven truncated history remains fenced')
    local v=h.H.state;local row=assert(v.days['2026-10-24'])
    assert(v.totals.kills==353 and v.totals.deaths==138 and v.totals.damage==1366617152)
    assert(v.firstAt=='2026-10-05 01:11' and row.kills==36 and row.damage==113976877)
    assert(row.firstAt=='2026-10-24 10:30' and row.lastAt=='2026-10-24 14:39')
    assert(row.honorParticipations==nil and row.honorKills==nil,'recovery invented optional historical counts')
    assert(h.P:FingerprintCanonicalValue(h.store,v)=='624DEB3B','recovery did not reproduce the original stamp')
    assert(h.store.dirty and h.store.dueAt<=h.ms,'recovered physical representation was not queued for immediate rewrite')
    assert(h.P:SaveStore(h.H.StoreId,{durable=true}))
    assert(h.S.PersistenceTransport.EstimateNativeBytes(h.disk[h.key])<15000,'saved history can still be truncated')
    h.store.loaded=false;h.H.loaded=false;assert(h.H:EnsureLoaded())
    assert(h.H.state.days['2026-10-24'].damage==113976877 and h.clears==0)
end)
Test('unrecognized or modified truncated histories remain protected',function()
    for _,tamper in ipairs({'stamp','counter','timestamp'}) do
        local h=Boot();local raw=TruncatedHistory(h)
        if tamper=='stamp' then raw.__rsmeta.encodedFingerprint='11111111'
        elseif tamper=='counter' then raw.payload.totals.kills=354
        else raw.payload.days['2026-10-25'].firstAt='2026-10-25 10:00' end
        raw.__rsmeta.envelopeFingerprint=assert(h.P:FingerprintEnvelopeIntegrity(raw));h.disk[h.key]=raw
        local writes=h.writes
        assert(h.H:EnsureLoaded()~=true and h.store.writeFenced,'unproven repair accepted: '..tamper)
        assert(h.writes==writes and h.clears==0,'failed recovery changed the disk')
    end
end)
Test('compact physical history preserves optional zero and source strings without changing canonical',function()
    local h=Boot();assert(h.H:EnsureLoaded())
    h.H.state.totals.honorKills=0
    for day=1,28 do
        local date=string.format('2026-10-%02d',day)
        local row=h.H.TransferHelpers.counts(nil);row.kills=day;row.damage=100000000+day
        row.firstAt=date..' 10:00';row.lastAt=date..' 20:00';h.H.state.days[date]=row
    end
    assert(h.P:SaveStore(h.H.StoreId,{durable=true}))
    assert(h.S.PersistenceTransport.EstimateNativeBytes(h.disk[h.key])<15000,'ordinary month exceeds the physical budget')
    h.store.loaded=false;h.H.loaded=false;assert(h.H:EnsureLoaded())
    assert(h.H.state.totals.honorKills==0 and h.H.state.days['2026-10-28'].honorKills==nil)
    assert(h.H.state.days['2026-10-28'].damage==100000028)
    local t=h.S.PersistenceTransport
    local input={a='__rs_t3:z',b='__rs_t7:m',c='',d=false,e=0,f='123456789012345',g=1.25}
    local packed=assert(t.EncodeV7({payload=input}));local decoded=assert(t.DecodeV7(packed))
    assert(decoded.payload.a=='__rs_t3:z' and decoded.payload.b=='__rs_t7:m' and decoded.payload.c=='')
    assert(decoded.payload.d==false and decoded.payload.e==0 and decoded.payload.f=='123456789012345' and decoded.payload.g==1.25)
    packed.payload=packed.payload:sub(1,-2)
    assert(t.DecodeV7(packed)==nil,'truncated compact row was accepted')
end)
Test('long histories span bounded physical pages and a failed page cannot replace the committed history',function()
    local h=Boot();assert(h.H:EnsureLoaded());assert(h.P:SaveStore(h.H.StoreId,{durable=true}))
    for year=2020,2025 do for day=1,28 do
        local date=string.format('%04d-10-%02d',year,day)
        local row=h.H.TransferHelpers.counts(nil);row.damage=123456789;row.firstAt=date..' 10:00';row.lastAt=date..' 20:00'
        h.H.state.days[date]=row
    end end
    h.H.state.totals.damage=20740740552
    assert(h.P:SaveStore(h.H.StoreId,{durable=true}),'long history cannot be stored')
    local committed=h.disk[h.key]
    assert(committed.__rsPaged and committed.__rsPaged.count>1,'long history was not paged')
    for _,raw in pairs(h.disk)do assert(h.S.PersistenceTransport.EstimateNativeBytes(raw)<15000,'physical key exceeds the safe limit')end
    h.store.loaded=false;h.H.loaded=false;assert(h.H:EnsureLoaded())
    assert(h.H.state.days['2025-10-28'].damage==123456789 and h.H.state.totals.damage==20740740552)
    local rootSave=ADDON.SaveData
    h.H.state.totals.damage=20740740553
    ADDON.SaveData=function(self,key,raw)local ok=rootSave(self,key,raw);if key==h.key then return false end;return ok end
    assert(h.P:SaveStore(h.H.StoreId,{durable=true}),'complete root written despite Native false was not acknowledged')
    ADDON.SaveData=rootSave;committed=h.disk[h.key]
    local brokeRoot=false
    h.H.state.totals.damage=20740740554
    ADDON.SaveData=function(self,key,raw)
        if key==h.key and not brokeRoot then
            brokeRoot=true;raw=h.Copy(raw);raw.__rsPaged={version=1};rootSave(self,key,raw);return false
        end
        return rootSave(self,key,raw)
    end
    assert(h.P:SaveStore(h.H.StoreId,{durable=true})~=true,'partial root write was accepted')
    ADDON.SaveData=rootSave
    assert(h.disk[h.key].__rsPaged.checksum==committed.__rsPaged.checksum,'failed root did not restore the old manifest')
    committed=h.disk[h.key]
    h.H.state.totals.damage=20740740553
    local save=ADDON.SaveData
    ADDON.SaveData=function(self,key,raw)if key:find('_rs_page_',1,true)then return false end;return save(self,key,raw)end
    assert(h.P:SaveStore(h.H.StoreId,{durable=true})~=true,'failed page write was reported successful')
    ADDON.SaveData=save
    assert(h.disk[h.key]==committed and h.clears==0,'failed page replaced the active manifest')
    -- 真正重载会建立新 Runtime；旧 Runtime 对未完成写入保留 dirty barrier 是正确行为。
    local nextHost=Boot({disk=h.disk});assert(nextHost.H:EnsureLoaded())
    assert(nextHost.H.state.totals.damage==20740740553,'failed transaction changed the committed total')
    nextHost.H.state.totals.damage=20740740554
    local nextSave=ADDON.SaveData
    ADDON.SaveData=function(self,key,raw)
        if key:find('_rs_page_',1,true)then raw=nextHost.Copy(raw);raw.data=raw.data:sub(1,-3)end
        return nextSave(self,key,raw)
    end
    assert(nextHost.P:SaveStore(nextHost.H.StoreId,{durable=true})~=true,'truncated page was committed')
    ADDON.SaveData=nextSave
    assert(nextHost.disk[nextHost.key]==committed,'truncated inactive bank replaced the active bank')
    local rollbackDisk=nextHost.Copy(nextHost.disk)
    nextHost.disk[nextHost.key..'_rs_page_'..committed.__rsPaged.bank..'_1']=nil
    local broken=Boot({disk=nextHost.disk});local afterWrites=broken.writes
    assert(broken.H:EnsureLoaded()~=true and broken.writes==afterWrites,'missing page was silently treated as empty history')
    local rollback=Boot({disk=nextHost.Copy(rollbackDisk)});assert(rollback.H:EnsureLoaded())
    rollback.H.state.totals.damage=20740740555
    local rollbackSave=ADDON.SaveData
    ADDON.SaveData=function(self,key,raw)
        if key==rollback.key then
            raw=rollback.Copy(raw);raw.__rsPaged={version=1};rollbackSave(self,key,raw);return false
        end
        return rollbackSave(self,key,raw)
    end
    local ok,err=rollback.P:SaveStore(rollback.H.StoreId,{durable=true})
    ADDON.SaveData=rollbackSave
    assert(ok~=true and tostring(err):find('paged_root_restore_failed',1,true),'failed rollback was hidden')
    assert(rollback.store.needsBarrierVerify,'unverified root lost the write barrier')
    local small=Boot({disk=rollbackDisk});assert(small.H:EnsureLoaded())
    local smallRoot=small.disk[small.key];local smallSave=ADDON.SaveData;local dropped=false
    ADDON.SaveData=function(self,key,raw)
        if key==small.key and not dropped then
            dropped=true;smallSave(self,key,{__rsmeta=raw.__rsmeta});return false
        end
        return smallSave(self,key,raw)
    end
    assert(small.P:SaveValue(small.H.StoreId,small.H:NormalizeState(nil),{durable=true})~=true)
    ADDON.SaveData=smallSave
    assert(small.disk[small.key].__rsPaged and small.disk[small.key].__rsPaged.checksum==smallRoot.__rsPaged.checksum,
        'failed large-to-small root write lost the paged history')
    local cleared=Boot({disk=small.disk});assert(cleared.H:EnsureLoaded())
    local clearSave=ADDON.SaveData
    ADDON.SaveData=function(self,key,raw)local saved=clearSave(self,key,raw);if key==cleared.key then return false end;return saved end
    assert(cleared.P:SaveValue(cleared.H.StoreId,cleared.H:NormalizeState(nil),{durable=true}),
        'complete inline root written despite false was not acknowledged')
    ADDON.SaveData=clearSave
    local cold=Boot({disk=cleared.disk});assert(cold.H:EnsureLoaded())
    assert(cold.H.state.totals.damage==0 and next(cold.H.state.days)==nil,'retired pages resurrected after inline commit')
end)
Test('the full 2048-day retention survives paged bank rotation',function()
    local h=Boot();assert(h.H:EnsureLoaded())
    for i=1,2048 do
        local date=string.format('%04d-%02d-%02d',2020+math.floor((i-1)/336),math.floor((i-1)/28)%12+1,(i-1)%28+1)
        local row=h.H.TransferHelpers.counts(nil);row.damage=123456789
        row.firstAt=date..' 10:00';row.lastAt=date..' 20:00';h.H.state.days[date]=row
    end
    h.H.state.totals.damage=252839503872
    assert(h.P:SaveStore(h.H.StoreId,{durable=true}))
    local first=h.disk[h.key].__rsPaged.bank
    h.H.state.days['2020-01-01'].damage=123456790;h.H.state.totals.damage=252839503873
    assert(h.P:SaveStore(h.H.StoreId,{durable=true}))
    assert(h.disk[h.key].__rsPaged.bank==3-first,'new commit did not rotate away from the active bank')
    h.store.loaded=false;h.H.loaded=false;assert(h.H:EnsureLoaded())
    local count=0;for _ in pairs(h.H.state.days)do count=count+1 end
    assert(count==2048 and h.H.state.days['2020-01-01'].damage==123456790)
    assert(h.H.state.totals.damage==252839503873 and h.clears==0,'bank rotation changed historical totals')
end)
print('RESULT combat-history passed='..passed..' failed='..failed)
if failed>0 then os.exit(1)end

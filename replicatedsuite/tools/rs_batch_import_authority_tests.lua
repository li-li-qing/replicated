-- 维护：真实 Core/Store/RSUI Diff；Native 仅模拟键入和第189项起缺失，不宣称RU内部硬上限。
local passed,failed=0,0
local function Test(name,fn)
 local ok,err=xpcall(fn,function(e)return tostring(e)..'\n'..debug.traceback()end)
 if ok then passed=passed+1;print('PASS batch-authority '..name)else failed=failed+1;print('FAIL batch-authority '..name..': '..err)end
end
local function Copy(v)if type(v)~='table'then return v end;local o={};for k,x in pairs(v)do o[k]=Copy(x)end;return o end
local function Equal(a,b)if type(a)~=type(b)then return false end;if type(a)~='table'then return a==b end;for k,v in pairs(a)do if not Equal(v,b[k])then return false end end;for k in pairs(b)do if a[k]==nil then return false end end;return true end

local function DropObservedV4ChunkField(v)
 if type(v)~='table'then return v end
 local o={};for k,x in pairs(v)do o[k]=DropObservedV4ChunkField(x)end
 if o['__rs_t4:a']==1 and o.p25~=nil then o.p25=nil end
 return o
end
local function LimitNative(v)
 if type(v)~='table'then return v end
 local o={};for k,x in pairs(v)do if type(k)~='number' or k<189 then o[k]=LimitNative(x)end end;return o
end
local function Boot(options)
 options=options or {};local io={disk=Copy(options.disk or {}),writes=0,reads=0,clears=0}
 ADDON={SaveData=function(_,k,v)io.writes=io.writes+1;io.disk[k]=options.loss==false and Copy(v)or LimitNative(v);if io.damage then io.damage(io.disk[k])end;return true end,
 LoadData=function(_,k)io.reads=io.reads+1;return Copy(io.disk[k])end,ClearData=function()io.clears=io.clears+1;error('unexpected clear')end}
 ReplicatedSuite={Features={},Services={},RSUI={},UI={CreateWindowShell=function()end},NowMs=function()return 1000 end,Generation=1,
 SafeTraceback=function(e)return tostring(e)end,FeatureRuntime={RegisterImplementation=function()return true end,IsEnabled=function()return false end}}
 local S=ReplicatedSuite
 for _,f in ipairs({'core/rs_utils.lua','core/rs_reuse.lua','core/rs_api.lua','core/rs_api_capabilities.lua','core/rs_events.lua','core/rs_scheduler.lua','core/rs_persistence.lua','core/rs_demand.lua',
 'data/rs_data_registry.lua','data/rs_skill_effects.lua','data/rs_combat_ability_catalog.lua','data/ids/rs_buff_ids.lua','data/ids/rs_plates_ids.lua','services/rs_status_classification_v3.lua','data/rs_status_tracking_catalog.lua','services/rs_buff_metadata_v3.lua','ui/framework/rs_ui_floating_surface.lua',
 'features/combat/buff_display/rs_buff_display_store.lua','features/combat/buff_display/rs_buff_display_projection.lua','features/combat/buff_display/rs_buff_display_feature.lua','features/combat/buff_display/rs_buff_display_management.lua','features/combat/buff_display/rs_buff_display_transfer_v2.lua'})do dofile(f)end
 local F=S.Features.BuffDisplay;return S,F,S.Persistence,io
end
Test('existing schema8 transport4 disk repairs one missing scoped chunk from its exact twin then rewrites transport5',function()
 local _,F,P,io=Boot({loss=false});assert(F:EnsureStoreLoaded());local st=P:GetStore('v3.buff_display');st.transportVersion=4
 assert(F:ImportBuiltinPack('recommended',false));local key=st.resolvedKey;assert(io.disk[key].__rsmeta.transportVersion==4)
 local victim=io.disk[key].payload.settings.tracked.target.auto;assert(victim and victim.p25);victim.p25=nil
 local _,fresh,freshP,fio=Boot({disk=io.disk,loss=false});local ok,why=fresh:EnsureStoreLoaded();assert(ok,why)
 assert(#fresh.State.settings.tracked.player.auto==397 and #fresh.State.settings.tracked.target.auto==397)
 local freshStore=freshP:GetStore('v3.buff_display');assert(freshStore.transportVersion==5 and freshStore.lastPhysicalTransportRepairOk==true)
 assert(freshP:Flush('v3.buff_display'));assert(fio.disk[freshStore.resolvedKey].__rsmeta.transportVersion==5)
end)
Test('transport5 readback reconstructs one physically omitted scoped auto field only by exact sibling plus stamped fingerprint',function()
 local _,F,P,io=Boot({loss=false});assert(F:EnsureStoreLoaded())
 local damaged=false
 io.damage=function(raw)
  if damaged then return end
  damaged=true
  assert(raw.__rsmeta.transportVersion==5,'fixture must exercise transport5')
  raw.payload.settings.tracked.player.auto=nil
 end
 local ok,why=F:ImportBuiltinPack('recommended',false)
 assert(ok,why)
 assert(#F.State.settings.tracked.player.auto==397 and #F.State.settings.tracked.target.auto==397)
 local st=P:GetStore('v3.buff_display')
 assert(st.lastVerifyOk==true,'current core must prove exact readback recovery')
 assert(st.lastReadbackRepresentationRecovered==true,'omitted field must be recovered only inside verification proof')
 local saved=Copy(io.disk[st.resolvedKey])
 assert(saved.payload.settings.tracked.player.auto==nil,'fixture must retain the physical omission on disk')
 local savedDisk={[st.resolvedKey]=saved}
 local _,fresh,freshP=Boot({disk=savedDisk,loss=false});local loaded,loadWhy=fresh:EnsureStoreLoaded();assert(loaded,loadWhy)
 assert(#fresh.State.settings.tracked.player.auto==397 and #fresh.State.settings.tracked.target.auto==397)
 local fst=freshP:GetStore('v3.buff_display')
 assert(fst.lastIntegrityStatus=='verified_canonical_recovered_representation','load must record exact representational recovery')
end)
Test('transport5 readback reconstructs observed scoped auto prefix truncation only by exact sibling plus stamped fingerprint',function()
 local _,F,P,io=Boot({loss=false});assert(F:EnsureStoreLoaded())
 local damaged=false
 io.damage=function(raw)
  if damaged then return end
  damaged=true
  assert(raw.__rsmeta.transportVersion==5,'fixture must exercise transport5')
  local player=raw.payload.settings.tracked.player.auto
  local target=raw.payload.settings.tracked.target.auto
  assert(player and target and player['__rs_t5:a']==1 and target['__rs_t5:a']==1)
  assert(player.count==397 and target.count==397 and type(player.chunks)=='table' and type(target.chunks)=='table')
  -- 中文维护注释（.18.240 RED fixture）：复刻 .239 实机 RAW_STORE：player.auto 的
  -- marker/count 被 Native 整体省略，chunks 只保留前 19 块，且第 19 块再丢最后一个 token；
  -- target.auto 仍完整。此夹具只验证“严格物理前缀 + twin + stamped 全 Store 指纹”恢复，
  -- 不把任意稀疏/改值/合法 scope 分叉提升成恢复 Authority。
  player['__rs_t5:a']=nil
  player.count=nil
  for index=20,25 do player.chunks[index]=nil end
  player.chunks[19]=assert(player.chunks[19]):gsub(',[^,]+$','')
 end
 local ok,why=F:ImportBuiltinPack('recommended',false)
 assert(ok,why)
 local st=P:GetStore('v3.buff_display')
 assert(st.lastVerifyOk==true,'observed t5 prefix truncation must be recoverable only for readback proof')
 assert(st.lastReadbackRepresentationRecovered==true,'prefix truncation recovery proof was not recorded')
end)
Test('transport5 readback accepts a final chunk truncated inside the last numeric token only under exact whole-store fingerprint proof',function()
 local _,F,P,io=Boot({loss=false});assert(F:EnsureStoreLoaded())
 local damaged=false
 io.damage=function(raw)
  if damaged then return end
  damaged=true
  local player=raw.payload.settings.tracked.player.auto
  local target=raw.payload.settings.tracked.target.auto
  assert(player and target and player['__rs_t5:a']==1 and target['__rs_t5:a']==1)
  player['__rs_t5:a']=nil;player.count=nil
  for index=20,25 do player.chunks[index]=nil end
  local full=assert(player.chunks[19])
  assert(#full>3 and full:sub(-3):match('%d%d%d'),'fixture needs a numeric tail')
  player.chunks[19]=full:sub(1,#full-2) -- .241 实机：最后一个 ID 在数字中间被 Native 截断，而不是只丢完整 token。
  assert(target.chunks[19]:sub(1,#player.chunks[19])==player.chunks[19],'fixture must be a strict byte prefix of intact twin')
 end
 local ok,why=F:ImportBuiltinPack('recommended',false);assert(ok,why)
 local st=P:GetStore('v3.buff_display')
 assert(st.lastVerifyOk==true,'mid-token prefix truncation must be recoverable only by exact whole-store fingerprint proof')
 assert(st.lastReadbackRepresentationRecovered==true,'mid-token readback recovery proof was not recorded')
 assert(tostring(st.lastReadbackRecoveryProbe or ''):find('mode=byte',1,true),'probe must distinguish byte-prefix truncation from token-boundary loss')
end)
Test('transport5 fresh load accepts the .241 mid-token scoped auto truncation but still requires the original stamped fingerprint',function()
 local _,F,P,io=Boot({loss=false});assert(F:EnsureStoreLoaded());assert(F:ImportBuiltinPack('recommended',false))
 local st=P:GetStore('v3.buff_display');local key=st.resolvedKey
 local saved=Copy(io.disk[key]);local player=saved.payload.settings.tracked.player.auto
 local target=saved.payload.settings.tracked.target.auto
 assert(player and target and player['__rs_t5:a']==1 and player.count==397 and type(player.chunks)=='table')
 player['__rs_t5:a']=nil;player.count=nil
 for index=20,25 do player.chunks[index]=nil end
 local full=assert(player.chunks[19]);player.chunks[19]=full:sub(1,#full-2)
 local _,fresh,freshP=Boot({disk={[key]=saved},loss=false});local ok,why=fresh:EnsureStoreLoaded();assert(ok,why)
 assert(#fresh.State.settings.tracked.player.auto==397 and #fresh.State.settings.tracked.target.auto==397)
 local fst=freshP:GetStore('v3.buff_display')
 assert(fst.lastIntegrityStatus=='verified_canonical_recovered_representation','fresh load must authenticate byte-prefix repair with the original stamp')
 assert(tostring(fst.lastHistoricalRecoveryProbe or ''):find('mode=byte',1,true),'load probe must show the mid-token byte-prefix path')
end)
Test('transport5 fresh load reconstructs observed scoped auto prefix truncation from exact sibling plus stamped fingerprint',function()
 local _,F,P,io=Boot({loss=false});assert(F:EnsureStoreLoaded());assert(F:ImportBuiltinPack('recommended',false))
 local st=P:GetStore('v3.buff_display');local key=st.resolvedKey
 local saved=Copy(io.disk[key]);local player=saved.payload.settings.tracked.player.auto
 assert(player and player['__rs_t5:a']==1 and player.count==397 and type(player.chunks)=='table')
 player['__rs_t5:a']=nil;player.count=nil
 for index=20,25 do player.chunks[index]=nil end
 player.chunks[19]=assert(player.chunks[19]):gsub(',[^,]+$','')
 local _,fresh,freshP=Boot({disk={[key]=saved},loss=false});local ok,why=fresh:EnsureStoreLoaded();assert(ok,why)
 assert(#fresh.State.settings.tracked.player.auto==397 and #fresh.State.settings.tracked.target.auto==397)
 local fst=freshP:GetStore('v3.buff_display')
 assert(fst.lastIntegrityStatus=='verified_canonical_recovered_representation','fresh load must authenticate prefix repair with stamped fingerprint')
end)
Test('transport5 prefix truncation cannot borrow sibling when scoped auto legitimately diverged',function()
 local _,F,P,io=Boot({loss=false});assert(F:EnsureStoreLoaded());assert(F:ImportBuiltinPack('recommended',false))
 assert(F:MutateStore(function()
  table.remove(F.State.settings.tracked.player.auto,1)
  return true
 end,0,'scope-auto-prefix-divergence',true))
 assert(#F.State.settings.tracked.player.auto==396 and #F.State.settings.tracked.target.auto==397)
 local damaged=false
 io.damage=function(raw)
  if damaged then return end
  damaged=true
  local player=raw.payload.settings.tracked.player.auto
  assert(player and player['__rs_t5:a']==1 and type(player.chunks)=='table')
  player['__rs_t5:a']=nil
  player.count=nil
  for index=20,25 do player.chunks[index]=nil end
  player.chunks[19]=assert(player.chunks[19]):gsub(',[^,]+$','')
 end
 local ok,why=P:SaveStore('v3.buff_display',{force=true,durable=true})
 assert(not ok and tostring(why):find('readback_verify_failed',1,true),why)
 local st=P:GetStore('v3.buff_display')
 assert(st.lastReadbackRepresentationRecovered~=true,'diverged scopes must not be accepted through prefix twin recovery')
 assert(tostring(st.lastVerifyError or ''):find('readback_fingerprint_mismatch',1,true),'must remain fail-closed on fingerprint mismatch')
end)
Test('transport5 prefix truncation cannot erase hidden same-prefix scoped divergence',function()
 local _,F,P,io=Boot({loss=false});assert(F:EnsureStoreLoaded());assert(F:ImportBuiltinPack('recommended',false))
 assert(F:MutateStore(function()
  F.State.settings.tracked.player.auto[350]=999999
  return true
 end,0,'scope-auto-hidden-prefix-divergence',true))
 assert(#F.State.settings.tracked.player.auto==397 and #F.State.settings.tracked.target.auto==397)
 local damaged=false
 io.damage=function(raw)
  if damaged then return end
  damaged=true
  local player=raw.payload.settings.tracked.player.auto
  player['__rs_t5:a']=nil;player.count=nil
  for index=20,25 do player.chunks[index]=nil end
  player.chunks[19]=assert(player.chunks[19]):gsub(',[^,]+$','')
 end
 local ok,why=P:SaveStore('v3.buff_display',{force=true,durable=true})
 assert(not ok and tostring(why):find('readback_verify_failed',1,true),why)
 local st=P:GetStore('v3.buff_display')
 assert(st.lastReadbackRepresentationRecovered~=true,'same-prefix hidden divergence must stay fenced')
 assert(tostring(st.lastVerifyError or ''):find('readback_fingerprint_mismatch',1,true),'whole-store fingerprint must reject hidden divergence')
end)
Test('transport5 omitted auto cannot borrow sibling when scoped auto legitimately diverged',function()
 local _,F,P,io=Boot({loss=false});assert(F:EnsureStoreLoaded());assert(F:ImportBuiltinPack('recommended',false))
 assert(F:MutateStore(function()
  table.remove(F.State.settings.tracked.player.auto,1)
  return true
 end,0,'scope-auto-divergence',true))
 assert(#F.State.settings.tracked.player.auto==396 and #F.State.settings.tracked.target.auto==397)
 local damaged=false
 io.damage=function(raw)
  if damaged then return end
  damaged=true
  raw.payload.settings.tracked.player.auto=nil
 end
 local ok,why=P:SaveStore('v3.buff_display',{force=true,durable=true})
 assert(not ok and tostring(why):find('readback_verify_failed',1,true),why)
 local st=P:GetStore('v3.buff_display')
 assert(st.lastReadbackRepresentationRecovered~=true,'diverged scopes must never be accepted through twin recovery')
 assert(tostring(st.lastVerifyError or ''):find('readback_fingerprint_mismatch',1,true),'must remain fail-closed on exact fingerprint mismatch')
end)
Test('transport5 target auto omission is symmetric when both scopes are identical',function()
 local _,F,P,io=Boot({loss=false});assert(F:EnsureStoreLoaded())
 local damaged=false
 io.damage=function(raw)
  if damaged then return end
  damaged=true
  raw.payload.settings.tracked.target.auto=nil
 end
 local ok,why=F:ImportBuiltinPack('recommended',false);assert(ok,why)
 assert(#F.State.settings.tracked.player.auto==397 and #F.State.settings.tracked.target.auto==397)
 local st=P:GetStore('v3.buff_display');assert(st.lastReadbackRepresentationRecovered==true)
end)
Test('transport4 recovery ignores complete scoped categories that legitimately differ',function()
 local _,F,P,io=Boot({loss=false});assert(F:EnsureStoreLoaded());local st=P:GetStore('v3.buff_display');st.transportVersion=4
 assert(F:ImportBuiltinPack('recommended',false))
 assert(F:MutateStore(function()
  F.State.settings.tracked.player.buff={};F.State.settings.tracked.target.buff={}
  for i=1,40 do F.State.settings.tracked.player.buff[i]=1000+i;F.State.settings.tracked.target.buff[i]=2000+i end
  return true
 end,0,'scope-difference-v4',true))
 local key=st.resolvedKey;local victim=io.disk[key].payload.settings.tracked.target.auto;assert(victim and victim.p25);victim.p25=nil
 local _,fresh=Boot({disk=io.disk,loss=false});local ok,why=fresh:EnsureStoreLoaded();assert(ok,why)
 assert(fresh.State.settings.tracked.player.buff[1]==1001 and fresh.State.settings.tracked.target.buff[1]==2001)
 assert(#fresh.State.settings.tracked.player.auto==397 and #fresh.State.settings.tracked.target.auto==397)
end)
Test('schema8 scoped tracking survives observed v4 p-chunk omission with transport5',function()
 local S,F,P,io=Boot({loss=false});io.damage=function(raw)local damaged=DropObservedV4ChunkField(raw);for k in pairs(raw)do raw[k]=nil end;for k,v in pairs(damaged)do raw[k]=v end end
 assert(F:EnsureStoreLoaded());local ok,why=F:ImportBuiltinPack('recommended',false);assert(ok,why)
 local st=P:GetStore('v3.buff_display');assert(st.transportVersion==5,'buff store must use transport5 after real v4 missing-chunk evidence')
 assert(#F.State.settings.tracked.player.auto==397 and #F.State.settings.tracked.target.auto==397)
 local _,fresh=Boot({disk=io.disk,loss=false});assert(fresh:EnsureStoreLoaded());assert(#fresh.State.settings.tracked.player.auto==397 and #fresh.State.settings.tracked.target.auto==397)
end)
Test('397 recommended IDs survive native loss starting at array index 189',function()
 local S,F,P,io=Boot();assert(F:EnsureStoreLoaded());local before=io.writes
 local ok,why=F:ImportBuiltinPack('recommended',false);assert(ok,why)
 assert(#F.State.settings.tracked.player.auto==397 and #F.State.settings.tracked.target.auto==397 and io.writes==before+1)
 local st=P:GetStore('v3.buff_display');local expected=Copy(F.State);local saved=io.disk[st.resolvedKey]
 assert(saved.__rsmeta.transportVersion==5,'status store must explicitly select bounded-vector transport')
 local _,fresh,_,fio=Boot({disk=io.disk});assert(fresh:EnsureStoreLoaded());assert(Equal(expected,fresh.State));assert(fio.writes==0 and fio.clears==0)
end)
Test('repeat import is idempotent and remove survives fresh reload',function()
 local _,F,P,io=Boot();assert(F:EnsureStoreLoaded());assert(F:ImportBuiltinPack('recommended',false));assert(F:ImportBuiltinPack('recommended',false))
 assert(#F.State.settings.tracked.player.auto==397 and #F.State.settings.tracked.target.auto==397);local id=F.State.settings.tracked.player.auto[189];assert(F:SetTrackedId(id,'auto',false));assert(P:Flush('v3.buff_display'))
 local _,nextF=Boot({disk=io.disk});assert(nextF:EnsureStoreLoaded());assert(not nextF:IsTrackedId(id) and #nextF.State.settings.tracked.player.auto==396 and #nextF.State.settings.tracked.target.auto==396)
end)
Test('legacy transport3 remains readable with full tracked list and no forced save',function()
 local _,F,P,io=Boot({loss=false});assert(F:EnsureStoreLoaded());local st=P:GetStore('v3.buff_display');st.transportVersion=3
 assert(F:ImportBuiltinPack('recommended',false));assert(io.disk[st.resolvedKey].__rsmeta.transportVersion==3)
 local _,fresh,_,fio=Boot({disk=io.disk});assert(fresh:EnsureStoreLoaded());assert(#fresh.State.settings.tracked.player.auto==397 and #fresh.State.settings.tracked.target.auto==397 and fio.writes==0)
end)
Test('transport4 physical layout reconstructs exact canonical values and escapes marker collisions',function()
 local _,_,P=Boot()
 for _,n in ipairs({0,1,16,32,33,188,189,397,1024,2048})do
  local ids={};for i=1,n do ids[i]=100000+i end
  local input={payload={ids=ids,['__rs_t4:a']='literal',s='__rs_t4:hello',zero=0,f=false,small=0.00000003},__rsmeta={framework=3,transportVersion=4}}
  local raw,err=P:EncodePhysicalEnvelope(input);assert(raw,err);local parsed,err=P:DecodePhysicalEnvelope(LimitNative(raw));assert(parsed,err);assert(Equal(input,parsed),'count '..n)
 end
end)
Test('missing chunk is rejected before applying or normalizing a partial list',function()
 local _,F,P,io=Boot();assert(F:EnsureStoreLoaded());local before=Copy(F.State)
 io.damage=function(raw)local a=raw.payload.settings.tracked.player.auto;a.chunks[2]=nil end
 local ok,why=F:ImportBuiltinPack('recommended',false);assert(not ok and tostring(why):find('transport',1,true),why)
 assert(Equal(before,F.State) and io.clears==0 and F.lastLibraryImport.ok==false)
end)
Test('same-length corrupt ID is rejected by original whole-config fingerprint',function()
 local _,F,P,io=Boot();assert(F:EnsureStoreLoaded());local before=Copy(F.State)
 io.damage=function(raw)local a=raw.payload.settings.tracked.player.auto;if a.chunks and a.chunks[1] then a.chunks[1]=a.chunks[1]:gsub('^%d+','99999')end end
 local ok,why=F:ImportBuiltinPack('recommended',false);assert(not ok and tostring(why):find('mismatch',1,true),why);assert(Equal(before,F.State))
end)
Test('legacy truncated save still fences instead of inventing missing IDs',function()
 local _,F,P,io=Boot({loss=false});assert(F:EnsureStoreLoaded());local st=P:GetStore('v3.buff_display');st.transportVersion=3;assert(F:ImportBuiltinPack('recommended',false))
 io.disk[st.resolvedKey]=LimitNative(io.disk[st.resolvedKey]);local _,fresh,_,fio=Boot({disk=io.disk});assert(not fresh:EnsureStoreLoaded());assert(fio.writes==0 and fio.clears==0)
end)
Test('other stores keep default physical transport3',function()
 local S,F,P,io=Boot();local value={n=1};local st=assert(P:RegisterV3Store({id='v3.test_default',owner='v3.test_default',key=P.V3KeyPrefix..'test_default',scope=P.Scope.Account,lifetime=P.Lifetime.Permanent,schemaVersion=1,budget={maxDepth=4,maxNodes=128,maxStringBytes=2048,maxEntriesPerTable=64},default=function()return value end,get=function()return value end,apply=function(v)value=v end}))
 assert(P:LoadStore(st.id));assert(P:SaveStore(st.id,{force=true,durable=true}));assert(io.disk[st.resolvedKey].__rsmeta.transportVersion==3)
end)
-- 维护：坏分块必须在业务Normalize前拒绝；这些数据是合成故障，不是额外用户存档。
Test('noncanonical escape marker is rejected rather than normalizing forged content',function()
 local _,_,P=Boot();local value,err=P:DecodePhysicalEnvelope({__rsmeta={framework=3,transportVersion=4},payload={name='__rs_t4:snot_reserved'}})
 assert(value==nil and tostring(err):find('transport',1,true),'invalid escaped token was accepted')
end)
Test('malformed chunk shape rejects sparse counts duplicate separators leading zero and extras',function()
 local _,_,P=Boot();local ids={};for i=1,397 do ids[i]=i end
 local source=assert(P:EncodePhysicalEnvelope({__rsmeta={framework=3,transportVersion=4},payload={ids=ids}}))
 local cases={
  function(t)t.p2=nil end,function(t)t.count=398 end,function(t)t.count=2049 end,
  function(t)t.count=0/0 end,function(t)t.count='397'end,function(t)t['__rs_t4:a']=2 end,
  function(t)t.p01=t.p1;t.p1=nil end,function(t)t.extra='1'end,function(t)t.p1=t.p1..','end,
  function(t)t.p1=t.p1:gsub(',','',1)end,function(t)t.p1='0'..t.p1 end,
  function(t)t.p1=t.p1:gsub('1,','16777217,',1)end,function(t)t.p1=t.p1:gsub('1,','1e0,',1)end,
  function(t)t.p1=string.rep('9',144)end,function(t)t.p1=5 end}
 for i,f in ipairs(cases)do local raw=Copy(source);f(raw.payload.ids);local out,err=P:DecodePhysicalEnvelope(raw);assert(not out and err,'accepted invalid vector '..i)end
end)
Test('mixed sparse and non-ID arrays remain exact without vector coercion',function()
 local _,_,P=Boot();local input={__rsmeta={framework=3,transportVersion=4},payload={
 sparse={[1]=2,[40]=4},negative={-1,-2},zero={0,1},decimal={0.25,1.1},big={16777217,1},
 nested={['__rs_t4:a']={['__rs_t4:s']='__rs_t4:s__rs_t4:a'},['__rs_t3:n']='__rs_t3:s'}, chinese='中文配置'}}
 local raw=assert(P:EncodePhysicalEnvelope(input));local out=assert(P:DecodePhysicalEnvelope(raw));assert(Equal(input,out))
end)
Test('all six scoped tracking buckets round-trip without 188-entry truncation',function()
 local _,F,P,io=Boot();assert(F:EnsureStoreLoaded())
 assert(F:MutateStore(function()for scopeIndex,scope in ipairs({'player','target'})do for offset,bucket in ipairs({'buff','debuff','auto'})do for i=1,512 do F.State.settings.tracked[scope][bucket][i]=100000*scopeIndex+10000*offset+i end end end;return true end,0,'six-bucket-test',true))
 local state=Copy(F.State);local _,fresh=Boot({disk=io.disk});assert(fresh:EnsureStoreLoaded());assert(Equal(state,fresh.State))
end)
Test('old failed import rollback is no longer rewritten by unrelated HUD save',function()
 local _,F,P,io=Boot();assert(F:EnsureStoreLoaded());local st=P:GetStore('v3.buff_display');st.transportVersion=3
 local before=Copy(F.State);local ok,err=F:ImportBuiltinPack('recommended',false)
 assert(not ok and err:find('player.auto.189',1,true),err);assert(Equal(before,F.State))
 local bad=Copy(io.disk);local mainKey=st.resolvedKey
 -- .18.241 Authority 边界：HUD 保存只能写 v3.buff_display.layout，不能再利用“顺手重写主 Store”
 -- 去修 tracking 事故。旧测试依赖的是错误耦合；这里明确证明布局保存既不改变回滚后的 Domain，
 -- 也不碰主 Store 失败证据。需要修主 Store 时必须经过主 Store 自己的 Persistence Authority。
 assert(F:PersistHudCalibrationSnapshot(F:GetHudCalibrationSnapshot(),'before_reload'))
 assert(Equal(before,F.State) and Equal(io.disk[mainKey],bad[mainKey]),'HUD save rewrote failed tracking Store')
 local _,broken=Boot({disk=bad});assert(not broken:EnsureStoreLoaded(),'legacy bad tracking disk was accidentally hidden')
 -- 这个夹具故意模拟已经淘汰的 Transport3 + 189 截断；.241 不再允许 HUD 越权把它
 -- “顺手修好”。当前 Transport5 的正式恢复能力由上方 scoped omission/prefix 用例独立证明。
end)

local GearBoot=dofile('tools/rs_gear_page_test_host.lua')
local function RealDiffHost()
 local h=GearBoot();local UI=h.UI;local oldActivate,oldDeactivate=UI.ActivateInputWidget,UI.DeactivateInputWidget
 dofile('ui/rs_ui_framework.lua')
 -- Native键入仍是替身；Diff缓存/claim/keyboard生命周期都改用生产函数。
 for _,id in ipairs({'v3_gear_create_edit','v3_gear_name_edit'})do
  local c=h.widgets[id];local n=c.root;n.rsUiLogicalId=id;n.rsUiKeyboardInput=true;n.rsUiOwner=c.owner;n.rsUiKeyboardArmed=false
  function n:EnableKeyboard(v)self.keyboard=v end;function n:SetFocus()UI.focused=self end;function n:ClearFocus()UI.focused=nil end
  assert(UI:ClaimNativeAuthority(n,c.owner,'strict'));UI:PrimeNativeState(n,{text=n.text})
 end
 UI.IsInputWidgetFocused=function(_,n)return UI.focused==n end
 UI.ReleaseFocusWithin=function(_,n)if UI.focused==n then UI.focused=nil end;return true,false end
 UI.TryInteractionCall=function(_,n,method,...)return pcall(n[method],n,...)end
 return h
end
Test('typing then successful Create clears field without false strict-authority repair',function()
 local h=RealDiffHost();local n=h.widgets.v3_gear_create_edit;assert(n:BeginEditing());n.root.text='合法草稿';assert(h.page:CreateSet())
 assert(h.UI:GetAuthoritySnapshot().violations==0,'legitimate keyboard draft was flagged as external write');assert(n:GetDraftValue()=='')
end)
Test('cancel and rejected input restore committed text without false-authority violation',function()
 local h=RealDiffHost();local c=h.widgets.v3_gear_create_edit;assert(c:BeginEditing());c.root.text='取消草稿';assert(c:CancelEditing())
 assert(c:GetDraftValue()=='' and h.UI:GetAuthoritySnapshot().violations==0)
end)
Test('inactive external edits remain strict-authority violations',function()
 local h=RealDiffHost();local c=h.widgets.v3_gear_create_edit;c.root.text='外部篡改';h.UI:SetText(c.root,'',c.owner)
 assert(h.UI:GetAuthoritySnapshot().violations==1,'fix must not globally suppress authority checks')
end)
Test('foreign owner cannot adopt a keyboard draft',function()
 local h=RealDiffHost();local c=h.widgets.v3_gear_create_edit;assert(c:BeginEditing());c.root.text='草稿'
 assert(type(h.UI.AdoptInputDraftText)=='function','draft handoff missing');assert(not h.UI:AdoptInputDraftText(c.root,'v3:other'))
end)
print('BATCH AUTHORITY RESULT '..passed..' passed / '..failed..' failed ('.._VERSION..')')
if failed>0 then error('batch-authority failures: '..failed)end

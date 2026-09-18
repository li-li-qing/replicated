-- 维护（2026-09-17，RU v4 双副本同段丢失回归）：
-- schema7->8 会把旧全局追踪复制到 player/target；实机可能在两个 v4 vector 表中都丢失同一 pN，
-- 此时“另一 scope 作为 twin”也不够。测试只允许从已声明导入的静态 Catalog 构造有限候选，
-- 且生产 Load 后仍必须通过原 envelope + canonical fingerprint，禁止猜测用户 ID。
local passed,failed=0,0
local function Test(name,fn)
 local ok,err=xpcall(fn,function(e)return tostring(e)..'\n'..debug.traceback()end)
 if ok then passed=passed+1;print('PASS transport4-dual-loss '..name)else failed=failed+1;print('FAIL transport4-dual-loss '..name..': '..err)end
end
local function Copy(v)if type(v)~='table'then return v end;local o={};for k,x in pairs(v)do o[k]=Copy(x)end;return o end
local function Boot(options)
 options=options or {};local io={disk=Copy(options.disk or {}),writes=0,reads=0,clears=0}
 ADDON={SaveData=function(_,k,v)io.writes=io.writes+1;io.disk[k]=Copy(v);return true end,
 LoadData=function(_,k)io.reads=io.reads+1;return Copy(io.disk[k])end,ClearData=function()io.clears=io.clears+1;error('unexpected clear')end}
 ReplicatedSuite={Features={},Services={},RSUI={},UI={CreateWindowShell=function()end},NowMs=function()return 1000 end,Generation=1,
 SafeTraceback=function(e)return tostring(e)end,FeatureRuntime={RegisterImplementation=function()return true end,IsEnabled=function()return false end}}
 local S=ReplicatedSuite
 for _,f in ipairs({'core/rs_utils.lua','core/rs_reuse.lua','core/rs_api.lua','core/rs_api_capabilities.lua','core/rs_events.lua','core/rs_scheduler.lua','core/rs_persistence.lua','core/rs_demand.lua',
 'data/rs_data_registry.lua','data/rs_skill_effects.lua','data/rs_combat_ability_catalog.lua','data/ids/rs_buff_ids.lua','data/ids/rs_plates_ids.lua','services/rs_status_classification_v3.lua','data/rs_status_tracking_catalog.lua','services/rs_buff_metadata_v3.lua','ui/framework/rs_ui_floating_surface.lua',
 'features/combat/buff_display/rs_buff_display_store.lua','features/combat/buff_display/rs_buff_display_projection.lua','features/combat/buff_display/rs_buff_display_feature.lua','features/combat/buff_display/rs_buff_display_management.lua','features/combat/buff_display/rs_buff_display_transfer_v2.lua'})do dofile(f)end
 local F=S.Features.BuffDisplay;return S,F,S.Persistence,io
end

Test('both migrated scope twins missing same v4 chunk recover from exact imported catalog candidate',function()
 local _,F,P,io=Boot();assert(F:EnsureStoreLoaded())
 local st=P:GetStore('v3.buff_display');st.transportVersion=4
 assert(F:ImportBuiltinPack('recommended',false))
 local key=st.resolvedKey;local raw=io.disk[key]
 assert(raw.__rsmeta.schema==8 and raw.__rsmeta.transportVersion==4)
 assert(raw.payload.settings.library.importedPacks.recommended==1)
 local pa=raw.payload.settings.tracked.player.auto
 local ta=raw.payload.settings.tracked.target.auto
 assert(pa and ta and pa.p25 and ta.p25 and pa.count==397 and ta.count==397)
 pa.p25=nil;ta.p25=nil
 local _,fresh,freshP,fio=Boot({disk=io.disk})
 local ok,why=fresh:EnsureStoreLoaded();assert(ok,why)
 assert(#fresh.State.settings.tracked.player.auto==397 and #fresh.State.settings.tracked.target.auto==397)
 local freshStore=freshP:GetStore('v3.buff_display')
 assert(freshStore.lastPhysicalTransportRepairOk==true)
 assert(tostring(freshStore.lastPhysicalTransportRepairProbe or ''):find('catalog',1,true),'catalog recovery probe missing')
 assert(freshP:Flush('v3.buff_display'))
 assert(fio.disk[freshStore.resolvedKey].__rsmeta.transportVersion==5)
end)


Test('legacy all watermark with 397-vector recovers from exact recommended superset candidate',function()
 local _,F,P,io=Boot();assert(F:EnsureStoreLoaded())
 local st=P:GetStore('v3.buff_display');st.transportVersion=4
 assert(F:ImportBuiltinPack('recommended',false))
 assert(F:MutateStore(function()
  F.State.settings.library.importedPacks={all=1}
  F.State.settings.library.catalogVersion=1
  return true
 end,0,'fixture-old-all-watermark',true))
 local raw=io.disk[st.resolvedKey]
 assert(raw.payload.settings.library.importedPacks.all==1 and raw.payload.settings.library.importedPacks.recommended==nil)
 local pa=raw.payload.settings.tracked.player.auto
 local ta=raw.payload.settings.tracked.target.auto
 assert(pa and ta and pa.count==397 and ta.count==397 and pa.p25 and ta.p25)
 pa.p25=nil;ta.p25=nil
 local _,fresh,freshP,fio=Boot({disk=io.disk})
 local ok,why=fresh:EnsureStoreLoaded();assert(ok,why)
 assert(#fresh.State.settings.tracked.player.auto==397 and #fresh.State.settings.tracked.target.auto==397)
 local fs=freshP:GetStore('v3.buff_display')
 assert(fs.lastPhysicalTransportRepairOk==true)
 local probe=tostring(fs.lastPhysicalTransportRepairProbe or '')
 assert(probe:find('pack:recommended',1,true),'recommended candidate probe missing: '..probe)
 assert(freshP:Flush('v3.buff_display'))
 assert(fio.disk[fs.resolvedKey].__rsmeta.transportVersion==5)
end)


Test('legacy all fallback refuses same-count candidate when surviving chunks differ',function()
 local _,F,P,io=Boot();assert(F:EnsureStoreLoaded())
 local st=P:GetStore('v3.buff_display');st.transportVersion=4
 assert(F:ImportBuiltinPack('recommended',false))
 assert(F:MutateStore(function()
  F.State.settings.library.importedPacks={all=1}
  F.State.settings.library.catalogVersion=1
  return true
 end,0,'fixture-old-all-watermark-mismatch',true))
 local raw=io.disk[st.resolvedKey]
 local pa=raw.payload.settings.tracked.player.auto
 local ta=raw.payload.settings.tracked.target.auto
 pa.p1=pa.p1:gsub('^%d+','99999');pa.p25=nil;ta.p25=nil
 local _,fresh,freshP,fio=Boot({disk=io.disk})
 local ok=fresh:EnsureStoreLoaded();assert(ok~=true)
 local fs=freshP:GetStore('v3.buff_display')
 assert(fs.writeFenced==true and fio.writes==0 and fio.clears==0)
end)

Test('catalog candidate never repairs when surviving chunks do not match catalog',function()
 local _,F,P,io=Boot();assert(F:EnsureStoreLoaded())
 local st=P:GetStore('v3.buff_display');st.transportVersion=4
 assert(F:ImportBuiltinPack('recommended',false))
 local raw=io.disk[st.resolvedKey]
 raw.payload.settings.tracked.player.auto.p1=raw.payload.settings.tracked.player.auto.p1:gsub('^%d+','99999')
 raw.payload.settings.tracked.player.auto.p25=nil
 raw.payload.settings.tracked.target.auto.p25=nil
 local _,fresh,freshP,fio=Boot({disk=io.disk})
 local ok=fresh:EnsureStoreLoaded();assert(ok~=true)
 local fs=freshP:GetStore('v3.buff_display')
 assert(fs.writeFenced==true and fio.writes==0 and fio.clears==0)
end)


Test('real RU 230 shape: imported watermarks union 397 but tracked vector 393 recovers exact all pack',function()
 local _,F,P,io=Boot();assert(F:EnsureStoreLoaded())
 local st=P:GetStore('v3.buff_display');st.transportVersion=4
 -- Reproduce the real persistence semantics instead of treating importedPacks as the current selection:
 -- the user once imported all + hidden (watermarks remain), then explicitly removed hidden ids.
 assert(F:ImportBuiltinPack('all',false))
 assert(F:ImportBuiltinPack('hidden',false))
 local hidden=ReplicatedSuite.Data.StatusTrackingCatalogV3.Packs.hidden
 assert(hidden and #hidden.entries==4)
 assert(F:MutateStore(function()
  local remove={};for _,entry in ipairs(hidden.entries) do remove[entry.id]=true end
  for _,scope in ipairs({'player','target'}) do
   local out={};for _,id in ipairs(F.State.settings.tracked[scope].auto) do if not remove[id] then out[#out+1]=id end end
   F.State.settings.tracked[scope].auto=out
  end
  return true
 end,0,'fixture-user-untracked-hidden',true))
 local raw=io.disk[st.resolvedKey]
 assert(raw.payload.settings.library.importedPacks.all==1)
 assert(raw.payload.settings.library.importedPacks.hidden==1)
 local pa=raw.payload.settings.tracked.player.auto
 local ta=raw.payload.settings.tracked.target.auto
 assert(pa and ta and pa.count==393 and ta.count==393 and pa.p25 and ta.p25)
 pa.p25=nil;ta.p25=nil
 local _,fresh,freshP,fio=Boot({disk=io.disk})
 local ok,why=fresh:EnsureStoreLoaded();assert(ok,why)
 assert(#fresh.State.settings.tracked.player.auto==393 and #fresh.State.settings.tracked.target.auto==393)
 local fs=freshP:GetStore('v3.buff_display')
 assert(fs.lastPhysicalTransportRepairOk==true)
 local probe=tostring(fs.lastPhysicalTransportRepairProbe or '')
 assert(probe:find('pack:all',1,true),'must identify exact all-pack recovery: '..probe)
 assert(freshP:Flush('v3.buff_display'))
 assert(fio.disk[fs.resolvedKey].__rsmeta.transportVersion==5)
end)


Test('static all candidate cannot overwrite a user change hidden entirely inside the missing chunk',function()
 local _,F,P,io=Boot();assert(F:EnsureStoreLoaded())
 local st=P:GetStore('v3.buff_display');st.transportVersion=4
 assert(F:ImportBuiltinPack('all',false))
 assert(F:MutateStore(function()
  for _,scope in ipairs({'player','target'}) do
   local list=F.State.settings.tracked[scope].auto
   assert(#list==393)
   list[#list]=16000000
  end
  return true
 end,0,'fixture-user-custom-last-chunk',true))
 local raw=io.disk[st.resolvedKey]
 local pa=raw.payload.settings.tracked.player.auto
 local ta=raw.payload.settings.tracked.target.auto
 assert(pa.count==393 and ta.count==393 and pa.p25 and ta.p25)
 -- All surviving p1..p24 still match the static all pack; only the lost p25 contained the user's change.
 pa.p25=nil;ta.p25=nil
 local _,fresh,freshP,fio=Boot({disk=io.disk})
 local ok=fresh:EnsureStoreLoaded();assert(ok~=true)
 local fs=freshP:GetStore('v3.buff_display')
 assert(fs.writeFenced==true and fio.writes==0 and fio.clears==0)
 assert(tostring(fs.lastError or ''):find('fingerprint',1,true),'Core fingerprint must reject reconstructed static content: '..tostring(fs.lastError))
end)


Test('no-candidate failure records bounded vector and first chunk mismatch evidence',function()
 local _,F,P,io=Boot();assert(F:EnsureStoreLoaded())
 local st=P:GetStore('v3.buff_display');st.transportVersion=4
 assert(F:ImportBuiltinPack('all',false))
 local raw=io.disk[st.resolvedKey]
 local pa=raw.payload.settings.tracked.player.auto
 local ta=raw.payload.settings.tracked.target.auto
 assert(pa.count==393 and ta.count==393 and pa.p25 and ta.p25)
 -- Simulate the real class of failure: both copies lose one chunk while at least one surviving
 -- chunk differs from the current static all pack. Recovery must stay fenced, but diagnostics
 -- must tell us the vector topology and the first concrete mismatch instead of only no_candidate.
 pa.p1=pa.p1:gsub('^%d+','99999');ta.p1=pa.p1
 pa.p25=nil;ta.p25=nil
 local _,fresh,freshP,fio=Boot({disk=io.disk})
 local ok=fresh:EnsureStoreLoaded();assert(ok~=true)
 local fs=freshP:GetStore('v3.buff_display')
 local e=tostring(fs.lastPhysicalTransportRepairError or '')
 assert(fs.writeFenced==true and fio.writes==0 and fio.clears==0)
 assert(e:find('bucket=player.auto',1,true),'bucket topology missing: '..e)
 assert(e:find('count=393',1,true),'vector count missing: '..e)
 assert(e:find('missing=p25',1,true),'missing chunk index missing: '..e)
 assert(e:find('sameCount=pack:all',1,true),'same-count candidate missing: '..e)
 assert(e:find('mis=p1',1,true),'first mismatching chunk missing: '..e)
 assert(e:find('disk=',1,true) and e:find('want=',1,true),'bounded chunk evidence missing: '..e)
end)


Test('deep probe audits missing and malformed chunks on both scoped twins',function()
 local _,F,P,io=Boot();assert(F:EnsureStoreLoaded())
 local st=P:GetStore('v3.buff_display');st.transportVersion=4
 assert(F:ImportBuiltinPack('all',false))
 local raw=io.disk[st.resolvedKey]
 local pa=raw.payload.settings.tracked.player.auto
 local ta=raw.payload.settings.tracked.target.auto
 assert(pa.count==393 and ta.count==393)
 local function FirstTokens(text,n)
  local out={};for tok in tostring(text):gmatch('[^,]+') do out[#out+1]=tok;if #out>=n then break end end
  return table.concat(out,',')
 end
 pa.p1=nil;pa.p2=nil;pa.p3=nil;pa.p4=nil;pa.p19=nil
 pa.p5=FirstTokens(pa.p5,10)
 ta.p2=nil;ta.p7=nil;ta.p19=nil
 ta.p5=FirstTokens(ta.p5,12)
 local _,fresh,freshP,fio=Boot({disk=io.disk})
 local ok=fresh:EnsureStoreLoaded();assert(ok~=true)
 local fs=freshP:GetStore('v3.buff_display')
 local e=tostring(fs.lastPhysicalTransportRepairError or '')
 assert(fs.writeFenced==true and fio.writes==0 and fio.clears==0)
 assert(e:find('Pauto=',1,true),'player vector audit missing: '..e)
 assert(e:find('m=1,2,3,4,19',1,true),'player missing map missing: '..e)
 assert(e:find('b=5:count10/16',1,true),'player malformed chunk audit missing: '..e)
 assert(e:find('Tauto=',1,true),'target vector audit missing: '..e)
 assert(e:find('m=2,7,19',1,true),'target missing map missing: '..e)
 assert(e:find('b=5:count12/16',1,true),'target malformed chunk audit missing: '..e)
 assert(e:find('twinDiff=',1,true) and e:find('p5',1,true),'twin overlap diff map missing: '..e)
 assert(e:find('p5P=',1,true) and e:find('p5T=',1,true),'twin p5 raw evidence missing: '..e)
end)


Test('real RU 233 shape: intact target twin repairs player missing and truncated chunks before fingerprint verification',function()
 local _,F,P,io=Boot();assert(F:EnsureStoreLoaded())
 local st=P:GetStore('v3.buff_display');st.transportVersion=4
 assert(F:ImportBuiltinPack('all',false))
 -- Historical/custom selection: keep 393 ids but make p5 differ from today's static all catalog.
 assert(F:MutateStore(function()
  local base={};for i,id in ipairs(F.State.settings.tracked.player.auto) do base[i]=id end
  assert(#base==393);base[65]=16000002
  local clone={};for i,id in ipairs(base) do clone[i]=id end
  F.State.settings.tracked.player.auto=base
  F.State.settings.tracked.target.auto=clone
  return true
 end,0,'fixture-ru233-historical-p5',true))
 local raw=io.disk[st.resolvedKey]
 local pa=raw.payload.settings.tracked.player.auto
 local ta=raw.payload.settings.tracked.target.auto
 assert(pa.count==393 and ta.count==393 and pa.p5==ta.p5)
 local function FirstTokens(text,n)
  local out={};for tok in tostring(text):gmatch('[^,]+') do out[#out+1]=tok;if #out>=n then break end end
  return table.concat(out,',')
 end
 pa.p1=nil;pa.p2=nil;pa.p3=nil;pa.p4=nil;pa.p19=nil
 pa.p5=FirstTokens(pa.p5,10)
 -- Exact RU evidence shape: target is structurally complete; player has 5 missing chunks + truncated p5.
 local _,fresh,freshP,fio=Boot({disk=io.disk})
 local ok,why=fresh:EnsureStoreLoaded();assert(ok,why)
 assert(#fresh.State.settings.tracked.player.auto==393 and #fresh.State.settings.tracked.target.auto==393)
 assert(fresh.State.settings.tracked.player.auto[65]==fresh.State.settings.tracked.target.auto[65])
 local fs=freshP:GetStore('v3.buff_display')
 assert(fs.lastPhysicalTransportRepairOk==true)
 local probe=tostring(fs.lastPhysicalTransportRepairProbe or '')
 assert(probe:find('twin:player.auto',1,true),'must use intact target twin, not catalog: '..probe)
 assert(freshP:Flush('v3.buff_display'))
 assert(fio.disk[fs.resolvedKey].__rsmeta.transportVersion==5)
end)

Test('intact twin candidate cannot overwrite legitimate scoped divergence hidden inside damaged player chunks',function()
 local _,F,P,io=Boot();assert(F:EnsureStoreLoaded())
 local st=P:GetStore('v3.buff_display');st.transportVersion=4
 assert(F:ImportBuiltinPack('all',false))
 assert(F:MutateStore(function()
  local base={};for i,id in ipairs(F.State.settings.tracked.player.auto) do base[i]=id end
  assert(#base==393)
  local p={};local t={};for i,id in ipairs(base) do p[i]=id;t[i]=id end
  -- Schema8 allows scope divergence. Put the user's player-only edit inside p1, which will later vanish physically.
  p[1]=22
  F.State.settings.tracked.player.auto=p
  F.State.settings.tracked.target.auto=t
  return true
 end,0,'fixture-scoped-divergence-in-lost-player-chunk',true))
 local raw=io.disk[st.resolvedKey]
 local pa=raw.payload.settings.tracked.player.auto
 local ta=raw.payload.settings.tracked.target.auto
 assert(pa.count==393 and ta.count==393 and pa.p1~=ta.p1)
 pa.p1=nil;pa.p2=nil;pa.p3=nil;pa.p4=nil;pa.p19=nil
 local function FirstTokens(text,n)
  local out={};for tok in tostring(text):gmatch('[^,]+') do out[#out+1]=tok;if #out>=n then break end end
  return table.concat(out,',')
 end
 pa.p5=FirstTokens(pa.p5,10)
 local _,fresh,freshP,fio=Boot({disk=io.disk})
 local ok=fresh:EnsureStoreLoaded();assert(ok~=true)
 local fs=freshP:GetStore('v3.buff_display')
 assert(fs.writeFenced==true and fio.writes==0 and fio.clears==0)
 assert(fs.lastPhysicalTransportRepairOk==true,'twin physical candidate should decode before logical fingerprint rejection'); assert(tostring(fs.lastError or ''):find('fingerprint',1,true) or tostring(fs.lastIntegrityError or ''):find('fingerprint',1,true),'original fingerprint must reject wrong twin reconstruction: '..tostring(fs.lastError)..' / '..tostring(fs.lastIntegrityError))
end)


Test('fingerprint mismatch on healthy twin falls back to exact catalog reconstruction',function()
 local _,F,P,io=Boot();assert(F:EnsureStoreLoaded())
 local st=P:GetStore('v3.buff_display');st.transportVersion=4
 assert(F:ImportBuiltinPack('all',false))
 local originalPlayer,originalTarget
 assert(F:MutateStore(function()
  local base={};for i,id in ipairs(F.State.settings.tracked.player.auto) do base[i]=id end
  assert(#base==393)
  local index=nil
  for i=1,15 do if base[i]+1<base[i+1] then index=i;break end end
  assert(index,'fixture needs one stable gap inside p1')
  local target={};for i,id in ipairs(base) do target[i]=id end
  target[index]=base[index]+1
  F.State.settings.tracked.player.auto=base
  F.State.settings.tracked.target.auto=target
  originalPlayer=Copy(base);originalTarget=Copy(target)
  return true
 end,0,'fixture-twin-wrong-catalog-exact',true))
 local raw=io.disk[st.resolvedKey]
 local pa=raw.payload.settings.tracked.player.auto
 local ta=raw.payload.settings.tracked.target.auto
 assert(pa.count==393 and ta.count==393 and pa.p1~=ta.p1)
 for i=2,25 do assert(pa['p'..i]==ta['p'..i],'fixture divergence escaped missing chunk p1') end
 pa.p1=nil;pa.p2=nil;pa.p3=nil;pa.p4=nil;pa.p19=nil
 local function FirstTokens(text,n)
  local out={};for tok in tostring(text):gmatch('[^,]+') do out[#out+1]=tok;if #out>=n then break end end
  return table.concat(out,',')
 end
 pa.p5=FirstTokens(pa.p5,10)
 local _,fresh,freshP,fio=Boot({disk=io.disk})
 local ok,why=fresh:EnsureStoreLoaded();assert(ok,why)
 assert(#fresh.State.settings.tracked.player.auto==393 and #fresh.State.settings.tracked.target.auto==393)
 for i,id in ipairs(originalPlayer) do assert(fresh.State.settings.tracked.player.auto[i]==id,'player catalog reconstruction changed at '..i) end
 for i,id in ipairs(originalTarget) do assert(fresh.State.settings.tracked.target.auto[i]==id,'target healthy scope changed at '..i) end
 local fs=freshP:GetStore('v3.buff_display')
 assert(fs.lastPhysicalTransportRepairOk==true)
 local probe=tostring(fs.lastPhysicalTransportRepairProbe or '')
 assert(probe:find('fallback_exact=catalog:player.auto',1,true),'must fall back from wrong healthy twin to an exact catalog-authenticated candidate: '..probe)
 assert(freshP:Flush('v3.buff_display'))
 assert(fio.disk[fs.resolvedKey].__rsmeta.transportVersion==5)
end)


Test('exact RU schema8 transport4 twin incident can enter only through the known-pair recovery hook',function()
 local _,F,P=Boot();assert(F:EnsureStoreLoaded())
 local st=assert(P:GetStore('v3.buff_display'))
 local decoded=st.default()
 decoded.settings.tracked.player.auto={}
 decoded.settings.tracked.target.auto={}
 for i=1,393 do
  decoded.settings.tracked.player.auto[i]=i
  decoded.settings.tracked.target.auto[i]=i
 end
 local raw={__rsmeta={framework=3,contractVersion=3,integrityVersion=4,reliabilityContract=8,envelopeIntegrityVersion=1,schema=8,transportVersion=4,encodedFingerprint='2FBF9352',store='v3.buff_display',owner='v3.buff_display'}}
 st.lastPhysicalTransportRepairOk=true
 st.lastPhysicalTransportRepairProbe='schema8_v4/repairs=6/twin:player.auto/primaryfp=0EBC870A/fallback=fallback_player_catalog_no_candidate:player.auto|bucket=player.auto/count=393/parts=25/missing=p1,p2,p3,p4,p19/present=20/twin=diff:p5/Pauto=c393/p25/m=1,2,3,4,19/b=5:count10/16/Tauto=c393/p25/m=-/b=-/twinDiff=5/p5P=664,667,745,770,778,794,795,796,828,854/p5T=664,667,745,770,778,794,795,796,828,854,855,856,857,877,883,886'
 local original=P.FingerprintCanonicalValue
 P.FingerprintCanonicalValue=function(self,store,canonical)
  if store==st then return '0EBC870A' end
  return original(self,store,canonical)
 end
 local recovered,reason=st.recoverKnownLegacyCanonical(decoded,'2FBF9352',decoded,raw)
 P.FingerprintCanonicalValue=original
 assert(type(recovered)=='table','exact RU incident did not recover')
 assert(reason=='schema8_transport4_twin_known_pair_2FBF9352_0EBC870A','unexpected recovery reason: '..tostring(reason))
end)

Test('known RU incident gate rejects stamp metadata probe and current fingerprint drift',function()
 local _,F,P=Boot();assert(F:EnsureStoreLoaded())
 local st=assert(P:GetStore('v3.buff_display'))
 local decoded=st.default()
 decoded.settings.tracked.player.auto={}
 decoded.settings.tracked.target.auto={}
 for i=1,393 do decoded.settings.tracked.player.auto[i]=i;decoded.settings.tracked.target.auto[i]=i end
 local goodProbe='schema8_v4/repairs=6/twin:player.auto/primaryfp=0EBC870A/fallback=fallback_player_catalog_no_candidate:player.auto|bucket=player.auto/count=393/parts=25/missing=p1,p2,p3,p4,p19/present=20/twin=diff:p5/Pauto=c393/p25/m=1,2,3,4,19/b=5:count10/16/Tauto=c393/p25/m=-/b=-/twinDiff=5/p5P=664,667,745,770,778,794,795,796,828,854/p5T=664,667,745,770,778,794,795,796,828,854,855,856,857,877,883,886'
 local function Raw()
  return {__rsmeta={framework=3,contractVersion=3,integrityVersion=4,reliabilityContract=8,envelopeIntegrityVersion=1,schema=8,transportVersion=4,encodedFingerprint='2FBF9352',store='v3.buff_display',owner='v3.buff_display'}}
 end
 local original=P.FingerprintCanonicalValue
 local current='0EBC870A'
 P.FingerprintCanonicalValue=function(self,store,canonical) if store==st then return current end return original(self,store,canonical) end
 st.lastPhysicalTransportRepairOk=true;st.lastPhysicalTransportRepairProbe=goodProbe
 assert(st.recoverKnownLegacyCanonical(decoded,'DEADBEEF',decoded,Raw())==nil,'unknown old stamp must fence')
 local badMeta=Raw();badMeta.__rsmeta.reliabilityContract=7
 assert(st.recoverKnownLegacyCanonical(decoded,'2FBF9352',decoded,badMeta)==nil,'wrong reliability generation must fence')
 local badRawFp=Raw();badRawFp.__rsmeta.encodedFingerprint='DEADBEEF'
 assert(st.recoverKnownLegacyCanonical(decoded,'2FBF9352',decoded,badRawFp)==nil,'raw stamp mismatch must fence')
 st.lastPhysicalTransportRepairProbe=goodProbe:gsub('missing=p1,p2,p3,p4,p19','missing=p1,p2,p3,p4,p20',1)
 assert(st.recoverKnownLegacyCanonical(decoded,'2FBF9352',decoded,Raw())==nil,'different physical topology must fence')
 st.lastPhysicalTransportRepairProbe=goodProbe;current='AAAAAAAA'
 assert(st.recoverKnownLegacyCanonical(decoded,'2FBF9352',decoded,Raw())==nil,'different reconstructed canonical must fence')
 P.FingerprintCanonicalValue=original
end)

print('TRANSPORT4 DUAL LOSS RESULT '..passed..' passed / '..failed..' failed ('.._VERSION..')')
if failed>0 then error('transport4 dual loss failures: '..failed) end

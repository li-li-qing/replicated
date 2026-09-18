-- 维护（2026-09-12）：物理版本按Store注册策略验收；仍比较完整配置，不放宽业务指纹/重载一致性。
-- 维护：从本轮udf实证提取的数值机制，合成无玩家身份的数据验证；不分发用户udf。
-- 两条桥只改校验用的历史token候选，实际Domain保留Native已读数值，不能捏造丢失的小数。
local B=dofile('tools/rs_udf_numeric_test_host.lua')
local passed,failed=0,0
local function Test(name,fn)local ok,e=pcall(fn);if ok then passed=passed+1;print('PASS UDF numeric '..name)else failed=failed+1;print('FAIL UDF numeric '..name..': '..tostring(e))end end
local function Legacy(kind,rows)
 local S,P,io=B.Boot();local id=kind=='buff'and 'v3.buff_display'or 'v3.death_review';local st=P:GetStore(id)
 local schema=kind=='buff'and 5 or 2
 local v=kind=='buff'and B.Copy(dofile('tools/rs_status_schema5_fixtures.lua')[2].canonical)or st.default()
 if kind=='buff'then
  v.widgetWindow=st.migrate(v).widgetWindow;v.widgetWindow.userMoved=true;v.widgetWindow.coordinateSpace='logical-free-v2'
  v.widgetWindow.normalizedCenterX=0.8299175000001;v.widgetWindow.normalizedCenterY=0.198611
  v.widgetWindow.x=10;v.widgetWindow.y=30
  v.widgetWindow=st.migrate(v).widgetWindow -- fixture必须先满足真实窗口normalizer，再按schema5盖章
 else
  v.settings.maxHistory=30;v.history={serial=rows or 5,entries={}}
  for i=1,(rows or 5)do v.history.entries[i]={serial=i,storageId=i,time=4473533+i*100+(i%2==0 and 0.01 or 0),clock='00:00:00',lethalSource='synthetic'}end
  v=st.migrate(v)
 end
 local c=kind=='buff'and B.Copy(v)or P:CanonicalIntegrityValue(st,v)
 local fp=P:FingerprintCanonicalValue(st,c)
 local raw=st.encode and st.encode(v)or {payload=B.Copy(v)}
 raw.__rsmeta={framework=3,store=id,owner=st.owner,contractVersion=st.contractVersion,lifetime=st.lifetime,scope=st.scope,
 schema=schema,transportVersion=2,reliabilityContract=8,integrityVersion=4,envelopeIntegrityVersion=1,encodedFingerprint=fp}
 raw.__rsmeta.envelopeFingerprint=P:FingerprintEnvelopeIntegrity(raw)
 local key=P:ResolveStoreKey(st)
 io.disk[key]=B.NativeLoss(assert(P:EncodePhysicalEnvelope(raw)))
 local disk=P:DecodePhysicalEnvelope(B.Copy(io.disk[key]));local read=st.decode and st.decode(disk)or disk.payload
 return S,P,io,st,key,v,read,fp
end
for _,kind in ipairs({'buff','death'})do
 Test(kind..' native float-first loss is recovered without inventing domain numbers',function()
  local S,P,io,st,key,v,read,fp=Legacy(kind);local original=B.Copy(io.disk[key])
  local readCanonical=kind=='buff'and read or P:CanonicalIntegrityValue(st,read)
  assert(P:FingerprintCanonicalValue(st,readCanonical)~=fp,'fixture did not introduce a historical mismatch')
  local ok,_,err=P:LoadStore(st.id);assert(ok,err)
  assert(st.lastIntegrityFingerprint==fp and not st.writeFenced)
  assert(B.Eq(st.get(),st.migrate(read)),'actual decoded settings/history were replaced by candidate values')
  assert(io.writes==0 and io.clears==0 and B.Eq(original,io.disk[key]))
 end)
 Test(kind..' recovered values save in transport3 and survive fresh addon registration',function()
  local S,P,io,st,key=Legacy(kind);assert(P:LoadStore(st.id));local expected=B.Copy(st.get())
  assert(P:SaveStore(st.id,{force=true,durable=true}));assert(io.disk[key].__rsmeta.transportVersion==(st.transportVersion or P.TransportContractVersion))
  local _,nextP,calls=B.Boot(io.disk,true);assert(nextP:LoadStore(st.id))
  assert(B.Eq(nextP:GetStore(st.id).get(),expected) and calls.writes==0 and calls.clears==0)
 end)
 Test(kind..' unrelated changed data cannot borrow the projection bridge',function()
  local S,P,io,st,key=Legacy(kind)
  if kind=='buff'then io.disk[key].payload.settings.playerRows=17
  else io.disk[key].payload.history.entries[1].totalDamage=999 end
  local applied=0;st.apply=function()applied=applied+1 end
  assert(not P:LoadStore(st.id) and st.writeFenced and applied==0 and io.writes==0)
 end)
 Test(kind..' invalid metadata does not enter projection recovery',function()
  local S,P,io,st,key=Legacy(kind);io.disk[key].__rsmeta.owner='other_store'
  assert(not P:LoadStore(st.id) and st.writeFenced and io.writes==0)
 end)
end
Test('timestamp search is bounded at eight eligible entries',function()
 local _,P,io,st=Legacy('death',9);assert(not P:LoadStore(st.id));assert(st.writeFenced and io.writes==0)
 assert(st.lastHistoricalRecoveryProbe:find('timestamp=budget',1,true))
end)
Test('sparse index and unknown raw fields are not normalized away to repair timestamps',function()
 for _,change in ipairs({'sparse','unknown'})do
  local _,P,io,st,key=Legacy('death')
  if change=='sparse'then io.disk[key].payload.history.entries[1]=nil
  else io.disk[key].payload.extra_unknown='must preserve' end
  assert(not P:LoadStore(st.id) and st.writeFenced and io.writes==0)
 end
end)
Test('window bridge still refuses two-axis losses',function()
 local _,P,io,st,key,v=Legacy('buff');v.widgetWindow.normalizedCenterY=0.8299175000001
 local raw={payload=v,__rsmeta=P:DecodePhysicalEnvelope(io.disk[key]).__rsmeta}
 raw.__rsmeta.encodedFingerprint=P:FingerprintCanonicalValue(st,v);raw.__rsmeta.envelopeFingerprint=P:FingerprintEnvelopeIntegrity(raw)
 io.disk[key]=B.NativeLoss(P:EncodePhysicalEnvelope(raw));assert(not P:LoadStore(st.id) and st.writeFenced)
end)
Test('timestamp legacy exponent rendering is explicit in the test environment only',function()
 local old=string.format
 string.format=function(f,...)local s=old(f,...);if f=='%.6g'or f=='%.17g'then return s:gsub('e([%+%-])(%d%d)$','e%10%2')end;return s end
 local ok,err=pcall(function()local _,P,io,st,key,v,read,fp=Legacy('death');assert(P:LoadStore(st.id));assert(st.lastIntegrityFingerprint==fp and B.Eq(st.get(),st.migrate(read)))end)
 string.format=old;assert(ok,err)
end)
print('UDF NUMERIC RESULT '..passed..' passed / '..failed..' failed ('.._VERSION..')')
assert(failed==0,'UDF numeric regressions failed')

-- 维护：真实 Core/Store/RSUI Diff；Native 仅模拟键入和第189项起缺失，不宣称RU内部硬上限。
local passed,failed=0,0
local function Test(name,fn)
 local ok,err=xpcall(fn,function(e)return tostring(e)..'\n'..debug.traceback()end)
 if ok then passed=passed+1;print('PASS batch-authority '..name)else failed=failed+1;print('FAIL batch-authority '..name..': '..err)end
end
local function Copy(v)if type(v)~='table'then return v end;local o={};for k,x in pairs(v)do o[k]=Copy(x)end;return o end
local function Equal(a,b)if type(a)~=type(b)then return false end;if type(a)~='table'then return a==b end;for k,v in pairs(a)do if not Equal(v,b[k])then return false end end;for k in pairs(b)do if a[k]==nil then return false end end;return true end
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
Test('397 recommended IDs survive native loss starting at array index 189',function()
 local S,F,P,io=Boot();assert(F:EnsureStoreLoaded());local before=io.writes
 local ok,why=F:ImportBuiltinPack('recommended',false);assert(ok,why)
 assert(#F.State.settings.tracked.auto==397 and io.writes==before+1)
 local st=P:GetStore('v3.buff_display');local expected=Copy(F.State);local saved=io.disk[st.resolvedKey]
 assert(saved.__rsmeta.transportVersion==4,'status store must explicitly select bounded-vector transport')
 local _,fresh,_,fio=Boot({disk=io.disk});assert(fresh:EnsureStoreLoaded());assert(Equal(expected,fresh.State));assert(fio.writes==0 and fio.clears==0)
end)
Test('repeat import is idempotent and remove survives fresh reload',function()
 local _,F,P,io=Boot();assert(F:EnsureStoreLoaded());assert(F:ImportBuiltinPack('recommended',false));assert(F:ImportBuiltinPack('recommended',false))
 assert(#F.State.settings.tracked.auto==397);local id=F.State.settings.tracked.auto[189];assert(F:SetTrackedId(id,'auto',false));assert(P:Flush('v3.buff_display'))
 local _,nextF=Boot({disk=io.disk});assert(nextF:EnsureStoreLoaded());assert(not nextF:IsTrackedId(id)and #nextF.State.settings.tracked.auto==396)
end)
Test('legacy transport3 remains readable with full tracked list and no forced save',function()
 local _,F,P,io=Boot({loss=false});assert(F:EnsureStoreLoaded());local st=P:GetStore('v3.buff_display');st.transportVersion=3
 assert(F:ImportBuiltinPack('recommended',false));assert(io.disk[st.resolvedKey].__rsmeta.transportVersion==3)
 local _,fresh,_,fio=Boot({disk=io.disk});assert(fresh:EnsureStoreLoaded());assert(#fresh.State.settings.tracked.auto==397 and fio.writes==0)
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
 io.damage=function(raw)local a=raw.payload.settings.tracked.auto;a.p2=nil end
 local ok,why=F:ImportBuiltinPack('recommended',false);assert(not ok and tostring(why):find('transport',1,true),why)
 assert(Equal(before,F.State) and io.clears==0 and F.lastLibraryImport.ok==false)
end)
Test('same-length corrupt ID is rejected by original whole-config fingerprint',function()
 local _,F,P,io=Boot();assert(F:EnsureStoreLoaded());local before=Copy(F.State)
 io.damage=function(raw)local a=raw.payload.settings.tracked.auto;if a.p1 then a.p1=a.p1:gsub('^%d+','99999')end end
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
Test('all three tracking buckets round-trip without 188-entry truncation',function()
 local _,F,P,io=Boot();assert(F:EnsureStoreLoaded())
 assert(F:MutateStore(function()for offset,bucket in ipairs({'buff','debuff','auto'})do for i=1,512 do F.State.settings.tracked[bucket][i]=10000*offset+i end end;return true end,0,'three-bucket-test',true))
 local state=Copy(F.State);local _,fresh=Boot({disk=io.disk});assert(fresh:EnsureStoreLoaded());assert(Equal(state,fresh.State))
end)
Test('old failed import can save verified rollback via existing HUD save before reload',function()
 local _,F,P,io=Boot();assert(F:EnsureStoreLoaded());local st=P:GetStore('v3.buff_display');st.transportVersion=3
 local before=Copy(F.State);local ok,err=F:ImportBuiltinPack('recommended',false)
 assert(not ok and err:find('auto.189',1,true),err);assert(Equal(before,F.State))
 local bad=Copy(io.disk)
 -- 旧会话可用Domain仍是经过回滚的原配置；HUD入口force+durable保存不依赖是否拖动。
 assert(F:PersistHudCalibrationSnapshot(F:GetHudCalibrationSnapshot(),'before_reload'))
 assert(Equal(before,F.State));local _,fresh,_,fio=Boot({disk=io.disk});assert(fresh:EnsureStoreLoaded());assert(Equal(before,fresh.State)and fio.writes==0)
 local _,broken=Boot({disk=bad});assert(not broken:EnsureStoreLoaded())
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

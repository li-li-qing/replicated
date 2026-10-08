-- 真实 Bus/Analytics/指标/模块报告；原生启停和磁盘为替身，不代表 RU 已确认击杀 ABI。
local passed,failed=0,0
local function Test(name,fn)
    local ok,err=xpcall(fn,debug.traceback)
    if ok then passed=passed+1;print('PASS kill diagnostics '..name)
    else failed=failed+1;print('FAIL kill diagnostics '..name..': '..tostring(err)) end
end
local function Copy(v) if type(v)~='table' then return v end local r={} for k,x in pairs(v) do r[k]=Copy(x) end return r end
local function Boot()
    local h={now=1000,writes=0,tasks={},starts=0}
    ReplicatedSuite={Generation=31,SafeTraceback=debug.traceback,NowMs=function()return h.now end,Services={},Features={},Data={},Utils={DeepCopy=Copy}}
    local S=ReplicatedSuite; h.S=S
    S.Utils.GetServerTime=function()return {year=2026,month=10,day=6,hour=3,minute=49}end
    S.Events={Publish=function()end,SubscribeInternal=function()return true end,SubscribeOptional=function()error('extra native subscription')end,UnsubscribeInternal=function()end}
    S.Scheduler={AddOneShot=function(_,id,ms,fn)h.tasks[id]={due=h.now+ms,fn=fn};return true end,RemoveTask=function(_,id)h.tasks[id]=nil;return true end,SetTaskModule=function()end}
    function h:Advance(ms)
        self.now=self.now+ms;local pending=self.tasks;self.tasks={}
        for id,row in pairs(pending) do if row.due<=self.now then row.fn() else self.tasks[id]=row end end
    end
    S.Services.UnitIdentityV3={player={id='self-id',name='Self'},IsPlayerName=function(_,name)return name=='Self'end,
        IsPlayerIdentityReady=function()return true end,RefreshPlayerIdentity=function(self)return self.player end,
        ResolveCombatEndpoint=function(_,id,source,target)if id=='self-id' and source=='Self' then return {id=id,role='source',confidence='exact'}end end,
        GetById=function()return {kind='PLAYER',kindReliable=true}end}
    S.Services.CombatRelationV3={GetUnit=function(_,name)return {kind=name=='Npc' and 'NPC' or 'PLAYER'}end}
    S.FeatureRuntime={implementations={},state={}}
    function S.FeatureRuntime:RegisterImplementation(id,f)self.implementations[id]=f;self.state[id]={initialized=true,enabled=true};return true end
    function S.FeatureRuntime:GetSnapshot(id)local f=self.implementations[id];return {enabled=f and f.enabled==true}end
    S.Persistence={Scope={Account='account',Character='character'},Lifetime={Permanent='permanent'},V3KeyPrefix='rs.v3.',stores={},loaded={}}
    local P=S.Persistence
    function P:GetStore(id)return self.stores[id]end
    function P:RegisterV3Store(spec)self.stores[spec.id]=spec;return spec end
    function P:IsStoreLoaded(id)return self.loaded[id]==true end
    function P:LoadStore(id)local s=self.stores[id];s.apply(s.default());self.loaded[id]=true;return 'empty'end
    function P:MarkDirty()h.writes=h.writes+1;return true end
    function P:MutateStore(id,fn)local ok,err=fn();if ok==false then return false,err end return self:MarkDirty(id)end
    function P:Describe()local rows={} for id,s in pairs(self.stores)do rows[#rows+1]={id=id,owner=s.owner,loadStatus=self.loaded[id] and 'loaded' or 'registered'}end return {rows=rows}end
    dofile('features/rs_feature_registry.lua');dofile('core/rs_diagnostic_detail.lua');dofile('core/rs_module_diagnostics.lua');dofile('core/rs_demand.lua')
    dofile('services/rs_combat_event_bus_v3.lua')
    h.bus=S.Services.CombatEventBusV3
    h.bus._Start=function(self)h.starts=h.starts+1;self.running=true;return true end
    h.bus._Stop=function(self)self.running=false;return true end
    h.bus._StartGlobalBridge=function()error('self diagnostics opened global bridge')end
    dofile('services/rs_combat_analytics_v3.lua');dofile('features/combat/analytics/rs_combat_metric_common.lua')
    dofile('features/combat/analytics/rs_combat_analytics_metrics.lua');dofile('features/combat/analytics/rs_combat_analytics_store.lua')
    dofile('features/combat/analytics/rs_combat_personal_history.lua');dofile('features/combat/analytics/rs_combat_analytics_feature.lua')
    h.F=S.Features.CombatAnalytics;h.A=S.Services.CombatAnalyticsV3
    assert(h.F:Initialize());assert(h.F:Enable('test'))
    function h:Damage(target)self.bus:_OnCombatRaw('private','self-id','SPELL_DAMAGE','Self',target,11,'Hit',0,100,true)end
    function h:Death(target)self.bus:_OnCombatRaw('private','self-id','UNIT_DEAD','Self',target,11,'Finish',0,0,true)end
    return h
end
local victim='Зачемтыхрюкнул'
local function ExportReport(h)
    local summary,err,text=h.S.ModuleDiagnosticsHub:BuildReport('combat_stats',{detailed=true})
    assert(summary,err);return assert(text,'detailed TXT unavailable')
end
Test('merged module TXT includes missing-source decision and both stores',function()
    local h=Boot();h:Damage(victim);h.bus:_OnDeathNotice(victim,'notice-two',true,17,nil);h:Advance(1600)
    assert((h.F:GetPersonalHistoryProjection().totals.kills or 0)==0,'death-only notice fabricated a kill')
    local text=ExportReport(h)
    assert(text:find(victim,1,true),'merged report omitted victim evidence')
    assert(text:find('missing_killer_source',1,true),'missing source skip reason omitted')
    assert(text:find('notice-two',1,true),'raw death notice payload omitted')
    assert(text:find(h.F.StoreId,1,true) and text:find(h.F.PersonalHistory.StoreId,1,true),'merged report omitted analytics/history stores')
end)
Test('direct kill remains counted and its evidence is detached',function()
    local h=Boot();h:Damage(victim);h:Death(victim)
    assert(h.F:GetPersonalHistoryProjection().totals.kills==1)
    local d=assert(h.F:DescribeDiagnosticDetail())
    assert(d.kills.counters.kill_credited==1,'direct credit evidence missing')
    d.kills.events[1].victim='mutated'
    assert(h.F:DescribeDiagnosticDetail().kills.events[1].victim==victim,'diagnostic exposes live metric rows')
end)
Test('retired NPC kills do not affect player counters and history',function()
    local h=Boot();h:Damage('Npc');h:Death('Npc');h:Damage(victim);h:Death(victim)
    local t=h.F:GetPersonalHistoryProjection().totals
    assert(t.kills==1 and t.npcKills==nil and t.deaths==0,'retired NPC kills affected player counters')
    local p=h.A:GetMetricProjection('kills',{valueKey='npcKills',includeZero=true})
    local self
    for _,r in ipairs(p.rows)do if r.name=='Self' then self=r end end
    assert(p.valueKey=='kills' and self and self.kills==1 and self.npcKills==nil,'stale NPC ranking request has no player fallback')
    assert(h.F:DescribeDiagnosticDetail().kills.counters.npc_kill_credited==nil)
end)
Test('native attribution after a settled death notice upgrades once',function()
    local h=Boot();h:Damage(victim);h.bus:_OnDeathNotice(victim);h:Advance(1800)
    assert(h.F:GetPersonalHistoryProjection().totals.kills==0)
    h.bus:_OnKillNotice('INSTANT_GAME_KILL',{killer='Self',victim=victim,killerKillstreak=1,ruleMode=2})
    h.bus:_OnKillNotice('UNIT_KILL_STREAK',{killerName='Self',victimName=victim,killerKillStreak=1,gameType=1})
    local t=h.F:GetPersonalHistoryProjection().totals
    assert(t.kills==1 and t.inferredKills==0,'native confirmations were dropped/double counted/inferred')
    local d=h.F:DescribeDiagnosticDetail().kills
    assert(d.counters.kill_credited==1 and d.counters.duplicate_death==1)
    local found=false;for _,row in ipairs(d.events)do if row.upgraded then found=true end end
    assert(found,'late attribution upgrade not diagnosed')
end)
Test('early native confirmation cancels the pending death notice',function()
    local h=Boot();h:Damage(victim);h.bus:_OnDeathNotice(victim)
    h.bus:_OnKillNotice('UNIT_KILL_STREAK',{killerName='Self',victimName=victim,killerKillStreak=1,gameType=1})
    h:Advance(1800)
    assert(h.F:GetPersonalHistoryProjection().totals.kills==1)
    assert(h.F:DescribeDiagnosticDetail().kills.pendingNotices==0)
end)
Test('direct death with a target ID deduplicates after a name-only kill',function()
    local h=Boot()
    h.bus:_OnKillNotice('INSTANT_GAME_KILL',{killer='Self',victim=victim,killerKillstreak=1})
    h.A:_DispatchFact({category='death',kind='death',sourceName='Self',targetName=victim,targetId='victim-id',targetKind='PLAYER',receivedAt=h.now})
    assert(h.F:GetPersonalHistoryProjection().totals.kills==1)
end)
Test('a later direct killer also upgrades a name-only death',function()
    local h=Boot();h:Damage(victim);h.bus:_OnDeathNotice(victim);h:Advance(1800)
    h.A:_DispatchFact({category='death',kind='death',sourceName='Self',targetName=victim,targetId='victim-id',targetKind='PLAYER',receivedAt=h.now})
    assert(h.F:GetPersonalHistoryProjection().totals.kills==1)
end)
Test('changed native kill streak permits a second confirmed kill',function()
    local h=Boot()
    h.bus:_OnKillNotice('INSTANT_GAME_KILL',{killer='Self',victim=victim,killerKillstreak=1})
    h:Advance(2000)
    h.bus:_OnKillNotice('INSTANT_GAME_KILL',{killer='Self',victim=victim,killerKillstreak=2})
    h.bus:_OnKillNotice('UNIT_KILL_STREAK',{killerName='Self',victimName=victim,killerKillStreak=2,gameType=1})
    assert(h.F:GetPersonalHistoryProjection().totals.kills==2)
end)
Test('confirmed deaths of same-name NPCs do not create statistics',function()
    local h=Boot()
    for _,id in ipairs({'npc-1','npc-2'})do
        h.A:_DispatchFact({category='death',kind='death',sourceName='Self',targetName='Npc',targetId=id,targetKind='NPC',receivedAt=h.now})
    end
    local t=h.F:GetPersonalHistoryProjection().totals
    assert(t.npcKills==nil and t.kills==0 and t.deaths==0)
    assert(h.A:GetMetric('kills').state.actorCount==0,'NPC deaths allocated statistic actors')
end)
Test('all scope never infers player or NPC kills from damage and death',function()
    local h=Boot();h.bus._StartGlobalBridge=function()return true end
    assert(h.F.Commands:SetCollectionScope('all'))
    h:Damage('Npc');h.bus:_OnDeathNotice('Npc');h:Damage(victim);h.bus:_OnDeathNotice(victim);h:Advance(1800)
    local t=h.F:GetPersonalHistoryProjection().totals
    assert(t.npcKills==nil and t.inferredNpcKills==nil and t.kills==0 and t.inferredKills==0,'damage plus death fabricated a kill')
    assert(h.F:DescribeDiagnosticDetail().kills.counters.missing_killer_source==1)
    h.bus:_OnKillNotice('INSTANT_GAME_KILL',{killer='Self',victim=victim,killerKillstreak=1})
    h:Death('Npc')
    t=h.F:GetPersonalHistoryProjection().totals
    assert(t.kills==1 and t.npcKills==nil and t.inferredKills==0 and t.inferredNpcKills==nil,'late explicit player attribution was lost')
end)
Test('self death never creates a self kill',function()
    local h=Boot();h:Death('Self')
    local t=h.F:GetPersonalHistoryProjection().totals
    assert(t.deaths==1 and t.kills==0 and t.npcKills==nil)
    local p=h.A:GetMetricProjection('kills',{includeZero=true})
    assert((p.rows[1].kills or 0)==0 and p.rows[1].deaths==1)
end)
Test('being killed by an NPC still records own death',function()
    local h=Boot()
    h.A:_DispatchFact({category='death',kind='death',sourceName='Npc',sourceKind='NPC',targetName='Self',targetKind='PLAYER',targetId='self-id',receivedAt=h.now})
    local t=h.F:GetPersonalHistoryProjection().totals
    assert(t.deaths==1 and t.kills==0 and t.npcKills==nil)
    local p=h.A:GetMetricProjection('kills',{valueKey='deaths',includeZero=true})
    assert(#p.rows==1 and p.rows[1].name=='Self' and p.rows[1].deaths==1,'NPC killer suppressed own death')
end)
Test('unknown victims and damaged-only NPC notices are not kills',function()
    local h=Boot();h.S.Services.CombatRelationV3.GetUnit=function(_,name)return {kind=name=='Npc' and 'NPC' or 'UNKNOWN'}end
    h:Damage('Npc');h.bus:_OnDeathNotice('Npc');h:Advance(1800);h:Death('Unknown')
    local t=h.F:GetPersonalHistoryProjection().totals
    assert(t.kills==0 and t.npcKills==nil,'unknown kind or missing dealer fabricated a kill')
    assert(h.F:DescribeDiagnosticDetail().kills.counters.unknown_victim_kind==1)
end)
Test('DOT damage uses the native spell amount ABI',function()
    local h=Boot();local before=h.F:GetPersonalHistoryProjection().totals.damage
    h.bus:_OnCombatRaw('private','self-id','SPELL_DOT_DAMAGE','Self','Npc',11,'Burning',0,37,true)
    assert(h.F:GetPersonalHistoryProjection().totals.damage==before+37,'DOT damage was dropped')
    assert(h.bus:GetDiagnosticDetail().unknownTypeDropped==0)
end)
Test('malformed native kill payloads are bounded and do not credit',function()
    local h=Boot()
    for _,p in ipairs({{}, {killer='Self',victim='Self'}, {killer={},victim=victim}, {killer='Self',victim=string.rep('x',513)}})do
        h.bus:_OnKillNotice('INSTANT_GAME_KILL',p)
    end
    assert(h.F:GetPersonalHistoryProjection().totals.kills==0)
    assert(h.bus:GetDiagnosticDetail().killNotifications.rejected==4)
    assert(#h.F:DescribeDiagnosticDetail().kills.events==0)
end)
Test('optional registration failure preserves ordinary combat and stops quietly',function()
    local h=Boot();local host={registered={},unregistered={},handlers={}}
    function host:SetHandler(key,fn)self.handlers[key]=fn end
    function host:ReleaseHandler(key)self.handlers[key]=nil end
    function host:RegisterEvent(name)
        if name=='INSTANT_GAME_KILL' then return false end
        self.registered[name]=true
    end
    function host:UnregisterEvent(name)
        self.unregistered[name]=true
        if name=='UNIT_KILL_STREAK' then return false end
        self.registered[name]=nil
    end
    h.S.PhysicalId=function(id)return id end
    h.S.NativeObjectFactory={CreateWindow=function()return host end}
    assert(h.bus:_StartPrivateHost())
    assert(host.registered.COMBAT_MSG and host.registered.UNIT_DEAD_NOTICE and host.registered.UNIT_KILL_STREAK and not host.registered.UNIT_DEAD)
    assert(h.bus:GetDiagnosticDetail().killNotifications.registrations.INSTANT_GAME_KILL=='unavailable')
    local handler=host.handlers.OnEvent
    local before=h.writes
    handler(host,'UNIT_DEAD','npc-raw-id',nil,12)
    assert(h.bus:GetDiagnosticDetail().npcKillEvidence==nil and h.writes==before,'retired raw death probe remains active')
    handler(host,'COMBAT_MSG','self-id','SPELL_DAMAGE','Self','Npc',11,'Hit',0,100,true,nil,nil,nil,nil,nil,false,'native-tail-16')
    assert(h.F:GetPersonalHistoryProjection().totals.damage==100,'removing raw probe dropped known PVE damage')
    handler(host,'UNIT_KILL_STREAK',{killerName='Self',victimName=victim,killerKillStreak=1,gameType=1})
    assert(h.F:GetPersonalHistoryProjection().totals.kills==1)
    h.S.Generation=h.S.Generation+1
    handler(host,'UNIT_KILL_STREAK',{killerName='Self',victimName='Stale',killerKillStreak=2,gameType=1})
    assert(h.F:GetPersonalHistoryProjection().totals.kills==1,'stale generation credited kill')
    h.S.Generation=h.S.Generation-1;h.bus.running=false
    handler(host,'UNIT_KILL_STREAK',{killerName='Self',victimName='Stopped',killerKillStreak=2,gameType=1})
    assert(h.F:GetPersonalHistoryProjection().totals.kills==1,'stopped host credited kill')
    assert(h.bus:_ReleasePrivateHost());assert(host.unregistered.UNIT_KILL_STREAK and host.handlers.OnEvent==nil)
    assert(h.bus:GetDiagnosticDetail().killNotifications.registrations.UNIT_KILL_STREAK=='retained','failed optional release was hidden')
end)
Test('capturing pending notice neither runs scheduler nor writes history',function()
    local h=Boot();h:Damage(victim);h.bus:_OnDeathNotice(victim)
    local writes,starts=h.writes,h.starts
    local first=assert(h.F:DescribeDiagnosticDetail());local text=ExportReport(h)
    assert(first.kills.pendingNotices==1 and text:find('notice_waiting',1,true))
    assert(h.writes==writes and h.starts==starts and h.A:GetMetric('kills').state.noticeCount==1,'report changed live work')
end)
Test('PVE damage keeps no retired NPC ledger or raw probe',function()
    local h=Boot()
    for i=1,100 do h:Damage('Npc') end
    assert(h.F:GetPersonalHistoryProjection().totals.damage==10000,'NPC probe removal dropped PVE damage')
    local metric=h.A:GetMetric('kills')
    assert(metric.state.targetCount==0 and metric.state.targets.Npc==nil,'retired NPC ledger still allocated')
    assert(h.bus.damageEvidence==nil and h.bus.unitDeadEvidence==nil and h.bus._OnUnitDeadEvidence==nil,'retired probe still allocated')
    assert(h.bus:GetDiagnosticDetail().npcKillEvidence==nil and not ExportReport(h):find('npcKillEvidence',1,true),'merged export still includes retired probe')
    assert(h.F:Disable())
    local writes=h.writes
    h:Damage('Npc')
    assert(h.writes==writes,'stopped statistics continued writing')
end)
Test('death evidence is bounded and survives stopping statistics',function()
    local h=Boot()
    for i=1,50 do h:Death('Victim'..i);h.now=h.now+2000 end
    local d=assert(h.F:DescribeDiagnosticDetail()).kills
    assert(#d.events<=32 and d.evicted>0,'unbounded death journal')
    assert(h.F:Disable('test'))
    assert(#h.F:DescribeDiagnosticDetail().kills.events==#d.events,'disable erased incident evidence')
end)
Test('crowd damage creates no metric evidence in self scope',function()
    local h=Boot();local count=h.A.metricDispatches
    for i=1,10000 do h.bus:_OnCombatRaw('private','other-id','SPELL_DAMAGE','Other'..i,'Enemy',11,'Hit',0,100,true)end
    assert(h.A.metricDispatches==count)
    assert(#h.F:DescribeDiagnosticDetail().kills.events==0,'damage allocated death trace rows')
end)
Test('unrecognized native types retain bounded scalar samples',function()
    local h=Boot()
    for i=1,40 do h.bus:_OnCombatRaw('private','self-id','UNVERIFIED_TYPE_'..i,'Self',victim,11,'Unknown',0,0,true,{})end
    local d=assert(h.bus:GetDiagnosticDetail())
    assert(#d.unknownEvents==32 and d.unknownTypeDropped==8,'unknown type evidence must be bounded')
    assert(d.unknownEvents[1].rawMore1=='<table>','raw sample retained native/non-scalar object')
    d.unknownEvents[1].sourceName='mutated'
    assert(h.bus:GetDiagnosticDetail().unknownEvents[1].sourceName=='Self','bus diagnostic exposes live rows')
end)
Test('merged TXT also includes related hidden analytics failures',function()
    local h=Boot()
    h.S.ModuleDiagnosticsHub:Observe({seq=1,level='error',source='combat_analytics',code='ANALYTICS_FAILED',message='metric failure'})
    assert(ExportReport(h):find('ANALYTICS_FAILED',1,true),'merged export omitted linked analytics error')
end)
Test('skill kill details keep native attribution without borrowing the last damage skill',function()
    local h=Boot();h:Damage(victim)
    h.bus:_OnKillNotice('UNIT_KILL_STREAK',{killerName='Self',victimName=victim,killerKillStreak=1,gameType=5})
    local p=assert(h.A:GetMetricProjection('kills',{actorKey='name:self',actorName='Self'}))
    assert(p.skills and #p.skills==1,'skill drill-down missing')
    local row=p.skills[1]
    assert(row.name=='技能未确认' and row.abilityId==nil and row.kills==1,'last damage skill was guessed')
    assert(#row.targets==1 and row.targets[1].name==victim and row.targets[1].kills==1)
    row.targets[1].name='mutated'
    assert(h.A:GetMetricProjection('kills',{actorKey='name:self',actorName='Self'}).skills[1].targets[1].name==victim,'skill detail exposes live state')
    h.bus:_OnKillNotice('INSTANT_GAME_KILL',{killer='Self',victim=victim,killerKillstreak=1})
    assert(h.A:GetMetricProjection('kills',{actorKey='name:self',actorName='Self'}).skills[1].kills==1,'duplicate notification counted twice in skill details')
end)
Test('explicit skill IDs keep separate victim lists even with the same skill name',function()
    local h=Boot()
    for _,event in ipairs({{id=101,victim='First'},{id=102,victim='Second'},{id=101,victim='First'}}) do
        h.A:_DispatchFact({category='death',kind='death',sourceName='Self',sourceKind='PLAYER',targetName=event.victim,
            targetKind='PLAYER',rawAbilityId=event.id,abilityName='SameSkill',receivedAt=h.now})
        h.now=h.now+10000
    end
    local p=h.A:GetMetricProjection('kills',{actorKey='name:Self'})
    assert(p.actor.kills==3 and #p.skills==2)
    assert(p.skills[1].abilityId==101 and p.skills[1].kills==2 and p.skills[1].targets[1].kills==2)
    assert(p.skills[2].abilityId==102 and p.skills[2].targets[1].name=='Second')
    h:Death('Npc')
    assert(h.A:GetMetricProjection('kills',{actorKey='name:Self'}).actor.kills==3,'NPC added to player skill kills')
    assert(h.F:Disable())
    assert(h.A:GetMetricProjection('kills',{actorKey='name:Self'}).actor.kills==3,'disable erased current-period skill details')
    assert(h.F:ClearMetric('kills'))
    assert(#h.A:GetMetricProjection('kills',{actorKey='name:Self'}).skills==0,'explicit clear left old skill victims')
end)
Test('skill victim retention is bounded while kill totals stay exact',function()
    local h=Boot()
    for i=1,150 do
        h.A:_DispatchFact({category='death',kind='death',sourceName='Self',sourceKind='PLAYER',targetName='Player'..i,
            targetKind='PLAYER',rawAbilityId=100+i,abilityName='Skill'..i,receivedAt=h.now})
        h.now=h.now+10000
    end
    local p=h.A:GetMetricProjection('kills',{actorKey='name:Self'})
    assert(p.actor.kills==150 and #p.skills<=66 and p.retainedTargets<=128)
    local kills,omitted=0,0
    for _,row in ipairs(p.skills) do kills=kills+row.kills;omitted=omitted+(row.omittedTargets or 0) end
    assert(kills==150 and omitted>0,'capacity silently lost aggregate skill counts or hid omitted victims')
end)
print(string.format('KILL DIAGNOSTICS RESULT %d passed / %d failed (%s)',passed,failed,_VERSION))
assert(failed==0,'kill diagnostic regression failures: '..failed)

-- Replicated Suite · 战斗击杀诊断测试
-- 作者：Replicated
-- QQ群：1104129461
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
    S.Events={Publish=function()end,SubscribeInternal=function()return true end,SubscribeOptional=function(_,name)
        assert(name=='PLAYER_HONOR_POINT_CHANGED_IN_HPW','extra native subscription');return true
    end,UnsubscribeInternal=function()end,Unsubscribe=function()return true end}
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
-- 入口证据须早于自身范围过滤，才能区分未收到和收到后排除；替身事件不证明 RU 必然发通知。
Test('native ingress survives self filtering and distinguishes rejected payloads',function()
    local h=Boot()
    h.bus:_OnKillNotice('UNIT_KILL_STREAK',{killerName='Other',victimName='Untouched',killerKillStreak=1,gameType=5})
    h.bus:_OnKillNotice('UNIT_KILL_STREAK',{killerName={},victimName='Bad'})
    local d=h.F:DescribeDiagnosticDetail()
    assert(d.bus.killNotifications.events and #d.bus.killNotifications.events==2,'native ingress evidence missing')
    assert(d.bus.killNotifications.events[1].victim=='Untouched' and d.bus.killNotifications.events[1].reason=='normalized')
    assert(d.bus.killNotifications.events[2].reason=='invalid_payload' and d.bus.killNotifications.events[2].killer=='<table>')
    assert(d.ingress.counters.self_scope_filtered==1 and d.ingress.events[1].victim=='Untouched','filtered native attribution disappeared')
    assert(h.F:GetPersonalHistoryProjection().totals.kills==0 and #d.kills.events==0,'diagnostics expanded self statistics')
    local text=ExportReport(h)
    assert(text:find('Untouched',1,true) and text:find('self_scope_filtered',1,true),'merged TXT omitted ingress/filter evidence')
end)
-- 原生明确自身归属无须最近伤害；高密度他人伤害不能挤占死亡入口证据。
Test('one shot kill with no damage ledger remains accepted after crowd traffic',function()
    local h=Boot()
    for i=1,2000 do h.bus:_OnCombatRaw('private','other-id','SPELL_DAMAGE','Other'..i,'Enemy',11,'Hit',0,100,true) end
    h.bus:_OnKillNotice('UNIT_KILL_STREAK',{killerName='Self',victimName='OneShot',killerKillStreak=1,gameType=5})
    local d=h.F:DescribeDiagnosticDetail()
    assert(h.F:GetPersonalHistoryProjection().totals.kills==1,'confirmed one shot kill requires prior damage')
    assert(d.ingress.counters.accepted==1 and #d.ingress.events==1,'damage traffic allocated ingress diagnostics')
    assert(#d.bus.killNotifications.events==1)
end)
-- 姓名死亡通知仍无击杀者；原始标量留在入口，超时结算不得据此推断击杀。
Test('missing attribution keeps native death notice parameters at ingress',function()
    local h=Boot();h:Damage(victim);h.bus:_OnDeathNotice(victim,'two',false,17,'five');h:Advance(1800)
    local d=h.F:DescribeDiagnosticDetail()
    local row=assert(d.bus.killNotifications.events and d.bus.killNotifications.events[1],'death ingress evidence missing')
    assert(row.kind=='death_notice' and row.victim==victim and row.rawNotice2=='two' and row.rawNotice3==false and row.rawNotice5=='five')
    assert(d.kills.counters.missing_killer_source==1 and h.F:GetPersonalHistoryProjection().totals.kills==0,'missing attribution was fabricated')
end)
-- 没有活动死亡指标时必须区分采集关闭和通知未到，原生接收事实仍只读留证。
Test('ingress distinguishes inactive metrics without starting collection',function()
    local h=Boot();h.A.factPlans.death={};local writes=h.writes
    h.bus:_OnKillNotice('UNIT_KILL_STREAK',{killerName='Self',victimName='Inactive'})
    local d=h.F:DescribeDiagnosticDetail()
    assert(d.ingress.counters.no_active_metrics==1 and d.ingress.events[1].victim=='Inactive')
    assert(h.writes==writes and h.F:GetPersonalHistoryProjection().totals.kills==0,'inactive ingress started statistics')
end)
-- 覆盖淘汰和脱离现场的导出副本须可验证；停止业务不得抹掉刚发生的漏记现场。
Test('ingress has bounded detached read only snapshots preserved on stop',function()
    local h=Boot()
    for i=1,80 do h.bus:_OnKillNotice('UNIT_KILL_STREAK',{killerName='Other',victimName='Filtered'..i,killerKillStreak=1,gameType=5}) end
    local before=h.writes;local d=h.F:DescribeDiagnosticDetail()
    assert(#d.bus.killNotifications.events==64 and d.bus.killNotifications.evicted==16)
    assert(#d.ingress.events==32 and d.ingress.evicted==48 and d.ingress.counters.self_scope_filtered==80)
    d.bus.killNotifications.events[1].victim='mutated';d.ingress.events[1].victim='mutated'
    local text=ExportReport(h);local current=h.F:DescribeDiagnosticDetail()
    assert(current.bus.killNotifications.events[1].victim=='Filtered17' and current.ingress.events[1].victim=='Filtered49','diagnostics expose live rows')
    assert(text:find('Filtered80',1,true) and h.writes==before,'snapshot writes or drops retained evidence')
    assert(h.F:Disable('test'));assert(#h.F:DescribeDiagnosticDetail().ingress.events==32,'disable erased ingress evidence')
    h.bus:_OnKillNotice('UNIT_KILL_STREAK',{killerName='Self',victimName='Stopped'})
    assert(h.bus:GetDiagnosticDetail().killNotifications.received==80,'stopped host recorded ingress')
end)
-- 2026-10-16：实机战争通知使用此参数形状；只驱动真实 Bus，不把荣誉金额作为击杀输入。
local function WarKill(h,name,count,mode)
    h.bus:_OnKillNotice('UNIT_KILL_STREAK',{killerName='Self',victimName=name,killerKillStreak=count,gameType=mode or 5})
end
Test('wild kill notices preserve the two native auxiliary parameters as evidence only',function()
    local h=Boot();local seen={}
    assert(h.bus:Subscribe(seen,function(_,fact)
        if fact.kind=='kill_notice' then seen.param1,seen.param2=fact.rawNotice4,fact.rawNotice5 end
    end,{scope='self'}))
    local payload={killerName='Self',victimName='WildVictim',killerKillStreak=3,gameType=5,param1=0,param2=false}
    h.bus:_OnKillNotice('UNIT_KILL_STREAK',payload)
    payload.param1,payload.param2=999,999
    local d=h.F:DescribeDiagnosticDetail();local row=assert(d.bus.killNotifications.events[1])
    assert(row.rawNotice4==0 and row.rawNotice5==false and seen.param1==0 and seen.param2==false,
        'native auxiliary fields were dropped or borrowed')
    assert(h.F:GetPersonalHistoryProjection().totals.kills==1,'auxiliary parameters fabricated additional kills')
    local before=h.writes;local text=ExportReport(h)
    assert(text:find('rawNotice4',1,true) and text:find('rawNotice5',1,true) and h.writes==before,
        'export lost the auxiliary evidence or wrote history')
    h.bus:_OnKillNotice('UNIT_KILL_STREAK',{killerName={},victimName='Bad',param1={},param2=string.rep('x',600)})
    row=h.bus:GetDiagnosticDetail().killNotifications.events[2]
    assert(row.reason=='invalid_payload' and row.rawNotice4=='<table>' and #row.rawNotice5<530,
        'invalid payload retained a native object or unbounded text')
end)
-- 取证运行真实身份服务，只替换 Native API 返回；任意字段名都保留，不能把测试造出的字段名当正式 ABI。
Test('system kill evidence captures allowed native fields without changing statistics',function()
    local h=Boot();local calls=0
    local raw={unverified_native_field=1147,zero=0,flag=false,nested={raw_value='1147'},opaque=function()end}
    local previousUnit=X2Unit;X2Unit={}
    h.S.Api={IsCapabilityAllowed=function()return true end,CallCapability=function(_,cap,host,method,arg)
        assert(host==X2Unit and ((method=='UnitInfo' and arg=='player') or (method=='GetUnitInfoById' and arg=='self-id')))
        calls=calls+1;return true,raw
    end}
    dofile('services/rs_unit_identity_v3.lua')
    local identity=h.S.Services.UnitIdentityV3;identity.player={id='self-id',name='Self',normalizedName='self',reliable=true}
    WarKill(h,'First',1);WarKill(h,'Second',2);h:Advance(300)
    assert(calls==2,'burst should coalesce into one sample of the two allowed getters')
    local d=h.F:DescribeDiagnosticDetail();local sample=assert(d.systemKillEvidence.samples[1])
    assert(sample.unitInfo.fields.unverified_native_field==1147 and sample.unitInfo.fields.zero==0
        and sample.unitInfo.fields.flag==false and sample.unitInfo.fields['nested.raw_value']=='1147','raw primitives or nested evidence lost')
    assert(sample.unitInfo.fields.opaque==nil and sample.unitInfo.verifiedKillCounter==nil,'unknown field was promoted into an authoritative counter')
    sample.unitInfo.fields.unverified_native_field=-1
    local before=h.writes;local text=ExportReport(h)
    assert(calls==2 and h.writes==before and text:find('1147',1,true),'export sampled Native, wrote history or lost system evidence')
    assert(h.F:DescribeDiagnosticDetail().systemKillEvidence.samples[1].unitInfo.fields.unverified_native_field==1147,'diagnostics expose cached native evidence')
    assert(h.F:GetPersonalHistoryProjection().totals.kills==2,'lifetime native field was imported into session kills')
    WarKill(h,'Third',3);assert(calls==2);h:Advance(5000);assert(calls==4,'trailing sample did not refresh after the rate limit')
    X2Unit=previousUnit
end)
-- 禁用能力不能通过方法存在绕过；停止统计必须撤掉未执行的原生采样，报告仍可读已留存快照。
Test('system evidence respects capabilities bounds and collection lifecycle',function()
    local h=Boot();local calls=0;local previousUnit=X2Unit;X2Unit={}
    h.S.Api={IsCapabilityAllowed=function(_,cap)return cap=='X2Unit:UnitInfo'end,CallCapability=function()
        calls=calls+1;local out={} for i=1,400 do out['field'..i]=i end;return true,out
    end}
    dofile('services/rs_unit_identity_v3.lua')
    local identity=h.S.Services.UnitIdentityV3;identity.player={id='self-id',name='Self',normalizedName='self',reliable=true}
    WarKill(h,'First',1);h:Advance(300)
    local sample=h.F:DescribeDiagnosticDetail().systemKillEvidence.samples[1]
    assert(calls==1 and sample.byId.status=='capability_unavailable' and sample.unitInfo.truncated,'capability gate or bounded capture bypassed')
    WarKill(h,'Second',2);assert(h.F:Disable());h:Advance(6000)
    assert(calls==1,'stopped statistics ran a pending Native sample')
    X2Unit=previousUnit
end)
-- 真实1/2/5/6只证明中间通知不完整；累计口径未验证前明确标记缺口，不把候选证据写进永久战绩。
Test('native sequence gaps are diagnosed without fabricating historical kills',function()
    local h=Boot()
    for _,entry in ipairs({{name='First',count=1},{name='Second',count=2},{name='Fifth',count=5},{name='Sixth',count=6}})do
        WarKill(h,entry.name,entry.count);h:Advance(2000)
    end
    local d=h.F:DescribeDiagnosticDetail().kills;local found=false
    for _,row in ipairs(d.events)do if row.reason=='native_counter_gap' then
        assert(row.previousCount==2 and row.nativeCount==5 and row.missingNotifications==2 and row.credited==false);found=true
    end end
    assert(found and h.F:GetPersonalHistoryProjection().totals.kills==4,'unverified counter gap fabricated permanent kills')
end)
-- 首次计数不是缺口；停止/恢复以后重新取证，不能把采集前和暂停期间的序号当作漏记补入。
Test('native gap evidence resets across inactive collection without backfilling',function()
    local h=Boot();WarKill(h,'First',6)
    assert(h.F:DescribeDiagnosticDetail().kills.counters.native_counter_gap==nil)
    assert(h.F:Disable());assert(h.F:Enable('resume'));h:Advance(2000);WarKill(h,'AfterPause',12)
    assert(h.F:DescribeDiagnosticDetail().kills.counters.native_counter_gap==nil)
    assert(h.F:GetPersonalHistoryProjection().totals.kills==2,'evidence collection changed permanent history')
end)
Test('fourteen positive war honor receipts are fourteen participations independently of five named kills',function()
    local h=Boot()
    for i,amount in ipairs({68,21,21,21,84,76,19,19,19,21,21,19,19,19})do
        h.A:_OnNativeEvent('PLAYER_HONOR_POINT_CHANGED_IN_HPW',amount)
    end
    for i,count in ipairs({1,3,2,5,3})do WarKill(h,'Named'..i,count) end
    h:Advance(1600)
    local t=h.F:GetPersonalHistoryProjection().totals
    assert(t.honorParticipations==14 and t.honorKills==nil and t.kills==14,'five explicit and fourteen honor receipts did not reconcile to fourteen kills')
    assert(h.F.Commands:SetSelectedValue('kills','honorParticipations')==false,'separate honor counting remains selectable')
    h.F.State.selectedValues.kills='honorParticipations'
    assert(h.F:GetStatisticsCountKey()=='kills','old honor preference replaced unified kills')
    local rows=h.A:GetMetricProjection('kills',{valueKey='honorParticipations',includeZero=true}).rows
    assert(rows[1].honorParticipations==14 and rows[1].kills==14)
    assert(h.F.Commands:SetSelectedValue('kills','kills'))
    assert(h.F:GetPersonalHistoryProjection().totals.kills==14,'old display preference changed the unified total')
end)
Test('explicit first and honor first share one kill including a late confirmation',function()
    for _,order in ipairs({'explicit_first','honor_first','honor_settled_first'})do
        local h=Boot()
        if order=='explicit_first' then WarKill(h,'Victim',1) end
        h.A:_OnNativeEvent('PLAYER_HONOR_POINT_CHANGED_IN_HPW',86)
        if order=='honor_settled_first' then h:Advance(1600) end
        if order~='explicit_first' then WarKill(h,'Victim',1) end
        h:Advance(1600)
        h.bus:_OnKillNotice('UNIT_KILL_STREAK',{killerName='Self',victimName='Victim',killerKillStreak=1,gameType=5},'private:kill_global')
        assert(h.F:GetPersonalHistoryProjection().totals.kills==1,'same kill counted twice: '..order)
        local row=h.A:GetMetricProjection('kills',{includeZero=true}).rows[1]
        assert(row.kills==1)
        local detail=h.A:GetMetricProjection('kills',{actorKey=row.key})
        assert(detail.skills[1].kills==1 and detail.skills[1].targets[1].key=='Victim','native confirmation lost its real victim')
    end
end)
Test('explicit kills without honor count immediately and generic honor never substitutes for HPW',function()
    local h=Boot()
    -- 普通区域没有战争荣誉：不能等荣誉出现才接纳明确归属，也不能拿任务等通用奖励补人头。
    WarKill(h,'NormalAreaVictim',1)
    assert(h.F:GetPersonalHistoryProjection().totals.kills==1,'no-honor kill did not count immediately')
    assert(h.tasks.v3_combat_kills_honor==nil,'explicit kill waited for an honor confirmation')
    h.A:_OnNativeEvent('PLAYER_HONOR_POINT',84,'84',false)
    h.A:_OnNativeEvent('SHOW_ACCUMULATE_HONOR_POINT_DURING_HPW','Zone',84,1)
    h:Advance(9000)
    assert(h.F:GetPersonalHistoryProjection().totals.kills==1,'generic or cumulative reward became a kill')
    WarKill(h,'SecondNormalAreaVictim',2)
    assert(h.F:GetPersonalHistoryProjection().totals.kills==2,'ordinary kills became dependent on war honor')
end)
Test('assists and unknown amounts never supplement kills while repeated equal kill rewards do',function()
    local h=Boot()
    for _,amount in ipairs({3,12,4,13,168,152,84,84,19,21})do h.A:_OnNativeEvent('PLAYER_HONOR_POINT_CHANGED_IN_HPW',amount) end
    h:Advance(1600)
    assert(h.F:GetPersonalHistoryProjection().totals.kills==4,'assist/unknown amount counted or equal genuine rewards merged')
    local p=h.A:GetMetricProjection('kills',{includeZero=true});assert(p.rows[1].kills==4 and p.rows[1].honorAssistedKills==4)
    local detail=h.A:GetMetricProjection('kills',{actorKey=p.rows[1].key});assert(#detail.skills==0,'honor supplement fabricated victims or skills')
end)
Test('confirmed sixty honor rewards supplement unified kills and pair with late explicit notices',function()
    local h=Boot();h.A:_OnNativeEvent('PLAYER_HONOR_POINT_CHANGED_IN_HPW',60)
    h:Advance(1600)
    assert(h.F:GetPersonalHistoryProjection().totals.kills==1,'confirmed 60 honor reward did not supplement the kill')
    WarKill(h,'SixtyVictim',1)
    assert(h.F:GetPersonalHistoryProjection().totals.kills==1,'late explicit notice doubled the 60 honor kill')
    h.A:_OnNativeEvent('PLAYER_HONOR_POINT_CHANGED_IN_HPW',60);h:Advance(1600)
    assert(h.F:GetPersonalHistoryProjection().totals.kills==2,'two genuine 60 honor rewards were merged')
end)
-- 21:19诊断的27笔原生荣誉：战争60/12，转纷争后15/3；保留真实间隔与一笔明确归属。
Test('exported war to conflict sequence reconciles sixty and fifteen without assists or duplicates',function()
    local h=Boot();local start=h.now
    local events={
        {2800490,4140},{2964550,12},{2986140,60},{2987270,60},{2989230,60},
        {2994990,12},{3003790,12},{3091640,12},{3119630,12},{3143490,12},
        {3205310,12},{3294920,60},{3306880,-10},{3619050,3},{3668350,6210},
        {3736310,15},{3808060,15},{3808280,15},{3815490,3},{3823730,3},
        {3877420,15},{3897740,3},{3901720,15},{3930780,15},{3931340,'Mismo'},
        {3933560,3},{3935500,3},{3953510,-10},
    }
    for _,event in ipairs(events)do
        h:Advance(start+event[1]-2800490-h.now)
        if type(event[2])=='number' then
            h.A:_OnNativeEvent('PLAYER_HONOR_POINT_CHANGED_IN_HPW',event[2])
        else
            WarKill(h,event[2],1)
            h.bus:_OnKillNotice('UNIT_KILL_STREAK',{killerName='Self',victimName=event[2],killerKillStreak=1,gameType=5},'private:kill_global')
        end
    end
    h:Advance(1600)
    local t=h.F:GetPersonalHistoryProjection().totals
    assert(t.kills==10,'four 60 and six 15 rewards did not reconcile to ten unique kills: '..tostring(t.kills))
    assert(t.honorParticipations==25 and t.honorKills==nil,'raw receipt evidence changed or split kill counter returned')
    local row=h.A:GetMetricProjection('kills',{includeZero=true}).rows[1]
    assert(row.kills==10 and row.honorAssistedKills==9,'explicit Mismo kill doubled or source evidence was lost')
    local counters=h.F:DescribeDiagnosticDetail().kills.counters
    assert(counters.honor_assist_excluded==13,'3/12 assists entered kill matching')
    assert(counters.honor_amount_unmatched==2,'large unknown 4140/6210 rewards were treated as kills')
    assert(h.A.metricErrors==0 and h.A.metricMutations==0)
end)
Test('stopping collection revokes pending honor work and saved callbacks',function()
    local h=Boot();h.A:_OnNativeEvent('PLAYER_HONOR_POINT_CHANGED_IN_HPW',84)
    local task=assert(h.tasks.v3_combat_kills_honor);assert(h.F:Disable());h:Advance(2000);task.fn()
    assert(h.F:GetPersonalHistoryProjection().totals.kills==0,'stopped generation settled pending honor')
end)
Test('honor pairing ledgers are bounded and explicit overflow never creates extra kills',function()
    local h=Boot()
    for i=1,300 do WarKill(h,'Victim'..i,i) end
    for i=1,300 do h.A:_OnNativeEvent('PLAYER_HONOR_POINT_CHANGED_IN_HPW',84) end
    h:Advance(1600)
    assert(h.F:GetPersonalHistoryProjection().totals.kills==300,'overflow lost deduplication and added honor twice')
    local state=h.A:GetMetric('kills').state
    assert(#state.honorReceipts<=256 and #state.explicitReceipts<=256)
end)
Test('a starved scheduler does not lose a pending reward when a new reward arrives',function()
    local h=Boot();h.A:_OnNativeEvent('PLAYER_HONOR_POINT_CHANGED_IN_HPW',84)
    h.now=h.now+9000;h.A:_OnNativeEvent('PLAYER_HONOR_POINT_CHANGED_IN_HPW',84)
    h:Advance(0);assert(h.F:GetPersonalHistoryProjection().totals.kills==1,'expired pending reward was pruned before settlement')
    h:Advance(1600);assert(h.F:GetPersonalHistoryProjection().totals.kills==2)
end)
Test('paired honor repairs failed history persistence without adding a second live kill',function()
    local h=Boot();local p=h.S.Persistence;local mark=p.MarkDirty
    p.MarkDirty=function()return false,'reject first write'end
    WarKill(h,'Victim',1);assert(h.F:GetPersonalHistoryProjection().totals.kills==0)
    p.MarkDirty=mark;h.A:_OnNativeEvent('PLAYER_HONOR_POINT_CHANGED_IN_HPW',86);h:Advance(1600)
    assert(h.F:GetPersonalHistoryProjection().totals.kills==1,'paired evidence failed to repair the missing history increment')
    assert(h.A:GetMetricProjection('kills',{includeZero=true}).rows[1].kills==1,'repair doubled the live count')
end)
Test('honor pairing across midnight keeps original day and monotonic history bounds',function()
    for _,withNative in ipairs({false,true})do
        local h=Boot();h.S.Utils.GetServerTime=function()return {year=2026,month=10,day=25,hour=23,minute=59}end
        h.A:_OnNativeEvent('PLAYER_HONOR_POINT_CHANGED_IN_HPW',86)
        h.now=h.now+1100;h.S.Utils.GetServerTime=function()return {year=2026,month=10,day=26,hour=0,minute=0}end
        assert(h.F.PersonalHistory:Record({deaths=1}))
        if withNative then WarKill(h,'Victim',1) end
        h:Advance(600)
        local state=h.F.PersonalHistory.state
        assert(state.days['2026-10-25'].kills==1 and state.days['2026-10-26'].kills==0,'cross-day pair moved the kill to the confirmation day')
        assert(state.firstAt=='2026-10-25 23:59' and state.lastAt=='2026-10-26 00:00','late supplement regressed history timestamps')
    end
end)
Test('honor native argument evidence is bounded detached and never interprets unknown fields',function()
    local h=Boot();local a=h.A
    for i=1,40 do a:_OnNativeEvent('PLAYER_HONOR_POINT_CHANGED_IN_HPW',37,'unknown'..i,false,{},0/0) end
    local d=a:GetHonorIngressDiagnostics()
    assert(d.limit==32 and d.evicted==8 and #d.events==32)
    local row=d.events[32]
    assert(row.argCount==5 and row.arg1==37 and row.arg2=='unknown40' and row.arg3==false and row.arg4=='<table>' and row.arg5=='<non_finite>')
    row.arg2='changed';assert(a:GetHonorIngressDiagnostics().events[32].arg2=='unknown40')
    h:Advance(1600);assert(h.F:GetPersonalHistoryProjection().totals.kills==0,'unknown native honor fields were guessed as attribution')
    assert(h.F:DescribeDiagnosticDetail().honorIngress.events[32].arg1==37)
    local count=#a:GetHonorIngressDiagnostics().events;assert(h.F:Disable())
    a:_OnNativeEvent('PLAYER_HONOR_POINT_CHANGED_IN_HPW',86)
    assert(#a:GetHonorIngressDiagnostics().events==count,'stopped collection captured extra honor')
end)
Test('honor counts positive deltas only and keeps repeated equal receipts in one frame',function()
    local h=Boot()
    h.A:_OnNativeEvent('PLAYER_HONOR_POINT_CHANGED_IN_HPW',21)
    h.A:_OnNativeEvent('PLAYER_HONOR_POINT_CHANGED_IN_HPW',21)
    for _,amount in ipairs({-10,0,0/0,math.huge,1.5,'21',{}})do h.A:_OnNativeEvent('PLAYER_HONOR_POINT_CHANGED_IN_HPW',amount) end
    h.A:_OnNativeEvent('PLAYER_HONOR_POINT',1000,'1000',true)
    h.A:_OnNativeEvent('SHOW_ACCUMULATE_HONOR_POINT_DURING_HPW','Zone',120,1)
    assert(h.F:GetPersonalHistoryProjection().totals.honorParticipations==2,'negative, generic, cumulative or malformed honor was counted')
    assert(h.A.metricErrors==0 and h.A.metricMutations==0,'invalid amount polluted the shared native fact boundary')
    assert(h.F:Disable());h.A:_OnNativeEvent('PLAYER_HONOR_POINT_CHANGED_IN_HPW',21)
    assert(h.F:GetPersonalHistoryProjection().totals.honorParticipations==2,'inactive statistics counted honor')
end)
Test('honor supplements wait for pairing and never create independent kill counters',function()
    local h=Boot()
    for _,amount in ipairs({84,76,21,19,68,168,152,1})do h.A:_OnNativeEvent('PLAYER_HONOR_POINT_CHANGED_IN_HPW',amount) end
    local t=h.F:GetPersonalHistoryProjection().totals
    assert(t.honorKills==nil and t.honorParticipations==8 and t.kills==0,'honor-only evidence became a kill estimate')
    h.A:_OnNativeEvent('PLAYER_HONOR_POINT',84,'84',true)
    h.A:_OnNativeEvent('PLAYER_HONOR_POINT_CHANGED_IN_HPW',-84)
    assert(h.F:GetPersonalHistoryProjection().totals.honorKills==nil,'generic reward or deduction became a kill')
    assert(h.F.Commands:AddHonorKillAmount(100))
    h.A:_OnNativeEvent('PLAYER_HONOR_POINT_CHANGED_IN_HPW',100)
    assert(h.F:GetPersonalHistoryProjection().totals.honorKills==nil,'editing legacy rules reenabled unsafe counting')
    assert(h.F.Commands:RemoveHonorKillAmount(84))
    h.A:_OnNativeEvent('PLAYER_HONOR_POINT_CHANGED_IN_HPW',84)
    assert(h.F:GetPersonalHistoryProjection().totals.honorKills==nil)
    assert(h.F.Commands:SetSelectedValue('kills','honorKills')==false,'unverified kills remain selectable')
    h.F.State.selectedValues.kills='honorKills'
    assert(h.F:GetStatisticsCountKey()=='kills','old unsafe preference did not fall back to confirmed kills')
    assert(h.F.Commands:SetSelectedValue('kills','kills'))
    assert(h.F:GetPersonalHistoryProjection().totals.kills==0,'switching views promoted matched counts to confirmed kills')
    h:Advance(1600);assert(h.F:GetPersonalHistoryProjection().totals.kills==6,'accepted unmatched rewards did not enter the unified kill count')
end)
Test('multiple chat windows do not duplicate one raw honor reward or one named kill',function()
    local h=Boot();local a=h.A
    a:_OnNativeEvent('PLAYER_HONOR_POINT_CHANGED_IN_HPW',86)
    for _,window in ipairs({'A','B'})do
        a:_OnNativeEvent('CHAT_MESSAGE','system','获得86点荣誉点数',window)
        a:_OnNativeEvent('PLAYER_HONOR_POINT',86,'86',true)
        a:_OnNativeEvent('SHOW_ACCUMULATE_HONOR_POINT_DURING_HPW','zone',86,window)
    end
    local t=h.F:GetPersonalHistoryProjection().totals
    assert(t.honorParticipations==1 and t.kills==0 and t.honorKills==nil,'chat echoes added kill/receipt counts')
    WarKill(h,'Victim',1)
    h.bus:_OnKillNotice('UNIT_KILL_STREAK',{killerName='Self',victimName='Victim',killerKillStreak=1,gameType=5},'private:kill_global')
    t=h.F:GetPersonalHistoryProjection().totals
    assert(t.kills==1 and t.honorParticipations==1,'native kill mirror doubled the result')
    a:_OnNativeEvent('PLAYER_HONOR_POINT_CHANGED_IN_HPW',86)
    assert(h.F:GetPersonalHistoryProjection().totals.honorParticipations==2,'two real equal rewards were incorrectly merged')
end)
Test('honor rules are bounded and empty remains an explicit saved choice',function()
    local h=Boot();local f=h.F
    for _,value in ipairs({0,-1,1.5,math.huge,0/0,'bad',{}})do assert(f.Commands:AddHonorKillAmount(value)==false) end
    for _,value in ipairs(f:GetHonorKillAmounts())do assert(f.Commands:RemoveHonorKillAmount(value)) end
    local store=h.S.Persistence:GetStore(f.StoreId);local saved=store.get();store.apply(saved)
    assert(#f:GetHonorKillAmounts()==0,'empty configured list reverted to defaults')
    h.A:_OnNativeEvent('PLAYER_HONOR_POINT_CHANGED_IN_HPW',84)
    assert(h.F:GetPersonalHistoryProjection().totals.honorKills==nil)
    for i=1,16 do assert(f.Commands:AddHonorKillAmount(i)) end
    assert(f.Commands:AddHonorKillAmount(17)==false and #f:GetHonorKillAmounts()==16)
    local copy=f:GetHonorKillAmounts();copy[1]=999;assert(f:GetHonorKillAmounts()[1]==1,'public list mutated authority')
end)
print(string.format('KILL DIAGNOSTICS RESULT %d passed / %d failed (%s)',passed,failed,_VERSION))
assert(failed==0,'kill diagnostic regression failures: '..failed)

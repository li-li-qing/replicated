-- Run from replicatedsuite with Lua 5.1. Native boundaries are stubbed; business code is real.
local function Copy(t) if type(t)~='table' then return t end local out={} for k,v in pairs(t) do out[k]=Copy(v) end return out end
local now=1000
ReplicatedSuite={Generation=1,NowMs=function() return now end,SafeTraceback=tostring,Utils={DeepCopy=Copy},Services={},Features={},Data={}}
local S=ReplicatedSuite
S.Utils.GetServerTime=function() return {year=2026,month=10,day=5,hour=12,minute=30} end
S.Services.UnitIdentityV3={player={id='self-id',name='Self'},IsPlayerName=function(_,n) return n=='Self' end,RefreshPlayerIdentity=function(self) return self.player end}
S.Events={native={},Publish=function() end,SubscribeInternal=function() return true end,UnsubscribeInternal=function() end,SubscribeOptional=function(self,event) self.native[event]=true;return true end}
S.Scheduler={callbacks={},AddOneShot=function(self,id,delay,callback) self.callbacks[id]=callback;return true end,RemoveTask=function(self,id) self.callbacks[id]=nil end,SetTaskModule=function() end}
S.Services.CombatEventBusV3={Subscribe=function(self,owner,cb,opts) self.callback=cb;self.scope=opts.scope;return true end,Unsubscribe=function(self) self.callback=nil;return true end,GetHealth=function() return {coverageState='FULL'} end}
S.FeatureRuntime={RegisterImplementation=function(self,id,f) self[id]=f;return true end,GetSnapshot=function(self,id) return {enabled=self[id] and self[id].enabled==true} end}
S.Persistence={Scope={Account='Account',Character='Character'},Lifetime={Permanent='Permanent'},V3KeyPrefix='rs.v3.',stores={},disk={},loaded={}}
local P=S.Persistence
function P:GetStore(id) return self.stores[id] end
function P:RegisterV3Store(spec) self.stores[spec.id]=spec;return spec end
function P:IsStoreLoaded(id) return self.loaded[id]==true end
function P:LoadStore(id) local s=self.stores[id];s.apply(Copy(self.disk[id] or s.default()));self.loaded[id]=true;return self.disk[id] and true or 'empty' end
function P:MarkDirty(id) if self.fail then return false,'save_failure' end return true end
function P:MutateStore(id,fn) local before=Copy(self.stores[id].get());local ok,err=fn();if ok==false or self.fail then self.stores[id].apply(before);return false,err or 'save_failure' end return self:MarkDirty(id) end
dofile('core/rs_demand.lua')
dofile('services/rs_combat_analytics_v3.lua')
dofile('features/combat/analytics/rs_combat_metric_common.lua')
dofile('features/combat/analytics/rs_combat_analytics_metrics.lua')
dofile('features/combat/analytics/rs_combat_analytics_store.lua')
dofile('features/combat/analytics/rs_combat_personal_history.lua')
dofile('features/combat/analytics/rs_combat_analytics_feature.lua')
local A,F=S.Services.CombatAnalyticsV3,S.Features.CombatAnalytics
local function Relation(name) return name=='Self' and 'SELF' or (name=='Other' and 'FRIENDLY' or 'OPPONENT') end
S.Services.CombatRelationV3={AcquireConsumer=function() return true end,ReleaseConsumer=function() return true end,ApplyKind=function() return true end,GetHealth=function() return {} end,
    GetUnit=function(_,name) return {kind=name=='Npc' and 'NPC' or 'PLAYER',relation=Relation(name)} end,GetRelationAt=function(_,name) return Relation(name) end,
    RecordCombatFact=function(_,fact) return true,{sourceRelation=Relation(fact.sourceName),targetRelation=Relation(fact.targetName)} end}
dofile('features/combat/dps/rs_dps_store.lua')
dofile('features/combat/dps/rs_dps_feature.lua')
dofile('features/combat/dps/rs_dps_domain.lua')
local D=S.Features.DPS
local store=P.stores[F.StoreId]
local historical=store.migrate({selectedMetric='control',metricEnabled={control=true},selectedValues={kills='assists'}},1)
assert(historical.selectedMetric=='control' and historical.selectedValues.kills=='assists','canonical old preferences must survive')
P.disk[F.StoreId]=Copy(historical)
assert(D:Initialize());assert(D:Enable('basic_test'))
for _,id in ipairs({'encounter','performance','casts','control','songcraft','utility','aura','mechanics'}) do
    assert(A.activeMetrics[id]~=true,'advanced metric must stay suspended: '..id)
    local count=A.consumerCount
    assert(A:AcquireConsumer('stale_advanced',{metrics={id}},'stale')==false,'stale callers must not restart '..id)
    assert(A.consumerCount==count and not A:HasConsumer('stale_advanced'),'rejected lease must be atomic')
    assert(F.Commands:SetMetricEnabled(id,true)==false,'stale settings cannot re-enable '..id)
    assert(F.Commands:ClearMetric(id)==false,'stale clear command must not clear the basic kill/death session')
end
assert(A.activeMetrics.kills and A.activeMetrics.dps_core and A.activeMetrics.personal_history,'only the shared basic counters and history run')
assert(next(S.Events.native)==nil,'basic statistics must not subscribe to cast/aura events')
assert(#A:ListMetrics(false)==1 and A:ListMetrics(false)[1].id=='kills','public analytics list excludes suspended metrics')
assert(F:GetSelectedMetric()=='kills' and F:GetSelectedValueKey('kills')=='kills','old control/assist selection must resolve to supported view')
assert(F.Commands:SetSelectedValue('kills','assists')==false,'assist option must be rejected')
assert(P.stores[F.StoreId].get().selectedValues.kills=='assists','runtime fallback must not rewrite old preferences')
local function Fact(category,source,target,amount,kind)
    now=now+2000
    A:_DispatchFact({category=category,kind=kind or category,sourceName=source,targetName=target,sourceKind='PLAYER',targetKind=target=='Npc' and 'NPC' or 'PLAYER',amount=amount or 0,receivedAt=now,sequence=now,abilityId=11,abilityName='Hit'})
end
local function Rows() local p=D:GetCombatOverview();local out={} for _,r in ipairs(p.rows) do out[r.name]=r end return out,p end
Fact('damage','Self','Enemy',100);Fact('damage','Enemy','Self',40);Fact('heal','Self','Self',60)
Fact('death','Self','Enemy');Fact('death','Enemy','Self');Fact('damage','Self','Npc',30);Fact('death','Self','Npc')
local rows,p=Rows();local me=assert(rows.Self)
assert(#p.rows==1 and me.damage==130 and me.taken==40 and me.heal==60 and me.kills==1 and me.deaths==1,'NPC damage remains while only player kills count')
assert(me.assists==nil and me.dps==nil and me.npcKills==nil,'overview calculates only five statistics')
local before=A.metricDispatches
for i=1,10000 do A:_DispatchFact({category='damage',kind='damage',sourceName='Other'..i,targetName='Enemy',amount=100,receivedAt=now}) end
assert(A.metricDispatches==before,'self scope must discard crowds before dispatch')
assert(F.Commands:SetCollectionScope('all'))
-- More contributors than the former per-target assist cap: direct killer still counts, no contributor map.
for i=1,100 do Fact('damage','Contributor'..i,'CrowdVictim',1) end
local ledger=assert(A:GetMetric('kills').state.targets.CrowdVictim)
assert(ledger.sources==nil and ledger.sourceCount==nil and ledger.latest==nil,'do not allocate assist contributors or inferred last-damage source')
Fact('damage','Self','CrowdVictim',200);Fact('damage','Other','CrowdVictim',80);Fact('death','Other','CrowdVictim')
Fact('heal','Self','Other',50);Fact('damage','Other','Self',25);Fact('death','Other','NoDamage')
rows,p=Rows();me=assert(rows.Self)
assert(me.damage==200 and me.heal==50 and me.taken==25 and me.assists==nil,'all scope uses same five counters without assists')
assert(rows.Other.kills==2 and rows.NoDamage.deaths==1,'direct kill and death-only actor are retained')
assert((F.PersonalHistory.state.totals.assists or 0)==0,'no new personal assists in all scope')
before=A.metricDispatches
local received=A.factsReceived
Fact('aura','Self','Other',0,'aura_apply')
assert(A.metricDispatches==before,'aura facts dispatch no metrics')
assert(A.factsReceived==received,'unused categories stop before allocating the metric fact snapshot')
-- Keep legacy saved counters, but never increment them again.
local h=F.PersonalHistory
h.state.totals.assists=9;h.state.days['2026-10-05'].assists=9
local revision=h.revision
h:Record({assists=3,unattributedParticipations=4,unknownTargetKills=2})
assert(h.state.totals.assists==9 and h.revision==revision,'discard paused history increments before dirtying the store')
Fact('damage','Self','AnotherEnemy',1);Fact('death','Other','AnotherEnemy')
assert(h.state.totals.assists==9,'legacy assists preserved without accumulation')
local saved=Copy(P.stores[h.StoreId].get())
P.disk[h.StoreId]=saved;P.loaded[h.StoreId]=nil;P.stores[h.StoreId].apply(nil);assert(h:EnsureLoaded())
local t=F:GetPersonalHistoryProjection({fromDate='2026-10-05',toDate='2026-10-05'}).totals
assert(t.damage==331 and t.taken==65 and t.healing==110 and t.kills==1 and t.npcKills==nil and t.deaths==1 and t.assists==9,'five statistics and legacy data survive reload and range query')
P.fail=true
assert(F.Commands:SetCollectionScope('self')==false and A:GetCollectionScope()=='all' and F:GetCollectionScope()=='all','failed save rolls back scope')
P.fail=false
assert(D:Disable('basic_test'));assert(A.consumerCount==0 and S.Services.CombatEventBusV3.callback==nil,'disabled statistics release the shared bus')
assert(D.Commands:ClearOverview('basic_clear'));assert(#D:GetCombatOverview().rows==0,'clear resets five live counters')
assert(F:GetPersonalHistoryProjection().totals.damage==331,'clear leaves permanent personal history intact')
print('PASS five basic statistics / retired NPC kills with PVE damage preserved / suspended advanced metrics / no assist ledger / self crowd filter / history compatibility / lease rollback')

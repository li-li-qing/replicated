-- Replicated Suite · 击杀投影缓存专项测试
-- 从 replicatedsuite 目录以真实 Lua 5.1 运行；只替代 Native 与磁盘边界。
-- 可选 --compare-baseline <源码路径>：同输入递归对照旧源码的全部投影字段。
local passed, failed = 0, 0
local baselinePath = arg and arg[1] == '--compare-baseline' and arg[2] or nil
local function Test(name, callback)
    local ok, err = xpcall(callback, debug.traceback)
    if ok then passed = passed + 1; print('PASS kill projection ' .. name)
    else failed = failed + 1; print('FAIL kill projection ' .. name .. ': ' .. tostring(err)) end
end
local function Copy(value)
    if type(value) ~= 'table' then return value end
    local out = {}; for key, item in pairs(value) do out[key] = Copy(item) end; return out
end
local function Equal(left, right, path)
    path = path or 'projection'
    assert(type(left) == type(right), path .. ' type changed')
    if type(left) ~= 'table' then assert(left == right, path .. ' value changed'); return end
    for key, value in pairs(left) do Equal(value, right[key], path .. '.' .. tostring(key)) end
    for key in pairs(right) do assert(left[key] ~= nil, path .. '.' .. tostring(key) .. ' added') end
end
local function Boot(metricsPath)
    local h = { now = 1000, tasks = {}, rankBuilds = 0, mapBuilds = 0, writes = 0 }
    local S = { Generation = 71, Services = {}, Features = {}, Data = {}, SafeTraceback = debug.traceback,
        NowMs = function() return h.now end, Utils = { DeepCopy = Copy } }
    ReplicatedSuite = S; h.S = S
    S.Utils.GetServerTime = function() return { year=2026, month=10, day=25, hour=12, minute=30 } end
    S.Services.UnitIdentityV3 = { player={id='self-id',name='Self'}, IsPlayerName=function(_,name) return name=='Self' end,
        RefreshPlayerIdentity=function(self) return self.player end }
    S.Events = { Publish=function() end, SubscribeInternal=function() return true end, UnsubscribeInternal=function() end,
        SubscribeOptional=function() error('basic statistics must not subscribe extra Native events') end }
    S.Scheduler = { AddOneShot=function(_,id,delay,callback) h.tasks[id]={due=h.now+delay,callback=callback}; return true end,
        RemoveTask=function(_,id) h.tasks[id]=nil; return true end, SetTaskModule=function() end }
    S.Services.CombatEventBusV3 = { Subscribe=function(self,_,callback,options) self.callback=callback; self.scope=options.scope; return true end,
        Unsubscribe=function(self) self.callback=nil; return true end, GetHealth=function() return {coverageState='FULL'} end }
    S.FeatureRuntime = { RegisterImplementation=function(self,id,feature) self[id]=feature; return true end,
        GetSnapshot=function(self,id) return {enabled=self[id] and self[id].enabled==true} end }
    local P = { Scope={Account='Account',Character='Character'}, Lifetime={Permanent='Permanent'}, V3KeyPrefix='rs.v3.', stores={}, loaded={} }
    S.Persistence = P
    function P:GetStore(id) return self.stores[id] end
    function P:RegisterV3Store(spec) self.stores[spec.id]=spec; return spec end
    function P:IsStoreLoaded(id) return self.loaded[id]==true end
    function P:LoadStore(id) local spec=self.stores[id]; spec.apply(spec.default()); self.loaded[id]=true; return 'empty' end
    function P:MarkDirty() h.writes=h.writes+1; return true end
    function P:MutateStore(_,callback) local ok,err=callback(); if ok==false then return false,err end; return self:MarkDirty() end
    local function Relation(name) return name=='Self' and 'SELF' or (name=='Friend' and 'FRIENDLY' or 'OPPONENT') end
    S.Services.CombatRelationV3 = { AcquireConsumer=function() return true end, ReleaseConsumer=function() return true end,
        ApplyKind=function() return true end, GetHealth=function() return {} end,
        GetUnit=function(_,name) return {kind=name=='Npc' and 'NPC' or (name=='Unknown' and 'UNKNOWN' or 'PLAYER'),relation=Relation(name)} end,
        GetRelationAt=function(_,name) return Relation(name) end,
        RecordCombatFact=function(_,fact) return true,{sourceRelation=Relation(fact.sourceName),targetRelation=Relation(fact.targetName)} end }
    dofile('core/rs_demand.lua'); dofile('services/rs_combat_analytics_v3.lua')
    dofile('features/combat/analytics/rs_combat_metric_common.lua')
    dofile(metricsPath or 'features/combat/analytics/rs_combat_analytics_metrics.lua')
    dofile('features/combat/analytics/rs_combat_analytics_store.lua')
    dofile('features/combat/analytics/rs_combat_personal_history.lua')
    dofile('features/combat/analytics/rs_combat_analytics_feature.lua')
    dofile('features/combat/dps/rs_dps_store.lua'); dofile('features/combat/dps/rs_dps_feature.lua'); dofile('features/combat/dps/rs_dps_domain.lua')
    h.A, h.F, h.D = S.Services.CombatAnalyticsV3, S.Features.CombatAnalytics, S.Features.DPS
    h.metric = h.A:GetMetric('kills')
    assert(h.D:Initialize()); assert(h.D:Enable('kill_projection_test')); assert(h.F.Commands:SetCollectionScope('all'))
    local C = h.F.MetricCommon
    local rank, map = C.RankActors, C.MapRows
    function C:RankActors(...) h.rankBuilds=h.rankBuilds+1; return rank(self,...) end
    function C:MapRows(...) h.mapBuilds=h.mapBuilds+1; return map(self,...) end
    function h:Fact(fact)
        self.now=self.now+2000; fact=Copy(fact); fact.receivedAt=self.now; fact.sequence=self.now
        fact.kind=fact.kind or fact.category
        return self.A:_DispatchFact(fact)
    end
    function h:Death(killer,victim,id,name)
        self.now=self.now+7000 -- 独立死亡超过原8秒合并窗；迟到补证测试直接用 Fact 保留原间隔。
        return self:Fact({category='death',sourceName=killer,targetName=victim,abilityId=id,abilityName=name})
    end
    function h:Damage() return self:Fact({category='damage',sourceName='Self',targetName='Enemy',sourceKind='PLAYER',targetKind='PLAYER',amount=100,abilityId=11,abilityName='Hit'}) end
    function h:Advance(ms)
        self.now=self.now+ms; local pending=self.tasks; self.tasks={}
        for id,row in pairs(pending) do if row.due<=self.now then row.callback() else self.tasks[id]=row end end
    end
    function h:Rank(options) return assert(self.A:GetMetricProjection('kills',options or {})) end
    function h:Skill(actorKey,actorName) return self:Rank({actorKey=actorKey,actorName=actorName}) end
    return h
end
local function Seed(h)
    h:Death('Alpha','Zed',101,'Hit'); h:Death('Beta','Zed',101,'Hit'); h:Death('Alpha','Beta',102,'Hit')
end
local function Names(rows) local out={}; for _,row in ipairs(rows) do out[#out+1]=row.name end; return table.concat(out,',') end

Test('warm ranking ignores damage updates and reuses different limits', function()
    local h=Boot(); Seed(h); h:Damage()
    h.D:GetCombatOverview(); local builds=h.rankBuilds; local revision=h.metric.state.revision
    for i=1,8 do h:Damage(); h.D:GetCombatOverview() end
    assert(h.metric.state.revision==revision and h.rankBuilds==builds,'damage-only overview rebuilt unchanged kill ranking')
    local a=h:Rank({valueKey='kills',includeZero=true,limit=1})
    local b=h:Rank({valueKey='kills',includeZero=true,limit=2.75})
    assert(#a.rows==1 and #b.rows==2 and Names(b.rows)=='Alpha,Beta','limit selection changed')
    assert(h.rankBuilds==builds,'different limit rebuilt the same sorted candidates')
end)
Test('warm skill projection keeps every returned layer detached', function()
    local h=Boot(); h:Death('Self','Enemy',101,'Hit')
    local first=h:Skill('name:self','Self'); h:Skill('name:Self') -- 两次读取后准入，第三次起只重建公开行。
    local builds=h.mapBuilds
    for i=1,8 do h:Damage(); local fresh=h:Skill('name:Self'); assert(fresh~=first and fresh.skills~=first.skills and fresh.skills[1]~=first.skills[1] and fresh.skills[1].targets~=first.skills[1].targets and fresh.skills[1].targets[1]~=first.skills[1].targets[1]) end
    assert(h.mapBuilds==builds,'unchanged skill targets were rebuilt')
    first.actor.name='mutated'; first.skills[1].kills=-1; first.skills[1].targets[1].name='mutated'; first.skills[2]={kills=99}
    local fresh=h:Skill('name:Self')
    assert(fresh.actor.name=='Self' and #fresh.skills==1 and fresh.skills[1].kills==1 and fresh.skills[1].targets[1].name=='Enemy','caller modified private skill cache')
end)
Test('skill ordering admits only the second read in the same actor revision', function()
    local h=Boot(); h:Death('Self','Enemy',101,'Hit')
    local first=h:Skill('name:Self'); assert(h.mapBuilds==1)
    first.skills[1].targets[1].name='changed before admission'; first.skills[1].kills=99
    local second=h:Skill('name:self','Self')
    assert(h.mapBuilds==2 and second.skills[1].kills==1 and second.skills[1].targets[1].name=='Enemy','second read skipped admission build or retained first public rows')
    h:Skill('name:Self'); assert(h.mapBuilds==2,'third read rebuilt admitted ordering')
    h:Death('Other','Zed',102,'Other'); h:Skill('name:Self'); assert(h.mapBuilds==3)
    h:Death('Other','Zed',102,'Other'); h:Skill('name:Self'); assert(h.mapBuilds==4)
    h:Skill('name:Self'); assert(h.mapBuilds==5,'another actor death failed to restart admission')
    assert(h:Skill('name:Self').skills[1].kills==1 and h.mapBuilds==5)
end)
Test('kills deaths includeZero and scalar row isolation', function()
    local h=Boot(); Seed(h)
    assert(Names(h:Rank({valueKey='kills'}).rows)=='Alpha,Beta')
    assert(Names(h:Rank({valueKey='kills',includeZero=true}).rows)=='Alpha,Beta,Zed')
    assert(Names(h:Rank({valueKey='deaths'}).rows)=='Zed,Beta')
    assert(Names(h:Rank({valueKey='deaths',includeZero=true}).rows)=='Zed,Beta,Alpha')
    assert(h.rankBuilds==4,'four ranking combinations should build once each')
    local first=h:Rank({valueKey='kills',includeZero=true}); first.rows[1].kills=-5; first.rows[1].name='changed'; first.rows[4]={}
    local fresh=h:Rank({valueKey='kills',includeZero=true})
    assert(first~=fresh and first.rows~=fresh.rows and first.rows[1]~=fresh.rows[1] and fresh.rows[1].name=='Alpha' and fresh.rows[1].kills==2 and #fresh.rows==3)
    assert(h.rankBuilds==4,'public mutation forced a rebuild or cache was not reused')
end)
Test('revision zero empty boards and generation are fresh', function()
    local h=Boot(); h.metric.state.revision=0
    assert(#h:Rank().rows==0 and #h:Rank().rows==0 and h.rankBuilds==1,'empty revision-zero ranking was rebuilt')
    h:Death('Alpha','Zed',101,'Hit'); assert(h:Rank().rows[1].kills==1 and h.rankBuilds==2)
    h.S.Generation=h.S.Generation+1
    assert(h:Rank().rows[1].kills==1 and h.rankBuilds==3,'new generation reused prior cache')
end)
Test('exact large revisions never collide through string tokens', function()
    local h=Boot(); Seed(h); h.metric.state.revision=100000000000001
    assert(h:Rank().rows[1].kills==2)
    h.metric.state.actors['name:Alpha'].kills=7; h.metric.state.revision=h.metric.state.revision+1
    assert(h:Rank().rows[1].kills==7 and h.rankBuilds==2,'distinct exact revisions shared cached rows')
end)
Test('new confirmed death refreshes existing cached skills and old snapshots stay fixed', function()
    local h=Boot(); h:Death('Self','Enemy',101,'Hit'); local old=h:Skill('name:Self'); h:Skill('name:Self'); h:Rank()
    h:Death('Self','Another',101,'Hit')
    local fresh=h:Skill('name:Self')
    assert(fresh.actor.kills==2 and fresh.skills[1].kills==2 and #fresh.skills[1].targets==2)
    assert(fresh.skills[1].targets[1].name=='Another' and h:Rank().rows[1].kills==2)
    assert(old.actor.kills==1 and old.skills[1].kills==1 and #old.skills[1].targets==1,'old public snapshot followed live state')
end)
Test('same revision replacement state and generation both invalidate skill ordering', function()
    local h=Boot(); h:Death('Self','Enemy',101,'Hit'); h:Rank(); h:Skill('name:Self'); h:Skill('name:Self')
    local replacement=Copy(h.metric.state); replacement.actors['name:Self'].kills=7; replacement.actors['name:Self'].skillKills['id:101'].kills=7
    h.metric.state=replacement
    assert(h:Rank().rows[1].kills==7 and h:Skill('name:Self').skills[1].kills==7,'same revision in a new state reused old data')
    h:Skill('name:Self')
    local before=h.mapBuilds; h.S.Generation=h.S.Generation+1
    assert(h:Skill('name:Self').skills[1].kills==7 and h.mapBuilds==before+1,'new generation reused skill cache')
end)
Test('skill fallback key resolves actor before caching and actor slots evict', function()
    local h=Boot()
    for _,name in ipairs({'Alpha','Beta','Gamma','Delta','Epsilon'}) do h:Death(name,'Zed',101,'Hit') end
    h:Skill('name:alpha','Alpha'); h:Skill('name:Alpha'); h:Skill('name:alpha','Alpha'); assert(h.mapBuilds==2,'resolved actor aliases did not share the admitted entry')
    h:Skill('missing','Beta'); h:Skill('missing','Beta'); assert(h.mapBuilds==4,'actorName fallback reused a different actor')
    h:Skill('name:Gamma'); h:Skill('name:Delta'); h:Skill('name:Epsilon')
    local before=h.mapBuilds; h:Skill('name:Alpha'); assert(h.mapBuilds==before+1,'fifth actor did not evict the oldest bounded slot')
    local missing=h:Skill('missing','Unknown'); assert(missing.actor==nil and #missing.skills==0)
end)
Test('dynamic metric preference and service wrapper stay current', function()
    local h=Boot(); h:Death('Self','Enemy',101,'Hit'); local first=h:Skill('name:Self'); h:Skill('name:Self'); h:Rank()
    local rank,map=h.rankBuilds,h.mapBuilds
    assert(h.F.Commands:SetMetricEnabled('kills',false)); h.A.projectionRevision=h.A.projectionRevision+1
    local paused=h:Skill('name:Self'); local ranks=h:Rank()
    assert(paused.statsAvailable==false and ranks.statsAvailable==false and paused.revision==h.A.projectionRevision and first.statsAvailable==true,'cached flags or wrapper became stale')
    assert(h.mapBuilds==map and h.rankBuilds==rank,'preference-only change rebuilt sorted data')
    assert(h.F.Commands:SetMetricEnabled('kills',true)); assert(h:Skill('name:Self').statsAvailable==true)
end)
Test('inactive reset releases caches while preserving counts', function()
    local h=Boot(); h:Death('Self','Enemy',101,'Hit'); h:Rank(); h:Skill('name:Self'); h:Skill('name:Self')
    local state=h.metric.state; local rank,map=h.rankBuilds,h.mapBuilds
    assert(h.D:Disable('test_stop')); assert(h.metric.state==state,'inactive reset must preserve current-period counters')
    assert(h:Rank().rows[1].kills==1 and h:Skill('name:Self').skills[1].kills==1)
    assert(h.rankBuilds==rank+1 and h.mapBuilds==map+1,'inactive reset retained private caches')
    assert(h:Rank().active==false)
end)
Test('clear and collection scope release old state snapshots', function()
    local h=Boot(); h:Death('Self','Enemy',101,'Hit'); h:Rank(); h:Skill('name:Self'); local state=h.metric.state
    assert(h.F.Commands:ClearMetric('kills')); assert(h.metric.state~=state and #h:Rank().rows==0 and #h:Skill('name:Self').skills==0)
    h:Death('Self','Another',102,'Other'); assert(h:Skill('name:Self').skills[1].abilityId==102)
    assert(h.F.Commands:SetCollectionScope('self')); assert(#h:Rank().rows==0 and #h:Skill('name:Self').skills==0)
end)
Test('late explicit attribution immediately invalidates warmed death snapshot', function()
    local h=Boot(); h:Damage(); h:Fact({category='death',kind='death_notice',targetName='Enemy'}); h:Advance(1600)
    assert(#h:Skill('name:Self').skills==0); local before=h:Rank({includeZero=true})
    assert(#before.rows==1 and before.rows[1].deaths==1 and before.rows[1].kills==nil)
    local oldRevision=h.metric.state.revision
    h:Fact({category='death',kind='kill_notice',sourceName='Self',targetName='Enemy',rawNotice2=1})
    local fresh=h:Skill('name:self','Self')
    assert(h.metric.state.revision>oldRevision and fresh.actor.kills==1 and fresh.skills[1].name=='技能未确认' and fresh.skills[1].abilityId==nil,'late explicit attribution stayed hidden or borrowed damage skill')
    assert(fresh.skills[1].targets[1].name=='Enemy' and h:Rank().rows[1].kills==1)
    h:Fact({category='death',kind='kill_notice',sourceName='Self',targetName='Enemy',rawNotice2=1})
    assert(h:Skill('name:Self').actor.kills==1,'duplicate notice created another kill')
end)
Test('damage or unknown victims never fabricate skill kills', function()
    local h=Boot(); h:Damage(); h:Fact({category='death',kind='death_notice',targetName='Enemy'}); h:Advance(1600)
    assert(#h:Skill('name:Self').skills==0)
    h:Fact({category='death',sourceName='Self',targetName='Unknown',targetKind='UNKNOWN'})
    h:Death('Self','Npc',101,'Hit'); assert(#h:Skill('name:Self').skills==0 and #h:Rank().rows==0)
end)

if baselinePath then
    Test('cold snapshots avoid duplicate row allocation', function()
        local old,new=Boot(baselinePath),Boot()
        for _,h in ipairs({old,new}) do
            for i=1,100 do h:Death('P'..i,'P'..(i+100),11,'Hit') end
            for i=1,128 do h:Death('Self','P'..i,(i-1)%64+1,'Skill'..tostring((i-1)%64+1)) end
        end
        local function Allocated(callback)
            collectgarbage('collect'); collectgarbage('stop'); local before=collectgarbage('count')
            local result=callback(); local allocated=collectgarbage('count')-before
            collectgarbage('restart'); collectgarbage('collect'); assert(type(result)=='table'); return allocated
        end
        local oldRank=Allocated(function() return old:Rank({includeZero=true,limit=512}) end)
        local newRank=Allocated(function() return new:Rank({includeZero=true,limit=512}) end)
        local oldSkill=Allocated(function() return old:Skill('name:Self') end)
        local newSkill=Allocated(function() return new:Skill('name:Self') end)
        assert(newRank<=oldRank*1.35,'cold ranking allocated a second row tree')
        assert(newSkill<=oldSkill*1.03+1,'first cold skill read allocated a premature ordering index')
    end)
    Test('full baseline field equivalence across inputs and late upgrade', function()
        local old,new=Boot(baselinePath),Boot()
        local options={{},{valueKey='kills'},{valueKey='deaths'},{valueKey='bad'},
            {valueKey='kills',includeZero=true},{valueKey='deaths',includeZero=true},
            {limit=1},{limit=2},{limit=2.75},{limit=0},{limit=-1},{limit='invalid'},{limit=700},
            {actorKey='name:Alpha'},{actorKey='name:alpha',actorName='Alpha'},
            {actorKey='missing',actorName='Beta'},{actorKey='missing',actorName='Unknown'},
            {actorKey='name:Self'},{actorKey='name:self',actorName='Self'}}
        local function Compare(label)
            for i,opt in ipairs(options) do Equal(old:Rank(Copy(opt)),new:Rank(Copy(opt)),label..':'..i) end
        end
        Compare('empty')
        for _,h in ipairs({old,new}) do h:Death('Alpha','Zed',101,'Hit'); h:Death('Beta','Zed',102,'Hit') end
        Compare('ties'); for _,h in ipairs({old,new}) do h:Death('Alpha','Beta',101,'Hit'); h:Damage() end
        Compare('damage')
        for _,h in ipairs({old,new}) do h:Fact({category='death',kind='death_notice',targetName='Enemy'}); h:Advance(1600) end
        Compare('death without killer')
        for _,h in ipairs({old,new}) do h:Fact({category='death',kind='kill_notice',sourceName='Self',targetName='Enemy',rawNotice2=1}) end
        Compare('late explicit upgrade')
        for _,h in ipairs({old,new}) do assert(h.F.Commands:SetMetricEnabled('kills',false)) end
        Compare('preference off')
        for _,h in ipairs({old,new}) do assert(h.D:Disable('test_stop')) end
        Compare('inactive reset')
        for _,h in ipairs({old,new}) do assert(h.F.Commands:ClearMetric('kills')) end
        Compare('explicit clear')
    end)
end
print(string.format('kill projection summary: %d passed, %d failed',passed,failed))
if failed>0 then os.exit(1) end

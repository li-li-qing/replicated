------------------------------------------------------------------------
-- Replicated Suite V3 - Combat Analytics Built-in Metrics
-- Independent bounded plugins. Direct/observed/inferred evidence stays explicit.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local Analytics = S.Services and S.Services.CombatAnalyticsV3 or nil
local Feature = S.Features and S.Features.CombatAnalytics or nil
local C = Feature and Feature.MetricCommon or nil
if type(Analytics) ~= "table" or type(C) ~= "table" then return end

local AbilityCatalog = S.Data and S.Data.CombatAbilityCatalog or nil
local MechanicCatalog = S.Data and S.Data.CombatMechanicCatalog or nil
local MAX_ACTORS, MAX_DETAIL = 512, 128
local function At(fact) return math.max(0, tonumber(fact and fact.receivedAt) or C:NowMs()) end
local function AbilityId(fact) return tonumber(fact and (fact.rawAbilityId or fact.abilityId)) end
local function AbilityName(fact)
    local name = C:Trim(fact and fact.abilityName)
    if name ~= "" then return name end
    local row = type(AbilityCatalog)=="table" and AbilityCatalog:GetSkill(AbilityId(fact)) or nil
    if row then return tostring(row.name or "") end
    return AbilityId(fact) and ("技能#"..tostring(AbilityId(fact))) or "未知技能"
end
local function SourceActor(state,fact) return C:EnsureActor(state,fact and fact.sourceName,fact and fact.sourceId) end
local function TargetName(fact)
    if type(fact) ~= "table" then return "" end
    local target = C:Trim(fact.targetName)
    if target ~= "" then return target end
    return C:Trim(fact.subjectName)
end
local function TargetActor(state,fact) return C:EnsureActor(state,TargetName(fact),fact and fact.targetId) end
local function AddDetail(actor,bucket,key,amount)
    if actor==nil then return false end
    actor.details=actor.details or {}; actor.details[bucket]=actor.details[bucket] or {}
    local countKey=bucket.."Count"; actor[countKey]=tonumber(actor[countKey]) or 0
    return C:AddMapValue(actor.details[bucket],key,amount,MAX_DETAIL,actor,countKey,"detailOverflow")
end
local function Rank(metric,key,fields,limit,options)
    options=type(options)=="table" and options or {}; options.copyFields=fields or options.copyFields
    return C:RankActors(metric.state,key,limit or 100,options)
end
local function ResetActor(metric) metric.state=C:NewActorState(MAX_ACTORS); return true end

------------------------------------------------------------------------
-- 1. Encounter / history / bounded timeline
------------------------------------------------------------------------
do
    local metric={state={history=C:NewBoundedQueue(20),current=nil,nextId=0,closeTask="v3_combat_encounter_idle"}}
    local function IsAnchor(fact) local c=tostring(fact and fact.category or ""); return c=="damage" or c=="heal" or c=="death" end
    local function Summary(cur,endedAt,reason)
        if cur==nil then return nil end
        local finish=tonumber(endedAt) or tonumber(cur.combatLastAt) or tonumber(cur.startedAt) or 0
        return {id=cur.id,startedAt=cur.startedAt,endedAt=finish,durationMs=math.max(0,finish-(tonumber(cur.startedAt) or finish)),closeReason=reason,
            damage=tonumber(cur.damage) or 0,healing=tonumber(cur.healing) or 0,deaths=tonumber(cur.deaths) or 0,auraEvents=tonumber(cur.auraEvents) or 0,
            actorCount=tonumber(cur.actorCount) or 0,actorOverflow=tonumber(cur.actorOverflow) or 0}
    end
    local function Close(reason)
        local cur=metric.state.current; if cur==nil then return false end
        C:QueuePush(metric.state.history,Summary(cur,cur.combatLastAt,tostring(reason or "idle"))); metric.state.current=nil; return true
    end
    local function ScheduleClose()
        local scheduler=S.Scheduler; if type(scheduler)~="table" or type(scheduler.AddOneShot)~="function" then return false end
        scheduler:RemoveTask(metric.state.closeTask); if type(scheduler.SetTaskModule)=="function" then scheduler:SetTaskModule(metric.state.closeTask,"combat_analytics",true) end
        return scheduler:AddOneShot(metric.state.closeTask,8000,function()
            local cur=metric.state.current
            if cur~=nil and C:NowMs()-(tonumber(cur.combatLastAt) or 0)>=7900 then Close("idle_8s"); Analytics:NotifyMetricChanged("encounter_closed") end
            return true
        end,metric,"P3",1)
    end
    Analytics:RegisterMetric({id="encounter",title="战斗历史",category="timeline",order=10,factCategories={"damage","heal","death","aura"},state=metric.state,
        description="当前战斗、最近20场摘要和当前有界时间线；Aura 不单独开启或延长战斗。",
        OnFact=function(self,fact)
            local anchor=IsAnchor(fact); if anchor~=true and fact.category~="aura" then return false end
            local now=At(fact); local cur=self.state.current
            -- Scheduler starvation or a long frame must not merge two encounters.
            -- The event itself is the final authority for the idle-gap boundary; the
            -- one-shot task is only a timely close helper.
            if cur~=nil and anchor==true and now-(tonumber(cur.combatLastAt) or now)>=8000 then
                Close("gap_8s")
                cur=nil
            end
            if cur==nil then
                if anchor~=true then return false end
                self.state.nextId=(tonumber(self.state.nextId) or 0)+1
                cur={id=self.state.nextId,startedAt=now,lastAt=now,combatLastAt=now,damage=0,healing=0,deaths=0,auraEvents=0,
                    actors={},actorCount=0,actorOverflow=0,deathSeen={},deathSeenCount=0,timeline=C:NewBoundedQueue(512)}; self.state.current=cur
            end
            cur.lastAt=math.max(tonumber(cur.lastAt) or now,now); if anchor then cur.combatLastAt=math.max(tonumber(cur.combatLastAt) or now,now) end
            if fact.category=="damage" then cur.damage=cur.damage+(tonumber(fact.amount) or 0)
            elseif fact.category=="heal" then cur.healing=cur.healing+(tonumber(fact.amount) or 0)
            elseif fact.category=="death" then
                local victim=C:Trim((fact.targetName and fact.targetName~="" and fact.targetName) or fact.subjectName); local last=tonumber(cur.deathSeen[victim]) or -999999
                if victim=="" or now-last>=1200 then cur.deaths=cur.deaths+1; if victim~="" and cur.deathSeenCount<512 then if cur.deathSeen[victim]==nil then cur.deathSeenCount=cur.deathSeenCount+1 end; cur.deathSeen[victim]=now end end
            else cur.auraEvents=cur.auraEvents+1 end
            for _,name in ipairs({C:Trim(fact.sourceName),C:Trim(fact.targetName),C:Trim(fact.subjectName)}) do if name~="" and cur.actors[name]~=true then if cur.actorCount<512 then cur.actors[name]=true;cur.actorCount=cur.actorCount+1 else cur.actorOverflow=cur.actorOverflow+1 end end end
            C:QueuePush(cur.timeline,{at=now,kind=tostring(fact.kind or ""),source=C:Trim(fact.sourceName),target=C:Trim((fact.targetName and fact.targetName~="" and fact.targetName) or fact.subjectName),ability=AbilityName(fact),amount=tonumber(fact.amount) or 0,confidence="direct_combat_fact"})
            if anchor then ScheduleClose() end
            return true
        end,
        GetProjection=function(self)
            local current=self.state.current; local summary=current and Summary(current,C:NowMs(),nil) or nil
            if summary and current then summary.combatDurationMs=math.max(0,(tonumber(current.combatLastAt) or 0)-(tonumber(current.startedAt) or 0));summary.timelineCount=current.timeline.count;summary.timelineEvicted=current.timeline.evicted end
            return {current=summary,history=C:QueueToArray(self.state.history,true,20),timeline=current and C:QueueToArray(current.timeline,false,512) or {},coverage="DIRECT_COMBAT_FACTS_ANCHORED_BY_DAMAGE_HEAL_DEATH"}
        end,
        Reset=function(self) if S.Scheduler then S.Scheduler:RemoveTask(self.state.closeTask) end; self.state={history=C:NewBoundedQueue(20),current=nil,nextId=0,closeTask="v3_combat_encounter_idle"};metric.state=self.state;return true end,
        GetHealth=function(self) return {current=self.state.current~=nil,history=self.state.history.count,timeline=self.state.current and self.state.current.timeline.count or 0,historyEvicted=self.state.history.evicted} end})
end

------------------------------------------------------------------------
-- 2. Kills / inferred assists / deaths
------------------------------------------------------------------------
do
    local metric={state=C:NewActorState(MAX_ACTORS)}
    local function Init(state) state.targets={};state.targetOrder=C:NewBoundedQueue(512);state.targetCount=0;state.deathOrder=C:NewBoundedQueue(512);state.lastDeath={} end
    Init(metric.state)
    local function EnsureTarget(state,name)
        name=C:Trim(name); if name=="" then return nil end
        local row=state.targets[name]; if row then return row end
        if state.targetCount>=512 then
            local victim
            C:QueueEach(state.targetOrder,function(candidate) if victim==nil and candidate.active==true then victim=candidate end end)
            if victim then state.targets[victim.name]=nil;victim.active=false;state.targetCount=state.targetCount-1 end
        end
        row={name=name,active=true,sources={},sourceCount=0,sourceOverflow=0};state.targets[name]=row;state.targetCount=state.targetCount+1;C:QueuePush(state.targetOrder,row);return row
    end
    local function RecordDamage(state,fact)
        if fact.category~="damage" or (tonumber(fact.amount) or 0)<=0 then return false end
        local target=EnsureTarget(state,fact.targetName);local source=C:Trim(fact.sourceName);if target==nil or source=="" then return false end
        local row=target.sources[source]
        if row==nil then if target.sourceCount>=64 then target.sourceOverflow=target.sourceOverflow+1;return false end;row={};target.sources[source]=row;target.sourceCount=target.sourceCount+1 end
        row.at=At(fact);row.sourceName=source;row.sourceId=fact.sourceId;row.ability=AbilityName(fact);row.amount=tonumber(fact.amount) or 0;return false
    end
    local function CreditDeath(state,victimName,victimId,directKiller,directAbility,now,confidence)
        victimName=C:Trim(victimName);if victimName=="" then return false end
        local last=tonumber(state.lastDeath[victimName]) or -999999;if now-last<1200 then return false end
        state.lastDeath[victimName]=now;local _,evicted=C:QueuePush(state.deathOrder,{victim=victimName,at=now});if evicted and state.lastDeath[evicted.victim]==evicted.at then state.lastDeath[evicted.victim]=nil end
        local victim=C:EnsureActor(state,victimName,victimId);if victim then C:AddCounter(victim,"deaths",1);C:Touch(victim,now) end
        local ledger=state.targets[victimName];local latest;local eligible={}
        if ledger then for sourceName,row in pairs(ledger.sources) do if now-(tonumber(row.at) or 0)<=10000 then eligible[sourceName]=row;if latest==nil or row.at>latest.at then latest=row end end end end
        local killer=C:Trim(directKiller);local ability=C:Trim(directAbility)
        if killer=="" and latest and now-(tonumber(latest.at) or 0)<=8000 then killer,ability,confidence=latest.sourceName,latest.ability,"inferred_recent_damage" end
        if killer~="" then
            local actor=C:EnsureActor(state,killer,latest and latest.sourceId or nil);if actor then C:AddCounter(actor,"kills",1);C:Touch(actor,now);actor.lastKillConfidence=confidence or "direct_death_source";AddDetail(actor,"killTargets",victimName,1);AddDetail(actor,"killAbilities",ability~="" and ability or "未知技能",1) end
            for sourceName in pairs(eligible) do if sourceName~=killer then local assist=C:EnsureActor(state,sourceName,nil);if assist then C:AddCounter(assist,"assists",1);C:Touch(assist,now);AddDetail(assist,"assistTargets",victimName,1) end end end
        end
        state.targets[victimName]=nil;if ledger and ledger.active then ledger.active=false;state.targetCount=math.max(0,state.targetCount-1) end
        return true
    end
    Analytics:RegisterMetric({id="kills",title="击杀 / 助攻 / 死亡",category="combat",order=20,factCategories={"damage","death"},state=metric.state,
        description="死亡为直接事实；缺少直接击杀源时，以最近8秒伤害推导最后一击，助攻为最近10秒参与伤害推导。",
        OnFact=function(self,fact) if fact.category=="damage" then return RecordDamage(self.state,fact) end;local now=At(fact);if fact.kind=="death_notice" then return CreditDeath(self.state,fact.subjectName,nil,nil,nil,now,"death_notice") end;return CreditDeath(self.state,(fact.targetName and fact.targetName~="" and fact.targetName) or fact.subjectName,fact.targetId,fact.sourceName,AbilityName(fact),now,"direct_death_source") end,
        GetProjection=function(self,opt) local key=tostring(opt and opt.valueKey or "kills");if key~="kills" and key~="assists" and key~="deaths" then key="kills" end;return {valueKey=key,rows=Rank(self,key,{"kills","assists","deaths","lastKillConfidence"},100),coverage="DIRECT_DEATH_PLUS_BOUNDED_DAMAGE_INFERENCE"} end,
        Reset=function(self) self.state=C:NewActorState(MAX_ACTORS);Init(self.state);metric.state=self.state;return true end,
        GetHealth=function(self) return {actors=self.state.actorCount,recentTargets=self.state.targetCount,actorOverflow=self.state.actorOverflow} end})
end

------------------------------------------------------------------------
-- 3. Skill activity / exact SELF native casts / opener
------------------------------------------------------------------------
do
    local metric={state=C:NewActorState(MAX_ACTORS)}
    local function Activity(self,fact,exact)
        local id=AbilityId(fact);if id==nil then return false end;local skill=type(AbilityCatalog)=="table" and AbilityCatalog:GetSkill(id) or nil;if skill==nil then return false end
        local actor=C:EnsureActor(self.state,fact.sourceName,fact.sourceId);if actor==nil then return false end;local now=At(fact)
        actor.castLast=actor.castLast or {};if exact~=true and now-(tonumber(actor.castLast[id]) or -999999)<250 then return false end;actor.castLast[id]=now;C:Touch(actor,now)
        C:AddCounter(actor,exact and "exactCasts" or "skillActivities",1);AddDetail(actor,exact and "exactSkills" or "skills",skill.name,1)
        actor.opener=actor.opener or C:NewBoundedQueue(12)
        local openerConfidence=exact and "self_native_catalog_match" or "inferred_combat_activity"
        local lastOpener=C:QueueLast(actor.opener)
        if lastOpener and lastOpener.skill==skill.name and now-(tonumber(lastOpener.at) or -999999)<250 then
            -- Native START may arrive just after the inferred combat activity for
            -- the same cast. Upgrade the evidence instead of duplicating opener.
            if exact==true then lastOpener.confidence=openerConfidence;lastOpener.exact=true end
        elseif actor.opener.count<12 then
            C:QueuePush(actor.opener,{at=now,skill=skill.name,confidence=openerConfidence,exact=exact==true})
        end
        return true
    end
    Analytics:RegisterMetric({id="casts",title="技能释放 / 起手",category="combat",order=30,factCategories={"damage","heal","other"},nativeEvents={"SPELLCAST_START"},state=metric.state,
        description="团队技能次数由战斗活动保守推导；本机 SPELLCAST_START+静态技能ID命中提供精确施法证据。",
        OnFact=function(self,fact) return Activity(self,fact,false) end,
        OnNativeFact=function(self,fact) if fact.kind~="cast_start" or fact.abilityId==nil then return false end;return Activity(self,fact,true) end,
        GetProjection=function(self,opt) local key=tostring(opt and opt.valueKey or "skillActivities");if key~="skillActivities" and key~="exactCasts" then key="skillActivities" end;local rows=Rank(self,key,{"skillActivities","exactCasts"},100);for _,row in ipairs(rows) do local actor=self.state.actors[row.key];row.opener=actor and C:QueueToArray(actor.opener,false,12) or {} end;return {valueKey=key,rows=rows,nativeCoverage=Analytics.nativeCoverage,coverage="TEAM_ACTIVITY_INFERRED_SELF_NATIVE_EXACT_WHEN_AVAILABLE"} end,
        Reset=function(self) return ResetActor(self) end,GetHealth=function(self) return {actors=self.state.actorCount} end})
end

------------------------------------------------------------------------
-- 4. Burst / highest hit / survival observation
------------------------------------------------------------------------
do
    local metric={state=C:NewActorState(MAX_ACTORS)}
    metric.state.deathOrder=C:NewBoundedQueue(512)
    metric.state.lastDeath={}
    local function ResetState(self)
        self.state=C:NewActorState(MAX_ACTORS)
        self.state.deathOrder=C:NewBoundedQueue(512)
        self.state.lastDeath={}
        metric.state=self.state
        return true
    end
    local function AddDamage(self,fact)
        if fact.category~="damage" or (tonumber(fact.amount) or 0)<=0 then return false end
        local actor=SourceActor(self.state,fact);if actor==nil then return false end;local now=At(fact);local amount=tonumber(fact.amount) or 0;C:Touch(actor,now);C:AddCounter(actor,"damage",amount);C:AddCounter(actor,"hits",1);actor.highestHit=math.max(tonumber(actor.highestHit) or 0,amount)
        actor.burstBuckets=actor.burstBuckets or C:NewBoundedQueue(64);actor.burstSum=tonumber(actor.burstSum) or 0;C:QueuePruneBefore(actor.burstBuckets,now-5000,function(row) actor.burstSum=math.max(0,actor.burstSum-(tonumber(row.amount) or 0)) end)
        local bucketAt=math.floor(now/100)*100;local last=C:QueueLast(actor.burstBuckets)
        if last and last.at==bucketAt then last.amount=last.amount+amount else local _,evicted=C:QueuePush(actor.burstBuckets,{at=bucketAt,amount=amount});if evicted then actor.burstSum=math.max(0,actor.burstSum-(tonumber(evicted.amount) or 0)) end end
        actor.burstSum=actor.burstSum+amount;actor.peak5sDamage=math.max(tonumber(actor.peak5sDamage) or 0,actor.burstSum);actor.peak5sDps=math.floor((actor.peak5sDamage/5)+0.5);return true
    end
    Analytics:RegisterMetric({id="performance",title="爆发 / 生存",category="combat",order=40,factCategories={"damage","death"},state=metric.state,
        description="最高单击与5秒滚动爆发使用100ms有界桶；死亡/观察跨度用于生存分析。",
        OnFact=function(self,fact)
            if fact.category=="damage" then return AddDamage(self,fact) end
            local victimName=TargetName(fact);if victimName=="" then return false end
            local now=At(fact);local last=tonumber(self.state.lastDeath[victimName]) or -999999;if now-last<1200 then return false end
            self.state.lastDeath[victimName]=now;local _,evicted=C:QueuePush(self.state.deathOrder,{victim=victimName,at=now});if evicted and self.state.lastDeath[evicted.victim]==evicted.at then self.state.lastDeath[evicted.victim]=nil end
            local victim=C:EnsureActor(self.state,victimName,fact.targetId);if victim then C:Touch(victim,now);C:AddCounter(victim,"deaths",1);return true end;return false
        end,
        GetProjection=function(self,opt) local key=tostring(opt and opt.valueKey or "peak5sDps");local allowed={peak5sDps=true,peak5sDamage=true,highestHit=true,damage=true,deaths=true};if not allowed[key] then key="peak5sDps" end;return {valueKey=key,rows=Rank(self,key,{"peak5sDps","peak5sDamage","highestHit","damage","hits","deaths"},100,{valueFn=function(actor,k) if k=="deaths" then return tonumber(actor.deaths) or 0 end;return tonumber(actor[k]) or 0 end}),coverage="DIRECT_DAMAGE_BOUNDED_5S_WINDOW"} end,
        Reset=ResetState,GetHealth=function(self) return {actors=self.state.actorCount,deathDedupe=self.state.deathOrder.count} end})
end

------------------------------------------------------------------------
-- 5. Crowd control activity / observed hit and duration
------------------------------------------------------------------------
do
    local metric={state=C:NewActorState(MAX_ACTORS)};metric.state.activeAuras={};metric.state.activeAuraCount=0;metric.state.activeAuraOverflow=0
    local function SkillActivity(self,fact)
        local row=type(AbilityCatalog)=="table" and AbilityCatalog:GetSkill(AbilityId(fact)) or nil;if row==nil or #row.controlTypes==0 then return false end
        local actor=SourceActor(self.state,fact);if actor==nil then return false end;local now=At(fact);actor.controlLast=actor.controlLast or {};if now-(tonumber(actor.controlLast[row.id]) or -999999)<300 then return false end;actor.controlLast[row.id]=now;C:Touch(actor,now);C:AddCounter(actor,"controlActivities",1);for _,t in ipairs(row.controlTypes) do AddDetail(actor,"controlActivityTypes",t,1) end;actor.controlConfidence=row.controlConfidence;return true
    end
    local function Aura(self,fact)
        if fact.category~="aura" or fact.auraId==nil then return false end;local buff=type(AbilityCatalog)=="table" and AbilityCatalog:GetBuff(fact.auraId) or nil;if buff==nil or type(buff.controlTypes)~="table" or #buff.controlTypes==0 then return false end
        local targetKey=C:ActorKey(fact.targetName,fact.targetId);if targetKey==nil then return false end;local key=targetKey.."|"..tostring(fact.auraId);local now=At(fact)
        if fact.kind=="aura_apply" then
            local source=SourceActor(self.state,fact);local target=TargetActor(self.state,fact);if source then C:Touch(source,now);C:AddCounter(source,"controlHits",1);for _,t in ipairs(buff.controlTypes) do AddDetail(source,"controlHitTypes",t,1) end end;if target then C:Touch(target,now);C:AddCounter(target,"controlled",1) end
            if self.state.activeAuras[key]==nil then if self.state.activeAuraCount<512 then self.state.activeAuras[key]={at=now,sourceKey=source and source.key,targetKey=target and target.key,auraName=buff.name};self.state.activeAuraCount=self.state.activeAuraCount+1 else self.state.activeAuraOverflow=self.state.activeAuraOverflow+1 end end;return true
        elseif fact.kind=="aura_remove" then local open=self.state.activeAuras[key];if open==nil then return false end;self.state.activeAuras[key]=nil;self.state.activeAuraCount=math.max(0,self.state.activeAuraCount-1);local duration=math.max(0,now-(tonumber(open.at) or now));local source=open.sourceKey and self.state.actors[open.sourceKey] or nil;local target=open.targetKey and self.state.actors[open.targetKey] or nil;if source then C:AddCounter(source,"controlMs",duration);AddDetail(source,"controlDurationByAura",open.auraName,duration) end;if target then C:AddCounter(target,"controlledMs",duration) end;return true end
        return false
    end
    Analytics:RegisterMetric({id="control",title="控制",category="utility",order=50,factCategories={"damage","heal","other","aura"},state=metric.state,
        description="控制技能活动、观察命中和观察持续时间；持续时间只来自明确 Aura apply/remove。",
        OnFact=function(self,fact) if fact.category=="aura" then return Aura(self,fact) end;return SkillActivity(self,fact) end,
        GetProjection=function(self,opt)
            local key=tostring(opt and opt.valueKey or "controlHits");local allowed={controlHits=true,controlActivities=true,controlMs=true,controlled=true,controlledMs=true};if not allowed[key] then key="controlHits" end
            local liveSource,liveTarget={},{}
            if key=="controlMs" or key=="controlledMs" then
                local now=C:NowMs()
                for _,open in pairs(self.state.activeAuras) do
                    local duration=math.max(0,now-(tonumber(open.at) or now))
                    if open.sourceKey then liveSource[open.sourceKey]=(tonumber(liveSource[open.sourceKey]) or 0)+duration end
                    if open.targetKey then liveTarget[open.targetKey]=(tonumber(liveTarget[open.targetKey]) or 0)+duration end
                end
            end
            local rows=Rank(self,key,{"controlHits","controlActivities","controlMs","controlled","controlledMs","controlConfidence"},100,{valueFn=function(actor,k)
                local value=tonumber(actor[k]) or 0
                if k=="controlMs" then value=value+(tonumber(liveSource[actor.key]) or 0) elseif k=="controlledMs" then value=value+(tonumber(liveTarget[actor.key]) or 0) end
                return value
            end})
            if key=="controlMs" or key=="controlledMs" then for _,row in ipairs(rows) do row[key]=row.value end end
            return {valueKey=key,rows=rows,activeAuras=self.state.activeAuraCount,coverage="ACTIVITY_INFERRED_AURA_DURATION_OBSERVED"}
        end,
        Reset=function(self) self.state=C:NewActorState(MAX_ACTORS);self.state.activeAuras={};self.state.activeAuraCount=0;self.state.activeAuraOverflow=0;metric.state=self.state;return true end,
        GetHealth=function(self) return {actors=self.state.actorCount,activeAuras=self.state.activeAuraCount,auraOverflow=self.state.activeAuraOverflow} end})
end

------------------------------------------------------------------------
-- 6. Songcraft / instrument duration / observed coverage
------------------------------------------------------------------------
do
    local metric={state=C:NewActorState(MAX_ACTORS)};metric.state.selfActiveSong=nil;metric.state.activeBuffs={};metric.state.activeBuffCount=0;metric.state.activeBuffOverflow=0
    local function Song(id) local r=type(AbilityCatalog)=="table" and AbilityCatalog:GetSkill(id) or nil;return r and r.songcraft==true and r or nil end
    local function CloseSelf(self,now,reason)
        local open=self.state.selfActiveSong;if open==nil then return false end;local actor=self.state.actors[open.actorKey];if actor then local duration=math.max(0,now-(tonumber(open.at) or now));C:AddCounter(actor,"songMs",duration);AddDetail(actor,"songDurationBySkill",open.name,duration);actor.lastSongStopReason=reason end;self.state.selfActiveSong=nil;return true
    end
    Analytics:RegisterMetric({id="songcraft",title="乐器 / 演奏",category="support",order=60,factCategories={"damage","heal","other","aura"},nativeEvents={"SPELLCAST_START","SPELLCAST_STOP"},state=metric.state,
        description="演奏活动、SELF精确开始/停止/切歌、各歌曲观察时间与歌曲Buff覆盖。Native不完整时明确降级。",
        OnFact=function(self,fact)
            local changed=false;local song=Song(AbilityId(fact));local now=At(fact)
            if song and fact.category~="aura" then local actor=SourceActor(self.state,fact);if actor then actor.songLast=actor.songLast or {};if now-(tonumber(actor.songLast[song.id]) or -999999)>=500 then actor.songLast[song.id]=now;C:Touch(actor,now);C:AddCounter(actor,"songActivities",1);AddDetail(actor,"songs",song.name,1);changed=true end end end
            if fact.category=="aura" and type(AbilityCatalog)=="table" then local songId=AbilityCatalog:GetSongSkillForBuff(fact.auraId);local songRow=Song(songId);local targetKey=C:ActorKey(fact.targetName,fact.targetId);local auraKey=targetKey and (targetKey.."|"..tostring(fact.auraId)) or nil
                if songRow and auraKey and fact.kind=="aura_apply" then local actor=TargetActor(self.state,fact);if actor then C:Touch(actor,now);C:AddCounter(actor,"songBuffApplies",1);AddDetail(actor,"songBuffs",songRow.name,1) end;if self.state.activeBuffs[auraKey]==nil then if self.state.activeBuffCount<1024 then self.state.activeBuffs[auraKey]={at=now,targetKey=actor and actor.key,songName=songRow.name};self.state.activeBuffCount=self.state.activeBuffCount+1 else self.state.activeBuffOverflow=self.state.activeBuffOverflow+1 end end;changed=true
                elseif songRow and auraKey and fact.kind=="aura_remove" and self.state.activeBuffs[auraKey] then local open=self.state.activeBuffs[auraKey];self.state.activeBuffs[auraKey]=nil;self.state.activeBuffCount=math.max(0,self.state.activeBuffCount-1);local actor=open.targetKey and self.state.actors[open.targetKey] or nil;if actor then local duration=math.max(0,now-(tonumber(open.at) or now));C:AddCounter(actor,"songBuffMs",duration);AddDetail(actor,"songBuffDuration",open.songName,duration) end;changed=true end
            end;return changed
        end,
        OnNativeFact=function(self,fact)
            local now=tonumber(fact.receivedAt) or C:NowMs()
            if fact.kind=="cast_start" then
                local song=Song(fact.abilityId);if song==nil then return false end
                local actor=C:EnsureActor(self.state,fact.sourceName,nil);if actor==nil then return false end
                local durationReliable=Analytics.nativeCoverage.SPELLCAST_STOP=="FULL"
                if self.state.selfActiveSong~=nil then
                    if durationReliable then CloseSelf(self,now,"switch");C:AddCounter(actor,"songSwitches",1)
                    else self.state.selfActiveSong=nil end
                end
                C:Touch(actor,now);C:AddCounter(actor,"songStarts",1);AddDetail(actor,"nativeSongs",song.name,1)
                -- START without STOP proves a cast, not its duration. Never infer
                -- song uptime merely from the next START or wall-clock passage.
                if durationReliable then self.state.selfActiveSong={actorKey=actor.key,skillId=song.id,name=song.name,at=now} end
                return true
            elseif fact.kind=="cast_stop" and self.state.selfActiveSong~=nil then
                local actor=self.state.actors[self.state.selfActiveSong.actorKey];if actor then C:AddCounter(actor,"songStops",1) end
                return CloseSelf(self,now,"stop")
            end
            return false
        end,
        GetProjection=function(self,opt) local key=tostring(opt and opt.valueKey or "songMs");local allowed={songMs=true,songStarts=true,songSwitches=true,songActivities=true,songBuffMs=true,songBuffApplies=true};if not allowed[key] then key="songMs" end;local open=self.state.selfActiveSong;local now=C:NowMs();local rows=Rank(self,key,{"songMs","songStarts","songStops","songSwitches","songActivities","songBuffMs","songBuffApplies"},100,{valueFn=function(actor,k) local v=tonumber(actor[k]) or 0;if k=="songMs" and open and open.actorKey==actor.key then v=v+math.max(0,now-(tonumber(open.at) or now)) end;return v end});for _,row in ipairs(rows) do if key=="songMs" and open and open.actorKey==row.key then row.songMs=row.value;row.songActive=true end end;local start=Analytics.nativeCoverage.SPELLCAST_START;local stop=Analytics.nativeCoverage.SPELLCAST_STOP;local native=(start=="FULL" and stop=="FULL") and "SELF_NATIVE_DURATION" or (start=="FULL" and "SELF_NATIVE_CAST_ONLY" or "UNAVAILABLE");return {valueKey=key,rows=rows,nativeCoverage=native,coverage="SELF_NATIVE_WHEN_AVAILABLE_TEAM_ACTIVITY_AND_AURA_OBSERVED"} end,
        Reset=function(self) self.state=C:NewActorState(MAX_ACTORS);self.state.selfActiveSong=nil;self.state.activeBuffs={};self.state.activeBuffCount=0;self.state.activeBuffOverflow=0;metric.state=self.state;return true end,
        GetHealth=function(self) return {actors=self.state.actorCount,selfSongOpen=self.state.selfActiveSong~=nil,activeBuffs=self.state.activeBuffCount,activeBuffOverflow=self.state.activeBuffOverflow} end})
end

------------------------------------------------------------------------
-- 7. Utility: interrupt/dispel/cleanse/resurrection/defensive activity
------------------------------------------------------------------------
do
    local metric={state=C:NewActorState(MAX_ACTORS)}
    local function Apply(self,fact,exact)
        local row=type(AbilityCatalog)=="table" and AbilityCatalog:GetSkill(AbilityId(fact)) or nil;if row==nil or #row.utilityTypes==0 then return false end
        local actor=C:EnsureActor(self.state,fact.sourceName,fact.sourceId);if actor==nil then return false end;local now=At(fact);actor.utilityLast=actor.utilityLast or {};if exact~=true and now-(tonumber(actor.utilityLast[row.id]) or -999999)<300 then return false end;actor.utilityLast[row.id]=now;C:Touch(actor,now);C:AddCounter(actor,exact and "utilityExact" or "utilityActivities",1);for _,t in ipairs(row.utilityTypes) do C:AddCounter(actor,t,1);AddDetail(actor,"utilityTypes",t,1) end;AddDetail(actor,exact and "utilitySkillsExact" or "utilitySkills",row.name,1);actor.utilityConfidence=exact and "self_native_catalog_match" or row.utilityConfidence;return true
    end
    Analytics:RegisterMetric({id="utility",title="辅助贡献",category="utility",order=70,factCategories={"damage","heal","other"},nativeEvents={"SPELLCAST_START"},state=metric.state,
        description="打断、驱散/净化、复活、防御技能的使用活动；成功效果需要后续更强事件证据，本机Native只证明施法。",
        OnFact=function(self,fact) return Apply(self,fact,false) end,OnNativeFact=function(self,fact) if fact.kind~="cast_start" then return false end;return Apply(self,fact,true) end,
        GetProjection=function(self,opt) local key=tostring(opt and opt.valueKey or "utilityActivities");local allowed={utilityActivities=true,utilityExact=true,interrupt=true,dispel=true,cleanse=true,resurrection=true,defensive=true};if not allowed[key] then key="utilityActivities" end;return {valueKey=key,rows=Rank(self,key,{"utilityActivities","utilityExact","interrupt","dispel","cleanse","resurrection","defensive","utilityConfidence"},100),coverage="CATALOG_ACTIVITY_SELF_NATIVE_ENRICHMENT"} end,
        Reset=function(self) return ResetActor(self) end,GetHealth=function(self) return {actors=self.state.actorCount} end})
end

------------------------------------------------------------------------
-- 8. Observed Buff/Debuff uptime
------------------------------------------------------------------------
do
    local metric={state=C:NewActorState(MAX_ACTORS)};metric.state.active={};metric.state.activeCount=0;metric.state.activeOverflow=0
    Analytics:RegisterMetric({id="aura",title="Buff / Debuff 覆盖",category="support",order=80,factCategories={"aura"},state=metric.state,
        description="只统计明确观察到的Aura施加/移除；没观察到不等于0%覆盖。",
        OnFact=function(self,fact)
            if fact.category~="aura" or fact.auraId==nil then return false end;local targetKey=C:ActorKey(fact.targetName,fact.targetId);if targetKey==nil then return false end;local key=targetKey.."|"..tostring(fact.auraId);local actor=TargetActor(self.state,fact);if actor==nil then return false end;local now=At(fact);C:Touch(actor,now)
            local buff=type(AbilityCatalog)=="table" and AbilityCatalog:GetBuff(fact.auraId) or nil;local name=C:Trim(fact.auraName);if name=="" then name=buff and buff.name or ("状态#"..tostring(fact.auraId)) end;local prefix=fact.auraType=="debuff" and "debuff" or "buff"
            if fact.kind=="aura_apply" then C:AddCounter(actor,prefix.."Applies",1);AddDetail(actor,prefix.."AppliesByAura",name,1);if self.state.active[key]==nil then if self.state.activeCount<1024 then self.state.active[key]={at=now,actorKey=actor.key,name=name,prefix=prefix};self.state.activeCount=self.state.activeCount+1 else self.state.activeOverflow=self.state.activeOverflow+1 end end;return true
            elseif fact.kind=="aura_remove" then C:AddCounter(actor,prefix.."Removes",1);local open=self.state.active[key];if open then self.state.active[key]=nil;self.state.activeCount=math.max(0,self.state.activeCount-1);local duration=math.max(0,now-(tonumber(open.at) or now));C:AddCounter(actor,prefix.."UptimeMs",duration);AddDetail(actor,prefix.."DurationByAura",open.name,duration) end;return true end;return false
        end,
        GetProjection=function(self,opt)
            local key=tostring(opt and opt.valueKey or "buffUptimeMs");local allowed={buffUptimeMs=true,debuffUptimeMs=true,buffApplies=true,debuffApplies=true};if not allowed[key] then key="buffUptimeMs" end
            local liveByActor={}
            if key=="buffUptimeMs" or key=="debuffUptimeMs" then
                local wanted=key=="debuffUptimeMs" and "debuff" or "buff";local now=C:NowMs()
                for _,open in pairs(self.state.active) do if open.prefix==wanted and open.actorKey then liveByActor[open.actorKey]=(tonumber(liveByActor[open.actorKey]) or 0)+math.max(0,now-(tonumber(open.at) or now)) end end
            end
            local rows=Rank(self,key,{"buffUptimeMs","debuffUptimeMs","buffApplies","debuffApplies","buffRemoves","debuffRemoves"},100,{valueFn=function(actor,k) return (tonumber(actor[k]) or 0)+(tonumber(liveByActor[actor.key]) or 0) end})
            if key=="buffUptimeMs" or key=="debuffUptimeMs" then for _,row in ipairs(rows) do row[key]=row.value end end
            return {valueKey=key,rows=rows,active=self.state.activeCount,coverage="OBSERVED_AURA_EVENTS_ONLY"}
        end,
        Reset=function(self) self.state=C:NewActorState(MAX_ACTORS);self.state.active={};self.state.activeCount=0;self.state.activeOverflow=0;metric.state=self.state;return true end,
        GetHealth=function(self) return {actors=self.state.actorCount,active=self.state.activeCount,overflow=self.state.activeOverflow} end})
end

------------------------------------------------------------------------
-- 9. Boss mechanics: exact static catalog observations only
------------------------------------------------------------------------
do
    local metric={state=C:NewActorState(MAX_ACTORS)};metric.state.total=0;metric.state.byMechanic={};metric.state.mechanicCount=0;metric.state.mechanicOverflow=0
    local function Credit(self,fact,mechanic,confidence)
        if mechanic==nil then return false end
        local affected=C:Trim(TargetName(fact));local source=C:Trim(fact.sourceName)
        local actor
        if affected~="" then actor=C:EnsureActor(self.state,affected,fact.targetId)
        elseif source~="" then actor=C:EnsureActor(self.state,source,fact.sourceId)
        else actor=C:EnsureActor(self.state,"未知单位",nil) end
        if actor==nil then return false end
        C:Touch(actor,At(fact));C:AddCounter(actor,"mechanics",1);AddDetail(actor,"mechanicTypes",mechanic.key,1)
        if source~="" then AddDetail(actor,"mechanicSources",source,1) end
        actor.lastMechanicConfidence=confidence;actor.lastMechanicRole=affected~="" and "affected_target" or "source_fallback"
        self.state.total=self.state.total+1;C:AddMapValue(self.state.byMechanic,mechanic.key,1,128,self.state,"mechanicCount","mechanicOverflow");return true
    end
    Analytics:RegisterMetric({id="mechanics",title="Boss 机制",category="mechanics",order=90,factCategories={"damage","heal","other","aura"},state=metric.state,
        description="复用BossAlerts，只记录精确技能名或已知Debuff ID；有明确目标时统计受影响单位，无目标才回退来源，热路径不做模糊匹配。",
        OnFact=function(self,fact)
            if type(MechanicCatalog)~="table" then return false end
            local mechanic,confidence
            if fact.category=="aura" then mechanic=MechanicCatalog:FindDebuff(fact.auraId);confidence="verified_debuff_id"
            else mechanic=MechanicCatalog:FindCast(AbilityName(fact));confidence="exact_cast_name" end
            return Credit(self,fact,mechanic,confidence)
        end,
        GetProjection=function(self) return {valueKey="mechanics",rows=Rank(self,"mechanics",{"lastMechanicConfidence","lastMechanicRole"},100),byMechanic=C:MapRows(self.state.byMechanic,100,"count"),total=self.state.total,coverage="EXACT_CATALOG_MATCH_TARGET_FIRST"} end,
        Reset=function(self) self.state=C:NewActorState(MAX_ACTORS);self.state.total=0;self.state.byMechanic={};self.state.mechanicCount=0;self.state.mechanicOverflow=0;metric.state=self.state;return true end,
        GetHealth=function(self) return {actors=self.state.actorCount,total=self.state.total,mechanicOverflow=self.state.mechanicOverflow} end})
end

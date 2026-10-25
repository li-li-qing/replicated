-- Replicated Suite · 战斗分析内置指标
-- 作者：Replicated
-- QQ群：1104129461
-- 独立且有界的指标插件；明确区分 direct、observed、inferred 证据。
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
local function KnownKind(name,kind)
    if kind~=nil and kind~="" and kind~="UNKNOWN" then return kind end
    local relation=S.Services and S.Services.CombatRelationV3
    local unit=relation and type(relation.GetUnit)=="function" and relation:GetUnit(name) or nil
    return type(unit)=="table" and unit.kind or nil
end
local function KnownPlayer(name,kind) return KnownKind(name,kind)=="PLAYER" end
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

-- 1. 战斗场次、历史与有界时间线。
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
    Analytics:RegisterMetric({id="encounter",suspended=true,title="战斗历史",category="timeline",order=10,factCategories={"damage","heal","death","aura"},state=metric.state,
        description="当前战斗、最近20场摘要和当前有界时间线；Aura 不单独开启或延长战斗。",
        OnFact=function(self,fact)
            local anchor=IsAnchor(fact); if anchor~=true and fact.category~="aura" then return false end
            local now=At(fact); local cur=self.state.current
            -- Scheduler 饥饿或长帧不能合并两场战斗；事件本身决定空闲间隔边界，一次性任务只协助及时关闭场次。
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

-- 2. Kills / deaths. 只保留目标类型/伤害观察时间，合并死亡与明确归属；不维护助攻集合。
do
    local metric={state=C:NewActorState(MAX_ACTORS)}
    -- 击杀计数只随确认死亡/补证变化；伤害刷新不应重复扫描、排序同一份战绩。
    -- 私有缓存固定为6种排行（击杀/死亡/荣誉次数 × 是否含零）和最多4个角色技能索引槽。
    -- 只缓存排序顺序，按精确版本及 state 身份失效；公开行永不存入私有缓存。
    local rankCache,skillCache,nextSkillCache={},{},1
    local cacheGeneration,cacheState,cacheRevision
    local function ClearReadCache()
        rankCache,skillCache,nextSkillCache={},{},1
        cacheGeneration,cacheState,cacheRevision=nil,nil,nil
    end
    local function CheckReadCache(state)
        if cacheGeneration~=S.Generation or cacheState~=state or cacheRevision~=state.revision then
            ClearReadCache()
            cacheGeneration,cacheState,cacheRevision=S.Generation,state,state.revision
        end
    end
    local function KillRanking(self,key,limit,includeZero)
        CheckReadCache(self.state)
        local slot=(key=="deaths" and 3 or (key=="honorParticipations" and 5 or 1))+(includeZero and 1 or 0)
        local order=rankCache[slot]
        local rows={}
        if order==nil then
            rows=Rank(self,key,{"kills","deaths","honorParticipations","honorAssistedKills","lastKillConfidence"},MAX_ACTORS,{includeZero=includeZero})
            order={};for index,row in ipairs(rows) do order[index]=row.key end
            rankCache[slot]=order
            -- 冷读直接交出本次新建行，只另存标量顺序，避免先建快照再复制整表。
            while #rows>limit do rows[#rows]=nil end
            return rows
        end
        for index=1,math.min(#order,limit) do
            local actor=self.state.actors[order[index]]
            local row={key=actor.key,name=actor.name~="" and actor.name or actor.key,value=tonumber(actor[key]) or 0,
                firstAt=actor.firstAt,lastAt=actor.lastAt}
            row.kills,row.deaths,row.lastKillConfidence,row.rank=actor.kills,actor.deaths,actor.lastKillConfidence,index
            row.honorParticipations=actor.honorParticipations
            row.honorAssistedKills=actor.honorAssistedKills
            rows[index]=row
        end
        return rows
    end
    -- 漏记击杀需要死亡原文与判定证据，errors=0 不能说明已计数。
    -- 只在死亡/通知分支保留32条标量记录；普通伤害不建诊断快照，不开全场桥/新任务。
    -- 证据属于本次加载，停用或清空实时计数不抹掉它；导出时才复制，不能触发结算。
    local evidence={events=C:NewBoundedQueue(32),counters={}}
    local function Scalar(value)
        local kind=type(value)
        if kind=="nil" or kind=="number" or kind=="boolean" then return value end
        if kind~="string" then return "<"..kind..">" end
        if #value<=512 then return value end
        local finish=512
        while finish>0 and (value:byte(finish+1) or 0)>=128 and (value:byte(finish+1) or 0)<192 do finish=finish-1 end
        return value:sub(1,finish).."<clipped>"
    end
    local function Evidence(fact,phase,reason,victim,killer,extra)
        fact=fact or {}
        local row={at=At(fact),processedAt=C:NowMs(),phase=phase,reason=reason,scope=Analytics:GetCollectionScope(),
            victim=Scalar(victim or TargetName(fact)),killer=Scalar(killer or fact.sourceName),kind=Scalar(fact.kind),
            transport=Scalar(fact.transport),sequence=Scalar(fact.sequence),rawEventType=Scalar(fact.rawEventType),
            sourceKind=Scalar(fact.sourceKind),targetKind=Scalar(fact.targetKind),boundRole=Scalar(fact.boundRole),
            rawUnitId=Scalar(fact.rawUnitId),rawNotice2=Scalar(fact.rawNotice2),rawNotice3=Scalar(fact.rawNotice3),
            rawAbilityId=Scalar(fact.rawAbilityId or fact.abilityId),abilityName=Scalar(fact.abilityName),
            rawNotice4=Scalar(fact.rawNotice4),rawNotice5=Scalar(fact.rawNotice5)}
        for key,value in pairs(extra or {}) do row[key]=Scalar(value) end
        C:QueuePush(evidence.events,row)
        evidence.counters[reason]=(tonumber(evidence.counters[reason]) or 0)+1
    end
    local function Init(state)
        state.targets={};state.targetOrder=C:NewBoundedQueue(512);state.targetCount=0;state.deathOrder=C:NewBoundedQueue(512)
        state.lastDeath={};state.deathByName={};state.notices={};state.noticeCount=0;state.noticeScheduled=false
        state.honorReceipts={};state.explicitReceipts={};state.honorScheduled=false;state.honorEpoch=(state.honorEpoch or 0)+1
        state.honorSuppressedUntil=nil
    end
    Init(metric.state)
    -- 与明确归属现有8秒补证窗一致。荣誉先等1.5秒接收正常延迟的击杀通知；已补记的荣誉仍保留配对位，迟到归属只补名单。
    -- 金额不含目标ID，只能按同一短时间段一对一消耗证据；有界保留，不按同额合并两次真实奖励。
    local HONOR_WINDOW,HONOR_GRACE,HONOR_LIMIT=8000,1500,256
    local function PruneReceipts(rows,now)
        local kept=0
        for i=1,#rows do
            local row=rows[i]
            if not row.matched and (now-row.at<=HONOR_WINDOW or (row.dueAt and not row.settled)) then kept=kept+1;rows[kept]=row end
        end
        for i=#rows,kept+1,-1 do rows[i]=nil end
    end
    local function FindReceipt(rows,now)
        PruneReceipts(rows,now)
        for _,row in ipairs(rows) do if not row.matched and now>=row.at and now-row.at<=HONOR_WINDOW then row.matched=true;return row end end
    end
    local function AddExplicitReceipt(state,now,live,history,death)
        PruneReceipts(state.explicitReceipts,now)
        if #state.explicitReceipts>=HONOR_LIMIT then
            state.honorSuppressedUntil=now+HONOR_WINDOW;table.remove(state.explicitReceipts,1)
        end
        local h=Feature.PersonalHistory;local date,stamp;if h then date,stamp=h:Timestamp() end
        state.explicitReceipts[#state.explicitReceipts+1]={at=now,liveKill=live,historyKill=history,death=death,recordTime={date=date,stamp=stamp}}
    end
    local function CreditHonor(state,row)
        if row.matched or row.settled then return false end
        row.settled=true;local changed=false
        if not row.liveKill and Feature:IsMetricPreferenceEnabled("kills") then
            local actor=C:EnsureActor(state,row.name)
            if actor then
                C:AddCounter(actor,"kills",1)
                if not row.confirmed then C:AddCounter(actor,"honorAssistedKills",1) end
                C:Touch(actor,row.at);actor.lastKillConfidence=row.confirmed and "native_kill_notice" or "honor_reward_match";row.liveKill=true;changed=true
            end
        end
        local history=Feature.PersonalHistory
        if not row.historyKill then
            row.historyKill=history and history:Record({kills=1},row.recordTime)==true or false;changed=row.historyKill or changed
        end
        Evidence({receivedAt=row.at,kind="war_honor_delta"},"decision","honor_kill_supplemented",nil,row.name,
            {honorAmount=row.amount,liveKill=row.liveKill==true,historyKill=row.historyKill,confidence="honor_reward_match"})
        if changed then state.revision=(tonumber(state.revision) or 0)+1;return true end
        return false
    end
    local ScheduleHonor
    ScheduleHonor=function(self)
        if self.state.honorScheduled then return true end
        local due
        for _,row in ipairs(self.state.honorReceipts) do
            if not row.matched and not row.settled and (not due or row.dueAt<due) then due=row.dueAt end
        end
        if not due then return true end
        local scheduler=S.Scheduler;if not scheduler then return false end
        if type(scheduler.SetTaskModule)=="function" then scheduler:SetTaskModule("v3_combat_kills_honor","combat_analytics",true) end
        local state,generation,epoch=self.state,S.Generation,self.state.honorEpoch
        state.honorScheduled=true
        local ok=scheduler:AddOneShot("v3_combat_kills_honor",math.max(50,due-C:NowMs()),function()
            if S.Generation~=generation or self.state~=state or state.honorEpoch~=epoch or not Analytics.activeMetrics.kills then return true end
            state.honorScheduled=false;local now=C:NowMs();local changed=false
            for _,row in ipairs(state.honorReceipts) do if row.dueAt<=now then changed=CreditHonor(state,row) or changed end end
            PruneReceipts(state.honorReceipts,now)
            if changed then Analytics:NotifyMetricChanged("honor_assisted_kills") end
            ScheduleHonor(self);return true
        end,self,"P3",1)
        if ok~=true then state.honorScheduled=false end
        return ok==true
    end
    local function QueueHonor(self,fact,name,amount)
        if not Feature:IsHonorKillAmount(amount) then
            Evidence(fact,"decision",(amount==3 or amount==12) and "honor_assist_excluded" or "honor_amount_unmatched",nil,name,{honorAmount=amount})
            return false
        end
        local now=At(fact)
        local explicit=FindReceipt(self.state.explicitReceipts,now)
        if explicit then
            -- 归属已确认不代表两路都保存成功；只补上失败的一路，已记的实时/历史绝不再加。
            local changed=false
            if not explicit.liveKill or not explicit.historyKill then
                local repair={at=explicit.at,name=name,amount=amount,confirmed=true,recordTime=explicit.recordTime,
                    liveKill=explicit.liveKill,historyKill=explicit.historyKill}
                changed=CreditHonor(self.state,repair)
                if explicit.death then explicit.death.liveKill=repair.liveKill;explicit.death.historyKill=repair.historyKill end
            end
            Evidence(fact,"decision","honor_paired_with_explicit",nil,name,{honorAmount=amount});return changed
        end
        if now<(self.state.honorSuppressedUntil or 0) then Evidence(fact,"decision","honor_pairing_overflow",nil,name);return false end
        -- 溢出时宁可留下诊断，也不能丢掉去重位后再把同一份证据加两遍。
        PruneReceipts(self.state.honorReceipts,now)
        if #self.state.honorReceipts>=HONOR_LIMIT then Evidence(fact,"decision","honor_pairing_overflow",nil,name);return false end
        local history=Feature.PersonalHistory;local date,stamp
        if history then date,stamp=history:Timestamp() end
        local row={at=now,dueAt=now+HONOR_GRACE,name=name,amount=amount,recordTime={date=date,stamp=stamp}}
        self.state.honorReceipts[#self.state.honorReceipts+1]=row
        if not ScheduleHonor(self) then row.matched=true;Evidence(fact,"decision","honor_scheduler_unavailable",nil,name);return false end
        Evidence(fact,"decision","honor_awaiting_explicit",nil,name,{honorAmount=amount});return true
    end
    -- 原生战争序号只用于定位漏通知；字段生命周期尚待系统累计验证，绝不能据此补写永久历史。
    local nativeCounter=nil
    local function EnsureTarget(state,name)
        name=C:Trim(name); if name=="" then return nil end
        local row=state.targets[name]; if row then return row end
        if state.targetCount>=512 then
            local victim
            C:QueueEach(state.targetOrder,function(candidate) if victim==nil and candidate.active==true then victim=candidate end end)
            if victim then state.targets[victim.name]=nil;victim.active=false;state.targetCount=state.targetCount-1 end
        end
        row={name=name,active=true};state.targets[name]=row;state.targetCount=state.targetCount+1;C:QueuePush(state.targetOrder,row);return row
    end
    local function RecordDamage(state,fact)
        if fact.category~="damage" or (tonumber(fact.amount) or 0)<=0 then return false end
        local kind=KnownKind(fact.targetName,fact.targetKind)
        if kind=="NPC" then return false end
        local source=C:Trim(fact.sourceName);if source=="" then return false end
        local target=EnsureTarget(state,fact.targetName);if target==nil then return false end
        target.lastDamageAt=At(fact)
        if Analytics:IsSelfActor(source,fact.sourceId) then target.selfDamageObserved=true end
        if kind=="PLAYER" then target.victimKind=kind end
        return false
    end
    -- 2026-10-07：技能只取确认击杀事实本身的字段；绝不借最近伤害推断最后一击技能。
    -- 当前原生玩家通知没有已接入的技能字段，统一落入“技能未确认”；仅在确认击杀时建记录。
    -- 每个角色最多64个具体技能、128个技能/玩家组合，容量外保留合计与遗漏数。
    local function RecordSkillKill(actor,fact,victim)
        local id=C:Finite(AbilityId(fact),nil)
        if not id or id<=0 or id~=math.floor(id) then id=nil end
        local name=C:Trim(fact and fact.abilityName)
        local key=id and ("id:"..tostring(id)) or (name~="" and ("name:"..name) or "__unknown_skill__")
        if name=="" then name=id and AbilityName(fact) or "技能未确认" end
        actor.skillKills=actor.skillKills or {}
        local row=actor.skillKills[key]
        if not row and key~="__unknown_skill__" and (tonumber(actor.skillKillCount) or 0)>=64 then
            key,id,name="__other_skills__",nil,"其他技能（容量已满）";row=actor.skillKills[key]
        end
        if not row then
            row={key=key,name=name,abilityId=id,kills=0,targets={},omittedTargets=0}
            actor.skillKills[key]=row
            if key~="__unknown_skill__" and key~="__other_skills__" then actor.skillKillCount=(tonumber(actor.skillKillCount) or 0)+1 end
        end
        row.kills=row.kills+1
        if row.targets[victim]~=nil then row.targets[victim]=row.targets[victim]+1
        elseif (tonumber(actor.skillKillTargetCount) or 0)<128 then
            row.targets[victim]=1;actor.skillKillTargetCount=(tonumber(actor.skillKillTargetCount) or 0)+1
        else row.omittedTargets=row.omittedTargets+1 end
    end
    local function SkillKillProjection(state,opt)
        local actor=state.actors[tostring(opt.actorKey or "")]
        if not actor and C:Trim(opt.actorName)~="" then actor=state.actors[C:ActorKey(opt.actorName)] end
        CheckReadCache(state)
        local cached,rows=nil,{}
        if actor then
            -- DPS 的 key 可能小写，必须先按原 actorName 回退解析，再复用真实角色键。
            for _,entry in ipairs(skillCache) do if entry.key==actor.key then cached=entry;break end end
            if not cached or cached.seen==true then
                for _,row in pairs(actor.skillKills or {}) do
                    rows[#rows+1]={key=row.key,name=row.name,abilityId=row.abilityId,kills=row.kills,
                        targets=C:MapRows(row.targets,128,"kills"),omittedTargets=row.omittedTargets}
                end
                table.sort(rows,function(a,b)if a.kills~=b.kills then return a.kills>b.kills end return a.key<b.key end)
                if not cached then
                    -- 每版本首次读取只留标量准入标记；频繁新击杀后的单次读取不建立整份索引。
                    -- 同角色第二次读取才准入，第三次起复用；绝不保存本次公开 skills/targets。
                    skillCache[nextSkillCache]={key=actor.key,seen=true};nextSkillCache=nextSkillCache%4+1
                else
                    -- 顺序数组以版本内的私有技能行分段，后接已排序的目标名；至多66+128项。
                    -- 行引用只属于当前 state，公开 skills/targets 均为新表，不会反向写入它。
                    local order={}
                    for _,row in ipairs(rows) do
                        order[#order+1]=actor.skillKills[row.key]
                        for _,target in ipairs(row.targets) do order[#order+1]=target.key end
                    end
                    cached.order,cached.seen=order,nil
                end
            else
                local row,targets
                for _,item in ipairs(cached.order) do
                    if type(item)=="table" then
                        row,targets=item,{}
                        rows[#rows+1]={key=row.key,name=row.name,abilityId=row.abilityId,kills=row.kills,
                            targets=targets,omittedTargets=row.omittedTargets}
                    else
                        local value=tonumber(row.targets[item]) or 0
                        targets[#targets+1]={key=item,name=item,value=value,kills=value}
                    end
                end
            end
        end
        return {actor=actor and {key=actor.key,name=actor.name,kills=actor.kills or 0} or nil,skills=rows,honorAssistedKills=actor and actor.honorAssistedKills or 0,
            retainedTargets=actor and actor.skillKillTargetCount or 0,dataRevision=tonumber(state.revision) or 0,
            statsAvailable=Feature:IsMetricPreferenceEnabled("kills"),coverage="CONFIRMED_PLAYER_KILLS_SKILL_FROM_DEATH_FACT_ONLY"}
    end
    local function CreditDeath(state,victimName,victimId,directKiller,directAbility,now,confidence,victimKind,killerKind,fact)
        victimName=C:Trim(victimName);if victimName=="" then Evidence(fact,"decision","missing_victim_name",victimName,directKiller);return false end
        local deathKey=victimId~=nil and ("id:"..tostring(victimId)) or ("name:"..victimName)
        local ledger=state.targets[victimName]
        local previous=state.lastDeath[deathKey]
        local named=state.deathByName[victimName]
        if fact and fact.kind=="kill_notice" then previous=named or previous
        elseif not previous and named and named.key=="name:"..victimName then previous=named end
        -- 通知结算后才到达的明确归属可以补计；已计的双通知不能再计一次。
        -- 新伤害表示可能已复活；不同已验证 ID 按不同死亡去重。
        local confirmed=fact and fact.kind~="death_notice" and C:Trim(directKiller)~=""
        local newNativeKill=confirmed and fact.kind=="kill_notice" and previous and previous.nativeStreak~=nil
            and fact.rawNotice2~=nil and fact.rawNotice2~=previous.nativeStreak and previous.nativeKiller==C:Trim(directKiller)
        local sameDeath=previous and ((now-previous.at<1200) or (confirmed and now-previous.at<=8000
            and not newNativeKill and not (ledger and (tonumber(ledger.lastDamageAt) or 0)>previous.at)))
        local upgrade=sameDeath and confirmed and C:Trim(directKiller)~="" and not previous.liveKill and not previous.historyKill
        if sameDeath and not upgrade then Evidence(fact,"decision","duplicate_death",victimName,directKiller);return false end
        local death=upgrade and previous or {key=deathKey,victim=victimName,at=now}
        if not upgrade then
            state.lastDeath[deathKey]=death;state.deathByName[victimName]=death
            local _,evicted=C:QueuePush(state.deathOrder,death)
            if evicted then
                if state.lastDeath[evicted.key]==evicted then state.lastDeath[evicted.key]=nil end
                if state.deathByName[evicted.victim]==evicted then state.deathByName[evicted.victim]=nil end
            end
        end
        if fact and fact.kind=="kill_notice" then death.nativeStreak=fact.rawNotice2;death.nativeKiller=C:Trim(directKiller) end
        local trackLive=type(Feature.IsMetricPreferenceEnabled)~="function" or Feature:IsMetricPreferenceEnabled("kills")
        local resolvedKind=KnownKind(victimName,victimKind)
        if resolvedKind~="PLAYER" and resolvedKind~="NPC" then resolvedKind=(ledger and ledger.victimKind) or death.victimKind end
        local playerVictim=Analytics:IsSelfActor(victimName,victimId) or resolvedKind=="PLAYER"
        death.victimKind=playerVictim and "PLAYER" or nil
        local victim=not upgrade and trackLive and playerVictim and C:EnsureActor(state,victimName,victimId) or nil;if victim then C:AddCounter(victim,"deaths",1);C:Touch(victim,now) end
        local killer=C:Trim(directKiller);local ability=C:Trim(directAbility)
        -- 2026-10-07 用户明确选择只计归属：self/all 都不能把最近伤害当最后一击。
        -- 伤害账本仅帮助分类/合并；缺击杀者的死亡保留诊断，等待明确归属补证。
        local killerId=fact and fact.sourceId or nil
        local playerKiller=Analytics:IsSelfActor(killer,killerId) or KnownPlayer(killer,killerKind)
        if killer==victimName then playerKiller=false end
        local ownKill=playerVictim and Analytics:IsSelfActor(killer,killerId) and killer~=victimName
        -- 明确归属不依赖地区或荣誉。普通区域杀人没有荣誉，仍须立即计入；下面配对只消除辅助重复。
        local pairedHonor=ownKill and FindReceipt(state.honorReceipts,now) or nil
        local liveKill,historyKill=pairedHonor and pairedHonor.liveKill==true or false,pairedHonor and pairedHonor.historyKill==true or false
        if killer~="" and trackLive and playerVictim and playerKiller then
            local actor=C:EnsureActor(state,killer,killerId);if actor then
                if not liveKill then C:AddCounter(actor,"kills",1) end
                if pairedHonor and pairedHonor.liveKill then actor.honorAssistedKills=math.max(0,(tonumber(actor.honorAssistedKills) or 0)-1) end
                liveKill=true;C:Touch(actor,now);actor.lastKillConfidence=confidence or "direct_death_source";AddDetail(actor,"killTargets",victimName,1);AddDetail(actor,"killAbilities",ability~="" and ability or "未知技能",1);RecordSkillKill(actor,fact,victimName)
            end
        end
        local h=Feature.PersonalHistory
        if h then
            local delta={}
            if not upgrade and Analytics:IsSelfActor(victimName,victimId) then delta.deaths=1
            elseif ownKill and not historyKill then
                delta.kills=1
            end
            if next(delta)~=nil then historyKill=h:Record(delta,pairedHonor and pairedHonor.recordTime)==true and delta.kills==1 end
        end
        if ownKill and not pairedHonor then AddExplicitReceipt(state,now,liveKill,historyKill,death) end
        local reason
        if liveKill or historyKill then reason="kill_credited"
        elseif Analytics:IsSelfActor(victimName,victimId) then reason="self_death"
        elseif killer=="" then reason="missing_killer_source"
        elseif not playerVictim then reason="unknown_victim_kind"
        elseif not playerKiller then reason="unknown_killer_kind"
        elseif Analytics:GetCollectionScope()=="self" and not Analytics:IsSelfActor(killer) then reason="other_killer"
        else reason="live_credit_unavailable" end
        Evidence(fact,"decision",reason,victimName,killer,{confidence=confidence,playerVictim=playerVictim==true,
            selfDamageObserved=ledger and ledger.selfDamageObserved==true or false,liveKill=liveKill,historyKill=historyKill,upgraded=upgrade==true})
        death.liveKill=death.liveKill or liveKill;death.historyKill=death.historyKill or historyKill
        state.targets[victimName]=nil;if ledger and ledger.active then ledger.active=false;state.targetCount=math.max(0,state.targetCount-1) end
        state.revision=(tonumber(state.revision) or 0)+1
        return true
    end
    -- notice 可能先于带最后一击来源的 COMBAT_MSG。先保留1.5秒，直接事实到达即取消通知，
    -- 缺归属时只确认死亡，明确来源晚到仍可补证；所有通知共用一个有界 one-shot。
    local function ScheduleNotices(self)
        if self.state.noticeScheduled or self.state.noticeCount<=0 then return true end
        local scheduler=S.Scheduler
        if not scheduler or type(scheduler.AddOneShot)~="function" then return false end
        self.state.noticeScheduled=true
        local nextAt
        for _,row in pairs(self.state.notices) do if not nextAt or row.dueAt<nextAt then nextAt=row.dueAt end end
        if type(scheduler.SetTaskModule)=="function" then scheduler:SetTaskModule("v3_combat_kills_notices","combat_analytics",true) end
        local ok=scheduler:AddOneShot("v3_combat_kills_notices",math.max(50,(nextAt or C:NowMs())-C:NowMs()),function()
            self.state.noticeScheduled=false
            local now=C:NowMs();local changed=false
            for name,row in pairs(self.state.notices) do
                if row.dueAt<=now then
                    self.state.notices[name]=nil;self.state.noticeCount=math.max(0,self.state.noticeCount-1)
                    changed=CreditDeath(self.state,name,nil,nil,nil,row.at,"death_notice",nil,nil,
                        {kind="death_notice",subjectName=name,receivedAt=row.at,transport="private"}) or changed
                end
            end
            if changed then Analytics:NotifyMetricChanged("death_notices") end
            ScheduleNotices(self);return true
        end,self,"P3",1)
        if ok~=true then self.state.noticeScheduled=false end
        return ok==true
    end
    Analytics:RegisterMetric({id="kills",title="击杀玩家 / 死亡",category="combat",order=20,factCategories={"damage","death"},state=metric.state,
        -- 一个共享原生入口；不再叠加通用荣誉或地区累计提示，也不按金额/时间合并同额收益。
        -- HPW专用增量只作战争/纷争备用证据；没有此事件不能否定已确认的普通区域击杀。
        -- RU 客户端 combat_text.lua:634 明确将此参数作为战争荣誉正负增量消费。
        nativeEvents={"PLAYER_HONOR_POINT_CHANGED_IN_HPW"},
        OnNativeFact=function(self,fact)
            if fact.eventName~="PLAYER_HONOR_POINT_CHANGED_IN_HPW" then return false end
            local amount=C:Finite(fact.amount,nil)
            if not amount or amount<=0 or amount~=math.floor(amount) then return false end
            local name=C:Trim(fact.sourceName)
            if name=="" or not Analytics:IsSelfActor(name) then return false end
            -- 原始收益只作辅助证据；匹配击杀规则、排除助攻并配对明确通知后才补记统一击杀数。
            local live=false
            if Feature:IsMetricPreferenceEnabled("kills") then
                local actor=C:EnsureActor(self.state,name)
                if actor then
                    C:AddCounter(actor,"honorParticipations",1)
                    C:Touch(actor,At(fact));live=true
                end
            end
            local history=Feature.PersonalHistory
            local saved=history and history:Record({honorParticipations=1})==true or false
            Evidence(fact,"decision","war_honor_received",nil,name,
                {honorAmount=amount,killAttribution="unavailable",liveParticipation=live,historyParticipation=saved})
            local assisted=QueueHonor(self,fact,name,amount)
            if live or saved then self.state.revision=(tonumber(self.state.revision) or 0)+1 end
            return live or saved or assisted
        end,
        description="统一击杀：明确归属优先，本人野外荣誉辅助补记；排除已知助攻3/12，匹配已确认金额，一对一配对避免重复。",
        OnFact=function(self,fact)
            -- 首个可见事实建立系统资料证据；伤害热路径只检查一次标记，不为每条伤害安排 Native 采样。
            if not self.state.systemEvidenceStarted then
                self.state.systemEvidenceStarted=true
                if type(Feature.ScheduleSystemKillEvidence)=="function" then Feature:ScheduleSystemKillEvidence("first_combat_fact") end
            end
            if fact.category=="damage" then return RecordDamage(self.state,fact) end
            local now=At(fact);local victim=TargetName(fact)
            if fact.kind=="kill_notice" and Analytics:IsSelfActor(fact.sourceName,fact.sourceId) then
                if type(Feature.ScheduleSystemKillEvidence)=="function" then Feature:ScheduleSystemKillEvidence("self_kill_notice") end
                if fact.rawEventType=="UNIT_KILL_STREAK" and fact.rawNotice3==5 then
                    local count=C:Finite(fact.rawNotice2,nil)
                    if count and count>=1 and count==math.floor(count) and count<=2147483647 then
                        if nativeCounter and count>nativeCounter.high+1 then
                            Evidence(fact,"notice","native_counter_gap",victim,fact.sourceName,
                                {previousCount=nativeCounter.high,nativeCount=count,missingNotifications=count-nativeCounter.high-1,credited=false})
                        end
                        -- 下降可能是新一轮或迟到通知，原样留证，不能把未知生命周期包装成确定的补记。
                        if nativeCounter and count<nativeCounter.high then
                            Evidence(fact,"notice","native_counter_decreased",victim,fact.sourceName,{previousCount=nativeCounter.high,nativeCount=count,credited=false})
                        end
                        nativeCounter={high=count,at=now}
                    end
                end
            end
            -- NPC击杀已删除；只忽略NPC作为死者，自身被怪物击杀仍记录死亡。
            if KnownKind(victim,fact.targetKind)=="NPC" and not Analytics:IsSelfActor(victim,fact.targetId) then return false end
            if fact.kind=="death_notice" and not Analytics:IsSelfActor(victim) then
                local last=self.state.deathByName[victim]
                if last and now-last.at<1200 then Evidence(fact,"notice","duplicate_death",victim);return false end
                if self.state.notices[victim] then Evidence(fact,"notice","duplicate_notice",victim);return false end
                if self.state.noticeCount<512 then
                    self.state.notices[victim]={at=now,dueAt=now+1500};self.state.noticeCount=self.state.noticeCount+1
                    if ScheduleNotices(self) then Evidence(fact,"notice","notice_waiting",victim);return false end
                    Evidence(fact,"notice","notice_schedule_failed",victim)
                    self.state.notices[victim]=nil;self.state.noticeCount=self.state.noticeCount-1
                end
            end
            if self.state.notices[victim] then self.state.notices[victim]=nil;self.state.noticeCount=math.max(0,self.state.noticeCount-1) end
            return CreditDeath(self.state,victim,fact.targetId,fact.kind~="death_notice" and fact.sourceName or nil,AbilityName(fact),now,
                fact.kind=="death_notice" and "death_notice" or (fact.kind=="kill_notice" and "native_kill_notice" or "direct_death_source"),fact.targetKind,fact.sourceKind,fact)
        end,
        GetDiagnosticDetail=function(self)
            local rows,counters={},{}
            C:QueueEach(evidence.events,function(row)local copy={} for key,value in pairs(row) do copy[key]=value end rows[#rows+1]=copy end)
            for key,value in pairs(evidence.counters) do counters[key]=value end
            return {available=true,scope=Analytics:GetCollectionScope(),events=rows,counters=counters,
                honorRetained=#self.state.honorReceipts,explicitRetained=#self.state.explicitReceipts,pairingWindowMs=HONOR_WINDOW,
                evicted=evidence.events.evicted,limit=32,pendingNotices=self.state.noticeCount,trackedTargets=self.state.targetCount,
                nativeCounter=nativeCounter and {high=nativeCounter.high,at=nativeCounter.at} or nil,
                coverage="本代明确归属及荣誉辅助判定；已知助攻3/12排除，已确认金额在8秒窗内一对一配对，补记等待1.5秒。未收到、超窗或淘汰事件不能准确还原。"}
        end,
        GetProjection=function(self,opt)
            if opt and opt.actorKey~=nil then return SkillKillProjection(self.state,opt) end
            local key=tostring(opt and opt.valueKey or "kills");if key~="kills" and key~="deaths" and key~="honorParticipations" then key="kills" end
            local limit=math.max(1,math.min(MAX_ACTORS,tonumber(opt and opt.limit) or 100))
            return {valueKey=key,rows=KillRanking(self,key,limit,opt and opt.includeZero==true),
                dataRevision=tonumber(self.state.revision) or 0,statsAvailable=Feature:IsMetricPreferenceEnabled("kills"),
                assistsAvailable=false,coverage=key=="honorParticipations" and "SELF_HPW_POSITIVE_RECEIPTS" or "EXPLICIT_WITH_SELF_HPW_SUPPLEMENT"}
        end,
        Reset=function(self,reason,resetKind)
            ClearReadCache() -- inactive 保留计数，但停用必须立即释放排序/技能快照。
            if S.Scheduler then S.Scheduler:RemoveTask("v3_combat_kills_notices") end
            if S.Scheduler then S.Scheduler:RemoveTask("v3_combat_kills_honor") end
            if type(Feature.CancelSystemKillEvidence)=="function" then Feature:CancelSystemKillEvidence() end
            nativeCounter=nil;self.state.systemEvidenceStarted=nil -- 停止/清空/换范围均切断取证基线，不补采未观测区间。
            -- 停用仅释放最近一击和通知任务，五项总览的实时战绩保留；显式清空或换范围才归零。
            if resetKind=="inactive" then Init(self.state);return true end
            local revision=(tonumber(self.state.revision) or 0)+1
            self.state=C:NewActorState(MAX_ACTORS);self.state.revision=revision;Init(self.state);metric.state=self.state;return true
        end,
        GetHealth=function(self) return {actors=self.state.actorCount,recentTargets=self.state.targetCount,pendingDeathNotices=self.state.noticeCount,actorOverflow=self.state.actorOverflow} end})
end

-- 3. 技能活动、SELF 原生精确施法与起手序列。
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
            -- 同次施法的 Native START 可能略晚于推断的战斗活动；应提升证据等级，不能重复添加起手记录。
            if exact==true then lastOpener.confidence=openerConfidence;lastOpener.exact=true end
        elseif actor.opener.count<12 then
            C:QueuePush(actor.opener,{at=now,skill=skill.name,confidence=openerConfidence,exact=exact==true})
        end
        return true
    end
    Analytics:RegisterMetric({id="casts",suspended=true,title="技能释放 / 起手",category="combat",order=30,factCategories={"damage","heal","other"},nativeEvents={"SPELLCAST_START"},state=metric.state,
        description="团队技能次数由战斗活动保守推导；本机 SPELLCAST_START+静态技能ID命中提供精确施法证据。",
        OnFact=function(self,fact) return Activity(self,fact,false) end,
        OnNativeFact=function(self,fact) if fact.kind~="cast_start" or fact.abilityId==nil then return false end;return Activity(self,fact,true) end,
        GetProjection=function(self,opt) local key=tostring(opt and opt.valueKey or "skillActivities");if key~="skillActivities" and key~="exactCasts" then key="skillActivities" end;local rows=Rank(self,key,{"skillActivities","exactCasts"},100);for _,row in ipairs(rows) do local actor=self.state.actors[row.key];row.opener=actor and C:QueueToArray(actor.opener,false,12) or {} end;return {valueKey=key,rows=rows,nativeCoverage=Analytics.nativeCoverage,coverage="TEAM_ACTIVITY_INFERRED_SELF_NATIVE_EXACT_WHEN_AVAILABLE"} end,
        Reset=function(self) return ResetActor(self) end,GetHealth=function(self) return {actors=self.state.actorCount} end})
end

-- 4. 爆发、最高单次命中与生存观察。
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
    Analytics:RegisterMetric({id="performance",suspended=true,title="爆发 / 生存",category="combat",order=40,factCategories={"damage","death"},state=metric.state,
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

-- 5. 控制活动、观察到的命中与持续时长。
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
    Analytics:RegisterMetric({id="control",suspended=true,title="控制",category="utility",order=50,factCategories={"damage","heal","other","aura"},state=metric.state,
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

-- 6. 吟游、乐器持续时长与观察覆盖。
do
    local metric={state=C:NewActorState(MAX_ACTORS)};metric.state.selfActiveSong=nil;metric.state.activeBuffs={};metric.state.activeBuffCount=0;metric.state.activeBuffOverflow=0
    local function Song(id) local r=type(AbilityCatalog)=="table" and AbilityCatalog:GetSkill(id) or nil;return r and r.songcraft==true and r or nil end
    local function CloseSelf(self,now,reason)
        local open=self.state.selfActiveSong;if open==nil then return false end;local actor=self.state.actors[open.actorKey];if actor then local duration=math.max(0,now-(tonumber(open.at) or now));C:AddCounter(actor,"songMs",duration);AddDetail(actor,"songDurationBySkill",open.name,duration);actor.lastSongStopReason=reason end;self.state.selfActiveSong=nil;return true
    end
    Analytics:RegisterMetric({id="songcraft",suspended=true,title="乐器 / 演奏",category="support",order=60,factCategories={"damage","heal","other","aura"},nativeEvents={"SPELLCAST_START","SPELLCAST_STOP"},state=metric.state,
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
                -- 有 START 无 STOP 只能证明施法，不能证明时长；禁止依据下一次 START 或墙钟经过推断歌曲覆盖时间。
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

-- 7. 辅助活动：打断、驱散、净化、复活与防御。
do
    local metric={state=C:NewActorState(MAX_ACTORS)}
    local function Apply(self,fact,exact)
        local row=type(AbilityCatalog)=="table" and AbilityCatalog:GetSkill(AbilityId(fact)) or nil;if row==nil or #row.utilityTypes==0 then return false end
        local actor=C:EnsureActor(self.state,fact.sourceName,fact.sourceId);if actor==nil then return false end;local now=At(fact);actor.utilityLast=actor.utilityLast or {};if exact~=true and now-(tonumber(actor.utilityLast[row.id]) or -999999)<300 then return false end;actor.utilityLast[row.id]=now;C:Touch(actor,now);C:AddCounter(actor,exact and "utilityExact" or "utilityActivities",1);for _,t in ipairs(row.utilityTypes) do C:AddCounter(actor,t,1);AddDetail(actor,"utilityTypes",t,1) end;AddDetail(actor,exact and "utilitySkillsExact" or "utilitySkills",row.name,1);actor.utilityConfidence=exact and "self_native_catalog_match" or row.utilityConfidence;return true
    end
    Analytics:RegisterMetric({id="utility",suspended=true,title="辅助贡献",category="utility",order=70,factCategories={"damage","heal","other"},nativeEvents={"SPELLCAST_START"},state=metric.state,
        description="打断、驱散/净化、复活、防御技能的使用活动；成功效果需要后续更强事件证据，本机Native只证明施法。",
        OnFact=function(self,fact) return Apply(self,fact,false) end,OnNativeFact=function(self,fact) if fact.kind~="cast_start" then return false end;return Apply(self,fact,true) end,
        GetProjection=function(self,opt) local key=tostring(opt and opt.valueKey or "utilityActivities");local allowed={utilityActivities=true,utilityExact=true,interrupt=true,dispel=true,cleanse=true,resurrection=true,defensive=true};if not allowed[key] then key="utilityActivities" end;return {valueKey=key,rows=Rank(self,key,{"utilityActivities","utilityExact","interrupt","dispel","cleanse","resurrection","defensive","utilityConfidence"},100),coverage="CATALOG_ACTIVITY_SELF_NATIVE_ENRICHMENT"} end,
        Reset=function(self) return ResetActor(self) end,GetHealth=function(self) return {actors=self.state.actorCount} end})
end

-- 8. 观察到的 Buff/Debuff 覆盖时长。
do
    local metric={state=C:NewActorState(MAX_ACTORS)};metric.state.active={};metric.state.activeCount=0;metric.state.activeOverflow=0
    Analytics:RegisterMetric({id="aura",suspended=true,title="Buff / Debuff 覆盖",category="support",order=80,factCategories={"aura"},state=metric.state,
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

-- 9. 首领机制：仅使用静态目录精确观察。
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
    Analytics:RegisterMetric({id="mechanics",suspended=true,title="Boss 机制",category="mechanics",order=90,factCategories={"damage","heal","other","aura"},state=metric.state,
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

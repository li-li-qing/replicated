------------------------------------------------------------------------
-- Replicated Suite V3 - Combat Analytics Runtime / Metric Registry
--
-- One all-scope CombatEventBus consumer fans borrowed immutable facts into
-- independent, bounded metric plugins. Optional native enrichment is shared and
-- may degrade without failing the combat fact pipeline.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Services = S.Services or {}

local A = {
    Id = "v3.combat_analytics",
    version = 3,
    metrics = {}, metricOrder = {},
    activeMetrics = {}, activeMetricOrder = {},
    factPlans = {}, nativePlans = {},
    consumers = {}, consumerCount = 0,
    busSubscribed = false,
    nativeSubscribed = {}, nativeCoverage = {},
    factsReceived = 0, metricDispatches = 0, metricErrors = 0, metricMutations = 0, nativeFacts = 0,
    projectionRevision = 0, publishScheduled = false, publishTask = "v3_combat_analytics_publish",
}
A.presentationBoundary = "service_only"
S.Services.CombatAnalyticsV3 = A

local FACT_CATEGORIES = { "damage", "heal", "death", "aura", "miss", "other" }
local function Trace(err) return type(S.SafeTraceback) == "function" and S.SafeTraceback(err) or tostring(err) end
local function RunMetricReset(metric, reason)
    if type(metric) ~= "table" or type(metric.Reset) ~= "function" then return false, "metric reset unavailable" end
    local ok, result, err = xpcall(function() return metric.Reset(metric, reason or "reset") end, Trace)
    if ok ~= true then return false, result end
    if result == false then return false, err or "metric reset rejected" end
    return true
end
local function Emit(level, code, message, context)
    local diag = S.DiagnosticsManager
    if type(diag) == "table" and type(diag.RateLimited) == "function" then diag:RateLimited(level, "combat_analytics", code, 3000, message, context)
    elseif type(diag) == "table" and type(diag.Emit) == "function" then diag:Emit(level, "combat_analytics", code, message, context) end
end
local function NormalizeId(value)
    return tostring(value or ""):lower():gsub("[^%w_%.%-]", "_"):gsub("_+", "_"):gsub("^_+", ""):gsub("_+$", "")
end
local function NormalizeCategorySet(values)
    if type(values) ~= "table" then return nil end
    local set = {}
    for _, value in ipairs(values) do
        local key = tostring(value or ""):lower()
        if key ~= "" then set[key] = true end
    end
    return next(set) ~= nil and set or nil
end
local function NormalizeOptions(options)
    local ids, seen = {}, {}
    for _, value in ipairs(type(options) == "table" and type(options.metrics) == "table" and options.metrics or {}) do
        local id = NormalizeId(value)
        if id ~= "" and seen[id] ~= true then seen[id] = true; ids[#ids + 1] = id end
    end
    table.sort(ids)
    return { metrics = ids }
end
local function BuildActiveSet(snapshot)
    local set = {}
    for _, options in pairs(type(snapshot) == "table" and type(snapshot.consumers) == "table" and snapshot.consumers or {}) do
        for _, id in ipairs(type(options) == "table" and type(options.metrics) == "table" and options.metrics or {}) do set[id] = true end
    end
    return set
end
local function SortedActive(runtime, set)
    local rows = {}
    for _, id in ipairs(runtime.metricOrder) do if set[id] == true and runtime.metrics[id] ~= nil then rows[#rows + 1] = id end end
    return rows
end
local function ActiveNativeEvents(runtime, activeSet)
    local set = {}
    for id in pairs(activeSet) do
        local metric = runtime.metrics[id]
        for _, eventName in ipairs(type(metric) == "table" and type(metric.nativeEvents) == "table" and metric.nativeEvents or {}) do
            eventName = tostring(eventName or "")
            if eventName ~= "" then set[eventName] = true end
        end
    end
    return set
end

function A:RegisterMetric(spec)
    spec = type(spec) == "table" and spec or {}
    local id = NormalizeId(spec.id)
    if id == "" then return false, "metric id required" end
    if self.metrics[id] ~= nil then return false, "metric already registered: " .. id end
    local row = {
        id = id, title = tostring(spec.title or id), description = tostring(spec.description or ""),
        category = tostring(spec.category or "general"), order = tonumber(spec.order) or 100, hidden = spec.hidden == true,
        nativeEvents = type(spec.nativeEvents) == "table" and spec.nativeEvents or {}, factCategories = NormalizeCategorySet(spec.factCategories),
        OnFact = type(spec.OnFact) == "function" and spec.OnFact or nil,
        OnNativeFact = type(spec.OnNativeFact) == "function" and spec.OnNativeFact or nil,
        GetProjection = type(spec.GetProjection) == "function" and spec.GetProjection or nil,
        Reset = type(spec.Reset) == "function" and spec.Reset or nil,
        GetHealth = type(spec.GetHealth) == "function" and spec.GetHealth or nil,
        state = type(spec.state) == "table" and spec.state or {}, owner = spec.owner,
    }
    self.metrics[id] = row
    self.metricOrder[#self.metricOrder + 1] = id
    table.sort(self.metricOrder, function(a, b)
        local l, r = self.metrics[a], self.metrics[b]
        if l.order ~= r.order then return l.order < r.order end
        return a < b
    end)
    return true, row
end
function A:UnregisterMetric(id)
    id = NormalizeId(id)
    if self.activeMetrics[id] == true then return false, "active metric cannot unregister" end
    if self.metrics[id] == nil then return false, "metric missing" end
    self.metrics[id] = nil
    local rows = {}; for _, existing in ipairs(self.metricOrder) do if existing ~= id then rows[#rows + 1] = existing end end
    self.metricOrder = rows
    return true
end
function A:GetMetric(id) return self.metrics[NormalizeId(id)] end
function A:ListMetrics(includeHidden)
    local rows = {}
    for _, id in ipairs(self.metricOrder) do
        local metric = self.metrics[id]
        if metric ~= nil and (includeHidden == true or metric.hidden ~= true) then
            rows[#rows + 1] = { id=id, title=metric.title, description=metric.description, category=metric.category, order=metric.order, active=self.activeMetrics[id] == true }
        end
    end
    return rows
end

function A:_SchedulePublish(reason)
    if self.publishScheduled == true then return true end
    local scheduler = S.Scheduler
    if type(scheduler) ~= "table" or type(scheduler.AddOneShot) ~= "function" then
        self.projectionRevision = self.projectionRevision + 1
        if S.Events and type(S.Events.Publish) == "function" then S.Events:Publish("v3.combat_analytics.updated", tostring(reason or "fact"), self.projectionRevision) end
        return true
    end
    self.publishScheduled = true
    if type(scheduler.SetTaskModule) == "function" then scheduler:SetTaskModule(self.publishTask, "combat_analytics", true) end
    local ok = scheduler:AddOneShot(self.publishTask, 350, function()
        A.publishScheduled = false
        A.projectionRevision = A.projectionRevision + 1
        if S.Events and type(S.Events.Publish) == "function" then S.Events:Publish("v3.combat_analytics.updated", tostring(reason or "fact"), A.projectionRevision) end
        return true
    end, self, "P3", 1)
    if ok ~= true then self.publishScheduled = false end
    return ok == true
end
function A:NotifyMetricChanged(reason)
    return self:_SchedulePublish(reason or "metric_changed")
end

local function RestoreCombatFact(fact, v)
    fact.schemaVersion, fact.sequence, fact.receivedAt, fact.transport = v.schemaVersion, v.sequence, v.receivedAt, v.transport
    fact.kind, fact.category, fact.environmental, fact.amount = v.kind, v.category, v.environmental, v.amount
    fact.sourceName, fact.targetName, fact.sourceId, fact.targetId = v.sourceName, v.targetName, v.sourceId, v.targetId
    fact.sourceKind, fact.targetKind, fact.abilityName = v.sourceKind, v.targetKind, v.abilityName
    fact.boundRole, fact.boundConfidence = v.boundRole, v.boundConfidence
    fact.rawUnitId, fact.rawEventType, fact.rawAbilityId = v.rawUnitId, v.rawEventType, v.rawAbilityId
    fact.rawDamageType, fact.rawEffectType, fact.rawIsActive = v.rawDamageType, v.rawEffectType, v.rawIsActive
    fact.rawMore1, fact.rawMore2, fact.rawMore3, fact.rawMore4, fact.rawMore5 = v.rawMore1, v.rawMore2, v.rawMore3, v.rawMore4, v.rawMore5
    fact.subjectName, fact.rawNotice2, fact.rawNotice3, fact.rawNotice4, fact.rawNotice5 = v.subjectName, v.rawNotice2, v.rawNotice3, v.rawNotice4, v.rawNotice5
    fact.auraType, fact.auraId, fact.auraName, fact.auraEvidence = v.auraType, v.auraId, v.auraName, v.auraEvidence
end
local function CombatFactChanged(fact, v)
    return fact.schemaVersion ~= v.schemaVersion or fact.sequence ~= v.sequence or fact.receivedAt ~= v.receivedAt or fact.transport ~= v.transport
        or fact.kind ~= v.kind or fact.category ~= v.category or fact.environmental ~= v.environmental or fact.amount ~= v.amount
        or fact.sourceName ~= v.sourceName or fact.targetName ~= v.targetName or fact.sourceId ~= v.sourceId or fact.targetId ~= v.targetId
        or fact.sourceKind ~= v.sourceKind or fact.targetKind ~= v.targetKind or fact.abilityName ~= v.abilityName
        or fact.boundRole ~= v.boundRole or fact.boundConfidence ~= v.boundConfidence
        or fact.rawUnitId ~= v.rawUnitId or fact.rawEventType ~= v.rawEventType or fact.rawAbilityId ~= v.rawAbilityId
        or fact.rawDamageType ~= v.rawDamageType or fact.rawEffectType ~= v.rawEffectType or fact.rawIsActive ~= v.rawIsActive
        or fact.rawMore1 ~= v.rawMore1 or fact.rawMore2 ~= v.rawMore2 or fact.rawMore3 ~= v.rawMore3 or fact.rawMore4 ~= v.rawMore4 or fact.rawMore5 ~= v.rawMore5
        or fact.subjectName ~= v.subjectName or fact.rawNotice2 ~= v.rawNotice2 or fact.rawNotice3 ~= v.rawNotice3 or fact.rawNotice4 ~= v.rawNotice4 or fact.rawNotice5 ~= v.rawNotice5
        or fact.auraType ~= v.auraType or fact.auraId ~= v.auraId or fact.auraName ~= v.auraName or fact.auraEvidence ~= v.auraEvidence
end
function A:_DispatchFact(fact)
    if type(fact) ~= "table" then return false end
    self.factsReceived = self.factsReceived + 1
    -- One compact scalar snapshot protects sibling metrics from each other. The
    -- parent CombatEventBus still applies its own full consumer fence as well.
    local v = {
        schemaVersion=fact.schemaVersion, sequence=fact.sequence, receivedAt=fact.receivedAt, transport=fact.transport,
        kind=fact.kind, category=fact.category, environmental=fact.environmental, amount=fact.amount,
        sourceName=fact.sourceName, targetName=fact.targetName, sourceId=fact.sourceId, targetId=fact.targetId,
        sourceKind=fact.sourceKind, targetKind=fact.targetKind, abilityName=fact.abilityName,
        boundRole=fact.boundRole, boundConfidence=fact.boundConfidence,
        rawUnitId=fact.rawUnitId, rawEventType=fact.rawEventType, rawAbilityId=fact.rawAbilityId,
        rawDamageType=fact.rawDamageType, rawEffectType=fact.rawEffectType, rawIsActive=fact.rawIsActive,
        rawMore1=fact.rawMore1, rawMore2=fact.rawMore2, rawMore3=fact.rawMore3, rawMore4=fact.rawMore4, rawMore5=fact.rawMore5,
        subjectName=fact.subjectName, rawNotice2=fact.rawNotice2, rawNotice3=fact.rawNotice3, rawNotice4=fact.rawNotice4, rawNotice5=fact.rawNotice5,
        auraType=fact.auraType, auraId=fact.auraId, auraName=fact.auraName, auraEvidence=fact.auraEvidence,
    }
    local plan = self.factPlans[tostring(fact.category or "other"):lower()] or self.factPlans.other or {}
    local changed = false
    for _, id in ipairs(plan) do
        local metric = self.metrics[id]
        if metric and type(metric.OnFact) == "function" then
            local ok, result = xpcall(function() return metric.OnFact(metric, fact, A) end, Trace)
            self.metricDispatches = self.metricDispatches + 1
            if CombatFactChanged(fact, v) then
                self.metricMutations = self.metricMutations + 1
                RestoreCombatFact(fact, v)
                Emit("error", "COMBAT_METRIC_MUTATED_FACT", "战斗分析指标修改了 borrowed CombatFact，已恢复", { metric=id })
            end
            if ok ~= true then self.metricErrors = self.metricErrors + 1; Emit("error", "COMBAT_METRIC_FAILED", "战斗分析指标处理失败", { metric=id, error=tostring(result) })
            elseif result == true then changed = true end
        end
    end
    if changed then self:_SchedulePublish("combat_fact") end
    return changed
end

local function DetectSkillId(args, argCount)
    local catalog = S.Data and S.Data.CombatAbilityCatalog or nil
    if type(catalog) ~= "table" then return nil end
    for index = 1, math.min(tonumber(argCount) or 0, 12) do
        local raw = args[index]
        local value = tonumber(raw)
        if value ~= nil and catalog.BySkillId[value] ~= nil then return value end
        if type(raw) == "table" then
            for _, key in ipairs({ "skillId", "skill_id", "skillType", "skill_type" }) do
                value = tonumber(raw[key]); if value ~= nil and catalog.BySkillId[value] ~= nil then return value end
            end
        end
    end
    return nil
end
local function DetectCasterToken(eventName, args, argCount)
    local index = eventName == "SPELLCAST_START" and 3 or 1
    if index > (tonumber(argCount) or 0) then return nil end
    return type(args[index]) == "string" and args[index] or nil
end
local function PlayerName()
    if X2Unit ~= nil and type(X2Unit.UnitName) == "function" then
        local ok, value = pcall(function() return X2Unit:UnitName("player") end)
        if ok and value ~= nil then return tostring(value) end
    end
    return ""
end
function A:_OnNativeEvent(eventName, ...)
    local args, count = { ... }, select("#", ...)
    local caster = DetectCasterToken(eventName, args, count)
    if caster ~= "player" then return false end
    self.nativeFacts = self.nativeFacts + 1
    local skillId = DetectSkillId(args, count)
    local catalog = S.Data and S.Data.CombatAbilityCatalog or nil
    local skill = type(catalog) == "table" and catalog:GetSkill(skillId) or nil
    local fact = {
        schemaVersion=1, native=true, eventName=tostring(eventName or ""),
        kind=eventName == "SPELLCAST_START" and "cast_start" or (eventName == "SPELLCAST_STOP" and "cast_stop" or (eventName == "SPELLCAST_SUCCEEDED" and "cast_succeeded" or "native_event")),
        receivedAt=math.max(0, tonumber(S.NowMs and S.NowMs()) or 0), sourceName=PlayerName(), casterToken=caster,
        abilityId=skillId, abilityName=skill and tostring(skill.name or "") or "", rawArgCount=count,
        confidence=skillId ~= nil and "self_native_catalog_match" or "self_native_event_only",
    }
    local sv,sn,se,sk,sr,ss,sc,si,sa,sg = fact.schemaVersion,fact.native,fact.eventName,fact.kind,fact.receivedAt,fact.sourceName,fact.casterToken,fact.abilityId,fact.abilityName,fact.confidence
    local changed = false
    for _, id in ipairs(self.nativePlans[eventName] or {}) do
        local metric = self.metrics[id]
        if metric and type(metric.OnNativeFact) == "function" then
            local ok, result = xpcall(function() return metric.OnNativeFact(metric, fact, A) end, Trace)
            if fact.schemaVersion~=sv or fact.native~=sn or fact.eventName~=se or fact.kind~=sk or fact.receivedAt~=sr or fact.sourceName~=ss or fact.casterToken~=sc or fact.abilityId~=si or fact.abilityName~=sa or fact.confidence~=sg then
                self.metricMutations = self.metricMutations + 1
                fact.schemaVersion,fact.native,fact.eventName,fact.kind,fact.receivedAt,fact.sourceName,fact.casterToken,fact.abilityId,fact.abilityName,fact.confidence=sv,sn,se,sk,sr,ss,sc,si,sa,sg
                Emit("error", "COMBAT_METRIC_MUTATED_NATIVE_FACT", "战斗分析指标修改了共享 NativeFact，已恢复", { metric=id,event=eventName })
            end
            if ok ~= true then self.metricErrors=self.metricErrors+1; Emit("error","COMBAT_METRIC_NATIVE_FAILED","战斗分析指标处理原生增强事件失败",{metric=id,event=eventName,error=tostring(result)})
            elseif result == true then changed = true end
        end
    end
    if changed then self:_SchedulePublish("native_fact") end
    return changed
end

function A:_SubscribeBus()
    if self.busSubscribed == true then return true end
    local bus = S.Services and S.Services.CombatEventBusV3 or nil
    if type(bus) ~= "table" or type(bus.Subscribe) ~= "function" then return false, "CombatEventBus unavailable" end
    local ok, err = bus:Subscribe(self, function(_, fact) A:_DispatchFact(fact) end, { scope="all" })
    if ok ~= true then return false, err end
    self.busSubscribed = true
    return true
end
function A:_UnsubscribeBus()
    if self.busSubscribed ~= true then return true end
    local bus = S.Services and S.Services.CombatEventBusV3 or nil
    if type(bus) ~= "table" or type(bus.Unsubscribe) ~= "function" then return false, "CombatEventBus release unavailable" end
    local ok, err = bus:Unsubscribe(self)
    if ok ~= true then return false, err end
    self.busSubscribed = false
    return true
end
function A:_ReconcileNative(activeSet)
    local needed = ActiveNativeEvents(self, activeSet)
    local events = S.Events
    if type(events) ~= "table" or type(events.SubscribeOptional) ~= "function" then
        for eventName in pairs(needed) do self.nativeCoverage[eventName] = "UNAVAILABLE" end
        return true
    end
    local existingNames = {}
    for eventName in pairs(self.nativeSubscribed) do existingNames[#existingNames+1] = eventName end
    for _, eventName in ipairs(existingNames) do
        if needed[eventName] ~= true then
            if type(events.Unsubscribe) == "function" then events:Unsubscribe(eventName, self) end
            self.nativeSubscribed[eventName] = nil; self.nativeCoverage[eventName] = "INACTIVE"
        end
    end
    for eventName in pairs(needed) do
        if self.nativeSubscribed[eventName] ~= true then
            local nativeEvent = eventName
            local ok = events:SubscribeOptional(nativeEvent, self, function(_, ...) A:_OnNativeEvent(nativeEvent, ...) end)
            if ok == true then self.nativeSubscribed[nativeEvent] = true; self.nativeCoverage[nativeEvent] = "FULL"
            else self.nativeCoverage[nativeEvent] = "UNAVAILABLE" end
        end
    end
    return true
end
function A:_CompilePlans(activeSet)
    local factPlans, nativePlans = {}, {}
    for _, category in ipairs(FACT_CATEGORIES) do factPlans[category] = {} end
    local order = SortedActive(self, activeSet)
    for _, id in ipairs(order) do
        local metric = self.metrics[id]
        if metric.factCategories == nil then
            for _, category in ipairs(FACT_CATEGORIES) do factPlans[category][#factPlans[category]+1] = id end
        else
            for category in pairs(metric.factCategories) do factPlans[category] = factPlans[category] or {}; factPlans[category][#factPlans[category]+1] = id end
        end
        if type(metric.OnNativeFact) == "function" then
            for _, eventName in ipairs(metric.nativeEvents or {}) do
                eventName=tostring(eventName or ""); if eventName~="" then nativePlans[eventName]=nativePlans[eventName] or {}; nativePlans[eventName][#nativePlans[eventName]+1]=id end
            end
        end
    end
    return order, factPlans, nativePlans
end
function A:_ApplyActiveSet(activeSet, reason)
    local previous = self.activeMetrics
    for id in pairs(previous) do
        if activeSet[id] ~= true then
            local metric = self.metrics[id]
            if metric and type(metric.Reset) == "function" then
                local ok, err = RunMetricReset(metric, reason or "disabled")
                if ok ~= true then
                    self.metricErrors=self.metricErrors+1
                    Emit("error","COMBAT_METRIC_RESET_FAILED","战斗指标释放状态失败",{metric=id,error=tostring(err)})
                    return false, "metric reset failed: " .. tostring(id) .. ": " .. tostring(err)
                end
            end
        end
    end
    local order, factPlans, nativePlans = self:_CompilePlans(activeSet)
    self.activeMetrics, self.activeMetricOrder, self.factPlans, self.nativePlans = activeSet, order, factPlans, nativePlans
    self:_ReconcileNative(activeSet)
    return true
end
function A:_ReconcileDemand(_, before, after, context)
    local beforeCount, afterCount = tonumber(before and before.count) or 0, tonumber(after and after.count) or 0
    local activeSet = BuildActiveSet(after)
    for id in pairs(activeSet) do if self.metrics[id] == nil then return false, "unknown combat metric: " .. tostring(id) end end
    if beforeCount <= 0 and afterCount > 0 then
        local ok, err = self:_SubscribeBus(); if ok ~= true then return false, err end
    end
    if beforeCount > 0 and afterCount <= 0 then
        -- Release can fail on some native builds; do not erase metric session
        -- state until the downstream lease transition really succeeded.
        local ok, err = self:_UnsubscribeBus(); if ok ~= true then return false, err end
    end
    local applied, applyErr = self:_ApplyActiveSet(activeSet, type(context)=="table" and context.reason or "demand")
    if applied ~= true then return false, applyErr end
    return true
end

if S.Demand == nil or type(S.Demand.Create) ~= "function" then error("Demand unavailable for CombatAnalyticsV3") end
local lease, leaseErr = S.Demand:Create({
    id="service.combat_analytics", owner=A, normalize=NormalizeOptions, projectionOwner=A,
    projectionConsumersField="consumers", projectionCountField="consumerCount",
    reconcile=function(leaseObj,before,after,context) return A:_ReconcileDemand(leaseObj,before,after,context) end,
    quiesce=function()
        A:_ReconcileNative({})
        local ok = A:_UnsubscribeBus()
        for _, id in ipairs(A.metricOrder) do
            local metric=A.metrics[id]
            if metric and type(metric.Reset)=="function" then
                local resetOk = RunMetricReset(metric,"quiesce")
                if resetOk ~= true then ok = false end
            end
        end
        A.activeMetrics,A.activeMetricOrder,A.factPlans,A.nativePlans={},{},{},{}
        A.publishScheduled=false
        if S.Scheduler and type(S.Scheduler.RemoveTask)=="function" then S.Scheduler:RemoveTask(A.publishTask) end
        return ok
    end,
})
if lease == nil then error(leaseErr) end
A.Demand = lease
local function HasRequestedMetrics(options)
    local normalized = NormalizeOptions(options)
    return #normalized.metrics > 0, normalized
end
function A:HasConsumer(token)
    token = tostring(token or "")
    return token ~= "" and self.Demand:Has(token) == true
end
function A:AcquireConsumer(token, options, reason)
    token = tostring(token or "")
    if token == "" then return false, "consumer token required" end
    local hasMetrics, normalized = HasRequestedMetrics(options)
    if hasMetrics ~= true then return false, "combat analytics consumer requires at least one metric" end
    return self.Demand:Acquire(token, normalized, reason or "analytics_acquire")
end
function A:ReleaseConsumer(token, reason)
    token = tostring(token or "")
    if token == "" or self.Demand:Has(token) ~= true then return true end
    return self.Demand:Release(token, reason or "analytics_release")
end
function A:UpdateConsumer(token, options, reason)
    token = tostring(token or "")
    if token == "" then return false, "consumer token required" end
    local hasMetrics, normalized = HasRequestedMetrics(options)
    if hasMetrics ~= true then
        if self.Demand:Has(token) == true then return self.Demand:Release(token, reason or "analytics_empty_release") end
        return true, false
    end
    return self.Demand:Acquire(token, normalized, reason or "analytics_update")
end
function A:GetMetricProjection(id, options)
    local metric=self.metrics[NormalizeId(id)]; if metric==nil then return nil,"metric missing" end
    local value={}
    if type(metric.GetProjection)=="function" then local ok,result=xpcall(function() return metric.GetProjection(metric,options or {},self) end,Trace); if ok~=true then return nil,result end; value=type(result)=="table" and result or {} end
    value.id,value.title,value.revision,value.active=metric.id,metric.title,self.projectionRevision,self.activeMetrics[metric.id]==true
    return value
end

-- Bounded actor drill-down projection. Metric plugin state stays private to the
-- Analytics Authority; Presentation never reads metric.state directly. Only
-- scalar actor fields, bounded detail maps and the bounded opener queue are
-- copied out. This runs on explicit UI selection/refresh, not on combat facts.
function A:GetMetricActorDetail(id, actorKey, options)
    local metric = self.metrics[NormalizeId(id)]
    if metric == nil then return nil, "metric missing" end
    actorKey = tostring(actorKey or "")
    if actorKey == "" then return nil, "actor key required" end
    options = type(options) == "table" and options or {}
    local maxSections = math.max(1, math.min(12, math.floor(tonumber(options.maxSections) or 8)))
    local maxRows = math.max(1, math.min(64, math.floor(tonumber(options.limit) or 24)))
    local state = type(metric.state) == "table" and metric.state or nil
    local actor = state and type(state.actors) == "table" and state.actors[actorKey] or nil
    if type(actor) ~= "table" then return nil, "actor missing" end

    local scalars = {}
    for key, value in pairs(actor) do
        if type(value) == "number" or type(value) == "string" or type(value) == "boolean" then
            scalars[tostring(key)] = value
        end
    end

    local sections = {}
    for sectionId, map in pairs(type(actor.details) == "table" and actor.details or {}) do
        if type(map) == "table" then
            local rows = {}
            for name, value in pairs(map) do
                if type(value) == "number" or tonumber(value) ~= nil then
                    rows[#rows + 1] = { key = tostring(name), name = tostring(name), value = tonumber(value) or 0 }
                end
            end
            table.sort(rows, function(a, b)
                if a.value ~= b.value then return a.value > b.value end
                return a.name < b.name
            end)
            local totalRows = #rows
            while #rows > maxRows do rows[#rows] = nil end
            if #rows > 0 then sections[#sections + 1] = { id = tostring(sectionId), rows = rows, totalRows = totalRows, truncated = totalRows > #rows } end
        end
    end
    table.sort(sections, function(a, b) return a.id < b.id end)
    while #sections > maxSections do sections[#sections] = nil end

    local opener = {}
    local queue = actor.opener
    if type(queue) == "table" and type(queue.rows) == "table" then
        local head = math.max(1, math.floor(tonumber(queue.head) or 1))
        local tail = math.max(0, math.floor(tonumber(queue.tail) or 0))
        for index = head, tail do
            local row = queue.rows[index]
            if type(row) == "table" then
                opener[#opener + 1] = { at = tonumber(row.at) or 0, skill = tostring(row.skill or ""), confidence = tostring(row.confidence or ""), exact = row.exact == true }
                if #opener >= 12 then break end
            end
        end
    end

    return {
        metricId = metric.id, title = metric.title, revision = self.projectionRevision,
        actor = { key = actorKey, name = tostring(actor.name or actorKey), stableId = actor.stableId },
        scalars = scalars, sections = sections, opener = opener,
    }
end
function A:ResetMetric(id, reason, suppressPublish)
    local metric=self.metrics[NormalizeId(id)]; if metric==nil or type(metric.Reset)~="function" then return false,"metric reset unavailable" end
    local ok,err=RunMetricReset(metric,reason or "user"); if ok~=true then return false,err end
    if suppressPublish~=true then self:_SchedulePublish("reset:"..metric.id) end
    return true
end
function A:ResetMetrics(ids, reason)
    if type(ids) ~= "table" then return false, "metric ids required" end
    local ordered, seen = {}, {}
    for _, value in ipairs(ids) do
        local id = NormalizeId(value)
        if id ~= "" and seen[id] ~= true then
            local metric = self.metrics[id]
            if metric == nil or type(metric.Reset) ~= "function" then return false, "metric reset unavailable: " .. tostring(id) end
            seen[id] = true; ordered[#ordered + 1] = id
        end
    end
    if #ordered <= 0 then return true end
    for _, id in ipairs(ordered) do
        local metric = self.metrics[id]
        local ok, err = RunMetricReset(metric, reason or "user")
        if ok ~= true then return false, err end
    end
    self:_SchedulePublish("reset_metrics")
    return true
end
function A:ResetAll(reason)
    return self:ResetMetrics(self.metricOrder, reason or "user")
end
function A:GetHealth()
    local metricHealth={}
    for _,id in ipairs(self.metricOrder) do local metric=self.metrics[id]; if metric and type(metric.GetHealth)=="function" then local ok,v=xpcall(function() return metric.GetHealth(metric,A) end,Trace); metricHealth[id]=ok and v or {ok=false,error=tostring(v)} end end
    local emptyConsumers = 0
    for _, options in pairs(self.consumers or {}) do
        if type(options) ~= "table" or type(options.metrics) ~= "table" or #options.metrics <= 0 then emptyConsumers = emptyConsumers + 1 end
    end
    local bus=S.Services and S.Services.CombatEventBusV3 or nil; local bh=type(bus)=="table" and type(bus.GetHealth)=="function" and bus:GetHealth() or {}
    return { version=self.version, consumers=tonumber(self.consumerCount) or 0, emptyConsumers=emptyConsumers, registeredMetrics=#self.metricOrder, activeMetrics=#self.activeMetricOrder,
        damageDispatchMetrics=#(self.factPlans.damage or {}), auraDispatchMetrics=#(self.factPlans.aura or {}), busSubscribed=self.busSubscribed==true,
        busCoverage=tostring(bh.coverageState or "INACTIVE"), factsReceived=self.factsReceived, metricDispatches=self.metricDispatches,
        metricErrors=self.metricErrors, metricMutations=self.metricMutations, nativeFacts=self.nativeFacts, nativeCoverage=self.nativeCoverage, metrics=metricHealth }
end

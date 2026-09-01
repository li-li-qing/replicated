ReplicatedSuiteModuleSandbox:Enter('dps', {'ReplicatedDps', 'ReplicatedDpsConfig'})
------------------------------------------------------------------------
-- Replicated DPS - diagnostic local replay closure planner
-- Author: Replicated
--
-- Authority boundary
--   * D.EventStore remains the production journal/order Authority.
--   * D.EventBlocks supplies immutable ActorRef/TargetRef position chains.
--   * D.EventClassifications supplies committed pre/post full-replay generations.
--   * D.LocalReplayPlanner never writes Entity, Classification, Stats, Boss,
--     pending queues, replay jobs or persistence. It is a diagnostic Proxy only.
--
-- Safety boundary
--   * A user/rule correction still commits only through the existing full replay.
--   * The planner computes an affected actor closure and event plan in bounded
--     steps, then compares that plan with the events that actually changed in
--     the authoritative full replay.
--   * One changed event outside the plan makes the plan unsafe and preserves the
--     full-replay fallback. Over-inclusion is allowed; under-inclusion is not.
--   * No synchronous full journal scan or unbounded sort runs in Tick/callbacks.
------------------------------------------------------------------------

if ReplicatedDps == nil or ReplicatedDps.Boot == nil then return end

local D = ReplicatedDps
local Boot = D.Boot
if Boot.phase == "FAILED" then return end
if type(D.EventStore) ~= "table" then
    Boot:Fail("local_replay:event_store", "D.EventStore is unavailable")
    return
end
if type(D.EventBlocks) ~= "table"
    or type(D.EventBlocks.GetEventIdByPosition) ~= "function"
    or type(D.EventBlocks.FindSourceActorRefIdByToken) ~= "function" then
    Boot:Fail("local_replay:event_blocks", "D.EventBlocks position boundary is unavailable")
    return
end
if type(D.EventClassifications) ~= "table"
    or type(D.EventClassifications.GetFromGeneration) ~= "function" then
    Boot:Fail("local_replay:event_classification",
        "D.EventClassifications generation read boundary is unavailable")
    return
end
if type(D.Util) ~= "table" then
    Boot:Fail("local_replay:util", "D.Util is unavailable")
    return
end

Boot:SetPhase("LOCAL_REPLAY_LOADING")

local U = D.Util
local Store = D.EventStore
local Blocks = D.EventBlocks
local Classifications = D.EventClassifications

D.LocalReplayPlanner = D.LocalReplayPlanner or {}
local L = D.LocalReplayPlanner

L.schemaVersion = 1
L.layoutVersion = 1
L.defaultActorLimit = 1024
L.defaultEventLimit = 100000
L.defaultStepBudget = 320
L.statsShadowObserver = nil

-- Only fields that can affect projection membership/routing are compared.
-- Revision, context, retry timestamps and diagnostic observation timestamps do
-- not change cumulative product output and therefore are intentionally omitted.
local AUDIT_FIELDS = {
    "candidateMode", "appliedMode", "applied", "pending", "thirdParty",
    "retiredThirdParty", "dormantThirdParty", "dormantPending",
    "dormantSummaryMode", "modeProvisional", "relationProvisional",
    "provisionalFallbackMode", "healRelationConflict", "friendlyFire",
    "opponentInternalDamage", "repdpsSummaryTracked", "repdpsSummaryMode",
    "repdpsSummaryThirdParty", "expiredModes", "sourceResolvedKey",
    "targetResolvedKey", "sourceProjectionSide", "targetProjectionSide",
    "pendingReason",
}

local TABLE_FIELDS = { expiredModes = true }


local function NotifyStatsShadow(methodName, ...)
    local observer = L.statsShadowObserver
    local method = type(observer) == "table" and observer[methodName] or nil
    if type(method) ~= "function" or observer.failed == true then
        return nil, "LOCAL_STATS_SHADOW_UNAVAILABLE"
    end
    local ok, first, second, third, fourth = pcall(method, observer, ...)
    if not ok then
        if type(observer.DisableAfterFailure) == "function" then
            pcall(observer.DisableAfterFailure, observer, first)
        end
        return nil, "LOCAL_STATS_SHADOW_FAILURE:" .. tostring(first)
    end
    return first, second, third, fourth
end

local function Counter(name, amount)
    local counters = D.Diagnostics and D.Diagnostics.counters or nil
    if type(counters) ~= "table" then return end
    counters[name] = (tonumber(counters[name]) or 0) + (tonumber(amount) or 1)
end

local function NowMs()
    return type(U.NowMs) == "function" and U.NowMs() or 0
end

local function NonEmpty(value)
    if value == nil then return nil end
    local text = tostring(value)
    text = string.gsub(text, "^%s+", "")
    text = string.gsub(text, "%s+$", "")
    if text == "" then return nil end
    return text
end

local function CopySeed(seed)
    if type(seed) ~= "table" then return nil end
    return {
        key = NonEmpty(seed.key),
        name = NonEmpty(seed.name),
        boundId = NonEmpty(seed.boundId or seed.stringId or seed.stableId),
    }
end

local function SameValue(field, left, right)
    if TABLE_FIELDS[field] == true then
        local lPvp = type(left) == "table" and left.PVP == true or false
        local lPve = type(left) == "table" and left.PVE == true or false
        local rPvp = type(right) == "table" and right.PVP == true or false
        local rPve = type(right) == "table" and right.PVE == true or false
        return lPvp == rPvp and lPve == rPve
    end
    return left == right
end

local function GenerationField(generation, eventId, field)
    return Classifications:GetFromGeneration(generation, eventId, field)
end

local function ClassificationChanged(oldGeneration, newGeneration, eventId)
    for _, field in ipairs(AUDIT_FIELDS) do
        local oldValue, oldKnown = GenerationField(oldGeneration, eventId, field)
        local newValue, newKnown = GenerationField(newGeneration, eventId, field)
        if oldKnown ~= newKnown or not SameValue(field, oldValue, newValue) then
            return true, field, oldValue, newValue
        end
    end
    return false
end

local function ProjectionRoute(generation, eventId)
    local applied = select(1, GenerationField(generation, eventId, "applied")) == true
    if not applied then return nil end
    local mode = select(1, GenerationField(generation, eventId, "appliedMode"))
        or select(1, GenerationField(generation, eventId, "candidateMode"))
        or "UNKNOWN"
    local sourceSide = select(1, GenerationField(generation, eventId, "sourceProjectionSide"))
        or "LEGACY_UNRECORDED"
    local targetSide = select(1, GenerationField(generation, eventId, "targetProjectionSide"))
        or "LEGACY_UNRECORDED"
    local category = select(1, Blocks:ReadFact(eventId, "category")) or "OTHER"
    return tostring(mode) .. "|" .. tostring(category)
        .. "|S:" .. tostring(sourceSide) .. "|T:" .. tostring(targetSide)
end

local function AddProjectionDelta(plan, generation, eventId, sign)
    local route = ProjectionRoute(generation, eventId)
    if route == nil then return end
    local amountValue = Blocks:ReadFact(eventId, "amount")
    local amount = tonumber(amountValue) or 0
    plan.projectionDeltaByRoute[route] =
        (tonumber(plan.projectionDeltaByRoute[route]) or 0) + amount * sign
end

local function FailPlan(plan, reason)
    plan.requiresFullReplay = true
    plan.fallbackReason = tostring(reason or "UNKNOWN")
    plan.phase = "FULL_REPLAY_REQUIRED"
    plan.completedAt = NowMs()
    Counter("localReplayFallbacks", 1)
end

local function AddToken(plan, token)
    token = NonEmpty(token)
    if token == nil or plan.actorSeen[token] == true then return true end
    if plan.actorCount >= plan.actorLimit then
        FailPlan(plan, "ACTOR_LIMIT_EXCEEDED")
        return false
    end
    plan.actorSeen[token] = true
    plan.actorCount = plan.actorCount + 1
    plan.actorQueue[#plan.actorQueue + 1] = token
    return true
end

local function AddPosition(plan, position)
    position = math.floor(tonumber(position) or 0)
    if position <= 0 or position > plan.eventTotal then return false end
    if plan.positionSeen[position] == true then return false end
    if plan.eventCount >= plan.eventLimit then
        FailPlan(plan, "EVENT_LIMIT_EXCEEDED")
        return false
    end
    plan.positionSeen[position] = true
    plan.eventCount = plan.eventCount + 1
    plan.positions[plan.eventCount] = position
    return true
end

local function RefToken(kind, refId)
    local snapshot = kind == "SOURCE" and Blocks:GetSourceActorRef(refId)
        or Blocks:GetTargetRef(refId)
    return type(snapshot) == "table" and snapshot.token or nil
end

local function ExpandEventEdge(plan, eventId)
    local category = select(1, Blocks:ReadFact(eventId, "category"))
    -- Damage and healing are the only relation-propagating edges. Death/last-hit
    -- events that directly mention a closure actor are included but do not widen
    -- the relation dependency graph by themselves.
    if category ~= "DAMAGE" and category ~= "HEAL" then return true end
    local sourceRefId = Blocks:GetSourceActorRefId(eventId)
    local targetRefId = Blocks:GetTargetRefId(eventId)
    if sourceRefId ~= nil and not AddToken(plan, RefToken("SOURCE", sourceRefId)) then return false end
    if targetRefId ~= nil and not AddToken(plan, RefToken("TARGET", targetRefId)) then return false end
    return true
end

local function StartActor(plan)
    local token = plan.actorQueue[plan.actorHead]
    if token == nil then
        plan.phase = "SORT"
        plan.sortWidth = 1
        plan.sortStart = 1
        plan.sortOutput = {}
        plan.merge = nil
        return false
    end
    plan.currentToken = token
    plan.currentSourceRefId = Blocks:FindSourceActorRefIdByToken(token)
    plan.currentTargetRefId = Blocks:FindTargetRefIdByToken(token)
    plan.currentLane = "SOURCE"
    plan.currentPosition = plan.currentSourceRefId ~= nil
        and Blocks:GetFirstSourcePosition(plan.currentSourceRefId) or nil
    return true
end

local function AdvanceLane(plan)
    if plan.currentLane == "SOURCE" then
        plan.currentLane = "TARGET"
        plan.currentPosition = plan.currentTargetRefId ~= nil
            and Blocks:GetFirstTargetPosition(plan.currentTargetRefId) or nil
        return
    end
    plan.actorHead = plan.actorHead + 1
    plan.currentToken = nil
    plan.currentSourceRefId = nil
    plan.currentTargetRefId = nil
    plan.currentLane = nil
    plan.currentPosition = nil
end

local function StepExpand(plan, budget)
    local processed = 0
    while processed < budget and plan.phase == "EXPAND" do
        if plan.currentToken == nil then
            if not StartActor(plan) then break end
        end
        if plan.currentPosition == nil then
            AdvanceLane(plan)
        else
            local position = plan.currentPosition
            if plan.currentLane == "SOURCE" then
                plan.currentPosition = Blocks:GetNextSourcePosition(position)
            else
                plan.currentPosition = Blocks:GetNextTargetPosition(position)
            end
            if AddPosition(plan, position) then
                local eventId = Blocks:GetEventIdByPosition(position)
                if eventId ~= nil then ExpandEventEdge(plan, eventId) end
            end
            processed = processed + 1
        end
    end
    return processed
end

local function BeginMerge(plan)
    local count = plan.eventCount
    if plan.sortWidth >= count then
        plan.phase = "WAIT_REPLAY"
        plan.readyAt = NowMs()
        plan.safeCandidate = plan.requiresFullReplay ~= true
        return false
    end
    if plan.sortStart > count then
        plan.positions = plan.sortOutput
        plan.sortOutput = {}
        plan.sortWidth = plan.sortWidth * 2
        plan.sortStart = 1
        if plan.sortWidth >= count then
            plan.phase = "WAIT_REPLAY"
            plan.readyAt = NowMs()
            plan.safeCandidate = plan.requiresFullReplay ~= true
            return false
        end
    end
    local leftStart = plan.sortStart
    local leftEnd = math.min(leftStart + plan.sortWidth - 1, count)
    local rightStart = leftEnd + 1
    local rightEnd = math.min(leftStart + plan.sortWidth * 2 - 1, count)
    plan.merge = {
        left = leftStart,
        leftEnd = leftEnd,
        right = rightStart,
        rightEnd = rightEnd,
        out = leftStart,
    }
    return true
end

local function StepSort(plan, budget)
    local moved = 0
    while moved < budget and plan.phase == "SORT" do
        local merge = plan.merge
        if merge == nil then
            if not BeginMerge(plan) then break end
            merge = plan.merge
        end
        local source = plan.positions
        local output = plan.sortOutput
        if merge.left <= merge.leftEnd
            and (merge.right > merge.rightEnd
                or source[merge.left] <= source[merge.right]) then
            output[merge.out] = source[merge.left]
            merge.left = merge.left + 1
        elseif merge.right <= merge.rightEnd then
            output[merge.out] = source[merge.right]
            merge.right = merge.right + 1
        else
            plan.sortStart = merge.rightEnd + 1
            plan.merge = nil
        end
        if plan.merge ~= nil then
            merge.out = merge.out + 1
            moved = moved + 1
        end
    end
    return moved
end

local function BeginAudit(plan)
    if plan.requiresFullReplay == true then return false end
    if type(plan.oldClassificationGeneration) ~= "table"
        or type(plan.newClassificationGeneration) ~= "table" then
        FailPlan(plan, "CLASSIFICATION_GENERATION_UNAVAILABLE")
        return false
    end
    plan.phase = "AUDIT"
    plan.auditPosition = 1
    plan.auditChecked = 0
    plan.changedEvents = 0
    plan.changedInsidePlan = 0
    plan.changedOutsidePlan = 0
    plan.firstOutside = nil
    plan.projectionDeltaByRoute = {}
    return true
end

local function StepAudit(plan, budget)
    local processed = 0
    while plan.auditPosition <= plan.eventTotal and processed < budget do
        local position = plan.auditPosition
        local eventId = Blocks:GetEventIdByPosition(position)
        if eventId ~= nil then
            local changed, field, oldValue, newValue = ClassificationChanged(
                plan.oldClassificationGeneration, plan.newClassificationGeneration, eventId)
            if changed then
                plan.changedEvents = plan.changedEvents + 1
                if plan.positionSeen[position] == true then
                    plan.changedInsidePlan = plan.changedInsidePlan + 1
                    AddProjectionDelta(plan, plan.oldClassificationGeneration, eventId, -1)
                    AddProjectionDelta(plan, plan.newClassificationGeneration, eventId, 1)
                else
                    plan.changedOutsidePlan = plan.changedOutsidePlan + 1
                    if plan.firstOutside == nil then
                        plan.firstOutside = {
                            eventId = eventId,
                            position = position,
                            field = field,
                            oldValue = oldValue,
                            newValue = newValue,
                        }
                    end
                end
            end
        end
        plan.auditPosition = position + 1
        plan.auditChecked = plan.auditChecked + 1
        processed = processed + 1
    end
    if plan.auditPosition > plan.eventTotal then
        plan.completedAt = NowMs()
        if plan.changedOutsidePlan > 0 then
            plan.requiresFullReplay = true
            plan.fallbackReason = "CHANGED_EVENT_OUTSIDE_CLOSURE"
            plan.phase = "FULL_REPLAY_REQUIRED"
            Counter("localReplayUnsafePlans", 1)
            Counter("localReplayChangedOutside", plan.changedOutsidePlan)
        else
            plan.safeCandidate = true
            local started, reason = NotifyStatsShadow("BeginProjectionTransaction", plan)
            if started == true then
                plan.phase = "STATS_SHADOW"
            else
                plan.requiresFullReplay = true
                plan.fallbackReason = tostring(reason or "LOCAL_STATS_SHADOW_UNAVAILABLE")
                plan.phase = "FULL_REPLAY_REQUIRED"
                Counter("localReplayUnsafePlans", 1)
            end
        end
        Counter("localReplayChangedEvents", plan.changedEvents)
        return true
    end
    return false
end

local function FreshState(reason, preserveEnabled)
    local enabled = preserveEnabled == true and L.enabled == true
    L.planCounter = math.max(0, math.floor(tonumber(L.planCounter) or 0))
    L.enabled = enabled
    L.failed = false
    L.failure = nil
    L.activePlan = nil
    L.lastPlan = nil
    L.lastResetReason = tostring(reason or "module_load")
end

FreshState("module_load", false)

function L:DisableAfterFailure(err)
    self.failed = true
    self.enabled = false
    self.failure = tostring(err or "unknown local replay planner failure")
    if type(self.activePlan) == "table" then
        self.activePlan.requiresFullReplay = true
        self.activePlan.fallbackReason = "PLANNER_FAILURE"
        self.activePlan.phase = "FULL_REPLAY_REQUIRED"
        self.lastPlan = self.activePlan
    end
    self.activePlan = nil
    Counter("localReplayFailures", 1)
    if D.Diagnostics ~= nil and type(D.Diagnostics.AddWarning) == "function" then
        D.Diagnostics:AddWarning("local_replay", "局部重放规划器已停用：" .. self.failure)
    end
end

function L:SetStatsShadowObserver(observer)
    if observer ~= nil and type(observer) ~= "table" then return false end
    self.statsShadowObserver = observer
    return true
end

function L:OnDiagnosticsChanged(enabled)
    FreshState(enabled == true and "diagnostics_enabled" or "diagnostics_disabled", false)
    self.enabled = enabled == true
    NotifyStatsShadow("OnDiagnosticsChanged", enabled == true)
end

function L:BeginPlan(seed, reason, options)
    if self.enabled ~= true or self.failed == true then return false end
    local normalizedSeed = CopySeed(seed)
    if normalizedSeed == nil then
        self.activePlan = nil
        self.planCounter = self.planCounter + 1
        self.lastPlan = {
            id = self.planCounter,
            reason = tostring(reason or "FULL_REPLAY"),
            phase = "FULL_REPLAY_REQUIRED",
            requiresFullReplay = true,
            fallbackReason = "NO_SINGLE_ACTOR_SEED",
            startedAt = NowMs(),
            completedAt = NowMs(),
        }
        Counter("localReplayFallbacks", 1)
        return false
    end
    if Blocks.enabled ~= true or Blocks.failed == true or Blocks.backfillJob ~= nil then
        self.activePlan = nil
        self.planCounter = self.planCounter + 1
        self.lastPlan = {
            id = self.planCounter,
            seed = normalizedSeed,
            reason = tostring(reason or "FULL_REPLAY"),
            phase = "FULL_REPLAY_REQUIRED",
            requiresFullReplay = true,
            fallbackReason = "EVENT_BLOCK_INDEX_NOT_READY",
            startedAt = NowMs(),
            completedAt = NowMs(),
        }
        Counter("localReplayFallbacks", 1)
        return false
    end
    local generation = Blocks.committed
    local eventTotal = math.max(0, math.floor(tonumber(generation and generation.eventCount) or 0))
    if eventTotal ~= #(Store.sessionEvents or {}) then
        self.activePlan = nil
        self.planCounter = self.planCounter + 1
        self.lastPlan = {
            id = self.planCounter,
            seed = normalizedSeed,
            reason = tostring(reason or "FULL_REPLAY"),
            phase = "FULL_REPLAY_REQUIRED",
            requiresFullReplay = true,
            fallbackReason = "EVENT_BLOCK_JOURNAL_COUNT_MISMATCH",
            startedAt = NowMs(),
            completedAt = NowMs(),
        }
        Counter("localReplayFallbacks", 1)
        return false
    end

    options = type(options) == "table" and options or {}
    self.planCounter = self.planCounter + 1
    local plan = {
        id = self.planCounter,
        seed = normalizedSeed,
        reason = tostring(reason or "FULL_REPLAY"),
        phase = "EXPAND",
        actorLimit = math.max(1, math.floor(tonumber(options.actorLimit)
            or self.defaultActorLimit)),
        eventLimit = math.max(1, math.floor(tonumber(options.eventLimit)
            or self.defaultEventLimit)),
        eventTotal = eventTotal,
        journal = Store.sessionEvents,
        journalGeneration = tonumber(Store.identityGeneration) or 0,
        blockGeneration = generation.id,
        oldClassificationGeneration = Classifications:CommittedGeneration(),
        newClassificationGeneration = nil,
        actorQueue = {},
        actorSeen = {},
        actorHead = 1,
        actorCount = 0,
        currentToken = nil,
        positions = {},
        positionSeen = {},
        eventCount = 0,
        requiresFullReplay = false,
        safeCandidate = false,
        startedAt = NowMs(),
    }
    self.activePlan = plan
    self.lastPlan = plan

    local sourceRefId = Blocks:FindSourceActorRefId(
        normalizedSeed.boundId, normalizedSeed.key, normalizedSeed.name)
    local targetRefId = Blocks:FindTargetRefId(
        normalizedSeed.boundId, normalizedSeed.key, normalizedSeed.name)
    local seeded = false
    if sourceRefId ~= nil then
        seeded = AddToken(plan, RefToken("SOURCE", sourceRefId)) or seeded
    end
    if targetRefId ~= nil then
        seeded = AddToken(plan, RefToken("TARGET", targetRefId)) or seeded
    end
    if not seeded or plan.actorCount == 0 then
        FailPlan(plan, "SEED_NOT_PRESENT_IN_EVENT_INDEX")
        self.activePlan = nil
        return false
    end
    Counter("localReplayPlans", 1)
    return true
end

function L:OnFullReplayBegin(reason, eventTotal)
    local plan = self.activePlan
    if type(plan) ~= "table" then return false end
    plan.fullReplayReason = tostring(reason or "FULL_REPLAY")
    plan.fullReplayEventTotal = math.max(0, math.floor(tonumber(eventTotal) or 0))
    if plan.fullReplayEventTotal ~= plan.eventTotal then
        FailPlan(plan, "JOURNAL_CHANGED_BEFORE_REPLAY")
        self.activePlan = nil
        return false
    end
    local captured, reason = NotifyStatsShadow("OnFullReplayBegin", plan, D.State.stats)
    if captured ~= true then
        FailPlan(plan, reason or "LOCAL_STATS_SHADOW_CAPTURE_FAILED")
        NotifyStatsShadow("OnPlanAborted", plan, plan.fallbackReason)
        self.activePlan = nil
        return false
    end
    return true
end

function L:OnFullReplayCommitted(reason)
    local plan = self.activePlan
    if type(plan) ~= "table" then return false end
    plan.fullReplayCommitted = true
    plan.fullReplayCommitReason = tostring(reason or "FULL_REPLAY")
    plan.fullReplayFinalEventTotal = #(Store.sessionEvents or {})
    if plan.fullReplayFinalEventTotal ~= plan.eventTotal then
        FailPlan(plan, "JOURNAL_CHANGED_DURING_REPLAY")
        NotifyStatsShadow("OnPlanAborted", plan, plan.fallbackReason)
        self.lastPlan = plan
        self.activePlan = nil
        return false
    end
    plan.newClassificationGeneration = Classifications:CommittedGeneration()
    local captured, captureReason = NotifyStatsShadow("OnFullReplayCommitted", plan, D.State.stats)
    if captured ~= true then
        FailPlan(plan, captureReason or "LOCAL_STATS_SHADOW_COMMIT_CAPTURE_FAILED")
        NotifyStatsShadow("OnPlanAborted", plan, plan.fallbackReason)
        self.lastPlan = plan
        self.activePlan = nil
        return false
    end
    if plan.phase == "WAIT_REPLAY" then BeginAudit(plan) end
    return true
end

function L:OnFullReplayRolledBack(reason)
    local plan = self.activePlan
    if type(plan) ~= "table" then return false end
    plan.phase = "FULL_REPLAY_ROLLED_BACK"
    plan.requiresFullReplay = true
    plan.fallbackReason = tostring(reason or "FULL_REPLAY_ROLLED_BACK")
    plan.completedAt = NowMs()
    NotifyStatsShadow("OnFullReplayRolledBack", plan, plan.fallbackReason)
    self.lastPlan = plan
    self.activePlan = nil
    Counter("localReplayRollbacks", 1)
    return true
end

function L:Step(budget)
    local plan = self.activePlan
    if type(plan) ~= "table" then return true end
    if self.enabled ~= true or self.failed == true then
        self.activePlan = nil
        return true
    end
    if plan.journal ~= Store.sessionEvents
        or plan.journalGeneration ~= (tonumber(Store.identityGeneration) or 0)
        or plan.blockGeneration ~= (Blocks.committed and Blocks.committed.id) then
        FailPlan(plan, "JOURNAL_OR_BLOCK_GENERATION_CHANGED")
        NotifyStatsShadow("OnPlanAborted", plan, plan.fallbackReason)
        self.lastPlan = plan
        self.activePlan = nil
        return true
    end
    local remaining = math.max(1, math.floor(tonumber(budget) or self.defaultStepBudget))
    if plan.phase == "EXPAND" then
        StepExpand(plan, remaining)
    elseif plan.phase == "SORT" then
        StepSort(plan, remaining)
    elseif plan.phase == "WAIT_REPLAY" then
        if plan.fullReplayCommitted == true then BeginAudit(plan) end
    elseif plan.phase == "AUDIT" then
        StepAudit(plan, remaining)
    elseif plan.phase == "STATS_SHADOW" then
        local done, safe, reason, summary = NotifyStatsShadow(
            "StepProjectionTransaction", plan, remaining)
        if done == true then
            plan.statsShadow = summary
            if safe == true then
                plan.phase = "EQUIVALENT_STATS"
                Counter("localReplayEquivalentPlans", 1)
            else
                plan.requiresFullReplay = true
                plan.fallbackReason = tostring(reason or "STATS_SHADOW_MISMATCH")
                plan.phase = "FULL_REPLAY_REQUIRED"
                Counter("localReplayUnsafePlans", 1)
            end
        end
    end
    if plan.phase == "EQUIVALENT_STATS"
        or plan.phase == "FULL_REPLAY_REQUIRED"
        or plan.phase == "FULL_REPLAY_ROLLED_BACK" then
        if plan.phase == "FULL_REPLAY_REQUIRED" then
            NotifyStatsShadow("OnPlanAborted", plan, plan.fallbackReason)
        end
        self.lastPlan = plan
        self.activePlan = nil
        return true
    end
    return false
end

function L:GetLastPlanSummary()
    local plan = self.activePlan or self.lastPlan
    if type(plan) ~= "table" then return nil end
    return {
        id = plan.id,
        reason = plan.reason,
        phase = plan.phase,
        actorCount = plan.actorCount or 0,
        eventCount = plan.eventCount or 0,
        eventTotal = plan.eventTotal or 0,
        changedEvents = plan.changedEvents or 0,
        changedInsidePlan = plan.changedInsidePlan or 0,
        changedOutsidePlan = plan.changedOutsidePlan or 0,
        requiresFullReplay = plan.requiresFullReplay == true,
        fallbackReason = plan.fallbackReason,
        firstOutside = plan.firstOutside,
        projectionDeltaByRoute = plan.projectionDeltaByRoute,
        statsShadow = plan.statsShadow,
    }
end

function L:GetStatusLine()
    if self.enabled ~= true then
        if self.failed == true then return "局部重放规划：已停用（故障）" end
        return "局部重放规划：关闭（诊断模式启用）"
    end
    local plan = self.activePlan or self.lastPlan
    if type(plan) ~= "table" then return "局部重放规划：等待人工纠错样本" end
    local text = "局部重放规划 #" .. tostring(plan.id or 0)
        .. " / " .. tostring(plan.phase or "UNKNOWN")
        .. " / Actor " .. tostring(plan.actorCount or 0)
        .. " / 事件 " .. tostring(plan.eventCount or 0)
            .. "/" .. tostring(plan.eventTotal or 0)
    if (tonumber(plan.changedEvents) or 0) > 0 then
        text = text .. " / 变化 " .. tostring(plan.changedEvents)
            .. " / 计划外 " .. tostring(plan.changedOutsidePlan or 0)
    end
    if type(plan.statsShadow) == "table" then
        text = text .. " / Stats路径 " .. tostring(plan.statsShadow.pathCount or 0)
            .. " / Stats不一致 " .. tostring(plan.statsShadow.mismatches or 0)
    end
    if plan.fallbackReason ~= nil then
        text = text .. " / 完整重放=" .. tostring(plan.fallbackReason)
    end
    return text
end

if D.State ~= nil and D.State.config ~= nil and D.State.config.diagnosticsEnabled == true then
    local ok, err = pcall(L.OnDiagnosticsChanged, L, true)
    if not ok then L:DisableAfterFailure(err) end
end

Boot:CompletePhase("LOCAL_REPLAY_READY")

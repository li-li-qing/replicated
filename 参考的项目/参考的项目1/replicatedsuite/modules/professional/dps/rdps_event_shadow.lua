ReplicatedSuiteModuleSandbox:Enter('dps', {'ReplicatedDps', 'ReplicatedDpsConfig'})
------------------------------------------------------------------------
-- Replicated DPS - immutable CombatEvent Fact / classification shadow
-- Author: Replicated
--
-- Authority boundary
--   * D.EventStore.sessionEvents remains the formal fact/order Authority.
--   * D.EventClassifications owns mutable product classification; this module is diagnostic-only.
--   * This module never changes legacy CombatEvent rows, pending queues, Stats,
--     Entity state, replay state or persistence.
--   * Immutable Fact records contain only observations that belong to the event
--     at creation time. Mutable classification outcomes live in a separate map.
--   * Full replay uses a shadow transaction: working classifications are not
--     visible as committed until the production replay reaches DONE. Rollback
--     discards the working map in O(1).
--
-- Performance boundary
--   * The shadow is active only while diagnosticsEnabled is true.
--   * Normal combat performs only constant configuration guards and no shadow allocation.
--   * Existing journals are backfilled only through explicit bounded steps.
--   * No full journal scan is run in Tick or a combat callback.
------------------------------------------------------------------------

if ReplicatedDps == nil or ReplicatedDps.Boot == nil then return end

local D = ReplicatedDps
local Boot = D.Boot
if Boot.phase == "FAILED" then return end
if type(D.EventStore) ~= "table" or type(D.EventStore.SetEventShadowObserver) ~= "function" then
    Boot:Fail("event_shadow:event_store", "D.EventStore observer boundary is unavailable")
    return
end
if type(D.Util) ~= "table" then
    Boot:Fail("event_shadow:util", "D.Util is unavailable")
    return
end

Boot:SetPhase("EVENT_SHADOW_LOADING")

local U = D.Util
local Store = D.EventStore

D.EventShadow = D.EventShadow or {}
local H = D.EventShadow

H.schemaVersion = 1
H.factLayoutVersion = 1
H.classificationLayoutVersion = 1

local FACT_FIELDS = {
    "eventId", "timestamp", "eventType", "category",
    "sourceName", "targetName", "abilityId", "abilityName", "amount",
    "parseStatus", "environmental", "inferredLastHit",
    "deathNoticeAt", "lastHitMatchReason", "linkedDamageEventId",
    -- Identity keys are creation-time observations only. The legacy Authority
    -- may later rewrite teamname:* into id:*; the immutable Fact intentionally
    -- keeps the original values and does not treat that promotion as corruption.
    "initialSourceKey", "initialTargetKey",
    "initialSourceBoundId", "initialTargetBoundId",
}

local CLASS_FIELDS = {
    "eventId", "revision", "classificationGeneration", "context", "observedAt",
    "candidateMode", "modeReason", "classificationStatus",
    "sourceProjectionSide", "targetProjectionSide", "projectionSideQuality", "pendingReason",
    "applied", "pending", "thirdParty", "retiredThirdParty",
    "dormantThirdParty", "dormantPending", "dormantSummaryMode",
    "modeProvisional", "relationProvisional", "provisionalFallbackMode",
    "healRelationConflict", "friendlyFire", "opponentInternalDamage",
    "sourceBindingQuality", "targetBindingQuality",
    "sourceBoundId", "targetBoundId",
    "sourceResolvedKey", "targetResolvedKey",
    "sourceObservedKind", "targetObservedKind",
    "sourceObservedKindQuality", "targetObservedKindQuality",
    "repdpsSummaryTracked", "repdpsSummaryMode", "repdpsSummaryThirdParty",
    "retryCount", "retryAt", "expiredModes", "outcomeSignature",
}

local function BuildIndex(fields)
    local result = {}
    for index, name in ipairs(fields) do result[name] = index end
    return result
end

local FACT_INDEX = BuildIndex(FACT_FIELDS)
local CLASS_INDEX = BuildIndex(CLASS_FIELDS)

-- Keep record payloads outside the public table. A normal assignment to either
-- a named field or a numeric slot therefore always reaches __newindex instead
-- of replacing an existing raw array value. rawset can bypass every Lua proxy,
-- but no production module receives or uses that escape hatch.
local RECORD_VALUES = setmetatable({}, { __mode = "k" })

local function ReadOnlyMeta(indexByName, label)
    return {
        __index = function(target, key)
            local index = indexByName[key]
            local values = RECORD_VALUES[target]
            if index ~= nil and type(values) == "table" then return values[index] end
            return nil
        end,
        __newindex = function(_, key)
            error(label .. " is immutable: " .. tostring(key), 2)
        end,
        __metatable = label,
    }
end

local FACT_META = ReadOnlyMeta(FACT_INDEX, "ReplicatedDps.CombatEventFact")
local CLASS_META = ReadOnlyMeta(CLASS_INDEX, "ReplicatedDps.EventClassification")

local function Counter(name, amount)
    local counters = D.Diagnostics and D.Diagnostics.counters or nil
    if type(counters) ~= "table" then return end
    counters[name] = (tonumber(counters[name]) or 0) + (tonumber(amount) or 1)
end

local function FiniteNumber(value, fallback)
    if U ~= nil and type(U.FiniteNumber) == "function" then return U.FiniteNumber(value, fallback) end
    local number = tonumber(value)
    if number == nil or number ~= number or number == math.huge or number == -math.huge then return fallback end
    return number
end

local function ScalarText(value)
    if value == nil then return nil end
    return tostring(value)
end

local function BooleanOrNil(value)
    if value == true then return true end
    if value == false then return false end
    return nil
end

local function ExpiredModesToken(value)
    if type(value) ~= "table" then return nil end
    local pvp = value.PVP == true
    local pve = value.PVE == true
    if pvp and pve then return "PVP|PVE" end
    if pvp then return "PVP" end
    if pve then return "PVE" end
    return nil
end

local function NewReadOnlyRecord(fields, indexByName, meta, values)
    local record = {}
    local payload = {}
    for _, field in ipairs(fields) do
        local value = values[field]
        if value ~= nil then payload[indexByName[field]] = value end
    end
    RECORD_VALUES[record] = payload
    return setmetatable(record, meta)
end

local function EventIdToken(event)
    if type(event) ~= "table" then return nil end
    local value = FiniteNumber(event.eventId, nil)
    if value == nil then return nil end
    value = math.floor(value)
    if value <= 0 then return nil end
    return value
end

local function FactValues(event)
    return {
        eventId = EventIdToken(event),
        timestamp = FiniteNumber(event.timestamp, 0) or 0,
        eventType = ScalarText(event.eventType) or "",
        category = ScalarText(event.category) or "OTHER",
        sourceName = ScalarText(event.sourceName) or "未知",
        targetName = ScalarText(event.targetName) or "未知",
        abilityId = ScalarText(event.abilityId),
        abilityName = ScalarText(event.abilityName) or "未知",
        amount = math.abs(FiniteNumber(event.amount, 0) or 0),
        parseStatus = ScalarText(event.parseStatus) or "UNPARSED",
        environmental = event.environmental == true and true or nil,
        inferredLastHit = event.inferredLastHit == true and true or nil,
        deathNoticeAt = FiniteNumber(event.deathNoticeAt, nil),
        lastHitMatchReason = ScalarText(event.lastHitMatchReason),
        linkedDamageEventId = ScalarText(event.linkedDamageEventId),
        initialSourceKey = ScalarText(event.sourceKey),
        initialTargetKey = ScalarText(event.targetKey),
        initialSourceBoundId = ScalarText(event.sourceBoundId),
        initialTargetBoundId = ScalarText(event.targetBoundId),
    }
end

local FACT_COMPARE_FIELDS = {
    "eventId", "timestamp", "eventType", "category", "sourceName", "targetName",
    "abilityId", "abilityName", "amount", "parseStatus", "environmental",
    "inferredLastHit", "deathNoticeAt", "lastHitMatchReason", "linkedDamageEventId",
}

local function SameScalar(left, right)
    if type(left) == "number" or type(right) == "number" then
        local a = tonumber(left)
        local b = tonumber(right)
        if a ~= nil and b ~= nil then return math.abs(a - b) <= 0.000001 end
    end
    return left == right
end

local function StatusStartsWith(status, prefix)
    return string.sub(tostring(status or ""), 1, #prefix) == prefix
end

local function NormalizeProjectionSide(value)
    value = value ~= nil and string.lower(tostring(value)) or nil
    if value == "friendly" or value == "enemy" then return value end
    return nil
end

local function DerivePendingReason(event, status, pending, thirdParty, providedReason)
    if providedReason ~= nil and tostring(providedReason) ~= "" then return tostring(providedReason) end
    if status == "PENDING_HEAL_RELATION_CONFLICT" or event.healRelationConflict == true then
        return "HEAL_RELATION_CONFLICT"
    end
    if event.dormantPending == true then return "DORMANT_PENDING" end
    if event.dormantThirdParty == true then return "DORMANT_THIRD_PARTY" end
    if thirdParty then return "THIRD_PARTY_UNOWNED" end
    if pending then return status ~= "" and status or "UNRESOLVED" end
    return nil
end

local function ClassificationValues(event, revision, generation, context,
    sourceProjectionSide, targetProjectionSide, pendingReason)
    local applied = BooleanOrNil(event.applied)
    local pending = BooleanOrNil(event.pending)
    local thirdParty = BooleanOrNil(event.thirdParty)
    local status = ScalarText(event.classificationStatus) or "UNKNOWN"
    local mode = ScalarText(event.candidateMode) or "UNKNOWN"
    local sourceSide = NormalizeProjectionSide(sourceProjectionSide)
    local targetSide = NormalizeProjectionSide(targetProjectionSide)
    local sideQuality = (sourceSide ~= nil or targetSide ~= nil) and "EXACT_ATTEMPT"
        or (StatusStartsWith(status, "APPLIED_") and "LEGACY_UNRECORDED" or "NOT_APPLICABLE")
    local resolvedPendingReason = DerivePendingReason(event, status,
        pending == true, thirdParty == true, pendingReason)
    local signature = table.concat({
        status,
        mode,
        sourceSide or "-",
        targetSide or "-",
        resolvedPendingReason or "-",
        applied == true and "A1" or (applied == false and "A0" or "AN"),
        pending == true and "P1" or (pending == false and "P0" or "PN"),
        thirdParty == true and "T1" or (thirdParty == false and "T0" or "TN"),
        ScalarText(event.sourceResolvedKey) or "-",
        ScalarText(event.targetResolvedKey) or "-",
    }, "|")
    return {
        eventId = EventIdToken(event),
        revision = revision,
        classificationGeneration = generation,
        context = tostring(context or "UNKNOWN"),
        observedAt = U.NowMs(),
        candidateMode = mode,
        modeReason = ScalarText(event.modeReason),
        classificationStatus = status,
        sourceProjectionSide = sourceSide,
        targetProjectionSide = targetSide,
        projectionSideQuality = sideQuality,
        pendingReason = resolvedPendingReason,
        applied = applied,
        pending = pending,
        thirdParty = thirdParty,
        retiredThirdParty = BooleanOrNil(event.retiredThirdParty),
        dormantThirdParty = BooleanOrNil(event.dormantThirdParty),
        dormantPending = BooleanOrNil(event.dormantPending),
        dormantSummaryMode = ScalarText(event.dormantSummaryMode),
        modeProvisional = BooleanOrNil(event.modeProvisional),
        relationProvisional = BooleanOrNil(event.relationProvisional),
        provisionalFallbackMode = ScalarText(event.provisionalFallbackMode),
        healRelationConflict = BooleanOrNil(event.healRelationConflict),
        friendlyFire = BooleanOrNil(event.friendlyFire),
        opponentInternalDamage = BooleanOrNil(event.opponentInternalDamage),
        sourceBindingQuality = ScalarText(event.sourceBindingQuality),
        targetBindingQuality = ScalarText(event.targetBindingQuality),
        sourceBoundId = ScalarText(event.sourceBoundId),
        targetBoundId = ScalarText(event.targetBoundId),
        sourceResolvedKey = ScalarText(event.sourceResolvedKey),
        targetResolvedKey = ScalarText(event.targetResolvedKey),
        sourceObservedKind = ScalarText(event.sourceObservedKind),
        targetObservedKind = ScalarText(event.targetObservedKind),
        sourceObservedKindQuality = ScalarText(event.sourceObservedKindQuality),
        targetObservedKindQuality = ScalarText(event.targetObservedKindQuality),
        repdpsSummaryTracked = BooleanOrNil(event.repdpsSummaryTracked),
        repdpsSummaryMode = ScalarText(event.repdpsSummaryMode),
        repdpsSummaryThirdParty = BooleanOrNil(event.repdpsSummaryThirdParty),
        retryCount = FiniteNumber(event.repdpsRetryCount, nil),
        retryAt = FiniteNumber(event.repdpsNextRetryAt, nil),
        expiredModes = ExpiredModesToken(event.expiredModes),
        outcomeSignature = signature,
    }
end

local function FreshState(reason, preserveEnabled)
    local enabled = preserveEnabled == true and H.enabled == true
    H.generation = tonumber(Boot.generation) or 0
    H.enabled = enabled
    H.failed = false
    H.failure = nil
    H.resetReason = tostring(reason or "reset")
    H.factByEventId = {}
    H.classificationByEventId = {}
    H.revisionByEventId = {}
    H.transaction = nil
    H.backfillJob = nil
    H.deferredBackfill = nil
    H.factCount = 0
    H.classificationCount = 0
    H.classificationWrites = 0
    H.classificationTransitions = 0
    H.mismatchCount = 0
    H.invariantFailureCount = 0
    H.lastMismatch = nil
    H.lastTransition = nil
    H.contextCounts = {}
    H.transactionGeneration = 0
    H.auditChecks = 0
end

FreshState("module_load", false)

function H:DisableAfterFailure(err)
    self.failed = true
    self.enabled = false
    self.failure = tostring(err or "unknown event shadow failure")
    self.transaction = nil
    self.backfillJob = nil
    Counter("eventShadowFailures", 1)
    if D.Diagnostics ~= nil and type(D.Diagnostics.AddWarning) == "function" then
        D.Diagnostics:AddWarning("event_shadow", "事件事实/分类影子已停用：" .. self.failure)
    end
end

local function RecordMismatch(self, kind, eventId, field, expected, actual, context)
    self.mismatchCount = (tonumber(self.mismatchCount) or 0) + 1
    Counter("eventShadowMismatches", 1)
    self.lastMismatch = {
        kind = tostring(kind or "UNKNOWN"),
        eventId = eventId,
        field = tostring(field or "-"),
        expected = expected,
        actual = actual,
        context = tostring(context or "UNKNOWN"),
    }
    if self.mismatchCount <= 4 and D.Diagnostics ~= nil and type(D.Diagnostics.AddWarning) == "function" then
        D.Diagnostics:AddWarning(
            "event_shadow",
            "事件 " .. tostring(eventId or "?") .. " " .. tostring(kind)
                .. " 不一致：" .. tostring(field)
        )
    end
end

function H:EnsureFact(event, context)
    if self.enabled ~= true or self.failed == true then return nil end
    local eventId = EventIdToken(event)
    if eventId == nil then
        RecordMismatch(self, "FACT_ID", nil, "eventId", "positive integer", event and event.eventId, context)
        return nil
    end
    local current = self.factByEventId[eventId]
    local values = FactValues(event)
    if current ~= nil then
        for _, field in ipairs(FACT_COMPARE_FIELDS) do
            if not SameScalar(current[field], values[field]) then
                RecordMismatch(self, "FACT_MUTATION", eventId, field, current[field], values[field], context)
                break
            end
        end
        return current
    end
    local fact = NewReadOnlyRecord(FACT_FIELDS, FACT_INDEX, FACT_META, values)
    self.factByEventId[eventId] = fact
    self.factCount = self.factCount + 1
    Counter("eventShadowFacts", 1)
    return fact
end

function H:OnLegacyEventAppended(event, sessionIndex)
    if self.enabled ~= true or self.failed == true then return false end
    local fact = self:EnsureFact(event, "APPEND")
    if fact == nil then return false end
    Counter("eventShadowAppends", 1)
    return true
end

function H:ValidateClassification(event, snapshot, context)
    local failures = 0
    local eventId = snapshot.eventId
    local status = tostring(snapshot.classificationStatus or "")
    local applied = snapshot.applied == true
    local pending = snapshot.pending == true
    local thirdParty = snapshot.thirdParty == true
    local dormant = snapshot.dormantThirdParty == true or snapshot.dormantPending == true

    local function Fail(field, expected, actual)
        failures = failures + 1
        self.invariantFailureCount = self.invariantFailureCount + 1
        Counter("eventShadowInvariantFailures", 1)
        RecordMismatch(self, "CLASS_INVARIANT", eventId, field, expected, actual, context)
    end

    if applied and pending then Fail("applied/pending", "not both true", "both true") end
    if applied and thirdParty then Fail("applied/thirdParty", "not both true", "both true") end
    if dormant and pending then Fail("dormant/pending", "dormant is outside active pending", "both true") end
    if StatusStartsWith(status, "APPLIED_") and not applied then
        Fail("classificationStatus", "APPLIED_* requires applied=true", status)
    end
    if (status == "PENDING" or status == "THIRD_PARTY"
        or StatusStartsWith(status, "PENDING_") or StatusStartsWith(status, "THIRD_PARTY_"))
        and applied then
        Fail("classificationStatus", "pending/third-party requires applied=false", status)
    end
    if status == "THIRD_PARTY" and not thirdParty then
        Fail("thirdParty", true, snapshot.thirdParty)
    end
    if snapshot.candidateMode ~= "PVP" and snapshot.candidateMode ~= "PVE"
        and snapshot.candidateMode ~= "UNKNOWN" then
        Fail("candidateMode", "PVP/PVE/UNKNOWN", snapshot.candidateMode)
    end
    for _, field in ipairs({ "sourceProjectionSide", "targetProjectionSide" }) do
        local side = snapshot[field]
        if side ~= nil and side ~= "friendly" and side ~= "enemy" then
            Fail(field, "friendly/enemy/nil", side)
        end
    end
    if StatusStartsWith(status, "APPLIED_")
        and snapshot.projectionSideQuality == "EXACT_ATTEMPT"
        and snapshot.sourceProjectionSide == nil then
        Fail("sourceProjectionSide", "applied exact route has source side", nil)
    end
    if StatusStartsWith(status, "APPLIED_SHARED_HEAL") and tostring(event.category) ~= "HEAL" then
        Fail("category", "HEAL", event.category)
    end
    return failures == 0
end

local function TargetClassificationMap(self)
    if type(self.transaction) == "table" then return self.transaction.working end
    return self.classificationByEventId
end

function H:ObserveClassification(event, context, sourceProjectionSide, targetProjectionSide, pendingReason)
    if self.enabled ~= true or self.failed == true then return false end
    local fact = self:EnsureFact(event, context or "CLASSIFY")
    if fact == nil then return false end
    local eventId = fact.eventId
    local revision = (tonumber(self.revisionByEventId[eventId]) or 0) + 1
    self.revisionByEventId[eventId] = revision
    local generation = type(self.transaction) == "table"
        and self.transaction.generation or self.transactionGeneration
    local values = ClassificationValues(event, revision, generation, context,
        sourceProjectionSide, targetProjectionSide, pendingReason)
    local snapshot = NewReadOnlyRecord(CLASS_FIELDS, CLASS_INDEX, CLASS_META, values)
    local target = TargetClassificationMap(self)
    local targetPrevious = target[eventId]
    local previous = targetPrevious or self.classificationByEventId[eventId]
    target[eventId] = snapshot
    if type(self.transaction) == "table" then
        if targetPrevious == nil then
            self.transaction.observed = (tonumber(self.transaction.observed) or 0) + 1
        end
    elseif previous == nil then
        self.classificationCount = self.classificationCount + 1
    end
    self.classificationWrites = self.classificationWrites + 1
    Counter("eventShadowClassifications", 1)
    local label = tostring(context or "UNKNOWN")
    self.contextCounts[label] = (tonumber(self.contextCounts[label]) or 0) + 1
    if previous ~= nil and previous.outcomeSignature ~= snapshot.outcomeSignature then
        self.classificationTransitions = self.classificationTransitions + 1
        Counter("eventShadowTransitions", 1)
        self.lastTransition = {
            eventId = eventId,
            from = previous.outcomeSignature,
            to = snapshot.outcomeSignature,
            context = label,
            revision = revision,
        }
    end
    self:ValidateClassification(event, snapshot, label)
    return true
end

function H:BeginClassificationTransaction(reason, eventTotal)
    if self.enabled ~= true or self.failed == true then return false end
    if type(self.transaction) == "table" then
        self:RollbackClassificationTransaction("superseded")
    end
    self.transactionGeneration = (tonumber(self.transactionGeneration) or 0) + 1
    self.transaction = {
        generation = self.transactionGeneration,
        reason = tostring(reason or "FULL_REPLAY"),
        eventTotal = math.max(0, math.floor(tonumber(eventTotal) or 0)),
        startedAt = U.NowMs(),
        working = {},
        observed = 0,
    }
    Counter("eventShadowReplayBegins", 1)
    return true
end

function H:CommitClassificationTransaction()
    local transaction = self.transaction
    if type(transaction) ~= "table" then
        if self.deferredBackfill == true and self.enabled == true and self.failed ~= true then
            self.deferredBackfill = nil
            self:BeginBackfill("production_replay_finished")
        end
        return false
    end
    -- REPLAY_SNAPSHOT seeded every legacy row and DRAIN_QUEUE added every new
    -- row, so the complete working generation can be published by one pointer
    -- swap. No O(journal size) commit loop is allowed here.
    self.classificationByEventId = transaction.working
    self.classificationCount = math.max(0, math.floor(tonumber(transaction.observed) or 0))
    self.transaction = nil
    Counter("eventShadowReplayCommits", 1)
    if self.deferredBackfill == true then
        self.deferredBackfill = nil
        self:BeginBackfill("production_replay_finished")
    end
    return true
end

function H:RollbackClassificationTransaction(reason)
    if type(self.transaction) ~= "table" then
        if self.deferredBackfill == true and self.enabled == true and self.failed ~= true then
            self.deferredBackfill = nil
            self:BeginBackfill("production_replay_rollback")
        end
        return false
    end
    self.transaction = nil
    Counter("eventShadowReplayRollbacks", 1)
    if self.deferredBackfill == true then
        self.deferredBackfill = nil
        self:BeginBackfill("production_replay_rollback")
    end
    return true
end

function H:OnEventStoreReset(reason)
    local enabled = self.enabled == true and self.failed ~= true
    FreshState(reason or "event_store_reset", false)
    self.enabled = enabled
    if enabled then self:BeginBackfill("event_store_reset") end
end

function H:BeginBackfill(reason)
    if self.enabled ~= true or self.failed == true then return nil end
    self.backfillJob = {
        reason = tostring(reason or "diagnostics"),
        cursor = 1,
        events = Store.sessionEvents,
        journalGeneration = tonumber(Store.identityGeneration) or 0,
        facts = 0,
        classifications = 0,
    }
    return self.backfillJob
end

function H:StepBackfill(eventBudget)
    local job = self.backfillJob
    if type(job) ~= "table" then return true end
    if self.enabled ~= true or self.failed == true then
        self.backfillJob = nil
        return true
    end
    if job.events ~= Store.sessionEvents
        or tonumber(job.journalGeneration) ~= (tonumber(Store.identityGeneration) or 0) then
        self:BeginBackfill("journal_changed")
        job = self.backfillJob
    end
    local events = job.events or {}
    local cursor = math.max(1, math.floor(tonumber(job.cursor) or 1))
    local budget = math.max(1, math.floor(tonumber(eventBudget) or 200))
    local processed = 0
    while cursor <= #events and processed < budget do
        local event = events[cursor]
        if type(event) == "table" then
            if self:EnsureFact(event, "BACKFILL") ~= nil then job.facts = job.facts + 1 end
            local target = TargetClassificationMap(self)
            local eventId = EventIdToken(event)
            if eventId ~= nil and target[eventId] == nil then
                self:ObserveClassification(event, "BACKFILL")
                job.classifications = job.classifications + 1
            end
        end
        cursor = cursor + 1
        processed = processed + 1
    end
    job.cursor = cursor
    if cursor > #events then
        self.backfillJob = nil
        Counter("eventShadowBackfills", 1)
        return true
    end
    return false
end

function H:OnDiagnosticsChanged(enabled)
    FreshState(enabled == true and "diagnostics_enabled" or "diagnostics_disabled", false)
    self.enabled = enabled == true
    if not self.enabled then return end
    if D.State ~= nil and D.State.runtime ~= nil and D.State.runtime.replaying == true then
        -- The production replay may already be beyond EVENT_SNAPSHOT. Starting
        -- a backfill here could publish a map containing a mixture of old and
        -- partially replayed classifications. Defer until DONE/rollback.
        self.deferredBackfill = true
        return
    end
    self:BeginBackfill("diagnostics_enabled")
end

function H:GetFact(eventId)
    eventId = math.floor(tonumber(eventId) or 0)
    return eventId > 0 and self.factByEventId[eventId] or nil
end

function H:GetClassification(eventId, includeWorking)
    eventId = math.floor(tonumber(eventId) or 0)
    if eventId <= 0 then return nil end
    if includeWorking == true and type(self.transaction) == "table" then
        return self.transaction.working[eventId] or self.classificationByEventId[eventId]
    end
    return self.classificationByEventId[eventId]
end

function H:CompareEvent(event, includeWorking, context)
    if type(event) ~= "table" then return false, 1 end
    local eventId = EventIdToken(event)
    if eventId == nil then return false, 1 end
    local mismatches = 0
    local fact = self.factByEventId[eventId]
    if fact == nil then
        RecordMismatch(self, "AUDIT_MISSING_FACT", eventId, "fact", "present", nil, context)
        mismatches = mismatches + 1
    else
        local values = FactValues(event)
        for _, field in ipairs(FACT_COMPARE_FIELDS) do
            if not SameScalar(fact[field], values[field]) then
                RecordMismatch(self, "AUDIT_FACT", eventId, field, fact[field], values[field], context)
                mismatches = mismatches + 1
                break
            end
        end
    end
    local snapshot = self:GetClassification(eventId, includeWorking)
    if snapshot == nil then
        RecordMismatch(self, "AUDIT_MISSING_CLASS", eventId, "classification", "present", nil, context)
        mismatches = mismatches + 1
    else
        local values = ClassificationValues(event, snapshot.revision,
            snapshot.classificationGeneration, snapshot.context,
            snapshot.sourceProjectionSide, snapshot.targetProjectionSide, snapshot.pendingReason)
        for _, field in ipairs(CLASS_FIELDS) do
            if field ~= "observedAt" and field ~= "revision" and field ~= "classificationGeneration"
                and field ~= "context" and not SameScalar(snapshot[field], values[field]) then
                RecordMismatch(self, "AUDIT_CLASS", eventId, field, snapshot[field], values[field], context)
                mismatches = mismatches + 1
                break
            end
        end
    end
    self.auditChecks = self.auditChecks + 1
    Counter("eventShadowAuditChecks", 1)
    return mismatches == 0, mismatches
end

function H:BeginConsistencyAudit(batchSize)
    return {
        cursor = 1,
        batchSize = math.max(1, math.floor(tonumber(batchSize) or 200)),
        events = Store.sessionEvents,
        journalGeneration = tonumber(Store.identityGeneration) or 0,
        checked = 0,
        mismatches = 0,
    }
end

function H:StepConsistencyAudit(job)
    if type(job) ~= "table" then return true, job end
    if job.events ~= Store.sessionEvents
        or tonumber(job.journalGeneration) ~= (tonumber(Store.identityGeneration) or 0) then
        job.cancelled = true
        job.cancelReason = "journal_changed"
        return true, job
    end
    local events = job.events or {}
    local cursor = math.max(1, math.floor(tonumber(job.cursor) or 1))
    local processed = 0
    while cursor <= #events and processed < job.batchSize do
        local event = events[cursor]
        if type(event) == "table" then
            local ok, count = self:CompareEvent(event, true, "AUDIT")
            job.checked = job.checked + 1
            if not ok then job.mismatches = job.mismatches + (tonumber(count) or 1) end
        end
        cursor = cursor + 1
        processed = processed + 1
    end
    job.cursor = cursor
    return cursor > #events, job
end

function H:GetStatusLine()
    if self.failed == true then return "事件分层：已停用（" .. tostring(self.failure or "未知错误") .. "）" end
    if self.enabled ~= true then return "事件分层：待机（诊断关闭）" end
    local transaction = type(self.transaction) == "table"
        and (" / 重放事务 G" .. tostring(self.transaction.generation)) or ""
    local backfill = type(self.backfillJob) == "table"
        and (" / 回填 " .. tostring(self.backfillJob.cursor) .. "/" .. tostring(#(self.backfillJob.events or {}))) or ""
    return "事件分层：Fact " .. tostring(self.factCount)
        .. " / 分类 " .. tostring(self.classificationCount)
        .. " / 转换 " .. tostring(self.classificationTransitions)
        .. " / 不一致 " .. tostring(self.mismatchCount)
        .. transaction .. backfill
end

Store:SetEventShadowObserver(H)
if D.State ~= nil and D.State.config ~= nil and D.State.config.diagnosticsEnabled == true then
    local ok, err = pcall(H.OnDiagnosticsChanged, H, true)
    if not ok then H:DisableAfterFailure(err) end
end

Boot:CompletePhase("EVENT_SHADOW_READY")

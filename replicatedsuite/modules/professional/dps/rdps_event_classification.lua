ReplicatedSuiteModuleSandbox:Enter('dps', {'ReplicatedDps', 'ReplicatedDpsConfig'})
------------------------------------------------------------------------
-- Replicated DPS - production EventClassification sidecar Authority
-- Author: Replicated
--
-- Authority boundary
--   * D.EventClassifications owns every mutable classification field.
--   * Legacy CombatEvent fields are compatibility mirrors only. Runtime writes
--     enter this sidecar first, then the registered mirror adapter updates the
--     old packed-event slot so pending/UI/rollback code can continue to read it.
--   * D.EventStore.sessionEvents still owns immutable event facts and ordering.
--
-- Storage boundary
--   * Classification values are stored in column tables indexed by eventId.
--     This avoids allocating another large hash table for every combat event.
--   * A known[eventId] bit distinguishes an authoritative nil from a legacy row
--     that has not yet been imported.
--   * Full replay writes an isolated working generation. EVENT_SNAPSHOT seeds
--     every journal row incrementally; commit is one pointer swap and rollback
--     discards the working generation.
--
-- Compatibility boundary
--   * Pre-prep7 journals are imported lazily or by bounded backfill from their
--     legacy mirror fields. After import, sidecar values win even if a mirror is
--     damaged or changed without the adapter; consistency audit reports it.
--   * No persistence schema or CombatEvent fact layout changes in this stage.
------------------------------------------------------------------------

if ReplicatedDps == nil or ReplicatedDps.Boot == nil then return end

local D = ReplicatedDps
local Boot = D.Boot
if Boot.phase == "FAILED" then return end
if type(D.EventStore) ~= "table" then
    Boot:Fail("event_classification:event_store", "D.EventStore is unavailable")
    return
end
if type(D.Util) ~= "table" then
    Boot:Fail("event_classification:util", "D.Util is unavailable")
    return
end

Boot:SetPhase("EVENT_CLASSIFICATION_LOADING")

local U = D.Util
local Store = D.EventStore

D.EventClassifications = D.EventClassifications or {}
local C = D.EventClassifications

C.schemaVersion = 1
C.layoutVersion = 1

local CLASSIFICATION_FIELDS = {
    "candidateMode", "modeReason", "classificationStatus", "appliedMode",
    "applied", "pending", "thirdParty", "retiredThirdParty",
    "dormantThirdParty", "dormantPending", "dormantSummaryMode",
    "modeProvisional", "relationProvisional", "provisionalFallbackMode",
    "healRelationConflict", "friendlyFire", "opponentInternalDamage",
    "repdpsSummaryTracked", "repdpsSummaryMode", "repdpsSummaryThirdParty",
    "repdpsRetryCount", "repdpsNextRetryAt", "expiredModes",
    "sourceBindingQuality", "targetBindingQuality",
    "sourceBoundId", "targetBoundId",
    "sourceResolvedKey", "targetResolvedKey",
    "sourceObservedKind", "targetObservedKind",
    "sourceObservedKindQuality", "targetObservedKindQuality",
    "sourceBindingAmbiguous", "targetBindingAmbiguous",
    "sourceKeyAuthoritative", "targetKeyAuthoritative",
    -- New product-only classification columns. The legacy event layout never
    -- stored these values, so they are intentionally not mirrored back.
    "sourceProjectionSide", "targetProjectionSide", "projectionSideQuality",
    "pendingReason", "classificationContext", "classificationObservedAt",
}

local SIDECAR_ONLY_FIELDS = {
    sourceProjectionSide = true,
    targetProjectionSide = true,
    projectionSideQuality = true,
    pendingReason = true,
    classificationContext = true,
    classificationObservedAt = true,
}

local FIELD_SET = {}
for _, field in ipairs(CLASSIFICATION_FIELDS) do FIELD_SET[field] = true end

-- New Runtime drafts are published before classification begins. Only these
-- initial fields can be non-nil at append time; importing all 40+ columns for
-- every COMBAT_MSG wastes a full field scan before the real batch commit.
local LIVE_DRAFT_FIELDS = {
    "candidateMode", "classificationStatus",
    "sourceBindingQuality", "targetBindingQuality",
    "sourceBoundId", "targetBoundId",
    "sourceBindingAmbiguous", "targetBindingAmbiguous",
}

local TABLE_FIELDS = { expiredModes = true }

local function Counter(name, amount)
    -- These counters exist only for the diagnostic page. Avoid several table
    -- lookups and numeric conversions on every combat metric in product mode.
    if D.State == nil or D.State.config == nil
        or D.State.config.diagnosticsEnabled ~= true then
        return
    end
    local counters = D.Diagnostics and D.Diagnostics.counters or nil
    if type(counters) ~= "table" then return end
    counters[name] = (tonumber(counters[name]) or 0) + (tonumber(amount) or 1)
end

local function DiagnosticsEnabled()
    return D.State ~= nil and D.State.config ~= nil
        and D.State.config.diagnosticsEnabled == true
end

local function EventIdToken(event)
    if type(event) ~= "table" then return nil end
    local value = tonumber(event.eventId)
    if value == nil or value ~= value or value == math.huge or value == -math.huge then return nil end
    value = math.floor(value)
    if value <= 0 then return nil end
    return value
end

local function SessionIndexToken(event)
    if type(event) ~= "table" then return 0 end
    local value = math.floor(tonumber(event.repdpsSessionIndex) or 0)
    return value > 0 and value or 0
end

local function CopyValue(field, value)
    if TABLE_FIELDS[field] == true then
        return type(value) == "table" and U.DeepCopy(value) or nil
    end
    return value
end

local function NewGeneration(id, reason)
    return {
        id = math.max(0, math.floor(tonumber(id) or 0)),
        reason = tostring(reason or "UNKNOWN"),
        known = {},
        revisions = {},
        contexts = {},
        columns = {},
        count = 0,
        writes = 0,
        startedAt = type(U.NowMs) == "function" and U.NowMs() or 0,
    }
end

local function Column(generation, field)
    local columns = generation.columns
    local column = columns[field]
    if type(column) ~= "table" then
        column = {}
        columns[field] = column
    end
    return column
end

local function ReadGenerationField(generation, eventId, field)
    if type(generation) ~= "table" or generation.known[eventId] ~= true then return nil, false end
    local column = generation.columns[field]
    if type(column) ~= "table" then return nil, true end
    return column[eventId], true
end

local function WriteGenerationField(generation, eventId, field, value, alreadyCopied)
    -- A known[eventId] row already makes nil authoritative. Do not create an
    -- empty column table for fields that are absent on almost every event.
    if value == nil then
        local column = generation.columns[field]
        if type(column) == "table" then column[eventId] = nil end
        return
    end
    local column = Column(generation, field)
    if TABLE_FIELDS[field] == true and alreadyCopied ~= true then
        column[eventId] = type(value) == "table" and U.DeepCopy(value) or nil
    else
        column[eventId] = value
    end
end

local function MarkKnown(generation, eventId, context)
    if generation.known[eventId] ~= true then
        generation.known[eventId] = true
        generation.count = (tonumber(generation.count) or 0) + 1
    end
    if DiagnosticsEnabled() then
        generation.revisions[eventId] = (tonumber(generation.revisions[eventId]) or 0) + 1
        generation.contexts[eventId] = tostring(context or "UNKNOWN")
    end
    generation.writes = (tonumber(generation.writes) or 0) + 1
end

local function FreshState(reason)
    C.generationCounter = math.max(0, math.floor(tonumber(C.generationCounter) or 0)) + 1
    C.committed = NewGeneration(C.generationCounter, reason or "module_load")
    C.transaction = nil
    C.backfillJob = nil
    C.auditJob = nil
    C.mirrorReader = nil
    C.mirrorWriter = nil
    C.mismatchCount = 0
    C.lastMismatch = nil
    C.lastCommitReason = nil
    C.lastRollbackReason = nil
    C.lastResetReason = tostring(reason or "module_load")
    C.activeMutation = nil
    C.failed = false
end

FreshState("module_load")

function C:IsClassificationField(field)
    return FIELD_SET[field] == true
end

function C:GetFieldNames()
    return CLASSIFICATION_FIELDS
end

-- Runtime metatable adapter uses this immutable lookup table directly so reads
-- of non-classification fact fields do not pay a Lua method call per access.
function C:GetAdapterFieldSet()
    return FIELD_SET
end

function C:RegisterLegacyMirrorAdapter(reader, writer)
    if type(reader) ~= "function" or type(writer) ~= "function" then
        error("EventClassification mirror adapter requires reader and writer", 2)
    end
    self.mirrorReader = reader
    self.mirrorWriter = writer
    if self.backfillJob == nil then self:BeginBackfill("mirror_adapter_registered") end
    return true
end

function C:CurrentGeneration()
    return type(self.transaction) == "table" and self.transaction.working or self.committed
end

function C:CommittedGeneration()
    return self.committed
end

-- Read-only generation boundary used by the diagnostic local-replay planner.
-- Callers receive copied table fields and cannot mutate the classification
-- Authority through a retained generation reference.
function C:GetFromGeneration(generation, eventId, field)
    if FIELD_SET[field] ~= true then return nil, false end
    eventId = math.floor(tonumber(eventId) or 0)
    if eventId <= 0 then return nil, false end
    local value, known = ReadGenerationField(generation, eventId, field)
    return CopyValue(field, value), known
end

function C:ReadLegacyMirror(event, field)
    local reader = self.mirrorReader
    if type(reader) == "function" then return reader(event, field) end
    return rawget(event, field)
end

function C:WriteLegacyMirror(event, field, value)
    if SIDECAR_ONLY_FIELDS[field] == true then return true end
    if TABLE_FIELDS[field] == true then
        value = type(value) == "table" and U.DeepCopy(value) or nil
    end
    local writer = self.mirrorWriter
    if type(writer) == "function" then return writer(event, field, value) end
    rawset(event, field, value)
    return true
end

-- Live parser drafts have no session index and therefore cannot already belong
-- to the Classification Authority. Populate only the compact compatibility
-- mirror here; OnLegacyEventAppended imports the complete initial state once.
function C:WriteLiveDraft(event, candidateMode, classificationStatus,
        sourceBindingQuality, targetBindingQuality, sourceBoundId, targetBoundId,
        sourceBindingAmbiguous, targetBindingAmbiguous)
    self:WriteLegacyMirror(event, "candidateMode", candidateMode)
    self:WriteLegacyMirror(event, "classificationStatus", classificationStatus)
    self:WriteLegacyMirror(event, "sourceBindingQuality", sourceBindingQuality)
    self:WriteLegacyMirror(event, "targetBindingQuality", targetBindingQuality)
    if sourceBoundId ~= nil then self:WriteLegacyMirror(event, "sourceBoundId", sourceBoundId) end
    if targetBoundId ~= nil then self:WriteLegacyMirror(event, "targetBoundId", targetBoundId) end
    if sourceBindingAmbiguous == true then
        self:WriteLegacyMirror(event, "sourceBindingAmbiguous", true)
    end
    if targetBindingAmbiguous == true then
        self:WriteLegacyMirror(event, "targetBindingAmbiguous", true)
    end
    return true
end

local function LegacyPendingReason(readMirror, event, status)
    if readMirror(event, "healRelationConflict") == true then return "HEAL_RELATION_CONFLICT" end
    if readMirror(event, "dormantPending") == true then return "DORMANT_PENDING" end
    if readMirror(event, "dormantThirdParty") == true then return "DORMANT_THIRD_PARTY" end
    if readMirror(event, "thirdParty") == true then return "THIRD_PARTY_UNOWNED" end
    if readMirror(event, "pending") == true then
        return status ~= nil and tostring(status) or "UNRESOLVED_RELATION"
    end
    return nil
end

function C:ImportLegacy(event, context, targetGeneration)
    local eventId = EventIdToken(event)
    if eventId == nil then return false end
    local generation = targetGeneration or self:CurrentGeneration()
    if generation.known[eventId] == true then return true end
    for _, field in ipairs(CLASSIFICATION_FIELDS) do
        if SIDECAR_ONLY_FIELDS[field] ~= true then
            WriteGenerationField(generation, eventId, field, self:ReadLegacyMirror(event, field))
        end
    end
    if DiagnosticsEnabled() then
        local status = self:ReadLegacyMirror(event, "classificationStatus")
        local statusText = tostring(status or "")
        local applied = string.sub(statusText, 1, 8) == "APPLIED_"
        WriteGenerationField(generation, eventId, "projectionSideQuality",
            applied and "LEGACY_UNRECORDED" or "NOT_APPLICABLE")
        WriteGenerationField(generation, eventId, "pendingReason",
            LegacyPendingReason(function(row, field) return self:ReadLegacyMirror(row, field) end,
                event, status))
        WriteGenerationField(generation, eventId, "classificationContext", context or "LEGACY_IMPORT")
    end
    MarkKnown(generation, eventId, context or "LEGACY_IMPORT")
    Counter("eventClassificationImports", 1)
    return true
end

-- High-frequency classification attempts mutate many compatibility fields on
-- one event. Writing every field immediately would perform dozens of sidecar
-- revisions and mirror writes per COMBAT_MSG. A mutation batch keeps staged
-- values in one small reusable overlay, lets event.field reads see those values,
-- then publishes all columns once (Authority first) and mirrors second.
local function ReleaseMutation(self, mutation)
    if type(mutation) ~= "table" then return end
    local touched = mutation.touched
    if type(touched) == "table" then
        for index = 1, #touched do
            local field = touched[index]
            mutation.values[field] = nil
            mutation.touchedSet[field] = nil
            touched[index] = nil
        end
    end
    mutation.event = nil
    mutation.eventId = nil
    mutation.context = nil
    if self.mutationPool == nil then self.mutationPool = mutation end
end

function C:AbortMutation(reason)
    local mutation = self.activeMutation
    if type(mutation) ~= "table" then return false end
    self.lastMutationAbortReason = tostring(reason or "ABORTED")
    self.activeMutation = nil
    ReleaseMutation(self, mutation)
    Counter("eventClassificationMutationAborts", 1)
    return true
end

function C:IsMutating(event)
    local mutation = self.activeMutation
    return type(mutation) == "table" and mutation.event == event
end

function C:BeginMutation(event, context)
    local eventId = EventIdToken(event)
    if eventId == nil then return false end
    local active = self.activeMutation
    if type(active) == "table" then
        if active.event == event and active.eventId == eventId then return true end
        self:AbortMutation("SUPERSEDED")
    end
    local mutation = self.mutationPool
    self.mutationPool = nil
    if type(mutation) ~= "table" then
        mutation = { values = {}, touched = {}, touchedSet = {} }
    end
    mutation.event = event
    mutation.eventId = eventId
    mutation.context = tostring(context or "CLASSIFICATION_ATTEMPT")
    self.activeMutation = mutation
    return true
end

local function StageMutationField(mutation, field, value)
    if mutation.touchedSet[field] ~= true then
        mutation.touchedSet[field] = true
        mutation.touched[#mutation.touched + 1] = field
    end
    if TABLE_FIELDS[field] == true then
        mutation.values[field] = type(value) == "table" and U.DeepCopy(value) or nil
    else
        mutation.values[field] = value
    end
end

function C:GetMutationValue(event, field)
    local mutation = self.activeMutation
    if type(mutation) ~= "table" or mutation.event ~= event
        or mutation.touchedSet[field] ~= true then return nil, false end
    local value = mutation.values[field]
    if TABLE_FIELDS[field] == true then
        value = type(value) == "table" and U.DeepCopy(value) or nil
    end
    return value, true
end

function C:CommitMutation(event, context, ...)
    local mutation = self.activeMutation
    if type(mutation) ~= "table" or mutation.event ~= event then return false end
    local pairCount = select("#", ...)
    if pairCount % 2 ~= 0 then error("EventClassification CommitMutation requires field/value pairs", 2) end
    for index = 1, pairCount, 2 do
        local field = select(index, ...)
        if FIELD_SET[field] ~= true then
            error("Unknown EventClassification field: " .. tostring(field), 2)
        end
        StageMutationField(mutation, field, select(index + 1, ...))
    end

    local eventId = mutation.eventId
    local generation = self:CurrentGeneration()
    if generation.known[eventId] ~= true then self:Ensure(event, context or mutation.context) end
    if generation.known[eventId] ~= true then
        self.activeMutation = nil
        error("EventClassification mutation commit could not acquire Authority row", 2)
    end

    -- Authority first.
    for _, field in ipairs(mutation.touched) do
        -- StageMutationField already detached table-valued fields.
        WriteGenerationField(generation, eventId, field, mutation.values[field], true)
    end
    MarkKnown(generation, eventId, context or mutation.context)

    -- Compatibility mirror second. Clear the active overlay before mirror writes
    -- so adapter reads observe the newly committed Authority, not staged values.
    self.activeMutation = nil
    for _, field in ipairs(mutation.touched) do
        if SIDECAR_ONLY_FIELDS[field] ~= true then
            self:WriteLegacyMirror(event, field, mutation.values[field])
        end
    end
    ReleaseMutation(self, mutation)
    Counter("eventClassificationBatchedWrites", 1)
    return true
end

function C:Ensure(event, context)
    local eventId = EventIdToken(event)
    if eventId == nil then return false end
    local generation = self:CurrentGeneration()
    if generation.known[eventId] == true then return true end
    -- Parser drafts are mirror-only until EventStore publishes them. Importing
    -- them here would allocate a long-lived sidecar row for parse failures,
    -- environment events and other rows that never enter the journal.
    if SessionIndexToken(event) < 1 then return false end

    -- During a replay transaction the committed generation remains the old
    -- product truth. Seed the working row from committed when possible; only
    -- pre-prep7 rows fall back to the old mirror.
    if type(self.transaction) == "table" and self.committed.known[eventId] == true then
        for _, field in ipairs(CLASSIFICATION_FIELDS) do
            local value = ReadGenerationField(self.committed, eventId, field)
            WriteGenerationField(generation, eventId, field, value)
        end
        MarkKnown(generation, eventId, context or "TRANSACTION_SEED")
        return true
    end
    return self:ImportLegacy(event, context or "LAZY_IMPORT", generation)
end

function C:Get(event, field, legacyFallback)
    if FIELD_SET[field] ~= true then return legacyFallback end
    local staged, stagedKnown = self:GetMutationValue(event, field)
    if stagedKnown then return staged end
    local eventId = EventIdToken(event)
    if eventId == nil then return legacyFallback end
    local generation = self:CurrentGeneration()
    local value, known = ReadGenerationField(generation, eventId, field)
    if known then
        if TABLE_FIELDS[field] == true then value = type(value) == "table" and U.DeepCopy(value) or nil end
        return value
    end
    if self:Ensure(event, "READ_IMPORT") then
        value = ReadGenerationField(generation, eventId, field)
        if TABLE_FIELDS[field] == true then value = type(value) == "table" and U.DeepCopy(value) or nil end
        return value
    end
    return legacyFallback
end

function C:GetCommitted(event, field, legacyFallback)
    if FIELD_SET[field] ~= true then return legacyFallback end
    local eventId = EventIdToken(event)
    if eventId == nil then return legacyFallback end
    local value, known = ReadGenerationField(self.committed, eventId, field)
    if known then return CopyValue(field, value) end
    if type(self.transaction) ~= "table" and self:ImportLegacy(event, "COMMITTED_READ_IMPORT", self.committed) then
        value = ReadGenerationField(self.committed, eventId, field)
        return CopyValue(field, value)
    end
    return legacyFallback
end

function C:SetMany(event, context, ...)
    local eventId = EventIdToken(event)
    if eventId == nil then error("EventClassification write requires a positive eventId", 2) end
    local pairCount = select("#", ...)
    if pairCount % 2 ~= 0 then error("EventClassification SetMany requires field/value pairs", 2) end
    local mutation = self.activeMutation
    if type(mutation) == "table" and mutation.event == event then
        for index = 1, pairCount, 2 do
            local field = select(index, ...)
            if FIELD_SET[field] ~= true then
                error("Unknown EventClassification field: " .. tostring(field), 2)
            end
            StageMutationField(mutation, field, select(index + 1, ...))
        end
        return true
    end
    local generation = self:CurrentGeneration()
    if generation.known[eventId] ~= true then self:Ensure(event, context or "WRITE_IMPORT") end

    -- Authority first: every sidecar column is updated before any legacy slot.
    for index = 1, pairCount, 2 do
        local field = select(index, ...)
        if FIELD_SET[field] ~= true then
            error("Unknown EventClassification field: " .. tostring(field), 2)
        end
        WriteGenerationField(generation, eventId, field, select(index + 1, ...))
    end
    MarkKnown(generation, eventId, context or "WRITE")

    -- Compatibility mirror second. A mirror failure is fatal to this operation;
    -- sidecar remains authoritative and the caller's protected transaction can
    -- roll back instead of silently continuing with divergent legacy readers.
    for index = 1, pairCount, 2 do
        local field = select(index, ...)
        if SIDECAR_ONLY_FIELDS[field] ~= true then
            self:WriteLegacyMirror(event, field, select(index + 1, ...))
        end
    end
    Counter("eventClassificationWrites", 1)
    return true
end

function C:Set(event, field, value, context)
    return self:SetMany(event, context or "WRITE", field, value)
end

-- Called by REPLAY_META.__newindex. The adapter must return true to tell the
-- metatable that the sidecar and raw mirror have both been updated.
function C:WriteLegacyField(event, field, value, context)
    if FIELD_SET[field] ~= true then return false end
    local mutation = self.activeMutation
    if type(mutation) == "table" and mutation.event == event then
        StageMutationField(mutation, field, value)
        return true
    end
    local eventId = EventIdToken(event)
    local generation = self:CurrentGeneration()
    if eventId == nil or (SessionIndexToken(event) < 1
        and generation.known[eventId] ~= true) then
        -- Draft creation is mirror-only. EventStore:AppendSessionEvent imports
        -- the complete initial row exactly once before it becomes visible.
        self:WriteLegacyMirror(event, field, value)
        return true
    end
    self:SetMany(event, context or "LEGACY_FIELD_WRITE", field, value)
    return true
end

function C:DiscardUnjournaled(event, reason)
    if type(event) ~= "table" then return false end
    if math.floor(tonumber(event.repdpsSessionIndex) or 0) > 0 then return false end
    local eventId = EventIdToken(event)
    if eventId == nil then return false end
    local generation = self:CurrentGeneration()
    if generation.known[eventId] ~= true then return false end
    generation.known[eventId] = nil
    generation.revisions[eventId] = nil
    generation.contexts[eventId] = nil
    for _, column in pairs(generation.columns) do column[eventId] = nil end
    generation.count = math.max(0, (tonumber(generation.count) or 0) - 1)
    self.lastDiscardReason = tostring(reason or "UNJOURNALED")
    Counter("eventClassificationDiscards", 1)
    return true
end

function C:SetExpiredMode(event, mode, enabled, context)
    mode = tostring(mode or "")
    if mode ~= "PVP" and mode ~= "PVE" then return false end
    local current = self:Get(event, "expiredModes", nil)
    current = type(current) == "table" and current or {}
    if enabled == false then current[mode] = nil else current[mode] = true end
    if next(current) == nil then current = nil end
    return self:Set(event, "expiredModes", current, context or "EXPIRED_MODE")
end

function C:Snapshot(event, committedOnly)
    local eventId = EventIdToken(event)
    if eventId == nil then return nil end
    local generation = committedOnly == true and self.committed or self:CurrentGeneration()
    if generation.known[eventId] ~= true then
        if committedOnly == true and type(self.transaction) == "table" then return nil end
        self:Ensure(event, "SNAPSHOT_IMPORT")
        generation = committedOnly == true and self.committed or self:CurrentGeneration()
    end
    if generation.known[eventId] ~= true then return nil end
    local result = {
        eventId = eventId,
        generation = generation.id,
        revision = generation.revisions[eventId],
        context = generation.contexts[eventId],
    }
    for _, field in ipairs(CLASSIFICATION_FIELDS) do
        local value = ReadGenerationField(generation, eventId, field)
        result[field] = CopyValue(field, value)
    end
    return result
end

function C:SeedTransactionEvent(event, context)
    local transaction = self.transaction
    if type(transaction) ~= "table" then return false end
    local eventId = EventIdToken(event)
    if eventId == nil then return false end
    if transaction.working.known[eventId] == true then return true end
    if self.committed.known[eventId] ~= true then
        self:ImportLegacy(event, "PRE_TRANSACTION_IMPORT", self.committed)
    end
    for _, field in ipairs(CLASSIFICATION_FIELDS) do
        local value = ReadGenerationField(self.committed, eventId, field)
        WriteGenerationField(transaction.working, eventId, field, value)
    end
    MarkKnown(transaction.working, eventId, context or "REPLAY_SNAPSHOT")
    transaction.seeded = (tonumber(transaction.seeded) or 0) + 1
    return true
end

function C:BeginTransaction(reason, eventTotal)
    if type(self.transaction) == "table" then self:RollbackTransaction("superseded") end
    self.generationCounter = math.max(0, math.floor(tonumber(self.generationCounter) or 0)) + 1
    self.transaction = {
        reason = tostring(reason or "FULL_REPLAY"),
        eventTotal = math.max(0, math.floor(tonumber(eventTotal) or 0)),
        working = NewGeneration(self.generationCounter, reason or "FULL_REPLAY"),
        seeded = 0,
        startedAt = type(U.NowMs) == "function" and U.NowMs() or 0,
    }
    Counter("eventClassificationTransactions", 1)
    return true
end

function C:CommitTransaction()
    local transaction = self.transaction
    if type(transaction) ~= "table" then return false end
    if transaction.eventTotal > 0 and transaction.working.count < transaction.eventTotal then
        error("EventClassification transaction is incomplete: "
            .. tostring(transaction.working.count) .. "/" .. tostring(transaction.eventTotal), 2)
    end
    self.committed = transaction.working
    self.lastCommitReason = transaction.reason
    self.transaction = nil
    self.backfillJob = nil
    Counter("eventClassificationCommits", 1)
    return true
end

function C:RollbackTransaction(reason)
    if type(self.transaction) ~= "table" then return false end
    self.lastRollbackReason = tostring(reason or self.transaction.reason or "ROLLBACK")
    self.transaction = nil
    Counter("eventClassificationRollbacks", 1)
    return true
end

local function ImportLiveDraft(self, event, context, generation)
    local eventId = EventIdToken(event)
    if eventId == nil then return false end
    if generation.known[eventId] == true then return true end
    for _, field in ipairs(LIVE_DRAFT_FIELDS) do
        local value = self:ReadLegacyMirror(event, field)
        if value ~= nil then WriteGenerationField(generation, eventId, field, value) end
    end
    MarkKnown(generation, eventId, context or "LIVE_APPEND")
    Counter("eventClassificationLiveDraftImports", 1)
    return true
end

function C:OnLegacyEventAppended(event, sessionIndex)
    local generation = type(self.transaction) == "table"
        and self.transaction.working or self.committed
    local context = type(self.transaction) == "table"
        and "APPEND_DURING_TRANSACTION" or "APPEND"
    if type(event) == "table" and event.repdpsPacked == true then
        return ImportLiveDraft(self, event, context, generation)
    end
    return self:ImportLegacy(event, context, generation)
end

function C:BeginBackfill(reason, batchSize)
    if type(self.transaction) == "table" then return false end
    self.backfillJob = {
        reason = tostring(reason or "BACKFILL"),
        cursor = 1,
        batchSize = math.max(1, math.floor(tonumber(batchSize) or 480)),
        generation = tonumber(Store.identityGeneration) or 0,
        journal = Store.sessionEvents,
        imported = 0,
    }
    return true
end

function C:StepBackfill(batchSize)
    local job = self.backfillJob
    if type(job) ~= "table" then return true end
    if type(self.transaction) == "table" then return false end
    if job.journal ~= Store.sessionEvents or job.generation ~= (tonumber(Store.identityGeneration) or 0) then
        self:BeginBackfill("journal_changed", batchSize)
        job = self.backfillJob
    end
    local events = Store.sessionEvents or {}
    local budget = math.max(1, math.floor(tonumber(batchSize) or job.batchSize or 480))
    local processed = 0
    local cursor = job.cursor
    while cursor <= #events and processed < budget do
        local event = events[cursor]
        if type(event) == "table" then
            if self.committed.known[EventIdToken(event) or -1] ~= true then
                self:ImportLegacy(event, job.reason, self.committed)
                job.imported = job.imported + 1
            end
        end
        cursor = cursor + 1
        processed = processed + 1
    end
    job.cursor = cursor
    if cursor > #events then
        self.backfillJob = nil
        Counter("eventClassificationBackfills", 1)
        return true
    end
    return false
end

function C:OnEventStoreReset(reason)
    if type(self.transaction) == "table" then self:RollbackTransaction("journal_reset") end
    self.generationCounter = math.max(0, math.floor(tonumber(self.generationCounter) or 0)) + 1
    self.committed = NewGeneration(self.generationCounter, reason or "JOURNAL_RESET")
    self.lastResetReason = tostring(reason or "JOURNAL_RESET")
    self:BeginBackfill(reason or "JOURNAL_RESET")
    Counter("eventClassificationResets", 1)
    return true
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

function C:CompareMirror(event, context)
    local eventId = EventIdToken(event)
    if eventId == nil then return false end
    if self.committed.known[eventId] ~= true then self:ImportLegacy(event, "AUDIT_IMPORT", self.committed) end
    local equal = true
    for _, field in ipairs(CLASSIFICATION_FIELDS) do
        if SIDECAR_ONLY_FIELDS[field] ~= true then
            local expected = ReadGenerationField(self.committed, eventId, field)
            local actual = self:ReadLegacyMirror(event, field)
            if not SameValue(field, expected, actual) then
            equal = false
            self.mismatchCount = (tonumber(self.mismatchCount) or 0) + 1
            self.lastMismatch = {
                eventId = eventId,
                field = field,
                expected = CopyValue(field, expected),
                actual = CopyValue(field, actual),
                context = tostring(context or "AUDIT"),
            }
                Counter("eventClassificationMirrorMismatches", 1)
                break
            end
        end
    end
    return equal
end

function C:BeginConsistencyAudit(batchSize)
    if type(self.transaction) == "table" then return false end
    self.auditJob = {
        cursor = 1,
        batchSize = math.max(1, math.floor(tonumber(batchSize) or 480)),
        journal = Store.sessionEvents,
        generation = tonumber(Store.identityGeneration) or 0,
        checked = 0,
        mismatches = 0,
    }
    return true
end

function C:StepConsistencyAudit(batchSize)
    local job = self.auditJob
    if type(job) ~= "table" then return true end
    if type(self.transaction) == "table" then return false end
    if job.journal ~= Store.sessionEvents or job.generation ~= (tonumber(Store.identityGeneration) or 0) then
        self.auditJob = nil
        return true
    end
    local events = Store.sessionEvents or {}
    local budget = math.max(1, math.floor(tonumber(batchSize) or job.batchSize or 480))
    local processed = 0
    while job.cursor <= #events and processed < budget do
        local event = events[job.cursor]
        if type(event) == "table" then
            job.checked = job.checked + 1
            if not self:CompareMirror(event, "CONSISTENCY_AUDIT") then
                job.mismatches = job.mismatches + 1
            end
        end
        job.cursor = job.cursor + 1
        processed = processed + 1
    end
    if job.cursor > #events then
        self.auditJob = nil
        Counter("eventClassificationAudits", 1)
        return true
    end
    return false
end

function C:GetStatusLine()
    local committed = self.committed or {}
    local text = "分类旁路 v" .. tostring(self.schemaVersion)
        .. " / 事件 " .. tostring(committed.count or 0)
        .. " / 写入 " .. tostring(committed.writes or 0)
    if type(self.transaction) == "table" then
        text = text .. " / 重放工作代次 " .. tostring(self.transaction.working.count or 0)
            .. "/" .. tostring(self.transaction.eventTotal or 0)
    elseif self.backfillJob ~= nil then
        text = text .. " / 回填 " .. tostring(self.backfillJob.cursor or 1)
    end
    if (tonumber(self.mismatchCount) or 0) > 0 then
        text = text .. " / 镜像差异 " .. tostring(self.mismatchCount)
    end
    return text
end

if type(Store.SetClassificationAuthority) == "function" then
    Store:SetClassificationAuthority(C)
else
    Store.classificationAuthority = C
end

Boot:CompletePhase("EVENT_CLASSIFICATION_READY")

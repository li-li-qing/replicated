ReplicatedSuiteModuleSandbox:Enter('dps', {'ReplicatedDps', 'ReplicatedDpsConfig'})
------------------------------------------------------------------------
-- Replicated DPS - production immutable CombatEvent Fact Authority
-- Author: Replicated
--
-- Authority boundary
--   * D.EventStore owns event ordering and the legacy eventId/session anchor.
--   * D.EventFacts owns immutable combat payload facts after journal publish.
--   * Legacy packed-event fact slots are compatibility mirrors. Runtime reads
--     are routed through this Authority; creation writes are allowed only before
--     the row enters EventStore. Post-publish writes must be idempotent, except
--     for the explicit corruption-repair API below.
--   * Mutable identity interpretation and classification never belong here.
--
-- Storage boundary
--   * Facts use column tables indexed by eventId. No per-event Authority hash
--     table is allocated on the combat hot path.
--   * initialSource/Target keys are sidecar-only creation observations. Later
--     teamname:* -> id:* promotion does not mutate those facts.
--   * Existing journals are imported lazily or by explicit bounded backfill.
--     No full journal scan runs in Tick or a combat callback.
--
-- Repair boundary
--   * Normal classification cannot mutate a Fact.
--   * A damaged legacy timestamp/amount/category can be replaced only through
--     RepairForClassification, which records a new Fact revision before updating
--     the compatibility mirror. This is corruption recovery, not classification.
------------------------------------------------------------------------

if ReplicatedDps == nil or ReplicatedDps.Boot == nil then return end

local D = ReplicatedDps
local Boot = D.Boot
if Boot.phase == "FAILED" then return end
if type(D.EventStore) ~= "table" then
    Boot:Fail("event_facts:event_store", "D.EventStore is unavailable")
    return
end
if type(D.Util) ~= "table" then
    Boot:Fail("event_facts:util", "D.Util is unavailable")
    return
end

Boot:SetPhase("EVENT_FACTS_LOADING")

local U = D.Util
local Store = D.EventStore

D.EventFacts = D.EventFacts or {}
local F = D.EventFacts

F.schemaVersion = 1
F.layoutVersion = 1

-- eventId is stored and audited as a Fact copy, but remains the EventStore
-- ordering/index anchor during this transition. It is intentionally excluded
-- from the REPLAY_META adapter field set so journal repair can canonicalize IDs
-- before a new bounded Fact generation is rebuilt.
local FACT_FIELDS = {
    "eventId", "timestamp", "eventType", "category",
    "sourceName", "targetName", "abilityId", "abilityName", "amount",
    "parseStatus", "environmental", "inferredLastHit",
    "deathNoticeAt", "lastHitMatchReason", "linkedDamageEventId",
    "initialSourceKey", "initialTargetKey",
    "initialSourceBoundId", "initialTargetBoundId",
}

local MIRRORED_FACT_FIELDS = {
    "timestamp", "eventType", "category",
    "sourceName", "targetName", "abilityId", "abilityName", "amount",
    "parseStatus", "environmental", "inferredLastHit",
    "deathNoticeAt", "lastHitMatchReason", "linkedDamageEventId",
}

local SIDECAR_ONLY_FIELDS = {
    initialSourceKey = true,
    initialTargetKey = true,
    initialSourceBoundId = true,
    initialTargetBoundId = true,
}

-- New live rows never carry last-hit payload after RC3 removed that feature
-- from the combat hot path. Import only facts that can actually exist on a new
-- packed event; full legacy/backfill imports still retain all compatibility
-- fields for old hot-reload rows.
local LIVE_FACT_FIELDS = {
    "eventId", "timestamp", "eventType", "category",
    "sourceName", "targetName", "abilityId", "abilityName", "amount",
    "parseStatus", "environmental", "inferredLastHit",
    "initialSourceKey", "initialTargetKey",
    "initialSourceBoundId", "initialTargetBoundId",
}

local FIELD_SET = {}
for _, field in ipairs(FACT_FIELDS) do FIELD_SET[field] = true end
local ADAPTER_FIELD_SET = {}
for _, field in ipairs(MIRRORED_FACT_FIELDS) do ADAPTER_FIELD_SET[field] = true end

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

local function FiniteNumber(value, fallback)
    if type(U.FiniteNumber) == "function" then return U.FiniteNumber(value, fallback) end
    local number = tonumber(value)
    if number == nil or number ~= number or number == math.huge or number == -math.huge then
        return fallback
    end
    return number
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
        repairs = 0,
        startedAt = type(U.NowMs) == "function" and U.NowMs() or 0,
    }
end

local function Column(generation, field)
    local column = generation.columns[field]
    if type(column) ~= "table" then
        column = {}
        generation.columns[field] = column
    end
    return column
end

local function ReadGenerationField(generation, eventId, field)
    if type(generation) ~= "table" or generation.known[eventId] ~= true then return nil, false end
    local column = generation.columns[field]
    if type(column) ~= "table" then return nil, true end
    return column[eventId], true
end

local function WriteGenerationField(generation, eventId, field, value)
    -- generation.known[eventId] is the presence bit, so nil facts need no
    -- physical column entry. Avoiding empty columns and nil assignments keeps
    -- the 4,000-row correction window compact without changing read semantics.
    if value == nil then return end
    Column(generation, field)[eventId] = value
end

local function DiagnosticsEnabled()
    return D.State ~= nil and D.State.config ~= nil
        and D.State.config.diagnosticsEnabled == true
end

local function MarkKnown(generation, eventId, context, repaired)
    if generation.known[eventId] ~= true then
        generation.known[eventId] = true
        generation.count = (tonumber(generation.count) or 0) + 1
    end
    if DiagnosticsEnabled() then
        generation.revisions[eventId] = (tonumber(generation.revisions[eventId]) or 0) + 1
        generation.contexts[eventId] = tostring(context or "UNKNOWN")
    end
    generation.writes = (tonumber(generation.writes) or 0) + 1
    if repaired == true then generation.repairs = (tonumber(generation.repairs) or 0) + 1 end
end

local function SameValue(field, left, right)
    if field == "eventId" or field == "timestamp" or field == "amount"
        or field == "deathNoticeAt" or field == "linkedDamageEventId" then
        local a = tonumber(left)
        local b = tonumber(right)
        if a ~= nil and b ~= nil then return math.abs(a - b) <= 0.000001 end
    end
    return left == right
end

local function FreshState(reason)
    F.generationCounter = math.max(0, math.floor(tonumber(F.generationCounter) or 0)) + 1
    F.committed = NewGeneration(F.generationCounter, reason or "module_load")
    F.backfillJob = nil
    F.auditJob = nil
    F.mirrorReader = nil
    F.mirrorWriter = nil
    F.mismatchCount = 0
    F.lastMismatch = nil
    F.lastRepair = nil
    F.lastResetReason = tostring(reason or "module_load")
    F.failed = false
end

FreshState("module_load")

function F:GetFieldNames()
    return FACT_FIELDS
end

function F:IsFactField(field)
    return FIELD_SET[field] == true
end

function F:GetAdapterFieldSet()
    return ADAPTER_FIELD_SET
end

-- Direct read boundary for columnar consumers. Unlike Snapshot(), this does not
-- allocate a per-event table and is therefore safe for bounded EventBlock work.
function F:GetCommittedField(eventId, field)
    eventId = math.floor(tonumber(eventId) or 0)
    if eventId <= 0 or FIELD_SET[field] ~= true then return nil, false end
    return ReadGenerationField(self.committed, eventId, field)
end

function F:SetEventBlockObserver(observer)
    self.eventBlockObserver = type(observer) == "table" and observer or nil
end

local function NotifyEventBlockFactRepair(self, eventId, context)
    local observer = self.eventBlockObserver
    if type(observer) ~= "table" or type(observer.OnFactAuthorityRepaired) ~= "function" then return end
    local ok, err = pcall(observer.OnFactAuthorityRepaired, observer, eventId, context)
    if not ok and type(observer.DisableAfterFailure) == "function" then
        pcall(observer.DisableAfterFailure, observer, err)
    end
end

function F:RegisterLegacyMirrorAdapter(reader, writer)
    if type(reader) ~= "function" or type(writer) ~= "function" then
        error("EventFacts mirror adapter requires reader and writer", 2)
    end
    self.mirrorReader = reader
    self.mirrorWriter = writer
    if self.backfillJob == nil then self:BeginBackfill("mirror_adapter_registered") end
    return true
end

function F:ReadLegacyMirror(event, field)
    local reader = self.mirrorReader
    if type(reader) == "function" then return reader(event, field) end
    return rawget(event, field)
end

function F:WriteLegacyMirror(event, field, value)
    local writer = self.mirrorWriter
    if type(writer) == "function" then return writer(event, field, value) end
    rawset(event, field, value)
    return true
end

local function EventIdToken(self, event, explicitValue)
    if type(event) ~= "table" then return nil end
    local value = explicitValue
    if value == nil then value = self:ReadLegacyMirror(event, "eventId") end
    value = FiniteNumber(value, nil)
    if value == nil then return nil end
    value = math.floor(value)
    if value <= 0 then return nil end
    return value
end

local function SessionIndexToken(self, event)
    local value = FiniteNumber(self:ReadLegacyMirror(event, "repdpsSessionIndex"), 0) or 0
    return math.floor(value)
end

local function LegacyFactValue(self, event, field)
    if field == "initialSourceKey" then return self:ReadLegacyMirror(event, "sourceKey") end
    if field == "initialTargetKey" then return self:ReadLegacyMirror(event, "targetKey") end
    if field == "initialSourceBoundId" then return self:ReadLegacyMirror(event, "sourceBoundId") end
    if field == "initialTargetBoundId" then return self:ReadLegacyMirror(event, "targetBoundId") end
    return self:ReadLegacyMirror(event, field)
end

function F:ImportLegacy(event, context, targetGeneration)
    local eventId = EventIdToken(self, event)
    if eventId == nil then return false end
    local generation = targetGeneration or self.committed
    if generation.known[eventId] == true then return true end
    for _, field in ipairs(FACT_FIELDS) do
        WriteGenerationField(generation, eventId, field, LegacyFactValue(self, event, field))
    end
    MarkKnown(generation, eventId, context or "LEGACY_IMPORT", false)
    Counter("eventFactImports", 1)
    return true
end

function F:Ensure(event, context)
    local eventId = EventIdToken(self, event)
    if eventId == nil then return false end
    if self.committed.known[eventId] == true then return true end
    -- Do not turn parser drafts or excluded environment rows into long-lived
    -- facts. Only EventStore-published rows may be imported lazily.
    if SessionIndexToken(self, event) < 1 then return false end
    return self:ImportLegacy(event, context or "LAZY_IMPORT", self.committed)
end

function F:Get(event, field, legacyFallback)
    if ADAPTER_FIELD_SET[field] ~= true then return legacyFallback end
    local eventId = EventIdToken(self, event)
    if eventId == nil then return legacyFallback end
    local value, known = ReadGenerationField(self.committed, eventId, field)
    if known then return value end
    if self:Ensure(event, "READ_IMPORT") then
        value = ReadGenerationField(self.committed, eventId, field)
        return value
    end
    return legacyFallback
end

-- REPLAY_META creation writes arrive here before repdpsSessionIndex is assigned.
-- They remain mirror-only until EventStore explicitly publishes the row. After
-- publish, an ordinary write may only repeat the exact authoritative value.
function F:WriteLegacyField(event, field, value, context)
    if ADAPTER_FIELD_SET[field] ~= true then return false end
    local eventId = EventIdToken(self, event)
    if eventId == nil or SessionIndexToken(self, event) < 1
        or self.committed.known[eventId] ~= true then
        self:WriteLegacyMirror(event, field, value)
        return true
    end
    local expected = ReadGenerationField(self.committed, eventId, field)
    if not SameValue(field, expected, value) then
        error("CombatEvent Fact is immutable after journal publish: " .. tostring(field), 2)
    end
    self:WriteLegacyMirror(event, field, value)
    return true
end

local function ImportLiveDraft(self, event, generation)
    local eventId = EventIdToken(self, event)
    if eventId == nil then return false end
    if generation.known[eventId] == true then return true end
    for _, field in ipairs(LIVE_FACT_FIELDS) do
        WriteGenerationField(generation, eventId, field, LegacyFactValue(self, event, field))
    end
    MarkKnown(generation, eventId, "LIVE_APPEND", false)
    Counter("eventFactLiveDraftImports", 1)
    return true
end

function F:OnLegacyEventAppended(event, sessionIndex)
    local eventId = EventIdToken(self, event)
    if eventId == nil then error("EventFacts append requires a positive eventId", 2) end
    if self.committed.known[eventId] == true then
        -- Replacing an event object during compaction is legal only when every
        -- mirrored Fact remains identical to the committed payload.
        for _, field in ipairs(MIRRORED_FACT_FIELDS) do
            local expected = ReadGenerationField(self.committed, eventId, field)
            local actual = self:ReadLegacyMirror(event, field)
            if not SameValue(field, expected, actual) then
                error("EventFacts append conflicts with committed Fact: " .. tostring(field), 2)
            end
        end
        return true
    end
    local imported
    if type(event) == "table" and event.repdpsPacked == true then
        imported = ImportLiveDraft(self, event, self.committed)
    else
        imported = self:ImportLegacy(event, "APPEND", self.committed)
    end
    if imported ~= true then error("EventFacts failed to import appended event", 2) end
    Counter("eventFactAppends", 1)
    return true
end

function F:DiscardUnjournaled(event, reason)
    if type(event) ~= "table" then return false end
    if SessionIndexToken(self, event) > 0 then return false end
    local eventId = EventIdToken(self, event)
    if eventId == nil or self.committed.known[eventId] ~= true then return false end
    self.committed.known[eventId] = nil
    self.committed.revisions[eventId] = nil
    self.committed.contexts[eventId] = nil
    for _, column in pairs(self.committed.columns) do column[eventId] = nil end
    self.committed.count = math.max(0, (tonumber(self.committed.count) or 0) - 1)
    self.lastDiscardReason = tostring(reason or "UNJOURNALED")
    Counter("eventFactDiscards", 1)
    return true
end

-- Unified creation entry for Runtime. The draft is not authoritative until
-- EventStore:AppendSessionEvent imports it. Classification fields are added by
-- Runtime after this call and remain owned by EventClassifications.
function F:CreateLegacyDraft(meta, eventId, timestamp, eventType, category,
    sourceName, targetName, abilityId, abilityName, amount, parseStatus, environmental,
    inferredLastHit, deathNoticeAt, lastHitMatchReason, linkedDamageEventId)
    local event = setmetatable({}, type(meta) == "table" and meta or nil)
    -- A parser draft is not yet owned by EventFacts. Writing through the public
    -- metatable would perform eventId/session/known checks for every field even
    -- though ownership cannot exist yet. Populate the registered compact mirror
    -- directly and import it once when EventStore publishes the row. Keep this
    -- fully positional: a nested helper closure would allocate once per event.
    self:WriteLegacyMirror(event, "repdpsPacked", true)
    self:WriteLegacyMirror(event, "repdpsCompact", true)
    self:WriteLegacyMirror(event, "eventId", eventId)
    self:WriteLegacyMirror(event, "timestamp", timestamp)
    self:WriteLegacyMirror(event, "eventType", eventType)
    self:WriteLegacyMirror(event, "category", category)
    self:WriteLegacyMirror(event, "sourceName", sourceName)
    self:WriteLegacyMirror(event, "targetName", targetName)
    if abilityId ~= nil then self:WriteLegacyMirror(event, "abilityId", abilityId) end
    self:WriteLegacyMirror(event, "abilityName", abilityName)
    self:WriteLegacyMirror(event, "amount", amount)
    self:WriteLegacyMirror(event, "parseStatus", parseStatus)
    if environmental ~= nil then self:WriteLegacyMirror(event, "environmental", environmental) end
    if inferredLastHit ~= nil then self:WriteLegacyMirror(event, "inferredLastHit", inferredLastHit) end
    if deathNoticeAt ~= nil then self:WriteLegacyMirror(event, "deathNoticeAt", deathNoticeAt) end
    if lastHitMatchReason ~= nil then self:WriteLegacyMirror(event, "lastHitMatchReason", lastHitMatchReason) end
    if linkedDamageEventId ~= nil then
        self:WriteLegacyMirror(event, "linkedDamageEventId", linkedDamageEventId)
    end
    return event
end

local SNAPSHOT_VALUES = setmetatable({}, { __mode = "k" })
local FACT_INDEX = {}
for index, field in ipairs(FACT_FIELDS) do FACT_INDEX[field] = index end
local FACT_META = {
    __index = function(target, key)
        local index = FACT_INDEX[key]
        local payload = SNAPSHOT_VALUES[target]
        if index ~= nil and type(payload) == "table" then return payload[index] end
        return nil
    end,
    __newindex = function(_, key)
        error("ReplicatedDps.CombatEventFact is immutable: " .. tostring(key), 2)
    end,
    __metatable = "ReplicatedDps.CombatEventFact",
}

function F:Snapshot(event)
    local eventId = EventIdToken(self, event)
    if eventId == nil then return nil end
    if self.committed.known[eventId] ~= true and not self:Ensure(event, "SNAPSHOT_IMPORT") then return nil end
    local payload = {}
    for index, field in ipairs(FACT_FIELDS) do
        payload[index] = ReadGenerationField(self.committed, eventId, field)
    end
    local result = {}
    SNAPSHOT_VALUES[result] = payload
    return setmetatable(result, FACT_META)
end

-- Explicit corruption-repair path. Authority is replaced first; compatibility
-- mirrors are updated only after the new revision is committed.
function F:RepairForClassification(event, timestamp, amount, category, context)
    local eventId = EventIdToken(self, event)
    if eventId == nil then return false end
    if self.committed.known[eventId] ~= true and not self:Ensure(event, "REPAIR_IMPORT") then return false end
    local changed = false
    local expectedTimestamp = ReadGenerationField(self.committed, eventId, "timestamp")
    local expectedAmount = ReadGenerationField(self.committed, eventId, "amount")
    local expectedCategory = ReadGenerationField(self.committed, eventId, "category")
    if not SameValue("timestamp", expectedTimestamp, timestamp) then
        WriteGenerationField(self.committed, eventId, "timestamp", timestamp)
        changed = true
    end
    if not SameValue("amount", expectedAmount, amount) then
        WriteGenerationField(self.committed, eventId, "amount", amount)
        changed = true
    end
    if not SameValue("category", expectedCategory, category) then
        WriteGenerationField(self.committed, eventId, "category", category)
        changed = true
    end
    if not changed then return false end
    MarkKnown(self.committed, eventId, context or "CLASSIFICATION_SANITIZE", true)
    self:WriteLegacyMirror(event, "timestamp", timestamp)
    self:WriteLegacyMirror(event, "amount", amount)
    self:WriteLegacyMirror(event, "category", category)
    self.lastRepair = {
        eventId = eventId,
        context = tostring(context or "CLASSIFICATION_SANITIZE"),
    }
    Counter("eventFactRepairs", 1)
    NotifyEventBlockFactRepair(self, eventId, context or "CLASSIFICATION_SANITIZE")
    return true
end

function F:BeginBackfill(reason, batchSize)
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

function F:StepBackfill(batchSize)
    local job = self.backfillJob
    if type(job) ~= "table" then return true end
    if job.journal ~= Store.sessionEvents or job.generation ~= (tonumber(Store.identityGeneration) or 0) then
        self:OnEventStoreReset("journal_changed")
        job = self.backfillJob
    end
    local events = Store.sessionEvents or {}
    local budget = math.max(1, math.floor(tonumber(batchSize) or job.batchSize or 480))
    local processed = 0
    while job.cursor <= #events and processed < budget do
        local event = events[job.cursor]
        if type(event) == "table" then
            local eventId = EventIdToken(self, event)
            if eventId ~= nil and self.committed.known[eventId] ~= true then
                if self:ImportLegacy(event, job.reason, self.committed) then
                    job.imported = job.imported + 1
                end
            end
        end
        job.cursor = job.cursor + 1
        processed = processed + 1
    end
    if job.cursor > #events then
        self.backfillJob = nil
        Counter("eventFactBackfills", 1)
        return true
    end
    return false
end

function F:OnEventStoreReset(reason)
    self.generationCounter = math.max(0, math.floor(tonumber(self.generationCounter) or 0)) + 1
    self.committed = NewGeneration(self.generationCounter, reason or "JOURNAL_RESET")
    self.lastResetReason = tostring(reason or "JOURNAL_RESET")
    self:BeginBackfill(reason or "JOURNAL_RESET")
    Counter("eventFactResets", 1)
    return true
end

function F:CompareMirror(event, context)
    local eventId = EventIdToken(self, event)
    if eventId == nil then return false end
    if self.committed.known[eventId] ~= true and not self:Ensure(event, "AUDIT_IMPORT") then return false end
    for _, field in ipairs(FACT_FIELDS) do
        local expected = ReadGenerationField(self.committed, eventId, field)
        local actual = LegacyFactValue(self, event, field)
        if not SameValue(field, expected, actual) then
            self.mismatchCount = (tonumber(self.mismatchCount) or 0) + 1
            self.lastMismatch = {
                eventId = eventId,
                field = field,
                expected = expected,
                actual = actual,
                context = tostring(context or "AUDIT"),
            }
            Counter("eventFactMirrorMismatches", 1)
            return false
        end
    end
    return true
end

function F:BeginConsistencyAudit(batchSize)
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

function F:StepConsistencyAudit(batchSize)
    local job = self.auditJob
    if type(job) ~= "table" then return true end
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
        Counter("eventFactAudits", 1)
        return true
    end
    return false
end

function F:GetStatusLine()
    local committed = self.committed or {}
    local text = "事实旁路 v" .. tostring(self.schemaVersion)
        .. " / 事件 " .. tostring(committed.count or 0)
        .. " / 修复 " .. tostring(committed.repairs or 0)
    if self.backfillJob ~= nil then text = text .. " / 回填 " .. tostring(self.backfillJob.cursor or 1) end
    if (tonumber(self.mismatchCount) or 0) > 0 then
        text = text .. " / 镜像差异 " .. tostring(self.mismatchCount)
    end
    return text
end

if type(Store.SetFactAuthority) == "function" then
    Store:SetFactAuthority(F)
else
    Store.factAuthority = F
end

Boot:CompletePhase("EVENT_FACTS_READY")

ReplicatedSuiteModuleSandbox:Enter('dps', {'ReplicatedDps', 'ReplicatedDpsConfig'})
------------------------------------------------------------------------
-- Replicated DPS - diagnostic EventBlock shadow and event-position index
-- Author: Replicated
--
-- Authority boundary
--   * D.EventStore.sessionEvents remains the production journal/order Authority.
--   * D.EventFacts remains the immutable Fact Authority.
--   * D.EventBlocks is a diagnostic-only columnar shadow. It never changes a
--     CombatEvent, Classification, Entity, Stats, replay job or persistence.
--   * Source ActorRef / TargetRef identities are derived only from immutable
--     creation observations. Current aliases, relations and UI state are not read.
--
-- Storage boundary
--   * Every block contains at most 512 events and owns one dense array per column.
--   * No per-event EventBlock table or per-position pair table is allocated.
--   * Actor/TargetRef positions use dense linked-list columns:
--       headByRefId -> position -> nextByPosition
--   * Strings, ActorRefs, TargetRefs and AbilityRefs are dictionary encoded.
--
-- Performance boundary
--   * The shadow is active only while diagnosticsEnabled is true.
--   * Normal combat performs one configuration guard and no EventBlock allocation.
--   * Existing journals are backfilled and audited only through bounded steps.
--   * No full journal scan runs in Tick or a combat callback.
------------------------------------------------------------------------

if ReplicatedDps == nil or ReplicatedDps.Boot == nil then return end

local D = ReplicatedDps
local Boot = D.Boot
if Boot.phase == "FAILED" then return end
if type(D.EventStore) ~= "table" or type(D.EventStore.SetEventBlockObserver) ~= "function" then
    Boot:Fail("event_blocks:event_store", "D.EventStore block observer boundary is unavailable")
    return
end
if type(D.EventFacts) ~= "table" or type(D.EventFacts.GetCommittedField) ~= "function" then
    Boot:Fail("event_blocks:event_facts", "D.EventFacts direct read boundary is unavailable")
    return
end
if type(D.Util) ~= "table" then
    Boot:Fail("event_blocks:util", "D.Util is unavailable")
    return
end

Boot:SetPhase("EVENT_BLOCKS_LOADING")

local U = D.Util
local Store = D.EventStore
local Facts = D.EventFacts

D.EventBlocks = D.EventBlocks or {}
local B = D.EventBlocks

B.schemaVersion = 1
B.layoutVersion = 1
B.blockCapacity = 512

local FACT_FIELDS = {
    "eventId", "timestamp", "eventType", "category",
    "sourceName", "targetName", "abilityId", "abilityName", "amount",
    "parseStatus", "environmental", "inferredLastHit",
    "deathNoticeAt", "lastHitMatchReason", "linkedDamageEventId",
    "initialSourceKey", "initialTargetKey",
    "initialSourceBoundId", "initialTargetBoundId",
}

local FIELD_SET = {}
for _, field in ipairs(FACT_FIELDS) do FIELD_SET[field] = true end

local function Counter(name, amount)
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

local function ScalarText(value)
    if value == nil then return nil end
    return tostring(value)
end

local function NonEmptyText(value)
    if value == nil then return nil end
    local text = tostring(value)
    text = string.gsub(text, "^%s+", "")
    text = string.gsub(text, "%s+$", "")
    if text == "" then return nil end
    return text
end

local function NormalizeToken(value)
    local text = NonEmptyText(value)
    if text == nil then return "unknown" end
    text = string.lower(text)
    text = string.gsub(text, "%s+", " ")
    return text
end

local function SameScalar(left, right)
    if type(left) == "number" or type(right) == "number" then
        local a = tonumber(left)
        local b = tonumber(right)
        if a ~= nil and b ~= nil then return math.abs(a - b) <= 0.000001 end
    end
    return left == right
end

local function NewDictionary()
    return { idByValue = {}, valueById = {}, count = 0 }
end

local function Intern(dictionary, value)
    if value == nil then return 0 end
    local text = tostring(value)
    local existing = dictionary.idByValue[text]
    if existing ~= nil then return existing end
    local id = dictionary.count + 1
    dictionary.count = id
    dictionary.idByValue[text] = id
    dictionary.valueById[id] = text
    return id
end

local function Lookup(dictionary, id)
    id = math.floor(tonumber(id) or 0)
    if id <= 0 then return nil end
    return dictionary.valueById[id]
end

local function NewRefDictionary()
    return {
        idByToken = {},
        tokenStringIdById = {},
        kindStringIdById = {},
        stableIdStringIdById = {},
        canonicalNameStringIdById = {},
        defaultInitialKeyStringIdById = {},
        defaultInitialBoundIdStringIdById = {},
        count = 0,
    }
end

local function RefIdentity(boundId, initialKey, name)
    local stableId = NonEmptyText(boundId)
    local key = NonEmptyText(initialKey)
    if stableId == nil and key ~= nil then
        stableId = string.match(key, "^id:(.+)$")
    end
    if stableId ~= nil then
        return "id:" .. NormalizeToken(stableId), "ACTOR", stableId
    end
    if key ~= nil then
        return "key:" .. NormalizeToken(key), "ACTOR_KEY", nil
    end
    return "name:" .. NormalizeToken(name), "NAME_HISTORY", nil
end

local function InternRef(generation, dictionary, boundId, initialKey, name)
    local token, kind, stableId = RefIdentity(boundId, initialKey, name)
    local existing = dictionary.idByToken[token]
    if existing ~= nil then return existing end
    local id = dictionary.count + 1
    dictionary.count = id
    dictionary.idByToken[token] = id
    dictionary.tokenStringIdById[id] = Intern(generation.strings, token)
    dictionary.kindStringIdById[id] = Intern(generation.strings, kind)
    dictionary.stableIdStringIdById[id] = Intern(generation.strings, stableId)
    dictionary.canonicalNameStringIdById[id] = Intern(generation.strings, NonEmptyText(name) or "未知")
    dictionary.defaultInitialKeyStringIdById[id] = Intern(generation.strings, initialKey)
    dictionary.defaultInitialBoundIdStringIdById[id] = Intern(generation.strings, boundId)
    return id
end

local function AbilityIdentity(abilityId, abilityName)
    local id = NonEmptyText(abilityId)
    if id ~= nil then return "id:" .. NormalizeToken(id) end
    return "name:" .. NormalizeToken(abilityName)
end

local function InternAbility(generation, abilityId, abilityName)
    local token = AbilityIdentity(abilityId, abilityName)
    local existing = generation.abilityRefs.idByToken[token]
    if existing ~= nil then return existing end
    local id = generation.abilityRefs.count + 1
    generation.abilityRefs.count = id
    generation.abilityRefs.idByToken[token] = id
    generation.abilityRefs.tokenStringIdById[id] = Intern(generation.strings, token)
    generation.abilityRefs.abilityIdStringIdById[id] = Intern(generation.strings, abilityId)
    generation.abilityRefs.abilityNameStringIdById[id] = Intern(generation.strings,
        NonEmptyText(abilityName) or "未知")
    return id
end

local function NewBlock(id, baseTimestamp)
    return {
        id = id,
        baseTimestamp = baseTimestamp,
        count = 0,
        eventIds = {},
        timestampDeltas = {},
        eventTypeStringIds = {},
        categoryStringIds = {},
        sourceActorRefIds = {},
        targetRefIds = {},
        sourceNameOverrideStringIds = {},
        targetNameOverrideStringIds = {},
        abilityRefIds = {},
        abilityIdOverrideStringIds = {},
        abilityNameOverrideStringIds = {},
        amounts = {},
        parseStatusStringIds = {},
        flags = {},
        deathNoticeDeltas = {},
        lastHitReasonStringIds = {},
        linkedDamageEventIdStringIds = {},
        initialSourceKeyOverrideStringIds = {},
        initialTargetKeyOverrideStringIds = {},
        initialSourceBoundIdOverrideStringIds = {},
        initialTargetBoundIdOverrideStringIds = {},
    }
end

local function NewGeneration(id, reason)
    return {
        id = math.max(0, math.floor(tonumber(id) or 0)),
        reason = tostring(reason or "UNKNOWN"),
        blockCapacity = B.blockCapacity,
        blocks = {},
        blockCount = 0,
        eventCount = 0,
        eventPositionById = {},
        sourceNextByPosition = {},
        targetNextByPosition = {},
        sourceHeadByRefId = {},
        sourceTailByRefId = {},
        sourcePositionCountByRefId = {},
        targetHeadByRefId = {},
        targetTailByRefId = {},
        targetPositionCountByRefId = {},
        strings = NewDictionary(),
        sourceActorRefs = NewRefDictionary(),
        targetRefs = NewRefDictionary(),
        abilityRefs = {
            idByToken = {},
            tokenStringIdById = {},
            abilityIdStringIdById = {},
            abilityNameStringIdById = {},
            count = 0,
        },
        startedAt = type(U.NowMs) == "function" and U.NowMs() or 0,
    }
end

local function FreshState(reason, preserveEnabled)
    local enabled = preserveEnabled == true and B.enabled == true
    B.generationCounter = math.max(0, math.floor(tonumber(B.generationCounter) or 0)) + 1
    B.committed = NewGeneration(B.generationCounter, reason or "module_load")
    B.enabled = enabled
    B.failed = false
    B.failure = nil
    B.backfillJob = nil
    B.auditJob = nil
    B.mismatchCount = 0
    B.lastMismatch = nil
    B.lastResetReason = tostring(reason or "module_load")
end

FreshState("module_load", false)

local function FactField(event, eventId, field)
    local value, known = Facts:GetCommittedField(eventId, field)
    if known then return value end
    if type(event) == "table" and Facts:Ensure(event, "EVENT_BLOCK_IMPORT") then
        value, known = Facts:GetCommittedField(eventId, field)
        if known then return value end
    end
    return nil
end

local function BooleanFlags(environmental, inferredLastHit)
    local flags = 0
    if environmental == true then flags = flags + 1
    elseif environmental == false then flags = flags + 2 end
    if inferredLastHit == true then flags = flags + 4
    elseif inferredLastHit == false then flags = flags + 8 end
    return flags
end

local function DecodeBoolean(flags, trueBit, falseBit)
    flags = math.floor(tonumber(flags) or 0)
    if math.floor(flags / trueBit) % 2 == 1 then return true end
    if math.floor(flags / falseBit) % 2 == 1 then return false end
    return nil
end

local function LinkSourcePosition(generation, refId, position)
    local tail = generation.sourceTailByRefId[refId]
    if tail == nil then
        generation.sourceHeadByRefId[refId] = position
    else
        generation.sourceNextByPosition[tail] = position
    end
    generation.sourceTailByRefId[refId] = position
    generation.sourcePositionCountByRefId[refId] =
        (tonumber(generation.sourcePositionCountByRefId[refId]) or 0) + 1
end

local function LinkTargetPosition(generation, refId, position)
    local tail = generation.targetTailByRefId[refId]
    if tail == nil then
        generation.targetHeadByRefId[refId] = position
    else
        generation.targetNextByPosition[tail] = position
    end
    generation.targetTailByRefId[refId] = position
    generation.targetPositionCountByRefId[refId] =
        (tonumber(generation.targetPositionCountByRefId[refId]) or 0) + 1
end

local function Locate(generation, eventId)
    eventId = math.floor(tonumber(eventId) or 0)
    local position = eventId > 0 and generation.eventPositionById[eventId] or nil
    if position == nil then return nil, nil, nil end
    local capacity = generation.blockCapacity
    local blockId = math.floor((position - 1) / capacity) + 1
    local offset = ((position - 1) % capacity) + 1
    return generation.blocks[blockId], offset, position
end

local function EncodeStringOverride(generation, value, defaultStringId)
    local defaultValue = Lookup(generation.strings, defaultStringId)
    local text = ScalarText(value)
    if text == defaultValue then return nil end
    -- 0 is an explicit nil override; nil means use the dictionary default.
    return Intern(generation.strings, text)
end

local function DecodeStringOverride(generation, overrides, offset, defaultStringId)
    local override = overrides[offset]
    if override ~= nil then return Lookup(generation.strings, override) end
    return Lookup(generation.strings, defaultStringId)
end

local function AppendFact(self, event, context)
    local generation = self.committed
    local rawEventId = type(event) == "table" and event.eventId or nil
    local eventId = math.floor(FiniteNumber(rawEventId, 0) or 0)
    if eventId <= 0 then error("EventBlocks append requires positive eventId", 2) end
    if generation.eventPositionById[eventId] ~= nil then
        return self:CompareEvent(event, context or "DUPLICATE_APPEND")
    end
    if not Facts:Ensure(event, "EVENT_BLOCK_APPEND") then
        error("EventBlocks cannot read committed Fact", 2)
    end

    local timestamp = FiniteNumber(FactField(event, eventId, "timestamp"), 0) or 0
    local eventType = ScalarText(FactField(event, eventId, "eventType")) or ""
    local category = ScalarText(FactField(event, eventId, "category")) or "OTHER"
    local sourceName = ScalarText(FactField(event, eventId, "sourceName")) or "未知"
    local targetName = ScalarText(FactField(event, eventId, "targetName")) or "未知"
    local abilityId = ScalarText(FactField(event, eventId, "abilityId"))
    local abilityName = ScalarText(FactField(event, eventId, "abilityName")) or "未知"
    local amount = FiniteNumber(FactField(event, eventId, "amount"), 0) or 0
    local parseStatus = ScalarText(FactField(event, eventId, "parseStatus")) or "UNPARSED"
    local environmental = FactField(event, eventId, "environmental")
    local inferredLastHit = FactField(event, eventId, "inferredLastHit")
    local deathNoticeAt = FiniteNumber(FactField(event, eventId, "deathNoticeAt"), nil)
    local lastHitMatchReason = ScalarText(FactField(event, eventId, "lastHitMatchReason"))
    local linkedDamageEventId = FactField(event, eventId, "linkedDamageEventId")
    local initialSourceKey = ScalarText(FactField(event, eventId, "initialSourceKey"))
    local initialTargetKey = ScalarText(FactField(event, eventId, "initialTargetKey"))
    local initialSourceBoundId = ScalarText(FactField(event, eventId, "initialSourceBoundId"))
    local initialTargetBoundId = ScalarText(FactField(event, eventId, "initialTargetBoundId"))

    local position = generation.eventCount + 1
    local capacity = generation.blockCapacity
    local blockId = math.floor((position - 1) / capacity) + 1
    local offset = ((position - 1) % capacity) + 1
    local block = generation.blocks[blockId]
    if block == nil then
        block = NewBlock(blockId, timestamp)
        generation.blocks[blockId] = block
        generation.blockCount = blockId
    end

    local sourceRefId = InternRef(generation, generation.sourceActorRefs,
        initialSourceBoundId, initialSourceKey, sourceName)
    local targetRefId = InternRef(generation, generation.targetRefs,
        initialTargetBoundId, initialTargetKey, targetName)
    local abilityRefId = InternAbility(generation, abilityId, abilityName)

    block.count = offset
    block.eventIds[offset] = eventId
    block.timestampDeltas[offset] = timestamp - block.baseTimestamp
    block.eventTypeStringIds[offset] = Intern(generation.strings, eventType)
    block.categoryStringIds[offset] = Intern(generation.strings, category)
    block.sourceActorRefIds[offset] = sourceRefId
    block.targetRefIds[offset] = targetRefId
    block.sourceNameOverrideStringIds[offset] = EncodeStringOverride(generation, sourceName,
        generation.sourceActorRefs.canonicalNameStringIdById[sourceRefId])
    block.targetNameOverrideStringIds[offset] = EncodeStringOverride(generation, targetName,
        generation.targetRefs.canonicalNameStringIdById[targetRefId])
    block.abilityRefIds[offset] = abilityRefId
    block.abilityIdOverrideStringIds[offset] = EncodeStringOverride(generation, abilityId,
        generation.abilityRefs.abilityIdStringIdById[abilityRefId])
    block.abilityNameOverrideStringIds[offset] = EncodeStringOverride(generation, abilityName,
        generation.abilityRefs.abilityNameStringIdById[abilityRefId])
    block.amounts[offset] = amount
    block.parseStatusStringIds[offset] = Intern(generation.strings, parseStatus)
    block.flags[offset] = BooleanFlags(environmental, inferredLastHit)
    if deathNoticeAt ~= nil then block.deathNoticeDeltas[offset] = deathNoticeAt - timestamp end
    block.lastHitReasonStringIds[offset] = Intern(generation.strings, lastHitMatchReason)
    block.linkedDamageEventIdStringIds[offset] = Intern(generation.strings, linkedDamageEventId)
    block.initialSourceKeyOverrideStringIds[offset] = EncodeStringOverride(generation, initialSourceKey,
        generation.sourceActorRefs.defaultInitialKeyStringIdById[sourceRefId])
    block.initialTargetKeyOverrideStringIds[offset] = EncodeStringOverride(generation, initialTargetKey,
        generation.targetRefs.defaultInitialKeyStringIdById[targetRefId])
    block.initialSourceBoundIdOverrideStringIds[offset] = EncodeStringOverride(generation, initialSourceBoundId,
        generation.sourceActorRefs.defaultInitialBoundIdStringIdById[sourceRefId])
    block.initialTargetBoundIdOverrideStringIds[offset] = EncodeStringOverride(generation, initialTargetBoundId,
        generation.targetRefs.defaultInitialBoundIdStringIdById[targetRefId])

    generation.eventCount = position
    generation.eventPositionById[eventId] = position
    LinkSourcePosition(generation, sourceRefId, position)
    LinkTargetPosition(generation, targetRefId, position)
    Counter("eventBlockEvents", 1)
    return true
end

function B:DisableAfterFailure(err)
    self.failed = true
    self.enabled = false
    self.failure = tostring(err or "unknown EventBlock failure")
    self.backfillJob = nil
    self.auditJob = nil
    Counter("eventBlockFailures", 1)
    if D.Diagnostics ~= nil and type(D.Diagnostics.AddWarning) == "function" then
        D.Diagnostics:AddWarning("event_blocks", "EventBlock 影子已停用：" .. self.failure)
    end
end

function B:OnDiagnosticsChanged(enabled)
    FreshState(enabled == true and "diagnostics_enabled" or "diagnostics_disabled", false)
    self.enabled = enabled == true
    if self.enabled then self:BeginBackfill("diagnostics_enabled") end
end

function B:BeginBackfill(reason, batchSize)
    if self.enabled ~= true or self.failed == true then return false end
    self.generationCounter = math.max(0, math.floor(tonumber(self.generationCounter) or 0)) + 1
    self.committed = NewGeneration(self.generationCounter, reason or "BACKFILL")
    self.backfillJob = {
        reason = tostring(reason or "BACKFILL"),
        cursor = 1,
        batchSize = math.max(1, math.floor(tonumber(batchSize) or 320)),
        journal = Store.sessionEvents,
        generation = tonumber(Store.identityGeneration) or 0,
    }
    return true
end

function B:StepBackfill(batchSize)
    local job = self.backfillJob
    if type(job) ~= "table" then return true end
    if self.enabled ~= true or self.failed == true then
        self.backfillJob = nil
        return true
    end
    if job.journal ~= Store.sessionEvents
        or job.generation ~= (tonumber(Store.identityGeneration) or 0) then
        self:BeginBackfill("journal_changed", job.batchSize)
        job = self.backfillJob
    end
    local events = Store.sessionEvents or {}
    local budget = math.max(1, math.floor(tonumber(batchSize) or job.batchSize or 320))
    local processed = 0
    while job.cursor <= #events and processed < budget do
        local event = events[job.cursor]
        if type(event) == "table" then AppendFact(self, event, "BACKFILL") end
        job.cursor = job.cursor + 1
        processed = processed + 1
    end
    if job.cursor > #events then
        self.backfillJob = nil
        Counter("eventBlockBackfills", 1)
        return true
    end
    return false
end

function B:OnLegacyEventAppended(event, sessionIndex)
    if self.enabled ~= true or self.failed == true then return false end
    if self.backfillJob ~= nil then
        -- The bounded backfill follows the live journal length and will reach
        -- this append in order. Appending it now would reorder the block stream.
        return true
    end
    return AppendFact(self, event, "APPEND")
end

function B:OnEventStoreReset(reason)
    local enabled = self.enabled == true
    FreshState(reason or "JOURNAL_RESET", false)
    self.enabled = enabled
    if enabled then self:BeginBackfill(reason or "JOURNAL_RESET") end
    Counter("eventBlockResets", 1)
    return true
end

function B:OnFactAuthorityRepaired(eventId, context)
    if self.enabled ~= true or self.failed == true then return false end
    self.lastFactRepair = {
        eventId = math.floor(tonumber(eventId) or 0),
        context = tostring(context or "FACT_REPAIR"),
    }
    -- Blocks are immutable after append. A corruption repair therefore starts
    -- a fresh bounded generation rather than mutating an existing block row.
    self:BeginBackfill("fact_authority_repaired")
    Counter("eventBlockFactRepairRebuilds", 1)
    return true
end

function B:GetEventPosition(eventId)
    eventId = math.floor(tonumber(eventId) or 0)
    if eventId <= 0 then return nil end
    local position = self.committed.eventPositionById[eventId]
    if position == nil then return nil end
    local blockId = math.floor((position - 1) / self.committed.blockCapacity) + 1
    local offset = ((position - 1) % self.committed.blockCapacity) + 1
    return blockId, offset, position
end

function B:GetEventIdAt(blockId, offset)
    blockId = math.floor(tonumber(blockId) or 0)
    offset = math.floor(tonumber(offset) or 0)
    local block = blockId > 0 and self.committed.blocks[blockId] or nil
    if type(block) ~= "table" or offset < 1 or offset > (tonumber(block.count) or 0) then return nil end
    return block.eventIds[offset]
end

function B:GetSourceActorRefId(eventId)
    local block, offset = Locate(self.committed, eventId)
    return type(block) == "table" and block.sourceActorRefIds[offset] or nil
end

function B:FindSourceActorRefId(boundId, initialKey, name)
    local token = RefIdentity(boundId, initialKey, name)
    return self.committed.sourceActorRefs.idByToken[token]
end

function B:FindSourceActorRefIdByToken(token)
    token = NonEmptyText(token)
    return token ~= nil and self.committed.sourceActorRefs.idByToken[token] or nil
end

function B:GetTargetRefId(eventId)
    local block, offset = Locate(self.committed, eventId)
    return type(block) == "table" and block.targetRefIds[offset] or nil
end

function B:FindTargetRefId(boundId, initialKey, name)
    local token = RefIdentity(boundId, initialKey, name)
    return self.committed.targetRefs.idByToken[token]
end

function B:FindTargetRefIdByToken(token)
    token = NonEmptyText(token)
    return token ~= nil and self.committed.targetRefs.idByToken[token] or nil
end

local function RefSnapshot(generation, dictionary, refId)
    refId = math.floor(tonumber(refId) or 0)
    if refId <= 0 or refId > dictionary.count then return nil end
    return {
        refId = refId,
        token = Lookup(generation.strings, dictionary.tokenStringIdById[refId]),
        kind = Lookup(generation.strings, dictionary.kindStringIdById[refId]),
        stableId = Lookup(generation.strings, dictionary.stableIdStringIdById[refId]),
        canonicalName = Lookup(generation.strings, dictionary.canonicalNameStringIdById[refId]),
    }
end

function B:GetSourceActorRef(refId)
    return RefSnapshot(self.committed, self.committed.sourceActorRefs, refId)
end

function B:GetTargetRef(refId)
    return RefSnapshot(self.committed, self.committed.targetRefs, refId)
end

function B:GetSourcePositionCount(refId)
    refId = math.floor(tonumber(refId) or 0)
    return math.max(0, math.floor(tonumber(self.committed.sourcePositionCountByRefId[refId]) or 0))
end

function B:GetTargetPositionCount(refId)
    refId = math.floor(tonumber(refId) or 0)
    return math.max(0, math.floor(tonumber(self.committed.targetPositionCountByRefId[refId]) or 0))
end

function B:GetFirstSourcePosition(refId)
    refId = math.floor(tonumber(refId) or 0)
    return self.committed.sourceHeadByRefId[refId]
end

function B:GetNextSourcePosition(position)
    position = math.floor(tonumber(position) or 0)
    return self.committed.sourceNextByPosition[position]
end

function B:GetFirstTargetPosition(refId)
    refId = math.floor(tonumber(refId) or 0)
    return self.committed.targetHeadByRefId[refId]
end

function B:GetNextTargetPosition(position)
    position = math.floor(tonumber(position) or 0)
    return self.committed.targetNextByPosition[position]
end

function B:GetEventIdByPosition(position)
    position = math.floor(tonumber(position) or 0)
    if position <= 0 or position > (tonumber(self.committed.eventCount) or 0) then return nil end
    local capacity = self.committed.blockCapacity
    local blockId = math.floor((position - 1) / capacity) + 1
    local offset = ((position - 1) % capacity) + 1
    local block = self.committed.blocks[blockId]
    return type(block) == "table" and block.eventIds[offset] or nil
end

function B:ReadFact(eventId, field)
    if FIELD_SET[field] ~= true then return nil, false end
    local block, offset = Locate(self.committed, eventId)
    if type(block) ~= "table" then return nil, false end
    local strings = self.committed.strings
    if field == "eventId" then return block.eventIds[offset], true end
    if field == "timestamp" then return block.baseTimestamp + (block.timestampDeltas[offset] or 0), true end
    if field == "eventType" then return Lookup(strings, block.eventTypeStringIds[offset]) or "", true end
    if field == "category" then return Lookup(strings, block.categoryStringIds[offset]) or "OTHER", true end
    local sourceRefId = block.sourceActorRefIds[offset]
    local targetRefId = block.targetRefIds[offset]
    local abilityRefId = block.abilityRefIds[offset]
    if field == "sourceName" then
        return DecodeStringOverride(self.committed, block.sourceNameOverrideStringIds, offset,
            self.committed.sourceActorRefs.canonicalNameStringIdById[sourceRefId]) or "未知", true
    end
    if field == "targetName" then
        return DecodeStringOverride(self.committed, block.targetNameOverrideStringIds, offset,
            self.committed.targetRefs.canonicalNameStringIdById[targetRefId]) or "未知", true
    end
    if field == "abilityId" then
        return DecodeStringOverride(self.committed, block.abilityIdOverrideStringIds, offset,
            self.committed.abilityRefs.abilityIdStringIdById[abilityRefId]), true
    end
    if field == "abilityName" then
        return DecodeStringOverride(self.committed, block.abilityNameOverrideStringIds, offset,
            self.committed.abilityRefs.abilityNameStringIdById[abilityRefId]) or "未知", true
    end
    if field == "amount" then return block.amounts[offset] or 0, true end
    if field == "parseStatus" then return Lookup(strings, block.parseStatusStringIds[offset]) or "UNPARSED", true end
    if field == "environmental" then return DecodeBoolean(block.flags[offset], 1, 2), true end
    if field == "inferredLastHit" then return DecodeBoolean(block.flags[offset], 4, 8), true end
    if field == "deathNoticeAt" then
        local delta = block.deathNoticeDeltas[offset]
        return delta ~= nil and (block.baseTimestamp + (block.timestampDeltas[offset] or 0) + delta) or nil, true
    end
    if field == "lastHitMatchReason" then return Lookup(strings, block.lastHitReasonStringIds[offset]), true end
    if field == "linkedDamageEventId" then return Lookup(strings, block.linkedDamageEventIdStringIds[offset]), true end
    if field == "initialSourceKey" then
        return DecodeStringOverride(self.committed, block.initialSourceKeyOverrideStringIds, offset,
            self.committed.sourceActorRefs.defaultInitialKeyStringIdById[sourceRefId]), true
    end
    if field == "initialTargetKey" then
        return DecodeStringOverride(self.committed, block.initialTargetKeyOverrideStringIds, offset,
            self.committed.targetRefs.defaultInitialKeyStringIdById[targetRefId]), true
    end
    if field == "initialSourceBoundId" then
        return DecodeStringOverride(self.committed, block.initialSourceBoundIdOverrideStringIds, offset,
            self.committed.sourceActorRefs.defaultInitialBoundIdStringIdById[sourceRefId]), true
    end
    if field == "initialTargetBoundId" then
        return DecodeStringOverride(self.committed, block.initialTargetBoundIdOverrideStringIds, offset,
            self.committed.targetRefs.defaultInitialBoundIdStringIdById[targetRefId]), true
    end
    return nil, false
end

local function RecordMismatch(self, eventId, field, expected, actual, context)
    self.mismatchCount = (tonumber(self.mismatchCount) or 0) + 1
    self.lastMismatch = {
        eventId = eventId,
        field = tostring(field or "UNKNOWN"),
        expected = expected,
        actual = actual,
        context = tostring(context or "AUDIT"),
    }
    Counter("eventBlockMismatches", 1)
end

function B:CompareEvent(event, context)
    if type(event) ~= "table" then return false end
    local eventId = math.floor(FiniteNumber(event.eventId, 0) or 0)
    if eventId <= 0 then return false end
    if self.committed.eventPositionById[eventId] == nil then return false end
    for _, field in ipairs(FACT_FIELDS) do
        local expected, known = Facts:GetCommittedField(eventId, field)
        local actual, blockKnown = self:ReadFact(eventId, field)
        if not known or not blockKnown or not SameScalar(expected, actual) then
            RecordMismatch(self, eventId, field, expected, actual, context)
            return false
        end
    end
    return true
end

function B:BeginConsistencyAudit(batchSize)
    if self.enabled ~= true or self.failed == true or self.backfillJob ~= nil then return false end
    self.auditJob = {
        cursor = 1,
        batchSize = math.max(1, math.floor(tonumber(batchSize) or 320)),
        journal = Store.sessionEvents,
        generation = tonumber(Store.identityGeneration) or 0,
        checked = 0,
        mismatches = 0,
    }
    return true
end

function B:StepConsistencyAudit(batchSize)
    local job = self.auditJob
    if type(job) ~= "table" then return true end
    if job.journal ~= Store.sessionEvents
        or job.generation ~= (tonumber(Store.identityGeneration) or 0) then
        self.auditJob = nil
        return true
    end
    local events = Store.sessionEvents or {}
    local budget = math.max(1, math.floor(tonumber(batchSize) or job.batchSize or 320))
    local processed = 0
    while job.cursor <= #events and processed < budget do
        local event = events[job.cursor]
        if type(event) == "table" then
            job.checked = job.checked + 1
            if not self:CompareEvent(event, "CONSISTENCY_AUDIT") then
                job.mismatches = job.mismatches + 1
            end
        end
        job.cursor = job.cursor + 1
        processed = processed + 1
    end
    if job.cursor > #events then
        self.auditJob = nil
        Counter("eventBlockAudits", 1)
        return true
    end
    return false
end

function B:GetStatusLine()
    if self.enabled ~= true then
        if self.failed == true then return "EventBlock 影子：已停用（故障）" end
        return "EventBlock 影子：关闭"
    end
    local generation = self.committed or {}
    local text = "EventBlock v" .. tostring(self.schemaVersion)
        .. " / 块 " .. tostring(generation.blockCount or 0)
        .. " / 事件 " .. tostring(generation.eventCount or 0)
        .. " / ActorRef " .. tostring(generation.sourceActorRefs and generation.sourceActorRefs.count or 0)
        .. " / TargetRef " .. tostring(generation.targetRefs and generation.targetRefs.count or 0)
    if self.backfillJob ~= nil then text = text .. " / 回填 " .. tostring(self.backfillJob.cursor or 1) end
    if (tonumber(self.mismatchCount) or 0) > 0 then text = text .. " / 差异 " .. tostring(self.mismatchCount) end
    return text
end

Store:SetEventBlockObserver(B)
if type(Facts.SetEventBlockObserver) == "function" then Facts:SetEventBlockObserver(B) end

if D.State ~= nil and D.State.config ~= nil and D.State.config.diagnosticsEnabled == true then
    local ok, err = pcall(B.OnDiagnosticsChanged, B, true)
    if not ok then B:DisableAfterFailure(err) end
end

Boot:CompletePhase("EVENT_BLOCKS_READY")

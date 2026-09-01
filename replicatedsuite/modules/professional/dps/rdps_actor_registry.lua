ReplicatedSuiteModuleSandbox:Enter('dps', {'ReplicatedDps', 'ReplicatedDpsConfig'})
------------------------------------------------------------------------
-- Replicated DPS - Actor Registry read facade
-- Author: Replicated
--
-- This module is intentionally read-only with respect to entity truth. The
-- existing D.Entities table remains the sole owner of identity observations,
-- aliases, manual overrides and relation state during this preparation stage.
--
-- The registry provides:
--   * one read boundary for entity key/name/stable-ID/kind access;
--   * lazy process-local ActorId values without changing Stats/Event keys;
--   * alias-aware ActorId reconciliation when an old key is promoted;
--   * bounded, incremental dual-read consistency auditing.
--
-- ActorId values in this stage are runtime-only scaffolding. They are not
-- persisted and must not be written into combat events, statistics or rules.
------------------------------------------------------------------------

if ReplicatedDps == nil or ReplicatedDps.Boot == nil then return end

local D = ReplicatedDps
local Boot = D.Boot
if Boot.phase == "FAILED" then return end
if type(D.Entities) ~= "table" or type(D.Entities.GetByKey) ~= "function" then
    Boot:Fail("actor_registry:entities", "D.Entities is unavailable")
    return
end

Boot:SetPhase("ACTOR_REGISTRY_LOADING")

local U = D.Util
local E = D.Entities

D.ActorRegistry = D.ActorRegistry or {}
local A = D.ActorRegistry

A.schemaVersion = 1
local currentGeneration = tonumber(Boot.generation) or 0
if tonumber(A.generation) ~= currentGeneration then
    -- ActorId is explicitly process/generation-local in the preparation architecture. Never let a hot
    -- reload carry stale keys or entity references into a new module graph.
    A.nextActorId = 0
    A.keyToActorId = {}
    A.actorIdToKey = {}
    A.actorIdAliases = {}
    A.entityToActorId = setmetatable({}, { __mode = "k" })
    A.actorIdToEntity = setmetatable({}, { __mode = "v" })
    A.readCount = 0
    A.snapshotCount = 0
    A.mismatchCount = 0
    A.actorIdMergeCount = 0
    A.lastMismatch = nil
end
A.generation = currentGeneration
A.nextActorId = math.max(0, math.floor(tonumber(A.nextActorId) or 0))
A.keyToActorId = type(A.keyToActorId) == "table" and A.keyToActorId or {}
A.actorIdToKey = type(A.actorIdToKey) == "table" and A.actorIdToKey or {}
A.actorIdAliases = type(A.actorIdAliases) == "table" and A.actorIdAliases or {}
A.entityToActorId = type(A.entityToActorId) == "table" and A.entityToActorId or setmetatable({}, { __mode = "k" })
A.actorIdToEntity = type(A.actorIdToEntity) == "table" and A.actorIdToEntity or setmetatable({}, { __mode = "v" })
A.readCount = math.max(0, math.floor(tonumber(A.readCount) or 0))
A.snapshotCount = math.max(0, math.floor(tonumber(A.snapshotCount) or 0))
A.mismatchCount = math.max(0, math.floor(tonumber(A.mismatchCount) or 0))
A.actorIdMergeCount = math.max(0, math.floor(tonumber(A.actorIdMergeCount) or 0))
A.lastMismatch = type(A.lastMismatch) == "table" and A.lastMismatch or nil
A.diagnosticsFlushedGeneration = tonumber(A.diagnosticsFlushedGeneration) or 0

local function Counter(name, amount)
    local counters = D.Diagnostics and D.Diagnostics.counters or nil
    if type(counters) ~= "table" then return end
    counters[name] = (tonumber(counters[name]) or 0) + (tonumber(amount) or 1)
end

local function NormalizeName(name)
    if U ~= nil and type(U.NormalizeName) == "function" then
        return U.NormalizeName(name)
    end
    local text = tostring(name or "")
    text = string.gsub(text, "^%s+", "")
    text = string.gsub(text, "%s+$", "")
    return string.lower(text)
end

local function RecordMismatch(kind, requestedKey, expected, actual)
    A.mismatchCount = A.mismatchCount + 1
    Counter("actorRegistryMismatches", 1)
    A.lastMismatch = {
        kind = tostring(kind or "unknown"),
        requestedKey = requestedKey ~= nil and tostring(requestedKey) or nil,
        expectedKey = type(expected) == "table" and tostring(expected.key or "") or nil,
        actualKey = type(actual) == "table" and tostring(actual.key or "") or nil,
    }
    if A.mismatchCount <= 8 and D.Diagnostics ~= nil and type(D.Diagnostics.AddWarning) == "function" then
        D.Diagnostics:AddWarning(
            "actor_registry",
            tostring(A.lastMismatch.kind) .. " mismatch for " .. tostring(A.lastMismatch.requestedKey or "nil")
        )
    end
end

local function DirectLegacyEquivalent(key)
    if key == nil then return nil end
    local requested = tostring(key)
    local resolved = type(E.aliases) == "table" and E.aliases[requested] or nil
    if resolved == nil then resolved = requested end
    return type(E.byKey) == "table" and E.byKey[resolved] or nil
end

function A:ResolveActorId(actorId)
    local current = tonumber(actorId)
    if current == nil then return nil end
    current = math.floor(current)
    if current <= 0 then return nil end
    local visited = nil
    for _ = 1, 16 do
        local nextId = tonumber(self.actorIdAliases[current])
        if nextId == nil or nextId == current then return current end
        visited = visited or {}
        if visited[current] == true then return current end
        visited[current] = true
        current = math.floor(nextId)
    end
    return current
end

local function MergeActorIds(left, right)
    left = A:ResolveActorId(left)
    right = A:ResolveActorId(right)
    if left == nil then return right end
    if right == nil then return left end
    if left == right then return left end

    local winner = math.min(left, right)
    local loser = math.max(left, right)
    A.actorIdAliases[loser] = winner
    A.actorIdToKey[loser] = nil
    A.actorIdToEntity[loser] = nil
    A.actorIdMergeCount = A.actorIdMergeCount + 1
    Counter("actorRegistryActorIdMerges", 1)
    return winner
end

local function BindActorId(entity, requestedKey)
    if type(entity) ~= "table" then return nil end
    local canonicalKey = entity.key ~= nil and tostring(entity.key) or nil
    local requested = requestedKey ~= nil and tostring(requestedKey) or nil

    local actorId = A:ResolveActorId(A.entityToActorId[entity])
    if canonicalKey ~= nil then actorId = MergeActorIds(actorId, A.keyToActorId[canonicalKey]) end
    if requested ~= nil then actorId = MergeActorIds(actorId, A.keyToActorId[requested]) end

    if actorId == nil then
        A.nextActorId = A.nextActorId + 1
        actorId = A.nextActorId
    end

    if canonicalKey ~= nil then A.keyToActorId[canonicalKey] = actorId end
    if requested ~= nil then A.keyToActorId[requested] = actorId end
    A.entityToActorId[entity] = actorId
    A.actorIdToEntity[actorId] = entity
    A.actorIdToKey[actorId] = canonicalKey
    return actorId
end

function A:GetEntityByKey(key)
    if key == nil then return nil end
    local expected = E:GetByKey(key)

    -- The combat/replay path must remain read-only and allocation-free. Perform
    -- the independent dual read only while diagnostics are enabled; focused
    -- tests and the incremental audit always execute the assertion explicitly.
    local diagnosticsEnabled = D.State ~= nil and D.State.config ~= nil
        and D.State.config.diagnosticsEnabled == true
    if diagnosticsEnabled then
        self.readCount = self.readCount + 1
        Counter("actorRegistryReads", 1)
        local equivalent = DirectLegacyEquivalent(key)
        if expected ~= equivalent then RecordMismatch("key_read", key, expected, equivalent) end
    end
    return expected
end

function A:GetCanonicalKey(key)
    local entity = self:GetEntityByKey(key)
    return type(entity) == "table" and entity.key or nil
end

function A:GetActorIdByKey(key)
    local entity = self:GetEntityByKey(key)
    return BindActorId(entity, key)
end

function A:GetActorId(entityOrKey)
    if type(entityOrKey) == "table" then
        return BindActorId(entityOrKey, entityOrKey.key)
    end
    return self:GetActorIdByKey(entityOrKey)
end

function A:GetEntityByActorId(actorId)
    local resolvedId = self:ResolveActorId(actorId)
    if resolvedId == nil then return nil end
    local entity = self.actorIdToEntity[resolvedId]
    if type(entity) == "table" then
        local canonical = entity.key ~= nil and E:GetByKey(entity.key) or nil
        if canonical ~= nil then
            BindActorId(canonical, entity.key)
            return canonical
        end
    end
    local key = self.actorIdToKey[resolvedId]
    if key == nil then return nil end
    entity = self:GetEntityByKey(key)
    if entity ~= nil then BindActorId(entity, key) end
    return entity
end

function A:GetStableId(entityOrKey)
    local entity = type(entityOrKey) == "table" and entityOrKey or self:GetEntityByKey(entityOrKey)
    if type(entity) ~= "table" or entity.stringId == nil or tostring(entity.stringId) == "" then return nil end
    return tostring(entity.stringId)
end

function A:GetCanonicalName(entityOrKey)
    local entity = type(entityOrKey) == "table" and entityOrKey or self:GetEntityByKey(entityOrKey)
    return type(entity) == "table" and entity.name or nil
end

function A:GetNormalizedName(entityOrKey)
    local entity = type(entityOrKey) == "table" and entityOrKey or self:GetEntityByKey(entityOrKey)
    if type(entity) ~= "table" then return "" end
    local normalized = tostring(entity.normalizedName or "")
    if normalized ~= "" then return normalized end
    return NormalizeName(entity.name)
end

-- hardKind is the latest trusted observation. kind is the current effective
-- type after manual/rule overlays and resolution. They are deliberately
-- exposed separately so callers do not silently reinterpret one as the other.
function A:GetObservedKind(entityOrKey)
    local entity = type(entityOrKey) == "table" and entityOrKey or self:GetEntityByKey(entityOrKey)
    return type(entity) == "table" and entity.hardKind or nil
end

function A:GetEffectiveKind(entityOrKey)
    local entity = type(entityOrKey) == "table" and entityOrKey or self:GetEntityByKey(entityOrKey)
    return type(entity) == "table" and entity.kind or nil
end

function A:HasNameConflict(name)
    local normalized = NormalizeName(name)
    return normalized ~= "" and type(E.nameConflicts) == "table" and E.nameConflicts[normalized] == true
end

function A:GetCandidatesByName(name)
    if type(E.GetCandidatesByName) ~= "function" then return {} end
    local candidates = E:GetCandidatesByName(name)
    if type(candidates) ~= "table" then return {} end
    for _, entity in ipairs(candidates) do BindActorId(entity, entity and entity.key) end
    return candidates
end

-- Low-frequency UI helper. It never creates entities and never enters the
-- combat path. The byName index is preferred; a full scan is only used when a
-- conflict/legacy row prevents a unique direct mapping.
function A:FindFirstByName(name)
    local normalized = NormalizeName(name)
    if normalized == "" then return nil end
    local mappedKey = type(E.byName) == "table" and E.byName[normalized] or nil
    if mappedKey ~= nil then
        local mapped = self:GetEntityByKey(mappedKey)
        if mapped ~= nil then return mapped end
    end
    for _, entity in pairs(type(E.byKey) == "table" and E.byKey or {}) do
        if type(entity) == "table" and NormalizeName(entity.name) == normalized then
            return entity
        end
    end
    return nil
end

function A:GetEntityCount()
    if U ~= nil and type(U.TableCount) == "function" then return U.TableCount(E.byKey) end
    local count = 0
    for _ in pairs(type(E.byKey) == "table" and E.byKey or {}) do count = count + 1 end
    return count
end

function A:GetRosterCount()
    if U ~= nil and type(U.TableCount) == "function" then return U.TableCount(E.roster) end
    local count = 0
    for _ in pairs(type(E.roster) == "table" and E.roster or {}) do count = count + 1 end
    return count
end

local function IdentityQuality(entity)
    if type(entity) ~= "table" then return "MISSING" end
    local key = tostring(entity.key or "")
    if entity.flags ~= nil and entity.flags.historicalNameAggregate == true then return "HISTORICAL_NAME" end
    if string.sub(key, 1, 3) == "id:" and entity.stringId ~= nil then return "STABLE_ID" end
    if string.sub(key, 1, 10) == "ambiguous:" then return "AMBIGUOUS_NAME" end
    if string.sub(key, 1, 9) == "teamname:" then return "TEAM_NAME" end
    if string.sub(key, 1, 8) == "history:" then return "HISTORICAL_NAME" end
    if string.sub(key, 1, 5) == "name:" then return "NAME_ONLY" end
    return "UNKNOWN_KEY"
end

function A:GetIdentityQuality(entityOrKey)
    local entity = type(entityOrKey) == "table" and entityOrKey or self:GetEntityByKey(entityOrKey)
    return IdentityQuality(entity)
end

-- Snapshot allocation is reserved for UI, diagnostics and tests. Hot combat
-- code should call scalar accessors instead.
function A:GetIdentitySnapshot(entityOrKey)
    local requestedKey = type(entityOrKey) == "table" and entityOrKey.key or entityOrKey
    local entity = type(entityOrKey) == "table" and entityOrKey or self:GetEntityByKey(entityOrKey)
    if type(entity) ~= "table" then return nil end
    self.snapshotCount = self.snapshotCount + 1
    Counter("actorRegistrySnapshots", 1)
    local actorId = BindActorId(entity, requestedKey)
    return {
        actorId = actorId,
        requestedKey = requestedKey ~= nil and tostring(requestedKey) or nil,
        canonicalKey = entity.key ~= nil and tostring(entity.key) or nil,
        stableId = entity.stringId ~= nil and tostring(entity.stringId) or nil,
        canonicalName = entity.name,
        normalizedName = self:GetNormalizedName(entity),
        nameWithWorld = entity.nameWithWorld,
        observedKind = entity.hardKind,
        effectiveKind = entity.kind,
        identityQuality = IdentityQuality(entity),
        hasNameConflict = self:HasNameConflict(entity.name),
        isHistoricalName = entity.flags ~= nil and entity.flags.historicalNameAggregate == true,
    }
end

function A:AssertKeyConsistency(key)
    local expected = E:GetByKey(key)
    local equivalent = DirectLegacyEquivalent(key)
    if expected == equivalent then return true end
    RecordMismatch("assert_key", key, expected, equivalent)
    return false, "actor registry key read differs from legacy entity read"
end

function A:BeginConsistencyAudit()
    return {
        phase = "entities",
        cursor = nil,
        checked = 0,
        mismatches = 0,
        done = false,
    }
end

local function AuditKeyTableStep(job, sourceTable, budget)
    local processed = 0
    while processed < budget do
        local key = next(sourceTable, job.cursor)
        if key == nil then return true, processed end
        job.cursor = key
        local before = A.mismatchCount
        A:AssertKeyConsistency(key)
        if A.mismatchCount > before then job.mismatches = job.mismatches + 1 end
        job.checked = job.checked + 1
        processed = processed + 1
    end
    return false, processed
end

local function AuditByNameStep(job, sourceTable, budget)
    local processed = 0
    while processed < budget do
        local normalizedName, mappedKey = next(sourceTable, job.cursor)
        if normalizedName == nil then return true, processed end
        job.cursor = normalizedName
        local entity = A:GetEntityByKey(mappedKey)
        local normalizedEntityName = type(entity) == "table" and NormalizeName(entity.name) or ""
        local normalizedIndexName = tostring(normalizedName)
        local isSelfAlias = type(entity) == "table"
            and D.Identity ~= nil
            and entity.key == D.Identity.entityKey
            and (normalizedIndexName == NormalizeName(D.Identity.playerName)
                or normalizedIndexName == NormalizeName(D.Identity.playerNameWithWorld))
        local mismatch = entity == nil
            or (normalizedEntityName ~= normalizedIndexName and not isSelfAlias)
        if mismatch then
            RecordMismatch("by_name", mappedKey, E:GetByKey(mappedKey), entity)
            job.mismatches = job.mismatches + 1
        end
        job.checked = job.checked + 1
        processed = processed + 1
    end
    return false, processed
end

function A:StepConsistencyAudit(job, budget)
    if type(job) ~= "table" or job.done == true then return true end
    local remaining = math.max(1, math.floor(tonumber(budget) or 64))

    while remaining > 0 and job.done ~= true do
        if job.phase == "entities" then
            local done, processed = AuditKeyTableStep(job, type(E.byKey) == "table" and E.byKey or {}, remaining)
            remaining = remaining - processed
            if done then job.phase = "aliases" job.cursor = nil end
        elseif job.phase == "aliases" then
            local done, processed = AuditKeyTableStep(job, type(E.aliases) == "table" and E.aliases or {}, remaining)
            remaining = remaining - processed
            if done then job.phase = "by_name" job.cursor = nil end
        elseif job.phase == "by_name" then
            local done, processed = AuditByNameStep(job, type(E.byName) == "table" and E.byName or {}, remaining)
            remaining = remaining - processed
            if done then job.phase = "done" end
        else
            job.done = true
        end
    end

    if job.phase == "done" then job.done = true end
    return job.done == true
end

-- Test/diagnostic convenience only. Runtime callers should use Begin/Step so a
-- large historical registry is never scanned in one frame.
function A:AuditAllForTests(batchSize)
    local job = self:BeginConsistencyAudit()
    local budget = math.max(1, math.floor(tonumber(batchSize) or 128))
    local guard = 0
    while job.done ~= true and guard < 100000 do
        self:StepConsistencyAudit(job, budget)
        guard = guard + 1
    end
    return job
end

function A:GetStatusLine()
    return "Actor Registry：只读 v" .. tostring(self.schemaVersion)
        .. "；ActorId=" .. tostring(self.nextActorId)
        .. "；读取=" .. tostring(self.readCount)
        .. "；双读不一致=" .. tostring(self.mismatchCount)
end

function A:FlushDiagnostics(diagnostics)
    if type(diagnostics) ~= "table" or type(diagnostics.AddInfo) ~= "function" then return end
    if self.diagnosticsFlushedGeneration == Boot.generation then return end
    self.diagnosticsFlushedGeneration = Boot.generation
    diagnostics:AddInfo("actor_registry", self:GetStatusLine())
end

local counters = D.Diagnostics and D.Diagnostics.counters or nil
if type(counters) == "table" then
    counters.actorRegistryReads = tonumber(counters.actorRegistryReads) or 0
    counters.actorRegistrySnapshots = tonumber(counters.actorRegistrySnapshots) or 0
    counters.actorRegistryMismatches = tonumber(counters.actorRegistryMismatches) or 0
    counters.actorRegistryActorIdMerges = tonumber(counters.actorRegistryActorIdMerges) or 0
end

A:FlushDiagnostics(D.Diagnostics)
Boot:CompletePhase("ACTOR_REGISTRY_READY")
if D.Diagnostics ~= nil then D.Diagnostics.status = "ACTOR_REGISTRY_READY" end

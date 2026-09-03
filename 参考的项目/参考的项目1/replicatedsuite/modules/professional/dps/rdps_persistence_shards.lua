ReplicatedSuiteModuleSandbox:Enter('dps', {'ReplicatedDps', 'ReplicatedDpsConfig'})
------------------------------------------------------------------------
-- Replicated DPS - fixed 16-shard persistence shadow
-- Author: Replicated
--
-- Authority boundary
--   * D.Persistence.SaveRotatingStats remains the durable fallback Authority.
--   * This module receives an already-finalized detached Stats payload only
--     after the rotating save succeeds, then maintains the fixed shard mirror.
--   * Formal boot adoption is owned by rdps_persistence_switch.lua. This module
--     never assigns D.State.stats or changes rotating recovery slots.
--
-- Transaction boundary
--   * Exactly sixteen actor shards are used.
--   * Every shard has three fixed banks (a/b/c). Two banks may be referenced by
--     the current and previous valid generation; the third is the only legal
--     write target. This prevents a failed new generation from overwriting the
--     previous recovery generation.
--   * Dirty shards are written first. The manifest is written last. A manifest
--     is valid only when every referenced shard envelope exists and its digest
--     matches. Interrupted writes therefore leave the old manifest valid.
--
-- Performance boundary
--   * The formal shard mirror runs only after a successful rotating checkpoint
--     and only in idle maintenance frames.
--   * Stats partitioning is incremental and counts top-level actor/dictionary
--     rows against a fixed budget.
--   * At most one logical persistence-key operation is issued per Step.
--   * The combat callback never performs a shard scan, digest scan or SaveData.
------------------------------------------------------------------------

if ReplicatedDps == nil or ReplicatedDps.Boot == nil then return end

local D = ReplicatedDps
local Boot = D.Boot
if Boot.phase == "FAILED" then return end
if type(D.Persistence) ~= "table" or type(D.Persistence.SetStatsShardObserver) ~= "function" then
    Boot:Fail("persistence_shards:persistence", "Stats shard observer boundary is unavailable")
    return
end
if type(D.Util) ~= "table" or type(D.Util.DeepCopy) ~= "function"
    or type(D.Util.HashString) ~= "function" then
    Boot:Fail("persistence_shards:util", "Util boundary is unavailable")
    return
end

Boot:SetPhase("PERSISTENCE_SHARDS_LOADING")

local U = D.Util
local Persistence = D.Persistence

D.PersistenceShards = D.PersistenceShards or {}
local S = D.PersistenceShards

S.schemaVersion = 1
S.layoutVersion = 1
S.manifestSchemaVersion = 1
S.shardSchemaVersion = 1
S.shardCount = 16
S.banks = { "a", "b", "c" }
S.defaultBuildBudget = 32
S.formalLoadEnabled = true
S.failed = S.failed == true
S.failure = S.failure
S.activeJob = nil
S.lastCompleted = S.lastCompleted
S.lastRecovery = S.lastRecovery
S.storage = S.storage
S.generationObserver = type(S.generationObserver) == "table" and S.generationObserver or nil
S.maintenanceJob = nil
S.sequence = math.max(0, math.floor(tonumber(S.sequence) or 0))
local currentBootGeneration = math.max(0, math.floor(tonumber(Boot.generation) or 0))
if tonumber(S.bootGeneration) ~= currentBootGeneration then
    S.bootGeneration = currentBootGeneration
    S.activeJob = nil
    S.failed = false
    S.failure = nil
end

local HASH_MOD = 2147483647
local VALID_BANK = { a = true, b = true, c = true }
local MODES = { "PVP", "PVE" }
local SIDES = { "friendly", "enemy" }

local function Counter(name, amount)
    local counters = D.Diagnostics and D.Diagnostics.counters or nil
    if type(counters) ~= "table" then return end
    counters[name] = (tonumber(counters[name]) or 0) + (tonumber(amount) or 1)
end

local function NowMs()
    return type(U.NowMs) == "function" and U.NowMs() or 0
end

local function DiagnosticsEnabled()
    return D.State ~= nil and D.State.config ~= nil
        and D.State.config.diagnosticsEnabled == true
end

local function NormalizeShardId(value)
    local number = math.floor(tonumber(value) or -1)
    if number < 0 or number >= S.shardCount then return nil end
    return number
end

local function ShardForToken(token)
    local hash = tonumber(U.HashString(tostring(token or ""))) or 0
    return hash % S.shardCount
end

local function ManifestKey(bank)
    return Persistence.Key("stats_shard_manifest", tostring(bank))
end

local function ShardKey(shardId, bank)
    return Persistence.Key(string.format("stats_shard_%02d", tonumber(shardId) or 0), tostring(bank))
end

local function DefaultStorage()
    return {
        read = function(_, key) return Persistence.LoadRaw(key) end,
        write = function(_, key, value) return Persistence.SaveRaw(key, value) end,
        clear = function(_, key) return Persistence.ClearRaw(key) end,
    }
end

local function Storage()
    if type(S.storage) ~= "table" then S.storage = DefaultStorage() end
    return S.storage
end


function S:SetGenerationObserver(observer)
    if observer ~= nil and (type(observer) ~= "table"
        or type(observer.OnShardGenerationCommitted) ~= "function") then
        return false, "INVALID_GENERATION_OBSERVER"
    end
    self.generationObserver = observer
    return true
end

local function NotifyGenerationObserver(summary)
    local observer = S.generationObserver
    if type(observer) ~= "table"
        or type(observer.OnShardGenerationCommitted) ~= "function" then return end
    local ok, err = pcall(observer.OnShardGenerationCommitted, observer, summary)
    if not ok and D.Diagnostics ~= nil and type(D.Diagnostics.AddWarning) == "function" then
        D.Diagnostics:AddWarning("persistence_switch",
            "分片 generation 通知失败：" .. tostring(err))
    end
end

function S:SetStorageAdapter(adapter)
    if adapter == nil then
        self.storage = DefaultStorage()
        return true
    end
    if type(adapter) ~= "table" or type(adapter.read) ~= "function"
        or type(adapter.write) ~= "function" then
        return false, "INVALID_STORAGE_ADAPTER"
    end
    self.storage = adapter
    return true
end

local function CopyWithout(source, omitted)
    local result = {}
    if type(source) ~= "table" then return result end
    for key, value in pairs(source) do
        if omitted[key] ~= true then result[U.DeepCopy(key)] = U.DeepCopy(value) end
    end
    return result
end

local function EmptyIdentityBreakdowns()
    return {
        PVP = { friendly = { actors = {} }, enemy = { actors = {} } },
        PVE = { friendly = { actors = {} }, enemy = { actors = {} } },
    }
end

local function NewShardPayload(shardId)
    return {
        schemaVersion = S.shardSchemaVersion,
        layoutVersion = S.layoutVersion,
        shardId = shardId,
        legacyActors = {
            PVP = { friendly = {}, enemy = {} },
            PVE = { friendly = {}, enemy = {} },
        },
        sharedHealingActors = { friendly = {}, enemy = {} },
        identityProjection = {
            actorIdByToken = {},
            targetRefIdByToken = {},
            actorsById = {},
            targetRefsById = {},
            breakdowns = EmptyIdentityBreakdowns(),
        },
    }
end

local function BuildMeta(payload)
    local meta = CopyWithout(payload, {
        PVP = true, PVE = true, sharedHealing = true, identityProjection = true,
    })
    for _, modeName in ipairs(MODES) do
        local mode = type(payload[modeName]) == "table" and payload[modeName] or {}
        local modeMeta = CopyWithout(mode, { friendly = true, enemy = true })
        for _, sideName in ipairs(SIDES) do
            local side = type(mode[sideName]) == "table" and mode[sideName] or {}
            modeMeta[sideName] = CopyWithout(side, { actors = true })
            modeMeta[sideName].actors = {}
        end
        meta[modeName] = modeMeta
    end
    local shared = type(payload.sharedHealing) == "table" and payload.sharedHealing or {}
    local sharedMeta = CopyWithout(shared, { friendly = true, enemy = true })
    for _, sideName in ipairs(SIDES) do
        local side = type(shared[sideName]) == "table" and shared[sideName] or {}
        sharedMeta[sideName] = CopyWithout(side, { actors = true })
        sharedMeta[sideName].actors = {}
    end
    meta.sharedHealing = sharedMeta

    local identity = type(payload.identityProjection) == "table" and payload.identityProjection or {}
    local identityMeta = CopyWithout(identity, {
        actorIdByToken = true, targetRefIdByToken = true,
        actorsById = true, targetRefsById = true, breakdowns = true,
    })
    identityMeta.actorIdByToken = {}
    identityMeta.targetRefIdByToken = {}
    identityMeta.actorsById = {}
    identityMeta.targetRefsById = {}
    identityMeta.breakdowns = EmptyIdentityBreakdowns()
    local sourceBreakdowns = type(identity.breakdowns) == "table" and identity.breakdowns or {}
    for _, modeName in ipairs(MODES) do
        local sourceMode = type(sourceBreakdowns[modeName]) == "table" and sourceBreakdowns[modeName] or {}
        identityMeta.breakdowns[modeName] = CopyWithout(sourceMode, {
            friendly = true, enemy = true,
        })
        for _, sideName in ipairs(SIDES) do
            local sourceSide = type(sourceMode[sideName]) == "table" and sourceMode[sideName] or {}
            identityMeta.breakdowns[modeName][sideName] = CopyWithout(sourceSide, { actors = true })
            identityMeta.breakdowns[modeName][sideName].actors = {}
        end
    end
    meta.identityProjection = identityMeta
    return meta
end

local function DigestScalar(acc, path, value)
    local kind = type(value)
    local token
    if kind == "number" then
        token = value == value and string.format("%.17g", value) or "nan"
    elseif kind == "boolean" then
        token = value and "true" or "false"
    elseif value == nil then
        token = "nil"
    else
        token = tostring(value)
    end
    local hash = tonumber(U.HashString(path .. "=" .. kind .. ":" .. token)) or 0
    acc.leafCount = acc.leafCount + 1
    acc.sum = (acc.sum + hash) % HASH_MOD
    acc.mix = (acc.mix + ((hash * ((hash % 65521) + 1)) % HASH_MOD)) % HASH_MOD
end

local function DigestValue(acc, path, value, seen)
    if type(value) ~= "table" then
        DigestScalar(acc, path, value)
        return
    end
    seen = seen or {}
    if seen[value] then
        DigestScalar(acc, path, "<cycle>")
        return
    end
    seen[value] = true
    local count = 0
    for key, item in pairs(value) do
        count = count + 1
        DigestValue(acc, path .. "/" .. type(key) .. ":" .. tostring(key), item, seen)
    end
    if count == 0 then DigestScalar(acc, path, "<empty-table>") end
    seen[value] = nil
end

local function Fingerprint(value)
    local acc = { leafCount = 0, sum = 0, mix = 0 }
    DigestValue(acc, "$", value, {})
    return table.concat({ tostring(acc.leafCount), tostring(acc.sum), tostring(acc.mix) }, ":"), acc.leafCount
end

local function NewShardDigest(shardId)
    local acc = { leafCount = 0, sum = 0, mix = 0 }
    DigestScalar(acc, "$schemaVersion", S.shardSchemaVersion)
    DigestScalar(acc, "$layoutVersion", S.layoutVersion)
    DigestScalar(acc, "$shardId", shardId)
    return acc
end

local function DigestFingerprint(acc)
    return table.concat({ tostring(acc.leafCount), tostring(acc.sum), tostring(acc.mix) }, ":"),
        acc.leafCount
end

local function TaskDigestPath(task, key)
    local context = task.context or {}
    return table.concat({
        tostring(task.kind), tostring(context.mode or ""), tostring(context.side or ""),
        type(key) .. ":" .. tostring(key),
    }, "/")
end

local function AddTask(tasks, kind, source, context)
    if type(source) ~= "table" then return end
    tasks[#tasks + 1] = {
        kind = kind,
        source = source,
        context = context,
        lastKey = nil,
    }
end

local function BuildTasks(payload)
    local tasks = {}
    for _, modeName in ipairs(MODES) do
        local mode = type(payload[modeName]) == "table" and payload[modeName] or {}
        for _, sideName in ipairs(SIDES) do
            local side = type(mode[sideName]) == "table" and mode[sideName] or {}
            AddTask(tasks, "LEGACY_ACTOR", side.actors, { mode = modeName, side = sideName })
        end
    end
    local shared = type(payload.sharedHealing) == "table" and payload.sharedHealing or {}
    for _, sideName in ipairs(SIDES) do
        local side = type(shared[sideName]) == "table" and shared[sideName] or {}
        AddTask(tasks, "SHARED_ACTOR", side.actors, { side = sideName })
    end
    local identity = type(payload.identityProjection) == "table" and payload.identityProjection or {}
    AddTask(tasks, "ACTOR_TOKEN", identity.actorIdByToken, {})
    AddTask(tasks, "TARGET_TOKEN", identity.targetRefIdByToken, {})
    AddTask(tasks, "ACTOR_DESCRIPTOR", identity.actorsById, {})
    AddTask(tasks, "TARGET_DESCRIPTOR", identity.targetRefsById, {})
    local breakdowns = type(identity.breakdowns) == "table" and identity.breakdowns or {}
    for _, modeName in ipairs(MODES) do
        local mode = type(breakdowns[modeName]) == "table" and breakdowns[modeName] or {}
        for _, sideName in ipairs(SIDES) do
            local side = type(mode[sideName]) == "table" and mode[sideName] or {}
            AddTask(tasks, "IDENTITY_BREAKDOWN", side.actors,
                { mode = modeName, side = sideName })
        end
    end
    return tasks
end

local function BuildShardDigestTasks(shard)
    local tasks = {}
    shard = type(shard) == "table" and shard or {}
    local legacy = type(shard.legacyActors) == "table" and shard.legacyActors or {}
    for _, modeName in ipairs(MODES) do
        local mode = type(legacy[modeName]) == "table" and legacy[modeName] or {}
        for _, sideName in ipairs(SIDES) do
            AddTask(tasks, "LEGACY_ACTOR", mode[sideName], { mode = modeName, side = sideName })
        end
    end
    local shared = type(shard.sharedHealingActors) == "table" and shard.sharedHealingActors or {}
    for _, sideName in ipairs(SIDES) do
        AddTask(tasks, "SHARED_ACTOR", shared[sideName], { side = sideName })
    end
    local identity = type(shard.identityProjection) == "table" and shard.identityProjection or {}
    AddTask(tasks, "ACTOR_TOKEN", identity.actorIdByToken, {})
    AddTask(tasks, "TARGET_TOKEN", identity.targetRefIdByToken, {})
    AddTask(tasks, "ACTOR_DESCRIPTOR", identity.actorsById, {})
    AddTask(tasks, "TARGET_DESCRIPTOR", identity.targetRefsById, {})
    local breakdowns = type(identity.breakdowns) == "table" and identity.breakdowns or {}
    for _, modeName in ipairs(MODES) do
        local mode = type(breakdowns[modeName]) == "table" and breakdowns[modeName] or {}
        for _, sideName in ipairs(SIDES) do
            local side = type(mode[sideName]) == "table" and mode[sideName] or {}
            AddTask(tasks, "IDENTITY_BREAKDOWN", side.actors,
                { mode = modeName, side = sideName })
        end
    end
    return tasks
end

local function TokenForActorId(job, actorId)
    return job.actorTokenById[tostring(actorId)] or ("actor-id:" .. tostring(actorId))
end

local function TokenForTargetId(job, refId)
    return job.targetTokenById[tostring(refId)] or ("target-ref-id:" .. tostring(refId))
end

local function CopyTaskEntry(job, task, key, value)
    local shardId
    if task.kind == "LEGACY_ACTOR" then
        shardId = ShardForToken("legacy:" .. tostring(key))
        job.shards[shardId].legacyActors[task.context.mode][task.context.side][key] = U.DeepCopy(value)
    elseif task.kind == "SHARED_ACTOR" then
        shardId = ShardForToken("shared:" .. tostring(key))
        job.shards[shardId].sharedHealingActors[task.context.side][key] = U.DeepCopy(value)
    elseif task.kind == "ACTOR_TOKEN" then
        shardId = ShardForToken("identity-actor:" .. tostring(key))
        job.shards[shardId].identityProjection.actorIdByToken[key] = U.DeepCopy(value)
        job.actorTokenById[tostring(value)] = tostring(key)
    elseif task.kind == "TARGET_TOKEN" then
        shardId = ShardForToken("identity-target:" .. tostring(key))
        job.shards[shardId].identityProjection.targetRefIdByToken[key] = U.DeepCopy(value)
        job.targetTokenById[tostring(value)] = tostring(key)
    elseif task.kind == "ACTOR_DESCRIPTOR" then
        local token = type(value) == "table" and value.identityToken or nil
        token = token or TokenForActorId(job, key)
        shardId = ShardForToken("identity-actor:" .. tostring(token))
        job.shards[shardId].identityProjection.actorsById[key] = U.DeepCopy(value)
    elseif task.kind == "TARGET_DESCRIPTOR" then
        local token = type(value) == "table" and value.identityToken or nil
        token = token or TokenForTargetId(job, key)
        shardId = ShardForToken("identity-target:" .. tostring(token))
        job.shards[shardId].identityProjection.targetRefsById[key] = U.DeepCopy(value)
    elseif task.kind == "IDENTITY_BREAKDOWN" then
        local token = TokenForActorId(job, key)
        shardId = ShardForToken("identity-actor:" .. tostring(token))
        job.shards[shardId].identityProjection.breakdowns[task.context.mode]
            [task.context.side].actors[key] = U.DeepCopy(value)
    else
        return false, "UNKNOWN_TASK_KIND"
    end
    DigestValue(job.shardDigests[shardId], TaskDigestPath(task, key), value, {})
    job.rowsCopied = job.rowsCopied + 1
    return true
end

local function NewBuildJob(payload, context)
    local contextInfo = type(context) == "table" and context or {}
    local contextName = type(context) == "table" and context.reason or context
    local shards = {}
    local shardDigests = {}
    for shardId = 0, S.shardCount - 1 do
        shards[shardId] = NewShardPayload(shardId)
        shardDigests[shardId] = NewShardDigest(shardId)
    end
    return {
        kind = "SAVE",
        phase = "SCAN_MANIFESTS",
        payload = payload,
        context = tostring(contextName or "FORMAL_SAVE"),
        sourceFormalSequence = math.max(0, math.floor(tonumber(contextInfo.sequence) or 0)),
        sourceFormalSlot = contextInfo.slot == "primary" and "primary"
            or contextInfo.slot == "backup" and "backup" or nil,
        sourceEnvelopeVersion = math.max(0, math.floor(tonumber(contextInfo.envelopeVersion) or 0)),
        startedAt = NowMs(),
        manifestBanks = {},
        manifestIndex = 1,
        validationCandidates = {},
        validationIndex = 1,
        validationShardId = 0,
        validManifests = {},
        invalidManifestReasons = {},
        validatedRefCache = {},
        validationDigest = nil,
        currentManifest = nil,
        previousManifest = nil,
        sequence = nil,
        targetManifestBank = nil,
        meta = BuildMeta(payload),
        metaFingerprint = nil,
        shards = shards,
        shardDigests = shardDigests,
        tasks = BuildTasks(payload),
        taskIndex = 1,
        actorTokenById = {},
        targetTokenById = {},
        rowsCopied = 0,
        shardFingerprints = {},
        fingerprintShardId = 0,
        dirtyShardIds = {},
        shardRefs = {},
        writeIndex = 1,
        writes = 0,
        reusedShards = 0,
        completed = false,
    }
end

local function MetaShapeValid(meta)
    if type(meta) ~= "table" or tonumber(meta.schemaVersion) ~= 3 then return false end
    for _, modeName in ipairs(MODES) do
        local mode = meta[modeName]
        if type(mode) ~= "table" then return false end
        for _, sideName in ipairs(SIDES) do
            local side = mode[sideName]
            if type(side) ~= "table" or type(side.actors) ~= "table" then return false end
        end
    end
    local shared = meta.sharedHealing
    if type(shared) ~= "table" then return false end
    for _, sideName in ipairs(SIDES) do
        local side = shared[sideName]
        if type(side) ~= "table" or type(side.actors) ~= "table" then return false end
    end
    local identity = meta.identityProjection
    if type(identity) ~= "table" or type(identity.actorIdByToken) ~= "table"
        or type(identity.targetRefIdByToken) ~= "table"
        or type(identity.actorsById) ~= "table" or type(identity.targetRefsById) ~= "table"
        or type(identity.breakdowns) ~= "table" then
        return false
    end
    for _, modeName in ipairs(MODES) do
        local mode = identity.breakdowns[modeName]
        if type(mode) ~= "table" then return false end
        for _, sideName in ipairs(SIDES) do
            local side = mode[sideName]
            if type(side) ~= "table" or type(side.actors) ~= "table" then return false end
        end
    end
    return true
end

local function ShardPayloadShapeValid(payload)
    if type(payload) ~= "table" or type(payload.legacyActors) ~= "table"
        or type(payload.sharedHealingActors) ~= "table"
        or type(payload.identityProjection) ~= "table" then
        return false
    end
    for _, modeName in ipairs(MODES) do
        local mode = payload.legacyActors[modeName]
        if type(mode) ~= "table" then return false end
        for _, sideName in ipairs(SIDES) do
            if type(mode[sideName]) ~= "table" then return false end
        end
    end
    for _, sideName in ipairs(SIDES) do
        if type(payload.sharedHealingActors[sideName]) ~= "table" then return false end
    end
    local identity = payload.identityProjection
    if type(identity.actorIdByToken) ~= "table" or type(identity.targetRefIdByToken) ~= "table"
        or type(identity.actorsById) ~= "table" or type(identity.targetRefsById) ~= "table"
        or type(identity.breakdowns) ~= "table" then
        return false
    end
    for _, modeName in ipairs(MODES) do
        local mode = identity.breakdowns[modeName]
        if type(mode) ~= "table" then return false end
        for _, sideName in ipairs(SIDES) do
            local side = mode[sideName]
            if type(side) ~= "table" or type(side.actors) ~= "table" then return false end
        end
    end
    return true
end

local function ManifestShapeValid(manifest, bank)
    if type(manifest) ~= "table" then return false end
    if tonumber(manifest.schemaVersion) ~= S.manifestSchemaVersion
        or tonumber(manifest.layoutVersion) ~= S.layoutVersion
        or tonumber(manifest.shardCount) ~= S.shardCount then
        return false
    end
    if manifest.bank ~= bank or not VALID_BANK[manifest.bank] then return false end
    local sequence = math.floor(tonumber(manifest.sequence) or -1)
    if sequence < 1 or not MetaShapeValid(manifest.meta) or type(manifest.shards) ~= "table" then
        return false
    end
    for shardId = 0, S.shardCount - 1 do
        local ref = manifest.shards[shardId]
        if type(ref) ~= "table" or NormalizeShardId(ref.shardId) ~= shardId
            or not VALID_BANK[ref.bank] or type(ref.fingerprint) ~= "string"
            or math.floor(tonumber(ref.generation) or -1) < 1 then
            return false
        end
    end
    return true
end

local function ShardEnvelopeShapeValid(envelope, ref)
    if type(envelope) ~= "table" or type(ref) ~= "table" then return false, "MISSING_SHARD" end
    if tonumber(envelope.schemaVersion) ~= S.shardSchemaVersion
        or tonumber(envelope.layoutVersion) ~= S.layoutVersion
        or NormalizeShardId(envelope.shardId) ~= NormalizeShardId(ref.shardId)
        or envelope.bank ~= ref.bank
        or math.floor(tonumber(envelope.generation) or -1) ~= math.floor(tonumber(ref.generation) or -2)
        or not ShardPayloadShapeValid(envelope.payload)
        or envelope.fingerprint ~= ref.fingerprint then
        return false, "SHARD_ENVELOPE_INVALID"
    end
    return true
end

local function BeginEnvelopeDigest(envelope, ref)
    local valid, reason = ShardEnvelopeShapeValid(envelope, ref)
    if not valid then return nil, reason end
    return {
        envelope = envelope,
        ref = ref,
        tasks = BuildShardDigestTasks(envelope.payload),
        taskIndex = 1,
        acc = NewShardDigest(ref.shardId),
        done = false,
    }
end

local function StepEnvelopeDigest(state, budget)
    budget = math.max(1, math.floor(tonumber(budget) or 8))
    local processed = 0
    while processed < budget do
        local task = state.tasks[state.taskIndex]
        if task == nil then
            local fingerprint = DigestFingerprint(state.acc)
            state.done = true
            if fingerprint ~= state.ref.fingerprint
                or fingerprint ~= state.envelope.fingerprint then
                return true, false, "SHARD_DIGEST_MISMATCH"
            end
            return true, true, nil
        end
        local ok, key, value = pcall(next, task.source, task.lastKey)
        if not ok then return true, false, tostring(key) end
        if key == nil then
            state.taskIndex = state.taskIndex + 1
        else
            task.lastKey = key
            DigestValue(state.acc, TaskDigestPath(task, key), value, {})
            processed = processed + 1
        end
    end
    return false, nil, nil
end

local function SortValidManifests(list)
    table.sort(list, function(left, right)
        if left.sequence ~= right.sequence then return left.sequence > right.sequence end
        return tostring(left.bank) < tostring(right.bank)
    end)
end

local function ChooseFreeBank(currentBank, previousBank)
    for _, bank in ipairs(S.banks) do
        if bank ~= currentBank and bank ~= previousBank then return bank end
    end
    return nil
end

local function ManifestShardRef(manifest, shardId)
    return type(manifest) == "table" and type(manifest.shards) == "table"
        and manifest.shards[shardId] or nil
end

local function BuildManifest(job)
    return {
        schemaVersion = S.manifestSchemaVersion,
        layoutVersion = S.layoutVersion,
        shardCount = S.shardCount,
        bank = job.targetManifestBank,
        sequence = job.sequence,
        createdAt = NowMs(),
        sourceStatsSchema = tonumber(job.payload and job.payload.schemaVersion) or 0,
        sourceLastSaveAt = tonumber(job.payload and job.payload.lastSaveAt) or 0,
        sourceFormalSequence = job.sourceFormalSequence,
        sourceFormalSlot = job.sourceFormalSlot,
        sourceEnvelopeVersion = job.sourceEnvelopeVersion,
        metaFingerprint = job.metaFingerprint,
        meta = job.meta,
        shards = job.shardRefs,
        previous = type(job.currentManifest) == "table" and {
            bank = job.currentManifest.bank,
            sequence = job.currentManifest.sequence,
        } or nil,
        formalAuthority = "ROTATING_STATS_V1",
        readOnlyShadow = true,
    }
end

local function FinalizeSelection(job)
    SortValidManifests(job.validManifests)
    job.currentManifest = job.validManifests[1]
    job.previousManifest = job.validManifests[2]
    local maxSequence = 0
    for _, item in ipairs(job.validManifests) do
        maxSequence = math.max(maxSequence, math.floor(tonumber(item.sequence) or 0))
    end
    job.sequence = maxSequence + 1
    job.targetManifestBank = ChooseFreeBank(
        job.currentManifest and job.currentManifest.bank,
        job.previousManifest and job.previousManifest.bank)
    if job.targetManifestBank == nil then return false, "NO_FREE_MANIFEST_BANK" end
    job.phase = "BUILD_ROWS"
    return true
end

local function SelectShardRefs(job)
    job.metaFingerprint = Fingerprint(job.meta)
    for shardId = 0, S.shardCount - 1 do
        local fingerprint, leafCount = DigestFingerprint(job.shardDigests[shardId])
        job.shardFingerprints[shardId] = { fingerprint = fingerprint, leafCount = leafCount }
        local currentRef = ManifestShardRef(job.currentManifest, shardId)
        local previousRef = ManifestShardRef(job.previousManifest, shardId)
        if type(currentRef) == "table" and currentRef.fingerprint == fingerprint then
            job.shardRefs[shardId] = U.DeepCopy(currentRef)
            job.reusedShards = job.reusedShards + 1
        else
            local bank = ChooseFreeBank(currentRef and currentRef.bank, previousRef and previousRef.bank)
            if bank == nil then return false, "NO_FREE_SHARD_BANK:" .. tostring(shardId) end
            job.dirtyShardIds[#job.dirtyShardIds + 1] = shardId
            job.shardRefs[shardId] = {
                shardId = shardId,
                bank = bank,
                generation = job.sequence,
                fingerprint = fingerprint,
                leafCount = leafCount,
            }
        end
    end
    job.phase = "WRITE_SHARDS"
    return true
end

local function Disable(reason)
    S.failed = true
    S.failure = tostring(reason or "UNKNOWN")
    S.activeJob = nil
    Counter("persistenceShardFailures", 1)
    if D.Diagnostics ~= nil and type(D.Diagnostics.AddWarning) == "function" then
        D.Diagnostics:AddWarning("persistence_shards",
            "16-shard 持久化影子已停用：" .. S.failure)
    end
end

function S:OnFormalStatsSaved(payload, context)
    if self.failed == true then return false, "SHARDS_FAILED" end
    if type(payload) ~= "table" or tonumber(payload.schemaVersion) ~= 3 then
        return false, "INVALID_STATS_PAYLOAD"
    end
    if self.activeJob ~= nil then
        Counter("persistenceShardSupersededJobs", 1)
    end
    self.activeJob = NewBuildJob(payload, context)
    Counter("persistenceShardBuildsStarted", 1)
    return true
end

function S:Cancel(reason)
    if self.activeJob == nil then return false end
    self.activeJob = nil
    Counter("persistenceShardCancelledJobs", 1)
    self.lastCancelReason = tostring(reason or "CANCELLED")
    return true
end

function S:OnDiagnosticsChanged(enabled)
    -- Diagnostics controls visibility and explicit audits only. A durable shard
    -- checkpoint already started from a successful rotating save must finish.
    return enabled == true
end

local function StepManifestScan(job)
    local bank = S.banks[job.manifestIndex]
    if bank == nil then
        job.validationCandidates = job.manifestBanks
        job.validationIndex = 1
        job.validationShardId = 0
        job.phase = "VALIDATE_MANIFESTS"
        return true
    end
    local raw = Storage():read(ManifestKey(bank))
    if ManifestShapeValid(raw, bank) then
        job.manifestBanks[#job.manifestBanks + 1] = raw
    end
    job.manifestIndex = job.manifestIndex + 1
    return true
end

local function StepManifestValidation(job, budget)
    local manifest = job.validationCandidates[job.validationIndex]
    if manifest == nil then return FinalizeSelection(job) end
    local shardId = job.validationShardId
    local ref = manifest.shards[shardId]
    local cacheKey = table.concat({ tostring(shardId), tostring(ref.bank),
        tostring(ref.generation), tostring(ref.fingerprint) }, "|")
    local cached = job.validatedRefCache[cacheKey]
    if cached ~= nil then
        if cached ~= true then
            job.invalidManifestReasons[manifest.bank] = cached
            job.validationIndex = job.validationIndex + 1
            job.validationShardId = 0
            return true
        end
    else
        if job.validationDigest == nil then
            local envelope = Storage():read(ShardKey(shardId, ref.bank))
            local state, reason = BeginEnvelopeDigest(envelope, ref)
            if state == nil then
                job.validatedRefCache[cacheKey] = reason or "SHARD_INVALID"
                job.invalidManifestReasons[manifest.bank] = reason
                job.validationIndex = job.validationIndex + 1
                job.validationShardId = 0
                return true
            end
            job.validationDigest = state
        end
        local done, valid, reason = StepEnvelopeDigest(job.validationDigest, budget)
        if not done then return true end
        job.validationDigest = nil
        if valid ~= true then
            job.validatedRefCache[cacheKey] = reason or "SHARD_INVALID"
            job.invalidManifestReasons[manifest.bank] = reason
            job.validationIndex = job.validationIndex + 1
            job.validationShardId = 0
            return true
        end
        job.validatedRefCache[cacheKey] = true
    end
    job.validationShardId = shardId + 1
    if job.validationShardId >= S.shardCount then
        job.validManifests[#job.validManifests + 1] = manifest
        job.validationIndex = job.validationIndex + 1
        job.validationShardId = 0
    end
    return true
end

local function StepBuildRows(job, budget)
    local processed = 0
    while processed < budget do
        local task = job.tasks[job.taskIndex]
        if task == nil then
            job.phase = "SELECT_SHARDS"
            return true, processed
        end
        local ok, key, value = pcall(next, task.source, task.lastKey)
        if not ok then return false, processed, tostring(key) end
        if key == nil then
            job.taskIndex = job.taskIndex + 1
        else
            task.lastKey = key
            local copied, reason = CopyTaskEntry(job, task, key, value)
            if copied ~= true then return false, processed, reason end
            processed = processed + 1
        end
    end
    return true, processed
end

local function StepWriteShard(job)
    local shardId = job.dirtyShardIds[job.writeIndex]
    if shardId == nil then
        job.phase = "WRITE_MANIFEST"
        return true
    end
    local ref = job.shardRefs[shardId]
    local envelope = {
        schemaVersion = S.shardSchemaVersion,
        layoutVersion = S.layoutVersion,
        shardId = shardId,
        bank = ref.bank,
        generation = ref.generation,
        fingerprint = ref.fingerprint,
        leafCount = ref.leafCount,
        payload = job.shards[shardId],
    }
    local ok, reason = Storage():write(ShardKey(shardId, ref.bank), envelope)
    if ok ~= true then return false, tostring(reason or "SHARD_WRITE_FAILED") end
    job.writeIndex = job.writeIndex + 1
    job.writes = job.writes + 1
    Counter("persistenceShardWrites", 1)
    return true
end

local function StepWriteManifest(job)
    local manifest = BuildManifest(job)
    local ok, reason = Storage():write(ManifestKey(job.targetManifestBank), manifest)
    if ok ~= true then return false, tostring(reason or "MANIFEST_WRITE_FAILED") end
    job.manifest = manifest
    job.writes = job.writes + 1
    job.phase = "DONE"
    job.completed = true
    job.completedAt = NowMs()
    S.sequence = job.sequence
    S.lastCompleted = {
        sequence = job.sequence,
        manifestBank = job.targetManifestBank,
        previousSequence = job.currentManifest and job.currentManifest.sequence or nil,
        dirtyShards = #job.dirtyShardIds,
        reusedShards = job.reusedShards,
        rowsCopied = job.rowsCopied,
        writes = job.writes,
        completedAt = job.completedAt,
        manifestWrittenLast = true,
        formalAuthorityUnchanged = true,
        sourceFormalSequence = job.sourceFormalSequence,
        sourceFormalSlot = job.sourceFormalSlot,
        sourceEnvelopeVersion = job.sourceEnvelopeVersion,
        sourceStatsSchema = tonumber(job.payload and job.payload.schemaVersion) or 0,
    }
    Counter("persistenceShardGenerationsCommitted", 1)
    Counter("persistenceShardDirtyShards", #job.dirtyShardIds)
    Counter("persistenceShardReusedShards", job.reusedShards)
    local summary = S.lastCompleted
    S.activeJob = nil
    NotifyGenerationObserver(summary)
    return true
end

function S:Step(budget)
    local job = self.activeJob
    if job == nil then return true, nil, nil end
    budget = math.max(1, math.floor(tonumber(budget) or self.defaultBuildBudget))

    local fn, arg
    if job.phase == "SCAN_MANIFESTS" then
        fn = StepManifestScan
    elseif job.phase == "VALIDATE_MANIFESTS" then
        fn, arg = StepManifestValidation, budget
    elseif job.phase == "BUILD_ROWS" then
        fn, arg = StepBuildRows, budget
    elseif job.phase == "SELECT_SHARDS" then
        fn = SelectShardRefs
    elseif job.phase == "WRITE_SHARDS" then
        fn = StepWriteShard
    elseif job.phase == "WRITE_MANIFEST" then
        fn = StepWriteManifest
    elseif job.phase == "DONE" then
        self.activeJob = nil
        return true, self.lastCompleted, nil
    else
        Disable("UNKNOWN_PHASE:" .. tostring(job.phase))
        return true, nil, "UNKNOWN_PHASE"
    end

    local callOk, result, extra, detail
    if arg ~= nil then
        callOk, result, extra, detail = pcall(fn, job, arg)
    else
        callOk, result, extra, detail = pcall(fn, job)
    end
    if not callOk then
        Disable(result)
        return true, nil, tostring(result)
    end
    if result ~= true then
        local reason = detail or extra or result or "PHASE_FAILED"
        Disable(reason)
        return true, nil, tostring(reason)
    end
    if self.activeJob == nil then return true, self.lastCompleted, nil end
    return false, nil, nil
end

local function MergeMap(target, source)
    if type(source) ~= "table" then return end
    for key, value in pairs(source) do target[key] = U.DeepCopy(value) end
end

local function MergeShardIntoRoot(root, shard)
    if type(root) ~= "table" or type(shard) ~= "table" then return false end
    for _, modeName in ipairs(MODES) do
        for _, sideName in ipairs(SIDES) do
            local target = root[modeName][sideName].actors
            local source = shard.legacyActors[modeName][sideName]
            MergeMap(target, source)
        end
    end
    for _, sideName in ipairs(SIDES) do
        MergeMap(root.sharedHealing[sideName].actors,
            shard.sharedHealingActors[sideName])
    end
    local targetIdentity = root.identityProjection
    local sourceIdentity = shard.identityProjection
    MergeMap(targetIdentity.actorIdByToken, sourceIdentity.actorIdByToken)
    MergeMap(targetIdentity.targetRefIdByToken, sourceIdentity.targetRefIdByToken)
    MergeMap(targetIdentity.actorsById, sourceIdentity.actorsById)
    MergeMap(targetIdentity.targetRefsById, sourceIdentity.targetRefsById)
    for _, modeName in ipairs(MODES) do
        for _, sideName in ipairs(SIDES) do
            MergeMap(targetIdentity.breakdowns[modeName][sideName].actors,
                sourceIdentity.breakdowns[modeName][sideName].actors)
        end
    end
    return true
end

function S:BeginRecovery()
    return {
        kind = "RECOVERY",
        phase = "SCAN_MANIFESTS",
        manifestBanks = {},
        manifestIndex = 1,
        validationCandidates = {},
        validationIndex = 1,
        validationShardId = 0,
        validManifests = {},
        invalidManifestReasons = {},
        validatedRefCache = {},
        validationDigest = nil,
        selected = nil,
        previous = nil,
        reconstructShardId = 0,
        recoveredRoot = nil,
        loadedShards = {},
        done = false,
        startedAt = NowMs(),
    }
end

local function RecoveryScan(job)
    local bank = S.banks[job.manifestIndex]
    if bank == nil then
        job.validationCandidates = job.manifestBanks
        job.phase = "VALIDATE_MANIFESTS"
        return true
    end
    local raw = Storage():read(ManifestKey(bank))
    if ManifestShapeValid(raw, bank) then job.manifestBanks[#job.manifestBanks + 1] = raw end
    job.manifestIndex = job.manifestIndex + 1
    return true
end

local function RecoveryValidate(job, budget)
    local manifest = job.validationCandidates[job.validationIndex]
    if manifest == nil then
        SortValidManifests(job.validManifests)
        job.selected = job.validManifests[1]
        job.previous = job.validManifests[2]
        if job.selected == nil then
            job.done = true
            job.phase = "DONE"
            job.reason = "NO_VALID_GENERATION"
            return true
        end
        job.recoveredRoot = U.DeepCopy(job.selected.meta)
        job.reconstructShardId = 0
        job.phase = "RECONSTRUCT"
        return true
    end
    local shardId = job.validationShardId
    local ref = manifest.shards[shardId]
    local cacheKey = table.concat({ tostring(shardId), tostring(ref.bank),
        tostring(ref.generation), tostring(ref.fingerprint) }, "|")
    local cached = job.validatedRefCache[cacheKey]
    if cached ~= nil then
        if cached ~= true then
            job.invalidManifestReasons[manifest.bank] = cached
            job.validationIndex = job.validationIndex + 1
            job.validationShardId = 0
            return true
        end
    else
        if job.validationDigest == nil then
            local envelope = Storage():read(ShardKey(shardId, ref.bank))
            local state, reason = BeginEnvelopeDigest(envelope, ref)
            if state == nil then
                job.validatedRefCache[cacheKey] = reason or "SHARD_INVALID"
                job.invalidManifestReasons[manifest.bank] = reason
                job.validationIndex = job.validationIndex + 1
                job.validationShardId = 0
                return true
            end
            job.validationDigest = state
        end
        local done, valid, reason = StepEnvelopeDigest(job.validationDigest, budget)
        if not done then return true end
        job.validationDigest = nil
        if valid ~= true then
            job.validatedRefCache[cacheKey] = reason or "SHARD_INVALID"
            job.invalidManifestReasons[manifest.bank] = reason
            job.validationIndex = job.validationIndex + 1
            job.validationShardId = 0
            return true
        end
        job.validatedRefCache[cacheKey] = true
    end
    job.validationShardId = shardId + 1
    if job.validationShardId >= S.shardCount then
        job.validManifests[#job.validManifests + 1] = manifest
        job.validationIndex = job.validationIndex + 1
        job.validationShardId = 0
    end
    return true
end

local function RecoveryReconstruct(job)
    local shardId = job.reconstructShardId
    if shardId >= S.shardCount then
        job.done = true
        job.phase = "DONE"
        job.completedAt = NowMs()
        S.lastRecovery = {
            sequence = job.selected.sequence,
            manifestBank = job.selected.bank,
            previousSequence = job.previous and job.previous.sequence or nil,
            recovered = true,
            formalAuthorityUnchanged = true,
        }
        return true
    end
    local ref = job.selected.shards[shardId]
    local envelope = Storage():read(ShardKey(shardId, ref.bank))
    local valid, reason = ShardEnvelopeShapeValid(envelope, ref)
    if not valid then
        job.done = true
        job.phase = "DONE"
        job.reason = reason
        return false, reason
    end
    MergeShardIntoRoot(job.recoveredRoot, envelope.payload)
    job.reconstructShardId = shardId + 1
    return true
end

function S:StepRecovery(job, budget)
    if type(job) ~= "table" then return true, nil, "INVALID_RECOVERY_JOB" end
    if job.done == true then return true, job.recoveredRoot, job.reason end
    budget = math.max(1, math.floor(tonumber(budget) or 1))
    for _ = 1, budget do
        local fn
        if job.phase == "SCAN_MANIFESTS" then
            fn = RecoveryScan
        elseif job.phase == "VALIDATE_MANIFESTS" then
            fn = RecoveryValidate
        elseif job.phase == "RECONSTRUCT" then
            fn = RecoveryReconstruct
        elseif job.phase == "DONE" then
            job.done = true
            return true, job.recoveredRoot, job.reason
        else
            job.done = true
            job.reason = "UNKNOWN_RECOVERY_PHASE"
            return true, nil, job.reason
        end
        local callOk, result, reason
        if fn == RecoveryValidate then
            callOk, result, reason = pcall(fn, job, budget)
        else
            callOk, result, reason = pcall(fn, job)
        end
        if not callOk or result ~= true then
            job.done = true
            job.reason = callOk and tostring(reason or result or "RECOVERY_FAILED")
                or tostring(result)
            return true, nil, job.reason
        end
        if job.done == true then return true, job.recoveredRoot, job.reason end
    end
    return false, nil, nil
end


------------------------------------------------------------------------
-- Streaming verification
--
-- The formal root is never copied and a recovered shard root is never built.
-- Each validated shard envelope is compared through the same logical digest
-- used by the writer. This keeps peak memory near one formal root plus one
-- loaded shard envelope instead of retaining formal + recovered roots.
------------------------------------------------------------------------

local function DigestTaskEntry(job, task, key, value)
    local shardId
    if task.kind == "LEGACY_ACTOR" then
        shardId = ShardForToken("legacy:" .. tostring(key))
    elseif task.kind == "SHARED_ACTOR" then
        shardId = ShardForToken("shared:" .. tostring(key))
    elseif task.kind == "ACTOR_TOKEN" then
        shardId = ShardForToken("identity-actor:" .. tostring(key))
        job.actorTokenById[tostring(value)] = tostring(key)
    elseif task.kind == "TARGET_TOKEN" then
        shardId = ShardForToken("identity-target:" .. tostring(key))
        job.targetTokenById[tostring(value)] = tostring(key)
    elseif task.kind == "ACTOR_DESCRIPTOR" then
        local token = type(value) == "table" and value.identityToken or nil
        token = token or TokenForActorId(job, key)
        shardId = ShardForToken("identity-actor:" .. tostring(token))
    elseif task.kind == "TARGET_DESCRIPTOR" then
        local token = type(value) == "table" and value.identityToken or nil
        token = token or TokenForTargetId(job, key)
        shardId = ShardForToken("identity-target:" .. tostring(token))
    elseif task.kind == "IDENTITY_BREAKDOWN" then
        local token = TokenForActorId(job, key)
        shardId = ShardForToken("identity-actor:" .. tostring(token))
    else
        return false, "UNKNOWN_TASK_KIND"
    end
    DigestValue(job.formalShardDigests[shardId], TaskDigestPath(task, key), value, {})
    job.rowsDigested = job.rowsDigested + 1
    return true
end

function S:BeginStreamVerification(formalRoot)
    if type(formalRoot) ~= "table" or tonumber(formalRoot.schemaVersion) ~= 3 then
        return nil, "INVALID_FORMAL_ROOT"
    end
    local job = self:BeginRecovery()
    job.kind = "STREAM_VERIFY"
    job.formalRoot = formalRoot
    job.formalMeta = nil
    job.formalMetaFingerprint = nil
    job.formalTasks = nil
    job.formalTaskIndex = 1
    job.formalShardDigests = {}
    job.actorTokenById = {}
    job.targetTokenById = {}
    job.rowsDigested = 0
    job.result = nil
    return job
end

local function PrepareFormalStream(job)
    job.recoveredRoot = nil
    job.loadedShards = nil
    job.formalMeta = BuildMeta(job.formalRoot)
    job.formalMetaFingerprint = Fingerprint(job.formalMeta)
    job.formalTasks = BuildTasks(job.formalRoot)
    for shardId = 0, S.shardCount - 1 do
        job.formalShardDigests[shardId] = NewShardDigest(shardId)
    end
    job.formalTaskIndex = 1
    job.phase = "DIGEST_FORMAL_ROOT"
end

local function StepFormalDigest(job, budget)
    local processed = 0
    while processed < budget do
        local task = job.formalTasks[job.formalTaskIndex]
        if task == nil then
            job.phase = "COMPARE_STREAM_DIGESTS"
            return true
        end
        local ok, key, value = pcall(next, task.source, task.lastKey)
        if not ok then return false, tostring(key) end
        if key == nil then
            job.formalTaskIndex = job.formalTaskIndex + 1
        else
            task.lastKey = key
            local digested, reason = DigestTaskEntry(job, task, key, value)
            if digested ~= true then return false, reason end
            processed = processed + 1
        end
    end
    return true
end

local function CompareStreamDigests(job)
    local selected = job.selected
    if type(selected) ~= "table" then return false, "NO_VALID_GENERATION" end
    local storedMetaFingerprint = Fingerprint(selected.meta)
    if storedMetaFingerprint ~= selected.metaFingerprint then
        return false, "MANIFEST_META_DIGEST_MISMATCH"
    end
    if job.formalMetaFingerprint ~= selected.metaFingerprint then
        return false, "FORMAL_META_MISMATCH"
    end
    for shardId = 0, S.shardCount - 1 do
        local expected = DigestFingerprint(job.formalShardDigests[shardId])
        local ref = selected.shards[shardId]
        if type(ref) ~= "table" or expected ~= ref.fingerprint then
            job.mismatchShardId = shardId
            return false, "FORMAL_SHARD_DIGEST_MISMATCH"
        end
    end
    job.result = {
        equivalent = true,
        selected = selected,
        previous = job.previous,
        validManifests = job.validManifests,
        invalidManifestReasons = job.invalidManifestReasons,
        rowsDigested = job.rowsDigested,
        streaming = true,
    }
    job.done = true
    job.phase = "DONE"
    job.formalRoot = nil
    job.formalMeta = nil
    job.formalTasks = nil
    job.formalShardDigests = nil
    return true
end

function S:StepStreamVerification(job, budget)
    if type(job) ~= "table" or job.kind ~= "STREAM_VERIFY" then
        return true, nil, "INVALID_STREAM_JOB"
    end
    if job.done == true then return true, job.result, job.reason end
    budget = math.max(1, math.floor(tonumber(budget) or 16))

    local ok, reason
    if job.phase == "SCAN_MANIFESTS" then
        ok, reason = RecoveryScan(job)
    elseif job.phase == "VALIDATE_MANIFESTS" then
        ok, reason = RecoveryValidate(job, budget)
        if ok == true and job.phase == "RECONSTRUCT" then PrepareFormalStream(job) end
    elseif job.phase == "DIGEST_FORMAL_ROOT" then
        ok, reason = StepFormalDigest(job, budget)
    elseif job.phase == "COMPARE_STREAM_DIGESTS" then
        ok, reason = CompareStreamDigests(job)
    elseif job.phase == "DONE" then
        job.done = true
        return true, job.result, job.reason
    else
        ok, reason = false, "UNKNOWN_STREAM_PHASE"
    end

    if ok ~= true then
        job.done = true
        job.reason = tostring(reason or "STREAM_VERIFY_FAILED")
        job.formalRoot = nil
        job.formalMeta = nil
        job.formalTasks = nil
        job.formalShardDigests = nil
        return true, nil, job.reason
    end
    if job.done == true then return true, job.result, job.reason end
    return false, nil, nil
end

------------------------------------------------------------------------
-- Fixed-key maintenance
------------------------------------------------------------------------

local function MaintenanceKeys()
    local keys = {}
    for _, bank in ipairs(S.banks) do keys[#keys + 1] = ManifestKey(bank) end
    for shardId = 0, S.shardCount - 1 do
        for _, bank in ipairs(S.banks) do
            keys[#keys + 1] = ShardKey(shardId, bank)
        end
    end
    return keys
end

function S:BeginClearStorage(reason)
    if self.activeJob ~= nil then return false, "SAVE_JOB_ACTIVE" end
    if self.maintenanceJob ~= nil then return false, "MAINTENANCE_ACTIVE" end
    self.maintenanceJob = {
        kind = "CLEAR_FIXED_STORAGE",
        reason = tostring(reason or "MANUAL"),
        keys = MaintenanceKeys(),
        cursor = 1,
        cleared = 0,
        failures = {},
        startedAt = NowMs(),
    }
    return true
end

function S:StepMaintenance(operationBudget)
    local job = self.maintenanceJob
    if type(job) ~= "table" then return true, nil, nil end
    local budget = math.max(1, math.floor(tonumber(operationBudget) or 1))
    for _ = 1, budget do
        local key = job.keys[job.cursor]
        if key == nil then
            local result = {
                kind = job.kind,
                cleared = job.cleared,
                failures = job.failures,
                completedAt = NowMs(),
            }
            self.maintenanceJob = nil
            self.lastMaintenance = result
            self.lastCompleted = nil
            self.lastRecovery = nil
            self.sequence = 0
            return true, result, #result.failures > 0 and "PARTIAL_CLEAR_FAILURE" or nil
        end
        local ok, reason = Storage():clear(key)
        if ok == true then
            job.cleared = job.cleared + 1
        else
            job.failures[#job.failures + 1] = { key = key, reason = tostring(reason) }
        end
        job.cursor = job.cursor + 1
    end
    return false, nil, nil
end

function S:GetMaintenanceStatus()
    local job = self.maintenanceJob
    if type(job) == "table" then
        return string.format("清理中 %d/%d", math.max(0, job.cursor - 1), #job.keys)
    end
    local last = self.lastMaintenance
    if type(last) == "table" then
        return string.format("上次清理 %d 项，失败 %d 项", last.cleared or 0, #(last.failures or {}))
    end
    return "未执行清理"
end

function S:GetStatusLine()
    if self.failed == true then
        return "16-shard 存档：已停用 / " .. tostring(self.failure or "未知错误")
    end
    local job = self.activeJob
    if type(job) == "table" then
        return string.format("16-shard 存档：%s / 已复制 %d 行 / 脏 shard %d",
            tostring(job.phase), tonumber(job.rowsCopied) or 0, #job.dirtyShardIds)
    end
    local last = self.lastCompleted
    if type(last) == "table" then
        return string.format("16-shard 存档：G%d / 脏 %d / 复用 %d / rotating 回退保留",
            tonumber(last.sequence) or 0, tonumber(last.dirtyShards) or 0,
            tonumber(last.reusedShards) or 0)
    end
    return "16-shard 存档：待首次正式保存 / rotating 回退保留"
end

function S:ResetForTests()
    self.failed = false
    self.failure = nil
    self.activeJob = nil
    self.lastCompleted = nil
    self.lastRecovery = nil
    self.sequence = 0
    self.maintenanceJob = nil
end

local registered, registerReason = Persistence.SetStatsShardObserver(Persistence, S)
if registered ~= true then
    Boot:Fail("persistence_shards:observer", tostring(registerReason or "observer registration failed"))
    return
end

Boot:CompletePhase("PERSISTENCE_SHARDS_READY")
if D.Diagnostics ~= nil then D.Diagnostics.status = "PERSISTENCE_SHARDS_READY" end

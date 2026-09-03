ReplicatedSuiteModuleSandbox:Enter('dps', {'ReplicatedDps', 'ReplicatedDpsConfig'})
------------------------------------------------------------------------
-- Replicated DPS - Stats Schema v3 projection adapter
-- Author: Replicated
--
-- Authority and compatibility boundary
--   * D.State.stats.PVP/PVE remain the compatibility projection consumed by
--     current ranking, Boss, replay and UI code in this preparation stage.
--   * D.State.stats.sharedHealing is the new independent healing projection.
--   * D.State.stats.identityProjection owns persisted ActorId / TargetRef IDs
--     and identity-keyed breakdown deltas produced after Schema v3 migration.
--   * D.ActorRegistry is a read-only Proxy for current Entity facts. Its
--     process-local ActorId values are never persisted or reused here.
--
-- Serialization layout
--   sharedHealing
--     schemaVersion = 1
--     friendly/enemy = legacy-shaped side records containing only meaningful
--       heal values. The familiar shape keeps the compatibility adapter small.
--
--   identityProjection
--     schemaVersion = 1
--     nextActorId / nextTargetRefId = monotonically increasing integer IDs.
--     actorIdByToken / targetRefIdByToken = intern dictionaries.
--     actorsById / targetRefsById = serialized descriptors keyed by decimal ID.
--     breakdowns[mode][side].actors[actorId].metrics[metric]
--       amount       = total v3 delta for this actor/metric.
--       abilities    = ability-name -> amount.
--       counterparts = TargetRefId-as-string -> amount.
--
-- Old v2 history cannot be losslessly split by stable identity. It remains in
-- the compatibility PVP/PVE maps and is explicitly described by migration
-- metadata. New v3 events use stable Actor/TargetRef tokens when available;
-- unresolved history remains a NAME_HISTORY reference and is never guessed
-- into a later stable unit.
--
-- Performance boundary
--   * No full history scan occurs in the combat callback.
--   * Interning and breakdown writes are O(1) average.
--   * A new detail key is admitted only while the per-map cap is available;
--     overflow is accumulated in one fixed "__other__" bucket.
--   * Consistency audits are explicit bounded jobs; no full audit runs in Tick.
------------------------------------------------------------------------

if ReplicatedDps == nil or ReplicatedDps.Boot == nil then return end

local D = ReplicatedDps
local Boot = D.Boot
if Boot.phase == "FAILED" then return end
if type(D.ActorRegistry) ~= "table" or type(D.ActorRegistry.GetEntityByKey) ~= "function" then
    Boot:Fail("stats_v3:actor_registry", "D.ActorRegistry is unavailable")
    return
end
if type(D.Stats) ~= "table" or type(D.Stats.SetStatsV3Observer) ~= "function" then
    Boot:Fail("stats_v3:stats", "D.Stats v3 observer boundary is unavailable")
    return
end
if type(D.State) ~= "table" or type(D.State.stats) ~= "table"
    or tonumber(D.State.stats.schemaVersion) ~= 3 then
    Boot:Fail("stats_v3:schema", "Stats Schema v3 root is unavailable")
    return
end

Boot:SetPhase("STATS_V3_LOADING")

local U = D.Util
local Actors = D.ActorRegistry
local Stats = D.Stats

D.StatsV3 = D.StatsV3 or {}
local V = D.StatsV3
V.schemaVersion = 1
V.failed = false
V.failure = nil
V.metricWrites = 0
V.sharedHealingWrites = 0
V.actorInterns = 0
V.targetRefInterns = 0
V.mismatchCount = 0
V.auditChecks = 0
V.checksByToken = {}
V.checkEntries = {}
V.authorityRoot = nil
V.actorIdCache = setmetatable({}, { __mode = "k" })
V.targetRefCache = setmetatable({}, { __mode = "k" })
V.metricRowCache = setmetatable({}, { __mode = "k" })
V.projectionReady = setmetatable({}, { __mode = "k" })
V.diagnosticsFlushedGeneration = tonumber(V.diagnosticsFlushedGeneration) or 0

local VALID_METRICS = { damage = true, taken = true, heal = true, kills = true }
local VALID_MODES = { PVP = true, PVE = true }
local VALID_SIDES = { friendly = true, enemy = true }
local MAX_KEYS = math.max(8, math.floor(tonumber(D.Const and D.Const.MAX_BREAKDOWN_KEYS) or 120))

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

local function SafeName(value, fallback)
    if U ~= nil and type(U.SafeName) == "function" then return U.SafeName(value, fallback or "未知") end
    local text = tostring(value or "")
    if text == "" then return fallback or "未知" end
    return text
end

local function NormalizeName(value)
    if U ~= nil and type(U.NormalizeName) == "function" then return U.NormalizeName(value) end
    local text = tostring(value or "")
    text = string.gsub(text, "^%s+", "")
    text = string.gsub(text, "%s+$", "")
    return string.lower(text)
end

local function EnsureNumberMap(value)
    return type(value) == "table" and value or {}
end

local function AddBounded(map, key, amount)
    map = EnsureNumberMap(map)
    local text = tostring(key or "")
    if text == "" then text = "未知" end
    if map[text] ~= nil then
        map[text] = (tonumber(map[text]) or 0) + amount
        return map, false
    end
    local count = 0
    for _ in pairs(map) do
        count = count + 1
        if count >= MAX_KEYS then break end
    end
    if count >= MAX_KEYS then
        map.__other__ = (tonumber(map.__other__) or 0) + amount
        return map, false
    end
    map[text] = amount
    return map, true
end

local function EnsureProjection(root)
    root.identityProjection = type(root.identityProjection) == "table" and root.identityProjection or {}
    local projection = root.identityProjection
    if V.projectionReady[projection] == true then return projection end
    projection.schemaVersion = 1
    projection.nextActorId = math.max(0, math.floor(tonumber(projection.nextActorId) or 0))
    projection.nextTargetRefId = math.max(0, math.floor(tonumber(projection.nextTargetRefId) or 0))
    projection.actorIdByToken = type(projection.actorIdByToken) == "table" and projection.actorIdByToken or {}
    projection.targetRefIdByToken = type(projection.targetRefIdByToken) == "table" and projection.targetRefIdByToken or {}
    projection.actorsById = type(projection.actorsById) == "table" and projection.actorsById or {}
    projection.targetRefsById = type(projection.targetRefsById) == "table" and projection.targetRefsById or {}
    projection.breakdowns = type(projection.breakdowns) == "table" and projection.breakdowns or {}
    for _, mode in ipairs({ "PVP", "PVE" }) do
        projection.breakdowns[mode] = type(projection.breakdowns[mode]) == "table"
            and projection.breakdowns[mode] or {}
        for _, sideName in ipairs({ "friendly", "enemy" }) do
            local side = projection.breakdowns[mode][sideName]
            if type(side) ~= "table" then
                side = { actors = {} }
                projection.breakdowns[mode][sideName] = side
            end
            side.actors = type(side.actors) == "table" and side.actors or {}
        end
    end
    projection.migration = type(projection.migration) == "table" and projection.migration or {
        sourceSchema = 2,
        legacyModeBucketsRetained = true,
        legacyNameBreakdownsRetained = true,
    }
    V.projectionReady[projection] = true
    return projection
end

local function IdentityQuality(entity)
    if type(Actors.GetIdentityQuality) == "function" then
        return Actors:GetIdentityQuality(entity)
    end
    return "UNKNOWN_KEY"
end

local function ActorIdentityToken(entity)
    if type(entity) ~= "table" then return "actor:missing" end
    local stableId = type(Actors.GetStableId) == "function" and Actors:GetStableId(entity) or entity.stringId
    local quality = IdentityQuality(entity)
    if stableId ~= nil and tostring(stableId) ~= "" and quality == "STABLE_ID" then
        return "actor:id:" .. tostring(stableId), "STABLE_ID"
    end
    local key = tostring(entity.key or "")
    if key == "" then key = "history:" .. NormalizeName(entity.name) end
    return "actor:legacy-key:" .. key, quality
end

local function InternActor(projection, entity)
    if type(entity) == "table" then
        local cached = V.actorIdCache[entity]
        if type(cached) == "table" and cached.projection == projection
            and tonumber(cached.actorId) ~= nil then
            local descriptor = projection.actorsById[tostring(cached.actorId)]
            local displayName = SafeName(entity.name, "未知")
            if type(descriptor) == "table" and cached.displayName ~= displayName then
                descriptor.displayName = displayName
                descriptor.normalizedName = NormalizeName(displayName)
                descriptor.canonicalKey = entity.key or descriptor.canonicalKey
                cached.displayName = displayName
            end
            return cached.actorId
        end
    end
    local token, quality = ActorIdentityToken(entity)
    local actorId = tonumber(projection.actorIdByToken[token])
    if actorId == nil or actorId <= 0 then
        projection.nextActorId = projection.nextActorId + 1
        actorId = projection.nextActorId
        projection.actorIdByToken[token] = actorId
        projection.actorsById[tostring(actorId)] = {
            actorId = actorId,
            identityToken = token,
            canonicalKey = type(entity) == "table" and entity.key or nil,
            stableId = type(entity) == "table" and Actors:GetStableId(entity) or nil,
            displayName = SafeName(type(entity) == "table" and entity.name, "未知"),
            normalizedName = NormalizeName(type(entity) == "table" and entity.name),
            identityQuality = quality,
        }
        V.actorInterns = V.actorInterns + 1
        Counter("statsV3ActorInterns", 1)
    else
        actorId = math.floor(actorId)
        local descriptor = projection.actorsById[tostring(actorId)]
        if type(descriptor) == "table" and type(entity) == "table" then
            descriptor.canonicalKey = entity.key or descriptor.canonicalKey
            descriptor.displayName = SafeName(entity.name, descriptor.displayName or "未知")
            descriptor.normalizedName = NormalizeName(descriptor.displayName)
            descriptor.stableId = Actors:GetStableId(entity) or descriptor.stableId
            descriptor.identityQuality = quality
        end
    end
    if type(entity) == "table" then
        V.actorIdCache[entity] = {
            projection = projection,
            actorId = actorId,
            displayName = SafeName(entity.name, "未知"),
        }
    end
    return actorId
end

local function ResolveEndpoint(event, role)
    event = type(event) == "table" and event or {}
    role = role == "source" and "source" or "target"
    local key = event[role .. "ResolvedKey"] or event[role .. "Key"]
    local entity = key ~= nil and Actors:GetEntityByKey(key) or nil
    local displayName = SafeName(event[role .. "Name"] or (entity and entity.name), "未知")
    return entity, displayName
end

local function TargetIdentityToken(entity, displayName)
    if type(entity) == "table" then
        local actorToken, quality = ActorIdentityToken(entity)
        if quality == "STABLE_ID" then return "target:" .. actorToken, "ACTOR", quality end
        local key = tostring(entity.key or "")
        if key ~= "" then return "target:name-history:" .. quality .. ":" .. key, "NAME_HISTORY", quality end
    end
    local normalized = NormalizeName(displayName)
    if normalized == "" then normalized = "unknown" end
    return "target:name-history:MISSING:" .. normalized, "NAME_HISTORY", "MISSING"
end

local function InternTargetRef(projection, event, role)
    local entity, displayName = ResolveEndpoint(event, role)
    if type(entity) == "table" then
        local cached = V.targetRefCache[entity]
        if type(cached) == "table" and cached.projection == projection
            and tonumber(cached.refId) ~= nil then
            local descriptor = projection.targetRefsById[tostring(cached.refId)]
            if type(descriptor) == "table" and cached.displayName ~= displayName then
                descriptor.displayName = displayName
                descriptor.normalizedName = NormalizeName(displayName)
                descriptor.canonicalKey = entity.key or descriptor.canonicalKey
                cached.displayName = displayName
            end
            return cached.refId
        end
    end
    local token, kind, quality = TargetIdentityToken(entity, displayName)
    local refId = tonumber(projection.targetRefIdByToken[token])
    if refId == nil or refId <= 0 then
        projection.nextTargetRefId = projection.nextTargetRefId + 1
        refId = projection.nextTargetRefId
        projection.targetRefIdByToken[token] = refId
        local actorId = kind == "ACTOR" and InternActor(projection, entity) or nil
        projection.targetRefsById[tostring(refId)] = {
            refId = refId,
            identityToken = token,
            kind = kind,
            actorId = actorId,
            canonicalKey = type(entity) == "table" and entity.key or nil,
            displayName = displayName,
            normalizedName = NormalizeName(displayName),
            resolutionQuality = quality,
        }
        V.targetRefInterns = V.targetRefInterns + 1
        Counter("statsV3TargetRefInterns", 1)
    else
        refId = math.floor(refId)
        local descriptor = projection.targetRefsById[tostring(refId)]
        if type(descriptor) == "table" then
            descriptor.displayName = displayName
            descriptor.normalizedName = NormalizeName(displayName)
            descriptor.canonicalKey = type(entity) == "table" and entity.key or descriptor.canonicalKey
        end
    end
    if type(entity) == "table" then
        V.targetRefCache[entity] = {
            projection = projection,
            refId = refId,
            displayName = displayName,
        }
    end
    return refId
end

local function EnsureMetricProjection(projection, mode, sideName, actorId, metric, entity)
    if type(entity) == "table" then
        local cached = V.metricRowCache[entity]
        if type(cached) ~= "table" or cached.projection ~= projection then
            cached = { projection = projection, rows = {} }
            V.metricRowCache[entity] = cached
        end
        local modeRows = cached.rows[mode]
        if type(modeRows) ~= "table" then
            modeRows = {}
            cached.rows[mode] = modeRows
        end
        local sideRows = modeRows[sideName]
        if type(sideRows) ~= "table" then
            sideRows = {}
            modeRows[sideName] = sideRows
        end
        local cachedRow = sideRows[metric]
        if type(cachedRow) == "table" then return cachedRow end

        local side = projection.breakdowns[mode][sideName]
        local actorKey = tostring(actorId)
        local actor = side.actors[actorKey]
        if type(actor) ~= "table" then
            actor = { actorId = actorId, metrics = {} }
            side.actors[actorKey] = actor
        end
        actor.metrics = type(actor.metrics) == "table" and actor.metrics or {}
        local row = actor.metrics[metric]
        if type(row) ~= "table" then
            row = { amount = 0, abilities = {}, counterparts = {} }
            actor.metrics[metric] = row
        end
        row.amount = math.max(0, tonumber(row.amount) or 0)
        row.abilities = EnsureNumberMap(row.abilities)
        row.counterparts = EnsureNumberMap(row.counterparts)
        sideRows[metric] = row
        return row
    end

    local side = projection.breakdowns[mode][sideName]
    local actorKey = tostring(actorId)
    local actor = side.actors[actorKey]
    if type(actor) ~= "table" then
        actor = { actorId = actorId, metrics = {} }
        side.actors[actorKey] = actor
    end
    actor.metrics = type(actor.metrics) == "table" and actor.metrics or {}
    local row = actor.metrics[metric]
    if type(row) ~= "table" then
        row = { amount = 0, abilities = {}, counterparts = {} }
        actor.metrics[metric] = row
    end
    row.amount = math.max(0, tonumber(row.amount) or 0)
    row.abilities = EnsureNumberMap(row.abilities)
    row.counterparts = EnsureNumberMap(row.counterparts)
    return row
end

local function AbilityKey(metric, event)
    event = type(event) == "table" and event or {}
    local value = tostring(event.abilityName or "")
    if value ~= "" then return value end
    return metric == "kills" and "未知技能" or "未知"
end

local function CounterpartRole(metric)
    return metric == "taken" and "source" or "target"
end

-- SharedHealing writes are owned by D.Stats. This module only observes the
-- already-committed Authority value while maintaining ActorId/TargetRef deltas.

local function CheckToken(...)
    local parts = {}
    for index = 1, select("#", ...) do
        local text = tostring(select(index, ...) or "")
        parts[index] = tostring(#text) .. ":" .. text
    end
    return table.concat(parts, "|")
end

local function AdoptAuthorityRoot(root)
    if V.authorityRoot == root then return end
    -- Full replay uses a working stats root and commits it later. Audit deltas
    -- are meaningful only inside one Authority root, so a root switch starts a
    -- fresh consistency generation instead of comparing unrelated baselines.
    V.authorityRoot = root
    V.actorIdCache = setmetatable({}, { __mode = "k" })
    V.targetRefCache = setmetatable({}, { __mode = "k" })
    V.metricRowCache = setmetatable({}, { __mode = "k" })
    V.checksByToken = {}
    V.checkEntries = {}
    V.mismatchCount = 0
    V.lastMismatch = nil
end

local function TrackDelta(token, template, legacyValue, v3Value, amount)
    local entry = V.checksByToken[token]
    if entry == nil then
        entry = template
        entry.token = token
        entry.legacyBaseline = (tonumber(legacyValue) or 0) - amount
        entry.v3Baseline = (tonumber(v3Value) or 0) - amount
        entry.delta = 0
        V.checksByToken[token] = entry
        V.checkEntries[#V.checkEntries + 1] = entry
    end
    entry.delta = (tonumber(entry.delta) or 0) + amount
    local expectedLegacy = (tonumber(entry.legacyBaseline) or 0) + entry.delta
    local expectedV3 = (tonumber(entry.v3Baseline) or 0) + entry.delta
    if tonumber(legacyValue) ~= expectedLegacy or tonumber(v3Value) ~= expectedV3 then
        V.mismatchCount = V.mismatchCount + 1
        V.lastMismatch = {
            token = token,
            legacy = legacyValue,
            expectedLegacy = expectedLegacy,
            v3 = v3Value,
            expectedV3 = expectedV3,
        }
        Counter("statsV3Mismatches", 1)
    end
end

function V:DisableAfterFailure(err, root)
    self.failed = true
    self.failure = tostring(err or "unknown Stats v3 failure")
    if type(root) == "table" and type(root.identityProjection) == "table" then
        root.identityProjection.projectionState = "DEGRADED"
        root.identityProjection.needsRebuild = true
    end
    Counter("statsV3Failures", 1)
    if D.Diagnostics ~= nil and type(D.Diagnostics.AddWarning) == "function" then
        D.Diagnostics:AddWarning("stats_v3", "Stats v3 投影已停用：" .. self.failure)
    end
end

local function ApplyIdentityProjectionMetric(projection, mode, sideName, entity, metric, amount, event)
    if type(projection) ~= "table" then return nil, "INVALID_PROJECTION" end
    if not VALID_MODES[mode] or not VALID_SIDES[sideName] or not VALID_METRICS[metric] then
        return nil, "INVALID_SELECTOR"
    end
    if type(entity) ~= "table" then return nil, "MISSING_ENTITY" end
    amount = tonumber(amount) or 0
    if amount == 0 then return true end
    local actorId = InternActor(projection, entity)
    local targetRefId = InternTargetRef(projection, event, CounterpartRole(metric))
    local row = EnsureMetricProjection(projection, mode, sideName, actorId, metric, entity)
    row.amount = row.amount + amount
    row.abilities = select(1, AddBounded(row.abilities, AbilityKey(metric, event), amount))
    row.counterparts = select(1, AddBounded(row.counterparts, tostring(targetRefId), amount))
    projection.projectionState = "READY"
    projection.needsRebuild = false
    return true, actorId, targetRefId, row
end

-- Bounded full-rebuild adapter used by the read-only local commit envelope.
-- It deliberately accepts an isolated projection object and never adopts or
-- mutates D.State.stats, audit cursors, SharedHealing, ranking or persistence.
function V:CreateIdentityProjectionRebuild()
    local holder = { identityProjection = {} }
    local projection = EnsureProjection(holder)
    projection.projectionState = "READY"
    projection.needsRebuild = false
    return projection
end

function V:ApplyIdentityProjectionRebuildMetric(projection, mode, sideName, entity,
        metric, amount, event)
    return ApplyIdentityProjectionMetric(projection, mode, sideName, entity,
        metric, amount, event)
end

function V:OnLegacyMetricApplied(mode, sideName, entity, metric, amount, event, legacyActor, legacySide, root)
    if self.failed == true then return end
    if not VALID_MODES[mode] or not VALID_SIDES[sideName] or not VALID_METRICS[metric] then return end
    if type(root) ~= "table" or tonumber(root.schemaVersion) ~= 3 then error("invalid Stats v3 root") end
    if type(entity) ~= "table" or type(legacyActor) ~= "table" or type(legacySide) ~= "table" then return end
    amount = tonumber(amount) or 0
    if amount == 0 then return end

    AdoptAuthorityRoot(root)
    local projection = EnsureProjection(root)
    local applied, actorId, targetRefId, row = ApplyIdentityProjectionMetric(
        projection, mode, sideName, entity, metric, amount, event)
    if applied ~= true then error("identity projection write failed: " .. tostring(actorId)) end

    -- Per-path counters/auditing are diagnostic presentation only. The formal
    -- ActorId/TargetRef projection above remains live in every mode.
    local auditEnabled = D.State ~= nil and D.State.config ~= nil
        and D.State.config.diagnosticsEnabled == true
    if auditEnabled then
        self.metricWrites = self.metricWrites + 1
        Counter("statsV3MetricWrites", 1)
    end

    -- Per-path delta auditing creates tokens and audit entries. It is valuable
    -- for diagnostics and tests but is not part of the product totals. Keep the
    -- ActorId/TargetRef projection live, while removing audit bookkeeping from
    -- the normal combat hot path.
    local actorKey = tostring(entity.key or "")
    if auditEnabled then
        TrackDelta(CheckToken("ACTOR", mode, sideName, actorKey, metric), {
            kind = "ACTOR", mode = mode, side = sideName, actorKey = actorKey,
            actorId = actorId, metric = metric,
        }, legacyActor[metric], row.amount, amount)
    end

    if metric == "heal" and auditEnabled then
        local shared = root.sharedHealing
        local sharedSide = type(shared) == "table" and shared[sideName] or nil
        local sharedActor = type(sharedSide) == "table" and type(sharedSide.actors) == "table"
            and sharedSide.actors[actorKey] or nil
        if type(sharedSide) ~= "table" or type(sharedActor) ~= "table" then
            error("SharedHealing Authority write missing before StatsV3 observation")
        end
        self.sharedHealingWrites = self.sharedHealingWrites + 1
        Counter("statsV3SharedHealingObservations", 1)
        local legacyCombined = 0
        for _, legacyMode in ipairs({ "PVP", "PVE" }) do
            local modeRoot = root[legacyMode]
            local sideRoot = type(modeRoot) == "table" and modeRoot[sideName] or nil
            local oldActor = type(sideRoot) == "table" and type(sideRoot.actors) == "table"
                and sideRoot.actors[actorKey] or nil
            legacyCombined = legacyCombined + (tonumber(oldActor and oldActor.heal) or 0)
        end
        TrackDelta(CheckToken("SHARED_HEAL", sideName, actorKey), {
            kind = "SHARED_HEAL", side = sideName, actorKey = actorKey,
        }, legacyCombined, sharedActor.heal, amount)
        local legacySideCombined = 0
        for _, legacyMode in ipairs({ "PVP", "PVE" }) do
            local modeRoot = root[legacyMode]
            local sideRoot = type(modeRoot) == "table" and modeRoot[sideName] or nil
            legacySideCombined = legacySideCombined
                + (tonumber(sideRoot and sideRoot.totals and sideRoot.totals.heal) or 0)
        end
        TrackDelta(CheckToken("SHARED_SIDE", sideName), {
            kind = "SHARED_SIDE", side = sideName,
        }, legacySideCombined, sharedSide.totals.heal, amount)
    end
end

function V:OnLegacyActorKeyMerged(oldKey, newKey, displayName, root)
    if type(root) ~= "table" or tonumber(root.schemaVersion) ~= 3 then return end
    AdoptAuthorityRoot(root)
    -- Legacy key movement is a structural transaction. Runtime delta baselines
    -- are invalid after the move, so discard only the audit cursors; persisted
    -- v3 projection data remains intact and future writes establish new checks.
    self.checksByToken = {}
    self.checkEntries = {}
    self.mismatchCount = 0
    self.metricRowCache = setmetatable({}, { __mode = "k" })
    -- SharedHealing key movement is part of the core Stats transaction. The
    -- optional identity observer only invalidates its own delta/audit cursors.
    local projection = EnsureProjection(root)
    projection.structureRevision = (tonumber(projection.structureRevision) or 0) + 1
end

-- Read-only adapter for v2 name-keyed history. This is intentionally an
-- on-demand diagnostic/migration view: it does not intern formal ActorIds,
-- persist guessed identity, or run from the combat callback.
function V:GetLegacyBreakdownAdapter(mode, sideName, actorKey, metric, root)
    root = root or D.State.stats
    if not VALID_MODES[mode] or not VALID_SIDES[sideName] or not VALID_METRICS[metric] then
        return nil, "invalid_breakdown_selector"
    end
    if type(root) ~= "table" or tonumber(root.schemaVersion) ~= 3 then
        return nil, "invalid_stats_root"
    end
    actorKey = tostring(actorKey or "")
    if actorKey == "" then return nil, "missing_actor_key" end
    local modeRoot = root[mode]
    local side = type(modeRoot) == "table" and modeRoot[sideName] or nil
    local actor = type(side) == "table" and type(side.actors) == "table"
        and side.actors[actorKey] or nil
    if type(actor) ~= "table" then return nil, "actor_not_found" end

    local details = type(actor.details) == "table" and actor.details or {}
    local metricDetails = type(details[metric]) == "table" and details[metric] or {}
    local abilities = {}
    for key, value in pairs(type(metricDetails.abilities) == "table" and metricDetails.abilities or {}) do
        local amount = tonumber(value) or 0
        if amount ~= 0 then abilities[tostring(key)] = amount end
    end
    local counterpartMap = metric == "taken" and metricDetails.sources or metricDetails.targets
    local counterparts = {}
    for displayName, value in pairs(type(counterpartMap) == "table" and counterpartMap or {}) do
        local amount = tonumber(value) or 0
        if amount ~= 0 then
            local safeDisplayName = SafeName(displayName, "未知")
            local normalizedName = NormalizeName(safeDisplayName)
            counterparts[#counterparts + 1] = {
                kind = "LEGACY_NAME_HISTORY",
                identityToken = "legacy-name:" .. normalizedName,
                displayName = safeDisplayName,
                normalizedName = normalizedName,
                amount = amount,
            }
        end
    end
    table.sort(counterparts, function(left, right)
        if left.identityToken ~= right.identityToken then return left.identityToken < right.identityToken end
        return left.displayName < right.displayName
    end)
    return {
        schemaVersion = 1,
        source = "STATS_V2_COMPATIBILITY",
        readOnly = true,
        actorRef = {
            kind = "LEGACY_ACTOR_KEY",
            identityToken = "legacy-actor:" .. actorKey,
            canonicalKey = actorKey,
            displayName = SafeName(actor.name, "未知"),
            resolutionQuality = "LEGACY_KEY",
        },
        mode = mode,
        side = sideName,
        metric = metric,
        amount = tonumber(actor[metric]) or 0,
        abilities = abilities,
        counterparts = counterparts,
    }
end

local function ReadLegacyForEntry(root, entry)
    if entry.kind == "ACTOR" then
        local mode = root[entry.mode]
        local side = type(mode) == "table" and mode[entry.side] or nil
        local actor = type(side) == "table" and type(side.actors) == "table"
            and side.actors[entry.actorKey] or nil
        return tonumber(actor and actor[entry.metric]) or 0
    end
    if entry.kind == "SHARED_HEAL" then
        local total = 0
        for _, modeName in ipairs({ "PVP", "PVE" }) do
            local side = root[modeName] and root[modeName][entry.side] or nil
            local actor = type(side) == "table" and type(side.actors) == "table"
                and side.actors[entry.actorKey] or nil
            total = total + (tonumber(actor and actor.heal) or 0)
        end
        return total
    end
    if entry.kind == "SHARED_SIDE" then
        local total = 0
        for _, modeName in ipairs({ "PVP", "PVE" }) do
            local side = root[modeName] and root[modeName][entry.side] or nil
            total = total + (tonumber(side and side.totals and side.totals.heal) or 0)
        end
        return total
    end
    return nil
end

local function ReadV3ForEntry(root, entry)
    if entry.kind == "ACTOR" then
        local projection = EnsureProjection(root)
        local side = projection.breakdowns[entry.mode][entry.side]
        local actor = side.actors[tostring(entry.actorId)]
        local row = actor and actor.metrics and actor.metrics[entry.metric] or nil
        return tonumber(row and row.amount) or 0
    end
    local shared = root.sharedHealing
    local side = type(shared) == "table" and shared[entry.side] or nil
    if entry.kind == "SHARED_HEAL" then
        local actor = type(side) == "table" and type(side.actors) == "table"
            and side.actors[entry.actorKey] or nil
        return tonumber(actor and actor.heal) or 0
    end
    if entry.kind == "SHARED_SIDE" then
        return tonumber(side and side.totals and side.totals.heal) or 0
    end
    return nil
end

function V:BeginConsistencyAudit(root)
    root = root or D.State.stats
    AdoptAuthorityRoot(root)
    return {
        root = root,
        cursor = 1,
        checked = 0,
        mismatches = 0,
        done = false,
    }
end

function V:StepConsistencyAudit(job, budget)
    if type(job) ~= "table" or job.done == true then return true end
    if job.root ~= D.State.stats and job.root ~= Stats.replayWorkingStats then
        job.done = true
        job.aborted = "authority_root_changed"
        return true
    end
    local remaining = math.max(1, math.floor(tonumber(budget) or 64))
    while remaining > 0 and job.cursor <= #self.checkEntries do
        local entry = self.checkEntries[job.cursor]
        local legacy = ReadLegacyForEntry(job.root, entry)
        local v3 = ReadV3ForEntry(job.root, entry)
        local expectedLegacy = (tonumber(entry.legacyBaseline) or 0) + (tonumber(entry.delta) or 0)
        local expectedV3 = (tonumber(entry.v3Baseline) or 0) + (tonumber(entry.delta) or 0)
        if legacy ~= expectedLegacy or v3 ~= expectedV3 then
            job.mismatches = job.mismatches + 1
            self.mismatchCount = self.mismatchCount + 1
            Counter("statsV3Mismatches", 1)
        end
        job.checked = job.checked + 1
        self.auditChecks = self.auditChecks + 1
        Counter("statsV3AuditChecks", 1)
        job.cursor = job.cursor + 1
        remaining = remaining - 1
    end
    if job.cursor > #self.checkEntries then job.done = true end
    return job.done == true
end

function V:AuditAllForTests(batchSize)
    local job = self:BeginConsistencyAudit(D.State.stats)
    local guard = 0
    while job.done ~= true and guard < 100000 do
        self:StepConsistencyAudit(job, batchSize or 64)
        guard = guard + 1
    end
    return job
end

function V:OnAuthorityRootReplaced(root, reason)
    AdoptAuthorityRoot(root)
    EnsureProjection(root)
    self.lastAuthorityResetReason = tostring(reason or "ROOT_REPLACED")
end

function V:GetStatusLine()
    local projection = type(D.State.stats) == "table" and D.State.stats.identityProjection or nil
    local shared = type(D.State.stats) == "table" and D.State.stats.sharedHealing or nil
    local status = self.failed == true and "失败" or "运行"
    return "Stats v3：" .. status
        .. "；ActorId=" .. tostring(type(projection) == "table" and projection.nextActorId or 0)
        .. "；TargetRef=" .. tostring(type(projection) == "table" and projection.nextTargetRefId or 0)
        .. "；共享治疗=" .. tostring(type(shared) == "table" and "独立" or "缺失")
        .. "；写入=" .. tostring(self.metricWrites)
        .. "；不一致=" .. tostring(self.mismatchCount)
end

function V:FlushDiagnostics(diagnostics)
    if type(diagnostics) ~= "table" or type(diagnostics.AddInfo) ~= "function" then return end
    if self.diagnosticsFlushedGeneration == Boot.generation then return end
    self.diagnosticsFlushedGeneration = Boot.generation
    diagnostics:AddInfo("stats_v3", self:GetStatusLine())
end

local counters = D.Diagnostics and D.Diagnostics.counters or nil
if type(counters) == "table" then
    counters.statsV3MetricWrites = tonumber(counters.statsV3MetricWrites) or 0
    counters.statsV3SharedHealingObservations = tonumber(counters.statsV3SharedHealingObservations) or 0
    counters.statsV3ActorInterns = tonumber(counters.statsV3ActorInterns) or 0
    counters.statsV3TargetRefInterns = tonumber(counters.statsV3TargetRefInterns) or 0
    counters.statsV3Mismatches = tonumber(counters.statsV3Mismatches) or 0
    counters.statsV3Failures = tonumber(counters.statsV3Failures) or 0
    counters.statsV3AuditChecks = tonumber(counters.statsV3AuditChecks) or 0
end

EnsureProjection(D.State.stats)
Stats:SetStatsV3Observer(V)
V:FlushDiagnostics(D.Diagnostics)
Boot:CompletePhase("STATS_V3_READY")
if D.Diagnostics ~= nil then D.Diagnostics.status = "STATS_V3_READY" end

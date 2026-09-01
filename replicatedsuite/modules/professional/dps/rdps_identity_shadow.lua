ReplicatedSuiteModuleSandbox:Enter('dps', {'ReplicatedDps', 'ReplicatedDpsConfig'})
------------------------------------------------------------------------
-- Replicated DPS - ActorId / TargetRef diagnostic shadow projection
-- Author: Replicated
--
-- Authority boundary
--   * D.State.stats and D.Entities remain the only production authorities.
--   * This module receives notifications only after a legacy metric write has
--     completed successfully.
--   * These diagnostic ActorId / TargetRef values remain runtime-only. The
--     persisted Stats v3 IDs are owned separately by D.StatsV3.
--   * A shadow failure disables only this diagnostic observer; it must never
--     roll back or interrupt the authoritative combat statistic.
--
-- Performance boundary
--   * The shadow is active only while diagnosticsEnabled is true.
--   * Normal combat performs no shadow allocation and no protected callback.
--   * Consistency scans are explicit bounded jobs; no full scan is run in Tick.
------------------------------------------------------------------------

if ReplicatedDps == nil or ReplicatedDps.Boot == nil then return end

local D = ReplicatedDps
local Boot = D.Boot
if Boot.phase == "FAILED" then return end
if type(D.ActorRegistry) ~= "table" or type(D.ActorRegistry.GetActorId) ~= "function" then
    Boot:Fail("identity_shadow:actor_registry", "D.ActorRegistry is unavailable")
    return
end
if type(D.StatsV3) ~= "table" then
    Boot:Fail("identity_shadow:stats_v3", "rdps_stats_v3.lua is unavailable")
    return
end
if type(D.Stats) ~= "table" or type(D.Stats.SetIdentityShadowObserver) ~= "function" then
    Boot:Fail("identity_shadow:stats", "D.Stats observer boundary is unavailable")
    return
end

Boot:SetPhase("IDENTITY_SHADOW_LOADING")

local U = D.Util
local Actors = D.ActorRegistry
local Stats = D.Stats

D.IdentityShadow = D.IdentityShadow or {}
local H = D.IdentityShadow

H.schemaVersion = 1
local currentGeneration = tonumber(Boot.generation) or 0

local METRICS = { damage = true, taken = true, heal = true, kills = true }
local MODES = { PVP = true, PVE = true }
local SIDES = { friendly = true, enemy = true }

local function Counter(name, amount)
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

local function NewSideProjection()
    return {
        totals = { damage = 0, taken = 0, heal = 0, kills = 0 },
        actors = {},
    }
end

local function NewProjection()
    return {
        PVP = { friendly = NewSideProjection(), enemy = NewSideProjection() },
        PVE = { friendly = NewSideProjection(), enemy = NewSideProjection() },
    }
end

local function NewActorProjection(actorId, entity)
    return {
        actorId = actorId,
        canonicalKey = type(entity) == "table" and entity.key or nil,
        displayName = type(entity) == "table" and entity.name or "未知",
        legacyKeys = {},
        damage = 0,
        taken = 0,
        heal = 0,
        kills = 0,
        abilities = {
            damage = {}, taken = {}, heal = {}, kills = {},
        },
        counterpartRefs = {
            damage = {}, taken = {}, heal = {}, kills = {},
        },
        legacyCounterpartNames = {
            damage = {}, taken = {}, heal = {}, kills = {},
        },
    }
end

local function FreshRuntimeState(reason)
    H.generation = currentGeneration
    H.enabled = false
    H.failed = false
    H.failure = nil
    H.resetReason = tostring(reason or "generation")
    H.authorityRoot = nil
    H.projection = NewProjection()
    H.targetRefsById = {}
    H.actorIdToTargetRefId = {}
    H.nameTokenToTargetRefId = {}
    H.refAliases = {}
    H.nextTargetRefId = 0
    H.nextNameHistoryId = 0
    H.checksByToken = {}
    H.checkEntries = {}
    H.metricWrites = 0
    H.mismatchCount = 0
    H.auditChecks = 0
    H.lastMismatch = nil
    H.mismatchSamples = {}
    H.lastActorMergeCount = tonumber(Actors.actorIdMergeCount) or 0
    H.authorityStructureRevision = nil
end

if tonumber(H.generation) ~= currentGeneration then
    FreshRuntimeState("boot_generation")
else
    -- A complete module reload must not keep references to an obsolete Stats
    -- tree or callbacks, even when the bootstrap generation was not advanced by
    -- a development harness.
    FreshRuntimeState("module_reload")
end
H.diagnosticsFlushedGeneration = tonumber(H.diagnosticsFlushedGeneration) or 0

local function IdentityQuality(entity)
    if type(Actors.GetIdentityQuality) == "function" then
        return Actors:GetIdentityQuality(entity)
    end
    if type(entity) ~= "table" then return "MISSING" end
    local key = tostring(entity.key or "")
    if entity.flags ~= nil and entity.flags.historicalNameAggregate == true then return "HISTORICAL_NAME" end
    if string.sub(key, 1, 3) == "id:" and entity.stringId ~= nil then return "STABLE_ID" end
    if string.sub(key, 1, 9) == "teamname:" then return "TEAM_NAME" end
    if string.sub(key, 1, 8) == "history:" then return "HISTORICAL_NAME" end
    if string.sub(key, 1, 5) == "name:" then return "NAME_ONLY" end
    if string.sub(key, 1, 10) == "ambiguous:" then return "AMBIGUOUS_NAME" end
    return "UNKNOWN_KEY"
end

local function IsStableActorIdentity(entity)
    if type(entity) ~= "table" then return false end
    local stableId = type(Actors.GetStableId) == "function" and Actors:GetStableId(entity) or entity.stringId
    if stableId == nil or tostring(stableId) == "" then return false end
    if entity.flags ~= nil and entity.flags.historicalNameAggregate == true then return false end
    return string.sub(tostring(entity.key or ""), 1, 3) == "id:"
end

function H:Reset(reason)
    local oldMismatchCount = tonumber(self.mismatchCount) or 0
    FreshRuntimeState(reason or "manual")
    self.mismatchCount = 0
    if oldMismatchCount > 0 then
        Counter("identityShadowResetsAfterMismatch", 1)
    end
end

function H:OnAuthorityRootReplaced(root)
    self:Reset("formal_persisted_root_replaced")
    self.authorityRoot = root
    self.authorityStructureRevision = tonumber(Stats.rankingStructureRevision) or 0
    self.enabled = D.State ~= nil and D.State.config ~= nil
        and D.State.config.diagnosticsEnabled == true
end

function H:OnDiagnosticsChanged(enabled)
    if enabled == true then
        self:Reset("diagnostics_enabled")
        self.enabled = true
    else
        self:Reset("diagnostics_disabled")
    end
end

function H:DisableAfterFailure(err)
    self.failed = true
    self.enabled = false
    self.failure = tostring(err or "unknown shadow failure")
    Counter("identityShadowFailures", 1)
    if D.Diagnostics ~= nil and type(D.Diagnostics.AddWarning) == "function" then
        D.Diagnostics:AddWarning("identity_shadow", "影子校验已停用：" .. self.failure)
    end
end

local function EnsureAuthorityRoot(self, root)
    if type(root) ~= "table" then return false end
    local structureRevision = tonumber(Stats.rankingStructureRevision) or 0
    if self.authorityRoot ~= root or (self.authorityStructureRevision ~= nil
        and tonumber(self.authorityStructureRevision) ~= structureRevision) then
        local reason
        if self.authorityRoot == nil then reason = "authority_attach"
        elseif self.authorityRoot ~= root then reason = "authority_root_changed"
        else reason = "authority_structure_changed" end
        FreshRuntimeState(reason)
        self.authorityRoot = root
        self.authorityStructureRevision = structureRevision
        self.enabled = true
    elseif self.authorityStructureRevision == nil then
        self.authorityStructureRevision = structureRevision
    end
    return true
end

local function ResolveRefAlias(self, refId)
    local current = tonumber(refId)
    if current == nil then return nil end
    current = math.floor(current)
    if current <= 0 then return nil end
    local visited = nil
    for _ = 1, 16 do
        local nextId = tonumber(self.refAliases[current])
        if nextId == nil or nextId == current then return current end
        visited = visited or {}
        if visited[current] == true then return current end
        visited[current] = true
        current = math.floor(nextId)
    end
    return current
end

function H:ResolveTargetRefId(refId)
    local resolvedRefId = ResolveRefAlias(self, refId)
    if resolvedRefId == nil then return nil end
    local ref = self.targetRefsById[resolvedRefId]
    if type(ref) ~= "table" or ref.kind ~= "ACTOR" then return resolvedRefId end

    local currentActorId = Actors:ResolveActorId(ref.actorId)
    if currentActorId == nil or currentActorId == ref.actorId then return resolvedRefId end
    local winnerRefId = self.actorIdToTargetRefId[currentActorId]
    if winnerRefId == nil then
        self.nextTargetRefId = self.nextTargetRefId + 1
        winnerRefId = self.nextTargetRefId
        self.actorIdToTargetRefId[currentActorId] = winnerRefId
        self.targetRefsById[winnerRefId] = {
            refId = winnerRefId,
            kind = "ACTOR",
            actorId = currentActorId,
            displayName = ref.displayName,
            normalizedName = ref.normalizedName,
            canonicalKey = ref.canonicalKey,
            resolutionQuality = "STABLE_ACTOR",
        }
        Counter("identityShadowTargetRefs", 1)
    end
    self.refAliases[resolvedRefId] = winnerRefId
    return winnerRefId
end

local function InternActorTargetRef(self, entity, displayName)
    local actorId = Actors:GetActorId(entity)
    actorId = Actors:ResolveActorId(actorId)
    if actorId == nil then return nil end
    local refId = self.actorIdToTargetRefId[actorId]
    if refId == nil then
        self.nextTargetRefId = self.nextTargetRefId + 1
        refId = self.nextTargetRefId
        self.actorIdToTargetRefId[actorId] = refId
        self.targetRefsById[refId] = {
            refId = refId,
            kind = "ACTOR",
            actorId = actorId,
            displayName = SafeName(displayName or entity.name, "未知"),
            normalizedName = NormalizeName(displayName or entity.name),
            canonicalKey = entity.key,
            resolutionQuality = "STABLE_ACTOR",
        }
        Counter("identityShadowTargetRefs", 1)
    else
        refId = self:ResolveTargetRefId(refId)
        local ref = self.targetRefsById[refId]
        if type(ref) == "table" then
            ref.displayName = SafeName(displayName or entity.name, ref.displayName or "未知")
            ref.normalizedName = NormalizeName(ref.displayName)
            ref.canonicalKey = entity.key or ref.canonicalKey
        end
    end
    return refId
end

local function InternNameTargetRef(self, entity, displayName, quality)
    local normalizedName = NormalizeName(displayName or (entity and entity.name))
    if normalizedName == "" then normalizedName = "unknown" end
    local identityKey = type(entity) == "table" and tostring(entity.key or "") or ""
    if identityKey == "" then identityKey = "history:" .. normalizedName end
    local token = tostring(quality or "NAME_ONLY") .. "|" .. identityKey
    local refId = self.nameTokenToTargetRefId[token]
    if refId == nil then
        self.nextNameHistoryId = self.nextNameHistoryId + 1
        self.nextTargetRefId = self.nextTargetRefId + 1
        refId = self.nextTargetRefId
        self.nameTokenToTargetRefId[token] = refId
        self.targetRefsById[refId] = {
            refId = refId,
            kind = "NAME_HISTORY",
            nameHistoryId = self.nextNameHistoryId,
            displayName = SafeName(displayName or (entity and entity.name), "未知"),
            normalizedName = normalizedName,
            canonicalKey = identityKey,
            resolutionQuality = tostring(quality or "NAME_ONLY"),
        }
        Counter("identityShadowTargetRefs", 1)
    end
    return refId
end

function H:GetOrCreateTargetRef(event, role)
    role = role == "source" and "source" or "target"
    event = type(event) == "table" and event or {}
    local key = event[role .. "ResolvedKey"] or event[role .. "Key"]
    local displayName = event[role .. "Name"]
    local entity = key ~= nil and Actors:GetEntityByKey(key) or nil
    if entity ~= nil and IsStableActorIdentity(entity) then
        return InternActorTargetRef(self, entity, displayName)
    end
    return InternNameTargetRef(self, entity, displayName, IdentityQuality(entity))
end

function H:GetTargetRefSnapshot(refId)
    local resolved = self:ResolveTargetRefId(refId)
    local ref = resolved ~= nil and self.targetRefsById[resolved] or nil
    if type(ref) ~= "table" then return nil end
    return {
        refId = resolved,
        kind = ref.kind,
        actorId = ref.actorId and Actors:ResolveActorId(ref.actorId) or nil,
        nameHistoryId = ref.nameHistoryId,
        displayName = ref.displayName,
        normalizedName = ref.normalizedName,
        canonicalKey = ref.canonicalKey,
        resolutionQuality = ref.resolutionQuality,
    }
end

local function LegacyAbilityKey(metric, event)
    event = type(event) == "table" and event or {}
    if metric == "kills" then
        local value = tostring(event.abilityName or "")
        return value ~= "" and value or "未知技能"
    end
    local value = tostring(event.abilityName or "")
    return value ~= "" and value or "未知"
end

local function LegacyCounterpartSpec(metric, event)
    event = type(event) == "table" and event or {}
    if metric == "taken" then
        local value = tostring(event.sourceName or "")
        return "sources", value ~= "" and value or "未知", "source"
    end
    local value = tostring(event.targetName or "")
    if metric == "kills" and value == "" then value = "未知目标" end
    if value == "" then value = "未知" end
    return "targets", value, "target"
end

local function ReadLegacyEntry(self, entry)
    local root = self.authorityRoot
    if type(root) ~= "table" then return nil end
    local mode = root[entry.mode]
    local side = type(mode) == "table" and mode[entry.side] or nil
    if type(side) ~= "table" then return nil end
    if entry.kind == "SIDE" then
        return tonumber(side.totals and side.totals[entry.metric]) or 0
    end
    local actor = type(side.actors) == "table" and side.actors[entry.actorKey] or nil
    if type(actor) ~= "table" then return 0 end
    if entry.kind == "ACTOR" then return tonumber(actor[entry.metric]) or 0 end
    local metricDetails = actor.details and actor.details[entry.metric] or nil
    if type(metricDetails) ~= "table" then return 0 end
    if entry.kind == "ABILITY" then
        return tonumber(metricDetails.abilities and metricDetails.abilities[entry.detailKey]) or 0
    end
    if entry.kind == "COUNTERPART" then
        local map = metricDetails[entry.mapName]
        return tonumber(type(map) == "table" and map[entry.detailKey]) or 0
    end
    return nil
end

local function RecordMismatch(self, entry, actual, expected)
    self.mismatchCount = (tonumber(self.mismatchCount) or 0) + 1
    Counter("identityShadowMismatches", 1)
    local mismatch = {
        kind = entry.kind,
        mode = entry.mode,
        side = entry.side,
        actorKey = entry.actorKey,
        metric = entry.metric,
        detailKey = entry.detailKey,
        actual = tonumber(actual) or 0,
        expected = tonumber(expected) or 0,
        writeSequence = self.metricWrites,
    }
    self.lastMismatch = mismatch
    if #self.mismatchSamples < 16 then self.mismatchSamples[#self.mismatchSamples + 1] = mismatch end
    if self.mismatchCount <= 4 and D.Diagnostics ~= nil and type(D.Diagnostics.AddWarning) == "function" then
        D.Diagnostics:AddWarning(
            "identity_shadow",
            tostring(entry.kind) .. " 不一致：" .. tostring(entry.mode) .. "/"
                .. tostring(entry.side) .. "/" .. tostring(entry.actorKey or "-")
                .. "/" .. tostring(entry.metric)
        )
    end
end

local function CheckToken(...)
    local parts = {}
    for index = 1, select("#", ...) do
        local text = tostring(select(index, ...) or "")
        parts[index] = tostring(#text) .. ":" .. text
    end
    return table.concat(parts, "|")
end

local function TrackLegacyDelta(self, token, entryTemplate, legacyValue, amount)
    local entry = self.checksByToken[token]
    if entry == nil then
        entry = entryTemplate
        entry.token = token
        entry.baseline = (tonumber(legacyValue) or 0) - amount
        entry.delta = 0
        self.checksByToken[token] = entry
        self.checkEntries[#self.checkEntries + 1] = entry
    end
    entry.delta = (tonumber(entry.delta) or 0) + amount
    local expected = (tonumber(entry.baseline) or 0) + entry.delta
    local actual = tonumber(legacyValue) or 0
    if actual ~= expected then RecordMismatch(self, entry, actual, expected) end
end

local function GetProjectionActor(self, mode, sideName, actorId, entity)
    local side = self.projection[mode][sideName]
    actorId = Actors:ResolveActorId(actorId)
    local actor = side.actors[actorId]
    if actor == nil then
        actor = NewActorProjection(actorId, entity)
        side.actors[actorId] = actor
    end
    actor.canonicalKey = type(entity) == "table" and entity.key or actor.canonicalKey
    actor.displayName = type(entity) == "table" and entity.name or actor.displayName
    if type(entity) == "table" and entity.key ~= nil then actor.legacyKeys[tostring(entity.key)] = true end
    return side, actor
end

function H:OnLegacyMetricApplied(mode, sideName, entity, metric, amount, event, legacyActor, legacySide, authorityRoot)
    if self.failed == true then return end
    if D.State == nil or D.State.config == nil or D.State.config.diagnosticsEnabled ~= true then
        if self.enabled == true then self:Reset("diagnostics_inactive") end
        return
    end
    if not MODES[mode] or not SIDES[sideName] or not METRICS[metric] then return end
    if type(entity) ~= "table" or type(legacyActor) ~= "table" or type(legacySide) ~= "table" then return end
    amount = tonumber(amount) or 0
    if amount == 0 then return end
    if not EnsureAuthorityRoot(self, authorityRoot) then return end

    self.enabled = true
    self.metricWrites = self.metricWrites + 1
    Counter("identityShadowMetricWrites", 1)

    local actorId = Actors:GetActorId(entity)
    actorId = Actors:ResolveActorId(actorId)
    if actorId == nil then error("owner ActorId unavailable") end

    local sideProjection, actorProjection = GetProjectionActor(self, mode, sideName, actorId, entity)
    sideProjection.totals[metric] = (tonumber(sideProjection.totals[metric]) or 0) + amount
    actorProjection[metric] = (tonumber(actorProjection[metric]) or 0) + amount

    local abilityKey = LegacyAbilityKey(metric, event)
    local mapName, counterpartName, counterpartRole = LegacyCounterpartSpec(metric, event)
    actorProjection.abilities[metric][abilityKey] =
        (tonumber(actorProjection.abilities[metric][abilityKey]) or 0) + amount
    actorProjection.legacyCounterpartNames[metric][counterpartName] =
        (tonumber(actorProjection.legacyCounterpartNames[metric][counterpartName]) or 0) + amount

    local targetRefId = self:GetOrCreateTargetRef(event, counterpartRole)
    targetRefId = self:ResolveTargetRefId(targetRefId)
    if targetRefId == nil then error("TargetRef unavailable") end
    actorProjection.counterpartRefs[metric][targetRefId] =
        (tonumber(actorProjection.counterpartRefs[metric][targetRefId]) or 0) + amount

    local actorKey = tostring(entity.key or "unknown")
    local legacyDetails = legacyActor.details and legacyActor.details[metric] or nil
    local legacyAbilityValue = tonumber(legacyDetails and legacyDetails.abilities
        and legacyDetails.abilities[abilityKey]) or 0
    local counterpartMap = legacyDetails and legacyDetails[mapName] or nil
    local legacyCounterpartValue = tonumber(type(counterpartMap) == "table"
        and counterpartMap[counterpartName]) or 0

    TrackLegacyDelta(self, CheckToken("S", mode, sideName, metric), {
        kind = "SIDE", mode = mode, side = sideName, metric = metric,
    }, legacySide.totals and legacySide.totals[metric] or 0, amount)
    TrackLegacyDelta(self, CheckToken("A", mode, sideName, actorKey, metric), {
        kind = "ACTOR", mode = mode, side = sideName, actorKey = actorKey, metric = metric,
    }, legacyActor[metric], amount)
    TrackLegacyDelta(self, CheckToken("B", mode, sideName, actorKey, metric, abilityKey), {
        kind = "ABILITY", mode = mode, side = sideName, actorKey = actorKey,
        metric = metric, detailKey = abilityKey,
    }, legacyAbilityValue, amount)
    TrackLegacyDelta(self, CheckToken("C", mode, sideName, actorKey, metric, mapName, counterpartName), {
        kind = "COUNTERPART", mode = mode, side = sideName, actorKey = actorKey,
        metric = metric, mapName = mapName, detailKey = counterpartName,
    }, legacyCounterpartValue, amount)
end

function H:BeginConsistencyAudit()
    return {
        cursor = 1,
        checked = 0,
        mismatches = 0,
        done = false,
        authorityRoot = self.authorityRoot,
    }
end

function H:StepConsistencyAudit(job, budget)
    if type(job) ~= "table" or job.done == true then return true end
    if job.authorityRoot ~= self.authorityRoot then
        job.done = true
        job.aborted = "authority_root_changed"
        return true
    end
    if tonumber(self.authorityStructureRevision) ~= (tonumber(Stats.rankingStructureRevision) or 0) then
        job.done = true
        job.aborted = "authority_structure_changed"
        return true
    end
    local remaining = math.max(1, math.floor(tonumber(budget) or 64))
    while remaining > 0 and job.cursor <= #self.checkEntries do
        local entry = self.checkEntries[job.cursor]
        local actual = ReadLegacyEntry(self, entry)
        local expected = (tonumber(entry.baseline) or 0) + (tonumber(entry.delta) or 0)
        local before = self.mismatchCount
        if actual == nil or tonumber(actual) ~= expected then
            RecordMismatch(self, entry, actual, expected)
        end
        if self.mismatchCount > before then job.mismatches = job.mismatches + 1 end
        job.checked = job.checked + 1
        self.auditChecks = self.auditChecks + 1
        Counter("identityShadowAuditChecks", 1)
        job.cursor = job.cursor + 1
        remaining = remaining - 1
    end
    if job.cursor > #self.checkEntries then job.done = true end
    return job.done == true
end

function H:AuditAllForTests(batchSize)
    local job = self:BeginConsistencyAudit()
    local budget = math.max(1, math.floor(tonumber(batchSize) or 64))
    local guard = 0
    while job.done ~= true and guard < 100000 do
        self:StepConsistencyAudit(job, budget)
        guard = guard + 1
    end
    return job
end

function H:GetActorMetric(mode, sideName, actorId, metric)
    if not MODES[mode] or not SIDES[sideName] or not METRICS[metric] then return 0 end
    actorId = Actors:ResolveActorId(actorId)
    if actorId == nil then return 0 end
    local total = 0
    for storedId, actor in pairs(self.projection[mode][sideName].actors) do
        if Actors:ResolveActorId(storedId) == actorId then
            total = total + (tonumber(actor and actor[metric]) or 0)
        end
    end
    return total
end

function H:GetCounterpartAmount(mode, sideName, actorId, metric, targetRefId)
    if not MODES[mode] or not SIDES[sideName] or not METRICS[metric] then return 0 end
    actorId = Actors:ResolveActorId(actorId)
    targetRefId = self:ResolveTargetRefId(targetRefId)
    if actorId == nil or targetRefId == nil then return 0 end
    local total = 0
    for storedId, actor in pairs(self.projection[mode][sideName].actors) do
        if Actors:ResolveActorId(storedId) == actorId then
            local map = actor and actor.counterpartRefs and actor.counterpartRefs[metric] or nil
            for storedRefId, amount in pairs(type(map) == "table" and map or {}) do
                if self:ResolveTargetRefId(storedRefId) == targetRefId then
                    total = total + (tonumber(amount) or 0)
                end
            end
        end
    end
    return total
end

function H:GetStatusLine()
    local state
    if self.failed == true then state = "失败"
    elseif D.State ~= nil and D.State.config ~= nil and D.State.config.diagnosticsEnabled == true then
        state = self.enabled == true and "运行" or "等待事件"
    else
        state = "待机"
    end
    return "身份影子：" .. state .. " v" .. tostring(self.schemaVersion)
        .. "；写入=" .. tostring(self.metricWrites)
        .. "；TargetRef=" .. tostring(self.nextTargetRefId)
        .. "；校验项=" .. tostring(#self.checkEntries)
        .. "；不一致=" .. tostring(self.mismatchCount)
end

function H:FlushDiagnostics(diagnostics)
    if type(diagnostics) ~= "table" or type(diagnostics.AddInfo) ~= "function" then return end
    if self.diagnosticsFlushedGeneration == Boot.generation then return end
    self.diagnosticsFlushedGeneration = Boot.generation
    diagnostics:AddInfo("identity_shadow", self:GetStatusLine())
end

local counters = D.Diagnostics and D.Diagnostics.counters or nil
if type(counters) == "table" then
    counters.identityShadowMetricWrites = tonumber(counters.identityShadowMetricWrites) or 0
    counters.identityShadowTargetRefs = tonumber(counters.identityShadowTargetRefs) or 0
    counters.identityShadowMismatches = tonumber(counters.identityShadowMismatches) or 0
    counters.identityShadowFailures = tonumber(counters.identityShadowFailures) or 0
    counters.identityShadowAuditChecks = tonumber(counters.identityShadowAuditChecks) or 0
end

Stats:SetIdentityShadowObserver(H)
H:FlushDiagnostics(D.Diagnostics)
Boot:CompletePhase("IDENTITY_SHADOW_READY")
if D.Diagnostics ~= nil then D.Diagnostics.status = "IDENTITY_SHADOW_READY" end

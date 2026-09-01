ReplicatedSuiteModuleSandbox:Enter('dps', {'ReplicatedDps', 'ReplicatedDpsConfig'})
------------------------------------------------------------------------
-- Replicated DPS - production statistics read facade
-- Author: Replicated
--
-- Authority / Proxy boundary
--   * D.State.stats.sharedHealing is the production Authority for every
--     healing ranking, detail and print read.
--   * PVP/PVE healing buckets are compatibility/reference data only. They are
--     never selected as the product result by this module.
--   * D.State.stats.identityProjection owns persisted ActorId/TargetRef delta
--     facts. This facade combines those proven deltas with the full name-keyed
--     SharedHealing history without guessing legacy identity.
--   * This module is read-only. It never changes Stats, Entity, EventStore or
--     persistence state.
--
-- Performance boundary
--   * Ranking reads use direct sharedHealing actor maps and O(1) actor lookup.
--   * Combined Breakdown work is performed only for the selected detail row.
--   * Compatibility audits are explicit bounded jobs. No full scan is run in
--     combat callbacks, Tick or normal UI refresh.
------------------------------------------------------------------------

if ReplicatedDps == nil or ReplicatedDps.Boot == nil then return end

local D = ReplicatedDps
local Boot = D.Boot
if Boot.phase == "FAILED" then return end
if type(D.Stats) ~= "table" then
    Boot:Fail("stats_read:stats", "D.Stats is unavailable")
    return
end
if type(D.StatsV3) ~= "table" then
    Boot:Fail("stats_read:stats_v3", "D.StatsV3 is unavailable")
    return
end
if type(D.ActorRegistry) ~= "table" then
    Boot:Fail("stats_read:actor_registry", "D.ActorRegistry is unavailable")
    return
end

Boot:SetPhase("STATS_READ_LOADING")

local U = D.Util
local Stats = D.Stats
local Actors = D.ActorRegistry

D.StatsRead = D.StatsRead or {}
local R = D.StatsRead
R.schemaVersion = 1
R.productHealingAuthority = "SHARED_HEALING_V1"
R.referenceHealingSource = "PVP_PVE_COMPATIBILITY"
R.auditChecks = tonumber(R.auditChecks) or 0
R.auditMismatches = tonumber(R.auditMismatches) or 0
R.combinedBreakdownReads = tonumber(R.combinedBreakdownReads) or 0
R.lastMismatch = type(R.lastMismatch) == "table" and R.lastMismatch or nil

local VALID_SIDES = { friendly = true, enemy = true }
local EPSILON = 0.000001

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

local function OpenActiveInterval(active, now, windowMs)
    if type(active) ~= "table" or active.last == nil or active.startedAt == nil then return nil, nil end
    now = tonumber(now) or (U and U.NowMs and U.NowMs()) or 0
    windowMs = math.max(0, tonumber(windowMs) or 0)
    local first = tonumber(active.startedAt)
    local last = tonumber(active.last)
    if first == nil or last == nil then return nil, nil end
    local finish = math.min(now, last + windowMs)
    if finish <= first then return nil, nil end
    return first, finish
end

local function SharedActiveMs(first, second, now, windowMs)
    now = tonumber(now) or (U and U.NowMs and U.NowMs()) or 0
    local total = math.max(0, tonumber(first and first.total) or 0)
        + math.max(0, tonumber(second and second.total) or 0)
    local firstFrom, firstTo = OpenActiveInterval(first, now, windowMs)
    local secondFrom, secondTo = OpenActiveInterval(second, now, windowMs)
    if firstFrom == nil then
        return total + (secondFrom ~= nil and math.max(0, secondTo - secondFrom) or 0)
    end
    if secondFrom == nil then return total + math.max(0, firstTo - firstFrom) end
    if secondFrom < firstFrom then
        firstFrom, secondFrom = secondFrom, firstFrom
        firstTo, secondTo = secondTo, firstTo
    end
    total = total + math.max(0, firstTo - firstFrom)
    if secondFrom <= firstTo then
        total = total + math.max(0, secondTo - math.max(firstTo, secondFrom))
    else
        total = total + math.max(0, secondTo - secondFrom)
    end
    return total
end

local function StatsRoot(root)
    root = root or (D.State and D.State.stats)
    if type(root) ~= "table" or tonumber(root.schemaVersion) ~= 3 then return nil end
    return root
end

function R:GetSharedHealingSide(sideName, root)
    if not VALID_SIDES[sideName] then return nil end
    root = StatsRoot(root)
    local shared = root and root.sharedHealing or nil
    if type(shared) ~= "table" or tonumber(shared.schemaVersion) ~= 1 then return nil end
    local side = shared[sideName]
    if type(side) ~= "table" then return nil end
    return side
end

-- Product detail lookup for DAMAGE/TAKEN pages. Mode is an immutable part of
-- the selected ranking context: a PVP detail is never allowed to fall through
-- to the same actor's PVE record, and vice versa. We may still follow the actor
-- across friendly/enemy sides inside the same mode because a later manual
-- relation correction can move the row without changing the event mode.
function R:GetModeActor(modeName, preferredSide, actorKey, root)
    if modeName ~= "PVP" and modeName ~= "PVE" then return nil, nil end
    if not VALID_SIDES[preferredSide] then return nil, nil end
    root = StatsRoot(root)
    if root == nil then return nil, nil end
    local mode = root[modeName]
    if type(mode) ~= "table" then return nil, nil end
    local key = tostring(actorKey or "")
    if key == "" then return nil, nil end

    local preferred = mode[preferredSide]
    local actor = type(preferred) == "table" and type(preferred.actors) == "table"
        and preferred.actors[key] or nil
    if actor ~= nil then return actor, preferredSide end

    local alternateSide = preferredSide == "friendly" and "enemy" or "friendly"
    local alternate = mode[alternateSide]
    actor = type(alternate) == "table" and type(alternate.actors) == "table"
        and alternate.actors[key] or nil
    if actor ~= nil then return actor, alternateSide end
    return nil, nil
end

function R:GetSharedHealingActor(sideName, actorKey, root)
    local side = self:GetSharedHealingSide(sideName, root)
    if type(side) ~= "table" or type(side.actors) ~= "table" then return nil end
    return side.actors[tostring(actorKey or "")]
end

function R:GetSharedHealingDisplayName(actorKey, actor)
    local entity = Actors:GetEntityByKey(actorKey)
    if type(entity) == "table" and tostring(entity.name or "") ~= "" then return entity.name end
    return SafeName(actor and actor.name, "未知")
end

function R:GetLegacyHealingReference(sideName, actorKey, now, root)
    if not VALID_SIDES[sideName] then return nil end
    root = StatsRoot(root)
    if root == nil then return nil end
    local key = tostring(actorKey or "")
    if key == "" then return nil end
    local pvpSide = root.PVP and root.PVP[sideName] or nil
    local pveSide = root.PVE and root.PVE[sideName] or nil
    local first = type(pvpSide) == "table" and type(pvpSide.actors) == "table" and pvpSide.actors[key] or nil
    local second = type(pveSide) == "table" and type(pveSide.actors) == "table" and pveSide.actors[key] or nil
    local value = (tonumber(first and first.heal) or 0) + (tonumber(second and second.heal) or 0)
    if value <= 0 and first == nil and second == nil then return nil end
    return {
        key = key,
        name = self:GetSharedHealingDisplayName(key, first or second),
        heal = value,
        provisional = (first and first.provisional == true) or (second and second.provisional == true) or false,
        activeMs = SharedActiveMs(first and first.active and first.active.heal,
            second and second.active and second.active.heal,
            now, D.State.config.personalWindowMs),
        first = first,
        second = second,
        source = self.referenceHealingSource,
    }
end

function R:GetLegacyHealingSideReference(sideName, now, root)
    if not VALID_SIDES[sideName] then return nil end
    root = StatsRoot(root)
    if root == nil then return nil end
    local pvpSide = root.PVP and root.PVP[sideName] or nil
    local pveSide = root.PVE and root.PVE[sideName] or nil
    return {
        heal = (tonumber(pvpSide and pvpSide.totals and pvpSide.totals.heal) or 0)
            + (tonumber(pveSide and pveSide.totals and pveSide.totals.heal) or 0),
        activeMs = SharedActiveMs(pvpSide and pvpSide.active and pvpSide.active.heal,
            pveSide and pveSide.active and pveSide.active.heal,
            now, D.State.config.sideWindowMs),
        source = self.referenceHealingSource,
    }
end

function R:CompareHealingActor(sideName, actorKey, root)
    local official = self:GetSharedHealingActor(sideName, actorKey, root)
    local reference = self:GetLegacyHealingReference(sideName, actorKey, nil, root)
    local officialValue = tonumber(official and official.heal) or 0
    local referenceValue = tonumber(reference and reference.heal) or 0
    return math.abs(officialValue - referenceValue) <= EPSILON, officialValue, referenceValue
end

local function ResolveProjectionActorId(projection, actorKey)
    if type(projection) ~= "table" then return nil end
    local entity = Actors:GetEntityByKey(actorKey)
    if type(entity) == "table" and type(Actors.GetStableId) == "function"
        and type(Actors.GetIdentityQuality) == "function"
        and Actors:GetIdentityQuality(entity) == "STABLE_ID" then
        local stableId = Actors:GetStableId(entity)
        if stableId ~= nil and tostring(stableId) ~= "" then
            local actorId = tonumber(projection.actorIdByToken and projection.actorIdByToken["actor:id:" .. tostring(stableId)])
            if actorId ~= nil and actorId > 0 then return math.floor(actorId) end
        end
    end
    local actorId = tonumber(projection.actorIdByToken
        and projection.actorIdByToken["actor:legacy-key:" .. tostring(actorKey or "")])
    if actorId ~= nil and actorId > 0 then return math.floor(actorId) end
    return nil
end

local function AddAmount(map, key, amount)
    local text = tostring(key or "")
    if text == "" then text = "未知" end
    map[text] = (tonumber(map[text]) or 0) + (tonumber(amount) or 0)
end

local function CopyNumberMap(source)
    local result = {}
    for key, amount in pairs(type(source) == "table" and source or {}) do
        amount = tonumber(amount) or 0
        if amount > 0 then result[tostring(key)] = amount end
    end
    return result
end

local function MakeLegacyEntry(displayName, amount)
    local normalized = NormalizeName(displayName)
    return {
        name = SafeName(displayName, "未知") .. " [旧名称汇总]",
        displayName = SafeName(displayName, "未知"),
        value = amount,
        kind = "COUNTERPART",
        identityKind = "LEGACY_NAME_HISTORY",
        identityQuality = "HISTORICAL_NAME_AGGREGATE",
        identityToken = "legacy-name:" .. normalized,
        canonicalKey = nil,
        readOnlyHistory = true,
    }
end

local function MakeTargetRefEntry(descriptor, amount, actorDescriptor)
    local displayName = SafeName(descriptor and descriptor.displayName, "未知")
    local identityKind = descriptor and descriptor.kind or "NAME_HISTORY"
    local stableId = type(actorDescriptor) == "table" and actorDescriptor.stableId or nil
    local suffix = identityKind == "ACTOR" and " [具体单位]" or " [新名称历史]"
    return {
        name = displayName .. suffix,
        displayName = displayName,
        value = amount,
        kind = "COUNTERPART",
        identityKind = identityKind,
        identityQuality = identityKind == "ACTOR" and "TARGET_REF_ACTOR" or "TARGET_REF_NAME_HISTORY",
        identityToken = descriptor and descriptor.identityToken or nil,
        canonicalKey = descriptor and descriptor.canonicalKey or nil,
        stableId = stableId,
        targetRefId = descriptor and descriptor.refId or nil,
        readOnlyHistory = identityKind ~= "ACTOR",
    }
end

function R:GetCombinedHealingBreakdown(sideName, actorKey, root)
    local official = self:GetSharedHealingActor(sideName, actorKey, root)
    if type(official) ~= "table" then return nil, "actor_not_found" end
    root = StatsRoot(root)
    local healDetails = official.details and official.details.heal or nil
    local fullTargets = CopyNumberMap(healDetails and healDetails.targets)
    local result = {
        schemaVersion = 1,
        source = "SHARED_HEALING_PLUS_TARGET_REF_DELTA",
        actorKey = tostring(actorKey or ""),
        amount = tonumber(official.heal) or 0,
        abilities = CopyNumberMap(healDetails and healDetails.abilities),
        counterparts = {},
        splitTargetRefAmount = 0,
        legacyNameAmount = 0,
        unresolvedDeltaAmount = 0,
        mismatchCount = 0,
        complete = true,
    }

    local fullByNormalized = {}
    local displayByNormalized = {}
    for displayName, amount in pairs(fullTargets) do
        local normalized = NormalizeName(displayName)
        if normalized == "" then normalized = "unknown" end
        AddAmount(fullByNormalized, normalized, amount)
        if displayByNormalized[normalized] == nil then displayByNormalized[normalized] = displayName end
    end

    local projection = root and root.identityProjection or nil
    local actorId = ResolveProjectionActorId(projection, actorKey)
    local refsByName = {}
    local unsafeNames = {}
    if actorId ~= nil and type(projection) == "table" then
        for _, modeName in ipairs({ "PVP", "PVE" }) do
            local side = projection.breakdowns and projection.breakdowns[modeName]
                and projection.breakdowns[modeName][sideName] or nil
            local actor = type(side) == "table" and type(side.actors) == "table"
                and side.actors[tostring(actorId)] or nil
            local row = type(actor) == "table" and type(actor.metrics) == "table" and actor.metrics.heal or nil
            for rawRefId, amount in pairs(type(row) == "table" and type(row.counterparts) == "table"
                and row.counterparts or {}) do
                amount = tonumber(amount) or 0
                local descriptor = projection.targetRefsById and projection.targetRefsById[tostring(rawRefId)] or nil
                if amount > 0 and type(descriptor) == "table" then
                    local normalized = NormalizeName(descriptor.displayName)
                    if normalized == "" then normalized = "unknown" end
                    refsByName[normalized] = refsByName[normalized] or {}
                    refsByName[normalized][#refsByName[normalized] + 1] = {
                        descriptor = descriptor,
                        amount = amount,
                    }
                elseif amount > 0 then
                    result.unresolvedDeltaAmount = result.unresolvedDeltaAmount + amount
                    result.complete = false
                end
            end
        end
    end

    for normalized, refs in pairs(refsByName) do
        local delta = 0
        for _, ref in ipairs(refs) do delta = delta + ref.amount end
        local full = tonumber(fullByNormalized[normalized]) or 0
        if delta > full + EPSILON then
            unsafeNames[normalized] = true
            result.mismatchCount = result.mismatchCount + 1
            result.complete = false
        end
    end

    for normalized, full in pairs(fullByNormalized) do
        local refs = refsByName[normalized]
        local split = 0
        if type(refs) == "table" and unsafeNames[normalized] ~= true then
            table.sort(refs, function(left, right)
                local leftToken = tostring(left.descriptor and left.descriptor.identityToken or "")
                local rightToken = tostring(right.descriptor and right.descriptor.identityToken or "")
                return leftToken < rightToken
            end)
            for _, ref in ipairs(refs) do
                local actorDescriptor = ref.descriptor and ref.descriptor.actorId ~= nil
                    and projection.actorsById and projection.actorsById[tostring(ref.descriptor.actorId)] or nil
                result.counterparts[#result.counterparts + 1] =
                    MakeTargetRefEntry(ref.descriptor, ref.amount, actorDescriptor)
                split = split + ref.amount
                result.splitTargetRefAmount = result.splitTargetRefAmount + ref.amount
            end
        end
        local residual = math.max(0, full - split)
        if residual > EPSILON then
            result.counterparts[#result.counterparts + 1] = MakeLegacyEntry(displayByNormalized[normalized], residual)
            result.legacyNameAmount = result.legacyNameAmount + residual
        end
    end

    -- A TargetRef with no matching name-keyed total cannot be displayed as an
    -- additive row without double-counting or inventing history. Preserve the
    -- complete name history and mark the view degraded instead.
    for normalized in pairs(refsByName) do
        if fullByNormalized[normalized] == nil then
            result.mismatchCount = result.mismatchCount + 1
            result.complete = false
        end
    end

    table.sort(result.counterparts, function(left, right)
        if left.value ~= right.value then return left.value > right.value end
        return tostring(left.name) < tostring(right.name)
    end)
    self.combinedBreakdownReads = self.combinedBreakdownReads + 1
    Counter("statsReadCombinedBreakdownReads", 1)
    if result.mismatchCount > 0 then Counter("statsReadBreakdownMismatches", result.mismatchCount) end
    return result
end

local function RecordAuditComparison(self, job, sideName, actorKey)
    local equal, officialValue, referenceValue = self:CompareHealingActor(sideName, actorKey, job.root)
    job.checked = job.checked + 1
    self.auditChecks = self.auditChecks + 1
    Counter("statsReadHealingAuditChecks", 1)
    if not equal then
        job.mismatches = job.mismatches + 1
        self.auditMismatches = self.auditMismatches + 1
        self.lastMismatch = {
            side = sideName,
            actorKey = actorKey,
            official = officialValue,
            reference = referenceValue,
        }
        Counter("statsReadHealingAuditMismatches", 1)
    end
end

function R:BeginSharedHealingAudit(root)
    root = StatsRoot(root)
    return {
        root = root,
        sideIndex = 1,
        phase = "SIDE_TOTAL",
        lastKey = nil,
        checked = 0,
        mismatches = 0,
        done = root == nil,
    }
end

function R:StepSharedHealingAudit(job, budget)
    if type(job) ~= "table" or job.done == true then return true end
    if job.root ~= D.State.stats and job.root ~= Stats.replayWorkingStats then
        job.done = true
        job.aborted = "authority_root_changed"
        return true
    end
    budget = math.max(1, math.floor(tonumber(budget) or 64))
    local processed = 0
    local sides = { "friendly", "enemy" }
    while processed < budget and job.sideIndex <= #sides do
        local sideName = sides[job.sideIndex]
        local shared = self:GetSharedHealingSide(sideName, job.root)
        local pvp = job.root.PVP and job.root.PVP[sideName] or nil
        local pve = job.root.PVE and job.root.PVE[sideName] or nil
        if job.phase == "SIDE_TOTAL" then
            local official = tonumber(shared and shared.totals and shared.totals.heal) or 0
            local reference = (tonumber(pvp and pvp.totals and pvp.totals.heal) or 0)
                + (tonumber(pve and pve.totals and pve.totals.heal) or 0)
            job.checked = job.checked + 1
            self.auditChecks = self.auditChecks + 1
            if math.abs(official - reference) > EPSILON then
                job.mismatches = job.mismatches + 1
                self.auditMismatches = self.auditMismatches + 1
                self.lastMismatch = { side = sideName, actorKey = "__side_total__", official = official, reference = reference }
            end
            job.phase = "SHARED"
            job.lastKey = nil
            processed = processed + 1
        else
            local actors
            if job.phase == "SHARED" then actors = shared and shared.actors or {}
            elseif job.phase == "PVP_EXTRA" then actors = pvp and pvp.actors or {}
            else actors = pve and pve.actors or {} end
            local key = next(type(actors) == "table" and actors or {}, job.lastKey)
            if key == nil then
                if job.phase == "SHARED" then job.phase = "PVP_EXTRA"
                elseif job.phase == "PVP_EXTRA" then job.phase = "PVE_EXTRA"
                else
                    job.sideIndex = job.sideIndex + 1
                    job.phase = "SIDE_TOTAL"
                end
                job.lastKey = nil
            else
                job.lastKey = key
                local shouldCheck = job.phase == "SHARED"
                    or not (shared and shared.actors and shared.actors[key])
                if shouldCheck and job.phase == "PVE_EXTRA" and pvp and pvp.actors and pvp.actors[key] ~= nil then
                    shouldCheck = false
                end
                if shouldCheck then
                    RecordAuditComparison(self, job, sideName, key)
                    processed = processed + 1
                end
            end
        end
    end
    if job.sideIndex > #sides then job.done = true end
    return job.done == true
end

function R:AuditAllForTests(batchSize)
    local job = self:BeginSharedHealingAudit(D.State.stats)
    local guard = 0
    while job.done ~= true and guard < 100000 do
        self:StepSharedHealingAudit(job, batchSize or 64)
        guard = guard + 1
    end
    return job
end

function R:OnAuthorityRootReplaced(root)
    self.lastMismatch = nil
    self.lastAuthorityRoot = root
end

function R:GetStatusLine()
    return "治疗读路径：SharedHealing正式；旧双桶仅校验"
        .. "；审计=" .. tostring(self.auditChecks)
        .. "；差异=" .. tostring(self.auditMismatches)
        .. "；组合详情=" .. tostring(self.combinedBreakdownReads)
end

local counters = D.Diagnostics and D.Diagnostics.counters or nil
if type(counters) == "table" then
    counters.statsReadHealingAuditChecks = tonumber(counters.statsReadHealingAuditChecks) or 0
    counters.statsReadHealingAuditMismatches = tonumber(counters.statsReadHealingAuditMismatches) or 0
    counters.statsReadCombinedBreakdownReads = tonumber(counters.statsReadCombinedBreakdownReads) or 0
    counters.statsReadBreakdownMismatches = tonumber(counters.statsReadBreakdownMismatches) or 0
end

Boot:CompletePhase("STATS_READ_READY")
if D.Diagnostics ~= nil then D.Diagnostics.status = "STATS_READ_READY" end

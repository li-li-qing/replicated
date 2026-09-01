ReplicatedSuiteModuleSandbox:Enter('dps', {'ReplicatedDps', 'ReplicatedDpsConfig'})
------------------------------------------------------------------------
-- Replicated DPS - diagnostic local Stats commit candidate and gates
-- Author: Replicated
--
-- Authority boundary
--   * D.State.stats remains the only production Stats Authority.
--   * D.LocalStatsShadow supplies a previously verified sparse delta ledger.
--   * This module clones only touched side totals / actor subtrees, applies the
--     sparse delta, and runs bounded pre-commit gates. It never swaps or mutates
--     D.State.stats, ranking caches, Boss projections or persistence state.
--
-- Commit policy
--   * Formal local commit is deliberately hard-disabled in this stage.
--   * A candidate may become VERIFIED_COMMIT_DISABLED, proving the working-copy
--     and gate mechanics without allowing product data to consume the result.
--   * Any journal, classification, block, Stats-root or mutation-revision change
--     fails closed and preserves the existing full-replay Authority.
--
-- Performance boundary
--   * Diagnostics must be enabled; otherwise no working copy is allocated.
--   * Only affected actors are deep-copied. Side closure scans and breakdown
--     checks advance with a fixed budget; no unbounded scan runs in Tick.
------------------------------------------------------------------------

if ReplicatedDps == nil or ReplicatedDps.Boot == nil then return end

local D = ReplicatedDps
local Boot = D.Boot
if Boot.phase == "FAILED" then return end
if type(D.LocalStatsShadow) ~= "table"
    or type(D.LocalStatsShadow.SetCommitCandidateObserver) ~= "function" then
    Boot:Fail("local_stats_candidate:local_stats_shadow",
        "D.LocalStatsShadow candidate observer boundary is unavailable")
    return
end
if type(D.Stats) ~= "table" then
    Boot:Fail("local_stats_candidate:stats", "D.Stats is unavailable")
    return
end
if type(D.EventStore) ~= "table" or type(D.EventBlocks) ~= "table"
    or type(D.EventClassifications) ~= "table" then
    Boot:Fail("local_stats_candidate:event_state", "event Authorities are unavailable")
    return
end
if type(D.Util) ~= "table" then
    Boot:Fail("local_stats_candidate:util", "D.Util is unavailable")
    return
end

Boot:SetPhase("LOCAL_STATS_CANDIDATE_LOADING")

local U = D.Util
local Stats = D.Stats
local Store = D.EventStore
local Blocks = D.EventBlocks
local Classifications = D.EventClassifications
local Shadow = D.LocalStatsShadow

D.LocalStatsCandidate = D.LocalStatsCandidate or {}
local G = D.LocalStatsCandidate

G.schemaVersion = 1
G.layoutVersion = 1
G.defaultStepBudget = 320
G.maxFailureSamples = 32
G.formalCommitEnabled = false -- Product commit remains intentionally disabled.
G.derivedStateObserver = nil
G.commitEnvelopeObserver = nil

local EPSILON = 0.0000001
local VALID_MODES = { PVP = true, PVE = true }
local VALID_SIDES = { friendly = true, enemy = true }
local VALID_METRICS = { damage = true, taken = true, heal = true, kills = true }
local SEP = string.char(31)


local function NotifyDerivedState(methodName, ...)
    local observer = G.derivedStateObserver
    local method = type(observer) == "table" and observer[methodName] or nil
    if type(method) ~= "function" or observer.failed == true then
        return nil, "LOCAL_DERIVED_STATE_UNAVAILABLE"
    end
    local ok, first, second, third, fourth = pcall(method, observer, ...)
    if not ok then
        if type(observer.DisableAfterFailure) == "function" then
            pcall(observer.DisableAfterFailure, observer, first)
        end
        return nil, "LOCAL_DERIVED_STATE_FAILURE:" .. tostring(first)
    end
    return first, second, third, fourth
end

local function NotifyCommitEnvelope(methodName, ...)
    local observer = G.commitEnvelopeObserver
    local method = type(observer) == "table" and observer[methodName] or nil
    if type(method) ~= "function" or observer.failed == true then
        return nil, "LOCAL_COMMIT_ENVELOPE_UNAVAILABLE"
    end
    local ok, first, second, third, fourth = pcall(method, observer, ...)
    if not ok then
        if type(observer.DisableAfterFailure) == "function" then
            pcall(observer.DisableAfterFailure, observer, first)
        end
        return nil, "LOCAL_COMMIT_ENVELOPE_FAILURE:" .. tostring(first)
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

local function DeepCopy(value)
    if type(U.DeepCopy) == "function" then return U.DeepCopy(value) end
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = DeepCopy(item) end
    return result
end

local function Finite(value)
    local number = tonumber(value)
    if number == nil or number ~= number or number == math.huge or number == -math.huge then
        return nil
    end
    return number
end

local function EmptyActor(name)
    return {
        name = tostring(name or "未知"),
        damage = 0, taken = 0, heal = 0, kills = 0,
        provisional = false,
        details = {
            damage = { abilities = {}, targets = {} },
            taken = { abilities = {}, sources = {} },
            heal = { abilities = {}, targets = {} },
            kills = { abilities = {}, targets = {} },
        },
        active = {
            damage = { total = 0 }, taken = { total = 0 }, heal = { total = 0 },
        },
    }
end

local function EnsureDetails(actor)
    actor.details = type(actor.details) == "table" and actor.details or {}
    for _, metric in ipairs({ "damage", "taken", "heal", "kills" }) do
        local counterpart = metric == "taken" and "sources" or "targets"
        local details = type(actor.details[metric]) == "table" and actor.details[metric] or {}
        details.abilities = type(details.abilities) == "table" and details.abilities or {}
        details[counterpart] = type(details[counterpart]) == "table" and details[counterpart] or {}
        actor.details[metric] = details
        actor[metric] = tonumber(actor[metric]) or 0
    end
    return actor
end

local function RootSide(root, mode, sideName)
    if mode == nil then
        local shared = type(root) == "table" and root.sharedHealing or nil
        return type(shared) == "table" and shared[sideName] or nil
    end
    local modeRoot = type(root) == "table" and root[mode] or nil
    return type(modeRoot) == "table" and modeRoot[sideName] or nil
end

local function WorkingSide(candidate, mode, sideName)
    local branch
    if mode == nil then
        candidate.working.sharedHealing = candidate.working.sharedHealing or {}
        branch = candidate.working.sharedHealing
    else
        candidate.working[mode] = candidate.working[mode] or {}
        branch = candidate.working[mode]
    end
    local side = branch[sideName]
    if side ~= nil then return side end
    local source = RootSide(candidate.oldRoot, mode, sideName)
    side = {
        totals = DeepCopy(type(source) == "table" and source.totals or {}) or {},
        actors = {},
    }
    for _, metric in ipairs({ "damage", "taken", "heal", "kills" }) do
        side.totals[metric] = tonumber(side.totals[metric]) or 0
    end
    branch[sideName] = side
    return side
end

local function WorkingActor(candidate, mode, sideName, actorKey)
    local side = WorkingSide(candidate, mode, sideName)
    local actor = side.actors[actorKey]
    if actor ~= nil then return actor end
    local sourceSide = RootSide(candidate.oldRoot, mode, sideName)
    local source = type(sourceSide) == "table" and type(sourceSide.actors) == "table"
        and sourceSide.actors[actorKey] or nil
    actor = type(source) == "table" and DeepCopy(source) or EmptyActor(actorKey)
    EnsureDetails(actor)
    side.actors[actorKey] = actor
    candidate.clonedActors = candidate.clonedActors + 1
    return actor
end

local function EntryToken(entry)
    return tostring(entry.kind or "") .. SEP .. tostring(entry.mode or "") .. SEP
        .. tostring(entry.side or "") .. SEP .. tostring(entry.actorKey or "") .. SEP
        .. tostring(entry.metric or "") .. SEP .. tostring(entry.detailKey or "")
end

local function ActorTaskToken(mode, sideName, actorKey, metric)
    return tostring(mode or "SHARED") .. SEP .. tostring(sideName) .. SEP
        .. tostring(actorKey) .. SEP .. tostring(metric)
end

local function SideTaskToken(mode, sideName, metric)
    return tostring(mode or "SHARED") .. SEP .. tostring(sideName) .. SEP .. tostring(metric)
end

local function AddFailure(candidate, reason, entry)
    candidate.failureCount = candidate.failureCount + 1
    candidate.failureReason = candidate.failureReason or tostring(reason or "UNKNOWN")
    if #candidate.failures < G.maxFailureSamples then
        candidate.failures[#candidate.failures + 1] = {
            reason = tostring(reason or "UNKNOWN"),
            kind = entry and entry.kind or nil,
            mode = entry and entry.mode or nil,
            side = entry and entry.side or nil,
            actorKey = entry and entry.actorKey or nil,
            metric = entry and entry.metric or nil,
            detailKey = entry and entry.detailKey or nil,
        }
    end
end

local function Fail(candidate, reason, entry)
    AddFailure(candidate, reason, entry)
    candidate.safe = false
    candidate.commitEligible = false
    candidate.phase = "FAILED"
    candidate.completedAt = NowMs()
    Counter("localStatsCandidateFallbacks", 1)
    return false
end

local function RecordSideTask(candidate, mode, sideName, metric)
    local token = SideTaskToken(mode, sideName, metric)
    if candidate.sideTaskSeen[token] then return end
    candidate.sideTaskSeen[token] = true
    candidate.sideTaskCount = candidate.sideTaskCount + 1
    candidate.sideTasks[candidate.sideTaskCount] = {
        mode = mode, side = sideName, metric = metric,
    }
end

local function RecordActorTask(candidate, mode, sideName, actorKey, metric)
    local token = ActorTaskToken(mode, sideName, actorKey, metric)
    if candidate.actorTaskSeen[token] then return end
    candidate.actorTaskSeen[token] = true
    candidate.actorTaskCount = candidate.actorTaskCount + 1
    candidate.actorTasks[candidate.actorTaskCount] = {
        mode = mode, side = sideName, actorKey = actorKey, metric = metric,
    }
end

local function ReadWorking(candidate, entry)
    local mode = string.sub(tostring(entry.kind), 1, 7) == "SHARED_" and nil or entry.mode
    local side = WorkingSide(candidate, mode, entry.side)
    if entry.kind == "LEGACY_SIDE_TOTAL" or entry.kind == "SHARED_SIDE_TOTAL" then
        return tonumber(side.totals[entry.metric]) or 0
    end
    local actor = side.actors[entry.actorKey]
    if type(actor) ~= "table" then return 0 end
    if entry.kind == "LEGACY_ACTOR_METRIC" or entry.kind == "SHARED_ACTOR_METRIC" then
        return tonumber(actor[entry.metric]) or 0
    end
    local details = actor.details and actor.details[entry.metric] or nil
    local map
    if entry.kind == "LEGACY_ABILITY" or entry.kind == "SHARED_ABILITY" then
        map = details and details.abilities
    elseif entry.kind == "LEGACY_COUNTERPART" then
        map = entry.metric == "taken" and details and details.sources or details and details.targets
    else
        map = details and details.targets
    end
    return tonumber(map and map[entry.detailKey]) or 0
end

local function ReadAuthority(root, entry)
    local mode = string.sub(tostring(entry.kind), 1, 7) == "SHARED_" and nil or entry.mode
    local side = RootSide(root, mode, entry.side)
    if entry.kind == "LEGACY_SIDE_TOTAL" or entry.kind == "SHARED_SIDE_TOTAL" then
        return tonumber(side and side.totals and side.totals[entry.metric]) or 0
    end
    local actor = type(side) == "table" and type(side.actors) == "table"
        and side.actors[entry.actorKey] or nil
    if entry.kind == "LEGACY_ACTOR_METRIC" or entry.kind == "SHARED_ACTOR_METRIC" then
        return tonumber(actor and actor[entry.metric]) or 0
    end
    local details = actor and actor.details and actor.details[entry.metric] or nil
    local map
    if entry.kind == "LEGACY_ABILITY" or entry.kind == "SHARED_ABILITY" then
        map = details and details.abilities
    elseif entry.kind == "LEGACY_COUNTERPART" then
        map = entry.metric == "taken" and details and details.sources or details and details.targets
    else
        map = details and details.targets
    end
    return tonumber(map and map[entry.detailKey]) or 0
end

local function ApplyEntry(candidate, entry)
    local delta = Finite(entry.delta)
    if delta == nil then return Fail(candidate, "NON_FINITE_DELTA", entry) end
    local shared = string.sub(tostring(entry.kind), 1, 7) == "SHARED_"
    local mode = shared and nil or entry.mode
    if mode ~= nil and not VALID_MODES[mode] then return Fail(candidate, "INVALID_MODE", entry) end
    if not VALID_SIDES[entry.side] then return Fail(candidate, "INVALID_SIDE", entry) end
    if not VALID_METRICS[entry.metric] then return Fail(candidate, "INVALID_METRIC", entry) end
    local side = WorkingSide(candidate, mode, entry.side)
    RecordSideTask(candidate, mode, entry.side, entry.metric)
    if entry.kind == "LEGACY_SIDE_TOTAL" or entry.kind == "SHARED_SIDE_TOTAL" then
        side.totals[entry.metric] = (tonumber(side.totals[entry.metric]) or 0) + delta
        return true
    end
    if entry.actorKey == nil then return Fail(candidate, "MISSING_ACTOR_KEY", entry) end
    local actor = WorkingActor(candidate, mode, entry.side, entry.actorKey)
    RecordActorTask(candidate, mode, entry.side, entry.actorKey, entry.metric)
    if entry.kind == "LEGACY_ACTOR_METRIC" or entry.kind == "SHARED_ACTOR_METRIC" then
        actor[entry.metric] = (tonumber(actor[entry.metric]) or 0) + delta
        return true
    end
    local details = actor.details[entry.metric]
    local map
    if entry.kind == "LEGACY_ABILITY" or entry.kind == "SHARED_ABILITY" then
        map = details.abilities
    elseif entry.kind == "LEGACY_COUNTERPART" then
        map = entry.metric == "taken" and details.sources or details.targets
    elseif entry.kind == "SHARED_TARGET" then
        map = details.targets
    else
        return Fail(candidate, "UNKNOWN_PATH_KIND", entry)
    end
    local detailKey = tostring(entry.detailKey or "")
    if detailKey == "" then return Fail(candidate, "MISSING_DETAIL_KEY", entry) end
    map[detailKey] = (tonumber(map[detailKey]) or 0) + delta
    return true
end

local function RevisionsMatch(candidate)
    if D.State.stats ~= candidate.newRoot then return false, "STATS_ROOT_CHANGED" end
    if Store.sessionEvents ~= candidate.journal then return false, "JOURNAL_ROOT_CHANGED" end
    if #(Store.sessionEvents or {}) ~= candidate.journalCount then return false, "JOURNAL_COUNT_CHANGED" end
    if (tonumber(Store.identityGeneration) or 0) ~= candidate.journalGeneration then
        return false, "JOURNAL_GENERATION_CHANGED"
    end
    if Blocks.committed ~= candidate.blockGeneration then return false, "BLOCK_GENERATION_CHANGED" end
    if Classifications:CommittedGeneration() ~= candidate.classificationGeneration then
        return false, "CLASSIFICATION_GENERATION_CHANGED"
    end
    if (tonumber(Stats.statsMutationRevision) or 0) ~= candidate.statsMutationRevision then
        return false, "STATS_MUTATION_REVISION_CHANGED"
    end
    if (tonumber(Stats.breakdownMutationRevision) or 0) ~= candidate.breakdownMutationRevision then
        return false, "BREAKDOWN_REVISION_CHANGED"
    end
    if (tonumber(Stats.rankingStructureRevision) or 0) ~= candidate.rankingStructureRevision then
        return false, "RANKING_STRUCTURE_REVISION_CHANGED"
    end
    return true
end

local function StepApply(candidate, budget)
    local used = 0
    while candidate.cursor <= candidate.entryCount and used < budget do
        local entry = candidate.entries[candidate.cursor]
        if type(entry) ~= "table" or not ApplyEntry(candidate, entry) then return used end
        candidate.cursor = candidate.cursor + 1
        used = used + 1
    end
    if candidate.cursor > candidate.entryCount then
        candidate.phase = "VALIDATE_PATHS"
        candidate.cursor = 1
    end
    return used
end

local function StepValidatePaths(candidate, budget)
    local used = 0
    while candidate.cursor <= candidate.entryCount and used < budget do
        local entry = candidate.entries[candidate.cursor]
        local value = ReadWorking(candidate, entry)
        local authority = ReadAuthority(candidate.newRoot, entry)
        if Finite(value) == nil or value < -EPSILON then
            Fail(candidate, "NEGATIVE_OR_NON_FINITE_PATH", entry)
            return used
        end
        if math.abs(value - authority) > EPSILON then
            Fail(candidate, "WORKING_PATH_MISMATCH", entry)
            return used
        end
        candidate.validatedPaths = candidate.validatedPaths + 1
        candidate.cursor = candidate.cursor + 1
        used = used + 1
    end
    if candidate.cursor > candidate.entryCount then
        candidate.phase = "VALIDATE_ACTORS"
        candidate.cursor = 1
        candidate.actorScan = nil
    end
    return used
end

local function BeginActorScan(candidate, task)
    local side = WorkingSide(candidate, task.mode, task.side)
    local actor = side.actors[task.actorKey]
    if type(actor) ~= "table" then return nil, "WORKING_ACTOR_MISSING" end
    local details = actor.details and actor.details[task.metric] or nil
    local counterpart = task.metric == "taken" and "sources" or "targets"
    return {
        task = task,
        actor = actor,
        abilityMap = type(details) == "table" and details.abilities or {},
        counterpartMap = type(details) == "table" and details[counterpart] or {},
        lane = "ABILITY", key = nil, abilitySum = 0, counterpartSum = 0,
    }
end

local function ScanNumberMap(scan, mapName, budget)
    local map = scan[mapName]
    local processed = 0
    while processed < budget do
        local key, value = next(map, scan.key)
        if key == nil then return true, processed end
        scan.key = key
        local number = Finite(value)
        if number == nil or number < -EPSILON then return false, processed, "INVALID_BREAKDOWN_VALUE" end
        if mapName == "abilityMap" then scan.abilitySum = scan.abilitySum + number
        else scan.counterpartSum = scan.counterpartSum + number end
        processed = processed + 1
    end
    return nil, processed
end

local function StepValidateActors(candidate, budget)
    local used = 0
    while candidate.cursor <= candidate.actorTaskCount and used < budget do
        local scan = candidate.actorScan
        if scan == nil then
            local err
            scan, err = BeginActorScan(candidate, candidate.actorTasks[candidate.cursor])
            if scan == nil then Fail(candidate, err) return used end
            candidate.actorScan = scan
        end
        local done, consumed, err
        if scan.lane == "ABILITY" then
            done, consumed, err = ScanNumberMap(scan, "abilityMap", budget - used)
            used = used + consumed
            if done == false then Fail(candidate, err, scan.task) return used end
            if done == true then scan.lane = "COUNTERPART" scan.key = nil end
        else
            done, consumed, err = ScanNumberMap(scan, "counterpartMap", budget - used)
            used = used + consumed
            if done == false then Fail(candidate, err, scan.task) return used end
            if done == true then
                local metricValue = tonumber(scan.actor[scan.task.metric]) or 0
                if metricValue < -EPSILON
                    or math.abs(metricValue - scan.abilitySum) > EPSILON
                    or math.abs(metricValue - scan.counterpartSum) > EPSILON then
                    Fail(candidate, "ACTOR_BREAKDOWN_NOT_CLOSED", scan.task)
                    return used
                end
                candidate.validatedActors = candidate.validatedActors + 1
                candidate.cursor = candidate.cursor + 1
                candidate.actorScan = nil
                used = used + 1
            end
        end
    end
    if candidate.cursor > candidate.actorTaskCount then
        candidate.phase = "VALIDATE_SIDES"
        candidate.cursor = 1
        candidate.sideScan = nil
    end
    return used
end

local function StepValidateSides(candidate, budget)
    local used = 0
    while candidate.cursor <= candidate.sideTaskCount and used < budget do
        local task = candidate.sideTasks[candidate.cursor]
        local scan = candidate.sideScan
        if scan == nil then
            local authoritySide = RootSide(candidate.newRoot, task.mode, task.side)
            scan = {
                task = task,
                actors = type(authoritySide) == "table" and authoritySide.actors or {},
                key = nil, sum = 0,
                expected = tonumber(WorkingSide(candidate, task.mode, task.side).totals[task.metric]) or 0,
            }
            candidate.sideScan = scan
        end
        local key, actor = next(scan.actors, scan.key)
        if key == nil then
            if scan.expected < -EPSILON or math.abs(scan.sum - scan.expected) > EPSILON then
                Fail(candidate, "SIDE_TOTAL_NOT_CLOSED", task)
                return used
            end
            candidate.validatedSides = candidate.validatedSides + 1
            candidate.cursor = candidate.cursor + 1
            candidate.sideScan = nil
            used = used + 1
        else
            scan.key = key
            local value = Finite(type(actor) == "table" and actor[task.metric] or 0)
            if value == nil or value < -EPSILON then
                Fail(candidate, "INVALID_SIDE_ACTOR_VALUE", task)
                return used
            end
            scan.sum = scan.sum + value
            used = used + 1
        end
    end
    if candidate.cursor > candidate.sideTaskCount then
        candidate.phase = "VALIDATE_SHARED"
        candidate.cursor = 1
    end
    return used
end

local function StepValidateShared(candidate, budget)
    candidate.sharedPhase = candidate.sharedPhase or "SIDES"
    candidate.sharedSideCursor = candidate.sharedSideCursor or 1
    candidate.sharedActorCursor = candidate.sharedActorCursor or 1
    local used = 0
    local sides = { "friendly", "enemy" }
    while used < budget do
        if candidate.sharedPhase == "SIDES" then
            local sideName = sides[candidate.sharedSideCursor]
            if sideName == nil then
                candidate.sharedPhase = "ACTORS"
            else
                local sharedSide = RootSide(candidate.newRoot, nil, sideName)
                local sharedTotal = tonumber(sharedSide and sharedSide.totals
                    and sharedSide.totals.heal) or 0
                local pvpSide = RootSide(candidate.newRoot, "PVP", sideName)
                local pveSide = RootSide(candidate.newRoot, "PVE", sideName)
                local legacyTotal = (tonumber(pvpSide and pvpSide.totals
                    and pvpSide.totals.heal) or 0)
                    + (tonumber(pveSide and pveSide.totals
                        and pveSide.totals.heal) or 0)
                if math.abs(sharedTotal - legacyTotal) > EPSILON then
                    Fail(candidate, "SHARED_HEALING_SIDE_MISMATCH",
                        { side = sideName, metric = "heal" })
                    return used
                end
                candidate.sharedSideCursor = candidate.sharedSideCursor + 1
                used = used + 1
            end
        elseif candidate.sharedPhase == "ACTORS" then
            local task = candidate.actorTasks[candidate.sharedActorCursor]
            if task == nil then
                candidate.validatedShared = true
                return used, true
            end
            candidate.sharedActorCursor = candidate.sharedActorCursor + 1
            if task.mode == nil and task.metric == "heal" then
                local sharedSide = RootSide(candidate.newRoot, nil, task.side)
                local sharedActor = type(sharedSide) == "table" and sharedSide.actors
                    and sharedSide.actors[task.actorKey] or nil
                local pvpSide = RootSide(candidate.newRoot, "PVP", task.side)
                local pveSide = RootSide(candidate.newRoot, "PVE", task.side)
                local legacy = (tonumber(pvpSide and pvpSide.actors
                    and pvpSide.actors[task.actorKey]
                    and pvpSide.actors[task.actorKey].heal) or 0)
                    + (tonumber(pveSide and pveSide.actors
                        and pveSide.actors[task.actorKey]
                        and pveSide.actors[task.actorKey].heal) or 0)
                local shared = tonumber(sharedActor and sharedActor.heal) or 0
                if math.abs(shared - legacy) > EPSILON then
                    Fail(candidate, "SHARED_HEALING_ACTOR_MISMATCH", task)
                    return used
                end
            end
            used = used + 1
        else
            Fail(candidate, "INVALID_SHARED_PHASE")
            return used
        end
    end
    return used, false
end

local function BeginDerivedGate(candidate)
    local ok, reason = RevisionsMatch(candidate)
    if not ok then return Fail(candidate, reason) end
    local started, startReason = NotifyDerivedState(
        "BeginDerived", candidate, candidate.transaction, candidate.plan)
    if started ~= true then
        return Fail(candidate, startReason or "LOCAL_DERIVED_STATE_UNAVAILABLE")
    end
    candidate.phase = "DERIVED_GATE"
    return true
end

local function BeginCommitEnvelope(candidate, derivedSummary)
    local ok, reason = RevisionsMatch(candidate)
    if not ok then return Fail(candidate, reason) end
    candidate.derived = derivedSummary
    candidate.safe = type(derivedSummary) == "table" and derivedSummary.safe == true
    if not candidate.safe then
        return Fail(candidate, type(derivedSummary) == "table"
            and derivedSummary.failureReason or "LOCAL_DERIVED_STATE_REJECTED")
    end
    local started, startReason = NotifyCommitEnvelope(
        "BeginEnvelope", candidate, candidate.transaction, candidate.plan, derivedSummary)
    if started ~= true then
        return Fail(candidate, startReason or "LOCAL_COMMIT_ENVELOPE_UNAVAILABLE")
    end
    candidate.phase = "COMMIT_ENVELOPE"
    return true
end

local function FinishCommitEnvelope(candidate, envelopeSummary)
    local ok, reason = RevisionsMatch(candidate)
    if not ok then return Fail(candidate, reason) end
    candidate.envelope = envelopeSummary
    candidate.safe = type(envelopeSummary) == "table" and envelopeSummary.safe == true
    if not candidate.safe then
        return Fail(candidate, type(envelopeSummary) == "table"
            and envelopeSummary.failureReason or "LOCAL_COMMIT_ENVELOPE_REJECTED")
    end
    local localCommitReady = envelopeSummary.localCommitReady == true
    candidate.commitEligible = G.formalCommitEnabled == true and localCommitReady
    if candidate.commitEligible then
        candidate.phase = "COMMIT_ELIGIBLE"
    elseif localCommitReady then
        candidate.phase = "VERIFIED_ENVELOPE_READ_ONLY"
    else
        candidate.phase = "VERIFIED_DERIVED_REBUILD_REQUIRED"
    end
    candidate.completedAt = NowMs()
    Counter("localStatsCandidateVerified", 1)
    if not candidate.commitEligible then Counter("localStatsCandidateCommitDisabled", 1) end
    return true
end

local function FreshState(reason, preserveEnabled)
    local enabled = preserveEnabled == true and G.enabled == true
    G.enabled = enabled
    G.failed = false
    G.failure = nil
    G.current = nil
    G.last = nil
    G.lastResetReason = tostring(reason or "module_load")
end

FreshState("module_load", false)

function G:DisableAfterFailure(err)
    self.failed = true
    self.enabled = false
    self.failure = tostring(err or "unknown local Stats candidate failure")
    if type(self.current) == "table" then
        Fail(self.current, "MODULE_FAILURE")
        self.last = self.current
    end
    self.current = nil
    Counter("localStatsCandidateFailures", 1)
    if D.Diagnostics ~= nil and type(D.Diagnostics.AddWarning) == "function" then
        D.Diagnostics:AddWarning("local_stats_candidate",
            "局部 Stats 可提交候选已停用：" .. self.failure)
    end
end

function G:SetDerivedStateObserver(observer)
    if observer ~= nil and type(observer) ~= "table" then return false end
    self.derivedStateObserver = observer
    return true
end

function G:SetCommitEnvelopeObserver(observer)
    if observer ~= nil and type(observer) ~= "table" then return false end
    self.commitEnvelopeObserver = observer
    return true
end

function G:OnDiagnosticsChanged(enabled)
    FreshState(enabled == true and "diagnostics_enabled" or "diagnostics_disabled", false)
    self.enabled = enabled == true
    NotifyDerivedState("OnDiagnosticsChanged", enabled == true)
    NotifyCommitEnvelope("OnDiagnosticsChanged", enabled == true)
end

function G:OnPlanAborted(plan, reason)
    local candidate = self.current
    if type(candidate) == "table" and type(plan) == "table"
        and candidate.planId == plan.id then
        Fail(candidate, reason or "LOCAL_PLAN_ABORTED")
        NotifyDerivedState("OnPlanAborted", plan, candidate.failureReason)
        NotifyCommitEnvelope("OnPlanAborted", plan, candidate.failureReason)
        self.last = candidate
    end
    self.current = nil
    return true
end

function G:BeginCandidate(transaction, plan)
    if self.enabled ~= true or self.failed == true then return false, "MODULE_DISABLED" end
    if type(transaction) ~= "table" or transaction.safe ~= true then
        return false, "STATS_SHADOW_NOT_EQUIVALENT"
    end
    if type(transaction.oldRoot) ~= "table" or type(transaction.newRoot) ~= "table"
        or tonumber(transaction.newRoot.schemaVersion) ~= 3 then
        return false, "STATS_ROOT_UNAVAILABLE"
    end
    if D.State.stats ~= transaction.newRoot then return false, "NEW_ROOT_NOT_AUTHORITY" end
    local candidate = {
        planId = type(plan) == "table" and plan.id or transaction.planId,
        transaction = transaction,
        plan = plan,
        oldRoot = transaction.oldRoot,
        newRoot = transaction.newRoot,
        entries = transaction.entries,
        entryCount = math.max(0, math.floor(tonumber(transaction.entryCount) or 0)),
        working = { PVP = {}, PVE = {}, sharedHealing = {} },
        phase = "APPLY_DELTA",
        cursor = 1,
        actorTasks = {}, actorTaskSeen = {}, actorTaskCount = 0,
        sideTasks = {}, sideTaskSeen = {}, sideTaskCount = 0,
        clonedActors = 0,
        validatedPaths = 0, validatedActors = 0, validatedSides = 0,
        validatedShared = false,
        failures = {}, failureCount = 0,
        safe = nil, commitEligible = false,
        journal = Store.sessionEvents,
        journalCount = #(Store.sessionEvents or {}),
        journalGeneration = tonumber(Store.identityGeneration) or 0,
        blockGeneration = Blocks.committed,
        classificationGeneration = transaction.newGeneration,
        statsMutationRevision = tonumber(Stats.statsMutationRevision) or 0,
        breakdownMutationRevision = tonumber(Stats.breakdownMutationRevision) or 0,
        rankingStructureRevision = tonumber(Stats.rankingStructureRevision) or 0,
        startedAt = NowMs(),
    }
    if Classifications:CommittedGeneration() ~= candidate.classificationGeneration then
        return false, "CLASSIFICATION_NOT_CURRENT"
    end
    self.current = candidate
    self.last = candidate
    Counter("localStatsCandidateTransactions", 1)
    return true
end

function G:StepCandidate(transaction, plan, budget)
    local candidate = self.current
    if self.enabled ~= true or self.failed == true then
        return true, false, "MODULE_DISABLED", nil
    end
    if type(candidate) ~= "table" or type(transaction) ~= "table"
        or candidate.planId ~= transaction.planId then
        return true, false, "CANDIDATE_NOT_FOUND", nil
    end
    local ok, reason = RevisionsMatch(candidate)
    if not ok then Fail(candidate, reason) end
    local remaining = math.max(1, math.floor(tonumber(budget) or self.defaultStepBudget))
    while remaining > 0 and candidate.phase ~= "FAILED"
        and candidate.phase ~= "VERIFIED_COMMIT_DISABLED"
        and candidate.phase ~= "VERIFIED_DERIVED_REBUILD_REQUIRED"
        and candidate.phase ~= "VERIFIED_ENVELOPE_READ_ONLY"
        and candidate.phase ~= "COMMIT_ELIGIBLE" do
        local used = 0
        if candidate.phase == "APPLY_DELTA" then used = StepApply(candidate, remaining)
        elseif candidate.phase == "VALIDATE_PATHS" then used = StepValidatePaths(candidate, remaining)
        elseif candidate.phase == "VALIDATE_ACTORS" then used = StepValidateActors(candidate, remaining)
        elseif candidate.phase == "VALIDATE_SIDES" then used = StepValidateSides(candidate, remaining)
        elseif candidate.phase == "VALIDATE_SHARED" then
            local done
            used, done = StepValidateShared(candidate, remaining)
            if done == true and candidate.phase ~= "FAILED" then BeginDerivedGate(candidate) end
        elseif candidate.phase == "DERIVED_GATE" then
            local done, safe, reason, summary = NotifyDerivedState(
                "StepDerived", candidate, transaction, plan, remaining)
            remaining = 0
            if done == true then
                if safe == true then
                    BeginCommitEnvelope(candidate, summary)
                else
                    Fail(candidate, reason or "LOCAL_DERIVED_STATE_REJECTED")
                end
            end
        elseif candidate.phase == "COMMIT_ENVELOPE" then
            local done, safe, reason, summary = NotifyCommitEnvelope(
                "StepEnvelope", candidate, transaction, plan, remaining)
            remaining = 0
            if done == true then
                if safe == true then
                    FinishCommitEnvelope(candidate, summary)
                else
                    Fail(candidate, reason or "LOCAL_COMMIT_ENVELOPE_REJECTED")
                end
            end
        else
            Fail(candidate, "INVALID_PHASE:" .. tostring(candidate.phase))
        end
        remaining = remaining - math.max(1, used)
    end
    local done = candidate.phase == "FAILED"
        or candidate.phase == "VERIFIED_COMMIT_DISABLED"
        or candidate.phase == "VERIFIED_DERIVED_REBUILD_REQUIRED"
        or candidate.phase == "VERIFIED_ENVELOPE_READ_ONLY"
        or candidate.phase == "COMMIT_ELIGIBLE"
    if done then
        local summary = {
            phase = candidate.phase,
            safe = candidate.safe == true,
            commitEligible = candidate.commitEligible == true,
            formalCommitEnabled = self.formalCommitEnabled == true,
            failureReason = candidate.failureReason,
            failureCount = candidate.failureCount,
            failures = candidate.failures,
            entryCount = candidate.entryCount,
            clonedActors = candidate.clonedActors,
            actorTaskCount = candidate.actorTaskCount,
            sideTaskCount = candidate.sideTaskCount,
            validatedPaths = candidate.validatedPaths,
            validatedActors = candidate.validatedActors,
            validatedSides = candidate.validatedSides,
            validatedShared = candidate.validatedShared == true,
            derived = candidate.derived,
            envelope = candidate.envelope,
        }
        self.last = candidate
        self.current = nil
        return true, summary.safe, summary.failureReason, summary
    end
    return false, nil, nil, nil
end

function G:GetLastSummary()
    local candidate = self.current or self.last
    if type(candidate) ~= "table" then return nil end
    return {
        phase = candidate.phase,
        safe = candidate.safe == true,
        commitEligible = candidate.commitEligible == true,
        formalCommitEnabled = self.formalCommitEnabled == true,
        failureReason = candidate.failureReason,
        entryCount = candidate.entryCount or 0,
        clonedActors = candidate.clonedActors or 0,
        actorTaskCount = candidate.actorTaskCount or 0,
        sideTaskCount = candidate.sideTaskCount or 0,
        validatedPaths = candidate.validatedPaths or 0,
        validatedActors = candidate.validatedActors or 0,
        validatedSides = candidate.validatedSides or 0,
        validatedShared = candidate.validatedShared == true,
        derived = candidate.derived,
        envelope = candidate.envelope,
    }
end

function G:GetWorkingCopyForTests()
    local candidate = self.current or self.last
    return type(candidate) == "table" and candidate.working or nil
end

function G:GetStatusLine()
    if self.enabled ~= true then
        if self.failed == true then return "局部提交门禁：已停用（故障）" end
        return "局部提交门禁：关闭（诊断模式启用）"
    end
    local candidate = self.current or self.last
    if type(candidate) ~= "table" then
        return "局部提交门禁：等待等价 Stats 样本（正式提交关闭）"
    end
    return "局部提交门禁 #" .. tostring(candidate.planId or 0)
        .. " / " .. tostring(candidate.phase or "UNKNOWN")
        .. " / 克隆Actor " .. tostring(candidate.clonedActors or 0)
        .. " / 路径 " .. tostring(candidate.validatedPaths or 0)
        .. "/" .. tostring(candidate.entryCount or 0)
        .. " / 正式提交=" .. (self.formalCommitEnabled == true and "允许" or "关闭")
        .. (type(candidate.envelope) == "table" and candidate.envelope.identityVerified == true
            and " / Envelope=通过" or "")
        .. (type(candidate.derived) == "table" and candidate.derived.identityPolicy ~= nil
            and (" / Identity=" .. tostring(candidate.derived.identityPolicy)) or "")
        .. (candidate.failureReason ~= nil and (" / " .. candidate.failureReason) or "")
end

local counters = D.Diagnostics and D.Diagnostics.counters or nil
if type(counters) == "table" then
    counters.localStatsCandidateTransactions = tonumber(counters.localStatsCandidateTransactions) or 0
    counters.localStatsCandidateVerified = tonumber(counters.localStatsCandidateVerified) or 0
    counters.localStatsCandidateCommitDisabled = tonumber(counters.localStatsCandidateCommitDisabled) or 0
    counters.localStatsCandidateFallbacks = tonumber(counters.localStatsCandidateFallbacks) or 0
    counters.localStatsCandidateFailures = tonumber(counters.localStatsCandidateFailures) or 0
end

Shadow:SetCommitCandidateObserver(G)
if D.State ~= nil and D.State.config ~= nil and D.State.config.diagnosticsEnabled == true then
    local ok, err = pcall(G.OnDiagnosticsChanged, G, true)
    if not ok then G:DisableAfterFailure(err) end
end

Boot:CompletePhase("LOCAL_STATS_CANDIDATE_READY")

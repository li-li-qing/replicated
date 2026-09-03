ReplicatedSuiteModuleSandbox:Enter('dps', {'ReplicatedDps', 'ReplicatedDpsConfig'})
------------------------------------------------------------------------
-- Replicated DPS - read-only local commit envelope and identity rebuild
-- Author: Replicated
--
-- Authority boundary
--   * D.State.stats remains the only product Stats Authority.
--   * D.EventClassifications remains the product classification Authority.
--   * D.LocalStatsCandidate owns a sparse compatibility working copy only.
--   * This module builds a read-only commit envelope and a complete isolated
--     identityProjection. It never swaps Stats roots, publishes classification,
--     changes ranking/Boss state, marks persistence dirty or writes UI data.
--
-- Transaction boundary
--   1. Capture immutable preconditions for the old/new roots and revisions.
--   2. Rebuild identityProjection from every committed EventBlock position,
--      using the committed EventClassification generation.
--   3. Compare the isolated projection with the full-replay Authority using a
--      bounded streaming table walk.
--   4. Publish a recursively read-only envelope containing commit order and an
--      atomic rollback description. Formal product commit remains hard-off.
--
-- Performance boundary
--   * Diagnostics must be enabled; otherwise no envelope or rebuild state is
--     allocated.
--   * Journal scan and deep comparison both advance with a fixed budget.
--   * No unbounded scan runs in Tick or the combat callback.
------------------------------------------------------------------------

if ReplicatedDps == nil or ReplicatedDps.Boot == nil then return end

local D = ReplicatedDps
local Boot = D.Boot
if Boot.phase == "FAILED" then return end
if type(D.LocalStatsCandidate) ~= "table"
    or type(D.LocalStatsCandidate.SetCommitEnvelopeObserver) ~= "function" then
    Boot:Fail("local_commit_envelope:local_stats_candidate",
        "D.LocalStatsCandidate envelope observer boundary is unavailable")
    return
end
if type(D.StatsV3) ~= "table"
    or type(D.StatsV3.CreateIdentityProjectionRebuild) ~= "function"
    or type(D.StatsV3.ApplyIdentityProjectionRebuildMetric) ~= "function" then
    Boot:Fail("local_commit_envelope:stats_v3", "Stats v3 rebuild boundary is unavailable")
    return
end
if type(D.ActorRegistry) ~= "table" or type(D.ActorRegistry.GetEntityByKey) ~= "function" then
    Boot:Fail("local_commit_envelope:actor_registry", "Actor Registry is unavailable")
    return
end
if type(D.EventBlocks) ~= "table" or type(D.EventBlocks.ReadFact) ~= "function"
    or type(D.EventBlocks.GetEventIdByPosition) ~= "function" then
    Boot:Fail("local_commit_envelope:event_blocks", "EventBlock boundary is unavailable")
    return
end
if type(D.EventClassifications) ~= "table"
    or type(D.EventClassifications.GetFromGeneration) ~= "function" then
    Boot:Fail("local_commit_envelope:event_classification",
        "EventClassification generation boundary is unavailable")
    return
end
if type(D.Stats) ~= "table" or type(D.EventStore) ~= "table" or type(D.Util) ~= "table" then
    Boot:Fail("local_commit_envelope:authorities", "Stats/EventStore/Util Authority unavailable")
    return
end

Boot:SetPhase("LOCAL_COMMIT_ENVELOPE_LOADING")

local U = D.Util
local Stats = D.Stats
local Store = D.EventStore
local Blocks = D.EventBlocks
local Classifications = D.EventClassifications
local Actors = D.ActorRegistry
local StatsV3 = D.StatsV3
local Candidate = D.LocalStatsCandidate

D.LocalCommitEnvelope = D.LocalCommitEnvelope or {}
local E = D.LocalCommitEnvelope

E.schemaVersion = 1
E.layoutVersion = 1
E.defaultStepBudget = 320
E.maxMismatchSamples = 32
E.formalCommitEnabled = false

local VALID_MODES = { PVP = true, PVE = true }
local VALID_SIDES = { friendly = true, enemy = true }
local EPSILON = 0.0000001

local function Counter(name, amount)
    local counters = D.Diagnostics and D.Diagnostics.counters or nil
    if type(counters) ~= "table" then return end
    counters[name] = (tonumber(counters[name]) or 0) + (tonumber(amount) or 1)
end

local function NowMs()
    return type(U.NowMs) == "function" and U.NowMs() or 0
end

local function NonEmpty(value)
    if value == nil then return nil end
    local text = tostring(value)
    if text == "" then return nil end
    return text
end

local function GenerationValue(generation, eventId, field)
    return Classifications:GetFromGeneration(generation, eventId, field)
end

local function ReadFact(eventId, field, fallback)
    local value, known = Blocks:ReadFact(eventId, field)
    if known ~= true then return fallback, false end
    if value == nil then return fallback, true end
    return value, true
end

local function SameScalar(left, right)
    if type(left) == "number" or type(right) == "number" then
        local a, b = tonumber(left), tonumber(right)
        if a == nil or b == nil then return false end
        return math.abs(a - b) <= EPSILON
    end
    return left == right
end

local function RootToken(value)
    return type(value) == "table" and tostring(value) or tostring(value)
end

local function GenerationId(generation)
    if type(generation) ~= "table" then return nil end
    return generation.id or generation.generation or generation.revision
end

local function RevisionsMatch(job)
    if D.State.stats ~= job.newRoot then return false, "STATS_ROOT_CHANGED" end
    if Store.sessionEvents ~= job.journal then return false, "JOURNAL_ROOT_CHANGED" end
    if #(Store.sessionEvents or {}) ~= job.journalCount then return false, "JOURNAL_COUNT_CHANGED" end
    if (tonumber(Store.identityGeneration) or 0) ~= job.journalGeneration then
        return false, "JOURNAL_GENERATION_CHANGED"
    end
    if Blocks.committed ~= job.blockGeneration then return false, "BLOCK_GENERATION_CHANGED" end
    if Classifications:CommittedGeneration() ~= job.classificationGeneration then
        return false, "CLASSIFICATION_GENERATION_CHANGED"
    end
    if (tonumber(Stats.statsMutationRevision) or 0) ~= job.statsMutationRevision then
        return false, "STATS_MUTATION_REVISION_CHANGED"
    end
    if (tonumber(Stats.breakdownMutationRevision) or 0) ~= job.breakdownMutationRevision then
        return false, "BREAKDOWN_REVISION_CHANGED"
    end
    if (tonumber(Stats.rankingStructureRevision) or 0) ~= job.rankingStructureRevision then
        return false, "RANKING_STRUCTURE_REVISION_CHANGED"
    end
    local analysis = D.Analysis
    if analysis ~= job.analysisRoot then return false, "ANALYSIS_ROOT_CHANGED" end
    if (tonumber(analysis and analysis.revision) or 0) ~= job.analysisRevision then
        return false, "ANALYSIS_REVISION_CHANGED"
    end
    return true
end

local function AddMismatch(job, reason, path, expected, actual)
    job.mismatchCount = job.mismatchCount + 1
    job.failureReason = job.failureReason or tostring(reason or "UNKNOWN")
    if #job.mismatches < E.maxMismatchSamples then
        job.mismatches[#job.mismatches + 1] = {
            reason = tostring(reason or "UNKNOWN"),
            path = tostring(path or "identityProjection"),
            expected = expected,
            actual = actual,
        }
    end
end

local function Fail(job, reason, path, expected, actual)
    AddMismatch(job, reason, path, expected, actual)
    job.safe = false
    job.localCommitReady = false
    job.phase = "FAILED"
    job.completedAt = NowMs()
    Counter("localCommitEnvelopeFallbacks", 1)
    return false
end

local function EventView(job, eventId)
    local event = job.eventView
    event.sourceResolvedKey = select(1, GenerationValue(job.classificationGeneration,
        eventId, "sourceResolvedKey"))
    event.targetResolvedKey = select(1, GenerationValue(job.classificationGeneration,
        eventId, "targetResolvedKey"))
    event.sourceKey = event.sourceResolvedKey
    event.targetKey = event.targetResolvedKey
    event.sourceName = select(1, ReadFact(eventId, "sourceName", "未知"))
    event.targetName = select(1, ReadFact(eventId, "targetName", "未知"))
    event.abilityName = select(1, ReadFact(eventId, "abilityName", "未知"))
    event.abilityId = select(1, ReadFact(eventId, "abilityId", nil))
    event.timestamp = select(1, ReadFact(eventId, "timestamp", 0))
    event.eventId = eventId
    return event
end

local function ApplyMetric(job, mode, sideName, entity, metric, amount, event)
    if not VALID_MODES[mode] or not VALID_SIDES[sideName] then
        return Fail(job, "INVALID_IDENTITY_ROUTE", "event:" .. tostring(event.eventId),
            mode .. "/" .. tostring(sideName), nil)
    end
    if type(entity) ~= "table" then
        return Fail(job, "IDENTITY_ENTITY_MISSING", "event:" .. tostring(event.eventId),
            metric, nil)
    end
    local ok, reason = StatsV3:ApplyIdentityProjectionRebuildMetric(
        job.rebuiltProjection, mode, sideName, entity, metric, amount, event)
    if ok ~= true then
        return Fail(job, "IDENTITY_REBUILD_WRITE_FAILED", "event:" .. tostring(event.eventId),
            reason, nil)
    end
    job.metricWrites = job.metricWrites + 1
    return true
end

local function StepIdentityRebuild(job, budget)
    local used = 0
    while used < budget and job.eventCursor <= job.journalCount do
        local position = job.eventCursor
        local eventId = Blocks:GetEventIdByPosition(position)
        if eventId == nil then
            Fail(job, "EVENT_POSITION_MISSING", "position:" .. tostring(position))
            return used
        end
        local applied = select(1, GenerationValue(job.classificationGeneration,
            eventId, "applied")) == true
        if applied then
            local mode = select(1, GenerationValue(job.classificationGeneration,
                eventId, "appliedMode"))
                or select(1, GenerationValue(job.classificationGeneration,
                    eventId, "candidateMode"))
            local sourceSide = select(1, GenerationValue(job.classificationGeneration,
                eventId, "sourceProjectionSide"))
            local targetSide = select(1, GenerationValue(job.classificationGeneration,
                eventId, "targetProjectionSide"))
            local category = select(1, ReadFact(eventId, "category", "OTHER"))
            local amountValue = ReadFact(eventId, "amount", 0)
            local amount = tonumber(amountValue) or 0
            local event = EventView(job, eventId)
            local source = event.sourceResolvedKey ~= nil
                and Actors:GetEntityByKey(event.sourceResolvedKey) or nil
            local target = event.targetResolvedKey ~= nil
                and Actors:GetEntityByKey(event.targetResolvedKey) or nil
            if category == "DAMAGE" then
                if not ApplyMetric(job, mode, sourceSide, source, "damage", amount, event)
                    or not ApplyMetric(job, mode, targetSide, target, "taken", amount, event) then
                    return used
                end
            elseif category == "HEAL" then
                if not ApplyMetric(job, mode, sourceSide, source, "heal", amount, event) then
                    return used
                end
            elseif category == "DEATH" then
                if not ApplyMetric(job, mode, sourceSide, source, "kills", 1, event) then
                    return used
                end
            end
        end
        job.eventCursor = job.eventCursor + 1
        job.eventsScanned = job.eventsScanned + 1
        used = used + 1
    end
    if job.eventCursor > job.journalCount and job.phase ~= "FAILED" then
        job.phase = "COMPARE_IDENTITY"
        job.compareRootCursor = 1
        job.compareStack = {}
    end
    return used
end

local COMPARE_ROOTS = {
    "schemaVersion", "nextActorId", "nextTargetRefId", "actorIdByToken",
    "targetRefIdByToken", "actorsById", "targetRefsById", "breakdowns",
    "migration", "projectionState", "needsRebuild",
}

local function PushCompare(job, left, right, path)
    job.compareStack[#job.compareStack + 1] = {
        left = left, right = right, path = path, phase = "INIT",
    }
end

local function StepCompareNode(job)
    local node = job.compareStack[#job.compareStack]
    if node == nil then
        local field = COMPARE_ROOTS[job.compareRootCursor]
        if field == nil then
            job.identityVerified = true
            job.phase = "BUILD_ENVELOPE"
            return 1
        end
        job.compareRootCursor = job.compareRootCursor + 1
        PushCompare(job, job.rebuiltProjection[field], job.expectedProjection[field],
            "identityProjection." .. field)
        return 1
    end

    if node.phase == "INIT" then
        local lt, rt = type(node.left), type(node.right)
        if lt ~= rt then
            Fail(job, "IDENTITY_TYPE_MISMATCH", node.path, lt, rt)
            return 1
        end
        if lt ~= "table" then
            if not SameScalar(node.left, node.right) then
                Fail(job, "IDENTITY_VALUE_MISMATCH", node.path, node.left, node.right)
            else
                job.compareNodes = job.compareNodes + 1
                job.compareStack[#job.compareStack] = nil
            end
            return 1
        end
        node.phase = "LEFT"
        node.key = nil
        return 1
    end

    if node.phase == "LEFT" then
        local ok, key, value = pcall(next, node.left, node.key)
        if not ok then
            Fail(job, "IDENTITY_TABLE_ITERATION_FAILED", node.path)
            return 1
        end
        if key == nil then
            node.phase = "RIGHT"
            node.key = nil
            return 1
        end
        node.key = key
        if rawget(node.right, key) == nil and value ~= nil then
            Fail(job, "IDENTITY_MISSING_EXPECTED_KEY",
                node.path .. "." .. tostring(key), value, nil)
            return 1
        end
        PushCompare(job, value, rawget(node.right, key),
            node.path .. "." .. tostring(key))
        return 1
    end

    if node.phase == "RIGHT" then
        local ok, key, value = pcall(next, node.right, node.key)
        if not ok then
            Fail(job, "IDENTITY_TABLE_ITERATION_FAILED", node.path)
            return 1
        end
        if key == nil then
            job.compareNodes = job.compareNodes + 1
            job.compareStack[#job.compareStack] = nil
            return 1
        end
        node.key = key
        if rawget(node.left, key) == nil and value ~= nil then
            Fail(job, "IDENTITY_UNEXPECTED_KEY",
                node.path .. "." .. tostring(key), nil, value)
            return 1
        end
        return 1
    end

    Fail(job, "IDENTITY_COMPARE_PHASE_INVALID", node.path)
    return 1
end

local function StepIdentityCompare(job, budget)
    local used = 0
    while used < budget and job.phase == "COMPARE_IDENTITY" do
        used = used + StepCompareNode(job)
    end
    return used
end

local function ReadOnlyProxy(value, cache)
    if type(value) ~= "table" then return value end
    cache = cache or {}
    if cache[value] ~= nil then return cache[value] end
    local proxy = {}
    cache[value] = proxy
    setmetatable(proxy, {
        __index = function(_, key) return ReadOnlyProxy(value[key], cache) end,
        __newindex = function() error("commit envelope is read-only", 2) end,
        __len = function() return #value end,
        __metatable = false,
    })
    return proxy
end

local function BuildEnvelope(job)
    local candidate = job.candidate
    local transaction = job.transaction
    local plan = job.plan
    local derived = job.derived
    local projection = job.rebuiltProjection
    local envelope = {
        schemaVersion = 1,
        planId = job.planId,
        readOnly = true,
        formalCommitEnabled = E.formalCommitEnabled == true,
        phase = "VERIFIED_ENVELOPE_READ_ONLY",
        createdAt = NowMs(),
        preconditions = {
            oldStatsRoot = RootToken(job.oldRoot),
            newStatsRoot = RootToken(job.newRoot),
            journalRoot = RootToken(job.journal),
            journalCount = job.journalCount,
            journalGeneration = job.journalGeneration,
            eventBlockGeneration = GenerationId(job.blockGeneration),
            oldClassificationGeneration = GenerationId(transaction.oldGeneration),
            newClassificationGeneration = GenerationId(job.classificationGeneration),
            statsMutationRevision = job.statsMutationRevision,
            breakdownMutationRevision = job.breakdownMutationRevision,
            rankingStructureRevision = job.rankingStructureRevision,
            analysisRoot = RootToken(job.analysisRoot),
            analysisRevision = job.analysisRevision,
        },
        candidate = {
            sparseEntryCount = tonumber(candidate.entryCount) or 0,
            clonedActors = tonumber(candidate.clonedActors) or 0,
            actorTaskCount = tonumber(candidate.actorTaskCount) or 0,
            sideTaskCount = tonumber(candidate.sideTaskCount) or 0,
            validatedPaths = tonumber(candidate.validatedPaths) or 0,
            validatedActors = tonumber(candidate.validatedActors) or 0,
            validatedSides = tonumber(candidate.validatedSides) or 0,
            validatedShared = candidate.validatedShared == true,
        },
        derived = {
            safe = type(derived) == "table" and derived.safe == true,
            validatedActorActive = type(derived) == "table"
                and tonumber(derived.validatedActorActive) or 0,
            validatedProvisional = type(derived) == "table"
                and tonumber(derived.validatedProvisional) or 0,
            validatedSideActive = type(derived) == "table"
                and tonumber(derived.validatedSideActive) or 0,
            bossValidated = type(derived) == "table" and derived.bossValidated == true,
            identityPolicy = "FULL_REBUILD_TRANSACTION_VERIFIED",
        },
        identityRebuild = {
            verified = job.identityVerified == true,
            eventsScanned = job.eventsScanned,
            metricWrites = job.metricWrites,
            actorCount = tonumber(projection.nextActorId) or 0,
            targetRefCount = tonumber(projection.nextTargetRefId) or 0,
            compareNodes = job.compareNodes,
            source = "EVENTBLOCK_PLUS_COMMITTED_CLASSIFICATION",
        },
        commitDescriptor = {
            atomic = true,
            enabled = false,
            order = {
                "REVALIDATE_ENVELOPE_PRECONDITIONS",
                "APPLY_SPARSE_COMPATIBILITY_SUBTREES",
                "INSTALL_REBUILT_IDENTITY_PROJECTION",
                "INSTALL_REBUILT_ACTIVE_PROVISIONAL_AND_BOSS",
                "PUBLISH_CLASSIFICATION_GENERATION",
                "INVALIDATE_AND_REBUILD_RANKING_CACHES",
                "MARK_STATS_AND_CONFIG_PERSISTENCE_DIRTY",
                "RELEASE_ROLLBACK_ROOTS_AFTER_DURABLE_SAVE",
            },
        },
        rollbackDescriptor = {
            atomic = true,
            executable = false,
            retainedAuthorities = {
                statsRoot = RootToken(job.oldRoot),
                classificationGeneration = GenerationId(transaction.oldGeneration),
                journalRoot = RootToken(job.journal),
                analysisRoot = RootToken(job.analysisRoot),
            },
            order = {
                "RESTORE_OLD_STATS_ROOT_POINTER",
                "RESTORE_OLD_CLASSIFICATION_GENERATION_POINTER",
                "RESTORE_OR_REBUILD_BOSS_FROM_OLD_STATS",
                "INVALIDATE_RANKING_CACHES_AND_REBUILD",
                "RESTORE_PERSISTENCE_DIRTY_FLAGS",
                "DISCARD_UNPUBLISHED_IDENTITY_AND_CANDIDATE_WORK",
            },
            releaseCondition = "NEW_STATS_GENERATION_DURABLY_SAVED",
        },
    }
    job.envelopeData = envelope
    job.envelopeProxy = ReadOnlyProxy(envelope)
    job.safe = true
    job.localCommitReady = true
    job.phase = "DONE"
    job.completedAt = NowMs()
    Counter("localCommitEnvelopesVerified", 1)
end

local function FreshState(reason, preserveEnabled)
    local enabled = preserveEnabled == true and E.enabled == true
    E.enabled = enabled
    E.failed = false
    E.failure = nil
    E.current = nil
    E.last = nil
    E.lastEnvelope = nil
    E.lastResetReason = tostring(reason or "module_load")
end

FreshState("module_load", false)

function E:DisableAfterFailure(err)
    self.failed = true
    self.enabled = false
    self.failure = tostring(err or "unknown local commit envelope failure")
    if type(self.current) == "table" then
        Fail(self.current, "MODULE_FAILURE")
        self.last = self.current
    end
    self.current = nil
    Counter("localCommitEnvelopeFailures", 1)
    if D.Diagnostics ~= nil and type(D.Diagnostics.AddWarning) == "function" then
        D.Diagnostics:AddWarning("local_commit_envelope",
            "局部只读提交信封已停用：" .. self.failure)
    end
end

function E:OnDiagnosticsChanged(enabled)
    FreshState(enabled == true and "diagnostics_enabled" or "diagnostics_disabled", false)
    self.enabled = enabled == true
end

function E:OnPlanAborted(plan, reason)
    local job = self.current
    if type(job) == "table" and type(plan) == "table" and job.planId == plan.id then
        Fail(job, reason or "LOCAL_PLAN_ABORTED")
        self.last = job
    end
    self.current = nil
    return true
end

function E:BeginEnvelope(candidate, transaction, plan, derived)
    if self.enabled ~= true or self.failed == true then return false, "MODULE_DISABLED" end
    if type(candidate) ~= "table" or type(transaction) ~= "table" or type(plan) ~= "table" then
        return false, "ENVELOPE_INPUT_MISSING"
    end
    if type(derived) ~= "table" or derived.safe ~= true then
        return false, "DERIVED_STATE_NOT_VERIFIED"
    end
    if D.State.stats ~= transaction.newRoot then return false, "NEW_ROOT_NOT_AUTHORITY" end
    local expectedProjection = type(transaction.newRoot.identityProjection) == "table"
        and transaction.newRoot.identityProjection or nil
    if type(expectedProjection) ~= "table" then return false, "IDENTITY_PROJECTION_MISSING" end
    local job = {
        planId = plan.id,
        candidate = candidate,
        transaction = transaction,
        plan = plan,
        derived = derived,
        oldRoot = transaction.oldRoot,
        newRoot = transaction.newRoot,
        expectedProjection = expectedProjection,
        rebuiltProjection = StatsV3:CreateIdentityProjectionRebuild(),
        phase = "REBUILD_IDENTITY",
        eventCursor = 1,
        eventsScanned = 0,
        metricWrites = 0,
        compareNodes = 0,
        mismatchCount = 0,
        mismatches = {},
        safe = nil,
        localCommitReady = false,
        eventView = {},
        journal = Store.sessionEvents,
        journalCount = #(Store.sessionEvents or {}),
        journalGeneration = tonumber(Store.identityGeneration) or 0,
        blockGeneration = Blocks.committed,
        classificationGeneration = transaction.newGeneration,
        statsMutationRevision = tonumber(Stats.statsMutationRevision) or 0,
        breakdownMutationRevision = tonumber(Stats.breakdownMutationRevision) or 0,
        rankingStructureRevision = tonumber(Stats.rankingStructureRevision) or 0,
        analysisRoot = D.Analysis,
        analysisRevision = tonumber(D.Analysis and D.Analysis.revision) or 0,
        startedAt = NowMs(),
    }
    if Classifications:CommittedGeneration() ~= job.classificationGeneration then
        return false, "CLASSIFICATION_NOT_CURRENT"
    end
    if tonumber(job.blockGeneration and job.blockGeneration.eventCount) ~= job.journalCount then
        return false, "EVENT_BLOCK_JOURNAL_COUNT_MISMATCH"
    end
    self.current = job
    self.last = job
    Counter("localCommitEnvelopeTransactions", 1)
    return true
end

function E:StepEnvelope(candidate, transaction, plan, budget)
    local job = self.current
    if self.enabled ~= true or self.failed == true then
        return true, false, "MODULE_DISABLED", nil
    end
    if type(job) ~= "table" or job.candidate ~= candidate or job.transaction ~= transaction
        or type(plan) ~= "table" or job.planId ~= plan.id then
        return true, false, "ENVELOPE_JOB_NOT_FOUND", nil
    end
    local ok, reason = RevisionsMatch(job)
    if not ok then Fail(job, reason) end
    local remaining = math.max(1, math.floor(tonumber(budget) or self.defaultStepBudget))
    while remaining > 0 and job.phase ~= "DONE" and job.phase ~= "FAILED" do
        local used = 0
        if job.phase == "REBUILD_IDENTITY" then
            used = StepIdentityRebuild(job, remaining)
        elseif job.phase == "COMPARE_IDENTITY" then
            used = StepIdentityCompare(job, remaining)
        elseif job.phase == "BUILD_ENVELOPE" then
            BuildEnvelope(job)
            used = 1
        else
            Fail(job, "INVALID_PHASE:" .. tostring(job.phase))
            used = 1
        end
        remaining = remaining - math.max(1, used)
    end
    if job.phase == "DONE" or job.phase == "FAILED" then
        local summary = {
            phase = job.phase,
            safe = job.safe == true,
            localCommitReady = job.localCommitReady == true,
            formalCommitEnabled = self.formalCommitEnabled == true,
            failureReason = job.failureReason,
            mismatchCount = job.mismatchCount,
            mismatches = job.mismatches,
            eventsScanned = job.eventsScanned,
            metricWrites = job.metricWrites,
            compareNodes = job.compareNodes,
            identityVerified = job.identityVerified == true,
            actorCount = tonumber(job.rebuiltProjection and job.rebuiltProjection.nextActorId) or 0,
            targetRefCount = tonumber(job.rebuiltProjection and job.rebuiltProjection.nextTargetRefId) or 0,
            envelope = job.envelopeProxy,
        }
        self.last = job
        if summary.safe then self.lastEnvelope = job.envelopeProxy end
        self.current = nil
        return true, summary.safe, summary.failureReason, summary
    end
    return false, nil, nil, nil
end

function E:GetLastEnvelope()
    return self.lastEnvelope
end

function E:GetLastSummary()
    local job = self.current or self.last
    if type(job) ~= "table" then return nil end
    return {
        phase = job.phase,
        safe = job.safe == true,
        localCommitReady = job.localCommitReady == true,
        eventsScanned = job.eventsScanned or 0,
        metricWrites = job.metricWrites or 0,
        compareNodes = job.compareNodes or 0,
        identityVerified = job.identityVerified == true,
        actorCount = tonumber(job.rebuiltProjection and job.rebuiltProjection.nextActorId) or 0,
        targetRefCount = tonumber(job.rebuiltProjection and job.rebuiltProjection.nextTargetRefId) or 0,
        failureReason = job.failureReason,
    }
end

function E:GetStatusLine()
    if self.enabled ~= true then
        if self.failed == true then return "只读提交信封：已停用（故障）" end
        return "只读提交信封：关闭（诊断模式启用）"
    end
    local job = self.current or self.last
    if type(job) ~= "table" then
        return "只读提交信封：等待安全候选（正式提交关闭）"
    end
    return "只读提交信封 #" .. tostring(job.planId or 0)
        .. " / " .. tostring(job.phase or "UNKNOWN")
        .. " / 事件 " .. tostring(job.eventsScanned or 0)
        .. "/" .. tostring(job.journalCount or 0)
        .. " / ActorId " .. tostring(job.rebuiltProjection and job.rebuiltProjection.nextActorId or 0)
        .. " / TargetRef " .. tostring(job.rebuiltProjection and job.rebuiltProjection.nextTargetRefId or 0)
        .. " / Identity=" .. tostring(job.identityVerified == true and "通过" or "待验证")
        .. " / 正式提交=关闭"
        .. (job.failureReason ~= nil and (" / " .. tostring(job.failureReason)) or "")
end

local counters = D.Diagnostics and D.Diagnostics.counters or nil
if type(counters) == "table" then
    counters.localCommitEnvelopeTransactions = tonumber(counters.localCommitEnvelopeTransactions) or 0
    counters.localCommitEnvelopesVerified = tonumber(counters.localCommitEnvelopesVerified) or 0
    counters.localCommitEnvelopeFallbacks = tonumber(counters.localCommitEnvelopeFallbacks) or 0
    counters.localCommitEnvelopeFailures = tonumber(counters.localCommitEnvelopeFailures) or 0
end

Candidate:SetCommitEnvelopeObserver(E)
if D.State ~= nil and D.State.config ~= nil and D.State.config.diagnosticsEnabled == true then
    local ok, err = pcall(E.OnDiagnosticsChanged, E, true)
    if not ok then E:DisableAfterFailure(err) end
end

Boot:CompletePhase("LOCAL_COMMIT_ENVELOPE_READY")

ReplicatedSuiteModuleSandbox:Enter('dps', {'ReplicatedDps', 'ReplicatedDpsConfig'})
------------------------------------------------------------------------
-- Replicated DPS - diagnostic local derived-state rebuild and commit policy
-- Author: Replicated
--
-- Authority boundary
--   * D.State.stats, D.Analysis boss runtime and Stats v3 identityProjection
--     remain production Authorities committed by the existing full replay.
--   * D.LocalStatsCandidate owns a sparse compatibility working copy only.
--   * This module reconstructs non-additive derived state and compares it with
--     the full-replay Authorities. It never mutates product Stats, Boss, ranking,
--     EventClassification, Entity, persistence state or UI data.
--
-- Rebuild policy
--   * Affected actor active windows and provisional flags are rebuilt from the
--     ordered local event plan.
--   * Touched side active windows require every event routed to that side. They
--     are rebuilt by a bounded full EventBlock pass; using only the Actor closure
--     could omit unrelated actors and falsely approve a local commit.
--   * Boss cumulative contributions are rebuilt from the hypothetical candidate
--     PVE-friendly target breakdowns. Historical target active time is not
--     available and remains intentionally rate-unavailable.
--   * identityProjection owns bounded persistent ActorId/TargetRef allocation.
--     A sparse compatibility delta cannot prove equivalent ID allocation or
--     identity-keyed breakdown removal, so the formal policy is
--     FULL_REBUILD_REQUIRED. This is a deliberate local-commit blocker.
--
-- Performance boundary
--   * Diagnostics must be enabled; otherwise no rebuild state is allocated.
--   * Every event/actor comparison advances with a fixed budget. No unbounded
--     history or actor-table scan runs in Tick or the combat callback.
------------------------------------------------------------------------

if ReplicatedDps == nil or ReplicatedDps.Boot == nil then return end

local D = ReplicatedDps
local Boot = D.Boot
if Boot.phase == "FAILED" then return end
if type(D.LocalStatsCandidate) ~= "table"
    or type(D.LocalStatsCandidate.SetDerivedStateObserver) ~= "function" then
    Boot:Fail("local_derived_shadow:local_stats_candidate",
        "D.LocalStatsCandidate derived observer boundary is unavailable")
    return
end
if type(D.EventBlocks) ~= "table" or type(D.EventBlocks.GetEventIdByPosition) ~= "function" then
    Boot:Fail("local_derived_shadow:event_blocks", "D.EventBlocks is unavailable")
    return
end
if type(D.EventClassifications) ~= "table"
    or type(D.EventClassifications.GetFromGeneration) ~= "function" then
    Boot:Fail("local_derived_shadow:event_classification",
        "D.EventClassifications generation boundary is unavailable")
    return
end
if type(D.Stats) ~= "table" or type(D.Util) ~= "table" then
    Boot:Fail("local_derived_shadow:core", "Stats/Util Authority is unavailable")
    return
end

Boot:SetPhase("LOCAL_DERIVED_SHADOW_LOADING")

local U = D.Util
local Stats = D.Stats
local Blocks = D.EventBlocks
local Classifications = D.EventClassifications
local Candidate = D.LocalStatsCandidate
local Store = D.EventStore

D.LocalDerivedShadow = D.LocalDerivedShadow or {}
local H = D.LocalDerivedShadow

H.schemaVersion = 1
H.layoutVersion = 1
H.defaultStepBudget = 320
H.identityPolicy = "FULL_REBUILD_REQUIRED"
H.maxMismatchSamples = 32

local EPSILON = 0.0000001
local SEP = string.char(31)
local VALID_MODES = { PVP = true, PVE = true }
local VALID_SIDES = { friendly = true, enemy = true }

local function Counter(name, amount)
    local counters = D.Diagnostics and D.Diagnostics.counters or nil
    if type(counters) ~= "table" then return end
    counters[name] = (tonumber(counters[name]) or 0) + (tonumber(amount) or 1)
end

local function NowMs()
    return type(U.NowMs) == "function" and U.NowMs() or 0
end

local function Finite(value, fallback)
    if type(U.FiniteNumber) == "function" then return U.FiniteNumber(value, fallback) end
    local number = tonumber(value)
    if number == nil or number ~= number or number == math.huge or number == -math.huge then
        return fallback
    end
    return number
end

local function NonEmpty(value)
    if value == nil then return nil end
    local text = tostring(value)
    if text == "" then return nil end
    return text
end

local function NewActive()
    return { total = 0, last = nil, startedAt = nil }
end

local function TouchActive(active, timestamp, windowMs)
    timestamp = Finite(timestamp, nil)
    if timestamp == nil then return false end
    windowMs = math.max(0, Finite(windowMs, 0) or 0)
    active.total = math.max(0, Finite(active.total, 0) or 0)
    if active.last == nil or active.startedAt == nil then
        active.startedAt = timestamp
        active.last = timestamp
        return true
    end
    local last = Finite(active.last, timestamp) or timestamp
    if timestamp - last > windowMs then
        local startedAt = Finite(active.startedAt, last) or last
        active.total = active.total + math.max(0, (last + windowMs) - startedAt)
        active.startedAt = timestamp
    end
    active.last = timestamp
    return true
end

local function ActiveEqual(left, right)
    left = type(left) == "table" and left or {}
    right = type(right) == "table" and right or {}
    local leftTotal = Finite(left.total, 0) or 0
    local rightTotal = Finite(right.total, 0) or 0
    if math.abs(leftTotal - rightTotal) > EPSILON then return false end
    local leftLast = Finite(left.last, nil)
    local rightLast = Finite(right.last, nil)
    if leftLast ~= rightLast then return false end
    local leftStart = Finite(left.startedAt, nil)
    local rightStart = Finite(right.startedAt, nil)
    return leftStart == rightStart
end

local function GenerationValue(generation, eventId, field)
    return Classifications:GetFromGeneration(generation, eventId, field)
end

local function ActiveToken(mode, sideName, actorKey, metric)
    return tostring(mode or "SHARED") .. SEP .. tostring(sideName or "") .. SEP
        .. tostring(actorKey or "") .. SEP .. tostring(metric or "")
end

local function RowToken(mode, sideName, actorKey)
    return tostring(mode or "SHARED") .. SEP .. tostring(sideName or "") .. SEP
        .. tostring(actorKey or "")
end

local function SideToken(mode, sideName, metric)
    return tostring(mode or "SHARED") .. SEP .. tostring(sideName or "") .. SEP
        .. tostring(metric or "")
end

local function RootSide(root, mode, sideName)
    if mode == nil then
        local shared = type(root) == "table" and root.sharedHealing or nil
        return type(shared) == "table" and shared[sideName] or nil
    end
    local modeRoot = type(root) == "table" and root[mode] or nil
    return type(modeRoot) == "table" and modeRoot[sideName] or nil
end

local function RootActor(root, mode, sideName, actorKey)
    local side = RootSide(root, mode, sideName)
    return type(side) == "table" and type(side.actors) == "table"
        and side.actors[actorKey] or nil
end

local function AddMismatch(job, reason, task, expected, actual)
    job.mismatchCount = job.mismatchCount + 1
    job.failureReason = job.failureReason or tostring(reason or "UNKNOWN")
    if #job.mismatches < H.maxMismatchSamples then
        job.mismatches[#job.mismatches + 1] = {
            reason = tostring(reason or "UNKNOWN"),
            mode = task and task.mode or nil,
            side = task and task.side or nil,
            actorKey = task and task.actorKey or nil,
            metric = task and task.metric or nil,
            expected = expected,
            actual = actual,
        }
    end
end

local function Fail(job, reason, task, expected, actual)
    AddMismatch(job, reason, task, expected, actual)
    job.safe = false
    job.localCommitReady = false
    job.phase = "FAILED"
    job.completedAt = NowMs()
    Counter("localDerivedFallbacks", 1)
    return false
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
    local currentBoss = type(analysis) == "table" and type(analysis.GetBossTarget) == "function"
        and analysis:GetBossTarget() or nil
    if currentBoss ~= job.bossAuthority then return false, "BOSS_TARGET_CHANGED" end
    return true
end

local function AddActorTask(job, mode, sideName, actorKey, metric)
    if metric == "kills" or not VALID_SIDES[sideName] then return end
    if mode ~= nil and not VALID_MODES[mode] then return end
    actorKey = NonEmpty(actorKey)
    if actorKey == nil then return end
    local token = ActiveToken(mode, sideName, actorKey, metric)
    if job.actorActiveByToken[token] == nil then
        local task = { mode = mode, side = sideName, actorKey = actorKey, metric = metric, token = token }
        job.actorTaskCount = job.actorTaskCount + 1
        job.actorTasks[job.actorTaskCount] = task
        job.actorActiveByToken[token] = NewActive()
    end
    local row = RowToken(mode, sideName, actorKey)
    if job.actorRowSeen[row] ~= true then
        job.actorRowSeen[row] = true
        job.actorRowCount = job.actorRowCount + 1
        job.actorRows[job.actorRowCount] = {
            mode = mode, side = sideName, actorKey = actorKey, token = row,
        }
        job.actorProvisionalByToken[row] = false
    end
end

local function AddSideTask(job, mode, sideName, metric)
    if metric == "kills" or not VALID_SIDES[sideName] then return end
    if mode ~= nil and not VALID_MODES[mode] then return end
    local token = SideToken(mode, sideName, metric)
    if job.sideActiveByToken[token] ~= nil then return end
    job.sideTaskCount = job.sideTaskCount + 1
    job.sideTasks[job.sideTaskCount] = {
        mode = mode, side = sideName, metric = metric, token = token,
    }
    job.sideActiveByToken[token] = NewActive()
end

local function MarkActorProvisional(job, mode, sideName, actorKey, provisional)
    if provisional ~= true or actorKey == nil then return end
    local token = RowToken(mode, sideName, actorKey)
    if job.actorRowSeen[token] == true then job.actorProvisionalByToken[token] = true end
end

local function TouchActor(job, mode, sideName, actorKey, metric, timestamp, provisional)
    if actorKey == nil then return end
    local token = ActiveToken(mode, sideName, actorKey, metric)
    local active = job.actorActiveByToken[token]
    if active ~= nil then
        local windowMs = D.State and D.State.config and D.State.config.personalWindowMs or 0
        TouchActive(active, timestamp, windowMs)
    end
    MarkActorProvisional(job, mode, sideName, actorKey, provisional)
end

local function TouchSide(job, mode, sideName, metric, timestamp)
    local token = SideToken(mode, sideName, metric)
    local active = job.sideActiveByToken[token]
    if active == nil then return end
    local windowMs = D.State and D.State.config and D.State.config.sideWindowMs or 0
    TouchActive(active, timestamp, windowMs)
end

local function ReadRoute(generation, eventId)
    local applied = select(1, GenerationValue(generation, eventId, "applied")) == true
    if not applied then return nil end
    local mode = select(1, GenerationValue(generation, eventId, "appliedMode"))
        or select(1, GenerationValue(generation, eventId, "candidateMode"))
    local sourceSide = select(1, GenerationValue(generation, eventId, "sourceProjectionSide"))
    local targetSide = select(1, GenerationValue(generation, eventId, "targetProjectionSide"))
    local sourceKey = NonEmpty(select(1, GenerationValue(generation, eventId, "sourceResolvedKey")))
    local targetKey = NonEmpty(select(1, GenerationValue(generation, eventId, "targetResolvedKey")))
    local provisional = select(1, GenerationValue(generation, eventId, "modeProvisional")) == true
    local category = select(1, Blocks:ReadFact(eventId, "category")) or "OTHER"
    local timestamp = select(1, Blocks:ReadFact(eventId, "timestamp"))
    return mode, sourceSide, targetSide, sourceKey, targetKey, provisional, category, timestamp
end

local function ApplyActorEvent(job, eventId)
    local mode, sourceSide, targetSide, sourceKey, targetKey, provisional, category, timestamp =
        ReadRoute(job.classificationGeneration, eventId)
    if mode == nil then return true end
    if category == "DAMAGE" then
        TouchActor(job, mode, sourceSide, sourceKey, "damage", timestamp, provisional)
        TouchActor(job, mode, targetSide, targetKey, "taken", timestamp, provisional)
    elseif category == "HEAL" then
        TouchActor(job, mode, sourceSide, sourceKey, "heal", timestamp, provisional)
        TouchActor(job, nil, sourceSide, sourceKey, "heal", timestamp, provisional)
    elseif category == "KILL" then
        MarkActorProvisional(job, mode, sourceSide, sourceKey, provisional)
    end
    return true
end

local function ApplySideEvent(job, eventId)
    local mode, sourceSide, targetSide, _, _, _, category, timestamp =
        ReadRoute(job.classificationGeneration, eventId)
    if mode == nil then return true end
    if category == "DAMAGE" then
        TouchSide(job, mode, sourceSide, "damage", timestamp)
        TouchSide(job, mode, targetSide, "taken", timestamp)
    elseif category == "HEAL" then
        TouchSide(job, mode, sourceSide, "heal", timestamp)
        TouchSide(job, nil, sourceSide, "heal", timestamp)
    end
    return true
end

local function StepActorEvents(job, budget)
    local used = 0
    while job.cursor <= job.eventCount and used < budget do
        local position = job.positions[job.cursor]
        local eventId = Blocks:GetEventIdByPosition(position)
        if eventId == nil then return used, Fail(job, "EVENT_POSITION_MISSING") end
        ApplyActorEvent(job, eventId)
        job.cursor = job.cursor + 1
        used = used + 1
    end
    if job.cursor > job.eventCount then
        job.phase = "SIDE_EVENTS"
        job.cursor = 1
    end
    return used, true
end

local function StepSideEvents(job, budget)
    local used = 0
    while job.cursor <= job.journalCount and used < budget do
        local eventId = Blocks:GetEventIdByPosition(job.cursor)
        if eventId == nil then return used, Fail(job, "SIDE_EVENT_POSITION_MISSING") end
        ApplySideEvent(job, eventId)
        job.cursor = job.cursor + 1
        used = used + 1
    end
    if job.cursor > job.journalCount then
        job.phase = "COMPARE_ACTOR_ACTIVE"
        job.cursor = 1
    end
    return used, true
end

local function StepCompareActorActive(job, budget)
    local used = 0
    while job.cursor <= job.actorTaskCount and used < budget do
        local task = job.actorTasks[job.cursor]
        local actor = RootActor(job.newRoot, task.mode, task.side, task.actorKey)
        local expected = actor and actor.active and actor.active[task.metric] or NewActive()
        local actual = job.actorActiveByToken[task.token]
        if not ActiveEqual(actual, expected) then
            return used, Fail(job, "ACTOR_ACTIVE_MISMATCH", task, expected, actual)
        end
        job.validatedActorActive = job.validatedActorActive + 1
        job.cursor = job.cursor + 1
        used = used + 1
    end
    if job.cursor > job.actorTaskCount then
        job.phase = "COMPARE_PROVISIONAL"
        job.cursor = 1
    end
    return used, true
end

local function StepCompareProvisional(job, budget)
    local used = 0
    while job.cursor <= job.actorRowCount and used < budget do
        local task = job.actorRows[job.cursor]
        local actor = RootActor(job.newRoot, task.mode, task.side, task.actorKey)
        local expected = type(actor) == "table" and actor.provisional == true or false
        local actual = job.actorProvisionalByToken[task.token] == true
        if expected ~= actual then
            return used, Fail(job, "ACTOR_PROVISIONAL_MISMATCH", task, expected, actual)
        end
        job.validatedProvisional = job.validatedProvisional + 1
        job.cursor = job.cursor + 1
        used = used + 1
    end
    if job.cursor > job.actorRowCount then
        job.phase = "COMPARE_SIDE_ACTIVE"
        job.cursor = 1
    end
    return used, true
end

local function StepCompareSideActive(job, budget)
    local used = 0
    while job.cursor <= job.sideTaskCount and used < budget do
        local task = job.sideTasks[job.cursor]
        local side = RootSide(job.newRoot, task.mode, task.side)
        local expected = side and side.active and side.active[task.metric] or NewActive()
        local actual = job.sideActiveByToken[task.token]
        if not ActiveEqual(actual, expected) then
            return used, Fail(job, "SIDE_ACTIVE_MISMATCH", task, expected, actual)
        end
        job.validatedSideActive = job.validatedSideActive + 1
        job.cursor = job.cursor + 1
        used = used + 1
    end
    if job.cursor > job.sideTaskCount then
        job.phase = "BOSS_OLD_ACTORS"
        job.cursorKey = nil
    end
    return used, true
end

local function TargetDamage(actor, normalizedTarget)
    local targets = actor and actor.details and actor.details.damage and actor.details.damage.targets or nil
    local total = 0
    for targetName, amount in pairs(type(targets) == "table" and targets or {}) do
        if U.NormalizeName(targetName) == normalizedTarget then
            total = total + math.max(0, Finite(amount, 0) or 0)
        end
    end
    return total
end

local function AddBossActor(job, actorKey, actor)
    if actorKey == nil or job.bossSeen[actorKey] == true then return end
    job.bossSeen[actorKey] = true
    local value = TargetDamage(actor, job.bossKey)
    if value > 0 then
        job.bossContributions[actorKey] = value
        job.bossTotal = job.bossTotal + value
    end
end

local function StepBossOldActors(job, budget)
    if job.bossAuthority == nil then
        job.bossValidated = true
        job.phase = "IDENTITY_GATE"
        return 1, true
    end
    local oldSide = RootSide(job.oldRoot, "PVE", "friendly")
    local oldActors = type(oldSide) == "table" and type(oldSide.actors) == "table" and oldSide.actors or {}
    local workingSide = job.candidate.working and job.candidate.working.PVE
        and job.candidate.working.PVE.friendly or nil
    local workingActors = type(workingSide) == "table" and type(workingSide.actors) == "table"
        and workingSide.actors or {}
    local used = 0
    while used < budget do
        local key, actor = next(oldActors, job.cursorKey)
        if key == nil then
            job.phase = "BOSS_WORKING_EXTRAS"
            job.cursorKey = nil
            break
        end
        job.cursorKey = key
        AddBossActor(job, key, workingActors[key] or actor)
        used = used + 1
    end
    return used, true
end

local function StepBossWorkingExtras(job, budget)
    local workingSide = job.candidate.working and job.candidate.working.PVE
        and job.candidate.working.PVE.friendly or nil
    local workingActors = type(workingSide) == "table" and type(workingSide.actors) == "table"
        and workingSide.actors or {}
    local oldSide = RootSide(job.oldRoot, "PVE", "friendly")
    local oldActors = type(oldSide) == "table" and type(oldSide.actors) == "table" and oldSide.actors or {}
    local used = 0
    while used < budget do
        local key, actor = next(workingActors, job.cursorKey)
        if key == nil then
            job.phase = "BOSS_COMPARE"
            job.cursorKey = nil
            break
        end
        job.cursorKey = key
        if oldActors[key] == nil then AddBossActor(job, key, actor) end
        used = used + 1
    end
    return used, true
end

local function StepBossCompare(job, budget)
    local authority = job.bossAuthority
    if authority == nil then
        job.bossValidated = true
        job.phase = "IDENTITY_GATE"
        return 1, true
    end
    local expected = type(authority.contributions) == "table" and authority.contributions or {}
    if job.bossComparePhase == nil then
        job.bossComparePhase = "EXPECTED"
        job.cursorKey = nil
    end
    local used = 0
    while used < budget do
        if job.bossComparePhase == "EXPECTED" then
            local key, value = next(expected, job.cursorKey)
            if key == nil then
                job.bossComparePhase = "ACTUAL"
                job.cursorKey = nil
            else
                job.cursorKey = key
                local actual = tonumber(job.bossContributions[key]) or 0
                if math.abs(actual - (tonumber(value) or 0)) > EPSILON then
                    return used, Fail(job, "BOSS_CONTRIBUTION_MISMATCH",
                        { actorKey = key, mode = "PVE", side = "friendly", metric = "damage" },
                        value, actual)
                end
                used = used + 1
            end
        elseif job.bossComparePhase == "ACTUAL" then
            local key, value = next(job.bossContributions, job.cursorKey)
            if key == nil then
                local expectedTotal = tonumber(authority.total) or 0
                if math.abs(job.bossTotal - expectedTotal) > EPSILON then
                    return used, Fail(job, "BOSS_TOTAL_MISMATCH",
                        { mode = "PVE", side = "friendly", metric = "damage" },
                        expectedTotal, job.bossTotal)
                end
                job.bossValidated = true
                job.phase = "IDENTITY_GATE"
                return used + 1, true
            end
            job.cursorKey = key
            local expectedValue = tonumber(expected[key]) or 0
            if math.abs((tonumber(value) or 0) - expectedValue) > EPSILON then
                return used, Fail(job, "BOSS_EXTRA_CONTRIBUTION",
                    { actorKey = key, mode = "PVE", side = "friendly", metric = "damage" },
                    expectedValue, value)
            end
            used = used + 1
        else
            return used, Fail(job, "INVALID_BOSS_COMPARE_PHASE")
        end
    end
    return used, true
end

local function StepIdentityGate(job)
    local projection = job.newRoot.identityProjection
    if type(projection) ~= "table" or tonumber(projection.schemaVersion) ~= 1 then
        return Fail(job, "IDENTITY_PROJECTION_UNAVAILABLE")
    end
    if projection.needsRebuild == true or projection.projectionState == "DEGRADED" then
        return Fail(job, "IDENTITY_PROJECTION_NOT_READY")
    end
    job.identityValidated = true
    job.identityPolicy = H.identityPolicy
    job.identityReason = "PERSISTENT_ID_ALLOCATION_AND_IDENTITY_BREAKDOWNS_REQUIRE_FULL_REBUILD"
    job.localCommitReady = false
    job.safe = true
    job.phase = "DONE"
    job.completedAt = NowMs()
    Counter("localDerivedVerified", 1)
    Counter("localDerivedIdentityRebuildRequired", 1)
    return true
end

local function FreshState(reason)
    H.enabled = false
    H.failed = false
    H.failure = nil
    H.current = nil
    H.last = nil
    H.lastResetReason = tostring(reason or "module_load")
end

FreshState("module_load")

function H:DisableAfterFailure(err)
    self.failed = true
    self.enabled = false
    self.failure = tostring(err or "unknown local derived-state failure")
    if type(self.current) == "table" then
        Fail(self.current, "MODULE_FAILURE")
        self.last = self.current
    end
    self.current = nil
    Counter("localDerivedFailures", 1)
    if D.Diagnostics ~= nil and type(D.Diagnostics.AddWarning) == "function" then
        D.Diagnostics:AddWarning("local_derived_shadow",
            "局部派生状态重建已停用：" .. self.failure)
    end
end

function H:OnDiagnosticsChanged(enabled)
    FreshState(enabled == true and "diagnostics_enabled" or "diagnostics_disabled")
    self.enabled = enabled == true
    return true
end

function H:OnPlanAborted(plan, reason)
    local job = self.current
    if type(job) == "table" and type(plan) == "table" and job.planId == plan.id then
        Fail(job, reason or "LOCAL_PLAN_ABORTED")
        self.last = job
    end
    self.current = nil
    return true
end

function H:BeginDerived(candidate, transaction, plan)
    if self.enabled ~= true or self.failed == true then return false, "MODULE_DISABLED" end
    if type(candidate) ~= "table" or candidate.safe == false then
        return false, "CANDIDATE_UNAVAILABLE"
    end
    if type(transaction) ~= "table" or type(plan) ~= "table"
        or candidate.planId ~= plan.id or transaction.planId ~= plan.id then
        return false, "PLAN_TRANSACTION_MISMATCH"
    end
    if type(candidate.newRoot) ~= "table" or D.State.stats ~= candidate.newRoot then
        return false, "NEW_ROOT_NOT_AUTHORITY"
    end
    if type(plan.positions) ~= "table" or type(plan.newClassificationGeneration) ~= "table" then
        return false, "EVENT_PLAN_UNAVAILABLE"
    end
    local analysis = D.Analysis
    local boss = type(analysis) == "table" and type(analysis.GetBossTarget) == "function"
        and analysis:GetBossTarget() or nil
    local job = {
        planId = plan.id,
        candidate = candidate,
        transaction = transaction,
        plan = plan,
        oldRoot = candidate.oldRoot,
        newRoot = candidate.newRoot,
        positions = plan.positions,
        eventCount = math.max(0, math.floor(tonumber(plan.eventCount) or 0)),
        classificationGeneration = plan.newClassificationGeneration,
        actorTasks = {}, actorTaskCount = 0, actorActiveByToken = {},
        actorRows = {}, actorRowCount = 0, actorRowSeen = {}, actorProvisionalByToken = {},
        sideTasks = {}, sideTaskCount = 0, sideActiveByToken = {},
        phase = "ACTOR_EVENTS", cursor = 1,
        validatedActorActive = 0, validatedProvisional = 0, validatedSideActive = 0,
        bossAuthority = boss,
        bossKey = boss and tostring(boss.key or "") or nil,
        bossContributions = {}, bossSeen = {}, bossTotal = 0, bossValidated = false,
        identityValidated = false, identityPolicy = H.identityPolicy,
        localCommitReady = false, safe = nil,
        mismatches = {}, mismatchCount = 0,
        journal = Store.sessionEvents,
        journalCount = #(Store.sessionEvents or {}),
        journalGeneration = tonumber(Store.identityGeneration) or 0,
        blockGeneration = Blocks.committed,
        statsMutationRevision = tonumber(Stats.statsMutationRevision) or 0,
        breakdownMutationRevision = tonumber(Stats.breakdownMutationRevision) or 0,
        rankingStructureRevision = tonumber(Stats.rankingStructureRevision) or 0,
        analysisRoot = analysis,
        analysisRevision = tonumber(analysis and analysis.revision) or 0,
        startedAt = NowMs(),
    }
    if Classifications:CommittedGeneration() ~= job.classificationGeneration then
        return false, "CLASSIFICATION_NOT_CURRENT"
    end
    if tonumber(job.blockGeneration and job.blockGeneration.eventCount) ~= job.journalCount then
        return false, "EVENT_BLOCK_JOURNAL_COUNT_MISMATCH"
    end
    for index = 1, math.max(0, math.floor(tonumber(candidate.actorTaskCount) or 0)) do
        local task = candidate.actorTasks[index]
        if type(task) == "table" then
            AddActorTask(job, task.mode, task.side, task.actorKey, task.metric)
        end
    end
    for index = 1, math.max(0, math.floor(tonumber(candidate.sideTaskCount) or 0)) do
        local task = candidate.sideTasks[index]
        if type(task) == "table" then AddSideTask(job, task.mode, task.side, task.metric) end
    end
    self.current = job
    self.last = job
    Counter("localDerivedTransactions", 1)
    return true
end

function H:StepDerived(candidate, transaction, plan, budget)
    local job = self.current
    if self.enabled ~= true or self.failed == true then
        return true, false, "MODULE_DISABLED", nil
    end
    if type(job) ~= "table" or type(candidate) ~= "table" or type(plan) ~= "table"
        or job.planId ~= plan.id or job.candidate ~= candidate or job.transaction ~= transaction then
        return true, false, "DERIVED_JOB_NOT_FOUND", nil
    end
    local ok, reason = RevisionsMatch(job)
    if not ok then Fail(job, reason) end
    local remaining = math.max(1, math.floor(tonumber(budget) or self.defaultStepBudget))
    while remaining > 0 and job.phase ~= "DONE" and job.phase ~= "FAILED" do
        local used = 0
        if job.phase == "ACTOR_EVENTS" then used = select(1, StepActorEvents(job, remaining))
        elseif job.phase == "SIDE_EVENTS" then used = select(1, StepSideEvents(job, remaining))
        elseif job.phase == "COMPARE_ACTOR_ACTIVE" then used = select(1, StepCompareActorActive(job, remaining))
        elseif job.phase == "COMPARE_PROVISIONAL" then used = select(1, StepCompareProvisional(job, remaining))
        elseif job.phase == "COMPARE_SIDE_ACTIVE" then used = select(1, StepCompareSideActive(job, remaining))
        elseif job.phase == "BOSS_OLD_ACTORS" then used = select(1, StepBossOldActors(job, remaining))
        elseif job.phase == "BOSS_WORKING_EXTRAS" then used = select(1, StepBossWorkingExtras(job, remaining))
        elseif job.phase == "BOSS_COMPARE" then used = select(1, StepBossCompare(job, remaining))
        elseif job.phase == "IDENTITY_GATE" then
            StepIdentityGate(job)
            used = 1
        else
            Fail(job, "INVALID_PHASE:" .. tostring(job.phase))
        end
        remaining = remaining - math.max(1, used)
    end
    if job.phase == "DONE" or job.phase == "FAILED" then
        local summary = {
            phase = job.phase,
            safe = job.safe == true,
            localCommitReady = job.localCommitReady == true,
            failureReason = job.failureReason,
            mismatchCount = job.mismatchCount,
            mismatches = job.mismatches,
            actorTaskCount = job.actorTaskCount,
            actorRowCount = job.actorRowCount,
            sideTaskCount = job.sideTaskCount,
            validatedActorActive = job.validatedActorActive,
            validatedProvisional = job.validatedProvisional,
            validatedSideActive = job.validatedSideActive,
            bossSelected = job.bossAuthority ~= nil,
            bossValidated = job.bossValidated == true,
            bossActorCount = (function()
                local count = 0
                for _ in pairs(job.bossContributions) do count = count + 1 end
                return count
            end)(),
            bossTotal = job.bossTotal,
            identityValidated = job.identityValidated == true,
            identityPolicy = job.identityPolicy,
            identityReason = job.identityReason,
        }
        self.last = job
        self.current = nil
        return true, summary.safe, summary.failureReason, summary
    end
    return false, nil, nil, nil
end

function H:GetLastSummary()
    local job = self.current or self.last
    if type(job) ~= "table" then return nil end
    return {
        phase = job.phase,
        safe = job.safe == true,
        localCommitReady = job.localCommitReady == true,
        failureReason = job.failureReason,
        actorTaskCount = job.actorTaskCount or 0,
        sideTaskCount = job.sideTaskCount or 0,
        validatedActorActive = job.validatedActorActive or 0,
        validatedProvisional = job.validatedProvisional or 0,
        validatedSideActive = job.validatedSideActive or 0,
        bossValidated = job.bossValidated == true,
        identityValidated = job.identityValidated == true,
        identityPolicy = job.identityPolicy or self.identityPolicy,
    }
end

function H:GetStatusLine()
    if self.enabled ~= true then
        if self.failed == true then return "局部派生状态：已停用（故障）" end
        return "局部派生状态：关闭（诊断模式启用）"
    end
    local job = self.current or self.last
    if type(job) ~= "table" then
        return "局部派生状态：等待候选 / Identity=完整重建"
    end
    return "局部派生状态 #" .. tostring(job.planId or 0)
        .. " / " .. tostring(job.phase or "UNKNOWN")
        .. " / ActorActive " .. tostring(job.validatedActorActive or 0)
        .. "/" .. tostring(job.actorTaskCount or 0)
        .. " / Provisional " .. tostring(job.validatedProvisional or 0)
        .. "/" .. tostring(job.actorRowCount or 0)
        .. " / SideActive " .. tostring(job.validatedSideActive or 0)
        .. "/" .. tostring(job.sideTaskCount or 0)
        .. " / Boss=" .. tostring(job.bossValidated == true and "通过" or "待验证")
        .. " / Identity=" .. tostring(job.identityPolicy or self.identityPolicy)
        .. (job.failureReason ~= nil and (" / " .. tostring(job.failureReason)) or "")
end

local counters = D.Diagnostics and D.Diagnostics.counters or nil
if type(counters) == "table" then
    counters.localDerivedTransactions = tonumber(counters.localDerivedTransactions) or 0
    counters.localDerivedVerified = tonumber(counters.localDerivedVerified) or 0
    counters.localDerivedIdentityRebuildRequired =
        tonumber(counters.localDerivedIdentityRebuildRequired) or 0
    counters.localDerivedFallbacks = tonumber(counters.localDerivedFallbacks) or 0
    counters.localDerivedFailures = tonumber(counters.localDerivedFailures) or 0
end

Candidate:SetDerivedStateObserver(H)
if D.State ~= nil and D.State.config ~= nil and D.State.config.diagnosticsEnabled == true then
    local ok, err = pcall(H.OnDiagnosticsChanged, H, true)
    if not ok then H:DisableAfterFailure(err) end
end

Boot:CompletePhase("LOCAL_DERIVED_SHADOW_READY")

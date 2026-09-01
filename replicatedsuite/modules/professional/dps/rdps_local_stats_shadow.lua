ReplicatedSuiteModuleSandbox:Enter('dps', {'ReplicatedDps', 'ReplicatedDpsConfig'})
------------------------------------------------------------------------
-- Replicated DPS - diagnostic local Stats undo/reproject transaction
-- Author: Replicated
--
-- Authority boundary
--   * D.State.stats remains the production Stats Authority.
--   * D.LocalReplayPlanner owns the affected Actor/event closure and ordered
--     position plan, but never writes product Stats.
--   * This module builds a sparse numeric transaction from the authoritative
--     old/new EventClassification generations, then compares that transaction
--     with the Stats root committed by the existing full replay.
--   * No result produced here is committed to rankings, Boss, persistence or UI.
--
-- Transaction model
--   1. WITHDRAW_OLD: subtract every old contribution in ordered event sequence.
--   2. APPLY_NEW: add every new contribution in the same sequence.
--   3. COMPARE: verify oldValue + sparseDelta == authoritative newValue for
--      side totals, actor metrics, abilities and target/source breakdowns.
--
-- Deliberate exclusions
--   * active-window timing, provisional flags and derived Boss caches are not
--     algebraically reversible from one sparse event plan. They remain guarded
--     by the production full replay and are not claimed equivalent here.
--   * Stats v3 identityProjection uses bounded TargetRef dictionaries whose ID
--     allocation is a separate migration concern. This stage verifies the
--     product PVP/PVE compatibility projection and independent SharedHealing.
--
-- Performance boundary
--   * Diagnostics must be enabled; otherwise no transaction or path ledger is
--     allocated.
--   * Processing is budgeted by event/path count. No complete journal or Stats
--     tree scan occurs in Tick or the combat callback.
------------------------------------------------------------------------

if ReplicatedDps == nil or ReplicatedDps.Boot == nil then return end

local D = ReplicatedDps
local Boot = D.Boot
if Boot.phase == "FAILED" then return end
if type(D.EventBlocks) ~= "table" or type(D.EventBlocks.ReadFact) ~= "function" then
    Boot:Fail("local_stats_shadow:event_blocks", "D.EventBlocks is unavailable")
    return
end
if type(D.EventClassifications) ~= "table"
    or type(D.EventClassifications.GetFromGeneration) ~= "function" then
    Boot:Fail("local_stats_shadow:event_classification",
        "D.EventClassifications generation boundary is unavailable")
    return
end
if type(D.LocalReplayPlanner) ~= "table"
    or type(D.LocalReplayPlanner.SetStatsShadowObserver) ~= "function" then
    Boot:Fail("local_stats_shadow:local_replay",
        "D.LocalReplayPlanner observer boundary is unavailable")
    return
end
if type(D.Util) ~= "table" then
    Boot:Fail("local_stats_shadow:util", "D.Util is unavailable")
    return
end

Boot:SetPhase("LOCAL_STATS_SHADOW_LOADING")

local U = D.Util
local Blocks = D.EventBlocks
local Classifications = D.EventClassifications
local LocalReplay = D.LocalReplayPlanner

D.LocalStatsShadow = D.LocalStatsShadow or {}
local T = D.LocalStatsShadow

T.schemaVersion = 1
T.layoutVersion = 1
T.defaultPathLimit = 250000
T.defaultStepBudget = 320
T.maxMismatchSamples = 32
T.commitCandidateObserver = nil

local VALID_MODES = { PVP = true, PVE = true }
local VALID_SIDES = { friendly = true, enemy = true }
local VALID_METRICS = { damage = true, taken = true, heal = true, kills = true }
local SEP = string.char(31)


local function NotifyCommitCandidate(methodName, ...)
    local observer = T.commitCandidateObserver
    local method = type(observer) == "table" and observer[methodName] or nil
    if type(method) ~= "function" or observer.failed == true then
        return nil, "LOCAL_STATS_CANDIDATE_UNAVAILABLE"
    end
    local ok, first, second, third, fourth = pcall(method, observer, ...)
    if not ok then
        if type(observer.DisableAfterFailure) == "function" then
            pcall(observer.DisableAfterFailure, observer, first)
        end
        return nil, "LOCAL_STATS_CANDIDATE_FAILURE:" .. tostring(first)
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
    text = string.gsub(text, "^%s+", "")
    text = string.gsub(text, "%s+$", "")
    if text == "" then return nil end
    return text
end

local function BreakdownKey(value, fallback)
    local text = tostring(value or "")
    if text == "" then return fallback or "未知" end
    return text
end

local function GenerationValue(generation, eventId, field)
    return Classifications:GetFromGeneration(generation, eventId, field)
end

local function ReadActor(root, mode, sideName, actorKey)
    local modeRoot = type(root) == "table" and root[mode] or nil
    local side = type(modeRoot) == "table" and modeRoot[sideName] or nil
    return type(side) == "table" and type(side.actors) == "table"
        and side.actors[actorKey] or nil
end

local function ReadLegacyPath(root, entry)
    local modeRoot = type(root) == "table" and root[entry.mode] or nil
    local side = type(modeRoot) == "table" and modeRoot[entry.side] or nil
    if entry.kind == "LEGACY_SIDE_TOTAL" then
        return tonumber(side and side.totals and side.totals[entry.metric]) or 0
    end
    local actor = type(side) == "table" and type(side.actors) == "table"
        and side.actors[entry.actorKey] or nil
    if entry.kind == "LEGACY_ACTOR_METRIC" then
        return tonumber(actor and actor[entry.metric]) or 0
    end
    local details = actor and actor.details and actor.details[entry.metric] or nil
    if entry.kind == "LEGACY_ABILITY" then
        return tonumber(details and details.abilities and details.abilities[entry.detailKey]) or 0
    end
    local map = entry.metric == "taken" and details and details.sources
        or details and details.targets
    return tonumber(map and map[entry.detailKey]) or 0
end

local function ReadSharedPath(root, entry)
    local shared = type(root) == "table" and root.sharedHealing or nil
    local side = type(shared) == "table" and shared[entry.side] or nil
    if entry.kind == "SHARED_SIDE_TOTAL" then
        return tonumber(side and side.totals and side.totals.heal) or 0
    end
    local actor = type(side) == "table" and type(side.actors) == "table"
        and side.actors[entry.actorKey] or nil
    if entry.kind == "SHARED_ACTOR_METRIC" then
        return tonumber(actor and actor.heal) or 0
    end
    local details = actor and actor.details and actor.details.heal or nil
    local map = entry.kind == "SHARED_ABILITY" and details and details.abilities
        or details and details.targets
    return tonumber(map and map[entry.detailKey]) or 0
end

local function ReadPath(root, entry)
    if string.sub(entry.kind, 1, 7) == "SHARED_" then
        return ReadSharedPath(root, entry)
    end
    return ReadLegacyPath(root, entry)
end

local function PathToken(kind, mode, sideName, actorKey, metric, detailKey)
    -- Direct concatenation avoids allocating one temporary array for every path
    -- touched by every planned event. The resulting key is transient but the
    -- path ledger retains only one interned entry per distinct numeric path.
    return tostring(kind or "") .. SEP .. tostring(mode or "") .. SEP
        .. tostring(sideName or "") .. SEP .. tostring(actorKey or "") .. SEP
        .. tostring(metric or "") .. SEP .. tostring(detailKey or "")
end

local function FailTransaction(transaction, reason)
    transaction.safe = false
    transaction.failureReason = tostring(reason or "UNKNOWN")
    transaction.phase = "FAILED"
    transaction.completedAt = NowMs()
    Counter("localStatsShadowFallbacks", 1)
    return false
end

local function AddPath(transaction, kind, mode, sideName, actorKey, metric, detailKey, delta)
    if mode ~= nil and not VALID_MODES[mode] then
        return FailTransaction(transaction, "INVALID_MODE:" .. tostring(mode))
    end
    if not VALID_SIDES[sideName] then
        return FailTransaction(transaction, "INVALID_SIDE:" .. tostring(sideName))
    end
    if metric ~= nil and not VALID_METRICS[metric] then
        return FailTransaction(transaction, "INVALID_METRIC:" .. tostring(metric))
    end
    actorKey = actorKey ~= nil and tostring(actorKey) or nil
    detailKey = detailKey ~= nil and tostring(detailKey) or nil
    local token = PathToken(kind, mode, sideName, actorKey, metric, detailKey)
    local entry = transaction.entryByToken[token]
    if entry == nil then
        if transaction.entryCount >= transaction.pathLimit then
            return FailTransaction(transaction, "PATH_LIMIT_EXCEEDED")
        end
        entry = {
            kind = kind,
            mode = mode,
            side = sideName,
            actorKey = actorKey,
            metric = metric,
            detailKey = detailKey,
            delta = 0,
        }
        transaction.entryCount = transaction.entryCount + 1
        transaction.entries[transaction.entryCount] = entry
        transaction.entryByToken[token] = entry
    end
    entry.delta = (tonumber(entry.delta) or 0) + (tonumber(delta) or 0)
    return true
end

local function SharedBucket(root, sideName, actorKey, mapName, requestedKey)
    local shared = type(root) == "table" and root.sharedHealing or nil
    local side = type(shared) == "table" and shared[sideName] or nil
    local actor = type(side) == "table" and type(side.actors) == "table"
        and side.actors[actorKey] or nil
    local details = actor and actor.details and actor.details.heal or nil
    local map = type(details) == "table" and details[mapName] or nil
    if type(map) == "table" then
        if map[requestedKey] ~= nil then return requestedKey end
        if map.__other__ ~= nil then return "__other__" end
    end
    return requestedKey
end

local function AddLegacyMetric(transaction, mode, sideName, actorKey, metric,
    amount, abilityName, counterpartName)
    if actorKey == nil or actorKey == "" then
        return FailTransaction(transaction, "MISSING_ACTOR_KEY:" .. tostring(metric))
    end
    if not AddPath(transaction, "LEGACY_SIDE_TOTAL", mode, sideName,
        nil, metric, nil, amount) then return false end
    if not AddPath(transaction, "LEGACY_ACTOR_METRIC", mode, sideName,
        actorKey, metric, nil, amount) then return false end
    if not AddPath(transaction, "LEGACY_ABILITY", mode, sideName,
        actorKey, metric, abilityName, amount) then return false end
    return AddPath(transaction, "LEGACY_COUNTERPART", mode, sideName,
        actorKey, metric, counterpartName, amount)
end

local function AddSharedHealing(transaction, root, sideName, actorKey, amount,
    abilityName, targetName)
    if actorKey == nil or actorKey == "" then
        return FailTransaction(transaction, "MISSING_SHARED_HEAL_ACTOR_KEY")
    end
    local abilityBucket = SharedBucket(root, sideName, actorKey, "abilities", abilityName)
    local targetBucket = SharedBucket(root, sideName, actorKey, "targets", targetName)
    if not AddPath(transaction, "SHARED_SIDE_TOTAL", nil, sideName,
        nil, "heal", nil, amount) then return false end
    if not AddPath(transaction, "SHARED_ACTOR_METRIC", nil, sideName,
        actorKey, "heal", nil, amount) then return false end
    if not AddPath(transaction, "SHARED_ABILITY", nil, sideName,
        actorKey, "heal", abilityBucket, amount) then return false end
    return AddPath(transaction, "SHARED_TARGET", nil, sideName,
        actorKey, "heal", targetBucket, amount)
end

local function ApplyEventContribution(transaction, generation, root, eventId, sign)
    local applied = select(1, GenerationValue(generation, eventId, "applied")) == true
    if not applied then return true end
    local mode = select(1, GenerationValue(generation, eventId, "appliedMode"))
        or select(1, GenerationValue(generation, eventId, "candidateMode"))
    local sourceSide = select(1, GenerationValue(generation, eventId, "sourceProjectionSide"))
    local targetSide = select(1, GenerationValue(generation, eventId, "targetProjectionSide"))
    local sourceKey = NonEmpty(select(1,
        GenerationValue(generation, eventId, "sourceResolvedKey")))
    local targetKey = NonEmpty(select(1,
        GenerationValue(generation, eventId, "targetResolvedKey")))
    local category = select(1, Blocks:ReadFact(eventId, "category")) or "OTHER"

    -- Applied-but-nonprojected rows include ignored, expired, environmental,
    -- invalid-amount and diagnostic-only events. The absence of projection sides
    -- is the authoritative signal that no numeric Stats contribution exists.
    if sourceSide == nil and targetSide == nil then return true end
    if not VALID_MODES[mode] then
        return FailTransaction(transaction, "MISSING_APPLIED_MODE:" .. tostring(eventId))
    end

    local amount = category == "KILL" and 1
        or math.max(0, Finite(select(1, Blocks:ReadFact(eventId, "amount")), 0) or 0)
    amount = amount * sign
    local abilityName = BreakdownKey(select(1, Blocks:ReadFact(eventId, "abilityName")),
        category == "KILL" and "未知技能" or "未知")
    local sourceName = BreakdownKey(select(1, Blocks:ReadFact(eventId, "sourceName")), "未知")
    local targetName = BreakdownKey(select(1, Blocks:ReadFact(eventId, "targetName")),
        category == "KILL" and "未知目标" or "未知")

    if category == "DAMAGE" then
        if not VALID_SIDES[sourceSide] or not VALID_SIDES[targetSide] then
            return FailTransaction(transaction, "MISSING_DAMAGE_ROUTE:" .. tostring(eventId))
        end
        if not AddLegacyMetric(transaction, mode, sourceSide, sourceKey, "damage",
            amount, abilityName, targetName) then return false end
        return AddLegacyMetric(transaction, mode, targetSide, targetKey, "taken",
            amount, abilityName, sourceName)
    end
    if category == "HEAL" then
        if not VALID_SIDES[sourceSide] then
            return FailTransaction(transaction, "MISSING_HEAL_ROUTE:" .. tostring(eventId))
        end
        if not AddLegacyMetric(transaction, mode, sourceSide, sourceKey, "heal",
            amount, abilityName, targetName) then return false end
        return AddSharedHealing(transaction, root, sourceSide, sourceKey,
            amount, abilityName, targetName)
    end
    if category == "KILL" then
        if not VALID_SIDES[sourceSide] then
            return FailTransaction(transaction, "MISSING_KILL_ROUTE:" .. tostring(eventId))
        end
        return AddLegacyMetric(transaction, mode, sourceSide, sourceKey, "kills",
            amount, abilityName, targetName)
    end
    return true
end

local function FreshState(reason, preserveEnabled)
    local enabled = preserveEnabled == true and T.enabled == true
    T.enabled = enabled
    T.failed = false
    T.failure = nil
    T.current = nil
    T.last = nil
    T.lastResetReason = tostring(reason or "module_load")
end

FreshState("module_load", false)

function T:DisableAfterFailure(err)
    self.failed = true
    self.enabled = false
    self.failure = tostring(err or "unknown local Stats shadow failure")
    if type(self.current) == "table" then
        FailTransaction(self.current, "MODULE_FAILURE")
        self.last = self.current
    end
    self.current = nil
    Counter("localStatsShadowFailures", 1)
    if D.Diagnostics ~= nil and type(D.Diagnostics.AddWarning) == "function" then
        D.Diagnostics:AddWarning("local_stats_shadow",
            "局部 Stats 影子事务已停用：" .. self.failure)
    end
end

function T:SetCommitCandidateObserver(observer)
    if observer ~= nil and type(observer) ~= "table" then return false end
    self.commitCandidateObserver = observer
    return true
end

function T:OnDiagnosticsChanged(enabled)
    FreshState(enabled == true and "diagnostics_enabled" or "diagnostics_disabled", false)
    self.enabled = enabled == true
    NotifyCommitCandidate("OnDiagnosticsChanged", enabled == true)
end

function T:OnFullReplayBegin(plan, oldRoot)
    if self.enabled ~= true or self.failed == true or type(plan) ~= "table" then return false end
    if type(oldRoot) ~= "table" or tonumber(oldRoot.schemaVersion) ~= 3 then return false end
    self.current = {
        planId = plan.id,
        oldRoot = oldRoot,
        newRoot = nil,
        phase = "WAIT_CLASSIFICATION_AUDIT",
        startedAt = NowMs(),
    }
    return true
end

function T:OnFullReplayCommitted(plan, newRoot)
    local transaction = self.current
    if self.enabled ~= true or self.failed == true or type(transaction) ~= "table"
        or type(plan) ~= "table" or transaction.planId ~= plan.id then return false end
    if type(newRoot) ~= "table" or tonumber(newRoot.schemaVersion) ~= 3 then
        return FailTransaction(transaction, "INVALID_NEW_STATS_ROOT")
    end
    transaction.newRoot = newRoot
    return true
end


function T:OnPlanAborted(plan, reason)
    local transaction = self.current
    if type(transaction) == "table" and type(plan) == "table"
        and transaction.planId == plan.id then
        transaction.phase = "ABORTED"
        transaction.safe = false
        transaction.failureReason = tostring(reason or "LOCAL_PLAN_ABORTED")
        transaction.completedAt = NowMs()
        NotifyCommitCandidate("OnPlanAborted", plan, transaction.failureReason)
        self.last = transaction
        self.current = nil
    end
    return true
end

function T:OnFullReplayRolledBack(plan, reason)
    local transaction = self.current
    if type(transaction) == "table" and type(plan) == "table"
        and transaction.planId == plan.id then
        transaction.phase = "ROLLED_BACK"
        transaction.safe = false
        transaction.failureReason = tostring(reason or "FULL_REPLAY_ROLLED_BACK")
        transaction.completedAt = NowMs()
        NotifyCommitCandidate("OnPlanAborted", plan, transaction.failureReason)
        self.last = transaction
    end
    self.current = nil
    return true
end

function T:BeginProjectionTransaction(plan, options)
    local transaction = self.current
    if self.enabled ~= true or self.failed == true then return false, "MODULE_DISABLED" end
    if type(transaction) ~= "table" or type(plan) ~= "table"
        or transaction.planId ~= plan.id then return false, "TRANSACTION_NOT_CAPTURED" end
    if type(transaction.oldRoot) ~= "table" or type(transaction.newRoot) ~= "table" then
        return false, "STATS_ROOT_UNAVAILABLE"
    end
    if type(plan.oldClassificationGeneration) ~= "table"
        or type(plan.newClassificationGeneration) ~= "table" then
        return false, "CLASSIFICATION_GENERATION_UNAVAILABLE"
    end
    options = type(options) == "table" and options or {}
    transaction.plan = plan
    transaction.oldGeneration = plan.oldClassificationGeneration
    transaction.newGeneration = plan.newClassificationGeneration
    transaction.positions = plan.positions
    transaction.eventCount = math.max(0, math.floor(tonumber(plan.eventCount) or 0))
    transaction.pathLimit = math.max(1, math.floor(tonumber(options.pathLimit)
        or self.defaultPathLimit))
    transaction.phase = "WITHDRAW_OLD"
    transaction.cursor = 1
    transaction.entries = {}
    transaction.entryByToken = {}
    transaction.entryCount = 0
    transaction.compared = 0
    transaction.mismatches = 0
    transaction.firstMismatches = {}
    transaction.safe = nil
    transaction.failureReason = nil
    Counter("localStatsShadowTransactions", 1)
    return true
end

local function StepContribution(transaction, generation, root, sign, budget)
    local processed = 0
    while transaction.cursor <= transaction.eventCount and processed < budget do
        local position = transaction.positions[transaction.cursor]
        local eventId = Blocks:GetEventIdByPosition(position)
        if eventId == nil then
            FailTransaction(transaction, "EVENT_POSITION_MISSING:" .. tostring(position))
            return processed
        end
        if not ApplyEventContribution(transaction, generation, root, eventId, sign) then
            return processed
        end
        transaction.cursor = transaction.cursor + 1
        processed = processed + 1
    end
    return processed
end

local function StepCompare(transaction, budget)
    local processed = 0
    while transaction.cursor <= transaction.entryCount and processed < budget do
        local entry = transaction.entries[transaction.cursor]
        local oldValue = ReadPath(transaction.oldRoot, entry)
        local newValue = ReadPath(transaction.newRoot, entry)
        local expected = oldValue + (tonumber(entry.delta) or 0)
        entry.oldValue = oldValue
        entry.expectedValue = expected
        entry.newValue = newValue
        local difference = math.abs(newValue - expected)
        if difference > 0.0000001 then
            transaction.mismatches = transaction.mismatches + 1
            if #transaction.firstMismatches < T.maxMismatchSamples then
                transaction.firstMismatches[#transaction.firstMismatches + 1] = {
                    kind = entry.kind,
                    mode = entry.mode,
                    side = entry.side,
                    actorKey = entry.actorKey,
                    metric = entry.metric,
                    detailKey = entry.detailKey,
                    oldValue = oldValue,
                    delta = entry.delta,
                    expected = expected,
                    actual = newValue,
                }
            end
        end
        transaction.cursor = transaction.cursor + 1
        transaction.compared = transaction.compared + 1
        processed = processed + 1
    end
    return processed
end

function T:StepProjectionTransaction(plan, budget)
    local transaction = self.current
    if self.enabled ~= true or self.failed == true then
        return true, false, "MODULE_DISABLED", nil
    end
    if type(transaction) ~= "table" or type(plan) ~= "table"
        or transaction.planId ~= plan.id then
        return true, false, "TRANSACTION_NOT_FOUND", nil
    end
    local remaining = math.max(1, math.floor(tonumber(budget) or self.defaultStepBudget))
    while remaining > 0 and transaction.phase ~= "DONE" and transaction.phase ~= "FAILED" do
        if transaction.phase == "WITHDRAW_OLD" then
            local used = StepContribution(transaction, transaction.oldGeneration,
                transaction.oldRoot, -1, remaining)
            remaining = remaining - math.max(1, used)
            if transaction.phase == "FAILED" then break end
            if transaction.cursor > transaction.eventCount then
                transaction.phase = "APPLY_NEW"
                transaction.cursor = 1
            end
        elseif transaction.phase == "APPLY_NEW" then
            local used = StepContribution(transaction, transaction.newGeneration,
                transaction.newRoot, 1, remaining)
            remaining = remaining - math.max(1, used)
            if transaction.phase == "FAILED" then break end
            if transaction.cursor > transaction.eventCount then
                transaction.phase = "COMPARE"
                transaction.cursor = 1
            end
        elseif transaction.phase == "COMPARE" then
            local used = StepCompare(transaction, remaining)
            remaining = remaining - math.max(1, used)
            if transaction.cursor > transaction.entryCount then
                transaction.safe = transaction.mismatches == 0
                if transaction.safe then
                    Counter("localStatsShadowEquivalent", 1)
                    local started, reason = NotifyCommitCandidate(
                        "BeginCandidate", transaction, plan)
                    if started == true then
                        transaction.phase = "COMMIT_GATE"
                    else
                        FailTransaction(transaction,
                            reason or "LOCAL_STATS_CANDIDATE_UNAVAILABLE")
                    end
                else
                    transaction.failureReason = "STATS_PATH_MISMATCH"
                    transaction.phase = "DONE"
                    transaction.completedAt = NowMs()
                    Counter("localStatsShadowMismatches", transaction.mismatches)
                end
            end
        elseif transaction.phase == "COMMIT_GATE" then
            local done, safe, reason, summary = NotifyCommitCandidate(
                "StepCandidate", transaction, plan, remaining)
            remaining = 0
            if done == true then
                transaction.commitCandidate = summary
                if safe == true then
                    transaction.safe = true
                    transaction.phase = "DONE"
                    transaction.completedAt = NowMs()
                else
                    FailTransaction(transaction,
                        reason or "LOCAL_STATS_CANDIDATE_REJECTED")
                end
            end
        else
            FailTransaction(transaction, "INVALID_PHASE:" .. tostring(transaction.phase))
        end
    end

    if transaction.phase == "DONE" or transaction.phase == "FAILED" then
        local summary = {
            phase = transaction.phase,
            safe = transaction.safe == true,
            failureReason = transaction.failureReason,
            eventCount = transaction.eventCount or 0,
            pathCount = transaction.entryCount or 0,
            compared = transaction.compared or 0,
            mismatches = transaction.mismatches or 0,
            firstMismatches = transaction.firstMismatches,
            commitCandidate = transaction.commitCandidate,
        }
        self.last = transaction
        self.current = nil
        return true, summary.safe, summary.failureReason, summary
    end
    return false, nil, nil, nil
end

function T:GetLastSummary()
    local transaction = self.current or self.last
    if type(transaction) ~= "table" then return nil end
    return {
        phase = transaction.phase,
        safe = transaction.safe == true,
        failureReason = transaction.failureReason,
        eventCount = transaction.eventCount or 0,
        pathCount = transaction.entryCount or 0,
        compared = transaction.compared or 0,
        mismatches = transaction.mismatches or 0,
        firstMismatches = transaction.firstMismatches,
        commitCandidate = transaction.commitCandidate,
    }
end

function T:GetStatusLine()
    if self.enabled ~= true then
        if self.failed == true then return "局部 Stats 影子：已停用（故障）" end
        return "局部 Stats 影子：关闭（诊断模式启用）"
    end
    local transaction = self.current or self.last
    if type(transaction) ~= "table" then return "局部 Stats 影子：等待安全闭包样本" end
    return "局部 Stats 影子 #" .. tostring(transaction.planId or 0)
        .. " / " .. tostring(transaction.phase or "UNKNOWN")
        .. " / 事件 " .. tostring(transaction.eventCount or 0)
        .. " / 路径 " .. tostring(transaction.entryCount or 0)
        .. " / 不一致 " .. tostring(transaction.mismatches or 0)
        .. (transaction.failureReason ~= nil
            and (" / " .. tostring(transaction.failureReason)) or "")
end

local counters = D.Diagnostics and D.Diagnostics.counters or nil
if type(counters) == "table" then
    counters.localStatsShadowTransactions = tonumber(counters.localStatsShadowTransactions) or 0
    counters.localStatsShadowEquivalent = tonumber(counters.localStatsShadowEquivalent) or 0
    counters.localStatsShadowMismatches = tonumber(counters.localStatsShadowMismatches) or 0
    counters.localStatsShadowFallbacks = tonumber(counters.localStatsShadowFallbacks) or 0
    counters.localStatsShadowFailures = tonumber(counters.localStatsShadowFailures) or 0
end

LocalReplay:SetStatsShadowObserver(T)
if D.State ~= nil and D.State.config ~= nil and D.State.config.diagnosticsEnabled == true then
    local ok, err = pcall(T.OnDiagnosticsChanged, T, true)
    if not ok then T:DisableAfterFailure(err) end
end

Boot:CompletePhase("LOCAL_STATS_SHADOW_READY")

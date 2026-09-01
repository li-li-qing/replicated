ReplicatedSuiteModuleSandbox:Enter('dps', {'ReplicatedDps', 'ReplicatedDpsConfig'})
------------------------------------------------------------------------
-- Replicated DPS - streaming shard/formal dual-read recovery gate
-- Author: Replicated
--
-- Authority boundary
--   * Rotating primary/backup remains the durable fallback loaded by Core.
--   * This gate reads one formal slot at a time and verifies the selected shard
--     generation through manifest/meta/shard digests without reconstructing a
--     second complete Stats root.
--   * A successful result is handed to rdps_persistence_switch.lua as a
--     promotion permit. This module never assigns D.State.stats itself.
--
-- Performance boundary
--   * Formal slot reads are serialized: at most one LoadData per Step.
--   * Shard envelopes are validated one at a time.
--   * The formal root is partition-digested incrementally; no recovered root or
--     second full path tree is retained during the dual-read audit.
------------------------------------------------------------------------

if ReplicatedDps == nil or ReplicatedDps.Boot == nil then return end

local D = ReplicatedDps
local Boot = D.Boot
if Boot.phase == "FAILED" then return end
if type(D.Persistence) ~= "table" or type(D.Persistence.LoadRaw) ~= "function"
    or type(D.Persistence.Key) ~= "function" then
    Boot:Fail("persistence_load_gate:persistence", "Persistence boundary is unavailable")
    return
end
if type(D.PersistenceShards) ~= "table"
    or type(D.PersistenceShards.BeginStreamVerification) ~= "function"
    or type(D.PersistenceShards.StepStreamVerification) ~= "function" then
    Boot:Fail("persistence_load_gate:shards", "Streaming shard verification is unavailable")
    return
end
if type(D.Stats) ~= "table"
    or type(D.Stats.ParsePersistedStatsCandidateForAudit) ~= "function" then
    Boot:Fail("persistence_load_gate:stats", "Stats persistence audit adapter is unavailable")
    return
end

Boot:SetPhase("PERSISTENCE_LOAD_GATE_LOADING")

local P = D.Persistence
local Shards = D.PersistenceShards
local Stats = D.Stats

D.PersistenceLoadGate = D.PersistenceLoadGate or {}
local G = D.PersistenceLoadGate

G.schemaVersion = 2
G.formalShardLoadEnabled = true
G.formalSwitchEnabled = true
G.defaultCompareBudget = 160
G.activeJob = nil
G.lastResult = G.lastResult
G.failed = G.failed == true
G.failure = G.failure
G.switchObserver = type(G.switchObserver) == "table" and G.switchObserver or nil
G.lastObservedShardSequence = math.max(0,
    math.floor(tonumber(G.lastObservedShardSequence) or 0))
G.auditSerial = math.max(0, math.floor(tonumber(G.auditSerial) or 0))
local currentBootGeneration = math.max(0, math.floor(tonumber(Boot.generation) or 0))
if tonumber(G.bootGeneration) ~= currentBootGeneration then
    G.bootGeneration = currentBootGeneration
    G.activeJob = nil
    G.failed = false
    G.failure = nil
    G.lastResult = nil
    G.auditSerial = 0
end

local FORMAL_SLOTS = { "primary", "backup", "pending" }
local FORMAL_PRIORITY = { primary = 3, pending = 2, backup = 1 }

local function Counter(name, amount)
    local counters = D.Diagnostics and D.Diagnostics.counters or nil
    if type(counters) ~= "table" then return end
    counters[name] = (tonumber(counters[name]) or 0) + (tonumber(amount) or 1)
end

local function NowMs()
    return D.Util ~= nil and type(D.Util.NowMs) == "function" and D.Util.NowMs() or 0
end

local function DiagnosticsEnabled()
    return D.State ~= nil and D.State.config ~= nil
        and D.State.config.diagnosticsEnabled == true
end

local function Disable(reason)
    G.failed = true
    G.failure = tostring(reason or "UNKNOWN")
    G.activeJob = nil
    Counter("persistenceLoadGateFailures", 1)
    if D.Diagnostics ~= nil and type(D.Diagnostics.AddWarning) == "function" then
        D.Diagnostics:AddWarning("persistence_load_gate",
            "分片双读门禁已停用：" .. G.failure)
    end
end

function G:SetSwitchObserver(observer)
    if observer ~= nil and (type(observer) ~= "table"
        or type(observer.OnPersistenceSwitchCandidate) ~= "function") then
        return false, "INVALID_SWITCH_OBSERVER"
    end
    self.switchObserver = observer
    return true
end

local function NotifySwitchObserver(result)
    local observer = G.switchObserver
    if type(observer) ~= "table"
        or type(observer.OnPersistenceSwitchCandidate) ~= "function" then return end
    local ok, err = pcall(observer.OnPersistenceSwitchCandidate, observer, result)
    if not ok and D.Diagnostics ~= nil and type(D.Diagnostics.AddWarning) == "function" then
        D.Diagnostics:AddWarning("persistence_switch", tostring(err))
    end
end

local function ParseFormal(raw, slot)
    local ok, candidate = pcall(Stats.ParsePersistedStatsCandidateForAudit,
        Stats, raw, slot)
    if not ok then return nil, tostring(candidate) end
    return candidate, nil
end

local function CandidateBetter(candidate, current)
    if type(candidate) ~= "table" then return false end
    if type(current) ~= "table" then return true end
    if candidate.enveloped == true and current.enveloped ~= true then return true end
    if candidate.enveloped ~= true and current.enveloped == true then return false end
    if candidate.enveloped == true then return candidate.sequence > current.sequence end
    return (FORMAL_PRIORITY[candidate.slot] or 0) > (FORMAL_PRIORITY[current.slot] or 0)
end

local function OrderedFormalSlots(head)
    local slots, seen = {}, {}
    if type(head) == "table" and tonumber(head.schemaVersion) == 1
        and (head.slot == "primary" or head.slot == "backup") then
        slots[#slots + 1] = head.slot
        seen[head.slot] = true
    end
    for _, slot in ipairs(FORMAL_SLOTS) do
        if not seen[slot] then slots[#slots + 1] = slot end
    end
    return slots
end

local function NewAuditJob(reason)
    G.auditSerial = G.auditSerial + 1
    return {
        kind = "STREAMING_DUAL_READ_AUDIT",
        auditId = G.auditSerial,
        reason = tostring(reason or "MANUAL"),
        triggerShardSequence = type(Shards.lastCompleted) == "table"
            and math.floor(tonumber(Shards.lastCompleted.sequence) or 0) or 0,
        phase = "WAIT_SHARD_IDLE",
        startedAt = NowMs(),
        formalHead = nil,
        formalSlotIndex = 1,
        formalSlots = nil,
        formalErrors = {},
        formalCandidate = nil,
        streamJob = nil,
        streamResult = nil,
    }
end

function G:BeginAudit(reason)
    if self.failed == true then return false, "GATE_FAILED" end
    if self.activeJob ~= nil then return false, "AUDIT_ALREADY_ACTIVE" end
    self.activeJob = NewAuditJob(reason)
    Counter("persistenceLoadGateAuditsStarted", 1)
    return true
end

function G:Cancel(reason)
    if self.activeJob == nil then return false end
    self.activeJob = nil
    self.lastCancelReason = tostring(reason or "CANCELLED")
    Counter("persistenceLoadGateAuditsCancelled", 1)
    return true
end

function G:OnDiagnosticsChanged(enabled)
    if enabled == true and self.activeJob == nil then
        self:BeginAudit("DIAGNOSTICS_ENABLED")
    end
end

function G:ShouldAutoAudit()
    if self.failed == true or self.activeJob ~= nil then return false end
    local completedSequence = type(Shards.lastCompleted) == "table"
        and math.floor(tonumber(Shards.lastCompleted.sequence) or 0) or 0
    if completedSequence <= self.lastObservedShardSequence then return false end
    local observer = self.switchObserver
    if type(observer) == "table" and type(observer.ShouldAuditShardSequence) == "function" then
        local ok, result = pcall(observer.ShouldAuditShardSequence, observer, completedSequence)
        if ok then return result == true end
    end
    return true
end

local function Finish(job, phase, reason, options)
    options = type(options) == "table" and options or {}
    local formal = job.formalCandidate
    local stream = job.streamResult
    local selected = stream and stream.selected or nil
    local previous = stream and stream.previous or nil
    G.lastResult = {
        auditId = job.auditId,
        phase = tostring(phase),
        reason = reason,
        equivalent = options.equivalent == true,
        migrationEquivalent = options.migrationEquivalent == true,
        switchCandidate = options.switchCandidate == true,
        commitEligible = options.switchCandidate == true
            and G.formalShardLoadEnabled == true and G.formalSwitchEnabled == true,
        formalShardLoadEnabled = G.formalShardLoadEnabled,
        formalSwitchEnabled = G.formalSwitchEnabled,
        formalSlot = formal and formal.slot or nil,
        formalSequence = formal and formal.sequence or nil,
        formalSchema = formal and formal.payloadSchema or nil,
        formalSource = formal and formal.source or nil,
        formalRepaired = formal and formal.repaired == true or false,
        formalMigratedFrom = formal and formal.migratedFrom or nil,
        shardSequence = selected and selected.sequence or nil,
        shardManifestBank = selected and selected.bank or nil,
        shardPreviousSequence = previous and previous.sequence or nil,
        shardSourceFormalSequence = selected and selected.sourceFormalSequence or nil,
        shardSourceFormalSlot = selected and selected.sourceFormalSlot or nil,
        shardSourceStatsSchema = selected and selected.sourceStatsSchema or nil,
        sourceEnvelopeVersion = selected and selected.sourceEnvelopeVersion or nil,
        comparedNodes = stream and stream.rowsDigested or 0,
        mismatchShardId = job.streamJob and job.streamJob.mismatchShardId or nil,
        streamingCompare = true,
        peakRootCopies = 0,
        completedAt = NowMs(),
        formalAuthorityUnchanged = true,
    }
    G.lastObservedShardSequence = math.max(G.lastObservedShardSequence,
        math.floor(tonumber(job.triggerShardSequence) or 0),
        math.floor(tonumber(selected and selected.sequence) or 0))
    G.activeJob = nil
    Counter("persistenceLoadGateAuditsCompleted", 1)
    if options.equivalent == true then Counter("persistenceLoadGateEquivalent", 1) end
    if options.switchCandidate == true then
        Counter("persistenceLoadGateSwitchCandidates", 1)
        NotifySwitchObserver(G.lastResult)
    end
    return true, G.lastResult, reason
end

local function StepWaitShardIdle(job)
    if Shards.activeJob ~= nil then return true end
    job.phase = "READ_FORMAL_HEAD"
    return true
end

local function StepReadFormalHead(job)
    job.formalHead = P.LoadRaw(P.Key("stats_head", "primary"))
    job.formalSlots = OrderedFormalSlots(job.formalHead)
    job.formalSlotIndex = 1
    job.phase = "READ_FORMAL_SLOTS"
    return true
end

local function StepReadFormalSlot(job)
    local slot = job.formalSlots and job.formalSlots[job.formalSlotIndex] or nil
    if slot == nil then
        job.phase = "SELECT_FORMAL"
        return true
    end
    local raw = P.LoadRaw(P.Key("stats", slot))
    local candidate, reason = ParseFormal(raw, slot)
    if candidate ~= nil then
        local head = job.formalHead
        local exactHead = type(head) == "table" and tonumber(head.schemaVersion) == 1
            and head.slot == slot and candidate.enveloped == true
            and candidate.sequence == math.max(0, math.floor(tonumber(head.sequence) or -1))
        if exactHead then
            job.formalCandidate = candidate
            job.formalHeadMatched = true
            job.phase = "SELECT_FORMAL"
            return true
        end
        if CandidateBetter(candidate, job.formalCandidate) then
            job.formalCandidate = candidate
        end
    elseif raw ~= nil then
        job.formalErrors[slot] = reason or "FORMAL_SLOT_INVALID"
    end
    -- Release the raw table immediately unless it is the selected candidate.
    raw = nil
    job.formalSlotIndex = job.formalSlotIndex + 1
    return true
end

local function StepSelectFormal(job)
    if job.formalCandidate == nil then
        return Finish(job, "NO_FORMAL_CANDIDATE", "NO_VALID_FORMAL_STATS")
    end
    if job.formalCandidate.legacyRequiresMigration == true
        or type(job.formalCandidate.data) ~= "table" then
        return Finish(job, "FORMAL_MIGRATION_REQUIRED",
            "FORMAL_LEGACY_REQUIRES_V3_SAVE")
    end
    local stream, reason = Shards:BeginStreamVerification(job.formalCandidate.data)
    if type(stream) ~= "table" then
        return Finish(job, "STREAM_VERIFY_FAILED", reason or "STREAM_BEGIN_FAILED")
    end
    job.streamJob = stream
    job.phase = "STREAM_VERIFY"
    return true
end

local function StepStreamVerify(job, budget)
    local done, result, reason = Shards:StepStreamVerification(job.streamJob, budget)
    if not done then return true end
    if type(result) ~= "table" or result.equivalent ~= true then
        -- Recovery may have correctly fallen back to the previous complete
        -- generation. Classify that as stale before reporting a path mismatch:
        -- its digest is expected to differ from the newer rotating root.
        local selected = job.streamJob and job.streamJob.selected or nil
        local formal = job.formalCandidate
        local formalLastSaveAt = tonumber(formal and formal.data and formal.data.lastSaveAt) or 0
        local shardLastSaveAt = tonumber(selected and selected.sourceLastSaveAt) or 0
        if type(selected) == "table" and shardLastSaveAt < formalLastSaveAt then
            job.streamResult = { selected = selected, previous = job.streamJob.previous,
                rowsDigested = job.streamJob.rowsDigested or 0 }
            return Finish(job, "SHARD_STALE", "SHARD_LAST_SAVE_OLDER")
        end
        if reason == "NO_VALID_GENERATION" then
            return Finish(job, "NO_SHARD_GENERATION", reason)
        end
        return Finish(job, "PATH_MISMATCH", reason or "STREAM_DIGEST_MISMATCH")
    end
    job.streamResult = result

    local formal = job.formalCandidate
    local selected = result.selected
    local previous = result.previous
    local formalLastSaveAt = tonumber(formal.data and formal.data.lastSaveAt) or 0
    local shardLastSaveAt = tonumber(selected and selected.sourceLastSaveAt) or 0
    if shardLastSaveAt < formalLastSaveAt then
        return Finish(job, "SHARD_STALE", "SHARD_LAST_SAVE_OLDER")
    elseif shardLastSaveAt > formalLastSaveAt then
        return Finish(job, "FORMAL_STALE", "SHARD_LAST_SAVE_NEWER")
    end

    local sourceSequence = math.max(0,
        math.floor(tonumber(selected and selected.sourceFormalSequence) or 0))
    local exactSource = formal.enveloped == true and formal.payloadSchema == 3
        and formal.repaired ~= true and sourceSequence == formal.sequence
        and selected.sourceFormalSlot == formal.slot
        and tonumber(selected.sourceEnvelopeVersion) == tonumber(P.STATS_ENVELOPE_VERSION)
    local hasRollbackGeneration = type(previous) == "table"
    local switchCandidate = exactSource and hasRollbackGeneration
    local migrationEquivalent = formal.migratedFrom ~= nil

    if switchCandidate then
        return Finish(job, "VERIFIED_SWITCH_CANDIDATE", "READY_FOR_NEXT_BOOT", {
            equivalent = true, switchCandidate = true,
        })
    elseif not exactSource then
        return Finish(job, migrationEquivalent and "VERIFIED_MIGRATION_EQUIVALENT"
            or "VERIFIED_EQUIVALENT_LEGACY_MANIFEST",
            formal.enveloped ~= true and "FORMAL_SOURCE_NOT_ROTATING_V3"
                or sourceSequence <= 0 and "MANIFEST_SOURCE_SEQUENCE_UNRECORDED"
                or selected.sourceFormalSlot ~= formal.slot and "MANIFEST_SOURCE_SLOT_MISMATCH"
                or "FORMAL_SOURCE_LINK_INCOMPLETE", {
                equivalent = true, migrationEquivalent = migrationEquivalent,
            })
    end
    return Finish(job, "VERIFIED_NEEDS_ROLLBACK_GENERATION",
        "NEEDS_SECOND_VALID_GENERATION", { equivalent = true })
end

function G:Step(budget)
    if self.failed == true then return true, self.lastResult, self.failure end
    if self.activeJob == nil and self:ShouldAutoAudit() then
        self:BeginAudit("SHARD_GENERATION_COMMITTED")
    end
    local job = self.activeJob
    if job == nil then return true, self.lastResult, nil end
    budget = math.max(1, math.floor(tonumber(budget) or self.defaultCompareBudget))

    local fn, arg
    if job.phase == "WAIT_SHARD_IDLE" then
        fn = StepWaitShardIdle
    elseif job.phase == "READ_FORMAL_HEAD" then
        fn = StepReadFormalHead
    elseif job.phase == "READ_FORMAL_SLOTS" then
        fn = StepReadFormalSlot
    elseif job.phase == "SELECT_FORMAL" then
        fn = StepSelectFormal
    elseif job.phase == "STREAM_VERIFY" then
        fn, arg = StepStreamVerify, budget
    else
        Disable("UNKNOWN_PHASE:" .. tostring(job.phase))
        return true, self.lastResult, self.failure
    end

    local ok, result, summary, reason
    if arg ~= nil then ok, result, summary, reason = pcall(fn, job, arg)
    else ok, result, summary, reason = pcall(fn, job) end
    if not ok then
        Disable(result)
        return true, self.lastResult, self.failure
    end
    if result ~= true then
        Disable(reason or summary or result or "GATE_STEP_FAILED")
        return true, self.lastResult, self.failure
    end
    if self.activeJob == nil then return true, summary or self.lastResult, reason end
    return false, nil, nil
end

function G:GetStatusLine()
    if self.failed == true then
        return "分片双读门禁：已停用 / " .. tostring(self.failure or "未知错误")
    end
    if type(self.activeJob) == "table" then
        local rows = self.activeJob.streamJob and self.activeJob.streamJob.rowsDigested or 0
        return string.format("分片双读门禁：%s / 流式核对 %d 行",
            tostring(self.activeJob.phase), tonumber(rows) or 0)
    end
    local result = self.lastResult
    if type(result) == "table" then
        return string.format("分片双读门禁：%s / 等价=%s / 下次启动候选=%s",
            tostring(result.phase), result.equivalent and "是" or "否",
            result.switchCandidate and "是" or "否")
    end
    return DiagnosticsEnabled() and "分片双读门禁：待审计"
        or "分片双读门禁：后台等待完整 generation"
end

function G:ResetForTests()
    self.activeJob = nil
    self.lastResult = nil
    self.failed = false
    self.failure = nil
    self.lastObservedShardSequence = 0
    self.auditSerial = 0
end

Boot:CompletePhase("PERSISTENCE_LOAD_GATE_READY")
if D.Diagnostics ~= nil then D.Diagnostics.status = "PERSISTENCE_LOAD_GATE_READY" end

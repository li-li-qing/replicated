ReplicatedSuiteModuleSandbox:Enter('dps', {'ReplicatedDps', 'ReplicatedDpsConfig'})
------------------------------------------------------------------------
-- Replicated DPS - formal shard boot switch and rotating fallback envelope
-- Author: Replicated
--
-- Commit order
--   1. Core loads and validates the rotating primary/backup fallback.
--   2. A previously verified promotion marker names one complete shard
--      generation and its exact rotating source sequence/slot.
--   3. Before Runtime starts, all shard envelopes are validated and recovered.
--   4. The recovered root is compared with the already-loaded rotating root.
--   5. D.Stats:AdoptPersistedStatsRoot performs the atomic in-memory swap and
--      invalidates every derived cache. Rotating slots are never cleared.
--
-- Rollback boundary
--   * Any marker, manifest, digest, source-link, compare or cache-adoption
--     failure leaves D.State.stats on the rotating root.
--   * The promotion marker is written only after the streaming dual-read gate
--     proves equality and a previous complete shard generation exists.
------------------------------------------------------------------------

if ReplicatedDps == nil or ReplicatedDps.Boot == nil then return end

local D = ReplicatedDps
local Boot = D.Boot
if Boot.phase == "FAILED" then return end
if type(D.Persistence) ~= "table" or type(D.Persistence.LoadRaw) ~= "function"
    or type(D.Persistence.SaveRaw) ~= "function" or type(D.Persistence.ClearRaw) ~= "function" then
    Boot:Fail("persistence_switch:persistence", "Persistence boundary is unavailable")
    return
end
if type(D.PersistenceShards) ~= "table"
    or type(D.PersistenceShards.BeginRecovery) ~= "function"
    or type(D.PersistenceShards.StepRecovery) ~= "function"
    or type(D.PersistenceShards.SetGenerationObserver) ~= "function" then
    Boot:Fail("persistence_switch:shards", "PersistenceShards boundary is unavailable")
    return
end
if type(D.PersistenceLoadGate) ~= "table"
    or type(D.PersistenceLoadGate.SetSwitchObserver) ~= "function" then
    Boot:Fail("persistence_switch:gate", "PersistenceLoadGate boundary is unavailable")
    return
end
if type(D.Stats) ~= "table" or type(D.Stats.AdoptPersistedStatsRoot) ~= "function" then
    Boot:Fail("persistence_switch:stats", "Stats root adoption boundary is unavailable")
    return
end

Boot:SetPhase("PERSISTENCE_SWITCH_LOADING")

local P = D.Persistence
local Shards = D.PersistenceShards
local Gate = D.PersistenceLoadGate
local Stats = D.Stats
local U = D.Util

D.PersistenceSwitch = D.PersistenceSwitch or {}
local S = D.PersistenceSwitch

S.schemaVersion = 1
S.markerSchemaVersion = 1
S.formalShardLoadEnabled = true
S.formalSwitchEnabled = true
S.bootAdoptionEnabled = true
S.maxBootRecoverySteps = 200000
S.clearConfirmWindowMs = 8000
S.lastBootResult = S.lastBootResult
S.lastMarkerWrite = S.lastMarkerWrite
S.clearArmedUntil = 0
S.lastMaintenance = S.lastMaintenance

local function Counter(name, amount)
    local counters = D.Diagnostics and D.Diagnostics.counters or nil
    if type(counters) ~= "table" then return end
    counters[name] = (tonumber(counters[name]) or 0) + (tonumber(amount) or 1)
end

local function NowMs()
    return U ~= nil and type(U.NowMs) == "function" and U.NowMs() or 0
end

local function MarkerKey()
    return P.Key("stats_shard_switch", "primary")
end

local function NormalizeSlot(slot)
    return slot == "primary" and "primary" or slot == "backup" and "backup" or nil
end

local function MarkerValid(marker)
    if type(marker) ~= "table" or tonumber(marker.schemaVersion) ~= S.markerSchemaVersion
        or marker.enabled ~= true then return false end
    if math.floor(tonumber(marker.shardSequence) or 0) < 1
        or (marker.manifestBank ~= "a" and marker.manifestBank ~= "b"
            and marker.manifestBank ~= "c")
        or math.floor(tonumber(marker.previousSequence) or 0) < 1
        or math.floor(tonumber(marker.sourceFormalSequence) or 0) < 1
        or NormalizeSlot(marker.sourceFormalSlot) == nil
        or tonumber(marker.sourceEnvelopeVersion) ~= tonumber(P.STATS_ENVELOPE_VERSION)
        or tonumber(marker.sourceStatsSchema) ~= 3 then
        return false
    end
    return true
end

local function LoadMarker()
    local marker = P.LoadRaw(MarkerKey())
    return MarkerValid(marker) and marker or nil
end

local function SaveMarker(marker)
    if not MarkerValid(marker) then return false, "INVALID_PROMOTION_MARKER" end
    local ok, reason = P.SaveRaw(MarkerKey(), marker)
    if ok == true then
        S.marker = marker
        S.lastMarkerWrite = { sequence = marker.shardSequence, at = NowMs(),
            verifiedBy = marker.verifiedBy }
        Counter("persistenceSwitchMarkersWritten", 1)
        return true
    end
    Counter("persistenceSwitchMarkerFailures", 1)
    return false, reason or "MARKER_WRITE_FAILED"
end

local function MarkerFromResult(result, verifiedBy)
    return {
        schemaVersion = S.markerSchemaVersion,
        enabled = true,
        shardSequence = math.floor(tonumber(result.shardSequence) or 0),
        manifestBank = result.shardManifestBank,
        previousSequence = math.floor(tonumber(result.shardPreviousSequence) or 0),
        sourceFormalSequence = math.floor(tonumber(result.shardSourceFormalSequence) or 0),
        sourceFormalSlot = NormalizeSlot(result.shardSourceFormalSlot),
        sourceEnvelopeVersion = math.floor(tonumber(result.sourceEnvelopeVersion) or 0),
        sourceStatsSchema = math.floor(tonumber(result.shardSourceStatsSchema) or 0),
        verifiedAt = NowMs(),
        verifiedBy = tostring(verifiedBy or "STREAMING_DUAL_READ"),
        rotatingFallbackRetained = true,
    }
end

function S:IsEnrolled()
    return MarkerValid(self.marker)
end

function S:ShouldAuditShardSequence(sequence)
    sequence = math.floor(tonumber(sequence) or 0)
    if not self:IsEnrolled() then return sequence > 0 end
    return sequence > math.floor(tonumber(self.marker.shardSequence) or 0)
end

function S:OnPersistenceSwitchCandidate(result)
    if type(result) ~= "table" or result.switchCandidate ~= true
        or result.equivalent ~= true or result.commitEligible ~= true then
        return false, "NOT_A_SWITCH_CANDIDATE"
    end
    return SaveMarker(MarkerFromResult(result, "STREAMING_DUAL_READ"))
end

function S:OnShardGenerationCommitted(summary)
    if not self:IsEnrolled() then return false, "NOT_ENROLLED" end
    if type(summary) ~= "table"
        or math.floor(tonumber(summary.sequence) or 0) <= math.floor(tonumber(self.marker.shardSequence) or 0)
        or math.floor(tonumber(summary.previousSequence) or 0) < 1
        or math.floor(tonumber(summary.sourceFormalSequence) or 0) < 1
        or NormalizeSlot(summary.sourceFormalSlot) == nil
        or tonumber(summary.sourceEnvelopeVersion) ~= tonumber(P.STATS_ENVELOPE_VERSION)
        or tonumber(summary.sourceStatsSchema) ~= 3 then
        return false, "GENERATION_NOT_PROMOTABLE"
    end
    return SaveMarker({
        schemaVersion = self.markerSchemaVersion,
        enabled = true,
        shardSequence = math.floor(tonumber(summary.sequence) or 0),
        manifestBank = summary.manifestBank,
        previousSequence = math.floor(tonumber(summary.previousSequence) or 0),
        sourceFormalSequence = math.floor(tonumber(summary.sourceFormalSequence) or 0),
        sourceFormalSlot = NormalizeSlot(summary.sourceFormalSlot),
        sourceEnvelopeVersion = math.floor(tonumber(summary.sourceEnvelopeVersion) or 0),
        sourceStatsSchema = math.floor(tonumber(summary.sourceStatsSchema) or 0),
        verifiedAt = NowMs(),
        verifiedBy = "SOURCE_LINKED_CONTINUATION",
        rotatingFallbackRetained = true,
    })
end

local function RootsEqual(left, right)
    local stack = { { left, right } }
    local compared = 0
    while #stack > 0 do
        local frame = stack[#stack]
        stack[#stack] = nil
        local a, b = frame[1], frame[2]
        if type(a) ~= type(b) then return false, compared, "TYPE_MISMATCH" end
        if type(a) ~= "table" then
            if a ~= b or (type(a) == "number" and (a ~= a or b ~= b)) then
                return false, compared, "VALUE_MISMATCH"
            end
            compared = compared + 1
        else
            for key, value in pairs(a) do
                if b[key] == nil then return false, compared, "MISSING_IN_SHARD" end
                stack[#stack + 1] = { value, b[key] }
            end
            for key in pairs(b) do
                if a[key] == nil then return false, compared, "EXTRA_IN_SHARD" end
            end
            compared = compared + 1
        end
    end
    return true, compared, nil
end

local function RecoverMarkerGeneration(marker)
    local job = Shards:BeginRecovery()
    for _ = 1, S.maxBootRecoverySteps do
        local done, root, reason = Shards:StepRecovery(job, 64)
        if done then
            if type(root) ~= "table" then return nil, job, reason or "RECOVERY_FAILED" end
            return root, job, nil
        end
    end
    return nil, job, "RECOVERY_STEP_LIMIT"
end

function S:TryBootAdoption()
    local marker = self.marker
    local result = {
        attempted = false, adopted = false, rotatingFallbackRetained = true,
        completedAt = NowMs(),
    }
    self.lastBootResult = result
    if self.formalShardLoadEnabled ~= true or self.formalSwitchEnabled ~= true
        or self.bootAdoptionEnabled ~= true then
        result.reason = "FORMAL_SWITCH_DISABLED"
        return false, result.reason
    end
    if not MarkerValid(marker) then
        result.reason = "NO_VERIFIED_MARKER"
        return false, result.reason
    end
    result.attempted = true
    if NormalizeSlot(P.statsActiveSlot) ~= marker.sourceFormalSlot
        or math.floor(tonumber(P.statsSequence) or 0) ~= marker.sourceFormalSequence then
        result.reason = "ROTATING_SOURCE_MISMATCH"
        Counter("persistenceSwitchFallbacks", 1)
        return false, result.reason
    end

    local recovered, recovery, reason = RecoverMarkerGeneration(marker)
    if recovered == nil then
        result.reason = reason or "SHARD_RECOVERY_FAILED"
        Counter("persistenceSwitchFallbacks", 1)
        return false, result.reason
    end
    local selected = recovery.selected
    local previous = recovery.previous
    if type(selected) ~= "table" or selected.sequence ~= marker.shardSequence
        or selected.bank ~= marker.manifestBank
        or type(previous) ~= "table" or previous.sequence ~= marker.previousSequence
        or selected.sourceFormalSequence ~= marker.sourceFormalSequence
        or selected.sourceFormalSlot ~= marker.sourceFormalSlot then
        result.reason = "MARKER_GENERATION_MISMATCH"
        Counter("persistenceSwitchFallbacks", 1)
        return false, result.reason
    end

    local equal, compared, compareReason = RootsEqual(D.State.stats, recovered)
    result.comparedNodes = compared
    if equal ~= true then
        result.reason = compareReason or "ROTATING_SHARD_MISMATCH"
        Counter("persistenceSwitchFallbacks", 1)
        return false, result.reason
    end

    local adopted, previousRootOrReason = Stats:AdoptPersistedStatsRoot(recovered,
        "shard_g" .. tostring(marker.shardSequence) .. "_formal")
    if adopted ~= true then
        result.reason = previousRootOrReason or "ROOT_ADOPTION_FAILED"
        Counter("persistenceSwitchFallbacks", 1)
        return false, result.reason
    end
    result.adopted = true
    result.reason = "SHARD_ROOT_ADOPTED"
    result.shardSequence = marker.shardSequence
    result.sourceFormalSequence = marker.sourceFormalSequence
    result.completedAt = NowMs()
    Counter("persistenceSwitchBootAdoptions", 1)
    return true, result.reason
end

function S:BeginSafetyAudit(reason)
    return Gate:BeginAudit(reason or "MANUAL_SAFETY_CHECK")
end

function S:DisableFormalShardLoad()
    local ok, reason = P.ClearRaw(MarkerKey())
    if ok == true then
        self.marker = nil
        self.lastBootResult = { attempted = false, adopted = false,
            reason = "FORMAL_SHARD_LOAD_DISABLED", completedAt = NowMs(),
            rotatingFallbackRetained = true }
    end
    return ok, reason
end

function S:RequestClearShardStorage()
    local now = NowMs()
    if now > (tonumber(self.clearArmedUntil) or 0) then
        self.clearArmedUntil = now + self.clearConfirmWindowMs
        return false, "CONFIRM_AGAIN"
    end
    self.clearArmedUntil = 0
    local disabled, disableReason = self:DisableFormalShardLoad()
    if disabled ~= true then return false, disableReason or "MARKER_CLEAR_FAILED" end
    return Shards:BeginClearStorage("USER_MAINTENANCE")
end

function S:StepMaintenance(budget)
    local done, result, reason = Shards:StepMaintenance(budget or 1)
    if done and type(result) == "table" then
        self.lastMaintenance = result
        Counter("persistenceSwitchMaintenanceRuns", 1)
    end
    return done, result, reason
end

function S:GetStatusLine()
    local boot = self.lastBootResult
    local marker = self.marker
    local adoption = type(boot) == "table" and boot.adopted == true
        and ("已从 G" .. tostring(boot.shardSequence) .. " 接管")
        or (type(boot) == "table" and boot.reason or "未执行")
    local enrolled = MarkerValid(marker) and ("G" .. tostring(marker.shardSequence)) or "否"
    return "分片正式加载：" .. adoption
        .. " / 已登记=" .. enrolled
        .. " / rotating 回退保留 / " .. Shards:GetMaintenanceStatus()
end

function S:ResetForTests()
    self.marker = nil
    self.lastBootResult = nil
    self.lastMarkerWrite = nil
    self.clearArmedUntil = 0
    self.lastMaintenance = nil
end

local gateRegistered, gateReason = Gate:SetSwitchObserver(S)
if gateRegistered ~= true then
    Boot:Fail("persistence_switch:gate_observer", tostring(gateReason))
    return
end
local shardRegistered, shardReason = Shards:SetGenerationObserver(S)
if shardRegistered ~= true then
    Boot:Fail("persistence_switch:shard_observer", tostring(shardReason))
    return
end

S.marker = LoadMarker()
S:TryBootAdoption()

Boot:CompletePhase("PERSISTENCE_SWITCH_READY")
if D.Diagnostics ~= nil then D.Diagnostics.status = "PERSISTENCE_SWITCH_READY" end

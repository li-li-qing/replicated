------------------------------------------------------------------------
-- Replicated Suite V3 - Team Tools visual/marker extension (.18.122)
--
-- Extends the existing combat_team_tools Feature without creating a second
-- navigation/runtime authority.  The permanent sub-store contains only user
-- choices and stable marker identities; roster/aura/native window facts remain
-- transient.
--
-- Performance contract:
-- * Sacrifice-Dance candidate discovery: roster edges + 10s safety scan.
-- * Aura reads: shared AuraObservationV3, only for Spelldance candidates.
-- * No Tick / no per-frame Native reads in Domain.
-- * Screen projection belongs to Presentation (rs_v3_team_sac_overlay.lua).
-- * Marker restore is a bounded 1.1s serial queue to respect the official
--   X2Unit:SetOverHeadMarker 1000ms cooldown; every write is verified before
--   the next queued write.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local Feature = S.Features and S.Features.combat_team_tools or nil
local P = S.Persistence
if type(Feature) ~= "table" or type(P) ~= "table" then return end

local STORE_ID = "v3.combat.team_tools.visuals"
local ROSTER_TOKEN = "combat_team_tools:sac_roster"
local AURA_TOKEN = "combat_team_tools:sac_aura"
local CANDIDATE_TASK = "v3_team_tools_sac_candidates"
local AURA_TASK = "v3_team_tools_sac_aura"
local AURA_EDGE_TASK = "v3_team_tools_sac_aura_edge"
local MARK_RESTORE_TASK = "v3_team_tools_marker_restore"
local SPELLEDANCE_ABILITY_INDEX = 14
local MAX_CANDIDATES = 16
local MAX_ROSTER = 100
local MAX_AURAS = 96
local MAX_SAVED_MARKS = 16
local ACTIVE_STALE_MS = 2500
local MARKER_FALLBACK_MAX = 8

-- Exact RU/legacy evidence from the user-provided reference project.  These
-- are identifiers only; AuraObservationV3 remains the single read Authority.
local SAC_BUFF_IDS = {
    [30098] = true,
    [30137] = true,
    [30141] = true,
    [30142] = true,
}

local V = {
    version = 1,
    state = { sacEnabled = false, savedMarks = {} },
    loaded = false,
    running = false,
    rosterHeld = false,
    auraHeld = false,
    candidateCount = 0,
    candidates = {},
    active = {},
    activeCount = 0,
    rosterRevision = 0,
    scanFailures = 0,
    lastError = nil,
    markerStatus = "idle",
    markerError = nil,
    markerQueued = 0,
    markerApplied = 0,
    markerSkipped = 0,
    restoreQueue = nil,
    restoreIndex = 0,
    restorePending = nil,
    eventOwner = {},
}
Feature.TeamVisuals = V

local function DeepCopy(value)
    if S.Utils ~= nil and type(S.Utils.DeepCopy) == "function" then return S.Utils.DeepCopy(value) end
    if type(value) ~= "table" then return value end
    local out = {}
    for key, child in pairs(value) do out[key] = DeepCopy(child) end
    return out
end

local function NowMs()
    return math.max(0, tonumber(S.NowMs and S.NowMs()) or 0)
end

local function Trim(value)
    return (tostring(value or ""):match("^%s*(.-)%s*$")) or ""
end

local function MarkerMax()
    local value = tonumber(rawget(_G, "MAX_OVER_HEAD_MARKER"))
    if value == nil or value < 1 or value ~= math.floor(value) then return MARKER_FALLBACK_MAX end
    return math.min(64, math.floor(value))
end

local function NormalizeSavedMarks(source)
    local out, seenName, seenMarker = {}, {}, {}
    for _, row in ipairs(type(source) == "table" and source or {}) do
        if #out >= MAX_SAVED_MARKS then break end
        local name = Trim(type(row) == "table" and row.name or nil)
        local marker = tonumber(type(row) == "table" and row.markerIndex or nil)
        if marker ~= nil then marker = math.floor(marker) end
        if name ~= "" and #name <= 96 and marker ~= nil and marker >= 1 and marker <= MarkerMax()
            and seenName[name] ~= true and seenMarker[marker] ~= true then
            seenName[name], seenMarker[marker] = true, true
            out[#out + 1] = { name = name, markerIndex = marker }
        end
    end
    table.sort(out, function(a, b)
        if a.markerIndex ~= b.markerIndex then return a.markerIndex < b.markerIndex end
        return a.name < b.name
    end)
    return out
end

local function NormalizeState(value)
    value = type(value) == "table" and value or {}
    return {
        sacEnabled = value.sacEnabled == true,
        savedMarks = NormalizeSavedMarks(value.savedMarks),
    }
end

if P:GetStore(STORE_ID) == nil then
    local store, err = P:RegisterV3Store({
        id = STORE_ID,
        owner = "v3.combat_team_tools.visuals",
        scope = P.Scope.Account,
        lifetime = P.Lifetime.Permanent,
        schemaVersion = 1,
        legacySchemaVersion = 0,
        key = P.V3KeyPrefix .. "combat_team_tools_visuals",
        budget = { maxDepth = 4, maxNodes = 160, maxStringBytes = 2048, maxEntriesPerTable = 48 },
        default = function() return { sacEnabled = false, savedMarks = {} } end,
        get = function() return NormalizeState(V.state) end,
        apply = function(value) V.state = NormalizeState(value) end,
        migrate = function(value) return NormalizeState(value) end,
    })
    if store == nil then error(err or "team tools visuals store register failed") end
end

local function Mutate(reason, fn, options)
    if type(fn) ~= "function" then return false, "team visual mutation required" end
    options = type(options) == "table" and options or {}
    return P:MutateStore(STORE_ID, function()
        local ok, err = fn(V.state)
        if ok == false then return false, err end
        V.state = NormalizeState(V.state)
        return true
    end, {
        delayMs = tonumber(options.delayMs) or 300,
        durable = options.durable == true,
        reason = tostring(reason or "team_visual_mutation"),
    })
end

local function Publish(reason)
    V.visualRevision = (tonumber(V.visualRevision) or 0) + 1
    if S.Events ~= nil and type(S.Events.Publish) == "function" then
        S.Events:Publish(Feature.UpdateTopic, tonumber(Feature.Authority and Feature.Authority.revision) or 0,
            "team_visuals:" .. tostring(reason or "updated"))
    end
end

local function TeamRoster()
    return S.Services and S.Services.TeamRosterV3 or nil
end

local function Aura()
    return S.Services and S.Services.AuraObservationV3 or nil
end

local function HasSpelldance(unitToken)
    if S.Api == nil or type(S.Api.CallCapability) ~= "function" then return false, "api_unavailable" end
    local ok, templates, err = S.Api:CallCapability("X2Unit:GetTargetAbilityTemplates", rawget(_G, "X2Unit"), "GetTargetAbilityTemplates", unitToken)
    if ok ~= true or type(templates) ~= "table" then return false, tostring(err or "ability_templates_unavailable") end
    for index = 1, math.min(3, #templates) do
        if tonumber(type(templates[index]) == "table" and templates[index].index or nil) == SPELLEDANCE_ABILITY_INDEX then return true end
    end
    return false, nil
end

local function SameIdentitySet(left, right)
    left, right = type(left) == "table" and left or {}, type(right) == "table" and right or {}
    local leftCount, rightCount = 0, 0
    for token, row in pairs(left) do
        leftCount = leftCount + 1
        local other = right[token]
        if type(other) ~= "table" or tostring(other.name or "") ~= tostring(row.name or "") then return false end
    end
    for _ in pairs(right) do rightCount = rightCount + 1 end
    return leftCount == rightCount
end

local function EnsureAuraTask()
    if S.Scheduler == nil or type(S.Scheduler.AddTask) ~= "function" then return false, "Scheduler unavailable" end
    if V.running ~= true or V.candidateCount <= 0 then
        S.Scheduler:RemoveTask(AURA_TASK)
        return true
    end
    local ok = S.Scheduler:AddTask(AURA_TASK, 1200, function()
        if V.running == true then Feature:ScanSacAuras("safety") end
    end, false, Feature, "P2", 1)
    if ok == true and type(S.Scheduler.SetTaskModule) == "function" then S.Scheduler:SetTaskModule(AURA_TASK, Feature.Id, true) end
    return ok == true, ok == true and nil or "Sac Aura safety task failed"
end

function Feature:ScanSacCandidates(reason)
    if V.running ~= true then return true end
    local roster = TeamRoster()
    if type(roster) ~= "table" or type(roster.GetSnapshot) ~= "function" then return false, "TeamRosterV3 unavailable" end
    local snapshot = roster:GetSnapshot()
    local members = type(snapshot) == "table" and type(snapshot.members) == "table" and snapshot.members or {}
    local nextCandidates, failures, count = {}, 0, 0
    for index = 1, math.min(MAX_ROSTER, #members) do
        if count >= MAX_CANDIDATES then break end
        local member = members[index]
        local token = Trim(type(member) == "table" and member.unitToken or nil)
        local name = Trim(type(member) == "table" and member.name or nil)
        if token ~= "" then
            local matched, err = HasSpelldance(token)
            if matched == true then
                count = count + 1
                nextCandidates[token] = { unitToken = token, name = name ~= "" and name or token }
            elseif err ~= nil then failures = failures + 1 end
        end
    end
    local changed = not SameIdentitySet(V.candidates, nextCandidates)
    V.candidates, V.candidateCount = nextCandidates, count
    V.rosterRevision = tonumber(type(snapshot) == "table" and snapshot.revision) or 0
    V.scanFailures = failures
    V.lastError = failures > 0 and ("职业读取失败 " .. tostring(failures) .. " 人；其余成员继续使用") or nil

    -- Drop active rows that are no longer valid candidates immediately.
    local activeChanged = false
    for token in pairs(V.active) do
        if nextCandidates[token] == nil then V.active[token] = nil; activeChanged = true end
    end
    local activeCount = 0
    for _ in pairs(V.active) do activeCount = activeCount + 1 end
    V.activeCount = activeCount
    local taskOk, taskErr = EnsureAuraTask()
    if taskOk ~= true then V.lastError = taskErr end
    if changed or activeChanged then Publish(reason or "candidate_scan") end
    if count > 0 then self:ScanSacAuras("candidate_scan") end
    return true
end

local function StatusMapHasSac(map)
    for id in pairs(type(map) == "table" and map or {}) do
        if SAC_BUFF_IDS[tonumber(id)] == true then return true end
    end
    return false
end

function Feature:ScanSacAuras(reason)
    if V.running ~= true or V.candidateCount <= 0 then return true end
    local aura = Aura()
    if type(aura) ~= "table" or type(aura.GetSnapshot) ~= "function" or type(aura.GetStatusMap) ~= "function" then
        V.lastError = "AuraObservationV3 unavailable"
        return false, V.lastError
    end
    local now = NowMs()
    local nextActive = {}
    local failures = 0
    for token, candidate in pairs(V.candidates) do
        local snapshot = aura:GetSnapshot(token, { buff = true, debuff = false, hidden = false, buffLimit = MAX_AURAS, ttlMs = 100 })
        if type(snapshot) == "table" then
            local map, meta = aura:GetStatusMap(snapshot, { buff = true, debuff = false, hidden = false })
            if type(meta) == "table" and meta.available == true then
                if StatusMapHasSac(map) then
                    nextActive[token] = { unitToken = token, name = candidate.name, verifiedAt = now }
                end
            else
                failures = failures + 1
                local previous = V.active[token]
                if type(previous) == "table" and now - (tonumber(previous.verifiedAt) or 0) <= ACTIVE_STALE_MS then
                    nextActive[token] = previous
                end
            end
        else
            failures = failures + 1
            local previous = V.active[token]
            if type(previous) == "table" and now - (tonumber(previous.verifiedAt) or 0) <= ACTIVE_STALE_MS then
                nextActive[token] = previous
            end
        end
    end
    local changed = not SameIdentitySet(V.active, nextActive)
    V.active = nextActive
    local activeCount = 0
    for _ in pairs(nextActive) do activeCount = activeCount + 1 end
    V.activeCount = activeCount
    if failures > 0 then V.lastError = "Sac Aura 读取失败 " .. tostring(failures) .. " 个候选；短暂保留最近已验证状态"
    elseif V.scanFailures <= 0 then V.lastError = nil end
    if changed then Publish(reason or "aura_scan") end
    return true
end

local function ScheduleAuraEdge()
    if V.running ~= true or V.candidateCount <= 0 or S.Scheduler == nil or type(S.Scheduler.AddOneShot) ~= "function" then return true end
    S.Scheduler:RemoveTask(AURA_EDGE_TASK)
    local ok = S.Scheduler:AddOneShot(AURA_EDGE_TASK, 120, function()
        if V.running == true then Feature:ScanSacAuras("buff_update") end
    end, Feature, "P2", 1)
    if ok == true and type(S.Scheduler.SetTaskModule) == "function" then S.Scheduler:SetTaskModule(AURA_EDGE_TASK, Feature.Id, true) end
    return ok == true
end

function Feature:StartSacObservation(reason)
    if V.running == true then return true end
    local roster, aura = TeamRoster(), Aura()
    if type(roster) ~= "table" or type(roster.AcquireConsumer) ~= "function" then return false, "TeamRosterV3 unavailable" end
    if type(aura) ~= "table" or type(aura.AcquireConsumer) ~= "function" then return false, "AuraObservationV3 unavailable" end
    local ok, err = roster:AcquireConsumer(ROSTER_TOKEN, { purpose = "team_sac_candidates" })
    if ok ~= true then return false, err or "team roster acquire failed" end
    V.rosterHeld = true
    ok, err = aura:AcquireConsumer(AURA_TOKEN, { purpose = "team_sac_overlay" })
    if ok ~= true then
        local released, releaseErr = roster:ReleaseConsumer(ROSTER_TOKEN)
        if released == true then V.rosterHeld = false end
        if released ~= true then
            return false, tostring(err or "aura acquire failed") .. "; roster rollback failed: " .. tostring(releaseErr or "unknown")
        end
        return false, err or "aura acquire failed"
    end
    V.auraHeld = true
    V.running = true

    if S.Events ~= nil and type(S.Events.SubscribeInternal) == "function" then
        S.Events:SubscribeInternal("v3.team_roster.updated", V.eventOwner, function() Feature:ScanSacCandidates("roster_updated") end)
    end
    if S.Events ~= nil and type(S.Events.SubscribeOptional) == "function" then
        -- BUFF_UPDATE is an acceleration edge only.  The 1.2s bounded safety
        -- scan remains authoritative when this optional event is absent.
        S.Events:SubscribeOptional("BUFF_UPDATE", V.eventOwner, function() ScheduleAuraEdge() end)
    end
    if S.Scheduler == nil or type(S.Scheduler.AddTask) ~= "function" then
        local stopped, stopErr = self:StopSacObservation("scheduler_missing")
        return false, stopped == true and "Scheduler unavailable" or ("Scheduler unavailable; cleanup failed: " .. tostring(stopErr or "unknown"))
    end
    ok = S.Scheduler:AddTask(CANDIDATE_TASK, 10000, function()
        if V.running == true then Feature:ScanSacCandidates("candidate_safety") end
    end, false, Feature, "P3", 1)
    if ok ~= true then
        local stopped, stopErr = self:StopSacObservation("candidate_task_failed")
        return false, stopped == true and "Sac candidate task failed" or ("Sac candidate task failed; cleanup failed: " .. tostring(stopErr or "unknown"))
    end
    if type(S.Scheduler.SetTaskModule) == "function" then S.Scheduler:SetTaskModule(CANDIDATE_TASK, Feature.Id, true) end
    self:ScanSacCandidates(reason or "sac_start")
    Publish("sac_started")
    return true
end

local function QuiesceSacObservation(reason)
    if S.Scheduler ~= nil then
        S.Scheduler:RemoveTask(CANDIDATE_TASK)
        S.Scheduler:RemoveTask(AURA_TASK)
        S.Scheduler:RemoveTask(AURA_EDGE_TASK)
    end
    if S.Events ~= nil then
        if type(S.Events.UnsubscribeOwner) == "function" then S.Events:UnsubscribeOwner(V.eventOwner) end
        if type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(V.eventOwner) end
    end
    local changed = V.running == true or V.activeCount > 0 or V.candidateCount > 0
    V.running, V.candidates, V.active = false, {}, {}
    V.candidateCount, V.activeCount, V.rosterRevision = 0, 0, 0
    if changed then Publish(reason or "sac_stopped") end
    return true
end

function Feature:StopSacObservation(reason)
    if V.running ~= true and V.auraHeld ~= true and V.rosterHeld ~= true then
        return QuiesceSacObservation(reason or "sac_already_stopped")
    end

    -- Demand::Release is transactional: a failed reconcile restores the held
    -- consumer.  Release Aura first; if the roster release then fails, reacquire
    -- Aura before returning so an enabled Feature is never left half-observing.
    local auraReleased = false
    if V.auraHeld == true then
        local aura = Aura()
        if type(aura) ~= "table" or type(aura.ReleaseConsumer) ~= "function" then
            return false, "AuraObservationV3 release unavailable"
        end
        local released, releaseErr = aura:ReleaseConsumer(AURA_TOKEN)
        if released ~= true then return false, releaseErr or "aura release failed" end
        V.auraHeld, auraReleased = false, true
    end

    if V.rosterHeld == true then
        local roster = TeamRoster()
        if type(roster) ~= "table" or type(roster.ReleaseConsumer) ~= "function" then
            if auraReleased == true then
                local aura = Aura()
                local rollbackOk = type(aura) == "table" and type(aura.AcquireConsumer) == "function"
                    and aura:AcquireConsumer(AURA_TOKEN, { purpose = "team_sac_overlay", reason = "stop_rollback" })
                V.auraHeld = rollbackOk == true
            end
            return false, "TeamRosterV3 release unavailable"
        end
        local released, releaseErr = roster:ReleaseConsumer(ROSTER_TOKEN)
        if released ~= true then
            if auraReleased == true then
                local aura = Aura()
                local rollbackOk, rollbackErr = false, nil
                if type(aura) == "table" and type(aura.AcquireConsumer) == "function" then
                    rollbackOk, rollbackErr = aura:AcquireConsumer(AURA_TOKEN, { purpose = "team_sac_overlay", reason = "stop_rollback" })
                end
                V.auraHeld = rollbackOk == true
                if rollbackOk ~= true then
                    QuiesceSacObservation("sac_stop_rollback_failed")
                    return false, tostring(releaseErr or "roster release failed") .. "; Aura rollback failed: " .. tostring(rollbackErr or "unknown")
                end
            end
            return false, releaseErr or "team roster release failed"
        end
        V.rosterHeld = false
    end

    return QuiesceSacObservation(reason or "sac_stopped")
end

local function ReadRosterMarks()
    local roster = TeamRoster()
    if type(roster) ~= "table" or type(roster.GetSnapshot) ~= "function" then return nil, "TeamRosterV3 unavailable" end
    if S.Api == nil or type(S.Api.CallCapability) ~= "function" then return nil, "API boundary unavailable" end
    local snapshot = roster:GetSnapshot()
    local members = type(snapshot) == "table" and type(snapshot.members) == "table" and snapshot.members or {}
    local rows, seenName, seenMarker, failures = {}, {}, {}, 0
    for index = 1, math.min(MAX_ROSTER, #members) do
        if #rows >= MAX_SAVED_MARKS then break end
        local member = members[index]
        local token = Trim(type(member) == "table" and member.unitToken or nil)
        local name = Trim(type(member) == "table" and member.name or nil)
        if token ~= "" and name ~= "" then
            local ok, marker = S.Api:CallCapability("X2Unit:GetOverHeadMarker", rawget(_G, "X2Unit"), "GetOverHeadMarker", token)
            marker = tonumber(marker)
            if ok == true and marker ~= nil then
                marker = math.floor(marker)
                if marker >= 1 and marker <= MarkerMax() and seenName[name] ~= true and seenMarker[marker] ~= true then
                    seenName[name], seenMarker[marker] = true, true
                    rows[#rows + 1] = { name = name, markerIndex = marker }
                end
            elseif ok ~= true then failures = failures + 1 end
        end
    end
    rows = NormalizeSavedMarks(rows)
    return rows, nil, failures
end

function Feature:SaveCurrentRaidMarkers()
    local rows, err, failures = ReadRosterMarks()
    if rows == nil then return false, err end
    local ok, persistErr = Mutate("team_marker_save", function(state) state.savedMarks = rows; return true end, { durable = true })
    if ok ~= true then return false, persistErr end
    V.markerStatus = #rows > 0 and "saved" or "empty"
    V.markerError = (tonumber(failures) or 0) > 0 and ("部分成员标记读取失败：" .. tostring(failures)) or nil
    V.markerQueued, V.markerApplied, V.markerSkipped = #rows, 0, 0
    Publish("markers_saved")
    return true, #rows
end

local function CurrentRosterByName()
    local roster = TeamRoster()
    if type(roster) ~= "table" or type(roster.GetSnapshot) ~= "function" then return nil, "TeamRosterV3 unavailable" end
    local snapshot = roster:GetSnapshot()
    local map = {}
    for index = 1, math.min(MAX_ROSTER, #(type(snapshot) == "table" and type(snapshot.members) == "table" and snapshot.members or {})) do
        local member = snapshot.members[index]
        local name = Trim(type(member) == "table" and member.name or nil)
        local token = Trim(type(member) == "table" and member.unitToken or nil)
        if name ~= "" and token ~= "" and map[name] == nil then map[name] = token end
    end
    return map
end

local function StopMarkerRestore(status, err)
    if S.Scheduler ~= nil then S.Scheduler:RemoveTask(MARK_RESTORE_TASK) end
    V.markerStatus = status or "stopped"
    V.markerError = err
    V.restoreQueue, V.restoreIndex, V.restorePending = nil, 0, nil
    Publish("marker_restore_" .. tostring(status or "stopped"))
    return err == nil
end

function Feature:RestoreSavedRaidMarkers()
    if V.restoreQueue ~= nil then return false, "标记恢复队列正在运行" end
    local saved = NormalizeSavedMarks(V.state.savedMarks)
    if #saved == 0 then return false, "没有已保存的团队头标" end
    local rosterByName, rosterErr = CurrentRosterByName()
    if rosterByName == nil then return false, rosterErr end
    local queue, skipped = {}, 0
    for _, row in ipairs(saved) do
        local token = rosterByName[row.name]
        if token ~= nil then queue[#queue + 1] = { name = row.name, unitToken = token, markerIndex = row.markerIndex }
        else skipped = skipped + 1 end
    end
    if #queue == 0 then return false, "当前团队中没有已保存标记对应的成员" end
    if S.Scheduler == nil or type(S.Scheduler.AddTask) ~= "function" then return false, "Scheduler unavailable" end
    V.restoreQueue, V.restoreIndex, V.restorePending = queue, 0, nil
    V.markerStatus, V.markerError = "restoring", nil
    V.markerQueued, V.markerApplied, V.markerSkipped = #queue, 0, skipped
    local ok = S.Scheduler:AddTask(MARK_RESTORE_TASK, 1100, function()
        if S.FeatureRuntime == nil or S.FeatureRuntime:IsEnabled(Feature.Id) ~= true then StopMarkerRestore("stopped", "团队中心已关闭，标记恢复停止"); return end
        if V.restorePending ~= nil then
            local pending = V.restorePending
            local readOk, current = S.Api:CallCapability("X2Unit:GetOverHeadMarker", rawget(_G, "X2Unit"), "GetOverHeadMarker", pending.unitToken)
            if readOk ~= true or tonumber(current) ~= tonumber(pending.markerIndex) then
                StopMarkerRestore("failed", "标记写入未通过读回验证：" .. tostring(pending.name)); return
            end
            V.markerApplied = V.markerApplied + 1
            V.restorePending = nil
            Publish("marker_verified")
        end
        local nextIndex = V.restoreIndex + 1
        local row = V.restoreQueue and V.restoreQueue[nextIndex] or nil
        if row == nil then StopMarkerRestore("complete", nil); return end

        -- Never perform a marker write when the current state cannot be read.
        -- Already-correct rows count as applied without consuming a native
        -- write/cooldown slot; changed rows still require post-write readback.
        local currentOk, currentMarker = S.Api:CallCapability("X2Unit:GetOverHeadMarker", rawget(_G, "X2Unit"), "GetOverHeadMarker", row.unitToken)
        if currentOk ~= true then StopMarkerRestore("failed", "标记写入前读取失败：" .. tostring(row.name)); return end
        if tonumber(currentMarker) == tonumber(row.markerIndex) then
            V.restoreIndex = nextIndex
            V.markerApplied = V.markerApplied + 1
            Publish("marker_already_correct")
            return
        end

        local actionOk, actionErr = S.Api:ActionCapability("X2Unit:SetOverHeadMarker", rawget(_G, "X2Unit"), "SetOverHeadMarker", row.unitToken, row.markerIndex)
        if actionOk ~= true then StopMarkerRestore("failed", tostring(actionErr or ("标记写入失败：" .. tostring(row.name)))); return end
        V.restoreIndex = nextIndex
        V.restorePending = row
        Publish("marker_write_requested")
    end, false, Feature, "P1", 1)
    if ok ~= true then V.restoreQueue = nil; return false, "标记恢复任务创建失败" end
    if type(S.Scheduler.SetTaskModule) == "function" then S.Scheduler:SetTaskModule(MARK_RESTORE_TASK, Feature.Id, true) end
    Publish("marker_restore_started")
    return true, #queue
end

function Feature:ClearSavedRaidMarkers()
    if V.restoreQueue ~= nil then return false, "标记恢复队列运行中，不能清空保存" end
    local ok, err = Mutate("team_marker_clear_saved", function(state) state.savedMarks = {}; return true end, { durable = true })
    if ok ~= true then return false, err end
    V.markerStatus, V.markerError = "idle", nil
    V.markerQueued, V.markerApplied, V.markerSkipped = 0, 0, 0
    Publish("markers_cleared")
    return true
end

-- Wrap the existing Feature lifecycle.  This extension is loaded after the
-- business bridge but before FeatureRuntime initialization, so both stores are
-- loaded transactionally before the first enable decision.
local BaseInitialize, BaseEnable, BaseDisable, BaseGetProjection = Feature.Initialize, Feature.Enable, Feature.Disable, Feature.GetProjection
function Feature:Initialize()
    local ok, err = BaseInitialize(self)
    if ok ~= true then return false, err end
    if V.loaded == true then return true end
    local status, _, loadErr = P:LoadStore(STORE_ID)
    if status ~= true and status ~= "empty" then return false, loadErr or tostring(status or "team visuals store load failed") end
    if status == "empty" then V.state = NormalizeState({}) end
    V.loaded = true
    return true
end

function Feature:Enable(reason)
    local ok, err = BaseEnable(self, reason)
    if ok ~= true then return false, err end
    if V.state.sacEnabled == true then
        local started, startErr = self:StartSacObservation("feature_enable")
        if started ~= true then BaseDisable(self, "team_visual_enable_rollback"); return false, startErr end
    end
    return true
end

function Feature:Disable(reason)
    if V.restoreQueue ~= nil then StopMarkerRestore("stopped", "团队中心已关闭，标记恢复停止") end
    local stopped, stopErr = self:StopSacObservation("feature_disable")
    if stopped ~= true then return false, stopErr end
    return BaseDisable(self, reason)
end

function Feature:GetProjection()
    local projection = BaseGetProjection(self) or {}
    projection.teamVisualRevision = tonumber(V.visualRevision) or 0
    projection.sacEnabled = V.state.sacEnabled == true
    projection.sacRunning = V.running == true
    projection.sacCandidateCount = tonumber(V.candidateCount) or 0
    projection.sacActiveCount = tonumber(V.activeCount) or 0
    projection.sacActive = {}
    for _, row in pairs(V.active) do projection.sacActive[#projection.sacActive + 1] = { unitToken = row.unitToken, name = row.name } end
    table.sort(projection.sacActive, function(a, b) return tostring(a.name or a.unitToken) < tostring(b.name or b.unitToken) end)
    projection.sacError = V.lastError
    projection.savedMarkerCount = #(type(V.state.savedMarks) == "table" and V.state.savedMarks or {})
    projection.markerStatus = V.markerStatus
    projection.markerError = V.markerError
    projection.markerQueued = tonumber(V.markerQueued) or 0
    projection.markerApplied = tonumber(V.markerApplied) or 0
    projection.markerSkipped = tonumber(V.markerSkipped) or 0
    projection.markerRestoreRunning = V.restoreQueue ~= nil
    return projection
end

Feature.Commands.SetSacHighlightEnabled = function(_, enabled)
    local target = enabled == true
    local previous = V.state.sacEnabled == true
    if target == previous then return true end
    local runtimeEnabled = S.FeatureRuntime ~= nil and S.FeatureRuntime:IsEnabled(Feature.Id) == true

    -- Runtime lease and persistent intent commit as one user-visible action.
    -- Enable acquires first, disable releases first; persistence failure rolls
    -- the runtime side back so UI/Store/Service demand cannot silently diverge.
    if runtimeEnabled == true and target == true then
        local started, startErr = Feature:StartSacObservation("setting_enabled")
        if started ~= true then return false, startErr end
        local ok, err = Mutate("team_sac_enabled", function(state) state.sacEnabled = true; return true end)
        if ok ~= true then
            local stopped, stopErr = Feature:StopSacObservation("setting_enable_persist_rollback")
            if stopped ~= true then return false, tostring(err or "save failed") .. "; runtime rollback failed: " .. tostring(stopErr or "unknown") end
            return false, err
        end
    elseif runtimeEnabled == true and target == false then
        local stopped, stopErr = Feature:StopSacObservation("setting_disabled")
        if stopped ~= true then return false, stopErr end
        local ok, err = Mutate("team_sac_enabled", function(state) state.sacEnabled = false; return true end)
        if ok ~= true then
            local restarted, restartErr = Feature:StartSacObservation("setting_disable_persist_rollback")
            if restarted ~= true then return false, tostring(err or "save failed") .. "; runtime rollback failed: " .. tostring(restartErr or "unknown") end
            return false, err
        end
    else
        local ok, err = Mutate("team_sac_enabled", function(state) state.sacEnabled = target; return true end)
        if ok ~= true then return false, err end
    end
    Publish("sac_setting")
    return true
end
Feature.Commands.SaveRaidMarkers = function() return Feature:SaveCurrentRaidMarkers() end
Feature.Commands.RestoreRaidMarkers = function() return Feature:RestoreSavedRaidMarkers() end
Feature.Commands.ClearSavedRaidMarkers = function() return Feature:ClearSavedRaidMarkers() end

-- Append extension dependencies for diagnostics/gates without duplicating the
-- Runtime implementation or creating a second lifecycle toggle.
local seen = {}
for _, value in ipairs(type(Feature.ApiDependencies) == "table" and Feature.ApiDependencies or {}) do seen[value] = true end
for _, value in ipairs({ "X2Unit:GetTargetAbilityTemplates", "X2Unit:GetOverHeadMarker", "X2Unit:SetOverHeadMarker" }) do
    if seen[value] ~= true then Feature.ApiDependencies[#Feature.ApiDependencies + 1] = value; seen[value] = true end
end

Feature.TeamVisualContractVersion = 1
Feature.TeamMarkerSnapshotContractVersion = 1
Feature.TeamSacContractVersion = 1

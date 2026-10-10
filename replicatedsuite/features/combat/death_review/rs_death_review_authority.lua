------------------------------------------------------------------------
-- Replicated Suite V3 - Death Review Authority
--
-- Owns the low-cost death-review Domain only: incoming SELF damage ring,
-- optional Aura snapshots, death-window records and history projection.
-- Native combat handlers remain exclusively owned by CombatEventBusV3.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local F = S.Features and S.Features.DeathReview or nil
if type(F) ~= "table" then return end
local Identity = S.Services and S.Services.UnitIdentityV3 or nil
local Aura = S.Services and S.Services.AuraObservationV3 or nil
local U = S.Utils

local A = {
    version = 2,
    incoming = {},
    debuffSamples = {},
    debuffSampleTask = "death_review_debuff_sample",
    debuffSampleScheduled = false,
    debuffDeferred = 0,
    debuffDeferFailures = 0,
    revision = 0,
    incomingAccepted = 0,
    incomingIgnored = 0,
    deaths = 0,
    debuffReads = 0,
    debuffFailures = 0,
    debuffSampleSkips = 0,
    lastDebuffSampleAt = 0,
    debuffSampleMinIntervalMs = 150,
    duplicateDeathNotices = 0,
    persistenceFailures = 0,
    volatileRecord = nil,
    lastDeathNoticeAt = 0,
    maxIncoming = 96,
    maxDebuffSamples = 8,
    maxDebuffsPerSample = 32,
    pendingDeath = nil,
    finalizeScheduled = false,
    deferredFinalizes = 0,
    deferredFinalizeFailures = 0,
}
F.Authority = A

local function NowMs() return math.max(0, tonumber(S.NowMs and S.NowMs()) or 0) end
local function Trim(value) return U and U.Trim and U.Trim(value) or (tostring(value or ""):match("^%s*(.-)%s*$") or "") end
local function DeepCopy(value) return U and U.DeepCopy and U.DeepCopy(value) or value end

local function Publish(reason, record)
    A.revision = A.revision + 1
    if S.Events ~= nil and type(S.Events.Publish) == "function" then
        S.Events:Publish("v3.death_review.updated", A.revision, tostring(reason or "update"), record)
    end
end

local function CurrentClockText()
    local value = U ~= nil and type(U.GetServerTime) == "function" and U.GetServerTime() or nil
    if type(value) == "table" then
        return string.format("%02d:%02d:%02d", tonumber(value.hour) or 0, tonumber(value.minute) or 0, tonumber(value.second) or 0)
    end
    return "--:--:--"
end

local function IsSelfName(value)
    if Identity == nil or type(Identity.IsPlayerName) ~= "function" then return false end
    if type(Identity.IsPlayerIdentityReady) == "function" and Identity:IsPlayerIdentityReady() ~= true
        and type(Identity.RefreshPlayerIdentity) == "function" then Identity:RefreshPlayerIdentity(false) end
    return Identity:IsPlayerName(value)
end

function A:ResetTransient()
    self.incoming = {}
    self.debuffSamples = {}
    self.lastDebuffSampleAt = 0
    self.debuffSampleScheduled = false
    self.debuffSampleForceRefresh = false
    self.pendingDeath = nil
    self.finalizeScheduled = false
    if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then
        S.Scheduler:RemoveTask("death_review_finalize")
        S.Scheduler:RemoveTask(self.debuffSampleTask)
    end
    return true
end

-- Routine Debuff sampling must never run inside the native COMBAT_MSG
-- callback. The callback only records that a sample is due; the actual Native
-- Aura read happens on the shared Scheduler so it is covered by FrameBudget
-- and can never add latency to the game's combat event dispatch.
function A:RequestDebuffSample(now, forceRefresh)
    local settings = F:GetSettings()
    if settings.showDebuffs ~= true or F.auraConsumerHeld ~= true or self.pendingDeath ~= nil then return true end
    if forceRefresh == true then self.debuffSampleForceRefresh = true end
    now = tonumber(now) or NowMs()
    if self.debuffSampleScheduled == true then return true end
    local delay = math.max(0, (tonumber(self.debuffSampleMinIntervalMs) or 150) - (now - (tonumber(self.lastDebuffSampleAt) or 0)))
    if delay > 0 then
        self.debuffSampleSkips = self.debuffSampleSkips + 1
    end
    local scheduler = S.Scheduler
    if type(scheduler) ~= "table" or type(scheduler.AddOneShot) ~= "function" then
        -- 调度不可用时明确留失败证据，不能把两路 Native 扫描退回战斗回调。
        self.debuffDeferFailures = self.debuffDeferFailures + 1
        return false, "scheduler unavailable for death status sample"
    end
    self.debuffSampleScheduled = true
    local added = scheduler:AddOneShot(self.debuffSampleTask, delay, function()
        A.debuffSampleScheduled = false
        local refresh = A.debuffSampleForceRefresh == true
        A.debuffSampleForceRefresh = false
        if F.enabled ~= true then return true end
        local sampled, sampleErr = A:SampleDebuffs(nil, refresh)
        if sampled == false then
            A.debuffDeferFailures = A.debuffDeferFailures + 1
            return false, sampleErr
        end
        A.debuffDeferred = A.debuffDeferred + 1
        return true
    end, self, "P4", 1)
    if added ~= true then
        self.debuffSampleScheduled = false
        self.debuffDeferFailures = self.debuffDeferFailures + 1
        return false, "death status sample schedule rejected"
    end
    return true
end

function A:RequestFinalizeDeath(noticeAt, noticeSequence)
    noticeAt = tonumber(noticeAt) or NowMs()
    noticeSequence = math.max(0, tonumber(noticeSequence) or 0)
    self.pendingDeath = { noticeAt = noticeAt, noticeSequence = noticeSequence }
    if self.finalizeScheduled == true then return true end
    local scheduler = S.Scheduler
    if type(scheduler) ~= "table" or type(scheduler.AddOneShot) ~= "function" then
        self.deferredFinalizeFailures = self.deferredFinalizeFailures + 1
        return false, "scheduler unavailable for death finalize"
    end
    self.finalizeScheduled = true
    local added = scheduler:AddOneShot("death_review_finalize", 50, function()
        A.finalizeScheduled = false
        local request = A.pendingDeath
        A.pendingDeath = nil
        if type(request) ~= "table" or F.enabled ~= true then return true end
        local ok, err = xpcall(function() return A:FinalizeDeath(request.noticeAt, request.noticeSequence) end, S.SafeTraceback)
        if ok ~= true then
            A.deferredFinalizeFailures = A.deferredFinalizeFailures + 1
            if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.WarningRateLimited) == "function" then
                S.DiagnosticsManager:WarningRateLimited("death_review_v3", "DEATH_REVIEW_DEFERRED_FINALIZE_FAILED", 3000,
                    "死亡回顾延迟收尾失败", { error = tostring(err) })
            end
            return false
        end
        A.deferredFinalizes = A.deferredFinalizes + 1
        return true
    end, self, "P2", 2)
    if added ~= true then
        self.finalizeScheduled = false
        self.deferredFinalizeFailures = self.deferredFinalizeFailures + 1
        return false, "death finalize schedule rejected"
    end
    return true
end

function A:PruneIncoming(now)
    local settings = F:GetSettings()
    local keepMs = math.max(15000, tonumber(settings.windowMs) or 10000) + 3000
    local cutoff = now - keepMs
    while #self.incoming > 0 and ((tonumber(self.incoming[1].time) or 0) < cutoff or #self.incoming > self.maxIncoming) do
        table.remove(self.incoming, 1)
    end
end

function A:SampleDebuffs(now, force)
    local settings = F:GetSettings()
    if settings.showDebuffs ~= true or F.auraConsumerHeld ~= true or self.pendingDeath ~= nil then return true end
    now = tonumber(now) or NowMs()
    if force ~= true and now - (tonumber(self.lastDebuffSampleAt) or 0) < (tonumber(self.debuffSampleMinIntervalMs) or 150) then
        self.debuffSampleSkips = self.debuffSampleSkips + 1
        return true
    end
    self.lastDebuffSampleAt = now
    if Aura == nil or type(Aura.GetSnapshot) ~= "function" then self.debuffFailures = self.debuffFailures + 1; return false end
    self.debuffReads = self.debuffReads + 1
    local snapshot, err = Aura:GetSnapshot("player", {
        buff = true, hidden = false, debuff = true,
        buffLimit = self.maxDebuffsPerSample,
        debuffLimit = self.maxDebuffsPerSample,
        ttlMs = force == true and 0 or 120,
        forceRefresh = force == true,
    })
    if type(snapshot) ~= "table" then
        self.debuffFailures = self.debuffFailures + 1
        return false, err
    end
    -- 两路分别归一，不能让相同效果ID跨 Buff/Debuff 合并而丢失归属。
    local sample = { time = tonumber(snapshot.at) or now, debuffs = {}, buffs = {}, statusSnapshot = {} }
    for _, lane in ipairs({ "buff", "debuff" }) do
        local observed = snapshot[lane]
        if type(observed) == "table" and tonumber(observed.at) then sample.time = math.min(sample.time, observed.at) end
        local state = "unavailable"
        if type(observed) == "table" and observed.available == true then
            state = observed.complete == true and observed.reliable == true and "complete" or "partial"
        end
        sample.statusSnapshot[lane] = state
        if type(observed) == "table" and observed.available == true then
            local map = Aura:GetStatusMap(snapshot, { buff = lane == "buff", debuff = lane == "debuff", hidden = false })
            local target = lane == "buff" and sample.buffs or sample.debuffs
            local seen = {}
            for _, raw in ipairs(observed.rows or {}) do
                local id = tonumber(raw.effectId)
                local row = id and map[id] or nil
                if row and not seen[id] and #target < self.maxDebuffsPerSample then
                    seen[id] = true
                    target[#target + 1] = { effectId = id, name = row.name, stack = row.stack,
                        path = row.iconPath ~= "" and row.iconPath or nil, timeLeft = row.timeKnown == true and row.timeLeft or nil }
                elseif row == nil then
                    sample.statusSnapshot[lane] = "partial"
                end
            end
            if (tonumber(observed.count) or 0) > self.maxDebuffsPerSample then sample.statusSnapshot[lane] = "partial" end
        end
    end
    self.debuffSamples[#self.debuffSamples + 1] = sample
    while #self.debuffSamples > self.maxDebuffSamples do table.remove(self.debuffSamples, 1) end
    return true
end

function A:CopyDeathStatus(now)
    local selected = nil
    for _, sample in ipairs(self.debuffSamples) do
        if (tonumber(sample.time) or 0) <= now and (selected == nil or sample.time >= selected.time) then selected = sample end
    end
    if selected == nil then return { buffs = {}, debuffs = {}, statusSnapshot = { buff = "uncollected", debuff = "uncollected" } } end
    local copy = DeepCopy(selected)
    copy.statusSnapshot.time = copy.time
    return copy
end

function A:CopyDeathDebuffs(now)
    return self:CopyDeathStatus(now).debuffs
end

function A:OnCombatFact(fact)
    if F.enabled ~= true or type(fact) ~= "table" then return end
    if fact.kind == "death_notice" then
        if IsSelfName(fact.subjectName) then
            local noticeAt = tonumber(fact.receivedAt) or NowMs()
            if noticeAt - (tonumber(self.lastDeathNoticeAt) or 0) <= 1200 then
                self.duplicateDeathNotices = self.duplicateDeathNotices + 1
            else
                self.lastDeathNoticeAt = noticeAt
                local queued, queueErr = self:RequestFinalizeDeath(noticeAt, fact.sequence)
                if queued ~= true and S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.WarningRateLimited) == "function" then
                    S.DiagnosticsManager:WarningRateLimited("death_review_v3", "DEATH_REVIEW_FINALIZE_QUEUE_FAILED", 3000,
                        "死亡回顾收尾未能进入统一调度器", { error = tostring(queueErr) })
                end
            end
        end
        return
    end
    if fact.category ~= "damage" or (tonumber(fact.amount) or 0) <= 0 then return end
    if IsSelfName(fact.targetName) ~= true then self.incomingIgnored = self.incomingIgnored + 1; return end
    local settings = F:GetSettings()
    local amount = math.max(0, math.floor((tonumber(fact.amount) or 0) + 0.5))
    if amount < math.max(0, tonumber(settings.minDamage) or 0) then self.incomingIgnored = self.incomingIgnored + 1; return end
    local now = tonumber(fact.receivedAt) or NowMs()
    local source = fact.environmental == true and "环境" or Trim(fact.sourceName)
    if source == "" then source = "未知来源" end
    local ability = Trim(fact.abilityName)
    if ability == "" or ability == "HEALTH" then ability = fact.environmental == true and "环境伤害" or "普通攻击" end
    self.incoming[#self.incoming + 1] = {
        time = now,
        sequence = math.max(0, tonumber(fact.sequence) or 0),
        source = source,
        ability = ability,
        -- RU MELEE_DAMAGE 的 rawAbilityId 是伤害金额；仅 spell_damage 携带真实技能ID。
        abilityId = fact.kind == "spell_damage" and tonumber(fact.rawAbilityId) and tonumber(fact.rawAbilityId) > 0
            and math.floor(tonumber(fact.rawAbilityId)) or nil,
        amount = amount,
        environmental = fact.environmental == true and true or nil,
    }
    self.incomingAccepted = self.incomingAccepted + 1
    self:PruneIncoming(now)
    if settings.showDebuffs == true then self:RequestDebuffSample(now) end
end

function A:TrimHistory()
    local maximum = math.max(1, math.min(30, math.floor(tonumber(F:GetSettings().maxHistory) or 10)))
    local entries = F.State.history.entries
    while #entries > maximum do table.remove(entries, 1) end
    return true
end

function A:FinalizeDeath(noticeAt, noticeSequence)
    local settings = F:GetSettings()
    noticeAt = tonumber(noticeAt) or NowMs()
    noticeSequence = math.max(0, tonumber(noticeSequence) or math.huge)
    -- 死亡后客户端会清空状态；仅冻结通知前观测，收尾禁止强制重读。
    self.debuffSampleScheduled = false
    if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(self.debuffSampleTask) end
    local captured = settings.showDebuffs == true and self:CopyDeathStatus(noticeAt)
        or { buffs = {}, debuffs = {}, statusSnapshot = { buff = "disabled", debuff = "disabled" } }
    local anchorAt = noticeAt
    local latest = self.incoming[#self.incoming]
    local latestAt = latest ~= nil and tonumber(latest.time) or nil
    if latestAt ~= nil and latestAt <= noticeAt + 250 and noticeAt - latestAt <= 2000 then anchorAt = latestAt end
    local cutoff = anchorAt - settings.windowMs
    local events, total = {}, 0
    for _, event in ipairs(self.incoming) do
        local at = tonumber(event.time) or 0
        if at >= cutoff and at <= anchorAt + 250 and (tonumber(event.sequence) or 0) <= noticeSequence then
            local copy = DeepCopy(event)
            local metadata = S.Services and S.Services.SkillMetadataV3
            if copy.abilityId and metadata and type(metadata.GetSkillInfo) == "function" then
                copy.iconPath = (metadata:GetSkillInfo(copy.abilityId, copy.ability) or {}).iconPath
            end
            events[#events + 1] = copy
            total = total + (tonumber(copy.amount) or 0)
        end
    end
    local lethal = events[#events]
    local nextSerial = math.max(0, tonumber(F.State.history.serial) or 0) + 1
    local record = {
        schemaVersion = 2,
        serial = nextSerial,
        time = anchorAt,
        noticeTime = noticeAt,
        clock = CurrentClockText(),
        windowMs = settings.windowMs,
        totalDamage = math.floor(total + 0.5),
        lethal = lethal and DeepCopy(lethal) or nil,
        events = events,
        debuffs = captured.debuffs,
        buffs = captured.buffs,
        statusSnapshot = captured.statusSnapshot,
    }
    local committed, committedRecord = F:CommitDeathRecord(record)
    if committed == true then
        record = committedRecord or record
        self.volatileRecord = nil
    else
        self.persistenceFailures = self.persistenceFailures + 1
        self.volatileRecord = DeepCopy(record)
        if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.WarningRateLimited) == "function" then
            S.DiagnosticsManager:WarningRateLimited("death_review_v3", "DEATH_REVIEW_RECORD_COMMIT_FAILED", 3000,
                "死亡回顾记录未能持久化，当前会话仍保留最近一次临时记录", { serial = nextSerial, error = tostring(committedRecord) })
        end
    end
    self.deaths = self.deaths + 1
    self:ResetTransient()
    Publish("death", record)
    return record
end

function A:GetHistoryRows(limit)
    local settingLimit = math.max(1, math.min(30, math.floor(tonumber(F:GetSettings().maxHistory) or 10)))
    limit = math.max(1, math.min(settingLimit, math.floor(tonumber(limit) or settingLimit)))
    local rows, entries = {}, F.State.history.entries
    local first = math.max(1, #entries - limit + 1)
    for index = #entries, first, -1 do
        local meta = entries[index]
        rows[#rows + 1] = {
            serial = tonumber(meta.serial) or index,
            clock = tostring(meta.clock or "--:--:--"),
            totalDamage = math.max(0, tonumber(meta.totalDamage) or 0),
            lethalSource = tostring(meta.lethalSource or "--"),
            lethalAbility = tostring(meta.lethalAbility or "--"),
            lethalAmount = math.max(0, tonumber(meta.lethalAmount) or 0),
            eventCount = math.max(0, tonumber(meta.eventCount) or 0),
            debuffCount = math.max(0, tonumber(meta.debuffCount) or 0),
            persisted = true,
        }
    end
    local volatile = self.volatileRecord
    if type(volatile) == "table" and (#rows == 0 or tonumber(rows[1].serial) ~= tonumber(volatile.serial)) then
        local lethal = type(volatile.lethal) == "table" and volatile.lethal or {}
        table.insert(rows, 1, {
            serial = tonumber(volatile.serial) or 0, clock = tostring(volatile.clock or "--:--:--"),
            totalDamage = math.max(0, tonumber(volatile.totalDamage) or 0),
            lethalSource = "[未保存] " .. tostring(lethal.source or "--"), lethalAbility = tostring(lethal.ability or "--"),
            lethalAmount = math.max(0, tonumber(lethal.amount) or 0),
            eventCount = type(volatile.events) == "table" and #volatile.events or 0,
            debuffCount = type(volatile.debuffs) == "table" and #volatile.debuffs or 0, persisted = false,
        })
        while #rows > limit do table.remove(rows) end
    end
    return rows, self.revision
end

function A:GetRecord(serial)
    serial = tonumber(serial)
    if type(self.volatileRecord) == "table" and (serial == nil or tonumber(self.volatileRecord.serial) == serial) then
        local latestMeta = F:FindHistoryMeta(nil)
        if serial ~= nil or latestMeta == nil or (tonumber(self.volatileRecord.time) or 0) >= (tonumber(latestMeta.time) or 0) then
            return DeepCopy(self.volatileRecord)
        end
    end
    local meta = F:FindHistoryMeta(serial)
    if meta == nil then return nil end
    local record, err = F:LoadRecord(meta.storageId)
    if type(record) ~= "table" or tonumber(record.serial) ~= tonumber(meta.serial) then
        if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.WarningRateLimited) == "function" then
            S.DiagnosticsManager:WarningRateLimited("death_review_v3", "DEATH_REVIEW_RECORD_SHARD_MISMATCH", 3000,
                "死亡回顾索引对应的记录分片不可用", { serial = tostring(meta.serial), storageId = tostring(meta.storageId), error = tostring(err) })
        end
        return nil
    end
    return DeepCopy(record)
end

function A:GetTimelineRows(serial, limit)
    local record = self:GetRecord(serial)
    if record == nil then return {}, nil end
    local rows, anchor = {}, tonumber(record.time) or 0
    for _, event in ipairs(record.events or {}) do
        rows[#rows + 1] = {
            secondsBefore = math.max(0, (anchor - (tonumber(event.time) or anchor)) / 1000),
            timeText = string.format("-%.1fs", math.max(0, (anchor - (tonumber(event.time) or anchor)) / 1000)),
            source = event.source,
            ability = event.ability,
            amount = event.amount,
            abilityId = event.abilityId,
            iconPath = event.iconPath,
        }
    end
    limit = math.max(1, math.floor(tonumber(limit) or #rows))
    while #rows > limit do table.remove(rows, 1) end
    return rows, record
end

function A:DeleteRecord(serial)
    serial = tonumber(serial)
    if serial == nil then return false, "死亡回顾记录编号无效" end
    if type(self.volatileRecord) == "table" and tonumber(self.volatileRecord.serial) == serial then
        self.volatileRecord = nil
        Publish("delete", serial)
        return true
    end
    local ok, err = F:DeleteHistoryRecord(serial)
    if ok == true then Publish("delete", serial) end
    return ok, err
end

function A:ClearHistory()
    local ok, err = F:ClearHistoryStore()
    if ok == true then self.volatileRecord = nil; Publish("clear", nil) end
    return ok, err
end

function A:GetHealth()
    return {
        ok = true,
        revision = self.revision,
        incoming = #self.incoming,
        debuffSamples = #self.debuffSamples,
        history = #F.State.history.entries,
        volatile = self.volatileRecord ~= nil,
        deaths = self.deaths,
        pendingDeath = self.pendingDeath ~= nil,
        deferredFinalizes = self.deferredFinalizes,
        deferredFinalizeFailures = self.deferredFinalizeFailures,
        incomingAccepted = self.incomingAccepted,
        incomingIgnored = self.incomingIgnored,
        debuffReads = self.debuffReads,
        debuffFailures = self.debuffFailures,
        debuffSampleSkips = self.debuffSampleSkips,
        debuffDeferred = self.debuffDeferred,
        debuffDeferFailures = self.debuffDeferFailures,
        debuffSampleScheduled = self.debuffSampleScheduled == true,
        duplicateDeathNotices = self.duplicateDeathNotices,
        persistenceFailures = self.persistenceFailures,
    }
end

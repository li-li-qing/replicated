------------------------------------------------------------------------
-- Replicated Suite - Damage Review Service
-- Team Utility owned incoming-damage/death review. Independent from DPS.
-- Uses a dedicated low-allocation COMBAT_MSG listener and Suite OnUpdate clock.
------------------------------------------------------------------------

if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local U = S.Utils
S.Services = S.Services or {}
S.Services.DamageReview = S.Services.DamageReview or {}
local R = S.Services.DamageReview
R.presentationBoundary = "event_host_only"
R.presentationDebt = nil

R.schemaVersion = 1
R.incoming = type(R.incoming) == "table" and R.incoming or {}
R.debuffSamples = type(R.debuffSamples) == "table" and R.debuffSamples or {}
R.history = {}
R.historyDirty = false
R.historyDirtyAt = 0
R.lastIncomingDamageAt = 0
R.debuffElapsed = 0
R.visibilityElapsed = 0
R.selectedHistoryIndex = 0
R.serial = math.max(0, math.floor(tonumber(R.serial) or 0))
R.autoDismissedSerial = nil
R.presenter = R.presenter or nil

local DEBUFF_SAMPLE_INTERVAL_MS = 150
local MAX_INCOMING_EVENTS = 96
local MAX_DEBUFF_SAMPLES = 8
local MAX_DEBUFFS_PER_SAMPLE = 10

local function Config()
    return S.State and S.State.settings or {}
end

local NowMs = S.Reuse.Time.NowMs


local function ReadPlayerName()
    if S.Api == nil or type(S.Api.CallCapability) ~= "function" then return nil end
    local ok, value = S.Api:CallCapability("X2Unit:UnitName", X2Unit, "UnitName", "player")
    if ok ~= true or value == nil or tostring(value) == "" then return nil end
    return tostring(value)
end

local function ReadPlayerNameWithWorld()
    if S.Api == nil or type(S.Api.CallCapability) ~= "function" then return nil end
    local ok, value = S.Api:CallCapability("X2Unit:UnitNameWithWorld", X2Unit, "UnitNameWithWorld", "player")
    if ok ~= true or value == nil or tostring(value) == "" then return nil end
    return tostring(value)
end

local function RefreshPlayerIdentity()
    R.playerName = ReadPlayerName() or R.playerName
    R.playerNameWithWorld = ReadPlayerNameWithWorld() or R.playerNameWithWorld
end

local function IsSelfName(name)
    if name == nil then return false end
    return name == R.playerName or name == R.playerNameWithWorld
end

local function IsEnvironmentalEventType(upper)
    return string.find(upper, "ENVIRONMENTAL_DAMAGE", 1, true) ~= nil
        or string.find(upper, "ENVIRONMENTAL_DMANAGE", 1, true) ~= nil
end

local function ParseDamage(eventType, abilityId, damageType, effectType)
    local upper = string.upper(tostring(eventType or ""))
    if string.find(upper, "MELEE_DAMAGE", 1, true) ~= nil then
        return math.abs(tonumber(abilityId) or 0), "DAMAGE", false
    end
    if string.find(upper, "SPELL_DAMAGE", 1, true) ~= nil then
        return math.abs(tonumber(effectType) or 0), "DAMAGE", false
    end
    if IsEnvironmentalEventType(upper) then
        return math.abs(tonumber(damageType) or 0), "DAMAGE", true
    end
    return 0, "OTHER", false
end

local function GetContentMainScriptPosVis(contentId)
    if ADDON == nil or type(ADDON.GetContentMainScriptPosVis) ~= "function" then return false end
    return pcall(ADDON.GetContentMainScriptPosVis, ADDON, contentId)
end

local function GetPlayerDebuffCount()
    if S.Api == nil or type(S.Api.CallCapability) ~= "function" then return 0 end
    local ok, value = S.Api:CallCapability("X2Unit:UnitDeBuffCount", X2Unit, "UnitDeBuffCount", "player")
    return ok == true and math.max(0, math.floor(tonumber(value) or 0)) or 0
end

local function GetPlayerDebuffTooltip(index)
    if S.Api == nil or type(S.Api.CallCapability) ~= "function" then return nil end
    local ok, value = S.Api:CallCapability("X2Unit:UnitDeBuffTooltip", X2Unit, "UnitDeBuffTooltip", "player", index)
    return ok == true and value or nil
end

local function GetPlayerDebuffEntry(index)
    if S.Api == nil or type(S.Api.CallCapability) ~= "function" then return nil end
    local ok, value = S.Api:CallCapability("X2Unit:UnitDeBuff", X2Unit, "UnitDeBuff", "player", index)
    return ok == true and value or nil
end

local function ClampInt(value, minimum, maximum, fallback)
    local n = math.floor(tonumber(value) or fallback or minimum)
    if n < minimum then n = minimum end
    if n > maximum then n = maximum end
    return n
end

local function NormalizeText(value, fallback)
    local text = U.Trim(tostring(value or ""))
    return text ~= "" and text or tostring(fallback or "")
end

local function CurrentClockText()
    if UIParent ~= nil and type(UIParent.GetServerTimeTable) == "function" then
        local ok, value = pcall(function() return UIParent:GetServerTimeTable() end)
        if ok and type(value) == "table" then
            return string.format("%02d:%02d:%02d",
                tonumber(value.hour) or 0,
                tonumber(value.minute) or 0,
                tonumber(value.second) or 0)
        end
    end
    return "--:--:--"
end

-- Presentation dependency inversion.  The service owns records, timing and
-- persistence; a Legacy/V3 presenter owns all visible widgets.  The hidden
-- eventHost used below is an ArcheAge event-subscription primitive, not UI.
function R:SetPresenter(presenter)
    if presenter ~= nil and type(presenter) ~= "table" then return false end
    if self.presenter ~= nil and self.presenter ~= presenter and type(self.presenter.HideAll) == "function" then
        pcall(self.presenter.HideAll, self.presenter)
    end
    self.presenter = presenter
    return true
end

function R:_Present(method, ...)
    local presenter = self.presenter
    local fn = presenter ~= nil and presenter[method] or nil
    if type(fn) ~= "function" then return false, nil end
    local ok, value = pcall(fn, presenter, ...)
    if not ok then
        if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.ErrorRateLimited) == "function" then
            S.DiagnosticsManager:ErrorRateLimited("damage_review", "PRESENTER_CALL_FAILED", 3000,
                "Presenter 调用失败：" .. tostring(method), { error = tostring(value), method = tostring(method) })
        end
        return false, nil
    end
    return true, value
end

function R:OpenHistory()
    local ok, value = self:_Present("OpenHistory", self)
    return ok and value ~= false
end

function R:ToggleHistory()
    local ok, value = self:_Present("ToggleHistory", self)
    return ok and value ~= false
end

function R:PruneIncoming(now)
    local cfg = Config()
    local keepMs = math.max(15000, tonumber(cfg.damageReviewWindowMs) or 10000) + 3000
    local cutoff = now - keepMs
    while #self.incoming > 0 and ((tonumber(self.incoming[1].time) or 0) < cutoff or #self.incoming > MAX_INCOMING_EVENTS) do
        table.remove(self.incoming, 1)
    end
end

function R:OnCombatMessage(eventType, sourceName, targetName, abilityId, abilityName, damageType, effectType, observedAt)
    local cfg = Config()
    if cfg.damageReviewEnabled ~= true or not IsSelfName(targetName) then return end
    local amount, category, environmental = ParseDamage(eventType, abilityId, damageType, effectType)
    amount = math.max(0, tonumber(amount) or 0)
    if category ~= "DAMAGE" or amount <= 0 or amount < math.max(0, tonumber(cfg.damageReviewMinDamage) or 0) then return end
    local now = tonumber(observedAt) or NowMs()
    local source = environmental == true and "环境" or NormalizeText(sourceName, "未知来源")
    local ability = NormalizeText(abilityName, "普通攻击")
    if ability == "HEALTH" then ability = "普通攻击" end
    if environmental == true then
        local envAbility = NormalizeText(abilityId, "环境伤害")
        if envAbility ~= "" and envAbility ~= "0" and envAbility ~= "-1" then ability = envAbility else ability = "环境伤害" end
    end
    self.incoming[#self.incoming + 1] = {
        time = now,
        source = source,
        ability = ability,
        amount = math.floor(amount + 0.5),
        environmental = environmental == true and true or nil,
    }
    self.lastIncomingDamageAt = now
    self:PruneIncoming(now)
end

function R:CaptureDebuffs(now)
    local debuffs = {}
    local count = math.min(MAX_DEBUFFS_PER_SAMPLE, GetPlayerDebuffCount())
    for index = 1, count do
        local tooltip = GetPlayerDebuffTooltip(index)
        local extra = GetPlayerDebuffEntry(index)
        if type(tooltip) == "table" then
            debuffs[#debuffs + 1] = {
                name = NormalizeText(tooltip.name, "未知 Debuff"),
                path = type(extra) == "table" and extra.path or nil,
                stack = tonumber(tooltip.stack) or 0,
            }
        end
    end
    self.debuffSamples[#self.debuffSamples + 1] = { time = now, debuffs = debuffs }
    while #self.debuffSamples > MAX_DEBUFF_SAMPLES do table.remove(self.debuffSamples, 1) end
end

function R:CopyDeathDebuffs(now)
    local selected = nil
    for _, sample in ipairs(self.debuffSamples) do
        if (tonumber(sample.time) or 0) <= now then selected = sample end
    end
    if selected == nil then selected = self.debuffSamples[#self.debuffSamples] end
    local copy = {}
    if type(selected) == "table" and type(selected.debuffs) == "table" then
        for _, debuff in ipairs(selected.debuffs) do
            copy[#copy + 1] = {
                name = debuff.name,
                path = debuff.path,
                stack = debuff.stack,
            }
        end
    end
    return copy
end

function R:TrimHistory()
    local maximum = ClampInt(Config().damageReviewMaxHistory, 1, 30, 10)
    while #self.history > maximum do table.remove(self.history, 1) end
    if self.selectedHistoryIndex > #self.history then self.selectedHistoryIndex = #self.history end
end

function R:OnDeathNotice(info1)
    local cfg = Config()
    if cfg.damageReviewEnabled ~= true or not IsSelfName(info1) then return end

    -- UNIT_DEAD_NOTICE can arrive a few frames after the actual lethal COMBAT_MSG.
    -- Use the Suite monotonic clock as timing Authority, then anchor the visible
    -- "x.x seconds before death" timeline to the latest incoming hit when that
    -- hit is close enough to the notice to be a credible lethal event. This makes
    -- the lethal skill read 0.0s instead of inheriting event-delivery latency.
    local noticeAt = NowMs()
    local anchorAt = noticeAt
    local latest = self.incoming[#self.incoming]
    local latestAt = latest ~= nil and tonumber(latest.time) or nil
    if latestAt ~= nil and latestAt <= noticeAt + 250 and noticeAt - latestAt <= 2000 then
        anchorAt = latestAt
    end

    local windowMs = ClampInt(cfg.damageReviewWindowMs, 3000, 20000, 10000)
    local cutoff = anchorAt - windowMs
    local events = {}
    local total = 0
    for _, event in ipairs(self.incoming) do
        local eventTime = tonumber(event.time) or 0
        if eventTime >= cutoff and eventTime <= anchorAt + 250 then
            events[#events + 1] = {
                time = eventTime,
                source = event.source,
                ability = event.ability,
                amount = event.amount,
                environmental = event.environmental,
            }
            total = total + (tonumber(event.amount) or 0)
        end
    end
    self.serial = self.serial + 1
    local lethal = events[#events]
    local record = {
        schemaVersion = 1,
        serial = self.serial,
        time = anchorAt,
        noticeTime = noticeAt,
        clock = CurrentClockText(),
        windowMs = windowMs,
        totalDamage = math.floor(total + 0.5),
        lethal = lethal ~= nil and {
            time = lethal.time,
            source = lethal.source,
            ability = lethal.ability,
            amount = lethal.amount,
            environmental = lethal.environmental,
        } or nil,
        events = events,
        debuffs = cfg.damageReviewShowDebuffs == true and self:CopyDeathDebuffs(anchorAt) or {},
    }
    self.history[#self.history + 1] = record
    self:TrimHistory()
    self.selectedHistoryIndex = #self.history
    self.historyDirty = true
    self.historyDirtyAt = noticeAt
    self.autoDismissedSerial = nil
    self.autoPendingSerial = record.serial
    self.autoPendingUntil = noticeAt + 2000
    self.incoming = {}
    self.debuffSamples = {}
    self:_Present("RenderAuto", self)
    if cfg.damageReviewAutoShow == true then self:_Present("ShowAuto", self) end
    local _, historyVisible = self:_Present("IsHistoryVisible", self)
    if historyVisible == true then self:_Present("RenderHistory", self) end
end

function R:SaveHistoryNow()
    if self.historyDirty ~= true or S.State == nil then return false end
    S.State.life = type(S.State.life) == "table" and S.State.life or {}
    S.State.life.damageReviewHistory = {
        schemaVersion = 1,
        serial = self.serial,
        entries = U.DeepCopy(self.history),
    }
    self.historyDirty = false
    if S.Storage ~= nil and type(S.Storage.RequestSave) == "function" then S.Storage:RequestSave() end
    return true
end

function R:LoadHistory()
    local payload = S.State ~= nil and type(S.State.life) == "table" and S.State.life.damageReviewHistory or nil
    if type(payload) ~= "table" then return end
    local entries = type(payload.entries) == "table" and payload.entries or {}
    self.history = {}
    for _, record in ipairs(entries) do
        if type(record) == "table" and type(record.events) == "table" then
            self.history[#self.history + 1] = U.DeepCopy(record)
        end
    end
    self.serial = math.max(tonumber(payload.serial) or 0, tonumber(self.serial) or 0)
    self:TrimHistory()
    self.selectedHistoryIndex = #self.history
end

function R:OnUpdate(dt, now, combatActive)
    local cfg = Config()
    dt = tonumber(dt) or 0
    now = NowMs()
    if cfg.damageReviewEnabled == true and cfg.damageReviewShowDebuffs == true then
        self.debuffElapsed = self.debuffElapsed + dt
        local recentDamage = now - (tonumber(self.lastIncomingDamageAt) or 0) <= math.max(3000, tonumber(cfg.damageReviewWindowMs) or 10000)
        if self.debuffElapsed >= DEBUFF_SAMPLE_INTERVAL_MS and (combatActive == true or recentDamage) then
            self.debuffElapsed = 0
            self:CaptureDebuffs(now)
        end
    else
        self.debuffElapsed = 0
        self.debuffSamples = {}
    end

    self.visibilityElapsed = self.visibilityElapsed + dt
    if self.visibilityElapsed >= 250 then
        self.visibilityElapsed = 0
        local latest = self.history[#self.history]
        local _, autoVisible = self:_Present("IsAutoVisible", self)
        if autoVisible == true and latest ~= nil and self.autoDismissedSerial ~= latest.serial then
            -- Follow the native death window while it is visible. During the
            -- first two seconds keep the centered fallback alive because the
            -- native resurrection window may appear slightly after UNIT_DEAD_NOTICE.
            local deathWindowVisible = false
            if UIC_DEATH_AND_RESURRECTION_WND ~= nil then
                local ok, _, _, _, _, isVisible = GetContentMainScriptPosVis(UIC_DEATH_AND_RESURRECTION_WND)
                deathWindowVisible = ok and isVisible == true
            end
            if deathWindowVisible then
                self.autoPendingSerial = nil
                self.autoPendingUntil = nil
                self:_Present("PositionAutoPanel", self)
            elseif self.autoPendingSerial == latest.serial and now <= (tonumber(self.autoPendingUntil) or 0) then
                -- Keep the one-shot fallback visible; do not issue another Show().
            else
                self:_Present("HideAuto", self)
            end
        end
    end

    if self.historyDirty == true and combatActive ~= true and now - (tonumber(self.historyDirtyAt) or 0) >= 1500 then
        self:SaveHistoryNow()
    end
end

function R:GetStatusLine()
    return "伤害回顾：历史 " .. tostring(#self.history)
        .. " / 缓冲伤害 " .. tostring(#self.incoming)
        .. " / Debuff快照 " .. tostring(#self.debuffSamples)
end

-- M5 v6 Team Workspace projection.  These getters intentionally read only the
-- already-recorded DamageReview buffers/history; they never touch X2Unit.
function R:GetWorkspaceHistorySnapshot(limit)
    local maximum = math.max(1, math.min(30, math.floor(tonumber(limit) or 20)))
    local rows = {}
    local first = math.max(1, #self.history - maximum + 1)
    for index = #self.history, first, -1 do
        local record = self.history[index]
        if type(record) == "table" then
            local lethal = type(record.lethal) == "table" and record.lethal or {}
            rows[#rows + 1] = {
                serial = tonumber(record.serial) or index,
                clock = tostring(record.clock or "--:--:--"),
                totalDamage = math.max(0, tonumber(record.totalDamage) or 0),
                lethalSource = tostring(lethal.source or "--"),
                lethalAbility = tostring(lethal.ability or "--"),
                lethalAmount = math.max(0, tonumber(lethal.amount) or 0),
                eventCount = type(record.events) == "table" and #record.events or 0,
                debuffCount = type(record.debuffs) == "table" and #record.debuffs or 0,
                windowMs = math.max(0, tonumber(record.windowMs) or 0),
            }
        end
    end
    return {
        revision = tonumber(self.serial) or 0,
        historyCount = #self.history,
        incomingCount = #self.incoming,
        debuffSampleCount = #self.debuffSamples,
        rows = rows,
    }
end

function R:GetWorkspaceRecord(serial)
    serial = tonumber(serial)
    local record = nil
    for index = #self.history, 1, -1 do
        local candidate = self.history[index]
        if type(candidate) == "table" and (serial == nil or tonumber(candidate.serial) == serial) then
            record = candidate
            break
        end
    end
    if type(record) ~= "table" then return nil end
    local anchorAt = tonumber(record.time) or 0
    local events = {}
    for _, event in ipairs(type(record.events) == "table" and record.events or {}) do
        events[#events + 1] = {
            secondsBefore = math.max(0, (anchorAt - (tonumber(event.time) or anchorAt)) / 1000),
            source = tostring(event.source or "--"),
            ability = tostring(event.ability or "--"),
            amount = math.max(0, tonumber(event.amount) or 0),
            environmental = event.environmental == true,
        }
    end
    local debuffs = {}
    for _, debuff in ipairs(type(record.debuffs) == "table" and record.debuffs or {}) do
        debuffs[#debuffs + 1] = {
            name = tostring(debuff.name or "未知 Debuff"),
            stack = math.max(0, tonumber(debuff.stack) or 0),
        }
    end
    return {
        serial = tonumber(record.serial) or 0,
        clock = tostring(record.clock or "--:--:--"),
        totalDamage = math.max(0, tonumber(record.totalDamage) or 0),
        windowMs = math.max(0, tonumber(record.windowMs) or 0),
        events = events,
        debuffs = debuffs,
    }
end

function R:ApplyConfigLimits()
    self:TrimHistory()
    local _, visible = self:_Present("IsHistoryVisible", self)
    if visible == true then self:_Present("RenderHistory", self) end
end

function R:SetEnabled(enabled)
    local value = enabled == true
    S.State.settings.damageReviewEnabled = value
    if S.Storage ~= nil and type(S.Storage.RequestSave) == "function" then S.Storage:RequestSave() end
    if S.Scheduler ~= nil then
        S.Scheduler:SetEnabled("team_utility_damage_review", self.started == true and value)
    end
    if value then
        RefreshPlayerIdentity()
        self:StartListener()
    else
        self:StopListener()
        self.incoming = {}
        self.debuffSamples = {}
        self:_Present("HideAll", self)
    end
    return value
end

function R:SetSetting(key, value)
    if key == "damageReviewEnabled" then return self:SetEnabled(value == true) end
    if key == "damageReviewAutoShow" or key == "damageReviewShowDebuffs" then
        S.State.settings[key] = value == true
    elseif key == "damageReviewWindowMs" then
        S.State.settings[key] = ClampInt(value, 3000, 20000, 10000)
    elseif key == "damageReviewMaxHistory" then
        S.State.settings[key] = ClampInt(value, 1, 30, 10)
        self:ApplyConfigLimits()
    elseif key == "damageReviewMinDamage" then
        S.State.settings[key] = ClampInt(value, 0, 5000, 0)
    else
        return false
    end
    if S.Storage ~= nil and type(S.Storage.RequestSave) == "function" then S.Storage:RequestSave() end
    return true
end

function R:StartListener()
    if self.started ~= true or Config().damageReviewEnabled ~= true or self.listenerActive == true then return true end
    RefreshPlayerIdentity()

    local host = self.eventHost
    if host == nil then
        host = CreateEmptyWindow(S.PhysicalId("damage_review_event_host"), "UIParent")
        if host == nil or type(host.SetHandler) ~= "function" or type(host.RegisterEvent) ~= "function" then return false end
        local generation = S.Generation
        local handlerOk = pcall(function()
            host:SetHandler("OnEvent", function(_, eventName, arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8, arg9, arg10, arg11, arg12, arg13, arg14)
                if R.started ~= true or R.listenerActive ~= true or S.Generation ~= generation then return end
                local label = eventName == "COMBAT_MSG" and "event:damage_review_combat" or "event:damage_review"
                local token = S.PerformanceMonitor and S.PerformanceMonitor:Begin(label, "team_utility") or nil
                if eventName == "COMBAT_MSG" then
                    -- COMBAT_MSG = unitId, eventType, sourceName, targetName, abilityId,
                    -- abilityName, damageType, effectType, ... . The review owns only
                    -- the local-player incoming slice and never allocates a relay table.
                    R:OnCombatMessage(arg2, arg3, arg4, arg5, arg6, arg7, arg8, NowMs())
                elseif eventName == "UNIT_DEAD_NOTICE" then
                    R:OnDeathNotice(arg1, arg2, arg3, arg4)
                elseif eventName == "ENTERED_WORLD" then
                    RefreshPlayerIdentity()
                end
                if S.PerformanceMonitor ~= nil then S.PerformanceMonitor:End(token) end
            end)
            host:Show(false)
        end)
        if handlerOk ~= true then
            pcall(function() host:Show(false) end)
            return false
        end
        self.eventHost = host
    end

    local ok = pcall(function()
        host:RegisterEvent("COMBAT_MSG")
        host:RegisterEvent("UNIT_DEAD_NOTICE")
        host:RegisterEvent("ENTERED_WORLD")
    end)
    if ok ~= true then return false end
    self.listenerActive = true
    return true
end

function R:StopListener()
    local host = self.eventHost
    self.listenerActive = false
    if host == nil then return end
    -- Keep the physical host for the lifetime of this Suite generation. Reusing
    -- it avoids duplicate widget IDs when the user toggles the feature/module
    -- off and back on without a full UI reload.
    if type(host.UnregisterEvent) == "function" then
        pcall(function() host:UnregisterEvent("COMBAT_MSG") end)
        pcall(function() host:UnregisterEvent("UNIT_DEAD_NOTICE") end)
        pcall(function() host:UnregisterEvent("ENTERED_WORLD") end)
    end
    pcall(function() host:Show(false) end)
end

function R:ReconcileCharacterSettings()
    if self.started ~= true then return true end
    self:LoadHistory()
    RefreshPlayerIdentity()
    self:ApplyConfigLimits()
    local enabled = Config().damageReviewEnabled == true
    if S.Scheduler ~= nil then S.Scheduler:SetEnabled("team_utility_damage_review", enabled) end
    if enabled then self:StartListener() else self:StopListener() end
    return true
end

function R:Start()
    if self.started == true then return true end
    self.started = true
    self:LoadHistory()
    RefreshPlayerIdentity()
    if Config().damageReviewEnabled == true then self:StartListener() end
    return true
end

function R:Stop()
    self.started = false
    self:StopListener()
    self:SaveHistoryNow()
    self.incoming = {}
    self.debuffSamples = {}
    self:_Present("HideAll", self)
end

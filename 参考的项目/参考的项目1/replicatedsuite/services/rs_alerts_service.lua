------------------------------------------------------------------------
-- Replicated Suite - Shared screen-alert channel (report 七-方案A)
-- Author: Replicated
--
-- S.Services.Alerts:Push({text, style, durationMs, sound}) is the single
-- screen-wide notification channel. Combat alerts are the first consumer
-- (plates rp_runtime); event reminders ("screen" tier) and fishing/trade
-- feedback can join later without duplicating the host window.
--
-- Design:
--   * Push-driven, NEVER polled. The host window is shown by Push and hidden
--     by a single Scheduler task (the longest active duration wins).
--   * Same-text alerts overwrite (re-arm the timer) instead of stacking.
--   * style "countdown" renders "text  N" (remaining seconds) updated by the
--     same scheduler tick; "bigtext" renders plain text.
--   * anchorMode "center" (default) or "top" centres the host horizontally;
--     scale 60-200% scales the font.
--   * The host is a plain UIParent window (buffCapHost pattern) owned by this
--     service; HudManager registration (plates_alert) only drives visibility.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Services = S.Services or {}
S.Services.Alerts = {
    started = false,
    host = nil,
    label = nil,
    currentText = nil,
    currentStyle = nil,
    expiresAt = 0,
    remainingMs = 0,
    tickTask = nil,
}
local A = S.Services.Alerts

local TICK_INTERVAL_MS = 100
local DEFAULT_DURATION_MS = 3000
local MAX_DURATION_MS = 15000

local function Trim(value)
    return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

-- Host creation mirrors the buff-cap label: one UIParent window + one label,
-- never destroyed/recreated (engine duplicate-id CreateEmptyWindow is not a
-- well-defined "recreate").
local function EnsureHost()
    if A.host ~= nil then return true end
    if type(CreateEmptyWindow) ~= "function" or S.UI == nil then return false end
    local host = CreateEmptyWindow(S.PhysicalId("suite_alert_window"), "UIParent")
    if host == nil then return false end
    host:SetExtent(640, 120)
    if host.EnablePick ~= nil then pcall(function() host:EnablePick(false) end) end
    if host.Clickable ~= nil then pcall(function() host:Clickable(false) end) end
    if host.CorrectOffsetByScreen ~= nil then pcall(function() host:CorrectOffsetByScreen() end) end
    local label = host:CreateChildWidget("label", S.PhysicalId("suite_alert_text"), 0, true)
    label:AddAnchor("TOPLEFT", host, 0, 0)
    label:SetExtent(640, 120)
    if label.SetAutoResize ~= nil then pcall(function() label:SetAutoResize(false) end) end
    if label.EnablePick ~= nil then pcall(function() label:EnablePick(false) end) end
    if label.Clickable ~= nil then pcall(function() label:Clickable(false) end) end
    label.style:SetFontSize(36)
    label.style:SetAlign(ALIGN_CENTER)
    label.style:SetColor(1, 0.9, 0.3, 1)
    if label.style.SetOutline ~= nil then pcall(function() label.style:SetOutline(true) end) end
    if label.style.SetEllipsis ~= nil then pcall(function() label.style:SetEllipsis(false) end) end
    label:SetText("")
    A.host = host
    A.label = label
    host:Show(false)
    return true
end

local function ApplyAnchor(cfg)
    if A.host == nil then return end
    if A.host.RemoveAllAnchors ~= nil then pcall(function() A.host:RemoveAllAnchors() end) end
    local anchorMode = type(cfg) == "table" and tostring(cfg.anchorMode) or "center"
    if anchorMode == "top" then
        if A.host.AddAnchor ~= nil then pcall(function() A.host:AddAnchor("TOP", "UIParent", 0, 40) end) end
    else
        if A.host.AddAnchor ~= nil then pcall(function() A.host:AddAnchor("CENTER", "UIParent", 0, -120) end) end
    end
end

local function ApplyScale(cfg)
    if A.label == nil then return end
    local scale = math.max(60, math.min(200, tonumber(type(cfg) == "table" and cfg.scale or 100) or 100)) / 100
    local fontSize = math.floor(36 * scale + 0.5)
    pcall(function() A.label.style:SetFontSize(fontSize) end)
end

-- Push one alert. Same text re-arms the timer (no stacking); a longer duration
-- than the current one extends the expiry. Returns true when shown.
function A:Push(payload)
    if self.started ~= true then return false end
    if type(payload) ~= "table" then return false end
    local text = Trim(payload.text)
    if text == "" then return false end
    if not EnsureHost() then return false end
    local cfg = (S.Services and S.Services.PlatesCfg and S.Services.PlatesCfg()) or nil
    local style = tostring(payload.style or "bigtext")
    local durationMs = math.max(500, math.min(MAX_DURATION_MS, tonumber(payload.durationMs) or DEFAULT_DURATION_MS))
    local now = S.NowMs()
    local remainingMs = math.max(0, math.max(0, tonumber(payload.remainingMs) or 0))

    -- Same text: overwrite and re-arm. Different text: show immediately.
    self.currentText = text
    self.currentStyle = style
    self.currentRemainingMs = remainingMs
    self.expiresAt = math.max(now + durationMs, self.expiresAt)
    if self.label ~= nil then
        local labelText = text
        if style == "countdown" and remainingMs > 0 then
            labelText = string.format("%s  %d", text, math.max(1, math.ceil(remainingMs / 1000)))
        end
        if self.labelLastText ~= labelText then
            self.labelLastText = labelText
            pcall(function() self.label:SetText(labelText) end)
        end
    end
    ApplyAnchor(cfg)
    ApplyScale(cfg)
    if self.host ~= nil then pcall(function() self.host:Show(true) end) end

    -- Single scheduler tick drives expiry + countdown redraw. No polling when
    -- idle: the task stays armed only while an alert is visible.
    if self.tickTask == nil and S.Scheduler ~= nil and type(S.Scheduler.AddTask) == "function" then
        S.Scheduler:AddTask("alerts_tick", TICK_INTERVAL_MS, function() A:Tick() end, false, self, "P3")
        self.tickTask = true
    end
    return true
end

function A:Tick()
    local now = S.NowMs()
    if now >= self.expiresAt or self.currentText == nil then
        self.currentText = nil
        self.currentRemainingMs = nil
        if self.host ~= nil then pcall(function() self.host:Show(false) end) end
        if self.tickTask == true and S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then
            S.Scheduler:RemoveTask("alerts_tick")
        end
        self.tickTask = nil
        return
    end
    -- Countdown redraw only for style=countdown with a remaining budget.
    if self.currentStyle == "countdown" and type(self.currentRemainingMs) == "number"
        and self.currentRemainingMs > 0 and self.label ~= nil then
        local left = math.max(1, math.ceil((self.expiresAt - now) / 1000))
        if self.labelLastText ~= self.currentText .. "  " .. left then
            self.labelLastText = self.currentText .. "  " .. left
            pcall(function() self.label:SetText(self.currentText .. "  " .. left) end)
        end
    end
end

-- Hide immediately (module disable, HUD hidden).
function A:Hide()
    self.currentText = nil
    self.currentRemainingMs = nil
    self.expiresAt = 0
    if self.host ~= nil then pcall(function() self.host:Show(false) end) end
    if self.tickTask == true and S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then
        S.Scheduler:RemoveTask("alerts_tick")
    end
    self.tickTask = nil
end

function A:Start()
    if self.started == true then return true end
    self.started = true
    return true
end

function A:Stop()
    if self.started ~= true then return true end
    self.started = false
    self:Hide()
    return true
end

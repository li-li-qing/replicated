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
    presenter = nil,
    currentText = nil,
    currentStyle = nil,
    expiresAt = 0,
    remainingMs = 0,
    tickTask = nil,
}
local A = S.Services.Alerts
A.presentationBoundary = "service_only"
A.presentationDebt = nil

local TICK_INTERVAL_MS = 100
local DEFAULT_DURATION_MS = 3000
local MAX_DURATION_MS = 15000

local Trim = S.Reuse.Text.Trim

-- Presentation is injected by a host-side presenter.  The service owns only
-- alert state/timing; it never creates or mutates Native UI.  This dependency
-- inversion lets Legacy and V3 presenters consume the same service without
-- making the service depend on either presentation stack.
function A:SetPresenter(presenter)
    if presenter ~= nil and type(presenter) ~= "table" then return false end
    if self.presenter ~= nil and self.presenter ~= presenter and type(self.presenter.Hide) == "function" then
        pcall(self.presenter.Hide, self.presenter)
    end
    self.presenter = presenter
    return true
end

function A:_Present(method, ...)
    local presenter = self.presenter
    local fn = presenter ~= nil and presenter[method] or nil
    if type(fn) ~= "function" then return false end
    local ok, result = pcall(fn, presenter, ...)
    if not ok then
        if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.ErrorRateLimited) == "function" then
            S.DiagnosticsManager:ErrorRateLimited("alerts", "PRESENTER_CALL_FAILED", 3000,
                "Presenter 调用失败：" .. tostring(method), { error = tostring(result), method = tostring(method) })
        end
        return false
    end
    return result ~= false
end

-- Push one alert. Same text re-arms the timer (no stacking); a longer duration
-- than the current one extends the expiry. Returns true when shown.
function A:Push(payload)
    if self.started ~= true then return false end
    if type(payload) ~= "table" then return false end
    local text = Trim(payload.text)
    if text == "" then return false end
    local cfg = type(payload.presentationConfig) == "table" and payload.presentationConfig
        or ((S.Services and S.Services.PlatesCfg and S.Services.PlatesCfg()) or nil)
    local style = tostring(payload.style or "bigtext")
    local durationMs = math.max(500, math.min(MAX_DURATION_MS, tonumber(payload.durationMs) or DEFAULT_DURATION_MS))
    local now = S.NowMs()
    local remainingMs = math.max(0, math.max(0, tonumber(payload.remainingMs) or 0))

    -- Same text may extend its existing presentation window; a different alert
    -- starts a fresh duration and must not inherit a previous long-lived expiry.
    local sameText = self.currentText == text
    self.currentText = text
    self.currentStyle = style
    self.currentRemainingMs = remainingMs
    self.expiresAt = sameText and math.max(now + durationMs, self.expiresAt) or (now + durationMs)
    local labelText = text
    if style == "countdown" and remainingMs > 0 then
        labelText = string.format("%s  %d", text, math.max(1, math.ceil(remainingMs / 1000)))
    end
    self.labelLastText = labelText
    self:_Present("Show", labelText, cfg)

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
        self:_Present("Hide")
        if self.tickTask == true and S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then
            S.Scheduler:RemoveTask("alerts_tick")
        end
        self.tickTask = nil
        return
    end
    -- Countdown redraw only for style=countdown with a remaining budget.
    if self.currentStyle == "countdown" and type(self.currentRemainingMs) == "number"
        and self.currentRemainingMs > 0 then
        local left = math.max(1, math.ceil((self.expiresAt - now) / 1000))
        if self.labelLastText ~= self.currentText .. "  " .. left then
            self.labelLastText = self.currentText .. "  " .. left
            self:_Present("UpdateText", self.currentText .. "  " .. left)
        end
    end
end

-- Hide immediately (module disable, HUD hidden).
function A:Hide()
    self.currentText = nil
    self.currentRemainingMs = nil
    self.expiresAt = 0
    self:_Present("Hide")
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

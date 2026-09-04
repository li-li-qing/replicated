------------------------------------------------------------------------
-- Replicated Suite - RSUI Action Runner v1
--
-- Shared command boundary for user-triggered UI actions. It owns synchronous
-- Busy/duplicate-click protection, button temporary state, exception fencing,
-- diagnostics and optional Toast feedback. Domain functions still own the
-- actual business transaction and return true/false + reason.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI, UI = S.RSUI, S.UI
if type(RSUI) ~= "table" or type(UI) ~= "table" then return end

local A = {
    version = 2,
    active = {},
    metrics = { runs = 0, succeeded = 0, failed = 0, exceptions = 0, duplicates = 0, buttonStateFailures = 0 },
}
RSUI.ActionRunnerEnabledTransactionContractVersion = 1
S.ActionRunner = A
RSUI.ActionRunner = A

local function Report(level, code, message, context)
    local D = S.DiagnosticsManager or S.Diagnostics
    if D ~= nil and type(D.Record) == "function" then
        pcall(function() D:Record(level or "warning", "action_runner", tostring(message or code), tostring(code), context) end)
    end
end

local function Notify(spec, ok, detail)
    if spec.notify == false then return end
    local host = S.UIV3 and S.UIV3.ToastHost or nil
    if type(host) ~= "table" or type(host.Notify) ~= "function" then return end
    local title = ok and spec.successTitle or spec.errorTitle
    local text = ok and spec.successText or spec.errorText
    if type(text) == "function" then
        local callOk, value = pcall(text, detail, spec)
        if callOk then text = value else text = nil end
    end
    if text == nil or tostring(text) == "" then return end
    host:Notify({
        id = spec.toastId,
        title = tostring(title or (ok and "操作完成" or "操作失败")),
        detail = tostring(text),
        tone = ok and tostring(spec.successTone or "green") or tostring(spec.errorTone or "red"),
        durationMs = tonumber(spec.toastDurationMs) or 3200,
    })
end

local function SetButtonEnabled(button, enabled)
    if type(button) == "table" and type(button.SetEnabled) == "function" then
        local state, accepted, detail = button:SetEnabled(enabled)
        if accepted == false then return false, detail or "component_enable_rejected", state end
        return true, nil, state
    end
    if button ~= nil and type(UI.EnsureEnabled) == "function" then
        local accepted, _, detail = UI:EnsureEnabled(button, enabled, "action_runner")
        return accepted == true, detail, enabled ~= false
    end
    return false, "button_enable_unavailable", nil
end

local function SetButtonText(button, text)
    if text == nil then return false end
    if type(button) == "table" and type(button.SetText) == "function" then return button:SetText(text) end
    if button ~= nil then return UI:SetText(button, tostring(text)) end
    return false
end

function A:IsBusy(id)
    return self.active[tostring(id or "")] ~= nil
end

function A:Run(spec)
    spec = type(spec) == "table" and spec or {}
    local id = tostring(spec.id or spec.actionId or "")
    if id == "" then return false, "action id required" end
    if type(spec.execute) ~= "function" then return false, "action execute required" end
    if self.active[id] ~= nil then
        self.metrics.duplicates = (tonumber(self.metrics.duplicates) or 0) + 1
        if type(spec.onDuplicate) == "function" then pcall(spec.onDuplicate, id, spec) end
        return false, "busy"
    end

    self.metrics.runs = (tonumber(self.metrics.runs) or 0) + 1
    local button = spec.button
    local previousEnabled = true
    if type(button) == "table" then previousEnabled = button.enabled ~= false end
    local previousText = spec.idleText or (type(button) == "table" and (button.text or (button.spec and button.spec.text))) or nil
    self.active[id] = { startedAt = type(S.NowMs) == "function" and S.NowMs() or 0, button = button }
    local busyEnabledRevision, busyTextRevision = nil, nil
    if button ~= nil then
        local stateOk, stateErr = SetButtonEnabled(button, false)
        if stateOk ~= true then
            self.metrics.buttonStateFailures = (tonumber(self.metrics.buttonStateFailures) or 0) + 1
            Report("warning", "ACTION_BUSY_STATE_REJECTED", tostring(stateErr or "button disable rejected"), { action = id })
        end
        if type(button) == "table" then busyEnabledRevision = tonumber(button.enabledRevision) end
        if spec.busyText ~= nil then
            SetButtonText(button, spec.busyText)
            if type(button) == "table" then busyTextRevision = tonumber(button.textRevision) end
        end
    end
    if type(spec.onBusyChanged) == "function" then pcall(spec.onBusyChanged, true, id, spec) end

    local ok, a, b, c = xpcall(function() return spec.execute(spec) end, S.SafeTraceback)
    local accepted, reason
    if ok ~= true then
        accepted, reason = false, a
        self.metrics.exceptions = (tonumber(self.metrics.exceptions) or 0) + 1
        Report("error", "ACTION_EXCEPTION", tostring(a), { action = id })
    else
        accepted = a ~= false
        reason = b
    end

    self.active[id] = nil
    if button ~= nil then
        if previousText ~= nil and spec.restoreText ~= false then
            local currentText = type(button) == "table" and button.text or nil
            local textUntouched = type(button) ~= "table"
                or busyTextRevision == nil
                or tonumber(button.textRevision) == busyTextRevision
            if textUntouched and (spec.busyText == nil or currentText == tostring(spec.busyText)) then SetButtonText(button, previousText) end
        end
        if spec.restoreEnabled ~= false then
            local enabledUntouched = type(button) ~= "table"
                or busyEnabledRevision == nil
                or tonumber(button.enabledRevision) == busyEnabledRevision
            if enabledUntouched then
                local restoreOk, restoreErr = SetButtonEnabled(button, previousEnabled)
                if restoreOk ~= true then
                    self.metrics.buttonStateFailures = (tonumber(self.metrics.buttonStateFailures) or 0) + 1
                    Report("warning", "ACTION_RESTORE_STATE_REJECTED", tostring(restoreErr or "button restore rejected"), { action = id })
                end
            end
        end
    end
    if type(spec.onBusyChanged) == "function" then pcall(spec.onBusyChanged, false, id, spec) end

    if accepted then
        self.metrics.succeeded = (tonumber(self.metrics.succeeded) or 0) + 1
        if type(spec.onSuccess) == "function" then pcall(spec.onSuccess, a, b, c, spec) end
        Notify(spec, true, b)
        return true, b, c
    end

    self.metrics.failed = (tonumber(self.metrics.failed) or 0) + 1
    Report("warning", "ACTION_FAILED", tostring(reason or "action rejected"), { action = id })
    if type(spec.onFailure) == "function" then pcall(spec.onFailure, reason, spec) end
    Notify(spec, false, reason)
    return false, reason
end

function A:Wrap(spec)
    spec = type(spec) == "table" and spec or {}
    return function() return A:Run(spec) end
end

function A:GetSnapshot()
    local busy = 0
    for _ in pairs(self.active) do busy = busy + 1 end
    return {
        version = self.version, busy = busy,
        runs = tonumber(self.metrics.runs) or 0,
        succeeded = tonumber(self.metrics.succeeded) or 0,
        failed = tonumber(self.metrics.failed) or 0,
        exceptions = tonumber(self.metrics.exceptions) or 0,
        duplicates = tonumber(self.metrics.duplicates) or 0,
        buttonStateFailures = tonumber(self.metrics.buttonStateFailures) or 0,
    }
end

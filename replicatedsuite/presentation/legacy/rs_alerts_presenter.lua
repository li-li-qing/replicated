------------------------------------------------------------------------
-- Replicated Suite - Legacy Alerts Presenter
-- Author: Replicated
--
-- Presentation-only adapter for S.Services.Alerts.  The Alerts service owns
-- alert state/timing and injects text into this presenter through a tiny sink
-- interface.  All Native UI creation/geometry stays here, outside Services.
--
-- This file is intentionally Legacy presentation.  A future V3 alert HUD can
-- replace the registered presenter without changing the Alerts service.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Presentation = S.Presentation or {}
S.Presentation.Legacy = S.Presentation.Legacy or {}
S.Presentation.Legacy.Alerts = S.Presentation.Legacy.Alerts or {
    host = nil,
    label = nil,
    lastText = nil,
}
local P = S.Presentation.Legacy.Alerts

local function EnsureHost(self)
    if self.host ~= nil then return true end
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
    host:Show(false)

    self.host = host
    self.label = label
    return true
end

local function ApplyAnchor(self, cfg)
    local host = self.host
    if host == nil then return end
    if host.RemoveAllAnchors ~= nil then pcall(function() host:RemoveAllAnchors() end) end
    local anchorMode = type(cfg) == "table" and tostring(cfg.anchorMode) or "center"
    if anchorMode == "top" then
        if host.AddAnchor ~= nil then pcall(function() host:AddAnchor("TOP", "UIParent", 0, 40) end) end
    else
        if host.AddAnchor ~= nil then pcall(function() host:AddAnchor("CENTER", "UIParent", 0, -120) end) end
    end
end

local function ApplyScale(self, cfg)
    local label = self.label
    if label == nil then return end
    local scale = math.max(60, math.min(200, tonumber(type(cfg) == "table" and cfg.scale or 100) or 100)) / 100
    local fontSize = math.floor(36 * scale + 0.5)
    pcall(function() label.style:SetFontSize(fontSize) end)
end

function P:Show(text, cfg)
    if not EnsureHost(self) then return false end
    local value = tostring(text or "")
    if self.lastText ~= value then
        self.lastText = value
        pcall(function() self.label:SetText(value) end)
    end
    ApplyAnchor(self, cfg)
    ApplyScale(self, cfg)
    pcall(function() self.host:Show(true) end)
    return true
end

function P:UpdateText(text)
    if not EnsureHost(self) then return false end
    local value = tostring(text or "")
    if self.lastText ~= value then
        self.lastText = value
        pcall(function() self.label:SetText(value) end)
    end
    return true
end

function P:Hide()
    if self.host ~= nil then pcall(function() self.host:Show(false) end) end
    return true
end

-- Dependency inversion: presentation registers a sink; the service never
-- references this concrete Legacy presenter or any Native widget.
local alerts = S.Services and S.Services.Alerts or nil
if alerts ~= nil and type(alerts.SetPresenter) == "function" then
    alerts:SetPresenter(P)
end

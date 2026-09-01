------------------------------------------------------------------------
-- Replicated Suite V3 - Native Adapter Boundary
--
-- V3 Presentation must not call Native Geometry directly.  This adapter is the
-- only shell-level creation boundary; all post-creation state is written through
-- DiffRenderer under strict v3:* authority.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local UI = S.UI
if type(UI) ~= "table" then return end

S.UIV3NativeAdapter = S.UIV3NativeAdapter or {
    version = 3,
    consumedById = {},
    metrics = { rootsCreated = 0, systemLayerApplied = 0, nativeEscapeCloseDisabled = 0, nativeModalDisabled = 0, consumedRejects = 0 },
}
local A = S.UIV3NativeAdapter
A.version = 3
A.consumedById = A.consumedById or {}
A.metrics = A.metrics or { rootsCreated = 0, systemLayerApplied = 0, nativeEscapeCloseDisabled = 0, nativeModalDisabled = 0, consumedRejects = 0 }
A.metrics.consumedRejects = tonumber(A.metrics.consumedRejects) or 0

function A:CreateRootWindow(logicalId, owner)
    logicalId = tostring(logicalId or "")
    owner = tostring(owner or "")
    if logicalId == "" or owner:sub(1, 3) ~= "v3:" then return nil, "invalid v3 native identity" end
    if tonumber(self.consumedById[logicalId]) == tonumber(S.Generation) then
        self.metrics.consumedRejects = (tonumber(self.metrics.consumedRejects) or 0) + 1
        return nil, "v3 root native identity already consumed this generation: " .. logicalId
    end
    local factory = S.NativeObjectFactory
    if type(factory) ~= "table" or type(factory.CreateWindow) ~= "function" then return nil, "NativeObjectFactory unavailable" end

    local window, createErr = factory:CreateWindow(S.PhysicalId(logicalId), "UIParent", "")
    if window == nil then return nil, createErr or "window create failed" end
    self.consumedById[logicalId] = S.Generation
    if type(S.RSUI) == "table" and type(S.RSUI.TrackBuildWidget) == "function" then S.RSUI:TrackBuildWidget(window) end
    window.rsUiOwner = owner
    window.rsUiLogicalId = logicalId
    window.rsUiParent = UIParent

    local registered = UI:Register(logicalId, window)
    if registered ~= window then return nil, "v3 root registration rejected" end
    UI:SetEnabled(window, true, owner)
    UI:SetPickable(window, false, owner)
    UI:SetVisible(window, false, owner)

    -- All V3 root windows use one explicit native policy. Native Escape closing
    -- is disabled because it would hide a window behind the lifecycle/persistence
    -- authorities. V3 owns Close through its Host/Modal contracts instead.
    if type(window.SetUILayer) == "function" then
        local ok = pcall(function() window:SetUILayer("system") end)
        if ok then self.metrics.systemLayerApplied = (tonumber(self.metrics.systemLayerApplied) or 0) + 1 end
    end
    if type(window.SetCloseOnEscape) == "function" then
        local ok = pcall(function() window:SetCloseOnEscape(false) end)
        if ok then self.metrics.nativeEscapeCloseDisabled = (tonumber(self.metrics.nativeEscapeCloseDisabled) or 0) + 1 end
    end
    if type(window.SetWindowModal) == "function" then
        local ok = pcall(function() window:SetWindowModal(false) end)
        if ok then self.metrics.nativeModalDisabled = (tonumber(self.metrics.nativeModalDisabled) or 0) + 1 end
    end
    self.metrics.rootsCreated = (tonumber(self.metrics.rootsCreated) or 0) + 1
    return window
end

function A:ApplyRect(widget, owner, x, y, width, height)
    if widget == nil then return false end
    UI:SetAnchor(widget, UIParent, tonumber(x) or 0, tonumber(y) or 0, owner)
    UI:SetExtent(widget, math.max(1, tonumber(width) or 1), math.max(1, tonumber(height) or 1), owner)
    return true
end

function A:SetVisible(widget, owner, visible)
    return UI:SetVisible(widget, visible == true, owner)
end

function A:IsVisible(widget)
    if widget == nil or type(widget.IsVisible) ~= "function" then return false end
    local ok, value = pcall(function() return widget:IsVisible() end)
    return ok and value == true
end

function A:GetExtent(widget)
    if widget == nil then return nil, nil end
    local width, height
    if type(widget.GetWidth) == "function" then pcall(function() width = tonumber(widget:GetWidth()) end) end
    if type(widget.GetHeight) == "function" then pcall(function() height = tonumber(widget:GetHeight()) end) end
    return width, height
end

function A:Raise(widget)
    if widget == nil or type(widget.Raise) ~= "function" then return false end
    return pcall(function() widget:Raise() end)
end

function A:SetAlpha(widget, owner, alpha)
    if widget == nil then return false end
    return UI:SetAlpha(widget, math.max(0, math.min(1, tonumber(alpha) or 1)), owner)
end

function A:Describe()
    return {
        version = self.version,
        rootsCreated = tonumber(self.metrics.rootsCreated) or 0,
        systemLayerApplied = tonumber(self.metrics.systemLayerApplied) or 0,
        nativeEscapeCloseDisabled = tonumber(self.metrics.nativeEscapeCloseDisabled) or 0,
        nativeModalDisabled = tonumber(self.metrics.nativeModalDisabled) or 0,
        consumedRejects = tonumber(self.metrics.consumedRejects) or 0,
    }
end

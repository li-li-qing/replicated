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
    version = 4,
    consumedById = {},
    metrics = { rootsCreated = 0, systemLayerApplied = 0, nativeEscapeCloseDisabled = 0, nativeModalDisabled = 0, consumedRejects = 0 },
}
local A = S.UIV3NativeAdapter
A.version = 4
A.consumedById = A.consumedById or {}
A.metrics = A.metrics or { rootsCreated = 0, systemLayerApplied = 0, nativeEscapeCloseDisabled = 0, nativeModalDisabled = 0, consumedRejects = 0 }
A.metrics.consumedRejects = tonumber(A.metrics.consumedRejects) or 0
A.RootInteractionPolicyContractVersion = 2

local FALSE_STATE_POLICY_SETTERS = {
    SetCloseOnEscape = true,
    SetWindowModal = true,
}

local function OptionalNativeAccepted(widget, methodName, ...)
    local fn = widget and widget[methodName] or nil
    if type(fn) ~= "function" then return true, false, nil end
    local args, argc = { ... }, select("#", ...)
    local ok, result = pcall(function() return fn(widget, unpack(args, 1, argc)) end)
    if ok ~= true then return false, true, tostring(result) end
    -- SetCloseOnEscape(false) / SetWindowModal(false) may return the applied
    -- boolean state on RU clients. A false return is therefore not proof of
    -- rejection. Only those boolean false-state policy calls are ambiguous;
    -- SetUILayer and any future non-boolean policy still fail closed on false.
    if result == false then
        local falseStateSetter = FALSE_STATE_POLICY_SETTERS[tostring(methodName or "")] == true
            and argc >= 1 and args[1] == false
        if not falseStateSetter then return false, true, "native_rejected" end
    end
    return true, true, nil
end

local function RejectRoot(window, owner, reason)
    if window ~= nil then
        window.rsUiDegraded = true
        window.rsUiDegradedReason = tostring(reason or "v3_root_policy_failed")
        UI:SetVisible(window, false, owner)
    end
    return nil, tostring(reason or "v3_root_policy_failed")
end

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
    if type(S.RSUI) == "table" and type(S.RSUI.TrackBuildWidget) == "function" then S.RSUI:TrackBuildWidget(window) end
    window.rsUiOwner = owner
    window.rsUiLogicalId = logicalId
    window.rsUiParent = UIParent

    if type(UI.EnsureEnabled) ~= "function" or type(UI.EnsurePickable) ~= "function" then
        return RejectRoot(window, owner, "v3 root interaction transaction unavailable")
    end
    local enabledOk, _, enabledErr = UI:EnsureEnabled(window, true, owner)
    if enabledOk ~= true then return RejectRoot(window, owner, "v3 root enable rejected:" .. tostring(enabledErr or "unknown")) end
    local pickOk, _, pickErr = UI:EnsurePickable(window, false, owner)
    if pickOk ~= true then return RejectRoot(window, owner, "v3 root pickable rejected:" .. tostring(pickErr or "unknown")) end
    if type(UI.EnsureVisible) ~= "function" then return RejectRoot(window, owner, "v3 root visibility transaction unavailable") end
    local hiddenOk, _, hiddenErr = UI:EnsureVisible(window, false, owner)
    if hiddenOk ~= true then return RejectRoot(window, owner, "v3 root initial hide rejected:" .. tostring(hiddenErr or "unknown")) end

    -- All V3 root windows use one explicit native policy. Native Escape closing
    -- is disabled because it would hide a window behind the lifecycle/persistence
    -- authorities. If the client exposes these methods but rejects the requested
    -- state, reject the root instead of returning a lifecycle-invalid window.
    local layerOk, layerPresent = OptionalNativeAccepted(window, "SetUILayer", "system")
    if layerOk ~= true then return RejectRoot(window, owner, "v3 root layer policy rejected") end
    if layerPresent then self.metrics.systemLayerApplied = (tonumber(self.metrics.systemLayerApplied) or 0) + 1 end
    local escapeOk, escapePresent = OptionalNativeAccepted(window, "SetCloseOnEscape", false)
    if escapeOk ~= true then return RejectRoot(window, owner, "v3 root escape policy rejected") end
    if escapePresent then self.metrics.nativeEscapeCloseDisabled = (tonumber(self.metrics.nativeEscapeCloseDisabled) or 0) + 1 end
    local modalOk, modalPresent = OptionalNativeAccepted(window, "SetWindowModal", false)
    if modalOk ~= true then return RejectRoot(window, owner, "v3 root modal policy rejected") end
    if modalPresent then self.metrics.nativeModalDisabled = (tonumber(self.metrics.nativeModalDisabled) or 0) + 1 end

    local registered = UI:Register(logicalId, window)
    if registered ~= window then return RejectRoot(window, owner, "v3 root registration rejected") end
    self.consumedById[logicalId] = S.Generation
    self.metrics.rootsCreated = (tonumber(self.metrics.rootsCreated) or 0) + 1
    return window
end

function A:ApplyRect(widget, owner, x, y, width, height)
    if widget == nil then return false, "widget_required" end
    if type(UI.EnsureAnchor) ~= "function" or type(UI.EnsureExtent) ~= "function" then
        return false, "geometry_transaction_unavailable"
    end
    local anchorOk, _, anchorErr = UI:EnsureAnchor(widget, UIParent, tonumber(x) or 0, tonumber(y) or 0, owner)
    if anchorOk ~= true then return false, anchorErr or "native_anchor_rejected" end
    local extentOk, _, extentErr = UI:EnsureExtent(widget, math.max(1, tonumber(width) or 1), math.max(1, tonumber(height) or 1), owner)
    if extentOk ~= true then return false, extentErr or "native_extent_rejected" end
    return true, nil
end

function A:SetVisible(widget, owner, visible)
    if widget == nil then return false, "widget_required" end
    if type(UI.EnsureVisible) ~= "function" then return false, "visibility_transaction_unavailable" end
    local accepted, _, detail = UI:EnsureVisible(widget, visible == true, owner)
    if accepted ~= true then return false, tostring(detail or "native_visibility_rejected") end
    return true, nil
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
        rootInteractionPolicyContractVersion = tonumber(self.RootInteractionPolicyContractVersion) or 0,
    }
end

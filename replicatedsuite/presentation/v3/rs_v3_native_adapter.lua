-- Replicated Suite · 原生窗口适配器
-- 作者：Replicated
-- QQ群：1104129461
-- Shell 在此创建原生窗口；后续状态由 DiffRenderer 在 v3:* 范围内写入。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local UI = S.UI
if type(UI) ~= "table" then return end

S.UIV3NativeAdapter = S.UIV3NativeAdapter or {
    version = 5,
    consumedById = {},
    metrics = { rootsCreated = 0, systemLayerApplied = 0, normalLayerApplied = 0, layerChanges = 0, layerFailures = 0, nativeEscapeCloseDisabled = 0, nativeModalDisabled = 0, consumedRejects = 0 },
}
local A = S.UIV3NativeAdapter
A.version = 5
A.consumedById = A.consumedById or {}
A.metrics = A.metrics or { rootsCreated = 0, systemLayerApplied = 0, normalLayerApplied = 0, layerChanges = 0, layerFailures = 0, nativeEscapeCloseDisabled = 0, nativeModalDisabled = 0, consumedRejects = 0 }
A.metrics.consumedRejects = tonumber(A.metrics.consumedRejects) or 0
A.metrics.normalLayerApplied = tonumber(A.metrics.normalLayerApplied) or 0
A.metrics.layerChanges = tonumber(A.metrics.layerChanges) or 0
A.metrics.layerFailures = tonumber(A.metrics.layerFailures) or 0
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
    -- RU 的 SetCloseOnEscape(false)/SetWindowModal(false) 可能返回已应用的布尔状态，false 不能证明拒绝；
    -- 仅这些 false 状态策略调用存在歧义，SetUILayer 及未来非布尔策略返回 false 仍须拒绝。
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

function A:CreateRootWindow(logicalId, owner, requestedLayer, options)
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

    -- 主 Shell 可按 WindowPreferences 选择 normal/system；未传 requestedLayer 的旧调用仍默认 system，
    -- 避免误降 Healer overlay 等特殊窗口层级。Escape/Modal 仍统一在此处理。
    local layerName = tostring(requestedLayer or "system") == "normal" and "normal" or "system"
    local layerOk, layerPresent = OptionalNativeAccepted(window, "SetUILayer", layerName)
    if layerOk ~= true then return RejectRoot(window, owner, "v3 root layer policy rejected:" .. layerName) end
    if layerPresent then
        if layerName == "normal" then self.metrics.normalLayerApplied = (tonumber(self.metrics.normalLayerApplied) or 0) + 1
        else self.metrics.systemLayerApplied = (tonumber(self.metrics.systemLayerApplied) or 0) + 1 end
    end
    -- 只有主菜单等明确接入 OnHide 清理的根窗口选择 Esc；其它调用保持原策略，不改变战斗/HUD输入层级。
    local closeOnEscape=type(options)=="table"and options.closeOnEscape==true
    local escapeOk, escapePresent = OptionalNativeAccepted(window, "SetCloseOnEscape", closeOnEscape)
    if escapeOk ~= true or (closeOnEscape and not escapePresent)then return RejectRoot(window, owner, "v3 root escape policy rejected") end
    if escapePresent then
        local key=closeOnEscape and "nativeEscapeCloseEnabled"or "nativeEscapeCloseDisabled"
        self.metrics[key]=(tonumber(self.metrics[key])or 0)+1
    end
    local modalOk, modalPresent = OptionalNativeAccepted(window, "SetWindowModal", false)
    if modalOk ~= true then return RejectRoot(window, owner, "v3 root modal policy rejected") end
    if modalPresent then self.metrics.nativeModalDisabled = (tonumber(self.metrics.nativeModalDisabled) or 0) + 1 end

    local registered = UI:Register(logicalId, window)
    if registered ~= window then return RejectRoot(window, owner, "v3 root registration rejected") end
    self.consumedById[logicalId] = S.Generation
    self.metrics.rootsCreated = (tonumber(self.metrics.rootsCreated) or 0) + 1
    return window
end

function A:SetRootLayer(widget, topmostOrLayer)
    if widget == nil then return false, "widget_required" end
    local layerName
    if type(topmostOrLayer) == "string" then
        layerName = tostring(topmostOrLayer) == "system" and "system" or "normal"
    else
        layerName = topmostOrLayer == true and "system" or "normal"
    end
    local accepted = OptionalNativeAccepted(widget, "SetUILayer", layerName)
    if accepted ~= true then
        self.metrics.layerFailures = (tonumber(self.metrics.layerFailures) or 0) + 1
        return false, "v3 root layer change rejected:" .. layerName
    end
    self.metrics.layerChanges = (tonumber(self.metrics.layerChanges) or 0) + 1
    widget.rsUiTopmost = layerName == "system"
    return true, layerName
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
        normalLayerApplied = tonumber(self.metrics.normalLayerApplied) or 0,
        layerChanges = tonumber(self.metrics.layerChanges) or 0,
        layerFailures = tonumber(self.metrics.layerFailures) or 0,
        nativeEscapeCloseEnabled = tonumber(self.metrics.nativeEscapeCloseEnabled) or 0,
        nativeEscapeCloseDisabled = tonumber(self.metrics.nativeEscapeCloseDisabled) or 0,
        nativeModalDisabled = tonumber(self.metrics.nativeModalDisabled) or 0,
        consumedRejects = tonumber(self.metrics.consumedRejects) or 0,
        rootInteractionPolicyContractVersion = tonumber(self.RootInteractionPolicyContractVersion) or 0,
    }
end

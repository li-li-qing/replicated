------------------------------------------------------------------------
-- Replicated Suite - RSUI Outer Window Foundation v13
--
-- Every V3 top-level/native window binds its movement and resizing here.
-- Presentation code supplies policy/persistence callbacks; this layer owns the
-- native drag transaction, eight-edge resize handles, unrestricted free-placement
-- safety and strict-authority cache reconciliation after native movement.
--
-- No permanent Tick/OnUpdate is created. Native StartMoving/StartSizing owns
-- the mouse gesture. During an active resize only, one bounded ~16ms interactive task on the
-- shared Scheduler reflows RSUI content to the live Native extent. If scheduling
-- is unavailable/rejected, the dedicated resize handle owns a gesture-only
-- OnUpdate fallback. Both paths are removed immediately at drag stop.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local UI, RSUI = S.UI, S.RSUI
if type(UI) ~= "table" or type(RSUI) ~= "table" then return end

RSUI.Windowing = RSUI.Windowing or { version = 13, bindings = {}, metrics = { attached = 0, detached = 0, drags = 0, resizes = 0, locks = 0, raises = 0, opacityChanges = 0, resizeHover = 0, liveResizeFrames = 0, interactionBegins = 0, interactionEnds = 0, freePlacementCommits = 0, recoveryClamps = 0 } }
RSUI.Windowing.version = 13
RSUI.Windowing.IdempotentStateContractVersion = 1
RSUI.Windowing.CallbackCaptureContractVersion = 1
RSUI.Windowing.metrics = RSUI.Windowing.metrics or {}
local W = RSUI.Windowing
local NATIVE_RESIZE_LIMIT = 16384 -- technical guard only; not a user-facing window cap

local function NativeOf(value)
    if type(value) == "table" and value.root ~= nil then return value.root end
    return value
end

local function Clamp(value, minimum, maximum)
    value = tonumber(value) or minimum
    return math.max(minimum, math.min(maximum, value))
end

local function ReadLogicalRect(window)
    if S.Layout ~= nil and type(S.Layout.GetLogicalRect) == "function" then
        local ok, x, y, width, height = pcall(function() return S.Layout:GetLogicalRect(window) end)
        if ok then return tonumber(x) or 0, tonumber(y) or 0, math.max(1, tonumber(width) or 1), math.max(1, tonumber(height) or 1) end
    end
    local x, y, width, height = 0, 0, 1, 1
    if window ~= nil and type(window.GetOffset) == "function" then pcall(function() x, y = window:GetOffset() end) end
    if window ~= nil and type(window.GetWidth) == "function" then pcall(function() width = window:GetWidth() end) end
    if window ~= nil and type(window.GetHeight) == "function" then pcall(function() height = window:GetHeight() end) end
    return tonumber(x) or 0, tonumber(y) or 0, math.max(1, tonumber(width) or 1), math.max(1, tonumber(height) or 1)
end

local function ReconcileWindow(controller, window, owner, x, y, width, height)
    if window == nil then return false end
    local originalX, originalY = tonumber(x) or 0, tonumber(y) or 0
    local boundaryMode = tostring(controller and controller.boundaryMode or "free")
    if boundaryMode == "strict" then
        local context = S.Layout and S.Layout:GetContext() or { logicalWidth = 1024, logicalHeight = 768, safeLeft = 0, safeTop = 0, safeRight = 0, safeBottom = 0 }
        local left = tonumber(context.safeLeft) or 0
        local top = tonumber(context.safeTop) or 0
        local right = math.max(left, (tonumber(context.logicalWidth) or width) - (tonumber(context.safeRight) or 0) - width)
        local bottom = math.max(top, (tonumber(context.logicalHeight) or height) - (tonumber(context.safeBottom) or 0) - height)
        x, y = Clamp(x, left, right), Clamp(y, top, bottom)
    elseif boundaryMode == "recoverable" and S.Layout ~= nil and type(S.Layout.ClampRecoverableTopLeft) == "function" then
        x, y = S.Layout:ClampRecoverableTopLeft(x, y, width, height, {
            visibleX = controller and controller.recoveryVisibleX or 72,
            visibleY = controller and controller.recoveryVisibleY or 18,
            topReachHeight = controller and controller.dragHandleHeight or nil,
        })
    end
    if controller ~= nil and (math.abs((tonumber(x) or 0) - originalX) > 0.5 or math.abs((tonumber(y) or 0) - originalY) > 0.5) then
        W.metrics.recoveryClamps = (tonumber(W.metrics.recoveryClamps) or 0) + 1
    end

    -- Native movement/sizing intentionally changes geometry outside DiffRenderer
    -- while the mouse is captured. Clear the cached native snapshot BEFORE the
    -- strict owner writes the committed geometry back, so this valid transaction
    -- never looks like an authority violation.
    if type(UI.InvalidateNativeState) == "function" then UI:InvalidateNativeState(window) end
    UI:SetAnchor(window, UIParent, x, y, owner)
    UI:SetExtent(window, width, height, owner)
    return true, x, y, width, height
end

local HANDLE_SPECS = {
    { key = "top", direction = "TOP", cursor = "V", x = function(_, _, t) return t end, y = function() return 0 end, w = function(width, _, t) return math.max(1, width - t * 2) end, h = function(_, _, t) return t end },
    { key = "bottom", direction = "BOTTOM", cursor = "V", x = function(_, _, t) return t end, y = function(_, height, t) return math.max(0, height - t) end, w = function(width, _, t) return math.max(1, width - t * 2) end, h = function(_, _, t) return t end },
    { key = "left", direction = "LEFT", cursor = "H", x = function() return 0 end, y = function(_, _, t) return t end, w = function(_, _, t) return t end, h = function(_, height, t) return math.max(1, height - t * 2) end },
    { key = "right", direction = "RIGHT", cursor = "H", x = function(width, _, t) return math.max(0, width - t) end, y = function(_, _, t) return t end, w = function(_, _, t) return t end, h = function(_, height, t) return math.max(1, height - t * 2) end },
    { key = "top_left", direction = "TOPLEFT", cursor = "D1", x = function() return 0 end, y = function() return 0 end, w = function(_, _, t) return t end, h = function(_, _, t) return t end },
    { key = "top_right", direction = "TOPRIGHT", cursor = "D2", x = function(width, _, t) return math.max(0, width - t) end, y = function() return 0 end, w = function(_, _, t) return t end, h = function(_, _, t) return t end },
    { key = "bottom_left", direction = "BOTTOMLEFT", cursor = "D2", x = function() return 0 end, y = function(_, height, t) return math.max(0, height - t) end, w = function(_, _, t) return t end, h = function(_, _, t) return t end },
    { key = "bottom_right", direction = "BOTTOMRIGHT", cursor = "D1", x = function(width, _, t) return math.max(0, width - t) end, y = function(_, height, t) return math.max(0, height - t) end, w = function(_, _, t) return t end, h = function(_, _, t) return t end },
}

function W:Attach(spec)
    spec = type(spec) == "table" and spec or {}
    local id = tostring(spec.id or "")
    local owner = tostring(spec.owner or "")
    local window = NativeOf(spec.window)
    local dragHandle = NativeOf(spec.dragHandle)
    if id == "" or window == nil or dragHandle == nil or owner == "" then return nil, "windowing identity required" end
    if self.bindings[id] ~= nil then return self.bindings[id] end

    -- A top-level window has no UX minimum in the foundation. Feature code may
    -- opt into a semantic minimum explicitly; otherwise only the native 1px
    -- technical floor remains. Layout compression/clipping owns tiny extents.
    local minWidth = math.max(1, tonumber(spec.minWidth) or 1)
    local minHeight = math.max(1, tonumber(spec.minHeight) or 1)
    local maxWidth = tonumber(spec.maxWidth)
    local maxHeight = tonumber(spec.maxHeight)
    if maxWidth ~= nil then maxWidth = math.max(minWidth, maxWidth) end
    if maxHeight ~= nil then maxHeight = math.max(minHeight, maxHeight) end

    local controller = {
        id = id, owner = owner, window = window, dragHandle = dragHandle,
        handles = {}, enabled = true, locked = spec.locked == true, resizeEnabled = spec.resizable ~= false,
        minWidth = minWidth,
        minHeight = minHeight,
        maxWidth = maxWidth,
        maxHeight = maxHeight,
        handleThickness = math.max(5, tonumber(spec.handleThickness) or 8),
        boundaryMode = tostring(spec.boundaryMode or "free"),
        recoveryVisibleX = math.max(8, tonumber(spec.recoveryVisibleX) or 72),
        recoveryVisibleY = math.max(8, tonumber(spec.recoveryVisibleY) or 18),
        dragHandleHeight = math.max(8, tonumber(spec.dragHandleHeight) or 36),
        onGeometryChanged = spec.onGeometryChanged,
        canDrag = spec.canDrag,
        canResize = spec.canResize,
        onDragStart = spec.onDragStart,
        onDragStop = spec.onDragStop,
        onResizeStart = spec.onResizeStart,
        onResizeStop = spec.onResizeStop,
        onLiveGeometry = spec.onLiveGeometry,
        opacity = math.max(0.0, math.min(1.0, tonumber(spec.opacity) or 1.0)),
    }


    function controller:IsInteracting()
        return self.interactionKind ~= nil
    end

    function controller:IsDragging()
        return self.interactionKind == "drag"
    end

    function controller:IsResizing()
        return self.interactionKind == "resize"
    end

    function controller:GetInteractionKind()
        return self.interactionKind
    end

    function controller:StopLiveGeometryTask()
        if self.liveTaskName ~= nil and S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then
            S.Scheduler:RemoveTask(self.liveTaskName)
        end
        self.liveTaskName = nil
        if self.liveUpdateFallback == true and self.liveFallbackWidget ~= nil and type(self.liveFallbackWidget.ReleaseHandler) == "function" then
            pcall(function() self.liveFallbackWidget:ReleaseHandler("OnUpdate") end)
        end
        self.liveUpdateFallback = false
        self.liveFallbackWidget = nil
        return true
    end

    function controller:PulseLiveGeometry(force)
        if self:IsResizing() ~= true or type(self.onLiveGeometry) ~= "function" then return false end
        local x, y, width, height = ReadLogicalRect(self.window)
        local changed = force == true
            or self.lastLiveWidth == nil or self.lastLiveHeight == nil
            or math.abs(width - self.lastLiveWidth) > 0.5 or math.abs(height - self.lastLiveHeight) > 0.5
            or math.abs(x - (self.lastLiveX or x)) > 0.5 or math.abs(y - (self.lastLiveY or y)) > 0.5
        if changed ~= true then return false end
        self.lastLiveX, self.lastLiveY, self.lastLiveWidth, self.lastLiveHeight = x, y, width, height
        local ok = pcall(self.onLiveGeometry, self, x, y, width, height, self.interactionKind, self.interactionDirection)
        if ok then W.metrics.liveResizeFrames = (tonumber(W.metrics.liveResizeFrames) or 0) + 1 end
        return ok
    end

    function controller:StartLiveGeometryTask(fallbackWidget)
        self:StopLiveGeometryTask()
        if self:IsResizing() ~= true or type(self.onLiveGeometry) ~= "function" then return false end
        local scheduler = S.Scheduler
        local taskName = "rsui_window_live_resize:" .. self.id
        local added = false
        if scheduler ~= nil and type(scheduler.AddInteractiveTask) == "function" then
            self.liveTaskName = taskName
            scheduler:RemoveTask(taskName)
            added = scheduler:AddInteractiveTask(taskName, 16, function()
                if controller:IsResizing() ~= true then
                    controller:StopLiveGeometryTask()
                    return true
                end
                controller:PulseLiveGeometry(false)
                return true
            end, true, controller, "P0", 1) == true
            if added ~= true then self.liveTaskName = nil end
        end
        if added ~= true and fallbackWidget ~= nil then
            self.liveFallbackWidget = fallbackWidget
            self.liveUpdateFallback = UI:SafeHandler(fallbackWidget, "OnUpdate", function()
                if controller:IsResizing() then controller:PulseLiveGeometry(false) end
                return true
            end, "v3_window:" .. self.id .. ":live_resize_update") == true
            if self.liveUpdateFallback ~= true then self.liveFallbackWidget = nil end
        end
        return added == true or self.liveUpdateFallback == true
    end

    function controller:BeginInteraction(kind, direction)
        kind = tostring(kind or "")
        if kind ~= "drag" and kind ~= "resize" then return false end
        if self.interactionKind ~= nil then return false end
        if type(UI.BeginNativeGeometryLease) == "function" then
            local ok = UI:BeginNativeGeometryLease(self.window, self.owner, kind)
            if ok ~= true then return false end
        end
        self.interactionKind = kind
        self.interactionDirection = direction
        self.lastLiveX, self.lastLiveY, self.lastLiveWidth, self.lastLiveHeight = ReadLogicalRect(self.window)
        W.metrics.interactionBegins = (tonumber(W.metrics.interactionBegins) or 0) + 1
        return true
    end

    function controller:EndInteraction()
        if self.interactionKind == nil then return true end
        self:StopLiveGeometryTask()
        if type(UI.EndNativeGeometryLease) == "function" then UI:EndNativeGeometryLease(self.window, self.owner) end
        self.interactionKind = nil
        self.interactionDirection = nil
        self.lastLiveX, self.lastLiveY, self.lastLiveWidth, self.lastLiveHeight = nil, nil, nil, nil
        W.metrics.interactionEnds = (tonumber(W.metrics.interactionEnds) or 0) + 1
        return true
    end

    function controller:IsDragAllowed()
        if self.enabled ~= true or self.locked == true then return false end
        if type(self.canDrag) == "function" then
            local ok, value = pcall(self.canDrag, self)
            return ok and value ~= false
        end
        return true
    end

    function controller:IsResizeAllowed()
        if self.enabled ~= true or self.locked == true or self.resizeEnabled ~= true then return false end
        if type(self.canResize) == "function" then
            local ok, value = pcall(self.canResize, self)
            return ok and value ~= false
        end
        return true
    end

    function controller:ApplyNativeResizeBounds()
        if self.window == nil then return false end
        local context = S.Layout and S.Layout:GetContext() or { addonScale = 1 }
        local scale = math.max(0.01, tonumber(context.addonScale) or 1)
        local minW = math.max(1, (tonumber(self.minWidth) or 1) * scale)
        local minH = math.max(1, (tonumber(self.minHeight) or 1) * scale)
        -- Native APIs require a finite maximum on some RU clients. When the
        -- caller has no semantic max, use a very large technical guard instead
        -- of silently capping to the current viewport.
        local maxW = math.max(minW, (tonumber(self.maxWidth) or NATIVE_RESIZE_LIMIT) * scale)
        local maxH = math.max(minH, (tonumber(self.maxHeight) or NATIVE_RESIZE_LIMIT) * scale)
        if type(self.window.UseResizing) == "function" then pcall(function() self.window:UseResizing(self.resizeEnabled == true and self.locked ~= true) end) end
        if type(self.window.SetMinResizingExtent) == "function" then pcall(function() self.window:SetMinResizingExtent(minW, minH) end) end
        if type(self.window.SetMaxResizingExtent) == "function" then pcall(function() self.window:SetMaxResizingExtent(maxW, maxH) end) end
        return true
    end

    function controller:CommitGeometry(reason)
        local x, y, width, height = ReadLogicalRect(self.window)
        local context = S.Layout and S.Layout:GetContext() or { addonScale = 1 }
        local scale = math.max(0.01, tonumber(context.addonScale) or 1)
        width = math.max((tonumber(self.minWidth) or 1) * scale, width)
        height = math.max((tonumber(self.minHeight) or 1) * scale, height)
        if self.maxWidth ~= nil then width = math.min(width, self.maxWidth * scale) end
        if self.maxHeight ~= nil then height = math.min(height, self.maxHeight * scale) end
        local ok
        ok, x, y, width, height = ReconcileWindow(self, self.window, self.owner, x, y, width, height)
        if ok ~= true then return false end
        if self.boundaryMode ~= "strict" then W.metrics.freePlacementCommits = (tonumber(W.metrics.freePlacementCommits) or 0) + 1 end
        if type(self.onGeometryChanged) == "function" then pcall(self.onGeometryChanged, self, x, y, width, height, tostring(reason or "geometry")) end
        return true, x, y, width, height
    end

    function controller:LayoutHandles(width, height)
        width, height = math.max(1, tonumber(width) or 1), math.max(1, tonumber(height) or 1)
        local t = self.handleThickness
        for _, definition in ipairs(HANDLE_SPECS) do
            local handle = self.handles[definition.key]
            if handle ~= nil then
                local x = definition.x(width, height, t)
                local y = definition.y(width, height, t)
                local w = definition.w(width, height, t)
                local h = definition.h(width, height, t)
                UI:SetAnchor(handle, self.window, x, y, self.owner)
                UI:SetExtent(handle, w, h, self.owner)
                UI:SetVisible(handle, self.resizeEnabled == true and self.locked ~= true, self.owner)
            end
        end
        self:ApplyNativeResizeBounds()
        return true
    end

    function controller:SetResizeEnabled(enabled)
        local nextValue = enabled == true
        if self.resizeEnabled == nextValue then return true, self.resizeEnabled, false end
        self.resizeEnabled = nextValue
        if type(self.window.UseResizing) == "function" then pcall(function() self.window:UseResizing(self.resizeEnabled and self.locked ~= true) end) end
        local _, _, width, height = ReadLogicalRect(self.window)
        self:LayoutHandles(width, height)
        return true, self.resizeEnabled, true
    end

    function controller:SetLocked(locked)
        local nextValue = locked == true
        if self.locked == nextValue then return true, false end
        self.locked = nextValue
        if type(self.window.UseResizing) == "function" then pcall(function() self.window:UseResizing(self.resizeEnabled == true and self.locked ~= true) end) end
        local _, _, width, height = ReadLogicalRect(self.window)
        self:LayoutHandles(width, height)
        W.metrics.locks = (tonumber(W.metrics.locks) or 0) + 1
        return true, true
    end

    function controller:IsLocked()
        return self.locked == true
    end

    function controller:BringToFront()
        if self.window == nil or type(self.window.Raise) ~= "function" then return false end
        local ok = pcall(function() self.window:Raise() end)
        if ok then W.metrics.raises = (tonumber(W.metrics.raises) or 0) + 1 end
        return ok
    end

    function controller:SetOpacity(value)
        local nextValue = math.max(0.0, math.min(1.0, tonumber(value) or self.opacity or 1.0))
        if math.abs(nextValue - (tonumber(self.opacity) or 1.0)) <= 0.0001 then return true, nextValue, false end
        self.opacity = nextValue
        local changed = UI:SetAlpha(self.window, nextValue, self.owner)
        if changed then W.metrics.opacityChanges = (tonumber(W.metrics.opacityChanges) or 0) + 1 end
        return true, nextValue, true
    end

    function controller:GetOpacity()
        return tonumber(self.opacity) or 1.0
    end

    UI:SetPickable(dragHandle, true, owner)
    if type(dragHandle.EnableDrag) == "function" then pcall(function() dragHandle:EnableDrag(true) end) end
    UI:SafeHandler(dragHandle, "OnDragStart", function()
        if controller:IsDragAllowed() ~= true or type(window.StartMoving) ~= "function" then return false end
        controller:BringToFront()
        if controller:BeginInteraction("drag") ~= true then return false end
        local ok = pcall(function() window:StartMoving() end)
        controller.dragging = ok == true
        if controller.dragging ~= true then controller:EndInteraction(); return false end
        if type(controller.onDragStart) == "function" then pcall(controller.onDragStart, controller) end
        W.metrics.drags = (tonumber(W.metrics.drags) or 0) + 1
        return true
    end, "v3_window:" .. id .. ":drag_start")
    UI:SafeHandler(dragHandle, "OnDragStop", function()
        if controller.dragging == true and type(window.StopMovingOrSizing) == "function" then pcall(function() window:StopMovingOrSizing() end) end
        controller.dragging = false
        controller:EndInteraction()
        controller:CommitGeometry("drag")
        if type(controller.onDragStop) == "function" then pcall(controller.onDragStop, controller) end
        return true
    end, "v3_window:" .. id .. ":drag_stop")

    if controller.resizeEnabled then
        for _, definition in ipairs(HANDLE_SPECS) do
            -- Deferred native drag callbacks must not capture the reused Lua 5.1
            -- generic-for variable. A stable per-handle definition preserves the
            -- correct resize direction for every edge/corner.
            local handleDefinition = definition
            local handle = UI:CreateEmptyWidget(window, "v3_window_" .. id .. "_resize_" .. handleDefinition.key, 0, 0, 1, 1, true)
            if handle ~= nil then
                controller.handles[handleDefinition.key] = handle
                if type(handle.EnableDrag) == "function" then pcall(function() handle:EnableDrag(true) end) end
                -- ArcheRage RU exposes X2Cursor:SetCursorImage, but the project
                -- does not yet contain a verified resize-cursor texture path.
                -- Until that native asset is verified, provide an immediate
                -- framework-owned edge highlight on hover rather than guessing a
                -- client resource name. The hit target and actual resize gesture
                -- remain identical.
                local hoverLine = nil
                if type(handle.CreateColorDrawable) == "function" then
                    hoverLine = handle:CreateColorDrawable(0.84, 0.68, 0.28, 0.0, "overlay")
                    if hoverLine ~= nil and type(hoverLine.AddAnchor) == "function" then
                        hoverLine:AddAnchor("TOPLEFT", handle, 0, 0)
                        hoverLine:AddAnchor("BOTTOMRIGHT", handle, 0, 0)
                    end
                end
                local function SetResizeHover(active)
                    if hoverLine ~= nil and type(hoverLine.SetColor) == "function" then
                        pcall(function() hoverLine:SetColor(0.84, 0.68, 0.28, active and 0.72 or 0.0) end)
                    end
                    if active then W.metrics.resizeHover = (tonumber(W.metrics.resizeHover) or 0) + 1 end
                end
                UI:SafeHandler(handle, "OnEnter", function() SetResizeHover(true); return true end, "v3_window:" .. id .. ":resize_enter:" .. handleDefinition.key)
                UI:SafeHandler(handle, "OnLeave", function() if handle.rsWindowSizing ~= true then SetResizeHover(false) end; return true end, "v3_window:" .. id .. ":resize_leave:" .. handleDefinition.key)
                UI:SafeHandler(handle, "OnDragStart", function()
                    if controller:IsResizeAllowed() ~= true or type(window.StartSizing) ~= "function" then return false end
                    controller:BringToFront()
                    if controller:BeginInteraction("resize", handleDefinition.direction) ~= true then return false end
                    local ok = pcall(function() window:StartSizing(handleDefinition.direction) end)
                    handle.rsWindowSizing = ok == true
                    if handle.rsWindowSizing ~= true then controller:EndInteraction(); return false end
                    if type(controller.onResizeStart) == "function" then pcall(controller.onResizeStart, controller, handleDefinition.direction) end
                    controller:PulseLiveGeometry(true)
                    controller:StartLiveGeometryTask(handle)
                    W.metrics.resizes = (tonumber(W.metrics.resizes) or 0) + 1
                    SetResizeHover(true)
                    return true
                end, "v3_window:" .. id .. ":resize_start:" .. handleDefinition.key)
                UI:SafeHandler(handle, "OnDragStop", function()
                    if handle.rsWindowSizing == true and type(window.StopMovingOrSizing) == "function" then pcall(function() window:StopMovingOrSizing() end) end
                    handle.rsWindowSizing = false
                    controller:PulseLiveGeometry(true)
                    controller:EndInteraction()
                    SetResizeHover(false)
                    controller:CommitGeometry("resize")
                    local _, _, width, height = ReadLogicalRect(window)
                    controller:LayoutHandles(width, height)
                    if type(controller.onResizeStop) == "function" then pcall(controller.onResizeStop, controller, handleDefinition.direction) end
                    return true
                end, "v3_window:" .. id .. ":resize_stop:" .. handleDefinition.key)
            end
        end
    end

    controller:SetOpacity(controller.opacity)
    self.bindings[id] = controller
    self.metrics.attached = (tonumber(self.metrics.attached) or 0) + 1
    return controller
end

function W:Detach(id)
    id = tostring(id or "")
    local controller = self.bindings[id]
    if controller == nil then return false end
    controller.enabled = false
    controller.locked = true
    -- Detach can happen during page/shell teardown while native mouse capture is
    -- still active. Release the RU StartMoving/StartSizing transaction before
    -- dropping the geometry lease/handlers, otherwise a hidden stale window may
    -- keep moving or sizing until the next mouse event.
    if controller:IsInteracting() == true and controller.window ~= nil and type(controller.window.StopMovingOrSizing) == "function" then
        pcall(function() controller.window:StopMovingOrSizing() end)
    end
    controller.dragging = false
    for _, handle in pairs(controller.handles or {}) do handle.rsWindowSizing = false end
    controller:EndInteraction()
    if controller.window ~= nil and type(controller.window.UseResizing) == "function" then
        pcall(function() controller.window:UseResizing(false) end)
    end
    local function Release(widget, eventName)
        if widget ~= nil and type(widget.ReleaseHandler) == "function" then pcall(function() widget:ReleaseHandler(eventName) end) end
    end
    Release(controller.dragHandle, "OnDragStart")
    Release(controller.dragHandle, "OnDragStop")
    for _, handle in pairs(controller.handles or {}) do
        Release(handle, "OnDragStart")
        Release(handle, "OnDragStop")
        Release(handle, "OnEnter")
        Release(handle, "OnLeave")
        UI:SetVisible(handle, false, controller.owner)
    end
    self.bindings[id] = nil
    self.metrics.detached = (tonumber(self.metrics.detached) or 0) + 1
    return true
end

function W:Describe()
    local count, locked = 0, 0
    for _, controller in pairs(self.bindings or {}) do
        count = count + 1
        if controller.locked == true then locked = locked + 1 end
    end
    return {
        version = self.version,
        attached = count,
        locked = locked,
        detached = tonumber(self.metrics.detached) or 0,
        drags = tonumber(self.metrics.drags) or 0,
        resizes = tonumber(self.metrics.resizes) or 0,
        lockChanges = tonumber(self.metrics.locks) or 0,
        raises = tonumber(self.metrics.raises) or 0,
        opacityChanges = tonumber(self.metrics.opacityChanges) or 0,
        resizeHover = tonumber(self.metrics.resizeHover) or 0,
        liveResizeFrames = tonumber(self.metrics.liveResizeFrames) or 0,
        interactionBegins = tonumber(self.metrics.interactionBegins) or 0,
        interactionEnds = tonumber(self.metrics.interactionEnds) or 0,
        freePlacementCommits = tonumber(self.metrics.freePlacementCommits) or 0,
        recoveryClamps = tonumber(self.metrics.recoveryClamps) or 0,
        idempotentStateContractVersion = tonumber(self.IdempotentStateContractVersion) or 0,
        callbackCaptureContractVersion = tonumber(self.CallbackCaptureContractVersion) or 0,
    }
end

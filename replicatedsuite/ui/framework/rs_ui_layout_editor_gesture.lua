------------------------------------------------------------------------
-- Replicated Suite - RSUI Layout Editor Gesture Controller v2
--
-- Finite gesture bridge for editor-style move/resize interactions.
--
-- Authority boundaries:
--   * Native StartMoving/StopMovingOrSizing = proven RU capture mechanism.
--   * RSUI.Pointer = logical pointer coordinates only; no generic capture.
--   * S.Layout RectTransformTransaction = transform math / rollback.
--   * LayoutGuideResolver = bounded snap math against candidates frozen at Begin.
--   * SelectionOverlay / LayoutGuideOverlay = presentation only.
--   * Caller owns persistence and feature state through callbacks.
--
-- Coordinate-space contract:
--   Pointer is sampled in viewport-logical coordinates. If edited rectangles are
--   parent/canvas-local, callers MUST provide pointerToLocal(x,y). Identity
--   conversion is accepted only when coordinateSpace="viewport" is declared.
--
-- Performance contract:
--   * no permanent Tick / OnUpdate;
--   * one ~16 ms InteractiveTask only while a gesture is active;
--   * OnUpdate is gesture-only fallback when Scheduler rejects/unavailable;
--   * snap candidate discovery runs once at gesture Begin, never every pulse;
--   * each pulse is pointer sampling + O(bounded candidates) pure math;
--   * persistence is caller-owned and should occur only in onCommit.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI = S.RSUI
local UI = S.UI
local Layout = S.Layout
if type(RSUI) ~= "table" or type(UI) ~= "table" or type(Layout) ~= "table" then return end

RSUI.LayoutEditorGestureContractVersion = 2

local HARD_MAX_FROZEN_CANDIDATES = 1024
local HANDLE_KEYS = { "top_left", "top", "top_right", "right", "bottom_right", "bottom", "bottom_left", "left" }

local function N(value, fallback)
    local result = tonumber(value)
    if result == nil then result = tonumber(fallback) or 0 end
    return result
end

local function CopyRect(rect)
    if type(rect) ~= "table" then return nil end
    local x, y = tonumber(rect.x), tonumber(rect.y)
    local width, height = tonumber(rect.width or rect.w), tonumber(rect.height or rect.h)
    if x == nil or y == nil or width == nil or height == nil or width <= 0 or height <= 0 then return nil end
    return { x = x, y = y, width = width, height = height }
end

local function SafeCall(label, callback, ...)
    if type(callback) ~= "function" then return true, nil end
    local args, count = { ... }, select("#", ...)
    local ok, resultA, resultB = xpcall(function()
        return callback(unpack(args, 1, count))
    end, S.SafeTraceback)
    if ok ~= true then
        if S.Diagnostics ~= nil and type(S.Diagnostics.RecordError) == "function" then
            pcall(function() S.Diagnostics:RecordError(tostring(label or "rsui_layout_editor_gesture"), resultA) end)
        end
        return false, resultA
    end
    return true, resultA, resultB
end

local function ReleaseHandler(widget, eventName)
    if widget ~= nil and type(widget.ReleaseHandler) == "function" then
        pcall(function() widget:ReleaseHandler(eventName) end)
    end
end

local function CopyCandidate(candidate, fallbackKey)
    if type(candidate) ~= "table" then return nil end
    local source = type(candidate.rect) == "table" and candidate.rect or candidate
    local rect = CopyRect(source)
    if rect == nil then return nil end
    return { key = tostring(candidate.key or fallbackKey), rect = rect }
end

local function FreezeSnapOptions(rawOptions, rawCandidates)
    rawOptions = type(rawOptions) == "table" and rawOptions or {}
    local frozen = {}
    for key, value in pairs(rawOptions) do
        if key ~= "candidates" and key ~= "canvasRect" and type(value) ~= "table" and type(value) ~= "function" then
            frozen[key] = value
        end
    end
    frozen.canvasRect = CopyRect(rawOptions.canvasRect)
    frozen.maxCandidates = math.max(1, math.min(math.floor(N(rawOptions.maxCandidates, 256)), HARD_MAX_FROZEN_CANDIDATES))
    frozen.candidates = {}
    local sourceCandidates = type(rawCandidates) == "table" and rawCandidates
        or (type(rawOptions.candidates) == "table" and rawOptions.candidates or {})
    local inspected = 0
    for index, candidate in ipairs(sourceCandidates) do
        if inspected >= frozen.maxCandidates then break end
        inspected = inspected + 1
        local copied = CopyCandidate(candidate, index)
        if copied ~= nil then frozen.candidates[#frozen.candidates + 1] = copied end
    end
    frozen.candidateSourceScanned = inspected
    frozen.candidatesTruncated = #sourceCandidates > inspected
    return frozen
end

local GestureController = {}
GestureController.__index = GestureController

function GestureController:GetSnapshot()
    return {
        id = self.id,
        contractVersion = tonumber(RSUI.LayoutEditorGestureContractVersion) or 0,
        active = self.active == true,
        kind = self.kind,
        handle = self.handle,
        coordinateSpace = self.coordinateSpace,
        sampling = self.taskName ~= nil and "scheduler" or (self.updateFallback == true and "on_update" or "none"),
        frozenCandidateCount = tonumber(self.frozenCandidateCount) or 0,
        previewRejected = self.previewRejected == true,
        revision = tonumber(self.revision) or 0,
        lastError = self.lastError,
    }
end

function GestureController:SampleLocalPointer()
    local pointer = RSUI.Pointer
    if type(pointer) ~= "table" or type(pointer.GetLogicalPosition) ~= "function" then
        return nil, nil, "layout_editor_pointer_unavailable"
    end
    local x, y, err = pointer:GetLogicalPosition()
    if x == nil or y == nil then return nil, nil, err or "layout_editor_pointer_unavailable" end
    if type(self.pointerToLocal) == "function" then
        local ok, localX, localY = SafeCall("rsui_layout_editor_pointer_to_local", self.pointerToLocal, x, y, self)
        if ok ~= true or tonumber(localX) == nil or tonumber(localY) == nil then
            return nil, nil, "layout_editor_pointer_space_conversion_failed"
        end
        return tonumber(localX), tonumber(localY), nil
    end
    if self.coordinateSpace == "viewport" then return tonumber(x), tonumber(y), nil end
    return nil, nil, "layout_editor_pointer_to_local_required"
end

function GestureController:StopSampling()
    if self.taskName ~= nil and S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then
        S.Scheduler:RemoveTask(self.taskName)
    end
    self.taskName = nil
    if self.updateFallback == true and self.captureSurface ~= nil then ReleaseHandler(self.captureSurface, "OnUpdate") end
    self.updateFallback = false
    return true
end

function GestureController:StartSampling()
    self:StopSampling()
    local scheduler = S.Scheduler
    local taskName = "rsui_layout_editor_gesture:" .. self.id
    if scheduler ~= nil and type(scheduler.AddInteractiveTask) == "function" then
        scheduler:RemoveTask(taskName)
        local added = scheduler:AddInteractiveTask(taskName, 16, function()
            if self.active ~= true then self:StopSampling(); return true end
            self:Pulse(false)
            return true
        end, true, self, "P0", 1) == true
        if added then self.taskName = taskName; return true end
    end
    if self.captureSurface ~= nil then
        self.updateFallback = UI:SafeHandler(self.captureSurface, "OnUpdate", function()
            if self.active == true then
                RSUI.metrics.layoutEditorGestureFallbackUpdates = (tonumber(RSUI.metrics.layoutEditorGestureFallbackUpdates) or 0) + 1
                self:Pulse(false)
            end
            return true
        end, "rsui:" .. self.id .. ":gesture_update") == true
    end
    return self.updateFallback == true
end

function GestureController:ResolveTransformConstraints(kind, handle, startRect)
    local constraints = {
        minWidth = self.minWidth, minHeight = self.minHeight,
        maxWidth = self.maxWidth, maxHeight = self.maxHeight,
    }
    if type(self.getTransformConstraints) == "function" then
        local ok, patch, detail = SafeCall("rsui_layout_editor_transform_constraints",
            self.getTransformConstraints, self, kind, handle, CopyRect(startRect))
        if ok ~= true then return nil, "layout_editor_transform_constraints_failed" end
        if patch == false then return nil, tostring(detail or "layout_editor_transform_constraints_rejected") end
        if type(patch) == "table" then
            local minWidth = patch.minWidth ~= nil and tonumber(patch.minWidth) or constraints.minWidth
            local minHeight = patch.minHeight ~= nil and tonumber(patch.minHeight) or constraints.minHeight
            local maxWidth = patch.maxWidth ~= nil and tonumber(patch.maxWidth) or constraints.maxWidth
            local maxHeight = patch.maxHeight ~= nil and tonumber(patch.maxHeight) or constraints.maxHeight
            if minWidth == nil or minHeight == nil or minWidth <= 0 or minHeight <= 0 then
                return nil, "layout_editor_transform_constraints_invalid_minimum"
            end
            if maxWidth ~= nil and maxWidth < minWidth then return nil, "layout_editor_transform_constraints_invalid_max_width" end
            if maxHeight ~= nil and maxHeight < minHeight then return nil, "layout_editor_transform_constraints_invalid_max_height" end
            constraints.minWidth, constraints.minHeight = minWidth, minHeight
            constraints.maxWidth, constraints.maxHeight = maxWidth, maxHeight
        end
    end
    return constraints, nil
end

function GestureController:FreezeSnapState(kind, handle, startRect, constraints)
    local rawOptions = self.snapOptions
    if type(self.getSnapOptions) == "function" then
        local ok, value = SafeCall("rsui_layout_editor_snap_options", self.getSnapOptions, self, kind, handle, CopyRect(startRect))
        if ok ~= true then return nil, "layout_editor_snap_options_failed" end
        rawOptions = value
    end
    local rawCandidates = nil
    -- Candidate discovery is only needed when alignment snapping is enabled.
    -- Grid-only or disabled snapping must not walk the page/component tree at
    -- gesture start merely because a getSnapCandidates callback exists.
    local wantsAlignment = type(rawOptions) ~= "table" or (rawOptions.enabled ~= false and rawOptions.alignmentEnabled ~= false)
    if wantsAlignment and type(self.getSnapCandidates) == "function" then
        local ok, value = SafeCall("rsui_layout_editor_snap_candidates", self.getSnapCandidates, self, kind, handle, CopyRect(startRect))
        if ok ~= true then return nil, "layout_editor_snap_candidates_failed" end
        rawCandidates = value
    end
    local frozen = FreezeSnapOptions(rawOptions, rawCandidates)
    constraints = type(constraints) == "table" and constraints or {}
    frozen.minWidth = tonumber(constraints.minWidth) or self.minWidth
    frozen.minHeight = tonumber(constraints.minHeight) or self.minHeight
    frozen.maxWidth = constraints.maxWidth ~= nil and tonumber(constraints.maxWidth) or self.maxWidth
    frozen.maxHeight = constraints.maxHeight ~= nil and tonumber(constraints.maxHeight) or self.maxHeight
    self.frozenCandidateCount = #frozen.candidates
    RSUI.metrics.layoutEditorGestureCandidateFreezes = (tonumber(RSUI.metrics.layoutEditorGestureCandidateFreezes) or 0) + 1
    return frozen, nil
end

function GestureController:Pulse(force)
    if self.active ~= true or self.transaction == nil then return false, "layout_editor_gesture_not_active" end
    local currentX, currentY, pointerErr = self:SampleLocalPointer()
    if currentX == nil or currentY == nil then self.lastError = pointerErr; return false, pointerErr end
    local dx, dy, deltaErr = RSUI.Pointer:Delta(self.startPointerX, self.startPointerY, currentX, currentY)
    if deltaErr ~= nil then self.lastError = deltaErr; return false, deltaErr end
    if force ~= true and self.lastDeltaX ~= nil and math.abs(dx - self.lastDeltaX) < 0.001
        and math.abs(dy - self.lastDeltaY) < 0.001 then return true end

    local proposed, previewErr = self.transaction:PreviewDelta(dx, dy)
    if proposed == nil then self.lastError = previewErr; return false, previewErr end
    local resolved, guides, resolveErr = RSUI.LayoutGuideResolver:Resolve(proposed, self.handle or "move", self.frozenSnapOptions or {})
    if resolved == nil then
        -- Snap is an enhancement, not transform authority. If it cannot resolve,
        -- keep the valid unsnapped transform instead of freezing the gesture.
        resolved, guides = proposed, {}
        self.lastSnapError = resolveErr
    else
        self.lastSnapError = nil
    end
    if self.frozenSnapOptions ~= nil and self.frozenSnapOptions.showGuides == false then guides = {} end
    local overridden, overrideErr = self.transaction:OverridePreview(resolved)
    if overridden == nil then self.lastError = overrideErr; return false, overrideErr end

    self.lastDeltaX, self.lastDeltaY = dx, dy
    self.lastRect = CopyRect(overridden)
    self.lastGuides = guides or {}
    if self.overlay ~= nil and type(self.overlay.SetRect) == "function" then self.overlay:SetRect(overridden) end
    if self.guideOverlay ~= nil and type(self.guideOverlay.SetGuides) == "function" then self.guideOverlay:SetGuides(self.lastGuides) end
    local callbackOk, accepted, detail = SafeCall("rsui_layout_editor_preview", self.onPreview,
        CopyRect(overridden), self.lastGuides, self)
    if self.previewMustSucceed == true and (callbackOk ~= true or accepted == false) then
        self.previewRejected = true
        self.lastError = tostring(detail or (callbackOk ~= true and accepted) or "layout_editor_preview_callback_rejected")
        RSUI.metrics.layoutEditorGesturePreviewRejects = (tonumber(RSUI.metrics.layoutEditorGesturePreviewRejects) or 0) + 1
        return false, self.lastError
    end
    self.revision = (tonumber(self.revision) or 0) + 1
    RSUI.metrics.layoutEditorGesturePulses = (tonumber(RSUI.metrics.layoutEditorGesturePulses) or 0) + 1
    return true, nil
end

function GestureController:Begin(kind, handle, captureSurface)
    if self.active == true then return false, "layout_editor_gesture_already_active" end
    if self.enabled ~= true then return false, "layout_editor_gesture_disabled" end
    if type(self.canBegin) == "function" then
        local ok, allowed = SafeCall("rsui_layout_editor_can_begin", self.canBegin, self, kind, handle)
        if ok ~= true or allowed == false then return false, "layout_editor_gesture_rejected" end
    end
    kind = tostring(kind or "move")
    handle = kind == "move" and "move" or tostring(handle or "")
    if kind ~= "move" and kind ~= "resize" then return false, "layout_editor_gesture_kind_invalid" end
    if captureSurface == nil or type(captureSurface.StartMoving) ~= "function" then
        RSUI.metrics.layoutEditorGestureCaptureFailures = (tonumber(RSUI.metrics.layoutEditorGestureCaptureFailures) or 0) + 1
        return false, "layout_editor_capture_surface_invalid"
    end
    if type(self.getRect) ~= "function" then return false, "layout_editor_get_rect_required" end
    local okRect, rawRect = SafeCall("rsui_layout_editor_get_rect", self.getRect, self)
    local startRect = okRect and CopyRect(rawRect) or nil
    if startRect == nil then return false, "layout_editor_start_rect_invalid" end
    local startX, startY, pointerErr = self:SampleLocalPointer()
    if startX == nil or startY == nil then return false, pointerErr end
    local constraints, constraintsErr = self:ResolveTransformConstraints(kind, handle, startRect)
    if constraints == nil then return false, constraintsErr end
    local frozen, freezeErr = self:FreezeSnapState(kind, handle, startRect, constraints)
    if frozen == nil then return false, freezeErr end

    local tx = Layout:CreateRectTransformTransaction({
        minWidth = constraints.minWidth, minHeight = constraints.minHeight,
        maxWidth = constraints.maxWidth, maxHeight = constraints.maxHeight,
    })
    local begun, beginErr = tx:Begin(startRect, kind, kind == "resize" and handle or nil)
    if begun ~= true then return false, beginErr end

    local leased = type(UI.BeginNativeGeometryLease) == "function"
        and UI:BeginNativeGeometryLease(captureSurface, self.owner, "layout_editor_" .. kind) == true
    if leased ~= true then
        tx:Cancel()
        RSUI.metrics.layoutEditorGestureCaptureFailures = (tonumber(RSUI.metrics.layoutEditorGestureCaptureFailures) or 0) + 1
        return false, "layout_editor_geometry_lease_failed"
    end
    local started, _, startErr = UI:TryInteractionCall(captureSurface, "StartMoving")
    if started ~= true then
        UI:EndNativeGeometryLease(captureSurface, self.owner)
        tx:Cancel()
        RSUI.metrics.layoutEditorGestureCaptureFailures = (tonumber(RSUI.metrics.layoutEditorGestureCaptureFailures) or 0) + 1
        return false, "layout_editor_native_capture_failed:" .. tostring(startErr or "native_rejected")
    end

    self.active = true
    self.kind, self.handle = kind, handle
    self.captureSurface = captureSurface
    self.transaction = tx
    self.startRect = CopyRect(startRect)
    self.lastRect = CopyRect(startRect)
    self.startPointerX, self.startPointerY = startX, startY
    self.lastDeltaX, self.lastDeltaY = nil, nil
    self.frozenSnapOptions = frozen
    self.activeConstraints = constraints
    self.lastGuides = {}
    self.lastError, self.lastSnapError = nil, nil
    self.previewRejected = false

    if type(self.onBegin) == "function" then
        local callbackOk, accepted, detail = SafeCall("rsui_layout_editor_begin", self.onBegin,
            self, kind, handle, CopyRect(startRect), constraints)
        if callbackOk ~= true or accepted == false then
            if type(captureSurface.StopMovingOrSizing) == "function" then pcall(function() captureSurface:StopMovingOrSizing() end) end
            if type(UI.EndNativeGeometryLease) == "function" then UI:EndNativeGeometryLease(captureSurface, self.owner) end
            tx:Cancel()
            self.active = false
            self.kind, self.handle = nil, nil
            self.captureSurface, self.transaction = nil, nil
            self.startPointerX, self.startPointerY = nil, nil
            self.frozenSnapOptions, self.activeConstraints = nil, nil
            self.frozenCandidateCount = 0
            self.lastError = tostring(detail or (callbackOk ~= true and accepted) or "layout_editor_begin_callback_rejected")
            return false, self.lastError
        end
    end

    local sampling = self:StartSampling()
    if sampling ~= true then
        if type(captureSurface.StopMovingOrSizing) == "function" then pcall(function() captureSurface:StopMovingOrSizing() end) end
        if type(UI.EndNativeGeometryLease) == "function" then UI:EndNativeGeometryLease(captureSurface, self.owner) end
        tx:Cancel()
        self.active = false
        self.kind, self.handle = nil, nil
        self.captureSurface, self.transaction = nil, nil
        self.startPointerX, self.startPointerY = nil, nil
        self.frozenSnapOptions, self.activeConstraints = nil, nil
        self.frozenCandidateCount = 0
        SafeCall("rsui_layout_editor_abort", self.onAbort, self, "sampling_unavailable")
        RSUI.metrics.layoutEditorGestureCaptureFailures = (tonumber(RSUI.metrics.layoutEditorGestureCaptureFailures) or 0) + 1
        return false, "layout_editor_sampling_unavailable"
    end
    RSUI.metrics.layoutEditorGestureBegins = (tonumber(RSUI.metrics.layoutEditorGestureBegins) or 0) + 1
    return true, nil
end

function GestureController:Finish(commit)
    if self.active ~= true then return false, "layout_editor_gesture_not_active" end
    -- Capture the final pointer position before releasing native movement. A
    -- strict preview rejection forces rollback on release; never commit a rect
    -- that the projection/persistence adapter already refused.
    self:Pulse(true)
    if self.previewRejected == true then commit = false end
    self:StopSampling()
    local surface = self.captureSurface
    if surface ~= nil and type(surface.StopMovingOrSizing) == "function" then
        pcall(function() surface:StopMovingOrSizing() end)
    end
    if surface ~= nil and type(UI.EndNativeGeometryLease) == "function" then UI:EndNativeGeometryLease(surface, self.owner) end

    local tx = self.transaction
    local result, err
    if commit == false then result, err = tx:Cancel() else result, err = tx:Commit() end
    result = CopyRect(result or self.startRect)

    self.active = false
    self.kind, self.handle = nil, nil
    self.captureSurface, self.transaction = nil, nil
    self.startPointerX, self.startPointerY = nil, nil
    self.lastDeltaX, self.lastDeltaY = nil, nil
    self.frozenSnapOptions, self.activeConstraints = nil, nil
    self.frozenCandidateCount = 0
    self.lastGuides = {}
    if self.guideOverlay ~= nil and type(self.guideOverlay.SetGuides) == "function" then self.guideOverlay:SetGuides({}) end
    if result ~= nil and self.overlay ~= nil and type(self.overlay.SetRect) == "function" then self.overlay:SetRect(result) end
    self.lastRect = result and CopyRect(result) or nil
    self.revision = (tonumber(self.revision) or 0) + 1

    if commit == false then
        RSUI.metrics.layoutEditorGestureCancels = (tonumber(RSUI.metrics.layoutEditorGestureCancels) or 0) + 1
        SafeCall("rsui_layout_editor_cancel", self.onCancel, result and CopyRect(result) or nil, self)
    else
        local callbackOk, accepted, detail = SafeCall("rsui_layout_editor_commit", self.onCommit,
            result and CopyRect(result) or nil, self)
        if self.commitMustSucceed == true and (callbackOk ~= true or accepted == false) then
            local rollback = CopyRect(self.startRect)
            if rollback ~= nil and self.overlay ~= nil and type(self.overlay.SetRect) == "function" then self.overlay:SetRect(rollback) end
            self.lastRect = rollback
            self.lastError = tostring(detail or (callbackOk ~= true and accepted) or "layout_editor_commit_callback_rejected")
            RSUI.metrics.layoutEditorGestureCommitRejects = (tonumber(RSUI.metrics.layoutEditorGestureCommitRejects) or 0) + 1
            return false, self.lastError
        end
        RSUI.metrics.layoutEditorGestureCommits = (tonumber(RSUI.metrics.layoutEditorGestureCommits) or 0) + 1
    end
    if err ~= nil then self.lastError = err; return false, err end
    return true, result
end

function GestureController:Commit()
    return self:Finish(true)
end

function GestureController:Cancel()
    return self:Finish(false)
end

function GestureController:SetEnabled(enabled)
    local desired = enabled == true
    if self.enabled == true and desired == false and self.active == true then self:Cancel() end
    if self.overlay ~= nil and type(self.overlay.SetInteractionPickable) == "function" then
        local pickOk, pickErr = self.overlay:SetInteractionPickable(desired)
        if pickOk ~= true then return self.enabled == true, false, tostring(pickErr or "layout_editor_pickable_state_failed") end
    end
    self.enabled = desired
    return self.enabled, true, nil
end

function GestureController:BindSurface(surface, kind, handle, label)
    if surface == nil then return false, "layout_editor_surface_required" end
    if type(UI.RequireHandler) ~= "function" then return false, "layout_editor_required_handler_contract_unavailable" end
    local startOk = UI:RequireHandler(surface, "OnDragStart", function()
        local ok = self:Begin(kind, handle, surface)
        return ok == true
    end, "rsui:" .. self.id .. ":" .. tostring(label) .. ":drag_start") == true
    local stopOk = UI:RequireHandler(surface, "OnDragStop", function()
        if self.active == true and self.captureSurface == surface then self:Commit() end
        return true
    end, "rsui:" .. self.id .. ":" .. tostring(label) .. ":drag_stop") == true
    if startOk ~= true or stopOk ~= true then
        ReleaseHandler(surface, "OnDragStart")
        ReleaseHandler(surface, "OnDragStop")
        return false, "layout_editor_surface_bind_failed:" .. tostring(label)
    end
    self.boundSurfaces[#self.boundSurfaces + 1] = surface
    return true, nil
end

function GestureController:BindOverlay()
    if type(self.overlay) ~= "table" or type(self.overlay.GetMoveNative) ~= "function"
        or type(self.overlay.GetHandleNative) ~= "function" then
        return false, "layout_editor_selection_overlay_required"
    end
    local ok, err = self:BindSurface(self.overlay:GetMoveNative(), "move", "move", "move")
    if ok ~= true then return false, err end
    for _, key in ipairs(HANDLE_KEYS) do
        ok, err = self:BindSurface(self.overlay:GetHandleNative(key), "resize", key, key)
        if ok ~= true then return false, err end
    end
    return true, nil
end

function GestureController:Release()
    if self.active == true then self:Cancel() else self:StopSampling() end
    for _, surface in ipairs(self.boundSurfaces or {}) do
        ReleaseHandler(surface, "OnDragStart")
        ReleaseHandler(surface, "OnDragStop")
        ReleaseHandler(surface, "OnUpdate")
    end
    self.boundSurfaces = {}
    if self.overlay ~= nil and type(self.overlay.SetInteractionPickable) == "function" then
        self.overlay:SetInteractionPickable(false)
    end
    self.released = true
    return true
end

function RSUI:CreateLayoutEditorGestureController(options)
    options = type(options) == "table" and options or {}
    local coordinateSpace = tostring(options.coordinateSpace or "")
    if type(options.pointerToLocal) ~= "function" and coordinateSpace ~= "viewport" then
        return nil, "layout_editor_coordinate_space_required"
    end
    local overlay = options.overlay
    if type(overlay) ~= "table" then return nil, "layout_editor_selection_overlay_required" end
    local controller = setmetatable({
        id = tostring(options.id or "layout_editor"),
        owner = tostring(options.owner or overlay.owner or ("rsui:layout_editor:" .. tostring(options.id or "layout_editor"))),
        overlay = overlay,
        guideOverlay = options.guideOverlay,
        getRect = options.getRect,
        getSnapOptions = options.getSnapOptions,
        getSnapCandidates = options.getSnapCandidates,
        getTransformConstraints = options.getTransformConstraints,
        snapOptions = options.snapOptions,
        pointerToLocal = options.pointerToLocal,
        coordinateSpace = coordinateSpace,
        onBegin = options.onBegin,
        onPreview = options.onPreview,
        onCommit = options.onCommit,
        onCancel = options.onCancel,
        onAbort = options.onAbort,
        canBegin = options.canBegin,
        previewMustSucceed = options.previewMustSucceed == true,
        commitMustSucceed = options.commitMustSucceed == true,
        previewRejected = false,
        minWidth = math.max(1, N(options.minWidth, 1)),
        minHeight = math.max(1, N(options.minHeight, 1)),
        maxWidth = tonumber(options.maxWidth),
        maxHeight = tonumber(options.maxHeight),
        enabled = options.enabled ~= false,
        active = false,
        boundSurfaces = {},
        revision = 0,
        frozenCandidateCount = 0,
        lastError = nil,
    }, GestureController)
    if controller.maxWidth ~= nil then controller.maxWidth = math.max(controller.minWidth, controller.maxWidth) end
    if controller.maxHeight ~= nil then controller.maxHeight = math.max(controller.minHeight, controller.maxHeight) end
    local ok, err = controller:BindOverlay()
    if ok ~= true then controller:Release(); return nil, err end
    controller:SetEnabled(controller.enabled)
    return controller, nil
end

RSUI.LayoutEditorGestureController = GestureController

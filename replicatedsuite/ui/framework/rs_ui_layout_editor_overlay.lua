------------------------------------------------------------------------
-- Replicated Suite - RSUI LayoutEditorOverlay v1
--
-- Canvas-side editor composition. This module does not invent any new input,
-- transform or persistence authority; it wires together the already-audited
-- foundations:
--
--   SelectionModel
--      -> LayoutEditorPreviewAdapter (single/multi transaction bridge)
--      -> SelectionOverlay + LayoutGuideOverlay (presentation)
--      -> LayoutEditorGestureController v2 (finite native capture)
--      -> AnchorPivot / MultiSelectionTransform / RectTransform / Snap resolver
--
-- Caller owns Feature projection and persistence through onPreview/onCommit/
-- onCancel. Source rects and pointer coordinates MUST share one declared editor
-- coordinate space; viewport<->local conversion is never guessed here.
--
-- Performance:
--   * no permanent Tick;
--   * no candidate scan when alignment snapping is disabled;
--   * candidate discovery is frozen once per gesture and hard-bounded upstream;
--   * selection refresh is event/explicit-call driven.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI = S.RSUI
local UI = S.UI
if type(RSUI) ~= "table" or type(UI) ~= "table" then return end

RSUI.LayoutEditorOverlayContractVersion = 1
RSUI.LayoutEditorOverlayHistoryBindingContractVersion = 1

local HARD_MAX_CANDIDATES = 1024

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
    if type(callback) ~= "function" then return true, nil, nil end
    local args, count = { ... }, select("#", ...)
    local ok, resultA, resultB = xpcall(function() return callback(unpack(args, 1, count)) end, S.SafeTraceback)
    if ok ~= true then
        if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Warn) == "function" then
            pcall(function()
                S.DiagnosticsManager:Warn("ui", "LAYOUT_EDITOR_OVERLAY_CALLBACK_FAILED",
                    "LayoutEditorOverlay 回调失败", { callback = tostring(label), error = tostring(resultA) })
            end)
        end
        return false, resultA, nil
    end
    return true, resultA, resultB
end

RSUI:RegisterTypeValidator("LayoutEditorOverlay", function(spec)
    if type(spec.selectionModel) ~= "table" or type(spec.selectionModel.GetSelectedKeys) ~= "function" then
        return false, "layout_editor_overlay_selection_model_required"
    end
    if type(spec.getRect) ~= "function" then return false, "layout_editor_overlay_get_rect_required" end
    if type(spec.canvasRect) ~= "table" and type(spec.getCanvasRect) ~= "function" then
        return false, "layout_editor_overlay_canvas_rect_required"
    end
    local coordinateSpace = tostring(spec.coordinateSpace or "")
    if type(spec.pointerToLocal) ~= "function" and coordinateSpace ~= "viewport" then
        return false, "layout_editor_overlay_coordinate_space_required"
    end
    return true
end)

RSUI:RegisterType("LayoutEditorOverlay", function(spec)
    local initialCanvas = CopyRect(spec.canvasRect)
    if initialCanvas == nil and type(spec.getCanvasRect) == "function" then
        local ok, value = SafeCall("get_canvas_rect", spec.getCanvasRect, spec)
        if ok == true then initialCanvas = CopyRect(value) end
    end
    if initialCanvas == nil then return nil, "layout_editor_overlay_canvas_rect_invalid" end

    local width = math.max(1, N(spec.width, initialCanvas.width))
    local height = math.max(1, N(spec.height, initialCanvas.height))
    local root = UI:CreateEmptyWidget(spec.parent, spec.id, N(spec.x, 0), N(spec.y, 0), width, height, false)
    if root == nil then return nil, "layout_editor_overlay_create_failed" end
    local c = RSUI:NewComponent("LayoutEditorOverlay", spec, root)
    c.selectionModel = spec.selectionModel
    c.canvasRect = initialCanvas
    c.getCanvasRect = spec.getCanvasRect
    c.getSnapCandidates = spec.getSnapCandidates
    c.onModeChanged = spec.onModeChanged
    c.onSelectionRefreshed = spec.onSelectionRefreshed
    c.onTransformCommitted = spec.onTransformCommitted
    c.enabled = spec.enabled ~= false
    c.selectionToken = "layout_editor_overlay:" .. tostring(spec.id)

    c.snapModel = spec.snapModel
    if c.snapModel == nil then
        local snap, snapErr = RSUI:CreateLayoutEditorSnapSettingsModel(type(spec.snapSettings) == "table" and spec.snapSettings or {})
        if snap == nil then c:Release(); return nil, snapErr end
        c.snapModel = snap
        c.ownsSnapModel = true
    end

    local adapter, adapterErr = RSUI:CreateLayoutEditorPreviewAdapter({
        id = spec.id .. ":adapter",
        selectionModel = c.selectionModel,
        getRect = spec.getRect,
        getParentRect = spec.getParentRect,
        getAnchorSpec = spec.getAnchorSpec,
        getItemConstraints = spec.getItemConstraints,
        canvasRect = c.canvasRect,
        maxSelected = spec.maxSelected,
        minWidth = spec.minWidth,
        minHeight = spec.minHeight,
        maxWidth = spec.maxWidth,
        maxHeight = spec.maxHeight,
        minChildWidth = spec.minChildWidth,
        minChildHeight = spec.minChildHeight,
        onPreview = spec.onPreview,
        onCommit = spec.onCommit,
        onCancel = spec.onCancel,
        -- Workspace-owned History is injected here so successful Adapter
        -- commits become the only edit-history write path. Preview/cancel never
        -- touch History, and the Overlay never owns a second command stack.
        historyModel = spec.historyModel,
    })
    if adapter == nil then c:Release(); return nil, adapterErr end
    c.adapter = adapter

    -- Guides are created before the selection overlay so resize handles remain
    -- the top-most editor hit targets inside this stable canvas host.
    c.guideOverlay = RSUI:LayoutGuideOverlay({
        id = spec.id .. "_guides", parent = c,
        x = 0, y = 0, width = width, height = height,
    })
    c.selectionOverlay = RSUI:SelectionOverlay({
        id = spec.id .. "_selection", parent = c,
        x = 0, y = 0, width = 1, height = 1,
        handleSize = spec.handleSize,
        handleHitSlop = spec.handleHitSlop,
        handlesPickable = c.enabled,
    })
    if c.guideOverlay == nil or c.selectionOverlay == nil then
        c:Release(); return nil, "layout_editor_overlay_visual_surface_failed"
    end
    c.selectionOverlay:SetVisible(false)

    local function ResolverOptions()
        return c.snapModel:ToResolverOptions({
            canvasRect = CopyRect(c.canvasRect),
            includeCanvas = true,
        })
    end

    local function BoundedCandidates(controller, kind, handle, startRect)
        if type(c.getSnapCandidates) ~= "function" then return {} end
        local ok, raw = SafeCall("snap_candidates", c.getSnapCandidates,
            c.adapter:GetSelectedKeys(), kind, handle, CopyRect(startRect), c)
        if ok ~= true or type(raw) ~= "table" then return {} end
        local snapshot = c.snapModel:GetSnapshot()
        local limit = math.max(1, math.min(math.floor(N(snapshot.maxCandidates, 256)), HARD_MAX_CANDIDATES))
        local selected = {}
        for _, key in ipairs(c.adapter:GetSelectedKeys()) do selected[tostring(key)] = true end
        local out, inspected = {}, 0
        for index, candidate in ipairs(raw) do
            if inspected >= limit then break end
            inspected = inspected + 1
            if type(candidate) == "table" then
                local key = tostring(candidate.key or index)
                if selected[key] ~= true then out[#out + 1] = candidate end
            end
        end
        RSUI.metrics.layoutEditorOverlayCandidateScans = (tonumber(RSUI.metrics.layoutEditorOverlayCandidateScans) or 0) + inspected
        return out
    end

    local gesture, gestureErr = RSUI:CreateLayoutEditorGestureController({
        id = spec.id .. ":gesture",
        owner = c.owner or ("rsui:layout_editor_overlay:" .. tostring(spec.id)),
        overlay = c.selectionOverlay,
        guideOverlay = c.guideOverlay,
        coordinateSpace = tostring(spec.coordinateSpace or ""),
        pointerToLocal = spec.pointerToLocal,
        getRect = function() return c.adapter:GetRect() end,
        getTransformConstraints = function(controller, kind, handle)
            return c.adapter:GetTransformConstraints(kind, handle)
        end,
        getSnapOptions = function() return ResolverOptions() end,
        getSnapCandidates = BoundedCandidates,
        canBegin = function()
            local allowed = c.adapter:CanBeginGesture()
            return allowed == true
        end,
        onBegin = function(controller, kind, handle)
            return c.adapter:BeginGesture(kind, handle)
        end,
        onPreview = function(rect, guides)
            return c.adapter:PreviewGesture(rect, guides)
        end,
        onCommit = function(rect)
            local ok, result = c.adapter:CommitGesture(rect)
            if ok == true then
                c:RefreshFromAdapter(false, "gesture_commit")
                SafeCall("transform_committed", c.onTransformCommitted, c.adapter:GetSnapshot(), c)
                return true
            end
            c:RefreshFromAdapter(false, "gesture_commit_rejected")
            return false, result
        end,
        onCancel = function()
            if c.adapter.activeGesture == true then c.adapter:CancelGesture("gesture_cancel") end
            c:RefreshFromAdapter(false, "gesture_cancel")
            return true
        end,
        onAbort = function(controller, reason)
            if c.adapter.activeGesture == true then c.adapter:CancelGesture(reason or "gesture_abort") end
            c:RefreshFromAdapter(false, "gesture_abort")
            return true
        end,
        previewMustSucceed = true,
        commitMustSucceed = true,
        minWidth = spec.minWidth,
        minHeight = spec.minHeight,
        maxWidth = spec.maxWidth,
        maxHeight = spec.maxHeight,
        enabled = c.enabled,
    })
    if gesture == nil then c:Release(); return nil, gestureErr end
    c.gesture = gesture

    function c:GetAdapter() return self.adapter end
    function c:GetSnapModel() return self.snapModel end
    function c:GetGestureController() return self.gesture end
    function c:GetSelectionOverlay() return self.selectionOverlay end
    function c:GetCanvasRect() return CopyRect(self.canvasRect) end

    function c:SetCanvasRect(rect, preserveSingleVisual)
        rect = CopyRect(rect)
        if rect == nil then return false, "layout_editor_overlay_canvas_rect_invalid" end
        self.canvasRect = rect
        self.adapter.canvasRect = CopyRect(rect)
        local anchorModel = self.adapter:GetAnchorModel()
        if anchorModel ~= nil and spec.getParentRect == nil and spec.getAnchorSpec == nil
            and type(anchorModel.SetParentRect) == "function" then
            anchorModel:SetParentRect(rect, preserveSingleVisual ~= false, "editor_canvas_rect")
            local key = self.adapter.keys and self.adapter.keys[1]
            if key ~= nil then self.adapter.workingRects[key] = anchorModel:GetRect() end
        end
        self.revision = (tonumber(self.revision) or 0) + 1
        return true, nil
    end

    function c:RefreshCanvasRect(preserveSingleVisual)
        if type(self.getCanvasRect) ~= "function" then return true, nil end
        local ok, value = SafeCall("refresh_canvas_rect", self.getCanvasRect, self)
        if ok ~= true then return false, "layout_editor_overlay_canvas_rect_callback_failed" end
        return self:SetCanvasRect(value, preserveSingleVisual)
    end

    function c:_FailClosedProjection(reason, source)
        self.lastError = tostring(reason or "layout_editor_overlay_projection_unavailable")
        if self.selectionOverlay ~= nil then
            self.selectionOverlay:SetVisible(false)
            self.selectionOverlay:SetInteractionPickable(false)
        end
        if self.guideOverlay ~= nil then self.guideOverlay:SetGuides({}) end
        SafeCall("mode_changed", self.onModeChanged, "none", 0, nil, self.adapter, self)
        SafeCall("selection_refreshed", self.onSelectionRefreshed,
            self.adapter and self.adapter:GetSnapshot() or nil, tostring(source or "projection_failed"), self)
        return false, self.lastError
    end

    function c:RefreshFromAdapter(syncSource, source)
        if self.gesture ~= nil and self.gesture.active == true and syncSource == true then
            return false, "layout_editor_overlay_gesture_active"
        end
        if syncSource == true then
            local canvasOk, canvasErr = self:RefreshCanvasRect(true)
            if canvasOk ~= true then return self:_FailClosedProjection(canvasErr, source or "canvas_refresh_failed") end
            local syncOk, syncErr = self.adapter:SyncSelection(source or "refresh_source")
            if syncOk ~= true then return self:_FailClosedProjection(syncErr, source or "selection_sync_failed") end
        end
        local rect = self.adapter:GetRect()
        local mode = self.adapter:GetMode()
        if rect == nil or mode == "none" then
            self.selectionOverlay:SetVisible(false)
            local pickOk, pickErr = self.selectionOverlay:SetInteractionPickable(false)
            if pickOk ~= true then return self:_FailClosedProjection(pickErr, source or "selection_disable_failed") end
            self.guideOverlay:SetGuides({})
        else
            self.selectionOverlay:SetRect(rect)
            self.selectionOverlay:SetVisible(true)
            local pickOk, pickErr = self.selectionOverlay:SetInteractionPickable(self.enabled)
            if pickOk ~= true then return self:_FailClosedProjection(pickErr, source or "selection_enable_failed") end
        end
        self.lastError = nil
        self.revision = (tonumber(self.revision) or 0) + 1
        RSUI.metrics.layoutEditorOverlayRefreshes = (tonumber(RSUI.metrics.layoutEditorOverlayRefreshes) or 0) + 1
        SafeCall("mode_changed", self.onModeChanged, mode, self.adapter:GetSelectionCount(), self.adapter:GetAnchorModel(), self.adapter, self)
        SafeCall("selection_refreshed", self.onSelectionRefreshed, self.adapter:GetSnapshot(), source or "refresh", self)
        return true, nil
    end

    function c:RefreshFromSource(source)
        return self:RefreshFromAdapter(true, source or "source")
    end

    function c:SetEnabled(enabled)
        local desired = enabled == true
        if self.gesture ~= nil then
            local _, gestureOk, gestureErr = self.gesture:SetEnabled(desired)
            if gestureOk ~= true then return self.enabled == true, false, tostring(gestureErr or "layout_editor_gesture_enable_failed") end
        elseif self.selectionOverlay ~= nil then
            local pickOk, pickErr = self.selectionOverlay:SetInteractionPickable(desired and self.adapter:GetMode() ~= "none")
            if pickOk ~= true then return self.enabled == true, false, tostring(pickErr or "layout_editor_selection_enable_failed") end
        end
        self.enabled = desired
        return self.enabled, true, nil
    end

    function c:Layout(x, y, nextWidth, nextHeight)
        local nextX, nextY = N(x, 0), N(y, 0)
        local nextW, nextH = math.max(1, N(nextWidth, width)), math.max(1, N(nextHeight, height))
        UI:SetAnchor(self.root, spec.parent, nextX, nextY, self.owner)
        UI:SetExtent(self.root, nextW, nextH, self.owner)
        self.guideOverlay:Layout(0, 0, nextW, nextH)
        self:CommitLayoutState(nextX, nextY, nextW, nextH)
        return nextH
    end

    function c:GetSnapshot()
        return {
            contractVersion = tonumber(RSUI.LayoutEditorOverlayContractVersion) or 0,
            enabled = self.enabled == true,
            revision = tonumber(self.revision) or 0,
            canvasRect = self:GetCanvasRect(),
            adapter = self.adapter and self.adapter:GetSnapshot() or nil,
            snap = self.snapModel and self.snapModel:GetSnapshot() or nil,
            gesture = self.gesture and self.gesture:GetSnapshot() or nil,
            lastError = self.lastError,
        }
    end

    local BaseRelease = c.Release
    function c:Release()
        if self.released == true then return false end
        if self.selectionModel ~= nil and type(self.selectionModel.Unsubscribe) == "function" then
            self.selectionModel:Unsubscribe(self.selectionToken)
        end
        if self.gesture ~= nil then self.gesture:Release() end
        if self.adapter ~= nil then self.adapter:Release() end
        return BaseRelease(self)
    end

    if type(c.selectionModel.Subscribe) == "function" then
        c.selectionModel:Subscribe(c.selectionToken, function()
            if c.gesture ~= nil and c.gesture.active == true then c.gesture:Cancel() end
            c:RefreshFromSource("selection_changed")
        end)
    end
    c:SetEnabled(c.enabled)
    local refreshOk, refreshErr = c:RefreshFromAdapter(false, "create")
    if refreshOk ~= true then c:Release(); return nil, refreshErr end
    RSUI.metrics.layoutEditorOverlaysCreated = (tonumber(RSUI.metrics.layoutEditorOverlaysCreated) or 0) + 1
    return c
end)

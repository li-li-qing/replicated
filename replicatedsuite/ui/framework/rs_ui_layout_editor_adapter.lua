------------------------------------------------------------------------
-- Replicated Suite - RSUI Layout Editor Preview Adapter v1
--
-- Coordinator/model bridge between stable-key SelectionModel and the editor
-- transform foundations.  It deliberately owns NO Feature Store persistence:
-- callers provide onPreview/onCommit/onCancel adapters for their own projection
-- and persistence boundaries.
--
-- Responsibilities:
--   * keep one working rect projection for the current selection;
--   * single selection -> AnchorPivotModel;
--   * multi selection  -> MultiSelectionTransformModel + projection session;
--   * expose one rect-model interface to TransformInspector;
--   * reject selection-revision changes during an active gesture;
--   * Preview is reversible; external Commit must accept before local session
--     state is finalized.
--
-- Coordinate contract:
--   all rects supplied to this adapter MUST already share one declared editor
--   coordinate space. It does not guess viewport<->canvas conversion.
--
-- Performance contract:
--   no Tick / polling; O(selected) only on explicit Sync/Preview/Commit.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI = S.RSUI
if type(RSUI) ~= "table" then return end

RSUI.LayoutEditorPreviewAdapterContractVersion = 1

local HARD_MAX_SELECTED = 512

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

local function CopyItems(items)
    local out = {}
    for index, item in ipairs(type(items) == "table" and items or {}) do
        local rect = CopyRect(item.rect)
        if rect == nil then return nil, "layout_editor_adapter_item_rect_invalid:" .. tostring(index) end
        out[#out + 1] = { key = tostring(item.key or ""), rect = rect }
    end
    return out
end

local function BoundsOfItems(items)
    local left, top, right, bottom = nil, nil, nil, nil
    for _, item in ipairs(type(items) == "table" and items or {}) do
        local rect = CopyRect(item.rect)
        if rect == nil then return nil end
        left = left == nil and rect.x or math.min(left, rect.x)
        top = top == nil and rect.y or math.min(top, rect.y)
        right = right == nil and (rect.x + rect.width) or math.max(right, rect.x + rect.width)
        bottom = bottom == nil and (rect.y + rect.height) or math.max(bottom, rect.y + rect.height)
    end
    if left == nil or right <= left or bottom <= top then return nil end
    return { x = left, y = top, width = right - left, height = bottom - top }
end

local function SameKeySet(items, keys)
    if #(type(items) == "table" and items or {}) ~= #(type(keys) == "table" and keys or {}) then return false end
    local wanted = {}
    for _, key in ipairs(keys or {}) do wanted[tostring(key)] = true end
    for _, item in ipairs(items or {}) do
        local key = tostring(item.key or "")
        if key == "" or wanted[key] ~= true then return false end
        wanted[key] = nil
    end
    for _, remains in pairs(wanted) do if remains == true then return false end end
    return true
end

local function HistoryStateOf(state, items)
    if type(state) == "table" and type(state.anchor) == "table" then
        local anchor = state.anchor
        local parentRect, rect = CopyRect(anchor.parentRect), CopyRect(anchor.rect)
        local anchorX, anchorY = tonumber(anchor.anchorX), tonumber(anchor.anchorY)
        local pivotX, pivotY = tonumber(anchor.pivotX), tonumber(anchor.pivotY)
        if parentRect ~= nil and rect ~= nil and anchorX ~= nil and anchorY ~= nil and pivotX ~= nil and pivotY ~= nil then
            return {
                anchor = { parentRect = parentRect, rect = rect, anchorX = anchorX, anchorY = anchorY, pivotX = pivotX, pivotY = pivotY },
            }
        end
    end
    local groupRect = type(state) == "table" and CopyRect(state.groupRect) or nil
    if groupRect == nil then groupRect = BoundsOfItems(items) end
    return groupRect ~= nil and { groupRect = groupRect } or nil
end

local function SafeCall(label, callback, ...)
    if type(callback) ~= "function" then return true, nil, nil end
    local args, count = { ... }, select("#", ...)
    local ok, resultA, resultB = xpcall(function()
        return callback(unpack(args, 1, count))
    end, S.SafeTraceback)
    if ok ~= true then
        if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Warn) == "function" then
            pcall(function()
                S.DiagnosticsManager:Warn("ui", "LAYOUT_EDITOR_ADAPTER_CALLBACK_FAILED",
                    "Layout Editor Adapter 回调失败", { callback = tostring(label), error = tostring(resultA) })
            end)
        end
        return false, resultA, nil
    end
    return true, resultA, resultB
end

local function SelectionRevision(selectionModel)
    if type(selectionModel) == "table" and type(selectionModel.GetSnapshot) == "function" then
        local snapshot = selectionModel:GetSnapshot()
        return tonumber(snapshot and snapshot.revision) or 0
    end
    return tonumber(selectionModel and selectionModel.revision) or 0
end

local Adapter = {}
Adapter.__index = Adapter

function Adapter:_ReadSourceRect(key)
    local ok, raw = SafeCall("get_rect", self.getRect, key, self)
    if ok ~= true then return nil, "layout_editor_adapter_get_rect_failed:" .. tostring(key) end
    local rect = CopyRect(raw)
    if rect == nil then return nil, "layout_editor_adapter_rect_invalid:" .. tostring(key) end
    return rect, nil
end

function Adapter:_ReadParentRect(key, rect)
    local raw = nil
    if type(self.getAnchorSpec) == "function" then
        local ok, spec = SafeCall("get_anchor_spec", self.getAnchorSpec, key, CopyRect(rect), self)
        if ok ~= true then return nil, nil, "layout_editor_adapter_anchor_spec_failed:" .. tostring(key) end
        if type(spec) == "table" then
            local parentRect = CopyRect(spec.parentRect)
            if parentRect == nil then return nil, nil, "layout_editor_adapter_parent_rect_invalid:" .. tostring(key) end
            return parentRect, spec, nil
        end
    end
    if type(self.getParentRect) == "function" then
        local ok, parent = SafeCall("get_parent_rect", self.getParentRect, key, self)
        if ok ~= true then return nil, nil, "layout_editor_adapter_parent_rect_failed:" .. tostring(key) end
        local parentRect = CopyRect(parent)
        if parentRect == nil then return nil, nil, "layout_editor_adapter_parent_rect_invalid:" .. tostring(key) end
        return parentRect, nil, nil
    end
    if type(self.canvasRect) == "table" then
        local parentRect = CopyRect(self.canvasRect)
        if parentRect ~= nil then return parentRect, nil, nil end
    end
    return nil, nil, "layout_editor_adapter_parent_rect_required"
end

function Adapter:_EmitPreview(items, source, guides, metadata)
    local copied, err = CopyItems(items)
    if copied == nil then return false, err end
    local ok, accepted, detail = SafeCall("preview", self.onPreview, copied, {
        source = tostring(source or "preview"),
        guides = type(guides) == "table" and guides or {},
        mode = self.mode,
        selectionRevision = self.syncedSelectionRevision,
        metadata = metadata,
    }, self)
    if ok ~= true then return false, "layout_editor_adapter_preview_callback_failed" end
    if accepted == false then return false, tostring(detail or "layout_editor_adapter_preview_rejected") end
    RSUI.metrics.layoutEditorAdapterPreviews = (tonumber(RSUI.metrics.layoutEditorAdapterPreviews) or 0) + 1
    return true, nil
end

function Adapter:_EmitCommit(items, source, metadata)
    local copied, err = CopyItems(items)
    if copied == nil then return false, err end
    local ok, accepted, detail = SafeCall("commit", self.onCommit, copied, {
        source = tostring(source or "commit"),
        mode = self.mode,
        selectionRevision = self.syncedSelectionRevision,
        metadata = metadata,
    }, self)
    if ok ~= true then return false, "layout_editor_adapter_commit_callback_failed" end
    if accepted == false then return false, tostring(detail or "layout_editor_adapter_commit_rejected") end
    RSUI.metrics.layoutEditorAdapterCommits = (tonumber(RSUI.metrics.layoutEditorAdapterCommits) or 0) + 1
    return true, nil
end

function Adapter:_EmitCancel(items, source)
    local copied = CopyItems(items)
    SafeCall("cancel", self.onCancel, copied or {}, {
        source = tostring(source or "cancel"),
        mode = self.mode,
        selectionRevision = self.syncedSelectionRevision,
    }, self)
    RSUI.metrics.layoutEditorAdapterCancels = (tonumber(RSUI.metrics.layoutEditorAdapterCancels) or 0) + 1
    return true
end

function Adapter:_RecordHistory(beforeItems, afterItems, source, beforeState, afterState)
    local history = self.historyModel
    if type(history) ~= "table" or type(history.Record) ~= "function" then return true, nil end
    local recorded, detail = history:Record({
        source = tostring(source or "commit"),
        selectionRevision = self.syncedSelectionRevision,
        beforeItems = beforeItems, afterItems = afterItems,
        beforeState = HistoryStateOf(beforeState, beforeItems),
        afterState = HistoryStateOf(afterState, afterItems),
    })
    if recorded == false and detail ~= "layout_edit_history_noop" then
        self.lastError = tostring(detail or "layout_editor_adapter_history_record_failed")
        if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Warn) == "function" then
            pcall(function()
                S.DiagnosticsManager:Warn("ui", "LAYOUT_EDIT_HISTORY_RECORD_FAILED",
                    "Layout Edit History 记录失败", { adapter = tostring(self.id), error = tostring(self.lastError) })
            end)
        end
    end
    return true, detail
end

function Adapter:GetHistoryModel()
    return self.historyModel
end

function Adapter:SetHistoryModel(model, ownsModel)
    if model ~= nil and (type(model) ~= "table" or type(model.Record) ~= "function"
        or type(model.Undo) ~= "function" or type(model.Redo) ~= "function"
        or type(model.SetApplyCallbacks) ~= "function") then
        return false, "layout_editor_adapter_history_model_invalid"
    end

    -- Stage callback attachment before detaching the previous model so a bad
    -- external History implementation cannot leave the adapter half-switched.
    if model ~= nil then
        local ok, err = model:SetApplyCallbacks(
            function(items, context) return self:ApplyHistoryState(items, context) end,
            function(items, context) return self:ApplyHistoryState(items, context) end)
        if ok ~= true then return false, err end
    end

    local previous, previousOwned = self.historyModel, self.ownsHistoryModel == true
    if previous ~= nil and previous ~= model then
        if previousOwned and type(previous.Release) == "function" then
            previous:Release()
        elseif type(previous.SetApplyCallbacks) == "function" then
            previous:SetApplyCallbacks(nil, nil)
        end
    end
    self.historyModel = model
    self.ownsHistoryModel = ownsModel == true
    return true, nil
end

function Adapter:EnableHistory(options)
    if type(RSUI.CreateLayoutEditHistoryModel) ~= "function"
        or (tonumber(RSUI.LayoutEditHistoryContractVersion) or 0) < 1 then
        return nil, "layout_editor_adapter_history_foundation_missing"
    end
    options = type(options) == "table" and options or {}
    local history, err = RSUI:CreateLayoutEditHistoryModel({
        id = tostring(options.id or (self.id .. ":history")),
        maxCommands = options.maxCommands,
        maxItems = options.maxItems or self.maxSelected,
    })
    if history == nil then return nil, err end
    local attached, attachErr = self:SetHistoryModel(history, true)
    if attached ~= true then history:Release(); return nil, attachErr end
    return history, nil
end

function Adapter:_ApplyHistoryLocal(items, state, source)
    if SameKeySet(items, self.keys) ~= true then return true, nil end
    if self.mode == "single" and self.anchorModel ~= nil then
        local target = items[1]
        if tostring(target.key) ~= tostring(self.keys[1]) then
            for _, item in ipairs(items) do if tostring(item.key) == tostring(self.keys[1]) then target = item break end end
        end
        local ok, err
        if type(state) == "table" and type(state.anchor) == "table"
            and type(self.anchorModel.ApplySnapshot) == "function" then
            ok, err = self.anchorModel:ApplySnapshot(state.anchor, source or "history_replay")
        else
            ok, err = self.anchorModel:SetRect(target.rect, source or "history_replay")
        end
        if ok ~= true then return false, err end
    elseif self.mode == "multi" and self.multiModel ~= nil then
        local ok, err = self.multiModel:SetItems(items, source or "history_replay")
        if ok ~= true then return false, err end
    end
    local setOk, setErr = self:_SetWorking(items)
    if setOk ~= true then return false, setErr end
    local resolved, geometryErr = self.geometryModel:Resolve()
    if resolved ~= true and self.mode ~= "none" then return false, geometryErr end
    self.revision = (tonumber(self.revision) or 0) + 1
    return true, nil
end

function Adapter:ApplyHistoryState(items, context)
    if self.activeGesture == true then return false, "layout_editor_adapter_gesture_active" end
    local copied, copyErr = CopyItems(items)
    if copied == nil then return false, copyErr end
    context = type(context) == "table" and context or {}
    local state = type(context.state) == "table" and context.state or nil
    local metadata = {}
    if type(state) == "table" then for key, value in pairs(state) do metadata[key] = value end end
    metadata.history = {
        replay = true, rollback = context.rollback == true, direction = tostring(context.direction or "history"),
        command = context.command,
    }
    local source = context.rollback == true and "history_rollback" or ("history_" .. tostring(context.direction or "apply"))
    local committed, commitErr = self:_EmitCommit(copied, source, metadata)
    if committed ~= true then return false, commitErr end
    local localOk, localErr = self:_ApplyHistoryLocal(copied, state, source)
    if localOk ~= true then return false, localErr end
    self.lastError = nil
    return true, nil
end

function Adapter:_ItemsFromWorking(keys)
    local items = {}
    for _, key in ipairs(keys or self.keys or {}) do
        local rect = CopyRect(self.workingRects[key])
        if rect == nil then return nil, "layout_editor_adapter_working_rect_missing:" .. tostring(key) end
        items[#items + 1] = { key = key, rect = rect }
    end
    return items, nil
end

function Adapter:_SetWorking(items)
    local nextRects = {}
    for _, item in ipairs(type(items) == "table" and items or {}) do
        local rect = CopyRect(item.rect)
        if rect == nil then return false, "layout_editor_adapter_working_rect_invalid:" .. tostring(item.key) end
        nextRects[tostring(item.key)] = rect
    end
    self.workingRects = nextRects
    return true, nil
end

function Adapter:GetWorkingRect(key)
    key = tostring(key or "")
    return CopyRect(self.workingRects[key])
end

function Adapter:GetMode()
    return self.mode or "none"
end

function Adapter:GetSelectionCount()
    return #(self.keys or {})
end

function Adapter:GetSelectedKeys()
    local out = {}
    for index, key in ipairs(self.keys or {}) do out[index] = key end
    return out
end

function Adapter:GetAnchorModel()
    return self.mode == "single" and self.anchorModel or nil
end

function Adapter:GetRect()
    if self.mode == "single" and self.anchorModel ~= nil then return self.anchorModel:GetRect() end
    if self.mode == "multi" and self.multiModel ~= nil then return self.multiModel:GetBounds() end
    return nil
end

function Adapter:GetSnapshot()
    return {
        id = self.id,
        contractVersion = tonumber(RSUI.LayoutEditorPreviewAdapterContractVersion) or 0,
        revision = tonumber(self.revision) or 0,
        mode = self:GetMode(),
        count = self:GetSelectionCount(),
        keys = self:GetSelectedKeys(),
        selectionRevision = self.syncedSelectionRevision,
        activeGesture = self.activeGesture == true,
        anchor = self.anchorModel and self.anchorModel:GetSnapshot() or nil,
        multi = self.multiModel and self.multiModel:GetSnapshot() or nil,
        geometry = self.geometryModel and self.geometryModel:GetSnapshot() or nil,
        lastError = self.lastError,
    }
end

function Adapter:SyncSelection(source)
    if self.activeGesture == true then return false, "layout_editor_adapter_gesture_active" end
    local selection = self.selectionModel
    if type(selection) ~= "table" or type(selection.GetSelectedKeys) ~= "function"
        or type(selection.GetPrimaryKey) ~= "function" then
        return false, "layout_editor_adapter_selection_model_required"
    end
    local rawKeys = selection:GetSelectedKeys()
    if type(rawKeys) ~= "table" then return false, "layout_editor_adapter_selection_keys_invalid" end
    if #rawKeys > self.maxSelected then return false, "layout_editor_adapter_max_selected_exceeded" end

    -- Stage the complete next selection state first. Nothing on the live
    -- adapter changes until every rect and the mode-specific model validates.
    local nextKeys, nextWorking = {}, {}
    for index, rawKey in ipairs(rawKeys) do
        local key = tostring(rawKey)
        if key == "" then return false, "layout_editor_adapter_selection_key_invalid:" .. tostring(index) end
        local rect, err = self:_ReadSourceRect(key)
        if rect == nil then self.lastError = err; return false, err end
        nextKeys[index] = key
        nextWorking[key] = rect
    end

    local nextMode = #nextKeys == 0 and "none" or (#nextKeys == 1 and "single" or "multi")
    local nextAnchorModel, nextMultiModel = nil, nil
    if nextMode == "single" then
        local key = nextKeys[1]
        local rect = nextWorking[key]
        local parentRect, anchorSpec, parentErr = self:_ReadParentRect(key, rect)
        if parentRect == nil then self.lastError = parentErr; return false, parentErr end
        anchorSpec = type(anchorSpec) == "table" and anchorSpec or {}
        local model, modelErr = RSUI:CreateAnchorPivotModel({
            id = self.id .. ":anchor:" .. key,
            parentRect = parentRect,
            rect = rect,
            anchorX = anchorSpec.anchorX,
            anchorY = anchorSpec.anchorY,
            pivotX = anchorSpec.pivotX,
            pivotY = anchorSpec.pivotY,
        })
        if model == nil then self.lastError = modelErr; return false, modelErr end
        nextAnchorModel = model
    elseif nextMode == "multi" then
        local items = {}
        for _, key in ipairs(nextKeys) do
            items[#items + 1] = { key = key, rect = CopyRect(nextWorking[key]) }
        end
        local model, modelErr = RSUI:CreateMultiSelectionTransformModel({
            id = self.id .. ":multi",
            items = items,
            maxItems = self.maxSelected,
            minChildWidth = self.minChildWidth,
            minChildHeight = self.minChildHeight,
        })
        if model == nil then self.lastError = modelErr; return false, modelErr end
        nextMultiModel = model
    end

    -- Atomic live-state commit. SelectionGeometry resolves only from the staged
    -- working rects after this point, so a failed model build above cannot leave
    -- a half-switched adapter.
    self.keys = nextKeys
    self.workingRects = nextWorking
    self.syncedSelectionRevision = SelectionRevision(selection)
    self.anchorModel = nextAnchorModel
    self.multiModel = nextMultiModel
    self.multiSession = nil
    self.mode = nextMode

    local resolved, geometryErr = self.geometryModel:Resolve()
    if resolved ~= true and self.mode ~= "none" then
        -- This should be unreachable after the staged rect validation above;
        -- fail closed and prevent gestures rather than expose partial geometry.
        self.mode = "none"
        self.anchorModel, self.multiModel, self.multiSession = nil, nil, nil
        self.lastError = geometryErr
        return false, geometryErr
    end
    self.revision = (tonumber(self.revision) or 0) + 1
    self.lastSource = tostring(source or "sync")
    self.lastError = nil
    RSUI.metrics.layoutEditorAdapterSyncs = (tonumber(RSUI.metrics.layoutEditorAdapterSyncs) or 0) + 1
    return true, nil
end

function Adapter:GetTransformConstraints(kind, handle)
    local constraints = { minWidth = self.minWidth, minHeight = self.minHeight, maxWidth = self.maxWidth, maxHeight = self.maxHeight }
    if self.mode == "multi" and self.multiModel ~= nil then
        local resolved, err = self.multiModel:GetGroupConstraints({
            minChildWidth = self.minChildWidth,
            minChildHeight = self.minChildHeight,
        })
        if resolved == nil then return nil, err end
        constraints.minWidth = math.max(constraints.minWidth, N(resolved.minWidth, constraints.minWidth))
        constraints.minHeight = math.max(constraints.minHeight, N(resolved.minHeight, constraints.minHeight))
    elseif self.mode == "single" and type(self.getItemConstraints) == "function" then
        local ok, patch = SafeCall("item_constraints", self.getItemConstraints, self.keys[1], kind, handle, self)
        if ok ~= true then return nil, "layout_editor_adapter_item_constraints_failed" end
        if type(patch) == "table" then
            if tonumber(patch.minWidth) ~= nil then constraints.minWidth = math.max(constraints.minWidth, tonumber(patch.minWidth)) end
            if tonumber(patch.minHeight) ~= nil then constraints.minHeight = math.max(constraints.minHeight, tonumber(patch.minHeight)) end
            if tonumber(patch.maxWidth) ~= nil then constraints.maxWidth = tonumber(patch.maxWidth) end
            if tonumber(patch.maxHeight) ~= nil then constraints.maxHeight = tonumber(patch.maxHeight) end
        end
    end
    return constraints, nil
end

function Adapter:CanBeginGesture()
    if self.mode == "none" then return false, "layout_editor_adapter_empty_selection" end
    if self.activeGesture == true then return false, "layout_editor_adapter_gesture_active" end
    if SelectionRevision(self.selectionModel) ~= self.syncedSelectionRevision then
        return false, "layout_editor_adapter_selection_revision_changed"
    end
    return true, nil
end

function Adapter:BeginGesture(kind, handle)
    local allowed, err = self:CanBeginGesture()
    if allowed ~= true then self.lastError = err; return false, err end
    local startItems, startItemsErr = self:_ItemsFromWorking(self.keys)
    if startItems == nil then self.lastError = startItemsErr; return false, startItemsErr end
    self.activeGesture = true
    self.gestureStartItems = startItems
    self.gestureStartRect = self:GetRect()
    if self.mode == "single" and self.anchorModel ~= nil then
        self.gestureStartState = { anchor = self.anchorModel:GetSnapshot() }
    else
        self.gestureStartState = { groupRect = BoundsOfItems(startItems) }
    end
    if self.mode == "multi" then
        local session, sessionErr = self.multiModel:BeginProjectionSession({
            minChildWidth = self.minChildWidth,
            minChildHeight = self.minChildHeight,
        })
        if session == nil then
            self.activeGesture = false
            self.gestureStartItems = nil
            self.gestureStartRect = nil
            self.gestureStartState = nil
            self.lastError = sessionErr
            return false, sessionErr
        end
        self.multiSession = session
    end
    self.lastError = nil
    RSUI.metrics.layoutEditorAdapterGestureBegins = (tonumber(RSUI.metrics.layoutEditorAdapterGestureBegins) or 0) + 1
    return true, nil
end

function Adapter:PreviewGesture(rect, guides)
    if self.activeGesture ~= true then return false, "layout_editor_adapter_gesture_not_active" end
    if SelectionRevision(self.selectionModel) ~= self.syncedSelectionRevision then
        self.lastError = "layout_editor_adapter_selection_revision_changed"
        return false, self.lastError
    end
    rect = CopyRect(rect)
    if rect == nil then return false, "layout_editor_adapter_preview_rect_invalid" end
    local items, metadata
    if self.mode == "single" then
        local ok, err = self.anchorModel:SetRect(rect, "gesture_preview")
        if ok ~= true then return false, err end
        items = { { key = self.keys[1], rect = self.anchorModel:GetRect() } }
        metadata = { anchor = self.anchorModel:GetSnapshot() }
    elseif self.mode == "multi" then
        items = self.multiSession and self.multiSession:Project(rect) or nil
        if items == nil then return false, "layout_editor_adapter_multi_preview_failed" end
        metadata = { groupRect = CopyRect(rect), multi = self.multiSession:GetSnapshot() }
    else
        return false, "layout_editor_adapter_empty_selection"
    end
    local setOk, setErr = self:_SetWorking(items)
    if setOk ~= true then return false, setErr end
    return self:_EmitPreview(items, "gesture_preview", guides, metadata)
end

function Adapter:CommitGesture(rect)
    if self.activeGesture ~= true then return false, "layout_editor_adapter_gesture_not_active" end
    if SelectionRevision(self.selectionModel) ~= self.syncedSelectionRevision then
        self:CancelGesture("selection_revision_changed")
        return false, "layout_editor_adapter_selection_revision_changed"
    end
    rect = CopyRect(rect or self:GetRect())
    if rect == nil then self:CancelGesture("invalid_commit_rect"); return false, "layout_editor_adapter_commit_rect_invalid" end
    local startItems = self.gestureStartItems or {}
    local items, metadata
    if self.mode == "single" then
        local ok, err = self.anchorModel:SetRect(rect, "gesture_commit")
        if ok ~= true then self:CancelGesture("single_commit_invalid"); return false, err end
        items = { { key = self.keys[1], rect = self.anchorModel:GetRect() } }
        metadata = { anchor = self.anchorModel:GetSnapshot() }
    else
        local projected, projectErr = nil, nil
        if self.multiSession ~= nil then projected, projectErr = self.multiSession:Project(rect) end
        if projected == nil then self:CancelGesture("multi_commit_projection_failed"); return false, projectErr or "layout_editor_adapter_multi_commit_failed" end
        local committed, sessionErr = self.multiSession:Commit(rect, "layout_editor_adapter")
        if committed == nil then
            self:CancelGesture("multi_session_commit_failed")
            return false, sessionErr
        end
        items = committed
        metadata = { groupRect = CopyRect(rect), multi = self.multiModel:GetSnapshot() }
    end

    local accepted, acceptErr = self:_EmitCommit(items, "gesture_commit", metadata)
    if accepted ~= true then
        if self.mode == "multi" and self.multiModel ~= nil then
            self.multiModel:SetItems(startItems, "gesture_commit_rollback")
            self.multiSession = nil
            self.activeGesture = true
        end
        self:CancelGesture("commit_rejected")
        return false, acceptErr
    end
    self:_SetWorking(items)
    self:_RecordHistory(startItems, items, "gesture_commit", self.gestureStartState, metadata)
    self.activeGesture = false
    self.multiSession = nil
    self.gestureStartItems, self.gestureStartRect, self.gestureStartState = nil, nil, nil
    self.revision = (tonumber(self.revision) or 0) + 1
    self.lastError = nil
    return true, items
end

function Adapter:CancelGesture(source)
    if self.activeGesture ~= true then return false, "layout_editor_adapter_gesture_not_active" end
    local startItems = self.gestureStartItems or {}
    if self.mode == "multi" and self.multiSession ~= nil then self.multiSession:Cancel() end
    if self.mode == "single" and self.anchorModel ~= nil and self.gestureStartRect ~= nil then
        self.anchorModel:SetRect(self.gestureStartRect, "gesture_cancel")
    end
    self:_SetWorking(startItems)
    self:_EmitCancel(startItems, source or "gesture_cancel")
    self.activeGesture = false
    self.multiSession = nil
    self.gestureStartItems, self.gestureStartRect, self.gestureStartState = nil, nil, nil
    self.revision = (tonumber(self.revision) or 0) + 1
    self.lastError = nil
    return true, startItems
end

-- Rect-model interface consumed by TransformInspector. An explicit inspector
-- edit is a short transaction: preview -> external commit -> local finalize.
function Adapter:SetRect(rect, source)
    if self.activeGesture == true then return false, "layout_editor_adapter_gesture_active" end
    rect = CopyRect(rect)
    if rect == nil then return false, "layout_editor_adapter_rect_invalid" end
    if self.mode == "none" then return false, "layout_editor_adapter_empty_selection" end
    if SelectionRevision(self.selectionModel) ~= self.syncedSelectionRevision then
        return false, "layout_editor_adapter_selection_revision_changed"
    end

    local startItems, startItemsErr = self:_ItemsFromWorking(self.keys)
    if startItems == nil then return false, startItemsErr end
    local startState
    if self.mode == "single" and self.anchorModel ~= nil then
        startState = { anchor = self.anchorModel:GetSnapshot() }
    else
        startState = { groupRect = BoundsOfItems(startItems) }
    end
    local items, metadata
    if self.mode == "single" then
        local oldRect = self.anchorModel:GetRect()
        local ok, err = self.anchorModel:SetRect(rect, tostring(source or "inspector_rect"))
        if ok ~= true then return false, err end
        items = { { key = self.keys[1], rect = self.anchorModel:GetRect() } }
        metadata = { anchor = self.anchorModel:GetSnapshot() }
        local previewOk, previewErr = self:_EmitPreview(items, source or "inspector_rect", {}, metadata)
        if previewOk ~= true then self.anchorModel:SetRect(oldRect, "inspector_rollback"); return false, previewErr end
        local commitOk, commitErr = self:_EmitCommit(items, source or "inspector_rect", metadata)
        if commitOk ~= true then
            self.anchorModel:SetRect(oldRect, "inspector_rollback")
            self:_SetWorking(startItems)
            self:_EmitCancel(startItems, "inspector_commit_rejected")
            return false, commitErr
        end
    else
        local session, beginErr = self.multiModel:BeginProjectionSession({ minChildWidth = self.minChildWidth, minChildHeight = self.minChildHeight })
        if session == nil then return false, beginErr end
        items = session:Project(rect)
        if items == nil then session:Cancel(); return false, "layout_editor_adapter_multi_inspector_projection_failed" end
        metadata = { groupRect = CopyRect(rect), multi = session:GetSnapshot() }
        local previewOk, previewErr = self:_EmitPreview(items, source or "inspector_group_rect", {}, metadata)
        if previewOk ~= true then session:Cancel(); return false, previewErr end
        local committed, sessionErr = session:Commit(rect, "inspector_group_rect")
        if committed == nil then return false, sessionErr end
        items = committed
        metadata.multi = self.multiModel:GetSnapshot()
        local commitOk, commitErr = self:_EmitCommit(items, source or "inspector_group_rect", metadata)
        if commitOk ~= true then
            self.multiModel:SetItems(startItems, "inspector_commit_rollback")
            self:_SetWorking(startItems)
            self:_EmitCancel(startItems, "inspector_commit_rejected")
            return false, commitErr
        end
    end

    local setOk, setErr = self:_SetWorking(items)
    if setOk ~= true then return false, setErr end
    self.geometryModel:Resolve()
    self:_RecordHistory(startItems, items, tostring(source or "inspector_rect"), startState, metadata)
    self.revision = (tonumber(self.revision) or 0) + 1
    self.lastError = nil
    return true, nil
end

-- Called after TransformInspector mutates the single AnchorPivotModel directly.
-- This keeps the inspector binding simple while preserving the same external
-- commit contract as rect edits.
function Adapter:CommitSingleAnchorEdit(source, previousSnapshot)
    if self.mode ~= "single" or self.anchorModel == nil then return false, "layout_editor_adapter_single_required" end
    if self.activeGesture == true then return false, "layout_editor_adapter_gesture_active" end
    local key = self.keys[1]
    local previous = CopyRect(self.workingRects[key])
    local previousAnchor = type(previousSnapshot) == "table" and previousSnapshot or nil
    local item = { key = key, rect = self.anchorModel:GetRect() }
    local metadata = { anchor = self.anchorModel:GetSnapshot() }
    local previewOk, previewErr = self:_EmitPreview({ item }, source or "inspector_anchor", {}, metadata)
    if previewOk ~= true then
        if previousAnchor ~= nil and type(self.anchorModel.ApplySnapshot) == "function" then
            self.anchorModel:ApplySnapshot(previousAnchor, "anchor_edit_rollback")
        else
            self.anchorModel:SetRect(previous, "anchor_edit_rollback")
        end
        return false, previewErr
    end
    local commitOk, commitErr = self:_EmitCommit({ item }, source or "inspector_anchor", metadata)
    if commitOk ~= true then
        if previousAnchor ~= nil and type(self.anchorModel.ApplySnapshot) == "function" then
            self.anchorModel:ApplySnapshot(previousAnchor, "anchor_edit_rollback")
        else
            self.anchorModel:SetRect(previous, "anchor_edit_rollback")
        end
        self:_EmitCancel({ { key = key, rect = previous } }, "anchor_edit_commit_rejected")
        return false, commitErr
    end
    self.workingRects[key] = CopyRect(item.rect)
    self.geometryModel:Resolve()
    self:_RecordHistory({ { key = key, rect = previous } }, { item }, tostring(source or "inspector_anchor"),
        previousAnchor ~= nil and { anchor = previousAnchor } or nil, metadata)
    self.revision = (tonumber(self.revision) or 0) + 1
    return true, nil
end

function Adapter:Release()
    if self.activeGesture == true then self:CancelGesture("release") end
    if self.historyModel ~= nil then
        if self.ownsHistoryModel == true and type(self.historyModel.Release) == "function" then
            self.historyModel:Release()
        elseif type(self.historyModel.SetApplyCallbacks) == "function" then
            self.historyModel:SetApplyCallbacks(nil, nil)
        end
    end
    self.historyModel, self.ownsHistoryModel = nil, false
    self.keys, self.workingRects = {}, {}
    self.anchorModel, self.multiModel, self.multiSession = nil, nil, nil
    return true
end

function RSUI:CreateLayoutEditorPreviewAdapter(options)
    options = type(options) == "table" and options or {}
    if type(options.selectionModel) ~= "table" or type(options.selectionModel.GetSelectedKeys) ~= "function"
        or type(options.selectionModel.GetPrimaryKey) ~= "function" then
        return nil, "layout_editor_adapter_selection_model_required"
    end
    if type(options.getRect) ~= "function" then return nil, "layout_editor_adapter_get_rect_required" end
    local maxSelected = math.floor(math.max(1, math.min(N(options.maxSelected, 64), HARD_MAX_SELECTED)))
    local adapter = setmetatable({
        id = tostring(options.id or "layout_editor_adapter"),
        selectionModel = options.selectionModel,
        getRect = options.getRect,
        getParentRect = options.getParentRect,
        getAnchorSpec = options.getAnchorSpec,
        getItemConstraints = options.getItemConstraints,
        onPreview = options.onPreview,
        onCommit = options.onCommit,
        onCancel = options.onCancel,
        canvasRect = CopyRect(options.canvasRect),
        maxSelected = maxSelected,
        minWidth = math.max(1, N(options.minWidth, 1)),
        minHeight = math.max(1, N(options.minHeight, 1)),
        maxWidth = tonumber(options.maxWidth),
        maxHeight = tonumber(options.maxHeight),
        minChildWidth = math.max(1, N(options.minChildWidth, options.minWidth or 1)),
        minChildHeight = math.max(1, N(options.minChildHeight, options.minHeight or 1)),
        keys = {}, workingRects = {}, mode = "none",
        revision = 0, syncedSelectionRevision = -1, activeGesture = false,
        historyModel = nil, ownsHistoryModel = false,
        lastError = nil,
    }, Adapter)
    adapter.geometryModel = RSUI:CreateSelectionGeometryModel({
        id = adapter.id .. ":geometry",
        selectionModel = adapter.selectionModel,
        maxSelected = maxSelected,
        getRect = function(key) return adapter:GetWorkingRect(key) or adapter:_ReadSourceRect(key) end,
    })
    if adapter.geometryModel == nil then return nil, "layout_editor_adapter_geometry_model_failed" end
    local ok, err = adapter:SyncSelection("create")
    if ok ~= true then return nil, err end
    if options.historyModel ~= nil then
        local attached, attachErr = adapter:SetHistoryModel(options.historyModel, false)
        if attached ~= true then return nil, attachErr end
    elseif options.historyEnabled == true then
        local history, historyErr = adapter:EnableHistory(options.historyOptions)
        if history == nil then return nil, historyErr end
    end
    RSUI.metrics.layoutEditorAdaptersCreated = (tonumber(RSUI.metrics.layoutEditorAdaptersCreated) or 0) + 1
    return adapter, nil
end

RSUI.LayoutEditorPreviewAdapter = Adapter

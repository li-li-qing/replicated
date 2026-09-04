------------------------------------------------------------------------
-- Replicated Suite - RSUI Workspace Composition Templates v4
--
-- Page-level composition helpers built exclusively from existing RSUI
-- primitives. These helpers do NOT become a second layout authority: all
-- geometry is still owned by Horizontal/VerticalBox, UniformGrid and SplitView.
--
-- Goals:
--   * eliminate page-owned copies of the same master/detail/editor scaffolds;
--   * make dense game-addon pages align predictably and share breakpoint math;
--   * preserve strict BuildScope / Diff / lifecycle / persistence boundaries;
--   * stay event/layout driven: zero Tick / OnUpdate / polling.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI = S.RSUI
if type(RSUI) ~= "table" then return end
local Tokens = S.UITokens or {}

local T = {
    version = 4,
    contractVersion = 4,
}

local function N(value, fallback)
    value = tonumber(value)
    if value == nil then return tonumber(fallback) or 0 end
    return value
end

local function Token(path, fallback)
    if type(Tokens.Number) == "function" then return Tokens:Number(path, fallback) end
    return N(fallback, 0)
end

local function Copy(source)
    local out = {}
    for key, value in pairs(type(source) == "table" and source or {}) do out[key] = value end
    return out
end

local function RequireSpec(spec, keys)
    if type(spec) ~= "table" then return false, "spec_required" end
    for _, key in ipairs(keys) do
        if spec[key] == nil or tostring(spec[key]) == "" then return false, tostring(key) .. "_required" end
    end
    return true
end

T.BreakpointPolicy = { version = 1 }
function T.BreakpointPolicy:Resolve(width, spec)
    spec = type(spec) == "table" and spec or {}
    width = math.max(1, N(width, 1))
    local compact = math.max(1, N(spec.compact, Token("breakpoint.compact", 720)))
    local regular = math.max(compact, N(spec.regular, Token("breakpoint.regular", 980)))
    local wide = math.max(regular, N(spec.wide, Token("breakpoint.wide", 1180)))
    if width <= compact then return "compact", compact, regular, wide end
    if width <= regular then return "regular", compact, regular, wide end
    if width <= wide then return "wide", compact, regular, wide end
    return "ultrawide", compact, regular, wide
end

-- Shared density policy. Pages may choose a density explicitly, but when they
-- derive it from available width they should all make the same decision.
T.DensityPolicy = { version = 1 }
function T.DensityPolicy:Resolve(width, requested)
    requested = tostring(requested or "auto"):lower()
    if requested == "compact" or requested == "dense" then return "compact" end
    if requested == "spacious" then return "spacious" end
    if requested == "normal" then return "normal" end
    local band = T.BreakpointPolicy:Resolve(width)
    if band == "compact" then return "compact" end
    if band == "ultrawide" then return "spacious" end
    return "normal"
end

-- MasterDetail
--
-- Returned zones:
--   root   : draggable SplitView
--   master : VerticalBox, filters/list/navigation
--   detail : VerticalBox, selected entity details / inspector
--
-- The template intentionally does not decide what data is shown. It only owns
-- repeatable Presentation composition and pane geometry.
function T:MasterDetail(spec)
    local ok, err = RequireSpec(spec, { "id", "parent" })
    if not ok then return nil, err end
    local id = tostring(spec.id)
    local root = RSUI:SplitView({
        id = id .. "_split",
        parent = spec.parent,
        orientation = spec.orientation or "horizontal",
        mode = spec.mode or "fixed",
        primarySize = N(spec.masterWidth or spec.primarySize, Token("workspace.masterW", 252)),
        ratio = N(spec.ratio, 0.34),
        minPrimary = N(spec.masterMinWidth or spec.minPrimary, Token("workspace.masterMinW", 184)),
        minSecondary = N(spec.detailMinWidth or spec.minSecondary, Token("workspace.detailMinW", 320)),
        maxPrimary = spec.masterMaxWidth or spec.maxPrimary,
        maxSecondary = spec.detailMaxWidth or spec.maxSecondary,
        dividerSize = N(spec.dividerSize, Token("workspace.divider", 6)),
        padding = spec.padding,
        onSplitChanged = spec.onSplitChanged,
        slot = spec.slot,
    })
    if root == nil then return nil, "master_detail_root_failed" end
    local master = RSUI:VerticalBox({
        id = id .. "_master",
        parent = root,
        gap = N(spec.masterGap, Token("spacing.sm", 8)),
        padding = spec.masterPadding,
        slot = { hAlign = "fill", vAlign = "fill" },
    })
    local detail = RSUI:VerticalBox({
        id = id .. "_detail",
        parent = root,
        gap = N(spec.detailGap, Token("spacing.sm", 8)),
        padding = spec.detailPadding,
        slot = { hAlign = "fill", vAlign = "fill" },
    })
    if master == nil or detail == nil then return nil, "master_detail_zone_failed" end
    return {
        kind = "MasterDetailWorkspace",
        id = id,
        root = root,
        master = master,
        detail = detail,
        split = root,
    }
end

-- InspectorWorkbench
--
-- Desktop composition:
--   [ navigation/tree ] | [ live preview / main canvas ] | [ inspector ]
--
-- Implemented as two nested SplitViews, so resize behavior, Native geometry
-- writes and divider interaction remain inside existing SplitView Authority.
function T:InspectorWorkbench(spec)
    local ok, err = RequireSpec(spec, { "id", "parent" })
    if not ok then return nil, err end
    local id = tostring(spec.id)
    local outer = RSUI:SplitView({
        id = id .. "_outer",
        parent = spec.parent,
        orientation = "horizontal",
        mode = spec.leftMode or "fixed",
        primarySize = N(spec.leftWidth, Token("workspace.railW", 220)),
        ratio = N(spec.leftRatio, 0.22),
        minPrimary = N(spec.leftMinWidth, Token("workspace.railMinW", 168)),
        minSecondary = N(spec.centerRightMinWidth, Token("workspace.previewMinW", 360) + Token("workspace.inspectorMinW", 220)),
        maxPrimary = spec.leftMaxWidth,
        dividerSize = N(spec.dividerSize, Token("workspace.divider", 6)),
        onSplitChanged = spec.onLeftSplitChanged,
        slot = spec.slot,
    })
    if outer == nil then return nil, "inspector_workbench_outer_failed" end
    local navigator = RSUI:VerticalBox({
        id = id .. "_navigator",
        parent = outer,
        gap = N(spec.navigatorGap, Token("spacing.sm", 8)),
        padding = spec.navigatorPadding,
        slot = { hAlign = "fill", vAlign = "fill" },
    })
    local centerRight = RSUI:SplitView({
        id = id .. "_center_right",
        parent = outer,
        orientation = "horizontal",
        mode = spec.centerMode or "ratio",
        ratio = N(spec.centerRatio, 0.70),
        primarySize = spec.centerWidth,
        minPrimary = N(spec.centerMinWidth, Token("workspace.previewMinW", 360)),
        minSecondary = N(spec.inspectorMinWidth, Token("workspace.inspectorMinW", 220)),
        maxSecondary = spec.inspectorMaxWidth,
        dividerSize = N(spec.dividerSize, Token("workspace.divider", 6)),
        onSplitChanged = spec.onInspectorSplitChanged,
        slot = { hAlign = "fill", vAlign = "fill" },
    })
    if navigator == nil or centerRight == nil then return nil, "inspector_workbench_middle_failed" end
    local canvas = RSUI:VerticalBox({
        id = id .. "_canvas",
        parent = centerRight,
        gap = N(spec.canvasGap, Token("spacing.sm", 8)),
        padding = spec.canvasPadding,
        slot = { hAlign = "fill", vAlign = "fill" },
    })
    local inspector = RSUI:VerticalBox({
        id = id .. "_inspector",
        parent = centerRight,
        gap = N(spec.inspectorGap, Token("spacing.sm", 8)),
        padding = spec.inspectorPadding,
        slot = { hAlign = "fill", vAlign = "fill" },
    })
    if canvas == nil or inspector == nil then return nil, "inspector_workbench_zone_failed" end
    return {
        kind = "InspectorWorkbench",
        id = id,
        root = outer,
        outerSplit = outer,
        navigator = navigator,
        canvas = canvas,
        inspector = inspector,
        inspectorSplit = centerRight,
    }
end

-- ResponsiveInspectorWorkspace
--
-- Two-zone editor workspace whose content + inspector remain under one stable
-- native parent for their whole lifetime. Wide layouts arrange them side by
-- side; compact layouts keep content full-size and expose the SAME inspector as
-- a right drawer. No Release/rebuild/reparent is performed on breakpoint
-- changes, preserving focus, selection and component identity.
function T:ResponsiveInspector(spec)
    local ok, err = RequireSpec(spec, { "id", "parent" })
    if not ok then return nil, err end
    if type(RSUI.ResponsiveInspector) ~= "function" or (tonumber(RSUI.ResponsiveInspectorContractVersion) or 0) < 1 then
        return nil, "responsive_inspector_foundation_missing"
    end
    local id = tostring(spec.id)
    local root = RSUI:ResponsiveInspector({
        id = id .. "_responsive",
        parent = spec.parent,
        breakpoint = spec.breakpoint or Token("breakpoint.regular", 980),
        inspectorWidth = spec.inspectorWidth or Token("workspace.inspectorW", 286),
        inspectorMinWidth = spec.inspectorMinWidth or Token("workspace.inspectorMinW", 220),
        contentMinWidth = spec.contentMinWidth or Token("workspace.previewMinW", 360),
        drawerOpen = spec.drawerOpen == true,
        drawerMaxFraction = spec.drawerMaxFraction,
        drawerMinReveal = spec.drawerMinReveal,
        gap = spec.gap or Token("workspace.divider", 6),
        padding = spec.padding,
        onModeChanged = spec.onModeChanged,
        onDrawerChanged = spec.onDrawerChanged,
        onInspectorWidthChanged = spec.onInspectorWidthChanged,
        slot = spec.slot,
    })
    if root == nil then return nil, "responsive_inspector_root_failed" end
    local content = RSUI:VerticalBox({
        id = id .. "_content",
        parent = root,
        gap = N(spec.contentGap, Token("spacing.sm", 8)),
        padding = spec.contentPadding,
        slot = { role = "content", hAlign = "fill", vAlign = "fill" },
    })
    local inspector = RSUI:VerticalBox({
        id = id .. "_inspector",
        parent = root,
        gap = N(spec.inspectorGap, Token("spacing.sm", 8)),
        padding = spec.inspectorPadding,
        slot = { role = "inspector", hAlign = "fill", vAlign = "fill" },
    })
    if content == nil or inspector == nil then return nil, "responsive_inspector_zone_failed" end
    return {
        kind = "ResponsiveInspectorWorkspace",
        id = id,
        root = root,
        content = content,
        canvas = content,
        inspector = inspector,
        SetDrawerOpen = function(_, open, notify) return root:SetDrawerOpen(open, notify) end,
        ToggleDrawer = function(_, notify) return root:ToggleDrawer(notify) end,
        GetMode = function() return root:GetMode() end,
        GetResponsiveSnapshot = function() return root:GetResponsiveSnapshot() end,
    }
end

-- SettingsWorkbench is a semantic MasterDetail preset. The rail is intended for
-- categories/element lists; the detail pane is the sole property editor.

-- Pure preflight for the optional durable edit-session boundary. Keeping this
-- validation outside widget construction lets Acceptance/Sequence verify the
-- contract without creating Native widgets.
function T:ValidateLayoutEditorEditSessionSpec(editSessionSpec)
    if editSessionSpec == nil then return true, nil end
    if type(editSessionSpec) ~= "table" then return false, "layout_editor_workspace_edit_session_invalid" end
    for _, callbackName in ipairs({
        "getWorkingSnapshot", "getPersistedSnapshot", "getDefaultSnapshot",
        "applyWorkingSnapshot", "persistSnapshot",
    }) do
        if type(editSessionSpec[callbackName]) ~= "function" then
            return false, "layout_editor_workspace_edit_session_callback_required:" .. callbackName
        end
    end
    if editSessionSpec.canPersist ~= nil and type(editSessionSpec.canPersist) ~= "function" then
        return false, "layout_editor_workspace_edit_session_can_persist_invalid"
    end
    return true, nil
end

-- LayoutEditorWorkspace
--
-- Stable-host editor composition:
--   ResponsiveInspector
--   ├─ content: toolbar + Overlay canvas
--   │           ├─ previewHost (caller content)
--   │           └─ LayoutEditorOverlay (selection/guides/gesture)
--   └─ inspector: ScrollBox -> ONE TransformInspector instance
--
-- Single/multi selection never creates two competing inspectors. The same
-- TransformInspector swaps its rect/anchor model binding; anchor fields collapse
-- in multi-select mode while shared SnapSettings remain the same Authority.
function T:LayoutEditor(spec)
    local ok, err = RequireSpec(spec, { "id", "parent" })
    if not ok then return nil, err end
    if type(spec.selectionModel) ~= "table" or type(spec.getRect) ~= "function" then
        return nil, "layout_editor_workspace_selection_contract_required"
    end
    if type(RSUI.LayoutEditorOverlay) ~= "function" or (tonumber(RSUI.LayoutEditorOverlayContractVersion) or 0) < 1 then
        return nil, "layout_editor_overlay_foundation_missing"
    end
    if type(RSUI.TransformInspector) ~= "function" or (tonumber(RSUI.TransformInspectorContractVersion) or 0) < 2 then
        return nil, "layout_editor_transform_inspector_v2_required"
    end
    if type(RSUI.CreateLayoutEditHistoryModel) ~= "function" or (tonumber(RSUI.LayoutEditHistoryContractVersion) or 0) < 1 then
        return nil, "layout_editor_workspace_history_foundation_missing"
    end
    if type(RSUI.EditorCommandBar) ~= "function" or (tonumber(RSUI.EditorCommandBarContractVersion) or 0) < 2 then
        return nil, "layout_editor_workspace_command_bar_foundation_missing"
    end

    -- Persistence remains a caller/Feature responsibility. The Workspace only
    -- creates the Session Authority when the caller supplies the complete
    -- durable boundary. Supplying no editSession keeps a valid history-only
    -- editor (Revert/Reset/Apply fail closed); supplying a partial contract is a
    -- hard error so no page can accidentally invent half-persistent semantics.
    local editSessionSpec = spec.editSession
    local editSessionOk, editSessionErr = self:ValidateLayoutEditorEditSessionSpec(editSessionSpec)
    if editSessionOk ~= true then return nil, editSessionErr end
    if editSessionSpec ~= nil and (type(RSUI.CreateLayoutEditSessionModel) ~= "function"
        or (tonumber(RSUI.LayoutEditSessionContractVersion) or 0) < 1) then
        return nil, "layout_editor_workspace_session_foundation_missing"
    end

    local id = tostring(spec.id)
    local root = RSUI:ResponsiveInspector({
        id = id .. "_responsive", parent = spec.parent,
        breakpoint = spec.breakpoint or Token("breakpoint.regular", 980),
        inspectorWidth = spec.inspectorWidth or Token("workspace.inspectorW", 286),
        inspectorMinWidth = spec.inspectorMinWidth or Token("workspace.inspectorMinW", 220),
        contentMinWidth = spec.contentMinWidth or Token("workspace.previewMinW", 360),
        drawerOpen = spec.drawerOpen == true, drawerMaxFraction = spec.drawerMaxFraction,
        drawerMinReveal = spec.drawerMinReveal, gap = spec.gap or Token("workspace.divider", 6),
        padding = spec.padding, onModeChanged = spec.onResponsiveModeChanged,
        onDrawerChanged = spec.onDrawerChanged, onInspectorWidthChanged = spec.onInspectorWidthChanged,
        slot = spec.slot,
    })
    if root == nil then return nil, "layout_editor_workspace_root_failed" end

    local historyModel = nil
    local sessionModel = nil
    local workspace = nil
    local released = false
    local historyToken = "layout_editor_workspace:" .. id .. ":history"
    local sessionToken = "layout_editor_workspace:" .. id .. ":session"

    local function ReleaseModels()
        if released == true then return false end
        released = true
        if historyModel ~= nil and type(historyModel.Unsubscribe) == "function" then
            pcall(function() historyModel:Unsubscribe(historyToken) end)
        end
        if sessionModel ~= nil and type(sessionModel.Unsubscribe) == "function" then
            pcall(function() sessionModel:Unsubscribe(sessionToken) end)
        end
        if sessionModel ~= nil and type(sessionModel.Release) == "function" then pcall(function() sessionModel:Release() end) end
        if historyModel ~= nil and type(historyModel.Release) == "function" then pcall(function() historyModel:Release() end) end
        sessionModel, historyModel = nil, nil
        if workspace ~= nil then
            workspace.sessionModel, workspace.historyModel = nil, nil
            workspace.commandBar = nil
        end
        return true
    end

    local function Fail(reason)
        if root ~= nil and type(root.Release) == "function" and root.released ~= true then pcall(function() root:Release() end) end
        ReleaseModels()
        return nil, tostring(reason or "layout_editor_workspace_create_failed")
    end

    local content = RSUI:VerticalBox({
        id = id .. "_content", parent = root, gap = N(spec.contentGap, Token("spacing.xs", 4)),
        padding = spec.contentPadding, slot = { role = "content", hAlign = "fill", vAlign = "fill" },
    })
    local toolbar = RSUI:HorizontalBox({
        id = id .. "_toolbar", parent = content, gap = N(spec.toolbarGap, Token("spacing.sm", 8)),
        padding = spec.toolbarPadding or { left = 6, top = 4, right = 6, bottom = 4 },
        slot = { size = "auto", hAlign = "fill", vAlign = "top" },
    })
    -- The host is created before the canvas so the command bar keeps a stable
    -- vertical slot without reparenting when the Workspace changes breakpoint.
    local commandHost = RSUI:VerticalBox({
        id = id .. "_command_host", parent = content, gap = 0,
        padding = spec.commandPadding or { left = 6, top = 0, right = 6, bottom = 2 },
        slot = { size = "auto", hAlign = "fill", vAlign = "top" },
    })
    local canvas = RSUI:Overlay({
        id = id .. "_canvas", parent = content, padding = spec.canvasPadding,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })
    local previewHost = RSUI:Overlay({
        id = id .. "_preview", parent = canvas,
        slot = { hAlign = "fill", vAlign = "fill" },
    })
    local inspectorScroll = RSUI:ScrollBox({
        id = id .. "_inspector_scroll", parent = root, orientation = "vertical", scrollStep = 2,
        scrollbar = true, padding = spec.inspectorPadding or { left = 6, top = 6, right = 6, bottom = 6 },
        slot = { role = "inspector", hAlign = "fill", vAlign = "fill" },
    })
    if content == nil or toolbar == nil or commandHost == nil or canvas == nil or previewHost == nil or inspectorScroll == nil then
        return Fail("layout_editor_workspace_zone_failed")
    end

    local selectionStatus = RSUI:StatusChip({
        id = id .. "_selection_status", parent = toolbar, status = "muted", text = "未选择",
        minWidth = 72, maxWidth = 160, slot = { size = "auto", vAlign = "center" },
    })
    local coordinateHint = RSUI:Text({
        id = id .. "_coordinate_hint", parent = toolbar,
        text = "左上(0,0) · X→右 · Y→下", tone = "muted", overflow = "ellipsis",
        slot = { size = "fill", fill = 1, hAlign = "right", vAlign = "center" },
    })
    if selectionStatus == nil or coordinateHint == nil then return Fail("layout_editor_workspace_toolbar_failed") end

    historyModel, err = RSUI:CreateLayoutEditHistoryModel({
        id = id .. ":history",
        maxCommands = type(spec.historyOptions) == "table" and spec.historyOptions.maxCommands or nil,
        maxItems = type(spec.historyOptions) == "table" and spec.historyOptions.maxItems or spec.maxSelected,
    })
    if historyModel == nil then return Fail(err or "layout_editor_workspace_history_failed") end

    workspace = {
        kind = "LayoutEditorWorkspace", id = id, root = root, content = content, toolbar = toolbar,
        commandHost = commandHost, canvas = canvas, previewHost = previewHost, inspectorHost = inspectorScroll,
        selectionStatus = selectionStatus, coordinateHint = coordinateHint, historyModel = historyModel,
        sessionModel = nil, commandBar = nil, released = false,
    }

    local editorOverlay = RSUI:LayoutEditorOverlay({
        id = id .. "_editor", parent = canvas,
        selectionModel = spec.selectionModel, getRect = spec.getRect, getParentRect = spec.getParentRect,
        getAnchorSpec = spec.getAnchorSpec, getItemConstraints = spec.getItemConstraints,
        canvasRect = spec.canvasRect, getCanvasRect = spec.getCanvasRect,
        coordinateSpace = spec.coordinateSpace, pointerToLocal = spec.pointerToLocal,
        getSnapCandidates = spec.getSnapCandidates, snapModel = spec.snapModel, snapSettings = spec.snapSettings,
        maxSelected = spec.maxSelected, minWidth = spec.minWidth, minHeight = spec.minHeight,
        maxWidth = spec.maxWidth, maxHeight = spec.maxHeight,
        minChildWidth = spec.minChildWidth, minChildHeight = spec.minChildHeight,
        handleSize = spec.handleSize, handleHitSlop = spec.handleHitSlop, enabled = spec.editorEnabled ~= false,
        onPreview = spec.onPreview, onCommit = spec.onCommit, onCancel = spec.onCancel,
        historyModel = historyModel,
        onTransformCommitted = spec.onTransformCommitted,
        onModeChanged = function(mode, count, anchorModel, adapter, overlay)
            if selectionStatus ~= nil then
                if mode == "none" then selectionStatus:SetStatus("muted", "未选择")
                elseif mode == "single" then selectionStatus:SetStatus("info", "单选 · 1 项")
                else selectionStatus:SetStatus("info", "多选 · " .. tostring(count) .. " 项") end
            end
            if workspace ~= nil and workspace.transformInspector ~= nil then
                workspace.transformInspector:SetModels(adapter, anchorModel)
                workspace.transformInspector:SetEnabled(mode ~= "none")
            end
            if spec.autoOpenInspectorOnSelection == true and mode ~= "none"
                and root:GetMode() == "drawer" and type(root.SetDrawerOpen) == "function" then
                root:SetDrawerOpen(true, true)
            end
            if type(spec.onSelectionModeChanged) == "function" then
                RSUI:Callback("rsui:layout_editor_workspace:" .. id .. ":mode",
                    spec.onSelectionModeChanged, mode, count, anchorModel, adapter, overlay, workspace)
            end
        end,
        slot = { hAlign = "fill", vAlign = "fill" },
    })
    if editorOverlay == nil then return Fail("layout_editor_workspace_overlay_failed") end
    workspace.editorOverlay = editorOverlay
    workspace.adapter = editorOverlay:GetAdapter()
    workspace.snapModel = editorOverlay:GetSnapModel()
    if workspace.adapter == nil or workspace.adapter:GetHistoryModel() ~= historyModel then
        return Fail("layout_editor_workspace_history_adapter_binding_failed")
    end

    local inspector = RSUI:TransformInspector({
        id = id .. "_transform_inspector", parent = inspectorScroll,
        rectModel = workspace.adapter, anchorModel = workspace.adapter:GetAnchorModel(), snapModel = workspace.snapModel,
        width = spec.inspectorWidth or Token("workspace.inspectorW", 286),
        enabled = workspace.adapter:GetMode() ~= "none",
        onAnchorChanged = function(currentSnapshot, previousSnapshot, source)
            local accepted, detail = workspace.adapter:CommitSingleAnchorEdit(source, previousSnapshot)
            if accepted == true then
                editorOverlay:RefreshFromAdapter(false, "inspector_anchor")
                return true
            end
            editorOverlay:RefreshFromAdapter(false, "inspector_anchor_rejected")
            return false, detail
        end,
        onTransformChanged = function(snapshot, source)
            editorOverlay:RefreshFromAdapter(false, "inspector_transform")
            if type(spec.onInspectorTransformChanged) == "function" then
                RSUI:Callback("rsui:layout_editor_workspace:" .. id .. ":transform",
                    spec.onInspectorTransformChanged, snapshot, source, workspace)
            end
            return true
        end,
        onSnapChanged = function(snapshot, source)
            if type(spec.onSnapChanged) == "function" then
                RSUI:Callback("rsui:layout_editor_workspace:" .. id .. ":snap", spec.onSnapChanged, snapshot, source, workspace)
            end
            return true
        end,
        slot = { hAlign = "fill", vAlign = "top" },
    })
    if inspector == nil then return Fail("layout_editor_workspace_inspector_failed") end
    workspace.transformInspector = inspector
    inspector:SetModels(workspace.adapter, workspace.adapter:GetAnchorModel())
    inspector:SetEnabled(workspace.adapter:GetMode() ~= "none")

    if editSessionSpec ~= nil then
        sessionModel, err = RSUI:CreateLayoutEditSessionModel({
            id = id .. ":session",
            historyModel = historyModel,
            maxSnapshotNodes = editSessionSpec.maxSnapshotNodes,
            getWorkingSnapshot = editSessionSpec.getWorkingSnapshot,
            getPersistedSnapshot = editSessionSpec.getPersistedSnapshot,
            getDefaultSnapshot = editSessionSpec.getDefaultSnapshot,
            applyWorkingSnapshot = editSessionSpec.applyWorkingSnapshot,
            persistSnapshot = editSessionSpec.persistSnapshot,
            canPersist = editSessionSpec.canPersist,
        })
        if sessionModel == nil then return Fail(err or "layout_editor_workspace_session_failed") end
        workspace.sessionModel = sessionModel
    end

    local commandBar = RSUI:EditorCommandBar({
        id = id .. "_commands", parent = commandHost,
        historyModel = historyModel, sessionModel = sessionModel,
        width = spec.commandWidth, height = spec.commandHeight or 28,
        buttonWidth = spec.commandButtonWidth or 46, gap = spec.commandGap or 4,
        statusMinWidth = spec.commandStatusMinWidth or 84, statusMaxWidth = spec.commandStatusMaxWidth or 180,
        enabled = spec.editorEnabled ~= false,
        onCommand = function(command, accepted, detail, snapshot, bar)
            if type(spec.onEditorCommand) == "function" then
                RSUI:Callback("rsui:layout_editor_workspace:" .. id .. ":command",
                    spec.onEditorCommand, command, accepted, detail, snapshot, bar, workspace)
            end
        end,
        slot = { size = "auto", hAlign = "fill", vAlign = "top" },
    })
    if commandBar == nil then return Fail("layout_editor_workspace_command_bar_failed") end
    workspace.commandBar = commandBar

    local function RefreshInspectorBinding()
        if workspace == nil or workspace.released == true then return false end
        inspector:SetModels(workspace.adapter, workspace.adapter:GetAnchorModel())
        inspector:SetEnabled(workspace.adapter:GetMode() ~= "none")
        return true
    end

    -- History replay already passes through Adapter:ApplyHistoryState, so the
    -- Adapter is current by the time this event fires. Refresh presentation from
    -- Adapter only; do not re-read Feature state or create another history entry.
    local historySubscribed = historyModel:Subscribe(historyToken, function(_, reason)
        if workspace == nil or workspace.released == true then return end
        reason = tostring(reason or "changed")
        if reason == "record" or reason == "undo" or reason == "redo" then
            editorOverlay:RefreshFromAdapter(false, "workspace_history:" .. reason)
            RefreshInspectorBinding()
        end
    end)
    if historySubscribed ~= true then return Fail("layout_editor_workspace_history_subscribe_failed") end

    if sessionModel ~= nil then
        local sessionSubscribed = sessionModel:Subscribe(sessionToken, function(_, reason, snapshot, detail)
            if workspace == nil or workspace.released == true then return end
            reason = tostring(reason or "changed")
            -- Reset/Revert (and their rollback/failure paths) mutate Feature
            -- Working through the caller callback, bypassing the Adapter by
            -- design. Re-read source exactly at those explicit command edges.
            if reason == "command:revert" or reason == "command:reset"
                or reason == "command_failed:revert" or reason == "command_failed:reset"
                or reason == "rebase" then
                local refreshed, refreshErr = editorOverlay:RefreshFromSource("workspace_session:" .. reason)
                if refreshed == true then RefreshInspectorBinding() end
                if refreshed ~= true and type(S.DiagnosticsManager) == "table" and type(S.DiagnosticsManager.Warn) == "function" then
                    pcall(function()
                        S.DiagnosticsManager:Warn("ui", "LAYOUT_EDITOR_WORKSPACE_SESSION_REFRESH_FAILED",
                            "Layout Editor Session 回放后刷新失败", { workspace = id, reason = reason, error = tostring(refreshErr) })
                    end)
                end
            end
            if type(spec.onEditSessionChanged) == "function" then
                RSUI:Callback("rsui:layout_editor_workspace:" .. id .. ":session",
                    spec.onEditSessionChanged, reason, snapshot, detail, sessionModel, workspace)
            end
        end)
        if sessionSubscribed ~= true then return Fail("layout_editor_workspace_session_subscribe_failed") end
    end

    workspace.SetDrawerOpen = function(_, open, notify) return root:SetDrawerOpen(open, notify) end
    workspace.ToggleDrawer = function(_, notify) return root:ToggleDrawer(notify) end
    workspace.GetMode = function() return root:GetMode() end
    workspace.GetHistoryModel = function() return historyModel end
    workspace.GetSessionModel = function() return sessionModel end
    workspace.GetCommandBar = function() return commandBar end
    workspace.ExecuteCommand = function(_, command) return commandBar:Execute(command) end
    workspace.RebaseEditSession = function(_, source)
        if sessionModel == nil then return false, "layout_editor_workspace_session_not_attached" end
        return sessionModel:Rebase(source or "workspace_rebase")
    end
    workspace.RefreshFromSource = function(_, source)
        source = tostring(source or "workspace_refresh")
        local refreshed, refreshErr = editorOverlay:RefreshFromSource(source)
        if refreshed ~= true then return false, refreshErr end
        RefreshInspectorBinding()
        if sessionModel ~= nil then
            local sessionOk, sessionErr = sessionModel:RefreshWorking("workspace_source:" .. source)
            if sessionOk ~= true then return false, sessionErr end
        end
        return true, nil
    end
    workspace.GetSnapshot = function()
        return {
            kind = workspace.kind, id = id, contractVersion = tonumber(RSUI.LayoutEditorWorkspaceContractVersion) or 0,
            responsive = root:GetResponsiveSnapshot(), editor = editorOverlay:GetSnapshot(), inspector = inspector:GetSnapshot(),
            history = historyModel and historyModel:GetSnapshot() or nil,
            session = sessionModel and sessionModel:GetCommandSnapshot() or nil,
            commands = commandBar and commandBar:GetSnapshot() or nil,
        }
    end
    workspace.Release = function()
        if workspace.released == true then return false end
        workspace.released = true
        if root ~= nil and type(root.Release) == "function" and root.released ~= true then root:Release() end
        ReleaseModels()
        return true
    end

    -- The returned workspace is a semantic facade, while root is the actual
    -- component lifetime owner. Hook root teardown so callers that release only
    -- the component tree cannot leak Session/History listeners or model state.
    local BaseRootRelease = root.Release
    function root:Release()
        if self.released == true then return 0 end
        local count = BaseRootRelease(self)
        if workspace ~= nil then workspace.released = true end
        ReleaseModels()
        return count
    end

    RSUI.metrics.layoutEditorWorkspacesCreated = (tonumber(RSUI.metrics.layoutEditorWorkspacesCreated) or 0) + 1
    RSUI.metrics.layoutEditorWorkspaceHistoryBindings = (tonumber(RSUI.metrics.layoutEditorWorkspaceHistoryBindings) or 0) + 1
    if sessionModel ~= nil then
        RSUI.metrics.layoutEditorWorkspaceSessionBindings = (tonumber(RSUI.metrics.layoutEditorWorkspaceSessionBindings) or 0) + 1
    end
    return workspace
end

function T:SettingsWorkbench(spec)
    spec = Copy(spec)
    spec.masterWidth = spec.masterWidth or Token("workspace.railW", 220)
    spec.masterMinWidth = spec.masterMinWidth or Token("workspace.railMinW", 168)
    spec.detailMinWidth = spec.detailMinWidth or Token("workspace.detailMinW", 320)
    local view, err = self:MasterDetail(spec)
    if view == nil then return nil, err end
    view.kind = "SettingsWorkbench"
    view.navigation = view.master
    view.content = view.detail
    return view
end

-- CommandCenter
--
-- Structure:
--   header (fixed)
--   status strip / KPIs (auto)
--   situation overview | exception / priority queue (fill)
--   evidence / timeline (optional fixed/auto)
--
-- This template is useful for Raid Readiness, Activities overview and combat
-- mechanic monitoring. It keeps exception-first pages visually consistent.
function T:CommandCenter(spec)
    local ok, err = RequireSpec(spec, { "id", "parent" })
    if not ok then return nil, err end
    local id = tostring(spec.id)
    local root = RSUI:VerticalBox({
        id = id .. "_root",
        parent = spec.parent,
        gap = N(spec.gap, Token("spacing.sm", 8)),
        padding = spec.padding,
        slot = spec.slot,
    })
    if root == nil then return nil, "command_center_root_failed" end
    local header = RSUI:HorizontalBox({
        id = id .. "_header",
        parent = root,
        gap = N(spec.headerGap, Token("spacing.sm", 8)),
        slot = { size = "fixed", height = N(spec.headerHeight, 34), hAlign = "fill" },
    })
    local status = RSUI:UniformGrid({
        id = id .. "_status",
        parent = root,
        minCellWidth = N(spec.statusMinCellWidth, 172),
        minCellHeight = N(spec.statusCellHeight, 58),
        maxColumns = math.max(1, math.floor(N(spec.statusMaxColumns, 4))),
        gap = N(spec.statusGap, Token("spacing.sm", 8)),
        slot = { size = "auto", minHeight = N(spec.statusCellHeight, 58), hAlign = "fill" },
    })
    local body = RSUI:SplitView({
        id = id .. "_body",
        parent = root,
        orientation = "horizontal",
        mode = spec.queueMode or "ratio",
        ratio = N(spec.overviewRatio, 0.68),
        primarySize = spec.overviewWidth,
        minPrimary = N(spec.overviewMinWidth, Token("workspace.previewMinW", 360)),
        minSecondary = N(spec.queueMinWidth, Token("workspace.commandQueueMinW", 236)),
        maxSecondary = spec.queueMaxWidth,
        dividerSize = N(spec.dividerSize, Token("workspace.divider", 6)),
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })
    if header == nil or status == nil or body == nil then return nil, "command_center_core_zone_failed" end
    local overview = RSUI:VerticalBox({ id = id .. "_overview", parent = body, gap = N(spec.overviewGap, 6), slot = { hAlign = "fill", vAlign = "fill" } })
    local queue = RSUI:VerticalBox({ id = id .. "_queue", parent = body, gap = N(spec.queueGap, 6), slot = { hAlign = "fill", vAlign = "fill" } })
    if overview == nil or queue == nil then return nil, "command_center_body_zone_failed" end
    local evidence = nil
    if spec.evidence ~= false then
        evidence = RSUI:VerticalBox({
            id = id .. "_evidence",
            parent = root,
            gap = N(spec.evidenceGap, 4),
            slot = { size = "fixed", height = N(spec.evidenceHeight, 118), hAlign = "fill" },
        })
        if evidence == nil then return nil, "command_center_evidence_failed" end
    end
    return {
        kind = "CommandCenterWorkspace",
        id = id,
        root = root,
        header = header,
        status = status,
        body = body,
        overview = overview,
        queue = queue,
        evidence = evidence,
    }
end

function T:GetSnapshot()
    return {
        version = self.version,
        contractVersion = self.contractVersion,
        breakpointPolicy = self.BreakpointPolicy.version,
        densityPolicy = self.DensityPolicy.version,
        templates = { "MasterDetail", "InspectorWorkbench", "ResponsiveInspector", "LayoutEditor", "SettingsWorkbench", "CommandCenter" },
    }
end

RSUI.LayoutEditorWorkspaceContractVersion = 2
RSUI.LayoutEditorWorkspaceSessionBindingContractVersion = 1
RSUI.WorkspaceTemplates = T
RSUI.WorkspaceTemplateContractVersion = T.contractVersion

function RSUI:CreateMasterDetailWorkspace(spec) return T:MasterDetail(spec) end
function RSUI:CreateInspectorWorkbench(spec) return T:InspectorWorkbench(spec) end
function RSUI:CreateResponsiveInspectorWorkspace(spec) return T:ResponsiveInspector(spec) end
function RSUI:CreateLayoutEditorWorkspace(spec) return T:LayoutEditor(spec) end
function RSUI:CreateSettingsWorkbench(spec) return T:SettingsWorkbench(spec) end
function RSUI:CreateCommandCenterWorkspace(spec) return T:CommandCenter(spec) end

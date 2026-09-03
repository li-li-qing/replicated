------------------------------------------------------------------------
-- Replicated Suite - RSUI Component Runtime v2
--
-- Public component layer above UI Factory + UI Framework Diff/Lifecycle.
-- Business modules should construct reusable UI through S.RSUI instead of
-- talking to ArcheAge native widgets directly whenever a standard component
-- exists.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local UI = S.UI
if type(UI) ~= "table" then return end

local RSUI = {
    version = 38,
    apiVersion = "12.2",
    types = {},
    typeOrder = {},
    metrics = {
        created = 0,
        rendered = 0,
        layouts = 0,
        events = 0,
        releases = 0,
        errors = 0,
        layoutCompressionEvents = 0,
        layoutOverflowEvents = 0,
        invalidations = 0,
        inspectorScans = 0,
        wrapEvents = 0,
        scrollChanges = 0,
        switchChanges = 0,
        measurePasses = 0,
        measureSkips = 0,
        layoutPasses = 0,
        layoutSkips = 0,
        viewportRefreshes = 0,
        safeZoneClamps = 0,
        screenBoundaryIssues = 0,
        visibilityChanges = 0,
        debugOverlayRefreshes = 0,
        virtualPoolRowsCreated = 0,
        virtualRowBinds = 0,
        virtualRowReuses = 0,
        virtualReconciles = 0,
        virtualDataRefreshes = 0,
        virtualVisibleRowsPeak = 0,
        tableColumnResolves = 0,
        tableEmergencyClamps = 0,
        selectionModelsCreated = 0,
        selectionChanges = 0,
        selectionVisualsCreated = 0,
        selectionVisualApplications = 0,
        selectionGeometryModelsCreated = 0,
        selectionGeometryResolves = 0,
        layoutGuideResolves = 0,
        layoutGuideCandidatesScanned = 0,
        layoutGuideSnaps = 0,
        selectionOverlayLayouts = 0,
        layoutGuideOverlayUpdates = 0,
        layoutEditorGestureBegins = 0,
        layoutEditorGesturePulses = 0,
        layoutEditorGestureCommits = 0,
        layoutEditorGestureCancels = 0,
        layoutEditorGestureCaptureFailures = 0,
        layoutEditorGestureFallbackUpdates = 0,
        layoutEditorGestureCandidateFreezes = 0,
        layoutEditorGesturePreviewRejects = 0,
        layoutEditorGestureCommitRejects = 0,
        layoutEditorAdaptersCreated = 0,
        layoutEditorAdapterSyncs = 0,
        layoutEditorAdapterPreviews = 0,
        layoutEditorAdapterCommits = 0,
        layoutEditorAdapterCancels = 0,
        layoutEditorAdapterGestureBegins = 0,
        layoutEditorOverlaysCreated = 0,
        layoutEditorOverlayRefreshes = 0,
        layoutEditorOverlayCandidateScans = 0,
        layoutEditorWorkspacesCreated = 0,
        layoutEditorAnchorPivotModelsCreated = 0,
        layoutEditorAnchorPivotChanges = 0,
        layoutEditorSnapSettingsModelsCreated = 0,
        layoutEditorSnapSettingsChanges = 0,
        transformInspectorEdits = 0,
        transformInspectorSnapEdits = 0,
        transformInspectorRefreshes = 0,
        transformInspectorLayouts = 0,
        multiSelectionTransformModelsCreated = 0,
        multiSelectionTransformSessions = 0,
        multiSelectionTransformProjections = 0,
        multiSelectionTransformCommits = 0,
        multiSelectionTransformCancels = 0,
        multiSelectionTransformRejects = 0,
        tilePoolItemsCreated = 0,
        tileItemBinds = 0,
        tileItemReuses = 0,
        tileReconciles = 0,
        tileColumnChanges = 0,
        tileVisibleItemsPeak = 0,
        tableHeaderClicks = 0,
        tableSortChanges = 0,
        tableColumnWidthChanges = 0,
        eventSubscriptions = 0,
        eventDispatches = 0,
        tooltipBindings = 0,
        tooltipShows = 0,
        tooltipHides = 0,
        contextMenuOpens = 0,
        contextMenuCloses = 0,
        contextMenuActions = 0,
        contextMenuRowsCreated = 0,
        focusChanges = 0,
        playgroundBuilds = 0,
        playgroundStressRuns = 0,
        layoutRootsQueued = 0,
        layoutFlushes = 0,
        layoutRootsReflowed = 0,
        layoutFlushDeferrals = 0,
        layoutStabilizationPasses = 0,
        layoutUnstableDeferrals = 0,
        siblingOverlapIssues = 0,
        -- Advanced layout-template degradation counters (rs_ui_layout_templates).
        -- Non-zero means a template hit a geometry dead end and degraded on
        -- purpose; these are diagnostic signals, not errors.
        collapsibleHeaderUnavailable = 0,
        collapsibleHeaderBindFailed = 0,
        splitToolbarSpacerClamped = 0,
        statusChipUpdates = 0,
        pickerModelRebuilds = 0,
        treeModelRebuilds = 0,
        treeExpansionChanges = 0,
        treeExpansionStatePrunes = 0,
        attachmentRejects = 0,
        attachmentCycleRejects = 0,
        attachmentParentConflicts = 0,
        attachmentNativeParentConflicts = 0,
        childRemovals = 0,
        responsiveInspectorModeChanges = 0,
        responsiveInspectorDrawerChanges = 0,
        searchablePickerQueries = 0,
        searchablePickerSelections = 0,
        iconPickerQueries = 0,
        iconPickerSelections = 0,
        iconPickerTileBinds = 0,
        externalLayoutInvalidations = 0,
        duplicateTypeRegistrations = 0,
        invalidationCoalesces = 0,
        invalidationEpochs = 0,
        buildScopesStarted = 0,
        buildScopesCommitted = 0,
        buildScopesRolledBack = 0,
        buildScopeComponentsReleased = 0,
        buildScopeWidgetsHidden = 0,
        buildScopeCleanupFailures = 0,
        buildScopeCloseOrderRecoveries = 0,
        buildTransactions = 0,
        buildTransactionFailures = 0,
        preflightFailures = 0,
        strictBuildFailFast = 0,
        typographyInvalidations = 0,
        fontScaleApplications = 0,
        byType = {},
    },
}
RSUI.StrictBuildFailFastContractVersion = 1
RSUI.AttachmentContractVersion = 1
RSUI.ReparentPolicyContractVersion = 1
RSUI.NativeReparentSupported = false

-- Event-driven invalidation queue.
--
-- Phase 1-8 established dirty propagation, but it deliberately required an
-- external caller to perform the next Layout pass.  That contract is not
-- sufficient for data-driven composites: Collapsed/Visible changes made after
-- an initial layout can leave stale gaps until the entire page is laid out
-- again.  M6-v10 closes that gap without adding a permanent Tick.  Only the
-- top-most logical RSUI component is queued, and the existing Suite Scheduler
-- executes one bounded one-shot flush.
RSUI.layoutQueue = setmetatable({}, { __mode = "k" })
RSUI.layoutFlushScratch = {}
RSUI.layoutFlushScheduled = false
RSUI.layoutFlushRunning = false
RSUI.layoutFlushTaskName = "rsui_layout_flush"
RSUI.layoutEpoch = 0
RSUI.typographyComponents = setmetatable({}, { __mode = "k" })

-- Synchronous construction transaction. V3 pages/widgets/windows are built
-- lazily, while the RU client does not expose a validated generic DestroyWidget
-- operation. A Lua exception after a native widget was committed therefore must
-- not be followed by a second constructor attempt with the same physical id.
-- Build scopes retain only objects created by the current synchronous factory;
-- normal rendering has zero per-frame cost.
RSUI.buildScopeStack = {}
RSUI.buildScopeSerial = 0
RSUI.BuildScopeContractVersion = 3
RSUI.BuildTransactionContractVersion = 1
RSUI.PreflightContractVersion = 1
RSUI.LogicalIdGenerationFenceVersion = 1
RSUI.typeValidators = {}
RSUI.consumedLogicalIds = {}

local function CurrentBuildScope(self)
    local stack = self.buildScopeStack
    local scope = stack and stack[#stack] or nil
    if scope ~= nil and tonumber(scope.generation) ~= tonumber(S.Generation) then return nil end
    return scope
end

local function RecordBuildFailure(self, spec, reason)
    local scope = CurrentBuildScope(self)
    if scope == nil or scope.strict ~= true or type(spec) ~= "table" or spec.buildOptional == true then return end
    scope.failed = true
    if scope.failure == nil then scope.failure = tostring(reason or "component build failed") end
end

local function RemoveArrayValue(list, value, entryField)
    if type(list) ~= "table" then return 0 end
    local removed = 0
    for index = #list, 1, -1 do
        local entry = list[index]
        local candidate = entryField ~= nil and type(entry) == "table" and entry[entryField] or entry
        if candidate == value then table.remove(list, index); removed = removed + 1 end
    end
    return removed
end

function RSUI:BeginBuildScope(label)
    self.buildScopeSerial = (tonumber(self.buildScopeSerial) or 0) + 1
    local parent = CurrentBuildScope(self)
    local scopeLabel = tostring(label or "build")
    local scope = {
        id = self.buildScopeSerial, label = scopeLabel, generation = S.Generation,
        strict = scopeLabel:sub(1, 5) == "page:" or scopeLabel:sub(1, 7) == "widget:"
            or scopeLabel:sub(1, 13) == "window_shell:" or scopeLabel:sub(1, 18) == "window_appearance:"
            or scopeLabel == "modal_host" or scopeLabel == "main_shell",
        failed = false, failure = nil,
        parent = parent, components = {}, widgets = {}, cleanups = {}, closed = false,
    }
    self.buildScopeStack[#self.buildScopeStack + 1] = scope
    self.metrics.buildScopesStarted = (tonumber(self.metrics.buildScopesStarted) or 0) + 1
    return scope
end

function RSUI:TrackBuildComponent(component)
    local scope = CurrentBuildScope(self)
    if scope == nil or type(component) ~= "table" then return component end
    if component._rsBuildScope ~= scope then
        scope.components[#scope.components + 1] = component
        component._rsBuildScope = scope
    end
    return component
end

function RSUI:TrackBuildWidget(widget)
    local scope = CurrentBuildScope(self)
    if scope == nil or widget == nil then return widget end
    if widget.rsBuildScope ~= scope then
        scope.widgets[#scope.widgets + 1] = widget
        pcall(function() widget.rsBuildScope = scope end)
    end
    return widget
end

function RSUI:TrackBuildCleanup(fn)
    local scope = CurrentBuildScope(self)
    if scope == nil or type(fn) ~= "function" then return false end
    scope.cleanups[#scope.cleanups + 1] = fn
    return true
end

function RSUI:DetachComponent(component)
    if type(component) ~= "table" then return false end
    local parent = component.parentComponent
    if type(parent) ~= "table" then return false end
    RemoveArrayValue(parent.children, component)
    RemoveArrayValue(parent.slots, component, "child")
    if parent.content == component then parent.content = nil end
    if parent.builtChildren ~= nil then RemoveArrayValue(parent.builtChildren, component) end
    component.parentComponent = nil
    if type(parent.InvalidateMeasure) == "function" then pcall(parent.InvalidateMeasure, parent, "build_rollback") end
    return true
end

local function RollbackBuildScope(self, scope)
    for index = #scope.cleanups, 1, -1 do
        local ok = pcall(scope.cleanups[index])
        if not ok then self.metrics.buildScopeCleanupFailures = (tonumber(self.metrics.buildScopeCleanupFailures) or 0) + 1 end
    end
    for index = #scope.components, 1, -1 do
        local component = scope.components[index]
        if type(component) == "table" then
            self:DetachComponent(component)
            if type(component.Release) == "function" then
                local ok = pcall(component.Release, component)
                if ok then self.metrics.buildScopeComponentsReleased = (tonumber(self.metrics.buildScopeComponentsReleased) or 0) + 1 end
            end
            if component._rsBuildScope == scope then component._rsBuildScope = nil end
        end
    end
    for index = #scope.widgets, 1, -1 do
        local widget = scope.widgets[index]
        if widget ~= nil then
            local owner = nil
            pcall(function() owner = widget.rsUiOwner end)
            -- UI:SetVisible() is the only V3 visibility Authority. A cache-hit
            -- no-op must never be interpreted as permission to raw Show(false).
            if type(UI.SetVisible) == "function" then UI:SetVisible(widget, false, owner) end
            self.metrics.buildScopeWidgetsHidden = (tonumber(self.metrics.buildScopeWidgetsHidden) or 0) + 1
            pcall(function() if widget.rsBuildScope == scope then widget.rsBuildScope = nil end end)
        end
    end
    self.metrics.buildScopesRolledBack = (tonumber(self.metrics.buildScopesRolledBack) or 0) + 1
end

function RSUI:EndBuildScope(scope, commit)
    if type(scope) ~= "table" or scope.closed == true then return false, "invalid build scope" end
    local stack = self.buildScopeStack
    if stack[#stack] ~= scope then
        -- A leaked nested scope previously poisoned the whole Generation because
        -- the outer caller could not close in stack order. Recover fail-closed:
        -- rollback every descendant plus the requested scope, then report a hard
        -- transaction error. This preserves Native quarantine while guaranteeing
        -- activeBuildScopes returns to a consistent depth.
        local targetIndex = nil
        for index = #stack, 1, -1 do
            if stack[index] == scope then targetIndex = index; break end
        end
        if targetIndex == nil then return false, "build scope close order violation: scope not active" end
        self.metrics.buildScopeCloseOrderRecoveries = (tonumber(self.metrics.buildScopeCloseOrderRecoveries) or 0) + 1
        local detail = "build scope close order violation recovered: " .. tostring(scope.label or scope.id or "?")
        for index = #stack, targetIndex, -1 do
            local leaked = stack[index]
            stack[index] = nil
            if type(leaked) == "table" and leaked.closed ~= true then
                leaked.closed = true
                leaked.failed = true
                leaked.failure = leaked.failure or detail
                RollbackBuildScope(self, leaked)
            end
        end
        return false, detail
    end
    stack[#stack] = nil
    scope.closed = true

    local rejectedCommit = commit == true and scope.failed == true
    if rejectedCommit then commit = false end

    if commit == true then
        local parent = scope.parent
        if type(parent) == "table" and parent.closed ~= true then
            for _, component in ipairs(scope.components) do
                parent.components[#parent.components + 1] = component
                if type(component) == "table" then component._rsBuildScope = parent end
            end
            for _, widget in ipairs(scope.widgets) do
                parent.widgets[#parent.widgets + 1] = widget
                pcall(function() widget.rsBuildScope = parent end)
            end
            for _, cleanup in ipairs(scope.cleanups) do parent.cleanups[#parent.cleanups + 1] = cleanup end
        else
            for _, component in ipairs(scope.components) do
                if type(component) == "table" and component._rsBuildScope == scope then component._rsBuildScope = nil end
            end
            for _, widget in ipairs(scope.widgets) do pcall(function() if widget.rsBuildScope == scope then widget.rsBuildScope = nil end end) end
        end
        self.metrics.buildScopesCommitted = (tonumber(self.metrics.buildScopesCommitted) or 0) + 1
        return true
    end

    RollbackBuildScope(self, scope)
    if rejectedCommit then return false, tostring(scope.failure or "strict build scope failed") end
    return true
end

-- Safe synchronous builder transaction. Callers no longer need to manually pair
-- BeginBuildScope/EndBuildScope across every return/error path. The wrapper also
-- benefits from EndBuildScope's close-order recovery if a nested builder leaks.
function RSUI:WithBuildScope(label, fn, options)
    if type(fn) ~= "function" then return false, nil, "build transaction callback required" end
    options = type(options) == "table" and options or {}
    self.metrics.buildTransactions = (tonumber(self.metrics.buildTransactions) or 0) + 1
    local scope = self:BeginBuildScope(label)
    local packed = nil
    local function Pack(...) local values = { ... }; values.n = select("#", ...); return values end
    local ok, trace = xpcall(function() packed = Pack(fn(scope)) end, S.SafeTraceback)
    local first = packed and packed[1] or nil
    local requireTruthy = options.requireTruthy ~= false
    local callbackSucceeded = ok == true and (requireTruthy ~= true or (first ~= nil and first ~= false))
    if ok == true and callbackSucceeded ~= true and scope.failed ~= true then
        scope.failed = true
        scope.failure = tostring((packed and packed[2]) or options.failure or "build transaction callback rejected")
    end
    local committed, scopeErr = self:EndBuildScope(scope, callbackSucceeded == true)
    if ok ~= true or committed ~= true or callbackSucceeded ~= true then
        self.metrics.buildTransactionFailures = (tonumber(self.metrics.buildTransactionFailures) or 0) + 1
        local detail
        if ok == true then
            detail = scopeErr or (packed and packed[2]) or scope.failure
        elseif scope.failure ~= nil then
            -- Preserve the first RSUI component failure as the primary cause.
            -- The xpcall trace remains available as secondary context without
            -- replacing the actionable preflight/native reason.
            detail = tostring(scope.failure) .. " | secondary=" .. tostring(trace or "callback exception")
        else
            detail = trace
        end
        return false, nil, tostring(detail or "build transaction failed")
    end
    return true, unpack(packed or {}, 1, packed and packed.n or 0)
end

RSUI.BuildTransaction = RSUI.WithBuildScope

S.RSUI = RSUI
UI.RSUI = RSUI

-- Semantic state vocabulary is shared across all component families. Native
-- hover/pressed feedback remains owned by the game's button implementation;
-- these states describe business-visible presentation state only.
RSUI.State = {
    Normal = "normal",
    Disabled = "disabled",
    Selected = "selected",
    Error = "error",
    ReadOnly = "readonly",
}

-- UMG-compatible layout visibility.  Legacy SetVisible(false) maps to
-- Collapsed so existing callers keep the old "does not consume layout"
-- behavior. Hidden is new: it consumes layout but does not paint.
RSUI.Visibility = {
    Visible = "visible",
    Hidden = "hidden",
    Collapsed = "collapsed",
}

local function NormalizeVisibility(value, legacyVisible)
    if value == nil then
        return legacyVisible == false and RSUI.Visibility.Collapsed or RSUI.Visibility.Visible
    end
    local v = tostring(value):lower()
    if v == "hidden" then return RSUI.Visibility.Hidden end
    if v == "collapsed" or v == "collapse" then return RSUI.Visibility.Collapsed end
    return RSUI.Visibility.Visible
end

local Base = {}
Base.__index = Base

local function NormalizeId(value)
    local id = tostring(value or "")
    id = id:gsub("[\r\n]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if id == "" then return nil end
    return id
end

local function SafeInvoke(label, fn, ...)
    if type(fn) ~= "function" then return true, nil end
    local args = { ... }
    local argc = select("#", ...)
    local result = nil
    local ok, err = xpcall(function()
        result = { fn(unpack(args, 1, argc)) }
    end, S.SafeTraceback)
    if not ok then
        RSUI.metrics.errors = RSUI.metrics.errors + 1
        if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Error) == "function" then
            S.DiagnosticsManager:Error("ui", "RSUI_CALLBACK_ERROR", "RSUI 回调执行失败", {
                label = tostring(label or "callback"),
                error = tostring(err),
            })
        end
        return false, err
    end
    return true, result and result[1] or nil
end

local function TouchType(kind)
    local row = RSUI.metrics.byType[kind]
    if row == nil then
        row = { created = 0, rendered = 0, layouts = 0, events = 0, releases = 0, errors = 0 }
        RSUI.metrics.byType[kind] = row
    end
    return row
end

function RSUI:_Count(kind, field, amount)
    amount = tonumber(amount) or 1
    self.metrics[field] = (tonumber(self.metrics[field]) or 0) + amount
    local row = TouchType(tostring(kind or "Unknown"))
    row[field] = (tonumber(row[field]) or 0) + amount
end

function RSUI:NewComponent(kind, spec, root)
    spec = type(spec) == "table" and spec or {}
    local id = NormalizeId(spec.id)
    if id == nil then return nil, "id_required" end
    local parent = spec.parent
    local component = setmetatable({
        id = id,
        kind = tostring(kind or "Component"),
        spec = spec,
        parent = parent,
        root = root,
        owner = root and root.rsUiOwner or (parent and parent.rsUiOwner) or nil,
        visibility = NormalizeVisibility(spec.visibility, spec.visible),
        visible = NormalizeVisibility(spec.visibility, spec.visible) ~= RSUI.Visibility.Collapsed,
        viewportVisible = true,
        enabled = spec.enabled ~= false,
        released = false,
        children = {},
        state = {},
        measureDirty = true,
        layoutDirty = true,
        invalidationReason = "create",
        layoutHost = spec.layoutHost,
    }, Base)
    self:_Count(component.kind, "created", 1)
    if root ~= nil and tonumber(root.rsBaseFontSize) ~= nil then self.typographyComponents[component] = true end
    self:TrackBuildComponent(component)
    return component
end

-- Typography is a low-frequency application setting, but changing it alters
-- the native line metrics of every styled RSUI label. Keep a weak set of only
-- typography-bearing components and invalidate their Measure chain once. This
-- is event-driven (settings/resolution changes only) and never runs from Tick.
function RSUI:InvalidateTypography(reason)
    local invalidated = 0
    for component in pairs(self.typographyComponents) do
        if type(component) == "table" and component.released ~= true and type(component.InvalidateMeasure) == "function" then
            component:InvalidateMeasure(reason or "typography_changed")
            invalidated = invalidated + 1
        end
    end
    self.metrics.typographyInvalidations = (tonumber(self.metrics.typographyInvalidations) or 0) + invalidated
    return invalidated
end

function Base:GetRoot()
    return self.root
end

function Base:GetOwner()
    return self.owner
end

function Base:IsReleased()
    return self.released == true
end

-- Native RSUI widgets are created under a physical parent and the RU client has
-- no validated generic reparent operation. Logical parent changes therefore
-- cannot be treated like UMG RemoveFromParent/AddChild: doing so would create a
-- split authority where layout believes one parent owns a widget while the
-- native object remains owned/clipped by another. Attachment is consequently
-- single-parent and fail-closed for the whole Generation.
function RSUI:ValidateAttachment(parent, component)
    if not self:IsComponent(parent) then return false, "attachment_parent_component_required" end
    if not self:IsComponent(component) then return false, "attachment_child_component_required" end
    if parent.released == true then return false, "attachment_parent_released" end
    if component.released == true then return false, "attachment_child_released" end
    if parent == component then
        self.metrics.attachmentRejects = (tonumber(self.metrics.attachmentRejects) or 0) + 1
        self.metrics.attachmentCycleRejects = (tonumber(self.metrics.attachmentCycleRejects) or 0) + 1
        return false, "attachment_cycle:self"
    end
    local existing = component.parentComponent
    if existing ~= nil and existing ~= parent then
        self.metrics.attachmentRejects = (tonumber(self.metrics.attachmentRejects) or 0) + 1
        self.metrics.attachmentParentConflicts = (tonumber(self.metrics.attachmentParentConflicts) or 0) + 1
        return false, "reparent_not_supported:" .. tostring(component.id or "?")
    end
    local ancestor, guard = parent, 0
    while type(ancestor) == "table" and guard < 64 do
        if ancestor == component then
            self.metrics.attachmentRejects = (tonumber(self.metrics.attachmentRejects) or 0) + 1
            self.metrics.attachmentCycleRejects = (tonumber(self.metrics.attachmentCycleRejects) or 0) + 1
            return false, "attachment_cycle:" .. tostring(component.id or "?")
        end
        ancestor = ancestor.parentComponent
        guard = guard + 1
    end
    if guard >= 64 and ancestor ~= nil then
        self.metrics.attachmentRejects = (tonumber(self.metrics.attachmentRejects) or 0) + 1
        self.metrics.attachmentCycleRejects = (tonumber(self.metrics.attachmentCycleRejects) or 0) + 1
        return false, "attachment_ancestor_guard"
    end

    -- Native parent identity is immutable for the whole component generation.
    -- Validate it on every attach path, including normal RSUI:Create().  This
    -- catches a buggy/custom factory that creates its native root under the
    -- wrong content host even if the logical parentComponent already points at
    -- the requested owner.
    local expectedNative = select(1, self:ResolveParent(parent))
    if expectedNative ~= nil and component.parent ~= nil and component.parent ~= expectedNative then
        self.metrics.attachmentRejects = (tonumber(self.metrics.attachmentRejects) or 0) + 1
        self.metrics.attachmentNativeParentConflicts = (tonumber(self.metrics.attachmentNativeParentConflicts) or 0) + 1
        return false, "attachment_native_parent_mismatch:" .. tostring(component.id or "?")
    end
    return true
end

function Base:GetParentComponent() return self.parentComponent end
function Base:CanReparentTo(parent)
    if self.parentComponent == parent then return true, "same_parent" end
    return false, "native_reparent_unverified"
end

function Base:AddChild(component, slot)
    if self.released == true or type(component) ~= "table" then return nil, false, "attachment_invalid" end
    local valid, attachErr = RSUI:ValidateAttachment(self, component)
    if valid ~= true then return nil, false, attachErr end
    for _, child in ipairs(self.children) do
        if child == component then
            if slot ~= nil then component.slot = slot end
            self:InvalidateMeasure("child_slot_update")
            return component, true, "already_attached"
        end
    end
    self.children[#self.children + 1] = component
    component.parentComponent = self
    if slot ~= nil then component.slot = slot end

    -- Interaction containers (most importantly ScrollBox) may need to bind
    -- behavior to descendants created after the container itself. Notify the
    -- nearest interested ancestor once; nested containers therefore keep
    -- ownership of their own input instead of leaking wheel events outward.
    local ancestor, guard = self, 0
    while type(ancestor) == "table" and guard < 64 do
        if type(ancestor.OnDescendantAdded) == "function" then
            local ok, consumed = pcall(ancestor.OnDescendantAdded, ancestor, component)
            if ok and consumed == true then break end
        end
        ancestor = ancestor.parentComponent
        guard = guard + 1
    end

    -- Appearance channels are inherited through the logical component tree.
    -- This is event-driven: newly virtualized rows inherit the current visual
    -- policy once when they are attached; no Tick/tree scan is introduced.
    if (self.appearanceBackgroundOpacity ~= nil or self.appearanceTextOpacity ~= nil)
        and type(RSUI.ApplyOpacityChannels) == "function" then
        RSUI:ApplyOpacityChannels(component, self.appearanceBackgroundOpacity, self.appearanceTextOpacity)
    end
    if self.appearanceFontScale ~= nil and type(RSUI.ApplyFontScale) == "function" then
        RSUI:ApplyFontScale(component, self.appearanceFontScale)
    end

    self:InvalidateMeasure("child_added")
    return component, true
end

-- Public child removal is terminal for the current Generation. The physical
-- widget cannot be safely reparented/recreated under the same identity, so a
-- removal always releases/hides the subtree instead of returning a detachable
-- widget that callers could mount elsewhere.
function Base:RemoveChild(component)
    if self.released == true or type(component) ~= "table" or component.parentComponent ~= self then
        return false, "child_not_owned"
    end
    RSUI:DetachComponent(component)
    local released = type(component.Release) == "function" and (tonumber(component:Release()) or 0) or 0
    RSUI.metrics.childRemovals = (tonumber(RSUI.metrics.childRemovals) or 0) + 1
    self:InvalidateMeasure("child_removed")
    return true, released
end

-- Applies independent drawable/text alpha channels to an RSUI subtree. Whole-
-- window opacity remains Native Windowing authority and multiplies these local
-- channels. Calls are settings/lifecycle driven, never per-frame.
function RSUI:ApplyOpacityChannels(component, backgroundOpacity, textOpacity)
    if not self:IsComponent(component) or component.released == true then return false end
    local background = backgroundOpacity ~= nil and math.max(0.0, math.min(1.0, tonumber(backgroundOpacity) or 1.0)) or nil
    local text = textOpacity ~= nil and math.max(0.0, math.min(1.0, tonumber(textOpacity) or 1.0)) or nil
    local theme = S.Theme
    local visited = 0
    local function Walk(node)
        if not RSUI:IsComponent(node) or node.released == true then return end
        visited = visited + 1
        if background ~= nil then
            node.appearanceBackgroundOpacity = background
            if theme ~= nil and type(theme.SetBackgroundOpacity) == "function" then theme:SetBackgroundOpacity(node.root, background) end
        end
        if text ~= nil then
            node.appearanceTextOpacity = text
            if type(node.ApplyTextOpacity) == "function" then
                node:ApplyTextOpacity(text)
            elseif theme ~= nil and type(theme.SetTextOpacity) == "function" then
                theme:SetTextOpacity(node.root, text)
            end
        end
        for _, child in ipairs(type(node.children) == "table" and node.children or {}) do Walk(child) end
    end
    Walk(component)
    return visited > 0
end

-- Applies a bounded local typography multiplier to an RSUI subtree. Global
-- addon/font scale remains Theme authority; this local multiplier is intended
-- for independently readable HUD surfaces. Native widgets keep their design
-- `rsBaseFontSize`, so repeated changes are drift-free. Virtualized descendants
-- inherit the multiplier from Base:AddChild instead of requiring a permanent
-- tree scan.
function RSUI:ApplyFontScale(component, fontScale)
    if not self:IsComponent(component) or component.released == true then return false end
    local scale = math.max(0.50, math.min(2.00, tonumber(fontScale) or 1.0))
    local theme = S.Theme
    local visited = 0
    local function Walk(node)
        if not RSUI:IsComponent(node) or node.released == true then return end
        visited = visited + 1
        node.appearanceFontScale = scale
        node.measureDirty = true
        node.layoutDirty = true
        local root = node.root
        if root ~= nil then
            root.rsLocalFontScale = scale
            local base = tonumber(root.rsBaseFontSize)
            if base ~= nil and type(UI.SetFontSize) == "function" then
                local target = base * scale
                if type(theme) == "table" and type(theme.ResolveFontSize) == "function" then
                    target = theme:ResolveFontSize(base, scale)
                end
                UI:SetFontSize(root, target, node.owner)
            end
        end
        if type(node.ApplyLocalFontScale) == "function" then pcall(function() node:ApplyLocalFontScale(scale) end) end
        for _, child in ipairs(type(node.children) == "table" and node.children or {}) do Walk(child) end
    end
    Walk(component)
    self.metrics.fontScaleApplications = (tonumber(self.metrics.fontScaleApplications) or 0) + visited
    component:InvalidateMeasure("local_font_scale")
    return visited > 0
end

RSUI.FloatingFontScaleContractVersion = 1

-- Containers may override this when their logical content host differs from
-- their visual root.  Business code can therefore pass an RSUI Component as
-- `parent` without reaching into `.root` / `.body` implementation details.
function Base:GetContentRoot()
    return self.root
end

function Base:_ApplyVisibility()
    if self.released == true or self.root == nil then return false end
    local final = self.visibility == RSUI.Visibility.Visible and self.viewportVisible ~= false
    if type(UI.SetVisible) == "function" then UI:SetVisible(self.root, final, self.owner) end
    return final
end

function Base:GetVisibility()
    return self.visibility or (self.visible == false and RSUI.Visibility.Collapsed or RSUI.Visibility.Visible)
end

function Base:IsCollapsed() return self:GetVisibility() == RSUI.Visibility.Collapsed end
function Base:IsHidden() return self:GetVisibility() == RSUI.Visibility.Hidden end
function Base:IsVisible() return self:GetVisibility() == RSUI.Visibility.Visible end
function Base:ParticipatesInLayout() return self:GetVisibility() ~= RSUI.Visibility.Collapsed end

function Base:SetVisibility(visibility)
    if self.released == true or self.root == nil then return false end
    local nextValue = NormalizeVisibility(visibility, true)
    local previous = self:GetVisibility()
    if nextValue == previous then
        self:_ApplyVisibility()
        return false
    end
    local previousLayout = previous ~= RSUI.Visibility.Collapsed
    local nextLayout = nextValue ~= RSUI.Visibility.Collapsed
    self.visibility = nextValue
    -- Legacy .visible means layout participation. This preserves every existing
    -- Panel check while adding Hidden without changing old SetVisible(false).
    self.visible = nextLayout
    self:_ApplyVisibility()
    RSUI.metrics.visibilityChanges = (tonumber(RSUI.metrics.visibilityChanges) or 0) + 1
    if previousLayout ~= nextLayout then
        self:InvalidateMeasure("visibility:" .. nextValue)
    else
        self:InvalidateLayout("visibility:" .. nextValue)
    end
    return true
end

function Base:SetVisible(visible)
    -- Compatibility: false historically removed a widget from layout.
    return self:SetVisibility(visible == true and RSUI.Visibility.Visible or RSUI.Visibility.Collapsed)
end

-- Viewport visibility is presentation-only. ScrollBox / WidgetSwitcher can
-- hide a child without mutating its logical visibility, so Measure can still
-- inspect it on the next layout pass.
function Base:SetViewportVisible(visible)
    if self.released == true or self.root == nil then return false end
    self.viewportVisible = visible ~= false
    return self:_ApplyVisibility()
end

function Base:SetEnabled(enabled)
    if self.released == true then return false end
    -- Revision is interaction metadata, not Domain state.  ActionRunner uses it
    -- to distinguish its own temporary Busy disable from a business refresh
    -- that deliberately changed the final enabled state while the action ran.
    self.enabledRevision = (tonumber(self.enabledRevision) or 0) + 1
    self.enabled = enabled ~= false
    if self.root ~= nil and type(UI.SetEnabled) == "function" then UI:SetEnabled(self.root, self.enabled, self.owner) end
    if self.root ~= nil and type(UI.SetAlpha) == "function" then
        local disabledAlpha = S.UITokens and S.UITokens:Number("alpha.disabled", 0.45) or 0.45
        UI:SetAlpha(self.root, self.enabled and 1 or disabledAlpha, self.owner)
    end
    return self.enabled
end

function Base:SetSemanticState(state)
    state = tostring(state or RSUI.State.Normal)
    self.semanticState = state
    if state == RSUI.State.Disabled then self:SetEnabled(false)
    elseif state == RSUI.State.Normal and self.enabled == false then self:SetEnabled(true) end
    if type(self.SetSelected) == "function" then
        if state == RSUI.State.Selected then self:SetSelected(true)
        elseif state == RSUI.State.Normal then self:SetSelected(false) end
    end
    return state
end



function Base:SetLayoutHost(host)
    self.layoutHost = host
    return self
end

function Base:GetLayoutHost()
    local current = self
    local guard = 0
    while type(current) == "table" and guard < 64 do
        if current.layoutHost ~= nil then return current.layoutHost end
        current = current.parentComponent
        guard = guard + 1
    end
    return nil
end

local function NotifyLayoutHost(component, reason, measureChanged)
    if type(component) ~= "table" then return false end
    local host = type(component.GetLayoutHost) == "function" and component:GetLayoutHost() or component.layoutHost
    if host == nil then return false end
    local fn = nil
    if type(host) == "function" then fn = host
    elseif type(host) == "table" then
        if measureChanged == true and type(host.InvalidateMeasure) == "function" then fn = function(...) return host:InvalidateMeasure(...) end
        elseif type(host.InvalidateLayout) == "function" then fn = function(...) return host:InvalidateLayout(...) end
        elseif type(host.ApplyLayout) == "function" then fn = function() return host:ApplyLayout(host.lastLayoutSpec or {}) end end
    end
    if type(fn) ~= "function" then return false end
    local ok = pcall(fn, tostring(reason or "rsui"), component)
    if ok then RSUI.metrics.externalLayoutInvalidations = (tonumber(RSUI.metrics.externalLayoutInvalidations) or 0) + 1 end
    return ok
end

local function FindLayoutRoot(component)
    local current = component
    local guard = 0
    while type(current) == "table" and current.parentComponent ~= nil and guard < 64 do
        current = current.parentComponent
        guard = guard + 1
    end
    return current
end

function RSUI:_ScheduleLayoutFlush()
    if self.layoutFlushScheduled == true then return true end
    local scheduler = S.Scheduler
    if scheduler == nil or type(scheduler.AddTask) ~= "function" then
        self.metrics.layoutFlushDeferrals = (tonumber(self.metrics.layoutFlushDeferrals) or 0) + 1
        return false
    end
    self.layoutFlushScheduled = true
    scheduler:RemoveTask(self.layoutFlushTaskName)
    scheduler:AddTask(self.layoutFlushTaskName, 50, function()
        -- One-shot: remove before flushing so an invalidation raised during this
        -- pass can schedule the next bounded pass instead of being lost.
        if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then
            S.Scheduler:RemoveTask(RSUI.layoutFlushTaskName)
        end
        RSUI.layoutFlushScheduled = false
        RSUI:FlushLayoutQueue(24)
    end, true, self, "P2", 1)
    return true
end

function RSUI:QueueLayout(component, reason)
    if not self:IsComponent(component) or component.released == true then return false end
    local root = FindLayoutRoot(component)
    if not self:IsComponent(root) or root.released == true then return false end
    local width, height = tonumber(root.width), tonumber(root.height)
    -- Creation-time invalidations are expected.  The first explicit layout will
    -- establish geometry; only established roots need an automatic reflow.
    if width == nil or height == nil or width <= 0 or height <= 0 then return false end
    if type(root.spec) == "table" and root.spec.autoRelayout == false then return false end
    if root:IsCollapsed() then return false end
    local entry = self.layoutQueue[root]
    if entry == nil then
        self.metrics.layoutRootsQueued = (tonumber(self.metrics.layoutRootsQueued) or 0) + 1
        self.layoutEpoch = (tonumber(self.layoutEpoch) or 0) + 1
        self.metrics.invalidationEpochs = (tonumber(self.metrics.invalidationEpochs) or 0) + 1
        local now = S.NowMs and S.NowMs() or 0
        entry = {
            epoch = self.layoutEpoch,
            reason = tostring(reason or root.invalidationReason or "dirty"),
            queuedAtMs = now,
            lastInvalidatedAtMs = now,
        }
        self.layoutQueue[root] = entry
        root.layoutQueuedEpoch = entry.epoch
    else
        entry.reason = tostring(reason or root.invalidationReason or entry.reason or "dirty")
        entry.lastInvalidatedAtMs = S.NowMs and S.NowMs() or entry.lastInvalidatedAtMs or 0
    end
    if self.layoutFlushRunning ~= true then self:_ScheduleLayoutFlush() end
    return true
end

function RSUI:GetLayoutQueueSnapshot()
    local now = S.NowMs and S.NowMs() or 0
    local snapshot = {
        pending = 0, fresh = 0, stale = 0, unscheduled = 0,
        flushScheduled = self.layoutFlushScheduled == true,
        flushRunning = self.layoutFlushRunning == true,
        oldestAgeMs = 0, details = {},
    }
    for root, entry in pairs(type(self.layoutQueue) == "table" and self.layoutQueue or {}) do
        snapshot.pending = snapshot.pending + 1
        local queuedAt = tonumber(type(entry) == "table" and entry.queuedAtMs) or now
        local age = math.max(0, now - queuedAt)
        if age > snapshot.oldestAgeMs then snapshot.oldestAgeMs = age end
        -- A one-shot 50 ms scheduler turn and one bounded stabilization pass are
        -- normal. Only roots that survive well beyond that window are stale.
        if age > 1000 then snapshot.stale = snapshot.stale + 1 else snapshot.fresh = snapshot.fresh + 1 end
        if #snapshot.details < 8 then
            snapshot.details[#snapshot.details + 1] = {
                id = tostring(type(root) == "table" and (root.id or root.logicalId) or "?"),
                ageMs = age,
                reason = tostring(type(entry) == "table" and entry.reason or "dirty"),
            }
        end
    end
    if snapshot.pending > 0 and snapshot.flushScheduled ~= true and snapshot.flushRunning ~= true then
        snapshot.unscheduled = snapshot.pending
    end
    return snapshot
end

function RSUI:FlushLayoutQueue(maxRoots)
    if self.layoutFlushRunning == true then return 0 end
    self.layoutFlushRunning = true
    self.metrics.layoutFlushes = (tonumber(self.metrics.layoutFlushes) or 0) + 1

    -- A layout pass is allowed to create/bind pooled descendants. Those new
    -- children legitimately invalidate their ancestors while the ancestor is
    -- already being arranged. Older code deferred the resulting second pass to
    -- another 50ms scheduler turn, leaving an observable dirty tree between
    -- passes. Stabilize within the same explicit flush, but keep a strict total
    -- reflow budget so data-driven UI can never turn this into an unbounded loop.
    local scratch = self.layoutFlushScratch
    local budget = math.max(1, math.min(tonumber(maxRoots) or 24, 64))
    local maxPasses = 3
    local reflowed, pass = 0, 0

    while budget > 0 and next(self.layoutQueue) ~= nil and pass < maxPasses do
        pass = pass + 1
        for i = #scratch, 1, -1 do scratch[i] = nil end
        for root in pairs(self.layoutQueue) do
            scratch[#scratch + 1] = root
            if #scratch >= budget then break end
        end
        if #scratch == 0 then break end

        for _, root in ipairs(scratch) do
            self.layoutQueue[root] = nil
            budget = budget - 1
            if self:IsComponent(root) and root.released ~= true and not root:IsCollapsed() then
                local width, height = tonumber(root.width), tonumber(root.height)
                if width and height and width > 0 and height > 0 and root:IsLayoutDirty() then
                    local ok = pcall(function()
                        root:LayoutIfNeeded(tonumber(root.x) or 0, tonumber(root.y) or 0, width, height, false)
                    end)
                    if ok then
                        reflowed = reflowed + 1
                        self.metrics.layoutRootsReflowed = (tonumber(self.metrics.layoutRootsReflowed) or 0) + 1
                    else
                        self.metrics.errors = (tonumber(self.metrics.errors) or 0) + 1
                    end
                end
            end
            if budget <= 0 then break end
        end
    end

    if pass > 1 then
        self.metrics.layoutStabilizationPasses = (tonumber(self.metrics.layoutStabilizationPasses) or 0) + (pass - 1)
    end
    self.layoutFlushRunning = false

    -- A persistent invalidator, or a queue larger than the bounded budget, is
    -- deliberately deferred instead of spinning synchronously.
    if next(self.layoutQueue) ~= nil then
        self.metrics.layoutUnstableDeferrals = (tonumber(self.metrics.layoutUnstableDeferrals) or 0) + 1
        self:_ScheduleLayoutFlush()
    end
    return reflowed
end

-- Coalescing is legal only while the root still owns a pending transaction.
-- A sticky dirty bit on a collapsed/reactivated child is not transaction
-- authority; this pure predicate is also exercised by sequence diagnostics.
function RSUI:ShouldCoalesceInvalidation(rootQueued, parent, measureChanged)
    if rootQueued ~= true or type(parent) ~= "table" then return false end
    if measureChanged == true then return parent.measureDirty == true or parent.layoutDirty == true end
    return parent.layoutDirty == true
end

local function PropagateInvalidation(component, reason, measureChanged)
    if type(component) ~= "table" or component.released == true then return false end
    local root = FindLayoutRoot(component)
    local rootQueued = RSUI.layoutQueue[root] ~= nil
    local firstChanged = false
    local current = component
    local guard = 0
    while type(current) == "table" and guard < 64 do
        guard = guard + 1
        local wasMeasureDirty = current.measureDirty == true
        local wasLayoutDirty = current.layoutDirty == true
        if measureChanged == true then current.measureDirty = true end
        current.layoutDirty = true
        current.invalidationReason = tostring(reason or (measureChanged and "measure" or "layout"))
        current.invalidationEpoch = tonumber(root and root.layoutQueuedEpoch) or tonumber(RSUI.layoutEpoch) or 0
        local becameDirty = measureChanged == true and not wasMeasureDirty or not wasLayoutDirty
        if becameDirty then
            RSUI.metrics.invalidations = (tonumber(RSUI.metrics.invalidations) or 0) + 1
            if current == component then firstChanged = true end
        end

        local parent = current.parentComponent
        if parent == nil then
            NotifyLayoutHost(current, current.invalidationReason, measureChanged == true)
            RSUI:QueueLayout(current, current.invalidationReason)
            break
        end

        -- Coalesce only when the root still owns a pending layout transaction.
        -- Sticky child dirty bits are NOT enough: after a parent has already
        -- arranged (or a Collapsed child is reactivated) the queue may be empty,
        -- in which case propagation must reach the root again. During an active
        -- flush the root entry is removed before Layout, so a fresh invalidation
        -- correctly re-queues a stabilization pass.
        local parentAlreadyDirty = RSUI:ShouldCoalesceInvalidation(rootQueued, parent, measureChanged)
        if parentAlreadyDirty then
            RSUI.metrics.invalidationCoalesces = (tonumber(RSUI.metrics.invalidationCoalesces) or 0) + 1
            break
        end
        current = parent
    end
    return firstChanged
end

function Base:InvalidateLayout(reason)
    return PropagateInvalidation(self, tostring(reason or "layout"), false)
end

function Base:InvalidateMeasure(reason)
    return PropagateInvalidation(self, tostring(reason or "measure"), true)
end

function Base:IsLayoutDirty()
    return self.measureDirty == true or self.layoutDirty == true
end

function Base:GetSlot()
    return self.slot
end


local function ClampSize(value, minimum, maximum)
    local v = math.max(0, tonumber(value) or 0)
    if tonumber(minimum) ~= nil then v = math.max(v, tonumber(minimum)) end
    if tonumber(maximum) ~= nil then v = math.min(v, tonumber(maximum)) end
    return v
end

function Base:Measure(availableWidth, availableHeight)
    local spec = type(self.spec) == "table" and self.spec or {}
    local width = tonumber(spec.desiredWidth) or tonumber(spec.width) or tonumber(self.width)
    local height = tonumber(spec.desiredHeight) or tonumber(spec.height) or tonumber(self.height)
    if width == nil and self.root ~= nil and type(self.root.GetWidth) == "function" then pcall(function() width = self.root:GetWidth() end) end
    if height == nil and self.root ~= nil and type(self.root.GetHeight) == "function" then pcall(function() height = self.root:GetHeight() end) end
    width = ClampSize(width or 0, spec.minWidth, spec.maxWidth)
    height = ClampSize(height or 0, spec.minHeight, spec.maxHeight)
    if tonumber(availableWidth) ~= nil and spec.allowOverflow ~= true then width = math.min(width, math.max(0, tonumber(availableWidth))) end
    if tonumber(availableHeight) ~= nil and spec.allowOverflow ~= true then height = math.min(height, math.max(0, tonumber(availableHeight))) end
    self.desiredWidth, self.desiredHeight = width, height
    self.measureDirty = false
    return width, height
end

function Base:GetDesiredSize(availableWidth, availableHeight)
    return self:Measure(availableWidth, availableHeight)
end

function Base:SetSlot(slot)
    self.slot = type(slot) == "table" and slot or nil
    local parent = self.parentComponent
    if parent ~= nil and type(parent.UpdateChildSlot) == "function" then
        parent:UpdateChildSlot(self, self.slot)
    elseif parent ~= nil and type(parent.InvalidateMeasure) == "function" then
        parent:InvalidateMeasure("slot_changed")
    end
    return self
end

-- Commit the logical geometry after a component-specific native layout.
-- SetBounds owns the common native write path; adapters such as Dropdown,
-- Section and legacy Form containers perform specialized native writes and then
-- call CommitLayoutState so RSUI dirty state still has one authoritative end.
function Base:CommitLayoutState(x, y, width, height)
    if self.released == true then return false end
    self.x, self.y = tonumber(x) or 0, tonumber(y) or 0
    self.width, self.height = tonumber(width) or self.width, tonumber(height) or self.height
    self.layoutDirty = false
    self.lastArrangedWidth, self.lastArrangedHeight = self.width, self.height
    self.layoutRevision = (tonumber(self.layoutRevision) or 0) + 1
    return true
end

function Base:SetBounds(x, y, width, height)
    if self.released == true or self.root == nil then return false end
    if width ~= nil and height ~= nil and type(UI.SetExtent) == "function" then UI:SetExtent(self.root, width, height, self.owner) end
    if self.parent ~= nil and type(UI.SetAnchor) == "function" then UI:SetAnchor(self.root, self.parent, x or 0, y or 0, self.owner) end
    self:CommitLayoutState(x, y, width, height)
    RSUI:_Count(self.kind, "layouts", 1)
    return true
end

function Base:Layout(x, y, width, height)
    return self:SetBounds(x, y, width, height)
end

-- Dirty-only arrange helper. A parent may call this every time it performs a
-- layout pass; unchanged descendants will not re-run Layout or touch Native UI.
-- A bounds change always wins over the dirty flag.
function Base:LayoutIfNeeded(x, y, width, height, force)
    if self.released == true or self:IsCollapsed() then return false end
    local nx, ny = tonumber(x) or 0, tonumber(y) or 0
    local nw, nh = math.max(0, tonumber(width) or tonumber(self.width) or 0), math.max(0, tonumber(height) or tonumber(self.height) or 0)
    local boundsChanged = tonumber(self.x) ~= nx or tonumber(self.y) ~= ny or tonumber(self.width) ~= nw or tonumber(self.height) ~= nh
    local wasDirty = self:IsLayoutDirty() == true
    if self.measureDirty == true and type(self.Measure) == "function" then
        pcall(function() self:Measure(nw, nh) end)
    end
    if force ~= true and not boundsChanged and not wasDirty then
        RSUI.metrics.layoutSkips = (tonumber(RSUI.metrics.layoutSkips) or 0) + 1
        return false
    end
    RSUI.metrics.layoutPasses = (tonumber(RSUI.metrics.layoutPasses) or 0) + 1
    self:Layout(nx, ny, math.max(1, nw), math.max(1, nh))
    return true
end

function Base:Render()
    if self.released == true then return false end
    RSUI:_Count(self.kind, "rendered", 1)
    return true
end

function Base:On(widget, eventName, fn, label)
    if self.released == true or widget == nil or type(fn) ~= "function" then return false end
    local component = self
    local eventKey = tostring(eventName or "")
    if eventKey == "" then return false end
    local eventLabel = tostring(label or ("rsui:" .. self.id .. ":" .. eventKey))
    self._eventMux = self._eventMux or setmetatable({}, { __mode = "k" })
    local widgetMux = self._eventMux[widget]
    if widgetMux == nil then widgetMux = {}; self._eventMux[widget] = widgetMux end
    local channel = widgetMux[eventKey]
    if channel == nil then
        channel = { handlers = {}, installed = false }
        widgetMux[eventKey] = channel
    end
    channel.handlers[#channel.handlers + 1] = { fn = fn, label = eventLabel }
    RSUI.metrics.eventSubscriptions = (tonumber(RSUI.metrics.eventSubscriptions) or 0) + 1
    if channel.installed == true then return true end

    local bound = UI:SafeHandler(widget, eventKey, function(...)
        if component.released == true or component.enabled == false then return false end
        local currentWidgetMux = component._eventMux and component._eventMux[widget]
        local current = currentWidgetMux and currentWidgetMux[eventKey]
        if current == nil then return false end
        RSUI.metrics.eventDispatches = (tonumber(RSUI.metrics.eventDispatches) or 0) + 1
        RSUI:_Count(component.kind, "events", 1)
        local result = nil
        -- Snapshot the length so a callback that subscribes another handler does
        -- not execute that new subscription during the same native dispatch.
        local count = #current.handlers
        for index = 1, count do
            local entry = current.handlers[index]
            if entry ~= nil and type(entry.fn) == "function" then
                local ok, value = SafeInvoke(entry.label, entry.fn, ...)
                if not ok then
                    local row = TouchType(component.kind)
                    row.errors = (tonumber(row.errors) or 0) + 1
                elseif value ~= nil then
                    result = value
                end
            end
        end
        return result
    end, "rsui:mux:" .. self.id .. ":" .. eventKey)
    channel.installed = bound == true
    return channel.installed
end

function Base:Off(widget, eventName, labelOrFn)
    if self._eventMux == nil or widget == nil then return 0 end
    local widgetMux = self._eventMux[widget]
    local channel = widgetMux and widgetMux[tostring(eventName or "")]
    if channel == nil then return 0 end
    local removed = 0
    for index = #channel.handlers, 1, -1 do
        local entry = channel.handlers[index]
        if labelOrFn == nil or entry.fn == labelOrFn or entry.label == tostring(labelOrFn) then
            table.remove(channel.handlers, index)
            removed = removed + 1
        end
    end
    return removed
end

function Base:Release()
    if self.released == true then return 0 end
    -- Standalone child teardown must not leave strong references in a live
    -- parent's children/slots arrays. During recursive parent teardown the
    -- parent is already marked released and children are detached from a
    -- snapshot below, avoiding mutation-while-iterating skips.
    local parent = self.parentComponent
    if type(parent) == "table" and parent.released ~= true then RSUI:DetachComponent(self) end

    self.released = true
    RSUI.layoutQueue[self] = nil
    RSUI.typographyComponents[self] = nil
    -- Component lifetime is also scheduler lifetime. Interactive gestures are
    -- normally removed on mouse-up, but teardown may happen mid-gesture.
    if S.Scheduler ~= nil and type(S.Scheduler.RemoveOwner) == "function" then S.Scheduler:RemoveOwner(self) end
    local count = 0
    local children = self.children
    self.children = {}
    if type(self.slots) == "table" then self.slots = {} end
    if self.content ~= nil and type(self.content) == "table" and self.content.parentComponent == self then self.content = nil end
    if type(children) == "table" then
        for index = #children, 1, -1 do
            local child = children[index]
            if type(child) == "table" then
                if child.parentComponent == self then child.parentComponent = nil end
                if type(child.Release) == "function" then count = count + (tonumber(child:Release()) or 0) end
            end
        end
    end
    if self.root ~= nil and type(UI.SetVisible) == "function" then
        UI:SetVisible(self.root, false, self.owner)
        count = count + 1
    end
    -- Native widget destruction is intentionally NOT attempted here. The owner
    -- Lifecycle remains the release Authority and will release registered native
    -- handlers during dialog/HUD teardown.
    RSUI:_Count(self.kind, "releases", 1)
    return count
end

function Base:Describe()
    return {
        id = self.id,
        kind = self.kind,
        owner = self.owner,
        visible = self.visible == true,
        visibility = self:GetVisibility(),
        enabled = self.enabled == true,
        released = self.released == true,
        childCount = #self.children,
        viewportVisible = self.viewportVisible ~= false,
        desiredWidth = tonumber(self.desiredWidth),
        desiredHeight = tonumber(self.desiredHeight),
        x = tonumber(self.x), y = tonumber(self.y), width = tonumber(self.width), height = tonumber(self.height),
        measureDirty = self.measureDirty == true,
        layoutDirty = self.layoutDirty == true,
        invalidationReason = self.invalidationReason,
        overflow = tonumber(self.lastOverflow) or 0,
    }
end

local function CloneSpec(spec)
    local copy = {}
    for key, value in pairs(type(spec) == "table" and spec or {}) do copy[key] = value end
    return copy
end

function RSUI:IsComponent(value)
    return type(value) == "table" and type(value.GetRoot) == "function" and value.kind ~= nil
end

function RSUI:ResolveParent(parent)
    if not self:IsComponent(parent) then return parent, nil end
    local root = nil
    if type(parent.GetContentRoot) == "function" then
        local ok, value = pcall(function() return parent:GetContentRoot() end)
        if ok then root = value end
    end
    if root == nil and type(parent.GetRoot) == "function" then
        local ok, value = pcall(function() return parent:GetRoot() end)
        if ok then root = value end
    end
    return root or parent.root, parent
end

local function EnsurePublicFactory(self, name)
    if type(self[name]) == "function" then return true end
    local typeName = tostring(name or "")
    if typeName == "" then return false end
    self[typeName] = function(instance, spec) return instance:Create(typeName, spec) end
    return true
end

function RSUI:RegisterTypeValidator(name, validator)
    name = tostring(name or "")
    if name == "" or type(validator) ~= "function" then return false end
    self.typeValidators[name] = validator
    return true
end

function RSUI:ValidateSpec(name, spec)
    name = tostring(name or "")
    spec = type(spec) == "table" and spec or {}
    if NormalizeId(spec.id) == nil then return false, "id_required" end
    if spec.parent == nil and name ~= "SettingsPage" then return false, "parent_required" end
    -- Reject a reused logical id before any native constructor is attempted. The
    -- Native factory already fences the physical id, but this earlier fence keeps
    -- duplicate attempts out of the C++-boundary diagnostics entirely.
    local logicalId = tostring(spec.id)
    if self.consumedLogicalIds[logicalId] == true then
        return false, "logical_id_already_consumed_this_generation:" .. logicalId
    end
    if type(UI.controls) == "table" and UI.controls[logicalId] ~= nil then
        return false, "logical_id_already_registered:" .. logicalId
    end
    local validator = self.typeValidators[name]
    if type(validator) == "function" then
        local ok, valid, detail = xpcall(function() return validator(spec) end, S.SafeTraceback)
        if ok ~= true then return false, "preflight_exception:" .. tostring(valid) end
        if valid ~= true then return false, tostring(detail or "preflight_rejected") end
    end
    return true
end

function RSUI:RegisterType(name, factory, validator)
    name = tostring(name or "")
    if name == "" or type(factory) ~= "function" then return false end
    if self.types[name] ~= nil then
        self.metrics.duplicateTypeRegistrations = (tonumber(self.metrics.duplicateTypeRegistrations) or 0) + 1
        return false, "component_type_already_registered:" .. name
    end
    self.typeOrder[#self.typeOrder + 1] = name
    self.types[name] = factory
    if type(validator) == "function" then self.typeValidators[name] = validator end
    EnsurePublicFactory(self, name)
    return true
end

-- Intentional upgrades must be explicit. This removes load-order authority from
-- duplicate RegisterType calls while preserving backwards-compatible names.
function RSUI:ReplaceType(name, factory, validator)
    name = tostring(name or "")
    if name == "" or type(factory) ~= "function" then return false end
    if self.types[name] == nil then
        self.typeOrder[#self.typeOrder + 1] = name
    end
    self.types[name] = factory
    if type(validator) == "function" then self.typeValidators[name] = validator end
    EnsurePublicFactory(self, name)
    return true
end

function RSUI:Create(name, spec)
    name = tostring(name or "")
    local sourceSpec = type(spec) == "table" and spec or {}
    spec = CloneSpec(sourceSpec)
    local function Fail(reason)
        local detail = tostring(reason or "component build failed")
        RecordBuildFailure(self, spec, detail)
        local scope = CurrentBuildScope(self)
        -- A strict page/widget/modal transaction cannot commit after a required
        -- component has failed. Abort at the first failure instead of allowing
        -- downstream code to dereference nil parents/controls and overwrite the
        -- useful root cause with a secondary Lua exception. Explicit
        -- buildOptional components retain the old nil-return degradation path.
        if scope ~= nil and scope.strict == true and spec.buildOptional ~= true then
            self.metrics.strictBuildFailFast = (tonumber(self.metrics.strictBuildFailFast) or 0) + 1
            error("required_component_build_failed:" .. tostring(name or "?") .. ":"
                .. tostring(spec.id or "?") .. ":" .. detail, 0)
        end
        return nil, detail
    end
    local factory = self.types[name]
    if type(factory) ~= "function" then
        self.metrics.errors = self.metrics.errors + 1
        return Fail("unknown_component_type:" .. name)
    end
    local preflightOk, preflightErr = self:ValidateSpec(name, spec)
    if preflightOk ~= true then
        self.metrics.errors = self.metrics.errors + 1
        self.metrics.preflightFailures = (tonumber(self.metrics.preflightFailures) or 0) + 1
        return Fail(preflightErr)
    end
    -- Logical identities are generation-consumed before entering a factory.
    -- A failed/rolled-back Native build cannot safely reuse its old physical id
    -- because the RU client has no validated generic DestroyWidget operation.
    -- This turns a second attempt into a Lua preflight rejection instead of a
    -- C++ NativeObjectFactory duplicate collision.
    self.consumedLogicalIds[tostring(spec.id)] = true

    local nativeParent, componentParent = self:ResolveParent(spec.parent)
    if nativeParent == nil and name ~= "SettingsPage" then
        self.metrics.errors = self.metrics.errors + 1
        return Fail("parent_required")
    end
    spec.parentComponent = componentParent
    spec.parent = nativeParent

    local component, err
    local ok, trace = xpcall(function() component, err = factory(spec) end, S.SafeTraceback)
    if not ok then
        self.metrics.errors = self.metrics.errors + 1
        if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Error) == "function" then
            S.DiagnosticsManager:Error("ui", "RSUI_CREATE_FAILED", "RSUI 组件创建失败", {
                component = name,
                id = tostring(spec.id or ""),
                error = tostring(trace),
            })
        end
        return Fail(trace)
    end
    if component == nil then
        self.metrics.errors = self.metrics.errors + 1
        return Fail(err)
    end
    component.parentComponent = componentParent or component.parentComponent
    if componentParent ~= nil and type(componentParent.AddChild) == "function" then
        local attached, _, attachErr = componentParent:AddChild(component, spec.slot)
        if attached == nil then
            self.metrics.errors = self.metrics.errors + 1
            return Fail("component_attach_failed:" .. tostring(attachErr or "unknown"))
        end
    end
    -- Apply Hidden/Collapsed immediately after the factory has created its
    -- native widget. This prevents a one-frame flash during initial build.
    if type(component._ApplyVisibility) == "function" then component:_ApplyVisibility() end
    return component, err
end

function RSUI:Build(parent, descriptors)
    local result = {}
    for _, descriptor in ipairs(type(descriptors) == "table" and descriptors or {}) do
        if type(descriptor) == "table" then
            local spec = {}
            for key, value in pairs(descriptor) do
                if key ~= "type" and key ~= "kind" and key ~= "children" then spec[key] = value end
            end
            if spec.parent == nil then spec.parent = parent end
            local component = self:Create(descriptor.type or descriptor.kind, spec)
            if component ~= nil then
                result[#result + 1] = component
                if type(descriptor.children) == "table" and #descriptor.children > 0 then
                    component.builtChildren = self:Build(component, descriptor.children)
                end
            end
        end
    end
    return result
end

function RSUI:Binding(spec)
    spec = type(spec) == "table" and spec or {}
    if type(spec.binding) == "table" then return spec.binding end
    if type(UI.CreateSettingBinding) ~= "function" then return nil end
    local create = (spec.storeId ~= nil or spec.persistenceStore ~= nil) and UI.CreatePersistentSettingBinding or UI.CreateSettingBinding
    if type(create) ~= "function" then return nil end
    return create(UI, {
        id = spec.bindingId or spec.id,
        value = spec.value,
        get = spec.get,
        set = spec.set,
        normalize = spec.normalize,
        validate = spec.validate,
        commit = spec.commit,
        equals = spec.equals,
        markDirty = spec.markDirty,
        dirtyKey = spec.dirtyKey,
        onChanged = spec.onBindingChanged,
        onErrorChanged = spec.onErrorChanged,
        onRejected = spec.onRejected,
        onCommitted = spec.onCommitted,
        onRefreshed = spec.onRefreshed,
        commitOnUnchanged = spec.commitOnUnchanged == true,
        autoCommit = spec.autoCommit == true,
        storeId = spec.storeId or spec.persistenceStore,
        persistDelayMs = spec.persistDelayMs or spec.persistenceDelayMs,
        persistReason = spec.persistReason,
    })
end

function RSUI:Callback(label, fn, ...)
    return SafeInvoke(label, fn, ...)
end

function RSUI:GetSnapshot()
    local byType = {}
    for _, name in ipairs(self.typeOrder) do
        local row = self.metrics.byType[name]
        if row ~= nil then
            byType[#byType + 1] = {
                type = name,
                created = tonumber(row.created) or 0,
                rendered = tonumber(row.rendered) or 0,
                layouts = tonumber(row.layouts) or 0,
                events = tonumber(row.events) or 0,
                releases = tonumber(row.releases) or 0,
                errors = tonumber(row.errors) or 0,
            }
        end
    end
    return {
        version = self.version,
        apiVersion = self.apiVersion,
        registeredTypes = #self.typeOrder,
        created = tonumber(self.metrics.created) or 0,
        rendered = tonumber(self.metrics.rendered) or 0,
        layouts = tonumber(self.metrics.layouts) or 0,
        events = tonumber(self.metrics.events) or 0,
        releases = tonumber(self.metrics.releases) or 0,
        errors = tonumber(self.metrics.errors) or 0,
        layoutCompressionEvents = tonumber(self.metrics.layoutCompressionEvents) or 0,
        layoutOverflowEvents = tonumber(self.metrics.layoutOverflowEvents) or 0,
        invalidations = tonumber(self.metrics.invalidations) or 0,
        invalidationCoalesces = tonumber(self.metrics.invalidationCoalesces) or 0,
        invalidationEpochs = tonumber(self.metrics.invalidationEpochs) or 0,
        inspectorScans = tonumber(self.metrics.inspectorScans) or 0,
        wrapEvents = tonumber(self.metrics.wrapEvents) or 0,
        scrollChanges = tonumber(self.metrics.scrollChanges) or 0,
        switchChanges = tonumber(self.metrics.switchChanges) or 0,
        measurePasses = tonumber(self.metrics.measurePasses) or 0,
        measureSkips = tonumber(self.metrics.measureSkips) or 0,
        layoutPasses = tonumber(self.metrics.layoutPasses) or 0,
        layoutSkips = tonumber(self.metrics.layoutSkips) or 0,
        viewportRefreshes = tonumber(self.metrics.viewportRefreshes) or 0,
        safeZoneClamps = tonumber(self.metrics.safeZoneClamps) or 0,
        screenBoundaryIssues = tonumber(self.metrics.screenBoundaryIssues) or 0,
        visibilityChanges = tonumber(self.metrics.visibilityChanges) or 0,
        debugOverlayRefreshes = tonumber(self.metrics.debugOverlayRefreshes) or 0,
        virtualPoolRowsCreated = tonumber(self.metrics.virtualPoolRowsCreated) or 0,
        virtualRowBinds = tonumber(self.metrics.virtualRowBinds) or 0,
        virtualRowReuses = tonumber(self.metrics.virtualRowReuses) or 0,
        virtualReconciles = tonumber(self.metrics.virtualReconciles) or 0,
        virtualDataRefreshes = tonumber(self.metrics.virtualDataRefreshes) or 0,
        virtualVisibleRowsPeak = tonumber(self.metrics.virtualVisibleRowsPeak) or 0,
        tableColumnResolves = tonumber(self.metrics.tableColumnResolves) or 0,
        tableEmergencyClamps = tonumber(self.metrics.tableEmergencyClamps) or 0,
        selectionModelsCreated = tonumber(self.metrics.selectionModelsCreated) or 0,
        selectionChanges = tonumber(self.metrics.selectionChanges) or 0,
        selectionVisualsCreated = tonumber(self.metrics.selectionVisualsCreated) or 0,
        selectionVisualApplications = tonumber(self.metrics.selectionVisualApplications) or 0,
        selectionGeometryModelsCreated = tonumber(self.metrics.selectionGeometryModelsCreated) or 0,
        selectionGeometryResolves = tonumber(self.metrics.selectionGeometryResolves) or 0,
        layoutGuideResolves = tonumber(self.metrics.layoutGuideResolves) or 0,
        layoutGuideCandidatesScanned = tonumber(self.metrics.layoutGuideCandidatesScanned) or 0,
        layoutGuideSnaps = tonumber(self.metrics.layoutGuideSnaps) or 0,
        selectionOverlayLayouts = tonumber(self.metrics.selectionOverlayLayouts) or 0,
        layoutGuideOverlayUpdates = tonumber(self.metrics.layoutGuideOverlayUpdates) or 0,
        layoutEditorGestureBegins = tonumber(self.metrics.layoutEditorGestureBegins) or 0,
        layoutEditorGesturePulses = tonumber(self.metrics.layoutEditorGesturePulses) or 0,
        layoutEditorGestureCommits = tonumber(self.metrics.layoutEditorGestureCommits) or 0,
        layoutEditorGestureCancels = tonumber(self.metrics.layoutEditorGestureCancels) or 0,
        layoutEditorGestureCaptureFailures = tonumber(self.metrics.layoutEditorGestureCaptureFailures) or 0,
        layoutEditorGestureFallbackUpdates = tonumber(self.metrics.layoutEditorGestureFallbackUpdates) or 0,
        layoutEditorGestureCandidateFreezes = tonumber(self.metrics.layoutEditorGestureCandidateFreezes) or 0,
        layoutEditorAnchorPivotModelsCreated = tonumber(self.metrics.layoutEditorAnchorPivotModelsCreated) or 0,
        layoutEditorAnchorPivotChanges = tonumber(self.metrics.layoutEditorAnchorPivotChanges) or 0,
        layoutEditorSnapSettingsModelsCreated = tonumber(self.metrics.layoutEditorSnapSettingsModelsCreated) or 0,
        layoutEditorSnapSettingsChanges = tonumber(self.metrics.layoutEditorSnapSettingsChanges) or 0,
        transformInspectorEdits = tonumber(self.metrics.transformInspectorEdits) or 0,
        transformInspectorSnapEdits = tonumber(self.metrics.transformInspectorSnapEdits) or 0,
        transformInspectorRefreshes = tonumber(self.metrics.transformInspectorRefreshes) or 0,
        transformInspectorLayouts = tonumber(self.metrics.transformInspectorLayouts) or 0,
        multiSelectionTransformModelsCreated = tonumber(self.metrics.multiSelectionTransformModelsCreated) or 0,
        multiSelectionTransformSessions = tonumber(self.metrics.multiSelectionTransformSessions) or 0,
        multiSelectionTransformProjections = tonumber(self.metrics.multiSelectionTransformProjections) or 0,
        multiSelectionTransformCommits = tonumber(self.metrics.multiSelectionTransformCommits) or 0,
        multiSelectionTransformCancels = tonumber(self.metrics.multiSelectionTransformCancels) or 0,
        multiSelectionTransformRejects = tonumber(self.metrics.multiSelectionTransformRejects) or 0,
        tilePoolItemsCreated = tonumber(self.metrics.tilePoolItemsCreated) or 0,
        tileItemBinds = tonumber(self.metrics.tileItemBinds) or 0,
        tileItemReuses = tonumber(self.metrics.tileItemReuses) or 0,
        tileReconciles = tonumber(self.metrics.tileReconciles) or 0,
        tileColumnChanges = tonumber(self.metrics.tileColumnChanges) or 0,
        tileVisibleItemsPeak = tonumber(self.metrics.tileVisibleItemsPeak) or 0,
        tableHeaderClicks = tonumber(self.metrics.tableHeaderClicks) or 0,
        tableSortChanges = tonumber(self.metrics.tableSortChanges) or 0,
        tableColumnWidthChanges = tonumber(self.metrics.tableColumnWidthChanges) or 0,
        eventSubscriptions = tonumber(self.metrics.eventSubscriptions) or 0,
        eventDispatches = tonumber(self.metrics.eventDispatches) or 0,
        tooltipBindings = tonumber(self.metrics.tooltipBindings) or 0,
        tooltipShows = tonumber(self.metrics.tooltipShows) or 0,
        tooltipHides = tonumber(self.metrics.tooltipHides) or 0,
        contextMenuOpens = tonumber(self.metrics.contextMenuOpens) or 0,
        contextMenuCloses = tonumber(self.metrics.contextMenuCloses) or 0,
        contextMenuActions = tonumber(self.metrics.contextMenuActions) or 0,
        contextMenuRowsCreated = tonumber(self.metrics.contextMenuRowsCreated) or 0,
        focusChanges = tonumber(self.metrics.focusChanges) or 0,
        playgroundBuilds = tonumber(self.metrics.playgroundBuilds) or 0,
        playgroundStressRuns = tonumber(self.metrics.playgroundStressRuns) or 0,
        layoutRootsQueued = tonumber(self.metrics.layoutRootsQueued) or 0,
        layoutFlushes = tonumber(self.metrics.layoutFlushes) or 0,
        layoutRootsReflowed = tonumber(self.metrics.layoutRootsReflowed) or 0,
        layoutFlushDeferrals = tonumber(self.metrics.layoutFlushDeferrals) or 0,
        layoutStabilizationPasses = tonumber(self.metrics.layoutStabilizationPasses) or 0,
        layoutUnstableDeferrals = tonumber(self.metrics.layoutUnstableDeferrals) or 0,
        siblingOverlapIssues = tonumber(self.metrics.siblingOverlapIssues) or 0,
        collapsibleHeaderUnavailable = tonumber(self.metrics.collapsibleHeaderUnavailable) or 0,
        collapsibleHeaderBindFailed = tonumber(self.metrics.collapsibleHeaderBindFailed) or 0,
        splitToolbarSpacerClamped = tonumber(self.metrics.splitToolbarSpacerClamped) or 0,
        statusChipUpdates = tonumber(self.metrics.statusChipUpdates) or 0,
        pickerModelRebuilds = tonumber(self.metrics.pickerModelRebuilds) or 0,
        treeModelRebuilds = tonumber(self.metrics.treeModelRebuilds) or 0,
        treeExpansionChanges = tonumber(self.metrics.treeExpansionChanges) or 0,
        treeExpansionStatePrunes = tonumber(self.metrics.treeExpansionStatePrunes) or 0,
        attachmentRejects = tonumber(self.metrics.attachmentRejects) or 0,
        attachmentCycleRejects = tonumber(self.metrics.attachmentCycleRejects) or 0,
        attachmentParentConflicts = tonumber(self.metrics.attachmentParentConflicts) or 0,
        attachmentNativeParentConflicts = tonumber(self.metrics.attachmentNativeParentConflicts) or 0,
        childRemovals = tonumber(self.metrics.childRemovals) or 0,
        responsiveInspectorModeChanges = tonumber(self.metrics.responsiveInspectorModeChanges) or 0,
        responsiveInspectorDrawerChanges = tonumber(self.metrics.responsiveInspectorDrawerChanges) or 0,
        searchablePickerQueries = tonumber(self.metrics.searchablePickerQueries) or 0,
        searchablePickerSelections = tonumber(self.metrics.searchablePickerSelections) or 0,
        iconPickerQueries = tonumber(self.metrics.iconPickerQueries) or 0,
        iconPickerSelections = tonumber(self.metrics.iconPickerSelections) or 0,
        iconPickerTileBinds = tonumber(self.metrics.iconPickerTileBinds) or 0,
        activeBuildScopes = #self.buildScopeStack,
        buildScopesStarted = tonumber(self.metrics.buildScopesStarted) or 0,
        buildScopesCommitted = tonumber(self.metrics.buildScopesCommitted) or 0,
        buildScopesRolledBack = tonumber(self.metrics.buildScopesRolledBack) or 0,
        buildScopeComponentsReleased = tonumber(self.metrics.buildScopeComponentsReleased) or 0,
        buildScopeWidgetsHidden = tonumber(self.metrics.buildScopeWidgetsHidden) or 0,
        buildScopeCleanupFailures = tonumber(self.metrics.buildScopeCleanupFailures) or 0,
        buildScopeCloseOrderRecoveries = tonumber(self.metrics.buildScopeCloseOrderRecoveries) or 0,
        buildTransactions = tonumber(self.metrics.buildTransactions) or 0,
        buildTransactionFailures = tonumber(self.metrics.buildTransactionFailures) or 0,
        preflightFailures = tonumber(self.metrics.preflightFailures) or 0,
        strictBuildFailFast = tonumber(self.metrics.strictBuildFailFast) or 0,
        duplicateTypeRegistrations = tonumber(self.metrics.duplicateTypeRegistrations) or 0,
        externalLayoutInvalidations = tonumber(self.metrics.externalLayoutInvalidations) or 0,
        typographyInvalidations = tonumber(self.metrics.typographyInvalidations) or 0,
        fontScaleApplications = tonumber(self.metrics.fontScaleApplications) or 0,
        strictBuildFailFastContractVersion = tonumber(self.StrictBuildFailFastContractVersion) or 0,
        attachmentContractVersion = tonumber(self.AttachmentContractVersion) or 0,
        reparentPolicyContractVersion = tonumber(self.ReparentPolicyContractVersion) or 0,
        nativeReparentSupported = self.NativeReparentSupported == true,
        responsiveInspectorContractVersion = tonumber(self.ResponsiveInspectorContractVersion) or 0,
        searchablePickerContractVersion = tonumber(self.SearchablePickerContractVersion) or 0,
        iconPickerContractVersion = tonumber(self.IconPickerContractVersion) or 0,
        pointerContractVersion = tonumber(self.PointerContractVersion) or 0,
        selectionGeometryContractVersion = tonumber(self.SelectionGeometryContractVersion) or 0,
        layoutGuideResolverContractVersion = tonumber(self.LayoutGuideResolverContractVersion) or 0,
        selectionOverlayContractVersion = tonumber(self.SelectionOverlayContractVersion) or 0,
        layoutGuideOverlayContractVersion = tonumber(self.LayoutGuideOverlayContractVersion) or 0,
        layoutEditorGestureContractVersion = tonumber(self.LayoutEditorGestureContractVersion) or 0,
        anchorPivotContractVersion = tonumber(self.AnchorPivotContractVersion) or 0,
        layoutEditorSnapSettingsContractVersion = tonumber(self.LayoutEditorSnapSettingsContractVersion) or 0,
        transformInspectorContractVersion = tonumber(self.TransformInspectorContractVersion) or 0,
        multiSelectionTransformContractVersion = tonumber(self.MultiSelectionTransformContractVersion) or 0,
        coordinateSystemContractVersion = tonumber(S.Layout and S.Layout.CoordinateSystemContractVersion) or 0,
        rectTransformTransactionContractVersion = tonumber(S.Layout and S.Layout.RectTransformTransactionContractVersion) or 0,
        consumedLogicalIds = (function() local count = 0; for _ in pairs(self.consumedLogicalIds or {}) do count = count + 1 end; return count end)(),
        logicalIdGenerationFenceVersion = tonumber(self.LogicalIdGenerationFenceVersion) or 0,
        text = self.TextLayout and self.TextLayout:GetSnapshot() or nil,
        viewState = self.ViewState and self.ViewState:GetSnapshot() or nil,
        compositeFoundation = self.CompositeFoundation and type(self.CompositeFoundation.GetSnapshot) == "function" and self.CompositeFoundation.GetSnapshot() or nil,
        popupCoordinator = self.PopupCoordinator and type(self.PopupCoordinator.GetSnapshot) == "function" and self.PopupCoordinator:GetSnapshot() or nil,
        pointer = self.Pointer and type(self.Pointer.GetCapabilities) == "function" and self.Pointer:GetCapabilities() or nil,
        selectionGeometry = self.SelectionGeometry and type(self.SelectionGeometry.GetSnapshot) == "function" and self.SelectionGeometry:GetSnapshot() or nil,
        layoutGuideResolver = self.LayoutGuideResolver and type(self.LayoutGuideResolver.GetSnapshot) == "function" and self.LayoutGuideResolver:GetSnapshot() or nil,
        geometry = S.Layout and type(S.Layout.GetGeometryContractSnapshot) == "function" and S.Layout:GetGeometryContractSnapshot() or nil,
        actionRunner = S.ActionRunner and type(S.ActionRunner.GetSnapshot) == "function" and S.ActionRunner:GetSnapshot() or nil,
        binding = UI.Binding and type(UI.Binding.GetSnapshot) == "function" and UI.Binding:GetSnapshot() or nil,
        byType = byType,
    }
end

-- On-demand, read-only layout inspector. It never creates overlay widgets and
-- never runs automatically from Tick; Diagnostics/debug pages may call it when
-- the user explicitly asks to inspect a component tree.
function RSUI:InspectLayout(component, options)
    options = type(options) == "table" and options or {}
    if not self:IsComponent(component) then return { ok = false, reason = "component_required", rows = {}, issues = {} } end
    local maxNodes = math.max(1, math.min(tonumber(options.maxNodes) or 160, 512))
    local maxDepth = math.max(0, math.min(tonumber(options.maxDepth) or 16, 32))
    local rows, issues, visited, textTruncated = {}, {}, 0, 0
    local NON_OVERLAP = {
        HorizontalBox = true, VerticalBox = true, Grid = true, UniformGrid = true,
        WrapBox = true, ScrollBox = true, TableView = true, Table = true,
        Form = true, FormSection = true, FieldGroup = true, SettingsPage = true,
    }
    local function ChildRect(child)
        if type(child) ~= "table" or child.released == true or child.visible == false or child.viewportVisible == false then return nil end
        local x, y, w, h = tonumber(child.x), tonumber(child.y), tonumber(child.width), tonumber(child.height)
        if x == nil or y == nil or w == nil or h == nil or w <= 0 or h <= 0 then return nil end
        return { x=x, y=y, right=x+w, bottom=y+h, width=w, height=h }
    end
    local function RectsOverlap(a,b)
        if a == nil or b == nil then return false end
        local ix = math.min(a.right,b.right) - math.max(a.x,b.x)
        local iy = math.min(a.bottom,b.bottom) - math.max(a.y,b.y)
        return ix > 0.75 and iy > 0.75
    end
    local function walk(node, path, depth)
        if visited >= maxNodes or depth > maxDepth or type(node) ~= "table" then return end
        visited = visited + 1
        local row = node:Describe()
        row.path = path
        row.depth = depth
        rows[#rows + 1] = row
        local flags = {}
        if (tonumber(row.overflow) or 0) > 0.01 then flags[#flags + 1] = "overflow" end
        if node.state and node.state.textTruncated == true then
            textTruncated = textTruncated + 1
            if node.spec and node.spec.warnOnTruncation == true then flags[#flags + 1] = "text_truncated" end
        end
        if node.state and node.state.textOverflow == true then flags[#flags + 1] = "text_overflow" end
        if row.visible and row.viewportVisible and row.width and row.height and node.parentComponent ~= nil then
            local parent = node.parentComponent
            local pw, ph = tonumber(parent.width), tonumber(parent.height)
            local x, y = tonumber(row.x) or 0, tonumber(row.y) or 0
            local scale = 1
            if parent.kind == "ScaleBox" and parent.content == node and tonumber(parent.appliedScale) ~= nil then scale = tonumber(parent.appliedScale) end
            local effectiveW, effectiveH = row.width * scale, row.height * scale
            if pw and (x < -0.01 or x + effectiveW > pw + 0.01) then flags[#flags + 1] = "x_out_of_bounds" end
            if ph and (y < -0.01 or y + effectiveH > ph + 0.01) then flags[#flags + 1] = "y_out_of_bounds" end
        end
        if row.visible and row.viewportVisible and (row.measureDirty == true or row.layoutDirty == true) and tonumber(row.width) and tonumber(row.height) then
            flags[#flags + 1] = "dirty_layout_pending"
        end
        if #flags > 0 then issues[#issues + 1] = { id = row.id, kind = row.kind, path = path, flags = flags } end

        if NON_OVERLAP[tostring(node.kind or "")] == true then
            local children = node.children or {}
            for a = 1, #children - 1 do
                local ca, ra = children[a], ChildRect(children[a])
                if ra ~= nil then
                    for b = a + 1, #children do
                        local cb, rb = children[b], ChildRect(children[b])
                        if RectsOverlap(ra, rb) then
                            issues[#issues + 1] = {
                                id = tostring(node.id or ""),
                                kind = tostring(node.kind or ""),
                                path = path,
                                flags = { "sibling_overlap" },
                                children = { tostring(ca.id or a), tostring(cb.id or b) },
                            }
                            self.metrics.siblingOverlapIssues = (tonumber(self.metrics.siblingOverlapIssues) or 0) + 1
                        end
                    end
                end
            end
        end
        for index, child in ipairs(node.children or {}) do
            walk(child, path .. "/" .. tostring(child.id or index), depth + 1)
            if visited >= maxNodes then break end
        end
    end
    walk(component, tostring(component.id or "root"), 0)
    self.metrics.inspectorScans = (tonumber(self.metrics.inspectorScans) or 0) + 1
    return { ok = true, rows = rows, issues = issues, nodeCount = #rows, issueCount = #issues, textTruncatedCount = textTruncated, truncated = visited >= maxNodes }
end

function RSUI:ResetMetrics()
    self.metrics.created, self.metrics.rendered, self.metrics.layouts = 0, 0, 0
    self.metrics.events, self.metrics.releases, self.metrics.errors = 0, 0, 0
    self.metrics.layoutCompressionEvents, self.metrics.layoutOverflowEvents = 0, 0
    self.metrics.invalidations, self.metrics.inspectorScans = 0, 0
    self.metrics.invalidationCoalesces, self.metrics.invalidationEpochs = 0, 0
    self.metrics.wrapEvents, self.metrics.scrollChanges, self.metrics.switchChanges = 0, 0, 0
    self.metrics.measurePasses, self.metrics.measureSkips = 0, 0
    self.metrics.layoutPasses, self.metrics.layoutSkips = 0, 0
    self.metrics.viewportRefreshes, self.metrics.safeZoneClamps, self.metrics.screenBoundaryIssues = 0, 0, 0
    self.metrics.visibilityChanges, self.metrics.debugOverlayRefreshes = 0, 0
    self.metrics.virtualPoolRowsCreated, self.metrics.virtualRowBinds, self.metrics.virtualRowReuses = 0, 0, 0
    self.metrics.virtualReconciles, self.metrics.virtualDataRefreshes, self.metrics.virtualVisibleRowsPeak = 0, 0, 0
    self.metrics.tableColumnResolves, self.metrics.tableEmergencyClamps = 0, 0
    self.metrics.selectionModelsCreated, self.metrics.selectionChanges = 0, 0
    self.metrics.selectionVisualsCreated, self.metrics.selectionVisualApplications = 0, 0
    self.metrics.selectionGeometryModelsCreated, self.metrics.selectionGeometryResolves = 0, 0
    self.metrics.layoutGuideResolves, self.metrics.layoutGuideCandidatesScanned, self.metrics.layoutGuideSnaps = 0, 0, 0
    self.metrics.selectionOverlayLayouts, self.metrics.layoutGuideOverlayUpdates = 0, 0
    self.metrics.layoutEditorGestureBegins, self.metrics.layoutEditorGesturePulses = 0, 0
    self.metrics.layoutEditorGestureCommits, self.metrics.layoutEditorGestureCancels = 0, 0
    self.metrics.layoutEditorGestureCaptureFailures, self.metrics.layoutEditorGestureFallbackUpdates = 0, 0
    self.metrics.layoutEditorGestureCandidateFreezes = 0
    self.metrics.tilePoolItemsCreated, self.metrics.tileItemBinds, self.metrics.tileItemReuses = 0, 0, 0
    self.metrics.tileReconciles, self.metrics.tileColumnChanges, self.metrics.tileVisibleItemsPeak = 0, 0, 0
    self.metrics.tableHeaderClicks, self.metrics.tableSortChanges, self.metrics.tableColumnWidthChanges = 0, 0, 0
    self.metrics.eventSubscriptions, self.metrics.eventDispatches = 0, 0
    self.metrics.tooltipBindings, self.metrics.tooltipShows, self.metrics.tooltipHides = 0, 0, 0
    self.metrics.contextMenuOpens, self.metrics.contextMenuCloses, self.metrics.contextMenuActions, self.metrics.contextMenuRowsCreated = 0, 0, 0, 0
    self.metrics.focusChanges, self.metrics.playgroundBuilds, self.metrics.playgroundStressRuns = 0, 0, 0
    self.metrics.layoutRootsQueued, self.metrics.layoutFlushes, self.metrics.layoutRootsReflowed = 0, 0, 0
    self.metrics.typographyInvalidations = 0
    self.metrics.duplicateTypeRegistrations = 0
    self.metrics.externalLayoutInvalidations = 0
    self.metrics.fontScaleApplications = 0
    self.metrics.buildScopesStarted, self.metrics.buildScopesCommitted, self.metrics.buildScopesRolledBack = 0, 0, 0
    self.metrics.buildScopeComponentsReleased, self.metrics.buildScopeWidgetsHidden, self.metrics.buildScopeCleanupFailures = 0, 0, 0
    self.metrics.buildScopeCloseOrderRecoveries, self.metrics.buildTransactions, self.metrics.buildTransactionFailures = 0, 0, 0
    self.metrics.preflightFailures, self.metrics.strictBuildFailFast = 0, 0
    self.metrics.layoutFlushDeferrals, self.metrics.layoutStabilizationPasses, self.metrics.layoutUnstableDeferrals, self.metrics.siblingOverlapIssues = 0, 0, 0, 0
    self.metrics.collapsibleHeaderUnavailable, self.metrics.collapsibleHeaderBindFailed, self.metrics.splitToolbarSpacerClamped = 0, 0, 0
    self.metrics.byType = {}
    if self.TextLayout ~= nil and self.TextLayout.metrics ~= nil then
        self.TextLayout.metrics.measures, self.TextLayout.metrics.wraps, self.TextLayout.metrics.fits, self.TextLayout.metrics.overflows = 0, 0, 0, 0
        self.TextLayout.metrics.wordBoundaryBreaks = 0
    end
    return true
end

-- Public component constructors are installed by RegisterType/ReplaceType.
-- Keep exactly one registry authority: adding a component type must not require
-- editing a second convenience-wrapper list.

RSUI.BaseComponent = Base

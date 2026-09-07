------------------------------------------------------------------------
-- Replicated Suite - UI Framework v13
--
-- Incremental upper layer over the limited ArcheAge/RU native UI API.
--
-- Authority rules:
--   * Native widgets remain render objects only; business state never lives here.
--   * DiffRenderer owns cached presentation state for migrated fields.
--   * Lifecycle owns handler release / hide / logical-reference cleanup.  The RU
--     API has no validated generic DestroyWidget operation, so release MUST NOT
--     pretend that a native widget can be safely destroyed.
--   * Hot-path diagnostics are cheap counters only; no log formatting happens
--     on every UI write.
------------------------------------------------------------------------

if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local UI = S.UI
if type(UI) ~= "table" then return end

local FRAMEWORK_VERSION = 13
local MAX_OWNER_METRICS = 48

local stateCache = setmetatable({}, { __mode = "k" })
local authorityClaims = setmetatable({}, { __mode = "k" })
local geometryLeases = setmetatable({}, { __mode = "k" })
local lifecycle = {
    owners = {},
    -- Physical-id keyed weak values let focus cleanup prove that the currently
    -- focused native widget belongs to Suite before touching it. Never clear an
    -- external game/chat focus merely because a Suite window is hiding.
    focusTargetsByPhysicalId = setmetatable({}, { __mode = "v" }),
    -- Deferred keyboard activation keeps edit boxes inert until an explicit
    -- user click arms them. Weak keys prevent released Native widgets from
    -- being retained by the lifecycle authority.
    armedInputs = setmetatable({}, { __mode = "k" }),
}

local metrics = {
    attempts = 0,
    writes = 0,
    skips = 0,
    nativeCalls = 0,
    cacheRepairs = 0,
    cacheRepairsByField = {},
    cacheRepairsByOwner = {},
    authority = { claims = 0, conflicts = 0, violations = 0, strictRepairs = 0, byOwner = {}, byField = {} },
    geometryLease = { begins = 0, ends = 0, deferredAnchors = 0, deferredExtents = 0, conflicts = 0 },
    nativeSafety = { staleRejects = 0, registrationRejects = 0, degradedRejects = 0, callFailures = 0, anchorParentRepairs = 0 },
    byOp = {},
    byOwner = {},
    ownerOrder = {},
    lifecycle = {
        adopted = 0,
        handlerBindings = 0,
        releasedOwners = 0,
        releasedHandlers = 0,
        hiddenOnRelease = 0,
        inputTargets = 0,
        focusClears = 0,
        focusClearFailures = 0,
        inputRetires = 0,
        keyboardArms = 0,
        keyboardDisarms = 0,
        keyboardArmFailures = 0,
    },
}

UI.FrameworkVersion = FRAMEWORK_VERSION
UI.CompositeEnabledAdapterContractVersion = 2
UI.EnabledStateTransactionContractVersion = 1
UI.PickableStateTransactionContractVersion = 1
-- RU Native Widget setters have no documented success-return contract. A
-- boolean setter may return the resulting state, so applying false may itself
-- return false and must not be globally classified as rejection. False while
-- requesting true still fails closed; explicit Lua callback false=veto
-- semantics remain owned by their higher-level transaction boundaries.
UI.NativeBooleanSetterReturnContractVersion = 1
-- Keyboard focus is a Native-lifecycle resource. Hidden/disabled/released
-- Suite subtrees must relinquish focus, while unrelated game/chat focus is
-- never touched. Input widgets register once at adoption; ancestors carry a
-- small subtree count so ordinary non-input visibility writes stay O(1).
UI.InputFocusLifecycleContractVersion = 2
UI.HiddenInputFocusIsolationContractVersion = 2
UI.DeferredKeyboardActivationContractVersion = 1
UI.ExplicitInputCommitFocusContractVersion = 1
UI.Tokens = S.UITokens
UI.NativeStateCache = stateCache
UI.NativeAuthorityClaims = authorityClaims
UI.NativeGeometryLeases = geometryLeases
UI.Lifecycle = lifecycle
UI.FrameworkMetrics = metrics

local function NativeBooleanSetterAccepted(ok, result, requested)
    if ok ~= true then return false, result end
    -- RU may return the resulting boolean state instead of a success flag.
    -- Therefore false is only ambiguous/valid when false was requested. A
    -- false result while requesting true still fails closed.
    if result == false and requested ~= false then return false, "native_rejected" end
    return true, nil
end

local function NormalizeOwner(value)
    local owner = tostring(value or "")
    owner = owner:gsub("[\r\n]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if owner == "" then owner = "suite" end
    if #owner > 64 then owner = owner:sub(1, 64) end
    return owner
end

local function OwnerOf(widget, explicitOwner)
    if explicitOwner ~= nil then return NormalizeOwner(explicitOwner) end
    if widget ~= nil then
        if widget.rsUiOwner ~= nil then return NormalizeOwner(widget.rsUiOwner) end
        if widget.rsHudOwner ~= nil then return NormalizeOwner("hud:" .. tostring(widget.rsHudOwner)) end
    end
    return "suite"
end

local function GetState(widget)
    if widget == nil then return nil end
    local row = stateCache[widget]
    if row == nil then
        row = {}
        stateCache[widget] = row
    end
    return row
end

local function WidgetUsable(widget)
    if widget == nil then return false, "nil_widget" end
    if widget.rsUiRegistrationRejected == true then
        metrics.nativeSafety.registrationRejects = (tonumber(metrics.nativeSafety.registrationRejects) or 0) + 1
        return false, "registration_rejected"
    end
    if widget.rsUiDegraded == true then
        metrics.nativeSafety.degradedRejects = (tonumber(metrics.nativeSafety.degradedRejects) or 0) + 1
        return false, "primitive_degraded"
    end
    local nativeGeneration = tonumber(widget.rsNativeGeneration)
    if nativeGeneration ~= nil and nativeGeneration ~= tonumber(S.Generation) then
        metrics.nativeSafety.staleRejects = (tonumber(metrics.nativeSafety.staleRejects) or 0) + 1
        return false, "stale_generation:" .. tostring(nativeGeneration) .. "!=" .. tostring(S.Generation)
    end
    return true
end

local function ResolveAnchorParent(parent)
    -- UIParent is a special root identity in the ArcheAge native API.  Keep the
    -- logical/cache side as the real UIParent object so effective-offset checks
    -- still work, but never let the literal string drift into cache authority.
    if parent == "UIParent" and UIParent ~= nil then return UIParent end
    local rsui = S.RSUI
    if type(rsui) == "table" and type(rsui.IsComponent) == "function" and rsui:IsComponent(parent) then
        local native = type(rsui.ResolveParent) == "function" and select(1, rsui:ResolveParent(parent)) or nil
        if native ~= nil then
            metrics.nativeSafety.anchorParentRepairs = (tonumber(metrics.nativeSafety.anchorParentRepairs) or 0) + 1
            return native
        end
    end
    return parent
end

local function ResolveNativeAnchorTarget(parent)
    -- RU root widgets (Window / top-level Button) accept "UIParent" as the
    -- root anchor identity. Passing the UIParent userdata can return success but
    -- leave the widget at its native creation origin (0,0), after which the diff
    -- cache incorrectly believes the requested position was applied.
    if parent == UIParent or parent == "UIParent" then return "UIParent" end
    return parent
end

function UI:ResolveNativeAnchorTarget(parent)
    local logicalParent = ResolveAnchorParent(parent)
    return ResolveNativeAnchorTarget(logicalParent), logicalParent
end

local function RecordNativeSafetyFailure(op, widget, detail, owner)
    metrics.nativeSafety.callFailures = (tonumber(metrics.nativeSafety.callFailures) or 0) + 1
    local logical = widget and (widget.rsNativeLogicalId or widget.rsUiLogicalId) or "?"
    local message = tostring(op or "native_call") .. ":" .. tostring(logical) .. ":" .. tostring(detail or "failed")
    if type(S.RecordLog) == "function" then S.RecordLog("error", "ui_native_safety", message) end
    local diagnostics = S.DiagnosticsManager
    if type(diagnostics) == "table" and type(diagnostics.Emit) == "function" then
        diagnostics:Emit("error", "ui_native_safety", "NATIVE_UI_CALL_REJECTED", "原生界面写入已被安全拒绝", {
            op = tostring(op or ""), logicalId = tostring(logical or ""), detail = tostring(detail or ""), owner = OwnerOf(widget, owner),
        })
    end
end

function UI:IsWidgetUsable(widget)
    return WidgetUsable(widget)
end


local MAX_INPUT_ANCESTRY_DEPTH = 32

local function PhysicalIdOf(widget)
    if widget == nil then return nil end
    local value = widget.rsNativePhysicalId
    if value == nil or tostring(value) == "" then return nil end
    return tostring(value)
end

local function IsInputTarget(widget)
    return widget ~= nil and widget.rsUiKeyboardInput == true
end

local function BumpInputSubtree(widget, delta)
    delta = tonumber(delta) or 0
    if widget == nil or delta == 0 then return end
    local current, guard = widget, 0
    while current ~= nil and current ~= UIParent and current ~= "UIParent" and guard < MAX_INPUT_ANCESTRY_DEPTH do
        guard = guard + 1
        local nextValue = math.max(0, (tonumber(current.rsUiKeyboardInputSubtreeCount) or 0) + delta)
        current.rsUiKeyboardInputSubtreeCount = nextValue
        local parent = current.rsUiParent
        if parent == nil or parent == current then break end
        current = parent
    end
end

local function RegisterInputTarget(widget)
    if not IsInputTarget(widget) or widget.rsUiInputLifecycleTracked == true then return false end
    widget.rsUiInputLifecycleRetired = false
    widget.rsUiInputLifecycleTracked = true
    widget.rsUiKeyboardArmed = widget.rsUiKeyboardArmed == true
    local physicalId = PhysicalIdOf(widget)
    if physicalId ~= nil then lifecycle.focusTargetsByPhysicalId[physicalId] = widget end
    if widget.rsUiKeyboardArmed == true then lifecycle.armedInputs[widget] = true end
    BumpInputSubtree(widget, 1)
    metrics.lifecycle.inputTargets = (tonumber(metrics.lifecycle.inputTargets) or 0) + 1
    return true
end

local function UnregisterInputTarget(widget)
    if widget == nil or widget.rsUiInputLifecycleTracked ~= true then return false end
    widget.rsUiInputLifecycleTracked = false
    lifecycle.armedInputs[widget] = nil
    widget.rsUiKeyboardArmed = false
    local physicalId = PhysicalIdOf(widget)
    if physicalId ~= nil and lifecycle.focusTargetsByPhysicalId[physicalId] == widget then
        lifecycle.focusTargetsByPhysicalId[physicalId] = nil
    end
    BumpInputSubtree(widget, -1)
    return true
end

local function SetInputKeyboardState(widget, armed, owner, reason)
    if not IsInputTarget(widget) then return false, false, "input_target_required" end
    if armed == true and widget.rsUiInputLifecycleRetired == true then return false, false, "input_retired" end
    if type(widget.EnableKeyboard) ~= "function" then return false, false, "keyboard_toggle_unavailable" end
    armed = armed == true
    if (widget.rsUiKeyboardArmed == true) == armed then return true, false, nil end
    local ok, result = pcall(function() return widget:EnableKeyboard(armed) end)
    local accepted, acceptErr = NativeBooleanSetterAccepted(ok, result, armed)
    if accepted ~= true then
        metrics.lifecycle.keyboardArmFailures = (tonumber(metrics.lifecycle.keyboardArmFailures) or 0) + 1
        RecordNativeSafetyFailure(armed and "INPUT_KEYBOARD_ARM" or "INPUT_KEYBOARD_DISARM", widget, acceptErr, owner)
        return false, false, tostring(acceptErr or "keyboard_toggle_rejected")
    end
    widget.rsUiKeyboardArmed = armed
    if armed then
        lifecycle.armedInputs[widget] = true
        metrics.lifecycle.keyboardArms = (tonumber(metrics.lifecycle.keyboardArms) or 0) + 1
    else
        lifecycle.armedInputs[widget] = nil
        metrics.lifecycle.keyboardDisarms = (tonumber(metrics.lifecycle.keyboardDisarms) or 0) + 1
    end
    return true, true, nil
end

function UI:ArmInputWidget(widget, owner, reason)
    return SetInputKeyboardState(widget, true, owner, reason or "explicit_input_activation")
end

function UI:DisarmInputWidget(widget, owner, reason)
    return SetInputKeyboardState(widget, false, owner, reason or "input_deactivation")
end

function UI:ActivateInputWidget(widget, owner, reason)
    local armed, _, armErr = self:ArmInputWidget(widget, owner, reason or "input_click")
    if armed ~= true then return false, tostring(armErr or "keyboard_arm_failed") end
    if type(self.TryInteractionCall) ~= "function" then
        self:DisarmInputWidget(widget, owner, "focus_contract_unavailable")
        return false, "focus_contract_unavailable"
    end
    local focused, focusErr = self:TryInteractionCall(widget, "SetFocus")
    if focused ~= true then
        self:DisarmInputWidget(widget, owner, "focus_failed")
        return false, tostring(focusErr or "set_focus_failed")
    end
    return true, nil
end

local function FocusedInputDescendsFrom(focused, root, focusedId)
    if focused == nil or root == nil then return false end
    if focused == root then return true end
    local current, guard = focused.rsUiParent, 0
    while current ~= nil and guard < MAX_INPUT_ANCESTRY_DEPTH do
        guard = guard + 1
        if current == root then return true end
        local parent = current.rsUiParent
        if parent == nil or parent == current then break end
        current = parent
    end
    -- rsUiParent is the cheap/authoritative path for Suite primitives. The
    -- verified Native ancestry API is only a fallback for adopted widgets whose
    -- historical constructor did not publish the Lua parent chain.
    if focusedId ~= nil and type(root.IsDescendantWidget) == "function" then
        local ok, result = pcall(function() return root:IsDescendantWidget(focusedId) end)
        if ok == true and result == true then return true end
    end
    return false
end

function UI:DisarmInputWithin(widget, owner, reason)
    if widget == nil then return true, 0, nil end
    local snapshot = {}
    for input in pairs(lifecycle.armedInputs) do
        if input ~= nil then snapshot[#snapshot + 1] = input end
    end
    local count, failed = 0, nil
    local allSuiteInputs = widget == UIParent or widget == "UIParent"
    for _, input in ipairs(snapshot) do
        local inputId = PhysicalIdOf(input)
        if allSuiteInputs or input == widget or FocusedInputDescendsFrom(input, widget, inputId) == true then
            local ok, changed, err = self:DisarmInputWidget(input, owner or OwnerOf(input), reason or "subtree_deactivate")
            if ok ~= true then failed = failed or err elseif changed == true then count = count + 1 end
        end
    end
    return failed == nil, count, failed
end

-- Raw multiline inputs are rare and intentionally stay outside the generic
-- Component factory. This helper gives them the same explicit-click activation
-- contract without allowing Presentation to bind Native handlers directly.
function UI:BindDeferredInputActivation(widget, owner, label)
    if not IsInputTarget(widget) then return false, "input_target_required" end
    if type(self.SafeHandler) ~= "function" then return false, "handler_contract_unavailable" end
    local eventLabel = tostring(label or widget.rsUiLogicalId or widget.rsNativeLogicalId or "input")
    local clickBound = self:SafeHandler(widget, "OnClick", function()
        local ok = self:ActivateInputWidget(widget, owner, eventLabel .. ":click")
        return ok == true
    end, eventLabel .. ":activate")
    if clickBound ~= true then return false, "input_click_activation_bind_failed" end
    local lostBound = self:SafeHandler(widget, "OnLostFocus", function()
        self:DisarmInputWidget(widget, owner, eventLabel .. ":lost_focus")
        return true
    end, eventLabel .. ":lost_focus")
    if lostBound ~= true then
        self:DisarmInputWidget(widget, owner, eventLabel .. ":lost_focus_bind_failed")
        return false, "input_lost_focus_bind_failed"
    end
    return true, nil
end

local function ReadFocusedWidgetId()
    if type(GetFocusedWidgetId) ~= "function" then return nil, "get_focus_unavailable" end
    local ok, value = pcall(GetFocusedWidgetId)
    if ok ~= true then return nil, "get_focus_failed" end
    if value == nil or tostring(value) == "" then return nil, nil end
    return tostring(value), nil
end

-- Clear focus only when the global focus id resolves to a registered Suite
-- EditBox and that EditBox is proven to be inside the subtree becoming
-- inactive. This is the core fence that prevents Suite cleanup from stealing
-- focus from ArcheAge chat or another game window.
function UI:ReleaseFocusWithin(widget, owner, reason)
    if widget == nil then return true, false, nil end
    local subtreeInputs = tonumber(widget.rsUiKeyboardInputSubtreeCount) or 0
    if subtreeInputs <= 0 and not IsInputTarget(widget) then return true, false, nil end

    local focusedId, focusErr = ReadFocusedWidgetId()
    if focusErr ~= nil then return true, false, focusErr end
    if focusedId == nil then return true, false, nil end
    local focused = lifecycle.focusTargetsByPhysicalId[focusedId]
    if focused == nil or FocusedInputDescendsFrom(focused, widget, focusedId) ~= true then
        return true, false, nil
    end
    if type(focused.ClearFocus) ~= "function" then
        metrics.lifecycle.focusClearFailures = (tonumber(metrics.lifecycle.focusClearFailures) or 0) + 1
        return false, false, "clear_focus_unavailable"
    end

    local ok, result = pcall(function() return focused:ClearFocus() end)
    if ok ~= true then
        metrics.lifecycle.focusClearFailures = (tonumber(metrics.lifecycle.focusClearFailures) or 0) + 1
        RecordNativeSafetyFailure("CLEAR_FOCUS", focused, result, owner)
        return false, false, "clear_focus_failed"
    end
    -- ClearFocus has no documented success-return ABI. Verify the observable
    -- focus identity instead of interpreting false/nil as failure.
    local afterId = select(1, ReadFocusedWidgetId())
    if afterId ~= nil and tostring(afterId) == focusedId then
        metrics.lifecycle.focusClearFailures = (tonumber(metrics.lifecycle.focusClearFailures) or 0) + 1
        RecordNativeSafetyFailure("CLEAR_FOCUS_VERIFY", focused, tostring(reason or "focus_retained"), owner)
        return false, false, "focus_retained"
    end
    metrics.lifecycle.focusClears = (tonumber(metrics.lifecycle.focusClears) or 0) + 1
    self:DisarmInputWidget(focused, owner or OwnerOf(focused), reason or "focus_released")
    return true, true, nil
end

-- Explicit edit completion is a single lifecycle transaction: first release
-- Native focus only when the focused physical id proves it belongs to this
-- Suite input, then disable its keyboard capture regardless of whether focus
-- telemetry was available.  This keeps ArcheAge chat/game focus isolated while
-- preventing a committed EditBox from continuing to consume movement/skill keys.
function UI:DeactivateInputWidget(widget, owner, reason)
    if widget == nil then return true, false, nil end
    local focusOk, focusChanged, focusErr = self:ReleaseFocusWithin(widget, owner, reason or "input_commit")
    local disarmOk, disarmChanged, disarmErr = self:DisarmInputWidget(widget, owner, reason or "input_commit")
    if focusOk ~= true then return false, focusChanged == true or disarmChanged == true, tostring(focusErr or "focus_release_failed") end
    if disarmOk ~= true then return false, focusChanged == true or disarmChanged == true, tostring(disarmErr or "keyboard_disarm_failed") end
    return true, focusChanged == true or disarmChanged == true, focusErr
end

-- Permanent input retirement is reserved for component/owner teardown and old
-- hot-reload generations. Live hide/disable paths only disarm Keyboard; a later
-- explicit user click can arm the surviving input again without re-registering it.
function UI:RetireInputWidget(widget, owner, reason)
    if not IsInputTarget(widget) then return true end
    if widget.rsUiInputLifecycleRetired == true then return true end
    self:ReleaseFocusWithin(widget, owner, reason or "input_retire")
    local failures = {}
    local disarmed, _, disarmErr = self:DisarmInputWidget(widget, owner, reason or "input_retire")
    if disarmed ~= true then failures[#failures + 1] = "EnableKeyboard:" .. tostring(disarmErr or "rejected") end
    if type(widget.EnableFocus) == "function" then
        local ok, result = pcall(function() return widget:EnableFocus(false) end)
        local accepted, acceptErr = NativeBooleanSetterAccepted(ok, result, false)
        if accepted ~= true then failures[#failures + 1] = "EnableFocus:" .. tostring(acceptErr or "rejected") end
    end
    UnregisterInputTarget(widget)
    widget.rsUiInputLifecycleRetired = true
    metrics.lifecycle.inputRetires = (tonumber(metrics.lifecycle.inputRetires) or 0) + 1
    if #failures > 0 then
        RecordNativeSafetyFailure("INPUT_RETIRE", widget, table.concat(failures, ","), owner)
        return false
    end
    return true
end

-- Runtime/bootstrap quiescence fence. With retire=false it clears current Suite
-- focus when provable and disarms every armed Suite input. With retire=true it
-- also permanently retires all tracked edits from the replaced generation.
function UI:QuiesceKeyboardInput(reason, retire)
    local focusedId = select(1, ReadFocusedWidgetId())
    if focusedId ~= nil then
        local focused = lifecycle.focusTargetsByPhysicalId[focusedId]
        if focused ~= nil then self:ReleaseFocusWithin(focused, OwnerOf(focused), reason or "input_quiesce") end
    end
    if retire ~= true then
        self:DisarmInputWithin(UIParent, "rsui:runtime", reason or "input_quiesce")
        return true
    end
    local snapshot = {}
    for _, widget in pairs(lifecycle.focusTargetsByPhysicalId) do
        if widget ~= nil then snapshot[#snapshot + 1] = widget end
    end
    local ok = true
    for _, widget in ipairs(snapshot) do
        if self:RetireInputWidget(widget, OwnerOf(widget), reason or "generation_retire") ~= true then ok = false end
    end
    return ok
end

local function TouchOwnerMetric(owner)
    local row = metrics.byOwner[owner]
    if row ~= nil then return row end

    -- Keep owner cardinality bounded.  "other" is intentionally a hot-path
    -- fallback rather than evicting arbitrary rows while the UI is refreshing.
    if #metrics.ownerOrder >= MAX_OWNER_METRICS then
        owner = "other"
        row = metrics.byOwner[owner]
        if row ~= nil then return row end
    else
        metrics.ownerOrder[#metrics.ownerOrder + 1] = owner
    end

    row = { attempts = 0, writes = 0, skips = 0, nativeCalls = 0 }
    metrics.byOwner[owner] = row
    return row
end

local function RecordAttempt(op, widget, changed, nativeCalls, explicitOwner)
    op = tostring(op or "UNKNOWN")
    nativeCalls = math.max(0, math.floor(tonumber(nativeCalls) or 0))

    metrics.attempts = metrics.attempts + 1
    if changed == true then metrics.writes = metrics.writes + 1 else metrics.skips = metrics.skips + 1 end
    metrics.nativeCalls = metrics.nativeCalls + nativeCalls

    local opRow = metrics.byOp[op]
    if opRow == nil then
        opRow = { attempts = 0, writes = 0, skips = 0, nativeCalls = 0 }
        metrics.byOp[op] = opRow
    end
    opRow.attempts = opRow.attempts + 1
    if changed == true then opRow.writes = opRow.writes + 1 else opRow.skips = opRow.skips + 1 end
    opRow.nativeCalls = opRow.nativeCalls + nativeCalls

    local ownerRow = TouchOwnerMetric(OwnerOf(widget, explicitOwner))
    ownerRow.attempts = ownerRow.attempts + 1
    if changed == true then ownerRow.writes = ownerRow.writes + 1 else ownerRow.skips = ownerRow.skips + 1 end
    ownerRow.nativeCalls = ownerRow.nativeCalls + nativeCalls
end


local function TryNativeText(widget)
    if widget == nil or type(widget.GetText) ~= "function" then return nil, false end
    local ok, value = pcall(function() return widget:GetText() end)
    if not ok then return nil, false end
    return tostring(value or ""), true
end

local function TryNativeExtent(widget)
    if widget == nil or type(widget.GetWidth) ~= "function" or type(widget.GetHeight) ~= "function" then return nil, nil, false end
    local okW, width = pcall(function() return widget:GetWidth() end)
    local okH, height = pcall(function() return widget:GetHeight() end)
    if not okW or not okH then return nil, nil, false end
    width, height = tonumber(width), tonumber(height)
    if width == nil or height == nil then return nil, nil, false end
    return width, height, true
end

local function HasKnownHiddenAncestor(widget)
    local parent = widget and widget.rsUiParent or nil
    local guard = 0
    while parent ~= nil and parent ~= UIParent and guard < 32 do
        guard = guard + 1
        local parentState = stateCache[parent]
        if parentState ~= nil and parentState.visible == false then return true end
        parent = parent.rsUiParent
    end
    return false
end

local function TryNativeVisible(widget)
    if widget == nil or type(widget.IsVisible) ~= "function" then return nil, false end
    local ok, value = pcall(function() return widget:IsVisible() end)
    if not ok then return nil, false end
    -- On RU builds IsVisible() may report EFFECTIVE visibility. A locally shown
    -- child under a hidden V3 shell then returns false even though its own Show
    -- state is correct. Treat that case as unverifiable instead of generating a
    -- false strict-authority violation. Geometry remains fully verifiable.
    if value ~= true and HasKnownHiddenAncestor(widget) then return nil, false end
    return value == true, true
end

-- Public readback for render diagnostics (v13): the overlay presenters report
-- what the engine THINKS a dot's visibility is, so "API 写入成功但屏幕无点"
-- can be separated from "坐标落到屏外" in one paste.
function UI:NativeVisibleReadback(widget)
    local value, known = TryNativeVisible(widget)
    return value, known == true
end

local function TryNativeAnchorMatches(widget, parent, x, y)
    if widget == nil or parent == nil then return nil, false end
    local parentState = stateCache[parent]
    if HasKnownHiddenAncestor(widget) or (parentState ~= nil and parentState.visible == false) then
        -- Effective offsets are not a reliable local-anchor probe while an
        -- ancestor is hidden on RU clients; defer verification until visible.
        return nil, false
    end
    if type(widget.GetEffectiveOffset) ~= "function" or type(parent.GetEffectiveOffset) ~= "function" then return nil, false end
    local okWidget, wx, wy = pcall(function() return widget:GetEffectiveOffset() end)
    local okParent, px, py = pcall(function() return parent:GetEffectiveOffset() end)
    wx, wy, px, py = tonumber(wx), tonumber(wy), tonumber(px), tonumber(py)
    if not okWidget or not okParent or wx == nil or wy == nil or px == nil or py == nil then return nil, false end
    local ax, ay = tonumber(x) or 0, tonumber(y) or 0
    local scale = 1
    if S.Layout ~= nil and type(S.Layout.GetContext) == "function" then
        local ok, context = pcall(function() return S.Layout:GetContext() end)
        -- SetAnchor receives logical coordinates that already include the
        -- Suite addonScale chosen by layout. Native getters may additionally
        -- expose the client's UI scale. Multiplying by addonScale a second time
        -- produced thousands of false strict-authority repairs when uiScale != 1.
        if ok and type(context) == "table" then scale = math.max(0.01, tonumber(context.uiScale) or 1) end
    end
    -- RU builds have returned effective offsets in both logical and native
    -- UI-scaled spaces. Accept either coordinate contract here; strict V3
    -- ownership is enforced by the writer fence, not by double-applying the
    -- Suite's addonScale to a value that is already laid out.
    local epsilon = math.max(1.0, scale)
    local rawMatch = math.abs(wx - (px + ax)) <= epsilon and math.abs(wy - (py + ay)) <= epsilon
    local scaledMatch = math.abs(wx - (px + ax * scale)) <= epsilon and math.abs(wy - (py + ay * scale)) <= epsilon
    return rawMatch or scaledMatch, true
end

local function RecordCacheRepair(kind, widget, explicitOwner)
    kind = tostring(kind or "unknown")
    metrics.cacheRepairs = (tonumber(metrics.cacheRepairs) or 0) + 1
    metrics.cacheRepairsByField[kind] = (tonumber(metrics.cacheRepairsByField[kind]) or 0) + 1
    local owner = OwnerOf(widget, explicitOwner)
    if metrics.byOwner[owner] == nil and #metrics.ownerOrder >= MAX_OWNER_METRICS then owner = "other" end
    metrics.cacheRepairsByOwner[owner] = (tonumber(metrics.cacheRepairsByOwner[owner]) or 0) + 1

    local claim = authorityClaims[widget]
    if type(claim) == "table" and claim.mode == "strict" then
        metrics.authority.violations = (tonumber(metrics.authority.violations) or 0) + 1
        metrics.authority.strictRepairs = (tonumber(metrics.authority.strictRepairs) or 0) + 1
        local claimOwner = tostring(claim.owner or owner)
        metrics.authority.byOwner[claimOwner] = (tonumber(metrics.authority.byOwner[claimOwner]) or 0) + 1
        metrics.authority.byField[kind] = (tonumber(metrics.authority.byField[kind]) or 0) + 1
        local d = S.DiagnosticsManager
        if type(d) == "table" and type(d.WarnRateLimited) == "function" then
            d:WarnRateLimited("ui_v3", "AUTHORITY_VIOLATION", 3000, "V3 Native 状态被 Diff Authority 之外的代码修改", {
                owner = claimOwner, field = kind, logicalId = widget and widget.rsUiLogicalId or nil,
            })
        end
    end
end

local function RepairCachedField(row, field, value)
    if row == nil then return end
    row[field] = value
end

local function SameAnchor(row, parent, x, y)
    if row == nil then return false end
    if row.anchorParent ~= nil or row.anchorX ~= nil or row.anchorY ~= nil then
        return row.anchorParent == parent and row.anchorX == x and row.anchorY == y
    end
    -- Compatibility with widgets primed by UI Factory v1.  Once the anchor is
    -- touched through DiffRenderer we migrate to scalar fields so hot HUDs do
    -- not allocate a table every time their screen position changes.
    local legacy = row.anchorTopLeft
    return type(legacy) == "table" and legacy.parent == parent and legacy.x == x and legacy.y == y
end

function UI:PrimeNativeState(widget, values)
    if widget == nil or type(values) ~= "table" then return false end
    local row = GetState(widget)
    for key, value in pairs(values) do row[key] = value end
    return true
end

-- Call this whenever legacy code must write a field directly on a widget that is
-- otherwise managed by DiffRenderer.  During migration it is preferable to
-- invalidate one field rather than clearing every cached presentation value.
function UI:InvalidateNativeState(widget, field)
    if widget == nil then return false end
    if field == nil then
        stateCache[widget] = nil
        return true
    end
    local row = stateCache[widget]
    if row ~= nil then row[tostring(field)] = nil end
    return true
end

-- V3 Native Authority contract. Legacy widgets may coexist during migration,
-- but a strict claim means DiffRenderer is the sole presentation writer. Any
-- later cache repair on that widget is a hard architecture violation.
function UI:ClaimNativeAuthority(widget, owner, mode)
    if widget == nil then return false, "widget required" end
    owner = NormalizeOwner(owner)
    mode = tostring(mode or "strict"):lower()
    if mode ~= "strict" and mode ~= "legacy" then return false, "invalid authority mode" end
    local current = authorityClaims[widget]
    if current ~= nil and tostring(current.owner) ~= owner then
        metrics.authority.conflicts = (tonumber(metrics.authority.conflicts) or 0) + 1
        metrics.authority.violations = (tonumber(metrics.authority.violations) or 0) + 1
        local d = S.DiagnosticsManager
        if type(d) == "table" and type(d.Warn) == "function" then
            d:Warn("ui_v3", "AUTHORITY_CONFLICT", "Native Widget Geometry Authority 冲突", {
                currentOwner = current.owner, requestedOwner = owner, logicalId = widget.rsUiLogicalId,
            })
        end
        return false, "authority conflict"
    end
    if current == nil then metrics.authority.claims = (tonumber(metrics.authority.claims) or 0) + 1 end
    authorityClaims[widget] = { owner = owner, mode = mode }
    widget.rsUiOwner = owner
    widget.rsUiAuthorityMode = mode
    return true
end

function UI:GetNativeAuthority(widget)
    return widget and authorityClaims[widget] or nil
end

function UI:ReleaseNativeAuthority(widget, owner)
    if widget == nil then return false end
    local current = authorityClaims[widget]
    if current == nil then return true end
    if owner ~= nil and NormalizeOwner(owner) ~= tostring(current.owner) then return false, "owner mismatch" end
    authorityClaims[widget] = nil
    widget.rsUiAuthorityMode = nil
    return true
end

function UI:AdoptV3Widget(widget, owner, logicalId)
    owner = NormalizeOwner(owner or "v3")
    local claimed, err = self:ClaimNativeAuthority(widget, owner, "strict")
    if not claimed then return false, err end
    return self:AdoptWidget(widget, owner, logicalId)
end

function UI:GetAuthoritySnapshot()
    local byOwner = {}
    for owner, count in pairs(metrics.authority.byOwner or {}) do byOwner[#byOwner + 1] = { owner=owner, violations=tonumber(count) or 0 } end
    table.sort(byOwner, function(a,b) if a.violations == b.violations then return a.owner < b.owner end return a.violations > b.violations end)
    return {
        claims = tonumber(metrics.authority.claims) or 0,
        conflicts = tonumber(metrics.authority.conflicts) or 0,
        violations = tonumber(metrics.authority.violations) or 0,
        strictRepairs = tonumber(metrics.authority.strictRepairs) or 0,
        liveClaims = (function() local count=0; for _ in pairs(authorityClaims) do count=count+1 end; return count end)(),
        byOwner = byOwner,
        byField = (function()
            local out = {}
            for field, count in pairs(metrics.authority.byField or {}) do out[field] = tonumber(count) or 0 end
            return out
        end)(),
    }
end

function UI:SetText(widget, value, owner)
    local usable = WidgetUsable(widget)
    if usable ~= true or type(widget.SetText) ~= "function" then return false end
    local text = tostring(value or "")
    local row = GetState(widget)
    if row.text == text then
        -- Legacy pages may still mutate native labels directly. Verify only on
        -- the cache-hit path so normal writes stay allocation-free and cheap.
        local nativeText, known = TryNativeText(widget)
        if not known or nativeText == text then
            RecordAttempt("SET_TEXT", widget, false, 0, owner)
            return false
        end
        RepairCachedField(row, "text", nativeText)
        RecordCacheRepair("text", widget, owner)
    end
    local ok, err = pcall(function() widget:SetText(text) end)
    if ok ~= true then RecordNativeSafetyFailure("SET_TEXT", widget, err, owner); return false end
    row.text = text
    RecordAttempt("SET_TEXT", widget, true, 1, owner)
    return true
end

function UI:SetVisible(widget, visible, owner)
    local usable = WidgetUsable(widget)
    if usable ~= true then return false end
    local preferSetVisible = widget.rsUiVisibilityMethod == "SetVisible"
    local hasShow = type(widget.Show) == "function"
    local hasSetVisible = type(widget.SetVisible) == "function"
    if not hasShow and not hasSetVisible then return false end

    local value = visible == true
    if value == false then self:ReleaseFocusWithin(widget, owner, "visibility_hide"); self:DisarmInputWithin(widget, owner, "visibility_hide") end
    local row = GetState(widget)
    if row.visible == value then
        local nativeVisible, known = TryNativeVisible(widget)
        if not known or nativeVisible == value then
            RecordAttempt("SHOW", widget, false, 0, owner)
            return false
        end
        RepairCachedField(row, "visible", nativeVisible)
        RecordCacheRepair("visible", widget, owner)
    end

    local nativeCalls = math.max(1, math.floor(tonumber(widget.rsUiVisibilityNativeCalls) or 1))
    local ok, result = pcall(function()
        if preferSetVisible and hasSetVisible then
            return widget:SetVisible(value)
        elseif hasShow then
            return widget:Show(value)
        else
            return widget:SetVisible(value)
        end
    end)
    local accepted, acceptErr = NativeBooleanSetterAccepted(ok, result, value)
    if accepted ~= true then
        RecordNativeSafetyFailure("SHOW", widget, acceptErr, owner)
        return false
    end
    row.visible = value
    RecordAttempt("SHOW", widget, true, nativeCalls, owner)
    return true
end

-- Transactional visibility facade. SetVisible keeps its historical "changed"
-- return contract, while EnsureVisible distinguishes a cache-hit/no-op from a
-- rejected Native transition. Component visibility publishes logical state only
-- after this method confirms that the requested presentation state is cached by
-- an accepted Native call.
function UI:EnsureVisible(widget, visible, owner)
    local usable, usableErr = WidgetUsable(widget)
    if usable ~= true then return false, false, tostring(usableErr or "widget_unusable") end
    local value = visible == true
    if value == false then self:ReleaseFocusWithin(widget, owner, "visibility_hide_ensure"); self:DisarmInputWithin(widget, owner, "visibility_hide_ensure") end
    local row = GetState(widget)
    if row.visible == value then
        local nativeVisible, known = TryNativeVisible(widget)
        if known == true and nativeVisible ~= value then
            RepairCachedField(row, "visible", nativeVisible)
            RecordCacheRepair("visible", widget, owner)
        else
            RecordAttempt("SHOW_ENSURE", widget, false, 0, owner)
            return true, false, nil
        end
    end
    local changed = self:SetVisible(widget, value, owner)
    if changed == true then return true, true, nil end
    row = GetState(widget)
    if row.visible == value then return true, false, nil end
    return false, false, "native_visibility_rejected"
end

-- Generic color diff for native drawables, text styles and small composite
-- adapters that expose SetColor(r,g,b,a).  Keeping this in the framework is
-- important for high-frequency HUDs such as Healer markers: color animation
-- may legitimately repaint, while static states should produce zero native
-- writes after the first application.
function UI:SetColor(widget, red, green, blue, alpha, owner)
    local usable = WidgetUsable(widget)
    if usable ~= true then return false end
    local r = tonumber(red) or 0
    local g = tonumber(green) or 0
    local b = tonumber(blue) or 0
    local a = tonumber(alpha) or 1
    local row = GetState(widget)
    local sameColor = row.colorR == r and row.colorG == g and row.colorB == b and row.colorA == a
    if not sameColor and row.colorR == nil then
        -- Compatibility with early v1 callers that primed a compact array.
        local legacy = row.color
        sameColor = type(legacy) == "table" and legacy[1] == r and legacy[2] == g and legacy[3] == b and legacy[4] == a
    end
    if sameColor then
        RecordAttempt("SET_COLOR", widget, false, 0, owner)
        return false
    end
    -- v13: LABEL widgets carry text color on their style object (RU TextStyle
    -- SetColor(r,g,b,a)); the widget itself has none -- widget-level SetColor
    -- only exists on drawables. Every working reference colors labels via
    -- style (easypull.lua:267, plates rp_ui.lua:2348, theme ApplyTextColor),
    -- so callers that pass the label widget directly (combat visual guide
    -- dots) must resolve to the style here, or they gate visibility behind a
    -- write that can never succeed.
    local target = widget
    if type(target.SetColor) ~= "function" then
        local style = target.style
        if style == nil or type(style.SetColor) ~= "function" then
            RecordAttempt("SET_COLOR", widget, false, 0, owner)
            return false
        end
        target = style
    end
    local ok, err = pcall(function() target:SetColor(r, g, b, a) end)
    if ok ~= true then RecordNativeSafetyFailure("SET_COLOR", widget, err, owner); return false end
    row.colorR, row.colorG, row.colorB, row.colorA = r, g, b, a
    row.color = nil
    RecordAttempt("SET_COLOR", widget, true, math.max(1, math.floor(tonumber(widget.rsUiColorNativeCalls) or 1)), owner)
    return true
end

-- Icon drawables in RU expose ClearAllTextures/AddTexture rather than a
-- universal SetTexture contract. Cache the path here so HUD/list components can
-- refresh the same icon snapshot without repeated native texture writes.
function UI:SetIconTexture(drawable, path, owner)
    if drawable == nil then return false end
    local value = tostring(path or "")
    local row = GetState(drawable)
    if row.iconTexture == value then RecordAttempt("ICON_TEXTURE", drawable, false, 0, owner); return false end
    local calls = 0
    if type(drawable.ClearAllTextures) == "function" then
        local ok = pcall(function() drawable:ClearAllTextures() end)
        if not ok then return false end
        calls = calls + 1
    end
    if value ~= "" then
        if type(drawable.AddTexture) ~= "function" then return false end
        local ok = pcall(function() drawable:AddTexture(value) end)
        if not ok then return false end
        calls = calls + 1
    end
    if calls == 0 then return false end
    row.iconTexture = value
    RecordAttempt("ICON_TEXTURE", drawable, true, calls, owner)
    return true
end


-- Native interaction geometry lease. During StartMoving/StartSizing the client
-- temporarily owns the top-level window geometry so the strict diff renderer
-- must not immediately write the pre-gesture anchor/extent back. The lease is
-- deliberately narrow: only SetAnchor/SetExtent are deferred, all other V3
-- presentation fields remain under normal strict authority.
function UI:BeginNativeGeometryLease(widget, owner, reason)
    if widget == nil then return false, "widget required" end
    local normalizedOwner = NormalizeOwner(owner)
    local claim = authorityClaims[widget]
    if claim ~= nil and tostring(claim.owner) ~= normalizedOwner then
        metrics.geometryLease.conflicts = (tonumber(metrics.geometryLease.conflicts) or 0) + 1
        return false, "authority owner mismatch"
    end
    local current = geometryLeases[widget]
    if current ~= nil and tostring(current.owner) ~= normalizedOwner then
        metrics.geometryLease.conflicts = (tonumber(metrics.geometryLease.conflicts) or 0) + 1
        return false, "geometry lease conflict"
    end
    geometryLeases[widget] = { owner = normalizedOwner, reason = tostring(reason or "native_interaction") }
    metrics.geometryLease.begins = (tonumber(metrics.geometryLease.begins) or 0) + 1
    return true
end

function UI:EndNativeGeometryLease(widget, owner)
    if widget == nil then return false end
    local current = geometryLeases[widget]
    if current == nil then return true end
    if owner ~= nil and NormalizeOwner(owner) ~= tostring(current.owner) then
        metrics.geometryLease.conflicts = (tonumber(metrics.geometryLease.conflicts) or 0) + 1
        return false, "geometry lease owner mismatch"
    end
    geometryLeases[widget] = nil
    -- Native movement has changed the physical state behind the diff cache. The
    -- next committed V3 write must re-prime from the final native rectangle.
    self:InvalidateNativeState(widget)
    metrics.geometryLease.ends = (tonumber(metrics.geometryLease.ends) or 0) + 1
    return true
end

function UI:GetNativeGeometryLease(widget)
    return widget and geometryLeases[widget] or nil
end

local function GeometryWriteDeferred(widget, owner, field)
    local lease = widget and geometryLeases[widget] or nil
    if lease == nil then return false end
    if owner ~= nil and NormalizeOwner(owner) ~= tostring(lease.owner) then
        metrics.geometryLease.conflicts = (tonumber(metrics.geometryLease.conflicts) or 0) + 1
    end
    if field == "anchor" then
        metrics.geometryLease.deferredAnchors = (tonumber(metrics.geometryLease.deferredAnchors) or 0) + 1
    else
        metrics.geometryLease.deferredExtents = (tonumber(metrics.geometryLease.deferredExtents) or 0) + 1
    end
    return true
end

local function RefreshCompositeExtent(widget)
    if widget == nil then return false end
    -- Custom horizontal sliders own child geometry (rail/thumb/drag surface).
    -- A Native root SetExtent therefore is not a complete layout transaction.
    -- Keep this hook centralized so both RSUI Slider and older framework fields
    -- receive identical resize semantics, including after a code hot-reload.
    if widget.rsCustomHorizontal == true and type(UI.UpdateSliderVisual) == "function" then
        local ok, changed = pcall(function() return UI:UpdateSliderVisual(widget, widget.rsValue) end)
        return ok == true and changed == true
    end
    return false
end

function UI:SetExtent(widget, width, height, owner)
    local usable = WidgetUsable(widget)
    if usable ~= true or type(widget.SetExtent) ~= "function" then return false end
    if GeometryWriteDeferred(widget, owner, "extent") then RecordAttempt("SET_EXTENT", widget, false, 0, owner); return false end
    local w = math.max(1, tonumber(width) or 1)
    local h = math.max(1, tonumber(height) or 1)
    local row = GetState(widget)
    if row.width == w and row.height == h then
        local nativeW, nativeH, known = TryNativeExtent(widget)
        local scale = 1
        if S.Layout ~= nil and type(S.Layout.GetContext) == "function" then
            local ok, context = pcall(function() return S.Layout:GetContext() end)
            -- Width/height passed into SetExtent are already Suite logical
            -- coordinates (including addonScale). Native getters may return the
            -- same logical extent or that extent multiplied by the client
            -- UI:GetUIScale value. addonScale must not be applied twice.
            if ok and type(context) == "table" then scale = math.max(0.01, tonumber(context.uiScale) or 1) end
        end
        -- RU clients have exposed GetWidth/GetHeight in both logical space and
        -- client-UI-scaled physical space. Either getter contract is valid.
        -- Comparing against addonScale here used to report an external writer on
        -- almost every layout cache hit whenever UI scale differed from 1.0.
        local epsilon = math.max(0.75, scale)
        local rawMatch = known and math.abs(nativeW - w) <= epsilon and math.abs(nativeH - h) <= epsilon
        local scaledMatch = known and math.abs(nativeW - w * scale) <= epsilon and math.abs(nativeH - h * scale) <= epsilon
        if not known or rawMatch or scaledMatch then
            RefreshCompositeExtent(widget)
            RecordAttempt("SET_EXTENT", widget, false, 0, owner)
            return false
        end
        -- Do not copy an unknown native unit-space back into the logical cache.
        -- The authoritative write below restores the requested logical extent.
        RecordCacheRepair("extent", widget, owner)
    end
    local ok, err = pcall(function() widget:SetExtent(w, h) end)
    if ok ~= true then RecordNativeSafetyFailure("SET_EXTENT", widget, err, owner); return false end
    row.width, row.height = w, h
    RefreshCompositeExtent(widget)
    RecordAttempt("SET_EXTENT", widget, true, 1, owner)
    return true
end

UI.GeometryStateTransactionContractVersion = 1

-- Geometry writes historically returned only "changed", making cache-hit/no-op
-- indistinguishable from a rejected Native write to callers that need to commit
-- persistent placement. EnsureExtent/EnsureAnchor provide accepted/changed/error
-- semantics for low-frequency window/layout transactions without changing the
-- hot-path SetExtent/SetAnchor contract used by diff renderers.
function UI:EnsureExtent(widget, width, height, owner)
    local usable, usableErr = WidgetUsable(widget)
    if usable ~= true then return false, false, tostring(usableErr or "widget_unusable") end
    if type(widget.SetExtent) ~= "function" then return false, false, "native_extent_unavailable" end
    local w = math.max(1, tonumber(width) or 1)
    local h = math.max(1, tonumber(height) or 1)
    local row = GetState(widget)
    if row.width == w and row.height == h then
        local nativeW, nativeH, known = TryNativeExtent(widget)
        if known ~= true then
            RecordAttempt("SET_EXTENT_ENSURE", widget, false, 0, owner)
            return true, false, nil
        end
        local scale = 1
        if S.Layout ~= nil and type(S.Layout.GetContext) == "function" then
            local ok, context = pcall(function() return S.Layout:GetContext() end)
            if ok and type(context) == "table" then scale = math.max(0.01, tonumber(context.uiScale) or 1) end
        end
        local epsilon = math.max(0.75, scale)
        local rawMatch = math.abs(nativeW - w) <= epsilon and math.abs(nativeH - h) <= epsilon
        local scaledMatch = math.abs(nativeW - w * scale) <= epsilon and math.abs(nativeH - h * scale) <= epsilon
        if rawMatch or scaledMatch then
            RecordAttempt("SET_EXTENT_ENSURE", widget, false, 0, owner)
            return true, false, nil
        end
    end
    local changed = self:SetExtent(widget, w, h, owner)
    if changed == true then return true, true, nil end
    return false, false, "native_extent_rejected"
end

function UI:SetAnchor(widget, parent, x, y, owner)
    local usable = WidgetUsable(widget)
    if usable ~= true or type(widget.AddAnchor) ~= "function" then return false end
    local nativeParent
    nativeParent, parent = self:ResolveNativeAnchorTarget(parent)
    if parent == nil or nativeParent == nil then RecordNativeSafetyFailure("SET_ANCHOR", widget, "parent_required", owner); return false end
    if GeometryWriteDeferred(widget, owner, "anchor") then RecordAttempt("SET_ANCHOR", widget, false, 0, owner); return false end
    local ax, ay = tonumber(x) or 0, tonumber(y) or 0
    local row = GetState(widget)
    if SameAnchor(row, parent, ax, ay) then
        local nativeMatches, known = TryNativeAnchorMatches(widget, parent, ax, ay)
        if not known or nativeMatches == true then
            RecordAttempt("SET_ANCHOR", widget, false, 0, owner)
            return false
        end
        RecordCacheRepair("anchor", widget, owner)
    end
    local nativeCalls = 0
    if type(widget.RemoveAllAnchors) == "function" then
        local removeOk, removeErr = pcall(function() widget:RemoveAllAnchors() end)
        if removeOk ~= true then RecordNativeSafetyFailure("REMOVE_ANCHORS", widget, removeErr, owner); return false end
        nativeCalls = nativeCalls + 1
    end
    local anchorOk, anchorErr = pcall(function() widget:AddAnchor("TOPLEFT", nativeParent, ax, ay) end)
    if anchorOk ~= true then
        RecordNativeSafetyFailure("SET_ANCHOR", widget, anchorErr, owner)
        return false
    end
    nativeCalls = nativeCalls + 1
    row.anchorParent, row.anchorX, row.anchorY = parent, ax, ay
    row.anchorTopLeft = nil
    RecordAttempt("SET_ANCHOR", widget, true, nativeCalls, owner)
    return true
end

function UI:EnsureAnchor(widget, parent, x, y, owner)
    local usable, usableErr = WidgetUsable(widget)
    if usable ~= true then return false, false, tostring(usableErr or "widget_unusable") end
    if type(widget.AddAnchor) ~= "function" then return false, false, "native_anchor_unavailable" end
    local nativeParent, logicalParent = self:ResolveNativeAnchorTarget(parent)
    if logicalParent == nil or nativeParent == nil then return false, false, "parent_required" end
    local ax, ay = tonumber(x) or 0, tonumber(y) or 0
    local row = GetState(widget)
    if SameAnchor(row, logicalParent, ax, ay) then
        local nativeMatches, known = TryNativeAnchorMatches(widget, logicalParent, ax, ay)
        if known ~= true or nativeMatches == true then
            RecordAttempt("SET_ANCHOR_ENSURE", widget, false, 0, owner)
            return true, false, nil
        end
    end
    local changed = self:SetAnchor(widget, logicalParent, ax, ay, owner)
    if changed == true then return true, true, nil end
    return false, false, "native_anchor_rejected"
end

-- Screen Snap Adapter -------------------------------------------------------
--
-- Top-level controls should not duplicate sibling discovery or geometry math.
-- Persistence remains owned by the feature/domain; this adapter only registers
-- visible screen controls and commits a snap result through the normal diff
-- renderer so UIParent root-anchor semantics stay centralized.
function UI:RegisterScreenSnap(id, widget, options)
    if S.Layout == nil or type(S.Layout.RegisterScreenSnap) ~= "function" or widget == nil then return false end
    options = type(options) == "table" and options or {}
    local normalized = {}
    for key, value in pairs(options) do normalized[key] = value end
    normalized.snapGroup = tostring(options.snapGroup or "screen_controls")
    normalized.snapKind = tostring(options.snapKind or "button")
    if normalized.ensureNow == nil then normalized.ensureNow = false end
    return S.Layout:RegisterScreenSnap(tostring(id or ""), widget, normalized)
end

function UI:UnregisterScreenSnap(id)
    if S.Layout == nil or type(S.Layout.UnregisterScreenSnap) ~= "function" then return false end
    S.Layout:UnregisterScreenSnap(tostring(id or ""))
    return true
end

function UI:ResolveScreenSnap(id, x, y, width, height, options)
    if S.Layout == nil or type(S.Layout.ResolveScreenSnap) ~= "function" then return x, y, false, nil end
    return S.Layout:ResolveScreenSnap(tostring(id or ""), x, y, width, height, options)
end

function UI:CommitScreenSnap(id, widget, options)
    options = type(options) == "table" and options or {}
    if widget == nil or S.Layout == nil or type(S.Layout.GetLogicalRect) ~= "function" then return false, nil, nil, false, nil end
    local x, y, width, height = S.Layout:GetLogicalRect(widget)
    if tonumber(x) == nil or tonumber(y) == nil then return false, x, y, false, nil end
    local sx, sy, snapped, targetId = self:ResolveScreenSnap(id, x, y, width, height, options)
    if snapped == true then
        self:SetAnchor(widget, UIParent, sx, sy, options.owner or "screen_snap")
        x, y = sx, sy
    end
    return true, x, y, snapped == true, targetId
end

function UI:GetScreenSnapSnapshot()
    if S.Layout ~= nil and type(S.Layout.GetScreenSnapSnapshot) == "function" then return S.Layout:GetScreenSnapSnapshot() end
    return { version = 1, registered = 0, visible = 0, resolves = 0, snaps = 0, candidates = 0 }
end

function UI:SetEnabled(widget, enabled, owner)
    local usable = WidgetUsable(widget)
    if usable ~= true then return false end
    -- Composite controls may own their actual hit surface on a child widget.
    -- A native WidgetBase:Enable() on the root is therefore insufficient. Only
    -- controls that explicitly publish this adapter bypass the native root path.
    local enabledAdapter = widget.rsUiSetEnabledAdapter
    local hasAdapter = type(enabledAdapter) == "function"
    local hasEnable = type(widget.Enable) == "function"
    local hasSetEnabled = type(widget.SetEnabled) == "function"
    if not hasAdapter and not hasEnable and not hasSetEnabled then return false end
    local value = enabled ~= false
    if value == false then self:ReleaseFocusWithin(widget, owner, "enabled_false"); self:DisarmInputWithin(widget, owner, "enabled_false") end
    local row = GetState(widget)
    if row.enabled == value then RecordAttempt("ENABLE", widget, false, 0, owner); return false end
    local ok, result
    if hasAdapter then
        ok, result = pcall(function() return enabledAdapter(widget, value) end)
        -- Composite adapters are Lua transaction callbacks, not opaque Native
        -- setters. Their explicit false remains an authoritative veto.
        if ok ~= true or result == false then
            RecordNativeSafetyFailure("ENABLE_ADAPTER", widget, ok and "adapter_rejected" or result, owner)
            return false
        end
    else
        ok, result = pcall(function()
            if hasEnable then return widget:Enable(value) end
            return widget:SetEnabled(value)
        end)
        local accepted, acceptErr = NativeBooleanSetterAccepted(ok, result, value)
        if accepted ~= true then
            RecordNativeSafetyFailure("ENABLE", widget, acceptErr, owner)
            return false
        end
    end
    row.enabled = value
    RecordAttempt("ENABLE", widget, true, 1, owner)
    return true
end

-- Transactional facade for component/runtime callers that need to know whether
-- the requested native enabled state is actually established. SetEnabled keeps
-- its historical "changed" return contract (false also means cache hit), while
-- EnsureEnabled disambiguates cache-hit success from native rejection. This is
-- deliberately cold/event-driven; it never polls native state.
function UI:EnsureEnabled(widget, enabled, owner)
    local usable, usableErr = WidgetUsable(widget)
    if usable ~= true then return false, false, tostring(usableErr or "widget_unusable") end
    local value = enabled ~= false
    if value == false then self:ReleaseFocusWithin(widget, owner, "enabled_false_ensure"); self:DisarmInputWithin(widget, owner, "enabled_false_ensure") end
    local row = GetState(widget)
    if row.enabled == value then
        RecordAttempt("ENABLE_ENSURE", widget, false, 0, owner)
        return true, false, nil
    end
    local changed = self:SetEnabled(widget, value, owner)
    if changed == true then return true, true, nil end
    -- SetEnabled only updates the cache after an accepted native write. If the
    -- desired value is still absent here, the native transition was rejected.
    row = GetState(widget)
    if row.enabled == value then return true, false, nil end
    return false, false, "native_enable_rejected"
end

function UI:SetPickable(widget, enabled, owner)
    local usable = WidgetUsable(widget)
    if usable ~= true then return false end
    local value = enabled == true
    if value == false then self:ReleaseFocusWithin(widget, owner, "pickable_false"); self:DisarmInputWithin(widget, owner, "pickable_false") end
    local row = GetState(widget)
    if row.pickable == value then RecordAttempt("PICKABLE", widget, false, 0, owner); return false end

    local calls = 0
    if type(widget.EnablePick) == "function" then
        local ok, result = pcall(function() return widget:EnablePick(value) end)
        local accepted, acceptErr = NativeBooleanSetterAccepted(ok, result, value)
        if accepted ~= true then RecordNativeSafetyFailure("ENABLE_PICK", widget, acceptErr, owner); return false end
        calls = calls + 1
    end
    if type(widget.Clickable) == "function" then
        local ok, result = pcall(function() return widget:Clickable(value) end)
        local accepted, acceptErr = NativeBooleanSetterAccepted(ok, result, value)
        if accepted ~= true then RecordNativeSafetyFailure("CLICKABLE", widget, acceptErr, owner); return false end
        calls = calls + 1
    end
    -- Do not cache a successful presentation state when the native widget does
    -- not expose any hit-test method. Otherwise a later real adapter/method can
    -- be skipped forever because the cache already claims the value was applied.
    if calls == 0 then
        RecordAttempt("PICKABLE", widget, false, 0, owner)
        return false
    end
    row.pickable = value
    RecordAttempt("PICKABLE", widget, true, calls, owner)
    return true
end

-- Same disambiguation contract as EnsureEnabled for hit-test state. This is
-- useful for runtime calibration/lock transitions where a silent pickable-state
-- mismatch would leave a visible control behaving opposite to its logical state.
function UI:EnsurePickable(widget, enabled, owner)
    local usable, usableErr = WidgetUsable(widget)
    if usable ~= true then return false, false, tostring(usableErr or "widget_unusable") end
    local value = enabled == true
    if value == false then self:ReleaseFocusWithin(widget, owner, "pickable_false_ensure"); self:DisarmInputWithin(widget, owner, "pickable_false_ensure") end
    local row = GetState(widget)
    if row.pickable == value then
        RecordAttempt("PICKABLE_ENSURE", widget, false, 0, owner)
        return true, false, nil
    end
    local changed = self:SetPickable(widget, value, owner)
    if changed == true then return true, true, nil end
    row = GetState(widget)
    if row.pickable == value then return true, false, nil end
    return false, false, "native_pickable_rejected"
end

-- RETURN CONTRACT (v13): SetFontSize returns false BOTH for a REJECTED native
-- write AND for a cached no-op ("already at this size"). Visibility-critical
-- render chains must NOT treat that ambiguous false as fatal — the .18.133
-- unit-line outage was exactly PlaceUnitDot bailing on a no-op false before
-- showing the dot. Use EnsureFontSize when the distinction matters; style
-- writers should stay best-effort.
function UI:SetFontSize(widget, size, owner)
    local usable = WidgetUsable(widget)
    if usable ~= true or widget.style == nil or type(widget.style.SetFontSize) ~= "function" then return false end
    local value = tonumber(size)
    if value == nil then return false end
    local row = GetState(widget)
    if row.fontSize == value then RecordAttempt("FONT_SIZE", widget, false, 0, owner); return false end
    local ok, err = pcall(function() widget.style:SetFontSize(value) end)
    if ok ~= true then RecordNativeSafetyFailure("FONT_SIZE", widget, err, owner); return false end
    row.fontSize = value
    widget.rsAppliedFontSize = value
    RecordAttempt("FONT_SIZE", widget, true, 1, owner)
    return true
end

-- Disambiguating facade for SetFontSize (same (ok, changed, err) contract as
-- EnsureVisible/EnsureAnchor/EnsurePickable). "ok=true, changed=false" is a
-- cached no-op; "ok=false" is a genuine rejection. Added after the .18.133
-- unit-line outage: CreateLabel primes row.fontSize via PrimeNativeState, so
-- the first SetFontSize(sameValue) legitimately returns false and a caller
-- that conflated the two meanings hid every dot in the pool.
function UI:EnsureFontSize(widget, size, owner)
    local usable, usableErr = WidgetUsable(widget)
    if usable ~= true then return false, false, tostring(usableErr or "widget_unusable") end
    local value = tonumber(size)
    if value == nil then return false, false, "font_size_required" end
    if widget.style == nil or type(widget.style.SetFontSize) ~= "function" then return false, false, "native_font_size_unavailable" end
    local row = GetState(widget)
    if row.fontSize == value then
        RecordAttempt("FONT_SIZE_ENSURE", widget, false, 0, owner)
        return true, false, nil
    end
    local changed = self:SetFontSize(widget, value, owner)
    if changed == true then return true, true, nil end
    row = GetState(widget)
    if row.fontSize == value then return true, false, nil end
    return false, false, "native_font_size_rejected"
end

function UI:SetAlpha(widget, alpha, owner)
    local usable = WidgetUsable(widget)
    if usable ~= true or type(widget.SetAlpha) ~= "function" then return false end
    local value = math.max(0, math.min(1, tonumber(alpha) or 1))
    local row = GetState(widget)
    if row.alpha == value then RecordAttempt("SET_ALPHA", widget, false, 0, owner); return false end
    local ok, err = pcall(function() widget:SetAlpha(value) end)
    if ok ~= true then RecordNativeSafetyFailure("SET_ALPHA", widget, err, owner); return false end
    row.alpha = value
    RecordAttempt("SET_ALPHA", widget, true, 1, owner)
    return true
end

-- Transactional alpha facade for low-frequency settings/window state changes.
-- SetAlpha retains the historical changed/no-op return value, while EnsureAlpha
-- tells callers whether the requested native state is established before they
-- publish an Authority-side opacity value.
function UI:EnsureAlpha(widget, alpha, owner)
    local usable, usableErr = WidgetUsable(widget)
    if usable ~= true then return false, false, tostring(usableErr or "widget_unusable") end
    if type(widget.SetAlpha) ~= "function" then return false, false, "native_alpha_unavailable" end
    local value = math.max(0, math.min(1, tonumber(alpha) or 1))
    local row = GetState(widget)
    if row.alpha == value then
        RecordAttempt("SET_ALPHA_ENSURE", widget, false, 0, owner)
        return true, false, nil
    end
    local changed = self:SetAlpha(widget, value, owner)
    if changed == true then return true, true, nil end
    row = GetState(widget)
    if row.alpha == value then return true, false, nil end
    return false, false, "native_alpha_rejected"
end

-- ScaleBox is event/layout driven; cache native SetScale so repeated layout at
-- the same resolution produces zero writes. SetScale is present in the RU UI
-- allowlist, but callers should still provide a non-scale fallback because
-- individual widget classes may omit the method.
function UI:SetScale(widget, scale, owner)
    local usable = WidgetUsable(widget)
    if usable ~= true or type(widget.SetScale) ~= "function" then return false end
    local value = math.max(0.01, tonumber(scale) or 1)
    local row = GetState(widget)
    if row.scale == value then RecordAttempt("SET_SCALE", widget, false, 0, owner); return false end
    local ok, err = pcall(function() widget:SetScale(value) end)
    if ok ~= true then RecordNativeSafetyFailure("SET_SCALE", widget, err, owner); return false end
    row.scale = value
    RecordAttempt("SET_SCALE", widget, true, 1, owner)
    return true
end

-- Tone/button styling is delegated to Theme so there is still only one color
-- Authority. Theme v1 now returns whether a real native repaint was needed.
function UI:SetLabelTone(widget, tone, owner)
    if WidgetUsable(widget) ~= true then return false end
    if S.Theme == nil or type(S.Theme.SetLabelTone) ~= "function" then return false end
    local changed = S.Theme:SetLabelTone(widget, tone) == true
    RecordAttempt("LABEL_TONE", widget, changed, changed and 1 or 0, owner)
    return changed
end

function UI:SetButtonActive(widget, active, owner)
    if WidgetUsable(widget) ~= true then return false end
    if S.Theme == nil or type(S.Theme.SetButtonActive) ~= "function" then return false end
    local changed = S.Theme:SetButtonActive(widget, active == true) == true
    -- A gradient button repaints two drawables (six band calls) internally, but
    -- expose one logical style write here; Theme remains the detailed native
    -- styling Authority.
    RecordAttempt("BUTTON_ACTIVE", widget, changed, changed and 1 or 0, owner)
    return changed
end

function UI:SetButtonHovered(widget, hovered, owner)
    if WidgetUsable(widget) ~= true then return false end
    if S.Theme == nil or type(S.Theme.SetButtonHovered) ~= "function" then return false end
    local changed = S.Theme:SetButtonHovered(widget, hovered == true) == true
    RecordAttempt("BUTTON_HOVER", widget, changed, changed and 1 or 0, owner)
    return changed
end

function UI:SetEllipsis(widget, enabled, owner)
    if WidgetUsable(widget) ~= true then return false end
    if S.Theme == nil or type(S.Theme.SetEllipsis) ~= "function" then return false end
    local changed = S.Theme:SetEllipsis(widget, enabled == true) == true
    RecordAttempt("ELLIPSIS", widget, changed, changed and 1 or 0, owner)
    return changed
end

local function EnsureOwner(ownerId)
    ownerId = NormalizeOwner(ownerId)
    local row = lifecycle.owners[ownerId]
    if row == nil then
        row = {
            id = ownerId,
            widgets = {},
            widgetSet = setmetatable({}, { __mode = "k" }),
            handlerKeys = setmetatable({}, { __mode = "k" }),
            released = false,
        }
        lifecycle.owners[ownerId] = row
    end
    return row
end

-- Adopt means "this owner is responsible for the Lua/native references".  It
-- does not transfer business state Authority and it does not destroy widgets.
function UI:AdoptWidget(widget, ownerId, logicalId)
    if widget == nil then return false end
    ownerId = OwnerOf(widget, ownerId)
    widget.rsUiOwner = ownerId
    widget.rsUiReleased = false
    if logicalId ~= nil then widget.rsUiLogicalId = tostring(logicalId) end

    local owner = EnsureOwner(ownerId)
    RegisterInputTarget(widget)
    if owner.widgetSet[widget] == true then return true end
    owner.widgetSet[widget] = true
    owner.widgets[#owner.widgets + 1] = widget
    metrics.lifecycle.adopted = metrics.lifecycle.adopted + 1
    return true
end

function UI:RegisterHandlerBinding(widget, eventName)
    if widget == nil or eventName == nil then return false end
    local ownerId = OwnerOf(widget)
    local owner = EnsureOwner(ownerId)
    local events = owner.handlerKeys[widget]
    if events == nil then events = {}; owner.handlerKeys[widget] = events end
    local key = tostring(eventName)
    if events[key] == true then return true end
    events[key] = true
    metrics.lifecycle.handlerBindings = metrics.lifecycle.handlerBindings + 1
    return true
end

function UI:ReleaseOwner(ownerId)
    ownerId = NormalizeOwner(ownerId)
    local owner = lifecycle.owners[ownerId]
    if owner == nil or owner.released == true then return 0 end
    owner.released = true

    local releasedHandlers, hidden = 0, 0
    for widget, events in pairs(owner.handlerKeys) do
        if widget ~= nil and type(events) == "table" and type(widget.ReleaseHandler) == "function" then
            for eventName in pairs(events) do
                local ok = pcall(function() widget:ReleaseHandler(eventName) end)
                if ok then releasedHandlers = releasedHandlers + 1 end
            end
        end
    end

    for _, widget in ipairs(owner.widgets) do
        if widget ~= nil then
            if IsInputTarget(widget) then self:RetireInputWidget(widget, ownerId, "owner_release") end
            widget.rsUiReleased = true
            if type(UI.SetVisible) == "function" then
                local ok = pcall(function() UI:SetVisible(widget, false, ownerId) end)
                if ok then hidden = hidden + 1 end
            end
            stateCache[widget] = nil
            local logicalId = widget.rsUiLogicalId
            if logicalId ~= nil and UI.controls ~= nil and UI.controls[logicalId] == widget then UI.controls[logicalId] = nil end
        end
    end

    lifecycle.owners[ownerId] = nil
    metrics.lifecycle.releasedOwners = metrics.lifecycle.releasedOwners + 1
    metrics.lifecycle.releasedHandlers = metrics.lifecycle.releasedHandlers + releasedHandlers
    metrics.lifecycle.hiddenOnRelease = metrics.lifecycle.hiddenOnRelease + hidden

    if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Info) == "function" then
        S.DiagnosticsManager:Info("ui", "UI_OWNER_RELEASED", "UI owner 已释放", {
            owner = ownerId,
            handlers = releasedHandlers,
            hidden = hidden,
        })
    end
    return releasedHandlers + hidden
end

function UI:CreateScope(ownerId)
    ownerId = NormalizeOwner(ownerId)
    EnsureOwner(ownerId)
    local scope = { ownerId = ownerId, released = false }

    function scope:Adopt(widget, logicalId)
        if self.released then return false end
        return UI:AdoptWidget(widget, self.ownerId, logicalId)
    end

    function scope:Bind(widget, eventName, fn, label)
        if self.released or widget == nil then return false end
        UI:AdoptWidget(widget, self.ownerId)
        return UI:SafeHandler(widget, eventName, fn, label)
    end

    function scope:Release()
        if self.released then return 0 end
        self.released = true
        return UI:ReleaseOwner(self.ownerId)
    end

    return scope
end

local function CountWeakKeys(tbl)
    local count = 0
    for _ in pairs(tbl or {}) do count = count + 1 end
    return count
end

function UI:ResetFrameworkMetrics()
    metrics.attempts = 0
    metrics.writes = 0
    metrics.skips = 0
    metrics.nativeCalls = 0
    metrics.cacheRepairs = 0
    metrics.cacheRepairsByField = {}
    metrics.cacheRepairsByOwner = {}
    metrics.authority.claims = 0
    metrics.authority.conflicts = 0
    metrics.authority.violations = 0
    metrics.authority.strictRepairs = 0
    metrics.authority.byOwner = {}
    metrics.authority.byField = {}
    metrics.byOp = {}
    metrics.byOwner = {}
    metrics.ownerOrder = {}
    metrics.lifecycle.adopted = 0
    metrics.lifecycle.handlerBindings = 0
    metrics.lifecycle.releasedOwners = 0
    metrics.lifecycle.releasedHandlers = 0
    metrics.lifecycle.hiddenOnRelease = 0
    metrics.lifecycle.inputTargets = 0
    metrics.lifecycle.focusClears = 0
    metrics.lifecycle.focusClearFailures = 0
    metrics.lifecycle.inputRetires = 0
    metrics.nativeSafety.staleRejects = 0
    metrics.nativeSafety.registrationRejects = 0
    metrics.nativeSafety.degradedRejects = 0
    metrics.nativeSafety.callFailures = 0
    metrics.nativeSafety.anchorParentRepairs = 0
    if UI.LayoutV2 ~= nil and type(UI.LayoutV2.ResetMetrics) == "function" then UI.LayoutV2:ResetMetrics() end
    if UI.Binding ~= nil and type(UI.Binding.ResetMetrics) == "function" then UI.Binding:ResetMetrics() end
    if UI.WindowShell ~= nil and type(UI.WindowShell.ResetMetrics) == "function" then UI.WindowShell:ResetMetrics() end
    if S.RSUI ~= nil and S.RSUI.FloatingSurface ~= nil and type(S.RSUI.FloatingSurface.ResetMetrics) == "function" then S.RSUI.FloatingSurface:ResetMetrics() end
    if S.RSUI ~= nil and type(S.RSUI.ResetMetrics) == "function" then S.RSUI:ResetMetrics() end
    return true
end

function UI:GetFrameworkSnapshot()
    local byOp = {}
    for op, row in pairs(metrics.byOp) do
        byOp[#byOp + 1] = {
            op = op,
            attempts = tonumber(row.attempts) or 0,
            writes = tonumber(row.writes) or 0,
            skips = tonumber(row.skips) or 0,
            nativeCalls = tonumber(row.nativeCalls) or 0,
        }
    end
    table.sort(byOp, function(a, b)
        if a.nativeCalls == b.nativeCalls then return a.op < b.op end
        return a.nativeCalls > b.nativeCalls
    end)

    local byOwner = {}
    for owner, row in pairs(metrics.byOwner) do
        byOwner[#byOwner + 1] = {
            owner = owner,
            attempts = tonumber(row.attempts) or 0,
            writes = tonumber(row.writes) or 0,
            skips = tonumber(row.skips) or 0,
            nativeCalls = tonumber(row.nativeCalls) or 0,
        }
    end
    table.sort(byOwner, function(a, b)
        if a.nativeCalls == b.nativeCalls then return a.owner < b.owner end
        return a.nativeCalls > b.nativeCalls
    end)

    local cacheRepairsByField = {}
    for field, count in pairs(metrics.cacheRepairsByField or {}) do cacheRepairsByField[field] = tonumber(count) or 0 end
    local cacheRepairsByOwner = {}
    for owner, count in pairs(metrics.cacheRepairsByOwner or {}) do
        cacheRepairsByOwner[#cacheRepairsByOwner + 1] = { owner = owner, count = tonumber(count) or 0 }
    end
    table.sort(cacheRepairsByOwner, function(a, b)
        if a.count == b.count then return a.owner < b.owner end
        return a.count > b.count
    end)

    local ownerCount = 0
    for _ in pairs(lifecycle.owners) do ownerCount = ownerCount + 1 end
    local skipRatio = metrics.attempts > 0 and (metrics.skips / metrics.attempts) or 0

    return {
        version = FRAMEWORK_VERSION,
        cachedWidgets = CountWeakKeys(stateCache),
        owners = ownerCount,
        attempts = metrics.attempts,
        writes = metrics.writes,
        skips = metrics.skips,
        nativeCalls = metrics.nativeCalls,
        cacheRepairs = tonumber(metrics.cacheRepairs) or 0,
        cacheRepairsByField = cacheRepairsByField,
        cacheRepairsByOwner = cacheRepairsByOwner,
        authority = self:GetAuthoritySnapshot(),
        skipRatio = skipRatio,
        byOp = byOp,
        byOwner = byOwner,
        lifecycle = {
            adopted = metrics.lifecycle.adopted,
            handlerBindings = metrics.lifecycle.handlerBindings,
            releasedOwners = metrics.lifecycle.releasedOwners,
            releasedHandlers = metrics.lifecycle.releasedHandlers,
            hiddenOnRelease = metrics.lifecycle.hiddenOnRelease,
            inputTargets = metrics.lifecycle.inputTargets,
            focusClears = metrics.lifecycle.focusClears,
            focusClearFailures = metrics.lifecycle.focusClearFailures,
            inputRetires = metrics.lifecycle.inputRetires,
            trackedFocusTargets = CountWeakKeys(lifecycle.focusTargetsByPhysicalId),
        },
        nativeSafety = {
            staleRejects = tonumber(metrics.nativeSafety.staleRejects) or 0,
            registrationRejects = tonumber(metrics.nativeSafety.registrationRejects) or 0,
            degradedRejects = tonumber(metrics.nativeSafety.degradedRejects) or 0,
            callFailures = tonumber(metrics.nativeSafety.callFailures) or 0,
            anchorParentRepairs = tonumber(metrics.nativeSafety.anchorParentRepairs) or 0,
        },
        screenSnap = self:GetScreenSnapSnapshot(),
        design = {
            tokens = S.UITokens and tonumber(S.UITokens.version) or 0,
            layout = UI.LayoutV2 and UI.LayoutV2:GetSnapshot() or nil,
            binding = UI.Binding and UI.Binding:GetSnapshot() or nil,
            shell = UI.WindowShell and UI.WindowShell:GetSnapshot() or nil,
            floatingSurface = S.RSUI and S.RSUI.FloatingSurface and S.RSUI.FloatingSurface:GetSnapshot() or nil,
            rsui = S.RSUI and S.RSUI:GetSnapshot() or nil,
        },
    }
end

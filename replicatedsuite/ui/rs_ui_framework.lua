-- Replicated Suite · 原生界面差异与生命周期
-- 作者：Replicated
-- QQ群：1104129461
-- 有限 RU API 上的差异渲染和生命周期管理；缓存只存表现，业务留在 Feature。
-- 释放包括处理器、隐藏和引用清理，RU 无验证过的通用 DestroyWidget，不能等同销毁 Native。
-- 热路径只计数，不逐次格式化日志。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local UI = S.UI
if type(UI) ~= "table" then return end

local FRAMEWORK_VERSION = 15
local MAX_OWNER_METRICS = 48

local stateCache = setmetatable({}, { __mode = "k" })
local authorityClaims = setmetatable({}, { __mode = "k" })
local geometryLeases = setmetatable({}, { __mode = "k" })
local lifecycle = {
    owners = {},
    -- 物理 id 弱值索引证明当前焦点 Native 属 Suite 才清理；Suite 窗口隐藏不能清外部游戏/聊天焦点。
    focusTargetsByPhysicalId = setmetatable({}, { __mode = "v" }),
    -- RU GetFocusedWidgetId 可返回生成物理 id 或逻辑 id；第二弱身份索引用于证明焦点归属，不猜或全树扫描。
    focusTargetsByIdentity = setmetatable({}, { __mode = "v" }),
    -- 输入默认键盘静默，明确点击才启用；弱 key 防生命周期权威留存已释放 Native。
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
        inputActivationAttempts = 0,
        inputActivationSuccesses = 0,
        inputActivationFailures = 0,
        postArmFocusPromotions = 0,
        focusedFastPathHits = 0,
    },
}

UI.FrameworkVersion = FRAMEWORK_VERSION
UI.CompositeEnabledAdapterContractVersion = 2
UI.EnabledStateTransactionContractVersion = 1
UI.PickableStateTransactionContractVersion = 1
-- RU setter 无文档化成功返回，布尔 setter 可返回最终状态，设置 false 返回 false 不能全局当拒绝；
-- 请求 true 返回 false 仍拒绝，Lua 回调显式 false 否决语义归上层事务。
UI.NativeBooleanSetterReturnContractVersion = 1
-- 键盘焦点属 Native 生命周期资源，隐藏/禁用/释放 Suite 子树须放弃，但不动游戏/聊天焦点。输入收养时一次注册，祖先维护小子树计数，使普通非输入显隐 O(1)。
UI.InputFocusLifecycleContractVersion = 3
UI.HiddenInputFocusIsolationContractVersion = 2
UI.InputFocusIdentityCompatibilityContractVersion = 1
UI.NativeCaretPlacementPreservationContractVersion = 2
UI.PostArmFocusPromotionContractVersion = 1
UI.InputActivationDiagnosticsContractVersion = 1
UI.DeferredKeyboardActivationContractVersion = 1
-- 仅显式启用的只读报告交付框有额外选区保护；普通表单策略不变。
UI.ReportCopySelectionContractVersion = 1
UI.ExplicitInputCommitFocusContractVersion = 1
UI.Tokens = S.UITokens
UI.NativeStateCache = stateCache
UI.NativeAuthorityClaims = authorityClaims
UI.NativeGeometryLeases = geometryLeases
UI.Lifecycle = lifecycle
UI.FrameworkMetrics = metrics

local function NativeBooleanSetterAccepted(ok, result, requested)
    if ok ~= true then return false, result end
    -- RU 可返回最终布尔状态，只有请求 false 时返回 false 可接受；请求 true 返回 false 仍拒绝。
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
    -- UIParent 为原生特殊根身份；逻辑/缓存仍存实际对象以验证 Effective 偏移，不能让字面字符串混入缓存权威。
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
    -- RU Window/顶层 Button 根锚用 "UIParent"；传 userdata 可能报告成功却留原点 (0,0)，让 Diff 误认位置已应用。
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

local function RegisterFocusIdentity(identity, widget)
    if identity == nil or widget == nil then return end
    local key = tostring(identity)
    if key == "" then return end
    lifecycle.focusTargetsByIdentity[key] = widget
end

local function RegisterInputTarget(widget)
    if not IsInputTarget(widget) or widget.rsUiInputLifecycleTracked == true then return false end
    widget.rsUiInputLifecycleRetired = false
    widget.rsUiInputLifecycleTracked = true
    widget.rsUiKeyboardArmed = widget.rsUiKeyboardArmed == true
    local physicalId = PhysicalIdOf(widget)
    if physicalId ~= nil then lifecycle.focusTargetsByPhysicalId[physicalId] = widget end
    RegisterFocusIdentity(physicalId, widget)
    RegisterFocusIdentity(widget.rsNativeLogicalId, widget)
    RegisterFocusIdentity(widget.rsUiLogicalId, widget)
    if widget.rsUiKeyboardArmed == true then lifecycle.armedInputs[widget] = true end
    BumpInputSubtree(widget, 1)
    metrics.lifecycle.inputTargets = (tonumber(metrics.lifecycle.inputTargets) or 0) + 1
    return true
end

local function UnregisterFocusIdentity(identity, widget)
    if identity == nil then return end
    local key = tostring(identity)
    if key ~= "" and lifecycle.focusTargetsByIdentity[key] == widget then lifecycle.focusTargetsByIdentity[key] = nil end
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
    UnregisterFocusIdentity(physicalId, widget)
    UnregisterFocusIdentity(widget.rsNativeLogicalId, widget)
    UnregisterFocusIdentity(widget.rsUiLogicalId, widget)
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
    -- 只为请求复制保护的输入记录本次键盘状态原因，不记录正文/按键/聊天目标。
    -- 每框常量大小；隐藏/停用的真实撤权也留证，不以新的计时任务维持或夺回焦点。
    local activity = widget.rsUiCopyActivity
    if type(activity) == "table" then
        activity.lastKeyboardReason = tostring(reason or ""):sub(1, 96)
        activity.lastKeyboardAt = type(S.NowMs) == "function" and S.NowMs() or 0
        activity.keyboardChanges = (tonumber(activity.keyboardChanges) or 0) + 1
    end
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

-- 复制框失焦时仅允许一个下一帧复核；任何显式撤权先取消。
-- Task属于此Native实例/owner/generation；不让隐藏、换页、释放后遗留回调修改键盘状态。
local function CancelCopyFocusRecheck(widget)
    if widget == nil then return end
    local name, scheduler = widget.rsUiCopyFocusTask, widget.rsUiCopyFocusScheduler
    widget.rsUiCopyFocusTask, widget.rsUiCopyFocusScheduler = nil, nil
    if name ~= nil and scheduler ~= nil and type(scheduler.RemoveTask) == "function" then
        pcall(function() scheduler:RemoveTask(name) end)
    end
end

function UI:DisarmInputWidget(widget, owner, reason)
    CancelCopyFocusRecheck(widget)
    -- 先把最后的合法键入交回Diff，再撤销键盘权；清空/取消在disarm后也不会误报警。
    if type(self.AdoptInputDraftText)=="function" then self:AdoptInputDraftText(widget,owner) end
    return SetInputKeyboardState(widget, false, owner, reason or "input_deactivation")
end

function UI:ActivateInputWidget(widget, owner, reason)
    metrics.lifecycle.inputActivationAttempts = (tonumber(metrics.lifecycle.inputActivationAttempts) or 0) + 1
    local armed, keyboardChanged, armErr = self:ArmInputWidget(widget, owner, reason or "input_click")
    if armed ~= true then
        metrics.lifecycle.inputActivationFailures = (tonumber(metrics.lifecycle.inputActivationFailures) or 0) + 1
        return false, tostring(armErr or "keyboard_arm_failed")
    end

    -- RU 点击可在输入仍键盘静默时先发布全局焦点；OnClick 把 Keyboard false -> true 后必须强制 SetFocus，不能因“已聚焦”跳过，否则看似聚焦却无文本。
    -- 仅已启用且已聚焦的重复点击可保留原生光标位置而不再 SetFocus。
    if keyboardChanged ~= true and type(self.IsInputWidgetFocused) == "function" then
        local alreadyFocused = self:IsInputWidgetFocused(widget)
        if alreadyFocused == true then
            metrics.lifecycle.focusedFastPathHits = (tonumber(metrics.lifecycle.focusedFastPathHits) or 0) + 1
            metrics.lifecycle.inputActivationSuccesses = (tonumber(metrics.lifecycle.inputActivationSuccesses) or 0) + 1
            return true, nil
        end
    end
    if type(self.TryInteractionCall) ~= "function" then
        self:DisarmInputWidget(widget, owner, "focus_contract_unavailable")
        metrics.lifecycle.inputActivationFailures = (tonumber(metrics.lifecycle.inputActivationFailures) or 0) + 1
        return false, "focus_contract_unavailable"
    end
    local focused, focusErr = self:TryInteractionCall(widget, "SetFocus")
    if focused ~= true then
        self:DisarmInputWidget(widget, owner, "focus_failed")
        metrics.lifecycle.inputActivationFailures = (tonumber(metrics.lifecycle.inputActivationFailures) or 0) + 1
        return false, tostring(focusErr or "set_focus_failed")
    end
    if keyboardChanged == true then
        metrics.lifecycle.postArmFocusPromotions = (tonumber(metrics.lifecycle.postArmFocusPromotions) or 0) + 1
    end
    metrics.lifecycle.inputActivationSuccesses = (tonumber(metrics.lifecycle.inputActivationSuccesses) or 0) + 1
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
    -- rsUiParent 是 Suite 原语的廉价权威路径；已验证 Native 祖先 API 仅兜底旧构造未发布 Lua 父链的收养控件。
    if focusedId ~= nil and type(root.IsDescendantWidget) == "function" then
        local ok, result = pcall(function() return root:IsDescendantWidget(focusedId) end)
        if ok == true and result == true then return true end
    end
    return false
end

function UI:DisarmInputWithin(widget, owner, reason)
    if widget == nil then return true, 0, nil end
    -- 沿真实父链维护输入计数，无输入的 HUD 隐藏时无需扫描其它窗口。
    -- 输入自身和全局停用仍清理键盘权，不能用已隐藏证明已撤权。
    local allSuiteInputs = widget == UIParent or widget == "UIParent"
    if not allSuiteInputs and not IsInputTarget(widget)
        and (tonumber(widget.rsUiKeyboardInputSubtreeCount) or 0) <= 0 then return true, 0, nil end
    local snapshot = {}
    for input in pairs(lifecycle.armedInputs) do
        if input ~= nil then snapshot[#snapshot + 1] = input end
    end
    local count, failed = 0, nil
    for _, input in ipairs(snapshot) do
        local inputId = PhysicalIdOf(input)
        if allSuiteInputs or input == widget or FocusedInputDescendsFrom(input, widget, inputId) == true then
            local ok, changed, err = self:DisarmInputWidget(input, owner or OwnerOf(input), reason or "subtree_deactivate")
            if ok ~= true then failed = failed or err elseif changed == true then count = count + 1 end
        end
    end
    return failed == nil, count, failed
end

-- 维护：OnLostFocus与Native焦点ID更新的先后顺序不受Lua保证。仅看即时ID并永远忽略通知，
-- 可能在真正切到聊天后仍让旧框持有键盘。用现有Scheduler的一次性下一帧检查区分：仍归本框
-- 则完全不写Native；已离开/未知则撤权。绝不SetFocus/ClearFocus、读写正文或重新选中。
-- 没有调度能力/注册失败则走原撤权边界；重复通知合并，隐藏/Retire/ReleaseOwner统一取消。
local function ScheduleCopyFocusRecheck(ui, widget, owner, eventLabel)
    local scheduler, physicalId = S.Scheduler, PhysicalIdOf(widget)
    if scheduler == nil or type(scheduler.AddHighFrequencyOneShot) ~= "function"
        or type(scheduler.RemoveTask) ~= "function" or physicalId == nil then return false end
    if widget.rsUiCopyFocusTask ~= nil then return true end
    local name, generation = "rsui:copy_focus:" .. tostring(physicalId), S.Generation
    widget.rsUiCopyFocusTask, widget.rsUiCopyFocusScheduler = name, scheduler
    local registered, accepted = pcall(function()
        return scheduler:AddHighFrequencyOneShot(name, 1, function()
            if widget.rsUiCopyFocusTask ~= name then return end
            widget.rsUiCopyFocusTask, widget.rsUiCopyFocusScheduler = nil, nil
            if rawget(_G, "ReplicatedSuite") ~= S or S.Generation ~= generation
                or WidgetUsable(widget) ~= true or widget.rsUiInputLifecycleRetired == true
                or OwnerOf(widget) ~= OwnerOf(widget, owner) then return end
            local focused, err = ui:IsInputWidgetFocused(widget)
            local activity = widget.rsUiCopyActivity
            if type(activity) == "table" then
                activity.focusRechecks = (tonumber(activity.focusRechecks) or 0) + 1
                activity.lastRecheckAt = type(S.NowMs) == "function" and S.NowMs() or 0
                activity.lastRecheckStillOwned = focused == true and err == nil
            end
            if focused == true and err == nil then return end
            ui:DisarmInputWidget(widget, owner, eventLabel .. ":lost_focus_recheck")
            if type(ui.SetEditBoxFocusVisual) == "function" then ui:SetEditBoxFocusVisual(widget, false) end
        end, owner, "P0", 1)
    end)
    if registered == true and accepted == true then return true end
    CancelCopyFocusRecheck(widget)
    return false
end

-- 少量裸多行输入有意不入通用组件工厂；此 helper 提供同样明确点击激活，表现仍不能直接绑 Native。
function UI:BindDeferredInputActivation(widget, owner, label, options)
    if not IsInputTarget(widget) then return false, "input_target_required" end
    if type(self.SafeHandler) ~= "function" then return false, "handler_contract_unavailable" end
    local eventLabel = tostring(label or widget.rsUiLogicalId or widget.rsNativeLogicalId or "input")
    -- Native失焦通知可能晚于一次重新激活；无条件Disarm会使选中文字仍可见但Ctrl+C失效。
    -- 仅报告框显式请求且实时identity仍证明焦点属于同一输入时保留已激活键盘，不调用SetFocus。
    -- 外部/聊天焦点、查询失败、隐藏、退休仍走原撤权流程。此保护不能证明客户端此次2秒触发源。
    local preserveSelection = type(options) == "table" and options.preserveFocusedSelection == true
    CancelCopyFocusRecheck(widget) -- 重新绑定也不能继承上一个交互策略的延迟回调。
    if preserveSelection and type(widget.rsUiCopyActivity) ~= "table" then
        widget.rsUiCopyActivity = { lostFocusNotifications = 0, stillFocusedNotifications = 0, keyboardChanges = 0 }
    end
    local clickBound = self:SafeHandler(widget, "OnClick", function()
        local ok = self:ActivateInputWidget(widget, owner, eventLabel .. ":click")
        if type(self.SetEditBoxFocusVisual) == "function" then self:SetEditBoxFocusVisual(widget, ok == true) end
        return ok == true
    end, eventLabel .. ":activate")
    if clickBound ~= true then return false, "input_click_activation_bind_failed" end
    local lostBound = self:SafeHandler(widget, "OnLostFocus", function()
        local activity = widget.rsUiCopyActivity
        if preserveSelection then
            local focused, focusErr = self:IsInputWidgetFocused(widget)
            if type(activity) == "table" then
                activity.lostFocusNotifications = activity.lostFocusNotifications + 1
                activity.lastLostFocusAt = type(S.NowMs) == "function" and S.NowMs() or 0
                activity.lastLostFocusKnown = focusErr == nil
                activity.lastLostFocusStillOwned = focused == true and focusErr == nil
            end
            if focusErr == nil and focused == true and widget.rsUiKeyboardArmed == true
                and widget.rsUiInputLifecycleRetired ~= true and OwnerOf(widget) == OwnerOf(widget, owner) then
                activity.stillFocusedNotifications = activity.stillFocusedNotifications + 1
                if ScheduleCopyFocusRecheck(self, widget, owner, eventLabel) then return true end
            end
        end
        self:DisarmInputWidget(widget, owner, eventLabel .. ":lost_focus")
        if type(self.SetEditBoxFocusVisual) == "function" then self:SetEditBoxFocusVisual(widget, false) end
        return true
    end, eventLabel .. ":lost_focus")
    if lostBound ~= true then
        self:DisarmInputWidget(widget, owner, eventLabel .. ":lost_focus_bind_failed")
        return false, "input_lost_focus_bind_failed"
    end
    return true, nil
end

local function ReadFocusedWidgetId()
    -- RU清单将X2Util:GetFocusedWidgetId列为not allowed；裸全局也没有允许证据。
    -- 不调用/探测此API。焦点诊断保持未知，编辑草稿由受控Native缓冲交接。
    return nil, "get_focus_not_allowed"
end

local function ResolveTrackedFocusedInput(focusedId)
    if focusedId == nil then return nil end
    local key = tostring(focusedId)
    local direct = lifecycle.focusTargetsByIdentity[key] or lifecycle.focusTargetsByPhysicalId[key]
    if direct ~= nil then return direct end
    -- NativeIdentity 仅身份注册表，不是焦点权威；只把已知 Suite 逻辑 id 转成精确生成 id。
    local identities = S.NativeIdentity
    local physical = type(identities) == "table" and type(identities.logicalToPhysical) == "table"
        and identities.logicalToPhysical[key] or nil
    if physical ~= nil then return lifecycle.focusTargetsByPhysicalId[tostring(physical)] end
    return nil
end

function UI:IsInputWidgetFocused(widget)
    if not IsInputTarget(widget) then return false, "input_target_required" end
    local focusedId, focusErr = ReadFocusedWidgetId()
    if focusErr ~= nil then return false, focusErr end
    if focusedId == nil then return false, nil end
    return ResolveTrackedFocusedInput(focusedId) == widget, nil
end

-- 只解析当前generation已收养输入的精确Native焦点；供草稿协调器在刷新边界接纳，
-- 不扫描窗口、不猜焦点字符串，也不抢回Native焦点。
function UI:GetFocusedInputWidget()
    local focusedId,focusErr=ReadFocusedWidgetId()
    if focusErr~=nil then return nil,focusErr end
    local widget=ResolveTrackedFocusedInput(focusedId)
    if widget==nil or widget.rsUiInputLifecycleRetired==true or WidgetUsable(widget)~=true then return nil end
    return widget
end

-- 只读有界状态供打印使用，禁止复制整个Native对象/正文，
-- 不扫描UI、不查询剪贴板、不从未知focused ID推断所有权；数据只在本generation内存在。
function UI:GetCopyInputSnapshot(widget)
    if not IsInputTarget(widget) then return { available = false } end
    local focused, err = self:IsInputWidgetFocused(widget)
    local out = { available = true, focused = focused == true, focusKnown = err == nil,
        keyboardArmed = widget.rsUiKeyboardArmed == true, retired = widget.rsUiInputLifecycleRetired == true,
        focusRecheckPending = widget.rsUiCopyFocusTask ~= nil }
    for key, value in pairs(type(widget.rsUiCopyActivity) == "table" and widget.rsUiCopyActivity or {}) do
        out[key] = value
    end
    return out
end

-- 全局焦点 id 解析为已注册 Suite EditBox 且证明在失活子树内才清理，不能抢聊天焦点。
function UI:ReleaseFocusWithin(widget, owner, reason)
    if widget == nil then return true, false, nil end
    local subtreeInputs = tonumber(widget.rsUiKeyboardInputSubtreeCount) or 0
    if subtreeInputs <= 0 and not IsInputTarget(widget) then return true, false, nil end

    local focusedId, focusErr = ReadFocusedWidgetId()
    if focusErr ~= nil then return true, false, focusErr end
    if focusedId == nil then return true, false, nil end
    local focused = ResolveTrackedFocusedInput(focusedId)
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
    -- ClearFocus 无文档化成功 ABI；验证可观察焦点身份，不能把 false/nil 当失败。
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

-- 结束编辑是单一生命周期事务：焦点物理身份证明属本输入才释放 Native 焦点，无论是否有焦点诊断均停键盘捕获，隔离聊天/游戏同时防已提交输入吞移动/技能键。
function UI:DeactivateInputWidget(widget, owner, reason)
    if widget == nil then return true, false, nil end
    local focusOk, focusChanged, focusErr = self:ReleaseFocusWithin(widget, owner, reason or "input_commit")
    local disarmOk, disarmChanged, disarmErr = self:DisarmInputWidget(widget, owner, reason or "input_commit")
    if type(self.SetEditBoxFocusVisual) == "function" then self:SetEditBoxFocusVisual(widget, false) end
    if focusOk ~= true then return false, focusChanged == true or disarmChanged == true, tostring(focusErr or "focus_release_failed") end
    if disarmOk ~= true then return false, focusChanged == true or disarmChanged == true, tostring(disarmErr or "keyboard_disarm_failed") end
    return true, focusChanged == true or disarmChanged == true, focusErr
end

-- 永久输入退休仅拆组件/owner 或旧热重载代际；活跃隐藏/禁用只解除 Keyboard，下次明确点击可再启，无需注册。
function UI:RetireInputWidget(widget, owner, reason)
    if not IsInputTarget(widget) then return true end
    if widget.rsUiInputLifecycleRetired == true then return true end
    local drafts=S.RSUI and S.RSUI.InputDraftCoordinator
    if type(drafts)=='table' and type(drafts.RetireNative)=='function' then drafts:RetireNative(widget) end
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

-- 运行/启动静默边界：retire=false 清可证明 Suite 焦点并停所有已启输入；retire=true 还永久退休替代代际全部追踪输入。
function UI:QuiesceKeyboardInput(reason, retire)
    local focusedId = select(1, ReadFocusedWidgetId())
    if focusedId ~= nil then
        local focused = ResolveTrackedFocusedInput(focusedId)
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

    -- owner 数量有界，other 是热路径兜底，不能刷新时任意驱逐记录。
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
    -- RU IsVisible() 可能为有效可见性，隐藏 Shell 下局部已 Show 子仍 false；此情况视不可验证，不能误报严格权威违规，几何仍可完整验证。
    if value ~= true and HasKnownHiddenAncestor(widget) then return nil, false end
    return value == true, true
end

-- 渲染诊断公开读回引擎实际认为的点可见状态，使“API 写入成功但屏幕无点”与
-- “坐标落到屏外”可在一次粘贴中区分。
function UI:NativeVisibleReadback(widget)
    local value, known = TryNativeVisible(widget)
    return value, known == true
end

local function TryNativeAnchorMatches(widget, parent, x, y)
    if widget == nil or parent == nil then return nil, false end
    local parentState = stateCache[parent]
    if HasKnownHiddenAncestor(widget) or (parentState ~= nil and parentState.visible == false) then
        -- RU 祖先隐藏时 Effective 偏移不能可靠探测局部锚，等可见后再验证。
        return nil, false
    end
    -- 顶层窗用校准后的逻辑矩形核对。UIParent 可能仅为字符串、没有 EffectiveOffset，
    -- 而 raw/scaled 任一命中会漏掉真实的 x/uiScale 偏移；缓存回退也不能证明缓存正确。
    -- 仅显式 Windowing 车道用 Layout readback，HUD 热路径不加探测。
    if widget.rsUiWindowGeometryReadback == true and (parent == UIParent or parent == "UIParent")
        and S.Layout ~= nil and type(S.Layout.GetWindowLogicalRect) == "function" then
        local ok, lx, ly, _, _, info = pcall(S.Layout.GetWindowLogicalRect, S.Layout, widget)
        if ok and type(info) == "table" and info.source == "effective_calibrated"
            and type(lx) == "number" and type(ly) == "number" then
            local epsilon=math.max(1,1/math.max(0.01,tonumber(info.effectiveScale) or 1))
            return math.abs(lx-(tonumber(x) or 0))<=epsilon and math.abs(ly-(tonumber(y) or 0))<=epsilon,true
        end
        return nil,false
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
        -- SetAnchor 已含布局 addonScale 的逻辑坐标，Native getter 还可能含客户端 UI scale；不能二次乘 addonScale，否则 uiScale 非 1 时大量误报修复。
        if ok and type(context) == "table" then scale = math.max(0.01, tonumber(context.uiScale) or 1) end
    end
    -- RU Effective 偏移可为逻辑或 Native UI 缩放空间，二者均接受；严格 V3 所有权由写入边界执行，不重复 addonScale。
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
    -- 兼容 UI Factory v1 初始化锚表；DiffRenderer 触锚后转标量字段，避免高频 HUD 每次位置变化分配表。
    local legacy = row.anchorTopLeft
    return type(legacy) == "table" and legacy.parent == parent and legacy.x == x and legacy.y == y
end

function UI:PrimeNativeState(widget, values)
    if widget == nil or type(values) ~= "table" then return false end
    local row = GetState(widget)
    for key, value in pairs(values) do row[key] = value end
    return true
end

-- 旧代码需直接写 Diff 管理字段时调用，只失效一个字段，避免清全部表现缓存。
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

-- 严格 V3 claim 表示 DiffRenderer 唯一表现写入者；迁移可共存旧控件，但严格控件后续缓存修复是架构硬违规。
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


local function EditableDraftUsable(widget,owner,explicitDiscard)
    if not IsInputTarget(widget) or widget.rsUiDraftInput~=true or WidgetUsable(widget)~=true
        or widget.rsUiInputLifecycleRetired==true then return false end
    local claim=authorityClaims[widget]
    if NormalizeOwner(owner)~=OwnerOf(widget) or (claim and NormalizeOwner(owner)~=tostring(claim.owner)) then return false end
    if explicitDiscard==true then return true end
    local node,guard=widget,0
    while node~=nil and node~=UIParent and guard<64 do
        local row=stateCache[node]
        if row and (row.visible==false or row.enabled==false) then return false end
        node=node.rsUiParent;guard=guard+1
    end
    return node==nil or node==UIParent
end

function UI:IsEditableInputBufferUsable(widget,owner)
    return EditableDraftUsable(widget,owner)
end

-- 明确取消/离页可以在Shell已经隐藏后发生：本输入owner已决定丢弃缓冲，
-- 先交接当前Native文字再恢复Authority，避免把合法取消报成外部违规。
-- 只给明确取消入口使用；环境观察仍完整拒绝隐藏/禁用输入，标签无法进入此通道。
function UI:PrepareInputDraftDiscard(widget,owner)
    if not EditableDraftUsable(widget,owner,true) then return false end
    local text,known=TryNativeText(widget)
    if not known then return false end
    GetState(widget).text=text
    return true
end

-- Native输入文字交回Diff缓存；RSUI编辑缓冲使用与观察入口相同的可用性/owner检查，
-- 其它输入仍须明确arm。普通标签/外owner保留严格审计，不清除历史违规计数。
function UI:AdoptInputDraftText(widget,owner)
    if not IsInputTarget(widget) or widget.rsUiInputLifecycleRetired==true
        or WidgetUsable(widget)~=true then return false end
    if widget.rsUiDraftInput~=true and (widget.rsUiKeyboardArmed~=true or lifecycle.armedInputs[widget]~=true) then return false end
    if widget.rsUiDraftInput==true and not EditableDraftUsable(widget,owner) then return false end
    local claim=authorityClaims[widget]
    if claim and NormalizeOwner(owner)~=tostring(claim.owner) then return false end
    if not claim and NormalizeOwner(owner)~=OwnerOf(widget) then return false end
    local text,known=TryNativeText(widget)
    if not known then return false end
    GetState(widget).text=text
    return true
end

-- 可编辑Native正文天然可由用户修改，不能拿标签Diff的旧缓存覆盖它。
-- 仅RSUI明确登记的输入、同owner、本代际且可见启用时接纳差异；不推断焦点、
-- 不启键盘、不写Binding。baseline来自组件最后一次渲染/捕获，首次Render不接管。
function UI:AdoptEditableInputDraftText(widget,owner,baseline)
    if baseline==nil or not EditableDraftUsable(widget,owner) then return false end
    local text,known=TryNativeText(widget)
    if not known or text==tostring(baseline) then return false end
    GetState(widget).text=text
    return true,text
end

function UI:SetText(widget, value, owner)
    local usable = WidgetUsable(widget)
    if usable ~= true or type(widget.SetText) ~= "function" then return false end
    local text = tostring(value or "")
    local row = GetState(widget)
    if row.text == text then
        -- 旧页仍可直接改原生标签，仅缓存命中时验证，使普通写无分配且低成本。
        local nativeText, known = TryNativeText(widget)
        if not known or nativeText == text then
            RecordAttempt("SET_TEXT", widget, false, 0, owner)
            return false
        end
        -- 显式提交/拒绝可以覆盖用户草稿，但必须先完成合法输入的缓存交接。
        if self:AdoptInputDraftText(widget,owner) ~= true then
            RepairCachedField(row, "text", nativeText)
            RecordCacheRepair("text", widget, owner)
        end
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

-- Transactional visibility facade. 区分缓存命中与 Native 拒绝，写入确认后才发布逻辑可见。
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

-- Native drawable、文字 style、SetColor(r,g,b,a) 小组合适配器的共享颜色 Diff；治疗标记动画可重绘，静态状态首次应用后应零 Native 写。
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
        -- 兼容早期调用方初始化紧凑数组。
        local legacy = row.color
        sameColor = type(legacy) == "table" and legacy[1] == r and legacy[2] == g and legacy[3] == b and legacy[4] == a
    end
    if sameColor then
        RecordAttempt("SET_COLOR", widget, false, 0, owner)
        return false
    end
    -- LABEL 颜色在 TextStyle:SetColor，不在 widget（widget SetColor 仅 drawable）；
    -- easypull.lua:267、rp_ui.lua:2348、Theme 均通过 style。直接传标签的世界引导点须在此解析 style，避免用永不会成功的写阻止显现。
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

-- RU 图标用 ClearAllTextures/AddTexture，清除与添加视为一次提交。
-- 任一步拒绝都作废路径缓存；旧代码吞掉 AddTexture=false，切装备后便不再重试。
-- 无返回仍兼容接受。SetIconTexture 保留 false=no-op，须证明成功的 HUD 用 EnsureIconTexture。
function UI:SetIconTexture(drawable, path, owner)
    if drawable == nil then return false end
    local value = tostring(path or "")
    local row = GetState(drawable)
    if row.iconTexture == value then RecordAttempt("ICON_TEXTURE", drawable, false, 0, owner); return false end
    local calls = 0
    local function Reject()
        row.iconTexture = nil
        metrics.nativeSafety.callFailures = metrics.nativeSafety.callFailures + 1
        return false
    end
    if type(drawable.ClearAllTextures) == "function" then
        local ok, result = pcall(drawable.ClearAllTextures, drawable)
        if not ok or result == false then return Reject() end
        calls = calls + 1
        row.iconTexture = nil -- Clear已改变物理状态；不能保留旧路径的成功声明。
    end
    if value ~= "" then
        if type(drawable.AddTexture) ~= "function" then return Reject() end
        local ok, result = pcall(drawable.AddTexture, drawable, value)
        if not ok or result == false then return Reject() end
        calls = calls + 1
    end
    if calls == 0 then return Reject() end
    row.iconTexture = value
    RecordAttempt("ICON_TEXTURE", drawable, true, calls, owner)
    return true
end

function UI:EnsureIconTexture(drawable, path, owner)
    if drawable == nil then return false, false, "drawable_required" end
    local value = tostring(path or "")
    if GetState(drawable).iconTexture == value then
        RecordAttempt("ICON_TEXTURE_ENSURE", drawable, false, 0, owner)
        return true, false, nil
    end
    if self:SetIconTexture(drawable, value, owner) == true then return true, true, nil end
    return false, false, "native_icon_texture_rejected"
end


-- Native 交互几何租约：StartMoving/StartSizing 期间客户端暂持顶层几何，严格 Diff 不能立即写回手势前锚/尺寸；
-- 仅延后 SetAnchor/SetExtent，其余字段仍严格管理。
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
    -- Native 移动已绕缓存改物理状态；下个提交 V3 写须从最终 Native 矩形重新初始化。
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
    -- 自定义横滑块持有 rail/thumb/drag 子几何，根 SetExtent 不完整；统一钩子让 RSUI 和旧字段在热重载后也共用缩放语义。
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
            -- SetExtent 宽高已为含 addonScale 的 Suite 逻辑坐标，Native getter 可返回同逻辑值或乘 UI:GetUIScale，不能再次应用 addonScale。
            if ok and type(context) == "table" then scale = math.max(0.01, tonumber(context.uiScale) or 1) end
        end
        -- RU GetWidth/GetHeight 可为逻辑或客户端物理空间，两契约均有效；不能拿 addonScale 比较而在 UI scale 非 1 时几乎每缓存命中都误报外部写。
        local epsilon = math.max(0.75, scale)
        local rawMatch = known and math.abs(nativeW - w) <= epsilon and math.abs(nativeH - h) <= epsilon
        local scaledMatch = known and math.abs(nativeW - w * scale) <= epsilon and math.abs(nativeH - h * scale) <= epsilon
        if not known or rawMatch or scaledMatch then
            RefreshCompositeExtent(widget)
            RecordAttempt("SET_EXTENT", widget, false, 0, owner)
            return false
        end
        -- 未知 Native 单位空间不能回写逻辑缓存，下方权威写恢复请求逻辑 extent。
        RecordCacheRepair("extent", widget, owner)
    end
    -- 原生 false 与抛错同为拒绝；nil 仍是历史成功。
    -- 不发布未被 Native 接受的 Diff cache，否则 Reset 会命中虚假缓存且 Store 误存。
    -- 仅改变失败边界，不改变 accepted/changed 契约和正常高频 diff 路径。
    local ok, err = pcall(function() return widget:SetExtent(w, h) end)
    if ok ~= true or err == false then RecordNativeSafetyFailure("SET_EXTENT", widget, err, owner); return false end
    row.width, row.height = w, h
    RefreshCompositeExtent(widget)
    RecordAttempt("SET_EXTENT", widget, true, 1, owner)
    return true
end

UI.GeometryStateTransactionContractVersion = 1

-- EnsureExtent/EnsureAnchor 为低频窗口/布局提交提供 accepted/changed/error，区分缓存无变化与 Native 拒绝；
-- 热 Diff 的 SetExtent/SetAnchor 保留 changed 契约。
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
        -- 与 extent 同一 Native 成功判据；坐标仍为 UIParent logical，不做缩放。
        local removeOk, removeErr = pcall(function() return widget:RemoveAllAnchors() end)
        if removeOk ~= true or removeErr == false then RecordNativeSafetyFailure("REMOVE_ANCHORS", widget, removeErr, owner); return false end
        nativeCalls = nativeCalls + 1
    end
    local anchorOk, anchorErr = pcall(function() return widget:AddAnchor("TOPLEFT", nativeParent, ax, ay) end)
    if anchorOk ~= true or anchorErr == false then
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

-- 屏幕吸附适配器。
-- 顶层控件不重复发现兄弟或计算几何；Feature/Domain 持久化，适配器仅登记可见屏幕控件并经普通 Diff 提交吸附，集中 UIParent 根锚语义。
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
    -- 拖动事务已经拥有逻辑矩形时，吸附必须
    -- 使用同一份 committed rect，不能再次读 Native；否则 UI Scale/原生更新时序可能在吸附前
    -- 就把旧坐标带回持久化链。无显式矩形的屏幕控件调用使用统一 Native logical 校准，HUD 的其它坐标 helper 不变。
    local x, y, width, height
    if tonumber(options.x) ~= nil and tonumber(options.y) ~= nil then
        x, y = tonumber(options.x), tonumber(options.y)
        width, height = tonumber(options.width), tonumber(options.height)
    else
        x, y, width, height = S.Layout:GetWindowLogicalRect(widget)
    end
    if tonumber(x) == nil or tonumber(y) == nil then return false, x, y, false, nil end
    local sx, sy, snapped, targetId = self:ResolveScreenSnap(id, x, y, width, height, options)
    if snapped == true then
        -- 吸附也是 Native 几何事务，拒绝不能冒充 committed 并进入位置 Store。
        local windowing=S.RSUI and S.RSUI.Windowing
        local ok,err
        if windowing and type(windowing.ApplyGeometry)=="function" then
            ok,err=windowing:ApplyGeometry(widget,options.owner or "screen_snap",sx,sy,width,height,true)
        else
            if type(self.InvalidateNativeState)=="function" then
                for _,field in ipairs({"anchorParent","anchorX","anchorY","anchorTopLeft"})do self:InvalidateNativeState(widget,field) end
            end
            local accepted,_,detail=self:EnsureAnchor(widget,UIParent,sx,sy,options.owner or "screen_snap")
            ok,err=accepted,detail
        end
        if ok~=true then return false,x,y,false,targetId,err or "snap_geometry_rejected" end
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
    -- 组合真实命中面可为子控件，根 WidgetBase:Enable() 不够；仅显式发布适配器的控件绕根路径。
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
        -- 组合适配器为 Lua 事务回调，显式 false 保持权威否决，不能按不透明 Native setter 处理。
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

-- EnsureEnabled 确认请求 Native 状态，区分缓存成功与拒绝；SetEnabled 保留 changed（false 也可缓存命中）。低频事件驱动，不轮询 Native。
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
    -- SetEnabled 仅接受写后更新缓存，此处目标值仍缺则原生转换已拒绝。
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
    -- Native 无命中方法时不能缓存成功，否则以后真实适配器/方法会因缓存宣称已应用而永久跳过。
    if calls == 0 then
        RecordAttempt("PICKABLE", widget, false, 0, owner)
        return false
    end
    row.pickable = value
    RecordAttempt("PICKABLE", widget, true, calls, owner)
    return true
end

-- 命中状态与 EnsureEnabled 共用消歧契约，供校准/锁定转换确认 pickable，避免可见控件行为与逻辑相反。
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

-- SetFontSize false 同时指拒绝与缓存无操作，显隐关键渲染不能当致命失败；需区分时用 EnsureFontSize，普通样式尽力写。
-- PlaceUnitDot 不能在显示前因无操作 false 退出。
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

-- EnsureFontSize 与 EnsureVisible/EnsureAnchor/EnsurePickable 共用 (ok,changed,err)：ok=true,changed=false 为缓存无操作，ok=false 才拒绝。
-- CreateLabel 通过 PrimeNativeState 初始化字体，首次同值 SetFontSize 合法 false，不能因此隐藏整个点池。
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

-- 低频透明事务：SetAlpha 保留 changed/无操作语义，EnsureAlpha 确认 Native 状态后再允许发布权威透明度。
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

-- ScaleBox 事件/布局驱动，缓存 SetScale 使同分辨率重复布局零写；虽在 RU allowlist，个别控件可能缺方法，须提供不缩放兜底。
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

-- 色调/按钮样式交 Theme，保持唯一颜色权威；Theme 返回是否实际需要 Native 重绘。
function UI:SetLabelTone(widget, tone, owner)
    if WidgetUsable(widget) ~= true then return false end
    if S.Theme == nil or type(S.Theme.SetLabelTone) ~= "function" then return false end
    local changed = S.Theme:SetLabelTone(widget, tone) == true
    RecordAttempt("LABEL_TONE", widget, changed, changed and 1 or 0, owner)
    return changed
end

-- 保留既有 WidgetUsable 与 Native 写计数，Theme 是唯一着色 Authority。
function UI:SetButtonStatusTone(widget, tone, owner)
    if WidgetUsable(widget) ~= true then return false end
    if S.Theme == nil or type(S.Theme.SetButtonStatusTone) ~= "function" then return false end
    local changed = S.Theme:SetButtonStatusTone(widget, tone) == true
    RecordAttempt("BUTTON_STATUS_TONE", widget, changed, changed and 1 or 0, owner)
    return changed
end

function UI:SetButtonActive(widget, active, owner)
    if WidgetUsable(widget) ~= true then return false end
    if S.Theme == nil or type(S.Theme.SetButtonActive) ~= "function" then return false end
    local changed = S.Theme:SetButtonActive(widget, active == true) == true
    -- 渐变按钮内部重绘两个 drawable（六次 band 调用），此处计一次逻辑样式写，详细 Native 样式统计归 Theme。
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

-- Adopt 表示 owner 负责 Lua/Native 引用，不转移业务权威，也不销毁控件。
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
            keyboardArms = metrics.lifecycle.keyboardArms,
            keyboardDisarms = metrics.lifecycle.keyboardDisarms,
            keyboardArmFailures = metrics.lifecycle.keyboardArmFailures,
            inputActivationAttempts = metrics.lifecycle.inputActivationAttempts,
            inputActivationSuccesses = metrics.lifecycle.inputActivationSuccesses,
            inputActivationFailures = metrics.lifecycle.inputActivationFailures,
            postArmFocusPromotions = metrics.lifecycle.postArmFocusPromotions,
            focusedFastPathHits = metrics.lifecycle.focusedFastPathHits,
            armedInputs = CountWeakKeys(lifecycle.armedInputs),
            trackedFocusTargets = CountWeakKeys(lifecycle.focusTargetsByPhysicalId),
            trackedFocusIdentities = CountWeakKeys(lifecycle.focusTargetsByIdentity),
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

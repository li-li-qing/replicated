------------------------------------------------------------------------
-- Replicated Suite - RSUI Interactive Controls v1
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local UI, RSUI = S.UI, S.RSUI
if type(UI) ~= "table" or type(RSUI) ~= "table" then return end
local Tokens = S.UITokens or {}

local function Token(path, fallback)
    if type(Tokens.Number) == "function" then return Tokens:Number(path, fallback) end
    return tonumber(fallback) or 0
end

local function Clamp(value, minimum, maximum)
    value = tonumber(value)
    if value == nil then return nil end
    if minimum ~= nil and value < minimum then value = minimum end
    if maximum ~= nil and value > maximum then value = maximum end
    return value
end

local function RoundStep(value, minimum, step)
    value = tonumber(value)
    if value == nil then return nil end
    step = math.abs(tonumber(step) or 0)
    minimum = tonumber(minimum) or 0
    if step <= 0 then return value end
    return minimum + math.floor(((value - minimum) / step) + 0.5) * step
end

local function NormalizeNumber(spec, value)
    value = tonumber(value)
    if value == nil then return nil end
    local stepOrigin = spec.stepOrigin ~= nil and spec.stepOrigin or spec.min
    value = RoundStep(value, stepOrigin, spec.step)
    value = Clamp(value, spec.min, spec.max)
    if spec.integer == true then value = math.floor(value + 0.5) end
    return value
end

local function Read(binding, fallback)
    if binding ~= nil and type(binding.Get) == "function" then return binding:Get() end
    return fallback
end

local function Write(binding, value, final, source, spec)
    if binding ~= nil and type(binding.Set) == "function" then
        local ok = binding:Set(value, final == true, source)
        if ok and final == true and spec.commitOnFinal == true and type(binding.Commit) == "function" then ok = binding:Commit(source) end
        return ok
    end
    return true
end

local function RequireBinding(component, spec, kind)
    local binding, bindingErr = RSUI:Binding(spec)
    if binding ~= nil then
        if type(component) == "table" then component.binding = binding end
        return binding, nil
    end
    if type(component) == "table" and type(component.Release) == "function" then pcall(function() component:Release() end) end
    return nil, tostring(kind or "control") .. "_binding_failed:" .. tostring(bindingErr or "unknown")
end

-- Interactive Draft Contract v1
--
-- RU text inputs do not expose a verified OnTextChanged event, while Slider
-- preview intentionally does not commit its binding until drag-stop.  Any
-- unrelated page/projection refresh that blindly calls Render() during those
-- active interactions would therefore overwrite the user's draft with the last
-- committed binding value.  Controls themselves own this fence so every page
-- gets the same behavior without inventing local "don't refresh while typing"
-- flags or permanent polling.
RSUI.InteractiveDraftContractVersion = 4
RSUI.InputDraftCommitContractVersion = 3
RSUI.InputDraftSessionContractVersion = 2 -- 中文维护注释：DraftSession V2 将 Lua 草稿寿命与 RU Native Focus 分离；显式确认输入失焦只挂起，不再提交/恢复 Authority。
RSUI.NumericInputDraftReadContractVersion = 1
RSUI.InputFocusVisualContractVersion = 1
RSUI.InputDisableDraftCleanupContractVersion = 1
RSUI.ControlTransactionContractVersion = 1
RSUI.PopupVisibilityTransactionContractVersion = 1
-- Popup hit-test quiescence: Close() unpicks the popup surface and every
-- Open()/Show() must re-pick before the surface can receive input again.
RSUI.PopupHitTestQuiescenceContractVersion = 1
RSUI.PopupNativeWindowContractVersion = 1

local function EnsureRawVisible(widget, visible, owner)
    if widget == nil then return false, "popup_widget_required" end
    if type(UI.EnsureVisible) ~= "function" then return false, "visibility_transaction_unavailable" end
    local accepted, _, detail = UI:EnsureVisible(widget, visible == true, owner)
    if accepted ~= true then return false, tostring(detail or "native_visibility_rejected") end
    return true, nil
end

local function IsFocusedDraft(component)
    if component == nil or component.root == nil then return false end
    if type(UI.IsInputWidgetFocused) == "function" then
        local ok, focused = pcall(function() return UI:IsInputWidgetFocused(component.root) end)
        if ok == true and focused == true then return true end
    end
    local focus = RSUI.Focus
    if type(focus) ~= "table" or type(focus.IsFocused) ~= "function" then return false end
    local ok, focused = pcall(function() return focus:IsFocused(component.root) end)
    return ok == true and focused == true
end

-- While a user owns a draft, every Render source is treated as ambient unless
-- it is the final result of this input's own transaction. This is deliberately
-- an allow-list for overrides rather than a deny-list for refresh names: new
-- page/projection refresh sources can therefore never resurrect old Binding
-- text just because their source label was not known when the control shipped.
local function CanOverrideActiveDraft(source)
    source = tostring(source or "binding_refresh")
    return source == "commit" or source == "rejected" or source == "restore_authority"
end

local function CanOverrideActiveSliderPreview(source)
    source = tostring(source or "binding_refresh")
    return CanOverrideActiveDraft(source) or source == "interaction" or source == "range_change"
end

local function ShouldPreserveDraft(component, source)
    if component == nil or CanOverrideActiveDraft(source) == true then return false end
    -- 中文维护注释（DraftSession V2）：ambient Render 是否可覆盖输入，Authority 是 Lua draft session，
    -- 不能再依赖 RU Native Focus。LostFocus 后显式确认型输入仍保留 draftActive，页面/投影刷新必须继续让路。
    if type(component.HasDraftSession) == "function" and component:HasDraftSession() == true then return true end
    return type(component.IsEditing) == "function" and component:IsEditing() == true
end

local function SetInputFocusVisual(component, focused)
    if component == nil or component.root == nil or type(UI.SetEditBoxFocusVisual) ~= "function" then return false end
    return UI:SetEditBoxFocusVisual(component.root, focused == true) == true
end

local function CountDraftSuppression()
    RSUI.metrics.interactiveDraftRenderSuppressions = (tonumber(RSUI.metrics.interactiveDraftRenderSuppressions) or 0) + 1
end

-- Deferred EditBox keyboard ownership. RU can capture movement/skill keys when
-- EnableKeyboard(true) is applied during construction, even before a real text
-- edit begins. Every input therefore starts inert and arms only on explicit
-- click; LostFocus always disarms again. No Tick/polling is introduced.
RSUI.DeferredKeyboardActivationContractVersion = 1
RSUI.InputLostFocusRecheckContractVersion = 1

local function BeginEditInteraction(component, source)
    if component == nil or component.root == nil or component.enabled == false then return false, "input_unavailable" end
    if type(UI.ActivateInputWidget) ~= "function" then return false, "input_activation_contract_unavailable" end
    return UI:ActivateInputWidget(component.root, component.owner, tostring(source or "input_click"))
end

local function EndEditInteraction(component, source)
    if component == nil or component.root == nil then return true end
    if type(UI.DeactivateInputWidget) ~= "function" then return false, "input_deactivation_contract_unavailable" end
    local ok, _, detail = UI:DeactivateInputWidget(component.root, component.owner, tostring(source or "input_end_edit"))
    return ok == true, detail
end

-- 中文维护注释（2026-09-14，single-line copy/focus ordering）：RU 的 OnLostFocus 与
-- GetFocusedWidgetId 更新顺序不是稳定 ABI。实机可出现“先收到 LostFocus，但焦点 identity 仍是当前
-- EditBox”的一帧窗口；旧 TextInput/NumericInput 会立即 EnableKeyboard(false)，于是 caret/选区还在，
-- Ctrl+C 却偶发失效。这里只在 identity 明确仍属于本框时安排一次 1ms high-frequency one-shot；
-- 下一帧仍在本框则什么都不写，真的离开才执行原 blur 提交/撤权。没有周期轮询，不 SetFocus，
-- 不读取剪贴板，不影响聊天焦点；Release/Commit/Disable 会取消挂起任务。
local function CancelInputLostFocusRecheck(component)
    if component == nil then return end
    local name, scheduler = component._lostFocusTask, component._lostFocusScheduler
    component._lostFocusTask, component._lostFocusScheduler = nil, nil
    if name ~= nil and scheduler ~= nil and type(scheduler.RemoveTask) == "function" then
        pcall(function() scheduler:RemoveTask(name) end)
    end
end

local function DeferAmbiguousLostFocus(component, finalizer, label)
    if component == nil or component.root == nil or component.released == true or component._endingEdit == true then return false end
    if component.root.rsUiKeyboardArmed ~= true or type(UI.IsInputWidgetFocused) ~= "function" then return false end
    local ok, focused, focusErr = pcall(function()
        local value, err = UI:IsInputWidgetFocused(component.root)
        return value, err
    end)
    if ok ~= true or focused ~= true or focusErr ~= nil then return false end
    local scheduler = S.Scheduler
    if scheduler == nil or type(scheduler.AddHighFrequencyOneShot) ~= "function" or type(scheduler.RemoveTask) ~= "function" then return false end
    if component._lostFocusTask ~= nil then return true end
    local generation = S.Generation
    local name = "rsui:input_focus_recheck:" .. tostring(generation or 0) .. ":" .. tostring(component.id or "input")
    component._lostFocusTask, component._lostFocusScheduler = name, scheduler
    local registered = scheduler:AddHighFrequencyOneShot(name, 1, function()
        if component._lostFocusTask ~= name then return end
        component._lostFocusTask, component._lostFocusScheduler = nil, nil
        if rawget(_G, "ReplicatedSuite") ~= S or S.Generation ~= generation
            or component.released == true or component.root == nil or component._endingEdit == true then return end
        local stillFocused, stillErr = UI:IsInputWidgetFocused(component.root)
        if stillFocused == true and stillErr == nil and component.root.rsUiKeyboardArmed == true then
            component.editing = true
            SetInputFocusVisual(component, true)
            return
        end
        finalizer(tostring(label or "input_lost_focus") .. ":recheck")
    end, component.owner, "P0", 1)
    if registered == true then return true end
    CancelInputLostFocusRecheck(component)
    return false
end

-- Component-local edit ownership is the authoritative draft lifetime.  The
-- coordinator is intentionally event-driven and weak: it lets a newly clicked
-- input finalize another still-active Suite input without retaining released
-- components or adding polling.
local DraftCoordinator = type(RSUI.InputDraftCoordinator) == "table" and RSUI.InputDraftCoordinator or {}
DraftCoordinator.active = type(DraftCoordinator.active) == "table" and DraftCoordinator.active or setmetatable({}, { __mode = "k" })
DraftCoordinator.metrics = type(DraftCoordinator.metrics) == "table" and DraftCoordinator.metrics or {
    began = 0, suspended = 0, committed = 0, cancelled = 0, ended = 0, renderSuppressions = 0,
}
RSUI.InputDraftCoordinator = DraftCoordinator

function DraftCoordinator:Bump(name)
    name = tostring(name or "")
    if name ~= "" then self.metrics[name] = (tonumber(self.metrics[name]) or 0) + 1 end
end

function DraftCoordinator:Forget(component)
    if component ~= nil then self.active[component] = nil end
end

-- 中文维护注释（DraftSession V2 / input switch）：旧版 Begin() 会 CommitAndEndEditing 其它输入，
-- 导致用户只是点击第二个编辑框就把第一个未确认草稿写进 Feature/Store。现在只撤销其它输入的 Native
-- 键盘权，并要求组件把当前 Native 文本捕获到 Lua draftText；业务 Authority 完全不写。多个显式草稿可
-- 同时存在，页面离开/Cancel 时再丢弃，Apply/Enter 才提交。风险边界：blur-commit 组件仍由自身 LostFocus
-- 走兼容提交，不在这里强行提交。
function DraftCoordinator:SuspendOthers(component, reason)
    local snapshot = {}
    for active in pairs(self.active) do
        if active ~= nil and active ~= component then snapshot[#snapshot + 1] = active end
    end
    for _, active in ipairs(snapshot) do
        if active.released == true then
            self.active[active] = nil
        elseif type(active.IsEditing) == "function" and active:IsEditing() == true then
            if tostring(active.draftCommitMode or "blur") == "explicit" and type(active.SuspendEditing) == "function" then
                active:SuspendEditing(reason or "input_switch")
            elseif type(active.CommitAndEndEditing) == "function" then
                -- Blur-mode compatibility: switching fields historically commits the previous field. DraftSession V2
                -- changes only explicit-confirm inputs; legacy blur fields keep that behavior.
                active:CommitAndEndEditing(reason or "input_switch")
            elseif type(active.EndEditing) == "function" then
                active:EndEditing(reason or "input_switch")
            end
        end
    end
    return true
end

function DraftCoordinator:Begin(component)
    self:SuspendOthers(component, "input_switch")
    if component ~= nil then self.active[component] = true end
    return true
end

-- 中文维护注释（DraftSession V2 / page fence）：高频 UnitLines/RangeAssist Presentation 刷新
-- 必须看 draftActive，而不是 Native Focus。真实 RU LostFocus 可以先于用户完成输入；若这里只看 IsEditing，
-- blur 后页面会立即恢复 Authority 文本，正是“删一个字符过一会又变回来”的根因。
RSUI.InputDraftScopeContractVersion = 2
function DraftCoordinator:HasActiveWithin(ancestor)
    if ancestor == nil then return false end
    local stale = {}
    for active in pairs(self.active) do
        local hasDraft = active ~= nil and active.released ~= true
            and type(active.HasDraftSession) == "function" and active:HasDraftSession() == true
        if not hasDraft then
            stale[#stale + 1] = active
        else
            local node, guard = active, 0
            while type(node) == "table" and guard < 64 do
                if node == ancestor then return true end
                node = node.parentComponent
                guard = guard + 1
            end
        end
    end
    for _, active in ipairs(stale) do self.active[active] = nil end
    return false
end
function RSUI:HasActiveInputDraftWithin(ancestor)
    return DraftCoordinator:HasActiveWithin(ancestor)
end

function DraftCoordinator:GetSnapshot()
    local activeCount, focusedCount, ids = 0, 0, {}
    for component in pairs(self.active) do
        if component ~= nil and component.released ~= true and type(component.HasDraftSession) == "function"
            and component:HasDraftSession() == true then
            activeCount = activeCount + 1
            ids[#ids + 1] = tostring(component.id or "input")
            if type(component.IsEditing) == "function" and component:IsEditing() == true then focusedCount = focusedCount + 1 end
        end
    end
    table.sort(ids)
    return {
        version = 2, active = activeCount, focused = focusedCount, ids = ids,
        began = tonumber(self.metrics.began) or 0, suspended = tonumber(self.metrics.suspended) or 0,
        committed = tonumber(self.metrics.committed) or 0, cancelled = tonumber(self.metrics.cancelled) or 0,
        ended = tonumber(self.metrics.ended) or 0,
        renderSuppressions = tonumber(RSUI.metrics.interactiveDraftRenderSuppressions) or 0,
    }
end
function RSUI:GetInputDraftSessionSnapshot() return DraftCoordinator:GetSnapshot() end


RSUI:RegisterType("Toggle", function(spec)
    local width = math.max(56, tonumber(spec.width) or 92)
    local height = math.max(22, tonumber(spec.height) or Token("size.buttonH", 26))
    local button = UI:CreateButton(spec.parent, spec.id, "", tonumber(spec.x) or 0, tonumber(spec.y) or 0, width, height,
        tonumber(spec.fontSize) or Token("font.small", 10), false, spec.gradient ~= false)
    if button == nil then return nil, "toggle_create_failed" end
    local c = RSUI:NewComponent("Toggle", spec, button)
    if type(RSUI.BindStableButtonHover) == "function" then RSUI:BindStableButtonHover(c, button) end
    local binding, bindingErr = RequireBinding(c, spec, "toggle")
    if binding == nil then return nil, bindingErr end
    c.value = spec.value == true
    function c:GetValue() return Read(self.binding, self.value) == true end
    function c:Render()
        RSUI:_Count(self.kind, "rendered", 1)
        local value = self:GetValue()
        self.value = value
        UI:SetText(self.root, value and tostring(spec.onText or "开") or tostring(spec.offText or "关"), self.owner)
        UI:SetButtonActive(self.root, value, self.owner)
        return value
    end
    function c:SetValue(value, source)
        if self.enabled == false then return false end
        value = value == true
        local ok = Write(self.binding, value, true, source or "toggle", spec)
        if ok then self.value = value end
        -- Always redraw from the authoritative binding.  A rejected write must
        -- never publish onChanged or leave the control visually claiming that
        -- an unapplied value succeeded.
        self:Render()
        if ok and type(spec.onChanged) == "function" then RSUI:Callback("rsui:" .. self.id .. ":changed", spec.onChanged, value, self) end
        return ok
    end
    c:RequireOn(button, "OnClick", function() return c:SetValue(not c:GetValue(), "click") end, "rsui:" .. spec.id .. ":toggle")
    c:SetEnabled(spec.enabled ~= false)
    c:Render()
    return c
end)


-- Compact one-of-many selector for HUD/toolbars. This is deliberately a
-- reusable RSUI control instead of a DPS-only button row: mode/side/metric
-- selectors are common in floating widgets, and they need one consistent
-- selected-state, persistence and idempotence contract.
--
-- No Tick/OnUpdate is used. Clicking the already-selected segment is an
-- idempotent success and does not write the persistent binding again.
RSUI.SegmentedSelectorContractVersion = 1
RSUI:RegisterType("SegmentedSelector", function(spec)
    local rowFactory = RSUI.types and RSUI.types.HorizontalBox or nil
    if type(rowFactory) ~= "function" then return nil, "segmented_horizontal_box_unavailable" end

    local sourceItems = type(spec.items) == "table" and spec.items or {}
    local maxItems = math.max(1, math.min(8, math.floor(tonumber(spec.maxItems) or 8)))
    local items = {}
    for index = 1, math.min(#sourceItems, maxItems) do
        local source = sourceItems[index]
        if type(source) == "table" and source.value ~= nil then
            items[#items + 1] = {
                value = source.value,
                text = tostring(source.text or source.label or source.value),
                width = tonumber(source.width),
                enabled = source.enabled ~= false,
            }
        end
    end
    if #items < 2 then return nil, "segmented_items_required" end

    spec.gap = math.max(0, tonumber(spec.gap) or 2)
    local c, err = rowFactory(spec)
    if c == nil then return nil, err or "segmented_host_create_failed" end
    c.kind = "SegmentedSelector"
    local binding, bindingErr = RequireBinding(c, spec, "segmented_selector")
    if binding == nil then return nil, bindingErr end
    c.items = items
    c.buttons = {}
    c.value = spec.value ~= nil and spec.value or items[1].value

    local function Equal(a, b)
        if type(spec.equals) == "function" then
            local ok, result = RSUI:Callback("rsui:" .. c.id .. ":equals", spec.equals, a, b, c)
            if ok then return result == true end
        end
        return a == b
    end

    function c:GetValue()
        return Read(self.binding, self.value)
    end

    function c:Render(explicitValue)
        RSUI:_Count(self.kind, "rendered", 1)
        local current = explicitValue ~= nil and explicitValue or self:GetValue()
        self.value = current
        for index, item in ipairs(self.items) do
            local button = self.buttons[index]
            if button ~= nil then
                local childOk, childErr = self:EnsureChildEnabled(button, self.enabled ~= false and item.enabled ~= false, "segment_" .. tostring(index))
                if childOk ~= true then return nil, childErr end
                button:Render({
                    text = item.text,
                    selected = Equal(item.value, current),
                })
            end
        end
        return current, nil
    end

    function c:SetValue(value, source)
        if self.enabled == false then return false, "disabled" end
        local valid = false
        for _, item in ipairs(self.items) do
            if Equal(item.value, value) and item.enabled ~= false then valid = true; value = item.value; break end
        end
        if not valid then return false, "invalid_segment_value" end
        local current = self:GetValue()
        if Equal(current, value) then
            self:Render(current)
            return true, false
        end
        local ok = Write(self.binding, value, true, source or "segment_click", spec)
        if ok then self.value = value end
        self:Render(ok and value or self:GetValue())
        if ok and type(spec.onChanged) == "function" then
            RSUI:Callback("rsui:" .. self.id .. ":changed", spec.onChanged, value, self)
        end
        return ok, ok == true
    end

    local baseSetEnabled = c.SetEnabled
    function c:SetEnabled(enabled)
        local state, accepted, detail = baseSetEnabled(self, enabled)
        if accepted ~= true then return state, false, detail end
        local _, renderErr = self:Render()
        if renderErr ~= nil then return state, false, renderErr end
        return self.enabled, true, nil
    end

    local defaultWidth = math.max(34, tonumber(spec.itemWidth) or 48)
    local height = math.max(22, tonumber(spec.height) or Token("size.buttonH", 26))
    for index, item in ipairs(items) do
        local itemValue = item.value
        local buttonWidth = math.max(30, tonumber(item.width) or defaultWidth)
        local button = RSUI:Button({
            id = tostring(spec.id) .. "_segment_" .. tostring(index),
            parent = c,
            text = item.text,
            compact = true,
            height = height,
            fontSize = tonumber(spec.fontSize) or Token("font.small", 10),
            gradient = spec.gradient ~= false,
            onClick = function() return c:SetValue(itemValue, "segment_click") end,
            slot = { size = "fixed", width = buttonWidth, minWidth = buttonWidth, hAlign = "fill", vAlign = "fill" },
        })
        if button == nil then return nil, "segmented_button_create_failed:" .. tostring(index) end
        c.buttons[index] = button
    end
    c:SetEnabled(spec.enabled ~= false)
    c:Render()
    return c
end, function(spec)
    if type(spec.items) ~= "table" then return false, "segmented_items_table_required" end
    local maxItems = math.max(1, math.min(8, math.floor(tonumber(spec.maxItems) or 8)))
    local valid = 0
    for index = 1, math.min(#spec.items, maxItems) do
        local item = spec.items[index]
        if type(item) == "table" and item.value ~= nil then valid = valid + 1 end
    end
    if valid < 2 then return false, "segmented_items_required" end
    return true
end)

RSUI:RegisterType("TextInput", function(spec)
    local width = math.max(56, tonumber(spec.width) or 160)
    local height = math.max(22, tonumber(spec.height) or Token("size.inputH", 24))
    local edit = UI:CreateEditBox(spec.parent, spec.id, tonumber(spec.x) or 0, tonumber(spec.y) or 0, width, height, tonumber(spec.maxLength) or 64)
    if edit == nil then return nil, "editbox_create_failed" end
    local c = RSUI:NewComponent("TextInput", spec, edit)
    local binding, bindingErr = RequireBinding(c, spec, "text_input")
    if binding == nil then return nil, bindingErr end
    if spec.placeholder ~= nil and type(edit.SetGuideText) == "function" then
        pcall(function() edit:SetGuideText(tostring(spec.placeholder or "")) end)
    end
    c.value = tostring(spec.value or "")
    c.editing = false
    c.draftActive = false
    c.draftText = nil
    c.draftCommitMode = tostring(spec.draftCommitMode or (spec.submitOnLostFocus == false and "explicit" or "blur"))
    if c.draftCommitMode ~= "explicit" then c.draftCommitMode = "blur" end
    local function Normalize(value)
        local text = tostring(value or "")
        if spec.trim ~= false then text = text:match("^%s*(.-)%s*$") or "" end
        return text
    end
    local function NativeText(self)
        if self.root ~= nil and type(self.root.GetText) == "function" then return Normalize(self.root:GetText()) end
        return Normalize(self.value)
    end
    local function CaptureDraft(self, reason)
        if self.draftActive ~= true then return NativeText(self) end
        self.draftText = NativeText(self)
        self.draftLastReason = tostring(reason or "capture")
        return self.draftText
    end
    local function ClearDraft(self, outcome, reason)
        local existed = self.draftActive == true
        self.draftActive, self.draftText = false, nil
        self.draftLastFinalizeReason = tostring(reason or outcome or "end")
        DraftCoordinator:Forget(self)
        if existed and outcome ~= nil then DraftCoordinator:Bump(outcome) end
        return existed
    end
    function c:GetValue() return Normalize(Read(self.binding, self.value)) end
    function c:HasDraftSession() return self.draftActive == true end
    -- 中文维护注释（DraftSession V2 / detached draft）：Native EditBox 只在当前持有焦点时作为输入载体；
    -- 失焦后的 Authority 是 Lua draftText，不能重新读取可能被 RU/页面刷新改写过的 Native 文本。
    function c:GetDraftValue()
        if self.draftActive == true then
            if self:IsEditing() == true then return CaptureDraft(self, "draft_read") end
            return Normalize(self.draftText)
        end
        return NativeText(self)
    end
    function c:IsEditing()
        return self.editing == true or (self.root ~= nil and self.root.rsUiKeyboardArmed == true) or IsFocusedDraft(self)
    end
    function c:Render(explicitValue, source)
        RSUI:_Count(self.kind, "rendered", 1)
        local value = Normalize(explicitValue ~= nil and explicitValue or self:GetValue())
        if ShouldPreserveDraft(self, source) then
            CountDraftSuppression()
            return self:GetDraftValue()
        end
        if explicitValue == nil then self.value = value end
        UI:SetText(self.root, value, self.owner)
        self.lastRenderedText = value
        return value
    end
    function c:SetValue(value, notify, source)
        if self.enabled == false then return false end
        value = Normalize(value)
        local ok = Write(self.binding, value, true, source or "text_input_api", spec)
        if ok then
            self.value = value
            self:Render(value, "commit")
            -- Programmatic SetValue is an explicit Authority replacement (row select / clear / import).
            -- It supersedes any pending draft so a stale Lua transaction cannot later resurrect old text.
            local wasEditing = self:IsEditing()
            ClearDraft(self, "ended", tostring(source or "text_input_api") .. ":set_value")
            self.editing = false
            if wasEditing then EndEditInteraction(self, tostring(source or "text_input_api") .. ":set_value") end
            SetInputFocusVisual(self, false)
        else
            self:Render(nil, "rejected")
        end
        if ok and notify ~= false and type(spec.onChanged) == "function" then
            RSUI:Callback("rsui:" .. self.id .. ":changed", spec.onChanged, value, self)
        end
        return ok
    end
    function c:Submit(source)
        if self.enabled == false then return false end
        local value = self:GetDraftValue()
        if spec.allowEmpty == false and value == "" then
            self:Render(nil, "rejected")
            if type(spec.onInvalid) == "function" then RSUI:Callback("rsui:" .. self.id .. ":invalid", spec.onInvalid, value, self) end
            return false
        end
        local ok = Write(self.binding, value, true, source or "edit", spec)
        if ok then
            self.value = value
            self:Render(value, "commit")
        else
            self:Render(nil, "rejected")
        end
        if ok and type(spec.onChanged) == "function" then RSUI:Callback("rsui:" .. self.id .. ":changed", spec.onChanged, value, self) end
        if ok and type(spec.onSubmit) == "function" then
            local callbackOk, result = RSUI:Callback("rsui:" .. self.id .. ":submit", spec.onSubmit, value, self)
            if callbackOk == false or result == false then return false end
        end
        return ok
    end
    function c:BeginEditing(source)
        CancelInputLostFocusRecheck(self)
        local hadDraft = self.draftActive == true
        if not hadDraft then
            self.draftActive = true
            self.draftText = NativeText(self)
            self.draftLastReason = tostring(source or "text_input_begin")
            DraftCoordinator:Bump("began")
        end
        DraftCoordinator:Begin(self)
        -- If RU repainted the dormant EditBox after blur, restore the Lua-owned draft before rearming keyboard.
        if self.draftText ~= nil then UI:SetText(self.root, tostring(self.draftText), self.owner) end
        local ok, err = BeginEditInteraction(self, source or ("text_input:" .. tostring(self.id)))
        if ok == true then
            self.editing = true
            SetInputFocusVisual(self, true)
        else
            self.editing = false
            SetInputFocusVisual(self, false)
            if not hadDraft then ClearDraft(self, "cancelled", "activation_failed") end
        end
        return ok, err
    end
    -- 中文维护注释（DraftSession V2 / suspend）：LostFocus 对显式确认输入只代表 Native keyboard ownership
    -- 结束，不代表业务事务结束。先捕获 Native 文本到 Lua，再撤键盘/焦点；不写 Binding、不恢复 Authority。
    function c:SuspendEditing(source)
        CancelInputLostFocusRecheck(self)
        if self.draftActive == true then CaptureDraft(self, source or "text_input_suspend") end
        local wasEditing = self:IsEditing()
        local nested = self._endingEdit == true
        self._endingEdit = true
        self.editing = false
        local ok, err = true, nil
        if wasEditing then ok, err = EndEditInteraction(self, source or ("text_input:" .. tostring(self.id) .. ":suspend")) end
        SetInputFocusVisual(self, false)
        self._endingEdit = nested
        if self.draftActive == true then DraftCoordinator.active[self] = true; DraftCoordinator:Bump("suspended") end
        return ok, err
    end
    -- EndEditing is an explicit caller boundary (successful create/rename, page deactivation): drop draft without
    -- writing Authority or forcing a restore. LostFocus must use SuspendEditing instead for explicit-mode controls.
    function c:EndEditing(source)
        CancelInputLostFocusRecheck(self)
        if self.draftActive == true and self:IsEditing() == true then CaptureDraft(self, source or "text_input_end") end
        local wasEditing = self:IsEditing()
        local nested = self._endingEdit == true
        self._endingEdit = true
        self.editing = false
        ClearDraft(self, "ended", source or "text_input_end")
        local ok, err = true, nil
        if wasEditing then ok, err = EndEditInteraction(self, source or ("text_input:" .. tostring(self.id) .. ":end")) end
        SetInputFocusVisual(self, false)
        self._endingEdit = nested
        return ok, err
    end
    function c:CancelEditing(source)
        CancelInputLostFocusRecheck(self)
        local wasEditing = self:IsEditing()
        local nested = self._endingEdit == true
        self._endingEdit = true
        self.editing = false
        ClearDraft(self, "cancelled", source or "text_input_cancel")
        if wasEditing then EndEditInteraction(self, tostring(source or "text_input_cancel")) end
        SetInputFocusVisual(self, false)
        self:Render(nil, "restore_authority")
        self._endingEdit = nested
        return true
    end
    function c:CommitAndEndEditing(source)
        CancelInputLostFocusRecheck(self)
        local nested = self._endingEdit == true
        self._endingEdit = true
        local committed = self:Submit(source or "edit_commit")
        local wasEditing = self:IsEditing()
        self.editing = false
        if committed == true then DraftCoordinator:Bump("committed") end
        ClearDraft(self, nil, source or "edit_commit")
        local ended, endErr = true, nil
        if wasEditing then ended, endErr = EndEditInteraction(self, tostring(source or "edit_commit") .. ":end") end
        SetInputFocusVisual(self, false)
        self._endingEdit = nested
        if committed ~= true then return false, "commit_rejected" end
        return ended == true, endErr
    end
    local BaseSetEnabled = c.SetEnabled
    function c:SetEnabled(enabled)
        if enabled == false and (self:HasDraftSession() or self:IsEditing()) then self:CancelEditing("text_input_disabled") end
        return BaseSetEnabled(self, enabled)
    end
    local BaseRelease = c.Release
    function c:Release()
        if self.released == true then return 0 end
        CancelInputLostFocusRecheck(self)
        if self:HasDraftSession() or self:IsEditing() then self:CancelEditing("text_input_release") else DraftCoordinator:Forget(self); SetInputFocusVisual(self, false) end
        return BaseRelease(self)
    end
    local activationBound = c:RequireOn(edit, "OnClick", function() return c:BeginEditing("text_input_click") end,
        "rsui:" .. spec.id .. ":activate")
    if activationBound ~= true then return c end
    for _, eventName in ipairs({ "OnEnterPressed", "OnEditEnter" }) do
        c:On(edit, eventName, function()
            if c:HasDraftSession() ~= true and c:IsEditing() ~= true then return true end
            return c:CommitAndEndEditing("enter")
        end, "rsui:" .. spec.id .. ":" .. eventName)
    end
    local function FinalizeTextInputLostFocus(source)
        if c._endingEdit == true then return true end
        if c.draftCommitMode == "explicit" then
            return c:SuspendEditing(tostring(source or "text_input_lost_focus"))
        end
        if c:HasDraftSession() ~= true and c:IsEditing() ~= true then
            EndEditInteraction(c, tostring(source or "text_input_lost_focus_inert"))
            SetInputFocusVisual(c, false)
            return true
        end
        local result = c:Submit("blur")
        c:EndEditing(tostring(source or "text_input_lost_focus"))
        return result
    end
    c:On(edit, "OnLostFocus", function()
        if c._endingEdit == true then return true end
        if DeferAmbiguousLostFocus(c, FinalizeTextInputLostFocus, "text_input_lost_focus") then return true end
        return FinalizeTextInputLostFocus("text_input_lost_focus")
    end, "rsui:" .. spec.id .. ":OnLostFocus")
    c:SetEnabled(spec.enabled ~= false)
    SetInputFocusVisual(c, false)
    c:Render(nil, "init")
    return c
end)

RSUI:RegisterType("NumericInput", function(spec)
    spec.min = tonumber(spec.min)
    spec.max = tonumber(spec.max)
    if spec.min ~= nil and spec.max ~= nil and spec.max < spec.min then spec.min, spec.max = spec.max, spec.min end
    spec.step = math.abs(tonumber(spec.step) or 1)
    local width = math.max(42, tonumber(spec.width) or 72)
    local height = math.max(22, tonumber(spec.height) or Token("size.inputH", 24))
    local edit = UI:CreateEditBox(spec.parent, spec.id, tonumber(spec.x) or 0, tonumber(spec.y) or 0, width, height, tonumber(spec.maxLength) or 16)
    if edit == nil then return nil, "editbox_create_failed" end
    local c = RSUI:NewComponent("NumericInput", spec, edit)
    local binding, bindingErr = RequireBinding(c, spec, "numeric_input")
    if binding == nil then return nil, bindingErr end
    if spec.placeholder ~= nil and type(edit.SetGuideText) == "function" then
        pcall(function() edit:SetGuideText(tostring(spec.placeholder or "")) end)
    end
    c.value = NormalizeNumber(spec, spec.value)
    c.editing = false
    c.draftActive = false
    c.draftText = nil
    c.draftCommitMode = tostring(spec.draftCommitMode or "blur")
    if c.draftCommitMode ~= "explicit" then c.draftCommitMode = "blur" end
    local function NativeText(self)
        if self.root ~= nil and type(self.root.GetText) == "function" then return tostring(self.root:GetText() or "") end
        return ""
    end
    local function CaptureDraft(self, reason)
        if self.draftActive ~= true then return NativeText(self) end
        self.draftText = NativeText(self)
        self.draftLastReason = tostring(reason or "capture")
        return self.draftText
    end
    local function ClearDraft(self, outcome, reason)
        local existed = self.draftActive == true
        self.draftActive, self.draftText = false, nil
        self.draftLastFinalizeReason = tostring(reason or outcome or "end")
        DraftCoordinator:Forget(self)
        if existed and outcome ~= nil then DraftCoordinator:Bump(outcome) end
        return existed
    end
    function c:GetValue() return NormalizeNumber(spec, Read(self.binding, self.value)) end
    function c:HasDraftSession() return self.draftActive == true end
    function c:GetDraftValue()
        if self.draftActive == true then
            if self:IsEditing() == true then return CaptureDraft(self, "draft_read") end
            return tostring(self.draftText or "")
        end
        return NativeText(self)
    end
    function c:GetDraftNumber()
        local text = self:GetDraftValue()
        local suffix = tostring(spec.suffix or spec.unit or "")
        if suffix ~= "" and #text >= #suffix and text:sub(-#suffix) == suffix then text = text:sub(1, #text - #suffix) end
        return NormalizeNumber(spec, text)
    end
    function c:IsEditing()
        return self.editing == true or (self.root ~= nil and self.root.rsUiKeyboardArmed == true) or IsFocusedDraft(self)
    end
    function c:Format(value)
        if type(spec.format) == "function" then
            local ok, text = RSUI:Callback("rsui:" .. self.id .. ":format", spec.format, value)
            if ok and text ~= nil then return tostring(text) end
        end
        local decimals = 0
        if spec.integer ~= true and spec.step < 1 then decimals = spec.step >= 0.1 and 1 or (spec.step >= 0.01 and 2 or 3) end
        local text = decimals == 0 and tostring(math.floor((tonumber(value) or 0) + 0.5)) or string.format("%." .. decimals .. "f", tonumber(value) or 0)
        if decimals > 0 then text = text:gsub("0+$", ""):gsub("%.$", "") end
        return text .. tostring(spec.suffix or spec.unit or "")
    end
    function c:Render(explicitValue, source)
        RSUI:_Count(self.kind, "rendered", 1)
        local value = NormalizeNumber(spec, explicitValue ~= nil and explicitValue or self:GetValue())
        if value == nil then return false end
        if ShouldPreserveDraft(self, source) then
            CountDraftSuppression()
            return value
        end
        if explicitValue == nil then self.value = value end
        local rendered = self:Format(value)
        UI:SetText(self.root, rendered, self.owner)
        self.lastRenderedText = rendered
        return value
    end
    function c:Submit(source)
        if self.enabled == false then return false end
        local text = self:GetDraftValue()
        local value = self:GetDraftNumber()
        if value == nil then
            if type(spec.onInvalid) == "function" then RSUI:Callback("rsui:" .. self.id .. ":invalid", spec.onInvalid, text, self) end
            self:Render(nil, "rejected")
            return false
        end
        local ok = Write(self.binding, value, true, source or "edit", spec)
        if ok then
            self.value = value
            self:Render(value, "commit")
        else
            self:Render(nil, "rejected")
        end
        if ok and type(spec.onChanged) == "function" then RSUI:Callback("rsui:" .. self.id .. ":changed", spec.onChanged, value, self) end
        return ok
    end
    function c:BeginEditing(source)
        CancelInputLostFocusRecheck(self)
        local hadDraft = self.draftActive == true
        if not hadDraft then
            self.draftActive = true
            self.draftText = NativeText(self)
            self.draftLastReason = tostring(source or "numeric_input_begin")
            DraftCoordinator:Bump("began")
        end
        DraftCoordinator:Begin(self)
        if self.draftText ~= nil then UI:SetText(self.root, tostring(self.draftText), self.owner) end
        local ok, err = BeginEditInteraction(self, source or ("numeric_input:" .. tostring(self.id)))
        if ok == true then
            self.editing = true
            SetInputFocusVisual(self, true)
        else
            self.editing = false
            SetInputFocusVisual(self, false)
            if not hadDraft then ClearDraft(self, "cancelled", "activation_failed") end
        end
        return ok, err
    end
    -- 中文维护注释（DraftSession V2 / numeric suspend）：显式 Apply 数值框在真实/伪 LostFocus 后只把
    -- Native 文本存入 Lua draftText 并释放 keyboard；不调用 Binding:Set，不把 Feature Authority 回写进框。
    function c:SuspendEditing(source)
        CancelInputLostFocusRecheck(self)
        if self.draftActive == true then CaptureDraft(self, source or "numeric_input_suspend") end
        local wasEditing = self:IsEditing()
        local nested = self._endingEdit == true
        self._endingEdit = true
        self.editing = false
        local ok, err = true, nil
        if wasEditing then ok, err = EndEditInteraction(self, source or ("numeric_input:" .. tostring(self.id) .. ":suspend")) end
        SetInputFocusVisual(self, false)
        self._endingEdit = nested
        if self.draftActive == true then DraftCoordinator.active[self] = true; DraftCoordinator:Bump("suspended") end
        return ok, err
    end
    function c:EndEditing(source)
        CancelInputLostFocusRecheck(self)
        if self.draftActive == true and self:IsEditing() == true then CaptureDraft(self, source or "numeric_input_end") end
        local wasEditing = self:IsEditing()
        local nested = self._endingEdit == true
        self._endingEdit = true
        self.editing = false
        ClearDraft(self, "ended", source or "numeric_input_end")
        local ok, err = true, nil
        if wasEditing then ok, err = EndEditInteraction(self, source or ("numeric_input:" .. tostring(self.id) .. ":end")) end
        SetInputFocusVisual(self, false)
        self._endingEdit = nested
        return ok, err
    end
    function c:CancelEditing(source)
        CancelInputLostFocusRecheck(self)
        local wasEditing = self:IsEditing()
        local nested = self._endingEdit == true
        self._endingEdit = true
        self.editing = false
        ClearDraft(self, "cancelled", source or "numeric_input_cancel")
        if wasEditing then EndEditInteraction(self, tostring(source or "numeric_input_cancel")) end
        SetInputFocusVisual(self, false)
        self:Render(nil, "restore_authority")
        self._endingEdit = nested
        return true
    end
    function c:CommitAndEndEditing(source)
        CancelInputLostFocusRecheck(self)
        local nested = self._endingEdit == true
        self._endingEdit = true
        local committed = self:Submit(source or "edit_commit")
        local wasEditing = self:IsEditing()
        self.editing = false
        if committed == true then DraftCoordinator:Bump("committed") end
        ClearDraft(self, nil, source or "edit_commit")
        local ended, endErr = true, nil
        if wasEditing then ended, endErr = EndEditInteraction(self, tostring(source or "edit_commit") .. ":end") end
        SetInputFocusVisual(self, false)
        self._endingEdit = nested
        if committed ~= true then return false, "commit_rejected" end
        return ended == true, endErr
    end
    local BaseSetEnabled = c.SetEnabled
    function c:SetEnabled(enabled)
        if enabled == false and (self:HasDraftSession() or self:IsEditing()) then self:CancelEditing("numeric_input_disabled") end
        return BaseSetEnabled(self, enabled)
    end
    local BaseRelease = c.Release
    function c:Release()
        if self.released == true then return 0 end
        CancelInputLostFocusRecheck(self)
        if self:HasDraftSession() or self:IsEditing() then self:CancelEditing("numeric_input_release") else DraftCoordinator:Forget(self); SetInputFocusVisual(self, false) end
        return BaseRelease(self)
    end
    local activationBound = c:RequireOn(edit, "OnClick", function() return c:BeginEditing("numeric_input_click") end,
        "rsui:" .. spec.id .. ":activate")
    if activationBound ~= true then return c end
    for _, eventName in ipairs({ "OnEnterPressed", "OnEditEnter" }) do
        c:On(edit, eventName, function()
            if c:HasDraftSession() ~= true and c:IsEditing() ~= true then return true end
            return c:CommitAndEndEditing("enter")
        end, "rsui:" .. spec.id .. ":" .. eventName)
    end
    local function FinalizeNumericInputLostFocus(source)
        if c._endingEdit == true then return true end
        if c.draftCommitMode == "explicit" then
            return c:SuspendEditing(tostring(source or "numeric_input_lost_focus"))
        end
        if c:HasDraftSession() ~= true and c:IsEditing() ~= true then
            EndEditInteraction(c, tostring(source or "numeric_input_lost_focus_inert"))
            SetInputFocusVisual(c, false)
            return true
        end
        local result = c:Submit("blur")
        c:EndEditing(tostring(source or "numeric_input_lost_focus"))
        return result
    end
    c:On(edit, "OnLostFocus", function()
        if c._endingEdit == true then return true end
        if DeferAmbiguousLostFocus(c, FinalizeNumericInputLostFocus, "numeric_input_lost_focus") then return true end
        return FinalizeNumericInputLostFocus("numeric_input_lost_focus")
    end, "rsui:" .. spec.id .. ":OnLostFocus")
    c:SetEnabled(spec.enabled ~= false)
    SetInputFocusVisual(c, false)
    c:Render(nil, "init")
    return c
end)

RSUI:RegisterType("Slider", function(spec)
    spec.min = tonumber(spec.min) or 0
    spec.max = tonumber(spec.max) or 100
    if spec.max < spec.min then spec.min, spec.max = spec.max, spec.min end
    spec.step = math.abs(tonumber(spec.step) or 1)
    local width = math.max(30, tonumber(spec.width) or 160)
    local height = math.max(14, tonumber(spec.height) or 20)
    local binding, bindingErr = RSUI:Binding(spec)
    if binding == nil then return nil, "slider_binding_failed:" .. tostring(bindingErr or "unknown") end
    local initial = NormalizeNumber(spec, Read(binding, spec.value)) or spec.min
    local slider = UI:CreateSlider(spec.parent, spec.id, tonumber(spec.x) or 0, tonumber(spec.y) or 0, width, height, spec.min, spec.max, spec.step, initial)
    if slider == nil then return nil, "slider_create_failed" end
    local c = RSUI:NewComponent("Slider", spec, slider)
    c.binding, c.value, c.previewValue = binding, initial, initial
    function c:GetValue() return NormalizeNumber(spec, Read(self.binding, self.value)) or self.value end
    function c:IsInteracting() return self.root ~= nil and self.root.rsDragging == true end
    function c:GetRange() return tonumber(spec.min), tonumber(spec.max), tonumber(spec.step) end
    function c:SetRange(minimum, maximum, step)
        minimum, maximum = tonumber(minimum), tonumber(maximum)
        if minimum == nil or maximum == nil then return false, "invalid_slider_range" end
        if maximum < minimum then minimum, maximum = maximum, minimum end
        if self:IsInteracting() then return false, "slider_drag_active" end
        local nextStep = math.abs(tonumber(step) or tonumber(spec.step) or 1)
        if self.root == nil or type(self.root.SetRange) ~= "function" then return false, "native_slider_range_unavailable" end
        local ok, changedOrErr = self.root:SetRange(minimum, maximum, nextStep)
        if ok ~= true then return false, changedOrErr or "native_slider_range_rejected" end
        spec.min, spec.max, spec.step = minimum, maximum, nextStep
        self.value = NormalizeNumber(spec, self.value) or minimum
        self.previewValue = NormalizeNumber(spec, self.previewValue) or self.value
        self:Render(self.previewValue, "range_change")
        return true, changedOrErr == true
    end
    function c:Render(explicit, source)
        RSUI:_Count(self.kind, "rendered", 1)
        if self:IsInteracting() and CanOverrideActiveSliderPreview(source) ~= true then
            CountDraftSuppression()
            return self.previewValue
        end
        local value = NormalizeNumber(spec, explicit ~= nil and explicit or self:GetValue())
        if value == nil then return false end
        self.previewValue = value
        if type(self.root.GetValue) ~= "function" or tonumber(self.root:GetValue()) ~= tonumber(value) then self.root:SetValue(value, false) end
        return value
    end
    function c:Preview(value, source)
        if self.enabled == false then return false end
        value = NormalizeNumber(spec, value)
        if value == nil then return false end
        self.previewValue = value
        self:Render(value, "interaction")
        if type(spec.onPreview) == "function" then RSUI:Callback("rsui:" .. self.id .. ":preview", spec.onPreview, value, self, source or "slider") end
        return true
    end
    function c:CommitValue(value, source)
        if self.enabled == false then return false end
        value = NormalizeNumber(spec, value)
        if value == nil then return false end
        local ok = Write(self.binding, value, true, source or "slider", spec)
        if ok then
            self.value, self.previewValue = value, value
            self:Render(value, "commit")
        else
            local authoritative = self:GetValue()
            self.previewValue = authoritative
            self:Render(authoritative, "rejected")
        end
        if ok and type(spec.onChanged) == "function" then RSUI:Callback("rsui:" .. self.id .. ":changed", spec.onChanged, value, self) end
        return ok
    end
    if type(slider.SetValueChangedHandler) == "function" then
        slider:SetValueChangedHandler(function(value, final)
            if final == true then c:CommitValue(value, "slider") else c:Preview(value, "slider") end
        end)
    end
    c:SetEnabled(spec.enabled ~= false)
    c:Render(initial, "init")
    local baseRelease = c.Release
    function c:Release()
        local drag = self.root and self.root.rsDragSurface or nil
        if self.root ~= nil and self.root.rsDragging == true and drag ~= nil and type(drag.StopMovingOrSizing) == "function" then
            pcall(function() drag:StopMovingOrSizing() end)
        end
        if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then
            S.Scheduler:RemoveTask("ui_custom_slider:" .. tostring(spec.id))
        end
        if drag ~= nil and type(drag.ReleaseHandler) == "function" then
            for _, eventName in ipairs({ "OnDragStart", "OnDragStop", "OnUpdate" }) do
                pcall(function() drag:ReleaseHandler(eventName) end)
            end
        end
        if self.root ~= nil then
            self.root.rsDragging = false
            self.root.rsDragStartX, self.root.rsDragStartValue = nil, nil
            if type(self.root.SetValueChangedHandler) == "function" then self.root:SetValueChangedHandler(nil)
            else self.root.rsValueChanged = nil end
        end
        return baseRelease(self)
    end
    return c
end)

RSUI.DropdownContractVersion = 3
RSUI.PopupCoordinateConsumerContractVersion = 3 -- 中文维护注释：Controls v3 按 Popup 类型选择安全车道：Dropdown 保留 Native-relative；ColorField V2 使用 Suite 父链 resolved viewport→UIParent，禁止跨层级顶层 Window→Button Anchor。
RSUI.PopupCoordinateConsumerLane = "popup-mixed-safe-v1" -- 中文维护注释：这是能力集合标签，不代表所有控件共享同一最终 Anchor 方式。
RSUI.DropdownDegradedFailClosedContractVersion = 1
RSUI.DropdownRuntimeInteractionContractVersion = 1
RSUI.PopupCoordinatorContractVersion = 1

local PopupCoordinator = RSUI.PopupCoordinator or {
    version = 1,
    instances = setmetatable({}, { __mode = "k" }),
}
RSUI.PopupCoordinator = PopupCoordinator
-- Compatibility alias only. Both names reference the exact same registry;
-- DropdownService must never become a second popup authority.
RSUI.DropdownService = PopupCoordinator

function PopupCoordinator:Register(component)
    if type(component) ~= "table" then return false end
    self.instances[component] = true
    return true
end

function PopupCoordinator:Unregister(component)
    if type(component) == "table" then self.instances[component] = nil end
    return true
end

function PopupCoordinator:CloseAll(except)
    local closed = 0
    for component in pairs(self.instances) do
        if component ~= except and type(component.Close) == "function" then
            local ok, changed = pcall(function() return component:Close() end)
            if ok and changed == true then closed = closed + 1 end
        end
    end
    return closed
end

local function DropdownFindValue(items, value)
    if value == nil then return nil end
    for index, item in ipairs(type(items) == "table" and items or {}) do
        if type(item) == "table" and item.value == value then return index end
    end
    return nil
end

local function InstallDropdownFallback(c, spec, reason)
    if type(c) ~= "table" then return nil, tostring(reason or "dropdown_fail_closed") end
    c.rsUiDegraded = true
    c.rsUiDegradedReason = tostring(reason or "dropdown_popup_unavailable")
    c.popup, c.up, c.down = nil, nil, nil
    c.optionButtons = {}
    c.open = false
    c.requestedEnabled = spec.enabled ~= false
    c.enabled = false

    local diagnostics = S.DiagnosticsManager
    if type(diagnostics) == "table" and type(diagnostics.Error) == "function" then
        diagnostics:Error("ui", "RSUI_DROPDOWN_DEGRADED", "下拉框弹层不可用，控件已安全禁用；当前值保持不变", {
            id = tostring(c.id or spec.id or ""), owner = tostring(c.owner or ""), reason = c.rsUiDegradedReason,
        })
    end

    function c:RefreshText()
        local text = tostring(spec.placeholder or "请选择")
        local item = self.items[self.selectedIndex]
        if type(item) == "table" then text = tostring(item.text or item.value or text) end
        UI:SetText(self.root, text .. "  ⚠", self.owner)
        return text
    end

    function c:SetItems(items)
        self.items = type(items) == "table" and items or {}
        self.selectedIndex = DropdownFindValue(self.items, self.value) or 0
        self:RefreshText()
        return true
    end

    function c:GetValue()
        return Read(self.binding, self.value)
    end

    function c:SetSelectedValue(value, silent, source)
        -- Rendering may mirror the authoritative bound value into the disabled
        -- presentation. Any user/API mutation path remains fail-closed.
        if source ~= "render" and silent ~= true then return false, "dropdown_degraded_fail_closed" end
        self.value = value
        self.selectedIndex = DropdownFindValue(self.items, value) or 0
        self:RefreshText()
        return true
    end

    function c:SetValue(value, notify)
        return false, "dropdown_degraded_fail_closed"
    end

    function c:Render()
        RSUI:_Count(self.kind, "rendered", 1)
        return self:SetSelectedValue(self:GetValue(), true, "render")
    end

    function c:Scroll() return false, "dropdown_degraded_fail_closed" end
    function c:Open() return false, "dropdown_degraded_fail_closed" end
    function c:Close() self.open = false return false end
    function c:ToggleOpen() return false, "dropdown_degraded_fail_closed" end
    function c:ApplyPopupLayout() return false end

    function c:Layout(x, y, nextWidth, nextHeight)
        local nextX, nextY = tonumber(x) or 0, tonumber(y) or 0
        local nextW = math.max(100, tonumber(nextWidth) or 180)
        local nextH = math.max(22, tonumber(nextHeight) or Token("size.buttonH", 26))
        self.lastLayout = { x = nextX, y = nextY, w = nextW, h = nextH, popupWidth = spec.popupWidth }
        UI:SetAnchor(self.root, spec.parent, nextX, nextY, self.owner)
        UI:SetExtent(self.root, nextW, nextH, self.owner)
        self:CommitLayoutState(nextX, nextY, nextW, nextH)
        RSUI:_Count(self.kind, "layouts", 1)
        return true
    end

    function c:SetEnabled(enabled)
        self.requestedEnabled = enabled ~= false
        self.enabled = false
        UI:SetEnabled(self.root, false, self.owner)
        self:RefreshText()
        return false
    end

    c:SetItems(spec.items or spec.options or {})
    c:SetEnabled(spec.enabled ~= false)
    c:Render()
    return c, c.rsUiDegradedReason
end

RSUI:RegisterType("Dropdown", function(spec)
    local width = math.max(100, tonumber(spec.width) or 180)
    local height = math.max(22, tonumber(spec.height) or Token("size.buttonH", 26))
    local maxVisible = math.max(3, math.min(16, math.floor(tonumber(spec.maxVisible) or 8)))
    local trigger, triggerErr = UI:CreateButton(spec.parent, spec.id .. "_trigger", "请选择  ▼", 0, 0, width, height,
        tonumber(spec.fontSize) or Token("font.small", 10), false, spec.gradient ~= false)
    if trigger == nil then return nil, "dropdown_trigger_create_failed" end

    local c = RSUI:NewComponent("Dropdown", spec, trigger)
    if c == nil then return nil, "dropdown_component_create_failed" end
    local binding, bindingErr = RequireBinding(c, spec, "dropdown")
    if binding == nil then return nil, bindingErr end
    c.value = spec.value
    c.items = {}
    c.selectedIndex = 0
    c.scrollOffset = 0
    c.maxVisible = maxVisible
    c.visibleRows = maxVisible
    c.optionButtons = {}
    c.open = false
    c.lastLayout = { x = 0, y = 0, w = width, h = height, popupWidth = spec.popupWidth }
    trigger.rsDropdownTrigger = true
    if trigger.rsUiDegraded == true then
        return InstallDropdownFallback(c, spec, "dropdown_trigger_degraded:" .. tostring(triggerErr or trigger.rsUiDegradedReason or "unknown"))
    end

    -- The popup is a top-level presentation surface so it is never clipped by a
    -- ScrollBox/card.  Logical ownership remains the V3 page/widget owner of the
    -- trigger.  CreatePanel's explicit owner path registers it under strict V3
    -- identity before any child controls are created.
    local popup, popupErr = UI:CreatePanel(UIParent, spec.id .. "_popup", 0, 0, width, height, "soft", {
        gradient = true,
        owner = c.owner,
        transientWindow = true,
        visible = false,
        pickable = false,
        drawPriority = Token("layer.popupPriority", 10000),
    })
    if popup == nil or popup.rsUiDegraded == true then
        return InstallDropdownFallback(c, spec, "dropdown_popup_create_failed:" .. tostring(popupErr or (popup and popup.rsUiDegradedReason) or "unknown"))
    end
    c.popup = popup
    -- UILayer is an optional RU capability. Never let an absent legacy-only
    -- helper invalidate a successfully created popup/page.
    if type(UI.TrySetUILayer) == "function" then UI:TrySetUILayer(popup, "system") end
    if type(popup.SetDrawPriority) == "function" then pcall(function() popup:SetDrawPriority(Token("layer.popupPriority", 10000)) end) end
    if type(UI.EnsurePickable) ~= "function" or type(UI.EnsureEnabled) ~= "function" then
        UI:SetVisible(popup, false, c.owner)
        return InstallDropdownFallback(c, spec, "dropdown_popup_interaction_contract_unavailable")
    end
    -- Hidden top-level surfaces start explicitly unpickable. The old build
    -- armed hit-testing before the initial hide, which left a hidden native
    -- surface able to intercept clicks on some RU clients.
    local popupPickOk, _, popupPickErr = UI:EnsurePickable(popup, false, c.owner)
    local popupEnableOk, _, popupEnableErr = UI:EnsureEnabled(popup, true, c.owner)
    if popupPickOk ~= true or popupEnableOk ~= true then
        UI:SetVisible(popup, false, c.owner)
        return InstallDropdownFallback(c, spec, "dropdown_popup_interaction_failed:" .. tostring(popupPickErr or popupEnableErr or "unknown"))
    end
    local popupHidden, popupHideErr = EnsureRawVisible(popup, false, c.owner)
    if popupHidden ~= true then
        return InstallDropdownFallback(c, spec, "dropdown_popup_initial_hide_failed:" .. tostring(popupHideErr or "unknown"))
    end

    local up, upErr = UI:CreateButton(popup, spec.id .. "_up", "^", 0, 0, 24, height, 9, false, false)
    local down, downErr = UI:CreateButton(popup, spec.id .. "_down", "v", 0, 0, 24, height, 9, false, false)
    if up == nil or down == nil or up.rsUiDegraded == true or down.rsUiDegraded == true then
        UI:SetVisible(popup, false, c.owner)
        return InstallDropdownFallback(c, spec, "dropdown_scroll_button_create_failed:" .. tostring(upErr or downErr or "degraded"))
    end
    c.up, c.down = up, down
    for index = 1, maxVisible do
        local button, buttonErr = UI:CreateButton(popup, spec.id .. "_option_" .. tostring(index), "", 0, 0, width, height,
            tonumber(spec.fontSize) or Token("font.small", 10), false, true)
        if button == nil or button.rsUiDegraded == true then
            UI:SetVisible(popup, false, c.owner)
            return InstallDropdownFallback(c, spec, "dropdown_option_create_failed:" .. tostring(index) .. ":" .. tostring(buttonErr or "degraded"))
        end
        c.optionButtons[index] = button
    end

    local function VisibleRowCapacity()
        return math.max(1, math.min(c.maxVisible, math.floor(tonumber(c.visibleRows) or c.maxVisible)))
    end

    local function MaxScrollOffset()
        return math.max(0, #c.items - VisibleRowCapacity())
    end

    function c:RefreshText()
        local text = tostring(spec.placeholder or "请选择")
        local item = self.items[self.selectedIndex]
        if type(item) == "table" then text = tostring(item.text or item.value or text) end
        UI:SetText(self.root, text .. "  ▼", self.owner)
        return text
    end

    function c:FailDropdownInteraction(reason)
        local detail = tostring(reason or "dropdown_runtime_interaction_failed")
        self.open = false
        if self.popup ~= nil then UI:SetVisible(self.popup, false, self.owner) end
        if type(self.FailClosedInteraction) == "function" then self:FailClosedInteraction(detail)
        else
            self.rsUiDegraded = true
            self.rsUiDegradedReason = detail
            UI:SetVisible(self.root, false, self.owner)
        end
        return false, detail
    end

    function c:EnsureChildEnabled(widget, desired, role)
        if type(UI.EnsureEnabled) ~= "function" then
            return self:FailDropdownInteraction("dropdown_enabled_contract_unavailable:" .. tostring(role or "child"))
        end
        local accepted, _, enableErr = UI:EnsureEnabled(widget, desired == true, self.owner)
        if accepted ~= true then
            return self:FailDropdownInteraction("dropdown_child_enable_failed:" .. tostring(role or "child") .. ":" .. tostring(enableErr or "unknown"))
        end
        return true, nil
    end

    function c:RefreshButtons()
        local count = #self.items
        local rowCapacity = VisibleRowCapacity()
        local needScroll = count > rowCapacity
        self.scrollOffset = math.max(0, math.min(tonumber(self.scrollOffset) or 0, MaxScrollOffset()))

        for index = 1, self.maxVisible do
            local button = self.optionButtons[index]
            local itemIndex = self.scrollOffset + index
            local item = self.items[itemIndex]
            -- PopupPositioning may reduce visibleRows on 768p or near a screen
            -- edge.  Keep the preallocated pool, but never leave rows beyond
            -- the resolved popup height visible/pickable.
            local visible = index <= rowCapacity and type(item) == "table"
            button.rsItemIndex = visible and itemIndex or nil
            button.rsDropdownSelectable = visible and item.selectable ~= false and item.kind ~= "header"
            local visibleOk, visibleErr = EnsureRawVisible(button, visible, self.owner)
            if visibleOk ~= true then return self:FailDropdownInteraction("dropdown_option_visibility_failed:" .. tostring(index) .. ":" .. tostring(visibleErr or "unknown")) end
            local enabledOk, enabledErr = self:EnsureChildEnabled(button, button.rsDropdownSelectable == true, "option_" .. tostring(index))
            if enabledOk ~= true then return false, enabledErr end
            if visible then UI:SetText(button, tostring(item.text or item.value or "--"), self.owner) end
        end

        local upVisibleOk, upVisibleErr = EnsureRawVisible(self.up, needScroll, self.owner)
        if upVisibleOk ~= true then return self:FailDropdownInteraction("dropdown_scroll_up_visibility_failed:" .. tostring(upVisibleErr or "unknown")) end
        local downVisibleOk, downVisibleErr = EnsureRawVisible(self.down, needScroll, self.owner)
        if downVisibleOk ~= true then return self:FailDropdownInteraction("dropdown_scroll_down_visibility_failed:" .. tostring(downVisibleErr or "unknown")) end
        local upOk, upErr = self:EnsureChildEnabled(self.up, needScroll and self.scrollOffset > 0, "scroll_up")
        if upOk ~= true then return false, upErr end
        local downOk, downErr = self:EnsureChildEnabled(self.down, needScroll and self.scrollOffset < MaxScrollOffset(), "scroll_down")
        if downOk ~= true then return false, downErr end
        return true, nil
    end

    function c:SetItems(items)
        local nextItems = type(items) == "table" and items or {}
        local oldTop = self.items[(tonumber(self.scrollOffset) or 0) + 1]
        local oldTopValue = type(oldTop) == "table" and oldTop.value or nil
        local oldOffset = tonumber(self.scrollOffset) or 0
        self.items = nextItems

        local anchored = DropdownFindValue(self.items, oldTopValue)
        if anchored ~= nil then self.scrollOffset = anchored - 1
        else self.scrollOffset = math.max(0, math.min(oldOffset, MaxScrollOffset())) end

        self.selectedIndex = DropdownFindValue(self.items, self.value) or 0
        self:RefreshText()
        local refreshOk, refreshErr = self:RefreshButtons()
        if refreshOk ~= true then return false, refreshErr end
        if self.open == true then
            local layoutOk, layoutErr = self:ApplyPopupLayout()
            if layoutOk ~= true then return false, layoutErr end
        end
        return true
    end

    function c:GetValue()
        return Read(self.binding, self.value)
    end

    function c:SetSelectedValue(value, silent, source)
        if self.enabled == false and source ~= "render" then return false end
        local ok = true
        if silent ~= true then ok = Write(self.binding, value, true, source or "dropdown", spec) end
        if ok ~= true then return false end
        self.value = value
        self.selectedIndex = DropdownFindValue(self.items, value) or 0
        self:RefreshText()
        if silent ~= true and type(spec.onChanged) == "function" then
            local item = self.items[self.selectedIndex]
            RSUI:Callback("rsui:" .. self.id .. ":changed", spec.onChanged, value, item, self)
        end
        return true
    end

    function c:Render()
        RSUI:_Count(self.kind, "rendered", 1)
        local value = self:GetValue()
        self:SetSelectedValue(value, true, "render")
        return value
    end

    function c:SetValue(value, notify)
        local ok = Write(self.binding, value, true, "dropdown_api", spec)
        if ok ~= true then return false end
        self.value = value
        self.selectedIndex = DropdownFindValue(self.items, value) or 0
        self:RefreshText()
        if notify ~= false and type(spec.onChanged) == "function" then
            local item = self.items[self.selectedIndex]
            RSUI:Callback("rsui:" .. self.id .. ":changed", spec.onChanged, value, item, self)
        end
        return true
    end

    function c:Scroll(delta)
        if self.enabled == false then return false end
        local nextOffset = math.max(0, math.min(MaxScrollOffset(), (tonumber(self.scrollOffset) or 0) + (tonumber(delta) or 0)))
        if nextOffset == self.scrollOffset then return false end
        self.scrollOffset = nextOffset
        return self:RefreshButtons()
    end

    function c:ApplyPopupLayout()
        local positioning = RSUI.PopupPositioning
        if type(positioning) ~= "table" or type(positioning.ResolveDropdown) ~= "function" then
            return self:FailDropdownInteraction("dropdown_popup_positioning_contract_unavailable")
        end
        local layout = self.lastLayout or { x = 0, y = 0, w = width, h = height }
        local triggerW = tonumber(layout.w) or width
        local triggerH = tonumber(layout.h) or height
        local optionH = math.max(24, triggerH)
        local resolved, resolveErr, meta = positioning:ResolveDropdown(self, {
            id = tostring(self.id or spec.id or "dropdown"),
            popupWidth = math.max(triggerW, tonumber(layout.popupWidth) or tonumber(spec.popupWidth) or triggerW),
            rowHeight = optionH,
            itemCount = #self.items,
            maxVisible = self.maxVisible,
            maxViewportHeightRatio = 0.60,
            gap = 2,
        })
        if resolved == nil then return self:FailDropdownInteraction("dropdown_popup_position_failed:" .. tostring(resolveErr or "unknown")) end

        self.visibleRows = math.max(1, math.min(self.maxVisible, math.floor(tonumber(meta and meta.visibleRows) or self.maxVisible)))
        self.scrollOffset = math.max(0, math.min(tonumber(self.scrollOffset) or 0, MaxScrollOffset()))
        local popupW, popupH = math.max(1, tonumber(resolved.width) or triggerW), math.max(optionH, tonumber(resolved.height) or optionH)
        local relativeOk, relativeErr = positioning:ApplyNativeRelativePopup(self.popup, self, self.owner, { id = tostring(self.id or spec.id or "dropdown"), width = popupW, height = popupH, triggerWidth = triggerW, triggerHeight = triggerH, gap = 2, placement = "bottom-start" }) -- 中文维护注释：Dropdown 顶层 Window 直接相对自身 Trigger 建立 Native Anchor，Shell/ScrollBox/分辨率/UI Scale 均交由 RU Anchor 系统处理。
        if relativeOk ~= true then return self:FailDropdownInteraction("dropdown_native_relative_anchor_failed:" .. tostring(relativeErr or "unknown")) end -- 中文维护注释：原生相对锚定失败必须 fail-closed，禁止再次回退到 UIParent 绝对坐标猜测路径。

        local rowCapacity = VisibleRowCapacity()
        local scrollW = #self.items > rowCapacity and 26 or 0
        for index = 1, self.maxVisible do
            local button = self.optionButtons[index]
            UI:SetExtent(button, math.max(1, popupW - scrollW), optionH, self.owner)
            UI:SetAnchor(button, self.popup, 0, (index - 1) * optionH, self.owner)
        end
        UI:SetExtent(self.up, math.max(1, scrollW), optionH, self.owner)
        UI:SetExtent(self.down, math.max(1, scrollW), optionH, self.owner)
        UI:SetAnchor(self.up, self.popup, math.max(0, popupW - scrollW), 0, self.owner)
        UI:SetAnchor(self.down, self.popup, math.max(0, popupW - scrollW), math.max(0, popupH - optionH), self.owner)
        local refreshOk, refreshErr = self:RefreshButtons()
        if refreshOk ~= true then return false, refreshErr end
        if self.open == true and type(self.popup.Raise) == "function" then pcall(function() self.popup:Raise() end) end
        return true
    end

    function c:Open()
        if self.enabled == false or self.released == true or self.rsUiDegraded == true then return false end
        if RSUI.PopupCoordinator ~= nil then RSUI.PopupCoordinator:CloseAll(self) end
        local layoutOk, layoutErr = self:ApplyPopupLayout()
        if layoutOk ~= true then return false, layoutErr end
        -- Popup hit-test quiescence contract: Close() unpicks the popup, so
        -- every Open must re-establish pickable before it can receive input.
        local repickOk, _, repickErr = UI:EnsurePickable(self.popup, true, self.owner)
        if repickOk ~= true then return self:FailDropdownInteraction("dropdown_popup_repick_failed:" .. tostring(repickErr or "unknown")) end
        local visibleOk, visibleErr = EnsureRawVisible(self.popup, true, self.owner) -- 中文维护注释：先让 Native Window 真正进入可见状态，随后 CorrectOffsetByScreen 才能基于最终窗口尺寸执行屏幕边缘修正。
        if visibleOk ~= true then return self:FailDropdownInteraction("dropdown_popup_show_failed:" .. tostring(visibleErr or "unknown")) end -- 中文维护注释：显示事务失败时立即停止，不发布 open=true，也不继续 Raise。
        local correctionOk, correctionErr = RSUI.PopupPositioning:CorrectNativePopupToScreen(self.popup, tostring(self.id or spec.id or "dropdown")) -- 中文维护注释：相对 Trigger 锚定完成后只让 RU Native 修正屏幕边缘，不再由 Lua 计算绝对 X/Y。
        if correctionOk ~= true then return self:FailDropdownInteraction("dropdown_screen_correction_failed:" .. tostring(correctionErr or "unknown")) end -- 中文维护注释：Native 修正方法存在却抛异常时 fail-closed，并保留诊断原始坐标证据。
        self.open = true -- 中文维护注释：只有 Anchor、Show、边缘修正全部成功后才提交 Presentation open Authority，避免 Lua 状态领先 Native。
        if type(self.popup.SetDrawPriority) == "function" then pcall(function() self.popup:SetDrawPriority(Token("layer.popupPriority", 10000)) end) end -- 中文维护注释：维持既有 Popup Priority 契约，坐标修复不得改变层级所有权。
        if type(self.popup.Raise) == "function" then pcall(function() self.popup:Raise() end) end
        return true
    end

    function c:Close()
        if self.open ~= true then return false end
        local visibleOk, visibleErr = EnsureRawVisible(self.popup, false, self.owner)
        if visibleOk ~= true then return self:FailDropdownInteraction("dropdown_popup_hide_failed:" .. tostring(visibleErr or "unknown")) end
        -- Hidden popups must not rely on native "hidden skips hit-test" alone:
        -- explicitly unpick so a future engine change can never leave an
        -- invisible intercepting surface behind.
        local unpickOk, _, unpickErr = UI:EnsurePickable(self.popup, false, self.owner)
        if unpickOk ~= true then return self:FailDropdownInteraction("dropdown_popup_unpick_failed:" .. tostring(unpickErr or "unknown")) end
        self.open = false
        return true
    end

    function c:ToggleOpen()
        if self.open == true then return self:Close() end
        return self:Open()
    end

    function c:Layout(x, y, nextWidth, nextHeight)
        local nextX, nextY = tonumber(x) or 0, tonumber(y) or 0
        local nextW = math.max(100, tonumber(nextWidth) or width)
        local nextH = math.max(22, tonumber(nextHeight) or height)
        self.lastLayout = { x = nextX, y = nextY, w = nextW, h = nextH, popupWidth = spec.popupWidth }
        UI:SetAnchor(self.root, spec.parent, nextX, nextY, self.owner)
        UI:SetExtent(self.root, nextW, nextH, self.owner)
        self:CommitLayoutState(nextX, nextY, nextW, nextH)
        if self.open == true then
            local popupOk, popupErr = self:ApplyPopupLayout()
            if popupOk ~= true then return false, popupErr end
        end
        RSUI:_Count(self.kind, "layouts", 1)
        return true
    end

    function c:SetEnabled(enabled)
        local desired = enabled ~= false
        if type(UI.EnsureEnabled) ~= "function" then return self.enabled ~= false, false, "enabled_transaction_unavailable" end
        local accepted, _, enableErr = UI:EnsureEnabled(self.root, desired, self.owner)
        if accepted ~= true then
            local detail = tostring(enableErr or "native_enable_rejected")
            if self.popup ~= nil then UI:SetVisible(self.popup, false, self.owner) end
            if type(self.FailClosedInteraction) == "function" then self:FailClosedInteraction("enabled_state_failed:" .. detail) end
            return self.enabled ~= false, false, detail
        end
        self.enabled = desired
        if self.enabled == false then self:Close() end
        return self.enabled, true, nil
    end

    if type(RSUI.BindStableButtonHover) == "function" then
        RSUI:BindStableButtonHover(c, trigger)
        RSUI:BindStableButtonHover(c, up)
        RSUI:BindStableButtonHover(c, down)
        for _, optionButton in ipairs(c.optionButtons) do RSUI:BindStableButtonHover(c, optionButton) end
    end

    c:RequireOn(trigger, "OnClick", function() return c:ToggleOpen() end, "rsui:" .. spec.id .. ":trigger")
    c:RequireOn(up, "OnClick", function() return c:Scroll(-1) end, "rsui:" .. spec.id .. ":up")
    c:RequireOn(down, "OnClick", function() return c:Scroll(1) end, "rsui:" .. spec.id .. ":down")
    c:On(popup, "OnWheelUp", function() return c:Scroll(-1) end, "rsui:" .. spec.id .. ":wheel_up")
    c:On(popup, "OnWheelDown", function() return c:Scroll(1) end, "rsui:" .. spec.id .. ":wheel_down")
    for index, button in ipairs(c.optionButtons) do
        -- Lua 5.1 closures capture the loop variable itself. Capture each native
        -- option button explicitly so every row keeps its own click target.
        local optionButton = button
        local optionIndex = index
        c:RequireOn(optionButton, "OnClick", function()
            local itemIndex = optionButton.rsItemIndex
            local item = itemIndex and c.items[itemIndex] or nil
            if type(item) ~= "table" or optionButton.rsDropdownSelectable ~= true then return false end
            local ok = c:SetSelectedValue(item.value, false, "dropdown")
            if ok then c:Close() end
            return ok
        end, "rsui:" .. spec.id .. ":option:" .. tostring(optionIndex))
        c:On(optionButton, "OnWheelUp", function() return c:Scroll(-1) end, "rsui:" .. spec.id .. ":option_wheel_up:" .. tostring(optionIndex))
        c:On(optionButton, "OnWheelDown", function() return c:Scroll(1) end, "rsui:" .. spec.id .. ":option_wheel_down:" .. tostring(optionIndex))
    end

    local baseRelease = c.Release
    function c:Release()
        self:Close()
        UI:SetVisible(self.popup, false, self.owner)
        if RSUI.PopupCoordinator ~= nil then RSUI.PopupCoordinator:Unregister(self) end
        return baseRelease(self)
    end

    RSUI.PopupCoordinator:Register(c)
    local itemsOk, itemsErr = c:SetItems(spec.items or spec.options or {})
    if itemsOk ~= true then return c, itemsErr end
    local _, enabledOk, enabledErr = c:SetEnabled(spec.enabled ~= false)
    if enabledOk ~= true then return c, enabledErr end
    c:Render()
    return c
end)

------------------------------------------------------------------------
-- ColorField V2 (shared color picker control)
--
-- 维护契约（2026-09-13）：
-- 1) Authority：业务只提供 get/set/defaultColor；RSUI 拥有 Draft、Popup、预览和提交事务。
-- 2) 数据流：打开时 Read authoritative -> draftColor；滑块/预设只改 draft；只有“应用”调用一次 Write；
--    “取消/外部关闭”丢弃 Draft，“恢复默认”只改 Draft，用户仍需点击应用。
-- 3) 坐标：ColorField popup 是 UIParent 顶层 Window，禁止直接跨层级 Anchor 到页面 Button。先通过
--    PopupPositioning:ResolveAnchorRect/ResolveAnchored 得到 viewport-logical 坐标，再只 Anchor 到 UIParent。
-- 4) 兼容：公开 get/set 仍使用 {r,g,b} 的 0..1 数组，避免破坏既有 Feature/存档；仅 UI 展示转换成 0..255。
-- 5) 性能：无 Tick；拖动只改本地 Draft/Drawable/Text，不触发 Persistence；Apply 最多一次业务写入。
------------------------------------------------------------------------
RSUI.ColorFieldContractVersion = 2

local COLORFIELD_POPUP_WIDTH = 300
local COLORFIELD_POPUP_HEIGHT = 270
local COLORFIELD_PRESETS = {
    { 1.00, 1.00, 1.00 }, { 0.82, 0.82, 0.82 }, { 1.00, 0.28, 0.28 },
    { 1.00, 0.62, 0.18 }, { 1.00, 0.88, 0.20 }, { 0.28, 0.86, 0.42 },
    { 0.20, 0.82, 1.00 }, { 0.32, 0.48, 1.00 }, { 0.72, 0.30, 1.00 },
}

RSUI:RegisterType("ColorField", function(spec)
    local parent = spec.parent
    local trigW = math.max(80, math.min(280, tonumber(spec.width) or 132))
    local trigH = math.max(22, math.min(40, tonumber(spec.height) or (Token("size.buttonH", 26))))
    local trigger = UI:CreateButton(parent, spec.id .. "_trigger", "", 0, 0, trigW, trigH,
        tonumber(spec.fontSize) or Token("font.small", 10), false, spec.gradient ~= false)
    if trigger == nil then return nil, "colorfield_trigger_create_failed" end
    local c = RSUI:NewComponent("ColorField", spec, trigger)
    if c == nil then return nil, "colorfield_component_create_failed" end
    local binding, bindingErr = RequireBinding(c, spec, "colorfield")
    if binding == nil then return nil, bindingErr end

    c.open = false
    c.color = { 1, 1, 1 } -- authoritative/persisted projection
    c.draftColor = { 1, 1, 1 } -- popup-local transaction draft
    c.defaultColor = type(spec.defaultColor) == "table"
        and { tonumber(spec.defaultColor[1]) or 1, tonumber(spec.defaultColor[2]) or 1, tonumber(spec.defaultColor[3]) or 1 }
        or { 1, 1, 1 }
    c.swatch = nil
    c.previewSwatch = nil
    c.previewHex = nil
    c.channelValues = {}
    c.sliders = {}
    c.label = tostring(spec.label or "颜色")

    local function Clamp01(v)
        v = tonumber(v)
        if v == nil then return 0 end
        if v < 0 then return 0 end
        if v > 1 then return 1 end
        return v
    end
    local function CopyColor(value, fallback)
        fallback = type(fallback) == "table" and fallback or { 1, 1, 1 }
        value = type(value) == "table" and value or fallback
        return { Clamp01(value[1]), Clamp01(value[2]), Clamp01(value[3]) }
    end
    local function To255(v) return math.floor(Clamp01(v) * 255 + 0.5) end

    c.defaultColor = CopyColor(c.defaultColor)

    -- Trigger swatch：只表示“已经应用”的 Authority，Draft 调整不提前污染设置列表。
    if type(trigger.CreateColorDrawable) == "function" then
        local ok, draw = pcall(function() return trigger:CreateColorDrawable(1, 1, 1, 1, "overlay") end)
        if ok and draw ~= nil then
            c.swatch = draw
            pcall(function()
                if draw.SetExtent ~= nil then draw:SetExtent(18, math.max(12, trigH - 8)) end
                if draw.AddAnchor ~= nil then draw:AddAnchor("LEFT", trigger, 6, 0) end
            end)
        end
    end

    -- 顶层 transient Window：尺寸必须由内容预算决定。旧版 140px 实际装不下 3×RGB + HEX + 按钮，
    -- 在 RU 下会出现控件互相覆盖；V2 统一使用 300×270，并在每次打开时按 resolved 尺寸显式 Layout body。
    local popup = UI:CreatePanel(UIParent, spec.id .. "_popup", 0, 0,
        COLORFIELD_POPUP_WIDTH, COLORFIELD_POPUP_HEIGHT, "soft", {
            gradient = true, owner = c.owner, transientWindow = true, visible = false, pickable = false,
            drawPriority = Token("layer.popupPriority", 10000),
        })
    if popup == nil then return nil, "colorfield_popup_create_failed" end
    c.popup = popup
    if type(UI.TrySetUILayer) == "function" then UI:TrySetUILayer(popup, "system") end
    if type(popup.SetDrawPriority) == "function" then
        pcall(function() popup:SetDrawPriority(Token("layer.popupPriority", 10000)) end)
    end

    local function FailColorBuild(reason)
        reason = tostring(reason or "colorfield_build_failed")
        UI:SetVisible(popup, false, c.owner)
        c.rsUiDegraded = true
        c.rsUiDegradedReason = reason
        return c, reason
    end
    if type(UI.EnsurePickable) ~= "function" or type(UI.EnsureEnabled) ~= "function" then
        return FailColorBuild("colorfield_popup_interaction_contract_unavailable")
    end
    local popupPickOk, _, popupPickErr = UI:EnsurePickable(popup, false, c.owner)
    local popupEnableOk, _, popupEnableErr = UI:EnsureEnabled(popup, true, c.owner)
    if popupPickOk ~= true or popupEnableOk ~= true then
        return FailColorBuild("colorfield_popup_interaction_failed:" .. tostring(popupPickErr or popupEnableErr or "unknown"))
    end
    local popupHidden, popupHideErr = EnsureRawVisible(popup, false, c.owner)
    if popupHidden ~= true then
        return FailColorBuild("colorfield_popup_initial_hide_failed:" .. tostring(popupHideErr or "unknown"))
    end

    local body = RSUI:VerticalBox({
        id = spec.id .. "_body", parent = popup, gap = 6, padding = 10,
        width = COLORFIELD_POPUP_WIDTH, height = COLORFIELD_POPUP_HEIGHT,
    })
    if body == nil then return FailColorBuild("colorfield_body_create_failed") end
    c.popupBody = body

    local title = RSUI:Text({ id = spec.id .. "_title", parent = body, text = "选择颜色", fontSize = 11,
        tone = "strong", slot = { size = "fixed", height = 22, hAlign = "fill" } })
    if title == nil then return FailColorBuild("colorfield_title_create_failed") end

    local previewRow = RSUI:HorizontalBox({ id = spec.id .. "_preview_row", parent = body, gap = 8,
        slot = { size = "fixed", height = 42, hAlign = "fill" } })
    if previewRow == nil then return FailColorBuild("colorfield_preview_row_create_failed") end
    local previewChip = RSUI:Panel({ id = spec.id .. "_preview_chip", parent = previewRow, variant = "soft",
        padding = 0, gradient = false, pickable = false, slot = { size = "fixed", width = 58, hAlign = "left" } })
    if previewChip == nil then return FailColorBuild("colorfield_preview_chip_create_failed") end
    if previewChip.root ~= nil and type(previewChip.root.CreateColorDrawable) == "function" then
        local ok, draw = pcall(function() return previewChip.root:CreateColorDrawable(1, 1, 1, 1, "overlay") end)
        if ok and draw ~= nil then
            c.previewSwatch = draw
            pcall(function()
                if draw.AddAnchor ~= nil then
                    draw:AddAnchor("TOPLEFT", previewChip.root, 3, 3)
                    draw:AddAnchor("BOTTOMRIGHT", previewChip.root, -3, -3)
                end
            end)
        end
    end
    local previewInfo = RSUI:VerticalBox({ id = spec.id .. "_preview_info", parent = previewRow, gap = 2,
        slot = { size = "fill", fill = 1, hAlign = "fill" } })
    if previewInfo == nil then return FailColorBuild("colorfield_preview_info_create_failed") end
    local currentLabel = RSUI:Text({ id = spec.id .. "_current_label", parent = previewInfo, text = "当前颜色",
        fontSize = 9, tone = "muted", slot = { size = "fixed", height = 16, hAlign = "fill" } })
    if currentLabel == nil then return FailColorBuild("colorfield_current_label_create_failed") end
    local previewHex = RSUI:Text({ id = spec.id .. "_preview_hex", parent = previewInfo, text = "#FFFFFF",
        fontSize = 11, tone = "strong", slot = { size = "fixed", height = 20, hAlign = "fill" } })
    if previewHex == nil then return FailColorBuild("colorfield_preview_hex_create_failed") end
    c.previewHex = previewHex

    local presetsRow = RSUI:HorizontalBox({ id = spec.id .. "_presets", parent = body, gap = 4,
        slot = { size = "fixed", height = 28, hAlign = "fill" } })
    if presetsRow == nil then return FailColorBuild("colorfield_presets_create_failed") end
    c.presetButtons = {}
    for index, preset in ipairs(COLORFIELD_PRESETS) do
        local presetRef = { preset[1], preset[2], preset[3] }
        local btn = RSUI:Button({ id = spec.id .. "_preset_" .. tostring(index), parent = presetsRow, text = "",
            compact = true, gradient = false,
            onClick = function()
                c:SetDraftColor(presetRef[1], presetRef[2], presetRef[3], true)
                return true
            end,
            slot = { size = "fill", fill = 1, minWidth = 20, hAlign = "fill" },
        })
        if btn == nil then return FailColorBuild("colorfield_preset_button_create_failed:" .. tostring(index)) end
        if btn.root ~= nil and type(btn.root.CreateColorDrawable) == "function" then
            local ok, draw = pcall(function()
                return btn.root:CreateColorDrawable(presetRef[1], presetRef[2], presetRef[3], 1, "overlay")
            end)
            if ok and draw ~= nil then
                pcall(function()
                    if draw.AddAnchor ~= nil then
                        draw:AddAnchor("TOPLEFT", btn.root, 3, 3)
                        draw:AddAnchor("BOTTOMRIGHT", btn.root, -3, -3)
                    end
                end)
            end
        end
        c.presetButtons[#c.presetButtons + 1] = btn
    end

    local channels = {
        { key = "r", label = "红色", idx = 1 },
        { key = "g", label = "绿色", idx = 2 },
        { key = "b", label = "蓝色", idx = 3 },
    }
    for _, ch in ipairs(channels) do
        local chRef = ch
        local row = RSUI:HorizontalBox({ id = spec.id .. "_" .. ch.key .. "_row", parent = body, gap = 6,
            slot = { size = "fixed", height = 28, hAlign = "fill" } })
        if row == nil then return FailColorBuild("colorfield_channel_row_create_failed:" .. tostring(ch.key)) end
        local channelLabel = RSUI:Text({ id = spec.id .. "_" .. ch.key .. "_label", parent = row,
            text = ch.label, fontSize = 9, tone = "muted", slot = { size = "fixed", width = 36 } })
        if channelLabel == nil then return FailColorBuild("colorfield_channel_label_create_failed:" .. tostring(ch.key)) end
        local slider = RSUI:Slider({
            id = spec.id .. "_" .. ch.key, parent = row,
            min = 0, max = 255, step = 1, integer = true,
            get = function() return To255(c.draftColor[chRef.idx]) end,
            set = function(v)
                c.draftColor[chRef.idx] = Clamp01((tonumber(v) or 0) / 255)
                c:SyncDraftPreview(false)
                return true
            end,
            onPreview = function(v)
                c.draftColor[chRef.idx] = Clamp01((tonumber(v) or 0) / 255)
                c:SyncDraftPreview(false)
                return true
            end,
            slot = { size = "fill", fill = 1, minWidth = 120, hAlign = "fill" },
        })
        if slider == nil then return FailColorBuild("colorfield_channel_slider_create_failed:" .. tostring(ch.key)) end
        c.sliders[ch.key] = slider
        local valueText = RSUI:Text({ id = spec.id .. "_" .. ch.key .. "_value", parent = row,
            text = "255", fontSize = 9, tone = "strong", align = ALIGN_RIGHT,
            slot = { size = "fixed", width = 34 } })
        if valueText == nil then return FailColorBuild("colorfield_channel_value_create_failed:" .. tostring(ch.key)) end
        c.channelValues[ch.key] = valueText
    end

    local footer = RSUI:HorizontalBox({ id = spec.id .. "_footer", parent = body, gap = 6,
        slot = { size = "fixed", height = 28, hAlign = "fill" } })
    if footer == nil then return FailColorBuild("colorfield_footer_create_failed") end
    local defaultBtn = RSUI:Button({ id = spec.id .. "_default", parent = footer, text = "恢复默认", compact = true,
        onClick = function() return c:RestoreDefaultDraft() end,
        slot = { size = "fixed", width = 84 } })
    if defaultBtn == nil then return FailColorBuild("colorfield_default_button_create_failed") end
    local spacer = RSUI:Text({ id = spec.id .. "_footer_spacer", parent = footer, text = "", fontSize = 8,
        slot = { size = "fill", fill = 1, hAlign = "fill" } })
    if spacer == nil then return FailColorBuild("colorfield_footer_spacer_create_failed") end
    local cancelBtn = RSUI:Button({ id = spec.id .. "_cancel", parent = footer, text = "取消", compact = true,
        onClick = function() return c:CancelDraft() end,
        slot = { size = "fixed", width = 62 } })
    if cancelBtn == nil then return FailColorBuild("colorfield_cancel_button_create_failed") end
    local applyBtn = RSUI:Button({ id = spec.id .. "_apply", parent = footer, text = "应用", compact = true,
        onClick = function() return c:ApplyDraft() end,
        slot = { size = "fixed", width = 62 } })
    if applyBtn == nil then return FailColorBuild("colorfield_apply_button_create_failed") end

    function c:HexOf(color)
        color = CopyColor(color, self.color)
        local function hx(x) return string.format("%02X", To255(x)) end
        return "#" .. hx(color[1]) .. hx(color[2]) .. hx(color[3])
    end
    function c:Hex() return self:HexOf(self.color) end
    function c:ParseHex(s)
        s = tostring(s or ""):gsub("#", ""):gsub("%s+", "")
        if #s ~= 6 then return nil end
        local r, g, b = tonumber(s:sub(1, 2), 16), tonumber(s:sub(3, 4), 16), tonumber(s:sub(5, 6), 16)
        if r == nil or g == nil or b == nil then return nil end
        return { r / 255, g / 255, b / 255 }
    end
    function c:SyncTrigger()
        if self.swatch ~= nil then UI:SetColor(self.swatch, self.color[1], self.color[2], self.color[3], 1, self.owner) end
        UI:SetText(self.root, self.label .. "  " .. self:Hex(), self.owner)
        return true
    end
    function c:SyncDraftPreview(syncSliders)
        local draft = CopyColor(self.draftColor, self.color)
        self.draftColor = draft
        if self.previewSwatch ~= nil then UI:SetColor(self.previewSwatch, draft[1], draft[2], draft[3], 1, self.owner) end
        if self.previewHex ~= nil then self.previewHex:SetText(self:HexOf(draft)) end
        local values = { r = To255(draft[1]), g = To255(draft[2]), b = To255(draft[3]) }
        for key, value in pairs(values) do
            if self.channelValues[key] ~= nil then self.channelValues[key]:SetText(tostring(value)) end
            if syncSliders == true and self.sliders[key] ~= nil then self.sliders[key]:Render(value, "colorfield_draft_sync") end
        end
        return true
    end
    function c:SetDraftColor(r, g, b, syncSliders)
        self.draftColor = { Clamp01(r), Clamp01(g), Clamp01(b) }
        return self:SyncDraftPreview(syncSliders ~= false)
    end
    function c:BeginDraft()
        self.draftColor = CopyColor(self.color)
        return self:SyncDraftPreview(true)
    end
    function c:RestoreDefaultDraft()
        return self:SetDraftColor(self.defaultColor[1], self.defaultColor[2], self.defaultColor[3], true)
    end
    function c:CancelDraft()
        self.draftColor = CopyColor(self.color)
        self:SyncDraftPreview(true)
        if self.open == true then return self:Close() end
        return true
    end
    function c:ApplyDraft()
        if self.enabled == false then return false end
        local nextColor = CopyColor(self.draftColor, self.color)
        local ok = Write(self.binding, nextColor, true, "colorfield_apply", spec)
        if ok ~= true then
            local authoritative = Read(self.binding, self.color)
            if type(authoritative) == "table" then self.color = CopyColor(authoritative, self.color) end
            self:SyncTrigger()
            self:BeginDraft()
            return false
        end
        self.color = CopyColor(nextColor)
        self.value = CopyColor(nextColor)
        self:SyncTrigger()
        if type(spec.onChanged) == "function" then
            RSUI:Callback("rsui:" .. self.id .. ":changed", spec.onChanged, CopyColor(nextColor), self)
        end
        if self.open == true then self:Close() end
        return true
    end
    function c:Commit() return self:ApplyDraft() end -- 中文维护注释：兼容旧调用名，但 V2 只允许用户显式“应用”进入该事务。
    function c:GetValue() return Read(self.binding, self.value) end
    function c:SetValue(color, notify)
        if self.enabled == false or type(color) ~= "table" then return false end
        local nextColor = CopyColor(color, self.color)
        local ok = Write(self.binding, nextColor, true, "colorfield_api", spec)
        if ok == true then
            self.color, self.value = CopyColor(nextColor), CopyColor(nextColor)
            self:SyncTrigger()
            if self.open ~= true then self:BeginDraft() end
            if notify ~= false and type(spec.onChanged) == "function" then
                RSUI:Callback("rsui:" .. self.id .. ":changed", spec.onChanged, CopyColor(nextColor), self)
            end
            return true
        end
        local authoritative = Read(self.binding, self.value)
        if type(authoritative) == "table" then self.color = CopyColor(authoritative, self.color) end
        self:SyncTrigger()
        if self.open ~= true then self:BeginDraft() end
        return false
    end
    function c:Render()
        local v = self:GetValue()
        if type(v) == "table" then
            self.color = CopyColor(v, self.color)
            self.value = CopyColor(self.color)
            self:SyncTrigger()
            if self.open ~= true then self:BeginDraft() end
        end
        return v
    end

    function c:ApplyPopupLayout()
        local positioning = RSUI.PopupPositioning
        if type(positioning) ~= "table" or type(positioning.ResolveAnchorRect) ~= "function"
            or type(positioning.ResolveAnchored) ~= "function"
            or type(positioning.ApplyResolvedViewportPopup) ~= "function" then
            return false, "colorfield_popup_positioning_contract_unavailable"
        end
        local anchor, anchorErr = positioning:ResolveAnchorRect(self)
        if anchor == nil then return false, "colorfield_anchor_unavailable:" .. tostring(anchorErr or "unknown") end
        local resolved, resolveErr = positioning:ResolveAnchored(anchor, COLORFIELD_POPUP_WIDTH, COLORFIELD_POPUP_HEIGHT, {
            id = tostring(self.id or spec.id or "colorfield"), gap = 4, preferred = "bottom-start",
        })
        if resolved == nil then return false, "colorfield_popup_position_failed:" .. tostring(resolveErr or "unknown") end
        -- 中文维护注释：body 是 Popup 的 Native child，不属于页面 Layout Tree；旧版从未显式 Layout 它，导致 1×1 Host 内的子控件互相覆盖。每次打开按最终 resolved 尺寸显式排版一次。
        if self.popupBody ~= nil and type(self.popupBody.Layout) == "function" then
            self.popupBody:Layout(0, 0, resolved.width, resolved.height)
        end
        local positionOk, positionErr = positioning:ApplyResolvedViewportPopup(self.popup, anchor, resolved, self.owner, {
            id = tostring(self.id or spec.id or "colorfield"),
        })
        if positionOk ~= true then
            return false, "colorfield_viewport_anchor_failed:" .. tostring(positionErr or "unknown")
        end
        if type(self.popup.Raise) == "function" then pcall(function() self.popup:Raise() end) end
        return true
    end

    function c:Open()
        if self.enabled == false or self.released == true or self.rsUiDegraded == true then return false end
        if RSUI.PopupCoordinator ~= nil then RSUI.PopupCoordinator:CloseAll(self) end
        self:Render() -- 中文维护注释：打开前重新读取 Authority，避免其他页面已改色而本 Popup 仍显示旧值。
        self:BeginDraft()
        local layoutOk, layoutErr = self:ApplyPopupLayout()
        if layoutOk ~= true then return false, layoutErr end
        local repickOk, _, repickErr = UI:EnsurePickable(self.popup, true, self.owner)
        if repickOk ~= true then
            if type(self.FailClosedInteraction) == "function" then
                self:FailClosedInteraction("colorfield_popup_repick_failed:" .. tostring(repickErr or "unknown"))
            end
            return false, repickErr
        end
        local visibleOk, visibleErr = EnsureRawVisible(self.popup, true, self.owner)
        if visibleOk ~= true then
            if type(self.FailClosedInteraction) == "function" then
                self:FailClosedInteraction("colorfield_popup_show_failed:" .. tostring(visibleErr or "unknown"))
            end
            return false, visibleErr
        end
        local correctionOk, correctionErr = RSUI.PopupPositioning:CorrectNativePopupToScreen(self.popup,
            tostring(self.id or spec.id or "colorfield"))
        if correctionOk ~= true then
            return false, "colorfield_screen_correction_failed:" .. tostring(correctionErr or "unknown")
        end
        self.open = true
        if type(self.popup.SetDrawPriority) == "function" then
            pcall(function() self.popup:SetDrawPriority(Token("layer.popupPriority", 10000)) end)
        end
        if type(self.popup.Raise) == "function" then pcall(function() self.popup:Raise() end) end
        return true
    end
    function c:Close()
        if self.open ~= true then
            self.draftColor = CopyColor(self.color)
            self:SyncDraftPreview(true)
            return false
        end
        local visibleOk, visibleErr = EnsureRawVisible(self.popup, false, self.owner)
        if visibleOk ~= true then
            if type(self.FailClosedInteraction) == "function" then
                self:FailClosedInteraction("colorfield_popup_hide_failed:" .. tostring(visibleErr or "unknown"))
            end
            return false, visibleErr
        end
        local unpickOk, _, unpickErr = UI:EnsurePickable(self.popup, false, self.owner)
        if unpickOk ~= true then
            if type(self.FailClosedInteraction) == "function" then
                self:FailClosedInteraction("colorfield_popup_unpick_failed:" .. tostring(unpickErr or "unknown"))
            end
            return false, unpickErr
        end
        self.open = false
        -- 中文维护注释：任何非 Apply 关闭都以 Authoritative 为准重置 Draft，保证点击外部/再次点 Trigger/页面销毁都不会偷写配置。
        self.draftColor = CopyColor(self.color)
        self:SyncDraftPreview(true)
        return true
    end
    function c:ToggleOpen()
        if self.open == true then return self:Close() end
        return self:Open()
    end
    function c:SetEnabled(enabled)
        local desired = enabled ~= false
        if type(UI.EnsureEnabled) ~= "function" then return self.enabled ~= false, false, "enabled_transaction_unavailable" end
        local accepted, _, enableErr = UI:EnsureEnabled(self.root, desired, self.owner)
        if accepted ~= true then
            local detail = tostring(enableErr or "native_enable_rejected")
            if self.popup ~= nil then UI:SetVisible(self.popup, false, self.owner) end
            if type(self.FailClosedInteraction) == "function" then self:FailClosedInteraction("enabled_state_failed:" .. detail) end
            return self.enabled ~= false, false, detail
        end
        self.enabled = desired
        if self.enabled == false then self:Close() end
        return self.enabled, true, nil
    end

    if type(RSUI.BindStableButtonHover) == "function" then RSUI:BindStableButtonHover(c, trigger) end

    local baseRelease = c.Release
    function c:Release()
        self:Close()
        UI:SetVisible(self.popup, false, self.owner)
        if RSUI.PopupCoordinator ~= nil then RSUI.PopupCoordinator:Unregister(self) end
        return baseRelease(self)
    end

    c:RequireOn(trigger, "OnClick", function() return c:ToggleOpen() end, "rsui:" .. spec.id .. ":trigger")
    if RSUI.PopupCoordinator ~= nil then RSUI.PopupCoordinator:Register(c) end

    c:SetEnabled(spec.enabled ~= false)
    -- 中文维护注释：Popup body 不属于页面布局树，首次构建后立即显式 Layout，保证隐藏态也有正确子控件几何；打开时仍会按 resolved 尺寸再次 Layout。
    if type(body.Layout) == "function" then body:Layout(0, 0, COLORFIELD_POPUP_WIDTH, COLORFIELD_POPUP_HEIGHT) end
    c:Render()
    return c
end)

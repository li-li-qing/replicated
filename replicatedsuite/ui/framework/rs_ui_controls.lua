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
    value = RoundStep(value, spec.min, spec.step)
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
RSUI.InteractiveDraftContractVersion = 1
RSUI.ControlTransactionContractVersion = 1
RSUI.PopupVisibilityTransactionContractVersion = 1

local function EnsureRawVisible(widget, visible, owner)
    if widget == nil then return false, "popup_widget_required" end
    if type(UI.EnsureVisible) ~= "function" then return false, "visibility_transaction_unavailable" end
    local accepted, _, detail = UI:EnsureVisible(widget, visible == true, owner)
    if accepted ~= true then return false, tostring(detail or "native_visibility_rejected") end
    return true, nil
end

local function IsFocusedDraft(component)
    local focus = RSUI.Focus
    if component == nil or component.root == nil or type(focus) ~= "table" or type(focus.IsFocused) ~= "function" then return false end
    local ok, focused = pcall(function() return focus:IsFocused(component.root) end)
    return ok == true and focused == true
end

local function IsAmbientRenderSource(source)
    source = tostring(source or "binding_refresh")
    return source == "binding_refresh" or source == "field_sync" or source == "ambient_refresh"
        or source == "external_refresh" or source == "refresh"
end

local function CountDraftSuppression()
    RSUI.metrics.interactiveDraftRenderSuppressions = (tonumber(RSUI.metrics.interactiveDraftRenderSuppressions) or 0) + 1
end

RSUI:RegisterType("Toggle", function(spec)
    local width = math.max(56, tonumber(spec.width) or 92)
    local height = math.max(22, tonumber(spec.height) or Token("size.buttonH", 26))
    local button = UI:CreateButton(spec.parent, spec.id, "", tonumber(spec.x) or 0, tonumber(spec.y) or 0, width, height,
        tonumber(spec.fontSize) or Token("font.small", 10), false, spec.gradient ~= false)
    if button == nil then return nil, "toggle_create_failed" end
    local c = RSUI:NewComponent("Toggle", spec, button)
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
    c.value = tostring(spec.value or "")
    local function Normalize(value)
        local text = tostring(value or "")
        if spec.trim ~= false then text = text:match("^%s*(.-)%s*$") or "" end
        return text
    end
    function c:GetValue() return Normalize(Read(self.binding, self.value)) end
    -- EditBox text is a draft until Submit(). Button-driven forms must be able
    -- to read/commit what the user has typed even when the field has not lost
    -- focus yet; GetValue() intentionally remains the committed binding value.
    function c:GetDraftValue()
        if self.root ~= nil and type(self.root.GetText) == "function" then return Normalize(self.root:GetText()) end
        return Normalize(self.value)
    end
    function c:IsEditing() return IsFocusedDraft(self) end
    function c:Render(explicitValue, source)
        RSUI:_Count(self.kind, "rendered", 1)
        local value = Normalize(explicitValue ~= nil and explicitValue or self:GetValue())
        if self:IsEditing() and IsAmbientRenderSource(source) then
            CountDraftSuppression()
            return self:GetDraftValue()
        end
        if explicitValue == nil then self.value = value end
        UI:SetText(self.root, value, self.owner)
        return value
    end
    function c:SetValue(value, notify, source)
        if self.enabled == false then return false end
        value = Normalize(value)
        local ok = Write(self.binding, value, true, source or "text_input_api", spec)
        if ok then
            self.value = value
            self:Render(value, "commit")
        else
            -- Force the committed/bound value back even if the native edit box
            -- is still focused.  Rejection is an explicit transaction result,
            -- not an ambient refresh that should preserve the draft.
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
            self:Render()
            if type(spec.onInvalid) == "function" then RSUI:Callback("rsui:" .. self.id .. ":invalid", spec.onInvalid, value, self) end
            return false
        end
        local ok = self:SetValue(value, true, source or "edit")
        if ok and type(spec.onSubmit) == "function" then
            local callbackOk, result = RSUI:Callback("rsui:" .. self.id .. ":submit", spec.onSubmit, value, self)
            if callbackOk == false or result == false then return false end
        end
        return ok
    end
    for _, eventName in ipairs({ "OnEnterPressed", "OnEditEnter" }) do
        c:On(edit, eventName, function() return c:Submit("enter") end, "rsui:" .. spec.id .. ":" .. eventName)
    end
    if spec.submitOnLostFocus ~= false then
        c:On(edit, "OnLostFocus", function() return c:Submit("blur") end, "rsui:" .. spec.id .. ":OnLostFocus")
    end
    c:SetEnabled(spec.enabled ~= false)
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
    c.value = NormalizeNumber(spec, spec.value)
    function c:GetValue() return NormalizeNumber(spec, Read(self.binding, self.value)) end
    function c:GetDraftValue()
        if self.root ~= nil and type(self.root.GetText) == "function" then return tostring(self.root:GetText() or "") end
        return ""
    end
    function c:IsEditing() return IsFocusedDraft(self) end
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
        if self:IsEditing() and IsAmbientRenderSource(source) then
            CountDraftSuppression()
            return value
        end
        if explicitValue == nil then self.value = value end
        UI:SetText(self.root, self:Format(value), self.owner)
        return value
    end
    function c:Submit(source)
        if self.enabled == false then return false end
        local text = type(self.root.GetText) == "function" and tostring(self.root:GetText() or "") or ""
        local suffix = tostring(spec.suffix or spec.unit or "")
        if suffix ~= "" and #text >= #suffix and text:sub(-#suffix) == suffix then text = text:sub(1, #text - #suffix) end
        local value = NormalizeNumber(spec, text)
        if value == nil then
            if type(spec.onInvalid) == "function" then RSUI:Callback("rsui:" .. self.id .. ":invalid", spec.onInvalid, text, self) end
            self:Render()
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
    for _, eventName in ipairs({ "OnEnterPressed", "OnEditEnter", "OnLostFocus" }) do
        c:On(edit, eventName, function() return c:Submit("edit") end, "rsui:" .. spec.id .. ":" .. eventName)
    end
    c:SetEnabled(spec.enabled ~= false)
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
    function c:Render(explicit, source)
        RSUI:_Count(self.kind, "rendered", 1)
        if self:IsInteracting() and IsAmbientRenderSource(source) then
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

RSUI.DropdownContractVersion = 2
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
    local popupPickOk, _, popupPickErr = UI:EnsurePickable(popup, true, c.owner)
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

    local function MaxScrollOffset()
        return math.max(0, #c.items - c.maxVisible)
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
        local needScroll = count > self.maxVisible
        self.scrollOffset = math.max(0, math.min(tonumber(self.scrollOffset) or 0, MaxScrollOffset()))

        for index = 1, self.maxVisible do
            local button = self.optionButtons[index]
            local itemIndex = self.scrollOffset + index
            local item = self.items[itemIndex]
            local visible = type(item) == "table"
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
        local layout = self.lastLayout or { x = 0, y = 0, w = width, h = height }
        local triggerX, triggerY, triggerW, triggerH = tonumber(layout.x) or 0, tonumber(layout.y) or 0, tonumber(layout.w) or width, tonumber(layout.h) or height
        if S.Layout ~= nil and type(S.Layout.GetLogicalRect) == "function" then
            local ok, x, y, w, h = pcall(function() return S.Layout:GetLogicalRect(self.root) end)
            if ok then
                triggerX = tonumber(x) or triggerX
                triggerY = tonumber(y) or triggerY
                triggerW = tonumber(w) or triggerW
                triggerH = tonumber(h) or triggerH
            end
        end

        local context = S.Layout ~= nil and type(S.Layout.GetContext) == "function" and S.Layout:GetContext() or nil
        local logicalW = context and tonumber(context.logicalWidth) or 1024
        local logicalH = context and tonumber(context.logicalHeight) or 768
        local safeLeft = context and tonumber(context.safeLeft) or 4
        local safeRight = context and tonumber(context.safeRight) or 4
        local safeTop = context and tonumber(context.safeTop) or 4
        local safeBottom = context and tonumber(context.safeBottom) or 4
        local desiredW = math.max(triggerW, tonumber(layout.popupWidth) or tonumber(spec.popupWidth) or triggerW)
        local popupW = math.max(100, math.min(desiredW, math.max(100, logicalW - safeLeft - safeRight)))
        local optionH = math.max(24, triggerH)
        local visibleRows = math.max(1, math.min(self.maxVisible, #self.items))
        local popupH = visibleRows * optionH
        local x = math.max(safeLeft, math.min(triggerX, math.max(safeLeft, logicalW - safeRight - popupW)))
        local belowY = triggerY + triggerH + 2
        local aboveY = triggerY - popupH - 2
        local y = belowY
        if belowY + popupH > logicalH - safeBottom and aboveY >= safeTop then y = aboveY end
        y = math.max(safeTop, math.min(y, math.max(safeTop, logicalH - safeBottom - popupH)))

        UI:SetExtent(self.popup, popupW, popupH, self.owner)
        UI:SetAnchor(self.popup, UIParent, x, y, self.owner)
        local scrollW = #self.items > self.maxVisible and 26 or 0
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
        local visibleOk, visibleErr = EnsureRawVisible(self.popup, true, self.owner)
        if visibleOk ~= true then return self:FailDropdownInteraction("dropdown_popup_show_failed:" .. tostring(visibleErr or "unknown")) end
        self.open = true
        if type(self.popup.SetDrawPriority) == "function" then pcall(function() self.popup:SetDrawPriority(Token("layer.popupPriority", 10000)) end) end
        if type(self.popup.Raise) == "function" then pcall(function() self.popup:Raise() end) end
        return true
    end

    function c:Close()
        if self.open ~= true then return false end
        local visibleOk, visibleErr = EnsureRawVisible(self.popup, false, self.owner)
        if visibleOk ~= true then return self:FailDropdownInteraction("dropdown_popup_hide_failed:" .. tostring(visibleErr or "unknown")) end
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
-- ColorField (color picker control)
--
-- A compact color control: a clickable swatch (live color preview) + a hex
-- input, with a popover holding R/G/B sliders. get/set carry {r,g,b} in 0..1.
-- This is the missing "line color setting" foundation: unit-lines used to cram
-- three separate R/G/B CompactNumericSetting sliders into one row (the clutter
-- the user flagged), and range-assist had no color control at all. One
-- ColorField replaces the three sliders and adds the missing control.
------------------------------------------------------------------------
RSUI:RegisterType("ColorField", function(spec)
    local parent = spec.parent
    local trigW = math.max(60, math.min(280, tonumber(spec.width) or 132))
    local trigH = math.max(22, math.min(40, tonumber(spec.height) or (Token("size.buttonH", 26))))
    local trigger, triggerErr = UI:CreateButton(parent, spec.id .. "_trigger", "", 0, 0, trigW, trigH, tonumber(spec.fontSize) or Token("font.small", 10), false, spec.gradient ~= false)
    if trigger == nil then return nil, "colorfield_trigger_create_failed" end
    local c = RSUI:NewComponent("ColorField", spec, trigger)
    if c == nil then return nil, "colorfield_component_create_failed" end
    local binding, bindingErr = RequireBinding(c, spec, "colorfield")
    if binding == nil then return nil, bindingErr end
    c.open = false
    c.color = { 1, 1, 1 }
    c.swatch = nil
    c.label = tostring(spec.label or "颜色")

    -- Swatch drawable fills the trigger so the current color is always visible.
    -- Some RU widgets expose CreateColorDrawable; fall back to a flat background
    -- tint so the control still reads as a color chip when the drawable API is
    -- unavailable on this client.
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

    -- Popover: top-level surface so it is never clipped by a ScrollBox/card.
    local popup, popupErr = UI:CreatePanel(UIParent, spec.id .. "_popup", 0, 0, trigW, 140, "soft", { gradient = true, owner = c.owner })
    if popup == nil then return nil, "colorfield_popup_create_failed" end
    c.popup = popup
    if type(UI.TrySetUILayer) == "function" then UI:TrySetUILayer(popup, "system") end
    if type(popup.SetDrawPriority) == "function" then pcall(function() popup:SetDrawPriority(Token("layer.popupPriority", 10000)) end) end
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
    local popupPickOk, _, popupPickErr = UI:EnsurePickable(popup, true, c.owner)
    local popupEnableOk, _, popupEnableErr = UI:EnsureEnabled(popup, true, c.owner)
    if popupPickOk ~= true or popupEnableOk ~= true then
        return FailColorBuild("colorfield_popup_interaction_failed:" .. tostring(popupPickErr or popupEnableErr or "unknown"))
    end
    local popupHidden, popupHideErr = EnsureRawVisible(popup, false, c.owner)
    if popupHidden ~= true then return FailColorBuild("colorfield_popup_initial_hide_failed:" .. tostring(popupHideErr or "unknown")) end

    local body = RSUI:VerticalBox({ id = spec.id .. "_body", parent = popup, gap = 5, padding = 7 })
    if body == nil then return FailColorBuild("colorfield_body_create_failed") end
    c.sliders = {}
    -- Declared BEFORE the slider loop on purpose: the per-channel set closure
    -- (below) references Clamp01. In Lua a closure defined before a `local
    -- function' declaration binds that name to a global, not the later local,
    -- so moving the declaration up keeps the closure capturing the real helper.
    local function Clamp01(v) v = tonumber(v); if v == nil then return 0 end; if v < 0 then v = 0 end; if v > 1 then v = 1 end; return v end
    local channels = { { key = "r", label = "R", idx = 1 }, { key = "g", label = "G", idx = 2 }, { key = "b", label = "B", idx = 3 } }
    for _, ch in ipairs(channels) do
        local row = RSUI:HorizontalBox({ id = spec.id .. "_" .. ch.key .. "_row", parent = body, gap = 4, slot = { size = "fixed", height = 24, hAlign = "fill" } })
        if row == nil then return FailColorBuild("colorfield_channel_row_create_failed:" .. tostring(ch.key)) end
        local channelLabel = RSUI:Text({ id = spec.id .. "_" .. ch.key .. "_label", parent = row, text = ch.label, fontSize = 9, tone = "muted", slot = { size = "fixed", width = 12 } })
        if channelLabel == nil then return FailColorBuild("colorfield_channel_label_create_failed:" .. tostring(ch.key)) end
        -- Each Slider owns its channel via get/set closures over the shared color.
        -- Slider (not NumericField) is used so ApplyColor can re-sync the slider
        -- view from c.color via :Render() without re-committing through the
        -- binding (NumericField has no SetValue; its Apply() would double-write).
        local slider = RSUI:Slider({
            id = spec.id .. "_" .. ch.key, parent = row, min = 0, max = 1, step = 0.02, integer = false,
            get = function() return c.color[ch.idx] end,
            set = function(v) c.color[ch.idx] = Clamp01(v); c:SyncSwatchAndHex(); return c:Commit() end,
            slot = { size = "fill", fill = 1, hAlign = "fill" },
        })
        if slider == nil then return FailColorBuild("colorfield_channel_slider_create_failed:" .. tostring(ch.key)) end
        c.sliders[ch.key] = slider
    end
    local hexRow = RSUI:HorizontalBox({ id = spec.id .. "_hex_row", parent = body, gap = 4, slot = { size = "fixed", height = 24, hAlign = "fill" } })
    if hexRow == nil then return FailColorBuild("colorfield_hex_row_create_failed") end
    local hexLabel = RSUI:Text({ id = spec.id .. "_hex_label", parent = hexRow, text = "#", fontSize = 9, tone = "muted", slot = { size = "fixed", width = 12 } })
    if hexLabel == nil then return FailColorBuild("colorfield_hex_label_create_failed") end
    -- TextInput commits via onSubmit (it exposes no OnCommitted method); the
    -- guard is dropped because onSubmit is always a safe no-op when absent.
    local hexInput = RSUI:TextInput({ id = spec.id .. "_hex", parent = hexRow, maxLength = 7, height = 20,
        onSubmit = function(text)
            local parsed = c:ParseHex(text)
            if parsed == nil then return false end
            c:ApplyColor(parsed[1], parsed[2], parsed[3])
            return c:Commit()
        end,
        slot = { size = "fill", fill = 1, hAlign = "fill" } })
    if hexInput == nil then return FailColorBuild("colorfield_hex_input_create_failed") end
    c.hexInput = hexInput
    local doneBtn = RSUI:Button({ id = spec.id .. "_done", parent = body, text = "完成", compact = true, slot = { size = "fixed", height = 24, hAlign = "fill" } })
    if doneBtn == nil then return FailColorBuild("colorfield_done_button_create_failed") end

    function c:SyncSwatchAndHex()
        if self.swatch ~= nil then UI:SetColor(self.swatch, self.color[1], self.color[2], self.color[3], 1, self.owner) end
        local hex = self:Hex()
        -- Always keep a textual affordance on the trigger. Some RU widget
        -- builds do not expose CreateColorDrawable; an empty button made the
        -- color setting look nonexistent even though the popup binding worked.
        UI:SetText(self.root, self.label .. "  " .. hex, self.owner)
        if self.hexInput ~= nil then self.hexInput:SetValue(hex) end
    end
    function c:Hex()
        local function hx(x) local v = math.floor(Clamp01(x) * 255 + 0.5); return string.format("%02X", v) end
        return "#" .. hx(self.color[1]) .. hx(self.color[2]) .. hx(self.color[3])
    end
    function c:ParseHex(s)
        s = tostring(s or ""):gsub("#", ""):gsub("%s+", "")
        if #s ~= 6 then return nil end
        local r, g, b = tonumber(s:sub(1, 2), 16), tonumber(s:sub(3, 4), 16), tonumber(s:sub(5, 6), 16)
        if r == nil or g == nil or b == nil then return nil end
        return { r / 255, g / 255, b / 255 }
    end
    function c:ApplyColor(r, g, b)
        self.color = { Clamp01(r), Clamp01(g), Clamp01(b) }
        self:SyncSwatchAndHex()
        -- Re-sync the channel sliders from the shared color via :Render(); this
        -- reads the binding (spec.get -> c.color) and never re-commits it.
        if self.sliders.r ~= nil then self.sliders.r:Render() end
        if self.sliders.g ~= nil then self.sliders.g:Render() end
        if self.sliders.b ~= nil then self.sliders.b:Render() end
    end
    function c:Commit()
        local nextColor = { self.color[1], self.color[2], self.color[3] }
        local ok = Write(self.binding, nextColor, true, "colorfield", spec)
        if ok == true then
            self.value = { nextColor[1], nextColor[2], nextColor[3] }
            if type(spec.onChanged) == "function" then RSUI:Callback("rsui:" .. self.id .. ":changed", spec.onChanged, nextColor, self) end
            return true
        end
        -- Slider/hex previews mutate the local color before Commit().  If the
        -- binding/persistence transaction rejects the write, roll the entire
        -- visual composite back to the authoritative value immediately.
        local authoritative = Read(self.binding, self.value)
        if type(authoritative) == "table" then self:ApplyColor(authoritative[1], authoritative[2], authoritative[3]) end
        return false
    end
    function c:GetValue() return Read(self.binding, self.value) end
    function c:SetValue(color, notify)
        if self.enabled == false then return false end
        if type(color) ~= "table" then return false end
        local nextColor = { Clamp01(color[1]), Clamp01(color[2]), Clamp01(color[3]) }
        local ok = Write(self.binding, nextColor, true, "colorfield_api", spec)
        if ok == true then
            self.value = { nextColor[1], nextColor[2], nextColor[3] }
            self:ApplyColor(nextColor[1], nextColor[2], nextColor[3])
            if notify ~= false and type(spec.onChanged) == "function" then RSUI:Callback("rsui:" .. self.id .. ":changed", spec.onChanged, nextColor, self) end
            return true
        end
        local authoritative = Read(self.binding, self.value)
        if type(authoritative) == "table" then self:ApplyColor(authoritative[1], authoritative[2], authoritative[3]) end
        return false
    end
    function c:Render()
        local v = self:GetValue()
        if type(v) == "table" then self:ApplyColor(v[1], v[2], v[3]) end
        return v
    end

    function c:ApplyPopupLayout()
        local px, py, pw, ph = 0, 0, trigW, trigH
        if S.Layout ~= nil and type(S.Layout.GetLogicalRect) == "function" then
            local ok, x, y, w, h = pcall(function() return S.Layout:GetLogicalRect(self.root) end)
            if ok then px, py, pw, ph = tonumber(x) or 0, tonumber(y) or 0, tonumber(w) or trigW, tonumber(h) or trigH end
        end
        local context = S.Layout ~= nil and type(S.Layout.GetContext) == "function" and S.Layout:GetContext() or nil
        local logicalW = context and tonumber(context.logicalWidth) or 1024
        local logicalH = context and tonumber(context.logicalHeight) or 768
        local safeLeft = context and tonumber(context.safeLeft) or 4
        local safeRight = context and tonumber(context.safeRight) or 4
        local safeTop = context and tonumber(context.safeTop) or 4
        local safeBottom = context and tonumber(context.safeBottom) or 4
        local popupW = math.max(120, math.min(trigW, math.max(120, logicalW - safeLeft - safeRight)))
        local popupH = 140
        local x = math.max(safeLeft, math.min(px, math.max(safeLeft, logicalW - safeRight - popupW)))
        local belowY = py + ph + 2
        local aboveY = py - popupH - 2
        local y = belowY
        if belowY + popupH > logicalH - safeBottom and aboveY >= safeTop then y = aboveY end
        y = math.max(safeTop, math.min(y, math.max(safeTop, logicalH - safeBottom - popupH)))
        UI:SetExtent(self.popup, popupW, popupH, self.owner)
        UI:SetAnchor(self.popup, UIParent, x, y, self.owner)
        if type(self.popup.Raise) == "function" then pcall(function() self.popup:Raise() end) end
        return true
    end
    function c:Open()
        if self.enabled == false or self.released == true or self.rsUiDegraded == true then return false end
        if RSUI.PopupCoordinator ~= nil then RSUI.PopupCoordinator:CloseAll(self) end
        local layoutOk, layoutErr = self:ApplyPopupLayout()
        if layoutOk ~= true then return false, layoutErr end
        local visibleOk, visibleErr = EnsureRawVisible(self.popup, true, self.owner)
        if visibleOk ~= true then
            if type(self.FailClosedInteraction) == "function" then self:FailClosedInteraction("colorfield_popup_show_failed:" .. tostring(visibleErr or "unknown")) end
            return false, visibleErr
        end
        self.open = true
        if type(self.popup.SetDrawPriority) == "function" then pcall(function() self.popup:SetDrawPriority(Token("layer.popupPriority", 10000)) end) end
        if type(self.popup.Raise) == "function" then pcall(function() self.popup:Raise() end) end
        return true
    end
    function c:Close()
        if self.open ~= true then return false end
        local visibleOk, visibleErr = EnsureRawVisible(self.popup, false, self.owner)
        if visibleOk ~= true then
            if type(self.FailClosedInteraction) == "function" then self:FailClosedInteraction("colorfield_popup_hide_failed:" .. tostring(visibleErr or "unknown")) end
            return false, visibleErr
        end
        self.open = false
        return true
    end
    function c:ToggleOpen() if self.open == true then return self:Close() end; return self:Open() end
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

    local baseRelease = c.Release
    function c:Release()
        self:Close()
        UI:SetVisible(self.popup, false, self.owner)
        if RSUI.PopupCoordinator ~= nil then RSUI.PopupCoordinator:Unregister(self) end
        return baseRelease(self)
    end

    c:RequireOn(trigger, "OnClick", function() return c:ToggleOpen() end, "rsui:" .. spec.id .. ":trigger")
    c:RequireOn(doneBtn, "OnClick", function() return c:Close() end, "rsui:" .. spec.id .. ":done")
    if RSUI.PopupCoordinator ~= nil then RSUI.PopupCoordinator:Register(c) end

    c:SetEnabled(spec.enabled ~= false)
    c:Render()
    return c
end)

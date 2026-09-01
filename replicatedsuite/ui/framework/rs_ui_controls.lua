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

RSUI:RegisterType("Toggle", function(spec)
    local width = math.max(56, tonumber(spec.width) or 92)
    local height = math.max(22, tonumber(spec.height) or Token("size.buttonH", 26))
    local button = UI:CreateButton(spec.parent, spec.id, "", tonumber(spec.x) or 0, tonumber(spec.y) or 0, width, height,
        tonumber(spec.fontSize) or Token("font.small", 10), false, spec.gradient ~= false)
    if button == nil then return nil, "toggle_create_failed" end
    local c = RSUI:NewComponent("Toggle", spec, button)
    c.binding = RSUI:Binding(spec)
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
        self:Render()
        if type(spec.onChanged) == "function" then RSUI:Callback("rsui:" .. self.id .. ":changed", spec.onChanged, value, self) end
        return ok
    end
    c:On(button, "OnClick", function() return c:SetValue(not c:GetValue(), "click") end, "rsui:" .. spec.id .. ":toggle")
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
    c.binding = RSUI:Binding(spec)
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
                button:Render({
                    text = item.text,
                    selected = Equal(item.value, current),
                    enabled = self.enabled ~= false and item.enabled ~= false,
                })
            end
        end
        return current
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
        local ok = baseSetEnabled(self, enabled)
        self:Render()
        return ok
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
    c.binding = RSUI:Binding(spec)
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
    function c:Render(explicitValue)
        RSUI:_Count(self.kind, "rendered", 1)
        local value = Normalize(explicitValue ~= nil and explicitValue or self:GetValue())
        if explicitValue == nil then self.value = value end
        UI:SetText(self.root, value, self.owner)
        return value
    end
    function c:SetValue(value, notify, source)
        if self.enabled == false then return false end
        value = Normalize(value)
        local ok = Write(self.binding, value, true, source or "text_input_api", spec)
        if ok then self.value = value end
        self:Render(value)
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
    c:Render()
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
    c.binding = RSUI:Binding(spec)
    c.value = NormalizeNumber(spec, spec.value)
    function c:GetValue() return NormalizeNumber(spec, Read(self.binding, self.value)) end
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
    function c:Render(explicitValue)
        RSUI:_Count(self.kind, "rendered", 1)
        local value = NormalizeNumber(spec, explicitValue ~= nil and explicitValue or self:GetValue())
        if value == nil then return false end
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
        if ok then self.value = value end
        self:Render()
        if type(spec.onChanged) == "function" then RSUI:Callback("rsui:" .. self.id .. ":changed", spec.onChanged, value, self) end
        return ok
    end
    for _, eventName in ipairs({ "OnEnterPressed", "OnEditEnter", "OnLostFocus" }) do
        c:On(edit, eventName, function() return c:Submit("edit") end, "rsui:" .. spec.id .. ":" .. eventName)
    end
    c:SetEnabled(spec.enabled ~= false)
    c:Render()
    return c
end)

RSUI:RegisterType("Slider", function(spec)
    spec.min = tonumber(spec.min) or 0
    spec.max = tonumber(spec.max) or 100
    if spec.max < spec.min then spec.min, spec.max = spec.max, spec.min end
    spec.step = math.abs(tonumber(spec.step) or 1)
    local width = math.max(30, tonumber(spec.width) or 160)
    local height = math.max(14, tonumber(spec.height) or 20)
    local binding = RSUI:Binding(spec)
    local initial = NormalizeNumber(spec, Read(binding, spec.value)) or spec.min
    local slider = UI:CreateSlider(spec.parent, spec.id, tonumber(spec.x) or 0, tonumber(spec.y) or 0, width, height, spec.min, spec.max, spec.step, initial)
    if slider == nil then return nil, "slider_create_failed" end
    local c = RSUI:NewComponent("Slider", spec, slider)
    c.binding, c.value, c.previewValue = binding, initial, initial
    function c:GetValue() return NormalizeNumber(spec, Read(self.binding, self.value)) or self.value end
    function c:Render(explicit)
        RSUI:_Count(self.kind, "rendered", 1)
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
        self:Render(value)
        if type(spec.onPreview) == "function" then RSUI:Callback("rsui:" .. self.id .. ":preview", spec.onPreview, value, self, source or "slider") end
        return true
    end
    function c:CommitValue(value, source)
        if self.enabled == false then return false end
        value = NormalizeNumber(spec, value)
        if value == nil then return false end
        local ok = Write(self.binding, value, true, source or "slider", spec)
        if ok then self.value, self.previewValue = value, value end
        self:Render(value)
        if type(spec.onChanged) == "function" then RSUI:Callback("rsui:" .. self.id .. ":changed", spec.onChanged, value, self) end
        return ok
    end
    if type(slider.SetValueChangedHandler) == "function" then
        slider:SetValueChangedHandler(function(value, final)
            if final == true then c:CommitValue(value, "slider") else c:Preview(value, "slider") end
        end)
    end
    c:SetEnabled(spec.enabled ~= false)
    c:Render(initial)
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
RSUI.DropdownService = RSUI.DropdownService or {
    version = 1,
    instances = setmetatable({}, { __mode = "k" }),
}

function RSUI.DropdownService:Register(component)
    if type(component) ~= "table" then return false end
    self.instances[component] = true
    return true
end

function RSUI.DropdownService:Unregister(component)
    if type(component) == "table" then self.instances[component] = nil end
    return true
end

function RSUI.DropdownService:CloseAll(except)
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
    if type(c) ~= "table" then return nil, tostring(reason or "dropdown_fallback_failed") end
    c.rsUiDegraded = true
    c.rsUiDegradedReason = tostring(reason or "dropdown_popup_unavailable")
    c.popup, c.up, c.down = nil, nil, nil
    c.optionButtons = {}
    c.open = false

    local diagnostics = S.DiagnosticsManager
    if type(diagnostics) == "table" and type(diagnostics.Error) == "function" then
        diagnostics:Error("ui", "RSUI_DROPDOWN_DEGRADED", "下拉框弹层不可用，已降级为单按钮循环选择", {
            id = tostring(c.id or spec.id or ""), owner = tostring(c.owner or ""), reason = c.rsUiDegradedReason,
        })
    end

    function c:RefreshText()
        local text = tostring(spec.placeholder or "请选择")
        local item = self.items[self.selectedIndex]
        if type(item) == "table" then text = tostring(item.text or item.value or text) end
        UI:SetText(self.root, text .. "  ↻", self.owner)
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
        if self.enabled == false and source ~= "render" then return false end
        local ok = true
        if silent ~= true then ok = Write(self.binding, value, true, source or "dropdown_fallback", spec) end
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

    function c:SetValue(value, notify)
        local ok = Write(self.binding, value, true, "dropdown_fallback_api", spec)
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

    function c:Render()
        RSUI:_Count(self.kind, "rendered", 1)
        return self:SetSelectedValue(self:GetValue(), true, "render")
    end

    function c:Scroll(delta)
        if self.enabled == false or #self.items == 0 then return false end
        local direction = (tonumber(delta) or 0) < 0 and -1 or 1
        local start = self.selectedIndex
        if start == nil or start < 1 or start > #self.items then start = direction > 0 and 0 or (#self.items + 1) end
        for step = 1, #self.items do
            local index = ((start - 1 + direction * step) % #self.items) + 1
            local item = self.items[index]
            if type(item) == "table" and item.selectable ~= false and item.kind ~= "header" then
                return self:SetSelectedValue(item.value, false, "dropdown_fallback")
            end
        end
        return false
    end

    function c:Open() return self:Scroll(1) end
    function c:Close() self.open = false return false end
    function c:ToggleOpen() return self:Scroll(1) end
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
        self.enabled = enabled ~= false
        UI:SetEnabled(self.root, self.enabled, self.owner)
        return self.enabled
    end

    c:On(c.root, "OnClick", function() return c:ToggleOpen() end, "rsui:" .. tostring(spec.id) .. ":fallback")
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
    c.binding = RSUI:Binding(spec)
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
    if type(popup.SetDrawPriority) == "function" then pcall(function() popup:SetDrawPriority(10000) end) end
    UI:SetPickable(popup, true, c.owner)
    UI:SetEnabled(popup, true, c.owner)
    UI:SetVisible(popup, false, c.owner)

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
            UI:SetVisible(button, visible, self.owner)
            UI:SetEnabled(button, button.rsDropdownSelectable == true, self.owner)
            if visible then UI:SetText(button, tostring(item.text or item.value or "--"), self.owner) end
        end

        UI:SetVisible(self.up, needScroll, self.owner)
        UI:SetVisible(self.down, needScroll, self.owner)
        UI:SetEnabled(self.up, needScroll and self.scrollOffset > 0, self.owner)
        UI:SetEnabled(self.down, needScroll and self.scrollOffset < MaxScrollOffset(), self.owner)
        return true
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
        self:RefreshButtons()
        if self.open == true then self:ApplyPopupLayout() end
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
        self:RefreshButtons()
        return true
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
        self:RefreshButtons()
        if self.open == true and type(self.popup.Raise) == "function" then pcall(function() self.popup:Raise() end) end
        return true
    end

    function c:Open()
        if self.enabled == false or self.released == true then return false end
        if RSUI.DropdownService ~= nil then RSUI.DropdownService:CloseAll(self) end
        self.open = true
        self:ApplyPopupLayout()
        UI:SetVisible(self.popup, true, self.owner)
        if type(self.popup.SetDrawPriority) == "function" then pcall(function() self.popup:SetDrawPriority(10000) end) end
        if type(self.popup.Raise) == "function" then pcall(function() self.popup:Raise() end) end
        return true
    end

    function c:Close()
        if self.open ~= true then return false end
        self.open = false
        UI:SetVisible(self.popup, false, self.owner)
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
        if self.open == true then self:ApplyPopupLayout() end
        RSUI:_Count(self.kind, "layouts", 1)
        return true
    end

    function c:SetEnabled(enabled)
        self.enabled = enabled ~= false
        UI:SetEnabled(self.root, self.enabled, self.owner)
        if self.enabled == false then self:Close() end
        return self.enabled
    end

    c:On(trigger, "OnClick", function() return c:ToggleOpen() end, "rsui:" .. spec.id .. ":trigger")
    c:On(up, "OnClick", function() return c:Scroll(-1) end, "rsui:" .. spec.id .. ":up")
    c:On(down, "OnClick", function() return c:Scroll(1) end, "rsui:" .. spec.id .. ":down")
    c:On(popup, "OnWheelUp", function() return c:Scroll(-1) end, "rsui:" .. spec.id .. ":wheel_up")
    c:On(popup, "OnWheelDown", function() return c:Scroll(1) end, "rsui:" .. spec.id .. ":wheel_down")
    for index, button in ipairs(c.optionButtons) do
        -- Lua 5.1 closures capture the loop variable itself. Capture each native
        -- option button explicitly so every row keeps its own click target.
        local optionButton = button
        local optionIndex = index
        c:On(optionButton, "OnClick", function()
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
        if RSUI.DropdownService ~= nil then RSUI.DropdownService:Unregister(self) end
        return baseRelease(self)
    end

    RSUI.DropdownService:Register(c)
    c:SetItems(spec.items or spec.options or {})
    c:SetEnabled(spec.enabled ~= false)
    c:Render()
    return c
end)

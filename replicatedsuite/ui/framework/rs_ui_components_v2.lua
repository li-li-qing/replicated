------------------------------------------------------------------------
-- Replicated Suite - UI Composition Primitives v2
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local UI = S.UI
if type(UI) ~= "table" then return end

local Tokens = S.UITokens or {}
local Components = {
    version = 2.1,
    metrics = { created = 0, renders = 0, layouts = 0, validationErrors = 0 },
}
UI.ComponentsV2 = Components

local function Token(path, fallback)
    if type(Tokens.Number) == "function" then return Tokens:Number(path, fallback) end
    return tonumber(fallback) or 0
end

local function Clamp(value, minimum, maximum)
    value = tonumber(value) or tonumber(minimum) or 0
    if minimum ~= nil and value < minimum then value = minimum end
    if maximum ~= nil and value > maximum then value = maximum end
    return value
end

local function RoundToStep(value, minimum, step)
    value = tonumber(value)
    if value == nil then return nil end
    minimum = tonumber(minimum) or 0
    step = math.abs(tonumber(step) or 0)
    if step <= 0 then return value end
    return minimum + math.floor(((value - minimum) / step) + 0.5) * step
end

local function FormatNumber(value, spec)
    if type(spec.format) == "function" then
        local ok, text = pcall(spec.format, value)
        if ok and text ~= nil then return tostring(text) end
    end
    local step = math.abs(tonumber(spec.step) or 1)
    local decimals = 0
    if spec.integer ~= true and step < 1 then
        if step >= 0.1 then decimals = 1 elseif step >= 0.01 then decimals = 2 else decimals = 3 end
    end
    local text = decimals == 0 and tostring(math.floor((tonumber(value) or 0) + 0.5)) or string.format("%." .. tostring(decimals) .. "f", tonumber(value) or 0)
    if decimals > 0 then text = text:gsub("0+$", ""):gsub("%.$", "") end
    return text
end

local function BindingOf(spec)
    if type(spec.binding) == "table" then return spec.binding end
    if type(UI.CreateSettingBinding) ~= "function" then return nil end
    return UI:CreateSettingBinding({
        id = spec.id,
        get = spec.get,
        set = spec.set,
        normalize = spec.normalize,
        validate = spec.validate,
        commit = spec.commit,
        autoCommit = spec.autoCommit == true,
    })
end

local function SetWidgetEnabled(widget, enabled, owner)
    if widget == nil then return end
    if type(UI.SetEnabled) == "function" and (type(widget.Enable) == "function" or type(widget.SetEnabled) == "function") then
        UI:SetEnabled(widget, enabled, owner)
        return
    end
    if type(widget.SetEnabled) == "function" then widget:SetEnabled(enabled == true)
    elseif type(widget.Enable) == "function" then widget:Enable(enabled == true) end
end

local function CreateFieldBase(parent, id, spec)
    spec = type(spec) == "table" and spec or {}
    local width = tonumber(spec.width) or 300
    local height = tonumber(spec.height) or Token("component.form.fieldH", 52)
    local root = UI:CreatePanel(parent, tostring(id) .. "_field", tonumber(spec.x) or 0, tonumber(spec.y) or 0, width, height, spec.kind or "card", { gradient = spec.gradient ~= false })
    local owner = root and root.rsUiOwner or nil
    local label = UI:CreateLabel(root, tostring(id) .. "_field_label", tostring(spec.label or ""), 8, 3, math.max(1, width - 112), 18,
        tonumber(spec.fontSize) or Token("font.body", 11), spec.labelTone or "default", ALIGN_LEFT, spec.shadow == true)
    local feedback = UI:CreateLabel(root, tostring(id) .. "_field_feedback", "", math.max(0, width - 104), 3, 96, 18,
        tonumber(spec.feedbackFontSize) or Token("font.caption", 9), "muted", ALIGN_RIGHT)
    local hint = nil
    if spec.hint ~= nil and tostring(spec.hint) ~= "" then
        hint = UI:CreateLabel(root, tostring(id) .. "_field_hint", tostring(spec.hint), 8, height - 18, math.max(1, width - 16), 15,
            tonumber(spec.hintFontSize) or Token("font.caption", 9), "muted", ALIGN_LEFT)
    end
    local field = {
        id = tostring(id), root = root, label = label, feedback = feedback, hint = hint,
        owner = owner, spec = spec, width = width, height = height, enabled = spec.enabled ~= false,
        lastFeedback = nil, lastFeedbackTone = nil,
    }
    Components.metrics.created = Components.metrics.created + 1

    function field:SetFeedback(text, tone)
        text = tostring(text or "")
        tone = tostring(tone or (text ~= "" and "danger" or "muted"))
        UI:SetText(self.feedback, text, self.owner)
        UI:SetLabelTone(self.feedback, tone, self.owner)
        self.lastFeedback, self.lastFeedbackTone = text, tone
        return true
    end

    function field:FeedbackFromBinding(binding)
        local err = binding and binding.GetError and binding:GetError() or nil
        if err ~= nil and tostring(err) ~= "" then
            local text = tostring(err)
            if self.lastFeedback ~= text or self.lastFeedbackTone ~= "danger" then
                Components.metrics.validationErrors = Components.metrics.validationErrors + 1
            end
            self:SetFeedback(text, "danger")
            return false
        end
        if self.spec.statusText ~= nil then self:SetFeedback(self.spec.statusText, self.spec.statusTone or "muted")
        else self:SetFeedback("", "muted") end
        return true
    end

    function field:SetEnabled(enabled)
        self.enabled = enabled == true
        UI:SetAlpha(self.root, self.enabled and 1 or Token("alpha.disabled", 0.45), self.owner)
        return self.enabled
    end

    function field:SetVisible(visible)
        return UI:SetVisible(self.root, visible == true, self.owner)
    end

    function field:Layout(x, y, nextWidth, nextHeight)
        self.width = math.max(1, tonumber(nextWidth) or self.width)
        self.height = math.max(1, tonumber(nextHeight) or self.height)
        UI:SetAnchor(self.root, parent, tonumber(x) or 0, tonumber(y) or 0, self.owner)
        UI:SetExtent(self.root, self.width, self.height, self.owner)
        local feedbackW = math.max(74, math.min(Token("component.form.feedbackW", 96), self.width * 0.32))
        UI:SetAnchor(self.label, self.root, 8, 3, self.owner)
        UI:SetExtent(self.label, math.max(1, self.width - feedbackW - 22), 18, self.owner)
        UI:SetAnchor(self.feedback, self.root, self.width - feedbackW - 8, 3, self.owner)
        UI:SetExtent(self.feedback, feedbackW, 18, self.owner)
        if self.hint ~= nil then
            UI:SetAnchor(self.hint, self.root, 8, math.max(21, self.height - 18), self.owner)
            UI:SetExtent(self.hint, math.max(1, self.width - 16), 15, self.owner)
        end
        Components.metrics.layouts = Components.metrics.layouts + 1
        return self.height
    end

    return field
end

function Components:CreateCard(parent, id, spec)
    spec = type(spec) == "table" and spec or {}
    local width = tonumber(spec.width) or 260
    local height = tonumber(spec.height) or 120
    local panel = UI:CreatePanel(parent, tostring(id) .. "_card", tonumber(spec.x) or 0, tonumber(spec.y) or 0, width, height, "card", { gradient = spec.gradient ~= false })
    panel.rsCardPadding = tonumber(spec.padding) or Token("component.card.padding", 10)
    return panel
end

function Components:CreateSection(parent, id, spec)
    spec = type(spec) == "table" and spec or {}
    local width = tonumber(spec.width) or 300
    local height = tonumber(spec.height) or 140
    local headerH = tonumber(spec.headerHeight) or Token("size.sectionHeaderH", 28)
    local padding = tonumber(spec.padding) or Token("component.card.padding", 10)
    local root = UI:CreatePanel(parent, tostring(id) .. "_section", tonumber(spec.x) or 0, tonumber(spec.y) or 0, width, height, "card", { gradient = spec.gradient ~= false })
    local header = UI:CreatePanel(root, tostring(id) .. "_header", 0, 0, width, headerH, "header", { accentStrip = spec.accentStrip ~= false })
    local title = UI:CreateLabel(header, tostring(id) .. "_title", tostring(spec.title or ""), padding, 2, math.max(1, width - padding * 2), headerH - 4, tonumber(spec.titleFontSize) or Token("font.section", 13), spec.tone or "default", ALIGN_LEFT, true)
    local section = { root = root, header = header, title = title, body = root, padding = padding, headerHeight = headerH, owner = root.rsUiOwner }
    function section:SetTitle(text) UI:SetText(self.title, tostring(text or ""), self.owner) end
    function section:ContentOrigin() return self.padding, self.headerHeight + self.padding end
    function section:SetExtent(nextWidth, nextHeight)
        nextWidth, nextHeight = math.max(1, tonumber(nextWidth) or width), math.max(1, tonumber(nextHeight) or height)
        UI:SetExtent(self.root, nextWidth, nextHeight, self.owner)
        UI:SetExtent(self.header, nextWidth, self.headerHeight, self.owner)
        UI:SetExtent(self.title, math.max(1, nextWidth - self.padding * 2), self.headerHeight - 4, self.owner)
    end
    return section
end

function Components:CreateFormRow(parent, id, spec)
    spec = type(spec) == "table" and spec or {}
    local height = tonumber(spec.height) or Token("component.form.rowH", 28)
    local width = tonumber(spec.width) or 320
    local labelW = tonumber(spec.labelWidth) or Token("component.form.labelW", 116)
    local gap = tonumber(spec.gap) or Token("spacing.sm", 8)
    local x, y = tonumber(spec.x) or 0, tonumber(spec.y) or 0
    local label = UI:CreateLabel(parent, tostring(id) .. "_label", tostring(spec.label or ""), x, y, labelW, height, tonumber(spec.fontSize) or Token("font.body", 11), spec.tone or "default", ALIGN_LEFT)
    local row = { label = label, control = spec.control, owner = label.rsUiOwner, x = x, y = y, width = width, height = height, labelWidth = labelW, gap = gap }
    if spec.control ~= nil then
        UI:SetAnchor(spec.control, parent, x + labelW + gap, y, row.owner)
        if spec.controlWidth ~= nil then UI:SetExtent(spec.control, tonumber(spec.controlWidth) or 1, height, row.owner) end
    end
    function row:SetLabel(text) UI:SetText(self.label, tostring(text or ""), self.owner) end
    function row:SetVisible(visible)
        UI:SetVisible(self.label, visible == true, self.owner)
        if self.control ~= nil then UI:SetVisible(self.control, visible == true, self.owner) end
    end
    return row
end

function Components:CreateToggleField(parent, id, spec)
    spec = type(spec) == "table" and spec or {}
    spec.id = spec.id or id
    local field = CreateFieldBase(parent, id, spec)
    local binding = BindingOf(spec)
    field.binding = binding
    field.button = UI:CreateButton(field.root, tostring(id) .. "_toggle_button", "", 8, 24, 120, Token("size.buttonH", 26), tonumber(spec.controlFontSize) or Token("font.small", 10), false, true)

    function field:Render()
        Components.metrics.renders = Components.metrics.renders + 1
        if self.binding == nil then self:SetFeedback("Binding 缺失", "danger"); return false end
        local value = self.binding:Get() == true
        local text = value and tostring(spec.onText or "已开启") or tostring(spec.offText or "已关闭")
        UI:SetText(self.button, text, self.owner)
        UI:SetButtonActive(self.button, value, self.owner)
        self:FeedbackFromBinding(self.binding)
        return value
    end

    local BaseSetEnabled = field.SetEnabled
    function field:SetEnabled(enabled)
        BaseSetEnabled(self, enabled)
        SetWidgetEnabled(self.button, self.enabled, self.owner)
        return self.enabled
    end

    function field:Layout(x, y, width, height)
        field.width = math.max(1, tonumber(width) or field.width)
        field.height = math.max(1, tonumber(height) or field.height)
        UI:SetAnchor(field.root, parent, tonumber(x) or 0, tonumber(y) or 0, field.owner)
        UI:SetExtent(field.root, field.width, field.height, field.owner)
        local feedbackW = math.max(74, math.min(Token("component.form.feedbackW", 96), field.width * 0.32))
        UI:SetAnchor(field.label, field.root, 8, 3, field.owner); UI:SetExtent(field.label, math.max(1, field.width - feedbackW - 22), 18, field.owner)
        UI:SetAnchor(field.feedback, field.root, field.width - feedbackW - 8, 3, field.owner); UI:SetExtent(field.feedback, feedbackW, 18, field.owner)
        local buttonW = math.max(92, math.min(138, field.width - 16))
        UI:SetAnchor(field.button, field.root, field.width - buttonW - 8, 23, field.owner); UI:SetExtent(field.button, buttonW, math.max(22, field.height - 29), field.owner)
        if field.hint ~= nil then UI:SetAnchor(field.hint, field.root, 8, math.max(21, field.height - 18), field.owner); UI:SetExtent(field.hint, math.max(1, field.width - buttonW - 28), 15, field.owner) end
        Components.metrics.layouts = Components.metrics.layouts + 1
        return field.height
    end

    UI:SafeHandler(field.button, "OnClick", function()
        if field.enabled ~= true or binding == nil then return false end
        local nextValue = not (binding:Get() == true)
        local ok = binding:Set(nextValue, true, "toggle")
        if ok and spec.commitOnFinal == true then ok = binding:Commit("toggle") end
        field:Render()
        if type(spec.onApplied) == "function" then pcall(spec.onApplied, ok, nextValue, field) end
        return ok
    end, tostring(id) .. ":toggle_v2")
    field:SetEnabled(field.enabled)
    field:Render()
    return field
end

function Components:CreateChoiceField(parent, id, spec)
    spec = type(spec) == "table" and spec or {}
    spec.id = spec.id or id
    local field = CreateFieldBase(parent, id, spec)
    local binding = BindingOf(spec)
    field.binding = binding
    field.values = type(spec.values) == "table" and spec.values or {}
    field.previous = UI:CreateButton(field.root, tostring(id) .. "_choice_previous", "<", 8, 24, 28, Token("size.buttonH", 26), Token("font.small", 10), false)
    field.valueButton = UI:CreateButton(field.root, tostring(id) .. "_choice_value", "", 40, 24, 120, Token("size.buttonH", 26), tonumber(spec.controlFontSize) or Token("font.small", 10), false, true)
    field.next = UI:CreateButton(field.root, tostring(id) .. "_choice_next", ">", 164, 24, 28, Token("size.buttonH", 26), Token("font.small", 10), false)

    local function ValueOf(item) return type(item) == "table" and item.value or item end
    local function LabelOf(item) return type(item) == "table" and (item.label or item.value) or item end
    function field:IndexOf(value)
        for index, item in ipairs(self.values) do if ValueOf(item) == value then return index end end
        return #self.values > 0 and 1 or 0
    end
    function field:Render()
        Components.metrics.renders = Components.metrics.renders + 1
        if binding == nil then self:SetFeedback("Binding 缺失", "danger"); return false end
        local value = binding:Get()
        local index = self:IndexOf(value)
        local item = self.values[index]
        UI:SetText(self.valueButton, tostring(LabelOf(item) or "--"), self.owner)
        self:FeedbackFromBinding(binding)
        return value
    end
    function field:Move(delta)
        if self.enabled ~= true or binding == nil or #self.values == 0 then return false end
        local index = self:IndexOf(binding:Get())
        if index <= 0 then index = 1 end
        index = ((index - 1 + (tonumber(delta) or 1)) % #self.values) + 1
        local value = ValueOf(self.values[index])
        local ok = binding:Set(value, true, "choice")
        if ok and spec.commitOnFinal == true then ok = binding:Commit("choice") end
        self:Render()
        if type(spec.onApplied) == "function" then pcall(spec.onApplied, ok, value, self) end
        return ok
    end
    local BaseSetEnabled = field.SetEnabled
    function field:SetEnabled(enabled)
        BaseSetEnabled(self, enabled)
        SetWidgetEnabled(self.previous, self.enabled, self.owner)
        SetWidgetEnabled(self.valueButton, self.enabled, self.owner)
        SetWidgetEnabled(self.next, self.enabled, self.owner)
        return self.enabled
    end
    function field:Layout(x, y, width, height)
        field.width = math.max(1, tonumber(width) or field.width); field.height = math.max(1, tonumber(height) or field.height)
        UI:SetAnchor(field.root, parent, tonumber(x) or 0, tonumber(y) or 0, field.owner); UI:SetExtent(field.root, field.width, field.height, field.owner)
        local feedbackW = math.max(74, math.min(Token("component.form.feedbackW", 96), field.width * 0.32))
        UI:SetAnchor(field.label, field.root, 8, 3, field.owner); UI:SetExtent(field.label, math.max(1, field.width - feedbackW - 22), 18, field.owner)
        UI:SetAnchor(field.feedback, field.root, field.width - feedbackW - 8, 3, field.owner); UI:SetExtent(field.feedback, feedbackW, 18, field.owner)
        local controlsW = math.max(128, field.width - 16)
        local arrowW, gap = 28, 4
        local valueW = math.max(64, controlsW - arrowW * 2 - gap * 2)
        local cy = 23
        UI:SetAnchor(field.previous, field.root, 8, cy, field.owner); UI:SetExtent(field.previous, arrowW, math.max(22, field.height - 29), field.owner)
        UI:SetAnchor(field.valueButton, field.root, 8 + arrowW + gap, cy, field.owner); UI:SetExtent(field.valueButton, valueW, math.max(22, field.height - 29), field.owner)
        UI:SetAnchor(field.next, field.root, 8 + arrowW + gap + valueW + gap, cy, field.owner); UI:SetExtent(field.next, arrowW, math.max(22, field.height - 29), field.owner)
        Components.metrics.layouts = Components.metrics.layouts + 1
        return field.height
    end
    UI:SafeHandler(field.previous, "OnClick", function() return field:Move(-1) end, tostring(id) .. ":choice_previous_v2")
    UI:SafeHandler(field.next, "OnClick", function() return field:Move(1) end, tostring(id) .. ":choice_next_v2")
    UI:SafeHandler(field.valueButton, "OnClick", function() return field:Move(1) end, tostring(id) .. ":choice_value_v2")
    field:SetEnabled(field.enabled)
    field:Render()
    return field
end

function Components:CreateNumericField(parent, id, spec)
    spec = type(spec) == "table" and spec or {}
    spec.id = spec.id or id
    local field = CreateFieldBase(parent, id, spec)
    local binding = BindingOf(spec)
    field.binding = binding
    field.minimum = tonumber(spec.min) or 0
    field.maximum = tonumber(spec.max) or 100
    if field.maximum < field.minimum then field.minimum, field.maximum = field.maximum, field.minimum end
    field.step = math.abs(tonumber(spec.step) or 1)
    field.integer = spec.integer == true
    field.unit = tostring(spec.unit or spec.suffix or "")
    field.previewValue = nil
    field.minus = UI:CreateButton(field.root, tostring(id) .. "_numeric_minus", "-", 8, 24, 26, Token("size.buttonH", 26), Token("font.small", 10), false)
    field.slider = UI.CreateSlider and UI:CreateSlider(field.root, tostring(id) .. "_numeric_slider", 38, 27, 100, 20, field.minimum, field.maximum, field.step, field.minimum) or nil
    field.edit = UI:CreateEditBox(field.root, tostring(id) .. "_numeric_edit", 142, 24, 54, Token("size.inputH", 24), tonumber(spec.maxLength) or 14)
    field.readout = field.edit == nil and UI:CreateLabel(field.root, tostring(id) .. "_numeric_readout", "", 142, 25, 54, 20, Token("font.small", 10), "default", ALIGN_CENTER) or nil
    field.plus = UI:CreateButton(field.root, tostring(id) .. "_numeric_plus", "+", 200, 24, 26, Token("size.buttonH", 26), Token("font.small", 10), false)

    function field:NormalizeInput(value)
        value = tonumber(value)
        if value == nil then return nil end
        value = RoundToStep(value, self.minimum, self.step)
        value = Clamp(value, self.minimum, self.maximum)
        if self.integer then value = math.floor(value + 0.5) end
        return value
    end
    function field:Display(value)
        local text = FormatNumber(value, { step = self.step, integer = self.integer, format = spec.format })
        return text, text .. self.unit
    end
    function field:Render(explicitValue)
        Components.metrics.renders = Components.metrics.renders + 1
        if binding == nil then self:SetFeedback("Binding 缺失", "danger"); return false end
        local value = explicitValue
        if value == nil then value = binding:Get() end
        value = self:NormalizeInput(value)
        if value == nil then self:SetFeedback("数值不可用", "danger"); return false end
        self.previewValue = value
        local rawText, displayText = self:Display(value)
        if self.edit ~= nil then UI:SetText(self.edit, rawText, self.owner) end
        if self.readout ~= nil then UI:SetText(self.readout, displayText, self.owner) end
        if self.slider ~= nil and type(self.slider.SetValue) == "function" and tonumber(self.slider:GetValue()) ~= tonumber(value) then self.slider:SetValue(value, false) end
        self:FeedbackFromBinding(binding)
        return value
    end
    function field:Apply(value, source)
        if self.enabled ~= true or binding == nil then return false end
        local normalized = self:NormalizeInput(value)
        if normalized == nil then self:SetFeedback("请输入有效数字", "danger"); return false end
        local previous = binding:Get()
        local ok = binding:Set(normalized, true, tostring(source or "numeric"), previous)
        if ok and spec.commitOnFinal == true then ok = binding:Commit(source or "numeric") end
        self:Render()
        if type(spec.onApplied) == "function" then pcall(spec.onApplied, ok, normalized, self) end
        return ok
    end
    function field:Preview(value)
        local normalized = self:NormalizeInput(value)
        if normalized == nil then return false end
        self.previewValue = normalized
        local rawText, displayText = self:Display(normalized)
        if self.edit ~= nil then UI:SetText(self.edit, rawText, self.owner) end
        if self.readout ~= nil then UI:SetText(self.readout, displayText, self.owner) end
        self:SetFeedback("预览", "info")
        return true
    end
    local BaseSetEnabled = field.SetEnabled
    function field:SetEnabled(enabled)
        BaseSetEnabled(self, enabled)
        SetWidgetEnabled(self.minus, self.enabled, self.owner)
        SetWidgetEnabled(self.slider, self.enabled, self.owner)
        SetWidgetEnabled(self.edit, self.enabled, self.owner)
        SetWidgetEnabled(self.plus, self.enabled, self.owner)
        return self.enabled
    end
    function field:Layout(x, y, width, height)
        field.width = math.max(1, tonumber(width) or field.width); field.height = math.max(1, tonumber(height) or field.height)
        UI:SetAnchor(field.root, parent, tonumber(x) or 0, tonumber(y) or 0, field.owner); UI:SetExtent(field.root, field.width, field.height, field.owner)
        local feedbackW = math.max(74, math.min(Token("component.form.feedbackW", 96), field.width * 0.32))
        UI:SetAnchor(field.label, field.root, 8, 3, field.owner); UI:SetExtent(field.label, math.max(1, field.width - feedbackW - 22), 18, field.owner)
        UI:SetAnchor(field.feedback, field.root, field.width - feedbackW - 8, 3, field.owner); UI:SetExtent(field.feedback, feedbackW, 18, field.owner)
        local cy = 25
        local controlH = math.max(20, field.height - 30)
        local minusW, plusW, editW, gap = 26, 26, (field.edit ~= nil and 54 or 50), 4
        local sliderW = math.max(56, field.width - 16 - minusW - plusW - editW - gap * 3)
        local xx = 8
        UI:SetAnchor(field.minus, field.root, xx, cy - 1, field.owner); UI:SetExtent(field.minus, minusW, controlH, field.owner); xx = xx + minusW + gap
        if field.slider ~= nil then UI:SetAnchor(field.slider, field.root, xx, cy + 2, field.owner); UI:SetExtent(field.slider, sliderW, math.max(16, controlH - 4), field.owner) end
        xx = xx + sliderW + gap
        if field.edit ~= nil then UI:SetAnchor(field.edit, field.root, xx, cy, field.owner); UI:SetExtent(field.edit, editW, math.max(20, controlH - 1), field.owner)
        elseif field.readout ~= nil then UI:SetAnchor(field.readout, field.root, xx, cy + 1, field.owner); UI:SetExtent(field.readout, editW, math.max(18, controlH - 2), field.owner) end
        xx = xx + editW + gap
        UI:SetAnchor(field.plus, field.root, xx, cy - 1, field.owner); UI:SetExtent(field.plus, plusW, controlH, field.owner)
        Components.metrics.layouts = Components.metrics.layouts + 1
        return field.height
    end

    UI:SafeHandler(field.minus, "OnClick", function()
        local base = field.previewValue or (binding and binding:Get()) or field.minimum
        return field:Apply((tonumber(base) or field.minimum) - field.step, "minus")
    end, tostring(id) .. ":numeric_minus_v2")
    UI:SafeHandler(field.plus, "OnClick", function()
        local base = field.previewValue or (binding and binding:Get()) or field.minimum
        return field:Apply((tonumber(base) or field.minimum) + field.step, "plus")
    end, tostring(id) .. ":numeric_plus_v2")
    local function SubmitEdit()
        if field.edit == nil or type(field.edit.GetText) ~= "function" then return false end
        local text = tostring(field.edit:GetText() or "")
        -- Unit is a literal suffix, not a Lua pattern.  In particular "%" is
        -- a valid Healer unit and must never be passed directly to gsub().
        if field.unit ~= "" and #text >= #field.unit and text:sub(-#field.unit) == field.unit then
            text = text:sub(1, #text - #field.unit)
        end
        return field:Apply(tonumber(text), "edit")
    end
    for _, eventName in ipairs({ "OnEnterPressed", "OnEditEnter", "OnLostFocus" }) do
        UI:SafeHandler(field.edit, eventName, SubmitEdit, tostring(id) .. ":numeric_edit_v2:" .. eventName)
    end
    if field.slider ~= nil and type(field.slider.SetValueChangedHandler) == "function" then
        -- Slider drag is preview-only until final=true.  This preserves the
        -- Persistence Dirty+Debounce contract by avoiding Domain writes every
        -- 50 ms while the user is dragging.
        field.slider:SetValueChangedHandler(function(value, final)
            if final == true then field:Apply(value, "slider") else field:Preview(value) end
        end)
    end
    field:SetEnabled(field.enabled)
    field:Render()
    return field
end

function Components:LayoutFieldGrid(parent, fields, spec)
    fields = type(fields) == "table" and fields or {}
    spec = type(spec) == "table" and spec or {}
    if UI.LayoutV2 == nil or type(UI.LayoutV2.ResponsiveGrid) ~= "function" then return 0 end
    local grid = UI.LayoutV2:ResponsiveGrid(parent, {
        x = tonumber(spec.x) or 0,
        y = tonumber(spec.y) or 0,
        width = math.max(1, tonumber(spec.width) or 1),
        minCellWidth = tonumber(spec.minCellWidth) or 250,
        minColumns = tonumber(spec.minColumns) or 1,
        maxColumns = tonumber(spec.maxColumns) or 2,
        cellHeight = tonumber(spec.cellHeight) or Token("component.form.fieldH", 52),
        gapX = tonumber(spec.gapX) or Token("component.grid.gapX", 8),
        gapY = tonumber(spec.gapY) or Token("component.grid.gapY", 8),
        owner = spec.owner,
    })
    for _, field in ipairs(fields) do
        if field ~= nil and field.root ~= nil then
            local _, x, y = grid:Add(field.root)
            if type(field.Layout) == "function" then field:Layout(x, y, grid.cellWidth, grid.cellHeight) end
        end
    end
    return grid:UsedHeight(), grid.columns
end

function Components:GetSnapshot()
    return {
        version = self.version,
        created = tonumber(self.metrics.created) or 0,
        renders = tonumber(self.metrics.renders) or 0,
        layouts = tonumber(self.metrics.layouts) or 0,
        validationErrors = tonumber(self.metrics.validationErrors) or 0,
    }
end

function Components:ResetMetrics()
    self.metrics.created, self.metrics.renders, self.metrics.layouts, self.metrics.validationErrors = 0, 0, 0, 0
end

function UI:CreateCardV2(parent, id, spec) return Components:CreateCard(parent, id, spec) end
function UI:CreateSectionV2(parent, id, spec) return Components:CreateSection(parent, id, spec) end
function UI:CreateFormRowV2(parent, id, spec) return Components:CreateFormRow(parent, id, spec) end
function UI:CreateToggleFieldV2(parent, id, spec) return Components:CreateToggleField(parent, id, spec) end
function UI:CreateChoiceFieldV2(parent, id, spec) return Components:CreateChoiceField(parent, id, spec) end
function UI:CreateNumericFieldV2(parent, id, spec) return Components:CreateNumericField(parent, id, spec) end

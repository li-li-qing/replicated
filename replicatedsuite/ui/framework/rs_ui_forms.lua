------------------------------------------------------------------------
-- Replicated Suite - RSUI Form Component System v1
--
-- Platform-level form composition above RSUI primitives/controls.  Business
-- modules declare fields and bindings; this layer owns label/status layout,
-- validation feedback, responsive field grids and form state summaries.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local UI, RSUI = S.UI, S.RSUI
if type(UI) ~= "table" or type(RSUI) ~= "table" then return end
local Tokens = S.UITokens or {}
local Layout = UI.LayoutV2
RSUI.FormLayoutContractVersion = 2
RSUI.NumericInlineContractVersion = 6
RSUI.NumericExplicitApplyContractVersion = 1
RSUI.NumericStepPairFallbackContractVersion = 1
RSUI.FormCompositeFailClosedContractVersion = 1
RSUI.NumericAdaptiveRangeContractVersion = 1

local function Token(path, fallback)
    if type(Tokens.Number) == "function" then return Tokens:Number(path, fallback) end
    return tonumber(fallback) or 0
end

local function N(value, fallback)
    local number = tonumber(value)
    if number == nil then return tonumber(fallback) or 0 end
    return number
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
    minimum = tonumber(minimum) or 0
    step = math.abs(tonumber(step) or 0)
    if step <= 0 then return value end
    return minimum + math.floor(((value - minimum) / step) + 0.5) * step
end

local function BindingDirty(binding)
    return binding ~= nil and type(binding.IsDirty) == "function" and binding:IsDirty() == true
end

local function BindingError(binding)
    if binding == nil or type(binding.GetError) ~= "function" then return nil end
    local err = binding:GetError()
    if err == nil or tostring(err) == "" then return nil end
    return tostring(err)
end

local function BindingValue(binding, fallback)
    if binding ~= nil and type(binding.Get) == "function" then return binding:Get() end
    return fallback
end

local function NotifyField(spec, name, ...)
    local fn = spec and spec[name]
    if type(fn) ~= "function" then return true end
    local ok = RSUI:Callback("rsui_form:" .. tostring(spec.id or "field") .. ":" .. tostring(name), fn, ...)
    return ok == true
end

local function TextMetricHeight(component, fallback)
    local base = math.max(1, tonumber(fallback) or 1)
    if type(component) ~= "table" then return base end
    local root = component.root
    local fontSize = root and tonumber(root.rsBaseFontSize) or (component.spec and tonumber(component.spec.fontSize))
    local textLayout = RSUI.TextLayout
    if root ~= nil and type(textLayout) == "table" and type(textLayout.LineHeight) == "function" then
        local ok, height = pcall(function() return textLayout:LineHeight(root, fontSize) end)
        if ok and tonumber(height) ~= nil then return math.max(base, math.ceil(tonumber(height))) end
    end
    if type(component.Measure) == "function" then
        local ok, _, height = pcall(function() return component:Measure(nil, nil) end)
        if ok and tonumber(height) ~= nil then return math.max(base, math.ceil(tonumber(height))) end
    end
    return base
end

local function NormalizeDropdownItems(items)
    local normalized = {}
    for _, item in ipairs(type(items) == "table" and items or {}) do
        if type(item) == "table" then
            local copy = {}
            for key, value in pairs(item) do copy[key] = value end
            if copy.text == nil then copy.text = copy.label or copy.name or copy.value end
            if copy.label == nil then copy.label = copy.text end
            normalized[#normalized + 1] = copy
        else
            normalized[#normalized + 1] = { value = item, text = tostring(item), label = tostring(item) }
        end
    end
    return normalized
end

------------------------------------------------------------------------
-- ValidationMessage
------------------------------------------------------------------------
RSUI:RegisterType("ValidationMessage", function(spec)
    local width = math.max(1, N(spec.width, Token("component.form.feedbackW", 96)))
    local height = math.max(1, N(spec.height, 18))
    local label = UI:CreateLabel(spec.parent, spec.id, tostring(spec.text or ""), N(spec.x, 0), N(spec.y, 0), width, height,
        N(spec.fontSize, Token("font.caption", 9)), spec.tone or "muted", spec.align or ALIGN_RIGHT, false)
    if label == nil then return nil, "validation_message_create_failed" end
    local c = RSUI:NewComponent("ValidationMessage", spec, label)
    c.message = tostring(spec.text or "")
    c.tone = tostring(spec.tone or "muted")

    function c:SetMessage(text, tone)
        self.message = tostring(text or "")
        self.tone = tostring(tone or (self.message ~= "" and "danger" or "muted"))
        UI:SetText(self.root, self.message, self.owner)
        UI:SetLabelTone(self.root, self.tone, self.owner)
        return self.message
    end

    function c:Clear()
        return self:SetMessage("", "muted")
    end

    function c:Render(state)
        state = type(state) == "table" and state or {}
        RSUI:_Count(self.kind, "rendered", 1)
        return self:SetMessage(state.text ~= nil and state.text or self.message, state.tone or self.tone)
    end

    return c
end)

------------------------------------------------------------------------
-- Shared field frame
------------------------------------------------------------------------
local function CreateFieldFrame(kind, spec)
    local width = math.max(1, N(spec.width, 300))
    local height = math.max(1, N(spec.height, Token("component.form.fieldH", 52)))
    local root = UI:CreatePanel(spec.parent, spec.id .. "_frame", N(spec.x, 0), N(spec.y, 0), width, height,
        spec.variant or "soft", { gradient = spec.gradient == true })
    if root == nil then return nil, "field_frame_create_failed" end

    local c = RSUI:NewComponent(kind, spec, root)
    if c == nil then
        if root ~= nil and type(UI.SetVisible) == "function" then UI:SetVisible(root, false, root.rsUiOwner) end
        return nil, "field_component_create_failed"
    end
    local binding, bindingErr = RSUI:Binding(spec)
    if binding == nil then
        c:Release()
        return nil, "field_binding_failed:" .. tostring(bindingErr or "unknown")
    end
    c.binding = binding
    c.padding = N(spec.padding, Token("spacing.sm", 8))
    c.headerHeight = N(spec.headerHeight, 18)
    c.controlTop = N(spec.controlTop, 24)
    c.headerInsetY = N(spec.headerInsetY, 3)
    c.headerGap = N(spec.headerGap, 3)
    c.hintGap = N(spec.hintGap, 3)
    c.controlMinHeight = math.max(18, N(spec.controlMinHeight, 18))
    c.controlPreferredHeight = math.max(c.controlMinHeight, N(spec.controlHeight, Token("size.inputH", 24)))
    c.feedbackWidth = N(spec.feedbackWidth, Token("component.form.feedbackW", 96))
    c.showDirty = spec.showDirty == true
    c.statusText = spec.statusText
    c.statusTone = spec.statusTone or "muted"
    c.control = nil
    c.transientFeedback = nil
    c.transientTone = nil
    c.localError = nil

    c.label = RSUI:Text({
        id = spec.id .. "_label",
        parent = c,
        text = tostring(spec.label or ""),
        fontSize = N(spec.labelFontSize, Token("font.body", 11)),
        tone = spec.labelTone or "default",
        align = ALIGN_LEFT,
        shadow = spec.shadow == true,
        width = math.max(1, width - c.feedbackWidth - c.padding * 3),
        height = c.headerHeight,
    })
    if c.label == nil then
        c:Release()
        return nil, "field_label_create_failed"
    end
    c.feedback = RSUI:ValidationMessage({
        id = spec.id .. "_feedback",
        parent = c,
        text = "",
        tone = "muted",
        align = ALIGN_RIGHT,
        width = c.feedbackWidth,
        height = c.headerHeight,
    })
    if c.feedback == nil then
        c:Release()
        return nil, "field_feedback_create_failed"
    end
    if spec.hint ~= nil and tostring(spec.hint) ~= "" then
        c.hint = RSUI:Text({
            id = spec.id .. "_hint",
            parent = c,
            text = tostring(spec.hint),
            fontSize = N(spec.hintFontSize, Token("font.caption", 9)),
            tone = spec.hintTone or "muted",
            align = ALIGN_LEFT,
            width = math.max(1, width - c.padding * 2),
            height = 16,
        })
    end

    function c:SetLabel(text)
        self.spec.label = tostring(text or "")
        if self.label ~= nil then return self.label:SetText(self.spec.label) end
        return false
    end

    function c:SetHint(text, tone)
        if self.hint == nil then return false end
        self.spec.hint = tostring(text or "")
        self.hint:SetText(self.spec.hint)
        if tone ~= nil then self.hint:SetTone(tone) end
        return true
    end

    function c:SetFeedback(text, tone, transient)
        text = tostring(text or "")
        tone = tostring(tone or "muted")
        if transient == true then
            self.transientFeedback = text
            self.transientTone = tone
            self.localError = (tone == "danger" and text ~= "") and text or nil
        elseif transient == false then
            self.transientFeedback, self.transientTone, self.localError = nil, nil, nil
        end
        if self.feedback ~= nil then self.feedback:SetMessage(text, tone) end
        return true
    end

    function c:ClearTransientFeedback()
        self.transientFeedback, self.transientTone, self.localError = nil, nil, nil
        return self:SyncFeedback()
    end

    function c:GetError()
        return BindingError(self.binding) or self.localError
    end

    function c:IsDirty()
        return BindingDirty(self.binding)
    end

    function c:IsValid()
        return self:GetError() == nil
    end

    function c:SyncFeedback()
        local err = self:GetError()
        if err ~= nil then
            if self.feedback ~= nil then self.feedback:SetMessage(err, "danger") end
            self.semanticState = RSUI.State.Error
            return false
        end
        if self.transientFeedback ~= nil and self.transientFeedback ~= "" then
            if self.feedback ~= nil then self.feedback:SetMessage(self.transientFeedback, self.transientTone or "info") end
            self.semanticState = RSUI.State.Normal
            return true
        end
        if self.statusText ~= nil and tostring(self.statusText) ~= "" then
            if self.feedback ~= nil then self.feedback:SetMessage(self.statusText, self.statusTone) end
        elseif self.showDirty and self:IsDirty() then
            if self.feedback ~= nil then self.feedback:SetMessage("已修改", "caution") end
        elseif self.feedback ~= nil then
            self.feedback:Clear()
        end
        self.semanticState = self.enabled == false and RSUI.State.Disabled or RSUI.State.Normal
        return true
    end

    function c:SetControl(control)
        self.control = control
        if type(control) == "table" then self:AddChild(control) end
        return control
    end

    local BaseSetEnabled = c.SetEnabled
    function c:SetEnabled(enabled)
        local state, accepted, detail = BaseSetEnabled(self, enabled)
        if accepted ~= true then return state, false, detail end
        local childOk, childErr = self:EnsureChildEnabled(self.control, self.enabled, "field_control")
        if childOk ~= true then return state, false, childErr end
        return self.enabled, true, nil
    end

    function c:Render()
        RSUI:_Count(self.kind, "rendered", 1)
        if self.control ~= nil and type(self.control.Render) == "function" then self.control:Render() end
        self:SyncFeedback()
        return true
    end

    function c:ResolveFieldMetrics(controlHeight)
        local labelH = TextMetricHeight(self.label, self.headerHeight)
        local feedbackH = TextMetricHeight(self.feedback, self.headerHeight)
        local headerH = math.max(self.headerHeight, labelH, feedbackH)
        local controlH = math.max(self.controlMinHeight, N(controlHeight, self.controlPreferredHeight))
        local controlTop = math.max(self.controlTop, self.headerInsetY + headerH + self.headerGap)
        local hintH = self.hint ~= nil and TextMetricHeight(self.hint, 15) or 0
        local hintGap = self.hint ~= nil and self.hintGap or 0
        local requiredH = controlTop + controlH + hintGap + hintH + self.padding
        return {
            headerHeight = headerH, controlTop = controlTop, controlHeight = controlH,
            hintHeight = hintH, hintGap = hintGap, requiredHeight = requiredH,
        }
    end

    function c:Measure(availableWidth, availableHeight)
        local metrics = self:ResolveFieldMetrics(self.controlPreferredHeight)
        local desiredW = tonumber(self.spec.desiredWidth) or tonumber(self.spec.width) or width
        if tonumber(availableWidth) ~= nil and self.spec.allowOverflow ~= true then desiredW = math.min(desiredW, math.max(1, tonumber(availableWidth))) end
        local desiredH = math.max(1, metrics.requiredHeight)
        if tonumber(self.spec.minHeight) ~= nil then desiredH = math.max(desiredH, tonumber(self.spec.minHeight)) end
        if tonumber(self.spec.maxHeight) ~= nil then desiredH = math.min(desiredH, tonumber(self.spec.maxHeight)) end
        self.desiredWidth, self.desiredHeight = desiredW, desiredH
        self.measureDirty = false
        return desiredW, desiredH
    end

    function c:LayoutHeader(width, metrics)
        metrics = metrics or self:ResolveFieldMetrics(self.controlPreferredHeight)
        local feedbackW = math.max(70, math.min(self.feedbackWidth, width * 0.36))
        local labelW = math.max(1, width - self.padding * 3 - feedbackW)
        if self.label ~= nil then self.label:Layout(self.padding, self.headerInsetY, labelW, metrics.headerHeight) end
        if self.feedback ~= nil then self.feedback:Layout(width - feedbackW - self.padding, self.headerInsetY, feedbackW, metrics.headerHeight) end
        return feedbackW
    end

    function c:Layout(x, y, nextWidth, nextHeight)
        local w = math.max(1, N(nextWidth, self.width or width))
        local metrics = self:ResolveFieldMetrics(self.controlPreferredHeight)
        local h = math.max(1, N(nextHeight, self.height or metrics.requiredHeight))
        self:SetBounds(x, y, w, h)
        self:LayoutHeader(w, metrics)
        if self.control ~= nil and type(self.control.Layout) == "function" then
            self.control:Layout(self.padding, metrics.controlTop, math.max(1, w - self.padding * 2), metrics.controlHeight)
        end
        if self.hint ~= nil then
            self.hint:Layout(self.padding, metrics.controlTop + metrics.controlHeight + metrics.hintGap, math.max(1, w - self.padding * 2), metrics.hintHeight)
        end
        return h
    end

    return c
end

RSUI:RegisterType("Field", function(spec)
    return CreateFieldFrame("Field", spec)
end)

------------------------------------------------------------------------
-- ToggleField
------------------------------------------------------------------------
RSUI:RegisterType("ToggleField", function(spec)
    local c, err = CreateFieldFrame("ToggleField", spec)
    if c == nil then return nil, err end

    local control = RSUI:Toggle({
        id = spec.id .. "_control",
        parent = c,
        width = N(spec.controlWidth, 118),
        height = N(spec.controlHeight, Token("size.buttonH", 26)),
        binding = c.binding,
        onText = spec.onText or "已开启",
        offText = spec.offText or "已关闭",
        enabled = spec.enabled ~= false,
        commitOnFinal = spec.commitOnFinal == true,
        onChanged = function(value)
            c.transientFeedback, c.transientTone, c.localError = nil, nil, nil
            c:Render()
            NotifyField(spec, "onApplied", c:IsValid(), value, c)
        end,
    })
    if control == nil then
        c:Release()
        return nil, "toggle_field_control_create_failed"
    end
    c:SetControl(control)
    c.controlPreferredHeight = math.max(c.controlMinHeight, N(spec.controlHeight, Token("size.buttonH", 26)))

    function c:Layout(x, y, nextWidth, nextHeight)
        local w = math.max(1, N(nextWidth, self.width or 300))
        local metrics = self:ResolveFieldMetrics(self.controlPreferredHeight)
        local h = math.max(1, N(nextHeight, self.height or metrics.requiredHeight))
        self:SetBounds(x, y, w, h)
        self:LayoutHeader(w, metrics)
        local cw = math.max(92, math.min(N(spec.controlWidth, 128), w - self.padding * 2))
        self.control:Layout(w - cw - self.padding, metrics.controlTop, cw, metrics.controlHeight)
        if self.hint ~= nil then self.hint:Layout(self.padding, metrics.controlTop + metrics.controlHeight + metrics.hintGap, math.max(1, w - cw - self.padding * 3), metrics.hintHeight) end
        return h
    end

    c:SetEnabled(spec.enabled ~= false)
    c:Render()
    return c
end)

------------------------------------------------------------------------
-- NumericField: Slider + exact NumericInput; +/- step buttons are opt-in
------------------------------------------------------------------------
RSUI:RegisterType("NumericField", function(spec)
    local c, err = CreateFieldFrame("NumericField", spec)
    if c == nil then return nil, err end

    c.useSlider = spec.slider ~= false
    c.useStepButtons = spec.stepButtons == true
    c.useApplyButton = spec.applyButton == true
    -- Inline numeric rows are the compact settings contract used by dense V3
    -- pages/HUD appearance editors: Name + Slider + exact NumericInput.  The
    -- same Binding remains the only business mutation/persistence authority.
    c.inline = spec.inline == true
    c.baseMinimum = tonumber(spec.min) or 0
    c.baseMaximum = tonumber(spec.max)
    -- Sliders require a finite presentation range. Exact-entry-only fields may
    -- omit max (for example free window dimensions).
    if c.baseMaximum == nil and c.useSlider then c.baseMaximum = 100 end
    if c.baseMaximum ~= nil and c.baseMaximum < c.baseMinimum then c.baseMinimum, c.baseMaximum = c.baseMaximum, c.baseMinimum end
    c.minimum, c.maximum = c.baseMinimum, c.baseMaximum
    c.step = math.abs(tonumber(spec.step) or 1)
    c.stepOrigin = tonumber(spec.stepOrigin) or c.baseMinimum
    c.integer = spec.integer == true
    c.unit = tostring(spec.unit or spec.suffix or "")
    -- Adaptive range changes only the slider's presentation endpoints.  Domain
    -- setters remain authoritative for real business constraints: if a Feature
    -- clamps/rejects an out-of-range edit, we read that authoritative value back
    -- and do not expand the slider to the rejected request.
    c.adaptiveRange = c.useSlider and spec.adaptiveRange ~= false and spec.fixedRange ~= true
    c.hardMinimum = tonumber(spec.hardMin)
    c.hardMaximum = tonumber(spec.hardMax)
    if c.adaptiveRange ~= true then
        c.hardMinimum, c.hardMaximum = c.baseMinimum, c.baseMaximum
    elseif c.hardMinimum ~= nil and c.hardMaximum ~= nil and c.hardMaximum < c.hardMinimum then
        c.hardMinimum, c.hardMaximum = c.hardMaximum, c.hardMinimum
    end
    c.rangeKey = tostring(spec.rangeKey or spec.id or "")
    c.rangeStore = type(RSUI.NumericRangeStore) == "table" and RSUI.NumericRangeStore or nil

    local function Normalize(value)
        value = tonumber(value)
        if value == nil then return nil end
        value = RoundStep(value, c.stepOrigin, c.step)
        value = Clamp(value, c.hardMinimum, c.hardMaximum)
        if c.integer then value = math.floor(value + 0.5) end
        return value
    end

    local function Current()
        return Normalize(BindingValue(c.binding, c.baseMinimum)) or c.baseMinimum
    end

    -- Restore only outward expansion. Saved metadata can never shrink a newer
    -- code-defined base range after an addon update.
    if c.adaptiveRange == true and c.rangeStore ~= nil and type(c.rangeStore.Get) == "function" and c.rangeKey ~= "" then
        local savedMin, savedMax = c.rangeStore:Get(c.rangeKey)
        if tonumber(savedMin) ~= nil then c.minimum = math.min(c.minimum, tonumber(savedMin)) end
        if tonumber(savedMax) ~= nil and c.maximum ~= nil then c.maximum = math.max(c.maximum, tonumber(savedMax)) end
    end
    local initialCurrent = Current()
    if c.adaptiveRange == true then
        if initialCurrent < c.minimum then c.minimum = initialCurrent end
        if c.maximum ~= nil and initialCurrent > c.maximum then c.maximum = initialCurrent end
    end

    local function PersistRange(reason)
        if c.adaptiveRange ~= true or c.rangeStore == nil or type(c.rangeStore.Set) ~= "function" or c.rangeKey == "" then return true end
        local ok, rangeErr = c.rangeStore:Set(c.rangeKey, c.minimum, c.maximum, reason or ("numeric_range:" .. c.rangeKey))
        if ok ~= true and S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Warn) == "function" then
            S.DiagnosticsManager:Warn("rsui", "NUMERIC_RANGE_PERSIST_FAILED", "滑块动态范围保存失败，业务数值仍保持已提交状态", {
                id = c.rangeKey, minimum = c.minimum, maximum = c.maximum, error = tostring(rangeErr or "unknown"),
            })
        end
        return ok == true
    end

    local function EnsureRangeFor(value, persist, source)
        value = Normalize(value)
        if value == nil or c.adaptiveRange ~= true or c.maximum == nil then return false end
        local nextMin, nextMax = c.minimum, c.maximum
        if value < nextMin then nextMin = value end
        if value > nextMax then nextMax = value end
        if nextMin == c.minimum and nextMax == c.maximum then return false end
        if c.slider ~= nil then
            local rangeOk, rangeErr = c.slider:SetRange(nextMin, nextMax, c.step)
            if rangeOk ~= true then
                if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Warn) == "function" then
                    S.DiagnosticsManager:Warn("rsui", "NUMERIC_RANGE_NATIVE_UPDATE_FAILED", "滑块动态范围更新失败", {
                        id = c.rangeKey, minimum = nextMin, maximum = nextMax, error = tostring(rangeErr or "unknown"),
                    })
                end
                return false
            end
        end
        c.minimum, c.maximum = nextMin, nextMax
        if persist == true then PersistRange(source or "numeric_range_expand") end
        RSUI.metrics.numericRangeExpansions = (tonumber(RSUI.metrics.numericRangeExpansions) or 0) + 1
        return true
    end

    local function SyncControls(value, source, persistRange)
        value = Normalize(value) or Current()
        EnsureRangeFor(value, persistRange == true, source)
        source = tostring(source or "binding_refresh")
        if c.slider ~= nil then c.slider:Render(value, source) end
        if c.input ~= nil then c.input:Render(value, source) end
        return value
    end

    local function Applied(_, source)
        c.transientFeedback, c.transientTone, c.localError = nil, nil, nil
        -- A Feature setter may clamp the submitted draft. Always read back the
        -- authoritative Domain value before deciding whether the slider expands.
        local actual = Current()
        SyncControls(actual, "commit", source == "input" or source == "numeric_field" or source == "minus" or source == "plus")
        c:SyncFeedback()
        NotifyField(spec, "onApplied", c:IsValid(), actual, c)
    end

    if c.useStepButtons then
        c.minus = RSUI:Button({ id = spec.id .. "_minus", parent = c, text = "-", compact = true, width = 26, height = Token("size.buttonH", 26), buildOptional = true })
    end
    if c.useSlider then
        c.slider = RSUI:Slider({
            id = spec.id .. "_slider", parent = c,
            min = c.minimum, max = c.maximum, step = c.step, stepOrigin = c.stepOrigin, integer = c.integer,
            binding = c.binding,
            onPreview = function(value)
                if c.input ~= nil then c.input:Render(value, "interaction") end
                c:SetFeedback(spec.previewText or "预览", spec.previewTone or "info", true)
                NotifyField(spec, "onPreview", value, c)
            end,
            onChanged = function(value) Applied(value, "slider") end,
            enabled = spec.enabled ~= false,
            commitOnFinal = spec.commitOnFinal == true,
        })
    end
    c.input = RSUI:NumericInput({
        id = spec.id .. "_input", parent = c,
        min = c.hardMinimum, max = c.hardMaximum, step = c.step, stepOrigin = c.stepOrigin, integer = c.integer,
        suffix = c.unit, maxLength = tonumber(spec.maxLength) or 14,
        binding = c.binding, enabled = spec.enabled ~= false,
        commitOnFinal = spec.commitOnFinal == true,
        format = spec.format,
        onChanged = function(value) Applied(value, "input") end,
        onInvalid = function()
            c:SetFeedback(spec.invalidText or "请输入有效数字", "danger", true)
            NotifyField(spec, "onInvalid", c)
        end,
    })
    if c.input == nil then
        c:Release()
        return nil, "numeric_field_input_create_failed"
    end
    function c:ApplyDraft(source)
        if self.enabled == false or self.input == nil then return false end
        local actionSource = tostring(source or "apply_button")
        local draft = type(self.input.GetDraftNumber) == "function" and self.input:GetDraftNumber() or nil
        local actual = Current()
        -- On RU a button click can deliver EditBox LostFocus before Button
        -- OnClick. LostFocus already committed the same value in that ordering;
        -- avoid a duplicate Domain/Persistence write. If focus is still owned by
        -- the EditBox, CommitAndEndEditing is the authoritative path.
        if self.input:IsEditing() ~= true and draft ~= nil and tonumber(draft) == tonumber(actual) then
            if type(self.input.EndEditing) == "function" then self.input:EndEditing(actionSource .. ":already_committed") end
            SyncControls(actual, "commit", true)
            return true
        end
        if type(self.input.CommitAndEndEditing) == "function" then
            return self.input:CommitAndEndEditing(actionSource)
        end
        if type(self.input.Submit) == "function" then return self.input:Submit(actionSource) end
        return false
    end
    if c.useApplyButton then
        c.apply = RSUI:Button({
            id = spec.id .. "_apply", parent = c, text = tostring(spec.applyText or "应用"), compact = true,
            width = math.max(34, N(spec.applyButtonWidth, 40)), height = N(spec.controlHeight, Token("size.buttonH", 24)),
            enabled = spec.enabled ~= false,
            onClick = function()
                -- Explicit Apply is the reliable RU commit affordance. Enter is
                -- still accepted when the client emits it, but business commit
                -- never depends on an unverified key event.
                return c:ApplyDraft("apply_button")
            end,
        })
        if c.apply == nil then
            c:Release()
            return nil, "numeric_field_apply_create_failed"
        end
    end
    if c.useStepButtons then
        c.plus = RSUI:Button({ id = spec.id .. "_plus", parent = c, text = "+", compact = true, width = 26, height = Token("size.buttonH", 26), buildOptional = true })
    end
    -- +/- are a convenience pair. If one optional native button cannot be
    -- created, hide/release the survivor instead of exposing a one-sided dead or
    -- misleading control; exact NumericInput remains the authoritative path.
    if c.useStepButtons and (c.minus == nil or c.plus == nil) then
        if c.minus ~= nil and type(c.minus.Release) == "function" then c.minus:Release() end
        if c.plus ~= nil and type(c.plus.Release) == "function" then c.plus:Release() end
        c.minus, c.plus = nil, nil
    end
    c:SetControl(c.input)
    c.controlPreferredHeight = math.max(c.controlMinHeight, N(spec.controlHeight, Token("size.inputH", 24)))
    if c.minus ~= nil then c:AddChild(c.minus) end
    if c.slider ~= nil then c:AddChild(c.slider) end
    if c.plus ~= nil then c:AddChild(c.plus) end
    if c.apply ~= nil then c:AddChild(c.apply) end
    if c.inline then
        -- Validation remains available through the Binding state, but compact
        -- rows deliberately do not reserve a second text line.  This prevents
        -- dense numeric settings from becoming a grid of oversized cards.
        if c.feedback ~= nil then c.feedback:SetVisibility("collapsed") end
        if c.hint ~= nil then c.hint:SetVisibility("collapsed") end
    end

    function c:Apply(value, source)
        if self.enabled == false then return false end
        local normalized = Normalize(value)
        if normalized == nil then self:SetFeedback(spec.invalidText or "请输入有效数字", "danger", true); return false end
        local previous = BindingValue(self.binding, normalized)
        local actionSource = tostring(source or "numeric_field")
        local ok = self.binding:Set(normalized, true, actionSource, previous)
        if ok and spec.commitOnFinal == true and type(self.binding.Commit) == "function" then ok = self.binding:Commit(actionSource) end
        if ok then self.transientFeedback, self.transientTone, self.localError = nil, nil, nil end
        local actual = Current()
        SyncControls(actual, "commit", ok == true)
        self:SyncFeedback()
        NotifyField(spec, "onApplied", ok, actual, self)
        return ok
    end

    function c:GetRange() return self.minimum, self.maximum end
    function c:ExpandRangeTo(value, persist)
        return EnsureRangeFor(value, persist == true, "numeric_field_api")
    end

    if c.minus ~= nil and c.plus ~= nil then
        c.minus.spec.onClick = function() return c:Apply(Current() - c.step, "minus") end
        c.plus.spec.onClick = function() return c:Apply(Current() + c.step, "plus") end
        -- Step buttons are optional convenience controls. Exact entry remains
        -- the authority and is always visible.
        c.minus.Click = function(self) if self.enabled == false then return false end return c:Apply(Current() - c.step, "minus") end
        c.plus.Click = function(self) if self.enabled == false then return false end return c:Apply(Current() + c.step, "plus") end
    end

    local BaseMeasure = c.Measure
    function c:Measure(availableWidth, availableHeight)
        if not self.inline then return BaseMeasure(self, availableWidth, availableHeight) end
        local desiredW = tonumber(self.spec.desiredWidth) or tonumber(self.spec.width) or 300
        if tonumber(availableWidth) ~= nil and self.spec.allowOverflow ~= true then desiredW = math.min(desiredW, math.max(1, tonumber(availableWidth))) end
        local labelH = TextMetricHeight(self.label, 16)
        local desiredH = math.max(labelH, self.controlPreferredHeight) + self.padding * 2
        if tonumber(self.spec.minHeight) ~= nil then desiredH = math.max(desiredH, tonumber(self.spec.minHeight)) end
        if tonumber(self.spec.maxHeight) ~= nil then desiredH = math.min(desiredH, tonumber(self.spec.maxHeight)) end
        self.desiredWidth, self.desiredHeight = desiredW, math.max(1, desiredH)
        self.measureDirty = false
        return self.desiredWidth, self.desiredHeight
    end

    local BaseSetEnabled = c.SetEnabled
    function c:SetEnabled(enabled)
        local state, accepted, detail = BaseSetEnabled(self, enabled)
        if accepted ~= true then return state, false, detail end
        local children = {
            { self.minus, "numeric_minus" },
            { self.slider, "numeric_slider" },
            { self.input, "numeric_input" },
            { self.plus, "numeric_plus" },
            { self.apply, "numeric_apply" },
        }
        for _, entry in ipairs(children) do
            local childOk, childErr = self:EnsureChildEnabled(entry[1], self.enabled, entry[2])
            if childOk ~= true then return state, false, childErr end
        end
        return self.enabled, true, nil
    end

    function c:Render()
        RSUI:_Count(self.kind, "rendered", 1)
        local value = SyncControls(Current(), "binding_refresh", false)
        self:SyncFeedback()
        return value
    end

    function c:Layout(x, y, nextWidth, nextHeight)
        local w = math.max(1, N(nextWidth, self.width or 300))
        if self.inline then
            local labelH = TextMetricHeight(self.label, 16)
            local controlH = math.max(self.controlMinHeight, self.controlPreferredHeight)
            local naturalH = math.max(labelH, controlH) + self.padding * 2
            local h = math.max(1, N(nextHeight, self.height or naturalH))
            self:SetBounds(x, y, w, h)
            local gap = math.max(2, N(spec.controlGap, Token("spacing.xs", 5)))
            -- Compact numeric rows now reserve an explicit Apply action to the
            -- right of the exact editor.  Width allocation remains single-row
            -- and responsive: on narrow pair cards the label/input/apply floors
            -- shrink first, while the slider keeps a usable drag target.  This
            -- avoids forcing every consumer into a new two-line layout.
            local hasApply = self.apply ~= nil
            local narrow = hasApply and w < N(spec.compactApplyNarrowWidth, 220)
            if narrow then gap = math.min(gap, 3) end
            local labelMinW = math.max(1, N(spec.labelMinWidth, narrow and 28 or 44))
            local labelShare = math.max(0.10, math.min(0.70, N(spec.labelMaxShare, narrow and 0.25 or 0.34)))
            local labelW = math.max(labelMinW, math.min(N(spec.labelWidth, narrow and 48 or 78), w * labelShare))
            local buttonW = N(spec.stepButtonWidth, 24)
            local inputMinW = math.max(42, N(spec.inputMinWidth, narrow and 42 or 54))
            local desiredInputW = math.max(inputMinW, N(spec.inputWidth, narrow and 48 or 76))
            local sliderMinW = math.max(16, N(spec.sliderMinWidth, narrow and 18 or 24))
            local sliderPreferredShare = math.max(0, math.min(0.80, N(spec.sliderPreferredShare, 0)))
            local applyW = hasApply and math.max(34, N(spec.applyButtonWidth, narrow and 36 or 40)) or 0
            local innerW = math.max(1, w - self.padding * 2)
            local stepButtonsW = self.useStepButtons and (buttonW * 2 + gap * 2) or 0
            local sliderGapW = self.slider ~= nil and gap or 0
            local applyGapW = hasApply and gap or 0
            local afterLabel = math.max(1, innerW - labelW - gap - stepButtonsW - sliderGapW - applyW - applyGapW)
            local desiredSliderW = self.slider ~= nil and math.max(sliderMinW, math.floor(innerW * sliderPreferredShare + 0.5)) or 0
            -- Exact editor yields before the slider, but never below the Native
            -- NumericInput 42px technical floor.  If a consumer is pathologically
            -- narrow, clamp label width before allowing sibling overlap.
            local minimumControlsW = (self.slider ~= nil and sliderMinW or 0) + inputMinW
            if afterLabel < minimumControlsW then
                local deficit = minimumControlsW - afterLabel
                local reducedLabel = math.max(18, labelW - deficit)
                afterLabel = afterLabel + (labelW - reducedLabel)
                labelW = reducedLabel
            end
            local maxSliderW = self.slider ~= nil and math.max(1, afterLabel - inputMinW) or 0
            local sliderW = self.slider ~= nil and math.max(1, math.min(math.max(sliderMinW, desiredSliderW, afterLabel - desiredInputW), maxSliderW)) or 0
            local inputW = math.max(1, math.min(desiredInputW, afterLabel - sliderW))
            local labelY = math.max(0, math.floor((h - labelH) * 0.5))
            local controlY = math.max(0, math.floor((h - controlH) * 0.5))
            local xx = self.padding
            if self.label ~= nil then self.label:Layout(xx, labelY, labelW, labelH) end
            xx = xx + labelW + gap
            if self.minus ~= nil then self.minus:Layout(xx, controlY, buttonW, controlH); xx = xx + buttonW + gap end
            if self.slider ~= nil then self.slider:Layout(xx, controlY + 2, sliderW, math.max(14, controlH - 4)); xx = xx + sliderW + gap end
            self.input:Layout(xx, controlY, inputW, controlH); xx = xx + inputW
            if self.plus ~= nil then xx = xx + gap; self.plus:Layout(xx, controlY, buttonW, controlH); xx = xx + buttonW end
            if self.apply ~= nil then xx = xx + gap; self.apply:Layout(xx, controlY, applyW, controlH) end
            return h
        end
        local metrics = self:ResolveFieldMetrics(self.controlPreferredHeight)
        local h = math.max(1, N(nextHeight, self.height or metrics.requiredHeight))
        self:SetBounds(x, y, w, h)
        self:LayoutHeader(w, metrics)
        local gap = N(spec.controlGap, Token("spacing.xs", 4))
        local buttonW = N(spec.stepButtonWidth, 26)
        local available = math.max(1, w - self.padding * 2)
        local controlH = metrics.controlHeight
        local stepButtonsW = self.useStepButtons and (buttonW * 2 + gap * 2) or 0
        local betweenSliderInput = self.slider ~= nil and gap or 0
        local applyW = self.apply ~= nil and math.max(34, N(spec.applyButtonWidth, 40)) or 0
        local applyGapW = self.apply ~= nil and gap or 0
        local usable = math.max(1, available - stepButtonsW - betweenSliderInput - applyW - applyGapW)
        local desiredInputW = math.max(48, N(spec.inputWidth, 84))
        local inputW = math.max(1, math.min(desiredInputW, usable))
        local sliderW = self.slider ~= nil and math.max(1, usable - inputW) or 0
        local xx = self.padding
        if self.minus ~= nil then self.minus:Layout(xx, metrics.controlTop, buttonW, controlH); xx = xx + buttonW + gap end
        if self.slider ~= nil then self.slider:Layout(xx, metrics.controlTop + 2, sliderW, math.max(14, controlH - 4)); xx = xx + sliderW + gap end
        self.input:Layout(xx, metrics.controlTop, inputW, controlH); xx = xx + inputW
        if self.plus ~= nil then xx = xx + gap; self.plus:Layout(xx, metrics.controlTop, buttonW, controlH); xx = xx + buttonW end
        if self.apply ~= nil then xx = xx + gap; self.apply:Layout(xx, metrics.controlTop, applyW, controlH) end
        if self.hint ~= nil then
            self.hint:Layout(self.padding, metrics.controlTop + controlH + metrics.hintGap, math.max(1, w - self.padding * 2), metrics.hintHeight)
        end
        return h
    end

    c:SetEnabled(spec.enabled ~= false)
    c:Render()
    return c
end, function(spec)
    if spec.slider ~= false then
        local minimum, maximum = tonumber(spec.min), tonumber(spec.max)
        if minimum == nil or maximum == nil then return false, "numeric_slider_range_required" end
        if minimum == maximum then return false, "numeric_slider_range_empty" end
    end
    if spec.step ~= nil and (tonumber(spec.step) == nil or tonumber(spec.step) == 0) then return false, "numeric_step_invalid" end
    return true
end)

------------------------------------------------------------------------
-- DropdownField
------------------------------------------------------------------------
RSUI:RegisterType("DropdownField", function(spec)
    local c, err = CreateFieldFrame("DropdownField", spec)
    if c == nil then return nil, err end

    local control = RSUI:Dropdown({
        id = spec.id .. "_control",
        parent = c,
        width = N(spec.controlWidth, 180),
        height = N(spec.controlHeight, Token("size.buttonH", 26)),
        popupWidth = spec.popupWidth,
        maxVisible = tonumber(spec.maxVisible) or 8,
        items = NormalizeDropdownItems(spec.items or spec.options or spec.values),
        binding = c.binding,
        enabled = spec.enabled ~= false,
        commitOnFinal = spec.commitOnFinal == true,
        onChanged = function(value, item)
            c.transientFeedback, c.transientTone, c.localError = nil, nil, nil
            c:Render()
            NotifyField(spec, "onApplied", c:IsValid(), value, item, c)
        end,
    })
    if control == nil then
        c:Release()
        return nil, "dropdown_field_control_create_failed"
    end
    c:SetControl(control)
    c.controlPreferredHeight = math.max(c.controlMinHeight, N(spec.controlHeight, Token("size.buttonH", 26)))

    function c:SetItems(items)
        spec.items = items
        return self.control:SetItems(NormalizeDropdownItems(items))
    end

    function c:Layout(x, y, nextWidth, nextHeight)
        local w = math.max(1, N(nextWidth, self.width or 300))
        local metrics = self:ResolveFieldMetrics(self.controlPreferredHeight)
        local h = math.max(1, N(nextHeight, self.height or metrics.requiredHeight))
        self:SetBounds(x, y, w, h)
        self:LayoutHeader(w, metrics)
        local cw = math.max(110, math.min(N(spec.controlWidth, 190), w - self.padding * 2))
        self.control:Layout(w - cw - self.padding, metrics.controlTop, cw, metrics.controlHeight)
        if self.hint ~= nil then self.hint:Layout(self.padding, metrics.controlTop + metrics.controlHeight + metrics.hintGap, math.max(1, w - cw - self.padding * 3), metrics.hintHeight) end
        return h
    end

    c:SetEnabled(spec.enabled ~= false)
    c:Render()
    return c
end)

------------------------------------------------------------------------
-- FieldGroup: responsive field collection. Layout is explicit/low-frequency;
-- there is no per-frame tree reconciliation.
------------------------------------------------------------------------
RSUI:RegisterType("FieldGroup", function(spec)
    local width = math.max(1, N(spec.width, 300))
    local height = math.max(1, N(spec.height, 10))
    local root = UI:CreateEmptyWidget(spec.parent, spec.id, N(spec.x, 0), N(spec.y, 0), width, height, false)
    if root == nil then return nil, "field_group_create_failed" end
    local c = RSUI:NewComponent("FieldGroup", spec, root)
    c.fields = {}
    c.fieldById = {}
    c.minCellWidth = N(spec.minCellWidth, 240)
    c.minColumns = math.max(1, math.floor(N(spec.minColumns, 1)))
    c.maxColumns = math.max(c.minColumns, math.floor(N(spec.maxColumns, 2)))
    c.fieldHeight = N(spec.fieldHeight, Token("component.form.fieldH", 52))
    c.gapX = N(spec.gapX, Token("component.grid.gapX", 8))
    c.gapY = N(spec.gapY, Token("component.grid.gapY", 8))
    c.lastColumns = 1
    c.usedHeight = 0

    function c:AddField(fieldOrSpec)
        local field = fieldOrSpec
        if type(fieldOrSpec) == "table" and not RSUI:IsComponent(fieldOrSpec) then
            local descriptor = {}
            for key, value in pairs(fieldOrSpec) do descriptor[key] = value end
            local typeName = descriptor.type or descriptor.kind or "Field"
            descriptor.type, descriptor.kind = nil, nil
            if descriptor.id ~= nil and self.fieldById[tostring(descriptor.id)] ~= nil then return self.fieldById[tostring(descriptor.id)] end
            descriptor.parent = self
            field = RSUI:Create(typeName, descriptor)
        end
        if RSUI:IsComponent(field) then
            for _, existing in ipairs(self.fields) do if existing == field then return field end end
            self.fields[#self.fields + 1] = field
            self.fieldById[tostring(field.id)] = field
            self:AddChild(field)
        end
        return field
    end

    function c:GetFields()
        return self.fields
    end

    function c:FindField(id)
        return self.fieldById[tostring(id or "")]
    end

    local BaseSetEnabled = c.SetEnabled
    function c:SetEnabled(enabled)
        local state, accepted, detail = BaseSetEnabled(self, enabled)
        if accepted ~= true then return state, false, detail end
        for index, field in ipairs(self.fields) do
            local childOk, childErr = self:EnsureChildEnabled(field, self.enabled, "field_group_" .. tostring(index))
            if childOk ~= true then return state, false, childErr end
        end
        return self.enabled, true, nil
    end

    function c:Render()
        RSUI:_Count(self.kind, "rendered", 1)
        for _, field in ipairs(self.fields) do if type(field.Render) == "function" then field:Render() end end
        return true
    end

    -- Measure-only height computation. UsedHeight in Grid depends solely on
    -- the placed span index, cell height and gap, so the natural height can be
    -- derived without any native write. Without this, containers above (Scroll
    -- Box / TransformInspector) measured the STALE post-layout height and
    -- stacked the next section on top of newly-expanded content.
    function c:Measure(availableWidth, availableHeight)
        local w = math.max(1, N(availableWidth, self.width or width))
        local resolvedFieldHeight = self.fieldHeight
        for _, field in ipairs(self.fields) do
            if field.visible ~= false and type(field.Measure) == "function" then
                local ok, _, desiredH = pcall(function() return field:Measure(w, nil) end)
                if ok and tonumber(desiredH) ~= nil then resolvedFieldHeight = math.max(resolvedFieldHeight, tonumber(desiredH)) end
            end
        end
        if Layout == nil or type(Layout.ResolveResponsiveColumns) ~= "function" then
            self.desiredWidth, self.desiredHeight, self.measureDirty = w, math.max(1, self.usedHeight or 1), false
            return w, math.max(1, self.usedHeight or 1)
        end
        local columns = Layout:ResolveResponsiveColumns(w, {
            minCellWidth = self.minCellWidth, gapX = self.gapX,
            minColumns = self.minColumns, maxColumns = self.maxColumns,
        })
        local index = 0
        for _, field in ipairs(self.fields) do
            if field.visible ~= false then
                local span = math.max(1, math.min(columns, math.floor(N(field.spec and field.spec.colSpan, 1))))
                local col = index % columns
                index = index + math.max(1, math.min(columns - col, span))
            end
        end
        local rows = math.ceil(index / columns)
        local usedHeight = rows > 0 and (rows * resolvedFieldHeight + (rows - 1) * self.gapY) or 0
        self.desiredWidth, self.desiredHeight, self.measureDirty = w, math.max(1, usedHeight), false
        return w, math.max(1, usedHeight)
    end

    function c:Layout(x, y, nextWidth, nextHeight)
        local w = math.max(1, N(nextWidth, self.width or width))
        UI:SetAnchor(self.root, self.parent, N(x, 0), N(y, 0), self.owner)
        if Layout == nil or type(Layout.ResponsiveGrid) ~= "function" then return 0 end
        local resolvedFieldHeight = self.fieldHeight
        for _, field in ipairs(self.fields) do
            if field.visible ~= false and type(field.Measure) == "function" then
                local ok, _, desiredH = pcall(function() return field:Measure(w, nil) end)
                if ok and tonumber(desiredH) ~= nil then resolvedFieldHeight = math.max(resolvedFieldHeight, tonumber(desiredH)) end
            end
        end
        local grid = Layout:ResponsiveGrid(self.root, {
            x = 0, y = 0, width = w,
            minCellWidth = self.minCellWidth, minColumns = self.minColumns, maxColumns = self.maxColumns,
            cellHeight = resolvedFieldHeight, gapX = self.gapX, gapY = self.gapY,
            owner = self.owner,
        })
        for _, field in ipairs(self.fields) do
            if field.visible ~= false and field.root ~= nil then
                local span = math.max(1, math.min(grid.columns, math.floor(N(field.spec and field.spec.colSpan, 1))))
                local _, fx, fy = grid:Add(field.root, { colSpan = span, height = resolvedFieldHeight, owner = self.owner })
                local fw = grid.cellWidth * span + grid.gapX * (span - 1)
                field:Layout(fx, fy, fw, resolvedFieldHeight)
            end
        end
        self.lastColumns = grid.columns
        self.usedHeight = grid:UsedHeight()
        UI:SetExtent(self.root, w, math.max(1, self.usedHeight), self.owner)
        self:CommitLayoutState(N(x, 0), N(y, 0), w, math.max(1, self.usedHeight))
        RSUI:_Count(self.kind, "layouts", 1)
        return self.usedHeight
    end

    for index, fieldSpec in ipairs(type(spec.fields) == "table" and spec.fields or {}) do
        local field = c:AddField(fieldSpec)
        if field == nil then
            c:Release()
            return nil, "field_group_initial_field_create_failed:" .. tostring(index)
        end
    end
    return c
end)

------------------------------------------------------------------------
-- FormSection
------------------------------------------------------------------------
RSUI:RegisterType("FormSection", function(spec)
    local width = math.max(1, N(spec.width, 300))
    local height = math.max(1, N(spec.height, 100))
    local raw = RSUI.ContainerSurface and RSUI.ContainerSurface:CreateSection(spec.parent, spec.id, {
        x = N(spec.x, 0), y = N(spec.y, 0), width = width, height = height,
        title = spec.title or "", titleFontSize = spec.titleFontSize,
        headerHeight = spec.headerHeight, padding = spec.padding,
        gradient = spec.gradient, accentStrip = spec.accentStrip, tone = spec.tone,
    })
    if raw == nil or raw.root == nil then return nil, "form_section_create_failed" end
    local c = RSUI:NewComponent("FormSection", spec, raw.root)
    c.raw = raw
    c.padding = raw.padding or N(spec.padding, Token("component.card.padding", 10))
    c.headerHeight = raw.headerHeight or N(spec.headerHeight, Token("size.sectionHeaderH", 28))
    c.fields = {}
    c.group = RSUI:FieldGroup({
        id = spec.id .. "_fields",
        parent = c,
        minCellWidth = N(spec.minCellWidth, 240),
        minColumns = N(spec.minColumns, 1), maxColumns = N(spec.maxColumns, 2),
        fieldHeight = N(spec.fieldHeight, Token("component.form.fieldH", 52)),
        gapX = spec.gapX, gapY = spec.gapY,
    })
    if c.group == nil then
        c:Release()
        return nil, "form_section_field_group_create_failed"
    end

    function c:SetTitle(text)
        return self.raw:SetTitle(text)
    end

    function c:GetContentRoot()
        return self.group and self.group.root or self.root
    end

    function c:AddField(fieldSpec)
        local field = self.group:AddField(fieldSpec)
        if field ~= nil then
            local exists = false
            for _, current in ipairs(self.fields) do if current == field then exists = true break end end
            if not exists then self.fields[#self.fields + 1] = field end
            if self.formOwner ~= nil and type(self.formOwner.RegisterField) == "function" then self.formOwner:RegisterField(field) end
        end
        return field
    end

    function c:GetFields()
        return self.fields
    end

    function c:FindField(id)
        return self.group and self.group:FindField(id) or nil
    end

    local BaseSetEnabled = c.SetEnabled
    function c:SetEnabled(enabled)
        local state, accepted, detail = BaseSetEnabled(self, enabled)
        if accepted ~= true then return state, false, detail end
        local childOk, childErr = self:EnsureChildEnabled(self.group, self.enabled, "form_section_group")
        if childOk ~= true then return state, false, childErr end
        return self.enabled, true, nil
    end

    function c:Render()
        RSUI:_Count(self.kind, "rendered", 1)
        if self.group ~= nil then self.group:Render() end
        return true
    end

    -- Pure content-height measurement (no native writes): mirrors Layout's
    -- content origin + group height + padding exactly.
    function c:Measure(availableWidth, availableHeight)
        local w = math.max(1, N(availableWidth, self.width or width))
        local contentX, contentY = self.raw:ContentOrigin()
        local contentW = math.max(1, w - contentX * 2)
        local _, groupH = self.group:Measure(contentW, nil)
        local desired = math.max(N(spec.minHeight, 0), contentY + N(groupH, 0) + self.padding)
        self.desiredWidth, self.desiredHeight, self.measureDirty = w, desired, false
        return w, desired
    end

    function c:Layout(x, y, nextWidth, nextHeight)
        local w = math.max(1, N(nextWidth, self.width or width))
        local contentX, contentY = self.raw:ContentOrigin()
        local contentW = math.max(1, w - contentX * 2)
        local used = self.group:Layout(contentX, contentY, contentW, math.max(1, N(nextHeight, height) - contentY - self.padding))
        local desired = math.max(N(spec.minHeight, 0), contentY + used + self.padding)
        self.raw:SetExtent(w, desired)
        UI:SetAnchor(self.root, self.parent, N(x, 0), N(y, 0), self.owner)
        self:CommitLayoutState(N(x, 0), N(y, 0), w, desired)
        RSUI:_Count(self.kind, "layouts", 1)
        return desired
    end

    for index, fieldSpec in ipairs(type(spec.fields) == "table" and spec.fields or {}) do
        local field = c:AddField(fieldSpec)
        if field == nil then
            c:Release()
            return nil, "form_section_initial_field_create_failed:" .. tostring(index)
        end
    end
    return c
end)

------------------------------------------------------------------------
-- Form
------------------------------------------------------------------------
RSUI:RegisterType("Form", function(spec)
    local width = math.max(1, N(spec.width, 400))
    local root = UI:CreateEmptyWidget(spec.parent, spec.id, N(spec.x, 0), N(spec.y, 0), width, math.max(1, N(spec.height, 10)), false)
    if root == nil then return nil, "form_create_failed" end
    local c = RSUI:NewComponent("Form", spec, root)
    c.sections = {}
    c.fields = {}
    c.fieldById = {}
    c.gap = N(spec.sectionGap, Token("spacing.md", 12))
    c.stateSummary = { dirty = 0, errors = 0, fields = 0, valid = true }

    function c:RegisterField(field)
        if not RSUI:IsComponent(field) then return nil end
        local id = tostring(field.id or "")
        if id ~= "" and self.fieldById[id] == field then return field end
        for _, current in ipairs(self.fields) do if current == field then return field end end
        self.fields[#self.fields + 1] = field
        if id ~= "" then self.fieldById[id] = field end
        return field
    end

    function c:FindField(id)
        return self.fieldById[tostring(id or "")]
    end

    function c:AddSection(sectionSpec)
        sectionSpec = type(sectionSpec) == "table" and sectionSpec or {}
        local copy = {}
        for key, value in pairs(sectionSpec) do copy[key] = value end
        copy.id = copy.id or (self.id .. "_section_" .. tostring(#self.sections + 1))
        copy.parent = self
        local section = RSUI:FormSection(copy)
        if section ~= nil then
            section.formOwner = self
            self.sections[#self.sections + 1] = section
            for _, field in ipairs(section:GetFields()) do self:RegisterField(field) end
        end
        return section
    end

    function c:AddField(section, fieldSpec)
        if not RSUI:IsComponent(section) or section.kind ~= "FormSection" then return nil end
        local field = section:AddField(fieldSpec)
        if field ~= nil then self:RegisterField(field) end
        return field
    end

    function c:GetFields()
        return self.fields
    end

    function c:RefreshState(notify)
        local dirty, errors = 0, 0
        for _, field in ipairs(self.fields) do
            if type(field.IsDirty) == "function" and field:IsDirty() then dirty = dirty + 1 end
            if type(field.GetError) == "function" and field:GetError() ~= nil then errors = errors + 1 end
        end
        local previous = self.stateSummary
        local changed = previous.dirty ~= dirty or previous.errors ~= errors or previous.fields ~= #self.fields
        self.stateSummary = { dirty = dirty, errors = errors, fields = #self.fields, valid = errors == 0 }
        if changed and notify ~= false and type(spec.onStateChanged) == "function" then
            RSUI:Callback("rsui_form:" .. self.id .. ":state", spec.onStateChanged, self.stateSummary, self)
        end
        return self.stateSummary
    end

    function c:GetState()
        return self:RefreshState(false)
    end

    function c:IsDirty()
        return self:RefreshState(false).dirty > 0
    end

    function c:IsValid()
        return self:RefreshState(false).errors == 0
    end

    local BaseSetEnabled = c.SetEnabled
    function c:SetEnabled(enabled)
        local state, accepted, detail = BaseSetEnabled(self, enabled)
        if accepted ~= true then return state, false, detail end
        for index, section in ipairs(self.sections) do
            local childOk, childErr = self:EnsureChildEnabled(section, self.enabled, "form_section_" .. tostring(index))
            if childOk ~= true then return state, false, childErr end
        end
        return self.enabled, true, nil
    end

    function c:Render()
        RSUI:_Count(self.kind, "rendered", 1)
        for _, section in ipairs(self.sections) do if type(section.Render) == "function" then section:Render() end end
        self:RefreshState(true)
        return true
    end

    function c:Refresh()
        return self:Render()
    end

    function c:CommitDirty(source)
        local visited, committed = {}, 0
        for _, field in ipairs(self.fields) do
            local binding = field.binding
            if binding ~= nil and not visited[binding] and type(binding.IsDirty) == "function" and binding:IsDirty() then
                visited[binding] = true
                if type(binding.Commit) == "function" and binding:Commit(source or "form") then committed = committed + 1 end
            end
        end
        self:RefreshState(true)
        return committed
    end

    -- Real content measurement: the TransformInspector inside the HUD-layout
    -- ScrollBox measured its stale post-layout height before this existed, so
    -- expanding the anchor section pushed the NEXT section on top of it.
    function c:Measure(availableWidth, availableHeight)
        local w = math.max(1, N(availableWidth, self.width or width))
        local cursor, sections = 0, 0
        for _, section in ipairs(self.sections) do
            if section.visible ~= false then
                local _, h = section:Measure(w, nil)
                cursor = cursor + N(h, 0) + self.gap
                sections = sections + 1
            end
        end
        local usedHeight = math.max(1, cursor - (sections > 0 and self.gap or 0))
        self.desiredWidth, self.desiredHeight, self.measureDirty = w, usedHeight, false
        return w, usedHeight
    end

    function c:Layout(x, y, nextWidth, nextHeight)
        local w = math.max(1, N(nextWidth, self.width or width))
        local cursor = 0
        for _, section in ipairs(self.sections) do
            local used = section:Layout(0, cursor, w, nextHeight)
            cursor = cursor + N(used, 0) + self.gap
        end
        local usedHeight = math.max(1, cursor - (#self.sections > 0 and self.gap or 0))
        self:SetBounds(x, y, w, usedHeight)
        self.width, self.height = w, usedHeight
        return usedHeight
    end

    for index, sectionSpec in ipairs(type(spec.sections) == "table" and spec.sections or {}) do
        local section = c:AddSection(sectionSpec)
        if section == nil then
            c:Release()
            return nil, "form_initial_section_create_failed:" .. tostring(index)
        end
    end
    c:RefreshState(false)
    return c
end)

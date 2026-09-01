------------------------------------------------------------------------
-- Replicated Suite - RSUI Primitive Components v1.1
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

local function NativeFontSize(baseSize, widget)
    local localScale = tonumber(widget and widget.rsLocalFontScale) or 1.0
    if S.Theme ~= nil and type(S.Theme.ResolveFontSize) == "function" then return S.Theme:ResolveFontSize(baseSize, localScale) end
    return math.max(1, (tonumber(baseSize) or Token("font.body", 11)) * localScale)
end

local function CommonSpec(spec, defaultWidth, defaultHeight)
    spec.x = tonumber(spec.x) or 0
    spec.y = tonumber(spec.y) or 0
    spec.width = math.max(1, tonumber(spec.width) or defaultWidth)
    spec.height = math.max(1, tonumber(spec.height) or defaultHeight)
    return spec
end

RSUI:RegisterType("Text", function(spec)
    CommonSpec(spec, 120, Token("size.rowH", 28))
    local widget = UI:CreateLabel(spec.parent, spec.id, tostring(spec.text or ""), spec.x, spec.y, spec.width, spec.height,
        tonumber(spec.fontSize) or Token("font.body", 11), spec.tone or "default", spec.align or ALIGN_LEFT, spec.shadow)
    if widget == nil then return nil, "label_create_failed" end
    local c = RSUI:NewComponent("Text", spec, widget)
    function c:SetText(text) return UI:SetText(self.root, tostring(text or ""), self.owner) end
    function c:SetTone(tone) self.state.tone = tostring(tone or "default"); return UI:SetLabelTone(self.root, self.state.tone, self.owner) end
    function c:SetFontSize(size) return UI:SetFontSize(self.root, NativeFontSize(size, self.root), self.owner) end
    function c:Render(state)
        state = type(state) == "table" and state or {}
        RSUI:_Count(self.kind, "rendered", 1)
        if state.text ~= nil then self:SetText(state.text) end
        if state.tone ~= nil then self:SetTone(state.tone) end
        if state.visible ~= nil then self:SetVisible(state.visible) end
        return true
    end
    c.state.tone = tostring(spec.tone or "default")
    return c
end)

RSUI:RegisterType("Panel", function(spec)
    CommonSpec(spec, 160, 80)
    local widget = UI:CreatePanel(spec.parent, spec.id, spec.x, spec.y, spec.width, spec.height, spec.variant or spec.kind or "card", {
        gradient = spec.gradient,
        gradientKind = spec.gradientKind,
        accentStrip = spec.accentStrip,
    })
    if widget == nil then return nil, "panel_create_failed" end
    local c = RSUI:NewComponent("Panel", spec, widget)
    c.padding = tonumber(spec.padding) or Token("component.card.padding", 10)
    function c:ContentOrigin() return self.padding, self.padding end
    return c
end)

RSUI:RegisterType("Divider", function(spec)
    CommonSpec(spec, 160, math.max(1, tonumber(spec.thickness) or 1))
    local root = UI:CreateEmptyWidget(spec.parent, spec.id, spec.x, spec.y, spec.width, spec.height, false)
    if root == nil then return nil, "divider_create_failed" end
    local color = Tokens.Color and Tokens:Color(spec.tone or "muted", { 0.35, 0.40, 0.46, 0.65 }) or { 0.35, 0.40, 0.46, 0.65 }
    local fill = root.CreateColorDrawable and root:CreateColorDrawable(color[1] or 0.35, color[2] or 0.40, color[3] or 0.46, tonumber(spec.alpha) or color[4] or 0.65, "artwork") or nil
    if fill ~= nil and fill.AddAnchor ~= nil then fill:AddAnchor("TOPLEFT", root, 0, 0); fill:AddAnchor("BOTTOMRIGHT", root, 0, 0) end
    if fill ~= nil then fill.rsUiOwner = root.rsUiOwner end
    local c = RSUI:NewComponent("Divider", spec, root)
    c.fill = fill
    function c:SetTone(tone, alpha)
        local nextColor = Tokens.Color and Tokens:Color(tone or "muted", color) or color
        if self.fill ~= nil then return UI:SetColor(self.fill, nextColor[1], nextColor[2], nextColor[3], tonumber(alpha) or nextColor[4] or 1, self.owner) end
        return false
    end
    return c
end)

RSUI:RegisterType("Icon", function(spec)
    local size = math.max(1, tonumber(spec.size) or Token("size.iconMd", 20))
    spec.width, spec.height = tonumber(spec.width) or size, tonumber(spec.height) or size
    CommonSpec(spec, size, size)
    local root = UI:CreateEmptyWidget(spec.parent, spec.id, spec.x, spec.y, spec.width, spec.height, spec.pickable == true)
    if root == nil then return nil, "icon_host_create_failed" end
    local icon = root.CreateIconDrawable and root:CreateIconDrawable(spec.layer or "artwork") or nil
    if icon ~= nil then
        icon.rsUiOwner = root.rsUiOwner
        if icon.SetExtent ~= nil then icon:SetExtent(spec.width, spec.height) end
        if icon.AddAnchor ~= nil then icon:AddAnchor("TOPLEFT", root, 0, 0) end
        UI:SetIconTexture(icon, spec.path or spec.iconPath, root.rsUiOwner)
        UI:SetVisible(icon, (spec.path or spec.iconPath) ~= nil and tostring(spec.path or spec.iconPath) ~= "", root.rsUiOwner)
    end
    local c = RSUI:NewComponent("Icon", spec, root)
    c.icon = icon
    function c:SetIcon(path)
        if self.icon == nil then return false end
        path = tostring(path or "")
        local changed = UI:SetIconTexture(self.icon, path, self.owner)
        UI:SetVisible(self.icon, path ~= "", self.owner)
        return changed
    end
    function c:Layout(x, y, width, height)
        self:SetBounds(x, y, width, height)
        if self.icon ~= nil and type(self.icon.SetExtent) == "function" then
            local w, h = math.max(1, tonumber(width) or self.width or size), math.max(1, tonumber(height) or self.height or size)
            if self.state.iconWidth ~= w or self.state.iconHeight ~= h then self.icon:SetExtent(w, h); self.state.iconWidth, self.state.iconHeight = w, h end
        end
        return true
    end
    return c
end)

local function CreateButtonComponent(kind, spec, withIcon)
    CommonSpec(spec, spec.compact == true and 72 or 96, tonumber(spec.height) or Token("size.buttonH", 26))
    local button = UI:CreateButton(spec.parent, spec.id, tostring(spec.text or ""), spec.x, spec.y, spec.width, spec.height,
        tonumber(spec.fontSize) or Token("font.body", 11), spec.selected == true or spec.active == true, spec.gradient ~= false)
    if button == nil then return nil, "button_create_failed" end
    local c = RSUI:NewComponent(kind, spec, button)
    c.state.selected = spec.selected == true or spec.active == true
    c.text = tostring(spec.text or "")
    function c:SetText(text)
        local value = tostring(text or "")
        self.textRevision = (tonumber(self.textRevision) or 0) + 1
        self.text = value
        self.spec.text = value
        return UI:SetText(self.root, value, self.owner)
    end
    function c:SetSelected(selected) self.state.selected = selected == true; return UI:SetButtonActive(self.root, self.state.selected, self.owner) end
    function c:Render(state)
        state = type(state) == "table" and state or {}
        RSUI:_Count(self.kind, "rendered", 1)
        if state.text ~= nil then self:SetText(state.text) end
        if state.selected ~= nil then self:SetSelected(state.selected) end
        if state.enabled ~= nil then self:SetEnabled(state.enabled) end
        if state.visible ~= nil then self:SetVisible(state.visible) end
        if state.icon ~= nil and type(self.SetIcon) == "function" then self:SetIcon(state.icon) end
        return true
    end
    function c:Click(...)
        if self.enabled == false then return false end
        local ok, result = RSUI:Callback("rsui:" .. self.id .. ":click", spec.onClick, self, ...)
        return ok and result ~= false
    end
    c:On(button, "OnClick", function(...) return c:Click(...) end, "rsui:" .. spec.id .. ":click")
    if withIcon == true and button.CreateIconDrawable ~= nil then
        local icon = button:CreateIconDrawable("artwork")
        c.icon = icon
        if icon ~= nil then
            icon.rsUiOwner = button.rsUiOwner
            local iconSize = math.max(1, tonumber(spec.iconSize) or Token("size.iconSm", 16))
            if icon.SetExtent ~= nil then icon:SetExtent(iconSize, iconSize) end
            if icon.AddAnchor ~= nil then icon:AddAnchor("CENTER", button, tonumber(spec.iconOffsetX) or 0, tonumber(spec.iconOffsetY) or 0) end
            UI:SetIconTexture(icon, spec.icon or spec.iconPath, c.owner)
            UI:SetVisible(icon, tostring(spec.icon or spec.iconPath or "") ~= "", c.owner)
        end
        function c:SetIcon(path)
            if self.icon == nil then return false end
            path = tostring(path or "")
            local changed = UI:SetIconTexture(self.icon, path, self.owner)
            UI:SetVisible(self.icon, path ~= "", self.owner)
            return changed
        end
    end
    c:SetEnabled(spec.enabled ~= false)
    return c
end

RSUI:RegisterType("Button", function(spec) return CreateButtonComponent("Button", spec, false) end)
RSUI:RegisterType("IconButton", function(spec) return CreateButtonComponent("IconButton", spec, true) end)

------------------------------------------------------------------------
-- Phase 3 UMG-like primitive upgrades. These registrations intentionally
-- replace the earlier v1 factories while keeping the same public type names.
------------------------------------------------------------------------

-- ArcheAge/RU LABEL is a single-line primitive. The public API exposes
-- SetAutoResize but no word-wrap/line-height contract; feeding a manually
-- wrapped string containing "\\n" into one LABEL can make multiple lines paint
-- on the same native baseline. RSUI therefore renders overflow="wrap" through
-- a bounded pool of one-line LABEL children hosted by an EMPTY_WIDGET.
--
-- The pool is created lazily and capped so long descriptions never explode the
-- native widget count. This remains event/layout driven: no Tick/OnUpdate.
function RSUI.NormalizeWrappedTextSizing(spec)
    spec = type(spec) == "table" and spec or {}
    local maxLines = math.max(1, math.floor(tonumber(spec.maxLines) or 1000))
    local nativeLineLimit = math.max(1, math.min(8, math.floor(tonumber(spec.nativeLineLimit) or math.min(maxLines, 6))))
    return {
        maxLines = maxLines,
        nativeLineLimit = nativeLineLimit,
        effectiveMaxLines = math.min(maxLines, nativeLineLimit),
        minHeight = tonumber(spec.minHeight),
        maxHeight = tonumber(spec.maxHeight),
    }
end

local function CreateWrappedText(spec)
    local preferredFont = math.max(1, tonumber(spec.fontSize) or Token("font.body", 11))
    local defaultH = math.max(Token("size.rowH", 28), math.ceil(preferredFont * 1.25))
    CommonSpec(spec, 120, defaultH)
    local root = UI:CreateEmptyWidget(spec.parent, spec.id, spec.x, spec.y, spec.width, spec.height, false)
    if root == nil then return nil, "wrapped_text_host_create_failed" end
    root.rsBaseFontSize = preferredFont

    local c = RSUI:NewComponent("Text", spec, root)
    c.text = tostring(spec.text or "")
    c.fontSize = preferredFont
    c.minFontSize = math.max(1, math.min(preferredFont, tonumber(spec.minFontSize) or math.max(8, preferredFont - 3)))
    c.overflow = "wrap"
    local wrappedSizing = RSUI.NormalizeWrappedTextSizing(spec)
    c.maxLines = wrappedSizing.maxLines
    c.nativeLineLimit = wrappedSizing.nativeLineLimit
    c.state.tone = tostring(spec.tone or "default")
    c.lineLabels = {}
    c.lineCreateFailures = 0
    root.rsWrappedTextComposite = true

    local function SplitLines(value)
        local lines = {}
        local source = tostring(value or "")
        for line in (source .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
        if #lines == 0 then lines[1] = "" end
        return lines
    end

    function c:_EnsureLine(index)
        index = math.max(1, math.floor(tonumber(index) or 1))
        if self.lineLabels[index] ~= nil then return self.lineLabels[index] end
        if index > self.nativeLineLimit then return nil end
        local lineId = self.id .. "_line_" .. tostring(index)
        local label, err = UI:CreateLabel(self.root, lineId, "", 0, 0,
            math.max(1, tonumber(self.width) or tonumber(self.spec.width) or 120), defaultH,
            self.fontSize, self.state.tone, self.spec.align or ALIGN_LEFT, self.spec.shadow)
        if label == nil then
            self.lineCreateFailures = (tonumber(self.lineCreateFailures) or 0) + 1
            self.state.lineCreateError = tostring(err or "label_create_failed")
            if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.WarningRateLimited) == "function" then
                S.DiagnosticsManager:WarningRateLimited("rsui_text", "RSUI_WRAPPED_TEXT_LINE_CREATE_FAILED", 5000,
                    "多行文字子行创建失败，已保持组件存活", { id = tostring(self.id), line = tostring(index), error = tostring(err or "") })
            end
            return nil
        end
        label.rsLocalFontScale = tonumber(self.appearanceFontScale) or tonumber(self.root and self.root.rsLocalFontScale) or 1.0
        self.lineLabels[index] = label
        return label
    end

    function c:SetText(text)
        local value = tostring(text or "")
        if self.text == value then return false end
        self.text = value
        self:InvalidateMeasure("text_changed")
        if tonumber(self.width) ~= nil and tonumber(self.height) ~= nil then return true end
        return self:Render()
    end

    function c:SetTone(tone)
        self.state.tone = tostring(tone or "default")
        local changed = false
        for _, label in ipairs(self.lineLabels) do
            if label ~= nil and UI:SetLabelTone(label, self.state.tone, self.owner) then changed = true end
        end
        return changed
    end

    function c:SetFontSize(size)
        local value = math.max(1, tonumber(size) or self.fontSize)
        if value ~= self.fontSize then self.fontSize = value; self.root.rsBaseFontSize = value; self:InvalidateMeasure("font_changed") end
        local changed = false
        for _, label in ipairs(self.lineLabels) do
            if label ~= nil then
                label.rsBaseFontSize = self.fontSize
                if UI:SetFontSize(label, NativeFontSize(self.fontSize, label), self.owner) then changed = true end
            end
        end
        return changed
    end

    function c:ApplyLocalFontScale(value)
        local scale = math.max(0.50, math.min(2.00, tonumber(value) or 1.0))
        self.appearanceFontScale = scale
        if self.root ~= nil then self.root.rsLocalFontScale = scale end
        local changed = false
        for _, label in ipairs(self.lineLabels) do
            if label ~= nil then
                label.rsLocalFontScale = scale
                label.rsBaseFontSize = self.fontSize
                if UI:SetFontSize(label, NativeFontSize(self.fontSize, label), self.owner) then changed = true end
            end
        end
        return changed
    end

    function c:ApplyTextOpacity(value)
        local theme = S.Theme
        if type(theme) ~= "table" or type(theme.SetTextOpacity) ~= "function" then return false end
        local changed = false
        for _, label in ipairs(self.lineLabels) do
            if label ~= nil and theme:SetTextOpacity(label, value) then changed = true end
        end
        return changed
    end

    function c:IsTextTruncated()
        return self.state.textTruncated == true or self.state.textClipped == true or self.state.textOverflow == true
    end
    function c:GetOverflowTooltipText()
        if self:IsTextTruncated() ~= true then return "" end
        return tostring(self.text or "")
    end

    function c:Measure(availableWidth, availableHeight)
        local TL = RSUI.TextLayout
        local probe = self:_EnsureLine(1)
        local text, font = self.text, self.fontSize
        local naturalW = TL and TL:MeasureWidth(probe, text, font) or (#text * font * 0.56)
        local lineH = TL and math.max(1, math.ceil(TL:LineHeight(probe, font))) or math.ceil(font * 1.25)
        local width, height = naturalW, lineH
        if tonumber(availableWidth) ~= nil then
            local aw = math.max(1, tonumber(availableWidth))
            if TL ~= nil and naturalW > aw then
                local _, lines = TL:Wrap(probe, text, aw, font, math.min(self.maxLines, self.nativeLineLimit))
                width, height = aw, lineH * math.max(1, tonumber(lines) or 1)
            elseif self.spec.allowOverflow ~= true then
                width = math.min(width, aw)
            end
        end
        width = math.max(1, tonumber(self.spec.minWidth) and math.max(width, tonumber(self.spec.minWidth)) or width)
        height = math.max(1, tonumber(self.spec.minHeight) and math.max(height, tonumber(self.spec.minHeight)) or height)
        if tonumber(self.spec.maxWidth) then width = math.min(width, tonumber(self.spec.maxWidth)) end
        if tonumber(self.spec.maxHeight) then height = math.min(height, tonumber(self.spec.maxHeight)) end
        if tonumber(availableHeight) and self.spec.allowOverflow ~= true then height = math.min(height, math.max(1, tonumber(availableHeight))) end
        self.desiredWidth, self.desiredHeight = width, height
        self.measureDirty = false
        return width, height
    end

    function c:Render(state)
        state = type(state) == "table" and state or {}
        RSUI:_Count(self.kind, "rendered", 1)
        if state.text ~= nil then
            local value = tostring(state.text or "")
            if value ~= self.text then self.text = value; self:InvalidateMeasure("render_text_changed") end
        end
        if state.tone ~= nil then self:SetTone(state.tone) end
        if state.visible ~= nil then self:SetVisible(state.visible) end

        local width = math.max(1, tonumber(state.width) or tonumber(self.width) or tonumber(self.spec.width) or 120)
        local font = self.fontSize
        local TL = RSUI.TextLayout
        local probe = self:_EnsureLine(1)
        local lineH = TL and math.max(1, math.ceil(TL:LineHeight(probe, font))) or math.ceil(font * 1.25)
        local allocatedHeight = tonumber(state.height) or tonumber(self.height) or tonumber(self.spec.height)
        local heightLineLimit = allocatedHeight and math.max(1, math.floor(allocatedHeight / lineH)) or self.maxLines
        local maxLines = math.max(1, math.min(self.maxLines, self.nativeLineLimit, heightLineLimit))
        local display, lineCount, truncated
        if TL ~= nil then
            display, lineCount, truncated = TL:Wrap(probe, self.text, width, font, maxLines)
        else
            display, lineCount, truncated = self.text, 1, false
        end
        local lines = SplitLines(display)
        if #lines > maxLines then
            while #lines > maxLines do table.remove(lines) end
            truncated = true
        end

        for index = 1, self.nativeLineLimit do
            local label = index <= #lines and self:_EnsureLine(index) or self.lineLabels[index]
            if label ~= nil then
                local visible = index <= #lines
                if visible then
                    label.rsBaseFontSize = font
                    label.rsLocalFontScale = tonumber(self.appearanceFontScale) or tonumber(self.root and self.root.rsLocalFontScale) or 1.0
                    UI:SetFontSize(label, NativeFontSize(font, label), self.owner)
                    UI:SetLabelTone(label, self.state.tone, self.owner)
                    UI:SetExtent(label, width, lineH, self.owner)
                    UI:SetAnchor(label, self.root, 0, (index - 1) * lineH, self.owner)
                    UI:SetText(label, lines[index], self.owner)
                    UI:SetVisible(label, true, self.owner)
                    if self.appearanceTextOpacity ~= nil and S.Theme ~= nil and type(S.Theme.SetTextOpacity) == "function" then
                        S.Theme:SetTextOpacity(label, self.appearanceTextOpacity)
                    end
                else
                    UI:SetVisible(label, false, self.owner)
                end
            end
        end
        self.state.wrappedLines = math.max(1, tonumber(lineCount) or #lines)
        self.state.textTruncated = truncated == true
        self.state.textClipped = false
        self.state.textOverflow = false
        self.state.displayText = display
        self.state.displayFontSize = font
        return true
    end

    function c:Layout(x, y, width, height)
        width = math.max(1, tonumber(width) or self.desiredWidth or self.spec.width or 1)
        local _, desiredH = self:Measure(width, height)
        height = math.max(1, tonumber(height) or desiredH or self.spec.height or defaultH)
        self:SetBounds(x, y, width, height)
        self:Render({ width = width, height = height })
        return height
    end

    c:_EnsureLine(1)
    c:Render({ width = spec.width, height = spec.height })
    return c
end

RSUI.WrappedTextContractVersion = 2

RSUI:ReplaceType("Text", function(spec)
    local overflowMode = tostring(spec.overflow or spec.overflowPolicy or "ellipsis"):lower()
    if overflowMode == "wrap" then return CreateWrappedText(spec) end
    local preferredFont = math.max(1, tonumber(spec.fontSize) or Token("font.body", 11))
    local defaultH = math.max(Token("size.rowH", 28), math.ceil(preferredFont * 1.25))
    CommonSpec(spec, 120, defaultH)
    local widget = UI:CreateLabel(spec.parent, spec.id, tostring(spec.text or ""), spec.x, spec.y, spec.width, spec.height,
        preferredFont, spec.tone or "default", spec.align or ALIGN_LEFT, spec.shadow)
    if widget == nil then return nil, "label_create_failed" end
    local c = RSUI:NewComponent("Text", spec, widget)
    c.text = tostring(spec.text or "")
    c.fontSize = preferredFont
    c.minFontSize = math.max(1, math.min(preferredFont, tonumber(spec.minFontSize) or math.max(8, preferredFont - 3)))
    c.overflow = tostring(spec.overflow or spec.overflowPolicy or "ellipsis"):lower()
    c.maxLines = math.max(1, math.floor(tonumber(spec.maxLines) or (c.overflow == "wrap" and 1000 or 1)))
    c.state.tone = tostring(spec.tone or "default")

    function c:SetText(text)
        local value = tostring(text or "")
        if self.text == value then return false end
        self.text = value
        self:InvalidateMeasure("text_changed")
        -- Once geometry exists, let Measure -> Layout -> Render own the update.
        -- This prevents ellipsis/wrap from rendering against a stale width.
        if tonumber(self.width) ~= nil and tonumber(self.height) ~= nil then return true end
        return self:Render()
    end
    function c:SetTone(tone) self.state.tone = tostring(tone or "default"); return UI:SetLabelTone(self.root, self.state.tone, self.owner) end

    -- Event-time overflow query used by TooltipService/TableView. Do not rely
    -- only on cached Render flags: a row may have just been rebound or a column
    -- may have been resized immediately before the pointer enters it. Measuring
    -- here is cheap because this path runs only on hover, never on Tick.
    function c:IsTextTruncated()
        if self.state.textTruncated == true or self.state.textClipped == true or self.state.textOverflow == true then return true end
        local TL = RSUI.TextLayout
        if TL == nil or type(TL.MeasureWidth) ~= "function" then return false end
        local width = tonumber(self.width) or tonumber(self.spec.width)
        if width == nil or width <= 0 then return false end
        if self.overflow == "ellipsis" or self.overflow == "clip" or self.overflow == "shrink" then
            return TL:MeasureWidth(self.root, self.text, self.fontSize) > width
        end
        return false
    end
    function c:GetOverflowTooltipText()
        if self:IsTextTruncated() ~= true then return "" end
        return tostring(self.text or "")
    end

    function c:SetFontSize(size)
        local value = math.max(1, tonumber(size) or self.fontSize)
        if value ~= self.fontSize then self.fontSize = value; self.root.rsBaseFontSize = value; self:InvalidateMeasure("font_changed") end
        return UI:SetFontSize(self.root, NativeFontSize(self.fontSize, self.root), self.owner)
    end
    function c:Measure(availableWidth, availableHeight)
        local TL = RSUI.TextLayout
        local text, font = self.text, self.fontSize
        local naturalW = TL and TL:MeasureWidth(self.root, text, font) or (#text * font * 0.56)
        local lineH = TL and TL:LineHeight(self.root, font) or math.ceil(font * 1.25)
        local width = naturalW
        local height = lineH
        if tonumber(availableWidth) ~= nil then
            local aw = math.max(1, tonumber(availableWidth))
            -- A single Native LABEL never owns wrap semantics. overflow=wrap is
            -- routed to CreateWrappedText before this factory is entered. If a
            -- caller mutates the field afterward, keep geometry single-line
            -- rather than ever feeding a newline string to the LABEL.
            if self.spec.allowOverflow ~= true then width = math.min(width, aw) end
        end
        width = math.max(1, tonumber(self.spec.minWidth) and math.max(width, tonumber(self.spec.minWidth)) or width)
        height = math.max(1, tonumber(self.spec.minHeight) and math.max(height, tonumber(self.spec.minHeight)) or height)
        if tonumber(self.spec.maxWidth) then width = math.min(width, tonumber(self.spec.maxWidth)) end
        if tonumber(self.spec.maxHeight) then height = math.min(height, tonumber(self.spec.maxHeight)) end
        if tonumber(availableHeight) and self.spec.allowOverflow ~= true then height = math.min(height, math.max(1, tonumber(availableHeight))) end
        self.desiredWidth, self.desiredHeight = width, height
        self.measureDirty = false
        return width, height
    end
    function c:Render(state)
        state = type(state) == "table" and state or {}
        RSUI:_Count(self.kind, "rendered", 1)
        if state.text ~= nil then
            local value = tostring(state.text or "")
            if value ~= self.text then self.text = value; self:InvalidateMeasure("render_text_changed") end
        end
        if state.tone ~= nil then self:SetTone(state.tone) end
        if state.visible ~= nil then self:SetVisible(state.visible) end
        local width = math.max(1, tonumber(state.width) or tonumber(self.width) or tonumber(self.spec.width) or 120)
        local display, font = self.text, self.fontSize
        local TL = RSUI.TextLayout
        local truncated, clipped, overflowed = false, false, false
        if TL ~= nil then
            local overflowMode = self.overflow == "wrap" and "ellipsis" or self.overflow
            if overflowMode == "shrink" then
                local wasTruncated
                display, font, wasTruncated = TL:ShrinkToFit(self.root, self.text, width, self.fontSize, self.minFontSize)
                truncated = wasTruncated == true
            elseif overflowMode == "ellipsis" then
                local wasTruncated
                display, wasTruncated = TL:Ellipsize(self.root, self.text, width, font)
                truncated = wasTruncated == true
            elseif overflowMode == "clip" then
                clipped = TL:MeasureWidth(self.root, self.text, font) > width
            else
                -- Unknown/visible overflow policies are the only unmanaged case.
                -- Managed policies above always return a display value that is
                -- bounded by the allocated geometry, so truncation is not a
                -- layout failure and must not be reported as text_overflow.
                overflowed = TL:MeasureWidth(self.root, self.text, font) > width
            end
        end
        self.state.textTruncated = truncated
        self.state.textClipped = clipped
        self.state.textOverflow = overflowed
        self.state.displayText = display
        self.state.displayFontSize = font
        UI:SetFontSize(self.root, NativeFontSize(font, self.root), self.owner)
        UI:SetText(self.root, display, self.owner)
        return true
    end
    function c:Layout(x, y, width, height)
        width = math.max(1, tonumber(width) or self.desiredWidth or self.spec.width or 1)
        local _, desiredH = self:Measure(width, height)
        height = math.max(1, tonumber(height) or desiredH or self.spec.height or defaultH)
        self:SetBounds(x, y, width, height)
        self:Render({ width = width, height = height })
        return height
    end
    c:Render({ width = spec.width })
    return c
end)

RSUI:RegisterType("Image", function(spec)
    local size = math.max(1, tonumber(spec.size) or Token("size.iconMd", 20))
    spec.width, spec.height = tonumber(spec.width) or size, tonumber(spec.height) or size
    CommonSpec(spec, size, size)
    local root = UI:CreateEmptyWidget(spec.parent, spec.id, spec.x, spec.y, spec.width, spec.height, spec.pickable == true)
    if root == nil then return nil, "image_host_create_failed" end
    local drawable = root.CreateIconDrawable and root:CreateIconDrawable(spec.layer or "artwork") or nil
    if drawable ~= nil then
        drawable.rsUiOwner = root.rsUiOwner
        if drawable.SetExtent ~= nil then drawable:SetExtent(spec.width, spec.height) end
        if drawable.AddAnchor ~= nil then drawable:AddAnchor("TOPLEFT", root, 0, 0) end
        UI:SetIconTexture(drawable, spec.path or spec.texture or spec.iconPath, root.rsUiOwner)
        UI:SetVisible(drawable, tostring(spec.path or spec.texture or spec.iconPath or "") ~= "", root.rsUiOwner)
    end
    local c = RSUI:NewComponent("Image", spec, root)
    c.drawable = drawable
    function c:SetImage(path)
        if self.drawable == nil then return false end
        path = tostring(path or "")
        local changed = UI:SetIconTexture(self.drawable, path, self.owner)
        UI:SetVisible(self.drawable, path ~= "", self.owner)
        return changed
    end
    c.SetTexture = c.SetImage
    function c:Measure(aw, ah)
        local w, h = tonumber(self.spec.desiredWidth) or tonumber(self.spec.width) or size, tonumber(self.spec.desiredHeight) or tonumber(self.spec.height) or size
        if aw and self.spec.allowOverflow ~= true then w = math.min(w, math.max(1, tonumber(aw))) end
        if ah and self.spec.allowOverflow ~= true then h = math.min(h, math.max(1, tonumber(ah))) end
        self.desiredWidth, self.desiredHeight = w, h; self.measureDirty=false; return w, h
    end
    function c:Layout(x, y, width, height)
        width, height = math.max(1, tonumber(width) or self.spec.width or size), math.max(1, tonumber(height) or self.spec.height or size)
        self:SetBounds(x, y, width, height)
        if self.drawable ~= nil and (self.state.imageW ~= width or self.state.imageH ~= height) then
            if type(self.drawable.SetExtent) == "function" then self.drawable:SetExtent(width, height) end
            self.state.imageW, self.state.imageH = width, height
        end
        return height
    end
    return c
end)

RSUI:RegisterType("Spacer", function(spec)
    local width, height = math.max(0, tonumber(spec.width) or 0), math.max(0, tonumber(spec.height) or 0)
    local root = UI:CreateEmptyWidget(spec.parent, spec.id, tonumber(spec.x) or 0, tonumber(spec.y) or 0, math.max(1, width), math.max(1, height), false)
    if root == nil then return nil, "spacer_create_failed" end
    local c = RSUI:NewComponent("Spacer", spec, root)
    function c:Measure(aw, ah)
        local w, h = math.max(0, tonumber(self.spec.width) or 0), math.max(0, tonumber(self.spec.height) or 0)
        if aw and self.spec.allowOverflow ~= true then w = math.min(w, math.max(0, tonumber(aw))) end
        if ah and self.spec.allowOverflow ~= true then h = math.min(h, math.max(0, tonumber(ah))) end
        self.desiredWidth, self.desiredHeight = w, h; self.measureDirty=false; return w, h
    end
    return c
end)

RSUI:RegisterType("ProgressBar", function(spec)
    spec.width, spec.height = math.max(1, tonumber(spec.width) or 160), math.max(1, tonumber(spec.height) or 14)
    local root = UI:CreateEmptyWidget(spec.parent, spec.id, tonumber(spec.x) or 0, tonumber(spec.y) or 0, spec.width, spec.height, false)
    if root == nil then return nil, "progress_create_failed" end
    local bgColor = Tokens.Color and Tokens:Color(spec.backgroundTone or "muted", {0.12,0.14,0.17,0.75}) or {0.12,0.14,0.17,0.75}
    local fillColor = Tokens.Color and Tokens:Color(spec.tone or "accent", {0.26,0.62,0.94,1}) or {0.26,0.62,0.94,1}
    local bg = root.CreateColorDrawable and root:CreateColorDrawable(bgColor[1],bgColor[2],bgColor[3],tonumber(spec.backgroundAlpha) or bgColor[4] or 0.75,"background") or nil
    if bg and bg.AddAnchor then bg:AddAnchor("TOPLEFT",root,0,0); bg:AddAnchor("BOTTOMRIGHT",root,0,0); bg.rsUiOwner=root.rsUiOwner end
    local fill = root.CreateColorDrawable and root:CreateColorDrawable(fillColor[1],fillColor[2],fillColor[3],tonumber(spec.alpha) or fillColor[4] or 1,"artwork") or nil
    if fill and fill.AddAnchor then fill:AddAnchor("TOPLEFT",root,0,0); fill.rsUiOwner=root.rsUiOwner end
    local c = RSUI:NewComponent("ProgressBar", spec, root)
    c.background, c.fill = bg, fill
    c.percent = math.max(0, math.min(1, tonumber(spec.percent or spec.value) or 0))
    function c:SetPercent(value)
        value = math.max(0, math.min(1, tonumber(value) or 0))
        self.percent = value
        local w, h = math.max(1, tonumber(self.width) or tonumber(self.spec.width) or 1), math.max(1, tonumber(self.height) or tonumber(self.spec.height) or 1)
        if self.fill ~= nil then UI:SetExtent(self.fill, math.max(1, math.floor(w * value + 0.5)), h, self.owner) end
        return value
    end
    function c:Measure(aw, ah)
        local w,h=tonumber(self.spec.width) or 160,tonumber(self.spec.height) or 14
        if aw and self.spec.allowOverflow~=true then w=math.min(w,math.max(1,tonumber(aw))) end
        if ah and self.spec.allowOverflow~=true then h=math.min(h,math.max(1,tonumber(ah))) end
        self.desiredWidth,self.desiredHeight=w,h; self.measureDirty=false; return w,h
    end
    function c:Layout(x,y,width,height)
        width,height=math.max(1,tonumber(width) or self.spec.width or 160),math.max(1,tonumber(height) or self.spec.height or 14)
        self:SetBounds(x,y,width,height); self:SetPercent(self.percent); return height
    end
    c:Layout(spec.x or 0,spec.y or 0,spec.width,spec.height)
    return c
end)

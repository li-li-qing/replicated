------------------------------------------------------------------------
-- Replicated Suite - Theme
------------------------------------------------------------------------

if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local C = S.Constants

S.Theme = {}
local T = S.Theme

local function SafeColor(style, color)
    if style ~= nil and style.SetColor ~= nil and color ~= nil then
        style:SetColor(color[1], color[2], color[3], color[4])
    end
end

function T:ToneColor(tone)
    local colors = C.Color
    if tone == "green" then return colors.green end
    if tone == "yellow" then return colors.yellow end
    if tone == "orange" then return colors.orange end
    if tone == "red" then return colors.red end
    if tone == "blue" then return colors.blue end
    if tone == "purple" then return colors.purple end
    if tone == "muted" then return colors.textMuted end
    return colors.text
end

function T:AddPanelBackground(widget, kind)
    if widget == nil or widget.CreateColorDrawable == nil then return nil end
    local color = kind == "header" and C.Color.cardHeader or (kind == "card" and C.Color.card or C.Color.panel)
    local bg = widget:CreateColorDrawable(color[1], color[2], color[3], color[4], "background")
    if bg ~= nil and bg.AddAnchor ~= nil then
        local inset = widget.rsBorder ~= nil and 1 or 0
        bg:AddAnchor("TOPLEFT", widget, inset, inset)
        bg:AddAnchor("BOTTOMRIGHT", widget, -inset, -inset)
    end
    widget.rsBackground = bg
    widget.rsBackgroundColor = { color[1], color[2], color[3], color[4] }
    return bg
end

function T:AddBorder(widget, soft)
    if widget == nil or widget.CreateColorDrawable == nil then return nil end
    local color = soft and C.Color.borderSoft or C.Color.border
    local border = widget:CreateColorDrawable(color[1], color[2], color[3], color[4], "background")
    if border ~= nil and border.AddAnchor ~= nil then
        border:AddAnchor("TOPLEFT", widget, 0, 0)
        border:AddAnchor("BOTTOMRIGHT", widget, 0, 0)
    end
    widget.rsBorder = border
    widget.rsBorderColor = { color[1], color[2], color[3], color[4] }
    return border
end

-- Modern dark theme: vertical 3-band gradient background. Uses the client's
-- CreateThreeColorDrawable + ChangeColor1/2/3 (r,g,b) API; falls back to the
-- solid-color background when the drawable type is unavailable so a panel is
-- never left invisible.  ChangeColor order is top -> mid -> bottom; if the RU
-- client renders the bands in a different order, swap the values in
-- Constants.Color.Gradient.
function T:AddGradientBackground(widget, kind, layer)
    if widget == nil then return nil end
    local bands = (kind == "titlebar" and C.Color.Gradient.titlebar)
        or (kind == "header" and C.Color.Gradient.header)
        or (kind == "card" and C.Color.Gradient.card)
        or C.Color.Gradient.panel
    local baseAlpha = (kind == "header" and C.Color.cardHeader[4])
        or (kind == "card" and C.Color.card[4])
        or C.Color.panel[4]
    if type(widget.CreateThreeColorDrawable) ~= "function" then
        return self:AddPanelBackground(widget, kind)
    end
    local ok, bg = pcall(function()
        local d = widget:CreateThreeColorDrawable(16, 16, layer or "background")
        if d == nil then return nil end
        -- Without the band setters the drawable stays blank/white; treat it as
        -- unsupported and fall back to the solid background.
        if type(d.ChangeColor1) ~= "function" or type(d.ChangeColor2) ~= "function" or type(d.ChangeColor3) ~= "function" then
            return nil
        end
        d:ChangeColor1(bands[1][1], bands[1][2], bands[1][3])
        d:ChangeColor2(bands[2][1], bands[2][2], bands[2][3])
        d:ChangeColor3(bands[3][1], bands[3][2], bands[3][3])
        -- Do NOT call SetColor on a multi-band drawable: on the RU client it can
        -- overwrite the ChangeColor bands and wash the gradient to a flat color.
        -- Fade with SetAlpha when the client exposes it; otherwise keep opaque.
        if d.SetAlpha ~= nil then d:SetAlpha(baseAlpha) end
        if d.AddAnchor ~= nil then
            local inset = widget.rsBorder ~= nil and 1 or 0
            d:AddAnchor("TOPLEFT", widget, inset, inset)
            d:AddAnchor("BOTTOMRIGHT", widget, -inset, -inset)
        end
        return d
    end)
    if not ok or bg == nil then
        return self:AddPanelBackground(widget, kind)
    end
    widget.rsBackground = bg
    -- Gradient drawable keeps its own RGB bands; store white + base alpha so
    -- SetBackgroundOpacity can still fade the whole strip uniformly.
    widget.rsBackgroundColor = { 1, 1, 1, baseAlpha }
    return bg
end

-- Thin accent strip pinned to the top edge of a panel (modern highlight line).
function T:AddAccentStrip(widget, height, color)
    if widget == nil or type(widget.CreateColorDrawable) ~= "function" then return nil end
    local h = math.max(1, tonumber(height) or 2)
    local c = color or C.Color.accentLine
    local ok, strip = pcall(function()
        local d = widget:CreateColorDrawable(c[1], c[2], c[3], c[4], "artwork")
        if d == nil then return nil end
        if d.AddAnchor ~= nil then
            d:AddAnchor("TOPLEFT", widget, 0, 0)
            d:AddAnchor("TOPRIGHT", widget, 0, h)
        end
        if d.SetHeight ~= nil then d:SetHeight(h) end
        return d
    end)
    if not ok or strip == nil then return nil end
    widget.rsAccentStrip = strip
    widget.rsAccentStripColor = { c[1], c[2], c[3], c[4] }
    return strip
end

-- Horizontal divider line drawn as a thin color drawable (the Line widget is
-- not part of the guaranteed surface on every RU build; a 1px color strip is
-- equivalent visually and cannot crash).
function T:AddDivider(widget, y, soft)
    if widget == nil or type(widget.CreateColorDrawable) ~= "function" then return nil end
    local c = soft and C.Color.dividerSoft or C.Color.divider
    local ok, line = pcall(function()
        local d = widget:CreateColorDrawable(c[1], c[2], c[3], c[4], "artwork")
        if d == nil then return nil end
        if d.AddAnchor ~= nil then
            d:AddAnchor("TOPLEFT", widget, 0, y or 0)
            d:AddAnchor("TOPRIGHT", widget, 0, y or 0)
        end
        if d.SetHeight ~= nil then d:SetHeight(1) end
        return d
    end)
    if not ok or line == nil then return nil end
    widget.rsDivider = line
    return line
end

function T:StyleLabel(label, size, tone, align, shadow)
    if label == nil or label.style == nil then return end
    label.rsBaseFontSize = tonumber(size) or 12
    local layoutScale = (S.Layout and S.Layout.GetContext) and S.Layout:GetContext().addonScale or 1
    local fontScale = (S.State and S.State.settings and tonumber(S.State.settings.fontScale)) or 1
    local scale = layoutScale * fontScale
    if label.style.SetFontSize ~= nil then label.style:SetFontSize(math.max(10, math.min(24, math.floor(label.rsBaseFontSize * scale + 0.5)))) end
    if label.style.SetAlign ~= nil then label.style:SetAlign(align or ALIGN_LEFT) end
    SafeColor(label.style, self:ToneColor(tone))
    if label.style.SetEllipsis ~= nil then pcall(function() label.style:SetEllipsis(false) end) end
    if shadow == true and label.style.SetShadow ~= nil then
        pcall(function() label.style:SetShadow(true) end)
    end
end

function T:StyleButton(button, width, height, fontSize, active, useGradient)
    if button == nil then return end
    width = math.max(1, tonumber(width) or 80)
    height = math.max(1, tonumber(height) or 26)
    if button.SetAutoResize ~= nil then pcall(function() button:SetAutoResize(false) end) end
    if button.SetExtent ~= nil then button:SetExtent(width, height) end
    if button.SetWidth ~= nil then button:SetWidth(width) end
    if button.SetHeight ~= nil then button:SetHeight(height) end

    local normal = active and { 0.17, 0.14, 0.09, 0.98 } or { 0.075, 0.095, 0.120, 0.97 }
    local highlight = active and { 0.26, 0.21, 0.12, 0.99 } or { 0.14, 0.19, 0.24, 0.99 }
    local pushed = { 0.045, 0.060, 0.078, 0.99 }
    local disabled = { 0.050, 0.052, 0.058, 0.70 }
    local colors = { normal, highlight, pushed, disabled }

    -- Modern gradient button skin. Each Button state gets its own
    -- CreateThreeColorDrawable when useGradient is requested and the client
    -- supports it; any failure falls back to the solid-color path below.
    local gradientBands = {
        active and C.Color.Gradient.buttonHover or C.Color.Gradient.button,
        C.Color.Gradient.buttonHover,
        C.Color.Gradient.buttonPushed,
        C.Color.Gradient.buttonDisabled,
    }
    local gradientAlphas = { 0.97, 0.99, 0.99, 0.70 }

    button.rsButtonBgs = button.rsButtonBgs or {}
    button.rsButtonBgColors = button.rsButtonBgColors or {}
    if #button.rsButtonBgs == 0 then
        local created = false
        if useGradient == true and type(button.CreateThreeColorDrawable) == "function" then
            created = true
            local gradientBgs = {}
            local gradientColors = {}
            for i = 1, 4 do
                local band = gradientBands[i] or C.Color.Gradient.button
                local ok, bg = pcall(function()
                    local d = button:CreateThreeColorDrawable(16, 16, "background")
                    if d == nil then return nil end
                    if type(d.ChangeColor1) ~= "function" or type(d.ChangeColor2) ~= "function" or type(d.ChangeColor3) ~= "function" then
                        return nil
                    end
                    d:ChangeColor1(band[1][1], band[1][2], band[1][3])
                    d:ChangeColor2(band[2][1], band[2][2], band[2][3])
                    d:ChangeColor3(band[3][1], band[3][2], band[3][3])
                    -- SetAlpha only: SetColor would overwrite the gradient bands.
                    if d.SetAlpha ~= nil then d:SetAlpha(gradientAlphas[i]) end
                    if d.AddAnchor ~= nil then
                        d:AddAnchor("TOPLEFT", button, 0, 0)
                        d:AddAnchor("BOTTOMRIGHT", button, 0, 0)
                    end
                    return d
                end)
                if not ok or bg == nil then
                    created = false
                    break
                end
                gradientBgs[i] = bg
                gradientColors[i] = { 1, 1, 1, gradientAlphas[i] }
            end
            if created then
                button.rsButtonBgs = gradientBgs
                button.rsButtonBgColors = gradientColors
                -- Keep the gradient band table so SetButtonActive can repaint the
                -- normal/highlight states live (used by main-window tabs).
                button.rsGradientBands = gradientBands
                button.rsGradientAlphas = gradientAlphas
            end
        end
        if not created then
            for i = 1, 4 do
                local c = colors[i]
                local bg = button:CreateColorDrawable(c[1], c[2], c[3], c[4], "background")
                if bg ~= nil and bg.AddAnchor ~= nil then
                    bg:AddAnchor("TOPLEFT", button, 0, 0)
                    bg:AddAnchor("BOTTOMRIGHT", button, 0, 0)
                end
                button.rsButtonBgs[i] = bg
                button.rsButtonBgColors[i] = { c[1], c[2], c[3], c[4] }
            end
        end
        if button.SetNormalBackground ~= nil then pcall(function() button:SetNormalBackground(button.rsButtonBgs[1]) end) end
        if button.SetHighlightBackground ~= nil then pcall(function() button:SetHighlightBackground(button.rsButtonBgs[2]) end) end
        if button.SetPushedBackground ~= nil then pcall(function() button:SetPushedBackground(button.rsButtonBgs[3]) end) end
        if button.SetDisabledBackground ~= nil then pcall(function() button:SetDisabledBackground(button.rsButtonBgs[4]) end) end
    end

    button.rsBaseFontSize = tonumber(fontSize) or 11
    if button.style ~= nil then
        local layoutScale = (S.Layout and S.Layout.GetContext) and S.Layout:GetContext().addonScale or 1
        local fontScale = (S.State and S.State.settings and tonumber(S.State.settings.fontScale)) or 1
        local scale = layoutScale * fontScale
        if button.style.SetFontSize ~= nil then button.style:SetFontSize(math.max(10, math.min(24, math.floor(button.rsBaseFontSize * scale + 0.5)))) end
        SafeColor(button.style, C.Color.text)
        if button.style.SetEllipsis ~= nil then pcall(function() button.style:SetEllipsis(false) end) end
    end
end

-- Live active/inactive repaint for gradient buttons (tabs etc.).
-- For gradient skins it swaps the normal/highlight band tables via
-- ChangeColor1/2/3; for solid skins it falls back to SetColor.
function T:SetButtonActive(button, active)
    if button == nil or type(button.rsButtonBgs) ~= "table" then return end
    if type(button.rsGradientBands) == "table" and button.rsButtonBgs[1] ~= nil and button.rsButtonBgs[2] ~= nil then
        local activeBand = active and C.Color.Gradient.buttonHover or C.Color.Gradient.button
        local hoverBand = C.Color.Gradient.buttonHover
        pcall(function()
            local n = button.rsButtonBgs[1]
            if n.ChangeColor1 ~= nil then
                n:ChangeColor1(activeBand[1][1], activeBand[1][2], activeBand[1][3])
                n:ChangeColor2(activeBand[2][1], activeBand[2][2], activeBand[2][3])
                n:ChangeColor3(activeBand[3][1], activeBand[3][2], activeBand[3][3])
            end
            local h = button.rsButtonBgs[2]
            if h.ChangeColor1 ~= nil then
                h:ChangeColor1(hoverBand[1][1], hoverBand[1][2], hoverBand[1][3])
                h:ChangeColor2(hoverBand[2][1], hoverBand[2][2], hoverBand[2][3])
                h:ChangeColor3(hoverBand[3][1], hoverBand[3][2], hoverBand[3][3])
            end
        end)
        return
    end
    if button.rsButtonBgColors == nil then return end
    local c = active and { 0.17, 0.14, 0.09, 0.98 } or { 0.075, 0.095, 0.120, 0.97 }
    if button.rsButtonBgs[1] ~= nil then
        pcall(function() button.rsButtonBgs[1]:SetColor(c[1], c[2], c[3], c[4]) end)
    end
end

function T:SetOpacity(widget, opacity)
    if widget ~= nil and widget.SetAlpha ~= nil then
        widget:SetAlpha(math.max(0.35, math.min(1.0, tonumber(opacity) or 1.0)))
    end
end

-- Floating HUD transparency must never walk arbitrary Widget references.
-- The RU client can retain Lua wrappers after the native widget underneath has
-- already been replaced/freed; GetParent()/SetDrawableLayerAlpha on such a
-- wrapper can cause a native access violation that pcall cannot catch.
--
-- Only drawables created and owned by this Theme are touched here. Their base
-- RGBA values are stored at creation time, so labels/text remain fully opaque
-- without probing descendants through the native UI tree.
local function ApplyOwnedDrawableAlpha(drawable, color, opacity)
    if drawable == nil or type(color) ~= "table" then return end
    local alpha = (tonumber(color[4]) or 1) * opacity
    -- Multi-band (gradient) drawables must not be faded through SetColor: on the
    -- RU client that call can overwrite the ChangeColor bands. SetAlpha is the
    -- safe path when available; otherwise leave the drawable at full opacity.
    if type(drawable.ChangeColor1) == "function" or type(drawable.ChangeColor2) == "function" or type(drawable.ChangeColor3) == "function" then
        if type(drawable.SetAlpha) == "function" then
            pcall(function() drawable:SetAlpha(alpha) end)
        end
        return
    end
    if type(drawable.SetColor) ~= "function" then return end
    pcall(function()
        drawable:SetColor(
            tonumber(color[1]) or 1,
            tonumber(color[2]) or 1,
            tonumber(color[3]) or 1,
            alpha
        )
    end)
end

function T:SetBackgroundOpacity(widget, opacity)
    if widget == nil then return end
    local value = math.max(0.0, math.min(1.0, tonumber(opacity) or 1.0))
    ApplyOwnedDrawableAlpha(widget.rsBackground, widget.rsBackgroundColor, value)
    ApplyOwnedDrawableAlpha(widget.rsBorder, widget.rsBorderColor, value)
    ApplyOwnedDrawableAlpha(widget.rsAccentStrip, widget.rsAccentStripColor, value)
    if type(widget.rsButtonBgs) == "table" and type(widget.rsButtonBgColors) == "table" then
        for i, drawable in ipairs(widget.rsButtonBgs) do
            ApplyOwnedDrawableAlpha(drawable, widget.rsButtonBgColors[i], value)
        end
    end
end


function T:SetEllipsis(widget, enabled)
    if widget ~= nil and widget.style ~= nil and type(widget.style.SetEllipsis) == "function" then
        pcall(function() widget.style:SetEllipsis(enabled == true) end)
    end
end

function T:SetLabelTone(label, tone)
    if label == nil or label.style == nil then return end
    SafeColor(label.style, self:ToneColor(tone))
end
function T:RefreshTypography()
    local controls = S.UI and S.UI.controls or nil
    if type(controls) ~= "table" then return end
    local layoutScale = (S.Layout and S.Layout.GetContext) and S.Layout:GetContext().addonScale or 1
    local fontScale = (S.State and S.State.settings and tonumber(S.State.settings.fontScale)) or 1
    local scale = layoutScale * fontScale
    for _, widget in pairs(controls) do
        if widget ~= nil and widget.style ~= nil and widget.rsBaseFontSize ~= nil and widget.style.SetFontSize ~= nil then
            pcall(function() widget.style:SetFontSize(math.max(10, math.min(24, math.floor((tonumber(widget.rsBaseFontSize) or 11) * scale + 0.5)))) end)
        end
    end
end


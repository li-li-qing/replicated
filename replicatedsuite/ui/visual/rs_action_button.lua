------------------------------------------------------------------------
-- Replicated Suite - Visual Action Button Composite (M6-v6)
--
-- M6-v6 restores the RU client's verified ThreeColorDrawable path for the
-- visual-layer buttons. Earlier visual passes intentionally forced flat fills
-- while stabilising hierarchy; the result still looked like a debug utility.
-- These palettes repaint the existing bounded button-state drawables only once
-- and never add a Tick, animation queue, or extra interactive widget.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI = S.RSUI
S.Visual = S.Visual or {}
local A = {}
S.Visual.ActionButton = A

local function Band(top, mid, bottom, alpha)
    return { top = top, mid = mid, bottom = bottom, alpha = alpha or 1 }
end

local function Solid(c, alpha)
    return Band(c, c, c, alpha or c[4] or 1)
end

local function ApplyBand(drawable, band)
    if drawable == nil or type(band) ~= "table" then return end
    local top = band.top or band.mid or { 0, 0, 0 }
    local mid = band.mid or top
    local bottom = band.bottom or mid
    if type(drawable.ChangeColor1) == "function" and type(drawable.ChangeColor2) == "function" and type(drawable.ChangeColor3) == "function" then
        pcall(function()
            drawable:ChangeColor1(top[1], top[2], top[3])
            drawable:ChangeColor2(mid[1], mid[2], mid[3])
            drawable:ChangeColor3(bottom[1], bottom[2], bottom[3])
            if drawable.SetAlpha then drawable:SetAlpha(tonumber(band.alpha) or 1) end
        end)
    elseif type(drawable.SetColor) == "function" then
        pcall(function() drawable:SetColor(mid[1], mid[2], mid[3], tonumber(band.alpha) or 1) end)
    end
end

local function Palette(variant)
    local V = S.VisualTokens
    variant = tostring(variant or "secondary")
    if variant == "primary" then
        return {
            Band({0.050,0.205,0.235},{0.026,0.132,0.158},{0.010,0.066,0.082},0.99),
            Band({0.075,0.275,0.310},{0.040,0.185,0.215},{0.018,0.094,0.112},0.99),
            Band({0.020,0.080,0.100},{0.034,0.142,0.170},{0.060,0.205,0.232},0.99),
            Band({0.040,0.050,0.055},{0.030,0.040,0.045},{0.022,0.030,0.034},0.58),
        }
    elseif variant == "danger" then
        return {
            Band({0.245,0.052,0.038},{0.145,0.028,0.024},{0.070,0.016,0.018},0.96),
            Band({0.420,0.082,0.055},{0.250,0.044,0.036},{0.110,0.022,0.023},0.99),
            Band({0.110,0.020,0.020},{0.230,0.042,0.034},{0.360,0.068,0.048},0.99),
            Solid({0.060,0.038,0.040,0.55}),
        }
    elseif variant == "ghost" or variant == "chrome" then
        return {
            Band({0.024,0.078,0.090},{0.012,0.048,0.060},{0.006,0.026,0.036},0.91),
            Band({0.048,0.158,0.180},{0.026,0.102,0.122},{0.010,0.050,0.066},0.98),
            Band({0.010,0.043,0.054},{0.020,0.082,0.098},{0.036,0.128,0.148},0.99),
            Solid({0.025,0.035,0.040,0.52}),
        }
    elseif variant == "nav" then
        return {
            Band({0.012,0.040,0.049},{0.006,0.026,0.034},{0.004,0.018,0.025},0.89),
            Band({0.026,0.092,0.108},{0.014,0.060,0.074},{0.006,0.032,0.043},0.97),
            Band({0.006,0.027,0.036},{0.015,0.061,0.075},{0.026,0.092,0.108},0.99),
            Solid({0.025,0.035,0.040,0.50}),
        }
    end
    return {
        Band({0.030,0.092,0.106},{0.016,0.058,0.071},{0.007,0.032,0.042},0.94),
        Band({0.050,0.155,0.178},{0.028,0.102,0.120},{0.012,0.050,0.064},0.98),
        Band({0.010,0.040,0.052},{0.022,0.082,0.100},{0.040,0.135,0.158},0.99),
        Solid({0.030,0.040,0.045,0.58}),
    }
end

function A:Apply(component, variant)
    if component == nil or component.root == nil then return component end
    local button = component.root
    local palette = Palette(variant)
    if type(button.rsButtonBgs) == "table" then
        button.rsButtonBgColors = type(button.rsButtonBgColors) == "table" and button.rsButtonBgColors or {}
        for i = 1, 4 do
            ApplyBand(button.rsButtonBgs[i], palette[i])
            local mid = palette[i].mid or { 1, 1, 1 }
            button.rsButtonBgColors[i] = { mid[1], mid[2], mid[3], tonumber(palette[i].alpha) or 1 }
        end
    end
    if button.style ~= nil and type(button.style.SetColor) == "function" then
        local text = S.VisualTokens and S.VisualTokens:Color("textStrong") or {1,1,1,1}
        pcall(function() button.style:SetColor(text[1], text[2], text[3], text[4]) end)
    end
    if S.Visual and S.Visual.Surface then
        local borderTone = (variant == "ghost" or variant == "chrome" or variant == "nav") and "cyanFaint" or "cyanDim"
        S.Visual.Surface:Apply(button, { surface = "cardInset", borderTone = borderTone, topAccent = false, fill = false })
    end
    component.rsActionVariant = variant
    return component
end

function A:Create(spec)
    spec = type(spec) == "table" and spec or {}
    -- Visual-layer buttons prefer the client's verified gradient button skin.
    -- Callers may still explicitly opt out with flat=true for tiny overlays.
    if spec.flat ~= true then spec.gradient = true end
    local c = RSUI:Button(spec)
    if c ~= nil then self:Apply(c, spec.visualVariant or spec.variant or "secondary") end
    return c
end

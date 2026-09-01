------------------------------------------------------------------------
-- Replicated Suite - Styled Dropdown Adapter (M6-v5)
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI = S.RSUI
S.Visual = S.Visual or {}
local D = {}
S.Visual.StyledDropdown = D

local function PaintTrigger(button)
    if button == nil or type(button.rsButtonBgs) ~= "table" then return end
    local palette = {
        {0.014,0.058,0.070,0.99}, {0.032,0.145,0.170,0.99},
        {0.018,0.085,0.102,0.99}, {0.025,0.040,0.046,0.60},
    }
    for i = 1, 4 do
        local d, c = button.rsButtonBgs[i], palette[i]
        if d and c then
            if type(d.ChangeColor1) == "function" and type(d.ChangeColor2) == "function" and type(d.ChangeColor3) == "function" then
                local top = { math.min(1,c[1]*1.45+0.008), math.min(1,c[2]*1.38+0.010), math.min(1,c[3]*1.32+0.012) }
                local bottom = { c[1]*0.52, c[2]*0.58, c[3]*0.64 }
                pcall(function()
                    d:ChangeColor1(top[1],top[2],top[3]); d:ChangeColor2(c[1],c[2],c[3]); d:ChangeColor3(bottom[1],bottom[2],bottom[3])
                    if d.SetAlpha then d:SetAlpha(c[4]) end
                end)
            elseif type(d.SetColor) == "function" then pcall(function() d:SetColor(c[1],c[2],c[3],c[4]) end)
            elseif type(d.SetAlpha) == "function" then pcall(function() d:SetAlpha(c[4]) end) end
        end
    end
end

function D:Create(spec)
    spec = type(spec) == "table" and spec or {}
    local c = RSUI:Dropdown(spec)
    if c == nil or c.dropdown == nil then return c end
    local dd = c.dropdown
    dd.visualStyle = "suite"
    if dd.trigger ~= nil and dd.trigger.style ~= nil and dd.trigger.style.SetColor ~= nil then
        local text = S.VisualTokens:Color("textStrong")
        pcall(function() dd.trigger.style:SetColor(text[1], text[2], text[3], text[4]) end)
    end
    if dd.trigger ~= nil then
        PaintTrigger(dd.trigger)
        if dd.trigger.SetInset then pcall(function() dd.trigger:SetInset(10, 0, 31, 0) end) end
        if S.Visual.Surface then S.Visual.Surface:Apply(dd.trigger, { surface = "cardRaised", borderTone = "cyanSoft", topAccent = false, fill = false }) end
        if dd.trigger.rsDropdownArrowDivider == nil and type(dd.trigger.CreateColorDrawable) == "function" then
            local c = S.VisualTokens:Color("cyanFaint")
            local line = dd.trigger:CreateColorDrawable(c[1],c[2],c[3],c[4],"artwork")
            if line and line.AddAnchor then
                line:AddAnchor("TOPRIGHT", dd.trigger, -27, 4)
                line:AddAnchor("BOTTOMRIGHT", dd.trigger, -27, -4)
                if line.SetWidth then line:SetWidth(1) end
            end
            dd.trigger.rsDropdownArrowDivider = line
        end
    end
    if dd.popup ~= nil and S.Visual.Surface then
        S.Visual.Surface:Apply(dd.popup, {
            surface = "sidebar", borderTone = "goldFaint",
            topAccent = true, accentTone = "goldSoft", accentHeight = 1,
        })
    end

    -- Rows are preallocated by the shared Dropdown authority. Repaint those
    -- bounded rows once instead of allocating a second popup/list implementation.
    for _, button in ipairs(dd.optionButtons or {}) do
        if button ~= nil then
            if button.style and button.style.SetAlign then pcall(function() button.style:SetAlign(ALIGN_LEFT) end) end
            if button.SetInset then pcall(function() button:SetInset(10, 0, 6, 0) end) end
            if S.Visual.ActionButton and type(S.Visual.ActionButton.Apply) == "function" then
                S.Visual.ActionButton:Apply({ root = button }, "nav")
            end
        end
    end
    if S.Visual.AppChrome and type(S.Visual.AppChrome.StyleNativeButton) == "function" then
        S.Visual.AppChrome:StyleNativeButton(dd.up, "chrome")
        S.Visual.AppChrome:StyleNativeButton(dd.down, "chrome")
    end
    return c
end

function D:GroupZones(zones)
    local result, lastGroup = {}, nil
    for _, zone in ipairs(type(zones) == "table" and zones or {}) do
        local label = tostring(zone.continentLabel or "其他")
        if label ~= lastGroup then
            result[#result + 1] = { value = "__group:" .. label, text = "— " .. label .. " —", kind = "header", selectable = false, tone = "brand" }
            lastGroup = label
        end
        result[#result + 1] = {
            value = tonumber(zone.id),
            text = tostring(zone.name or zone.displayName or zone.id or "--"),
            description = tostring(zone.displayName or zone.name or ""),
            continentLabel = label,
        }
    end
    return result
end

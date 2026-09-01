------------------------------------------------------------------------
-- Replicated Suite - App Chrome Visual Helpers (M6-v3)
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Visual = S.Visual or {}
local C = {}
S.Visual.AppChrome = C

function C:DecorateFrame(root)
    if root == nil or S.Visual.Surface == nil then return end
    S.Visual.Surface:Apply(root, { surface = "header", borderTone = "goldSoft", topAccent = true, accentHeight = 2, innerBottom = true })
end

function C:CreateButton(parent, id, text, tooltip, onClick, variant)
    local c = S.Visual.ActionButton:Create({
        id = id, parent = parent, text = tostring(text or ""), fontSize = 10,
        width = 28, height = 24, compact = true, gradient = false,
        visualVariant = variant or "chrome", onClick = onClick,
    })
    c.rsChromeTooltip = tooltip
    return c
end

function C:StyleNativeButton(button, variant)
    if button == nil then return button end
    local colors
    if variant == "danger" then
        colors = { {0.12,0.035,0.030,0.88}, {0.45,0.060,0.045,0.98}, {0.30,0.035,0.030,0.99}, {0.05,0.04,0.04,0.5} }
    else
        colors = { {0.008,0.035,0.044,0.72}, {0.025,0.115,0.135,0.96}, {0.012,0.060,0.075,0.98}, {0.025,0.035,0.040,0.55} }
    end
    if type(button.rsButtonBgs) == "table" then
        for i = 1, 4 do
            local d, c = button.rsButtonBgs[i], colors[i]
            if d ~= nil then
                if type(d.ChangeColor1) == "function" then
                    pcall(function() d:ChangeColor1(c[1],c[2],c[3]); d:ChangeColor2(c[1],c[2],c[3]); d:ChangeColor3(c[1],c[2],c[3]); if d.SetAlpha then d:SetAlpha(c[4]) end end)
                elseif type(d.SetColor) == "function" then
                    pcall(function() d:SetColor(c[1],c[2],c[3],c[4]) end)
                end
            end
        end
    end
    if button.style ~= nil and button.style.SetColor ~= nil and S.VisualTokens ~= nil then
        local c = S.VisualTokens:Color("textStrong")
        pcall(function() button.style:SetColor(c[1],c[2],c[3],c[4]) end)
    end
    if S.Visual.Surface ~= nil then S.Visual.Surface:Apply(button, { surface = "cardInset", borderTone = "separatorSoft", topAccent = false, fill = false }) end
    return button
end

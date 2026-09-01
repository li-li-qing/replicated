------------------------------------------------------------------------
-- Replicated Suite - Visual Surface Decorator (M6-v3)
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Visual = S.Visual or {}
local Surface = {}
S.Visual.Surface = Surface

local function SetColor(drawable, color)
    if drawable == nil or type(color) ~= "table" or type(drawable.SetColor) ~= "function" then return end
    pcall(function() drawable:SetColor(color[1], color[2], color[3], color[4] or 1) end)
end


local function ApplyGradient(drawable, band)
    if drawable == nil or type(band) ~= "table" then return false end
    if type(drawable.ChangeColor1) ~= "function" or type(drawable.ChangeColor2) ~= "function" or type(drawable.ChangeColor3) ~= "function" then return false end
    local top, mid, bottom = band.top or band.mid, band.mid or band.top, band.bottom or band.mid
    if type(top) ~= "table" or type(mid) ~= "table" or type(bottom) ~= "table" then return false end
    pcall(function()
        drawable:ChangeColor1(top[1], top[2], top[3])
        drawable:ChangeColor2(mid[1], mid[2], mid[3])
        drawable:ChangeColor3(bottom[1], bottom[2], bottom[3])
        if drawable.SetAlpha then drawable:SetAlpha(tonumber(band.alpha) or 1) end
    end)
    return true
end

local function Fill(root, color, inset, layer)
    if root == nil or type(root.CreateColorDrawable) ~= "function" then return nil end
    local c = color or { 0, 0, 0, 0 }
    local d = root:CreateColorDrawable(c[1], c[2], c[3], c[4] or 1, layer or "background")
    if d ~= nil and type(d.AddAnchor) == "function" then
        inset = math.max(0, tonumber(inset) or 0)
        d:AddAnchor("TOPLEFT", root, inset, inset)
        d:AddAnchor("BOTTOMRIGHT", root, -inset, -inset)
    end
    return d
end

local function Edge(root, edge, thickness, color, layer)
    if root == nil or type(root.CreateColorDrawable) ~= "function" then return nil end
    local c = color or { 1, 1, 1, 1 }
    local d = root:CreateColorDrawable(c[1], c[2], c[3], c[4] or 1, layer or "artwork")
    if d == nil or type(d.AddAnchor) ~= "function" then return d end
    local t = math.max(1, tonumber(thickness) or 1)
    if edge == "top" then
        d:AddAnchor("TOPLEFT", root, 0, 0); d:AddAnchor("TOPRIGHT", root, 0, t)
        if d.SetHeight then d:SetHeight(t) end
    elseif edge == "bottom" then
        d:AddAnchor("BOTTOMLEFT", root, 0, -t); d:AddAnchor("BOTTOMRIGHT", root, 0, 0)
        if d.SetHeight then d:SetHeight(t) end
    elseif edge == "left" then
        d:AddAnchor("TOPLEFT", root, 0, 0); d:AddAnchor("BOTTOMLEFT", root, t, 0)
        if d.SetWidth then d:SetWidth(t) end
    elseif edge == "right" then
        d:AddAnchor("TOPRIGHT", root, -t, 0); d:AddAnchor("BOTTOMRIGHT", root, 0, 0)
        if d.SetWidth then d:SetWidth(t) end
    end
    return d
end

function Surface:Apply(root, style)
    if root == nil then return nil end
    style = type(style) == "table" and style or {}
    root.rsVisualSurface = root.rsVisualSurface or {}
    local owned = root.rsVisualSurface
    local vt = S.VisualTokens
    local background = style.background or (vt and vt:Color(style.surface or "card"))
    local border = style.border or (vt and vt:Color(style.borderTone or "cyanDim"))
    local accent = style.accent or (vt and vt:Color(style.accentTone or "gold"))

    -- If Theme already owns a flat background, repaint it rather than creating
    -- another full-screen layer. Gradients are left intact; the inner plate
    -- below still guarantees luminance separation when gradient support varies.
    if style.fill ~= false then
        local surfaceKey = tostring(style.surface or "card")
        local band = vt and type(vt.gradient) == "table" and vt.gradient[surfaceKey] or nil
        if root.rsBackground ~= nil and ApplyGradient(root.rsBackground, band) then
            root.rsBackgroundColor = { 1, 1, 1, tonumber(band and band.alpha) or 1 }
        elseif root.rsBackground ~= nil and type(root.rsBackground.ChangeColor1) ~= "function" then
            SetColor(root.rsBackground, background)
            root.rsBackgroundColor = background
        elseif owned.innerPlate == nil then
            owned.innerPlate = Fill(root, background, tonumber(style.inset) or 1, "background")
        end
    end
    if root.rsBorder ~= nil and type(root.rsBorder.ChangeColor1) ~= "function" then
        SetColor(root.rsBorder, border)
        root.rsBorderColor = border
    end

    if style.topAccent ~= false and owned.topAccent == nil then
        owned.topAccent = Edge(root, "top", tonumber(style.accentHeight) or 2, accent, "artwork")
    end
    if style.innerBottom == true and owned.innerBottom == nil then
        owned.innerBottom = Edge(root, "bottom", 1, vt and vt:Color("separatorSoft") or border, "artwork")
    end
    if style.leftAccent == true and owned.leftAccent == nil then
        owned.leftAccent = Edge(root, "left", tonumber(style.leftAccentWidth) or 3, accent, "artwork")
    end
    if style.cornerCaps == true and owned.cornerCaps == nil then
        local c = style.cornerColor or border or accent
        local len = math.max(4, tonumber(style.cornerLength) or 9)
        local t = math.max(1, tonumber(style.cornerThickness) or 1)
        owned.cornerCaps = {}
        local function cap(xAnchor, yAnchor, x, y, w, h)
            if type(root.CreateColorDrawable) ~= "function" then return end
            local d = root:CreateColorDrawable(c[1],c[2],c[3],c[4] or 1,"artwork")
            if d then
                if d.SetExtent then d:SetExtent(w,h) end
                if d.AddAnchor then d:AddAnchor(xAnchor, root, yAnchor, x, y) end
                owned.cornerCaps[#owned.cornerCaps+1] = d
            end
        end
        cap("TOPLEFT","TOPLEFT",0,0,len,t); cap("TOPLEFT","TOPLEFT",0,0,t,len)
        cap("TOPRIGHT","TOPRIGHT",0,0,len,t); cap("TOPRIGHT","TOPRIGHT",0,0,t,len)
        cap("BOTTOMLEFT","BOTTOMLEFT",0,0,len,t); cap("BOTTOMLEFT","BOTTOMLEFT",0,0,t,len)
        cap("BOTTOMRIGHT","BOTTOMRIGHT",0,0,len,t); cap("BOTTOMRIGHT","BOTTOMRIGHT",0,0,t,len)
    end
    return owned
end

function Surface:SetLeftAccentVisible(root, visible)
    local owned = root and root.rsVisualSurface
    local d = owned and owned.leftAccent or nil
    if d ~= nil and type(d.SetVisible) == "function" then pcall(function() d:SetVisible(visible == true) end) end
end

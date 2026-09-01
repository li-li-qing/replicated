------------------------------------------------------------------------
-- Replicated Suite - Navigation Visual Composites (M6-v6)
--
-- The RU client does not render several Unicode symbol glyphs consistently.
-- M6-v6 replaces those text placeholders with tiny geometric icons built from
-- bounded ColorDrawables.  They are allocated once per nav item, recolored only
-- when selection changes, and require no texture lookup or runtime update.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI = S.RSUI
S.Visual = S.Visual or {}
local N = {}
S.Visual.Nav = N

local function Rect(root, x, y, w, h, color)
    if root == nil or type(root.CreateColorDrawable) ~= "function" then return nil end
    color = type(color) == "table" and color or { 1, 1, 1, 1 }
    local d = root:CreateColorDrawable(color[1], color[2], color[3], color[4] or 1, "artwork")
    if d ~= nil then
        if d.SetExtent then d:SetExtent(math.max(1, w), math.max(1, h)) end
        if d.AddAnchor then d:AddAnchor("TOPLEFT", root, x, y) end
    end
    return d
end

local function Add(drawables, root, x, y, w, h, color)
    local d = Rect(root, x, y, w, h, color)
    if d ~= nil then drawables[#drawables + 1] = d end
end

local function CreateGlyph(root, kind, opts)
    local V = S.VisualTokens
    local color = V and V:Color("gold") or {0.92,0.70,0.29,1}
    local d = {}
    kind = tostring(kind or "page")
    opts = type(opts) == "table" and opts or {}
    local ox, oy = tonumber(opts.ox) or 10, tonumber(opts.oy) or 4

    if kind == "home" then
        Add(d,root,ox+2,oy+2,12,2,color); Add(d,root,ox+2,oy+12,12,2,color)
        Add(d,root,ox+2,oy+4,2,8,color); Add(d,root,ox+12,oy+4,2,8,color)
        Add(d,root,ox+7,oy+7,3,7,color)
    elseif kind == "team" then
        Add(d,root,ox+1,oy+4,4,4,color); Add(d,root,ox+7,oy+2,4,4,color); Add(d,root,ox+13,oy+4,4,4,color)
        Add(d,root,ox,oy+11,6,2,color); Add(d,root,ox+6,oy+9,6,2,color); Add(d,root,ox+12,oy+11,6,2,color)
    elseif kind == "dps" then
        Add(d,root,ox+1,oy+10,3,5,color); Add(d,root,ox+7,oy+6,3,9,color); Add(d,root,ox+13,oy+2,3,13,color)
    elseif kind == "healer" then
        Add(d,root,ox+7,oy+2,4,14,color); Add(d,root,ox+2,oy+7,14,4,color)
    elseif kind == "gear" then
        Add(d,root,ox+1,oy+2,6,5,color); Add(d,root,ox+11,oy+2,6,5,color)
        Add(d,root,ox+1,oy+11,6,5,color); Add(d,root,ox+11,oy+11,6,5,color)
        Add(d,root,ox+8,oy+7,2,4,color)
    elseif kind == "buff" then
        Add(d,root,ox+1,oy+3,4,4,color); Add(d,root,ox+7,oy+3,10,2,color)
        Add(d,root,ox+1,oy+8,4,4,color); Add(d,root,ox+7,oy+8,8,2,color)
        Add(d,root,ox+1,oy+13,4,4,color); Add(d,root,ox+7,oy+13,6,2,color)
    elseif kind == "activity" then
        Add(d,root,ox+7,oy+1,4,3,color); Add(d,root,ox+7,oy+14,4,3,color)
        Add(d,root,ox+1,oy+7,3,4,color); Add(d,root,ox+14,oy+7,3,4,color)
        Add(d,root,ox+7,oy+7,4,4,color)
    elseif kind == "trade" then
        Add(d,root,ox+1,oy+4,13,2,color); Add(d,root,ox+13,oy+2,4,6,color)
        Add(d,root,ox+4,oy+12,13,2,color); Add(d,root,ox+1,oy+10,4,6,color)
    elseif kind == "bond" then
        Add(d,root,ox+1,oy+2,7,6,color); Add(d,root,ox+10,oy+2,7,6,color)
        Add(d,root,ox+1,oy+10,7,6,color); Add(d,root,ox+10,oy+10,7,6,color)
    elseif kind == "task" then
        for i=0,2 do
            Add(d,root,ox+1,oy+2+i*5,3,3,color); Add(d,root,ox+6,oy+3+i*5,11,1,color)
        end
    elseif kind == "treasure" then
        Add(d,root,ox+7,oy+6,4,4,color)
        Add(d,root,ox+2,oy+2,3,3,color); Add(d,root,ox+13,oy+2,3,3,color)
        Add(d,root,ox+2,oy+13,3,3,color); Add(d,root,ox+13,oy+13,3,3,color)
    elseif kind == "fishing" then
        Add(d,root,ox+1,oy+4,13,2,color); Add(d,root,ox+4,oy+9,13,2,color); Add(d,root,ox+1,oy+14,13,2,color)
    elseif kind == "bag" then
        for row=0,1 do for col=0,2 do Add(d,root,ox+1+col*5,oy+4+row*6,4,4,color) end end
    elseif kind == "hud" then
        Add(d,root,ox+1,oy+2,6,2,color); Add(d,root,ox+1,oy+2,2,6,color)
        Add(d,root,ox+11,oy+2,6,2,color); Add(d,root,ox+15,oy+2,2,6,color)
        Add(d,root,ox+1,oy+14,6,2,color); Add(d,root,ox+1,oy+10,2,6,color)
        Add(d,root,ox+11,oy+14,6,2,color); Add(d,root,ox+15,oy+10,2,6,color)
    elseif kind == "modules" then
        Add(d,root,ox+2,oy+2,5,5,color); Add(d,root,ox+10,oy+2,5,5,color)
        Add(d,root,ox+2,oy+10,5,5,color); Add(d,root,ox+10,oy+10,5,5,color)
    elseif kind == "quick" then
        Add(d,root,ox+2,oy+12,4,3,color); Add(d,root,ox+7,oy+8,4,7,color); Add(d,root,ox+12,oy+3,4,12,color)
    elseif kind == "settings" then
        Add(d,root,ox+1,oy+3,16,2,color); Add(d,root,ox+11,oy+1,3,6,color)
        Add(d,root,ox+1,oy+8,16,2,color); Add(d,root,ox+5,oy+6,3,6,color)
        Add(d,root,ox+1,oy+13,16,2,color); Add(d,root,ox+12,oy+11,3,6,color)
    elseif kind == "diagnostics" then
        Add(d,root,ox+2,oy+10,3,6,color); Add(d,root,ox+7,oy+5,3,11,color); Add(d,root,ox+12,oy+2,3,14,color)
    else
        Add(d,root,ox+3,oy+3,12,12,color); Add(d,root,ox+6,oy+6,6,6,{0.01,0.03,0.04,1})
    end
    return d
end

local function PaintGlyph(drawables, selected)
    local V = S.VisualTokens
    local c = V and V:Color(selected and "cyan" or "gold") or {1,1,1,1}
    local alpha = selected and 1.0 or 0.84
    for _, d in ipairs(type(drawables) == "table" and drawables or {}) do
        if d and d.SetColor then pcall(function() d:SetColor(c[1],c[2],c[3],alpha) end) end
    end
end


function N:CreateGlyph(root, kind, opts)
    return CreateGlyph(root, kind, opts)
end

function N:PaintGlyph(drawables, tone)
    local V = S.VisualTokens
    local c = V and V:Color(tostring(tone or "gold")) or {1,1,1,1}
    for _, d in ipairs(type(drawables) == "table" and drawables or {}) do
        if d and d.SetColor then pcall(function() d:SetColor(c[1],c[2],c[3],c[4] or 1) end) end
    end
end

function N:CreateGroupHeader(parent, id, title)
    local header = RSUI:Border({
        id = id, parent = parent, height = 20,
        padding = { left = 8, right = 4, top = 1, bottom = 1 },
        variant = "soft", gradient = true,
        slot = { size = "fixed", height = 20, hAlign = "fill" },
    })
    if header and S.Visual.Surface then
        S.Visual.Surface:Apply(header.root, { surface = "section", borderTone = "separatorSoft", topAccent = false, innerBottom = true })
    end
    local row = RSUI:HorizontalBox({ id = id .. "_row", parent = header, gap = 6 })
    local marker = RSUI:Border({
        id = id .. "_marker", parent = row, width = 4, height = 4, padding = 0,
        variant = "soft", gradient = false,
        slot = { size = "fixed", width = 4, hAlign = "fill", vAlign = "center" },
    })
    if marker and S.Visual.Surface then S.Visual.Surface:Apply(marker.root, { surface = "gold", borderTone = "gold", topAccent = false }) end
    RSUI:Text({
        id = id .. "_title", parent = row, text = tostring(title or ""),
        tone = "brand", fontSize = 9, shadow = true, overflow = "ellipsis",
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "center" },
    })
    return header
end

function N:CreateSection(parent, id, title)
    local section = {}
    section.component = RSUI:Border({
        id = id, parent = parent,
        padding = { left = 4, right = 4, top = 2, bottom = 3 },
        variant = "soft", gradient = true,
        slot = { size = "auto", hAlign = "fill", padding = { bottom = 2 } },
    })
    if section.component and S.Visual.Surface then
        S.Visual.Surface:Apply(section.component.root, { surface = "section", borderTone = "separatorSoft", topAccent = false })
    end

    section.stack = RSUI:VerticalBox({ id = id .. "_stack", parent = section.component, gap = 0 })
    section.header = RSUI:Border({
        id = id .. "_header", parent = section.stack, height = 20,
        padding = { left = 8, right = 4, top = 1, bottom = 1 },
        variant = "soft", gradient = true,
        slot = { size = "fixed", height = 20, hAlign = "fill" },
    })
    if section.header and S.Visual.Surface then
        S.Visual.Surface:Apply(section.header.root, { surface = "section", borderTone = "separatorSoft", topAccent = false, innerBottom = true })
    end

    section.headerRow = RSUI:HorizontalBox({ id = id .. "_header_row", parent = section.header, gap = 6 })
    section.marker = RSUI:Border({
        id = id .. "_marker", parent = section.headerRow, width = 4, height = 4,
        padding = 0, variant = "soft", gradient = false,
        slot = { size = "fixed", width = 4, hAlign = "fill", vAlign = "center" },
    })
    if section.marker and S.Visual.Surface then S.Visual.Surface:Apply(section.marker.root, { surface = "gold", borderTone = "gold", topAccent = false }) end
    section.title = RSUI:Text({
        id = id .. "_title", parent = section.headerRow, text = tostring(title or ""),
        tone = "brand", fontSize = 10, shadow = true, overflow = "ellipsis",
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "center" },
    })
    return section
end

function N:CreateItem(parent, id, text, onClick, iconKind)
    local component = S.Visual.ActionButton:Create({
        id = id, parent = parent, text = tostring(text or ""), fontSize = 10,
        height = 26, compact = true, visualVariant = "nav",
        slot = { size = "fixed", height = 26, hAlign = "fill", padding = { left = 2, right = 2 } },
        onClick = onClick,
    })
    if component == nil then return nil end
    local root = component.root

    if root.style and root.style.SetAlign then pcall(function() root.style:SetAlign(ALIGN_LEFT) end) end
    if root.SetInset then pcall(function() root:SetInset(38, 0, 7, 0) end) end

    if S.Visual.Surface then
        S.Visual.Surface:Apply(root, {
            surface = "cardInset", borderTone = "separatorSoft", topAccent = false, fill = false,
            leftAccent = true, leftAccentWidth = 3, accentTone = "cyan",
        })
        S.Visual.Surface:SetLeftAccentVisible(root, false)
    end

    component.iconDrawables = CreateGlyph(root, iconKind)
    PaintGlyph(component.iconDrawables, false)

    local base = component.SetSelected
    function component:SetSelected(selected)
        local value = selected == true
        local changed = base(self, value)
        if S.Visual and S.Visual.Surface then S.Visual.Surface:SetLeftAccentVisible(self.root, value) end
        if self.root ~= nil and self.root.style ~= nil and self.root.style.SetColor ~= nil then
            local c = S.VisualTokens:Color(value and "textStrong" or "tableHeaderText") or {1,1,1,1}
            pcall(function() self.root.style:SetColor(c[1], c[2], c[3], c[4]) end)
        end
        PaintGlyph(self.iconDrawables, value)
        if value and type(self.root.rsButtonBgs) == "table" then
            local selectedBand = {
                top={0.035,0.155,0.180}, mid={0.022,0.108,0.130}, bottom={0.010,0.054,0.070}, alpha=0.98,
            }
            for _, bg in ipairs(self.root.rsButtonBgs) do
                if bg and type(bg.ChangeColor1)=="function" then
                    pcall(function()
                        bg:ChangeColor1(selectedBand.top[1],selectedBand.top[2],selectedBand.top[3])
                        bg:ChangeColor2(selectedBand.mid[1],selectedBand.mid[2],selectedBand.mid[3])
                        bg:ChangeColor3(selectedBand.bottom[1],selectedBand.bottom[2],selectedBand.bottom[3])
                        if bg.SetAlpha then bg:SetAlpha(selectedBand.alpha) end
                    end)
                elseif bg and bg.SetColor then
                    pcall(function() bg:SetColor(selectedBand.mid[1],selectedBand.mid[2],selectedBand.mid[3],selectedBand.alpha) end)
                end
            end
        elseif not value then
            S.Visual.ActionButton:Apply(self, "nav")
        end
        return changed
    end
    return component
end

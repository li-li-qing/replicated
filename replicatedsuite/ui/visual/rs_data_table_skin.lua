------------------------------------------------------------------------
-- Replicated Suite - Data Table Visual Skin (M6-v6)
--
-- Decoration is attached once to each virtualized pool row. M6-v6 gives the
-- header a verified ThreeColorDrawable band while retaining flat, low-cost row
-- fills for fast hover/selection repaint. No data refresh allocates drawables.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Visual = S.Visual or {}
local T = {}
S.Visual.TableSkin = T

local function MakeFill(root, color)
    if root == nil or type(root.CreateColorDrawable) ~= "function" then return nil end
    local d = root:CreateColorDrawable(color[1], color[2], color[3], color[4] or 1, "background")
    if d and d.AddAnchor then d:AddAnchor("TOPLEFT", root, 0, 0); d:AddAnchor("BOTTOMRIGHT", root, 0, 0) end
    return d
end

local function MakeHeaderGradient(root)
    if root == nil or type(root.CreateThreeColorDrawable) ~= "function" then return nil end
    local ok, d = pcall(function()
        local g = root:CreateThreeColorDrawable(16,16,"background")
        if g == nil or type(g.ChangeColor1)~="function" or type(g.ChangeColor2)~="function" or type(g.ChangeColor3)~="function" then return nil end
        g:ChangeColor1(0.040,0.135,0.150)
        g:ChangeColor2(0.022,0.082,0.096)
        g:ChangeColor3(0.009,0.042,0.054)
        if g.SetAlpha then g:SetAlpha(0.99) end
        if g.AddAnchor then g:AddAnchor("TOPLEFT",root,0,0); g:AddAnchor("BOTTOMRIGHT",root,0,0) end
        return g
    end)
    return ok and d or nil
end

local function Paint(d, c)
    if d and c and d.SetColor then pcall(function() d:SetColor(c[1],c[2],c[3],c[4] or 1) end) end
end

function T:Decorate(row)
    if row == nil or row.root == nil or row.rsTableVisual ~= nil then return end
    local V = S.VisualTokens
    local headerFill = row.header and MakeHeaderGradient(row.root) or nil
    row.rsTableVisual = {
        fill = headerFill or MakeFill(row.root, V:Color(row.header and "tableHeader" or "rowA")),
        headerGradient = headerFill ~= nil,
        selected = false,
        hovered = false,
    }
    if row.header and S.Visual.Surface then
        S.Visual.Surface:Apply(row.root, { surface = "tableHeader", borderTone = "cyanDim", topAccent = false, innerBottom = true, fill = false })
    end
    if row.root.Clickable and row.spec and row.spec.pickable == true then pcall(function() row.root:Clickable(true) end) end
    if row.spec and row.spec.pickable == true and S.UI and S.UI.SafeHandler then
        S.UI:SafeHandler(row.root, "OnEnter", function() row.rsTableVisual.hovered = true; T:Refresh(row) end, "table:hover:" .. tostring(row.id))
        S.UI:SafeHandler(row.root, "OnLeave", function() row.rsTableVisual.hovered = false; T:Refresh(row) end, "table:leave:" .. tostring(row.id))
    end
end

function T:ApplyItem(row, index)
    if row == nil then return end
    self:Decorate(row)
    row.rsTableVisual.index = tonumber(index) or 1
    self:Refresh(row)
end

function T:SetSelected(row, selected)
    if row == nil then return false end
    self:Decorate(row)
    local v = selected == true
    if row.rsTableVisual.selected == v then return false end
    row.rsTableVisual.selected = v
    self:Refresh(row)
    return true
end

function T:Refresh(row)
    local state = row and row.rsTableVisual
    if state == nil then return end
    if row.header and state.headerGradient == true then return end
    local V = S.VisualTokens
    local key
    if row.header then key = "tableHeader"
    elseif state.selected then key = "rowSelected"
    elseif state.hovered then key = "rowHover"
    elseif ((tonumber(state.index) or 1) % 2) == 0 then key = "rowB"
    else key = "rowA" end
    Paint(state.fill, V:Color(key))
end

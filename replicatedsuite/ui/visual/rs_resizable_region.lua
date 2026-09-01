------------------------------------------------------------------------
-- Replicated Suite - Resizable Region / Splitter Composite (M6-v7)
--
-- Presentation-only drag helper.  It does NOT own layout state: callers keep
-- the authoritative normalized split preference and re-run their normal RSUI
-- layout after the drag commits.  Native StartSizing is used only during an
-- explicit user drag, so there is no permanent Tick/OnUpdate work.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local UI = S.UI
S.Visual = S.Visual or {}
local R = {}
S.Visual.ResizableRegion = R

local function Color(key, fallback)
    local vt = S.VisualTokens
    return vt and vt:Color(key, fallback) or fallback
end

local function SetDrawableColor(drawable, color)
    if drawable == nil or type(color) ~= "table" or type(drawable.SetColor) ~= "function" then return end
    pcall(function() drawable:SetColor(color[1] or 1, color[2] or 1, color[3] or 1, color[4] or 1) end)
end

function R:Attach(spec)
    spec = type(spec) == "table" and spec or {}
    local target = spec.target
    local root = type(target) == "table" and target.root or target
    if root == nil or UI == nil or type(UI.CreateEmptyWidget) ~= "function" then return nil end

    local id = tostring(spec.id or "rs_splitter")
    local thickness = math.max(5, tonumber(spec.thickness) or 8)
    local handle = UI:CreateEmptyWidget(root, id, 0, 0, 40, thickness, true)
    if handle == nil then return nil end
    if type(handle.Enable) == "function" then pcall(function() handle:Enable(true) end) end
    if type(handle.EnablePick) == "function" then pcall(function() handle:EnablePick(true, true) end) end
    if type(handle.Clickable) == "function" then pcall(function() handle:Clickable(true, true) end) end
    if type(handle.EnableDrag) == "function" then pcall(function() handle:EnableDrag(true) end) end
    if type(handle.SetDragCondition) == "function" and DC_ALWAYS ~= nil then pcall(function() handle:SetDragCondition(DC_ALWAYS) end) end

    handle:RemoveAllAnchors()
    -- Keep the hit target fully inside the card so child clipping cannot hide
    -- the splitter on the RU client.  Both horizontal anchors share the same
    -- inset; SetHeight supplies the vertical hit range.
    handle:AddAnchor("BOTTOMLEFT", root, 0, -thickness)
    handle:AddAnchor("BOTTOMRIGHT", root, 0, -thickness)
    handle:SetHeight(thickness)

    local hit = nil
    local line = nil
    local grip = nil
    if type(handle.CreateColorDrawable) == "function" then
        hit = handle:CreateColorDrawable(0, 0, 0, 0.001, "overlay")
        if hit and hit.AddAnchor then hit:AddAnchor("TOPLEFT", handle, 0, 0); hit:AddAnchor("BOTTOMRIGHT", handle, 0, 0) end
        local lineColor = Color("separatorSoft", {0.05,0.18,0.20,0.45})
        line = handle:CreateColorDrawable(lineColor[1], lineColor[2], lineColor[3], lineColor[4] or 0.45, "artwork")
        if line and line.AddAnchor then line:AddAnchor("LEFT", handle, 12, 0); line:AddAnchor("RIGHT", handle, -12, 0); if line.SetHeight then line:SetHeight(1) end end
        local gripColor = Color("cyanDim", {0.08,0.30,0.34,0.7})
        grip = handle:CreateColorDrawable(gripColor[1], gripColor[2], gripColor[3], gripColor[4] or 0.7, "overlay")
        if grip then
            if grip.SetExtent then grip:SetExtent(math.max(28, tonumber(spec.gripWidth) or 44), 2) end
            if grip.AddAnchor then grip:AddAnchor("CENTER", handle, 0, 0) end
        end
    end

    local api = { root = handle, target = root, line = line, grip = grip, dragging = false }
    function api:SetVisible(visible)
        if self.root ~= nil and type(self.root.Show) == "function" then self.root:Show(visible == true) end
    end

    local function Hover(active)
        SetDrawableColor(grip, Color(active and "cyan" or "cyanDim", active and {0.2,0.74,0.84,1} or {0.08,0.30,0.34,0.7}))
    end
    UI:SafeHandler(handle, "OnEnter", function() Hover(true) end, id .. ":enter")
    UI:SafeHandler(handle, "OnLeave", function() if not api.dragging then Hover(false) end end, id .. ":leave")

    UI:SafeHandler(handle, "OnDragStart", function()
        if type(spec.canDrag) == "function" and spec.canDrag() ~= true then return false end
        local width = type(root.GetWidth) == "function" and tonumber(root:GetWidth()) or 1
        local height = type(root.GetHeight) == "function" and tonumber(root:GetHeight()) or 1
        local minH = math.max(40, tonumber(type(spec.getMinHeight)=="function" and spec.getMinHeight() or spec.minHeight) or 80)
        local maxH = math.max(minH, tonumber(type(spec.getMaxHeight)=="function" and spec.getMaxHeight() or spec.maxHeight) or 900)
        if type(root.UseResizing) == "function" then pcall(function() root:UseResizing(true) end) end
        if type(root.SetMinResizingExtent) == "function" then pcall(function() root:SetMinResizingExtent(math.max(1,width), minH) end) end
        if type(root.SetMaxResizingExtent) == "function" then pcall(function() root:SetMaxResizingExtent(math.max(1,width), maxH) end) end
        if type(root.StartSizing) ~= "function" then return false end
        api.dragging = true
        Hover(true)
        root:StartSizing("BOTTOM")
        return true
    end, id .. ":drag_start")

    UI:SafeHandler(handle, "OnDragStop", function()
        if type(root.StopMovingOrSizing) == "function" then pcall(function() root:StopMovingOrSizing() end) end
        local height = type(root.GetHeight) == "function" and tonumber(root:GetHeight()) or nil
        api.dragging = false
        Hover(false)
        if height ~= nil and type(spec.onCommit) == "function" then
            local ok, err = pcall(spec.onCommit, height, api)
            if not ok and S.DiagnosticsManager and type(S.DiagnosticsManager.Emit)=="function" then
                S.DiagnosticsManager:Emit("error", "ui", "splitter_commit_failed", tostring(err), { id=id })
            end
        end
        return true
    end, id .. ":drag_stop")

    if type(handle.Raise) == "function" then pcall(function() handle:Raise() end) end
    handle:Show(spec.visible ~= false)
    return api
end

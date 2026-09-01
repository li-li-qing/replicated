------------------------------------------------------------------------
-- Replicated Suite - RSUI Layout Debug Overlay v1
--
-- Explicit diagnostics only.  The overlay never registers Tick/OnUpdate and
-- only scans/refreshes when the developer calls Refresh().  Native widgets are
-- pooled because RU has no validated generic DestroyWidget API.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local UI, RSUI = S.UI, S.RSUI
if type(UI) ~= "table" or type(RSUI) ~= "table" then return end

local Debug = { version = 1 }
RSUI.LayoutDebug = Debug

local function Metrics()
    if S.Api ~= nil and type(S.Api.GetUiMetrics) == "function" then
        local ok, _, _, _, w, h = pcall(function() return S.Api:GetUiMetrics() end)
        if ok and tonumber(w) and tonumber(h) then return tonumber(w), tonumber(h) end
    end
    return 1024, 768
end

local function AddEdge(host, r, g, b, a, anchorA, anchorB, thickness)
    if host == nil or type(host.CreateColorDrawable) ~= "function" then return nil end
    local draw = host:CreateColorDrawable(r, g, b, a, "overlay")
    if draw == nil then return nil end
    draw.rsUiOwner = host.rsUiOwner
    if type(draw.AddAnchor) == "function" then
        if anchorA == "TOP" then
            draw:AddAnchor("TOPLEFT", host, 0, 0); draw:AddAnchor("TOPRIGHT", host, 0, 0)
            if type(draw.SetHeight) == "function" then draw:SetHeight(thickness) elseif type(draw.SetExtent) == "function" then draw:SetExtent(1, thickness) end
        elseif anchorA == "BOTTOM" then
            draw:AddAnchor("BOTTOMLEFT", host, 0, 0); draw:AddAnchor("BOTTOMRIGHT", host, 0, 0)
            if type(draw.SetHeight) == "function" then draw:SetHeight(thickness) elseif type(draw.SetExtent) == "function" then draw:SetExtent(1, thickness) end
        elseif anchorA == "LEFT" then
            draw:AddAnchor("TOPLEFT", host, 0, 0); draw:AddAnchor("BOTTOMLEFT", host, 0, 0)
            if type(draw.SetWidth) == "function" then draw:SetWidth(thickness) elseif type(draw.SetExtent) == "function" then draw:SetExtent(thickness, 1) end
        else
            draw:AddAnchor("TOPRIGHT", host, 0, 0); draw:AddAnchor("BOTTOMRIGHT", host, 0, 0)
            if type(draw.SetWidth) == "function" then draw:SetWidth(thickness) elseif type(draw.SetExtent) == "function" then draw:SetExtent(thickness, 1) end
        end
    end
    return draw
end

local function CreateBox(overlay, index)
    local box = UI:CreateEmptyWidget(overlay.root, overlay.id .. "_box_" .. tostring(index), 0, 0, 1, 1, false)
    if box == nil then return nil end
    box.rsUiOwner = overlay.owner
    local normal = { 0.24, 0.70, 1.00, 0.86 }
    box.edges = {
        AddEdge(box, normal[1], normal[2], normal[3], normal[4], "TOP", nil, 1),
        AddEdge(box, normal[1], normal[2], normal[3], normal[4], "BOTTOM", nil, 1),
        AddEdge(box, normal[1], normal[2], normal[3], normal[4], "LEFT", nil, 1),
        AddEdge(box, normal[1], normal[2], normal[3], normal[4], "RIGHT", nil, 1),
    }
    box.label = UI:CreateLabel(box, overlay.id .. "_label_" .. tostring(index), "", 2, 2, 180, 16, 9, "info", ALIGN_LEFT, true)
    if box.label ~= nil then box.label.rsUiOwner = overlay.owner end
    UI:SetVisible(box, false, overlay.owner)
    return box
end

local function SetIssueTone(box, issue, owner)
    if box == nil then return end
    local r, g, b, a
    if issue then r, g, b, a = 1.0, 0.25, 0.18, 0.95 else r, g, b, a = 0.24, 0.70, 1.00, 0.86 end
    for _, edge in ipairs(box.edges or {}) do if edge ~= nil then UI:SetColor(edge, r, g, b, a, owner) end end
end

function Debug:CreateOverlay(spec)
    spec = type(spec) == "table" and spec or {}
    local parent = spec.parent or UIParent
    if parent == nil then return nil, "parent_required" end
    local id = tostring(spec.id or "rsui_layout_inspector")
    local w, h = Metrics()
    local root = UI:CreateEmptyWidget(parent, id, 0, 0, w, h, false)
    if root == nil then return nil, "overlay_create_failed" end
    root.rsUiOwner = tostring(spec.owner or "rsui:layout_debug")
    local overlay = {
        id = id,
        root = root,
        owner = root.rsUiOwner,
        boxes = {},
        maxNodes = math.max(1, math.min(tonumber(spec.maxNodes) or 80, 160)),
        showLabels = spec.showLabels ~= false,
        visible = true,
        lastReport = nil,
    }

    function overlay:EnsureBox(index)
        if self.boxes[index] ~= nil then return self.boxes[index] end
        local box = CreateBox(self, index)
        self.boxes[index] = box
        return box
    end

    function overlay:SetVisible(visible)
        self.visible = visible == true
        UI:SetVisible(self.root, self.visible, self.owner)
        return self.visible
    end

    function overlay:Hide()
        for _, box in ipairs(self.boxes) do if box ~= nil then UI:SetVisible(box, false, self.owner) end end
        self:SetVisible(false)
        return true
    end

    function overlay:Refresh(component, options)
        if not RSUI:IsComponent(component) then return false, "component_required" end
        options = type(options) == "table" and options or {}
        local vw, vh = Metrics()
        UI:SetExtent(self.root, vw, vh, self.owner)
        UI:SetAnchor(self.root, parent, 0, 0, self.owner)
        self:SetVisible(true)
        local report = RSUI:InspectLayout(component, { maxNodes = math.min(self.maxNodes, tonumber(options.maxNodes) or self.maxNodes), maxDepth = options.maxDepth })
        self.lastReport = report
        local issueByPath = {}
        for _, issue in ipairs(report.issues or {}) do issueByPath[issue.path] = issue end
        local pathMap = {}
        local function mapTree(node, path, depth)
            if node == nil or depth > 32 or pathMap[path] ~= nil then return end
            pathMap[path] = node
            for _, child in ipairs(node.children or {}) do mapTree(child, path .. "/" .. tostring(child.id or "?"), depth + 1) end
        end
        mapTree(component, tostring(component.id or "root"), 0)
        local used = 0
        for _, row in ipairs(report.rows or {}) do
            local node = pathMap[row.path]
            local rect = node and RSUI:GetAbsoluteRect(node) or nil
            if rect ~= nil and rect.width > 0 and rect.height > 0 then
                used = used + 1
                local box = self:EnsureBox(used)
                if box ~= nil then
                    UI:SetExtent(box, math.max(1, rect.width), math.max(1, rect.height), self.owner)
                    UI:SetAnchor(box, self.root, rect.x, rect.y, self.owner)
                    SetIssueTone(box, issueByPath[row.path] ~= nil, self.owner)
                    if box.label ~= nil then
                        UI:SetText(box.label, tostring(row.kind or "?") .. ":" .. tostring(row.id or "?"), self.owner)
                        UI:SetVisible(box.label, self.showLabels, self.owner)
                    end
                    UI:SetVisible(box, true, self.owner)
                end
            end
            if used >= self.maxNodes then break end
        end
        for i = used + 1, #self.boxes do if self.boxes[i] ~= nil then UI:SetVisible(self.boxes[i], false, self.owner) end end
        RSUI.metrics.debugOverlayRefreshes = (tonumber(RSUI.metrics.debugOverlayRefreshes) or 0) + 1
        return true, report
    end

    function overlay:Release()
        self:Hide()
        return true
    end

    return overlay
end

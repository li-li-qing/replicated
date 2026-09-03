------------------------------------------------------------------------
-- Replicated Suite - RSUI Layout Safety / Resolution Components v1
--
-- UMG-inspired safety layer.  Everything here is explicit/event driven:
-- there is no Tick registration and no hidden polling loop.
--
-- Authority:
--   * S.Api:GetUiMetrics() is the logical viewport Authority.
--   * ResolutionRoot owns viewport-sized composition, not business state.
--   * SafeZone owns edge insets / screen-safe arrangement.
--   * CanvasPanel is intentionally limited to screen-space/HUD/debug cases.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local UI, RSUI = S.UI, S.RSUI
if type(UI) ~= "table" or type(RSUI) ~= "table" then return end
local U = RSUI.LayoutUtil
if type(U) ~= "table" then return end

local N, Clamp, Pad, Measure, Align, Arrange, Host = U.N, U.Clamp, U.Pad, U.Measure, U.Align, U.Arrange, U.Host
local Base = RSUI.BaseComponent

local function GetUiMetrics()
    if S.Api ~= nil and type(S.Api.GetUiMetrics) == "function" then
        local ok, sw, sh, scale, lw, lh = pcall(function() return S.Api:GetUiMetrics() end)
        if ok then
            lw, lh, scale = tonumber(lw), tonumber(lh), tonumber(scale)
            if lw and lw > 0 and lh and lh > 0 then return lw, lh, (scale and scale > 0) and scale or 1, tonumber(sw), tonumber(sh) end
        end
    end
    local w, h = nil, nil
    if UIParent ~= nil and type(UIParent.GetExtent) == "function" then
        local ok, a, b = pcall(function() return UIParent:GetExtent() end)
        if ok then w, h = tonumber(a), tonumber(b) end
    end
    w = (w and w > 0) and w or 1024
    h = (h and h > 0) and h or 768
    return w, h, 1, w, h
end

local function ResolveInset(spec, width, height)
    local base = Pad(spec.safePadding or spec.padding or spec.margin or 0)
    local edge = math.max(0, tonumber(spec.edgePercent) or 0)
    local hx = math.max(0, tonumber(spec.horizontalPercent) or edge)
    local vy = math.max(0, tonumber(spec.verticalPercent) or edge)
    base.left = base.left + width * hx
    base.right = base.right + width * hx
    base.top = base.top + height * vy
    base.bottom = base.bottom + height * vy
    return base
end

local function ClampInsets(inset, width, height)
    local changed = false
    local sumX, sumY = inset.left + inset.right, inset.top + inset.bottom
    if sumX >= width and sumX > 0 then
        local factor = math.max(0, (width - 1) / sumX)
        inset.left, inset.right = inset.left * factor, inset.right * factor
        changed = true
    end
    if sumY >= height and sumY > 0 then
        local factor = math.max(0, (height - 1) / sumY)
        inset.top, inset.bottom = inset.top * factor, inset.bottom * factor
        changed = true
    end
    if changed then RSUI.metrics.safeZoneClamps = (tonumber(RSUI.metrics.safeZoneClamps) or 0) + 1 end
    return inset
end

------------------------------------------------------------------------
-- ResolutionRoot
------------------------------------------------------------------------
local ResolutionRoots = setmetatable({}, { __mode = "k" })
RSUI.ResolutionRoots = ResolutionRoots

RSUI:RegisterType("ResolutionRoot", function(spec)
    local width, height, scale = GetUiMetrics()
    spec.width, spec.height = tonumber(spec.width) or width, tonumber(spec.height) or height
    spec.x, spec.y = tonumber(spec.x) or 0, tonumber(spec.y) or 0
    local c, err = Host("ResolutionRoot", spec)
    if c == nil then return nil, err end
    c.content = nil
    c.logicalWidth, c.logicalHeight, c.uiScale = width, height, scale
    c.designWidth = math.max(1, tonumber(spec.designWidth) or 1024)
    c.designHeight = math.max(1, tonumber(spec.designHeight) or 768)
    c.breakpoint = "normal"
    local baseAdd = c.AddChild
    function c:AddChild(child, slot)
        local result, ok, attachErr = baseAdd(self, child, slot)
        if result ~= nil and self.content == nil then self.content = result end
        return result, ok, attachErr
    end

    function c:GetViewportMetrics()
        return self.logicalWidth, self.logicalHeight, self.uiScale
    end

    function c:GetBreakpoint()
        return self.breakpoint
    end

    function c:ResolveBreakpoint(width)
        width = tonumber(width) or self.logicalWidth or self.designWidth
        local compact = tonumber(self.spec.compactWidth) or 1100
        local wide = tonumber(self.spec.wideWidth) or 1800
        if width < compact then return "compact" end
        if width >= wide then return "wide" end
        return "normal"
    end

    function c:RefreshViewport(relayout, force)
        local w, h, nextScale = GetUiMetrics()
        local changed = force == true or w ~= self.logicalWidth or h ~= self.logicalHeight or nextScale ~= self.uiScale
        self.logicalWidth, self.logicalHeight, self.uiScale = w, h, nextScale
        local nextBreakpoint = self:ResolveBreakpoint(w)
        if nextBreakpoint ~= self.breakpoint then self.breakpoint = nextBreakpoint; changed = true end
        if changed then
            self:InvalidateMeasure("viewport_changed")
            RSUI.metrics.viewportRefreshes = (tonumber(RSUI.metrics.viewportRefreshes) or 0) + 1
        end
        if relayout ~= false and (changed or force == true or self:IsLayoutDirty()) then self:LayoutIfNeeded(0, 0, w, h, force == true) end
        return changed, w, h, nextScale, self.breakpoint
    end

    function c:Measure(availableW, availableH)
        local w = tonumber(availableW) or self.logicalWidth or self.spec.width
        local h = tonumber(availableH) or self.logicalHeight or self.spec.height
        self.desiredWidth, self.desiredHeight, self.measureDirty = math.max(1, w), math.max(1, h), false
        return self.desiredWidth, self.desiredHeight
    end

    function c:Layout(x, y, w, h)
        w, h = math.max(1, tonumber(w) or self.logicalWidth or 1), math.max(1, tonumber(h) or self.logicalHeight or 1)
        self.logicalWidth, self.logicalHeight = w, h
        self.breakpoint = self:ResolveBreakpoint(w)
        self:SetBounds(tonumber(x) or 0, tonumber(y) or 0, w, h)
        if self.content ~= nil and self.content.visible ~= false then Arrange(self.content, 0, 0, w, h) end
        return h
    end

    ResolutionRoots[c] = true
    c:RefreshViewport(true, true)
    return c
end)

function RSUI:RefreshResolutionRoots(force)
    local changed, count = 0, 0
    for root in pairs(ResolutionRoots) do
        if type(root) == "table" and root.released ~= true and type(root.RefreshViewport) == "function" then
            count = count + 1
            if root:RefreshViewport(true, force == true) then changed = changed + 1 end
        end
    end
    return changed, count
end

------------------------------------------------------------------------
-- SafeZone
------------------------------------------------------------------------
RSUI:RegisterType("SafeZone", function(spec)
    local c, err = Host("SafeZone", spec)
    if c == nil then return nil, err end
    c.content = nil
    c.lastSafeRect = nil
    local baseAdd = c.AddChild
    function c:AddChild(child, slot)
        local result, ok, attachErr = baseAdd(self, child, slot)
        if result ~= nil and self.content == nil then self.content = result end
        return result, ok, attachErr
    end

    function c:GetSafeRect(width, height)
        width, height = math.max(1, tonumber(width) or self.width or 1), math.max(1, tonumber(height) or self.height or 1)
        local inset = ClampInsets(ResolveInset(self.spec, width, height), width, height)
        return {
            x = inset.left,
            y = inset.top,
            width = math.max(1, width - inset.left - inset.right),
            height = math.max(1, height - inset.top - inset.bottom),
            left = inset.left, top = inset.top, right = inset.right, bottom = inset.bottom,
        }
    end

    function c:Measure(availableW, availableH)
        local aw, ah = tonumber(availableW), tonumber(availableH)
        if aw == nil or ah == nil then
            local dw, dh = Measure(self.content, aw, ah)
            aw, ah = aw or dw, ah or dh
        end
        aw, ah = math.max(1, aw or 1), math.max(1, ah or 1)
        local rect = self:GetSafeRect(aw, ah)
        local dw, dh = Measure(self.content, rect.width, rect.height)
        local w = dw + rect.left + rect.right
        local h = dh + rect.top + rect.bottom
        if availableW ~= nil and self.spec.allowOverflow ~= true then w = math.min(w, aw) end
        if availableH ~= nil and self.spec.allowOverflow ~= true then h = math.min(h, ah) end
        self.desiredWidth, self.desiredHeight, self.measureDirty = math.max(1, w), math.max(1, h), false
        return self.desiredWidth, self.desiredHeight
    end

    function c:Layout(x, y, width, height)
        width, height = math.max(1, tonumber(width) or self.width or 1), math.max(1, tonumber(height) or self.height or 1)
        self:SetBounds(tonumber(x) or 0, tonumber(y) or 0, width, height)
        local rect = self:GetSafeRect(width, height)
        self.lastSafeRect = rect
        if self.content ~= nil and self.content.visible ~= false then Arrange(self.content, rect.x, rect.y, rect.width, rect.height) end
        return height
    end
    return c
end)

------------------------------------------------------------------------
-- AspectRatioBox
------------------------------------------------------------------------
RSUI:RegisterType("AspectRatioBox", function(spec)
    local c, err = Host("AspectRatioBox", spec)
    if c == nil then return nil, err end
    c.content = nil
    c.aspectRatio = math.max(0.01, tonumber(spec.aspectRatio or spec.ratio) or (16 / 9))
    c.mode = tostring(spec.mode or "fit"):lower()
    local baseAdd = c.AddChild
    function c:AddChild(child, slot)
        local result, ok, attachErr = baseAdd(self, child, slot)
        if result ~= nil and self.content == nil then self.content = result end
        return result, ok, attachErr
    end
    function c:SetAspectRatio(value)
        value = math.max(0.01, tonumber(value) or self.aspectRatio)
        if value == self.aspectRatio then return false end
        self.aspectRatio = value
        self:InvalidateMeasure("aspect_ratio")
        return true
    end
    function c:Measure(aw, ah)
        local dw, dh = Measure(self.content, aw, ah)
        if dw <= 0 and dh <= 0 then dw, dh = self.aspectRatio, 1 end
        local w, h
        if dw / math.max(0.01, dh) > self.aspectRatio then w, h = dw, dw / self.aspectRatio else h, w = dh, dh * self.aspectRatio end
        if aw ~= nil and self.spec.allowOverflow ~= true and w > aw then w, h = aw, aw / self.aspectRatio end
        if ah ~= nil and self.spec.allowOverflow ~= true and h > ah then h, w = ah, ah * self.aspectRatio end
        self.desiredWidth, self.desiredHeight, self.measureDirty = math.max(1, w), math.max(1, h), false
        return self.desiredWidth, self.desiredHeight
    end
    function c:Layout(x, y, width, height)
        width, height = math.max(1, tonumber(width) or self.width or 1), math.max(1, tonumber(height) or self.height or 1)
        self:SetBounds(tonumber(x) or 0, tonumber(y) or 0, width, height)
        if self.content == nil or self.content.visible == false then return height end
        local targetW, targetH
        local currentRatio = width / math.max(1, height)
        local fill = self.mode == "fill"
        if (currentRatio > self.aspectRatio) ~= fill then
            targetH, targetW = height, height * self.aspectRatio
        else
            targetW, targetH = width, width / self.aspectRatio
        end
        local hx = tostring(self.spec.hAlign or "center"):lower()
        local vy = tostring(self.spec.vAlign or "center"):lower()
        local cx = hx == "right" and (width - targetW) or (hx == "center" and (width - targetW) / 2 or 0)
        local cy = vy == "bottom" and (height - targetH) or (vy == "center" and (height - targetH) / 2 or 0)
        Arrange(self.content, cx, cy, math.max(1, targetW), math.max(1, targetH))
        self.lastOverflow = math.max(0, targetW - width, targetH - height)
        if self.lastOverflow > 0.01 then RSUI.metrics.layoutOverflowEvents = (tonumber(RSUI.metrics.layoutOverflowEvents) or 0) + 1 end
        return height
    end
    return c
end)

------------------------------------------------------------------------
-- CanvasPanel (restricted absolute layout)
------------------------------------------------------------------------
RSUI:RegisterType("CanvasPanel", function(spec)
    local c, err = Host("CanvasPanel", spec)
    if c == nil then return nil, err end
    c.clampChildren = spec.clampChildren ~= false
    c.purpose = tostring(spec.purpose or "hud")
    c.state.absoluteLayout = true

    function c:Measure(availableW, availableH)
        local maxX, maxY = 0, 0
        for _, entry in ipairs(self.slots or {}) do
            if entry.child.visible ~= false then
                local slot = entry.slot
                local dw, dh = Measure(entry.child, availableW, availableH)
                local x, y = tonumber(slot.x or slot.left) or 0, tonumber(slot.y or slot.top) or 0
                local w, h = tonumber(slot.width) or dw, tonumber(slot.height) or dh
                maxX, maxY = math.max(maxX, x + w), math.max(maxY, y + h)
            end
        end
        local w = tonumber(self.spec.desiredWidth) or tonumber(self.spec.width) or maxX
        local h = tonumber(self.spec.desiredHeight) or tonumber(self.spec.height) or maxY
        if availableW ~= nil and self.spec.allowOverflow ~= true then w = math.min(w, math.max(0, tonumber(availableW))) end
        if availableH ~= nil and self.spec.allowOverflow ~= true then h = math.min(h, math.max(0, tonumber(availableH))) end
        self.desiredWidth, self.desiredHeight, self.measureDirty = math.max(1, w), math.max(1, h), false
        return self.desiredWidth, self.desiredHeight
    end

    function c:Layout(x, y, width, height)
        width, height = math.max(1, tonumber(width) or self.width or 1), math.max(1, tonumber(height) or self.height or 1)
        self:SetBounds(tonumber(x) or 0, tonumber(y) or 0, width, height)
        local issues = 0
        for _, entry in ipairs(self.slots or {}) do
            local child, slot = entry.child, entry.slot
            if child.visible ~= false then
                local dw, dh = Measure(child, width, height)
                local px, py = tonumber(slot.x or slot.left) or 0, tonumber(slot.y or slot.top) or 0
                local pw, ph = tonumber(slot.width) or dw, tonumber(slot.height) or dh
                if self.clampChildren and self.spec.allowOverflow ~= true then
                    local originalX, originalY, originalW, originalH = px, py, pw, ph
                    pw, ph = math.min(math.max(1, pw), width), math.min(math.max(1, ph), height)
                    px, py = Clamp(px, 0, math.max(0, width - pw)), Clamp(py, 0, math.max(0, height - ph))
                    if px ~= originalX or py ~= originalY or pw ~= originalW or ph ~= originalH then issues = issues + 1 end
                elseif px < 0 or py < 0 or px + pw > width or py + ph > height then
                    issues = issues + 1
                end
                Arrange(child, px, py, math.max(1, pw), math.max(1, ph))
            end
        end
        if issues > 0 then RSUI.metrics.screenBoundaryIssues = (tonumber(RSUI.metrics.screenBoundaryIssues) or 0) + issues end
        self.state.lastBoundaryIssues = issues
        return height
    end
    return c
end)

------------------------------------------------------------------------
-- Screen-bound helpers (on demand only)
------------------------------------------------------------------------
function RSUI:GetAbsoluteRect(component)
    if not self:IsComponent(component) then return nil end
    local x, y = tonumber(component.x) or 0, tonumber(component.y) or 0
    local w, h = tonumber(component.width) or 0, tonumber(component.height) or 0
    local current, parent = component, component.parentComponent
    while parent ~= nil do
        if parent.kind == "ScaleBox" and parent.content == current and tonumber(parent.appliedScale) ~= nil then
            local scale = math.max(0.01, tonumber(parent.appliedScale) or 1)
            x, y, w, h = x * scale, y * scale, w * scale, h * scale
        end
        x, y = x + (tonumber(parent.x) or 0), y + (tonumber(parent.y) or 0)
        current, parent = parent, parent.parentComponent
    end
    return { x = x, y = y, width = w, height = h, right = x + w, bottom = y + h }
end

function RSUI:CheckScreenBounds(component, options)
    options = type(options) == "table" and options or {}
    local rect = self:GetAbsoluteRect(component)
    if rect == nil then return false, { "component_required" } end
    local vw, vh = tonumber(options.width), tonumber(options.height)
    if vw == nil or vh == nil then vw, vh = GetUiMetrics() end
    local margin = math.max(0, tonumber(options.margin) or 0)
    local issues = {}
    if rect.x < margin then issues[#issues + 1] = "left" end
    if rect.y < margin then issues[#issues + 1] = "top" end
    if rect.right > vw - margin then issues[#issues + 1] = "right" end
    if rect.bottom > vh - margin then issues[#issues + 1] = "bottom" end
    if #issues > 0 then self.metrics.screenBoundaryIssues = (tonumber(self.metrics.screenBoundaryIssues) or 0) + 1 end
    return #issues == 0, issues, rect, { width = vw, height = vh }
end

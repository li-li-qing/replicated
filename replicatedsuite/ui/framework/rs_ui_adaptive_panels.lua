-- Replicated Suite · 自适应组合布局
-- 作者：Replicated
-- QQ群：1104129461
-- 基于 rs_ui_panels.lua 的 UMG 风格组合布局，仅布局/事件驱动，各面板不持有 Tick 回调。
-- RU 限制：ScrollBox 使用安全条目吸附视口显隐，不假设未文档化通用裁切矩形；视口外子节点必须隐藏以免绘到邻近 UI。Native EnableScroll 仅用于滚轮事件支持。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local UI, RSUI = S.UI, S.RSUI
if type(UI) ~= "table" or type(RSUI) ~= "table" then return end
local Tokens = S.UITokens or {}
local U = RSUI.LayoutUtil
if type(U) ~= "table" then return end

local N, Clamp, Pad, Slot, Measure, Align, Arrange, Host = U.N, U.Clamp, U.Pad, U.Slot, U.Measure, U.Align, U.Arrange, U.Host
local function Token(path, fallback)
    if type(Tokens.Number) == "function" then return Tokens:Number(path, fallback) end
    return N(fallback, 0)
end

local function VisibleEntries(panel)
    local out = {}
    for _, entry in ipairs(panel.slots or {}) do
        if type(entry.child) == "table" and entry.child.visible ~= false then out[#out + 1] = entry end
    end
    return out
end

local function OuterSize(entry, availableW, availableH)
    local dw, dh = Measure(entry.child, availableW, availableH)
    local p = entry.slot.padding
    return dw + p.left + p.right, dh + p.top + p.bottom, dw, dh
end

local function SetViewport(child, visible)
    if type(child) ~= "table" then return end
    if type(child.SetViewportVisible) == "function" then child:SetViewportVisible(visible)
    elseif child.root ~= nil and type(UI.SetVisible) == "function" then UI:SetVisible(child.root, child.visible ~= false and visible == true, child.owner) end
end

local function RecordOverflow(panel, amount)
    amount = math.max(0, tonumber(amount) or 0)
    local previous = tonumber(panel.state and panel.state.lastAdaptiveOverflow) or 0
    panel.lastOverflow = amount
    if amount > 0 and math.abs(previous - amount) > 0.01 then
        RSUI.metrics.layoutOverflowEvents = (tonumber(RSUI.metrics.layoutOverflowEvents) or 0) + 1
    end
    panel.state.lastAdaptiveOverflow = amount
    return amount
end

-- UniformGrid 均匀网格。
RSUI:RegisterType("UniformGrid", function(spec)
    local c, err = Host("UniformGrid", spec)
    if c == nil then return nil, err end
    c.columnGap = math.max(0, N(spec.columnGap or spec.gapX, c.gap))
    c.rowGap = math.max(0, N(spec.rowGap or spec.gapY, c.gap))
    c.minCellWidth = math.max(1, N(spec.minCellWidth, 80))
    c.minCellHeight = math.max(1, N(spec.minCellHeight, 20))
    c.maxColumns = math.max(1, math.floor(N(spec.maxColumns, 12)))

    function c:ResolveColumns(innerWidth, count)
        count = math.max(1, tonumber(count) or 1)
        if tonumber(self.spec.columns) ~= nil then return math.max(1, math.min(count, math.floor(tonumber(self.spec.columns)))) end
        if tonumber(innerWidth) == nil then return math.max(1, math.min(count, math.floor(N(self.spec.preferredColumns, math.min(count, 4))))) end
        local cols = math.floor((math.max(0, innerWidth) + self.columnGap) / (self.minCellWidth + self.columnGap))
        return math.max(1, math.min(count, self.maxColumns, cols))
    end

    local function ResolvePlacement(entries, columns)
        local placements, cursor = {}, 0
        for _, entry in ipairs(entries) do
            local row = tonumber(entry.slot.row)
            local col = tonumber(entry.slot.column)
            if row == nil or col == nil then
                row = math.floor(cursor / columns) + 1
                col = (cursor % columns) + 1
                cursor = cursor + 1
            else
                row = math.max(1, math.floor(row))
                col = math.max(1, math.min(columns, math.floor(col)))
                cursor = math.max(cursor, (row - 1) * columns + col)
            end
            placements[#placements + 1] = { entry = entry, row = row, column = col }
        end
        return placements
    end

    function c:Measure(availableW, availableH)
        local p = Pad(self.spec.padding)
        local entries = VisibleEntries(self)
        if #entries == 0 then
            self.desiredWidth, self.desiredHeight, self.measureDirty = p.left + p.right, p.top + p.bottom, false
            return self.desiredWidth, self.desiredHeight
        end
        local innerAvailable = availableW and math.max(0, N(availableW, 0) - p.left - p.right) or nil
        local columns = self:ResolveColumns(innerAvailable, #entries)
        local measureCellWidth = innerAvailable and math.max(1, (innerAvailable - self.columnGap * math.max(0, columns - 1)) / columns) or nil
        local maxW, maxH = self.minCellWidth, self.minCellHeight
        for _, entry in ipairs(entries) do
            -- 按子节点实际分得的网格宽度测量，不能使用整个网格宽度；否则换行文字误报单行高度，并在压缩卡片外绘制。
            local ow, oh = OuterSize(entry, measureCellWidth, availableH)
            maxW, maxH = math.max(maxW, ow), math.max(maxH, oh)
        end
        local placements = ResolvePlacement(entries, columns)
        local rows = 1
        for _, item in ipairs(placements) do rows = math.max(rows, item.row) end
        local cellW = tonumber(self.spec.cellWidth) or maxW
        local cellH = tonumber(self.spec.cellHeight) or maxH
        local w = cellW * columns + self.columnGap * math.max(0, columns - 1) + p.left + p.right
        local h = cellH * rows + self.rowGap * math.max(0, rows - 1) + p.top + p.bottom
        if availableW ~= nil and self.spec.allowOverflow ~= true then w = math.min(w, math.max(0, N(availableW, w))) end
        if availableH ~= nil and self.spec.allowOverflow ~= true then h = math.min(h, math.max(0, N(availableH, h))) end
        self.desiredWidth, self.desiredHeight, self.measureDirty = w, h, false
        return w, h
    end

    function c:Layout(x, y, width, height)
        width, height = math.max(1, N(width, self.width or 1)), math.max(1, N(height, self.height or 1))
        self:SetBounds(x, y, width, height)
        local p = Pad(self.spec.padding)
        local iw, ih = math.max(0, width - p.left - p.right), math.max(0, height - p.top - p.bottom)
        local entries = VisibleEntries(self)
        if #entries == 0 then return height end
        local columns = self:ResolveColumns(iw, #entries)
        local placements = ResolvePlacement(entries, columns)
        local rows = 1
        for _, item in ipairs(placements) do rows = math.max(rows, item.row) end
        local cellW = math.max(1, (iw - self.columnGap * math.max(0, columns - 1)) / columns)
        local desiredCellH = self.minCellHeight
        for _, entry in ipairs(entries) do
            local _, oh = OuterSize(entry, cellW, nil)
            desiredCellH = math.max(desiredCellH, oh)
        end
        desiredCellH = tonumber(self.spec.cellHeight) or desiredCellH
        local availableCellH = rows > 0 and math.max(1, (ih - self.rowGap * math.max(0, rows - 1)) / rows) or desiredCellH
        local cellH = self.spec.allowOverflow == true and desiredCellH or math.min(desiredCellH, availableCellH)
        RecordOverflow(self, desiredCellH * rows + self.rowGap * math.max(0, rows - 1) - ih)
        for _, item in ipairs(placements) do
            local entry, slot = item.entry, item.entry.slot
            local sx = p.left + (item.column - 1) * (cellW + self.columnGap)
            local sy = p.top + (item.row - 1) * (cellH + self.rowGap)
            local pad = slot.padding
            local aw = math.max(0, cellW - pad.left - pad.right)
            local ah = math.max(0, cellH - pad.top - pad.bottom)
            local dw, dh = Measure(entry.child, aw, ah)
            local cx, cw = Align(sx + pad.left, aw, dw, slot.hAlign)
            local cy, ch = Align(sy + pad.top, ah, dh, slot.vAlign)
            SetViewport(entry.child, true)
            Arrange(entry.child, cx, cy, math.max(1, cw), math.max(1, ch))
        end
        return height
    end
    return c
end)

-- WrapBox 自动换行布局。
RSUI:RegisterType("WrapBox", function(spec)
    local c, err = Host("WrapBox", spec)
    if c == nil then return nil, err end
    c.orientation = tostring(spec.orientation or "horizontal"):lower()
    c.lineGap = math.max(0, N(spec.lineGap or spec.rowGap, c.gap))
    c.itemGap = math.max(0, N(spec.itemGap or spec.columnGap, c.gap))
    c.hideOverflow = spec.hideOverflow ~= false

    local function BuildLines(self, innerW, innerH)
        local horizontal = self.orientation ~= "vertical"
        local primaryLimit = horizontal and innerW or innerH
        if tonumber(primaryLimit) == nil or primaryLimit <= 0 then primaryLimit = math.huge end
        local lines, line = {}, { items = {}, primary = 0, cross = 0 }
        local function flush()
            if #line.items > 0 then lines[#lines + 1] = line; line = { items = {}, primary = 0, cross = 0 } end
        end
        for _, entry in ipairs(VisibleEntries(self)) do
            local ow, oh, dw, dh = OuterSize(entry, innerW, innerH)
            local primary, cross = horizontal and ow or oh, horizontal and oh or ow
            local force = entry.slot.newLine == true or entry.slot.wrapBefore == true
            local addedGap = #line.items > 0 and self.itemGap or 0
            if #line.items > 0 and (force or line.primary + addedGap + primary > primaryLimit + 0.01) then
                flush()
                RSUI.metrics.wrapEvents = (tonumber(RSUI.metrics.wrapEvents) or 0) + 1
                addedGap = 0
            end
            line.items[#line.items + 1] = { entry = entry, dw = dw, dh = dh, primary = primary, cross = cross }
            line.primary = line.primary + addedGap + primary
            line.cross = math.max(line.cross, cross)
        end
        flush()
        return lines, horizontal
    end

    function c:Measure(availableW, availableH)
        local p = Pad(self.spec.padding)
        local iw = availableW and math.max(0, N(availableW, 0) - p.left - p.right) or nil
        local ih = availableH and math.max(0, N(availableH, 0) - p.top - p.bottom) or nil
        local lines, horizontal = BuildLines(self, iw, ih)
        local primary, cross = 0, 0
        for i, line in ipairs(lines) do
            primary = math.max(primary, line.primary)
            cross = cross + line.cross + (i > 1 and self.lineGap or 0)
        end
        local w, h = horizontal and primary or cross, horizontal and cross or primary
        w, h = w + p.left + p.right, h + p.top + p.bottom
        if availableW ~= nil and self.spec.allowOverflow ~= true then w = math.min(w, math.max(0, N(availableW, w))) end
        if availableH ~= nil and self.spec.allowOverflow ~= true then h = math.min(h, math.max(0, N(availableH, h))) end
        self.desiredWidth, self.desiredHeight, self.measureDirty = w, h, false
        return w, h
    end

    function c:Layout(x, y, width, height)
        width, height = math.max(1, N(width, self.width or 1)), math.max(1, N(height, self.height or 1))
        self:SetBounds(x, y, width, height)
        local p = Pad(self.spec.padding)
        local iw, ih = math.max(0, width - p.left - p.right), math.max(0, height - p.top - p.bottom)
        local lines, horizontal = BuildLines(self, iw, ih)
        local crossCursor = horizontal and p.top or p.left
        local crossLimit = horizontal and (p.top + ih) or (p.left + iw)
        self.lastOverflow = 0
        for _, line in ipairs(lines) do
            local primaryCursor = horizontal and p.left or p.top
            for _, item in ipairs(line.items) do
                local entry, slot, pad = item.entry, item.entry.slot, item.entry.slot.padding
                local outerPrimary = item.primary
                local outerCross = line.cross
                local contentPrimary = math.max(0, outerPrimary - (horizontal and (pad.left + pad.right) or (pad.top + pad.bottom)))
                local contentCross = math.max(0, outerCross - (horizontal and (pad.top + pad.bottom) or (pad.left + pad.right)))
                local px, py, pw, ph
                if horizontal then
                    local cy, ch = Align(crossCursor + pad.top, contentCross, item.dh, slot.vAlign)
                    local cx, cw = Align(primaryCursor + pad.left, contentPrimary, item.dw, slot.hAlign)
                    px, py, pw, ph = cx, cy, cw, ch
                else
                    local cx, cw = Align(crossCursor + pad.left, contentCross, item.dw, slot.hAlign)
                    local cy, ch = Align(primaryCursor + pad.top, contentPrimary, item.dh, slot.vAlign)
                    px, py, pw, ph = cx, cy, cw, ch
                end
                local fullyInside = crossCursor + outerCross <= crossLimit + 0.01
                SetViewport(entry.child, fullyInside or self.hideOverflow ~= true)
                if fullyInside or self.hideOverflow ~= true then Arrange(entry.child, px, py, math.max(1, pw), math.max(1, ph)) end
                primaryCursor = primaryCursor + outerPrimary + self.itemGap
            end
            crossCursor = crossCursor + line.cross + self.lineGap
        end
        local usedCross = crossCursor - self.lineGap
        RecordOverflow(self, usedCross - crossLimit)
        return height
    end
    return c
end)

-- WidgetSwitcher 页面切换容器。
RSUI.WidgetSwitcherContractVersion = 2
RSUI:RegisterType("WidgetSwitcher", function(spec)
    local c, err = Host("WidgetSwitcher", spec)
    if c == nil then return nil, err end
    c.activeIndex = math.max(1, math.floor(N(spec.activeIndex, 1)))
    c.measureMode = tostring(spec.measureMode or "active"):lower()

    function c:ApplyActiveVisibility()
        for index, entry in ipairs(self.slots) do SetViewport(entry.child, index == self.activeIndex) end
    end

    function c:SetActiveIndex(index)
        local count = #self.slots
        if count <= 0 then self.activeIndex = 1; return false end
        local value = math.max(1, math.min(count, math.floor(N(index, self.activeIndex))))
        if value == self.activeIndex then return false end
        self.activeIndex = value
        self:ApplyActiveVisibility()
        self:InvalidateMeasure("switch_active")
        RSUI.metrics.switchChanges = (tonumber(RSUI.metrics.switchChanges) or 0) + 1
        if self.width and self.height then self:Layout(self.x or 0, self.y or 0, self.width, self.height) end
        return true
    end

    function c:SetActiveWidget(widgetOrId)
        for index, entry in ipairs(self.slots) do
            if entry.child == widgetOrId or tostring(entry.child.id or "") == tostring(widgetOrId or "") then
                -- SetActiveIndex 无变化返回 false 供变化检测；SetActiveWidget 同时是导航接受 API，已活跃目标有效，不能报告页面拒绝。
                if index == self.activeIndex then return true, false end
                local changed = self:SetActiveIndex(index)
                return changed ~= false, changed == true
            end
        end
        return false, false
    end

    local baseAdd = c.AddChild
    function c:AddChild(child, slot)
        local result, ok, attachErr = baseAdd(self, child, slot)
        if result ~= nil then
            self.activeIndex = math.max(1, math.min(#self.slots, self.activeIndex))
            self:ApplyActiveVisibility()
        end
        return result, ok, attachErr
    end

    function c:Measure(availableW, availableH)
        local p = Pad(self.spec.padding)
        local w, h = 0, 0
        if self.measureMode == "largest" then
            for _, entry in ipairs(self.slots) do
                if entry.child.visible ~= false then
                    local ow, oh = OuterSize(entry, availableW, availableH)
                    w, h = math.max(w, ow), math.max(h, oh)
                end
            end
        else
            local entry = self.slots[self.activeIndex]
            if entry and entry.child.visible ~= false then w, h = OuterSize(entry, availableW, availableH) end
        end
        w, h = w + p.left + p.right, h + p.top + p.bottom
        if availableW ~= nil and self.spec.allowOverflow ~= true then w = math.min(w, math.max(0, N(availableW, w))) end
        if availableH ~= nil and self.spec.allowOverflow ~= true then h = math.min(h, math.max(0, N(availableH, h))) end
        self.desiredWidth, self.desiredHeight, self.measureDirty = w, h, false
        return w, h
    end

    function c:Layout(x, y, width, height)
        width, height = math.max(1, N(width, self.width or 1)), math.max(1, N(height, self.height or 1))
        self:SetBounds(x, y, width, height)
        local p = Pad(self.spec.padding)
        local iw, ih = math.max(0, width - p.left - p.right), math.max(0, height - p.top - p.bottom)
        self:ApplyActiveVisibility()
        local entry = self.slots[self.activeIndex]
        if entry and entry.child.visible ~= false then
            local slot, pad = entry.slot, entry.slot.padding
            local aw, ah = math.max(0, iw - pad.left - pad.right), math.max(0, ih - pad.top - pad.bottom)
            local dw, dh = Measure(entry.child, aw, ah)
            local cx, cw = Align(p.left + pad.left, aw, dw, slot.hAlign)
            local cy, ch = Align(p.top + pad.top, ah, dh, slot.vAlign)
            Arrange(entry.child, cx, cy, math.max(1, cw), math.max(1, ch))
        end
        return height
    end
    c:ApplyActiveVisibility()
    return c
end)

-- ResponsiveInspector 响应式检查面板。
-- 稳定宿主响应式组合：内容与检查面板仅创建一次且共享原生 RSUI 宿主，宽度变化仅改几何/视口显隐；不运行时换父，RU 未验证该能力且会割裂逻辑/原生所有权。
RSUI.ResponsiveInspectorContractVersion = 1
RSUI:RegisterType("ResponsiveInspector", function(spec)
    local c, err = Host("ResponsiveInspector", spec)
    if c == nil then return nil, err end
    c.content = nil
    c.inspector = nil
    c.mode = "inline"
    c.drawerOpen = spec.drawerOpen == true
    c.breakpoint = math.max(320, N(spec.breakpoint, Token("breakpoint.regular", 980)))
    c.inspectorWidth = math.max(120, N(spec.inspectorWidth, Token("workspace.inspectorW", 286)))
    c.inspectorMinWidth = math.max(96, N(spec.inspectorMinWidth, Token("workspace.inspectorMinW", 220)))
    c.contentMinWidth = math.max(120, N(spec.contentMinWidth, Token("workspace.previewMinW", 360)))
    c.gap = math.max(0, N(spec.gap, Token("workspace.divider", 6)))
    c.drawerMaxFraction = math.max(0.50, math.min(1.0, N(spec.drawerMaxFraction, 0.92)))
    c.drawerMinReveal = math.max(0, N(spec.drawerMinReveal, 64))

    local baseAdd = c.AddChild
    local function ResolveRole(self, child, slot)
        local role = type(slot) == "table" and tostring(slot.role or ""):lower() or ""
        if role == "main" or role == "canvas" or role == "body" then role = "content" end
        if role == "detail" or role == "properties" then role = "inspector" end
        if role == "" then
            if self.content == nil then role = "content"
            elseif self.inspector == nil then role = "inspector"
            else return nil, "responsive_inspector_two_children_only" end
        end
        if role ~= "content" and role ~= "inspector" then return nil, "responsive_inspector_role_invalid:" .. tostring(role) end
        local existing = role == "content" and self.content or self.inspector
        if existing ~= nil and existing ~= child then return nil, "responsive_inspector_role_occupied:" .. role end
        return role
    end

    function c:AddChild(child, slot)
        local role, roleErr = ResolveRole(self, child, slot)
        if role == nil then return nil, false, roleErr end
        local attached, ok, attachErr = baseAdd(self, child, slot)
        if attached == nil then return nil, false, attachErr end
        if role == "content" then self.content = attached else self.inspector = attached end
        attached.responsiveInspectorRole = role
        return attached, ok, attachErr
    end

    function c:ResolveMode(width)
        width = math.max(1, N(width, self.width or 1))
        local required = self.contentMinWidth + self.gap + self.inspectorMinWidth
        if width <= self.breakpoint or width < required then return "drawer" end
        return "inline"
    end

    function c:GetMode() return self.mode end
    function c:IsDrawerOpen() return self.drawerOpen == true end

    function c:SetDrawerOpen(open, notify)
        local nextValue = open == true
        if nextValue == self.drawerOpen then return false end
        self.drawerOpen = nextValue
        RSUI.metrics.responsiveInspectorDrawerChanges = (tonumber(RSUI.metrics.responsiveInspectorDrawerChanges) or 0) + 1
        self:InvalidateLayout("responsive_inspector_drawer")
        if self.width and self.height then self:Layout(self.x or 0, self.y or 0, self.width, self.height) end
        if notify ~= false and type(spec.onDrawerChanged) == "function" then
            RSUI:Callback("rsui:" .. self.id .. ":drawer", spec.onDrawerChanged, nextValue, self)
        end
        return true
    end

    function c:ToggleDrawer(notify) return self:SetDrawerOpen(not self.drawerOpen, notify) end

    function c:SetInspectorWidth(width, notify)
        local nextWidth = math.max(self.inspectorMinWidth, N(width, self.inspectorWidth))
        if nextWidth == self.inspectorWidth then return false end
        self.inspectorWidth = nextWidth
        self:InvalidateMeasure("responsive_inspector_width")
        if self.width and self.height then self:Layout(self.x or 0, self.y or 0, self.width, self.height) end
        if notify ~= false and type(spec.onInspectorWidthChanged) == "function" then
            RSUI:Callback("rsui:" .. self.id .. ":width", spec.onInspectorWidthChanged, nextWidth, self)
        end
        return true
    end

    function c:Measure(availableW, availableH)
        local p = Pad(self.spec.padding)
        local innerW = availableW and math.max(0, N(availableW, 0) - p.left - p.right) or nil
        local innerH = availableH and math.max(0, N(availableH, 0) - p.top - p.bottom) or nil
        local contentW, contentH = Measure(self.content, innerW, innerH)
        local inspectorW, inspectorH = Measure(self.inspector, innerW, innerH)
        local mode = self:ResolveMode(innerW or (contentW + self.gap + inspectorW))
        local width, height
        if mode == "inline" then
            width = contentW + (self.inspector ~= nil and self.content ~= nil and self.gap or 0) + inspectorW
            height = math.max(contentH, inspectorH)
        else
            width = math.max(contentW, math.min(self.inspectorWidth, inspectorW))
            height = math.max(contentH, inspectorH)
        end
        width, height = width + p.left + p.right, height + p.top + p.bottom
        if availableW ~= nil and self.spec.allowOverflow ~= true then width = math.min(width, math.max(0, N(availableW, width))) end
        if availableH ~= nil and self.spec.allowOverflow ~= true then height = math.min(height, math.max(0, N(availableH, height))) end
        self.desiredWidth, self.desiredHeight, self.measureDirty = width, height, false
        return width, height
    end

    function c:Layout(x, y, width, height)
        width, height = math.max(1, N(width, self.width or 1)), math.max(1, N(height, self.height or 1))
        self:SetBounds(x, y, width, height)
        local p = Pad(self.spec.padding)
        local innerW, innerH = math.max(1, width - p.left - p.right), math.max(1, height - p.top - p.bottom)
        local nextMode = self:ResolveMode(innerW)
        if nextMode ~= self.mode then
            self.mode = nextMode
            RSUI.metrics.responsiveInspectorModeChanges = (tonumber(RSUI.metrics.responsiveInspectorModeChanges) or 0) + 1
            if type(spec.onModeChanged) == "function" then RSUI:Callback("rsui:" .. self.id .. ":mode", spec.onModeChanged, nextMode, self) end
        end

        if self.content ~= nil then SetViewport(self.content, true) end
        if nextMode == "inline" then
            if self.inspector ~= nil then SetViewport(self.inspector, true) end
            local inspectorW = self.inspector ~= nil and math.max(self.inspectorMinWidth, math.min(self.inspectorWidth, math.max(self.inspectorMinWidth, innerW - self.contentMinWidth - self.gap))) or 0
            local contentW = self.inspector ~= nil and math.max(1, innerW - inspectorW - self.gap) or innerW
            if self.content ~= nil then Arrange(self.content, p.left, p.top, contentW, innerH) end
            if self.inspector ~= nil then Arrange(self.inspector, p.left + contentW + self.gap, p.top, inspectorW, innerH) end
        else
            if self.content ~= nil then Arrange(self.content, p.left, p.top, innerW, innerH) end
            local showInspector = self.inspector ~= nil and self.drawerOpen == true
            if self.inspector ~= nil then
                SetViewport(self.inspector, showInspector)
                if showInspector then
                    local maxDrawer = math.max(1, innerW * self.drawerMaxFraction)
                    local byReveal = self.drawerMinReveal > 0 and math.max(1, innerW - self.drawerMinReveal) or maxDrawer
                    local drawerW = math.max(1, math.min(self.inspectorWidth, maxDrawer, byReveal))
                    drawerW = math.min(innerW, math.max(math.min(self.inspectorMinWidth, innerW), drawerW))
                    Arrange(self.inspector, p.left + innerW - drawerW, p.top, drawerW, innerH, true)
                    if self.inspector.root ~= nil and type(self.inspector.root.Raise) == "function" then pcall(function() self.inspector.root:Raise() end) end
                end
            end
        end
        self.layoutDirty = false
        return height
    end

    function c:GetResponsiveSnapshot()
        return {
            contractVersion = RSUI.ResponsiveInspectorContractVersion,
            mode = self.mode,
            drawerOpen = self.drawerOpen == true,
            breakpoint = self.breakpoint,
            inspectorWidth = self.inspectorWidth,
            nativeReparent = RSUI.NativeReparentSupported == true,
            stableHost = true,
        }
    end
    return c
end)

-- ScaleBox 缩放布局。
RSUI:RegisterType("ScaleBox", function(spec)
    local c, err = Host("ScaleBox", spec)
    if c == nil then return nil, err end
    c.content = nil
    c.stretch = tostring(spec.stretch or "scaleToFit"):lower()
    c.scaleDirection = tostring(spec.scaleDirection or "both"):lower()
    c.userScale = math.max(0.01, N(spec.userScale, 1))
    local baseAdd = c.AddChild
    function c:AddChild(child, slot)
        local result, ok, attachErr = baseAdd(self, child, slot)
        if result ~= nil then
            if self.content == nil then self.content = result else SetViewport(result, false) end
        end
        return result, ok, attachErr
    end

    local function RestrictScale(self, scale)
        scale = math.max(0.01, scale * self.userScale)
        if self.scaleDirection == "downonly" or self.scaleDirection == "down_only" then scale = math.min(1, scale)
        elseif self.scaleDirection == "uponly" or self.scaleDirection == "up_only" then scale = math.max(1, scale) end
        return scale
    end

    function c:SetUserScale(value)
        local scale = math.max(0.01, N(value, self.userScale))
        if scale == self.userScale then return false end
        self.userScale = scale
        self:InvalidateLayout("user_scale")
        if self.width and self.height then self:Layout(self.x or 0, self.y or 0, self.width, self.height) end
        return true
    end

    function c:Measure(availableW, availableH)
        local p = Pad(self.spec.padding)
        local dw, dh = Measure(self.content, nil, nil)
        local w, h = dw + p.left + p.right, dh + p.top + p.bottom
        if availableW ~= nil and self.spec.allowOverflow ~= true then w = math.min(w, math.max(0, N(availableW, w))) end
        if availableH ~= nil and self.spec.allowOverflow ~= true then h = math.min(h, math.max(0, N(availableH, h))) end
        self.desiredWidth, self.desiredHeight, self.measureDirty = w, h, false
        return w, h
    end

    function c:Layout(x, y, width, height)
        width, height = math.max(1, N(width, self.width or 1)), math.max(1, N(height, self.height or 1))
        self:SetBounds(x, y, width, height)
        if self.content == nil or self.content.visible == false then return height end
        local p = Pad(self.spec.padding)
        local iw, ih = math.max(1, width - p.left - p.right), math.max(1, height - p.top - p.bottom)
        local dw, dh = Measure(self.content, nil, nil)
        dw, dh = math.max(1, dw), math.max(1, dh)
        local sx, sy = iw / dw, ih / dh
        local scale
        if self.stretch == "fill" then
            -- Native SetScale 等比缩放，因此 fill 选较大比例而可能裁切；需避免裁切时用 ScaleToFit。
            scale = math.max(sx, sy)
        elseif self.stretch == "scaletofitx" or self.stretch == "fitx" then scale = sx
        elseif self.stretch == "scaletofity" or self.stretch == "fity" then scale = sy
        elseif self.stretch == "none" then scale = 1
        else scale = math.min(sx, sy) end
        scale = RestrictScale(self, scale)
        local effectiveW, effectiveH = dw * scale, dh * scale
        local ha = tostring(self.spec.hAlign or "center"):lower()
        local va = tostring(self.spec.vAlign or "center"):lower()
        local cx = p.left + (ha == "right" and math.max(0, iw - effectiveW) or (ha == "center" and math.max(0, (iw - effectiveW) / 2) or 0))
        local cy = p.top + (va == "bottom" and math.max(0, ih - effectiveH) or (va == "center" and math.max(0, (ih - effectiveH) / 2) or 0))
        SetViewport(self.content, true)
        Arrange(self.content, cx, cy, dw, dh)
        local hasNativeScale = self.content.root ~= nil and type(self.content.root.SetScale) == "function"
        if hasNativeScale and type(UI.SetScale) == "function" then UI:SetScale(self.content.root, scale, self.content.owner) end
        if not hasNativeScale then
            -- 控件缺少 Native SetScale 时安全回退，让子节点留在可用矩形内，避免重叠。
            Arrange(self.content, p.left, p.top, iw, ih)
            scale, effectiveW, effectiveH = 1, iw, ih
        end
        self.appliedScale = scale
        self.effectiveWidth, self.effectiveHeight = effectiveW, effectiveH
        RecordOverflow(self, math.max(effectiveW - iw, effectiveH - ih))
        return height
    end
    return c
end)

-- SplitView 主从分栏与事件驱动分隔条。
-- 运行布局和序列测试共享纯策略，无 Native 副作用，小窗口行为确定且可独立验证；仅遵循显式 max，不补造上限。
RSUI.SplitViewPolicy = RSUI.SplitViewPolicy or { version = 1 }
function RSUI.SplitViewPolicy:Resolve(primaryAvail, dividerSize, minPrimary, minSecondary, requested, maxPrimary, maxSecondary)
    primaryAvail = math.max(0, tonumber(primaryAvail) or 0)
    local divider = math.min(math.max(0, tonumber(dividerSize) or 0), primaryAvail)
    local paneSpace = math.max(0, primaryAvail - divider)
    local minA = math.max(0, tonumber(minPrimary) or 0)
    local minB = math.max(0, tonumber(minSecondary) or 0)
    local value = tonumber(requested) or minA
    if paneSpace < minA + minB and minA + minB > 0 then
        value = paneSpace * (minA / (minA + minB))
    else
        value = math.max(minA, math.min(value, paneSpace - minB))
    end
    if maxPrimary ~= nil then value = math.min(value, math.max(0, tonumber(maxPrimary) or value)) end
    if maxSecondary ~= nil then value = math.max(value, paneSpace - math.max(0, tonumber(maxSecondary) or paneSpace)) end
    value = Clamp(value, 0, paneSpace)
    return value, math.max(0, paneSpace - value), divider
end

RSUI:RegisterType("SplitView", function(spec)
    local c, err = Host("SplitView", spec)
    if c == nil then return nil, err end
    c.orientation = tostring(spec.orientation or "horizontal"):lower()
    if c.orientation ~= "vertical" then c.orientation = "horizontal" end
    c.mode = tostring(spec.mode or spec.sizeMode or "ratio"):lower()
    if c.mode ~= "fixed" then c.mode = "ratio" end
    c.ratio = Clamp(N(spec.ratio or spec.splitRatio, 0.35), 0, 1)
    c.primarySize = tonumber(spec.primarySize or spec.fixedSize)
    -- 框架不强加面板最小值；需要语义空间的 Feature 显式声明，否则用户可完全折叠任一侧。
    c.minPrimary = math.max(0, N(spec.minPrimary, 0))
    c.minSecondary = math.max(0, N(spec.minSecondary, 0))
    c.maxPrimary = tonumber(spec.maxPrimary)
    c.maxSecondary = tonumber(spec.maxSecondary)
    if c.maxPrimary ~= nil then c.maxPrimary = math.max(c.minPrimary, c.maxPrimary) end
    if c.maxSecondary ~= nil then c.maxSecondary = math.max(c.minSecondary, c.maxSecondary) end
    c.dividerSize = math.max(2, N(spec.dividerSize, 6))
    c.onSplitChanged = spec.onSplitChanged
    c.dragging = false
    c.dragTaskName = "rsui_split_drag:" .. tostring(c.id)

    local dividerVisual = UI:CreateEmptyWidget(c.root, c.id .. "_divider_visual", 0, 0, c.dividerSize, 20, false)
    local dividerDrag = UI:CreateEmptyWidget(c.root, c.id .. "_divider_drag", 0, 0, math.max(10, c.dividerSize + 6), 20, true)
    c.dividerVisual, c.dividerDrag = dividerVisual, dividerDrag
    if dividerVisual ~= nil and type(dividerVisual.CreateColorDrawable) == "function" then
        local color = (S.VisualTokens and S.VisualTokens:Color("separator")) or {0.08,0.28,0.31,0.72}
        local d = dividerVisual:CreateColorDrawable(color[1],color[2],color[3],color[4] or 0.72,"overlay")
        if d and d.AddAnchor then d:AddAnchor("TOPLEFT",dividerVisual,0,0); d:AddAnchor("BOTTOMRIGHT",dividerVisual,0,0) end
        if S.Theme and S.Theme.BindColorDrawable then S.Theme:BindColorDrawable(dividerVisual,d,'decorations.split') end
    end
    if dividerDrag == nil then
        c.rsUiDegraded, c.rsUiDegradedReason = true, "split_divider_drag_create_failed"
    elseif type(UI.TryInteractionCall) ~= "function" or type(UI.RequireHandler) ~= "function" then
        c.rsUiDegraded, c.rsUiDegradedReason = true, "critical_interaction_contract_unavailable"
    else
        local dragEnabled, dragErr = UI:TryInteractionCall(dividerDrag, "EnableDrag", true)
        if dragEnabled ~= true then
            c.rsUiDegraded, c.rsUiDegradedReason = true, "split_enable_drag_failed:" .. tostring(dragErr or "rejected")
        elseif type(dividerDrag.SetDragCondition) == "function" and DC_ALWAYS ~= nil then
            local conditionOk, conditionErr = UI:TryInteractionCall(dividerDrag, "SetDragCondition", DC_ALWAYS)
            if conditionOk ~= true then
                c.rsUiDegraded, c.rsUiDegradedReason = true, "split_drag_condition_failed:" .. tostring(conditionErr or "rejected")
            end
        end
    end

    local function EffectiveAxis(widget, horizontal)
        if widget == nil then return nil end
        local x, y
        if type(widget.GetEffectiveOffset) == "function" then
            local ok, ax, ay = pcall(function() return widget:GetEffectiveOffset() end)
            if ok then x, y = tonumber(ax), tonumber(ay) end
        end
        if (x == nil and y == nil) and type(widget.GetOffset) == "function" then
            local ok, ax, ay = pcall(function() return widget:GetOffset() end)
            if ok then x, y = tonumber(ax), tonumber(ay) end
        end
        return horizontal and x or y
    end

    function c:GetPaneEntries()
        local entries = VisibleEntries(self)
        return entries[1], entries[2]
    end

    function c:ResolvePrimary(primaryAvail)
        primaryAvail = math.max(0, tonumber(primaryAvail) or 0)
        local divider = math.min(self.dividerSize, primaryAvail)
        local paneSpace = math.max(0, primaryAvail - divider)
        local requested = self.mode == "fixed" and (tonumber(self.primarySize) or self.minPrimary) or paneSpace * Clamp(self.ratio, 0, 1)
        return RSUI.SplitViewPolicy:Resolve(primaryAvail, self.dividerSize, self.minPrimary, self.minSecondary, requested, self.maxPrimary, self.maxSecondary)
    end

    function c:GetSplitRatio()
        local primaryAvail = self.orientation == "horizontal" and tonumber(self.width) or tonumber(self.height)
        if primaryAvail == nil then return Clamp(self.ratio, 0, 1) end
        local p = Pad(self.spec.padding)
        primaryAvail = self.orientation == "horizontal" and math.max(0, primaryAvail - p.left - p.right) or math.max(0, primaryAvail - p.top - p.bottom)
        local a, b = self:ResolvePrimary(primaryAvail)
        return (a + b) > 0 and a / (a + b) or 0.5
    end

    function c:SetSplitRatio(value, notify, relayout)
        local nextValue = Clamp(value, 0, 1)
        self.mode = "ratio"
        if math.abs(nextValue - (tonumber(self.ratio) or 0)) <= 0.0001 then return false end
        self.ratio = nextValue
        self:InvalidateLayout("split_ratio")
        if relayout ~= false and self.width and self.height then self:Layout(self.x or 0,self.y or 0,self.width,self.height) end
        if notify ~= false and type(self.onSplitChanged) == "function" then pcall(self.onSplitChanged, self, self.ratio, "ratio") end
        return true
    end

    function c:SetPrimarySize(value, notify, relayout)
        local nextValue = math.max(0, tonumber(value) or 0)
        self.mode = "fixed"
        if tonumber(self.primarySize) ~= nil and math.abs(nextValue - self.primarySize) <= 0.01 then return false end
        self.primarySize = nextValue
        self:InvalidateLayout("split_primary")
        if relayout ~= false and self.width and self.height then self:Layout(self.x or 0,self.y or 0,self.width,self.height) end
        if notify ~= false and type(self.onSplitChanged) == "function" then pcall(self.onSplitChanged, self, self.primarySize, "fixed") end
        return true
    end

    function c:Measure(availableW, availableH)
        local p = Pad(self.spec.padding)
        local first, second = self:GetPaneEntries()
        local aw, ah = availableW, availableH
        local fw, fh = 0, 0
        if first then fw, fh = Measure(first.child, aw, ah) end
        local sw, sh = 0, 0
        if second then sw, sh = Measure(second.child, aw, ah) end
        local w, h
        if self.orientation == "horizontal" then
            w = fw + sw + self.dividerSize + p.left + p.right
            h = math.max(fh, sh) + p.top + p.bottom
        else
            w = math.max(fw, sw) + p.left + p.right
            h = fh + sh + self.dividerSize + p.top + p.bottom
        end
        if availableW ~= nil and self.spec.allowOverflow ~= true then w = math.min(w, math.max(0,N(availableW,w))) end
        if availableH ~= nil and self.spec.allowOverflow ~= true then h = math.min(h, math.max(0,N(availableH,h))) end
        self.desiredWidth,self.desiredHeight,self.measureDirty=math.max(1,w),math.max(1,h),false
        return self.desiredWidth,self.desiredHeight
    end

    function c:Layout(x,y,width,height)
        width,height=math.max(1,N(width,self.width or 1)),math.max(1,N(height,self.height or 1))
        self:SetBounds(x,y,width,height)
        local p=Pad(self.spec.padding)
        local horizontal=self.orientation=="horizontal"
        local primaryAvail=horizontal and math.max(0,width-p.left-p.right) or math.max(0,height-p.top-p.bottom)
        local crossAvail=horizontal and math.max(0,height-p.top-p.bottom) or math.max(0,width-p.left-p.right)
        local primary,secondary,divider=self:ResolvePrimary(primaryAvail)
        local first,second=self:GetPaneEntries()
        -- 与 ScrollBox 相同，排版直接提交最终显隐，避免短暂隐藏可见面板中正在按下的按钮。
        for _,entry in ipairs(self.slots or {}) do
            SetViewport(entry.child,(entry==first and primary>0) or (entry==second and secondary>0))
        end
        if first ~= nil and primary > 0 then
            if horizontal then Arrange(first.child,p.left,p.top,math.max(1,primary),math.max(1,crossAvail))
            else Arrange(first.child,p.left,p.top,math.max(1,crossAvail),math.max(1,primary)) end
        end
        if second ~= nil and secondary > 0 then
            if horizontal then Arrange(second.child,p.left+primary+divider,p.top,math.max(1,secondary),math.max(1,crossAvail))
            else Arrange(second.child,p.left,p.top+primary+divider,math.max(1,crossAvail),math.max(1,secondary)) end
        end
        if self.dividerVisual ~= nil then
            if horizontal then
                UI:SetAnchor(self.dividerVisual,self.root,p.left+primary,p.top,self.owner); UI:SetExtent(self.dividerVisual,math.max(1,divider),math.max(1,crossAvail),self.owner)
            else
                UI:SetAnchor(self.dividerVisual,self.root,p.left,p.top+primary,self.owner); UI:SetExtent(self.dividerVisual,math.max(1,crossAvail),math.max(1,divider),self.owner)
            end
            UI:SetVisible(self.dividerVisual,first~=nil and second~=nil and divider>0,self.owner)
        end
        if self.dividerDrag ~= nil and self.dragging ~= true then
            local hit=math.max(10,divider+6)
            if horizontal then
                UI:SetAnchor(self.dividerDrag,self.root,p.left+primary-(hit-divider)/2,p.top,self.owner); UI:SetExtent(self.dividerDrag,hit,math.max(1,crossAvail),self.owner)
            else
                UI:SetAnchor(self.dividerDrag,self.root,p.left,p.top+primary-(hit-divider)/2,self.owner); UI:SetExtent(self.dividerDrag,math.max(1,crossAvail),hit,self.owner)
            end
            UI:SetVisible(self.dividerDrag,first~=nil and second~=nil and divider>0,self.owner)
        end
        self.measureDirty,self.layoutDirty=false,false
        return height
    end

    local function StopDragTask()
        if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask)=="function" then S.Scheduler:RemoveTask(c.dragTaskName) end
        if c.dragUpdateFallback == true and c.dividerDrag ~= nil and type(c.dividerDrag.ReleaseHandler) == "function" then
            pcall(function() c.dividerDrag:ReleaseHandler("OnUpdate") end)
        end
        c.dragUpdateFallback = false
    end
    local function SyncDrag(final)
        if c.dragging ~= true and final ~= true then return false end
        local current=EffectiveAxis(c.dividerDrag,c.orientation=="horizontal")
        if current==nil or c.dragStartAxis==nil then return false end
        local requested=(tonumber(c.dragStartPrimary) or 0)+(current-c.dragStartAxis)
        local p=Pad(c.spec.padding)
        local total=c.orientation=="horizontal" and math.max(0,(tonumber(c.width) or 0)-p.left-p.right) or math.max(0,(tonumber(c.height) or 0)-p.top-p.bottom)
        local paneSpace=math.max(0,total-c.dividerSize)
        if c.mode=="fixed" then c.primarySize=Clamp(requested,0,paneSpace)
        else c.ratio=paneSpace>0 and Clamp(requested/paneSpace,0,1) or 0.5 end
        c:InvalidateLayout("split_drag")
        if c.width and c.height then c:Layout(c.x or 0,c.y or 0,c.width,c.height) end
        if type(c.onSplitChanged)=="function" then pcall(c.onSplitChanged,c,c.mode=="fixed" and c.primarySize or c.ratio,c.mode,final==true) end
        return true
    end

    if dividerDrag ~= nil then
        local startBound, startErr = UI:RequireHandler(dividerDrag,"OnDragStart",function()
            local axis=EffectiveAxis(dividerDrag,c.orientation=="horizontal")
            if axis==nil then return false end
            local p=Pad(c.spec.padding)
            local total=c.orientation=="horizontal" and math.max(0,(tonumber(c.width) or 0)-p.left-p.right) or math.max(0,(tonumber(c.height) or 0)-p.top-p.bottom)
            local primary=c:ResolvePrimary(total)
            local moving = UI:TryInteractionCall(dividerDrag, "StartMoving")
            if moving ~= true then return false end
            c.dragging=true; c.dragStartAxis=axis; c.dragStartPrimary=primary
            StopDragTask()
            local scheduled = false
            if S.Scheduler~=nil and type(S.Scheduler.AddInteractiveTask)=="function" then
                scheduled = S.Scheduler:AddInteractiveTask(c.dragTaskName,16,function() if c.dragging then SyncDrag(false) end return true end,true,c,"P0",1) == true
            end
            -- 专用分隔条仅在手势期间持有 OnUpdate 兜底，拖动停止即释放；启动/重载时 Scheduler 不可用也保持实时反馈，不形成永久 Tick。
            if scheduled ~= true then
                c.dragUpdateFallback = UI:SafeHandler(dividerDrag,"OnUpdate",function() if c.dragging then SyncDrag(false) end return true end,"rsui:"..c.id..":split_drag_update") == true
            end
            SyncDrag(false)
            return true
        end,"rsui:"..c.id..":split_drag_start")
        local stopBound, stopErr = UI:RequireHandler(dividerDrag,"OnDragStop",function()
            SyncDrag(true); StopDragTask()
            if type(dividerDrag.StopMovingOrSizing)=="function" then pcall(function() dividerDrag:StopMovingOrSizing() end) end
            c.dragging=false; c.dragStartAxis=nil; c.dragStartPrimary=nil
            if c.width and c.height then c:Layout(c.x or 0,c.y or 0,c.width,c.height) end
            return true
        end,"rsui:"..c.id..":split_drag_stop")
        if startBound ~= true or stopBound ~= true then
            c.rsUiDegraded = true
            c.rsUiDegradedReason = tostring(startErr or stopErr or "split_required_handler_failed")
        end
    end

    local baseRelease=c.Release
    function c:Release()
        StopDragTask()
        if self.dragging == true and self.dividerDrag ~= nil and type(self.dividerDrag.StopMovingOrSizing) == "function" then
            pcall(function() self.dividerDrag:StopMovingOrSizing() end)
        end
        self.dragging=false; self.dragStartAxis=nil; self.dragStartPrimary=nil
        if self.dividerDrag~=nil and type(self.dividerDrag.ReleaseHandler)=="function" then
            pcall(function() self.dividerDrag:ReleaseHandler("OnDragStart") end); pcall(function() self.dividerDrag:ReleaseHandler("OnDragStop") end); pcall(function() self.dividerDrag:ReleaseHandler("OnUpdate") end)
        end
        return baseRelease(self)
    end
    return c
end)

function RSUI:SplitView(spec)
    return self:Create("SplitView", spec)
end

-- ScrollBox 安全条目吸附视口。
RSUI:RegisterType("ScrollBox", function(spec)
    local c, err = Host("ScrollBox", spec)
    if c == nil then return nil, err end
    c.orientation = tostring(spec.orientation or "vertical"):lower()
    c.scrollOffset = math.max(0, math.floor(N(spec.scrollOffset, 0)))
    c.scrollStep = math.max(1, math.floor(N(spec.scrollStep, 1)))
    c.visibleStart, c.visibleEnd = 0, 0
    c.wheelTargets = setmetatable({}, { __mode = "k" })
    c.scrollbarEnabled = spec.scrollbar ~= false
    c.scrollbarReserve = spec.reserveScrollbar == true
    c.scrollbarWidth = math.max(10, N(spec.scrollbarWidth, 14))
    c.scrollbarGap = math.max(2, N(spec.scrollbarGap, 4))
    c.scrollbarMinThumb = math.max(6, N(spec.scrollbarMinThumb, 12))
    c.scrollbar = nil

    function c:BindWheelTarget(componentOrRoot)
        local root = type(componentOrRoot) == "table" and componentOrRoot.root or componentOrRoot
        if root == nil then return false, "scrollbox_wheel_target_required" end
        if self.wheelTargets[root] == true then return true, nil end
        if type(root.EnableScroll) == "function" then
            if type(UI.TryInteractionCall) ~= "function" then return self:FailClosedInteraction("scrollbox_interaction_contract_unavailable") end
            local scrollOk, scrollErr = UI:TryInteractionCall(root, "EnableScroll", true)
            if scrollOk ~= true then return self:FailClosedInteraction("scrollbox_enable_scroll_failed:" .. tostring(scrollErr or "unknown")) end
        end
        -- 视口必须是真实命中目标；子控件保留自身命中策略，不能在此改变而抢走嵌套按钮/输入点击。
        if root == self.root then
            if type(UI.EnsurePickable) ~= "function" then return self:FailClosedInteraction("scrollbox_pickable_contract_unavailable") end
            local pickOk, _, pickErr = UI:EnsurePickable(root, true, self.owner)
            if pickOk ~= true then return self:FailClosedInteraction("scrollbox_root_pickable_failed:" .. tostring(pickErr or "unknown")) end
        end
        -- RU 子按钮/文本/卡片常持有鼠标命中；为各后代绑定滚轮并转发最近 ScrollBox，使滚动不依赖光标像素，不需轮询或焦点状态。
        local upKey = "rsui:" .. self.id .. ":wheel_up_desc"
        local downKey = "rsui:" .. self.id .. ":wheel_down_desc"
        local upOk = self:On(root, "OnWheelUp", function() return self:ScrollBy(-self.scrollStep) end, upKey)
        local downOk = self:On(root, "OnWheelDown", function() return self:ScrollBy(self.scrollStep) end, downKey)
        if upOk ~= true or downOk ~= true then
            if upOk == true then self:Off(root, "OnWheelUp", upKey) end
            if downOk == true then self:Off(root, "OnWheelDown", downKey) end
            return self:FailClosedInteraction("scrollbox_wheel_handler_pair_failed")
        end
        self.wheelTargets[root] = true
        return true, nil
    end

    function c:OnDescendantAdded(component)
        if component == self then return true end
        -- 嵌套 ScrollBox 持有自身子树；外层滚轮转发器不能安装到嵌套视口。
        if type(component) == "table" and tostring(component.kind or "") == "ScrollBox" then return true end
        self:BindWheelTarget(component)
        return true
    end

    local rootWheelOk, rootWheelErr = c:BindWheelTarget(c.root)
    if rootWheelOk ~= true then return c, rootWheelErr end

    function c:GetScrollableEntries()
        return VisibleEntries(self)
    end

    function c:GetMaxOffset()
        if tonumber(self.maxScrollOffset) ~= nil then return math.max(0, math.floor(self.maxScrollOffset)) end
        return math.max(0, #self:GetScrollableEntries() - 1)
    end

    function c:ComputeBottomOffset(entries, primaryAvail, crossAvail, horizontal)
        local used, start = 0, #entries
        for index = #entries, 1, -1 do
            local ow, oh = OuterSize(entries[index], horizontal and nil or crossAvail, horizontal and crossAvail or nil)
            local primary = horizontal and ow or oh
            local needed = primary + (used > 0 and self.gap or 0)
            if used > 0 and used + needed > primaryAvail + 0.01 then break end
            used = used + needed
            start = index
            if used >= primaryAvail - 0.01 then break end
        end
        return math.max(0, start - 1)
    end

    function c:SetScrollOffset(offset, relayout)
        local value = math.max(0, math.min(self:GetMaxOffset(), math.floor(N(offset, self.scrollOffset))))
        if value == self.scrollOffset then return false end
        self.scrollOffset = value
        self:InvalidateLayout("scroll_offset")
        RSUI.metrics.scrollChanges = (tonumber(RSUI.metrics.scrollChanges) or 0) + 1
        if relayout ~= false and self.width and self.height then self:Layout(self.x or 0, self.y or 0, self.width, self.height) end
        return true
    end

    function c:ScrollBy(delta)
        return self:SetScrollOffset(self.scrollOffset + math.floor(N(delta, 0)))
    end
    function c:ScrollToTop() return self:SetScrollOffset(0) end
    function c:ScrollToBottom() return self:SetScrollOffset(self:GetMaxOffset()) end
    function c:EnsureChildVisible(childOrId)
        local entries = self:GetScrollableEntries()
        for index, entry in ipairs(entries) do
            if entry.child == childOrId or tostring(entry.child.id or "") == tostring(childOrId or "") then
                if index >= self.visibleStart and index <= self.visibleEnd then return false end
                return self:SetScrollOffset(index - 1)
            end
        end
        return false
    end

    function c:GetScrollbarReserve(needsScrollbar)
        if self.scrollbarEnabled ~= true then return 0 end
        if needsScrollbar == true or self.scrollbarReserve == true then return self.scrollbarWidth + self.scrollbarGap end
        return 0
    end

    if c.scrollbarEnabled and type(RSUI.ScrollbarBehavior) == "table" and type(RSUI.ScrollbarBehavior.Attach) == "function" then
        local scrollbar, scrollbarErr = RSUI.ScrollbarBehavior:Attach(c, {
            id = c.id .. "_scrollbar",
            orientation = c.orientation,
            thickness = c.scrollbarWidth,
            minThumb = c.scrollbarMinThumb,
            getMaxOffset = function(host) return host:GetMaxOffset() end,
            getOffset = function(host) return host.scrollOffset end,
            setOffset = function(host, value, relayout) return host:SetScrollOffset(value, relayout) end,
            getVisibleUnits = function(host) return math.max(1, (tonumber(host.visibleEnd) or 0) - (tonumber(host.visibleStart) or 0) + 1) end,
            getTotalUnits = function(host) return math.max(1, #host:GetScrollableEntries()) end,
        })
        c.scrollbar = scrollbar
        if scrollbar == nil then
            c.rsUiDegraded = true
            c.rsUiDegradedReason = "scrollbar_attach_failed:" .. tostring(scrollbarErr or "unknown")
        end
    end

    function c:Measure(availableW, availableH)
        local p = Pad(self.spec.padding)
        local horizontal = self.orientation == "horizontal"
        local primary, cross, count = 0, 0, 0
        for _, entry in ipairs(self:GetScrollableEntries()) do
            local ow, oh = OuterSize(entry, availableW, availableH)
            primary = primary + (horizontal and ow or oh)
            cross = math.max(cross, horizontal and oh or ow)
            count = count + 1
        end
        if count > 1 then primary = primary + self.gap * (count - 1) end
        local w, h = horizontal and primary or cross, horizontal and cross or primary
        w, h = w + p.left + p.right, h + p.top + p.bottom
        if tonumber(self.spec.maxDesiredWidth) then w = math.min(w, tonumber(self.spec.maxDesiredWidth)) end
        if tonumber(self.spec.maxDesiredHeight) then h = math.min(h, tonumber(self.spec.maxDesiredHeight)) end
        if availableW ~= nil and self.spec.allowOverflow ~= true then w = math.min(w, math.max(0, N(availableW, w))) end
        if availableH ~= nil and self.spec.allowOverflow ~= true then h = math.min(h, math.max(0, N(availableH, h))) end
        self.desiredWidth, self.desiredHeight, self.measureDirty = w, h, false
        return w, h
    end

    function c:Layout(x, y, width, height)
        width, height = math.max(1, N(width, self.width or 1)), math.max(1, N(height, self.height or 1))
        self:SetBounds(x, y, width, height)
        local p = Pad(self.spec.padding)
        local horizontal = self.orientation == "horizontal"
        local primaryAvail = horizontal and math.max(0, width - p.left - p.right) or math.max(0, height - p.top - p.bottom)
        local fullCrossAvail = horizontal and math.max(0, height - p.top - p.bottom) or math.max(0, width - p.left - p.right)
        local entries = self:GetScrollableEntries()
        local preliminaryMax = self:ComputeBottomOffset(entries, primaryAvail, fullCrossAvail, horizontal)
        local reserve = self:GetScrollbarReserve(preliminaryMax > 0)
        local crossAvail = math.max(0, fullCrossAvail - reserve)
        self.maxScrollOffset = self:ComputeBottomOffset(entries, primaryAvail, crossAvail, horizontal)
        self.scrollOffset = math.max(0, math.min(self:GetMaxOffset(), self.scrollOffset))
        local cursor = horizontal and p.left or p.top
        local start = self.scrollOffset + 1
        local shown = 0
        local placements = {}
        self.visibleStart, self.visibleEnd = start, start - 1
        self.lastOverflow = 0
        for index = start, #entries do
            local entry, slot = entries[index], entries[index].slot
            local ow, oh, dw, dh = OuterSize(entry, horizontal and nil or crossAvail, horizontal and crossAvail or nil)
            local outerPrimary = horizontal and ow or oh
            local remaining = primaryAvail - ((horizontal and cursor - p.left) or (cursor - p.top))
            if shown > 0 and outerPrimary > remaining + 0.01 then break end
            local allocated = math.min(outerPrimary, math.max(1, remaining))
            local pad = slot.padding
            local contentPrimary = math.max(0, allocated - (horizontal and (pad.left + pad.right) or (pad.top + pad.bottom)))
            local contentCross = math.max(0, crossAvail - (horizontal and (pad.top + pad.bottom) or (pad.left + pad.right)))
            local px, py, pw, ph
            if horizontal then
                local cy, ch = Align(p.top + pad.top, contentCross, dh, slot.vAlign)
                local cx, cw = Align(cursor + pad.left, contentPrimary, dw, slot.hAlign)
                px, py, pw, ph = cx, cy, cw, ch
            else
                local cx, cw = Align(p.left + pad.left, contentCross, dw, slot.hAlign)
                local cy, ch = Align(cursor + pad.top, contentPrimary, dh, slot.vAlign)
                px, py, pw, ph = cx, cy, cw, ch
            end
            placements[#placements + 1] = { child = entry.child, x = px, y = py, width = math.max(1, pw), height = math.max(1, ph) }
            shown = shown + 1
            self.visibleEnd = index
            cursor = cursor + allocated + self.gap
            if outerPrimary > allocated + 0.01 then
                self.lastOverflow = math.max(self.lastOverflow, outerPrimary - allocated)
                break
            end
        end
        -- 先计算最终可见区，再一次提交显隐。旧版每次排版先全隐藏再显示，
        -- 战斗刷新会隐藏正在按下的按钮祖先，导致 Native 取消点击；留在视口的控件必须持续可见。
        for index, entry in ipairs(entries) do
            SetViewport(entry.child, index >= self.visibleStart and index <= self.visibleEnd)
        end
        for _, placement in ipairs(placements) do
            Arrange(placement.child, placement.x, placement.y, placement.width, placement.height)
        end
        RecordOverflow(self, self.lastOverflow)
        self.canScrollBackward = self.scrollOffset > 0
        self.canScrollForward = self.visibleEnd < #entries
        if self.scrollbar ~= nil then
            local visibleUnits = math.max(1, self.visibleEnd - self.visibleStart + 1)
            if horizontal then
                self.scrollbar:Layout(p.left, height - p.bottom - self.scrollbarWidth, primaryAvail, self.scrollbarWidth, visibleUnits, math.max(1, #entries))
            else
                self.scrollbar:Layout(width - p.right - self.scrollbarWidth, p.top, self.scrollbarWidth, primaryAvail, visibleUnits, math.max(1, #entries))
            end
        end
        return height
    end

    local baseRelease = c.Release
    function c:Release()
        if self.scrollbar ~= nil and type(self.scrollbar.Release) == "function" then self.scrollbar:Release() end
        self.scrollbar = nil
        return baseRelease(self)
    end

    -- 根滚轮同样经上方 BindWheelTarget 安装，与视口/后代共用路径。
    return c
end)

------------------------------------------------------------------------
-- Replicated Suite · 组合布局模板
-- 作者：Replicated
-- QQ群：1104129461
--
-- 模板建在现有 HorizontalBox/VerticalBox/Border/SizeBox/Overlay 上，复用 RSUI.LayoutUtil Measure/Align/Arrange/Slot 与组件树，不新增布局权威。
-- 设计规则见 RSUI_ARCHITECTURE.md §7/§8：纯策略与类型相邻，零 Native 副作用验证小窗口/序列；仅布局/事件驱动，无 Tick/OnUpdate/轮询；
-- Measure 不写 Native，Layout 仅通过 Diff/Anchor；窄窗标签收缩/省略/列折叠须明确并计入 RSUI.metrics，不隐藏钳制。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local UI, RSUI = S.UI, S.RSUI
if type(UI) ~= "table" or type(RSUI) ~= "table" then return end
local U = RSUI.LayoutUtil
if type(U) ~= "table" then return end

local N, Clamp, Pad, Slot, Measure, Align, Arrange, Host = U.N, U.Clamp, U.Pad, U.Slot, U.Measure, U.Align, U.Arrange, U.Host
local Base = RSUI.BaseComponent
local Tokens = S.UITokens or {}

local function Token(path, fallback)
    if type(Tokens.Number) == "function" then return Tokens:Number(path, fallback) end
    return tonumber(fallback) or 0
end

local function VisibleEntries(panel)
    local out = {}
    for _, entry in ipairs(panel.slots or {}) do
        if type(entry.child) == "table" and entry.child.visible ~= false then out[#out + 1] = entry end
    end
    return out
end

local function SetViewport(child, visible)
    if type(child) ~= "table" then return end
    if type(child.SetViewportVisible) == "function" then child:SetViewportVisible(visible)
    elseif child.root ~= nil and type(UI.SetVisible) == "function" then UI:SetVisible(child.root, child.visible ~= false and visible == true, child.owner) end
end

------------------------------------------------------------------------
-- FormRow 表单行。
--
-- 单行 label | control | hint/feedback；标签占声明份额，窄行先收缩到 labelMinWidth 再压控件，不能让紧凑 HUD 标签与控件重叠。
------------------------------------------------------------------------
RSUI.FormRowPolicy = RSUI.FormRowPolicy or { version = 1 }
RSUI.FormRowPolicy.version = 2
function RSUI.FormRowPolicy:Resolve(innerWidth, gap, labelShare, labelMinWidth, controlMinWidth, hintWidth)
    innerWidth = math.max(0, tonumber(innerWidth) or 0)
    gap = math.max(0, tonumber(gap) or 0)
    labelShare = Clamp(tonumber(labelShare) or 0.35, 0, 1)
    labelMinWidth = math.max(0, tonumber(labelMinWidth) or 0)
    controlMinWidth = math.max(0, tonumber(controlMinWidth) or 0)
    hintWidth = math.max(0, tonumber(hintWidth) or 0)

    local hintGap = hintWidth > 0 and gap or 0
    local fixed = labelMinWidth + controlMinWidth + hintWidth + (hintWidth > 0 and gap * 2 or gap)
    local labelW = math.floor(innerWidth * labelShare)
    if labelW < labelMinWidth then labelW = math.min(labelMinWidth, innerWidth) end

    local controlW = math.max(0, innerWidth - labelW - hintWidth - (hintWidth > 0 and gap * 2 or gap))
    -- 最小值也放不下时先丢提示，再让标签为控件让空间，避免负 extent。
    if controlW < controlMinWidth and hintWidth > 0 then
        hintWidth = 0
        controlW = math.max(0, innerWidth - labelW - gap)
    end
    if controlW < controlMinWidth then
        local extra = math.min(labelW - math.min(labelW, labelMinWidth), controlMinWidth - controlW)
        labelW = labelW - extra
        controlW = controlW + extra
    end
    return math.max(0, labelW), math.max(0, controlW), math.max(0, hintWidth)
end

RSUI.FormRowResponsiveContractVersion = 1
function RSUI.FormRowPolicy:ResolveMode(availableWidth, layout, collapseWidth)
    layout = tostring(layout or "horizontal"):lower()
    if layout == "vertical" then return "vertical" end
    if layout ~= "auto" and layout ~= "responsive" then return "horizontal" end
    collapseWidth = math.max(1, tonumber(collapseWidth) or Token("settings.settingRowCollapseWidth", 360))
    if tonumber(availableWidth) ~= nil and tonumber(availableWidth) < collapseWidth then return "vertical" end
    return "horizontal"
end

RSUI:RegisterType("FormRow", function(spec)
    local c, err = Host("FormRow", spec)
    if c == nil then return nil, err end
    c.gap = math.max(0, N(spec.gap, Token("spacing.sm", 8)))
    c.labelShare = Clamp(N(spec.labelShare or spec.labelRatio, 0.35), 0, 1)
    c.labelMinWidth = math.max(0, N(spec.labelMinWidth, Token("component.form.labelW", 116)))
    c.controlMinWidth = math.max(0, N(spec.controlMinWidth, 60))
    c.hintWidth = math.max(0, N(spec.hintWidth, 0))
    c.layoutMode = tostring(spec.layout or spec.direction or "horizontal"):lower()
    c.collapseWidth = math.max(1, N(spec.collapseWidth, Token("settings.settingRowCollapseWidth", 360)))
    c.lastResolvedMode = nil

    function c:GetZones()
        local entries = VisibleEntries(self)
        return entries[1], entries[2], entries[3]
    end

    function c:ResolveLayoutMode(availableWidth)
        local p = Pad(self.spec.padding)
        local inner = tonumber(availableWidth)
        if inner ~= nil then inner = math.max(0, inner - p.left - p.right) end
        local mode = RSUI.FormRowPolicy:ResolveMode(inner, self.layoutMode, self.collapseWidth)
        if self.lastResolvedMode ~= nil and self.lastResolvedMode ~= mode then
            RSUI.metrics.settingsResponsiveModeChanges = (tonumber(RSUI.metrics.settingsResponsiveModeChanges) or 0) + 1
        end
        self.lastResolvedMode = mode
        return mode
    end

    function c:GetResolvedLayoutMode()
        return self.lastResolvedMode or self:ResolveLayoutMode(self.width or self.spec.width)
    end

    function c:Measure(availableW, availableH)
        local p = Pad(self.spec.padding)
        local innerW = availableW and math.max(0, N(availableW, 0) - p.left - p.right) or nil
        local innerH = availableH and math.max(0, N(availableH, 0) - p.top - p.bottom) or nil
        local label, control, hint = self:GetZones()
        local lw, lh, cw, ch, hw, hh = 0, 0, 0, 0, 0, 0
        if label ~= nil then lw, lh = Measure(label.child, innerW, innerH) end
        if control ~= nil then cw, ch = Measure(control.child, innerW, innerH) end
        if hint ~= nil then hw, hh = Measure(hint.child, innerW, innerH) end
        local mode = self:ResolveLayoutMode(availableW)
        local w, h
        if mode == "vertical" then
            local visibleCount = (label and 1 or 0) + (control and 1 or 0) + (hint and 1 or 0)
            w = math.max(lw, cw, hw) + p.left + p.right
            h = lh + ch + hh + self.gap * math.max(0, visibleCount - 1) + p.top + p.bottom
        else
            local gapCount = (label and control and 1 or 0) + (hint and (control or label) and 1 or 0)
            w = lw + cw + hw + self.gap * gapCount + p.left + p.right
            h = math.max(lh, ch, hh) + p.top + p.bottom
        end
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
        local label, control, hint = self:GetZones()
        local mode = self:ResolveLayoutMode(width)
        if mode == "vertical" then
            local cursor = p.top
            local entries = { label, control, hint }
            local remaining = 0
            for _, entry in ipairs(entries) do if entry ~= nil and entry.child.visible ~= false then remaining = remaining + 1 end end
            for _, entry in ipairs(entries) do
                if entry ~= nil and entry.child.visible ~= false then
                    local dw, dh = Measure(entry.child, iw, math.max(0, ih - cursor + p.top))
                    local ex, ew = Align(p.left, iw, dw, entry.slot.hAlign)
                    Arrange(entry.child, ex, cursor, math.max(1, ew), math.max(1, dh))
                    remaining = remaining - 1
                    cursor = cursor + dh + (remaining > 0 and self.gap or 0)
                end
            end
            return height
        end
        local hintW = hint ~= nil and N(self.hintWidth > 0 and self.hintWidth or nil, 0) or 0
        local labelW, controlW, usedHintW = RSUI.FormRowPolicy:Resolve(iw, self.gap, self.labelShare, self.labelMinWidth, self.controlMinWidth, hintW)
        local cursor = p.left
        if label ~= nil then
            local dw, dh = Measure(label.child, labelW, ih)
            local lx, lw2 = Align(cursor, labelW, dw, label.slot.hAlign)
            local ly, lh = Align(p.top, ih, dh, label.slot.vAlign)
            Arrange(label.child, lx, ly, math.max(1, lw2), math.max(1, lh))
            cursor = cursor + labelW + self.gap
        end
        if control ~= nil then
            local dw, dh = Measure(control.child, controlW, ih)
            local cx, cw2 = Align(cursor, controlW, dw, control.slot.hAlign)
            local cy, ch = Align(p.top, ih, dh, control.slot.vAlign)
            Arrange(control.child, cx, cy, math.max(1, cw2), math.max(1, ch))
            cursor = cursor + controlW + self.gap
        end
        if hint ~= nil and usedHintW > 0 then
            local dw, dh = Measure(hint.child, usedHintW, ih)
            local hx, hw2 = Align(cursor, usedHintW, dw, hint.slot.hAlign)
            local hy, hh = Align(p.top, ih, dh, hint.slot.vAlign)
            Arrange(hint.child, hx, hy, math.max(1, hw2), math.max(1, hh))
        end
        return height
    end
    return c
end)

------------------------------------------------------------------------
-- KeyValueRow 键值行。
--
-- 标签在左、值右对齐；先测值并保留固定宽，标签填余量且省略。
------------------------------------------------------------------------
RSUI.KeyValueRowPolicy = RSUI.KeyValueRowPolicy or { version = 1 }
function RSUI.KeyValueRowPolicy:Resolve(innerWidth, gap, valueMinWidth, valueMaxShare)
    innerWidth = math.max(0, tonumber(innerWidth) or 0)
    gap = math.max(0, tonumber(gap) or 0)
    valueMinWidth = math.max(0, tonumber(valueMinWidth) or 0)
    valueMaxShare = Clamp(tonumber(valueMaxShare) or 0.5, 0, 1)
    local valueW = math.min(math.floor(innerWidth * valueMaxShare), math.max(valueMinWidth, innerWidth - gap - valueMinWidth))
    valueW = math.max(0, math.min(valueW, innerWidth - gap))
    local labelW = math.max(0, innerWidth - valueW - gap)
    return labelW, valueW
end

RSUI:RegisterType("KeyValueRow", function(spec)
    local c, err = Host("KeyValueRow", spec)
    if c == nil then return nil, err end
    c.gap = math.max(0, N(spec.gap, Token("spacing.sm", 8)))
    c.valueMinWidth = math.max(0, N(spec.valueMinWidth, 40))
    c.valueMaxShare = Clamp(N(spec.valueMaxShare, 0.5), 0, 1)

    function c:GetZones()
        return VisibleEntries(self)[1], VisibleEntries(self)[2]
    end

    function c:Measure(availableW, availableH)
        local p = Pad(self.spec.padding)
        local label, value = self:GetZones()
        local lw = label and Measure(label.child, availableW, availableH) or 0
        local vw = value and Measure(value.child, availableW, availableH) or 0
        local w = lw + vw + (label and value and self.gap or 0) + p.left + p.right
        local h = math.max(lw, vw) + p.top + p.bottom
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
        local label, value = self:GetZones()
        local labelW, valueW = RSUI.KeyValueRowPolicy:Resolve(iw, self.gap, self.valueMinWidth, self.valueMaxShare)
        if label ~= nil then
            local dw, dh = Measure(label.child, labelW, ih)
            local lx, lw2 = Align(p.left, labelW, dw, label.slot.hAlign)
            local ly, lh = Align(p.top, ih, dh, label.slot.vAlign)
            Arrange(label.child, lx, ly, math.max(1, lw2), math.max(1, lh))
        end
        if value ~= nil then
            local dw, dh = Measure(value.child, valueW, ih)
            local vx = p.left + labelW + self.gap
            local vx2, vw2 = Align(vx, valueW, dw, "right")
            local vy, vh = Align(p.top, ih, dh, value.slot.vAlign)
            Arrange(value.child, vx2, vy, math.max(1, vw2), math.max(1, vh))
        end
        return height
    end
    return c
end)

------------------------------------------------------------------------
-- Toolbar 工具条。
--
-- 子节点按 slot.group 分组：left 默认从左紧排，right 从右紧排，spacer 扩展填中间。
------------------------------------------------------------------------
RSUI.ToolbarPolicy = RSUI.ToolbarPolicy or { version = 1 }
function RSUI.ToolbarPolicy:Partition(entries)
    local left, right, spacers = {}, {}, {}
    for _, entry in ipairs(entries or {}) do
        local group = tostring((type(entry.slot) == "table" and entry.slot.group) or "left"):lower()
        if group == "right" then right[#right + 1] = entry
        elseif group == "spacer" then spacers[#spacers + 1] = entry
        else left[#left + 1] = entry end
    end
    return left, right, spacers
end

RSUI:RegisterType("Toolbar", function(spec)
    local c, err = Host("Toolbar", spec)
    if c == nil then return nil, err end
    c.gap = math.max(0, N(spec.gap, Token("spacing.sm", 8)))

    function c:Measure(availableW, availableH)
        local p = Pad(self.spec.padding)
        local left, right, spacers = RSUI.ToolbarPolicy:Partition(VisibleEntries(self))
        local total = 0
        local count = 0
        for _, entry in ipairs(left) do total = total + Measure(entry.child, availableW, availableH); count = count + 1 end
        for _, entry in ipairs(right) do total = total + Measure(entry.child, availableW, availableH); count = count + 1 end
        local w = total + (count > 1 and self.gap * (count - 1) or 0) + p.left + p.right
        local h = 0
        for _, entry in ipairs(VisibleEntries(self)) do h = math.max(h, select(2, Measure(entry.child, availableW, availableH))) end
        h = h + p.top + p.bottom
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
        local left, right, spacers = RSUI.ToolbarPolicy:Partition(VisibleEntries(self))
        -- 先固定右组，再左组，spacer 填剩余。
        local rightUsed = 0
        for _, entry in ipairs(right) do
            local dw = Measure(entry.child, iw, ih)
            rightUsed = rightUsed + dw + self.gap
        end
        if #right > 0 then rightUsed = rightUsed - self.gap end
        -- 工具条主轴自动尺寸，每子节点只占测量宽；fill 会让每按钮撑满整条。交叉轴高度仍遵循 vAlign。
        local rightCursor = p.left + iw - rightUsed
        for _, entry in ipairs(right) do
            local dw, dh = Measure(entry.child, iw, ih)
            local rx, rw = Align(rightCursor, dw, dw, "left")
            local ry, rh = Align(p.top, ih, dh, entry.slot.vAlign)
            Arrange(entry.child, rx, ry, math.max(1, rw), math.max(1, rh))
            rightCursor = rightCursor + dw + self.gap
        end
        local leftCursor = p.left
        local leftUsed = 0
        for _, entry in ipairs(left) do leftUsed = leftUsed + Measure(entry.child, iw, ih) + self.gap end
        local spacerWidth = math.max(0, (rightCursor - self.gap) - leftCursor - leftUsed)
        for _, entry in ipairs(left) do
            local dw, dh = Measure(entry.child, iw, ih)
            local lx, lw2 = Align(leftCursor, dw, dw, "left")
            local ly, lh = Align(p.top, ih, dh, entry.slot.vAlign)
            Arrange(entry.child, lx, ly, math.max(1, lw2), math.max(1, lh))
            leftCursor = leftCursor + dw + self.gap
        end
        if #spacers > 0 and spacerWidth > 0 then
            local spacer = spacers[1]
            local dw, dh = Measure(spacer.child, spacerWidth, ih)
            local sx, sw = Align(leftCursor, spacerWidth, spacerWidth, "left")
            local sy, sh = Align(p.top, ih, dh, spacer.slot.vAlign)
            Arrange(spacer.child, sx, sy, math.max(1, sw), math.max(1, sh))
        end
        return height
    end
    return c
end)

------------------------------------------------------------------------
-- HeaderBodyFooter 表头/正文/页脚。
--
-- 标准页面堆栈 header(auto)、body(fill)、footer(auto)；正文固定第二子节点，首/三为表头/页脚。
------------------------------------------------------------------------
RSUI.HeaderBodyFooterPolicy = RSUI.HeaderBodyFooterPolicy or { version = 1 }
function RSUI.HeaderBodyFooterPolicy:Resolve(innerHeight, headerH, footerH, gap, bodyMinHeight)
    innerHeight = math.max(0, tonumber(innerHeight) or 0)
    headerH = math.max(0, tonumber(headerH) or 0)
    footerH = math.max(0, tonumber(footerH) or 0)
    gap = math.max(0, tonumber(gap) or 0)
    bodyMinHeight = math.max(0, tonumber(bodyMinHeight) or 0)
    local fixed = headerH + footerH + (headerH > 0 and footerH > 0 and gap * 2 or (headerH > 0 or footerH > 0) and gap or 0)
    local bodyH = math.max(bodyMinHeight, innerHeight - fixed)
    return math.max(0, headerH), math.max(0, bodyH), math.max(0, footerH)
end

RSUI:RegisterType("HeaderBodyFooter", function(spec)
    local c, err = Host("HeaderBodyFooter", spec)
    if c == nil then return nil, err end
    c.gap = math.max(0, N(spec.gap, Token("spacing.sm", 8)))
    c.bodyMinHeight = math.max(0, N(spec.bodyMinHeight, 0))

    function c:GetZones()
        local entries = VisibleEntries(self)
        return entries[1], entries[2], entries[3]
    end

    function c:Measure(availableW, availableH)
        local p = Pad(self.spec.padding)
        local header, body, footer = self:GetZones()
        -- 须显式双值赋值；
        -- `local hw, hh = header and Measure(...) or 0, 0` 解析为 hw=(header and Measure(...) or 0)、hh=0，逗号优先级低于 or，静默丢高度，与 CollapsibleGroup:Measure 同陷阱。
        local hw, hh, bw, bh, fw, fh = 0, 0, 0, 0, 0, 0
        if header ~= nil then hw, hh = Measure(header.child, availableW, availableH) end
        if body ~= nil then bw, bh = Measure(body.child, availableW, availableH) end
        if footer ~= nil then fw, fh = Measure(footer.child, availableW, availableH) end
        local w = math.max(hw, bw, fw) + p.left + p.right
        local count = (header and 1 or 0) + (body and 1 or 0) + (footer and 1 or 0)
        local h = hh + bh + fh + (count > 1 and self.gap * (count - 1) or 0) + p.top + p.bottom
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
        local header, body, footer = self:GetZones()
        local headerH, footerH = 0, 0
        if header then headerH = select(2, Measure(header.child, iw, ih)) end
        if footer then footerH = select(2, Measure(footer.child, iw, ih)) end
        local hh2, bodyH, fh2 = RSUI.HeaderBodyFooterPolicy:Resolve(ih, headerH, footerH, self.gap, self.bodyMinHeight)
        local cursor = p.top
        if header ~= nil then
            local dw, dh = Measure(header.child, iw, hh2)
            Arrange(header.child, p.left, cursor, iw, math.max(1, dh))
            cursor = cursor + dh + self.gap
        end
        if body ~= nil then
            local dw, dh = Measure(body.child, iw, bodyH)
            Arrange(body.child, p.left, cursor, iw, math.max(1, bodyH))
            cursor = cursor + bodyH + self.gap
        end
        if footer ~= nil then
            local dw, dh = Measure(footer.child, iw, fh2)
            Arrange(footer.child, p.left, cursor, iw, math.max(1, dh))
        end
        return height
    end
    return c
end)

------------------------------------------------------------------------
-- GroupBox 分组框。
--
-- 单一 Border 内组合标题条、内容、可选页脚；基于 Border/HeaderBodyFooter 继承完整 Measure/Arrange，区别于旧 Section。
------------------------------------------------------------------------
RSUI:RegisterType("GroupBox", function(spec)
    local border = UI:CreatePanel(spec.parent, spec.id, N(spec.x, 0), N(spec.y, 0), math.max(1, N(spec.width, 1)), math.max(1, N(spec.height, 1)), spec.variant or "card", { gradient = spec.gradient, accentStrip = spec.accentStrip })
    if border == nil then return nil, "groupbox_create_failed" end
    local c = RSUI:NewComponent("GroupBox", spec, border)
    c.padding = Pad(spec.padding or Token("component.card.padding", 10))
    c.gap = math.max(0, N(spec.gap, Token("spacing.sm", 8)))
    c.headerHeight = math.max(0, N(spec.headerHeight, Token("size.sectionHeaderH", 28)))
    c.content = nil

    local title = nil
    if spec.title ~= nil and tostring(spec.title) ~= "" then
        title = UI:CreateLabel(border, spec.id .. "_title", tostring(spec.title), c.padding.left, 2, math.max(1, N(spec.width, 1) - c.padding.left - c.padding.right), c.headerHeight - 4, N(spec.titleFontSize, Token("font.section", 13)), spec.tone or "default", ALIGN_LEFT, true)
        if title ~= nil then title.rsUiOwner = c.owner end
    end
    c.title = title
    c.appearanceWidgets = title and { title } or {} -- 约束（2026-10-09）：原生标题显式继承组件外观通道。

    local baseAdd = c.AddChild
    function c:AddChild(child, slot)
        local result, ok, attachErr = baseAdd(self, child, slot)
        if result ~= nil and self.content == nil then self.content = result end
        return result, ok, attachErr
    end
    function c:SetTitle(text)
        if self.title ~= nil then UI:SetText(self.title, tostring(text or ""), self.owner) end
        return true
    end
    function c:GetContentRoot() return self.root end

    function c:Measure(availableW, availableH)
        local headerH = (self.title ~= nil) and self.headerHeight or 0
        local dw, dh = Measure(self.content, availableW and availableW - self.padding.left - self.padding.right, availableH and availableH - self.padding.top - self.padding.bottom - headerH - self.gap)
        local w = dw + self.padding.left + self.padding.right
        local h = headerH + self.gap + dh + self.padding.top + self.padding.bottom
        if self.spec.width then w = N(self.spec.width, w) end
        if self.spec.height then h = N(self.spec.height, h) end
        w = Clamp(w, self.spec.minWidth, self.spec.maxWidth)
        h = Clamp(h, self.spec.minHeight, self.spec.maxHeight)
        if availableW ~= nil and self.spec.allowOverflow ~= true then w = math.min(w, math.max(0, N(availableW, w))) end
        if availableH ~= nil and self.spec.allowOverflow ~= true then h = math.min(h, math.max(0, N(availableH, h))) end
        self.desiredWidth, self.desiredHeight, self.measureDirty = w, h, false
        return w, h
    end

    function c:Layout(x, y, width, height)
        width, height = math.max(1, N(width, self.width or self.spec.width or 1)), math.max(1, N(height, self.height or self.spec.height or 1))
        self:SetBounds(x, y, width, height)
        if self.title ~= nil then
            UI:SetExtent(self.title, math.max(1, width - self.padding.left - self.padding.right), math.max(1, self.headerHeight - 4), self.owner)
            UI:SetAnchor(self.title, self.root, self.padding.left, 2, self.owner)
        end
        local headerH = (self.title ~= nil) and self.headerHeight or 0
        if self.content ~= nil and self.content.visible ~= false then
            Arrange(self.content, self.padding.left, self.padding.top + headerH + self.gap, math.max(1, width - self.padding.left - self.padding.right), math.max(1, height - self.padding.top - self.padding.bottom - headerH - self.gap))
        end
        return height
    end
    return c
end)

------------------------------------------------------------------------
-- CollapsibleGroup 可折叠分组。
--
-- 可点标题展开/折叠的 GroupBox，复用 Border/标题条加小箭头，保留完整 Measure/Arrange；仅增加表现 expanded 标志，不持业务事实。折叠内容隐藏且零高，不留空隙。
------------------------------------------------------------------------
RSUI.CollapsibleGroupPolicy = RSUI.CollapsibleGroupPolicy or { version = 1 }
RSUI.CollapsibleGroupInteractionContractVersion = 2
function RSUI.CollapsibleGroupPolicy:Resolve(innerHeight, headerH, gap, expanded)
    innerHeight = math.max(0, tonumber(innerHeight) or 0)
    headerH = math.max(0, tonumber(headerH) or 0)
    gap = math.max(0, tonumber(gap) or 0)
    local fixed = headerH
    if expanded ~= false then fixed = fixed + gap end
    -- 展开内容填剩余（>=0）；折叠内容零高且无间距，整个组恰为标题高。
    local contentH = expanded ~= false and math.max(0, innerHeight - fixed) or 0
    return math.max(0, headerH), contentH
end

RSUI:RegisterType("CollapsibleGroup", function(spec)
    local border = UI:CreatePanel(spec.parent, spec.id, N(spec.x, 0), N(spec.y, 0), math.max(1, N(spec.width, 1)), math.max(1, N(spec.height, 1)), spec.variant or "card", { gradient = spec.gradient, accentStrip = spec.accentStrip })
    if border == nil then return nil, "collapsiblegroup_create_failed" end
    local c = RSUI:NewComponent("CollapsibleGroup", spec, border)
    c.padding = Pad(spec.padding or Token("component.card.padding", 10))
    c.gap = math.max(0, N(spec.gap, Token("spacing.sm", 8)))
    c.headerHeight = math.max(0, N(spec.headerHeight, Token("size.sectionHeaderH", 28)))
    c.expanded = spec.expanded ~= false
    c.content = nil

    -- 整标题条须为 Native Button 命中面，RU Button 可靠 OnClick，EmptyWidget 不派发点击。按钮位于不可拾取标题/箭头标签下，去主题背景保留 GroupBox 外观；
    -- 箭头表示可操作。按钮是 Border 原生子节点，不参与 Measure，仅 Layout 定位。
    local headerHit = UI:CreateButton(border, spec.id .. "_header_hit", "", 0, 0, math.max(1, N(spec.width, 1)), math.max(1, c.headerHeight), N(spec.titleFontSize, Token("font.section", 13)), false, false)
    if headerHit == nil or headerHit.rsUiDegraded == true then
        if type(RSUI.metrics) == "table" then RSUI.metrics.collapsibleHeaderUnavailable = (tonumber(RSUI.metrics.collapsibleHeaderUnavailable) or 0) + 1 end
        c.rsUiDegraded = true
        c.rsUiDegradedReason = "collapsible_header_create_failed"
        return c, c.rsUiDegradedReason
    end
    headerHit.rsUiOwner = c.owner
    -- 去掉按钮四态主题背景，使标题条保持 GroupBox 外观。
    if type(S.Theme) == "table" and type(S.Theme.SetBackgroundOpacity) == "function" then
        pcall(function() S.Theme:SetBackgroundOpacity(headerHit, 0) end)
    end
    -- 标题点击是 CollapsibleGroup 核心交互，绑定必须成功；失败由组件工厂后边界拒绝整组，不能报告诊断通过却显示死 UI。
    local bound, bindErr = c:RequireOn(headerHit, "OnClick", function()
        if c.released then return nil end
        return c:SetExpanded(not c.expanded, true)
    end, tostring(spec.id) .. ":collapsible_header")
    if bound ~= true then
        if type(RSUI.metrics) == "table" then RSUI.metrics.collapsibleHeaderBindFailed = (tonumber(RSUI.metrics.collapsibleHeaderBindFailed) or 0) + 1 end
        c.rsUiDegraded = true
        c.rsUiDegradedReason = tostring(bindErr or "collapsible_header_bind_failed")
        return c, c.rsUiDegradedReason
    end
    c.headerHit = headerHit

    local title = nil
    if spec.title ~= nil and tostring(spec.title) ~= "" then
        title = UI:CreateLabel(border, spec.id .. "_title", tostring(spec.title), c.padding.left + 12, 2, math.max(1, N(spec.width, 1) - c.padding.left - c.padding.right - 24), c.headerHeight - 4, N(spec.titleFontSize, Token("font.section", 13)), spec.tone or "default", ALIGN_LEFT, true)
        if title ~= nil then title.rsUiOwner = c.owner end
    end
    c.title = title

    -- 箭头字形："▾" 表示展开，"▸" 表示折叠。
    local chevron = UI:CreateLabel(border, spec.id .. "_chevron", c.expanded and "\226\150\190" or "\226\150\184", c.padding.left, 2, 12, c.headerHeight - 4, N(spec.chevronFontSize, Token("font.small", 10)), spec.tone or "muted", ALIGN_CENTER, true)
    if chevron ~= nil then chevron.rsUiOwner = c.owner end
    c.chevron = chevron
    c.appearanceWidgets = {} -- 原生文字不参与 Measure children，但必须跟随同一透明表面策略。
    if title ~= nil then c.appearanceWidgets[#c.appearanceWidgets + 1] = title end
    if chevron ~= nil then c.appearanceWidgets[#c.appearanceWidgets + 1] = chevron end

    local baseAdd = c.AddChild
    function c:AddChild(child, slot)
        local result, ok, attachErr = baseAdd(self, child, slot)
        if result ~= nil and self.content == nil then self.content = result end
        return result, ok, attachErr
    end
    function c:SetTitle(text)
        if self.title ~= nil then UI:SetText(self.title, tostring(text or ""), self.owner) end
        return true
    end
    function c:SetExpanded(expanded, notify)
        -- 变量用 nextState，不能用 next 遮蔽全局 next()，否则此作用域表遍历会失败。
        local nextState = expanded ~= false
        if nextState == self.expanded then return false end
        self.expanded = nextState
        if self.chevron ~= nil then
            UI:SetText(self.chevron, nextState and "\226\150\190" or "\226\150\184", self.owner)
        end
        -- 折叠内容通过 viewport 隐藏，不占布局或留空隙；展开重新显示。
        if self.content ~= nil then SetViewport(self.content, nextState) end
        self:InvalidateMeasure("collapsed_state")
        self:InvalidateLayout("collapsed_state")
        if notify ~= false and type(spec.onExpandedChanged) == "function" then pcall(spec.onExpandedChanged, self, nextState) end
        return true
    end
    function c:GetContentRoot() return self.root end

    function c:Measure(availableW, availableH)
        local headerH = (self.title ~= nil or self.chevron ~= nil) and self.headerHeight or 0
        local dw, dh = 0, 0
        if self.expanded and self.content ~= nil and self.content.visible ~= false then
            -- 显式双值赋值；
            -- `local dw, dh = cond and Measure(...) or 0, 0` 等价 dw=(cond and Measure(...) or 0)、dh=0，逗号低优先级会让展开测量永久丢内容高。
            local contentW = availableW and (availableW - self.padding.left - self.padding.right)
            local contentH = availableH and math.max(0, availableH - self.padding.top - self.padding.bottom - headerH - self.gap)
            dw, dh = Measure(self.content, contentW, contentH)
        end
        local w = dw + self.padding.left + self.padding.right
        local h = headerH + (self.expanded and self.gap or 0) + dh + self.padding.top + self.padding.bottom
        if self.spec.width then w = N(self.spec.width, w) end
        if self.spec.height then h = N(self.spec.height, h) end
        w = Clamp(w, self.spec.minWidth, self.spec.maxWidth)
        h = Clamp(h, self.spec.minHeight, self.spec.maxHeight)
        if availableW ~= nil and self.spec.allowOverflow ~= true then w = math.min(w, math.max(0, N(availableW, w))) end
        if availableH ~= nil and self.spec.allowOverflow ~= true then h = math.min(h, math.max(0, N(availableH, h))) end
        self.desiredWidth, self.desiredHeight, self.measureDirty = w, h, false
        return w, h
    end

    function c:Layout(x, y, width, height)
        width, height = math.max(1, N(width, self.width or self.spec.width or 1)), math.max(1, N(height, self.height or self.spec.height or 1))
        self:SetBounds(x, y, width, height)
        local headerH = (self.title ~= nil or self.chevron ~= nil) and self.headerHeight or 0
        if self.headerHit ~= nil then
            UI:SetExtent(self.headerHit, math.max(1, width), math.max(1, headerH), self.owner)
            UI:SetAnchor(self.headerHit, self.root, 0, 0, self.owner)
        end
        if self.title ~= nil then
            UI:SetExtent(self.title, math.max(1, width - self.padding.left - self.padding.right - 24), math.max(1, headerH - 4), self.owner)
            UI:SetAnchor(self.title, self.root, self.padding.left + 12, 2, self.owner)
        end
        if self.chevron ~= nil then
            UI:SetExtent(self.chevron, 12, math.max(1, headerH - 4), self.owner)
            UI:SetAnchor(self.chevron, self.root, self.padding.left, 2, self.owner)
        end
        if self.expanded and self.content ~= nil and self.content.visible ~= false then
            Arrange(self.content, self.padding.left, self.padding.top + headerH + self.gap, math.max(1, width - self.padding.left - self.padding.right), math.max(1, height - self.padding.top - self.padding.bottom - headerH - self.gap))
        end
        return height
    end
    return c
end)

------------------------------------------------------------------------
-- DetailRow 详情行。
--
-- 前导标签加 1..N 个值列，各值在自身列右对齐；标签保留声明份额，其余宽均分，窄窗先缩标签。
------------------------------------------------------------------------
RSUI.DetailRowPolicy = RSUI.DetailRowPolicy or { version = 1 }
function RSUI.DetailRowPolicy:Resolve(innerWidth, gap, labelShare, labelMinWidth, columnCount, columnMinWidth)
    innerWidth = math.max(0, tonumber(innerWidth) or 0)
    gap = math.max(0, tonumber(gap) or 0)
    labelShare = Clamp(tonumber(labelShare) or 0.3, 0, 1)
    labelMinWidth = math.max(0, tonumber(labelMinWidth) or 0)
    columnCount = math.max(1, math.floor(tonumber(columnCount) or 1))
    columnMinWidth = math.max(0, tonumber(columnMinWidth) or 0)
    local gapsTotal = gap * columnCount
    local labelW = math.floor(innerWidth * labelShare)
    labelW = math.max(labelMinWidth, labelW)
    local remainder = math.max(0, innerWidth - labelW - gapsTotal)
    local columnW = math.max(0, math.floor(remainder / columnCount))
    if columnW < columnMinWidth then
        -- 各列保持最小值，缩标签让位且不低于零，不能产生负/重叠 extent。
        local need = columnMinWidth - columnW
        local give = math.min(labelW - labelMinWidth, need)
        labelW = labelW - give
        remainder = math.max(0, innerWidth - labelW - gapsTotal)
        columnW = math.max(0, math.floor(remainder / columnCount))
    end
    return math.max(0, labelW), math.max(0, columnW)
end

RSUI:RegisterType("DetailRow", function(spec)
    local c, err = Host("DetailRow", spec)
    if c == nil then return nil, err end
    c.gap = math.max(0, N(spec.gap, Token("spacing.sm", 8)))
    c.labelShare = Clamp(N(spec.labelShare or spec.labelRatio, 0.3), 0, 1)
    c.labelMinWidth = math.max(0, N(spec.labelMinWidth, Token("component.form.labelW", 116)))
    c.columnMinWidth = math.max(0, N(spec.columnMinWidth, 40))
    c.columnCount = math.max(1, math.floor(N(spec.columns or spec.columnCount, 1)))

    function c:GetZones()
        return VisibleEntries(self)
    end

    function c:Measure(availableW, availableH)
        local p = Pad(self.spec.padding)
        local entries = self:GetZones()
        local totalW = 0
        local maxH = 0
        for _, entry in ipairs(entries) do
            local dw, dh = Measure(entry.child, availableW, availableH)
            totalW = totalW + dw
            maxH = math.max(maxH, dh)
        end
        local count = #entries
        local w = totalW + (count > 1 and self.gap * (count - 1) or 0) + p.left + p.right
        local h = maxH + p.top + p.bottom
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
        local entries = self:GetZones()
        if #entries == 0 then return height end
        local label = entries[1]
        local valueCount = math.max(0, #entries - 1)
        if valueCount == 0 then
            -- 仅有标签时填满整行。
            local dw, dh = Measure(label.child, iw, ih)
            local lx, lw2 = Align(p.left, iw, dw, label.slot.hAlign)
            local ly, lh = Align(p.top, ih, dh, label.slot.vAlign)
            Arrange(label.child, lx, ly, math.max(1, lw2), math.max(1, lh))
            return height
        end
        local labelW, columnW = RSUI.DetailRowPolicy:Resolve(iw, self.gap, self.labelShare, self.labelMinWidth, valueCount, self.columnMinWidth)
        -- 标签填满自身区域，内容经 slot.hAlign 左对齐。
        local dw, dh = Measure(label.child, labelW, ih)
        local lx, lw2 = Align(p.left, labelW, dw, label.slot.hAlign)
        local ly, lh = Align(p.top, ih, dh, label.slot.vAlign)
        Arrange(label.child, lx, ly, math.max(1, lw2), math.max(1, lh))
        -- 值在各自等宽列中右对齐。
        local cursor = p.left + labelW + self.gap
        for i = 2, #entries do
            local entry = entries[i]
            local vdw, vdh = Measure(entry.child, columnW, ih)
            local vx, vw2 = Align(cursor, columnW, vdw, "right")
            local vy, vh = Align(p.top, ih, vdh, entry.slot.vAlign)
            Arrange(entry.child, vx, vy, math.max(1, vw2), math.max(1, vh))
            cursor = cursor + columnW + self.gap
        end
        return height
    end
    return c
end)

------------------------------------------------------------------------
-- Steps 步骤指示。
--
-- 横向步骤指示用于向导/多阶段进度，各步骤均分单元格；纯策略返回几何与 done/active/pending 状态，表现只渲染三色，无 Native 副作用。
--
-- 模板仅几何、不绘制；步骤子节点显式提供 SetStepState(state,index) 接受 done/active/pending，Layout 仅状态变化时调用。
-- 无方法的子节点仅排列，普通标签保持零耦合。
------------------------------------------------------------------------
RSUI.StepsPolicy = RSUI.StepsPolicy or { version = 1 }
function RSUI.StepsPolicy:Resolve(innerWidth, gap, count, current)
    innerWidth = math.max(0, tonumber(innerWidth) or 0)
    gap = math.max(0, tonumber(gap) or 0)
    count = math.max(1, math.floor(tonumber(count) or 1))
    current = math.max(0, math.floor(tonumber(current) or 0))
    local totalGap = gap * math.max(0, count - 1)
    local cellW = math.max(0, (innerWidth - totalGap) / count)
    local steps = {}
    local cursor = 0
    for i = 1, count do
        local state = (i - 1 < current) and "done" or (i - 1 == current and "active" or "pending")
        -- 最后一格吸收亚像素余量，整宽连续无尾部空隙。
        local width = (i == count) and math.max(0, innerWidth - cursor) or math.floor(cellW)
        steps[#steps + 1] = { x = cursor, width = width, state = state }
        cursor = cursor + width + gap
    end
    return steps
end

RSUI:RegisterType("Steps", function(spec)
    local c, err = Host("Steps", spec)
    if c == nil then return nil, err end
    c.gap = math.max(0, N(spec.gap, Token("spacing.sm", 8)))
    c.count = math.max(1, math.floor(N(spec.count or spec.steps, 1)))
    c.current = math.max(0, math.floor(N(spec.current or spec.activeStep, 0)))
    c.stepHeight = math.max(1, N(spec.stepHeight, Token("size.rowH", 28)))

    function c:SetCurrent(index)
        index = math.max(0, math.floor(tonumber(index) or 0))
        if index == self.current then return false end
        self.current = index
        self:InvalidateMeasure("step_changed")
        self:InvalidateLayout("step_changed")
        return true
    end

    function c:Measure(availableW, availableH)
        local p = Pad(self.spec.padding)
        local w = math.max(0, N(spec.width, 0)) or 0
        if w <= 0 then
            -- 内容最小值：每格至少 stepHeight 宽。
            w = self.count * self.stepHeight + self.gap * math.max(0, self.count - 1)
        end
        w = w + p.left + p.right
        local h = self.stepHeight + p.top + p.bottom
        if availableW ~= nil and self.spec.allowOverflow ~= true then w = math.min(w, math.max(0, N(availableW, w))) end
        if availableH ~= nil and self.spec.allowOverflow ~= true then h = math.min(h, math.max(0, N(availableH, h))) end
        self.desiredWidth, self.desiredHeight, self.measureDirty = w, h, false
        return w, h
    end

    function c:Layout(x, y, width, height)
        width, height = math.max(1, N(width, self.width or 1)), math.max(1, N(height, self.height or 1))
        self:SetBounds(x, y, width, height)
        local p = Pad(self.spec.padding)
        local iw = math.max(0, width - p.left - p.right)
        local ih = math.max(0, height - p.top - p.bottom)
        self.lastSteps = RSUI.StepsPolicy:Resolve(iw, self.gap, self.count, self.current)
        for i, entry in ipairs(VisibleEntries(self)) do
            local step = self.lastSteps[i]
            if step ~= nil then
                local dw, dh = Measure(entry.child, step.width, ih)
                local sx, sw = Align(p.left + step.x, step.width, dw, entry.slot.hAlign)
                local sy, sh = Align(p.top, ih, dh, entry.slot.vAlign)
                Arrange(entry.child, sx, sy, math.max(1, sw), math.max(1, sh))
                -- 仅选择接收的子节点获得状态；按前次状态比较，滚动/缩放/失效重复布局不重入。调用前标记，抛错 Consumer 不会每轮再试。
                if entry.child.rsUiStepState ~= step.state and type(entry.child.SetStepState) == "function" then
                    entry.child.rsUiStepState = step.state
                    pcall(entry.child.SetStepState, entry.child, step.state, i)
                end
            end
        end
        return height
    end
    return c
end)

------------------------------------------------------------------------
-- SplitToolbar 分区工具条。
--
-- 中部 spacer 可承载搜索框等 fill 组件，填左右按钮组间隙；分组复用 ToolbarPolicy:Partition，中部用 SplitViewPolicy 风格 min/fill，不再固定自动宽。
--
-- 窄窗无法满足两侧与 spacer 最小时，Resolve 保留 spacer 下限并返回 clamped=true，矩形可与右组重叠；
-- 这是明确降级信号，优于不可见零宽搜索框，调用方须计 RSUI.metrics.splitToolbarSpacerClamped。
------------------------------------------------------------------------
RSUI.SplitToolbarPolicy = RSUI.SplitToolbarPolicy or { version = 1 }
function RSUI.SplitToolbarPolicy:Resolve(innerWidth, gap, leftWidth, rightWidth, spacerMinWidth)
    innerWidth = math.max(0, tonumber(innerWidth) or 0)
    gap = math.max(0, tonumber(gap) or 0)
    leftWidth = math.max(0, tonumber(leftWidth) or 0)
    rightWidth = math.max(0, tonumber(rightWidth) or 0)
    spacerMinWidth = math.max(0, tonumber(spacerMinWidth) or 0)
    local gaps = (leftWidth > 0 and gap or 0) + (rightWidth > 0 and gap or 0)
    local spacerW = math.max(0, innerWidth - leftWidth - rightWidth - gaps)
    if spacerW < spacerMinWidth then
        -- 保留 spacer 最小值，让外容器暴露溢出，不能静默归零；clamped=true 表示矩形宽超可用空间并与右组重叠。
        spacerW = math.max(0, spacerMinWidth)
        return spacerW, true
    end
    return spacerW, false
end

RSUI:RegisterType("SplitToolbar", function(spec)
    local c, err = Host("SplitToolbar", spec)
    if c == nil then return nil, err end
    c.gap = math.max(0, N(spec.gap, Token("spacing.sm", 8)))
    c.spacerMinWidth = math.max(0, N(spec.spacerMinWidth, 40))

    function c:Measure(availableW, availableH)
        local p = Pad(self.spec.padding)
        local left, right, spacers = RSUI.ToolbarPolicy:Partition(VisibleEntries(self))
        local total = 0
        local count = 0
        for _, entry in ipairs(left) do total = total + Measure(entry.child, availableW, availableH); count = count + 1 end
        for _, entry in ipairs(right) do total = total + Measure(entry.child, availableW, availableH); count = count + 1 end
        for _, entry in ipairs(spacers) do total = total + math.max(self.spacerMinWidth, Measure(entry.child, availableW, availableH)); count = count + 1 end
        local w = total + (count > 1 and self.gap * (count - 1) or 0) + p.left + p.right
        local h = 0
        for _, entry in ipairs(VisibleEntries(self)) do h = math.max(h, select(2, Measure(entry.child, availableW, availableH))) end
        h = h + p.top + p.bottom
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
        local left, right, spacers = RSUI.ToolbarPolicy:Partition(VisibleEntries(self))
        -- 先固定右组并从右紧排。
        local rightUsed = 0
        for _, entry in ipairs(right) do
            local dw = Measure(entry.child, iw, ih)
            rightUsed = rightUsed + dw + self.gap
        end
        if #right > 0 then rightUsed = rightUsed - self.gap end
        local rightCursor = p.left + iw - rightUsed
        for _, entry in ipairs(right) do
            local dw, dh = Measure(entry.child, iw, ih)
            local rx, rw = Align(rightCursor, dw, dw, "left")
            local ry, rh = Align(p.top, ih, dh, entry.slot.vAlign)
            Arrange(entry.child, rx, ry, math.max(1, rw), math.max(1, rh))
            rightCursor = rightCursor + dw + self.gap
        end
        -- 左组从左紧排。
        local leftUsed = 0
        for _, entry in ipairs(left) do leftUsed = leftUsed + Measure(entry.child, iw, ih) + self.gap end
        local leftCursor = p.left
        for _, entry in ipairs(left) do
            local dw, dh = Measure(entry.child, iw, ih)
            local lx, lw2 = Align(leftCursor, dw, dw, "left")
            local ly, lh = Align(p.top, ih, dh, entry.slot.vAlign)
            Arrange(entry.child, lx, ly, math.max(1, lw2), math.max(1, lh))
            leftCursor = leftCursor + dw + self.gap
        end
        -- spacer 填中间余量，严格保留 >=spacerMinWidth。
        if #spacers > 0 then
            local spacer = spacers[1]
            local spacerW, clamped = RSUI.SplitToolbarPolicy:Resolve(iw, self.gap, leftUsed > 0 and leftUsed - self.gap or 0, rightUsed, self.spacerMinWidth)
            if clamped then
                -- 窄窗 spacer 保最小而与右组重叠，属于有意降级，须记录而不能静默。
                if type(RSUI.metrics) == "table" then RSUI.metrics.splitToolbarSpacerClamped = (tonumber(RSUI.metrics.splitToolbarSpacerClamped) or 0) + 1 end
            end
            local sx = p.left + (leftUsed > 0 and leftUsed or 0)
            local dw, dh = Measure(spacer.child, spacerW, ih)
            local sx2, sw = Align(sx, spacerW, dw, spacer.slot.hAlign)
            local sy, sh = Align(p.top, ih, dh, spacer.slot.vAlign)
            Arrange(spacer.child, sx2, sy, math.max(1, sw), math.max(1, sh))
        end
        return height
    end
    return c
end)

RSUI.LayoutTemplates = { version = 4, types = { "FormRow", "KeyValueRow", "Toolbar", "HeaderBodyFooter", "GroupBox", "CollapsibleGroup", "DetailRow", "Steps", "SplitToolbar" } }

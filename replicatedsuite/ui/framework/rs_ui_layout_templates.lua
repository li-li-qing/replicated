------------------------------------------------------------------------
-- Replicated Suite - RSUI Advanced Layout Templates v1
--
-- Composite layout templates built ON TOP of the existing UMG-like primitives
-- (HorizontalBox / VerticalBox / Border / SizeBox / Overlay). They do NOT invent
-- a second layout authority; every template reuses RSUI.LayoutUtil Measure /
-- Align / Arrange / Slot semantics and the existing component tree.
--
-- Design rules (see RSUI_ARCHITECTURE.md §7 / §8):
--   * Pure policy functions live beside each type so tiny-window and sequence
--     tests can exercise the math with zero Native side effects (SplitViewPolicy
--     precedent).
--   * Layout/event driven only: no Tick, no OnUpdate, no polling.
--   * Measure never writes Native layout; Layout writes only through the
--     existing Diff/Anchor authority.
--   * Narrow-window degradation is explicit (label shrink / ellipsis / column
--     collapse) and reported through RSUI.metrics, never hidden behind a clamp.
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
-- FormRow
--
-- label | control | (hint/feedback)  in a single logical row. The label has a
-- declared share of the row; on narrow rows it shrinks down to labelMinWidth
-- before the control is compressed, so a compact HUD never collapses the label
-- into the control.
------------------------------------------------------------------------
RSUI.FormRowPolicy = RSUI.FormRowPolicy or { version = 1 }
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
    -- If even the minimums cannot fit, drop the hint first, then let the label
    -- give up room to the control rather than producing negative extents.
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

RSUI:RegisterType("FormRow", function(spec)
    local c, err = Host("FormRow", spec)
    if c == nil then return nil, err end
    c.gap = math.max(0, N(spec.gap, Token("spacing.sm", 8)))
    c.labelShare = Clamp(N(spec.labelShare or spec.labelRatio, 0.35), 0, 1)
    c.labelMinWidth = math.max(0, N(spec.labelMinWidth, Token("component.form.labelW", 116)))
    c.controlMinWidth = math.max(0, N(spec.controlMinWidth, 60))
    c.hintWidth = math.max(0, N(spec.hintWidth, 0))
    c.vertical = tostring(spec.layout or spec.direction or "horizontal"):lower() == "vertical"

    function c:GetZones()
        return VisibleEntries(self)[1], VisibleEntries(self)[2], VisibleEntries(self)[3]
    end

    function c:Measure(availableW, availableH)
        local p = Pad(self.spec.padding)
        local label, control, hint = self:GetZones()
        local lw = label and Measure(label.child, availableW, availableH) or 0
        local cw = control and Measure(control.child, availableW, availableH) or 0
        local hw = hint and Measure(hint.child, availableW, availableH) or 0
        local w, h
        if self.vertical then
            w = math.max(lw, cw, hw) + p.left + p.right
            h = (label and lw + self.gap or 0) + (control and cw + self.gap or 0) + (hint and hw or 0) + p.top + p.bottom
        else
            w = lw + cw + hw + (label and control and self.gap or 0) + (hint and (control or label) and self.gap or 0) + p.left + p.right
            h = math.max(lw, cw, hw) + p.top + p.bottom
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
        if self.vertical then
            local cursor = p.top
            for _, entry in ipairs({ label, control, hint }) do
                if entry ~= nil and entry.child.visible ~= false then
                    local dw, dh = Measure(entry.child, iw, ih)
                    local ey = Align(cursor, ih, dh, entry.slot.vAlign)
                    Arrange(entry.child, p.left, ey, iw, math.max(1, dh))
                    cursor = cursor + dh + self.gap
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
-- KeyValueRow
--
-- label ................ value (right aligned). The value is measured first and
-- owns its fixed width; the label fills the remainder with ellipsis.
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
-- Toolbar
--
-- [left group] ..... [right group]. Children are divided by a `group` slot:
--   slot.group == "left"  (default) are packed from the left,
--   slot.group == "right" are packed from the right,
--   slot.group == "spacer" expands to fill the middle.
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
        -- Right group first (fixed), then left group, spacer fills the rest.
        local rightUsed = 0
        for _, entry in ipairs(right) do
            local dw = Measure(entry.child, iw, ih)
            rightUsed = rightUsed + dw + self.gap
        end
        if #right > 0 then rightUsed = rightUsed - self.gap end
        -- Toolbar items are auto-sized along the primary axis: each child owns
        -- exactly its measured width (a fill slot would otherwise stretch every
        -- button across the whole bar). Cross-axis height still honors vAlign.
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
-- HeaderBodyFooter
--
-- Canonical app-page stack: header (auto), body (fill), footer (auto). The
-- body is always the second child; header/footer are the first/third.
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
        -- Explicit two-value form on purpose: `local hw, hh = header and
        -- Measure(...) or 0, 0` parses as `hw = (header and Measure(...) or 0),
        -- hh = 0` (comma binds looser than `or`), which silently zeroes the
        -- zone height. Same trap as the CollapsibleGroup:Measure bug.
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
-- GroupBox
--
-- A titled box: header (title strip) + content + optional footer, all inside a
-- single Border surface. Unlike Section (legacy composite), this is composed
-- from Border + HeaderBodyFooter so it inherits the full Measure/Arrange path.
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
-- CollapsibleGroup
--
-- A GroupBox whose header is clickable to collapse/expand the content. It is
-- composed from the existing GroupBox surface (Border + title strip) plus a
-- small chevron indicator, so it inherits the full Measure/Arrange path while
-- adding exactly one new fact: an expanded flag (Presentation state, not
-- business truth). Collapsed content contributes zero height and is hidden, so
-- the group never leaves a ghost gap.
------------------------------------------------------------------------
RSUI.CollapsibleGroupPolicy = RSUI.CollapsibleGroupPolicy or { version = 1 }
RSUI.CollapsibleGroupInteractionContractVersion = 2
function RSUI.CollapsibleGroupPolicy:Resolve(innerHeight, headerH, gap, expanded)
    innerHeight = math.max(0, tonumber(innerHeight) or 0)
    headerH = math.max(0, tonumber(headerH) or 0)
    gap = math.max(0, tonumber(gap) or 0)
    local fixed = headerH
    if expanded ~= false then fixed = fixed + gap end
    -- Expanded: content fills the remainder (>= 0). Collapsed: zero content and
    -- no gap, so the group is exactly the header.
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

    -- Clickable header: the whole title strip is a native Button surface. RU
    -- input dispatches OnClick reliably to Button widgets, while EmptyWidget
    -- surfaces never fire OnClick on this client (see rs_ui_data_views.lua), so
    -- an empty-widget + SetOnClick hit target would leave collapse clicks
    -- silently dead. The Button is created under the title/chevron labels
    -- (labels are not pickable, so clicks fall through to it) and its themed
    -- backdrop is removed so the card keeps the GroupBox look; the chevron glyph
    -- carries the click affordance. It is a native child of the border, not a
    -- component, so it does not participate in Measure (laid out in Layout).
    local headerHit = UI:CreateButton(border, spec.id .. "_header_hit", "", 0, 0, math.max(1, N(spec.width, 1)), math.max(1, c.headerHeight), N(spec.titleFontSize, Token("font.section", 13)), false, false)
    if headerHit == nil or headerHit.rsUiDegraded == true then
        if type(RSUI.metrics) == "table" then RSUI.metrics.collapsibleHeaderUnavailable = (tonumber(RSUI.metrics.collapsibleHeaderUnavailable) or 0) + 1 end
        c.rsUiDegraded = true
        c.rsUiDegradedReason = "collapsible_header_create_failed"
        return c, c.rsUiDegradedReason
    end
    headerHit.rsUiOwner = c.owner
    -- Drop the themed button background (all four state drawables) so the
    -- strip stays visually identical to a GroupBox header.
    if type(S.Theme) == "table" and type(S.Theme.SetBackgroundOpacity) == "function" then
        pcall(function() S.Theme:SetBackgroundOpacity(headerHit, 0) end)
    end
    -- The header is the defining interaction of a CollapsibleGroup. Returning a
    -- rendered but inert group recreates the same "green diagnostics / dead UI"
    -- failure class as the old EditBox bug, so binding is now required and the
    -- normal component post-factory fence rejects the whole composite on failure.
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

    -- Chevron indicator: a small text glyph ("▾" expanded / "▸" collapsed).
    local chevron = UI:CreateLabel(border, spec.id .. "_chevron", c.expanded and "\226\150\190" or "\226\150\184", c.padding.left, 2, 12, c.headerHeight - 4, N(spec.chevronFontSize, Token("font.small", 10)), spec.tone or "muted", ALIGN_CENTER, true)
    if chevron ~= nil then chevron.rsUiOwner = c.owner end
    c.chevron = chevron

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
        -- `nextState`, not `next`: shadowing the global next() iterator would
        -- break any table walk running in this scope.
        local nextState = expanded ~= false
        if nextState == self.expanded then return false end
        self.expanded = nextState
        if self.chevron ~= nil then
            UI:SetText(self.chevron, nextState and "\226\150\190" or "\226\150\184", self.owner)
        end
        -- Collapsed content is hidden (viewport) so it contributes no layout and
        -- leaves no ghost gap; expanded re-shows it.
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
            -- Explicit two-value assignment. `local dw, dh = cond and Measure(...)
            -- or 0, 0` parses as `dw = (cond and Measure(...) or 0), dh = 0`: the
            -- comma has lower precedence than `or`, silently pinning dh to zero
            -- and dropping the content height from every expanded measurement.
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
-- DetailRow
--
-- A multi-column key/value row: a leading label followed by 1..N value columns,
-- each right-aligned within its own column. The policy divides the available
-- width so every column gets an equal share of the remainder after the label,
-- and the label keeps a declared share. Narrow windows shrink the label first.
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
        -- Columns must hold their minimum; shrink the label to make room (never
        -- below zero) rather than produce negative/overlapping extents.
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
            -- Only a label: fill the whole row.
            local dw, dh = Measure(label.child, iw, ih)
            local lx, lw2 = Align(p.left, iw, dw, label.slot.hAlign)
            local ly, lh = Align(p.top, ih, dh, label.slot.vAlign)
            Arrange(label.child, lx, ly, math.max(1, lw2), math.max(1, lh))
            return height
        end
        local labelW, columnW = RSUI.DetailRowPolicy:Resolve(iw, self.gap, self.labelShare, self.labelMinWidth, valueCount, self.columnMinWidth)
        -- Label fills its zone (left-aligned content via slot.hAlign).
        local dw, dh = Measure(label.child, labelW, ih)
        local lx, lw2 = Align(p.left, labelW, dw, label.slot.hAlign)
        local ly, lh = Align(p.top, ih, dh, label.slot.vAlign)
        Arrange(label.child, lx, ly, math.max(1, lw2), math.max(1, lh))
        -- Each value column is right-aligned within its equal-width column.
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
-- Steps
--
-- A horizontal step indicator (e.g. a wizard / multi-phase progress). Each step
-- owns an equal cell; the policy returns per-step geometry and a state enum
-- (done / active / pending) so the visual layer only needs to render three
-- tones. Pure math, no Native side effects.
--
-- State delivery: the template is a geometry container, it does not paint. A
-- step child opts into the semantic state by exposing
-- `SetStepState(state, index)`; Layout calls it (diffed: only when the state
-- actually changed) with "done" / "active" / "pending". Children without that
-- method are arranged by geometry alone and never touched, so a plain
-- label-only step stays a zero-coupling consumer.
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
        -- Last cell absorbs any sub-pixel remainder so the cells tile the whole
        -- width with no trailing gap.
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
            -- Content-driven minimum: count cells each at least stepHeight wide.
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
                -- Hand the semantic state to the child if it opts in. Diffed
                -- against the last delivered state so repeated layout passes
                -- (scroll, resize, invalidation storms) do not re-enter the
                -- consumer, and marked before the call so a throwing consumer
                -- is not retried on every pass.
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
-- SplitToolbar
--
-- A toolbar whose middle "spacer" region can host a fill component (e.g. a
-- search box) that stretches to consume the gap between the left and right
-- button groups. Reuses ToolbarPolicy:Partition for grouping, but the spacer
-- is now allocated by SplitViewPolicy-style min/fill semantics instead of a
-- fixed auto-width item.
--
-- Degradation contract: when the window is too narrow to honour both side
-- groups and the spacer minimum, Resolve keeps the spacer minimum (fail-closed)
-- and returns clamped = true. In that state the spacer rectangle overlaps the
-- right group — the overlap is a deliberate degradation signal (better a
-- visibly broken toolbar than an invisible 0-width search box), and the caller
-- must count it in RSUI.metrics.splitToolbarSpacerClamped.
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
        -- Fail-closed: preserve the spacer minimum and let the outer container
        -- expose overflow rather than silently collapsing the fill region to
        -- zero. clamped = true means the returned rectangle is wider than the
        -- room that actually exists, i.e. it overlaps the right group.
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
        -- Right group first (fixed, packed from the right).
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
        -- Left group packed from the left.
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
        -- Spacer fills the remaining middle (>= spacerMinWidth, fail-closed).
        if #spacers > 0 then
            local spacer = spacers[1]
            local spacerW, clamped = RSUI.SplitToolbarPolicy:Resolve(iw, self.gap, leftUsed > 0 and leftUsed - self.gap or 0, rightUsed, self.spacerMinWidth)
            if clamped then
                -- Narrow window: the spacer kept its minimum, so its rectangle
                -- overlaps the right group. That overlap is the intended
                -- degradation, counted here instead of passing silently.
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

RSUI.LayoutTemplates = { version = 3, types = { "FormRow", "KeyValueRow", "Toolbar", "HeaderBodyFooter", "GroupBox", "CollapsibleGroup", "DetailRow", "Steps", "SplitToolbar" } }

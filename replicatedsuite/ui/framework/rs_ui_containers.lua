------------------------------------------------------------------------
-- Replicated Suite - RSUI Container Components v1.1
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local UI, RSUI = S.UI, S.RSUI
if type(UI) ~= "table" or type(RSUI) ~= "table" then return end
local Tokens = S.UITokens or {}

local function Token(path, fallback)
    if type(Tokens.Number) == "function" then return Tokens:Number(path, fallback) end
    return tonumber(fallback) or 0
end


------------------------------------------------------------------------
-- ContainerSurface Authority v1
--
-- Card / Section are RSUI-owned presentation surfaces. This replaces the
-- retired UI.ComponentsV2 layer while preserving historical native root
-- identity suffixes (_card / _section) for upgrade-safe ownership.
------------------------------------------------------------------------
local ContainerSurface = RSUI.ContainerSurface or { version = 1 }
RSUI.ContainerSurface = ContainerSurface

function ContainerSurface:CreateCard(parent, id, spec)
    spec = type(spec) == "table" and spec or {}
    local width = math.max(1, tonumber(spec.width) or 260)
    local height = math.max(1, tonumber(spec.height) or 120)
    local panel = UI:CreatePanel(parent, tostring(id) .. "_card",
        tonumber(spec.x) or 0, tonumber(spec.y) or 0, width, height, "card",
        { gradient = spec.gradient ~= false, owner = spec.owner })
    if panel == nil then return nil, "card_create_failed" end
    panel.rsCardPadding = tonumber(spec.padding) or Token("component.card.padding", 10)
    return panel
end

function ContainerSurface:CreateSection(parent, id, spec)
    spec = type(spec) == "table" and spec or {}
    local width = math.max(1, tonumber(spec.width) or 300)
    local height = math.max(1, tonumber(spec.height) or 140)
    local headerH = math.max(1, tonumber(spec.headerHeight) or Token("size.sectionHeaderH", 28))
    local padding = math.max(0, tonumber(spec.padding) or Token("component.card.padding", 10))
    local root = UI:CreatePanel(parent, tostring(id) .. "_section",
        tonumber(spec.x) or 0, tonumber(spec.y) or 0, width, height, "card",
        { gradient = spec.gradient ~= false, owner = spec.owner })
    if root == nil then return nil, "section_root_create_failed" end
    local header = UI:CreatePanel(root, tostring(id) .. "_header", 0, 0, width, headerH, "header",
        { accentStrip = spec.accentStrip ~= false, owner = root.rsUiOwner })
    if header == nil then
        if type(UI.SetVisible) == "function" then UI:SetVisible(root, false, root.rsUiOwner) end
        return nil, "section_header_create_failed"
    end
    local title = UI:CreateLabel(header, tostring(id) .. "_title", tostring(spec.title or ""),
        padding, 2, math.max(1, width - padding * 2), math.max(1, headerH - 4),
        tonumber(spec.titleFontSize) or Token("font.section", 13), spec.tone or "default", ALIGN_LEFT, true)
    if title == nil then
        if type(UI.SetVisible) == "function" then UI:SetVisible(root, false, root.rsUiOwner) end
        return nil, "section_title_create_failed"
    end
    local section = {
        root = root, header = header, title = title, body = root,
        padding = padding, headerHeight = headerH, owner = root.rsUiOwner,
    }
    function section:SetTitle(text)
        return UI:SetText(self.title, tostring(text or ""), self.owner)
    end
    function section:ContentOrigin()
        return self.padding, self.headerHeight + self.padding
    end
    function section:SetExtent(nextWidth, nextHeight)
        nextWidth = math.max(1, tonumber(nextWidth) or width)
        nextHeight = math.max(1, tonumber(nextHeight) or height)
        UI:SetExtent(self.root, nextWidth, nextHeight, self.owner)
        UI:SetExtent(self.header, nextWidth, self.headerHeight, self.owner)
        UI:SetExtent(self.title, math.max(1, nextWidth - self.padding * 2), math.max(1, self.headerHeight - 4), self.owner)
        return true
    end
    return section
end

RSUI:RegisterType("Card", function(spec)
    local panel = ContainerSurface:CreateCard(spec.parent, spec.id, {
        x = tonumber(spec.x) or 0, y = tonumber(spec.y) or 0,
        width = math.max(1, tonumber(spec.width) or 260), height = math.max(1, tonumber(spec.height) or 120),
        padding = tonumber(spec.padding) or Token("component.card.padding", 10),
        gradient = spec.gradient,
    })
    if panel == nil then return nil, "card_create_failed" end
    local c = RSUI:NewComponent("Card", spec, panel)
    c.padding = panel.rsCardPadding or tonumber(spec.padding) or Token("component.card.padding", 10)
    function c:ContentOrigin() return self.padding, self.padding end
    function c:GetContentRoot() return self.root end
    return c
end)

RSUI:RegisterType("Section", function(spec)
    local raw = ContainerSurface:CreateSection(spec.parent, spec.id, {
        x = tonumber(spec.x) or 0, y = tonumber(spec.y) or 0,
        width = math.max(1, tonumber(spec.width) or 300), height = math.max(1, tonumber(spec.height) or 140),
        title = spec.title or "", titleFontSize = spec.titleFontSize,
        headerHeight = spec.headerHeight, padding = spec.padding,
        gradient = spec.gradient, accentStrip = spec.accentStrip, tone = spec.tone,
    })
    if raw == nil or raw.root == nil then return nil, "section_create_failed" end
    local c = RSUI:NewComponent("Section", spec, raw.root)
    c.raw, c.header, c.title, c.body = raw, raw.header, raw.title, raw.body
    c.padding, c.headerHeight = raw.padding, raw.headerHeight
    c.items = {}
    c.gap = tonumber(spec.gap) or Token("spacing.sm", 8)
    function c:SetTitle(text) return self.raw:SetTitle(text) end
    function c:ContentOrigin() return self.raw:ContentOrigin() end
    function c:GetContentRoot() return self.body or self.root end
    function c:Add(component)
        if type(component) == "table" then self.items[#self.items + 1] = component; self:AddChild(component) end
        return component
    end
    function c:LayoutItems(width, specLayout)
        specLayout = type(specLayout) == "table" and specLayout or {}
        local contentX, contentY = self:ContentOrigin()
        local available = math.max(1, (tonumber(width) or self.width or 300) - contentX * 2)
        local cursor = contentY
        for _, item in ipairs(self.items) do
            if type(item) == "table" and item.root ~= nil and item.visible ~= false then
                local h = tonumber(item.spec and item.spec.height) or tonumber(specLayout.itemHeight) or Token("size.controlH", 24)
                item:Layout(contentX, cursor, available, h)
                cursor = cursor + h + self.gap
            end
        end
        return math.max(contentY * 2, cursor - self.gap + (tonumber(self.padding) or 0))
    end
    function c:Layout(x, y, width, height)
        width = math.max(1, tonumber(width) or tonumber(spec.width) or 300)
        height = math.max(1, tonumber(height) or tonumber(spec.height) or 140)
        self.raw:SetExtent(width, height)
        UI:SetAnchor(self.root, self.parent, x or 0, y or 0, self.owner)
        self:CommitLayoutState(x or 0, y or 0, width, height)
        RSUI:_Count(self.kind, "layouts", 1)
        return true
    end
    return c
end)

RSUI:RegisterType("SettingsPage", function(spec)
    local parent = spec.parent
    local shell = nil
    if parent == nil then
        shell = UI:CreateWindowShell({
            id = spec.id,
            title = spec.title or spec.id,
            width = tonumber(spec.width) or 620,
            height = tonumber(spec.height) or 520,
            minWidth = tonumber(spec.minWidth) or 1,
            minHeight = tonumber(spec.minHeight) or 1,
            maxWidth = tonumber(spec.maxWidth),
            maxHeight = tonumber(spec.maxHeight),
            movable = spec.movable ~= false,
            resizable = spec.resizable ~= false,
            footer = spec.footer ~= false,
            status = spec.status or "",
            onClose = spec.onClose,
            onClosed = spec.onClosed,
            allowCloseVeto = spec.allowCloseVeto == true,
            defaultPlacement = spec.defaultPlacement,
        })
        if shell == nil then return nil, "settings_shell_create_failed" end
        parent = shell:GetContentRoot()
    end
    local root = UI:CreateEmptyWidget(parent, spec.id .. "_content", 0, 0, 10, 10, false)
    if root == nil then return nil, "settings_content_create_failed" end
    local pageSpec = {}
    for key, value in pairs(spec) do pageSpec[key] = value end
    pageSpec.parent = parent
    local c = RSUI:NewComponent("SettingsPage", pageSpec, root)
    c.shell, c.sections, c.forms, c.items = shell, {}, {}, {}
    c.padding = tonumber(spec.padding) or Token("component.window.padding", 12)
    c.gap = tonumber(spec.sectionGap) or Token("spacing.md", 12)
    c.layoutWidth, c.layoutHeight = 0, 0

    function c:GetContentRoot() return self.root end
    function c:SetStatus(text, tone) if self.shell ~= nil then return self.shell:SetStatus(text, tone) end return false end
    function c:AddSection(sectionSpec)
        sectionSpec = type(sectionSpec) == "table" and sectionSpec or {}
        local copy = {}
        for key, value in pairs(sectionSpec) do copy[key] = value end
        copy.parent = self
        copy.id = copy.id or (self.id .. "_section_" .. tostring(#self.sections + 1))
        local section = RSUI:Section(copy)
        if section ~= nil then
            self.sections[#self.sections + 1] = section
            self.items[#self.items + 1] = section
            self:AddChild(section)
        end
        return section
    end

    function c:AddForm(formSpec)
        formSpec = type(formSpec) == "table" and formSpec or {}
        local copy = {}
        for key, value in pairs(formSpec) do copy[key] = value end
        copy.parent = self
        copy.id = copy.id or (self.id .. "_form_" .. tostring(#self.forms + 1))
        local form = RSUI:Form(copy)
        if form ~= nil then
            self.forms[#self.forms + 1] = form
            self.items[#self.items + 1] = form
            self:AddChild(form)
        end
        return form
    end
    function c:Layout(x, y, nextWidth, nextHeight)
        -- Backwards compatibility: historical callers passed Layout(width,
        -- height). LayoutIfNeeded uses the standard Layout(x,y,w,h) contract.
        local width, height
        if nextWidth ~= nil or nextHeight ~= nil then
            width, height = nextWidth, nextHeight
        else
            width, height = x, y
            x, y = 0, 0
        end
        x, y = tonumber(x) or 0, tonumber(y) or 0
        if self.shell ~= nil then self.shell:Layout() end
        if width == nil or height == nil then
            if parent ~= nil and type(parent.GetWidth) == "function" then pcall(function() width = parent:GetWidth() end) end
            if parent ~= nil and type(parent.GetHeight) == "function" then pcall(function() height = parent:GetHeight() end) end
        end
        width, height = math.max(1, tonumber(width) or 560), math.max(1, tonumber(height) or 440)
        UI:SetAnchor(self.root, parent, x, y, self.owner)
        UI:SetExtent(self.root, width, height, self.owner)
        local contentW = math.max(1, width - self.padding * 2)
        local cursorY = self.padding
        local items = #self.items > 0 and self.items or self.sections
        for _, item in ipairs(items) do
            local desiredH = tonumber(item.spec and item.spec.height) or 140
            local used = type(item.Layout) == "function" and item:Layout(self.padding, cursorY, contentW, math.max(1, height - cursorY - self.padding)) or desiredH
            local actualH = type(used) == "number" and used or desiredH
            cursorY = cursorY + math.max(1, actualH) + self.gap
        end
        self.layoutWidth, self.layoutHeight = width, height
        self:CommitLayoutState(x, y, width, height)
        RSUI:_Count(self.kind, "layouts", 1)
        return math.max(0, cursorY - self.gap + self.padding)
    end
    function c:Show(visible)
        if self.shell ~= nil then return self.shell:Show(visible == true) end
        return self:SetVisible(visible)
    end
    function c:Close(reason)
        if self.shell ~= nil then return self.shell:Close(reason or "close") end
        return self:SetVisible(false)
    end
    local baseRelease = c.Release
    function c:Release()
        local released = baseRelease(self)
        if self.shell ~= nil then released = released + (tonumber(self.shell:Destroy()) or 0) end
        return released
    end

    for _, sectionSpec in ipairs(type(spec.sections) == "table" and spec.sections or {}) do c:AddSection(sectionSpec) end
    return c
end)

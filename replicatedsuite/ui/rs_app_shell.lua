------------------------------------------------------------------------
-- Replicated Suite - Main App Shell (M1)
--
-- Purpose:
--   * provide the new grouped ArcheAge-style navigation shell;
--   * keep legacy business pages alive behind a stable content host;
--   * move shell layout onto RSUI primitives without creating a second
--     business/data Authority;
--   * remain responsive through the shared S.Layout Authority.
--
-- This file is intentionally a Composite, not a new RSUI standard type. The
-- Foundation registry stays frozen; the shell composes Border / VerticalBox /
-- ScrollBox / Text / Button primitives already graduated in Phase 1-8.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI = S.RSUI
if type(RSUI) ~= "table" then return end

S.AppShell = {}
local A = S.AppShell

local catalog = S.UICatalog
local PAGE_META = catalog ~= nil and type(catalog.GetPageMeta) == "function" and catalog:GetPageMeta() or {}
local NAV_GROUPS = catalog ~= nil and type(catalog.GetNavGroups) == "function" and catalog:GetNavGroups() or {}

local function SafeNavigate(entry)
    if type(entry) ~= "table" then return false end
    if entry.kind == "page" then
        return S.UI ~= nil and type(S.UI.ShowPage) == "function" and S.UI:ShowPage(entry.page) == true
    end
    if entry.kind == "hud" then
        if S.UI ~= nil and type(S.UI.ToggleWidget) == "function" then
            S.UI:ToggleWidget(entry.hud)
            return true
        end
    end
    return false
end

local function AddNavButton(shell, parent, entry, scrollTarget)
    local spec = {
        id = "main_shell_nav_" .. tostring(entry.key), parent = parent,
        text = tostring(entry.text or entry.key), fontSize = 10, height = 26,
        selected = false, gradient = false,
        slot = { size = "fixed", height = 26, hAlign = "fill", padding = { left = 2, right = 2 } },
        onClick = function()
            if SafeNavigate(entry) then
                shell.lastAction = tostring(entry.key)
                if entry.kind == "hud" then shell:SetTransientStatus("已切换：" .. tostring(entry.text or entry.key)) end
            end
            return true
        end,
    }
    local component
    if S.Visual ~= nil and S.Visual.Nav ~= nil and type(S.Visual.Nav.CreateItem) == "function" then
        component = S.Visual.Nav:CreateItem(parent, spec.id, spec.text, spec.onClick, entry.iconKind or entry.icon)
        if component ~= nil then component.slot = spec.slot; component.spec.slot = spec.slot end
    else
        component = RSUI:Button(spec)
    end
    if component == nil then return nil end
    component.navEntry = entry
    shell.navEntries[#shell.navEntries + 1] = component
    if entry.kind == "page" then
        shell.pageEntries[#shell.pageEntries + 1] = {
            key = tostring(entry.page),
            text = tostring(entry.text),
            component = component,
            button = component.root,
            scrollTarget = scrollTarget or component,
        }
    end
    return component
end

function A.Create(window)
    if window == nil then return nil, "window_required" end

    local shell = {
        window = window,
        navEntries = {},
        pageEntries = {},
        pageMeta = PAGE_META,
        currentPage = "life",
        transientStatus = nil,
        dataClockText = "--:--:--",
    }

    -- Left application rail -------------------------------------------------
    shell.navFrame = RSUI:Border({
        id = "main_shell_nav_frame", parent = window,
        width = 204, height = 700, padding = 7, variant = "card", gradient = true,
    })
    if S.Visual ~= nil and S.Visual.Surface ~= nil then
        S.Visual.Surface:Apply(shell.navFrame.root, { surface = "sidebar", borderTone = "goldSoft", topAccent = true, accentHeight = 2, cornerCaps = true, cornerLength = 10, cornerThickness = 1 })
    end
    shell.navStack = RSUI:VerticalBox({ id = "main_shell_nav_stack", parent = shell.navFrame, gap = 5 })

    shell.brand = RSUI:Border({
        id = "main_shell_brand", parent = shell.navStack,
        height = 60, padding = { left = 8, right = 8, top = 5, bottom = 4 },
        variant = "header", gradient = true,
        slot = { size = "fixed", height = 60, hAlign = "fill" },
    })
    if S.Visual ~= nil and S.Visual.Surface ~= nil then
        S.Visual.Surface:Apply(shell.brand.root, { surface = "headerRaised", borderTone = "goldSoft", topAccent = true, accentHeight = 2, cornerCaps = true, cornerLength = 7 })
    end
    shell.brandRow = RSUI:HorizontalBox({ id = "main_shell_brand_row", parent = shell.brand, gap = 8 })
    shell.brandLogo = RSUI:Border({
        id = "main_shell_brand_logo", parent = shell.brandRow, width = 38, height = 38, padding = 2, variant = "soft", gradient = false,
        slot = { size = "fixed", width = 38, hAlign = "fill", vAlign = "center" },
    })
    if S.Visual ~= nil and S.Visual.Surface ~= nil then
        S.Visual.Surface:Apply(shell.brandLogo.root, { surface = "cardInset", borderTone = "gold", topAccent = false })
    end
    shell.brandLogoText = RSUI:Text({
        id = "main_shell_brand_logo_text", parent = shell.brandLogo, text = "A", tone = "brand", fontSize = 18, shadow = true, align = ALIGN_CENTER,
    })
    -- Tiny bounded emblem marks give the brand area an ArcheAge-like seal
    -- without relying on unverified texture paths. They are allocated once.
    if shell.brandLogo and shell.brandLogo.root and type(shell.brandLogo.root.CreateColorDrawable) == "function" then
        local gold = S.VisualTokens and S.VisualTokens:Color("goldSoft") or {0.7,0.5,0.2,0.5}
        local function mark(x,y,w,h)
            local d=shell.brandLogo.root:CreateColorDrawable(gold[1],gold[2],gold[3],gold[4] or 0.5,"artwork")
            if d then
                if d.SetExtent then d:SetExtent(w,h) end
                if d.AddAnchor then d:AddAnchor("TOPLEFT",shell.brandLogo.root,x,y) end
            end
        end
        mark(5,5,8,1); mark(5,5,1,8); mark(25,5,8,1); mark(32,5,1,8)
        mark(5,31,8,1); mark(5,24,1,8); mark(25,31,8,1); mark(32,24,1,8)
    end
    shell.brandStack = RSUI:VerticalBox({
        id = "main_shell_brand_stack", parent = shell.brandRow, gap = 1,
        slot = { size = "fill", fill = 1, minWidth = 80, hAlign = "fill" },
    })
    shell.brandTitle = RSUI:Text({
        id = "main_shell_brand_title", parent = shell.brandStack,
        text = "ArcheAge Suite", tone = "brand", fontSize = 15, shadow = true,
        overflow = "ellipsis", slot = { size = "fixed", height = 23, hAlign = "fill" },
    })
    shell.brandSubtitle = RSUI:Text({
        id = "main_shell_brand_subtitle", parent = shell.brandStack,
        text = "Replicated  ·  ArcheRage RU", tone = "muted", fontSize = 8,
        overflow = "ellipsis", slot = { size = "fixed", height = 16, hAlign = "fill" },
    })

    -- Unified navigation document ------------------------------------------
    -- Scroll at item granularity, never at whole-section granularity. The old
    -- section-as-one-child model could hide an entire Life/System group even
    -- when the viewport still had hundreds of unused pixels. Flattening the
    -- document keeps the rail visually continuous and remains reachable at the
    -- supported 600px minimum window height.
    shell.navScroll = RSUI:ScrollBox({
        id = "main_shell_nav_scroll", parent = shell.navStack,
        orientation = "vertical", gap = 1, scrollStep = 2,
        padding = { left = 2, right = 2, top = 1, bottom = 1 },
        slot = { size = "fill", fill = 1, minHeight = 120, hAlign = "fill" },
    })

    shell.navGroups = {}
    for groupIndex, group in ipairs(NAV_GROUPS) do
        local groupHeader = nil
        if S.Visual ~= nil and S.Visual.Nav ~= nil and type(S.Visual.Nav.CreateGroupHeader) == "function" then
            groupHeader = S.Visual.Nav:CreateGroupHeader(shell.navScroll, "main_shell_group_header_" .. tostring(groupIndex), tostring(group.title or ""))
        end
        if groupHeader == nil then
            groupHeader = RSUI:Text({
                id = "main_shell_group_" .. tostring(groupIndex), parent = shell.navScroll,
                text = tostring(group.title or ""), tone = "brand", fontSize = 9, shadow = true, overflow = "ellipsis",
                slot = { size = "fixed", height = 20, hAlign = "fill", padding = { left = 6, top = 1 } },
            })
        end
        shell.navGroups[groupIndex] = groupHeader
        if tostring(group.title or "") == "系统" then shell.systemNavGroup = groupHeader end
        for _, entry in ipairs(group.entries or {}) do AddNavButton(shell, shell.navScroll, entry, nil) end
        if groupIndex < #NAV_GROUPS then
            RSUI:Spacer({
                id = "main_shell_group_gap_" .. tostring(groupIndex), parent = shell.navScroll, height = 3,
                slot = { size = "fixed", height = 3, hAlign = "fill" },
            })
        end
    end

    shell.navFooter = RSUI:Border({
        id = "main_shell_nav_footer", parent = shell.navStack,
        height = 42, padding = { left = 8, right = 8, top = 3, bottom = 3 },
        variant = "soft", gradient = true,
        slot = { size = "fixed", height = 42, hAlign = "fill" },
    })
    if S.Visual ~= nil and S.Visual.Surface ~= nil then S.Visual.Surface:Apply(shell.navFooter.root, { surface = "cardInset", borderTone = "cyanDim", topAccent = false }) end
    shell.navFooterStack = RSUI:VerticalBox({ id = "main_shell_footer_stack", parent = shell.navFooter, gap = 1 })
    shell.footerStatus = RSUI:Text({
        id = "main_shell_footer_status", parent = shell.navFooterStack,
        text = "数据时间：--:--:--", tone = "muted", fontSize = 8,
        overflow = "ellipsis", slot = { size = "fixed", height = 16, hAlign = "fill" },
    })
    shell.footerVersion = RSUI:Text({
        id = "main_shell_footer_version", parent = shell.navFooterStack,
        text = "Replicated Suite v" .. tostring(S.Version or "--"), tone = "muted", fontSize = 8,
        overflow = "ellipsis", slot = { size = "fixed", height = 17, hAlign = "fill" },
    })

    -- Content-side title bar -----------------------------------------------
    shell.topFrame = RSUI:Border({
        id = "main_shell_top_frame", parent = window,
        width = 700, height = 34, padding = 0,
        variant = "header", gradient = true,
    })
    if S.Visual ~= nil and S.Visual.AppChrome ~= nil and type(S.Visual.AppChrome.DecorateFrame) == "function" then S.Visual.AppChrome:DecorateFrame(shell.topFrame.root) end
    -- These labels intentionally use the native top-frame root as their parent
    -- instead of becoming Border content; the right side is reserved for the
    -- main window chrome controls owned by rs_main_window.lua.
    shell.pageMarker = RSUI:Border({
        id = "main_shell_page_marker", parent = shell.topFrame.root, width = 3, height = 18, padding = 0,
        variant = "soft", gradient = false,
    })
    if shell.pageMarker and S.Visual and S.Visual.Surface then
        S.Visual.Surface:Apply(shell.pageMarker.root, { surface = "cyan", borderTone = "cyan", topAccent = false })
    end
    shell.pageGroup = RSUI:Text({
        id = "main_shell_page_group", parent = shell.topFrame.root,
        text = "首页", tone = "brand", fontSize = 9, overflow = "ellipsis",
    })
    shell.pageTitle = RSUI:Text({
        id = "main_shell_page_title", parent = shell.topFrame.root,
        text = PAGE_META.life.title, tone = "textStrong", fontSize = 14,
        overflow = "ellipsis", shadow = true,
    })

    -- Legacy Page Bridge ----------------------------------------------------
    -- Legacy pages still create their own roots and ApplyLayout() functions.
    -- The bridge is only their parent/viewport. It does not duplicate state,
    -- scan any X2 API, or own persistence.
    shell.contentFrame = RSUI:Border({
        id = "main_shell_content_frame", parent = window,
        width = 700, height = 600, padding = 0,
        variant = "soft", gradient = true,
    })
    if S.Visual ~= nil and S.Visual.Surface ~= nil then S.Visual.Surface:Apply(shell.contentFrame.root, { surface = "app", borderTone = "goldSoft", topAccent = false, cornerCaps = true, cornerLength = 10, cornerThickness = 1 }) end
    shell.contentHost = shell.contentFrame.root

    function shell:GetContentHost()
        return self.contentHost
    end

    function shell:GetTopBar()
        return self.topFrame and self.topFrame.root or nil
    end

    function shell:GetPageEntries()
        return self.pageEntries
    end

    function shell:SetDataClock(text)
        self.dataClockText = tostring(text or "--:--:--")
        if self.footerStatus ~= nil and (self.transientStatus == nil or self.transientStatus == "") then
            self.footerStatus:SetText("数据时间：" .. self.dataClockText)
        end
    end

    function shell:SetTransientStatus(text)
        self.transientStatus = tostring(text or "")
        if self.footerStatus ~= nil and self.transientStatus ~= "" then self.footerStatus:SetText(self.transientStatus) end
    end

    function shell:SetActivePage(pageKey)
        pageKey = tostring(pageKey or "life")
        self.currentPage = pageKey
        local meta = self.pageMeta[pageKey] or { group = "Replicated Suite", title = pageKey }
        if self.pageGroup ~= nil then self.pageGroup:SetText(tostring(meta.group or "") .. "  >") end
        if self.pageTitle ~= nil then self.pageTitle:SetText(tostring(meta.title or pageKey)) end
        self.transientStatus = nil
        if self.footerStatus ~= nil then self.footerStatus:SetText("数据时间：" .. tostring(self.dataClockText or "--:--:--")) end
        for _, item in ipairs(self.pageEntries) do
            if item.component ~= nil and type(item.component.SetSelected) == "function" then
                item.component:SetSelected(item.key == pageKey)
            end
        end
        -- If the selected page was reached through an old alias/hotlink, bring
        -- its real button into the ScrollBox viewport without changing data.
        if self.navScroll ~= nil then
            for _, item in ipairs(self.pageEntries) do
                if item.key == pageKey and item.component ~= nil then
                    self.navScroll:EnsureChildVisible(item.scrollTarget or item.component)
                    break
                end
            end
        end
        return true
    end

    function shell:SetCollapsed(collapsed)
        local visible = collapsed ~= true
        if self.navFrame ~= nil then self.navFrame:SetVisible(visible) end
        if self.contentFrame ~= nil then self.contentFrame:SetVisible(visible) end
        return visible
    end

    function shell:Layout(spec, collapsed)
        spec = type(spec) == "table" and spec or {}
        local width = math.max(1, tonumber(spec.width) or 900)
        local height = math.max(1, tonumber(spec.height) or 700)
        local margin = math.max(2, tonumber(spec.margin) or 8)
        local navWidth = math.max(120, tonumber(spec.navWidth) or 180)
        local navX = math.max(1, margin * 0.35)
        local navY = math.max(1, margin * 0.35)
        local navH = math.max(1, height - navY * 2)

        if collapsed == true then
            self:SetCollapsed(true)
            self.topFrame:LayoutIfNeeded(1, 1, math.max(1, width - 2), math.max(26, tonumber(spec.titleHeight) or 30))
            if self.pageMarker ~= nil then self.pageMarker:SetVisible(false) end
            self.pageGroup:SetVisible(false)
            self.pageTitle:SetVisible(false)
            return true
        end

        self:SetCollapsed(false)
        if self.pageMarker ~= nil then self.pageMarker:SetVisible(true) end
        self.pageGroup:SetVisible(true)
        self.pageTitle:SetVisible(true)
        self.navFrame:LayoutIfNeeded(navX, navY, navWidth, navH)

        -- Keep the Legacy Page Bridge on the exact S.Layout content rect. Old
        -- pages still receive the same spec, so their internal layout and the
        -- bridge viewport cannot drift by even a few pixels.
        local contentX = math.max(navX + navWidth + margin, tonumber(spec.contentX) or 0)
        local topY = navY
        local topH = math.max(30, tonumber(spec.titleHeight) or 34)
        local contentW = math.max(1, tonumber(spec.contentWidth) or (width - contentX - margin))
        local contentY = math.max(topY + topH, tonumber(spec.contentY) or (topY + topH + margin))
        local contentH = math.max(1, tonumber(spec.contentHeight) or (height - contentY - margin))

        self.topFrame:LayoutIfNeeded(contentX, topY, contentW, topH)
        local chromeReserve = math.min(contentW * 0.48, 360)
        local titleW = math.max(80, contentW - chromeReserve - 16)
        local groupW = math.min(104, math.max(64, titleW * 0.20))
        if self.pageMarker ~= nil then self.pageMarker:LayoutIfNeeded(12, math.max(5, (topH - 18) * 0.5), 3, 18) end
        self.pageGroup:LayoutIfNeeded(22, 4, groupW - 10, math.max(16, topH - 8))
        self.pageTitle:LayoutIfNeeded(16 + groupW, 3, math.max(60, titleW - groupW - 4), math.max(18, topH - 6))

        self.contentFrame:LayoutIfNeeded(contentX, contentY, contentW, contentH)
        return true
    end

    shell:SetActivePage("life")
    return shell
end

------------------------------------------------------------------------
-- Replicated Suite - Main window
-- Author: Replicated
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.MainWindow = {}
local M = S.MainWindow

local function Clamp(v, a, b)
    v = tonumber(v) or a
    if v < a then return a end
    if v > b then return b end
    return v
end

function M.Create()
    local window = CreateEmptyWindow(S.PhysicalId("main"), "UIParent")
    -- The large Suite shell intentionally stays on the normal UI layer.
    -- Detail/floating windows must be able to appear above it, and native
    -- game windows opened later should not be permanently covered by Suite.
    if window.Enable ~= nil then window:Enable(true) end
    if window.Clickable ~= nil then window:Clickable(true) end
    if window.UseResizing ~= nil then pcall(function() window:UseResizing(true) end) end
    -- Modern dark theme shell: vertical gradient body + soft border + top accent.
    S.Theme:AddBorder(window, false)
    S.Theme:AddGradientBackground(window, "panel", nil)
    S.Theme:AddAccentStrip(window, 2, nil)
    S.UI.windows.main = window

    local titleBar = S.UI:CreatePanel(window, "main_titlebar", 1, 1, 100, 30, "header", { gradient = true, accentStrip = 2 })
    local title = S.UI:CreateLabel(titleBar, "main_title", tostring(S.MainWindowTitle or "作者：Replicated     qq群：1104129461"), 12, 4, 300, 22, 17, nil, ALIGN_CENTER, true)
    local windowOpacity = S.UI:CreateButton(titleBar, "main_window_opacity", "窗90%", 0, 3, 50, 24, 9, false, true)
    local contentOpacity = S.UI:CreateButton(titleBar, "main_content_opacity", "底100%", 0, 3, 56, 24, 9, false, true)
    local refresh = S.UI:CreateButton(titleBar, "main_refresh", "刷", 0, 3, 28, 24, 10, false, true)
    local reloadCode = S.UI:CreateButton(titleBar, "main_reload_code", "载", 0, 3, 28, 24, 10, false, true)
    local lock = S.UI:CreateButton(titleBar, "main_lock", "动", 0, 3, 28, 24, 10, false, true)
    local minimize = S.UI:CreateButton(titleBar, "main_minimize", "-", 0, 3, 28, 24, 10, false, true)
    local close = S.UI:CreateButton(titleBar, "main_close", "X", 0, 3, 28, 24, 11, false, true)
    local resizeHandle = S.UI:CreateButton(window, "main_resize", "拖", 0, 0, 20, 20, 10, false, true)

    -- Shared hover tooltip for the single-character title-bar buttons.  These
    -- glyphs (刷/载/动/—/×) are ambiguous on their own, so a small owned panel
    -- explains each one on mouse-over.  It reuses the same pattern as the entry
    -- "R" tooltip: a Suite-owned panel parented to UIParent, no native tooltip
    -- API dependency, positioned from the hovered button's logical rect.
    local chromeTooltip = S.UI:CreatePanel("UIParent", "main_chrome_tooltip", 0, 0, 190, 24, "card")
    chromeTooltip:Show(false)
    local chromeTipLabel = S.UI:CreateLabel(chromeTooltip, "main_chrome_tip_text", "", 8, 4, 174, 18, 9, nil, ALIGN_LEFT)
    local function ShowChromeTip(anchor, text)
        if text == nil or text == "" then return end
        chromeTipLabel:SetText(text)
        local c = S.Layout:GetContext()
        local x, y, w = S.Layout:GetLogicalRect(anchor)
        local tw, th = 190 * c.addonScale, 24 * c.addonScale
        local tx = x + w + 6 * c.addonScale
        if tx + tw > c.logicalWidth - c.safeRight then tx = x - tw - 6 * c.addonScale end
        local ty = y
        tx, ty = S.Layout:ClampTopLeft(tx, ty, tw, th, { edge = c.safeLeft })
        chromeTooltip:RemoveAllAnchors()
        chromeTooltip:AddAnchor("TOPLEFT", "UIParent", tx, ty)
        chromeTooltip:SetExtent(tw, th)
        chromeTooltip:Show(true)
        if chromeTooltip.Raise ~= nil then pcall(function() chromeTooltip:Raise() end) end
    end
    local function HideChromeTip()
        chromeTooltip:Show(false)
    end
    local function BindChromeTip(button, text)
        S.UI:SafeHandler(button, "OnEnter", function() ShowChromeTip(button, text) end, "main:tip_enter")
        S.UI:SafeHandler(button, "OnLeave", function() HideChromeTip() end, "main:tip_leave")
    end
    BindChromeTip(windowOpacity, "整窗透明度：点击循环 100% → 35%")
    BindChromeTip(contentOpacity, "内容背景透明度：点击循环 100% → 0%，方便边调 HUD 边看角色")
    BindChromeTip(refresh, "刷新数据 / 界面（不重读文件）")
    BindChromeTip(reloadCode, "重载插件代码（重新读取磁盘文件）")
    BindChromeTip(lock, "切换主面板 锁定 / 可拖动")
    BindChromeTip(minimize, "折叠 / 展开主面板")
    BindChromeTip(close, "关闭主面板")

    local tabNames = {
        { key = "life", text = "首页" },
        { key = "team", text = "团队辅助" },
        { key = "dps", text = "伤害统计" },
        { key = "healer", text = "治疗辅助" },
        { key = "gear", text = "一键换装" },
        { key = "plates", text = "BUFF显示" },
        { key = "bagorganizer", text = "整理背包" },
        { key = "modules", text = "模块" },
        { key = "hud", text = "HUD" },
        { key = "quick", text = "快捷" },
        { key = "settings", text = "设置" },
        { key = "diagnostics", text = "诊断" },
    }
    local tabs = {}
    for index, def in ipairs(tabNames) do
        -- Active tab gets the golden gradient; inactive tabs keep the blue one.
        local button = S.UI:CreateButton(window, "main_tab_" .. def.key, def.text, 0, 0, 120, 30, 11, def.key == "life", true)
        tabs[index] = { key = def.key, text = def.text, button = button }
        S.UI:SafeHandler(button, "OnClick", function() S.UI:ShowPage(def.key) end, "main:tab:" .. def.key)
    end

    local contentHost = S.UI:CreatePanel(window, "main_content_host", 0, 0, 100, 100, "card", { gradient = true })

    local lifePage = S.LifePage.Create(contentHost)
    -- `activity` has been an alias of 首页 for several releases. Do not
    -- instantiate an unreachable legacy page (and its dead buttons) at runtime;
    -- UIX:ShowPage("activity") still redirects old saved links to `life`.
    local teamPage = S.TeamPage.Create(contentHost)
    local dpsPage = S.ProfessionalPages.CreateDps(contentHost)
    local healerPage = S.ProfessionalPages.CreateHealer(contentHost)
    local gearPage = S.ProfessionalPages.CreateGear(contentHost)
    local platesPage = S.ProfessionalPages.CreatePlates(contentHost)
    local bagOrganizerPage = S.BagOrganizerPage.Create(contentHost)
    local modulesPage = S.ModulesPage.Create(contentHost)
    local hudPage = S.HudPage.Create(contentHost)
    local quickPage = S.QuickPage.Create(contentHost)
    local settingsPage = S.SettingsPage.Create(contentHost)
    local diagnosticsPage = S.DiagnosticsPage.Create(contentHost)

    M.window, M.titleBar, M.title, M.contentHost = window, titleBar, title, contentHost
    M.windowOpacity, M.contentOpacity = windowOpacity, contentOpacity
    M.refresh, M.reloadCode, M.lock, M.minimize, M.close, M.resizeHandle = refresh, reloadCode, lock, minimize, close, resizeHandle
    M.chromeTooltip = chromeTooltip
    M.HideChromeTip = HideChromeTip
    M.tabs = tabs
    M.pages = { lifePage, teamPage, dpsPage, healerPage, gearPage, platesPage, bagOrganizerPage, modulesPage, hudPage, quickPage, settingsPage, diagnosticsPage }

    if type(titleBar.EnableDrag) == "function" then titleBar:EnableDrag(true) end
    if type(titleBar.Clickable) == "function" then titleBar:Clickable(true) end
    if type(resizeHandle.EnableDrag) == "function" then resizeHandle:EnableDrag(true) end

    S.UI:SafeHandler(titleBar, "OnDragStart", function()
        if S.State.settings.mainLocked == true then return false end
        -- Never move the responsive/resizable shell directly when the shared
        -- resolution-safe proxy is available.  Native StartMoving() can
        -- normalize anchors/min extents on 1024x768 and cause a first-frame jump.
        titleBar.rsSafeMoving = S.Layout ~= nil and type(S.Layout.BeginSafeMove) == "function"
            and S.Layout:BeginSafeMove("main_window", window, { clamp = true }) == true
        if titleBar.rsSafeMoving == true then return true end
        if type(window.StartMoving) ~= "function" then return false end
        if S.State.ui.main.collapsed == true and type(M.ApplyResizePolicy) == "function" then M:ApplyResizePolicy(true) end
        window:StartMoving(); return true
    end, "main:drag_start")
    S.UI:SafeHandler(titleBar, "OnDragStop", function()
        if titleBar.rsSafeMoving == true and S.Layout ~= nil and type(S.Layout.EndSafeMove) == "function" then
            S.Layout:EndSafeMove("main_window", false)
        elseif type(window.StopMovingOrSizing) == "function" then
            window:StopMovingOrSizing()
        end
        titleBar.rsSafeMoving = false
        -- Native fallback may still restore a stale standard minimum. Proxy drag
        -- never mutates the extent, but this compact fence is harmless there.
        if S.State.ui.main.collapsed == true then
            local spec = S.Layout:GetMainSpec()
            local context = S.Layout:GetContext()
            local compactW, compactH = M:ApplyResizePolicy(true, spec, context)
            if window.SetExtent ~= nil then pcall(function() window:SetExtent(compactW, compactH) end) end
        end
        S.Layout:SnapAndStore(S.State.ui.main, window)
        if S.State.ui.main.collapsed == true then M:ApplyLayout(false) end
        S.Storage:RequestSave(); return true
    end, "main:drag_stop")

    S.UI:SafeHandler(resizeHandle, "OnDragStart", function()
        if S.State.settings.mainLocked == true or S.State.ui.main.collapsed == true then return false end
        if type(window.StartSizing) ~= "function" then return false end
        window:StartSizing("BOTTOMRIGHT"); return true
    end, "main:resize_start")
    S.UI:SafeHandler(resizeHandle, "OnDragStop", function()
        if type(window.StopMovingOrSizing) == "function" then window:StopMovingOrSizing() end
        local context = S.Layout:GetContext()
        local _, _, w, h = S.Layout:GetLogicalRect(window)
        local minW = math.min((S.Constants.MainWindow.minWidth or 560) * context.addonScale, context.usableWidth)
        local minH = math.min((S.Constants.MainWindow.minHeight or 600) * context.addonScale, context.usableHeight)
        local maxW = math.min((S.Constants.MainWindow.maxWidth or 1180) * context.addonScale, context.usableWidth)
        local maxH = math.min((S.Constants.MainWindow.maxHeight or 900) * context.addonScale, context.usableHeight)
        w, h = Clamp(w, math.min(minW, maxW), maxW), Clamp(h, math.min(minH, maxH), maxH)
        S.State.ui.main.width = w / context.addonScale
        S.State.ui.main.height = h / context.addonScale
        S.Layout:SnapAndStore(S.State.ui.main, window)
        M:ApplyLayout(false)
        S.Storage:RequestSave(); return true
    end, "main:resize_stop")

    local function NextOpacity(list, current)
        current=tonumber(current) or list[1]
        local best=1;local diff=math.huge
        for i,v in ipairs(list) do local d=math.abs(v-current);if d<diff then best=i;diff=d end end
        return list[best % #list + 1]
    end
    S.UI:SafeHandler(windowOpacity, "OnClick", function()
        S.State.settings.opacity=NextOpacity({1.00,0.90,0.80,0.70,0.60,0.50,0.40,0.35},S.State.settings.opacity)
        M:ApplyLayout(false);S.Storage:RequestSave()
    end, "main:window_opacity")
    S.UI:SafeHandler(contentOpacity, "OnClick", function()
        S.State.settings.contentOpacity=NextOpacity({1.00,0.85,0.70,0.55,0.40,0.25,0.10,0.00},S.State.settings.contentOpacity)
        M:ApplyLayout(false);S.Storage:RequestSave()
    end, "main:content_opacity")

    S.UI:SafeHandler(refresh, "OnClick", function()
        if type(S.SafeSuiteRefresh) == "function" then S.SafeSuiteRefresh("title")
        elseif S.Runtime and S.Runtime.RefreshAll then S.Runtime:RefreshAll(true, true) end
    end, "main:refresh")
    S.UI:SafeHandler(reloadCode, "OnClick", function()
        if type(S.ReloadCodeFromDisk) == "function" then S.ReloadCodeFromDisk("title")
        else S.SafeChat("重载失败：代码重载入口不可用。") end
    end, "main:reload_code")
    S.UI:SafeHandler(lock, "OnClick", function()
        S.State.settings.mainLocked = not S.State.settings.mainLocked
        M:RefreshChrome(); M:ApplyLayout(false); S.Storage:RequestSave()
    end, "main:lock")

    S.UI:SafeHandler(minimize, "OnClick", function()
        if S.Dropdown and type(S.Dropdown.CloseAll) == "function" then S.Dropdown:CloseAll() end
        HideChromeTip()
        local nextCollapsed = not (S.State.ui.main.collapsed == true)
        if nextCollapsed and S.UI and type(S.UI.NotifyPagesHidden) == "function" then S.UI:NotifyPagesHidden(nil) end
        S.State.ui.main.collapsed = nextCollapsed
        M:ApplyLayout(false); S.Storage:RequestSave()
    end, "main:minimize")
    S.UI:SafeHandler(close, "OnClick", function()
        if S.Dropdown and type(S.Dropdown.CloseAll) == "function" then S.Dropdown:CloseAll() end
        HideChromeTip()
        if S.UI and type(S.UI.NotifyPagesHidden) == "function" then S.UI:NotifyPagesHidden(nil) end
        window:Show(false)
    end, "main:close")

    function M:RefreshChrome()
        self.lock:SetText(S.State.settings.mainLocked and "锁" or "动")
        self.minimize:SetText(S.State.ui.main.collapsed and "展" or "-")
        if self.windowOpacity then self.windowOpacity:SetText("窗"..tostring(math.floor((tonumber(S.State.settings.opacity) or 0.90)*100+0.5)).."%") end
        if self.contentOpacity then self.contentOpacity:SetText("底"..tostring(math.floor((tonumber(S.State.settings.contentOpacity) or 1.00)*100+0.5)).."%") end
    end

    function M:RefreshTabs()
        for _, tab in ipairs(self.tabs or {}) do
            local isActive = S.UI.currentPage == tab.key
            -- Selected tab gets a live gradient highlight; text keeps its plain
            -- label (the old "[...]" brackets are replaced by the visual state).
            if tab.button ~= nil then
                if isActive and tab.button:GetText() ~= tab.text then
                    tab.button:SetText(tab.text)
                end
                S.Theme:SetButtonActive(tab.button, isActive)
            end
        end
    end

    function M:ApplyResizePolicy(collapsed, spec, context)
        spec = spec or S.Layout:GetMainSpec()
        context = context or S.Layout:GetContext()
        local scale = context.addonScale
        if collapsed == true then
            local compactH = math.min((S.Constants.MainWindow.collapsedHeight or 32) * scale, context.usableHeight)
            local compactW = math.min(spec.width, context.usableWidth)
            -- Disable native resizing while collapsed.  Merely hiding the resize
            -- handle is insufficient: StartMoving() still consults stale native
            -- min/max extents in ArcheRage.
            if window.UseResizing ~= nil then pcall(function() window:UseResizing(false) end) end
            if window.SetMinResizingExtent ~= nil then pcall(function() window:SetMinResizingExtent(compactW, compactH) end) end
            if window.SetMaxResizingExtent ~= nil then pcall(function() window:SetMaxResizingExtent(compactW, compactH) end) end
            return compactW, compactH
        end

        local minW = math.min((S.Constants.MainWindow.minWidth or 560) * scale, context.usableWidth)
        local minH = math.min((S.Constants.MainWindow.minHeight or 600) * scale, context.usableHeight)
        local maxW = math.min((S.Constants.MainWindow.maxWidth or 1180) * scale, context.usableWidth)
        local maxH = math.min((S.Constants.MainWindow.maxHeight or 900) * scale, context.usableHeight)
        if window.UseResizing ~= nil then pcall(function() window:UseResizing(true) end) end
        if window.SetMinResizingExtent ~= nil then pcall(function() window:SetMinResizingExtent(minW, minH) end) end
        if window.SetMaxResizingExtent ~= nil then pcall(function() window:SetMaxResizingExtent(maxW, maxH) end) end
        return spec.width, spec.height
    end

    function M:ApplyLayout(fromMetricsChange)
        local spec = S.Layout:GetMainSpec()
        local collapsed = S.State.ui.main.collapsed == true
        local context = S.Layout:GetContext()
        local scale = context.addonScale
        local _, targetHeight = self:ApplyResizePolicy(collapsed, spec, context)
        targetHeight = collapsed and targetHeight or spec.height
        S.Layout:ApplyPlacement(window, S.State.ui.main, spec.width, targetHeight, 95, 105)

        titleBar:SetExtent(spec.width - 2, collapsed and math.max(28 * scale, targetHeight - 2) or spec.titleHeight)
        S.UI:SetAnchor(titleBar, window, 1, 1)
        title:SetExtent(math.max(120, spec.width - 330 * scale), math.max(22 * scale, spec.titleHeight - 6 * scale))
        S.UI:SetAnchor(title, titleBar, 12 * scale, 3 * scale)

        local buttonSize, buttonGap = 24 * scale, 2 * scale
        windowOpacity:Show(not collapsed);contentOpacity:Show(not collapsed)
        refresh:Show(not collapsed); reloadCode:Show(not collapsed); lock:Show(not collapsed); minimize:Show(true); close:Show(true)
        local chrome = collapsed and { close, minimize } or { close, minimize, lock, reloadCode, refresh }
        local controlX = spec.width - 4 * scale - buttonSize
        for _, button in ipairs(chrome) do
            button:SetExtent(buttonSize, buttonSize); S.UI:SetAnchor(button, titleBar, controlX, 3 * scale)
            controlX = controlX - buttonSize - buttonGap
        end
        if not collapsed then
            local contentW=56*scale;local windowW=50*scale
            local quickRight=controlX+buttonSize
            contentOpacity:SetExtent(contentW,buttonSize);S.UI:SetAnchor(contentOpacity,titleBar,quickRight-contentW,3*scale)
            quickRight=quickRight-contentW-buttonGap
            windowOpacity:SetExtent(windowW,buttonSize);S.UI:SetAnchor(windowOpacity,titleBar,quickRight-windowW,3*scale)
        end

        for _, tab in ipairs(tabs) do tab.button:Show(not collapsed) end
        for key, page in pairs(S.UI.pages or {}) do if page.root then page.root:Show(not collapsed and S.UI.currentPage == key) end end
        contentHost:Show(not collapsed)
        resizeHandle:Show(not collapsed)

        if not collapsed then
            S.UI:SetAnchor(contentHost, window, spec.contentX, spec.contentY)
            contentHost:SetExtent(spec.contentWidth, spec.contentHeight)
            local navX = spec.margin
            local navY = spec.titleHeight + spec.margin
            local navButtonH = math.max(28 * scale, math.min(36 * scale, spec.contentHeight / math.max(1, #tabs) - 3 * scale))
            for index, tab in ipairs(tabs) do
                tab.button:SetExtent(spec.navWidth, navButtonH)
                S.UI:SetAnchor(tab.button, window, navX, navY + (index - 1) * (navButtonH + 3 * scale))
            end
            local pageKeys={"life","team","dps","healer","gear","plates","bagorganizer","modules","hud","quick","settings","diagnostics"}
            for index, page in ipairs(self.pages) do
                if page.ApplyLayout then
                    local pageKey=page.key or pageKeys[index] or tostring(index)
                    local ok, err = xpcall(function() page:ApplyLayout(spec) end, S.SafeTraceback)
                    if not ok then
                        S.WarnOnce("main_apply_layout:"..tostring(pageKey), "页面布局异常 ["..tostring(pageKey).."]：" .. tostring(err))
                        if S.DiagnosticsManager and type(S.DiagnosticsManager.Record)=="function" then
                            S.DiagnosticsManager:Record("error","layout:"..tostring(pageKey),tostring(err))
                        end
                    end
                end
            end
            resizeHandle:SetExtent(20 * scale, 20 * scale)
            if resizeHandle.RemoveAllAnchors then resizeHandle:RemoveAllAnchors() end
            resizeHandle:AddAnchor("BOTTOMRIGHT", window, -2 * scale, -2 * scale)
            if resizeHandle.SetDrawPriority then pcall(function() resizeHandle:SetDrawPriority(10000) end) end
            if resizeHandle.Raise then pcall(function() resizeHandle:Raise() end) end

            if type(resizeHandle.EnableDrag) == "function" then resizeHandle:EnableDrag(not S.State.settings.mainLocked) end
        end

        S.Theme:SetOpacity(window, S.State.settings.opacity)
        S.Theme:SetBackgroundOpacity(contentHost, tonumber(S.State.settings.contentOpacity) or 1.0)
        self:RefreshChrome(); self:RefreshTabs()
        if window.CorrectOffsetByScreen then pcall(function() window:CorrectOffsetByScreen() end) end
    end

    M:ApplyLayout(false)
    local startPage = tostring(S.State.settings.defaultStartPage or "life")
    if startPage == "last" then startPage = tostring(S.State.product and S.State.product.lastPage or "life") end
    if startPage == "combat" then startPage = "dps" end
    if startPage == "activity" then startPage = "life" end
    -- Compatibility: the removed Target Inspector page now resolves to the existing BUFF tracking UI.
    if startPage == "target" then startPage = "plates" end
    if S.UI.pages[startPage] == nil then startPage = "life" end
    S.UI:ShowPage(startPage)
    window:Show(false)
    if S.Layout~=nil and type(S.Layout.RegisterFloating)=="function" then
        S.Layout:RegisterFloating("suite_main_window",window,{
            onlyWhenVisible=true, ensureNow=false,
            onMetricsChanged=function() M:ApplyLayout(true) end,
        })
    end
    return window
end

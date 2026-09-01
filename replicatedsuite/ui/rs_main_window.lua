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
    if S.Visual ~= nil and S.Visual.Surface ~= nil then S.Visual.Surface:Apply(window, { surface = "app", borderTone = "goldSoft", topAccent = true, accentHeight = 2 }) end
    S.UI.windows.main = window

    -- M1 App Shell is a presentation Composite built from the frozen RSUI
    -- Foundation. It owns only shell/navigation geometry; legacy pages remain
    -- the business/persistence Authority behind its content host.
    local appShell, shellErr = S.AppShell.Create(window)
    if appShell == nil then
        error("Replicated Suite App Shell 创建失败：" .. tostring(shellErr or "unknown"))
    end
    local titleBar = appShell:GetTopBar()
    local title = appShell.pageTitle and appShell.pageTitle.root or nil
    local contentHost = appShell:GetContentHost()

    local windowOpacity = S.UI:CreateButton(titleBar, "main_window_opacity", "窗90%", 0, 3, 50, 24, 9, false, true)
    local contentOpacity = S.UI:CreateButton(titleBar, "main_content_opacity", "底100%", 0, 3, 56, 24, 9, false, true)
    local refresh = S.UI:CreateButton(titleBar, "main_refresh", "↻", 0, 3, 28, 24, 11, false, false)
    local reloadCode = S.UI:CreateButton(titleBar, "main_reload_code", "重载", 0, 3, 44, 24, 9, false, false)
    local lock = S.UI:CreateButton(titleBar, "main_lock", "◇", 0, 3, 28, 24, 11, false, false)
    local minimize = S.UI:CreateButton(titleBar, "main_minimize", "—", 0, 3, 28, 24, 11, false, false)
    local close = S.UI:CreateButton(titleBar, "main_close", "×", 0, 3, 28, 24, 12, false, false)
    local resizeHandle = S.UI:CreateButton(window, "main_resize", "↘", 0, 0, 20, 20, 10, false, false)
    if S.Visual ~= nil and S.Visual.AppChrome ~= nil and type(S.Visual.AppChrome.StyleNativeButton) == "function" then
        for _, button in ipairs({ refresh, reloadCode, lock, minimize, resizeHandle }) do S.Visual.AppChrome:StyleNativeButton(button, "chrome") end
        S.Visual.AppChrome:StyleNativeButton(close, "danger")
    end

    -- Shared hover tooltip for the compact title-bar controls. The visual
    -- shell keeps them terse; the owned tooltip preserves discoverability.
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

    local tabs = appShell:GetPageEntries()

    -- M2 replaces only the home presentation. The legacy LifePage file stays
    -- loaded as a rollback bridge; business Authorities remain unchanged.
    local lifePage
    if S.DashboardPage ~= nil and type(S.DashboardPage.Create) == "function" then
        local ok, result = xpcall(function() return S.DashboardPage.Create(contentHost) end, S.SafeTraceback)
        if ok then
            lifePage = result
        else
            S.WarnOnce("dashboard_m2_create", "M2 首页创建失败，已回退旧首页：" .. tostring(result))
        end
    end
    if lifePage == nil then lifePage = S.LifePage.Create(contentHost) end

    -- M3 Life workspaces are presentation-only pages layered on the same
    -- Quest/Event/Trade/Resident/Treasure/Fishing Authorities. A failed page
    -- must not take the whole Suite shell down; successful siblings remain
    -- registered and the dashboard continues to be a safe home.
    local lifeWorkspaces = {}
    if S.LifeWorkspace ~= nil and type(S.LifeWorkspace.CreateAll) == "function" then
        local ok, result = xpcall(function() return S.LifeWorkspace.CreateAll(contentHost) end, S.SafeTraceback)
        if ok and type(result) == "table" then
            lifeWorkspaces = result
        else
            S.WarnOnce("life_workspace_m3_create", "M3 生活工作区创建异常，首页与旧功能仍可使用：" .. tostring(result))
        end
    end
    -- `activity` has been an alias of 首页 for several releases. Do not
    -- instantiate an unreachable legacy page (and its dead buttons) at runtime;
    -- UIX:ShowPage("activity") still redirects old saved links to `life`.
    -- M5 keeps the mature professional editors alive as the "高级设置"
    -- surface, then wraps them with RSUI combat overviews.  The wrapper is a
    -- Presentation Proxy only; every Domain/persistence Authority remains in
    -- TeamUtility / DPS / Healer / Gear / Plates.  If the M5 composite fails,
    -- these already-created legacy pages remain the safe runtime fallback.
    local legacyCombat = {
        team = S.TeamPage.Create(contentHost),
        dps = S.ProfessionalPages.CreateDps(contentHost),
        healer = S.ProfessionalPages.CreateHealer(contentHost),
        gear = S.ProfessionalPages.CreateGear(contentHost),
        plates = S.ProfessionalPages.CreatePlates(contentHost),
    }
    local combatPages = nil
    if S.CombatWorkspace ~= nil and type(S.CombatWorkspace.CreateAll) == "function" then
        local ok, result = xpcall(function() return S.CombatWorkspace.CreateAll(contentHost, legacyCombat) end, S.SafeTraceback)
        if ok and type(result) == "table" then
            combatPages = result
        else
            S.WarnOnce("combat_workspace_m5_create", "M5 战斗工作区创建异常，已回退旧专业页面：" .. tostring(result))
        end
    end
    local teamPage = combatPages and combatPages.team or legacyCombat.team
    local dpsPage = combatPages and combatPages.dps or legacyCombat.dps
    local healerPage = combatPages and combatPages.healer or legacyCombat.healer
    local gearPage = combatPages and combatPages.gear or legacyCombat.gear
    local platesPage = combatPages and combatPages.plates or legacyCombat.plates
    local bagOrganizerPage = S.BagOrganizerPage.Create(contentHost)
    local modulesPage = S.ModulesPage.Create(contentHost)
    local hudPage = S.HudPage.Create(contentHost)
    local quickPage = S.QuickPage.Create(contentHost)
    local settingsPage = S.SettingsPage.Create(contentHost)
    local diagnosticsPage = S.DiagnosticsPage.Create(contentHost)

    M.window, M.titleBar, M.title, M.contentHost = window, titleBar, title, contentHost
    M.appShell = appShell
    M.windowOpacity, M.contentOpacity = windowOpacity, contentOpacity
    M.refresh, M.reloadCode, M.lock, M.minimize, M.close, M.resizeHandle = refresh, reloadCode, lock, minimize, close, resizeHandle
    M.chromeTooltip = chromeTooltip
    M.HideChromeTip = HideChromeTip
    M.tabs = tabs
    M.pages = { lifePage }
    for _, workspacePage in ipairs(lifeWorkspaces) do M.pages[#M.pages + 1] = workspacePage end
    for _, page in ipairs({ teamPage, dpsPage, healerPage, gearPage, platesPage, bagOrganizerPage, modulesPage, hudPage, quickPage, settingsPage, diagnosticsPage }) do
        M.pages[#M.pages + 1] = page
    end

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
        self.lock:SetText(S.State.settings.mainLocked and "◆" or "◇")
        self.minimize:SetText(S.State.ui.main.collapsed and "□" or "—")
        if self.windowOpacity then self.windowOpacity:SetText("窗"..tostring(math.floor((tonumber(S.State.settings.opacity) or 0.90)*100+0.5)).."%") end
        if self.contentOpacity then self.contentOpacity:SetText("底"..tostring(math.floor((tonumber(S.State.settings.contentOpacity) or 1.00)*100+0.5)).."%") end
    end

    function M:RefreshTabs()
        -- The new App Shell is the sole navigation presentation Authority. Page
        -- switching itself still belongs to UIX:ShowPage, preserving all old
        -- aliases, persistence and page-hidden callbacks.
        if self.appShell ~= nil and type(self.appShell.SetActivePage) == "function" then
            self.appShell:SetActivePage(S.UI.currentPage)
            return
        end
        for _, tab in ipairs(self.tabs or {}) do
            local isActive = S.UI.currentPage == tab.key
            if tab.button ~= nil then S.Theme:SetButtonActive(tab.button, isActive) end
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

        if self.appShell ~= nil and type(self.appShell.Layout) == "function" then
            self.appShell:Layout(spec, collapsed)
        end

        local buttonSize, buttonGap = 24 * scale, 2 * scale
        -- M6-v7 reload hotfix: code reload is a core in-game developer/user
        -- workflow and must remain directly reachable from the main chrome.
        -- The previous Unicode-arrow control was hidden because RU fonts did not
        -- render it reliably; restore the action as an explicit text button
        -- instead of forcing the player to relog or hunt through Settings.
        refresh:Show(false); reloadCode:Show(not collapsed); lock:Show(not collapsed); minimize:Show(true); close:Show(true)
        local chrome = collapsed and { { button = close, width = buttonSize }, { button = minimize, width = buttonSize } } or {
            { button = close, width = buttonSize },
            { button = minimize, width = buttonSize },
            { button = lock, width = buttonSize },
            { button = reloadCode, width = 44 * scale },
        }
        local topBarWidth = spec.contentWidth
        if titleBar ~= nil and type(titleBar.GetWidth) == "function" then
            local ok, value = pcall(function() return titleBar:GetWidth() end)
            if ok and tonumber(value) ~= nil then topBarWidth = tonumber(value) end
        end
        local controlRight = math.max(buttonSize, topBarWidth - 4 * scale)
        for _, item in ipairs(chrome) do
            local button = item.button
            local width = item.width or buttonSize
            controlRight = controlRight - width
            button:SetExtent(width, buttonSize); S.UI:SetAnchor(button, titleBar, controlRight, 3 * scale)
            controlRight = controlRight - buttonGap
        end
        local controlX = controlRight
        -- At narrow user-sized widths the two textual opacity shortcuts would
        -- collide with the page title. Their full controls remain available in
        -- Settings, so the shell collapses only these redundant chrome items.
        -- M6-v2 visual parity: opacity is a Settings/HUD-manager concern, not
        -- permanent title-bar chrome. Hiding these textual shortcuts removes the
        -- "窗90% / 底100%" debug-console look and frees the title bar for the
        -- compact ArcheAge-style controls.
        local showOpacityChrome = false
        windowOpacity:Show(showOpacityChrome); contentOpacity:Show(showOpacityChrome)
        if showOpacityChrome then
            local contentW=56*scale;local windowW=50*scale
            local quickRight=controlX+buttonSize
            contentOpacity:SetExtent(contentW,buttonSize);S.UI:SetAnchor(contentOpacity,titleBar,quickRight-contentW,3*scale)
            quickRight=quickRight-contentW-buttonGap
            windowOpacity:SetExtent(windowW,buttonSize);S.UI:SetAnchor(windowOpacity,titleBar,quickRight-windowW,3*scale)
        end

        for key, page in pairs(S.UI.pages or {}) do if page.root then page.root:Show(not collapsed and S.UI.currentPage == key) end end
        resizeHandle:Show(not collapsed)

        if not collapsed then
            -- M6: only the visible page participates in this outer layout pass.
            -- Hidden M1-M5 workspaces are solved lazily by UIX:ShowPage through
            -- EnsurePageLayout(), so resizing / changing UI scale no longer
            -- traverses every professional editor and virtual view at once.
            if S.UI ~= nil and type(S.UI.EnsurePageLayout) == "function" then
                S.UI:EnsurePageLayout(S.UI.currentPage, fromMetricsChange == true, spec)
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
        -- ApplyPlacement already resolves the saved edge anchor against the
        -- current safe logical viewport. Calling native CorrectOffsetByScreen()
        -- afterwards can rewrite/normalize anchors in ArcheRage and makes the
        -- next responsive pass pull the window back again (visible as a jump on
        -- 1024x768). Keep one placement Authority and do not post-correct it.
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

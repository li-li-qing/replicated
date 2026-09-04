------------------------------------------------------------------------
-- Replicated Suite V3 - Application Shell
--
-- The V3 shell is the only active application window. It owns chrome,
-- navigation, PageHost/ModalHost and responsive geometry only. All top-level
-- movement/resizing is delegated to the shared RSUI Windowing foundation.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local UI, RSUI, Adapter = S.UI, S.RSUI, S.UIV3NativeAdapter
local Router = S.UIV3 and S.UIV3.Router or nil
local PageHost = S.UIV3 and S.UIV3.PageHost or nil
local ModalHost = S.UIV3 and S.UIV3.ModalHost or nil
local ToastHost = S.UIV3 and S.UIV3.ToastHost or nil
local Windowing = RSUI and RSUI.Windowing or nil
if type(UI) ~= "table" or type(RSUI) ~= "table" or type(Adapter) ~= "table"
    or type(Router) ~= "table" or type(PageHost) ~= "table" or type(Windowing) ~= "table"
    or type(ModalHost) ~= "table" or type(ToastHost) ~= "table" then return end

S.UIV3 = S.UIV3 or {}
local V3 = S.UIV3
V3.Shell = V3.Shell or {
    owner = "v3:shell",
    logicalId = "v3_shell_root",
    created = false,
    window = nil,
    root = nil,
    background = nil,
    appStack = nil,
    topBar = nil,
    body = nil,
    navFrame = nil,
    navColumn = nil,
    navScroll = nil,
    navStack = nil,
    navPager = nil,
    systemFrame = nil,
    contentFrame = nil,
    contentRoot = nil,
    footer = nil,
    status = nil,
    minimizeButton = nil,
    reloadButton = nil,
    navButtons = {},
    lastRect = nil,
    lastRoute = nil,
    windowController = nil,
    failedBuildGeneration = nil,
    failedBuildError = nil,
    buildQuarantinedRejects = 0,
}
local Shell = V3.Shell
Shell.navigationCallbackContractVersion = 1
Shell.NavigationCallbackCaptureContractVersion = 1
Shell.StateMutationTransactionContractVersion = 1

local SCROLL_CATEGORY_ORDER = { "home", "combat", "life", "tools" }
local SYSTEM_ROUTES = { "system.widgets", "system.features", "system.settings", "system.diagnostics" }

local function SetButtonSelected(button, selected)
    if button ~= nil and type(button.SetSelected) == "function" then button:SetSelected(selected == true) end
end

local function MarkDirty(reason)
    if type(V3.MarkShellStoreDirty) == "function" then V3:MarkShellStoreDirty(350, reason or "shell_changed") end
end

function Shell:ResolveRect(designWidth, designHeight)
    local context = S.Layout:GetContext()
    local scale = math.max(0.01, tonumber(context.addonScale) or 1)
    local state = V3.ShellState or {}
    local size = V3.ShellSizePolicy or { defaultWidth = 1040, defaultHeight = 700, minWidth = 1, minHeight = 1 }
    local dw = math.max(size.minWidth, tonumber(designWidth) or tonumber(state.width) or size.defaultWidth)
    local normalDh = math.max(size.minHeight, tonumber(designHeight) or tonumber(state.height) or size.defaultHeight)
    local width = dw * scale
    local height = normalDh * scale
    local centerX = ((tonumber(context.logicalWidth) or width) - width) * 0.5
    local centerY = ((tonumber(context.logicalHeight) or height) - height) * 0.5
    local x, y
    if state.userMoved == true and S.Layout ~= nil and type(S.Layout.ResolvePlacement) == "function" then
        x, y = S.Layout:ResolvePlacement(state, width, height, centerX, centerY, { mode = "free" })
    else
        x, y = centerX, centerY
        -- Keep a fresh/default title bar recoverable even when the chosen size is
        -- larger than the current viewport; never shrink the requested size.
        if S.Layout ~= nil and type(S.Layout.ClampRecoverableTopLeft) == "function" then
            x, y = S.Layout:ClampRecoverableTopLeft(x, y, width, height, { visibleX = 72, visibleY = 18, topReachHeight = 50 })
        end
    end
    return x, y, width, height, dw, normalDh
end

function Shell:SetStatus(text, tone)
    if self.status ~= nil then
        self.status:SetText(tostring(text or ""))
        if tone ~= nil and type(self.status.SetTone) == "function" then self.status:SetTone(tone) end
    end
end

function Shell:RefreshNavScrollHint()
    if self.navScroll == nil or self.navScrollHint == nil then return false end
    local entries = self.navScroll:GetScrollableEntries()
    local total = #entries
    local first = math.max(1, tonumber(self.navScroll.visibleStart) or 1)
    local last = math.max(0, tonumber(self.navScroll.visibleEnd) or 0)
    if total == 0 then first, last = 0, 0 end
    self.navScrollHint:SetText(tostring(first) .. "-" .. tostring(last) .. " / " .. tostring(total))
    if self.navUp ~= nil then self.navUp:SetEnabled(self.navScroll.canScrollBackward == true) end
    if self.navDown ~= nil then self.navDown:SetEnabled(self.navScroll.canScrollForward == true) end
    return true
end

function Shell:BuildScrollableNavigation()
    if self.navScroll == nil then return false end
    local navParent = self.navScroll
    for _, categoryId in ipairs(SCROLL_CATEGORY_ORDER) do
        local category = S.FeatureRegistry and S.FeatureRegistry.categories[categoryId] or nil
        local routes = Router:List(categoryId)
        if category ~= nil and #routes > 0 then
            RSUI:Text({
                id = "v3_nav_category_" .. categoryId, parent = navParent,
                text = category.name, fontSize = 10, tone = "muted", overflow = "ellipsis",
                slot = { size = "fixed", height = 22, hAlign = "fill" },
            })
            local previousGroup = nil
            local groupGapIndex = 0
            for _, route in ipairs(routes) do
                -- Navigation callbacks execute long after this Lua 5.1 generic
                -- loop finishes; capture the concrete route for each button.
                local routeRef = route
                local group = tostring(routeRef.group or categoryId)
                if previousGroup ~= nil and group ~= previousGroup then
                    groupGapIndex = groupGapIndex + 1
                    RSUI:Spacer({
                        id = "v3_nav_group_gap_" .. categoryId .. "_" .. tostring(groupGapIndex),
                        parent = navParent, height = 4, slot = { size = "fixed", height = 4 },
                    })
                end
                local button = RSUI:Button({
                    id = "v3_nav_" .. routeRef.id:gsub("[^%w]", "_"),
                    parent = navParent,
                    text = routeRef.title,
                    compact = true,
                    onClick = function() return self:Navigate(routeRef.id, { source = "navigation" }) end,
                    slot = { size = "fixed", height = 28, hAlign = "fill" },
                })
                self.navButtons[routeRef.id] = button
                previousGroup = group
            end
            RSUI:Spacer({ id = "v3_nav_gap_" .. categoryId, parent = navParent, height = 5, slot = { size = "fixed", height = 5 } })
        end
    end
    return true
end

function Shell:BuildSystemNavigation()
    if self.systemFrame == nil then return false end
    local stack = RSUI:VerticalBox({ id = "v3_nav_system_stack", parent = self.systemFrame, gap = 3 })
    RSUI:Text({ id = "v3_nav_system_title", parent = stack, text = "系统", fontSize = 10, tone = "muted", overflow = "ellipsis", slot = { size = "fixed", height = 20, hAlign = "fill" } })
    for _, routeId in ipairs(SYSTEM_ROUTES) do
        local route = Router:Get(routeId)
        if route ~= nil then
            local routeRef = route
            local button = RSUI:Button({
                id = "v3_nav_" .. routeRef.id:gsub("[^%w]", "_"), parent = stack, text = routeRef.title, compact = true,
                onClick = function() return self:Navigate(routeRef.id, { source = "system_navigation" }) end,
                slot = { size = "fixed", height = 27, hAlign = "fill" },
            })
            self.navButtons[routeRef.id] = button
        end
    end
    self.reloadButton = RSUI:Button({
        id = "v3_nav_reload", parent = stack, text = "重新加载文件", compact = true,
        onClick = function()
            if type(S.ReloadCodeFromDisk) ~= "function" then return false end
            return S.ReloadCodeFromDisk("v3_navigation")
        end,
        slot = { size = "fixed", height = 27, hAlign = "fill" },
    })
    return true
end

local function EnsureComponentVisibility(component, visibility, label)
    if component == nil then return true, nil end
    if type(component.SetVisibility) ~= "function" then return false, tostring(label or "component") .. "_visibility_contract_missing" end
    local _, accepted, detail = component:SetVisibility(visibility)
    if accepted ~= true then return false, detail or (tostring(label or "component") .. "_visibility_rejected") end
    return true, nil
end

function Shell:ApplyMinimizedState(persist)
    local state = V3.ShellState or {}
    local minimized = state.minimized == true
    -- The main application minimizes back to the persistent R launcher. It no
    -- longer compresses into a title-only strip, which was visually ambiguous
    -- and consumed screen space without providing useful content. Every Native
    -- or Component state transition must be accepted before this projection is
    -- considered applied; callers own the ShellState transaction itself.
    local bodyOk, bodyErr = EnsureComponentVisibility(self.body, "visible", "shell_body")
    if bodyOk ~= true then return false, bodyErr end
    local footerOk, footerErr = EnsureComponentVisibility(self.footer, "visible", "shell_footer")
    if footerOk ~= true then return false, footerErr end
    if self.minimizeButton ~= nil then self.minimizeButton:SetText("—") end
    if self.windowController ~= nil then
        local lockOk, _, lockDetail = self.windowController:SetLocked(state.locked == true)
        if lockOk ~= true then return false, lockDetail or "主窗口锁定状态应用失败" end
        local resizeOk, _, _, resizeDetail = self.windowController:SetResizeEnabled(true)
        if resizeOk ~= true then return false, resizeDetail or "主窗口缩放状态应用失败" end
    end
    if minimized then
        if RSUI.DropdownService ~= nil and type(RSUI.DropdownService.CloseAll) == "function" then
            RSUI.DropdownService:CloseAll()
        end
        if self.window ~= nil then
            local hidden, hideErr = Adapter:SetVisible(self.window, self.owner, false)
            if hidden ~= true then return false, hideErr or "主窗口最小化隐藏失败" end
        end
    end
    if persist ~= false then MarkDirty("minimized_changed") end
    return true, minimized
end

function Shell:ToggleMinimized()
    local state = V3.ShellState or {}
    local previous = state.minimized == true
    if previous then return true end
    state.minimized = true
    local applied, applyErr = self:ApplyMinimizedState(false)
    if applied ~= true then
        state.minimized = previous
        self:ApplyMinimizedState(false)
        return false, applyErr or "主窗口最小化状态应用失败"
    end
    local closed, closeErr = self:Close("minimized_to_launcher")
    if closed ~= true then
        state.minimized = previous
        self:ApplyMinimizedState(false)
        if previous ~= true and self.window ~= nil then Adapter:SetVisible(self.window, self.owner, true) end
        return false, closeErr or "主窗口最小化关闭失败"
    end
    MarkDirty("minimized_changed")
    return true
end

function Shell:SetLocked(locked, persist)
    local state = V3.ShellState or {}
    local nextValue = locked == true
    if state.locked == nextValue then return true, false end
    if self.windowController ~= nil then
        local accepted, _, detail = self.windowController:SetLocked(nextValue)
        if accepted ~= true then return false, detail or "主窗口锁定状态应用失败" end
    end
    state.locked = nextValue
    if persist ~= false then MarkDirty("window_locked") end
    return true, true
end

function Shell:IsLocked()
    return (V3.ShellState or {}).locked == true
end

function Shell:CommitWindowGeometry(_, x, y, width, height, reason)
    local state = V3.ShellState or {}
    local previous = {}
    for key, value in pairs(state) do previous[key] = value end
    local context = S.Layout:GetContext()
    local scale = math.max(0.01, tonumber(context.addonScale) or 1)
    if state.minimized ~= true and tostring(reason or "") == "resize" then
        local size = V3.ShellSizePolicy or { minWidth = 1, minHeight = 1 }
        state.width = math.max(size.minWidth, width / scale)
        state.height = math.max(size.minHeight, height / scale)
    end
    if S.Layout ~= nil and type(S.Layout.StorePlacement) == "function" then S.Layout:StorePlacement(state, self.window, { mode = "free" }) end
    state.userMoved = true
    local layoutOk, layoutErr = self:ApplyLayout(false)
    if layoutOk ~= true then
        for key in pairs(state) do state[key] = nil end
        for key, value in pairs(previous) do state[key] = value end
        pcall(function() self:ApplyLayout(false) end)
        return false, layoutErr or "主窗口几何提交失败"
    end
    MarkDirty("window_" .. tostring(reason or "geometry"))
    return true
end

function Shell:Create()
    if self.created == true and self.window ~= nil then return true end
    if tonumber(self.failedBuildGeneration) == tonumber(S.Generation) then
        self.buildQuarantinedRejects = (tonumber(self.buildQuarantinedRejects) or 0) + 1
        return false, tostring(self.failedBuildError or "主窗口构建已隔离")
    end
    local loaded, loadErr = true, nil
    if type(V3.EnsureShellStoreLoaded) == "function" then loaded, loadErr = V3:EnsureShellStoreLoaded() end
    if loaded ~= true then return false, loadErr or "主窗口配置读取失败" end

    local scope = type(RSUI.BeginBuildScope) == "function" and RSUI:BeginBuildScope("main_shell") or nil
    local function FailBuild(err)
        if scope ~= nil and type(RSUI.EndBuildScope) == "function" then RSUI:EndBuildScope(scope, false); scope = nil end
        self.created = false
        self.failedBuildGeneration = S.Generation
        self.failedBuildError = tostring(err or "主窗口构建失败")
        if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Error) == "function" then
            S.DiagnosticsManager:Error("ui_v3", "V3_SHELL_BUILD_QUARANTINED", "V3 主窗口构建失败，本次 Generation 已隔离重试", {
                generation = tostring(S.Generation or ""), error = self.failedBuildError,
            })
        end
        return false, self.failedBuildError
    end

    local window, createErr = Adapter:CreateRootWindow(self.logicalId, self.owner)
    if window == nil then return FailBuild(createErr) end
    self.window = window

    local root, rootErr = RSUI:Overlay({ id = "v3_shell_overlay", parent = window, width = 1, height = 1 })
    self.root = root
    if self.root == nil then return FailBuild("主窗口组件创建失败：" .. tostring(rootErr or "未知错误")) end

    self.background = RSUI:Border({
        id = "v3_shell_background", parent = self.root, variant = "card", gradient = false,
        padding = 0, slot = { hAlign = "fill", vAlign = "fill" },
    })
    self.appStack = RSUI:VerticalBox({ id = "v3_shell_app_stack", parent = self.background, gap = 0, slot = { hAlign = "fill", vAlign = "fill" } })

    self.topBar = RSUI:Border({
        id = "v3_shell_top_bar", parent = self.appStack, variant = "header", padding = 6, pickable = true,
        slot = { size = "fixed", height = 50, hAlign = "fill" },
    })
    local topRow = RSUI:HorizontalBox({ id = "v3_shell_top_row", parent = self.topBar, gap = 8 })
    local brand = RSUI:VerticalBox({ id = "v3_shell_brand", parent = topRow, gap = 1, slot = { size = "fill", fill = 1 } })
    RSUI:Text({ id = "v3_shell_title", parent = brand, text = "上古世纪综合辅助", fontSize = 15, tone = "accent", overflow = "ellipsis", slot = { size = "fixed", height = 20 } })
    RSUI:Text({ id = "v3_shell_subtitle", parent = brand, text = "模块化重构 · 新版界面", fontSize = 9, tone = "muted", overflow = "ellipsis", slot = { size = "fixed", height = 14 } })
    RSUI:Button({ id = "v3_shell_diag_button", parent = topRow, text = "诊断", compact = true,
        onClick = function() return self:Navigate("system.diagnostics", { source = "topbar" }) end,
        slot = { size = "fixed", width = 64 } })
    self.minimizeButton = RSUI:Button({ id = "v3_shell_minimize_button", parent = topRow, text = "—", compact = true,
        onClick = function() return self:ToggleMinimized() end,
        slot = { size = "fixed", width = 36 } })
    RSUI:Button({ id = "v3_shell_close_button", parent = topRow, text = "×", compact = true,
        onClick = function() return self:Close("close_button") end,
        slot = { size = "fixed", width = 36 } })

    self.body = RSUI:HorizontalBox({ id = "v3_shell_body", parent = self.appStack, gap = 0, slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" } })

    self.navFrame = RSUI:Border({ id = "v3_shell_nav_frame", parent = self.body, variant = "soft", padding = 7, slot = { size = "fixed", width = 204, hAlign = "fill", vAlign = "fill" } })
    self.navColumn = RSUI:VerticalBox({ id = "v3_shell_nav_column", parent = self.navFrame, gap = 5, slot = { hAlign = "fill", vAlign = "fill" } })
    self.navScroll = RSUI:ScrollBox({ id = "v3_shell_nav_scroll", parent = self.navColumn, scrollStep = 2, gap = 3, slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" } })
    self.navStack = nil
    self:BuildScrollableNavigation()

    self.navPager = RSUI:HorizontalBox({ id = "v3_shell_nav_pager", parent = self.navColumn, gap = 4, slot = { size = "fixed", height = 27, hAlign = "fill" } })
    self.navUp = RSUI:Button({ id = "v3_shell_nav_up", parent = self.navPager, text = "上", compact = true, slot = { size = "fixed", width = 38 }, onClick = function() local changed = self.navScroll:ScrollBy(-2); self:RefreshNavScrollHint(); return changed end })
    self.navScrollHint = RSUI:Text({ id = "v3_shell_nav_hint", parent = self.navPager, text = "滚动", fontSize = 9, tone = "muted", overflow = "ellipsis", align = ALIGN_CENTER, slot = { size = "fill", fill = 1 } })
    self.navDown = RSUI:Button({ id = "v3_shell_nav_down", parent = self.navPager, text = "下", compact = true, slot = { size = "fixed", width = 38 }, onClick = function() local changed = self.navScroll:ScrollBy(2); self:RefreshNavScrollHint(); return changed end })
    local rawScrollBy = self.navScroll.ScrollBy
    self.navScroll.ScrollBy = function(scroll, delta)
        local changed = rawScrollBy(scroll, delta)
        self:RefreshNavScrollHint()
        return changed
    end

    self.systemFrame = RSUI:Border({ id = "v3_shell_system_frame", parent = self.navColumn, variant = "card", padding = 5, slot = { size = "fixed", height = 185, hAlign = "fill" } })
    self:BuildSystemNavigation()

    self.contentFrame = RSUI:Border({ id = "v3_shell_content_frame", parent = self.body, variant = "card", padding = 14, slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" } })
    self.contentRoot = RSUI:Overlay({ id = "v3_shell_content_root", parent = self.contentFrame })
    if PageHost:Attach(self.contentRoot) ~= true then return FailBuild("页面宿主挂载失败") end

    self.footer = RSUI:Border({ id = "v3_shell_footer", parent = self.appStack, variant = "soft", padding = 6, slot = { size = "fixed", height = 30, hAlign = "fill" } })
    local footerRow = RSUI:HorizontalBox({ id = "v3_shell_footer_row", parent = self.footer, gap = 8 })
    self.status = RSUI:Text({ id = "v3_shell_status", parent = footerRow, text = "新版框架 · 活动模块已迁移", fontSize = 9, tone = "muted", overflow = "ellipsis", slot = { size = "fill", fill = 1 } })
    RSUI:Text({ id = "v3_shell_mode", parent = footerRow, text = "旧界面已停用", fontSize = 9, tone = "accent", overflow = "ellipsis", slot = { size = "auto" } })

    -- Toast is above normal page chrome but below the modal scrim. This keeps
    -- notifications visible without allowing them to bypass a blocking modal.
    local toastLayer = RSUI:Overlay({ id = "v3_shell_toast_layer", parent = self.root, slot = { hAlign = "fill", vAlign = "fill" } })
    local toastOk, toastErr = ToastHost:Attach(toastLayer)
    if toastOk ~= true then return FailBuild("通知宿主挂载失败：" .. tostring(toastErr or "未知错误")) end

    if ModalHost == nil or type(ModalHost.Attach) ~= "function" then return FailBuild("模态窗口宿主不可用") end
    local modalLayer = RSUI:Overlay({ id = "v3_shell_modal_layer", parent = self.root, slot = { hAlign = "fill", vAlign = "fill" } })
    local modalOk, modalErr = ModalHost:Attach(modalLayer)
    if modalOk ~= true then return FailBuild("模态窗口宿主挂载失败：" .. tostring(modalErr or "未知错误")) end

    self.windowController = Windowing:Attach({
        id = "main_shell", window = self.window, owner = self.owner, dragHandle = self.topBar,
        resizable = true, locked = (V3.ShellState or {}).locked == true,
        minWidth = (V3.ShellSizePolicy or {}).minWidth or 1, minHeight = (V3.ShellSizePolicy or {}).minHeight or 1,
        boundaryMode = "free", dragHandleHeight = 50,
        canResize = function() return true end,
        onGeometryChanged = function(controller, x, y, width, height, reason) return self:CommitWindowGeometry(controller, x, y, width, height, reason) end,
        onLiveGeometry = function(controller, x, y, width, height, kind) return self:ApplyInteractiveGeometry(x, y, width, height, kind) end,
    })
    if self.windowController == nil then return FailBuild("主窗口拖动/缩放能力创建失败") end

    self.created = true
    local minimizedOk, minimizedErr = self:ApplyMinimizedState(false)
    if minimizedOk ~= true then return FailBuild(minimizedErr or "主窗口初始状态应用失败") end
    local ok, layoutErr = self:ApplyLayout(false)
    if ok ~= true then return FailBuild(layoutErr) end

    local state = V3.ShellState or {}
    local initialRoute = Router:Resolve(state.lastRoute or "home") and tostring(state.lastRoute or "home") or "home"
    if initialRoute == "foundation" then initialRoute = "home" end
    local routed = self:Navigate(initialRoute, { source = "restore", keepHidden = true })
    if routed ~= true then self:Navigate("home", { source = "fallback", keepHidden = true }) end
    self:Close("create")
    if scope ~= nil and type(RSUI.EndBuildScope) == "function" then
        local committed, scopeErr = RSUI:EndBuildScope(scope, true)
        scope = nil
        if committed ~= true then return FailBuild(scopeErr or "主窗口严格构建失败") end
    end
    return true
end


function Shell:ApplyInteractiveGeometry(_, _, width, height, kind)
    if self.created ~= true or self.root == nil then return false end
    if tostring(kind or "") ~= "resize" then return true end
    width, height = math.max(1, tonumber(width) or 1), math.max(1, tonumber(height) or 1)
    self.root:LayoutIfNeeded(0, 0, width, height, true)
    if self.windowController ~= nil then
        local handlesOk, handlesErr = self.windowController:LayoutHandles(width, height)
        if handlesOk ~= true then return false, handlesErr or "主窗口缩放句柄布局失败" end
    end
    if type(RSUI.FlushLayoutQueue) == "function" then RSUI:FlushLayoutQueue(24) end
    return true
end

function Shell:ApplyLayout(fromMetricsChange, designWidth, designHeight)
    if self.created ~= true or self.window == nil or self.root == nil then return false, "主窗口尚未创建" end
    local x, y, width, height, dw, dh = self:ResolveRect(designWidth, designHeight)
    if self.windowController ~= nil and self.windowController:IsInteracting() == true then
        local ix, iy, iw, ih = S.Layout:GetLogicalRect(self.window)
        x, y, width, height = tonumber(ix) or x, tonumber(iy) or y, tonumber(iw) or width, tonumber(ih) or height
        if self.windowController:IsResizing() == true then
            self:ApplyInteractiveGeometry(x, y, width, height, "resize")
        end
        self.lastRect = { x = x, y = y, width = width, height = height, designWidth = dw, designHeight = dh, metricsChange = fromMetricsChange == true, interacting = true }
        return true, self.lastRect
    end
    local rectOk, rectErr = Adapter:ApplyRect(self.window, self.owner, x, y, width, height)
    if rectOk ~= true then return false, rectErr or "主窗口原生几何应用失败" end
    self.root:LayoutIfNeeded(0, 0, width, height, true)
    if self.windowController ~= nil then
        local handlesOk, handlesErr = self.windowController:LayoutHandles(width, height)
        if handlesOk ~= true then return false, handlesErr or "主窗口缩放句柄布局失败" end
    end
    -- Scroll visibility is known only after the first arrangement. Updating the
    -- hint can invalidate text/button measure, so do it BEFORE the final bounded
    -- stabilization flush; otherwise ApplyLayout would return a dirty tree.
    self:RefreshNavScrollHint()
    if type(RSUI.FlushLayoutQueue) == "function" then RSUI:FlushLayoutQueue(32) end
    self.lastRect = { x = x, y = y, width = width, height = height, designWidth = dw, designHeight = dh, metricsChange = fromMetricsChange == true, minimized = (V3.ShellState or {}).minimized == true }
    return true, self.lastRect
end

function Shell:Open()
    local created, err = self:Create()
    if created ~= true then return false, err end
    local state = V3.ShellState or {}
    local wasMinimized = state.minimized == true
    if wasMinimized then
        state.minimized = false
        local restored, restoreErr = self:ApplyMinimizedState(false)
        if restored ~= true then
            state.minimized = true
            self:ApplyMinimizedState(false)
            return false, restoreErr or "主窗口恢复状态应用失败"
        end
    end
    local layoutOk, layoutErr = self:ApplyLayout(false)
    if layoutOk ~= true then
        if wasMinimized then
            state.minimized = true
            self:ApplyMinimizedState(false)
        end
        return false, layoutErr or "主窗口布局应用失败"
    end
    local shown, showErr = Adapter:SetVisible(self.window, self.owner, true)
    if shown ~= true then
        if wasMinimized then
            state.minimized = true
            self:ApplyMinimizedState(false)
        end
        return false, showErr or "主窗口显示失败"
    end
    if wasMinimized then MarkDirty("minimized_changed") end
    Adapter:Raise(self.window)
    return true
end

function Shell:Close(reason)
    if RSUI.DropdownService ~= nil and type(RSUI.DropdownService.CloseAll) == "function" then
        RSUI.DropdownService:CloseAll()
    end
    if self.window == nil then return true end
    local hidden, hideErr = Adapter:SetVisible(self.window, self.owner, false)
    if hidden ~= true then return false, hideErr or "主窗口隐藏失败" end
    self.lastCloseReason = tostring(reason or "close")
    if ModalHost ~= nil and type(ModalHost.Clear) == "function" then ModalHost:Clear() end
    if ToastHost ~= nil and type(ToastHost.Clear) == "function" then ToastHost:Clear("shell_close") end
    return true
end

local function ReportNavigationFailure(routeId, reason, context)
    reason = tostring(reason or "未知错误")
    local source = tostring(type(context) == "table" and context.source or "")
    if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Error) == "function" then
        S.DiagnosticsManager:Error("v3_navigation", "PAGE_NAVIGATION_FAILED", "V3 页面打开失败", {
            route = tostring(routeId or ""), source = source, error = reason,
        })
    end
    if source == "navigation" or source == "system_navigation" or source == "topbar" then
        if ToastHost ~= nil and type(ToastHost.Notify) == "function" then
            ToastHost:Notify({
                id = "nav_failed_" .. tostring(routeId or "page"):gsub("[^%w]", "_"),
                title = "页面打开失败", detail = tostring(routeId or "页面") .. " · " .. reason,
                tone = "red", durationMs = 5200,
            })
        end
        if type(Shell.SetStatus) == "function" then Shell:SetStatus("页面打开失败 · " .. reason, "red") end
    end
    return false, reason
end

function Shell:Navigate(routeId, context)
    context = type(context) == "table" and context or {}
    local resolved = Router:Resolve(routeId)
    if resolved == nil then return ReportNavigationFailure(routeId, "页面不存在", context) end
    if resolved.probe == true then self.lastRoute = "foundation:probe"; return true end
    local ok, err = PageHost:Navigate(resolved.id, context)
    if ok ~= true then
        pcall(function() self:ApplyLayout(false) end)
        return ReportNavigationFailure(resolved.id, err or "页面创建/激活失败", context)
    end
    self.lastRoute = resolved.id
    Router.current = resolved.id
    for route, button in pairs(self.navButtons) do SetButtonSelected(button, route == resolved.id) end
    local state = V3.ShellState or {}
    if state.lastRoute ~= resolved.id then state.lastRoute = resolved.id; MarkDirty("route_changed") end
    self:SetStatus(resolved.title .. " · 新版界面")
    if context.keepHidden ~= true then return self:Open() end
    local layoutOk, layoutErr = self:ApplyLayout(false)
    if layoutOk ~= true then return false, layoutErr end
    return true
end

function Shell:RefreshData(dirty)
    if PageHost ~= nil and type(PageHost.RefreshData) == "function" then return PageHost:RefreshData(dirty) end
    return true
end

function Shell:GetSnapshot()
    local width, height = Adapter:GetExtent(self.window)
    local authority = self.window and UI:GetNativeAuthority(self.window) or nil
    return {
        created = self.created == true,
        visible = Adapter:IsVisible(self.window),
        width = width,
        height = height,
        owner = authority and authority.owner or nil,
        authorityMode = authority and authority.mode or nil,
        rootDirty = self.root and self.root:IsLayoutDirty() == true or false,
        buildQuarantined = tonumber(self.failedBuildGeneration) == tonumber(S.Generation),
        buildQuarantinedRejects = tonumber(self.buildQuarantinedRejects) or 0,
        buildError = self.failedBuildError,
        stackDirty = self.appStack and self.appStack:IsLayoutDirty() == true or false,
        lastRoute = self.lastRoute,
        minimized = (V3.ShellState or {}).minimized == true,
        locked = (V3.ShellState or {}).locked == true,
        pageHost = PageHost and PageHost:Describe() or nil,
        windowing = Windowing and Windowing:Describe() or nil,
        toastHost = ToastHost and ToastHost:Describe() or nil,
        modalHost = ModalHost and ModalHost:Describe() or nil,
        window = self.window,
        lastRect = self.lastRect,
    }
end

-- Replicated Suite · 页面生命周期宿主
-- 作者：Replicated
-- QQ群：1104129461
-- 页面工厂按语义路由注册；PageHost 延迟创建并保留页面，所有页面间转换经 Router 返回。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI = S.RSUI
if type(RSUI) ~= "table" then return end

S.UIV3 = S.UIV3 or {}
S.UIV3.PageHost = {
    version = 6,
    featureConsumerLifecycleContractVersion = 1,
    buildTransactionContractVersion = 1,
    buildContextContractVersion = 1,
    root = nil,
    switcher = nil,
    factories = {},
    fallbackFactory = nil,
    pages = {},
    moduleControls = {},
    pageOrder = {},
    activeRoute = nil,
    context = nil,
    -- buildContext 只在工厂同步构建期间传递 moduleId；成功或失败都恢复 previousContext，
    -- 不能跨帧缓存，否则后建页面会继承前一模块的诊断入口。
    buildContext = nil,
    failedPages = {},
    stats = {
        builds = 0, buildFailures = 0, quarantinedRejects = 0,
        consumerAcquires = 0, consumerReleases = 0, consumerReleaseSkips = 0,
        consumerDisabledSyncs = 0, lifecycleDisableSyncs = 0, lifecycleEnableSyncs = 0,
        lifecycleReacquireFailures = 0,
    },
}
local H = S.UIV3.PageHost

local function ReportPageFault(code, message, route, phase, detail)
    local diagnostics = S.DiagnosticsManager
    if type(diagnostics) == "table" and type(diagnostics.Error) == "function" then
        diagnostics:Error("ui_v3", tostring(code or "V3_PAGE_ERROR"), tostring(message or "V3 页面错误"), {
            route = tostring(route or ""), phase = tostring(phase or ""), error = tostring(detail or ""),
        })
    end
end

function H:RegisterFactory(route, factory)
    route = tostring(route or "")
    if route == "*" then
        if type(factory) ~= "function" then return false, "fallback factory required" end
        self.fallbackFactory = factory
        return true
    end
    if route == "" or type(factory) ~= "function" then return false, "invalid page factory" end
    if self.factories[route] ~= nil then return false, "duplicate page factory: " .. route end
    self.factories[route] = factory
    return true
end

function H:Attach(parent)
    if self.switcher ~= nil then return true end
    self.root = parent
    local controls = S.UIV3.ModuleControlsV3
    if controls then
        -- 工具条固定占一行，正文独立Fill；不侵入ScrollBox也不改Native父级。
        self.frame = RSUI:VerticalBox({ id = "v3_page_frame", parent = parent, gap = 6,
            slot = { hAlign = "fill", vAlign = "fill" } })
        if not self.frame then return false, "page_frame_failed" end
        self.controlsSwitcher = RSUI:WidgetSwitcher({ id = "v3_module_controls_switcher", parent = self.frame,
            activeIndex = 1, measureMode = "active", slot = { size = "fixed", height = 32, hAlign = "fill" } })
        if not self.controlsSwitcher then return false, "module_controls_switcher_failed" end
        parent = self.frame
        controls:BindLifecycle()
    end
    self.switcher = RSUI:WidgetSwitcher({ id = "v3_page_switcher", parent = parent, activeIndex = 1, measureMode = "active", slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" } })
    return self.switcher ~= nil
end

function H:GetBuildContext()
    local row = self.buildContext
    if type(row) ~= "table" then return nil end
    -- 返回新的薄表，禁止 DesignSystem/页面工厂反向修改 PageHost 当前上下文。Feature 元数据本身
    -- 来自 FeatureRegistry，只用于读取 id/route/name；诊断按钮不能通过这里启停 Feature。
    return { route = row.route, moduleId = row.moduleId, feature = row.feature, controlBar = row.controlBar }
end

-- Feature Disable 先清 Demand 再发 disabled。页面若只保留 consumerHeld=true，
-- 再次启用时就不会重取需求，出现开关已开却未采集的情况。
-- 此桥只管当前可见页：disabled 同步旗标，enabled 幂等重取同一 token；
-- 离页先用 Demand:Has 查真实持有关系，不能对已清掉的 token 再 Release。
local function FeatureConsumerHeld(feature, token, fallback)
    local demand = type(feature) == "table" and feature.Demand or nil
    if type(demand) == "table" and type(demand.Has) == "function" then
        return demand:Has(token) == true
    end
    return fallback == true
end

function H:SyncFeatureConsumer(page, options, reason)
    options = type(options) == "table" and options or {}
    local feature = options.feature
    local featureId = tostring(options.featureId or (type(feature) == "table" and feature.Id) or "")
    local token = tostring(options.token or "")
    if type(page) ~= "table" or type(feature) ~= "table" or featureId == "" or token == "" then
        return false, "invalid page feature consumer binding"
    end
    if type(feature.AcquireConsumer) ~= "function" then return false, "feature consumer acquire unavailable" end
    if S.FeatureRuntime == nil or S.FeatureRuntime:IsEnabled(featureId) ~= true then
        self.stats.consumerDisabledSyncs = (tonumber(self.stats.consumerDisabledSyncs) or 0) + 1
        page.consumerHeld = false
        if type(options.onDisabled) == "function" then pcall(options.onDisabled, page, tostring(reason or "disabled")) end
        if type(options.refresh) == "function" then options.refresh(page, "disabled", reason) end
        return true
    end

    local held = FeatureConsumerHeld(feature, token, page.consumerHeld)
    if held ~= true then
        local ok, err = feature:AcquireConsumer(token)
        if ok ~= true then
            page.consumerHeld = false
            return false, err or ("Consumer 获取失败: " .. token)
        end
        self.stats.consumerAcquires = (tonumber(self.stats.consumerAcquires) or 0) + 1
    end
    page.consumerHeld = true
    if type(options.onEnabled) == "function" then pcall(options.onEnabled, page, tostring(reason or "enabled")) end
    if type(options.refresh) == "function" then options.refresh(page, "enabled", reason) end
    return true
end

function H:ReleaseFeatureConsumer(page, options, reason)
    options = type(options) == "table" and options or {}
    local feature = options.feature
    local featureId = tostring(options.featureId or (type(feature) == "table" and feature.Id) or "")
    local token = tostring(options.token or "")
    if type(page) ~= "table" or type(feature) ~= "table" or token == "" then return false, "invalid page feature consumer release" end

    -- Disable 已清空 Demand，只同步页面旗标；再次 Release 会误报 consumer not held。
    if featureId ~= "" and S.FeatureRuntime ~= nil and S.FeatureRuntime:IsEnabled(featureId) ~= true then
        self.stats.consumerReleaseSkips = (tonumber(self.stats.consumerReleaseSkips) or 0) + 1
        page.consumerHeld = false
        return true
    end
    local held = FeatureConsumerHeld(feature, token, page.consumerHeld)
    if held ~= true then
        self.stats.consumerReleaseSkips = (tonumber(self.stats.consumerReleaseSkips) or 0) + 1
        page.consumerHeld = false
        return true
    end
    if type(feature.ReleaseConsumer) ~= "function" then return false, "feature consumer release unavailable" end
    local ok, err = feature:ReleaseConsumer(token)
    if ok ~= true then return false, err or ("Consumer 释放失败: " .. token) end
    self.stats.consumerReleases = (tonumber(self.stats.consumerReleases) or 0) + 1
    page.consumerHeld = false
    return true
end

function H:BindFeatureConsumerLifecycle(page, options)
    options = type(options) == "table" and options or {}
    local feature = options.feature
    local featureId = tostring(options.featureId or (type(feature) == "table" and feature.Id) or "")
    if type(page) ~= "table" or type(feature) ~= "table" or featureId == "" then return false, "invalid feature lifecycle binding" end
    if S.Events == nil or type(S.Events.SubscribeInternal) ~= "function" then return false, "internal event bus unavailable" end
    return S.Events:SubscribeInternal((S.FeatureRuntime and S.FeatureRuntime.LifecycleTopic) or "v3.feature.lifecycle", page,
        function(_, changedId, state, reason)
            if tostring(changedId or "") ~= featureId then return end
            state = tostring(state or "")
            if state == "disabled" then
                self.stats.lifecycleDisableSyncs = (tonumber(self.stats.lifecycleDisableSyncs) or 0) + 1
                -- Domain 已完成 Demand:Clear；这里绝不能根据旧 boolean 二次 Release。
                page.consumerHeld = false
                if type(options.onDisabled) == "function" then pcall(options.onDisabled, page, tostring(reason or "feature_disable")) end
                if type(options.refresh) == "function" then options.refresh(page, state, reason) end
                return
            end
            if state ~= "enabled" then return end
            self.stats.lifecycleEnableSyncs = (tonumber(self.stats.lifecycleEnableSyncs) or 0) + 1
            local ok, err = H:SyncFeatureConsumer(page, options, "feature_lifecycle:" .. tostring(reason or "enable"))
            if ok ~= true then
                self.stats.lifecycleReacquireFailures = (tonumber(self.stats.lifecycleReacquireFailures) or 0) + 1
                ReportPageFault("V3_PAGE_CONSUMER_REACQUIRE_FAILED", "功能重新启用后页面 Consumer 恢复失败", tostring(page.route or ""),
                    "feature_lifecycle", tostring(err or "unknown"))
            end
        end)
end

function H:CreatePage(route)
    route = tostring(route or "")
    if self.switcher == nil then return nil, "page host not attached" end
    -- 直接 PageHost 调用也检查开放，不能只依赖 Shell/Router。先于缓存页和 Native build，
    -- 拒绝不进入 quarantine，也不调用页面 Initialize/AcquireConsumer。
    local accessMeta = S.FeatureRegistry and S.FeatureRegistry:GetByRoute(route)
    local accessRoute = S.UIV3.Router and S.UIV3.Router.routes and S.UIV3.Router.routes[route]
    local accessId = accessMeta and accessMeta.id or accessRoute and accessRoute.featureId
    if accessId and not S.FeatureRegistry:IsAccessible(accessId) then return nil, "功能未在手动配置中开放" end
    if self.pages[route] ~= nil then return self.pages[route] end

    local failed = self.failedPages[route]
    if type(failed) == "table" and tonumber(failed.generation) == tonumber(S.Generation) then
        self.stats.quarantinedRejects = (tonumber(self.stats.quarantinedRejects) or 0) + 1
        return nil, tostring(failed.error or "page build quarantined")
    end

    local feature = S.FeatureRegistry and S.FeatureRegistry:GetByRoute(route) or nil
    -- 同一功能的隐藏语义视图可以复用 Router 的 featureId；不另造功能或启停 Authority。
    if feature==nil and S.FeatureRegistry and type(S.FeatureRegistry.Get)=="function" and S.UIV3 and S.UIV3.Router and type(S.UIV3.Router.Get)=="function" then
        local routed=S.UIV3.Router:Get(route)
        if routed and routed.featureId then feature=S.FeatureRegistry:Get(routed.featureId) end
    end
    local factory = self.factories[route] or self.fallbackFactory
    if type(factory) ~= "function" then return nil, "page factory unavailable: " .. tostring(route) end

    local controlBar
    local ok, page, detail = RSUI:WithBuildScope("page:" .. route, function()
        -- 同步工厂调用期间传递诊断 moduleId，xpcall 后必恢复上下文。
        -- 不能留到激活或 Refresh 阶段，否则异步 UI 会把报告归给错误模块。
        local previousBuildContext = self.buildContext
        if self.controlsSwitcher and S.UIV3.ModuleControlsV3 then
            local controlErr
            controlBar, controlErr = S.UIV3.ModuleControlsV3:Create(self.controlsSwitcher, route, feature)
            if not controlBar then error(controlErr or "module_controls_failed") end
        end
        self.buildContext = { route = route, moduleId = feature and feature.id or nil, feature = feature, controlBar = controlBar }
        local factoryOk, builtPage, builtDetail = xpcall(function()
            local result, resultErr = factory(self.switcher, route, feature)
            if result and controlBar then S.UIV3.ModuleControlsV3:Finish(controlBar, result) end
            return result, resultErr
        end, S.SafeTraceback)
        self.buildContext = previousBuildContext
        if factoryOk ~= true then error(builtPage) end
        return builtPage, builtDetail
    end)
    self.stats.builds = (tonumber(self.stats.builds) or 0) + 1
    if ok ~= true or page == nil then
        local err = tostring(detail or ("page create failed: " .. route))
        self.failedPages[route] = { generation = S.Generation, error = err }
        self.stats.buildFailures = (tonumber(self.stats.buildFailures) or 0) + 1
        if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Error) == "function" then
            S.DiagnosticsManager:Error("ui_v3", "V3_PAGE_BUILD_QUARANTINED", "V3 页面构建失败，本次 Generation 已隔离重试", {
                route = route, generation = tostring(S.Generation or ""), error = err,
            })
        end
        return nil, err
    end
    self.pages[route] = page
    self.moduleControls[route] = controlBar
    self.pageOrder[#self.pageOrder + 1] = route
    return page
end

function H:ActivateControls(route)
    local page = self.pages[route]
    local compact = page ~= nil and page.compactPageChrome == true
    if self.compactPageChrome ~= compact then
        self.compactPageChrome = compact
        if self.frame then
            self.frame.gap = compact and 2 or 6
            self.frame:InvalidateMeasure("page_chrome_changed")
        end
        if self.controlsSwitcher then
            self.controlsSwitcher:SetSlot({ size = "fixed", height = compact and 24 or 32, hAlign = "fill" })
        end
    end
    local bar = self.moduleControls[route]
    if not bar or not self.controlsSwitcher then return true end
    if self.activeControlsRoute ~= route then
        local accepted = self.controlsSwitcher:SetActiveWidget(bar.root)
        if accepted == false then return false, "module controls switch rejected" end
        self.activeControlsRoute = route
    end
    S.UIV3.ModuleControlsV3:Refresh(bar)
    return true
end

function H:Navigate(route, context)
    route = tostring(route or "")
    local page, err = self:CreatePage(route)
    if page == nil then return false, err end
    local nextContext = type(context) == "table" and context or {}
    local previousRoute = self.activeRoute
    local previousContext = self.context
    local previousPage = previousRoute and self.pages[previousRoute] or nil

    local function RestorePreviousPage()
        if previousPage == nil then
            self.activeRoute, self.context = previousRoute, previousContext
            return true
        end
        if type(self.switcher.SetActiveWidget) == "function" then
            local switched = self.switcher:SetActiveWidget(previousPage)
            if switched == false then return false, "widget switcher rejected previous page restore" end
        end
        self.activeRoute, self.context = previousRoute, previousContext
        local controlsOk, controlsErr = self:ActivateControls(previousRoute)
        if controlsOk ~= true then return false, controlsErr end
        if type(previousPage.OnRoute) == "function" then
            local routed, routeErr = xpcall(function() return previousPage:OnRoute(previousContext or {}) end, S.SafeTraceback)
            if routed ~= true then return false, routeErr end
            if routeErr == false then return false, "previous page route restore returned false" end
        end
        if type(previousPage.OnActivated) == "function" then
            local activated, activateResult, activateErr = xpcall(function()
                return previousPage:OnActivated(previousRoute, previousContext or {})
            end, S.SafeTraceback)
            if activated ~= true then return false, activateResult end
            if activateResult == false then return false, activateErr or "previous page activation restore returned false" end
        end
        return true
    end

    -- 先准备目标路由再释放当前 Consumer，畸形目标不能拆掉正在使用的页面。
    -- OnRoute 只处理表现，OnActivated 才获取资源。
    if type(page.OnRoute) == "function" then
        local ok, routeResult, routeErr = xpcall(function() return page:OnRoute(nextContext) end, S.SafeTraceback)
        if not ok then
            ReportPageFault("V3_PAGE_ROUTE_FAILED", "V3 页面路由准备失败", route, "route", routeErr)
            return false, routeErr
        end
        if routeResult == false then
            ReportPageFault("V3_PAGE_ROUTE_REJECTED", "V3 页面路由准备拒绝目标页", route, "route", routeErr)
            return false, routeErr or "page route rejected"
        end
    end

    -- 下拉弹层挂 UIParent 以绕过页面裁切；成功切页前须先关闭，隐藏旧页面不会自动隐藏它。
    if RSUI.DropdownService ~= nil and type(RSUI.DropdownService.CloseAll) == "function" then
        RSUI.DropdownService:CloseAll()
    end

    -- 重选当前路由仍传递 OnRoute 上下文，但不重取 Consumer 或触发停用、激活；
    -- switcher 的无变更返回也不能当作导航拒绝。
    if previousPage == page and previousRoute == route then
        self.activeRoute = route
        self.context = nextContext
        if type(page.Refresh) == "function" and route == "system.diagnostics" then page:Refresh() end
        return self:ActivateControls(route)
    end

    if previousPage ~= nil and previousPage ~= page and type(previousPage.OnDeactivated) == "function" then
        local ok, deactivateResult, deactivateErr = xpcall(function() return previousPage:OnDeactivated(route) end, S.SafeTraceback)
        if not ok then
            ReportPageFault("V3_PAGE_DEACTIVATE_FAILED", "V3 页面停用失败", tostring(previousRoute or ""), "deactivate", deactivateErr)
            return false, deactivateErr
        end
        if deactivateResult == false then
            ReportPageFault("V3_PAGE_DEACTIVATE_REJECTED", "V3 页面停用拒绝释放", tostring(previousRoute or ""), "deactivate", deactivateErr)
            return false, deactivateErr or "previous page deactivation rejected"
        end
    end

    if type(self.switcher.SetActiveWidget) == "function" then
        local switched = self.switcher:SetActiveWidget(page)
        if switched == false then
            local switchErr = "widget switcher rejected target page"
            ReportPageFault("V3_PAGE_SWITCH_FAILED", "V3 页面切换器拒绝目标页面", route, "switch", switchErr)
            local restored, restoreErr = RestorePreviousPage()
            if restored ~= true then
                ReportPageFault("V3_PAGE_RESTORE_FAILED", "V3 页面切换失败且旧页面恢复失败", tostring(previousRoute or ""), "restore", restoreErr)
                return false, switchErr .. "; restore failed: " .. tostring(restoreErr or "unknown")
            end
            return false, switchErr
        end
    end
    self.activeRoute = route
    self.context = nextContext

    if type(page.OnActivated) == "function" then
        local ok, activateResult, activateDetail = xpcall(function() return page:OnActivated(previousRoute, nextContext) end, S.SafeTraceback)
        local activated = ok and activateResult ~= false
        if not activated then
            local activationErr = ok and (activateDetail or "page activation returned false") or activateResult
            ReportPageFault("V3_PAGE_ACTIVATE_FAILED", "V3 页面激活失败", route, "activate", activationErr)
            -- 尽力回滚：失败目标先释放已获取资源，再由前一条路由恢复表现与 Consumer 所有权；导航失败不能让 Feature 通道在空白页面后继续运行。
            if type(page.OnDeactivated) == "function" then pcall(function() page:OnDeactivated(previousRoute) end) end
            local restored, restoreErr = RestorePreviousPage()
            if restored ~= true then
                ReportPageFault("V3_PAGE_RESTORE_FAILED", "V3 页面激活失败且旧页面恢复失败", tostring(previousRoute or ""), "restore", restoreErr)
            end
            return false, activationErr
        end
    end

    local controlsOk, controlsErr = self:ActivateControls(route)
    if controlsOk ~= true then
        if type(page.OnDeactivated) == "function" then pcall(page.OnDeactivated, page, previousRoute) end
        local restored, restoreErr = RestorePreviousPage()
        return false, tostring(controlsErr) .. (restored ~= true and ("; restore: " .. tostring(restoreErr)) or "")
    end
    if type(page.Refresh) == "function" and route == "system.diagnostics" then page:Refresh() end
    return true
end

function H:RefreshData(dirty)
    local page = self.activeRoute and self.pages[self.activeRoute] or nil
    if page ~= nil and type(page.RefreshData) == "function" then return page:RefreshData(dirty) end
    return true
end

function H:Describe()
    local registered = 0
    for _ in pairs(self.factories) do registered = registered + 1 end
    local quarantined = 0
    for _, row in pairs(self.failedPages or {}) do if type(row) == "table" and tonumber(row.generation) == tonumber(S.Generation) then quarantined = quarantined + 1 end end
    return {
        version = self.version, buildTransactionContractVersion = self.buildTransactionContractVersion,
        buildContextContractVersion = self.buildContextContractVersion,
        featureConsumerLifecycleContractVersion = self.featureConsumerLifecycleContractVersion,
        registeredFactories = registered, hasFallback = self.fallbackFactory ~= nil,
        created = #self.pageOrder, activeRoute = self.activeRoute, quarantined = quarantined,
        builds = tonumber(self.stats.builds) or 0, buildFailures = tonumber(self.stats.buildFailures) or 0,
        quarantinedRejects = tonumber(self.stats.quarantinedRejects) or 0,
        consumerAcquires = tonumber(self.stats.consumerAcquires) or 0,
        consumerReleases = tonumber(self.stats.consumerReleases) or 0,
        consumerReleaseSkips = tonumber(self.stats.consumerReleaseSkips) or 0,
        consumerDisabledSyncs = tonumber(self.stats.consumerDisabledSyncs) or 0,
        lifecycleDisableSyncs = tonumber(self.stats.lifecycleDisableSyncs) or 0,
        lifecycleEnableSyncs = tonumber(self.stats.lifecycleEnableSyncs) or 0,
        lifecycleReacquireFailures = tonumber(self.stats.lifecycleReacquireFailures) or 0,
    }
end

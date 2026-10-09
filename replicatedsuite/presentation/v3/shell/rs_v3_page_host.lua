------------------------------------------------------------------------
-- Replicated Suite V3 - Page Host
--
-- Pages register factories against semantic routes. PageHost lazy-creates and
-- retains pages, while every page-to-page transition returns through Router.
------------------------------------------------------------------------
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
    -- 中文维护注释（2026-09-18，module-diagnostics-header-1）：buildContext 只在页面工厂
    -- 同步构建期间存在，用来把 FeatureRegistry 的 moduleId 传给 DesignSystem。它不是运行时
    -- Feature Authority，也不得跨帧缓存；页面构建成功/失败都必须恢复 previousContext，避免
    -- 后一个页面错误继承前一个模块的诊断入口。
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
        -- 维护（module-controls-diag-2）：工具条固定占一行，正文独立Fill；不侵入ScrollBox也不改Native父级。
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

------------------------------------------------------------------------
-- Active-page Feature Consumer lifecycle bridge
--
-- 中文维护注释（2026-09-25，page-feature-consumer-lifecycle-1）：
-- FeatureRuntime 是 Enabled/Disabled 唯一 Authority。Feature:Disable() 会先清空其 Demand，随后才发布
-- `v3.feature.lifecycle=disabled`。过去很多已打开页面只记一份 `consumerHeld=true`，却不监听这个
-- 生命周期事实；功能方案关闭模块后，真实 Demand 已归零而页面旗标仍为 true，再次启用时页面不会
-- Acquire，形成“开关显示已开、实际采集/查询没有恢复”的假开启。
--
-- 本桥只服务当前可见页面的 Presentation Consumer：
-- * 不直接启停 Feature，不写 v3.features，不成为第二生命周期 Authority；
-- * disabled 事件只同步本地 lease 事实并刷新 UI，绝不对已被 Domain 清掉的 token 再 Release；
-- * enabled 事件在页面仍订阅期间重新 Acquire 同一 token；Demand token 幂等，避免重复 lease；
-- * 页面离开时优先用 Demand:Has 校验真实持有状态，防止 stale boolean 导致 `consumer not held`；
-- * 全部发生在页面激活/生命周期边沿，无 Tick、无轮询、无 Native 查询放大。
------------------------------------------------------------------------
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

    -- Runtime 已关闭时，Feature Disable 契约已经清空 Demand。这里只同步 Presentation 旗标，
    -- 不能再发一次 Release；否则严格 Demand 会返回 `consumer not held` 并把正常页面退出误判为故障。
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
    -- 中文维护：直接 PageHost 调用也检查开放，不能只依赖 Shell/Router。先于缓存页和 Native build，
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
        -- 中文维护注释（2026-09-18）：PageHeader 的诊断按钮必须自动知道当前 Feature，
        -- 但不能要求每个业务页面手工传 moduleId。这里以页面工厂同步调用栈作为唯一边界；
        -- xpcall 确保 factory 抛错时 buildContext 也一定恢复。禁止把 buildContext 留到页面
        -- 激活/Refresh 阶段，否则异步 UI 会串模块并把错误报告归错 Owner。
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

    -- Route preparation runs before the current page releases its consumers. A
    -- malformed target therefore cannot tear down the page the user is already
    -- using. OnRoute must remain presentation-only and must not acquire runtime
    -- resources; OnActivated is the lifecycle boundary.
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

    -- Dropdown popups are physically parented to UIParent so they can escape a
    -- page ScrollBox/card clipping boundary. They are transient presentation,
    -- therefore every successful route transition closes them before the old
    -- page is hidden. This is event-driven and owns no Tick/scan task.
    if RSUI.DropdownService ~= nil and type(RSUI.DropdownService.CloseAll) == "function" then
        RSUI.DropdownService:CloseAll()
    end

    -- Re-selecting the route already on screen is an idempotent navigation. The
    -- old path asked WidgetSwitcher to "change" to the same page; its no-change
    -- return was then misclassified as a hard navigation rejection. Keep OnRoute
    -- above so refreshed route context is accepted, but do not tear down/reacquire
    -- feature consumers or emit activation/deactivation churn.
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
            -- Best-effort rollback. The failed target first releases anything it
            -- may have acquired, then the previous route regains presentation and
            -- consumer ownership. A navigation failure must never leave Feature
            -- lanes running behind a blank page.
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

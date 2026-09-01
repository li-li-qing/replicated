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
    version = 4,
    buildTransactionContractVersion = 1,
    root = nil,
    switcher = nil,
    factories = {},
    fallbackFactory = nil,
    pages = {},
    pageOrder = {},
    activeRoute = nil,
    context = nil,
    failedPages = {},
    stats = { builds = 0, buildFailures = 0, quarantinedRejects = 0 },
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
    self.switcher = RSUI:WidgetSwitcher({ id = "v3_page_switcher", parent = parent, activeIndex = 1, measureMode = "active", slot = { hAlign = "fill", vAlign = "fill" } })
    return self.switcher ~= nil
end

function H:CreatePage(route)
    route = tostring(route or "")
    if self.switcher == nil then return nil, "page host not attached" end
    if self.pages[route] ~= nil then return self.pages[route] end

    local failed = self.failedPages[route]
    if type(failed) == "table" and tonumber(failed.generation) == tonumber(S.Generation) then
        self.stats.quarantinedRejects = (tonumber(self.stats.quarantinedRejects) or 0) + 1
        return nil, tostring(failed.error or "page build quarantined")
    end

    local feature = S.FeatureRegistry and S.FeatureRegistry:GetByRoute(route) or nil
    local factory = self.factories[route] or self.fallbackFactory
    if type(factory) ~= "function" then return nil, "page factory unavailable: " .. tostring(route) end

    local ok, page, detail = RSUI:WithBuildScope("page:" .. route, function()
        return factory(self.switcher, route, feature)
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
    self.pageOrder[#self.pageOrder + 1] = route
    return page
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
        return true
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
        version = self.version, buildTransactionContractVersion = self.buildTransactionContractVersion, registeredFactories = registered, hasFallback = self.fallbackFactory ~= nil,
        created = #self.pageOrder, activeRoute = self.activeRoute, quarantined = quarantined,
        builds = tonumber(self.stats.builds) or 0, buildFailures = tonumber(self.stats.buildFailures) or 0, quarantinedRejects = tonumber(self.stats.quarantinedRejects) or 0,
    }
end

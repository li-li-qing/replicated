------------------------------------------------------------------------
-- Replicated Suite V3 - Foundation Acceptance v99 -- 中文维护注释：.18.197 增加 Persistence Transport v2/活动精确恢复、团队默认开启与团队中心布局验收；所有检查均为只读契约检查，不触发 Store Load 或 Native 动作。
--
-- Bounded, on-demand checks only. No Native widget creation and no Tick.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.UIV3Acceptance = { version = 99 } -- 中文维护注释：v99 把本轮持久化与团队产品语义纳入 Fresh Reload 发布门槛；不会把 Presentation acceptance 变成业务 Authority。
local A = S.UIV3Acceptance
A.TradeDpsFreshReloadPreflightContractVersion = 2
A.TradeDetailFavoritesContractVersion = 1
A.PersistenceReliabilityV3ContractVersion = 1
A.PersistenceReliabilityV4ContractVersion = 1
A.PersistenceReliabilityV5ContractVersion = 1
A.PersistenceReliabilityV6ContractVersion = 1
A.PersistenceReliabilityV7ContractVersion = 1
A.PersistenceTerminalLoadMemoizationContractVersion = 1
A.DeathReviewCanonicalWindowContractVersion = 6
A.PersistenceTaskStableCodecContractVersion = 1
A.BuffDisplayEquipmentReadContractVersion = 1
A.SidecarServiceBoundaryContractVersion = 1
A.QuickSurfaceReloadReconcileContractVersion = 3
A.ShellPersistenceSchemaContractVersion = 1
A.PopupCoordinateAuthorityContractVersion = 3 -- 中文维护注释：v3 要求 Suite-owned detached Popup 最终使用 Native-relative Trigger Anchor；绝对 viewport solver 仅服务显式 point/外部 Native，且专项诊断按钮属于验收能力。
A.NavigationDevelopmentOrderContractVersion = 1 -- 中文维护注释：验收明确要求 Registry 单一判定、Router 完成优先排序、Shell 专用 navigationTitle 三段链路，防止未来 UI 重构重新混排。
A.PersistenceSaveReadbackTransportContractVersion = 1 -- 中文维护注释：v1 表示 Acceptance 已要求 Framework3 Transport v2 + mismatch 字段级诊断证据；旧 Transport v1 仅允许读取迁移，禁止继续作为新写格式。
A.TeamDefaultsLayoutContractVersion = 1 -- 中文维护注释：v1 固化自动职责/牺牲之舞 fresh default=on、旧显式关闭兼容，以及团队中心职责/辅助分区；不授予任何额外 Native 写权限。

local MIGRATED_MODAL_MODULES = {
    ["v3_quest_detail_modal"] = "QuestDetailModalV3",
    ["v3_gear_quick_settings_modal"] = "GearQuickSettingsModalV3",
}

-- Single source for the routes that have moved beyond the planned placeholder.
-- Sequence cases reuse this matrix to exercise the actual PageHost build path.
A.migratedPresentation = {
    { route = "combat.stats", widget = "combat.dps" },
    { route = "combat.analytics" },
    { route = "combat.healer" },
    { route = "combat.death_review", widget = "combat.death_review" },
    { route = "combat.buff_display", widget = "combat.buff_display" },
    { route = "combat.boss_alerts" },
    { route = "combat.target_monitor" },
    { route = "combat.unit_lines" },
    { route = "combat.range_assist" },
    { route = "combat.buff_cap" },
    { route = "combat.team_tools" },
    { route = "combat.raid_recruitment" },
    { route = "combat.siege_readiness" },
    { route = "combat.gear", widget = "combat.gear.quick", modal = "v3_gear_quick_settings_modal" },
    { route = "life.activities", widget = "life.activities", modal = "v3_quest_detail_modal" },
    { route = "life.trade", widget = "life.trade" },
    { route = "life.bonds", widget = "life.bonds" },
    { route = "life.treasure" },
    { route = "life.fishing" },
    { route = "life.craft_planner" },
    { route = "life.housing" },
    { route = "life.butler" },
    { route = "life.tasks", widget = "life.tasks" },
    { route = "tools.instance_browser" },
    { route = "tools.bag_organizer" },
    { route = "tools.craft_assist" },
    { route = "tools.auction_favorites" },
    { route = "tools.market_analysis" },
    { route = "tools.social" },
    { route = "tools.hotkey_profiles" },
    { route = "tools.portal_profiles" },
    { route = "tools.reinforce_analysis" },
    { route = "tools.random_shop" },
    { route = "combat.raid_readiness" },
}

local HARD_FLAGS = {
    text_overflow = true,
    x_out_of_bounds = true,
    y_out_of_bounds = true,
    sibling_overlap = true,
    overflow = true,
}

local function CountMap(tbl)
    local count = 0
    for _ in pairs(type(tbl) == "table" and tbl or {}) do count = count + 1 end
    return count
end

local function CountHard(component)
    if component == nil or S.RSUI == nil or type(S.RSUI.InspectLayout) ~= "function" then return 0, {} end
    local audit = S.RSUI:InspectLayout(component, { maxNodes = 1024, maxDepth = 40 })
    if audit.ok ~= true then return 1, { "inspect_failed" } end
    local count, details = 0, {}
    for _, issue in ipairs(audit.issues or {}) do
        for _, flag in ipairs(issue.flags or {}) do
            if HARD_FLAGS[flag] then
                count = count + 1
                if #details < 16 then details[#details + 1] = tostring(issue.id or "?") .. ":" .. tostring(flag) end
                break
            end
        end
    end
    return count, details
end

function A:RunMatrix()
    local failures = {}
    local router = S.UIV3 and S.UIV3.Router or nil
    local registry = S.FeatureRegistry
    if router == nil then failures[#failures + 1] = "router_missing" end
    if registry == nil then failures[#failures + 1] = "feature_registry_missing" end
    if router ~= nil and ((tonumber(router.version) or 0) < 2 or (tonumber(router.DevelopmentOrderContractVersion) or 0) < 1) then failures[#failures + 1] = "navigation_development_order_contract" end -- 中文维护注释：Router 必须显式声明开发态排序契约，避免仅靠当前偶然顺序通过。
    if router ~= nil and registry ~= nil then
        local seen = {}
        for _, feature in ipairs(registry:List()) do
            if seen[feature.route] then failures[#failures + 1] = "duplicate_route:" .. feature.route end
            seen[feature.route] = true
            local routeRow = router:Get(feature.route) -- 中文维护注释：同一 Router row 同时用于注册完整性与开发态展示一致性校验，不创建页面或 Consumer。
            if routeRow == nil then failures[#failures + 1] = "unregistered_route:" .. feature.route end
            if routeRow ~= nil and feature.navigationVisible ~= false then -- 中文维护注释：只有左侧真实可见入口需要“未完成”标签；隐藏团队子路由保持原业务标题。
                if routeRow.navigationIncomplete ~= (feature.navigationIncomplete == true) then failures[#failures + 1] = "navigation_development_state_drift:" .. feature.id end -- 中文维护注释：Registry 是唯一完成度判定 Authority，Router 不允许出现第二份不同结果。
                local expectedNavigationTitle = tostring(feature.name or "") .. (feature.navigationIncomplete == true and "（未完成）" or "") -- 中文维护注释：开发标签只拼接到专用 navigationTitle，不修改 feature.name/routeRow.title。
                if tostring(routeRow.navigationTitle or "") ~= expectedNavigationTitle then failures[#failures + 1] = "navigation_development_title_drift:" .. feature.id end -- 中文维护注释：防止后续 Shell/Router 重构漏后缀或把后缀污染页面语义标题。
            end
            -- Exact Namespace:Method dependencies must exist in the central
            -- capability registry. Semantic group tags such as legacy "MAP"
            -- remain allowed and are intentionally not treated as API names.
            for _, dependency in ipairs(feature.apiDependencies or {}) do
                dependency = tostring(dependency or "")
                if dependency:find(":", 1, true) ~= nil then
                    local info = S.ApiCapabilities and S.ApiCapabilities:Get(dependency) or nil
                    if info == nil then failures[#failures + 1] = "feature_api_unregistered:" .. feature.id .. ":" .. dependency end
                end
            end
        end
    end

    local windowing = S.RSUI and S.RSUI.Windowing or nil
    if windowing == nil or (tonumber(windowing.version) or 0) < 11 then failures[#failures + 1] = "windowing_contract" end
    local pageHost = S.UIV3 and S.UIV3.PageHost or nil
    if pageHost == nil or (tonumber(pageHost.version) or 0) < 4 or (tonumber(pageHost.buildTransactionContractVersion) or 0) < 1 then
        failures[#failures + 1] = "page_host_build_transaction_contract"
    end
    local businessPagesContract = S.UIV3 and S.UIV3.BusinessPagesContract or nil
    if type(businessPagesContract) ~= "table" or (tonumber(businessPagesContract.version) or 0) < 1
            or (tonumber(businessPagesContract.componentIdContractVersion) or 0) < 1 then
        failures[#failures + 1] = "business_page_component_id_contract"
    end
    if type(businessPagesContract) ~= "table" or (tonumber(businessPagesContract.version) or 0) < 5
            or (tonumber(businessPagesContract.unitLineSettingsFoundationConsumerContractVersion) or 0) < 2 then
        failures[#failures + 1] = "unit_line_settings_page_contract"
    end
    local shellStore = S.Persistence and type(S.Persistence.GetStore) == "function" and S.Persistence:GetStore("v3.shell") or nil
    if type(shellStore) ~= "table" or tonumber(shellStore.schemaVersion) ~= 7
            or tonumber(shellStore.legacySchemaVersion) ~= 6
            or type(shellStore.rebuildCanonicalForIntegrity) ~= "function"
            or type(shellStore.recoverKnownLegacyCanonical) ~= "function"
            or type(S.UIV3) ~= "table"
            or (tonumber(S.UIV3.ShellCanonicalMigrationContractVersion) or 0) < 1
            or (tonumber(S.UIV3.ShellKnownLegacyRecoveryContractVersion) or 0) < 1
            or (tonumber(S.UIV3.ShellStoreSchemaContractVersion) or 0) < 7 then
        failures[#failures + 1] = "shell_persistence_schema_v7_contract"
    end
    if S.RSUI == nil or (tonumber(S.RSUI.StrictBuildFailFastContractVersion) or 0) < 1 then
        failures[#failures + 1] = "strict_build_fail_fast_contract"
    end
    local widgetHost = S.UIV3 and S.UIV3.WidgetHost or nil
    if widgetHost == nil or (tonumber(widgetHost.version) or 0) < 13 or (tonumber(widgetHost.buildTransactionContractVersion) or 0) < 1 or type(widgetHost.SetMinimized) ~= "function"
        or type(widgetHost.NotifyWindowClosed) ~= "function" or type(widgetHost.BindFeatureLifecycle) ~= "function"
        or type(widgetHost.RequestClose) ~= "function" or type(widgetHost.NotifyProjectionChanged) ~= "function" then
        failures[#failures + 1] = "widget_host_contract"
    end

    -- Migrated routes must resolve to their specialized presentation factories.
    -- Planned registry entries may intentionally use the fallback placeholder,
    -- but an active migrated route must never silently do so.
    local matrixRoutes = {}
    for _, item in ipairs(A.migratedPresentation) do
        local route = tostring(item.route or "")
        if route == "" then
            failures[#failures + 1] = "migrated_matrix_empty_route"
        elseif matrixRoutes[route] then
            failures[#failures + 1] = "migrated_matrix_duplicate_route:" .. route
        else
            matrixRoutes[route] = true
        end
        if registry ~= nil and type(registry.GetByRoute) == "function" and registry:GetByRoute(route) == nil then
            failures[#failures + 1] = "migrated_matrix_unregistered_route:" .. route
        end
        local factoryOk = type(pageHost) == "table" and type(pageHost.factories) == "table"
            and type(pageHost.factories[route]) == "function"
        if not factoryOk then failures[#failures + 1] = "missing_migrated_page_factory:" .. route end
        if item.widget ~= nil then
            local widgetOk = type(widgetHost) == "table" and type(widgetHost.GetSpec) == "function"
                and widgetHost:GetSpec(item.widget) ~= nil
            if not widgetOk then failures[#failures + 1] = "missing_migrated_widget_spec:" .. item.widget end
        end
        if item.modal ~= nil then
            local modalId = tostring(item.modal)
            local moduleName = MIGRATED_MODAL_MODULES[modalId]
            local modal = moduleName ~= nil and S.UIV3 and S.UIV3[moduleName] or nil
            if moduleName == nil or type(modal) ~= "table" or tostring(modal.id or "") ~= modalId
                or type(modal.EnsureCreated) ~= "function" or type(modal.Close) ~= "function" then
                failures[#failures + 1] = "missing_migrated_modal_contract:" .. modalId
            end
        end
    end

    -- The M1.16 life pages share one Presentation builder, so factory presence
    -- alone is not enough evidence. Validate the exact public read-model and
    -- command facades consumed by that builder; this catches a missing Feature
    -- projection before the first Native page allocation on RU.
    local lifeContracts = {
        { name = "Trade", id = "life_trade", methods = { "GetProjection", "GetRouteSettings", "GetFavoriteItems", "GetRow", "GetWidgetVisible", "GetWidgetWindowState", "AcquireConsumer", "ReleaseConsumer" }, commands = { "Refresh", "SetFrom", "SetTo", "SetSortMode", "ToggleCurrentFavorite", "SelectFavorite", "SelectRow", "QuotePendingMaterials", "QuoteRowMaterials", "GetWidgetVisible", "SetWidgetVisible", "SetWidgetWindowState" } },
        { name = "Bonds", id = "life_bonds", methods = { "GetProjection", "GetSortMode", "GetBondFilter", "GetWidgetVisible", "GetWidgetWindowState", "AcquireConsumer", "ReleaseConsumer" }, commands = { "Refresh", "SetSortMode", "SetBondFilterOption", "SetDuplicatePriority", "GetWidgetVisible", "SetWidgetVisible", "SetWidgetWindowState" } },
        { name = "Treasure", id = "life_treasure", methods = { "GetProjection", "GetWidgetVisible", "GetWidgetWindowState", "AcquireConsumer", "ReleaseConsumer" }, commands = { "Refresh", "Select", "GetWidgetVisible", "SetWidgetVisible", "SetWidgetWindowState" } },
        { name = "Fishing", id = "life_fishing", methods = { "GetProjection", "GetWidgetVisible", "GetWidgetWindowState", "IsAutoArmed", "AcquireConsumer", "ReleaseConsumer" }, commands = { "Refresh", "GetWidgetVisible", "SetWidgetVisible", "SetWidgetWindowState", "ArmAuto", "DisarmAuto" } },
    }
    for _, contract in ipairs(lifeContracts) do
        local feature = S.Features and S.Features[contract.name] or nil
        local valid = type(feature) == "table"
            and S.FeatureRuntime ~= nil and S.FeatureRuntime:IsImplemented(contract.id) == true
            and type(feature.Commands) == "table"
        if valid then
            for _, method in ipairs(contract.methods) do
                if type(feature[method]) ~= "function" then valid = false; break end
            end
        end
        if valid then
            for _, command in ipairs(contract.commands) do
                if type(feature.Commands[command]) ~= "function" then valid = false; break end
            end
        end
        if not valid then failures[#failures + 1] = "life_m16_feature_contract:" .. contract.id end
    end

    local businessTruth = {
        { id = "combat_boss_alerts", status = "migrated_partial" },
        { id = "combat_unit_lines", status = "migrated_partial" },
        { id = "combat_range_assist", status = "migrated_partial" },
        { id = "combat_buff_cap", status = "migrated_partial" },
        { id = "combat_team_tools", status = "migrated_partial" },
        { id = "combat_raid_recruitment", status = "migrated_partial" },
        { id = "life_trade", status = "migrated_partial" },
        { id = "life_fishing", status = "migrated_partial" },
        { id = "life_craft_planner", status = "migrated_partial" },
        { id = "tools_bag", status = "migrated_partial" },
        { id = "tools_auction", status = "migrated_partial" },
        { id = "tools_market_analysis", status = "migrated_partial" },
        { id = "tools_craft", status = "migrated_partial" },
    }
    for _, expected in ipairs(businessTruth) do
        local row = registry and registry:Get(expected.id) or nil
        if row == nil or tostring(row.status or "") ~= expected.status then
            failures[#failures + 1] = "feature_truth_status:" .. expected.id .. ":" .. tostring(row and row.status or "missing")
        end
    end


    local bagTools = S.Features and S.Features.tools_bag or nil
    local bagQuickPresenter = S.UIV3 and S.UIV3.BagQuickOverlay or nil
    local inventorySnapshot = S.Services and S.Services.InventorySnapshotV3 or nil
    if type(inventorySnapshot) ~= "table" or (tonumber(inventorySnapshot.SnapshotContractVersion) or 0) < 1
        or (tonumber(inventorySnapshot.PhysicalBagAuthorityContractVersion) or 0) < 1
        or tonumber(inventorySnapshot.PreferredBagId) ~= 1 or tonumber(inventorySnapshot.FallbackBagId) ~= 0
        or type(inventorySnapshot.BuildSnapshot) ~= "function" or type(inventorySnapshot.FindLiveRow) ~= "function"
        or type(bagTools) ~= "table" or (tonumber(bagTools.BagMoveContractVersion) or 0) < 8
        or (tonumber(bagTools.BatchLifecycleContractVersion) or 0) < 5 or (tonumber(bagTools.NativeWindowQuickContractVersion) or 0) < 7
        or (tonumber(bagTools.ReloadQuickObserverContractVersion) or 0) < 3
        or (tonumber(bagTools.ResponsiveWindowObserverContractVersion) or 0) < 1
        or (tonumber(bagTools.ProductBlacklistUxContractVersion) or 0) < 1
        or (tonumber(bagTools.BlacklistNameMetadataContractVersion) or 0) < 1
        or (tonumber(bagTools.BlacklistExplicitLookupContractVersion) or 0) < 1
        or (tonumber(bagTools.RUFourValueWindowVisibilityContractVersion) or 0) < 2
        or (tonumber(bagTools.NativeVisibilityShapeContractVersion) or 0) < 1
        or (tonumber(bagTools.SurfaceVisibilitySplitContractVersion) or 0) < 1
        or (tonumber(bagTools.StorageSessionBagSurfaceContractVersion) or 0) < 1
        or (tonumber(bagTools.BagActionPhysicalReadAuthorityContractVersion) or 0) < 1
        or (tonumber(bagTools.VisiblePresenterRetryContractVersion) or 0) < 1
        or (tonumber(bagTools.DynamicSourceResolutionContractVersion) or 0) < 3
        or (tonumber(bagTools.QuickIdentityFallbackContractVersion) or 0) < 1
        -- Mutex v2: an empty plan must never hold the quick mutex, and a queue
        -- that lost its executor must be reclaimed (.18.183 "click does nothing").
        or (tonumber(bagTools.BagTaskMutexContractVersion) or 0) < 2
        or (tonumber(bagTools.QuickRunSelfHealContractVersion) or 0) < 1
        or (tonumber(bagTools.QuickTwoButtonContractVersion) or 0) < 1
        or (tonumber(bagTools.QuickReasonVisibilityContractVersion) or 0) < 1
        or (tonumber(bagTools.QuickStatusTimestampContractVersion) or 0) < 1
        or (tonumber(bagTools.InventorySnapshotContractVersion) or 0) < 1
        or (tonumber(bagTools.GroupedIntentQueueContractVersion) or 0) < 1
        or (tonumber(bagTools.FullStorageContinuationContractVersion) or 0) < 1
        or type(bagTools.Commands) ~= "table" or type(bagTools.Commands.QuickWithdraw) ~= "function"
        or type(bagTools.Commands.ResolveAndAddBlacklistItem) ~= "function"
        or type(bagTools.Commands.AddGlobalBlacklistItem) ~= "function"
        or type(bagTools.Commands.RemoveGlobalBlacklistItem) ~= "function"
        or type(bagTools.Commands.QuickDeposit) ~= "function" or type(bagTools.Commands.QuickCancel) ~= "function"
        or type(bagTools.Commands.SetBatchCategory) ~= "function" or type(bagTools.Commands.SetBatchTarget) ~= "function"
        or type(bagTools.Commands.SetBatchLimit) ~= "function"
        -- Category batch resolves its target from the open storage window; the old
        -- bank/coffer choice is gone from the page (.18.183 user report).
        or type(bagTools.Commands.DepositCategoryCurrent) ~= "function"
        or (tonumber(bagTools.BatchTargetAutoContractVersion) or 0) < 1
        or type(businessPagesContract) ~= "table" or (tonumber(businessPagesContract.bagProductUxContractVersion) or 0) < 2
        or type(bagQuickPresenter) ~= "table" or (tonumber(bagQuickPresenter.version) or 0) < 9
        or (tonumber(bagQuickPresenter.ReleasedRootRecoveryContractVersion) or 0) < 1
        or (tonumber(bagQuickPresenter.ReloadVisibilityContractVersion) or 0) < 2
        or (tonumber(bagQuickPresenter.NativeTransientHostContractVersion) or 0) < 2
        or (tonumber(bagQuickPresenter.VisibleRetryContractVersion) or 0) < 2
        or (tonumber(bagQuickPresenter.TwoButtonContractVersion) or 0) < 1
        or (tonumber(bagQuickPresenter.DiffRenderContractVersion) or 0) < 1
        or (tonumber(bagQuickPresenter.HintYieldContractVersion) or 0) < 1
        or (tonumber(bagQuickPresenter.QuietByDefaultContractVersion) or 0) < 1 then
        failures[#failures + 1] = "bag_quick_take_put_contract_v13"
    end

    local gearFeature = S.Features and S.Features.Gear or nil
    if type(S.FeatureRuntime) ~= "table" or (tonumber(S.FeatureRuntime.StartupEnableIntentContractVersion) or 0) < 1
        or type(gearFeature) ~= "table" or (tonumber(gearFeature.QuickStartupIntentContractVersion) or 0) < 1
        or type(gearFeature.GetStartupEnableIntent) ~= "function" or type(gearFeature.OnStartupEnableIntentCommitted) ~= "function"
        or type(gearFeature.ShouldShowQuickButtons) ~= "function" then
        failures[#failures + 1] = "quick_surface_reload_reconcile_contract_v3"
    end

    local auctionQuery = S.Services and S.Services.AuctionQueryV3 or nil
    local auction = S.Features and S.Features.tools_auction or nil
    local market = S.Features and S.Features.tools_market_analysis or nil
    if type(auctionQuery) ~= "table" or (tonumber(auctionQuery.version) or 0) < 2 or (tonumber(auctionQuery.EventAuthorityContractVersion) or 0) < 1
        or tostring(auctionQuery.presentationBoundary or "") ~= "service_only"
        or type(auctionQuery.Search) ~= "function" or type(auctionQuery.GetSnapshot) ~= "function"
        or type(auction) ~= "table" or (tonumber(auction.AuctionQueryContractVersion) or 0) < 1 or type(auction.Commands.Search) ~= "function"
        or type(market) ~= "table" or (tonumber(market.AuctionQueryContractVersion) or 0) < 1 or type(market.Commands.Search) ~= "function" then
        failures[#failures + 1] = "auction_query_contract_v2"
    end
    local auctionSurface = S.Services and S.Services.AuctionSurfaceV3 or nil
    local auctionSidecar = S.UIV3 and S.UIV3.AuctionSidecar or nil
    if type(auctionSurface) ~= "table" or (tonumber(auctionSurface.version) or 0) < 2
        or tostring(auctionSurface.presentationBoundary or "") ~= "service_only"
        or (tonumber(auctionSurface.VisibilityContractVersion) or 0) < 2
        or type(auctionSurface.GetSnapshot) ~= "function" or type(auctionSurface.Start) ~= "function" or type(auctionSurface.Stop) ~= "function"
        or type(auctionSidecar) ~= "table" then
        failures[#failures + 1] = "auction_sidecar_contract_v2"
    end

    for _, craftId in ipairs({ "life_craft_planner", "tools_craft" }) do
        local craftFeature = S.Features and S.Features[craftId] or nil
        if type(craftFeature) ~= "table" or (tonumber(craftFeature.CraftUserSelectionContractVersion) or 0) < 1
            or type(craftFeature.Commands) ~= "table" or type(craftFeature.Commands.SelectRecipe) ~= "function" then
            failures[#failures + 1] = "craft_user_selection_contract:" .. craftId
        end
    end

    local craftPlanner = S.Features and S.Features.life_craft_planner or nil
    if type(craftPlanner) ~= "table" or (tonumber(craftPlanner.CraftPlanContractVersion) or 0) < 1
        or type(craftPlanner.Commands) ~= "table" or type(craftPlanner.Commands.AddPlanRecipe) ~= "function"
        or type(craftPlanner.Commands.RemovePlanRecipe) ~= "function" or type(craftPlanner.Commands.ClearPlan) ~= "function"
        or type(craftPlanner.Commands.QuotePlanMaterials) ~= "function" then
        failures[#failures + 1] = "craft_plan_contract_v1"
    end
    local craftSurface = S.Services and S.Services.CraftSurfaceV3 or nil
    local craftSidecar = S.UIV3 and S.UIV3.CraftSidecar or nil
    local craftAssistant = S.Features and S.Features.tools_craft or nil
    if type(craftSurface) ~= "table" or (tonumber(craftSurface.version) or 0) < 1
        or tostring(craftSurface.presentationBoundary or "") ~= "service_only"
        or (tonumber(craftSurface.VisibilityContractVersion) or 0) < 1
        or type(craftSurface.GetSnapshot) ~= "function" or type(craftSurface.Start) ~= "function" or type(craftSurface.Stop) ~= "function"
        or type(craftSidecar) ~= "table" or type(craftAssistant) ~= "table"
        or (tonumber(craftAssistant.CraftSidecarContractVersion) or 0) < 1
        or type(craftAssistant.Commands) ~= "table" or type(craftAssistant.Commands.SetAutoSidecar) ~= "function" then
        failures[#failures + 1] = "craft_sidecar_contract_v1"
    end

    local teamTools = S.Features and S.Features.combat_team_tools or nil
    local teamRoleCatalog = S.Data and S.Data.TeamAutoRoleCatalog or nil
    local archerRole = type(teamRoleCatalog) == "table" and type(teamRoleCatalog.byClassKey) == "table"
        and teamRoleCatalog.byClassKey["name_6_8_9"] or nil
    if type(teamTools) ~= "table" or (tonumber(teamTools.TeamRoleContractVersion) or 0) < 2
        or (tonumber(teamTools.AutoRoleCatalogContractVersion) or 0) < 1
        or type(teamTools.Commands) ~= "table" or type(teamTools.Commands.SetRole) ~= "function"
        or type(teamRoleCatalog) ~= "table" or (tonumber(teamRoleCatalog.version) or 0) < 2
        or type(archerRole) ~= "table" or tostring(archerRole.role or "") ~= "ranged" then
        failures[#failures + 1] = "team_role_catalog_contract_v3"
    end
    local teamSacOverlay = S.UIV3 and S.UIV3.TeamSacOverlay or nil
    if type(teamTools) ~= "table" or (tonumber(teamTools.TeamVisualContractVersion) or 0) < 2 -- 中文维护注释：v2 要求新用户牺牲之舞默认开启且 schema1 旧关闭可迁移；Consumer 生命周期仍由 Feature Demand 控制。
        or (tonumber(teamTools.TeamMarkerSnapshotContractVersion) or 0) < 1 -- 中文维护注释：标记恢复继续执行原串行 readback 校验，本轮不改写 marker 权限边界。
        or (tonumber(teamTools.TeamSacContractVersion) or 0) < 2 -- 中文维护注释：拒绝遗漏 schema2/default-on Store 的增量包。
        or (tonumber(teamTools.AutoRoleDefaultOnContractVersion) or 0) < 1 -- 中文维护注释：自动职责空 Store 默认 true 与旧 false 保留必须同时存在。
        or type(teamTools.Commands) ~= "table"
        or type(teamTools.Commands.SetSacHighlightEnabled) ~= "function"
        or type(teamTools.Commands.SaveRaidMarkers) ~= "function"
        or type(teamTools.Commands.RestoreRaidMarkers) ~= "function"
        or type(teamSacOverlay) ~= "table" or (tonumber(teamSacOverlay.TeamSacPresentationContractVersion) or 0) < 1 then
        failures[#failures + 1] = "team_visual_marker_contract_v2" -- 中文维护注释：故障键升 v2，实机诊断可直接区分“旧视觉契约缺失”与“.18.197 默认值/迁移遗漏”。
    end
    local businessPagesContract = S.UIV3 and S.UIV3.BusinessPagesContract or nil -- 中文维护注释：团队中心布局属于 Presentation contract；这里只验证分区版本，不把页面结构反向作为 TeamTools Domain Authority。
    if type(businessPagesContract) ~= "table" or (tonumber(businessPagesContract.teamCenterLayoutContractVersion) or 0) < 1 then
        failures[#failures + 1] = "team_center_layout_contract_v1" -- 中文维护注释：防止后续页面合并时重新露出已安全停用的成员移动表单或恢复无意义成本列。
    end

    local buffCap = S.Features and S.Features.combat_buff_cap or nil
    if type(buffCap) ~= "table" or (tonumber(buffCap.ObservationContractVersion) or 0) < 1
        or type(buffCap.UpdateTopic) ~= "string" then
        failures[#failures + 1] = "buff_cap_observation_contract"
    end

    local activities = S.Features and S.Features.Activities or nil
    local activityStore = S.Persistence ~= nil and type(S.Persistence.GetStore) == "function" and S.Persistence:GetStore("v3.activities") or nil -- 中文维护注释：Acceptance 只检查 Store spec，不主动读取用户存档，避免启动期为验收增加 SaveData I/O。
    if type(activities) ~= "table" or (tonumber(activities.PersistenceStoreSchemaContractVersion) or 0) < 8
        or (tonumber(activities.KnownLegacyCanonicalRecoveryContractVersion) or 0) < 3
        or (tonumber(activities.TransportV1ZeroOmissionRecoveryContractVersion) or 0) < 1 -- 中文维护注释：`.18.198` 要求零值省略结构化恢复随包存在；它与 known-pair 互为先后层级，缺一不可。
        or type(activityStore) ~= "table" or tonumber(activityStore.schemaVersion) ~= 8
        or type(activityStore.recoverKnownLegacyCanonical) ~= "function" or activityStore.allowIntegrityUpgrade ~= true
        or type(activityStore.rebuildCanonicalForIntegrity) ~= "function" then
        failures[#failures + 1] = "activity_persistence_recovery_contract_v3" -- 中文维护注释：`.18.198` 起 schema8/Transport-v1 走零值省略结构化 exact 恢复，6963CEA5→109696BD 只作为更早世代兜底；未知 mismatch 不能被此 Gate 放宽。
    end
    local tasks = S.Features and S.Features.Tasks or nil
    if type(activities) ~= "table" or (tonumber(activities.PersistenceMutationContractVersion) or 0) < 2
        or type(tasks) ~= "table" or (tonumber(tasks.PersistenceMutationContractVersion) or 0) < 2 then
        failures[#failures + 1] = "specialized_persistence_mutation_contract_v2"
    end
    if type(tasks) ~= "table" or (tonumber(tasks.PersistenceCodecVersion) or 0) < 2 then
        failures[#failures + 1] = "task_persistence_stable_codec_v2"
    end

    local social = S.Features and S.Features.tools_social or nil
    if type(social) ~= "table" or type(social.Commands) ~= "table"
        or type(social.Commands.Block) ~= "function" or type(social.Commands.Unblock) ~= "function"
        or type(social.Commands.Mute) ~= "function" or type(social.Commands.Unmute) ~= "function"
        or type(social.Commands.IsFriend) ~= "function" then
        failures[#failures + 1] = "social_action_contract"
    end

    local api = S.Api
    if type(api) ~= "table" or (tonumber(api.CapabilityCooldownContractVersion) or 0) < 1
        or type(api.ConsumeCapabilityCooldown) ~= "function" or type(api.GetCapabilityCooldownState) ~= "function" then
        failures[#failures + 1] = "api_capability_cooldown_contract"
    end

    local targetMonitor = S.Features and S.Features.combat_target_monitor or nil
    local treasure = S.Features and S.Features.Treasure or nil
    local fishing = S.Features and S.Features.Fishing or nil
    if type(targetMonitor) ~= "table" or (tonumber(targetMonitor.ObservationContractVersion) or 0) < 1 or type(targetMonitor.UpdateTopic) ~= "string" then
        failures[#failures + 1] = "target_monitor_observation_contract"
    end
    if type(treasure) ~= "table" or (tonumber(treasure.ObservationContractVersion) or 0) < 1 or type(treasure.UpdateTopic) ~= "string" then
        failures[#failures + 1] = "treasure_observation_contract"
    end
    if type(fishing) ~= "table" or (tonumber(fishing.ObservationContractVersion) or 0) < 1 or type(fishing.UpdateTopic) ~= "string" then
        failures[#failures + 1] = "fishing_observation_contract"
    end

    -- M1.16.0.18.43 usability recovery: these contracts prove that the newly
    -- visible HUD/screen capabilities are real runtime surfaces, not page-only
    -- labels.  Checks are read-only and allocate no Native widgets.
    local screenProjection = S.Services and S.Services.ScreenProjectionV3 or nil
    if type(screenProjection) ~= "table" or (tonumber(screenProjection.version) or 0) < 13 or tostring(screenProjection.presentationBoundary or "") ~= "service_only"
        or type(screenProjection.ProjectUnitFlexible) ~= "function" or type(screenProjection.ProjectUnitBatch) ~= "function"
        or (tonumber(screenProjection.FrontHemisphereBatchContractVersion) or 0) < 1
        or (tonumber(screenProjection.UnitProjectionConsistencyContractVersion) or 0) < 1
        or (tonumber(screenProjection.UnitWorldAliasGuardContractVersion) or 0) < 1
        or (tonumber(screenProjection.WorldBatchIndexContractVersion) or 0) < 1
        or (tonumber(screenProjection.WorldBatchFactsContractVersion) or 0) < 1
        or (tonumber(screenProjection.CameraUnavailableNativeFallbackContractVersion) or 0) < 1
        or (tonumber(screenProjection.UiParentScreenCoordinateContractVersion) or 0) < 1
        or type(screenProjection.ProjectWorld) ~= "function"
        or type(screenProjection.ProjectWorldBatch) ~= "function" or type(screenProjection.GetUnitWorldPosition) ~= "function" then
        failures[#failures + 1] = "screen_projection_v3_contract"
    end
    local alerts = S.Services and S.Services.Alerts or nil
    local alertHud = S.UIV3 and S.UIV3.AlertHudV3 or nil
    if type(alerts) ~= "table" or type(alerts.Push) ~= "function" or type(alerts.SetPresenter) ~= "function"
        or type(alertHud) ~= "table" or (tonumber(alertHud.version) or 0) < 1 or type(alertHud.Describe) ~= "function" then
        failures[#failures + 1] = "boss_alert_hud_contract"
    end
    local bossAlerts = S.Features and S.Features.combat_boss_alerts or nil
    if type(bossAlerts) ~= "table" or (tonumber(bossAlerts.HudContractVersion) or 0) < 2
        or (tonumber(bossAlerts.RealtimeFactBridgeContractVersion) or 0) < 1
        or type(S.Services and S.Services.CastingObservationV3) ~= "table"
        or type(bossAlerts.Commands) ~= "table" or type(bossAlerts.Commands.TestBigText) ~= "function"
        or type(bossAlerts.Commands.TestCountdown) ~= "function" or type(bossAlerts.Commands.SetHudEnabled) ~= "function" then
        failures[#failures + 1] = "boss_alert_feature_hud_contract"
    end
    local visualGuides = S.UIV3 and S.UIV3.CombatVisualGuidesV3 or nil
    local unitLines = S.Features and S.Features.combat_unit_lines or nil
    local rangeAssist = S.Features and S.Features.combat_range_assist or nil
    if type(visualGuides) ~= "table" or (tonumber(visualGuides.version) or 0) < 11 or type(visualGuides.Describe) ~= "function"
        or (tonumber(visualGuides.AdaptiveUnitLineSamplingContractVersion) or 0) < 2
        or (tonumber(visualGuides.UnitLineVisibleSegmentClippingContractVersion) or 0) < 1
        or (tonumber(visualGuides.UnitLinePressureBudgetContractVersion) or 0) < 1
        or (tonumber(visualGuides.UnitLineDiffRenderContractVersion) or 0) < 1
        or (tonumber(visualGuides.UnitLineProgressivePoolContractVersion) or 0) < 1
        or (tonumber(visualGuides.UnitLineRawProjectedAnchorContractVersion) or 0) < 2
        or (tonumber(visualGuides.ScreenToOverlayHostContractVersion) or 0) < 1
        or (tonumber(visualGuides.ResolutionIndependentOverlayContractVersion) or 0) < 1
        or type(visualGuides.BuildUnitLineSamplePlan) ~= "function" then
        failures[#failures + 1] = "combat_visual_guides_presenter_contract"
    end
    if type(unitLines) ~= "table" or (tonumber(unitLines.VisualGuideContractVersion) or 0) < 5
        or (tonumber(unitLines.AdaptiveDensityContractVersion) or 0) < 2
        or (tonumber(unitLines.SmoothRefreshContractVersion) or 0) < 1
        or (tonumber(unitLines.FrontHemisphereContractVersion) or 0) < 1
        or (tonumber(unitLines.ProjectionConsistencyContractVersion) or 0) < 1
        or type(unitLines.Commands) ~= "table" or type(unitLines.Commands.SetPointCount) ~= "function"
        or type(unitLines.Commands.SetPointSize) ~= "function" or type(unitLines.Commands.SetOpacity) ~= "function"
        or type(unitLines.Commands.SetRefreshMs) ~= "function" or type(unitLines.Commands.SetPairEnabled) ~= "function" then
        failures[#failures + 1] = "unit_lines_visual_contract"
    end
    if type(rangeAssist) ~= "table" or (tonumber(rangeAssist.VisualGuideContractVersion) or 0) < 7
        or (tonumber(rangeAssist.WorldSpaceContractVersion) or 0) < 2
        or (tonumber(rangeAssist.ProjectionFactsContractVersion) or 0) < 5
        or (tonumber(rangeAssist.AnchorCalibrationContractVersion) or 0) < 1
        or type(rangeAssist.Commands) ~= "table" or type(rangeAssist.Commands.SetRadius) ~= "function"
        or type(rangeAssist.Commands.SetPointCount) ~= "function" or type(rangeAssist.Commands.SetOpacity) ~= "function"
        or type(rangeAssist.Commands.SetColor) ~= "function" then
        failures[#failures + 1] = "range_assist_visual_contract"
    end
    local lifeWidgets = S.UIV3 and S.UIV3.LifeEconomyWidgetsV3 or nil
    local buffHeadMarkers = S.UIV3 and S.UIV3.BuffHeadMarkersV3 or nil
    local tradeWidget = type(widgetHost) == "table" and type(widgetHost.GetSpec) == "function" and widgetHost:GetSpec("life.trade") or nil
    local bondsWidget = type(widgetHost) == "table" and type(widgetHost.GetSpec) == "function" and widgetHost:GetSpec("life.bonds") or nil
    local treasureWidget = type(widgetHost) == "table" and type(widgetHost.GetSpec) == "function" and widgetHost:GetSpec("life.treasure") or nil
    local fishingWidget = type(widgetHost) == "table" and type(widgetHost.GetSpec) == "function" and widgetHost:GetSpec("life.fishing") or nil
    if type(lifeWidgets) ~= "table" or (tonumber(lifeWidgets.version) or 0) < 2
        or type(tradeWidget) ~= "table" or tradeWidget.featureId ~= "life_trade"
        or type(bondsWidget) ~= "table" or bondsWidget.featureId ~= "life_bonds"
        or type(treasureWidget) ~= "table" or treasureWidget.featureId ~= "life_treasure"
        or type(fishingWidget) ~= "table" or fishingWidget.featureId ~= "life_fishing" then
        failures[#failures + 1] = "life_economy_widget_contract_v2"
    end
    -- 中文维护注释（.18.208 状态显示装备分数边界）：Presentation acceptance 只证明
    -- Feature 已切到 UnitGearScore(unit, comma=false)、共享 ParseGearScore，以及 Store 已声明
    -- 实机 TARGET|EQUIP 默认模板；不在验收中读目标/装备分数，也不修改 schema5 配置。
    -- 这样热重载旧 Feature/Utils 会明确失败，而不会让 Renderer 静默显示空装分。
    local buffDisplay = S.Features and S.Features.BuffDisplay or nil
    local gearV3 = S.Services and S.Services.GearV3 or nil
    local buffHealth = type(buffDisplay) == "table" and type(buffDisplay.GetHealth) == "function" and buffDisplay:GetHealth() or nil
    if type(buffHealth) ~= "table" or (tonumber(buffHealth.observationContractVersion) or 0) < 2
        or (tonumber(buffDisplay and buffDisplay.EquipmentReadContractVersion) or 0) < 1
        or (tonumber(buffDisplay and buffDisplay.GearScoreApiContractVersion) or 0) < 1
        or (tonumber(buffDisplay and buffDisplay.TargetDefaultTemplateContractVersion) or 0) < 1
        or type(S.Utils) ~= "table" or (tonumber(S.Utils.GearScoreParseContractVersion) or 0) < 1
        or type(S.Utils.ParseGearScore) ~= "function"
        or type(gearV3) ~= "table" or tostring(gearV3.presentationBoundary or "") ~= "service_only" or type(gearV3.GetEquipped) ~= "function"
        or (tonumber(gearV3.version) or 0) < 4 or (tonumber(gearV3.PartialApplyContractVersion) or 0) < 1
        or type(buffDisplay.eventTaskName) ~= "string"
        or type(buffHeadMarkers) ~= "table" or (tonumber(buffHeadMarkers.version) or 0) < 2
        or type(buffHeadMarkers.GetDiagnostics) ~= "function"
        or type(buffHeadMarkers.metrics) ~= "table" or type(buffHeadMarkers.metrics.anchorFailures) ~= "table"
        or (tonumber(buffHeadMarkers.BuffIconFontSizeContractVersion) or 0) < 1
        or (tonumber(buffDisplay.BuffHeadMarkerContractVersion) or 0) < 9
        or type(S.UIV3 and S.UIV3.BuffHeadMarkersV3) ~= "table"
        or (tonumber(S.UIV3.BuffHeadMarkersV3.LiveHudSuppressionContractVersion) or 0) < 1
        or (tonumber(S.UIV3.BuffHeadMarkersV3.EquipmentIndependentOffsetContractVersion) or 0) < 1
        or type(S.UIV3.BuffHeadMarkersV3.SetCalibrationSuppressed) ~= "function"
        or (tonumber(buffDisplay.LayoutAuthorityContractVersion) or 0) < 3
        or (tonumber(buffDisplay.HudCalibrationContractVersion) or 0) < 1
        or tonumber(buffDisplay.SchemaVersion) ~= 5
        or type(S.Services and S.Services.StatusClassificationV3) ~= "table" then
        failures[#failures + 1] = "buff_display_observation_head_marker_contract"
    end
    -- 中文维护注释（HUD 校准 v3 交互边界）：HUD 校准是按需 Presentation，不得通过验收时创建。
    -- .18.206 同时检查屏幕Y适配、面板拖动、上下文控件、全局位置预览、正式 HUD suppression 与
    -- 页面 Measure 契约，防止热重载后混入旧模块。Authority 仍由 BuffDisplay Store/Renderer 持有；
    -- 验收不触碰 Draft、Native geometry 或 Consumer，因此不会把静态检查变成运行时副作用。
    -- .18.207 追加装备局部 offset 与模板快照契约，避免旧 Renderer 继续把前一槽位 x 传给后续
    -- 槽位，也避免旧校准器缺少发行模板导出却仍被视为可用。
    local buffHudCalibration = S.UIV3 and S.UIV3.BuffHudCalibrationV3 or nil
    if type(buffHudCalibration) ~= "table" or (tonumber(buffHudCalibration.version) or 0) < 3
        or (tonumber(buffDisplay and buffDisplay.HudCalibrationPresentationContractVersion) or 0) < 5
        or (tonumber(buffHudCalibration.DiagnosticsContractVersion) or 0) < 4
        or (tonumber(buffHudCalibration.ScreenCoordinateAdapterContractVersion) or 0) < 1
        or (tonumber(buffHudCalibration.PanelDragContractVersion) or 0) < 1
        or (tonumber(buffHudCalibration.ContextualControlsContractVersion) or 0) < 1
        or (tonumber(buffHudCalibration.GlobalPreviewContractVersion) or 0) < 1
        or (tonumber(buffHudCalibration.LiveHudSuppressionContractVersion) or 0) < 1
        or (tonumber(buffHudCalibration.TemplateSnapshotContractVersion) or 0) < 1
        or type(buffHudCalibration.BuildTemplateSnapshotLines) ~= "function" or type(buffHudCalibration.OutputTemplateSnapshot) ~= "function"
        or type(buffHudCalibration.ToggleGlobalPreview) ~= "function"
        or type(buffHudCalibration.Open) ~= "function" or type(buffHudCalibration.Exit) ~= "function"
        or type(buffHudCalibration.SyncPlayerToTarget) ~= "function" or type(buffHudCalibration.GetDiagnostics) ~= "function"
        or (tonumber(buffDisplay and buffDisplay.HudLayoutPageMeasureContractVersion) or 0) < 1
        or type(S.DiagnosticsManager) ~= "table" or type(S.DiagnosticsManager.BuildBuffHudReport) ~= "function" then
        failures[#failures + 1] = "buff_display_hud_calibration_contract"
    end
    local healerWidgetSpec = type(widgetHost) == "table" and type(widgetHost.GetSpec) == "function" and widgetHost:GetSpec("combat.healer") or nil
    local healerRaidOverlay = S.UIV3 and S.UIV3.HealerRaidOverlay or nil
    local healerStore = S.Persistence and type(S.Persistence.GetStore) == "function" and S.Persistence:GetStore("v3.healer") or nil
    if healerWidgetSpec ~= nil or type(healerRaidOverlay) ~= "table" or (tonumber(healerRaidOverlay.version) or 0) < 3
        or (tonumber(healerRaidOverlay.NativeRosterGeometryContractVersion) or 0) < 2
        or (tonumber(healerRaidOverlay.StackedHalfRosterContractVersion) or 0) < 1
        or (tonumber(healerRaidOverlay.ColumnMajorSlotContractVersion) or 0) < 1
        or type(healerRaidOverlay.Describe) ~= "function" or type(healerStore) ~= "table" or tonumber(healerStore.schemaVersion) ~= 6 then
        failures[#failures + 1] = "healer_native_roster_geometry_contract"
    end

    local windowShell = S.UI and S.UI.WindowShell or nil
    if windowShell == nil or (tonumber(windowShell.version) or 0) < 24 or (tonumber(windowShell.compactMinimizeContract) or 0) < 1
        or (tonumber(windowShell.titleAppearanceContract) or 0) < 3
        or (tonumber(windowShell.topLevelLayerContractVersion) or 0) < 1
        or type(S.UI.CreateWindowShell) ~= "function" then
        failures[#failures + 1] = "window_shell_compact_contract"
    end
    local floatingSurface = S.RSUI and S.RSUI.FloatingSurface or nil
    if floatingSurface == nil or (tonumber(floatingSurface.version) or 0) < 11
        or (tonumber(floatingSurface.CompactMinimizeContractVersion) or 0) < 1
        or (tonumber(floatingSurface.TitleAppearanceContractVersion) or 0) < 1
        or (tonumber(floatingSurface.DetachedStateContractVersion) or 0) < 1
        or (tonumber(floatingSurface.ResponsivePlacementIntentContractVersion) or 0) < 1
        or tonumber(floatingSurface.generation) ~= tonumber(S.Generation)
        or type(floatingSurface.Create) ~= "function" or type(floatingSurface.NormalizeState) ~= "function"
        or type(floatingSurface.CreateStateAdapter) ~= "function" then
        failures[#failures + 1] = "floating_surface_contract"
    end
    local viewState = S.RSUI and S.RSUI.ViewState or nil
    if viewState == nil or (tonumber(viewState.version) or 0) < 2 or tonumber(viewState.generation) ~= tonumber(S.Generation)
        or type(S.RSUI.CreateViewState) ~= "function" or type(viewState.GetSnapshot) ~= "function"
        or type(viewState:GetSnapshot().states) ~= "table" then
        failures[#failures + 1] = "view_state_contract"
    end
    local actionRunner = S.ActionRunner
    if actionRunner == nil or (tonumber(actionRunner.version) or 0) < 1 or type(actionRunner.Run) ~= "function" or type(actionRunner.IsBusy) ~= "function" then
        failures[#failures + 1] = "action_runner_contract"
    end
    local binding = S.UI and S.UI.Binding or nil
    if binding == nil or (tonumber(binding.version) or 0) < 2.3 or type(S.UI.CreatePersistentSettingBinding) ~= "function"
        or type(binding.GetSnapshot) ~= "function" or binding:GetSnapshot().persistentActive == nil then
        failures[#failures + 1] = "persistent_setting_binding_contract"
    end
    local modalHost = S.UIV3 and S.UIV3.ModalHost or nil
    if modalHost == nil or (tonumber(modalHost.version) or 0) < 5 or (tonumber(modalHost.buildTransactionContractVersion) or 0) < 1 then failures[#failures + 1] = "modal_host_contract" end
    local toastHost = S.UIV3 and S.UIV3.ToastHost or nil
    if toastHost == nil or (tonumber(toastHost.version) or 0) < 1 or type(toastHost.Notify) ~= "function" then failures[#failures + 1] = "toast_host_contract" end
    if S.Scheduler == nil or type(S.Scheduler.AddOneShot) ~= "function" then failures[#failures + 1] = "one_shot_scheduler_contract" end
    if S.Scheduler == nil or (tonumber(S.Scheduler.version) or 0) < 2 or type(S.Scheduler.AddInteractiveTask) ~= "function" then failures[#failures + 1] = "interactive_scheduler_contract" end
    if S.Demand == nil or (tonumber(S.Demand.version) or 0) < 2 or type(S.Demand.Create) ~= "function"
        or type(S.Demand.ClearAll) ~= "function" or type(S.Demand.Describe) ~= "function"
        or S.Demand:Describe().quiesceFailures == nil then
        failures[#failures + 1] = "demand_foundation_contract"
    end
    if S.Persistence == nil or type(S.Persistence.ClearStore) ~= "function"
        or type(S.Persistence.CanWrite) ~= "function" or type(S.Persistence.PrepareWrite) ~= "function"
        or type(S.Persistence.MutateStore) ~= "function" or type(S.Persistence.IsStoreLoaded) ~= "function"
        or type(S.Persistence.VerifyPersistedValue) ~= "function"
        or type(S.Persistence.FingerprintEncodedPayload) ~= "function"
        or type(S.Persistence.FingerprintEnvelopeIntegrity) ~= "function"
        or type(S.Persistence.EncodePhysicalEnvelope) ~= "function" or type(S.Persistence.DecodePhysicalEnvelope) ~= "function" -- 中文维护注释：物理 Transport 必须继续由 Persistence Core 单一拥有，业务 Store 不允许自行编码 sentinel。
        or type(S.Persistence.DescribeCanonicalDivergence) ~= "function" or (tonumber(S.Persistence.ReadbackDivergenceDiagnosticsContractVersion) or 0) < 1 -- 中文维护注释：readback mismatch 必须留下字段级证据，未来同类 RU serializer 故障不能再只返回两个 Hash。
        or (tonumber(S.Persistence.FrameworkVersion) or 0) < 3 or (tonumber(S.Persistence.TransportContractVersion) or 0) < 2 -- 中文维护注释：新写必须是 Framework3/Transport2；Transport1 仅兼容读取并迁移，防止 0/空字符串再次被物理省略。
        or type(S.Persistence.Flush) ~= "function"
        or (tonumber(S.Persistence.ReliabilityContractVersion) or 0) < 7
        or (tonumber(S.Persistence.MinIntegrityReliabilityContractVersion) or 0) > 4
        or (tonumber(S.Persistence.IntegrityContractVersion) or 0) < 1
        or (tonumber(S.Persistence.EnvelopeIntegrityContractVersion) or 0) < 1
        or (tonumber(S.Persistence.ScopeBindingContractVersion) or 0) < 1 then
        failures[#failures + 1] = "persistence_hardening_contract"
    end
    if S.RefreshCoordinator == nil or (tonumber(S.RefreshCoordinator.version) or 0) < 1
        or type(S.RefreshCoordinator.Request) ~= "function" or type(S.RefreshCoordinator.CancelOwner) ~= "function" then
        failures[#failures + 1] = "refresh_coordinator_contract"
    end
    local aura = S.Services and S.Services.AuraObservationV3 or nil
    if aura == nil or (tonumber(aura.version) or 0) < 1 or type(aura.AcquireConsumer) ~= "function"
        or type(aura.GetSnapshot) ~= "function" or type(aura.ReleaseConsumer) ~= "function" then
        failures[#failures + 1] = "aura_observation_contract"
    end
    local unitIdentity = S.Services and S.Services.UnitIdentityV3 or nil
    local combatBus = S.Services and S.Services.CombatEventBusV3 or nil
    if unitIdentity == nil or (tonumber(unitIdentity.version) or 0) < 1
        or type(unitIdentity.ResolveCombatEndpoint) ~= "function" or type(unitIdentity.GetById) ~= "function"
        or type(unitIdentity.ParseExplicitKind) ~= "function" or type(unitIdentity.GetHealth) ~= "function" then
        failures[#failures + 1] = "unit_identity_contract"
    end
    if combatBus == nil or (tonumber(combatBus.version) or 0) < 2
        or type(combatBus.Subscribe) ~= "function" or type(combatBus.Unsubscribe) ~= "function"
        or type(combatBus.DescribeEventType) ~= "function" or type(combatBus.ParseAmount) ~= "function"
        or type(combatBus.GetCoverageState) ~= "function" or type(combatBus.GetHealth) ~= "function" or combatBus.demand == nil then
        failures[#failures + 1] = "combat_event_bus_contract"
    else
        local descriptor = combatBus:DescribeEventType("SPELL_DAMAGE")
        if type(descriptor) ~= "table" or descriptor.category ~= "damage" or descriptor.kind ~= "spell_damage"
            or combatBus:ParseAmount("SPELL_DAMAGE", 0, 0, -321) ~= 321
            or combatBus:ParseAmount("MELEE_DAMAGE", -77, 0, 0) ~= 77 then
            failures[#failures + 1] = "combat_event_parser_contract"
        end
    end
    local combatCaps = {
        "X2Unit:GetUnitNameById", "X2Unit:GetUnitInfoById",
        "UI:SetEventHandler", "UI:ReleaseEventHandler",
        "UIParent:SetEventHandler", "UIParent:ReleaseEventHandler",
    }
    for _, capability in ipairs(combatCaps) do
        if S.ApiCapabilities == nil or S.ApiCapabilities:Get(capability) == nil then
            failures[#failures + 1] = "combat_api_unregistered:" .. capability
        end
    end
    local deathReview = S.Features and S.Features.DeathReview or nil
    local deathMeta = S.FeatureRegistry and S.FeatureRegistry:Get("combat_death_review") or nil
    if deathReview == nil or type(deathReview.Authority) ~= "table" or type(deathReview.Authority.RequestFinalizeDeath) ~= "function"
        or type(deathReview.GetProjection) ~= "function" or type(deathReview.Commands) ~= "table"
        or type(deathReview.Commands.SetEnabled) ~= "function" or type(deathReview.Commands.ClearHistory) ~= "function"
        or deathReview.Demand == nil or S.FeatureRuntime == nil or S.FeatureRuntime:IsImplemented("combat_death_review") ~= true
        or deathMeta == nil or tostring(deathMeta.status) ~= "migrated_m15_2" or tostring(deathMeta.authority) ~= "v3.death_review" then
        failures[#failures + 1] = "death_review_feature_contract"
    end
    if S.UIV3 == nil or S.UIV3.PageHost == nil or S.UIV3.PageHost.factories["combat.death_review"] == nil
        or S.UIV3.WidgetHost == nil or S.UIV3.WidgetHost:GetSpec("combat.death_review") == nil then
        failures[#failures + 1] = "death_review_presentation_contract"
    end
    local dpsFeature = S.Features and S.Features.DPS or nil
    local dpsMeta = S.FeatureRegistry and S.FeatureRegistry:Get("combat_stats") or nil
    if dpsFeature == nil or type(dpsFeature.Domain) ~= "table" or type(dpsFeature.ClearStats) ~= "function"
        or type(dpsFeature.GetProjection) ~= "function" or S.FeatureRuntime == nil or S.FeatureRuntime:IsImplemented("combat_stats") ~= true
        or dpsMeta == nil or tostring(dpsMeta.status) ~= "migrated_m16"
        or tostring(dpsMeta.authority or ""):find("v3.dps", 1, true) == nil
        or tostring(dpsMeta.authority or ""):find("v3.combat_analytics", 1, true) == nil then
        failures[#failures + 1] = "dps_feature_contract"
    end
    if S.UIV3 == nil or S.UIV3.PageHost == nil or S.UIV3.PageHost.factories["combat.stats"] == nil
        or S.UIV3.WidgetHost == nil or S.UIV3.WidgetHost:GetSpec("combat.dps") == nil then
        failures[#failures + 1] = "dps_presentation_contract"
    end

    -- .18.94 Fresh Reload preflight: Feature enablement and floating visibility
    -- are independent authorities.  Calling the lifecycle preference is a
    -- read-only check; it must resolve to the same durable value exposed by the
    -- DPS Feature, otherwise a reload can reopen a window the user closed.
    local dpsStore = S.Persistence and S.Persistence:GetStore("v3.dps") or nil
    local dpsBinding = S.UIV3 and S.UIV3.WidgetHost and S.UIV3.WidgetHost.featureBindings
        and S.UIV3.WidgetHost.featureBindings["combat.dps"] or nil
    local dpsPreferenceOk, dpsPreference = false, nil
    if type(dpsBinding) == "table" and type(dpsBinding.preference) == "function" then
        dpsPreferenceOk, dpsPreference = pcall(dpsBinding.preference)
    end
    local dpsVisible = type(dpsFeature) == "table" and type(dpsFeature.GetWidgetVisible) == "function"
        and dpsFeature:GetWidgetVisible() == true or false
    if type(dpsStore) ~= "table" or tonumber(dpsStore.schemaVersion) ~= 4
        or type(dpsFeature) ~= "table" or type(dpsFeature.State) ~= "table" or type(dpsFeature.State.widgetVisible) ~= "boolean"
        or type(dpsFeature.GetWidgetVisible) ~= "function" or type(dpsFeature.Commands) ~= "table"
        or type(dpsFeature.Commands.SetWidgetVisible) ~= "function"
        or dpsPreferenceOk ~= true or (dpsPreference == true) ~= dpsVisible then
        failures[#failures + 1] = "dps_widget_visibility_preference_contract"
    end

    -- The Trade route UI is dropdown-only.  Runtime acceptance cannot prove a
    -- Native popup opened without user input, but it can prove the public
    -- command/projection contract that both the page and floating widget depend
    -- on before the package reaches RU Fresh Reload.
    local tradeFeature = S.Features and S.Features.Trade or nil
    local tradeProjection = type(tradeFeature) == "table" and type(tradeFeature.GetProjection) == "function"
        and tradeFeature:GetProjection() or nil
    local tradePayout = S.Services and S.Services.TradePayoutV3 or nil
    if type(tradeFeature) ~= "table" or type(tradeFeature.GetRouteSettings) ~= "function"
        or type(tradeFeature.Authority) ~= "table" or (tonumber(tradeFeature.Authority.version) or 0) < 6
        or (tonumber(tradeFeature.Authority.TradePayoutProjectionContractVersion) or 0) < 1
        or type(tradePayout) ~= "table" or (tonumber(tradePayout.PriceFormulaContractVersion) or 0) < 1
        or (tonumber(tradePayout.StaticPriceKeyResolverContractVersion) or 0) < 2
        or (tonumber(tradePayout.CommerceMultiplierContractVersion) or 0) < 1
        or (tonumber(tradePayout.PackCategoryMultiplierContractVersion) or 0) < 1
        or (tonumber(tradeFeature.Authority.RouteRefreshRetryContractVersion) or 0) < 1
        or (tonumber(tradeFeature.Authority.RequestTimeoutContractVersion) or 0) < 1
        or type(tradeFeature.Commands) ~= "table" or type(tradeFeature.Commands.SetFrom) ~= "function"
        or type(tradeFeature.Commands.SetTo) ~= "function" or type(tradeFeature.Commands.QuotePendingMaterials) ~= "function"
        or type(tradeProjection) ~= "table" or type(tradeProjection.zones) ~= "table"
        or type(tradeProjection.sellableZones) ~= "table" or tradeProjection.pendingQuoteCount == nil
        or tostring(tradeProjection.commercePriceFormulaStatus or "") ~= "supplied_working_v1"
        or tostring(tradeProjection.packPriceMultiplierStatus or "") ~= "supplied_working_v1"
        or type(S.UIV3 and S.UIV3.LifeEconomyWidgetsV3) ~= "table"
        or (tonumber(S.UIV3.LifeEconomyWidgetsV3.version) or 0) < 3 then
        failures[#failures + 1] = "trade_dropdown_quote_preflight_contract"
    end
    local tradeDetail = S.UIV3 and S.UIV3.TradeDetailFloatingV3 or nil
    if type(tradeFeature) ~= "table" or type(tradeFeature.Commands) ~= "table"
        or type(tradeFeature.Commands.SetSortMode) ~= "function" or type(tradeFeature.Commands.ToggleCurrentFavorite) ~= "function"
        or type(tradeFeature.Commands.SelectFavorite) ~= "function" or type(tradeFeature.Commands.SelectRow) ~= "function"
        or type(tradeFeature.Commands.QuoteRowMaterials) ~= "function" or type(tradeFeature.GetFavoriteItems) ~= "function"
        or type(tradeFeature.GetRow) ~= "function" or type(tradeProjection.favoriteItems) ~= "table"
        or tradeProjection.currentRouteFavorite == nil or tradeProjection.sortMode == nil
        or type(tradeDetail) ~= "table" or (tonumber(tradeDetail.TradeDetailContractVersion) or 0) < 2
        or type(tradeDetail.Open) ~= "function" or type(tradeDetail.Close) ~= "function" then
        failures[#failures + 1] = "trade_detail_favorites_contract"
    end
    local adapter = S.UIV3NativeAdapter
    if adapter == nil or (tonumber(adapter.version) or 0) < 2 then failures[#failures + 1] = "native_root_policy_contract" end
    local numericRangeStore = S.Persistence and type(S.Persistence.GetStore) == "function" and S.Persistence:GetStore("v3.rsui.numeric_ranges") or nil
    if S.UIV3Design == nil or (tonumber(S.UIV3Design.version) or 0) < 7 or type(S.UIV3Design.ScrollablePageRoot) ~= "function"
        or type(S.UIV3Design.CompactNumericSetting) ~= "function" or (tonumber(S.RSUI and S.RSUI.NumericInlineContractVersion) or 0) < 6
        or (tonumber(S.RSUI and S.RSUI.NumericAdaptiveRangeContractVersion) or 0) < 1
        or (tonumber(S.RSUI and S.RSUI.NumericExplicitApplyContractVersion) or 0) < 1
        or (tonumber(S.RSUI and S.RSUI.NumericRangePersistenceContractVersion) or 0) < 1
        or type(numericRangeStore) ~= "table" or tostring(numericRangeStore.owner or "") ~= "v3.rsui.numeric_ranges"
        or (tonumber(S.RSUI and S.RSUI.InteractiveDraftContractVersion) or 0) < 4
        or (tonumber(S.RSUI and S.RSUI.InputDraftCommitContractVersion) or 0) < 2
        or (tonumber(S.RSUI and S.RSUI.NumericInputDraftReadContractVersion) or 0) < 1
        or (tonumber(S.RSUI and S.RSUI.InputFocusVisualContractVersion) or 0) < 1
        or (tonumber(S.RSUI and S.RSUI.InputDisableDraftCleanupContractVersion) or 0) < 1
        or (tonumber(S.UI and S.UI.NativeCaretPlacementPreservationContractVersion) or 0) < 2
        or (tonumber(S.UI and S.UI.PostArmFocusPromotionContractVersion) or 0) < 1
        or (tonumber(S.UI and S.UI.InputActivationDiagnosticsContractVersion) or 0) < 1
        or (tonumber(S.RSUI and S.RSUI.StableButtonHoverContractVersion) or 0) < 2 then
        failures[#failures + 1] = "scrollable_compact_numeric_contract"
    end
    local rsui = S.RSUI
    if rsui == nil or (tonumber(rsui.version) or 0) < 30 or type(rsui.SplitView) ~= "function" or type(rsui.SplitViewPolicy) ~= "table" then failures[#failures + 1] = "split_view_contract" end
    local workspaceTemplates = rsui and rsui.WorkspaceTemplates or nil
    if rsui == nil or (tonumber(rsui.AttachmentContractVersion) or 0) < 1
        or (tonumber(rsui.ReparentPolicyContractVersion) or 0) < 1 or rsui.NativeReparentSupported ~= false
        or (tonumber(rsui.ResponsiveInspectorContractVersion) or 0) < 1 or type(rsui.ResponsiveInspector) ~= "function"
        or type(workspaceTemplates) ~= "table" or (tonumber(workspaceTemplates.contractVersion) or 0) < 3
        or type(rsui.CreateResponsiveInspectorWorkspace) ~= "function" then
        failures[#failures + 1] = "ui_host_slot_responsive_contract"
    end
    local layout = S.Layout
    if type(layout) ~= "table" or (tonumber(layout.CoordinateSystemContractVersion) or 0) < 1
        or (tonumber(layout.RectTransformTransactionContractVersion) or 0) < 2
        or (tonumber(layout.ScreenToWidgetLocalContractVersion) or 0) < 1
        or (tonumber(layout.ResponsivePlacementIntentContractVersion) or 0) < 1
        or type(layout.GetCoordinateSystemSnapshot) ~= "function" or type(layout.OffsetPoint) ~= "function"
        or type(layout.GetUiParentLocalOrigin) ~= "function" or type(layout.ScreenPointToWidgetLocal) ~= "function"
        or type(layout.CreateRectTransformTransaction) ~= "function"
        or (tonumber(rsui and rsui.PointerContractVersion) or 0) < 1 or type(rsui.Pointer) ~= "table"
        or type(rsui.Pointer.GetLogicalPosition) ~= "function" or type(rsui.Pointer.Delta) ~= "function"
        or rsui.Pointer.captureSupported ~= false then
        failures[#failures + 1] = "ui_geometry_pointer_contract"
    end
    if rsui == nil or (tonumber(rsui.version) or 0) < 31
        or (tonumber(rsui.SelectionGeometryContractVersion) or 0) < 1
        or type(rsui.SelectionGeometry) ~= "table" or type(rsui.SelectionGeometry.GetHandleRects) ~= "function"
        or type(rsui.SelectionGeometry.HitTestHandle) ~= "function" or type(rsui.CreateSelectionGeometryModel) ~= "function"
        or (tonumber(rsui.LayoutGuideResolverContractVersion) or 0) < 1
        or type(rsui.LayoutGuideResolver) ~= "table" or type(rsui.LayoutGuideResolver.Resolve) ~= "function"
        or (tonumber(rsui.SelectionOverlayContractVersion) or 0) < 1 or type(rsui.SelectionOverlay) ~= "function"
        or (tonumber(rsui.LayoutGuideOverlayContractVersion) or 0) < 1 or type(rsui.LayoutGuideOverlay) ~= "function" then
        failures[#failures + 1] = "ui_selection_geometry_contract"
    end
    if rsui == nil or (tonumber(rsui.version) or 0) < 36
        or (tonumber(rsui.LayoutEditorGestureContractVersion) or 0) < 2
        or type(rsui.CreateLayoutEditorGestureController) ~= "function"
        or type(rsui.LayoutEditorGestureController) ~= "table"
        or type(layout) ~= "table" or (tonumber(layout.RectTransformTransactionContractVersion) or 0) < 2 then
        failures[#failures + 1] = "ui_layout_editor_gesture_contract"
    end
    if rsui == nil or (tonumber(rsui.version) or 0) < 36
        or (tonumber(rsui.AnchorPivotContractVersion) or 0) < 2
        or type(rsui.CreateAnchorPivotModel) ~= "function" or type(rsui.AnchorPivotModel) ~= "table"
        or (tonumber(rsui.LayoutEditorSnapSettingsContractVersion) or 0) < 1
        or type(rsui.CreateLayoutEditorSnapSettingsModel) ~= "function"
        or type(rsui.LayoutEditorSnapSettingsModel) ~= "table" then
        failures[#failures + 1] = "ui_layout_editor_model_contract"
    end
    if rsui == nil or (tonumber(rsui.version) or 0) < 36
        or (tonumber(rsui.TransformInspectorContractVersion) or 0) < 3
        or type(rsui.TransformInspector) ~= "function" then
        failures[#failures + 1] = "ui_transform_inspector_contract"
    end
    if rsui == nil or (tonumber(rsui.version) or 0) < 35
        or (tonumber(rsui.MultiSelectionTransformContractVersion) or 0) < 1
        or type(rsui.CreateMultiSelectionTransformModel) ~= "function"
        or type(rsui.MultiSelectionTransformModel) ~= "table"
        or type(rsui.MultiSelectionTransformSession) ~= "table" then
        failures[#failures + 1] = "ui_multi_selection_transform_contract"
    end
    if rsui == nil or (tonumber(rsui.version) or 0) < 36
        or (tonumber(rsui.LayoutEditorPreviewAdapterContractVersion) or 0) < 1
        or type(rsui.CreateLayoutEditorPreviewAdapter) ~= "function"
        or type(rsui.LayoutEditorPreviewAdapter) ~= "table" then
        failures[#failures + 1] = "ui_layout_editor_preview_adapter_contract"
    end
    if rsui == nil or (tonumber(rsui.version) or 0) < 39
        or (tonumber(rsui.LayoutEditHistoryContractVersion) or 0) < 1
        or type(rsui.CreateLayoutEditHistoryModel) ~= "function"
        or type(rsui.LayoutEditHistoryModel) ~= "table" then
        failures[#failures + 1] = "ui_layout_edit_history_contract"
    end
    if rsui == nil or (tonumber(rsui.version) or 0) < 41
        or (tonumber(rsui.LayoutEditSessionContractVersion) or 0) < 1
        or (tonumber(rsui.LayoutEditSessionPersistenceBoundaryContractVersion) or 0) < 1
        or type(rsui.CreateLayoutEditSessionModel) ~= "function"
        or type(rsui.LayoutEditSessionModel) ~= "table" then
        failures[#failures + 1] = "ui_layout_edit_session_contract"
    end
    if rsui == nil or (tonumber(rsui.version) or 0) < 41
        or (tonumber(rsui.LayoutEditHistoryObservableContractVersion) or 0) < 1
        or (tonumber(rsui.EditorCommandBarContractVersion) or 0) < 2
        or (tonumber(rsui.EditorCommandSessionProjectionContractVersion) or 0) < 2
        or type(rsui.ProjectEditorCommandState) ~= "function"
        or type(rsui.EditorCommandBar) ~= "function"
        or type(rsui.types) ~= "table" or rsui.types["EditorCommandBar"] == nil then
        failures[#failures + 1] = "ui_editor_command_bar_contract"
    end
    if rsui == nil or (tonumber(rsui.version) or 0) < 37
        or (tonumber(rsui.LayoutEditorOverlayContractVersion) or 0) < 1
        or type(rsui.LayoutEditorOverlay) ~= "function"
        or type(rsui.types) ~= "table" or rsui.types["LayoutEditorOverlay"] == nil then
        failures[#failures + 1] = "ui_layout_editor_overlay_contract"
    end
    if rsui == nil or (tonumber(rsui.version) or 0) < 44
        or (tonumber(rsui.ComponentApiContractVersion) or 0) < 1
        or type(rsui.RequireComponentMethods) ~= "function"
        or type(workspaceTemplates) ~= "table" or (tonumber(workspaceTemplates.contractVersion) or 0) < 6
        or (tonumber(rsui.LayoutEditorWorkspaceContractVersion) or 0) < 4
        or (tonumber(rsui.LayoutEditorWorkspaceSessionBindingContractVersion) or 0) < 1
        or type(workspaceTemplates.ValidateLayoutEditorEditSessionSpec) ~= "function"
        or type(rsui.CreateLayoutEditorWorkspace) ~= "function"
        or (tonumber(rsui.LayoutEditorOverlayHistoryBindingContractVersion) or 0) < 1
        or (tonumber(rsui.LayoutEditHistoryContractVersion) or 0) < 1
        or (tonumber(rsui.LayoutEditSessionContractVersion) or 0) < 1
        or (tonumber(rsui.EditorCommandBarContractVersion) or 0) < 2
        or (tonumber(rsui.TransformInspectorContractVersion) or 0) < 3 then
        failures[#failures + 1] = "ui_layout_editor_workspace_contract"
    end
    if rsui == nil or (tonumber(rsui.BuildScopeContractVersion) or 0) < 4
        or (tonumber(rsui.BuildTransactionContractVersion) or 0) < 2
        or (tonumber(rsui.BuildRollbackInputQuiescenceContractVersion) or 0) < 1
        or (tonumber(rsui.PreflightContractVersion) or 0) < 1
        or (tonumber(rsui.LogicalIdGenerationFenceVersion) or 0) < 1
        or type(rsui.WithBuildScope) ~= "function" or type(rsui.ValidateSpec) ~= "function"
        or type(rsui.RegisterTypeValidator) ~= "function" then
        failures[#failures + 1] = "build_transaction_preflight_contract"
    end
    local validators = rsui and rsui.typeValidators or nil
    if type(validators) ~= "table" or type(validators.TableView) ~= "function"
        or type(validators.Table) ~= "function" or type(validators.SegmentedSelector) ~= "function"
        or type(validators.NumericField) ~= "function" then
        failures[#failures + 1] = "component_preflight_validator_contract"
    end
    if rsui == nil or (tonumber(rsui.DataViewViewportContractVersion) or 0) < 2
        or (tonumber(rsui.DataViewOverlayScrollbarContractVersion) or 0) < 1
        or (tonumber(rsui.DataViewResizePreviewAuthorityContractVersion) or 0) < 2 then
        failures[#failures + 1] = "dataview_overlay_scrollbar_contract"
    end
    local uiTokens = S.UITokens
    if type(uiTokens) ~= "table" or (tonumber(uiTokens.version) or 0) < 8
        or type(uiTokens.layer) ~= "table"
        or (tonumber(uiTokens.layer.shellPriority) or 0) <= 0
        or (tonumber(uiTokens.layer.floatingPriority) or 0) <= (tonumber(uiTokens.layer.shellPriority) or 0)
        or (tonumber(uiTokens.layer.popupPriority) or 0) <= (tonumber(uiTokens.layer.floatingPriority) or 0)
        or (tonumber(uiTokens.layer.modalPriority) or 0) < (tonumber(uiTokens.layer.popupPriority) or 0) then
        failures[#failures + 1] = "ui_token_layer_contract"
    end
    local settingsFoundation = rsui and rsui.SettingsFoundation or nil
    local settingsDesign = S.UIV3Design
    if type(settingsFoundation) ~= "table" or (tonumber(settingsFoundation.contractVersion) or 0) < 3
        or (tonumber(rsui.SettingsResponsiveContractVersion) or 0) < 2
        or (tonumber(rsui.SettingsDiagnosticsDisclosureContractVersion) or 0) < 1
        or (tonumber(rsui.SettingsStyleCardContractVersion) or 0) < 3
        or (tonumber(rsui.SettingsCompactToggleContractVersion) or 0) < 1
        or (tonumber(rsui.SettingsScrollSafeCardContractVersion) or 0) < 2
        or (tonumber(rsui.SettingsSectionHierarchyContractVersion) or 0) < 1
        or (tonumber(rsui.SettingsNumericSliderContractVersion) or 0) < 1
        or (tonumber(rsui.FormRowResponsiveContractVersion) or 0) < 1
        or (tonumber(rsui.NumericResponsiveStackContractVersion) or 0) < 1
        or type(rsui.CreateFeatureSettingsHeader) ~= "function"
        or type(rsui.CreateSettingsToggleGrid) ~= "function"
        or type(rsui.CreateSettingsStyleCardGrid) ~= "function"
        or type(rsui.CreateSettingsDiagnosticsDisclosure) ~= "function"
        or type(rsui.CreateResponsiveSettingRow) ~= "function"
        or type(rsui.CreateResponsiveNumericSetting) ~= "function"
        or type(rsui.CreateSettingsNumericSlider) ~= "function"
        or type(settingsDesign) ~= "table" or (tonumber(settingsDesign.version) or 0) < 10
        or type(settingsDesign.FeatureSettingsHeader) ~= "function"
        or type(settingsDesign.SettingsToggleGrid) ~= "function"
        or type(settingsDesign.SettingsStyleCard) ~= "function"
        or type(settingsDesign.SettingsDiagnostics) ~= "function"
        or type(settingsDesign.ResponsiveNumericSetting) ~= "function"
        or type(settingsDesign.SettingsNumericSlider) ~= "function" then
        failures[#failures + 1] = "settings_page_foundation_contract"
    end
    if rsui == nil or (tonumber(rsui.StatusChipContractVersion) or 0) < 1 or type(rsui.StatusChip) ~= "function"
        or (tonumber(rsui.PickerModelContractVersion) or 0) < 1 or type(rsui.PickerModel) ~= "table"
        or (tonumber(rsui.SearchablePickerContractVersion) or 0) < 1 or type(rsui.SearchablePicker) ~= "function"
        or (tonumber(rsui.IconPickerContractVersion) or 0) < 1 or type(rsui.IconPicker) ~= "function"
        or (tonumber(rsui.TreeViewContractVersion) or 0) < 1 or type(rsui.TreeView) ~= "function"
        or type(rsui.TreeModel) ~= "table" or type(rsui.CompositeFoundation) ~= "table"
        or (tonumber(rsui.TreeStableIdentityContractVersion) or 0) < 1
        or (tonumber(rsui.TreeMutationTransactionContractVersion) or 0) < 2
        or (tonumber(rsui.TreeExpansionStateBoundContractVersion) or 0) < 1 then
        failures[#failures + 1] = "ui_composite_foundation_contract"
    end
    if rsui == nil or (tonumber(rsui.DropdownDegradedFailClosedContractVersion) or 0) < 1 then
        failures[#failures + 1] = "dropdown_degraded_fail_closed_contract"
    end
    if rsui == nil or (tonumber(rsui.PopupCoordinatorContractVersion) or 0) < 1
        or type(rsui.PopupCoordinator) ~= "table" or type(rsui.PopupCoordinator.CloseAll) ~= "function"
        or rsui.DropdownService ~= rsui.PopupCoordinator then
        failures[#failures + 1] = "popup_coordinator_contract"
    end
    -- Detached UIParent popups use one viewport-logical Authority.  Do not
    -- regress to per-control GetEffectiveOffset/uiScale arithmetic: RU has
    -- exposed effective geometry in more than one unit space, and a second
    -- transform produces position-dependent drift on non-default resolutions.
    local popupPositioning = rsui and rsui.PopupPositioning or nil
    if type(S.Layout) ~= "table"
        or (tonumber(S.Layout.ViewportLogicalRectContractVersion) or 0) < 1 -- 中文维护注释：外部 Native Trigger 仍必须能归一到 viewport-logical-v1。
        or (tonumber(S.Layout.EffectiveGeometryCalibrationContractVersion) or 0) < 1 -- 中文维护注释：外部原生控件仍保留 bounded Effective Geometry 校准。
        or (tonumber(S.Layout.SuiteOwnedViewportAnchorContractVersion) or 0) < 1 -- 中文维护注释：Suite-owned Trigger 必须提供完整 Diff cache 父链 Authority。
        or type(S.Layout.ResolveViewportLogicalRect) ~= "function" -- 中文维护注释：验证外部原生几何解析函数存在。
        or type(S.Layout.ResolveSuiteOwnedViewportLogicalRect) ~= "function" -- 中文维护注释：验证 Suite-owned cache-first 锚点函数存在。
        or rsui == nil -- 中文维护注释：RSUI 缺失时 Popup 契约无法成立。
        or (tonumber(rsui.PopupPositioningContractVersion) or 0) < 3 -- 中文维护注释：PopupPositioning v3 才包含 .18.191 Native-relative 最终 Anchor，.18.190 cache-first 绝对坐标已被 RU 实机证明不足。
        or (tonumber(rsui.PopupNativeRelativeAnchorContractVersion) or 0) < 1 -- 中文维护注释：验收必须证明 Native-relative Trigger Anchor 契约已登记。
        or (tonumber(rsui.PopupSuiteAnchorAuthorityContractVersion) or 0) < 1 -- 中文维护注释：显式要求 Suite Popup Anchor Authority 已登记。
        or (tonumber(rsui.PopupCoordinateSpaceContractVersion) or 0) < 1 -- 中文维护注释：最终输出坐标空间仍必须是 viewport-logical-v1。
        or (tonumber(rsui.PopupCoordinateConsumerContractVersion) or 0) < 2 -- 中文维护注释：Controls consumer v2 才能证明 Dropdown/ColorField 最终位置不再写 UIParent 绝对坐标。
        or (tonumber(rsui.InteractionPopupCoordinateConsumerContractVersion) or 0) < 2 -- 中文维护注释：Interactions consumer v2 才能证明目标型 Tooltip/ContextMenu 已切换到同一 Native-relative Authority。
        or type(popupPositioning) ~= "table" -- 中文维护注释：唯一 Popup Positioning Authority 缺失时不能接受 detached Popup 能力。
        or type(popupPositioning.ApplyNativeRelativePopup) ~= "function" -- 中文维护注释：验收直接要求最终 Native-relative 提交入口存在，避免“契约版本升了但 Consumer 仍走旧算法”的假绿。
        or type(popupPositioning.CorrectNativePopupToScreen) ~= "function" -- 中文维护注释：验收屏幕边缘 Native 修正入口，低分辨率不允许回退业务固定偏移。
        or type(S.DiagnosticsManager) ~= "table" or type(S.DiagnosticsManager.BuildPopupPositioningReport) ~= "function" -- 中文维护注释：专项坐标报告属于 .18.191 可观测性契约，用户必须能复制真实 RU 几何。
        or type(popupPositioning.ResolveAnchorRect) ~= "function"
        or type(popupPositioning.ResolveAnchored) ~= "function"
        or type(popupPositioning.ResolveDropdown) ~= "function"
        or type(popupPositioning.ResolvePoint) ~= "function" then
        failures[#failures + 1] = "popup_coordinate_authority_contract"
    end
    if rsui == nil or (tonumber(rsui.FocusContractVersion) or 0) < 2
        or type(rsui.Focus) ~= "table" or type(rsui.Focus.CanSet) ~= "function"
        or type(rsui.Focus.CanClear) ~= "function" or type(rsui.Focus.IsFocused) ~= "function" then
        failures[#failures + 1] = "focus_target_capability_contract"
    end
    local selectionVisual = rsui and rsui.SelectionVisual or nil
    if selectionVisual == nil or (tonumber(selectionVisual.version) or 0) < 1
        or type(selectionVisual.Apply) ~= "function" or type(selectionVisual.Clear) ~= "function" then
        failures[#failures + 1] = "selection_visual_contract"
    end
    local tooltip = rsui and rsui.Tooltip or nil
    if tooltip == nil or (tonumber(tooltip.version) or 0) < 6 or type(tooltip.Bind) ~= "function"
        or type(tooltip.Unbind) ~= "function" or type(tooltip.BindOverflowText) ~= "function"
        or (tonumber(tooltip.TransientLayerContractVersion) or 0) < 1
        or (tonumber(tooltip.LineEstimateContractVersion) or 0) < 1
        or (tonumber(tooltip.IsShowingContractVersion) or 0) < 1
        or type(tooltip.EstimateWrappedLines) ~= "function"
        or type(tooltip.IsShowing) ~= "function" then
        failures[#failures + 1] = "tooltip_contract"
    end
    if S.Api == nil or type(S.Api.GetMouseLogicalPosition) ~= "function" then failures[#failures + 1] = "tooltip_mouse_boundary" end
    local mouseCapability = S.ApiCapabilities and S.ApiCapabilities:Get("X2Input:GetMousePos") or nil
    if type(mouseCapability) ~= "table" or tostring(mouseCapability.OfficialState or "") ~= "OfficialEnabled" then
        failures[#failures + 1] = "tooltip_mouse_capability"
    end
    local scrollbar = rsui and rsui.ScrollbarBehavior or nil
    if scrollbar == nil or (tonumber(scrollbar.version) or 0) < 3 or type(scrollbar.ComputeGeometry) ~= "function" then failures[#failures + 1] = "scrollbar_behavior_contract" end
    local identity = S.NativeIdentity
    local factory = S.NativeObjectFactory
    local identityInfo = type(S.DescribeNativeIdentity) == "function" and S.DescribeNativeIdentity() or nil
    if type(identity) ~= "table" or (tonumber(identity.version) or 0) < 2 or type(identity.Build) ~= "function"
            or identityInfo == nil or (tonumber(identityInfo.maxPhysicalLength) or 99) > 23
            or type(factory) ~= "table" or (tonumber(factory.version) or 0) < 2
            or type(factory.ValidateParent) ~= "function" or type(factory.ReservePhysicalId) ~= "function" then
        failures[#failures + 1] = "native_identity_contract"
    else
        local a = identity:Build("v3_shell_nav_scroll_scrollbar_track", 1, 0)
        local b = identity:Build("v3_shell_nav_scroll_scrollbar_thumb", 1, 0)
        local c = identity:Build("v3_shell_nav_scroll_scrollbar_drag_proxy", 1, 0)
        local g2 = identity:Build("v3_shell_nav_scroll_scrollbar_track", 2, 0)
        if a == b or a == c or b == c or a == g2 or #a > identity.maxPhysicalLength or #b > identity.maxPhysicalLength or #c > identity.maxPhysicalLength then
            failures[#failures + 1] = "native_identity_uniqueness"
        end
        local currentParent = { rsNativeGeneration = S.Generation }
        local staleParent = { rsNativeGeneration = (tonumber(S.Generation) or 1) - 1 }
        local rejectedParent = { rsNativeGeneration = S.Generation, rsUiRegistrationRejected = true }
        if factory:ValidateParent(currentParent) ~= true or factory:ValidateParent(staleParent) == true or factory:ValidateParent(rejectedParent) == true then
            failures[#failures + 1] = "native_parent_fence"
        end
    end
    local framework = S.UI and type(S.UI.GetFrameworkSnapshot) == "function" and S.UI:GetFrameworkSnapshot() or nil
    if framework == nil or (tonumber(framework.version) or 0) < 8 or framework.nativeSafety == nil then failures[#failures + 1] = "native_write_safety_contract" end
    if S.UI == nil or type(S.UI.ResolveNativeAnchorTarget) ~= "function" then
        failures[#failures + 1] = "root_anchor_boundary_contract"
    else
        local nativeRoot, logicalRoot = S.UI:ResolveNativeAnchorTarget(UIParent)
        if nativeRoot ~= "UIParent" or logicalRoot ~= UIParent then failures[#failures + 1] = "root_anchor_identity_contract" end
    end

    -- Screen Snap is a framework capability, not a Gear-only interaction.  The
    -- synthetic widgets below exercise cross-owner discovery without creating
    -- native objects, keeping acceptance bounded and safe to run on demand.
    if S.Layout == nil or type(S.Layout.ResolveScreenSnap) ~= "function" or type(S.Layout.GetScreenSnapSnapshot) ~= "function"
        or S.UI == nil or type(S.UI.RegisterScreenSnap) ~= "function" or type(S.UI.ResolveScreenSnap) ~= "function"
        or type(S.UI.CommitScreenSnap) ~= "function" then
        failures[#failures + 1] = "screen_snap_framework_contract"
    else
        local fakeA = { GetOffset = function() return 112, 100 end, GetWidth = function() return 10 end, GetHeight = function() return 10 end, IsVisible = function() return true end }
        local fakeB = { GetOffset = function() return 100, 100 end, GetWidth = function() return 10 end, GetHeight = function() return 10 end, IsVisible = function() return true end }
        S.Layout:RegisterScreenSnap("__v3_snap_accept_a", fakeA, { snapGroup = "__accept", snapKind = "button" })
        S.Layout:RegisterScreenSnap("__v3_snap_accept_b", fakeB, { snapGroup = "__accept", snapKind = "button" })
        local sx, sy, snapped, targetId = S.Layout:ResolveScreenSnap("__v3_snap_accept_a", 112, 100, 10, 10, {
            enabled = true, group = "__accept", kind = "button", distance = 4, gap = 0,
        })
        if snapped ~= true or math.abs((tonumber(sx) or 0) - 110) > 0.01 or math.abs((tonumber(sy) or 0) - 100) > 0.01
            or tostring(targetId or "") ~= "__v3_snap_accept_b" then
            failures[#failures + 1] = "screen_snap_cross_owner_contract"
        end
        S.Layout:RegisterScreenSnap("__v3_snap_accept_b", fakeB, { snapGroup = "__accept", snapKind = "button", snapEnabled = false })
        local _, _, disabledTargetSnap = S.Layout:ResolveScreenSnap("__v3_snap_accept_a", 112, 100, 10, 10, {
            enabled = true, group = "__accept", kind = "button", distance = 4, gap = 0,
        })
        if disabledTargetSnap == true then failures[#failures + 1] = "screen_snap_disabled_target_contract" end
        S.Layout:UnregisterScreenSnap("__v3_snap_accept_a")
        S.Layout:UnregisterScreenSnap("__v3_snap_accept_b")
    end

    -- Hard design fence: the new shell minimum must fit the project's mandatory
    -- 1024x768 validation target without reducing font size below design tokens.
    local sizePolicy = S.UIV3 and S.UIV3.ShellSizePolicy or { minWidth = 1, minHeight = 1 }
    local minWidth, minHeight = tonumber(sizePolicy.minWidth) or 1, tonumber(sizePolicy.minHeight) or 1
    if minWidth > 1024 then failures[#failures + 1] = "min_width_1024" end
    if minHeight > 768 then failures[#failures + 1] = "min_height_768" end
    return { ok = #failures == 0, failures = #failures, details = failures, cases = 36 + (registry and #registry.order or 0) }
end

function A:RunTextStress()
    local failures = {}
    local registry = S.FeatureRegistry
    if registry ~= nil then
        for _, feature in ipairs(registry:List()) do
            local name = tostring(feature.name or "")
            if name == "" then failures[#failures + 1] = "empty_name:" .. feature.id end
            if #name > 96 then failures[#failures + 1] = "name_too_long:" .. feature.id end
            if name:find("[\r\n]") then failures[#failures + 1] = "name_multiline:" .. feature.id end
            -- User-visible V3 navigation names are Chinese-first. Internal ids,
            -- API names and diagnostic codes may remain technical English.
            if name:find("[A-Za-z]") then failures[#failures + 1] = "visible_name_latin:" .. feature.id end
        end
    end
    return { ok = #failures == 0, failures = #failures, details = failures }
end

function A:InspectLive()
    local shell = S.UIV3 and S.UIV3.Shell or nil
    local pageHost = S.UIV3 and S.UIV3.PageHost or nil
    if shell == nil or pageHost == nil then
        return { hardIssues = 1, pendingLayoutRoots = CountMap(S.RSUI and S.RSUI.layoutQueue), cacheRepairs = 0, activeRoute = nil, details = { "shell_or_page_host_missing" } }
    end

    local hard, details = 0, {}
    local function Audit(component)
        local count, rows = CountHard(component)
        hard = hard + count
        for _, row in ipairs(rows) do if #details < 24 then details[#details + 1] = row end end
    end
    Audit(shell.topBar)
    Audit(shell.navFrame)
    local active = pageHost.activeRoute and pageHost.pages and pageHost.pages[pageHost.activeRoute] or nil
    Audit(active)

    local framework = S.UI and S.UI.GetFrameworkSnapshot and S.UI:GetFrameworkSnapshot() or nil
    local layoutQueue = S.RSUI and type(S.RSUI.GetLayoutQueueSnapshot) == "function" and S.RSUI:GetLayoutQueueSnapshot() or { pending = CountMap(S.RSUI and S.RSUI.layoutQueue), stale = 0, unscheduled = 0, fresh = 0 }
    return {
        hardIssues = hard,
        pendingLayoutRoots = tonumber(layoutQueue.pending) or 0,
        freshLayoutRoots = tonumber(layoutQueue.fresh) or 0,
        staleLayoutRoots = tonumber(layoutQueue.stale) or 0,
        unscheduledLayoutRoots = tonumber(layoutQueue.unscheduled) or 0,
        oldestLayoutAgeMs = tonumber(layoutQueue.oldestAgeMs) or 0,
        -- InspectLive itself is read-only. Report a zero mutation delta here and
        -- expose the historical counter separately so Diagnostics does not imply
        -- that pressing the button performed thousands of repairs.
        cacheRepairs = 0,
        cacheRepairsTotal = framework and (tonumber(framework.cacheRepairs) or 0) or 0,
        activeRoute = pageHost.activeRoute,
        details = details,
    }
end

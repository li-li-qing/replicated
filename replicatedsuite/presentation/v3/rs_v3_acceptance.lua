------------------------------------------------------------------------
-- Replicated Suite V3 - Foundation Acceptance v64
--
-- Bounded, on-demand checks only. No Native widget creation and no Tick.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.UIV3Acceptance = { version = 64 }
local A = S.UIV3Acceptance
A.TradeDpsFreshReloadPreflightContractVersion = 1
A.PersistenceReliabilityV3ContractVersion = 1
A.PersistenceReliabilityV4ContractVersion = 1
A.PersistenceReliabilityV5ContractVersion = 1
A.PersistenceReliabilityV6ContractVersion = 1
A.PersistenceReliabilityV7ContractVersion = 1

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
    if router ~= nil and registry ~= nil then
        local seen = {}
        for _, feature in ipairs(registry:List()) do
            if seen[feature.route] then failures[#failures + 1] = "duplicate_route:" .. feature.route end
            seen[feature.route] = true
            if router:Get(feature.route) == nil then failures[#failures + 1] = "unregistered_route:" .. feature.route end
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
        { name = "Trade", id = "life_trade", methods = { "GetProjection", "GetRouteSettings", "GetWidgetVisible", "GetWidgetWindowState", "AcquireConsumer", "ReleaseConsumer" }, commands = { "Refresh", "SetFrom", "SetTo", "GetWidgetVisible", "SetWidgetVisible", "SetWidgetWindowState" } },
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
    if type(bagTools) ~= "table" or (tonumber(bagTools.BagMoveContractVersion) or 0) < 5
        or (tonumber(bagTools.BatchLifecycleContractVersion) or 0) < 5 or (tonumber(bagTools.NativeWindowQuickContractVersion) or 0) < 3
        or (tonumber(bagTools.DynamicSourceResolutionContractVersion) or 0) < 1
        or (tonumber(bagTools.BagTaskMutexContractVersion) or 0) < 1
        or type(bagTools.Commands) ~= "table" or type(bagTools.Commands.QuickWithdraw) ~= "function"
        or type(bagTools.Commands.QuickDeposit) ~= "function" or type(bagTools.Commands.QuickCancel) ~= "function"
        or type(bagTools.Commands.SetBatchCategory) ~= "function" or type(bagTools.Commands.SetBatchTarget) ~= "function"
        or type(bagTools.Commands.SetBatchLimit) ~= "function"
        or type(bagQuickPresenter) ~= "table" or (tonumber(bagQuickPresenter.version) or 0) < 1 then
        failures[#failures + 1] = "bag_quick_take_put_contract_v5"
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

    for _, craftId in ipairs({ "life_craft_planner", "tools_craft" }) do
        local craftFeature = S.Features and S.Features[craftId] or nil
        if type(craftFeature) ~= "table" or (tonumber(craftFeature.CraftUserSelectionContractVersion) or 0) < 1
            or type(craftFeature.Commands) ~= "table" or type(craftFeature.Commands.SelectRecipe) ~= "function" then
            failures[#failures + 1] = "craft_user_selection_contract:" .. craftId
        end
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

    local buffCap = S.Features and S.Features.combat_buff_cap or nil
    if type(buffCap) ~= "table" or (tonumber(buffCap.ObservationContractVersion) or 0) < 1
        or type(buffCap.UpdateTopic) ~= "string" then
        failures[#failures + 1] = "buff_cap_observation_contract"
    end

    local activities = S.Features and S.Features.Activities or nil
    local tasks = S.Features and S.Features.Tasks or nil
    if type(activities) ~= "table" or (tonumber(activities.PersistenceMutationContractVersion) or 0) < 2
        or type(tasks) ~= "table" or (tonumber(tasks.PersistenceMutationContractVersion) or 0) < 2 then
        failures[#failures + 1] = "specialized_persistence_mutation_contract_v2"
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
    if type(screenProjection) ~= "table" or (tonumber(screenProjection.version) or 0) < 5 or tostring(screenProjection.presentationBoundary or "") ~= "service_only"
        or type(screenProjection.ProjectUnitFlexible) ~= "function" or type(screenProjection.ProjectUnitBatch) ~= "function"
        or (tonumber(screenProjection.FrontHemisphereBatchContractVersion) or 0) < 1
        or (tonumber(screenProjection.UnitProjectionConsistencyContractVersion) or 0) < 1
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
    if type(bossAlerts) ~= "table" or (tonumber(bossAlerts.HudContractVersion) or 0) < 1
        or type(bossAlerts.Commands) ~= "table" or type(bossAlerts.Commands.TestBigText) ~= "function"
        or type(bossAlerts.Commands.TestCountdown) ~= "function" or type(bossAlerts.Commands.SetHudEnabled) ~= "function" then
        failures[#failures + 1] = "boss_alert_feature_hud_contract"
    end
    local visualGuides = S.UIV3 and S.UIV3.CombatVisualGuidesV3 or nil
    local unitLines = S.Features and S.Features.combat_unit_lines or nil
    local rangeAssist = S.Features and S.Features.combat_range_assist or nil
    if type(visualGuides) ~= "table" or (tonumber(visualGuides.version) or 0) < 5 or type(visualGuides.Describe) ~= "function"
        or (tonumber(visualGuides.AdaptiveUnitLineSamplingContractVersion) or 0) < 2
        or (tonumber(visualGuides.UnitLineVisibleSegmentClippingContractVersion) or 0) < 1
        or (tonumber(visualGuides.UnitLinePressureBudgetContractVersion) or 0) < 1
        or (tonumber(visualGuides.UnitLineDiffRenderContractVersion) or 0) < 1
        or (tonumber(visualGuides.UnitLineProgressivePoolContractVersion) or 0) < 1
        or type(visualGuides.BuildUnitLineSamplePlan) ~= "function" then
        failures[#failures + 1] = "combat_visual_guides_presenter_contract"
    end
    if type(unitLines) ~= "table" or (tonumber(unitLines.VisualGuideContractVersion) or 0) < 4
        or (tonumber(unitLines.AdaptiveDensityContractVersion) or 0) < 2
        or (tonumber(unitLines.SmoothRefreshContractVersion) or 0) < 1
        or (tonumber(unitLines.FrontHemisphereContractVersion) or 0) < 1
        or (tonumber(unitLines.ProjectionConsistencyContractVersion) or 0) < 1
        or type(unitLines.Commands) ~= "table" or type(unitLines.Commands.SetPointCount) ~= "function"
        or type(unitLines.Commands.SetPointSize) ~= "function" or type(unitLines.Commands.SetOpacity) ~= "function"
        or type(unitLines.Commands.SetRefreshMs) ~= "function" or type(unitLines.Commands.SetPairEnabled) ~= "function" then
        failures[#failures + 1] = "unit_lines_visual_contract"
    end
    if type(rangeAssist) ~= "table" or (tonumber(rangeAssist.VisualGuideContractVersion) or 0) < 3
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
    local buffDisplay = S.Features and S.Features.BuffDisplay or nil
    local buffHealth = type(buffDisplay) == "table" and type(buffDisplay.GetHealth) == "function" and buffDisplay:GetHealth() or nil
    if type(buffHealth) ~= "table" or (tonumber(buffHealth.observationContractVersion) or 0) < 2
        or type(buffDisplay.eventTaskName) ~= "string"
        or type(buffHeadMarkers) ~= "table" or (tonumber(buffHeadMarkers.version) or 0) < 2
        or type(buffHeadMarkers.GetDiagnostics) ~= "function"
        or type(buffHeadMarkers.metrics) ~= "table" or type(buffHeadMarkers.metrics.anchorFailures) ~= "table"
        or (tonumber(buffDisplay.BuffHeadMarkerContractVersion) or 0) < 3
        or tonumber(buffDisplay.SchemaVersion) ~= 4
        or type(S.Services and S.Services.StatusClassificationV3) ~= "table" then
        failures[#failures + 1] = "buff_display_observation_head_marker_contract"
    end
    local healerWidgetSpec = type(widgetHost) == "table" and type(widgetHost.GetSpec) == "function" and widgetHost:GetSpec("combat.healer") or nil
    local healerRaidOverlay = S.UIV3 and S.UIV3.HealerRaidOverlay or nil
    if healerWidgetSpec ~= nil or type(healerRaidOverlay) ~= "table" or type(healerRaidOverlay.Describe) ~= "function" then
        failures[#failures + 1] = "healer_calibration_only_presentation_contract"
    end

    local windowShell = S.UI and S.UI.WindowShell or nil
    if windowShell == nil or (tonumber(windowShell.version) or 0) < 17 or (tonumber(windowShell.compactMinimizeContract) or 0) < 1
        or (tonumber(windowShell.titleAppearanceContract) or 0) < 3 or type(S.UI.CreateWindowShell) ~= "function" then
        failures[#failures + 1] = "window_shell_compact_contract"
    end
    local floatingSurface = S.RSUI and S.RSUI.FloatingSurface or nil
    if floatingSurface == nil or (tonumber(floatingSurface.version) or 0) < 9
        or (tonumber(floatingSurface.CompactMinimizeContractVersion) or 0) < 1
        or (tonumber(floatingSurface.TitleAppearanceContractVersion) or 0) < 1
        or (tonumber(floatingSurface.DetachedStateContractVersion) or 0) < 1
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
    if type(tradeFeature) ~= "table" or type(tradeFeature.GetRouteSettings) ~= "function"
        or type(tradeFeature.Commands) ~= "table" or type(tradeFeature.Commands.SetFrom) ~= "function"
        or type(tradeFeature.Commands.SetTo) ~= "function" or type(tradeFeature.Commands.QuotePendingMaterials) ~= "function"
        or type(tradeProjection) ~= "table" or type(tradeProjection.zones) ~= "table"
        or type(tradeProjection.sellableZones) ~= "table" or tradeProjection.pendingQuoteCount == nil
        or type(S.UIV3 and S.UIV3.LifeEconomyWidgetsV3) ~= "table"
        or (tonumber(S.UIV3.LifeEconomyWidgetsV3.version) or 0) < 2 then
        failures[#failures + 1] = "trade_dropdown_quote_preflight_contract"
    end
    local adapter = S.UIV3NativeAdapter
    if adapter == nil or (tonumber(adapter.version) or 0) < 2 then failures[#failures + 1] = "native_root_policy_contract" end
    if S.UIV3Design == nil or (tonumber(S.UIV3Design.version) or 0) < 6 or type(S.UIV3Design.ScrollablePageRoot) ~= "function"
        or type(S.UIV3Design.CompactNumericSetting) ~= "function" or (tonumber(S.RSUI and S.RSUI.NumericInlineContractVersion) or 0) < 4
        or (tonumber(S.RSUI and S.RSUI.InteractiveDraftContractVersion) or 0) < 1 then
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
        or type(layout.GetCoordinateSystemSnapshot) ~= "function" or type(layout.OffsetPoint) ~= "function"
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
        or (tonumber(rsui.TransformInspectorContractVersion) or 0) < 2
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
        or (tonumber(rsui.TransformInspectorContractVersion) or 0) < 2 then
        failures[#failures + 1] = "ui_layout_editor_workspace_contract"
    end
    if rsui == nil or (tonumber(rsui.BuildScopeContractVersion) or 0) < 3
        or (tonumber(rsui.BuildTransactionContractVersion) or 0) < 1
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
    if rsui == nil or (tonumber(rsui.DataViewViewportContractVersion) or 0) < 2 or (tonumber(rsui.DataViewOverlayScrollbarContractVersion) or 0) < 1 then
        failures[#failures + 1] = "dataview_overlay_scrollbar_contract"
    end
    local uiTokens = S.UITokens
    if type(uiTokens) ~= "table" or (tonumber(uiTokens.version) or 0) < 4
        or type(uiTokens.layer) ~= "table" or (tonumber(uiTokens.layer.popupPriority) or 0) <= 0 then
        failures[#failures + 1] = "ui_token_layer_contract"
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
    if tooltip == nil or (tonumber(tooltip.version) or 0) < 2 or type(tooltip.Bind) ~= "function"
        or type(tooltip.Unbind) ~= "function" or type(tooltip.BindOverflowText) ~= "function" then
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

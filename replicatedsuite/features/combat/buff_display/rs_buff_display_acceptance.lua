------------------------------------------------------------------------
-- Replicated Suite V3 - Buff Display Acceptance (schema 4)
-- Non-destructive contract checks. No feature is enabled by this case.
--
-- Schema 4 contracts covered here:
--   * store schemaVersion == 4, tracked = { buff = {...}, debuff = {...} }
--   * shared StatusClassificationV3 service resolves category + detection
--     source (hidden is a detection source, never a user category)
--   * Feature commands: SetTrackedId(id, category, enabled) with explicit
--     category; SetComponentField; tracked-id import; full export/import
--   * 10 head components projected through GetSettingsProjection
--   * ProjectStatusMap rows carry category/detectionSource; hidden-sourced
--     rows classify as debuff
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local G = S.FoundationGate
local F = S.Features and S.Features.BuffDisplay or nil
if type(G) ~= "table" or type(G.RegisterSequenceCase) ~= "function" or type(F) ~= "table" then return end

G:RegisterSequenceCase("v3_m16_18_4_buff_display_statusmap_contract", function()
    local meta = S.FeatureRegistry and S.FeatureRegistry:Get("combat_buff_display") or nil
    if meta == nil or tostring(meta.status) ~= "migrated_m16_18"
        or tostring(meta.lifecycle) ~= "demand_scoped"
        or tostring(meta.authority):find("v3.buff_display", 1, true) == nil
        or meta.widgetCapable ~= true or meta.settingsCapable ~= true or meta.defaultEnabled == true then
        return false, "metadata_contract"
    end
    if S.FeatureRuntime == nil or S.FeatureRuntime:IsImplemented(F.Id) ~= true then return false, "implementation_missing" end
    local store = S.Persistence and S.Persistence:GetStore(F.StoreId or "v3.buff_display") or nil
    if store == nil or tostring(store.owner or "") ~= "v3.buff_display" or tonumber(store.schemaVersion) ~= 4 then return false, "store_contract" end
    -- Shared classification service (schema 4 Authority).
    local classification = S.Services and S.Services.StatusClassificationV3 or nil
    if type(classification) ~= "table" or (tonumber(classification.version) or 0) < 1
        or type(classification.ClassifyEntry) ~= "function" or type(classification.ClassifyId) ~= "function"
        or type(classification.SetOverride) ~= "function" or type(classification.GetOverrides) ~= "function"
        or type(classification.ApplyOverrides) ~= "function" or type(classification.GetRegistrySnapshot) ~= "function"
        or type(classification.GetHealth) ~= "function" then return false, "classification_service_contract" end
    if type(F.ProjectStatusMap) ~= "function" or type(F.ProjectPlates) ~= "function"
        or type(F.GetProjection) ~= "function" or type(F.GetSettingsProjection) ~= "function"
        or type(F.RefreshScope) ~= "function" or type(F.Refresh) ~= "function"
        or type(F.AcquireConsumer) ~= "function" or type(F.ReleaseConsumer) ~= "function"
        or tonumber(F.SchemaVersion) ~= 4 or (tonumber(F.ProjectPlatesContractVersion) or 0) < 1
        or type(F.Commands) ~= "table" or type(F.Commands.SetSetting) ~= "function"
        or type(F.Commands.ApplySettingFromBinding) ~= "function" or type(F.Commands.MarkStoreDirty) ~= "function"
        or type(F.Commands.GetWidgetVisible) ~= "function" or type(F.Commands.SetWidgetVisible) ~= "function"
        or type(F.Commands.SetTrackedId) ~= "function" or type(F.Commands.ClearTrackedIds) ~= "function"
        or type(F.Commands.SetComponentField) ~= "function" or type(F.Commands.ImportTrackedIds) ~= "function"
        or type(F.Commands.ExportAll) ~= "function" or type(F.Commands.SerializeExport) ~= "function"
        or type(F.Commands.ParseImportText) ~= "function" or type(F.Commands.ImportAll) ~= "function"
        or (tonumber(F.BuffHeadMarkerContractVersion) or 0) < 3 then return false, "feature_contract" end
    -- Head renderer gate contract: tracked-independent start (HasRenderableComponents
    -- gate) + GetDiagnostics triage surface + anchorFailure trail on hidden scopes.
    local headMarkers = S.UIV3 and S.UIV3.BuffHeadMarkersV3 or nil
    if type(headMarkers) ~= "table" or (tonumber(headMarkers.version) or 0) < 2
        or type(headMarkers.GetDiagnostics) ~= "function"
        or type(headMarkers.metrics) ~= "table" or type(headMarkers.metrics.anchorFailures) ~= "table"
        or type(headMarkers.Start) ~= "function" or type(headMarkers.Stop) ~= "function" or type(headMarkers.Reconcile) ~= "function"
        or type(headMarkers.VisualTick) ~= "function" then return false, "head_marker_gate_contract" end
    local aura = S.Services and S.Services.AuraObservationV3 or nil
    if type(aura) ~= "table" or (tonumber(aura.version) or 0) < 2 or type(aura.GetSnapshot) ~= "function"
        or type(aura.GetStatusMap) ~= "function" or type(aura.AcquireConsumer) ~= "function" then return false, "aura_contract" end
    local pageHost, widgetHost = S.UIV3 and S.UIV3.PageHost or nil, S.UIV3 and S.UIV3.WidgetHost or nil
    if type(pageHost) ~= "table" or type(pageHost.factories) ~= "table" or type(pageHost.factories["combat.buff_display"]) ~= "function" then return false, "page_registration" end
    if type(widgetHost) ~= "table" or type(widgetHost.specs) ~= "table" or type(widgetHost.specs["combat.buff_display"]) ~= "table" then return false, "widget_registration" end
    if (tonumber(F.consumerCount) or 0) <= 0 and (F.auraHeld == true or (S.Scheduler and S.Scheduler.tasks and S.Scheduler.tasks[F.taskName] ~= nil)) then return false, "dormant_resource_contract" end
    -- Schema 4 projection: hidden is a detection source; the hidden-sourced
    -- entry classifies as debuff. Explicit overrides keep this deterministic
    -- regardless of the seeded registry.
    local map = { [101] = { id = 101, name = "A", iconPath = "a.dds", stack = 2, timeLeft = 3000, sources = { buff = true } }, [202] = { id = 202, name = "B", sources = { debuff = true } }, [303] = { id = 303, name = "H", sources = { hidden = true } } }
    local rows = F.ProjectStatusMap(map, { available = true, complete = true, reliable = true, revision = 1 },
        { showBuffs = true, showDebuffs = true, showHidden = false, classification = { [101] = "buff", [202] = "debuff", [303] = "debuff" } }, "player", 8)
    if type(rows) ~= "table" or #rows ~= 3 or rows[1].id ~= 101 or rows[2].id ~= 202 or rows[3].id ~= 303
        or rows[1].category ~= "buff" or rows[2].category ~= "debuff" or rows[3].category ~= "debuff"
        or rows[3].detectionSource ~= "hidden" or rows[1].timeText ~= "3s" or rows[1].tracked ~= false then return false, "projection_contract" end
    -- Settings projection exposes all 10 head components + category-keyed tracked.
    local settingsProjection = type(F.GetSettingsProjection) == "function" and F:GetSettingsProjection() or {}
    local components = type(settingsProjection.components) == "table" and settingsProjection.components or {}
    local tracked = type(settingsProjection.tracked) == "table" and settingsProjection.tracked or {}
    local componentKeys = { "buffs", "debuffs", "distance", "class", "gearScore", "mainHand", "offHand", "ranged", "wings", "castBar" }
    local missingComponents = 0
    for _, key in ipairs(componentKeys) do if type(components[key]) ~= "table" then missingComponents = missingComponents + 1 end end
    if missingComponents ~= 0 or type(tracked.buff) ~= "table" or type(tracked.debuff) ~= "table" then return false, "schema4_settings_projection" end
    -- Head plates projection: bounded tracked rows + enabled component data.
    local plates = F.ProjectPlates({ buffRows = { { id = 101, name = "A" } }, distance = 1234.5, class = "法师", gearScore = 12345 }, settingsProjection)
    if type(plates) ~= "table" or type(plates.components) ~= "table" or type(plates.buffs) ~= "table"
        or type(plates.distance) ~= "table" or plates.distance.value ~= "1.23km"
        or type(plates.class) ~= "table" or plates.class.value ~= "法师"
        or type(plates.gearScore) ~= "table" or plates.gearScore.value ~= "12345" then return false, "plates_projection_contract" end
    return true
end)

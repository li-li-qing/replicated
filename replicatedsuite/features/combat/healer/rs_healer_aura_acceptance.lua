------------------------------------------------------------------------
-- Replicated Suite V3 - Healer Domain + Visual Presentation Acceptance (M1.16.0.18)
--
-- Non-destructive contract checks. The case never enables Healer; it validates
-- that an already-disabled feature is cold and an already-enabled feature owns
-- exactly the resources required by its independent runtime lifecycle.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local G = S.FoundationGate
local F = S.Features and S.Features.Healer or nil
local B = S.Features and S.Features.HealerAuraBridge or nil
if type(G) ~= "table" or type(G.RegisterSequenceCase) ~= "function" or type(F) ~= "table" or type(B) ~= "table" then return end

local function Fail(message) return false, tostring(message or "healer_runtime_acceptance_failed") end

G:RegisterSequenceCase("v3_m16_18_healer_visual_consumers_contract", function()
    local meta = S.FeatureRegistry and S.FeatureRegistry:Get("combat_healer") or nil
    if meta == nil or tostring(meta.status) ~= "migrated_m16_18"
        or tostring(meta.lifecycle) ~= "independent"
        or tostring(meta.authority):find("v3.healer", 1, true) == nil
        or meta.defaultEnabled == true then
        return Fail("metadata_contract")
    end
    if S.FeatureRuntime == nil or S.FeatureRuntime:IsImplemented("combat_healer") ~= true then return Fail("implementation_missing") end

    local store = S.Persistence and S.Persistence:GetStore(F.StoreId or "v3.healer") or nil
    if store == nil or tostring(store.owner or "") ~= "v3.healer" or tonumber(store.schemaVersion) ~= 3 then
        return Fail("store_contract")
    end
    if type(F.Roster) ~= "table" or (tonumber(F.Roster.version) or 0) < 1
        or type(F.Roster.SyncFromShared) ~= "function" or type(F.Roster.RunRoleSlice) ~= "function" then
        return Fail("roster_domain_contract")
    end
    if type(F.Recommendation) ~= "table" or (tonumber(F.Recommendation.version) or 0) < 1
        or type(F.Recommendation.Evaluate) ~= "function" or type(F.Recommendation.Publish) ~= "function"
        or type(F.Recommendation.ShouldRefreshMemberStatuses) ~= "function"
        or type(F.Recommendation.GetMemberProjection) ~= "function" or type(F.Recommendation.GetRaidDisplayProjection) ~= "function" then
        return Fail("recommendation_domain_contract")
    end
    if type(F.HealthRuntime) ~= "table" or (tonumber(F.HealthRuntime.version) or 0) < 1
        or type(F.HealthRuntime.Start) ~= "function" or type(F.HealthRuntime.Stop) ~= "function"
        or type(F.HealthRuntime.RunHealthSlice) ~= "function" or type(F.HealthRuntime.RunStatusSlice) ~= "function" then
        return Fail("health_runtime_contract")
    end
    if (tonumber(F.HealthRuntime.healthSliceMembers) or 0) > 20
        or (tonumber(F.HealthRuntime.statusSliceMembers) or 0) > 8 then return Fail("slice_budget_contract") end
    if (tonumber(B.version) or 0) < 2 or type(B.ReadAccurate) ~= "function" or type(B.GetHealth) ~= "function" then
        return Fail("aura_bridge_contract")
    end
    if type(F.Commands) ~= "table" or type(F.Commands.ApplySettingFromBinding) ~= "function"
        or type(F.Commands.SetRule) ~= "function" or type(F.Commands.AddRule) ~= "function"
        or type(F.Commands.RemoveRule) ~= "function" or type(F.Commands.SetTrackedBuff) ~= "function"
        or type(F.Commands.AddTrackedBuff) ~= "function" or type(F.Commands.RemoveTrackedBuff) ~= "function"
        or type(F.Commands.SetHealerColor) ~= "function" or type(F.Commands.SetRaidSectionRect) ~= "function"
        or type(F.Commands.ResetRaidLayout) ~= "function" or type(F.Commands.RequestRosterRefresh) ~= "function"
        or type(F.GetMemberDetail) ~= "function"
        or type(F.GetWidgetWindowState) ~= "function" or type(F:GetWidgetWindowState()) ~= "table"
        or type(F.GetPresentationSettings) ~= "function" or type(F.SetPresentationSetting) ~= "function"
        or type(F.SetRaidSectionRect) ~= "function" or type(F.GetRosterProjection) ~= "function"
        or type(F.GetRaidOverlayProjection) ~= "function" or type(F.ProjectUnitToScreen) ~= "function"
        or type(F.GetRules) ~= "function" or type(F.SetRule) ~= "function" or type(F.AddRule) ~= "function"
        or type(F.RemoveRule) ~= "function" or type(F.GetTrackedBuffs) ~= "function"
        or type(F.SetTrackedBuff) ~= "function" or type(F.AddTrackedBuff) ~= "function"
        or type(F.RemoveTrackedBuff) ~= "function" or type(F.SetHealerColor) ~= "function" then
        return Fail("feature_projection_command_contract")
    end
    local visual = F:GetPresentationSettings()
    if type(visual) ~= "table" or type(visual.head) ~= "table" or type(visual.raid) ~= "table"
        or type(visual.raid.sections) ~= "table" or #visual.raid.sections ~= 4 then
        return Fail("visual_store_contract")
    end
    local screen = S.Features and S.Features.HealerScreenProjection or nil
    local head = S.UIV3 and S.UIV3.HealerHeadMarker or nil
    local raid = S.UIV3 and S.UIV3.HealerRaidOverlay or nil
    if type(screen) ~= "table" or (tonumber(screen.version) or 0) < 1 or type(screen.ProjectUnit) ~= "function"
        or type(head) ~= "table" or type(head.Describe) ~= "function"
        or type(raid) ~= "table" or type(raid.Describe) ~= "function" then
        return Fail("visual_consumer_contract")
    end
    local pageHost = S.UIV3 and S.UIV3.PageHost or nil
    local widgetHost = S.UIV3 and S.UIV3.WidgetHost or nil
    if type(pageHost) ~= "table" or type(pageHost.factories) ~= "table"
        or type(pageHost.factories["combat.healer"]) ~= "function" then return Fail("page_factory_missing") end
    local widgetSpec = type(widgetHost) == "table" and type(widgetHost.specs) == "table" and widgetHost.specs["combat.healer"] or nil
    -- User product decision in M1.16.0.18.43: the recommendation floating
    -- list is removed from Active Presentation. Keep legacy Store fields for
    -- upgrade compatibility, but loading/registering the old Widget is now a
    -- regression rather than an acceptance requirement.
    if widgetSpec ~= nil then return Fail("removed_recommendation_widget_registered") end

    local health = F:GetHealth()
    local runtimeHealth = health and health.runtime or nil
    local auraHealth = B:GetHealth()
    if F.enabled == true then
        if health.rosterHeld ~= true or health.auraHeld ~= true or health.eventsSubscribed ~= true
            or type(runtimeHealth) ~= "table" or runtimeHealth.running ~= true or auraHealth.held ~= true then
            return Fail("enabled_resource_contract")
        end
    elseif (tonumber(F.consumerCount) or 0) <= 0 then
        if health.rosterHeld == true or health.auraHeld == true or health.eventsSubscribed == true
            or (type(runtimeHealth) == "table" and runtimeHealth.running == true) or auraHealth.held == true then
            return Fail("dormant_resource_contract")
        end
    end
    local headHealth, raidHealth = head:Describe(), raid:Describe()
    local calibrating = visual.raid.calibration == true
    if F.enabled ~= true then
        if headHealth.running == true or headHealth.consumerHeld == true or headHealth.taskActive == true then
            return Fail("disabled_head_visual_resource_contract")
        end
        if calibrating then
            if raidHealth.running ~= true or raidHealth.calibrationMode ~= true or raidHealth.consumerHeld == true or raidHealth.taskActive == true then
                return Fail("standalone_calibration_contract")
            end
        elseif raidHealth.running == true or raidHealth.consumerHeld == true or raidHealth.taskActive == true then
            return Fail("disabled_raid_visual_resource_contract")
        end
    else
        if visual.head.enabled == true and (headHealth.running ~= true or headHealth.consumerHeld ~= true or headHealth.taskActive ~= true) then
            return Fail("head_visual_runtime_contract")
        end
        if visual.head.enabled ~= true and (headHealth.running == true or headHealth.consumerHeld == true or headHealth.taskActive == true) then
            return Fail("head_visual_disabled_contract")
        end
        if calibrating then
            -- Calibration is Presentation-only even while the Feature is
            -- enabled; it must not acquire an extra Healer runtime Consumer.
            if raidHealth.running ~= true or raidHealth.calibrationMode ~= true or raidHealth.consumerHeld == true or raidHealth.taskActive == true then
                return Fail("enabled_calibration_contract")
            end
        elseif visual.raid.enabled == true then
            if raidHealth.running ~= true or raidHealth.consumerHeld ~= true or raidHealth.calibrationMode == true then
                return Fail("raid_visual_runtime_contract")
            end
            if tonumber(visual.raid.effectMode) == 1 and raidHealth.taskActive == true then
                return Fail("raid_visual_static_task_contract")
            end
            if tonumber(visual.raid.effectMode) ~= 1 and raidHealth.taskActive ~= true then
                return Fail("raid_visual_animated_task_contract")
            end
        elseif raidHealth.running == true or raidHealth.consumerHeld == true or raidHealth.taskActive == true then
            return Fail("raid_visual_disabled_contract")
        end
    end
    return true
end)

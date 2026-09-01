------------------------------------------------------------------------
-- Replicated Suite V3 - Gear / Title Acceptance
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local G = S.FoundationGate
local F = S.Features and S.Features.Gear or nil
if type(G) ~= "table" or type(G.RegisterSequenceCase) ~= "function" or type(F) ~= "table" then return end

local function Fail(message) return false, tostring(message or "gear_acceptance_failed") end

G:RegisterSequenceCase("v3_m4_gear_screen_buttons", function()
    local meta = S.FeatureRegistry and S.FeatureRegistry:Get("combat_gear") or nil
    if meta == nil or tostring(meta.status) ~= "migrated_m4" or tostring(meta.authority) ~= "v3.gear" or meta.widgetCapable ~= true or meta.defaultEnabled ~= true then return Fail("metadata_contract") end
    if S.FeatureRuntime == nil or S.FeatureRuntime:IsImplemented("combat_gear") ~= true then return Fail("implementation_missing") end

    local indexStore = S.Persistence and S.Persistence:GetStore(F.IndexStoreId or "v3.gear.index") or nil
    if indexStore == nil or tostring(indexStore.owner or "") ~= "v3.gear" or tostring(indexStore.scope or "") ~= tostring(S.Persistence.Scope.Character) then
        return Fail("index_store_contract")
    end
    if tonumber(F.MaxSets) ~= 40 or type(F.EnsurePayloadStore) ~= "function" or type(F.SavePayload) ~= "function" then return Fail("sharded_store_contract") end
    if tonumber(indexStore.schemaVersion) ~= 4 or type(F.GetQuickHudState) ~= "function" or type(F.SetQuickHudVisible) ~= "function" or type(F.QuickButtonPolicy) ~= "table" then return Fail("quick_button_store_contract") end
    if type(F.GetQuickSnapSettings) ~= "function" or type(F.SetQuickSnapEnabled) ~= "function" or type(F.SetQuickSnapDistance) ~= "function"
        or type(F.SetQuickButtonGap) ~= "function" or type(F.ResetQuickSnapSettings) ~= "function" then return Fail("quick_button_snap_settings_contract") end
    local snapSettings = F:GetQuickSnapSettings()
    if type(snapSettings) ~= "table" or type(snapSettings.enabled) ~= "boolean" or tonumber(snapSettings.distance) == nil or tonumber(snapSettings.gap) == nil then return Fail("quick_button_snap_settings_state") end
    local snapDefaults = F.NormalizeQuickHud({ layoutMode = "buttons-v1" })
    if snapDefaults.snapEnabled ~= true or tonumber(snapDefaults.snapDistance) ~= 16 or tonumber(snapDefaults.buttonGap) ~= 0 then return Fail("quick_button_snap_settings_defaults") end
    local snapDisabled = F.NormalizeQuickHud({ layoutMode = "buttons-v1", snapEnabled = false, snapDistance = 27, buttonGap = 3 })
    if snapDisabled.snapEnabled ~= false or tonumber(snapDisabled.snapDistance) ~= 27 or tonumber(snapDisabled.buttonGap) ~= 3 then return Fail("quick_button_snap_settings_roundtrip") end
    if tonumber(F.QuickButtonPolicy.snapDistance) == nil or tonumber(F.QuickButtonPolicy.snapDistance) <= 0
        or S.Layout == nil or type(S.Layout.ResolveSiblingSnap) ~= "function" or type(S.Layout.ResolveScreenSnap) ~= "function"
        or S.UI == nil or type(S.UI.RegisterScreenSnap) ~= "function" or type(S.UI.ResolveScreenSnap) ~= "function" then
        return Fail("quick_button_snap_contract")
    end
    local snapX, snapY, snapped = S.Layout:ResolveSiblingSnap(417, 106, 104, 26, { { x = 300, y = 100, width = 104, height = 26 } }, { distance = 16, gapX = 0, gapY = 0 })
    if snapped ~= true or math.abs((tonumber(snapX) or 0) - 404) > 0.01 or math.abs((tonumber(snapY) or 0) - 100) > 0.01 then
        return Fail("quick_button_snap_solver")
    end
    local freeX, freeY, freeSnapped = S.Layout:ResolveSiblingSnap(700, 500, 104, 26, { { x = 300, y = 100, width = 104, height = 26 } }, { distance = 16, gapX = 0, gapY = 0 })
    if freeSnapped == true or freeX ~= 700 or freeY ~= 500 then return Fail("quick_button_free_drag_contract") end
    if type(F.IndexBudget) ~= "table" or tonumber(F.IndexBudget.maxNodes) < 1000 or type(F.PayloadBudget) ~= "table" or tonumber(F.PayloadBudget.maxNodes) < 600 then
        return Fail("gear_persistence_budget_contract")
    end

    local service = S.Services and S.Services.GearV3 or nil
    if type(service) ~= "table" or type(service.CapturePayload) ~= "function" or type(service.BuildBagSnapshot) ~= "function"
        or type(service.ValidatePayload) ~= "function" or type(service.Start) ~= "function"
        or type(service.CaptureEquippedSnapshot) ~= "function" or type(service.PayloadMatchScore) ~= "function" then
        return Fail("service_contract")
    end
    if #(service.EquipmentSlots or {}) ~= 19 or tonumber(service.BagSlots) ~= 150 then return Fail("equipment_contract") end

    -- Regression guard for the M3 save failure: a fully populated 19-slot
    -- loadout must fit AFTER the persistence metadata envelope is attached.
    local syntheticItems = {}
    for _, def in ipairs(service.EquipmentSlots or {}) do
        syntheticItems[#syntheticItems + 1] = {
            slot = def.slot, key = def.key, slotName = def.name, alternative = def.alternative == true,
            empty = false, managed = true, name = "+18 安全预算测试装备", grade = 12, itemType = 999999,
            icon = "ui/icon/test", modifierSignature = "属性甲=1;属性乙=2;属性丙=3",
        }
    end
    local synthetic = F.NormalizePayload({
        configured = true, revision = 1, capturedAt = 1, items = syntheticItems,
        title = {
            apply = true, displayName = "安全预算测试称号",
            showing = { values = { 11, "展示称号", true, 4, 5, 6 }, id = 11, name = "展示称号" },
            effect = { values = { 22, "效果称号", true, 4, 5, 6 }, id = 22, name = "效果称号" },
        },
    })
    local encoded = {
        payload = synthetic,
        __rsmeta = { framework = S.Persistence.FrameworkVersion, store = "v3.gear.payload.test", owner = "v3.gear", contractVersion = 3, lifetime = "Permanent", scope = "Character", schema = 1 },
    }
    local budgetProbe = S.Persistence:InspectPayload(encoded, F.PayloadBudget)
    if type(budgetProbe) ~= "table" or budgetProbe.ok ~= true then return Fail("gear_encoded_payload_budget:" .. tostring(budgetProbe and budgetProbe.reason)) end

    local syntheticSets = {}
    for index = 1, 40 do
        syntheticSets[index] = { id = "set_" .. tostring(index), name = "换装方案" .. tostring(index), order = index, storageId = index, configured = true, quick = true,
            quickX = 300 + index * 3, quickY = 100 + index * 2, quickPositionCustomized = true, payloadRevision = 99 }
    end
    local indexEncoded = {
        payload = { revision = 99, nextId = 41, nextStorageId = 41, sets = syntheticSets,
            quickHud = F.NormalizeQuickHud({ layoutMode = "buttons-v1", visible = true, locked = true, snapEnabled = true, snapDistance = 16, buttonGap = 0, overallOpacity = 0.9, backgroundOpacity = 0.8, textOpacity = 1 }) },
        __rsmeta = { framework = S.Persistence.FrameworkVersion, store = "v3.gear.index", owner = "v3.gear", contractVersion = 3, lifetime = "Permanent", scope = "Character", schema = 4 },
    }
    local indexBudgetProbe = S.Persistence:InspectPayload(indexEncoded, F.IndexBudget)
    if type(indexBudgetProbe) ~= "table" or indexBudgetProbe.ok ~= true then return Fail("gear_encoded_index_budget:" .. tostring(indexBudgetProbe and indexBudgetProbe.reason)) end

    local deps = {}
    for _, name in ipairs(F.ApiDependencies or {}) do deps[tostring(name)] = true end
    for _, required in ipairs({ "PLAYER", "EQUIPMENT", "BAG" }) do if deps[required] ~= true then return Fail("native_dependency:" .. required) end end
    local contract = S.NativeContract
    if type(contract) ~= "table" or contract:GetApi("PLAYER") == nil or contract:GetApi("EQUIPMENT") == nil or contract:GetApi("BAG") == nil then
        return Fail("native_contract")
    end

    if S.UIV3 == nil or S.UIV3.PageHost == nil or S.UIV3.PageHost.factories["combat.gear"] == nil then return Fail("page_contract") end
    if S.UIV3.GearQuickSettingsModalV3 == nil or type(S.UIV3.GearQuickSettingsModalV3.Open) ~= "function" then return Fail("quick_button_settings_modal_contract") end
    local quickSpec = S.UIV3.WidgetHost and S.UIV3.WidgetHost:GetSpec("combat.gear.quick") or nil
    if quickSpec == nil or quickSpec.windowingRequired ~= false then return Fail("quick_button_widget_contract") end
    if type(F.Commands) ~= "table" or type(F.Commands.ApplyQuickSnapEnabled) ~= "function"
        or type(F.Commands.ApplyQuickSnapDistance) ~= "function" or type(F.Commands.ApplyQuickButtonGap) ~= "function"
        or type(F.Commands.MarkStoreDirty) ~= "function" then return Fail("presentation_command_contract") end
    if type(F.Authority) ~= "table" or type(F.Authority.GetQuickRows) ~= "function" or type(F.Authority.DetectCurrentQuickSet) ~= "function"
        or type(F.Authority.SetQuickPosition) ~= "function" or type(F.Authority.ResetQuickPositions) ~= "function" then return Fail("quick_button_authority_contract") end

    -- The feature must be genuinely idle when not executing a user-authorized
    -- loadout. No background equipment/bag scan task is allowed.
    local runtime = service:GetRuntimeSnapshot()
    if type(runtime) ~= "table" then return Fail("runtime_snapshot") end
    if runtime.busy ~= true and S.Scheduler ~= nil and S.Scheduler.tasks ~= nil then
        local task = S.Scheduler.tasks[service.taskName]
        if task ~= nil and task.enabled == true then return Fail("idle_scheduler_task") end
    end
    return true
end)

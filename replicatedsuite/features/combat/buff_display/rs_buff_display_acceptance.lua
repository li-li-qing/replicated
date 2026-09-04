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
--   * equipment projection preserves the verified grade overlay texture
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
        or tonumber(F.SchemaVersion) ~= 4 or (tonumber(F.ProjectPlatesContractVersion) or 0) < 4
        or (tonumber(F.LayoutAuthorityContractVersion) or 0) < 1
        or type(F.GetDefaultSettingsSnapshot) ~= "function"
        or type(F.SyncTrackedProjectionFlags) ~= "function"
        or type(F.Commands) ~= "table" or type(F.Commands.SetSetting) ~= "function"
        or type(F.Commands.ApplySettingFromBinding) ~= "function" or type(F.Commands.MarkStoreDirty) ~= "function"
        or type(F.Commands.GetWidgetVisible) ~= "function" or type(F.Commands.SetWidgetVisible) ~= "function"
        or type(F.Commands.SetTrackedId) ~= "function" or type(F.Commands.ClearTrackedIds) ~= "function"
        or type(F.Commands.ResetLayoutSettings) ~= "function"
        or type(F.Commands.SetComponentField) ~= "function" or type(F.Commands.ImportTrackedIds) ~= "function"
        or type(F.Commands.GetLayoutSettingsSnapshot) ~= "function"
        or type(F.Commands.GetDefaultLayoutSettingsSnapshot) ~= "function"
        or type(F.Commands.CanPersistLayoutSettings) ~= "function"
        or type(F.Commands.PersistLayoutSettingsSnapshot) ~= "function"
        or type(F.Commands.ExportAll) ~= "function" or type(F.Commands.SerializeExport) ~= "function"
        or type(F.Commands.ParseImportText) ~= "function" or type(F.Commands.ImportAll) ~= "function"
        or (tonumber(F.BuffHeadMarkerContractVersion) or 0) < 6 then return false, "feature_contract" end
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
    local mapSettings = { showBuffs = true, showDebuffs = true, showHidden = false, classification = { [101] = "buff", [202] = "debuff", [303] = "debuff" } }
    local rows = F.ProjectStatusMap(map, { available = true, complete = true, reliable = true, revision = 1 },
        mapSettings, "player", 8, { buff = { [101] = true }, debuff = {} })
    if type(rows) ~= "table" or #rows ~= 3 or rows[1].id ~= 101 or rows[2].id ~= 202 or rows[3].id ~= 303
        or rows[1].category ~= "buff" or rows[2].category ~= "debuff" or rows[3].category ~= "debuff"
        or rows[3].detectionSource ~= "hidden" or rows[1].timeText ~= "3.0" or rows[1].tracked ~= true
        or rows[1].trackedText ~= "已追踪" or rows[3].trackedText ~= "" then return false, "projection_contract" end
    -- Hidden-sourced statuses are an independent fact source: they must survive
    -- a disabled buff/debuff category toggle so 只看隐藏 always has rows to show.
    local hiddenOnlyRows = F.ProjectStatusMap(map, { available = true, complete = true, reliable = true, revision = 1 },
        { showBuffs = true, showDebuffs = false, showHidden = false, classification = mapSettings.classification }, "player", 8)
    if type(hiddenOnlyRows) ~= "table" or #hiddenOnlyRows ~= 2 or hiddenOnlyRows[1].id ~= 101
        or hiddenOnlyRows[2].id ~= 303 or hiddenOnlyRows[2].detectionSource ~= "hidden" then return false, "hidden_source_not_suppressed_by_category_toggle" end
    -- Settings projection exposes all 10 head components + category-keyed tracked.
    if (tonumber(F.LayoutAuthorityContractVersion) or 0) < 2
        or (tonumber(F.LayoutPersistenceBoundaryContractVersion) or 0) < 1 then
        return false, "layout_persistence_boundary_contract_missing"
    end
    local layoutSnapshot = F.Commands:GetLayoutSettingsSnapshot()
    local defaultLayoutSnapshot = F.Commands:GetDefaultLayoutSettingsSnapshot()
    if type(layoutSnapshot) ~= "table" or type(layoutSnapshot.components) ~= "table"
        or type(defaultLayoutSnapshot) ~= "table" or type(defaultLayoutSnapshot.components) ~= "table" then
        return false, "layout_snapshot_projection_missing"
    end
    if layoutSnapshot.tracked ~= nil or layoutSnapshot.classification ~= nil then
        return false, "layout_snapshot_leaks_tracking_authority"
    end

    local settingsProjection = type(F.GetSettingsProjection) == "function" and F:GetSettingsProjection() or {}
    local components = type(settingsProjection.components) == "table" and settingsProjection.components or {}
    local tracked = type(settingsProjection.tracked) == "table" and settingsProjection.tracked or {}
    local componentKeys = { "buffs", "debuffs", "distance", "class", "gearScore", "mainHand", "offHand", "ranged", "wings", "castBar" }
    local missingComponents = 0
    for _, key in ipairs(componentKeys) do if type(components[key]) ~= "table" then missingComponents = missingComponents + 1 end end
    if missingComponents ~= 0 or type(tracked.buff) ~= "table" or type(tracked.debuff) ~= "table"
        or settingsProjection.freezeEnabled ~= false or settingsProjection.showHidden ~= false then return false, "schema4_settings_projection" end
    -- Head plates projection: bounded tracked rows + enabled component data.
    local plates = F.ProjectPlates({
        buffRows = { { id = 101, name = "A" } }, distance = 1234.5, class = "法师", gearScore = 12345,
        mainHand = { icon = "weapon.dds", gradeIconPath = "grade.dds", name = "武器" },
    }, settingsProjection)
    if type(plates) ~= "table" or type(plates.components) ~= "table" or type(plates.buffs) ~= "table"
        or type(plates.distance) ~= "table" or plates.distance.value ~= "1.23km"
        or type(plates.class) ~= "table" or plates.class.value ~= "法师"
        or type(plates.gearScore) ~= "table" or plates.gearScore.value ~= "12345"
        or type(plates.mainHand) ~= "table" or plates.mainHand.icon ~= "weapon.dds"
        or plates.mainHand.gradeIconPath ~= "grade.dds" then return false, "plates_projection_contract" end
    -- Pure compatibility checks: import must match the Store's 1024/category
    -- budget, and component-specific fields exposed by the UI must round-trip.
    local ids = {}
    for i = 1, 40 do ids[#ids + 1] = tostring(70000 + i) end
    local parsed40 = F:ParseImportText("BUFF=" .. table.concat(ids, ","))
    if type(parsed40) ~= "table" or type(parsed40.data) ~= "table"
        or #(parsed40.data.tracked.buff or {}) ~= 40 then return false, "import_tracking_cap_regression" end
    local serialized = F:SerializeExport({ schemaVersion = 4, tracked = { buff = {}, debuff = {} }, classification = {},
        components = { buffs = { enabled = true, x = 0, y = 0, size = 29, fontSize = 11, alpha = 1, spacing = 5, maxPerRow = 11, maxRows = 3 },
            castBar = { enabled = true, x = 0, y = 0, size = 7, fontSize = 12, alpha = 1, width = 177, showText = false } }, settings = {} })
    local roundTrip = F:ParseImportText(serialized)
    local rtComponents = roundTrip and roundTrip.data and roundTrip.data.components or {}
    if type(rtComponents.buffs) ~= "table" or rtComponents.buffs.spacing ~= 5
        or rtComponents.buffs.maxPerRow ~= 11 or rtComponents.buffs.maxRows ~= 3
        or type(rtComponents.castBar) ~= "table" or rtComponents.castBar.width ~= 177
        or rtComponents.castBar.showText ~= false then return false, "component_export_roundtrip_regression" end
    return true
end)

------------------------------------------------------------------------
-- v6: HealthBarProxy anchor layout geometry (pure function contract).
-- Covers the 15 acceptance geometry cases from the plate-layout task. All
-- assertions run against ComputePlateLayout without touching widgets/native.
------------------------------------------------------------------------
G:RegisterSequenceCase("v3_m16_18_buff_display_plate_geometry", function()
    local markers = S.UIV3 and S.UIV3.BuffHeadMarkersV3 or nil
    if type(markers) ~= "table" or type(markers.ComputePlateLayout) ~= "function" then
        return false, "compute_plate_layout_missing"
    end
    local Compute = markers.ComputePlateLayout

    -- Base settings use the 1.2× defaults (icons 29, equip 26, bar 180×24).
    local function base(overrides)
        local s = {
            plate = { x = 0, y = 0, width = 180, height = 24 },
            info = { enabled = true, x = 0, y = 0, fontSize = 12, showClass = true, showGear = true, showDistance = true },
            plateScale = 1.0,
            gaps = { buffToBar = 8, debuffToBar = 8, infoToBuff = 7, equipToBar = 7, castToBar = 6, castToDebuff = 5, rowGap = 4 },
            components = {
                buffs = { enabled = true, x = 0, y = 0, size = 29, spacing = 2, maxPerRow = 8, maxRows = 4 },
                debuffs = { enabled = true, x = 0, y = 0, size = 29, spacing = 2, maxPerRow = 8, maxRows = 4 },
                class = { enabled = true }, gearScore = { enabled = true }, distance = { enabled = true },
                mainHand = { enabled = true, size = 26 }, offHand = { enabled = true, size = 26 },
                ranged = { enabled = true, size = 26 }, wings = { enabled = true, size = 26 },
                castBar = { enabled = true, width = 144, size = 7, fontSize = 12 },
            },
        }
        if type(overrides) == "table" then
            for k, v in pairs(overrides) do s[k] = v end
        end
        return s
    end
    local function layout(buffCount, debuffCount, equip, settings)
        return Compute(500, 400, settings or base(), buffCount, debuffCount, equip or { mainHand = true, offHand = true, wings = true, ranged = true })
    end

    -- CASE 1: 0 buff / 0 debuff -> info sits directly above the bar.
    local l1 = layout(0, 0)
    if l1.info.top + l1.info.height >= l1.bar.top then return false, "case1_info_not_above_bar" end

    -- CASE 2/3/4: actual buff rows (not MaxRows) drive info placement.
    local l1buff = layout(1, 0)
    local l8buff = layout(8, 0)
    local l9buff = layout(9, 0)
    if l1buff.buff.actualRows ~= 1 then return false, "case2_actual_rows_wrong:" .. tostring(l1buff.buff.actualRows) end
    if l8buff.buff.actualRows ~= 1 then return false, "case3_actual_rows_wrong" end
    if l9buff.buff.actualRows ~= 2 then return false, "case4_actual_rows_wrong:" .. tostring(l9buff.buff.actualRows) end
    if l1buff.info.top + l1buff.info.height >= l1buff.buff.topMostTop then return false, "case2_info_not_above_actual_row" end
    if l9buff.buff.topMostTop >= l1buff.buff.topMostTop then return false, "case4_rows_not_stacking_upward" end

    -- CASE 5: 1 debuff first row = bar.bottom + DebuffToBarGap(8).
    local l1deb = layout(0, 1)
    local expectedGap = 8 * 1.0
    if math.abs(l1deb.debuff.firstTop - (l1deb.bar.bottom + expectedGap)) > 1 then
        return false, "case5_debuff_gap_wrong:" .. tostring(l1deb.debuff.firstTop - l1deb.bar.bottom)
    end

    -- CASE 6/7/8: equipment collapse (no empty slots).
    local lOff = layout(0, 0, { mainHand = true, offHand = false, wings = true, ranged = false })
    if lOff.equip.offHand ~= false or lOff.equip.mainHand ~= true then return false, "case6_collapse_wrong" end
    local lMain = layout(0, 0, { mainHand = false, offHand = true, wings = true, ranged = false })
    if lMain.equip.mainHand ~= false or lMain.equip.offHand ~= true then return false, "case7_collapse_wrong" end
    local lNoWing = layout(0, 0, { mainHand = true, offHand = true, wings = false, ranged = false })
    if lNoWing.equip.wings ~= false then return false, "case8_collapse_wrong" end

    -- CASE 9/10: left flank is offHand (closest) -> mainHand -> ranged;
    -- right flank contains wings/back only.
    local lBoth = layout(0, 0, { mainHand = true, offHand = true, wings = true, ranged = true })
    if #lBoth.leftGroup.slots ~= 3 or #lBoth.rightGroup.slots ~= 1 then
        return false, "case9_10_equip_group_slot_count_wrong:left=" .. tostring(#lBoth.leftGroup.slots) .. ",right=" .. tostring(#lBoth.rightGroup.slots)
    end
    local sl = lBoth.leftGroup.slots
    if sl[1].key ~= "offHand" or sl[2].key ~= "mainHand" or sl[3].key ~= "ranged" then
        return false, "case9_left_order_wrong:" .. tostring(sl[1].key) .. "," .. tostring(sl[2].key) .. "," .. tostring(sl[3].key)
    end
    if lBoth.rightGroup.slots[1].key ~= "wings" then return false, "case9_right_order_wrong" end
    -- offHand remains closest to bar: x = 410-7-26 = 377.
    if sl[1].x ~= 377 then return false, "case9_offhand_position_wrong:" .. tostring(sl[1].x) end
    if sl[3].x >= sl[2].x then return false, "case9_ranged_not_outermost" end

    -- CASE 11/12: bar geometry stable regardless of info toggle.
    local lNoInfo = Compute(500, 400, base({ info = { enabled = false, fontSize = 12 } }), 3, 0, { mainHand = true, offHand = true, wings = true, ranged = true })
    if lNoInfo.bar.top >= lNoInfo.bar.bottom then return false, "case11_bar_geometry_wrong" end

    -- CASE 13: fresh config defaults are anchor-relative (component y == 0).
    local defaultSettings = F:GetDefaultSettingsSnapshot()
    local comps = type(defaultSettings.components) == "table" and defaultSettings.components or {}
    if type(comps.buffs) ~= "table" or comps.buffs.y ~= 0 or comps.debuffs.y ~= 0 then
        return false, "case13_fresh_defaults_not_anchor_relative"
    end
    -- ranged is opt-in by default; wings/back remains the default right slot.
    if comps.ranged.enabled ~= false or comps.wings.enabled ~= true then
        return false, "case13_ranged_wings_default_wrong"
    end
    if defaultSettings.headIconSize ~= nil or defaultSettings.headMaxIcons ~= nil then
        return false, "case13_duplicate_icon_authority_present"
    end

    -- CASE 14/15: geometry with 1.2× sizes. anchor(500,400), bar 180x24 ->
    -- left 410/right 590/top 388/bottom 412. Buff 29px: firstTop=388-8-29=351.
    -- Debuff: firstTop=412+8=420. Equip 26px: offHand at 410-7-26=377, wings at 590+7=597.
    if l1.bar.left ~= 410 or l1.bar.right ~= 590 or l1.bar.top ~= 388 or l1.bar.bottom ~= 412 then
        return false, "case14_bar_rect_wrong:" .. tostring(l1.bar.left) .. "," .. tostring(l1.bar.right)
    end
    if l1buff.buff.firstTop ~= 351 or l1deb.debuff.firstTop ~= 420 then
        return false, "case14_row_positions_wrong:" .. tostring(l1buff.buff.firstTop) .. "," .. tostring(l1deb.debuff.firstTop)
    end
    local sL = l1.leftGroup.slots[1]  -- offHand (closest to bar)
    local sR = l1.rightGroup.slots[1] -- wings
    if sL.key ~= "offHand" then return false, "case14_left_first_key_wrong:" .. tostring(sL.key) end
    if sL.x ~= 377 or sR.x ~= 597 then
        return false, "case14_equip_positions_wrong:" .. tostring(sL.x) .. "," .. tostring(sR.x)
    end
    -- Vertical separation: no two regions overlap (info < buff < bar < debuff).
    local buffBottom = l1buff.buff.firstTop + 29
    if l1buff.info.top + l1buff.info.height > l1buff.buff.firstTop - 2
        or buffBottom > l1.bar.top - 4
        or l1deb.debuff.firstTop < l1.bar.bottom + 4 then
        return false, "case15_vertical_separation_failed"
    end

    -- Name resolution + compact time format tests.
    -- Name passthrough for a buff entry. Self-contained: the statusmap_contract
    -- case is a separate closure that owns its own `rows`/`map`, so re-project
    -- here instead of reading an undefined upvalue (would throw at runtime).
    local nameProbe = F.ProjectStatusMap(
        { [101] = { id = 101, name = "A", iconPath = "a.dds", stack = 2, timeLeft = 3000, sources = { buff = true } } },
        { available = true, complete = true, reliable = true, revision = 1 },
        { showBuffs = true, showDebuffs = true, showHidden = false, classification = { [101] = "buff" } },
        "player", 8, { buff = { [101] = true }, debuff = {} })
    if type(nameProbe) ~= "table" or #nameProbe ~= 1 or nameProbe[1].name ~= "A" then
        return false, "projection_name_valid_passthrough"
    end
    local nameMap = { [22263] = { id = 22263, name = "测试减益", iconPath = "x.dds", stack = 1, timeLeft = 21000, sources = { debuff = true } } }
    local nameRows = F.ProjectStatusMap(nameMap, { available = true }, { showBuffs = true, showDebuffs = true, classification = {} }, "player", 8)
    if type(nameRows) ~= "table" or #nameRows ~= 1 or nameRows[1].name ~= "测试减益"
        or nameRows[1].id ~= 22263 or nameRows[1].effectTypeText ~= "Debuff"
        or nameRows[1].timeText ~= "21.0" then return false, "case_a_name_resolution" end
    local idNameMap = { [22263] = { id = 22263, name = "22263", iconPath = "", stack = 1, sources = { debuff = true } } }
    local idNameRows = F.ProjectStatusMap(idNameMap, { available = true }, { showBuffs = true, showDebuffs = true, classification = {} }, "player", 8)
    if type(idNameRows) ~= "table" or #idNameRows ~= 1 then return false, "case_b_row_count" end
    if idNameRows[1].name == "22263" then return false, "case_b_name_equals_id_not_resolved" end
    -- Compact time: 80010ms = 1m20s1cs → "1.20.01".
    local timeMap = { [999] = { id = 999, name = "T", stack = 1, timeLeft = 80010, sources = { buff = true } } }
    local timeRows = F.ProjectStatusMap(timeMap, { available = true }, { showBuffs = true, showDebuffs = true, classification = {} }, "player", 8)
    if type(timeRows) ~= "table" or #timeRows ~= 1 or timeRows[1].timeText ~= "1.20.01" then
        return false, "compact_time_format_wrong:" .. tostring(timeRows[1] and timeRows[1].timeText)
    end

    return true
end)

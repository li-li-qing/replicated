------------------------------------------------------------------------
-- Replicated Suite V3 - Buff Display Acceptance (schema 5)
-- Non-destructive contract checks. No feature is enabled by this case.
--
-- Schema 5 contracts covered here:
--   * store schemaVersion == 5, with schema4 single-HUD integrity recovery + 4->5 migration
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
    if store == nil or tostring(store.owner or "") ~= "v3.buff_display" or tonumber(store.schemaVersion) ~= 5 then return false, "store_contract" end
    if type(store.rebuildCanonicalForIntegrity) ~= "function" or type(store.recoverKnownLegacyCanonical) ~= "function"
        or type(store.migrate) ~= "function" then return false, "schema5_migration_hooks_missing" end
    -- 中文维护注释（非破坏性 schema4→5 验收）：构造一个“不含 targetLayout”的旧单 HUD
    -- Domain，要求 historical hook 返回仍不含新字段的旧 canonical；随后正式 migrate 必须补出
    -- targetLayout。这里只验证纯函数边界，不 Apply、不保存、不取得 Consumer。
    local legacyProbeSettings = type(F.GetDefaultSettingsSnapshot) == "function" and F:GetDefaultSettingsSnapshot() or nil
    if type(legacyProbeSettings) ~= "table" then return false, "schema5_migration_probe_defaults_missing" end
    legacyProbeSettings = S.Utils.DeepCopy(legacyProbeSettings)
    legacyProbeSettings.targetLayout = nil
    legacyProbeSettings.plate = type(legacyProbeSettings.plate) == "table" and legacyProbeSettings.plate or {}
    legacyProbeSettings.plate.y = nil -- 旧 schema4 对“plate table 存在但 y 缺失”的 fallback 是 0；用于防止只删 targetLayout 的伪恢复。
    local legacyProbe = { settings = legacyProbeSettings, widgetVisible = false }
    local previousHistoricalProbe = store.lastHistoricalRecoveryProbe
    local historicalProbe, recoveredProbe = store.rebuildCanonicalForIntegrity(legacyProbe, "ACCEPTANCE", nil, {
        __rsmeta = { store = "v3.buff_display", owner = "v3.buff_display", framework = 3, schema = 4, transportVersion = 1 },
    })
    -- 中文维护注释：Acceptance 不得污染实机恢复诊断。hook 为了真实故障会写 runtime-only
    -- probe，因此合成验收完成后必须原样恢复旧值，保证“恢复探针”只反映真实 LoadStore。
    store.lastHistoricalRecoveryProbe = previousHistoricalProbe
    if type(historicalProbe) ~= "table" or type(historicalProbe.settings) ~= "table"
        or historicalProbe.settings.targetLayout ~= nil or tonumber(historicalProbe.settings.plate and historicalProbe.settings.plate.y) ~= 0
        or type(recoveredProbe) ~= "table" then return false, "schema4_historical_canonical_rebuild" end
    local migratedProbe = store.migrate(recoveredProbe, 4, 5)
    if type(migratedProbe) ~= "table" or type(migratedProbe.settings) ~= "table"
        or type(migratedProbe.settings.targetLayout) ~= "table"
        or type(migratedProbe.settings.targetLayout.components) ~= "table" then return false, "schema4_to_5_dual_hud_migration" end
    -- Shared classification service (schema 4+ Authority; schema5 only adds dual-HUD persistence).
    local classification = S.Services and S.Services.StatusClassificationV3 or nil
    if type(classification) ~= "table" or (tonumber(classification.version) or 0) < 1
        or type(classification.ClassifyEntry) ~= "function" or type(classification.ClassifyId) ~= "function"
        or type(classification.SetOverride) ~= "function" or type(classification.GetOverrides) ~= "function"
        or type(classification.ApplyOverrides) ~= "function" or type(classification.GetRegistrySnapshot) ~= "function"
        or type(classification.GetHealth) ~= "function" then return false, "classification_service_contract" end
    -- 中文维护注释（.18.208 装分/API 与目标默认模板契约）：
    -- 问题原因：UnitGearScore 的 comma 参数曾被误作 target 标志，且 target 装分被 kind gate
    -- 阻断；同时发行模板开始拥有已实机确认的 TARGET|EQUIP 默认值。Acceptance 只验证声明
    -- 能力与共享 parser，不主动读取目标、不调用 X2Unit、不写 Store。旧模块热重载残留必须
    -- fail-closed，避免 UI 看似可用却继续吞掉格式化装分或恢复成错误目标默认值。
    if type(F.ProjectStatusMap) ~= "function" or type(F.ProjectPlates) ~= "function"
        or type(F.GetProjection) ~= "function" or type(F.GetSettingsProjection) ~= "function"
        or type(F.RefreshScope) ~= "function" or type(F.Refresh) ~= "function"
        or type(F.AcquireConsumer) ~= "function" or type(F.ReleaseConsumer) ~= "function"
        or tonumber(F.SchemaVersion) ~= 5 or (tonumber(F.ProjectPlatesContractVersion) or 0) < 4
        or (tonumber(F.LayoutAuthorityContractVersion) or 0) < 3
        or (tonumber(F.HudCalibrationContractVersion) or 0) < 1
        or (tonumber(F.Schema5DualHudMigrationContractVersion) or 0) < 1
        or (tonumber(F.TargetDefaultTemplateContractVersion) or 0) < 1
        or (tonumber(F.GearScoreApiContractVersion) or 0) < 1
        or type(S.Utils) ~= "table" or (tonumber(S.Utils.GearScoreParseContractVersion) or 0) < 1
        or type(S.Utils.ParseGearScore) ~= "function"
        or type(F.GetHeadPolicyProjection) ~= "function"
        or type(F.GetScopeSettingsProjection) ~= "function"
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
        or type(F.Commands.GetHudCalibrationSnapshot) ~= "function"
        or type(F.Commands.GetDefaultHudCalibrationSnapshot) ~= "function"
        or type(F.Commands.PersistHudCalibrationSnapshot) ~= "function"
        or type(F.Commands.CanPersistLayoutSettings) ~= "function"
        or type(F.Commands.PersistLayoutSettingsSnapshot) ~= "function"
        or type(F.Commands.ExportAll) ~= "function" or type(F.Commands.SerializeExport) ~= "function"
        or type(F.Commands.ParseImportText) ~= "function" or type(F.Commands.ImportAll) ~= "function"
        or (tonumber(F.BuffHeadMarkerContractVersion) or 0) < 9 then return false, "feature_contract" end
    -- Head renderer gate contract: tracked-independent start (HasRenderableComponents
    -- gate) + GetDiagnostics triage surface + anchorFailure trail on hidden scopes.
    local headMarkers = S.UIV3 and S.UIV3.BuffHeadMarkersV3 or nil
    if type(headMarkers) ~= "table" or (tonumber(headMarkers.version) or 0) < 2
        or type(headMarkers.GetDiagnostics) ~= "function"
        or type(headMarkers.metrics) ~= "table" or type(headMarkers.metrics.anchorFailures) ~= "table"
        or type(headMarkers.Start) ~= "function" or type(headMarkers.Stop) ~= "function" or type(headMarkers.Reconcile) ~= "function"
        or type(headMarkers.VisualTick) ~= "function" or (tonumber(headMarkers.CastYOffsetContractVersion) or 0) < 1
        or (tonumber(headMarkers.BuffIconFontSizeContractVersion) or 0) < 1
        or (tonumber(headMarkers.LiveHudSuppressionContractVersion) or 0) < 1
        or (tonumber(headMarkers.EquipmentIndependentOffsetContractVersion) or 0) < 1
        or type(headMarkers.SetCalibrationSuppressed) ~= "function" then return false, "head_marker_gate_contract" end
    -- 中文维护注释（HUD 校准交互契约 v3）：.18.206 在方向适配/面板拖动基础上增加全局位置预览，
    -- 并要求正式 Renderer 支持仅 Presentation 层的校准隐藏。Acceptance 只检查声明能力，不创建
    -- Native Widget、不写 Draft/Store、不取得或释放 Consumer。兼容边界：schema5 不变；旧校准器、
    -- 旧 Renderer 或旧 HUD 布局页若热重载残留必须 fail-closed，避免校准画面同时出现正式 HUD。
    -- .18.207 继续要求 equipment local-offset 与 HUD_TEMPLATE_V1 Draft snapshot 两个能力；前者防止
    -- 主手/副手/远程位置串联，后者只读校准 Draft 并分行输出，不取得新的 Consumer、不写 Store。
    local calibration = S.UIV3 and S.UIV3.BuffHudCalibrationV3 or nil
    if type(calibration) ~= "table" or (tonumber(calibration.version) or 0) < 3
        or (tonumber(F.HudCalibrationPresentationContractVersion) or 0) < 5
        or (tonumber(calibration.DiagnosticsContractVersion) or 0) < 4
        or (tonumber(calibration.ScreenCoordinateAdapterContractVersion) or 0) < 1
        or (tonumber(calibration.PanelDragContractVersion) or 0) < 1
        or (tonumber(calibration.ContextualControlsContractVersion) or 0) < 1
        or (tonumber(calibration.GlobalPreviewContractVersion) or 0) < 1
        or (tonumber(calibration.LiveHudSuppressionContractVersion) or 0) < 1
        or (tonumber(calibration.TemplateSnapshotContractVersion) or 0) < 1
        or type(calibration.BuildTemplateSnapshotLines) ~= "function" or type(calibration.OutputTemplateSnapshot) ~= "function"
        or type(calibration.ToggleGlobalPreview) ~= "function"
        or type(calibration.Open) ~= "function" or type(calibration.Exit) ~= "function"
        or type(calibration.SetScope) ~= "function" or type(calibration.SetComponent) ~= "function"
        or type(calibration.SyncPlayerToTarget) ~= "function" or type(calibration.GetDraftSnapshot) ~= "function"
        or type(calibration.GetDiagnostics) ~= "function"
        or (tonumber(F.HudLayoutPageMeasureContractVersion) or 0) < 1 then
        return false, "hud_calibration_presentation_contract"
    end
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
    if type(layoutSnapshot.targetLayout) ~= "table" or type(layoutSnapshot.targetLayout.components) ~= "table" then
        return false, "dual_hud_layout_snapshot_missing"
    end
    local hudSnapshot = F.Commands:GetHudCalibrationSnapshot()
    local defaultHudSnapshot = F.Commands:GetDefaultHudCalibrationSnapshot()
    if type(hudSnapshot) ~= "table" or type(hudSnapshot.player) ~= "table" or type(hudSnapshot.target) ~= "table"
        or type(hudSnapshot.player.components) ~= "table" or type(hudSnapshot.target.components) ~= "table"
        or type(defaultHudSnapshot) ~= "table" or type(defaultHudSnapshot.player) ~= "table" or type(defaultHudSnapshot.target) ~= "table" then
        return false, "dual_hud_calibration_snapshot_missing"
    end
    -- Detached-snapshot contract: calibration draft edits must never mutate Store before Save & Exit.
    local freshBefore = F.Commands:GetHudCalibrationSnapshot()
    local oldTargetX = tonumber(freshBefore.target.plate and freshBefore.target.plate.x) or 0
    hudSnapshot.target.plate.x = oldTargetX + 17
    local freshAfter = F.Commands:GetHudCalibrationSnapshot()
    if (tonumber(freshAfter.target.plate and freshAfter.target.plate.x) or 0) ~= oldTargetX then
        return false, "hud_calibration_snapshot_aliases_store"
    end
    local playerProjection = F:GetScopeSettingsProjection("player")
    local targetProjection = F:GetScopeSettingsProjection("target")
    if type(playerProjection) ~= "table" or type(playerProjection.components) ~= "table"
        or type(targetProjection) ~= "table" or type(targetProjection.components) ~= "table" then
        return false, "scope_settings_projection_missing"
    end

    local settingsProjection = type(F.GetSettingsProjection) == "function" and F:GetSettingsProjection() or {}
    local components = type(settingsProjection.components) == "table" and settingsProjection.components or {}
    local tracked = type(settingsProjection.tracked) == "table" and settingsProjection.tracked or {}
    local componentKeys = { "buffs", "debuffs", "distance", "class", "gearScore", "mainHand", "offHand", "ranged", "wings", "castBar" }
    local missingComponents = 0
    for _, key in ipairs(componentKeys) do if type(components[key]) ~= "table" then missingComponents = missingComponents + 1 end end
    if missingComponents ~= 0 or type(tracked.buff) ~= "table" or type(tracked.debuff) ~= "table"
        or settingsProjection.freezeEnabled ~= false or settingsProjection.showHidden ~= false then return false, "schema5_settings_projection" end
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
    local serialized = F:SerializeExport({ schemaVersion = 5, tracked = { buff = {}, debuff = {} }, classification = {},
        components = { buffs = { enabled = true, x = 0, y = 0, size = 29, fontSize = 11, alpha = 1, spacing = 5, maxPerRow = 11, maxRows = 3 },
            castBar = { enabled = true, x = 0, y = 0, size = 7, fontSize = 12, alpha = 1, width = 177, showText = false } },
        hud = { player = { plateScale = 1.1, plate = { x = 7, y = 22 }, info = { x = 3, y = -4 } },
            target = { plateScale = 0.9, plate = { x = -15, y = 31, width = 166, height = 19 }, info = { x = 8, y = -9, fontSize = 13 },
                components = { buffs = { enabled = true, x = 5, y = -2, size = 31, fontSize = 12, alpha = 1, spacing = 4, maxPerRow = 9, maxRows = 3 } } } },
        settings = {} })
    local roundTrip = F:ParseImportText(serialized)
    local rtComponents = roundTrip and roundTrip.data and roundTrip.data.components or {}
    if type(rtComponents.buffs) ~= "table" or rtComponents.buffs.spacing ~= 5
        or rtComponents.buffs.maxPerRow ~= 11 or rtComponents.buffs.maxRows ~= 3
        or type(rtComponents.castBar) ~= "table" or rtComponents.castBar.width ~= 177
        or rtComponents.castBar.showText ~= false then return false, "component_export_roundtrip_regression" end
    local rtHud = roundTrip and roundTrip.data and roundTrip.data.hud or {}
    if type(rtHud.player) ~= "table" or tonumber(rtHud.player.plateScale) ~= 1.1
        or type(rtHud.target) ~= "table" or tonumber(rtHud.target.plateScale) ~= 0.9
        or type(rtHud.target.plate) ~= "table" or tonumber(rtHud.target.plate.x) ~= -15
        or type(rtHud.target.components) ~= "table" or type(rtHud.target.components.buffs) ~= "table"
        or tonumber(rtHud.target.components.buffs.maxPerRow) ~= 9 then return false, "dual_hud_export_roundtrip_regression" end
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

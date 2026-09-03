------------------------------------------------------------------------
-- Replicated Suite V3 - Healer Page (M1.16.0.18)
--
-- Presentation-only consumer of the V3 Healer Feature projection.
-- No X2Unit/X2Team access is allowed here. Runtime facts stay in
-- TeamRosterV3/AuraObservationV3/Healer Domain; this page owns only UI state.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI, D = S.RSUI, S.UIV3Design
local PageHost = S.UIV3 and S.UIV3.PageHost or nil
local Feature = S.Features and S.Features.Healer or nil
if type(RSUI) ~= "table" or type(D) ~= "table" or type(PageHost) ~= "table" or type(Feature) ~= "table" then return end

local FEATURE_ID, STORE_ID = "combat_healer", "v3.healer"
local ROUTE = "combat.healer"
local CONSUMER = "page:combat_healer"
local function Settings() return Feature:GetSettingsProjection() end

local function RunAction(id, button, execute, busyText)
    if S.ActionRunner ~= nil then
        return S.ActionRunner:Run({
            id = "healer." .. tostring(id), button = button, busyText = busyText or "处理中…",
            notify = true, execute = execute,
        })
    end
    return execute()
end

local function N(value, fallback) return tonumber(value) or tonumber(fallback) or 0 end
local function Percent(value) return value ~= nil and string.format("%.1f%%", N(value)) or "--" end
local function Distance(value) return value ~= nil and string.format("%.1fm", N(value)) or "--" end
local function Score(value) return value ~= nil and string.format("%.1f", N(value)) or "--" end
local function HealthText(row)
    local current, maximum = N(row and row.currentHealth), N(row and row.maxHealth)
    if maximum <= 0 then return "--" end
    return tostring(math.floor(current + 0.5)) .. "/" .. tostring(math.floor(maximum + 0.5))
end

local ROLE_NAMES = { [1] = "普通", [2] = "主坦", [3] = "副坦", [4] = "治疗", [5] = "未知" }
local function RoleText(value) return ROLE_NAMES[math.floor(N(value, 5))] or "未知" end
local function LevelTone(level)
    level = math.floor(N(level, 1))
    if level >= 4 then return "red" end
    if level == 3 then return "warn" end
    if level == 2 then return "accent" end
    return "green"
end

local function SourceText(mask)
    mask = math.max(0, math.floor(N(mask)))
    local out = {}
    if mask % 2 >= 1 then out[#out + 1] = "Buff" end
    if math.floor(mask / 2) % 2 >= 1 then out[#out + 1] = "Debuff" end
    if math.floor(mask / 4) % 2 >= 1 then out[#out + 1] = "隐藏" end
    return #out > 0 and table.concat(out, "/") or "状态"
end

local function RecommendationColumns()
    return {
        { id = "rank", title = "#", field = "rankText", size = "fixed", width = 34, minWidth = 30 },
        { id = "name", title = "成员", field = "name", size = "fill", fill = 1.2, minWidth = 110,
            getTone = function(row) return row and row.tone or "default" end },
        { id = "hp", title = "生命", field = "hpText", size = "fixed", width = 92, minWidth = 76,
            getTone = function(row) return row and row.tone or "default" end },
        { id = "distance", title = "距离", field = "distanceText", size = "fixed", width = 70, minWidth = 60 },
        { id = "score", title = "评分", field = "scoreText", size = "fixed", width = 62, minWidth = 54,
            getTone = function(row) return row and row.tone or "default" end },
        { id = "role", title = "职责", field = "roleText", size = "fixed", width = 62, minWidth = 52 },
        { id = "state", title = "状态", field = "stateText", size = "fill", fill = 1.35, minWidth = 135,
            getTone = function(row) return row and row.tone or "muted" end },
    }
end

local function StatusColumns()
    return {
        { id = "icon", title = "", field = "iconPath", cellType = "icon", iconSize = 18,
            fallbackIcon = "ui/icon/icon_unknown_item.dds", size = "fixed", width = 28, minWidth = 26 },
        { id = "name", title = "状态", field = "name", size = "fill", fill = 1.2, minWidth = 100 },
        { id = "id", title = "ID", field = "idText", size = "fixed", width = 72, minWidth = 60 },
        { id = "source", title = "来源", field = "sourceText", size = "fixed", width = 74, minWidth = 62 },
        { id = "stack", title = "层数", field = "stackText", size = "fixed", width = 48, minWidth = 42 },
        { id = "time", title = "剩余", field = "timeText", size = "fixed", width = 70, minWidth = 58 },
    }
end

local function BuildPage(parent, route)
    local loaded, loadErr = Feature:EnsureStoreLoaded()
    if loaded ~= true then return nil, "治疗辅助设置读取失败：" .. tostring(loadErr or "未知错误") end
    local root, rootErr = D:PageRoot(parent, "v3_page_healer")
    if root == nil then return nil, "页面根组件创建失败：" .. tostring(rootErr or "未知错误") end

    D:PageHeader(root, "v3_healer_header", "治疗辅助",
        "以团队色块显示治疗优先级；页面只负责校准与规则设置，不再显示推荐列表悬浮窗/成员明细表。")

    local summaryGrid = RSUI:UniformGrid({
        id = "v3_healer_summary_grid", parent = root, minCellWidth = 190, minCellHeight = 68, maxColumns = 3, gap = 7,
        slot = { size = "auto", minHeight = 70, hAlign = "fill" },
    })
    local runtimeCard = D:InfoCard(summaryGrid, { id = "v3_healer_runtime_card", title = "运行状态", value = "已关闭", detail = "--", detailMaxLines = 2 })
    local recommendationCard = D:InfoCard(summaryGrid, { id = "v3_healer_recommend_card", title = "颜色判定", value = "0 人", detail = "后台候选仅用于团队色块，不在页面展示名单。", detailMaxLines = 2 })
    local observationCard = D:InfoCard(summaryGrid, { id = "v3_healer_observation_card", title = "观察覆盖", value = "--", detail = "--", detailMaxLines = 2 })

    local actions = RSUI:HorizontalBox({ id = "v3_healer_actions", parent = root, gap = 6,
        slot = { size = "fixed", height = 31, hAlign = "fill" } })
    local featureButton = RSUI:Button({ id = "v3_healer_feature_toggle", parent = actions, text = "启用功能", compact = true,
        slot = { size = "fixed", width = 96 } })
    local calibrationButton = RSUI:Button({ id = "v3_healer_raid_calibration_action", parent = actions, text = "校准团队色块", compact = true,
        slot = { size = "fixed", width = 118 } })
    local rosterButton = RSUI:Button({ id = "v3_healer_roster_refresh", parent = actions, text = "刷新团队", compact = true,
        slot = { size = "fixed", width = 96 } })
    local actionHint = RSUI:Text({ id = "v3_healer_action_hint", parent = actions,
        text = "关闭后会停止后台治疗扫描与状态观察，不会继续占用团战资源。", fontSize = 8, tone = "muted", overflow = "ellipsis",
        slot = { size = "fill", fill = 1 } })

    local settingsMode = "strategy"
    local settingsSwitcher = RSUI:HorizontalBox({ id = "v3_healer_settings_switcher", parent = root, gap = 5,
        slot = { size = "fixed", height = 29, hAlign = "fill" } })
    local strategyButton = RSUI:Button({ id = "v3_healer_strategy_mode", parent = settingsSwitcher, text = "治疗策略", compact = true,
        slot = { size = "fixed", width = 86 } })
    local displayButton = RSUI:Button({ id = "v3_healer_display_mode", parent = settingsSwitcher, text = "战斗显示", compact = true,
        slot = { size = "fixed", width = 86 } })
    RSUI:Text({ id = "v3_healer_settings_mode_hint", parent = settingsSwitcher,
        text = "数值设置统一使用：名称 + 滑块 + 精确输入框。", fontSize = 8, tone = "muted", overflow = "ellipsis",
        slot = { size = "fill", fill = 1 } })

    local settingsPanel = RSUI:GroupBox({ id = "v3_healer_settings_panel", parent = root, title = "核心治疗策略",
        variant = "card", gradient = true, padding = 5,
        slot = { size = "auto", minHeight = 120, hAlign = "fill" } })
    local settingsStack = RSUI:VerticalBox({ id = "v3_healer_settings_stack", parent = settingsPanel, gap = 4 })
    local settingGrid = RSUI:UniformGrid({ id = "v3_healer_setting_grid", parent = settingsStack,
        minCellWidth = 250, minCellHeight = 32, maxColumns = 2, gap = 5,
        slot = { size = "auto", minHeight = 128, hAlign = "fill" } })
    local settingRowA, settingRowB = settingGrid, settingGrid

    local settingFields = {}
    local function AddNumeric(parentBox, id, label, hint, key, minimum, maximum, step, unit)
        local field = D:CompactNumericSetting(parentBox, {
            id = id, label = label, hint = hint, min = minimum, max = maximum, step = step,
            integer = true, unit = unit or "", slider = true, stepButtons = false,
            labelWidth = 72, inputWidth = 66,
            get = function() return Settings()[key] end,
            set = function(v) return Feature.Commands:ApplySettingFromBinding(key, v) end,
            storeId = STORE_ID, persistDelayMs = 350, persistReason = "healer_" .. key,
            slot = { size = "fill", fill = 1, hAlign = "fill" },
        })
        if field ~= nil then settingFields[#settingFields + 1] = field end
        return field
    end

    AddNumeric(settingRowA, "v3_healer_max_distance", "治疗距离", "超过该距离不进入推荐。", "maxDistance", 1, 100, 1, "m")
    AddNumeric(settingRowA, "v3_healer_emergency", "紧急血线", "低于该血量进入紧急优先。", "emergencyThreshold", 1, 100, 1, "%")
    AddNumeric(settingRowA, "v3_healer_low_health", "低血线", "低血状态与显示优先阈值。", "lowHealthThreshold", 1, 100, 1, "%")
    AddNumeric(settingRowA, "v3_healer_self_threshold", "自身血线", "自身候选的血量阈值。", "selfThreshold", 1, 100, 1, "%")
    AddNumeric(settingRowB, "v3_healer_enter_threshold", "进入阈值", "进入候选的评分门槛。", "enterThreshold", 1, 100, 1, "")
    AddNumeric(settingRowB, "v3_healer_exit_threshold", "退出阈值", "低于该值且滞回结束后退出。", "exitThreshold", 1, 100, 1, "")
    AddNumeric(settingRowB, "v3_healer_health_scan", "生命刷新", "Health 分片周期；越低越实时但成本更高。", "healthScanMs", 100, 1000, 25, "ms")

    local roleToggle = RSUI:Toggle({
        id = "v3_healer_role_scoring", parent = settingRowB,
        onText = "职责评分：开", offText = "职责评分：关",
        get = function() return Settings().roleScoringEnabled == true end,
        set = function(v) return Feature.Commands:ApplySettingFromBinding("roleScoringEnabled", v == true) end,
        storeId = STORE_ID, persistDelayMs = 350, persistReason = "healer_role_scoring",
        slot = { size = "fill", fill = 0.8, hAlign = "fill" },
    })

    local visualPanel = RSUI:GroupBox({ id = "v3_healer_visual_panel", parent = root, title = "战斗显示层",
        variant = "card", gradient = true, padding = 5, visible = false,
        slot = { size = "auto", minHeight = 154, hAlign = "fill" } })
    local visualStack = RSUI:VerticalBox({ id = "v3_healer_visual_stack", parent = visualPanel, gap = 4 })
    local visualGrid = RSUI:UniformGrid({ id = "v3_healer_visual_grid", parent = visualStack,
        minCellWidth = 205, minCellHeight = 31, maxColumns = 3, gap = 5,
        slot = { size = "auto", minHeight = 155, hAlign = "fill" } })
    local visualRowA, visualRowB, visualRowC = visualGrid, visualGrid, visualGrid
    local presentationFields = {}
    local function AddPresentationNumeric(parentBox, id, label, hint, scope, key, minimum, maximum, step, unit)
        local field = D:CompactNumericSetting(parentBox, {
            id = id, label = label, hint = hint, min = minimum, max = maximum, step = step,
            integer = step >= 1, unit = unit or "", slider = true, stepButtons = false,
            labelWidth = 66, inputWidth = 58,
            get = function()
                local value = Feature:GetPresentationProjection(scope)
                return type(value) == "table" and value[key] or minimum
            end,
            set = function(v) return Feature.Commands:ApplyPresentationSettingFromBinding(scope, key, v) end,
            storeId = STORE_ID, persistDelayMs = 350, persistReason = "healer_" .. scope .. "_" .. key,
            slot = { size = "fill", fill = 1, hAlign = "fill" },
        })
        if field ~= nil then presentationFields[#presentationFields + 1] = field end
        return field
    end
    local function AddPresentationToggle(parentBox, id, onText, offText, scope, key, fill)
        local field = RSUI:Toggle({
            id = id, parent = parentBox, onText = onText, offText = offText,
            get = function()
                local value = Feature:GetPresentationProjection(scope)
                return type(value) == "table" and value[key] == true
            end,
            set = function(v) return Feature.Commands:ApplyPresentationSettingFromBinding(scope, key, v == true) end,
            storeId = STORE_ID, persistDelayMs = 350, persistReason = "healer_" .. scope .. "_" .. key,
            slot = { size = "fill", fill = fill or 0.85, hAlign = "fill" },
        })
        if field ~= nil then presentationFields[#presentationFields + 1] = field end
        return field
    end

    AddPresentationToggle(visualRowA, "v3_healer_head_enabled", "头顶标记：开", "头顶标记：关", "head", "enabled", 0.9)
    AddPresentationNumeric(visualRowA, "v3_healer_head_count", "标记人数", "只影响显示数量，不影响后台推荐。", "head", "count", 1, 50, 1, "人")
    AddPresentationNumeric(visualRowA, "v3_healer_head_shape", "标记形状", "1=整块 2=方块 3=十字 4=箭头。", "head", "shapeMode", 1, 4, 1, "")
    AddPresentationToggle(visualRowA, "v3_healer_head_name", "显示名字：开", "显示名字：关", "head", "showName", 0.8)
    AddPresentationToggle(visualRowA, "v3_healer_head_distance", "显示距离：开", "显示距离：关", "head", "showDistance", 0.8)
    AddPresentationToggle(visualRowA, "v3_healer_head_score", "显示评分：开", "显示评分：关", "head", "showScore", 0.8)

    AddPresentationToggle(visualRowB, "v3_healer_raid_enabled", "团队覆盖：开", "团队覆盖：关", "raid", "enabled", 0.9)
    AddPresentationToggle(visualRowB, "v3_healer_raid_ranks", "名次：开", "名次：关", "raid", "showRanks", 0.75)
    AddPresentationNumeric(visualRowB, "v3_healer_raid_rank_count", "名次数量", "只显示前 N 名推荐编号。", "raid", "rankCount", 0, 50, 1, "")
    AddPresentationNumeric(visualRowB, "v3_healer_raid_rank_font", "名次字号", "团队槽位上的推荐名次字号。", "raid", "rankFontSize", 8, 20, 1, "")
    AddPresentationToggle(visualRowB, "v3_healer_raid_calibration", "校准：开", "校准：关", "raid", "calibration", 0.75)
    local resetRaidButton = RSUI:Button({ id = "v3_healer_raid_reset", parent = visualRowB, text = "重置覆盖位置", compact = true,
        slot = { size = "fill", fill = 0.85, hAlign = "fill" } })
    AddPresentationNumeric(visualRowC, "v3_healer_head_effect", "头顶效果", "1=静态 2=呼吸 3=闪烁。", "head", "effectMode", 1, 3, 1, "")
    AddPresentationNumeric(visualRowC, "v3_healer_raid_effect", "覆盖效果", "1=静态无动画任务，2=呼吸，3=闪烁。", "raid", "effectMode", 1, 3, 1, "")
    AddPresentationToggle(visualRowC, "v3_healer_raid_proximity", "范围底色：开", "范围底色：关", "raid", "proximityMode", 0.9)

    -- Team roster / calibration model (Refactor: RaidTeam != RaidPanel != Calibration).
    -- Panel A/B are independent screen containers; their bound team can change at
    -- runtime without moving geometry. Modes: auto (derive from TeamRosterV3),
    -- single (one list, team follows native/manual), dual (A + B side by side).
    local raidTeamPanel = RSUI:GroupBox({ id = "v3_healer_raid_team_panel", parent = visualStack, title = "团队名单与校准模式",
        variant = "card", gradient = true, padding = 5,
        slot = { size = "auto", minHeight = 120, hAlign = "fill" } })
    local raidTeamStack = RSUI:VerticalBox({ id = "v3_healer_raid_team_stack", parent = raidTeamPanel, gap = 4 })
    local raidTeamGrid = RSUI:UniformGrid({ id = "v3_healer_raid_team_grid", parent = raidTeamStack,
        minCellWidth = 205, minCellHeight = 31, maxColumns = 3, gap = 5,
        slot = { size = "auto", minHeight = 96, hAlign = "fill" } })
    local raidTeamRowA, raidTeamRowB, raidTeamRowC = raidTeamGrid, raidTeamGrid, raidTeamGrid
    local function RaidSetting() return Feature:GetPresentationProjection("raid") or {} end
    local raidTeamFields = {}
    local function AddRaidDropdown(parentBox, id, label, items, getter, setter)
        local field = RSUI:DropdownField({ id = id, parent = parentBox, label = label, items = items,
            get = getter, set = setter, storeId = STORE_ID, persistDelayMs = 350, persistReason = "healer_" .. id,
            slot = { size = "fill", fill = 1, hAlign = "fill" } })
        if field ~= nil then raidTeamFields[#raidTeamFields + 1] = field end
        return field
    end
    local modeField = AddRaidDropdown(raidTeamRowA, "v3_healer_raid_mode", "列表模式",
        { { value = "auto", text = "自动" }, { value = "single", text = "单列表" }, { value = "dual", text = "双列表" } },
        function() return RaidSetting().mode or "auto" end,
        function(v) return Feature.Commands:SetRaidMode(v) end)
    local singleTeamField = AddRaidDropdown(raidTeamRowA, "v3_healer_raid_single_team", "单列表队伍",
        { { value = 0, text = "跟随原生" }, { value = 1, text = "队伍1" }, { value = 2, text = "队伍2" } },
        function() return RaidSetting().singleTeamId or 0 end,
        function(v) return Feature.Commands:SetRaidSingleTeam(tonumber(v) or 0) end)
    local panelATeamField = AddRaidDropdown(raidTeamRowB, "v3_healer_raid_panel_a_team", "面板A队伍",
        { { value = 1, text = "队伍1" }, { value = 2, text = "队伍2" } },
        function() local p = (RaidSetting().panels or {}).A or {}; return p.team or 1 end,
        function(v) return Feature.Commands:SetRaidPanelTeam("A", tonumber(v) or 1) end)
    local panelBTeamField = AddRaidDropdown(raidTeamRowB, "v3_healer_raid_panel_b_team", "面板B队伍",
        { { value = 1, text = "队伍1" }, { value = 2, text = "队伍2" } },
        function() local p = (RaidSetting().panels or {}).B or {}; return p.team or 2 end,
        function(v) return Feature.Commands:SetRaidPanelTeam("B", tonumber(v) or 2) end)
    local testColorToggle = RSUI:Toggle({ id = "v3_healer_raid_test_colors", parent = raidTeamRowC,
        onText = "测试色：开", offText = "测试色：关",
        get = function() return RaidSetting().testColors == true end,
        set = function(v) return Feature.Commands:SetRaidTestSetting("testColors", v == true) end,
        storeId = STORE_ID, persistDelayMs = 350, persistReason = "healer_raid_test_colors",
        slot = { size = "fill", fill = 0.85, hAlign = "fill" } })
    local slotNumberToggle = RSUI:Toggle({ id = "v3_healer_raid_slot_numbers", parent = raidTeamRowC,
        onText = "槽位编号：开", offText = "槽位编号：关",
        get = function() return RaidSetting().slotNumbers ~= false end,
        set = function(v) return Feature.Commands:SetRaidTestSetting("slotNumbers", v == true) end,
        storeId = STORE_ID, persistDelayMs = 350, persistReason = "healer_raid_slot_numbers",
        slot = { size = "fill", fill = 0.85, hAlign = "fill" } })
    local locateSelfButton = RSUI:Button({ id = "v3_healer_raid_locate_self", parent = raidTeamRowC, text = "定位自己", compact = true,
        slot = { size = "fill", fill = 0.85, hAlign = "fill" } })
    local function ApplyRaidTeamVisibility()
        local mode = RaidSetting().mode or "auto"
        local single = mode == "single"
        local dual = mode == "dual"
        if type(singleTeamField) == "table" and type(singleTeamField.SetVisibility) == "function" then singleTeamField:SetVisibility(single and "visible" or "collapsed") end
        if type(panelATeamField) == "table" and type(panelATeamField.SetVisibility) == "function" then panelATeamField:SetVisibility(dual and "visible" or "collapsed") end
        if type(panelBTeamField) == "table" and type(panelBTeamField.SetVisibility) == "function" then panelBTeamField:SetVisibility(dual and "visible" or "collapsed") end
    end

    local function SetSettingsMode(mode)
        settingsMode = mode == "display" and "display" or "strategy"
        settingsPanel:SetVisibility(settingsMode == "strategy" and "visible" or "collapsed")
        visualPanel:SetVisibility(settingsMode == "display" and "visible" or "collapsed")
        if type(strategyButton.SetSelected) == "function" then strategyButton:SetSelected(settingsMode == "strategy") end
        if type(displayButton.SetSelected) == "function" then displayButton:SetSelected(settingsMode == "display") end
        return true
    end
    strategyButton.spec.onClick = function() return SetSettingsMode("strategy") end
    displayButton.spec.onClick = function() return SetSettingsMode("display") end
    if strategyButton.root ~= nil then S.UI:SafeHandler(strategyButton.root, "OnClick", function() return strategyButton.spec.onClick() end, "v3_healer:strategy_mode") end
    if displayButton.root ~= nil then S.UI:SafeHandler(displayButton.root, "OnClick", function() return displayButton.spec.onClick() end, "v3_healer:display_mode") end
    SetSettingsMode("strategy")

    local advancedButton = RSUI:Button({ id = "v3_healer_advanced_toggle", parent = actions, text = "高级编辑", compact = true,
        slot = { size = "fixed", width = 88 } })

    local advancedPanel = RSUI:GroupBox({ id = "v3_healer_advanced_panel", parent = root, title = "高级治疗策略编辑器",
        variant = "card", gradient = true, padding = 5,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" } })
    local advancedStack = RSUI:VerticalBox({ id = "v3_healer_advanced_stack", parent = advancedPanel, gap = 4,
        slot = { hAlign = "fill", vAlign = "fill" } })
    local advancedHeader = RSUI:HorizontalBox({ id = "v3_healer_advanced_header", parent = advancedStack, gap = 6,
        slot = { size = "fixed", height = 28, hAlign = "fill" } })
    local advancedCloseButton = RSUI:Button({ id = "v3_healer_advanced_close", parent = advancedHeader, text = "返回概览", compact = true,
        slot = { size = "fixed", width = 82 } })
    RSUI:Text({ id = "v3_healer_advanced_hint", parent = advancedStack,
        text = "所有修改都经过 v3.healer Normalize 并写入同一 Store；规则顺序决定相同优先级下的稳定结果。",
        fontSize = 8, tone = "muted", overflow = "ellipsis", slot = { size = "fixed", height = 18, hAlign = "fill" } })
    local advancedModeRow = RSUI:HorizontalBox({ id = "v3_healer_advanced_modes", parent = advancedStack, gap = 5,
        slot = { size = "fixed", height = 28, hAlign = "fill" } })
    local ruleModeButton = RSUI:Button({ id = "v3_healer_advanced_rules_mode", parent = advancedModeRow, text = "治疗规则", compact = true,
        slot = { size = "fixed", width = 92 } })
    local trackedModeButton = RSUI:Button({ id = "v3_healer_advanced_tracked_mode", parent = advancedModeRow, text = "Tracked Buff", compact = true,
        slot = { size = "fixed", width = 102 } })
    local colorModeButton = RSUI:Button({ id = "v3_healer_advanced_colors_mode", parent = advancedModeRow, text = "颜色策略", compact = true,
        slot = { size = "fixed", width = 92 } })
    local advancedModeHint = RSUI:Text({ id = "v3_healer_advanced_mode_hint", parent = advancedModeRow,
        text = "最多 20 条规则", fontSize = 8, tone = "muted", overflow = "ellipsis", slot = { size = "fill", fill = 1 } })

    local advancedMode, advancedOpen = "rules", false
    local ruleIndex, trackedIndex = 1, 1
    local ruleEditorFields, trackedEditorFields, colorEditorFields = {}, {}, {}
    local rulePanel = RSUI:VerticalBox({ id = "v3_healer_rule_editor_panel", parent = advancedStack, gap = 4,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" } })
    local ruleActions = RSUI:HorizontalBox({ id = "v3_healer_rule_actions", parent = rulePanel, gap = 5,
        slot = { size = "fixed", height = 28, hAlign = "fill" } })
    local ruleAddButton = RSUI:Button({ id = "v3_healer_rule_add", parent = ruleActions, text = "新增规则", compact = true,
        slot = { size = "fixed", width = 76 } })
    local ruleRemoveButton = RSUI:Button({ id = "v3_healer_rule_remove", parent = ruleActions, text = "删除选中", compact = true,
        slot = { size = "fixed", width = 76 } })
    local ruleStatus = RSUI:Text({ id = "v3_healer_rule_status", parent = ruleActions, text = "请选择规则", fontSize = 8, tone = "muted",
        overflow = "ellipsis", slot = { size = "fill", fill = 1 } })
    local ruleTable = RSUI:TableView({
        id = "v3_healer_rule_table", parent = rulePanel, items = {}, rowHeight = 22, headerHeight = 22, desiredRows = 4,
        scrollbar = true, selectable = true, selectionMode = "single", columnResize = true, headerInteractive = false,
        getKey = function(item) return item and item.key or nil end,
        onSelectionChanged = function(_, _, view)
            local key = view and type(view.GetSelectedKey) == "function" and view:GetSelectedKey() or nil
            ruleIndex = tonumber(tostring(key or ""):match("(%d+)$")) or 1
            if type(root.RefreshAdvanced) == "function" then root:RefreshAdvanced() end
        end,
        columns = {
            { id = "index", title = "#", field = "indexText", size = "fixed", width = 30, minWidth = 28 },
            { id = "name", title = "名称", field = "name", size = "fill", fill = 1.4, minWidth = 120 },
            { id = "ids", title = "状态 ID", field = "ids", size = "fill", fill = 1.4, minWidth = 120 },
            { id = "effect", title = "效果", field = "effect", size = "fixed", width = 74, minWidth = 64 },
            { id = "priority", title = "优先级", field = "priority", size = "fixed", width = 58, minWidth = 50 },
            { id = "enabled", title = "启用", field = "enabled", size = "fixed", width = 48, minWidth = 42 },
        },
        slot = { size = "fixed", height = 112, hAlign = "fill" },
    })
    local ruleEditor = RSUI:VerticalBox({ id = "v3_healer_rule_editor", parent = rulePanel, gap = 3,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" } })
    local trackedPanel = RSUI:VerticalBox({ id = "v3_healer_tracked_editor_panel", parent = advancedStack, gap = 4,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" } })
    local trackedAddRow = RSUI:HorizontalBox({ id = "v3_healer_tracked_add_row", parent = trackedPanel, gap = 5,
        slot = { size = "fixed", height = 29, hAlign = "fill" } })
    RSUI:Text({ id = "v3_healer_tracked_add_label", parent = trackedAddRow, text = "新增 Buff ID", fontSize = 9, tone = "strong",
        slot = { size = "fixed", width = 78 } })
    local trackedAddInput = RSUI:TextInput({ id = "v3_healer_tracked_add_input", parent = trackedAddRow, value = "", maxLength = 12, buildOptional = true,
        allowEmpty = false, slot = { size = "fixed", width = 120 } })
    local trackedAddButton = RSUI:Button({ id = "v3_healer_tracked_add", parent = trackedAddRow, text = "添加", compact = true,
        slot = { size = "fixed", width = 58 } })
    if trackedAddInput == nil then trackedAddButton:SetEnabled(false) end
    local trackedStatus = RSUI:Text({ id = "v3_healer_tracked_status", parent = trackedAddRow, text = "最多 20 条，ID 重复时由 Normalize 去重。", fontSize = 8, tone = "muted",
        overflow = "ellipsis", slot = { size = "fill", fill = 1 } })
    local trackedTable = RSUI:TableView({
        id = "v3_healer_tracked_table", parent = trackedPanel, items = {}, rowHeight = 22, headerHeight = 22, desiredRows = 4,
        scrollbar = true, selectable = true, selectionMode = "single", columnResize = true, headerInteractive = false,
        getKey = function(item) return item and item.key or nil end,
        onSelectionChanged = function(_, _, view)
            local key = view and type(view.GetSelectedKey) == "function" and view:GetSelectedKey() or nil
            trackedIndex = tonumber(tostring(key or ""):match("(%d+)$")) or 1
            if type(root.RefreshAdvanced) == "function" then root:RefreshAdvanced() end
        end,
        columns = {
            { id = "index", title = "#", field = "indexText", size = "fixed", width = 30, minWidth = 28 },
            { id = "id", title = "ID", field = "idText", size = "fixed", width = 76, minWidth = 60 },
            { id = "name", title = "名称", field = "name", size = "fill", fill = 1.4, minWidth = 120 },
            { id = "enabled", title = "启用", field = "enabled", size = "fixed", width = 48, minWidth = 42 },
        },
        slot = { size = "fixed", height = 112, hAlign = "fill" },
    })
    local trackedEditor = RSUI:VerticalBox({ id = "v3_healer_tracked_editor", parent = trackedPanel, gap = 3,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" } })
    local colorPanel = RSUI:VerticalBox({ id = "v3_healer_color_editor_panel", parent = advancedStack, gap = 4,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" } })
    RSUI:Text({ id = "v3_healer_color_editor_hint", parent = colorPanel,
        text = "颜色通道范围 0–1；Alpha 最低 0.05。规则和 Tracked Buff 的颜色在各自编辑器中单独维护。",
        fontSize = 8, tone = "muted", overflow = "ellipsis", slot = { size = "fixed", height = 18, hAlign = "fill" } })

    local function AddAdvancedText(parentBox, id, label, getter, setter, maxLength, fields)
        local row = RSUI:HorizontalBox({ id = id .. "_row", parent = parentBox, gap = 4, slot = { size = "auto", minHeight = 27, hAlign = "fill" } })
        RSUI:Text({ id = id .. "_label", parent = row, text = label, fontSize = 8, tone = "muted", overflow = "ellipsis", slot = { size = "fixed", width = 72 } })
        local input = RSUI:TextInput({ id = id, parent = row, maxLength = maxLength or 160, allowEmpty = true, buildOptional = true, get = getter, set = function(v) return setter(v) end,
            slot = { size = "fill", fill = 1, hAlign = "fill" } })
        if input == nil then
            RSUI:Text({ id = id .. "_unavailable", parent = row, text = "文本输入不可用", fontSize = 8, tone = "warn", overflow = "ellipsis",
                slot = { size = "fill", fill = 1, hAlign = "fill" } })
            return nil
        end
        fields[#fields + 1] = input
        return input
    end
    local function AddAdvancedNumeric(parentBox, id, label, getter, setter, minimum, maximum, step, fields, unit)
        local field = D:CompactNumericSetting(parentBox, { id = id, label = label, min = minimum, max = maximum, step = step,
            integer = step >= 1, unit = unit or "", slider = true, stepButtons = false, get = getter, set = function(v) return setter(v) end,
            labelWidth = 64, inputWidth = 58,
            slot = { size = "fill", fill = 1, hAlign = "fill" } })
        if field == nil then return nil end
        fields[#fields + 1] = field
        return field
    end
    local function AddAdvancedToggle(parentBox, id, onText, offText, getter, setter, fields)
        local field = RSUI:Toggle({ id = id, parent = parentBox, onText = onText, offText = offText, get = getter, set = function(v) return setter(v == true) end,
            slot = { size = "fill", fill = 1, hAlign = "fill" } })
        if field == nil then return nil end
        fields[#fields + 1] = field
        return field
    end
    local function AddAdvancedDropdown(parentBox, id, label, getter, setter, items, fields)
        local field = RSUI:DropdownField({ id = id, parent = parentBox, label = label, items = items, get = getter, set = function(v) return setter(v) end,
            slot = { size = "fill", fill = 1, hAlign = "fill" } })
        if field == nil then return nil end
        fields[#fields + 1] = field
        return field
    end
    local function RuleValue(key, fallback)
        local rule = Feature:GetRules()[ruleIndex]
        return type(rule) == "table" and (rule[key] ~= nil and rule[key] or fallback) or fallback
    end
    local function SetRuleValue(key, value)
        local ok, err = Feature.Commands:SetRule(ruleIndex, key, value)
        if ok == true and type(root.RefreshAdvanced) == "function" then root:RefreshAdvanced() end
        return ok, err
    end
    local ruleRows = {}
    for index = 1, 5 do ruleRows[index] = RSUI:HorizontalBox({ id = "v3_healer_rule_fields_" .. tostring(index), parent = ruleEditor, gap = 4,
        slot = { size = "auto", minHeight = 30, hAlign = "fill" } }) end
    AddAdvancedText(ruleRows[1], "v3_healer_rule_name", "名称", function() return RuleValue("name", "未命名规则") end, function(v) return SetRuleValue("name", v) end, 64, ruleEditorFields)
    AddAdvancedToggle(ruleRows[1], "v3_healer_rule_enabled", "规则：开", "规则：关", function() return RuleValue("enabled", true) == true end, function(v) return SetRuleValue("enabled", v) end, ruleEditorFields)
    AddAdvancedDropdown(ruleRows[1], "v3_healer_rule_purpose", "用途", function() return RuleValue("purpose", 5) end, function(v) return SetRuleValue("purpose", v) end,
        { { value = 1, text = "保护" }, { value = 2, text = "紧急" }, { value = 3, text = "增益" }, { value = 4, text = "排除" }, { value = 5, text = "通用" } }, ruleEditorFields)
    AddAdvancedDropdown(ruleRows[1], "v3_healer_rule_source", "来源", function() return RuleValue("sourceMode", 5) end, function(v) return SetRuleValue("sourceMode", v) end,
        { { value = 1, text = "Buff" }, { value = 2, text = "Debuff" }, { value = 3, text = "隐藏" }, { value = 4, text = "任一" }, { value = 5, text = "全部" } }, ruleEditorFields)
    AddAdvancedText(ruleRows[2], "v3_healer_rule_ids", "状态 ID", function() return table.concat(RuleValue("ids", {}), ",") end, function(v) return SetRuleValue("ids", v) end, 180, ruleEditorFields)
    AddAdvancedDropdown(ruleRows[2], "v3_healer_rule_match", "匹配", function() return RuleValue("matchMode", 1) end, function(v) return SetRuleValue("matchMode", v) end,
        { { value = 1, text = "任一 ID" }, { value = 2, text = "全部 ID" } }, ruleEditorFields)
    AddAdvancedNumeric(ruleRows[2], "v3_healer_rule_min_stacks", "最少层数", function() return RuleValue("minStacks", 1) end, function(v) return SetRuleValue("minStacks", v) end, 1, 99, 1, ruleEditorFields)
    AddAdvancedNumeric(ruleRows[2], "v3_healer_rule_remaining", "最少剩余", function() return RuleValue("minRemainingMs", 0) end, function(v) return SetRuleValue("minRemainingMs", v) end, 0, 3600000, 100, ruleEditorFields, "ms")
    AddAdvancedToggle(ruleRows[2], "v3_healer_rule_unknown_time", "未知时长：有效", "未知时长：无效", function() return RuleValue("unknownRemainingValid", true) == true end, function(v) return SetRuleValue("unknownRemainingValid", v) end, ruleEditorFields)
    AddAdvancedToggle(ruleRows[3], "v3_healer_rule_health_range", "血线范围：开", "血线范围：关", function() return RuleValue("healthRangeEnabled", false) == true end, function(v) return SetRuleValue("healthRangeEnabled", v) end, ruleEditorFields)
    AddAdvancedNumeric(ruleRows[3], "v3_healer_rule_health_min", "血线下限", function() return RuleValue("healthMin", 0) end, function(v) return SetRuleValue("healthMin", v) end, 0, 100, 1, ruleEditorFields, "%")
    AddAdvancedNumeric(ruleRows[3], "v3_healer_rule_health_max", "血线上限", function() return RuleValue("healthMax", 100) end, function(v) return SetRuleValue("healthMax", v) end, 0, 100, 1, ruleEditorFields, "%")
    AddAdvancedDropdown(ruleRows[3], "v3_healer_rule_effect", "效果", function() return RuleValue("effectType", 2) end, function(v) return SetRuleValue("effectType", v) end,
        { { value = 1, text = "减分" }, { value = 2, text = "加分" }, { value = 3, text = "排除" }, { value = 4, text = "救援" } }, ruleEditorFields)
    AddAdvancedDropdown(ruleRows[3], "v3_healer_rule_score_mode", "计分", function() return RuleValue("scoreMode", 1) end, function(v) return SetRuleValue("scoreMode", v) end,
        { { value = 1, text = "固定" }, { value = 2, text = "按层数" } }, ruleEditorFields)
    AddAdvancedNumeric(ruleRows[4], "v3_healer_rule_score", "分值", function() return RuleValue("scoreValue", 0) end, function(v) return SetRuleValue("scoreValue", v) end, 0, 500, 1, ruleEditorFields)
    AddAdvancedToggle(ruleRows[4], "v3_healer_rule_stack", "允许叠层", "不叠加", function() return RuleValue("allowStack", false) == true end, function(v) return SetRuleValue("allowStack", v) end, ruleEditorFields)
    AddAdvancedNumeric(ruleRows[4], "v3_healer_rule_emergency_retain", "紧急保留", function() return RuleValue("emergencyRetainPercent", 20) end, function(v) return SetRuleValue("emergencyRetainPercent", v) end, 0, 100, 1, ruleEditorFields, "%")
    AddAdvancedToggle(ruleRows[4], "v3_healer_rule_protection", "计入保护", "不计保护", function() return RuleValue("countsAsProtection", false) == true end, function(v) return SetRuleValue("countsAsProtection", v) end, ruleEditorFields)
    AddAdvancedNumeric(ruleRows[4], "v3_healer_rule_display_priority", "显示优先", function() return RuleValue("displayPriority", 50) end, function(v) return SetRuleValue("displayPriority", v) end, 0, 999, 1, ruleEditorFields)
    AddAdvancedNumeric(ruleRows[5], "v3_healer_rule_rescue_priority", "救援优先", function() return RuleValue("rescuePriority", 50) end, function(v) return SetRuleValue("rescuePriority", v) end, 0, 999, 1, ruleEditorFields)
    AddAdvancedDropdown(ruleRows[5], "v3_healer_rule_distance_mode", "距离", function() return RuleValue("distanceMode", 1) end, function(v) return SetRuleValue("distanceMode", v) end,
        { { value = 1, text = "全局距离" }, { value = 2, text = "自定义" } }, ruleEditorFields)
    AddAdvancedNumeric(ruleRows[5], "v3_healer_rule_distance", "自定义距离", function() return RuleValue("customDistance", 20) end, function(v) return SetRuleValue("customDistance", v) end, 1, 100, 1, ruleEditorFields, "m")
    AddAdvancedNumeric(ruleRows[5], "v3_healer_rule_heal_threshold", "治疗优先", function() return RuleValue("healPriorityThreshold", 70) end, function(v) return SetRuleValue("healPriorityThreshold", v) end, 0, 100, 1, ruleEditorFields, "%")
    AddAdvancedDropdown(ruleRows[5], "v3_healer_rule_exclude", "排除显示", function() return RuleValue("excludeDisplayMode", 1) end, function(v) return SetRuleValue("excludeDisplayMode", v) end,
        { { value = 1, text = "隐藏" }, { value = 2, text = "保留" } }, ruleEditorFields)
    AddAdvancedToggle(ruleRows[5], "v3_healer_rule_simple_group", "参与显示组", "不参与显示组", function() return RuleValue("simpleDisplayGroup", false) == true end, function(v) return SetRuleValue("simpleDisplayGroup", v) end, ruleEditorFields)
    local ruleColorRow = RSUI:HorizontalBox({ id = "v3_healer_rule_color_row", parent = ruleEditor, gap = 4, slot = { size = "auto", minHeight = 30, hAlign = "fill" } })
    local function RuleColorValue(channel) local color = RuleValue("color", {}) return type(color) == "table" and color[channel] or 1 end
    local function SetRuleColor(channel, value)
        local color = RuleValue("color", {})
        color[channel] = value
        return SetRuleValue("color", color)
    end
    for _, channel in ipairs({ "r", "g", "b", "a" }) do
        local channelRef = channel
        AddAdvancedNumeric(ruleColorRow, "v3_healer_rule_color_" .. channelRef, "颜色 " .. channelRef:upper(), function() return RuleColorValue(channelRef) end,
            function(v) return SetRuleColor(channelRef, v) end, 0, 1, 0.01, ruleEditorFields)
    end

    local trackedRows = {}
    for index = 1, 2 do trackedRows[index] = RSUI:HorizontalBox({ id = "v3_healer_tracked_fields_" .. tostring(index), parent = trackedEditor, gap = 4,
        slot = { size = "auto", minHeight = 30, hAlign = "fill" } }) end
    local function TrackedValue(key, fallback)
        local row = Feature:GetTrackedBuffs()[trackedIndex]
        return type(row) == "table" and (row[key] ~= nil and row[key] or fallback) or fallback
    end
    local function SetTrackedValue(key, value)
        local ok, err = Feature.Commands:SetTrackedBuff(trackedIndex, key, value)
        if ok == true and type(root.RefreshAdvanced) == "function" then root:RefreshAdvanced() end
        return ok, err
    end
    AddAdvancedText(trackedRows[1], "v3_healer_tracked_name", "名称", function() return TrackedValue("name", "Tracked Buff") end, function(v) return SetTrackedValue("name", v) end, 64, trackedEditorFields)
    AddAdvancedText(trackedRows[1], "v3_healer_tracked_icon", "图标路径", function() return TrackedValue("iconPath", "") end, function(v) return SetTrackedValue("iconPath", v) end, 180, trackedEditorFields)
    AddAdvancedToggle(trackedRows[1], "v3_healer_tracked_enabled", "追踪：开", "追踪：关", function() return TrackedValue("enabled", true) == true end, function(v) return SetTrackedValue("enabled", v) end, trackedEditorFields)
    local trackedRemoveButton = RSUI:Button({ id = "v3_healer_tracked_remove", parent = trackedRows[1], text = "删除选中", compact = true, slot = { size = "fixed", width = 74 } })
    local function TrackedColorValue(channel) local color = TrackedValue("color", {}) return type(color) == "table" and color[channel] or 1 end
    local function SetTrackedColor(channel, value)
        local color = TrackedValue("color", {})
        color[channel] = value
        return SetTrackedValue("color", color)
    end
    for _, channel in ipairs({ "r", "g", "b", "a" }) do
        local channelRef = channel
        AddAdvancedNumeric(trackedRows[2], "v3_healer_tracked_color_" .. channelRef, "颜色 " .. channelRef:upper(), function() return TrackedColorValue(channelRef) end,
            function(v) return SetTrackedColor(channelRef, v) end, 0, 1, 0.01, trackedEditorFields)
    end

    local colorRows = {}
    local colorKeys = { { key = "proximityColor", label = "范围底色" }, { key = "lowHealthColor", label = "低血色" }, { key = "emergencyColor", label = "紧急色" } }
    for index, descriptor in ipairs(colorKeys) do
        local descriptorRef = descriptor
        colorRows[index] = RSUI:HorizontalBox({ id = "v3_healer_color_row_" .. tostring(index), parent = colorPanel, gap = 4, slot = { size = "auto", minHeight = 30, hAlign = "fill" } })
        RSUI:Text({ id = "v3_healer_color_label_" .. tostring(index), parent = colorRows[index], text = descriptorRef.label, fontSize = 9, tone = "strong", slot = { size = "fixed", width = 70 } })
        for _, channel in ipairs({ "r", "g", "b", "a" }) do
            local channelRef = channel
            local function CurrentColor()
                local settings = Settings()
                local color = settings[descriptorRef.key]
                return type(color) == "table" and color[channelRef] or 1
            end
            local function ApplyColor(value)
                local color = Settings()[descriptorRef.key] or {}
                color[channelRef] = value
                local ok, err = Feature.Commands:SetHealerColor(descriptorRef.key, color)
                if ok == true and type(root.RefreshAdvanced) == "function" then root:RefreshAdvanced() end
                return ok, err
            end
            AddAdvancedNumeric(colorRows[index], "v3_healer_color_" .. tostring(index) .. "_" .. channelRef, channelRef:upper(), CurrentColor, ApplyColor, 0, 1, 0.01, colorEditorFields)
        end
    end

    -- Product decision M1.16.0.18.43: treatment assistance is a screen-color
    -- aid, not another ranking UI. Keep the recommendation domain because the
    -- Raid Overlay consumes its committed color/priority facts, but do not
    -- allocate a duplicate member list/detail table in Presentation.
    local body = RSUI:GroupBox({ id = "v3_healer_calibration_panel", parent = root, title = "团队色块校准",
        variant = "card", gradient = true, padding = 8,
        slot = { size = "fill", fill = 1, minHeight = 150, hAlign = "fill", vAlign = "fill" } })
    local bodyStack = RSUI:VerticalBox({ id = "v3_healer_calibration_stack", parent = body, gap = 6 })
    local calibrationState = RSUI:Text({ id = "v3_healer_calibration_state", parent = bodyStack,
        text = "点击上方“校准团队色块”后，屏幕会按当前列表模式显示面板（单列表=面板A，双列表=面板A+B）。校准模式不启动治疗扫描。",
        fontSize = 9, tone = "accent", overflow = "wrap", maxLines = 3,
        slot = { size = "auto", minHeight = 48, hAlign = "fill" } })
    RSUI:Text({ id = "v3_healer_calibration_help", parent = bodyStack,
        text = "拖动四个区域与游戏团队框对齐；颜色、低血/紧急阈值、显示效果在“战斗显示”和“高级编辑”中设置。真正运行时只显示团队颜色模块，不创建推荐名单悬浮窗。",
        fontSize = 9, tone = "muted", overflow = "wrap", maxLines = 4,
        slot = { size = "auto", minHeight = 64, hAlign = "fill" } })

    local function SetAdvancedVisibility(component, visible)
        if component ~= nil and type(component.SetVisibility) == "function" then component:SetVisibility(visible and "visible" or "collapsed") end
    end
    function root:SetAdvancedMode(mode)
        mode = (mode == "tracked" or mode == "colors") and mode or "rules"
        advancedMode, advancedOpen = mode, true
        SetAdvancedVisibility(body, false)
        SetAdvancedVisibility(advancedPanel, true)
        SetAdvancedVisibility(rulePanel, mode == "rules")
        SetAdvancedVisibility(trackedPanel, mode == "tracked")
        SetAdvancedVisibility(colorPanel, mode == "colors")
        ruleModeButton:SetSelected(mode == "rules")
        trackedModeButton:SetSelected(mode == "tracked")
        colorModeButton:SetSelected(mode == "colors")
        advancedModeHint:SetText(mode == "rules" and "规则顺序决定相同优先级下的稳定结果"
            or (mode == "tracked" and "Tracked Buff 只读取已提交 StatusMap / Aura 快照" or "颜色用于范围、低血、紧急及规则/Tracked Buff 状态"))
        return self:RefreshAdvanced()
    end
    function root:RefreshAdvanced()
        local rules = Feature:GetRules()
        local ruleRows = {}
        for index, rule in ipairs(rules) do
            ruleRows[index] = { key = "rule_" .. tostring(index), indexText = tostring(index), name = tostring(rule.name or "未命名规则"),
                ids = table.concat(rule.ids or {}, ","), effect = tostring(rule.effectType or "-"), priority = tostring(rule.displayPriority or 0),
                enabled = rule.enabled == true and "是" or "否" }
        end
        ruleTable:SetItems(ruleRows, "healer_rules:" .. tostring(#ruleRows))
        ruleIndex = math.max(1, math.min(#rules, tonumber(ruleIndex) or 1))
        if #rules > 0 and ruleTable:GetSelectedIndex() ~= ruleIndex then ruleTable:SetSelectedIndex(ruleIndex) end
        ruleRemoveButton:SetEnabled(#rules > 1 and #rules >= ruleIndex)
        ruleStatus:SetText(#rules > 0 and ("编辑第 " .. tostring(ruleIndex) .. " 条规则 / 共 " .. tostring(#rules) .. " 条") or "暂无规则")
        for _, field in ipairs(ruleEditorFields) do if type(field.Render) == "function" then field:Render() end end

        local tracked = Feature:GetTrackedBuffs()
        local trackedRows = {}
        for index, row in ipairs(tracked) do
            trackedRows[index] = { key = "tracked_" .. tostring(index), indexText = tostring(index), idText = tostring(row.id or "-"),
                name = tostring(row.name or "Tracked Buff"), enabled = row.enabled == true and "是" or "否" }
        end
        trackedTable:SetItems(trackedRows, "healer_tracked:" .. tostring(#trackedRows))
        if #tracked > 0 then
            trackedIndex = math.max(1, math.min(#tracked, tonumber(trackedIndex) or 1))
            if trackedTable:GetSelectedIndex() ~= trackedIndex then trackedTable:SetSelectedIndex(trackedIndex) end
        else trackedIndex = 1 end
        trackedRemoveButton:SetEnabled(#tracked >= trackedIndex and #tracked > 0)
        trackedStatus:SetText(#tracked > 0 and ("编辑第 " .. tostring(trackedIndex) .. " 条 / 共 " .. tostring(#tracked) .. " 条") or "暂无 Tracked Buff")
        for _, field in ipairs(trackedEditorFields) do if type(field.Render) == "function" then field:Render() end end
        for _, field in ipairs(colorEditorFields) do if type(field.Render) == "function" then field:Render() end end
        return true
    end
    function root:ShowAdvanced(show)
        if show == true then return self:SetAdvancedMode(advancedMode) end
        advancedOpen = false
        SetAdvancedVisibility(advancedPanel, false)
        SetAdvancedVisibility(body, true)
        advancedButton:SetText("高级编辑")
        return true
    end
    SetAdvancedVisibility(advancedPanel, false)
    SetAdvancedVisibility(body, true)

    function root:Refresh(settingsChanged)
        local enabled = S.FeatureRuntime ~= nil and S.FeatureRuntime:IsEnabled(FEATURE_ID) == true
        local projection = Feature:GetProjection(50)
        local health = Feature:GetHealth()
        local runtime = type(health) == "table" and health.runtime or {}
        local roster = type(health) == "table" and health.roster or {}
        local aura = type(health) == "table" and health.aura or {}
        local recommendation = type(health) == "table" and health.recommendation or {}

        runtimeCard:SetData({
            value = enabled and (runtime.running == true and "运行中" or "初始化中") or "已关闭",
            detail = "团队 " .. tostring(N(roster.members or roster.count)) .. " 人 · 数据轮次 " .. tostring(N(runtime.healthGeneration))
                .. "/" .. tostring(N(runtime.statusGeneration)),
        })
        runtimeCard.valueText:SetTone(enabled and (runtime.running == true and "green" or "warn") or "muted")
        recommendationCard:SetData({
            value = tostring(projection.recommendationCount or 0) .. " 人",
            detail = "后台颜色候选 · 暂不可评分 " .. tostring(projection.unavailableCount or 0)
                .. " · 更新 " .. tostring(projection.revision or 0),
        })
        local fallbackCount = N(aura.nativeFallbacks)
        observationCard:SetData({
            value = fallbackCount > 0 and "共享 + 精确补读" or "共享状态",
            detail = "共享命中 " .. tostring(N(aura.accepted)) .. " · 精确补读 " .. tostring(fallbackCount)
                .. " · 已观察 " .. tostring(N(recommendation.statusMembers)) .. " 人",
        })
        observationCard.valueText:SetTone(N(aura.nativeFallbackFailures) > 0 and "warn" or "green")
        featureButton:SetText(enabled and "关闭功能" or "启用功能")
        rosterButton:SetEnabled(enabled)
        if settingsChanged == true then
            for _, field in ipairs(settingFields) do if type(field.Render) == "function" then field:Render() end end
            roleToggle:Render()
            for _, field in ipairs(presentationFields) do if type(field.Render) == "function" then field:Render() end end
            for _, field in ipairs(raidTeamFields) do if type(field) == "table" and type(field.Render) == "function" then field:Render() end end
            ApplyRaidTeamVisibility()
        end
        local raidProjection = Feature:GetPresentationProjection("raid")
        local calibrating = type(raidProjection) == "table" and raidProjection.calibration == true
        calibrationButton:SetText(calibrating and "结束团队校准" or "校准团队色块")
        calibrationButton:SetEnabled(true)
        calibrationState:SetText(calibrating
            and "校准正在显示：拖动屏幕上的团队区域与游戏团队框对齐；此模式不获取治疗 Consumer。"
            or (enabled and "治疗辅助运行中：团队色块按已提交的生命/状态/规则结果更新。" or "治疗辅助已关闭：仍可单独打开校准色块，不启动后台治疗扫描。"))
        calibrationState:SetTone(calibrating and "accent" or (enabled and "green" or "muted"))
        advancedButton:SetText(advancedOpen and "返回概览" or "高级编辑")

        if advancedOpen == true then self:RefreshAdvanced() end
        return true
    end

    advancedButton.onClick = function()
        if advancedOpen == true then return root:ShowAdvanced(false) end
        return root:ShowAdvanced(true)
    end
    advancedCloseButton.onClick = function() return root:ShowAdvanced(false) end
    ruleModeButton.onClick = function() return root:SetAdvancedMode("rules") end
    trackedModeButton.onClick = function() return root:SetAdvancedMode("tracked") end
    colorModeButton.onClick = function() return root:SetAdvancedMode("colors") end
    ruleAddButton.onClick = function()
        local ok, err = Feature.Commands:AddRule()
        if ok == true then ruleIndex = #Feature:GetRules(); root:RefreshAdvanced() end
        return ok, err or "已新增治疗规则"
    end
    ruleRemoveButton.onClick = function()
        local ok, err = Feature.Commands:RemoveRule(ruleIndex)
        if ok == true then ruleIndex = math.max(1, ruleIndex - 1); root:RefreshAdvanced() end
        return ok, err or "已删除治疗规则"
    end
    trackedAddButton.onClick = function()
        if trackedAddInput == nil or type(trackedAddInput.GetDraftValue) ~= "function" then return false, "当前客户端文本输入框不可用" end
        local value = trackedAddInput:GetDraftValue()
        local ok, err = Feature.Commands:AddTrackedBuff(value)
        if ok == true then trackedIndex = #Feature:GetTrackedBuffs(); trackedAddInput:SetValue("", false, "tracked_add_clear"); root:RefreshAdvanced() end
        return ok, err or "已添加 Tracked Buff"
    end
    trackedRemoveButton.onClick = function()
        local ok, err = Feature.Commands:RemoveTrackedBuff(trackedIndex)
        if ok == true then trackedIndex = math.max(1, trackedIndex - 1); root:RefreshAdvanced() end
        return ok, err or "已删除 Tracked Buff"
    end

    featureButton.onClick = function()
        return RunAction("feature_toggle", featureButton, function()
            if S.FeatureRuntime == nil then return false, "FeatureRuntime 不可用" end
            local enabled = S.FeatureRuntime:IsEnabled(FEATURE_ID) == true
            local target = not enabled
            local ok, err = S.FeatureRuntime:SetPreferredEnabled(FEATURE_ID, target, "healer_page")
            if ok ~= true then return false, err end
            if target then
                local acquired, acquireErr = Feature:AcquireConsumer(CONSUMER)
                if acquired ~= true then
                    S.FeatureRuntime:SetPreferredEnabled(FEATURE_ID, false, "healer_page_consumer_rollback")
                    return false, acquireErr
                end
            end
            root:Refresh(false)
            return true, target and "治疗辅助已启用" or "治疗辅助已关闭"
        end)
    end
    calibrationButton.onClick = function()
        return RunAction("raid_calibration", calibrationButton, function()
            local current = Feature:GetPresentationProjection("raid")
            local target = not (type(current) == "table" and current.calibration == true)
            local ok, err = Feature.Commands:ApplyPresentationSettingFromBinding("raid", "calibration", target)
            if ok == true then root:Refresh(true) end
            return ok, err or (target and "团队色块校准已显示；可拖动团队面板区域" or "团队色块校准已结束")
        end)
    end
    rosterButton.onClick = function()
        return RunAction("roster_refresh", rosterButton, function()
            local ok, err = Feature.Commands:RequestRosterRefresh("healer_page_manual")
            return ok, err or "已请求刷新团队名单"
        end)
    end
    resetRaidButton.onClick = function()
        return RunAction("raid_reset", resetRaidButton, function()
            local ok, err = Feature.Commands:ResetRaidLayout()
            if ok == true then root:Refresh(true) end
            return ok, err or "团队覆盖位置已重置"
        end)
    end
    locateSelfButton.onClick = function()
        return RunAction("raid_locate_self", locateSelfButton, function()
            local ok, err = Feature.Commands:LocateSelf()
            return ok, err or "已在覆盖层高亮你所在的槽位"
        end)
    end
    for _, pair in ipairs({
        { featureButton, "feature" }, { calibrationButton, "raid_calibration" }, { rosterButton, "roster" }, { resetRaidButton, "raid_reset" },
        { locateSelfButton, "raid_locate_self" },
        { advancedButton, "advanced" }, { advancedCloseButton, "advanced_close" }, { ruleModeButton, "rules_mode" },
        { trackedModeButton, "tracked_mode" }, { colorModeButton, "colors_mode" }, { ruleAddButton, "rule_add" },
        { ruleRemoveButton, "rule_remove" }, { trackedAddButton, "tracked_add" }, { trackedRemoveButton, "tracked_remove" },
    }) do
        local buttonRef, keyRef = pair[1], pair[2]
        if buttonRef.root ~= nil then
            S.UI:SafeHandler(buttonRef.root, "OnClick", function() return buttonRef.onClick() end, "v3_healer:" .. keyRef)
        end
    end

    function root:Subscribe()
        if S.Events == nil or type(S.Events.SubscribeInternal) ~= "function" or type(S.Events.UnsubscribeInternalOwner) ~= "function" then
            return false, "内部事件总线不可用"
        end
        S.Events:UnsubscribeInternalOwner(self)
        local topics = { "v3.healer.updated", "v3.healer.settings", "v3.healer.presentation", "v3.team_roster.updated" }
        for _, topic in ipairs(topics) do
            local topicRef = topic -- Lua 5.1: bind each generic-for value.
            local ok = S.Events:SubscribeInternal(topicRef, self, function()
                root:Refresh(topicRef == "v3.healer.settings" or topicRef == "v3.healer.presentation")
            end)
            if ok ~= true then
                S.Events:UnsubscribeInternalOwner(self)
                return false, "页面事件订阅失败：" .. tostring(topicRef)
            end
        end
        return true
    end

    function root:OnActivated()
        local loadedNow, errNow = Feature:EnsureStoreLoaded()
        if loadedNow ~= true then return false, errNow end
        local subscribed, subscribeErr = self:Subscribe()
        if subscribed ~= true then return false, subscribeErr end
        local enabled = S.FeatureRuntime ~= nil and S.FeatureRuntime:IsEnabled(FEATURE_ID) == true
        if enabled then
            local acquired, acquireErr = Feature:AcquireConsumer(CONSUMER)
            if acquired ~= true then
                S.Events:UnsubscribeInternalOwner(self)
                return false, acquireErr
            end
        end
        self:Refresh(true)
        return true
    end

    function root:OnDeactivated()
        if S.Events ~= nil and type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
        Feature:ReleaseConsumer(CONSUMER)
        return true
    end

    root.route = route
    root.calibrationPanel = body
    return root
end

local ok, err = PageHost:RegisterFactory(ROUTE, BuildPage)
if ok ~= true then error(err) end

------------------------------------------------------------------------
-- Replicated Suite - Healer Combat Workspace (M5 v3)
--
-- Deep RSUI migration for Replicated Healer.
--
-- Authority / Proxy boundary:
--   * This file never calls X2Unit/X2Team/X2Ability directly.
--   * Live rows come from ReplicatedHealerModule workspace projections, which
--     expose only committed Roster / Health / Recommendation / Status data.
--   * Setting changes cross ReplicatedHealerModule -> SettingsPresenter ->
--     SettingsModel; this workspace never owns a second healer config table.
--   * Role overrides and calibration commands remain Healer Authority actions.
--
-- Performance notes:
--   * recommendation rows rebind only when Recommendation publication changes;
--   * hidden subviews do not rebuild their tables on the workspace timer;
--   * TableView keeps Native row count bounded by viewport + overscan;
--   * selected-member Buff text reads committed cache only (no scan on timer).
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI = S.RSUI
if type(RSUI) ~= "table" then return end

S.CombatHealerWorkspace = S.CombatHealerWorkspace or {}
local WH = S.CombatHealerWorkspace

local function ExportHealer()
    local sandbox = ReplicatedSuiteModuleSandbox
    local value = sandbox ~= nil and sandbox:GetExport("healer", "ReplicatedHealerModule") or nil
    if value == nil then value = rawget(_G, "ReplicatedHealerModule") end
    return value
end

local function SafeChat(text)
    if S.SafeChat ~= nil then S.SafeChat(tostring(text or "")) end
end

local function RoleLabel(h, role)
    if h ~= nil and type(h.GetSuiteRoleLabel) == "function" then return tostring(h:GetSuiteRoleLabel(role) or "--") end
    local labels = { "普通成员", "主坦", "副坦", "治疗", "未识别" }
    return labels[math.max(1, math.min(5, math.floor(tonumber(role) or 1)))] or "--"
end

local function LevelTone(level)
    level = tonumber(level) or 1
    if level >= 4 then return "red" end
    if level == 3 then return "yellow" end
    if level == 2 then return "accent" end
    return "green"
end

local function FormatPercent(value)
    value = tonumber(value)
    return value ~= nil and string.format("%.1f%%", value) or "--"
end

local function FormatDistance(value)
    value = tonumber(value)
    return value ~= nil and string.format("%.1fm", value) or "--"
end

local function FormatScore(value)
    value = tonumber(value)
    return value ~= nil and string.format("%.1f", value) or "--"
end

local function CreateSelectableRow(prefix, list, poolIndex, tableView, onActivate)
    local row = RSUI:TableRow({
        id = prefix .. "_row_" .. tostring(poolIndex),
        parent = list,
        columns = tableView.columns,
        resolvedWidths = tableView.resolvedWidths,
        rowHeight = tableView.rowHeight,
        columnGap = tableView.columnGap,
        pickable = true,
    })
    if row ~= nil and row.root ~= nil then
        S.UI:SafeHandler(row.root, "OnClick", function()
            local index = row.itemIndex
            if index ~= nil and type(tableView.SetSelectedIndex) == "function" then tableView:SetSelectedIndex(index) end
            if type(onActivate) == "function" and row.item ~= nil then onActivate(row.item, false) end
            return true
        end, prefix .. ":click:" .. tostring(poolIndex))
        S.UI:SafeHandler(row.root, "OnRButtonUp", function()
            if type(onActivate) == "function" and row.item ~= nil then onActivate(row.item, true) end
            return true
        end, prefix .. ":right:" .. tostring(poolIndex))
    end
    return row
end

local function ActionButton(parent, id, text, width, fn, fill)
    return RSUI:Button({
        id = id,
        parent = parent,
        text = text,
        fontSize = 8,
        compact = true,
        gradient = true,
        slot = fill == true
            and { size = "fill", fill = 1, minWidth = tonumber(width) or 48, hAlign = "fill" }
            or { size = "fixed", width = tonumber(width) or 68, hAlign = "fill" },
        onClick = fn,
    })
end

local function SettingBinding(id, key, fallback)
    return RSUI:Binding({
        id = id,
        get = function()
            local h = ExportHealer()
            local value = h and type(h.GetSuiteSetting) == "function" and h:GetSuiteSetting(key) or nil
            if value == nil then return fallback end
            return value
        end,
        normalize = function(value)
            local h = ExportHealer()
            if h and type(h.PreviewSuiteSetting) == "function" then
                local ok, normalized = h:PreviewSuiteSetting(key, value)
                if ok == true then return normalized end
            end
            return value
        end,
        validate = function(value)
            local h = ExportHealer()
            if h == nil or type(h.PreviewSuiteSetting) ~= "function" then return false, "治疗模块未初始化" end
            local ok, _, err = h:PreviewSuiteSetting(key, value)
            return ok == true, err
        end,
        set = function(value)
            local h = ExportHealer()
            if h == nil or type(h.SetSuiteSetting) ~= "function" then return false end
            local ok, err = h:SetSuiteSetting(key, value)
            if ok ~= true and err ~= nil then SafeChat("治疗设置失败：" .. tostring(err)) end
            return ok == true
        end,
    })
end

local function WeightBinding(id, key, fallback)
    return RSUI:Binding({
        id = id,
        get = function()
            local h = ExportHealer()
            local value = h and type(h.GetSuiteWeight) == "function" and h:GetSuiteWeight(key) or nil
            return value ~= nil and value or fallback
        end,
        set = function(value)
            local h = ExportHealer()
            if h == nil or type(h.SetSuiteWeight) ~= "function" then return false end
            local ok, err = h:SetSuiteWeight(key, value)
            if ok ~= true and err ~= nil then SafeChat("评分权重设置失败：" .. tostring(err)) end
            return ok == true
        end,
    })
end

local function RoleScoreBinding(id, key, fallback)
    return RSUI:Binding({
        id = id,
        get = function()
            local h = ExportHealer()
            local value = h and type(h.GetSuiteRoleScore) == "function" and h:GetSuiteRoleScore(key) or nil
            return value ~= nil and value or fallback
        end,
        set = function(value)
            local h = ExportHealer()
            if h == nil or type(h.SetSuiteRoleScore) ~= "function" then return false end
            local ok, err = h:SetSuiteRoleScore(key, value)
            if ok ~= true and err ~= nil then SafeChat("职责评分设置失败：" .. tostring(err)) end
            return ok == true
        end,
    })
end

local function LocalNumberBinding(id, getter, setter)
    return RSUI:Binding({ id = id, get = getter, set = function(value) setter(math.floor(tonumber(value) or 0)); return true end })
end

function WH:Build(workspace, parent)
    local view = {
        subview = "recommend",
        buffMode = "groups",
        recommendationRows = {},
        recommendationRevision = -1,
        selectedMemberKey = nil,
        groupRows = {},
        selectedGroupRuleIndex = nil,
        conditionInputId = 0,
        trackedRows = {},
        selectedTrackedIndex = nil,
        trackedInputId = 0,
        overrideRows = {},
        selectedOverrideName = nil,
        lastRosterGeneration = -1,
        lastHealthGeneration = -1,
    }

    view.component = RSUI:Border({
        id = "combat_healer_v3_root", parent = parent,
        width = 100, height = 100, padding = 6, variant = "soft", gradient = false,
    })
    view.root = view.component and view.component.root or nil
    if view.root == nil then return nil end
    if view.root.rsBorder and view.root.rsBorder.SetVisible then view.root.rsBorder:SetVisible(false) end
    if view.root.rsBackground and view.root.rsBackground.SetVisible then view.root.rsBackground:SetVisible(false) end
    view.stack = RSUI:VerticalBox({ id = "combat_healer_v3_stack", parent = view.component, gap = 5 })

    ------------------------------------------------------------------------
    -- Main tabs
    ------------------------------------------------------------------------
    view.toolbar = RSUI:HorizontalBox({
        id = "combat_healer_v3_toolbar", parent = view.stack, gap = 4,
        slot = { size = "fixed", height = 28, hAlign = "fill" },
    })
    view.tabRecommend = ActionButton(view.toolbar, "combat_healer_v3_tab_recommend", "实时推荐", 72, function() view:SetSubview("recommend"); return true end)
    view.tabScore = ActionButton(view.toolbar, "combat_healer_v3_tab_score", "救援评分", 72, function() view:SetSubview("score"); return true end)
    view.tabBuffs = ActionButton(view.toolbar, "combat_healer_v3_tab_buffs", "BUFF条件", 72, function() view:SetSubview("buffs"); return true end)
    view.tabRoles = ActionButton(view.toolbar, "combat_healer_v3_tab_roles", "职责", 58, function() view:SetSubview("roles"); return true end)
    view.tabDisplay = ActionButton(view.toolbar, "combat_healer_v3_tab_display", "显示 / 校准", 86, function() view:SetSubview("display"); return true end)
    view.settingsButton = ActionButton(view.toolbar, "combat_healer_v3_settings", "高级设置", 66, function()
        workspace:SetMode("settings")
        return true
    end, true)

    view.summary = RSUI:Text({
        id = "combat_healer_v3_summary", parent = view.stack,
        text = "治疗辅助：--", tone = "muted", fontSize = 9, overflow = "ellipsis",
        slot = { size = "fixed", height = 20, hAlign = "fill" },
    })

    view.switcher = RSUI:WidgetSwitcher({
        id = "combat_healer_v3_switcher", parent = view.stack, activeIndex = 1,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })

    ------------------------------------------------------------------------
    -- 1. Live Recommendation + selected member inspector
    ------------------------------------------------------------------------
    view.recommendPage = RSUI:HorizontalBox({
        id = "combat_healer_v3_recommend_page", parent = view.switcher, gap = 6,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })
    local recommendColumns = {
        { id = "rank", title = "#", width = 34, minWidth = 28, absoluteMinWidth = 24, field = "rank" },
        { id = "name", title = "成员", size = "fill", minWidth = 106, absoluteMinWidth = 54, field = "name" },
        { id = "hp", title = "血量", width = 62, minWidth = 52, absoluteMinWidth = 38, field = "health", getTone = function(row) return row and row.tone or "muted" end },
        { id = "distance", title = "距离", width = 58, minWidth = 48, absoluteMinWidth = 36, field = "distance" },
        { id = "score", title = "救援分", width = 60, minWidth = 50, absoluteMinWidth = 38, field = "score", getTone = function(row) return row and row.tone or "muted" end },
        { id = "reason", title = "原因", width = 92, minWidth = 70, absoluteMinWidth = 46, field = "reason", tone = "muted" },
    }
    view.recommendTable = RSUI:TableView({
        id = "combat_healer_v3_recommend_table", parent = view.recommendPage,
        columns = recommendColumns, rowHeight = 22, headerHeight = 22, columnGap = 3,
        items = view.recommendationRows, overscan = 2, maxPoolSize = 32,
        selectable = true, selectionMode = "single",
        rowFactory = function(list, poolIndex, tableView)
            return CreateSelectableRow("combat_healer_v3_recommend", list, poolIndex, tableView, function(row)
                view.selectedMemberKey = row and row.key or nil
                view:RefreshSelectedMember()
            end)
        end,
        onSelectionChanged = function(index)
            local row = index and view.recommendationRows[index] or nil
            view.selectedMemberKey = row and row.key or nil
            view:RefreshSelectedMember()
        end,
        slot = { size = "fill", fill = 1, minWidth = 280, hAlign = "fill", vAlign = "fill" },
    })

    view.memberInspector = RSUI:Border({
        id = "combat_healer_v3_member_inspector", parent = view.recommendPage,
        width = 252, padding = 7, variant = "card", gradient = true, accentStrip = 2,
        slot = { size = "fixed", width = 252, hAlign = "fill", vAlign = "fill" },
    })
    view.memberStack = RSUI:VerticalBox({ id = "combat_healer_v3_member_stack", parent = view.memberInspector, gap = 4 })
    view.memberTitle = RSUI:Text({
        id = "combat_healer_v3_member_title", parent = view.memberStack,
        text = "未选择成员", tone = "accent", fontSize = 11, overflow = "ellipsis",
        slot = { size = "fixed", height = 22, hAlign = "fill" },
    })
    view.memberVitals = RSUI:Text({
        id = "combat_healer_v3_member_vitals", parent = view.memberStack,
        text = "血量 / 距离：--", tone = "muted", fontSize = 8, overflow = "wrap", maxLines = 2,
        slot = { size = "fixed", height = 34, hAlign = "fill" },
    })
    view.memberScore = RSUI:Text({
        id = "combat_healer_v3_member_score", parent = view.memberStack,
        text = "救援评分：--", tone = "muted", fontSize = 8, overflow = "wrap", maxLines = 3,
        slot = { size = "fixed", height = 48, hAlign = "fill" },
    })
    view.memberStatuses = RSUI:Text({
        id = "combat_healer_v3_member_statuses", parent = view.memberStack,
        text = "已提交状态：--", tone = "muted", fontSize = 8, overflow = "wrap", maxLines = 4,
        slot = { size = "fixed", height = 62, hAlign = "fill" },
    })
    view.roleHint = RSUI:Text({
        id = "combat_healer_v3_role_hint", parent = view.memberStack,
        text = "手动职责覆盖会立即交给 Healer Roster Authority 重新分类。", tone = "muted", fontSize = 8, overflow = "wrap", maxLines = 2,
        slot = { size = "fixed", height = 34, hAlign = "fill" },
    })
    view.roleRow1 = RSUI:HorizontalBox({
        id = "combat_healer_v3_role_row1", parent = view.memberStack, gap = 3,
        slot = { size = "fixed", height = 26, hAlign = "fill" },
    })
    view.roleNormal = ActionButton(view.roleRow1, "combat_healer_v3_role_normal", "普通", 46, function() view:SetSelectedRole(1); return true end, true)
    view.roleMain = ActionButton(view.roleRow1, "combat_healer_v3_role_main", "主坦", 46, function() view:SetSelectedRole(2); return true end, true)
    view.roleOff = ActionButton(view.roleRow1, "combat_healer_v3_role_off", "副坦", 46, function() view:SetSelectedRole(3); return true end, true)
    view.roleHeal = ActionButton(view.roleRow1, "combat_healer_v3_role_heal", "治疗", 46, function() view:SetSelectedRole(4); return true end, true)
    view.roleRow2 = RSUI:HorizontalBox({
        id = "combat_healer_v3_role_row2", parent = view.memberStack, gap = 3,
        slot = { size = "fixed", height = 26, hAlign = "fill" },
    })
    view.roleUnknown = ActionButton(view.roleRow2, "combat_healer_v3_role_unknown", "未识别", 64, function() view:SetSelectedRole(5); return true end, true)
    view.roleClear = ActionButton(view.roleRow2, "combat_healer_v3_role_clear", "清除覆盖", 72, function() view:ClearSelectedRole(); return true end, true)
    view.roleSettings = ActionButton(view.roleRow2, "combat_healer_v3_role_settings", "职责设置", 68, function() view:SetSubview("roles"); return true end, true)

    ------------------------------------------------------------------------
    -- 2. Rescue score / candidate policy form
    ------------------------------------------------------------------------
    view.scorePage = RSUI:VerticalBox({
        id = "combat_healer_v3_score_page", parent = view.switcher, gap = 5,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })
    view.scoreForm = RSUI:Form({
        id = "combat_healer_v3_score_form", parent = view.scorePage, sectionGap = 6,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "top" },
    })
    view.candidateSection = view.scoreForm:AddSection({
        id = "combat_healer_v3_candidate_section", title = "候选 / 扫描策略", minCellWidth = 178, maxColumns = 3, fieldHeight = 50,
    })
    local candidateFields = {
        { id="max_distance", label="最大治疗距离", key="maxDistance", min=1, max=100, step=1, fallback=27, unit="m" },
        { id="enter_hp", label="进入候选血量", key="enterThreshold", min=1, max=100, step=1, fallback=100, unit="%" },
        { id="exit_hp", label="退出候选血量", key="exitThreshold", min=1, max=100, step=1, fallback=100, unit="%" },
        { id="self_hp", label="自己警戒血量", key="selfThreshold", min=1, max=100, step=1, fallback=70, unit="%" },
        { id="emergency_hp", label="紧急血量", key="emergencyThreshold", min=1, max=100, step=1, fallback=50, unit="%" },
        { id="low_hp", label="低血量", key="lowHealthThreshold", min=1, max=100, step=1, fallback=70, unit="%" },
        { id="health_scan", label="血量扫描", key="healthScanMs", min=100, max=1000, step=50, fallback=150, unit="ms" },
        { id="buff_scan", label="BUFF扫描", key="buffScanMs", min=200, max=2000, step=50, fallback=300, unit="ms" },
        { id="hold", label="候选保持", key="minHoldMs", min=0, max=5000, step=50, fallback=500, unit="ms" },
    }
    for _, item in ipairs(candidateFields) do
        view.scoreForm:AddField(view.candidateSection, {
            type = "NumericField", id = "combat_healer_v3_field_" .. item.id, label = item.label,
            min = item.min, max = item.max, step = item.step, integer = true, unit = item.unit,
            binding = SettingBinding("healer.v3." .. item.key, item.key, item.fallback),
        })
    end
    view.weightSection = view.scoreForm:AddSection({
        id = "combat_healer_v3_weight_section", title = "救援评分权重", minCellWidth = 178, maxColumns = 3, fieldHeight = 50,
    })
    for _, item in ipairs({
        {"health","生命危险",55},{"distance","距离",15},{"missing","缺失生命",10},{"unprotected","无治疗保护",20},
    }) do
        view.scoreForm:AddField(view.weightSection, {
            type = "NumericField", id = "combat_healer_v3_weight_" .. item[1], label = item[2],
            min = 0, max = 100, step = 1, unit = "%", slider = true,
            binding = WeightBinding("healer.v3.weight." .. item[1], item[1], item[3]),
        })
    end
    view.scoreForm:AddField(view.weightSection, {
        type = "NumericField", id = "combat_healer_v3_score_lead", label = "评分领先切换",
        min = 0, max = 50, step = 1, binding = SettingBinding("healer.v3.scoreLead", "scoreLead", 5),
    })
    view.scoreHint = RSUI:Text({
        id = "combat_healer_v3_score_hint", parent = view.scorePage,
        text = "权重写入后由 Healer Domain 统一归一化；UI 不复制评分公式。", tone = "muted", fontSize = 8, overflow = "wrap", maxLines = 2,
        slot = { size = "fixed", height = 30, hAlign = "fill" },
    })

    ------------------------------------------------------------------------
    -- 3. BUFF condition groups / tracked Buffs
    ------------------------------------------------------------------------
    view.buffPage = RSUI:VerticalBox({
        id = "combat_healer_v3_buff_page", parent = view.switcher, gap = 5,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })
    view.buffTabs = RSUI:HorizontalBox({
        id = "combat_healer_v3_buff_tabs", parent = view.buffPage, gap = 4,
        slot = { size = "fixed", height = 28, hAlign = "fill" },
    })
    view.groupTab = ActionButton(view.buffTabs, "combat_healer_v3_group_tab", "颜色条件组", 82, function() view:SetBuffMode("groups"); return true end)
    view.trackedTab = ActionButton(view.buffTabs, "combat_healer_v3_tracked_tab", "追踪 Buff", 76, function() view:SetBuffMode("tracked"); return true end)
    view.buffAdvanced = ActionButton(view.buffTabs, "combat_healer_v3_buff_advanced", "高级规则 / 颜色", 98, function()
        workspace:SetSection("buffs")
        return true
    end, true)
    view.buffSwitcher = RSUI:WidgetSwitcher({
        id = "combat_healer_v3_buff_switcher", parent = view.buffPage, activeIndex = 1,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })

    -- Condition groups
    view.groupPage = RSUI:VerticalBox({ id = "combat_healer_v3_group_page", parent = view.buffSwitcher, gap = 4 })
    view.groupActions = RSUI:HorizontalBox({
        id = "combat_healer_v3_group_actions", parent = view.groupPage, gap = 4,
        slot = { size = "fixed", height = 28, hAlign = "fill" },
    })
    view.groupAdd = ActionButton(view.groupActions, "combat_healer_v3_group_add", "新增条件组", 78, function()
        local h = ExportHealer(); if h and type(h.AddSuiteColorConditionGroup) == "function" then
            local ok, idx = h:AddSuiteColorConditionGroup(); if ok then view.selectedGroupRuleIndex = idx else SafeChat(tostring(idx or "新增失败")) end
        end
        view:RefreshBuffs(true); return true
    end)
    view.groupToggle = ActionButton(view.groupActions, "combat_healer_v3_group_toggle", "启用 / 禁用", 76, function() view:ToggleSelectedGroup(); return true end)
    view.groupUp = ActionButton(view.groupActions, "combat_healer_v3_group_up", "上移", 50, function() view:MoveSelectedGroup(-1); return true end)
    view.groupDown = ActionButton(view.groupActions, "combat_healer_v3_group_down", "下移", 50, function() view:MoveSelectedGroup(1); return true end)
    view.groupDelete = ActionButton(view.groupActions, "combat_healer_v3_group_delete", "删除", 50, function() view:DeleteSelectedGroup(); return true end)
    view.groupIdInput = RSUI:NumericInput({
        id = "combat_healer_v3_group_id", parent = view.groupActions,
        min = 1, max = 99999999, step = 1, integer = true, maxLength = 10,
        binding = LocalNumberBinding("healer.v3.group.id", function() return view.conditionInputId end, function(v) view.conditionInputId = v end),
        slot = { size = "fixed", width = 82, hAlign = "fill" },
    })
    view.groupAddId = ActionButton(view.groupActions, "combat_healer_v3_group_add_id", "+状态ID", 66, function() view:ChangeSelectedGroupId(true); return true end)
    view.groupRemoveId = ActionButton(view.groupActions, "combat_healer_v3_group_remove_id", "-状态ID", 66, function() view:ChangeSelectedGroupId(false); return true end, true)
    local groupColumns = {
        { id="state", title="状态", width=52, minWidth=44, absoluteMinWidth=36, field="state", getTone=function(row) return row and row.tone or "muted" end },
        { id="name", title="条件组", size="fill", minWidth=120, absoluteMinWidth=60, field="name" },
        { id="ids", title="状态 ID", width=220, minWidth=100, absoluteMinWidth=70, field="ids", tone="muted" },
    }
    view.groupTable = RSUI:TableView({
        id="combat_healer_v3_group_table", parent=view.groupPage, columns=groupColumns,
        rowHeight=23, headerHeight=22, columnGap=3, items=view.groupRows, overscan=2, maxPoolSize=24,
        selectable=true, selectionMode="single",
        rowFactory=function(list,poolIndex,tableView)
            return CreateSelectableRow("combat_healer_v3_group",list,poolIndex,tableView,function(row)
                view.selectedGroupRuleIndex=row and row.ruleIndex or nil; view:RefreshGroupActions()
            end)
        end,
        onSelectionChanged=function(index)
            local row=index and view.groupRows[index] or nil; view.selectedGroupRuleIndex=row and row.ruleIndex or nil; view:RefreshGroupActions()
        end,
        slot={size="fill",fill=1,hAlign="fill",vAlign="fill"},
    })
    view.groupInfo = RSUI:Text({
        id="combat_healer_v3_group_info", parent=view.groupPage, text="选择条件组后可增删状态 ID。", tone="muted", fontSize=8, overflow="ellipsis",
        slot={size="fixed",height=20,hAlign="fill"},
    })

    -- Tracked Buff list
    view.trackedPage = RSUI:VerticalBox({ id = "combat_healer_v3_tracked_page", parent = view.buffSwitcher, gap = 4 })
    view.trackedActions = RSUI:HorizontalBox({
        id = "combat_healer_v3_tracked_actions", parent = view.trackedPage, gap = 4,
        slot = { size = "fixed", height = 28, hAlign = "fill" },
    })
    view.trackedIdInput = RSUI:NumericInput({
        id = "combat_healer_v3_tracked_id", parent = view.trackedActions,
        min = 1, max = 99999999, step = 1, integer = true, maxLength = 10,
        binding = LocalNumberBinding("healer.v3.tracked.id", function() return view.trackedInputId end, function(v) view.trackedInputId = v end),
        slot = { size = "fixed", width = 90, hAlign = "fill" },
    })
    view.trackedAdd = ActionButton(view.trackedActions, "combat_healer_v3_tracked_add", "按 ID 追踪", 78, function() view:AddTrackedBuff(); return true end)
    view.trackedToggle = ActionButton(view.trackedActions, "combat_healer_v3_tracked_toggle", "启用 / 禁用", 76, function() view:ToggleTrackedBuff(); return true end)
    view.trackedUp = ActionButton(view.trackedActions, "combat_healer_v3_tracked_up", "上移", 50, function() view:MoveTrackedBuff(-1); return true end)
    view.trackedDown = ActionButton(view.trackedActions, "combat_healer_v3_tracked_down", "下移", 50, function() view:MoveTrackedBuff(1); return true end)
    view.trackedDelete = ActionButton(view.trackedActions, "combat_healer_v3_tracked_delete", "删除", 50, function() view:DeleteTrackedBuff(); return true end)
    view.trackedColor = ActionButton(view.trackedActions, "combat_healer_v3_tracked_color", "颜色编辑", 70, function() workspace:SetSection("buffs"); return true end, true)
    local trackedColumns = {
        { id="state", title="状态", width=52, minWidth=44, absoluteMinWidth=36, field="state", getTone=function(row) return row and row.tone or "muted" end },
        { id="name", title="Buff", size="fill", minWidth=150, absoluteMinWidth=70, field="name" },
        { id="id", title="ID", width=78, minWidth=64, absoluteMinWidth=48, field="id" },
    }
    view.trackedTable = RSUI:TableView({
        id="combat_healer_v3_tracked_table", parent=view.trackedPage, columns=trackedColumns,
        rowHeight=23, headerHeight=22, columnGap=3, items=view.trackedRows, overscan=2, maxPoolSize=24,
        selectable=true, selectionMode="single",
        rowFactory=function(list,poolIndex,tableView)
            return CreateSelectableRow("combat_healer_v3_tracked",list,poolIndex,tableView,function(row)
                view.selectedTrackedIndex=row and row.index or nil; view:RefreshTrackedActions()
            end)
        end,
        onSelectionChanged=function(index)
            local row=index and view.trackedRows[index] or nil; view.selectedTrackedIndex=row and row.index or nil; view:RefreshTrackedActions()
        end,
        slot={size="fill",fill=1,hAlign="fill",vAlign="fill"},
    })
    view.trackedInfo = RSUI:Text({
        id="combat_healer_v3_tracked_info", parent=view.trackedPage,
        text="追踪 Buff 是兼容显示策略；创建颜色条件组后，条件组成为显示颜色 Authority。", tone="muted", fontSize=8, overflow="wrap", maxLines=2,
        slot={size="fixed",height=30,hAlign="fill"},
    })

    ------------------------------------------------------------------------
    -- 4. Role scoring + override list
    ------------------------------------------------------------------------
    view.rolesPage = RSUI:VerticalBox({
        id = "combat_healer_v3_roles_page", parent = view.switcher, gap = 5,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })
    view.rolesForm = RSUI:Form({
        id = "combat_healer_v3_roles_form", parent = view.rolesPage, sectionGap = 5,
        slot = { size = "fixed", height = 184, hAlign = "fill", vAlign = "top" },
    })
    view.roleScoreSection = view.rolesForm:AddSection({
        id = "combat_healer_v3_role_score_section", title = "职责评分", minCellWidth = 165, maxColumns = 3, fieldHeight = 48,
    })
    view.rolesForm:AddField(view.roleScoreSection, {
        type="ToggleField", id="combat_healer_v3_role_enabled", label="启用职责评分",
        onText="已启用", offText="已关闭", binding=SettingBinding("healer.v3.role.enabled","roleScoringEnabled",false),
    })
    for _, item in ipairs({
        {"normal","普通成员",0},{"mainTank","主坦",0},{"offTank","副坦",0},{"healer","治疗",0},{"unknown","未识别",0},
    }) do
        view.rolesForm:AddField(view.roleScoreSection, {
            type="NumericField", id="combat_healer_v3_role_score_"..item[1], label=item[2].."固定加分",
            min=-100,max=100,step=1,slider=true,binding=RoleScoreBinding("healer.v3.role."..item[1],item[1],item[3]),
        })
    end
    view.overrideHeader = RSUI:HorizontalBox({
        id="combat_healer_v3_override_header", parent=view.rolesPage, gap=4,
        slot={size="fixed",height=28,hAlign="fill"},
    })
    view.overrideTitle = RSUI:Text({
        id="combat_healer_v3_override_title", parent=view.overrideHeader, text="手动职责覆盖", tone="accent", fontSize=9,
        slot={size="fill",fill=1,minWidth=100,hAlign="fill",vAlign="center"},
    })
    view.overrideDelete = ActionButton(view.overrideHeader,"combat_healer_v3_override_delete","删除选中",74,function() view:DeleteOverride(); return true end)
    view.overrideAdvanced = ActionButton(view.overrideHeader,"combat_healer_v3_override_advanced","高级职责设置",88,function() workspace:SetSection("roles"); return true end)
    local overrideColumns = {
        {id="name",title="玩家",size="fill",minWidth=140,absoluteMinWidth=72,field="name"},
        {id="role",title="职责",width=100,minWidth=76,absoluteMinWidth=50,field="role",getTone=function() return "accent" end},
    }
    view.overrideTable = RSUI:TableView({
        id="combat_healer_v3_override_table",parent=view.rolesPage,columns=overrideColumns,rowHeight=23,headerHeight=22,columnGap=3,
        items=view.overrideRows,overscan=2,maxPoolSize=24,selectable=true,selectionMode="single",
        rowFactory=function(list,poolIndex,tableView)
            return CreateSelectableRow("combat_healer_v3_override",list,poolIndex,tableView,function(row)
                view.selectedOverrideName=row and row.name or nil; view:RefreshOverrideActions()
            end)
        end,
        onSelectionChanged=function(index)
            local row=index and view.overrideRows[index] or nil; view.selectedOverrideName=row and row.name or nil; view:RefreshOverrideActions()
        end,
        slot={size="fill",fill=1,hAlign="fill",vAlign="fill"},
    })

    ------------------------------------------------------------------------
    -- 5. Head / Raid display + calibration
    ------------------------------------------------------------------------
    view.displayPage = RSUI:VerticalBox({
        id = "combat_healer_v3_display_page", parent = view.switcher, gap = 5,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })
    view.displayForm = RSUI:Form({
        id="combat_healer_v3_display_form",parent=view.displayPage,sectionGap=5,
        slot={size="fixed",height=196,hAlign="fill",vAlign="top"},
    })
    view.displaySection = view.displayForm:AddSection({
        id="combat_healer_v3_display_section",title="团队高亮 / 头顶标记",minCellWidth=155,maxColumns=4,fieldHeight=46,
    })
    view.displayForm:AddField(view.displaySection,{type="NumericField",id="combat_healer_v3_head_count",label="头顶推荐数量",min=1,max=50,step=1,integer=true,binding=SettingBinding("healer.v3.head.count","headMarkerCount",5)})
    view.displayForm:AddField(view.displaySection,{type="ToggleField",id="combat_healer_v3_head_name",label="显示名称",binding=SettingBinding("healer.v3.head.name","showHeadName",true)})
    view.displayForm:AddField(view.displaySection,{type="ToggleField",id="combat_healer_v3_head_distance",label="显示距离",binding=SettingBinding("healer.v3.head.distance","showHeadDistance",true)})
    view.displayForm:AddField(view.displaySection,{type="ToggleField",id="combat_healer_v3_head_score",label="显示评分",binding=SettingBinding("healer.v3.head.score","showHeadScore",true)})
    view.displayForm:AddField(view.displaySection,{type="ToggleField",id="combat_healer_v3_raid_ranks",label="团队列表名次",binding=SettingBinding("healer.v3.raid.ranks","showRaidRanks",true)})
    view.displayForm:AddField(view.displaySection,{type="NumericField",id="combat_healer_v3_raid_count",label="团队名次数量",min=0,max=50,step=1,integer=true,binding=SettingBinding("healer.v3.raid.count","raidRankCount",5)})
    view.displayForm:AddField(view.displaySection,{type="NumericField",id="combat_healer_v3_raid_font",label="名次字号",min=8,max=20,step=1,integer=true,binding=SettingBinding("healer.v3.raid.font","raidRankFontSize",11)})
    view.displayForm:AddField(view.displaySection,{type="NumericField",id="combat_healer_v3_raid_alpha",label="名次透明度",min=0.1,max=1,step=0.05,binding=SettingBinding("healer.v3.raid.alpha","raidRankAlpha",1)})
    view.calSummary = RSUI:Text({
        id="combat_healer_v3_cal_summary",parent=view.displayPage,text="位置校准：--",tone="muted",fontSize=8,overflow="ellipsis",
        slot={size="fixed",height=20,hAlign="fill"},
    })
    view.calRow1 = RSUI:HorizontalBox({id="combat_healer_v3_cal_row1",parent=view.displayPage,gap=4,slot={size="fixed",height=27,hAlign="fill"}})
    view.calScope = ActionButton(view.calRow1,"combat_healer_v3_cal_scope","范围：两团",84,function() view:CycleCalibrationScope(); return true end)
    view.calSection = ActionButton(view.calRow1,"combat_healer_v3_cal_section","区域：1团上",92,function() view:CycleCalibrationSection(); return true end)
    view.calMode = ActionButton(view.calRow1,"combat_healer_v3_cal_mode","开始校准",74,function() view:ToggleCalibration(); return true end)
    view.calCenter = ActionButton(view.calRow1,"combat_healer_v3_cal_center","居中",54,function() view:CalibrationCommand("center"); return true end)
    view.calReset = ActionButton(view.calRow1,"combat_healer_v3_cal_reset","恢复当前",68,function() view:CalibrationCommand("reset"); return true end)
    view.calColors = ActionButton(view.calRow1,"combat_healer_v3_display_advanced","颜色 / 外观高级",94,function() workspace:SetSection("colors"); return true end,true)
    view.calRow2 = RSUI:HorizontalBox({id="combat_healer_v3_cal_row2",parent=view.displayPage,gap=3,slot={size="fixed",height=27,hAlign="fill"}})
    local adjustSpecs = {
        {"xminus","X-", "offsetX",-10},{"xplus","X+","offsetX",10},{"yminus","Y-","offsetY",-10},{"yplus","Y+","offsetY",10},
        {"wminus","宽-","width",-20},{"wplus","宽+","width",20},{"hminus","高-","height",-20},{"hplus","高+","height",20},
    }
    view.calAdjustButtons={}
    for _,item in ipairs(adjustSpecs) do
        -- Lua 5.1 generic-for variables are shared by closures. Copy the
        -- immutable button specification into locals so every callback keeps
        -- its own field/delta instead of all buttons targeting the last row.
        local suffix = item[1]
        local label = item[2]
        local field = item[3]
        local delta = item[4]
        view.calAdjustButtons[#view.calAdjustButtons+1]=ActionButton(view.calRow2,"combat_healer_v3_cal_"..suffix,label,46,function()
            view:AdjustCalibration(field,delta); return true
        end,true)
    end

    ------------------------------------------------------------------------
    -- Methods
    ------------------------------------------------------------------------
    function view:SetSubview(name)
        local indexMap = { recommend=1, score=2, buffs=3, roles=4, display=5 }
        name = indexMap[name] and name or "recommend"
        self.subview = name
        self.switcher:SetActiveIndex(indexMap[name])
        self.tabRecommend:SetSelected(name=="recommend")
        self.tabScore:SetSelected(name=="score")
        self.tabBuffs:SetSelected(name=="buffs")
        self.tabRoles:SetSelected(name=="roles")
        self.tabDisplay:SetSelected(name=="display")
        self:Refresh(true)
        return true
    end

    function view:SetBuffMode(mode)
        mode = mode=="tracked" and "tracked" or "groups"
        self.buffMode=mode
        self.buffSwitcher:SetActiveIndex(mode=="groups" and 1 or 2)
        self.groupTab:SetSelected(mode=="groups")
        self.trackedTab:SetSelected(mode=="tracked")
        self:RefreshBuffs(true)
        return true
    end

    function view:SetSelectedRole(role)
        local h=ExportHealer(); if h==nil or self.selectedMemberKey==nil or type(h.GetWorkspaceMemberSnapshot)~="function" then return false end
        local member=h:GetWorkspaceMemberSnapshot(self.selectedMemberKey)
        if type(member)~="table" or tostring(member.name or "")=="" then return false end
        local ok,err=h:SetSuiteRoleOverride(member.name,role)
        if ok~=true and err then SafeChat(tostring(err)) end
        self:Refresh(true)
        return ok==true
    end

    function view:ClearSelectedRole()
        local h=ExportHealer(); if h==nil or self.selectedMemberKey==nil or type(h.GetWorkspaceMemberSnapshot)~="function" then return false end
        local member=h:GetWorkspaceMemberSnapshot(self.selectedMemberKey)
        if type(member)~="table" then return false end
        local ok,err=h:RemoveSuiteRoleOverride(member.name)
        if ok~=true and err then SafeChat(tostring(err)) end
        self:Refresh(true)
        return ok==true
    end

    function view:RefreshSelectedMember()
        local h=ExportHealer()
        if h==nil or self.selectedMemberKey==nil or type(h.GetWorkspaceMemberSnapshot)~="function" then
            self.memberTitle:SetText("未选择成员")
            self.memberVitals:SetText("血量 / 距离：--")
            self.memberScore:SetText("救援评分：--")
            self.memberStatuses:SetText("已提交状态：--")
            for _,b in ipairs({self.roleNormal,self.roleMain,self.roleOff,self.roleHeal,self.roleUnknown,self.roleClear}) do b:SetEnabled(false) end
            return false
        end
        local member=h:GetWorkspaceMemberSnapshot(self.selectedMemberKey)
        if type(member)~="table" then self.selectedMemberKey=nil; return self:RefreshSelectedMember() end
        self.memberTitle:SetText(tostring(member.name or "未知成员").." · "..RoleLabel(h,member.role))
        self.memberTitle:SetTone(LevelTone(member.level))
        self.memberVitals:SetText("血量 "..FormatPercent(member.healthPercent).." · 距离 "..FormatDistance(member.distance)
            .." · 缺失 "..tostring(math.floor(tonumber(member.missingHealth) or 0)))
        if member.isRecommended==true then
            self.memberScore:SetText("救援分 "..FormatScore(member.finalScore).." · "..tostring(member.colorReason or "")
                .."\n"..tostring(member.reason or ""))
            self.memberScore:SetTone(LevelTone(member.level))
        else
            self.memberScore:SetText("当前不在治疗候选列表 · 职责 "..RoleLabel(h,member.role))
            self.memberScore:SetTone("muted")
        end
        local statuses,total = type(h.GetWorkspaceCommittedStatuses)=="function" and h:GetWorkspaceCommittedStatuses(self.selectedMemberKey,6) or {},0
        local names={}
        for _,st in ipairs(type(statuses)=="table" and statuses or {}) do names[#names+1]=tostring(st.name or st.id or "") end
        self.memberStatuses:SetText("已提交状态 "..tostring(total or 0).."："..(#names>0 and table.concat(names," / ") or "暂无缓存"))
        self.memberStatuses:SetTone((tonumber(total) or 0)>0 and "accent" or "muted")
        for _,b in ipairs({self.roleNormal,self.roleMain,self.roleOff,self.roleHeal,self.roleUnknown,self.roleClear}) do b:SetEnabled(true) end
        return true
    end

    function view:RefreshRecommendations(force,revisions)
        local h=ExportHealer(); if h==nil or type(h.GetWorkspaceRecommendations)~="function" then return false end
        revisions=revisions or (type(h.GetWorkspaceRevisions)=="function" and h:GetWorkspaceRevisions() or {})
        local revision=tonumber(revisions.recommendation) or 0
        if force==true or revision~=self.recommendationRevision then
            local source=h:GetWorkspaceRecommendations(100) or {}
            local rows={}
            for index,item in ipairs(source) do
                rows[index]={
                    key=tostring(item.key or ""),rank=tostring(item.rank or index),name=tostring(item.name or "未知成员"),
                    health=FormatPercent(item.healthPercent),distance=FormatDistance(item.distance),score=FormatScore(item.finalScore),
                    reason=tostring(item.colorReason or item.reason or ""),tone=LevelTone(item.level),source=item,
                }
            end
            self.recommendationRows=rows
            self.recommendationRevision=revision
            self.recommendTable:SetItems(rows,"healer:v3:recommend:"..tostring(revision))
            if self.selectedMemberKey~=nil then
                local found=false; for _,row in ipairs(rows) do if row.key==self.selectedMemberKey then found=true break end end
                if not found then self.selectedMemberKey=nil; if type(self.recommendTable.ClearSelection)=="function" then self.recommendTable:ClearSelection() end end
            end
        end
        self:RefreshSelectedMember()
        return true
    end

    function view:RefreshGroupActions()
        local selected=self.selectedGroupRuleIndex~=nil
        for _,b in ipairs({self.groupToggle,self.groupUp,self.groupDown,self.groupDelete,self.groupAddId,self.groupRemoveId}) do b:SetEnabled(selected) end
        local row=nil
        for _,candidate in ipairs(self.groupRows) do if candidate.ruleIndex==self.selectedGroupRuleIndex then row=candidate break end end
        self.groupInfo:SetText(row and ("选中："..row.name.." · ID："..row.ids) or "选择条件组后可增删状态 ID。")
    end

    function view:ToggleSelectedGroup()
        local h=ExportHealer(); if h==nil or self.selectedGroupRuleIndex==nil then return false end
        local list=h:GetSuiteConditionGroups() or {}; local current
        for _,r in ipairs(list) do if r.ruleIndex==self.selectedGroupRuleIndex then current=r break end end
        if current and type(h.SetSuiteRuleEnabled)=="function" then h:SetSuiteRuleEnabled(current.ruleIndex,current.enabled==false) end
        self:RefreshBuffs(true); return true
    end
    function view:MoveSelectedGroup(delta)
        local h=ExportHealer(); if h and self.selectedGroupRuleIndex and type(h.MoveSuiteConditionGroup)=="function" then
            local ok,target=h:MoveSuiteConditionGroup(self.selectedGroupRuleIndex,delta); if ok and target then self.selectedGroupRuleIndex=target end
        end
        self:RefreshBuffs(true); return true
    end
    function view:DeleteSelectedGroup()
        local h=ExportHealer(); if h and self.selectedGroupRuleIndex and type(h.RemoveSuiteRule)=="function" then h:RemoveSuiteRule(self.selectedGroupRuleIndex) end
        self.selectedGroupRuleIndex=nil; self:RefreshBuffs(true); return true
    end
    function view:ChangeSelectedGroupId(add)
        local h=ExportHealer(); local id=math.floor(tonumber(self.conditionInputId) or 0)
        if h==nil or self.selectedGroupRuleIndex==nil or id<=0 then SafeChat("请先选择条件组并输入有效状态 ID。"); return false end
        local ok,err
        if add and type(h.AddSuiteRuleId)=="function" then ok,err=h:AddSuiteRuleId(self.selectedGroupRuleIndex,id)
        elseif not add and type(h.RemoveSuiteRuleId)=="function" then ok,err=h:RemoveSuiteRuleId(self.selectedGroupRuleIndex,id) end
        if ok~=true and err then SafeChat(tostring(err)) end
        self:RefreshBuffs(true); return ok==true
    end

    function view:RefreshTrackedActions()
        local selected=self.selectedTrackedIndex~=nil
        for _,b in ipairs({self.trackedToggle,self.trackedUp,self.trackedDown,self.trackedDelete}) do b:SetEnabled(selected) end
    end
    function view:AddTrackedBuff()
        local h=ExportHealer(); local id=math.floor(tonumber(self.trackedInputId) or 0)
        if h==nil or id<=0 or type(h.AddTrackedBuffId)~="function" then SafeChat("请输入有效 Buff ID。"); return false end
        local ok,err=h:AddTrackedBuffId(id)
        if ok~=true and err then SafeChat(tostring(err)) end
        self:RefreshBuffs(true); return ok==true
    end
    function view:ToggleTrackedBuff()
        local h=ExportHealer(); local row=self.selectedTrackedIndex and self.trackedRows[self.selectedTrackedIndex] or nil
        if h and row and type(h.SetTrackedBuffEnabled)=="function" then h:SetTrackedBuffEnabled(row.index,row.enabled~=true) end
        self:RefreshBuffs(true); return true
    end
    function view:MoveTrackedBuff(delta)
        local h=ExportHealer(); local row=self.selectedTrackedIndex and self.trackedRows[self.selectedTrackedIndex] or nil
        if h and row and type(h.MoveTrackedBuff)=="function" then
            local target=row.index+(delta<0 and -1 or 1)
            if h:MoveTrackedBuff(row.index,delta) then self.selectedTrackedIndex=target end
        end
        self:RefreshBuffs(true); return true
    end
    function view:DeleteTrackedBuff()
        local h=ExportHealer(); local row=self.selectedTrackedIndex and self.trackedRows[self.selectedTrackedIndex] or nil
        if h and row and type(h.RemoveTrackedBuff)=="function" then h:RemoveTrackedBuff(row.index) end
        self.selectedTrackedIndex=nil; self:RefreshBuffs(true); return true
    end

    function view:RefreshBuffs(force)
        local h=ExportHealer(); if h==nil then return false end
        if self.buffMode=="groups" then
            local groups=type(h.GetSuiteConditionGroups)=="function" and h:GetSuiteConditionGroups() or {}
            local rows={}
            for index,g in ipairs(groups) do
                local ids={}; for _,id in ipairs(g.ids or {}) do ids[#ids+1]=tostring(id) end
                rows[index]={ruleIndex=g.ruleIndex,name=tostring(g.name or ("条件组 "..index)),enabled=g.enabled~=false,
                    state=g.enabled==false and "关闭" or "启用",tone=g.enabled==false and "muted" or "green",ids=#ids>0 and table.concat(ids,", ") or "--"}
            end
            self.groupRows=rows; self.groupTable:SetItems(rows,"healer:v3:groups:"..tostring(#rows)..":"..table.concat((function() local x={} for _,r in ipairs(rows) do x[#x+1]=tostring(r.ruleIndex)..":"..tostring(r.enabled)..":"..r.ids end return x end)(),"|"))
            local exists=false; for _,r in ipairs(rows) do if r.ruleIndex==self.selectedGroupRuleIndex then exists=true break end end
            if not exists then self.selectedGroupRuleIndex=nil end
            self:RefreshGroupActions()
        else
            local tracked=type(h.GetTrackedBuffs)=="function" and h:GetTrackedBuffs() or {}
            local rows={}
            for index,item in ipairs(tracked) do rows[index]={index=index,name=tostring(item.name or ("Buff "..tostring(item.id or ""))),id=tostring(item.id or ""),enabled=item.enabled~=false,state=item.enabled==false and "关闭" or "启用",tone=item.enabled==false and "muted" or "green"} end
            self.trackedRows=rows; self.trackedTable:SetItems(rows,"healer:v3:tracked:"..tostring(#rows)..":"..(function() local x={} for _,r in ipairs(rows) do x[#x+1]=r.id..":"..tostring(r.enabled) end return table.concat(x,"|") end)())
            if self.selectedTrackedIndex~=nil and self.trackedRows[self.selectedTrackedIndex]==nil then self.selectedTrackedIndex=nil end
            self:RefreshTrackedActions()
        end
        return true
    end

    function view:RefreshOverrideActions()
        self.overrideDelete:SetEnabled(self.selectedOverrideName~=nil)
    end
    function view:DeleteOverride()
        local h=ExportHealer(); if h and self.selectedOverrideName and type(h.RemoveSuiteRoleOverride)=="function" then
            local ok,err=h:RemoveSuiteRoleOverride(self.selectedOverrideName); if ok~=true and err then SafeChat(tostring(err)) end
        end
        self.selectedOverrideName=nil; self:RefreshRoles(true); return true
    end
    function view:RefreshRoles(force)
        local h=ExportHealer(); if h==nil then return false end
        if self.rolesForm and type(self.rolesForm.Render)=="function" then self.rolesForm:Render() end
        local source=type(h.GetSuiteRoleOverrides)=="function" and h:GetSuiteRoleOverrides() or {}
        local rows={}
        for index,item in ipairs(source) do rows[index]={name=tostring(item.name or ""),role=RoleLabel(h,item.role),rawRole=item.role} end
        self.overrideRows=rows; self.overrideTable:SetItems(rows,"healer:v3:overrides:"..tostring(#rows)..":"..(function() local x={} for _,r in ipairs(rows) do x[#x+1]=r.name..":"..tostring(r.rawRole) end return table.concat(x,"|") end)())
        if self.selectedOverrideName~=nil then local found=false for _,r in ipairs(rows) do if r.name==self.selectedOverrideName then found=true break end end if not found then self.selectedOverrideName=nil end end
        self:RefreshOverrideActions(); return true
    end

    function view:CycleCalibrationScope()
        local h=ExportHealer(); if h==nil then return false end
        local current=tonumber(h:GetSuiteSetting("raidCalibrationScope")) or 1
        h:SetSuiteSetting("raidCalibrationScope",current%3+1); self:RefreshDisplay(true); return true
    end
    function view:CycleCalibrationSection()
        local h=ExportHealer(); if h==nil then return false end
        local current=tonumber(h:GetSuiteSetting("raidCalibrationSection")) or 1
        h:SetSuiteSetting("raidCalibrationSection",current%4+1); self:RefreshDisplay(true); return true
    end
    function view:ToggleCalibration()
        local h=ExportHealer(); if h==nil or type(h.SetSuiteCalibrationMode)~="function" then return false end
        local current=type(h.GetSuiteCalibrationMode)=="function" and h:GetSuiteCalibrationMode()==true
        local ok,err=h:SetSuiteCalibrationMode(not current); if ok~=true and err then SafeChat(tostring(err)) end
        self:RefreshDisplay(true); return ok==true
    end
    function view:AdjustCalibration(field,delta)
        local h=ExportHealer(); if h and type(h.AdjustSuiteCalibration)=="function" then local ok,err=h:AdjustSuiteCalibration(field,delta); if ok~=true and err then SafeChat(tostring(err)) end end
        self:RefreshDisplay(true); return true
    end
    function view:CalibrationCommand(command)
        local h=ExportHealer(); if h==nil then return false end
        local ok,err=false,nil
        if command=="center" and type(h.CenterSuiteCalibration)=="function" then ok,err=h:CenterSuiteCalibration()
        elseif command=="reset" and type(h.ResetSuiteCalibration)=="function" then ok,err=h:ResetSuiteCalibration(false) end
        if ok~=true and err then SafeChat(tostring(err)) end
        self:RefreshDisplay(true); return ok==true
    end
    function view:RefreshDisplay(force)
        local h=ExportHealer(); if h==nil then return false end
        if self.displayForm and type(self.displayForm.Render)=="function" then self.displayForm:Render() end
        local cal=type(h.GetSuiteCalibration)=="function" and h:GetSuiteCalibration() or {}
        local scopes={"两团","仅1团","仅2团"}; local sections={"1团上半","1团下半","2团上半","2团下半"}
        local scope=math.max(1,math.min(3,math.floor(tonumber(cal.scope) or 1))); local section=math.max(1,math.min(4,math.floor(tonumber(cal.section) or 1)))
        local rect=type(cal.rect)=="table" and cal.rect or {}
        self.calScope:SetText("范围："..scopes[scope]); self.calSection:SetText("区域："..sections[section]); self.calMode:SetText(cal.enabled==true and "结束校准" or "开始校准"); self.calMode:SetSelected(cal.enabled==true)
        self.calSummary:SetText(string.format("位置校准 · %s / %s · X %.0f Y %.0f · %.0f×%.0f",
            scopes[scope],sections[section],tonumber(rect.x) or 0,tonumber(rect.y) or 0,tonumber(rect.width) or 0,tonumber(rect.height) or 0))
        self.calSummary:SetTone(cal.enabled==true and "yellow" or "muted")
        return true
    end

    function view:Refresh(force)
        local h=ExportHealer()
        if h==nil then self.summary:SetText("治疗辅助 Domain 尚未初始化"); self.summary:SetTone("red"); return false end
        local revisions=type(h.GetWorkspaceRevisions)=="function" and h:GetWorkspaceRevisions() or {}
        local enabled=revisions.runtimeEnabled==true
        self.summary:SetTone(enabled and (revisions.rosterReady and "green" or "yellow") or "muted")
        self.summary:SetText("Roster "..tostring(revisions.rosterMode or "none").." "..tostring(revisions.rosterCount or 0)
            .." 人 · 推荐 "..tostring(revisions.recommendationCount or 0).." · HealthGen "..tostring(revisions.health or 0)
            .." · StatusGen "..tostring(revisions.status or 0)..(revisions.rosterReady and "" or " · Roster 正在重建"))
        if self.subview=="recommend" then self:RefreshRecommendations(force,revisions)
        elseif self.subview=="score" then if self.scoreForm and type(self.scoreForm.Render)=="function" then self.scoreForm:Render() end
        elseif self.subview=="buffs" then self:RefreshBuffs(force)
        elseif self.subview=="roles" then self:RefreshRoles(force)
        elseif self.subview=="display" then self:RefreshDisplay(force) end
        return true
    end

    view:SetBuffMode("groups")
    view:SetSubview("recommend")
    return view
end

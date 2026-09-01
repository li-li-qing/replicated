------------------------------------------------------------------------
-- Replicated Suite - DPS Combat Workspace (M5 v2)
--
-- Deep RSUI migration for Replicated DPS.
--
-- Authority / Proxy boundary:
--   * This file is presentation-only.  It never reads X2 combat APIs directly.
--   * Ranking and detail data come from ReplicatedDps.Stats / UI read bridges.
--   * Identity edits delegate to ReplicatedDps.Entities / Rules through UIX.
--   * Boss/exclusion actions delegate to ReplicatedDps.Analysis through UIX.
--   * No persistence is duplicated here.
--
-- Performance notes:
--   * Ranking uses the existing bounded ranking cache (<= configured rows).
--   * Ability/target maps use the DPS UI facade's incremental detail-sort job.
--   * Persistent rules are re-sorted only when rules.revision changes.
--   * Hidden subviews do not refresh their data on the 500 ms workspace timer.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI = S.RSUI
if type(RSUI) ~= "table" then return end

S.CombatDpsWorkspace = S.CombatDpsWorkspace or {}
local WD = S.CombatDpsWorkspace

local function ExportDps()
    local sandbox = ReplicatedSuiteModuleSandbox
    local value = sandbox ~= nil and sandbox:GetExport("dps", "ReplicatedDps") or nil
    if value == nil then value = rawget(_G, "ReplicatedDps") end
    return value
end

local function CompactNumber(value)
    local n = tonumber(value) or 0
    local abs = math.abs(n)
    local suffix, divisor = "", 1
    if abs >= 1000000000 then suffix, divisor = "b", 1000000000
    elseif abs >= 1000000 then suffix, divisor = "m", 1000000
    elseif abs >= 1000 then suffix, divisor = "k", 1000 end
    if divisor == 1 then return tostring(math.floor(n + (n >= 0 and 0.5 or -0.5))) end
    local scaled = n / divisor
    if math.abs(scaled) >= 100 then return string.format("%.0f%s", scaled, suffix) end
    if math.abs(scaled) >= 10 then return string.format("%.1f%s", scaled, suffix) end
    return string.format("%.2f%s", scaled, suffix)
end

local function PageLabel(page)
    if page == "TAKEN" then return "承伤" end
    if page == "HEAL" then return "治疗" end
    return "伤害"
end

local function NextPage(page)
    if page == "DAMAGE" then return "TAKEN" end
    if page == "TAKEN" then return "HEAL" end
    return "DAMAGE"
end

local function SafeChat(text)
    if S.SafeChat ~= nil then S.SafeChat(tostring(text or "")) end
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

local function DecisionText(rule)
    if type(rule) ~= "table" then return "--" end
    local parts = {}
    local kind = tostring(rule.kind or "")
    if kind == "PLAYER" then parts[#parts + 1] = "玩家"
    elseif kind == "NPC" then parts[#parts + 1] = "NPC"
    elseif kind == "MATE" then parts[#parts + 1] = "召唤"
    elseif kind == "SLAVE" then parts[#parts + 1] = "从属"
    elseif kind == "OTHER" then parts[#parts + 1] = "其它" end
    local relation = tostring(rule.relation or "")
    if relation == "FRIENDLY" then parts[#parts + 1] = "友军"
    elseif relation == "OPPONENT" then parts[#parts + 1] = "敌军"
    elseif relation == "NEUTRAL" then parts[#parts + 1] = "中立" end
    if rule.ignored == true then parts[#parts + 1] = "忽略" end
    return #parts > 0 and table.concat(parts, "/") or "无分类"
end

function WD:Build(workspace, parent)
    local view = {
        subview = "ranking",
        side = "friendly",
        rankingRows = {},
        rankingCount = 0,
        rankingRevision = 0,
        selectedContext = nil,
        selectedKey = nil,
        detailEntries = {},
        detailTotal = 0,
        detailKey = nil,
        targetName = nil,
        targetCorrectionContext = nil,
        ruleRows = {},
        ruleRevision = -1,
        selectedRuleId = nil,
        ruleDeleteArmedId = nil,
        ruleDeleteArmedAt = 0,
        ruleClearArmedAt = 0,
    }

    view.component = RSUI:Border({
        id = "combat_dps_v2_root", parent = parent,
        width = 100, height = 100, padding = 6, variant = "soft", gradient = false,
    })
    view.root = view.component and view.component.root or nil
    if view.root == nil then return nil end
    if view.root.rsBorder and view.root.rsBorder.SetVisible then view.root.rsBorder:SetVisible(false) end
    if view.root.rsBackground and view.root.rsBackground.SetVisible then view.root.rsBackground:SetVisible(false) end
    view.stack = RSUI:VerticalBox({ id = "combat_dps_v2_stack", parent = view.component, gap = 5 })

    ------------------------------------------------------------------------
    -- Main toolbar
    ------------------------------------------------------------------------
    view.toolbar = RSUI:HorizontalBox({
        id = "combat_dps_v2_toolbar", parent = view.stack, gap = 4,
        slot = { size = "fixed", height = 28, hAlign = "fill" },
    })
    view.modeButton = ActionButton(view.toolbar, "combat_dps_v2_mode", "模式：PVP", 76, function()
        local d = ExportDps()
        if d and d.State and d.State.config and d.UI and type(d.UI.SetMode) == "function" then
            d.UI:SetMode(d.State.config.currentMode == "PVP" and "PVE" or "PVP")
        end
        view:ClearSelection()
        view:SetSubview("ranking")
        return true
    end)
    view.pageButton = ActionButton(view.toolbar, "combat_dps_v2_page", "页面：伤害", 86, function()
        local d = ExportDps()
        if d and d.State and d.State.config and d.UI and type(d.UI.SetPage) == "function" then
            d.UI:SetPage(NextPage(tostring(d.State.config.currentPage or "DAMAGE")))
        end
        view:ClearSelection()
        view:SetSubview("ranking")
        return true
    end)
    view.sideButton = ActionButton(view.toolbar, "combat_dps_v2_side", "阵营：友军", 80, function()
        view.side = view.side == "friendly" and "enemy" or "friendly"
        view:ClearSelection()
        view:SetSubview("ranking")
        return true
    end)
    view.hudButton = ActionButton(view.toolbar, "combat_dps_v2_hud", "当前HUD", 68, function()
        local hudId = view.side == "friendly" and "dps_friendly" or "dps_enemy"
        if S.HudManager and S.HudManager:Get(hudId) then S.HudManager:ToggleVisible(hudId) end
        return true
    end)
    view.bossButton = ActionButton(view.toolbar, "combat_dps_v2_boss_current", "当前目标Boss", 84, function()
        local d = ExportDps()
        if d and d.UI and type(d.UI.ToggleCurrentTargetBoss) == "function" then d.UI:ToggleCurrentTargetBoss() end
        view:Refresh(true)
        return true
    end)
    view.clearButton = ActionButton(view.toolbar, "combat_dps_v2_clear", "清空 / 恢复", 82, function()
        local d = ExportDps()
        if d and d.UI and type(d.UI.ShowClearConfirmation) == "function" then d.UI:ShowClearConfirmation() end
        return true
    end)
    view.settingsButton = ActionButton(view.toolbar, "combat_dps_v2_settings", "高级设置", 64, function()
        workspace:SetMode("settings")
        return true
    end, true)

    ------------------------------------------------------------------------
    -- Subview tabs
    ------------------------------------------------------------------------
    view.tabs = RSUI:HorizontalBox({
        id = "combat_dps_v2_tabs", parent = view.stack, gap = 4,
        slot = { size = "fixed", height = 28, hAlign = "fill" },
    })
    view.tabRanking = ActionButton(view.tabs, "combat_dps_v2_tab_ranking", "排行榜", 72, function() view:SetSubview("ranking"); return true end)
    view.tabAbility = ActionButton(view.tabs, "combat_dps_v2_tab_ability", "技能详情", 76, function() view:SetSubview("ability"); return true end)
    view.tabCounterpart = ActionButton(view.tabs, "combat_dps_v2_tab_counterpart", "目标 / 来源", 82, function() view:SetSubview("counterpart"); return true end)
    view.tabRules = ActionButton(view.tabs, "combat_dps_v2_tab_rules", "名单 / 纠错", 82, function() view:SetSubview("rules"); return true end)
    view.tabSpacer = RSUI:Text({
        id = "combat_dps_v2_tabs_hint", parent = view.tabs,
        text = "排行榜选择单位后，可直接在新工作区查看技能/目标并人工纠错。", tone = "muted", fontSize = 8, overflow = "ellipsis",
        slot = { size = "fill", fill = 1, minWidth = 80, hAlign = "fill", vAlign = "center" },
    })

    view.summary = RSUI:Text({
        id = "combat_dps_v2_summary", parent = view.stack,
        text = "DPS：--", tone = "muted", fontSize = 9, overflow = "ellipsis",
        slot = { size = "fixed", height = 20, hAlign = "fill" },
    })

    view.switcher = RSUI:WidgetSwitcher({
        id = "combat_dps_v2_switcher", parent = view.stack, activeIndex = 1,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })

    ------------------------------------------------------------------------
    -- 1. Ranking + identity inspector
    ------------------------------------------------------------------------
    view.rankingPage = RSUI:HorizontalBox({
        id = "combat_dps_v2_ranking_page", parent = view.switcher, gap = 6,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })
    local rankingColumns = {
        { id = "rank", title = "#", width = 36, minWidth = 30, absoluteMinWidth = 24, field = "rank" },
        { id = "name", title = "玩家 / 单位", size = "fill", minWidth = 118, absoluteMinWidth = 58, field = "name" },
        { id = "value", title = "累计", width = 76, minWidth = 60, absoluteMinWidth = 44, field = "valueText" },
        { id = "rate", title = "每秒", width = 68, minWidth = 54, absoluteMinWidth = 40, field = "rateText", tone = "muted" },
        { id = "percent", title = "占比", width = 56, minWidth = 46, absoluteMinWidth = 34, field = "percentText" },
    }
    view.rankingTable = RSUI:TableView({
        id = "combat_dps_v2_ranking_table", parent = view.rankingPage,
        columns = rankingColumns, rowHeight = 22, headerHeight = 22, columnGap = 3,
        getCount = function() return view.rankingCount end,
        getItem = function(index) return view.rankingRows[index] end,
        getKey = function(row, index) return row and row.key or index end,
        overscan = 2, maxPoolSize = 30, selectable = true, selectionMode = "single",
        rowFactory = function(list, poolIndex, tableView)
            return CreateSelectableRow("combat_dps_v2_rank", list, poolIndex, tableView, function(row, rightClick)
                if row == nil then return end
                view:SelectRankingRow(row)
                if rightClick then view:SetSubview("ability") end
            end)
        end,
        onSelectionChanged = function(index)
            local row = index and view.rankingRows[index] or nil
            if row ~= nil then view:SelectRankingRow(row) end
        end,
        slot = { size = "fill", fill = 1, minWidth = 260, hAlign = "fill", vAlign = "fill" },
    })

    view.inspector = RSUI:Border({
        id = "combat_dps_v2_inspector", parent = view.rankingPage,
        width = 258, padding = 7, variant = "card", gradient = true, accentStrip = 2,
        slot = { size = "fixed", width = 258, hAlign = "fill", vAlign = "fill" },
    })
    view.inspectorStack = RSUI:VerticalBox({ id = "combat_dps_v2_inspector_stack", parent = view.inspector, gap = 4 })
    view.selectedTitle = RSUI:Text({
        id = "combat_dps_v2_selected_title", parent = view.inspectorStack,
        text = "未选择单位", tone = "accent", fontSize = 11, overflow = "ellipsis",
        slot = { size = "fixed", height = 22, hAlign = "fill" },
    })
    view.identityText = RSUI:Text({
        id = "combat_dps_v2_identity", parent = view.inspectorStack,
        text = "从左侧排行榜选择单位。", tone = "muted", fontSize = 8, overflow = "wrap", maxLines = 3,
        slot = { size = "fixed", height = 48, hAlign = "fill" },
    })
    view.scoreText = RSUI:Text({
        id = "combat_dps_v2_scores", parent = view.inspectorStack,
        text = "身份证据：--", tone = "muted", fontSize = 8, overflow = "ellipsis",
        slot = { size = "fixed", height = 18, hAlign = "fill" },
    })

    local function InspectorRow(id)
        return RSUI:HorizontalBox({
            id = id, parent = view.inspectorStack, gap = 3,
            slot = { size = "fixed", height = 26, hAlign = "fill" },
        })
    end
    view.relationRow = InspectorRow("combat_dps_v2_relation_row")
    view.friendButton = ActionButton(view.relationRow, "combat_dps_v2_friend", "友军", 52, function() view:Manual(nil, "FRIENDLY", nil); return true end, true)
    view.enemyButton = ActionButton(view.relationRow, "combat_dps_v2_enemy", "敌军", 52, function() view:Manual(nil, "OPPONENT", nil); return true end, true)
    view.neutralButton = ActionButton(view.relationRow, "combat_dps_v2_neutral", "中立", 52, function() view:Manual(nil, "NEUTRAL", nil); return true end, true)

    view.kindRow = InspectorRow("combat_dps_v2_kind_row")
    view.playerButton = ActionButton(view.kindRow, "combat_dps_v2_player", "玩家", 46, function() view:Manual("PLAYER", nil, nil); return true end, true)
    view.npcButton = ActionButton(view.kindRow, "combat_dps_v2_npc", "NPC", 46, function() view:Manual("NPC", nil, nil); return true end, true)
    view.mateButton = ActionButton(view.kindRow, "combat_dps_v2_mate", "召唤", 46, function() view:Manual("MATE", nil, nil); return true end, true)
    view.otherButton = ActionButton(view.kindRow, "combat_dps_v2_other", "其它", 46, function() view:Manual("OTHER", nil, nil); return true end, true)

    view.manualRow = InspectorRow("combat_dps_v2_manual_row")
    view.ignoreButton = ActionButton(view.manualRow, "combat_dps_v2_ignore", "本次忽略", 74, function()
        local d = ExportDps()
        if d and d.UI and type(d.UI.ToggleWorkspaceIgnore) == "function" and view.selectedContext ~= nil then
            local ok, err = d.UI:ToggleWorkspaceIgnore(view.selectedContext)
            if ok ~= true then SafeChat("忽略切换失败：" .. tostring(err or "未知错误")) end
        end
        view:RefreshSelectedInspector(true)
        return true
    end, true)
    view.autoButton = ActionButton(view.manualRow, "combat_dps_v2_auto", "恢复自动", 74, function()
        local d = ExportDps()
        if d and d.UI and type(d.UI.ClearWorkspaceManual) == "function" and view.selectedContext ~= nil then
            local ok, err = d.UI:ClearWorkspaceManual(view.selectedContext)
            if ok ~= true then SafeChat(tostring(err or "恢复自动判断失败")) end
        end
        view:RefreshSelectedInspector(true)
        return true
    end, true)

    view.ruleActionRow = InspectorRow("combat_dps_v2_rule_action_row")
    view.saveRuleButton = ActionButton(view.ruleActionRow, "combat_dps_v2_save_rule", "保存到名单", 82, function()
        local d = ExportDps()
        if d and d.UI and type(d.UI.SaveWorkspaceRule) == "function" and view.selectedContext ~= nil then
            local rule, err = d.UI:SaveWorkspaceRule(view.selectedContext)
            if rule == nil then SafeChat("保存名单失败：" .. tostring(err or "未知错误")) end
        end
        view:RefreshSelectedInspector(true)
        return true
    end, true)
    view.removeRuleButton = ActionButton(view.ruleActionRow, "combat_dps_v2_remove_rule", "移除名单", 78, function()
        local d = ExportDps()
        if d and d.UI and type(d.UI.RemoveWorkspaceRule) == "function" and view.selectedContext ~= nil then
            local ok, err = d.UI:RemoveWorkspaceRule(view.selectedContext)
            if ok ~= true then SafeChat(tostring(err or "移除名单失败")) end
        end
        view:RefreshSelectedInspector(true)
        return true
    end, true)

    view.inspectorHint = RSUI:Text({
        id = "combat_dps_v2_inspector_hint", parent = view.inspectorStack,
        text = "人工纠错只修改 DPS Authority；统计重分类由 Runtime 在安全时机执行。", tone = "muted", fontSize = 8, overflow = "wrap", maxLines = 3,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "top" },
    })

    ------------------------------------------------------------------------
    -- 2/3. Ability / counterpart detail views
    ------------------------------------------------------------------------
    local function CreateDetailPage(id, counterpart)
        local page = RSUI:VerticalBox({
            id = id, parent = view.switcher, gap = 5,
            slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
        })
        local state = RSUI:Text({
            id = id .. "_state", parent = page,
            text = "请先从排行榜选择单位。", tone = "muted", fontSize = 9, overflow = "ellipsis",
            slot = { size = "fixed", height = 20, hAlign = "fill" },
        })
        local columns = {
            { id = "name", title = counterpart and "目标 / 来源" or "技能", size = "fill", minWidth = 160, absoluteMinWidth = 72,
                getText = function(row) return tostring(row and (row.displayName or row.name) or "未知") end },
            { id = "value", title = "累计", width = 92, minWidth = 68, absoluteMinWidth = 48,
                getText = function(row) return CompactNumber(row and row.value or 0) end },
            { id = "percent", title = "占比", width = 68, minWidth = 50, absoluteMinWidth = 38,
                getText = function(row)
                    local total = math.max(0, tonumber(view.detailTotal) or 0)
                    local value = math.max(0, tonumber(row and row.value) or 0)
                    return string.format("%.1f%%", total > 0 and value / total * 100 or 0)
                end },
        }
        if counterpart then
            columns[#columns + 1] = {
                id = "analysis", title = "分析", width = 92, minWidth = 66, absoluteMinWidth = 44,
                getText = function(row)
                    local d = ExportDps()
                    local name = tostring(row and (row.displayName or row.name) or "")
                    if d and d.Analysis and name ~= "" then
                        if d.Analysis:IsBoss(name) then return "Boss统计" end
                        if d.Analysis:IsExcluded(name) then return "已排除" end
                    end
                    return "--"
                end,
                getTone = function(row)
                    local d = ExportDps()
                    local name = tostring(row and (row.displayName or row.name) or "")
                    if d and d.Analysis and name ~= "" then
                        if d.Analysis:IsBoss(name) then return "yellow" end
                        if d.Analysis:IsExcluded(name) then return "red" end
                    end
                    return "muted"
                end,
            }
        end
        local tableView = RSUI:TableView({
            id = id .. "_table", parent = page,
            columns = columns, rowHeight = 23, headerHeight = 22, columnGap = 3,
            getCount = function() return #view.detailEntries end,
            getItem = function(index) return view.detailEntries[index] end,
            getKey = function(row, index) return tostring(row and (row.displayName or row.name) or index) .. ":" .. tostring(index) end,
            overscan = 2, maxPoolSize = 30, selectable = counterpart == true, selectionMode = "single",
            rowFactory = counterpart and function(list, poolIndex, tv)
                return CreateSelectableRow("combat_dps_v2_counterpart", list, poolIndex, tv, function(row)
                    view:SelectCounterpart(row)
                end)
            end or nil,
            onSelectionChanged = counterpart and function(index)
                local row = index and view.detailEntries[index] or nil
                if row ~= nil then view:SelectCounterpart(row) end
            end or nil,
            slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
        })
        return page, state, tableView
    end

    view.abilityPage, view.abilityState, view.abilityTable = CreateDetailPage("combat_dps_v2_ability_page", false)
    view.counterpartPage, view.counterpartState, view.counterpartTable = CreateDetailPage("combat_dps_v2_counterpart_page", true)
    view.counterpartActions = RSUI:HorizontalBox({
        id = "combat_dps_v2_counterpart_actions", parent = view.counterpartPage, gap = 4,
        slot = { size = "fixed", height = 28, hAlign = "fill" },
    })
    view.targetBossButton = ActionButton(view.counterpartActions, "combat_dps_v2_target_boss", "设为 Boss", 82, function()
        local d = ExportDps()
        if d and d.UI and type(d.UI.ToggleBossTarget) == "function" and view.targetName ~= nil then
            d.UI:ToggleBossTarget(view.targetName, view.targetCorrectionContext and view.targetCorrectionContext.entityRef)
        end
        view:RefreshDetail("COUNTERPART", true)
        return true
    end)
    view.targetExcludeButton = ActionButton(view.counterpartActions, "combat_dps_v2_target_exclude", "排除目标", 82, function()
        local d = ExportDps()
        if d and d.UI and type(d.UI.ToggleExcludedTarget) == "function" and view.targetName ~= nil then
            d.UI:ToggleExcludedTarget(view.targetName)
        end
        view:RefreshDetail("COUNTERPART", true)
        return true
    end)
    view.targetFriendlyButton = ActionButton(view.counterpartActions, "combat_dps_v2_target_friend", "纠错友军", 76, function()
        view:ManualTarget(nil, "FRIENDLY", nil)
        return true
    end)
    view.targetEnemyButton = ActionButton(view.counterpartActions, "combat_dps_v2_target_enemy", "纠错敌军", 76, function()
        view:ManualTarget(nil, "OPPONENT", nil)
        return true
    end)
    view.targetSaveButton = ActionButton(view.counterpartActions, "combat_dps_v2_target_save", "保存名单", 72, function()
        local d = ExportDps()
        if d and d.UI and type(d.UI.SaveWorkspaceRule) == "function" and view.targetCorrectionContext ~= nil then
            local rule, err = d.UI:SaveWorkspaceRule(view.targetCorrectionContext)
            if rule == nil then SafeChat("保存目标名单失败：" .. tostring(err or "未知错误")) end
        end
        view:RefreshTargetActions()
        return true
    end, true)

    ------------------------------------------------------------------------
    -- 4. Persistent rules manager
    ------------------------------------------------------------------------
    view.rulesPage = RSUI:VerticalBox({
        id = "combat_dps_v2_rules_page", parent = view.switcher, gap = 5,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })
    view.rulesActions = RSUI:HorizontalBox({
        id = "combat_dps_v2_rules_actions", parent = view.rulesPage, gap = 4,
        slot = { size = "fixed", height = 28, hAlign = "fill" },
    })
    view.ruleToggleButton = ActionButton(view.rulesActions, "combat_dps_v2_rule_toggle", "启用 / 禁用", 86, function() view:ToggleRule(); return true end)
    view.ruleDeleteButton = ActionButton(view.rulesActions, "combat_dps_v2_rule_delete", "删除选中", 76, function() view:DeleteRule(); return true end)
    view.ruleRestoreIgnoreButton = ActionButton(view.rulesActions, "combat_dps_v2_rule_restore_ignore", "恢复本次忽略", 96, function()
        local d = ExportDps()
        if d and d.Entities and type(d.Entities.ClearSessionIgnores) == "function" then
            local count = d.Entities:ClearSessionIgnores()
            SafeChat("已恢复本次运行忽略：" .. tostring(count or 0) .. " 个")
            if d.UI and type(d.UI.RefreshQuickWindows) == "function" then d.UI:RefreshQuickWindows() end
        end
        view:RefreshRules(true)
        return true
    end)
    view.ruleClearButton = ActionButton(view.rulesActions, "combat_dps_v2_rule_clear", "清空全部名单", 92, function() view:ClearRules(); return true end)
    view.rulesHint = RSUI:Text({
        id = "combat_dps_v2_rules_hint", parent = view.rulesActions,
        text = "ID 规则优先；名称规则遇同名冲突由 DPS Authority 暂停。", tone = "muted", fontSize = 8, overflow = "ellipsis",
        slot = { size = "fill", fill = 1, minWidth = 80, hAlign = "fill", vAlign = "center" },
    })
    local ruleColumns = {
        { id = "enabled", title = "状态", width = 58, minWidth = 48, absoluteMinWidth = 38, field = "enabledText", getTone = function(row) return row and row.enabledTone or "muted" end },
        { id = "name", title = "单位", size = "fill", minWidth = 130, absoluteMinWidth = 62, field = "name" },
        { id = "match", title = "匹配", width = 70, minWidth = 54, absoluteMinWidth = 40, field = "match" },
        { id = "decision", title = "人工裁决", width = 118, minWidth = 82, absoluteMinWidth = 54, field = "decision" },
        { id = "id", title = "规则ID", width = 76, minWidth = 60, absoluteMinWidth = 44, field = "ruleId", tone = "muted" },
    }
    view.rulesTable = RSUI:TableView({
        id = "combat_dps_v2_rules_table", parent = view.rulesPage,
        columns = ruleColumns, rowHeight = 23, headerHeight = 22, columnGap = 3,
        items = view.ruleRows, overscan = 2, maxPoolSize = 30, selectable = true, selectionMode = "single",
        rowFactory = function(list, poolIndex, tableView)
            return CreateSelectableRow("combat_dps_v2_rule", list, poolIndex, tableView, function(row)
                view.selectedRuleId = row and row.ruleId or nil
                view:RefreshRuleActionState()
            end)
        end,
        onSelectionChanged = function(index)
            local row = index and view.ruleRows[index] or nil
            view.selectedRuleId = row and row.ruleId or nil
            view:RefreshRuleActionState()
        end,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })

    ------------------------------------------------------------------------
    -- Methods
    ------------------------------------------------------------------------
    function view:ClearSelection()
        self.selectedContext, self.selectedKey = nil, nil
        self.targetName, self.targetCorrectionContext = nil, nil
        self.detailEntries, self.detailTotal, self.detailKey = {}, 0, nil
        if self.rankingTable and type(self.rankingTable.ClearSelection) == "function" then self.rankingTable:ClearSelection() end
        self:RefreshSelectedInspector(true)
    end

    function view:SetSubview(name)
        local indexMap = { ranking = 1, ability = 2, counterpart = 3, rules = 4 }
        name = indexMap[name] and name or "ranking"
        self.subview = name
        self.switcher:SetActiveIndex(indexMap[name])
        self.tabRanking:SetSelected(name == "ranking")
        self.tabAbility:SetSelected(name == "ability")
        self.tabCounterpart:SetSelected(name == "counterpart")
        self.tabRules:SetSelected(name == "rules")
        self:Refresh(true)
        return true
    end

    function view:SelectRankingRow(row)
        local d = ExportDps()
        if d == nil or d.State == nil or d.State.config == nil or row == nil then return false end
        self.selectedKey = row.key
        self.selectedContext = {
            mode = tostring(d.State.config.currentMode or "PVP"),
            page = tostring(d.State.config.currentPage or "DAMAGE"),
            side = self.side,
            key = row.key,
            projectionKey = row.key,
            name = row.rawName or row.name,
            actor = row.source and row.source.actor or nil,
        }
        self.targetName, self.targetCorrectionContext = nil, nil
        self.detailEntries, self.detailTotal, self.detailKey = {}, 0, nil
        self:RefreshSelectedInspector(true)
        return true
    end

    function view:Manual(kind, relation, ignored)
        local d = ExportDps()
        if d == nil or d.UI == nil or type(d.UI.ApplyWorkspaceManual) ~= "function" or self.selectedContext == nil then return false end
        local ok, err = d.UI:ApplyWorkspaceManual(self.selectedContext, kind, relation, ignored)
        if ok ~= true then SafeChat("人工纠错失败：" .. tostring(err or "未知错误")) end
        self:RefreshSelectedInspector(true)
        return ok == true
    end

    function view:RefreshSelectedInspector()
        local d = ExportDps()
        local snapshot = d and d.UI and type(d.UI.GetWorkspaceIdentitySnapshot) == "function"
            and d.UI:GetWorkspaceIdentitySnapshot(self.selectedContext) or nil
        if type(snapshot) ~= "table" or snapshot.available ~= true then
            self.selectedTitle:SetText(self.selectedContext and tostring(self.selectedContext.name or "单位已变化") or "未选择单位")
            self.identityText:SetText(snapshot and tostring(snapshot.reason or "单位当前不可纠错") or "从左侧排行榜选择单位。")
            self.scoreText:SetText("身份 Authority：--")
            for _, button in ipairs({ self.friendButton, self.enemyButton, self.neutralButton, self.playerButton,
                self.npcButton, self.mateButton, self.otherButton, self.ignoreButton, self.autoButton,
                self.saveRuleButton, self.removeRuleButton }) do button:SetEnabled(false) end
            return false
        end
        self.selectedContext = snapshot.context or self.selectedContext
        self.selectedTitle:SetText(tostring(snapshot.name or "未知"))
        local idText = snapshot.stableId and ("ID " .. tostring(snapshot.stableId)) or "无稳定ID"
        local conflict = snapshot.nameConflict and " · 同名冲突" or ""
        local saved = snapshot.savedRuleId and (" · 名单 " .. tostring(snapshot.savedRuleId)) or ""
        self.identityText:SetText(string.format("%s / %s · %s\n%s%s%s",
            tostring(snapshot.kindText or "未知"), tostring(snapshot.relationText or "未知"), tostring(snapshot.manualText or "自动判断"),
            idText, conflict, saved))
        self.scoreText:SetText(string.format("关系证据：友 %.0f / 敌 %.0f · 永久匹配 %s",
            tonumber(snapshot.friendlyScore) or 0, tonumber(snapshot.opponentScore) or 0,
            tostring(snapshot.matchMode == "ID" and "ID" or "名称")))
        local editable = snapshot.canEdit == true
        for _, button in ipairs({ self.friendButton, self.enemyButton, self.neutralButton,
            self.playerButton, self.npcButton, self.mateButton, self.otherButton }) do button:SetEnabled(editable) end
        self.ignoreButton:SetEnabled(snapshot.canToggleIgnore == true)
        self.autoButton:SetEnabled(snapshot.canClearManual == true)
        self.saveRuleButton:SetEnabled(snapshot.canSaveRule == true)
        self.removeRuleButton:SetEnabled(snapshot.canRemoveRule == true)
        self.friendButton:SetSelected(snapshot.relation == "FRIENDLY")
        self.enemyButton:SetSelected(snapshot.relation == "OPPONENT")
        self.neutralButton:SetSelected(snapshot.relation == "NEUTRAL")
        self.playerButton:SetSelected(snapshot.kind == "PLAYER")
        self.npcButton:SetSelected(snapshot.kind == "NPC")
        self.mateButton:SetSelected(snapshot.kind == "MATE" or snapshot.kind == "SLAVE")
        self.otherButton:SetSelected(snapshot.kind == "OTHER")
        self.ignoreButton:SetSelected(snapshot.ignored == true)
        self.ignoreButton:SetText(snapshot.ignored == true and "恢复计入" or "本次忽略")
        return true
    end

    function view:RefreshRanking()
        local d = ExportDps()
        if d == nil or d.State == nil or d.State.config == nil or d.Stats == nil or type(d.Stats.BuildRanking) ~= "function" then
            self.rankingCount = 0
            self.summary:SetText("DPS Domain 尚未初始化")
            self.summary:SetTone("red")
            self.rankingTable:RefreshVisible("dpsv2:unavailable", true)
            return false
        end
        local mode = tostring(d.State.config.currentMode or "PVP")
        local page = tostring(d.State.config.currentPage or "DAMAGE")
        if page ~= "DAMAGE" and page ~= "TAKEN" and page ~= "HEAL" then page = "DAMAGE" end
        self.modeButton:SetText("模式：" .. mode)
        self.pageButton:SetText("页面：" .. PageLabel(page))
        self.sideButton:SetText("阵营：" .. (self.side == "friendly" and "友军" or "敌军"))

        local ok, ranking, total, _, _, analysisView = xpcall(function()
            return d.Stats:BuildRanking(mode, self.side, page)
        end, S.SafeTraceback)
        if not ok then
            self.summary:SetText("排行榜读取失败：" .. tostring(ranking))
            self.summary:SetTone("red")
            return false
        end
        ranking = type(ranking) == "table" and ranking or {}
        local limit = math.min(#ranking, math.max(1, math.floor(tonumber(d.State.config.displayRows) or 100)))
        local duplicateCounts = {}
        local normalize = d.Util and d.Util.NormalizeName
        for _, item in ipairs(ranking) do
            local normalized = type(normalize) == "function" and normalize(item and item.name) or tostring(item and item.name or "")
            if normalized ~= "" then duplicateCounts[normalized] = (duplicateCounts[normalized] or 0) + 1 end
        end
        local pinnedSelf = nil
        local pinnedRank = nil
        if self.side == "friendly" and d.State.config.alwaysShowSelf == true and d.Identity ~= nil then
            local selfKey = tostring(d.Identity.entityKey or "")
            local playerName = type(normalize) == "function" and normalize(d.Identity.playerName) or tostring(d.Identity.playerName or "")
            local playerWorld = type(normalize) == "function" and normalize(d.Identity.playerNameWithWorld) or tostring(d.Identity.playerNameWithWorld or "")
            for index, item in ipairs(ranking) do
                local normalized = type(normalize) == "function" and normalize(item and item.name) or tostring(item and item.name or "")
                if tostring(item and item.key or "") == selfKey or (normalized ~= "" and (normalized == playerName or normalized == playerWorld)) then
                    if index > limit then pinnedSelf, pinnedRank = item, index end
                    break
                end
            end
        end

        local oldCount = self.rankingCount
        local outIndex = 0
        local function AddItem(item, realRank, pinned)
            if item == nil then return end
            outIndex = outIndex + 1
            local row = self.rankingRows[outIndex] or {}
            local normalized = type(normalize) == "function" and normalize(item.name) or tostring(item.name or "")
            local displayName = tostring(item.name or "未知")
            if (duplicateCounts[normalized] or 0) > 1 then displayName = displayName .. " [同名]" end
            if pinned == true then displayName = "[自己] " .. displayName end
            row.rank = tostring(realRank)
            row.key = tostring(item.key or realRank)
            row.rawName = tostring(item.name or "未知")
            row.name = displayName
            row.valueText = CompactNumber(item.value)
            row.rateText = CompactNumber(item.rate)
            row.percentText = string.format("%.1f%%", tonumber(item.percent) or 0)
            row.source = item
            self.rankingRows[outIndex] = row
        end
        if pinnedSelf ~= nil then AddItem(pinnedSelf, pinnedRank, true) end
        for index = 1, limit do
            local item = ranking[index]
            if pinnedSelf == nil or item ~= pinnedSelf then AddItem(item, index, false) end
        end
        for index = outIndex + 1, oldCount do self.rankingRows[index] = nil end
        self.rankingCount = outIndex
        self.rankingRevision = self.rankingRevision + 1
        if oldCount ~= outIndex then
            if self.rankingTable.list and type(self.rankingTable.list.InvalidateMeasure) == "function" then self.rankingTable.list:InvalidateMeasure("dpsv2_count") end
            if type(self.rankingTable.InvalidateMeasure) == "function" then self.rankingTable:InvalidateMeasure("dpsv2_count") end
        end
        self.rankingTable:RefreshVisible("dpsv2:rank:" .. tostring(self.rankingRevision), true)

        if self.selectedKey ~= nil then
            local selected = nil
            for index = 1, self.rankingCount do
                if self.rankingRows[index] and self.rankingRows[index].key == self.selectedKey then selected = self.rankingRows[index]; break end
            end
            if selected ~= nil and self.selectedContext ~= nil then
                self.selectedContext.actor = selected.source and selected.source.actor or self.selectedContext.actor
                self.selectedContext.name = selected.rawName or self.selectedContext.name
                self.selectedContext.mode, self.selectedContext.side, self.selectedContext.page = mode, self.side, page
            end
        end
        self:RefreshSelectedInspector(false)

        local analysis = type(analysisView) == "table" and analysisView.enabled == true
        local cacheCurrent = type(d.Stats.IsRankingCacheCurrent) == "function" and d.Stats:IsRankingCacheCurrent(mode, self.side, page)
        local boss = d.Analysis and type(d.Analysis.GetBossTarget) == "function" and d.Analysis:GetBossTarget() or nil
        local excluded = d.Analysis and type(d.Analysis.GetExcludedCount) == "function" and d.Analysis:GetExcludedCount() or 0
        local analysisText = analysis and (boss and (" · Boss：" .. tostring(boss.name)) or " · 目标分析") or ""
        if tonumber(excluded) and tonumber(excluded) > 0 then analysisText = analysisText .. " · 排除 " .. tostring(excluded) end
        self.summary:SetTone(cacheCurrent and "green" or "yellow")
        self.summary:SetText(string.format("%s · %s · %s · %d 行 · 总计 %s%s",
            mode, self.side == "friendly" and "友军" or "敌军", PageLabel(page), outIndex, CompactNumber(total), analysisText))
        return true
    end

    function view:RefreshDetail(kind, force)
        local d = ExportDps()
        local stateText = kind == "ABILITY" and self.abilityState or self.counterpartState
        local tableView = kind == "ABILITY" and self.abilityTable or self.counterpartTable
        if self.selectedContext == nil or d == nil or d.UI == nil or type(d.UI.GetWorkspaceDetailSnapshot) ~= "function" then
            self.detailEntries, self.detailTotal, self.detailKey = {}, 0, nil
            stateText:SetText("请先从排行榜选择单位。")
            stateText:SetTone("muted")
            tableView:RefreshVisible("dpsv2:detail:none:" .. kind, true)
            if kind == "COUNTERPART" then self:RefreshTargetActions() end
            return false
        end
        local snapshot = d.UI:GetWorkspaceDetailSnapshot(self.selectedContext, kind)
        if type(snapshot) ~= "table" or snapshot.available ~= true then
            self.detailEntries, self.detailTotal = {}, 0
            stateText:SetText(snapshot and tostring(snapshot.reason or "详情当前不可用") or "详情当前不可用")
            stateText:SetTone("yellow")
            tableView:RefreshVisible("dpsv2:detail:unavailable:" .. kind, true)
            if kind == "COUNTERPART" then self:RefreshTargetActions() end
            return false
        end
        if snapshot.building == true then
            self.detailEntries, self.detailTotal = {}, tonumber(snapshot.total) or 0
            stateText:SetText("正在分帧整理详情… 已收集 " .. tostring(snapshot.collected or 0) .. " 条；不会阻塞战斗事件处理。")
            stateText:SetTone("yellow")
            tableView:RefreshVisible("dpsv2:detail:building:" .. tostring(snapshot.key) .. ":" .. tostring(snapshot.collected), true)
            return true
        end
        local changedKey = self.detailKey ~= snapshot.key
        self.detailEntries = type(snapshot.entries) == "table" and snapshot.entries or {}
        self.detailTotal = tonumber(snapshot.total) or 0
        self.detailKey = snapshot.key
        stateText:SetTone("green")
        local selectedName = tostring(self.selectedContext.name or "未知")
        stateText:SetText(selectedName .. " · " .. (kind == "ABILITY" and "技能明细" or (self.selectedContext.page == "TAKEN" and "伤害来源" or "目标明细"))
            .. " · " .. tostring(#self.detailEntries) .. " 条 · 合计 " .. CompactNumber(self.detailTotal))
        tableView:RefreshVisible("dpsv2:detail:" .. tostring(snapshot.key), changedKey or force == true)
        if kind == "COUNTERPART" then self:RefreshTargetActions() end
        return true
    end

    function view:SelectCounterpart(row)
        local name = tostring(row and (row.displayName or row.name) or "")
        if name == "" then return false end
        self.targetName = name
        self.targetCorrectionContext = nil
        local d = ExportDps()
        if d and d.Entities and type(d.Entities.GetCandidatesByName) == "function" then
            local candidates = d.Entities:GetCandidatesByName(name)
            local concrete = {}
            for _, entity in ipairs(type(candidates) == "table" and candidates or {}) do
                if type(entity) == "table" and not (entity.flags and entity.flags.historicalNameAggregate == true) then concrete[#concrete + 1] = entity end
            end
            if #concrete == 1 then
                local entity = concrete[1]
                self.targetCorrectionContext = {
                    mode = self.selectedContext and self.selectedContext.mode,
                    page = self.selectedContext and self.selectedContext.page,
                    side = self.selectedContext and self.selectedContext.side,
                    key = entity.key, projectionKey = entity.key, entityKey = entity.key,
                    name = entity.name, entityRef = entity,
                }
                self.counterpartState:SetText(name .. " · 已解析唯一当前单位，可直接人工纠错。")
                self.counterpartState:SetTone("green")
            elseif #concrete > 1 then
                self.counterpartState:SetText(name .. " · 同名当前单位 " .. tostring(#concrete) .. " 个；为避免误标，人工纠错已禁用。")
                self.counterpartState:SetTone("yellow")
            else
                self.counterpartState:SetText(name .. " · 只有历史名称聚合，保留统计但不扩大人工纠错范围。")
                self.counterpartState:SetTone("muted")
            end
        end
        self:RefreshTargetActions()
        return true
    end

    function view:RefreshTargetActions()
        local d = ExportDps()
        local scopeAllowed = self.selectedContext ~= nil
            and self.selectedContext.mode == "PVE" and self.selectedContext.side == "friendly" and self.selectedContext.page == "DAMAGE"
            and self.targetName ~= nil
        local isBoss = scopeAllowed and d and d.Analysis and d.Analysis:IsBoss(self.targetName) == true
        local excluded = scopeAllowed and d and d.Analysis and d.Analysis:IsExcluded(self.targetName) == true
        self.targetBossButton:SetEnabled(scopeAllowed == true)
        self.targetExcludeButton:SetEnabled(scopeAllowed == true)
        self.targetBossButton:SetSelected(isBoss)
        self.targetExcludeButton:SetSelected(excluded)
        self.targetBossButton:SetText(isBoss and "取消 Boss" or "设为 Boss")
        self.targetExcludeButton:SetText(excluded and "恢复计入" or "排除目标")
        local correction = self.targetCorrectionContext ~= nil
        self.targetFriendlyButton:SetEnabled(correction)
        self.targetEnemyButton:SetEnabled(correction)
        local snapshot = correction and d and d.UI and type(d.UI.GetWorkspaceIdentitySnapshot) == "function"
            and d.UI:GetWorkspaceIdentitySnapshot(self.targetCorrectionContext) or nil
        self.targetSaveButton:SetEnabled(snapshot ~= nil and snapshot.canSaveRule == true)
    end

    function view:ManualTarget(kind, relation, ignored)
        local d = ExportDps()
        if self.targetCorrectionContext == nil then
            SafeChat("该目标存在同名冲突或只有历史聚合，不能直接扩大人工纠错范围。")
            return false
        end
        if d and d.UI and type(d.UI.ApplyWorkspaceManual) == "function" then
            local ok, err = d.UI:ApplyWorkspaceManual(self.targetCorrectionContext, kind, relation, ignored)
            if ok ~= true then SafeChat("目标纠错失败：" .. tostring(err or "未知错误")) end
            self:RefreshTargetActions()
            return ok == true
        end
        return false
    end

    function view:RefreshRuleActionState()
        local d = ExportDps()
        local rule = d and d.Rules and self.selectedRuleId and d.Rules:GetById(self.selectedRuleId) or nil
        self.ruleToggleButton:SetEnabled(rule ~= nil)
        self.ruleDeleteButton:SetEnabled(rule ~= nil)
        self.ruleToggleButton:SetText(rule and (rule.enabled == false and "启用规则" or "禁用规则") or "启用 / 禁用")
        local now = S.NowMs and S.NowMs() or 0
        local armedDelete = rule ~= nil and tostring(self.ruleDeleteArmedId or "") == tostring(rule.ruleId)
            and now - (tonumber(self.ruleDeleteArmedAt) or 0) <= 5000
        self.ruleDeleteButton:SetText(armedDelete and "再次点击删除" or "删除选中")
        local armedClear = now - (tonumber(self.ruleClearArmedAt) or 0) <= 5000
        self.ruleClearButton:SetText(armedClear and "再次点击清空" or "清空全部名单")
    end

    function view:RefreshRules(force)
        local d = ExportDps()
        if d == nil or d.Rules == nil then
            self.ruleRows = {}
            self.rulesTable:SetItems(self.ruleRows, "dpsv2:rules:none")
            self.summary:SetText("DPS 名单 Authority 尚未初始化")
            self.summary:SetTone("red")
            self:RefreshRuleActionState()
            return false
        end
        local revision = tonumber(d.State and d.State.rules and d.State.rules.revision) or 0
        if force == true or revision ~= self.ruleRevision then
            local entries = d.Rules:List()
            local rows = {}
            for index, rule in ipairs(entries) do
                rows[index] = {
                    ruleId = tostring(rule.ruleId or ""),
                    name = tostring(rule.displayName or rule.matchValue or "未知"),
                    enabledText = rule.enabled == false and "停用" or "启用",
                    enabledTone = rule.enabled == false and "muted" or "green",
                    match = rule.matchType == "ID" and "单位ID" or "名称",
                    decision = DecisionText(rule),
                    source = rule,
                }
            end
            self.ruleRows = rows
            self.ruleRevision = revision
            self.rulesTable:SetItems(self.ruleRows, "dpsv2:rules:" .. tostring(revision))
            if self.selectedRuleId ~= nil and d.Rules:GetById(self.selectedRuleId) == nil then self.selectedRuleId = nil end
        end
        self.summary:SetTone("green")
        self.summary:SetText("持久名单 " .. tostring(#self.ruleRows) .. "/" .. tostring(d.Const and d.Const.MAX_PERSISTENT_RULES or 500)
            .. " · 个人人工裁决优先 · 名称冲突由 Authority 阻止宽泛覆盖")
        self:RefreshRuleActionState()
        return true
    end

    function view:ToggleRule()
        local d = ExportDps()
        local rule = d and d.Rules and self.selectedRuleId and d.Rules:GetById(self.selectedRuleId) or nil
        if rule == nil then return false end
        local ok, err = d.Rules:SetEnabled(rule.ruleId, rule.enabled == false)
        if ok ~= true then SafeChat("名单切换失败：" .. tostring(err or "未知错误")) end
        if d.UI and type(d.UI.RefreshQuickWindows) == "function" then d.UI:RefreshQuickWindows() end
        self:RefreshRules(true)
        return ok == true
    end

    function view:DeleteRule()
        local d = ExportDps()
        local rule = d and d.Rules and self.selectedRuleId and d.Rules:GetById(self.selectedRuleId) or nil
        if rule == nil then return false end
        local now = S.NowMs and S.NowMs() or 0
        if tostring(self.ruleDeleteArmedId or "") ~= tostring(rule.ruleId)
            or now - (tonumber(self.ruleDeleteArmedAt) or 0) > 5000 then
            self.ruleDeleteArmedId, self.ruleDeleteArmedAt = rule.ruleId, now
            SafeChat("5秒内再次点击“删除选中”确认删除：" .. tostring(rule.displayName or rule.ruleId))
            self:RefreshRuleActionState()
            return false
        end
        local removed = d.Rules:Remove(rule.ruleId)
        self.ruleDeleteArmedId, self.ruleDeleteArmedAt = nil, 0
        if removed then
            SafeChat("已删除名单规则：" .. tostring(rule.displayName or rule.ruleId))
            self.selectedRuleId = nil
            if d.UI and type(d.UI.RefreshQuickWindows) == "function" then d.UI:RefreshQuickWindows() end
        end
        self:RefreshRules(true)
        return removed == true
    end

    function view:ClearRules()
        local d = ExportDps()
        if d == nil or d.Rules == nil then return false end
        local now = S.NowMs and S.NowMs() or 0
        if now - (tonumber(self.ruleClearArmedAt) or 0) > 5000 then
            self.ruleClearArmedAt = now
            SafeChat("5秒内再次点击“清空全部名单”确认；该操作不会清除原始战斗统计。")
            self:RefreshRuleActionState()
            return false
        end
        local changed = d.Rules:ClearAll()
        self.ruleClearArmedAt = 0
        self.selectedRuleId = nil
        if changed then
            SafeChat("已清空 DPS 持久名单；相关统计会在安全时机重新归类。")
            if d.UI and type(d.UI.RefreshQuickWindows) == "function" then d.UI:RefreshQuickWindows() end
        end
        self:RefreshRules(true)
        return changed == true
    end

    function view:Refresh()
        local d = ExportDps()
        if d and d.State and d.State.config then
            local mode = tostring(d.State.config.currentMode or "PVP")
            local page = tostring(d.State.config.currentPage or "DAMAGE")
            self.modeButton:SetText("模式：" .. mode)
            self.pageButton:SetText("页面：" .. PageLabel(page))
            self.sideButton:SetText("阵营：" .. (self.side == "friendly" and "友军" or "敌军"))
        end
        if self.subview == "ranking" then return self:RefreshRanking() end
        if self.subview == "ability" then
            self.summary:SetTone("green")
            self.summary:SetText("技能明细 · 只对当前选中排行榜单位分帧整理；不在隐藏页做排序。")
            return self:RefreshDetail("ABILITY", false)
        end
        if self.subview == "counterpart" then
            self.summary:SetTone("green")
            self.summary:SetText("目标 / 来源 · PVE 友军伤害目标可直接切 Boss / 排除；同名冲突不会自动扩大人工纠错范围。")
            return self:RefreshDetail("COUNTERPART", false)
        end
        return self:RefreshRules(false)
    end

    view:SetSubview("ranking")
    return view
end

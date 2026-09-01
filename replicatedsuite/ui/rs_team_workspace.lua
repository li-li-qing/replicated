------------------------------------------------------------------------
-- Replicated Suite - Team Utility Combat Workspace (M5 v6)
--
-- Deep RSUI migration for Team Utility.
--
-- Authority / performance boundary:
--   * this file never calls X2Unit/X2Team/X2Option directly;
--   * periodic Refresh() consumes only committed TeamUtility / DamageReview
--     snapshots and never performs a raid scan;
--   * Buff / profession and siege checks are explicit button actions in the
--     TeamUtility Service; their structured results are cached for rendering;
--   * DamageReview timeline reads the already-recorded history buffer only;
--   * Sacrifice rows read the Service's committed candidate/active sets only.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI = S.RSUI
if type(RSUI) ~= "table" then return end

S.CombatTeamWorkspace = S.CombatTeamWorkspace or {}
local WT = S.CombatTeamWorkspace

local SECTION_ORDER = { "overview", "checks", "sacrifice", "review", "markers", "diag" }
local SECTION_LABEL = {
    overview = "团队总览",
    checks = "团队检查",
    sacrifice = "牺牲之舞",
    review = "伤害回顾",
    markers = "原生标记",
    diag = "诊断",
}

local ROLE_ORDER = { "tank", "healer", "dealer", "ranged", "none" }
local ROLE_LABEL = { tank = "T", healer = "奶妈", dealer = "战士", ranged = "远程", none = "未标记" }
local BUFF_CATEGORY_LABEL = { drum = "drum", statue = "statue", book = "book", ribs = "ribs", goblet = "goblet" }

local function TeamService()
    return S.Services and S.Services.TeamUtility or nil
end

local function ReviewService()
    return S.Services and S.Services.DamageReview or nil
end

local function SafeChat(text)
    if S.SafeChat ~= nil then S.SafeChat(tostring(text or "")) end
end

local function BoolText(value)
    return value == true and "开" or "关"
end

local function ToneForBool(value)
    return value == true and "green" or "muted"
end

local function FormatCompact(value)
    local n = tonumber(value) or 0
    local a = math.abs(n)
    if a >= 1000000000 then return string.format("%.2fB", n / 1000000000) end
    if a >= 1000000 then return string.format("%.2fM", n / 1000000) end
    if a >= 1000 then return string.format("%.1fK", n / 1000) end
    return tostring(math.floor(n + 0.5))
end

local function FormatRemaining(ms)
    ms = tonumber(ms)
    if ms == nil then return "--" end
    if ms <= 0 then return "0.0s" end
    return string.format("%.1fs", ms / 1000)
end

local function FormatCheckAge(checkedAt)
    checkedAt = tonumber(checkedAt) or 0
    if checkedAt <= 0 or S.NowMs == nil then return "尚未执行" end
    local age = math.max(0, (S.NowMs() - checkedAt) / 1000)
    if age < 2 then return "刚刚" end
    if age < 60 then return tostring(math.floor(age + 0.5)) .. "秒前" end
    return tostring(math.floor(age / 60 + 0.5)) .. "分钟前"
end

local function JoinArray(values, fallback)
    if type(values) ~= "table" or #values == 0 then return fallback or "--" end
    local out = {}
    for _, value in ipairs(values) do out[#out + 1] = tostring(value) end
    return table.concat(out, " / ")
end

local function ActionButton(parent, id, text, width, fn, fill)
    return RSUI:Button({
        id = id, parent = parent, text = text, fontSize = 8, compact = true, gradient = true,
        slot = fill == true
            and { size = "fill", fill = 1, minWidth = tonumber(width) or 48, hAlign = "fill" }
            or { size = "fixed", width = tonumber(width) or 68, hAlign = "fill" },
        onClick = fn,
    })
end

local function CreatePage(parent, id, scroll)
    local page = RSUI:Border({ id = id, parent = parent, padding = 4, variant = "soft", gradient = false })
    if page and page.root and page.root.rsBorder and page.root.rsBorder.SetVisible then page.root.rsBorder:SetVisible(false) end
    if page and page.root and page.root.rsBackground and page.root.rsBackground.SetVisible then page.root.rsBackground:SetVisible(false) end
    local stack
    if scroll == true then
        stack = RSUI:ScrollBox({ id = id .. "_scroll", parent = page, orientation = "vertical", gap = 5, scrollStep = 2, padding = 2 })
    else
        stack = RSUI:VerticalBox({ id = id .. "_stack", parent = page, gap = 5 })
    end
    return page, stack
end

local function CreateSelectableRow(prefix, list, poolIndex, tableView, onActivate)
    local row = RSUI:TableRow({
        id = prefix .. "_row_" .. tostring(poolIndex), parent = list,
        columns = tableView.columns, resolvedWidths = tableView.resolvedWidths,
        rowHeight = tableView.rowHeight, columnGap = tableView.columnGap, pickable = true,
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

local function NextDiscrete(current, values, direction)
    current = tonumber(current) or tonumber(values[1]) or 0
    direction = tonumber(direction) or 1
    local nearest = 1
    for index, value in ipairs(values) do
        if tonumber(value) == current then nearest = index; break end
        if tonumber(value) <= current then nearest = index end
    end
    nearest = nearest + (direction >= 0 and 1 or -1)
    if nearest < 1 then nearest = #values end
    if nearest > #values then nearest = 1 end
    return values[nearest]
end

function WT:Build(workspace, parent)
    local view = {
        section = "overview",
        navButtons = {}, pages = {},
        checkMode = "buff",
        checkRows = {}, checkRevision = -1,
        sacrificeRows = {}, sacrificeSignature = "",
        historyRows = {}, historyRevision = -1, selectedHistorySerial = nil,
        eventRows = {}, eventSignature = "",
    }

    view.component = RSUI:Border({
        id = "combat_team_v6_root", parent = parent,
        width = 100, height = 100, padding = 4, variant = "soft", gradient = false,
    })
    view.root = view.component and view.component.root or nil
    if view.root == nil then return nil end
    if view.root.rsBorder and view.root.rsBorder.SetVisible then view.root.rsBorder:SetVisible(false) end
    if view.root.rsBackground and view.root.rsBackground.SetVisible then view.root.rsBackground:SetVisible(false) end

    view.stack = RSUI:VerticalBox({ id = "combat_team_v6_stack", parent = view.component, gap = 5 })
    view.summary = RSUI:Text({
        id = "combat_team_v6_summary", parent = view.stack,
        text = "团队辅助：--", tone = "muted", fontSize = 9, overflow = "ellipsis",
        slot = { size = "fixed", height = 20, hAlign = "fill" },
    })
    view.body = RSUI:HorizontalBox({
        id = "combat_team_v6_body", parent = view.stack, gap = 6,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })

    view.navCard = RSUI:Border({
        id = "combat_team_v6_nav", parent = view.body, width = 122, padding = 5, variant = "card", gradient = true,
        slot = { size = "fixed", width = 122, hAlign = "fill", vAlign = "fill" },
    })
    view.navStack = RSUI:VerticalBox({ id = "combat_team_v6_nav_stack", parent = view.navCard, gap = 3 })
    RSUI:Text({
        id = "combat_team_v6_nav_title", parent = view.navStack,
        text = "团队工作台", tone = "accent", fontSize = 10,
        slot = { size = "fixed", height = 22, hAlign = "fill" },
    })
    for _, section in ipairs(SECTION_ORDER) do
        local key = section
        view.navButtons[key] = ActionButton(view.navStack, "combat_team_v6_nav_" .. key, SECTION_LABEL[key], 110, function()
            view:SetSection(key)
            return true
        end)
    end
    ActionButton(view.navStack, "combat_team_v6_legacy", "旧高级设置", 110, function()
        workspace:SetMode("settings")
        return true
    end)

    view.switcher = RSUI:WidgetSwitcher({
        id = "combat_team_v6_switcher", parent = view.body, activeIndex = 1,
        slot = { size = "fill", fill = 1, minWidth = 280, hAlign = "fill", vAlign = "fill" },
    })

    local function RegisterPage(section, scroll)
        local page, stack = CreatePage(view.switcher, "combat_team_v6_" .. section, scroll)
        view.pages[section] = { page = page, stack = stack }
        return page, stack
    end

    ------------------------------------------------------------------------
    -- Overview
    ------------------------------------------------------------------------
    local _, overview = RegisterPage("overview", false)
    view.overviewToolbar = RSUI:HorizontalBox({
        id = "combat_team_v6_overview_toolbar", parent = overview, gap = 4,
        slot = { size = "fixed", height = 28, hAlign = "fill" },
    })
    view.roleToggle = ActionButton(view.overviewToolbar, "combat_team_v6_role_toggle", "自动职责", 76, function()
        local svc = TeamService(); if svc then svc:SetAutoRoleEnabled(not (S.State.settings.teamAutoRoleEnabled == true)) end
        view:RefreshOverview(true); return true
    end)
    view.roleMode = ActionButton(view.overviewToolbar, "combat_team_v6_role_mode", "职责规则", 84, function()
        local svc = TeamService(); if svc then svc:CycleRoleMode() end
        view:RefreshOverview(true); return true
    end)
    ActionButton(view.overviewToolbar, "combat_team_v6_role_apply", "立即应用", 72, function()
        local svc = TeamService(); if svc then svc:ApplyRole("team_workspace", true) end
        view:RefreshOverview(true); return true
    end)
    view.sacToggleOverview = ActionButton(view.overviewToolbar, "combat_team_v6_sac_toggle", "牺牲高亮", 76, function()
        local svc = TeamService(); if svc then svc:SetSacMarkerEnabled(not (S.State.settings.sacMarkerEnabled == true)) end
        view:RefreshOverview(true); return true
    end)
    ActionButton(view.overviewToolbar, "combat_team_v6_hud", "HUD 管理", 70, function()
        if S.UI and type(S.UI.ShowPage) == "function" then S.UI:ShowPage("hud") end
        return true
    end, true)

    local overviewColumns = {
        { id = "feature", title = "功能", width = 112, minWidth = 82, absoluteMinWidth = 56, field = "feature" },
        { id = "state", title = "状态", width = 74, minWidth = 56, absoluteMinWidth = 42, field = "state", getTone = function(r) return r and r.tone or "muted" end },
        { id = "detail", title = "实时信息", size = "fill", minWidth = 150, absoluteMinWidth = 76, field = "detail", tone = "muted" },
    }
    view.overviewRows = {}
    view.overviewTable = RSUI:TableView({
        id = "combat_team_v6_overview_table", parent = overview,
        columns = overviewColumns, rowHeight = 25, headerHeight = 22, columnGap = 3,
        items = view.overviewRows, overscan = 1, maxPoolSize = 10,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })
    view.overviewHint = RSUI:Text({
        id = "combat_team_v6_overview_hint", parent = overview,
        text = "团队检查只在点击时扫描；工作台的周期刷新只读取 Service 已提交的数据。", tone = "muted", fontSize = 8, overflow = "ellipsis",
        slot = { size = "fixed", height = 18, hAlign = "fill" },
    })

    ------------------------------------------------------------------------
    -- Manual raid checks
    ------------------------------------------------------------------------
    local _, checks = RegisterPage("checks", false)
    view.checkToolbar = RSUI:HorizontalBox({
        id = "combat_team_v6_check_toolbar", parent = checks, gap = 4,
        slot = { size = "fixed", height = 28, hAlign = "fill" },
    })
    view.checkBuffButton = ActionButton(view.checkToolbar, "combat_team_v6_check_buff", "Buff / 职业检查", 108, function()
        local svc = TeamService()
        if svc then
            local ok, err = svc:RunBuffCheck()
            if ok ~= true and err ~= nil then SafeChat("团队检查：" .. tostring(err)) end
        end
        view.checkMode = "buff"; view.checkRevision = -1; view:RefreshChecks(true); return true
    end)
    view.checkSiegeButton = ActionButton(view.checkToolbar, "combat_team_v6_check_siege", "攻城装备检查", 96, function()
        local svc = TeamService()
        if svc then
            local ok, err = svc:RunSiegeCheck()
            if ok ~= true and err ~= nil then SafeChat("攻城检查：" .. tostring(err)) end
        end
        view.checkMode = "siege"; view.checkRevision = -1; view:RefreshChecks(true); return true
    end)
    view.checkShowBuff = ActionButton(view.checkToolbar, "combat_team_v6_check_show_buff", "显示 Buff结果", 88, function()
        view.checkMode = "buff"; view.checkRevision = -1; view:RefreshChecks(true); return true
    end)
    view.checkShowSiege = ActionButton(view.checkToolbar, "combat_team_v6_check_show_siege", "显示攻城结果", 88, function()
        view.checkMode = "siege"; view.checkRevision = -1; view:RefreshChecks(true); return true
    end, true)
    view.checkSummary = RSUI:Text({
        id = "combat_team_v6_check_summary", parent = checks,
        text = "尚未执行检查", tone = "muted", fontSize = 9, overflow = "ellipsis",
        slot = { size = "fixed", height = 20, hAlign = "fill" },
    })
    view.checkRoles = RSUI:Text({
        id = "combat_team_v6_check_roles", parent = checks,
        text = "职责统计：--", tone = "muted", fontSize = 8, overflow = "ellipsis",
        slot = { size = "fixed", height = 18, hAlign = "fill" },
    })
    local checkColumns = {
        { id = "slot", title = "位置", width = 58, minWidth = 48, absoluteMinWidth = 40, field = "slot" },
        { id = "name", title = "成员", size = "fill", minWidth = 100, absoluteMinWidth = 60, field = "name" },
        { id = "role", title = "职责", width = 64, minWidth = 50, absoluteMinWidth = 40, field = "role" },
        { id = "result", title = "检查结果", size = "fill", minWidth = 150, absoluteMinWidth = 78, field = "result", getTone = function(r) return r and r.tone or "muted" end },
    }
    view.checkTable = RSUI:TableView({
        id = "combat_team_v6_check_table", parent = checks,
        columns = checkColumns, rowHeight = 24, headerHeight = 22, columnGap = 3,
        items = view.checkRows, overscan = 2, maxPoolSize = 28,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })
    view.checkHint = RSUI:Text({
        id = "combat_team_v6_check_hint", parent = checks,
        text = "检查结果是上一次手动扫描的快照；不会因为停留在本页而持续枚举团队 Buff。", tone = "muted", fontSize = 8, overflow = "ellipsis",
        slot = { size = "fixed", height = 18, hAlign = "fill" },
    })

    ------------------------------------------------------------------------
    -- Sacrifice Dance
    ------------------------------------------------------------------------
    local _, sacrifice = RegisterPage("sacrifice", false)
    view.sacToolbar = RSUI:HorizontalBox({
        id = "combat_team_v6_sac_toolbar", parent = sacrifice, gap = 4,
        slot = { size = "fixed", height = 28, hAlign = "fill" },
    })
    view.sacToggle = ActionButton(view.sacToolbar, "combat_team_v6_sac_enabled", "高亮：--", 76, function()
        local svc = TeamService(); if svc then svc:SetSacMarkerEnabled(not (S.State.settings.sacMarkerEnabled == true)) end
        view:RefreshSacrifice(true); return true
    end)
    ActionButton(view.sacToolbar, "combat_team_v6_sac_scan", "立即扫描候选", 92, function()
        local svc = TeamService()
        if svc then
            if type(svc.ScanDancerCandidates) == "function" then svc:ScanDancerCandidates() end
            if type(svc.ScanSacBuffs) == "function" then svc:ScanSacBuffs() end
        end
        view.sacrificeSignature = ""; view:RefreshSacrifice(true); return true
    end)
    view.sacSummary = RSUI:Text({
        id = "combat_team_v6_sac_summary", parent = view.sacToolbar,
        text = "候选 0 · 施放中 0", tone = "muted", fontSize = 9, overflow = "ellipsis",
        slot = { size = "fill", fill = 1, minWidth = 120, hAlign = "fill", vAlign = "center" },
    })
    local sacColumns = {
        { id = "name", title = "成员", size = "fill", minWidth = 120, absoluteMinWidth = 68, field = "name" },
        { id = "state", title = "状态", width = 72, minWidth = 58, absoluteMinWidth = 44, field = "state", getTone = function(r) return r and r.tone or "muted" end },
        { id = "buff", title = "Buff ID", width = 72, minWidth = 58, absoluteMinWidth = 46, field = "buff" },
        { id = "remaining", title = "剩余", width = 70, minWidth = 58, absoluteMinWidth = 44, field = "remaining", tone = "accent" },
    }
    view.sacTable = RSUI:TableView({
        id = "combat_team_v6_sac_table", parent = sacrifice,
        columns = sacColumns, rowHeight = 24, headerHeight = 22, columnGap = 3,
        items = view.sacrificeRows, overscan = 2, maxPoolSize = 28,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })
    view.sacHint = RSUI:Text({
        id = "combat_team_v6_sac_hint", parent = sacrifice,
        text = "候选发现由低频 Roster 扫描负责；仅正在施放成员启用 50ms 位置跟随，列表刷新不会追加 Native 扫描。", tone = "muted", fontSize = 8, overflow = "ellipsis",
        slot = { size = "fixed", height = 30, hAlign = "fill" },
    })

    ------------------------------------------------------------------------
    -- Damage Review
    ------------------------------------------------------------------------
    local _, review = RegisterPage("review", false)
    view.reviewToolbar = RSUI:HorizontalBox({
        id = "combat_team_v6_review_toolbar", parent = review, gap = 4,
        slot = { size = "fixed", height = 28, hAlign = "fill" },
    })
    view.reviewEnabled = ActionButton(view.reviewToolbar, "combat_team_v6_review_enabled", "回顾：--", 70, function()
        local svc = ReviewService(); if svc then svc:SetEnabled(not (S.State.settings.damageReviewEnabled == true)) end
        view:RefreshReview(true); return true
    end)
    view.reviewAuto = ActionButton(view.reviewToolbar, "combat_team_v6_review_auto", "弹窗：--", 70, function()
        local svc = ReviewService(); if svc then svc:SetSetting("damageReviewAutoShow", not (S.State.settings.damageReviewAutoShow == true)) end
        view:RefreshReview(true); return true
    end)
    view.reviewDebuff = ActionButton(view.reviewToolbar, "combat_team_v6_review_debuff", "Debuff：--", 76, function()
        local svc = ReviewService(); if svc then svc:SetSetting("damageReviewShowDebuffs", not (S.State.settings.damageReviewShowDebuffs == true)) end
        view:RefreshReview(true); return true
    end)
    ActionButton(view.reviewToolbar, "combat_team_v6_review_history_native", "独立历史窗口", 92, function()
        local svc = ReviewService()
        if svc and type(svc.OpenHistory) == "function" then svc:OpenHistory()
        elseif svc and type(svc.ToggleHistory) == "function" then svc:ToggleHistory() end
        return true
    end, true)

    view.reviewConfig = RSUI:HorizontalBox({
        id = "combat_team_v6_review_config", parent = review, gap = 4,
        slot = { size = "fixed", height = 28, hAlign = "fill" },
    })
    view.reviewWindowMinus = ActionButton(view.reviewConfig, "combat_team_v6_review_window_minus", "窗口 -", 58, function()
        local svc = ReviewService(); if svc then svc:SetSetting("damageReviewWindowMs", NextDiscrete(S.State.settings.damageReviewWindowMs, { 5000, 8000, 10000, 12000, 15000, 20000 }, -1)) end
        view:RefreshReview(true); return true
    end)
    view.reviewWindowPlus = ActionButton(view.reviewConfig, "combat_team_v6_review_window_plus", "窗口 +", 58, function()
        local svc = ReviewService(); if svc then svc:SetSetting("damageReviewWindowMs", NextDiscrete(S.State.settings.damageReviewWindowMs, { 5000, 8000, 10000, 12000, 15000, 20000 }, 1)) end
        view:RefreshReview(true); return true
    end)
    view.reviewHistoryMinus = ActionButton(view.reviewConfig, "combat_team_v6_review_keep_minus", "保留 -", 58, function()
        local svc = ReviewService(); if svc then svc:SetSetting("damageReviewMaxHistory", NextDiscrete(S.State.settings.damageReviewMaxHistory, { 5, 10, 15, 20, 30 }, -1)) end
        view:RefreshReview(true); return true
    end)
    view.reviewHistoryPlus = ActionButton(view.reviewConfig, "combat_team_v6_review_keep_plus", "保留 +", 58, function()
        local svc = ReviewService(); if svc then svc:SetSetting("damageReviewMaxHistory", NextDiscrete(S.State.settings.damageReviewMaxHistory, { 5, 10, 15, 20, 30 }, 1)) end
        view:RefreshReview(true); return true
    end)
    view.reviewMinMinus = ActionButton(view.reviewConfig, "combat_team_v6_review_min_minus", "最低伤害 -", 72, function()
        local svc = ReviewService(); if svc then svc:SetSetting("damageReviewMinDamage", NextDiscrete(S.State.settings.damageReviewMinDamage, { 0, 100, 250, 500, 1000, 2500, 5000 }, -1)) end
        view:RefreshReview(true); return true
    end)
    view.reviewMinPlus = ActionButton(view.reviewConfig, "combat_team_v6_review_min_plus", "最低伤害 +", 72, function()
        local svc = ReviewService(); if svc then svc:SetSetting("damageReviewMinDamage", NextDiscrete(S.State.settings.damageReviewMinDamage, { 0, 100, 250, 500, 1000, 2500, 5000 }, 1)) end
        view:RefreshReview(true); return true
    end, true)

    view.reviewSummary = RSUI:Text({
        id = "combat_team_v6_review_summary", parent = review,
        text = "伤害回顾：--", tone = "muted", fontSize = 9, overflow = "ellipsis",
        slot = { size = "fixed", height = 20, hAlign = "fill" },
    })
    view.reviewBody = RSUI:HorizontalBox({
        id = "combat_team_v6_review_body", parent = review, gap = 6,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })
    view.reviewLeft = RSUI:VerticalBox({
        id = "combat_team_v6_review_left", parent = view.reviewBody, gap = 4,
        slot = { size = "fixed", width = 280, hAlign = "fill", vAlign = "fill" },
    })
    local historyColumns = {
        { id = "clock", title = "时间", width = 64, minWidth = 54, absoluteMinWidth = 44, field = "clock" },
        { id = "total", title = "总承伤", width = 72, minWidth = 58, absoluteMinWidth = 46, field = "total" },
        { id = "lethal", title = "致命技能", size = "fill", minWidth = 100, absoluteMinWidth = 58, field = "lethal" },
    }
    view.historyTable = RSUI:TableView({
        id = "combat_team_v6_review_history", parent = view.reviewLeft,
        columns = historyColumns, rowHeight = 24, headerHeight = 22, columnGap = 3,
        items = view.historyRows, selectable = true, selectionMode = "single", overscan = 2, maxPoolSize = 18,
        rowFactory = function(list, poolIndex, tableView)
            return CreateSelectableRow("combat_team_v6_review_history", list, poolIndex, tableView, function(row)
                if row then view.selectedHistorySerial = row.serial end
                view:RefreshReviewDetail(true)
            end)
        end,
        onSelectionChanged = function(index)
            local row = index and view.historyRows[index] or nil
            view.selectedHistorySerial = row and row.serial or nil
            view:RefreshReviewDetail(true)
        end,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })
    view.reviewRight = RSUI:VerticalBox({
        id = "combat_team_v6_review_right", parent = view.reviewBody, gap = 4,
        slot = { size = "fill", fill = 1, minWidth = 220, hAlign = "fill", vAlign = "fill" },
    })
    view.reviewDetail = RSUI:Text({
        id = "combat_team_v6_review_detail", parent = view.reviewRight,
        text = "请选择一条死亡记录", tone = "muted", fontSize = 8, overflow = "ellipsis",
        slot = { size = "fixed", height = 36, hAlign = "fill" },
    })
    local eventColumns = {
        { id = "before", title = "死亡前", width = 62, minWidth = 52, absoluteMinWidth = 42, field = "before" },
        { id = "source", title = "来源", width = 100, minWidth = 72, absoluteMinWidth = 52, field = "source" },
        { id = "ability", title = "技能", size = "fill", minWidth = 100, absoluteMinWidth = 60, field = "ability" },
        { id = "amount", title = "伤害", width = 72, minWidth = 58, absoluteMinWidth = 46, field = "amount", tone = "red" },
    }
    view.eventTable = RSUI:TableView({
        id = "combat_team_v6_review_events", parent = view.reviewRight,
        columns = eventColumns, rowHeight = 23, headerHeight = 22, columnGap = 3,
        items = view.eventRows, overscan = 2, maxPoolSize = 20,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })

    ------------------------------------------------------------------------
    -- Native marker scale
    ------------------------------------------------------------------------
    local _, markers = RegisterPage("markers", true)
    view.markerTitle = RSUI:Text({
        id = "combat_team_v6_marker_title", parent = markers,
        text = "游戏原生头顶团队标记", tone = "accent", fontSize = 12,
        slot = { size = "fixed", height = 24, hAlign = "fill" },
    })
    view.markerHint = RSUI:Text({
        id = "combat_team_v6_marker_hint", parent = markers,
        text = "只调整客户端原生团队标记图标大小，不修改 Replicated Plates / Healer 自绘 HUD。", tone = "muted", fontSize = 9,
        slot = { size = "fixed", height = 38, hAlign = "fill" },
    })
    view.markerRow = RSUI:HorizontalBox({
        id = "combat_team_v6_marker_row", parent = markers, gap = 5,
        slot = { size = "fixed", height = 36, hAlign = "fill" },
    })
    ActionButton(view.markerRow, "combat_team_v6_marker_minus", "- 10%", 68, function()
        local svc = TeamService(); if svc then svc:AdjustMarkerScale(-0.10) end
        view:RefreshMarkers(true); return true
    end)
    view.markerValue = RSUI:Text({
        id = "combat_team_v6_marker_value", parent = view.markerRow,
        text = "120%", tone = "accent", fontSize = 14, align = ALIGN_CENTER,
        slot = { size = "fixed", width = 92, hAlign = "fill", vAlign = "center" },
    })
    ActionButton(view.markerRow, "combat_team_v6_marker_plus", "+ 10%", 68, function()
        local svc = TeamService(); if svc then svc:AdjustMarkerScale(0.10) end
        view:RefreshMarkers(true); return true
    end)
    ActionButton(view.markerRow, "combat_team_v6_marker_reset", "恢复 120%", 86, function()
        local svc = TeamService(); if svc then svc:ResetMarkerScale() end
        view:RefreshMarkers(true); return true
    end, true)
    view.markerStatus = RSUI:Text({
        id = "combat_team_v6_marker_status", parent = markers,
        text = "API：--", tone = "muted", fontSize = 9,
        slot = { size = "fixed", height = 22, hAlign = "fill" },
    })

    ------------------------------------------------------------------------
    -- Diagnostics
    ------------------------------------------------------------------------
    local _, diag = RegisterPage("diag", false)
    view.diagSummary = RSUI:Text({
        id = "combat_team_v6_diag_summary", parent = diag,
        text = "团队辅助诊断：--", tone = "muted", fontSize = 9, overflow = "ellipsis",
        slot = { size = "fixed", height = 22, hAlign = "fill" },
    })
    local diagColumns = {
        { id = "name", title = "能力 / 状态", size = "fill", minWidth = 170, absoluteMinWidth = 90, field = "name" },
        { id = "state", title = "状态", width = 94, minWidth = 70, absoluteMinWidth = 52, field = "state", getTone = function(r) return r and r.tone or "muted" end },
        { id = "detail", title = "说明", size = "fill", minWidth = 180, absoluteMinWidth = 90, field = "detail", tone = "muted" },
    }
    view.diagRows = {}
    view.diagTable = RSUI:TableView({
        id = "combat_team_v6_diag_table", parent = diag,
        columns = diagColumns, rowHeight = 24, headerHeight = 22, columnGap = 3,
        items = view.diagRows, overscan = 1, maxPoolSize = 16,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })
    view.diagHint = RSUI:Text({
        id = "combat_team_v6_diag_hint", parent = diag,
        text = "本页只显示 TeamUtility Start 时已缓存的 Capability 结果和当前 Service 状态，不在刷新循环里重新探测 API。", tone = "muted", fontSize = 8,
        slot = { size = "fixed", height = 30, hAlign = "fill" },
    })

    ------------------------------------------------------------------------
    -- Refresh methods
    ------------------------------------------------------------------------
    function view:SetSection(section)
        if self.pages[section] == nil then section = "overview" end
        self.section = section
        local index = 1
        for i, key in ipairs(SECTION_ORDER) do if key == section then index = i; break end end
        self.switcher:SetActiveIndex(index)
        for _, key in ipairs(SECTION_ORDER) do
            local button = self.navButtons[key]
            if button then button:SetText((key == section and "▶ " or "") .. SECTION_LABEL[key]) end
        end
        self:Refresh(true)
        return true
    end

    function view:RefreshSummary()
        local svc = TeamService()
        local o = svc and type(svc.GetWorkspaceOverview) == "function" and svc:GetWorkspaceOverview() or nil
        if o == nil then
            self.summary:SetText("团队辅助：Service 未初始化")
            self.summary:SetTone("red")
            return nil
        end
        local role = o.role or {}
        local sac = o.sacrifice or {}
        self.summary:SetText("职责 " .. tostring(role.status or "--") .. " · 规则 " .. tostring(role.modeLabel or "--")
            .. " · 舞者候选 " .. tostring(sac.candidates or 0) .. " · 施放中 " .. tostring(sac.active or 0))
        self.summary:SetTone(o.started and "green" or "yellow")
        return o
    end

    function view:RefreshOverview(force)
        local o = self:RefreshSummary(); if o == nil then return false end
        local settings = S.State.settings or {}
        local role = o.role or {}; local sac = o.sacrifice or {}; local marker = o.marker or {}
        self.roleToggle:SetText("自动职责：" .. BoolText(role.enabled))
        self.roleMode:SetText("规则：" .. tostring(role.modeLabel or "--"))
        self.sacToggleOverview:SetText("牺牲高亮：" .. BoolText(sac.enabled))
        local reviewSvc = ReviewService()
        local reviewLine = reviewSvc and type(reviewSvc.GetStatusLine) == "function" and reviewSvc:GetStatusLine() or "伤害回顾未加载"
        local rows = {
            { feature = "自动职责", state = BoolText(role.enabled), tone = ToneForBool(role.enabled), detail = tostring(role.status) .. " · " .. tostring(role.classKey) .. " · " .. tostring(role.source) },
            { feature = "团队检查", state = (o.checks and tonumber(o.checks.revision) or 0) > 0 and "有快照" or "未检查", tone = (o.checks and tonumber(o.checks.revision) or 0) > 0 and "green" or "muted", detail = "上次 " .. tostring(o.checks and o.checks.lastKind or "--") .. " · " .. FormatCheckAge(o.checks and o.checks.lastAt) },
            { feature = "牺牲之舞", state = BoolText(sac.enabled), tone = ToneForBool(sac.enabled), detail = "候选 " .. tostring(sac.candidates or 0) .. " · 施放中 " .. tostring(sac.active or 0) },
            { feature = "伤害回顾", state = BoolText(settings.damageReviewEnabled == true), tone = ToneForBool(settings.damageReviewEnabled == true), detail = reviewLine },
            { feature = "原生标记", state = marker.available and "可用" or "API不可用", tone = marker.available and "green" or "red", detail = tostring(math.floor((tonumber(marker.scale) or 1.2) * 100 + 0.5)) .. "%" },
        }
        self.overviewRows = rows
        self.overviewTable:SetItems(rows, table.concat({ tostring(role.enabled), tostring(role.mode), tostring(role.status), tostring(sac.enabled), tostring(sac.candidates), tostring(sac.active), tostring(settings.damageReviewEnabled), tostring(marker.scale), tostring(o.checks and o.checks.revision) }, "|"))
        return true
    end

    function view:RefreshChecks(force)
        local svc = TeamService(); self:RefreshSummary()
        if svc == nil or type(svc.GetManualCheckSnapshot) ~= "function" then return false end
        local snapshot = svc:GetManualCheckSnapshot(self.checkMode, 100)
        self.checkShowBuff:SetText((self.checkMode == "buff" and "▶ " or "") .. "显示 Buff结果")
        self.checkShowSiege:SetText((self.checkMode == "siege" and "▶ " or "") .. "显示攻城结果")
        if force ~= true and self.checkRevision == tonumber(snapshot.revision) then
            self.checkSummary:SetText((self.checkMode == "buff" and "Buff / 职业" or "攻城装备") .. " · " .. FormatCheckAge(snapshot.checkedAt) .. " · 成员 " .. tostring(snapshot.checked or 0))
            return true
        end
        self.checkRevision = tonumber(snapshot.revision) or 0
        local rows = {}
        for _, row in ipairs(snapshot.rows or {}) do
            local result
            local tone = "muted"
            if self.checkMode == "buff" then
                result = tostring(row.state or "--")
                if row.unreadable then tone = "yellow"
                elseif type(row.missing) == "table" and #row.missing > 0 then tone = "yellow"
                elseif snapshot.buffReadable == false then tone = "muted"
                else tone = "green" end
            else
                result = tostring(row.state or "--")
                if row.unreadable then tone = "yellow"
                elseif type(row.detected) == "table" and #row.detected > 0 then tone = "yellow"
                else tone = "green" end
            end
            rows[#rows + 1] = { slot = row.slot or "--", name = row.name or "--", role = row.role or "--", result = result, tone = tone }
        end
        self.checkRows = rows
        self.checkTable:SetItems(rows, tostring(self.checkMode) .. ":" .. tostring(snapshot.revision or 0))
        self.checkSummary:SetText((self.checkMode == "buff" and "Buff / 职业" or "攻城装备") .. " · " .. FormatCheckAge(snapshot.checkedAt) .. " · 成员 " .. tostring(snapshot.checked or 0)
            .. (snapshot.unreadableCount and snapshot.unreadableCount > 0 and (" · 无法读取 " .. tostring(snapshot.unreadableCount)) or ""))
        if self.checkMode == "buff" then
            local parts = {}
            for _, kind in ipairs(ROLE_ORDER) do parts[#parts + 1] = tostring(ROLE_LABEL[kind]) .. " " .. tostring((snapshot.roleCounts or {})[kind] or 0) end
            self.checkRoles:SetText("职责统计：" .. table.concat(parts, " · "))
        else
            self.checkRoles:SetText(snapshot.message and ("状态：" .. tostring(snapshot.message)) or "攻城装备分类沿用 TeamUtility 已验证的 Hidden Buff ID Authority。")
        end
        return true
    end

    function view:RefreshSacrifice(force)
        local svc = TeamService(); local o = self:RefreshSummary()
        if svc == nil or type(svc.GetSacrificeSnapshot) ~= "function" then return false end
        local snapshot = svc:GetSacrificeSnapshot(100)
        self.sacToggle:SetText("高亮：" .. BoolText(snapshot.enabled))
        self.sacSummary:SetText("候选 " .. tostring(snapshot.count or 0) .. " · 施放中 " .. tostring(snapshot.activeCount or 0))
        local rows, sig = {}, { tostring(snapshot.enabled), tostring(snapshot.activeCount), tostring(snapshot.count) }
        for _, row in ipairs(snapshot.rows or {}) do
            rows[#rows + 1] = {
                name = row.name or "--",
                state = row.state or "--",
                tone = row.active and "yellow" or "muted",
                buff = row.buffId and tostring(row.buffId) or "--",
                remaining = row.active and FormatRemaining(row.remainingMs) or "--",
            }
            sig[#sig + 1] = tostring(row.unitId) .. ":" .. tostring(row.active) .. ":" .. tostring(math.floor((tonumber(row.remainingMs) or 0) / 1000))
        end
        local signature = table.concat(sig, "|")
        if force == true or signature ~= self.sacrificeSignature then
            self.sacrificeSignature = signature
            self.sacrificeRows = rows
            self.sacTable:SetItems(rows, signature)
        end
        return o ~= nil
    end

    function view:RefreshReviewDetail(force)
        local svc = ReviewService()
        if svc == nil or type(svc.GetWorkspaceRecord) ~= "function" then return false end
        local record = svc:GetWorkspaceRecord(self.selectedHistorySerial)
        if record == nil then
            self.reviewDetail:SetText("请选择一条死亡记录")
            if force == true or self.eventSignature ~= "none" then
                self.eventSignature = "none"; self.eventRows = {}; self.eventTable:SetItems({}, "none")
            end
            return true
        end
        self.selectedHistorySerial = record.serial
        local debuffNames = {}
        for _, debuff in ipairs(record.debuffs or {}) do
            debuffNames[#debuffNames + 1] = tostring(debuff.name) .. ((tonumber(debuff.stack) or 0) > 1 and (" x" .. tostring(debuff.stack)) or "")
        end
        self.reviewDetail:SetText("#" .. tostring(record.serial) .. " · " .. tostring(record.clock) .. " · 窗口 " .. tostring(math.floor((record.windowMs or 0) / 1000 + 0.5)) .. "s · 总承伤 " .. FormatCompact(record.totalDamage)
            .. " · Debuff " .. (#debuffNames > 0 and table.concat(debuffNames, " / ") or "无记录"))
        local rows, sig = {}, { tostring(record.serial) }
        for _, event in ipairs(record.events or {}) do
            rows[#rows + 1] = {
                before = string.format("%.1fs", tonumber(event.secondsBefore) or 0),
                source = event.source or "--",
                ability = event.ability or "--",
                amount = FormatCompact(event.amount),
            }
            sig[#sig + 1] = tostring(event.secondsBefore) .. ":" .. tostring(event.source) .. ":" .. tostring(event.ability) .. ":" .. tostring(event.amount)
        end
        local signature = table.concat(sig, "|")
        if force == true or signature ~= self.eventSignature then
            self.eventSignature = signature; self.eventRows = rows; self.eventTable:SetItems(rows, signature)
        end
        return true
    end

    function view:RefreshReview(force)
        self:RefreshSummary()
        local svc = ReviewService()
        if svc == nil or type(svc.GetWorkspaceHistorySnapshot) ~= "function" then
            self.reviewSummary:SetText("伤害回顾 Service 未加载")
            return false
        end
        self.reviewEnabled:SetText("回顾：" .. BoolText(S.State.settings.damageReviewEnabled == true))
        self.reviewAuto:SetText("弹窗：" .. BoolText(S.State.settings.damageReviewAutoShow == true))
        self.reviewDebuff:SetText("Debuff：" .. BoolText(S.State.settings.damageReviewShowDebuffs == true))
        local snapshot = svc:GetWorkspaceHistorySnapshot(30)
        self.reviewSummary:SetText("历史 " .. tostring(snapshot.historyCount or 0) .. " · 缓冲伤害 " .. tostring(snapshot.incomingCount or 0) .. " · Debuff快照 " .. tostring(snapshot.debuffSampleCount or 0)
            .. " · 窗口 " .. tostring(math.floor((tonumber(S.State.settings.damageReviewWindowMs) or 10000) / 1000 + 0.5)) .. "s · 保留 " .. tostring(S.State.settings.damageReviewMaxHistory or 10)
            .. " · 最低伤害 " .. tostring(S.State.settings.damageReviewMinDamage or 0))
        if force == true or self.historyRevision ~= tonumber(snapshot.revision) then
            self.historyRevision = tonumber(snapshot.revision) or 0
            local rows = {}
            local selectedExists = false
            for _, row in ipairs(snapshot.rows or {}) do
                local item = {
                    serial = row.serial,
                    clock = row.clock,
                    total = FormatCompact(row.totalDamage),
                    lethal = tostring(row.lethalAbility or "--") .. " · " .. tostring(row.lethalSource or "--"),
                }
                rows[#rows + 1] = item
                if tonumber(item.serial) == tonumber(self.selectedHistorySerial) then selectedExists = true end
            end
            self.historyRows = rows
            self.historyTable:SetItems(rows, "history:" .. tostring(snapshot.revision) .. ":" .. tostring(#rows))
            if not selectedExists then self.selectedHistorySerial = rows[1] and rows[1].serial or nil end
        end
        self:RefreshReviewDetail(force)
        return true
    end

    function view:RefreshMarkers(force)
        local svc = TeamService(); local o = self:RefreshSummary()
        if svc == nil or o == nil then return false end
        local marker = o.marker or {}
        self.markerValue:SetText(marker.available and (tostring(math.floor((tonumber(marker.scale) or 1.2) * 100 + 0.5)) .. "%") or "不可用")
        self.markerValue:SetTone(marker.available and "accent" or "red")
        self.markerStatus:SetText("Console Variable：name_tag_mark_size_ratio · API " .. (marker.available and "可用" or "不可用") .. " · 持久覆盖 " .. BoolText(marker.override))
        self.markerStatus:SetTone(marker.available and "green" or "red")
        return true
    end

    function view:RefreshDiag(force)
        local o = self:RefreshSummary(); if o == nil then return false end
        local rows = {}
        local caps = o.capabilities or {}
        local ordered = {
            { "X2Unit:UnitBuffCount", "Buff 数量读取" },
            { "X2Unit:UnitBuff", "Buff 读取" },
            { "X2Unit:UnitBuffTooltip", "Buff Tooltip" },
            { "X2Unit:UnitHiddenBuffCount", "Hidden Buff 数量" },
            { "X2Unit:UnitHiddenBuff", "Hidden Buff 读取" },
            { "X2Unit:GetUnitScreenPosition", "舞者屏幕位置" },
        }
        for _, entry in ipairs(ordered) do
            local enabled = caps[entry[1]] == true
            rows[#rows + 1] = { name = entry[1], state = enabled and "可用" or "不可用", tone = enabled and "green" or "yellow", detail = entry[2] }
        end
        rows[#rows + 1] = { name = "TeamUtility Service", state = o.started and "运行" or "停止", tone = o.started and "green" or "red", detail = "团队职责 / 手动检查 / 牺牲之舞 Authority" }
        rows[#rows + 1] = { name = "Manual Check Revision", state = tostring(o.checks and o.checks.revision or 0), tone = "accent", detail = "仅显式点击检查时增长" }
        rows[#rows + 1] = { name = "Sacrifice Active", state = tostring(o.sacrifice and o.sacrifice.active or 0), tone = (o.sacrifice and o.sacrifice.active or 0) > 0 and "yellow" or "muted", detail = "只有活动成员启用高频位置跟随" }
        self.diagRows = rows
        self.diagTable:SetItems(rows, table.concat({ tostring(o.started), tostring(o.checks and o.checks.revision), tostring(o.sacrifice and o.sacrifice.active), tostring(caps["X2Unit:UnitBuff"]), tostring(caps["X2Unit:UnitHiddenBuff"]), tostring(caps["X2Unit:GetUnitScreenPosition"]) }, "|"))
        self.diagSummary:SetText("团队辅助 Service " .. (o.started and "运行" or "停止") .. " · 手动检查 Revision " .. tostring(o.checks and o.checks.revision or 0) .. " · 牺牲之舞活动 " .. tostring(o.sacrifice and o.sacrifice.active or 0))
        self.diagSummary:SetTone(o.started and "green" or "yellow")
        return true
    end

    function view:Refresh(force)
        self:RefreshSummary()
        if self.section == "overview" then return self:RefreshOverview(force)
        elseif self.section == "checks" then return self:RefreshChecks(force)
        elseif self.section == "sacrifice" then return self:RefreshSacrifice(force)
        elseif self.section == "review" then return self:RefreshReview(force)
        elseif self.section == "markers" then return self:RefreshMarkers(force)
        elseif self.section == "diag" then return self:RefreshDiag(force) end
        return true
    end

    function view:ApplyLayout(width, height)
        self.component:LayoutIfNeeded(0, 0, math.max(1, tonumber(width) or 1), math.max(1, tonumber(height) or 1))
        return true
    end

    view:SetSection("overview")
    return view
end

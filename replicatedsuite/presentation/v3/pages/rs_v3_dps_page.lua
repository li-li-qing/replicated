------------------------------------------------------------------------
-- Replicated Suite V3 - DPS Page
--
-- Rich live projection for combat statistics. Presentation consumes only DPS
-- Feature Projection/Commands; no native combat/target API is read here.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI, D = S.RSUI, S.UIV3Design
local PageHost = S.UIV3 and S.UIV3.PageHost or nil
local WidgetHost = S.UIV3 and S.UIV3.WidgetHost or nil
local Feature = S.Features and S.Features.DPS or nil
if type(RSUI) ~= "table" or type(D) ~= "table" or type(PageHost) ~= "table" or type(WidgetHost) ~= "table" or type(Feature) ~= "table" then return end

local FEATURE_ID, STORE_ID = "combat_stats", "v3.dps"
local CLEAR_CONFIRM_TASK = "v3_dps_clear_confirm_expire"
local function Settings() return Feature:GetSettingsProjection() end

local function N(value) return math.max(0, math.floor((tonumber(value) or 0) + 0.5)) end
local function ModeText(value) return tostring(value or "PVE") == "PVP" and "PVP" or "PVE" end
local function MetricText(value)
    value = tostring(value or "damage")
    if value == "taken" then return "承伤" end
    if value == "heal" then return "治疗" end
    return "伤害"
end
local function CompactNumber(value)
    local n = tonumber(value) or 0
    local abs = math.abs(n)
    if abs < 1000 then return tostring(math.floor(n + 0.5)) end
    if abs >= 1000000000 then return string.format(abs >= 100000000000 and "%.0fB" or "%.1fB", n / 1000000000) end
    if abs >= 1000000 then return string.format(abs >= 100000000 and "%.0fM" or "%.1fM", n / 1000000) end
    return string.format(abs >= 100000 and "%.0fK" or "%.1fK", n / 1000)
end
local function TotalsText(label, projected, shownRows)
    projected = type(projected) == "table" and projected or {}
    local totals = type(projected.totals) == "table" and projected.totals or {}
    local shown = math.max(0, tonumber(shownRows) or #(projected.rows or {}))
    local total = math.max(0, tonumber(projected.totalRows) or shown)
    local suffix = total > shown and (" · 显示 " .. tostring(shown) .. "/" .. tostring(total)) or ""
    return tostring(label) .. " · 伤 " .. CompactNumber(totals.damage)
        .. " · 承 " .. CompactNumber(totals.taken)
        .. " · 治 " .. CompactNumber(totals.heal)
        .. " · 单位 " .. tostring(N(totals.actorCount)) .. suffix
end

local function RankingColumns()
    return {
        { id = "rank", title = "#", field = "rank", size = "fixed", width = 30, minWidth = 26, sortable = false,
            getTone = function(row) return row.self == true and "accent" or "default" end },
        { id = "name", title = "单位", field = "name", size = "fill", minWidth = 86, fill = 1 },
        { id = "damage", title = "伤害", field = "damage", size = "fixed", width = 68, minWidth = 48,
            format = CompactNumber, getTone = function() return "red" end },
        { id = "dps", title = "DPS", field = "dps", size = "fixed", width = 56, minWidth = 42, format = CompactNumber },
        { id = "taken", title = "承伤", field = "taken", size = "fixed", width = 64, minWidth = 48, format = CompactNumber },
        { id = "heal", title = "治疗", field = "heal", size = "fixed", width = 64, minWidth = 48,
            format = CompactNumber, getTone = function() return "green" end },
    }
end

local function CounterpartColumns(nameTitle)
    return {
        { id = "rank", title = "#", field = "rank", size = "fixed", width = 28, minWidth = 24, sortable = false },
        { id = "name", title = nameTitle, field = "name", size = "fill", minWidth = 90, fill = 1 },
        { id = "amount", title = "数值", field = "amount", size = "fixed", width = 78, minWidth = 60, format = CompactNumber },
        { id = "events", title = "次数", field = "events", size = "fixed", width = 52, minWidth = 44 },
    }
end

local function AbilityColumns()
    return {
        { id = "icon", title = "", field = "iconPath", cellType = "icon", iconSize = 18, fallbackIcon = "ui/icon/icon_unknown_item.dds",
            size = "fixed", width = 26, minWidth = 24, sortable = false, resizable = false },
        { id = "name", title = "技能", field = "name", size = "fill", minWidth = 88, fill = 1 },
        { id = "skillId", title = "技能ID", field = "skillIdText", size = "fixed", width = 62, minWidth = 52 },
        { id = "amount", title = "数值", field = "amount", size = "fixed", width = 70, minWidth = 56, format = CompactNumber },
        { id = "share", title = "占比", field = "shareText", size = "fixed", width = 50, minWidth = 44 },
        { id = "events", title = "次数", field = "events", size = "fixed", width = 46, minWidth = 40 },
    }
end

local function CopyAndSortRows(source, sortState, limit)
    local rows = {}
    for _, row in ipairs(type(source) == "table" and source or {}) do
        local copy = {}
        for key, value in pairs(row) do copy[key] = value end
        rows[#rows + 1] = copy
    end
    sortState = type(sortState) == "table" and sortState or {}
    local columnId = tostring(sortState.columnId or "")
    local direction = tostring(sortState.direction or "desc")
    if columnId ~= "" and direction ~= "none" then
        local sign = direction == "asc" and 1 or -1
        table.sort(rows, function(a, b)
            local av, bv
            if columnId == "name" then
                av, bv = tostring(a.name or a.key or ""), tostring(b.name or b.key or "")
                if av ~= bv then return sign > 0 and av < bv or av > bv end
            else
                av, bv = tonumber(a[columnId]) or 0, tonumber(b[columnId]) or 0
                if av ~= bv then return sign > 0 and av < bv or av > bv end
            end
            return tostring(a.name or a.key or "") < tostring(b.name or b.key or "")
        end)
    end
    limit = math.max(1, math.floor(tonumber(limit) or #rows))
    while #rows > limit do rows[#rows] = nil end
    for index, row in ipairs(rows) do row.rank = index end
    return rows
end

local function PendingRows(projected, metric)
    local rows = {}
    for _, row in ipairs(type(projected) == "table" and projected.rows or {}) do
        rows[#rows + 1] = {
            rank = tonumber(row.rank) or (#rows + 1),
            name = tostring(row.name or row.key or "未知单位"),
            amount = math.max(0, tonumber(row.metricValue or row[metric]) or 0),
            events = math.max(0, tonumber(row.events) or 0),
        }
    end
    return rows
end

local function Build(parent, route)
    local root, rootErr = D:PageRoot(parent, "v3_page_dps")
    if root == nil then error("DPS PageRoot 创建失败：" .. tostring(rootErr or "unknown")) end
    root.route = route
    root.subscribed = false
    root.clearConfirmUntil = 0
    root.selectedBoss = ""
    root.lastBossToken = ""
    root.selectedActorKey = nil
    root.selectedSide = nil
    root.pendingView = false
    root.rankingRows = { friendly = {}, enemy = {} }
    root.rankingSort = { friendly = { columnId = "damage", direction = "desc" }, enemy = { columnId = "damage", direction = "desc" } }
    root.lastMetric = nil

    D:PageHeader(root, "v3_dps_header", "伤害统计",
        "逐事件统计伤害、DPS、承伤与治疗；PVP/PVE 独立归类。点击排行单位可查看技能与目标/来源明细。")

    local function NowMs() return math.max(0, tonumber(S.NowMs and S.NowMs()) or 0) end
    local clear
    local function RefreshClearButton()
        local confirming = (tonumber(root.clearConfirmUntil) or 0) >= NowMs()
        if clear ~= nil then clear:SetText(confirming and "再次点击确认清空" or "清空统计") end
        return confirming
    end

    local top = RSUI:HorizontalBox({ id = "v3_dps_top", parent = root, gap = 8,
        slot = { size = "fixed", height = 34, hAlign = "fill" } })
    local enableBtn = RSUI:Button({ id = "v3_dps_enable", parent = top, text = "启用伤害统计", compact = true,
        slot = { size = "fixed", width = 124 } })
    -- FloatingSurface already owns logical id `v3_dps_widget`.  Page controls
    -- must never alias a floating root because V3 component IDs are ownership
    -- identities, not labels.
    local showWidget = RSUI:Button({ id = "v3_dps_widget_toggle", parent = top, text = "显示悬浮窗", compact = true,
        slot = { size = "fixed", width = 110 } })
    clear = RSUI:Button({ id = "v3_dps_clear", parent = top, text = "清空统计", compact = true,
        slot = { size = "fixed", width = 106 } })
    local pendingBtn = RSUI:Button({ id = "v3_dps_pending_view", parent = top, text = "查看待确认", compact = true,
        slot = { size = "fixed", width = 104 } })
    local advancedBtn = RSUI:Button({ id = "v3_dps_advanced_toggle", parent = top, text = "展开高级", compact = true,
        slot = { size = "fixed", width = 88 } })
    local healthText = RSUI:Text({ id = "v3_dps_health", parent = top, text = "--", fontSize = 9, tone = "muted",
        overflow = "ellipsis", slot = { size = "fill", fill = 1 } })

    -- NumericField gets its own row so label/hint can never share the slider's
    -- native hit box. This is intentionally not a compact 34px toolbar control.
    local settings = RSUI:VerticalBox({ id = "v3_dps_settings", parent = root, gap = 5,
        slot = { size = "auto", hAlign = "fill" } })
    local settingsTop = RSUI:HorizontalBox({ id = "v3_dps_settings_top", parent = settings, gap = 6,
        slot = { size = "fixed", height = 36, hAlign = "fill" } })
    local settingsRows = RSUI:HorizontalBox({ id = "v3_dps_settings_rows", parent = settings, gap = 6,
        slot = { size = "auto", hAlign = "fill" } })

    local modeToggle = RSUI:Toggle({
        id = "v3_dps_mode", parent = settingsTop, onText = "统计模式：PVE", offText = "统计模式：PVP",
        get = function() return Settings().mode == "PVE" end,
        set = function(v) return Feature.Commands:ApplySettingFromBinding("mode", v and "PVE" or "PVP") end,
        storeId = STORE_ID, persistDelayMs = 300, persistReason = "dps_mode",
        slot = { size = "fixed", width = 150 },
    })
    local metricSelector, metricSelectorErr = RSUI:SegmentedSelector({
        id = "v3_dps_metric", parent = settingsTop, itemWidth = 50, gap = 2,
        items = {
            { value = "damage", text = "伤害" },
            { value = "taken", text = "承伤" },
            { value = "heal", text = "治疗" },
        },
        get = function() return Settings().metric or "damage" end,
        set = function(v) return Feature.Commands:ApplySettingFromBinding("metric", v) end,
        storeId = STORE_ID, persistDelayMs = 300, persistReason = "dps_metric",
        slot = { size = "fixed", width = 154 },
    })
    if metricSelector == nil then error("DPS 排序选择器创建失败：" .. tostring(metricSelectorErr or "unknown")) end
    local sideToggle = RSUI:Toggle({
        id = "v3_dps_side", parent = settingsTop, onText = "悬浮：敌方", offText = "悬浮：友方",
        get = function() return Settings().side == "enemy" end,
        set = function(v) return Feature.Commands:ApplySettingFromBinding("side", v and "enemy" or "friendly") end,
        storeId = STORE_ID, persistDelayMs = 300, persistReason = "dps_side",
        slot = { size = "fixed", width = 130 },
    })
    local selfToggle = RSUI:Toggle({
        id = "v3_dps_self", parent = settingsTop, onText = "始终显示自己：开", offText = "始终显示自己：关",
        get = function() return Settings().alwaysShowSelf == true end,
        set = function(v) return Feature.Commands:ApplySettingFromBinding("alwaysShowSelf", v == true) end,
        storeId = STORE_ID, persistDelayMs = 300, persistReason = "dps_self",
        slot = { size = "fill", fill = 1 },
    })
    local rows = D:NumericSetting(settingsRows, {
        id = "v3_dps_rows", label = "显示行数", hint = "仅限制页面和悬浮窗显示；后台累计不截断，上限 150 名。",
        min = 1, max = 150, step = 1, integer = true, unit = " 名", slider = true, stepButtons = false,
        get = function() return Settings().displayRows end,
        set = function(v) return Feature.Commands:ApplySettingFromBinding("displayRows", v) end,
        storeId = STORE_ID, persistDelayMs = 300, persistReason = "dps_rows",
        slot = { size = "fill", fill = 1, hAlign = "fill" },
    })
    root.advancedVisible = false
    settingsRows:SetVisible(false)

    local body = RSUI:VerticalBox({ id = "v3_dps_body", parent = root, gap = 6,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" } })
    -- At 1024x768, stacking friendly/enemy/detail as three vertical regions
    -- starves the ranking tables. Keep both sides visible horizontally and give
    -- the remaining vertical budget to rows + drill-down details.
    local rankings = RSUI:HorizontalBox({ id = "v3_dps_rankings", parent = body, gap = 6,
        slot = { size = "fill", fill = 1.35, hAlign = "fill", vAlign = "fill" } })

    local friendlyPanel, enemyPanel
    local function RankingPanel(id, title, side)
        local panel = RSUI:Border({ id = id .. "_panel", parent = rankings, padding = 5, variant = "card",
            slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" } })
        local stack = RSUI:VerticalBox({ id = id .. "_stack", parent = panel, gap = 3 })
        local summary = RSUI:Text({ id = id .. "_summary", parent = stack, text = title .. " · 尚无数据",
            fontSize = 10, tone = "strong", overflow = "ellipsis", slot = { size = "fixed", height = 20 } })
        local tableView = RSUI:TableView({
            id = id .. "_table", parent = stack, items = {}, rowHeight = 22, headerHeight = 22, desiredRows = 6,
            scrollbar = true, selectable = true, selectionMode = "single", columnResize = true, headerInteractive = true, columns = RankingColumns(),
            onSortChanged = function(columnId, direction, view)
                if type(root.ApplyRankingSort) == "function" then return root:ApplyRankingSort(side, columnId, direction, view) end
                return false
            end,
            onSelectionChanged = function(index)
                if index ~= nil and type(root.SelectActor) == "function" then root:SelectActor(side, index) end
            end,
            slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
        })
        return { panel = panel, summary = summary, table = tableView }
    end

    friendlyPanel = RankingPanel("v3_dps_friendly", "友方/自己", "friendly")
    enemyPanel = RankingPanel("v3_dps_enemy", "敌方/目标", "enemy")

    local detailPanel = RSUI:Border({ id = "v3_dps_detail_panel", parent = body, padding = 5, variant = "card",
        slot = { size = "fill", fill = 0.85, hAlign = "fill", vAlign = "fill" } })
    local detailStack = RSUI:VerticalBox({ id = "v3_dps_detail_stack", parent = detailPanel, gap = 3 })
    local detailSummary = RSUI:Text({ id = "v3_dps_detail_summary", parent = detailStack,
        text = "明细：点击上方任意单位", fontSize = 10, tone = "strong", overflow = "ellipsis",
        slot = { size = "fixed", height = 20 } })
    local detailTables = RSUI:HorizontalBox({ id = "v3_dps_detail_tables", parent = detailStack, gap = 6,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" } })
    local abilityTable = RSUI:TableView({
        id = "v3_dps_ability_table", parent = detailTables, items = {}, rowHeight = 21, headerHeight = 22, desiredRows = 5,
        scrollbar = true, selectable = false, columnResize = true, columns = AbilityColumns(),
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })
    local counterpartTable = RSUI:TableView({
        id = "v3_dps_counterpart_table", parent = detailTables, items = {}, rowHeight = 21, headerHeight = 22, desiredRows = 5,
        scrollbar = true, selectable = false, columnResize = true, columns = CounterpartColumns("目标/来源"),
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })
    local pendingModeTable = RSUI:TableView({
        id = "v3_dps_pending_mode_table", parent = detailTables, items = {}, rowHeight = 21, headerHeight = 22, desiredRows = 5,
        scrollbar = true, selectable = false, columnResize = true, columns = CounterpartColumns("模式未定单位"),
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })
    local pendingSideTable = RSUI:TableView({
        id = "v3_dps_pending_side_table", parent = detailTables, items = {}, rowHeight = 21, headerHeight = 22, desiredRows = 5,
        scrollbar = true, selectable = false, columnResize = true, columns = CounterpartColumns("阵营未定单位"),
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })
    pendingModeTable:SetVisible(false)
    pendingSideTable:SetVisible(false)

    local statusPanel = RSUI:Border({ id = "v3_dps_status_panel", parent = body, padding = 5, variant = "card",
        slot = { size = "fixed", height = 102, hAlign = "fill" } })
    local statusStack = RSUI:VerticalBox({ id = "v3_dps_status_stack", parent = statusPanel, gap = 2 })
    local coverageText = RSUI:Text({ id = "v3_dps_coverage", parent = statusStack, text = "覆盖：--", fontSize = 9,
        tone = "muted", overflow = "ellipsis", slot = { size = "fixed", height = 18 } })
    local unresolvedText = RSUI:Text({ id = "v3_dps_unresolved", parent = statusStack, text = "待确认保留：0",
        fontSize = 9, tone = "muted", overflow = "wrap", slot = { size = "fixed", height = 30 } })
    local busText = RSUI:Text({ id = "v3_dps_bus_health", parent = statusStack, text = "事件总线：--",
        fontSize = 9, tone = "muted", overflow = "ellipsis", slot = { size = "fixed", height = 18 } })
    local relationText = RSUI:Text({ id = "v3_dps_relation_health", parent = statusStack, text = "关系/团队：--",
        fontSize = 9, tone = "muted", overflow = "ellipsis", slot = { size = "fixed", height = 18 } })

    local bossPanel = RSUI:VerticalBox({ id = "v3_dps_boss_panel", parent = root, gap = 4,
        slot = { size = "fixed", height = 66, hAlign = "fill" } })
    local bossAddRow = RSUI:HorizontalBox({ id = "v3_dps_boss_add_row", parent = bossPanel, gap = 6,
        slot = { size = "fixed", height = 29, hAlign = "fill" } })
    local bossInput, bossInputErr = RSUI:TextInput({ id = "v3_dps_boss_input", parent = bossAddRow, value = "", maxLength = 64, buildOptional = true,
        allowEmpty = true, submitOnLostFocus = false,
        onSubmit = function(value)
            if type(root.AddBossFromInput) == "function" then return root:AddBossFromInput(value) end
            return false
        end,
        slot = { size = "fill", fill = 1, hAlign = "fill" } })
    local bossInputAvailable = bossInput ~= nil
    if bossInputAvailable ~= true then
        -- X2_EDITBOX/EDITBOX is optional on ArcheRage RU builds. Manual Boss
        -- name entry may degrade, but a missing optional text field must never
        -- abort construction of the whole DPS page.
        bossInput = RSUI:Text({ id = "v3_dps_boss_input_unavailable", parent = bossAddRow,
            text = "当前客户端文本输入框不可用", fontSize = 9, tone = "warn", overflow = "ellipsis",
            slot = { size = "fill", fill = 1, hAlign = "fill" } })
        if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.WarningRateLimited) == "function" then
            S.DiagnosticsManager:WarningRateLimited("dps_v3", "DPS_BOSS_TEXT_INPUT_UNAVAILABLE", 5000,
                "DPS 首领名称输入框不可用；页面已降级继续打开", { error = tostring(bossInputErr or "native editbox unavailable") })
        end
    end
    local addBoss = RSUI:Button({ id = "v3_dps_boss_add", parent = bossAddRow, text = "添加首领名称", compact = true,
        enabled = bossInputAvailable, slot = { size = "fixed", width = 112 } })
    local bossManageRow = RSUI:HorizontalBox({ id = "v3_dps_boss_manage_row", parent = bossPanel, gap = 6,
        slot = { size = "fixed", height = 29, hAlign = "fill" } })
    local bossSummary = RSUI:Text({ id = "v3_dps_boss_summary", parent = bossManageRow, text = "首领标记：无", fontSize = 9,
        tone = "muted", overflow = "ellipsis", slot = { size = "fill", fill = 1 } })
    local bossDropdown, bossDropdownErr = RSUI:Dropdown({
        id = "v3_dps_boss_dropdown", parent = bossManageRow, items = {}, value = "", maxVisible = 8,
        get = function() return root.selectedBoss end,
        set = function(v) root.selectedBoss = tostring(v or ""); return true end,
        onChanged = function(value)
            root.selectedBoss = tostring(value or "")
            if type(root.RefreshBossList) == "function" then root:RefreshBossList() end
        end,
        slot = { size = "fixed", width = 190 },
    })
    if bossDropdown == nil then error("DPS Boss 下拉框创建失败：" .. tostring(bossDropdownErr or "unknown")) end
    local removeBoss = RSUI:Button({ id = "v3_dps_boss_remove", parent = bossManageRow, text = "移除首领标记", compact = true,
        slot = { size = "fixed", width = 112 } })
    statusPanel:SetVisible(false)
    bossPanel:SetVisible(false)

    function root:SetAdvancedVisible(visible)
        self.advancedVisible = visible == true
        settingsRows:SetVisible(self.advancedVisible)
        statusPanel:SetVisible(self.advancedVisible)
        bossPanel:SetVisible(self.advancedVisible)
        advancedBtn:SetText(self.advancedVisible and "收起高级" or "展开高级")
        return true
    end

    function root:RefreshBossList()
        local names = Feature:GetBossNames() or {}
        local tokenParts, items = {}, {}
        local found = false
        for _, name in ipairs(names) do
            local text = tostring(name or "")
            if text ~= "" then
                tokenParts[#tokenParts + 1] = text
                items[#items + 1] = { value = text, text = text }
                if text == self.selectedBoss then found = true end
            end
        end
        local token = table.concat(tokenParts, "\31")
        if token ~= self.lastBossToken then
            self.lastBossToken = token
            if found ~= true then self.selectedBoss = items[1] and tostring(items[1].value) or "" end
            bossDropdown:SetItems(items)
            bossDropdown:Render()
        end
        bossSummary:SetText(#items == 0 and "首领标记：无" or ("首领标记 " .. tostring(#items) .. " 个 · 已选：" .. tostring(self.selectedBoss)))
        removeBoss:SetEnabled(self.selectedBoss ~= "")
        return true
    end

    function root:ApplyRankingSort(side, columnId, direction, view)
        side = side == "enemy" and "enemy" or "friendly"
        columnId = tostring(columnId or "")
        direction = tostring(direction or "none")
        -- Ranking headers use a two-state sort. Generic TableView cycles
        -- asc -> desc -> none; on the third state it reports columnId=nil. A
        -- ranking cannot have a meaningful unsorted state, so interpret that
        -- transition as ascending on the previous column. The next click then
        -- becomes descending again: desc <-> asc with visible feedback.
        if direction == "none" then
            local previous = type(self.rankingSort[side]) == "table" and self.rankingSort[side].columnId or nil
            columnId = tostring(previous or Settings().metric or "damage")
            direction = "asc"
            if view ~= nil and type(view.SetSortState) == "function" then
                view:SetSortState(columnId, direction, false)
            end
        end
        if columnId == "damage" or columnId == "taken" or columnId == "heal" then
            local settingsValue = Settings()
            if tostring(settingsValue.metric or "damage") ~= columnId then
                local ok, err = Feature.Commands:SetMetric(columnId)
                if ok ~= true then return false, err end
                self.rankingSort.friendly = { columnId = columnId, direction = "desc" }
                self.rankingSort.enemy = { columnId = columnId, direction = "desc" }
                friendlyPanel.table:SetSortState(columnId, "desc", false)
                enemyPanel.table:SetSortState(columnId, "desc", false)
                return self:RefreshStats()
            end
        end
        self.rankingSort[side] = { columnId = columnId ~= "" and columnId or nil, direction = direction }
        return self:RefreshStats()
    end

    function root:SelectActor(side, index)
        local list = self.rankingRows[side] or {}
        local row = list[index]
        if row == nil then return false end
        self.pendingView = false
        pendingBtn:SetText("查看待确认")
        self.selectedSide = side
        self.selectedActorKey = row.key
        if side == "friendly" and enemyPanel.table ~= nil then enemyPanel.table:ClearSelection() end
        if side == "enemy" and friendlyPanel.table ~= nil then friendlyPanel.table:ClearSelection() end
        return self:RefreshDetail()
    end

    function root:RefreshDetail()
        local settingsValue = Settings()
        if self.pendingView == true then
            abilityTable:SetVisible(false)
            counterpartTable:SetVisible(false)
            pendingModeTable:SetVisible(true)
            pendingSideTable:SetVisible(true)
            pendingBtn:SetText("返回单位明细")
            local projection = Feature:GetProjection({
                mode = settingsValue.mode, metric = settingsValue.metric, displayRows = settingsValue.displayRows,
            })
            local p = projection.projection or {}
            local sides = type(p.sides) == "table" and p.sides or {}
            local unresolved = type(p.unresolved) == "table" and p.unresolved or {}
            local sideUnknown = type(sides.unknown) == "table" and sides.unknown or {}
            local token = tostring(p.revision or 0) .. ":" .. tostring(p.mode or "") .. ":" .. tostring(p.metric or "")
            pendingModeTable:SetItems(PendingRows(unresolved, p.metric), "dps:pending:mode:" .. token)
            pendingSideTable:SetItems(PendingRows(sideUnknown, p.metric), "dps:pending:side:" .. token)
            detailSummary:SetText("待确认明细 · " .. ModeText(settingsValue.mode) .. " · 按" .. MetricText(settingsValue.metric)
                .. "排序 · 左：PVP/PVE 模式未定 · 右：阵营未定（数据均已保留，不代表丢失）")
            return true
        end

        abilityTable:SetVisible(true)
        counterpartTable:SetVisible(true)
        pendingModeTable:SetVisible(false)
        pendingSideTable:SetVisible(false)
        pendingBtn:SetText("查看待确认")
        local key = tostring(self.selectedActorKey or "")
        if key == "" or self.selectedSide == nil then
            detailSummary:SetText("明细：点击上方任意单位，或点击“查看待确认”检查未决数据")
            abilityTable:SetItems({}, "dps:detail:empty")
            counterpartTable:SetItems({}, "dps:detail:empty")
            return true
        end
        local detail = Feature:GetActorDetail({
            mode = settingsValue.mode, side = self.selectedSide, metric = settingsValue.metric, actorKey = key, limit = 100,
        })
        local actor = detail and detail.actor or nil
        if actor == nil then
            self.selectedActorKey, self.selectedSide = nil, nil
            detailSummary:SetText("明细：所选单位已不在当前模式/排序中")
            abilityTable:SetItems({}, "dps:detail:missing")
            counterpartTable:SetItems({}, "dps:detail:missing")
            return true
        end
        local metricText = MetricText(detail.metric)
        detailSummary:SetText("明细 · " .. tostring(actor.name or actor.key) .. " · " .. ModeText(settingsValue.mode)
            .. " · " .. (self.selectedSide == "enemy" and "敌方" or "友方") .. " · " .. metricText
            .. " " .. CompactNumber(actor[detail.metric]))
        local token = tostring(detail.revision or 0) .. ":" .. tostring(actor.key) .. ":" .. tostring(detail.metric)
        local abilityRows = type(detail.abilities) == "table" and detail.abilities or {}
        local metricTotal = math.max(0, tonumber(actor[detail.metric]) or 0)
        for _, row in ipairs(abilityRows) do
            local skillId = tonumber(row.skillId or row.abilityId)
            row.skillIdText = skillId ~= nil and tostring(math.floor(skillId + 0.5)) or "—"
            row.iconPath = tostring(row.iconPath or "ui/icon/icon_unknown_item.dds")
            row.shareText = metricTotal > 0 and string.format("%.1f%%", (math.max(0, tonumber(row.amount) or 0) / metricTotal) * 100) or "0%"
        end
        abilityTable:SetItems(abilityRows, "dps:ability:" .. token)
        counterpartTable:SetItems(type(detail.counterparts) == "table" and detail.counterparts or {}, "dps:counterpart:" .. token)
        return true
    end

    function root:RefreshStats()
        local settingsValue = Settings()
        -- Fetch the bounded full ranking projection (Domain max 150) and apply
        -- view sorting before slicing to displayRows. This makes header sorting
        -- affect the whole visible ranking instead of only the previously cut set.
        local projection = Feature:GetProjection({ mode = settingsValue.mode, metric = settingsValue.metric, displayRows = 150 })
        local p = projection.projection or {}
        local sides = type(p.sides) == "table" and p.sides or {}
        local friendly = type(sides.friendly) == "table" and sides.friendly or {}
        local enemy = type(sides.enemy) == "table" and sides.enemy or {}
        local sideUnknown = type(sides.unknown) == "table" and sides.unknown or {}
        local unresolved = type(p.unresolved) == "table" and p.unresolved or {}
        if self.lastMetric ~= tostring(settingsValue.metric or "damage") then
            self.lastMetric = tostring(settingsValue.metric or "damage")
            self.rankingSort.friendly = { columnId = self.lastMetric, direction = "desc" }
            self.rankingSort.enemy = { columnId = self.lastMetric, direction = "desc" }
            friendlyPanel.table:SetSortState(self.lastMetric, "desc", false)
            enemyPanel.table:SetSortState(self.lastMetric, "desc", false)
        end
        self.rankingRows.friendly = CopyAndSortRows(friendly.rows, self.rankingSort.friendly, settingsValue.displayRows)
        self.rankingRows.enemy = CopyAndSortRows(enemy.rows, self.rankingSort.enemy, settingsValue.displayRows)
        local token = tostring(p.revision or 0) .. ":" .. tostring(p.mode or "") .. ":" .. tostring(p.metric or "")
        friendlyPanel.table:SetItems(self.rankingRows.friendly, "dps:f:" .. token)
        enemyPanel.table:SetItems(self.rankingRows.enemy, "dps:e:" .. token)
        local function SortLabel(sideName)
            local state = self.rankingSort[sideName] or {}
            local label = state.columnId == "name" and "名称" or (state.columnId == "dps" and "DPS" or MetricText(state.columnId or p.metric))
            return label .. (state.direction == "asc" and "↑" or "↓")
        end
        friendlyPanel.summary:SetText(TotalsText("友方/自己 · " .. SortLabel("friendly"), friendly, #self.rankingRows.friendly))
        enemyPanel.summary:SetText(TotalsText("敌方/目标 · " .. SortLabel("enemy"), enemy, #self.rankingRows.enemy))

        local coverage = tostring(projection.coverageState or "INACTIVE")
        coverageText:SetText("事件覆盖：" .. coverage .. (coverage == "FULL" and " · 完整" or " · 当前客户端事件源不是完整覆盖"))
        coverageText:SetTone(coverage == "FULL" and "muted" or "warn")
        local unresolvedTotals = type(unresolved.totals) == "table" and unresolved.totals or {}
        local sideUnknownTotals = type(sideUnknown.totals) == "table" and sideUnknown.totals or {}
        local h = projection.health or {}
        local unresolvedAmount = N(unresolvedTotals.damage) + N(unresolvedTotals.taken) + N(unresolvedTotals.heal)
            + N(sideUnknownTotals.damage) + N(sideUnknownTotals.taken) + N(sideUnknownTotals.heal)
        unresolvedText:SetText("待确认：模式未知[伤 " .. CompactNumber(unresolvedTotals.damage)
            .. "/承 " .. CompactNumber(unresolvedTotals.taken)
            .. "/治 " .. CompactNumber(unresolvedTotals.heal)
            .. "] · 阵营未知[伤 " .. CompactNumber(sideUnknownTotals.damage)
            .. "/承 " .. CompactNumber(sideUnknownTotals.taken)
            .. "/治 " .. CompactNumber(sideUnknownTotals.heal)
            .. "] · 技能代理未归属[治 " .. CompactNumber(h.proxySourceHealAmount)
            .. "/件 " .. tostring(N(h.proxySourceHeals))
            .. "] · Replay " .. tostring(N(h.pendingRows)) .. "/" .. tostring(N(h.pendingLedgerSlots))
            .. " · 淘汰 " .. tostring(N(h.pendingEvicted))
            .. " · 重分类 " .. tostring(N(h.replayReclassifications)))
        unresolvedText:SetTone((unresolvedAmount > 0 or N(h.proxySourceHealAmount) > 0 or N(h.pendingEvicted) > 0) and "warn" or "muted")
        busText:SetText("总线：Private " .. tostring(N(h.busPrivateRows))
            .. " · Global " .. tostring(N(h.busGlobalRows))
            .. " · Global SELF过滤 " .. tostring(N(h.busGlobalSelfFiltered))
            .. " · UI双Host去重 " .. tostring(N(h.busCrossHostDuplicates))
            .. " · 去重待配 " .. tostring(N(h.busCrossHostPending))
            .. " · 去重淘汰 " .. tostring(N(h.busCrossHostEvicted))
            .. " · Journal丢弃 " .. tostring(N(h.busJournalDropped))
            .. " · Fact修改 " .. tostring(N(h.busFactMutationErrors)))
        busText:SetTone((N(h.busJournalDropped) > 0 or N(h.busFactMutationErrors) > 0 or N(h.busCrossHostEvicted) > 0) and "warn" or "muted")
        relationText:SetText("关系：单位 " .. tostring(N(h.relationUnits))
            .. " · 未知 " .. tostring(N(h.relationUnknown))
            .. " · 证据 " .. tostring(N(h.relationEvidenceApplied))
            .. " · 冲突 " .. tostring(N(h.relationConflicts))
            .. " · 团队 " .. tostring(N(h.teamMembers))
            .. " · 扫描 " .. tostring(N(h.teamScans))
            .. " · 失败 " .. tostring(N(h.teamScanFailures))
            .. " · 重试 " .. tostring(N(h.teamRetries)))
        relationText:SetTone((N(h.relationConflicts) > 0 or N(h.teamScanFailures) > 0) and "warn" or "muted")

        enableBtn:SetText(projection.enabled == true and "停用伤害统计" or "启用伤害统计")
        local widgetVisible = WidgetHost:IsVisible("combat.dps") == true
        showWidget:SetText(widgetVisible and "隐藏悬浮窗" or "显示悬浮窗")
        showWidget:SetEnabled(projection.enabled == true)
        healthText:SetText(ModeText(settingsValue.mode) .. " · " .. MetricText(settingsValue.metric) .. "排序 · PVP " .. tostring(N(h.classificationPVP))
            .. " · PVE " .. tostring(N(h.classificationPVE)) .. " · 治疗 " .. tostring(N(h.classificationHeal))
            .. " · 未知 " .. tostring(N(h.classificationUnknown)) .. " · 事件 " .. tostring(N(h.events)))
        modeToggle:Render(); metricSelector:Render(); sideToggle:Render(); selfToggle:Render(); rows:Render()
        RefreshClearButton()
        self:RefreshDetail()
        return true
    end

    function root:Refresh()
        self:RefreshStats()
        self:RefreshBossList()
        return true
    end

    function root:Subscribe()
        if self.subscribed then return true end
        if S.Events and type(S.Events.SubscribeInternal) == "function" then
            S.Events:SubscribeInternal("v3.dps.updated", self, function() root:RefreshStats() end)
            S.Events:SubscribeInternal("v3.dps.settings", self, function(_, key)
                root:RefreshStats()
                if tostring(key or "") == "bossNames" then root:RefreshBossList() end
            end)
            S.Events:SubscribeInternal((S.FeatureRuntime and S.FeatureRuntime.LifecycleTopic) or "v3.feature.lifecycle", self,
                function(_, featureId) if tostring(featureId or "") == FEATURE_ID then root:RefreshStats() end end)
        end
        self.subscribed = true
        return true
    end

    function root:Unsubscribe()
        if not self.subscribed then return true end
        if S.Events and type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
        self.subscribed = false
        return true
    end

    function root:OnActivated()
        local ok, err = Feature:EnsureStoreLoaded()
        if ok ~= true then return false, err end
        self:Subscribe()
        return self:Refresh()
    end

    function root:OnDeactivated()
        self:Unsubscribe()
        self.clearConfirmUntil = 0
        if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then
            pcall(function() S.Scheduler:RemoveTask(CLEAR_CONFIRM_TASK) end)
        end
        RefreshClearButton()
        return true
    end

    enableBtn.spec.onClick = function()
        local projection = Feature:GetProjection({})
        local nextEnabled = not (projection and projection.enabled == true)
        return S.ActionRunner:Run({
            id = "dps.toggle", button = enableBtn, idleText = enableBtn.text, busyText = "处理中…", notify = true,
            successText = function() return nextEnabled and "伤害统计已启用。" or "伤害统计已停用；本次统计数据已保留。" end,
            errorText = function(reason) return tostring(reason or "状态切换失败") end,
            execute = function() return Feature.Commands:SetEnabled(nextEnabled, "dps_page") end,
            onSuccess = function() root:RefreshStats() end,
        })
    end

    advancedBtn.spec.onClick = function()
        return root:SetAdvancedVisible(not root.advancedVisible)
    end

    pendingBtn.spec.onClick = function()
        root.pendingView = root.pendingView ~= true
        if root.pendingView == true then
            if friendlyPanel.table ~= nil then friendlyPanel.table:ClearSelection() end
            if enemyPanel.table ~= nil then enemyPanel.table:ClearSelection() end
        end
        return root:RefreshDetail()
    end

    showWidget.spec.onClick = function()
        local nextVisible = not (WidgetHost:IsVisible("combat.dps") == true)
        return S.ActionRunner:Run({
            id = "dps.widget_visibility", button = showWidget, idleText = showWidget.text, busyText = "处理中…", notify = true,
            successText = function() return nextVisible and "DPS 悬浮窗已显示。" or "DPS 悬浮窗已隐藏。" end,
            errorText = function(reason) return tostring(reason or "悬浮窗切换失败") end,
            execute = function()
                if S.FeatureRuntime:IsEnabled(FEATURE_ID) ~= true then return false, "请先启用伤害统计" end
                return WidgetHost:SetVisible("combat.dps", nextVisible, { source = "dps_page", persist = false })
            end,
            onSuccess = function() root:RefreshStats() end,
        })
    end

    clear.spec.onClick = function()
        local now = NowMs()
        if (tonumber(root.clearConfirmUntil) or 0) < now then
            root.clearConfirmUntil = now + 5000
            RefreshClearButton()
            if S.Scheduler ~= nil and type(S.Scheduler.AddOneShot) == "function" then
                S.Scheduler:AddOneShot(CLEAR_CONFIRM_TASK, 5050, function()
                    root.clearConfirmUntil = 0
                    RefreshClearButton()
                    return true
                end, root, "P3", 1)
            end
            return true
        end
        root.clearConfirmUntil = 0
        return S.ActionRunner:Run({
            id = "dps.clear", button = clear, idleText = clear.text, busyText = "清空中…", notify = true,
            successText = "DPS 统计已清空。", errorText = function(reason) return tostring(reason or "清空失败") end,
            execute = function() return Feature.Commands:Clear("dps_page") end,
            onSuccess = function()
                root.selectedActorKey, root.selectedSide = nil, nil
                friendlyPanel.table:ClearSelection(); enemyPanel.table:ClearSelection()
                root:RefreshStats()
            end,
        })
    end

    function root:AddBossFromInput(submittedName)
        if bossInputAvailable ~= true then return false, "当前客户端不支持首领名称文本输入框" end
        local name = tostring(submittedName or "")
        if name == "" and type(bossInput.GetDraftValue) == "function" then name = bossInput:GetDraftValue() end
        if tostring(name or "") == "" then return false, "请输入首领名称" end
        return S.ActionRunner:Run({
            id = "dps.add_boss", button = addBoss, idleText = addBoss.text, busyText = "添加中…", notify = true,
            successText = "已添加首领名称。", errorText = function(reason) return tostring(reason or "添加失败") end,
            execute = function() return Feature.Commands:AddBossName(name) end,
            onSuccess = function()
                if type(bossInput.SetValue) == "function" then bossInput:SetValue("", false, "boss_added") end
                root.lastBossToken = ""
                root:RefreshBossList(); root:RefreshStats()
            end,
        })
    end
    -- Button and Enter share the TextInput Submit path so a focused EditBox
    -- commits the live draft before AddBossFromInput reads it.
    addBoss.spec.onClick = function()
        if bossInputAvailable ~= true or type(bossInput.Submit) ~= "function" then
            return false, "当前客户端不支持首领名称文本输入框"
        end
        return bossInput:Submit("button")
    end

    removeBoss.spec.onClick = function()
        local selected = tostring(root.selectedBoss or "")
        return S.ActionRunner:Run({
            id = "dps.remove_boss", button = removeBoss, idleText = removeBoss.text, busyText = "处理中…", notify = true,
            successText = "已移除首领标记。", errorText = function(reason) return tostring(reason or "移除失败") end,
            execute = function()
                if selected == "" then return false, "请先选择首领标记" end
                return Feature.Commands:RemoveBossName(selected)
            end,
            onSuccess = function()
                root.selectedBoss = ""
                root.lastBossToken = ""
                root:RefreshBossList(); root:RefreshStats()
            end,
        })
    end

    return root
end

local ok, err = PageHost:RegisterFactory("combat.stats", Build)
if ok ~= true then error(err) end

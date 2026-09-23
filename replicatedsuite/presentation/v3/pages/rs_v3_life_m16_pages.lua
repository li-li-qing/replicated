------------------------------------------------------------------------
-- Replicated Suite V3 - Life vertical-slice pages
------------------------------------------------------------------------
-- 维护（module-controls-diag-2）：总开关领取PageHost左上角的同一实例；原Feature/Consumer/保存回滚回调不变。
-- 只调整呈现归属，禁止在刷新中另造开关状态、重设Native父级或绑定第二个OnClick；局部选项开关保持原位。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI, D = S.RSUI, S.UIV3Design
local Host = S.UIV3 and S.UIV3.PageHost or nil
local WidgetHost = S.UIV3 and S.UIV3.WidgetHost or nil
if type(RSUI) ~= "table" or type(D) ~= "table" or type(Host) ~= "table" or type(WidgetHost) ~= "table" then return end

local function Items(rows, label)
    local out = {}
    for _, row in ipairs(rows or {}) do out[#out + 1] = { value = row.id or row.key, text = tostring(label and label(row) or row.name or row.text or row.key) } end
    return out
end

local function ValidateFeatureContract(feature, kind)
    if type(feature) ~= "table" then return false, "生活功能实例缺失: " .. tostring(kind) end
    if type(feature.GetProjection) ~= "function" then return false, "生活功能缺少 GetProjection(): " .. tostring(kind) end
    if type(feature.AcquireConsumer) ~= "function" or type(feature.ReleaseConsumer) ~= "function" then
        return false, "生活功能 Consumer 契约不完整: " .. tostring(kind)
    end
    local commands = feature.Commands
    if type(commands) ~= "table" or type(commands.Refresh) ~= "function" then
        return false, "生活功能 Commands.Refresh 契约缺失: " .. tostring(kind)
    end
    if kind == "trade" then
        if type(feature.GetRouteSettings) ~= "function" or type(commands.SetFrom) ~= "function" or type(commands.SetTo) ~= "function"
            or type(commands.SetRatioMode) ~= "function" or type(commands.SetCommerceMode) ~= "function"
            or type(commands.SetViewMode) ~= "function" or type(commands.ToggleTrackedProduct) ~= "function" or type(commands.SetAutoRefresh) ~= "function"
            or type(commands.QuoteRowMaterials) ~= "function"
            or type(feature.GetWidgetVisible) ~= "function" or type(commands.SetWidgetVisible) ~= "function" then
            return false, "跑商页面 Feature 契约不完整"
        end
    elseif kind == "bonds" then
        if type(feature.GetSortMode) ~= "function" or type(feature.GetContinentOrder) ~= "function" or type(feature.GetBondFilter) ~= "function"
            or type(commands.SetSortMode) ~= "function" or type(commands.SetContinentOrder) ~= "function" or type(commands.SetBondFilterOption) ~= "function"
            or type(commands.SetDuplicatePriority) ~= "function" or type(feature.GetWidgetVisible) ~= "function"
            or type(commands.SetWidgetVisible) ~= "function" then
            return false, "债券页面 Feature 契约不完整"
        end
    elseif kind == "fishing" then
        if type(feature.IsAutoArmed) ~= "function" or type(commands.ArmAuto) ~= "function" or type(commands.DisarmAuto) ~= "function"
            or type(feature.GetWidgetVisible) ~= "function" or type(commands.SetWidgetVisible) ~= "function" then
            return false, "钓鱼页面 Feature 契约不完整"
        end
    elseif kind == "treasure" then
        if type(commands.Select) ~= "function" or type(feature.GetWidgetVisible) ~= "function" or type(commands.SetWidgetVisible) ~= "function" then return false, "寻宝页面 Feature 契约不完整" end
    else
        return false, "未知生活页面类型: " .. tostring(kind)
    end
    return true
end

local function Build(parent, route, feature, kind)
    -- Preflight the public Feature boundary before PageRoot allocates any Native
    -- controls. A missing facade must fail the build transaction cleanly instead
    -- of producing a half-built page that only explodes during OnActivated().
    local contractOk, contractErr = ValidateFeatureContract(feature, kind)
    if contractOk ~= true then return nil, contractErr end
    local root, err = D:PageRoot(parent, "v3_page_" .. tostring(kind))
    if root == nil then return nil, err end
    root.consumerHeld = false
    local title, subtitle = "", ""
    if kind == "trade" then title, subtitle = "跑商", "选择路线后查看实时货率与预计售价；单击选中货物，双击该行查询它的材料价格并自动计算毛利。"
    elseif kind == "bonds" then title, subtitle = "债券 / 居民板", "分别在西大陆、东大陆（以及原大陆）刷新一次即可保存当天快照；页面会合并显示已读取大陆，排序不会隐藏另一大陆。"
    elseif kind == "treasure" then title, subtitle = "寻宝", "直接扫描有限背包槽位中的藏宝图坐标，并在单位世界坐标可用时计算方向与距离。"
    else title, subtitle = "钓鱼", "按需识别目标鱼动作并可安全切换 R；关闭、切区、战斗恢复或重载时按持久恢复快照还原原键位。" end
    D:PageHeader(root, "v3_" .. kind .. "_header", title, subtitle, "刷新", function()
        local ok, refreshErr = feature.Commands:Refresh("page_manual")
        if ok == true then root:Refresh() end
        return ok, refreshErr
    end)
    local actionRow = RSUI:HorizontalBox({ id = "v3_" .. kind .. "_actions", parent = root, gap = 6, slot = { size = "fixed", height = 32, hAlign = "fill" } })
    local featureButton = D:ModuleToggleButton({ id = "v3_" .. kind .. "_toggle", parent = actionRow, text = "关闭功能", compact = true, slot = { size = "fixed", width = 96 } })
    local widgetButton = RSUI:Button({ id = "v3_" .. kind .. "_widget_toggle", parent = actionRow, text = "打开悬浮窗", compact = true, slot = { size = "fixed", width = 96 } })
    local status

    local tradeFrom, tradeTo, tradeFavoriteDropdown
    if kind == "trade" then
        -- Route selection is dropdown-only.  Keep origin/destination on separate
        -- rows so the controls remain usable at 1024-wide layouts without the
        -- old four cycle buttons consuming the entire horizontal budget.
        local tradeRouteBox = RSUI:VerticalBox({ id = "v3_trade_route_box", parent = root, gap = 4, slot = { size = "fixed", height = 64, hAlign = "fill" } })
        local fromRow = RSUI:HorizontalBox({ id = "v3_trade_from_row", parent = tradeRouteBox, gap = 6, slot = { size = "fixed", height = 30, hAlign = "fill" } })
        RSUI:Text({ id = "v3_trade_from_label", parent = fromRow, text = "起点", fontSize = 10, tone = "muted", slot = { size = "fixed", width = 52, hAlign = "fill" } })
        tradeFrom = RSUI:Dropdown({ id = "v3_trade_from", parent = fromRow, items = {}, maxVisible = 12, popupWidth = 300,
            placeholder = "选择起点", get = function() local state = feature:GetRouteSettings(); return state.fromZone end,
            set = function(value) return feature.Commands:SetFrom(value) end, slot = { size = "fill", fill = 1, minWidth = 160 } })

        local toRow = RSUI:HorizontalBox({ id = "v3_trade_to_row", parent = tradeRouteBox, gap = 6, slot = { size = "fixed", height = 30, hAlign = "fill" } })
        RSUI:Text({ id = "v3_trade_to_label", parent = toRow, text = "目的地", fontSize = 10, tone = "muted", slot = { size = "fixed", width = 52, hAlign = "fill" } })
        tradeTo = RSUI:Dropdown({ id = "v3_trade_to", parent = toRow, items = {}, maxVisible = 12, popupWidth = 300,
            placeholder = "选择目的地", get = function() local state = feature:GetRouteSettings(); return state.toZone end,
            set = function(value) return feature.Commands:SetTo(value) end, slot = { size = "fill", fill = 1, minWidth = 160 } })
        if tradeFrom == nil or tradeTo == nil then return nil, "跑商路线下拉框创建失败" end

        local favoriteRow = RSUI:HorizontalBox({ id = "v3_trade_favorite_row", parent = root, gap = 6, slot = { size = "fixed", height = 30, hAlign = "fill" } })
        RSUI:Text({ id = "v3_trade_favorite_label", parent = favoriteRow, text = "收藏", fontSize = 10, tone = "muted", slot = { size = "fixed", width = 52 } })
        tradeFavoriteDropdown = RSUI:Dropdown({ id = "v3_trade_favorite_dropdown", parent = favoriteRow, items = {}, maxVisible = 12, popupWidth = 360,
            placeholder = "选择已收藏路线", get = function() local projection = feature:GetProjection() or {}; return projection.currentRouteFavorite and projection.currentFavoriteKey or nil end,
            set = function(value) return feature.Commands:SelectFavorite(value) end, slot = { size = "fill", fill = 1, minWidth = 150 } })
        local tradeFavoriteButton = RSUI:Button({ id = "v3_trade_favorite_toggle", parent = favoriteRow, text = "收藏路线", compact = true, slot = { size = "fixed", width = 94 } })
        tradeFavoriteButton.onClick = function()
            local ok, favoriteErr = feature.Commands:ToggleCurrentFavorite()
            if ok == true then root:Refresh() end
            return ok, favoriteErr
        end
        -- Sort is one-of-many, not a two-state cycle: three segments share the
        -- same selected-state contract as DPS/HUD selectors.  The row has no
        -- fill headroom at 1024 logical width, so the selector reserves fixed
        -- space and the favorite dropdown fills the rest (minWidth 150).
        local tradeSortSelector = RSUI:SegmentedSelector({
            id = "v3_trade_sort_mode", parent = favoriteRow, itemWidth = 40, gap = 2, height = 26, fontSize = 9,
            items = {
                { value = "ratio", text = "货率" },
                { value = "price", text = "售价" },
                { value = "name", text = "名字" },
            },
            get = function() local projection = feature:GetProjection() or {}; return projection.sortMode or "ratio" end,
            set = function(value) return feature.Commands:SetSortMode(value) end,
            slot = { size = "fixed", width = 132, vAlign = "fill" },
        })
        if tradeSortSelector == nil then return nil, "跑商排序选择器创建失败" end
        root.tradeFavoriteButton, root.tradeSortSelector = tradeFavoriteButton, tradeSortSelector

        -- 维护（2026-09-23，trade-view-mode-ui-1）：服务器仍按路线返回整包货率；这里的“关注”只过滤本地
        -- Display Projection，避免对不关心的几十个货物做材料/利润重投影。“随身”由背部装备 ItemID Authority
        -- 驱动目的地串行扫描，不在 Presentation 读取 X2Equipment。
        local tradeViewRow = RSUI:HorizontalBox({ id = "v3_trade_view_row", parent = root, gap = 6, slot = { size = "fixed", height = 30, hAlign = "fill" } })
        RSUI:Text({ id = "v3_trade_view_label", parent = tradeViewRow, text = "显示", fontSize = 10, tone = "muted", slot = { size = "fixed", width = 52 } })
        local tradeViewSelector = RSUI:SegmentedSelector({
            id = "v3_trade_view_mode", parent = tradeViewRow, itemWidth = 82, gap = 2, height = 26, fontSize = 9,
            items = { { value = "all", text = "全部货物" }, { value = "tracked", text = "关注货物" }, { value = "cargo", text = "随身贸易包" } },
            get = function() local projection = feature:GetProjection() or {}; return projection.viewMode or "all" end,
            set = function(value) return feature.Commands:SetViewMode(value) end,
            slot = { size = "fixed", width = 252, vAlign = "fill" },
        })
        local tradeAutoRefreshButton = RSUI:Button({ id = "v3_trade_auto_refresh", parent = tradeViewRow, text = "自动刷新：开", compact = true, slot = { size = "fixed", width = 104 } })
        tradeAutoRefreshButton.onClick = function()
            local projection = feature:GetProjection() or {}
            local ok, commandErr = feature.Commands:SetAutoRefresh(projection.autoRefresh ~= true)
            if ok == true then root:Refresh() end
            return ok, commandErr
        end
        local tradeViewHint = RSUI:Text({ id = "v3_trade_view_hint", parent = tradeViewRow, text = "", fontSize = 9, tone = "muted", overflow = "ellipsis", slot = { size = "fill", fill = 1 } })
        root.tradeViewSelector, root.tradeAutoRefreshButton, root.tradeViewHint = tradeViewSelector, tradeAutoRefreshButton, tradeViewHint

        local tradeRatioModeButton = RSUI:Button({ id = "v3_trade_ratio_mode", parent = actionRow, text = "货率：实时", compact = true, slot = { size = "fixed", width = 94 } })
        tradeRatioModeButton.onClick = function()
            local projection = feature:GetProjection() or {}
            local ok, modeErr = feature.Commands:SetRatioMode(projection.ratioMode == "full" and "current" or "full")
            if ok == true then root:Refresh() end
            return ok, modeErr
        end
        local tradeCommerceModeButton = RSUI:Button({ id = "v3_trade_commerce_mode", parent = actionRow, text = "售价：计熟练", compact = true, slot = { size = "fixed", width = 108 } })
        tradeCommerceModeButton.onClick = function()
            local projection = feature:GetProjection() or {}
            local ok, modeErr = feature.Commands:SetCommerceMode(projection.commerceMode == "off" and "observe" or "off")
            if ok == true then root:Refresh() end
            return ok, modeErr
        end

        -- 维护（2026-09-23，trade-row-double-click-1）：取消“材料询价/扩大询价/取消询价”三套全列表按钮。
        -- 用户真正关心的是某一货物的毛利；全列表批量命令仍保留在 Feature 兼容边界，但普通页面不再暴露。
        -- 单击仅选择，详情由显式按钮打开，双击同一行才查询该货物材料，避免第一次点击弹窗截断双击手势。
        local tradeDetailButton = RSUI:Button({ id = "v3_trade_detail", parent = actionRow, text = "货物详情", compact = true, slot = { size = "fixed", width = 92 } })
        tradeDetailButton:SetEnabled(false)
        tradeDetailButton.onClick = function()
            local row = type(feature.GetSelectedRow) == "function" and feature:GetSelectedRow() or nil
            if row == nil or row.key == nil then return false, "请先单击选择一个货物" end
            local detail = S.UIV3 and S.UIV3.TradeDetailFloatingV3 or nil
            if type(detail) ~= "table" or type(detail.Open) ~= "function" then return false, "贸易品详情悬浮窗不可用" end
            return detail:Open(row.key)
        end
        -- 维护（2026-09-23，trade-track-direct-action-1）：关注货物是高频筛选动作，不应强迫玩家先打开详情窗。
        -- 按钮只消费 Feature 当前 selectedKey，并调用同一 ToggleTrackedProduct Command；关注 Store/ItemID Authority 不复制到 UI。
        local tradeTrackButton = RSUI:Button({ id = "v3_trade_track", parent = actionRow, text = "关注货物", compact = true, slot = { size = "fixed", width = 92 } })
        tradeTrackButton:SetEnabled(false)
        tradeTrackButton.onClick = function()
            local row = type(feature.GetSelectedRow) == "function" and feature:GetSelectedRow() or nil
            if row == nil or row.key == nil then return false, "请先单击选择一个货物" end
            local ok, trackErr = feature.Commands:ToggleTrackedProduct(row.itemType or row.key)
            if ok == true then root:Refresh() end
            return ok, trackErr
        end
        root.tradeInteractionHint = RSUI:Text({
            id = "v3_trade_interaction_hint", parent = root,
            text = "操作：单击选中 · 双击查询材料并计算毛利 · 可直接关注/取消关注货物",
            fontSize = 9, tone = "muted", overflow = "ellipsis", slot = { size = "fixed", height = 22, hAlign = "fill" },
        })
        root.tradeRatioModeButton, root.tradeCommerceModeButton, root.tradeDetailButton, root.tradeTrackButton = tradeRatioModeButton, tradeCommerceModeButton, tradeDetailButton, tradeTrackButton
    elseif kind == "bonds" then
        -- 中文维护注释（2026-09-15，债券控制语义重排）：旧版把排序、数量筛选、去重和“优先西”
        -- 全塞进通用 actionRow，既拥挤又把两个完全不同的概念混在一起。现在 actionRow 只保留功能/
        -- 悬浮窗/详情，债券专用选项放到独立一行：排序方式、大陆顺序、数量筛选、重复显示策略。
        -- 数据 Authority 不变，所有按钮仍只调用 Feature.Commands；1024 宽度下使用短标签避免挤压表格。
        local bondOptionsRow = RSUI:HorizontalBox({ id = "v3_bonds_options", parent = root, gap = 5, slot = { size = "fixed", height = 30, hAlign = "fill" } })
        local sortButton = RSUI:Button({ id = "v3_bonds_sort", parent = bondOptionsRow, text = "排序：按大陆", compact = true, slot = { size = "fixed", width = 104 } })
        root.bondSortButton = sortButton
        local runBondCommand = function(command)
            local ok, commandErr = command()
            if ok == true then root:Refresh() end
            return ok, commandErr
        end
        sortButton.onClick = function() return runBondCommand(function() return feature.Commands:SetSortMode(feature:GetSortMode() == "quantity" and "continent" or "quantity") end) end

        local continentOrderButton = RSUI:Button({ id = "v3_bonds_continent_order", parent = bondOptionsRow, text = "大陆：西→东", compact = true, slot = { size = "fixed", width = 104 } })
        continentOrderButton.onClick = function()
            return runBondCommand(function() return feature.Commands:SetContinentOrder(feature:GetContinentOrder() == "east_first" and "west_first" or "east_first") end)
        end
        root.bondContinentOrderButton = continentOrderButton

        local bondState = function() return feature:GetBondFilter() end
        local bondButton = function(id, text, key, width)
            local button = RSUI:Button({ id = id, parent = bondOptionsRow, text = text, compact = true, slot = { size = "fixed", width = width or 48 } })
            button.onClick = function() local state = bondState(); return runBondCommand(function() return feature.Commands:SetBondFilterOption(key, not state[key]) end) end
            return button
        end
        root.bondFilterButtons = {
            q20 = bondButton("v3_bonds_q20", "20", "q20", 42),
            q60 = bondButton("v3_bonds_q60", "60", "q60", 42),
            q100 = bondButton("v3_bonds_q100", "100", "q100", 46),
            auroria = bondButton("v3_bonds_auroria", "原陆", "auroria", 54),
            excludeSame = bondButton("v3_bonds_exclude", "重复：全部", "excludeSame", 92),
        }
        local priorityButton = RSUI:Button({ id = "v3_bonds_priority", parent = bondOptionsRow, text = "合并留西", compact = true, slot = { size = "fixed", width = 76 } })
        priorityButton.onClick = function() local state = bondState(); return runBondCommand(function() return feature.Commands:SetDuplicatePriority(state.priority == "west" and "east" or "west") end) end
        root.bondPriorityButton = priorityButton

        local detailButton = RSUI:Button({ id = "v3_bonds_detail", parent = actionRow, text = "查看详情", compact = true, slot = { size = "fixed", width = 84 } })
        detailButton.onClick = function()
            local selected = type(feature.GetSelectedRow) == "function" and feature:GetSelectedRow() or nil
            if selected == nil then return false, "请先选择一条居民板任务" end
            local floating = S.UIV3 and S.UIV3.QuestDetailFloatingV3 or nil
            if type(floating) == "table" and type(floating.Open) == "function" then
                return floating:Open("bonds", selected.key, selected)
            end
            return false, "任务详情浮窗不可用"
        end
        root.bondDetailButton = detailButton
    elseif kind == "fishing" then
        -- 中文维护：按钮文案只表达会话状态；“暂时不可用”可能来自战斗/恢复/能力门，不能再误导为永久 Runtime Blocked。
        local autoButton = RSUI:Button({ id = "v3_fishing_auto", parent = actionRow, text = "启用自动 R", compact = true, slot = { size = "fixed", width = 118 } })
        autoButton.onClick = function()
            local ok, actionErr
            if feature:IsAutoArmed() then ok, actionErr = feature.Commands:DisarmAuto() else ok, actionErr = feature.Commands:ArmAuto() end
            if ok == true then root:Refresh() end
            return ok, actionErr
        end
        root.autoButton = autoButton
    end

    status = RSUI:Text({ id = "v3_" .. kind .. "_status", parent = root, text = "尚未读取", fontSize = 9, tone = "muted", overflow = "wrap", slot = { size = "auto", minHeight = 28, hAlign = "fill" } })

    featureButton.onClick = function()
        local enabled = S.FeatureRuntime:IsEnabled(feature.Id) == true
        local target = not enabled
        local ok, enableErr = S.FeatureRuntime:SetPreferredEnabled(feature.Id, target, "life_page_toggle")
        if ok ~= true then return false, enableErr end
        if target then
            local acquired, acquireErr = feature:AcquireConsumer("page:" .. kind)
            if acquired ~= true then
                local rolledBack, rollbackErr = S.FeatureRuntime:SetPreferredEnabled(feature.Id, false, "life_page_acquire_rollback")
                root.consumerHeld = false
                root:Refresh()
                if rolledBack ~= true then return false, tostring(acquireErr or "Consumer 启动失败") .. "；回滚失败：" .. tostring(rollbackErr or "unknown") end
                return false, acquireErr
            end
            root.consumerHeld = true
        else
            -- Disable clears the entire Demand lease set transactionally.
            root.consumerHeld = false
        end
        root:Refresh()
        return true
    end
    if widgetButton ~= nil then
        widgetButton.onClick = function()
            if S.FeatureRuntime:IsEnabled(feature.Id) ~= true then return false, "请先启用" .. title end
            local widgetIds = { trade = "life.trade", bonds = "life.bonds", treasure = "life.treasure", fishing = "life.fishing" }
            local widgetId = widgetIds[kind]
            if widgetId == nil then return false, "生活悬浮窗路由缺失" end
            local visible = WidgetHost:IsVisible(widgetId) == true
            local ok, widgetErr = WidgetHost:SetVisible(widgetId, not visible, { source = "life_page", persist = true })
            if ok == true then root:Refresh() end
            return ok, widgetErr
        end
    end

    local tableView = RSUI:TableView({
        id = "v3_" .. kind .. "_table", parent = root, items = {}, rowHeight = 26, headerHeight = 27, desiredRows = 12, rowFitMode = kind == "trade" and "adaptive_tail" or "fixed", rowFitMin = 22, rowFitMax = 30,
        scrollbar = true, selectable = kind == "treasure" or kind == "trade" or kind == "bonds", selectionMode = "single", columnResize = true, headerInteractive = false,
        columns = kind == "trade" and {
            { id = "name", title = "货物", field = "name", size = "fill", minWidth = 150 },
            { id = "rate", title = "货率", field = "rate", size = "fixed", width = 70, minWidth = 60, getTone = function(item) return item and item.tone or "muted" end },
            { id = "price", title = "预计售价", field = "price", size = "fixed", width = 100, minWidth = 80 },
            { id = "materials", title = "材料", field = "materials", size = "fill", minWidth = 160 },
            { id = "profit", title = "毛利", field = "profit", size = "fixed", width = 100, minWidth = 80 },
        } or kind == "bonds" and {
            -- 中文维护注释：大陆是同日多快照最关键的身份字段，必须直接展示；否则西/东行同时存在时
            -- 玩家仍无法判断来源。只消费 Authority row.continent，不在 UI 重新推断大陆。
            { id = "continent", title = "大陆", field = "continent", size = "fixed", width = 72, minWidth = 62 },
            { id = "board", title = "材料", field = "name", size = "fixed", width = 96, minWidth = 76 },
            { id = "text", title = "居民板原文", field = "text", size = "fill", minWidth = 180 },
            { id = "quantity", title = "数量", field = "quantity", size = "fixed", width = 64, minWidth = 50 },
            { id = "resource", title = "持有", field = "resourceText", size = "fixed", width = 64, minWidth = 50 },
            { id = "shortage", title = "缺口", field = "shortageText", size = "fixed", width = 64, minWidth = 50 },
            { id = "resourceStatus", title = "资源状态", field = "resourceStatusText", size = "fixed", width = 82, minWidth = 68 },
            { id = "status", title = "任务状态", field = "statusText", size = "fixed", width = 82, minWidth = 68, getTone = function(item) return item and item.tone or "muted" end },
        } or kind == "treasure" and {
            { id = "name", title = "藏宝图", field = "name", size = "fixed", width = 140, minWidth = 100 },
            { id = "coord", title = "坐标", field = "text", size = "fill", minWidth = 220 },
            { id = "direction", title = "方向 / 距离", field = "directionText", size = "fixed", width = 140, minWidth = 110 },
        } or {
            { id = "status", title = "状态", field = "statusText", size = "fixed", width = 80, minWidth = 60, getTone = function(item) return item and item.tone or "muted" end },
            { id = "message", title = "动作 / 建议", field = "message", size = "fill", minWidth = 220 },
            { id = "slot", title = "技能栏", field = "slotText", size = "fixed", width = 80, minWidth = 56 },
        },
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })

    if kind == "trade" then
        tableView.onSelectionChanged = function(index)
            -- 维护（2026-09-23，trade-row-double-click-1）：单击仅更新 Feature 的 selectedKey，
            -- 不再自动弹详情；否则第二次点击落不到同一 TableView 行，双击查询无法稳定成立。
            local row = tableView:GetItem(index)
            if row == nil or row.key == nil then return false end
            local ok, selectErr = feature.Commands:SelectRow(row.key)
            if ok == true then
                if root.tradeDetailButton then root.tradeDetailButton:SetEnabled(true) end
                if root.tradeTrackButton then
                    local selected = type(feature.GetSelectedRow) == "function" and feature:GetSelectedRow() or row
                    root.tradeTrackButton:SetEnabled(type(selected) == "table")
                    root.tradeTrackButton:SetText(type(selected) == "table" and selected.tracked == true and "取消关注" or "关注货物")
                end
            end
            return ok, selectErr
        end
        tableView.onItemActivated = function(item, index, key, view, reason)
            local row = type(item) == "table" and item or tableView:GetItem(index)
            if row == nil or row.key == nil then return false end
            -- TableView 的 activated 当前由每次 row click 触发；这里只为 Trade 做实例内双击门控，
            -- 不改变 RSUI 的全局单击激活契约，也不把瞬时点击状态写入配置。
            local now = type(S.NowMs) == "function" and tonumber(S.NowMs()) or 0
            local rowKey = tostring(row.key)
            local previousAt = tonumber(root.tradeLastActivateAt) or -100000
            local isDouble = root.tradeLastActivateKey == rowKey and now >= previousAt and (now - previousAt) <= 450
            root.tradeLastActivateKey, root.tradeLastActivateAt = rowKey, now
            if not isDouble then return true end
            root.tradeLastActivateKey, root.tradeLastActivateAt = nil, 0
            local ok, quoteErr = feature.Commands:QuoteRowMaterials(row.key)
            if ok == true then
                root:Refresh()
            elseif root.tradeInteractionHint then
                root.tradeInteractionHint:SetText("无法查询该货物毛利：" .. tostring(quoteErr or "材料不可询价"))
            end
            return ok, quoteErr
        end
    elseif kind == "treasure" then
        tableView.onSelectionChanged = function(index)
            local row = tableView:GetItem(index)
            if row == nil or row.key == nil then return false end
            local ok, selectErr = feature.Commands:Select(row.key)
            if ok == true then root:Refresh() end
            return ok, selectErr
        end
    elseif kind == "bonds" then
        tableView.onSelectionChanged = function(index)
            local row = tableView:GetItem(index)
            if row == nil or row.key == nil then return false end
            if type(feature.Commands) == "table" and type(feature.Commands.SelectRow) == "function" then
                feature.Commands:SelectRow(row.key)
            end
            if root.bondDetailButton then root.bondDetailButton:SetEnabled(true) end
            return true
        end
        tableView.onItemActivated = function(index)
            local row = tableView:GetItem(index)
            if row == nil then return false end
            local floating = S.UIV3 and S.UIV3.QuestDetailFloatingV3 or nil
            if type(floating) == "table" and type(floating.Open) == "function" then
                return floating:Open("bonds", row.key, row)
            end
            return false
        end
    end

    local function Rows()
        local projection = feature:GetProjection() or {}
        local rows = projection.rows or projection.maps or {}
        if kind == "treasure" then
            for _, row in ipairs(rows) do row.directionText = tostring(row.direction or "--") .. (row.distance and (" / " .. tostring(math.floor(row.distance + 0.5))) or "") end
        elseif kind == "fishing" then
            local one = { key = "fishing", statusText = projection.status or "--", message = projection.message or "--", slotText = projection.slot and tostring(projection.slot) or "--", tone = projection.status == "ready" and "green" or "muted" }
            rows = { one }
        end
        return rows, projection
    end

    function root:Refresh()
        local rows, projection = Rows()
        tableView:SetItems(rows, projection.revision or 0)
        local enabled = S.FeatureRuntime:IsEnabled(feature.Id) == true
        featureButton:SetText(enabled and "关闭功能" or "启用功能")
        if kind == "trade" then
            local fromItems = Items(projection.zones, function(row) return row.displayName or row.name end)
            local toItems = Items(projection.sellableZones, function(row) return row.displayName or row.name end)
            -- 维护（2026-09-23，trade-cargo-ui-authority-1）：随身模式的 origin/destination 由背包 ItemID +
            -- Cargo Authority 决定，Presentation 不能让历史路线下拉继续可操作，否则用户会误以为它能改变随身扫描来源，
            -- 还可能无意义地抢占 SingleFlight。退出随身模式后原路线仍完整保留。
            local routeControlsEnabled = enabled and projection.viewMode ~= "cargo"
            tradeFrom:SetItems(fromItems); tradeFrom:SetEnabled(routeControlsEnabled and #fromItems > 0); tradeFrom:Render()
            tradeTo:SetItems(toItems); tradeTo:SetEnabled(routeControlsEnabled and #toItems > 0); tradeTo:Render()
            local favoriteItems = type(projection.favoriteItems) == "table" and projection.favoriteItems or {}
            if tradeFavoriteDropdown then
                tradeFavoriteDropdown:SetItems(favoriteItems)
                tradeFavoriteDropdown:SetEnabled(routeControlsEnabled and #favoriteItems > 0)
                tradeFavoriteDropdown:Render()
            end
            if root.tradeFavoriteButton then
                local canFavorite = routeControlsEnabled and projection.fromZone ~= nil and projection.toZone ~= nil
                root.tradeFavoriteButton:SetEnabled(canFavorite)
                root.tradeFavoriteButton:SetText(projection.currentRouteFavorite == true and "取消收藏路线" or "收藏路线")
            end
            if root.tradeSortSelector then
                root.tradeSortSelector:SetEnabled(enabled and #(projection.rows or {}) > 0)
                root.tradeSortSelector:Render()
            end
            if root.tradeViewSelector then
                root.tradeViewSelector:SetEnabled(enabled)
                root.tradeViewSelector:Render()
            end
            if root.tradeAutoRefreshButton then
                root.tradeAutoRefreshButton:SetEnabled(enabled and projection.viewMode ~= "cargo")
                root.tradeAutoRefreshButton:SetText(projection.autoRefresh == true and "自动刷新：开" or "自动刷新：关")
            end
            if root.tradeViewHint then
                -- 维护（2026-09-23，trade-view-help-1）：视图名称不再只显示计数，直接解释用途。
                -- 这是 Presentation 帮助文案，不推断 Trade 数据，也不改变任何筛选 Authority。
                if projection.viewMode == "tracked" then
                    root.tradeViewHint:SetText("仅显示你关注的货物；回到“全部货物”后单击货物即可直接关注/取消关注")
                elseif projection.viewMode == "cargo" then
                    local cargo = projection.cargo or {}
                    local label = tostring(cargo.name or cargo.legacyName or "未识别贸易包")
                    local progress = tonumber(cargo.queueCount) and tonumber(cargo.queueCount) > 0
                        and (" · 目的地 " .. tostring(cargo.completedCount or 0) .. "/" .. tostring(cargo.queueCount)) or ""
                    root.tradeViewHint:SetText("读取当前背部贸易包并比较不同目的地收益：" .. label .. progress)
                else
                    root.tradeViewHint:SetText("显示当前路线服务器返回的全部货物；双击任一货物可查询材料并计算毛利")
                end
            end
            if root.tradeRatioModeButton then
                root.tradeRatioModeButton:SetEnabled(enabled)
                root.tradeRatioModeButton:SetText(projection.ratioMode == "full"
                    and ("货率：满" .. tostring(projection.fullRatio or 130) .. "%")
                    or "货率：实时")
            end
            if root.tradeCommerceModeButton then
                root.tradeCommerceModeButton:SetEnabled(enabled)
                root.tradeCommerceModeButton:SetText(projection.commerceMode == "off" and "售价：忽略熟练" or "售价：计熟练")
            end
            local selected = type(feature.GetSelectedRow) == "function" and feature:GetSelectedRow() or nil
            if root.tradeDetailButton then root.tradeDetailButton:SetEnabled(enabled and selected ~= nil) end
            if root.tradeTrackButton then
                root.tradeTrackButton:SetEnabled(enabled and selected ~= nil)
                root.tradeTrackButton:SetText(selected ~= nil and selected.tracked == true and "取消关注" or "关注货物")
            end

            local batch = projection.quoteBatch or {}
            if root.tradeInteractionHint then
                if batch.active == true and batch.scope == "row" then
                    root.tradeInteractionHint:SetText("正在查询所选货物材料 "
                        .. tostring(batch.completed or 0) .. "/" .. tostring(batch.total or 0)
                        .. "；完成后毛利会自动更新")
                elseif tonumber(batch.failed) and tonumber(batch.failed) > 0 and batch.scope == "row" then
                    root.tradeInteractionHint:SetText("上次材料询价有 " .. tostring(batch.failed) .. " 项失败；双击该货物可重试，详情中可查看材料状态")
                else
                    root.tradeInteractionHint:SetText("操作：单击选中 · 双击查询材料并计算毛利 · 可直接关注/取消关注货物")
                end
            end

            -- 页面底部只保留不可从控件直接看出的状态。旧版把地区计数、视图、排序、收藏、熟练度、
            -- 待询价数量等全部重复一遍，造成高信息密度但低可操作性。
            local statusParts = {}
            if not enabled then
                status:SetText("功能已关闭")
            else
                local shown = #(projection.rows or {})
                local raw = tonumber(projection.rawRowCount) or shown
                statusParts[#statusParts + 1] = "显示 " .. tostring(shown) .. "/" .. tostring(raw) .. " 种货物"
                if projection.ratioAgeMs ~= nil then
                    statusParts[#statusParts + 1] = "数据 " .. tostring(math.max(0, math.floor((tonumber(projection.ratioAgeMs) or 0) / 1000))) .. " 秒前"
                end
                if projection.isRefreshing == true then statusParts[#statusParts + 1] = "刷新中" end
                if projection.commerceMode == "observe" and projection.commerceStatus == "ready" and projection.commerceSkill ~= nil then
                    statusParts[#statusParts + 1] = "经商熟练 " .. tostring(math.floor(math.max(0, tonumber(projection.commerceSkill) or 0) + 0.5))
                elseif projection.commerceMode == "observe" and projection.commerceStatus ~= "ready" then
                    statusParts[#statusParts + 1] = "经商熟练度不可读"
                end
                if projection.zoneFallback == true or projection.sellableFallback == true then
                    statusParts[#statusParts + 1] = "地区列表使用兼容数据"
                end
                if projection.error ~= nil then statusParts[#statusParts + 1] = tostring(projection.error)
                elseif projection.sellableError ~= nil then statusParts[#statusParts + 1] = tostring(projection.sellableError) end
                status:SetText(table.concat(statusParts, " · "))
            end
            if widgetButton then
                widgetButton:SetEnabled(enabled)
                widgetButton:SetText(WidgetHost:IsVisible("life.trade") and "关闭悬浮窗" or "打开悬浮窗")
            end
        elseif kind == "treasure" then
            status:SetText(enabled and ((projection.status or "--") .. " · " .. tostring(#(projection.maps or {})) .. " 张地图" .. (projection.selected and (" · 当前 " .. tostring(projection.selected.name or "--")) or "")) or "功能已关闭")
            if widgetButton then widgetButton:SetEnabled(enabled); widgetButton:SetText(WidgetHost:IsVisible("life.treasure") and "关闭悬浮窗" or "打开悬浮窗") end
        elseif kind == "fishing" then
            local fishingText = projection.message or "--"
            if projection.autoAvailable ~= true and projection.autoBlockedReason then
                fishingText = fishingText .. " · " .. tostring(projection.autoBlockedReason)
            end
            status:SetText(enabled and fishingText or "功能已关闭")
            if root.autoButton then
                -- 中文维护：战斗中禁止“新写键”不等于禁止用户发出关闭意图。已 armed 时按钮必须保持可点，Disarm 会立即停止新映射并把恢复延迟到脱战后。
                local armed = feature:IsAutoArmed() == true
                local autoAvailable = enabled and (armed or projection.autoAvailable == true)
                root.autoButton:SetEnabled(autoAvailable)
                root.autoButton:SetText(armed and "关闭自动 R" or (autoAvailable and "启用自动 R" or "自动 R 不可用"))
            end
            if widgetButton then widgetButton:SetEnabled(enabled); widgetButton:SetText(WidgetHost:IsVisible("life.fishing") and "关闭悬浮窗" or "打开悬浮窗") end
        else
            local diagnostic = projection.duplicatePriorityUnresolved and (" · " .. projection.duplicatePriorityUnresolved) or ""
            local currentText = projection.boardScope == "west" and "当前位置：西大陆"
                or (projection.boardScope == "east" and "当前位置：东大陆"
                or (projection.boardScope == "auroria" and "当前位置：原大陆"
                or "当前位置：未识别（显示今日缓存）"))
            local coverage = type(projection.dailySnapshotStatus) == "table" and projection.dailySnapshotStatus or {}
            local coverageText = "今日已获取：西" .. (coverage.west and "✓" or "×")
                .. " 东" .. (coverage.east and "✓" or "×") .. " 原" .. (coverage.auroria and "✓" or "×")
            local errorText = projection.error and (" · " .. tostring(projection.error)) or ""
            status:SetText(enabled and ((projection.status or "--") .. " · " .. currentText .. " · " .. coverageText
                .. " · " .. tostring(#(projection.rows or {})) .. " 条" .. diagnostic .. errorText) or "功能已关闭")
            local bondFilter = feature:GetBondFilter()
            if root.bondSortButton then root.bondSortButton:SetText(bondFilter.sortMode == "quantity" and "排序：按数量" or "排序：按大陆") end
            if root.bondContinentOrderButton then root.bondContinentOrderButton:SetText(bondFilter.continentOrder == "east_first" and "大陆：东→西" or "大陆：西→东") end
            if root.bondFilterButtons then
                root.bondFilterButtons.q20:SetText(bondFilter.q20 and "20✓" or "20×")
                root.bondFilterButtons.q60:SetText(bondFilter.q60 and "60✓" or "60×")
                root.bondFilterButtons.q100:SetText(bondFilter.q100 and "100✓" or "100×")
                root.bondFilterButtons.auroria:SetText(bondFilter.auroria and "原陆✓" or "原陆×")
                root.bondFilterButtons.excludeSame:SetText(bondFilter.excludeSame and "重复：合并" or "重复：全部")
            end
            if root.bondPriorityButton then
                root.bondPriorityButton:SetText(bondFilter.priority == "east" and "合并留东" or "合并留西")
                root.bondPriorityButton:SetEnabled(enabled and bondFilter.excludeSame == true)
            end
            if root.bondDetailButton then
                local selected = type(feature.GetSelectedRow) == "function" and feature:GetSelectedRow() or nil
                root.bondDetailButton:SetEnabled(enabled and selected ~= nil)
            end
            if widgetButton then
                widgetButton:SetEnabled(enabled)
                widgetButton:SetText(WidgetHost:IsVisible("life.bonds") and "关闭悬浮窗" or "打开悬浮窗")
            end
        end
        return true
    end
    function root:BindFeatureUpdates()
        if S.Events == nil or type(S.Events.SubscribeInternal) ~= "function" or type(feature.UpdateTopic) ~= "string" then return true end
        if type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
        return S.Events:SubscribeInternal(feature.UpdateTopic, self, function() root:Refresh() end)
    end
    function root:UnbindFeatureUpdates()
        if S.Events ~= nil and type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
        return true
    end
    function root:OnActivated()
        self:BindFeatureUpdates()
        if S.FeatureRuntime:IsEnabled(feature.Id) ~= true then
            self.consumerHeld = false
            return self:Refresh()
        end
        local acquired, acquireErr = feature:AcquireConsumer("page:" .. kind)
        if acquired ~= true then return false, acquireErr end
        self.consumerHeld = true
        -- Demand 0->1 performs the initial read. Presentation must not issue a
        -- duplicate page-enter refresh, especially for server-query features.
        return self:Refresh()
    end
    function root:OnDeactivated()
        self:UnbindFeatureUpdates()
        if self.consumerHeld then feature:ReleaseConsumer("page:" .. kind); self.consumerHeld = false end
        return true
    end
    root.route, root.tableView = route, tableView
    return root
end

local definitions = {
    { route = "life.trade", id = "life_trade", feature = "Trade", kind = "trade" },
    { route = "life.bonds", id = "life_bonds", feature = "Bonds", kind = "bonds" },
    { route = "life.treasure", id = "life_treasure", feature = "Treasure", kind = "treasure" },
    { route = "life.fishing", id = "life_fishing", feature = "Fishing", kind = "fishing" },
}
for _, definition in ipairs(definitions) do
    local feature = S.Features[definition.feature]
    if type(feature) == "table" then
        local function MakeFactory(capturedFeature, capturedKind)
            return function(parent, route) return Build(parent, route, capturedFeature, capturedKind) end
        end
        local ok, err = Host:RegisterFactory(definition.route, MakeFactory(feature, definition.kind))
        if ok ~= true then error(err) end
    end
end

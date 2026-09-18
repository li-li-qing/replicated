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
            or type(commands.QuotePendingMaterials) ~= "function"
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
    if kind == "trade" then title, subtitle = "跑商", "实时货率来自服务器；预计售价按静态底价 × 货率 × 经商熟练度 × 贸易品类别倍率计算。可切换满货率 130% 与忽略熟练度做对比。"
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

        local tradeRatioModeButton = RSUI:Button({ id = "v3_trade_ratio_mode", parent = actionRow, text = "货率：实时", compact = true, slot = { size = "fixed", width = 94 } })
        tradeRatioModeButton.onClick = function()
            local projection = feature:GetProjection() or {}
            local ok, modeErr = feature.Commands:SetRatioMode(projection.ratioMode == "full" and "current" or "full")
            if ok == true then root:Refresh() end
            return ok, modeErr
        end
        local tradeCommerceModeButton = RSUI:Button({ id = "v3_trade_commerce_mode", parent = actionRow, text = "熟练：计入", compact = true, slot = { size = "fixed", width = 94 } })
        tradeCommerceModeButton.onClick = function()
            local projection = feature:GetProjection() or {}
            local ok, modeErr = feature.Commands:SetCommerceMode(projection.commerceMode == "off" and "observe" or "off")
            if ok == true then root:Refresh() end
            return ok, modeErr
        end
        local tradeQuoteButton = RSUI:Button({ id = "v3_trade_quote_materials", parent = actionRow, text = "材料询价", compact = true, slot = { size = "fixed", width = 108 } })
        tradeQuoteButton.onClick = function()
            local ok, quoteErr = feature.Commands:QuotePendingMaterials()
            if ok == true then root:Refresh() end
            return ok, quoteErr
        end
        -- 维护（module-controls-diag-2）：诊断入口统一在左上角；原跑商请求/身份/初始化证据
        -- 改为Hub独立Provider，删除这里只会重复/串窗口的按钮，不删除原数据或报价流程。
        -- 维护：报价预算/取消统一走Feature，三处视图共享同一批次；此行只显示进度。
        local qb=RSUI:HorizontalBox({id="v3_trade_quote_budget",parent=root,gap=6,slot={size="fixed",height=28}})
        root.tradeCancelQuote=RSUI:Button({id="v3_trade_cancel_quote",parent=qb,text="取消询价",compact=true,slot={size="fixed",width=90}})
        root.tradeCancelQuote.onClick=function()return feature.Commands:CancelQuoteBatch("user")end
        root.tradeFullQuote=RSUI:Button({id="v3_trade_full_quote",parent=qb,text="扩大询价(最多4项)",compact=true,slot={size="fixed",width=140}})
        root.tradeFullQuote.onClick=function()return feature.Commands:QuotePendingMaterials("full")end
        root.tradeQuoteProgress=RSUI:Text({id="v3_trade_quote_progress",parent=qb,text="默认仅提示品质；扩大查询才搜索其他品质/名称。",fontSize=9,overflow="ellipsis",slot={size="fill",fill=1}})
        root.tradeRatioModeButton, root.tradeCommerceModeButton, root.tradeQuoteButton = tradeRatioModeButton, tradeCommerceModeButton, tradeQuoteButton
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
        id = "v3_" .. kind .. "_table", parent = root, items = {}, rowHeight = 26, headerHeight = 27, desiredRows = 12,
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
            local row = tableView:GetItem(index)
            if row == nil or row.key == nil then return false end
            local ok, selectErr = feature.Commands:SelectRow(row.key)
            if ok ~= true then return false, selectErr end
            local detail = S.UIV3 and S.UIV3.TradeDetailFloatingV3 or nil
            if type(detail) ~= "table" or type(detail.Open) ~= "function" then return false, "贸易品详情悬浮窗不可用" end
            return detail:Open(row.key)
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
            tradeFrom:SetItems(fromItems); tradeFrom:SetEnabled(enabled and #fromItems > 0); tradeFrom:Render()
            tradeTo:SetItems(toItems); tradeTo:SetEnabled(enabled and #toItems > 0); tradeTo:Render()
            local favoriteItems = type(projection.favoriteItems) == "table" and projection.favoriteItems or {}
            if tradeFavoriteDropdown then
                tradeFavoriteDropdown:SetItems(favoriteItems)
                tradeFavoriteDropdown:SetEnabled(enabled and #favoriteItems > 0)
                tradeFavoriteDropdown:Render()
            end
            if root.tradeFavoriteButton then
                local canFavorite = enabled and projection.fromZone ~= nil and projection.toZone ~= nil
                root.tradeFavoriteButton:SetEnabled(canFavorite)
                root.tradeFavoriteButton:SetText(projection.currentRouteFavorite == true and "取消收藏" or "收藏路线")
            end
            if root.tradeSortSelector then
                root.tradeSortSelector:SetEnabled(enabled and #(projection.rows or {}) > 0)
                root.tradeSortSelector:Render()
            end
            local pendingQuotes = math.max(0, tonumber(projection.pendingQuoteCount) or 0)
            if root.tradeRatioModeButton then
                root.tradeRatioModeButton:SetEnabled(enabled)
                root.tradeRatioModeButton:SetText(projection.ratioMode == "full" and ("货率：满" .. tostring(projection.fullRatio or 130) .. "%") or "货率：实时")
            end
            if root.tradeCommerceModeButton then
                root.tradeCommerceModeButton:SetEnabled(enabled)
                root.tradeCommerceModeButton:SetText(projection.commerceMode == "off" and "熟练：忽略" or "熟练：计入")
            end
            local batch=projection.quoteBatch or {}
            if root.tradeQuoteButton then
                root.tradeQuoteButton:SetEnabled(enabled and pendingQuotes>0 and not batch.active)
                root.tradeQuoteButton:SetText(batch.active and "询价中" or "材料询价(4)")
            end
            root.tradeCancelQuote:SetEnabled(enabled and batch.active==true)
            root.tradeFullQuote:SetEnabled(enabled and not batch.active and #rows>0)
            root.tradeQuoteProgress:SetText((batch.active and "进行中 " or "本批完成 ")..tostring(batch.completed or 0).."/"..tostring(batch.total or 0).." · 未报价 "..pendingQuotes.." · 失败 "..tostring(batch.failed or 0).."；扩大询价才扫描其他品质。")
            local dropdownHint = ""
            if enabled then
                if #fromItems == 0 then dropdownHint = dropdownHint .. " · 起点下拉不可用：地区未读取" end
                if #toItems == 0 and #fromItems > 0 then dropdownHint = dropdownHint .. " · 终点下拉不可用：请先选择起点" end
            end
            local fallback = (projection.zoneFallback == true and " · 起点使用静态候选" or "") .. (projection.sellableFallback == true and " · 目的地使用兼容候选" or "")
            local errorText = projection.error and (" · " .. tostring(projection.error)) or (projection.sellableError and (" · " .. tostring(projection.sellableError)) or "")
            local quoteHint = pendingQuotes > 0 and (" · 待询价材料 " .. tostring(pendingQuotes)) or ""
            local inFlightQuotes = math.max(0, tonumber(projection.quoteInFlightCount) or 0)
            if inFlightQuotes > 0 then quoteHint = quoteHint .. (" · 询价中 " .. tostring(inFlightQuotes)) end
            local unresolvedIdentity = math.max(0, tonumber(projection.unresolvedIdentityCount) or 0)
            if unresolvedIdentity > 0 then quoteHint = quoteHint .. (" · 配方待解析 " .. tostring(unresolvedIdentity)) end
            local ratioHint = projection.ratioMode == "full" and (" · 满货率 " .. tostring(projection.fullRatio or 130) .. "% 对比") or " · 实时货率"
            local commerceHint = ""
            if projection.commerceMode == "observe" then
                if projection.commerceStatus == "ready" and projection.commerceSkill ~= nil then
                    local skill = math.max(0, tonumber(projection.commerceSkill) or 0)
                    commerceHint = " · 经商 " .. tostring(math.floor(skill + 0.5))
                        .. " ×" .. string.format("%.3f", 1 + (skill / 10000 * 0.05)) .. "（已计售价）"
                else
                    commerceHint = " · 经商熟练度不可读，完整售价暂停"
                        .. (projection.commerceError and ("：" .. tostring(projection.commerceError)) or "")
                end
            else
                commerceHint = " · 熟练度忽略（对比模式）"
            end
            local favoriteHint = " · 收藏 " .. tostring(#favoriteItems) .. "/12" .. (projection.currentRouteFavorite == true and "（当前）" or "")
            local sortHint = (projection.sortMode == "price" and " · 按售价排序")
                or (projection.sortMode == "name" and " · 按名字排序（[]优先）")
                or " · 按货率排序"
            status:SetText(enabled and ((projection.status or "--") .. " · 地区 " .. tostring(#fromItems) .. "/" .. tostring(#toItems) .. " · " .. tostring(#(projection.rows or {})) .. " 种货物" .. ratioHint .. commerceHint .. quoteHint .. favoriteHint .. sortHint .. fallback .. dropdownHint .. errorText) or "功能已关闭")
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

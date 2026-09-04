------------------------------------------------------------------------
-- Replicated Suite V3 - Life vertical-slice pages
------------------------------------------------------------------------
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
            or type(commands.QuotePendingMaterials) ~= "function"
            or type(feature.GetWidgetVisible) ~= "function" or type(commands.SetWidgetVisible) ~= "function" then
            return false, "跑商页面 Feature 契约不完整"
        end
    elseif kind == "bonds" then
        if type(feature.GetSortMode) ~= "function" or type(feature.GetBondFilter) ~= "function"
            or type(commands.SetSortMode) ~= "function" or type(commands.SetBondFilterOption) ~= "function"
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
    if kind == "trade" then title, subtitle = "跑商", "直接读取 X2Store 生产地、可售地和服务器货率；价格只在本地静态数据能精确匹配时显示。"
    elseif kind == "bonds" then title, subtitle = "债券 / 居民板", "读取居民板内容、QuestProgressV3 任务状态和有限背包材料总量；明确显示未知与部分可读诊断。"
    elseif kind == "treasure" then title, subtitle = "寻宝", "直接扫描有限背包槽位中的藏宝图坐标，并在单位世界坐标可用时计算方向与距离。"
    else title, subtitle = "钓鱼", "按需观察目标鱼动作 Buff；自动 R 只有在热键读取和战斗保护都通过时才允许显式启用。" end
    D:PageHeader(root, "v3_" .. kind .. "_header", title, subtitle, "刷新", function()
        local ok, refreshErr = feature.Commands:Refresh("page_manual")
        if ok == true then root:Refresh() end
        return ok, refreshErr
    end)
    local actionRow = RSUI:HorizontalBox({ id = "v3_" .. kind .. "_actions", parent = root, gap = 6, slot = { size = "fixed", height = 32, hAlign = "fill" } })
    local featureButton = RSUI:Button({ id = "v3_" .. kind .. "_toggle", parent = actionRow, text = "关闭功能", compact = true, slot = { size = "fixed", width = 96 } })
    local widgetButton = RSUI:Button({ id = "v3_" .. kind .. "_widget_toggle", parent = actionRow, text = "打开悬浮窗", compact = true, slot = { size = "fixed", width = 96 } })
    local status

    local tradeFrom, tradeTo
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

        local tradeQuoteButton = RSUI:Button({ id = "v3_trade_quote_materials", parent = actionRow, text = "材料询价", compact = true, slot = { size = "fixed", width = 108 } })
        tradeQuoteButton.onClick = function()
            local ok, quoteErr = feature.Commands:QuotePendingMaterials()
            if ok == true then root:Refresh() end
            return ok, quoteErr
        end
        root.tradeQuoteButton = tradeQuoteButton
    elseif kind == "bonds" then
        local sortButton = RSUI:Button({ id = "v3_bonds_sort", parent = actionRow, text = "按数量排序", compact = true, slot = { size = "fixed", width = 108 } })
        root.bondSortButton = sortButton
        local runBondCommand = function(command)
            local ok, commandErr = command()
            if ok == true then root:Refresh() end
            return ok, commandErr
        end
        sortButton.onClick = function() return runBondCommand(function() return feature.Commands:SetSortMode(feature:GetSortMode() == "quantity" and "continent" or "quantity") end) end
        local bondState = function() return feature:GetBondFilter() end
        local bondButton = function(id, text, key)
            local button = RSUI:Button({ id = id, parent = actionRow, text = text, compact = true, slot = { size = "fixed", width = 54 } })
            button.onClick = function() local state = bondState(); return runBondCommand(function() return feature.Commands:SetBondFilterOption(key, not state[key]) end) end
            return button
        end
        root.bondFilterButtons = { q20 = bondButton("v3_bonds_q20", "20", "q20"), q60 = bondButton("v3_bonds_q60", "60", "q60"), q100 = bondButton("v3_bonds_q100", "100", "q100"), auroria = bondButton("v3_bonds_auroria", "原大陆", "auroria"), excludeSame = bondButton("v3_bonds_exclude", "去重", "excludeSame") }
        local priorityButton = RSUI:Button({ id = "v3_bonds_priority", parent = actionRow, text = "优先西", compact = true, slot = { size = "fixed", width = 64 } })
        priorityButton.onClick = function() local state = bondState(); return runBondCommand(function() return feature.Commands:SetDuplicatePriority(state.priority == "west" and "east" or "west") end) end
        root.bondPriorityButton = priorityButton
    elseif kind == "fishing" then
        local autoButton = RSUI:Button({ id = "v3_fishing_auto", parent = actionRow, text = "启用自动 R", compact = true, slot = { size = "fixed", width = 108 } })
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
        scrollbar = true, selectable = kind == "treasure", selectionMode = "single", columnResize = true, headerInteractive = false,
        columns = kind == "trade" and {
            { id = "name", title = "货物", field = "name", size = "fill", minWidth = 150 },
            { id = "rate", title = "货率", field = "rate", size = "fixed", width = 70, minWidth = 60, getTone = function(item) return item and item.tone or "muted" end },
            { id = "price", title = "预计售价", field = "price", size = "fixed", width = 100, minWidth = 80 },
            { id = "materials", title = "材料", field = "materials", size = "fill", minWidth = 160 },
            { id = "profit", title = "毛利", field = "profit", size = "fixed", width = 100, minWidth = 80 },
        } or kind == "bonds" and {
            { id = "board", title = "板", field = "name", size = "fixed", width = 100, minWidth = 80 },
            { id = "text", title = "居民板原文", field = "text", size = "fill", minWidth = 220 },
            { id = "quantity", title = "数量", field = "quantity", size = "fixed", width = 70, minWidth = 54 },
            { id = "resource", title = "资源", field = "resourceText", size = "fixed", width = 70, minWidth = 54 },
            { id = "shortage", title = "缺口", field = "shortageText", size = "fixed", width = 70, minWidth = 54 },
            { id = "resourceStatus", title = "资源状态", field = "resourceStatus", size = "fixed", width = 90, minWidth = 72 },
            { id = "status", title = "任务状态", field = "statusText", size = "fixed", width = 86, minWidth = 72, getTone = function(item) return item and item.tone or "muted" end },
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

    if kind == "treasure" then
        tableView.onSelectionChanged = function(index)
            local row = tableView:GetItem(index)
            if row == nil or row.key == nil then return false end
            local ok, selectErr = feature.Commands:Select(row.key)
            if ok == true then root:Refresh() end
            return ok, selectErr
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
            local pendingQuotes = math.max(0, tonumber(projection.pendingQuoteCount) or 0)
            if root.tradeQuoteButton then
                root.tradeQuoteButton:SetEnabled(enabled and pendingQuotes > 0)
                root.tradeQuoteButton:SetText(pendingQuotes > 0 and ("材料询价 (" .. tostring(pendingQuotes) .. ")") or "材料询价")
            end
            local dropdownHint = ""
            if enabled then
                if #fromItems == 0 then dropdownHint = dropdownHint .. " · 起点下拉不可用：地区未读取" end
                if #toItems == 0 and #fromItems > 0 then dropdownHint = dropdownHint .. " · 终点下拉不可用：请先选择起点" end
            end
            local fallback = (projection.zoneFallback == true and " · 起点使用静态候选" or "") .. (projection.sellableFallback == true and " · 目的地使用兼容候选" or "")
            local errorText = projection.error and (" · " .. tostring(projection.error)) or (projection.sellableError and (" · " .. tostring(projection.sellableError)) or "")
            local quoteHint = pendingQuotes > 0 and (" · 待询价材料 " .. tostring(pendingQuotes)) or ""
            status:SetText(enabled and ((projection.status or "--") .. " · 地区 " .. tostring(#fromItems) .. "/" .. tostring(#toItems) .. " · " .. tostring(#(projection.rows or {})) .. " 种货物" .. quoteHint .. fallback .. dropdownHint .. errorText) or "功能已关闭")
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
                local autoAvailable = enabled and projection.autoAvailable == true
                root.autoButton:SetEnabled(autoAvailable)
                root.autoButton:SetText(autoAvailable and (feature:IsAutoArmed() and "关闭自动 R" or "启用自动 R") or "自动 R 待迁移")
            end
            if widgetButton then widgetButton:SetEnabled(enabled); widgetButton:SetText(WidgetHost:IsVisible("life.fishing") and "关闭悬浮窗" or "打开悬浮窗") end
        else
            local diagnostic = projection.duplicatePriorityUnresolved and (" · " .. projection.duplicatePriorityUnresolved) or ""
            local scopeText = projection.boardScope == "mainland" and "大陆居民板"
                or (projection.boardScope == "auroria" and "原大陆居民板" or "区域未判定")
            local factionText = projection.faction and tostring(projection.faction) ~= "" and (" · 阵营 " .. tostring(projection.faction)) or ""
            local errorText = projection.error and (" · " .. tostring(projection.error)) or ""
            status:SetText(enabled and ((projection.status or "--") .. " · " .. scopeText .. factionText
                .. " · " .. tostring(#(projection.rows or {})) .. " 条" .. diagnostic .. errorText) or "功能已关闭")
            local bondFilter = feature:GetBondFilter()
            if root.bondSortButton then root.bondSortButton:SetText(bondFilter.sortMode == "quantity" and "按大陆排序" or "按数量排序") end
            if root.bondFilterButtons then
                root.bondFilterButtons.q20:SetText(bondFilter.q20 and "20✓" or "20×")
                root.bondFilterButtons.q60:SetText(bondFilter.q60 and "60✓" or "60×")
                root.bondFilterButtons.q100:SetText(bondFilter.q100 and "100✓" or "100×")
                root.bondFilterButtons.auroria:SetText(bondFilter.auroria and "原陆✓" or "原陆×")
                root.bondFilterButtons.excludeSame:SetText(bondFilter.excludeSame and "去重✓" or "去重×")
            end
            if root.bondPriorityButton then root.bondPriorityButton:SetText(bondFilter.priority == "east" and "优先东" or "优先西") end
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

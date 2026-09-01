------------------------------------------------------------------------
-- Replicated Suite - Life Workspaces (M3)
--
-- Presentation composites for Activity / Trade / Bond / Task / Treasure /
-- Fishing. These pages consume existing Services + State only; they never read
-- X2 APIs directly and never create a second persistence/business Authority.
-- Large lists are virtualized with the frozen RSUI TableView implementation.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI = S.RSUI
if type(RSUI) ~= "table" then return end

S.LifeWorkspace = {}
local W = S.LifeWorkspace

local function ToggleHud(id)
    if S.UI ~= nil and type(S.UI.ToggleWidget) == "function" then S.UI:ToggleWidget(id) end
    return true
end

local function FormatClock(seconds)
    local value = tonumber(seconds)
    if value == nil then return "--" end
    value = math.max(0, math.floor(value))
    local hours = math.floor(value / 3600)
    local minutes = math.floor((value % 3600) / 60)
    local secs = value % 60
    if hours > 0 then return string.format("%02d:%02d:%02d", hours, minutes, secs) end
    return string.format("%02d:%02d", minutes, secs)
end

local function EventPhase(row)
    if type(row) ~= "table" then return "--" end
    local status = tostring(row.status or "")
    if status == "" then return row.active == true and "进行中" or "--" end
    local seconds = tonumber(row.seconds)
    if seconds == nil then return status end
    local token
    if seconds < 60 then token = tostring(math.max(0, math.floor(seconds))) .. "秒"
    elseif seconds < 3600 then token = tostring(math.floor(seconds / 60)) .. "分"
    else
        local hours = math.floor(seconds / 3600)
        local minutes = math.floor((seconds % 3600) / 60)
        token = tostring(hours) .. "时" .. (minutes > 0 and (tostring(minutes) .. "分") or "")
    end
    if status == token and row.active ~= true then return "即将开始" end
    if status == "进行中 " .. token then return "进行中" end
    if #token > 0 and #status > #token and string.sub(status, -#token) == token then
        local prefix = string.gsub(string.sub(status, 1, #status - #token), "%s+$", "")
        if prefix ~= "" then return prefix end
    end
    return status
end

local function CreateClickableTableRow(tableId, list, poolIndex, tableView, onClick, onRightClick)
    local row = RSUI:TableRow({
        id = tableId .. "_row_" .. tostring(poolIndex),
        parent = list,
        columns = tableView.columns,
        resolvedWidths = tableView.resolvedWidths,
        rowHeight = tableView.rowHeight,
        columnGap = tableView.columnGap,
        pickable = type(onClick) == "function" or type(onRightClick) == "function",
    })
    if row == nil or row.root == nil then return row end
    if type(onClick) == "function" then
        S.UI:SafeHandler(row.root, "OnClick", function()
            if row.item ~= nil then onClick(row.item) end
            return true
        end, tableId .. ":click:" .. tostring(poolIndex))
    end
    if type(onRightClick) == "function" then
        S.UI:SafeHandler(row.root, "OnRButtonUp", function()
            if row.item ~= nil then onRightClick(row.item) end
            return true
        end, tableId .. ":right:" .. tostring(poolIndex))
    end
    return row
end

local function CreatePage(parent, key, title, subtitle, actions)
    local page = { key = key, title = title, cache = {}, revision = 0 }
    page.component = RSUI:Border({
        id = key .. "_page", parent = parent,
        width = 100, height = 100, padding = 6, variant = "soft", gradient = false,
    })
    page.root = page.component and page.component.root or nil
    if page.root == nil then return nil end
    if page.root.rsBorder and page.root.rsBorder.SetVisible then page.root.rsBorder:SetVisible(false) end
    if page.root.rsBackground and page.root.rsBackground.SetVisible then page.root.rsBackground:SetVisible(false) end

    page.stack = RSUI:VerticalBox({ id = key .. "_stack", parent = page.component, gap = 5 })
    page.header = RSUI:Border({
        id = key .. "_header", parent = page.stack, height = 50,
        padding = { left = 8, right = 8, top = 5, bottom = 4 }, variant = "card", gradient = true, accentStrip = 2,
        slot = { size = "fixed", height = 50, hAlign = "fill" },
    })
    page.headerRow = RSUI:HorizontalBox({ id = key .. "_header_row", parent = page.header, gap = 4 })
    page.headerText = RSUI:VerticalBox({
        id = key .. "_header_text", parent = page.headerRow, gap = 0,
        slot = { size = "fill", fill = 1, minWidth = 70, hAlign = "fill" },
    })
    page.heading = RSUI:Text({
        id = key .. "_heading", parent = page.headerText, text = title, tone = "accent", fontSize = 12, shadow = true, overflow = "ellipsis",
        slot = { size = "fixed", height = 22, hAlign = "fill" },
    })
    page.subtitle = RSUI:Text({
        id = key .. "_subtitle", parent = page.headerText, text = subtitle or "", tone = "muted", fontSize = 8, overflow = "ellipsis",
        slot = { size = "fixed", height = 17, hAlign = "fill" },
    })
    page.actions = {}
    for i, action in ipairs(type(actions) == "table" and actions or {}) do
        local button = RSUI:Button({
            id = key .. "_action_" .. tostring(i), parent = page.headerRow,
            text = tostring(action.text or "操作"), compact = true, gradient = true, fontSize = 8,
            slot = { size = "fixed", width = tonumber(action.width) or 52, hAlign = "fill", vAlign = "center" },
            onClick = action.onClick,
        })
        page.actions[#page.actions + 1] = button
    end
    return page
end

local function FinalizePage(page)
    if page == nil then return nil end
    S.UI.pages[page.key] = page
    return page
end

local function SetItemsIfChanged(view, cache, key, rows, signature)
    signature = tostring(signature or "")
    if cache[key] == signature then return false end
    cache[key] = signature
    view:SetItems(rows, signature)
    return true
end

local function Signature(rows, fields)
    local out = { tostring(#(rows or {})) }
    for i, row in ipairs(rows or {}) do
        local part = { tostring(i) }
        for _, field in ipairs(fields or {}) do part[#part + 1] = tostring(row and row[field] or "") end
        out[#out + 1] = table.concat(part, ":")
    end
    return table.concat(out, "|")
end

local function ZoneItems(zones)
    if S.Visual ~= nil and S.Visual.StyledDropdown ~= nil and type(S.Visual.StyledDropdown.GroupZones) == "function" then
        return S.Visual.StyledDropdown:GroupZones(zones)
    end
    local items = {}
    for _, zone in ipairs(zones or {}) do
        items[#items + 1] = { value = tonumber(zone.id), text = tostring(zone.displayName or zone.name or zone.id or "--") }
    end
    return items
end

------------------------------------------------------------------------
-- Activity workspace
------------------------------------------------------------------------
function W.CreateActivity(parent)
    local page
    page = CreatePage(parent, "life_activity", "活动 / 世界状态", "多活动同时监控；左键打开任务详情，右键隐藏普通活动。", {
        { text = "悬浮HUD", width = 60, onClick = function() return ToggleHud("event") end },
        { text = "刷新", width = 44, onClick = function()
            local service = S.Services and S.Services.Event
            if service and type(service.Refresh) == "function" then service:Refresh() end
            if page then page:Refresh({ all = true }) end
            return true
        end },
        { text = "提醒", width = 48, onClick = function()
            local mode=tostring(S.State.settings.eventReminderMode or "off")
            if mode=="off" then mode="5" elseif mode=="5" then mode="15_5" else mode="off" end
            S.State.settings.eventReminderMode=mode
            local service=S.Services and S.Services.Event
            if service and mode=="off" then service.reminderBootstrapped=false end
            S.Storage:RequestSave()
            if page then page:Refresh() end
            return true
        end },
        { text = "恢复隐藏", width = 60, onClick = function()
            local service = S.Services and S.Services.Event
            if service and type(service.RestoreHiddenEvents) == "function" then service:RestoreHiddenEvents() end
            if page then page:Refresh({ all = true }) end
            return true
        end },
    })
    if page == nil then return nil end

    page.summary = RSUI:Text({
        id = "life_activity_summary", parent = page.stack, text = "活动：--", tone = "muted", fontSize = 9, overflow = "ellipsis",
        slot = { size = "fixed", height = 20, hAlign = "fill", padding = { left = 4, right = 4 } },
    })
    local columns = {
        { id = "name", title = "活动名称", size = "fill", minWidth = 140, absoluteMinWidth = 70, getText = function(row) return tostring(row and (row.fullName or row.name or row.shortName) or "--") end },
        { id = "phase", title = "状态 / 阶段", width = 130, minWidth = 86, absoluteMinWidth = 56, getText = EventPhase, getTone = function(row) return row and row.tone or "muted" end },
        { id = "remain", title = "剩余", width = 80, minWidth = 64, absoluteMinWidth = 46, getText = function(row) return row and FormatClock(row.seconds) or "--" end, getTone = function(row) return row and row.tone or "muted" end },
        { id = "progress", title = "进度", width = 72, minWidth = 56, absoluteMinWidth = 42, getText = function(row) return row and tostring(row.progressText or "--") or "--" end, getTone = function(row) return row and (row.progressTone or "muted") or "muted" end },
        { id = "goal", title = "关联任务 / 目标", size = "fill", fill = 0.9, minWidth = 110, absoluteMinWidth = 58, getText = function(row)
            if type(row) ~= "table" then return "--" end
            return tostring(row.goalText or row.questName or row.objectiveText or (row.questKey and "点击查看任务" or "--"))
        end },
    }
    page.table = RSUI:TableView({
        id = "life_activity_table", parent = page.stack, columns = columns,
        rowHeight = 22, headerHeight = 23, columnGap = 3, overscan = 3, maxPoolSize = 28,
        rowFactory = function(list, poolIndex, tableView)
            return CreateClickableTableRow("life_activity_table", list, poolIndex, tableView, function(row)
                local service = S.Services and S.Services.Event
                if row and row.questKey and service and type(service.OpenTask) == "function" then service:OpenTask(row) end
            end, function(row)
                local service = S.Services and S.Services.Event
                if row and service and type(service.HideEvent) == "function" then service:HideEvent(row) end
            end)
        end,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })

    function page:Refresh()
        -- Main workspace is a virtualized complete list. eventMaxRows is a HUD
        -- presentation preference and must not silently truncate the full page.
        local rows = S.State.data.events or {}
        SetItemsIfChanged(self.table, self.cache, "events", rows, Signature(rows, { "name", "status", "seconds", "progressText", "questKey" }))
        local service = S.Services and S.Services.Event
        local hidden = service and type(service.GetHiddenCount) == "function" and service:GetHiddenCount() or 0
        local active = 0
        for _, row in ipairs(rows) do if row.active == true then active = active + 1 end end
        local reminderMode=tostring(S.State.settings.eventReminderMode or "off")
        if self.actions and self.actions[3] then
            self.actions[3]:SetText(reminderMode=="15_5" and "提醒15/5" or reminderMode=="5" and "提醒5分" or "提醒关")
        end
        self.summary:SetText("共 " .. tostring(#rows) .. " 条 · 进行中 " .. tostring(active) .. " 条" .. (hidden > 0 and (" · 已隐藏 " .. tostring(hidden) .. " 条") or ""))
        return true
    end
    function page:ApplyLayout(spec)
        self.component:LayoutIfNeeded(0, 0, math.max(1, tonumber(spec.contentWidth) or 1), math.max(1, tonumber(spec.contentHeight) or 1))
        self:Refresh()
    end
    page:Refresh()
    return FinalizePage(page)
end

------------------------------------------------------------------------
-- Trade workspace
------------------------------------------------------------------------
local function FavoriteKey(fromZone, toZone)
    local from, to = tonumber(fromZone), tonumber(toZone)
    if from == nil or to == nil then return nil end
    return tostring(math.floor(from)) .. ":" .. tostring(math.floor(to))
end

local function CycleFavorite(service, delta)
    if service == nil or type(service.GetFavorites) ~= "function" or type(service.SelectFavorite) ~= "function" then return false end
    local favorites = service:GetFavorites()
    if #favorites == 0 then S.SafeChat("还没有收藏跑商路线。") return false end
    local current = FavoriteKey(S.State.life.trade.fromZone, S.State.life.trade.toZone)
    local index = 0
    for i, favorite in ipairs(favorites) do if tostring(favorite.key) == tostring(current) then index = i break end end
    local step = tonumber(delta) or 1
    index = ((index + step - 1) % #favorites) + 1
    return service:SelectFavorite(favorites[index].key)
end

function W.CreateTrade(parent)
    local function CreateTradeDropdown(spec)
        if S.Visual ~= nil and S.Visual.StyledDropdown ~= nil and type(S.Visual.StyledDropdown.Create) == "function" then return S.Visual.StyledDropdown:Create(spec) end
        return RSUI:Dropdown(spec)
    end
    local page
    page = CreatePage(parent, "life_trade", "跑商货率", "一条路线显示多种真实贸易货物；路线查询仍由 TradeService / X2Store Authority 执行。", {
        { text = "悬浮HUD", width = 60, onClick = function() return ToggleHud("trade") end },
        { text = "刷新", width = 44, onClick = function()
            local service = S.Services and S.Services.Trade
            if service and type(service.Request) == "function" then service:Request(true) end
            return true
        end },
        { text = "排序", width = 48, onClick = function()
            S.State.settings.tradeSortMode = S.State.settings.tradeSortMode == "price" and "ratio" or "price"
            local service = S.Services and S.Services.Trade
            if service and S.State.data.trade and S.State.data.trade.status == "ready" and type(service.Request) == "function" then service:Request(true) end
            S.Storage:RequestSave()
            if page then page:Refresh() end
            return true
        end },
        { text = "自动", width = 48, onClick = function()
            S.State.settings.tradeAutoRefresh = not (S.State.settings.tradeAutoRefresh == true)
            if S.Runtime and type(S.Runtime.ApplyRefreshSettings) == "function" then S.Runtime:ApplyRefreshSettings() end
            S.Storage:RequestSave()
            if page then page:Refresh() end
            return true
        end },
        { text = "间隔", width = 48, onClick = function()
            local options = S.Constants and S.Constants.TradeRefreshOptionsMs or { 60000, 120000, 180000 }
            local current = tonumber(S.State.settings.tradeAutoRefreshMs) or tonumber(options[1]) or 120000
            local index = 1
            for i, value in ipairs(options) do if tonumber(value) == current then index = i break end end
            index = index + 1; if index > #options then index = 1 end
            S.State.settings.tradeAutoRefreshMs = options[index]
            if S.Runtime and type(S.Runtime.ApplyRefreshSettings) == "function" then S.Runtime:ApplyRefreshSettings() end
            S.Storage:RequestSave()
            if page then page:Refresh() end
            return true
        end },
    })
    if page == nil then return nil end

    page.routeBar = RSUI:HorizontalBox({ id = "life_trade_route_bar", parent = page.stack, gap = 4, slot = { size = "fixed", height = 29, hAlign = "fill" } })
    page.routeText = RSUI:Text({ id = "life_trade_route", parent = page.routeBar, text = "请选择路线", tone = "accent", fontSize = 10, overflow = "ellipsis", slot = { size = "fill", fill = 1, minWidth = 100, hAlign = "fill", vAlign = "center" } })
    page.favoriteDropdown = CreateTradeDropdown({
        id = "life_trade_favorite_dropdown", parent = page.routeBar, width = 170, height = 28, maxVisible = 12, popupWidth = 270, items = {},
        slot = { size = "fixed", width = 170, hAlign = "fill" },
        onChanged = function(value)
            local service = S.Services and S.Services.Trade
            if service and type(service.SelectFavorite) == "function" and value ~= nil then service:SelectFavorite(value) end
        end,
    })
    page.favorite = RSUI:Button({ id = "life_trade_favorite", parent = page.routeBar, text = "收藏", compact = true, gradient = true, fontSize = 8, slot = { size = "fixed", width = 48 }, onClick = function()
        local service = S.Services and S.Services.Trade
        if service and type(service.ToggleCurrentFavorite) == "function" then service:ToggleCurrentFavorite() end
        if page then page:Refresh() end
        return true
    end })

    -- M6-v2: route endpoints are dropdowns, not cycle buttons. Trade zone sets
    -- are large and continent-grouped by TradeService, so direct selection is
    -- the only scalable interaction.
    page.selectorBar = RSUI:HorizontalBox({ id = "life_trade_selector_bar", parent = page.stack, gap = 6, slot = { size = "fixed", height = 32, hAlign = "fill" } })
    page.fromDropdown = CreateTradeDropdown({
        id = "life_trade_from_dropdown", parent = page.selectorBar, width = 260, height = 28, maxVisible = 14, popupWidth = 300, items = {},
        slot = { size = "fill", fill = 1, minWidth = 130, hAlign = "fill" },
        onChanged = function(value)
            local service = S.Services and S.Services.Trade
            if service and type(service.SelectFrom) == "function" then service:SelectFrom(value) end
        end,
    })
    page.toDropdown = CreateTradeDropdown({
        id = "life_trade_to_dropdown", parent = page.selectorBar, width = 260, height = 28, maxVisible = 14, popupWidth = 300, items = {},
        slot = { size = "fill", fill = 1, minWidth = 130, hAlign = "fill" },
        onChanged = function(value)
            local service = S.Services and S.Services.Trade
            if service and type(service.SelectTo) == "function" then service:SelectTo(value) end
        end,
    })

    local columns = {
        { id = "name", title = "货物名称", size = "fill", minWidth = 160, absoluteMinWidth = 78, getText = function(row) return tostring(row and row.name or "--") end },
        { id = "rate", title = "货率", width = 66, minWidth = 56, absoluteMinWidth = 44, getText = function(row) return tostring(row and row.rate or "--") end, getTone = function(row) return row and row.tone or "muted" end },
        { id = "price", title = "预计售价", width = 96, minWidth = 78, absoluteMinWidth = 58, getText = function(row) return tostring(row and row.price or "--") end },
        { id = "material", title = "材料成本", width = 96, minWidth = 78, absoluteMinWidth = 56, getText = function(row) return row and row.materialCostCopper and S.Utils.FormatCompactMoney(row.materialCostCopper, false) or "--" end },
        { id = "profit", title = "预计毛利", width = 96, minWidth = 76, absoluteMinWidth = 54, getText = function(row) return tostring(row and row.profit or "--") end, getTone = function(row) return row and row.profitCopper and (row.profitCopper >= 0 and "green" or "red") or "muted" end },
    }
    page.table = RSUI:TableView({
        id = "life_trade_table", parent = page.stack, columns = columns, rowHeight = 22, headerHeight = 23, columnGap = 3, overscan = 3, maxPoolSize = 30,
        rowFactory = function(list, poolIndex, tableView)
            return CreateClickableTableRow("life_trade_table", list, poolIndex, tableView, function(row)
                local service = S.Services and S.Services.Trade
                if row and service and type(service.SelectPack) == "function" then service:SelectPack(row, true) end
            end)
        end,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })
    page.status = RSUI:Text({ id = "m3_life_trade_status", parent = page.stack, text = "请选择路线", tone = "muted", fontSize = 8, overflow = "ellipsis", slot = { size = "fixed", height = 20, hAlign = "fill", padding = { left = 4, right = 4 } } })

    function page:Refresh()
        local d = S.State.data.trade or {}
        local rows = d.rows or {}
        SetItemsIfChanged(self.table, self.cache, "trade", rows, Signature(rows, { "name", "rate", "price", "materialCostCopper", "profit" }))
        local service = S.Services and S.Services.Trade
        local life = S.State.life and S.State.life.trade or {}
        local fromName = service and type(service.ZoneName) == "function" and service:ZoneName(life.fromZone) or "--"
        local toName = service and type(service.ZoneName) == "function" and service:ZoneName(life.toZone) or "--"
        self.routeText:SetText(tostring(d.route or (fromName .. " → " .. toName)))
        self.fromDropdown:SetItems(ZoneItems(d.zones or {}))
        self.fromDropdown:SetValue(tonumber(life.fromZone), false)
        self.toDropdown:SetItems(ZoneItems(d.sellableZones or {}))
        self.toDropdown:SetValue(tonumber(life.toZone), false)
        self.toDropdown:SetEnabled(#(d.sellableZones or {}) > 0)
        local favorite = service and type(service.IsFavorite) == "function" and service:IsFavorite(life.fromZone, life.toZone) == true
        self.favorite:SetText(favorite and "已收藏" or "收藏")
        local favoriteItems = service and type(service.GetFavoriteItems) == "function" and service:GetFavoriteItems() or {}
        self.favoriteDropdown:SetItems(favoriteItems)
        local selectedFavorite = nil
        for _, item in ipairs(favoriteItems) do if item.selected == true then selectedFavorite = item.value; break end end
        self.favoriteDropdown:SetValue(selectedFavorite, false)
        self.favoriteDropdown:SetEnabled(#favoriteItems > 0)
        if selectedFavorite == nil and self.favoriteDropdown.dropdown and self.favoriteDropdown.dropdown.trigger then
            self.favoriteDropdown.dropdown.trigger:SetText(#favoriteItems > 0 and "收藏路线  ▼" or "暂无收藏路线  ▼")
        end
        local message, tone = "请选择出发地与目的地", "muted"
        if d.status == "loading" then message, tone = "正在查询服务器实时货率……", "yellow"
        elseif d.status == "ready" then message, tone = "共 " .. tostring(#rows) .. " 种贸易货物 · 点击行查看材料 / 拍卖报价 / 毛利", "green"
        elseif d.status == "error" or d.status == "unavailable" then message, tone = "查询失败：" .. tostring(d.error or "未知原因"), "red"
        elseif tonumber(life.fromZone) ~= nil and tonumber(life.toZone) == nil then message = "已选择出发地，请选择目的地" end
        self.status:SetText(message); self.status:SetTone(tone)
        if self.actions then
            if self.actions[3] then self.actions[3]:SetText(S.State.settings.tradeSortMode == "price" and "售价排序" or "货率排序") end
            if self.actions[4] then self.actions[4]:SetText(S.State.settings.tradeAutoRefresh == true and "自动开" or "自动关") end
            if self.actions[5] then self.actions[5]:SetText(tostring(math.floor((tonumber(S.State.settings.tradeAutoRefreshMs) or 120000) / 1000)) .. "秒") end
        end
        return true
    end
    function page:ApplyLayout(spec)
        self.component:LayoutIfNeeded(0, 0, math.max(1, tonumber(spec.contentWidth) or 1), math.max(1, tonumber(spec.contentHeight) or 1))
        self:Refresh()
    end
    page:Refresh()
    return FinalizePage(page)
end

------------------------------------------------------------------------
-- Bond / resident board workspace
------------------------------------------------------------------------
local function BondRows()
    local board = S.State.data.bondBoard or {}
    local resident = S.Services and S.Services.Resident
    local entries = resident and type(resident.GetDisplayBondEntries) == "function" and resident:GetDisplayBondEntries(board.entries or {}) or (board.entries or {})
    local rows = {}
    for _, entry in ipairs(entries) do
        local bag = entry.materialKey and board.materials and board.materials[entry.materialKey] or nil
        rows[#rows + 1] = {
            continent = tostring(entry.continentLabel or "--"),
            material = tostring(entry.material or "--"),
            quantity = tonumber(entry.quantity) and tostring(math.floor(tonumber(entry.quantity))) or "--",
            requirement = tostring(entry.text or "--"),
            status = entry.questId ~= nil and (entry.completed == true and "已完成" or "未完成") or tostring(entry.status or "--"),
            bag = bag ~= nil and tostring(math.floor(tonumber(bag) or 0)) or "--",
            tone = entry.tone or (entry.completed == true and "green" or "red"),
        }
    end
    return rows
end

function W.CreateBond(parent)
    local page
    page = CreatePage(parent, "life_bond", "债券 / 居民板", "按大陆记录当天居民板需求；筛选、去重、排序均沿用 ResidentService。", {
        { text = "悬浮HUD", width = 60, onClick = function() return ToggleHud("bond") end },
        { text = "筛选设置", width = 60, onClick = function()
            local widget = S.UI and S.UI.widgets and S.UI.widgets.bond
            if widget and type(widget.OpenSettingsPanel) == "function" then widget:OpenSettingsPanel() end
            return true
        end },
        { text = "刷新", width = 44, onClick = function()
            local resident = S.Services and S.Services.Resident
            if resident and type(resident.Refresh) == "function" then resident:Refresh() end
            if resident and type(resident.RefreshStages) == "function" then resident:RefreshStages() end
            return true
        end },
    })
    if page == nil then return nil end
    page.summary = RSUI:Text({ id = "life_bond_summary", parent = page.stack, text = "居民板：--", tone = "muted", fontSize = 9, overflow = "ellipsis", slot = { size = "fixed", height = 20, hAlign = "fill", padding = { left = 4, right = 4 } } })
    local columns = {
        { id = "continent", title = "大陆", width = 82, minWidth = 66, absoluteMinWidth = 50, getText = function(r) return r.continent end },
        { id = "material", title = "类型", width = 78, minWidth = 62, absoluteMinWidth = 48, getText = function(r) return r.material end },
        { id = "quantity", title = "数量", width = 52, minWidth = 46, absoluteMinWidth = 38, getText = function(r) return r.quantity end },
        { id = "requirement", title = "今日需求", size = "fill", minWidth = 150, absoluteMinWidth = 70, getText = function(r) return r.requirement end },
        { id = "status", title = "状态", width = 70, minWidth = 58, absoluteMinWidth = 44, getText = function(r) return r.status end, getTone = function(r) return r.tone end },
        { id = "bag", title = "背包", width = 56, minWidth = 48, absoluteMinWidth = 40, getText = function(r) return r.bag end },
    }
    page.table = RSUI:TableView({ id = "life_bond_table", parent = page.stack, columns = columns, rowHeight = 22, headerHeight = 23, columnGap = 3, overscan = 3, maxPoolSize = 32, slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" } })
    page.stages = RSUI:Text({ id = "life_bond_stages", parent = page.stack, text = "居民阶段：--", tone = "muted", fontSize = 8, overflow = "ellipsis", slot = { size = "fixed", height = 20, hAlign = "fill", padding = { left = 4, right = 4 } } })

    function page:Refresh()
        local rows = BondRows()
        SetItemsIfChanged(self.table, self.cache, "bond", rows, Signature(rows, { "continent", "material", "quantity", "requirement", "status", "bag" }))
        local board = S.State.data.bondBoard or {}
        local c = board.continents or {}
        local current = board.currentContinent == "west" and "西大陆" or board.currentContinent == "east" and "东大陆" or board.currentContinent == "auroria" and "原大陆" or "--"
        self.summary:SetText("当前：" .. current .. " · 今日记录 " .. table.concat({ c.west and "西✓" or "西-", c.east and "东✓" or "东-", c.auroria and "原✓" or "原-" }, "  ") .. " · 显示 " .. tostring(#rows) .. " 条")
        local stages = {}
        for _, stage in ipairs(S.State.data.residentStages or {}) do if stage.zoneId ~= nil then stages[#stages + 1] = tostring(stage.name) .. "=" .. tostring(stage.status) end end
        self.stages:SetText(#stages > 0 and ("居民阶段：" .. table.concat(stages, " · ")) or (board.error and tostring(board.error) or "居民阶段：当前未发现三阶段状态"))
        return true
    end
    function page:ApplyLayout(spec)
        self.component:LayoutIfNeeded(0, 0, math.max(1, tonumber(spec.contentWidth) or 1), math.max(1, tonumber(spec.contentHeight) or 1))
        self:Refresh()
    end
    page:Refresh()
    return FinalizePage(page)
end

------------------------------------------------------------------------
-- Task tracking workspace
------------------------------------------------------------------------
local function TaskRows()
    local rows = {}
    local quest = S.Services and S.Services.Quest
    local completedState = S.Constants and S.Constants.QuestStatus and S.Constants.QuestStatus.COMPLETED
    local function Add(scope, source)
        local list = scope == "daily" and (S.State.data.daily or {}) or (S.State.data.weekly or {})
        for _, row in ipairs(list) do
            if scope ~= "daily" or quest == nil or type(quest.IsDailyTracked) ~= "function" or quest:IsDailyTracked(row.key) == true then
                local completed = completedState ~= nil and row.state == completedState
                if not completed or (S.State.settings.onlyIncompleteTasks ~= true and S.State.settings.showCompletedTasks ~= false) then
                    rows[#rows + 1] = {
                        source = source, name = tostring(row.name or row.key or "任务"),
                        progress = (tonumber(row.total) or 0) > 0 and (tostring(tonumber(row.completed) or 0) .. "/" .. tostring(tonumber(row.total) or 0)) or "--",
                        status = tostring(row.status or "--"), tone = row.tone or "muted", scope = scope, key = row.key,
                    }
                end
            end
        end
    end
    Add("daily", "日常")
    -- Event Objective Tracking is intentionally managed on the Activity surface.
    -- It has a different Authority from dailyTracking and must not be presented
    -- as if it were part of the same user-selected task list. There is also no
    -- persisted weekly-selection Authority today, so weekly rows stay out of
    -- this "my tracked" projection until a real weeklyTracking policy exists.
    if #rows == 0 then
        rows[1] = { source = "日常", name = "尚未选择追踪日常", progress = "--", status = "点“自定义”选择", tone = "yellow", placeholder = true }
    end
    return rows
end

function W.CreateTasks(parent)
    local page
    page = CreatePage(parent, "life_tasks", "任务追踪", "仅显示 dailyTracking 选择项；活动目标在“活动”中独立管理，周常当前没有独立选择 Authority。", {
        { text = "悬浮HUD", width = 60, onClick = function() return ToggleHud("task") end },
        { text = "自定义", width = 50, onClick = function() if S.DailyCustomWindow and S.DailyCustomWindow.Open then S.DailyCustomWindow:Open() end return true end },
        { text = "完成项", width = 50, onClick = function()
            S.State.settings.showCompletedTasks = not (S.State.settings.showCompletedTasks == true)
            S.State:MarkDirty("quests"); S.Storage:RequestSave(); if page then page:Refresh() end
            return true
        end },
        { text = "过滤", width = 48, onClick = function()
            S.State.settings.onlyIncompleteTasks = not (S.State.settings.onlyIncompleteTasks == true)
            S.State:MarkDirty("quests"); S.Storage:RequestSave(); if page then page:Refresh() end
            return true
        end },
    })
    if page == nil then return nil end
    local columns = {
        { id = "source", title = "来源", width = 58, minWidth = 48, absoluteMinWidth = 40, getText = function(r) return r.source end },
        { id = "name", title = "任务名称", size = "fill", minWidth = 170, absoluteMinWidth = 80, getText = function(r) return r.name end },
        { id = "progress", title = "进度", width = 70, minWidth = 56, absoluteMinWidth = 44, getText = function(r) return r.progress end },
        { id = "status", title = "状态", width = 100, minWidth = 72, absoluteMinWidth = 52, getText = function(r) return r.status end, getTone = function(r) return r.tone end },
    }
    page.table = RSUI:TableView({
        id = "life_tasks_table", parent = page.stack, columns = columns, rowHeight = 22, headerHeight = 23, columnGap = 3, overscan = 3, maxPoolSize = 30,
        rowFactory = function(list, poolIndex, tableView)
            return CreateClickableTableRow("life_tasks_table", list, poolIndex, tableView, function(row)
                if row == nil or row.placeholder == true then
                    if S.DailyCustomWindow and type(S.DailyCustomWindow.Open) == "function" then S.DailyCustomWindow:Open() end
                    return
                end
                local service = S.Services and S.Services.Quest
                if row.key and service and type(service.OpenGroupDetail) == "function" then service:OpenGroupDetail(row.scope or "daily", row.key) end
            end)
        end,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })
    function page:Refresh()
        local rows = TaskRows()
        SetItemsIfChanged(self.table, self.cache, "tasks", rows, Signature(rows, { "source", "name", "progress", "status" }))
        if self.actions then
            if self.actions[3] then self.actions[3]:SetText(S.State.settings.showCompletedTasks == true and "完成显示" or "完成隐藏") end
            if self.actions[4] then self.actions[4]:SetText(S.State.settings.onlyIncompleteTasks == true and "仅未完成" or "全部任务") end
        end
        return true
    end
    function page:ApplyLayout(spec) self.component:LayoutIfNeeded(0, 0, math.max(1, tonumber(spec.contentWidth) or 1), math.max(1, tonumber(spec.contentHeight) or 1)); self:Refresh() end
    page:Refresh()
    return FinalizePage(page)
end

------------------------------------------------------------------------
-- Treasure workspace
------------------------------------------------------------------------
function W.CreateTreasure(parent)
    local page
    page = CreatePage(parent, "life_treasure", "寻宝助手", "管理藏宝图；实时方向 / 距离仍由独立 HUD 在显示时按 250ms 更新。", {
        { text = "悬浮HUD", width = 60, onClick = function() return ToggleHud("treasure") end },
        { text = "刷新背包", width = 60, onClick = function() local s=S.Services and S.Services.Treasure; if s and s.ForceRefresh then s:ForceRefresh() end return true end },
    })
    if page == nil then return nil end
    page.selector = RSUI:HorizontalBox({ id = "life_treasure_selector", parent = page.stack, gap = 5, slot = { size = "fixed", height = 32, hAlign = "fill" } })
    page.prev = RSUI:Button({ id = "life_treasure_prev", parent = page.selector, text = "◀上一张", compact = true, gradient = true, slot = { size = "fixed", width = 70 }, onClick = function()
        local d=S.State.data.treasure or {}; local maps=d.maps or {}; if #maps==0 then return true end
        local idx=1; for i,m in ipairs(maps) do if tostring(m.key)==tostring(d.selectedKey) then idx=i break end end
        idx=((idx-2)%#maps)+1; local s=S.Services and S.Services.Treasure; if s and s.SelectMap then s:SelectMap(maps[idx].key); if s.UpdatePosition then s:UpdatePosition() end end; return true
    end })
    page.current = RSUI:Text({ id = "life_treasure_current", parent = page.selector, text = "未发现藏宝图", tone = "accent", fontSize = 10, overflow = "ellipsis", slot = { size = "fill", fill = 1, minWidth = 100, hAlign = "fill", vAlign = "center" } })
    page.next = RSUI:Button({ id = "life_treasure_next", parent = page.selector, text = "下一张▶", compact = true, gradient = true, slot = { size = "fixed", width = 70 }, onClick = function()
        local d=S.State.data.treasure or {}; local maps=d.maps or {}; if #maps==0 then return true end
        local idx=0; for i,m in ipairs(maps) do if tostring(m.key)==tostring(d.selectedKey) then idx=i break end end
        idx=(idx%#maps)+1; local s=S.Services and S.Services.Treasure; if s and s.SelectMap then s:SelectMap(maps[idx].key); if s.UpdatePosition then s:UpdatePosition() end end; return true
    end })
    page.directionCard = RSUI:Border({ id = "life_treasure_direction_card", parent = page.stack, padding = 10, variant = "card", gradient = true, slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" } })
    page.directionStack = RSUI:VerticalBox({ id = "life_treasure_direction_stack", parent = page.directionCard, gap = 4 })
    page.arrow = RSUI:Text({ id = "life_treasure_arrow", parent = page.directionStack, text = "--", tone = "yellow", fontSize = 34, align = "center", slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "center" } })
    page.direction = RSUI:Text({ id = "life_treasure_direction", parent = page.directionStack, text = "方向：--", tone = "blue", fontSize = 12, align = "center", slot = { size = "fixed", height = 28, hAlign = "fill" } })
    page.distance = RSUI:Text({ id = "life_treasure_distance", parent = page.directionStack, text = "距离：--", tone = "blue", fontSize = 15, align = "center", slot = { size = "fixed", height = 32, hAlign = "fill" } })
    function page:Refresh()
        local d=S.State.data.treasure or {}; local maps=d.maps or {}; local selectedText="未发现藏宝图"
        for i,m in ipairs(maps) do if tostring(m.key)==tostring(d.selectedKey) then selectedText="藏宝图 "..tostring(i).."/"..tostring(#maps).." · "..tostring(m.text or "--") break end end
        self.current:SetText(selectedText); self.prev:SetEnabled(#maps>1); self.next:SetEnabled(#maps>1)
        self.arrow:SetText(tostring(d.arrow or "--")); self.direction:SetText("方向："..tostring(d.directionShort or "--").."  "..tostring(d.direction or "--"))
        local dist=tonumber(d.distance); self.distance:SetText("距离："..(dist and string.format("%.1f m",dist) or "--"))
        self.distance:SetTone(dist and (dist<=20 and "green" or dist<=100 and "yellow" or "blue") or "muted")
        self.arrow:SetTone(dist and (dist<=20 and "green" or dist<=100 and "yellow" or "blue") or "muted")
        return true
    end
    function page:ApplyLayout(spec) self.component:LayoutIfNeeded(0,0,math.max(1,tonumber(spec.contentWidth) or 1),math.max(1,tonumber(spec.contentHeight) or 1)); self:Refresh() end
    page:Refresh()
    return FinalizePage(page)
end

------------------------------------------------------------------------
-- Fishing workspace
------------------------------------------------------------------------
function W.CreateFishing(parent)
    local page
    page = CreatePage(parent, "life_fishing", "智能钓鱼", "识别鱼动作 Buff 后给出技能推荐；Auto-R 的临时按键修改仍由 FishingService 负责安全恢复。", {
        { text = "悬浮HUD", width = 60, onClick = function() return ToggleHud("fishing") end },
        { text = "自动R", width = 50, onClick = function() local s=S.Services and S.Services.Fishing; if s and s.ToggleAuto then s:ToggleAuto() end return true end },
    })
    if page == nil then return nil end
    page.card = RSUI:Border({ id = "life_fishing_card", parent = page.stack, padding = 12, variant = "card", gradient = true, slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" } })
    page.body = RSUI:VerticalBox({ id = "life_fishing_body", parent = page.card, gap = 8 })
    page.status = RSUI:Text({ id = "life_fishing_status", parent = page.body, text = "等待目标", tone = "yellow", fontSize = 13, overflow = "ellipsis", slot = { size = "fixed", height = 28, hAlign = "fill" } })
    page.recommend = RSUI:Text({ id = "life_fishing_recommend", parent = page.body, text = "推荐：--", tone = "blue", fontSize = 18, overflow = "ellipsis", slot = { size = "fixed", height = 38, hAlign = "fill" } })
    page.auto = RSUI:Text({ id = "life_fishing_auto", parent = page.body, text = "Auto-R：关", tone = "muted", fontSize = 11, overflow = "ellipsis", slot = { size = "fixed", height = 24, hAlign = "fill" } })
    page.protect = RSUI:Text({ id = "life_fishing_protect", parent = page.body, text = "关闭 HUD / 切换动作 / Reload 时会恢复原按键；读不到原键则拒绝改键。", tone = "muted", fontSize = 9, overflow = "wrap", maxLines = 3, slot = { size = "fill", fill = 1, hAlign = "fill" } })
    function page:Refresh()
        local d=S.State.data.fishing or {}; local slot=tonumber(d.slot)
        self.status:SetText(tostring(d.message or "等待目标"))
        self.recommend:SetText(slot and ("推荐：R / 技能栏 "..tostring(slot)) or "推荐：--")
        self.auto:SetText(d.auto==true and "Auto-R：已开启" or "Auto-R：关闭"); self.auto:SetTone(d.auto==true and "green" or "muted")
        return true
    end
    function page:ApplyLayout(spec) self.component:LayoutIfNeeded(0,0,math.max(1,tonumber(spec.contentWidth) or 1),math.max(1,tonumber(spec.contentHeight) or 1)); self:Refresh() end
    page:Refresh()
    return FinalizePage(page)
end

function W.CreateAll(parent)
    local pages = {}
    local creators = {
        W.CreateActivity, W.CreateTrade, W.CreateBond, W.CreateTasks, W.CreateTreasure, W.CreateFishing,
    }
    for _, create in ipairs(creators) do
        local ok, page = xpcall(function() return create(parent) end, S.SafeTraceback)
        if ok and page ~= nil then
            pages[#pages + 1] = page
        else
            S.WarnOnce("life_workspace_create:" .. tostring(#pages + 1), "M3 生活工作区创建失败：" .. tostring(page))
        end
    end
    W.pages = pages
    return pages
end

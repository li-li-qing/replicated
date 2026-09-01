------------------------------------------------------------------------
-- Replicated Suite - High-density Today Dashboard (M2)
--
-- Presentation only. This composite consumes the existing Quest / Event /
-- Trade / Resident / Resource Authorities and never scans X2 APIs itself.
-- Large row sets use RSUI TableView virtualization; refreshes are dirty-driven
-- by rs_ui_factory.lua rather than Tick/OnUpdate.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI = S.RSUI
if type(RSUI) ~= "table" then return end

S.DashboardPage = {}
local P = S.DashboardPage

local function Clamp(value, lo, hi)
    local n = tonumber(value) or lo or 0
    if lo ~= nil then n = math.max(n, tonumber(lo) or n) end
    if hi ~= nil then n = math.min(n, tonumber(hi) or n) end
    return n
end

local function SignedInteger(value)
    local n = math.floor(tonumber(value) or 0)
    if n > 0 then return "+" .. tostring(n) end
    return tostring(n)
end

local function ToneForDelta(value, positiveTone)
    local n = tonumber(value) or 0
    if n > 0 then return positiveTone or "green" end
    if n < 0 then return "red" end
    return "muted"
end

local function FormatClock(seconds)
    local value = tonumber(seconds)
    if value == nil then return "--" end
    value = math.max(0, math.floor(value))
    local days = math.floor(value / 86400)
    value = value % 86400
    local hours = math.floor(value / 3600)
    local minutes = math.floor((value % 3600) / 60)
    local secs = value % 60
    if days > 0 then return string.format("%d天 %02d:%02d:%02d", days, hours, minutes, secs) end
    return string.format("%02d:%02d:%02d", hours, minutes, secs)
end

local function FormatEventServiceCountdown(seconds)
    local value = math.max(0, math.floor(tonumber(seconds) or 0))
    if value < 60 then return tostring(value) .. "秒" end
    local minutes = math.floor(value / 60)
    if minutes < 60 then return tostring(minutes) .. "分" end
    local hours = math.floor(minutes / 60)
    minutes = minutes % 60
    if hours < 24 then
        if minutes > 0 then return tostring(hours) .. "时" .. tostring(minutes) .. "分" end
        return tostring(hours) .. "时"
    end
    local days = math.floor(hours / 24)
    hours = hours % 24
    if hours > 0 then return tostring(days) .. "天" .. tostring(hours) .. "时" end
    return tostring(days) .. "天"
end

local function EventPhase(row)
    if type(row) ~= "table" then return "--" end
    local status = tostring(row.status or "")
    if status == "" then return row.active == true and "进行中" or "--" end
    if row.seconds ~= nil then
        local token = FormatEventServiceCountdown(row.seconds)
        if status == token and row.active ~= true then return "即将开始" end
        if status == "进行中 " .. token then return "进行中" end
        if #token > 0 and #status > #token and string.sub(status, -#token) == token then
            local prefix = string.gsub(string.sub(status, 1, #status - #token), "%s+$", "")
            if prefix ~= "" then return prefix end
        end
    end
    return status
end

local function OpenEvent(row)
    local service = S.Services and S.Services.Event
    if type(row) == "table" and row.questKey ~= nil and service ~= nil and type(service.OpenTask) == "function" then
        service:OpenTask(row)
        return true
    end
    return false
end

local function OpenTrackedQuest(row)
    if type(row) ~= "table" then return false end
    if row.placeholder == true then
        if S.DailyCustomWindow ~= nil and type(S.DailyCustomWindow.Open) == "function" then
            S.DailyCustomWindow:Open()
            return true
        end
        return false
    end
    if row.source == "活动" and row.eventRow ~= nil then return OpenEvent(row.eventRow) end
    local service = S.Services and S.Services.Quest
    if service ~= nil and type(service.OpenGroupDetail) == "function" and row.key ~= nil then
        service:OpenGroupDetail(row.scope or "daily", row.key)
        return true
    end
    return false
end

local function ToggleHud(name)
    if S.UI ~= nil and type(S.UI.ToggleWidget) == "function" then S.UI:ToggleWidget(name) end
end

local function OpenBondSettings()
    local widget = S.UI and S.UI.widgets and S.UI.widgets.bond
    if widget ~= nil and type(widget.OpenSettingsPanel) == "function" then widget:OpenSettingsPanel() end
end

local function CreateClickableTableRow(tableId, list, poolIndex, tableView, onClick, onRightClick)
    local row = RSUI:TableRow({
        id = tableId .. "_row_" .. tostring(poolIndex),
        parent = list,
        columns = tableView.columns,
        resolvedWidths = tableView.resolvedWidths,
        rowHeight = tableView.rowHeight,
        columnGap = tableView.columnGap,
        pickable = true,
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
        end, tableId .. ":right_click:" .. tostring(poolIndex))
    end
    return row
end

local function CreateCard(parent, id, title, actions, opts)
    opts = type(opts) == "table" and opts or {}
    if S.Visual ~= nil and S.Visual.DashboardCard ~= nil and type(S.Visual.DashboardCard.Create) == "function" then
        opts.headerHeight = tonumber(opts.headerHeight) or 32
        opts.gap = tonumber(opts.gap) or 3
        local card = S.Visual.DashboardCard:Create(parent, id, title, actions, opts)
        if card ~= nil then return card end
    end
    local card = { id = id, actions = {} }
    card.component = RSUI:Border({ id = id .. "_card", parent = parent, width = 100, height = 100, padding = 6, variant = "card", gradient = true, accentStrip = 2 })
    card.root = card.component and card.component.root or nil
    card.stack = RSUI:VerticalBox({ id = id .. "_stack", parent = card.component, gap = 4 })
    card.header = RSUI:HorizontalBox({ id = id .. "_header", parent = card.stack, gap = 4, slot = { size = "fixed", height = 25, hAlign = "fill" } })
    card.title = RSUI:Text({ id = id .. "_title", parent = card.header, text = title, tone = "accent", fontSize = 13, shadow = true, overflow = "ellipsis", slot = { size = "fill", fill = 1, minWidth = 30, hAlign = "fill", vAlign = "center" } })
    for index, action in ipairs(type(actions) == "table" and actions or {}) do
        local button = RSUI:Button({ id = id .. "_action_" .. tostring(index), parent = card.header, text = tostring(action.text or "操作"), fontSize = 8, compact = true, gradient = true, slot = { size = "fixed", width = tonumber(action.width) or 45, hAlign = "fill" }, onClick = action.onClick })
        card.actions[#card.actions + 1] = button
    end
    return card
end

local function AddFooterButton(parent, id, text, width, onClick, variant)
    if S.Visual and S.Visual.ActionButton and type(S.Visual.ActionButton.Create) == "function" then
        return S.Visual.ActionButton:Create({
            id = id, parent = parent, text = text, fontSize = 9, compact = true,
            visualVariant = variant or "ghost",
            slot = { size = "fixed", width = tonumber(width) or 70, hAlign = "fill", vAlign = "center" },
            onClick = onClick,
        })
    end
    return RSUI:Button({ id = id, parent = parent, text = text, fontSize = 8, compact = true, slot = { size = "fixed", width = tonumber(width) or 70, hAlign = "fill" }, onClick = onClick })
end

local function SetItemsIfChanged(tableView, cache, key, rows, signature)
    signature = tostring(signature or "")
    if cache[key] == signature then return false end
    cache[key] = signature
    tableView:SetItems(rows, signature)
    return true
end

local function ServerClockText(includeDate)
    local t = S.Utils and type(S.Utils.GetServerTime) == "function" and S.Utils.GetServerTime() or nil
    if type(t) ~= "table" then return includeDate and "--/-- --:--:--" or "--:--:--" end
    local hour, minute, second = tonumber(t.hour) or 0, tonumber(t.minute) or 0, tonumber(t.second) or 0
    if includeDate then
        return string.format("%02d/%02d %02d:%02d:%02d", tonumber(t.month) or 0, tonumber(t.day) or 0, hour, minute, second)
    end
    return string.format("%02d:%02d:%02d", hour, minute, second)
end

local function CompactTrackerStatus(status, progress)
    local text = S.Utils and type(S.Utils.Trim)=="function" and S.Utils.Trim(tostring(status or "")) or tostring(status or "")
    local p = tostring(progress or "")
    if p ~= "" and p ~= "--" and #text >= #p and string.sub(text, -#p) == p then
        text = string.gsub(string.sub(text, 1, #text - #p), "%s+$", "")
    end
    if text == "" then text = "进行中" end
    return text
end

local function BuildTrackerRows()
    local rows = {}
    local quest = S.Services and S.Services.Quest
    local completedState = S.Constants and S.Constants.QuestStatus and S.Constants.QuestStatus.COMPLETED
    local function IncludeQuest(row, scope)
        if type(row) ~= "table" then return end
        if scope == "daily" and quest ~= nil and type(quest.IsDailyTracked) == "function" and quest:IsDailyTracked(row.key) ~= true then return end
        local completed = completedState ~= nil and row.state == completedState
        if completed and (S.State.settings.onlyIncompleteTasks == true or S.State.settings.showCompletedTasks == false) then return end
        rows[#rows + 1] = {
            source = scope == "daily" and "日常" or "周常",
            name = tostring(row.name or row.key or "任务"),
            progress = (tonumber(row.total) or 0) > 0 and (tostring(tonumber(row.completed) or 0) .. "/" .. tostring(tonumber(row.total) or 0)) or "--",
            status = CompactTrackerStatus(row.status, (tonumber(row.total) or 0) > 0 and (tostring(tonumber(row.completed) or 0) .. "/" .. tostring(tonumber(row.total) or 0)) or "--"),
            tone = row.tone or "muted",
            scope = scope, key = row.key,
        }
    end
    for _, row in ipairs(S.State.data.daily or {}) do IncludeQuest(row, "daily") end
    -- There is currently no persisted weekly-selection Authority equivalent to
    -- dailyTracking. Do not silently label every weekly as "my tracked" here.
    -- Event Objective Tracking is also a separate Authority owned by the activity
    -- surface, so it must not be duplicated into this dashboard projection.

    if #rows == 0 then
        rows[1] = { source = "日常", name = "尚未选择追踪日常", progress = "--", status = "点“自定义”", tone = "yellow", placeholder = true }
    end
    return rows
end

local function BuildTrackerSignature(rows)
    local parts = { tostring(#rows) }
    for i, row in ipairs(rows) do
        parts[#parts + 1] = table.concat({ tostring(i), tostring(row.source), tostring(row.name), tostring(row.progress), tostring(row.status) }, ":")
    end
    return table.concat(parts, "|")
end

local function BuildBondRows()
    local board = S.State.data.bondBoard or {}
    local resident = S.Services and S.Services.Resident
    local entries = resident ~= nil and type(resident.GetDisplayBondEntries) == "function"
        and resident:GetDisplayBondEntries(board.entries or {}) or (board.entries or {})
    local rows = {}
    for _, entry in ipairs(entries) do
        local materialCount = entry.materialKey ~= nil and board.materials and board.materials[entry.materialKey] or nil
        rows[#rows + 1] = {
            continent = tostring(entry.continentLabel or "--"),
            requirement = tostring(entry.text ~= nil and entry.text ~= "" and entry.text or entry.material or "债券"),
            status = entry.questId ~= nil and (entry.completed == true and "已完成" or "未完成") or tostring(entry.status or "--"),
            bag = materialCount ~= nil and tostring(math.floor(tonumber(materialCount) or 0)) or "--",
            tone = entry.tone or "muted",
        }
    end
    if #rows == 0 then
        rows[1] = { continent = "--", requirement = "进入居民板区域后自动记录当天信息", status = "--", bag = "--", tone = "muted" }
    end
    return rows
end

local function BuildBondSignature(rows)
    local parts = { tostring(#rows) }
    for i, row in ipairs(rows) do
        parts[#parts + 1] = table.concat({ tostring(i), row.continent, row.requirement, row.status, row.bag }, ":")
    end
    return table.concat(parts, "|")
end

local function BuildTodayRows()
    local counters = S.State.dailyCounters or {}
    local gold = tonumber(counters.gold) or 0
    local exp = tonumber(counters.exp) or 0
    local honor = tonumber(counters.honor) or 0
    local vocation = tonumber(counters.vocation) or 0
    return {
        { name = "金币净变化", value = S.Utils.FormatCompactMoney(gold, true), tone = ToneForDelta(gold, "green") },
        { name = "经验获得", value = SignedInteger(exp), tone = ToneForDelta(exp, "green") },
        { name = "荣誉获得", value = SignedInteger(honor), tone = ToneForDelta(honor, "purple") },
        { name = "生活点获得", value = SignedInteger(vocation), tone = ToneForDelta(vocation, "blue") },
    }
end

local function BuildTodaySignature(rows)
    local parts = {}
    for _, row in ipairs(rows) do parts[#parts + 1] = tostring(row.name) .. ":" .. tostring(row.value) end
    return table.concat(parts, "|")
end

local function CurrentTradeData()
    return S.State.data.trade or {}
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

function P.Create(parent)
    if parent == nil then return nil end
    local page = {
        key = "life", parent = parent, cache = {}, revision = 0,
        bondRows = {}, trackerRows = {}, todayRows = {},
    }

    page.component = RSUI:Border({
        id = "dashboard_page", parent = parent,
        width = 100, height = 100, padding = 0, variant = "soft", gradient = false,
    })
    page.root = page.component and page.component.root or nil
    if page.root == nil then return nil end
    if page.root.rsBorder and page.root.rsBorder.SetVisible then page.root.rsBorder:SetVisible(false) end
    if page.root.rsBackground and page.root.rsBackground.SetVisible then page.root.rsBackground:SetVisible(false) end

    ------------------------------------------------------------------------
    -- Activity / world status: full-width, multi-event virtualized table.
    ------------------------------------------------------------------------
    page.activityCard = CreateCard(page.root, "dashboard_activity", "活动 / 世界状态", {
        { text = "全部", width = 44, variant = "ghost", onClick = function() if S.UI and type(S.UI.ShowPage)=="function" then S.UI:ShowPage("life_activity") end; return true end },
        { text = "恢复", width = 46, variant = "ghost", onClick = function() local service=S.Services and S.Services.Event; if service and type(service.RestoreHiddenEvents)=="function" then service:RestoreHiddenEvents() end; return true end },
        { text = "悬浮HUD", width = 58, variant = "primary", onClick = function() ToggleHud("event"); return true end },
    }, { accentTone = "cyan", iconKind = "activity", titleTone = "primary", topAccentTone = "goldSoft", subtitle = ServerClockText(true) })
    local activityColumns = {
        { id = "mark", title = "", width = 26, minWidth = 24, absoluteMinWidth = 20, align = ALIGN_CENTER,
          getText = function(row) return row and (row.active == true and "◆" or "◇") or "◇" end,
          getTone = function(row) return row and row.tone or "muted" end },
        { id = "name", title = "活动名称", size = "fill", minWidth = 112, absoluteMinWidth = 56, getText = function(row) return tostring(row and (row.name or row.shortName) or "--") end },
        { id = "phase", title = "状态 / 阶段", width = 118, minWidth = 80, absoluteMinWidth = 48, getText = EventPhase, getTone = function(row) return row and row.tone or "muted" end },
        { id = "remain", title = "剩余时间", width = 82, minWidth = 68, absoluteMinWidth = 48, getText = function(row) return row and FormatClock(row.seconds) or "--" end, getTone = function(row) return row and row.tone or "muted" end },
        { id = "progress", title = "进度", width = 68, minWidth = 54, absoluteMinWidth = 40, getText = function(row) return row and tostring(row.progressText or "--") or "--" end, getTone = function(row) return row and (row.progressTone or "muted") or "muted" end },
    }
    page.activityTable = RSUI:TableView({
        id = "dashboard_activity_table", parent = page.activityCard.stack,
        columns = activityColumns, rowHeight = 21, headerHeight = 23, columnGap = 2, cellPaddingX = 6, fontSize = 9, overscan = 2, maxPoolSize = 20,
        getCount = function() return math.min(12, #(S.State.data.events or {})) end,
        getItem = function(index) return (S.State.data.events or {})[index] end,
        getKey = function(row, index) return row and (row.reminderOccurrence or row.questKey or row.name) or index end,
        rowFactory = function(list, poolIndex, tableView)
            return CreateClickableTableRow("dashboard_activity_table", list, poolIndex, tableView, OpenEvent, function(row)
                local service = S.Services and S.Services.Event
                if service ~= nil and type(service.HideEvent) == "function" then service:HideEvent(row) end
            end)
        end,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })


    ------------------------------------------------------------------------
    -- Trade: route controls + all authoritative goods for the route.
    ------------------------------------------------------------------------
    page.tradeCard = CreateCard(page.root, "dashboard_trade", "跑商货率", {
        { text = "悬浮", width = 46, onClick = function() ToggleHud("trade"); return true end },
    }, { accentTone = "cyan", iconKind = "trade", titleTone = "primary", topAccentTone = "goldSoft" })
    page.tradeRouteLabel = RSUI:Text({
        id = "dashboard_trade_route_label", parent = page.tradeCard.stack,
        text = "当前路线：请选择出发地与目的地", tone = "accent", fontSize = 10, overflow = "ellipsis",
        slot = { size = "fixed", height = 18, hAlign = "fill", padding = { left = 2, right = 2 } },
    })
    page.tradeRouteRow = RSUI:HorizontalBox({
        id = "dashboard_trade_route", parent = page.tradeCard.stack, gap = 5,
        slot = { size = "fixed", height = 29, hAlign = "fill" },
    })
    local function CreateTradeDropdown(spec)
        if S.Visual ~= nil and S.Visual.StyledDropdown ~= nil and type(S.Visual.StyledDropdown.Create) == "function" then
            return S.Visual.StyledDropdown:Create(spec)
        end
        return RSUI:Dropdown(spec)
    end
    page.tradeFrom = CreateTradeDropdown({
        id = "dashboard_trade_from", parent = page.tradeRouteRow, width = 190, height = 27, maxVisible = 14, popupWidth = 270,
        items = {}, value = nil,
        slot = { size = "fill", fill = 1, minWidth = 86, hAlign = "fill" },
        onChanged = function(value)
            local service = S.Services and S.Services.Trade
            if service and type(service.SelectFrom) == "function" then service:SelectFrom(value) end
        end,
    })
    page.tradeTo = CreateTradeDropdown({
        id = "dashboard_trade_to", parent = page.tradeRouteRow, width = 190, height = 27, maxVisible = 14, popupWidth = 270,
        items = {}, value = nil,
        slot = { size = "fill", fill = 1, minWidth = 86, hAlign = "fill" },
        onChanged = function(value)
            local service = S.Services and S.Services.Trade
            if service and type(service.SelectTo) == "function" then service:SelectTo(value) end
        end,
    })
    page.tradeRefresh = RSUI:Button({
        id = "dashboard_trade_refresh", parent = page.tradeRouteRow, text = "刷新", fontSize = 8, compact = true, gradient = true,
        slot = { size = "fixed", width = 48, hAlign = "fill" },
        onClick = function()
            local service = S.Services and S.Services.Trade
            if service and type(service.Request) == "function" then service:Request(true) end
            return true
        end,
    })
    if S.Visual ~= nil and S.Visual.ActionButton ~= nil and type(S.Visual.ActionButton.Apply) == "function" then
        S.Visual.ActionButton:Apply(page.tradeRefresh, "ghost")
    end
    page.tradeStatus = RSUI:Text({
        id = "dashboard_trade_status", parent = page.tradeCard.stack,
        text = "请选择路线", tone = "muted", fontSize = 9, overflow = "ellipsis",
        slot = { size = "fixed", height = 16, hAlign = "fill" },
    })
    page.tradeEmptyHint = RSUI:Border({
        id = "dashboard_trade_empty", parent = page.tradeCard.stack,
        height = 38, padding = { left = 10, right = 10, top = 4, bottom = 4 },
        variant = "soft", gradient = false,
        slot = { size = "fixed", height = 38, hAlign = "fill" },
    })
    if page.tradeEmptyHint and S.Visual and S.Visual.Surface then
        S.Visual.Surface:Apply(page.tradeEmptyHint.root, {
            surface = "cardRaised", borderTone = "cyanFaint", topAccent = false,
        })
    end
    page.tradeEmptyText = RSUI:Text({
        id = "dashboard_trade_empty_text", parent = page.tradeEmptyHint,
        text = "选择出发地与目的地后，将显示该路线的全部货物、货率、预计售价与毛利。",
        tone = "caption", fontSize = 9, overflow = "wrap", maxLines = 2,
    })
    local tradeColumns = {
        { id = "name", title = "货物名称", size = "fill", minWidth = 104, absoluteMinWidth = 58, field = "name" },
        { id = "rate", title = "货率", width = 55, minWidth = 48, absoluteMinWidth = 34, getText = function(row) return tostring(row and (row.rate or (row.ratio and tostring(row.ratio) .. "%")) or "--") end, getTone = function(row) return row and row.tone or "muted" end },
        { id = "price", title = "预计售价", width = 72, minWidth = 60, absoluteMinWidth = 42, field = "price", getTone = function(row) return row and row.tone or "muted" end },
        { id = "materials", title = "材料", width = 48, minWidth = 42, absoluteMinWidth = 30, getText = function(row)
            local count = type(row) == "table" and type(row.materials) == "table" and #row.materials or 0
            return count > 0 and tostring(count) or "--"
        end, tone = "muted" },
        { id = "cost", title = "材料成本", width = 72, minWidth = 58, absoluteMinWidth = 40, getText = function(row) return tostring(row and row.materialCost or "--") end, getTone = function(row) return row and row.materialCostCopper ~= nil and "yellow" or "muted" end },
        { id = "profit", title = "毛利", width = 68, minWidth = 56, absoluteMinWidth = 40, field = "profit", getTone = function(row)
            local value = row and tonumber(row.profitCopper) or nil
            if value == nil then return "muted" end
            return value >= 0 and "green" or "red"
        end },
    }
    page.tradeTable = RSUI:TableView({
        id = "dashboard_trade_table", parent = page.tradeCard.stack,
        columns = tradeColumns, rowHeight = 21, headerHeight = 23, columnGap = 2, cellPaddingX = 5, fontSize = 9, overscan = 2, maxPoolSize = 20,
        getCount = function() return #(CurrentTradeData().rows or {}) end,
        getItem = function(index) return (CurrentTradeData().rows or {})[index] end,
        getKey = function(row, index) return row and (row.packKey or row.itemType or row.name) or index end,
        rowFactory = function(list, poolIndex, tableView)
            return CreateClickableTableRow("dashboard_trade_table", list, poolIndex, tableView, function(row)
                local service = S.Services and S.Services.Trade
                if service and type(service.SelectPack) == "function" then service:SelectPack(row, true) end
            end)
        end,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })
    page.tradeFooter = RSUI:HorizontalBox({
        id = "dashboard_trade_footer", parent = page.tradeCard.stack, gap = 6,
        slot = { size = "fixed", height = 25, hAlign = "fill" },
    })
    AddFooterButton(page.tradeFooter, "dashboard_trade_favorite", "收藏路线", 68, function()
        local service = S.Services and S.Services.Trade
        if service and type(service.ToggleCurrentFavorite) == "function" then service:ToggleCurrentFavorite() end
        return true
    end)
    AddFooterButton(page.tradeFooter, "dashboard_trade_detail", "货物详情", 68, function()
        local service = S.Services and S.Services.Trade
        local selected = CurrentTradeData().selectedPack
        if type(selected) == "table" and S.TradeDetailWindow and type(S.TradeDetailWindow.ShowPack) == "function" then S.TradeDetailWindow:ShowPack(); return true end
        local row = (CurrentTradeData().rows or {})[1]
        if service and row and type(service.SelectPack) == "function" then service:SelectPack(row, true) end
        return true
    end)
    AddFooterButton(page.tradeFooter, "dashboard_trade_quote", "材料询价", 68, function()
        local service = S.Services and S.Services.Trade
        if service and type(service.QuoteSelectedPack) == "function" then service:QuoteSelectedPack() end
        return true
    end)
    AddFooterButton(page.tradeFooter, "dashboard_trade_open", "打开跑商页", 76, function()
        if S.UI and type(S.UI.ShowPage) == "function" then S.UI:ShowPage("life_trade") end
        return true
    end, "primary")

    ------------------------------------------------------------------------
    -- Bonds / resident boards: filtered real multi-continent board entries.
    ------------------------------------------------------------------------
    page.bondCard = CreateCard(page.root, "dashboard_bond", "债券 / 居民板", {
        { text = "设置", width = 43, onClick = function() OpenBondSettings(); return true end },
        { text = "悬浮", width = 43, onClick = function() ToggleHud("bond"); return true end },
    }, { accentTone = "gold", iconKind = "bond", titleTone = "brand", topAccentTone = "goldSoft" })
    page.bondFilterRow = RSUI:HorizontalBox({
        id = "dashboard_bond_filters", parent = page.bondCard.stack, gap = 4,
        slot = { size = "fixed", height = 27, hAlign = "fill" },
    })
    page.bondFilterButtons = {}
    local function BondFilterButton(key, text, width)
        local button = AddFooterButton(page.bondFilterRow, "dashboard_bond_filter_" .. key, text, width, function()
            local service = S.Services and S.Services.Resident
            if service == nil then return true end
            if key == "all" then
                for _, filterKey in ipairs({ "q20", "q60", "q100", "auroria" }) do if type(service.SetBondFilterOption) == "function" then service:SetBondFilterOption(filterKey, true) end end
            elseif type(service.ToggleBondFilterOption) == "function" then service:ToggleBondFilterOption(key) end
            return true
        end)
        page.bondFilterButtons[key] = button
    end
    BondFilterButton("all", "全部", 42); BondFilterButton("q20", "20", 34); BondFilterButton("q60", "60", 34); BondFilterButton("q100", "100", 38); BondFilterButton("auroria", "原大陆", 54)
    local bondColumns = {
        { id = "continent", title = "大陆", width = 48, minWidth = 42, absoluteMinWidth = 30, field = "continent" },
        { id = "need", title = "今日需求 / 数量", size = "fill", minWidth = 92, absoluteMinWidth = 52, field = "requirement" },
        { id = "status", title = "状态", width = 54, minWidth = 46, absoluteMinWidth = 34, field = "status", getTone = function(row) return row and row.tone or "muted" end },
        { id = "bag", title = "背包", width = 42, minWidth = 38, absoluteMinWidth = 28, field = "bag" },
    }
    page.bondTable = RSUI:TableView({
        id = "dashboard_bond_table", parent = page.bondCard.stack,
        columns = bondColumns, rowHeight = 21, headerHeight = 23, columnGap = 1, cellPaddingX = 5, fontSize = 9, overscan = 2, maxPoolSize = 20,
        items = page.bondRows,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })
    page.bondFooter = RSUI:HorizontalBox({ id = "dashboard_bond_footer", parent = page.bondCard.stack, gap = 6, slot = { size = "fixed", height = 28, hAlign = "fill" } })
    AddFooterButton(page.bondFooter, "dashboard_bond_refresh", "刷新居民板", 74, function() local service=S.Services and S.Services.Resident; if service and type(service.Refresh)=="function" then service:Refresh() end; return true end)
    AddFooterButton(page.bondFooter, "dashboard_bond_open", "打开详情", 66, function() if S.UI and type(S.UI.ShowPage)=="function" then S.UI:ShowPage("life_bond") end; return true end, "primary")

    ------------------------------------------------------------------------
    -- User tracking: selected dailies + weekly state + selected event goals.
    ------------------------------------------------------------------------
    page.trackerCard = CreateCard(page.root, "dashboard_tracker", "我的任务追踪", {
        { text = "自定义", width = 50, onClick = function()
            if S.DailyCustomWindow and type(S.DailyCustomWindow.Open) == "function" then S.DailyCustomWindow:Open() end
            return true
        end },
        { text = "悬浮", width = 43, onClick = function() ToggleHud("task"); return true end },
    }, { accentTone = "cyan", iconKind = "task", titleTone = "primary", topAccentTone = "cyanFaint" })
    local trackerColumns = {
        { id = "source", title = "来源", width = 44, minWidth = 38, absoluteMinWidth = 28, field = "source" },
        { id = "name", title = "任务名称", size = "fill", minWidth = 86, absoluteMinWidth = 46, field = "name" },
        { id = "progress", title = "进度", width = 48, minWidth = 42, absoluteMinWidth = 32, field = "progress", getTone = function(row) return row and row.tone or "muted" end },
        { id = "status", title = "状态", width = 58, minWidth = 48, absoluteMinWidth = 34, field = "status", getTone = function(row) return row and row.tone or "muted" end },
    }
    page.trackerTable = RSUI:TableView({
        id = "dashboard_tracker_table", parent = page.trackerCard.stack,
        columns = trackerColumns, rowHeight = 21, headerHeight = 23, columnGap = 1, cellPaddingX = 5, fontSize = 9, overscan = 1, maxPoolSize = 16,
        items = page.trackerRows,
        rowFactory = function(list, poolIndex, tableView)
            return CreateClickableTableRow("dashboard_tracker_table", list, poolIndex, tableView, OpenTrackedQuest)
        end,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })

    ------------------------------------------------------------------------
    -- Today statistics: only counters backed by ResourceService Authority.
    ------------------------------------------------------------------------
    page.todayCard = CreateCard(page.root, "dashboard_today", "今日统计", {
        { text = "刷新", width = 43, onClick = function()
            if S.Runtime and type(S.Runtime.RefreshAll) == "function" then S.Runtime:RefreshAll(false) end
            return true
        end },
    }, { accentTone = "cyan", iconKind = "home", titleTone = "primary", topAccentTone = "cyanFaint" })
    if S.Visual ~= nil and S.Visual.CompactStats ~= nil and type(S.Visual.CompactStats.Create) == "function" then
        page.todayStats = S.Visual.CompactStats:Create({
            id = "dashboard_today_stats", parent = page.todayCard.stack, maxRows = 6, rowHeight = 28, valueWidth = 96,
            slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
        })
    else
        local todayColumns = {
            { id = "name", title = "项目", size = "fill", minWidth = 82, absoluteMinWidth = 48, field = "name" },
            { id = "value", title = "今日变化", width = 92, minWidth = 70, absoluteMinWidth = 48, field = "value", getTone = function(row) return row and row.tone or "muted" end },
        }
        page.todayTable = RSUI:TableView({
            id = "dashboard_today_table", parent = page.todayCard.stack,
            columns = todayColumns, rowHeight = 22, headerHeight = 21, columnGap = 3, overscan = 0, maxPoolSize = 6,
            items = page.todayRows,
            slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
        })
    end

    -- Dashboard cards are intentionally positioned by the page-level band
    -- Authority, so each card is a logical RSUI root under the native content
    -- host. Expose every root to Diagnostics; inspecting only page.component
    -- previously missed the entire dashboard and could falsely report "0 issues".
    page.inspectionRoots = {
        page.activityCard and page.activityCard.component,
        page.tradeCard and page.tradeCard.component,
        page.bondCard and page.bondCard.component,
        page.todayCard and page.todayCard.component,
        page.trackerCard and page.trackerCard.component,
    }
    function page:GetInspectionRoots() return self.inspectionRoots end

    ------------------------------------------------------------------------
    -- M6-v7 resizable dashboard bands.  The splitters commit normalized
    -- presentation ratios only after the user releases the drag; the regular
    -- responsive layout remains the single geometry Authority.
    ------------------------------------------------------------------------
    S.State.ui.dashboard = type(S.State.ui.dashboard)=="table" and S.State.ui.dashboard or {}
    page.dashboardPrefs = S.State.ui.dashboard
    local function CommitBand(which, height)
        local layout = page.lastBandLayout
        if type(layout)~="table" or tonumber(layout.available)==nil or layout.available<=0 then return end
        local ratio = tonumber(height) / layout.available
        if which=="activity" then
            page.dashboardPrefs.activityRatio = Clamp(ratio, 0.18, 0.58)
        elseif which=="middle" then
            page.dashboardPrefs.middleRatio = Clamp(ratio, 0.22, 0.62)
        end
        if S.Storage and type(S.Storage.RequestSave)=="function" then S.Storage:RequestSave() end
        if page.lastLayoutSpec then page:ApplyLayout(page.lastLayoutSpec) end
    end
    if S.Visual and S.Visual.ResizableRegion and type(S.Visual.ResizableRegion.Attach)=="function" then
        page.activitySplitter = S.Visual.ResizableRegion:Attach({
            id="dashboard_activity_splitter", target=page.activityCard.component,
            getMinHeight=function() return page.lastBandLayout and page.lastBandLayout.minEvent or 120 end,
            getMaxHeight=function() local l=page.lastBandLayout; return l and math.max(l.minEvent,l.available-l.minMiddle-l.minBottom) or 620 end,
            onCommit=function(h) CommitBand("activity",h) end,
        })
        local function MiddleSplitter(id,target)
            return S.Visual.ResizableRegion:Attach({
                id=id, target=target,
                getMinHeight=function() return page.lastBandLayout and page.lastBandLayout.minMiddle or 150 end,
                getMaxHeight=function() local l=page.lastBandLayout; return l and math.max(l.minMiddle,l.available-l.eventH-l.minBottom) or 660 end,
                onCommit=function(h) CommitBand("middle",h) end,
            })
        end
        page.tradeSplitter = MiddleSplitter("dashboard_trade_splitter",page.tradeCard.component)
        page.bondSplitter = MiddleSplitter("dashboard_bond_splitter",page.bondCard.component)
    end

    local function RefreshDynamicTable(tableView, cacheKey, count, revision)
        count = math.max(0, math.floor(tonumber(count) or 0))
        if page.cache[cacheKey .. ":count"] ~= count then
            page.cache[cacheKey .. ":count"] = count
            if tableView.list ~= nil and type(tableView.list.InvalidateMeasure) == "function" then
                tableView.list:InvalidateMeasure("data_count_changed")
            end
            if type(tableView.InvalidateMeasure) == "function" then tableView:InvalidateMeasure("data_count_changed") end
            if tableView.width ~= nil and tableView.height ~= nil then
                tableView:LayoutIfNeeded(tableView.x or 0, tableView.y or 0, tableView.width, tableView.height, true)
            end
        end
        tableView:RefreshVisible(revision, true)
    end

    function page:Refresh(dirty)
        -- Dirty services continue updating their own Authorities while the user
        -- is on another page. Defer presentation rebinding until ShowPage("life")
        -- calls Refresh again; this avoids hidden 1-second event-table work.
        if S.UI ~= nil and S.UI.currentPage ~= nil and S.UI.currentPage ~= "life" then
            self.pendingRefresh = true
            return false
        end
        self.pendingRefresh = false
        self.revision = self.revision + 1

        local refreshAll = type(dirty) ~= "table" or dirty.all == true
        local refreshEvents = refreshAll or dirty.events == true or dirty.quests == true
        local refreshTrade = refreshAll or dirty.trade == true
        local refreshBond = refreshAll or dirty.resident == true or dirty.resources == true
        local refreshTracker = refreshAll or dirty.quests == true
        local refreshToday = refreshAll or dirty.resources == true

        -- Event/Trade tables point directly at State arrays. Refresh only the
        -- bounded visible pools; no array copy and no native row explosion.
        if refreshEvents then
            local eventCount = math.min(12, #(S.State.data.events or {}))
            RefreshDynamicTable(self.activityTable, "events", eventCount, "events:" .. tostring(self.revision))
            local clock = ServerClockText(false)
            if self.activityCard and type(self.activityCard.SetSubtitle)=="function" then self.activityCard:SetSubtitle(ServerClockText(true), "caption") end
            if S.MainWindow and S.MainWindow.appShell and type(S.MainWindow.appShell.SetDataClock)=="function" then S.MainWindow.appShell:SetDataClock(clock) end
            local eventService = S.Services and S.Services.Event
            local hiddenCount = eventService and type(eventService.GetHiddenCount)=="function" and tonumber(eventService:GetHiddenCount()) or 0
            if self.activityCard and type(self.activityCard.SetActionVisible)=="function" then self.activityCard:SetActionVisible(2, hiddenCount > 0) end
            if hiddenCount > 0 and self.activityCard and type(self.activityCard.SetActionText)=="function" then self.activityCard:SetActionText(2, "恢复" .. tostring(hiddenCount)) end
        end

        if refreshTrade then
            RefreshDynamicTable(self.tradeTable, "trade", #(CurrentTradeData().rows or {}), "trade:" .. tostring(self.revision))
            local trade = CurrentTradeData()
            local tradeService = S.Services and S.Services.Trade
            local lifeTrade = type(S.State.life) == "table" and type(S.State.life.trade) == "table" and S.State.life.trade or {}
            local fromName = tradeService and type(tradeService.ZoneName) == "function" and tradeService:ZoneName(lifeTrade.fromZone) or "--"
            local toName = tradeService and type(tradeService.ZoneName) == "function" and tradeService:ZoneName(lifeTrade.toZone) or "--"
            self.tradeFrom:SetItems(ZoneItems(trade.zones or {}))
            self.tradeFrom:SetValue(tonumber(lifeTrade.fromZone), false)
            self.tradeTo:SetItems(ZoneItems(trade.sellableZones or {}))
            self.tradeTo:SetValue(tonumber(lifeTrade.toZone), false)
            self.tradeTo:SetEnabled(#(trade.sellableZones or {}) > 0)
            self.tradeRouteLabel:SetText("当前路线：" .. tostring(fromName) .. " → " .. tostring(toName))
            if self.tradeCard and type(self.tradeCard.SetSubtitle)=="function" then
                local count=#(trade.rows or {})
                self.tradeCard:SetSubtitle(count > 0 and (tostring(count).."项货物") or "", "caption")
            end
            local tradeStatus = tostring(trade.error or trade.route or "请选择路线")
            local tradeTone = trade.status == "error" and "red" or trade.status == "loading" and "yellow" or trade.status == "ready" and "green" or "muted"
            self.tradeStatus:SetText(tradeStatus)
            self.tradeStatus:SetTone(tradeTone)
            -- Ready-route text is already represented by the stronger current
            -- route line above. Keep this secondary line only for actionable
            -- states instead of repeating "A → B" twice.
            local hasRoute = tonumber(lifeTrade.fromZone) ~= nil and tonumber(lifeTrade.toZone) ~= nil
            local showTradeStatus = (trade.status == "error" or trade.status == "loading" or not hasRoute)
            local visibilityChanged = self.tradeStatus:SetVisible(showTradeStatus) == true
            if self.tradeEmptyHint ~= nil then
                visibilityChanged = self.tradeEmptyHint:SetVisible(#(trade.rows or {}) == 0 and trade.status ~= "loading") == true or visibilityChanged
            end
            -- M6-v10: visibility is layout, not paint.  Older RSUI only marked
            -- the card dirty here, so the two collapsed helper rows could leave
            -- their old 16+38px slots visible until a page-level resize. Reflow
            -- the already-sized card immediately; the Foundation invalidation
            -- queue also protects the same contract for other composites.
            local tradeComponent = self.tradeCard and self.tradeCard.component
            if visibilityChanged and tradeComponent ~= nil and tonumber(tradeComponent.width) and tonumber(tradeComponent.height) then
                tradeComponent:LayoutIfNeeded(tradeComponent.x or 0, tradeComponent.y or 0, tradeComponent.width, tradeComponent.height, true)
            end
        end

        if refreshBond then
            local bondRows = BuildBondRows()
            SetItemsIfChanged(self.bondTable, self.cache, "bond", bondRows, BuildBondSignature(bondRows))
            self.bondRows = bondRows
            local service = S.Services and S.Services.Resident
            local filter = service and type(service.GetBondFilter) == "function" and service:GetBondFilter() or nil
            if type(filter) == "table" and type(self.bondFilterButtons) == "table" then
                local all = filter.q20 == true and filter.q60 == true and filter.q100 == true and filter.auroria == true
                for key, button in pairs(self.bondFilterButtons) do
                    local selected = key == "all" and all or (key ~= "all" and filter[key] == true)
                    if button and S.Visual and S.Visual.ActionButton and type(S.Visual.ActionButton.Apply) == "function" then
                        S.Visual.ActionButton:Apply(button, selected and "primary" or "ghost")
                    end
                end
            end
        end

        if refreshTracker then
            local trackerRows = BuildTrackerRows()
            SetItemsIfChanged(self.trackerTable, self.cache, "tracker", trackerRows, BuildTrackerSignature(trackerRows))
            self.trackerRows = trackerRows
        end

        if refreshToday then
            local todayRows = BuildTodayRows()
            local signature = BuildTodaySignature(todayRows)
            if self.cache.today ~= signature then
                self.cache.today = signature
                if self.todayStats ~= nil and type(self.todayStats.SetRows) == "function" then self.todayStats:SetRows(todayRows)
                elseif self.todayTable ~= nil then self.todayTable:SetItems(todayRows, signature) end
            end
            self.todayRows = todayRows
        end
        return true
    end

    local function AllocateHeights(totalHeight, gap, scale, prefs)
        local available = math.max(3, totalHeight - gap * 2)
        -- Trade is a primary decision surface.  Its minimum and default share
        -- are deliberately larger than v6 so common 768/1080p layouts expose
        -- several cargo rows before the player even touches the splitter.
        local minEvent, minMiddle, minBottom = 126 * scale, 206 * scale, 96 * scale
        local minTotal = minEvent + minMiddle + minBottom
        if available <= minTotal then
            local ratio = available / math.max(1, minTotal)
            return minEvent * ratio, minMiddle * ratio, minBottom * ratio, minEvent*ratio, minMiddle*ratio, minBottom*ratio, available
        end
        local extra = available - minTotal
        local eventH = minEvent + extra * 0.32
        local middleH = minMiddle + extra * 0.51
        local bottomH = available - eventH - middleH

        prefs = type(prefs)=="table" and prefs or {}
        local eventRatio = tonumber(prefs.activityRatio)
        if eventRatio then eventH = Clamp(available*eventRatio,minEvent,available-minMiddle-minBottom) end
        local middleRatio = tonumber(prefs.middleRatio)
        if middleRatio then middleH = Clamp(available*middleRatio,minMiddle,available-eventH-minBottom) end
        -- Re-clamp event after middle in case old/corrupt preferences compete.
        eventH = Clamp(eventH,minEvent,available-middleH-minBottom)
        bottomH = math.max(minBottom, available-eventH-middleH)
        middleH = math.max(minMiddle, available-eventH-bottomH)
        return eventH,middleH,bottomH,minEvent,minMiddle,minBottom,available
    end

    function page:ApplyLayout(spec)
        spec = spec or S.Layout:GetMainSpec()
        local width = math.max(1, tonumber(spec.contentWidth) or 1)
        local height = math.max(1, tonumber(spec.contentHeight) or 1)
        local scale = S.Layout:GetContext().addonScale
        local gap = math.max(8 * scale, tonumber(spec.gap) or 8 * scale)

        self.component:LayoutIfNeeded(0, 0, width, height)

        -- M6-v5 adds an actual application gutter inside the content viewport.
        -- Previous passes placed card borders directly against the host edge,
        -- which made the entire dashboard read as one giant debug grid.
        local outerPad = math.max(7 * scale, math.min(10 * scale, gap + 2 * scale))
        local innerW = math.max(1, width - outerPad * 2)
        local innerH = math.max(1, height - outerPad * 2)
        local eventH, middleH, bottomH, minEvent, minMiddle, minBottom, available = AllocateHeights(innerH, gap, scale, self.dashboardPrefs)
        self.lastLayoutSpec = spec
        self.lastBandLayout = {
            available=available, eventH=eventH, middleH=middleH, bottomH=bottomH,
            minEvent=minEvent, minMiddle=minMiddle, minBottom=minBottom,
        }
        local middleY = outerPad + eventH + gap
        local bottomY = middleY + middleH + gap

        -- The dashboard keeps the high-density two-panel rows even on compact
        -- widths. TableView's absolute-minimum column compression + ellipsis is
        -- the fallback, avoiding bespoke 1024-only branches and sibling overlap.
        local usableW = math.max(2, innerW - gap)
        local tradeW = math.floor(usableW * (width >= 760 * scale and 0.61 or 0.58))
        local bondW = usableW - tradeW
        local bottomUsable = math.max(2, innerW - gap)
        local trackerW = math.floor(bottomUsable * (width >= 760 * scale and 0.64 or 0.60))
        local todayW = bottomUsable - trackerW

        self.activityCard.component:LayoutIfNeeded(outerPad, outerPad, innerW, eventH)
        self.tradeCard.component:LayoutIfNeeded(outerPad, middleY, tradeW, middleH)
        self.bondCard.component:LayoutIfNeeded(outerPad + tradeW + gap, middleY, bondW, middleH)
        self.trackerCard.component:LayoutIfNeeded(outerPad, bottomY, trackerW, bottomH)
        self.todayCard.component:LayoutIfNeeded(outerPad + trackerW + gap, bottomY, todayW, bottomH)

        -- Refresh after geometry is final so dynamic-source count changes can
        -- reconcile only the bounded visible pools once.
        self:Refresh()
    end

    page:Refresh()
    P.instance = page
    -- M2 initially returned the page to MainWindow but did not register it in
    -- UIX.pages, which made ShowPage("life") unable to select the dashboard on
    -- a clean load. The page registry remains the navigation presentation
    -- Authority, so register the dashboard explicitly.
    S.UI.pages.life = page
    return page
end

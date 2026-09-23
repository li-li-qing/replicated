------------------------------------------------------------------------
-- Replicated Suite V3 - Trade Pack Floating Detail
--
-- Auxiliary detail surface shared by the main Trade page and the Trade HUD.
-- Geometry is persisted by the Presentation-only AuxWindow Store; business data
-- remains owned by life_trade.
-- Business facts remain owned by life_trade.  This presenter never calls X2Store
-- or X2Auction directly; explicit material quotes route back through Trade
-- Commands -> PriceQuoteQueueV3.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI = S.RSUI
local Floating = RSUI and RSUI.FloatingSurface or nil
local AuxStore = S.UIV3 and S.UIV3.AuxWindowStoreV3 or nil
if type(RSUI) ~= "table" or type(Floating) ~= "table" or type(AuxStore) ~= "table" then return end

S.UIV3 = S.UIV3 or {}
S.UIV3.TradeDetailFloatingV3 = S.UIV3.TradeDetailFloatingV3 or {
    version = 1,
    TradeDetailContractVersion = 3,
    id = "v3_trade_detail_floating",
    created = false,
    visible = false,
    acquired = false,
    subscribed = false,
    rowKey = nil,
    revision = 0,
}
local M = S.UIV3.TradeDetailFloatingV3

local function Feature()
    return S.Features and S.Features.Trade or nil
end

local function Money(value)
    local n = tonumber(value)
    if n == nil then return "--" end
    if S.Utils and type(S.Utils.FormatMoney) == "function" then
        local ok, text = pcall(S.Utils.FormatMoney, n)
        if ok and type(text) == "string" and text ~= "" then return text end
    end
    return tostring(math.floor(n + 0.5))
end

local function ZoneName(projection, id)
    id = tonumber(id)
    for _, row in ipairs(type(projection) == "table" and projection.zones or {}) do
        if tonumber(row.id) == id then return tostring(row.name or row.displayName or id or "--") end
    end
    for _, row in ipairs(type(projection) == "table" and projection.sellableZones or {}) do
        if tonumber(row.id) == id then return tostring(row.name or row.displayName or id or "--") end
    end
    return id and tostring(math.floor(id)) or "--"
end

-- Internal cost/price status codes must never reach a player. Map each known
-- code to plain Chinese; an unknown code becomes an honest generic sentence
-- rather than the raw identifier (that is exactly the unreadable-token class of
-- noise this Suite kept producing).
local PRICE_STATUS_TEXT = {
    explicit_quote_required = "价格需询价",
    quote_pending = "正在询价",
    quote_failed = "询价失败",
    price_pending = "价格待确认",
    identity_pending = "材料待确认",
    quoted = "已取价",
    quoted_reference = "参考价",
    excluded = "不计入成本",
    bound_resource = "绑定资源",
    non_market_resource = "非市场资源",
    non_market_unpriced = "不可拍卖/未折价",
    ready_with_resources = "金币成本已齐（另含资源）",
    unavailable = "暂无法估价",
    partial = "部分材料未取到价",
}
local function PlayerPriceStatusText(code)
    local key = tostring(code or "")
    if PRICE_STATUS_TEXT[key] ~= nil then return PRICE_STATUS_TEXT[key] end
    -- A bare ASCII identifier is an internal token, not wording: replace it.
    if key ~= "" and key:match("^[A-Za-z0-9_%.%-]+$") then return "暂无法估价" end
    return key ~= "" and key or "售价不可用"
end

local function MaterialStatus(row)
    local status = tostring(row and row.costStatus or "")
    if status == "quoted" then return "已报价", "green" end
    -- Distinct wording AND a softer tone than a live quote: auction listings can
    -- be manipulated, so a stored sample must never look like fresh market data.
    if status == "quoted_reference" then return "参考价", "muted" end
    if status == "excluded" then return "不计成本", "muted" end
    if status == "bound_resource" then return "绑定资源", "accent" end
    if status == "non_market_resource" then return "非市场资源", "muted" end
    if status == "non_market_unpriced" then return "不可拍卖", "yellow" end
    if status == "quote_pending" then
        return tostring(row.quoteState) == "inflight" and "询价中" or "询价排队中", "yellow"
    end
    if status == "quote_failed" then return "询价失败", "red" end
    if status == "explicit_quote_required" then return "待询价", "yellow" end
    if status == "identity_pending" then return "身份待确认", "muted" end
    return "待确认", "muted"
end

function M:ReleaseConsumer(reason)
    if self.acquired ~= true then return true end
    local feature = Feature()
    if type(feature) ~= "table" or (S.FeatureRuntime and S.FeatureRuntime:IsEnabled(feature.Id) ~= true) then
        self.acquired = false
        return true
    end
    local ok, err = feature:ReleaseConsumer("floating:trade_detail")
    if ok ~= true then return false, err or "贸易品详情 Consumer 释放失败" end
    self.acquired = false
    return true
end

function M:Unsubscribe()
    if self.subscribed and S.Events ~= nil and type(S.Events.UnsubscribeInternalOwner) == "function" then
        S.Events:UnsubscribeInternalOwner(self)
    end
    self.subscribed = false
    return true
end

function M:Deactivate(reason)
    self.visible = false
    self:Unsubscribe()
    return self:ReleaseConsumer(reason or "trade_detail_hide")
end

function M:EnsureCreated()
    if self.created == true and self.surface ~= nil then return true end
    local loaded, loadErr = AuxStore:EnsureLoaded()
    if loaded ~= true then return false, loadErr or "辅助窗口布局读取失败" end
    local surface, err = Floating:Create({
        id = self.id,
        owner = "v3:trade_detail:floating",
        title = "贸易品详情",
        status = "--",
        footer = true,
        movable = true,
        resizable = true,
        minimizeMode = "compact",
        boundaryMode = "free",
        defaultPlacement = "center",
        statePolicy = AuxStore:GetPolicy("trade_detail"),
        getState = function() return AuxStore:GetWindowState("trade_detail") end,
        setState = function(value, reason) return AuxStore:SetWindowState("trade_detail", value, reason) end,
        -- 中文维护注释：贸易品详情只把窗口几何/锁定/透明度写入 Presentation Store；
        -- 业务数据继续由原 Feature/Service Authority 管理，避免第二业务 Authority。
        persist = function(reason, delayMs) return AuxStore:PersistWindow("trade_detail", reason, delayMs) end,
        onClosed = function()
            M:Deactivate("surface_closed")
            return true
        end,
    })
    if surface == nil then return false, err or "贸易品详情悬浮窗创建失败" end
    self.surface, self.shell = surface, surface.shell

    local stack = RSUI:VerticalBox({ id = self.id .. "_stack", parent = surface:GetContentRoot(), gap = 6,
        slot = { hAlign = "fill", vAlign = "fill" } })
    self.route = RSUI:Text({ id = self.id .. "_route", parent = stack, text = "--", fontSize = 10, tone = "muted",
        overflow = "wrap", maxLines = 2, slot = { size = "fixed", height = 34, hAlign = "fill" } })
    self.summary = RSUI:Text({ id = self.id .. "_summary", parent = stack, text = "--", fontSize = 10, tone = "default",
        overflow = "wrap", maxLines = 2, slot = { size = "fixed", height = 36, hAlign = "fill" } })

    -- 维护（2026-09-23，trade-detail-actions-fit-1）：详情窗最小宽度仍是历史 470px，新增“关注货物”后
    -- 若继续把 5 个固定宽按钮塞在同一 HorizontalBox，会在旧用户已保存的小窗口宽度下发生越界/互相覆盖。
    -- 不抬高 minWidth（避免强制改变旧窗口几何），而是拆成两行；只改变 Presentation 排布，所有动作仍走 Feature Commands。
    local actions = RSUI:HorizontalBox({ id = self.id .. "_actions", parent = stack, gap = 6,
        slot = { size = "fixed", height = 30, hAlign = "fill" } })
    self.quoteButton = RSUI:Button({ id = self.id .. "_quote", parent = actions, text = "询价当前材料", compact = true,
        slot = { size = "fixed", width = 116 } })
    -- 中文维护注释（2026-09-14，跑商→拍卖临时清单）：这里不让 Presentation 重算配方，也不把
    -- 临时材料写进 life_trade Store。点击时只把 Trade Authority 已经解析好的 detached row/materialRows
    -- 交给 AuctionSessionListV3；该 Service 没有 Persistence Store，ReloadAddon 后自然清空。
    self.auctionTempButton = RSUI:Button({ id = self.id .. "_auction_temp", parent = actions, text = "加入拍卖临时清单", compact = true,
        slot = { size = "fixed", width = 126 } })
    self.refreshButton = RSUI:Button({ id = self.id .. "_refresh", parent = actions, text = "刷新详情", compact = true,
        slot = { size = "fixed", width = 86 } })

    local manageActions = RSUI:HorizontalBox({ id = self.id .. "_manage_actions", parent = stack, gap = 6,
        slot = { size = "fixed", height = 30, hAlign = "fill" } })
    self.favoriteButton = RSUI:Button({ id = self.id .. "_favorite", parent = manageActions, text = "收藏路线", compact = true,
        slot = { size = "fixed", width = 92 } })
    self.trackButton = RSUI:Button({ id = self.id .. "_track", parent = manageActions, text = "关注货物", compact = true,
        slot = { size = "fixed", width = 86 } })

    self.table = RSUI:TableView({
        id = self.id .. "_table", parent = stack, items = {}, rowHeight = 26, headerHeight = 25, desiredRows = 10, rowFitMode = "adaptive_tail", rowFitMin = 22, rowFitMax = 30,
        scrollbar = true, selectable = false, columnResize = true, headerInteractive = false,
        getKey = function(item, index) return item and item.key or tostring(index or 0) end,
        columns = {
            { id = "name", title = "材料", field = "name", size = "fill", minWidth = 130, fill = 1.2 },
            { id = "count", title = "数量", field = "countText", size = "fixed", width = 58, minWidth = 46 },
            { id = "unit", title = "单价", field = "unitText", size = "fixed", width = 92, minWidth = 72 },
            { id = "subtotal", title = "小计", field = "subtotalText", size = "fixed", width = 98, minWidth = 76 },
            { id = "status", title = "状态", field = "statusText", size = "fixed", width = 82, minWidth = 64,
                getTone = function(item) return item and item.statusTone or "muted" end },
        },
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })
    self.hint = RSUI:Text({ id = self.id .. "_hint", parent = stack,
        text = "材料价格只有在用户显式询价后才读取；普通刷新不会批量请求拍卖行。", fontSize = 9, tone = "muted",
        overflow = "wrap", maxLines = 2, slot = { size = "fixed", height = 34, hAlign = "fill" } })

    if self.route == nil or self.summary == nil or self.quoteButton == nil or self.favoriteButton == nil or self.trackButton == nil
        or self.auctionTempButton == nil or self.refreshButton == nil or self.table == nil or self.hint == nil then
        surface:Destroy()
        self.surface, self.shell = nil, nil
        return false, "贸易品详情悬浮窗内容创建失败"
    end

    self.quoteButton.onClick = function()
        local feature = Feature()
        if type(feature) ~= "table" or type(feature.Commands) ~= "table" or type(feature.Commands.QuoteRowMaterials) ~= "function" then
            return false, "贸易品材料询价命令不可用"
        end
        local ok, quoteErr = feature.Commands:QuoteRowMaterials(M.rowKey)
        if ok == true then M:Refresh("quote_requested") end
        return ok, quoteErr
    end
    self.favoriteButton.onClick = function()
        local feature = Feature()
        if type(feature) ~= "table" or type(feature.Commands) ~= "table" or type(feature.Commands.ToggleCurrentFavorite) ~= "function" then
            return false, "贸易路线收藏命令不可用"
        end
        local ok, favoriteErr = feature.Commands:ToggleCurrentFavorite()
        if ok == true then M:Refresh("favorite_changed") end
        return ok, favoriteErr
    end
    self.trackButton.onClick = function()
        local feature = Feature()
        if type(feature) ~= "table" or type(feature.Commands) ~= "table" or type(feature.Commands.ToggleTrackedProduct) ~= "function" then
            return false, "贸易品关注命令不可用"
        end
        local row = feature:GetRow(M.rowKey)
        if type(row) ~= "table" or tonumber(row.itemType) == nil then return false, "该贸易品缺少已验证 ItemID" end
        local ok, trackErr = feature.Commands:ToggleTrackedProduct(row.itemType)
        if ok == true then M:Refresh("tracked_changed") end
        return ok, trackErr
    end
    self.auctionTempButton.onClick = function()
        local feature = Feature()
        local session = S.Services and S.Services.AuctionSessionListV3 or nil
        if type(feature) ~= "table" or type(feature.GetRow) ~= "function" then return false, "跑商数据不可用" end
        if type(session) ~= "table" or type(session.AddTradeRow) ~= "function" then return false, "拍卖临时清单服务不可用" end
        local row = feature:GetRow(M.rowKey)
        if type(row) ~= "table" then return false, "当前贸易品已失效，请重新选择" end
        if type(row.materialRows) ~= "table" or #row.materialRows <= 0 then return false, "当前贸易品没有可加入的材料" end
        local ok, groupOrErr = session:AddTradeRow(row)
        if ok == true then
            M.hint:SetText("已加入拍卖助手“临时”选项卡；临时数据只保留到本次插件重载/客户端重启。")
        else
            M.hint:SetText("加入拍卖临时清单失败：" .. tostring(groupOrErr or "未执行"))
        end
        return ok, groupOrErr
    end
    self.refreshButton.onClick = function() return M:Refresh("manual") end

    surface:Show(false)
    self.created = true
    return true
end

function M:Subscribe()
    if self.subscribed then return true end
    local feature = Feature()
    if type(feature) == "table" and S.Events ~= nil and type(S.Events.SubscribeInternal) == "function" and type(feature.UpdateTopic) == "string" then
        S.Events:SubscribeInternal(feature.UpdateTopic, self, function()
            if M.visible then M:Refresh("feature_update") end
        end)
    end
    self.subscribed = true
    return true
end

function M:Refresh(reason)
    local feature = Feature()
    if type(feature) ~= "table" or type(feature.GetRow) ~= "function" then return false, "跑商 Feature 不可用" end
    local row = feature:GetRow(self.rowKey)
    local projection = feature:GetProjection() or {}
    if type(row) ~= "table" then
        self.table:SetItems({}, "missing:" .. tostring(self.revision or 0))
        self.table:SetViewState("empty", { title = "当前贸易品已失效", detail = "路线或服务器货率已经变化，请重新在跑商列表选择贸易品。" })
        self.route:SetText("当前路线结果已变化")
        self.summary:SetText("请回到跑商列表重新选择贸易品。")
        self.quoteButton:SetEnabled(false)
        self.favoriteButton:SetEnabled(false)
        self.trackButton:SetEnabled(false)
        self.auctionTempButton:SetEnabled(false)
        self.surface:SetStatus("结果已更新", "yellow")
        return false, "贸易品已不在当前路线结果中"
    end

    self.revision = (tonumber(self.revision) or 0) + 1
    if self.shell ~= nil and type(self.shell.SetTitle) == "function" then self.shell:SetTitle(tostring(row.name or "贸易品详情")) end
    self.route:SetText(ZoneName(projection, row.originZone) .. " → " .. ZoneName(projection, row.destinationZone))
    local payoutFactors = row.priceComplete == true
        and " · 含经商与品类加成"
        or (" · " .. PlayerPriceStatusText(row.priceBreakdown or row.priceEstimateStatus))
    local resourceCount = math.max(0, tonumber(row.boundResourceCount) or 0) + math.max(0, tonumber(row.nonMarketResourceCount) or 0)
    local resourceHint = resourceCount > 0 and (" · 另含" .. tostring(resourceCount) .. "项绑定/非市场资源") or ""
    self.summary:SetText("货率 " .. tostring(row.rate or "--") .. " · 预计售价 " .. tostring(row.price or "--") .. payoutFactors
        .. "\n材料金币成本 " .. Money(row.materialCostCopper) .. resourceHint .. " · 毛利 " .. tostring(row.profit or "--"))

    local items, pending, inflight, failed, firstQuoteError = {}, 0, 0, 0, nil
    for index, material in ipairs(type(row.materialRows) == "table" and row.materialRows or {}) do
        local statusText, tone = MaterialStatus(material)
        local costStatus = tostring(material.costStatus or "")
        -- Actionable backlog for the quote button: never-quoted + failed retries.
        if costStatus == "explicit_quote_required" or costStatus == "quote_failed" then pending = pending + 1 end
        if costStatus == "quote_pending" then inflight = inflight + 1 end
        if costStatus == "quote_failed" then
            failed = failed + 1
            if firstQuoteError == nil and material.quoteError ~= nil then firstQuoteError = tostring(material.quoteError) end
        end
        items[#items + 1] = {
            -- key is an internal row handle for the table widget, not display text.
            key = tostring(material.internalKey or material.materialKey or index),
            -- The projection already resolved `name` through the Localization
            -- Authority; the old English-key fallback leaked raw data keys
            -- ("Chopped Produce") straight onto a player-facing table.
            name = tostring(material.name or "材料"),
            countText = "×" .. tostring(math.max(0, tonumber(material.count) or 0)),
            unitText = material.includeInCost == false and "资源" or Money(material.unitCostCopper),
            subtotalText = material.includeInCost == false and "--" or Money(material.totalCostCopper),
            statusText = statusText, statusTone = tone,
        }
    end
    self.table:SetItems(items, "trade_detail:" .. tostring(self.revision))
    if #items == 0 then
        self.table:SetViewState("empty", { title = "暂无材料详情", detail = "当前贸易品尚未匹配到已核验材料表。" })
    else
        self.table:SetViewState("ready")
    end
    self.quoteButton:SetEnabled(pending > 0)
    self.quoteButton:SetText(pending > 0 and ("询价当前材料(" .. tostring(pending) .. ")") or "材料已询价")
    self.favoriteButton:SetEnabled(row.cargoMode ~= true and projection.fromZone ~= nil and projection.toZone ~= nil)
    self.favoriteButton:SetText(row.cargoMode == true and "随身扫描" or (projection.currentRouteFavorite == true and "取消路线收藏" or "收藏路线"))
    self.trackButton:SetEnabled(tonumber(row.itemType) ~= nil)
    self.trackButton:SetText(row.tracked == true and "取消关注" or "关注货物")
    self.auctionTempButton:SetEnabled(type(S.Services and S.Services.AuctionSessionListV3) == "table" and #(row.materialRows or {}) > 0)
    local statusSummary = "材料 " .. tostring(#items) .. " 项"
    if pending > 0 then statusSummary = statusSummary .. (" · 待询价 " .. tostring(pending)) end
    if inflight > 0 then statusSummary = statusSummary .. (" · 询价中 " .. tostring(inflight)) end
    if failed > 0 then statusSummary = statusSummary .. (" · 询价失败 " .. tostring(failed)) end
    if pending == 0 and inflight == 0 and failed == 0 then statusSummary = statusSummary .. " · 价格已齐/无需询价" end
    self.surface:SetStatus(statusSummary, failed > 0 and "red" or (pending > 0 and "yellow" or "accent"))
    -- Surface the first real failure reason directly where the user clicked;
    -- the diagnostics "报价队列" row carries the queue-wide last result.
    if failed > 0 then
        self.hint:SetText("询价失败原因：" .. (firstQuoteError or "未知；请复制诊断页「报价队列」行给维护者。"))
    else
        local resourceText = resourceCount > 0 and ("；当前含 " .. tostring(resourceCount) .. " 项绑定/非市场制作资源，不折算金币成本") or ""
        self.hint:SetText("材料价格只有在用户显式询价后才读取；普通刷新不会批量请求拍卖行" .. resourceText .. "。")
    end
    return true
end

function M:Open(rowKey)
    local feature = Feature()
    if type(feature) ~= "table" or S.FeatureRuntime == nil or S.FeatureRuntime:IsEnabled(feature.Id) ~= true then
        return false, "请先启用跑商功能"
    end
    local row = type(feature.GetRow) == "function" and feature:GetRow(rowKey) or nil
    if type(row) ~= "table" then return false, "贸易品已不在当前路线结果中" end
    local ok, err = self:EnsureCreated()
    if ok ~= true then return false, err end
    if self.acquired ~= true then
        local acquired, acquireErr = feature:AcquireConsumer("floating:trade_detail")
        if acquired ~= true then return false, acquireErr or "贸易品详情 Consumer 启动失败" end
        self.acquired = true
    end
    self.rowKey = tostring(row.key or rowKey or "")
    if type(feature.Commands) == "table" and type(feature.Commands.SelectRow) == "function" then feature.Commands:SelectRow(self.rowKey) end
    self:Subscribe()
    self.visible = true
    self:Refresh("open")
    local restored, restoreErr = self.surface:SetMinimized(false, false)
    if restored ~= true then self:Deactivate("restore_failed"); return false, restoreErr end
    local shown, showErr = self.surface:Show(true)
    if shown ~= true then self:Deactivate("show_failed"); return false, showErr end
    return true
end

function M:Close(reason)
    if self.surface == nil then return self:Deactivate(reason or "trade_detail_close") end
    local closed, closeErr = self.surface:Close(reason or "trade_detail_close")
    if closed ~= true then return false, closeErr end
    self:Deactivate(reason or "trade_detail_close")
    return true
end

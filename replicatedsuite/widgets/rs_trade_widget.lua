------------------------------------------------------------------------
-- Replicated Suite - Trade floating widget
-- Author: Replicated
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.TradeWidget = {}

function S.TradeWidget.Create()
    local widget = S.WidgetBase:Create("trade", "跑商货率", S.Constants.Widget.trade)
    local win = widget.window
    widget.scrollOffset = 0
    widget.visibleRows = 1

    local route = S.UI:CreateLabel(win, "trade_widget_route", "请选择路线", 12, 0, 420, 22, 11, "yellow", ALIGN_LEFT)
    local favoriteToggle = S.UI:CreateButton(win, "trade_favorite_toggle", "收藏", 0, 0, 70, 24, 9, false)
    local refresh = S.UI:CreateButton(win, "trade_refresh", "刷新", 0, 0, 58, 24, 9, false)
    local favoritePrev = S.UI:CreateButton(win, "trade_favorite_prev", "◀", 0, 0, 24, 24, 8, false)
    local favoriteNext = S.UI:CreateButton(win, "trade_favorite_next", "▶", 0, 0, 24, 24, 8, false)
    local headerName = S.UI:CreateLabel(win, "trade_widget_header_name", "货物名称", 12, 0, 260, 20, 9, "muted", ALIGN_LEFT)
    local headerRate = S.UI:CreateLabel(win, "trade_widget_header_rate", "货率", 0, 0, 70, 20, 9, "muted", ALIGN_RIGHT)
    local headerPrice = S.UI:CreateLabel(win, "trade_widget_header_price", "预计售价", 0, 0, 110, 20, 9, "muted", ALIGN_RIGHT)
    local headerProfit = S.UI:CreateLabel(win, "trade_widget_header_profit", "预计毛利", 0, 0, 96, 20, 9, "muted", ALIGN_RIGHT)
    local up = S.UI:CreateButton(win, "trade_widget_scroll_up", "^", 0, 0, 20, 20, 8, false)
    local down = S.UI:CreateButton(win, "trade_widget_scroll_down", "v", 0, 0, 20, 20, 8, false)
    local function Service() return S.Services and S.Services.Trade end
    local rows = {}
    for i = 1, 18 do
        local index = i
        local row = {
            name = S.UI:CreateLabel(win, "trade_widget_name_" .. i, "", 12, 0, 310, 22, 10, nil, ALIGN_LEFT),
            rate = S.UI:CreateLabel(win, "trade_widget_rate_" .. i, "", 0, 0, 64, 22, 10, "green", ALIGN_RIGHT),
            price = S.UI:CreateLabel(win, "trade_widget_price_" .. i, "", 0, 0, 110, 22, 10, nil, ALIGN_RIGHT),
            profit = S.UI:CreateLabel(win, "trade_widget_profit_" .. i, "", 0, 0, 96, 22, 10, "muted", ALIGN_RIGHT),
            hit = UIParent:CreateWidget("emptywidget", S.PhysicalId("trade_widget_hit_" .. i), win),
            data = nil,
        }
        row.hit:SetExtent(520, 22)
        if row.hit.Enable ~= nil then row.hit:Enable(true) end
        if row.hit.EnablePick ~= nil then pcall(function() row.hit:EnablePick(true) end) end
        if row.hit.Clickable ~= nil then pcall(function() row.hit:Clickable(true) end) end
        row.name:Show(false); row.rate:Show(false); row.price:Show(false); row.profit:Show(false); row.hit:Show(false)
        rows[i] = row
        S.UI:SafeHandler(row.hit, "OnClick", function()
            local selected = rows[index] and rows[index].data
            local svc = Service()
            if selected ~= nil and svc ~= nil and type(svc.SelectPack) == "function" then svc:SelectPack(selected, true) end
        end, "trade:row:" .. i)
    end
    local footer = S.UI:CreateLabel(win, "trade_widget_footer", "", 12, 0, 500, 20, 9, "muted", ALIGN_LEFT)
    local mini = S.UI:CreateLabel(win, "trade_widget_mini", "跑商 --", 8, 4, 360, 22, 10, "blue", ALIGN_LEFT)
    mini:Show(false)

    local function ZoneItems(zones)
        local items = {}
        for _, z in ipairs(zones or {}) do items[#items + 1] = { value = z.id, text = z.displayName or z.name } end
        return items
    end

    widget.favoriteDropdown = S.Dropdown:Create(win, "trade_widget_favorite_dd", 250, 27, 12, function(item)
        local svc = Service(); if svc == nil or item == nil then return end
        widget.scrollOffset = 0
        if svc:SelectFavorite(item.value) then
            widget:RefreshDropdowns(); widget:Refresh()
        end
    end)

    widget.fromDropdown = S.Dropdown:Create(win, "trade_widget_from_dd", 250, 27, 13, function(item)
        local svc = Service(); if svc == nil or item == nil then return end
        widget.scrollOffset = 0
        svc:SelectFrom(item.value)
        widget:RefreshDropdowns(); widget:Refresh()
    end)
    widget.toDropdown = S.Dropdown:Create(win, "trade_widget_to_dd", 250, 27, 13, function(item)
        local svc = Service(); if svc == nil or item == nil then return end
        widget.scrollOffset = 0
        svc:SelectTo(item.value)
    end)

    function widget:GetMaxOffset()
        return math.max(0, #((S.State.data.trade or {}).rows or {}) - math.max(1, self.visibleRows or 1))
    end
    function widget:Scroll(delta)
        self.scrollOffset = math.max(0, math.min(self:GetMaxOffset(), (self.scrollOffset or 0) + (tonumber(delta) or 0)))
        self:Refresh()
    end

    function widget:CycleFavorite(delta)
        local svc = Service()
        if svc == nil or type(svc.GetFavorites) ~= "function" or type(svc.SelectFavorite) ~= "function" then return false end
        local favorites = svc:GetFavorites()
        if #favorites == 0 then return false end
        local currentKey = tostring(tonumber(S.State.life.trade.fromZone) or "") .. ":" .. tostring(tonumber(S.State.life.trade.toZone) or "")
        local index = 0
        for i, favorite in ipairs(favorites) do if tostring(favorite.key) == currentKey then index = i; break end end
        local step = tonumber(delta) or 1
        index = ((index + step - 1) % #favorites) + 1
        self.scrollOffset = 0
        local ok = svc:SelectFavorite(favorites[index].key)
        if ok then self:RefreshDropdowns(); self:Refresh() end
        return ok
    end

    function widget:RefreshDropdowns()
        local d = S.State.data.trade or {}
        local svc = Service()
        local favoriteItems = svc and svc:GetFavoriteItems() or {}
        self.favoriteDropdown:SetItems(favoriteItems)
        local currentFavorite = nil
        for _, item in ipairs(favoriteItems) do
            if item.selected == true then currentFavorite = item.value; break end
        end
        self.favoriteDropdown:SetSelectedValue(currentFavorite, true)
        if currentFavorite == nil then self.favoriteDropdown.trigger:SetText("收藏路线  v") end
        self.fromDropdown:SetItems(ZoneItems(d.zones))
        self.fromDropdown:SetSelectedValue(tonumber(S.State.life.trade.fromZone), true)
        self.toDropdown:SetItems(ZoneItems(d.sellableZones))
        self.toDropdown:SetSelectedValue(tonumber(S.State.life.trade.toZone), true)
    end

    S.UI:SafeHandler(favoritePrev, "OnClick", function() widget:CycleFavorite(-1) end, "trade:favorite_prev")
    S.UI:SafeHandler(favoriteNext, "OnClick", function() widget:CycleFavorite(1) end, "trade:favorite_next")
    S.UI:SafeHandler(favoriteToggle, "OnClick", function()
        local svc = Service(); if svc == nil then return end
        if svc:ToggleCurrentFavorite() then widget:RefreshDropdowns(); widget:Refresh() end
    end, "trade:favorite_toggle")
    S.UI:SafeHandler(refresh, "OnClick", function() local svc = Service(); if svc then svc:Request(true) end end, "trade:refresh")
    S.UI:SafeHandler(up, "OnClick", function() widget:Scroll(-1) end, "trade:up")
    S.UI:SafeHandler(down, "OnClick", function() widget:Scroll(1) end, "trade:down")
    if win.EnableScroll ~= nil then pcall(function() win:EnableScroll(true) end) end
    S.UI:SafeHandler(win, "OnWheelUp", function() widget:Scroll(-1) end, "trade:wheel_up")
    S.UI:SafeHandler(win, "OnWheelDown", function() widget:Scroll(1) end, "trade:wheel_down")

    function widget:Refresh()
        local d = S.State.data.trade or {}
        self:RefreshDropdowns()
        route:SetText(d.route or "请选择路线")
        local svc = Service()
        local canFavorite = tonumber(S.State.life.trade.fromZone) ~= nil and tonumber(S.State.life.trade.toZone) ~= nil
        if favoriteToggle.Enable ~= nil then favoriteToggle:Enable(canFavorite) end
        favoriteToggle:SetText((canFavorite and svc and svc:IsFavorite(S.State.life.trade.fromZone, S.State.life.trade.toZone)) and "已收藏" or "收藏")
        local favoriteCount = svc and type(svc.GetFavorites) == "function" and #svc:GetFavorites() or 0
        if favoritePrev.Enable then favoritePrev:Enable(favoriteCount > 0) end
        if favoriteNext.Enable then favoriteNext:Enable(favoriteCount > 0) end
        self.scrollOffset = math.max(0, math.min(self.scrollOffset or 0, self:GetMaxOffset()))
        local needScroll = #(d.rows or {}) > (self.visibleRows or 1)
        local scrollVisible=needScroll and S.State.ui.widgets.trade.mode == "standard"
        up:Show(scrollVisible)
        down:Show(scrollVisible)
        if up.Enable then up:Enable(scrollVisible and self.scrollOffset>0) end
        if down.Enable then down:Enable(scrollVisible and self.scrollOffset<self:GetMaxOffset()) end
        for i, w in ipairs(rows) do
            local r = d.rows and d.rows[self.scrollOffset + i] or nil
            local show = r ~= nil and S.State.ui.widgets.trade.mode == "standard" and i <= (self.visibleRows or #rows)
            w.data = r
            local showProfit = show and self.showProfitColumn == true
            w.name:Show(show); w.rate:Show(show); w.price:Show(show); w.profit:Show(showProfit); w.hit:Show(show)
            if show then
                w.name:SetText(tostring(r.name or ""))
                w.rate:SetText(tostring(r.rate or "--"))
                w.price:SetText(tostring(r.price or "--"))
                w.profit:SetText(tostring(r.profit or "--"))
                S.Theme:SetLabelTone(w.rate, r.tone)
                S.Theme:SetLabelTone(w.profit, tonumber(r.profitCopper) ~= nil and (tonumber(r.profitCopper) >= 0 and "green" or "red") or "muted")
            end
        end
        if d.status == "loading" then footer:SetText("正在查询实时货率……")
        elseif d.status == "error" or d.status == "unavailable" then footer:SetText("无法查询：" .. tostring(d.error or "未知原因"))
        elseif d.status == "ready" then footer:SetText("实时货率 · 点击贸易品查看材料/毛利 · 滚轮可翻页")
        elseif tonumber(S.State.life.trade.fromZone) ~= nil and tonumber(S.State.life.trade.toZone) == nil then
            footer:SetText(d.sellableFallback and "请选择目的地 · 当前交货地列表由官方生产地区兜底" or "请选择目的地")
        else footer:SetText("请从下拉框选择出发地与目的地") end
        local top = d.rows and d.rows[1]
        mini:SetText((d.route or "跑商") .. " | " .. (top and top.rate or "--") .. " | " .. (top and top.price or "--"))
    end

    widget.OnLayout = function(self, width, height, titleHeight, mode)
        local scale = S.Layout:GetContext().addonScale
        local standard = mode == "standard"
        local miniMode = mode == "mini"
        self.refs.titleBar:Show(true); mini:Show(miniMode)
        for _, c in ipairs({ route, favoriteToggle, refresh, favoritePrev, favoriteNext, headerName, headerRate, headerPrice, headerProfit, footer, self.favoriteDropdown.trigger, self.fromDropdown.trigger, self.toDropdown.trigger }) do c:Show(standard) end
        if not standard then self.favoriteDropdown:Close(); self.fromDropdown:Close(); self.toDropdown:Close(); up:Show(false); down:Show(false) end
        if miniMode then mini:SetExtent(width - 16 * scale, math.max(18 * scale, height - titleHeight - 8 * scale)); S.UI:SetAnchor(mini, win, 8 * scale, titleHeight + 3 * scale) end
        if standard then
            local y = titleHeight + 7 * scale
            local popupW = math.max(620 * scale, width * 1.25)
            local sidePad = 12 * scale
            local innerW = math.max(1, width - sidePad * 2)

            -- Favorite route is always one quick row with previous/next. The
            -- origin/destination selectors share a row when space permits and
            -- fall back to stacked controls at narrow user-resized widths.
            favoritePrev:SetExtent(24 * scale, 27 * scale); favoriteNext:SetExtent(24 * scale, 27 * scale)
            S.UI:SetAnchor(favoritePrev, win, sidePad, y)
            S.UI:SetAnchor(favoriteNext, win, width - sidePad - 24 * scale, y)
            self.favoriteDropdown:ApplyLayout(sidePad + 28 * scale, y, math.max(50 * scale, innerW - 56 * scale), 27 * scale, popupW)

            local selectorY = y + 32 * scale
            local routeY
            if width >= 420 * scale then
                local selectorGap = 6 * scale
                local selectorW = math.max(80 * scale, (innerW - selectorGap) / 2)
                self.fromDropdown:ApplyLayout(sidePad, selectorY, selectorW, 27 * scale, popupW)
                self.toDropdown:ApplyLayout(sidePad + selectorW + selectorGap, selectorY, selectorW, 27 * scale, popupW)
                routeY = selectorY + 36 * scale
            else
                self.fromDropdown:ApplyLayout(sidePad, selectorY, innerW, 27 * scale, popupW)
                self.toDropdown:ApplyLayout(sidePad, selectorY + 32 * scale, innerW, 27 * scale, popupW)
                routeY = selectorY + 68 * scale
            end

            route:SetExtent(math.max(70 * scale, width - 154 * scale), 22 * scale); S.UI:SetAnchor(route, win, sidePad, routeY + 2 * scale)
            favoriteToggle:SetExtent(64 * scale, 24 * scale); S.UI:SetAnchor(favoriteToggle, win, width - 136 * scale, routeY)
            refresh:SetExtent(58 * scale, 24 * scale); S.UI:SetAnchor(refresh, win, width - 70 * scale, routeY)

            local headerY = routeY + 31 * scale
            local rowStart = headerY + 23 * scale
            local rowH = 27 * scale
            local footerY = height - 28 * scale
            self.visibleRows = math.max(1, math.min(#rows, math.floor((footerY - rowStart) / rowH)))
            local needScroll = #((S.State.data.trade or {}).rows or {}) > self.visibleRows
            local scrollRail = needScroll and 26 * scale or 6 * scale
            local leftX = sidePad
            local contentRight = width - scrollRail - 8 * scale
            self.showProfitColumn = (contentRight - leftX) >= 500 * scale
            local gap = 7 * scale
            local profitW = self.showProfitColumn and math.min(100 * scale, math.max(76 * scale, (contentRight-leftX) * 0.18)) or 0
            local priceW = math.min(106 * scale, math.max(78 * scale, (contentRight-leftX) * 0.20))
            local rateW = math.min(68 * scale, math.max(52 * scale, (contentRight-leftX) * 0.13))
            local profitX = self.showProfitColumn and (contentRight - profitW) or contentRight
            local priceX = profitX - (self.showProfitColumn and gap or 0) - priceW
            local rateX = priceX - gap - rateW
            local nameW = math.max(70 * scale, rateX - gap - leftX)
            headerName:SetExtent(nameW, 20 * scale); headerRate:SetExtent(rateW, 20 * scale); headerPrice:SetExtent(priceW, 20 * scale); headerProfit:SetExtent(profitW, 20 * scale)
            S.UI:SetAnchor(headerName, win, leftX, headerY); S.UI:SetAnchor(headerRate, win, rateX, headerY); S.UI:SetAnchor(headerPrice, win, priceX, headerY); S.UI:SetAnchor(headerProfit, win, profitX, headerY)
            headerProfit:Show(self.showProfitColumn)
            for i, w in ipairs(rows) do
                local ry = rowStart + (i - 1) * rowH
                w.name:SetExtent(nameW, 22 * scale); w.rate:SetExtent(rateW, 22 * scale); w.price:SetExtent(priceW, 22 * scale); w.profit:SetExtent(profitW, 22 * scale); w.hit:SetExtent(math.max(1, contentRight - leftX), 22 * scale)
                S.UI:SetAnchor(w.name, win, leftX, ry); S.UI:SetAnchor(w.rate, win, rateX, ry); S.UI:SetAnchor(w.price, win, priceX, ry); S.UI:SetAnchor(w.profit, win, profitX, ry); S.UI:SetAnchor(w.hit, win, leftX, ry)
            end
            up:SetExtent(20 * scale, 20 * scale); down:SetExtent(20 * scale, 20 * scale)
            S.UI:SetAnchor(up, win, width - 23 * scale, rowStart)
            S.UI:SetAnchor(down, win, width - 23 * scale, math.max(rowStart, footerY - 21 * scale))
            footer:SetExtent(width - 42 * scale, 20 * scale); S.UI:SetAnchor(footer, win, sidePad, footerY)
        end
        self:Refresh()
    end

    widget:ApplyLayout(false)
    return widget
end

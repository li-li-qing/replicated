------------------------------------------------------------------------
-- Replicated Suite - Life dashboard
-- Author: Replicated
-- v0.2.8-ui7: content-aware responsive grid + vertical two-cell trade card
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local function ClampLocal(value, minimum, maximum)
    local n = tonumber(value) or minimum
    if n < minimum then return minimum end
    if n > maximum then return maximum end
    return n
end

local function ResponsiveFontLocal(width, minFont, maxFont)
    local w = tonumber(width) or 300
    local t = ClampLocal((w - 240) / 520, 0, 1)
    return math.floor(minFont + (maxFont - minFont) * t + 0.5)
end

S.LifePage = {}
local P = S.LifePage

local function CreateListCard(parent, id, title, maxRows, actionText, actionFn, onRowClick, options)
    options = type(options) == "table" and options or {}
    local card = {
        id = id,
        rowWidgets = {},
        data = {},
        onRowClick = onRowClick,
        scrollOffset = 0,
        visibleCount = 0,
        preferredRows = math.max(1, tonumber(options.preferredRows) or 5),
        maxPreferredRows = math.max(1, tonumber(options.maxPreferredRows) or math.min(maxRows or 16, 8)),
        growWeight = math.max(0, tonumber(options.growWeight) or 1),
        statusDesign = tonumber(options.statusDesign),
        metaDesign = tonumber(options.metaDesign),
        metaFraction = tonumber(options.metaFraction),
    }
    local root = S.UI:CreatePanel(parent, id .. "_card", 0, 0, 100, 100, "card", { gradient = true })
    local header = S.UI:CreatePanel(root, id .. "_header", 1, 1, 98, 26, "header", { gradient = true, accentStrip = 2 })
    local titleLabel = S.UI:CreateLabel(header, id .. "_title", title, 8, 3, 160, 20, 12, nil, ALIGN_LEFT, true)
    local metaLabel = S.UI:CreateLabel(header, id .. "_meta", "", 0, 4, 120, 18, 8, "muted", ALIGN_RIGHT)
    metaLabel:Show(false)
    local action = nil
    if actionText then
        action = S.UI:CreateButton(header, id .. "_action", actionText, 0, 2, 62, 22, 9, false)
        if actionFn then S.UI:SafeHandler(action, "OnClick", actionFn, id .. ":action") end
    end
    local secondaryAction = nil
    if options.secondaryActionText then
        secondaryAction = S.UI:CreateButton(header, id .. "_secondary_action", tostring(options.secondaryActionText), 0, 2, 62, 22, 9, false)
        if type(options.secondaryActionFn)=="function" then S.UI:SafeHandler(secondaryAction,"OnClick",options.secondaryActionFn,id..":secondary_action") end
    end
    local up = S.UI:CreateButton(root, id .. "_scroll_up", "^", 0, 0, 20, 20, 8, false)
    local down = S.UI:CreateButton(root, id .. "_scroll_down", "v", 0, 0, 20, 20, 8, false)
    up:Show(false); down:Show(false)

    for i = 1, (maxRows or 16) do
        local name
        if onRowClick then
            name = S.UI:CreateButton(root, id .. "_name_" .. i, "", 8, 0, 120, 22, 10, false)
            if name.style and name.style.SetAlign then pcall(function() name.style:SetAlign(ALIGN_LEFT) end) end
        else
            name = S.UI:CreateLabel(root, id .. "_name_" .. i, "", 8, 0, 120, 22, 10, nil, ALIGN_LEFT)
        end
        local value = S.UI:CreateLabel(root, id .. "_value_" .. i, "", 0, 0, 80, 22, 10, "muted", ALIGN_RIGHT)
        name:Show(false); value:Show(false)
        card.rowWidgets[i] = { name = name, value = value, data = nil }
        if onRowClick then
            local rowWidget = card.rowWidgets[i]
            S.UI:SafeHandler(name, "OnClick", function()
                if rowWidget.data ~= nil then onRowClick(rowWidget.data) end
            end, id .. ":row:" .. i)
        end
    end

    function card:SetHeaderMeta(text, tone)
        local value = tostring(text or "")
        metaLabel:SetText(value)
        metaLabel:Show(value ~= "")
        S.Theme:SetLabelTone(metaLabel, tone or "muted")
    end

    function card:GetMaxOffset()
        local visible = math.max(1, tonumber(self.visibleCount) or 0)
        return math.max(0, #self.data - visible)
    end

    function card:Scroll(delta)
        if (tonumber(self.visibleCount) or 0) <= 0 then return end
        self.scrollOffset = math.max(0, math.min(self:GetMaxOffset(), (tonumber(self.scrollOffset) or 0) + (tonumber(delta) or 0)))
        self:RefreshRows()
    end

    S.UI:SafeHandler(up, "OnClick", function() card:Scroll(-1) end, id .. ":scroll_up")
    S.UI:SafeHandler(down, "OnClick", function() card:Scroll(1) end, id .. ":scroll_down")
    if root.EnableScroll ~= nil then pcall(function() root:EnableScroll(true) end) end
    S.UI:SafeHandler(root, "OnWheelUp", function() card:Scroll(-1) end, id .. ":wheel_up")
    S.UI:SafeHandler(root, "OnWheelDown", function() card:Scroll(1) end, id .. ":wheel_down")

    function card:SetRows(rows)
        self.data = type(rows) == "table" and rows or {}
        self.scrollOffset = math.max(0, math.min(self.scrollOffset or 0, self:GetMaxOffset()))
        self:RefreshRows()
    end

    function card:RefreshRows()
        local count = math.max(0, tonumber(self.visibleCount) or 0)
        local needScroll = count > 0 and #self.data > count
        local maxOffset = self:GetMaxOffset()
        self.scrollOffset = math.max(0, math.min(self.scrollOffset or 0, maxOffset))
        up:Show(needScroll); down:Show(needScroll)
        if up.Enable then up:Enable(needScroll and self.scrollOffset>0) end
        if down.Enable then down:Enable(needScroll and self.scrollOffset<maxOffset) end
        for i, w in ipairs(self.rowWidgets) do
            local dataIndex = self.scrollOffset + i
            local row = self.data[dataIndex]
            local show = row ~= nil and i <= count
            w.data = row
            w.name:Show(show); w.value:Show(show)
            if show then
                local label = tostring(row.name or "")
                if self.onRowClick then label = label .. "  >" end
                w.name:SetText(label)
                w.value:SetText(tostring(row.status or ""))
                S.Theme:SetLabelTone(w.value, row.tone)
            end
        end
    end

    function card:GetMetrics(rowHeight)
        local scale = S.Layout:GetContext().addonScale
        local headerH = 32 * scale
        local dataRows = math.max(1, #self.data)
        local preferredRows = math.min(dataRows, self.preferredRows)
        local maxRowsForContent = math.min(dataRows, self.maxPreferredRows, #self.rowWidgets)
        return {
            min = headerH + rowHeight + 4 * scale,
            desired = headerH + preferredRows * rowHeight + 4 * scale,
            max = headerH + maxRowsForContent * rowHeight + 4 * scale,
            grow = self.growWeight,
        }
    end

    function card:ApplyLayout(x, y, width, height, rowHeight)
        S.UI:SetAnchor(root, parent, x, y); root:SetExtent(width, height)
        local scale = S.Layout:GetContext().addonScale
        local headerH = math.min(28 * scale, math.max(24 * scale, height - 2))
        header:SetExtent(width - 2, headerH)

        local actionW = action and 68 * scale or 0
        local secondaryW = secondaryAction and 68 * scale or 0
        local metaDesign = tonumber(self.metaDesign) or 128
        local metaFraction = tonumber(self.metaFraction) or 0.34
        local metaW = math.min(metaDesign * scale, math.max(0, width * metaFraction))
        local right = width - 6 * scale
        if action then
            right = right - actionW
            action:SetExtent(actionW,23*scale); S.UI:SetAnchor(action,header,right,2*scale)
            right = right - 4*scale
        end
        if secondaryAction then
            right = right - secondaryW
            secondaryAction:SetExtent(secondaryW,23*scale); S.UI:SetAnchor(secondaryAction,header,right,2*scale)
            right = right - 4*scale
        end
        local metaRight = right
        local metaX = math.max(90 * scale, metaRight - metaW)
        metaLabel:SetExtent(math.max(1, metaRight - metaX), 18 * scale)
        S.UI:SetAnchor(metaLabel, header, metaX, 4 * scale)
        titleLabel:SetExtent(math.max(40 * scale, metaX - 14 * scale), 22 * scale)

        local top = 32 * scale
        local available = math.max(0, height - top - 4 * scale)
        local fit = math.max(0, math.floor(available / math.max(1, rowHeight)))
        self.visibleCount = math.min(#self.rowWidgets, fit)
        local needScroll = self.visibleCount > 0 and #self.data > self.visibleCount
        local scrollW = needScroll and 24 * scale or 0

        local statusDesign = self.statusDesign
        if statusDesign == nil then
            statusDesign = 96
            if id == "life_daily" or id == "life_weekly" then statusDesign = 118
            elseif id == "life_character" then statusDesign = 126
            elseif id == "life_resources" then statusDesign = 132
            elseif id == "life_events" then statusDesign = 112
            elseif id == "life_bonds" then statusDesign = 104
            elseif id == "life_quick" then statusDesign = 82 end
        end

        local rightPad = 7 * scale
        local contentRight = math.max(80 * scale, width - scrollW - rightPad)
        local statusW = math.min(statusDesign * scale, math.max(50 * scale, contentRight * 0.46))
        local statusX = math.max(74 * scale, contentRight - statusW)
        for i, w in ipairs(self.rowWidgets) do
            if i <= self.visibleCount then
                local ry = top + (i - 1) * rowHeight
                local nameX = 8 * scale
                local nameW = math.max(44 * scale, statusX - nameX - 5 * scale)
                w.name:SetExtent(nameW, math.max(1, rowHeight - 1 * scale))
                w.value:SetExtent(statusW, math.max(1, rowHeight - 1 * scale))
                S.UI:SetAnchor(w.name, root, nameX, ry)
                S.UI:SetAnchor(w.value, root, statusX, ry)
            end
        end
        up:SetExtent(20 * scale, 20 * scale); down:SetExtent(20 * scale, 20 * scale)
        S.UI:SetAnchor(up, root, width - 22 * scale, top)
        S.UI:SetAnchor(down, root, width - 22 * scale, math.max(top, height - 23 * scale))
        self:RefreshRows()
    end

    card.root = root
    card.header = header
    card.title = titleLabel
    card.meta = metaLabel
    card.action = action
    card.secondaryAction = secondaryAction
    return card
end


local function CreateEventCard(parent)
    local id="life_events"
    local card={id=id,rowWidgets={},data={},eventRows={},scrollOffset=0,visibleCount=0,preferredRows=8,maxPreferredRows=20,growWeight=1.6}
    local root=S.UI:CreatePanel(parent,id.."_card",0,0,100,100,"card",{gradient=true})
    local header=S.UI:CreatePanel(root,id.."_header",1,1,98,26,"header",{gradient=true,accentStrip=2})
    local titleLabel=S.UI:CreateLabel(header,id.."_title","活动时间",8,3,160,20,12,nil,ALIGN_LEFT,true)
    local action=S.UI:CreateButton(header,id.."_action","悬浮",0,2,62,22,9,false)
    S.UI:SafeHandler(action,"OnClick",function() S.UI:ToggleWidget("event") end,id..":action")
    local up=S.UI:CreateButton(root,id.."_scroll_up","^",0,0,20,20,8,false)
    local down=S.UI:CreateButton(root,id.."_scroll_down","v",0,0,20,20,8,false)
    up:Show(false);down:Show(false)

    local function DisplayName(row,density)
        if type(row)~="table" then return "" end
        if density=="ultra" then return tostring(row.microName or row.shortName or row.name or row.fullName or "") end
        if density=="compact" then return tostring(row.shortName or row.name or row.fullName or "") end
        return tostring(row.fullName or row.name or "")
    end
    local function CompactStatus(text,density)
        local value=tostring(text or "--")
        if density~="ultra" then return value end
        local payload=string.match(value,"^进行中%s+纷争%s+(.+)$");if payload then return "进行 纷"..payload end
        payload=string.match(value,"^进行中%s+战争%s+(.+)$");if payload then return "进行 战"..payload end
        payload=string.match(value,"^和平%s+(.+)$");if payload then return "和"..payload end
        local danger=string.match(value,"^危险(%d)阶段$");if danger then return "危"..danger end
        return value
    end

    for i=1,20 do
        local idx=i
        local name=S.UI:CreateButton(root,id.."_name_"..i,"",8,0,120,18,9,false)
        if name.style and name.style.SetAlign then pcall(function() name.style:SetAlign(ALIGN_LEFT) end) end
        local value=S.UI:CreateLabel(root,id.."_value_"..i,"",0,0,82,18,9,"blue",ALIGN_CENTER)
        local progress=S.UI:CreateLabel(root,id.."_progress_"..i,"",0,0,34,18,9,"yellow",ALIGN_RIGHT)
        name:Show(false);value:Show(false);progress:Show(false)
        card.rowWidgets[i]={name=name,value=value,progress=progress,data=nil}
        S.UI:SafeHandler(name,"OnClick",function() local row=card.rowWidgets[idx].data;if row and row.questKey and S.Services and S.Services.Event then S.Services.Event:OpenTask(row) end end,id..":row:"..i)
        S.UI:SafeHandler(name,"OnRButtonUp",function() local row=card.rowWidgets[idx].data;local service=S.Services and S.Services.Event;if row and service and type(service.HideEvent)=="function" then service:HideEvent(row) end end,id..":hide:"..i)
    end

    function card:GetMaxOffset() local visible=math.max(1,tonumber(self.visibleCount) or 0);return math.max(0,#self.eventRows-visible) end
    function card:Scroll(delta) if (tonumber(self.visibleCount) or 0)<=0 then return end;self.scrollOffset=math.max(0,math.min(self:GetMaxOffset(),(tonumber(self.scrollOffset) or 0)+(tonumber(delta) or 0)));self:RefreshRows() end
    S.UI:SafeHandler(up,"OnClick",function() card:Scroll(-1) end,id..":scroll_up")
    S.UI:SafeHandler(down,"OnClick",function() card:Scroll(1) end,id..":scroll_down")
    if root.EnableScroll~=nil then pcall(function() root:EnableScroll(true) end) end
    S.UI:SafeHandler(root,"OnWheelUp",function() card:Scroll(-1) end,id..":wheel_up")
    S.UI:SafeHandler(root,"OnWheelDown",function() card:Scroll(1) end,id..":wheel_down")

    function card:SetRows(rows)
        self.eventRows={}
        for _,row in ipairs(type(rows)=="table" and rows or {}) do self.eventRows[#self.eventRows+1]=row end
        self.data=self.eventRows;self.scrollOffset=math.max(0,math.min(self.scrollOffset or 0,self:GetMaxOffset()));self:RefreshRows()
    end
    function card:RefreshRows()
        local count=math.max(0,tonumber(self.visibleCount) or 0);local needScroll=count>0 and #self.eventRows>count
        local maxOffset=self:GetMaxOffset()
        self.scrollOffset=math.max(0,math.min(self.scrollOffset or 0,maxOffset));up:Show(needScroll);down:Show(needScroll)
        if up.Enable then up:Enable(needScroll and self.scrollOffset>0) end
        if down.Enable then down:Enable(needScroll and self.scrollOffset<maxOffset) end
        for i,w in ipairs(self.rowWidgets) do
            local row=self.eventRows[self.scrollOffset+i];local show=row~=nil and i<=count;w.data=row
            w.name:Show(show);w.value:Show(show);w.progress:Show(show)
            if show then
                local density=tostring(self.eventDensity or "full")
                local suffix=row.questKey and "  >" or ""
                w.name:SetText(DisplayName(row,density)..suffix)
                w.value:SetText(CompactStatus(row.status,density))
                local progressText=(row.questKey~=nil and row.progressText~=nil and row.progressText~="--") and tostring(row.progressText) or ""
                w.progress:SetText(progressText)
                S.Theme:SetLabelTone(w.name,row.active==true and "red" or nil);S.Theme:SetLabelTone(w.value,row.tone or "blue");S.Theme:SetLabelTone(w.progress,progressText~="" and (row.progressTone or "yellow") or "muted")
                if w.name.Enable then w.name:Enable(row.questKey~=nil) end
            end
        end
    end
    function card:GetMetrics(rowHeight)
        local scale=S.Layout:GetContext().addonScale;local headerH=32*scale;local denseRowH=19*scale;local dataRows=math.max(1,#self.eventRows)
        local preferredRows=math.min(dataRows,self.preferredRows);local maxRows=math.min(dataRows,self.maxPreferredRows,#self.rowWidgets)
        return {min=headerH+denseRowH*3+4*scale,desired=headerH+preferredRows*denseRowH+4*scale,max=headerH+maxRows*denseRowH+4*scale,grow=self.growWeight}
    end
    function card:ApplyLayout(x,y,width,height,rowHeight)
        S.UI:SetAnchor(root,parent,x,y);root:SetExtent(width,height)
        local scale=S.Layout:GetContext().addonScale;local headerH=math.min(28*scale,math.max(24*scale,height-2))
        header:SetExtent(width-2,headerH);action:SetExtent(62*scale,23*scale);S.UI:SetAnchor(action,header,width-68*scale,2*scale);titleLabel:SetExtent(math.max(60*scale,width-82*scale),22*scale)
        local rowFont=ResponsiveFontLocal(width,10,12);local listTop=headerH+3*scale;local bottomPad=5*scale;local rowH=math.max(18*scale,rowFont+5*scale)
        local fit=math.floor(math.max(0,height-listTop-bottomPad)/math.max(1,rowH));self.visibleCount=math.max(0,math.min(#self.rowWidgets,fit))
        local density="full";if width<250*scale then density="ultra" elseif width<360*scale then density="compact" end;self.eventDensity=density
        local needScroll=self.visibleCount>0 and #self.eventRows>self.visibleCount;local scrollW=needScroll and 23*scale or 0
        local leftPad=5*scale;local rightPad=5*scale+scrollW;local gap=(density=="ultra" and 2 or 4)*scale
        local progressW=(density=="ultra" and 34 or (density=="compact" and 42 or 52))*scale
        local timeW=(density=="ultra" and 78 or (density=="compact" and 108 or 132))*scale
        local progressX=math.max(leftPad,width-rightPad-progressW);local valueX=math.max(leftPad+50*scale,progressX-gap-timeW);local nameW=math.max(40*scale,valueX-leftPad-gap)
        for i,w in ipairs(self.rowWidgets) do
            if w.name.style then w.name.style:SetFontSize(rowFont) end;if w.value.style then w.value.style:SetFontSize(rowFont) end;if w.progress.style then w.progress.style:SetFontSize(rowFont) end
            local ry=listTop+(i-1)*rowH;w.name:SetExtent(nameW,rowH);w.value:SetExtent(timeW,rowH);w.progress:SetExtent(progressW,rowH)
            S.UI:SetAnchor(w.name,root,leftPad,ry);S.UI:SetAnchor(w.value,root,valueX,ry);S.UI:SetAnchor(w.progress,root,progressX,ry)
        end
        up:SetExtent(20*scale,20*scale);down:SetExtent(20*scale,20*scale);S.UI:SetAnchor(up,root,width-22*scale,listTop);S.UI:SetAnchor(down,root,width-22*scale,math.max(listTop,height-23*scale))
        self:RefreshRows()
    end
    card.root=root
    return card
end

local function CreateTradeCard(parent)
    local card = { id = "life_trade", scrollOffset = 0, visibleCount = 0, preferredRows = 10, maxPreferredRows = 16, growWeight = 2.4 }
    local root = S.UI:CreatePanel(parent, "life_trade_card", 0, 0, 100, 100, "card", { gradient = true })
    local header = S.UI:CreatePanel(root, "life_trade_header", 1, 1, 98, 26, "header", { gradient = true, accentStrip = 2 })
    local title = S.UI:CreateLabel(header, "life_trade_title", "跑商货率查询", 8, 3, 170, 20, 12, nil, ALIGN_LEFT, true)
    local detail = S.UI:CreateButton(header, "life_trade_detail", "悬浮", 0, 2, 58, 22, 9, false)
    local refresh = S.UI:CreateButton(header, "life_trade_refresh", "刷新", 0, 2, 58, 22, 9, false)
    -- P1-3: craft-station material assist entry. Manual open is the guaranteed
    -- fallback channel when native craft-station detection is unavailable.
    local assist = S.UI:CreateButton(header, "life_trade_assist", "助手", 0, 2, 58, 22, 9, false)
    local fromText = S.UI:CreateLabel(root, "life_trade_from_text", "出发地", 8, 0, 60, 20, 9, "muted", ALIGN_LEFT)
    local toText = S.UI:CreateLabel(root, "life_trade_to_text", "目的地", 8, 0, 60, 20, 9, "muted", ALIGN_LEFT)
    local status = S.UI:CreateLabel(root, "life_trade_status", "请选择出发地和目的地", 8, 0, 200, 20, 10, "yellow", ALIGN_LEFT)
    -- P1-3 master switch for the craft-station material assist. Lives in the
    -- trade card because the feature rides the trade module lifecycle.
    local assistToggle = S.UI:CreateButton(root, "life_trade_assist_toggle", "助手：关", 0, 0, 64, 20, 9, false)
    local up = S.UI:CreateButton(root, "life_trade_scroll_up", "^", 0, 0, 20, 20, 8, false)
    local down = S.UI:CreateButton(root, "life_trade_scroll_down", "v", 0, 0, 20, 20, 8, false)
    local rows = {}
    for i = 1, 16 do
        local idx = i
        rows[i] = {
            name = S.UI:CreateLabel(root, "life_trade_row_name_" .. i, "", 8, 0, 120, 20, 9, nil, ALIGN_LEFT),
            value = S.UI:CreateLabel(root, "life_trade_row_value_" .. i, "", 0, 0, 100, 20, 9, "green", ALIGN_RIGHT),
            hit = UIParent:CreateWidget("emptywidget", S.PhysicalId("life_trade_row_hit_" .. i), root),
            data = nil,
        }
        rows[i].hit:SetExtent(220, 20)
        if rows[i].hit.Enable ~= nil then rows[i].hit:Enable(true) end
        if rows[i].hit.EnablePick ~= nil then pcall(function() rows[i].hit:EnablePick(true) end) end
        if rows[i].hit.Clickable ~= nil then pcall(function() rows[i].hit:Clickable(true) end) end
        rows[i].name:Show(false); rows[i].value:Show(false); rows[i].hit:Show(false)
        S.UI:SafeHandler(rows[i].hit, "OnClick", function()
            local selected = rows[idx] and rows[idx].data
            local svc = S.Services and S.Services.Trade
            if selected ~= nil and svc ~= nil and type(svc.SelectPack) == "function" then svc:SelectPack(selected, true) end
        end, "life_trade:row:" .. i)
        -- The transparent row hit target sits above the labels, so preserve the
        -- card's existing wheel navigation when the pointer is over a product.
        S.UI:SafeHandler(rows[i].hit, "OnWheelUp", function() card:Scroll(-1) end, "life_trade:row_wheel_up:" .. i)
        S.UI:SafeHandler(rows[i].hit, "OnWheelDown", function() card:Scroll(1) end, "life_trade:row_wheel_down:" .. i)
    end

    local function Service() return S.Services and S.Services.Trade end
    local function ZoneItems(zones)
        local items = {}
        for _, z in ipairs(zones or {}) do items[#items + 1] = { value = z.id, text = z.displayName or z.name } end
        return items
    end

    card.fromDropdown = S.Dropdown:Create(root, "life_trade_from_dd", 200, 27, 12, function(item)
        local svc = Service(); if svc == nil or item == nil then return end
        svc:SelectFrom(item.value)
        card.scrollOffset = 0
        card:RefreshDropdowns(); card:Refresh()
    end)
    card.toDropdown = S.Dropdown:Create(root, "life_trade_to_dd", 200, 27, 12, function(item)
        local svc = Service(); if svc == nil or item == nil then return end
        card.scrollOffset = 0
        svc:SelectTo(item.value)
    end)
    S.UI:SafeHandler(detail, "OnClick", function() S.UI:ToggleWidget("trade") end, "life_trade:detail")
    S.UI:SafeHandler(refresh, "OnClick", function() local svc = Service(); if svc then svc:Request(true) end end, "life_trade:refresh")
    S.UI:SafeHandler(assist, "OnClick", function()
        local craft = S.Services and S.Services.CraftAssist
        if craft == nil then S.SafeChat("制作台助手服务尚未就绪"); return end
        local window = S.CraftAssistWindow
        if window ~= nil and type(window.Show) == "function" then
            craft:ManualRefresh()
            window:Show(true)
        end
    end, "life_trade:assist")
    S.UI:SafeHandler(assistToggle, "OnClick", function()
        local settings = S.State and S.State.settings or {}
        local craft = settings.craftAssist
        if type(craft) ~= "table" then craft = { enabled = true, autoShow = true }; settings.craftAssist = craft end
        craft.enabled = not (craft.enabled == true)
        if S.Storage ~= nil and type(S.Storage.RequestSave) == "function" then S.Storage:RequestSave() end
        if S.State ~= nil and type(S.State.MarkDirty) == "function" then S.State:MarkDirty("craftAssist") end
        card:Refresh()
    end, "life_trade:assist_toggle")

    function card:GetMaxOffset()
        local visible = math.max(1, tonumber(self.visibleCount) or 0)
        return math.max(0, #((S.State.data.trade or {}).rows or {}) - visible)
    end
    function card:Scroll(delta)
        if (tonumber(self.visibleCount) or 0) <= 0 then return end
        self.scrollOffset = math.max(0, math.min(self:GetMaxOffset(), (self.scrollOffset or 0) + (tonumber(delta) or 0)))
        self:Refresh()
    end
    S.UI:SafeHandler(up, "OnClick", function() card:Scroll(-1) end, "life_trade:up")
    S.UI:SafeHandler(down, "OnClick", function() card:Scroll(1) end, "life_trade:down")
    if root.EnableScroll ~= nil then pcall(function() root:EnableScroll(true) end) end
    S.UI:SafeHandler(root, "OnWheelUp", function() card:Scroll(-1) end, "life_trade:wheel_up")
    S.UI:SafeHandler(root, "OnWheelDown", function() card:Scroll(1) end, "life_trade:wheel_down")

    function card:RefreshDropdowns()
        local d = S.State.data.trade or {}
        self.fromDropdown:SetItems(ZoneItems(d.zones))
        self.fromDropdown:SetSelectedValue(tonumber(S.State.life.trade.fromZone), true)
        self.toDropdown:SetItems(ZoneItems(d.sellableZones))
        self.toDropdown:SetSelectedValue(tonumber(S.State.life.trade.toZone), true)
    end

    function card:Refresh()
        local d = S.State.data.trade or {}
        self:RefreshDropdowns()
        if d.status == "loading" then status:SetText("正在查询 " .. tostring(d.route or "")); S.Theme:SetLabelTone(status, "yellow")
        elseif d.status == "ready" then status:SetText(tostring(d.route or "") .. " · 实时货率"); S.Theme:SetLabelTone(status, "blue")
        elseif d.status == "error" or d.status == "unavailable" then status:SetText(tostring(d.error or "当前路线不可查询")); S.Theme:SetLabelTone(status, "red")
        elseif tonumber(S.State.life.trade.fromZone) ~= nil and tonumber(S.State.life.trade.toZone) == nil then
            status:SetText(d.sellableFallback and "请选择目的地（交货地列表使用官方地区兜底）" or "请选择目的地"); S.Theme:SetLabelTone(status, "muted")
        else status:SetText("请选择出发地和目的地"); S.Theme:SetLabelTone(status, "muted") end
        local craftCfg = (S.State and S.State.settings and S.State.settings.craftAssist) or {}
        assistToggle:SetText(craftCfg.enabled == true and "助手：开" or "助手：关")
        local toggleOn = craftCfg.enabled == true
        if assistToggle.rsButtonBgs and assistToggle.rsButtonBgs[1] then
            pcall(function() assistToggle.rsButtonBgs[1]:SetColor(toggleOn and 0.10 or 0.075, toggleOn and 0.42 or 0.095, toggleOn and 0.16 or 0.120, 0.97) end)
        end
        self.scrollOffset = math.max(0, math.min(self.scrollOffset or 0, self:GetMaxOffset()))
        local needScroll = self.visibleCount > 0 and #(d.rows or {}) > self.visibleCount
        up:Show(needScroll); down:Show(needScroll)
        local maxOffset=self:GetMaxOffset()
        if up.Enable then up:Enable(needScroll and self.scrollOffset>0) end
        if down.Enable then down:Enable(needScroll and self.scrollOffset<maxOffset) end
        for i, w in ipairs(rows) do
            local r = d.rows and d.rows[self.scrollOffset + i] or nil
            local show = r ~= nil and i <= (self.visibleCount or 0)
            w.data = r
            w.name:Show(show); w.value:Show(show); w.hit:Show(show)
            if show then
                w.name:SetText(tostring(r.name or ""))
                w.value:SetText(tostring(r.rate or "--") .. "  " .. tostring(r.price or "--"))
                if w.hit.EnablePick ~= nil then pcall(function() w.hit:EnablePick(true) end) end
                if w.hit.Raise ~= nil then pcall(function() w.hit:Raise() end) end
                S.Theme:SetLabelTone(w.value, r.tone)
            elseif w.hit.EnablePick ~= nil then
                pcall(function() w.hit:EnablePick(false) end)
            end
        end
    end

    function card:GetMetrics(rowHeight)
        local scale = S.Layout:GetContext().addonScale
        local fixed = (34 + 31 + 34 + 24) * scale
        local dataRows = math.max(1, #((S.State.data.trade or {}).rows or {}))
        local preferredRows = math.min(dataRows, self.preferredRows)
        local maxRowsForContent = math.min(dataRows, self.maxPreferredRows, #rows)
        return {
            min = fixed + rowHeight + 4 * scale,
            desired = fixed + preferredRows * rowHeight + 4 * scale,
            max = fixed + maxRowsForContent * rowHeight + 4 * scale,
            grow = self.growWeight,
        }
    end

    function card:ApplyLayout(x, y, width, height, rowHeight)
        S.UI:SetAnchor(root, parent, x, y); root:SetExtent(width, height)
        local scale = S.Layout:GetContext().addonScale
        header:SetExtent(width - 2, 28 * scale)
        title:SetExtent(math.max(80 * scale, width - 206 * scale), 22 * scale)
        detail:SetExtent(58 * scale, 23 * scale); refresh:SetExtent(58 * scale, 23 * scale); assist:SetExtent(58 * scale, 23 * scale)
        S.UI:SetAnchor(assist, header, width - 190 * scale, 2 * scale)
        S.UI:SetAnchor(detail, header, width - 128 * scale, 2 * scale)
        S.UI:SetAnchor(refresh, header, width - 66 * scale, 2 * scale)
        local contentY = 34 * scale
        local labelW = 50 * scale
        local fieldW = math.max(120 * scale, width - labelW - 22 * scale)
        local context = S.Layout:GetContext()
        local popupW = math.min(context.usableWidth, math.max(560 * scale, fieldW, width * 1.35))
        fromText:SetExtent(labelW, 20 * scale); S.UI:SetAnchor(fromText, root, 8 * scale, contentY + 3 * scale)
        self.fromDropdown:ApplyLayout(8 * scale + labelW, contentY, fieldW, 27 * scale, popupW)
        contentY = contentY + 31 * scale
        toText:SetExtent(labelW, 20 * scale); S.UI:SetAnchor(toText, root, 8 * scale, contentY + 3 * scale)
        self.toDropdown:ApplyLayout(8 * scale + labelW, contentY, fieldW, 27 * scale, popupW)
        contentY = contentY + 34 * scale
        status:SetExtent(width - 82 * scale, 20 * scale); S.UI:SetAnchor(status, root, 8 * scale, contentY)
        assistToggle:SetExtent(64 * scale, 20 * scale); S.UI:SetAnchor(assistToggle, root, width - 70 * scale, contentY)
        contentY = contentY + 24 * scale
        local scrollW = 24 * scale
        local fit = math.max(0, math.floor((height - contentY - 4 * scale) / math.max(1, rowHeight)))
        self.visibleCount = math.min(#rows, fit)
        for i, w in ipairs(rows) do
            local ry = contentY + (i - 1) * rowHeight
            local contentRight = width - scrollW - 7 * scale
            local valueW = math.min(168 * scale, math.max(108 * scale, contentRight * 0.38))
            local valueX = contentRight - valueW
            local hitH = math.max(1, rowHeight - 1 * scale)
            w.name:SetExtent(math.max(70 * scale, valueX - 13 * scale), hitH)
            w.value:SetExtent(valueW, hitH)
            w.hit:SetExtent(math.max(1, contentRight - 6 * scale), hitH)
            S.UI:SetAnchor(w.name, root, 8 * scale, ry)
            S.UI:SetAnchor(w.value, root, valueX, ry)
            S.UI:SetAnchor(w.hit, root, 6 * scale, ry)
        end
        up:SetExtent(20 * scale, 20 * scale); down:SetExtent(20 * scale, 20 * scale)
        S.UI:SetAnchor(up, root, width - 22 * scale, contentY)
        S.UI:SetAnchor(down, root, width - 22 * scale, math.max(contentY, height - 23 * scale))
        self:Refresh()
    end

    card.root = root
    return card
end

local function DistributeHeights(tracks, available)
    local total = 0
    for _, t in ipairs(tracks) do t.height = t.min; total = total + t.height end
    local extra = math.max(0, available - total)

    local function growToward(field)
        local guard = 0
        while extra > 0.5 and guard < 16 do
            guard = guard + 1
            local active, weight = {}, 0
            for _, t in ipairs(tracks) do
                local target = tonumber(t[field]) or t.height
                if target > t.height + 0.5 then
                    active[#active + 1] = t
                    weight = weight + math.max(0.1, tonumber(t.grow) or 1)
                end
            end
            if #active == 0 or weight <= 0 then break end
            local used = 0
            for _, t in ipairs(active) do
                local target = tonumber(t[field]) or t.height
                local share = extra * (math.max(0.1, tonumber(t.grow) or 1) / weight)
                local add = math.min(target - t.height, share)
                if add > 0 then t.height = t.height + add; used = used + add end
            end
            if used <= 0.1 then break end
            extra = math.max(0, extra - used)
        end
    end

    growToward("desired")
    growToward("max")

    -- Once every track has reached its content-driven max, any remaining
    -- vertical space still belongs to the dashboard. Leaving it unused packs
    -- all cards against the top edge (especially on the first open, where many
    -- cards only have one or two rows). Distribute the remainder by grow weight
    -- so the grid fills the available height while preserving relative priority.
    if extra > 0.5 and #tracks > 0 then
        local totalWeight = 0
        for _, t in ipairs(tracks) do
            totalWeight = totalWeight + math.max(0.1, tonumber(t.grow) or 1)
        end
        if totalWeight > 0 then
            local remaining = extra
            for index, t in ipairs(tracks) do
                local add
                if index == #tracks then
                    add = remaining
                else
                    add = extra * (math.max(0.1, tonumber(t.grow) or 1) / totalWeight)
                    remaining = math.max(0, remaining - add)
                end
                t.height = t.height + math.max(0, add or 0)
            end
            extra = 0
        end
    end
    return extra
end

function P.Create(parent)
    local page = { root = S.UI:CreatePanel(parent, "life_page", 0, 0, 100, 100, "soft", { gradient = true }), cards = {}, lastColumns = 2 }
    if page.root.rsBorder and page.root.rsBorder.SetVisible then page.root.rsBorder:SetVisible(false) end
    if page.root.rsBackground and page.root.rsBackground.SetVisible then page.root.rsBackground:SetVisible(false) end

    local function OpenDetail(row)
        if row and row.placeholder == true then
            if S.DailyCustomWindow and type(S.DailyCustomWindow.Open)=="function" then S.DailyCustomWindow:Open() end
        elseif row and S.Services and S.Services.Quest then
            S.Services.Quest:OpenGroupDetail(row.scope, row.key)
        end
    end

    page.cards[1] = CreateListCard(page.root, "life_daily", "日常任务", 16, "悬浮", function() S.UI:ToggleWidget("task") end, OpenDetail,
        { preferredRows = 5, maxPreferredRows = 7, growWeight = 1, statusDesign = 118, metaDesign=84, metaFraction=0.22,
          secondaryActionText="自定义", secondaryActionFn=function() if S.DailyCustomWindow and type(S.DailyCustomWindow.Open)=="function" then S.DailyCustomWindow:Open() end end })
    page.cards[2] = CreateListCard(page.root, "life_weekly", "周常任务", 16, "悬浮", function() S.UI:ToggleWidget("task") end, OpenDetail,
        { preferredRows = 5, maxPreferredRows = 7, growWeight = 1, statusDesign = 118 })
    page.cards[3] = CreateTradeCard(page.root)
    page.cards[4] = CreateListCard(page.root, "life_resources", "资源统计", 16, "刷新", function() if S.Runtime then S.Runtime:RefreshAll(false) end end, nil,
        { preferredRows = 8, maxPreferredRows = 10, growWeight = 1.2, statusDesign = 132 })
    page.cards[5] = CreateListCard(page.root, "life_bonds", "债券 / 居民板", 20, "悬浮", function() S.UI:ToggleWidget("bond") end, nil,
        { preferredRows = 5, maxPreferredRows = 10, growWeight = 1, statusDesign = 104, metaDesign = 150, metaFraction = 0.46,
          secondaryActionText="设置", secondaryActionFn=function()
              local widget=S.UI and S.UI.widgets and S.UI.widgets.bond
              if widget and type(widget.OpenSettingsPanel)=="function" then
                  widget:OpenSettingsPanel()
              end
          end })
    page.cards[6] = CreateEventCard(page.root)
    page.cards[7] = CreateListCard(page.root, "life_character", "角色信息", 16, "刷新", function() if S.Services and S.Services.Character then S.Services.Character:Refresh() end end, nil,
        { preferredRows = 6, maxPreferredRows = 6, growWeight = 0.8, statusDesign = 126 })
    page.cards[8] = CreateListCard(page.root, "life_quick", "常用入口", 12, "管理", function() S.UI:ShowPage("quick") end, function(row)
        if row and row.actionPage then
            if type(S.State.product) == "table" then
                S.State.product.lastSeenVersion = tostring(S.Version or "")
                S.State.product.updateNoticeDismissed = true
                if S.Storage ~= nil then S.Storage:RequestSave() end
            end
            S.UI:ShowPage(tostring(row.actionPage))
            return
        end
        if row and row.favoriteId and S.Favorites then S.Favorites:Activate(row.favoriteId) end
    end,
        { preferredRows = 5, maxPreferredRows = 6, growWeight = 0.5, statusDesign = 82 })

    function page:BuildBondSummary()
        local board = S.State.data.bondBoard or {}
        local cached = board.continents or {}
        local current = board.currentContinent == "west" and "西大陆" or board.currentContinent == "east" and "东大陆" or board.currentContinent == "auroria" and "原大陆" or "--"
        local marks = {
            cached.west and "西已" or "西未",
            cached.east and "东已" or "东未",
            cached.auroria and "原已" or "原未",
        }
        self.cards[5]:SetHeaderMeta("当前:" .. current .. "  " .. table.concat(marks, " "), "muted")

        local rows = {}
        local resident=S.Services and S.Services.Resident
        local entries=resident and type(resident.GetDisplayBondEntries)=="function" and resident:GetDisplayBondEntries(board.entries or {}) or (board.entries or {})
        if self.cards[5].secondaryAction then
            self.cards[5].secondaryAction:SetText("设置")
        end
        -- Debt/resident-board data is the primary content of this card. Keep it
        -- first so resident stage diagnostics never consume the initial visible
        -- rows and push today's bond requirements below the fold.
        for _, entry in ipairs(entries) do
            local name
            if entry.text ~= nil and tostring(entry.text) ~= "" and tostring(entry.text) ~= "暂无内容" then
                name = "[" .. tostring(entry.continentLabel or "--") .. "] " .. tostring(entry.text)
            else
                name = "[" .. tostring(entry.continentLabel or "--") .. "] " .. tostring(entry.material or "债券")
            end
            rows[#rows + 1] = { name = name, status = tostring(entry.status or "--"), tone = entry.tone or "muted" }
        end
        -- Resident three-stage information is secondary and therefore appended
        -- after all captured bond rows. The wider status column above preserves
        -- strings such as "暂无3阶段" and longer zone names without truncation.
        for _, stage in ipairs(S.State.data.residentStages or {}) do
            rows[#rows + 1] = { name = "[三阶段] " .. tostring(stage.name or "居民发展"), status = tostring(stage.status or "--"), tone = stage.tone or "muted" }
        end
        if #rows == 0 then
            rows[1] = { name = "进入有居民板的区域后记录当天债券信息", status = "--", tone = "muted" }
        end
        return rows
    end

    function page:BuildQuick()
        local rows = {}
        if type(S.State.product) == "table" and tostring(S.State.product.lastSeenVersion or "") ~= tostring(S.Version or "") then
            rows[#rows + 1] = { name = "Replicated Suite " .. tostring(S.Version or "") .. " 已更新", status = "查看变化", tone = "yellow", actionPage = "diagnostics" }
        end
        local favorites = S.Favorites and S.Favorites:List() or {}
        for _, item in ipairs(favorites) do
            local status = item.kind == "page" and "页面" or item.kind == "hud" and "HUD" or "模块"
            local tone = item.kind == "module" and "green" or "blue"
            rows[#rows + 1] = { name = tostring(item.title or item.id), status = status, tone = tone, favoriteId = item.id }
        end
        if #favorites == 0 then
            rows[#rows + 1] = { name = "尚未添加常用入口", status = "点“管理”", tone = "muted" }
        end
        return rows
    end

    local function FilterTasks(source, scope)
        local result = {}
        local questService = S.Services and S.Services.Quest
        for _, r in ipairs(source or {}) do
            local tracked = scope ~= "daily" or questService == nil or questService:IsDailyTracked(r.key)
            local completed = r.state == S.Constants.QuestStatus.COMPLETED
            local include = tracked
            if S.State.settings.onlyIncompleteTasks == true and completed then include = false end
            if S.State.settings.showCompletedTasks == false and completed then include = false end
            if include then result[#result + 1] = r end
        end
        return result
    end

    function page:Refresh()
        local questService = S.Services and S.Services.Quest
        local selected,total = 0,0
        if questService and type(questService.GetDailyTrackingStats)=="function" then selected,total=questService:GetDailyTrackingStats() end
        self.cards[1]:SetHeaderMeta("追踪 "..tostring(selected).."/"..tostring(total), selected>0 and "blue" or "yellow")
        local dailyRows=FilterTasks(S.State.data.daily,"daily")
        if selected==0 then dailyRows={{ placeholder=true, name="尚未选择追踪日常", status="点“自定义”", tone="yellow", scope="daily" }} end
        self.cards[1]:SetRows(dailyRows)
        self.cards[2]:SetRows(FilterTasks(S.State.data.weekly,"weekly"))
        self.cards[3]:Refresh()
        self.cards[4]:SetRows(S.State.data.resources or {})
        self.cards[5]:SetRows(self:BuildBondSummary())
        local ev = {}
        local max = math.min(64, tonumber(S.State.settings.eventMaxRows) or 20)
        for i = 1, math.min(max + 4, #(S.State.data.events or {})) do ev[#ev + 1] = S.State.data.events[i] end
        self.cards[6]:SetRows(ev)
        self.cards[7]:SetRows(S.State.data.character or {})
        self.cards[8]:SetRows(self:BuildQuick())
    end

    -- Card heights depend on the amount of data currently available. During the
    -- first addon load the UI shell is created before Quest/Resource/Event/etc.
    -- services have populated State, so the first layout can legitimately be
    -- solved against one placeholder row per card.  Data refreshes must therefore
    -- be able to tell the layout Authority that content metrics changed; otherwise
    -- the dashboard stays packed until a manual resize happens to trigger reflow.
    function page:GetMetricSignature(spec)
        spec = spec or S.Layout:GetMainSpec()
        local scale = S.Layout:GetContext().addonScale
        local rowHeight = math.max(tonumber(spec.rowHeight) or 0, 23 * scale)
        local parts = { tostring(math.max(1, math.min(3, tonumber(spec.columns) or 2))) }
        for index = 1, #self.cards do
            local metrics = self.cards[index]:GetMetrics(rowHeight)
            parts[#parts + 1] = table.concat({
                tostring(index),
                tostring(math.floor((tonumber(metrics.min) or 0) + 0.5)),
                tostring(math.floor((tonumber(metrics.desired) or 0) + 0.5)),
                tostring(math.floor((tonumber(metrics.max) or 0) + 0.5))
            }, ":")
        end
        return table.concat(parts, "|")
    end

    function page:NeedsMetricReflow(spec)
        return self.lastMetricSignature ~= self:GetMetricSignature(spec)
    end

    function page:GetTemplate(columns)
        -- Trade is deliberately a vertical two-cell card. This increases the
        -- number of visible goods instead of only making the card wider.
        if columns >= 3 then
            return {
                { { card = 1, col = 1 }, { card = 2, col = 2 }, { card = 4, col = 3 } },
                { { card = 3, col = 1, rowSpan = 2 }, { card = 5, col = 2 }, { card = 6, col = 3 } },
                { { card = 7, col = 2 }, { card = 8, col = 3 } },
            }
        end
        if columns == 2 then
            return {
                { { card = 1, col = 1 }, { card = 2, col = 2 } },
                { { card = 3, col = 1, rowSpan = 2 }, { card = 4, col = 2 } },
                { { card = 5, col = 2 } },
                { { card = 7, col = 1 }, { card = 6, col = 2 } },
                { { card = 8, col = 1, colSpan = 2 } },
            }
        end
        return {
            { { card = 1, col = 1 } }, { { card = 2, col = 1 } }, { { card = 3, col = 1 } },
            { { card = 4, col = 1 } }, { { card = 5, col = 1 } }, { { card = 7, col = 1 } },
            { { card = 6, col = 1 } }, { { card = 8, col = 1 } },
        }
    end

    local function EnsureSpanMetric(tracks, startRow, rowSpan, metrics, gap)
        rowSpan = math.max(1, math.floor(tonumber(rowSpan) or 1))
        if rowSpan <= 1 then return end
        local lastRow = math.min(#tracks, startRow + rowSpan - 1)
        local count = lastRow - startRow + 1
        if count <= 0 then return end

        local function Ensure(field)
            local current = gap * math.max(0, count - 1)
            for r = startRow, lastRow do current = current + (tonumber(tracks[r][field]) or 0) end
            local target = tonumber(metrics[field]) or 0
            local deficit = math.max(0, target - current)
            if deficit <= 0 then return end
            local per = deficit / count
            for r = startRow, lastRow do tracks[r][field] = (tonumber(tracks[r][field]) or 0) + per end
        end
        Ensure("min")
        Ensure("desired")
        Ensure("max")
        for r = startRow, lastRow do
            tracks[r].grow = math.max(tonumber(tracks[r].grow) or 1, tonumber(metrics.grow) or 1)
        end
    end

    function page:ApplyLayout(spec)
        S.UI:SetAnchor(self.root, parent, 0, 0)
        self.root:SetExtent(spec.contentWidth, spec.contentHeight)
        self:Refresh()

        local columns = math.max(1, math.min(3, tonumber(spec.columns) or 2))
        self.lastColumns = columns
        local gap = spec.gap
        local rowHeight = math.max(spec.rowHeight, 23 * S.Layout:GetContext().addonScale)
        local template = self:GetTemplate(columns)
        local tracks = {}

        for rowIndex = 1, #template do
            tracks[rowIndex] = { min = 0, desired = 0, max = 0, grow = 1 }
        end

        -- First solve cards that occupy one row.
        for rowIndex, row in ipairs(template) do
            for _, slot in ipairs(row) do
                if math.max(1, tonumber(slot.rowSpan) or 1) == 1 then
                    local metrics = self.cards[slot.card]:GetMetrics(rowHeight)
                    local t = tracks[rowIndex]
                    t.min = math.max(t.min, metrics.min or 0)
                    t.desired = math.max(t.desired, metrics.desired or metrics.min or 0)
                    t.max = math.max(t.max, metrics.max or metrics.desired or metrics.min or 0)
                    t.grow = math.max(t.grow, tonumber(metrics.grow) or 1)
                end
            end
        end
        -- Then guarantee vertically-spanning cards receive their own minimum /
        -- preferred content height across the rows they occupy.
        for rowIndex, row in ipairs(template) do
            for _, slot in ipairs(row) do
                local rowSpan = math.max(1, tonumber(slot.rowSpan) or 1)
                if rowSpan > 1 then
                    EnsureSpanMetric(tracks, rowIndex, rowSpan, self.cards[slot.card]:GetMetrics(rowHeight), gap)
                end
            end
        end

        -- Empty continuation tracks still need a stable minimum so a span cannot
        -- collapse to a thin strip when the neighboring column has little data.
        local scale = S.Layout:GetContext().addonScale
        for _, t in ipairs(tracks) do
            local floorH = (32 * scale) + rowHeight + (4 * scale)
            t.min = math.max(t.min, floorH)
            t.desired = math.max(t.desired, t.min)
            t.max = math.max(t.max, t.desired)
        end

        local gapsTotal = gap * math.max(0, #tracks - 1)
        local availableTracks = math.max(1, spec.contentHeight - gapsTotal)
        local totalMin = 0
        for _, t in ipairs(tracks) do totalMin = totalMin + t.min end
        if totalMin > availableTracks then
            local factor = math.max(0.58, availableTracks / math.max(1, totalMin))
            for _, t in ipairs(tracks) do
                t.min = t.min * factor
                t.desired = math.max(t.min, t.desired * factor)
                t.max = math.max(t.desired, t.max * factor)
            end
        end
        DistributeHeights(tracks, availableTracks)

        local cellW = (spec.contentWidth - gap * (columns - 1)) / columns
        local rowY = {}
        local y = 0
        for rowIndex = 1, #tracks do
            rowY[rowIndex] = y
            y = y + tracks[rowIndex].height + gap
        end

        for rowIndex, row in ipairs(template) do
            for _, slot in ipairs(row) do
                local col = math.max(1, math.min(columns, tonumber(slot.col) or 1))
                local colSpan = math.max(1, math.min(columns - col + 1, tonumber(slot.colSpan) or 1))
                local rowSpan = math.max(1, math.min(#tracks - rowIndex + 1, tonumber(slot.rowSpan) or 1))
                local width = cellW * colSpan + gap * (colSpan - 1)
                local height = 0
                for r = rowIndex, rowIndex + rowSpan - 1 do height = height + tracks[r].height end
                height = height + gap * (rowSpan - 1)
                local x = (col - 1) * (cellW + gap)
                self.cards[slot.card]:ApplyLayout(x, rowY[rowIndex], width, height, rowHeight)
            end
        end
        self.lastMetricSignature = self:GetMetricSignature(spec)
    end

    S.UI.pages.life = page
    S.LifePage.instance = page
    return page
end

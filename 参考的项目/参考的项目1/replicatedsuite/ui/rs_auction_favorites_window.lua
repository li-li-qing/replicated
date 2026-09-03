------------------------------------------------------------------------
-- Replicated Suite - Auction Favorites attached window
-- Author: Replicated
--
-- Two data scopes are deliberately separated:
--   * Today: runtime-derived ingredients for active resident trade-pack Dailies.
--            Never persisted; completion/abandonment removes them automatically.
--   * My Favorites: user-owned persistent auction keywords.
--
-- Clicking either row only asks Services.AuctionFavorites to search; native
-- Auction House remains the UI/data Authority and the shared Auction service
-- remains the SearchAuctionArticle request Authority.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S=ReplicatedSuite
S.AuctionFavoritesWindow={
    window=nil, rows={}, scrollOffset=0, input=nil, pageLabel=nil,
    todayTab=nil, manualTab=nil, mode=nil,
}
local W=S.AuctionFavoritesWindow

local PANEL_W=286
local PANEL_H=410
local ROWS=10
local ROW_H=27
local TAB_Y=70
local LIST_Y=100
local BOTTOM_Y=376

local function Service()
    return S.Services and S.Services.AuctionFavorites or nil
end

local function GetText(edit)
    if edit==nil or type(edit.GetText)~="function" then return "" end
    local ok,value=pcall(function() return edit:GetText() end)
    return ok and tostring(value or "") or ""
end

local function SetText(edit,value)
    if edit~=nil and type(edit.SetText)=="function" then pcall(function() edit:SetText(tostring(value or "")) end) end
end

local function SetButtonExtent(button,width,height)
    if button~=nil and type(button.SetExtent)=="function" then
        pcall(function() button:SetExtent(width,height) end)
    end
end

function W:ResolveInitialMode()
    if self.mode=="today" or self.mode=="manual" or self.mode=="temp" then return self.mode end
    local svc=Service()
    -- Temp entries take precedence when present (F1: a material was just pushed).
    local temp=svc and type(svc.GetTempItems)=="function" and svc:GetTempItems() or {}
    if #temp>0 then self.mode="temp"; return self.mode end
    local today=svc and type(svc.GetTodayItems)=="function" and svc:GetTodayItems() or {}
    self.mode=(#today>0) and "today" or "manual"
    return self.mode
end

function W:SetMode(mode)
    mode=tostring(mode or "")
    if mode~="today" and mode~="manual" and mode~="temp" then return end
    if self.mode~=mode then self.scrollOffset=0 end
    self.mode=mode
    self:RefreshList(false)
end

function W:RefreshTabs()
    local svc=Service()
    local today=svc and type(svc.GetTodayItems)=="function" and svc:GetTodayItems() or {}
    local manual=svc and type(svc.NormalizeItems)=="function" and svc:NormalizeItems() or {}
    local temp=svc and type(svc.GetTempItems)=="function" and svc:GetTempItems() or {}
    local mode=self:ResolveInitialMode()
    if self.todayTab~=nil then
        self.todayTab:SetText((mode=="today" and "【今日】" or "今日").." "..tostring(#today))
    end
    if self.manualTab~=nil then
        self.manualTab:SetText((mode=="manual" and "【收藏】" or "收藏").." "..tostring(#manual))
    end
    if self.tempTab~=nil then
        self.tempTab:SetText((mode=="temp" and "【临时】" or "临时").." "..tostring(#temp))
    end
    if self.tempClear~=nil then
        if self.tempClear.Enable~=nil then self.tempClear:Enable(#temp>0) end
        self.tempClear:Show(mode=="temp")
    end
end

function W:Create()
    if self.window~=nil then return self.window end
    if type(CreateEmptyWindow)~="function" or S.UI==nil then return nil end

    local panel=CreateEmptyWindow(S.PhysicalId("auction_favorites_window"),"UIParent")
    if panel==nil then return nil end
    panel:SetExtent(PANEL_W,PANEL_H)
    if panel.Clickable~=nil then pcall(function() panel:Clickable(true) end) end
    if panel.SetCloseOnEscape~=nil then pcall(function() panel:SetCloseOnEscape(true) end) end
    S.UI:TrySetUILayer(panel,"system")
    if panel.SetDrawPriority~=nil then pcall(function() panel:SetDrawPriority(12100) end) end
    S.Theme:AddBorder(panel,false)
    S.Theme:AddGradientBackground(panel,"card",nil)
    S.Theme:SetOpacity(panel,1.0)

    S.UI:CreateLabel(panel,"auction_favorites_title","拍卖行收藏夹",12,9,220,24,14,"accent",ALIGN_LEFT,true)
    local close=S.UI:CreateButton(panel,"auction_favorites_close","×",250,7,26,24,13,false,true)

    local input=S.UI:CreateEditBox(panel,"auction_favorites_input",10,38,154,26,64)
    self.input=input
    local search=S.UI:CreateButton(panel,"auction_favorites_search","搜索",169,38,49,26,10,false,true)
    local add=S.UI:CreateButton(panel,"auction_favorites_add","收藏",223,38,53,26,10,false,true)

    self.todayTab=S.UI:CreateButton(panel,"auction_favorites_tab_today","今日",10,TAB_Y,84,24,9,false,false)
    self.manualTab=S.UI:CreateButton(panel,"auction_favorites_tab_manual","收藏",98,TAB_Y,84,24,9,false,false)
    -- F1: temp search queue tab (session-local, not persisted).
    self.tempTab=S.UI:CreateButton(panel,"auction_favorites_tab_temp","临时",186,TAB_Y,90,24,9,false,false)

    self.rows={}
    for i=1,ROWS do
        local y=LIST_Y+(i-1)*ROW_H
        local item=S.UI:CreateButton(panel,"auction_favorite_item_"..tostring(i),"",10,y,238,24,10,false,false)
        local del=S.UI:CreateButton(panel,"auction_favorite_delete_"..tostring(i),"×",252,y,24,24,11,false,false)
        item:Show(false); del:Show(false)
        self.rows[i]={item=item,del=del,index=nil}
    end

    local prev=S.UI:CreateButton(panel,"auction_favorites_prev","▲",10,BOTTOM_Y,38,24,10,false,false)
    local page=S.UI:CreateLabel(panel,"auction_favorites_page","",55,BOTTOM_Y+2,120,22,10,"muted",ALIGN_CENTER,false)
    local nextBtn=S.UI:CreateButton(panel,"auction_favorites_next","▼",238,BOTTOM_Y,38,24,10,false,false)
    -- F1: clear-temp button (only meaningful in temp mode).
    self.tempClear=S.UI:CreateButton(panel,"auction_favorites_temp_clear","清空临时",180,BOTTOM_Y,52,24,8,false,false)
    self.pageLabel=page

    S.UI:SafeHandler(close,"OnClick",function()
        local svc=Service(); if svc and svc.DismissForSession then svc:DismissForSession() end
    end,"auction_favorites:close")
    S.UI:SafeHandler(panel,"OnCloseByEsc",function()
        local svc=Service(); if svc and svc.DismissForSession then svc:DismissForSession() end
    end,"auction_favorites:esc")

    S.UI:SafeHandler(search,"OnClick",function()
        local text=GetText(W.input)
        local svc=Service(); if svc==nil then return end
        local ok,err=svc:Search(text)
        if ok~=true and err~=nil then S.SafeChat("拍卖搜索失败："..tostring(err)) end
    end,"auction_favorites:search")

    S.UI:SafeHandler(add,"OnClick",function()
        local text=GetText(W.input)
        local svc=Service(); if svc==nil then return end
        local ok,err=svc:AddFavorite(text)
        if ok then
            SetText(W.input,"")
            W:SetMode("manual")
        elseif err~=nil then
            S.SafeChat(tostring(err))
        end
    end,"auction_favorites:add")

    S.UI:SafeHandler(self.todayTab,"OnClick",function() W:SetMode("today") end,"auction_favorites:tab_today")
    S.UI:SafeHandler(self.manualTab,"OnClick",function() W:SetMode("manual") end,"auction_favorites:tab_manual")
    S.UI:SafeHandler(self.tempTab,"OnClick",function() W:SetMode("temp") end,"auction_favorites:tab_temp")
    S.UI:SafeHandler(self.tempClear,"OnClick",function()
        local svc=Service(); if svc==nil then return end
        if type(svc.ClearTemp)=="function" then svc:ClearTemp() end
        W:SetMode("manual")
    end,"auction_favorites:temp_clear")

    S.UI:SafeHandler(prev,"OnClick",function()
        if W.scrollOffset>0 then W.scrollOffset=math.max(0,W.scrollOffset-ROWS); W:RefreshList(false) end
    end,"auction_favorites:prev")
    S.UI:SafeHandler(nextBtn,"OnClick",function()
        local svc=Service(); local items=svc and svc:GetViewItems(W:ResolveInitialMode()) or {}
        local maxOffset=math.max(0,#items-ROWS)
        if W.scrollOffset<maxOffset then W.scrollOffset=math.min(maxOffset,W.scrollOffset+ROWS); W:RefreshList(false) end
    end,"auction_favorites:next")
    S.UI:SafeHandler(panel,"OnWheelUp",function()
        if W.scrollOffset>0 then W.scrollOffset=W.scrollOffset-1; W:RefreshList(false) end
    end,"auction_favorites:wheel_up")
    S.UI:SafeHandler(panel,"OnWheelDown",function()
        local svc=Service(); local items=svc and svc:GetViewItems(W:ResolveInitialMode()) or {}
        local maxOffset=math.max(0,#items-ROWS)
        if W.scrollOffset<maxOffset then W.scrollOffset=W.scrollOffset+1; W:RefreshList(false) end
    end,"auction_favorites:wheel_down")

    self.window=panel
    panel:Show(false)
    self:RefreshList(true)
    return panel
end

function W:RefreshList(clampToEnd)
    local panel=self:Create()
    if panel==nil then return end
    local svc=Service()
    local mode=self:ResolveInitialMode()
    local items=svc and type(svc.GetViewItems)=="function" and svc:GetViewItems(mode) or {}
    local maxOffset=math.max(0,#items-ROWS)
    if clampToEnd==true and self.scrollOffset>maxOffset then self.scrollOffset=maxOffset end
    self.scrollOffset=math.max(0,math.min(self.scrollOffset,maxOffset))

    for i=1,ROWS do
        local row=self.rows[i]
        local index=self.scrollOffset+i
        local entry=items[index]
        if row and type(entry)=="table" then
            row.index=index
            row.item:SetText(tostring(entry.displayText or entry.searchText or ""))
            SetButtonExtent(row.item,mode=="today" and 266 or 238,24)
            row.item:Show(true)
            row.del:Show(mode=="manual")
            -- Temp rows (F1) search by official CN name on click; manual rows
            -- keep the delete button; today rows search too (no delete).
            S.UI:SafeHandler(row.item,"OnClick",function()
                local current=Service(); if current==nil then return end
                local liveItems=current:GetViewItems(W:ResolveInitialMode())
                local live=liveItems[index]
                if type(live)~="table" then return end
                local keyword=tostring(live.searchText or "")
                SetText(W.input,keyword)
                local ok,err=current:Search(keyword)
                if ok~=true and err~=nil then S.SafeChat("拍卖搜索失败："..tostring(err)) end
            end,"auction_favorites:item_"..tostring(i))
            S.UI:SafeHandler(row.del,"OnClick",function()
                if W:ResolveInitialMode()~="manual" then return end
                local current=Service(); if current==nil then return end
                local liveItems=current:GetViewItems("manual")
                local live=liveItems[index]
                local manualIndex=type(live)=="table" and tonumber(live.manualIndex) or nil
                if manualIndex==nil then return end
                local ok,err=current:RemoveFavorite(manualIndex)
                if ok~=true and err~=nil then S.SafeChat(tostring(err)) end
            end,"auction_favorites:delete_"..tostring(i))
        elseif row then
            row.index=nil
            row.item:SetText("")
            SetButtonExtent(row.item,238,24)
            row.item:Show(false); row.del:Show(false)
        end
    end

    local first=#items>0 and (self.scrollOffset+1) or 0
    local last=math.min(#items,self.scrollOffset+ROWS)
    if self.pageLabel~=nil then
        if #items==0 then
            local emptyText = mode=="today" and "今天没有识别到做货日常"
                or mode=="temp" and "临时搜索区为空" or "暂无收藏"
            self.pageLabel:SetText(emptyText)
        else
            self.pageLabel:SetText(tostring(first).."-"..tostring(last).." / "..tostring(#items))
        end
    end
    self:RefreshTabs()
end

function W:OnTodayItemsChanged(previousCount,nextCount)
    previousCount=math.max(0,tonumber(previousCount) or 0)
    nextCount=math.max(0,tonumber(nextCount) or 0)
    -- If the window has never chosen a mode yet, let the newly-derived Daily
    -- list become the natural default. Never yank a user away from a tab they
    -- already selected while the Auction House is open.
    if self.mode==nil and previousCount==0 and nextCount>0 then self.mode="today" end
    if self.window~=nil then self:RefreshList(true) end
end

function W:ApplyAuctionAnchor(rect)
    local panel=self:Create(); if panel==nil then return end
    if panel.RemoveAllAnchors~=nil then panel:RemoveAllAnchors() end
    local context=S.Layout and S.Layout:GetContext() or {}
    local logicalW=tonumber(context.logicalWidth) or 1024
    local logicalH=tonumber(context.logicalHeight) or 768
    local edge=math.max(6,tonumber(context.safeTop) or 10)
    local x,y
    if type(rect)=="table" then
        x=(tonumber(rect.x) or 0)-PANEL_W-6
        y=tonumber(rect.y) or edge
        -- Preserve the requested left-side attachment. Only if the screen has no
        -- left room at all do we clamp to the safe edge rather than covering the
        -- Auction House itself with an arbitrary right-side fallback.
        if S.Layout and type(S.Layout.ClampTopLeft)=="function" then
            x,y=S.Layout:ClampTopLeft(x,y,PANEL_W,PANEL_H,{edge=edge})
        else
            x=math.max(edge,math.min(x,math.max(edge,logicalW-edge-PANEL_W)))
            y=math.max(edge,math.min(y,math.max(edge,logicalH-edge-PANEL_H)))
        end
    else
        x=edge
        y=math.max(edge,math.floor((logicalH-PANEL_H)/2))
    end
    panel:AddAnchor("TOPLEFT","UIParent",math.floor(x+0.5),math.floor(y+0.5))
end

function W:Show(visible)
    local panel=self:Create(); if panel==nil then return end
    panel:Show(visible==true)
    if visible==true and panel.Raise~=nil then pcall(function() panel:Raise() end) end
end

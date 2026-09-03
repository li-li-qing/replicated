------------------------------------------------------------------------
-- Replicated Suite - Auction Favorites service
-- Author: Replicated
--
-- Native Auction House remains Authority. This service only observes its
-- visibility/geometry, persists an ordered favorite-keyword list, and routes
-- user clicks through Services.Auction's shared SearchAuctionArticle Authority.
-- No hotkey is rebound and no standalone OnUpdate owner is created.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S=ReplicatedSuite; S.Services=S.Services or {}; S.Services.AuctionFavorites={}
local F=S.Services.AuctionFavorites

local TASK_WATCH="auction_favorites_watch"
local MAX_FAVORITES=200
local WATCH_MS=200

F.started=false
F.sessionDismissed=false
F.auctionSignalOpen=false
F.lastAuctionVisible=false
F.lastRect=nil
F.lastSource="none"
F.todayItems={}
-- Temp search queue (F1). Session-local ONLY: never persisted, cleared on
-- reload. Entries are official localized display names (CN) which are both the
-- row text and the auction search keyword. EN names never appear here.
F.tempItems={}

local function Trim(value)
    value=tostring(value or ""):gsub("[\r\n]", " ")
    return value:match("^%s*(.-)%s*$") or ""
end

local function CapabilityAllowed(name)
    return S.Api~=nil and type(S.Api.IsCapabilityAllowed)=="function"
        and S.Api:IsCapabilityAllowed(name)==true
end

local function ReadWidgetVisible(widget)
    if widget==nil or type(widget.IsVisible)~="function" then return false,nil end
    local ok,value=pcall(function() return widget:IsVisible() end)
    if not ok then return false,nil end
    return true,value==true
end

local function ReadContentChainVisible(content)
    local node=content
    local anyKnown=false
    for _=0,8 do
        if node==nil then break end
        local known,visible=ReadWidgetVisible(node)
        if known then
            anyKnown=true
            if visible then return true,true end
        end
        if type(node.GetParent)~="function" then break end
        local ok,parent=pcall(function() return node:GetParent() end)
        if not ok or parent==nil or parent==node then break end
        node=parent
    end
    return anyKnown,false
end

function F:GetItems()
    S.State.life.auctionFavorites=type(S.State.life.auctionFavorites)=="table"
        and S.State.life.auctionFavorites or {items={}}
    local data=S.State.life.auctionFavorites
    data.items=type(data.items)=="table" and data.items or {}
    return data.items
end

function F:NormalizeItems()
    local source=self:GetItems()
    local items,seen={},{}
    for _,value in ipairs(source) do
        local text=Trim(type(value)=="table" and (value.text or value.name) or value)
        local key=string.lower(text)
        if text~="" and not seen[key] then
            seen[key]=true
            items[#items+1]=text
            if #items>=MAX_FAVORITES then break end
        end
    end
    S.State.life.auctionFavorites.items=items
    return items
end

local function SameTodayItems(left,right)
    if type(left)~="table" or type(right)~="table" or #left~=#right then return false end
    for index=1,#left do
        local a,b=left[index],right[index]
        if type(a)~="table" or type(b)~="table"
            or tonumber(a.questId)~=tonumber(b.questId)
            or tostring(a.recipeName or "")~=tostring(b.recipeName or "")
            or tostring(a.searchText or "")~=tostring(b.searchText or "")
            or tostring(a.displayText or "")~=tostring(b.displayText or "")
            or tonumber(a.count or 0)~=tonumber(b.count or 0) then
            return false
        end
    end
    return true
end

-- ArcheRage also exposes rotating "Today" specialty-crafting quests such as:
--   [特产-东部] 翡翠谷的保存特制特产
-- These are independent of the resident Trade Outlet quest family (8559..8593),
-- so a fixed quest-id table cannot cover them truthfully. Resolve the requested
-- production zone from the ACTIVE quest title and let TradeMaterials remain the
-- recipe/material Authority. This scan runs only on quest refresh/startup, never
-- from the 200 ms Auction House visibility watcher.
local DAILY_SPECIALTY_ZONE_FALLBACK = {
    -- Verified current RU-CN localization. Other regions resolve from the
    -- server-provided production-zone list through Trade:FindZoneByText.
    ["翡翠谷"]=23,
}

local function ResolveDailySpecialtyRecipe(title,materials)
    title=Trim(title)
    if title=="" or materials==nil or type(materials.ResolveRecipeName)~="function" then return nil end
    local east=string.find(title,"[特产-东部]",1,true)~=nil
    local west=string.find(title,"[特产-西部]",1,true)~=nil
    if not east and not west then return nil end

    local body=string.match(title,"%]%s*(.+)$")
    local zoneText,packTail=nil,nil
    if body~=nil then zoneText,packTail=string.match(body,"^(.-)的(.+)$") end
    if zoneText==nil or packTail==nil or string.find(packTail,"特产",1,true)==nil then return nil end
    zoneText=Trim(zoneText); packTail=Trim(packTail)
    if zoneText=="" or packTail=="" then return nil end

    local zoneId=nil
    local trade=S.Services and S.Services.Trade or nil
    if trade~=nil and type(trade.FindZoneByText)=="function" then
        local ok,value=pcall(function() return trade:FindZoneByText(zoneText) end)
        if ok then zoneId=tonumber(value) end
    end
    zoneId=zoneId or DAILY_SPECIALTY_ZONE_FALLBACK[zoneText]
    if zoneId==nil then return nil end

    -- ResolveRecipeName needs the zone id for canonical English recipe identity;
    -- the localized pack text is presentation input only and never auction identity.
    local localizedPack="["..zoneText.."]"..packTail
    return materials:ResolveRecipeName(localizedPack,zoneId)
end

local function AppendRecipeMaterials(target,questId,recipeName,alternativeCount,materials)
    if type(target)~="table" or materials==nil or type(materials.GetMaterialsForPack)~="function" then return false end
    local recipeRows,resolved=materials:GetMaterialsForPack(recipeName,nil)
    local canonical=tostring(resolved or recipeName or "")
    if canonical=="" or type(recipeRows)~="table" or #recipeRows==0 then return false end
    local zoneLabel=type(materials.GetRecipeZoneLabel)=="function"
        and materials:GetRecipeZoneLabel(canonical) or canonical
    local appended=false
    for _,material in ipairs(recipeRows) do
        local searchText=Trim(material.displayName or material.name)
        if searchText~="" and material.auctionable~=false and material.includeInCost~=false then
            local count=math.max(0,tonumber(material.count) or 0)
            local countText=tostring(math.floor(count+0.5))
            target[#target+1]={
                questId=tonumber(questId),
                recipeName=canonical,
                packLabel=tostring(zoneLabel or canonical),
                alternativeCount=math.max(1,tonumber(alternativeCount) or 1),
                materialName=tostring(material.name or ""),
                searchText=searchText,
                count=count,
                displayText=tostring(zoneLabel or canonical).." · "..searchText.." ×"..countText,
            }
            appended=true
        end
    end
    return appended
end

function F:GetTodayItems()
    self.todayItems=type(self.todayItems)=="table" and self.todayItems or {}
    return self.todayItems
end

function F:GetViewItems(mode)
    if tostring(mode) == "today" then return self:GetTodayItems() end
    if tostring(mode) == "temp" then return self:GetTempViewItems() end
    local rows={}
    for index,text in ipairs(self:NormalizeItems()) do
        rows[#rows+1]={
            displayText=tostring(text), searchText=tostring(text), manualIndex=index,
        }
    end
    return rows
end

function F:RefreshTodayQuestItems(activeIndex)
    local quest=S.Services and S.Services.Quest or nil
    local materials=S.Services and S.Services.TradeMaterials or nil
    local definitions=S.Data and S.Data.DailyTradePackQuestRecipes or nil
    if quest==nil or materials==nil or type(definitions)~="table"
        or type(quest.QuestState)~="function" or type(materials.GetMaterialsForPack)~="function" then
        return self:GetTodayItems()
    end

    if type(activeIndex)~="table" then
        activeIndex=type(quest.BuildActiveIndex)=="function" and quest:BuildActiveIndex() or {}
    end

    local inProgress=S.Constants and S.Constants.QuestStatus and S.Constants.QuestStatus.IN_PROGRESS or "in_progress"
    local nextItems={}
    local handledQuestIds={}

    -- Fixed resident Trade Outlet quests: one quest may offer several alternative
    -- local specialties. Keep those alternatives separate exactly as before.
    for _,definition in ipairs(definitions) do
        local questId=tonumber(type(definition)=="table" and definition.questId or nil)
        if questId~=nil and activeIndex[questId]~=nil and quest:QuestState(questId,activeIndex)==inProgress then
            local recipes=type(definition.recipes)=="table" and definition.recipes or {}
            local alternativeCount=#recipes
            for _,recipeName in ipairs(recipes) do
                AppendRecipeMaterials(nextItems,questId,recipeName,alternativeCount,materials)
            end
            handledQuestIds[questId]=true
        end
    end

    -- Rotating ArcheMaster "Today" crafting quests are identified from their
    -- authoritative active quest title. Sort ids first so derived UI order stays
    -- deterministic and does not dirty/rebuild the list because of pairs() order.
    local activeQuestIds={}
    for questId in pairs(activeIndex) do
        questId=tonumber(questId)
        if questId~=nil and handledQuestIds[questId]~=true then activeQuestIds[#activeQuestIds+1]=questId end
    end
    table.sort(activeQuestIds)
    for _,questId in ipairs(activeQuestIds) do
        local title=type(quest.QuestTitle)=="function" and quest:QuestTitle(questId,"") or ""
        local recipeName=ResolveDailySpecialtyRecipe(title,materials)
        if recipeName~=nil and quest:QuestState(questId,activeIndex)==inProgress then
            AppendRecipeMaterials(nextItems,questId,recipeName,1,materials)
        end
    end

    local previous=self:GetTodayItems()
    if SameTodayItems(previous,nextItems) then return previous end
    self.todayItems=nextItems
    local ui=S.AuctionFavoritesWindow
    if ui~=nil and type(ui.OnTodayItemsChanged)=="function" then
        ui:OnTodayItemsChanged(#previous,#nextItems)
    elseif ui~=nil and type(ui.RefreshList)=="function" then
        ui:RefreshList(true)
    end
    return nextItems
end

function F:RequestSave()
    if S.Storage~=nil and type(S.Storage.RequestSave)=="function" then S.Storage:RequestSave(100) end
end

function F:AddFavorite(value)
    local text=Trim(value)
    if text=="" then return false,"请输入要收藏的物品名称" end
    local items=self:NormalizeItems()
    local key=string.lower(text)
    for _,item in ipairs(items) do
        if string.lower(Trim(item))==key then return false,"该物品已经收藏" end
    end
    if #items>=MAX_FAVORITES then return false,"收藏数量已达到上限" end
    items[#items+1]=text
    self:RequestSave()
    if S.AuctionFavoritesWindow and type(S.AuctionFavoritesWindow.RefreshList)=="function" then
        S.AuctionFavoritesWindow:RefreshList(true)
    end
    return true,text
end

function F:RemoveFavorite(index)
    index=math.floor(tonumber(index) or 0)
    local items=self:NormalizeItems()
    if index<1 or index>#items then return false,"收藏项不存在" end
    local removed=table.remove(items,index)
    self:RequestSave()
    if S.AuctionFavoritesWindow and type(S.AuctionFavoritesWindow.RefreshList)=="function" then
        S.AuctionFavoritesWindow:RefreshList(true)
    end
    return true,removed
end

-- ---------------------------------------------------------------------
-- F1: temp search queue + official-name resolution
-- ---------------------------------------------------------------------
-- Official localized (CN) display-name resolution. HARD RULE: no machine
-- translation, no invented names. Resolution chain:
--   1. runtime first — scan bag/storage once per itemType and take the client
--      GetBagItemInfo().name (the client returns the official localized name;
--      this is the authoritative source);
--   2. fallback — TradeMaterials:DisplayResourceName(name) shared static ID
--      table (also official-named static backup), then the caller-provided
--      display fallback (mat.displayName, already official).
-- The EN name is identity only and NEVER surfaces in any UI or search term.
function F:ResolveOfficialName(itemType, fallbackDisplay)
    local numeric = tonumber(itemType)
    if numeric ~= nil then
        -- Session cache (2026-08-24): runtime bag/bank/coffer scans are heavy;
        -- the craft-assist window calls this per material row on every refresh.
        -- Cache the resolved name per itemType for this generation.
        if F.officialNameCache == nil then F.officialNameCache = {} end
        local cached = F.officialNameCache[numeric]
        if cached ~= nil then return cached end
        -- Static verified data is the primary Chinese authority. It is loaded
        -- with the addon, needs no runtime Wiki request, and avoids scanning
        -- every bag-like container merely to resolve a row label.
        if S.Localization ~= nil and type(S.Localization.GetName) == "function" then
            local static, verified = S.Localization:GetName("item", numeric, nil)
            if verified == true and static ~= nil and tostring(static) ~= "" then
                F.officialNameCache[numeric] = static
                return static
            end
        end
        -- Runtime-first scan of bag + bank + coffer, matching by itemType.
        local sources = { "ScanBag", "ScanBank", "ScanCoffer" }
        local organizer = S.Services and S.Services.BagOrganizer
        if organizer ~= nil then
            for _, method in ipairs(sources) do
                if type(organizer[method]) == "function" then
                    local ok, scan = xpcall(function() return organizer[method](organizer) end, S.SafeTraceback)
                    if ok and type(scan) == "table" then
                        for _, entry in ipairs(scan.items or {}) do
                            if tonumber(entry.itemType) == numeric
                                and type(entry.name) == "string" and entry.name ~= "" then
                                F.officialNameCache[numeric] = entry.name
                                return entry.name
                            end
                        end
                    end
                end
            end
        end
    end
    -- Static fallback: EN identity -> official ZH table, then caller display.
    local materials = S.Services and S.Services.TradeMaterials
    if materials ~= nil and type(materials.DisplayResourceName) == "function" then
        local zh = materials:DisplayResourceName(fallbackDisplay)
        if zh ~= nil and tostring(zh) ~= "" then return zh end
    end
    local display = tostring(fallbackDisplay or "")
    return display ~= "" and display or ("物品ID " .. tostring(numeric or ""))
end

-- Add one material to the temp search queue (session-only). Display name is
-- the official localized name; it is both the row text and the search keyword.
function F:PushTemp(displayName)
    local text = Trim(displayName)
    if text == "" then return false, "缺少官方名称" end
    local key = string.lower(text)
    for _, item in ipairs(self.tempItems) do
        if string.lower(Trim(item)) == key then return true, text end -- de-dup, re-show
    end
    if #self.tempItems >= MAX_FAVORITES then return false, "临时搜索队列已满" end
    self.tempItems[#self.tempItems + 1] = text
    if S.AuctionFavoritesWindow and type(S.AuctionFavoritesWindow.RefreshList) == "function" then
        S.AuctionFavoritesWindow:RefreshList(true)
    end
    return true, text
end

function F:ClearTemp()
    self.tempItems = {}
    if S.AuctionFavoritesWindow and type(S.AuctionFavoritesWindow.RefreshList) == "function" then
        S.AuctionFavoritesWindow:RefreshList(true)
    end
    return true
end

function F:GetTempItems()
    self.tempItems = type(self.tempItems) == "table" and self.tempItems or {}
    return self.tempItems
end

-- Temp rows for the window (displayText + searchText both = official CN name).
function F:GetTempViewItems()
    local rows = {}
    for index, text in ipairs(self:GetTempItems()) do
        rows[#rows + 1] = {
            displayText = tostring(text),
            searchText = tostring(text),
            tempIndex = index,
        }
    end
    return rows
end

function F:Search(value)
    local text=Trim(value)
    if text=="" then return false,"搜索内容不能为空" end
    local auction=S.Services and S.Services.Auction or nil
    if auction==nil or type(auction.SearchInteractive)~="function" then
        return false,"拍卖搜索服务尚未就绪"
    end
    return auction:SearchInteractive(text)
end

function F:GetAuctionContent()
    if UIC_AUCTION==nil or ADDON==nil or not CapabilityAllowed("ADDON:GetContent") then return nil end
    local ok,value=S.Api:CallCapability("ADDON:GetContent",ADDON,"GetContent",UIC_AUCTION)
    if ok and value~=nil then return value end
    return nil
end

function F:ReadMainScriptState()
    if UIC_AUCTION==nil or ADDON==nil or not CapabilityAllowed("ADDON:GetContentMainScriptPosVis")
        or type(ADDON.GetContentMainScriptPosVis)~="function" then return false,nil end
    -- Five-value native getter: bypass generic CallCapability because it carries
    -- only four native return values. Numeric geometry also counts as visible on
    -- RU builds that omit the final boolean for UIC_AUCTION.
    local ok,x,y,width,height,visible=pcall(function()
        return ADDON:GetContentMainScriptPosVis(UIC_AUCTION)
    end)
    if not ok then return false,nil end
    x,y,width,height=tonumber(x),tonumber(y),tonumber(width),tonumber(height)
    local hasRect=x~=nil and y~=nil and width~=nil and height~=nil and width>0 and height>0
    local hasSignal=visible~=nil or x~=nil or y~=nil or width~=nil or height~=nil
    if not hasSignal then return false,nil end
    local isVisible=visible==true or (visible==nil and hasRect)
    return true,{x=x,y=y,width=width,height=height,visible=isVisible}
end

local function PlausibleRect(x,y,width,height,logicalW,logicalH)
    x,y,width,height=tonumber(x),tonumber(y),tonumber(width),tonumber(height)
    if x==nil or y==nil or width==nil or height==nil or width<120 or height<120 then return false end
    if width>(logicalW*0.98) or height>(logicalH*0.98) then return false end
    if x>(logicalW+64) or y>(logicalH+64) or x+width<(-64) or y+height<(-64) then return false end
    return true
end

function F:ResolveAuctionRect(content,state)
    local context=S.Layout and S.Layout:GetContext() or {}
    local logicalW=tonumber(context.logicalWidth) or 1024
    local logicalH=tonumber(context.logicalHeight) or 768
    if type(state)=="table" and PlausibleRect(state.x,state.y,state.width,state.height,logicalW,logicalH) then
        self.lastSource="main-script"
        return {x=state.x,y=state.y,width=state.width,height=state.height}
    end

    -- GetContent may point at a child proxy. Walk a short parent chain and use
    -- the nearest plausible native window rectangle, matching the proven bag
    -- organizer overlay strategy already used by Suite.
    local node=content
    for depth=0,8 do
        if node==nil then break end
        if S.Layout~=nil and type(S.Layout.GetLogicalRect)=="function" then
            local ok,x,y,width,height=pcall(function() return S.Layout:GetLogicalRect(node) end)
            if ok and PlausibleRect(x,y,width,height,logicalW,logicalH) then
                self.lastSource=depth==0 and "auction-widget" or ("auction-parent-"..tostring(depth))
                return {x=tonumber(x),y=tonumber(y),width=tonumber(width),height=tonumber(height)}
            end
        end
        if type(node.GetParent)~="function" then break end
        local ok,parent=pcall(function() return node:GetParent() end)
        if not ok or parent==nil or parent==node then break end
        node=parent
    end
    self.lastSource="unresolved"
    return nil
end

function F:ReadAuctionVisibility()
    local content=self:GetAuctionContent()
    local contentKnown,contentVisible=ReadContentChainVisible(content)
    if contentVisible==true then
        local _,state=self:ReadMainScriptState()
        return true,true,content,state
    end

    local stateKnown,state=self:ReadMainScriptState()
    if stateKnown then
        if type(state)=="table" and state.visible==true then return true,true,content,state end
        return true,false,content,state
    end

    -- Some RU UIC_AUCTION proxies do not publish MainScript geometry. In that
    -- case parent-chain visibility is the next-best native signal; auction
    -- events remain a final compatibility open latch, never a hotkey hook.
    if self.auctionSignalOpen==true then return false,true,content,state end
    if contentKnown then return true,false,content,state end
    return false,false,content,state
end

function F:ShowForAuction(content,state,refreshList)
    if self.sessionDismissed==true then return end
    local ui=S.AuctionFavoritesWindow
    if ui==nil or type(ui.Create)~="function" then return end
    ui:Create()
    local rect=self:ResolveAuctionRect(content,state)
    self.lastRect=rect
    if type(ui.ApplyAuctionAnchor)=="function" then ui:ApplyAuctionAnchor(rect) end
    if refreshList==true and type(ui.RefreshList)=="function" then ui:RefreshList(false) end
    if type(ui.Show)=="function" then ui:Show(true) end
end

function F:HideForAuction()
    local ui=S.AuctionFavoritesWindow
    if ui and type(ui.Show)=="function" then ui:Show(false) end
end

function F:DismissForSession()
    self.sessionDismissed=true
    self:HideForAuction()
end

function F:WatchAuction()
    if self.started~=true then return end
    local known,visible,content,state=self:ReadAuctionVisibility()
    if visible==true then
        local opening=self.lastAuctionVisible~=true
        if opening then self.sessionDismissed=false end
        self.lastAuctionVisible=true
        self.auctionSignalOpen=true
        self:ShowForAuction(content,state,opening)
        return
    end

    if known==true then
        if self.lastAuctionVisible==true then self.sessionDismissed=false end
        self.lastAuctionVisible=false
        self.auctionSignalOpen=false
        self.lastRect=nil
        self:HideForAuction()
    elseif self.auctionSignalOpen==true and self.sessionDismissed~=true then
        -- Event-only compatibility path for builds where both native content
        -- visibility getters are absent. Never hotkey-hook merely to obtain this.
        self:ShowForAuction(content,state,false)
    end
end

function F:OnAuctionSignal()
    if self.started~=true then return end
    self.auctionSignalOpen=true
    self:WatchAuction()
end

function F:OnInteractionEnd()
    if self.started~=true then return end
    -- Do not blindly close on interaction end: remote Auction House access may
    -- remain visible. The next visibility read remains Authority.
    self:WatchAuction()
end

function F:Start()
    if self.started==true then return true end
    self.started=true
    self.sessionDismissed=false
    self.auctionSignalOpen=false
    self.lastAuctionVisible=false
    self:NormalizeItems()
    self:RefreshTodayQuestItems()
    if S.AuctionFavoritesWindow and type(S.AuctionFavoritesWindow.Create)=="function" then
        S.AuctionFavoritesWindow:Create()
        S.AuctionFavoritesWindow:Show(false)
    end

    if S.Events~=nil then
        if type(S.Events.UnsubscribeOwner)=="function" then S.Events:UnsubscribeOwner(self) end
        for _,eventName in ipairs({"AUCTION_ITEM_SEARCH","AUCTION_ITEM_SEARCHED","AUCTION_ITEM_ATTACHMENT_STATE_CHANGED"}) do
            S.Events:Subscribe(eventName,self,function() F:OnAuctionSignal() end)
        end
        for _,eventName in ipairs({"NPC_INTERACTION_END","INTERACTION_END"}) do
            S.Events:Subscribe(eventName,self,function() F:OnInteractionEnd() end)
        end
        S.Events:Subscribe("ENTERED_WORLD",self,function()
            F.sessionDismissed=false
            F.auctionSignalOpen=false
            F.lastAuctionVisible=false
            F:HideForAuction()
        end)
    end

    if S.Scheduler~=nil then
        S.Scheduler:RemoveTask(TASK_WATCH)
        -- Lightweight native visibility/geometry observation only. No inventory
        -- scan, tag matching, file IO, or server query occurs on this schedule.
        S.Scheduler:AddTask(TASK_WATCH,WATCH_MS,function() F:WatchAuction() end,false,self,"P2")
    end
    self:WatchAuction()
    return true
end

function F:Stop()
    if S.Scheduler~=nil then S.Scheduler:RemoveTask(TASK_WATCH) end
    if S.Events~=nil and type(S.Events.UnsubscribeOwner)=="function" then S.Events:UnsubscribeOwner(self) end
    self.started=false
    self.sessionDismissed=false
    self.auctionSignalOpen=false
    self.lastAuctionVisible=false
    self.lastRect=nil
    self:HideForAuction()
    return true
end

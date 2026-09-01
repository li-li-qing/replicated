------------------------------------------------------------------------
-- Replicated Suite - Trade auction reference-price service
-- Author: Replicated
--
-- Stable material identity is itemType (+ itemGrade hint). The current RU
-- whitelist exposes X2Auction:GetLowestPrice(itemType, itemGrade), so explicit
-- user price queries use that stable-ID path first. The historical “货率 2.5”
-- keyword search remains a compatibility fallback only when the direct getter
-- cannot resolve a price on the current client/data row.
--
-- Direct lookups are serialized at a 600 ms safety interval (official cooldown
-- is 500 ms). SearchAuctionArticle fallback keeps the existing 1.6 s fence and
-- AUCTION_ITEM_SEARCHED completion path. No auction API is called per-frame;
-- the scheduler advances at most one explicit price operation per step.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S=ReplicatedSuite; S.Services=S.Services or {}; S.Services.Auction={}
local A=S.Services.Auction
A.presentationBoundary = "service_only"
A.presentationDebt = nil

A.queue={}
A.current=nil
A.nextSendAt=0
A.token=0
A.cache={}
A.cacheTtlMs=120000
A.directCooldownMs=600
A.searchCooldownMs=(S.Constants.Refresh.auctionCooldownMs or 1600)
A.searchTimeoutMs=6500
A.staleSearchFenceUntil=0
-- Interactive Auction House searches (favorites/manual Suite UI) share the same
-- server-query Authority as trade-price fallback searches. AUCTION_ITEM_SEARCHED
-- has no request token, so an interactive request owns the event stream until its
-- first completion (or bounded timeout) before any quote fallback search may run.
A.interactivePending=nil
A.interactiveAwaiting=nil

local function ToNumber(value)
    if type(value)=="number" then return value end
    if type(value)=="string" then
        local cleaned=value:gsub(",",""):gsub("%s","")
        return tonumber(cleaned)
    end
    if type(value)=="table" then
        local gold=tonumber(value.gold or value.g)
        local silver=tonumber(value.silver or value.s)
        local copper=tonumber(value.copper or value.c)
        if gold~=nil or silver~=nil or copper~=nil then
            return math.floor((gold or 0)*10000+(silver or 0)*100+(copper or 0))
        end
        for _,key in ipairs({
            "value","amount","price","money","lowestPrice","lowest_price",
            "directPrice","directPriceStr","bidPrice","bidPriceStr","buyoutPrice","buyoutPriceStr",
        }) do
            local n=ToNumber(value[key]); if n~=nil then return n end
        end
    end
    return nil
end

local function ExtractPrice(...)
    local count=select("#",...)
    for index=1,count do
        local n=ToNumber(select(index,...))
        if n~=nil and n>0 then return math.floor(n) end
    end
    return nil
end

local function NonEmpty(value)
    value=tostring(value or "")
    if value=="" then return nil end
    return value
end

local Trim = S.Reuse.Text.SingleLine

local function AddUnique(list,seen,value)
    value=NonEmpty(value)
    if value==nil or seen[value] then return end
    seen[value]=true
    list[#list+1]=value
end

local function AddUniqueGrade(list,seen,value)
    value=tonumber(value)
    if value==nil or value~=value then return end
    value=math.floor(value)
    if value<0 or value>20 or seen[value] then return end
    seen[value]=true
    list[#list+1]=value
end

-- Keyword fallback is intentionally localized-name first to preserve the old
-- working route, but it is no longer the primary auction identity.
local function BuildQueryNames(material)
    local list,seen={},{}
    AddUnique(list,seen,material and material.displayName)
    AddUnique(list,seen,material and material.name)
    return list
end

-- Trade metadata carries explicit itemGrade for known processed materials and a
-- compact gradeOffset hint for the rest. Prefer the one-based interpretation
-- used by the explicit grade=1 entries, then tolerate the raw offset and a small
-- bounded grade set. Every retry keeps the SAME itemType Authority.
local function BuildGradeCandidates(material)
    local list,seen={},{}
    local explicit=tonumber(material and material.itemGrade)
    local offset=tonumber(material and material.itemGradeOffset)
    AddUniqueGrade(list,seen,explicit)
    if explicit==nil and offset~=nil then
        AddUniqueGrade(list,seen,offset+1)
        AddUniqueGrade(list,seen,offset)
    end
    for grade=1,6 do AddUniqueGrade(list,seen,grade) end
    AddUniqueGrade(list,seen,0)
    return list
end

local function PreferredGrade(material)
    local explicit=tonumber(material and material.itemGrade)
    if explicit~=nil then return math.floor(explicit) end
    local offset=tonumber(material and material.itemGradeOffset)
    if offset~=nil then return math.floor(offset)+1 end
    return nil
end

local function CacheKey(material)
    local itemType=tonumber(material and material.itemType)
    if itemType~=nil and itemType>0 then
        local grade=PreferredGrade(material)
        return "id:"..tostring(math.floor(itemType))..(grade~=nil and (":g:"..tostring(grade)) or "")
    end
    local name=NonEmpty(material and material.name)
    return name and ("name:"..name) or nil
end

function A:GetCached(material)
    local key=CacheKey(material); if key==nil then return nil end
    local item=self.cache[key]
    if type(item)~="table" then return nil end
    if S.NowMs()-(tonumber(item.at) or 0)>self.cacheTtlMs then
        self.cache[key]=nil
        return nil
    end
    return tonumber(item.price)
end

function A:StoreCached(request,price)
    local key=request and request.cacheKey
    price=tonumber(price)
    if key==nil or price==nil or price<=0 then return end
    self.cache[key]={price=math.floor(price),at=S.NowMs()}
end

function A:Publish(status,text)
    S.State.data.auction=S.State.data.auction or {}
    S.State.data.auction.status=status or "idle"
    S.State.data.auction.text=text
    S.State.data.auction.pending=#self.queue+(self.current and 1 or 0)
    S.State:MarkDirty("trade")
end

function A:FinishRequest(request,price)
    if request==nil or request.finished==true then return end
    request.finished=true
    price=tonumber(price)
    if price~=nil and price>0 then self:StoreCached(request,price) end

    local quote=request.quote
    if type(quote)=="table" and quote.token==self.token then
        quote.prices[request.name]=(price~=nil and price>0) and math.floor(price) or nil
        if price==nil or price<=0 then
            quote.failures=quote.failures or {}
            quote.failures[#quote.failures+1]={
                name=tostring(request.displayName or request.name or ""),
                path=tostring(request.lastPath or "stable-id+search-fallback"),
                error=tostring(request.lastError or "拍卖接口未返回参考价"),
            }
        end
        quote.remaining=math.max(0,(tonumber(quote.remaining) or 1)-1)
        if quote.remaining<=0 then
            self:Publish("ready","材料拍卖参考价查询完成")
            local trade=S.Services and S.Services.Trade
            if trade and type(trade.OnMaterialQuote)=="function" then trade:OnMaterialQuote(quote) end
        end
    end
end

local function CurrentQuery(request)
    if type(request)~="table" or type(request.queryNames)~="table" then return nil end
    return request.queryNames[tonumber(request.queryIndex) or 1]
end

local function CurrentGrade(request)
    if type(request)~="table" or type(request.gradeCandidates)~="table" then return nil end
    return request.gradeCandidates[tonumber(request.gradeIndex) or 1]
end

function A:FallbackToSearch(request,reason)
    if request==nil or request.finished==true then return false end
    request.lastError=tostring(reason or request.lastError or "稳定ID查询无结果")
    if request.searchEnabled==true and #(request.queryNames or {})>0 then
        request.mode="search"
        request.queryIndex=1
        request.activeQuery=nil
        request.requestedAt=0
        request.lastPath="stable-id->folio105-search-first-row"
        table.insert(self.queue,1,request)
        return true
    end
    request.lastPath=request.lastPath or "stable-id"
    self:FinishRequest(request,nil)
    return false
end

function A:RetryNextGrade(request,reason)
    if request==nil or request.finished==true then return false end
    request.lastError=tostring(reason or request.lastError or "当前品级没有拍卖参考价")
    request.gradeIndex=(tonumber(request.gradeIndex) or 1)+1
    if request.gradeIndex<=#(request.gradeCandidates or {}) then
        request.mode="direct"
        table.insert(self.queue,1,request)
        return true
    end
    return self:FallbackToSearch(request,request.lastError)
end

function A:RetryNextQuery(request,reason)
    if request==nil or request.finished==true then return false end
    request.lastError=tostring(reason or request.lastError or "拍卖搜索无结果")
    request.queryIndex=(tonumber(request.queryIndex) or 1)+1
    if request.queryIndex<=#(request.queryNames or {}) then
        request.requestedAt=0
        request.activeQuery=nil
        table.insert(self.queue,1,request)
        return true
    end
    request.lastPath=request.lastPath or "folio105-search-first-row"
    self:FinishRequest(request,nil)
    return false
end

function A:QueueOne(quote,material,directReady,searchReady)
    if material.auctionable==false then return end
    local cached=self:GetCached(material)
    if cached~=nil then
        quote.prices[material.name]=cached
        quote.remaining=math.max(0,(tonumber(quote.remaining) or 1)-1)
        return
    end

    local itemType=tonumber(material.itemType)
    itemType=(itemType and itemType>0) and math.floor(itemType) or nil
    local queryNames=BuildQueryNames(material)
    local directEnabled=directReady==true and itemType~=nil
    local searchEnabled=searchReady==true and #queryNames>0
    if not directEnabled and not searchEnabled then
        local placeholder={
            token=quote.token, quote=quote, name=material.name, displayName=material.displayName,
            finished=false, lastPath="capability", lastError="缺少可用的稳定ID或拍卖搜索路径",
        }
        self:FinishRequest(placeholder,nil)
        return
    end

    self.queue[#self.queue+1]={
        token=quote.token,
        quote=quote,
        name=material.name,
        displayName=material.displayName,
        itemType=itemType,
        cacheKey=CacheKey(material),
        gradeCandidates=BuildGradeCandidates(material),
        gradeIndex=1,
        queryNames=queryNames,
        queryIndex=1,
        activeQuery=nil,
        requestedAt=0,
        directEnabled=directEnabled,
        searchEnabled=searchEnabled,
        mode=directEnabled and "direct" or "search",
        finished=false,
    }
end

function A:QuotePack(packName,materials,context)
    local apiReady=S.Api~=nil and type(S.Api.IsCapabilityAllowed)=="function"
    local directReady=apiReady and S.Api:IsCapabilityAllowed("X2Auction:GetLowestPrice")==true
    local searchReady=apiReady
        and S.Api:IsCapabilityAllowed("X2Auction:SearchAuctionArticle")==true
        and S.Api:IsCapabilityAllowed("X2Auction:GetSearchedItemCount")==true
        and S.Api:IsCapabilityAllowed("X2Auction:GetSearchedItemInfo")==true
    if directReady~=true and searchReady~=true then
        self:Publish("unavailable","X2Auction 稳定ID直查 / 搜索接口均不可用")
        return false
    end

    self.token=self.token+1
    self.queue={}
    local cancelled=self.current
    if type(cancelled)=="table" and cancelled.mode=="search" then
        -- AUCTION_ITEM_SEARCHED carries no request token. If the user starts a
        -- new quote while an older async name search is still outstanding, do
        -- not send another name search until the old request's bounded timeout
        -- has expired; otherwise a late old result can be mistaken for the new
        -- material. Stable-ID GetLowestPrice calls may continue immediately.
        local requestedAt=tonumber(cancelled.requestedAt) or S.NowMs()
        self.staleSearchFenceUntil=math.max(tonumber(self.staleSearchFenceUntil) or 0,requestedAt+self.searchTimeoutMs)
    end
    self.current=nil
    self.nextSendAt=math.max(tonumber(self.nextSendAt) or 0,S.NowMs()+100)

    local queryable=0
    for _,material in ipairs(materials or {}) do
        if material.auctionable~=false then queryable=queryable+1 end
    end
    local quote={
        token=self.token, packName=tostring(packName or ""), materials=materials or {},
        prices={}, failures={}, remaining=queryable, context=context,
    }
    if #(materials or {})<=0 then
        self:Publish("unavailable","该贸易品没有可查询的材料表")
        return false
    end

    for _,material in ipairs(materials or {}) do self:QueueOne(quote,material,directReady,searchReady) end
    if quote.remaining<=0 then
        self:Publish("ready","材料价格来自短时缓存")
        local trade=S.Services and S.Services.Trade
        if trade and type(trade.OnMaterialQuote)=="function" then trade:OnMaterialQuote(quote) end
        return true
    end

    self:Publish("loading",directReady and "正在按材料ID逐项查询拍卖参考价…" or "正在按名称兜底查询拍卖参考价…")
    return true
end

-- Queue a user-visible Auction House keyword search. Latest click wins while an
-- older interactive search is still awaiting AUCTION_ITEM_SEARCHED. The method
-- never touches the trade quote token/queue and therefore cannot cancel a price
-- request merely because the player clicked a favorite.
function A:SearchInteractive(keyword)
    keyword=Trim(keyword)
    if keyword=="" then return false, "搜索内容不能为空" end
    if S.Api==nil or type(S.Api.IsCapabilityAllowed)~="function"
        or S.Api:IsCapabilityAllowed("X2Auction:SearchAuctionArticle")~=true then
        return false, "拍卖搜索接口当前不可用"
    end
    self.interactivePending={keyword=keyword, queuedAt=S.NowMs()}
    return true, "queued"
end

function A:SendInteractive(request)
    if type(request)~="table" then return false end
    local keyword=Trim(request.keyword)
    if keyword=="" then return false end
    local now=S.NowMs()
    self.nextSendAt=now+self.searchCooldownMs
    local ok,value,err=S.Api:CallCapability(
        "X2Auction:SearchAuctionArticle",X2Auction,"SearchAuctionArticle",1,0,55,1,0,false,keyword,"0","0")
    if not ok or value==false then
        return false, tostring(err or "rejected")
    end
    self.interactiveAwaiting={keyword=keyword,requestedAt=now}
    return true
end

function A:SendDirect(request)
    if request==nil or request.token~=self.token or request.finished==true then return false end
    local grade=CurrentGrade(request)
    if request.itemType==nil or grade==nil then
        return self:FallbackToSearch(request,"稳定ID查询缺少 itemType/itemGrade")
    end

    local now=S.NowMs()
    self.nextSendAt=now+self.directCooldownMs
    request.mode="direct"
    request.lastPath="stable-id:GetLowestPrice"
    local ok,value,err,b,c,d=S.Api:CallCapability(
        "X2Auction:GetLowestPrice",X2Auction,"GetLowestPrice",request.itemType,grade)
    if not ok then
        -- A capability/runtime failure is not evidence that the next grade is
        -- valid. Fall back once instead of burning the whole grade probe range.
        return self:FallbackToSearch(request,
            "ID直查失败["..tostring(request.itemType).."/"..tostring(grade).."]："..tostring(err or "rejected"))
    end

    local price=ExtractPrice(value,b,c,d)
    if price~=nil then
        request.resolvedGrade=grade
        self:FinishRequest(request,price)
        return true
    end
    return self:RetryNextGrade(request,
        "ID直查无价格["..tostring(request.itemType).."/"..tostring(grade).."]")
end

function A:SendSearch(request)
    if request==nil or request.token~=self.token or request.finished==true then return false end
    local query=CurrentQuery(request)
    if query==nil then
        request.lastError="没有可用搜索词"
        self:FinishRequest(request,nil)
        return false
    end

    request.mode="search"
    request.lastPath=request.lastPath or "folio105-search-first-row"
    request.activeQuery=query
    request.requestedAt=S.NowMs()
    self.current=request
    self.nextSendAt=request.requestedAt+self.searchCooldownMs

    -- Historical Folio105 compatibility fallback. Stable-ID direct lookup above
    -- is the primary path; this request is only used when direct data is absent.
    local ok,value,err=S.Api:CallCapability(
        "X2Auction:SearchAuctionArticle",X2Auction,"SearchAuctionArticle",1,0,999,1,0,false,query,"0","0")
    if not ok or value==false then
        if self.current==request then self.current=nil end
        local reason="搜索请求失败["..tostring(query).."]："..tostring(err or "rejected")
        self:RetryNextQuery(request,reason)
        return false
    end
    return true
end

local function ExtractRowItemType(info)
    if type(info)~="table" then return nil end
    local value=tonumber(info.itemType or info.itemTypeId or info.item_type)
    if value~=nil then return math.floor(value) end
    for _,key in ipairs({"itemInfo","item","tooltip","info"}) do
        local nested=info[key]
        if type(nested)=="table" then
            value=tonumber(nested.itemType or nested.itemTypeId or nested.item_type)
            if value~=nil then return math.floor(value) end
        end
    end
    return nil
end

local function ExtractRowName(info)
    if type(info)~="table" then return nil end
    for _,key in ipairs({"name","itemName","displayName","item_name"}) do
        local value=NonEmpty(info[key]); if value~=nil then return value end
    end
    for _,key in ipairs({"itemInfo","item","tooltip","info"}) do
        local nested=info[key]
        if type(nested)=="table" then
            for _,nameKey in ipairs({"name","itemName","displayName","item_name"}) do
                local value=NonEmpty(nested[nameKey]); if value~=nil then return value end
            end
        end
    end
    return nil
end

-- The compatibility path deliberately preserves the old first-row bidPrice
-- behavior. It is a fallback only; do not scan/sort the whole page here.
local function ExtractFolioReferencePrice(info)
    if type(info)~="table" then return nil end
    local price=ToNumber(info.bidPriceStr)
    if price==nil then price=ToNumber(info.bidPrice) end
    if price~=nil and price>0 then return math.floor(price) end
    return nil
end

function A:OnSearched(...)
    -- Interactive requests are never sent while a quote name-search is current,
    -- so this branch cannot steal a price-query completion. Clear the ownership
    -- fence and leave the native Auction House to render the result normally.
    if self.current==nil and self.interactiveAwaiting~=nil then
        self.interactiveAwaiting=nil
        return
    end

    local request=self.current
    if request==nil or request.token~=self.token or request.mode~="search" or request.finished==true then return end

    local okCount,countValue=S.Api:CallCapability("X2Auction:GetSearchedItemCount",X2Auction,"GetSearchedItemCount")
    if not okCount then return end
    local count=math.max(0,math.floor(tonumber(countValue) or 0))
    if count<=0 then
        self.current=nil
        self:RetryNextQuery(request,"拍卖搜索0条["..tostring(request.activeQuery or "?").."]")
        return
    end

    local okInfo,info,err=S.Api:CallCapability("X2Auction:GetSearchedItemInfo",X2Auction,"GetSearchedItemInfo",1)
    if not okInfo or type(info)~="table" then
        self.current=nil
        self:RetryNextQuery(request,"首条结果读取失败["..tostring(request.activeQuery or "?").."]："..tostring(err or "invalid row"))
        return
    end

    -- Even the fallback must not accept a clearly different stable identity.
    local rowType=ExtractRowItemType(info)
    if request.itemType~=nil then
        if rowType==nil then
            self.current=nil
            self:RetryNextQuery(request,
                "首条结果无法验证材料ID[期望="..tostring(request.itemType).."]")
            return
        end
        if rowType~=request.itemType then
            self.current=nil
            self:RetryNextQuery(request,
                "首条结果ID不匹配[期望="..tostring(request.itemType)..", 实际="..tostring(rowType).."]")
            return
        end
    end

    local price=ExtractFolioReferencePrice(info)
    if price==nil then
        local rowName=ExtractRowName(info) or request.activeQuery or "?"
        self.current=nil
        self:RetryNextQuery(request,"首条结果无竞拍参考价["..tostring(rowName).."]")
        return
    end

    self.current=nil
    self:FinishRequest(request,price)
end

function A:Tick()
    local now=S.NowMs()
    if self.current~=nil then
        local request=self.current
        if now-(tonumber(request.requestedAt) or now)>=self.searchTimeoutMs then
            self.current=nil
            self:RetryNextQuery(request,"拍卖搜索超时["..tostring(request.activeQuery or "?").."]")
            self.nextSendAt=math.max(tonumber(self.nextSendAt) or 0,now+self.searchCooldownMs)
        end
        return
    end

    -- An interactive native search owns the un-tokened AUCTION_ITEM_SEARCHED
    -- stream until completion. Direct GetLowestPrice calls are safe, but keeping
    -- the queue paused for this short interval also prevents a later fallback
    -- search from immediately replacing the result the player just requested.
    if self.interactiveAwaiting~=nil then
        if now-(tonumber(self.interactiveAwaiting.requestedAt) or now)>=self.searchTimeoutMs then
            self.interactiveAwaiting=nil
        else
            return
        end
    end

    -- Favorites are explicit foreground user intent. Coalesce repeated clicks
    -- and run the latest one at the next shared auction cooldown boundary.
    if self.interactivePending~=nil
        and now>=(tonumber(self.nextSendAt) or 0)
        and now>=(tonumber(self.staleSearchFenceUntil) or 0) then
        local request=self.interactivePending
        self.interactivePending=nil
        local ok=self:SendInteractive(request)
        if ok~=true then
            -- No retry loop for a UI click; a later click can try again.
            self.interactiveAwaiting=nil
        end
        return
    end

    if #self.queue==0 or now<(tonumber(self.nextSendAt) or 0) then return end
    local pending=self.queue[1]
    if pending~=nil and pending.mode=="search"
        and now<(tonumber(self.staleSearchFenceUntil) or 0) then return end
    local request=table.remove(self.queue,1)
    if request.mode=="direct" and request.directEnabled==true then self:SendDirect(request)
    else self:SendSearch(request) end
end

function A:Start()
    self.interactivePending=nil
    self.interactiveAwaiting=nil
    S.State.data.auction={status="idle",text=nil,pending=0}
    S.Events:Subscribe("AUCTION_ITEM_SEARCHED",self,function(_,...) A:OnSearched(...) end)
    S.Scheduler:AddTask("auction_queue",S.Constants.Refresh.auctionStepMs or 200,function() A:Tick() end,false,self,"P2")
end

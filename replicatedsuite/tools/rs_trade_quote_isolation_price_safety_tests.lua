------------------------------------------------------------------------
-- 2026-09-30 quote-isolation-price-safety-1: real API/import/queue/search/material services.
-- Native 窗口/网络回包/时钟只作为外部边界替身；同一套用例必须先在旧基线失败。
-- 不进入 toc.g；离线通过不能证明 RU 服务器已发送请求可以撤回。
------------------------------------------------------------------------
unpack = unpack or table.unpack
local passed, total = 0, 0
local function Test(name, fn)
    total = total + 1
    local ok, err = xpcall(fn, debug.traceback)
    if ok then passed = passed + 1; print("PASS " .. name)
    else print("FAIL " .. name .. ": " .. tostring(err)) end
end
local function Eq(a, b, message)
    assert(a == b, (message or "value") .. ": expected=" .. tostring(b) .. ", actual=" .. tostring(a))
end
local function Copy(v)
    if type(v) ~= "table" then return v end
    local out = {}; for k, x in pairs(v) do out[k] = Copy(x) end; return out
end
local function Boot(staleAuctionHost)
    local h = { now = 10000, visible = false, tasks = {}, native = {}, internal = {}, calls = {}, events = {},
        deliveries = {}, rows = {}, lowest = {}, visibilityReads = 0, textWrites = 0, keyword = "用户搜索", pausedEvents = 0 }
    local S = { Services = {}, Utils = { DeepCopy = Copy }, NowMs = function() return h.now end }
    ReplicatedSuite = S
    S.Layout = { GetContext = function() return { logicalWidth = 1920, logicalHeight = 1080 } end }
    S.Scheduler = {}
    function S.Scheduler:AddTask(id, interval, fn, _, owner)
        h.tasks[id] = { id = id, interval = interval, at = h.now + interval, fn = fn, owner = owner }; return true
    end
    function S.Scheduler:AddOneShot(id, delay, fn, owner)
        if h.rejectTimeout and id == "v3_auction_query_timeout" then return false end
        h.tasks[id] = { id = id, at = h.now + delay, fn = fn, owner = owner }; return true
    end
    function S.Scheduler:RemoveTask(id) h.tasks[id] = nil; return true end
    function S.Scheduler:SetTaskModule() return true end
    local function Subscribe(map, topic, owner, fn)
        map[topic] = map[topic] or {}; map[topic][owner] = fn; return true
    end
    local function Unsubscribe(map, topic, owner)
        if map[topic] then map[topic][owner] = nil end; return true
    end
    local function Emit(map, topic, ...)
        local entries = {}; for owner, fn in pairs(map[topic] or {}) do entries[#entries + 1] = { owner, fn } end
        for _, entry in ipairs(entries) do entry[2](entry[1], ...) end
    end
    S.Events = {}
    function S.Events:BindOwner() return true end
    function S.Events:SubscribeOptional(topic, owner, fn) return Subscribe(h.native, topic, owner, fn) end
    function S.Events:Unsubscribe(topic, owner) return Unsubscribe(h.native, topic, owner) end
    function S.Events:SubscribeInternal(topic, owner, fn) return Subscribe(h.internal, topic, owner, fn) end
    function S.Events:UnsubscribeInternal(topic, owner) return Unsubscribe(h.internal, topic, owner) end
    function S.Events:Publish(topic, ...)
        h.events[#h.events + 1] = { topic = topic, args = { ... } }
        Emit(h.internal, topic, ...); return true
    end
    S.Reuse = { Table = { DeepCopy = Copy } }
    S.Generation = 1
    dofile("core/rs_api_capabilities.lua")
    dofile("core/rs_api.lua")
    local auction = {}
    local function Called(method, args)
        h.calls[#h.calls+1] = { method=method, args=args, at=h.now }
    end
    function auction:SearchAuctionArticle(...)
        Called("SearchAuctionArticle", {...})
        if h.rejectSearch then return false end
        if h.syncComplete then Emit(h.native, "AUCTION_ITEM_SEARCHED") end
        return true
    end
    function auction:GetSearchedItemCount() Called("GetSearchedItemCount",{});return #h.rows end
    function auction:GetSearchedItemInfo(i) Called("GetSearchedItemInfo",{i});return Copy(h.rows[i]) end
    function auction:AskMarketPrice(id,grade,open)
        Called("AskMarketPrice",{id,grade,open});Eq(open,false,"never open price UI")
        if h.askError then error("cold_ask_error") end
        if h.askFalse then return false end
        return true
    end
    function auction:GetLowestPrice(id,grade)
        Called("GetLowestPrice",{id,grade})
        if h.readError then error("cold_read_error") end
        return h.lowest[id]
    end
    h.edit = {
        GetObjectType = function() return "editbox" end, GetName = function() return "auction_search_keyword" end,
        GetText = function() return h.keyword end,
        SetText = function(_, value) h.keyword = value; h.textWrites = h.textWrites + 1 end,
    }
    h.content = { search = h.edit, IsVisible = function() return h.visible end, GetParent = function() return nil end }
    _G.UIC_AUCTION = 9001
    _G.ADDON = {
        GetContent = function() return h.content end,
        GetContentMainScriptPosVis = function()
            h.visibilityReads = h.visibilityReads + 1
            if h.onVisibilityRead then h.onVisibilityRead(h.visibilityReads) end
            if h.visibilityError then error("native geometry unavailable") end
            if h.noGeometry then return nil, nil, nil, nil, h.omitVisibility and nil or h.visible end
            if h.omitVisibility then return 200, 150, 800, 600 end
            return 200, 150, 800, 600, h.visible
        end,
    }
    -- Load services with no business namespaces present; import only Trade's actual registry dependencies later.
    for _,name in ipairs({"X2Auction","X2Craft","X2Store","X2Ability","X2Equipment"}) do _G[name]=nil end
    if staleAuctionHost then _G.X2Auction={} end -- placeholder/reload host, replaced by ImportAPI
    h.imports={}
    dofile("native/rs_native_contract.lua")
    function ADDON:ImportAPI(id)
        h.imports[id]=(h.imports[id] or 0)+1
        for _,def in pairs(S.NativeContract.Api) do
            if def.id==id then _G[def.nativeName]=id==51 and auction or {} end
        end
        return true
    end
    function ADDON:ImportObject() return true end
    dofile("native/rs_native_imports.lua")
    assert(S.BootError==nil,S.BootError)
    dofile("features/rs_feature_registry.lua")
    -- toc.g order: Query and Queue load BEFORE Surface. Guard lookups must be runtime-local, not captured nil.
    dofile("services/rs_auction_query_v3.lua")
    dofile("services/rs_price_quote_queue_v3.lua")
    dofile("services/rs_auction_surface_v3.lua")
    h.S, h.query, h.queue, h.surface = S, S.Services.AuctionQueryV3, S.Services.PriceQuoteQueueV3, S.Services.AuctionSurfaceV3
    assert(S.NativeImports:Acquire("feature:life_trade", S.FeatureRegistry.features.life_trade.apiDependencies))
    h.Emit=Emit
    function h:loadMaterialPrices()
        local stores={}
        S.Persistence={Scope={Account="account"},Lifetime={Permanent="permanent"},V3KeyPrefix="test:",
            GetStore=function(_,id)return stores[id]end,
            RegisterV3Store=function(_,spec)stores[spec.id]={value=spec.default(),spec=spec};return stores[spec.id]end,
            LoadStore=function(_,id)return true,Copy(stores[id].value)end,
            MarkDirty=function()return true end}
        S.Utils.GetServerTime=function()return {year=2026,month=9,day=30,hour=12,min=0,sec=0}end
        dofile("services/rs_material_price_service_v3.lua")
        self.materialPrices=S.Services.MaterialPriceServiceV3
        return self.materialPrices
    end
    function h:advance(ms)
        local stop, iterations = self.now + ms, 0
        while true do
            local first
            for _, task in pairs(self.tasks) do
                if task.at <= stop and (not first or task.at < first.at or (task.at == first.at and task.id < first.id)) then first = task end
            end
            if not first then break end
            iterations = iterations + 1; assert(iterations < 2000, "scheduler runaway")
            self.now = first.at
            if first.interval then first.at = first.at + first.interval else self.tasks[first.id] = nil end
            first.fn()
        end
        self.now = stop
    end
    function h:count(method)
        local n = 0; for _, c in ipairs(self.calls) do if c.method == method then n = n + 1 end end; return n
    end
    function h:quote(requester, itemType, name)
        return self.queue:RequestQuote(requester, itemType, 1, function(result)
            self.deliveries[#self.deliveries + 1] = result
        end, {1}, { searchName = name or ("材料" .. tostring(itemType)), force = true, priority = "user" })
    end
    function h:untilSearch()
        for _ = 1, 10 do if self:count("SearchAuctionArticle") > 0 then return end; self:advance(1000) end
        error("initial hidden fallback did not search")
    end
    function h:searched(rows)
        self.rows = rows or self.rows; Emit(self.native, "AUCTION_ITEM_SEARCHED")
    end
    function h:open(publish)
        self.visible = true
        if publish then self.S.Events:Publish(self.surface.topic, { status = "ready", visible = true }) end
    end
    return h
end
local function Row(id,price,count)
    return {itemType=id,itemGrade=1,name="材料"..id,itemStack=count or 10,directPrice=price or 500}
end
Test("only Trade import owner can quote with Auction feature never loaded",function()
    local h=Boot();h.lowest[30901]=559
    assert(h:quote("life_trade:rowjob:1",30901));h:advance(6000)
    Eq(h.deliveries[1].price,559);Eq(h.imports[51],1);Eq(h.imports[9],1)
    Eq(h.S.Features,nil,"no other features loaded");Eq(h.surface.started,false)
    Eq(h.tasks[h.surface.taskId],nil,"sidecar observer remains stopped")
    Eq(h.S.NativeImports.apiOwners["feature:tools_auction"],nil)
end)
Test("late Trade import replaces placeholder Auction namespace for name fallback",function()
    local h=Boot(true);assert(h:quote("trade:1",101));h:untilSearch()
    h:searched({Row(101)});h:advance(3000);Eq(h.deliveries[1].price,50)
    Eq(h.S.NativeImports.apiOwners["feature:tools_auction"],nil)
end)
Test("direct getter exception falls back to owned name search instead of failing the row",function()
    local h=Boot();h.readError=true;assert(h:quote("trade:1",101));h:untilSearch()
    h:searched({Row(101)});h:advance(3000)
    Eq(#h.deliveries,1);Eq(h.deliveries[1].status,"ready");Eq(h.deliveries[1].price,50)
    assert(tostring(h.deliveries[1].marketError):find("cold_read_error",1,true),"preserve direct error evidence")
    Eq(h.surface.started,false)
end)
Test("native false Ask is not a successful handshake and cannot consume stale getter",function()
    local h=Boot();h.askFalse=true;h.lowest[101]=999999
    assert(h:quote("trade:1",101));h:untilSearch();h:searched({Row(101)});h:advance(3000)
    Eq(h:count("GetLowestPrice"),0);Eq(h.deliveries[1].price,50)
end)
Test("failed direct getter retains manual auction ownership protection",function()
    local h=Boot();h.readError=true;h.visible=true
    assert(h:quote("trade:1",101));h:advance(20000)
    Eq(h:count("SearchAuctionArticle"),0);Eq(#h.deliveries,0);Eq(h.queue:GetActivitySnapshot().paused,true)
    h.visible=false;h:untilSearch();h:searched({Row(101)});h:advance(3000);Eq(h.deliveries[1].price,50)
end)
Test("fallback must still fail on conflicting identity",function()
    local h=Boot();h.readError=true;assert(h:quote("trade:1",101));h:untilSearch()
    local row=Row(102);row.name="材料101";h:searched({row});h:advance(3000)
    assert(h.deliveries[1].status~="ready");Eq(h.deliveries[1].price,nil)
end)
for _,shape in ipairs({
    {amount=180,directPrice=269820,itemStack=180},
    {directPrice=269820,itemStack=180},
    {amount=180},
    {bidPrice=1234,itemStack=20},
}) do
    Test("ambiguous direct return cannot be accepted as unit cost #"..tostring(total),function()
        local h=Boot();h.lowest[101]=shape
        assert(h:quote("trade:1",101));h:untilSearch();h:searched({Row(101,55900,100)});h:advance(3000)
        Eq(h.deliveries[1].price,559);Eq(h.deliveries[1].priceSource,"name_search_direct_unit")
    end)
end
Test("scalar grouped string and currency tuples remain supported",function()
    for _,price in ipairs({"1,234",{gold=1,silver=2,copper=3},{value=2468},{lowestPrice=310}})do
        local h=Boot();h.lowest[101]=price;assert(h:quote("trade:1",101));h:advance(5000)
        Eq(h.deliveries[1].status,"ready");Eq(h:count("SearchAuctionArticle"),0)
    end
end)
Test("name-search money totals still normalize strings currency tuples and wrappers",function()
    for _,raw in ipairs({"50,000",{gold=5,silver=0,copper=0},{value=50000},{amount=50000}})do
        local h=Boot();assert(h:quote("trade:1",101));h:untilSearch()
        local row=Row(101,50000,1000);row.directPrice=raw
        h:searched({row});h:advance(3000);Eq(h.deliveries[1].price,50)
    end
end)
Test("cyclic malformed money wrapper is rejected without crashing the lane",function()
    local h=Boot();local p={};p.value=p;h.lowest[101]=p
    assert(h:quote("trade:1",101));h:untilSearch();h:searched({Row(101)});h:advance(3000);Eq(h.deliveries[1].price,50)
end)
for _,invalidCount in ipairs({0,-1,0.5,math.huge})do
    Test("invalid listing quantity is not silently one unit "..tostring(invalidCount),function()
        local h=Boot();assert(h:quote("trade:1",101));h:untilSearch()
        local row=Row(101,62573);row.itemStack=invalidCount;h:searched({row});h:advance(3000)
        assert(h.deliveries[1].status~="ready","malformed count became a valid quote")
        Eq(h.deliveries[1].price,nil)
    end)
end
Test("market anomaly quarantine cannot leak through session or TTL cache",function()
    local h=Boot();local m=h:loadMaterialPrices();assert(m:ObserveConfirmedPrice(30901,1,559,"market_price:1"))
    h.lowest[30901]=1499;assert(h:quote("trade:1",30901));h:advance(6000)
    Eq(m:GetPrice(30901,1),559,"material authority kept old price")
    Eq(h.queue:GetPriceByItemType(30901,1),559,"session must not bypass quarantine")
    Eq(h.queue:PeekCached(30901,1),nil,"held candidate cannot enter TTL cache")
    Eq(h.deliveries[1].observedPrice,1499);Eq(h.deliveries[1].priceAccepted,false)
    Eq(h.deliveries[1].priceDecision,"anomaly_candidate_held");Eq(h.deliveries[1].price,559)
end)
Test("second genuine quote can confirm changed market price",function()
    local h=Boot();local m=h:loadMaterialPrices();assert(m:ObserveConfirmedPrice(30901,1,559,"market_price:1"))
    h.lowest[30901]=1499;assert(h:quote("trade:1",30901));h:advance(5000)
    assert(h:quote("trade:2",30901));h:advance(5000)
    Eq(m:GetPrice(30901,1),1499);Eq(h.queue:GetPriceByItemType(30901,1),1499)
end)
Test("failed durable store keeps explicit session quotation usable",function()
    local h=Boot();local m=h:loadMaterialPrices();m.storeLoaded=false
    h.S.Persistence.LoadStore=function()return false,nil,"store_unavailable"end
    h.lowest[101]=55;assert(h:quote("trade:1",101));h:advance(5000)
    Eq(h.deliveries[1].price,55);Eq(h.queue:GetPriceByItemType(101,1),55)
end)
Test("zero/nonfinite money table never becomes a free material quote",function()
    for _,price in ipairs({{value=0},{gold=0},{value=math.huge}})do
        local h=Boot();h.lowest[101]=price;assert(h:quote("trade:1",101));h:untilSearch()
        h:searched({Row(101)});h:advance(3000);Eq(h.deliveries[1].price,50)
    end
end)
Test("malformed nested listing money cannot crash the shared response handler",function()
    local h=Boot();assert(h:quote("trade:1",101));h:untilSearch()
    local cyclic={};cyclic.value=cyclic;local row=Row(101);row.directPrice=cyclic
    h:searched({row});h:advance(3000);assert(h.deliveries[1].status~="ready")
end)
Test("native calls retain serial pacing and exact once delivery across two requests",function()
    local h=Boot();h.readError=true;assert(h:quote("trade:1",101));assert(h:quote("trade:2",102));h:untilSearch()
    h:searched({Row(101)});h:advance(1000)
    for _=1,10 do if h:count("SearchAuctionArticle")>=2 then break end;h:advance(1000)end
    Eq(h:count("SearchAuctionArticle"),2);h:searched({Row(102)});h:advance(5000);Eq(#h.deliveries,2)
    local last=nil
    for _,c in ipairs(h.calls)do
        if c.method=="AskMarketPrice" or c.method=="GetLowestPrice" or c.method=="SearchAuctionArticle" then
            if last then assert(c.at-last>=1000,"native call pacing lost")end;last=c.at
        end
    end
    Eq(h.queue.pending,nil);Eq(#h.queue.queue,0);Eq(h.tasks[h.queue.taskName],nil)
end)
print(string.format("TRADE_QUOTE_ISOLATION_PRICE_SAFETY: %d/%d passed (%s)",passed,total,_VERSION))
assert(passed==total,"trade quote isolation/price safety failures")

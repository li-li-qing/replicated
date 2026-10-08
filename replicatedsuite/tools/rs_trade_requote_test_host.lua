-- 2026-09-30 trade-requote-2: test-only Native, clock, persistence boundaries.
-- Real Api/NativeImports/AuctionSurface/Query/Queue/MaterialPrice services are loaded below.
-- The helper shares the prior reviewed cold-import boundary model; no production test hook.
unpack = unpack or table.unpack
local function Eq(a,b,message) assert(a==b,(message or "value")..": expected="..tostring(b)..", actual="..tostring(a)) end
local function Copy(v)
    if type(v) ~= "table" then return v end
    local out = {}; for k, x in pairs(v) do out[k] = Copy(x) end; return out
end
local function Boot(existingS)
    local h = { now = 10000, visible = false, tasks = {}, native = {}, internal = {}, calls = {}, events = {},
        deliveries = {}, rows = {}, lowest = {}, visibilityReads = 0, textWrites = 0, keyword = "用户搜索", pausedEvents = 0 }
    local S = existingS or { Services = {}, Utils = { DeepCopy = Copy } }
    S.NowMs = function() return h.now end
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
        local args={...};h.searchNumber=(h.searchNumber or 0)+1
        -- 给边界模型完整九参数；已有 keyword/序号回调保持兼容，模型不能凭请求 ID 自动伪造命中。
        if h.onSearch then h.rows=h.onSearch(args[7],h.searchNumber,args) or {} end
        if h.rejectSearch then return false end
        if h.syncComplete then Emit(h.native, "AUCTION_ITEM_SEARCHED") end
        return true
    end
    function auction:GetSearchedItemCount() Called("GetSearchedItemCount",{});return #h.rows end
    function auction:GetSearchedItemTotalCount()
        Called("GetSearchedItemTotalCount",{})
        if h.totalCountUnknown then return nil end
        if h.totalCountError then error('total_count_failed') end
        return h.totalCount or #h.rows
    end
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
    if true then _G.X2Auction={} end -- placeholder/reload host, replaced by ImportAPI
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
    dofile('core/rs_diagnostic_detail.lua')
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
        S.Utils.GetServerTime=function()return {year=2026,month=9,day=30,hour=12,minute=0,second=0}end
        dofile("services/rs_material_price_service_v3.lua")
        dofile("services/rs_trade_material_quote_service_v3.lua")
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
    function h:quote(requester, itemType, name, options)
        return self.queue:RequestQuote(requester, itemType, 1, function(result)
            self.deliveries[#self.deliveries + 1] = result
        end, {1}, options or { searchName = name or ("材料" .. tostring(itemType)), force = true, priority = "user" })
    end
    function h:untilSearch()
        for _ = 1, 10 do if self:count("SearchAuctionArticle") > 0 then return end; self:advance(1000) end
        error("initial hidden fallback did not search")
    end
    function h:searched(rows, ...)
        -- 维护：Native 完成边界保留中间 nil 和实际参数数；回调仍按真实 EventBus 的 owner-first 形状分发。
        self.rows = rows or self.rows; Emit(self.native, "AUCTION_ITEM_SEARCHED", ...)
    end
    function h:open(publish)
        self.visible = true
        if publish then self.S.Events:Publish(self.surface.topic, { status = "ready", visible = true }) end
    end
    return h
end

return Boot

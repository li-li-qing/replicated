------------------------------------------------------------------------
-- 维护（2026-09-30，auction-user-priority-1）：实际加载共享服务，不模拟修复逻辑。
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
local function Boot()
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
    S.Api = {}
    function S.Api:IsCapabilityAllowed(capability) return capability ~= h.blockedCapability end
    function S.Api:CallCapability(capability, api, method, ...)
        local args = { ... }
        h.calls[#h.calls + 1] = { method = method, args = args, at = h.now }
        if method == "GetContent" then return true, h.content end
        if method == "SearchAuctionArticle" then
            if h.syncComplete then Emit(h.native, "AUCTION_ITEM_SEARCHED") end
            if h.rejectSearch then return false, nil, "test_search_rejected" end
            return true, true
        end
        if method == "GetSearchedItemCount" then return true, #h.rows end
        if method == "GetSearchedItemInfo" then return true, h.rows[args[1]] end
        if method == "AskMarketPrice" then Eq(args[3], false, "never open market-price UI"); return true, true end
        if method == "GetLowestPrice" then return true, h.lowest[args[1]] end
        error("unexpected Native call " .. tostring(method))
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
    _G.X2Auction = {}
    -- toc.g order: Query and Queue load BEFORE Surface. Guard lookups must be runtime-local, not captured nil.
    dofile("services/rs_auction_query_v3.lua")
    dofile("services/rs_price_quote_queue_v3.lua")
    dofile("services/rs_auction_surface_v3.lua")
    dofile("services/rs_auction_search_bridge_v3.lua")
    h.S, h.query, h.queue, h.surface, h.bridge = S, S.Services.AuctionQueryV3, S.Services.PriceQuoteQueueV3,
        S.Services.AuctionSurfaceV3, S.Services.AuctionSearchBridgeV3
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
local function Row(id, price)
    return { itemType = id, itemGrade = 1, name = "材料" .. tostring(id), itemStack = 10, directPrice = price or 500 }
end

Test("open-before-quote blocks fallback without cancelling row", function()
    local h = Boot(); h:open(); assert(h:quote("trade:1", 101)); h:advance(30000)
    Eq(h:count("SearchAuctionArticle"), 0, "background must not replace native list")
    Eq(#h.deliveries, 0, "pause is not completion")
    Eq(h.queue.stats.failed, 0, "pause is not failure")
    Eq(h.queue:GetActivitySnapshot().paused, true, "activity")
end)
Test("open-during-fallback stops repeated materials and ignores user rows", function()
    local h = Boot(); assert(h:quote("trade:1", 101)); assert(h:quote("trade:2", 102)); h:untilSearch()
    h:open(); h:searched({Row(101)}); h:advance(30000)
    Eq(h:count("SearchAuctionArticle"), 1, "no second material search")
    Eq(h:count("GetSearchedItemCount"), 0, "native user results are not quote-owned")
    Eq(#h.deliveries, 0, "row intents retained")
    Eq(next(h.queue.negativeCache), nil, "no negative-cache pollution")
end)
Test("stopped-sidecar cached closed snapshot cannot authorize search", function()
    local h = Boot(); h.surface:Stop("sidecar_disabled"); h:open(); assert(h:quote("trade:1", 101)); h:advance(20000)
    Eq(h:count("SearchAuctionArticle"), 0, "fresh Native visibility required")
    Eq(h.surface.started, false, "guard must not turn on sidecar")
    Eq(h.tasks[h.surface.taskId], nil, "no new surface observer")
end)
Test("low-level legacy fallback requester also guarded", function()
    local h = Boot(); h:open()
    local ok = h.query:Search("price_quote_fallback", "材料101", {})
    Eq(ok, false, "legacy requester cannot bypass ownership")
    Eq(h:count("SearchAuctionArticle"), 0, "no rejected native call")
end)
Test("explicit sidecar user search remains available and syncs once", function()
    local h = Boot(); h:open(true)
    assert(h.bridge:Search("tools_auction", "玩家关键词", {}))
    Eq(h:count("SearchAuctionArticle"), 1, "user authorized search")
    Eq(h.keyword, "玩家关键词", "explicit keyword")
    Eq(h.textWrites, 1, "single native keyword write")
    h:advance(1000); Eq(h.textWrites, 1, "no keyword loop")
end)
Test("unknown visibility is waiting, not false empty/failure", function()
    local h = Boot(); h.visibilityError = true; h.content = nil
    assert(h:quote("trade:1", 101)); h:advance(30000)
    Eq(h:count("SearchAuctionArticle"), 0, "unknown ownership fails closed")
    Eq(#h.deliveries, 0, "no fake failure")
    Eq(h.queue:GetActivitySnapshot().reason, "native_auction_visibility_unknown", "reason")
end)
Test("boolean visibility survives missing geometry", function()
    local h = Boot(); h.noGeometry = true; h:open()
    local known, visible = h.surface:ReadVisibility()
    Eq(known, true, "known open independent of geometry"); Eq(visible, true, "visible")
    assert(h:quote("trade:1", 101)); h:advance(15000); Eq(h:count("SearchAuctionArticle"), 0, "no search")
end)
Test("legacy four-value getter uses content visibility", function()
    local h = Boot(); h.omitVisibility = true
    local known, visible = h.surface:ReadVisibility()
    Eq(known, true, "content visibility known"); Eq(visible, false, "hidden content stronger than stale geometry")
    assert(h:quote("trade:1", 101)); h:untilSearch(); Eq(h:count("SearchAuctionArticle"), 1, "legacy hidden searches")
    h:open(); h:searched({Row(101)}); Eq(#h.deliveries, 0, "open ownership invalidated")
end)
Test("on-demand visibility probe does not publish or start observer", function()
    local h = Boot(); local beforeEvents, beforeRevision = #h.events, h.surface.revision
    local before = h.surface:GetSnapshot(); h:open()
    local known, visible = h.surface:ReadVisibility()
    Eq(known, true); Eq(visible, true); Eq(#h.events, beforeEvents, "pure observation")
    Eq(h.surface.revision, beforeRevision); Eq(h.surface:GetSnapshot().status, before.status)
    Eq(next(h.tasks), nil, "no tasks just to read visibility")
end)
Test("long user session freezes deadline then resumes same request", function()
    local h = Boot(); h:open(); assert(h:quote("trade:1", 101)); h:advance(120000)
    -- 维护（auction-full-lane-safety-1）：旧测试允许开窗期间提前 Ask/Read；现在恢复后须完整节流握手。
    Eq(#h.deliveries, 0); Eq(h:count("AskMarketPrice"), 0); Eq(h:count("GetLowestPrice"), 0)
    h.visible = false; h:untilSearch()
    Eq(h:count("SearchAuctionArticle"), 1, "resume once after close")
    h:searched({Row(101)}); h:advance(2000)
    Eq(#h.deliveries, 1); Eq(h.deliveries[1].status, "ready"); Eq(h.deliveries[1].price, 50, "unit price remains correct")
    Eq(h.queue.stats.failed, 0); Eq(h.queue.running, false, "lane released")
end)
Test("inflight takeover preserves reservation until original timeout", function()
    local h = Boot(); assert(h:quote("trade:1", 101)); h:untilSearch()
    local oldRequest = h.query.pending; local deadline = h.tasks[h.query.timeoutTask].at
    h:open(true); h:searched({Row(101, 10)}); h:advance(1000)
    Eq(h.query.pending, oldRequest, "untokened callback cannot free drain reservation")
    Eq(h:count("GetSearchedItemCount"), 0, "discard row read")
    h.visible = false; h:advance(math.max(0, deadline - h.now - 1))
    Eq(h:count("SearchAuctionArticle"), 1, "no reuse before original drain deadline")
    h:advance(4000); Eq(h:count("SearchAuctionArticle"), 2, "one fresh search after drain")
    h:searched({Row(101, 900)}); h:advance(2000)
    Eq(#h.deliveries, 1); Eq(h.deliveries[1].price, 90, "old/foreign price not persisted")
end)
Test("surface open event invalidates even when closed again before next drain", function()
    local h = Boot(); assert(h:quote("trade:1", 101)); h:untilSearch()
    h:open(true); h.visible = false; h:searched({Row(101, 10)})
    Eq(h:count("GetSearchedItemCount"), 0, "lost ownership remains lost after close")
    Eq(h.query:GetSnapshot("price_quote_fallback").status, "interrupted")
end)
Test("cancel last watcher during pause removes queue work and callbacks", function()
    local h = Boot(); h:open(); assert(h:quote("trade:1", 101)); h:advance(10000)
    h.queue:CancelRequester("trade:1"); Eq(h.queue.running, false); Eq(h.queue.pending, nil)
    h.visible = false; h:advance(20000); Eq(h:count("SearchAuctionArticle"), 0); Eq(#h.deliveries, 0)
    Eq(h.queue:GetActivitySnapshot().paused, false, "idle cannot remain paused")
end)
Test("shared watcher cancellation does not cancel survivor or cached cost", function()
    local h = Boot(); h.queue.pricesByItemType[101] = { price=70, itemGrade=1, completedAt=h.now }
    h:open(); assert(h:quote("trade:1", 101)); assert(h:quote("trade:2", 101)); h:advance(30000)
    h.queue:CancelRequester("trade:1"); Eq(h.queue.pricesByItemType[101].price, 70, "good cost retained")
    -- 维护（auction-full-lane-safety-1）：保留共享 watcher/缓存断言，同时检查整条协议暂停。
    Eq(h:count("AskMarketPrice"), 0); Eq(h:count("GetLowestPrice"), 0)
    h.visible = false; h:untilSearch(); h:searched({Row(101, 900)}); h:advance(2000)
    Eq(#h.deliveries, 1); Eq(h.deliveries[1].requester, "trade:2"); Eq(h.deliveries[1].price, 90)
end)
-- 维护（auction-full-lane-safety-1）：稳定 ID 不等于独立原生资源；开窗不发包，关窗仍须得到真实价。
Test("stable-ID quotes pause while native is open and recover without moving native search", function()
    local h = Boot(); h:open(); h.lowest[101] = 77
    assert(h:quote("trade:1", 101)); h:advance(5000)
    Eq(h:count("AskMarketPrice"), 0); Eq(h:count("GetLowestPrice"), 0); Eq(#h.deliveries, 0)
    h.visible = false; h:advance(10000)
    Eq(h:count("SearchAuctionArticle"), 0); Eq(#h.deliveries, 1); Eq(h.deliveries[1].price, 77)
    Eq(h.textWrites, 0)
end)
Test("query admission rechecks visibility immediately before native search", function()
    local h = Boot(); h.onVisibilityRead = function(n) if n >= 2 then h.visible = true end end
    assert(h:quote("trade:1", 101)); h:advance(20000)
    Eq(h:count("SearchAuctionArticle"), 0, "last-boundary visibility fence")
    Eq(#h.deliveries, 0, "admission pause is not failed quote")
end)
Test("late old timeout cannot complete a new explicit search", function()
    local h = Boot(); assert(h.query:Search("tools_auction", "first", {}))
    local oldTimeout = h.tasks[h.query.timeoutTask].fn
    h:searched({Row(101)}); assert(h.query:Search("tools_auction", "second", {}))
    local second = h.query.pending; oldTimeout()
    Eq(h.query.pending, second, "request-bound timeout")
    Eq(h.query:GetSnapshot("tools_auction").status, "waiting")
end)
Test("synchronous completion leaves no orphan timeout", function()
    local h = Boot(); h.syncComplete = true; h.rows = {Row(101)}
    assert(h.query:Search("tools_auction", "material", {}))
    Eq(h.query.pending, nil); Eq(h.tasks[h.query.timeoutTask], nil, "no post-completion timer")
    Eq(h.query:GetSnapshot("tools_auction").status, "ready")
end)
Test("timeout registration failure sends no unguarded native request", function()
    local h = Boot(); h.rejectTimeout = true
    local ok = h.query:Search("tools_auction", "material", {})
    Eq(ok, false); Eq(h:count("SearchAuctionArticle"), 0, "safety before side effect")
    Eq(h.query.pending, nil); Eq(h.query.eventBound, false)
end)
Test("missing Surface contract cannot authorize a background name search", function()
    local h = Boot(); h.S.Services.AuctionSurfaceV3 = nil
    local ok = h.query:Search("price_quote_fallback", "material", { background = true })
    Eq(ok, false); Eq(h:count("SearchAuctionArticle"), 0)
    assert(h.query:Search("tools_auction", "user", {}), "explicit user search must not require visibility proof")
end)
Test("genuine hidden empty search remains a real terminal result", function()
    local h = Boot(); assert(h:quote("trade:1", 101)); h:untilSearch(); h:searched({}); h:advance(2000)
    Eq(#h.deliveries, 1); Eq(h.deliveries[1].status, "unavailable"); Eq(h.queue.stats.failed, 1)
end)
Test("activity state is detached and never a completion event", function()
    local h = Boot(); h:open(); assert(h:quote("trade:1", 101)); h:advance(15000)
    local state = h.queue:GetActivitySnapshot(); Eq(state.paused, true); state.paused = false
    Eq(h.queue:GetActivitySnapshot().paused, true, "detached read model")
    local completionCount, activityCount = 0, 0
    for _, event in ipairs(h.events) do
        if event.topic == h.queue.Topic then completionCount = completionCount + 1 end
        if event.topic == h.queue.ActivityTopic then activityCount = activityCount + 1 end
    end
    Eq(completionCount, 0, "pause does not finish Trade materials"); Eq(activityCount, 1, "transition-only event")
    local calls, reads = #h.calls, h.visibilityReads
    h.queue:Describe(); h.queue:GetActivitySnapshot()
    Eq(#h.calls, calls); Eq(h.visibilityReads, reads, "diagnostics do not probe Native")
end)
Test("cancel takeover pending keeps only bounded native drain", function()
    local h = Boot(); assert(h:quote("trade:1", 101)); h:untilSearch(); h:open(); h:advance(1000)
    h.queue:CancelRequester("trade:1"); Eq(h.queue.running, false); Eq(h.tasks[h.queue.taskName], nil)
    h:advance(10000); Eq(h.query.pending, nil); Eq(h.query.eventBound, false); Eq(#h.deliveries, 0)
    Eq(h.tasks[h.query.timeoutTask], nil)
end)

Test("cancel before takeover cannot resurrect a watcherless fallback", function()
    local h = Boot(); assert(h:quote("trade:1", 101)); h:untilSearch()
    h.queue:CancelRequester("trade:1") -- in-flight owner must initially stay until settlement
    h:open(); h:advance(20000)
    Eq(h.queue.running, false, "watcherless pause releases recurring lane")
    Eq(h.queue.pending, nil); Eq(#h.deliveries, 0)
    h.visible = false; h:advance(20000); Eq(h:count("SearchAuctionArticle"), 1, "cancelled work never resumes")
end)
Test("late old Native callback cannot read results for a replacement request", function()
    local h = Boot(); assert(h.query:Search("tools_auction", "old", {}))
    local oldHandler = h.native["AUCTION_ITEM_SEARCHED"][h.query.owner]
    h:searched({Row(101)}); assert(h.query:Search("tools_auction", "new", {}))
    local before = h:count("GetSearchedItemCount"); local pending = h.query.pending
    oldHandler(h.query.owner)
    Eq(h.query.pending, pending); Eq(h:count("GetSearchedItemCount"), before)
end)
Test("read-only visibility excludes visible UIParent as auction evidence", function()
    local h = Boot(); h.omitVisibility = true
    local parent = { IsVisible = function() return true end, GetParent = function() return nil end }
    _G.UIParent = parent
    h.content.GetParent = function() return parent end
    local known, visible = h.surface:ReadVisibility()
    Eq(known, true); Eq(visible, false, "desktop visibility is not auction visibility")
    _G.UIParent = nil
end)

Test("non-boolean content visibility never proves native auction closed", function()
    for _, mode in ipairs({ "nil", "number", "string" }) do
        local h = Boot()
        _G.ADDON.GetContentMainScriptPosVis = function() return nil, nil, nil, nil end
        h.content.IsVisible = function()
            if mode == "number" then return 0 end
            if mode == "string" then return "false" end
            return nil
        end
        local known = h.surface:ReadVisibility()
        Eq(known, false, "unknown Native shape: " .. mode)
        assert(h:quote("trade:1", 101)); h:advance(20000)
        Eq(h:count("SearchAuctionArticle"), 0, "uncertain visibility must not replace user results")
        Eq(#h.deliveries, 0, "uncertainty is not a terminal failure")
    end
end)

print(string.format("AUCTION_USER_PRIORITY: %d/%d passed (%s)", passed, total, _VERSION))
assert(passed == total, "auction user-priority regression failure")

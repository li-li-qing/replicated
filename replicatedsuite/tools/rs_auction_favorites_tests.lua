------------------------------------------------------------------------
-- Replicated Suite V3 - Auction Favorites & Query Test Suite (B9)
--
-- Tests AuctionFavorites Feature, AuctionQueryV3 service, AuctionSurfaceV3,
-- bounded favorites mutations, 9-parameter search, itemGrade extraction,
-- paging logic, explicit PriceQuoteQueueV3 quotes, sidecar lifecycle,
-- and FoundationGate / Acceptance contract clauses.
------------------------------------------------------------------------

unpack = unpack or table.unpack
if not math.frexp then math.frexp = function(x) if x == 0 then return 0, 0 end local e = math.floor(math.log(math.abs(x)) / math.log(2)) + 1 return x / (2^e), e end end
if not math.ldexp then math.ldexp = function(m, e) return m * (2^e) end end

local passed, total = 0, 0
local function Test(name, fn)
    total = total + 1
    local ok, err = xpcall(fn, debug.traceback)
    if ok then
        passed = passed + 1
        print(string.format("  PASS [%02d] %s", total, name))
    else
        print(string.format("  FAIL [%02d] %s: %s", total, name, tostring(err)))
    end
end

print("=== Replicated Suite: Auction Favorites & Query Tests ===")

local h = dofile("tools/rs_gear_page_test_host.lua")({})
local S = h.S
S.UI = S.UI or {}
S.UI.SetAnchor = function() return true end
S.UI.CreateWindowShell = function(self, spec)
    local mockWin = {}
    return {
        window = mockWin,
        windowController = {
            IsInteracting = function() return false end,
        },
        GetContentRoot = function() return {} end,
        GetContentComponent = function() return {} end,
        GetNativeContentRoot = function() return {} end,
        GetWindow = function() return mockWin end,
        SetTitle = function() return true end,
        SetStatus = function() return true end,
        SetFooter = function() return true end,
        SetMinSize = function() return true end,
        SetMaxSize = function() return true end,
        SetResizable = function() return true end,
        SetCloseHandler = function() return true end,
        SetMinimizeHandler = function() return true end,
        SetLockHandler = function() return true end,
        SetOpacity = function() return true end,
        SetOverallOpacity = function() return true end,
        SetBackgroundOpacity = function() return true end,
        SetTextOpacity = function() return true end,
        SetFontScale = function() return true end,
        SetMinimized = function() return true end,
        SetLocked = function() return true end,
        IsLocked = function() return false end,
        SetExtent = function() return true end,
        Layout = function() return true end,
        Show = function() return true end,
        Hide = function() return true end,
        Close = function() return true end,
    }
end

-- Layout context mock
S.Layout = S.Layout or {}
S.Layout.GetContext = function()
    return { logicalWidth = 1920, logicalHeight = 1080, safeLeft = 0, safeTop = 0, safeRight = 0, safeBottom = 0 }
end
S.Layout.GetLogicalRect = function(node)
    if type(node) == "table" and node.rect then
        return node.rect.x, node.rect.y, node.rect.w, node.rect.h
    end
    return 100, 100, 800, 600
end
S.Layout.ResolvePlacement = function(self, state, w, h, dx, dy, options)
    local x = tonumber(state and state.x) or dx or 0
    local y = tonumber(state and state.y) or dy or 0
    return x, y
end

-- Native UI mock
local mockAuctionContent = {
    IsVisible = function() return true end,
    GetParent = function() return nil end,
    rect = { x = 200, y = 150, w = 820, h = 600 },
}

_G.ADDON = _G.ADDON or {}
_G.ADDON.GetContent = function(self, id)
    if id == 9999 or id == "UIC_AUCTION" then return mockAuctionContent end
    return nil
end
_G.ADDON.GetContentMainScriptPosVis = function(self, id)
    return 200, 150, 820, 600, true
end
_G.UIC_AUCTION = 9999
_G.UIC_BAG = 9998

-- Mock X2Auction
local mockAuction
mockAuction = {
    searchCalls = {},
    searchedItems = {},
    SearchAuctionArticle = function(self, page, minLevel, maxLevel, category, subCategory, exact, keyword, minPrice, maxPrice)
        table.insert(mockAuction.searchCalls, {
            page = page, minLevel = minLevel, maxLevel = maxLevel,
            category = category, subCategory = subCategory, exact = exact,
            keyword = keyword, minPrice = minPrice, maxPrice = maxPrice,
        })
        return true
    end,
    GetSearchedItemCount = function(self)
        return #mockAuction.searchedItems
    end,
    GetSearchedItemInfo = function(self, index)
        return mockAuction.searchedItems[index]
    end,
    GetLowestPrice = function(self, itemType, grade)
        return 125000 -- 12g 50s
    end,
}
_G.X2Auction = mockAuction

-- Allow API capabilities
S.Api.allowedCapabilities = S.Api.allowedCapabilities or {}
S.Api.allowedCapabilities["X2Auction:SearchAuctionArticle"] = true
S.Api.allowedCapabilities["X2Auction:GetSearchedItemCount"] = true
S.Api.allowedCapabilities["X2Auction:GetSearchedItemInfo"] = true
S.Api.allowedCapabilities["X2Auction:GetLowestPrice"] = true
S.Api.allowedCapabilities["ADDON:GetContent"] = true
S.Api.allowedCapabilities["ADDON:GetContentMainScriptPosVis"] = true

_G.ReplicatedSuite = S
S.Features = S.Features or {}
S.Services = S.Services or {}

-- Load foundation and data modules in correct dependency order
dofile("data/rs_data_registry.lua")
dofile("data/ids/rs_item_ids.lua")
dofile("data/ids/rs_quest_ids.lua")
dofile("core/rs_constants.lua")
dofile("core/rs_demand.lua")
dofile("core/rs_foundation_gate.lua")
dofile("features/rs_feature_registry.lua")
dofile("features/rs_feature_runtime.lua")

-- Services
dofile("services/rs_price_quote_queue_v3.lua")
dofile("services/rs_auction_query_v3.lua")
dofile("services/rs_auction_surface_v3.lua")

-- Business bridge (defines tools_auction and tools_market_analysis)
dofile("features/rs_business_bridge.lua")

-- UI Framework and WidgetHost for Sidecar
S.RSUI = S.RSUI or {}
local function ParseSpec(a, b)
    if type(b) == "table" then return b end
    if type(a) == "table" then return a end
    return {}
end
S.RSUI.VerticalBox = function(self, spec) return {} end
S.RSUI.HorizontalBox = function(self, spec) return {} end
S.RSUI.TextInput = function(self, spec)
    spec = ParseSpec(self, spec)
    local inp = { spec = spec, val = spec.value or "" }
    function inp:GetDraftValue() return self.val end
    function inp:SetValue(v) self.val = v end
    return inp
end
S.RSUI.Button = function(self, spec)
    spec = ParseSpec(self, spec)
    local btn = { spec = spec, enabled = true, text = spec.text or "" }
    function btn:SetText(t) self.text = t end
    function btn:SetEnabled(e) self.enabled = e end
    return btn
end
S.RSUI.Text = function(self, spec)
    spec = ParseSpec(self, spec)
    local txt = { spec = spec, text = spec.text or "" }
    function txt:SetText(t) self.text = t end
    return txt
end
S.RSUI.TableView = function(self, spec)
    spec = ParseSpec(self, spec)
    local tv = { spec = spec, items = {}, viewState = "ready" }
    function tv:SetItems(items, rev) self.items = items or {}; self.rev = rev end
    function tv:SetViewState(state, info) self.viewState = state; self.viewInfo = info end
    function tv:GetItem(idx) return self.items[idx] end
    return tv
end

dofile("ui/framework/rs_ui_floating_surface.lua")

S.UIV3 = S.UIV3 or {}
S.UIV3.WidgetHost = {
    specs = {},
    visibleWidgets = {},
    instances = {},
    Register = function(self, id, spec)
        self.specs[id] = spec
        return true
    end,
    GetSpec = function(self, id) return self.specs[id] end,
    IsVisible = function(self, id) return self.visibleWidgets[id] == true end,
    SetVisible = function(self, id, visible, ctx)
        self.visibleWidgets[id] = visible == true
        if visible and not self.instances[id] and self.specs[id] then
            local inst = self.specs[id].create()
            self.instances[id] = inst
        end
        local inst = self.instances[id]
        if inst then
            if visible then inst:Show(ctx) else inst:Hide() end
        end
        return true
    end,
    GetInstance = function(self, id) return self.instances[id] end,
    NotifyWindowClosed = function(self, id, ctx)
        self.visibleWidgets[id] = false
        return true
    end,
}

-- Load sidecar widget
dofile("presentation/v3/widgets/rs_v3_auction_sidecar.lua")

local Feature = S.Features.tools_auction
local Query = S.Services.AuctionQueryV3
local Surface = S.Services.AuctionSurfaceV3
local QuoteQueue = S.Services.PriceQuoteQueueV3

------------------------------------------------------------------------
-- Test 1: Feature Registry Metadata & Contracts
------------------------------------------------------------------------
Test("T1: Feature registry metadata & contracts", function()
    local reg = S.FeatureRegistry:Get("tools_auction")
    assert(reg ~= nil, "tools_auction must be in FeatureRegistry")
    assert(reg.id == "tools_auction", "id mismatch")
    assert(reg.route == "tools.auction_favorites", "route mismatch")
    assert(reg.name == "拍卖收藏", "name mismatch")
    assert(reg.category == "tools", "category mismatch")
    assert(reg.authority == "v3.auction", "authority mismatch")
    assert(reg.apiPolicy == "explicit_server_query_plus_readonly_native_surface_observation", "apiPolicy mismatch")

    -- Check required API dependencies
    local deps = reg.apiDependencies
    assert(#deps >= 6, "Must declare at least 6 API dependencies")
    local hasSearch, hasLowest, hasPosVis = false, false, false
    for _, d in ipairs(deps) do
        if d == "X2Auction:SearchAuctionArticle" then hasSearch = true end
        if d == "X2Auction:GetLowestPrice" then hasLowest = true end
        if d == "ADDON:GetContentMainScriptPosVis" then hasPosVis = true end
    end
    assert(hasSearch, "X2Auction:SearchAuctionArticle dependency missing")
    assert(hasLowest, "X2Auction:GetLowestPrice dependency missing")
    assert(hasPosVis, "ADDON:GetContentMainScriptPosVis dependency missing")

    -- Check Feature implementation
    assert(Feature ~= nil, "tools_auction Feature missing from S.Features")
    assert(Feature.AuctionQueryContractVersion >= 1, "AuctionQueryContractVersion >= 1 missing")
    assert(type(Feature.Commands) == "table", "Feature.Commands table missing")
    assert(type(Feature.Commands.Search) == "function", "Commands.Search missing")
    assert(type(Feature.Commands.AddFavorite) == "function", "Commands.AddFavorite missing")
    assert(type(Feature.Commands.RemoveFavorite) == "function", "Commands.RemoveFavorite missing")
    assert(type(Feature.Commands.Quote) == "function", "Commands.Quote missing")
    assert(type(Feature.Commands.SetExactMatch) == "function", "Commands.SetExactMatch missing")
    assert(type(Feature.Commands.SetResultLimit) == "function", "Commands.SetResultLimit missing")
end)

------------------------------------------------------------------------
-- Test 2: Favorite Keywords: Add, Deduplication, Bounds & Remove
------------------------------------------------------------------------
Test("T2: Favorite keywords: Add, deduplication, bounds & Remove", function()
    Feature:Enable()
    assert(Feature:AcquireConsumer("test_t2"), "AcquireConsumer failed")

    -- Clean slate
    Feature.State.favorites = {}

    -- 1. Add valid favorite
    local ok, err = Feature.Commands:AddFavorite("铁锭")
    assert(ok == true, "AddFavorite failed: " .. tostring(err))
    assert(#Feature.State.favorites == 1, "Favorites count should be 1")
    assert(Feature.State.favorites[1] == "铁锭", "First favorite mismatch")

    -- 2. Deduplication check: re-adding "铁锭" must fail
    local dupOk, dupErr = Feature.Commands:AddFavorite("铁锭")
    assert(dupOk == false, "Re-adding duplicate favorite should fail")
    assert(tostring(dupErr):find("已存在") ~= nil, "Error message must mention already exists")
    assert(#Feature.State.favorites == 1, "Favorites count should still be 1")

    -- 3. Validation: empty or whitespace
    local emptyOk, emptyErr = Feature.Commands:AddFavorite("   ")
    assert(emptyOk == false, "Empty keyword must be rejected")
    local controlOk, _ = Feature.Commands:AddFavorite("test\nitem")
    assert(controlOk == false, "Control characters must be rejected")

    -- 4. Upper bound: AUCTION_FAVORITE_MAX = 20
    for i = 2, 20 do
        local addOk = Feature.Commands:AddFavorite("材料_" .. tostring(i))
        assert(addOk == true, "Adding favorite " .. tostring(i) .. " should succeed")
    end
    assert(#Feature.State.favorites == 20, "Should have reached 20 favorites")
    local overOk, overErr = Feature.Commands:AddFavorite("材料_21")
    assert(overOk == false, "21st favorite must be rejected due to max limit")
    assert(tostring(overErr):find("上限") ~= nil, "Error should mention upper bound")

    -- 5. RemoveFavorite
    local remInvalidOk = Feature.Commands:RemoveFavorite(999)
    assert(remInvalidOk == false, "Out of bounds index must be rejected")
    local remOk, remErr = Feature.Commands:RemoveFavorite(1) -- Remove "铁锭"
    assert(remOk == true, "RemoveFavorite(1) failed: " .. tostring(remErr))
    assert(#Feature.State.favorites == 19, "Favorites count should now be 19")
    assert(Feature.State.favorites[1] == "材料_2", "New first favorite should be 材料_2")

    -- 6. Check projection
    local proj = Feature:GetProjection()
    assert(proj.favoriteCount == 19, "proj.favoriteCount mismatch")
    assert(proj.favoriteMax == 20, "proj.favoriteMax mismatch")

    -- Cleanup
    Feature.State.favorites = { "原木", "粗糙的石头" }
    Feature:ReleaseConsumer("test_t2")
end)

------------------------------------------------------------------------
-- Test 3: AuctionQueryV3: 9-Parameter Call, SingleFlight & Timeout Guard
------------------------------------------------------------------------
Test("T3: AuctionQueryV3: 9-parameter call, SingleFlight & timeout guard", function()
    -- Reset query state
    Query:_CleanupNativeEdge()
    Query.pending = nil
    mockAuction.searchCalls = {}

    -- 1. Input validation
    local badReqOk = Query:Search("", "keyword")
    assert(badReqOk == false, "Empty requester must be rejected")
    local badKeyOk = Query:Search("test", "")
    assert(badKeyOk == false, "Empty keyword must be rejected")

    -- 2. Successful search dispatch with 9-parameter contract
    local ok, status = Query:Search("tools_auction", "原木", { exactMatch = true, resultLimit = 15 })
    assert(ok == true, "Query:Search failed: " .. tostring(status))
    assert(status == "waiting", "Status must be waiting")
    assert(#mockAuction.searchCalls == 1, "Must have called SearchAuctionArticle once")

    local call = mockAuction.searchCalls[1]
    assert(call.page == 1, "page must be 1")
    assert(call.minLevel == 0 and call.maxLevel == 55, "level range must be 0-55")
    assert(call.category == 1 and call.subCategory == 0, "category must be 1, 0")
    assert(call.exact == true, "exactMatch must be true")
    assert(call.keyword == "原木", "keyword mismatch")
    assert(call.minPrice == "0" and call.maxPrice == "0", "prices must be '0', '0'")

    -- 3. SingleFlight rejection while waiting
    local dupOk, dupErr = Query:Search("tools_auction", "铁锭")
    assert(dupOk == false, "Concurrent search while pending must be rejected")
    assert(tostring(dupErr):find("等待") ~= nil, "Rejection error must mention pending search")

    -- 4. Timeout guard
    assert(Query.pending ~= nil, "Must have pending request")
    assert(S.Scheduler.tasks[Query.timeoutTask] ~= nil, "Timeout task must be scheduled")
    -- Simulate timeout execution
    local timeoutTask = S.Scheduler.tasks[Query.timeoutTask]
    timeoutTask.callback()
    assert(Query.pending == nil, "Pending must be cleared after timeout")
    local snap = Query:GetSnapshot("tools_auction")
    assert(snap.status == "failed", "Snapshot status must be failed after timeout")
    assert(tostring(snap.error):find("超时") ~= nil, "Snapshot error must mention timeout")
end)

------------------------------------------------------------------------
-- Test 4: Native AUCTION_ITEM_SEARCHED Completion Edge & Normalization
------------------------------------------------------------------------
Test("T4: Native AUCTION_ITEM_SEARCHED completion edge & normalization", function()
    Query:_CleanupNativeEdge()
    Query.pending = nil
    mockAuction.searchCalls = {}

    -- Case A: Empty results (0 items)
    mockAuction.searchedItems = {}
    local okA = Query:Search("tools_auction", "稀有不存在物品")
    assert(okA == true)
    -- Fire native completion edge
    Query:_OnSearched()
    local snapA = Query:GetSnapshot("tools_auction")
    assert(snapA.status == "empty", "0 items should result in status = empty")
    assert(snapA.count == 0, "count should be 0")
    assert(#snapA.rows == 0, "rows should be empty")

    -- Case B: Multiple results with diverse fields including itemGrade
    mockAuction.searchedItems = {
        {
            itemType = 18888,
            name = "原木",
            itemGrade = 3, -- 稀有
            count = 100,
            directPrice = 50000, -- 5g 一口价
            bidPrice = 45000,
            seller = "LoggerOne",
        },
        {
            itemInfo = {
                itemTypeId = 18889,
                itemName = "铁锭",
                grade = 1, -- 普通
                amount = 20,
                buyoutPriceStr = "30000",
                currentBidPrice = 25000,
                sellerName = "MinerTwo",
            }
        },
    }

    local okB = Query:Search("tools_auction", "建筑材料", { resultLimit = 20 })
    assert(okB == true)
    Query:_OnSearched()
    local snapB = Query:GetSnapshot("tools_auction")
    assert(snapB.status == "ready", "Status must be ready")
    assert(snapB.count == 2, "Count should be 2")
    assert(#snapB.rows == 2, "Rows count should be 2")

    -- Row 1 check
    local r1 = snapB.rows[1]
    assert(r1.itemType == 18888, "r1 itemType mismatch")
    assert(r1.itemGrade == 3, "r1 itemGrade must be extracted as 3")
    assert(r1.name == "原木", "r1 name mismatch")
    assert(r1.quantity == 100, "r1 quantity mismatch")
    assert(r1.directPrice == 50000, "r1 directPrice mismatch")
    assert(r1.bidPrice == 45000, "r1 bidPrice mismatch")
    assert(r1.seller == "LoggerOne", "r1 seller mismatch")
    assert(r1.text:find("数量 100") ~= nil, "r1 text must contain quantity")
    assert(r1.text:find("一口价 50000") ~= nil, "r1 text must contain buyout price")

    -- Row 2 check (nested itemInfo extraction)
    local r2 = snapB.rows[2]
    assert(r2.itemType == 18889, "r2 nested itemType mismatch")
    assert(r2.itemGrade == 1, "r2 nested itemGrade must be extracted as 1")
    assert(r2.name == "铁锭", "r2 nested name mismatch")
    assert(r2.quantity == 20, "r2 nested quantity mismatch")
    assert(r2.directPrice == 30000, "r2 nested buyoutPriceStr mismatch")
    assert(r2.seller == "MinerTwo", "r2 nested seller mismatch")
end)

------------------------------------------------------------------------
-- Test 5: Feature Demand Lifecycle & Dual Favorite/Result Rows Projection
------------------------------------------------------------------------
Test("T5: Feature demand lifecycle & dual favorite/result rows projection", function()
    -- Ensure clean demand state before T5
    S.Events:Publish("v3.auction_surface.updated", { status = "ready", visible = false })
    for token in pairs(Feature.Demand and Feature.Demand.consumers or {}) do
        Feature:ReleaseConsumer(token)
    end
    Feature:Enable()
    assert(Feature.enabled == true, "Feature must be enabled")

    -- Initial state before acquiring consumer
    assert(Feature.AuctionQuerySubscribed ~= true, "Must not subscribe before consumer acquired")

    -- Acquire consumer: activates Demand and subscribes to events
    assert(Feature:AcquireConsumer("test_t5"), "AcquireConsumer failed")
    assert(Feature.consumerCount == 1, "consumerCount should be 1")
    assert(Feature.AuctionQuerySubscribed == true, "Must subscribe to v3.auction_query.updated")
    assert(Feature.PriceQuoteSubscribed == true, "Must subscribe to v3.price_quote.completed")

    -- Set up favorites and execute search
    Feature.State.favorites = { "原木", "铁矿石" }
    local okSearch = Feature.Commands:Search("原木")
    assert(okSearch == true, "Feature.Commands:Search failed")
    assert(Feature.State.searchStatus == "waiting", "searchStatus should be waiting")

    -- Complete search
    Query:_OnSearched()
    Feature.Authority:Refresh("auction_query_updated")

    -- Verify projection contains both favorites and search results
    local proj = Feature:GetProjection()
    assert(proj.favoriteCount == 2, "favoriteCount should be 2")
    assert(proj.searchStatus == "ready", "searchStatus should be ready")
    assert(proj.resultCount == 2, "resultCount should be 2")

    -- Read rows from authority/projection
    local rows = proj.rows
    assert(#rows == 4, "Total rows must be 4 (2 favorites + 2 results)")
    assert(rows[1].kind == "favorite" and rows[1].name == "原木", "Row 1 must be favorite")
    assert(rows[2].kind == "favorite" and rows[2].name == "铁矿石", "Row 2 must be favorite")
    assert(rows[3].kind == "result" and rows[3].itemType == 18888, "Row 3 must be search result")
    assert(rows[4].kind == "result" and rows[4].itemType == 18889, "Row 4 must be search result")

    -- Release consumer: tears down subscriptions
    Feature:ReleaseConsumer("test_t5")
    assert(Feature.consumerCount == 0, "consumerCount should be 0")
    assert(Feature.AuctionQuerySubscribed == false, "Must unsubscribe from v3.auction_query.updated")
    assert(Feature.PriceQuoteSubscribed == false, "Must unsubscribe from v3.price_quote.completed")
end)

------------------------------------------------------------------------
-- Test 6: Bounded Paging Calculation
------------------------------------------------------------------------
Test("T6: Bounded paging calculation (25 items, 10 per page)", function()
    -- Mock 25 items in rows
    local dummyRows = {}
    for i = 1, 25 do
        dummyRows[#dummyRows + 1] = { key = "item:" .. i, index = i, name = "Item_" .. i }
    end

    local pageSize = 10
    local total = #dummyRows

    local function ComputePage(pageNo)
        local pagesCount = math.max(1, math.ceil(total / pageSize))
        local clampedPage = math.max(1, math.min(pageNo, pagesCount))
        local first = (clampedPage - 1) * pageSize + 1
        local last = math.min(first + pageSize - 1, total)
        local pageRows = {}
        for i = first, last do pageRows[#pageRows + 1] = dummyRows[i] end
        return clampedPage, pagesCount, pageRows, clampedPage > 1, clampedPage < pagesCount
    end

    -- Page 1
    local p1, totalPages, r1, canPrev1, canNext1 = ComputePage(1)
    assert(p1 == 1 and totalPages == 3, "Page 1 count mismatch")
    assert(#r1 == 10, "Page 1 should have 10 rows")
    assert(r1[1].index == 1 and r1[10].index == 10, "Page 1 bounds mismatch")
    assert(canPrev1 == false, "Page 1 cannot prev")
    assert(canNext1 == true, "Page 1 can next")

    -- Page 2
    local p2, _, r2, canPrev2, canNext2 = ComputePage(2)
    assert(p2 == 2, "Page 2 mismatch")
    assert(#r2 == 10, "Page 2 should have 10 rows")
    assert(r2[1].index == 11 and r2[10].index == 20, "Page 2 bounds mismatch")
    assert(canPrev2 == true and canNext2 == true, "Page 2 prev/next mismatch")

    -- Page 3 (Partial page: 5 rows)
    local p3, _, r3, canPrev3, canNext3 = ComputePage(3)
    assert(p3 == 3, "Page 3 mismatch")
    assert(#r3 == 5, "Page 3 should have 5 rows")
    assert(r3[1].index == 21 and r3[5].index == 25, "Page 3 bounds mismatch")
    assert(canPrev3 == true and canNext3 == false, "Page 3 cannot next")

    -- Out of bounds clamping: requesting page 99 clamps to page 3
    local p99, _, r99 = ComputePage(99)
    assert(p99 == 3, "Page 99 must clamp to max page 3")
    assert(#r99 == 5, "Clamped page rows mismatch")
end)

------------------------------------------------------------------------
-- Test 7: Explicit Lowest-Price Quote via PriceQuoteQueueV3
------------------------------------------------------------------------
Test("T7: Explicit lowest-price quote via PriceQuoteQueueV3", function()
    Feature:Enable()
    Feature:AcquireConsumer("test_t7")

    -- Verify Quote command delegates to PriceQuoteQueueV3
    assert(type(Feature.Commands.Quote) == "function", "Commands.Quote missing")

    local ok, status = Feature.Commands:Quote(18888, 3)
    assert(ok == true, "Commands:Quote failed: " .. tostring(status))

    -- Check PriceQuoteQueueV3 snapshot for tools_auction
    local quoteSnap = QuoteQueue:GetSnapshot("tools_auction")
    assert(quoteSnap ~= nil, "Quote snapshot missing")
    assert(quoteSnap.itemType == 18888, "itemType mismatch in queue")
    assert((quoteSnap.itemGrade or quoteSnap.grade) == 3, "grade mismatch in queue")

    -- Advance scheduler / process queue item
    local taskKey = QuoteQueue.taskId or QuoteQueue.taskName
    assert(S.Scheduler.tasks[taskKey] ~= nil, "Quote task must be scheduled")
    local quoteTask = S.Scheduler.tasks[taskKey]
    quoteTask.callback()

    -- Completed quote should have recorded the mock lowest price (125000 = 12g 50s)
    local compSnap = QuoteQueue:GetSnapshot("tools_auction")
    assert(compSnap.status == "ready", "Quote status should be ready after processing")
    assert(compSnap.price == 125000, "Lowest price should be 125000, got: " .. tostring(compSnap.price))

    -- Projection should reflect the quote result
    local proj = Feature:GetProjection()
    assert(proj.quoteStatus == "ready", "Projection quoteStatus mismatch")
    assert(proj.quotePrice == 125000, "Projection quotePrice mismatch")

    Feature:ReleaseConsumer("test_t7")
end)

------------------------------------------------------------------------
-- Test 8: AuctionSurfaceV3: 5-Value & 4-Value Native Geometry & Cleanup
------------------------------------------------------------------------
Test("T8: AuctionSurfaceV3: 5-value & 4-value native geometry & cleanup", function()
    Surface:Stop("test_init")
    assert(Surface.started == false, "Must be stopped initially")

    -- 1. Start observer
    local okStart, errStart = Surface:Start()
    assert(okStart == true, "Surface:Start failed: " .. tostring(errStart))
    assert(Surface.started == true, "started must be true")
    assert(S.Scheduler.tasks[Surface.taskId] ~= nil, "Observer task must be registered in Scheduler")

    -- 2. 5-value native return: (x, y, width, height, visible)
    _G.ADDON.GetContentMainScriptPosVis = function(self, id)
        return 300, 200, 750, 550, true
    end
    Surface:Refresh("test_5val", true)
    local snap5 = Surface:GetSnapshot()
    assert(snap5.status == "ready", "snap5 status mismatch")
    assert(snap5.visible == true, "snap5 visible mismatch")
    assert(snap5.x == 300 and snap5.y == 200, "snap5 position mismatch")
    assert(snap5.width == 750 and snap5.height == 550, "snap5 size mismatch")
    assert(snap5.source == "main-script", "snap5 source should be main-script")

    -- 3. RU 4-value compatibility: (x, y, width, height, nil)
    -- Omit the 5th boolean, relying on plausible geometry and content visibility
    _G.ADDON.GetContentMainScriptPosVis = function(self, id)
        return 320, 210, 750, 550 -- 5th return value is nil
    end
    Surface:Refresh("test_4val", true)
    local snap4 = Surface:GetSnapshot()
    assert(snap4.status == "ready", "snap4 status mismatch")
    assert(snap4.visible == true, "snap4 visible must resolve to true from content/geometry")
    assert(snap4.x == 320 and snap4.y == 210, "snap4 position mismatch")

    -- 4. Closed state: content hidden
    mockAuctionContent.IsVisible = function() return false end
    _G.ADDON.GetContentMainScriptPosVis = function(self, id)
        return 0, 0, 0, 0, false
    end
    Surface:Refresh("test_closed", true)
    local snapClosed = Surface:GetSnapshot()
    assert(snapClosed.visible == false, "snapClosed must be invisible")

    -- Restore mock
    mockAuctionContent.IsVisible = function() return true end
    _G.ADDON.GetContentMainScriptPosVis = function(self, id)
        return 200, 150, 820, 600, true
    end

    -- 5. Stop cleanup
    Surface:Stop("test_teardown")
    assert(Surface.started == false, "started must be false after Stop")
    assert(S.Scheduler.tasks[Surface.taskId] == nil, "Scheduler task must be removed after Stop")
end)

------------------------------------------------------------------------
-- Test 9: AuctionSidecar Widget: Native Window Tracking & Anchoring
------------------------------------------------------------------------
Test("T9: AuctionSidecar widget: native window tracking & anchoring", function()
    local sidecarSpec = S.UIV3.WidgetHost:GetSpec("tools.auction_sidecar")
    assert(sidecarSpec ~= nil, "tools.auction_sidecar widget spec must be registered")
    assert(sidecarSpec.featureId == "tools_auction", "featureId mismatch")

    local SidecarController = S.UIV3.AuctionSidecar
    assert(SidecarController ~= nil, "AuctionSidecar controller missing")

    -- 1. Native window opens -> Sidecar becomes visible
    local openSnapshot = { status = "ready", visible = true, x = 400, y = 200, width = 800, height = 600, revision = 10 }
    S.Events:Publish("v3.auction_surface.updated", openSnapshot)

    assert(S.UIV3.WidgetHost:IsVisible("tools.auction_sidecar") == true, "Sidecar must be visible when native auction opens")
    assert(SidecarController.nativeVisible == true, "nativeVisible must be true")

    local instance = S.UIV3.WidgetHost:GetInstance("tools.auction_sidecar")
    assert(instance ~= nil, "Sidecar instance must exist")
    assert(instance.acquired == true, "Sidecar must have acquired Consumer")

    -- 2. Anchoring check: sidecar should be placed adjacent to the auction window
    -- Window is 300px wide, auctionX is 400 -> x = 400 - 300 - 8 = 92
    assert(instance.state.x == 92, "Sidecar X coordinate should be 92, got: " .. tostring(instance.state.x))
    assert(instance.state.y == 200, "Sidecar Y coordinate should align with auction Y (200)")

    -- 3. Native window closes -> Sidecar hides
    local closeSnapshot = { status = "ready", visible = false, x = 0, y = 0, width = 0, height = 0, revision = 11 }
    S.Events:Publish("v3.auction_surface.updated", closeSnapshot)

    assert(S.UIV3.WidgetHost:IsVisible("tools.auction_sidecar") == false, "Sidecar must hide when native auction closes")
    assert(SidecarController.nativeVisible == false, "nativeVisible must be false")
    assert(instance.acquired == false, "Consumer must be released when hidden")

    -- 4. User manual close (dismissal)
    S.Events:Publish("v3.auction_surface.updated", openSnapshot)
    assert(S.UIV3.WidgetHost:IsVisible("tools.auction_sidecar") == true)
    instance.surface.spec.onClosed(instance.surface, "user_click_close")
    assert(SidecarController.dismissed == true, "dismissed flag must be set on manual close")

    -- Subsequent surface updates while still open must not resurrect dismissed sidecar
    S.Events:Publish("v3.auction_surface.updated", openSnapshot)
    assert(S.UIV3.WidgetHost:IsVisible("tools.auction_sidecar") == false, "Dismissed sidecar must not re-open while native window remains open")

    -- Native closes and reopens -> dismissed flag is cleared and sidecar resurrects
    S.Events:Publish("v3.auction_surface.updated", closeSnapshot)
    assert(SidecarController.dismissed == false, "dismissed flag must reset when native closes")
    S.Events:Publish("v3.auction_surface.updated", openSnapshot)
    assert(S.UIV3.WidgetHost:IsVisible("tools.auction_sidecar") == true, "Sidecar re-opens on fresh native auction open")

    -- Final cleanup
    S.Events:Publish("v3.auction_surface.updated", closeSnapshot)
end)

------------------------------------------------------------------------
-- Test 10: FoundationGate & Acceptance Contract Verification
------------------------------------------------------------------------
Test("T10: FoundationGate & Acceptance contract verification", function()
    -- 1. v3_auction_query_contract verification
    assert(type(Query) == "table", "Query must be table")
    assert((tonumber(Query.version) or 0) >= 2, "AuctionQueryV3 version >= 2")
    assert((tonumber(Query.EventAuthorityContractVersion) or 0) >= 1, "EventAuthorityContractVersion >= 1")
    assert(tostring(Query.presentationBoundary or "") == "service_only", "presentationBoundary == service_only")
    assert(type(Query.Search) == "function", "Query.Search must be function")
    assert(type(Query.GetSnapshot) == "function", "Query.GetSnapshot must be function")
    assert((tonumber(Feature.AuctionQueryContractVersion) or 0) >= 1, "Feature AuctionQueryContractVersion >= 1")
    assert(type(Feature.Commands.Search) == "function", "Feature Commands.Search must be function")

    local MarketFeature = S.Features.tools_market_analysis
    assert(type(MarketFeature) == "table", "tools_market_analysis Feature missing")
    assert((tonumber(MarketFeature.AuctionQueryContractVersion) or 0) >= 1, "MarketFeature AuctionQueryContractVersion >= 1")
    assert(type(MarketFeature.Commands.Search) == "function", "MarketFeature Commands.Search must be function")

    -- 2. v3_auction_sidecar_contract verification
    assert(type(Surface) == "table", "Surface must be table")
    assert((tonumber(Surface.version) or 0) >= 2, "AuctionSurfaceV3 version >= 2")
    assert((tonumber(Surface.VisibilityContractVersion) or 0) >= 2, "VisibilityContractVersion >= 2")
    assert(type(Surface.GetSnapshot) == "function", "Surface.GetSnapshot must be function")
    assert(type(Surface.Start) == "function", "Surface.Start must be function")
    assert(type(Surface.Stop) == "function", "Surface.Stop must be function")
    assert(type(S.UIV3.AuctionSidecar) == "table", "AuctionSidecar controller must be table")

    -- 3. Acceptance contract clauses
    assert(Feature.Commands.AddFavorite ~= nil, "AddFavorite command must exist")
    assert(Feature.Commands.RemoveFavorite ~= nil, "RemoveFavorite command must exist")
    assert(Feature.Commands.Quote ~= nil, "Quote command must exist")
    assert(Feature.Commands.SetExactMatch ~= nil, "SetExactMatch command must exist")
    assert(Feature.Commands.SetResultLimit ~= nil, "SetResultLimit command must exist")

    local sidecarSpec = S.UIV3.WidgetHost:GetSpec("tools.auction_sidecar")
    assert(sidecarSpec ~= nil and sidecarSpec.featureId == "tools_auction", "Sidecar spec must exist with featureId tools_auction")
end)

print(string.format("\nAuction Favorites & Query Test Results: %d/%d passed", passed, total))
if passed == total then
    print("ALL TESTS PASSED!")
else
    print("SOME TESTS FAILED!")
    os.exit(1)
end

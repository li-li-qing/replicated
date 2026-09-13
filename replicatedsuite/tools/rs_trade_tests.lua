------------------------------------------------------------------------
-- Replicated Suite V3 - Trade / Specialty Route Test Suite
--
-- Tests Trade Feature, Authority, SingleFlight route request & timeout,
-- dropped/stale callback handling, ratio & 130% full ratio modes,
-- Commerce proficiency integration, TradePayoutV3 price calculations,
-- bounded material projection & identity resolution, quote batching (max 4),
-- route favorites (max 12), HUD widget & TradeDetailFloatingV3,
-- and FoundationGate / Acceptance contract verification.
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

print("=== Replicated Suite: Trade / Specialty Route Tests ===")

local h = dofile("tools/rs_gear_page_test_host.lua")({})
local S = h.S

S.Layout = S.Layout or {
    GetContext = function() return { logicalWidth = 1280, logicalHeight = 768, addonScale = 1, uiScale = 1 } end,
    ResolvePlacement = function(_, target, w, h, dx, dy) return dx or 100, dy or 100 end,
}

S.UI = S.UI or {}
S.UI.SetAnchor = function() return true end
S.UI.RegisterScreenSnap = function() return true end
S.UI.UnregisterScreenSnap = function() return true end
S.UI.CreateWindowShell = function()
    local dummy = {
        width = 400, height = 300,
        GetParent = function() return nil end,
        GetWidth = function(self) return self.width end,
        GetHeight = function(self) return self.height end,
        SetExtent = function(self, w, h) self.width = w; self.height = h end,
        Show = function() return true end, Hide = function() return true end, Close = function() return true end,
    }
    return {
        root = dummy,
        window = dummy,
        body = dummy,
        normalWidth = 400, normalHeight = 300,
        SetTitle = function() return true end, SetFooter = function() return true end,
        SetMinSize = function() return true end, SetMaxSize = function() return true end,
        SetResizable = function() return true end, SetCloseHandler = function() return true end,
        SetMinimizeHandler = function() return true end, SetLockHandler = function() return true end,
        SetOpacity = function() return true end, SetMinimized = function() return true end,
        SetLocked = function() return true end, SetExtent = function() return true end,
        SetOverallOpacity = function() return true end, SetBackgroundOpacity = function() return true end,
        SetTextOpacity = function() return true end, Layout = function() return true end,
        SetStatus = function() return true end,
        GetContentRoot = function() return dummy end,
        GetContentComponent = function() return dummy end,
        GetNativeContentRoot = function() return dummy end,
        GetWindow = function() return dummy end,
        IsLocked = function() return false end,
        Show = function() return true end, Hide = function() return true end, Close = function() return true end,
    }
end

dofile("core/rs_demand.lua")
dofile("ui/framework/rs_ui_floating_surface.lua")
dofile("data/rs_data_registry.lua")
dofile("data/ids/rs_item_ids.lua")
dofile("data/ids/rs_quest_ids.lua")
dofile("data/rs_static_data_v2.lua")
dofile("data/ids/rs_zone_ids.lua")
dofile("data/ids/rs_trade_craft_ids.lua")
dofile("data/ids/rs_trade_product_ids.lua")
dofile("data/rs_trade_materials.lua")
dofile("data/rs_trade_prices.lua")
dofile("data/rs_trade_crafter_locations.lua")
dofile("data/rs_trade_static_v2.lua")
dofile("core/rs_constants.lua")
dofile("core/rs_foundation_gate.lua")
dofile("features/rs_feature_registry.lua")
dofile("services/rs_price_quote_queue_v3.lua")
dofile("services/rs_trade_payout_v3.lua")
dofile("services/rs_trade_material_identity_v3.lua")

-- Mock RSUI controls
S.RSUI = S.RSUI or {}
S.RSUI.TableView = function(spec)
    local tv = { spec = spec, items = {}, viewState = "ready" }
    function tv:SetItems(items, rev) self.items = items or {}; self.rev = rev end
    function tv:SetViewState(state, info) self.viewState = state; self.viewInfo = info end
    function tv:GetItem(idx) return self.items[idx] end
    function tv:ScrollToTop() end
    return tv
end
S.RSUI.Button = function(spec)
    local btn = { spec = spec, enabled = true, text = spec.text or "" }
    function btn:SetText(t) self.text = t end
    function btn:SetEnabled(e) self.enabled = e end
    return btn
end
S.RSUI.Text = function(spec)
    local txt = { spec = spec, text = spec.text or "" }
    function txt:SetText(t) self.text = t end
    return txt
end
S.RSUI.Dropdown = function(spec)
    local dd = { spec = spec, items = spec.items or {}, enabled = true }
    function dd:SetItems(it) self.items = it or {} end
    function dd:SetEnabled(e) self.enabled = e end
    function dd:Render() end
    return dd
end
S.RSUI.SegmentedSelector = function(spec)
    local ss = { spec = spec, enabled = true }
    function ss:SetEnabled(e) self.enabled = e end
    function ss:Render() end
    return ss
end
S.RSUI.VerticalBox = function(spec) return { spec = spec } end
S.RSUI.HorizontalBox = function(spec) return { spec = spec } end
S.RSUI.Border = function() return {} end
S.RSUI.WithBuildScope = function(_, fn) return fn() end

-- Mock UI Hosts
S.UIV3 = S.UIV3 or {}
S.UIV3.WidgetHost = {
    specs = {},
    Register = function(self, id, spec) self.specs[id] = spec; return true end,
    BindFeatureLifecycle = function(self, id, binding) end,
    GetSpec = function(self, id) return self.specs[id] end,
    IsVisible = function() return false end,
    SetVisible = function() return true end,
    NotifyWindowClosed = function() return true end,
}
S.UIV3.AuxWindowStoreV3 = {
    EnsureLoaded = function() return true end,
    GetPolicy = function() return { defaultWidth = 620, defaultHeight = 400 } end,
    GetWindowState = function() return {} end,
    SetWindowState = function() return true end,
    PersistWindow = function() return true end,
}

-- Native APIs mock
local mockStore = {
    productionZones = {
        { zoneGroupId = 1, zoneGroupName = "索兹里德半岛", continentName = "西大陆" },
        { zoneGroupId = 5, zoneGroupName = "双冠丘陵", continentName = "西大陆" },
        { zoneGroupId = 8, zoneGroupName = "十字星平原", continentName = "西大陆" },
        { zoneGroupId = 4, zoneGroupName = "摩哈特比", continentName = "东大陆" },
    },
    sellableZones = {
        [1] = {
            { zoneGroupId = 5, zoneGroupName = "双冠丘陵", continentName = "西大陆" },
            { zoneGroupId = 8, zoneGroupName = "十字星平原", continentName = "西大陆" },
        },
        [5] = {
            { zoneGroupId = 1, zoneGroupName = "索兹里德半岛", continentName = "西大陆" },
            { zoneGroupId = 8, zoneGroupName = "十字星平原", continentName = "西大陆" },
        },
    },
    ratioCalls = {},
}

_G.X2Store = {
    GetProductionZoneGroups = function(self)
        return mockStore.productionZones
    end,
    GetSellableZoneGroups = function(self, from)
        return mockStore.sellableZones[from] or {}
    end,
    GetSpecialtyRatioBetween = function(self, from, to)
        mockStore.ratioCalls[#mockStore.ratioCalls + 1] = { from = from, to = to }
        return true
    end,
}

_G.X2Ability = {
    GetAllMyActabilityInfos = function(self)
        return {
            { name = "Commerce", point = 50000, modifyPoint = 0 },
            { name = "Husbandry", point = 10000, modifyPoint = 0 },
        }
    end,
}

dofile("features/life/rs_life_m16_bundle.lua")
dofile("presentation/v3/widgets/rs_v3_trade_detail_floating.lua")
dofile("presentation/v3/widgets/rs_v3_life_economy_widgets.lua")

local Trade = S.Features.Trade
assert(Trade ~= nil, "Trade feature failed to load")
Trade.enabled = true
assert(Trade:Initialize(), "Trade Initialize failed")

------------------------------------------------------------------------
-- Test 1: Registry Contract & Metadata
------------------------------------------------------------------------
Test("T1: Feature registry metadata & contract", function()
    local reg = S.FeatureRegistry:Get("life_trade")
    assert(reg ~= nil, "life_trade must be registered")
    assert(reg.route == "life.trade", "route must be life.trade")
    assert(reg.category == "life", "category must be life")
    assert(reg.authority == "v3.life.trade", "authority must be v3.life.trade")
    assert(reg.lifecycle == "demand_scoped", "lifecycle must be demand_scoped")
    assert(reg.widgetCapable == true, "widgetCapable must be true")
    assert(reg.settingsCapable == true, "settingsCapable must be true")
    assert(#reg.apiDependencies == 4, "must declare 4 api dependencies")
end)

------------------------------------------------------------------------
-- Test 2: Zone Normalization & Candidate Fallback
------------------------------------------------------------------------
Test("T2: Zone reading, continent classification & candidate fallback", function()
    assert(Trade:AcquireConsumer("test_t2"), "AcquireConsumer failed")
    local TA = Trade.Authority
    assert(TA:RefreshZones(), "RefreshZones failed")
    assert(#TA.zones == 4, "Must have 4 zones from mock")
    assert(TA.zoneFallback == false, "zoneFallback should be false when native returns data")

    -- Check continent tagging
    local westCount, eastCount = 0, 0
    for _, z in ipairs(TA.zones) do
        if z.continentKey == "west" then westCount = westCount + 1 end
        if z.continentKey == "east" then eastCount = eastCount + 1 end
    end
    assert(westCount == 3, "Should have 3 west zones")
    assert(eastCount == 1, "Should have 1 east zone")

    -- Test sellable zones caching
    Trade.State.fromZone = 1
    assert(TA:RefreshSellable(), "RefreshSellable failed")
    assert(#TA.sellableZones == 2, "Should have 2 sellable destinations for zone 1: got " .. tostring(#TA.sellableZones))
    assert(TA.sellableCache[1] ~= nil, "Zone 1 should be cached")

    -- Test fallback when native returns empty
    local oldProd = mockStore.productionZones
    mockStore.productionZones = {}
    assert(TA:RefreshZones(), "RefreshZones with empty native failed")
    assert(TA.zoneFallback == true, "zoneFallback should be true when native is empty")
    assert(#TA.zones > 0, "Static fallback zones should be populated")
    mockStore.productionZones = oldProd
    assert(TA:RefreshZones())

    Trade:ReleaseConsumer("test_t2")
end)

------------------------------------------------------------------------
-- Test 3: Route Selection, SingleFlight & Timeout Guard
------------------------------------------------------------------------
Test("T3: Route selection, SingleFlight lane & request timeout guard", function()
    assert(Trade:AcquireConsumer("test_t3"))
    local TA = Trade.Authority
    Trade.State.fromZone, Trade.State.toZone = nil, nil
    TA.inFlight = nil
    TA.pendingRoute = nil
    TA:RefreshZones()
    mockStore.ratioCalls = {}

    -- Setting From
    assert(Trade:SetFrom(1), "SetFrom(1) failed")
    assert(Trade.State.fromZone == 1, "fromZone must be 1")
    assert(Trade.State.toZone == nil, "toZone must be reset to nil on origin change")

    -- Setting To
    assert(Trade:SetTo(5), "SetTo(5) failed")
    assert(Trade.State.toZone == 5, "toZone must be 5")
    assert(#mockStore.ratioCalls == 1, "Should have called GetSpecialtyRatioBetween once")
    assert(mockStore.ratioCalls[1].from == 1 and mockStore.ratioCalls[1].to == 5)
    assert(TA.inFlight ~= nil, "inFlight record must be set")
    assert(TA.status == "loading", "Status must be loading")

    -- SingleFlight: identical request while inFlight with force=false is rejected as in-flight
    local ok, msg = TA:Request(false)
    assert(ok == false and msg == "路线查询仍在进行", "Duplicate request should be rejected")

    -- SingleFlight: different route queues latest pending route
    Trade.State.toZone = 8
    local queued = TA:Request(false)
    assert(queued == true, "Different route should queue latest route")
    assert(TA.pendingRoute ~= nil and TA.pendingRoute.to == 8, "pendingRoute must be set to 8")

    -- Simulate timeout guard task execution
    local timeoutTask = S.Scheduler.tasks and S.Scheduler.tasks[TA.requestTimeoutTask]
    if type(timeoutTask) == "table" and type(timeoutTask.callback) == "function" then
        timeoutTask.callback()
    end
    assert(TA.inFlight == nil or TA.inFlight.to == 8, "Inflight should transition to pending route")

    TA.inFlight = nil
    TA.pendingRoute = nil
    Trade:ReleaseConsumer("test_t3")
end)

------------------------------------------------------------------------
-- Test 4: Stale & Dropped Callback Safety
------------------------------------------------------------------------
Test("T4: Dropped and stale callback protection", function()
    assert(Trade:AcquireConsumer("test_t4"))
    local TA = Trade.Authority
    Trade.State.fromZone, Trade.State.toZone = nil, nil
    TA.inFlight = nil
    TA.pendingRoute = nil
    TA:RefreshZones()

    -- Simulate dropped callback when inFlight is nil
    local droppedOk = TA:OnRatio({ { name = "test", ratio = 100 } })
    assert(droppedOk == false, "Late callback with no inFlight must be dropped")
    assert(TA.diag and TA.diag.droppedCallbacks > 0, "droppedCallbacks counter must increment")

    -- Simulate stale callback when user switched selection
    Trade:SetFrom(1)
    Trade:SetTo(5)
    assert(TA.inFlight ~= nil)
    -- User switches to 8
    Trade.State.toZone = 8
    -- Callback arrives for 5
    local staleResult = TA:OnRatio({ { name = "test", ratio = 100 } })
    assert(TA.inFlight == nil or TA.inFlight.to == 8, "Stale callback must trigger pending request for route to 8")

    TA.inFlight = nil
    TA.pendingRoute = nil
    Trade:ReleaseConsumer("test_t4")
end)

------------------------------------------------------------------------
-- Test 5: Ratio Event Processing, Sorting & 130% Full Mode
------------------------------------------------------------------------
Test("T5: Ratio event processing, 130% full mode & sorting", function()
    assert(Trade:AcquireConsumer("test_t5"))
    local TA = Trade.Authority
    Trade.State.fromZone, Trade.State.toZone = nil, nil
    TA.inFlight = nil
    TA.pendingRoute = nil
    TA:RefreshZones()

    assert(Trade:SetFrom(1))
    assert(Trade:SetTo(5))

    -- Dispatch ratio data matching the active inFlight route (1->5)
    local mockRatioInfo = {
        {
            name = "[格威尔]标准特产",
            ratio = 120,
            itemInfo = { name = "[格威尔]标准特产", itemType = 24651 },
        },
        {
            name = "索兹里德肉脯特产",
            ratio = 129,
            itemInfo = { name = "索兹里德肉脯特产", itemType = 24652 },
        },
        {
            name = "[双冠]特供特产",
            ratio = 110,
            itemInfo = { name = "[双冠]特供特产", itemType = 24653 },
        },
    }
    assert(TA:OnRatio(mockRatioInfo), "OnRatio must process rows")
    assert(#TA.rows == 3, "Must have 3 rows: got " .. tostring(#TA.rows))
    assert(TA.status == "ready", "Status must be ready")

    -- Test sorting: ratio mode (default)
    assert(Trade:SetSortMode("ratio"))
    assert(TA.rows[1].ratio >= TA.rows[2].ratio, "Rows must be sorted descending by ratio")

    -- Test sorting: name mode ([xx] prefix priority)
    assert(Trade:SetSortMode("name"))
    assert(string.sub(TA.rows[1].name, 1, 1) == "[", "First row must have bracket prefix")
    assert(string.sub(TA.rows[2].name, 1, 1) == "[", "Second row must have bracket prefix")
    assert(string.sub(TA.rows[3].name, 1, 1) ~= "[", "Third row has no bracket prefix")

    -- Test full 130% ratio mode
    assert(Trade:SetRatioMode("full"))
    for _, row in ipairs(TA.rows) do
        assert(row.ratio == 130, "All rows must have 130% ratio in full mode")
        assert(row.rate == "130%", "rate display must be 130%")
    end

    -- Switch back to current ratio
    assert(Trade:SetRatioMode("current"))
    assert(TA.rows[1].currentRatio ~= nil, "currentRatio must be preserved")

    TA.inFlight = nil
    TA.pendingRoute = nil
    Trade:ReleaseConsumer("test_t5")
end)

------------------------------------------------------------------------
-- Test 6: Commerce Proficiency & Payout Calculation
------------------------------------------------------------------------
Test("T6: Commerce skill reading & TradePayoutV3 calculation", function()
    assert(Trade:AcquireConsumer("test_t6"))
    local TA = Trade.Authority
    Trade.State.fromZone, Trade.State.toZone = nil, nil
    TA.inFlight = nil
    TA.pendingRoute = nil
    TA:RefreshZones()
    assert(Trade:SetFrom(1))
    assert(Trade:SetTo(5))

    local mockRatioInfo = {
        {
            name = "[格威尔]标准特产",
            ratio = 120,
            itemInfo = { name = "[格威尔]标准特产", itemType = 24651 },
        },
    }
    assert(TA:OnRatio(mockRatioInfo))

    -- Check commerce skill resolution
    assert(TA.commerceSkill == 50000, "Commerce skill must be 50000")
    assert(TA.commerceStatus == "ready", "Commerce status must be ready")

    -- Payout calculation for [格威尔]标准特产 to Zone 5
    local row = TA.rows[1]
    assert(row ~= nil, "[格威尔]标准特产 row must exist")
    assert(row.priceCopper ~= nil and row.priceCopper > 0, "Price in copper must be calculated: " .. tostring(row.priceCopper))
    assert(row.commerceMultiplier ~= nil and row.commerceMultiplier > 1.0, "Commerce multiplier must be > 1.0")
    assert(row.priceComplete == true, "Price estimation must be complete")

    -- Test turning commerce mode off
    assert(Trade:SetCommerceMode("off"))
    assert(Trade.State.commerceMode == "off")
    assert(TA.commerceStatus == "off")

    -- Restore commerce mode
    assert(Trade:SetCommerceMode("observe"))

    TA.inFlight = nil
    TA.pendingRoute = nil
    Trade:ReleaseConsumer("test_t6")
end)

------------------------------------------------------------------------
-- Test 7: Material Projection & Identity Resolution
------------------------------------------------------------------------
Test("T7: Material projection, recipe resolution & bounded display", function()
    assert(Trade:AcquireConsumer("test_t7"))
    local TA = Trade.Authority
    Trade.State.fromZone, Trade.State.toZone = nil, nil
    TA.inFlight = nil
    TA.pendingRoute = nil
    TA:RefreshZones()
    assert(Trade:SetFrom(1))
    assert(Trade:SetTo(5))

    local mockRatioInfo = {
        {
            name = "[格威尔]标准特产",
            ratio = 120,
            itemInfo = { name = "[格威尔]标准特产", itemType = 24651 },
        },
    }
    assert(TA:OnRatio(mockRatioInfo))

    local row = TA.rows[1]
    assert(row ~= nil, "Must have a row")
    assert(type(row.materials) == "string", "materials summary text must be present")
    assert(type(row.materialRows) == "table", "materialRows table must exist")
    assert(row.materialLimit == 32, "Material rows limit must be 32")

    for _, mat in ipairs(row.materialRows) do
        assert(mat.name ~= nil and mat.name ~= "", "Material must have a display name")
        assert(mat.count > 0, "Material count must be > 0")
        assert(mat.costStatus ~= nil, "Material must have costStatus")
    end

    TA.inFlight = nil
    TA.pendingRoute = nil
    Trade:ReleaseConsumer("test_t7")
end)

------------------------------------------------------------------------
-- Test 8: Bounded Quote Batching (Max 4) & Cancel
------------------------------------------------------------------------
Test("T8: Bounded quote batching (max 4 per batch) & cancel", function()
    assert(Trade:AcquireConsumer("test_t8"))
    local queue = S.Services.PriceQuoteQueueV3
    assert(queue ~= nil, "PriceQuoteQueueV3 must be available")

    local ok, msg, batchTotal, deferred = Trade:QuotePendingMaterials()
    if ok then
        local batch = Trade:GetQuoteBatch()
        assert(batch.total <= 4, "Batch size must be <= 4")
        assert(Trade.quoteBatch.active == true, "Batch must be active")

        local ok2, msg2 = Trade:QuotePendingMaterials()
        assert(ok2 == true, "Second call returns active status")
        assert(Trade:GetQuoteBatch().total <= 4, "Batch total remains bounded")

        assert(Trade:CancelQuoteBatch("test_cancel"), "CancelQuoteBatch failed")
        assert(Trade:GetQuoteBatch().active == false, "Batch must no longer be active")
    end

    Trade:ReleaseConsumer("test_t8")
end)

------------------------------------------------------------------------
-- Test 9: Route Favorites Management & Persistence
------------------------------------------------------------------------
Test("T9: Route favorites toggle, 12-route bound & selection", function()
    assert(Trade:AcquireConsumer("test_t9"))
    local TA = Trade.Authority
    Trade.State.fromZone, Trade.State.toZone = nil, nil
    TA.inFlight = nil
    TA.pendingRoute = nil
    TA:RefreshZones()

    assert(Trade:SetFrom(1))
    assert(Trade:SetTo(5))

    -- Toggle favorite (add)
    local okAdd, msgAdd = Trade:ToggleCurrentFavorite()
    assert(okAdd == true and msgAdd == "已收藏路线", "Must successfully add favorite: " .. tostring(msgAdd))
    assert(Trade:IsFavorite(1, 5) == true, "1->5 must be favorite")

    local favs = Trade:GetFavorites()
    assert(#favs == 1, "Must have 1 favorite")
    assert(favs[1].fromZone == 1 and favs[1].toZone == 5)

    local favItems = Trade:GetFavoriteItems()
    assert(#favItems == 1, "Must have 1 favorite item for dropdown")
    assert(favItems[1].selected == true, "Current route should be marked selected")

    -- Select favorite
    assert(Trade:SelectFavorite("1:5"), "SelectFavorite failed")
    assert(Trade.State.fromZone == 1 and Trade.State.toZone == 5)

    -- Toggle favorite (remove)
    local okRem, msgRem = Trade:ToggleCurrentFavorite()
    assert(okRem == true and msgRem == "已取消收藏", "Must successfully remove favorite")
    assert(Trade:IsFavorite(1, 5) == false, "1->5 must not be favorite")
    assert(#Trade:GetFavorites() == 0, "Favorites must be empty")

    -- Bound: cannot exceed 12 favorites
    Trade.State.favorites = {}
    for i = 1, 12 do
        Trade.State.favorites[#Trade.State.favorites + 1] = { fromZone = i, toZone = i + 10 }
    end
    Trade.State.fromZone = 99
    Trade.State.toZone = 100
    local ok13, err13 = Trade:ToggleCurrentFavorite()
    assert(ok13 == false and string.find(err13, "最多保存 12 条") ~= nil, "Must reject 13th favorite")

    TA.inFlight = nil
    TA.pendingRoute = nil
    Trade:ReleaseConsumer("test_t9")
end)

------------------------------------------------------------------------
-- Test 10: HUD Widget, TradeDetailFloatingV3 & Gate Checks
------------------------------------------------------------------------
Test("T10: HUD widget, Floating Detail & FoundationGate / Acceptance verification", function()
    assert(Trade:AcquireConsumer("test_t10"))
    local TA = Trade.Authority
    Trade.State.fromZone, Trade.State.toZone = nil, nil
    TA.inFlight = nil
    TA.pendingRoute = nil
    TA:RefreshZones()
    assert(Trade:SetFrom(1))
    assert(Trade:SetTo(5))

    local mockRatioInfo = {
        {
            name = "[格威尔]标准特产",
            ratio = 120,
            itemInfo = { name = "[格威尔]标准特产", itemType = 24651 },
        },
    }
    assert(TA:OnRatio(mockRatioInfo))

    -- Widget window state compatibility
    Trade.State.widgetWindow = { width = 470, height = 374, x = 100, y = 100 }
    local state = Trade:GetWidgetWindowState()
    assert(state.width == 410 and state.height == 306, "470x374 legacy size must be normalized to 410x306")

    -- Row lookup and selection
    local row = TA.rows[1]
    assert(row ~= nil, "Must have at least one row")
    assert(Trade:GetRow(row.key) ~= nil, "GetRow must find row by key")
    assert(Trade:SelectRow(row.key) == true, "SelectRow must succeed")
    assert(Trade:GetSelectedRow() ~= nil, "GetSelectedRow must return selected row")

    -- TradeDetailFloatingV3 open and close
    local detail = S.UIV3.TradeDetailFloatingV3
    assert(detail ~= nil, "TradeDetailFloatingV3 must be present")
    assert(detail:Open(row.key) == true, "TradeDetailFloatingV3:Open must succeed")
    assert(detail.visible == true, "Detail floating must be visible")
    assert(detail.rowKey == row.key, "Detail floating rowKey must match")
    assert(detail:Close() == true, "TradeDetailFloatingV3:Close must succeed")
    assert(detail.visible == false, "Detail floating must be hidden")

    -- FoundationGate check: v3_trade_detail_favorites_contract clauses
    local tradeFeature = S.Features and S.Features.Trade or nil
    local tradePayout = S.Services and S.Services.TradePayoutV3 or nil
    assert(type(tradeFeature) == "table", "tradeFeature must be table")
    assert(type(tradeFeature.Authority) == "table" and (tonumber(tradeFeature.Authority.version) or 0) >= 6, "trade Authority >= 6")
    assert((tonumber(tradeFeature.Authority.TradePayoutProjectionContractVersion) or 0) >= 1, "TradePayoutProjectionContractVersion >= 1")
    assert(type(tradePayout) == "table" and (tonumber(tradePayout.PriceFormulaContractVersion) or 0) >= 1, "PriceFormulaContractVersion >= 1")
    assert((tonumber(tradePayout.StaticPriceKeyResolverContractVersion) or 0) >= 2, "StaticPriceKeyResolverContractVersion >= 2")
    assert((tonumber(tradePayout.CommerceMultiplierContractVersion) or 0) >= 1, "CommerceMultiplierContractVersion >= 1")
    assert((tonumber(tradePayout.PackCategoryMultiplierContractVersion) or 0) >= 1, "PackCategoryMultiplierContractVersion >= 1")
    assert((tonumber(tradeFeature.Authority.RouteRefreshRetryContractVersion) or 0) >= 2, "RouteRefreshRetryContractVersion >= 2")
    assert((tonumber(tradeFeature.Authority.SingleFlightLatestRouteContractVersion) or 0) >= 1, "SingleFlightLatestRouteContractVersion >= 1")
    assert((tonumber(tradeFeature.Authority.RequestTimeoutContractVersion) or 0) >= 1, "RequestTimeoutContractVersion >= 1")
    assert(type(tradeFeature.Commands) == "table", "tradeFeature.Commands must exist")
    assert(type(tradeFeature.Commands.ToggleCurrentFavorite) == "function", "ToggleCurrentFavorite missing")
    assert(type(tradeFeature.Commands.SelectFavorite) == "function", "SelectFavorite missing")
    assert(type(tradeFeature.Commands.SetSortMode) == "function", "SetSortMode missing")
    assert(type(tradeFeature.Commands.SelectRow) == "function", "SelectRow missing")
    assert(type(tradeFeature.Commands.QuoteRowMaterials) == "function", "QuoteRowMaterials missing")
    assert(type(tradeFeature.GetFavoriteItems) == "function", "GetFavoriteItems missing")
    assert(type(tradeFeature.GetRow) == "function", "GetRow missing")
    assert(type(detail) == "table" and (tonumber(detail.TradeDetailContractVersion) or 0) >= 2, "TradeDetailContractVersion >= 2")
    assert(type(detail.Open) == "function" and type(detail.Close) == "function", "TradeDetail Open/Close missing")

    -- Acceptance check: trade_dropdown_quote_preflight_contract & trade_detail_favorites_contract
    local tradeProjection = tradeFeature:GetProjection()
    assert(type(tradeFeature.GetRouteSettings) == "function", "GetRouteSettings missing")
    assert(type(tradeFeature.Commands.SetFrom) == "function", "Commands.SetFrom missing")
    assert(type(tradeFeature.Commands.SetTo) == "function", "Commands.SetTo missing")
    assert(type(tradeFeature.Commands.QuotePendingMaterials) == "function", "Commands.QuotePendingMaterials missing")
    assert(type(tradeProjection) == "table" and type(tradeProjection.zones) == "table", "tradeProjection.zones missing")
    assert(type(tradeProjection.sellableZones) == "table", "tradeProjection.sellableZones missing")
    assert(tradeProjection.pendingQuoteCount ~= nil, "tradeProjection.pendingQuoteCount missing")
    assert(tostring(tradeProjection.commercePriceFormulaStatus or "") == "supplied_working_v1", "commercePriceFormulaStatus must be supplied_working_v1")
    assert(tostring(tradeProjection.packPriceMultiplierStatus or "") == "supplied_working_v1", "packPriceMultiplierStatus must be supplied_working_v1")
    assert(type(S.UIV3 and S.UIV3.LifeEconomyWidgetsV3) == "table", "LifeEconomyWidgetsV3 missing")
    assert((tonumber(S.UIV3.LifeEconomyWidgetsV3.version) or 0) >= 3, "LifeEconomyWidgetsV3 version >= 3")
    assert(type(tradeProjection.favoriteItems) == "table", "tradeProjection.favoriteItems missing")
    assert(tradeProjection.currentRouteFavorite ~= nil, "tradeProjection.currentRouteFavorite missing")
    assert(tradeProjection.sortMode ~= nil, "tradeProjection.sortMode missing")

    Trade:ReleaseConsumer("test_t10")
end)


------------------------------------------------------------------------
-- Test 11: Route switch invalidates stale rows immediately
------------------------------------------------------------------------
Test("T11: destination change clears previous route rows before new callback", function()
    assert(Trade:AcquireConsumer("test_t11"))
    local TA = Trade.Authority
    Trade.State.fromZone, Trade.State.toZone = nil, nil
    TA.inFlight = nil
    TA.pendingRoute = nil
    TA.rows = {}
    TA:RefreshZones()
    assert(Trade:SetFrom(1))
    assert(Trade:SetTo(5))
    assert(TA:OnRatio({ { name = "route-five", ratio = 121, itemInfo = { name = "route-five", itemType = 24651 } } }))
    assert(#TA.rows == 1 and TA.rows[1].destinationZone == 5, "route 1->5 fixture must be visible")

    assert(Trade:SetTo(8), "SetTo(8) failed")
    assert(Trade.State.toZone == 8, "destination must switch to 8")
    assert(TA.status == "loading", "destination switch must enter loading")
    assert(#TA.rows == 0, "old destination rows must be cleared immediately while 1->8 loads")

    TA.inFlight = nil
    TA.pendingRoute = nil
    Trade:ReleaseConsumer("test_t11")
end)

------------------------------------------------------------------------
-- Test 12: Overview trade card exposes an explicit refresh command
------------------------------------------------------------------------
Test("T12: overview trade controls expose refresh button wired to Feature.Commands.Refresh", function()
    local spec = S.UIV3.LifeEconomyContent and S.UIV3.LifeEconomyContent.specs and S.UIV3.LifeEconomyContent.specs.Trade
    assert(type(spec) == "table" and type(spec.buildControls) == "function", "Trade content spec missing")
    local instance = { contentPrefix = "trade_overview_test_", overview = true, Refresh = function(self) self.refreshCount = (self.refreshCount or 0) + 1; return true end }
    local oldRefresh = Trade.Commands.Refresh
    local calls = 0
    Trade.Commands.Refresh = function(_, reason) calls = calls + 1; assert(reason == "overview_manual", "unexpected refresh reason"); return true end
    local ok, err = spec.buildControls(instance, {}, Trade)
    assert(ok == true, tostring(err))
    assert(instance.refreshButton ~= nil, "overview trade must expose refreshButton")
    assert(type(instance.refreshButton.onClick) == "function", "overview refresh button onClick missing")
    local clickOk, clickErr = instance.refreshButton.onClick()
    assert(clickOk == true, tostring(clickErr))
    assert(calls == 1, "overview refresh must call Feature.Commands.Refresh once")
    assert(instance.refreshCount == 1, "overview refresh must repaint immediately after accepted command")
    Trade.Commands.Refresh = oldRefresh
end)

------------------------------------------------------------------------
-- Test 13: Floating trade HUD exposes refresh and stays compact
------------------------------------------------------------------------
Test("T13: floating trade controls expose refresh and use compact three-row header", function()
    local spec = S.UIV3.LifeEconomyContent and S.UIV3.LifeEconomyContent.specs and S.UIV3.LifeEconomyContent.specs.Trade
    assert(type(spec) == "table" and type(spec.buildControls) == "function", "Trade content spec missing")
    local instance = { contentPrefix = "trade_float_test_", overview = false, Refresh = function(self) self.refreshCount = (self.refreshCount or 0) + 1; return true end }
    local oldRefresh = Trade.Commands.Refresh
    local calls = 0
    Trade.Commands.Refresh = function(_, reason) calls = calls + 1; assert(reason == "widget_manual", "unexpected refresh reason"); return true end
    local ok, err = spec.buildControls(instance, {}, Trade)
    assert(ok == true, tostring(err))
    assert(instance.refreshButton ~= nil, "floating trade HUD must expose refreshButton")
    assert(type(instance.refreshButton.onClick) == "function", "floating refresh onClick missing")
    assert(instance.routeControlHeight ~= nil and instance.routeControlHeight <= 93, "floating control header must stay within three compact rows; got=" .. tostring(instance.routeControlHeight))
    assert(instance.cancelQuote == nil and instance.fullQuote == nil, "floating HUD must not reserve a dedicated fourth quote-control row")
    local clickOk, clickErr = instance.refreshButton.onClick()
    assert(clickOk == true, tostring(clickErr))
    assert(calls == 1, "floating refresh must call Feature.Commands.Refresh once")
    assert(instance.refreshCount == 1, "floating refresh must repaint immediately after accepted command")
    Trade.Commands.Refresh = oldRefresh
end)

------------------------------------------------------------------------
-- Test 14: Favorite button uses explicit cancel-favorite wording
------------------------------------------------------------------------
Test("T14: favorite button says 取消收藏 when current route is favorited", function()
    local spec = S.UIV3.LifeEconomyContent and S.UIV3.LifeEconomyContent.specs and S.UIV3.LifeEconomyContent.specs.Trade
    local instance = { contentPrefix = "trade_favorite_test_", overview = false, Refresh = function() return true end }
    local ok, err = spec.buildControls(instance, {}, Trade)
    assert(ok == true, tostring(err))
    spec.refreshControls(instance, {
        zones = {}, sellableZones = {}, fromZone = 1, toZone = 5, rows = {},
        pendingQuoteCount = 0, ratioMode = "current", commerceMode = "off",
        quoteBatch = { active = false, completed = 0, total = 0, failed = 0 },
        favoriteItems = {}, currentRouteFavorite = true, sortMode = "ratio",
    })
    assert(instance.favoriteButton ~= nil, "favorite button missing")
    assert(instance.favoriteButton.text == "取消收藏", "favorited route must show explicit 取消收藏 label")
end)



------------------------------------------------------------------------
-- Test 15: Native specialty-query cooldown must bound response timeout
------------------------------------------------------------------------
Test("T15: native specialty cooldown is recorded but does not extend response SLA", function()
    assert(Trade:AcquireConsumer("test_t15"))
    local TA = Trade.Authority
    Trade.State.fromZone, Trade.State.toZone = nil, nil
    TA.inFlight, TA.pendingRoute = nil, nil
    TA:CancelRequestTimeout()
    if TA.CancelDeferredRequest then TA:CancelDeferredRequest() end
    TA:RefreshZones()
    mockStore.ratioCalls = {}
    h.ms = 1000

    local oldGetRatio = X2Store.GetSpecialtyRatioBetween
    X2Store.GetSpecialtyRatioBetween = function(self, from, to)
        mockStore.ratioCalls[#mockStore.ratioCalls + 1] = { from = from, to = to }
        return 12000
    end

    assert(Trade:SetFrom(1))
    assert(Trade:SetTo(5))
    local task = assert(S.Scheduler.tasks[TA.requestTimeoutTask], "response timeout task missing")
    assert((tonumber(TA.lastNativeCooldownMs) or 0) == 12000, "native cooldown must be recorded")
    assert((tonumber(task.intervalMs) or 0) == 6500,
        "response SLA must stay independent from native cooldown; got=" .. tostring(task.intervalMs))

    X2Store.GetSpecialtyRatioBetween = oldGetRatio
    TA.inFlight, TA.pendingRoute = nil, nil
    TA:CancelRequestTimeout()
    if TA.CancelDeferredRequest then TA:CancelDeferredRequest() end
    Trade:ReleaseConsumer("test_t15")
end)

------------------------------------------------------------------------
-- Test 16: Manual refresh during native cooldown is deferred, not spammed
------------------------------------------------------------------------
Test("T16: refresh during native cooldown defers request until allowed", function()
    assert(Trade:AcquireConsumer("test_t16"))
    local TA = Trade.Authority
    Trade.State.fromZone, Trade.State.toZone = nil, nil
    TA.inFlight, TA.pendingRoute = nil, nil
    TA:CancelRequestTimeout()
    if TA.CancelDeferredRequest then TA:CancelDeferredRequest() end
    TA.nextNativeRequestAt, TA.lastNativeCooldownMs = 0, 0
    TA.rows = {}
    TA:RefreshZones()
    mockStore.ratioCalls = {}
    h.ms = 2000

    local oldGetRatio = X2Store.GetSpecialtyRatioBetween
    X2Store.GetSpecialtyRatioBetween = function(self, from, to)
        mockStore.ratioCalls[#mockStore.ratioCalls + 1] = { from = from, to = to }
        return 10000
    end

    assert(Trade:SetFrom(1))
    assert(Trade:SetTo(5))
    assert(#mockStore.ratioCalls == 1, "initial native request missing")
    assert(TA:OnRatio({ { name = "测试货物", ratio = 120, itemInfo = { name = "测试货物", itemType = 24651 } } }))
    assert(#TA.rows == 1, "successful callback must populate rows")

    h.ms = h.ms + 1000
    local ok, err = Trade:Refresh("manual_cooldown_test")
    assert(ok == true, tostring(err))
    assert(#mockStore.ratioCalls == 1, "refresh inside native cooldown must not issue a second native request")
    assert(TA.requestDeferredTask ~= nil and S.Scheduler.tasks[TA.requestDeferredTask] ~= nil,
        "refresh inside native cooldown must schedule one deferred request")
    assert(#TA.rows == 1, "same-route deferred refresh must keep current rows until native request really starts")

    h.ms = (tonumber(TA.nextNativeRequestAt) or h.ms) + 1
    assert(S.Scheduler:RunTask(TA.requestDeferredTask), "deferred route task must run")
    assert(#mockStore.ratioCalls == 2, "deferred refresh must issue exactly one native request when cooldown expires")
    assert(TA.status == "loading", "actual deferred native request must enter loading")
    assert(#TA.rows == 0, "rows should clear only when deferred native request is actually sent")

    X2Store.GetSpecialtyRatioBetween = oldGetRatio
    TA.inFlight, TA.pendingRoute = nil, nil
    TA:CancelRequestTimeout()
    if TA.CancelDeferredRequest then TA:CancelDeferredRequest() end
    Trade:ReleaseConsumer("test_t16")
end)



------------------------------------------------------------------------
-- Test 17: Missing callback gets one bounded automatic retry after cooldown
------------------------------------------------------------------------
Test("T17: missing specialty callback retries once after native cooldown", function()
    assert(Trade:AcquireConsumer("test_t17"))
    local TA = Trade.Authority
    Trade.State.fromZone, Trade.State.toZone = nil, nil
    TA.inFlight, TA.pendingRoute = nil, nil
    TA:CancelRequestTimeout()
    if TA.CancelDeferredRequest then TA:CancelDeferredRequest() end
    TA.nextNativeRequestAt, TA.lastNativeCooldownMs = 0, 0
    TA.pendingRetryCount = nil
    TA.timeoutRetryCount = 0
    TA:RefreshZones()
    mockStore.ratioCalls = {}
    h.ms = 3000

    local oldGetRatio = X2Store.GetSpecialtyRatioBetween
    X2Store.GetSpecialtyRatioBetween = function(self, from, to)
        mockStore.ratioCalls[#mockStore.ratioCalls + 1] = { from = from, to = to }
        return 8000
    end

    assert(Trade:SetFrom(1))
    assert(Trade:SetTo(5))
    assert(#mockStore.ratioCalls == 1)
    local firstTimeout = assert(S.Scheduler.tasks[TA.requestTimeoutTask], "first timeout missing")
    h.ms = h.ms + (tonumber(firstTimeout.intervalMs) or 0) + 1
    assert(S.Scheduler:RunTask(TA.requestTimeoutTask), "first timeout callback failed")
    assert(#mockStore.ratioCalls == 1, "response timeout must not retry before native cooldown expires")
    assert(TA.inFlight == nil and TA.status == "cooldown", "bounded timeout should expose cooldown state")
    local deferred = assert(S.Scheduler.tasks[TA.requestDeferredTask], "deferred retry missing")
    h.ms = (tonumber(TA.nextNativeRequestAt) or h.ms) + 1
    assert(S.Scheduler:RunTask(TA.requestDeferredTask), "deferred retry callback failed")
    assert(#mockStore.ratioCalls == 2, "cooldown expiry must issue exactly one retry")
    assert(TA.inFlight ~= nil and TA.status == "loading", "deferred retry must own the SingleFlight lane")

    local secondTimeout = assert(S.Scheduler.tasks[TA.requestTimeoutTask], "retry timeout missing")
    h.ms = h.ms + (tonumber(secondTimeout.intervalMs) or 0) + 1
    assert(S.Scheduler:RunTask(TA.requestTimeoutTask), "second timeout callback failed")
    assert(#mockStore.ratioCalls == 2, "second timeout must not create an unbounded retry loop")
    assert(TA.inFlight == nil and TA.status == "error", "second timeout must surface a stable error")

    X2Store.GetSpecialtyRatioBetween = oldGetRatio
    TA.inFlight, TA.pendingRoute = nil, nil
    TA:CancelRequestTimeout()
    if TA.CancelDeferredRequest then TA:CancelDeferredRequest() end
    TA.timeoutRetryCount = 0
    Trade:ReleaseConsumer("test_t17")
end)



------------------------------------------------------------------------
-- Test 18: Empty loading state must say querying, not "no ratio"
------------------------------------------------------------------------
Test("T18: loading trade view reports server query in progress", function()
    local Contents = S.UIV3.LifeEconomyContent
    assert(type(Contents) == "table" and type(Contents.Create) == "function")
    local oldProjection = Trade.GetProjection
    Trade.GetProjection = function()
        return {
            revision = 999, rows = {}, zones = {}, sellableZones = {}, status = "loading",
            fromZone = 1, toZone = 5, pendingQuoteCount = 0, quoteInFlightCount = 0,
            ratioMode = "current", commerceMode = "off", favoriteItems = {}, sortMode = "ratio",
            quoteBatch = { active = false, completed = 0, total = 0, failed = 0 },
        }
    end
    local instance, createErr = Contents:Create({}, "Trade", "trade_loading_test_", { overview = true })
    assert(instance ~= nil, tostring(createErr))
    assert(instance:Refresh())
    assert(instance.table.viewState == "empty")
    assert(instance.table.viewInfo and instance.table.viewInfo.title == "正在查询货率",
        "loading route must not be presented as no-data; got=" .. tostring(instance.table.viewInfo and instance.table.viewInfo.title))
    Trade.GetProjection = oldProjection
end)


------------------------------------------------------------------------
-- Test 19: A long Native button cooldown must not pin the response lane/loading state
------------------------------------------------------------------------
Test("T19: native cooldown does not extend response wait beyond bounded SLA", function()
    assert(Trade:AcquireConsumer("test_t19"))
    local TA = Trade.Authority
    Trade.State.fromZone, Trade.State.toZone = nil, nil
    TA.inFlight, TA.pendingRoute = nil, nil
    TA:CancelRequestTimeout()
    if TA.CancelDeferredRequest then TA:CancelDeferredRequest() end
    TA.nextNativeRequestAt, TA.lastNativeCooldownMs = 0, 0
    TA.pendingRetryCount = nil
    TA:RefreshZones()
    mockStore.ratioCalls = {}
    h.ms = 5000

    local oldGetRatio = X2Store.GetSpecialtyRatioBetween
    X2Store.GetSpecialtyRatioBetween = function(self, from, to)
        mockStore.ratioCalls[#mockStore.ratioCalls + 1] = { from = from, to = to }
        return 60000
    end

    assert(Trade:SetFrom(1))
    assert(Trade:SetTo(5))
    assert(#mockStore.ratioCalls == 1, "initial request missing")
    local timeout = assert(S.Scheduler.tasks[TA.requestTimeoutTask], "response timeout missing")
    assert((tonumber(timeout.intervalMs) or 0) <= 7000,
        "Native re-query cooldown must not be used as response SLA; got=" .. tostring(timeout.intervalMs))

    h.ms = h.ms + (tonumber(timeout.intervalMs) or 0) + 1
    assert(S.Scheduler:RunTask(TA.requestTimeoutTask), "bounded response timeout failed")
    assert(TA.inFlight == nil, "response lane must be released after bounded SLA")
    assert(TA.status == "cooldown", "remaining Native cooldown should become explicit cooldown state, got=" .. tostring(TA.status))
    assert(#mockStore.ratioCalls == 1, "must not issue a second native request before cooldown expiry")
    assert(S.Scheduler.tasks[TA.requestDeferredTask] ~= nil, "cooldown expiry should schedule one deferred retry")

    X2Store.GetSpecialtyRatioBetween = oldGetRatio
    TA.inFlight, TA.pendingRoute = nil, nil
    TA:CancelRequestTimeout()
    if TA.CancelDeferredRequest then TA:CancelDeferredRequest() end
    TA.nextNativeRequestAt, TA.lastNativeCooldownMs = 0, 0
    Trade:ReleaseConsumer("test_t19")
end)


------------------------------------------------------------------------
-- Test 20: A late callback after bounded SLA is accepted if no newer request exists
------------------------------------------------------------------------
Test("T20: safe late callback for same route cancels deferred retry", function()
    assert(Trade:AcquireConsumer("test_t20"))
    local TA = Trade.Authority
    Trade.State.fromZone, Trade.State.toZone = nil, nil
    TA.inFlight, TA.pendingRoute, TA.timedOutFlight = nil, nil, nil
    TA:CancelRequestTimeout()
    if TA.CancelDeferredRequest then TA:CancelDeferredRequest() end
    TA.nextNativeRequestAt, TA.lastNativeCooldownMs = 0, 0
    TA.pendingRetryCount = nil
    TA:RefreshZones()
    mockStore.ratioCalls = {}
    h.ms = 7000

    local oldGetRatio = X2Store.GetSpecialtyRatioBetween
    X2Store.GetSpecialtyRatioBetween = function(self, from, to)
        mockStore.ratioCalls[#mockStore.ratioCalls + 1] = { from = from, to = to }
        return 60000
    end

    assert(Trade:SetFrom(1))
    assert(Trade:SetTo(5))
    local timeout = assert(S.Scheduler.tasks[TA.requestTimeoutTask])
    h.ms = h.ms + (tonumber(timeout.intervalMs) or 0) + 1
    assert(S.Scheduler:RunTask(TA.requestTimeoutTask))
    assert(TA.inFlight == nil, "bounded SLA should release active lane")

    local accepted = TA:OnRatio({
        { name = "迟到但仍可归属的货物", ratio = 123, itemInfo = { name = "迟到但仍可归属的货物", itemType = 24651 } },
    })
    assert(accepted == true, "same-route late callback should be accepted when no newer request exists")
    assert(TA.status == "ready" and #TA.rows == 1, "late callback must populate the current route")
    assert(S.Scheduler.tasks[TA.requestDeferredTask] == nil, "accepted late callback must cancel deferred retry")
    assert(#mockStore.ratioCalls == 1, "accepted late callback must avoid duplicate native query")

    X2Store.GetSpecialtyRatioBetween = oldGetRatio
    TA.inFlight, TA.pendingRoute, TA.timedOutFlight = nil, nil, nil
    TA:CancelRequestTimeout()
    if TA.CancelDeferredRequest then TA:CancelDeferredRequest() end
    TA.nextNativeRequestAt, TA.lastNativeCooldownMs = 0, 0
    Trade:ReleaseConsumer("test_t20")
end)


------------------------------------------------------------------------
-- Test 21: first demand with a persisted complete route must request ratios
------------------------------------------------------------------------
Test("T21: first consumer auto-queries persisted complete route", function()
    local TA = Trade.Authority
    -- Simulate a freshly loaded session: route settings survived persistence,
    -- but no consumer/ratio rows/native request exist yet.
    assert((tonumber(Trade.consumerCount) or 0) == 0, "test requires no pre-existing consumers")
    Trade.State.fromZone, Trade.State.toZone = 5, 8
    TA.inFlight, TA.pendingRoute, TA.timedOutFlight = nil, nil, nil
    TA.rows, TA.sellableZones = {}, {}
    TA.nextNativeRequestAt, TA.lastNativeCooldownMs = 0, 0
    TA:CancelRequestTimeout()
    if TA.CancelDeferredRequest then TA:CancelDeferredRequest() end
    mockStore.ratioCalls = {}

    local oldGetRatio = X2Store.GetSpecialtyRatioBetween
    X2Store.GetSpecialtyRatioBetween = function(self, from, to)
        mockStore.ratioCalls[#mockStore.ratioCalls + 1] = { from = from, to = to }
        return 0
    end

    assert(Trade:AcquireConsumer("test_t21"))
    assert(#mockStore.ratioCalls == 1,
        "first visible consumer must query the persisted complete route instead of showing an inert empty table")
    assert(mockStore.ratioCalls[1].from == 5 and mockStore.ratioCalls[1].to == 8,
        "auto-query used wrong persisted route")

    X2Store.GetSpecialtyRatioBetween = oldGetRatio
    TA.inFlight, TA.pendingRoute, TA.timedOutFlight = nil, nil, nil
    TA:CancelRequestTimeout()
    if TA.CancelDeferredRequest then TA:CancelDeferredRequest() end
    Trade:ReleaseConsumer("test_t21")
end)

print(string.format("\nTrade Test Results: %d/%d passed", passed, total))
if passed == total then
    print("ALL TESTS PASSED!")
else
    print("SOME TESTS FAILED!")
    os.exit(1)
end

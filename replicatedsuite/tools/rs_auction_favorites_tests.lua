------------------------------------------------------------------------
-- Replicated Suite · 拍卖收藏测试
-- 作者：Replicated
-- QQ群：1104129461
--
-- 合并时须检查未解决冲突，不能把文件存在视为实现已完整恢复。
-- 数据归属、调用链和存档协议由原实现管理，
-- 不能通过清配置、跳过加载或恢复旧架构绕过错误；本文件须与完整 toc.g 和相应 UI 配套。
-- 合并后先核对冲突标记、加载清单和 Lua 语法，再进行客户端验收。
-- 覆盖 AuctionFavorites、AuctionQueryV3 和 AuctionSurfaceV3，
-- 包括有界收藏修改、九参数搜索、itemGrade 提取，
-- 分页、显式 PriceQuoteQueueV3 询价和伴随浮窗生命周期，
-- 并核对 FoundationGate 和验收契约条款。
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
    local minimizeButton = { text = "—", root = {} }
    function minimizeButton:SetText(value) self.text = tostring(value or "") return true end
    local shell = {
        window = mockWin,
        minimized = false,
        locked = false,
        overallOpacity = 1,
        backgroundOpacity = 1,
        textOpacity = 1,
        fontScale = 1,
        minimizeButton = minimizeButton,
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
        SetOverallOpacity = function(self, value) self.overallOpacity = value return true end,
        SetBackgroundOpacity = function(self, value) self.backgroundOpacity = value return true end,
        SetTextOpacity = function(self, value) self.textOpacity = value return true end,
        SetFontScale = function(self, value) self.fontScale = value return true end,
        SetMinimized = function(self, value) self.minimized = value == true; self.minimizeButton:SetText(self.minimized and "+" or "—"); return true end,
        SetLocked = function(self, value) self.locked = value == true return true end,
        IsLocked = function(self) return self.locked == true end,
        SetExtent = function() return true end,
        ApplyPlacementRect = function(self, x, y, w, h, info) self.x,self.y,self.width,self.height=x,y,w,h; return true end,
        Layout = function() return true end,
        Show = function() return true end,
        Hide = function() return true end,
        Close = function() return true end,
    }
    return shell
end

-- 布局上下文测试替身。
S.Constants={SafeArea=12,MinAddonScale=.5,MaxAddonScale=2,Breakpoint={COMPACT=1150,STANDARD=1700,WIDE=2300,NARROW_ONE_COLUMN=760}}
dofile('core/rs_layout.lua') -- 使用真实位置元数据写入逻辑；下方旧视口和几何测试值保持固定。
S.Layout = S.Layout or {}
S.Layout.GetContext = function()
    return { logicalWidth = 1920, logicalHeight = 1080, usableWidth = 1920, usableHeight = 1080, addonScale = 1, uiScale = 1, safeLeft = 0, safeTop = 0, safeRight = 0, safeBottom = 0 }
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
    return x, y, w, h, { x = x, y = y, width = w, height = h, screenW = 1920, screenH = 1080 }
end

-- 原生 UI 测试替身。
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

-- X2Auction 测试替身。
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
    AskMarketPrice = function(self, itemType, grade, askMarketPriceUi)
        return true
    end,
    GetLowestPrice = function(self, itemType, grade)
        return 125000 -- 12g 50s
    end,
}
_G.X2Auction = mockAuction

-- 开放测试需要的 API 能力。
S.Api.allowedCapabilities = S.Api.allowedCapabilities or {}
S.Api.allowedCapabilities["X2Auction:SearchAuctionArticle"] = true
S.Api.allowedCapabilities["X2Auction:GetSearchedItemCount"] = true
S.Api.allowedCapabilities["X2Auction:GetSearchedItemInfo"] = true
S.Api.allowedCapabilities["X2Auction:AskMarketPrice"] = true
S.Api.allowedCapabilities["X2Auction:GetLowestPrice"] = true
S.Api.allowedCapabilities["ADDON:GetContent"] = true
S.Api.allowedCapabilities["ADDON:GetContentMainScriptPosVis"] = true

_G.ReplicatedSuite = S
S.Features = S.Features or {}
S.Services = S.Services or {}

-- 按实际依赖顺序加载基础层和数据模块。
dofile("data/rs_data_registry.lua")
dofile("data/ids/rs_item_ids.lua")
dofile("data/ids/rs_quest_ids.lua")
dofile("core/rs_constants.lua")
dofile("core/rs_demand.lua")
dofile("core/rs_foundation_gate.lua")
dofile("features/rs_feature_registry.lua")
dofile("features/rs_feature_runtime.lua")
dofile("core/rs_module_diagnostics.lua")

-- 加载共享服务。
dofile("services/rs_price_quote_queue_v3.lua")
dofile("services/rs_auction_query_v3.lua")
dofile("services/rs_auction_surface_v3.lua")
local auctionSearchBridgeLoaded, auctionSearchBridgeLoadErr = pcall(dofile, "services/rs_auction_search_bridge_v3.lua")
dofile("services/rs_auction_session_list_v3.lua")
local dailySidecarConsumers = 0
S.Services.DailyAuctionMaterialsV3 = {
    version = 2, DailyMaterialContractVersion = 2,
    Topic = "v3.daily_auction_materials.updated",
    snapshot = { status = "ready", revision = 1, tasks = {
        { questId = 7001, recipes = { "候选货物A", "候选货物B" }, selectedRecipe = "候选货物A", requiresSelection = false, materials = {
            { key = "item:501", questId = 7001, recipe = "候选货物A", itemType = 501, name = "木材", count = 20, searchable = true, hidden = false },
        } },
    } },
    AcquireConsumer = function(self, token) dailySidecarConsumers = dailySidecarConsumers + 1; return true end,
    ReleaseConsumer = function(self, token) dailySidecarConsumers = math.max(0, dailySidecarConsumers - 1); return true end,
    GetSnapshot = function(self) return self.snapshot end,
    SelectRecipe = function(self, questId, recipe) self.selectedRecipe = recipe; return true end,
    SetMaterialHidden = function(self, questId, recipe, key, hidden) self.hidden = { questId=questId, recipe=recipe, key=key, hidden=hidden }; return true end,
    RestoreHidden = function(self, questId) self.restoredQuestId = questId; return true end,
    MoveMaterial = function(self, questId, recipe, key, direction) self.moved = { questId=questId, recipe=recipe, key=key, direction=direction }; return true end,
}

-- 业务桥接定义 tools_auction 和 tools_market_analysis。
-- 中文维护注释（2026-09-28，Phase 1 Batch A）：bridge 现在依赖 toc.g 中先加载的通用装配骨架，
-- 离线宿主必须复现同一加载顺序，否则 FeatureRuntime/Store 注册路径与真实运行时不一致。
dofile("features/shared/rs_feature_slice_factory.lua")
dofile("features/shared/rs_shared_bounds.lua")
dofile("features/tools/auction/rs_auction_read_model.lua")
-- 中文维护注释（2026-09-28，Phase 1 Batch E）：bridge 已退役；按 toc.g 顺序加载本套件需要的 Feature。
dofile("features/tools/market_analysis/rs_market_analysis_feature.lua")
dofile("features/tools/auction/rs_auction_feature.lua")
-- 中文维护注释（2026-09-28，Phase 1 Batch A/D）：tools_market_analysis 与 tools_auction 已从 bridge 拆出，
-- 本套件同时覆盖两者，因此必须按 toc.g 顺序把它们也加载进来。

-- 伴随浮窗使用 UI 框架及 WidgetHost。
S.RSUI = S.RSUI or {}
local function ParseSpec(a, b)
    if type(b) == "table" then return b end
    if type(a) == "table" then return a end
    return {}
end
local function MockContainer(spec)
    local c = { spec = ParseSpec(spec), visibility = "visible" }
    function c:SetVisibility(v) self.visibility = v; return v, true end
    return c
end
S.RSUI.VerticalBox = function(self, spec) return MockContainer(spec) end
S.RSUI.HorizontalBox = function(self, spec) return MockContainer(spec) end
S.RSUI.TextInput = function(self, spec)
    spec = ParseSpec(self, spec)
    local inp = { spec = spec, val = spec.value or "" }
    function inp:GetDraftValue() return self.val end
    function inp:SetValue(v) self.val = v end
    function inp:SetVisibility(v) self.visibility = v; return v, true end
    function inp:SetEnabled(v) self.enabled = v end
    return inp
end
S.RSUI.Button = function(self, spec)
    spec = ParseSpec(self, spec)
    local btn = { spec = spec, enabled = true, text = spec.text or "" }
    function btn:SetText(t) self.text = t end
    function btn:SetEnabled(e) self.enabled = e end
    function btn:SetVisibility(v) self.visibility = v; return v, true end
    return btn
end
S.RSUI.Text = function(self, spec)
    spec = ParseSpec(self, spec)
    local txt = { spec = spec, text = spec.text or "" }
    function txt:SetText(t) self.text = t end
    function txt:SetVisibility(v) self.visibility = v; return v, true end
    return txt
end
S.RSUI.TableView = function(self, spec)
    spec = ParseSpec(self, spec)
    local tv = { spec = spec, items = {}, viewState = "ready" }
    function tv:SetItems(items, rev) self.items = items or {}; self.rev = rev end
    function tv:SetViewState(state, info) self.viewState = state; self.viewInfo = info end
    function tv:GetItem(idx) return self.items[idx] end
    function tv:GetSelectedKey() return self.selectedKey end
    function tv:ClearSelection() self.selectedKey = nil; return true end
    function tv:SetSelectedIndex(idx) self.selectedKey = self.items[idx] and self.items[idx].key or nil; return true end
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
    BindFeatureLifecycle = function(self, id, options)
        self.lifecycle = self.lifecycle or {}
        self.lifecycle[id] = options
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

-- 加载拍卖伴随浮窗。
dofile("presentation/v3/widgets/rs_v3_auction_sidecar.lua")

local Feature = S.Features.tools_auction
local Query = S.Services.AuctionQueryV3
local Surface = S.Services.AuctionSurfaceV3
local QuoteQueue = S.Services.PriceQuoteQueueV3

-- 测试 1：功能注册元数据与契约。
Test("T1: Feature registry metadata & contracts", function()
    local reg = S.FeatureRegistry:Get("tools_auction")
    assert(reg ~= nil, "tools_auction must be in FeatureRegistry")
    assert(reg.id == "tools_auction", "id mismatch")
    assert(reg.route == "tools.auction_favorites", "route mismatch")
    assert(reg.name == "拍卖收藏", "name mismatch")
    assert(reg.category == "tools", "category mismatch")
    assert(reg.authority == "v3.auction", "authority mismatch")
    assert(reg.widgetCapable == true, "tools_auction must advertise its native-surface Sidecar capability")
    -- 中文维护注释（2026-09-15，拍卖收藏完成态回归）：用户已确认该功能进入完成区。
    -- 这里同时钉住导航完成态与 Registry 产品状态，防止后续残留的 pending/partial 元数据把它
    -- 再次下沉到“未完成”区。该断言只验证展示/产品元数据，不参与 AuctionQuery/Sidecar Authority。
    assert(reg.navigationDevelopmentState == "complete" and reg.navigationIncomplete ~= true, "tools_auction must be marked complete in navigation")
    assert(reg.status == "migrated_m1", "tools_auction completed product status must be migrated_m1")
    assert(reg.description == "拍卖关键词收藏、当前挂单查询与拍卖助手管理；打开拍卖行后可使用收藏、今日任务和临时清单工作区。", "auction registry description must be player-facing and explain the Sidecar workspace")
    assert(reg.apiPolicy == "explicit_server_query_plus_readonly_native_surface_observation", "apiPolicy mismatch")

    -- 核对必需的 API 依赖声明。
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

    -- 核对功能实现是否注册。
    assert(Feature ~= nil, "tools_auction Feature missing from S.Features")
    assert(Feature.AuctionQueryContractVersion >= 1, "AuctionQueryContractVersion >= 1 missing")
    assert(type(Feature.Commands) == "table", "Feature.Commands table missing")
    assert(type(Feature.Commands.Search) == "function", "Commands.Search missing")
    assert(type(Feature.Commands.AddFavorite) == "function", "Commands.AddFavorite missing")
    assert(type(Feature.Commands.RemoveFavorite) == "function", "Commands.RemoveFavorite missing")
    assert(type(Feature.Commands.Quote) == "function", "Commands.Quote missing")
    assert(type(Feature.Commands.SetExactMatch) == "function", "Commands.SetExactMatch missing")
    assert(type(Feature.Commands.SetResultLimit) == "function", "Commands.SetResultLimit missing")
    assert(type(Feature.Commands.SetSidecarEnabled) == "function", "Commands.SetSidecarEnabled missing")
    assert(type(Feature.IsSidecarEnabled) == "function", "Feature.IsSidecarEnabled missing")
end)

-- 测试 2：收藏关键词的添加、去重、数量边界与删除。
Test("T2: Favorite keywords: Add, deduplication, bounds & Remove", function()
    Feature:Enable()
    assert(Feature:AcquireConsumer("test_t2"), "AcquireConsumer failed")

    -- 清空测试状态，避免前一用例影响收藏断言。
    Feature.State.favorites = {}

    -- 1. 添加有效收藏。
    local ok, err = Feature.Commands:AddFavorite("铁锭")
    assert(ok == true, "AddFavorite failed: " .. tostring(err))
    assert(#Feature.State.favorites == 1, "Favorites count should be 1")
    assert(Feature.State.favorites[1] == "铁锭", "First favorite mismatch")

    -- 2. 验证去重：重复添加铁锭收藏必须失败。
    local dupOk, dupErr = Feature.Commands:AddFavorite("铁锭")
    assert(dupOk == false, "Re-adding duplicate favorite should fail")
    assert(tostring(dupErr):find("已存在") ~= nil, "Error message must mention already exists")
    assert(#Feature.State.favorites == 1, "Favorites count should still be 1")

    -- 3. 拒绝空字符串和纯空白关键词。
    local emptyOk, emptyErr = Feature.Commands:AddFavorite("   ")
    assert(emptyOk == false, "Empty keyword must be rejected")
    local controlOk, _ = Feature.Commands:AddFavorite("test\nitem")
    assert(controlOk == false, "Control characters must be rejected")

    -- 4. 验证 AUCTION_FAVORITE_MAX=20 的数量上限。
    for i = 2, 20 do
        local addOk = Feature.Commands:AddFavorite("材料_" .. tostring(i))
        assert(addOk == true, "Adding favorite " .. tostring(i) .. " should succeed")
    end
    assert(#Feature.State.favorites == 20, "Should have reached 20 favorites")
    local overOk, overErr = Feature.Commands:AddFavorite("材料_21")
    assert(overOk == false, "21st favorite must be rejected due to max limit")
    assert(tostring(overErr):find("上限") ~= nil, "Error should mention upper bound")

    -- 5. 验证 RemoveFavorite 删除收藏。
    local remInvalidOk = Feature.Commands:RemoveFavorite(999)
    assert(remInvalidOk == false, "Out of bounds index must be rejected")
    local remOk, remErr = Feature.Commands:RemoveFavorite(1) -- Remove "铁锭"
    assert(remOk == true, "RemoveFavorite(1) failed: " .. tostring(remErr))
    assert(#Feature.State.favorites == 19, "Favorites count should now be 19")
    assert(Feature.State.favorites[1] == "材料_2", "New first favorite should be 材料_2")

    -- 6. 核对收藏投影。
    local proj = Feature:GetProjection()
    assert(proj.favoriteCount == 19, "proj.favoriteCount mismatch")
    assert(proj.favoriteMax == 20, "proj.favoriteMax mismatch")

    -- 清理本用例的数据和订阅。
    Feature.State.favorites = { "原木", "粗糙的石头" }
    Feature:ReleaseConsumer("test_t2")
end)

-- 测试 2B：按稳定键增删改查收藏，保持旧字符串数组存档结构。
Test("T2B: Favorite rename, move, remove-by-keyword & clear", function()
    Feature.State.favorites = { "木材", "铁锭", "蜂蜜" }

    local renameOk, renameErr = Feature.Commands:RenameFavorite("铁锭", "铁矿石")
    assert(renameOk == true, "RenameFavorite failed: " .. tostring(renameErr))
    assert(Feature.State.favorites[1] == "木材" and Feature.State.favorites[2] == "铁矿石" and Feature.State.favorites[3] == "蜂蜜", "rename must preserve order and string-array schema")

    local duplicateOk = Feature.Commands:RenameFavorite("铁矿石", "木材")
    assert(duplicateOk == false, "rename must reject duplicate target keyword")

    local moveOk, moveErr = Feature.Commands:MoveFavorite("蜂蜜", -1)
    assert(moveOk == true, "MoveFavorite failed: " .. tostring(moveErr))
    assert(Feature.State.favorites[2] == "蜂蜜" and Feature.State.favorites[3] == "铁矿石", "move up must swap adjacent string entries")

    local edgeMoveOk = Feature.Commands:MoveFavorite("木材", -1)
    assert(edgeMoveOk == false, "moving first favorite further up must fail")

    local removeOk, removeErr = Feature.Commands:RemoveFavoriteByKeyword("蜂蜜")
    assert(removeOk == true, "RemoveFavoriteByKeyword failed: " .. tostring(removeErr))
    assert(#Feature.State.favorites == 2 and Feature.State.favorites[1] == "木材" and Feature.State.favorites[2] == "铁矿石", "remove-by-keyword must preserve remaining order")

    local clearOk, clearErr = Feature.Commands:ClearFavorites()
    assert(clearOk == true, "ClearFavorites failed: " .. tostring(clearErr))
    assert(#Feature.State.favorites == 0, "ClearFavorites must leave legacy favorites as empty array")

    Feature.State.favorites = { "原木", "粗糙的石头" }
end)

-- 测试 2C：AuctionSearchBridgeV3 原生同步成功或降级时均不阻塞搜索。
Test("T2C: Search bridge verified native sync and fallback", function()
    assert(auctionSearchBridgeLoaded == true, "AuctionSearchBridgeV3 failed to load: " .. tostring(auctionSearchBridgeLoadErr))
    local Bridge = S.Services.AuctionSearchBridgeV3
    assert(type(Bridge) == "table" and type(Bridge.Search) == "function", "AuctionSearchBridgeV3 contract missing")

    -- 已验证的 EditBox 候选必须同时满足：路径或名称具有搜索语义、类型为 EditBox，且写入后回读一致。
    local nativeText = ""
    mockAuctionContent.keywordSearchBox = {
        GetObjectType = function() return "EditBox" end,
        GetName = function() return "auctionKeywordSearch" end,
        SetText = function(self, value) nativeText = tostring(value) end,
        GetText = function() return nativeText end,
    }
    Bridge:ResetNativeCandidate("test_verified")
    Query:_CleanupNativeEdge(); Query.pending = nil; mockAuction.searchCalls = {}
    local ok, status = Bridge:Search("tools_auction", "木材", { exactMatch = false, resultLimit = 20 })
    assert(ok == true and status == "waiting", "bridge direct search must preserve AuctionQuery waiting contract")
    assert(#mockAuction.searchCalls == 1 and mockAuction.searchCalls[1].keyword == "木材", "bridge must issue exactly one authoritative server search")
    assert(nativeText == "木材", "verified native EditBox must receive keyword")
    local verified = Bridge:GetSnapshot()
    assert(verified.nativeSync == "success", "verified native sync must report success")
    assert(tostring(verified.candidatePath or ""):find("keywordSearchBox", 1, true) ~= nil, "candidate path must be diagnosable")

    -- 第二次查询前先结束当前请求，避免单请求约束干扰用例。
    mockAuction.searchedItems = {}; Query:_OnSearched()

    -- 找不到已验证候选时仍须发起服务器查询，桥接层报告降级。
    mockAuctionContent.keywordSearchBox = nil
    Bridge:ResetNativeCandidate("test_fallback")
    Query:_CleanupNativeEdge(); Query.pending = nil; mockAuction.searchCalls = {}
    local fallbackOk, fallbackStatus = Bridge:Search("tools_auction", "铁锭", { exactMatch = false, resultLimit = 20 })
    assert(fallbackOk == true and fallbackStatus == "waiting", "native-sync absence must not block direct search")
    assert(#mockAuction.searchCalls == 1 and mockAuction.searchCalls[1].keyword == "铁锭", "fallback must still query server exactly once")
    local fallback = Bridge:GetSnapshot()
    assert(fallback.nativeSync == "fallback" or fallback.nativeSync == "unavailable", "missing candidate must be reported as fallback/unavailable")
    assert((tonumber(fallback.fallbackCount) or 0) >= 1, "fallback counter must increase")
    mockAuction.searchedItems = {}; Query:_OnSearched()
end)

-- 测试 2D：原生拍卖内容中的不可访问或不透明 userdata 必须安全拒绝。
Test("T2D: Search bridge hostile userdata probe cannot break authoritative query", function()
    local Bridge = S.Services.AuctionSearchBridgeV3
    mockAuctionContent.keywordSearchBox = nil
    local hostile = io.tmpfile()
    assert(type(hostile) == "userdata", "test requires a userdata candidate")
    debug.setmetatable(hostile, { __index = function() error("opaque native userdata") end })
    mockAuctionContent.searchOpaqueNative = hostile
    Bridge:ResetNativeCandidate("test_hostile_userdata")
    Query:_CleanupNativeEdge(); Query.pending = nil; mockAuction.searchCalls = {}
    local callOk, searchOk, searchStatus = pcall(function()
        return Bridge:Search("tools_auction", "原木", { exactMatch = false, resultLimit = 20 })
    end)
    assert(callOk == true, "opaque native userdata must be contained by fail-closed probe")
    assert(searchOk == true and searchStatus == "waiting", "native probe failure must not block authoritative query")
    assert(#mockAuction.searchCalls == 1 and mockAuction.searchCalls[1].keyword == "原木", "authoritative query must still execute exactly once")
    local snap = Bridge:GetSnapshot()
    assert(snap.nativeSync == "fallback", "opaque userdata must degrade to fallback, not abort search")
    mockAuctionContent.searchOpaqueNative = nil
    mockAuction.searchedItems = {}; Query:_OnSearched()
end)

-- 测试 3：AuctionQueryV3 的九参数契约、单请求约束和超时保护。
Test("T3: AuctionQueryV3: 9-parameter call, SingleFlight & timeout guard", function()
    -- 重置查询状态，隔离后续请求断言。
    Query:_CleanupNativeEdge()
    Query.pending = nil
    mockAuction.searchCalls = {}

    -- 1. 核对输入校验。
    local badReqOk = Query:Search("", "keyword")
    assert(badReqOk == false, "Empty requester must be rejected")
    local badKeyOk = Query:Search("test", "")
    assert(badKeyOk == false, "Empty keyword must be rejected")

    -- 2. 按九参数契约成功派发搜索。
    local ok, status = Query:Search("tools_auction", "原木", { exactMatch = true, resultLimit = 15 })
    assert(ok == true, "Query:Search failed: " .. tostring(status))
    assert(status == "waiting", "Status must be waiting")
    assert(#mockAuction.searchCalls == 1, "Must have called SearchAuctionArticle once")

    local call = mockAuction.searchCalls[1]
    assert(call.page == 1, "page must be 1")
    assert(call.minLevel == 0 and call.maxLevel == 0, "level range must be 0-0 (no level cap)")
    assert(call.category == 1 and call.subCategory == 0, "category must be 1, 0")
    assert(call.exact == true, "exactMatch must be true")
    assert(call.keyword == "原木", "keyword mismatch")
    assert(call.minPrice == "0" and call.maxPrice == "0", "prices must be '0', '0'")

    -- 3. 等待回包期间拒绝并发查询。
    local dupOk, dupErr = Query:Search("tools_auction", "铁锭")
    assert(dupOk == false, "Concurrent search while pending must be rejected")
    assert(tostring(dupErr):find("等待") ~= nil, "Rejection error must mention pending search")

    -- 4. 验证超时保护。
    assert(Query.pending ~= nil, "Must have pending request")
    assert(S.Scheduler.tasks[Query.timeoutTask] ~= nil, "Timeout task must be scheduled")
    -- 手动推进超时回调，验证等待状态能够释放。
    local timeoutTask = S.Scheduler.tasks[Query.timeoutTask]
    timeoutTask.callback()
    assert(Query.pending == nil, "Pending must be cleared after timeout")
    local snap = Query:GetSnapshot("tools_auction")
    assert(snap.status == "failed", "Snapshot status must be failed after timeout")
    assert(tostring(snap.error):find("超时") ~= nil, "Snapshot error must mention timeout")
end)

-- 测试 4：原生 AUCTION_ITEM_SEARCHED 完成事件与结果归一化。
Test("T4: Native AUCTION_ITEM_SEARCHED completion edge & normalization", function()
    Query:_CleanupNativeEdge()
    Query.pending = nil
    mockAuction.searchCalls = {}

    -- 情形 A：搜索结果为空。
    mockAuction.searchedItems = {}
    local okA = Query:Search("tools_auction", "稀有不存在物品")
    assert(okA == true)
    -- 触发原生查询完成事件。
    Query:_OnSearched()
    local snapA = Query:GetSnapshot("tools_auction")
    assert(snapA.status == "empty", "0 items should result in status = empty")
    assert(snapA.count == 0, "count should be 0")
    assert(#snapA.rows == 0, "rows should be empty")

    -- 情形 B：多条结果包含不同字段，覆盖 itemGrade。
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

    -- 核对第 1 条结果。
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

    -- 核对第 2 条结果，覆盖嵌套 itemInfo 的提取。
    local r2 = snapB.rows[2]
    assert(r2.itemType == 18889, "r2 nested itemType mismatch")
    assert(r2.itemGrade == 1, "r2 nested itemGrade must be extracted as 1")
    assert(r2.name == "铁锭", "r2 nested name mismatch")
    assert(r2.quantity == 20, "r2 nested quantity mismatch")
    assert(r2.directPrice == 30000, "r2 nested buyoutPriceStr mismatch")
    assert(r2.seller == "MinerTwo", "r2 nested seller mismatch")
end)

-- 测试 5：功能需求生命周期及收藏、搜索结果两类行的投影。
Test("T5: Feature demand lifecycle & dual favorite/result rows projection", function()
    -- 第 5 组测试前清空需求状态，避免前序消费者影响断言。
    S.Events:Publish("v3.auction_surface.updated", { status = "ready", visible = false })
    for token in pairs(Feature.Demand and Feature.Demand.consumers or {}) do
        Feature:ReleaseConsumer(token)
    end
    Feature:Enable()
    assert(Feature.enabled == true, "Feature must be enabled")

    -- 核对消费者获取需求之前的初始状态。
    assert(Feature.AuctionQuerySubscribed ~= true, "Must not subscribe before consumer acquired")

    -- 获取消费者需求后，应激活 Demand 并订阅事件。
    assert(Feature:AcquireConsumer("test_t5"), "AcquireConsumer failed")
    assert(Feature.consumerCount == 1, "consumerCount should be 1")
    assert(Feature.AuctionQuerySubscribed == true, "Must subscribe to v3.auction_query.updated")
    assert(Feature.PriceQuoteSubscribed == true, "Must subscribe to v3.price_quote.completed")

    -- 配置收藏并执行搜索。
    Feature.State.favorites = { "原木", "铁矿石" }
    local okSearch = Feature.Commands:Search("原木")
    assert(okSearch == true, "Feature.Commands:Search failed")
    assert(Feature.State.searchStatus == "waiting", "searchStatus should be waiting")

    -- 触发搜索完成回包。
    Query:_OnSearched()
    Feature.Authority:Refresh("auction_query_updated")

    -- 验证投影同时包含收藏和搜索结果。
    local proj = Feature:GetProjection()
    assert(proj.favoriteCount == 2, "favoriteCount should be 2")
    assert(proj.searchStatus == "ready", "searchStatus should be ready")
    assert(proj.resultCount == 2, "resultCount should be 2")

    -- 从数据层及投影读取行，核对数据归属。
    local rows = proj.rows
    assert(#rows == 4, "Total rows must be 4 (2 favorites + 2 results)")
    assert(rows[1].kind == "favorite" and rows[1].name == "原木", "Row 1 must be favorite")
    assert(rows[2].kind == "favorite" and rows[2].name == "铁矿石", "Row 2 must be favorite")
    assert(rows[3].kind == "result" and rows[3].itemType == 18888, "Row 3 must be search result")
    assert(rows[4].kind == "result" and rows[4].itemType == 18889, "Row 4 must be search result")

    -- 释放消费者需求后必须清除订阅。
    Feature:ReleaseConsumer("test_t5")
    assert(Feature.consumerCount == 0, "consumerCount should be 0")
    assert(Feature.AuctionQuerySubscribed == false, "Must unsubscribe from v3.auction_query.updated")
    assert(Feature.PriceQuoteSubscribed == false, "Must unsubscribe from v3.price_quote.completed")
end)

-- 测试 6：有界分页计算。
Test("T6: Bounded paging calculation (25 items, 10 per page)", function()
    -- 构造 25 条结果，用于覆盖完整页和末尾不足一页的情况。
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

    -- 核对第 1 页。
    local p1, totalPages, r1, canPrev1, canNext1 = ComputePage(1)
    assert(p1 == 1 and totalPages == 3, "Page 1 count mismatch")
    assert(#r1 == 10, "Page 1 should have 10 rows")
    assert(r1[1].index == 1 and r1[10].index == 10, "Page 1 bounds mismatch")
    assert(canPrev1 == false, "Page 1 cannot prev")
    assert(canNext1 == true, "Page 1 can next")

    -- 核对第 2 页。
    local p2, _, r2, canPrev2, canNext2 = ComputePage(2)
    assert(p2 == 2, "Page 2 mismatch")
    assert(#r2 == 10, "Page 2 should have 10 rows")
    assert(r2[1].index == 11 and r2[10].index == 20, "Page 2 bounds mismatch")
    assert(canPrev2 == true and canNext2 == true, "Page 2 prev/next mismatch")

    -- 核对第 3 页，仅剩 5 条结果。
    local p3, _, r3, canPrev3, canNext3 = ComputePage(3)
    assert(p3 == 3, "Page 3 mismatch")
    assert(#r3 == 5, "Page 3 should have 5 rows")
    assert(r3[1].index == 21 and r3[5].index == 25, "Page 3 bounds mismatch")
    assert(canPrev3 == true and canNext3 == false, "Page 3 cannot next")

    -- 请求第 99 页时应限制到实际最后一页，即第 3 页。
    local p99, _, r99 = ComputePage(99)
    assert(p99 == 3, "Page 99 must clamp to max page 3")
    assert(#r99 == 5, "Clamped page rows mismatch")
end)

-- 测试 7：通过 PriceQuoteQueueV3 显式查询最低价。
Test("T7: Explicit lowest-price quote via PriceQuoteQueueV3", function()
    Feature:Enable()
    Feature:AcquireConsumer("test_t7")

    -- 验证 Quote 命令委托现有 PriceQuoteQueueV3 队列。
    assert(type(Feature.Commands.Quote) == "function", "Commands.Quote missing")

    local ok, status = Feature.Commands:Quote(18888, 3)
    assert(ok == true, "Commands:Quote failed: " .. tostring(status))

    -- 核对 tools_auction 对应的询价队列快照。
    local quoteSnap = QuoteQueue:GetSnapshot("tools_auction")
    assert(quoteSnap ~= nil, "Quote snapshot missing")
    assert(quoteSnap.itemType == 18888, "itemType mismatch in queue")
    assert((quoteSnap.itemGrade or quoteSnap.grade) == 3, "grade mismatch in queue")

    -- 推进共享调度器，处理当前队列项。
    local taskKey = QuoteQueue.taskId or QuoteQueue.taskName
    assert(S.Scheduler.tasks[taskKey] ~= nil, "Quote task must be scheduled")
    local quoteTask = S.Scheduler.tasks[taskKey]
    -- 维护（auction-full-lane-safety-1）：显式“报价”也不能侵占已打开的原生拍卖行。
    -- 原测试在 visible=true 时要求请求成功，漏掉了本轮整条协议的资源边界。
    quoteTask.callback()
    assert(QuoteQueue:GetActivitySnapshot().paused == true, "Quote must pause while native auction is visible")
    assert(QuoteQueue:GetSnapshot("tools_auction").status ~= "ready", "Visible native auction cannot admit a quote")
    local oldPosVis = _G.ADDON.GetContentMainScriptPosVis
    _G.ADDON.GetContentMainScriptPosVis = function() return nil, nil, nil, nil, false end
    -- 恢复事件推进出队，再调用 AskMarketPrice 和 GetLowestPrice；后续继续核对实际价格及投影。
    for _ = 1, 6 do
        h.ms = h.ms + QuoteQueue.intervalMs
        quoteTask.callback()
    end
    _G.ADDON.GetContentMainScriptPosVis = oldPosVis

    -- 完成询价后应记录替身最低价：125000，即 12 金 50 银。
    local compSnap = QuoteQueue:GetSnapshot("tools_auction")
    assert(compSnap.status == "ready", "Quote status should be ready after processing")
    assert(compSnap.price == 125000, "Lowest price should be 125000, got: " .. tostring(compSnap.price))

    -- 投影必须包含本次询价结果。
    local proj = Feature:GetProjection()
    assert(proj.quoteStatus == "ready", "Projection quoteStatus mismatch")
    assert(proj.quotePrice == 125000, "Projection quotePrice mismatch")

    Feature:ReleaseConsumer("test_t7")
end)

-- 测试 8：AuctionSurfaceV3 的五返回值、四返回值原生几何与停用清理。
Test("T8: AuctionSurfaceV3: 5-value & 4-value native geometry & cleanup", function()
    Surface:Stop("test_init")
    assert(Surface.started == false, "Must be stopped initially")

    -- 1. 启动观察服务。
    local okStart, errStart = Surface:Start()
    assert(okStart == true, "Surface:Start failed: " .. tostring(errStart))
    assert(Surface.started == true, "started must be true")
    assert(S.Scheduler.tasks[Surface.taskId] ~= nil, "Observer task must be registered in Scheduler")

    -- 2. 五返回值契约为 (x, y, width, height, visible)。
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

    -- 3. 覆盖 RU 四返回值兼容契约 (x, y, width, height, nil)；第五个布尔值缺失时结合有效几何和内容可见性判断。
    _G.ADDON.GetContentMainScriptPosVis = function(self, id)
        return 320, 210, 750, 550 -- 第五个返回值为 nil。
    end
    Surface:Refresh("test_4val", true)
    local snap4 = Surface:GetSnapshot()
    assert(snap4.status == "ready", "snap4 status mismatch")
    assert(snap4.visible == true, "snap4 visible must resolve to true from content/geometry")
    assert(snap4.x == 320 and snap4.y == 210, "snap4 position mismatch")

    -- 4. 内容隐藏时应判断为关闭状态。
    mockAuctionContent.IsVisible = function() return false end
    _G.ADDON.GetContentMainScriptPosVis = function(self, id)
        return 0, 0, 0, 0, false
    end
    Surface:Refresh("test_closed", true)
    local snapClosed = Surface:GetSnapshot()
    assert(snapClosed.visible == false, "snapClosed must be invisible")

    -- 恢复原生接口测试替身。
    mockAuctionContent.IsVisible = function() return true end
    _G.ADDON.GetContentMainScriptPosVis = function(self, id)
        return 200, 150, 820, 600, true
    end

    -- 5. 停用观察服务并清理资源。
    Surface:Stop("test_teardown")
    assert(Surface.started == false, "started must be false after Stop")
    assert(S.Scheduler.tasks[Surface.taskId] == nil, "Scheduler task must be removed after Stop")
end)

-- 测试 9：拍卖伴随浮窗的原生窗口跟随与锚定。
Test("T9: AuctionSidecar widget: independent placement & native visibility lifecycle", function()
    local sidecarSpec = S.UIV3.WidgetHost:GetSpec("tools.auction_sidecar")
    assert(sidecarSpec ~= nil, "tools.auction_sidecar widget spec must be registered")
    assert(sidecarSpec.featureId == "tools_auction", "featureId mismatch")

    local SidecarController = S.UIV3.AuctionSidecar
    assert(SidecarController ~= nil, "AuctionSidecar controller missing")

    -- 1. 原生拍卖窗口打开后，伴随浮窗显示。
    local previousInstance=S.UIV3.WidgetHost:GetInstance("tools.auction_sidecar")
    local previousX,previousY=previousInstance and previousInstance.shell.x,previousInstance and previousInstance.shell.y
    local openSnapshot = { status = "ready", visible = true, x = 400, y = 200, width = 800, height = 600, revision = 10 }
    S.Events:Publish("v3.auction_surface.updated", openSnapshot)

    assert(S.UIV3.WidgetHost:IsVisible("tools.auction_sidecar") == true, "Sidecar must be visible when native auction opens")
    assert(SidecarController.nativeVisible == true, "nativeVisible must be true")

    local instance = S.UIV3.WidgetHost:GetInstance("tools.auction_sidecar")
    assert(instance ~= nil, "Sidecar instance must exist")
    assert(instance.acquired == true, "Sidecar must have acquired Consumer")

    -- 2. 伴随浮窗放在拍卖窗口相邻位置：宽度 300px，auctionX=400，因此 x=400-300-8=92。
    if previousInstance then
        assert(instance.shell.x==previousX and instance.shell.y==previousY,"native update cannot move independent sidecar")
    else
        assert(instance.shell.x==92 and instance.shell.y==200,"first default must be left of native auction")
    end
    assert(instance.surface.spec.movable==true and instance.state.userMoved==false,"unmodified default must allow dragging")

    -- 3. 原生拍卖窗口关闭后，伴随浮窗隐藏。
    local closeSnapshot = { status = "ready", visible = false, x = 0, y = 0, width = 0, height = 0, revision = 11 }
    S.Events:Publish("v3.auction_surface.updated", closeSnapshot)

    assert(S.UIV3.WidgetHost:IsVisible("tools.auction_sidecar") == false, "Sidecar must hide when native auction closes")
    assert(SidecarController.nativeVisible == false, "nativeVisible must be false")
    assert(instance.acquired == false, "Consumer must be released when hidden")

    -- 4. 覆盖用户手动关闭浮窗。
    S.Events:Publish("v3.auction_surface.updated", openSnapshot)
    assert(S.UIV3.WidgetHost:IsVisible("tools.auction_sidecar") == true)
    instance.surface.spec.onClosed(instance.surface, "user_click_close")
    assert(SidecarController.dismissed == true, "dismissed flag must be set on manual close")

    -- 原生窗口仍打开时，后续状态刷新不能重新打开用户已关闭的伴随浮窗。
    S.Events:Publish("v3.auction_surface.updated", openSnapshot)
    assert(S.UIV3.WidgetHost:IsVisible("tools.auction_sidecar") == false, "Dismissed sidecar must not re-open while native window remains open")

    -- 原生窗口关闭后重新打开时清除 dismissed 状态，允许再次显示伴随浮窗。
    S.Events:Publish("v3.auction_surface.updated", closeSnapshot)
    assert(SidecarController.dismissed == false, "dismissed flag must reset when native closes")
    S.Events:Publish("v3.auction_surface.updated", openSnapshot)
    assert(S.UIV3.WidgetHost:IsVisible("tools.auction_sidecar") == true, "Sidecar re-opens on fresh native auction open")

    -- 清理最后一组消费者和窗口状态。
    S.Events:Publish("v3.auction_surface.updated", closeSnapshot)
end)

-- 测试 9A：主页面可以显式恢复用户手动关闭的伴随浮窗。
Test("T9A: AuctionSidecar explicit restore contract", function()
    local controller = S.UIV3.AuctionSidecar
    assert(type(controller.GetControlState) == "function", "AuctionSidecar must expose read-only control state for the main page")
    assert(type(controller.RequestShow) == "function", "AuctionSidecar must expose an explicit user-requested restore action")
    assert(type(controller.ControlTopic) == "string" and controller.ControlTopic ~= "", "AuctionSidecar control state topic missing")

    local openSnapshot = { status = "ready", visible = true, x = 400, y = 200, width = 800, height = 600, revision = 15 }
    S.Events:Publish("v3.auction_surface.updated", openSnapshot)
    local instance = S.UIV3.WidgetHost:GetInstance("tools.auction_sidecar")
    assert(instance ~= nil, "sidecar instance unavailable")

    instance.surface.spec.onClosed(instance.surface, "user_click_close")
    local dismissed = controller:GetControlState()
    assert(dismissed.nativeVisible == true, "native auction must remain open after manual sidecar close")
    assert(dismissed.visible == false, "sidecar must be hidden after manual close")
    assert(dismissed.dismissed == true, "manual close must be represented as dismissed")
    assert(dismissed.canShow == true, "main page must be allowed to restore a dismissed sidecar while auction is open")

    local restored, restoreErr = controller:RequestShow("test_main_page_restore")
    assert(restored == true, "explicit restore failed: " .. tostring(restoreErr))
    local restoredState = controller:GetControlState()
    assert(restoredState.visible == true and restoredState.dismissed == false, "explicit restore must show sidecar and clear dismissal")

    local closeSnapshot = { status = "ready", visible = false, x = 0, y = 0, width = 0, height = 0, revision = 16 }
    S.Events:Publish("v3.auction_surface.updated", closeSnapshot)
    local blocked, blockedErr = controller:RequestShow("test_closed_native")
    assert(blocked == false, "main page must not create a detached sidecar while native auction is closed")
    assert(tostring(blockedErr):find("拍卖行", 1, true) ~= nil, "closed-native error must explain that auction house needs to be opened")
end)

-- 测试 9A1：持久化的伴随浮窗开关管理观察服务生命周期。
Test("T9A1: AuctionSidecar persistent enable/disable preference", function()
    local controller = S.UIV3.AuctionSidecar
    local store = S.Persistence:GetStore(Feature.storeId)
    assert(type(store) == "table" and type(store.apply) == "function" and type(store.get) == "function", "auction store contract unavailable")

    -- 旧存档没有 sidecarEnabled 字段时保持原有行为，即默认允许自动显示伴随浮窗。
    store.apply({ keyword = "", favorites = {}, exactMatch = false, resultLimit = 20 })
    assert(Feature:IsSidecarEnabled() == true, "legacy auction payload must default Sidecar to enabled")

    local openSnapshot = { status = "ready", visible = true, x = 400, y = 200, width = 800, height = 600, revision = 17 }
    S.Events:Publish("v3.auction_surface.updated", openSnapshot)
    assert(S.UIV3.WidgetHost:IsVisible("tools.auction_sidecar") == true, "precondition: Sidecar should be visible while enabled")

    local offOk, offErr = Feature.Commands:SetSidecarEnabled(false)
    assert(offOk == true, "disabling Sidecar failed: " .. tostring(offErr))
    assert(Feature:IsSidecarEnabled() == false, "Sidecar preference must become false")
    assert(store.get().sidecarEnabled == false, "disabled preference must be part of persistent auction payload")
    assert(Surface.started == false, "disabled Sidecar must release AuctionSurface observer")
    assert(S.UIV3.WidgetHost:IsVisible("tools.auction_sidecar") == false, "disabling must immediately hide an already-visible Sidecar")
    local offState = controller:GetControlState()
    assert(offState.enabled == false and offState.canShow == false, "controller must expose disabled state and block manual show")
    local blocked, blockedErr = controller:RequestShow("test_disabled_preference")
    assert(blocked == false and tostring(blockedErr):find("开启", 1, true) ~= nil, "manual show must be blocked while Sidecar preference is off")

    -- 持久化的 false 偏好必须阻止功能启用或重载后重新启动每 250ms 执行的原生 AuctionSurface 观察任务。
    assert(Feature:Disable("t9a1_pref_off") == true, "feature disable with Sidecar off failed")
    assert(Feature:Enable("t9a1_pref_off_reload") == true, "feature enable with Sidecar off failed")
    assert(Surface.started == false, "persisted Sidecar-off preference must survive Feature enable without restarting observer")
    assert(S.UIV3.WidgetHost:IsVisible("tools.auction_sidecar") == false, "Feature enable must not resurrect Sidecar while preference is off")

    -- 原生拍卖窗口已打开时重新启用观察服务，应立即读取真实窗口状态并自动显示浮窗。
    local onOk, onErr = Feature.Commands:SetSidecarEnabled(true)
    assert(onOk == true, "re-enabling Sidecar failed: " .. tostring(onErr))
    assert(Feature:IsSidecarEnabled() == true, "Sidecar preference must become true")
    assert(store.get().sidecarEnabled == true, "enabled preference must be persisted")
    assert(Surface.started == true, "re-enabled Sidecar must restart AuctionSurface observer")
    assert(S.UIV3.WidgetHost:IsVisible("tools.auction_sidecar") == true, "re-enable while auction is open must immediately show Sidecar")

    Surface:Stop("t9a1_cleanup")
end)

-- 测试 9A2：拍卖主页提供伴随浮窗说明和入口控件。
Test("T9A2: Auction main page Sidecar entry layout contract", function()
    local pageFile = assert(io.open("presentation/v3/pages/rs_v3_business_pages.lua", "rb"))
    local pageText = pageFile:read("*a"); pageFile:close()
    assert(pageText:find('auctionSidecarEntryContractVersion = 2', 1, true) ~= nil,
        "business page contract must record the auction Sidecar entry layout")
    assert(pageText:find('id = "v3_business_tools_auction_sidecar_card"', 1, true) ~= nil,
        "auction page must build a dedicated Sidecar explanation card")
    assert(pageText:find('id = "v3_business_tools_auction_sidecar_status"', 1, true) ~= nil,
        "auction page must show native-auction/Sidecar status")
    assert(pageText:find('id = "v3_business_tools_auction_sidecar_enabled"', 1, true) ~= nil,
        "auction page must expose an independent Sidecar enable/disable toggle")
    assert(pageText:find('SetSidecarEnabled(value == true)', 1, true) ~= nil,
        "auction page toggle must persist through the tools_auction command facade")
    assert(pageText:find('id = "v3_business_tools_auction_sidecar_show"', 1, true) ~= nil,
        "auction page must expose a restore/show button")
    assert(pageText:find('RequestShow("auction_main_page")', 1, true) ~= nil,
        "auction page show button must route through AuctionSidecar controller instead of WidgetHost directly")
    assert(pageText:find('ControlTopic', 1, true) ~= nil,
        "auction page must listen to Sidecar control-state changes while active")
end)

-- 测试 9B：伴随浮窗的三个工作区页签及显式行操作。
Test("T9B: AuctionSidecar favorites/daily/temp workspace", function()
    local openSnapshot = { status = "ready", visible = true, x = 400, y = 200, width = 800, height = 600, revision = 20 }
    S.Events:Publish("v3.auction_surface.updated", openSnapshot)
    local instance = S.UIV3.WidgetHost:GetInstance("tools.auction_sidecar")
    assert(instance ~= nil, "sidecar instance unavailable")
    assert(type(instance.tabButtons) == "table" and instance.tabButtons.favorites and instance.tabButtons.daily and instance.tabButtons.temp, "three tab buttons missing")
    assert(type(instance.SetTab) == "function" and instance.activeTab == "favorites", "default tab must be favorites")
    assert(instance.editButton and instance.upButton and instance.downButton and instance.clearButton, "CRUD/move controls missing")

    -- 激活单条收藏会显式发起真实搜索，不能转换为后台轮询。
    Feature.State.favorites = { "木材", "铁锭" }; Feature:Refresh("sidecar_t9b")
    instance:SetTab("favorites"); instance:Refresh()
    Query:_CleanupNativeEdge(); Query.pending = nil; mockAuction.searchCalls = {}
    local favoriteRow = instance.currentRows[1]
    local activated = instance.table.spec.onItemActivated(favoriteRow, 1, favoriteRow.key, instance.table, "row_click")
    assert(activated == true and #mockAuction.searchCalls == 1 and mockAuction.searchCalls[1].keyword == "木材", "favorite click must explicitly search selected keyword")
    mockAuction.searchedItems = {}; Query:_OnSearched()

    -- 每日页签仅在激活期间获取需求；点击材料发起搜索，点击候选仅选择该项。
    assert(instance:SetTab("daily") == true and instance.activeTab == "daily", "daily tab switch failed")
    assert(dailySidecarConsumers == 1, "daily tab must acquire one demand consumer")
    instance:Refresh()
    local materialRow, recipeRow
    for _, row in ipairs(instance.currentRows or {}) do if row.kind == "daily_material" then materialRow = row elseif row.kind == "daily_recipe" then recipeRow = recipeRow or row end end
    assert(materialRow and recipeRow, "daily rows must expose recipe choices and materials")
    Query:_CleanupNativeEdge(); Query.pending = nil; mockAuction.searchCalls = {}
    assert(instance.table.spec.onItemActivated(materialRow, 1, materialRow.key, instance.table, "row_click") == true, "daily material activation failed")
    assert(#mockAuction.searchCalls == 1 and mockAuction.searchCalls[1].keyword == "木材", "daily material click must search material")
    mockAuction.searchedItems = {}; Query:_OnSearched()
    assert(instance.table.spec.onItemActivated(recipeRow, 1, recipeRow.key, instance.table, "row_click") == true, "daily recipe activation must select candidate")
    assert(S.Services.DailyAuctionMaterialsV3.selectedRecipe == recipeRow.recipe, "daily recipe selection not routed to service")

    -- 临时页签释放每日任务需求，支持手动添加，数据仅在当前会话保留。
    assert(instance:SetTab("temp") == true and dailySidecarConsumers == 0, "leaving daily tab must release quest demand")
    instance.input:SetValue("蜂蜜")
    instance.qtyInput:SetValue("3")
    local addOk, addErr = instance.addButton.onClick()
    assert(addOk == true, "temporary manual add failed: " .. tostring(addErr))
    local tempSnap = S.Services.AuctionSessionListV3:GetSnapshot()
    assert(#tempSnap.groups >= 1, "temporary group missing")
    local found = false
    for _, group in ipairs(tempSnap.groups) do for _, material in ipairs(group.materials or {}) do if material.name == "蜂蜜" and material.count == 3 then found = true end end end
    assert(found, "manual temporary material/count missing")

    S.Events:Publish("v3.auction_surface.updated", { status="ready", visible=false, revision=21 })
    assert(dailySidecarConsumers == 0, "sidecar hide must not leak daily consumer")
end)

-- 回归约束：FloatingSurface 保留 <surface-id>_status 作为底部状态栏标识，同一构建 Generation 内的内容 Text 不能复用该逻辑 ID。
Test("T9C: AuctionSidecar content status id does not collide with FloatingSurface footer", function()
    local sidecarFile = assert(io.open("presentation/v3/widgets/rs_v3_auction_sidecar.lua", "rb"))
    local sidecarText = sidecarFile:read("*a"); sidecarFile:close()
    assert(sidecarText:find('id = "v3_auction_sidecar_status"', 1, true) == nil,
        "content status logical id collides with WindowShell-generated v3_auction_sidecar_status")
    assert(sidecarText:find('id = "v3_auction_sidecar_action_status"', 1, true) ~= nil,
        "sidecar must use a dedicated content/action status logical id")
end)

-- 每日与临时页签切换会改变 searchRow 是否参与布局。
-- 可见性变化后必须重新布局 FloatingSurface 外壳，否则搜索行复用旧边界，而操作行仍处于每日页签的位置，导致两行重叠。
Test("T9D: AuctionSidecar tab visibility change reapplies floating layout", function()
    local openSnapshot = { status = "ready", visible = true, x = 400, y = 200, width = 800, height = 600, revision = 30 }
    S.Events:Publish("v3.auction_surface.updated", openSnapshot)
    local instance = S.UIV3.WidgetHost:GetInstance("tools.auction_sidecar")
    assert(instance ~= nil and instance.surface ~= nil, "sidecar instance/surface unavailable")

    local originalApply = instance.surface.ApplyLayout
    local layoutCalls = 0
    instance.surface.ApplyLayout = function(self, fromMetricsChange)
        layoutCalls = layoutCalls + 1
        return originalApply(self, fromMetricsChange)
    end

    assert(instance:SetTab("daily") == true, "daily tab switch failed")
    assert(instance.searchRow.visibility == "collapsed", "daily tab must collapse search row")
    assert(instance:SetTab("temp") == true, "temp tab switch failed")
    assert(instance.searchRow.visibility == "visible", "temp tab must restore search row")
    assert(layoutCalls >= 2, "each search-row visibility transition must trigger FloatingSurface ApplyLayout; calls=" .. tostring(layoutCalls))

    instance.surface.ApplyLayout = originalApply
end)

-- 临时页签的数量输入必须说明含义；紧凑伴随浮窗需要比共享默认值略短的原生输入光标。
Test("T9E: AuctionSidecar temp quantity affordance and compact caret", function()
    local sidecarFile = assert(io.open("presentation/v3/widgets/rs_v3_auction_sidecar.lua", "rb"))
    local sidecarText = sidecarFile:read("*a"); sidecarFile:close()
    assert(sidecarText:find('id = "v3_auction_sidecar_qty_label"', 1, true) ~= nil,
        "temporary quantity field needs an explicit quantity marker")
    assert(sidecarText:find('SetVisible(self.qtyLabel, self.activeTab == "temp")', 1, true) ~= nil,
        "quantity marker must follow the temporary-only quantity input visibility")
    assert(sidecarText:find('id = "v3_auction_sidecar_keyword"', 1, true) ~= nil
        and sidecarText:find('height = 22', 1, true) ~= nil,
        "sidecar edit boxes need an explicit compact creation height so native caret is not oversized")
end)

-- 测试 10：基础门禁与验收契约。
Test("T10: FoundationGate & Acceptance contract verification", function()
    -- 1. 核对 v3_auction_query_contract。
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

    -- 2. 核对 v3_auction_sidecar_contract。
    assert(type(Surface) == "table", "Surface must be table")
    assert((tonumber(Surface.version) or 0) >= 2, "AuctionSurfaceV3 version >= 2")
    assert((tonumber(Surface.VisibilityContractVersion) or 0) >= 2, "VisibilityContractVersion >= 2")
    assert(type(Surface.GetSnapshot) == "function", "Surface.GetSnapshot must be function")
    assert(type(Surface.Start) == "function", "Surface.Start must be function")
    assert(type(Surface.Stop) == "function", "Surface.Stop must be function")
    assert(type(S.UIV3.AuctionSidecar) == "table", "AuctionSidecar controller must be table")

    -- 3. 核对验收契约条款。
    assert(Feature.Commands.AddFavorite ~= nil, "AddFavorite command must exist")
    assert(Feature.Commands.RemoveFavorite ~= nil, "RemoveFavorite command must exist")
    assert(Feature.Commands.Quote ~= nil, "Quote command must exist")
    assert(Feature.Commands.SetExactMatch ~= nil, "SetExactMatch command must exist")
    assert(Feature.Commands.SetResultLimit ~= nil, "SetResultLimit command must exist")

    local sidecarSpec = S.UIV3.WidgetHost:GetSpec("tools.auction_sidecar")
    assert(sidecarSpec ~= nil and sidecarSpec.featureId == "tools_auction", "Sidecar spec must exist with featureId tools_auction")

    -- 4. 核对拍卖工作区的增删改查、每日任务与会话数据归属，以及可选原生搜索同步桥接。
    local Bridge = S.Services.AuctionSearchBridgeV3
    local Session = S.Services.AuctionSessionListV3
    local Daily = S.Services.DailyAuctionMaterialsV3
    assert(type(S.UIV3.AuctionSidecar) == "table" and (tonumber(S.UIV3.AuctionSidecar.AuctionWorkspaceContractVersion) or 0) >= 1, "Auction workspace sidecar contract missing")
    assert(type(Session) == "table" and (tonumber(Session.SessionListContractVersion) or 0) >= 1 and Session.PersistenceStoreId == nil, "Session-only auction list contract missing")
    assert(type(Daily) == "table" and (tonumber(Daily.DailyMaterialContractVersion) or 0) >= 2, "Daily auction materials contract missing")
    assert(type(Bridge) == "table" and (tonumber(Bridge.SearchBridgeContractVersion) or 0) >= 1 and (tonumber(Bridge.NativeSyncContractVersion) or 0) >= 1, "Search bridge contract missing")
    assert(type(Feature.Commands.RenameFavorite) == "function" and type(Feature.Commands.MoveFavorite) == "function" and type(Feature.Commands.RemoveFavoriteByKeyword) == "function" and type(Feature.Commands.ClearFavorites) == "function", "Favorite CRUD commands incomplete")
    local gateFile = assert(io.open("core/rs_foundation_gate.lua", "rb")); local gateText = gateFile:read("*a"); gateFile:close()
    local acceptanceFile = assert(io.open("presentation/v3/rs_v3_acceptance.lua", "rb")); local acceptanceText = acceptanceFile:read("*a"); acceptanceFile:close()
    local reportFile = assert(io.open("core/rs_self_check_report.lua", "rb")); local reportText = reportFile:read("*a"); reportFile:close()
    assert(gateText:find("v3_auction_workspace_contract", 1, true) ~= nil, "FoundationGate must expose auction workspace contract")
    assert(acceptanceText:find("auction_workspace_contract_v2", 1, true) ~= nil, "Acceptance must verify auction workspace contract")
    assert(reportText:find("AUCTION_SEARCH_BRIDGE", 1, true) ~= nil, "Self-check report must expose native auction search sync evidence")
    assert(reportText:find("DAILY_AUCTION_MATERIALS", 1, true) ~= nil, "Self-check report must expose daily trade task discovery evidence")
end)

-- 使用真实伴随浮窗投影和渲染契约覆盖部分每日任务；原生 UI 基础控件为测试替身，禁止自动发起拍卖搜索。
Test("Daily UI keeps real missing task materials without internal match reasons", function()
    local daily = S.Services.DailyAuctionMaterialsV3
    local old = daily.snapshot
    daily.snapshot = { status="partial", revision=9001, pendingTitleCount=0, unresolvedTaskCount=1, tasks={
        {questId=990011,title="[特产-西部] 珊瑚海岸的保存特产",recipes={},selectedRecipe="Sanddeep Preserved Specialty",materialStatus="ready",materials={
            {key="item:30902",name="研磨谷物",count=200,itemType=30902,searchable=true}}},
        {questId=990012,title="[特产-西部] 未收录测试区域的保存特产",recipes={},materials={},materialStatus="unresolved",matchReason="zone_unmatched"},
    }}
    local instance = assert(S.UIV3.WidgetHost:GetInstance("tools.auction_sidecar"))
    local before = #mockAuction.searchCalls
    assert(instance:SetTab("daily")); assert(instance:Refresh())
    local headers, unknown = 0, nil
    for _, row in ipairs(instance.currentRows) do
        if row.kind=="daily_task" then headers=headers+1; if row.questId==990012 then unknown=row end end
        assert(not (row.kind=="daily_material" and row.questId==990012), "unmatched task acquired fabricated materials")
    end
    assert(headers==2 and unknown, "second task header disappeared")
    assert(unknown.status=="材料暂不可用", "missing materials must have a player-facing state")
    instance.table.spec.onItemActivated(unknown, 3, unknown.key, instance.table, "row_click")
    assert(#mockAuction.searchCalls==before, "unmatched task must never trigger native search")
    daily.snapshot=old; assert(instance:SetTab("temp"))
end)

Test("Daily UI explains title readiness instead of claiming no daily tasks", function()
    local daily=S.Services.DailyAuctionMaterialsV3; local old=daily.snapshot
    daily.snapshot={status="waiting_titles",revision=9002,pendingTitleCount=2,tasks={}}
    local instance=assert(S.UIV3.WidgetHost:GetInstance("tools.auction_sidecar"))
    assert(instance:SetTab("daily")); assert(instance:Refresh())
    assert(instance.table.viewInfo and instance.table.viewInfo.title=="任务标题尚未就绪", "unready data falsely displayed as no tasks")
    assert(tostring(instance.table.viewInfo.detail):find("2",1,true), "pending title count missing")
    daily.snapshot=old; assert(instance:SetTab("temp"))
end)

Test("Daily UI does not label empty selected recipe as parsed materials", function()
    local daily=S.Services.DailyAuctionMaterialsV3; local old=daily.snapshot
    daily.snapshot={status="ready",revision=9003,tasks={{questId=990012,title="已核任务",recipes={},selectedRecipe="test-recipe",materialStatus="empty",materials={}}}}
    local instance=assert(S.UIV3.WidgetHost:GetInstance("tools.auction_sidecar"))
    assert(instance:SetTab("daily")); assert(instance:Refresh())
    assert(instance.currentRows[1].status=="材料暂不可用", "selected recipe without rows must not claim parsed")
    daily.snapshot=old; assert(instance:SetTab("temp"))
end)

Test("Daily UI footer counts shopping tasks and materials without parser status", function()
    local daily=S.Services.DailyAuctionMaterialsV3; local old=daily.snapshot
    daily.snapshot={status="partial",revision=9004,pendingTitleCount=0,unresolvedTaskCount=1,tasks={
        {questId=990011,title="已核任务",recipes={},materials={}},
        {questId=990012,title="未匹配任务",recipes={},materials={},materialStatus="unresolved",matchReason="recipe_unmatched"},
    }}
    local instance=assert(S.UIV3.WidgetHost:GetInstance("tools.auction_sidecar"))
    local original=instance.surface.SetStatus; local footer
    instance.surface.SetStatus=function(self,text,tone) footer=text; return original(self,text,tone) end
    assert(instance:SetTab("daily")); assert(instance:Refresh())
    assert(tostring(footer):find("2 项任务",1,true), "footer lacks total task count")
    assert(tostring(footer):find("0 项材料",1,true), "footer lacks actual material count")
    assert(not tostring(footer):find("待匹配",1,true), "parser status leaked into shopping footer")
    local found=false
    for _, row in ipairs(instance.currentRows) do if row.questId==990012 and row.kind=="daily_task" then found=row.status=="材料暂不可用" end end
    assert(found, "missing materials falsely appeared ready")
    instance.surface.SetStatus=original; daily.snapshot=old; assert(instance:SetTab("temp"))
end)

Test("Daily shopping shows only a fixed task and its ingredients, then clicks search", function()
    local daily=S.Services.DailyAuctionMaterialsV3; local old=daily.snapshot
    daily.snapshot={status="ready",revision=9010,tasks={{questId=990014,
        title="[特产-东部] 草原之脉的保存特制特产",recipes={"Windscour Preserved Gilda Specialty"},
        selectedRecipe="Windscour Preserved Gilda Specialty",requiresSelection=false,materialStatus="ready",materials={
            {key="item:1",name="干净的肉串",count=300,searchable=true},
            {key="item:2",name="辣木树果实",count=3,searchable=true},
            {key="item:3",name="德翡纳之星",count=2,searchable=false},
        }}}}
    local instance=assert(S.UIV3.WidgetHost:GetInstance("tools.auction_sidecar"))
    local before=#mockAuction.searchCalls
    assert(instance:SetTab("daily")); assert(instance:Refresh())
    assert(#instance.currentRows==4, "fixed recipe added a redundant choice row")
    assert(instance.currentRows[1].kind=="daily_task" and instance.currentRows[1].status=="", "parsed-state clutter remains")
    for i=2,4 do assert(instance.currentRows[i].kind=="daily_material") end
    assert(instance.currentRows[2].status=="×300" and instance.currentRows[3].status=="×3" and instance.currentRows[4].status=="×2")
    assert(#mockAuction.searchCalls==before, "rendering performed an auction query")
    Query:_CleanupNativeEdge(); Query.pending=nil; mockAuction.searchCalls={}
    assert(instance.table.spec.onItemActivated(instance.currentRows[2]))
    assert(#mockAuction.searchCalls==1 and mockAuction.searchCalls[1].keyword=="干净的肉串", "shopping material click lost native search")
    mockAuction.searchedItems={}; Query:_OnSearched()
    local starOk=instance.table.spec.onItemActivated(instance.currentRows[4])
    assert(starOk==false and #mockAuction.searchCalls==1, "bound resource searched auction")
    daily.snapshot=old; assert(instance:SetTab("temp"))
end)

Test("Daily choices use actual product names only when recipes are alternatives", function()
    local daily=S.Services.DailyAuctionMaterialsV3; local old=daily.snapshot
    daily.snapshot={status="ready",revision=9011,tasks={{questId=990015,title="居民交付任务",
        recipes={"recipe-a","recipe-b"},requiresSelection=true,materials={},materialStatus="waiting_selection",
        recipeOptions={{recipe="recipe-a",name="[虎脊山脉]特产"},{recipe="recipe-b",name="[摩哈特比]特产"}},
    }}}
    local instance=assert(S.UIV3.WidgetHost:GetInstance("tools.auction_sidecar"))
    assert(instance:SetTab("daily")); assert(instance:Refresh())
    assert(instance.currentRows[1].status=="请选择制作货物")
    assert(#instance.currentRows==3 and instance.currentRows[2].kind=="daily_recipe")
    assert(instance.currentRows[2].name=="  [虎脊山脉]特产" and instance.currentRows[3].name=="  [摩哈特比]特产")
    assert(instance.table.spec.onItemActivated(instance.currentRows[3]))
    assert(daily.selectedRecipe=="recipe-b", "choice bypassed service")
    daily.snapshot=old; assert(instance:SetTab("temp"))
end)

Test("Auction module diagnostic includes real daily proof without acquiring or querying", function()
    local hub=assert(S.ModuleDiagnosticsHub)
    local provider
    for _, row in ipairs(hub.providers.tools_auction or {}) do if row.id=="daily_materials" then provider=row end end
    assert(provider, "auction module report has no daily materials provider")
    local old=S.Services.DailyAuctionMaterialsV3
    dofile("services/rs_daily_auction_materials_v3.lua")
    local daily=assert(S.Services.DailyAuctionMaterialsV3)
    daily.snapshot={status="partial",revision=1,activeQuestCount=2,pendingTitleCount=1,
        pendingTitles={{questId=990012,title="任务 990012"}},tasks={{questId=990011,title="已识别任务",materialStatus="ready",materials={{name="研磨谷物"}}}}}
    local before=#mockAuction.searchCalls
    local diag=provider.fn()
    assert(diag.patch=="daily-auction-title-recovery-1" and diag.pendingTitleCount==1)
    assert(diag.tasks[1].questId==990011 and diag.taskCount==1)
    local report=assert(hub:BuildReport("tools_auction"))
    assert(report:find("provider.daily_materials=",1,true) and report:find("daily-auction-title-recovery-1",1,true), "module report omitted actual daily proof")
    assert(daily.consumerCount==0 and #mockAuction.searchCalls==before, "diagnostic acquired/queried")
    S.Services.DailyAuctionMaterialsV3=old
end)

print(string.format("\nAuction Favorites & Query Test Results: %d/%d passed", passed, total))
if passed == total then
    print("ALL TESTS PASSED!")
else
    print("SOME TESTS FAILED!")
    os.exit(1)
end

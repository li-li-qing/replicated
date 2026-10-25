-- Replicated Suite · 交易报价单位价格测试
-- 作者：Replicated
-- QQ群：1104129461
-- 交易报价挂牌价与单位价回归，仅运行纯逻辑宿主，不调用原生接口，不读写文件或存档。
unpack = unpack or table.unpack
ReplicatedSuite = {
    Services = {},
    Utils = {},
    Events = { Publish = function() return true end },
    NowMs = function() return 10000 end,
}
local S = ReplicatedSuite
local function Copy(v)
    if type(v) ~= "table" then return v end
    local o = {}; for k,x in pairs(v) do o[k] = Copy(x) end; return o
end
S.Utils.DeepCopy = Copy
S.Scheduler = { RemoveTask = function() return true end }
S.Api = {}
S.Persistence = nil

dofile("services/rs_price_quote_queue_v3.lua")
local Q = S.Services.PriceQuoteQueueV3
assert(Q.FallbackUnitPriceContractVersion == 1, "fallback unit-price contract missing")

local function Reset(rows, itemType, name)
    Q.pending = {
        requester = "test", itemType = itemType, itemGrade = 1, resolvedGrade = 1,
        requestedAt = 0, requestKey = tostring(itemType) .. ":1", fallbackState = "searching",
        searchName = name, watchers = { test = {} },
    }
    Q.queue = {}; Q.snapshots = {}; Q.pricesByItemType = {}; Q.quoteStateByItemType = {}
    S.Services.AuctionQueryV3 = { GetSnapshot = function()
        return { status = "ready", rows = rows, count = #rows }
    end }
end

-- 应选择最低单位直接购买价的挂牌，不能按首行或最低挂牌总价选择。
Reset({
    { itemType=3603, name="鸡蛋", quantity=1000, directPrice=62573, unitDirectPrice=63 },
    { itemType=3603, name="鸡蛋", quantity=100, directPrice=10000, unitDirectPrice=100 },
    { itemType=3603, name="鸡蛋", quantity=10000, directPrice=299286, unitDirectPrice=30 },
    { itemType=9999, name="别的物品", quantity=1, directPrice=1, unitDirectPrice=1 },
}, 3603, "鸡蛋")
Q:_CheckFallback()
local snap = Q:GetSnapshot("test")
assert(snap.status == "ready", "normalized fallback must complete")
assert(snap.price == 30, "expected 30 copper/unit, got " .. tostring(snap.price))
assert(snap.priceSource == "name_search_direct_unit", "wrong fallback source")
assert(Q.lastFallbackMatch and Q.lastFallbackMatch.matchIndex == 3, "must choose lowest matching unit listing")
assert(Q.lastFallbackMatch.quantity == 10000, "selected listing quantity missing")

-- 数量缺失时安全拒绝，不能把 62573 铜的挂牌总价当作每单位 62573 铜。
Reset({ { itemType=3603, name="鸡蛋", directPrice=62573 } }, 3603, "鸡蛋")
Q:_CheckFallback()
snap = Q:GetSnapshot("test")
assert(snap.status ~= "ready", "missing quantity must not produce a unit quote")
assert(snap.price == nil, "missing quantity must not fabricate price")
assert(tostring(snap.error or ""):find("堆叠数量") ~= nil, "failure must explain missing listing quantity")


-- AuctionQueryV3 必须提取 RU 原生 itemStack 字段，并将挂牌原始总价与归一化单位价分开。
S.Api.CallCapability = function(self, capability, api, method, ...)
    if method == "GetSearchedItemCount" then return true, 1, nil end
    if method == "GetSearchedItemInfo" then
        return true, { itemType=3603, itemGrade=1, name="鸡蛋", itemStack=1000, directPrice=62573 }, nil
    end
    return false, nil, "unexpected_method:" .. tostring(method)
end
S.Events.Unsubscribe = function() return true end
S.Scheduler.RemoveTask = function() return true end
dofile("services/rs_auction_query_v3.lua")
local AQ = S.Services.AuctionQueryV3
AQ.pending = { requester="auction_test", keyword="鸡蛋", exactMatch=false, requestedAt=0 }
assert(AQ:_OnSearched() == true, "auction query normalization failed")
local aqRow = AQ:GetSnapshot("auction_test").rows[1]
assert(aqRow.quantity == 1000, "itemStack must normalize to quantity")
assert(aqRow.directPrice == 62573, "listing total must remain raw")
assert(aqRow.unitDirectPrice == 63, "62573/1000 must normalize to 63 copper/unit")

-- 旧 18.312 曾把未归一化的 name_search_direct 总价保存为长期单位参考价；迁移仅清除这些污染来源，保留已归一化证据。
local fakeStore = { value = { entries = {
    ["3603:1"] = { price=62573, source="name_search_direct", updatedAt=1, samples={} },
    ["30902:1"] = { price=42, source="name_search_direct_unit", updatedAt=2, samples={} },
} } }
S.Persistence = {
    Scope={Account="account"}, Lifetime={Permanent="permanent"}, V3KeyPrefix="",
    RegisterV3Store=function(self,spec) return fakeStore, nil end,
    GetStore=function(self,id) return fakeStore end,
    LoadStore=function(self,id) return true, fakeStore.value, nil end,
    MarkDirty=function() return true end,
}
Q.storeLoaded = false
Q.referencePrices = {}
local storeOk, storeErr = Q:EnsureStoreLoaded(); assert(storeOk == true, "reference store load failed:" .. tostring(storeErr))
assert(Q:GetReferencePrice(3603,1) == nil, "legacy listing-total fallback reference must be discarded")
local kept = Q:GetReferencePrice(30902,1)
assert(kept == 42, "normalized unit reference must be retained")

print("TRADE_QUOTE_UNIT_PRICE: PASS")

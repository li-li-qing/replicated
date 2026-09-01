------------------------------------------------------------------------
-- Replicated Suite - Auction Query V3
--
-- Shared explicit-search Authority for the un-tokened AUCTION_ITEM_SEARCHED
-- completion edge. Feature modules never subscribe to that Native event
-- directly; one bounded service serializes user searches and publishes detached
-- snapshots through the internal EventBus.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Services = S.Services or {}
local Q = {
    version = 2,
    EventAuthorityContractVersion = 1,
    presentationBoundary = "service_only",
    presentationDebt = nil,
    Topic = "v3.auction_query.updated",
    pending = nil,
    snapshots = {},
    eventBound = false,
    owner = {},
    timeoutTask = "v3_auction_query_timeout",
    timeoutMs = 8000,
    maxRows = 30,
}
S.Services.AuctionQueryV3 = Q

local AuctionApi = rawget(_G, "X2Auction")
local function Trim(value) return (tostring(value or ""):match("^%s*(.-)%s*$")) or "" end
local function Copy(value)
    if S.Utils ~= nil and type(S.Utils.DeepCopy) == "function" then return S.Utils.DeepCopy(value) end
    if type(value) ~= "table" then return value end
    local out = {}; for key, child in pairs(value) do out[key] = Copy(child) end; return out
end
local function PositiveInt(value)
    local n = tonumber(value); if n == nil or n ~= math.floor(n) or n < 1 then return nil end
    return math.floor(n)
end
local function FirstText(info, keys)
    if type(info) ~= "table" then return nil end
    for _, key in ipairs(keys) do
        local value = info[key]
        if type(value) == "string" and value ~= "" then return value end
        if type(value) == "number" then return tostring(value) end
    end
    return nil
end
local function Nested(info, fn)
    if type(info) ~= "table" then return nil end
    local direct = fn(info); if direct ~= nil then return direct end
    for _, key in ipairs({ "itemInfo", "item", "tooltip", "info" }) do
        local child = info[key]
        if type(child) == "table" then local value = fn(child); if value ~= nil then return value end end
    end
    return nil
end
local function ItemType(info)
    return Nested(info, function(row)
        local value = tonumber(row.itemType or row.itemTypeId or row.item_type)
        return value ~= nil and math.floor(value) or nil
    end)
end
local function ItemName(info)
    return Nested(info, function(row) return FirstText(row, { "name", "itemName", "displayName", "item_name" }) end)
end
local function Amount(info)
    return Nested(info, function(row)
        local value = tonumber(row.stackCount or row.count or row.amount or row.itemCount)
        return value ~= nil and math.max(1, math.floor(value)) or nil
    end)
end
local function Price(info, keys)
    if type(info) ~= "table" then return nil end
    for _, key in ipairs(keys) do
        local raw = info[key]
        local n = tonumber(raw)
        if n ~= nil and n >= 0 then return math.floor(n) end
        if type(raw) == "string" and raw ~= "" then return raw end
    end
    return nil
end
local function NormalizeRow(info, index)
    if type(info) ~= "table" then return nil end
    local itemType = ItemType(info)
    local name = ItemName(info)
    local count = Amount(info)
    local direct = Price(info, { "directPriceStr", "directPrice", "buyoutPriceStr", "buyoutPrice" })
    local bid = Price(info, { "bidPriceStr", "bidPrice", "currentBidPriceStr", "currentBidPrice" })
    local seller = FirstText(info, { "sellerName", "seller", "ownerName", "characterName" })
    if name == nil and itemType ~= nil and S.Localization ~= nil and type(S.Localization.GetName) == "function" then
        name = S.Localization:GetName("item", itemType, nil)
    end
    name = name or (itemType ~= nil and ("物品 " .. tostring(itemType)) or ("拍卖结果 " .. tostring(index)))
    local parts = {}
    if count ~= nil then parts[#parts + 1] = "数量 " .. tostring(count) end
    if direct ~= nil then parts[#parts + 1] = "一口价 " .. tostring(direct) end
    if bid ~= nil then parts[#parts + 1] = "竞拍价 " .. tostring(bid) end
    if seller ~= nil then parts[#parts + 1] = "卖家 " .. tostring(seller) end
    if #parts == 0 then parts[1] = "当前 RU 返回字段有限；保留该条结果" end
    return {
        key = "auction:" .. tostring(index), resultIndex = index, itemType = itemType,
        name = tostring(name), text = table.concat(parts, " · "), statusText = "搜索结果", tone = "default",
        quantity = count, directPrice = direct, bidPrice = bid, seller = seller,
    }
end

function Q:GetSnapshot(requester)
    requester = tostring(requester or "")
    return Copy(self.snapshots[requester] or { requester = requester, status = "idle", rows = {}, count = 0 })
end

function Q:_Publish(requester)
    if S.Events ~= nil and type(S.Events.Publish) == "function" then
        S.Events:Publish(self.Topic, tostring(requester or ""))
    end
end

function Q:_CleanupNativeEdge()
    if S.Scheduler ~= nil then S.Scheduler:RemoveTask(self.timeoutTask) end
    if self.eventBound == true and S.Events ~= nil then S.Events:Unsubscribe("AUCTION_ITEM_SEARCHED", self.owner) end
    self.eventBound = false
end

function Q:_Complete(status, rows, err)
    local pending = self.pending
    if type(pending) ~= "table" then return false end
    local requester = pending.requester
    self:_CleanupNativeEdge()
    self.pending = nil
    self.snapshots[requester] = {
        requester = requester, keyword = pending.keyword, exactMatch = pending.exactMatch == true,
        status = tostring(status or "failed"), rows = type(rows) == "table" and rows or {},
        count = type(rows) == "table" and #rows or 0, error = err,
        requestedAt = pending.requestedAt, completedAt = type(S.NowMs) == "function" and S.NowMs() or nil,
        contract = "9参数显式搜索；结果字段按当前 RU 返回做 bounded normalization，不作为历史成交样本",
    }
    self:_Publish(requester)
    return true
end

function Q:_OnSearched()
    local pending = self.pending
    if type(pending) ~= "table" then return false end
    local okCount, countValue, countErr = S.Api:CallCapability("X2Auction:GetSearchedItemCount", AuctionApi, "GetSearchedItemCount")
    if okCount ~= true then return self:_Complete("failed", {}, "结果数量读取失败：" .. tostring(countErr or "unknown")) end
    local sourceCount = math.max(0, math.floor(tonumber(countValue) or 0))
    if sourceCount == 0 then return self:_Complete("empty", {}, nil) end
    local limit = math.min(sourceCount, math.max(1, math.min(self.maxRows, tonumber(pending.resultLimit) or 20)))
    local rows, failures = {}, 0
    for index = 1, limit do
        local okInfo, info = S.Api:CallCapability("X2Auction:GetSearchedItemInfo", AuctionApi, "GetSearchedItemInfo", index)
        if okInfo == true and type(info) == "table" then
            local row = NormalizeRow(info, index); if row ~= nil then rows[#rows + 1] = row else failures = failures + 1 end
        else failures = failures + 1 end
    end
    local status = failures > 0 and (#rows > 0 and "partial" or "failed") or "ready"
    local err = failures > 0 and ("有 " .. tostring(failures) .. " 条结果字段不可读") or nil
    return self:_Complete(status, rows, err)
end

function Q:Search(requester, keyword, options)
    requester, keyword = tostring(requester or ""), Trim(keyword)
    options = type(options) == "table" and options or {}
    if requester == "" then return false, "查询来源不能为空" end
    if keyword == "" or #keyword > 64 or keyword:find("[%c]") ~= nil then return false, "搜索关键词必须是 1-64 个可见字符" end
    if self.pending ~= nil then return false, "上一个拍卖搜索仍在等待服务器返回，请稍后再试" end
    if S.Events == nil or type(S.Events.SubscribeOptional) ~= "function" then return false, "拍卖完成事件总线不可用" end
    S.Events:BindOwner(self.owner, "AuctionQueryV3")
    local subscribed = S.Events:SubscribeOptional("AUCTION_ITEM_SEARCHED", self.owner, function() return Q:_OnSearched() end)
    if subscribed ~= true then return false, "AUCTION_ITEM_SEARCHED 当前不可订阅" end
    self.eventBound = true
    self.pending = {
        requester = requester, keyword = keyword, exactMatch = options.exactMatch == true,
        resultLimit = math.max(1, math.min(self.maxRows, tonumber(options.resultLimit) or 20)),
        requestedAt = type(S.NowMs) == "function" and S.NowMs() or 0,
    }
    self.snapshots[requester] = { requester = requester, keyword = keyword, exactMatch = options.exactMatch == true, status = "waiting", rows = {}, count = 0 }
    self:_Publish(requester)
    local ok, value, err = S.Api:CallCapability("X2Auction:SearchAuctionArticle", AuctionApi, "SearchAuctionArticle",
        1, 0, 55, 1, 0, options.exactMatch == true, keyword, "0", "0")
    if ok ~= true or value == false then
        local reason = tostring(err or "搜索请求被拒绝")
        self:_Complete("failed", {}, reason)
        return false, reason
    end
    if S.Scheduler == nil or type(S.Scheduler.AddOneShot) ~= "function" then
        self:_Complete("failed", {}, "拍卖查询超时保护不可用，已安全停止等待")
        return false, "拍卖查询超时保护不可用"
    end
    S.Scheduler:RemoveTask(self.timeoutTask)
    local added = S.Scheduler:AddOneShot(self.timeoutTask, self.timeoutMs, function()
        if Q.pending ~= nil then Q:_Complete("failed", {}, "等待拍卖服务器返回超时") end
    end, self.owner, "P2", 1)
    if added ~= true then
        self:_Complete("failed", {}, "拍卖查询超时保护任务创建失败，已安全停止等待")
        return false, "拍卖查询超时保护任务创建失败"
    end
    if type(S.Scheduler.SetTaskModule) == "function" then S.Scheduler:SetTaskModule(self.timeoutTask, "AuctionQueryV3", true) end
    return true, "waiting"
end

function Q:Describe()
    return { version = self.version, pending = self.pending ~= nil, eventBound = self.eventBound == true, maxRows = self.maxRows, timeoutMs = self.timeoutMs }
end

------------------------------------------------------------------------
-- Replicated Suite - Auction Query V3
--
-- Shared explicit-search Authority for the un-tokened AUCTION_ITEM_SEARCHED
-- completion edge. Feature modules never subscribe to that Native event
-- directly; one bounded service serializes user searches and publishes detached
-- snapshots through the internal EventBus.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
-- 维护（2026-09-30，trade-quote-price-safety-1）：共享服务早于按需 ImportAPI 加载。
-- 不捕获早期/重载占位的 X2Auction 表；每次由 Api capability boundary 解析当前 Native host。
-- 这不启用拍卖助手，只让 Trade 所有的惰性导入在 Search/回包读取时真正生效。
local S = ReplicatedSuite
S.Services = S.Services or {}
local Q = {
    version = 3,
    EventAuthorityContractVersion = 1,
    NativeUserPriorityContractVersion = 1,
    priorityPatch = "auction-user-priority-1",
    surfaceTopic = "v3.auction_surface.updated",
    interruptions = 0, discardedCompletions = 0,
    -- 中文维护注释（2026-09-25，auction-listing-unit-price-1）：GetSearchedItemInfo 的 direct/bid 是整条
    -- 拍卖记录价格，而不是材料单价。数量是价格归一 Authority 的必要组成；下游不得再把 listing total
    -- 当作 unit cost。该契约同时要求兼容 RU 常见 itemStack 字段，避免数量丢失后错误放大材料成本。
    ListingUnitPriceContractVersion = 1,
    SampledUnitPriceContractVersion = 1,
    sortPatch = "auction-three-sample-1",
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
    priceEvidence = {},
}
S.Services.AuctionQueryV3 = Q

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
local function Nested(info, fn)
    if type(info) ~= "table" then return nil end
    local direct = fn(info); if direct ~= nil then return direct end
    for _, key in ipairs({ "itemInfo", "item", "tooltip", "info" }) do
        local child = info[key]
        if type(child) == "table" then local value = fn(child); if value ~= nil then return value end end
    end
    return nil
end
local function FirstText(info, keys)
    return Nested(info, function(row)
        for _, key in ipairs(keys) do
            local value = row[key]
            if type(value) == "string" and value ~= "" then return value end
            if type(value) == "number" then return tostring(value) end
        end
        return nil
    end)
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
        -- 中文维护注释（2026-09-25，auction-listing-unit-price-1）：官方 Auction API 的分割购买接口
        -- 使用 itemStack 命名，RU 搜索结果也可能沿用该字段。旧实现漏掉 itemStack 后 quantity=nil，
        -- PriceQuote fallback 只能看到整单 directPrice，最终会把几百/几千件的总价误当成 1 件单价。
        -- 这里只做 bounded 字段归一，不调用 Native；数量至少为 1，保持 AuctionQuery 为字段 Authority。
        local value = tonumber(row.itemStack or row.stackCount or row.stack or row.count or row.amount
            or row.itemCount or row.quantity or row.stackSize)
        -- 维护（2026-09-30，trade-quote-price-safety-1）：零/负数/小数/无穷不是“1件”。
        -- 禁止把不可读数量钳成1后用整单总价当单价，保留 nil 让报价按无可靠数量失败。
        if value == nil or value ~= value or value == math.huge or value < 1 or value ~= math.floor(value) then return nil end
        return value
    end)
end
local function Money(value, depth)
    depth = tonumber(depth) or 0
    if depth > 4 then return nil end -- 无效递归包装不得拖垮共享 AUCTION_ITEM_SEARCHED 回调。
    -- 维护（2026-09-24，auction-money-normalize-1）：RU 的拍卖价格字段并不保证始终是裸 number；
    -- 历史客户端会出现逗号分组字符串或 gold/silver/copper 复合表。AuctionQueryV3 是搜索结果字段
    -- normalization Authority，应在这里一次归一为铜币 number，不能让各 Feature 各猜一次返回形状。
    if type(value) == "number" then return value >= 0 and math.floor(value) or nil end
    if type(value) == "string" then
        local n = tonumber((value:gsub(",", ""):gsub("%s", "")))
        return n ~= nil and n >= 0 and math.floor(n) or nil
    end
    if type(value) == "table" then
        local gold, silver, copper = tonumber(value.gold or value.g), tonumber(value.silver or value.s), tonumber(value.copper or value.c)
        if gold ~= nil or silver ~= nil or copper ~= nil then
            local n = (gold or 0) * 10000 + (silver or 0) * 100 + (copper or 0)
            return n >= 0 and math.floor(n) or nil
        end
        for _, key in ipairs({ "value", "amount", "price", "money" }) do
            local n = Money(value[key], depth + 1); if n ~= nil then return n end
        end
    end
    return nil
end
local function Price(info, keys)
    return Nested(info, function(row)
        for _, key in ipairs(keys) do
            local n = Money(row[key])
            if n ~= nil then return n end
        end
        return nil
    end)
end
local function ItemGrade(info)
    return Nested(info, function(row)
        local value = tonumber(row.itemGrade or row.grade or row.item_grade or row.item_grade_id)
        return value ~= nil and math.floor(value) or nil
    end)
end

local function UnitPrice(totalPrice, quantity)
    local total = tonumber(totalPrice)
    local count = tonumber(quantity)
    if total == nil or total ~= total or total == math.huge or total <= 0
        or count == nil or count ~= count or count == math.huge or count < 1 or count ~= math.floor(count) then return nil end
    -- Cost projection is copper-integer based. Ceil is deliberately conservative: a fractional average copper
    -- must never understate the material cost, and the rounding error is bounded to <1 copper per unit.
    return math.max(1, math.ceil(total / count))
end
local function NormalizeRow(info, index)
    if type(info) ~= "table" then return nil end
    local itemType = ItemType(info)
    local itemGrade = ItemGrade(info) -- 中文维护注释：提取拍卖行搜索结果的物品品级，支持后续针对具体品级走 PriceQuoteQueueV3 显式询价
    local name = ItemName(info)
    local count = Amount(info)
    local direct = Price(info, { "directPriceStr", "directPrice", "buyoutPriceStr", "buyoutPrice" })
    local bid = Price(info, { "bidPriceStr", "bidPrice", "currentBidPriceStr", "currentBidPrice" })
    local directUnit = UnitPrice(direct, count)
    local bidUnit = UnitPrice(bid, count)
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
        key = "auction:" .. tostring(index), resultIndex = index, itemType = itemType, itemGrade = itemGrade,
        name = tostring(name), text = table.concat(parts, " · "), statusText = "搜索结果", tone = "default",
        -- directPrice/bidPrice remain raw LISTING totals for the auction UI. unit* fields are the only
        -- material-cost-safe values and are derived from the same detached row + normalized quantity.
        quantity = count, directPrice = direct, bidPrice = bid,
        unitDirectPrice = directUnit, unitBidPrice = bidUnit, seller = seller,
    }
end

-- 维护（2026-10-02）：严格报价释放快照后仍保留有界字段证据。仅在既有回包读取处采集，
-- 不补读 Native、不保存卖家/整张 Native 表。独立诊断 provider 避免报价大快照耗尽节点预算。
local function EvidenceTime() return type(S.NowMs) == "function" and S.NowMs() or 0 end
local function EvidenceClip(text, limit)
    if #text <= limit then return text end
    local last = limit
    while last > 0 and text:byte(last) >= 128 and text:byte(last) < 192 do last = last - 1 end
    if last > 0 and text:byte(last) >= 192 then last = last - 1 end
    return text:sub(1, last)
end
local function EvidenceScalar(value, depth)
    local kind = type(value)
    if kind == "number" or kind == "boolean" or kind == "nil" then return kind .. ":" .. tostring(value) end
    if kind == "string" then return "string:" .. EvidenceClip(value:gsub("[%c]", " "), 48) end
    if kind ~= "table" or (depth or 0) >= 2 then return kind end
    local parts = {}
    for _, key in ipairs({ "gold", "g", "silver", "s", "copper", "c", "value", "amount", "price", "money" }) do
        if value[key] ~= nil then parts[#parts + 1] = key .. "=" .. EvidenceScalar(value[key], (depth or 0) + 1) end
    end
    return "table{" .. table.concat(parts, ",") .. "}"
end
local function EvidenceFields(info)
    if type(info) ~= "table" then return "shape=" .. type(info) end
    local parts = {}
    local function Shape(row, path)
        local keys, visited = {}, 0
        for key in pairs(row) do
            visited = visited + 1
            if type(key) == "string" then keys[#keys + 1] = EvidenceClip(key:gsub("[%c]", " "), 32) end
            if #keys >= 16 or visited >= 32 then break end
        end
        table.sort(keys)
        -- 显式白名单只记录身份/数量/价格字段；未知字段仅保留字段名供后续核验。
        for _, key in ipairs({ "itemType", "itemTypeId", "item_type", "itemGrade", "grade", "item_grade", "item_grade_id",
            "itemStack", "stackCount", "stack", "count", "amount", "itemCount", "quantity", "stackSize",
            "directPriceStr", "directPrice", "buyoutPriceStr", "buyoutPrice", "bidPriceStr", "bidPrice", "currentBidPriceStr", "currentBidPrice" }) do
            if row[key] ~= nil then parts[#parts + 1] = path .. "." .. key .. "=" .. EvidenceScalar(row[key]) end
        end
        parts[#parts + 1] = path .. ".keys=" .. table.concat(keys, ",")
    end
    Shape(info, "root")
    for _, key in ipairs({ "itemInfo", "item", "tooltip", "info" }) do
        if type(info[key]) == "table" then Shape(info[key], key) end
    end
    -- 8 请求 × 3 样本仍须落在 Hub 每个 provider 的 16 KiB 预算内。
    return EvidenceClip(table.concat(parts, " "), 450)
end
-- 维护（2026-10-02，auction-search-packet-evidence-1）：210656 报告只有 getter 的 0，旧订阅丢掉了
-- 完成事件的所有参数，无法排除事件携带数据而 Native 缓存为空。这里只保全事实，不把未知表 schema
-- 当报价 ABI；保留参数类型及中间 nil，剥离 owner，并有界脱离 Native 表/循环/个人名称字段。
local function EvidencePacket(...)
    local packet = { argCount = select("#", ...), types = {}, values = {} }
    for index = 1, math.min(packet.argCount, 8) do
        local value = select(index, ...)
        packet.types[index], packet.values[index] = type(value), value
    end
    packet.omittedArguments = math.max(0, packet.argCount - 8)
    if type(S.DiagnosticDetail) == "table" and type(S.DiagnosticDetail.Detach) == "function" then
        return S.DiagnosticDetail:Detach(packet, { nodes=512, depth=6, keys=64, stringBytes=1024,
            excludeKeys={sellerName=true,seller=true,ownerName=true,characterName=true} })
    end
    -- Detail 未加载时不能退回无界 DeepCopy；标出采样缺口，标量仍保留，复杂返回等待下次完整加载。
    packet.captureUnavailable = true
    for index, value in pairs(packet.values) do
        if type(value) == "table" then packet.values[index] = "<not_captured diagnostic_detail_unavailable>"
        elseif type(value) == "string" then packet.values[index] = EvidenceClip(value, 1024)
        elseif type(value) ~= "number" and type(value) ~= "boolean" then packet.values[index] = "<not_captured type=" .. type(value) .. ">" end
    end
    return packet
end
local function EvidenceRead(pending, index, reason, info, row)
    local evidence = pending.evidence
    if evidence == nil then return end
    evidence.readCount = evidence.readCount + 1
    if type(S.DiagnosticDetail) == 'table' then
        evidence.listingDetails = evidence.listingDetails or {}
        -- 只记录已经读到的最多30条；报价完整比较仍受原有 resultLimit 约束。
        evidence.listingDetails[#evidence.listingDetails + 1] = {
            index=index, reason=reason, normalized=type(row)=='table' and {
                itemType=row.itemType, itemGrade=row.itemGrade, quantity=row.quantity,
                directPrice=row.directPrice, unitDirectPrice=row.unitDirectPrice, bidPrice=row.bidPrice } or nil,
            raw=S.DiagnosticDetail:Detach(info,{nodes=128,depth=4,keys=64,stringBytes=512,
                excludeKeys={sellerName=true,seller=true,ownerName=true,characterName=true}}) }
    end
    if reason == "candidate" then evidence.candidateCount = (tonumber(evidence.candidateCount) or 0) + 1
    elseif reason == "accepted" then evidence.acceptedIndex = index
    else evidence.reasons[reason] = (evidence.reasons[reason] or 0) + 1 end
    if #evidence.samples < 3 then
        local normalized = type(row) == "table" and (" normalized{id=" .. tostring(row.itemType)
            .. " grade=" .. tostring(row.itemGrade) .. " qty=" .. tostring(row.quantity)
            .. " total=" .. tostring(row.directPrice) .. " unit=" .. tostring(row.unitDirectPrice) .. "}") or ""
        evidence.samples[#evidence.samples + 1] = EvidenceClip("index=" .. tostring(index) .. " reason=" .. reason
            .. normalized .. " " .. EvidenceFields(info), 512)
    end
end
function Q:DescribePriceEvidence(itemTypes)
    local rows = {}
    for index = #self.priceEvidence, 1, -1 do
        local evidence = self.priceEvidence[index]
        if itemTypes == nil or itemTypes[evidence.itemType] == true then
            -- 原始回包/返回值只进 TXT 明细；摘要保留参数数，避免大表挤掉其余诊断 provider。
            local row = {}; for key, value in pairs(evidence) do
                if key ~= 'listingDetails' and key ~= 'eventPacket' and key ~= 'searchReturn'
                    and key ~= 'searchArguments' then row[key] = Copy(value) end
            end
            local reasons = {}; for reason, count in pairs(row.reasons) do reasons[#reasons + 1] = reason .. "=" .. tostring(count) end
            table.sort(reasons); row.rejections = table.concat(reasons, ","); row.reasons = nil
            rows[#rows + 1] = row
            if #rows >= 8 then break end
        end
    end
    return { patch = "auction-price-evidence-1", sortPatch = self.sortPatch, retained = #self.priceEvidence, requests = rows,
        sampleLimit = 3, sampleBytes = 512, requestLimit = 8, ringLimit = 16 }
end

function Q:DescribePriceEvidenceDetail()
    return { patch='auction-search-packet-evidence-1', requests=Copy(self.priceEvidence), ringLimit=16,
        coverage='strict_quote_reads_at_most_three_current_page_rows; not_a_global_market_minimum',
        rawLimits={nodesPerRow=128,depth=4,keys=64,stringBytes=512},
        -- 回包取证不追加搜索或 getter；超限由 Detach 明确写出 OMITTED，而不是声称完整无遗漏。
        packetLimits={arguments=8,nodes=512,depth=6,keys=64,stringBytes=1024},
        pending=self.pending~=nil, maxRowsPerRequest=self.maxRows }
end

-- 中文维护：任务概览保留所有请求及拒绝原因/归一化身份；raw/事件大表由独立 TXT 来源输出。
-- 直接只读 retained ring，既不追加 Native getter，也不复制 raw 再删除造成无谓大快照。
function Q:DescribePriceEvidenceOverview()
    local requests={}
    for _, evidence in ipairs(self.priceEvidence) do
        local row={}
        for key,value in pairs(evidence) do
            if key~='listingDetails' and key~='eventPacket' and key~='searchReturn' then row[key]=Copy(value) end
        end
        row.listingDetails={}
        for _,listing in ipairs(evidence.listingDetails or {}) do
            row.listingDetails[#row.listingDetails+1]={index=listing.index,reason=listing.reason,normalized=Copy(listing.normalized)}
        end
        requests[#requests+1]=row
    end
    return {requests=requests,ringLimit=16,pending=self.pending~=nil,
        coverage='all_retained_request_outcomes; raw_packets_in_separate_deferred_txt_source'}
end

function Q:GetSnapshot(requester)
    requester = tostring(requester or "")
    return Copy(self.snapshots[requester] or { requester = requester, status = "idle", rows = {}, count = 0 })
end

-- 一次性严格消费者可释放已读快照；取消在途时只标记待释放，不缩短原生隔离期。
function Q:ReleaseSnapshot(requester, searchGeneration)
    local pending = self.pending
    if pending and pending.requester == requester and pending.searchGeneration == searchGeneration then pending.releaseSnapshot = true end
    local snapshot = self.snapshots[requester]
    if snapshot and snapshot.searchGeneration == searchGeneration then self.snapshots[requester] = nil; return true end
    return false
end

function Q:_Publish(requester)
    if S.Events ~= nil and type(S.Events.Publish) == "function" then
        S.Events:Publish(self.Topic, tostring(requester or ""))
    end
end

-- 维护（2026-09-30，auction-user-priority-1）：toc.g 中 Surface 晚于 Query，必须调用时
-- 解析依赖。不能读取旧 snapshot，也不能把 Trade 的 priority=user 当成原生搜索授权。
-- 该方法仅在请求/回包/活动询价调度中读取 Native；Describe 仍是无副作用快照。
function Q:CanBackgroundSearch()
    local surface = S.Services and S.Services.AuctionSurfaceV3 or nil
    local ok, known, visible, source, probe = false, false, false, "surface_unavailable", nil
    if type(surface) == "table" and type(surface.ReadVisibility) == "function" then
        ok, known, visible, source, probe = pcall(surface.ReadVisibility, surface)
    end
    self.lastVisibility = { known = ok == true and known == true, visible = ok == true and visible == true,
        source = ok == true and tostring(source or "unknown") or "visibility_read_failed",
        probe = type(probe) == "table" and Copy(probe) or nil }
    if ok ~= true or known ~= true then return false, "native_auction_visibility_unknown" end
    if visible == true then return false, "native_auction_visible" end
    if self.pending ~= nil then
        if self.pending.discarded == true then return false, "auction_response_drain" end
        if self.pending.background ~= true then return false, "auction_user_search_pending" end
    end
    return true
end

-- 已发出的 Native 查询没有取消/请求令牌 ABI。失去归属后保留原 timeout 占位；期间所有完成边
-- 都丢弃，不读结果、不缩短隔离期，避免把玩家自己的搜索回包当成“旧请求已排空”。
function Q:YieldBackgroundSearch(reason, requester, searchGeneration)
    local pending = self.pending
    if type(pending) ~= "table" or pending.background ~= true then return false end
    if requester ~= nil and (pending.requester ~= requester or pending.searchGeneration ~= searchGeneration) then return false end
    if pending.discarded == true then return true end
    pending.discarded = true
    pending.discardReason = tostring(reason or "native_auction_visible")
    if pending.evidence ~= nil then
        pending.evidence.status, pending.evidence.error = "interrupted", pending.discardReason
        pending.evidence.completedAt = EvidenceTime()
    end
    self.interruptions = (tonumber(self.interruptions) or 0) + 1
    self.snapshots[pending.requester] = { requester = pending.requester, keyword = pending.keyword,
        status = "interrupted", rows = {}, count = 0, error = pending.discardReason,
        requestedAt = pending.requestedAt, drainUntil = pending.expiresAt, searchGeneration = pending.searchGeneration }
    self:_Publish(pending.requester)
    return true
end

function Q:_CleanupNativeEdge()
    if S.Scheduler ~= nil then S.Scheduler:RemoveTask(self.timeoutTask) end
    if self.eventBound == true and S.Events ~= nil then S.Events:Unsubscribe("AUCTION_ITEM_SEARCHED", self.owner) end
    self.eventBound = false
    if self.surfaceBound == true and S.Events ~= nil and type(S.Events.UnsubscribeInternal) == "function" then
        S.Events:UnsubscribeInternal(self.surfaceTopic, self.owner)
    end
    self.surfaceBound = false
end

function Q:_Complete(status, rows, err)
    local pending = self.pending
    if type(pending) ~= "table" then return false end
    local requester = pending.requester
    if pending.discarded == true then status, rows, err = "interrupted", {}, pending.discardReason end
    local errorCode
    if pending.evidence ~= nil then
        pending.evidence.status, pending.evidence.error = status, err
        pending.evidence.errorCode = errorCode
        pending.evidence.completedAt = EvidenceTime()
    end
    self:_CleanupNativeEdge()
    self.pending = nil
    self.snapshots[requester] = {
        requester = requester, keyword = pending.keyword, exactMatch = pending.exactMatch == true,
        searchGeneration = pending.searchGeneration,
        status = tostring(status or "failed"), rows = type(rows) == "table" and rows or {},
        count = type(rows) == "table" and #rows or 0, error = err, errorCode = errorCode,
        requestedAt = pending.requestedAt, completedAt = type(S.NowMs) == "function" and S.NowMs() or nil,
        listingSelection = pending.listingSelection, coverageComplete = pending.coverageComplete,
        sampleLowerLater = pending.sampleLowerLater == true,
        contract = "9参数显式搜索；结果字段按当前 RU 返回做 bounded normalization，不作为历史成交样本",
    }
    self:_Publish(requester)
    if pending.releaseSnapshot == true then self:ReleaseSnapshot(requester, pending.searchGeneration) end
    return true
end

function Q:_OnSearched(expected, ...)
    local pending = self.pending
    if type(pending) ~= "table" or (expected ~= nil and expected ~= pending) then return false end
    if pending.evidence ~= nil then pending.evidence.callbackAt = EvidenceTime() end
    if pending.background == true then
        local allowed, reason = self:CanBackgroundSearch()
        if allowed ~= true then self:YieldBackgroundSearch(reason) end
        if pending.discarded == true then
            self.discardedCompletions = (tonumber(self.discardedCompletions) or 0) + 1
            return true
        end
    end
    -- 通过当前请求/可见性归属验证后才复制事件正文；被让出的玩家手动搜索回包仍只丢弃。
    if pending.evidence ~= nil then
        pending.evidence.eventArgCount = select("#", ...)
        pending.evidence.eventPacket = EvidencePacket(...)
    end
    local okCount, countValue, countErr = S.Api:CallCapability("X2Auction:GetSearchedItemCount", nil, "GetSearchedItemCount")
    if pending.evidence ~= nil then
        pending.evidence.countCallOk, pending.evidence.countError = okCount == true, countErr
        pending.evidence.countReturn = EvidenceClip(EvidenceScalar(countValue), 96)
    end
    if okCount ~= true then return self:_Complete("failed", {}, "结果数量读取失败：" .. tostring(countErr or "unknown")) end
    -- Getter 未知/损坏不得经 tonumber(... ) or 0 伪装为“市场无挂单”；合法整数字符串保持兼容。
    local sourceCount = tonumber(countValue)
    if sourceCount == nil or sourceCount ~= sourceCount or sourceCount == math.huge
        or sourceCount < 0 or sourceCount ~= math.floor(sourceCount) then
        return self:_Complete("failed", {}, "auction_search_count_invalid")
    end
    if pending.evidence ~= nil then
        pending.evidence.sourceCount = sourceCount
        pending.evidence.unreadRows = sourceCount
    end
    local limit = math.min(sourceCount, math.max(1, math.min(self.maxRows, tonumber(pending.resultLimit) or 20)))
    if pending.firstValidBuyout ~= nil then
        -- 三条样本只提供参考单价。无论拍卖行当前是升序还是降序，最多读取本页前三条，
        -- 以同身份、同品质的有效一口单价中较低者展示；不声称这是全市场最低价。
        limit = math.min(limit, 3)
        pending.coverageComplete = limit == sourceCount
        pending.listingSelection = "sampled_unit_buyout"
        if pending.evidence then
            pending.evidence.selection = pending.listingSelection
            pending.evidence.coverageComplete = pending.coverageComplete
            pending.evidence.sampleLimit = 3
        end
    end
    if sourceCount == 0 then return self:_Complete("empty", {}, nil) end
    local rows, failures, bestBuyout = {}, 0, nil
    for index = 1, limit do
        local okInfo, info = S.Api:CallCapability("X2Auction:GetSearchedItemInfo", nil, "GetSearchedItemInfo", index)
        if okInfo == true and type(info) == "table" then
            local row = NormalizeRow(info, index)
            if pending.firstValidBuyout ~= nil then
                -- firstValidBuyout 保留历史调用字段名，仅作为精确身份过滤条件。
                -- 比较至多三条已核验样本；相同单价保留先读到的第一条。
                local wanted = pending.firstValidBuyout
                local exactId = Nested(info, function(value) return tonumber(value.itemType or value.itemTypeId or value.item_type) end)
                local exactGrade = Nested(info, function(value) return tonumber(value.itemGrade or value.grade or value.item_grade or value.item_grade_id) end)
                if row ~= nil and exactId == wanted.itemType and exactGrade == wanted.itemGrade
                    and row.itemType == wanted.itemType and row.itemGrade == wanted.itemGrade
                    and row.unitDirectPrice ~= nil and row.unitDirectPrice > 0 then
                    EvidenceRead(pending, index, "candidate", info, row)
                    if pending.firstSampleUnitPrice == nil then pending.firstSampleUnitPrice = row.unitDirectPrice
                    elseif row.unitDirectPrice < pending.firstSampleUnitPrice then pending.sampleLowerLater = true end
                    if bestBuyout == nil or row.unitDirectPrice < bestBuyout.unitDirectPrice then bestBuyout = row end
                else
                    local reason = exactId == nil and "id_missing" or exactId ~= wanted.itemType and "id_mismatch"
                        or exactGrade == nil and "grade_missing" or exactGrade ~= wanted.itemGrade and "grade_mismatch"
                        or row == nil and "info_shape_invalid" or row.quantity == nil and "quantity_invalid" or "buyout_invalid"
                    EvidenceRead(pending, index, reason, info, row)
                    -- 未知字段不能变成价格；其它可读样本仍可提供明确标注的参考价。
                    failures = failures + 1
                end
            elseif row ~= nil then rows[#rows + 1] = row else failures = failures + 1 end
        else
            failures = failures + 1
            EvidenceRead(pending, index, okInfo ~= true and "info_call_failed" or "info_shape_invalid", info)
        end
    end
    if pending.firstValidBuyout ~= nil then
        if bestBuyout ~= nil then rows[1] = bestBuyout end
        if pending.evidence then
            pending.evidence.acceptedIndex = rows[1] and rows[1].resultIndex or nil
            pending.evidence.selectedUnitPrice = rows[1] and rows[1].unitDirectPrice or nil
            pending.evidence.sampleLowerLater = pending.sampleLowerLater == true
        end
    end
    local status = pending.firstValidBuyout ~= nil and (#rows > 0 and "ready" or "failed")
        or (failures > 0 and (#rows > 0 and "partial" or "failed") or "ready")
    if pending.evidence then pending.evidence.unreadRows = math.max(0, sourceCount-pending.evidence.readCount) end
    local err = failures > 0 and ("有 " .. tostring(failures) .. " 条结果字段不可读") or nil
    return self:_Complete(status, rows, err)
end

function Q:Search(requester, keyword, options)
    requester, keyword = tostring(requester or ""), Trim(keyword)
    options = type(options) == "table" and options or {}
    if requester == "" then return false, "查询来源不能为空" end
    if keyword == "" or #keyword > 64 or keyword:find("[%c]") ~= nil then return false, "搜索关键词必须是 1-64 个可见字符" end
    local firstValidBuyout
    if options.firstValidBuyout ~= nil then
        local wanted = options.firstValidBuyout
        local id = type(wanted) == "table" and PositiveInt(wanted.itemType) or nil
        local grade = type(wanted) == "table" and tonumber(wanted.itemGrade) or nil
        if id == nil or grade == nil or grade ~= math.floor(grade) or grade < 0 or grade > 20 then
            return false, "strict_search_identity_invalid"
        end
        firstValidBuyout = { itemType = id, itemGrade = grade }
    end
    local background = options.background == true or requester == "price_quote_fallback"
    if background then
        local allowed, reason = self:CanBackgroundSearch()
        if allowed ~= true then return false, reason end
    end
    if self.pending ~= nil then
        -- 只使旧报价失去结果归属，不强行并发新的无 token 查询。原生手动操作完全不经过此门。
        if not background then self:YieldBackgroundSearch("auction_user_search_pending") end
        return false, "上一个拍卖搜索仍在等待服务器返回，请稍后再试"
    end
    if S.Events == nil or type(S.Events.SubscribeOptional) ~= "function" then return false, "拍卖完成事件总线不可用" end
    if S.Scheduler == nil or type(S.Scheduler.AddOneShot) ~= "function" then return false, "拍卖查询超时保护不可用" end
    S.Events:BindOwner(self.owner, "AuctionQueryV3")
    local requestedAt = type(S.NowMs) == "function" and S.NowMs() or 0
    local pending = { requester = requester, keyword = keyword, exactMatch = options.exactMatch == true,
        background = background, requestedAt = requestedAt, expiresAt = requestedAt + self.timeoutMs,
        firstValidBuyout = firstValidBuyout, searchGeneration = options.searchGeneration,
        resultLimit = math.max(1, math.min(self.maxRows, tonumber(options.resultLimit) or 20)) }
    self.pending = pending
    if firstValidBuyout ~= nil then
        pending.evidence = { itemType = firstValidBuyout.itemType, itemGrade = firstValidBuyout.itemGrade,
            keyword = keyword, searchGeneration = pending.searchGeneration, requestedAt = requestedAt,
            status = "waiting", readCount = 0, samples = {}, reasons = {} }
        -- 完整记录真正发出的九参数，区分名称/等级/品质过滤与返回校验；不增加试探请求或改用户过滤。
        pending.evidence.searchArguments = { page=1,minLevel=0,maxLevel=0,grade=1,category=0,
            exactMatch=pending.exactMatch,keyword=keyword,minDirectPriceStr="0",maxDirectPriceStr="0" }
        self.priceEvidence[#self.priceEvidence + 1] = pending.evidence
        if #self.priceEvidence > 16 then table.remove(self.priceEvidence, 1) end
    end
    self.snapshots[requester] = { requester = requester, keyword = keyword, exactMatch = pending.exactMatch,
        status = "waiting", rows = {}, count = 0, searchGeneration = pending.searchGeneration }
    local subscribed = S.Events:SubscribeOptional("AUCTION_ITEM_SEARCHED", self.owner, function(_, ...)
        return Q:_OnSearched(pending, ...)
    end)
    if subscribed ~= true then
        self:_Complete("failed", {}, "AUCTION_ITEM_SEARCHED 当前不可订阅")
        return false, "AUCTION_ITEM_SEARCHED 当前不可订阅"
    end
    self.eventBound = true
    if background and type(S.Events.SubscribeInternal) == "function" then
        self.surfaceBound = S.Events:SubscribeInternal(self.surfaceTopic, self.owner, function(_, snapshot)
            if Q.pending == pending and type(snapshot) == "table" and snapshot.visible == true then
                Q:YieldBackgroundSearch("native_auction_visible")
            end
        end) == true
    end
    -- 维护：先建立 timeout 再发 Native；回调绑定本次请求，不能误结束下一次查询。
    -- Native 同步完成也会清除此任务，避免“完成后再注册”遗留计时器。
    S.Scheduler:RemoveTask(self.timeoutTask)
    local added = S.Scheduler:AddOneShot(self.timeoutTask, self.timeoutMs, function()
        if Q.pending ~= pending then return end
        if pending.background == true then
            local allowed, reason = Q:CanBackgroundSearch()
            if allowed ~= true then Q:YieldBackgroundSearch(reason) end
        end
        Q:_Complete("failed", {}, "等待拍卖服务器返回超时")
    end, self.owner, "P2", 1)
    if added ~= true then
        self:_Complete("failed", {}, "拍卖查询超时保护任务创建失败，已安全停止等待")
        return false, "拍卖查询超时保护任务创建失败"
    end
    if type(S.Scheduler.SetTaskModule) == "function" then S.Scheduler:SetTaskModule(self.timeoutTask, "AuctionQueryV3", true) end
    self:_Publish(requester)
    if background then
        local allowed, reason = self:CanBackgroundSearch()
        if allowed ~= true or pending.discarded == true then
            reason = pending.discardReason or reason
            self:YieldBackgroundSearch(reason)
            self:_Complete("interrupted", {}, reason) -- 尚未发包，无需保留 Native 占位。
            return false, reason
        end
    end
    -- RU 官方已核实九参数签名；0/0 的过滤语义仍待实机对照，不能沿用旧注释宣称它已经证明无上限。
    -- 本轮保留现有参数，先记录返回与事件；不新增 Native 查询或 UI 搜索框写入。
    if pending.evidence ~= nil then pending.evidence.sentAt = EvidenceTime() end
    local ok, value, err, second, third, fourth = S.Api:CallCapability("X2Auction:SearchAuctionArticle", nil, "SearchAuctionArticle",
        1, 0, 0, 1, 0, options.exactMatch == true, keyword, "0", "0")
    if pending.evidence ~= nil then
        local returned = EvidencePacket(value, second, third, fourth)
        -- Api:Call 固定返回最多四个 Native 槽位；该数不是 Native 的实际返回数量，尾 nil 不推断不存在。
        returned.argCount, returned.observedReturnSlots = nil, 4
        returned.callOk, returned.error = ok == true, err
        pending.evidence.searchReturn = returned -- 同步完成后也补回同一请求证据，不污染下一代。
    end
    if ok ~= true or value == false then
        local reason = tostring(err or "搜索请求被拒绝")
        if self.pending == pending then self:_Complete("failed", {}, reason) end
        return false, reason
    end
    return true, "waiting"
end

function Q:Describe()
    return { version = self.version, pending = self.pending ~= nil, eventBound = self.eventBound == true,
        maxRows = self.maxRows, timeoutMs = self.timeoutMs, patch = self.priorityPatch,
        nativeUserPriorityContractVersion = self.NativeUserPriorityContractVersion,
        sortPatch = self.sortPatch, sampledUnitPriceContractVersion = self.SampledUnitPriceContractVersion,
        requester = self.pending ~= nil and self.pending.requester or nil,
        searchGeneration = self.pending ~= nil and self.pending.searchGeneration or nil,
        background = self.pending ~= nil and self.pending.background == true,
        discarded = self.pending ~= nil and self.pending.discarded == true,
        drainUntil = self.pending ~= nil and self.pending.discarded == true and self.pending.expiresAt or nil,
        interruptions = self.interruptions, discardedCompletions = self.discardedCompletions,
        visibility = Copy(self.lastVisibility) }
end

-- Replicated Suite · 共享材料报价队列
-- 作者：Replicated
-- QQ群：1104129461
-- 显式报价共用串行通道，间隔不低于 GetLowestPrice 的 RU 官方 500ms 冷却；普通刷新不能逐材料发查询。
-- RequestQuote 按 requester 和 itemType/itemGrade 排队，回调及 completed 交付结果；重读快照不再发包。
-- 身份未知、阻断或不可读都返回状态，不能伪造价格。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Services = S.Services or {}
local Q = {
    version = 3,
    EventAuthorityContractVersion = 1,
    NativeUserPriorityContractVersion = 1,
    NativeInteractionContractVersion = 1,
    nativeInteractionPatch = "auction-full-lane-safety-1",
    ActivityTopic = "v3.price_quote.activity",
    activityPatch = "auction-user-priority-1",
    paused = false, pauseReason = nil, pauseStartedAt = nil, resumeAfter = nil,
    EventPayloadContractVersion = 1, -- 完成事件携带 itemType/itemGrade/status/reason，用于有界投影同步。
    RequestIdentityDedupContractVersion = 1, -- 请求身份取稳定 itemType+grade 梯度，searchName 仅作 fallback 元数据；耐久价格由 MaterialPriceServiceV3 保存。
    MaterialPriceAuthorityContractVersion = 1,
    PriorityQueueContractVersion = 1, -- 用户显式报价排在后台 SWR 前，但不抢占当前 Native 调用。
    FallbackIdentityMatchContractVersion = 1,
    MarketPriceHandshakeContractVersion = 1,
    PriceSafetyContractVersion = 1,
    RequoteContractVersion = 2,
    SingleQueryContractVersion = 1,
    singleQuerySequence = 0, singleQueryWatchers = {},
    requotePatch = "trade-requote-2",
    -- 准入等待不是 Native 在途。最多64项共享容量、单一既有1s lane；
    -- unknown 最多宽限45s后明确 blocked，已确认玩家打开拍卖行仍等待关闭，不抢结果。
    admissionWaiting = {},
    unknownAdmissionWaitMs = 45000,
    maxListingObservations = 2,
    priceSafetyPatch = "trade-quote-price-safety-1",
    -- 名称搜索只取 AuctionQueryV3 按数量归一的单价；同身份选较低可立即购买价，数量缺失则拒绝。
    FallbackUnitPriceContractVersion = 1,
    presentationBoundary = "service_only",
    Topic = "v3.price_quote.completed",
    -- 只保留一个 pending 原生调用；GetLowestPrice 同步，但节奏及交付异步，同一时刻仅一请求在途。
    pending = nil,
    queue = {},
    snapshots = {},
    -- itemType 映射最新 queued/inflight/ready/failed 生命周期；Trade/Craft/Auction 据此显示排队、查询中、已
    -- 报价、失败，不能从缺价猜状态。失败完成不复活或清除有效价格。
    quoteStateByItemType = {},
    -- 最新完成（任意状态）只保留单条有界记录，供诊断复制；不是第二权威，requester 快照仍是读模型。
    lastCompleted = nil,
    -- itemType 映射会话最新完成报价；Trade/CraftAssist/AuctionFavorites 可按 itemType+itemGrade 得材料单价
    -- ，不需知道请求者，也不重新查询服务器。
    pricesByItemType = {},
    -- 旧长期参考表仅作迁移来源；耐久年龄由服务器时间计算，NowMs 不能跨重载。
    -- 按 itemType+grade 保存有界观察历史，旧价可先显示，再由新报价替换。
    StoreId = "v3.trade_reference_prices",
    -- 缓存契约 v2 丢弃旧 name_search_direct 的整单价语义，不改 Store schema。
    StoreContractVersion = 2,
    referencePrices = {},          -- 缓存形状：itemType:grade -> { price, updatedAt, samples }。
    storeLoaded = false,
    persistPending = false,
    -- 会话价格缓存按 itemType:grade 使用已验证 TTL；普通显式点击复用新鲜报价，options.force 为主动刷新覆盖
    -- 。负结果独立采用策略相关 30s 退避，不伪造价格。
    cache = {},
    cacheTtlMs = 120000,
    owner = {},
    -- 默认每 1000ms 排一项，仍按单调时钟保证 >=500ms，不能只数 tick（预算延迟会让相邻执行贴近）。
    -- 只有显式协议/品质探针展开梯度，普通请求不隐式探测。
    intervalMs = 1000,
    lastNativeCallAt = nil,
    maxQueue = 64,
    taskName = "v3_price_quote_drain",
    running = false,
    -- 有界诊断记录解释 RU 报价为何失败封闭，不修改读模型契约。
    stats = { attempts = 0, ready = 0, failed = 0, merged = 0, cacheHits = 0,
        cancelled = 0, nativeLastMs = 0, nativeMaxMs = 0, fallbackMatches = 0,
        marketPriceAsks = 0, marketPriceAskFailures = 0 },
    negativeCache = {}, negativeTtlMs = 30000, cacheMax = 512,
    budgetPatch = "trade-budget-1",
    recent = {},        -- 最近完成环按最新优先保存。
    recentMax = 12,
    lastRawReturn = nil,
    -- 名称搜索仍只发一次服务器请求；最多读取 20 条分离结果，按稳定 itemType/精确名称本地匹配，
    -- 避免模糊搜索首条并非目标导致误判。
    fallbackSearchLimit = 20,
    lastFallbackMatch = nil,
    lastMarketAsk = nil,
}
S.Services.PriceQuoteQueueV3 = Q

local function NowMs()
    if type(S.NowMs) == "function" then return math.max(0, tonumber(S.NowMs()) or 0) end
    return 0
end

local function Copy(value)
    if S.Utils ~= nil and type(S.Utils.DeepCopy) == "function" then return S.Utils.DeepCopy(value) end
    if type(value) ~= "table" then return value end
    local out = {}; for key, child in pairs(value) do out[key] = Copy(child) end; return out
end

local function PositiveInt(value)
    local n = tonumber(value); if n == nil or n ~= math.floor(n) or n < 1 then return nil end
    return math.floor(n)
end

-- 暂停/恢复用独立 topic；completed 会推进 RowJob 完成数，不能用它发送 paused/resumed。
local PAUSE_REASONS = {
    native_auction_visible = "拍卖行使用中，材料询价已暂停；关闭拍卖行后自动继续",
    native_auction_visibility_unknown = "无法确认拍卖行已关闭，材料询价已暂停；持续不可读将停止本次询价",
    auction_user_search_pending = "正在等待手动拍卖搜索完成，材料名称查询已暂停",
    auction_response_drain = "正在隔离旧拍卖查询回包，材料名称查询稍后继续",
    auction_query_busy = "正在等待共享拍卖搜索通道，材料名称查询已暂停",
}
function Q:GetActivitySnapshot()
    return { patch = self.activityPatch, paused = self.paused == true, reason = self.pauseReason,
        pausedAt = self.pauseStartedAt, resumeAfter = self.resumeAfter,
        text = self.paused == true and PAUSE_REASONS[self.pauseReason] or nil,
        requotePatch = self.requotePatch, admissionWaiting = #self.admissionWaiting,
        verifying = self.pending ~= nil and self.pending.verifying == true,
        lastBlocked = Copy(self.lastBlocked) }
end
function Q:_SetPaused(paused, reason)
    paused = paused == true
    reason = paused and tostring(reason or "native_auction_visibility_unknown") or nil
    if self.paused == paused and self.pauseReason == reason then return false end
    if paused and not self.paused then self.pauseStartedAt = NowMs() end
    if not paused then self.pauseStartedAt = nil end
    self.paused, self.pauseReason = paused, reason
    if S.Events ~= nil and type(S.Events.Publish) == "function" then
        S.Events:Publish(self.ActivityTopic, self:GetActivitySnapshot())
    end
    return true
end
-- 只让出尚未占用原生搜索通道的本地请求。已发包的无令牌响应
-- 必须继续由 AuctionQuery 原 timeout 隔离；不能为了让队列前进而把它当成已取消。
local function HasWork()
    return Q.pending ~= nil or #Q.queue > 0 or #Q.admissionWaiting > 0
end
-- 同一身份已有显式重验时，普通调用者也必须加入该请求；不能先用旧 TTL 发 ready，
-- 否则共享完成事件会提前结算 Trade RowJob。只在请求入队边沿扫描总计<=64项，无 Tick 扫描。
local function HasCurrentListingRequest(requestKey)
    if Q.pending and Q.pending.requestKey == requestKey and Q.pending.requireListing == true then return true end
    for _, request in ipairs(Q.queue) do
        if request.requestKey == requestKey and request.requireListing == true then return true end
    end
    for _, request in ipairs(Q.admissionWaiting) do
        if request.requestKey == requestKey and request.requireListing == true then return true end
    end
    return false
end
local function InsertByPriority(list, request)
    local index = #list + 1
    if request.priority == "user" then
        for i = 1, #list do
            if tostring(list[i].priority or "normal") == "background" then index = i; break end
        end
    end
    table.insert(list, index, request)
end
-- Ask/Read/Search 整条协议都须检查玩家占用；UI 参数 false 不代表空闲。
-- 仅在需求 lane/显式探针读取可见性，缺证据或读失败时不能发包。
function Q:CanNativeQuote()
    local query = S.Services and S.Services.AuctionQueryV3 or nil
    local allowed, reason = false, "native_auction_visibility_unknown"
    if type(query) == "table" and type(query.CanBackgroundSearch) == "function" then
        local ok, value, why = pcall(query.CanBackgroundSearch, query)
        if ok == true then allowed, reason = value == true, why end
    end
    if allowed and type(query.Describe) == "function" then
        local state = query:Describe()
        if type(state) == "table" and state.pending == true
            and not (self.pending and self.pending.fallbackState == "searching") then
            allowed, reason = false, "auction_query_busy"
        end
    end
    if allowed then reason = nil else reason = tostring(reason or "native_auction_visibility_unknown") end
    self.nativeAdmission = { allowed = allowed, reason = reason, at = NowMs() }
    return allowed, reason
end
local function ParkAdmission(request, reason)
    local query = S.Services and S.Services.AuctionQueryV3 or nil
    local state = query and type(query.Describe) == "function" and query:Describe() or nil
    -- 只有正在让出无 token 在途查询的 pending 需保留隔离。
    -- 其它未发包请求可以停在本地等待区，不能因为原生手动查询忙就占住/反复派发它们。
    if Q.pending == request and type(state) == "table" and state.pending == true then return false end
    if request.fallbackState == "searching" then return false end
    request.admissionReason = reason
    request.unknownSince = reason == "native_auction_visibility_unknown" and (request.unknownSince or NowMs()) or nil
    request.fallbackDeadlineAt = nil
    if Q.pending == request then Q.pending = nil end
    InsertByPriority(Q.admissionWaiting, request)
    Q.resumeAfter = nil
    Q:_SetPaused(Q.pending == nil and #Q.queue == 0, reason)
    return true
end
local function PauseFallback(request, reason)
    -- 玩家介入 Ask 与 Read 之间后，不接受共享 Native 旧快照。
    -- 恢复时先重新 Ask，再按原节流 Read；已获得的本地确认价完全不动。
    if request.marketPriceState == "readback_queued" then
        request.marketPriceState, request.marketPriceGrade = "ask_queued", nil
    end
    if request.fallbackState == "searching" then
        local query = S.Services and S.Services.AuctionQueryV3 or nil
        if type(query) == "table" and type(query.YieldBackgroundSearch) == "function" then query:YieldBackgroundSearch(reason) end
        request.fallbackState = "queued"
    end
    -- 最后一个 watcher 可能在“在飞但尚未暂停”的时刻已取消。转为本地等待后必须释放它，
    -- 不能关窗又重发无人需要的请求；原 Native 隔离占位仍由 AuctionQuery 的有限 timeout 回收。
    if type(request.watchers) == "table" and next(request.watchers) == nil then
        Q.pending = nil
        Q.quoteStateByItemType[request.itemType] = { status = "cancelled", itemGrade = request.itemGrade, at = NowMs() }
        if not HasWork() then Q:_StopLane() else Q:_SetPaused(false) end
        return
    end
    if ParkAdmission(request, reason) then return end
    -- 已发 Native 尚在隔离时保留 pending；未发包的等待已由上方分离。
    request.fallbackDeadlineAt = nil
    Q.resumeAfter = nil
    Q:_SetPaused(true, reason)
end

-- 金额接受标量、逗号串及已支持的 gold/silver/copper 包装，递归最多 4 层。
-- 带 listing/堆叠字段的未知表不能据总价、数量或 bid 猜单位价，交给名称搜索在同一行中核实。
-- 先声明局部名再赋递归函数，避免递归引用解析成全局。
local function ToMoney(value, depth)
    depth = tonumber(depth) or 0
    if depth > 4 then return nil end
    if type(value) == "number" then
        if value ~= value or value == math.huge or value == -math.huge then return nil end
        return value
    end
    if type(value) == "string" then
        local cleaned = value:gsub(",", ""):gsub("%s", "")
        return ToMoney(tonumber(cleaned), depth + 1)
    end
    if type(value) == "table" then
        for _, key in ipairs({ "itemStack", "stackCount", "stack", "count", "quantity", "itemCount", "stackSize",
            "directPrice", "directPriceStr", "buyoutPrice", "buyoutPriceStr", "bidPrice", "bidPriceStr" }) do
            if value[key] ~= nil then return nil end
        end
        local gold = tonumber(value.gold or value.g)
        local silver = tonumber(value.silver or value.s)
        local copper = tonumber(value.copper or value.c)
        if gold ~= nil or silver ~= nil or copper ~= nil then
            for _, component in ipairs({ gold or 0, silver or 0, copper or 0 }) do
                if component ~= component or component < 0 or component == math.huge then return nil end
            end
            return ToMoney((gold or 0) * 10000 + (silver or 0) * 100 + (copper or 0), depth + 1)
        end
        for _, key in ipairs({
            "value", "price", "money", "lowestPrice", "lowest_price",
        }) do
            local n = ToMoney(value[key], depth + 1); if n ~= nil then return n end
        end
    end
    return nil
end

-- 用户或旧显示名约束为安全搜索关键字，与 AuctionQueryV3 的 SearchAuctionArticle 契约一致：1..64 可见字符，
-- 无控制字符。
local function TrimToKeyword(value)
    local text = tostring(value or ""):gsub("[\r\n\t%c]", " ")
    text = text:match("^%s*(.-)%s*$") or ""
    if text == "" or #text > 64 then return nil end
    return text
end

local function NormalizeQuote(raw)
    if raw == nil then return nil end
    local price = ToMoney(raw)
    if price == nil or price ~= price or price == math.huge or price < 1 then return nil end
    return { value = math.floor(price), source = type(raw) == "table" and "money_field" or type(raw) }
end

-- 原始 Native 返回的有界保真类型描述，用于回答 RU GetLowestPrice 真实形状，不向诊断倾倒无界 payload。
local function ShapeOf(value)
    local kind = type(value)
    if kind == "nil" or kind == "boolean" then return kind .. ":" .. tostring(value) end
    if kind == "number" then return "number:" .. tostring(value) end
    if kind == "string" then
        local sample = #value > 40 and (string.sub(value, 1, 40) .. "…") or value
        return "string(" .. tostring(#value) .. "):" .. sample
    end
    if kind ~= "table" then return kind end
    local fields, total = {}, 0
    for key, child in pairs(value) do
        total = total + 1
        if #fields < 12 then fields[#fields + 1] = tostring(key) .. "=" .. type(child) end
    end
    table.sort(fields)
    return "table(" .. tostring(total) .. "){" .. table.concat(fields, ",") .. "}"
end


-- 最低挂单品质可与静态提示不同；某品质 nil 是有效无货答案，不是错误。已验证旧协议对每材料探测有界品质梯度，
-- 并检查所有返回槽，因为价格不总在首个返回。
local function ScanPrice(...)
    local count = select("#", ...)
    for index = 1, count do
        local n = ToMoney(select(index, ...))
        if n ~= nil and n == n and n ~= math.huge and n >= 1 then return math.floor(n) end
    end
    return nil
end

local function Publish(itemType, itemGrade, status, reason)
    if S.Events ~= nil and type(S.Events.Publish) == "function" then
        -- 完成事件带本请求的 itemType/itemGrade，供迟到或共享回调定位，不要求 Feature 全表扫描。
        -- 身份只取 pending/request，不能从 UI 名称推断；旧监听器可忽略新增参数。
        S.Events:Publish(Q.Topic, itemType, itemGrade, status, reason)
    end
end

-- GetLowestPrice 成功但全 nil 可能是协议中间态、缓存未预热或无货，不能只凭 nil 判 API 损坏。
-- 显式控制探针用燕麦/干草捆/鸡蛋，并结合名称 fallback 结果解释。
local PROBE_CONTROL_ITEM_TYPES = { 3545, 3712, 3603 }
local ProbeState = { done = false, results = {}, attempts = 0, maxAttempts = 6 }

-- 同步原生读取只记录 RU 返回精确形状，不参与价格、不修改读模型，也不在单位或行循环运行。
function Q:RunProtocolProbe()
    if ProbeState.done == true then return true end
    if S.Api == nil or type(S.Api.CallCapability) ~= "function" then return false end
    -- 手动协议探针也不得绕过原生优先级或挤占正在工作的 lane。
    if HasWork() then return false, "price_quote_busy" end
    local allowed, reason = self:CanNativeQuote()
    if allowed ~= true then return false, reason end
    if Q.lastNativeCallAt ~= nil and NowMs() - Q.lastNativeCallAt < Q.intervalMs then return false, "quote_cooldown" end
    if ProbeState.attempts >= ProbeState.maxAttempts then
        ProbeState.done = true
        return true
    end
    local index = (#ProbeState.results) + 1
    if index > #PROBE_CONTROL_ITEM_TYPES then
        ProbeState.done = true
        return true
    end
    local itemType = PROBE_CONTROL_ITEM_TYPES[index]
    ProbeState.attempts = ProbeState.attempts + 1
    Q.lastNativeCallAt = NowMs()
    -- 先试 grade=0，旧梯度将其视为未过滤的最宽查询。
    local ok, value, err, b, c, d = S.Api:CallCapability("X2Auction:GetLowestPrice", nil, "GetLowestPrice", itemType, 0)
    ProbeState.results[#ProbeState.results + 1] = {
        itemType = itemType, grade = 0, ok = ok == true,
        error = err ~= nil and tostring(err) or nil,
        shape = ShapeOf(value) .. "|" .. ShapeOf(b) .. "|" .. ShapeOf(c) .. "|" .. ShapeOf(d),
        money = ScanPrice(value, b, c, d),
        at = NowMs(),
    }
    Publish(nil, nil, "probe", "protocol_probe")
    return true
end

function Q:GetProtocolProbe()
    return Copy({ done = ProbeState.done, attempts = ProbeState.attempts, results = ProbeState.results })
end

-- 稳定 ID 梯度耗尽后只发一次名称搜索；原生完成事件仍由 AuctionQueryV3 管理。
local function BeginSearchFallback(pending)
    local query = S.Services and S.Services.AuctionQueryV3 or nil
    if type(query) ~= "table" or type(query.Search) ~= "function" then return false, "auction_query_unavailable" end
    local keyword = tostring(pending.searchName or "")
    if keyword == "" or #keyword > 64 then return false, "search_name_unavailable" end
    -- 共享 AuctionQueryV3 拥有无 token 完成边沿；玩家搜索已在途时不抢夺或取消，也不因忙碌使报价失败。下一次
    -- 有节奏轮转只重试本地准入检查。
    local describe = type(query.Describe) == "function" and query:Describe() or nil
    if type(describe) == "table" and describe.pending == true then return false, "auction_query_busy" end
    pending.fallbackState = "searching"
    pending.fallbackDeadlineAt = pending.fallbackDeadlineAt or (NowMs() + 12000)
    -- 名称搜索首条未必是目标，单次请求最多读 20 条，先匹配 itemType，再匹配精确名称。
    -- requireListing 限制价格来源，不是 Native exactMatch 开关；返回后仍核实身份，不追加翻页或重试。
    local ok, err = query:Search("price_quote_fallback", keyword, { resultLimit = Q.fallbackSearchLimit, background = true, exactMatch = false })
    if ok ~= true then pending.fallbackState = "queued" end
    return ok == true, err
end

local function FallbackRowPrice(row, requireListing)
    if type(row) ~= "table" then return nil, nil, "row_unavailable" end
    -- directPrice/bidPrice 是整单总价，不能再乘材料数量；只取 unit*，旧快照有 quantity 时可重算，缺数量绝不猜。
    local quantity = tonumber(row.quantity)
    if quantity == nil or quantity ~= quantity or quantity == math.huge or quantity < 1 or quantity ~= math.floor(quantity) then return nil, nil, "listing_quantity_unavailable" end
    local directUnit = ToMoney(row.unitDirectPrice)
    if directUnit == nil then
        local directTotal = ToMoney(row.directPrice)
        if directTotal ~= nil and directTotal > 0 then directUnit = math.max(1, math.ceil(directTotal / quantity)) end
    end
    if directUnit ~= nil and directUnit == directUnit and directUnit > 0 then
        return math.floor(directUnit), "name_search_direct_unit", nil
    end
    -- 显式货物重验以本次同物品一口价为准；竞拍起价不是可直接购入成本。
    if requireListing == true then return nil, nil, "buyout_unavailable" end
    local bidUnit = ToMoney(row.unitBidPrice)
    if bidUnit == nil then
        local bidTotal = ToMoney(row.bidPrice)
        if bidTotal ~= nil and bidTotal > 0 then bidUnit = math.max(1, math.ceil(bidTotal / quantity)) end
    end
    if bidUnit ~= nil and bidUnit == bidUnit and bidUnit > 0 then
        return math.floor(bidUnit), "name_search_bid_unit", nil
    end
    return nil, nil, "listing_price_unavailable"
end

local function NormalizeSearchIdentityName(value)
    local text = tostring(value or "")
    text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    text = text:gsub("[%s%c]+", " ")
    return text:match("^%s*(.-)%s*$") or ""
end

local function SelectFallbackRow(rows, pending)
    rows = type(rows) == "table" and rows or {}
    local expected = tonumber(pending and pending.itemType)
    expected = expected ~= nil and math.floor(expected) or nil
    local wantedName = NormalizeSearchIdentityName(pending and pending.searchName)
    local typed, named = {}, {}
    for index, row in ipairs(rows) do
        if type(row) == "table" then
            local rowType = tonumber(row.itemType)
            rowType = rowType ~= nil and math.floor(rowType) or nil
            local gradeMatches = pending.requireListing ~= true or row.itemGrade == nil
                or tonumber(row.itemGrade) == tonumber(pending.itemGrade)
            if gradeMatches and expected ~= nil and rowType ~= nil and rowType == expected then
                typed[#typed + 1] = { row = row, index = index, kind = "itemType" }
            else
                local gotName = NormalizeSearchIdentityName(row.name)
                -- 文本只可补缺失稳定身份，不能覆盖冲突身份。
                if gradeMatches and wantedName ~= "" and gotName == wantedName and (rowType == nil or expected == nil) then
                    named[#named + 1] = { row = row, index = index, kind = "name" }
                end
            end
        end
    end
    local pool = #typed > 0 and typed or named
    if #pool == 0 then return nil, "none", nil, nil, nil, "identity_not_found" end

    -- SearchAuctionArticle 排序不保证单价；本地评估全部有界匹配行并选最低可立即买入单价。只有匹配直购行无可
    -- 用数量时才考虑 bid-only，不增加 Native/服务器调用。
    local bestDirect, bestBid, firstReason = nil, nil, nil
    for _, candidate in ipairs(pool) do
        local price, source, reason = FallbackRowPrice(candidate.row, pending.requireListing)
        firstReason = firstReason or reason
        if price ~= nil then
            local target = source == "name_search_direct_unit" and "direct" or "bid"
            local record = { row = candidate.row, index = candidate.index, kind = candidate.kind, price = price, source = source }
            if target == "direct" then
                if bestDirect == nil or price < bestDirect.price then bestDirect = record end
            elseif bestBid == nil or price < bestBid.price then
                bestBid = record
            end
        end
    end
    local best = bestDirect or bestBid
    if best ~= nil then return best.row, best.kind, best.index, best.price, best.source, nil end
    local first = pool[1]
    return first.row, first.kind, first.index, nil, nil, firstReason or "unit_price_unavailable"
end


-- 会话缓存有界，取消仅移除请求者需求；不能清除其它模块共享的事实。
local function CachePut(cache, key, value)
    local count, oldest, at = 0, nil, math.huge
    for k, v in pairs(cache) do
        count = count + 1
        local activeStrict = cache == Q.snapshots and Q.singleQueryWatchers[k] ~= nil
        if not activeStrict and (tonumber(v.at) or 0) < at then oldest, at = k, tonumber(v.at) or 0 end
    end
    if cache[key]==nil and count>=Q.cacheMax and oldest then cache[oldest]=nil end
    cache[key]=value
end
local function Deliver(requester, callback, snapshot)
    local value=Copy(snapshot);value.requester=requester
    CachePut(Q.snapshots, requester, value)
    if type(callback)=="function" then
        local ok,err=pcall(callback,Copy(value))
        if not ok then S.LastPriceQuoteCallbackError={requester=requester,error=tostring(err)} end
    end
end

local function CompletePending(status, quote, err, origin, waitingRequest)
    local pending = waitingRequest or Q.pending
    if type(pending) ~= "table" then return false end
    local requester = pending.requester
    if Q.pending == pending then Q.pending = nil end
    local observedPrice = quote and quote.value or nil
    local priceHeld, referenceStored, priceDecision = false, false, nil
    if status == "ready" and quote ~= nil and pending.itemType ~= nil then
        -- 每个 Native 回包只向价格服务登记一次，接受后才写 session/TTL；候选隔离不延长旧价新鲜度。
        referenceStored, priceDecision = Q:RecordReferencePrice(pending.itemType,
            pending.resolvedGrade or pending.itemGrade, quote.value, quote.source)
        priceHeld = referenceStored ~= true and priceDecision == "anomaly_candidate_held"
        if priceHeld and pending.singleQuery == true then
            -- 严格单次查询不负责二次验证；候选价不冒充已确认价。
            status, quote, err = "review_required", nil, "anomaly_candidate_held"
        elseif priceHeld and pending.requireListing == true and type(pending.watchers) == "table" and next(pending.watchers) == nil then
            -- 已发出的首个观察可自然收尾，但最后消费者离开后不得追加第二次确认搜索。
            status, quote, err = "cancelled", nil, "requesters_released"
        elseif priceHeld and pending.requireListing == true then
            -- 一次双击内部最多两个独立名称查询；不能靠复用同一快照、重复 Observe 来凑两次确认。
            -- 首次候选保留原价但不发 completed/ready；下一 paced turn 重新发 Native 请求。
            pending.heldObservations = (tonumber(pending.heldObservations) or 0) + 1
            if pending.heldObservations < Q.maxListingObservations then
                pending.marketPriceState, pending.marketPriceGrade = nil, nil
                pending.fallbackState, pending.fallbackDeadlineAt = "queued", NowMs() + 12000
                pending.verifying = true
                Q.pending = pending
                Q.quoteStateByItemType[pending.itemType] = { status = "verifying", itemGrade = pending.itemGrade,
                    candidatePrice = observedPrice, at = NowMs() }
                if S.Events and type(S.Events.Publish) == "function" then S.Events:Publish(Q.ActivityTopic, Q:GetActivitySnapshot()) end
                return false
            end
            status, quote, err = "review_required", nil, "两次一口价观察不一致，旧价保留；材料价需复核"
        elseif priceHeld then
            local materialPrices = S.Services and S.Services.MaterialPriceServiceV3 or nil
            local accepted, meta
            if materialPrices and type(materialPrices.GetPrice) == "function" then
                accepted, meta = materialPrices:GetPrice(pending.itemType, pending.resolvedGrade or pending.itemGrade)
            end
            if accepted ~= nil then quote = { value = accepted, source = meta and meta.source or "retained_reference" }
            else status, quote, err = "unavailable", nil, "anomaly_candidate_without_reference" end
        end
    end
    local snapshot = {
        requester = requester,
        itemType = pending.itemType,
        itemGrade = pending.itemGrade,
        status = tostring(status or "failed"),
        price = quote ~= nil and quote.value or nil,
        priceSource = quote ~= nil and quote.source or nil,
        error = err,
        observedPrice = observedPrice, priceAccepted = status == "ready" and not priceHeld,
        referenceStored = referenceStored == true, priceDecision = priceDecision,
        marketError = pending.marketError, requireListing = pending.requireListing == true,
        -- 冻结排队/响应阶段事实，TXT 不再把没发出的搜索笼统报告成 Native 响应超时。
        singleQuery = pending.singleQuery == true, searchGeneration = pending.searchGeneration,
        dispatchedAt=pending.dispatchedAt, queueDeadlineAt=pending.queueDeadlineAt, deadlineAt=pending.deadlineAt,
        blockReason = status == "blocked" and pending.admissionReason or nil,
        requestedAt = pending.requestedAt,
        completedAt = NowMs(),
        contract = "显式+异步报价；串行限速；结果字段按当前 RU 返回做 bounded normalization，未验证字段不作为成交样本",
        errorCode = pending.failureCode,
    }
    snapshot.at = snapshot.completedAt
    -- ready 同步单价缓存，其它终态保留缺价原因，避免 UI 永久待询价。
    if pending.itemType ~= nil then
        if status == "ready" and quote ~= nil then
            Q.quoteStateByItemType[pending.itemType] = {
                status = "ready", price = quote.value, priceSource = quote.source,
                itemGrade = pending.resolvedGrade or pending.itemGrade, requester = requester, at = snapshot.completedAt,
            }
        else
            Q.quoteStateByItemType[pending.itemType] = {
                status = (status == "blocked" or status == "cancelled") and status or "failed", code = tostring(status or "failed"), error = err,
                itemGrade = pending.resolvedGrade or pending.itemGrade, requester = requester, at = snapshot.completedAt,
            }
        end
    end
    Q.lastCompleted = {
        requester = requester, itemType = pending.itemType, itemGrade = pending.itemGrade,
        status = snapshot.status, price = snapshot.price, priceSource = snapshot.priceSource,
        error = err, rawShape = Q.lastRawReturn, requestedAt = pending.requestedAt, at = snapshot.completedAt,
        -- 最近完成环也保留两阶段时间；操作结束后原 active operation 已被释放。
        dispatchedAt=pending.dispatchedAt, queueDeadlineAt=pending.queueDeadlineAt, deadlineAt=pending.deadlineAt,
        observedPrice = observedPrice, priceAccepted = snapshot.priceAccepted, priceDecision = priceDecision,
        marketError = pending.marketError,
    }
    if status == "ready" then Q.stats.ready = Q.stats.ready + 1 else Q.stats.failed = Q.stats.failed + 1 end
    table.insert(Q.recent, 1, {
        requester = requester, itemType = pending.itemType, itemGrade = pending.itemGrade,
        status = snapshot.status, price = snapshot.price, priceSource = snapshot.priceSource,
        error = err, rawShape = Q.lastRawReturn, at = snapshot.completedAt,
        requestedAt=pending.requestedAt, dispatchedAt=pending.dispatchedAt,
        queueDeadlineAt=pending.queueDeadlineAt, deadlineAt=pending.deadlineAt,
        observedPrice = observedPrice, priceAccepted = snapshot.priceAccepted, priceDecision = priceDecision,
        marketError = pending.marketError,
    })
    if #Q.recent > Q.recentMax then table.remove(Q.recent) end
    -- 失败/不可用不覆盖旧有效价；保留可信参考值，不能清成会被误当 0 的缺价。
    if status == "ready" and quote ~= nil and pending.itemType ~= nil and not priceHeld then
        Q.pricesByItemType[pending.itemType] = {
            price = quote.value, source = quote.source, itemGrade = pending.resolvedGrade or pending.itemGrade,
            completedAt = snapshot.completedAt,
        }
        -- 新挂单已验真时，同身份旧 TTL/负缓存失效；不能在下一次
        -- 普通请求中回放修正前价格。只失效当前品质，不清其它材料，也不把名称样本伪装成直接实时缓存。
        if pending.requireListing == true then
            local grade = tonumber(pending.resolvedGrade) or tonumber(pending.itemGrade)
            if grade ~= nil then Q.cache[tostring(pending.itemType) .. ":" .. tostring(grade)] = nil end
            if pending.requestKey ~= nil then Q.negativeCache[pending.requestKey] = nil end
        end
        -- 只有稳定 ID 直接报价进入 TTL 缓存；名称搜索 bid 仅参考估计，不能在后续被动刷新当新鲜价复用。
        if origin ~= "fallback" then
            local resolvedGrade = tonumber(pending.resolvedGrade) or tonumber(pending.itemGrade)
            if resolvedGrade ~= nil then
                CachePut(Q.cache, tostring(math.floor(pending.itemType)) .. ":" .. tostring(math.floor(resolvedGrade)),
                    { price = quote.value, at = snapshot.completedAt })
            end
        end
    end
    if status ~= "ready" and status ~= "blocked" and status ~= "review_required" and status ~= "cancelled" and pending.requestKey then
        CachePut(Q.negativeCache, pending.requestKey, {at=NowMs(),snapshot=Copy(snapshot)})
    end
    -- 每个消费者各接收一次；取消的页面不再回调。快照在回调前复制，不能跨Feature共享可写表。
    for token, watcher in pairs(pending.watchers or {[requester]={callback=pending.callback}}) do
        if pending.singleQuery ~= true or Q.singleQueryWatchers[token] == watcher then
            if pending.singleQuery == true then Q.singleQueryWatchers[token] = nil end
            Deliver(token,watcher.callback,snapshot)
        end
    end
    if not HasWork() then Q:_StopLane() end
    Publish(pending.itemType, pending.resolvedGrade or pending.itemGrade, snapshot.status, tostring(origin or "completed"))
    return true
end

-- 严格路径只发一次 Search：默认前台共五秒，跑商可分本地等待和发包后五秒，后台仅发包前可等待准入。
-- 完成/取消先解绑通知；无 token 在途请求仍由 AuctionQuery 原 timeout 隔离。
local function FinishSingle(request, status, quote, reason)
    if request.finished == true then return false end
    request.finished = true
    if S.Scheduler and request.deadlineTask then S.Scheduler:RemoveTask(request.deadlineTask) end
    local query = S.Services and S.Services.AuctionQueryV3 or nil
    if request.queryOwner and S.Events and type(S.Events.UnsubscribeInternal) == "function" then
        S.Events:UnsubscribeInternal(query and query.Topic or "v3.auction_query.updated", request.queryOwner)
    end
    if query and type(query.YieldBackgroundSearch) == "function" and request.fallbackState == "searching" then
        query:YieldBackgroundSearch(reason or status, request.queryRequester, request.searchGeneration)
    end
    if query and type(query.ReleaseSnapshot) == "function" then query:ReleaseSnapshot(request.queryRequester, request.searchGeneration) end
    for i = #Q.queue, 1, -1 do if Q.queue[i] == request then table.remove(Q.queue, i) end end
    for i = #Q.admissionWaiting, 1, -1 do if Q.admissionWaiting[i] == request then table.remove(Q.admissionWaiting, i) end end
    request.admissionReason = status == "blocked" and reason or nil
    return CompletePending(status, quote, reason, "fallback", request)
end

function Q:_CheckSingle(request)
    request = request or self.pending
    if not request or request.singleQuery ~= true or request.finished or request.fallbackState ~= "searching" then return end
    local query = S.Services and S.Services.AuctionQueryV3 or nil
    local snap = query and type(query.GetSnapshot) == "function" and query:GetSnapshot(request.queryRequester) or nil
    if type(snap) ~= "table" or snap.searchGeneration ~= request.searchGeneration then return end
    if snap.status == "waiting" or snap.status == "idle" then return end
    -- （2026-10-02）原生 Count=0 与有结果却无可靠一口价是两个断点；空搜索不是已证实无货。
    if snap.status == "empty" then return FinishSingle(request, "unavailable", nil, "auction_search_empty") end
    if snap.status == "ready" or snap.status == "partial" then
        if snap.listingSelection ~= "sampled_unit_buyout" then
            request.failureCode = "auction_sample_missing"
            return FinishSingle(request, "unavailable", nil, "未返回可核验的拍卖样本")
        end
        for _, row in ipairs(snap.rows or {}) do
            if row.itemType == request.itemType and row.itemGrade == request.itemGrade then
                local price, source = FallbackRowPrice(row, true)
                if price ~= nil then
                    return FinishSingle(request, "ready", { value = price,
                        source = snap.sampleLowerLater == true and "name_search_sampled_lower_unit"
                            or "name_search_sampled_direct_unit" })
                end
            end
        end
        return FinishSingle(request, "unavailable", nil, "strict_buyout_not_found")
    end
    request.failureCode = snap.errorCode
    return FinishSingle(request, snap.status == "interrupted" and "blocked" or "unavailable", nil,
        snap.error or "strict_buyout_not_found")
end

local function ArmSingleDeadline(request, deadline)
    local scheduler = S.Scheduler
    if not scheduler or type(scheduler.AddOneShot) ~= "function" then return false end
    request.deadlineAt = deadline
    scheduler:RemoveTask(request.deadlineTask)
    local added = scheduler:AddOneShot(request.deadlineTask, math.max(0, deadline - NowMs()), function()
        if request.finished ~= true then
            local reason=request.queueDeadlineAt and request.deferDeadline and 'quote_queue_wait_timeout' or 'quote_deadline'
            FinishSingle(request, "timeout", nil, reason)
        end
    end, Q.owner, "P2", 1)
    if added and type(scheduler.SetTaskModule) == "function" then scheduler:SetTaskModule(request.deadlineTask, "PriceQuoteQueueV3", true) end
    return added == true
end

local function StartSingle(request)
    if request.finished then return end
    if request.deferDeadline == true then
        request.deferDeadline = false
        -- 排队期与 Native 响应期分开。跑商的本地等待有自己的硬期限；
        -- 真正取得 lane 后响应仍最多五秒，且不超过等待阶段的上界。后台原有准入策略保持不变。
        local responseDeadline=math.min(NowMs()+5000,request.queueDeadlineAt or math.huge)
        if not ArmSingleDeadline(request, responseDeadline) then return FinishSingle(request, "unavailable", nil, "quote_deadline_unavailable") end
    end
    if NowMs() >= request.deadlineAt then return FinishSingle(request, "timeout", nil, "quote_deadline") end
    local query = S.Services and S.Services.AuctionQueryV3 or nil
    if type(query) ~= "table" or type(query.Search) ~= "function" then
        return FinishSingle(request, "unavailable", nil, "auction_query_unavailable")
    end
    request.fallbackState = "searching"
    request.queryOwner = {}
    if S.Events and type(S.Events.SubscribeInternal) == "function" then
        S.Events:BindOwner(request.queryOwner, "PriceQuoteQueueV3")
        S.Events:SubscribeInternal(query.Topic, request.queryOwner, function(_, requester)
            if requester == request.queryRequester and Q.pending == request and request.finished ~= true then Q:_CheckSingle(request) end
        end)
    end
    Q.lastNativeCallAt = NowMs()
    request.dispatchedAt=Q.lastNativeCallAt
    -- 中文静态名不一定是 Native 完整索引名，强制 exactMatch 曾让有效候选在 ID 校验前被排除。
    -- 单次材料搜索用普通名称召回，随后验真实 ID/品质、正数量和一口价；本页最多三样本取较低参考单价，不代表全市场最低。
    local ok, err = query:Search(request.queryRequester, request.searchName, {
        background = true, exactMatch = false, resultLimit = 3,
        firstValidBuyout = { itemType = request.itemType, itemGrade = request.itemGrade },
        searchGeneration = request.searchGeneration,
    })
    if request.finished then return end -- Native 可能在 Search 内同步完成。
    if ok ~= true then
        return FinishSingle(request, PAUSE_REASONS[err] and "blocked" or "unavailable", nil, err or "search_rejected")
    end
    Q:_CheckSingle(request)
end

-- 只在既有需求 lane 中处理有界等待队列；不新建永久观察者。
-- 缺少可见性证据时整条询价协议只停留在本地等待区，
-- 不占用 Native 查询；blocked 不写“无货”负缓存。恢复后仍按用户优先级/同级 FIFO 发包。
local function PollAdmissionWaiting(allowed, reason)
    if #Q.admissionWaiting == 0 then return end
    local now, expired, promoted = NowMs(), {}, {}
    for index = #Q.admissionWaiting, 1, -1 do
        local request = Q.admissionWaiting[index]
        if allowed == true then
            table.remove(Q.admissionWaiting, index)
            request.admissionReason, request.unknownSince = nil, nil
            request.fallbackDeadlineAt = now + 12000
            promoted[#promoted + 1] = request
        else
            request.admissionReason = reason
            if reason == "native_auction_visibility_unknown" then
                request.unknownSince = request.unknownSince or now
                if now - request.unknownSince >= Q.unknownAdmissionWaitMs then
                    table.remove(Q.admissionWaiting, index)
                    expired[#expired + 1] = request
                end
            else request.unknownSince = nil end
        end
    end
    -- 倒序移除避免漏项，但恢复同级任务必须还原原始 FIFO，不能让最后排队的材料先查。
    for index = #promoted, 1, -1 do InsertByPriority(Q.queue, promoted[index]) end
    for _, request in ipairs(expired) do
        local message = "材料重验受阻：无法确认原生拍卖窗口已关闭；已停止本次询价，原价未更新。确认拍卖行关闭后可双击重试"
        Q.lastBlocked = { itemType = request.itemType, reason = "native_auction_visibility_unknown", at = now }
        Q.stats.admissionBlocked = (tonumber(Q.stats.admissionBlocked) or 0) + 1
        if request.singleQuery then FinishSingle(request, "blocked", nil, "native_auction_visibility_unknown")
        else CompletePending("blocked", nil, message, "admission", request) end
    end
end

-- fallback 拥有 pending 时，每个有节奏 drain tick 检查一次，全部队列转换归同一权威。不新增永久订阅，watcher
-- 仅在 fallback 期间存在。
function Q:_CheckFallback()
    local pending = Q.pending
    if type(pending) ~= "table" or pending.fallbackState ~= "searching" then return end
    local query = S.Services and S.Services.AuctionQueryV3 or nil
    if type(query) ~= "table" or type(query.GetSnapshot) ~= "function" then
        Q:_FailPending("unavailable", "拍卖名称搜索兜底不可用")
        return
    end
    local snap = query:GetSnapshot("price_quote_fallback")
    local status = type(snap) == "table" and tostring(snap.status or "") or ""
    if status == "interrupted" then
        PauseFallback(pending, "auction_response_drain")
        return
    end
    if status == "waiting" then
        -- AuctionQueryV3 自有 8s 超时；外层时间预算略宽，避免 Scheduler 抖动使 pending 永不结束。
        pending.fallbackDeadlineAt = pending.fallbackDeadlineAt or (NowMs() + 12000)
        if NowMs() < (tonumber(pending.fallbackDeadlineAt) or 0) then return end
        Q:_FailPending("unavailable", "名称搜索超时")
        return
    end
    if status == "ready" or status == "partial" then
        local rows = type(snap.rows) == "table" and snap.rows or {}
        local row, matchKind, matchIndex, price, priceSource, priceReason = SelectFallbackRow(rows, pending)
        Q.lastFallbackMatch = {
            keyword = tostring(pending.searchName or ""), itemType = pending.itemType,
            resultCount = #rows, matchKind = matchKind, matchIndex = matchIndex,
            status = status, at = NowMs(),
            quantity = type(row) == "table" and row.quantity or nil,
            directPrice = type(row) == "table" and row.directPrice or nil,
            bidPrice = type(row) == "table" and row.bidPrice or nil,
            unitDirectPrice = type(row) == "table" and row.unitDirectPrice or nil,
            unitBidPrice = type(row) == "table" and row.unitBidPrice or nil,
            selectedUnitPrice = price, priceSource = priceSource, priceReason = priceReason,
        }
        if row == nil then
            Q:_FailPending("unavailable", "名称搜索返回 " .. tostring(#rows) .. " 条，但没有匹配目标物品")
            return
        end
        if price ~= nil then
            Q.stats.fallbackMatches = (tonumber(Q.stats.fallbackMatches) or 0) + 1
            CompletePending("ready", { value = price, source = priceSource }, nil, "fallback")
            return
        end
        if priceReason == "listing_quantity_unavailable" then
            Q:_FailPending("unavailable", "匹配到目标物品，但拍卖结果缺少堆叠数量，已拒绝把整单价格当作材料单价")
        else
            Q:_FailPending("unavailable", "匹配到目标物品，但搜索结果没有可读单位参考价")
        end
        return
    end
    local queryError = type(snap) == "table" and snap.error or nil
    Q.lastFallbackMatch = {
        keyword = tostring(pending.searchName or ""), itemType = pending.itemType,
        resultCount = type(snap) == "table" and tonumber(snap.count) or 0,
        matchKind = "none", status = status ~= "" and status or "unknown", error = queryError, at = NowMs(),
    }
    if status == "empty" then
        Q:_FailPending("unavailable", "名称搜索没有返回在售结果")
    else
        Q:_FailPending("unavailable", "名称搜索失败：" .. tostring(queryError or status or "unknown"))
    end
end

local function RequeueFront(request)
    Q.pending = nil
    table.insert(Q.queue, 1, request)
end

local function QueueFallbackStart(request)
    if request.searchName == nil or request.searchName == "" then
        Q:_FailPending("unavailable", "目标品质没有可读最低价，且缺少名称搜索身份")
        return
    end
    -- GetLowestPrice/SearchAuctionArticle 都是服务器查询；fallback 放到下一次有节奏 drain，不在同一次调度发
    -- 两次请求，保持单通道节奏且不增加请求数。
    request.fallbackState = "queued"
    request.fallbackDeadlineAt = request.fallbackDeadlineAt or (NowMs() + 12000)
end

local function AdvanceAfterUnreadableLowestPrice(request, grades)
    request.marketPriceState = nil
    request.marketPriceGrade = nil
    request.gradeIndex = (tonumber(request.gradeIndex) or 1) + 1
    if request.gradeIndex <= #grades then
        RequeueFront(request)
        return
    end
    QueueFallbackStart(request)
end

local function ReadLowestPrice(request, grade, phase)
    Q.lastNativeCallAt = NowMs()
    local started = Q.lastNativeCallAt
    local ok, value, err, b, c, d = S.Api:CallCapability("X2Auction:GetLowestPrice", nil, "GetLowestPrice", request.itemType, grade)
    Q.stats.nativeLastMs = math.max(0, NowMs() - started)
    Q.stats.nativeMaxMs = math.max(Q.stats.nativeMaxMs, Q.stats.nativeLastMs)
    local gradeLabel = "grade " .. tostring(grade) .. "/" .. tostring(#(request.grades or {}))
    Q.lastRawReturn = ok ~= true and (tostring(phase or "read") .. "_failed:" .. tostring(err or "?"))
        or (tostring(phase or "read") .. " " .. gradeLabel .. ": " .. ShapeOf(value) .. ", " .. ShapeOf(b) .. ", " .. ShapeOf(c) .. ", " .. ShapeOf(d))
    if ok ~= true then return false, nil, tostring(err or "报价请求被拒绝") end
    local price = ScanPrice(value, b, c, d)
    if price == nil and type(value) == "table" then
        local quote = NormalizeQuote(value)
        if quote ~= nil then price = quote.value end
    end
    return true, price, nil
end

local function Drain()
    -- RU 2025-08-12 开放 AskMarketPrice 和 GetLowestPrice，均 500ms 冷却。Get 全 nil 时先 Ask，下一轮再 Read，无值才名称搜索。
    -- 三步共用一个通道，每轮最多一次服务器调用。now 使用本次 Drain 局部时间。
    -- 生成源码须用真实换行，字面 \n 留在 -- 注释里会吞掉后续 local now。
    local now = NowMs()
    if Q.pending and Q.pending.singleQuery == true then
        Q:_CheckSingle(Q.pending)
        if Q.pending and Q.pending.singleQuery == true then
            local allowed, reason = Q:CanNativeQuote()
            if not allowed then FinishSingle(Q.pending, "blocked", nil, reason) end
            return
        end
    end
    local wasPaused = Q.paused == true
    local allowed, reason = Q:CanNativeQuote()
    PollAdmissionWaiting(allowed, reason)
    if allowed ~= true then
        if Q.pending ~= nil then PauseFallback(Q.pending, reason) end
        -- 一次把<=64个未发包请求转入等待，unknown 宽限从
        -- 同一暂停边沿计时。不能逐材料先 Ask/Read 再等待，也不能让队尾多等数分钟才开始超时。
        local waiting = Q.queue
        Q.queue = {}
        for _, request in ipairs(waiting) do
            if request.singleQuery and request.priority ~= "background" then FinishSingle(request, "blocked", nil, reason)
            else ParkAdmission(request, reason) end
        end
        if HasWork() then Q:_SetPaused(true, reason) else Q:_StopLane() end
        return
    end
    if not HasWork() then Q:_StopLane(); return end
    if wasPaused then
        if Q.pending ~= nil then Q.pending.fallbackDeadlineAt = now + 12000 end
        Q.resumeAfter = now + Q.intervalMs
        Q:_SetPaused(false)
        return
    end
    if Q.lastNativeCallAt ~= nil and (now - Q.lastNativeCallAt) < Q.intervalMs then return end
    if Q.resumeAfter ~= nil and now < Q.resumeAfter then return end

    if Q.pending ~= nil then
        local pending = Q.pending
        -- 终态发布/恢复通知可能同步触发用户操作，
        -- 真正派发前再次验证；市场价与名称价一视同仁，不能从“直接 ID 报价”绕过保护。
        local stillAllowed, why = Q:CanNativeQuote()
        if stillAllowed ~= true then PauseFallback(pending, why); return end
        local grades = pending.grades or {}
        local grade = grades[tonumber(pending.gradeIndex) or 1] or pending.itemGrade
        if pending.marketPriceState == "ask_queued" then
            if grade == nil then Q:_FailPending("unavailable", "没有可探测的品质档位"); return end
            Q.lastNativeCallAt = NowMs()
            local started = Q.lastNativeCallAt
            local ok, value, err, b, c, d = S.Api:CallCapability("X2Auction:AskMarketPrice", nil, "AskMarketPrice", pending.itemType, grade, false)
            Q.stats.nativeLastMs = math.max(0, NowMs() - started)
            Q.stats.nativeMaxMs = math.max(Q.stats.nativeMaxMs, Q.stats.nativeLastMs)
            Q.stats.marketPriceAsks = (tonumber(Q.stats.marketPriceAsks) or 0) + 1
            Q.lastMarketAsk = {
                itemType = pending.itemType, itemGrade = grade, ok = ok == true,
                shape = ShapeOf(value) .. ", " .. ShapeOf(b) .. ", " .. ShapeOf(c) .. ", " .. ShapeOf(d),
                error = ok == true and nil or tostring(err or "unknown"), at = NowMs(),
            }
            if ok ~= true or value == false then
                pending.marketError = tostring(err or "AskMarketPrice rejected")
                Q.lastMarketAsk.ok, Q.lastMarketAsk.error = false, pending.marketError
                Q.stats.marketPriceAskFailures = (tonumber(Q.stats.marketPriceAskFailures) or 0) + 1
                -- Ask 失败不能污染整个服务；该 grade 退回既有名称搜索/下一 grade 降级链。
                AdvanceAfterUnreadableLowestPrice(pending, grades)
                return
            end
            pending.marketPriceState = "readback_queued"
            pending.marketPriceGrade = grade
            return
        elseif pending.marketPriceState == "readback_queued" then
            grade = tonumber(pending.marketPriceGrade) or grade
            local ok, price, err = ReadLowestPrice(pending, grade, "after_ask")
            if ok ~= true then
                -- 单独开启跑商时 getter 未就绪/被拒绝，不应绕过已存在的独立名称搜索降级链。
                -- 仍执行原 grade 上限、单 lane 节流、原生拍卖窗口所有权保护；不启动拍卖助手。
                pending.marketError = tostring(err or "报价读取失败")
                Q.stats.marketPriceReadFailures = (tonumber(Q.stats.marketPriceReadFailures) or 0) + 1
                AdvanceAfterUnreadableLowestPrice(pending, grades)
                return
            end
            if price ~= nil then
                pending.resolvedGrade = grade
                pending.marketPriceState = nil
                CompletePending("ready", { value = price, source = "market_price:" .. tostring(grade) }, nil, "direct")
                return
            end
            AdvanceAfterUnreadableLowestPrice(pending, grades)
            return
        elseif pending.fallbackState == "queued" then
            if NowMs() >= (tonumber(pending.fallbackDeadlineAt) or (NowMs() + 1)) then
                Q:_FailPending("unavailable", "名称搜索等待共享查询通道超时")
                return
            end
            local query = S.Services and S.Services.AuctionQueryV3 or nil
            local describe = type(query) == "table" and type(query.Describe) == "function" and query:Describe() or nil
            if type(describe) == "table" and describe.pending == true then
                return -- 共享无 token AuctionQuery 忙碌，下次有节奏轮转重试本地准入。
            end
            Q.lastNativeCallAt = NowMs()
            local ok, err = BeginSearchFallback(pending)
            if ok ~= true then
                if PAUSE_REASONS[err] ~= nil then
                    PauseFallback(pending, err)
                    return
                end
                Q:_FailPending("unavailable", "名称搜索启动失败：" .. tostring(err or "unknown"))
            end
            return
        elseif pending.fallbackState == "searching" then
            Q:_CheckFallback()
            if not HasWork() then Q:_StopLane() end
        end
        return
    end

    local request = table.remove(Q.queue, 1)
    if request == nil then
        if not HasWork() then Q:_StopLane() end
        return
    end
    if S.Api == nil or type(S.Api.CallCapability) ~= "function" then
        Q.pending = request
        Q.lastRawReturn = "capability_boundary_unavailable"
        Q:_FailPending("capability_unavailable", "报价能力边界不可用")
        return
    end
    Q.pending = request
    if request.started ~= true then Q.stats.attempts = Q.stats.attempts + 1; request.started = true end
    Q.quoteStateByItemType[request.itemType] = {
        status = "inflight", itemGrade = request.itemGrade, requester = request.requester, at = NowMs(),
    }
    if request.singleQuery == true then StartSingle(request); return end
    local grades = request.grades or {}
    local grade = grades[tonumber(request.gradeIndex) or 1] or request.itemGrade
    if grade == nil then
        Q:_FailPending("unavailable", "没有可探测的品质档位")
        return
    end
    -- 显式行重验不能以 GetLowestPrice 的旧 Native 快照或 TTL 命中宣告刷新。
    -- 只消费本次受归属保护的名称搜索一口价，普通后台路径保留原 Ask/Read 协议。
    if request.requireListing == true or request.fallbackState == "queued" then
        request.marketPriceState, request.marketPriceGrade = nil, nil
        QueueFallbackStart(request)
        return
    end
    -- 先 Ask，再在下一 paced turn GetLowestPrice。askMarketPriceUi=false 保持纯数据查询，不弹原生市场价 UI。
    request.marketPriceState = "ask_queued"
    request.marketPriceGrade = grade
end

function Q:_FailPending(status, err)
    local pending = Q.pending
    if type(pending) ~= "table" then return end
    -- CompletePending 读取并独占清除 Q.pending；此处不能先清，否则其见 nil 会静默丢失失败快照。
    CompletePending(status, nil, err)
end

function Q:_StartLane()
    if Q.running == true then return true end
    if S.Scheduler == nil or type(S.Scheduler.AddTask) ~= "function" then return false, "报价调度不可用" end
    local added = S.Scheduler:AddTask(Q.taskName, Q.intervalMs, function() Drain() end, false, Q.owner, "P2", 1)
    if added == true then Q.running = true; return true end
    return false, "报价调度注册失败"
end

function Q:_StopLane()
    if Q.running == true and S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(Q.taskName) end
    Q.running = false
    Q.resumeAfter = nil
    Q:_SetPaused(false)
end

function Q:_Enqueue(requester, itemType, itemGrade, callback, grades, searchName, requestKey, priority, requireListing)
    local function Share(request)
        if request and request.requestKey==requestKey then
            request.watchers=request.watchers or {}
            request.watchers[requester]={callback=callback}
            -- 同 itemType/grade 共用一个请求，searchName 不参与身份；后加入 watcher 可补缺名称，不能改稳定键。
            if (request.searchName==nil or request.searchName=="") and searchName~=nil and searchName~="" then request.searchName=searchName end
            if requireListing == true and request.requireListing ~= true then
                request.requireListing = true
                if request.fallbackState ~= "searching" then
                    request.marketPriceState, request.marketPriceGrade = nil, nil
                    request.fallbackState, request.fallbackDeadlineAt = "queued", NowMs() + 12000
                end
            end
            if priority == "user" then request.priority = "user" end
            self.stats.merged=self.stats.merged+1
            return true
        end
    end
    if Share(self.pending) then return true,"shared" end
    for _, request in ipairs(self.admissionWaiting) do
        if Share(request) then return true, "shared_waiting" end
    end
    for index, request in ipairs(self.queue) do
        local oldPriority = request.priority
        if Share(request) then
            -- 用户意图可加入先前作为低优先级 SWR 准入的请求；将排队项提到剩余后台前，不触碰当前 Native pending。
            if tostring(priority or "normal") == "user" and tostring(oldPriority or "normal") == "background" then
                request.priority = "user"
                table.remove(self.queue, index)
                local insertAt = #self.queue + 1
                for i = 1, #self.queue do if tostring(self.queue[i].priority or "normal") == "background" then insertAt = i; break end end
                table.insert(self.queue, insertAt, request)
            end
            return true,"shared"
        end
    end
    local request = {
        requester = requester, itemType = itemType, itemGrade = itemGrade,
        callback = callback, requestedAt = NowMs(), requestKey=requestKey,
        watchers = {[requester]={callback=callback}},
        grades = type(grades) == "table" and #grades > 0 and grades or nil,
        gradeIndex = 1,
        searchName = searchName, fallbackState = nil, fallbackAttempts = 0,
        marketPriceState = nil, marketPriceGrade = nil,
        priority = tostring(priority or "normal"), requireListing = requireListing == true,
    }
    if #Q.queue + #Q.admissionWaiting + (Q.pending ~= nil and 1 or 0) >= Q.maxQueue then return false, "报价队列已满，请稍后再试" end
    -- 用户显式询价排在尚未开始的后台 SWR 前；当前 Native 请求无 request-id，不能抢占。
    if request.priority == "user" then
        local inserted = false
        for index = 1, #Q.queue do
            if tostring(Q.queue[index].priority or "normal") == "background" then
                table.insert(Q.queue, index, request); inserted = true; break
            end
        end
        if not inserted then Q.queue[#Q.queue + 1] = request end
    else
        Q.queue[#Q.queue + 1] = request
    end
    -- 无 drain 所有者不能报告请求成功；Scheduler 登记失败必须回滚 enqueue，不能遗留虚假请求。
    local started, startErr = Q:_StartLane()
    if started ~= true then
        for index = #Q.queue, 1, -1 do if Q.queue[index] == request then table.remove(Q.queue, index); break end end
        return false, startErr
    end
    return true
end

local function YieldUnsentBackground(priority)
    local pending = Q.pending
    if priority == "user" and pending and pending.priority == "background"
        and pending.fallbackState ~= "searching" and pending.marketPriceState ~= "readback_queued" then
        Q.pending = nil; InsertByPriority(Q.queue, pending)
    end
end

-- strict 身份与 legacy grade ladder 隔离，绝不加入更弱的 Ask/Get/名称回退请求。
function Q:_RequestSingle(requester, itemType, itemGrade, callback, options)
    local now = NowMs()
    local priority = options.priority == "background" and "background" or "user"
    local deadline = tonumber(options.deadlineAt)
    if deadline == nil or deadline ~= deadline or deadline == math.huge then deadline = now + 5000 end
    -- 默认消费者仍总计五秒；仅明确请求分阶段计时的材料操作允许有界本地排队。
    local waitForDispatch = options.waitForDispatch == true and priority == "user"
    if not waitForDispatch then deadline = math.min(now + 5000, deadline)
    else
        -- 有界契约不能依赖调用者传入任意巨大数字：最多共享容量个旧隔离槽及一次响应预算。
        local query=S.Services and S.Services.AuctionQueryV3
        local waitCap=5000+(self.maxQueue+1)*((query and tonumber(query.timeoutMs) or 8000)+self.intervalMs)
        deadline=math.min(deadline,now+waitCap)
    end
    local key = "single:" .. tostring(itemType) .. ":" .. tostring(itemGrade)
    local watcher = { callback = callback }
    local request
    if self.pending and self.pending.requestKey == key then request = self.pending end
    if not request then for _, candidate in ipairs(self.queue) do if candidate.requestKey == key then request = candidate; break end end end
    if not request then for _, candidate in ipairs(self.admissionWaiting) do if candidate.requestKey == key then request = candidate; break end end end
    if not request and #self.queue + #self.admissionWaiting + (self.pending and 1 or 0) >= self.maxQueue then return false, "报价队列已满，请稍后再试" end
    self.singleQueryWatchers[requester] = watcher
    if request then
        request.watchers[requester] = watcher
        if priority == "user" then
            request.priority = "user"
            for i = #self.queue, 1, -1 do if self.queue[i] == request then table.remove(self.queue, i); InsertByPriority(self.queue, request); break end end
            for i = #self.admissionWaiting, 1, -1 do
                if self.admissionWaiting[i] == request then table.remove(self.admissionWaiting, i); InsertByPriority(self.queue, request); break end
            end
        end
        if request.searchName == "" then request.searchName = TrimToKeyword(options.searchName) end
        self.stats.merged = self.stats.merged + 1
        CachePut(self.snapshots, requester, { requester = requester, itemType = itemType, itemGrade = itemGrade,
            status = "queued", singleQuery = true, at = now })
        local allowed, reason = self:CanNativeQuote()
        if request.priority == "user" then
            if not allowed and (reason == "native_auction_visible" or reason == "native_auction_visibility_unknown") then
                FinishSingle(request, "blocked", nil, reason)
            elseif deadline <= now then FinishSingle(request, "timeout", nil, "quote_deadline")
            elseif (request.deferDeadline == true and not waitForDispatch) or deadline < request.deadlineAt then
                -- 共享不得延长先来的响应期限；默认五秒消费者仍可收紧等待中的请求。
                if not waitForDispatch then request.deferDeadline = false end
                if request.deferDeadline then request.queueDeadlineAt=deadline end
                if not ArmSingleDeadline(request, deadline) then FinishSingle(request, "unavailable", nil, "quote_deadline_unavailable") end
            end
        end
        if not request.finished and priority == "user" then YieldUnsentBackground(priority); Drain() end
        return true, "shared"
    end
    self.singleQuerySequence = self.singleQuerySequence + 1
    request = { requester = requester, itemType = itemType, itemGrade = itemGrade, requestedAt = now,
        singleQuery = true, requireListing = true, requestKey = key, deadlineAt = deadline,
        searchGeneration = self.singleQuerySequence, queryRequester = "price_quote_single:" .. tostring(self.singleQuerySequence),
        searchName = TrimToKeyword(options.searchName), priority = priority, deferDeadline = priority == "background" or waitForDispatch,
        queueDeadlineAt = waitForDispatch and deadline or nil,
        watchers = { [requester] = watcher }, deadlineTask = "v3_price_quote_single_deadline:" .. tostring(self.singleQuerySequence) }
    CachePut(self.snapshots, requester, { requester = requester, itemType = itemType, itemGrade = itemGrade,
        status = "queued", singleQuery = true, requestedAt = now, at = now })
    self.quoteStateByItemType[itemType] = { status = "queued", itemGrade = itemGrade, requester = requester, at = now }
    local allowed, reason = self:CanNativeQuote()
    if deadline <= now then FinishSingle(request, "timeout", nil, "quote_deadline"); return true, "timeout" end
    if not allowed and (reason == "native_auction_visible" or reason == "native_auction_visibility_unknown") then
        if priority == "background" then
            -- 只允许尚未发包的后台 SWR 等待关闭；unknown 沿既有45秒边界结束，用户请求不进入停车区。
            ParkAdmission(request, reason)
            local started, err = self:_StartLane()
            if not started then FinishSingle(request, "unavailable", nil, err) end
            return true, "waiting"
        end
        FinishSingle(request, "blocked", nil, reason); return true, "blocked"
    end
    if request.searchName == "" then FinishSingle(request, "unavailable", nil, "search_name_unavailable"); return true, "unavailable" end
    if priority ~= "background" and not ArmSingleDeadline(request, deadline) then
        FinishSingle(request, "unavailable", nil, "quote_deadline_unavailable"); return true, "unavailable"
    end
    -- 用户优先只让出尚未发出的后台协议步；已发搜索必须保持原归属直到结束/隔离期满。
    YieldUnsentBackground(request.priority)
    InsertByPriority(self.queue, request)
    local started, err = self:_StartLane()
    if not started then FinishSingle(request, "unavailable", nil, err); return true, "unavailable" end
    Drain() -- 第一项可立即发出；后继仍受同一 lastNativeCallAt 冷却约束。
    return true, "queued"
end

-- 持久参考价格修改全部通过 Persistence 事务，失败保存不能留下半写表，损坏或外来 Store 须隔离，不静默用默认值覆盖。
local MAX_REFERENCE_SAMPLES = 6
local function ReferenceKey(itemType, itemGrade)
    local id, grade = PositiveInt(itemType), tonumber(itemGrade)
    if id == nil then return nil end
    -- grade 属于身份；梯度按品质答复，未过滤 grade=0 不能覆盖特定品质记录。
    return tostring(id) .. ":" .. tostring(grade or -1)
end

local function NormalizeReferenceState(value, preserveLegacyFallback)
    local out = {}
    if type(value) ~= "table" then return out end
    local rows = type(value.entries) == "table" and value.entries or value
    local count = 0
    for key, entry in pairs(rows) do
        if count < 512 and type(key) == "string" and type(entry) == "table" then
            local price = tonumber(entry.price)
            local itemType = tonumber((key:gsub("^(-?%d+):.*$", "%1")))
            local grade = tonumber((key:gsub("^-?%d+:(-?%d+)$", "%1")))
            local source = tostring(entry.source or "auction")
            -- 18.312 及更早的 name_search_direct/name_search_bid 记录为整单总价，不能作为材料单价继续加载。
            -- 只丢弃这些已知错误来源，保留 GetLowestPrice 及新单位价格 fallback 历史证据，不清空整个参考价 Store。
            local poisonedLegacyFallback = source == "name_search_direct" or source == "name_search_bid" or source == "name_search"
            if (preserveLegacyFallback == true or not poisonedLegacyFallback) and price ~= nil and price == price and price > 0 and itemType ~= nil and grade ~= nil then
                local samples = {}
                if type(entry.samples) == "table" then
                    for index = 1, math.min(MAX_REFERENCE_SAMPLES, #entry.samples) do
                        local sample = tonumber(entry.samples[index])
                        if sample ~= nil and sample == sample and sample > 0 then
                            samples[#samples + 1] = math.floor(sample)
                        end
                    end
                end
                out[key] = {
                    itemType = math.floor(itemType), grade = grade,
                    price = math.floor(price),
                    updatedAt = math.max(0, math.floor(tonumber(entry.updatedAt) or 0)),
                    source = source,
                    samples = samples,
                }
                count = count + 1
            end
        end
    end
    return out
end

-- 旧 schema1 曾将整单价计入原章；历史投影只供精确验旧章，Apply 仍过滤已确认错误来源。
-- Core 命中原章后才可迁移，不能白名单放行任意 Hash。
local function RebuildLegacyReferenceCanonical(value,_,_,raw)
    local meta=type(raw)=="table" and raw.__rsmeta or nil
    if type(meta)~="table" or meta.store~=Q.StoreId or meta.owner~=Q.StoreId or tonumber(meta.schema)~=1
        or type(value)~="table" or tonumber(value.contractVersion)~=1 then return nil end
    return {entries=NormalizeReferenceState(value,true),contractVersion=1},
        {entries=NormalizeReferenceState(value),contractVersion=Q.StoreContractVersion}
end

function Q:_EnsureStoreRegistered()
    local P = S.Persistence
    if type(P) ~= "table" or type(P.RegisterV3Store) ~= "function" then return false, "persistence_unavailable" end
    if P:GetStore(Q.StoreId) ~= nil then return true end
    local store, err = P:RegisterV3Store({
        id = Q.StoreId,
        owner = "v3.trade_reference_prices",
        scope = P.Scope.Account,
        lifetime = P.Lifetime.Permanent,
        schemaVersion = 1,
        legacySchemaVersion = 0,
        key = (P.V3KeyPrefix or "") .. "trade_reference_prices",
        rebuildCanonicalForIntegrity = RebuildLegacyReferenceCanonical,
        budget = { maxDepth = 5, maxNodes = 4096, maxStringBytes = 16000, maxEntriesPerTable = 512 },
        default = function() return { entries = {}, contractVersion = Q.StoreContractVersion } end,
        get = function()
            local entries = {}
            for key, entry in pairs(Q.referencePrices or {}) do entries[key] = Copy(entry) end
            return { entries = entries, contractVersion = Q.StoreContractVersion }
        end,
        apply = function(value) Q.referencePrices = NormalizeReferenceState(value) end,
        migrate = function(value) return { entries = NormalizeReferenceState(value), contractVersion = Q.StoreContractVersion } end,
    })
    if store == nil then return false, tostring(err or "store_register_failed") end
    return true
end

-- 每会话只加载一次；失败保持内存空，但不清除或改写磁盘，用户历史保留。
function Q:EnsureStoreLoaded()
    if Q.storeLoaded == true then return true end
    local ok, regErr = Q:_EnsureStoreRegistered()
    if ok ~= true then return false, regErr end
    local P = S.Persistence
    if type(P.LoadStore) ~= "function" then return false, "load_unavailable" end
    local status, _, err = P:LoadStore(Q.StoreId)
    if status ~= true and status ~= "empty" then return false, tostring(err or status or "store_load_failed") end
    local stored = P.GetStore and P:GetStore(Q.StoreId) or nil
    if type(stored) == "table" and type(stored.value) == "table" then
        Q.referencePrices = NormalizeReferenceState(stored.value.entries or stored.value)
    end
    Q.storeLoaded = true
    return true
end

function Q:_MarkDirty()
    local P = S.Persistence
    if P ~= nil and type(P.MarkDirty) == "function" then
        -- 合并写入：多种材料可能在同一秒内完成。
        P:MarkDirty(Q.StoreId, 1200, "reference_price_update")
        return true
    end
    return false
end

-- 记录已确认报价；稳定 ID 直接结果可持久化，名称搜索 bid 只是不同挂单估计，不能洗成长期事实。
function Q:RecordReferencePrice(itemType, itemGrade, price, source)
    source = tostring(source or "auction")
    -- 长期单价由 MaterialPriceServiceV3 保存，Queue 管串行与回调；旧 reference Store 留作迁移来源。
    -- 缺新服务时保留 legacy fallback，避免混装直接使 Queue 失效。
    local materialPrices = S.Services and S.Services.MaterialPriceServiceV3 or nil
    if type(materialPrices) == "table" and type(materialPrices.ObserveConfirmedPrice) == "function" then
        return materialPrices:ObserveConfirmedPrice(itemType, itemGrade, price, source)
    end
    -- 仅已按数量归一化的 direct fallback 可进入长期参考；bid 仍非最终估计，明确拒绝旧未归一化 name_search_* 来源。
    if source == "name_search_bid_unit" or (source:find("^name_search") ~= nil
        and source ~= "name_search_direct_unit" and source ~= "name_search_min_direct_unit"
        and source ~= "name_search_sampled_direct_unit" and source ~= "name_search_sampled_lower_unit") then
        return false, "estimate_or_legacy_fallback_not_persisted"
    end
    local key = ReferenceKey(itemType, itemGrade)
    local money = tonumber(price)
    if key == nil or money == nil or money ~= money or money <= 0 then return false end
    if Q:EnsureStoreLoaded() ~= true then return false, "store_unavailable" end
    local previous = Q.referencePrices[key]
    local entry = {
        itemType = math.floor(PositiveInt(itemType)),
        grade = tonumber((key:gsub("^-?%d+:(-?%d+)$", "%1"))),
        price = math.floor(money),
        updatedAt = NowMs(),
        source = source,
        samples = {},
    }
    if type(previous) == "table" and type(previous.samples) == "table" then
        -- 历史最新优先且有界，保留足够相邻上下文识别操纵性低异常，不永久增长。
        entry.samples[1] = math.floor(previous.price or 0)
        for index = 1, math.min(MAX_REFERENCE_SAMPLES - 1, #previous.samples) do
            local sample = tonumber(previous.samples[index])
            if sample ~= nil and sample > 0 then entry.samples[#entry.samples + 1] = math.floor(sample) end
        end
    end
    Q.referencePrices[key] = entry
    Q:_MarkDirty()
    return true
end

-- 没有实时报价前读取最后已知成本，同时返回年龄与来源，供调用者标成参考而非当前市场价。
function Q:GetReferencePrice(itemType, itemGrade)
    local materialPrices = S.Services and S.Services.MaterialPriceServiceV3 or nil
    if type(materialPrices) == "table" and type(materialPrices.GetPrice) == "function" then
        local price, meta = materialPrices:GetPrice(itemType, itemGrade)
        if price ~= nil then
            return price, {
                updatedAt = meta and meta.observedMinute or nil, grade = itemGrade, source = meta and meta.source or "material_price_service",
                freshness = meta and meta.freshness or "unknown", ageMinutes = meta and meta.ageMinutes or nil,
                samples = Copy(meta and meta.samples or {}),
            }
        end
    end
    if Q.storeLoaded ~= true then return nil end
    local entry = Q.referencePrices[ReferenceKey(itemType, itemGrade)]
    if type(entry) ~= "table" then return nil end
    return entry.price, {
        updatedAt = entry.updatedAt, grade = entry.grade, source = entry.source,
        samples = Copy(entry.samples or {}),
    }
end

-- 一次接收一材料，callback 每请求完成一次；缓存命中可同步回调，调用前先建批次状态。
-- gradeCandidates 为有序 0..20，最多 8 项，单品质 nil 可继续；options.searchName 允许梯度耗尽后名称兜底。
-- singleQuery=true 只做一次精确 ID/grade 的 buyout 搜索，不走 Ask/Get/梯度/重试。前台最多五秒，后台准入后五秒，取消仍保留 Native 隔离。
function Q:RequestQuote(requester, itemType, itemGrade, callback, gradeCandidates, options)
    requester = tostring(requester or "")
    itemType = PositiveInt(itemType)
    if requester == "" then return false, "报价来源不能为空" end
    if itemType == nil then return false, "物品类型无效" end
    itemGrade = tonumber(itemGrade)
    if itemGrade==nil or itemGrade~=math.floor(itemGrade) or itemGrade<0 or itemGrade>20 then itemGrade=1 end
    options = type(options) == "table" and options or {}
    if options.singleQuery == true then return self:_RequestSingle(requester, itemType, itemGrade, callback, options) end
    local searchName = TrimToKeyword(options.searchName)
    local grades = {}
    local seenGrades = {}
    local function AddGrade(value)
        local n = tonumber(value)
        if n == nil or n ~= n or n < 0 or n > 20 or n ~= math.floor(n) or seenGrades[n] then return end
        seenGrades[n] = true
        grades[#grades + 1] = math.floor(n)
    end
    if type(gradeCandidates) == "table" then
        for _, candidate in ipairs(gradeCandidates) do
            AddGrade(candidate)
            if #grades >= 8 then break end
        end
    end
    if #grades == 0 then
        AddGrade(itemGrade)
    end
    local parts={};for _,grade in ipairs(grades) do parts[#parts+1]=tostring(grade) end
    -- requestKey 只含 itemType+grade 梯度；本地化显示名不能让同材料重复查询。
    local requestKey=tostring(itemType)..":"..table.concat(parts,",")
    -- 显式force只跳过缓存，仍遵守串行/去重。正常点击不反复查询刚完成/刚失败的材料。
    if options.force ~= true and options.requireListing ~= true and not HasCurrentListingRequest(requestKey) then
        local price,at=Q:PeekCached(itemType,grades[1])
        if price~=nil then
            self.stats.cacheHits=self.stats.cacheHits+1
            Deliver(requester,callback,{status="ready",price=price,itemType=itemType,itemGrade=grades[1],cached=true,
                completedAt=at,at=NowMs(),priceSource="cached"});Publish(itemType,grades[1],"ready","cached");return true,"cached"
        end
        local negative=self.negativeCache[requestKey]
        if negative and NowMs()-negative.at>=0 and NowMs()-negative.at<self.negativeTtlMs then
            self.stats.cacheHits=self.stats.cacheHits+1;local snap=Copy(negative.snapshot);snap.cached=true
            Deliver(requester,callback,snap);Publish(itemType,grades[1],tostring(snap.status or "failed"),"cached_negative");return true,"cached_negative"
        end
    end
    local ok, err = Q:_Enqueue(requester, itemType, itemGrade, callback, grades, searchName, requestKey, options.priority, options.requireListing)
    if ok ~= true then return ok, err end
    -- 把 requester 标为 queued，让投影显示真实等待而非旧价。
    Q.snapshots[requester] = {
        requester = requester, itemType = itemType, itemGrade = itemGrade,
        status = "queued", price = nil, error = nil, requestedAt = NowMs(),
        contract = "显式+异步报价；等待串行限速队列处理",
    }
    -- 新显式请求取代 itemType 之前生命周期，包括 ready，因为用户要求重新报价。
    Q.quoteStateByItemType[itemType] = {
        status = "queued", itemGrade = itemGrade, requester = requester, at = NowMs(),
    }
    return true, err or "queued"
end

-- 取消权限是精确requester，不按item清缓存，也不取消其它模块的同项请求。
-- 已发出的同步调用不能撤回；名称搜索保留占位到其结束/超时，避免晚到无token事件误配下次请求。
function Q:CancelRequester(requester)
    requester=tostring(requester or "")
    self.singleQueryWatchers[requester] = nil
    local removed=0
    for i=#self.admissionWaiting,1,-1 do
        local request=self.admissionWaiting[i]
        if request.watchers and request.watchers[requester] then request.watchers[requester]=nil;removed=removed+1 end
        if not next(request.watchers or {}) then
            if request.singleQuery then FinishSingle(request, "cancelled", nil, "requesters_released")
            else table.remove(self.admissionWaiting,i) end
            self.quoteStateByItemType[request.itemType]={status="cancelled",itemGrade=request.itemGrade,at=NowMs()}
        end
    end
    for i=#self.queue,1,-1 do
        local r=self.queue[i]
        if r.watchers and r.watchers[requester] then r.watchers[requester]=nil;removed=removed+1 end
        if not next(r.watchers or {}) then
            if r.singleQuery then FinishSingle(r, "cancelled", nil, "requesters_released")
            else table.remove(self.queue,i) end
            self.quoteStateByItemType[r.itemType]={status="cancelled",itemGrade=r.itemGrade,at=NowMs()}
        end
    end
    local r=self.pending
    if r and r.watchers and r.watchers[requester] then
        r.watchers[requester]=nil;removed=removed+1
        if not next(r.watchers) and r.singleQuery then
            FinishSingle(r, "cancelled", nil, "requesters_released")
        elseif not next(r.watchers) and r.fallbackState~="searching" then
            -- 末 watcher 取消且请求丢弃时，同步把 queued/inflight 标成 cancelled，避免界面永久询价中。
            -- 仍在 searching 的无 token 请求须占位到完成/超时，不能为更新 UI 提前复用 lane。
            self.quoteStateByItemType[r.itemType]={
                status="cancelled",itemGrade=r.itemGrade,requester=requester,at=NowMs(),
            }
            self.pending=nil
        end
    end
    self.stats.cancelled=self.stats.cancelled+removed
    self.snapshots[requester]={status="cancelled",requester=requester,at=NowMs()}
    if not HasWork() then self:_StopLane() end
    return true,removed
end

function Q:GetSnapshot(requester)
    requester = tostring(requester or "")
    return Copy(Q.snapshots[requester] or { requester = requester, status = "idle", price = nil, error = nil })
end

-- 共享读模型按 itemType/可选 itemGrade 返回单价；尚无完成报价时返回 nil 而非 0，保留真实等待状态。
function Q:GetPriceByItemType(itemType, itemGrade)
    itemType = PositiveInt(itemType)
    if itemType == nil then return nil end
    -- 先用会话新鲜价，否则返回已知参考价及来源，无需等搜索才显示。
    local entry = Q.pricesByItemType[itemType]
    if type(entry) ~= "table" then
        local reference, meta = Q:GetReferencePrice(itemType, itemGrade)
        if reference ~= nil then return reference, "reference:" .. tostring(meta and meta.source or "stored"), meta and meta.updatedAt or nil end
        return nil
    end
    -- grade 是软过滤：官方 GetLowestPrice(itemType,itemGrade) 区分品质，但调用者省略 grade 时仍返回该
    -- itemType 最后已知单价。
    if itemGrade ~= nil and entry.itemGrade ~= nil and tonumber(entry.itemGrade) ~= tonumber(itemGrade) then
        return nil
    end
    return entry.price, entry.source, entry.completedAt
end

-- 投影被动读取会话缓存，不发原生调用、不延长新鲜度；普通 Refresh 在仅 UI 重载后复用，避免再次消耗冷却查询。
-- 普通显式点击也复用，force 为显式覆盖。
function Q:PeekCached(itemType, itemGrade)
    itemType = PositiveInt(itemType)
    local grade = tonumber(itemGrade)
    if itemType == nil or grade == nil then return nil end
    local entry = Q.cache[tostring(itemType) .. ":" .. tostring(grade)]
    if type(entry) ~= "table" then return nil end
    local at = tonumber(entry.at) or 0
    if NowMs() - at < 0 or NowMs() - at > Q.cacheTtlMs then
        Q.cache[tostring(itemType) .. ":" .. tostring(grade)] = nil
        return nil
    end
    return tonumber(entry.price), at
end

-- 投影唯一入口返回 price、live/reference 来源及保存年龄，页面须诚实标注；参考值绝不能当实时报价显示。
function Q:GetPriceWithProvenance(itemType, itemGrade)
    itemType = PositiveInt(itemType)
    if itemType == nil then return nil, "none" end
    local fresh = Q.pricesByItemType[itemType]
    if type(fresh) == "table" and fresh.price ~= nil and (itemGrade==nil or tonumber(fresh.itemGrade)==tonumber(itemGrade)) then
        local age=NowMs()-(tonumber(fresh.completedAt) or 0)
        local fromNameSearch = tostring(fresh.source or ""):find("^name_search_") ~= nil
        local kind=(age>=0 and age<=self.cacheTtlMs and not fromNameSearch) and "live" or "reference"
        return tonumber(fresh.price), kind, { source = fresh.source, at = fresh.completedAt, grade = fresh.itemGrade }
    end
    local reference, meta = Q:GetReferencePrice(itemType, itemGrade)
    if reference ~= nil then return reference, "reference", meta end
    return nil, "none"
end

-- 只返回本会话实际请求过且品质匹配的生命周期；没有就 nil，不能借其它品质状态。
function Q:GetQuoteStateByItemType(itemType, itemGrade)
    itemType = PositiveInt(itemType)
    if itemType == nil then return nil end
    local entry = Q.quoteStateByItemType[itemType]
    if type(entry) ~= "table" then return nil end
    if itemGrade ~= nil and entry.itemGrade ~= nil and tonumber(entry.itemGrade) ~= tonumber(itemGrade) then
        return nil
    end
    return Copy(entry)
end

function Q:Describe()
    local priced = 0
    for _ in pairs(self.pricesByItemType or {}) do priced = priced + 1 end
    local recent = {}
    for index, record in ipairs(self.recent or {}) do
        if index > self.recentMax then break end
        recent[#recent + 1] = Copy(record)
    end
    return {
        version = self.version, patch=self.budgetPatch, running = self.running == true,
        priceSafetyPatch = self.priceSafetyPatch, requotePatch = self.requotePatch,
        nativeInteractionPatch = self.nativeInteractionPatch,
        nativeInteractionContractVersion = self.NativeInteractionContractVersion,
        nativeAdmission = Copy(self.nativeAdmission),
        admissionWaiting = #self.admissionWaiting, unknownAdmissionWaitMs = self.unknownAdmissionWaitMs,
        activity = self:GetActivitySnapshot(),
        pending = self.pending ~= nil, queueLength = #self.queue,
        maxQueue = self.maxQueue, intervalMs = self.intervalMs,
        pricedItemTypes = priced,
        stats = Copy(self.stats),
        recent = recent,
        lastRawReturn = self.lastRawReturn,
        lastFallbackMatch = self.lastFallbackMatch and Copy(self.lastFallbackMatch) or nil,
        lastMarketAsk = self.lastMarketAsk and Copy(self.lastMarketAsk) or nil,
        pendingDetail = type(self.pending) == "table" and {
            -- 只读当前阶段，诊断生成不启动/续期 deadline，也不发补查。
            requestedAt=self.pending.requestedAt, dispatchedAt=self.pending.dispatchedAt,
            deadlineAt=self.pending.deadlineAt, queueDeadlineAt=self.pending.queueDeadlineAt,
            deadlinePhase=self.pending.deferDeadline and 'queue_wait' or 'response_or_default',
            itemType = self.pending.itemType, itemGrade = self.pending.itemGrade, gradeIndex = self.pending.gradeIndex,
            searchName = self.pending.searchName, fallbackState = self.pending.fallbackState, priority = self.pending.priority,
            marketPriceState = self.pending.marketPriceState, marketPriceGrade = self.pending.marketPriceGrade,
            requestedAt = self.pending.requestedAt, marketError = self.pending.marketError,
            requireListing = self.pending.requireListing == true, heldObservations = self.pending.heldObservations,
            verifying = self.pending.verifying == true,
        } or nil,
        lastCompleted = self.lastCompleted and Copy(self.lastCompleted) or nil,
        protocolProbe = {
            done = ProbeState.done == true,
            attempts = ProbeState.attempts,
            results = Copy(ProbeState.results),
        },
    }
end

-- 诊断别名维持共享服务 GetHealth 契约，不重复 Describe 投影。
function Q:GetHealth()
    return self:Describe()
end

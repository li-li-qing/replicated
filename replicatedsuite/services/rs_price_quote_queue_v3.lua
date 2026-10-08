------------------------------------------------------------------------
-- Replicated Suite - Price Quote Queue V3
--
-- Shared explicit, rate-limited authority for X2Auction:GetLowestPrice.
--
-- GetLowestPrice is a cooldown-bound server query (Cooldown=500ms, Risk
-- "server_query"). Trade / CraftAssist / AuctionFavorites all need lowest-price
-- quotes for their materials, but a craft graph or route can contain many
-- itemType rows: fanning out one native call per row from an ordinary Refresh
-- would both violate the official cooldown contract and spam the server.
--
-- This service owns the *serialization* and *pacing* of quote requests:
--
--   * Feature modules call RequestQuote(...) with an explicit requester token,
--     itemType/itemGrade, and an optional completion callback. They NEVER call
--     X2Auction:GetLowestPrice directly.
--   * Requests are queued and drained one at a time by a single scheduler lane,
--     spaced at >= the official cooldown so every call observes a clean window.
--   * Each completion is delivered asynchronously through the internal event bus
--     (topic "v3.price_quote.completed") and, if supplied, the per-request
--     callback. This is the "explicit + async callback" quote semantics.
--   * A requester-scoped snapshot preserves the last result so a projection can
--     re-read it without re-issuing a server query.
--   * Everything fails closed: an unknown identity, a blocked capability, a
--     throttled call, or an unreadable native return yields a status, never a
--     fabricated price.
------------------------------------------------------------------------
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
    EventPayloadContractVersion = 1, -- 18.315: completion event carries itemType/itemGrade/status/reason for bounded projection sync.
    RequestIdentityDedupContractVersion = 1, -- 18.316: stable itemType+grade ladder is request identity; localized searchName is fallback metadata only.
    MaterialPriceAuthorityContractVersion = 1, -- 18.317: durable material price ownership moves to MaterialPriceServiceV3; this queue remains Native serialization Authority.
    PriorityQueueContractVersion = 1, -- 18.317: explicit user quote jobs insert ahead of background SWR requests without preempting the active Native call.
    FallbackIdentityMatchContractVersion = 1,
    MarketPriceHandshakeContractVersion = 1,
    PriceSafetyContractVersion = 1,
    RequoteContractVersion = 2,
    SingleQueryContractVersion = 1,
    singleQuerySequence = 0, singleQueryWatchers = {},
    requotePatch = "trade-requote-2",
    -- 维护（trade-requote-2）：准入等待不是 Native 在途。最多64项共享容量、单一既有1s lane；
    -- unknown 最多宽限45s后明确 blocked，已确认玩家打开拍卖行仍等待关闭，不抢结果。
    admissionWaiting = {},
    unknownAdmissionWaitMs = 45000,
    maxListingObservations = 2,
    priceSafetyPatch = "trade-quote-price-safety-1",
    -- 中文维护注释（2026-09-25，trade-fallback-unit-price-1）：名称搜索 fallback 只能消费
    -- AuctionQueryV3 已按 listing quantity 归一后的单价；禁止把整单 directPrice/bidPrice 作为 unit cost。
    -- 同 itemType 多条结果按最低“可立即购买单价”选择，数量缺失则 fail-closed。
    FallbackUnitPriceContractVersion = 1,
    presentationBoundary = "service_only",
    Topic = "v3.price_quote.completed",
    -- Single pending native call. GetLowestPrice is synchronous, but pacing and
    -- delivery are asynchronous: one in-flight request at a time.
    pending = nil,
    queue = {},
    snapshots = {},
    -- itemType -> latest quote lifecycle state ("queued"/"inflight"/"ready"/"failed").
    -- Shared honest-state read model: Trade/Craft/Auction projections render
    -- 排队/查询中/已报价/失败 from here instead of guessing from a missing price.
    -- Fail-closed: a failed completion never resurrects or clears a good price.
    quoteStateByItemType = {},
    -- Bounded single record of the most recent completion (any status), for the
    -- diagnostics copyable line. Not a second Authority; snapshots stay the
    -- requester-scoped read model.
    lastCompleted = nil,
    -- itemType -> latest completed quote (this session). Cross-feature read model:
    -- any Feature (Trade/CraftAssist/AuctionFavorites) can resolve a material's
    -- unit cost by itemType+itemGrade without knowing which requester issued the
    -- quote, and without re-issuing a server query.
    pricesByItemType = {},
    -- ------------------------------------------------------------------
    -- Long-lived reference price table (user-requested design, .18.180).
    --
    -- A fresh auction search is slow (one paced native call per grade per
    -- material), so making the player wait on every session was wrong. Every
    -- price we ever confirm is now persisted and replayed immediately: a row
    -- shows its last known cost at once, and the live quote replaces it when
    -- the background search finishes.
    --
    -- 18.317 note: this table is legacy migration input only. Durable age/freshness
    -- policy moved to MaterialPriceServiceV3 because NowMs cannot represent
    -- multi-day age across addon reloads. Old values remain readable for upgrade.
    --   * Per itemType+grade, not per itemType, because the ladder already tells
    --     us which grade answered.
    --   * History is kept (bounded) so a suspiciously low sample can be judged
    --     against its neighbours later.
    --   * The store is per-account runtime data. It is never shipped with the
    --     addon package: each player builds their own observations.
    -- ------------------------------------------------------------------
    StoreId = "v3.trade_reference_prices",
    -- Contract 2 invalidates legacy name_search_direct samples created before listing-total/unit-price
    -- semantics were fixed. Store schema is unchanged; this is a semantic migration of cached evidence only.
    StoreContractVersion = 2,
    referencePrices = {},          -- "itemType:grade" -> { price, updatedAt, samples }
    storeLoaded = false,
    persistPending = false,
    -- Session price cache keyed by "itemType:grade" (legacy-verified TTL model).
    -- Maintenance trade-budget-1: explicit normal clicks also reuse a fresh
    -- quote; options.force is the opt-in refresh override. Negative outcomes
    -- carry a separate 30s strategy-specific backoff, never a fabricated price.
    cache = {},
    cacheTtlMs = 120000,
    owner = {},
    -- Spacing between drained requests. Must be >= the 500ms official cooldown
    -- so the capability gate never rejects the next call mid-batch.
    -- 维护（trade-budget-1）：用户一次询价可能展开多品质/协议探针；服务拥有节奏，
    -- 正常请求不探针、不隐式扩展。保持>=API的500ms门，默认1000ms，单次同步调用仍不可拆帧。
    intervalMs = 1000,
    -- Real spacing is enforced against the monotonic clock, not the scheduler's
    -- tick count: a budget-deferred tick makes two adjacent drains land far
    -- closer together than intervalMs, which tripped the official 500 ms gate and
    -- produced "cooldown active: NNNms remaining" quote failures on RU.
    lastNativeCallAt = nil,
    maxQueue = 64,
    taskName = "v3_price_quote_drain",
    running = false,
    -- Debugging observability (.18.168): many RU quotes fail closed; these
    -- bounded records expose WHY without touching the read-model contracts.
    stats = { attempts = 0, ready = 0, failed = 0, merged = 0, cacheHits = 0,
        cancelled = 0, nativeLastMs = 0, nativeMaxMs = 0, fallbackMatches = 0,
        marketPriceAsks = 0, marketPriceAskFailures = 0 },
    negativeCache = {}, negativeTtlMs = 30000, cacheMax = 512,
    budgetPatch = "trade-budget-1",
    recent = {},        -- newest-first ring of the last completions
    recentMax = 12,
    lastRawReturn = nil, -- bounded shape of the most recent native return
    -- 维护（2026-09-24，quote-fallback-identity-match-1）：名称搜索本身仍只发一次服务器请求；
    -- 但读取最多 20 条 detached 结果用于本地 stable itemType/精确名称匹配，避免 fuzzy search 首条并非目标时误判。
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

-- 维护（2026-09-30，auction-user-priority-1）：暂停不属于报价终态，必须使用独立 topic。
-- price_quote.completed 会驱动 Trade 的 RowJob 完成计数，禁止用它发送 paused/resumed。
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
-- 维护（trade-requote-2）：只让出尚未占用原生搜索通道的本地请求。已发包的无令牌响应
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
-- 维护（2026-10-01，auction-full-lane-safety-1）：保护覆盖整个 Ask/Read/Search 协议，
-- 不是只有名称 fallback。诊断已证实 unknown 时前半段仍反复 Ask；false UI 参数不证明无共享占用。
-- 只在现有需求 lane/显式探针边沿采样；缺 Authority 或读失败均不允许发送原生询价。
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
    -- 维护（auction-full-lane-safety-1）：只有正在让出无 token 在途查询的 pending 需保留隔离。
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
    -- 维护（auction-full-lane-safety-1）：玩家介入 Ask 与 Read 之间后，不接受共享 Native 旧快照。
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

-- Normalize a native GetLowestPrice return into a bounded, honest quote. The RU
-- client may return a number, a string, or a table whose exact field layout is
-- not yet proven on the live client, so we accept several conservative shapes
-- and never invent a price when none is readable.
-- Legacy-verified money coercion (rs_auction_service ToNumber): RU price values
-- may arrive as comma-grouped strings ("1,234,567") or gold/silver/copper
-- composite tables; bare tonumber() silently yields nil for both and would
-- misclassify a real listing as "no listing". Every price extraction path uses
-- this, never raw tonumber(). Declared before all users; assigned to the local
-- name after definition so the table-recursion branch resolves correctly.
local function ToMoney(value, depth)
    -- 维护（2026-09-30，trade-quote-price-safety-1）：GetLowestPrice 的“单价”不得从
    -- listing 总价/数量/bidPrice 猜测。带堆叠或挂单字段的未验证对象交给既有名称搜索，
    -- 由 AuctionQuery 在同一结果中确认数量与总价；只保留已支持的标量/币值/显式价格包装。
    -- 有界递归避免异常自引用返回让共享报价 lane 栈溢出，最大4层，不追加 Native 探针。
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

-- Bound a user/legacy display name into a safe auction search keyword. The
-- native SearchAuctionArticle keyword shares the same bounded contract as
-- AuctionQueryV3: 1-64 visible characters, no control characters.
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

-- Bounded, type-faithful descriptor of a raw native return. This is the probe
-- that answers "what does GetLowestPrice actually return on RU" without
-- dumping unbounded payloads into diagnostics.
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


-- The lowest listing grade often differs from the static hint, and nil at one
-- grade is a VALID answer ("no listing at that grade"), not an error. The
-- verified legacy protocol probes a bounded grade ladder per material and scans
-- every return slot for the price (it is not always the first return value).
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
        -- 维护（2026-09-25，price-quote-event-payload-1）：完成事件必须携带稳定物品身份。
        -- 旧 Topic 只有“有报价变化”这一事实，Trade 若要自愈迟到/共享请求只能全表扫描；更严重的是
        -- requester callback 被取消/换代后，Feature 完全不知道哪个 quoteState 已从 inflight 进入终态。
        -- itemType/itemGrade 只来自本 Authority 的 pending/request，不接受 UI 名称推断；旧监听器忽略额外参数仍兼容。
        S.Events:Publish(Q.Topic, itemType, itemGrade, status, reason)
    end
end

-- ---------------------------------------------------------------------
-- Bounded discriminating probe (.18.173, RU evidence driven).
--
-- .18.172 report on a route of ordinary trade goods (oats / egg / milk / sweet
-- potato) proved every GetLowestPrice return slot is a real nil while the call
-- itself succeeds (ok==true, so not a gate/cooldown refusal). "No listing at any
-- of seven grades for staples that are always on the AH" is far less plausible
-- than "wrong call protocol", so three hypotheses stay open:
--   H1 argument semantics  - itemGrade may not be a 0..6 ladder index
--   H2 warm-up prerequisite - the server may only answer after the Auction House
--                             UI / a SearchAuctionArticle populated the row cache
--   H3 genuinely empty     - these specific materials really have no listings
-- A raw-value log cannot separate them. This probe answers it directly by
-- querying a control itemType that must be listed, once per session, outside the
-- quote lane's hot path, and recording the honest outcome for diagnostics.
--
-- CORRECTION (.18.177, supersedes the .176 conclusion recorded here): the first
-- run of this probe made us declare GetLowestPrice unusable on RU. That was
-- wrong, and the reason is that the probe only ever exercised ONE of the two
-- legacy paths. The working reference build prices materials through a name
-- search whose first-row bid price becomes the cost; GetLowestPrice all-nil is
-- the *expected* mid-step, not a terminal failure. So "control items also return
-- nil" proved nothing about whether quoting can work -- our fallback was simply
-- dead code at the time (see _CheckFallback history). Do not conclude the API is
-- broken from these three rows again; read them alongside the fallback outcome.
-- ---------------------------------------------------------------------
local PROBE_CONTROL_ITEM_TYPES = { 3545, 3712, 3603 } -- oats / hay bale / egg
local ProbeState = { done = false, results = {}, attempts = 0, maxAttempts = 6 }

-- One synchronous native read whose ONLY purpose is to record the exact shape of
-- what RU returns. Never feeds prices, never touches the read model, never runs
-- inside a loop over units/rows.
function Q:RunProtocolProbe()
    if ProbeState.done == true then return true end
    if S.Api == nil or type(S.Api.CallCapability) ~= "function" then return false end
    -- 维护（auction-full-lane-safety-1）：手动协议探针也不得绕过原生优先级或挤占正在工作的 lane。
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
    -- Grade 0 first: the legacy ladder treats 0 as the unfiltered/widest query.
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

-- After direct stable-ID lookup is exhausted, use ONE bounded auction name
-- search as a compatibility fallback. AUCTION_ITEM_SEARCHED remains owned by
-- AuctionQueryV3; this service only consumes its detached snapshot.
local function BeginSearchFallback(pending)
    local query = S.Services and S.Services.AuctionQueryV3 or nil
    if type(query) ~= "table" or type(query.Search) ~= "function" then return false, "auction_query_unavailable" end
    local keyword = tostring(pending.searchName or "")
    if keyword == "" or #keyword > 64 then return false, "search_name_unavailable" end
    -- Shared AuctionQueryV3 owns the un-tokened native completion edge. If a
    -- user-facing auction search is already in flight, do not steal/cancel it
    -- and do not fail the quote merely because the shared authority is busy.
    -- The quote lane retries this *local admission check* on its next paced turn.
    local describe = type(query.Describe) == "function" and query:Describe() or nil
    if type(describe) == "table" and describe.pending == true then return false, "auction_query_busy" end
    pending.fallbackState = "searching"
    pending.fallbackDeadlineAt = pending.fallbackDeadlineAt or (NowMs() + 12000)
    -- 维护（2026-09-24，quote-fallback-identity-match-1）：旧实现 resultLimit=1 后只读 rows[1]。
    -- SearchAuctionArticle 是名称搜索，首条并不保证就是目标材料；因此“拍卖行有货”也会被错误判成身份不匹配。
    -- 这里仍只发 ONE 次服务器搜索，但有界读取最多 20 条，再按 stable itemType 优先、精确名称次之匹配。
    -- 维护（2026-10-02，material-name-candidates-1）：requireListing 约束价格来源，不是 Native 的名称
    -- 精确匹配开关。名称只负责召回候选；返回后仍由既有 SelectFallbackRow/FallbackRowPrice 核对事实。
    -- 不为同一材料追加重试/翻页，拍卖助手自己的显式精确搜索继续尊重其设置。
    local ok, err = query:Search("price_quote_fallback", keyword, { resultLimit = Q.fallbackSearchLimit, background = true, exactMatch = false })
    if ok ~= true then pending.fallbackState = "queued" end
    return ok == true, err
end

local function FallbackRowPrice(row, requireListing)
    if type(row) ~= "table" then return nil, nil, "row_unavailable" end
    -- 中文维护注释（2026-09-25，trade-fallback-unit-price-1）：AuctionQueryV3 的 directPrice/bidPrice
    -- 是整条 listing 的总价。旧实现直接把总价乘配方数量，例如“谷物细粉 x300”会再放大 300 倍，
    -- 产生 -10万金级假毛利。PriceQuoteQueue 作为价格 Authority 必须消费 unit* 字段；为了兼容同版本
    -- 内的旧 detached snapshot，可在 quantity 存在时本地重算，但 quantity 缺失时绝不猜测。
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
                -- Text may only bridge a missing stable identity, never override a conflicting one.
                if gradeMatches and wantedName ~= "" and gotName == wantedName and (rowType == nil or expected == nil) then
                    named[#named + 1] = { row = row, index = index, kind = "name" }
                end
            end
        end
    end
    local pool = #typed > 0 and typed or named
    if #pool == 0 then return nil, "none", nil, nil, nil, "identity_not_found" end

    -- SearchAuctionArticle ordering is not a unit-price contract. Evaluate every bounded matching row locally
    -- and choose the lowest immediately-purchasable unit price; bid-only rows are considered only if no
    -- matching direct/buyout listing has a usable quantity. No additional Native/server call is issued.
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


-- 维护：会话缓存有界，取消仅移除请求者需求；不能清除其它模块共享的事实。
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
        -- 维护（2026-09-30，trade-quote-price-safety-1）：价格服务是接受/隔离的唯一 Authority。
        -- 旧代码先写 session/TTL 再忽略 ObserveConfirmedPrice 返回；异常候选价因此能绕过已接受参考价。
        -- 一次 Native 回包只登记一次观察；隔离候选不进 session/TTL，也不延长旧参考价的新鲜度。
        referenceStored, priceDecision = Q:RecordReferencePrice(pending.itemType,
            pending.resolvedGrade or pending.itemGrade, quote.value, quote.source)
        priceHeld = referenceStored ~= true and priceDecision == "anomaly_candidate_held"
        if priceHeld and pending.singleQuery == true then
            -- 维护（trade-material-single-query-1）：严格单次查询不负责二次验证；候选价不冒充已确认价。
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
        -- 中文维护：冻结排队/响应阶段事实，TXT 不再把没发出的搜索笼统报告成 Native 响应超时。
        singleQuery = pending.singleQuery == true, searchGeneration = pending.searchGeneration,
        dispatchedAt=pending.dispatchedAt, queueDeadlineAt=pending.queueDeadlineAt, deadlineAt=pending.deadlineAt,
        blockReason = status == "blocked" and pending.admissionReason or nil,
        requestedAt = pending.requestedAt,
        completedAt = NowMs(),
        contract = "显式+异步报价；串行限速；结果字段按当前 RU 返回做 bounded normalization，未验证字段不作为成交样本",
        errorCode = pending.failureCode,
    }
    snapshot.at = snapshot.completedAt
    -- Shared per-itemType lifecycle state. "ready" mirrors pricesByItemType;
    -- every other terminal status records why the material stays unpriced so a
    -- projection can show 询价失败(原因) instead of an endless 待询价.
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
        -- 中文维护：最近完成环也保留两阶段时间；操作结束后原 active operation 已被释放。
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
    -- Index a completed (ready) quote by itemType so other Features can resolve
    -- a material's unit cost from the shared read model. Failed/unavailable
    -- completions must NOT overwrite a previously good price: fail-closed means
    -- we preserve the last trustworthy value rather than clearing it to a bogus
    -- "unknown" that a projection might misrender as zero.
    if status == "ready" and quote ~= nil and pending.itemType ~= nil and not priceHeld then
        Q.pricesByItemType[pending.itemType] = {
            price = quote.value, source = quote.source, itemGrade = pending.resolvedGrade or pending.itemGrade,
            completedAt = snapshot.completedAt,
        }
        -- 维护（trade-requote-2）：新挂单已验真时，同身份旧 TTL/负缓存失效；不能在下一次
        -- 普通请求中回放修正前价格。只失效当前品质，不清其它材料，也不把名称样本伪装成直接实时缓存。
        if pending.requireListing == true then
            local grade = tonumber(pending.resolvedGrade) or tonumber(pending.itemGrade)
            if grade ~= nil then Q.cache[tostring(pending.itemType) .. ":" .. tostring(grade)] = nil end
            if pending.requestKey ~= nil then Q.negativeCache[pending.requestKey] = nil end
        end
        -- Only direct stable-ID quotes enter the TTL cache; a name-search bid
        -- price is a reference estimate and must not be reused as a fresh quote
        -- on a later passive refresh.
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

-- 维护（trade-material-single-query-1 / 215703）：严格路径只拥有一次 Search；默认前台总计五秒，
-- 跑商有界排队与发包后五秒分别计时；后台仅未发包时可等待准入。
-- 完成/取消先解绑自身通知，再让出自己的无 token Native 请求；原 AuctionQuery timeout 继续隔离晚包。
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
    -- 维护（2026-10-02）：原生 Count=0 与有结果却无可靠一口价是两个断点；空搜索不是已证实无货。
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
        -- 中文维护（215703）：排队期与 Native 响应期分开。跑商的本地等待有自己的硬期限；
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
    -- 维护（2026-10-02，material-name-candidates-1）：211943 实机证明搜索返回空且事件不含行数据；
    -- 中文静态显示名并不是已核验的 Native 完整索引名，强制 exactMatch 可能在 ID 校验前排除候选。
    -- 单次材料查询用普通名称筛选；firstValidBuyout 要求真实 ID/品质、正数量和有效一口价，
    -- 并在本页最多三条样本中选较低单价，作为参考价；不声称是全市场最低。
    -- 不靠同名或默认品质接受报价。等级参数/单包上限/玩家拍卖优先级保持既有契约。
    local ok, err = query:Search(request.queryRequester, request.searchName, {
        background = true, exactMatch = false, resultLimit = 3,
        firstValidBuyout = { itemType = request.itemType, itemGrade = request.itemGrade },
        searchGeneration = request.searchGeneration,
    })
    if request.finished then return end -- Native may finish synchronously inside Search.
    if ok ~= true then
        return FinishSingle(request, PAUSE_REASONS[err] and "blocked" or "unavailable", nil, err or "search_rejected")
    end
    Q:_CheckSingle(request)
end

-- 维护（trade-requote-2）：只在既有需求 lane 中处理有界等待队列；不新建永久观察者。
-- 维护（auction-full-lane-safety-1）：缺少可见性证据时整条询价协议只停留在本地等待区，
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

-- Called from the drain lane every paced tick while a fallback search owns the
-- pending request. This keeps all queue state transitions on one authority and
-- adds no permanent subscription: the watcher task exists only during fallback.
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
        -- AuctionQueryV3 has its own 8s timeout. Keep a slightly wider outer wall
        -- clock so scheduler budget jitter cannot leave the quote pending forever.
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
    -- GetLowestPrice and SearchAuctionArticle are both server-query capabilities.
    -- Start the fallback on the *next* paced drain instead of issuing two server
    -- calls in the same scheduler turn. This keeps PriceQuoteQueueV3's one-lane
    -- pacing contract intact without increasing request count.
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
    -- 维护（2026-09-24，auction-market-price-handshake-1）：ArcheRage RU 2025-08-12 同一批次、同为 500ms 冷却
    -- 放行 AskMarketPrice(itemType,itemGrade,askMarketPriceUi) 与 GetLowestPrice(itemType,itemGrade)。结合实机证据
    -- “直接 GetLowestPrice 调用成功但全 nil”，报价协议改为显式 Ask -> 下一 paced turn Read；若仍无值才走名称搜索。
    -- 这里不依赖未验证事件、不轮询：Ask/Read/Search 三类服务器调用共用一个 scheduler lane，每个 turn 最多一次。
    -- 中文维护注释（2026-09-25，price-quote-drain-newline-1）：上一补丁生成时这里误写成字面量 `\n`，
    -- Lua 的 `--` 会把同一物理行剩余内容全部视为注释，导致 `local now = NowMs()` 没有执行；后续
    -- `now - lastNativeCallAt` 因 now=nil 让 v3_price_quote_drain 连续异常并被 Scheduler 退避暂停。
    -- 必须保持 now 为 Drain 每次调用的局部快照；禁止改成模块缓存或 Tick 外共享时间，避免并发状态漂移。
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
        -- 维护（auction-full-lane-safety-1）：一次把<=64个未发包请求转入等待，unknown 宽限从
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
        -- 维护（auction-full-lane-safety-1）：终态发布/恢复通知可能同步触发用户操作，
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
                return -- shared un-tokened AuctionQuery is busy; retry admission next paced turn
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
    -- CompletePending owns clearing Q.pending (it reads the pending request and
    -- nils it inside). Clearing it here first would make CompletePending see nil
    -- and silently drop the failure snapshot. Leave it intact and let
    -- CompletePending do the single authoritative clear.
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
    Q:_SetPaused(false) -- 最后一个需求取消/完成后，不遗留暂停提示或额外观察任务。
end

function Q:_Enqueue(requester, itemType, itemGrade, callback, grades, searchName, requestKey, priority, requireListing)
    local function Share(request)
        if request and request.requestKey==requestKey then
            request.watchers=request.watchers or {}
            request.watchers[requester]={callback=callback}
            -- 维护（2026-09-25，quote-request-identity-dedup-1）：searchName 只是稳定 ItemType 查询失败后的
            -- fallback 元数据，绝不能参与请求身份。两个货物共用同 itemType/grade 时必须合并成一个 Native 请求；
            -- 如果第一个 watcher 没有可用本地化名称，后加入 watcher 可以补全 fallback 名，但不能改写稳定身份。
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
            -- User intent may join a request that was admitted earlier as low-priority SWR. Promote that queued request
            -- ahead of remaining background work without touching the active Native pending request.
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
    -- 维护（2026-09-25，material-price-swr-priority-1）：后台 stale-while-revalidate 只能占用等待队列尾部；
    -- 用户明确双击/批量询价属于交互高优先级，必须插到尚未开始的 background 请求之前。当前 pending Native
    -- 调用不可抢占，因为 AUCTION_ITEM_SEARCHED/市场价协议没有 request-id；这里仅调整本地等待顺序。
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
    -- Maintenance: no successful request without a drain owner; a failed
    -- scheduler registration must roll back this enqueue, not leave a phantom.
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
    -- 中文维护：默认消费者仍总计五秒；仅明确请求分阶段计时的材料操作允许有界本地排队。
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

-- ---------------------------------------------------------------------
-- Persistent reference prices (see Q.referencePrices above for the design).
-- All mutations go through Persistence transactions so a failed save can never
-- leave a half-written table, and a corrupt/foreign store is fenced rather than
-- silently overwritten with defaults (fail-closed persistence invariants).
-- ---------------------------------------------------------------------
local MAX_REFERENCE_SAMPLES = 6
local function ReferenceKey(itemType, itemGrade)
    local id, grade = PositiveInt(itemType), tonumber(itemGrade)
    if id == nil then return nil end
    -- Grade is part of the identity: the ladder answers per grade, and an
    -- unfiltered grade-0 probe must not overwrite a specific grade's record.
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
            -- 中文维护注释（2026-09-25，trade-reference-price-poison-cleanup-1）：18.312 及更早的
            -- name_search_direct/name_search_bid 把 listing 总价写进了“单价”缓存。继续加载会让修复后的
            -- 代码仍显示 -10万金级旧毛利。只丢弃这些已知语义错误来源；GetLowestPrice/新 unit fallback
            -- 的历史证据继续保留，避免粗暴清空整个用户参考价 Store。
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

-- 2026-10-05 导出证明：旧 schema1 曾把 name_search_direct 的整单价计入原章。
-- 旧投影仅用于精确校验（含原有 updatedAt 取整）；Apply 仍过滤这些已证实错误的价格来源。
-- 不清档、不白名单放行 Hash；Core 必须验证旧候选与原章完全相同才能迁移并重新保存。
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

-- Load once per session. A load failure leaves the table empty but does NOT
-- clear or rewrite anything on disk: the player's history stays intact.
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
        -- Coalesced write: many materials can complete inside one second.
        P:MarkDirty(Q.StoreId, 1200, "reference_price_update")
        return true
    end
    return false
end

-- Record a confirmed quote. Only direct stable-ID results are persisted: a
-- name-search bid price is an estimate of a *different* listing and must not be
-- laundered into the long-lived table.
function Q:RecordReferencePrice(itemType, itemGrade, price, source)
    source = tostring(source or "auction")
    -- 维护（2026-09-25，material-price-authority-1）：18.317 起长期材料单价由 MaterialPriceServiceV3
    -- 独占。PriceQuoteQueueV3 只拥有 Native 请求串行/回调状态；旧 v3.trade_reference_prices 仅作为升级迁移
    -- 来源保留。混装旧包时继续走下方 legacy fallback，避免 Queue 因新 Service 缺失直接失效。
    local materialPrices = S.Services and S.Services.MaterialPriceServiceV3 or nil
    if type(materialPrices) == "table" and type(materialPrices.ObserveConfirmedPrice) == "function" then
        return materialPrices:ObserveConfirmedPrice(itemType, itemGrade, price, source)
    end
    -- Only the quantity-normalized direct fallback may become a long-lived reference. Bid prices remain
    -- non-final estimates; legacy unnormalized name_search_* sources are explicitly rejected.
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
        -- Newest first, bounded: keeps enough context to spot a manipulated low
        -- outlier without growing forever.
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

-- Read the last known cost for a material before any live quote exists. Returns
-- price, age info and provenance so the caller can label it as a reference value
-- instead of presenting it as current market data.
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

-- Explicit entry point. Feature modules submit one material at a time; the
-- service serializes and paces the native calls. `callback(snapshot)` fires once
-- when this request resolves (synchronously on a cache hit, otherwise paced).
-- Callers must establish batch state before requesting. `requester` is a stable token
-- used both for snapshot lookup and for delivery routing. `gradeCandidates` is
-- the optional ordered grade ladder (0..20, max 8): nil at one grade is a valid
-- "no listing" answer, so the request walks the ladder before failing.
-- `options.searchName` enables the verified legacy name-search fallback after
-- the whole ladder returns no listing; without it the request fails honestly.
-- `options.singleQuery=true` opts into one ID+grade-verified first-valid buyout search,
-- with no Ask/Get/ladder/retry. Foreground honors deadlineAt <= now+5s; background may
-- wait for safe admission, then owns a 5s result deadline. Cancellation keeps Native quarantine.
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
    -- 维护（2026-09-25，quote-request-identity-dedup-1）：requestKey 只由稳定 itemType + grade ladder 构成。
    -- localized searchName 不属于业务身份；把它拼进 key 会让同一红薯仅因两个调用者的显示名不同而重复查服务器。
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
    -- Mark the requester "queued" so its projection can render an honest
    -- pending state instead of a stale previous price.
    Q.snapshots[requester] = {
        requester = requester, itemType = itemType, itemGrade = itemGrade,
        status = "queued", price = nil, error = nil, requestedAt = NowMs(),
        contract = "显式+异步报价；等待串行限速队列处理",
    }
    -- A fresh explicit request supersedes any previous lifecycle state for this
    -- itemType (including a previous "ready": the user asked for a re-quote).
    Q.quoteStateByItemType[itemType] = {
        status = "queued", itemGrade = itemGrade, requester = requester, at = NowMs(),
    }
    return true, err or "queued"
end

-- 维护：取消权限是精确requester，不按item清缓存，也不取消其它模块的同项请求。
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
            -- 维护（2026-09-25，quote-pending-cancel-state-1）：pending 与 queue 必须遵守同一生命周期收敛。
            -- 18.307 只把 self.pending 清空，却没有把 quoteStateByItemType 的 queued/inflight 状态撤销；
            -- Trade 的材料投影因此会在批次已经取消、队列已经为空后仍永久渲染“询价中…”。这里仅在最后
            -- 一个 watcher 被移除且请求确实被丢弃时标记 cancelled；共享 watcher 仍存在时不得改写共享事实。
            -- fallbackState==searching 仍保留 pending 占位，因为 AuctionQueryV3 的完成事件没有请求 token，必须
            -- 消费晚到结果/超时后再释放 lane，不能为了 UI 状态提前复用未归属清晰的 Native 查询。
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

-- Read the last result for a requester without issuing a server query.
function Q:GetSnapshot(requester)
    requester = tostring(requester or "")
    return Copy(Q.snapshots[requester] or { requester = requester, status = "idle", price = nil, error = nil })
end

-- Resolve a material's unit cost from the shared read model by itemType (and
-- optional itemGrade). Returns nil (not 0) when no quote has completed, so a
-- projection can keep the honest "price pending" state instead of faking a cost.
function Q:GetPriceByItemType(itemType, itemGrade)
    itemType = PositiveInt(itemType)
    if itemType == nil then return nil end
    -- Session-fresh quote wins; otherwise replay the last known cost so the row
    -- is usable immediately instead of waiting on a paced auction search. The
    -- caller labels it as a reference value (see GetPriceWithProvenance).
    local entry = Q.pricesByItemType[itemType]
    if type(entry) ~= "table" then
        local reference, meta = Q:GetReferencePrice(itemType, itemGrade)
        if reference ~= nil then return reference, "reference:" .. tostring(meta and meta.source or "stored"), meta and meta.updatedAt or nil end
        return nil
    end
    -- Grade is a soft filter: the official GetLowestPrice(itemType, itemGrade)
    -- contract distinguishes grades, but if the caller omits grade we still
    -- return the last known price for that itemType (conservative single price).
    if itemGrade ~= nil and entry.itemGrade ~= nil and tonumber(entry.itemGrade) ~= tonumber(itemGrade) then
        return nil
    end
    return entry.price, entry.source, entry.completedAt
end

-- Passive read of the session price cache for a projection. Never issues a
-- native call and never extends freshness: an ordinary Refresh consults this to
-- avoid re-burning cooldown-bound queries after a reload of the UI (not the
-- addon). Normal explicit clicks also reuse it; force is an explicit override.
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

-- Single entry point for projections: returns price, provenance ("live" /
-- "reference") and the stored age so a page can label the number honestly. A
-- reference value must never be rendered as if it were a current quote.
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

-- Read the latest quote lifecycle state for an itemType. Returns nil (never a
-- fabricated state) when the itemType was never explicitly requested this
-- session, mirroring the grade soft-filter of GetPriceByItemType: a grade
-- mismatch is reported as "no state" so the caller keeps its honest unquoted
-- rendering instead of borrowing another grade's outcome.
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
            -- 中文维护：只读当前阶段，诊断生成不启动/续期 deadline，也不发补查。
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

-- Diagnostics-facing alias: keeps the shared-service GetHealth contract used by
-- the diagnostics snapshot without duplicating the Describe projection.
function Q:GetHealth()
    return self:Describe()
end

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
    version = 2,
    EventAuthorityContractVersion = 1,
    FallbackIdentityMatchContractVersion = 1,
    MarketPriceHandshakeContractVersion = 1,
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
    -- Deliberate decisions from the user:
    --   * NEVER expires. Auction listings are manipulable -- one cheap outlier
    --     drags everyone else's expectations down -- so an old sample must stay
    --     visibly old rather than silently masquerading as current. The UI label
    --     ("参考价") carries the staleness instead of a TTL.
    --   * Per itemType+grade, not per itemType, because the ladder already tells
    --     us which grade answered.
    --   * History is kept (bounded) so a suspiciously low sample can be judged
    --     against its neighbours later.
    --   * The store is per-account runtime data. It is never shipped with the
    --     addon package: each player builds their own observations.
    -- ------------------------------------------------------------------
    StoreId = "v3.trade_reference_prices",
    StoreContractVersion = 1,
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

local AuctionApi = rawget(_G, "X2Auction")

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
local function ToMoney(value)
    if type(value) == "number" then return value end
    if type(value) == "string" then
        local cleaned = value:gsub(",", ""):gsub("%s", "")
        return tonumber(cleaned)
    end
    if type(value) == "table" then
        local gold = tonumber(value.gold or value.g)
        local silver = tonumber(value.silver or value.s)
        local copper = tonumber(value.copper or value.c)
        if gold ~= nil or silver ~= nil or copper ~= nil then
            return math.floor((gold or 0) * 10000 + (silver or 0) * 100 + (copper or 0))
        end
        for _, key in ipairs({
            "value", "amount", "price", "money", "lowestPrice", "lowest_price",
            "directPrice", "directPriceStr", "bidPrice", "bidPriceStr", "buyoutPrice", "buyoutPriceStr",
        }) do
            local n = ToMoney(value[key]); if n ~= nil then return n end
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
    if price == nil or price < 0 then return nil end
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
        if n ~= nil and n == n and n ~= math.huge and n > 0 then return math.floor(n) end
    end
    return nil
end

local function Publish()
    if S.Events ~= nil and type(S.Events.Publish) == "function" then
        S.Events:Publish(Q.Topic)
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
    Publish()
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
    local ok, err = query:Search("price_quote_fallback", keyword, { resultLimit = Q.fallbackSearchLimit })
    if ok ~= true then pending.fallbackState = "queued" end
    return ok == true, err
end

local function FallbackRowPrice(row)
    if type(row) ~= "table" then return nil, nil end
    -- 维护（2026-09-24，auction-fallback-buyout-authority-1）：跑商材料成本需要“现在可以买到”的价格。
    -- direct/buyout 是可立即成交 Authority；bid 只是当前竞拍价，可能在结束前继续上涨，不能在存在一口价时
    -- 反过来覆盖它。仅当 RU 结果没有可读 directPrice 时，才把 bidPrice 作为降级参考并明确标记来源。
    local n = ToMoney(row.directPrice)
    if n ~= nil and n == n and n > 0 then return math.floor(n), "name_search_direct" end
    n = ToMoney(row.bidPrice)
    if n ~= nil and n == n and n > 0 then return math.floor(n), "name_search_bid" end
    return nil, nil
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
    local nameCandidate = nil
    for index, row in ipairs(rows) do
        if type(row) == "table" then
            local rowType = tonumber(row.itemType)
            rowType = rowType ~= nil and math.floor(rowType) or nil
            -- Stable item identity is authoritative. A localized display-name
            -- difference must never reject a row whose itemType already matches.
            if expected ~= nil and rowType ~= nil and rowType == expected then
                return row, "itemType", index
            end
            local gotName = NormalizeSearchIdentityName(row.name)
            -- Text is only a fallback when the native row does not prove a
            -- conflicting stable identity.
            if wantedName ~= "" and gotName == wantedName and (rowType == nil or expected == nil or rowType == expected) then
                nameCandidate = nameCandidate or { row = row, index = index }
            end
        end
    end
    if nameCandidate ~= nil then return nameCandidate.row, "name", nameCandidate.index end
    return nil, "none", nil
end


-- 维护：会话缓存有界，取消仅移除请求者需求；不能清除其它模块共享的事实。
local function CachePut(cache, key, value)
    local count, oldest, at = 0, nil, math.huge
    for k, v in pairs(cache) do count=count+1;if (tonumber(v.at) or 0)<at then oldest,at=k,tonumber(v.at) or 0 end end
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

local function CompletePending(status, quote, err, origin)
    local pending = Q.pending
    if type(pending) ~= "table" then return false end
    local requester = pending.requester
    Q.pending = nil
    local snapshot = {
        requester = requester,
        itemType = pending.itemType,
        itemGrade = pending.itemGrade,
        status = tostring(status or "failed"),
        price = quote ~= nil and quote.value or nil,
        priceSource = quote ~= nil and quote.source or nil,
        error = err,
        requestedAt = pending.requestedAt,
        completedAt = NowMs(),
        contract = "显式+异步报价；串行限速；结果字段按当前 RU 返回做 bounded normalization，未验证字段不作为成交样本",
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
                status = "failed", code = tostring(status or "failed"), error = err,
                itemGrade = pending.resolvedGrade or pending.itemGrade, requester = requester, at = snapshot.completedAt,
            }
        end
    end
    Q.lastCompleted = {
        requester = requester, itemType = pending.itemType, itemGrade = pending.itemGrade,
        status = snapshot.status, price = snapshot.price, priceSource = snapshot.priceSource,
        error = err, rawShape = Q.lastRawReturn, requestedAt = pending.requestedAt, at = snapshot.completedAt,
    }
    if status == "ready" then Q.stats.ready = Q.stats.ready + 1 else Q.stats.failed = Q.stats.failed + 1 end
    table.insert(Q.recent, 1, {
        requester = requester, itemType = pending.itemType, itemGrade = pending.itemGrade,
        status = snapshot.status, price = snapshot.price, priceSource = snapshot.priceSource,
        error = err, rawShape = Q.lastRawReturn, at = snapshot.completedAt,
    })
    if #Q.recent > Q.recentMax then table.remove(Q.recent) end
    -- Index a completed (ready) quote by itemType so other Features can resolve
    -- a material's unit cost from the shared read model. Failed/unavailable
    -- completions must NOT overwrite a previously good price: fail-closed means
    -- we preserve the last trustworthy value rather than clearing it to a bogus
    -- "unknown" that a projection might misrender as zero.
    if status == "ready" and quote ~= nil and pending.itemType ~= nil then
        Q.pricesByItemType[pending.itemType] = {
            price = quote.value, source = quote.source, itemGrade = pending.resolvedGrade or pending.itemGrade,
            completedAt = snapshot.completedAt,
        }
        -- Persist the grade that actually answered (resolvedGrade), not the hint
        -- we happened to ask about first.
        Q:RecordReferencePrice(pending.itemType, pending.resolvedGrade or pending.itemGrade,
            quote.value, quote.source)
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
    if status ~= "ready" and pending.requestKey then
        CachePut(Q.negativeCache, pending.requestKey, {at=NowMs(),snapshot=Copy(snapshot)})
    end
    -- 每个消费者各接收一次；取消的页面不再回调。快照在回调前复制，不能跨Feature共享可写表。
    for token, watcher in pairs(pending.watchers or {[requester]={callback=pending.callback}}) do
        Deliver(token,watcher.callback,snapshot)
    end
    if #Q.queue==0 and Q.pending==nil then Q:_StopLane() end
    Publish()
    return true
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
        local row, matchKind, matchIndex = SelectFallbackRow(rows, pending)
        Q.lastFallbackMatch = {
            keyword = tostring(pending.searchName or ""), itemType = pending.itemType,
            resultCount = #rows, matchKind = matchKind, matchIndex = matchIndex,
            status = status, at = NowMs(),
        }
        if row == nil then
            Q:_FailPending("unavailable", "名称搜索返回 " .. tostring(#rows) .. " 条，但没有匹配目标物品")
            return
        end
        local price, priceSource = FallbackRowPrice(row)
        if price ~= nil then
            Q.stats.fallbackMatches = (tonumber(Q.stats.fallbackMatches) or 0) + 1
            CompletePending("ready", { value = price, source = priceSource or "name_search" }, nil, "fallback")
            return
        end
        Q:_FailPending("unavailable", "匹配到目标物品，但搜索结果没有可读参考价")
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
    -- 这里不依赖未验证事件、不轮询：Ask/Read/Search 三类服务器调用共用一个 scheduler lane，每个 turn 最多一次。\n    local now = NowMs()
    if Q.lastNativeCallAt ~= nil and (now - Q.lastNativeCallAt) < Q.intervalMs then return end

    if Q.pending ~= nil then
        local pending = Q.pending
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
            if ok ~= true then
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
                Q:_FailPending("failed", tostring(err or "报价读取失败"))
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
                if err == "auction_query_busy" then
                    pending.fallbackState = "queued"
                    return
                end
                Q:_FailPending("unavailable", "名称搜索启动失败：" .. tostring(err or "unknown"))
            end
            return
        elseif pending.fallbackState == "searching" then
            Q:_CheckFallback()
            if Q.pending == nil and #Q.queue == 0 then Q:_StopLane() end
        end
        return
    end

    local request = table.remove(Q.queue, 1)
    if request == nil then
        Q:_StopLane()
        return
    end
    if S.Api == nil or type(S.Api.CallCapability) ~= "function" then
        Q.pending = request
        Q.lastRawReturn = "capability_boundary_unavailable"
        Q:_FailPending("capability_unavailable", "报价能力边界不可用")
        return
    end
    Q.pending = request
    Q.stats.attempts = Q.stats.attempts + 1
    Q.quoteStateByItemType[request.itemType] = {
        status = "inflight", itemGrade = request.itemGrade, requester = request.requester, at = NowMs(),
    }
    local grades = request.grades or {}
    local grade = grades[tonumber(request.gradeIndex) or 1] or request.itemGrade
    if grade == nil then
        Q:_FailPending("unavailable", "没有可探测的品质档位")
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
    if Q.running ~= true then return end
    if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(Q.taskName) end
    Q.running = false
end

function Q:_Enqueue(requester, itemType, itemGrade, callback, grades, searchName, requestKey)
    local function Share(request)
        if request and request.requestKey==requestKey then
            request.watchers=request.watchers or {}
            request.watchers[requester]={callback=callback}
            self.stats.merged=self.stats.merged+1
            return true
        end
    end
    if Share(self.pending) then return true,"shared" end
    for _,request in ipairs(self.queue) do if Share(request) then return true,"shared" end end
    local request = {
        requester = requester, itemType = itemType, itemGrade = itemGrade,
        callback = callback, requestedAt = NowMs(), requestKey=requestKey,
        watchers = {[requester]={callback=callback}},
        grades = type(grades) == "table" and #grades > 0 and grades or nil,
        gradeIndex = 1,
        searchName = searchName, fallbackState = nil, fallbackAttempts = 0,
        marketPriceState = nil, marketPriceGrade = nil,
    }
    if #Q.queue >= Q.maxQueue then return false, "报价队列已满，请稍后再试" end
    Q.queue[#Q.queue + 1] = request
    -- Maintenance: no successful request without a drain owner; a failed
    -- scheduler registration must roll back this enqueue, not leave a phantom.
    local started, startErr = Q:_StartLane()
    if started ~= true then table.remove(Q.queue); return false, startErr end
    return true
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

local function NormalizeReferenceState(value)
    local out = {}
    if type(value) ~= "table" then return out end
    local rows = type(value.entries) == "table" and value.entries or value
    local count = 0
    for key, entry in pairs(rows) do
        if count < 512 and type(key) == "string" and type(entry) == "table" then
            local price = tonumber(entry.price)
            local itemType = tonumber((key:gsub("^(-?%d+):.*$", "%1")))
            local grade = tonumber((key:gsub("^-?%d+:(-?%d+)$", "%1")))
            if price ~= nil and price == price and price > 0 and itemType ~= nil and grade ~= nil then
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
                    source = tostring(entry.source or "auction"),
                    samples = samples,
                }
                count = count + 1
            end
        end
    end
    return out
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
    if source == "name_search_bid" then return false, "estimate_not_persisted" end
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
        source = tostring(source or "auction"),
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
function Q:RequestQuote(requester, itemType, itemGrade, callback, gradeCandidates, options)
    requester = tostring(requester or "")
    itemType = PositiveInt(itemType)
    if requester == "" then return false, "报价来源不能为空" end
    if itemType == nil then return false, "物品类型无效" end
    itemGrade = tonumber(itemGrade)
    if itemGrade==nil or itemGrade~=math.floor(itemGrade) or itemGrade<0 or itemGrade>20 then itemGrade=1 end
    options = type(options) == "table" and options or {}
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
    local requestKey=tostring(itemType)..":"..table.concat(parts,",")..":"..tostring(searchName or "")
    -- 显式force只跳过缓存，仍遵守串行/去重。正常点击不反复查询刚完成/刚失败的材料。
    if options.force ~= true then
        local price,at=Q:PeekCached(itemType,grades[1])
        if price~=nil then
            self.stats.cacheHits=self.stats.cacheHits+1
            Deliver(requester,callback,{status="ready",price=price,itemType=itemType,itemGrade=grades[1],cached=true,
                completedAt=at,at=NowMs(),priceSource="cached"});Publish();return true,"cached"
        end
        local negative=self.negativeCache[requestKey]
        if negative and NowMs()-negative.at>=0 and NowMs()-negative.at<self.negativeTtlMs then
            self.stats.cacheHits=self.stats.cacheHits+1;local snap=Copy(negative.snapshot);snap.cached=true
            Deliver(requester,callback,snap);Publish();return true,"cached_negative"
        end
    end
    local ok, err = Q:_Enqueue(requester, itemType, itemGrade, callback, grades, searchName, requestKey)
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
    local removed=0
    for i=#self.queue,1,-1 do
        local r=self.queue[i]
        if r.watchers and r.watchers[requester] then r.watchers[requester]=nil;removed=removed+1 end
        if not next(r.watchers or {}) then
            table.remove(self.queue,i)
            self.quoteStateByItemType[r.itemType]={status="cancelled",itemGrade=r.itemGrade,at=NowMs()}
        end
    end
    local r=self.pending
    if r and r.watchers and r.watchers[requester] then
        r.watchers[requester]=nil;removed=removed+1
        if not next(r.watchers) and r.fallbackState~="searching" then self.pending=nil end
    end
    self.stats.cancelled=self.stats.cancelled+removed
    self.snapshots[requester]={status="cancelled",requester=requester,at=NowMs()}
    if #self.queue==0 and self.pending==nil then self:_StopLane() end
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
        pending = self.pending ~= nil, queueLength = #self.queue,
        maxQueue = self.maxQueue, intervalMs = self.intervalMs,
        pricedItemTypes = priced,
        stats = Copy(self.stats),
        recent = recent,
        lastRawReturn = self.lastRawReturn,
        lastFallbackMatch = self.lastFallbackMatch and Copy(self.lastFallbackMatch) or nil,
        lastMarketAsk = self.lastMarketAsk and Copy(self.lastMarketAsk) or nil,
        pendingDetail = type(self.pending) == "table" and {
            itemType = self.pending.itemType, itemGrade = self.pending.itemGrade, gradeIndex = self.pending.gradeIndex,
            searchName = self.pending.searchName, fallbackState = self.pending.fallbackState,
            marketPriceState = self.pending.marketPriceState, marketPriceGrade = self.pending.marketPriceGrade,
            requestedAt = self.pending.requestedAt,
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

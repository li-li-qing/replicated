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
    version = 1,
    EventAuthorityContractVersion = 1,
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
    -- A fresh explicit RequestQuote always bypasses it (user intent wins); only
    -- passive projections consult PeekCached so an ordinary Refresh never burns
    -- cooldown-bound native calls. Failed/unavailable outcomes are NOT cached.
    cache = {},
    cacheTtlMs = 120000,
    owner = {},
    -- Spacing between drained requests. Must be >= the 500ms official cooldown
    -- so the capability gate never rejects the next call mid-batch.
    intervalMs = 560,
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
    stats = { attempts = 0, ready = 0, failed = 0 },
    recent = {},        -- newest-first ring of the last completions
    recentMax = 12,
    lastRawReturn = nil, -- bounded shape of the most recent native return
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

-- After the grade ladder is exhausted, the verified legacy protocol falls back
-- to ONE bounded auction search by the material's localized display name and
-- reads the first row's bid price as a reference estimate. The un-tokened
-- AUCTION_ITEM_SEARCHED completion edge is owned by AuctionQueryV3; this service
-- never subscribes to it directly (shared-fact ownership invariant).
local function BeginSearchFallback(pending)
    local query = S.Services and S.Services.AuctionQueryV3 or nil
    if type(query) ~= "table" or type(query.Search) ~= "function" then return false end
    local keyword = tostring(pending.searchName or "")
    if keyword == "" or #keyword > 64 then return false end
    pending.fallbackState = "searching"
    local ok = query:Search("price_quote_fallback", keyword, { resultLimit = 1 })
    return ok == true
end

local function FallbackRowPrice(row)
    if type(row) ~= "table" then return nil end
    local n = ToMoney(row.bidPrice)
    if n == nil then n = ToMoney(row.directPrice) end
    if n ~= nil and n == n and n > 0 then return math.floor(n) end
    return nil
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
    Q.snapshots[requester] = snapshot
    -- Shared per-itemType lifecycle state. "ready" mirrors pricesByItemType;
    -- every other terminal status records why the material stays unpriced so a
    -- projection can show 询价失败(原因) instead of an endless 待询价.
    if pending.itemType ~= nil then
        if status == "ready" and quote ~= nil then
            Q.quoteStateByItemType[pending.itemType] = {
                status = "ready", price = quote.value, priceSource = quote.source,
                itemGrade = pending.itemGrade, requester = requester, at = snapshot.completedAt,
            }
        else
            Q.quoteStateByItemType[pending.itemType] = {
                status = "failed", code = tostring(status or "failed"), error = err,
                itemGrade = pending.itemGrade, requester = requester, at = snapshot.completedAt,
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
            price = quote.value, source = quote.source, itemGrade = pending.itemGrade,
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
                Q.cache[tostring(math.floor(pending.itemType)) .. ":" .. tostring(math.floor(resolvedGrade))] =
                    { price = quote.value, at = snapshot.completedAt }
            end
        end
    end
    if type(pending.callback) == "function" then
        local ok, cbErr = pcall(function() pending.callback(snapshot) end)
        if not ok then S.LastPriceQuoteCallbackError = { requester = requester, error = tostring(cbErr or "unknown") } end
    end
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
        Q:_FailPending("unavailable", "全部 " .. tostring(#(pending.grades or {})) .. " 档品质均无在售挂单（名称搜索兜底不可用）")
        return
    end
    local snap = query:GetSnapshot("price_quote_fallback")
    local status = type(snap) == "table" and tostring(snap.status or "") or ""
    if status == "waiting" then
        -- Still awaiting AUCTION_ITEM_SEARCHED. Re-issuing here cannot help:
        -- AuctionQueryV3:Search rejects a new request while its own pending slot
        -- is occupied, so an earlier version of this branch burned three retries
        -- on guaranteed failures and then declared the material unquotable. Just
        -- wait, bounded by an explicit wall-clock deadline instead of attempt
        -- counts (auction responses are slower than one 560 ms drain tick).
        pending.fallbackDeadlineAt = pending.fallbackDeadlineAt or (NowMs() + 12000)
        if NowMs() < (tonumber(pending.fallbackDeadlineAt) or 0) then return end
        Q:_FailPending("unavailable", "全部 " .. tostring(#(pending.grades or {})) .. " 档品质均无在售挂单（名称搜索超时）")
        return
    end
    if status == "ready" or status == "partial" then
        local rows = type(snap.rows) == "table" and snap.rows or {}
        local row = rows[1]
        local expected = tonumber(pending.itemType)
        local rowType = type(row) == "table" and tonumber(row.itemType) or nil
        -- Reject a *provably different* stable identity. An unreadable row shape
        -- (rowType == nil) must not fail closed here: the current RU client does
        -- not reliably expose itemType on GetSearchedItemInfo, and treating that
        -- as "identity mismatch" made every fallback die on its own guard. The
        -- keyword was our own localized material name, so a name-equality check
        -- is the honest available verification.
        if expected ~= nil and rowType ~= nil and math.floor(rowType) ~= expected then
            Q:_FailPending("unavailable", "全部 " .. tostring(#(pending.grades or {})) .. " 档品质均无在售挂单（搜索结果身份不匹配）")
            return
        end
        local wantName = tostring(pending.searchName or "")
        local gotName = type(row) == "table" and tostring(row.name or "") or ""
        if wantName ~= "" and gotName ~= "" and gotName ~= wantName then
            Q:_FailPending("unavailable", "全部 " .. tostring(#(pending.grades or {})) .. " 档品质均无在售挂单（搜索结果名称不符）")
            return
        end
        local price = FallbackRowPrice(row)
        if price ~= nil then
            CompletePending("ready", { value = price, source = "name_search_bid" }, nil, "fallback")
            return
        end
        Q:_FailPending("unavailable", "全部 " .. tostring(#(pending.grades or {})) .. " 档品质均无在售挂单（搜索结果无参考价）")
        return
    end
    -- empty / failed / idle: the ladder already proved there is no direct listing.
    Q:_FailPending("unavailable", "全部 " .. tostring(#(pending.grades or {})) .. " 档品质均无在售挂单（名称搜索亦无结果）")
end

local function Drain()
    -- Protocol discrimination rides the same paced lane as real quotes: it only
    -- advances while the queue is already alive (explicit user demand), stops by
    -- itself once ProbeState is done, and never needs its own timer/task. It is
    -- advanced before the pending early-return so a slow in-flight request cannot
    -- stall the whole probe behind one drain slot.
    -- One native call per tick, period. The probe shares the GetLowestPrice
    -- capability cooldown with real quotes, so issuing both in the same drain
    -- slot made the second one fail with "cooldown active: 500ms remaining" and
    -- burned user quotes. When the probe still has work, it takes the tick and
    -- the real queue waits for the next paced slot.
    -- Wall-clock cooldown fence: never enter the native path until the previous
    -- attempt is provably outside the official window. Applies to probe and real
    -- quotes alike, so a deferred tick cannot double-fire inside 500 ms.
    local now = NowMs()
    if Q.lastNativeCallAt ~= nil and (now - Q.lastNativeCallAt) < Q.intervalMs then return end

    if ProbeState.done ~= true then
        Q:RunProtocolProbe()
        return
    end
    -- An in-flight fallback search legitimately occupies Q.pending while we wait
    -- for AUCTION_ITEM_SEARCHED. Servicing it must happen *before* the generic
    -- pending early-return below, otherwise the wait becomes a permanent stall
    -- (.178: 已报=0/失败=0 because this branch was unreachable).
    if Q.pending ~= nil then
        if Q.pending.fallbackState == "searching" then
            Q:_CheckFallback()
            if Q.pending == nil then Q.running = false end
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
    -- Reaching here means the request is fresh from the queue, so it cannot be in
    -- fallback state (that path is serviced above). Counting attempts only on the
    -- direct grade probe keeps stats.attempts meaning "GetLowestPrice calls".
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
    -- CallCapability enforces the 500ms cooldown itself; our 560ms spacing keeps
    -- the native call inside a clean window. A false return here means the gate
    -- (or the native getter) rejected it — fail closed, do not retry blindly.
    Q.lastNativeCallAt = NowMs()
    local ok, value, err, b, c, d = S.Api:CallCapability("X2Auction:GetLowestPrice", nil, "GetLowestPrice", request.itemType, grade)
    local gradeLabel = "grade " .. tostring(grade) .. "/" .. tostring(#grades)
    Q.lastRawReturn = ok ~= true and ("call_failed:" .. tostring(err or "?")) or (gradeLabel .. ": " .. ShapeOf(value) .. ", " .. ShapeOf(b) .. ", " .. ShapeOf(c) .. ", " .. ShapeOf(d))
    if ok ~= true then
        -- A capability/runtime failure is not evidence about the next grade.
        Q:_FailPending("failed", tostring(err or "报价请求被拒绝"))
        return
    end
    local price = ScanPrice(value, b, c, d)
    if price == nil and type(value) == "table" then
        local quote = NormalizeQuote(value)
        if quote ~= nil then price = quote.value end
    end
    if price ~= nil then
        -- Legacy-verified semantics: a positive GetLowestPrice return IS the
        -- lowest listing price (per-grade). The name-search fallback below is
        -- bidPrice-based and therefore only a reference estimate.
        request.resolvedGrade = grade
        CompletePending("ready", { value = price, source = "grade:" .. tostring(grade) }, nil, "direct")
        return
    end
    -- nil here means "no listing at this grade": probe the next grade for the
    -- SAME request on the next paced tick instead of failing the material.
    request.gradeIndex = (tonumber(request.gradeIndex) or 1) + 1
    if request.gradeIndex <= #grades then
        Q.pending = nil
        table.insert(Q.queue, 1, request)
        return
    end
    -- Ladder exhausted. Fall back to one bounded name search when the caller
    -- supplied a display name; otherwise fail with the honest no-listing reason.
    -- No separate scheduler task: the existing drain lane re-enters this
    -- request every paced tick and _CheckFallback advances it (single-lane
    -- contract; a second AddTask would be a parallel authority).
    if request.searchName ~= nil and request.searchName ~= "" and BeginSearchFallback(request) then
        return
    end
    Q:_FailPending("unavailable", "全部 " .. tostring(#grades) .. " 档品质均无在售挂单")
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
    if Q.running == true then return end
    if S.Scheduler == nil or type(S.Scheduler.AddTask) ~= "function" then return end
    local added = S.Scheduler:AddTask(Q.taskName, Q.intervalMs, function() Drain() end, false, Q.owner, "P2", 1)
    if added == true then Q.running = true end
end

function Q:_StopLane()
    if Q.running ~= true then return end
    if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(Q.taskName) end
    Q.running = false
end

function Q:_Enqueue(requester, itemType, itemGrade, callback, grades, searchName)
    local request = {
        requester = requester, itemType = itemType, itemGrade = itemGrade,
        callback = callback, requestedAt = NowMs(),
        grades = type(grades) == "table" and #grades > 0 and grades or nil,
        gradeIndex = 1,
        searchName = searchName, fallbackState = nil, fallbackAttempts = 0,
    }
    if #Q.queue >= Q.maxQueue then return false, "报价队列已满，请稍后再试" end
    Q.queue[#Q.queue + 1] = request
    Q:_StartLane()
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
    local id, grade = PositiveInt(itemType), PositiveInt(itemGrade)
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
-- when this request resolves (asynchronously). `requester` is a stable token
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
    itemGrade = PositiveInt(itemGrade)
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
        for grade = 1, 6 do AddGrade(grade) end
        AddGrade(0)
    end
    local ok, err = Q:_Enqueue(requester, itemType, itemGrade, callback, grades, searchName)
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
    return true, "queued"
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
-- addon). Explicit user quotes bypass it inside RequestQuote by design.
function Q:PeekCached(itemType, itemGrade)
    itemType = PositiveInt(itemType)
    local grade = PositiveInt(itemGrade)
    if itemType == nil or grade == nil then return nil end
    local entry = Q.cache[tostring(itemType) .. ":" .. tostring(grade)]
    if type(entry) ~= "table" then return nil end
    local at = tonumber(entry.at) or 0
    if NowMs() - at > Q.cacheTtlMs then
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
    if type(fresh) == "table" and fresh.price ~= nil then
        return tonumber(fresh.price), "live", { source = fresh.source, at = fresh.completedAt, grade = fresh.itemGrade }
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
        version = self.version, running = self.running == true,
        pending = self.pending ~= nil, queueLength = #self.queue,
        maxQueue = self.maxQueue, intervalMs = self.intervalMs,
        pricedItemTypes = priced,
        stats = Copy(self.stats),
        recent = recent,
        lastRawReturn = self.lastRawReturn,
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

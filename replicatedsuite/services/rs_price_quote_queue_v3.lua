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
    -- itemType -> latest completed quote. This is the cross-feature read model:
    -- any Feature (Trade/CraftAssist/AuctionFavorites) can resolve a material's
    -- unit cost by itemType+itemGrade without knowing which requester issued the
    -- quote, and without re-issuing a server query.
    pricesByItemType = {},
    owner = {},
    -- Spacing between drained requests. Must be >= the 500ms official cooldown
    -- so the capability gate never rejects the next call mid-batch.
    intervalMs = 560,
    maxQueue = 64,
    taskName = "v3_price_quote_drain",
    running = false,
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
local function NormalizeQuote(raw)
    if raw == nil then return nil end
    local price = nil
    local source = "unknown"
    if type(raw) == "number" then
        price, source = math.floor(raw), "number"
    elseif type(raw) == "string" then
        local n = tonumber(raw); if n ~= nil and n >= 0 then price, source = math.floor(n), "string" end
    elseif type(raw) == "table" then
        for _, key in ipairs({ "lowestPrice", "price", "buyoutPrice", "minPrice", "value", "copper", "result" }) do
            local candidate = raw[key]
            if type(candidate) == "number" then price, source = math.floor(candidate), "field:" .. key; break
            elseif type(candidate) == "string" then
                local n = tonumber(candidate); if n ~= nil and n >= 0 then price, source = math.floor(n), "field:" .. key; break end
            end
        end
    end
    if price == nil or price < 0 then return nil end
    return { value = price, source = source }
end

local function Publish()
    if S.Events ~= nil and type(S.Events.Publish) == "function" then
        S.Events:Publish(Q.Topic)
    end
end

local function CompletePending(status, quote, err)
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
    end
    if type(pending.callback) == "function" then
        local ok, cbErr = pcall(function() pending.callback(snapshot) end)
        if not ok then S.LastPriceQuoteCallbackError = { requester = requester, error = tostring(cbErr or "unknown") } end
    end
    Publish()
    return true
end

local function Drain()
    if Q.pending ~= nil then return end
    local request = table.remove(Q.queue, 1)
    if request == nil then
        Q:_StopLane()
        return
    end
    if S.Api == nil or type(S.Api.CallCapability) ~= "function" then
        Q.pending = request
        Q:_FailPending("capability_unavailable", "报价能力边界不可用")
        return
    end
    Q.pending = request
    -- CallCapability enforces the 500ms cooldown itself; our 560ms spacing keeps
    -- the native call inside a clean window. A false return here means the gate
    -- (or the native getter) rejected it — fail closed, do not retry blindly.
    local ok, value, err = S.Api:CallCapability("X2Auction:GetLowestPrice", AuctionApi, "GetLowestPrice", request.itemType, request.itemGrade)
    if ok ~= true then
        Q:_FailPending("failed", tostring(err or "报价请求被拒绝"))
        return
    end
    local quote = NormalizeQuote(value)
    if quote == nil then
        Q:_FailPending("unavailable", "最低价返回不可读（当前 RU 字段待核）")
        return
    end
    CompletePending("ready", quote, nil)
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

function Q:_Enqueue(requester, itemType, itemGrade, callback)
    local request = {
        requester = requester, itemType = itemType, itemGrade = itemGrade,
        callback = callback, requestedAt = NowMs(),
    }
    if #Q.queue >= Q.maxQueue then return false, "报价队列已满，请稍后再试" end
    Q.queue[#Q.queue + 1] = request
    Q:_StartLane()
    return true
end

-- Explicit entry point. Feature modules submit one material at a time; the
-- service serializes and paces the native calls. `callback(snapshot)` fires once
-- when this request resolves (asynchronously). `requester` is a stable token
-- used both for snapshot lookup and for delivery routing.
function Q:RequestQuote(requester, itemType, itemGrade, callback)
    requester = tostring(requester or "")
    itemType = PositiveInt(itemType)
    if requester == "" then return false, "报价来源不能为空" end
    if itemType == nil then return false, "物品类型无效" end
    itemGrade = PositiveInt(itemGrade)
    local ok, err = Q:_Enqueue(requester, itemType, itemGrade, callback)
    if ok ~= true then return ok, err end
    -- Mark the requester "queued" so its projection can render an honest
    -- pending state instead of a stale previous price.
    Q.snapshots[requester] = {
        requester = requester, itemType = itemType, itemGrade = itemGrade,
        status = "queued", price = nil, error = nil, requestedAt = NowMs(),
        contract = "显式+异步报价；等待串行限速队列处理",
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
    local entry = Q.pricesByItemType[itemType]
    if type(entry) ~= "table" then return nil end
    -- Grade is a soft filter: the official GetLowestPrice(itemType, itemGrade)
    -- contract distinguishes grades, but if the caller omits grade we still
    -- return the last known price for that itemType (conservative single price).
    if itemGrade ~= nil and entry.itemGrade ~= nil and tonumber(entry.itemGrade) ~= tonumber(itemGrade) then
        return nil
    end
    return entry.price, entry.source, entry.completedAt
end

function Q:Describe()
    local priced = 0
    for _ in pairs(self.pricesByItemType or {}) do priced = priced + 1 end
    return {
        version = self.version, running = self.running == true,
        pending = self.pending ~= nil, queueLength = #self.queue,
        maxQueue = self.maxQueue, intervalMs = self.intervalMs,
        pricedItemTypes = priced,
    }
end

------------------------------------------------------------------------
-- Replicated Suite - Material Price Service V3
--
-- Long-lived material unit-price Authority used by Trade and any future
-- economy feature. PriceQuoteQueueV3 owns Native auction serialization; this
-- service owns durable unit-price observations, age/freshness semantics,
-- bounded anomaly protection and stale-while-revalidate admission.
--
-- Data flow:
--   Trade/Craft/etc. -> GetPrice()                    (local read only)
--   Trade visible rows -> QueueRevalidate()           (bounded background intent)
--   PriceQuoteQueueV3 -> RecordReferencePrice()       (confirmed unit quote)
--                        -> ObserveConfirmedPrice()    (this service)
--   this service -> v3.material_price.changed         (read-model invalidation)
--
-- Important boundaries:
--   * NEVER issues X2Auction calls directly.
--   * NEVER scans on Tick/OnUpdate. Background work is only explicit admission
--     into the existing single PriceQuoteQueueV3 lane.
--   * Persistent timestamps use server wall-clock minute stamps, not NowMs().
--     NowMs resets on reload and therefore cannot represent multi-day age.
--   * Old data remains usable. "stale" means "show now, refresh quietly", not
--     "invalidate and block profit".
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Services = S.Services or {}

local M = {
    version = 1,
    ContractVersion = 1,
    StoreContractVersion = 1,
    FreshnessContractVersion = 1,
    BackgroundRevalidateContractVersion = 1,
    AnomalyGuardContractVersion = 1,
    StoreLoadBackoffContractVersion = 1,
    CorruptCacheRecoveryContractVersion = 1,
    Topic = "v3.material_price.changed",
    StoreId = "v3.market.material_prices",
    -- 维护（2026-09-25，service-boundary-declaration-1）：Foundation Gate 的
    -- service_presentation_boundary 会枚举 S.Services.* 的每一张表，要求显式声明
    -- presentationBoundary ∈ {service_only, event_host_only}；缺失即 blocker。
    -- 本服务只拥有持久价格事实/新鲜度/有界后台 admission，不创建任何 Native 控件、
    -- 不引用 S.UI/UIParent/RSUI，也不直接发起 X2Auction 调用，因此属于 service_only。
    -- 新增 Service 时必须一并声明该字段，否则自检整份报告会被阻断。
    presentationBoundary = "service_only",
    entries = {},
    revision = 0,
    storeLoaded = false,
    legacyImported = false,
    -- 维护（2026-09-27，material-price-store-backoff-1）：材料价 Store 属于冷路径持久化 Authority。
    -- 若一次 LoadStore 因完整性/传输/初始化边界失败，普通路线一行可能包含多种材料，旧实现每次 GetPrice
    -- 都会再次尝试 LoadStore；实机诊断出现 567 次 miss / 0 write，导致“货率已回调”之后仍被材料价子系统
    -- 反复拖住。失败只在固定边沿重试，绝不在行循环里重打持久化读取；显式报价仍可回退 QuoteQueue 的会话缓存。
    storeLoadRetryMs = 5000,
    storeLoadAttempts = 0,
    storeLoadFailures = 0,
    storeLoadBackoffHits = 0,
    lastStoreLoadAt = 0,
    lastStoreLoadError = nil,
    nextStoreLoadRetryAt = 0,
    -- 维护（2026-09-27，material-price-cache-recovery-1）：本 Store 保存的是可由拍卖询价重新生成的
    -- 派生缓存，不是用户配置/收藏/路线 Authority。若 Persistence 已经通过 Envelope/预算/Schema
    -- 检查并明确把该 Store Fence 为 current-schema fingerprint mismatch，继续保留写保护只会让
    -- MaterialPriceService 永久不可用。这里允许一次“空缓存完整替换 + durable readback 验证”；
    -- 只处理 integrity fingerprint mismatch，LoadData 错误/未来 schema/作用域错误等仍保持 fail-closed。
    cacheRecoveryAttempts = 0,
    cacheRecoverySuccesses = 0,
    cacheRecoveryFailures = 0,
    lastCacheRecoveryAt = 0,
    lastCacheRecoveryError = nil,
    lastCacheRecoveryReason = nil,
    -- Freshness policy requested for Trade SWR. Old prices remain readable.
    freshMinutes = 6 * 60,
    warmMinutes = 24 * 60,
    staleMinutes = 7 * 24 * 60,
    maxEntries = 512,
    maxSamples = 6,
    maxBackgroundPerAdmission = 12,
    backgroundRetryMs = 60000,
    -- 维护（2026-09-28，material-price-anomaly-jump-1）：本条阈值原来是 8，只防“数量级错误”
    -- （例如拍卖把整组总价当单价，×100）。实机取证（`USER<id>/udf` 的 v3.market.material_prices，
    -- 38 次写入 + 22 条材料）发现真正的故障模式是另一种：**拍卖行临时缺货、只剩一个高价挂单**，
    -- 于是最低一口价单价一次性跳 2~3 倍并被直接落库。实例：「捣碎的香料」(30901) 前 34 次写入
    -- 稳定 559 铜，随后一次跳到 1,499 铜（2.68 倍，无中间值）；它占 `[玛瑞诺普]新鲜特产`
    -- 配方成本的 93.7%（180/198 件），把该行从 +16 金 26 银 直接算成 −66 银 04 铜。
    -- 同族 6 个加工品当时都在 385~576 铜，只有它 3 倍偏离，说明这不是市场整体涨价。
    -- 因此把阈值收紧到 2.5：2.5 倍以上的跳变必须先进入候选观察、第二次一致观测才落库；
    -- 代价是真实市场突变时价格生效晚一个观测周期（SWR 本来就容忍 stale，可接受）。
    -- 注意：正常波动不受影响 —— 本次 22 条里除该例外，其余倍率都在 0.72~1.11。
    anomalyRatio = 2.5,
    anomalyConfirmTolerance = 0.15,
    refreshPending = {},
    lastRefreshAttemptMs = {},
    -- Session-only acceptance clock. Server wall time can be briefly unavailable immediately after UI reload;
    -- a quote confirmed in this generation must still be treated as fresh instead of being re-enqueued every rebuild.
    -- This table is deliberately not persisted: multi-day age always comes from observedMinute.
    sessionObservedAtMs = {},
    stats = {
        reads = 0, hits = 0, misses = 0, writes = 0, imported = 0,
        backgroundSubmitted = 0, backgroundSkippedFresh = 0,
        backgroundJoined = 0, backgroundFailed = 0, backgroundStoreUnavailable = 0,
        anomalyHeld = 0, anomalyConfirmed = 0, anomalyRevertedToKnown = 0,
    },
}
S.Services.MaterialPriceServiceV3 = M

local function Copy(value)
    if S.Utils ~= nil and type(S.Utils.DeepCopy) == "function" then return S.Utils.DeepCopy(value) end
    if type(value) ~= "table" then return value end
    local out = {}; for key, child in pairs(value) do out[key] = Copy(child) end; return out
end

local function NowMs()
    return type(S.NowMs) == "function" and math.max(0, tonumber(S.NowMs()) or 0) or 0
end

local function PositiveInt(value)
    local n = tonumber(value)
    if n == nil or n ~= n or n < 1 or n ~= math.floor(n) then return nil end
    return math.floor(n)
end

local function Grade(value)
    local n = tonumber(value)
    if n == nil or n ~= n or n < 0 or n > 20 or n ~= math.floor(n) then return 1 end
    return math.floor(n)
end

local function Key(itemType, itemGrade)
    local id = PositiveInt(itemType)
    if id == nil then return nil end
    return tostring(id) .. ":" .. tostring(Grade(itemGrade))
end

local function IsLeap(year)
    return year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)
end

local MONTH_OFFSETS = { 0,31,59,90,120,151,181,212,243,273,304,334 }
local function ServerMinuteStamp()
    if S.Utils == nil or type(S.Utils.GetServerTime) ~= "function" then return nil end
    local t = S.Utils.GetServerTime()
    if type(t) ~= "table" then return nil end
    local year, month, day = tonumber(t.year), tonumber(t.month), tonumber(t.day)
    local hour, minute = tonumber(t.hour), tonumber(t.minute)
    if year == nil or year < 2000 or year > 2100 or month == nil or month < 1 or month > 12 or day == nil or day < 1 or day > 31 then return nil end
    hour = math.max(0, math.min(23, math.floor(hour or 0)))
    minute = math.max(0, math.min(59, math.floor(minute or 0)))
    year, month, day = math.floor(year), math.floor(month), math.floor(day)
    -- Gregorian serial day. Formula is stable across addon reloads and does not
    -- depend on os.time (not guaranteed in the ArcheAge Lua sandbox).
    local y = year - 1
    local days = 365 * y + math.floor(y / 4) - math.floor(y / 100) + math.floor(y / 400)
        + MONTH_OFFSETS[month] + day - 1
    if month > 2 and IsLeap(year) then days = days + 1 end
    return days * 1440 + hour * 60 + minute
end

local function NormalizeSamples(value, maxSamples)
    local out = {}
    if type(value) ~= "table" then return out end
    for index = 1, math.min(maxSamples, #value) do
        local raw = value[index]
        if type(raw) == "number" then
            if raw > 0 then out[#out + 1] = { price = math.floor(raw), observedMinute = nil } end
        elseif type(raw) == "table" then
            local price = tonumber(raw.price)
            local minute = tonumber(raw.observedMinute)
            if price ~= nil and price == price and price > 0 then
                out[#out + 1] = { price = math.floor(price), observedMinute = minute ~= nil and math.floor(minute) or nil }
            end
        end
    end
    return out
end

local function NormalizeEntries(value)
    local source = type(value) == "table" and (type(value.entries) == "table" and value.entries or value) or {}
    local out, count = {}, 0
    for key, raw in pairs(source) do
        if count >= M.maxEntries then break end
        if type(key) == "string" and type(raw) == "table" then
            local itemType = PositiveInt(raw.itemType or tonumber((key:gsub("^(-?%d+):.*$", "%1"))))
            local itemGrade = Grade(raw.itemGrade or raw.grade or tonumber((key:gsub("^-?%d+:(-?%d+)$", "%1"))))
            local price = tonumber(raw.price)
            if itemType ~= nil and price ~= nil and price == price and price > 0 then
                local normalizedKey = Key(itemType, itemGrade)
                out[normalizedKey] = {
                    itemType = itemType,
                    itemGrade = itemGrade,
                    price = math.floor(price),
                    observedMinute = tonumber(raw.observedMinute) and math.floor(tonumber(raw.observedMinute)) or nil,
                    source = tostring(raw.source or "unknown"),
                    samples = NormalizeSamples(raw.samples, M.maxSamples),
                    candidatePrice = tonumber(raw.candidatePrice) and math.floor(tonumber(raw.candidatePrice)) or nil,
                    candidateCount = math.max(0, math.floor(tonumber(raw.candidateCount) or 0)),
                    candidateObservedMinute = tonumber(raw.candidateObservedMinute) and math.floor(tonumber(raw.candidateObservedMinute)) or nil,
                }
                count = count + 1
            end
        end
    end
    return out
end

local function EntryCount(entries)
    local count = 0; for _ in pairs(type(entries) == "table" and entries or {}) do count = count + 1 end; return count
end

function M:_EnsureStoreRegistered()
    local P = S.Persistence
    if type(P) ~= "table" or type(P.RegisterV3Store) ~= "function" then return false, "persistence_unavailable" end
    if P:GetStore(self.StoreId) ~= nil then return true end
    local store, err = P:RegisterV3Store({
        id = self.StoreId,
        owner = "v3.market.material_prices",
        scope = P.Scope.Account,
        lifetime = P.Lifetime.Permanent,
        schemaVersion = 1,
        legacySchemaVersion = 0,
        key = (P.V3KeyPrefix or "") .. "market_material_prices",
        budget = { maxDepth = 6, maxNodes = 12000, maxStringBytes = 24000, maxEntriesPerTable = 512 },
        -- 维护（material-price-cache-recovery-1）：仅此派生缓存允许“损坏后全量替换”。
        -- Persistence 仍要求 replaceCorrupt + durable readback，普通 Save/MarkDirty 不能借此绕过 Fence。
        recoverableReplacement = true,
        default = function() return { entries = {}, contractVersion = M.StoreContractVersion } end,
        get = function()
            local entries = {}; for key, entry in pairs(M.entries or {}) do entries[key] = Copy(entry) end
            return { entries = entries, contractVersion = M.StoreContractVersion }
        end,
        apply = function(value) M.entries = NormalizeEntries(value) end,
        migrate = function(value) return { entries = NormalizeEntries(value), contractVersion = M.StoreContractVersion } end,
    })
    if store == nil then return false, tostring(err or "store_register_failed") end
    return true
end

function M:_MarkDirty(reason)
    local P = S.Persistence
    if type(P) == "table" and type(P.MarkDirty) == "function" then
        P:MarkDirty(self.StoreId, 1200, tostring(reason or "material_price_update"))
        return true
    end
    return false
end

function M:_ImportLegacyReferencePrices()
    if self.legacyImported == true then return 0 end
    self.legacyImported = true
    if EntryCount(self.entries) > 0 then return 0 end
    local queue = S.Services and S.Services.PriceQuoteQueueV3 or nil
    if type(queue) ~= "table" or type(queue.EnsureStoreLoaded) ~= "function" then return 0 end
    local ok = queue:EnsureStoreLoaded()
    if ok ~= true then return 0 end
    local imported = 0
    for key, legacy in pairs(type(queue.referencePrices) == "table" and queue.referencePrices or {}) do
        if imported >= self.maxEntries then break end
        if type(legacy) == "table" then
            local itemType = PositiveInt(legacy.itemType or tonumber((tostring(key):gsub("^(-?%d+):.*$", "%1"))))
            local itemGrade = Grade(legacy.grade or tonumber((tostring(key):gsub("^-?%d+:(-?%d+)$", "%1"))))
            local price = tonumber(legacy.price)
            if itemType ~= nil and price ~= nil and price > 0 then
                local newKey = Key(itemType, itemGrade)
                self.entries[newKey] = {
                    itemType = itemType, itemGrade = itemGrade, price = math.floor(price),
                    -- Legacy updatedAt used NowMs and cannot survive reload; keep the
                    -- price but deliberately mark age unknown so SWR refreshes it.
                    observedMinute = nil,
                    source = "legacy:" .. tostring(legacy.source or "reference"),
                    samples = NormalizeSamples(legacy.samples, self.maxSamples),
                    candidatePrice = nil, candidateCount = 0, candidateObservedMinute = nil,
                }
                imported = imported + 1
            end
        end
    end
    if imported > 0 then
        self.stats.imported = (tonumber(self.stats.imported) or 0) + imported
        self.revision = self.revision + 1
        self:_MarkDirty("legacy_reference_import")
    end
    return imported
end

local function IsRecoverableCacheIntegrityFailure(reason)
    reason = tostring(reason or "")
    return reason:find("^integrity_failed:fingerprint_mismatch:") ~= nil
end

function M:_RecoverCorruptDerivedCache(loadErr)
    if IsRecoverableCacheIntegrityFailure(loadErr) ~= true then return false, "not_recoverable_cache_failure" end
    local P = S.Persistence
    local store = type(P) == "table" and type(P.GetStore) == "function" and P:GetStore(self.StoreId) or nil
    if type(store) ~= "table" or store.writeFenced ~= true
        or tostring(store.writeFenceReason or ""):find("^integrity_failed:fingerprint_mismatch:") == nil then
        return false, "persistence_fence_not_eligible"
    end
    if type(P.SaveValue) ~= "function" then return false, "save_value_unavailable" end

    self.cacheRecoveryAttempts = (tonumber(self.cacheRecoveryAttempts) or 0) + 1
    self.lastCacheRecoveryAt = NowMs()
    self.lastCacheRecoveryReason = tostring(loadErr or store.writeFenceReason or "integrity_failed")

    -- Authority 边界：这里只丢弃 MaterialPriceService 自己的可再生价格缓存。Trade 路线、收藏、
    -- 用户配置、QuoteQueue 会话状态都不在这个 Store 中；因此不能把该策略泛化到其它 Store。
    local replacement = { entries = {}, contractVersion = self.StoreContractVersion }
    local ok, saveErr = P:SaveValue(self.StoreId, replacement, {
        replaceCorrupt = true, durable = true, allowUnloadedWrite = true,
        reason = "material_price_cache_integrity_rebuild",
    })
    if ok ~= true then
        self.cacheRecoveryFailures = (tonumber(self.cacheRecoveryFailures) or 0) + 1
        self.lastCacheRecoveryError = tostring(saveErr or "cache_replacement_failed")
        return false, self.lastCacheRecoveryError
    end

    self.entries = {}
    self.storeLoaded = true
    self.legacyImported = false
    self.lastStoreLoadError = nil
    self.nextStoreLoadRetryAt = 0
    self.lastCacheRecoveryError = nil
    self.cacheRecoverySuccesses = (tonumber(self.cacheRecoverySuccesses) or 0) + 1
    -- 若旧 PriceQuoteQueue 仍有通过自己 Store 校验的参考价，可在空缓存恢复后重新播种；
    -- 失败只意味着保持空缓存，绝不能让恢复路径重新依赖拍卖 Native 查询。
    self:_ImportLegacyReferencePrices()
    return true, "derived_cache_rebuilt"
end

function M:EnsureStoreLoaded(force)
    if self.storeLoaded == true then return true end
    local now = NowMs()
    local retryAt = tonumber(self.nextStoreLoadRetryAt) or 0
    if force ~= true and retryAt > 0 and now < retryAt then
        self.storeLoadBackoffHits = (tonumber(self.storeLoadBackoffHits) or 0) + 1
        return false, tostring(self.lastStoreLoadError or "store_load_backoff")
    end

    self.storeLoadAttempts = (tonumber(self.storeLoadAttempts) or 0) + 1
    self.lastStoreLoadAt = now

    local function Fail(reason)
        reason = tostring(reason or "store_load_failed")
        self.storeLoadFailures = (tonumber(self.storeLoadFailures) or 0) + 1
        self.lastStoreLoadError = reason
        self.nextStoreLoadRetryAt = now + math.max(1000, tonumber(self.storeLoadRetryMs) or 5000)
        return false, reason
    end

    local ok, regErr = self:_EnsureStoreRegistered()
    if ok ~= true then return Fail(regErr) end
    local P = S.Persistence
    if type(P.LoadStore) ~= "function" then return Fail("load_unavailable") end
    local status, _, err = P:LoadStore(self.StoreId)
    if status ~= true and status ~= "empty" then
        local loadErr = tostring(err or status or "store_load_failed")
        -- 维护（material-price-cache-recovery-1）：当前实机证据为
        -- integrity_failed:fingerprint_mismatch:4EE70972>3697A407。货率 Fast Path 已正常，真正
        -- 剩余故障是派生材料价缓存被永久 Fence。该缓存可重建，因此只在 Persistence 已明确
        -- 给出 current-schema fingerprint mismatch 时尝试一次 durable verified replacement；
        -- transient LoadData/未来 schema/metadata/envelope 等错误仍进入 Fail + backoff，不覆盖磁盘。
        local recovered, recoverErr = self:_RecoverCorruptDerivedCache(loadErr)
        if recovered == true then return true end
        if IsRecoverableCacheIntegrityFailure(loadErr) == true and recoverErr ~= "not_recoverable_cache_failure" then
            loadErr = loadErr .. "|cache_recovery=" .. tostring(recoverErr or "failed")
        end
        return Fail(loadErr)
    end
    local stored = P.GetStore and P:GetStore(self.StoreId) or nil
    if type(stored) == "table" and type(stored.value) == "table" then
        self.entries = NormalizeEntries(stored.value.entries or stored.value)
    end
    self.storeLoaded = true
    self.lastStoreLoadError = nil
    self.nextStoreLoadRetryAt = 0
    self:_ImportLegacyReferencePrices()
    return true
end

function M:GetRevision() return tonumber(self.revision) or 0 end

function M:_Freshness(entry, key)
    if type(entry) ~= "table" then return "missing", nil, true end
    local nowMinute = ServerMinuteStamp()
    local observed = tonumber(entry.observedMinute)
    if nowMinute == nil or observed == nil or nowMinute < observed then
        -- 维护（2026-09-25，material-price-session-freshness-1）：服务器日历在 UI reload 初期可能暂不可读。
        -- 刚刚由本 generation 成功确认的报价不能因此立刻变成 unknown 并在每次路线重建时重复入队。
        -- sessionObservedAtMs 只解决当前加载期短窗口；持久化跨天年龄仍只相信 server wall-clock minute stamp。
        local acceptedAt = key ~= nil and tonumber(self.sessionObservedAtMs[key]) or nil
        local now = NowMs()
        if acceptedAt ~= nil and now >= acceptedAt then
            local ageMinutes = math.floor((now - acceptedAt) / 60000)
            if ageMinutes < self.freshMinutes then return "fresh", ageMinutes, false end
        end
        return "unknown", nil, true
    end
    local age = math.max(0, nowMinute - observed)
    if age < self.freshMinutes then return "fresh", age, false end
    if age < self.warmMinutes then return "warm", age, true end
    if age < self.staleMinutes then return "stale", age, true end
    return "old", age, true
end

function M:GetPrice(itemType, itemGrade)
    self.stats.reads = (tonumber(self.stats.reads) or 0) + 1
    local loaded, loadErr = self:EnsureStoreLoaded()
    if loaded ~= true then
        self.stats.misses = (tonumber(self.stats.misses) or 0) + 1
        return nil, {
            freshness = "missing", needsRefresh = true, storeUnavailable = true,
            error = tostring(loadErr or self.lastStoreLoadError or "store_unavailable"),
        }
    end
    local key = Key(itemType, itemGrade)
    local entry = key ~= nil and self.entries[key] or nil
    if type(entry) ~= "table" then
        self.stats.misses = (tonumber(self.stats.misses) or 0) + 1
        return nil, { freshness = "missing", needsRefresh = true, refreshing = key ~= nil and self.refreshPending[key] == true or false }
    end
    self.stats.hits = (tonumber(self.stats.hits) or 0) + 1
    local freshness, ageMinutes, needsRefresh = self:_Freshness(entry, key)
    return tonumber(entry.price), {
        itemType = entry.itemType, itemGrade = entry.itemGrade,
        source = entry.source, freshness = freshness, ageMinutes = ageMinutes,
        observedMinute = entry.observedMinute, needsRefresh = needsRefresh,
        refreshing = self.refreshPending[key] == true,
        samples = Copy(entry.samples or {}),
        candidatePrice = entry.candidatePrice, candidateCount = entry.candidateCount,
    }
end

local function TrustedSource(source)
    source = tostring(source or "")
    if source == "name_search_direct_unit" then return true end
    if source:find("^market_price:") ~= nil then return true end
    return false
end

local function SimilarPrice(a, b, tolerance)
    a, b = tonumber(a), tonumber(b)
    if a == nil or b == nil or a <= 0 or b <= 0 then return false end
    return math.abs(a - b) / math.max(a, b) <= (tonumber(tolerance) or 0.15)
end

function M:ObserveConfirmedPrice(itemType, itemGrade, price, source)
    itemType = PositiveInt(itemType); itemGrade = Grade(itemGrade); price = tonumber(price)
    source = tostring(source or "")
    if itemType == nil or price == nil or price ~= price or price <= 0 then return false, "invalid_price" end
    if TrustedSource(source) ~= true then return false, "untrusted_source" end
    if self:EnsureStoreLoaded() ~= true then return false, "store_unavailable" end
    local key = Key(itemType, itemGrade)
    local entry = self.entries[key]
    local rounded = math.floor(price)
    local nowMinute = ServerMinuteStamp()

    if type(entry) == "table" and tonumber(entry.price) ~= nil and tonumber(entry.price) > 0 then
        local previous = tonumber(entry.price)
        local ratio = math.max(previous, rounded) / math.max(1, math.min(previous, rounded))
        if ratio >= self.anomalyRatio then
            -- 维护（2026-09-28，material-price-anomaly-jump-1）：跳变方向必须区分。若新价其实是回到了
            -- **已知历史样本区间**内，那它是“回归正常”，不是“新的市场常态”，必须立即采纳 —— 否则一旦
            -- 被“缺货一次性高价”污染（本例 559→1499），之后修正价又会因为 2.68 倍同样越限而被反复挡在
            -- 候选区，玩家要询价两次才看到正确毛利。只有“越限且与所有已知样本都不相似”才是真正的候选。
            local revertedToKnown = false
            for _, sample in ipairs(type(entry.samples) == "table" and entry.samples or {}) do
                local samplePrice = tonumber(type(sample) == "table" and sample.price or sample)
                if SimilarPrice(samplePrice, rounded, self.anomalyConfirmTolerance) then
                    revertedToKnown = true
                    break
                end
            end
            if revertedToKnown == true then
                self.stats.anomalyRevertedToKnown = (tonumber(self.stats.anomalyRevertedToKnown) or 0) + 1
            elseif entry.candidatePrice ~= nil and SimilarPrice(entry.candidatePrice, rounded, self.anomalyConfirmTolerance) then
                entry.candidateCount = (tonumber(entry.candidateCount) or 1) + 1
                self.stats.anomalyConfirmed = (tonumber(self.stats.anomalyConfirmed) or 0) + 1
                -- second consistent observation confirms the market regime change
            else
                entry.candidatePrice = rounded
                entry.candidateCount = 1
                entry.candidateObservedMinute = nowMinute
                self.stats.anomalyHeld = (tonumber(self.stats.anomalyHeld) or 0) + 1
                self:_MarkDirty("material_price_anomaly_candidate")
                return false, "anomaly_candidate_held"
            end
        end
    end

    local samples = {}
    if type(entry) == "table" and tonumber(entry.price) ~= nil and tonumber(entry.price) > 0 then
        samples[#samples + 1] = { price = math.floor(tonumber(entry.price)), observedMinute = tonumber(entry.observedMinute) }
        for index = 1, math.min(self.maxSamples - 1, #(entry.samples or {})) do
            local sample = entry.samples[index]
            if type(sample) == "table" and tonumber(sample.price) ~= nil and tonumber(sample.price) > 0 then
                samples[#samples + 1] = { price = math.floor(tonumber(sample.price)), observedMinute = tonumber(sample.observedMinute) }
            end
        end
    end
    self.entries[key] = {
        itemType = itemType, itemGrade = itemGrade, price = rounded,
        observedMinute = nowMinute, source = source, samples = samples,
        candidatePrice = nil, candidateCount = 0, candidateObservedMinute = nil,
    }
    self.refreshPending[key] = nil
    self.sessionObservedAtMs[key] = NowMs()
    self.revision = self.revision + 1
    self.stats.writes = (tonumber(self.stats.writes) or 0) + 1
    self:_MarkDirty("material_price_confirmed")
    if S.Events ~= nil and type(S.Events.Publish) == "function" then
        S.Events:Publish(self.Topic, itemType, itemGrade, rounded, {
            source = source, freshness = "fresh", ageMinutes = 0,
            revision = self.revision, observedMinute = nowMinute,
        })
    end
    return true
end

function M:RequestRevalidate(material, options)
    material = type(material) == "table" and material or {}
    options = type(options) == "table" and options or {}
    local loaded, loadErr = self:EnsureStoreLoaded()
    if loaded ~= true then
        self.stats.backgroundStoreUnavailable = (tonumber(self.stats.backgroundStoreUnavailable) or 0) + 1
        return false, "store_unavailable:" .. tostring(loadErr or "unknown")
    end
    local itemType = PositiveInt(material.itemType)
    local itemGrade = Grade(material.itemGrade)
    if itemType == nil then return false, "invalid_item_type" end
    local key = Key(itemType, itemGrade)
    local price, meta = self:GetPrice(itemType, itemGrade)
    if options.force ~= true and price ~= nil and meta.freshness == "fresh" then
        self.stats.backgroundSkippedFresh = (tonumber(self.stats.backgroundSkippedFresh) or 0) + 1
        return true, "fresh"
    end
    if self.refreshPending[key] == true then
        self.stats.backgroundJoined = (tonumber(self.stats.backgroundJoined) or 0) + 1
        return true, "pending"
    end
    local now = NowMs()
    local lastAttempt = tonumber(self.lastRefreshAttemptMs[key]) or -1000000000
    if options.force ~= true and now >= lastAttempt and (now - lastAttempt) < self.backgroundRetryMs then return true, "retry_throttled" end
    local queue = S.Services and S.Services.PriceQuoteQueueV3 or nil
    if type(queue) ~= "table" or type(queue.RequestQuote) ~= "function" then return false, "price_quote_queue_unavailable" end
    self.lastRefreshAttemptMs[key] = now
    self.refreshPending[key] = true
    local requester = "material_price:bg:" .. key
    local searchName = tostring(material.searchName or material.name or "")
    if searchName == "" then searchName = nil end
    local ok, err = queue:RequestQuote(requester, itemType, itemGrade, function(snapshot)
        M.refreshPending[key] = nil
        if type(snapshot) ~= "table" or tostring(snapshot.status or "") ~= "ready" then
            M.stats.backgroundFailed = (tonumber(M.stats.backgroundFailed) or 0) + 1
        end
    end, { itemGrade }, {
        searchName = searchName,
        force = true,
        priority = "background",
        background = true,
    })
    if ok ~= true then
        self.refreshPending[key] = nil
        self.stats.backgroundFailed = (tonumber(self.stats.backgroundFailed) or 0) + 1
        return false, err
    end
    self.stats.backgroundSubmitted = (tonumber(self.stats.backgroundSubmitted) or 0) + 1
    return true, err or "queued"
end

function M:QueueRevalidate(materials, options)
    materials = type(materials) == "table" and materials or {}
    options = type(options) == "table" and options or {}
    -- 维护（material-price-store-backoff-1）：自动 SWR 只有在自己的持久价格 Authority 可用时才有意义。
    -- Store 不可用时继续向共享拍卖队列灌 background 请求，结果也无法落进本服务，会在每次路线重建后重复制造
    -- pending/miss。这里 fail-soft：停止自动后台 admission；用户双击的显式 QuoteRowMaterials 仍走 QuoteQueue，
    -- Trade 投影也会回退它的会话报价，因此不会牺牲手动查询能力。
    local loaded, loadErr = self:EnsureStoreLoaded()
    if loaded ~= true then
        self.stats.backgroundStoreUnavailable = (tonumber(self.stats.backgroundStoreUnavailable) or 0) + 1
        return false, {
            candidates = 0, submitted = 0, skipped = 0, failed = 0,
            limit = math.max(1, math.min(self.maxBackgroundPerAdmission, math.floor(tonumber(options.maxItems) or self.maxBackgroundPerAdmission))),
            storeUnavailable = true, error = tostring(loadErr or "store_unavailable"),
        }
    end
    local unique, candidates = {}, {}
    local rank = { missing = 1, old = 2, unknown = 3, stale = 4, warm = 5, fresh = 99 }
    for _, material in ipairs(materials) do
        if type(material) == "table" then
            local itemType, itemGrade = PositiveInt(material.itemType), Grade(material.itemGrade)
            local key = itemType and Key(itemType, itemGrade) or nil
            if key ~= nil and unique[key] == nil and material.auctionable ~= false and material.includeInCost ~= false then
                unique[key] = true
                local _, meta = self:GetPrice(itemType, itemGrade)
                local freshness = tostring(meta and meta.freshness or "missing")
                if options.force == true or freshness ~= "fresh" then
                    candidates[#candidates + 1] = {
                        itemType = itemType, itemGrade = itemGrade,
                        name = material.name, searchName = material.searchName or material.name,
                        freshness = freshness, rank = rank[freshness] or 50,
                    }
                end
            end
        end
    end
    table.sort(candidates, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        if a.itemType ~= b.itemType then return a.itemType < b.itemType end
        return a.itemGrade < b.itemGrade
    end)
    local limit = math.max(1, math.min(self.maxBackgroundPerAdmission, math.floor(tonumber(options.maxItems) or self.maxBackgroundPerAdmission)))
    local submitted, skipped, failed = 0, 0, 0
    for index = 1, math.min(limit, #candidates) do
        local ok, state = self:RequestRevalidate(candidates[index], options)
        if ok == true and state ~= "fresh" and state ~= "retry_throttled" and state ~= "pending" then submitted = submitted + 1
        elseif ok == true then skipped = skipped + 1
        else failed = failed + 1 end
    end
    return true, { candidates = #candidates, submitted = submitted, skipped = skipped, failed = failed, limit = limit }
end

function M:Describe()
    self:EnsureStoreLoaded()
    local freshness = { fresh = 0, warm = 0, stale = 0, old = 0, unknown = 0 }
    local count, pending = 0, 0
    for key, entry in pairs(self.entries or {}) do
        count = count + 1
        local state = self:_Freshness(entry, key)
        freshness[state] = (tonumber(freshness[state]) or 0) + 1
        if self.refreshPending[key] == true then pending = pending + 1 end
    end
    return {
        version = self.version, contractVersion = self.ContractVersion,
        storeId = self.StoreId, storeLoaded = self.storeLoaded == true,
        storeLoadAttempts = tonumber(self.storeLoadAttempts) or 0,
        storeLoadFailures = tonumber(self.storeLoadFailures) or 0,
        storeLoadBackoffHits = tonumber(self.storeLoadBackoffHits) or 0,
        lastStoreLoadAt = tonumber(self.lastStoreLoadAt) or 0,
        lastStoreLoadError = self.lastStoreLoadError,
        nextStoreLoadRetryInMs = math.max(0, (tonumber(self.nextStoreLoadRetryAt) or 0) - NowMs()),
        cacheRecoveryAttempts = tonumber(self.cacheRecoveryAttempts) or 0,
        cacheRecoverySuccesses = tonumber(self.cacheRecoverySuccesses) or 0,
        cacheRecoveryFailures = tonumber(self.cacheRecoveryFailures) or 0,
        lastCacheRecoveryAt = tonumber(self.lastCacheRecoveryAt) or 0,
        lastCacheRecoveryReason = self.lastCacheRecoveryReason,
        lastCacheRecoveryError = self.lastCacheRecoveryError,
        entries = count, revision = self.revision,
        freshness = freshness, refreshPending = pending,
        thresholdsMinutes = { fresh = self.freshMinutes, warm = self.warmMinutes, stale = self.staleMinutes },
        stats = Copy(self.stats),
    }
end

-- Replicated Suite · 材料参考价格
-- 作者：Replicated
-- QQ群：1104129461
-- 保存材料参考单价、年龄和异常候选；Native 串行查询由 PriceQuoteQueueV3 执行。
-- GetPrice 只读本地，显式 QueueRevalidate 加入后台队列，确认后发布 changed 失效读模型。
-- 年龄用服务器分钟，不能用重载归零的 NowMs；旧价可先显示并标 stale，再后台刷新。
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
    -- Foundation 要求每个 Service 声明 presentationBoundary；本服务无 UI，属于 service_only。
    presentationBoundary = "service_only",
    entries = {},
    revision = 0,
    storeLoaded = false,
    legacyImported = false,
    -- Store 加载失败后只在固定边沿重试，不能每行 GetPrice 都重读；显式报价仍可用 Queue 会话缓存。
    storeLoadRetryMs = 5000,
    storeLoadAttempts = 0,
    storeLoadFailures = 0,
    storeLoadBackoffHits = 0,
    lastStoreLoadAt = 0,
    lastStoreLoadError = nil,
    nextStoreLoadRetryAt = 0,
    -- 价格是可再生缓存；仅 Persistence 确认当前 schema 指纹不符时，允许一次空缓存完整替换并耐久回读。
    -- LoadData 失败、未来 schema、scope 等错误仍隔离，不能套用到用户配置 Store。
    cacheRecoveryAttempts = 0,
    cacheRecoverySuccesses = 0,
    cacheRecoveryFailures = 0,
    lastCacheRecoveryAt = 0,
    lastCacheRecoveryError = nil,
    lastCacheRecoveryReason = nil,
    -- Trade SWR 使用的新鲜度策略，旧价格仍可读取。
    freshMinutes = 6 * 60,
    warmMinutes = 24 * 60,
    staleMinutes = 7 * 24 * 60,
    maxEntries = 512,
    maxSamples = 6,
    maxBackgroundPerAdmission = 12,
    backgroundRetryMs = 60000,
    -- 缺货时单条高价可能污染成本：30901 捣碎香料曾从 559 铜跳到 1499（2.68倍），让配方毛利由正变负。
    -- 超过 2.5 倍先记候选，第二次一致观察才落库；真实市场突变会晚一个观察周期生效。
    anomalyRatio = 2.5,
    anomalyConfirmTolerance = 0.15,
    refreshPending = {},
    -- 后台请求须有 owner，末 owner 离开才解绑 watcher；不能取消其它 Feature 的需求。
    refreshRequests = {},
    backgroundBlockReason = nil,
    backgroundInteractionPatch = "auction-full-lane-safety-1",
    lastRefreshAttemptMs = {},
    -- 会话接受时钟：UI 重载后服务器时间可暂不可用，本代际已确认报价仍视为新鲜，避免每次重建重新排队。此表不
    -- 持久化，多日年龄始终来自 observedMinute。
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
    -- 公历序数日公式跨插件重载稳定，不依赖 ArcheAge Lua 沙盒未保证的 os.time。
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
        -- 仅此派生缓存允许“损坏后全量替换”。
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
                    -- 旧 updatedAt 使用 NowMs，无法跨重载；保留价格但年龄明确未知，由 SWR 刷新。
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

    -- 这里只丢弃本服务的可再生价格缓存，不含路线、收藏或用户配置，不能泛化到其它 Store。
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
        -- 只对当前 schema 指纹不符尝试一次耐久完整替换；其它读盘/元数据错误保留隔离并退避。
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
        -- material-price-session-freshness-1：日历暂缺时用本次加载内的报价时间，避免重复排队；跨天年龄仍以服务器分钟为准。
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

-- 跑商缓存有效窗为七天；不改变共享 Store/schema 或其它消费者政策。
-- Store 故障时只回退本 generation 的真实 session 观察，不能复活无年龄的旧 reference。
local function SortDependentSource(source)
    return tostring(source or ""):gsub("^legacy:", "") == "name_search_direct_unit"
end
function M:GetTradePrice(itemType, itemGrade)
    local price, meta = self:GetPrice(itemType, itemGrade)
    -- （2026-10-07）旧来源无法区分“首条高价”与完整最低价，不再进入跑商成本。
    -- 仅改变读取政策，保留历史 payload/canonical；用户重新询价后由可信新观察替换该条。
    if meta and SortDependentSource(meta.source) then
        meta.sortUnverified, meta.needsRefresh, meta.freshness = true, true, "sort_unverified"
        meta.previousReferencePrice = price
        return nil, meta
    end
    if price ~= nil and (meta.freshness == "fresh" or meta.freshness == "warm" or meta.freshness == "stale") then return price, meta end
    local queue = S.Services and S.Services.PriceQuoteQueueV3
    local current, source, completedAt
    if queue and type(queue.GetPriceByItemType) == "function" then current, source, completedAt = queue:GetPriceByItemType(itemType, itemGrade) end
    if tonumber(current) and tonumber(completedAt) and not tostring(source or ""):match("^reference:") and not SortDependentSource(source) then
        local age = NowMs() - completedAt
        if age >= 0 and age < self.freshMinutes * 60000 then
            return current, { freshness = "fresh", ageMinutes = math.floor(age / 60000), source = source, needsRefresh = false }
        end
    end
    return nil, meta or { freshness = "missing", needsRefresh = true }
end

-- 报价传输只发一次；价格接受/候选隔离仍经 Queue 的既有 RecordReferencePrice 单一入口。
function M:RequestQuoteOnce(material, callback, options)
    options = type(options) == "table" and options or {}
    local queue = S.Services and S.Services.PriceQuoteQueueV3
    if not queue or type(queue.RequestQuote) ~= "function" then return false, "price_quote_queue_unavailable" end
    return queue:RequestQuote(options.requester, material.itemType, material.itemGrade, callback, { material.itemGrade }, {
        searchName = material.searchName or material.name, singleQuery = true,
        -- 跑商显式传递有界排队期限；共享 Queue 拥有发包后五秒计时，价格层不计时。
        priority = options.priority or "user", deadlineAt = options.deadlineAt, waitForDispatch = options.waitForDispatch == true,
    })
end

local function TrustedSource(source)
    source = tostring(source or "")
    if source == "name_search_direct_unit" or source == "name_search_min_direct_unit"
        or source == "name_search_sampled_direct_unit" or source == "name_search_sampled_lower_unit" then return true end
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
    local replacesUnverified = (source == "name_search_min_direct_unit"
        or source == "name_search_sampled_direct_unit" or source == "name_search_sampled_lower_unit")
        and type(entry) == "table" and SortDependentSource(entry.source)

    if not replacesUnverified and type(entry) == "table" and tonumber(entry.price) ~= nil and tonumber(entry.price) > 0 then
        local previous = tonumber(entry.price)
        local ratio = math.max(previous, rounded) / math.max(1, math.min(previous, rounded))
        if ratio >= self.anomalyRatio then
            -- 回到已知历史样本区间的价格立即接受；否则高价污染后的正常回落也会被跳变阈值拦住。
            -- 仅越限且不接近任何已知样本时进入新候选。
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
                -- 第二次一致观察确认市场行情变化。
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
    if not replacesUnverified and type(entry) == "table" and tonumber(entry.price) ~= nil and tonumber(entry.price) > 0 then
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

-- unknown 到达明确 blocked 后，不允许下一次货率刷新
-- 每60秒复活同一批后台任务。仅现有调用边沿检查恢复证据，不新建 Tick，不清价格、不伪造失败价。
function M:_CanResumeBlockedRevalidation()
    if self.backgroundBlockReason == nil then return true end
    local queue = S.Services and S.Services.PriceQuoteQueueV3 or nil
    if type(queue) == "table" and type(queue.CanNativeQuote) == "function" then
        local allowed = queue:CanNativeQuote()
        if allowed == true then self.backgroundBlockReason = nil; return true end
    end
    self.stats.backgroundSuppressed = (tonumber(self.stats.backgroundSuppressed) or 0) + 1
    return false
end

function M:CancelRevalidationOwner(owner)
    owner = tostring(owner or "material_price")
    local queue = S.Services and S.Services.PriceQuoteQueueV3 or nil
    local cancelled = 0
    for key, request in pairs(self.refreshRequests) do
        request.owners[owner] = nil
        if next(request.owners) == nil then
            -- 先撤销本地请求身份，晚到/重入回调不能清掉同材料下一代请求。
            self.refreshRequests[key], self.refreshPending[key] = nil, nil
            if queue and type(queue.CancelRequester) == "function" then queue:CancelRequester(request.requester) end
            cancelled = cancelled + 1
        end
    end
    self.stats.backgroundCancelled = (tonumber(self.stats.backgroundCancelled) or 0) + cancelled
    return true, cancelled
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
    local owner = tostring(options.owner or "material_price")
    if self.refreshPending[key] == true then
        local request = self.refreshRequests[key]
        if request ~= nil then request.owners[owner] = true end
        self.stats.backgroundJoined = (tonumber(self.stats.backgroundJoined) or 0) + 1
        return true, "pending"
    end
    if self:_CanResumeBlockedRevalidation() ~= true then return true, "interaction_blocked" end
    local now = NowMs()
    local lastAttempt = tonumber(self.lastRefreshAttemptMs[key]) or -1000000000
    if options.force ~= true and now >= lastAttempt and (now - lastAttempt) < self.backgroundRetryMs then return true, "retry_throttled" end
    local queue = S.Services and S.Services.PriceQuoteQueueV3 or nil
    if type(queue) ~= "table" or type(queue.RequestQuote) ~= "function" then return false, "price_quote_queue_unavailable" end
    self.lastRefreshAttemptMs[key] = now
    self.refreshPending[key] = true
    local requester = "material_price:bg:" .. key
    local request = { requester = requester, owners = { [owner] = true } }
    self.refreshRequests[key] = request
    local searchName = tostring(material.searchName or material.name or "")
    if searchName == "" then searchName = nil end
    local ok, err = queue:RequestQuote(requester, itemType, itemGrade, function(snapshot)
        if M.refreshRequests[key] ~= request then return end
        M.refreshRequests[key], M.refreshPending[key] = nil, nil
        if type(snapshot) == "table" and snapshot.status == "blocked"
            and snapshot.blockReason == "native_auction_visibility_unknown" then
            M.backgroundBlockReason = snapshot.blockReason
        end
        if type(snapshot) ~= "table" or tostring(snapshot.status or "") ~= "ready" then
            M.stats.backgroundFailed = (tonumber(M.stats.backgroundFailed) or 0) + 1
        end
    end, { itemGrade }, {
        searchName = searchName,
        force = true,
        priority = "background",
        background = true,
        singleQuery = options.singleQuery == true,
    })
    if ok ~= true then
        if self.refreshRequests[key] == request then self.refreshRequests[key], self.refreshPending[key] = nil, nil end
        self.stats.backgroundFailed = (tonumber(self.stats.backgroundFailed) or 0) + 1
        return false, err
    end
    self.stats.backgroundSubmitted = (tonumber(self.stats.backgroundSubmitted) or 0) + 1
    return true, err or "queued"
end

function M:QueueRevalidate(materials, options)
    materials = type(materials) == "table" and materials or {}
    options = type(options) == "table" and options or {}
    -- Store 不可用时停自动 SWR，否则每次重建都产生无法落库的重复请求。
    -- 用户显式询价仍走 Queue，并可显示会话价格。
    local loaded, loadErr = self:EnsureStoreLoaded()
    if loaded ~= true then
        self.stats.backgroundStoreUnavailable = (tonumber(self.stats.backgroundStoreUnavailable) or 0) + 1
        return false, {
            candidates = 0, submitted = 0, skipped = 0, failed = 0,
            limit = math.max(1, math.min(self.maxBackgroundPerAdmission, math.floor(tonumber(options.maxItems) or self.maxBackgroundPerAdmission))),
            storeUnavailable = true, error = tostring(loadErr or "store_unavailable"),
        }
    end
    if self:_CanResumeBlockedRevalidation() ~= true then
        return true, { candidates = 0, submitted = 0, skipped = 0, failed = 0,
            interactionBlocked = true, blockReason = self.backgroundBlockReason }
    end
    local unique, candidates = {}, {}
    local rank = options.cachedOnly == true and { warm = 1, stale = 2, fresh = 99 }
        or { missing = 1, old = 2, unknown = 3, stale = 4, warm = 5, fresh = 99 }
    for _, material in ipairs(materials) do
        if type(material) == "table" then
            local itemType, itemGrade = PositiveInt(material.itemType), Grade(material.itemGrade)
            local key = itemType and Key(itemType, itemGrade) or nil
            if key ~= nil and unique[key] == nil and material.auctionable ~= false and material.includeInCost ~= false then
                unique[key] = true
                local _, meta = self:GetPrice(itemType, itemGrade)
                local freshness = tostring(meta and meta.freshness or "missing")
                if (options.cachedOnly ~= true and (options.force == true or freshness ~= "fresh"))
                    or (options.cachedOnly == true and (freshness == "warm" or freshness == "stale")) then
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
        if ok == true and state ~= "fresh" and state ~= "retry_throttled" and state ~= "pending" and state ~= "interaction_blocked" then submitted = submitted + 1
        elseif ok == true then skipped = skipped + 1
        else failed = failed + 1 end
    end
    return true, { candidates = #candidates, submitted = submitted, skipped = skipped, failed = failed, limit = limit }
end

function M:Describe()
    -- 诊断不能发起首次存档加载/迁移；只报告最近已经采样的事实。
    local freshness = { fresh = 0, warm = 0, stale = 0, old = 0, unknown = 0 }
    local count, pending, sortUnverified = 0, 0, 0
    -- 缺价材料尚无 entries，但仍可能占着 pending；不能只遍历 entries 得出0。
    for _, active in pairs(self.refreshPending or {}) do if active == true then pending = pending + 1 end end
    for key, entry in pairs(self.entries or {}) do
        count = count + 1
        local state = self:_Freshness(entry, key)
        freshness[state] = (tonumber(freshness[state]) or 0) + 1
        if SortDependentSource(entry.source) then sortUnverified = sortUnverified + 1 end
    end
    return {
        version = self.version, contractVersion = self.ContractVersion, requotePatch = "trade-requote-2",
        sortPatch = "auction-three-sample-1", tradeSortUnverifiedEntries = sortUnverified,
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
        backgroundInteractionPatch = self.backgroundInteractionPatch, backgroundBlockReason = self.backgroundBlockReason,
        freshness = freshness, refreshPending = pending,
        thresholdsMinutes = { fresh = self.freshMinutes, warm = self.warmMinutes, stale = self.staleMinutes },
        stats = Copy(self.stats),
    }
end

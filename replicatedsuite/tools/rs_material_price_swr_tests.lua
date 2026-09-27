-- Replicated Suite .18.317 MaterialPriceServiceV3 runtime regression.
-- Pure Lua: no ArcheRage Native API. It validates persistence/freshness/anomaly/background-admission semantics.
local root = (... and tostring(...)) or "."

local server = { year = 2026, month = 9, day = 25, hour = 15, minute = 0 }
local nowMs = 1000
local published = {}
local queued = {}
local savedValue = nil

local function DeepCopy(value)
    if type(value) ~= "table" then return value end
    local out = {}; for k, v in pairs(value) do out[k] = DeepCopy(v) end; return out
end

local function NewPersistence(initial)
    local stores = {}
    return {
        Scope = { Account = "account" }, Lifetime = { Permanent = "permanent" }, V3KeyPrefix = "test:",
        GetStore = function(self, id) return stores[id] end,
        RegisterV3Store = function(self, spec)
            local value = initial ~= nil and DeepCopy(initial) or spec.default()
            stores[spec.id] = { value = value, spec = spec }
            return stores[spec.id]
        end,
        LoadStore = function(self, id) return stores[id] ~= nil and true or false end,
        MarkDirty = function(self, id)
            local store = stores[id]
            assert(store ~= nil, "store missing")
            store.value = DeepCopy(store.spec.get())
            savedValue = DeepCopy(store.value)
            return true
        end,
    }
end

local function Boot(initial)
    queued = {}
    published = {}
    local persistence = NewPersistence(initial)
    ReplicatedSuite = {
        BootError = nil,
        Persistence = persistence,
        Utils = {
            DeepCopy = DeepCopy,
            GetServerTime = function() return server end,
        },
        NowMs = function() return nowMs end,
        Events = { Publish = function(_, topic, ...) published[#published + 1] = { topic = topic, args = { ... } }; return 1 end },
        Services = {},
    }
    ReplicatedSuite.Services.PriceQuoteQueueV3 = {
        EnsureStoreLoaded = function() return true end,
        referencePrices = {},
        RequestQuote = function(self, requester, itemType, itemGrade, callback, grades, options)
            queued[#queued + 1] = {
                requester = requester, itemType = itemType, itemGrade = itemGrade,
                callback = callback, grades = DeepCopy(grades), options = DeepCopy(options),
            }
            return true, "queued"
        end,
    }
    dofile(root .. "/services/rs_material_price_service_v3.lua")
    return ReplicatedSuite.Services.MaterialPriceServiceV3, persistence
end

local function Eq(actual, expected, label)
    assert(actual == expected, label .. ": expected=" .. tostring(expected) .. " actual=" .. tostring(actual))
end

-- Initial confirmed unit quote is immediately readable and persisted.
local M = Boot(nil)
assert(M:EnsureStoreLoaded() == true)
local ok = M:ObserveConfirmedPrice(30902, 1, 386, "name_search_direct_unit")
assert(ok == true)
local price, meta = M:GetPrice(30902, 1)
Eq(price, 386, "initial unit price")
Eq(meta.freshness, "fresh", "initial freshness")
assert(savedValue ~= nil and savedValue.entries["30902:1"].price == 386, "confirmed quote persisted")
assert(#published >= 1 and published[#published].topic == "v3.material_price.changed", "price change published")

-- Reload simulation: persisted server-wall-clock timestamp survives generation-local NowMs reset.
local persisted = DeepCopy(savedValue)
nowMs = 5
server = { year = 2026, month = 9, day = 25, hour = 20, minute = 0 }
M = Boot(persisted)
assert(M:EnsureStoreLoaded() == true)
price, meta = M:GetPrice(30902, 1)
Eq(price, 386, "reload price")
Eq(meta.freshness, "fresh", "five-hour cache remains fresh")

server = { year = 2026, month = 9, day = 26, hour = 5, minute = 0 }
price, meta = M:GetPrice(30902, 1)
Eq(price, 386, "warm cache still readable")
Eq(meta.freshness, "warm", "fourteen-hour cache warm")
assert(meta.needsRefresh == true, "warm cache requests quiet refresh")

server = { year = 2026, month = 10, day = 4, hour = 15, minute = 0 }
price, meta = M:GetPrice(30902, 1)
Eq(price, 386, "old cache still readable")
Eq(meta.freshness, "old", "nine-day cache old")
assert(meta.needsRefresh == true, "old cache requests refresh without invalidating price")

-- Background admission remains one queue request with low priority/force refresh.
queued = {}
local qok, summary = M:QueueRevalidate({ { itemType = 30902, itemGrade = 1, name = "谷物细粉" } }, { maxItems = 12 })
assert(qok == true and summary.submitted == 1, "old cache admitted for background refresh")
Eq(#queued, 1, "one background queue request")
Eq(queued[1].options.priority, "background", "background priority")
assert(queued[1].options.force == true, "background bypasses session quote TTL but not queue serialization")

-- Large single-sample jump is held; stable price remains available. A second similar sample confirms.
server = { year = 2026, month = 10, day = 4, hour = 15, minute = 1 }
local accepted, reason = M:ObserveConfirmedPrice(30902, 1, 62573, "name_search_direct_unit")
assert(accepted == false and reason == "anomaly_candidate_held", "single 8x+ jump held")
price = M:GetPrice(30902, 1)
Eq(price, 386, "held anomaly cannot poison stable price")
accepted = M:ObserveConfirmedPrice(30902, 1, 63000, "name_search_direct_unit")
assert(accepted == true, "second similar anomaly confirms regime change")
price, meta = M:GetPrice(30902, 1)
Eq(price, 63000, "confirmed anomaly becomes stable price")
Eq(meta.freshness, "fresh", "confirmed replacement fresh")

-- If server calendar is unavailable immediately after a confirmed quote, session acceptance time prevents requeue storms.
server = nil
nowMs = nowMs + 1000
accepted = M:ObserveConfirmedPrice(3603, 1, 120, "name_search_direct_unit")
assert(accepted == true, "quote accepted without server calendar")
price, meta = M:GetPrice(3603, 1)
Eq(price, 120, "session price readable without server calendar")
Eq(meta.freshness, "fresh", "session acceptance clock keeps quote fresh")

-- 维护（2026-09-25，RS-ERROR-PAGE-1 / service-boundary-declaration-1）：Foundation Gate 的
-- service_presentation_boundary 会枚举 S.Services.* 的每一张表并要求显式声明
-- presentationBoundary ∈ {service_only, event_host_only}；缺失会让整份自检报告变成 BLOCKED。
-- 这里直接断言真实加载出来的服务表，防止再次漏声明。
Eq(tostring(M.presentationBoundary), "service_only", "MaterialPriceServiceV3 presentationBoundary")

print("MATERIAL PRICE SWR RUNTIME: PASS")

-- 维护（2026-09-27，material-price-store-backoff-1）：持久 Store 故障必须是冷边沿失败，不能被每个材料 GetPrice
-- 放大成 LoadStore 风暴；自动 SWR 在该状态下 fail-soft，显式 QuoteQueue 仍由 Trade 自己回退读取。
local failingLoadCalls = 0
local function BootWithFailingStore()
    queued = {}
    published = {}
    local stores = {}
    ReplicatedSuite = {
        BootError = nil,
        Persistence = {
            Scope = { Account = "account" }, Lifetime = { Permanent = "permanent" }, V3KeyPrefix = "test:",
            GetStore = function(self, id) return stores[id] end,
            RegisterV3Store = function(self, spec)
                stores[spec.id] = { value = spec.default(), spec = spec }
                return stores[spec.id]
            end,
            LoadStore = function(self, id)
                failingLoadCalls = failingLoadCalls + 1
                return false, nil, "forced_store_failure"
            end,
            MarkDirty = function() return true end,
        },
        Utils = { DeepCopy = DeepCopy, GetServerTime = function() return server end },
        NowMs = function() return nowMs end,
        Events = { Publish = function() return 1 end },
        Services = {},
    }
    ReplicatedSuite.Services.PriceQuoteQueueV3 = {
        EnsureStoreLoaded = function() return true end,
        referencePrices = {},
        RequestQuote = function(self, requester, itemType, itemGrade, callback, grades, options)
            queued[#queued + 1] = { itemType = itemType, itemGrade = itemGrade }
            return true, "queued"
        end,
    }
    dofile(root .. "/services/rs_material_price_service_v3.lua")
    return ReplicatedSuite.Services.MaterialPriceServiceV3
end

nowMs = 20000
failingLoadCalls = 0
M = BootWithFailingStore()
for _ = 1, 20 do
    local missing, missingMeta = M:GetPrice(30902, 1)
    assert(missing == nil and missingMeta.storeUnavailable == true, "failed store reports degraded price read")
end
Eq(failingLoadCalls, 1, "store load failure is backoff-bounded inside row loops")
local revalidateOk, revalidateState = M:QueueRevalidate({ { itemType = 30902, itemGrade = 1, name = "谷物细粉" } }, { maxItems = 12 })
assert(revalidateOk == false and type(revalidateState) == "table" and revalidateState.storeUnavailable == true,
    "background SWR stops while durable store is unavailable")
Eq(#queued, 0, "store failure cannot fan out background auction requests")
local degraded = M:Describe()
assert(degraded.storeLoaded == false and degraded.lastStoreLoadError == "forced_store_failure", "load error exposed in diagnostics")
assert((tonumber(degraded.storeLoadBackoffHits) or 0) >= 20, "backoff hits diagnosed")
nowMs = nowMs + 6000
M:GetPrice(30902, 1)
Eq(failingLoadCalls, 2, "store retry resumes only after bounded retry window")

print("MATERIAL PRICE STORE BACKOFF: PASS")

-- 维护（2026-09-27，material-price-cache-recovery-1）：材料价 Store 是可再生派生缓存。
-- current-schema fingerprint mismatch 已由 .18.323 实机证明会让 Store 永久 Fence；服务只允许该
-- 明确错误走一次 replaceCorrupt + durable verified replacement，不能把 LoadData/未来 schema 等错误吞掉。
local integrityLoadCalls, replacementCalls = 0, 0
local function BootWithRecoverableIntegrityFence()
    queued = {}
    published = {}
    local stores = {}
    ReplicatedSuite = {
        BootError = nil,
        Persistence = {
            Scope = { Account = "account" }, Lifetime = { Permanent = "permanent" }, V3KeyPrefix = "test:",
            GetStore = function(self, id) return stores[id] end,
            RegisterV3Store = function(self, spec)
                assert(spec.recoverableReplacement == true, "material price cache must declare recoverableReplacement")
                stores[spec.id] = { value = spec.default(), spec = spec, loaded = false, writeFenced = false }
                return stores[spec.id]
            end,
            LoadStore = function(self, id)
                integrityLoadCalls = integrityLoadCalls + 1
                local store = assert(stores[id], "store missing")
                store.loaded = true
                store.loadStatus = "integrity_failed"
                store.writeFenced = true
                store.writeFenceReason = "integrity_failed:fingerprint_mismatch:4EE70972>3697A407"
                return false, nil, store.writeFenceReason
            end,
            SaveValue = function(self, id, value, options)
                replacementCalls = replacementCalls + 1
                local store = assert(stores[id], "store missing")
                assert(options.replaceCorrupt == true, "cache recovery must explicitly replace corrupt store")
                assert(options.durable == true, "cache recovery replacement must be durable-verified")
                assert(options.allowUnloadedWrite == true, "cache recovery must declare unloaded replacement intent")
                store.value = DeepCopy(value)
                store.loaded = true
                store.loadStatus = "saved"
                store.writeFenced = false
                store.writeFenceReason = nil
                return true
            end,
            MarkDirty = function(self, id)
                local store = assert(stores[id], "store missing")
                store.value = DeepCopy(store.spec.get())
                return true
            end,
        },
        Utils = { DeepCopy = DeepCopy, GetServerTime = function() return server end },
        NowMs = function() return nowMs end,
        Events = { Publish = function() return 1 end },
        Services = {},
    }
    ReplicatedSuite.Services.PriceQuoteQueueV3 = {
        EnsureStoreLoaded = function() return true end,
        referencePrices = {},
        RequestQuote = function() return true, "queued" end,
    }
    dofile(root .. "/services/rs_material_price_service_v3.lua")
    return ReplicatedSuite.Services.MaterialPriceServiceV3
end

integrityLoadCalls, replacementCalls = 0, 0
nowMs = 40000
M = BootWithRecoverableIntegrityFence()
assert(M:EnsureStoreLoaded() == true, "fingerprint-fenced derived cache should self-heal")
Eq(integrityLoadCalls, 1, "integrity cache recovery performs one failed load")
Eq(replacementCalls, 1, "integrity cache recovery performs one verified replacement")
assert(M.storeLoaded == true, "service resumes after cache replacement")
local recovered = M:Describe()
Eq(recovered.cacheRecoveryAttempts, 1, "cache recovery attempt diagnosed")
Eq(recovered.cacheRecoverySuccesses, 1, "cache recovery success diagnosed")
Eq(recovered.cacheRecoveryFailures, 0, "cache recovery has no failure")
assert(recovered.lastCacheRecoveryReason:find("4EE70972>3697A407", 1, true) ~= nil,
    "diagnostics preserve the triggering fingerprint pair")
local recoveredOk = M:ObserveConfirmedPrice(30902, 1, 386, "name_search_direct_unit")
assert(recoveredOk == true, "material prices are writable again after cache replacement")

print("MATERIAL PRICE DERIVED CACHE RECOVERY: PASS")

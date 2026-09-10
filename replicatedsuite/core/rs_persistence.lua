------------------------------------------------------------------------
-- Replicated Suite - Persistence Framework
--
-- Shared persistence mechanism for V3-owned stores. Business Domains keep
-- ownership of their data and reset semantics; this layer owns SaveData keys,
-- lifetime metadata, schema fences, dirty/debounce, period calculation and
-- structured diagnostics. Legacy Suite payloads are migration sources only and
-- are not an active persistence dependency of the V3 runtime.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite

local DeepCopy
if S.Reuse and S.Reuse.Table and type(S.Reuse.Table.DeepCopy) == "function" then
    DeepCopy = S.Reuse.Table.DeepCopy
else
    -- Keep the fallback recursively self-contained. A local declared inside its
    -- own initializer would resolve DeepCopy as a global under Lua 5.1 rules.
    DeepCopy = function(value, seen)
        if type(value) ~= "table" then return value end
        seen = seen or {}
        if seen[value] ~= nil then return seen[value] end
        local out = {}; seen[value] = out
        for k, v in pairs(value) do out[DeepCopy(k, seen)] = DeepCopy(v, seen) end
        return out
    end
end

local LIFETIME = {
    Permanent = "Permanent",
    Daily = "Daily",
    Weekly = "Weekly",
    Session = "Session",
    Checkpoint = "Checkpoint",
}

local SCOPE = {
    Account = "Account",
    Character = "Character",
}

S.Persistence = {
    FrameworkVersion = 3,
    -- 中文维护注释：Framework3 引入物理传输编码。RU SaveData 已实证会省略 false/空表；业务 Domain、Store canonical 与完整性指纹仍使用原始 Lua 语义，只有真正交给 SaveData 的物理 envelope 才编码，LoadData 后在 metadata/schema/Apply 前还原。Authority 仍唯一属于 Store/Persistence，不把哨兵泄漏到 Feature/UI。旧 Framework2 继续可读；旧插件读取 Framework3 时会命中 future-framework 写保护，避免回滚版本误写哨兵。
    TransportContractVersion = 1,
    ReliabilityContractVersion = 8,
    MinIntegrityReliabilityContractVersion = 4,
    -- Integrity v3 verifies the CANONICAL store value (decode -> store
    -- normalize/encode) instead of the raw encoded envelope, so a logical-
    -- preserving RU SaveData/LoadData representation change (map<->sequence,
    -- dropped empty tables, float renormalization) can no longer create a
    -- false corruption fence. v2 raw-envelope verification is retained as a
    -- recognized legacy generation and upgraded to v3 at the next save.
    -- v4: the per-store canonical functions are real normalizers. v3 stamps
    -- were produced while four life-bundle stores had a CONTENT-BLIND migrate
    -- (`migrate = default` hashed the default table shape, not the content) --
    -- those stamps are meaningless as integrity evidence and are recovered
    -- through the gated one-generation upgrade below.
    IntegrityContractVersion = 4,
    ContentBlindCanonicalContractVersion = 3,
    PreCanonicalIntegrityContractVersion = 2,
    LegacyIntegrityContractVersion = 1,
    SerializerNumericFingerprintContractVersion = 1,
    EnvelopeIntegrityContractVersion = 1,
    ScopeBindingContractVersion = 1,
    RuntimeAcceptanceDiagnosticsContractVersion = 1,
    RuntimeAcceptanceSnapshotContractVersion = 2,
    ReadinessContractVersion = 1,
    TerminalLoadMemoizationContractVersion = 1,
    HistoricalCanonicalRecoveryContractVersion = 3,
    KnownLegacyCanonicalRecoveryContractVersion = 1,
    Lifetime = LIFETIME,
    Scope = SCOPE,
    DefaultBudget = { maxDepth = 12, maxNodes = 4096, maxStringBytes = 65536, maxEntriesPerTable = 1024 },
    -- Domain payload and framework envelope are deliberately budgeted
    -- separately. The old code validated {payload,__rsmeta} against the exact
    -- business budget, so a payload at its legal maxDepth could be rejected
    -- only because Persistence added one wrapper table of its own.
    DefaultEnvelopeOverhead = { maxDepth = 2, maxNodes = 64, maxStringBytes = 4096, maxEntriesPerTable = 16 },
    stores = {},
    order = {},
    keyOwners = {},
    defaultDelayMs = 750,
    maxDebounceMs = 5000,
    periodCheckMs = 15000,
    nextPeriodCheckAt = 0,
    -- Runtime-only acceptance evidence. Never persisted and never used as a
    -- write-policy Authority. It exists solely so a failed reload/Flush can be
    -- copied after the fact with the exact store id + reason required by the
    -- RU Fresh Reload acceptance matrix.
    lastFlush = { at = 0, ok = nil, saved = 0, verified = 0, failures = {} },
    stats = {
        registered = 0,
        loaded = 0,
        loadFailures = 0,
        saves = 0,
        saveFailures = 0,
        migrations = 0,
        periodResets = 0,
        payloadRejected = 0,
        encodedPayloadRejected = 0,
        metadataMismatches = 0,
        keyCollisions = 0,
        clears = 0,
        clearFailures = 0,
        unloadedWriteRejects = 0,
        dirtyReloadRejects = 0,
        unverifiedReloadRejects = 0,
        flushFailures = 0,
        retryQueued = 0,
        corruptEmptyRejects = 0,
        mutationAttempts = 0,
        mutationPrepareRejects = 0,
        mutationFailures = 0,
        mutationCommitFailures = 0,
        mutationRollbacks = 0,
        mutationRollbackFailures = 0,
        readbackVerifyAttempts = 0,
        readbackVerifySuccesses = 0,
        readbackVerifyFailures = 0,
        integrityStampedSaves = 0,
        integrityLoadChecks = 0,
        integrityLoadFailures = 0,
        integrityLegacyLoads = 0,
        integrityCompatibilityLoads = 0,
        integrityCompatibilityResaves = 0,
        integritySerializerRepairLoads = 0,
        integritySerializerRepairFailures = 0,
        integritySerializerRepairResaves = 0,
        integrityUpgradeRecoveries = 0,
        integrityUpgradeResaves = 0,
        integrityUpgradeValidationFailures = 0,
        encodedLoadRejects = 0,
        verifiedReplacementRecoveries = 0,
        barrierVerifyAttempts = 0,
        barrierVerifySuccesses = 0,
        barrierVerifyFailures = 0,
        barrierVerifyRequeued = 0,
        clearVerifyAttempts = 0,
        clearVerifyFailures = 0,
        envelopeIntegrityStampedSaves = 0,
        envelopeIntegrityLoadChecks = 0,
        envelopeIntegrityLoadFailures = 0,
        decodedLoadRejects = 0,
        durableVerifyAttempts = 0,
        durableVerifyFailures = 0,
        scopeBindingMismatches = 0,
        scopeRebinds = 0,
        deferredLoadResaves = 0,
        readPrepareAttempts = 0,
        readPrepareFailures = 0,
        readPrepareLoads = 0,
        terminalAutoRetrySuppressions = 0,
        terminalLoadShortCircuits = 0,
        knownLegacyCanonicalRecoveries = 0,
        knownLegacyCanonicalRecoveryRejects = 0,
    },
}
local P = S.Persistence
P.V3KeyPrefix = tostring(S.SaveKey or "replicated_suite_v1") .. "_v3_"

local function NowMs()
    return type(S.NowMs) == "function" and math.max(0, tonumber(S.NowMs()) or 0) or 0
end

local function NonEmptyText(value)
    if value == nil then return nil end
    local text = tostring(value):gsub("[\r\n]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return text ~= "" and text or nil
end

-- 中文维护注释：RU 物理 SaveData 传输层。这里仅解决已实证的两类表示丢失：boolean false 与空 table。
-- 不能直接把 false 改成 nil，也不能让各 Feature 自己发明编码，否则重载后会出现“默认 true 覆盖用户 false”以及多套兼容逻辑。
-- 保留字符串转义是为了消除哨兵碰撞：任何业务字符串只要以保留前缀开头，保存前都会先转义，因而解码绝不会把真实用户字符串误判成框架值。
local TRANSPORT_PREFIX = "__rs_t1:"
local TRANSPORT_FALSE = TRANSPORT_PREFIX .. "f"
local TRANSPORT_EMPTY = TRANSPORT_PREFIX .. "e"
local TRANSPORT_STRING = TRANSPORT_PREFIX .. "s"

local function TransportEncodeValue(value, seen)
    local kind = type(value)
    if kind == "boolean" then return value == false and TRANSPORT_FALSE or true, nil end
    if kind == "string" then
        if value:sub(1, #TRANSPORT_PREFIX) == TRANSPORT_PREFIX then return TRANSPORT_STRING .. value, nil end
        return value, nil
    end
    if kind ~= "table" then return value, nil end
    if next(value) == nil then return TRANSPORT_EMPTY, nil end
    seen = seen or {}
    if seen[value] ~= nil then return nil, "transport_cycle" end
    seen[value] = true
    local out = {}
    for key, child in pairs(value) do
        local encodedKey, keyErr = TransportEncodeValue(key, seen)
        if keyErr ~= nil then seen[value] = nil; return nil, keyErr end
        local encodedChild, childErr = TransportEncodeValue(child, seen)
        if childErr ~= nil then seen[value] = nil; return nil, childErr end
        out[encodedKey] = encodedChild
    end
    seen[value] = nil
    return out, nil
end

local function TransportDecodeValue(value, seen)
    local kind = type(value)
    if kind == "string" then
        if value == TRANSPORT_FALSE then return false, nil end
        if value == TRANSPORT_EMPTY then return {}, nil end
        if value:sub(1, #TRANSPORT_STRING) == TRANSPORT_STRING then return value:sub(#TRANSPORT_STRING + 1), nil end
        if value:sub(1, #TRANSPORT_PREFIX) == TRANSPORT_PREFIX then return nil, "unknown_transport_token" end
        return value, nil
    end
    if kind ~= "table" then return value, nil end
    seen = seen or {}
    if seen[value] ~= nil then return nil, "transport_cycle" end
    seen[value] = true
    local out = {}
    for key, child in pairs(value) do
        local decodedKey, keyErr = TransportDecodeValue(key, seen)
        if keyErr ~= nil then seen[value] = nil; return nil, keyErr end
        local decodedChild, childErr = TransportDecodeValue(child, seen)
        if childErr ~= nil then seen[value] = nil; return nil, childErr end
        out[decodedKey] = decodedChild
    end
    seen[value] = nil
    return out, nil
end

function P:EncodePhysicalEnvelope(raw)
    if type(raw) ~= "table" then return nil, "transport_raw_type:" .. tostring(type(raw)) end
    return TransportEncodeValue(raw)
end

function P:DecodePhysicalEnvelope(raw)
    if type(raw) ~= "table" then return nil, "transport_raw_type:" .. tostring(type(raw)) end
    local meta = type(raw.__rsmeta) == "table" and raw.__rsmeta or nil
    local framework = meta and tonumber(meta.framework) or nil
    local transport = meta and tonumber(meta.transportVersion) or nil
    if framework ~= nil and framework >= 3 then
        if transport ~= tonumber(self.TransportContractVersion) then
            return nil, "transport_contract:" .. tostring(transport) .. ">" .. tostring(self.TransportContractVersion)
        end
        return TransportDecodeValue(raw)
    end
    -- 中文维护注释：Framework2/无 metadata 的历史存档没有物理哨兵，保持原样进入既有 legacy/schema 迁移。
    -- transportVersion 单独出现而 framework 缺失属于损坏 envelope，不猜测恢复。
    if transport ~= nil then return nil, "transport_without_framework" end
    return raw, nil
end

local function NormalizeId(value)
    local text = tostring(value or ""):lower():gsub("[^%w_%.%-]", "_"):gsub("_+", "_")
    text = text:gsub("^_+", ""):gsub("_+$", "")
    return text
end

local function Emit(level, code, message, context)
    local d = S.DiagnosticsManager
    if type(d) == "table" and type(d.Emit) == "function" then
        return d:Emit(level, "persistence", code, message, context)
    end
    if (level == "error" or level == "warning") and type(S.RecordLog) == "function" then
        S.RecordLog(level, "persistence", "[" .. tostring(code) .. "] " .. tostring(message))
    end
end

local function Count(code, delta)
    local d = S.DiagnosticsManager
    if type(d) == "table" and type(d.Count) == "function" then d:Count("persistence", code, delta or 1) end
end

local function NormalizeBudget(value)
    value = type(value) == "table" and value or {}
    local defaults = P.DefaultBudget or {}
    return {
        maxDepth = math.max(2, math.floor(tonumber(value.maxDepth) or tonumber(defaults.maxDepth) or 12)),
        maxNodes = math.max(16, math.floor(tonumber(value.maxNodes) or tonumber(defaults.maxNodes) or 4096)),
        maxStringBytes = math.max(256, math.floor(tonumber(value.maxStringBytes) or tonumber(defaults.maxStringBytes) or 65536)),
        maxEntriesPerTable = math.max(8, math.floor(tonumber(value.maxEntriesPerTable) or tonumber(defaults.maxEntriesPerTable) or 1024)),
    }
end

local function NormalizeEnvelopeBudget(domainBudget, explicitBudget)
    domainBudget = NormalizeBudget(domainBudget)
    if type(explicitBudget) == "table" then
        local explicit = NormalizeBudget(explicitBudget)
        -- An encoded envelope can never be allowed to be smaller than the
        -- already-approved Domain payload. This keeps custom encoders bounded
        -- while ensuring framework metadata cannot make a legal payload illegal.
        return {
            maxDepth = math.max(domainBudget.maxDepth, explicit.maxDepth),
            maxNodes = math.max(domainBudget.maxNodes, explicit.maxNodes),
            maxStringBytes = math.max(domainBudget.maxStringBytes, explicit.maxStringBytes),
            maxEntriesPerTable = math.max(domainBudget.maxEntriesPerTable, explicit.maxEntriesPerTable),
        }
    end
    local overhead = P.DefaultEnvelopeOverhead or {}
    return {
        maxDepth = domainBudget.maxDepth + math.max(1, math.floor(tonumber(overhead.maxDepth) or 2)),
        maxNodes = domainBudget.maxNodes + math.max(8, math.floor(tonumber(overhead.maxNodes) or 64)),
        maxStringBytes = domainBudget.maxStringBytes + math.max(256, math.floor(tonumber(overhead.maxStringBytes) or 4096)),
        maxEntriesPerTable = math.max(domainBudget.maxEntriesPerTable, math.max(8, math.floor(tonumber(overhead.maxEntriesPerTable) or 16))),
    }
end

-- SaveData preflight. The RU serializer has proven truncation behavior on large
-- nested payloads, so every shared V2 store is structurally bounded BEFORE a
-- write. This is intentionally O(n) only on save/load boundaries, never Tick-hot.
function P:InspectPayload(value, budget)
    budget = NormalizeBudget(budget)
    local seen = {}
    local result = { ok = true, nodes = 0, stringBytes = 0, maxDepth = 0, maxTableEntries = 0, reason = nil }
    local function Fail(reason)
        if result.ok then result.ok = false; result.reason = reason end
        return false
    end
    local function Visit(node, depth)
        if result.ok ~= true then return false end
        if depth > budget.maxDepth then return Fail("max_depth") end
        if depth > result.maxDepth then result.maxDepth = depth end
        local t = type(node)
        result.nodes = result.nodes + 1
        if result.nodes > budget.maxNodes then return Fail("max_nodes") end
        if t == "nil" or t == "boolean" then return true end
        if t == "number" then
            if node ~= node or node == math.huge or node == -math.huge then return Fail("invalid_number") end
            return true
        end
        if t == "string" then
            result.stringBytes = result.stringBytes + #node
            if result.stringBytes > budget.maxStringBytes then return Fail("max_string_bytes") end
            return true
        end
        if t ~= "table" then return Fail("unsupported_type:" .. t) end
        if seen[node] then return Fail("cyclic_table") end
        seen[node] = true
        local entries = 0
        for k, v in pairs(node) do
            entries = entries + 1
            if entries > budget.maxEntriesPerTable then seen[node] = nil; return Fail("max_table_entries") end
            local kt = type(k)
            if kt ~= "string" and kt ~= "number" then seen[node] = nil; return Fail("unsupported_key_type:" .. kt) end
            if not Visit(k, depth + 1) or not Visit(v, depth + 1) then seen[node] = nil; return false end
        end
        if entries > result.maxTableEntries then result.maxTableEntries = entries end
        seen[node] = nil
        return true
    end
    Visit(value, 1)
    result.budget = budget
    return result
end

local function IsLeapYear(year)
    year = tonumber(year) or 0
    return year % 400 == 0 or (year % 4 == 0 and year % 100 ~= 0)
end

local MONTH_DAYS = { 31,28,31,30,31,30,31,31,30,31,30,31 }

local function ValidDate(year, month, day)
    year, month, day = tonumber(year), tonumber(month), tonumber(day)
    if year == nil or year < 2000 or year > 2100 or month == nil or month < 1 or month > 12 or day == nil or day < 1 then
        return false
    end
    local maxDay = MONTH_DAYS[month] + ((month == 2 and IsLeapYear(year)) and 1 or 0)
    return day <= maxDay
end

-- Small bounded calendar helpers.  They run only during period checks (default
-- every 15 seconds), never in combat/event hot loops.
local function DateOrdinal(year, month, day)
    if not ValidDate(year, month, day) then return nil end
    local value = 0
    for y = 2000, year - 1 do value = value + (IsLeapYear(y) and 366 or 365) end
    for m = 1, month - 1 do value = value + MONTH_DAYS[m] + ((m == 2 and IsLeapYear(year)) and 1 or 0) end
    return value + day - 1
end

local function DateFromOrdinal(ordinal)
    ordinal = math.floor(tonumber(ordinal) or -1)
    if ordinal < 0 then return nil end
    local year = 2000
    while year <= 2100 do
        local days = IsLeapYear(year) and 366 or 365
        if ordinal < days then break end
        ordinal = ordinal - days
        year = year + 1
    end
    if year > 2100 then return nil end
    local month = 1
    while month <= 12 do
        local days = MONTH_DAYS[month] + ((month == 2 and IsLeapYear(year)) and 1 or 0)
        if ordinal < days then break end
        ordinal = ordinal - days
        month = month + 1
    end
    if month > 12 then return nil end
    return year, month, ordinal + 1
end

local function ShiftDate(year, month, day, deltaDays)
    local ordinal = DateOrdinal(year, month, day)
    if ordinal == nil then return nil end
    return DateFromOrdinal(ordinal + math.floor(tonumber(deltaDays) or 0))
end

local function ServerTimeParts()
    if S.Utils == nil or type(S.Utils.GetServerTime) ~= "function" then return nil end
    local t = S.Utils.GetServerTime()
    if type(t) ~= "table" then return nil end
    local year, month, day = tonumber(t.year), tonumber(t.month), tonumber(t.day)
    if not ValidDate(year, month, day) then return nil end
    local hour = math.max(0, math.min(23, math.floor(tonumber(t.hour) or 0)))
    local minute = math.max(0, math.min(59, math.floor(tonumber(t.minute) or 0)))
    return year, month, day, hour, minute
end

local function DateText(year, month, day)
    if not ValidDate(year, month, day) then return nil end
    return string.format("%04d-%02d-%02d", year, month, day)
end

local function BeforeReset(hour, minute, resetHour, resetMinute)
    local nowMinutes = (tonumber(hour) or 0) * 60 + (tonumber(minute) or 0)
    local resetMinutes = (tonumber(resetHour) or 0) * 60 + (tonumber(resetMinute) or 0)
    return nowMinutes < resetMinutes
end

function P:GetPeriodId(lifetime, policy)
    lifetime = tostring(lifetime or "")
    if lifetime == LIFETIME.Permanent then return "permanent" end
    if lifetime == LIFETIME.Session then return "session:g" .. tostring(tonumber(S.Generation) or 0) end
    if lifetime == LIFETIME.Checkpoint then return "checkpoint" end

    policy = type(policy) == "table" and policy or nil
    if policy == nil then return nil, "reset policy required" end
    local year, month, day, hour, minute = ServerTimeParts()
    if year == nil then return nil, "server time unavailable" end

    local kind = tostring(policy.kind or "")
    if lifetime == LIFETIME.Daily then
        if kind == "server_date" then return DateText(year, month, day) end
        if kind ~= "server_reset" then return nil, "unsupported daily reset policy: " .. kind end
        local resetHour = math.max(0, math.min(23, math.floor(tonumber(policy.hour) or 0)))
        local resetMinute = math.max(0, math.min(59, math.floor(tonumber(policy.minute) or 0)))
        if BeforeReset(hour, minute, resetHour, resetMinute) then
            year, month, day = ShiftDate(year, month, day, -1)
        end
        return DateText(year, month, day)
    end

    if lifetime == LIFETIME.Weekly then
        if kind ~= "server_weekly" then return nil, "unsupported weekly reset policy: " .. kind end
        local resetWeekday = math.floor(tonumber(policy.weekday) or 0)
        if resetWeekday < 1 or resetWeekday > 7 then return nil, "weekly reset weekday must be 1..7" end
        local resetHour = math.max(0, math.min(23, math.floor(tonumber(policy.hour) or 0)))
        local resetMinute = math.max(0, math.min(59, math.floor(tonumber(policy.minute) or 0)))
        local weekday = S.Utils and type(S.Utils.DayOfWeek) == "function" and S.Utils.DayOfWeek(year, month, day) or nil
        if weekday == nil then return nil, "weekday unavailable" end
        local daysSince = (weekday - resetWeekday) % 7
        if daysSince == 0 and BeforeReset(hour, minute, resetHour, resetMinute) then daysSince = 7 end
        year, month, day = ShiftDate(year, month, day, -daysSince)
        local date = DateText(year, month, day)
        return date and ("week:" .. date) or nil
    end
    return nil, "unsupported lifetime: " .. lifetime
end

local SCOPE_HASH_MOD = 2147483647

local function ScopeIdentityFingerprint(value)
    value = NonEmptyText(value)
    if value == nil then return nil end
    -- Two independent bounded byte hashes keep the persisted identity marker
    -- ASCII-only without changing the historical physical SaveData key format.
    -- This is collision detection, not a cryptographic identity primitive.
    local h1, h2 = 104729, 130363
    for i = 1, #value do
        local byte = string.byte(value, i)
        h1 = (h1 * 131 + byte) % SCOPE_HASH_MOD
        h2 = (h2 * 137 + byte + i) % SCOPE_HASH_MOD
    end
    return string.format("%08X%08X", math.floor(h1), math.floor(h2))
end

local function CharacterScopeIdentity()
    -- V3 Character stores resolve identity directly from the authoritative
    -- world-qualified unit getter. They do not depend on the legacy monolithic
    -- Storage object or its deferred Character Override machinery.
    local identity = nil
    if X2Unit ~= nil and S.Api ~= nil and type(S.Api.CallCapability) == "function" then
        local ok, value = S.Api:CallCapability("X2Unit:UnitNameWithWorld", X2Unit, "UnitNameWithWorld", "player")
        if ok then identity = NonEmptyText(value) end
    end
    return identity
end

local function CharacterScopeToken(identity)
    identity = NonEmptyText(identity)
    if identity == nil then return nil end
    -- Keep the physical key algorithm unchanged for upgrade compatibility. The
    -- exact world-qualified identity is additionally stamped as a fingerprint in
    -- v6 metadata so lossy/non-ASCII normalization cannot silently cross-load a
    -- different character that happens to collapse to the same token.
    local token = NormalizeId("world:" .. identity)
    if token == "" then return nil end
    if #token > 80 then token = token:sub(1, 80) end
    return token
end

function P:ResolveStoreKey(storeOrId)
    local store = type(storeOrId) == "table" and storeOrId or self:GetStore(storeOrId)
    if store == nil then return nil, "unknown store" end
    if store.lifetime == LIFETIME.Session then return nil, nil, nil end
    local baseKey = NonEmptyText(store.key)
    if baseKey == nil then return nil, "store key unavailable", nil end
    if store.scope == SCOPE.Account then return baseKey, nil, nil end
    if store.scope == SCOPE.Character then
        local identity = CharacterScopeIdentity()
        local token = CharacterScopeToken(identity)
        if token == nil then return nil, "character scope unavailable", nil end
        return baseKey .. "_char_" .. token, nil, ScopeIdentityFingerprint(identity)
    end
    return nil, "unsupported scope: " .. tostring(store.scope), nil
end

local function CurrentScopeBinding(store)
    if store == nil or store.lifetime == LIFETIME.Session or store.scope ~= SCOPE.Character then
        return true, nil, store and store.resolvedKey or nil, store and store.resolvedScopeFingerprint or nil
    end

    -- Character identity is resolved only at explicit persistence readiness /
    -- write boundaries. No Tick path performs this lookup. Correctness wins over
    -- caching here because a stale identity can redirect an otherwise valid save.
    local currentKey, scopeErr, currentFingerprint = P:ResolveStoreKey(store)
    if currentKey == nil then return false, scopeErr or "character scope unavailable", nil, nil end
    if store.resolvedKey ~= nil and tostring(store.resolvedKey) ~= tostring(currentKey) then
        return false, "scope_binding_key_changed", currentKey, currentFingerprint
    end
    if store.resolvedScopeFingerprint ~= nil and currentFingerprint ~= nil
        and tostring(store.resolvedScopeFingerprint) ~= tostring(currentFingerprint) then
        return false, "scope_binding_identity_changed", currentKey, currentFingerprint
    end
    return true, nil, currentKey, currentFingerprint
end

local EncodeValue

local function ValidateDefinition(def)
    if type(def) ~= "table" then return nil, "definition must be table" end
    local id = NormalizeId(def.id)
    if id == "" then return nil, "store id required" end
    local lifetime = tostring(def.lifetime or "")
    if LIFETIME[lifetime] == nil then return nil, "invalid lifetime: " .. lifetime end
    local scope = tostring(def.scope or SCOPE.Account)
    if SCOPE[scope] == nil then return nil, "invalid scope: " .. scope end
    local contractVersion = math.max(1, math.floor(tonumber(def.contractVersion) or 1))
    if contractVersion >= 2 then
        if NonEmptyText(def.owner) == nil then return nil, "V2 store owner required" end
        if def.scope == nil then return nil, "V2 store scope required" end
        if type(def.budget) ~= "table" then return nil, "V2 store requires explicit SaveData budget" end
    end
    if contractVersion >= 3 then
        local owner = NonEmptyText(def.owner)
        if owner == nil or owner:match("^v3%.") == nil then return nil, "V3 store owner must use v3.* namespace" end
    end
    if lifetime ~= LIFETIME.Session and NonEmptyText(def.key) == nil then return nil, "persistent store key required" end
    if contractVersion >= 3 and lifetime ~= LIFETIME.Session then
        local key = NonEmptyText(def.key) or ""
        if key:sub(1, #P.V3KeyPrefix) ~= P.V3KeyPrefix then return nil, "V3 store key must use " .. P.V3KeyPrefix end
    end
    if (lifetime == LIFETIME.Daily or lifetime == LIFETIME.Weekly) and type(def.resetPolicy) ~= "table" then
        return nil, lifetime .. " store requires explicit resetPolicy"
    end
    if type(def.get) ~= "function" and lifetime ~= LIFETIME.Session then return nil, "get() required" end
    if type(def.apply) ~= "function" and lifetime ~= LIFETIME.Session then return nil, "apply() required" end
    return id, nil
end

function P:RegisterStore(def)
    local id, err = ValidateDefinition(def)
    if id == nil then
        Emit("error", "STORE_REGISTER_INVALID", tostring(err), { requestedId = type(def) == "table" and def.id or nil })
        return nil, err
    end
    if self.stores[id] ~= nil then
        Emit("error", "STORE_DUPLICATE", "重复 Persistence Store", { store = id })
        return nil, "duplicate store: " .. id
    end
    local requestedKey = NonEmptyText(def.key)
    if requestedKey ~= nil and tostring(def.lifetime) ~= LIFETIME.Session then
        local existingOwner = self.keyOwners[requestedKey]
        if existingOwner ~= nil then
            self.stats.keyCollisions = (tonumber(self.stats.keyCollisions) or 0) + 1
            Emit("error", "STORE_KEY_COLLISION", "Persistence Store 复用了已注册 SaveData Key", {
                store = id, key = requestedKey, existingStore = existingOwner,
            })
            return nil, "duplicate persistent key: " .. requestedKey
        end
    end

    local state = {
        id = id,
        owner = NonEmptyText(def.owner) or "Suite",
        lifetime = tostring(def.lifetime),
        scope = tostring(def.scope or SCOPE.Account),
        contractVersion = math.max(1, math.floor(tonumber(def.contractVersion) or 1)),
        schemaVersion = math.max(1, math.floor(tonumber(def.schemaVersion) or 1)),
        legacySchemaVersion = math.max(0, math.floor(tonumber(def.legacySchemaVersion) or 0)),
        key = NonEmptyText(def.key),
        resolvedKey = nil,
        resolvedScopeFingerprint = nil,
        lastScopeBindingError = nil,
        get = def.get,
        apply = def.apply,
        default = type(def.default) == "function" and def.default or function() return {} end,
        encode = def.encode,
        decode = def.decode,
        -- Optional, opt-in recovery hook for a very narrow class of RU
        -- serializer representation changes. It may reconstruct the exact
        -- pre-serializer encoded BUSINESS shape, but Persistence will accept
        -- it only when that candidate reproduces the already-stamped integrity
        -- fingerprint while the independent metadata envelope seal is valid.
        -- This is not a corruption bypass and is never enabled implicitly.
        rebuildEncodedForIntegrity = def.rebuildEncodedForIntegrity,
        -- Optional exact historical-canonical recovery for a current-integrity
        -- stamp produced by an older Store normalizer / a serializer omission
        -- whose lost logical value can be reconstructed from the existing stamp.
        -- This hook is considered ONLY after the independent envelope seal,
        -- decode and current canonical construction succeed. Its candidate is
        -- accepted only when it exactly reproduces the already-stamped fingerprint.
        -- For plain Stores, Persistence then re-runs the CURRENT canonicalizer on
        -- that exact historical logical candidate before Apply, so a recovered
        -- default-sensitive value (for example false vs omitted) is not silently
        -- replaced by the current default. Typed-codec Stores retain decode-owned
        -- Domain application. Successful recovery queues an immediate restamp.
        rebuildCanonicalForIntegrity = def.rebuildCanonicalForIntegrity,
        -- Optional STORE-OWNED one-time migration bridge for a known historical
        -- canonical stamp that is no longer invertible after a native serializer
        -- representation loss. This is intentionally stronger-gated than the
        -- exact reconstruction hook above: it is called only after current-v4
        -- verification and exact historical reconstruction both fail, while the
        -- independent envelope seal + metadata/schema + decoded budget already
        -- passed. The hook itself MUST whitelist exact historical fingerprints
        -- and validate the legacy Domain shape before returning a recovered
        -- current Domain. Unknown fingerprints continue fail-closed.
        recoverKnownLegacyCanonical = def.recoverKnownLegacyCanonical,
        -- One-generation recovery for legacy (v2 raw-envelope) stamped Stores
        -- whose fingerprint no longer verifies because the RU serializer changed
        -- the on-disk representation. Default ON: the .18.125 real-machine run
        -- proved the drift is a serializer-general behavior (v3.life.bonds,
        -- v3.gear.payload shards, v3.death_review.record shards all mismatched
        -- on their first cross-reload), so a per-store opt-in whitelist only
        -- defers each user's fenced data to a future build. The gate itself is
        -- unchanged: valid metadata envelope seal, reliability>=6, non-
        -- verifyAfterSave/non-recoverableReplacement at the flag level below,
        -- full decode + budget + schema pass, immediate canonical v3 restamp.
        -- Domains that genuinely need absolute fail-closed legacy handling may
        -- explicitly opt OUT with allowIntegrityUpgrade = false.
        allowIntegrityUpgrade = def.allowIntegrityUpgrade ~= false,
        save = def.save,
        migrate = def.migrate,
        resetPolicy = def.resetPolicy,
        autoReset = def.autoReset == true,
        periodIdFromValue = def.periodIdFromValue,
        budget = NormalizeBudget(def.budget),
        encodedBudget = NormalizeEnvelopeBudget(def.budget, def.encodedBudget),
        verifyAfterSave = def.verifyAfterSave == true,
        recoverableReplacement = def.recoverableReplacement == true,
        registrationBudgetOk = true,
        dirty = false,
        dueAt = 0,
        firstDirtyAt = 0,
        lastDirtyAt = 0,
        lastDirtyReason = nil,
        dirtyRevision = 0,
        lastSavedRevision = 0,
        consecutiveSaveFailures = 0,
        loaded = false,
        loadStatus = "not_loaded",
        writeFenced = false,
        writeFenceReason = nil,
        lastError = nil,
        lastSaveAt = nil,
        lastLoadAt = nil,
        lastVerifyAt = nil,
        lastVerifyOk = nil,
        lastVerifyFingerprint = nil,
        lastVerifyError = nil,
        lastIntegrityStatus = nil,
        lastIntegrityFingerprint = nil,
        lastIntegrityError = nil,
        lastDecodedInspection = nil,
        needsBarrierVerify = false,
        lastBarrierVerifyAt = nil,
        lastBarrierVerifyOk = nil,
        lastBarrierVerifyError = nil,
        periodId = nil,
        memory = nil,
    }
    self.stores[id] = state
    if state.key ~= nil and state.lifetime ~= LIFETIME.Session then self.keyOwners[state.key] = state.id end
    self.order[#self.order + 1] = id
    table.sort(self.order)
    self.stats.registered = (tonumber(self.stats.registered) or 0) + 1
    Count("STORE_REGISTERED", 1)
    -- Boot-time budget self-check: validate the store's DEFAULT payload against
    -- its own budget at registration. A budget too small for the store's real
    -- data used to surface only as a first-save rejection + session write fence
    -- (2026-09-01: buff display's 192-entry budget starved a 713-id payload);
    -- catching it here turns that into a visible boot diagnostic instead.
    if state.lifetime ~= LIFETIME.Session then
        local okDefault, defaultPayload = pcall(state.default)
        if okDefault then
            local inspection = self:InspectPayload(defaultPayload, state.budget)
            state.lastPayloadInspection = inspection
            if inspection.ok ~= true then
                state.registrationBudgetOk = false
                state.lastError = "default_payload_rejected:" .. tostring(inspection.reason or "unknown")
                Emit("error", "STORE_DEFAULT_BUDGET_EXCEEDED",
                    "注册即超预算：store 默认 Domain payload 无法通过自身 SaveData 预算检查，所有保存都将被拒绝", {
                        store = id, reason = inspection.reason, nodes = inspection.nodes,
                        stringBytes = inspection.stringBytes, maxTableEntries = inspection.maxTableEntries,
                    })
            elseif type(EncodeValue) == "function" then
                local raw, encodeErr = EncodeValue(state, DeepCopy(defaultPayload), nil)
                if raw == nil then
                    state.registrationBudgetOk = false
                    state.lastError = "default_encode_failed:" .. tostring(encodeErr or "unknown")
                    Emit("error", "STORE_DEFAULT_ENCODE_FAILED", "注册期默认 payload 编码失败", { store = id, error = encodeErr })
                else
                    local encodedInspection = self:InspectPayload(raw, state.encodedBudget)
                    state.lastEncodedInspection = encodedInspection
                    if encodedInspection.ok ~= true then
                        state.registrationBudgetOk = false
                        state.lastError = "default_encoded_payload_rejected:" .. tostring(encodedInspection.reason or "unknown")
                        Emit("error", "STORE_DEFAULT_ENVELOPE_BUDGET_EXCEEDED",
                            "注册即超预算：Persistence 编码外壳无法通过独立 envelope 预算检查", {
                                store = id, reason = encodedInspection.reason, nodes = encodedInspection.nodes,
                                stringBytes = encodedInspection.stringBytes, maxTableEntries = encodedInspection.maxTableEntries,
                            })
                    end
                end
            end
        else
            state.registrationBudgetOk = false
            state.lastError = "default_exception:" .. tostring(defaultPayload)
        end
    end
    return state
end

function P:RegisterV3Store(def)
    if type(def) ~= "table" then return nil, "store definition required" end
    local copy = {}
    for k, v in pairs(def) do copy[k] = v end
    copy.contractVersion = 3
    return self:RegisterStore(copy)
end

function P:GetStore(id)
    return self.stores[NormalizeId(id)]
end

local function DecodeValue(store, raw)
    if type(store.decode) == "function" then
        local ok, value, err = pcall(store.decode, raw)
        if not ok then return nil, "decode exception: " .. tostring(value) end
        if err ~= nil then return nil, tostring(err) end
        return value, nil
    end
    if type(raw) == "table" and raw.payload ~= nil then return raw.payload, nil end
    -- 中文维护注释（Framework2 RU 兼容）：普通 Store 只要带 __rsmeta，就一定是
    -- Persistence 自己写出的 `{ payload = Domain, __rsmeta = ... }` envelope。RU 会把
    -- `payload={ onlyFalse=false }` 先删掉 false，再把空 payload 表也删掉；此时不能把
    -- `__rsmeta` 整个误当成 Domain。把它还原成空 Domain 只恢复“外壳语义”，真正丢失
    -- 的 default=true -> false 字段仍必须在后续用旧指纹精确证明，绝不在这里猜值。
    if type(raw) == "table" and type(raw.__rsmeta) == "table" then return {}, nil end
    return raw, nil
end

EncodeValue = function(store, value, periodId, scopeFingerprint)
    local raw
    if type(store.encode) == "function" then
        local ok, result, err = pcall(store.encode, value)
        if not ok then return nil, "encode exception: " .. tostring(result) end
        if err ~= nil then return nil, tostring(err) end
        raw = result
    else
        raw = { payload = value }
    end
    if type(raw) ~= "table" then return nil, "encoded payload must be table" end
    raw.__rsmeta = {
        framework = P.FrameworkVersion,
        store = store.id,
        owner = store.owner,
        contractVersion = store.contractVersion,
        lifetime = store.lifetime,
        scope = store.scope,
        schema = store.schemaVersion,
        periodId = periodId,
        scopeBindingContract = store.scope == SCOPE.Character and P.ScopeBindingContractVersion or nil,
        scopeIdentityFingerprint = store.scope == SCOPE.Character and NonEmptyText(scopeFingerprint) or nil,
        transportVersion = P.TransportContractVersion, -- 中文维护注释：数值字段不会被 RU false/空表省略，用于 LoadData 边界决定是否还原物理哨兵；旧 Framework2 无此字段。
    }
    return raw, nil
end

local function ApplyValue(store, value, reason)
    local ok, err = pcall(store.apply, DeepCopy(value), reason)
    if not ok then return false, tostring(err) end
    return true, nil
end

local function DefaultValue(store)
    local ok, value = pcall(store.default)
    if not ok then return nil, tostring(value) end
    return DeepCopy(value), nil
end

-- Framework2 historical bridge for the exact RU serializer behavior that
-- motivated Transport v1. SaveData can remove a `false` field / empty table and
-- then remove its now-empty parent table. For a plain Store we rebuild only
-- serializer-removable values already declared by the Store default: missing
-- default=false stays false, missing default={} stays empty, while a missing
-- default=true is tried as false because persisted true would survive RU.
--
-- 中文维护边界：这里只处理无自定义 encode/decode 的普通 Store，而且只读取 Store
-- 自己声明的 default=true 叶子；不扫描 Feature/业务注册表，不枚举未知字段。候选会先
-- 重新经过当前 Store canonicalizer，再与磁盘中已经盖章的旧 fingerprint **完全匹配**。
-- 任一条件不成立都返回 nil，让原来的完整性 fence 继续 fail-closed。该逻辑只在旧
-- Framework<=2 的“当前 Integrity v4 指纹不匹配”冷路径运行，不进入 Tick/事件热路径。
function P:RebuildFramework2SerializerOmissions(store, decoded, stampedFingerprint, raw)
    if type(store) ~= "table" or type(raw) ~= "table" or type(raw.__rsmeta) ~= "table" then return nil, nil end
    if type(store.encode) == "function" or type(store.decode) == "function" then return nil, nil end
    local framework = tonumber(raw.__rsmeta.framework) or 0
    if framework < 1 or framework > 2 then return nil, nil end

    local defaults = DefaultValue(store)
    if type(defaults) ~= "table" then return nil, nil end
    local source = type(raw.payload) == "table" and raw.payload or (type(decoded) == "table" and decoded or {})
    local recovered = DeepCopy(source)
    local restored = 0
    local limit = 64 -- 中文维护注释：仅为防御未来异常超大 schema；超过上限立即放弃恢复而不是扩大冷启动 CPU。

    local function Restore(defaultNode, sourceNode, outputNode)
        if restored > limit or type(defaultNode) ~= "table" or type(outputNode) ~= "table" then return end
        local sourceTable = type(sourceNode) == "table" and sourceNode or nil
        for key, defaultValue in pairs(defaultNode) do
            if restored > limit then return end
            local sourceValue = sourceTable ~= nil and sourceTable[key] or nil
            if sourceValue == nil and type(defaultValue) == "boolean" then
                -- 中文维护注释：RU 只会吞 false，不会吞 true。default=false 缺失直接复原 false；
                -- default=true 缺失只“尝试”为 false，最终仍由旧 fingerprint 决定是否真实成立。
                outputNode[key] = false
                restored = restored + 1
            elseif sourceValue == nil and type(defaultValue) == "table" and next(defaultValue) == nil then
                -- 中文维护注释：空表是 RU 第二个已实证丢失形态。这里只恢复 Store default 明确声明的空表；
                -- 动态未知表不在 Core 猜测，避免把业务 nil 强制变成 `{}`。
                outputNode[key] = {}
                restored = restored + 1
            elseif type(defaultValue) == "table" then
                local child = type(sourceValue) == "table" and DeepCopy(sourceValue) or {}
                local before = restored
                Restore(defaultValue, sourceValue, child)
                if restored > before then outputNode[key] = child end
            end
        end
    end

    Restore(defaults, source, recovered)
    if restored < 1 or restored > limit then return nil, nil end

    local historicalCanonical = self:CanonicalIntegrityValue(store, recovered)
    if type(historicalCanonical) ~= "table" then return nil, nil end
    local fingerprint = self:FingerprintCanonicalValue(store, historicalCanonical)
    local matched = fingerprint ~= nil and tostring(fingerprint) == tostring(stampedFingerprint)
    store.lastHistoricalRecoveryProbe = "framework2_serializer_omissions=" .. tostring(restored)
        .. "/matched=" .. tostring(matched == true)
    if matched ~= true then return nil, nil end
    return historicalCanonical, recovered
end

-- Only full-replacement journal shards may repair a fence created while
-- READING a corrupt inactive copy. Future-schema and transient LoadData errors
-- are deliberately excluded: overwriting those could destroy data the current
-- build simply does not understand or could not read temporarily.
local function IsRecoverableReplacementFence(reason)
    reason = tostring(reason or "")
    return reason == "decode_failed"
        or reason:match("^metadata_mismatch:") ~= nil
        or reason:match("^integrity_failed:") ~= nil
        or reason:match("^envelope_integrity_failed:") ~= nil
        or reason:match("^encoded_load_rejected:") ~= nil
        or reason:match("^decoded_load_rejected:") ~= nil
        or reason:match("^transport_decode_failed:") ~= nil
end

-- Reliability v3: optional post-write readback verification for critical
-- stores. SaveData returning true is not treated as durable proof on RU because
-- oversized/nested payloads have historically been observed to truncate
-- silently. Verification is explicit/opt-in so ordinary debounced settings do
-- not double their storage traffic. The readback is decode-only: it never calls
-- store.apply() and therefore cannot become a second Domain Authority.
function P:VerifyPersistedValue(storeOrId, expectedValue, resolvedKey)
    local store = type(storeOrId) == "table" and storeOrId or self:GetStore(storeOrId)
    if store == nil then return false, "unknown store" end
    if store.lifetime == LIFETIME.Session then return true end
    if S.Api == nil or type(S.Api.LoadData) ~= "function" then return false, "LoadData unavailable" end

    local key, keyErr = resolvedKey, nil
    if key == nil then key, keyErr = self:ResolveStoreKey(store) end
    if key == nil then return false, keyErr or "store key unavailable" end

    self.stats.readbackVerifyAttempts = (tonumber(self.stats.readbackVerifyAttempts) or 0) + 1
    store.lastVerifyAt = NowMs()
    local function Fail(reason)
        reason = tostring(reason or "readback verification failed")
        store.lastVerifyOk = false
        store.lastVerifyFingerprint = nil
        store.lastVerifyError = reason
        self.stats.readbackVerifyFailures = (tonumber(self.stats.readbackVerifyFailures) or 0) + 1
        Emit("error", "STORE_READBACK_VERIFY_FAILED", "SaveData 回读校验失败，不能把本次写入视为已持久化", {
            store = store.id, owner = store.owner, error = reason,
        })
        return false, reason
    end

    local raw, loadErr = S.Api:LoadData(key)
    if loadErr ~= nil then return Fail("readback_load_failed:" .. tostring(loadErr)) end
    if raw == nil then return Fail("readback_missing") end
    if type(raw) ~= "table" then return Fail("readback_raw_type:" .. tostring(type(raw))) end

    -- 中文维护注释：立即回读必须先验证“物理 envelope”预算，再按 Framework3 transport 还原。
    -- 完整性/Store decode 永远只看逻辑 raw，防止物理哨兵泄漏进业务层或把 RU 的 false/空表省略误判为用户恢复默认值。
    local physicalInspection = self:InspectPayload(raw, store.encodedBudget)
    store.lastPhysicalInspection = physicalInspection
    if type(physicalInspection) ~= "table" or physicalInspection.ok ~= true then
        return Fail("readback_physical_payload_rejected:" .. tostring(physicalInspection and physicalInspection.reason or "unknown"))
    end
    local decodedRaw, transportErr = self:DecodePhysicalEnvelope(raw)
    if decodedRaw == nil then return Fail("readback_transport_decode_failed:" .. tostring(transportErr or "unknown")) end
    raw = decodedRaw

    local rawInspection = self:InspectPayload(raw, store.encodedBudget)
    if type(rawInspection) ~= "table" or rawInspection.ok ~= true then
        return Fail("readback_encoded_payload_rejected:" .. tostring(rawInspection and rawInspection.reason or "unknown"))
    end

    local meta = type(raw.__rsmeta) == "table" and raw.__rsmeta or nil
    if meta == nil then return Fail("readback_metadata_missing") end
    if tonumber(meta.framework) ~= tonumber(self.FrameworkVersion) then return Fail("readback_metadata_framework") end
    if tostring(meta.store or "") ~= tostring(store.id) then return Fail("readback_metadata_store") end
    if tostring(meta.owner or "") ~= tostring(store.owner) then return Fail("readback_metadata_owner") end
    if tostring(meta.lifetime or "") ~= tostring(store.lifetime) then return Fail("readback_metadata_lifetime") end
    if tostring(meta.scope or "") ~= tostring(store.scope) then return Fail("readback_metadata_scope") end
    if tonumber(meta.schema) ~= tonumber(store.schemaVersion) then return Fail("readback_metadata_schema") end
    if tonumber(meta.contractVersion) ~= tonumber(store.contractVersion) then return Fail("readback_metadata_contract") end

    local readbackIntegrityVersion = tonumber(meta.integrityVersion)
    local canonicalReadback = readbackIntegrityVersion == tonumber(self.IntegrityContractVersion)
    if readbackIntegrityVersion ~= tonumber(self.IntegrityContractVersion)
        and readbackIntegrityVersion ~= tonumber(self.PreCanonicalIntegrityContractVersion) then
        return Fail("readback_metadata_integrity_version:" .. tostring(readbackIntegrityVersion))
    end
    local stampedEncodedFingerprint = NonEmptyText(meta.encodedFingerprint or meta.payloadFingerprint)
    if stampedEncodedFingerprint == nil then return Fail("readback_metadata_fingerprint_missing") end
    if tonumber(meta.reliabilityContract) ~= tonumber(self.ReliabilityContractVersion) then
        return Fail("readback_metadata_reliability_contract")
    end
    if canonicalReadback ~= true then
        -- Legacy v2 raw-envelope comparison. Only reached by stores still
        -- stamped by the pre-canonical contract; v3 stamps verify the
        -- canonical value after decode below, because a raw comparison would
        -- false-fail exactly on the RU representation changes v3 exists for.
        local actualEncodedFingerprint, encodedFingerprintErr = self:FingerprintEncodedPayload(raw, store.encodedBudget)
        if actualEncodedFingerprint == nil then
            return Fail("readback_encoded_fingerprint_failed:" .. tostring(encodedFingerprintErr or "unknown"))
        end
        if tostring(stampedEncodedFingerprint) ~= tostring(actualEncodedFingerprint) then
            return Fail("readback_encoded_fingerprint_mismatch:" .. tostring(stampedEncodedFingerprint) .. ">" .. tostring(actualEncodedFingerprint))
        end
    end

    -- Reliability v6 seals the metadata envelope as well as the encoded
    -- business payload. This catches schema/owner/scope metadata truncation
    -- that the v4/v5 business-only fingerprint intentionally excluded.
    if tonumber(meta.envelopeIntegrityVersion) ~= tonumber(self.EnvelopeIntegrityContractVersion) then
        return Fail("readback_metadata_envelope_integrity_version")
    end
    local stampedEnvelopeFingerprint = NonEmptyText(meta.envelopeFingerprint)
    if stampedEnvelopeFingerprint == nil then return Fail("readback_metadata_envelope_fingerprint_missing") end
    if store.scope == SCOPE.Character then
        if tonumber(meta.scopeBindingContract) ~= tonumber(self.ScopeBindingContractVersion) then
            return Fail("readback_metadata_scope_binding_contract")
        end
        local expectedScopeFingerprint = NonEmptyText(store.resolvedScopeFingerprint)
        local stampedScopeFingerprint = NonEmptyText(meta.scopeIdentityFingerprint)
        if expectedScopeFingerprint == nil or stampedScopeFingerprint == nil
            or tostring(expectedScopeFingerprint) ~= tostring(stampedScopeFingerprint) then
            return Fail("readback_metadata_scope_identity_fingerprint")
        end
    end
    local actualEnvelopeFingerprint, envelopeFingerprintErr = self:FingerprintEnvelopeIntegrity(raw)
    if actualEnvelopeFingerprint == nil then
        return Fail("readback_envelope_fingerprint_failed:" .. tostring(envelopeFingerprintErr or "unknown"))
    end
    if tostring(stampedEnvelopeFingerprint) ~= tostring(actualEnvelopeFingerprint) then
        return Fail("readback_envelope_fingerprint_mismatch:" .. tostring(stampedEnvelopeFingerprint) .. ">" .. tostring(actualEnvelopeFingerprint))
    end

    local actualValue, decodeErr = DecodeValue(store, raw)
    if decodeErr ~= nil then return Fail("readback_decode_failed:" .. tostring(decodeErr)) end
    if actualValue == nil then return Fail("readback_payload_missing") end

    if type(self.FingerprintPayload) ~= "function" then return Fail("fingerprint_unavailable") end
    local expectedFingerprint, expectedErr
    local actualFingerprint, actualErr
    if canonicalReadback == true then
        -- v3: compare canonical store values on both sides so the readback
        -- proof survives the same representation changes the load-side
        -- verification absorbs.
        local canonicalExpected, canonicalExpectedErr = self:CanonicalIntegrityValue(store, expectedValue)
        if canonicalExpected == nil then
            return Fail(tostring(canonicalExpectedErr or "canonical_value_missing"))
        end
        local canonicalActual, canonicalActualErr = self:CanonicalIntegrityValue(store, actualValue)
        if canonicalActual == nil then
            return Fail("readback_canonical_failed:" .. tostring(canonicalActualErr or "unknown"))
        end
        expectedFingerprint, expectedErr = self:FingerprintCanonicalValue(store, canonicalExpected)
        actualFingerprint, actualErr = self:FingerprintCanonicalValue(store, canonicalActual)
    else
        expectedFingerprint, expectedErr = self:FingerprintDurablePayload(expectedValue, store.budget)
        actualFingerprint, actualErr = self:FingerprintDurablePayload(actualValue, store.budget)
    end
    if expectedFingerprint == nil then return Fail("expected_fingerprint_failed:" .. tostring(expectedErr)) end
    if actualFingerprint == nil then return Fail("readback_fingerprint_failed:" .. tostring(actualErr)) end
    if tostring(actualFingerprint) ~= tostring(expectedFingerprint) then
        return Fail("readback_fingerprint_mismatch:" .. tostring(expectedFingerprint) .. ">" .. tostring(actualFingerprint))
    end

    store.lastVerifyOk = true
    store.lastVerifyFingerprint = expectedFingerprint
    store.lastVerifyError = nil
    self.stats.readbackVerifySuccesses = (tonumber(self.stats.readbackVerifySuccesses) or 0) + 1
    return true, nil, expectedFingerprint
end

function P:LoadStore(id, options)
    options = type(options) == "table" and options or {}
    local store = self:GetStore(id)
    if store == nil then return false, nil, "unknown store" end
    -- Never re-apply disk state over unsaved in-memory mutations. A caller that
    -- truly wants to discard dirty working data must say so explicitly. This is
    -- the persistence-side reload fence; Feature/page code must not be trusted
    -- to remember it independently.
    if store.lifetime ~= LIFETIME.Session and store.dirty == true and options.discardDirty ~= true then
        self.stats.dirtyReloadRejects = (tonumber(self.stats.dirtyReloadRejects) or 0) + 1
        Count("STORE_DIRTY_RELOAD_REJECTED", 1)
        Emit("warning", "STORE_DIRTY_RELOAD_REJECTED", "存档仍有未落盘修改，已拒绝重新读取以避免覆盖当前配置", {
            store = store.id, owner = store.owner, reason = store.lastDirtyReason, revision = store.dirtyRevision,
        })
        return false, nil, "dirty store reload rejected"
    end
    -- Reliability v7 treats a successful-but-not-yet-readback-verified write
    -- as an in-memory durability obligation. Re-loading the same Store here could
    -- apply an older physical value over the newer healthy Domain if RU SaveData
    -- reported success before the write became durably visible. Only an explicit
    -- destructive recovery path may discard this obligation.
    if store.lifetime ~= LIFETIME.Session and store.needsBarrierVerify == true and options.discardUnverified ~= true then
        self.stats.unverifiedReloadRejects = (tonumber(self.stats.unverifiedReloadRejects) or 0) + 1
        Count("STORE_UNVERIFIED_RELOAD_REJECTED", 1)
        Emit("warning", "STORE_UNVERIFIED_RELOAD_REJECTED", "存档写入尚未通过耐久回读，已拒绝重新读取以避免旧磁盘值覆盖当前配置", {
            store = store.id, owner = store.owner, revision = store.dirtyRevision,
            lastVerifyError = store.lastVerifyError,
        })
        return false, nil, "unverified store reload rejected"
    end
    -- Terminal structural failures are immutable inside one Lua generation.
    -- Re-reading the same fenced key cannot repair an integrity/metadata/schema
    -- failure, but Feature defaults may call EnsureStoreLoaded repeatedly during
    -- startup. Memoize that terminal result so one physical failure produces one
    -- incident instead of N LoadData calls / duplicate diagnostics. A new addon
    -- generation naturally rebuilds the Store object; explicit recovery paths
    -- (ClearStore / verified replacement) reset the state themselves.
    if store.lifetime ~= LIFETIME.Session and store.loaded == true and store.writeFenced == true
        and options.revalidateTerminal ~= true then
        self.stats.terminalLoadShortCircuits = (tonumber(self.stats.terminalLoadShortCircuits) or 0) + 1
        return false, nil, tostring(store.lastError or store.writeFenceReason or store.loadStatus or "terminal store load failure")
    end
    if store.lifetime == LIFETIME.Session then
        if store.memory == nil then store.memory = select(1, DefaultValue(store)) end
        store.loaded, store.loadStatus, store.lastLoadAt = true, "session", NowMs()
        return true, DeepCopy(store.memory), nil
    end
    if S.Api == nil or type(S.Api.LoadData) ~= "function" then return false, nil, "LoadData unavailable" end
    local resolvedKey, scopeErr, scopeFingerprint = self:ResolveStoreKey(store)
    if resolvedKey == nil then
        store.loaded = false
        store.loadStatus = "scope_pending"
        store.lastError = scopeErr
        return false, nil, scopeErr
    end
    if store.scope == SCOPE.Character and store.resolvedKey ~= nil then
        local keyChanged = tostring(store.resolvedKey) ~= tostring(resolvedKey)
        local identityChanged = store.resolvedScopeFingerprint ~= nil and scopeFingerprint ~= nil
            and tostring(store.resolvedScopeFingerprint) ~= tostring(scopeFingerprint)
        if (keyChanged or identityChanged) and store.needsBarrierVerify == true then
            local reason = "scope_change_barrier_pending"
            store.lastScopeBindingError = reason
            self.stats.scopeBindingMismatches = (tonumber(self.stats.scopeBindingMismatches) or 0) + 1
            return false, nil, reason
        end
        if identityChanged and keyChanged ~= true then
            -- The historical key normalizer is intentionally unchanged for
            -- upgrade compatibility. If two exact world-qualified identities
            -- collapse to the same physical token, never guess ownership.
            local reason = "scope_binding_identity_collision"
            store.loaded = true
            store.loadStatus = "scope_binding_failed"
            store.writeFenced = true
            store.writeFenceReason = reason
            store.lastError = reason
            store.lastScopeBindingError = reason
            self.stats.scopeBindingMismatches = (tonumber(self.stats.scopeBindingMismatches) or 0) + 1
            Emit("error", "STORE_SCOPE_BINDING_COLLISION", "角色级存档身份归一化发生冲突，已拒绝跨角色读取/覆盖", { store = store.id })
            return false, nil, reason
        end
        if keyChanged or identityChanged then
            self.stats.scopeRebinds = (tonumber(self.stats.scopeRebinds) or 0) + 1
        end
    end
    store.resolvedKey = resolvedKey
    store.resolvedScopeFingerprint = scopeFingerprint
    store.lastScopeBindingError = nil

    local raw, loadErr = S.Api:LoadData(resolvedKey)
    store.lastLoadAt = NowMs()
    if loadErr ~= nil then
        store.loaded = false
        store.loadStatus = "error"
        store.lastError = tostring(loadErr)
        store.writeFenced = true
        store.writeFenceReason = "load_failed"
        self.stats.loadFailures = (tonumber(self.stats.loadFailures) or 0) + 1
        Emit("error", "STORE_LOAD_FAILED", "读取独立存档失败，已启用写保护", { store = store.id, owner = store.owner, error = loadErr })
        return false, nil, tostring(loadErr)
    end
    if raw == nil then
        local fresh, defaultErr = DefaultValue(store)
        if defaultErr ~= nil then
            store.loaded = true
            store.loadStatus = "default_failed"
            store.writeFenced = true
            store.writeFenceReason = "default_failed"
            store.lastError = tostring(defaultErr)
            return false, nil, tostring(defaultErr)
        end
        if options.apply ~= false then
            local applied, applyErr = ApplyValue(store, fresh, "empty")
            if applied ~= true then
                store.loaded = true
                store.loadStatus = "apply_failed"
                store.writeFenced = true
                store.writeFenceReason = "apply_failed"
                store.lastError = tostring(applyErr)
                Emit("error", "STORE_APPLY_FAILED", "空存档默认值应用失败，已启用写保护", { store = store.id, error = applyErr })
                return false, nil, tostring(applyErr)
            end
        end
        store.loaded = true
        store.loadStatus = "empty"
        store.lastError = nil
        store.writeFenced = false
        store.writeFenceReason = nil
        store.needsBarrierVerify = false
        store.dirty, store.dueAt, store.firstDirtyAt = false, 0, 0
        store.lastDirtyAt, store.lastDirtyReason = 0, nil
        return "empty", DeepCopy(fresh), nil
    end
    if type(raw) ~= "table" then
        store.loaded = true
        store.loadStatus = "decode_failed"
        store.lastError = "unexpected raw type: " .. tostring(type(raw))
        store.writeFenced = true
        store.writeFenceReason = "decode_failed"
        self.stats.corruptEmptyRejects = (tonumber(self.stats.corruptEmptyRejects) or 0) + 1
        self.stats.loadFailures = (tonumber(self.stats.loadFailures) or 0) + 1
        Emit("error", "STORE_DECODE_FAILED", "存档返回了非表且非空的数据，禁止按空存档处理以避免覆盖旧配置", {
            store = store.id, rawType = type(raw),
        })
        return false, nil, store.lastError
    end

    -- 中文维护注释：Framework3 的第一条读取边界必须是物理预算 + transport decode。
    -- 这一步位于 metadata/canonical/decode/apply 之前；因此所有 Feature 仍只接触原始 Lua boolean/table，
    -- 并且未来版本/损坏 transport 会 fail-closed，不会被当成“空存档”后用默认值覆盖。
    local physicalLoadInspection = self:InspectPayload(raw, store.encodedBudget)
    store.lastPhysicalInspection = physicalLoadInspection
    if type(physicalLoadInspection) ~= "table" or physicalLoadInspection.ok ~= true then
        store.loaded = true
        store.loadStatus = "encoded_load_rejected"
        store.lastError = "physical_load_rejected:" .. tostring(physicalLoadInspection and physicalLoadInspection.reason or "unknown")
        store.writeFenced = true
        store.writeFenceReason = store.lastError
        self.stats.encodedLoadRejects = (tonumber(self.stats.encodedLoadRejects) or 0) + 1
        self.stats.loadFailures = (tonumber(self.stats.loadFailures) or 0) + 1
        Emit("error", "STORE_PHYSICAL_LOAD_REJECTED", "读取到的物理存档外壳超过安全预算，已在 transport 解码前阻止读取", {
            store = store.id, reason = physicalLoadInspection and physicalLoadInspection.reason or "unknown",
        })
        return false, nil, store.lastError
    end
    local transportRaw, transportErr = self:DecodePhysicalEnvelope(raw)
    if transportRaw == nil then
        store.loaded = true
        store.loadStatus = "transport_decode_failed"
        store.lastError = "transport_decode_failed:" .. tostring(transportErr or "unknown")
        store.writeFenced = true
        store.writeFenceReason = store.lastError
        self.stats.loadFailures = (tonumber(self.stats.loadFailures) or 0) + 1
        Emit("error", "STORE_TRANSPORT_DECODE_FAILED", "Framework3 物理存档传输编码无法还原，已启用写保护", { store = store.id, error = tostring(transportErr or "unknown") })
        return false, nil, store.lastError
    end
    raw = transportRaw

    -- Reliability v4 validates the encoded envelope on READ as well as WRITE.
    -- A serializer-truncated or otherwise malformed table must never reach a
    -- business decoder/apply path merely because it is still technically a Lua
    -- table. This remains a cold persistence-boundary walk, not a feature Tick.
    local encodedLoadInspection = self:InspectPayload(raw, store.encodedBudget)
    store.lastEncodedInspection = encodedLoadInspection
    if type(encodedLoadInspection) ~= "table" or encodedLoadInspection.ok ~= true then
        store.loaded = true
        store.loadStatus = "encoded_load_rejected"
        store.lastError = "encoded_load_rejected:" .. tostring(encodedLoadInspection and encodedLoadInspection.reason or "unknown")
        store.writeFenced = true
        store.writeFenceReason = store.lastError
        self.stats.encodedLoadRejects = (tonumber(self.stats.encodedLoadRejects) or 0) + 1
        self.stats.loadFailures = (tonumber(self.stats.loadFailures) or 0) + 1
        Emit("error", "STORE_ENCODED_LOAD_REJECTED", "读取到的存档外壳不满足安全预算，已阻止解码/应用", {
            store = store.id, reason = encodedLoadInspection and encodedLoadInspection.reason or "unknown",
        })
        return false, nil, store.lastError
    end

    local meta = type(raw.__rsmeta) == "table" and raw.__rsmeta or nil
    if meta ~= nil then
        local mismatch = nil
        local metaFramework = tonumber(meta.framework)
        local metaContract = tonumber(meta.contractVersion)
        local metaReliability = tonumber(meta.reliabilityContract)
        if metaFramework ~= nil and metaFramework > (tonumber(self.FrameworkVersion) or 3) then mismatch = "framework"
        elseif metaReliability ~= nil and metaReliability > (tonumber(self.ReliabilityContractVersion) or 0) then mismatch = "reliabilityContract"
        elseif metaContract ~= nil and metaContract > (tonumber(store.contractVersion) or 1) then mismatch = "contractVersion"
        elseif NonEmptyText(meta.store) ~= nil and tostring(meta.store) ~= tostring(store.id) then mismatch = "store"
        elseif NonEmptyText(meta.owner) ~= nil and tostring(meta.owner) ~= tostring(store.owner) then mismatch = "owner"
        elseif NonEmptyText(meta.lifetime) ~= nil and tostring(meta.lifetime) ~= tostring(store.lifetime) then mismatch = "lifetime"
        elseif NonEmptyText(meta.scope) ~= nil and tostring(meta.scope) ~= tostring(store.scope) then mismatch = "scope" end
        if mismatch ~= nil then
            store.loaded = true
            store.loadStatus = "metadata_mismatch"
            store.writeFenced = true
            store.writeFenceReason = "metadata_mismatch:" .. mismatch
            store.lastError = store.writeFenceReason
            self.stats.metadataMismatches = (tonumber(self.stats.metadataMismatches) or 0) + 1
            Emit("error", "STORE_METADATA_MISMATCH", "独立存档元数据与注册契约不一致，已启用写保护", {
                store = store.id, field = mismatch, metaStore = meta.store, metaLifetime = meta.lifetime, metaScope = meta.scope,
            })
            return false, nil, store.writeFenceReason
        end
    end

    -- Reliability v6 adds an independent envelope seal over critical metadata
    -- plus the v4/v5 encoded-business fingerprint. The business fingerprint
    -- stays decoder/schema agnostic; the envelope seal detects metadata-only
    -- truncation or cross-scope substitution before any business decoder runs.
    local metaReliabilityContract = meta and tonumber(meta.reliabilityContract) or nil
    local stampedEnvelopeVersion = meta and tonumber(meta.envelopeIntegrityVersion) or nil
    local stampedEnvelopeFingerprint = meta and NonEmptyText(meta.envelopeFingerprint) or nil
    local envelopeAdvertised = stampedEnvelopeFingerprint ~= nil or stampedEnvelopeVersion ~= nil
        or (metaReliabilityContract ~= nil and metaReliabilityContract >= 6)
    if envelopeAdvertised then
        self.stats.envelopeIntegrityLoadChecks = (tonumber(self.stats.envelopeIntegrityLoadChecks) or 0) + 1
        local envelopeIntegrityErr = nil
        if meta == nil then
            envelopeIntegrityErr = "metadata_missing"
        elseif metaReliabilityContract == nil or metaReliabilityContract < 6
            or metaReliabilityContract > (tonumber(self.ReliabilityContractVersion) or 0) then
            envelopeIntegrityErr = "reliability_contract:" .. tostring(metaReliabilityContract)
        elseif stampedEnvelopeVersion ~= tonumber(self.EnvelopeIntegrityContractVersion) then
            envelopeIntegrityErr = "envelope_version:" .. tostring(stampedEnvelopeVersion)
        elseif stampedEnvelopeFingerprint == nil then
            envelopeIntegrityErr = "envelope_fingerprint_missing"
        elseif meta.framework == nil or NonEmptyText(meta.store) == nil or NonEmptyText(meta.owner) == nil
            or meta.contractVersion == nil or NonEmptyText(meta.lifetime) == nil or NonEmptyText(meta.scope) == nil
            or meta.schema == nil or meta.reliabilityContract == nil or meta.integrityVersion == nil
            or NonEmptyText(meta.encodedFingerprint or meta.payloadFingerprint) == nil then
            envelopeIntegrityErr = "required_metadata_missing"
        elseif store.scope == SCOPE.Character and tonumber(meta.scopeBindingContract) ~= tonumber(self.ScopeBindingContractVersion) then
            envelopeIntegrityErr = "scope_binding_contract:" .. tostring(meta.scopeBindingContract)
        elseif store.scope == SCOPE.Character and (NonEmptyText(meta.scopeIdentityFingerprint) == nil
            or scopeFingerprint == nil or tostring(meta.scopeIdentityFingerprint) ~= tostring(scopeFingerprint)) then
            envelopeIntegrityErr = "scope_identity_fingerprint"
        else
            local actualEnvelopeFingerprint, actualEnvelopeErr = self:FingerprintEnvelopeIntegrity(raw)
            if actualEnvelopeFingerprint == nil then
                envelopeIntegrityErr = "envelope_fingerprint_failed:" .. tostring(actualEnvelopeErr or "unknown")
            elseif tostring(actualEnvelopeFingerprint) ~= tostring(stampedEnvelopeFingerprint) then
                envelopeIntegrityErr = "envelope_fingerprint_mismatch:" .. tostring(stampedEnvelopeFingerprint) .. ">" .. tostring(actualEnvelopeFingerprint)
            end
        end
        if envelopeIntegrityErr ~= nil then
            store.loaded = true
            store.loadStatus = "envelope_integrity_failed"
            store.writeFenced = true
            store.writeFenceReason = "envelope_integrity_failed:" .. tostring(envelopeIntegrityErr)
            store.lastError = store.writeFenceReason
            self.stats.envelopeIntegrityLoadFailures = (tonumber(self.stats.envelopeIntegrityLoadFailures) or 0) + 1
            self.stats.loadFailures = (tonumber(self.stats.loadFailures) or 0) + 1
            Emit("error", "STORE_ENVELOPE_INTEGRITY_FAILED", "存档元数据封印校验失败，已在业务解码前阻止读取/应用", {
                store = store.id, error = envelopeIntegrityErr,
            })
            return false, nil, store.lastError
        end
    end

    local storedSchema = meta and tonumber(meta.schema) or tonumber(store.legacySchemaVersion) or 0
    if storedSchema > store.schemaVersion then
        store.loaded = true
        store.loadStatus = "future_schema"
        store.writeFenced = true
        store.writeFenceReason = "future_schema:" .. tostring(storedSchema) .. ">" .. tostring(store.schemaVersion)
        store.lastError = store.writeFenceReason
        Emit("warning", "STORE_FUTURE_SCHEMA", "独立存档来自更高 Schema，当前版本只读保护", {
            store = store.id, storedSchema = storedSchema, currentSchema = store.schemaVersion,
        })
        return false, nil, store.writeFenceReason
    end

    -- Cross-reload business integrity check. Integrity v2 canonicalizes only
    -- non-integral numeric representation so RU SaveData float normalization
    -- cannot create false corruption fences. Integrity v1 remains readable. If
    -- a v1 non-critical settings Store has a business hash mismatch while its
    -- v6+ metadata envelope seal is intact, treat it as a one-generation
    -- compatibility load and immediately queue a v2 restamp after decode,
    -- budget, migration and apply all succeed. Critical/journal Stores remain
    -- fail-closed and never use this compatibility escape hatch.
    local stampedFingerprint = meta and NonEmptyText(meta.encodedFingerprint or meta.payloadFingerprint) or nil
    local stampedIntegrityVersion = meta and tonumber(meta.integrityVersion) or nil
    local stampedReliabilityContract = meta and tonumber(meta.reliabilityContract) or nil
    local minIntegrityReliability = tonumber(self.MinIntegrityReliabilityContractVersion) or 4
    local currentReliability = tonumber(self.ReliabilityContractVersion) or minIntegrityReliability
    local currentIntegrity = tonumber(self.IntegrityContractVersion) or 4
    local contentBlindIntegrity = tonumber(self.ContentBlindCanonicalContractVersion) or 3
    local preCanonicalIntegrity = tonumber(self.PreCanonicalIntegrityContractVersion) or 2
    local legacyIntegrity = tonumber(self.LegacyIntegrityContractVersion) or 1
    local integrityAdvertised = stampedFingerprint ~= nil or stampedIntegrityVersion ~= nil
        or (stampedReliabilityContract ~= nil and stampedReliabilityContract >= minIntegrityReliability)
    local legacyIntegrityUpgradeNeeded = false
    local integrityUpgradeNeeded = false
    local preDecodedValue = nil
    local serializerRepairNeeded = false
    local serializerRepairedRaw = nil
    if integrityAdvertised then
        self.stats.integrityLoadChecks = (tonumber(self.stats.integrityLoadChecks) or 0) + 1
        local integrityErr = nil
        if stampedReliabilityContract == nil or stampedReliabilityContract < minIntegrityReliability
            or stampedReliabilityContract > currentReliability then
            integrityErr = "reliability_contract:" .. tostring(stampedReliabilityContract)
        elseif stampedIntegrityVersion == contentBlindIntegrity then
            -- Integrity v3 stamps came from the content-blind canonical era
            -- (see ContentBlindCanonicalContractVersion): the stamped hash was
            -- derived from the store's DEFAULT table shape, not its content,
            -- so there is no meaningful fingerprint to re-verify here. Treat
            -- the stamp as absent and recover through the same gated
            -- one-generation path as v2 (seal + decode + budget + apply must
            -- all pass), then re-stamp with the repaired v4 canonical.
            local decoded, decodeErr = DecodeValue(store, raw)
            local upgradedInspection = nil
            if decoded ~= nil then upgradedInspection = self:InspectPayload(decoded, store.budget) end
            if store.allowIntegrityUpgrade == true
                and (tonumber(stampedReliabilityContract) or 0) >= minIntegrityReliability
                and envelopeAdvertised == true
                and decoded ~= nil
                and type(upgradedInspection) == "table" and upgradedInspection.ok == true then
                integrityUpgradeNeeded = true
                local canonical, canonicalErr = self:CanonicalIntegrityValue(store, decoded)
                if type(canonical) == "table"
                    and not (type(store.encode) == "function" and type(store.decode) == "function") then
                    decoded = canonical
                end
                preDecodedValue = decoded
                store.lastIntegrityStatus = "integrity_contract_upgrade_recovery"
                store.lastIntegrityFingerprint = stampedFingerprint
                store.lastIntegrityError = "content_blind_canonical_stamp"
                self.stats.integrityUpgradeRecoveries = (tonumber(self.stats.integrityUpgradeRecoveries) or 0) + 1
                Emit("info", "STORE_INTEGRITY_CONTRACT_UPGRADE_RECOVERY",
                    "v3 内容盲盖章无法作为完整性证据；元数据封印与业务校验全部通过，按契约升级加载并在保存时重盖 v4 canonical 指纹", {
                        store = store.id, oldFingerprint = stampedFingerprint,
                    })
            else
                integrityErr = "fingerprint_mismatch:" .. tostring(stampedFingerprint)
                    .. "|contract_upgrade_gate=reliability:" .. tostring(stampedReliabilityContract)
                    .. "/optOut:" .. tostring(store.allowIntegrityUpgrade == false)
                    .. "/decode:" .. tostring(decoded ~= nil)
                    .. "/budget:" .. tostring(type(upgradedInspection) == "table" and upgradedInspection.ok == true)
            end
        elseif stampedIntegrityVersion == currentIntegrity then
            -- Integrity v4: verify the CANONICAL value instead of the raw
            -- encoded envelope. The metadata envelope seal and the raw budget
            -- inspection have already passed, so decoding here exposes the
            -- decoder to exactly the input it would have received after a
            -- successful legacy check; decode hooks in this codebase are pure
            -- normalizers. A logical-preserving RU representation change is
            -- absorbed by re-canonicalization; content corruption is not.
            local decoded, decodeErr = DecodeValue(store, raw)
            if decoded == nil then
                integrityErr = "decode_failed:" .. tostring(decodeErr or "decoded payload missing")
            else
                local canonical, canonicalErr = self:CanonicalIntegrityValue(store, decoded)
                if canonical == nil then
                    integrityErr = "fingerprint_failed:" .. tostring(canonicalErr or "canonical_value_missing")
                else
                    local actualFingerprint, actualErr = self:FingerprintCanonicalValue(store, canonical)
                    if actualFingerprint == nil then
                        integrityErr = "fingerprint_failed:" .. tostring(actualErr or "unknown")
                    elseif tostring(actualFingerprint) ~= tostring(stampedFingerprint) then
                        -- A current-v4 mismatch normally remains fail-closed. One
                        -- narrow exception exists for Stores that can deterministically
                        -- rebuild the exact historical logical candidate after their
                        -- own canonicalizer changed or RU omitted a representational
                        -- field. We accept it only when that candidate reproduces the
                        -- stamped fingerprint byte-for-byte and the independent v6+
                        -- envelope seal already verified above.
                        local recoveredHistoricalCanonical = false
                        if envelopeAdvertised == true and store.allowIntegrityUpgrade == true then
                            local decodedInspection = self:InspectPayload(decoded, store.budget)
                            if type(decodedInspection) == "table" and decodedInspection.ok == true then
                                -- 中文维护注释（恢复顺序）：先尝试 Core 能严格证明的 Framework2
                                -- `false/空表` 省略（含 default=true 被用户关成 false）；匹配不上才交给 Store 自己的 typed/custom
                                -- recovery hook。两条路径最终都必须重算并命中同一个旧 fingerprint，Core
                                -- 不会因为“看起来像 RU 省略”就绕过完整性门。
                                local rebuiltOk, historicalCanonical, recoveredDomain = pcall(
                                    self.RebuildFramework2SerializerOmissions, self, store, DeepCopy(decoded),
                                    stampedFingerprint, DeepCopy(raw))
                                if rebuiltOk ~= true or type(historicalCanonical) ~= "table" then
                                    if type(store.rebuildCanonicalForIntegrity) == "function" then
                                        -- Contract v2 passes the original raw envelope as a fourth argument. Existing
                                        -- hooks remain source-compatible (Lua ignores extra args). A hook may optionally
                                        -- return a second table: the recovered CURRENT Domain value. This is necessary when
                                        -- decode() cannot distinguish an RU-omitted false from a missing default-true field.
                                        rebuiltOk, historicalCanonical, recoveredDomain = pcall(
                                            store.rebuildCanonicalForIntegrity, DeepCopy(decoded), stampedFingerprint,
                                            canonical, DeepCopy(raw))
                                    else
                                        rebuiltOk, historicalCanonical, recoveredDomain = false, nil, nil
                                    end
                                end
                                if rebuiltOk == true and type(historicalCanonical) == "table" then
                                    local historicalFingerprint = self:FingerprintCanonicalValue(store, historicalCanonical)
                                    if historicalFingerprint ~= nil and tostring(historicalFingerprint) == tostring(stampedFingerprint) then
                                        -- The historical candidate is now integrity-authenticated by the OLD stamp.
                                        -- Apply must be derived from that recovered logical value, not blindly from
                                        -- canonical(decoded), or default-sensitive data could be silently changed.
                                        local recoveredApplyValue = decoded
                                        local recoveredApplyOk = true
                                        if type(recoveredDomain) == "table" then
                                            local recoveredDomainInspection = self:InspectPayload(recoveredDomain, store.budget)
                                            if type(recoveredDomainInspection) ~= "table" or recoveredDomainInspection.ok ~= true then
                                                recoveredApplyOk = false
                                            else
                                                recoveredApplyValue = recoveredDomain
                                            end
                                        elseif not (type(store.encode) == "function" and type(store.decode) == "function") then
                                            local recoveredCanonical = self:CanonicalIntegrityValue(store, historicalCanonical)
                                            if recoveredCanonical == nil then
                                                recoveredApplyOk = false
                                            else
                                                local recoveredInspection = self:InspectPayload(recoveredCanonical, store.budget)
                                                if type(recoveredInspection) ~= "table" or recoveredInspection.ok ~= true then
                                                    recoveredApplyOk = false
                                                else
                                                    recoveredApplyValue = recoveredCanonical
                                                end
                                            end
                                        end
                                        local recoveredCurrentCanonical = nil
                                        if recoveredApplyOk == true then
                                            recoveredCurrentCanonical = self:CanonicalIntegrityValue(store, recoveredApplyValue)
                                            local recoveredCanonicalInspection = recoveredCurrentCanonical ~= nil
                                                and self:InspectPayload(recoveredCurrentCanonical, store.encodedBudget) or nil
                                            if type(recoveredCanonicalInspection) ~= "table" or recoveredCanonicalInspection.ok ~= true then
                                                recoveredApplyOk = false
                                            end
                                        end
                                        if recoveredApplyOk == true then
                                            local recoveredCurrentFingerprint = self:FingerprintCanonicalValue(store, recoveredCurrentCanonical)
                                            local needsRestamp = recoveredCurrentFingerprint == nil
                                                or tostring(recoveredCurrentFingerprint) ~= tostring(stampedFingerprint)
                                            recoveredHistoricalCanonical = true
                                            integrityUpgradeNeeded = needsRestamp
                                            preDecodedValue = recoveredApplyValue
                                            store.lastIntegrityStatus = needsRestamp
                                                and "historical_canonical_recovery" or "verified_canonical_recovered_representation"
                                            store.lastIntegrityFingerprint = historicalFingerprint
                                            store.lastIntegrityError = needsRestamp
                                                and "canonicalizer_changed" or "serializer_omission_recovered"
                                            self.stats.integrityUpgradeRecoveries = (tonumber(self.stats.integrityUpgradeRecoveries) or 0) + 1
                                            Emit("info", "STORE_HISTORICAL_CANONICAL_RECOVERY",
                                                needsRestamp
                                                    and "旧版 Store canonical 精确复原已匹配原指纹；按当前 canonical 重新归一该历史逻辑值并排队重盖章"
                                                    or "Store canonical 精确复原已匹配原指纹；已恢复 RU 省略的逻辑值，无需改写现有盖章", {
                                                        store = store.id, oldFingerprint = stampedFingerprint,
                                                        newFingerprint = recoveredCurrentFingerprint or actualFingerprint,
                                                        restamp = needsRestamp,
                                                    })
                                        end
                                    end
                                end
                            end
                        end
                        -- Contract v3: after exact historical reconstruction has
                        -- exhausted all deterministic candidates, a Store may opt
                        -- into a ONE-TIME known-stamp migration. This is not a
                        -- generic mismatch bypass. The hook receives the exact old
                        -- stamp and raw envelope, and is responsible for whitelisting
                        -- that stamp + validating its own legacy payload shape. Core
                        -- still enforces envelope integrity (already passed above),
                        -- decoded/current-domain budgets, current canonicalization and
                        -- immediate restamp before the Store can return to normal use.
                        if recoveredHistoricalCanonical ~= true and envelopeAdvertised == true
                            and store.allowIntegrityUpgrade == true
                            and type(store.recoverKnownLegacyCanonical) == "function" then
                            local knownOk, knownDomain, knownReason = pcall(
                                store.recoverKnownLegacyCanonical, DeepCopy(decoded), stampedFingerprint, canonical, DeepCopy(raw))
                            if knownOk == true and type(knownDomain) == "table" then
                                local knownInspection = self:InspectPayload(knownDomain, store.budget)
                                local knownCanonical = nil
                                local knownCanonicalInspection = nil
                                if type(knownInspection) == "table" and knownInspection.ok == true then
                                    knownCanonical = self:CanonicalIntegrityValue(store, knownDomain)
                                    knownCanonicalInspection = knownCanonical ~= nil
                                        and self:InspectPayload(knownCanonical, store.encodedBudget) or nil
                                end
                                if type(knownCanonicalInspection) == "table" and knownCanonicalInspection.ok == true then
                                    local knownCurrentFingerprint = self:FingerprintCanonicalValue(store, knownCanonical)
                                    if knownCurrentFingerprint ~= nil then
                                        recoveredHistoricalCanonical = true
                                        integrityUpgradeNeeded = true
                                        preDecodedValue = knownDomain
                                        store.lastIntegrityStatus = "known_legacy_canonical_recovery"
                                        store.lastIntegrityFingerprint = tostring(stampedFingerprint)
                                        store.lastIntegrityError = tostring(knownReason or "known_legacy_stamp")
                                        self.stats.integrityUpgradeRecoveries = (tonumber(self.stats.integrityUpgradeRecoveries) or 0) + 1
                                        self.stats.knownLegacyCanonicalRecoveries = (tonumber(self.stats.knownLegacyCanonicalRecoveries) or 0) + 1
                                        Emit("warning", "STORE_KNOWN_LEGACY_CANONICAL_RECOVERY",
                                            "已识别并验证 Store 专属历史盖章；保留现存业务数据并立即按当前 canonical 重盖章", {
                                                store = store.id, oldFingerprint = stampedFingerprint,
                                                newFingerprint = knownCurrentFingerprint, reason = knownReason,
                                            })
                                    end
                                else
                                    self.stats.knownLegacyCanonicalRecoveryRejects = (tonumber(self.stats.knownLegacyCanonicalRecoveryRejects) or 0) + 1
                                end
                            elseif knownOk ~= true or knownDomain ~= nil then
                                self.stats.knownLegacyCanonicalRecoveryRejects = (tonumber(self.stats.knownLegacyCanonicalRecoveryRejects) or 0) + 1
                            end
                        end
                        if recoveredHistoricalCanonical ~= true then
                            integrityErr = "fingerprint_mismatch:" .. tostring(stampedFingerprint) .. ">" .. tostring(actualFingerprint)
                            local historicalProbe = NonEmptyText(store.lastHistoricalRecoveryProbe)
                            if historicalProbe ~= nil then
                                integrityErr = integrityErr .. "|historical_probe=" .. historicalProbe
                            end
                        end
                    else
                        store.lastIntegrityStatus = "verified_canonical"
                        store.lastIntegrityFingerprint = actualFingerprint
                        store.lastIntegrityError = nil
                        -- v4 pipeline: Decode -> Normalize -> Verify -> Apply.
                        -- Plain stores apply the canonical (normalized) value so
                        -- the Domain receives the fixed shape even without a
                        -- schema migration; typed-codec stores apply the decoded
                        -- Domain, whose normalize is performed by decode().
                        if type(store.encode) == "function" and type(store.decode) == "function" then
                            preDecodedValue = decoded
                        else
                            preDecodedValue = canonical
                        end
                    end
                end
            end
        elseif stampedIntegrityVersion ~= preCanonicalIntegrity and stampedIntegrityVersion ~= legacyIntegrity then
            integrityErr = "integrity_version:" .. tostring(stampedIntegrityVersion)
        elseif stampedFingerprint == nil then
            integrityErr = "fingerprint_missing"
        else
            local actualFingerprint, actualErr
            if stampedIntegrityVersion == legacyIntegrity then
                actualFingerprint, actualErr = self:FingerprintEncodedPayloadV1(raw, store.encodedBudget)
            else
                actualFingerprint, actualErr = self:FingerprintEncodedPayload(raw, store.encodedBudget)
            end
            if actualFingerprint == nil then
                integrityErr = "fingerprint_failed:" .. tostring(actualErr or "unknown")
            elseif tostring(actualFingerprint) ~= tostring(stampedFingerprint) then
                local compatibilityAllowed = stampedIntegrityVersion == legacyIntegrity
                    and (tonumber(stampedReliabilityContract) or 0) >= 6
                    and envelopeAdvertised == true
                    and store.verifyAfterSave ~= true
                    and store.recoverableReplacement ~= true
                if compatibilityAllowed then
                    legacyIntegrityUpgradeNeeded = true
                    store.lastIntegrityStatus = "legacy_v1_compatibility"
                    store.lastIntegrityFingerprint = actualFingerprint
                    store.lastIntegrityError = "fingerprint_mismatch:" .. tostring(stampedFingerprint) .. ">" .. tostring(actualFingerprint)
                    self.stats.integrityCompatibilityLoads = (tonumber(self.stats.integrityCompatibilityLoads) or 0) + 1
                    Emit("info", "STORE_INTEGRITY_V1_COMPATIBILITY_LOAD",
                        "旧版完整性指纹与 RU 序列化后的数值表示不一致；元数据封印有效，完成业务校验后将升级为 v2 指纹", {
                            store = store.id, oldFingerprint = stampedFingerprint, loadedFingerprint = actualFingerprint,
                        })
                else
                    -- Integrity v2 remains fail-closed by default. A Store may
                    -- opt in to one narrowly-proven serializer-shape repair: the
                    -- metadata envelope must already have verified, the Store
                    -- must be non-critical/non-journal, and its hook must rebuild
                    -- a candidate whose CURRENT integrity hash is EXACTLY the
                    -- previously stamped hash. Any lost/changed business value
                    -- therefore still fails and keeps the Store fenced.
                    local repairAllowed = stampedIntegrityVersion == preCanonicalIntegrity
                        and (tonumber(stampedReliabilityContract) or 0) >= 6
                        and envelopeAdvertised == true
                        and store.verifyAfterSave ~= true
                        and store.recoverableReplacement ~= true
                        and type(store.rebuildEncodedForIntegrity) == "function"
                    local repaired = false
                    if repairAllowed then
                        local okRepair, candidate, repairReason = pcall(store.rebuildEncodedForIntegrity, DeepCopy(raw), {
                            store = store.id, stampedFingerprint = stampedFingerprint, loadedFingerprint = actualFingerprint,
                        })
                        -- A hook may return one candidate table or { candidates =
                        -- { ... } } when several historical encoded shapes existed
                        -- (e.g. a pre-codec Domain form and an intermediate wrapped
                        -- form). Persistence hashes each candidate and accepts only
                        -- an exact stamp reproduction.
                        local candidateList = nil
                        if okRepair == true and type(candidate) == "table" and type(candidate.candidates) == "table" then
                            candidateList = candidate.candidates
                        elseif okRepair == true and type(candidate) == "table" then
                            candidateList = { candidate }
                        end
                        if type(candidateList) == "table" then
                            for candidateIndex = 1, #candidateList do
                                local candidateValue = candidateList[candidateIndex]
                                if type(candidateValue) ~= "table" then
                                    self.stats.integritySerializerRepairFailures = (tonumber(self.stats.integritySerializerRepairFailures) or 0) + 1
                                else
                                    local candidateInspection = self:InspectPayload(candidateValue, store.encodedBudget)
                                    local candidateFingerprint, candidateErr = nil, nil
                                    if type(candidateInspection) == "table" and candidateInspection.ok == true then
                                        candidateFingerprint, candidateErr = self:FingerprintEncodedPayload(candidateValue, store.encodedBudget)
                                    else
                                        candidateErr = "candidate_rejected:" .. tostring(candidateInspection and candidateInspection.reason or "unknown")
                                    end
                                    if candidateFingerprint ~= nil and tostring(candidateFingerprint) == tostring(stampedFingerprint) then
                                        repaired = true
                                        serializerRepairNeeded = true
                                        serializerRepairedRaw = candidateValue
                                        store.lastIntegrityStatus = "serializer_repair_verified"
                                        store.lastIntegrityFingerprint = candidateFingerprint
                                        store.lastIntegrityError = "fingerprint_mismatch:" .. tostring(stampedFingerprint) .. ">" .. tostring(actualFingerprint)
                                        self.stats.integritySerializerRepairLoads = (tonumber(self.stats.integritySerializerRepairLoads) or 0) + 1
                                        Emit("info", "STORE_INTEGRITY_SERIALIZER_REPAIR",
                                            "RU 序列化改变了已知 Store 的编码表示；重建候选精确复现原完整性指纹，允许加载并立即改写为稳定编码", {
                                                store = store.id, oldFingerprint = stampedFingerprint, loadedFingerprint = actualFingerprint,
                                                candidate = candidateIndex, reason = tostring(repairReason or "verified_reconstruction"),
                                            })
                                        break
                                    end
                                end
                            end
                            if repaired ~= true then
                                self.stats.integritySerializerRepairFailures = (tonumber(self.stats.integritySerializerRepairFailures) or 0) + 1
                                Emit("warning", "STORE_INTEGRITY_SERIALIZER_REPAIR_REJECTED",
                                    "Store 提供的序列化修复候选无法复现原完整性指纹，继续按真实损坏 Fail Closed", {
                                        store = store.id, oldFingerprint = stampedFingerprint,
                                        error = tostring(repairReason or "fingerprint_not_reproduced"),
                                    })
                            end
                        elseif repairAllowed then
                            self.stats.integritySerializerRepairFailures = (tonumber(self.stats.integritySerializerRepairFailures) or 0) + 1
                        end
                    end
                    if repaired ~= true then
                        -- One-generation upgrade escape for legacy v2 raw-envelope
                        -- stamps: the RU serializer changed the on-disk business
                        -- representation of the pre-canonical era. Real-machine
                        -- evidence 2026-09-05 shows this drift is serializer-
                        -- GENERAL (life.bonds / gear payload journal shards /
                        -- death_review record shards), so recovery is the default
                        -- for every v2 stamp unless the domain explicitly opts
                        -- out. Accept ONLY when the independent metadata envelope
                        -- seal is valid AND the full business path (decode +
                        -- budget) still passes; the store is then re-stamped with
                        -- the canonical v3 contract at the deferred upgrade save,
                        -- which re-arms strict fail-closed verification. For
                        -- verifyAfterSave/recoverableReplacement journal shards
                        -- this is strictly LESS destructive than the alternative
                        -- replaceCorrupt recovery, which overwrites the shard.
                        -- Real-machine 2026-09-06: a v2-stamped store whose
                        -- envelope predates reliability v6 stayed fenced with
                        -- v3Upgrade=0/0 because BOTH the v1-compat path and this
                        -- gate demanded reliability>=6. The seal + full business
                        -- validation is the actual evidence; the floor only has
                        -- to prove the envelope IS integrity-era. One unified
                        -- gated recovery now covers v1 AND v2 stamps.
                        local upgradeAllowed = store.allowIntegrityUpgrade == true
                            and stampedIntegrityVersion == preCanonicalIntegrity
                            and (tonumber(stampedReliabilityContract) or 0) >= minIntegrityReliability
                            and envelopeAdvertised == true
                        local upgraded = false
                        if upgradeAllowed then
                            local okDecode, upgradedValue, upgradeDecodeErr = pcall(DecodeValue, store, raw)
                            local upgradedInspection = nil
                            if okDecode == true and upgradedValue ~= nil then
                                upgradedInspection = self:InspectPayload(upgradedValue, store.budget)
                            end
                            if okDecode ~= true or upgradedValue == nil
                                or type(upgradedInspection) ~= "table" or upgradedInspection.ok ~= true then
                                -- Silent rejection here made the real machine
                                -- unfalsifiable (v3Upgrade=0/0 with no clue why).
                                self.stats.integrityUpgradeValidationFailures = (tonumber(self.stats.integrityUpgradeValidationFailures) or 0) + 1
                                Emit("warning", "STORE_INTEGRITY_UPGRADE_VALIDATION_FAILED",
                                    "受控升级的解码/预算校验未通过，继续按真实损坏 Fail Closed", {
                                        store = store.id,
                                        decodeOk = okDecode == true,
                                        decodeError = tostring(okDecode == true and (upgradeDecodeErr or "none") or upgradeDecodeErr or "decode exception"),
                                        budgetReason = type(upgradedInspection) == "table" and tostring(upgradedInspection.reason or "unknown") or "inspection_failed",
                                    })
                            end
                            if okDecode == true and upgradedValue ~= nil then
                                if type(upgradedInspection) == "table" and upgradedInspection.ok == true then
                                    upgraded = true
                                    integrityUpgradeNeeded = true
                                    local canonicalValue = self:CanonicalIntegrityValue(store, upgradedValue)
                                    local divergence = nil
                                    local applyValue = upgradedValue
                                    if type(canonicalValue) == "table"
                                        and not (type(store.encode) == "function" and type(store.decode) == "function") then
                                        -- Plain stores: apply the normalized canonical form and
                                        -- name the exact field the serializer/normalize gap changed.
                                        applyValue = canonicalValue
                                        divergence = self:DescribeCanonicalDivergence(upgradedValue, canonicalValue)
                                    end
                                    preDecodedValue = applyValue
                                    store.lastIntegrityStatus = "integrity_upgrade_recovery"
                                    store.lastIntegrityFingerprint = actualFingerprint
                                    store.lastIntegrityError = "fingerprint_mismatch:" .. tostring(stampedFingerprint) .. ">" .. tostring(actualFingerprint)
                                    store.lastIntegrityDivergence = divergence
                                    self.stats.integrityUpgradeRecoveries = (tonumber(self.stats.integrityUpgradeRecoveries) or 0) + 1
                                    Emit("info", "STORE_INTEGRITY_UPGRADE_RECOVERY",
                                        "旧版完整性指纹与磁盘表示不一致，但元数据封印与业务校验全部通过；按契约升级加载并将在保存时改盖 canonical 指纹", {
                                            store = store.id, oldFingerprint = stampedFingerprint, loadedFingerprint = actualFingerprint,
                                            divergence = divergence,
                                        })
                                end
                            end
                        end
                        if upgraded ~= true then
                            -- Make the fence DECISIVE on the real machine: the
                            -- 2026-09-06 banner showed v3Upgrade=0/0 with no way
                            -- to tell WHICH gate condition refused the recovery.
                            integrityErr = "fingerprint_mismatch:" .. tostring(stampedFingerprint) .. ">" .. tostring(actualFingerprint)
                                .. "|upgrade_gate=reliability:" .. tostring(stampedReliabilityContract)
                                .. "/version:" .. tostring(stampedIntegrityVersion)
                                .. "/optOut:" .. tostring(store.allowIntegrityUpgrade == false)
                        end
                    end
                end
            else
                store.lastIntegrityStatus = stampedIntegrityVersion == legacyIntegrity and "verified_v1" or "verified_v2"
                store.lastIntegrityFingerprint = actualFingerprint
                store.lastIntegrityError = nil
                if stampedIntegrityVersion == legacyIntegrity and (tonumber(stampedReliabilityContract) or 0) >= 6
                    and store.verifyAfterSave ~= true and store.recoverableReplacement ~= true then
                    -- Exact v1 loads are healthy, but restamping them with v2
                    -- prevents the next native round-trip from re-entering the
                    -- representation-sensitive legacy contract.
                    legacyIntegrityUpgradeNeeded = true
                elseif stampedIntegrityVersion == preCanonicalIntegrity
                    and (tonumber(stampedReliabilityContract) or 0) >= 6
                    and store.allowIntegrityUpgrade == true then
                    -- Exact v2 loads are healthy today, but the raw-envelope
                    -- contract is representation-fragile (serializer-general
                    -- drift, 2026-09-05 real-machine evidence). Restamping with
                    -- the canonical v3 contract at the deferred save removes the
                    -- false-fence class entirely for this Store, including
                    -- journal shards whose next drift would otherwise fence.
                    integrityUpgradeNeeded = true
                end
            end
        end
        if integrityErr ~= nil then
            store.loaded = true
            store.loadStatus = "integrity_failed"
            store.writeFenced = true
            store.writeFenceReason = "integrity_failed:" .. tostring(integrityErr)
            store.lastError = store.writeFenceReason
            store.lastIntegrityStatus = "failed"
            store.lastIntegrityFingerprint = nil
            store.lastIntegrityError = integrityErr
            self.stats.integrityLoadFailures = (tonumber(self.stats.integrityLoadFailures) or 0) + 1
            self.stats.loadFailures = (tonumber(self.stats.loadFailures) or 0) + 1
            Emit("error", "STORE_INTEGRITY_FAILED", "存档跨重载完整性校验失败，已阻止解码/应用并启用写保护", {
                store = store.id, error = integrityErr,
            })
            return false, nil, store.lastError
        end
    else
        store.lastIntegrityStatus = "legacy_unstamped"
        store.lastIntegrityFingerprint = nil
        store.lastIntegrityError = nil
        self.stats.integrityLegacyLoads = (tonumber(self.stats.integrityLegacyLoads) or 0) + 1
    end

    local function RejectDecodedLoad(phase, inspection)
        local reason = tostring(inspection and inspection.reason or "unknown")
        store.loaded = true
        store.loadStatus = "decoded_load_rejected"
        store.lastError = "decoded_load_rejected:" .. tostring(phase or "decode") .. ":" .. reason
        store.writeFenced = true
        store.writeFenceReason = store.lastError
        store.dirty = false
        store.dueAt = 0
        store.firstDirtyAt = 0
        store.lastDirtyAt = 0
        store.lastDirtyReason = nil
        self.stats.decodedLoadRejects = (tonumber(self.stats.decodedLoadRejects) or 0) + 1
        self.stats.loadFailures = (tonumber(self.stats.loadFailures) or 0) + 1
        Emit("error", "STORE_DECODED_LOAD_REJECTED", "解码/迁移后的 Domain payload 超出 Store 安全预算，已阻止应用并启用写保护", {
            store = store.id, phase = tostring(phase or "decode"), reason = reason,
            nodes = inspection and inspection.nodes or nil, depth = inspection and inspection.maxDepth or nil,
        })
        return false, nil, store.lastError
    end

    local decodeRaw = serializerRepairedRaw or raw
    local value, decodeErr
    if preDecodedValue ~= nil then
        -- v3 canonical verification and the gated upgrade recovery already
        -- decoded this payload successfully; reuse that exact value so the
        -- business path sees the same object that was verified.
        value = preDecodedValue
    else
        value, decodeErr = DecodeValue(store, decodeRaw)
        if decodeErr == nil and value == nil then decodeErr = "decoded payload missing" end
    end
    if decodeErr ~= nil then
        store.loaded = true
        store.loadStatus = "decode_failed"
        store.writeFenced = true
        store.writeFenceReason = "decode_failed"
        store.lastError = decodeErr
        self.stats.loadFailures = (tonumber(self.stats.loadFailures) or 0) + 1
        Emit("error", "STORE_DECODE_FAILED", "独立存档解析失败，已启用写保护", { store = store.id, error = decodeErr })
        return false, nil, decodeErr
    end

    -- Custom decoders can expand a compact encoded table dramatically. Budget
    -- the Domain result before migration/apply so a small disk envelope cannot
    -- bypass the business Store's bounded-memory contract.
    local decodedInspection = self:InspectPayload(value, store.budget)
    store.lastDecodedInspection = decodedInspection
    if type(decodedInspection) ~= "table" or decodedInspection.ok ~= true then
        return RejectDecodedLoad("decode", decodedInspection)
    end

    -- Reliability v7 defers migration/period-reset dirty metadata until the
    -- transformed Domain has passed its final budget and apply() has succeeded.
    -- Otherwise a failed apply could leave a terminal, write-fenced Store marked
    -- dirty and make the debounce loop repeatedly attempt an unsafe save.
    local deferredSaveReason = nil
    local deferredSaveDelayMs = nil
    if legacyIntegrityUpgradeNeeded == true then
        deferredSaveReason = "integrity_v2_upgrade"
        deferredSaveDelayMs = 0
    elseif serializerRepairNeeded == true then
        deferredSaveReason = "integrity_serializer_repair"
        deferredSaveDelayMs = 0
    elseif integrityUpgradeNeeded == true then
        deferredSaveReason = "integrity_v4_upgrade"
        deferredSaveDelayMs = 0
    end

    if storedSchema < store.schemaVersion then
        if type(store.migrate) ~= "function" then
            if storedSchema ~= store.legacySchemaVersion then
                store.writeFenced = true
                store.writeFenceReason = "migration_missing"
                store.lastError = store.writeFenceReason
                Emit("error", "STORE_MIGRATION_MISSING", "独立存档需要迁移但未提供迁移函数", {
                    store = store.id, from = storedSchema, to = store.schemaVersion,
                })
                return false, nil, store.writeFenceReason
            end
        else
            local ok, migrated, migrateErr = pcall(store.migrate, DeepCopy(value), storedSchema, store.schemaVersion)
            if not ok or migrated == nil then
                local message = ok and tostring(migrateErr or "migration returned nil") or tostring(migrated)
                store.writeFenced = true
                store.writeFenceReason = "migration_failed"
                store.lastError = message
                Emit("error", "STORE_MIGRATION_FAILED", "独立存档迁移失败，已保留原数据并启用写保护", {
                    store = store.id, from = storedSchema, to = store.schemaVersion, error = message,
                })
                return false, nil, message
            end
            value = migrated -- 中文维护注释：只在 migration 成功且返回非 nil Domain 后替换待 Apply 值；Integrity recovery 已证明的当前 Domain 仍必须经过同一迁移边界。
            self.stats.migrations = (tonumber(self.stats.migrations) or 0) + 1 -- 中文维护注释：schema 迁移统计照常增加，用于区分历史档升级与普通 current-schema Load。
            if deferredSaveReason == nil then -- 中文维护注释：若前面已经发生 integrity/historical/known-stamp recovery，就保留其更强的“立即重盖”语义，禁止普通 schema migration 把 0ms durability 修复降成 debounce 保存。
                deferredSaveReason = "migration" -- 中文维护注释：只有纯 schema 升级、没有更高优先级完整性恢复时，才使用普通 migration 脏标记原因。
                deferredSaveDelayMs = self.defaultDelayMs -- 中文维护注释：纯迁移可按既有 debounce 保存；完整性恢复路径已在前面设置 0ms，不在此覆盖。
            end -- 中文维护注释：结束 deferred save 优先级保护；period reset 后续仍可按其更高业务语义显式覆盖。
        end
    end

    local currentPeriod = select(1, self:GetPeriodId(store.lifetime, store.resetPolicy))
    local storedPeriod = meta and NonEmptyText(meta.periodId) or nil
    local payloadPeriod = nil
    if type(store.periodIdFromValue) == "function" then
        local ok, candidate = pcall(store.periodIdFromValue, value)
        if ok then payloadPeriod = NonEmptyText(candidate) end
    end
    store.periodId = storedPeriod or payloadPeriod or currentPeriod

    if store.autoReset == true and (store.lifetime == LIFETIME.Daily or store.lifetime == LIFETIME.Weekly)
        and currentPeriod ~= nil and storedPeriod ~= nil and currentPeriod ~= storedPeriod then
        local fresh, defaultErr = DefaultValue(store)
        if fresh == nil and defaultErr ~= nil then
            store.writeFenced = true
            store.writeFenceReason = "reset_default_failed"
            store.lastError = defaultErr
            return false, nil, defaultErr
        end
        value = fresh
        store.periodId = currentPeriod
        deferredSaveReason = "period_reset_load"
        deferredSaveDelayMs = 0
        self.stats.periodResets = (tonumber(self.stats.periodResets) or 0) + 1
        Emit("info", "STORE_PERIOD_RESET", "独立存档跨周期重置", { store = store.id, oldPeriod = storedPeriod, newPeriod = currentPeriod })
    end

    if deferredSaveReason == nil and meta ~= nil
        and (tonumber(meta.framework) or 0) < (tonumber(self.FrameworkVersion) or 3) then
        -- 中文维护注释：旧 Framework2 只有在完整性、schema migration、周期 reset 全部
        -- 成功后才排队升级物理 transport；若前面已有更强的 resave 原因则不覆盖，因为
        -- 任一当前 SaveValue 都会自动写 Framework3。这样不会改变历史迁移的事务优先级。
        deferredSaveReason = "framework_transport_upgrade"
        deferredSaveDelayMs = 0
    end

    -- Migration and period-reset transforms are also business code and may grow
    -- the payload. Re-check the final value immediately before Domain apply.
    local finalDecodedInspection = self:InspectPayload(value, store.budget)
    store.lastDecodedInspection = finalDecodedInspection
    if type(finalDecodedInspection) ~= "table" or finalDecodedInspection.ok ~= true then
        return RejectDecodedLoad("final", finalDecodedInspection)
    end

    if options.apply ~= false then
        local applied, applyErr = ApplyValue(store, value, "load")
        if not applied then
            store.writeFenced = true
            store.writeFenceReason = "apply_failed"
            store.lastError = applyErr
            Emit("error", "STORE_APPLY_FAILED", "独立存档应用失败，已启用写保护", { store = store.id, error = applyErr })
            return false, nil, applyErr
        end
        if deferredSaveReason ~= nil then
            local dirtyNow = NowMs()
            store.dirty = true
            store.firstDirtyAt = dirtyNow
            store.lastDirtyAt = dirtyNow
            store.lastDirtyReason = deferredSaveReason
            store.dirtyRevision = math.max(0, math.floor(tonumber(store.dirtyRevision) or 0)) + 1
            store.dueAt = dirtyNow + math.max(0, tonumber(deferredSaveDelayMs) or 0)
            self.stats.deferredLoadResaves = (tonumber(self.stats.deferredLoadResaves) or 0) + 1
            if deferredSaveReason == "integrity_v2_upgrade" then
                self.stats.integrityCompatibilityResaves = (tonumber(self.stats.integrityCompatibilityResaves) or 0) + 1
            elseif deferredSaveReason == "integrity_serializer_repair" then
                self.stats.integritySerializerRepairResaves = (tonumber(self.stats.integritySerializerRepairResaves) or 0) + 1
            elseif deferredSaveReason == "integrity_v4_upgrade" then
                self.stats.integrityUpgradeResaves = (tonumber(self.stats.integrityUpgradeResaves) or 0) + 1
            end
        end
    end
    store.loaded = true
    store.loadStatus = "loaded"
    store.writeFenced = false
    store.writeFenceReason = nil
    store.lastError = nil
    store.needsBarrierVerify = false
    -- Reaching this point means disk data decoded/applied successfully under the
    -- current budget/schema/integrity contract. Any earlier in-session read
    -- fence is therefore stale and is cleared above. Save-side budget fences are
    -- not silently cleared because they do not pass through a successful load.
    self.stats.loaded = (tonumber(self.stats.loaded) or 0) + 1
    Count("STORE_LOADED", 1)
    return true, DeepCopy(value), nil
end

function P:SaveValue(id, value, options)
    options = type(options) == "table" and options or {}
    local store = self:GetStore(id)
    if store == nil then return false, "unknown store" end
    if store.lifetime == LIFETIME.Session then
        store.memory = DeepCopy(value)
        store.dirty = false
        return true
    end
    local replacingFencedShard = false
    local originalFenceReason = store.writeFenceReason
    if store.writeFenced == true then
        local verifyRequired = options.verifyAfterSave == true or options.durable == true or store.verifyAfterSave == true
        replacingFencedShard = options.replaceCorrupt == true
            and store.recoverableReplacement == true
            and verifyRequired == true
            and IsRecoverableReplacementFence(store.writeFenceReason)
        if replacingFencedShard ~= true then
            Count("STORE_WRITE_FENCED", 1)
            return false, store.writeFenceReason or "write fenced"
        end
    end
    if type(store.save) ~= "function" and (S.Api == nil or type(S.Api.SaveData) ~= "function") then
        return false, "SaveData unavailable"
    end
    local resolvedKey, scopeErr, scopeFingerprint
    if options.useBoundScope == true and store.scope == SCOPE.Character and store.resolvedKey ~= nil then
        -- Dirty state belongs to the scope under which it was loaded/mutated. A
        -- debounce/Flush that runs after a character switch must finish writing
        -- the old bound key, never project that stale Domain into the new player.
        resolvedKey = store.resolvedKey
        scopeFingerprint = store.resolvedScopeFingerprint
    else
        resolvedKey, scopeErr, scopeFingerprint = self:ResolveStoreKey(store)
        if resolvedKey == nil then
            store.lastError = scopeErr
            return false, scopeErr
        end
        if store.scope == SCOPE.Character and store.resolvedKey ~= nil then
            local keyChanged = tostring(store.resolvedKey) ~= tostring(resolvedKey)
            local identityChanged = store.resolvedScopeFingerprint ~= nil and scopeFingerprint ~= nil
                and tostring(store.resolvedScopeFingerprint) ~= tostring(scopeFingerprint)
            if keyChanged or identityChanged then
                local verifyRequired = options.verifyAfterSave == true or options.durable == true or store.verifyAfterSave == true
                local safeReplacementRebind = keyChanged == true and store.dirty ~= true and store.needsBarrierVerify ~= true
                    and options.allowUnloadedWrite == true and store.recoverableReplacement == true and verifyRequired == true
                if safeReplacementRebind then
                    -- Gear-style inactive journal shards are full replacement
                    -- writes. A clean shard object may survive a character switch
                    -- in the same Lua generation; rebind only when the PHYSICAL
                    -- key changes. Identity-only collisions on the same lossy key
                    -- remain fail-closed and can never be overwritten.
                    self.stats.scopeRebinds = (tonumber(self.stats.scopeRebinds) or 0) + 1
                else
                    local bindingErr = keyChanged and "scope_binding_key_changed" or "scope_binding_identity_changed"
                    self.stats.scopeBindingMismatches = (tonumber(self.stats.scopeBindingMismatches) or 0) + 1
                    store.lastScopeBindingError = bindingErr
                    return false, bindingErr
                end
            end
        end
        store.resolvedKey = resolvedKey
        store.resolvedScopeFingerprint = scopeFingerprint
        store.lastScopeBindingError = nil
    end

    local periodId = nil
    if type(store.periodIdFromValue) == "function" then
        local ok, candidate = pcall(store.periodIdFromValue, value)
        if ok then periodId = NonEmptyText(candidate) end
    end
    local periodErr = nil
    if periodId == nil then periodId, periodErr = self:GetPeriodId(store.lifetime, store.resetPolicy) end
    if (store.lifetime == LIFETIME.Daily or store.lifetime == LIFETIME.Weekly) and periodId == nil then
        -- Never fabricate a reset period while server time is cold.  The store
        -- may still be saved if its Domain data already carries a trustworthy
        -- period through periodIdFromValue; otherwise fence this attempt only.
        return false, "period unavailable: " .. tostring(periodErr or "unknown")
    end

    local payloadInspection = self:InspectPayload(value, store.budget)
    store.lastPayloadInspection = payloadInspection
    if payloadInspection.ok ~= true then
        store.lastError = "payload_rejected:" .. tostring(payloadInspection.reason or "unknown")
        store.writeFenced = true
        store.writeFenceReason = store.lastError
        self.stats.payloadRejected = (tonumber(self.stats.payloadRejected) or 0) + 1
        self.stats.saveFailures = (tonumber(self.stats.saveFailures) or 0) + 1
        Count("STORE_PAYLOAD_REJECTED", 1)
        Emit("error", "STORE_PAYLOAD_REJECTED", "独立存档超过 SaveData 安全预算，已阻止写入以保护旧存档", {
            store = store.id, reason = payloadInspection.reason, nodes = payloadInspection.nodes,
            depth = payloadInspection.maxDepth, stringBytes = payloadInspection.stringBytes,
            maxTableEntries = payloadInspection.maxTableEntries,
        })
        -- A rejection silently write-fences the store for the whole session —
        -- the user must KNOW their edits are no longer being persisted
        -- (2026-09-01: a 713-id tracked list starved the buff display store
        -- for its entire lifetime without any visible signal).
        if S.WarnOnce ~= nil then
            S.WarnOnce("store_payload_rejected_" .. store.id,
                "[" .. store.id .. "] 存档超出安全预算，本次会话的所有修改都无法保存！请在诊断页查看 STORE_PAYLOAD_REJECTED 详情。")
        end
        return false, store.lastError
    end

    -- Reliability v8 stamps Integrity v4 over the CANONICAL store value (the
    -- store's own deterministic encode/normalize of the Domain), not over the
    -- raw envelope. The fingerprint deliberately excludes __rsmeta, so its own
    -- integrity fields do not create a recursive hash; non-integral numbers use
    -- the serializer-stable token while exact Domain/business fingerprints
    -- remain unchanged. For typed-codec stores the canonical value equals the
    -- encoded business payload; for plain stores it is the store's fixed-shape
    -- normalize of the Domain.
    local canonicalValue, canonicalErr = self:CanonicalIntegrityValue(store, value)
    if canonicalValue == nil then
        store.lastError = tostring(canonicalErr or "canonical_value_missing")
        self.stats.saveFailures = (tonumber(self.stats.saveFailures) or 0) + 1
        Emit("error", "STORE_CANONICAL_FAILED", "独立存档 canonical 值计算失败，已阻止写入", {
            store = store.id, error = store.lastError,
        })
        return false, store.lastError
    end
    local encodedFingerprint, fingerprintErr = self:FingerprintCanonicalValue(store, canonicalValue)
    if encodedFingerprint == nil then
        store.lastError = "encoded_fingerprint_failed:" .. tostring(fingerprintErr or "unknown")
        self.stats.saveFailures = (tonumber(self.stats.saveFailures) or 0) + 1
        Emit("error", "STORE_FINGERPRINT_FAILED", "独立存档编码完整性指纹计算失败，已阻止写入", {
            store = store.id, error = tostring(fingerprintErr or "unknown"),
        })
        return false, store.lastError
    end

    local raw, encodeErr = EncodeValue(store, DeepCopy(value), periodId, scopeFingerprint)
    if raw == nil then
        store.lastError = encodeErr
        self.stats.saveFailures = (tonumber(self.stats.saveFailures) or 0) + 1
        Emit("error", "STORE_ENCODE_FAILED", "独立存档编码失败", { store = store.id, error = encodeErr })
        return false, encodeErr
    end
    raw.__rsmeta.reliabilityContract = self.ReliabilityContractVersion
    raw.__rsmeta.integrityVersion = self.IntegrityContractVersion
    raw.__rsmeta.encodedFingerprint = encodedFingerprint
    raw.__rsmeta.envelopeIntegrityVersion = self.EnvelopeIntegrityContractVersion
    local envelopeFingerprint, envelopeErr = self:FingerprintEnvelopeIntegrity(raw)
    if envelopeFingerprint == nil then
        store.lastError = "envelope_fingerprint_failed:" .. tostring(envelopeErr or "unknown")
        self.stats.saveFailures = (tonumber(self.stats.saveFailures) or 0) + 1
        Emit("error", "STORE_ENVELOPE_FINGERPRINT_FAILED", "独立存档元数据封印计算失败，已阻止写入", {
            store = store.id, error = tostring(envelopeErr or "unknown"),
        })
        return false, store.lastError
    end
    raw.__rsmeta.envelopeFingerprint = envelopeFingerprint

    -- Inspect the FINAL serialized table too. A custom encode() is allowed to
    -- reshape data, so validating only the Domain snapshot would leave a path
    -- for an encoder to exceed the RU SaveData serializer's safe envelope.
    local encodedInspection = self:InspectPayload(raw, store.encodedBudget)
    store.lastEncodedInspection = encodedInspection
    if encodedInspection.ok ~= true then
        store.lastError = "encoded_payload_rejected:" .. tostring(encodedInspection.reason or "unknown")
        store.writeFenced = true
        store.writeFenceReason = store.lastError
        self.stats.encodedPayloadRejected = (tonumber(self.stats.encodedPayloadRejected) or 0) + 1
        self.stats.saveFailures = (tonumber(self.stats.saveFailures) or 0) + 1
        Count("STORE_ENCODED_PAYLOAD_REJECTED", 1)
        Emit("error", "STORE_ENCODED_PAYLOAD_REJECTED", "编码后的独立存档超过 SaveData 安全预算，已阻止写入", {
            store = store.id, reason = encodedInspection.reason, nodes = encodedInspection.nodes,
            depth = encodedInspection.maxDepth, stringBytes = encodedInspection.stringBytes,
            maxTableEntries = encodedInspection.maxTableEntries,
        })
        if S.WarnOnce ~= nil then
            S.WarnOnce("store_encoded_payload_rejected_" .. store.id,
                "[" .. store.id .. "] 存档编码后超出安全预算，本次会话的所有修改都无法保存！请在诊断页查看 STORE_ENCODED_PAYLOAD_REJECTED 详情。")
        end
        return false, store.lastError
    end

    -- 中文维护注释：完整性指纹已经对逻辑 raw/Domain 完成；直到真正跨 SaveData 边界时才做物理 transport。
    -- 这样 boolean false/空表在 RU 中不会消失，同时所有 Store codec、canonical、迁移和 Feature Apply 都保持原语义。
    local physicalRaw, transportErr = self:EncodePhysicalEnvelope(raw)
    if physicalRaw == nil then
        store.lastError = "transport_encode_failed:" .. tostring(transportErr or "unknown")
        self.stats.saveFailures = (tonumber(self.stats.saveFailures) or 0) + 1
        Emit("error", "STORE_TRANSPORT_ENCODE_FAILED", "独立存档物理传输编码失败，已阻止 SaveData", { store = store.id, error = tostring(transportErr or "unknown") })
        return false, store.lastError
    end
    local physicalInspection = self:InspectPayload(physicalRaw, store.encodedBudget)
    store.lastPhysicalInspection = physicalInspection
    if type(physicalInspection) ~= "table" or physicalInspection.ok ~= true then
        store.lastError = "physical_payload_rejected:" .. tostring(physicalInspection and physicalInspection.reason or "unknown")
        self.stats.encodedPayloadRejected = (tonumber(self.stats.encodedPayloadRejected) or 0) + 1
        self.stats.saveFailures = (tonumber(self.stats.saveFailures) or 0) + 1
        Emit("error", "STORE_PHYSICAL_PAYLOAD_REJECTED", "物理传输编码后的存档超过 SaveData 安全预算，已阻止写入", {
            store = store.id, reason = physicalInspection and physicalInspection.reason or "unknown",
        })
        return false, store.lastError
    end

    local ok, saveErr
    if type(store.save) == "function" then
        -- 中文维护注释：custom save 也属于物理写入边界，因此必须收到 transport 后 envelope；第三参数仍保留原 Domain 快照供事务型分片实现使用。
        local callOk, result, customErr = pcall(store.save, resolvedKey, physicalRaw, DeepCopy(value), options)
        if callOk then
            ok = result == true
            saveErr = customErr
        else
            ok = false
            saveErr = result
        end
    else
        ok, saveErr = S.Api:SaveData(resolvedKey, physicalRaw)
    end
    if ok ~= true then
        -- A failed SaveData return does not prove the physical key was untouched.
        -- Journal shards are pointer-committed separately and may safely leave a
        -- failed inactive bank orphaned; other stores must be checked/restored at
        -- the next durability barrier before Reload/Stop may proceed.
        if store.recoverableReplacement ~= true then store.needsBarrierVerify = true end
        store.lastError = tostring(saveErr or "save failed")
        self.stats.saveFailures = (tonumber(self.stats.saveFailures) or 0) + 1
        Count("STORE_SAVE_FAILED", 1)
        Emit("warning", "STORE_SAVE_FAILED", "独立存档保存失败", { store = store.id, error = saveErr })
        if S.WarnOnce ~= nil then
            S.WarnOnce("store_save_failed_" .. store.id,
                "[" .. store.id .. "] 存档保存失败，本次修改可能无法保留：" .. tostring(saveErr or "unknown"))
        end
        store.consecutiveSaveFailures = (tonumber(store.consecutiveSaveFailures) or 0) + 1
        -- Dirty writes are retried at a bounded cadence regardless of whether
        -- the caller used an explicit Commit path. Without this, a failed
        -- consumeDirty commit could be retried every Storage tick or simply be
        -- forgotten by a caller that proceeds to reload. Direct transactional
        -- writes that were never dirty remain caller-owned and are not queued.
        if store.dirty == true then
            store.dueAt = NowMs() + math.min(30000, math.max(2000, tonumber(options.retryMs) or 5000))
            self.stats.retryQueued = (tonumber(self.stats.retryQueued) or 0) + 1
        end
        return false, store.lastError
    end

    local verifyRequired = options.verifyAfterSave == true or options.durable == true or store.verifyAfterSave == true
    if verifyRequired then
        if options.durable == true then
            self.stats.durableVerifyAttempts = (tonumber(self.stats.durableVerifyAttempts) or 0) + 1
        end
        local verified, verifyErr = self:VerifyPersistedValue(store, value, resolvedKey)
        if verified ~= true then
            if options.durable == true then
                self.stats.durableVerifyFailures = (tonumber(self.stats.durableVerifyFailures) or 0) + 1
            end
            -- SaveData may already have touched the physical key even though the
            -- immediate readback did not prove the write. Keep a durability
            -- barrier obligation so a later Reload/Stop cannot silently proceed
            -- over an uncertain key after the caller rolls its Domain state back.
            store.needsBarrierVerify = true
            store.lastError = "readback_verify_failed:" .. tostring(verifyErr or "unknown")
            store.consecutiveSaveFailures = (tonumber(store.consecutiveSaveFailures) or 0) + 1
            self.stats.saveFailures = (tonumber(self.stats.saveFailures) or 0) + 1
            Count("STORE_SAVE_VERIFY_FAILED", 1)
            if store.dirty == true then
                store.dueAt = NowMs() + math.min(30000, math.max(2000, tonumber(options.retryMs) or 5000))
                self.stats.retryQueued = (tonumber(self.stats.retryQueued) or 0) + 1
            end
            if S.WarnOnce ~= nil then
                S.WarnOnce("store_readback_verify_failed_" .. store.id,
                    "[" .. store.id .. "] SaveData 返回成功，但立即回读内容不一致；本次写入未被提交为可靠存档。")
            end
            return false, store.lastError
        end
        store.needsBarrierVerify = false
    else
        -- Ordinary low-frequency settings keep the normal one-write fast path.
        -- Their physical key is verified once at the explicit durability
        -- barrier (Reload/Stop), never in Feature Tick or slider loops.
        store.needsBarrierVerify = true
    end

    self.stats.integrityStampedSaves = (tonumber(self.stats.integrityStampedSaves) or 0) + 1
    self.stats.envelopeIntegrityStampedSaves = (tonumber(self.stats.envelopeIntegrityStampedSaves) or 0) + 1

    store.periodId = periodId
    store.loaded = true
    if store.loadStatus == nil or store.loadStatus == "not_loaded" or store.loadStatus == "scope_pending" then
        store.loadStatus = "saved"
    end
    store.lastSaveAt = NowMs()
    store.lastError = nil
    store.lastIntegrityStatus = "stamped"
    store.lastIntegrityFingerprint = encodedFingerprint
    store.lastIntegrityError = nil
    if replacingFencedShard == true then
        store.writeFenced = false
        store.writeFenceReason = nil
        store.loadStatus = "saved"
        self.stats.verifiedReplacementRecoveries = (tonumber(self.stats.verifiedReplacementRecoveries) or 0) + 1
        Emit("warning", "STORE_VERIFIED_REPLACEMENT_RECOVERED", "已用完整回读验证的新分片替换损坏的非活动存档副本", {
            store = store.id, previousFence = tostring(originalFenceReason or "unknown"),
        })
    end
    store.lastSavedRevision = math.max(tonumber(store.lastSavedRevision) or 0, tonumber(store.dirtyRevision) or 0)
    store.consecutiveSaveFailures = 0
    store.dirty = false
    store.dueAt = 0
    store.firstDirtyAt = 0
    store.lastDirtyAt = 0
    store.lastDirtyReason = nil
    self.stats.saves = (tonumber(self.stats.saves) or 0) + 1
    Count("STORE_SAVED", 1)
    return true
end

local READY_LOAD_STATUS = {
    loaded = true,
    empty = true,
    saved = true,
    session = true,
}

local function IsStoreReady(store)
    return store ~= nil and store.loaded == true and READY_LOAD_STATUS[tostring(store.loadStatus or "")] == true
end

function P:IsStoreLoaded(id)
    local store = self:GetStore(id)
    if store == nil then return false, "unknown store" end
    -- `store.loaded` is the terminal-attempt bit retained for diagnostics. Public
    -- readiness is narrower: corrupt/future/apply-failed stores are terminal but
    -- must never be treated as safe Domain state by Feature/UI callers.
    if IsStoreReady(store) ~= true then return false, store.loadStatus end
    if store.scope == SCOPE.Character then
        local bindingOk, bindingErr = CurrentScopeBinding(store)
        if bindingOk ~= true then return false, bindingErr or "scope_changed" end
    end
    return true, store.loadStatus
end

-- Read-before-render helper for shared UI bindings and other generic consumers.
-- A settings surface can be constructed before the owning Feature is enabled;
-- it must never render Lua defaults as if they were persisted truth. Unlike
-- PrepareWrite this path does not require write permission and never marks the
-- Store dirty. It only establishes the current scope's authoritative Domain
-- state or fails closed with the existing terminal load reason.
function P:PrepareRead(id)
    self.stats.readPrepareAttempts = (tonumber(self.stats.readPrepareAttempts) or 0) + 1
    local store = self:GetStore(id)
    if store == nil then
        self.stats.readPrepareFailures = (tonumber(self.stats.readPrepareFailures) or 0) + 1
        return false, "unknown store"
    end
    local ready, readyReason = self:IsStoreLoaded(id)
    if ready == true then return true end

    -- Terminal failed attempts (corrupt/future/apply-failed/etc.) are already
    -- diagnostic truth. Do not hammer LoadData once per field on the same page.
    -- A ready-status Store can still be false here when character scope changed;
    -- that case is intentionally allowed to rebind through LoadStore below.
    if store.loaded == true and READY_LOAD_STATUS[tostring(store.loadStatus or "")] ~= true then
        self.stats.readPrepareFailures = (tonumber(self.stats.readPrepareFailures) or 0) + 1
        return false, store.lastError or readyReason or store.loadStatus or "store_not_ready"
    end

    local status, _, loadErr = self:LoadStore(id)
    if status ~= true and status ~= "empty" then
        self.stats.readPrepareFailures = (tonumber(self.stats.readPrepareFailures) or 0) + 1
        return false, loadErr or tostring(status or readyReason or "load failed")
    end
    self.stats.readPrepareLoads = (tonumber(self.stats.readPrepareLoads) or 0) + 1
    local loaded, loadedReason = self:IsStoreLoaded(id)
    if loaded ~= true then
        self.stats.readPrepareFailures = (tonumber(self.stats.readPrepareFailures) or 0) + 1
        return false, loadedReason or "store_not_ready_after_load"
    end
    return true
end

function P:CanWrite(id)
    local store = self:GetStore(id)
    if store == nil then return false, "unknown store" end
    if store.lifetime == LIFETIME.Session then return true end
    if IsStoreReady(store) ~= true then return false, "store_not_ready:" .. tostring(store.loadStatus or "not_loaded") end
    if store.scope == SCOPE.Character then
        local bindingOk, bindingErr = CurrentScopeBinding(store)
        if bindingOk ~= true then
            store.lastScopeBindingError = bindingErr
            self.stats.scopeBindingMismatches = (tonumber(self.stats.scopeBindingMismatches) or 0) + 1
            return false, bindingErr or "scope_changed"
        end
    end
    if store.writeFenced == true then return false, store.writeFenceReason or store.lastError or "store write-fenced" end
    return true
end

-- Pre-mutation helper for shared UI bindings and other generic callers. It is
-- intentionally called BEFORE Domain mutation; MarkDirty itself will never
-- auto-load because doing so after a mutation could re-apply disk state over the
-- very value the caller is trying to persist.
function P:PrepareWrite(id)
    local store = self:GetStore(id)
    if store == nil then return false, "unknown store" end
    if store.lifetime == LIFETIME.Session then return true end

    if IsStoreReady(store) == true and store.scope == SCOPE.Character then
        local bindingOk, bindingErr = CurrentScopeBinding(store)
        if bindingOk ~= true then
            -- The loaded Domain belongs to the old character. Never overwrite it
            -- with the new character key. First finish any outstanding old-scope
            -- durability obligation; otherwise a clean store may safely rebind
            -- by loading the current character before mutation.
            if store.dirty == true or store.needsBarrierVerify == true then
                store.lastScopeBindingError = "scope_change_pending_persistence:" .. tostring(bindingErr or "changed")
                self.stats.scopeBindingMismatches = (tonumber(self.stats.scopeBindingMismatches) or 0) + 1
                return false, store.lastScopeBindingError
            end
            local status, _, loadErr = self:LoadStore(id)
            if status ~= true and status ~= "empty" then
                return false, loadErr or tostring(status or "scope rebind load failed")
            end
        end
    elseif IsStoreReady(store) ~= true then
        local status, _, loadErr = self:LoadStore(id)
        if status ~= true and status ~= "empty" then return false, loadErr or tostring(status or "load failed") end
    end
    return self:CanWrite(id)
end

function P:SaveStore(id, options)
    options = type(options) == "table" and options or {}
    local store = self:GetStore(id)
    if store == nil then return false, "unknown store" end
    if store.lifetime == LIFETIME.Session then return self:SaveValue(id, store.memory, options) end
    -- Direct SaveStore used to bypass the load-before-write fence entirely.
    -- That allowed a Feature command to serialize default Domain memory over a
    -- perfectly valid older Store when the Feature had not been enabled/loaded
    -- yet. Full-replacement transactional shard writers may opt in explicitly;
    -- ordinary settings/index stores must always be loaded first.
    local replacementWrite = options.replaceCorrupt == true and store.recoverableReplacement == true
    if IsStoreReady(store) ~= true and options.allowUnloadedWrite ~= true and replacementWrite ~= true then
        self.stats.unloadedWriteRejects = (tonumber(self.stats.unloadedWriteRejects) or 0) + 1
        Count("STORE_WRITE_BEFORE_LOAD_REJECTED", 1)
        Emit("error", "STORE_WRITE_BEFORE_LOAD_REJECTED", "配置尚未完成读取，已拒绝直接保存以避免默认值覆盖旧存档", {
            store = store.id, owner = store.owner, loadStatus = store.loadStatus, reason = tostring(options.reason or "direct_save"),
        })
        return false, "store_not_loaded:" .. tostring(store.loadStatus or "not_loaded")
    end
    local ok, value = pcall(store.get)
    if not ok then
        store.lastError = tostring(value)
        Emit("error", "STORE_GET_FAILED", "读取 Domain 持久化快照失败", { store = store.id, error = value })
        return false, tostring(value)
    end
    return self:SaveValue(id, value, options)
end

-- NOTE: the old ReadLegacy bridge (arbitrary SaveData key reads for old-plugin
-- migration) was removed on 2026-09-01 by directive: the old plugin generation
-- is reference-only and its data is never migrated into V3 stores.

-- Reliability v2+ mutation transaction. Public business mutations should prefer
-- this over "mutate Domain -> MarkDirty". The disk value is loaded before the
-- mutation, the registered Domain getter is snapshotted, and any mutation/commit
-- failure restores both Domain state and Persistence dirty metadata.
function P:MutateStore(id, mutate, options)
    options = type(options) == "table" and options or {}
    if type(mutate) ~= "function" then return false, "mutation callback required" end
    local store = self:GetStore(id)
    if store == nil then return false, "unknown store" end
    self.stats.mutationAttempts = (tonumber(self.stats.mutationAttempts) or 0) + 1

    local prepared, prepareErr = self:PrepareWrite(id)
    if prepared ~= true then
        self.stats.mutationPrepareRejects = (tonumber(self.stats.mutationPrepareRejects) or 0) + 1
        return false, prepareErr or "store prepare failed"
    end

    local beforeValue
    if store.lifetime == LIFETIME.Session then
        beforeValue = DeepCopy(store.memory)
    else
        local got, snapshot = pcall(store.get)
        if got ~= true then return false, "pre-mutation snapshot failed: " .. tostring(snapshot) end
        beforeValue = DeepCopy(snapshot)
    end
    local beforeMeta = {
        dirty = store.dirty == true, dueAt = tonumber(store.dueAt) or 0,
        firstDirtyAt = tonumber(store.firstDirtyAt) or 0, lastDirtyAt = tonumber(store.lastDirtyAt) or 0,
        lastDirtyReason = store.lastDirtyReason, dirtyRevision = tonumber(store.dirtyRevision) or 0,
        lastSavedRevision = tonumber(store.lastSavedRevision) or 0,
        consecutiveSaveFailures = tonumber(store.consecutiveSaveFailures) or 0,
    }

    local function Rollback(reason)
        local rollbackOk, rollbackErr
        if store.lifetime == LIFETIME.Session then
            store.memory = DeepCopy(beforeValue)
            rollbackOk = true
        else
            rollbackOk, rollbackErr = ApplyValue(store, beforeValue, "mutation_rollback:" .. tostring(reason or "failed"))
        end
        if rollbackOk == true then
            store.dirty = beforeMeta.dirty
            store.dueAt = beforeMeta.dueAt
            store.firstDirtyAt = beforeMeta.firstDirtyAt
            store.lastDirtyAt = beforeMeta.lastDirtyAt
            store.lastDirtyReason = beforeMeta.lastDirtyReason
            store.dirtyRevision = beforeMeta.dirtyRevision
            store.lastSavedRevision = beforeMeta.lastSavedRevision
            store.consecutiveSaveFailures = beforeMeta.consecutiveSaveFailures
            self.stats.mutationRollbacks = (tonumber(self.stats.mutationRollbacks) or 0) + 1
            return true
        end
        store.writeFenced = true
        store.writeFenceReason = "mutation_rollback_failed"
        store.lastError = tostring(rollbackErr or "mutation rollback failed")
        self.stats.mutationRollbackFailures = (tonumber(self.stats.mutationRollbackFailures) or 0) + 1
        Emit("error", "STORE_MUTATION_ROLLBACK_FAILED", "持久化事务回滚失败，已对 Store 启用写保护", {
            store = store.id, reason = tostring(reason or "failed"), error = store.lastError,
        })
        return false, store.lastError
    end

    local callOk, result, mutationErr, extra = pcall(mutate, store)
    if callOk ~= true or result == false then
        self.stats.mutationFailures = (tonumber(self.stats.mutationFailures) or 0) + 1
        local reason = callOk == true and tostring(mutationErr or "mutation rejected") or tostring(result)
        Rollback(reason)
        return false, reason
    end

    local committed, commitErr
    if options.durable == true then
        committed, commitErr = self:SaveStore(id, {
            consumeDirty = true,
            durable = true,
            verifyAfterSave = true,
            reason = tostring(options.reason or "mutation_durable"),
            retryMs = options.retryMs,
        })
    else
        committed, commitErr = self:MarkDirty(id, tonumber(options.delayMs) or self.defaultDelayMs, tostring(options.reason or "mutation"))
    end
    if committed ~= true then
        self.stats.mutationCommitFailures = (tonumber(self.stats.mutationCommitFailures) or 0) + 1
        Rollback(commitErr or "mutation commit failed")
        return false, commitErr or "mutation commit failed"
    end
    return true, mutationErr, extra
end

function P:ClearStore(id, options)
    options = type(options) == "table" and options or {}
    local store = self:GetStore(id)
    if store == nil then return false, "unknown store" end
    if store.lifetime == LIFETIME.Session then
        local fresh, defaultErr = DefaultValue(store)
        if defaultErr ~= nil then return false, defaultErr end
        store.memory = DeepCopy(fresh)
        store.loaded, store.loadStatus, store.dirty, store.dueAt = true, "session", false, 0
        return true
    end
    local key, keyErr
    if store.scope == SCOPE.Character then
        local prepared, prepareErr = self:PrepareWrite(id)
        if prepared ~= true then return false, prepareErr or "character store not ready for clear" end
        key = store.resolvedKey
        if key == nil then return false, "character store key unavailable" end
    else
        key, keyErr = self:ResolveStoreKey(store)
        if key == nil then return false, keyErr end
    end
    if S.Api == nil or type(S.Api.ClearData) ~= "function" then return false, "ClearData unavailable" end
    local cleared, clearErr = S.Api:ClearData(key)
    if cleared ~= true then
        self.stats.clearFailures = (tonumber(self.stats.clearFailures) or 0) + 1
        Emit("warning", "STORE_CLEAR_FAILED", "独立存档物理清理失败", { store = store.id, error = tostring(clearErr or "unknown") })
        return false, clearErr or "clear failed"
    end

    -- ClearData success is not a durability proof. Verify the exact key is gone
    -- BEFORE applying defaults to Domain memory; otherwise a fake-success clear
    -- makes settings look reset until the next Reload resurrects the old data.
    if S.Api == nil or type(S.Api.LoadData) ~= "function" then
        self.stats.clearFailures = (tonumber(self.stats.clearFailures) or 0) + 1
        self.stats.clearVerifyFailures = (tonumber(self.stats.clearVerifyFailures) or 0) + 1
        store.writeFenced, store.writeFenceReason = true, "clear_verify_unavailable"
        store.lastError = store.writeFenceReason
        return false, store.lastError
    end
    self.stats.clearVerifyAttempts = (tonumber(self.stats.clearVerifyAttempts) or 0) + 1
    local verifyRaw, verifyErr = S.Api:LoadData(key)
    if verifyErr ~= nil or verifyRaw ~= nil then
        self.stats.clearFailures = (tonumber(self.stats.clearFailures) or 0) + 1
        self.stats.clearVerifyFailures = (tonumber(self.stats.clearVerifyFailures) or 0) + 1
        local reason = verifyErr ~= nil and ("clear_verify_load_failed:" .. tostring(verifyErr)) or "clear_verify_not_empty"
        store.loadStatus = "clear_verify_failed"
        store.writeFenced, store.writeFenceReason, store.lastError = true, reason, reason
        Emit("error", "STORE_CLEAR_VERIFY_FAILED", "ClearData 返回成功但物理存档仍未确认清空，已保留当前 Domain 并启用写保护", {
            store = store.id, owner = store.owner, error = reason,
        })
        return false, reason
    end
    local fresh, defaultErr = DefaultValue(store)
    if defaultErr ~= nil then
        store.writeFenced, store.writeFenceReason, store.lastError = true, "clear_default_failed", tostring(defaultErr)
        return false, defaultErr
    end
    if options.applyDefault ~= false then
        local applied, applyErr = ApplyValue(store, fresh, options.reason or "clear_store")
        if applied ~= true then
            store.writeFenced, store.writeFenceReason, store.lastError = true, "clear_apply_failed", tostring(applyErr)
            return false, applyErr
        end
    end
    store.loaded, store.loadStatus = true, "empty"
    store.dirty, store.dueAt, store.periodId = false, 0, nil
    store.firstDirtyAt, store.lastDirtyAt, store.lastDirtyReason = 0, 0, nil
    store.consecutiveSaveFailures = 0
    store.writeFenced, store.writeFenceReason, store.lastError = false, nil, nil
    store.needsBarrierVerify = false
    store.lastBarrierVerifyAt, store.lastBarrierVerifyOk, store.lastBarrierVerifyError = NowMs(), true, nil
    store.lastLoadAt = NowMs()
    self.stats.clears = (tonumber(self.stats.clears) or 0) + 1
    Count("STORE_CLEARED", 1)
    return true
end

function P:MarkDirty(id, delayMs, reason)
    local store = self:GetStore(id)
    if store == nil then return false, "unknown store" end
    if store.lifetime == LIFETIME.Session then return true end
    if IsStoreReady(store) ~= true then
        self.stats.unloadedWriteRejects = (tonumber(self.stats.unloadedWriteRejects) or 0) + 1
        Count("STORE_WRITE_BEFORE_LOAD_REJECTED", 1)
        Emit("error", "STORE_WRITE_BEFORE_LOAD_REJECTED", "配置尚未完成读取，已拒绝保存意图以避免默认值覆盖旧存档", {
            store = store.id, owner = store.owner, loadStatus = store.loadStatus, reason = tostring(reason or ""),
        })
        return false, "store_not_loaded:" .. tostring(store.loadStatus or "not_loaded")
    end
    if store.scope == SCOPE.Character then
        local bindingOk, bindingErr = CurrentScopeBinding(store)
        if bindingOk ~= true then
            store.lastScopeBindingError = bindingErr
            self.stats.scopeBindingMismatches = (tonumber(self.stats.scopeBindingMismatches) or 0) + 1
            Emit("error", "STORE_SCOPE_DIRTY_REJECTED", "角色级 Store 当前身份已变化，拒绝把旧角色 Domain 标记为待保存", {
                store = store.id, error = tostring(bindingErr or "scope_changed"),
            })
            return false, bindingErr or "scope_changed"
        end
    end
    if store.writeFenced == true then return false, store.writeFenceReason or store.lastError or "store write-fenced" end
    local now = NowMs()
    local delay = math.max(0, tonumber(delayMs) or self.defaultDelayMs)
    if store.dirty ~= true then
        store.firstDirtyAt = now
    end
    store.dirty = true
    store.lastDirtyAt = now
    store.lastDirtyReason = tostring(reason or "changed")
    store.dirtyRevision = math.max(0, math.floor(tonumber(store.dirtyRevision) or 0)) + 1
    if delay <= 0 then
        store.dueAt = now
    else
        -- True debounce: save after the latest edit, but bound continuous input
        -- so a long slider drag cannot postpone persistence forever.
        local requested = now + delay
        local absoluteCap = (tonumber(store.firstDirtyAt) or now) + math.max(delay, tonumber(self.maxDebounceMs) or 5000)
        store.dueAt = math.min(requested, absoluteCap)
    end
    Count("STORE_DIRTY", 1)
    return true
end

function P:SetSession(id, value)
    local store = self:GetStore(id)
    if store == nil or store.lifetime ~= LIFETIME.Session then return false, "not a Session store" end
    store.memory = DeepCopy(value)
    store.loaded = true
    store.loadStatus = "session"
    return true
end

function P:GetSession(id)
    local store = self:GetStore(id)
    if store == nil or store.lifetime ~= LIFETIME.Session then return nil end
    if store.memory == nil then store.memory = select(1, DefaultValue(store)) end
    return store.memory
end

function P:RevalidateStore(id)
    local store = self:GetStore(id)
    if store == nil then return false, "unknown store" end
    if store.lifetime ~= LIFETIME.Session and IsStoreReady(store) ~= true then
        local status, _, loadErr = self:LoadStore(id)
        if status ~= true and status ~= "empty" then return false, loadErr or tostring(status or "load failed") end
    end
    local fence = tostring(store.writeFenceReason or "")
    if fence:match("^payload_rejected:") == nil and fence:match("^encoded_payload_rejected:") == nil then
        return false, "store is not payload-fenced"
    end
    local ok, value = pcall(store.get)
    if not ok then return false, tostring(value) end
    local inspection = self:InspectPayload(value, store.budget)
    store.lastPayloadInspection = inspection
    if inspection.ok ~= true then return false, inspection.reason end
    local periodId = nil
    if type(store.periodIdFromValue) == "function" then
        local periodOk, candidate = pcall(store.periodIdFromValue, value)
        if periodOk then periodId = NonEmptyText(candidate) end
    end
    if periodId == nil then periodId = select(1, self:GetPeriodId(store.lifetime, store.resetPolicy)) end
    local raw, encodeErr = EncodeValue(store, DeepCopy(value), periodId, store.resolvedScopeFingerprint)
    if raw == nil then return false, encodeErr end
    local encodedInspection = self:InspectPayload(raw, store.encodedBudget)
    store.lastEncodedInspection = encodedInspection
    if encodedInspection.ok ~= true then return false, encodedInspection.reason end
    store.writeFenced = false
    store.writeFenceReason = nil
    store.lastError = nil
    store.dirty = true
    store.firstDirtyAt = NowMs()
    store.lastDirtyAt = store.firstDirtyAt
    store.lastDirtyReason = "revalidate"
    store.dirtyRevision = math.max(0, math.floor(tonumber(store.dirtyRevision) or 0)) + 1
    store.dueAt = store.firstDirtyAt
    return true
end

function P:Flush(owner)
    local allOk, failures = true, {}
    local saved, verified = 0, 0
    owner = NonEmptyText(owner)

    -- Phase 1: commit all currently dirty Domain snapshots.
    for _, id in ipairs(self.order) do
        local store = self.stores[id]
        if store ~= nil and store.dirty == true and (owner == nil or store.owner == owner) then
            local ok, err = self:SaveStore(id, { reason = "flush", retryMs = 5000, useBoundScope = true })
            if ok == true then
                saved = saved + 1
            else
                allOk = false
                failures[#failures + 1] = tostring(id) .. ":" .. tostring(err or store.lastError or "save failed")
            end
        end
    end

    -- Phase 2: durability barrier. Ordinary settings intentionally avoid an
    -- immediate LoadData after every SaveData; however Reload/Stop is a hard
    -- generation boundary. Any key written since the previous barrier must be
    -- read back and fingerprint-matched here before code reload may continue.
    -- This is bounded by the number of registered stores and never runs in a
    -- Feature Tick/slider loop.
    for _, id in ipairs(self.order) do
        local store = self.stores[id]
        if store ~= nil and store.lifetime ~= LIFETIME.Session and store.needsBarrierVerify == true
            and (owner == nil or store.owner == owner) then
            self.stats.barrierVerifyAttempts = (tonumber(self.stats.barrierVerifyAttempts) or 0) + 1
            store.lastBarrierVerifyAt = NowMs()

            local ready = IsStoreReady(store)
            local expected, getErr
            if ready == true then
                local got, value = pcall(store.get)
                if got == true then expected = value else getErr = tostring(value) end
            else
                getErr = "store_not_ready:" .. tostring(store.loadStatus or "not_loaded")
            end

            local ok, err
            if getErr == nil then
                ok, err = self:VerifyPersistedValue(store, expected, store.resolvedKey)
            else
                ok, err = false, getErr
            end

            if ok == true then
                verified = verified + 1
                store.needsBarrierVerify = false
                store.lastBarrierVerifyOk = true
                if store.lastError == store.lastBarrierVerifyError then store.lastError = nil end
                store.lastBarrierVerifyError = nil
                self.stats.barrierVerifySuccesses = (tonumber(self.stats.barrierVerifySuccesses) or 0) + 1
            else
                allOk = false
                local reason = "barrier_verify_failed:" .. tostring(err or "unknown")
                store.lastBarrierVerifyOk = false
                store.lastBarrierVerifyError = reason
                store.lastError = reason
                self.stats.barrierVerifyFailures = (tonumber(self.stats.barrierVerifyFailures) or 0) + 1
                failures[#failures + 1] = tostring(id) .. ":" .. reason

                -- A barrier mismatch can be an immediate-read visibility delay,
                -- so do not permanently write-fence the Store. Requeue the
                -- current verified Domain snapshot for a bounded retry. The next
                -- barrier must still pass before Reload is allowed.
                if store.writeFenced ~= true and IsStoreReady(store) == true then
                    local now = NowMs()
                    if store.dirty ~= true then
                        store.firstDirtyAt = now
                        store.dirtyRevision = math.max(0, math.floor(tonumber(store.dirtyRevision) or 0)) + 1
                    end
                    store.dirty = true
                    store.lastDirtyAt = now
                    store.lastDirtyReason = "durability_barrier_verify_failed"
                    store.dueAt = now + 5000
                    self.stats.retryQueued = (tonumber(self.stats.retryQueued) or 0) + 1
                    self.stats.barrierVerifyRequeued = (tonumber(self.stats.barrierVerifyRequeued) or 0) + 1
                end
            end
        end
    end

    self.lastFlush = {
        at = NowMs(),
        ok = allOk == true,
        owner = owner,
        saved = saved,
        verified = verified,
        failures = DeepCopy(failures),
    }

    if allOk ~= true then
        self.stats.flushFailures = (tonumber(self.stats.flushFailures) or 0) + 1
        Emit("error", "STORE_FLUSH_FAILED", "持久化 Flush/耐久屏障未能安全确认全部修改", {
            owner = owner, saved = saved, verified = verified, failures = failures,
        })
    end
    return allOk, failures
end

function P:Tick()
    local now = NowMs()
    for _, id in ipairs(self.order) do
        local store = self.stores[id]
        if store ~= nil and store.dirty == true and now >= (tonumber(store.dueAt) or 0) then
            if IsStoreReady(store) == true and store.writeFenced ~= true then
                self:SaveStore(id, { reason = "debounce", useBoundScope = true })
            else
                -- Terminal/fenced stores keep their dirty evidence for Flush and
                -- diagnostics, but must never hammer SaveStore from the runtime
                -- cadence. Recovery is explicit through Load/Revalidate/Clear.
                store.dueAt = now + math.max(5000, tonumber(self.maxDebounceMs) or 5000)
                self.stats.terminalAutoRetrySuppressions = (tonumber(self.stats.terminalAutoRetrySuppressions) or 0) + 1
            end
        end
    end

    if now < (tonumber(self.nextPeriodCheckAt) or 0) then return end
    self.nextPeriodCheckAt = now + math.max(5000, tonumber(self.periodCheckMs) or 15000)
    for _, id in ipairs(self.order) do
        local store = self.stores[id]
        if store ~= nil and IsStoreReady(store) == true and store.autoReset == true
            and (store.lifetime == LIFETIME.Daily or store.lifetime == LIFETIME.Weekly) then
            local current = select(1, self:GetPeriodId(store.lifetime, store.resetPolicy))
            if current ~= nil and store.periodId ~= nil and current ~= store.periodId then
                local fresh, err = DefaultValue(store)
                if fresh ~= nil then
                    local applied, applyErr = ApplyValue(store, fresh, "period_reset")
                    if applied then
                        local old = store.periodId
                        store.periodId = current
                        store.dirty = true
                        store.firstDirtyAt = now
                        store.lastDirtyAt = now
                        store.lastDirtyReason = "period_reset"
                        store.dirtyRevision = math.max(0, math.floor(tonumber(store.dirtyRevision) or 0)) + 1
                        store.dueAt = now
                        self.stats.periodResets = (tonumber(self.stats.periodResets) or 0) + 1
                        Emit("info", "STORE_PERIOD_RESET", "在线跨周期重置", { store = store.id, oldPeriod = old, newPeriod = current })
                    else
                        store.writeFenced = true
                        store.writeFenceReason = "period_apply_failed"
                        store.lastError = applyErr
                    end
                else
                    store.writeFenced = true
                    store.writeFenceReason = "period_default_failed"
                    store.lastError = err
                end
            end
        end
    end
end


-- Stable, bounded content fingerprint used only by the RU Fresh Reload
-- acceptance workflow. This deliberately hashes the Domain snapshot rather
-- than the encoded SaveData envelope so framework metadata/timestamps cannot
-- create false mismatches across processes. It never loads, saves or mutates a
-- Store and is therefore safe to call only from explicit diagnostics actions.
local HASH_MOD = 2147483647
local HASH_MULTIPLIER = 131

local function HashText(hash, text)
    hash = math.floor(tonumber(hash) or 1) % HASH_MOD
    text = tostring(text or "")
    for i = 1, #text do
        hash = (hash * HASH_MULTIPLIER + string.byte(text, i)) % HASH_MOD
    end
    return hash
end

local function NumberToken(value)
    value = tonumber(value) or 0
    if value == 0 then return "0" end
    return string.format("%.17g", value)
end

-- Persistence Integrity v2 deliberately uses a serializer-stable numeric token
-- for non-integral values. RU SaveData/LoadData may normalize floating-point
-- representation even when the business value is unchanged; hashing the full
-- 17-digit binary representation therefore created false cross-reload
-- corruption fences for UI geometry/opacity/color settings. Integral values
-- remain exact so item/skill ids, counters and timestamps do not lose entropy.
local function DurableNumberToken(value)
    value = tonumber(value) or 0
    if value == 0 then return "0" end
    if value == math.floor(value) and math.abs(value) <= 9007199254740991 then
        return string.format("%.0f", value)
    end
    -- Six significant decimal digits stay safely inside single-precision
    -- serializer round-trip accuracy while exceeding the precision required by
    -- Suite UI scale/opacity/color/geometry settings. This token is used only
    -- by the persistence integrity layer, never by business-domain fingerprints.
    return string.format("%.6g", value)
end

local function KeyToken(value, numberToken)
    local kind = type(value)
    if kind == "number" then return "n:" .. (numberToken or NumberToken)(value) end
    return "s:" .. tostring(value)
end

local function FingerprintValue(value, hash, seen, numberToken)
    local kind = type(value)
    if kind == "nil" then return HashText(hash, "N;") end
    if kind == "boolean" then return HashText(hash, value and "B1;" or "B0;") end
    if kind == "number" then return HashText(hash, "D" .. (numberToken or NumberToken)(value) .. ";") end
    if kind == "string" then
        hash = HashText(hash, "S" .. tostring(#value) .. ":")
        hash = HashText(hash, value)
        return HashText(hash, ";")
    end
    if kind ~= "table" then return nil, "unsupported_type:" .. kind end
    if seen[value] then return nil, "cyclic_table" end
    seen[value] = true

    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b)
        local at, bt = KeyToken(a, numberToken), KeyToken(b, numberToken)
        if at ~= bt then return at < bt end
        return tostring(type(a)) < tostring(type(b))
    end)

    hash = HashText(hash, "T" .. tostring(#keys) .. "{")
    for _, key in ipairs(keys) do
        hash = HashText(hash, "K")
        local nextHash, keyErr = FingerprintValue(key, hash, seen, numberToken)
        if nextHash == nil then seen[value] = nil; return nil, keyErr end
        hash = nextHash
        hash = HashText(hash, "V")
        local valueHash, valueErr = FingerprintValue(value[key], hash, seen, numberToken)
        if valueHash == nil then seen[value] = nil; return nil, valueErr end
        hash = valueHash
    end
    seen[value] = nil
    return HashText(hash, "};")
end

local function FingerprintPayloadWithNumberToken(self, value, budget, numberToken)
    local inspection = self:InspectPayload(value, budget)
    if inspection.ok ~= true then return nil, tostring(inspection.reason or "payload_rejected"), inspection end
    local hash, err = FingerprintValue(value, 146959810, {}, numberToken)
    if hash == nil then return nil, err, inspection end
    return string.format("%08X", math.floor(hash)), nil, inspection
end

-- Exact Domain fingerprint remains intentionally unchanged because Gear's A/B
-- journal stores this business fingerprint in its own index contract. Do not
-- silently change that contract when evolving persistence-integrity hashing.
function P:FingerprintPayload(value, budget)
    return FingerprintPayloadWithNumberToken(self, value, budget, NumberToken)
end

-- Readback/durability proof is allowed to canonicalize non-integral numbers: it
-- verifies business equivalence across the native SaveData serializer rather
-- than Lua's in-memory binary representation.
function P:FingerprintDurablePayload(value, budget)
    return FingerprintPayloadWithNumberToken(self, value, budget, DurableNumberToken)
end

-- Fingerprint only the encoded business fields. Framework metadata is excluded
-- so the integrity stamp can live in __rsmeta without hashing itself. A shallow
-- top-level projection is sufficient: FingerprintPayload recursively walks the
-- referenced nested tables without mutating them, and InspectPayload rejects
-- cycles/over-budget shapes before hashing.
local function EncodedBusinessProjection(raw)
    if type(raw) ~= "table" then return nil, "encoded payload must be table" end
    local business = {}
    for key, value in pairs(raw) do
        if key ~= "__rsmeta" then business[key] = value end
    end
    return business, nil
end

-- Integrity v2: serializer-stable numeric canonicalization.
function P:FingerprintEncodedPayload(raw, budget)
    local business, err = EncodedBusinessProjection(raw)
    if business == nil then return nil, err end
    return self:FingerprintDurablePayload(business, budget)
end

-- Integrity v1 compatibility only. New saves must never stamp this form.
function P:FingerprintEncodedPayloadV1(raw, budget)
    local business, err = EncodedBusinessProjection(raw)
    if business == nil then return nil, err end
    return self:FingerprintPayload(business, budget)
end

-- Integrity v3: the canonical store value is a pure function of the logical
-- Domain state, computed through the Store's own typed codec (encode) or its
-- fixed-shape domain normalizer (migrate). RU SaveData/LoadData may change the
-- on-disk representation of order-sensitive maps, empty tables or floats; as
-- long as the decoded value is logically equivalent, re-canonicalizing it on
-- both sides yields the same fingerprint. Content corruption survives decode
-- and changes the canonical value, so verification still fails closed.
function P:CanonicalIntegrityValue(store, domainValue)
    if type(store.encode) == "function" and type(store.decode) == "function" then
        local ok, encoded = pcall(store.encode, domainValue)
        if ok and type(encoded) == "table" then return encoded, nil end
        return nil, "canonical_encode_failed:" .. tostring(ok and type(encoded) or encoded)
    end
    if type(store.migrate) == "function" then
        local ok, normalized = pcall(store.migrate, domainValue)
        if ok and type(normalized) == "table" then return normalized, nil end
        if ok then return domainValue, nil end
        return nil, "canonical_normalize_failed:" .. tostring(normalized)
    end
    return domainValue, nil
end

-- Acceptance brief §8.4: a fingerprint mismatch alone ("A>B") is not
-- actionable. This walks the DISK domain and its canonical reconstruction in
-- the same deterministic key order the fingerprint uses and returns the FIRST
-- path where they differ, so one real-machine run names the exact field the
-- RU serializer (or a normalize gap) changed.
local function DescribeValueDivergence(expected, actual, path, depth, budget)
    if depth > 8 or budget.used >= budget.max then return nil end
    local expectedKind, actualKind = type(expected), type(actual)
    if expectedKind ~= actualKind then
        return tostring(path) .. ": type " .. expectedKind .. " vs " .. actualKind
    end
    if expectedKind ~= "table" then
        if expected ~= actual then
            return tostring(path) .. ": " .. tostring(expected) .. " vs " .. tostring(actual)
        end
        return nil
    end
    local keys = {}
    for key in pairs(expected) do keys[#keys + 1] = key end
    for key in pairs(actual) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local previous = nil
    for _, key in ipairs(keys) do
        if key ~= previous then
            previous = key
            budget.used = budget.used + 1
            local childPath = tostring(path) .. "." .. tostring(key)
            local found = DescribeValueDivergence(expected[key], actual[key], childPath, depth + 1, budget)
            if found ~= nil then return found end
        end
    end
    return nil
end

function P:DescribeCanonicalDivergence(expected, actual)
    if type(expected) ~= "table" or type(actual) ~= "table" then return nil end
    local budget = { used = 0, max = 512 }
    return DescribeValueDivergence(expected, actual, "$", 0, budget)
end

-- Fingerprint the canonical v3 value. Canonical values never contain __rsmeta,
-- so the durable (serializer-stable numeric token) hash applies directly.
function P:FingerprintCanonicalValue(store, canonical, budget)
    if canonical == nil then return nil, "canonical_value_missing" end
    return self:FingerprintDurablePayload(canonical, budget or store.encodedBudget)
end

local ENVELOPE_SEAL_BUDGET = { maxDepth = 4, maxNodes = 96, maxStringBytes = 4096, maxEntriesPerTable = 32 }

function P:FingerprintEnvelopeIntegrity(raw)
    if type(raw) ~= "table" then return nil, "encoded payload must be table" end
    local meta = type(raw.__rsmeta) == "table" and raw.__rsmeta or nil
    if meta == nil then return nil, "metadata_missing" end
    local canonical = {
        framework = tostring(meta.framework or "<nil>"),
        store = tostring(meta.store or "<nil>"),
        owner = tostring(meta.owner or "<nil>"),
        contractVersion = tostring(meta.contractVersion or "<nil>"),
        lifetime = tostring(meta.lifetime or "<nil>"),
        scope = tostring(meta.scope or "<nil>"),
        schema = tostring(meta.schema or "<nil>"),
        periodId = tostring(meta.periodId or "<nil>"),
        reliabilityContract = tostring(meta.reliabilityContract or "<nil>"),
        integrityVersion = tostring(meta.integrityVersion or "<nil>"),
        encodedFingerprint = tostring(meta.encodedFingerprint or meta.payloadFingerprint or "<nil>"),
        envelopeIntegrityVersion = tostring(meta.envelopeIntegrityVersion or "<nil>"),
        scopeBindingContract = tostring(meta.scopeBindingContract or "<nil>"),
        scopeIdentityFingerprint = tostring(meta.scopeIdentityFingerprint or "<nil>"),
    }
    return self:FingerprintPayload(canonical, ENVELOPE_SEAL_BUDGET)
end

function P:BuildRuntimeAcceptanceSnapshot(options)
    options = type(options) == "table" and options or {}
    local exact = {}
    for _, id in ipairs(type(options.ids) == "table" and options.ids or {}) do
        id = NormalizeId(id)
        if id ~= "" then exact[id] = true end
    end
    local prefixes = {}
    for _, prefix in ipairs(type(options.prefixes) == "table" and options.prefixes or {}) do
        prefix = NormalizeId(prefix)
        if prefix ~= "" then prefixes[#prefixes + 1] = prefix end
    end

    local selected, missing = {}, {}
    local function Selected(id)
        if exact[id] == true then return true end
        for _, prefix in ipairs(prefixes) do
            if id:sub(1, #prefix) == prefix then return true end
        end
        return options.includeAllV3 == true and id:sub(1, 3) == "v3."
    end
    for id in pairs(exact) do if self.stores[id] == nil then missing[#missing + 1] = id end end
    for _, id in ipairs(self.order) do if Selected(id) then selected[#selected + 1] = id end end
    table.sort(selected)
    table.sort(missing)

    local rows, aggregate = {}, 104729
    local healthy, loaded, dirty, fenced, fingerprinted = 0, 0, 0, 0, 0
    for _, id in ipairs(selected) do
        local store = self.stores[id]
        local row = {
            id = id,
            owner = store.owner,
            scope = store.scope,
            lifetime = store.lifetime,
            schema = store.schemaVersion,
            loaded = select(1, self:IsStoreLoaded(id)) == true,
            terminalLoaded = store.loaded == true,
            loadStatus = store.loadStatus,
            dirty = store.dirty == true,
            writeFenced = store.writeFenced == true,
            writeFenceReason = store.writeFenceReason,
            dirtyRevision = math.max(0, math.floor(tonumber(store.dirtyRevision) or 0)),
            lastSavedRevision = math.max(0, math.floor(tonumber(store.lastSavedRevision) or 0)),
            needsBarrierVerify = store.needsBarrierVerify == true,
            lastBarrierVerifyOk = store.lastBarrierVerifyOk,
            lastBarrierVerifyError = store.lastBarrierVerifyError,
            resolvedKey = store.resolvedKey,
            resolvedScopeFingerprint = store.resolvedScopeFingerprint,
            lastScopeBindingError = store.lastScopeBindingError,
            lastIntegrityStatus = store.lastIntegrityStatus,
            lastIntegrityError = store.lastIntegrityError,
            historicalRecoveryProbe = store.lastHistoricalRecoveryProbe,
        }
        if row.loaded then loaded = loaded + 1 end
        if row.dirty then dirty = dirty + 1 end
        if row.writeFenced then fenced = fenced + 1 end

        if row.loaded ~= true then
            row.error = "store_not_loaded:" .. tostring(row.loadStatus or "not_loaded")
        elseif type(store.get) ~= "function" then
            row.error = "store_get_unavailable"
        else
            local ok, payload = pcall(store.get)
            if ok ~= true then
                row.error = "store_get_exception:" .. tostring(payload)
            else
                local fingerprint, fingerprintErr, inspection = self:FingerprintDurablePayload(payload, store.budget)
                row.fingerprint = fingerprint
                row.error = fingerprintErr
                row.nodes = inspection and inspection.nodes or nil
                row.stringBytes = inspection and inspection.stringBytes or nil
                if fingerprint ~= nil then
                    fingerprinted = fingerprinted + 1
                    aggregate = HashText(aggregate, id .. "=" .. fingerprint .. ";")
                end
            end
        end
        if row.loaded == true and row.writeFenced ~= true and row.error == nil then healthy = healthy + 1 end
        rows[#rows + 1] = row
    end

    for _, id in ipairs(missing) do aggregate = HashText(aggregate, "MISSING=" .. id .. ";") end
    return {
        contractVersion = self.RuntimeAcceptanceSnapshotContractVersion,
        fingerprintMode = "serializer_stable_numeric_v2",
        at = NowMs(),
        buildTag = tostring(S.BuildTag or ""),
        generation = tonumber(S.Generation) or 0,
        total = #rows,
        exactMissing = missing,
        healthy = healthy,
        loaded = loaded,
        dirty = dirty,
        fenced = fenced,
        fingerprinted = fingerprinted,
        aggregateFingerprint = string.format("%08X", math.floor(aggregate)),
        rows = rows,
    }
end

function P:GetPersistentKeys()
    local result = {}
    for _, id in ipairs(self.order) do
        local store = self.stores[id]
        if store ~= nil and store.lifetime ~= LIFETIME.Session and store.key ~= nil then
            local key = select(1, self:ResolveStoreKey(store)) or store.key
            result[#result + 1] = key
        end
    end
    table.sort(result)
    return result
end

function P:Describe()
    local rows = {}
    local dirty, fenced, contractV2, contractV3, scopePending, budgetProtected, envelopeBudgetProtected, unloadedDirty, registrationBudgetFailed, barrierPending = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    for _, id in ipairs(self.order) do
        local store = self.stores[id]
        if store ~= nil then
            if store.dirty == true then
                dirty = dirty + 1
                if IsStoreReady(store) ~= true then unloadedDirty = unloadedDirty + 1 end
            end
            if store.writeFenced == true then fenced = fenced + 1 end
            if store.needsBarrierVerify == true then barrierPending = barrierPending + 1 end
            if tonumber(store.contractVersion) and tonumber(store.contractVersion) >= 2 then contractV2 = contractV2 + 1 end
            if tonumber(store.contractVersion) and tonumber(store.contractVersion) >= 3 then contractV3 = contractV3 + 1 end
            if type(store.budget) == "table" then budgetProtected = budgetProtected + 1 end
            if type(store.encodedBudget) == "table" then envelopeBudgetProtected = envelopeBudgetProtected + 1 end
            if store.registrationBudgetOk ~= true then registrationBudgetFailed = registrationBudgetFailed + 1 end
            if store.loadStatus == "scope_pending" then scopePending = scopePending + 1 end
            rows[#rows + 1] = {
                id = store.id,
                owner = store.owner,
                lifetime = store.lifetime,
                scope = store.scope,
                contractVersion = store.contractVersion,
                schema = store.schemaVersion,
                loaded = IsStoreReady(store) == true,
                terminalLoaded = store.loaded == true,
                loadStatus = store.loadStatus,
                dirty = store.dirty == true,
                writeFenced = store.writeFenced == true,
                writeFenceReason = store.writeFenceReason,
                periodId = store.periodId,
                baseKey = store.key,
                resolvedKey = store.resolvedKey,
                resolvedScopeFingerprint = store.resolvedScopeFingerprint,
                lastScopeBindingError = store.lastScopeBindingError,
            lastIntegrityStatus = store.lastIntegrityStatus,
            lastIntegrityError = store.lastIntegrityError,
            historicalRecoveryProbe = store.lastHistoricalRecoveryProbe,
                lastError = store.lastError,
                lastSaveAt = store.lastSaveAt,
                firstDirtyAt = store.firstDirtyAt,
                lastDirtyAt = store.lastDirtyAt,
                lastDirtyReason = store.lastDirtyReason,
                dirtyRevision = store.dirtyRevision,
                lastSavedRevision = store.lastSavedRevision,
                consecutiveSaveFailures = store.consecutiveSaveFailures,
                budget = DeepCopy(store.budget),
                encodedBudget = DeepCopy(store.encodedBudget),
                verifyAfterSave = store.verifyAfterSave == true,
                recoverableReplacement = store.recoverableReplacement == true,
                lastVerifyAt = store.lastVerifyAt,
                lastVerifyOk = store.lastVerifyOk,
                lastVerifyFingerprint = store.lastVerifyFingerprint,
                lastVerifyError = store.lastVerifyError,
                lastIntegrityStatus = store.lastIntegrityStatus,
                lastIntegrityFingerprint = store.lastIntegrityFingerprint,
                lastIntegrityError = store.lastIntegrityError,
                lastIntegrityDivergence = store.lastIntegrityDivergence,
                needsBarrierVerify = store.needsBarrierVerify == true,
                lastBarrierVerifyAt = store.lastBarrierVerifyAt,
                lastBarrierVerifyOk = store.lastBarrierVerifyOk,
                lastBarrierVerifyError = store.lastBarrierVerifyError,
                registrationBudgetOk = store.registrationBudgetOk == true,
                lastPayloadInspection = DeepCopy(store.lastPayloadInspection),
                lastEncodedInspection = DeepCopy(store.lastEncodedInspection),
                lastDecodedInspection = DeepCopy(store.lastDecodedInspection),
            }
        end
    end
    return {
        total = #rows,
        dirty = dirty,
        fenced = fenced,
        contractV2 = contractV2,
        contractV3 = contractV3,
        legacyContracts = #rows - contractV2,
        scopePending = scopePending,
        budgetProtected = budgetProtected,
        envelopeBudgetProtected = envelopeBudgetProtected,
        registrationBudgetFailed = registrationBudgetFailed,
        unloadedDirty = unloadedDirty,
        barrierPending = barrierPending,
        frameworkVersion = self.FrameworkVersion,
        transportContractVersion = self.TransportContractVersion,
        reliabilityContractVersion = self.ReliabilityContractVersion,
        integrityContractVersion = self.IntegrityContractVersion,
        legacyIntegrityContractVersion = self.LegacyIntegrityContractVersion,
        serializerNumericFingerprintContractVersion = self.SerializerNumericFingerprintContractVersion,
        envelopeIntegrityContractVersion = self.EnvelopeIntegrityContractVersion,
        scopeBindingContractVersion = self.ScopeBindingContractVersion,
        runtimeAcceptanceDiagnosticsContractVersion = self.RuntimeAcceptanceDiagnosticsContractVersion,
        runtimeAcceptanceSnapshotContractVersion = self.RuntimeAcceptanceSnapshotContractVersion,
        readinessContractVersion = self.ReadinessContractVersion,
        terminalLoadMemoizationContractVersion = self.TerminalLoadMemoizationContractVersion,
        historicalCanonicalRecoveryContractVersion = self.HistoricalCanonicalRecoveryContractVersion,
        knownLegacyCanonicalRecoveryContractVersion = self.KnownLegacyCanonicalRecoveryContractVersion,
        lastFlush = DeepCopy(self.lastFlush),
        rows = rows,
        stats = DeepCopy(self.stats),
    }
end

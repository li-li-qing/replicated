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
    FrameworkVersion = 2,
    Lifetime = LIFETIME,
    Scope = SCOPE,
    DefaultBudget = { maxDepth = 12, maxNodes = 4096, maxStringBytes = 65536, maxEntriesPerTable = 1024 },
    stores = {},
    order = {},
    keyOwners = {},
    defaultDelayMs = 750,
    periodCheckMs = 15000,
    nextPeriodCheckAt = 0,
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

local function CharacterScopeToken()
    -- V3 Character stores resolve identity directly from the authoritative
    -- world-qualified unit getter. They do not depend on the legacy monolithic
    -- Storage object or its deferred Character Override machinery.
    local key = nil
    if X2Unit ~= nil and S.Api ~= nil and type(S.Api.CallCapability) == "function" then
        local ok, value = S.Api:CallCapability("X2Unit:UnitNameWithWorld", X2Unit, "UnitNameWithWorld", "player")
        if ok then key = NonEmptyText(value) end
    end
    if key == nil then return nil end
    local token = NormalizeId("world:" .. key)
    if token == "" then return nil end
    if #token > 80 then token = token:sub(1, 80) end
    return token
end

function P:ResolveStoreKey(storeOrId)
    local store = type(storeOrId) == "table" and storeOrId or self:GetStore(storeOrId)
    if store == nil then return nil, "unknown store" end
    if store.lifetime == LIFETIME.Session then return nil, nil end
    local baseKey = NonEmptyText(store.key)
    if baseKey == nil then return nil, "store key unavailable" end
    if store.scope == SCOPE.Account then return baseKey, nil end
    if store.scope == SCOPE.Character then
        local token = CharacterScopeToken()
        if token == nil then return nil, "character scope unavailable" end
        return baseKey .. "_char_" .. token, nil
    end
    return nil, "unsupported scope: " .. tostring(store.scope)
end

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
        get = def.get,
        apply = def.apply,
        default = type(def.default) == "function" and def.default or function() return {} end,
        encode = def.encode,
        decode = def.decode,
        save = def.save,
        migrate = def.migrate,
        resetPolicy = def.resetPolicy,
        autoReset = def.autoReset == true,
        periodIdFromValue = def.periodIdFromValue,
        budget = NormalizeBudget(def.budget),
        dirty = false,
        dueAt = 0,
        loaded = false,
        loadStatus = "not_loaded",
        writeFenced = false,
        writeFenceReason = nil,
        lastError = nil,
        lastSaveAt = nil,
        lastLoadAt = nil,
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
            if inspection.ok ~= true then
                state.lastError = "default_payload_rejected:" .. tostring(inspection.reason or "unknown")
                Emit("error", "STORE_DEFAULT_BUDGET_EXCEEDED",
                    "注册即超预算：store 默认 payload 无法通过自身 SaveData 预算检查，所有保存都将被拒绝", {
                        store = id, reason = inspection.reason, nodes = inspection.nodes,
                        stringBytes = inspection.stringBytes, maxTableEntries = inspection.maxTableEntries,
                    })
            end
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
    return raw, nil
end

local function EncodeValue(store, value, periodId)
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

function P:LoadStore(id, options)
    options = type(options) == "table" and options or {}
    local store = self:GetStore(id)
    if store == nil then return false, nil, "unknown store" end
    if store.lifetime == LIFETIME.Session then
        if store.memory == nil then store.memory = select(1, DefaultValue(store)) end
        store.loaded, store.loadStatus, store.lastLoadAt = true, "session", NowMs()
        return true, DeepCopy(store.memory), nil
    end
    if S.Api == nil or type(S.Api.LoadData) ~= "function" then return false, nil, "LoadData unavailable" end
    local resolvedKey, scopeErr = self:ResolveStoreKey(store)
    if resolvedKey == nil then
        store.loaded = false
        store.loadStatus = "scope_pending"
        store.lastError = scopeErr
        return false, nil, scopeErr
    end
    store.resolvedKey = resolvedKey

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
    if type(raw) ~= "table" then
        store.loaded = true
        store.loadStatus = "empty"
        store.lastError = nil
        store.writeFenced = false
        store.writeFenceReason = nil
        return "empty", nil, nil
    end

    local meta = type(raw.__rsmeta) == "table" and raw.__rsmeta or nil
    if meta ~= nil then
        local mismatch = nil
        local metaFramework = tonumber(meta.framework)
        local metaContract = tonumber(meta.contractVersion)
        if metaFramework ~= nil and metaFramework > (tonumber(self.FrameworkVersion) or 2) then mismatch = "framework"
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

    local value, decodeErr = DecodeValue(store, raw)
    if decodeErr == nil and value == nil then decodeErr = "decoded payload missing" end
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
            value = migrated
            self.stats.migrations = (tonumber(self.stats.migrations) or 0) + 1
            store.dirty = true
            store.dueAt = NowMs() + self.defaultDelayMs
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
        store.dirty = true
        store.dueAt = NowMs()
        self.stats.periodResets = (tonumber(self.stats.periodResets) or 0) + 1
        Emit("info", "STORE_PERIOD_RESET", "独立存档跨周期重置", { store = store.id, oldPeriod = storedPeriod, newPeriod = currentPeriod })
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
    end
    store.loaded = true
    store.loadStatus = "loaded"
    store.writeFenced = false
    store.writeFenceReason = nil
    store.lastError = nil
    -- A previous save that exceeded the then-current budget leaves a permanent
    -- payload fence. After a store budget upgrade the same payload can fit
    -- again; revalidate and lift the fence automatically instead of stranding
    -- the store in write-only mode until a manual RevalidateStore call. Non
    -- payload fences (metadata/schema/load) stay untouched.
    if store.writeFenced == true and store.writeFenceReason ~= nil
        and (store.writeFenceReason:match("^payload_rejected:") ~= nil
            or store.writeFenceReason:match("^encoded_payload_rejected:") ~= nil) then
        self:RevalidateStore(id)
    end
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
    if store.writeFenced == true then
        Count("STORE_WRITE_FENCED", 1)
        return false, store.writeFenceReason or "write fenced"
    end
    if type(store.save) ~= "function" and (S.Api == nil or type(S.Api.SaveData) ~= "function") then
        return false, "SaveData unavailable"
    end
    local resolvedKey, scopeErr = self:ResolveStoreKey(store)
    if resolvedKey == nil then
        store.lastError = scopeErr
        return false, scopeErr
    end
    store.resolvedKey = resolvedKey

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

    local raw, encodeErr = EncodeValue(store, DeepCopy(value), periodId)
    if raw == nil then
        store.lastError = encodeErr
        self.stats.saveFailures = (tonumber(self.stats.saveFailures) or 0) + 1
        Emit("error", "STORE_ENCODE_FAILED", "独立存档编码失败", { store = store.id, error = encodeErr })
        return false, encodeErr
    end

    -- Inspect the FINAL serialized table too. A custom encode() is allowed to
    -- reshape data, so validating only the Domain snapshot would leave a path
    -- for an encoder to exceed the RU SaveData serializer's safe envelope.
    local encodedInspection = self:InspectPayload(raw, store.budget)
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

    local ok, saveErr
    if type(store.save) == "function" then
        local callOk, result, customErr = pcall(store.save, resolvedKey, raw, DeepCopy(value), options)
        if callOk then
            ok = result == true
            saveErr = customErr
        else
            ok = false
            saveErr = result
        end
    else
        ok, saveErr = S.Api:SaveData(resolvedKey, raw)
    end
    if ok ~= true then
        store.lastError = tostring(saveErr or "save failed")
        self.stats.saveFailures = (tonumber(self.stats.saveFailures) or 0) + 1
        Count("STORE_SAVE_FAILED", 1)
        Emit("warning", "STORE_SAVE_FAILED", "独立存档保存失败", { store = store.id, error = saveErr })
        if S.WarnOnce ~= nil then
            S.WarnOnce("store_save_failed_" .. store.id,
                "[" .. store.id .. "] 存档保存失败，本次修改可能无法保留：" .. tostring(saveErr or "unknown"))
        end
        if options.consumeDirty ~= true then
            store.dirty = true
            store.dueAt = NowMs() + math.min(30000, math.max(2000, tonumber(options.retryMs) or 5000))
        end
        return false, store.lastError
    end

    store.periodId = periodId
    store.lastSaveAt = NowMs()
    store.lastError = nil
    store.dirty = false
    store.dueAt = 0
    self.stats.saves = (tonumber(self.stats.saves) or 0) + 1
    Count("STORE_SAVED", 1)
    return true
end

function P:IsStoreLoaded(id)
    local store = self:GetStore(id)
    if store == nil then return false, "unknown store" end
    return store.loaded == true, store.loadStatus
end

function P:CanWrite(id)
    local store = self:GetStore(id)
    if store == nil then return false, "unknown store" end
    if store.lifetime == LIFETIME.Session then return true end
    if store.writeFenced == true then return false, store.writeFenceReason or store.lastError or "store write-fenced" end
    return true
end

function P:SaveStore(id, options)
    local store = self:GetStore(id)
    if store == nil then return false, "unknown store" end
    if store.lifetime == LIFETIME.Session then return self:SaveValue(id, store.memory, options) end
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
    local key, keyErr = self:ResolveStoreKey(store)
    if key == nil then return false, keyErr end
    if S.Api == nil or type(S.Api.ClearData) ~= "function" then return false, "ClearData unavailable" end
    local cleared, clearErr = S.Api:ClearData(key)
    if cleared ~= true then
        self.stats.clearFailures = (tonumber(self.stats.clearFailures) or 0) + 1
        Emit("warning", "STORE_CLEAR_FAILED", "独立存档物理清理失败", { store = store.id, error = tostring(clearErr or "unknown") })
        return false, clearErr or "clear failed"
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
    store.writeFenced, store.writeFenceReason, store.lastError = false, nil, nil
    store.lastLoadAt = NowMs()
    self.stats.clears = (tonumber(self.stats.clears) or 0) + 1
    Count("STORE_CLEARED", 1)
    return true
end

function P:MarkDirty(id, delayMs, reason)
    local store = self:GetStore(id)
    if store == nil then return false, "unknown store" end
    if store.lifetime == LIFETIME.Session then return true end
    if store.writeFenced == true then return false, store.writeFenceReason or store.lastError or "store write-fenced" end
    store.dirty = true
    local due = NowMs() + math.max(0, tonumber(delayMs) or self.defaultDelayMs)
    if store.dueAt == 0 or due < store.dueAt then store.dueAt = due end
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
    local raw, encodeErr = EncodeValue(store, DeepCopy(value), periodId)
    if raw == nil then return false, encodeErr end
    local encodedInspection = self:InspectPayload(raw, store.budget)
    store.lastEncodedInspection = encodedInspection
    if encodedInspection.ok ~= true then return false, encodedInspection.reason end
    store.writeFenced = false
    store.writeFenceReason = nil
    store.lastError = nil
    store.dirty = true
    store.dueAt = NowMs()
    return true
end

function P:Flush(owner)
    local allOk = true
    owner = NonEmptyText(owner)
    for _, id in ipairs(self.order) do
        local store = self.stores[id]
        if store ~= nil and store.dirty == true and (owner == nil or store.owner == owner) then
            local ok = self:SaveStore(id)
            if ok ~= true then allOk = false end
        end
    end
    return allOk
end

function P:Tick()
    local now = NowMs()
    for _, id in ipairs(self.order) do
        local store = self.stores[id]
        if store ~= nil and store.dirty == true and now >= (tonumber(store.dueAt) or 0) then self:SaveStore(id) end
    end

    if now < (tonumber(self.nextPeriodCheckAt) or 0) then return end
    self.nextPeriodCheckAt = now + math.max(5000, tonumber(self.periodCheckMs) or 15000)
    for _, id in ipairs(self.order) do
        local store = self.stores[id]
        if store ~= nil and store.loaded == true and store.autoReset == true
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
    local dirty, fenced, contractV2, contractV3, scopePending, budgetProtected = 0, 0, 0, 0, 0, 0
    for _, id in ipairs(self.order) do
        local store = self.stores[id]
        if store ~= nil then
            if store.dirty == true then dirty = dirty + 1 end
            if store.writeFenced == true then fenced = fenced + 1 end
            if tonumber(store.contractVersion) and tonumber(store.contractVersion) >= 2 then contractV2 = contractV2 + 1 end
            if tonumber(store.contractVersion) and tonumber(store.contractVersion) >= 3 then contractV3 = contractV3 + 1 end
            if type(store.budget) == "table" then budgetProtected = budgetProtected + 1 end
            if store.loadStatus == "scope_pending" then scopePending = scopePending + 1 end
            rows[#rows + 1] = {
                id = store.id,
                owner = store.owner,
                lifetime = store.lifetime,
                scope = store.scope,
                contractVersion = store.contractVersion,
                schema = store.schemaVersion,
                loaded = store.loaded == true,
                loadStatus = store.loadStatus,
                dirty = store.dirty == true,
                writeFenced = store.writeFenced == true,
                writeFenceReason = store.writeFenceReason,
                periodId = store.periodId,
                baseKey = store.key,
                resolvedKey = store.resolvedKey,
                lastError = store.lastError,
                lastSaveAt = store.lastSaveAt,
                budget = DeepCopy(store.budget),
                lastPayloadInspection = DeepCopy(store.lastPayloadInspection),
                lastEncodedInspection = DeepCopy(store.lastEncodedInspection),
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
        rows = rows,
        stats = DeepCopy(self.stats),
    }
end

------------------------------------------------------------------------
-- Replicated Suite - RSUI Numeric Range Preference Store v1
--
-- Presentation-only persistence for adaptive NumericField slider endpoints.
-- Business values remain owned by their Feature/App Store bindings. This Store
-- only remembers outward range expansion (for example 1..10 -> 1..20) so the
-- same slider affordance survives Fresh Reload without coupling every Feature
-- schema to RSUI presentation metadata.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local P, RSUI = S.Persistence, S.RSUI
if type(P) ~= "table" or type(P.RegisterV3Store) ~= "function" or type(RSUI) ~= "table" then return end

RSUI.NumericRangePersistenceContractVersion = 1

local Store = RSUI.NumericRangeStore or {
    version = 1,
    storeId = "v3.rsui.numeric_ranges",
    loaded = false,
    sessionFallback = false,
    lastLoadError = nil,
    state = { ranges = {} },
}
RSUI.NumericRangeStore = Store

local MAX_RANGES = 160
local STORE_ID = Store.storeId

local function FiniteNumber(value)
    local number = tonumber(value)
    if number == nil or number ~= number or number == math.huge or number == -math.huge then return nil end
    return number
end

local function NormalizeRange(value)
    if type(value) ~= "table" then return nil end
    local minimum, maximum = FiniteNumber(value.min), FiniteNumber(value.max)
    if minimum == nil or maximum == nil then return nil end
    if maximum < minimum then minimum, maximum = maximum, minimum end
    return { min = minimum, max = maximum }
end

local function NormalizeState(value)
    value = type(value) == "table" and value or {}
    local source = type(value.ranges) == "table" and value.ranges or {}
    local ranges, count = {}, 0
    for key, range in pairs(source) do
        if count >= MAX_RANGES then break end
        key = tostring(key or "")
        if key ~= "" and #key <= 160 then
            local normalized = NormalizeRange(range)
            if normalized ~= nil then
                ranges[key] = normalized
                count = count + 1
            end
        end
    end
    return { ranges = ranges }
end

local function ApplyState(value)
    Store.state = NormalizeState(value)
end

if P:GetStore(STORE_ID) == nil then
    local registered, registerErr = P:RegisterV3Store({
        id = STORE_ID,
        owner = "rsui.numeric_ranges",
        scope = P.Scope and P.Scope.Account or "account",
        lifetime = P.Lifetime and P.Lifetime.Permanent or "permanent",
        schemaVersion = 1,
        legacySchemaVersion = 0,
        key = P.V3KeyPrefix and (P.V3KeyPrefix .. "rsui_numeric_ranges") or STORE_ID,
        budget = { maxDepth = 5, maxNodes = 540, maxStringBytes = 18000, maxEntriesPerTable = 180 },
        default = function() return NormalizeState(nil) end,
        get = function() return NormalizeState(Store.state) end,
        apply = ApplyState,
    })
    if registered == nil and S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Error) == "function" then
        S.DiagnosticsManager:Error("rsui", "NUMERIC_RANGE_STORE_REGISTER_FAILED", "数值滑块范围存档注册失败", {
            error = tostring(registerErr or "unknown"),
        })
    end
end

function Store:EnsureLoaded()
    if self.loaded == true then return true end
    if P:GetStore(STORE_ID) == nil then
        self.loaded, self.sessionFallback, self.lastLoadError = true, true, "store_unavailable"
        ApplyState(nil)
        return true, self.lastLoadError
    end
    local status, _, err = P:LoadStore(STORE_ID)
    if status == true or status == "empty" then
        if status == "empty" then ApplyState(nil) end
        self.loaded, self.sessionFallback, self.lastLoadError = true, false, nil
        return true
    end
    -- Range metadata is non-critical. Preserve usability in-memory while never
    -- overwriting a failed/fenced physical payload during the degraded session.
    self.loaded, self.sessionFallback, self.lastLoadError = true, true, tostring(err or status or "load_failed")
    ApplyState(nil)
    if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Warn) == "function" then
        S.DiagnosticsManager:Warn("rsui", "NUMERIC_RANGE_STORE_SESSION_FALLBACK",
            "数值滑块范围存档读取失败；本次会话继续使用默认范围且不会覆盖原存档", { error = self.lastLoadError })
    end
    return true, self.lastLoadError
end

function Store:Get(fieldId)
    self:EnsureLoaded()
    local key = tostring(fieldId or "")
    local range = self.state and self.state.ranges and self.state.ranges[key] or nil
    range = NormalizeRange(range)
    if range == nil then return nil, nil end
    return range.min, range.max
end

function Store:Set(fieldId, minimum, maximum, reason)
    self:EnsureLoaded()
    local key = tostring(fieldId or "")
    if key == "" or #key > 160 then return false, "invalid_range_key" end
    local normalized = NormalizeRange({ min = minimum, max = maximum })
    if normalized == nil then return false, "invalid_range" end

    local function ApplyMutation()
        self.state = NormalizeState(self.state)
        self.state.ranges[key] = { min = normalized.min, max = normalized.max }
        return true
    end

    if self.sessionFallback == true then return ApplyMutation(), "session_fallback_no_persist" end
    if type(P.MutateStore) ~= "function" then return false, "persistence_transaction_unavailable" end
    return P:MutateStore(STORE_ID, ApplyMutation, {
        delayMs = 400,
        reason = tostring(reason or ("numeric_range:" .. key)),
    })
end

function Store:Describe(fieldId)
    local minimum, maximum = self:Get(fieldId)
    return {
        id = tostring(fieldId or ""), minimum = minimum, maximum = maximum,
        loaded = self.loaded == true, sessionFallback = self.sessionFallback == true,
        lastLoadError = self.lastLoadError,
    }
end

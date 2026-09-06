------------------------------------------------------------------------
-- Replicated Suite V3 - Task Tracker Store
--
-- Persistent presentation policy only. Quest completion/progress remains owned
-- by QuestProgressService V3. Tracking is account-permanent and defaults to
-- "all curated groups tracked" until the user makes an explicit selection.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local P = S.Persistence
if type(P) ~= "table" or type(P.RegisterV3Store) ~= "function" then return end

S.Features = S.Features or {}
S.Features.Tasks = S.Features.Tasks or {}
local F = S.Features.Tasks

F.WidgetWindowSizePolicy = {
    defaultWidth = 420,
    defaultHeight = 286,
    minWidth = 1,
    minHeight = 1,
}
local WINDOW_SIZE = F.WidgetWindowSizePolicy
local STORE_ID = "v3.tasks"
local TASK_CODEC_VERSION = 2
local VALID_SCOPE = { daily = true, weekly = true }

-- Domain code keeps O(1) membership maps. SaveData does not need that shape:
-- RU has now produced a real cross-reload fingerprint mismatch on this Store
-- while the independent metadata envelope remained healthy. The only dynamic
-- associative tables here are tracked group sets, so the persistence codec
-- writes them as sorted arrays. This removes serializer-dependent map shape
-- without changing the Feature's in-memory Authority or lookup complexity.
local function NormalizeKeys(value)
    local result = {}
    for key, enabled in pairs(type(value) == "table" and value or {}) do
        local candidate = nil
        if enabled == true then
            candidate = key
        elseif type(key) == "number" and type(enabled) == "string" then
            -- Codec v2 / RU-normalized sequence form: { "guild", "pack20" }.
            candidate = enabled
        end
        candidate = tostring(candidate or "")
        if candidate ~= "" then result[candidate] = true end
    end
    return result
end

local function SortedKeyArray(value)
    local out = {}
    for key, enabled in pairs(NormalizeKeys(value)) do
        if enabled == true then out[#out + 1] = tostring(key) end
    end
    table.sort(out)
    return out
end

local function NormalizeTracking(value)
    value = type(value) == "table" and value or {}
    return {
        configured = value.configured == true,
        keys = NormalizeKeys(value.keys),
    }
end

local Floating = S.RSUI and S.RSUI.FloatingSurface or nil
if type(Floating) ~= "table" or type(Floating.NormalizeState) ~= "function" then error("FloatingSurface unavailable for Tasks store") end

local function NormalizeWindow(value)
    return Floating:NormalizeState(value, {
        defaultWidth = WINDOW_SIZE.defaultWidth, defaultHeight = WINDOW_SIZE.defaultHeight,
        minWidth = WINDOW_SIZE.minWidth, minHeight = WINDOW_SIZE.minHeight,
        defaultOverallOpacity = 0.94, defaultBackgroundOpacity = 1.0, defaultTextOpacity = 1.0,
    })
end

local function Normalize(value)
    value = type(value) == "table" and value or {}
    local tracking = type(value.tracking) == "table" and value.tracking or {}
    return {
        tracking = {
            daily = NormalizeTracking(tracking.daily),
            weekly = NormalizeTracking(tracking.weekly),
        },
        lastScope = VALID_SCOPE[tostring(value.lastScope or "")] and tostring(value.lastScope) or "daily",
        widgetVisible = value.widgetVisible == true,
        widgetRows = math.max(3, math.min(18, math.floor(tonumber(value.widgetRows) or 9))),
        widgetWindow = NormalizeWindow(value.widgetWindow),
    }
end

local function EncodeTaskState(value)
    local normalized = Normalize(value)
    return {
        codec = TASK_CODEC_VERSION,
        payload = {
            tracking = {
                daily = { configured = normalized.tracking.daily.configured == true, keys = SortedKeyArray(normalized.tracking.daily.keys) },
                weekly = { configured = normalized.tracking.weekly.configured == true, keys = SortedKeyArray(normalized.tracking.weekly.keys) },
            },
            lastScope = normalized.lastScope,
            widgetVisible = normalized.widgetVisible == true,
            widgetRows = normalized.widgetRows,
            widgetWindow = normalized.widgetWindow,
        },
    }
end

-- Migration-safe decode (§ old-user upgrade): accepts the current codec
-- envelope, the intermediate { payload = ... } wrapper build, and the original
-- pre-codec bare-Domain shape. Normalize() is strict about content, so shape
-- tolerance here cannot smuggle corrupted values into the Domain.
local function DecodeTaskState(raw)
    if type(raw) ~= "table" then return nil, "task_encoded_payload_required" end
    local payload = raw
    if raw.codec ~= nil or type(raw.payload) == "table" then
        payload = type(raw.payload) == "table" and raw.payload or nil
        if payload == nil then return nil, "task_payload_missing" end
    end
    return Normalize(payload), nil
end

-- This hook exists only to recover an already-written pre-canonical Store from
-- a proven RU representation change. Persistence does NOT trust the result: it
-- hashes each reconstructed candidate and accepts it only if it exactly equals
-- the fingerprint stamped before the native serializer round-trip. Current
-- codec payloads are never eligible, so future corruption cannot use this path.
-- Two historical on-disk shapes existed before the typed codec: the bare
-- normalized Domain (the original no-encode contract) and an intermediate
-- { payload = ... } wrapper build; each was stamped over its own shape, so both
-- reconstructions are offered and only an exact stamp match wins.
local function RebuildLegacyEncodedForIntegrity(raw)
    if type(raw) ~= "table" then return nil, "not_pre_codec_task_payload" end
    if raw.codec ~= nil then return nil, "codec_payload_not_eligible" end
    local source = type(raw.payload) == "table" and raw.payload or raw
    return { candidates = { Normalize(source), { payload = Normalize(source) } } },
        "task_tracking_set_map_reconstruction"
end

F.State = Normalize(F.State)

local function Apply(value)
    local normalized = Normalize(value)
    F.State.tracking = normalized.tracking
    F.State.lastScope = normalized.lastScope
    F.State.widgetVisible = normalized.widgetVisible
    F.State.widgetRows = normalized.widgetRows
    F.State.widgetWindow = normalized.widgetWindow
end

if P:GetStore(STORE_ID) == nil then
    local store, err = P:RegisterV3Store({
        id = STORE_ID,
        owner = "v3.tasks",
        scope = P.Scope.Account,
        lifetime = P.Lifetime.Permanent,
        schemaVersion = 1,
        legacySchemaVersion = 0,
        key = P.V3KeyPrefix .. "tasks",
        budget = { maxDepth = 7, maxNodes = 260, maxStringBytes = 4096, maxEntriesPerTable = 160 },
        default = function() return Normalize(nil) end,
        get = function() return Normalize(F.State) end,
        apply = Apply,
        encode = EncodeTaskState,
        decode = DecodeTaskState,
        rebuildEncodedForIntegrity = RebuildLegacyEncodedForIntegrity,
        allowIntegrityUpgrade = true,
        migrate = function(value) return Normalize(value) end,
    })
    if store == nil and S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Error) == "function" then
        S.DiagnosticsManager:Error("tasks_v3", "TASK_STORE_REGISTER_FAILED", "任务追踪存档注册失败", { error = tostring(err) })
    end
end

F.StoreId = STORE_ID
F.PersistenceCodecVersion = TASK_CODEC_VERSION
F.StoreLoaded = F.StoreLoaded == true

function F:EnsureStoreLoaded()
    if type(P.IsStoreLoaded) == "function" and P:IsStoreLoaded(STORE_ID) == true then self.StoreLoaded = true; return true end
    if P:GetStore(STORE_ID) == nil then return false, "任务追踪存档不可用" end
    local status, _, err = P:LoadStore(STORE_ID)
    if status == true or status == "empty" then
        if status == "empty" then Apply(nil) end
        self.StoreLoaded = true
        return true
    end
    return false, err or tostring(status or "读取失败")
end

function F:MarkStoreDirty(delayMs, reason)
    return P:MarkDirty(STORE_ID, tonumber(delayMs) or 350, reason or "task_tracking_changed")
end

function F:MutateStore(mutator, delayMs, reason, durable)
    if type(P.MutateStore) ~= "function" then return false, "任务追踪持久化事务不可用" end
    return P:MutateStore(STORE_ID, function() return mutator() end, {
        delayMs = tonumber(delayMs) or 350,
        reason = tostring(reason or "task_tracking_changed"),
        durable = durable == true,
    })
end

------------------------------------------------------------------------
-- Replicated Suite V3 - Activity Feature Store
--
-- Owns Activity presentation preferences only. Schema v7 keeps free-placement
-- coordinates, removes semantic minimum-size clamps and adds independent
-- overall/background/text opacity channels while migrating the old opacity field.
-- Activity floating-window geometry/minimized state used by common RSUI Windowing
-- foundation. Gameplay truth remains in ActivityAuthority.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local P = S.Persistence
if type(P) ~= "table" or type(P.RegisterV3Store) ~= "function" then return end

S.Features = S.Features or {}
S.Features.Activities = S.Features.Activities or {}
local F = S.Features.Activities
F.WidgetWindowSizePolicy = {
    defaultWidth = 430,
    defaultHeight = 276,
    minWidth = 1,
    minHeight = 1,
}
local WINDOW_SIZE = F.WidgetWindowSizePolicy

F.State = type(F.State) == "table" and F.State or {
    widgetVisible = false,
    widgetRows = 8,
    hiddenEvents = {},
    widgetWindow = { width = WINDOW_SIZE.defaultWidth, height = WINDOW_SIZE.defaultHeight, minimized = false, locked = false, overallOpacity = 0.94, backgroundOpacity = 1.0, textOpacity = 1.0, userMoved = false },
}

local STORE_ID = "v3.activities"
local Floating = S.RSUI and S.RSUI.FloatingSurface or nil
if type(Floating) ~= "table" or type(Floating.NormalizeState) ~= "function" then error("FloatingSurface unavailable for Activities store") end

local function NormalizeWindow(value)
    return Floating:NormalizeState(value, {
        defaultWidth = WINDOW_SIZE.defaultWidth, defaultHeight = WINDOW_SIZE.defaultHeight,
        minWidth = WINDOW_SIZE.minWidth, minHeight = WINDOW_SIZE.minHeight,
        defaultOverallOpacity = 0.94, defaultBackgroundOpacity = 1.0, defaultTextOpacity = 1.0,
    })
end

local function Normalize(value)
    value = type(value) == "table" and value or {}
    local hidden = {}
    for key, enabled in pairs(type(value.hiddenEvents) == "table" and value.hiddenEvents or {}) do
        key = tostring(key or "")
        if key ~= "" and enabled == true then hidden[key] = true end
    end
    return {
        widgetVisible = value.widgetVisible == true,
        widgetRows = math.max(3, math.min(16, math.floor(tonumber(value.widgetRows) or 8))),
        hiddenEvents = hidden,
        widgetWindow = NormalizeWindow(value.widgetWindow),
    }
end

local function Apply(value)
    local normalized = Normalize(value)
    F.State.widgetVisible = normalized.widgetVisible
    F.State.widgetRows = normalized.widgetRows
    F.State.hiddenEvents = normalized.hiddenEvents
    F.State.widgetWindow = normalized.widgetWindow
end

if P:GetStore(STORE_ID) == nil then
    local store, err = P:RegisterV3Store({
        id = STORE_ID,
        owner = "v3.activities",
        scope = P.Scope.Account,
        lifetime = P.Lifetime.Permanent,
        schemaVersion = 7,
        legacySchemaVersion = 6,
        key = P.V3KeyPrefix .. "activities",
        budget = { maxDepth = 7, maxNodes = 200, maxStringBytes = 4096, maxEntriesPerTable = 112 },
        default = function() return Normalize(nil) end,
        get = function() return Normalize(F.State) end,
        apply = Apply,
        migrate = function(value) return Normalize(value) end,
    })
    if store == nil and S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Error) == "function" then
        S.DiagnosticsManager:Error("activities_v3", "ACTIVITY_STORE_REGISTER_FAILED", "活动模块存档注册失败", { error = tostring(err) })
    end
end

F.StoreId = STORE_ID
F.StoreLoaded = F.StoreLoaded == true

function F:EnsureStoreLoaded()
    if type(P.IsStoreLoaded) == "function" and P:IsStoreLoaded(STORE_ID) == true then self.StoreLoaded = true; return true end
    local store = P:GetStore(STORE_ID)
    if store == nil then return false, "活动模块存档不可用" end
    local status, _, err = P:LoadStore(STORE_ID)
    if status == true or status == "empty" then
        if status == "empty" then Apply(nil) end
        self.StoreLoaded = true
        return true
    end
    return false, err or tostring(status or "读取失败")
end

function F:MarkStoreDirty(delayMs, reason)
    return P:MarkDirty(STORE_ID, tonumber(delayMs) or 500, reason or "activity_changed")
end

function F:MutateStore(mutator, delayMs, reason, durable)
    if type(P.MutateStore) ~= "function" then return false, "活动持久化事务不可用" end
    return P:MutateStore(STORE_ID, function() return mutator() end, {
        delayMs = tonumber(delayMs) or 500, reason = tostring(reason or "activity_changed"), durable = durable == true,
    })
end

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
local VALID_SCOPE = { daily = true, weekly = true }

local function NormalizeKeys(value)
    local result = {}
    for key, enabled in pairs(type(value) == "table" and value or {}) do
        key = tostring(key or "")
        if key ~= "" and enabled == true then result[key] = true end
    end
    return result
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
        migrate = function(value) return Normalize(value) end,
    })
    if store == nil and S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Error) == "function" then
        S.DiagnosticsManager:Error("tasks_v3", "TASK_STORE_REGISTER_FAILED", "任务追踪存档注册失败", { error = tostring(err) })
    end
end

F.StoreId = STORE_ID
F.StoreLoaded = F.StoreLoaded == true

function F:EnsureStoreLoaded()
    if self.StoreLoaded == true then return true end
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

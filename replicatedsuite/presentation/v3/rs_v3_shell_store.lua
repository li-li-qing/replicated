------------------------------------------------------------------------
-- Replicated Suite V3 - Shell Persistence Contract
--
-- Application-window preferences only. Domain/Feature state is never stored
-- here. Schema v6 preserves explicit V3 free-placement only. Legacy edge
-- placement is intentionally re-centered once so the rebuilt menu no longer
-- inherits old top-left defaults. Windowing adds no semantic minimum/maximum
-- unless a caller opts in.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local P = S.Persistence
if type(P) ~= "table" or type(P.RegisterV3Store) ~= "function" then return end

S.UIV3 = S.UIV3 or {}
local V3 = S.UIV3
V3.ShellSizePolicy = {
    defaultWidth = 1040,
    defaultHeight = 700,
    minWidth = 1,
    minHeight = 1,
}
local SIZE = V3.ShellSizePolicy
V3.ShellState = type(V3.ShellState) == "table" and V3.ShellState or {
    width = SIZE.defaultWidth,
    height = SIZE.defaultHeight,
    lastRoute = "home",
    minimized = false,
    locked = false,
    userMoved = false,
}

local STORE_ID = "v3.shell"
local function AtLeast(value, minimum, fallback)
    local number = tonumber(value) or tonumber(fallback) or minimum
    return math.max(minimum, number)
end
local function NormalizeState(value)
    value = type(value) == "table" and value or {}
    local requestedMoved = value.userMoved == true
    local free = requestedMoved and tostring(value.coordinateSpace or "") == "logical-free-v2"
        and tonumber(value.x) ~= nil and tonumber(value.y) ~= nil
    -- Edge-v1 belonged to the retired shell placement model. Carrying an old
    -- LEFT/TOP offset of zero into V3 makes the rebuilt menu reopen in the
    -- corner forever. Only an explicit V3 free placement is authoritative.
    local moved = free
    return {
        width = AtLeast(value.width, SIZE.minWidth, SIZE.defaultWidth),
        height = AtLeast(value.height, SIZE.minHeight, SIZE.defaultHeight),
        lastRoute = (tostring(value.lastRoute or "home") == "foundation") and "home" or tostring(value.lastRoute or "home"),
        minimized = value.minimized == true,
        locked = value.locked == true,
        userMoved = moved,
        x = moved and tonumber(value.x) or nil,
        y = moved and tonumber(value.y) or nil,
        anchorH = nil,
        anchorV = nil,
        offsetX = nil,
        offsetY = nil,
        coordinateSpace = moved and "logical-free-v2" or nil,
        savedUiScale = moved and tonumber(value.savedUiScale) or nil,
    }
end

local function Apply(value)
    local normalized = NormalizeState(value)
    for key in pairs(V3.ShellState) do V3.ShellState[key] = nil end
    for key, item in pairs(normalized) do V3.ShellState[key] = item end
end

if P:GetStore(STORE_ID) == nil then
    local store, err = P:RegisterV3Store({
        id = STORE_ID,
        owner = "v3.shell",
        scope = P.Scope.Account,
        lifetime = P.Lifetime.Permanent,
        schemaVersion = 6,
        legacySchemaVersion = 5,
        key = P.V3KeyPrefix .. "shell",
        budget = { maxDepth = 5, maxNodes = 80, maxStringBytes = 2048, maxEntriesPerTable = 40 },
        default = function() return NormalizeState(nil) end,
        get = function() return NormalizeState(V3.ShellState) end,
        apply = Apply,
        migrate = function(value) return NormalizeState(value) end,
    })
    if store == nil and S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Error) == "function" then
        S.DiagnosticsManager:Error("ui_v3", "SHELL_STORE_REGISTER_FAILED", "新版主窗口存档注册失败", { error = tostring(err) })
    end
end

V3.ShellStoreId = STORE_ID
V3.ShellStoreLoaded = V3.ShellStoreLoaded == true

function V3:EnsureShellStoreLoaded()
    if self.ShellStoreLoaded == true then return true end
    local store = P:GetStore(STORE_ID)
    if store == nil then return false, "新版主窗口存档不可用" end
    local status, _, err = P:LoadStore(STORE_ID)
    if status == true or status == "empty" then
        if status == "empty" then Apply(nil) end
        self.ShellStoreLoaded = true
        return true
    end
    return false, err or tostring(status or "读取失败")
end

function V3:MarkShellStoreDirty(delayMs, reason)
    if P:GetStore(STORE_ID) == nil then return false, "新版主窗口存档不可用" end
    return P:MarkDirty(STORE_ID, tonumber(delayMs) or 750, reason or "shell_changed")
end

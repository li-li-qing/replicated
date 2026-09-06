------------------------------------------------------------------------
-- Replicated Suite V3 - Launcher / Recovery Entry Store
--
-- The bootstrap R entry exists before Persistence is available, but once V3
-- Foundation is ready its placement becomes a normal account-level V3 store.
-- The launcher remains usable during startup failure; persistence is an upgrade,
-- never a prerequisite for the recovery path.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local P = S.Persistence
if type(P) ~= "table" or type(P.RegisterV3Store) ~= "function" then return end

S.UIV3 = S.UIV3 or {}
local V3 = S.UIV3
V3.LauncherState = type(V3.LauncherState) == "table" and V3.LauncherState or {
    userMoved = false,
}

local STORE_ID = "v3.launcher"
local LAUNCHER_LOGICAL_SIZE = 30
local function Normalize(value)
    value = type(value) == "table" and value or {}
    local moved = value.userMoved == true
    local free = moved and tostring(value.coordinateSpace or "") == "logical-free-v2"
        and tonumber(value.x) ~= nil and tonumber(value.y) ~= nil
    return {
        userMoved = moved,
        x = free and tonumber(value.x) or nil,
        y = free and tonumber(value.y) or nil,
        anchorH = moved and not free and (tostring(value.anchorH or "") == "RIGHT" and "RIGHT" or "LEFT") or nil,
        anchorV = moved and not free and (tostring(value.anchorV or "") == "BOTTOM" and "BOTTOM" or "TOP") or nil,
        offsetX = moved and not free and math.max(0, tonumber(value.offsetX) or 0) or nil,
        offsetY = moved and not free and math.max(0, tonumber(value.offsetY) or 0) or nil,
        coordinateSpace = moved and (free and "logical-free-v2" or "logical-edge-v1") or nil,
        savedUiScale = moved and tonumber(value.savedUiScale) or nil,
    }
end

local function Apply(value)
    local normalized = Normalize(value)
    for k in pairs(V3.LauncherState) do V3.LauncherState[k] = nil end
    for k,v in pairs(normalized) do V3.LauncherState[k] = v end
end

if P:GetStore(STORE_ID) == nil then
    P:RegisterV3Store({
        id = STORE_ID,
        owner = "v3.launcher",
        scope = P.Scope.Account,
        lifetime = P.Lifetime.Permanent,
        schemaVersion = 2,
        legacySchemaVersion = 1,
        key = P.V3KeyPrefix .. "launcher",
        budget = { maxDepth = 4, maxNodes = 40, maxStringBytes = 512, maxEntriesPerTable = 24 },
        default = function() return Normalize(nil) end,
        get = function() return Normalize(V3.LauncherState) end,
        apply = Apply,
        migrate = function(value) return Normalize(value) end,
    })
end

V3.LauncherStoreId = STORE_ID
V3.LauncherStoreLoaded = V3.LauncherStoreLoaded == true
V3.LauncherStoreSessionFallback = V3.LauncherStoreSessionFallback == true
V3.LauncherStoreLoadError = V3.LauncherStoreLoadError

function V3:UseLauncherSessionDefaults(reason)
    Apply(nil)
    self.LauncherStoreLoaded = true
    self.LauncherStoreSessionFallback = true
    self.LauncherStoreLoadError = tostring(reason or "launcher store load failed")
    if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Warn) == "function" then
        S.DiagnosticsManager:Warn("ui_v3", "LAUNCHER_STORE_SESSION_FALLBACK",
            "启动按钮存档读取失败；本次会话使用默认位置，不以降级值主动覆盖原存档",
            { error = self.LauncherStoreLoadError })
    end
    return true
end

function V3:EnsureLauncherStoreLoaded()
    if self.LauncherStoreLoaded == true then return true end
    local store = P:GetStore(STORE_ID)
    if store == nil then return self:UseLauncherSessionDefaults("启动按钮存档不可用") end
    local status, _, err = P:LoadStore(STORE_ID)
    if status == true or status == "empty" then
        if status == "empty" then Apply(nil) end
        self.LauncherStoreLoaded = true
        self.LauncherStoreSessionFallback = false
        self.LauncherStoreLoadError = nil
        return true
    end
    return self:UseLauncherSessionDefaults(err or tostring(status or "读取失败"))
end

function V3:MarkLauncherStoreDirty(delayMs, reason)
    if self.LauncherStoreSessionFallback == true then return true, "session_fallback_no_persist" end
    return P:MarkDirty(STORE_ID, tonumber(delayMs) or 250, reason or "launcher_changed")
end

function V3:ApplyLauncherPlacement()
    local button = S.RecoveryEntry
    if button == nil or S.Layout == nil then return false end
    -- Launcher is a screen affordance, not Suite content. SetExtent receives
    -- logical UI coordinates already affected by the client's UI scale; applying
    -- Suite content scale here again double-scaled R on low-resolution / high-scale setups.
    local size = LAUNCHER_LOGICAL_SIZE
    S.Layout:ApplyPlacement(button, self.LauncherState, size, size, 300, 100, { mode = "free" })
    if type(S.Layout.RegisterFloating) == "function" then
        S.Layout:RegisterFloating("v3_launcher", button, {
            onlyWhenVisible = true,
            onMetricsChanged = function()
                S.Layout:ApplyPlacement(button, V3.LauncherState, LAUNCHER_LOGICAL_SIZE, LAUNCHER_LOGICAL_SIZE, 300, 100, { mode = "free" })
            end,
        })
    end
    if type(S.Layout.RegisterScreenSnap) == "function" then
        S.Layout:RegisterScreenSnap("v3_launcher", button, {
            snapGroup = "screen_buttons",
            snapKind = "button",
            snapDistance = 16,
            snapGap = 0,
        })
    end
    return true
end

function V3:ResetLauncherPlacement(persist)
    local state = self.LauncherState
    if type(state) ~= "table" then return false end
    state.userMoved = false
    state.x, state.y, state.anchorH, state.anchorV = nil, nil, nil, nil
    state.offsetX, state.offsetY, state.coordinateSpace, state.savedUiScale = nil, nil, nil, nil
    local ok = self:ApplyLauncherPlacement()
    if persist ~= false then self:MarkLauncherStoreDirty(250, "launcher_reset") end
    return ok
end

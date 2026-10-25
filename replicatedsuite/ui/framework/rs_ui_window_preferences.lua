-- Replicated Suite · 窗口层级偏好
-- 作者：Replicated
-- QQ群：1104129461
-- 顶层 RSUI 窗口共用仅表现偏好；业务 Store 仍持几何/外观，Native 层级偏好独立保存，避免改大量冻结 Feature 规范形状。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local P, RSUI = S.Persistence, S.RSUI
if type(P) ~= "table" or type(P.RegisterV3Store) ~= "function" or type(RSUI) ~= "table" then return end

local STORE_ID = "v3.rsui.window_preferences"
local MAX_WINDOWS = 192

local Store = RSUI.WindowPreferences or {
    version = 1,
    storeId = STORE_ID,
    loaded = false,
    sessionFallback = false,
    lastLoadError = nil,
    state = { topmost = {} },
}
RSUI.WindowPreferences = Store
Store.version = 1
Store.storeId = STORE_ID
RSUI.WindowPreferencePersistenceContractVersion = 1
RSUI.WindowLayerPreferenceContractVersion = 1

-- 置顶按逻辑窗口 ID 存独立 Account/Permanent 表，只存 true，缺省表示 normal。
-- 放入各 Feature 的 widgetWindow 会改变冻结 canonical，触发旧档指纹问题。
-- 先 SetUILayer 再保存，失败由调用方回滚 Native；读档受保护时可用 normal，但不能覆盖故障存档。
local function NormalizeState(value)
    value = type(value) == "table" and value or {}
    local source = type(value.topmost) == "table" and value.topmost or {}
    local keys = {}
    for key, enabled in pairs(source) do
        key = tostring(key or "")
        if enabled == true and key ~= "" and #key <= 180 then keys[#keys + 1] = key end
    end
    table.sort(keys)
    local out = {}
    for index = 1, math.min(#keys, MAX_WINDOWS) do out[keys[index]] = true end
    local normalized = { topmost = out }
    -- 会话设置窗只保存小锁，不提升几何为业务存档；空锁表省略，旧 schema1 canonical 完全不变。
    local lockedKeys = {}
    for key, enabled in pairs(type(value.locked) == "table" and value.locked or {}) do
        key = tostring(key or "")
        if enabled == true and key ~= "" and #key <= 180 then lockedKeys[#lockedKeys + 1] = key end
    end
    table.sort(lockedKeys)
    if #lockedKeys > 0 then
        normalized.locked = {}
        for index = 1, math.min(#lockedKeys, MAX_WINDOWS) do normalized.locked[lockedKeys[index]] = true end
    end
    return normalized
end

local function ApplyState(value)
    Store.state = NormalizeState(value)
end

if P:GetStore(STORE_ID) == nil then
    local registered, registerErr = P:RegisterV3Store({
        id = STORE_ID,
        owner = "v3.rsui.window_preferences",
        scope = P.Scope and P.Scope.Account or "account",
        lifetime = P.Lifetime and P.Lifetime.Permanent or "permanent",
        schemaVersion = 1,
        legacySchemaVersion = 0,
        key = P.V3KeyPrefix and (P.V3KeyPrefix .. "rsui_window_preferences") or STORE_ID,
        budget = { maxDepth = 4, maxNodes = 440, maxStringBytes = 12000, maxEntriesPerTable = 210 },
        default = function() return NormalizeState(nil) end,
        get = function() return NormalizeState(Store.state) end,
        apply = ApplyState,
    })
    if registered == nil and S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Error) == "function" then
        S.DiagnosticsManager:Error("rsui", "WINDOW_PREFERENCE_STORE_REGISTER_FAILED", "窗口层级偏好存档注册失败", {
            error = tostring(registerErr or "unknown"),
        })
    end
end

function Store:EnsureLoaded()
    if self.loaded == true then return true, self.lastLoadError end
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
    self.loaded, self.sessionFallback, self.lastLoadError = true, true, tostring(err or status or "load_failed")
    ApplyState(nil)
    if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Warn) == "function" then
        S.DiagnosticsManager:Warn("rsui", "WINDOW_PREFERENCE_SESSION_FALLBACK",
            "窗口层级偏好读取失败；本次会话使用非置顶默认且不会覆盖原存档", { error = self.lastLoadError })
    end
    return true, self.lastLoadError
end

function Store:GetTopmost(windowId)
    self:EnsureLoaded()
    local key = tostring(windowId or "")
    if key == "" then return false end
    return self.state ~= nil and self.state.topmost ~= nil and self.state.topmost[key] == true
end

function Store:SetTopmost(windowId, value, persist)
    self:EnsureLoaded()
    local key = tostring(windowId or "")
    if key == "" or #key > 180 then return false, "invalid_window_preference_key" end
    local nextValue = value == true
    self.state = NormalizeState(self.state)
    local previous = self.state.topmost[key] == true
    if previous == nextValue then return true, nextValue, false end

    -- 置顶与小锁共用 Persistence 事务；拒写/静默丢写时须恢复 Domain 和 dirty 元数据，
    -- MarkDirty(0)+普通 SaveStore 只有原生返回成功，既不能证明读回一致，也会残留拒绝动作的重试。
    local function Mutate()
        if nextValue then self.state.topmost[key] = true else self.state.topmost[key] = nil end
        return true
    end
    if persist == false then Mutate(); return true, nextValue, true end
    if self.sessionFallback == true then
        -- 隔离/损坏载荷不能覆盖；可仅会话改变 Native 层级，但应报告持久化不可用，不能宣称重登保留。
        Mutate(); return true, nextValue, true, "session_fallback_no_persist"
    end

    local saved, saveErr = P:MutateStore(STORE_ID, Mutate, { durable = true, reason = "window_topmost:" .. key })
    if saved ~= true then return false, saveErr or "window_preference_save_failed" end
    return true, nextValue, true
end

function Store:Describe(windowId)
    return {
        version = self.version,
        id = tostring(windowId or ""),
        topmost = self:GetTopmost(windowId),
        loaded = self.loaded == true,
        sessionFallback = self.sessionFallback == true,
        lastLoadError = self.lastLoadError,
    }
end

function Store:GetLocked(windowId)
    self:EnsureLoaded()
    return self.state and self.state.locked and self.state.locked[tostring(windowId or "")] == true or false
end

function Store:SetLocked(windowId, value, persist)
    -- 仅显式声明 persistSessionLock 的窗口使用此 Authority；Feature HUD 继续由自身 widgetWindow 保存锁。
    self:EnsureLoaded()
    local key, nextValue = tostring(windowId or ""), value == true
    if key == "" or #key > 180 then return false, "invalid_window_preference_key" end
    if self:GetLocked(key) == nextValue then return true, nextValue, false end
    local function Mutate()
        self.state = NormalizeState(self.state)
        self.state.locked = self.state.locked or {}
        self.state.locked[key] = nextValue and true or nil
        if next(self.state.locked) == nil then self.state.locked = nil end
        return true
    end
    if persist == false or self.sessionFallback == true then
        Mutate(); return true, nextValue, true, self.sessionFallback and "session_fallback_no_persist" or nil
    end
    local ok, err = P:MutateStore(STORE_ID, Mutate, { durable = true, reason = "window_lock:" .. key })
    if ok ~= true then return false, err end
    return true, nextValue, true
end

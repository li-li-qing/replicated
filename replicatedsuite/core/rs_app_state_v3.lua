------------------------------------------------------------------------
-- Replicated Suite · 应用状态
-- 作者：Replicated
-- QQ群：1104129461
--
-- 应用状态只保存应用自身的小量状态；功能和业务状态归拥有它的 Feature，并通过自身 V3 Store 持久化。本文件作
-- 为 Foundation 依赖，不承担旧单体 Suite State 的领域职责。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local P = S.Persistence
if type(P) ~= "table" or type(P.RegisterV3Store) ~= "function" then return end

S.AppState = {
    version = 2,
    loaded = false,
    sessionFallback = false,
    lastLoadError = nil,
    settings = {
        addonScale = 1.0,
        fontScale = 1.0,
        appearance = "dark",
    },
}
local A = S.AppState

local function Clamp(value, minimum, maximum, fallback)
    local n = tonumber(value) or tonumber(fallback) or minimum
    return math.max(minimum, math.min(maximum, n))
end

local function Normalize(value)
    value = type(value) == "table" and value or {}
    local appearance = tostring(value.appearance or "dark"):lower()
    if appearance ~= "dark" then appearance = "dark" end
    return {
        addonScale = Clamp(value.addonScale, 0.75, 1.25, 1.0),
        fontScale = Clamp(value.fontScale, 0.75, 1.50, 1.0),
        appearance = appearance,
    }
end

local function Apply(value)
    local v = Normalize(value)
    A.settings.addonScale = v.addonScale
    A.settings.fontScale = v.fontScale
    A.settings.appearance = v.appearance
end

local STORE_ID = "v3.app"
if P:GetStore(STORE_ID) == nil then
    local store, err = P:RegisterV3Store({
        id = STORE_ID,
        owner = "v3.app",
        scope = P.Scope.Account,
        lifetime = P.Lifetime.Permanent,
        schemaVersion = 1,
        legacySchemaVersion = 0,
        key = P.V3KeyPrefix .. "app",
        budget = { maxDepth = 4, maxNodes = 48, maxStringBytes = 1024, maxEntriesPerTable = 24 },
        default = function() return Normalize(nil) end,
        get = function() return Normalize(A.settings) end,
        apply = Apply,
    })
    if store == nil and S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Error) == "function" then
        S.DiagnosticsManager:Error("app_v3", "APP_STORE_REGISTER_FAILED", "V3 App Store 注册失败", { error = tostring(err) })
    end
end

A.storeId = STORE_ID

function A:UseSessionDefaults(reason)
    Apply(nil)
    self.loaded = true
    self.sessionFallback = true
    self.lastLoadError = tostring(reason or "v3 app store load failed")
    if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Warn) == "function" then
        S.DiagnosticsManager:Warn("app_v3", "APP_STORE_SESSION_FALLBACK",
            "V3 App Store 读取失败；本次会话使用安全默认设置，原存档不会因降级启动被主动覆盖",
            { error = self.lastLoadError })
    end
    return true
end

function A:EnsureLoaded()
    if self.loaded == true then return true end
    local store = P:GetStore(STORE_ID)
    if store == nil then return self:UseSessionDefaults("v3 app store unavailable") end
    local status, _, err = P:LoadStore(STORE_ID)
    if status == true or status == "empty" then
        if status == "empty" then Apply(nil) end
        self.loaded = true
        self.sessionFallback = false
        self.lastLoadError = nil
        return true
    end
    return self:UseSessionDefaults(err or tostring(status or "load failed"))
end

function A:GetSettings()
    return self.settings
end

function A:Set(key, value, persist)
    key = tostring(key or "")
    local function ApplyMutation()
        if key == "addonScale" then self.settings.addonScale = Clamp(value, 0.75, 1.25, 1.0)
        elseif key == "fontScale" then self.settings.fontScale = Clamp(value, 0.75, 1.50, 1.0)
        elseif key == "appearance" then self.settings.appearance = "dark"
        else return false, "unknown app setting" end
        return true
    end
    if persist == false then return ApplyMutation() end
    -- 启动兜底仅为会话安全状态；当前会话可继续操作设置，但不能向已隔离或尚未加载的物理 Store 写入。
    if self.sessionFallback == true then return ApplyMutation() end
    if type(P.MutateStore) ~= "function" then return false, "persistence transaction unavailable" end
    -- persist=false 专供预览；显式应用缩放/字体后必须在返回前写盘回读，避免用户立即退出时丢失设置。
    local ok, err = P:MutateStore(STORE_ID, ApplyMutation, { durable = true, reason = "app_setting:" .. key })
    if ok ~= true then return false, err or "v3 app setting transaction failed" end
    return true
end

function A:Describe()
    return {
        version = self.version,
        loaded = self.loaded == true,
        sessionFallback = self.sessionFallback == true,
        lastLoadError = self.lastLoadError,
        storeId = self.storeId,
        addonScale = self.settings.addonScale,
        fontScale = self.settings.fontScale,
        appearance = self.settings.appearance,
    }
end

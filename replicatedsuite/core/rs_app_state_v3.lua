------------------------------------------------------------------------
-- Replicated Suite V3 - Application State
--
-- Small application-owned state only. Feature/business state must live in the
-- Feature that owns it and persist through its own V3 Store. This file replaces
-- the legacy monolithic Suite State as an active Foundation dependency.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local P = S.Persistence
if type(P) ~= "table" or type(P.RegisterV3Store) ~= "function" then return end

S.AppState = {
    version = 1,
    loaded = false,
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

function A:EnsureLoaded()
    if self.loaded == true then return true end
    local store = P:GetStore(STORE_ID)
    if store == nil then return false, "v3 app store unavailable" end
    local status, _, err = P:LoadStore(STORE_ID)
    if status == true or status == "empty" then
        if status == "empty" then Apply(nil) end
        self.loaded = true
        return true
    end
    return false, err or tostring(status or "load failed")
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
    if type(P.MutateStore) ~= "function" then return false, "persistence transaction unavailable" end
    local ok, err = P:MutateStore(STORE_ID, ApplyMutation, { delayMs = 500, reason = "app_setting:" .. key })
    if ok ~= true then return false, err or "v3 app setting transaction failed" end
    return true
end

function A:Describe()
    return {
        version = self.version,
        loaded = self.loaded == true,
        storeId = self.storeId,
        addonScale = self.settings.addonScale,
        fontScale = self.settings.fontScale,
        appearance = self.settings.appearance,
    }
end

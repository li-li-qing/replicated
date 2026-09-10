------------------------------------------------------------------------
-- Replicated Suite V3 - Auxiliary Floating Window Store
--
-- Presentation-only persistence for movable auxiliary surfaces that do not own
-- business data.  The Store is registered at startup but loaded lazily on the
-- first auxiliary-window open, so a hidden detail/diagnostics surface has zero
-- SaveData read cost.  Feature/Service Authorities remain unchanged.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local P = S.Persistence
local Floating = S.RSUI and S.RSUI.FloatingSurface or nil
if type(P) ~= "table" or type(P.RegisterV3Store) ~= "function" or type(Floating) ~= "table" then return end

S.UIV3 = S.UIV3 or {}
local V3 = S.UIV3
local STORE_ID = "v3.presentation.aux_windows"
local SCHEMA = 1

-- 中文维护注释：只有真实可拖动/缩放、且没有自己 Feature Store 的辅助窗进入此表。
-- 不允许业务字段加入这里，否则会形成 Presentation 与 Feature 的双 Authority。
local POLICIES = {
    trade_detail = {
        defaultWidth = 620, defaultHeight = 440, minWidth = 470, minHeight = 300,
        defaultOverallOpacity = 0.96, defaultBackgroundOpacity = 1.0, defaultTextOpacity = 1.0,
        defaultFontScale = 1.0, minFontScale = 0.80, maxFontScale = 1.25,
    },
    trade_diagnostics = {
        defaultWidth = 700, defaultHeight = 520, minWidth = 520, minHeight = 340,
        defaultOverallOpacity = 0.96, defaultBackgroundOpacity = 1.0, defaultTextOpacity = 1.0,
        defaultFontScale = 1.0, minFontScale = 0.80, maxFontScale = 1.25,
    },
    quest_detail = {
        defaultWidth = 560, defaultHeight = 420, minWidth = 420, minHeight = 260,
        defaultOverallOpacity = 0.96, defaultBackgroundOpacity = 1.0, defaultTextOpacity = 1.0,
        defaultFontScale = 1.0, minFontScale = 0.80, maxFontScale = 1.25,
    },
}

local function Copy(value)
    if S.Utils ~= nil and type(S.Utils.DeepCopy) == "function" then return S.Utils.DeepCopy(value) end
    if type(value) ~= "table" then return value end
    local out = {}
    for key, item in pairs(value) do out[key] = Copy(item) end
    return out
end

local function NormalizeWindow(id, value)
    local policy = POLICIES[tostring(id or "")]
    if policy == nil then return nil end
    return Floating:NormalizeState(value, policy)
end

local function NormalizeState(value)
    value = type(value) == "table" and value or {}
    local out = {}
    for id in pairs(POLICIES) do out[id] = NormalizeWindow(id, value[id]) end
    return out
end

V3.AuxWindowStoreV3 = type(V3.AuxWindowStoreV3) == "table" and V3.AuxWindowStoreV3 or {
    version = 1,
    contractVersion = 1,
    storeId = STORE_ID,
    loaded = false,
    state = NormalizeState(nil),
}
local A = V3.AuxWindowStoreV3
A.version = 1
A.contractVersion = 1
A.storeId = STORE_ID
A.policies = POLICIES

local function Apply(value)
    A.state = NormalizeState(value)
end

if P:GetStore(STORE_ID) == nil then
    local store, err = P:RegisterV3Store({
        id = STORE_ID,
        owner = "v3.presentation.aux_windows",
        scope = P.Scope.Account,
        lifetime = P.Lifetime.Permanent,
        schemaVersion = SCHEMA,
        legacySchemaVersion = 0,
        key = P.V3KeyPrefix .. "presentation_aux_windows",
        budget = { maxDepth = 6, maxNodes = 320, maxStringBytes = 4096, maxEntriesPerTable = 64 },
        default = function() return NormalizeState(nil) end,
        get = function() return NormalizeState(A.state) end,
        apply = Apply,
        migrate = function(value) return NormalizeState(value) end,
    })
    if store == nil and S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Error) == "function" then
        S.DiagnosticsManager:Error("ui_v3", "AUX_WINDOW_STORE_REGISTER_FAILED",
            "辅助悬浮窗布局存档注册失败", { error = tostring(err or "unknown") })
    end
end

function A:EnsureLoaded()
    if self.loaded == true and type(P.IsStoreLoaded) == "function" and P:IsStoreLoaded(STORE_ID) == true then return true end
    local status, _, err = P:LoadStore(STORE_ID)
    if status ~= true and status ~= "empty" then return false, err or tostring(status or "辅助窗口布局读取失败") end
    if status == "empty" then Apply(nil) end
    self.loaded = true
    return true
end

function A:GetPolicy(id)
    return Copy(POLICIES[tostring(id or "")])
end

function A:GetWindowState(id)
    id = tostring(id or "")
    if POLICIES[id] == nil then return nil, "unknown auxiliary window: " .. id end
    local ok, err = self:EnsureLoaded()
    if ok ~= true then return nil, err end
    return Copy(NormalizeWindow(id, self.state[id]))
end

function A:SetWindowState(id, value, reason)
    id = tostring(id or "")
    if POLICIES[id] == nil then return false, "unknown auxiliary window: " .. id end
    local ok, err = self:EnsureLoaded()
    if ok ~= true then return false, err end
    -- 中文维护注释：FloatingSurface 先 Commit state、再调用 Persist；这里只更新
    -- Presentation Domain，不直接 SaveData。若后续 MarkDirty 失败，Floating transaction
    -- 会把 before-state 回滚回来，因此不会出现“视觉位置已变、Store Authority 未提交”。
    self.state[id] = NormalizeWindow(id, value)
    return true
end

function A:PersistWindow(id, reason, delayMs)
    id = tostring(id or "")
    if POLICIES[id] == nil then return false, "unknown auxiliary window: " .. id end
    local ok, err = self:EnsureLoaded()
    if ok ~= true then return false, err end
    return P:MarkDirty(STORE_ID, tonumber(delayMs) or 250,
        "aux_window:" .. id .. ":" .. tostring(reason or "state"))
end

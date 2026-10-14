------------------------------------------------------------------------
-- Replicated Suite · 伤害与治疗统计设置存储
-- 作者：Replicated
-- QQ群：1104129461
--
-- 账号永久存储仅保存 DPS 设置、手工首领名、FloatingSurface 窗口状态和用户 HUD 可见偏好；战斗统计按原有行为仅驻会话内存。
-- 持久化必须走 S.Persistence，Feature/Domain 禁止直接调用 LoadData/SaveData/ClearData。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local P = S.Persistence
if type(P) ~= "table" or type(P.RegisterV3Store) ~= "function" then return end

S.Features = S.Features or {}
S.Features.DPS = S.Features.DPS or {}
local F = S.Features.DPS
local U = S.Utils

local STORE_ID = "v3.dps"
local SCHEMA = 4
local MAX_BOSS_NAMES = 64
local MAX_DISPLAY_ROWS = 150

-- DPS Window policy 必须只有一个 Authority。过去 Feature 使用
-- 470x330/min1，而 Floating Widget 使用 560x410/min430x250，Reload 后同一存档
-- 会被两个 canonicalizer 反复解释，表现为尺寸/位置恢复后再次跳回。Store 暴露
-- 只读 policy 给 Feature/Presentation 共用；这里不持久化 policy 本身。
F.WidgetWindowPolicy = {
    defaultWidth = 560, defaultHeight = 410, minWidth = 430, minHeight = 250,
    defaultOverallOpacity = 0.96, defaultBackgroundOpacity = 1.0, defaultTextOpacity = 1.0,
    defaultFontScale = 1.0, minFontScale = 0.80, maxFontScale = 1.25,
}

local function DeepCopy(value)
    if U ~= nil and type(U.DeepCopy) == "function" then return U.DeepCopy(value) end
    return value
end

local function ClampInt(value, minimum, maximum, fallback)
    local n = math.floor(tonumber(value) or tonumber(fallback) or minimum)
    if n < minimum then n = minimum end
    if n > maximum then n = maximum end
    return n
end

local function NormalizeMode(value)
    value = tostring(value or "PVE")
    if value ~= "PVP" and value ~= "PVE" then return "PVE" end
    return value
end

local function NormalizeSide(value)
    value = tostring(value or "friendly")
    if value ~= "friendly" and value ~= "enemy" then return "friendly" end
    return value
end

local function NormalizeMetric(value)
    value = tostring(value or "damage")
    if value ~= "damage" and value ~= "taken" and value ~= "heal" then return "damage" end
    return value
end

local function NormalizeName(value)
    value = tostring(value or ""):match("^%s*(.-)%s*$") or ""
    return value
end

local function NormalizeSettings(value)
    value = type(value) == "table" and value or {}
    return {
        mode = NormalizeMode(value.mode),
        side = NormalizeSide(value.side),
        metric = NormalizeMetric(value.metric),
        displayRows = ClampInt(value.displayRows, 1, MAX_DISPLAY_ROWS, 12),
        alwaysShowSelf = value.alwaysShowSelf ~= false,
    }
end

local function NormalizeState(value)
    value = type(value) == "table" and value or {}
    local bossNames, seen = {}, {}
    local src = type(value.bossNames) == "table" and value.bossNames or {}
    for index = 1, math.min(#src, MAX_BOSS_NAMES) do
        local name = NormalizeName(src[index])
        local key = string.lower(name)
        if name ~= "" and seen[key] ~= true and #bossNames < MAX_BOSS_NAMES then
            seen[key] = true
            bossNames[#bossNames + 1] = name
        end
    end
    return {
        settings = NormalizeSettings(value.settings),
        bossNames = bossNames,
        -- 可见性是持久表现偏好，不由 DPS Feature 启用状态隐含决定。schema≤3 缺此字段，升级默认隐藏，避免每次重载自动打开。
        widgetVisible = value.widgetVisible == true,
        -- 嵌套具体 schema 归 FloatingSurface；本处保持不透明，确保窗口几何、锁定、最小化和透明度经 Store 归一化及未来迁移仍保留。
        widgetWindow = type(value.widgetWindow) == "table" and DeepCopy(value.widgetWindow) or {},
    }
end

F.StoreId = STORE_ID
F.State = NormalizeState(F.State)
F.StoreLoaded = F.StoreLoaded == true

local function ApplyState(value) F.State = NormalizeState(value) end

if P:GetStore(STORE_ID) == nil then
    local store, err = P:RegisterV3Store({
        id = STORE_ID,
        owner = "v3.dps",
        scope = P.Scope and P.Scope.Account or "account",
        lifetime = P.Lifetime and P.Lifetime.Permanent or "permanent",
        schemaVersion = SCHEMA,
        legacySchemaVersion = 0,
        key = P.V3KeyPrefix and (P.V3KeyPrefix .. "dps") or "v3.dps",
        budget = { maxDepth = 5, maxNodes = 600, maxStringBytes = 6000, maxEntriesPerTable = 64 },
        default = function() return NormalizeState(nil) end,
        get = function() return NormalizeState(F.State) end,
        apply = ApplyState,
        migrate = function(value) return NormalizeState(value) end,
    })
    if store == nil and S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Error) == "function" then
        S.DiagnosticsManager:Error("dps_v3", "DPS_STORE_REGISTER_FAILED", "DPS 设置存档注册失败", { error = tostring(err) })
    end
end

function F:GetSettings() return self.State.settings end

function F:ApplySettingRaw(key, value)
    local settings = self.State.settings
    key = tostring(key or "")
    if key == "mode" then settings.mode = NormalizeMode(value)
    elseif key == "side" then settings.side = NormalizeSide(value)
    elseif key == "metric" then settings.metric = NormalizeMetric(value)
    elseif key == "displayRows" then settings.displayRows = ClampInt(value, 1, MAX_DISPLAY_ROWS, 12)
    elseif key == "alwaysShowSelf" then settings.alwaysShowSelf = value == true
    else return false, "unknown dps setting: " .. key end
    return true
end

function F:IsBossName(name)
    name = NormalizeName(name)
    if name == "" then return false end
    local key = string.lower(name)
    for _, row in ipairs(self.State.bossNames) do
        if string.lower(NormalizeName(row)) == key then return true end
    end
    return false
end

function F:GetBossNames() return DeepCopy(self.State.bossNames) end

function F:SetBossName(name)
    name = NormalizeName(name)
    if name == "" then return false, "boss name required" end
    local ok, err = P:MutateStore(STORE_ID, function()
        if self:IsBossName(name) == true then return true end
        if #self.State.bossNames >= MAX_BOSS_NAMES then return false, "boss name limit reached" end
        self.State.bossNames[#self.State.bossNames + 1] = name
        return true
    end, { durable = true, reason = "dps_boss_name" })
    return ok, err
end

function F:DeleteBossName(name)
    name = NormalizeName(name)
    return P:MutateStore(STORE_ID, function()
        local removed = false
        local nextNames = {}
        for _, row in ipairs(self.State.bossNames) do
            if row == name then removed = true else nextNames[#nextNames + 1] = row end
        end
        if removed == true then self.State.bossNames = nextNames end
        return true
    end, { durable = true, reason = "dps_boss_name_remove" })
end

function F:EnsureStoreLoaded()
    if type(P.IsStoreLoaded) == "function" and P:IsStoreLoaded(STORE_ID) == true then self.StoreLoaded = true; return true end
    local store = P:GetStore(STORE_ID)
    if store == nil then return false, "DPS 设置存档不可用" end
    local status, _, err = P:LoadStore(STORE_ID)
    if status ~= true and status ~= "empty" then return false, err or tostring(status or "读取失败") end
    if status == "empty" then ApplyState(nil) end
    self.StoreLoaded = true
    return true
end

function F:MarkStoreDirty(delayMs, reason)
    -- 拖动后立即重载不能只留下 dirty；失败交给 Floating 事务回滚。
    if reason == "widget_geometry" or reason == "widget_layout_reset" or reason == "widget_minimized" then
        return P:SaveStore(STORE_ID, { durable=true, consumeDirty=true, reason=reason })
    end
    return P:MarkDirty(STORE_ID, tonumber(delayMs) or 300, reason or "dps_changed")
end

function F:MutateStore(mutator, delayMs, reason, durable)
    return P:MutateStore(STORE_ID, function() return mutator() end, {
        delayMs = tonumber(delayMs) or 300, reason = tostring(reason or "dps_changed"), durable = durable == true,
    })
end

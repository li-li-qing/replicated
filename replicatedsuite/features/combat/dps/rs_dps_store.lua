------------------------------------------------------------------------
-- Replicated Suite V3 - DPS Store
--
-- Account-scoped permanent storage for DPS settings, manual Boss names, the
-- FloatingSurface window state, and the user-controlled HUD visibility preference. No combat statistics are persisted here: the live meter is session-only
-- by design, exactly like the legacy behaviour evidence (the old Professional
-- DPS kept its running totals in memory and only persisted user preferences).
--
-- Persistence boundary is S.Persistence only; the Feature/Domain never call
-- LoadData/SaveData/ClearData directly.
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
        -- Visibility is a durable presentation preference, not an implication of
        -- the DPS Feature enable state.  Schema <=3 stores do not contain this
        -- field and therefore migrate fail-closed to hidden instead of reopening
        -- the meter after every reload.
        widgetVisible = value.widgetVisible == true,
        -- FloatingSurface owns the concrete schema below this table. Keep the
        -- state opaque here so window geometry/lock/minimize/opacity survives
        -- store normalization and future FloatingSurface migrations.
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
    return P:MarkDirty(STORE_ID, tonumber(delayMs) or 300, reason or "dps_changed")
end

function F:MutateStore(mutator, delayMs, reason, durable)
    return P:MutateStore(STORE_ID, function() return mutator() end, {
        delayMs = tonumber(delayMs) or 300, reason = tostring(reason or "dps_changed"), durable = durable == true,
    })
end

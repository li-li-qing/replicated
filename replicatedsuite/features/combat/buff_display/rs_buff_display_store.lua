------------------------------------------------------------------------
-- Replicated Suite V3 - Buff Display Settings Store (schema 4)
--
-- Permanent display policy only. Aura facts stay session data owned by
-- AuraObservationV3; FeatureRuntime owns enabled/disabled state.
--
-- Schema 4 highlights (vs schema 3):
--   * tracked ids are category-keyed: tracked = { buff = {...}, debuff = {...} }
--   * hidden is a detection source, not a user category; user overrides live
--     in classification = { [id] = "buff"|"debuff" }
--   * 10 head components (buffs/debuffs/distance/class/gearScore/mainHand/
--     offHand/ranged/wings/castBar) each with enabled/x/y/size/fontSize/alpha
--   * refreshMs / headRefreshMs floors lowered to 1 ms (never clamped up)
-- Migration from schema 1/2/3 is lossless: every previously tracked id is
-- distributed into a category bucket via the shared classification service.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local P = S.Persistence
if type(P) ~= "table" or type(P.RegisterV3Store) ~= "function" then return end

S.Features = S.Features or {}
S.Features.BuffDisplay = S.Features.BuffDisplay or {}
local F = S.Features.BuffDisplay
local U = S.Utils
local STORE_ID = "v3.buff_display"
local SCHEMA = 4

local function Copy(value)
    if U ~= nil and type(U.DeepCopy) == "function" then return U.DeepCopy(value) end
    if type(value) ~= "table" then return value end
    local out = {}
    for key, item in pairs(value) do out[key] = Copy(item) end
    return out
end

local function ClampInt(value, minimum, maximum, fallback)
    local n = math.floor(tonumber(value) or tonumber(fallback) or minimum)
    if n < minimum then n = minimum end
    if n > maximum then n = maximum end
    return n
end

local function ClampFloat(value, minimum, maximum, fallback)
    local n = tonumber(value) or tonumber(fallback) or minimum
    if n < minimum then n = minimum end
    if n > maximum then n = maximum end
    return n
end

local Floating = S.RSUI and S.RSUI.FloatingSurface or nil
if type(Floating) ~= "table" or type(Floating.NormalizeState) ~= "function" then error("FloatingSurface unavailable for BuffDisplay store") end

local COMPONENT_KEYS = { "buffs", "debuffs", "distance", "class", "gearScore", "mainHand", "offHand", "ranged", "wings", "castBar" }
local COMPONENT_DEFAULTS = {
    buffs     = { enabled = true,  x = 0,   y = -54,  size = 24, fontSize = 9,  alpha = 1.0 },
    debuffs   = { enabled = true,  x = 0,   y = -84,  size = 24, fontSize = 9,  alpha = 1.0 },
    distance  = { enabled = true,  x = 0,   y = -108, size = 0,  fontSize = 10, alpha = 1.0 },
    class     = { enabled = true,  x = 0,   y = -122, size = 0,  fontSize = 10, alpha = 1.0 },
    gearScore = { enabled = true,  x = 0,   y = -136, size = 0,  fontSize = 10, alpha = 1.0 },
    mainHand  = { enabled = true,  x = -22, y = -156, size = 18, fontSize = 0,  alpha = 1.0 },
    offHand   = { enabled = true,  x = 0,   y = -156, size = 18, fontSize = 0,  alpha = 1.0 },
    ranged    = { enabled = true,  x = 22,  y = -156, size = 18, fontSize = 0,  alpha = 1.0 },
    wings     = { enabled = true,  x = 0,   y = -178, size = 18, fontSize = 0,  alpha = 1.0 },
    castBar   = { enabled = true,  x = 0,   y = -40,  size = 6,  fontSize = 10, alpha = 1.0 },
}

local function NormalizeTrackedIds(value)
    local out, seen = {}, {}
    for _, raw in ipairs(type(value) == "table" and value or {}) do
        local id = math.floor(tonumber(raw) or 0)
        if id > 0 and seen[id] ~= true and #out < 32 then
            seen[id] = true
            out[#out + 1] = id
        end
    end
    table.sort(out)
    return out
end

local function NormalizeWindow(value)
    return Floating:NormalizeState(value, {
        defaultWidth = 430, defaultHeight = 300, minWidth = 180, minHeight = 100,
        defaultOverallOpacity = 0.94, defaultBackgroundOpacity = 1.0, defaultTextOpacity = 1.0,
    })
end

local function NormalizeComponent(value, defaults)
    value = type(value) == "table" and value or {}
    return {
        enabled = value.enabled ~= false,
        x = ClampInt(value.x, -400, 400, defaults.x),
        y = ClampInt(value.y, -400, 400, defaults.y),
        size = ClampInt(value.size, 0, 64, defaults.size),
        fontSize = ClampInt(value.fontSize, 0, 32, defaults.fontSize),
        alpha = ClampFloat(value.alpha, 0.1, 1.0, defaults.alpha),
    }
end

local function NormalizeComponents(value)
    value = type(value) == "table" and value or {}
    local out = {}
    for _, key in ipairs(COMPONENT_KEYS) do out[key] = NormalizeComponent(value[key], COMPONENT_DEFAULTS[key]) end
    return out
end

local function NormalizeClassification(value)
    local out = {}
    if type(value) == "table" then
        for id, category in pairs(value) do
            local numeric = math.floor(tonumber(id) or 0)
            if numeric > 0 and (category == "buff" or category == "debuff") then out[numeric] = category end
        end
    end
    return out
end

local function NormalizeSettings(value)
    value = type(value) == "table" and value or {}
    local tracked = type(value.tracked) == "table" and value.tracked or {}
    return {
        showBuffs = value.showBuffs ~= false,
        showDebuffs = value.showDebuffs ~= false,
        showHidden = value.showHidden == true,
        playerRows = ClampInt(value.playerRows, 1, 64, 24),
        targetRows = ClampInt(value.targetRows, 1, 64, 24),
        refreshMs = ClampInt(value.refreshMs, 1, 2000, 400),
        components = NormalizeComponents(value.components),
        tracked = {
            buff = NormalizeTrackedIds(tracked.buff),
            debuff = NormalizeTrackedIds(tracked.debuff),
        },
        classification = NormalizeClassification(value.classification),
        headEnabled = value.headEnabled ~= false,
        headShowAll = value.headShowAll ~= false,
        headPlayer = value.headPlayer ~= false,
        headTarget = value.headTarget ~= false,
        headIconSize = ClampInt(value.headIconSize, 8, 64, 24),
        headMaxIcons = ClampInt(value.headMaxIcons, 1, 12, 8),
        headOffsetY = ClampInt(value.headOffsetY, -400, 400, -54),
        headRefreshMs = ClampInt(value.headRefreshMs, 1, 2000, 100),
        headShowStacks = value.headShowStacks ~= false,
        headShowTime = value.headShowTime ~= false,
    }
end

local function NormalizeState(value)
    value = type(value) == "table" and value or {}
    return {
        settings = NormalizeSettings(value.settings),
        widgetWindow = NormalizeWindow(value.widgetWindow),
        widgetVisible = value.widgetVisible == true,
    }
end

-- Lossless schema < 4 -> 4 migration. Persistence calls migrate(raw, from, to)
-- and write-fences on failure, so a failed migration never loses the raw data.
local function MigrateState(value, fromSchema)
    value = type(value) == "table" and value or {}
    local settings = type(value.settings) == "table" and value.settings or {}
    local out = NormalizeState(value)

    -- 1) Distribute legacy flat tracked ids into category buckets. Unknown ids
    --    are classified by the shared service (default buff) so no id is lost.
    --    Schema 3 kept the ids as a flat array (settings.tracked = { 101, ... })
    --    while schema 4 buckets them by category; accept the trackedIds field,
    --    a top-level trackedIds, AND the flat-array shape so no id is lost.
    local legacyIds = settings.trackedIds
    if type(legacyIds) ~= "table" then legacyIds = value.trackedIds end
    if type(legacyIds) ~= "table" then
        for _, candidate in ipairs({ settings.tracked, value.tracked }) do
            if type(candidate) == "table" and candidate.buff == nil and candidate.debuff == nil then
                legacyIds = candidate
                break
            end
        end
    end
    if type(legacyIds) == "table" and #legacyIds > 0 then
        local classification = S.Services and S.Services.StatusClassificationV3 or nil
        local buffList, debuffList, seen = {}, {}, {}
        for _, raw in ipairs(legacyIds) do
            local id = math.floor(tonumber(raw) or 0)
            if id > 0 and seen[id] ~= true and #buffList + #debuffList < 64 then
                seen[id] = true
                local category = "buff"
                if classification ~= nil and type(classification.ClassifyId) == "function" then
                    local kind = classification:ClassifyId(id, out.settings.classification)
                    if kind ~= nil and kind.category ~= nil then category = kind.category end
                end
                if category == "debuff" then debuffList[#debuffList + 1] = id else buffList[#buffList + 1] = id end
            end
        end
        out.settings.tracked.buff, out.settings.tracked.debuff = buffList, debuffList
    end

    -- 2) Mirror legacy head fields into the buffs component only when the old
    --    state carried no components (schema 1/2/3).
    if type(settings.components) ~= "table" and type(value.components) ~= "table" then
        local buffs = out.settings.components.buffs
        local offset = ClampInt(settings.headOffsetY, -400, 400, -54)
        local iconSize = ClampInt(settings.headIconSize, 8, 64, 24)
        buffs.x, buffs.y, buffs.size = 0, offset, iconSize
        buffs.fontSize = math.max(6, math.floor(iconSize * 0.38))
        out.settings.components.debuffs.y = offset - 30
    end
    return out
end

F.StoreId, F.SchemaVersion = STORE_ID, SCHEMA
F.State = NormalizeState(F.State)
F.StoreLoaded = F.StoreLoaded == true

local function ApplyState(value) F.State = NormalizeState(value) end
if P:GetStore(STORE_ID) == nil then
    local store, err = P:RegisterV3Store({
        id = STORE_ID, owner = "v3.buff_display", scope = P.Scope and P.Scope.Account or "account",
        lifetime = P.Lifetime and P.Lifetime.Permanent or "permanent", schemaVersion = SCHEMA,
        legacySchemaVersion = 1, key = P.V3KeyPrefix and (P.V3KeyPrefix .. "buff_display") or STORE_ID,
        budget = { maxDepth = 5, maxNodes = 320, maxStringBytes = 1400, maxEntriesPerTable = 96 },
        default = function() return NormalizeState(nil) end,
        get = function() return NormalizeState(F.State) end,
        apply = ApplyState,
        migrate = function(value, fromSchema) return MigrateState(value, fromSchema) end,
    })
    if store == nil and S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Error) == "function" then
        S.DiagnosticsManager:Error("buff_display_v3", "BUFF_DISPLAY_STORE_REGISTER_FAILED", "状态显示设置存档注册失败", { error = tostring(err) })
    end
end

function F:GetSettings() return self.State.settings end
function F:EnsureStoreLoaded()
    if self.StoreLoaded == true then return true end
    local store = P:GetStore(STORE_ID)
    if store == nil then return false, "状态显示设置存档不可用" end
    local status, _, err = P:LoadStore(STORE_ID)
    if status ~= true and status ~= "empty" then return false, err or tostring(status or "读取失败") end
    if status == "empty" then ApplyState(nil) end
    self.StoreLoaded = true
    return true
end

function F:MarkStoreDirty(delayMs, reason)
    -- Every settings mutation persists through this path, so it is the single
    -- invalidation hook for the feature's detached settings-snapshot cache.
    if type(F.InvalidateSettingsCache) == "function" then F:InvalidateSettingsCache() end
    return P:MarkDirty(STORE_ID, tonumber(delayMs) or 300, reason or "buff_display_changed")
end

function F:GetComponent(key)
    key = tostring(key or "")
    return self.State.settings.components[key] or nil
end

function F:GetTracked(category)
    local tracked = self.State.settings.tracked or {}
    if category == "debuff" then return Copy(tracked.debuff or {}) end
    return Copy(tracked.buff or {})
end

function F:GetClassification() return Copy(self.State.settings.classification or {}) end

-- category: "buff" | "debuff" | nil (nil => classify via shared service)
function F:IsTrackedId(id, category)
    id = math.floor(tonumber(id) or 0)
    if id <= 0 then return false end
    local tracked = self.State.settings.tracked or {}
    if category == nil or category == "debuff" then
        for _, trackedId in ipairs(tracked.debuff or {}) do if trackedId == id then return true end end
    end
    if category == nil or category == "buff" then
        for _, trackedId in ipairs(tracked.buff or {}) do if trackedId == id then return true end end
    end
    return false
end

function F:SetTrackedId(id, category, enabled)
    id = math.floor(tonumber(id) or 0)
    if id <= 0 then return false, "Buff ID 无效" end
    local settings = self.State.settings
    if category ~= "buff" and category ~= "debuff" then
        local classification = S.Services and S.Services.StatusClassificationV3 or nil
        category = "buff"
        if classification ~= nil and type(classification.ClassifyId) == "function" then
            local kind = classification:ClassifyId(id, settings.classification)
            if kind ~= nil and kind.category == "debuff" then category = "debuff" end
        end
    end
    local before = Copy(self.State)
    local list, found = NormalizeTrackedIds(settings.tracked[category]), false
    for _, tracked in ipairs(list) do if tracked == id then found = true break end end
    if enabled == true and not found then
        if #list >= 32 then return false, "最多追踪 32 个状态" end
        list[#list + 1] = id
        table.sort(list)
    elseif enabled ~= true and found then
        local nextList = {}
        for _, tracked in ipairs(list) do if tracked ~= id then nextList[#nextList + 1] = tracked end end
        list = nextList
    else
        return true
    end
    settings.tracked[category] = list
    local marked, markErr = self:MarkStoreDirty(200, "tracked_" .. category .. "_" .. tostring(id))
    if marked ~= true then self.State = before; return false, markErr or "追踪状态保存失败" end
    if S.Events ~= nil and type(S.Events.Publish) == "function" then S.Events:Publish("v3.buff_display.settings", "tracked") end
    return true
end

function F:ClearTrackedIds(category)
    local before = Copy(self.State)
    local settings = self.State.settings
    if category == "buff" then settings.tracked.buff = {}
    elseif category == "debuff" then settings.tracked.debuff = {}
    else settings.tracked = { buff = {}, debuff = {} } end
    local marked, markErr = self:MarkStoreDirty(200, "tracked_clear")
    if marked ~= true then self.State = before; return false, markErr or "清空追踪状态保存失败" end
    if S.Events ~= nil and type(S.Events.Publish) == "function" then S.Events:Publish("v3.buff_display.settings", "tracked") end
    return true
end

function F:SetComponentField(componentKey, field, value)
    componentKey, field = tostring(componentKey or ""), tostring(field or "")
    local component = self.State.settings.components[componentKey]
    if component == nil then return false, "未知显示组件：" .. tostring(componentKey) end
    local defaults = COMPONENT_DEFAULTS[componentKey]
    local before = Copy(self.State.settings)
    if field == "enabled" then component.enabled = value == true
    elseif field == "x" then component.x = ClampInt(value, -400, 400, defaults.x)
    elseif field == "y" then component.y = ClampInt(value, -400, 400, defaults.y)
    elseif field == "size" then component.size = ClampInt(value, 0, 64, defaults.size)
    elseif field == "fontSize" then component.fontSize = ClampInt(value, 0, 32, defaults.fontSize)
    elseif field == "alpha" then component.alpha = ClampFloat(value, 0.1, 1.0, defaults.alpha)
    else return false, "未知组件字段：" .. tostring(field) end
    local marked, markErr = self:MarkStoreDirty(250, "component_" .. componentKey .. "_" .. field)
    if marked ~= true then self.State.settings = before; return false, markErr or "组件设置保存失败" end
    if S.Events ~= nil and type(S.Events.Publish) == "function" then S.Events:Publish("v3.buff_display.settings", "components") end
    return true
end

function F:SetClassification(id, category)
    id = math.floor(tonumber(id) or 0)
    if id <= 0 then return false, "Buff ID 无效" end
    if category ~= "buff" and category ~= "debuff" then return false, "分类必须是 buff 或 debuff" end
    local before = Copy(self.State.settings)
    local classification = self.State.settings.classification or {}
    classification[id] = category
    self.State.settings.classification = classification
    local marked, markErr = self:MarkStoreDirty(250, "classification_" .. tostring(id))
    if marked ~= true then self.State.settings = before; return false, markErr or "人工分类保存失败" end
    if S.Events ~= nil and type(S.Events.Publish) == "function" then S.Events:Publish("v3.buff_display.settings", "classification") end
    return true
end

function F:ClearClassification(id)
    id = math.floor(tonumber(id) or 0)
    if id <= 0 then return false, "Buff ID 无效" end
    local before = Copy(self.State.settings)
    local classification = self.State.settings.classification or {}
    classification[id] = nil
    self.State.settings.classification = classification
    local marked, markErr = self:MarkStoreDirty(250, "classification_clear_" .. tostring(id))
    if marked ~= true then self.State.settings = before; return false, markErr or "人工分类清除保存失败" end
    if S.Events ~= nil and type(S.Events.Publish) == "function" then S.Events:Publish("v3.buff_display.settings", "classification") end
    return true
end

function F:ApplySettingRaw(key, value)
    local settings = self.State.settings
    key = tostring(key or "")
    if key == "showBuffs" then settings.showBuffs = value == true
    elseif key == "showDebuffs" then settings.showDebuffs = value == true
    elseif key == "showHidden" then settings.showHidden = value == true
    elseif key == "playerRows" then settings.playerRows = ClampInt(value, 1, 64, settings.playerRows)
    elseif key == "targetRows" then settings.targetRows = ClampInt(value, 1, 64, settings.targetRows)
    elseif key == "refreshMs" then settings.refreshMs = ClampInt(value, 1, 2000, settings.refreshMs)
    elseif key == "headEnabled" then settings.headEnabled = value == true
    elseif key == "headPlayer" then settings.headPlayer = value == true
    elseif key == "headTarget" then settings.headTarget = value == true
    elseif key == "headIconSize" then
        -- Proxy write: the "图标大小" slider is the global size for the buffs/
        -- debuffs icon rows; the head renderer only reads components.*.size.
        settings.headIconSize = ClampInt(value, 8, 64, settings.headIconSize)
        if settings.components.buffs then settings.components.buffs.size = settings.headIconSize end
        if settings.components.debuffs then settings.components.debuffs.size = settings.headIconSize end
    elseif key == "headMaxIcons" then settings.headMaxIcons = ClampInt(value, 1, 12, settings.headMaxIcons)
    elseif key == "headOffsetY" then
        -- Proxy write: the "上下位置" slider moves the buffs row and keeps the
        -- debuffs row 30px above it (same delta the schema 1/2/3 migration used).
        settings.headOffsetY = ClampInt(value, -400, 400, settings.headOffsetY)
        if settings.components.buffs then settings.components.buffs.y = settings.headOffsetY end
        if settings.components.debuffs then settings.components.debuffs.y = settings.headOffsetY - 30 end
    elseif key == "headRefreshMs" then settings.headRefreshMs = ClampInt(value, 1, 2000, settings.headRefreshMs)
    elseif key == "headShowStacks" then settings.headShowStacks = value == true
    elseif key == "headShowTime" then settings.headShowTime = value == true
    elseif string.sub(key, 1, 11) == "components." then
        local rest = string.sub(key, 12)
        local dot = string.find(rest, ".", 1, true)
        if dot == nil then return false, "组件字段格式无效：" .. tostring(key) end
        return self:SetComponentField(string.sub(rest, 1, dot - 1), string.sub(rest, dot + 1), value)
    else return false, "unknown buff display setting: " .. key end
    return true
end

function F:ApplySettingFromBinding(key, value)
    local ok, err = self:ApplySettingRaw(key, value)
    if ok ~= true then return false, err end
    if S.Events ~= nil and type(S.Events.Publish) == "function" then S.Events:Publish("v3.buff_display.settings", tostring(key or "")) end
    return true
end

function F:SetSettingValue(key, value)
    local before = Copy(self.State.settings)
    local ok, err = self:ApplySettingRaw(key, value)
    if ok ~= true then return false, err end
    local marked, markErr = self:MarkStoreDirty(300, "setting_" .. tostring(key))
    if marked ~= true then self.State.settings = before; return false, markErr or "状态显示设置保存失败" end
    if S.Events ~= nil and type(S.Events.Publish) == "function" then S.Events:Publish("v3.buff_display.settings", tostring(key or "")) end
    return true
end

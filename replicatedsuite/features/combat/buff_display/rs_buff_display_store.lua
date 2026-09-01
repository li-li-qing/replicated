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
--   * headShowAll is explicit opt-in; fresh/default config remains tracked-only
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
-- Layout preset version. Schema 4 (tracked buckets / classification) is
-- unchanged; layout geometry evolves through this preset counter, NOT schema.
--   v1 -> v2 : compact one-row equipment preset (M1.16.0.18.50)
--   v2 -> v3 : health-bar anchor layout (this round). Absolute component y
--              values are no longer screen offsets — they become local
--              anchor-relative fine-tune offsets. Defaults collapse to 0.
local LAYOUT_PRESET_VERSION = 3

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

-- Exact M1.16.0.18.50 defaults are kept only as a compatibility fingerprint.
-- A saved component is moved to the compact v2 preset only when its geometry
-- still matches this fingerprint. Any user-adjusted position/size/font/alpha is
-- left untouched, so an upgrade cannot overwrite a deliberate HUD layout.
local LEGACY_COMPONENT_DEFAULTS = {
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

-- Anchor-relative compact preset (v3). Every x/y is now a LOCAL fine-tune
-- offset relative to the health-bar proxy rectangle, NOT a screen coordinate.
-- Default 0 for all: the layout function places buffs above the bar, debuffs
-- below, equipment flanks, info on top. `enabled` is the only meaningful
-- default divergence (ranged OFF by default; wings ON as the right-side slot).
-- Default sizes are 1.2× the original v3 baseline (24→29 icons, 22→26 equip).
local COMPONENT_DEFAULTS = {
    buffs     = { enabled = true,  x = 0, y = 0, size = 29, fontSize = 11, alpha = 1.0, spacing = 2, maxPerRow = 8, maxRows = 2 },
    debuffs   = { enabled = true,  x = 0, y = 0, size = 29, fontSize = 11, alpha = 1.0, spacing = 2, maxPerRow = 8, maxRows = 2 },
    distance  = { enabled = true,  x = 0, y = 0, size = 0,  fontSize = 12, alpha = 1.0 },
    class     = { enabled = true,  x = 0, y = 0, size = 0,  fontSize = 12, alpha = 1.0 },
    gearScore = { enabled = true,  x = 0, y = 0, size = 0,  fontSize = 12, alpha = 1.0 },
    mainHand  = { enabled = true,  x = 0, y = 0, size = 26, fontSize = 0,  alpha = 1.0 },
    offHand   = { enabled = true,  x = 0, y = 0, size = 26, fontSize = 0,  alpha = 1.0 },
    ranged    = { enabled = true,  x = 0, y = 0, size = 26, fontSize = 0,  alpha = 1.0 },
    wings     = { enabled = true,  x = 0, y = 0, size = 26, fontSize = 0,  alpha = 1.0 },
    castBar   = { enabled = true,  x = 0, y = 0, size = 7,  fontSize = 12, alpha = 1.0 },
}

-- The "broken anchor layout" preset shipped on GitHub main: these absolute y/x
-- values were the v2 defaults. A saved component matching this fingerprint is
-- migrated to the v3 anchor-relative 0/0 defaults; a user-adjusted value is
-- left untouched (the renderer now treats x/y as local offsets).
local BROKEN_COMPONENT_DEFAULTS = {
    buffs     = { enabled = true,  x = 0,   y = -108, size = 24, fontSize = 9,  alpha = 1.0 },
    debuffs   = { enabled = true,  x = 0,   y = -136, size = 24, fontSize = 9,  alpha = 1.0 },
    distance  = { enabled = true,  x = -62, y = -82,  size = 0,  fontSize = 10, alpha = 1.0 },
    class     = { enabled = true,  x = 0,   y = -94,  size = 0,  fontSize = 10, alpha = 1.0 },
    gearScore = { enabled = true,  x = 62,  y = -82,  size = 0,  fontSize = 10, alpha = 1.0 },
    mainHand  = { enabled = true,  x = -36, y = -58,  size = 22, fontSize = 0,  alpha = 1.0 },
    offHand   = { enabled = true,  x = -12, y = -58,  size = 22, fontSize = 0,  alpha = 1.0 },
    ranged    = { enabled = true,  x = 12,  y = -58,  size = 22, fontSize = 0,  alpha = 1.0 },
    wings     = { enabled = true,  x = 36,  y = -58,  size = 22, fontSize = 0,  alpha = 1.0 },
    castBar   = { enabled = true,  x = 0,   y = -34,  size = 6,  fontSize = 10, alpha = 1.0 },
}

local function NormalizeTrackedIds(value)
    -- 1024/category: this function runs on EVERY load and save, so its cap is
    -- the effective tracked-list size. The old hard cap of 32 silently
    -- truncated any larger list (legacy schema 1-3 saves carry hundreds of
    -- ids — one live save held 713) on the first save after load: the user's
    -- additions vanished on every reload. 1024 stays inside the store's
    -- SaveData budget (maxEntriesPerTable = 2048).
    local out, seen = {}, {}
    for _, raw in ipairs(type(value) == "table" and value or {}) do
        local id = math.floor(tonumber(raw) or 0)
        if id > 0 and seen[id] ~= true and #out < 1024 then
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
        -- CastBar-only extras (ignored by other components). width is the bar
        -- length in px; showText toggles the spell-name label under the bar.
        width = ClampInt(value.width, 20, 480, defaults.width or 120),
        showText = value.showText ~= false,
        -- Row layout extras for buff/debuff rows (ignored elsewhere).
        spacing = ClampInt(value.spacing, 0, 24, defaults.spacing or 2),
        maxPerRow = ClampInt(value.maxPerRow, 1, 16, defaults.maxPerRow or 8),
        maxRows = ClampInt(value.maxRows, 1, 4, defaults.maxRows or 2),
    }
end

local function SameLegacyGeometry(component, legacy)
    if type(component) ~= "table" or type(legacy) ~= "table" then return false end
    return component.x == legacy.x and component.y == legacy.y
        and component.size == legacy.size and component.fontSize == legacy.fontSize
        and math.abs((tonumber(component.alpha) or 1) - (tonumber(legacy.alpha) or 1)) < 0.0001
end

local function NormalizeComponents(value, presetVersion)
    value = type(value) == "table" and value or {}
    presetVersion = math.floor(tonumber(presetVersion) or 0)
    local out = {}
    for _, key in ipairs(COMPONENT_KEYS) do
        local source = value[key]
        local fresh = NormalizeComponent(nil, COMPONENT_DEFAULTS[key])
        if presetVersion >= LAYOUT_PRESET_VERSION then
            -- Already on the anchor-relative preset: normalize as-is.
            out[key] = NormalizeComponent(source, COMPONENT_DEFAULTS[key])
        elseif type(source) ~= "table" then
            -- No saved value: use the new anchor-relative default.
            out[key] = fresh
        else
            -- Three-generation migration. Only a component whose geometry still
            -- EXACTLY matches a known old default (legacy v1 or broken v2) is
            -- moved to the v3 default; any user-adjusted value is preserved and
            -- simply re-interpreted as a local offset.
            local asLegacy = NormalizeComponent(source, LEGACY_COMPONENT_DEFAULTS[key])
            local asBroken = NormalizeComponent(source, BROKEN_COMPONENT_DEFAULTS[key])
            local enabled = source.enabled ~= false
            if SameLegacyGeometry(asLegacy, LEGACY_COMPONENT_DEFAULTS[key])
                or SameLegacyGeometry(asBroken, BROKEN_COMPONENT_DEFAULTS[key]) then
                local migrated = NormalizeComponent(COMPONENT_DEFAULTS[key], COMPONENT_DEFAULTS[key])
                migrated.enabled = enabled
                out[key] = migrated
            else
                -- User-customized: keep their values; only fill the new fields
                -- (spacing/maxPerRow/maxRows) from the v3 default when absent.
                local kept = NormalizeComponent(source, COMPONENT_DEFAULTS[key])
                kept.enabled = enabled
                out[key] = kept
            end
        end
    end
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
    local layoutPresetVersion = math.floor(tonumber(value.layoutPresetVersion) or 0)
    local headOffsetY = ClampInt(value.headOffsetY, -400, 400, COMPONENT_DEFAULTS.buffs.y)
    if layoutPresetVersion < LAYOUT_PRESET_VERSION then
        local legacyHeadOffset = tonumber(value.headOffsetY)
        if legacyHeadOffset == nil or math.floor(legacyHeadOffset) == LEGACY_COMPONENT_DEFAULTS.buffs.y then
            headOffsetY = COMPONENT_DEFAULTS.buffs.y
        end
    end
    -- NativeBarProxy: the RU API exposes no native unit-frame rectangle, so the
    -- anchor is the unit screen projection point + a calibratable offset that
    -- the player aligns onto the game's own health bar. This proxy is used ONLY
    -- for layout geometry (left/right/top/bottom/center) — nothing is drawn.
    local plate = type(value.plate) == "table" and value.plate or {}
    local info = type(value.info) == "table" and value.info or {}
    -- y=0 centers the proxy on the unit projection point by default; the
    -- calibrate mode / plate.y slider lets the player land it on the native bar.
    -- headOffsetY is legacy-only and never feeds the anchor chain.
    -- Default plate.y = 22 (up 4px from the original 26 to better align with
    -- the native health bar after the 1.5× size increase).
    if plate.y == nil and value.plate == nil then
        plate.y = 22
    end
    return {
        showBuffs = value.showBuffs ~= false,
        showDebuffs = value.showDebuffs ~= false,
        showHidden = value.showHidden == true,
        -- freezeEnabled: keep every tracked row in the list even after its aura
        -- expires/disappears (Legacy Plates freeze semantics). The Feature keeps
        -- a session frozen-row snapshot while this is on.
        freezeEnabled = value.freezeEnabled == true,
        playerRows = ClampInt(value.playerRows, 1, 64, 24),
        targetRows = ClampInt(value.targetRows, 1, 64, 24),
        -- Old-default fingerprint migration (2026-09-01 cadence fix): 400/100
        -- were the only defaults these settings ever had before 120/50, so a
        -- stored copy of those exact values was written by the old default —
        -- not by a user choice. Upgraded saves must follow the faster cadence
        -- or they keep the slow refresh forever (defaults changes don't reach
        -- existing saves). User-tuned values (anything else) are preserved.
        refreshMs = (tonumber(value.refreshMs) == 400) and 120
            or ClampInt(value.refreshMs, 1, 2000, 120),
        components = NormalizeComponents(value.components, layoutPresetVersion),
        layoutPresetVersion = LAYOUT_PRESET_VERSION,
        tracked = {
            buff = NormalizeTrackedIds(tracked.buff),
            debuff = NormalizeTrackedIds(tracked.debuff),
        },
        classification = NormalizeClassification(value.classification),
        headEnabled = value.headEnabled ~= false,
        headShowAll = value.headShowAll == true,
        headPlayer = value.headPlayer ~= false,
        headTarget = value.headTarget ~= false,
        headIconSize = ClampInt(value.headIconSize, 8, 64, 24),
        headMaxIcons = ClampInt(value.headMaxIcons, 1, 12, 8),
        headOffsetY = headOffsetY,
        headRefreshMs = (tonumber(value.headRefreshMs) == 100) and 50
            or ClampInt(value.headRefreshMs, 1, 2000, 50),
        headShowStacks = value.headShowStacks ~= false,
        headShowTime = value.headShowTime ~= false,
        -- Global plate scale multiplies every region (health bar, icons, text).
        plateScale = ClampFloat(value.plateScale, 0.5, 2.0, 1.0),
        -- NativeBarProxy anchor rect: aligned by the player onto the native bar
        -- via x/y/width/height. Not drawn; used only for layout. enabled/
        -- opacity/showName kept for backward compatibility, ignored by renderer.
        plate = {
            enabled = plate.enabled ~= false,
            width = ClampInt(plate.width, 80, 320, 150),
            height = ClampInt(plate.height, 8, 40, 20),
            x = ClampInt(plate.x, -400, 400, 0),
            y = ClampInt(plate.y, -500, 500, 0),
            opacity = ClampFloat(plate.opacity, 0.2, 1.0, 0.85),
            showName = plate.showName ~= false,
        },
        -- Info row above buffs: class · gear score · distance (each toggleable).
        info = {
            enabled = info.enabled ~= false,
            x = ClampInt(info.x, -400, 400, 0),
            y = ClampInt(info.y, -120, 120, 0),
            fontSize = ClampInt(info.fontSize, 8, 24, 12),
            showClass = info.showClass ~= false,
            showGear = info.showGear ~= false,
            showDistance = info.showDistance ~= false,
        },
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
    --    state carried no components (schema 1/2/3). Keep the compact preset's
    --    relative spacing so an old headOffset still behaves as a row anchor.
    if type(settings.components) ~= "table" and type(value.components) ~= "table" then
        local buffs = out.settings.components.buffs
        local offset = ClampInt(settings.headOffsetY, -400, 400, COMPONENT_DEFAULTS.buffs.y)
        local iconSize = ClampInt(settings.headIconSize, 8, 64, 24)
        buffs.x, buffs.y, buffs.size = 0, offset, iconSize
        buffs.fontSize = math.max(6, math.floor(iconSize * 0.38))
        out.settings.components.debuffs.y = offset - 28
        out.settings.headOffsetY = offset
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
        -- Budget sized for REAL payloads (2026-09-01): legacy schema 1-3 saves
        -- can carry hundreds of tracked ids per category (one live save held
        -- 713). The old 192-entry / 2800-byte budget rejected every such save
        -- AND write-fenced the store for the whole session — nothing the user
        -- changed ever persisted again (edits, tracked toggles, resets).
        -- Encoded JSON for 713+713 ids plus settings is well under 16KB, which
        -- the client SaveData has always accepted (the legacy path saved it).
        budget = { maxDepth = 6, maxNodes = 32768, maxStringBytes = 65536, maxEntriesPerTable = 2048 },
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

-- Restore every display/layout setting to current defaults. The floating
-- window's visibility is preserved (a reset should not close the user's open
-- window); tracked ids and classification are intentionally included in the
-- reset scope — the page labels the button 恢复默认 and documents the sweep.
function F:ResetSettings()
    local keepVisible = self.State ~= nil and self.State.widgetVisible == true
    self.State = NormalizeState(nil)
    if keepVisible then self.State.widgetVisible = true end
    return true
end
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
        -- 1024/category, matching NormalizeTrackedIds (load/save) and
        -- ImportTrackedIds so every path agrees and nothing is silently lost.
        if #list >= 1024 then return false, "最多追踪 1024 个状态" end
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
    elseif field == "width" then component.width = ClampInt(value, 20, 480, defaults.width or 120)
    elseif field == "showText" then component.showText = value ~= false
    elseif field == "spacing" then component.spacing = ClampInt(value, 0, 24, defaults.spacing or 2)
    elseif field == "maxPerRow" then component.maxPerRow = ClampInt(value, 1, 16, defaults.maxPerRow or 8)
    elseif field == "maxRows" then component.maxRows = ClampInt(value, 1, 4, defaults.maxRows or 2)
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
    elseif key == "freezeEnabled" then settings.freezeEnabled = value == true
    elseif key == "playerRows" then settings.playerRows = ClampInt(value, 1, 64, settings.playerRows)
    elseif key == "targetRows" then settings.targetRows = ClampInt(value, 1, 64, settings.targetRows)
    elseif key == "refreshMs" then settings.refreshMs = ClampInt(value, 1, 2000, settings.refreshMs)
    elseif key == "headEnabled" then settings.headEnabled = value == true
    elseif key == "headShowAll" then settings.headShowAll = value == true
    elseif key == "headPlayer" then settings.headPlayer = value == true
    elseif key == "headTarget" then settings.headTarget = value == true
    elseif key == "headIconSize" then
        -- Proxy write: the "图标大小" slider is the global size for the buffs/
        -- debuffs icon rows; the head renderer only reads components.*.size.
        settings.headIconSize = ClampInt(value, 8, 64, settings.headIconSize)
        if settings.components.buffs then settings.components.buffs.size = settings.headIconSize end
        if settings.components.debuffs then settings.components.debuffs.size = settings.headIconSize end
    elseif key == "headMaxIcons" then
        -- Proxy write: per-row cap for buffs/debuffs (schema 5 row layout).
        settings.headMaxIcons = ClampInt(value, 1, 12, settings.headMaxIcons)
        if settings.components.buffs then settings.components.buffs.maxPerRow = settings.headMaxIcons end
        if settings.components.debuffs then settings.components.debuffs.maxPerRow = settings.headMaxIcons end
    elseif key == "headOffsetY" then
        -- Legacy compatibility only: this field no longer drives layout. The
        -- single anchor offset is plate.x/plate.y (NativeBarProxy). Kept so
        -- older saved values survive migration without re-entering runtime.
        settings.headOffsetY = ClampInt(value, -500, 500, settings.headOffsetY)
    elseif key == "headRefreshMs" then settings.headRefreshMs = ClampInt(value, 1, 2000, settings.headRefreshMs)
    elseif key == "headShowStacks" then settings.headShowStacks = value == true
    elseif key == "headShowTime" then settings.headShowTime = value == true
    elseif key == "plateScale" then settings.plateScale = ClampFloat(value, 0.5, 2.0, settings.plateScale)
    elseif string.sub(key, 1, 6) == "plate." then
        local field = string.sub(key, 7)
        local before = settings.plate
        if field == "enabled" then settings.plate.enabled = value == true
        elseif field == "width" then settings.plate.width = ClampInt(value, 80, 320, before.width)
        elseif field == "height" then settings.plate.height = ClampInt(value, 8, 40, before.height)
        elseif field == "x" then settings.plate.x = ClampInt(value, -400, 400, before.x)
        elseif field == "y" then settings.plate.y = ClampInt(value, -500, 500, before.y)
        elseif field == "opacity" then settings.plate.opacity = ClampFloat(value, 0.2, 1.0, before.opacity)
        elseif field == "showName" then settings.plate.showName = value == true
        else return false, "unknown plate field: " .. tostring(field) end
    elseif string.sub(key, 1, 5) == "info." then
        local field = string.sub(key, 6)
        local before = settings.info
        if field == "enabled" then settings.info.enabled = value == true
        elseif field == "x" then settings.info.x = ClampInt(value, -400, 400, before.x)
        elseif field == "y" then settings.info.y = ClampInt(value, -120, 120, before.y)
        elseif field == "fontSize" then settings.info.fontSize = ClampInt(value, 8, 24, before.fontSize)
        elseif field == "showClass" then settings.info.showClass = value == true
        elseif field == "showGear" then settings.info.showGear = value == true
        elseif field == "showDistance" then settings.info.showDistance = value == true
        else return false, "unknown info field: " .. tostring(field) end
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

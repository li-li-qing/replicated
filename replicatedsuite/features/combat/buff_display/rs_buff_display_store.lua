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
    ranged    = { enabled = false, x = 0, y = 0, size = 26, fontSize = 0,  alpha = 1.0 },
    wings     = { enabled = true,  x = 0, y = 0, size = 26, fontSize = 0,  alpha = 1.0 },
    castBar   = { enabled = true,  x = 0, y = 0, size = 7,  fontSize = 12, alpha = 1.0 },
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
    local enabled = defaults.enabled ~= false
    if value.enabled ~= nil then enabled = value.enabled == true end
    return {
        -- Missing fields inherit the component-specific default. This matters
        -- for opt-in components such as ranged; the old generic ~= false rule
        -- accidentally forced every missing component ON.
        enabled = enabled,
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

local function NormalizeComponents(value)
    value = type(value) == "table" and value or {}
    local out = {}
    for _, key in ipairs(COMPONENT_KEYS) do
        -- New-framework contract: stored values normalize against CURRENT
        -- defaults only (missing fields filled from defaults). No old-default
        -- fingerprint migration — the old plugin generation was kept as
        -- reference only and is never carried forward (2026-09-01 directive).
        out[key] = NormalizeComponent(value[key], COMPONENT_DEFAULTS[key])
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
    -- NativeBarProxy: the RU API exposes no native unit-frame rectangle, so the
    -- anchor is the unit screen projection point + a calibratable offset that
    -- the player aligns onto the game's own health bar. This proxy is used ONLY
    -- for layout geometry (left/right/top/bottom/center) — nothing is drawn.
    local plate = type(value.plate) == "table" and value.plate or {}
    local info = type(value.info) == "table" and value.info or {}
    -- Compatibility-only bridge for schema-4 saves written before .18.79.
    -- headIconSize/headMaxIcons used to be duplicate writable authorities for
    -- buffs/debuffs. Fold them into the canonical component fields only when
    -- those component fields are absent; normalized state no longer retains the
    -- aliases, so every live consumer has one field authority.
    local rawComponents = Copy(type(value.components) == "table" and value.components or {})
    local legacyIconSize = tonumber(value.headIconSize)
    local legacyMaxIcons = tonumber(value.headMaxIcons)
    if legacyIconSize ~= nil then
        rawComponents.buffs = type(rawComponents.buffs) == "table" and rawComponents.buffs or {}
        rawComponents.debuffs = type(rawComponents.debuffs) == "table" and rawComponents.debuffs or {}
        if rawComponents.buffs.size == nil then rawComponents.buffs.size = legacyIconSize end
        if rawComponents.debuffs.size == nil then rawComponents.debuffs.size = legacyIconSize end
    end
    if legacyMaxIcons ~= nil then
        rawComponents.buffs = type(rawComponents.buffs) == "table" and rawComponents.buffs or {}
        rawComponents.debuffs = type(rawComponents.debuffs) == "table" and rawComponents.debuffs or {}
        if rawComponents.buffs.maxPerRow == nil then rawComponents.buffs.maxPerRow = legacyMaxIcons end
        if rawComponents.debuffs.maxPerRow == nil then rawComponents.debuffs.maxPerRow = legacyMaxIcons end
    end
    -- y=0 centers the proxy on the unit projection point by default; the
    -- calibrate mode / plate.y slider lets the player land it on the native bar.
    -- Default plate.y = 22 (up 4px from the original 26 to better align with
    -- the native health bar after the 1.2× size increase).
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
        components = NormalizeComponents(rawComponents),
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
            if id > 0 and seen[id] ~= true and #buffList + #debuffList < 1024 then
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
    return out
end

F.StoreId, F.SchemaVersion = STORE_ID, SCHEMA
F.LayoutAuthorityContractVersion = 2
F.LayoutPersistenceBoundaryContractVersion = 1
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
function F:GetDefaultSettingsSnapshot() return Copy(NormalizeSettings(nil)) end

-- HUD layout persistence boundary ------------------------------------------------
--
-- The page editor owns an isolated Working snapshot.  Preview/Undo/Redo/Reset
-- never mutate F.State, because F.State is the registered Persistence getter and
-- may be flushed for an unrelated dirty setting at any time.  Only Apply crosses
-- this boundary through PersistLayoutSnapshot(), which writes the full Store
-- synchronously and rolls the in-memory layout back if the durable write fails.
-- This prevents an un-applied editor preview from leaking into the next reload.
local LAYOUT_SETTING_KEYS = {
    "layoutPresetVersion", "headEnabled", "headShowAll", "headPlayer", "headTarget",
    "headRefreshMs", "headShowStacks", "headShowTime", "plateScale",
}

local function NormalizeLayoutSnapshot(value)
    value = type(value) == "table" and value or {}
    local defaults = NormalizeSettings(nil)
    local plate = type(value.plate) == "table" and value.plate or {}
    local info = type(value.info) == "table" and value.info or {}
    return {
        layoutPresetVersion = LAYOUT_PRESET_VERSION,
        headEnabled = value.headEnabled ~= false,
        headShowAll = value.headShowAll == true,
        headPlayer = value.headPlayer ~= false,
        headTarget = value.headTarget ~= false,
        -- Do NOT reuse NormalizeSettings' historical 100->50 fingerprint here:
        -- LayoutEditor snapshots are already schema-4 values, not legacy input.
        headRefreshMs = ClampInt(value.headRefreshMs, 1, 2000, defaults.headRefreshMs),
        headShowStacks = value.headShowStacks ~= false,
        headShowTime = value.headShowTime ~= false,
        plateScale = ClampFloat(value.plateScale, 0.5, 2.0, defaults.plateScale),
        plate = {
            enabled = plate.enabled ~= false,
            width = ClampInt(plate.width, 80, 320, defaults.plate.width),
            height = ClampInt(plate.height, 8, 40, defaults.plate.height),
            x = ClampInt(plate.x, -400, 400, defaults.plate.x),
            y = ClampInt(plate.y, -500, 500, defaults.plate.y),
            opacity = ClampFloat(plate.opacity, 0.2, 1.0, defaults.plate.opacity),
            showName = plate.showName ~= false,
        },
        info = {
            enabled = info.enabled ~= false,
            x = ClampInt(info.x, -400, 400, defaults.info.x),
            y = ClampInt(info.y, -120, 120, defaults.info.y),
            fontSize = ClampInt(info.fontSize, 8, 24, defaults.info.fontSize),
            showClass = info.showClass ~= false,
            showGear = info.showGear ~= false,
            showDistance = info.showDistance ~= false,
        },
        components = NormalizeComponents(value.components),
    }
end

local function LayoutSnapshotFromSettings(settings)
    return Copy(NormalizeLayoutSnapshot(settings))
end

local function ApplyLayoutSnapshotToSettings(settings, snapshot)
    local normalized = NormalizeLayoutSnapshot(snapshot)
    for _, key in ipairs(LAYOUT_SETTING_KEYS) do settings[key] = Copy(normalized[key]) end
    settings.plate = Copy(normalized.plate)
    settings.info = Copy(normalized.info)
    settings.components = Copy(normalized.components)
    return normalized
end

function F:GetLayoutSettingsSnapshot()
    return LayoutSnapshotFromSettings(self.State.settings)
end

function F:GetDefaultLayoutSettingsSnapshot()
    return LayoutSnapshotFromSettings(NormalizeSettings(nil))
end

function F:CanPersistLayoutSettings()
    local loaded, loadErr = self:EnsureStoreLoaded()
    if loaded ~= true then return false, loadErr or "状态显示设置尚未读取" end
    return P:CanWrite(STORE_ID)
end

function F:PersistLayoutSettingsSnapshot(snapshot, reason)
    -- Apply is the only LayoutEditor command allowed to cross the durable
    -- boundary. Persistence v2 owns preflight, snapshot and rollback atomically.
    local saved, saveErr = self:MutateStore(function()
        ApplyLayoutSnapshotToSettings(self.State.settings, snapshot)
        return true
    end, 0, tostring(reason or "buff_display_layout_apply"), true)
    if saved ~= true then return false, saveErr or "HUD 布局持久化失败" end

    if type(F.ReconcileLanes) == "function" then F:ReconcileLanes() end
    if type(F.RefreshScope) == "function" then
        F:RefreshScope("player")
        F:RefreshScope("target")
    end
    if S.Events ~= nil and type(S.Events.Publish) == "function" then
        S.Events:Publish("v3.buff_display.settings", "layout_apply")
    end
    return true, nil
end

-- Layout Reset is intentionally narrow. It restores HUD presentation defaults
-- while preserving tracking-manager state, classification overrides, browser
-- filters/row counts, floating-window state, and feature lifecycle preference.
-- A destructive factory reset belongs to the future global settings surface.
function F:ResetLayoutSettings()
    local settings = self.State.settings
    local defaults = NormalizeSettings(nil)
    local before = Copy(settings)

    settings.components = Copy(defaults.components)
    settings.layoutPresetVersion = defaults.layoutPresetVersion
    settings.headEnabled = defaults.headEnabled
    settings.headShowAll = defaults.headShowAll
    settings.headPlayer = defaults.headPlayer
    settings.headTarget = defaults.headTarget
    settings.headRefreshMs = defaults.headRefreshMs
    settings.headShowStacks = defaults.headShowStacks
    settings.headShowTime = defaults.headShowTime
    settings.plateScale = defaults.plateScale
    settings.plate = Copy(defaults.plate)
    settings.info = Copy(defaults.info)
    return true, before
end

-- Compatibility alias for any old caller. Since .18.79 this is deliberately
-- NON-destructive and has the same scoped semantics as Layout Reset.
function F:ResetSettings()
    return self:ResetLayoutSettings()
end
function F:EnsureStoreLoaded()
    local loaded = type(P.IsStoreLoaded) == "function" and select(1, P:IsStoreLoaded(STORE_ID)) == true
    if loaded == true then self.StoreLoaded = true; return true end
    local store = P:GetStore(STORE_ID)
    if store == nil then return false, "状态显示设置存档不可用" end
    local status, _, err = P:LoadStore(STORE_ID)
    if status ~= true and status ~= "empty" then return false, err or tostring(status or "读取失败") end
    if status == "empty" then ApplyState(nil) end
    self.StoreLoaded = true
    return true
end

function F:MarkStoreDirty(delayMs, reason)
    -- Compatibility entry for callers whose Domain mutation is already guarded
    -- by a PersistentBinding/FloatingSurface preflight. New public business
    -- mutations should use MutateStore() so rollback is owned by Persistence v2.
    if type(F.InvalidateSettingsCache) == "function" then F:InvalidateSettingsCache() end
    return P:MarkDirty(STORE_ID, tonumber(delayMs) or 300, reason or "buff_display_changed")
end

function F:MutateStore(mutator, delayMs, reason, durable)
    if type(P.MutateStore) ~= "function" then return false, "Persistence mutation transaction unavailable" end
    local ok, err, extra = P:MutateStore(STORE_ID, function()
        return mutator()
    end, { delayMs = tonumber(delayMs) or 300, reason = reason or "buff_display_changed", durable = durable == true })
    -- Whether the transaction committed or rolled back, any detached settings
    -- projection may now reference an old table generation. Rebuild lazily.
    if type(F.InvalidateSettingsCache) == "function" then F:InvalidateSettingsCache() end
    return ok, err, extra
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
    local list, found = NormalizeTrackedIds(settings.tracked[category]), false
    for _, tracked in ipairs(list) do if tracked == id then found = true break end end
    if enabled == true and found then return true end
    if enabled ~= true and not found then return true end
    if enabled == true and #list >= 1024 then return false, "最多追踪 1024 个状态" end
    local marked, markErr = self:MutateStore(function()
        local current = self.State.settings
        local nextList = NormalizeTrackedIds(current.tracked[category])
        if enabled == true then
            local exists = false
            for _, tracked in ipairs(nextList) do if tracked == id then exists = true break end end
            if not exists then nextList[#nextList + 1] = id; table.sort(nextList) end
        else
            local filtered = {}
            for _, tracked in ipairs(nextList) do if tracked ~= id then filtered[#filtered + 1] = tracked end end
            nextList = filtered
        end
        current.tracked[category] = nextList
        return true
    end, 200, "tracked_" .. category .. "_" .. tostring(id))
    if marked ~= true then return false, markErr or "追踪状态保存失败" end
    if S.Events ~= nil and type(S.Events.Publish) == "function" then S.Events:Publish("v3.buff_display.settings", "tracked") end
    return true
end

function F:ClearTrackedIds(category)
    local marked, markErr = self:MutateStore(function()
        local settings = self.State.settings
        if category == "buff" then settings.tracked.buff = {}
        elseif category == "debuff" then settings.tracked.debuff = {}
        else settings.tracked = { buff = {}, debuff = {} } end
        return true
    end, 200, "tracked_clear")
    if marked ~= true then return false, markErr or "清空追踪状态保存失败" end
    if S.Events ~= nil and type(S.Events.Publish) == "function" then S.Events:Publish("v3.buff_display.settings", "tracked") end
    return true
end

function F:ApplyComponentFieldRaw(componentKey, field, value)
    componentKey, field = tostring(componentKey or ""), tostring(field or "")
    local component = self.State.settings.components[componentKey]
    if component == nil then return false, "未知显示组件：" .. tostring(componentKey) end
    local defaults = COMPONENT_DEFAULTS[componentKey]
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
    return true
end

function F:SetComponentField(componentKey, field, value)
    componentKey, field = tostring(componentKey or ""), tostring(field or "")
    local marked, markErr = self:MutateStore(function()
        return self:ApplyComponentFieldRaw(componentKey, field, value)
    end, 250, "component_" .. componentKey .. "_" .. field)
    if marked ~= true then return false, markErr or "组件设置保存失败" end
    if S.Events ~= nil and type(S.Events.Publish) == "function" then S.Events:Publish("v3.buff_display.settings", "components") end
    return true
end

function F:SetClassification(id, category)
    id = math.floor(tonumber(id) or 0)
    if id <= 0 then return false, "Buff ID 无效" end
    if category ~= "buff" and category ~= "debuff" then return false, "分类必须是 buff 或 debuff" end
    local marked, markErr = self:MutateStore(function()
        local classification = self.State.settings.classification or {}
        classification[id] = category
        self.State.settings.classification = classification
        return true
    end, 250, "classification_" .. tostring(id))
    if marked ~= true then return false, markErr or "人工分类保存失败" end
    if S.Events ~= nil and type(S.Events.Publish) == "function" then S.Events:Publish("v3.buff_display.settings", "classification") end
    return true
end

function F:ClearClassification(id)
    id = math.floor(tonumber(id) or 0)
    if id <= 0 then return false, "Buff ID 无效" end
    local marked, markErr = self:MutateStore(function()
        local classification = self.State.settings.classification or {}
        classification[id] = nil
        self.State.settings.classification = classification
        return true
    end, 250, "classification_clear_" .. tostring(id))
    if marked ~= true then return false, markErr or "人工分类清除保存失败" end
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
        return self:ApplyComponentFieldRaw(string.sub(rest, 1, dot - 1), string.sub(rest, dot + 1), value)
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
    local marked, markErr = self:MutateStore(function()
        return self:ApplySettingRaw(key, value)
    end, 300, "setting_" .. tostring(key))
    if marked ~= true then return false, markErr or "状态显示设置保存失败" end
    if S.Events ~= nil and type(S.Events.Publish) == "function" then S.Events:Publish("v3.buff_display.settings", tostring(key or "")) end
    return true
end

------------------------------------------------------------------------
-- Replicated Suite V3 - Buff Display Settings Store (schema 8)
--
-- Permanent display policy only. Aura facts stay session data owned by
-- AuraObservationV3; FeatureRuntime owns enabled/disabled state.
--
-- Schema 5 highlights (vs schema 4):
--   * player HUD remains on the historical flat layout fields for upgrade compatibility
--   * targetLayout is a second, independently persisted visual HUD profile
--   * schema-4 single-HUD saves are integrity-rebuilt with the exact old canonicalizer,
--     then migrated to schema 5 and immediately restamped; no user layout is discarded
--
-- Schema 4 compatibility carried forward:
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
local HUD_LAYOUT_STORE_ID = "v3.buff_display.layout"
local HUD_LAYOUT_STORE_SCHEMA = 1
local SETTINGS_STORE_ID = "v3.buff_display.settings"
local TRACKING_MANIFEST_STORE_ID = "v3.buff_display.tracking.manifest"
local TRACKING_STORE_PREFIX = "v3.buff_display.tracking."
local TRACKING_SLOTS = { "a", "b" }
local TRACKING_PARTS = { "player", "target", "meta" }
local SETTINGS_STORE_SCHEMA = 1
local TRACKING_STORE_SCHEMA = 1
local TRACKING_MANIFEST_SCHEMA = 1
-- 中文维护注释：结构新增必须升级 schema；旧 canonical 在下方以词法隔离冻结，不能冒用 schema5。
local SCHEMA = 8
-- Layout preset version. Schema 4 introduced tracked buckets/classification; schema 5 only
-- adds the second persisted HUD profile. Geometry presets still evolve through this counter,
-- while persistent STRUCTURE changes must increment SCHEMA.
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

-- 中文维护注释（发行版目标 HUD 装备模板，2026-09-11）：
-- 问题背景：维护者通过 HUD_TEMPLATE_V1 在实机完成目标装备区域校准，需要把这组结果
-- 固化为“新用户/恢复默认”的 target 默认模板，而不是覆盖已有用户保存的 targetLayout。
-- Authority/数据流：这些值只参与 fresh NormalizeSettings(nil) 与 ResetLayoutSettings 的默认
-- profile 构建；已有 schema5 targetLayout 仍是用户 Store Authority，schema4/缺 targetLayout 的
-- 老用户仍按兼容规则复制现有 player profile，绝不因为版本更新被强制换成发行模板。
-- 兼容边界：本次用户只提供 TARGET|EQUIP，因此只固化主手/副手/远程/背部；Buff、信息、
-- 施法条等目标默认继续继承 player defaults，禁止猜测未提供的模板行。
-- 实现理由：单独维护目标 equipment overlay，避免复制整套 COMPONENT_DEFAULTS 后未来字段漂移。
-- 后续维护：收到其余 HUD_TEMPLATE_V1 行时按同样的“只覆盖已确认字段”方式扩展模板。
local TARGET_EQUIPMENT_TEMPLATE = {
    mainHand = { enabled = true, x = -32, y = 0, size = 22, alpha = 1.0 },
    offHand  = { enabled = true, x = -33, y = 0, size = 22, alpha = 1.0 },
    ranged   = { enabled = true, x = 39,  y = 0, size = 22, alpha = 1.0 },
    wings    = { enabled = true, x = 0,   y = 0, size = 22, alpha = 1.0 },
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

-- 中文维护注释（HUD 双配置 Authority，2026-09-11）：
-- 问题原因：旧版只有 settings.plate/info/components/plateScale 一套几何 Authority，
-- 自身与目标 HUD 被迫共享布局；校准目标时会同时改动自身，无法满足 PVP 双 HUD。
-- Authority/数据流：Store 继续以旧字段作为 player Authority，新增 targetLayout 只负责 target
-- 的视觉几何；Feature/Presentation 只能通过 GetScopeLayoutSettings/GetHudCalibrationSnapshot
-- 读取 detached snapshot，禁止直接持有或修改 F.State。
-- 兼容边界：这一段是 schema5 引入双 HUD 时冻结下来的 profile 几何语义；当前 Store 已升级到
-- schema7，但 schema4/5/6 的 historical canonical 仍必须按当时规则验真。旧 schema4 存档不存在
-- targetLayout 时，完整性证明通过后由迁移路径复制当前 player 布局作为初始 target；一旦保存
-- targetLayout 就完全独立。
-- 这样升级不丢原 HUD，也不会让
-- 新字段反向污染追踪列表/分类/Feature 生命周期。
-- 实现理由：不把 player 旧字段整体搬迁到新结构，避免对现有导入导出、Binding 和旧版
-- schema4 存档做破坏性迁移。潜在风险：未来若新增视觉字段，必须同时进入 profile normalize。
local function NormalizeHudProfile(value, fallback)
    fallback = type(fallback) == "table" and fallback or {}
    if type(value) ~= "table" then return Copy(fallback) end
    local plateFallback = type(fallback.plate) == "table" and fallback.plate or {}
    local infoFallback = type(fallback.info) == "table" and fallback.info or {}
    local componentsFallback = type(fallback.components) == "table" and fallback.components or {}

    -- 中文维护注释（profile 字段级继承）：targetLayout 在旧存档升级、导入或未来字段
    -- 扩展时可能只有“部分 component”。若直接用整张 component 表覆盖 fallback，未出现的
    -- fontSize/spacing/maxRows 等字段会错误回落到全局默认，而不是用户已经调好的 player
    -- profile。这里先做字段级 overlay，再交给统一 Normalize* 限幅，保证 Authority 只有一套。
    local plate = Copy(plateFallback)
    for key, item in pairs(type(value.plate) == "table" and value.plate or {}) do plate[key] = Copy(item) end
    local info = Copy(infoFallback)
    for key, item in pairs(type(value.info) == "table" and value.info or {}) do info[key] = Copy(item) end
    local rawComponents = Copy(componentsFallback)
    for key, component in pairs(type(value.components) == "table" and value.components or {}) do
        local merged = Copy(type(rawComponents[key]) == "table" and rawComponents[key] or {})
        for field, item in pairs(type(component) == "table" and component or {}) do merged[field] = Copy(item) end
        rawComponents[key] = merged
    end
    local function BoolOrFallback(raw, fallbackValue, defaultValue)
        if raw ~= nil then return raw == true end
        if fallbackValue ~= nil then return fallbackValue == true end
        return defaultValue == true
    end
    return {
        plateScale = ClampFloat(value.plateScale, 0.5, 2.0, fallback.plateScale or 1.0),
        plate = {
            enabled = BoolOrFallback(plate.enabled, plateFallback.enabled, true),
            width = ClampInt(plate.width, 80, 320, plateFallback.width or 150),
            height = ClampInt(plate.height, 8, 40, plateFallback.height or 20),
            x = ClampInt(plate.x, -400, 400, plateFallback.x or 0),
            y = ClampInt(plate.y, -500, 500, plateFallback.y or 22),
            opacity = ClampFloat(plate.opacity, 0.2, 1.0, plateFallback.opacity or 0.85),
            showName = BoolOrFallback(plate.showName, plateFallback.showName, true),
        },
        info = {
            enabled = BoolOrFallback(info.enabled, infoFallback.enabled, true),
            x = ClampInt(info.x, -400, 400, infoFallback.x or 0),
            y = ClampInt(info.y, -120, 120, infoFallback.y or 0),
            fontSize = ClampInt(info.fontSize, 8, 24, infoFallback.fontSize or 12),
            showClass = BoolOrFallback(info.showClass, infoFallback.showClass, true),
            showGear = BoolOrFallback(info.showGear, infoFallback.showGear, true),
            showDistance = BoolOrFallback(info.showDistance, infoFallback.showDistance, true),
        },
        components = NormalizeComponents(rawComponents),
    }
end

local function BuildDefaultTargetHudProfile(playerProfile)
    local target = NormalizeHudProfile(nil, playerProfile)
    target.components = type(target.components) == "table" and target.components or {}
    for key, overlay in pairs(TARGET_EQUIPMENT_TEMPLATE) do
        local merged = Copy(type(target.components[key]) == "table" and target.components[key] or {})
        for field, item in pairs(overlay) do merged[field] = Copy(item) end
        target.components[key] = NormalizeComponent(merged, COMPONENT_DEFAULTS[key])
    end
    return target
end

local function HudProfileFromSettings(settings)
    settings = type(settings) == "table" and settings or {}
    return NormalizeHudProfile({
        plateScale = settings.plateScale, plate = settings.plate, info = settings.info, components = settings.components,
    }, {
        plateScale = 1.0,
        plate = { enabled=true, width=150, height=20, x=0, y=22, opacity=0.85, showName=true },
        info = { enabled=true, x=0, y=0, fontSize=12, showClass=true, showGear=true, showDistance=true },
        components = COMPONENT_DEFAULTS,
    })
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
    -- Keep the distinction between a truly fresh default request (nil) and an
    -- existing/legacy settings table without targetLayout. The latter must keep
    -- the schema5 upgrade rule “target starts as current player”; only fresh
    -- installs / explicit Reset defaults receive the release target template.
    local isFreshDefault = type(value) ~= "table"
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
    local normalizedPlayerProfile = NormalizeHudProfile({
        plateScale = value.plateScale, plate = plate, info = info, components = rawComponents,
    }, {
        plateScale = 1.0,
        plate = { enabled=true, width=150, height=20, x=0, y=22, opacity=0.85, showName=true },
        info = { enabled=true, x=0, y=0, fontSize=12, showClass=true, showGear=true, showDistance=true },
        components = COMPONENT_DEFAULTS,
    })
    local normalizedTargetProfile
    if type(value.targetLayout) == "table" then
        normalizedTargetProfile = NormalizeHudProfile(value.targetLayout, normalizedPlayerProfile)
    elseif isFreshDefault == true then
        normalizedTargetProfile = BuildDefaultTargetHudProfile(normalizedPlayerProfile)
    else
        -- Compatibility Authority: an old persisted single-HUD state must not
        -- suddenly receive the distributor template; initialize target from the
        -- user's current player layout exactly once, as schema5 originally did.
        normalizedTargetProfile = Copy(normalizedPlayerProfile)
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
        components = Copy(normalizedPlayerProfile.components),
        targetLayout = Copy(normalizedTargetProfile),
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
        plateScale = normalizedPlayerProfile.plateScale,
        -- NativeBarProxy anchor rect: aligned by the player onto the native bar
        -- via x/y/width/height. Not drawn; used only for layout. enabled/
        -- opacity/showName kept for backward compatibility, ignored by renderer.
        plate = Copy(normalizedPlayerProfile.plate),
        -- Info row above buffs: class · gear score · distance (each toggleable).
        info = Copy(normalizedPlayerProfile.info),
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

-- 中文维护注释（schema4 单 HUD 历史 canonical，2026-09-11）：
-- 问题原因：.18.202 把 targetLayout 加进 schema4 的 NormalizeSettings，却没有升级
-- schema。旧 schema4 SaveData 的已盖章 canonical 因而从 515E1BF3 变成了
-- 3B898E2F，Persistence 正确地把它视为同代数据被静默改写并 Fence。
-- Authority/数据流：此函数只复刻 .18.202 之前 schema4 的 Store canonical；它不是
-- 新业务 Authority，也不会 Apply/写盘。Persistence Core 仍负责 envelope 校验、预算、旧
-- fingerprint exact-match、4->5 migrate、Apply 与当前 schema5 的重新盖章。
-- 兼容边界：只用于 __rsmeta.schema==4 的历史档；当前/future schema 永远不得调用。
-- 为什么不用“删掉 targetLayout 再 Hash”：.18.202 同时把 player profile 收敛到
-- NormalizeHudProfile；其中缺省 plate.y 的 fallback 与旧 schema4 有细微差异。逐行保留旧
-- normalizer 才能证明旧盖章，而不是猜测某个字段导致 Hash 变化。
-- 后续维护：任何新的持久化字段都必须升级 Schema；禁止再次在同一 schema 下改变 canonical。
local function NormalizeHistoricalSchema4SingleHudSettings(value)
    value = type(value) == "table" and value or {}
    local tracked = type(value.tracked) == "table" and value.tracked or {}
    local plate = type(value.plate) == "table" and value.plate or {}
    local info = type(value.info) == "table" and value.info or {}
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
    if plate.y == nil and value.plate == nil then plate.y = 22 end
    return {
        showBuffs = value.showBuffs ~= false,
        showDebuffs = value.showDebuffs ~= false,
        showHidden = value.showHidden == true,
        freezeEnabled = value.freezeEnabled == true,
        playerRows = ClampInt(value.playerRows, 1, 64, 24),
        targetRows = ClampInt(value.targetRows, 1, 64, 24),
        refreshMs = (tonumber(value.refreshMs) == 400) and 120 or ClampInt(value.refreshMs, 1, 2000, 120),
        components = NormalizeComponents(rawComponents),
        layoutPresetVersion = LAYOUT_PRESET_VERSION,
        tracked = { buff = NormalizeTrackedIds(tracked.buff), debuff = NormalizeTrackedIds(tracked.debuff) },
        classification = NormalizeClassification(value.classification),
        headEnabled = value.headEnabled ~= false,
        headShowAll = value.headShowAll == true,
        headPlayer = value.headPlayer ~= false,
        headTarget = value.headTarget ~= false,
        headRefreshMs = (tonumber(value.headRefreshMs) == 100) and 50 or ClampInt(value.headRefreshMs, 1, 2000, 50),
        headShowStacks = value.headShowStacks ~= false,
        headShowTime = value.headShowTime ~= false,
        plateScale = ClampFloat(value.plateScale, 0.5, 2.0, 1.0),
        plate = {
            enabled = plate.enabled ~= false,
            width = ClampInt(plate.width, 80, 320, 150),
            height = ClampInt(plate.height, 8, 40, 20),
            x = ClampInt(plate.x, -400, 400, 0),
            y = ClampInt(plate.y, -500, 500, 0),
            opacity = ClampFloat(plate.opacity, 0.2, 1.0, 0.85),
            showName = plate.showName ~= false,
        },
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

local function NormalizeHistoricalSchema4SingleHudState(value)
    value = type(value) == "table" and value or {}
    return {
        settings = NormalizeHistoricalSchema4SingleHudSettings(value.settings),
        widgetWindow = NormalizeWindow(value.widgetWindow),
        widgetVisible = value.widgetVisible == true,
    }
end

local function BuffDisplayStoreProbe(text)
    local store = type(P.GetStore) == "function" and P:GetStore(STORE_ID) or nil
    if type(store) == "table" then store.lastHistoricalRecoveryProbe = tostring(text or "") end
end

local function IsHistoricalSingleHudMeta(raw)
    local meta = type(raw) == "table" and raw.__rsmeta or nil
    if type(meta) ~= "table" then return false, nil, "meta_missing" end
    if tostring(meta.store or "") ~= STORE_ID or tostring(meta.owner or "") ~= "v3.buff_display" then
        return false, meta, "identity"
    end
    if tonumber(meta.framework) ~= 3 or tonumber(meta.schema) ~= 4 then
        return false, meta, "generation"
    end
    return true, meta, nil
end

local function RebuildHistoricalSingleHudCanonical(decoded, stampedFingerprint, _currentCanonical, raw)
    local eligible, meta, reason = IsHistoricalSingleHudMeta(raw)
    if eligible ~= true then
        BuffDisplayStoreProbe("schema4SingleHud=skip:" .. tostring(reason) .. "/fw=" .. tostring(meta and meta.framework)
            .. "/s=" .. tostring(meta and meta.schema) .. "/tv=" .. tostring(meta and meta.transportVersion))
        return nil
    end
    local settings = type(decoded) == "table" and decoded.settings or nil
    if type(settings) ~= "table" or settings.targetLayout ~= nil then
        BuffDisplayStoreProbe("schema4SingleHud=reject:shape/targetLayout=" .. tostring(type(settings) == "table" and settings.targetLayout ~= nil))
        return nil
    end
    local historical = NormalizeHistoricalSchema4SingleHudState(decoded)
    local store = type(P.GetStore) == "function" and P:GetStore(STORE_ID) or nil
    local fp = type(P.FingerprintCanonicalValue) == "function" and type(store) == "table"
        and P:FingerprintCanonicalValue(store, historical) or nil
    BuffDisplayStoreProbe("schema4SingleHud=cand/hfp=" .. tostring(fp or "nil") .. "/old=" .. tostring(stampedFingerprint)
        .. "/tv=" .. tostring(meta.transportVersion))
    -- recovered Domain 故意返回“原 decoded 单 HUD”，而不是提前塞 targetLayout。这样 Core
    -- 在 exact old-hash 证明成功后仍会走正式 4->5 migrate；Schema 迁移保持唯一 Authority。
    return historical, Copy(decoded)
end

local KNOWN_SCHEMA4_SINGLE_HUD = { ["515E1BF3"] = "3B898E2F" }

local function ValidateHistoricalSchema4SingleHudShape(decoded)
    if type(decoded) ~= "table" or type(decoded.settings) ~= "table" then return false, "root" end
    local settings = decoded.settings
    if settings.targetLayout ~= nil then return false, "target_layout_present" end
    if type(settings.tracked) ~= "table" or type(settings.tracked.buff) ~= "table" or type(settings.tracked.debuff) ~= "table" then
        return false, "tracked"
    end
    if type(settings.components) ~= "table" or type(settings.plate) ~= "table" or type(settings.info) ~= "table" then
        return false, "layout"
    end
    return true, nil
end

local function RecoverKnownSchema4SingleHud(decoded, stampedFingerprint, currentCanonical, raw)
    local expectedCurrent = KNOWN_SCHEMA4_SINGLE_HUD[tostring(stampedFingerprint or "")]
    if expectedCurrent == nil then return nil end
    local eligible, meta, reason = IsHistoricalSingleHudMeta(raw)
    if eligible ~= true or tonumber(meta and meta.transportVersion) ~= 1 then
        BuffDisplayStoreProbe("knownSchema4=" .. tostring(stampedFingerprint) .. "/generation=reject:" .. tostring(reason)
            .. "/fw=" .. tostring(meta and meta.framework) .. "/s=" .. tostring(meta and meta.schema)
            .. "/tv=" .. tostring(meta and meta.transportVersion))
        return nil
    end
    local valid, shapeReason = ValidateHistoricalSchema4SingleHudShape(decoded)
    if valid ~= true then
        BuffDisplayStoreProbe("knownSchema4=" .. tostring(stampedFingerprint) .. "/shape=reject:" .. tostring(shapeReason))
        return nil
    end
    local store = type(P.GetStore) == "function" and P:GetStore(STORE_ID) or nil
    local currentFingerprint = type(P.FingerprintCanonicalValue) == "function" and type(store) == "table"
        and P:FingerprintCanonicalValue(store, NormalizeState(decoded)) or nil
    if tostring(currentFingerprint or "") ~= tostring(expectedCurrent) then
        BuffDisplayStoreProbe("knownSchema4=" .. tostring(stampedFingerprint) .. "/shape=ok/current=reject:"
            .. tostring(currentFingerprint) .. "!=" .. tostring(expectedCurrent))
        return nil
    end
    BuffDisplayStoreProbe("knownSchema4=" .. tostring(stampedFingerprint) .. "/shape=ok/current=" .. tostring(currentFingerprint))
    return Copy(decoded), "schema4_single_hud_known_pair"
end

-- 中文维护注释（schema6 / 历史 canonical 词法隔离）：
-- 上方 Normalize* 是上传 .18.208 的 schema5 原逻辑；schema4 hook 也仍捕获旧 helper。
-- 以下以同名 local 重新绑定当前规范化函数，旧 closure 不会读取新组件/Auto/库元数据。
-- Authority：先由 Persistence 用 historical exact hash 验证，随后 migrate，再盖 schema6 章。
-- 不放宽未知 mismatch，不改变 schema5/4 的默认值、双 HUD、窗口或冻结字段的旧 hash。
-- 新冷却字段仅保存用户选择/几何，不保存实时计时；目标组件强制关闭，禁止推测敌人 CD。
local NormalizeSchema5State = NormalizeState
local NormalizeSchema5Settings = NormalizeSettings
local NormalizeSchema5HudProfile = NormalizeHudProfile
local HudProfileFromSchema5Settings = HudProfileFromSettings
local COMPONENT_KEYS = Copy(COMPONENT_KEYS)
COMPONENT_KEYS[#COMPONENT_KEYS + 1] = "cooldowns"
local COMPONENT_DEFAULTS = Copy(COMPONENT_DEFAULTS)
COMPONENT_DEFAULTS.cooldowns = { enabled=false, x=0, y=90, size=29, fontSize=11, alpha=1, spacing=2, maxPerRow=8, maxRows=2 }
-- 中文维护注释（远程武器发行默认 v4，2026-09-15）：
-- 历史 LAYOUT_PRESET_VERSION=3 被 schema4/5/6 已盖章 canonical 捕获，禁止直接改常量；
-- 当前发行版用独立版本号描述“主手→副手→远程（视觉从左到右）”的新装备排列。
-- 旧存档仍先按冻结 v3 normalizer 验真，只有加载成功后的兼容迁移才会升级到 v4。
local CURRENT_LAYOUT_PRESET_VERSION = 4
local function NormalizeComponents(value)
    local out = {}
    for _, key in ipairs(COMPONENT_KEYS) do
        out[key] = NormalizeComponent(type(value)=="table" and value[key] or nil, COMPONENT_DEFAULTS[key])
    end
    return out
end
local function NormalizeHudProfile(value, fallback)
    local out = NormalizeSchema5HudProfile(value, fallback)
    local base = type(fallback)=="table" and type(fallback.components)=="table" and fallback.components.cooldowns or nil
    local merged = Copy(type(base)=="table" and base or {})
    local incoming = type(value)=="table" and type(value.components)=="table" and value.components.cooldowns or nil
    for k,v in pairs(type(incoming)=="table" and incoming or {}) do merged[k]=v end
    out.components = type(out.components)=="table" and out.components or {}
    out.components.cooldowns = NormalizeComponent(merged, COMPONENT_DEFAULTS.cooldowns)
    return out
end
local function HudProfileFromSettings(settings)
    return NormalizeHudProfile(settings, HudProfileFromSchema5Settings(settings))
end
local function NormalizeCooldownIds(value)
    local out = NormalizeTrackedIds(value)
    while #out > 256 do out[#out]=nil end
    return out
end
-- 中文维护（hud-default-template-2，2026-09-13）：用户实机 hud.1.1 的三页已按
-- 619+619+314 连续偏移验真；wire=9BF4FA11，raw=1539/3486F051，含11条V2记录。
-- Authority/数据流：仅“无设置的新安装”和显式默认快照/恢复动作使用此发行模板；
-- 原 Store/canonical 仍拥有已存几何，不能在每次 Normalize 或加载时套用新布局。
-- 兼容边界：上方 schema4/5 closure、schema6 对已有 table 的缺字段 fallback 必须冻结；
-- 直接修改 COMPONENT_DEFAULTS 会改旧档 Hash，因此在当前 schema6 的 fresh 分支合并。
-- 坐标为校准局部 screen-y-v1：plate/info/class 的Y直接使用，Aura旧存储Y方向相反但本次
-- 两行均为0；不要据2560x1440/uiScale=1再乘分辨率或把屏幕绝对点写进默认。
-- 只固化已导出的视觉字段；未导出的cooldowns/距离/装分组件及业务选择继续用既有默认。
-- PLAYER/TARGET本次值相同但每次分别Normalize成独立表；以后不要共享用户可写表。
local VERIFIED_HUD_DEFAULT_PROFILE = {
    plateScale = 1.0,
    plate = { x=0, y=-24, width=150, height=20 },
    info = { x=1, y=0, fontSize=12, enabled=true, showClass=true, showGear=true, showDistance=true },
    components = {
        buffs = { x=0, y=0, size=29, fontSize=11, spacing=2, maxPerRow=8, maxRows=2, alpha=1, enabled=true },
        debuffs = { x=0, y=0, size=29, fontSize=11, spacing=2, maxPerRow=8, maxRows=2, alpha=1, enabled=true },
        mainHand = { x=0, y=0, size=26, alpha=1, enabled=true },
        offHand = { x=0, y=0, size=26, alpha=1, enabled=true },
        ranged = { x=0, y=0, size=26, alpha=1, enabled=false },
        wings = { x=0, y=0, size=26, alpha=1, enabled=true },
        castBar = { x=0, y=0, width=120, size=7, fontSize=12, alpha=1, enabled=true, showText=true },
        class = { x=16, y=-5, size=27, alpha=1, enabled=true },
    },
}

local function NormalizeSettings(value)
    -- 维护：必须在nil被替换成{}之前区分fresh；空表、旧档缺targetLayout也不是发行模板请求。
    local isFreshDefault = type(value) ~= "table"
    local out = NormalizeSchema5Settings(value)
    value = type(value)=="table" and value or {}
    -- 中文维护注释：schema6 旧存档中的 v3 必须规范化后仍是 v3，保证历史 Hash 不变；
    -- 只有已经明确写入 v4 的当前存档才保留 v4。这样新排列版本不会倒灌进未知旧档。
    out.layoutPresetVersion = ClampInt(value.layoutPresetVersion, 1, CURRENT_LAYOUT_PRESET_VERSION, LAYOUT_PRESET_VERSION)
    local rawTracked = type(value.tracked)=="table" and value.tracked or {}
    out.tracked.auto = NormalizeTrackedIds(rawTracked.auto)
    -- 旧 buff/debuff 桶原样保留；只排除新 Auto 与明确选择的重复，不迁移猜测用户意图。
    local explicit = {}; for _,category in ipairs({"buff","debuff"}) do
        for _,id in ipairs(out.tracked[category]) do explicit[id]=true end
    end
    local auto = {}; for _,id in ipairs(out.tracked.auto) do if not explicit[id] then auto[#auto+1]=id end end
    out.tracked.auto = auto
    local cooldowns = type(value.trackedCooldowns)=="table" and value.trackedCooldowns or {}
    out.trackedCooldowns = {skill=NormalizeCooldownIds(cooldowns.skill),mate=NormalizeCooldownIds(cooldowns.mate)}
    out.components.cooldowns = NormalizeComponent(type(value.components)=="table" and value.components.cooldowns or nil, COMPONENT_DEFAULTS.cooldowns)
    out.targetLayout.components.cooldowns = NormalizeComponent(nil, COMPONENT_DEFAULTS.cooldowns)
    local library = type(value.library)=="table" and value.library or {}
    out.library = {catalogVersion=ClampInt(library.catalogVersion,0,1000000,0),importedPacks={}}
    local count=0
    -- importedPacks 仅是用户主动导入的版本水位，不形成“后台补回被取消 ID”的订阅。
    local keys={};for key in pairs(type(library.importedPacks)=="table" and library.importedPacks or {}) do
        if type(key)=="string" and #key<=64 then keys[#keys+1]=key end
    end
    table.sort(keys)
    for _,key in ipairs(keys) do
        if count<64 then out.library.importedPacks[key]=ClampInt(library.importedPacks[key],0,1000000,0);count=count+1 end
    end
    out.freezeEnabled = false -- 只保留读取兼容字段；会话冻结不是持久化 Authority。
    if isFreshDefault then
        -- 维护：默认入口集中到这一个纯函数分支；Reset/校准默认均经此处，不保存、不读Native。
        -- target显式覆盖本次全部已验真字段，避免继承历史TARGET装备的-32/-33/22px与远程开启。
        local player = NormalizeHudProfile(VERIFIED_HUD_DEFAULT_PROFILE, HudProfileFromSettings(out))
        -- 中文维护注释（玩家远程武器默认开启）：经实机用户反馈，远程职业必须和主手/副手一样
        -- 开箱即见。VERIFIED_HUD_DEFAULT_PROFILE 保留 2026-09-13 原始模板（ranged=false）作为
        -- 历史证据；这里只在“fresh/reset 默认入口”覆盖玩家 ranged.enabled，避免修改冻结模板本身。
        player.components.ranged.enabled = true
        out.plateScale, out.plate, out.info, out.components = player.plateScale, player.plate, player.info, player.components
        out.targetLayout = NormalizeHudProfile(VERIFIED_HUD_DEFAULT_PROFILE, out.targetLayout)
        out.layoutPresetVersion = CURRENT_LAYOUT_PRESET_VERSION
    end
    return out
end
local function NormalizeState(value)
    value=type(value)=="table" and value or {}
    return {settings=NormalizeSettings(value.settings),widgetWindow=NormalizeWindow(value.widgetWindow),widgetVisible=value.widgetVisible==true}
end
-- 中文维护注释（schema5/6 表示兼容）：旧回归未覆盖数字序号变成字符串，ipairs 可在
-- 校验前漏读仍存在磁盘的 ID。此处不改变正常 canonical、不新增 Hash 白名单；只对声明列表
-- 无损重建 dense 候选。schema5 用冻结旧 normalizer，schema6 用当前规则，再由 Core 比旧章。
-- Authority/数据流：原 decoded → 列表候选 → 对应世代 canonical → Core 验真/迁移/Apply。
-- 不重分类、不查 Native、不补默认 ID；未来 schema/错误 owner 禁入，未知 Hash 保留写保护。
-- 中文维护注释（.18.241，HUD 大 Store 最后一次已知标量省略恢复）：
-- 实机在 .240 已证明：用户把自身 distance.x 调为 -1、同步到目标并“保存并退出”时，
-- SaveData 回读会把主 v3.buff_display 的 `settings.components.distance.x` 整个字段省略，
-- 当前 Normalize 因缺字段回落到 0，形成 `number(-1) vs number(0)`。这次 .241 已把后续 HUD
-- 保存迁出主 Store，但用户磁盘上可能已经留下这份失败写入，必须先能安全跨过下一次 Reload。
-- Authority/验真：只接受 CURRENT schema8 + Transport5（调用者已校验）、Normalize 前 decoded 该字段为 nil、
-- 当前 canonical 恰为默认 0 的单字段事故。枚举 x 合法整数 [-400,400] 中非0候选，并要求完整
-- Store canonical 对旧 stamped fingerprint **唯一精确命中**；0个或>1个命中均 fail-closed。
-- 不枚举其它组件/坐标、不改 tracking、不根据 Hash 猜 ID；这是 bounded scalar proof，模式与 Core
-- 既有 F2 数值冷恢复一致但范围更窄。只在 integrity mismatch 冷路径运行，不进入 Tick/渲染/循环热路。
-- 恢复后不主动重写主 Store；HUD 下一次正式保存会写 v3.buff_display.layout 小 Store，从架构上结束
-- 该故障链。未来如出现其它字段省略，必须先有独立实机 divergence 再新增路径，禁止扩大通配。
local function RecoverSchema8DistanceXTransport5Omission(decoded, stamped, current, raw, store, prefix)
    local settings = type(decoded) == "table" and type(decoded.settings) == "table" and decoded.settings or nil
    local components = type(settings) == "table" and type(settings.components) == "table" and settings.components or nil
    local distance = type(components) == "table" and type(components.distance) == "table" and components.distance or nil
    local canonicalDistance = type(current) == "table" and type(current.settings) == "table"
        and type(current.settings.components) == "table" and type(current.settings.components.distance) == "table"
        and current.settings.components.distance or nil
    -- DecodeValue 交给 Store 的 decoded 仍是 Normalize 之前的业务 payload；因此这里用
    -- `distance.x == nil` 作为“Native 物理回读省略了该字段”的证据。不要再次依赖 raw.payload：
    -- Persistence 在进入 Store canonical hook 前已经把 transport envelope 解开，raw 的具体层级不是
    -- Store Authority，历史版本也可能不同。current 则是当前 Normalize 后的 canonical，缺字段只会回落到 0。
    if type(distance) ~= "table" or distance.x ~= nil
        or type(canonicalDistance) ~= "table" or tonumber(canonicalDistance.x) ~= 0
        or type(stamped) ~= "string" or #stamped ~= 8 or stamped:find("[^%x]") then return nil end

    local candidate = Copy(current)
    local matchedValue, matches, tries = nil, 0, 0
    for value = -400, 400 do
        if value ~= 0 then
            tries = tries + 1
            candidate.settings.components.distance.x = value
            local fp = P:FingerprintCanonicalValue(store, candidate)
            if fp ~= nil and tostring(fp) == tostring(stamped) then
                matches = matches + 1
                matchedValue = value
                if matches > 1 then break end
            end
        end
    end
    BuffDisplayStoreProbe(tostring(prefix) .. "/layoutScalar=distance.x/omitted/tries=" .. tostring(tries)
        .. "/matches=" .. tostring(matches) .. "/value=" .. tostring(matchedValue or "-"))
    if matches ~= 1 then return nil end

    local recoveredDomain = Copy(decoded)
    recoveredDomain.settings.components.distance.x = matchedValue
    -- current 已是 schema8 的当前 canonical。直接只替换经旧章唯一证明的 x，避免本 helper
    -- 捕获到文件前部冻结的历史 NormalizeState closure；Core 随后仍会对 recoveredDomain
    -- 按 Store 当前 Normalize 重新 canonicalize 并再次比章，所以这里不是绕过 Authority。
    local recoveredCanonical = Copy(current)
    recoveredCanonical.settings.components.distance.x = matchedValue
    local recoveredFp = P:FingerprintCanonicalValue(store, recoveredCanonical)
    if tostring(recoveredFp or "") ~= tostring(stamped) then return nil end
    return recoveredCanonical, recoveredDomain
end

local function RebuildHistoricalCanonical(decoded, stamped, current, raw)
    local meta = type(raw) == "table" and raw.__rsmeta or nil
    local schema = type(meta) == "table" and tonumber(meta.schema) or nil
    if type(meta) == "table" and meta.store == STORE_ID and meta.owner == "v3.buff_display"
        and tonumber(meta.framework) == 3 and (schema == 5 or schema == 6) then
        local normalize = schema == 5 and NormalizeSchema5State or NormalizeState
        local base = normalize(decoded)
        local store = P:GetStore(STORE_ID)
        local baseFp = P:FingerprintCanonicalValue(store, base)
        local prefix = "schema" .. tostring(schema) .. "/base=" .. tostring(baseFp) .. "/old=" .. tostring(stamped)
        BuffDisplayStoreProbe(prefix)
        if tostring(baseFp) == tostring(stamped) then return base, Copy(decoded) end
        if type(decoded) ~= "table" or type(decoded.settings) ~= "table"
            or type(P.RebuildDenseSequenceForIntegrity) ~= "function" then
            BuffDisplayStoreProbe(prefix .. "/sequence=unavailable")
            return base, Copy(decoded)
        end
        local recovered, changes = Copy(decoded), 0
        local function RebuildGroup(group, keys, limit)
            if type(group) ~= "table" then return true end
            for _, key in ipairs(keys) do
                if group[key] ~= nil then
                    local rows, reason, changed = P:RebuildDenseSequenceForIntegrity(group[key], limit)
                    if rows == nil then return false, key .. ":" .. tostring(reason) end
                    if changed then group[key] = rows; changes = changes + 1 end
                end
            end
            return true
        end
        local ok, reason = RebuildGroup(recovered.settings.tracked,
            schema == 5 and {"buff", "debuff"} or {"buff", "debuff", "auto"}, 1024)
        if ok and schema == 6 then
            ok, reason = RebuildGroup(recovered.settings.trackedCooldowns, {"skill", "mate"}, 256)
        end
        if not ok or changes == 0 then
            BuffDisplayStoreProbe(prefix .. "/sequence=" .. tostring(reason or "unchanged"))
            -- 维护（F2窗口精度）：该失败形状与已实证跑商共用Floating中心比例。先严格确认
            -- 追踪列表完整且未重建，再在原schema5/6 canonical上尝试单轴精度恢复；不是
            -- 先迁移再比较旧章。复合序列+数值漂移本轮不猜，历史ID/双HUD/默认值仍保持原链路。
            if ok and changes == 0 and type(P.RebuildFixed6WindowCanonical) == "function" then
                local candidate, domain = P:RebuildFixed6WindowCanonical(store, decoded, stamped, base, raw, schema, nil)
                if candidate ~= nil then return candidate, domain end
            end
            return base, Copy(decoded)
        end
        local candidate = normalize(recovered)
        BuffDisplayStoreProbe(prefix .. "/sequence=" .. tostring(changes)
            .. "/seqfp=" .. tostring(P:FingerprintCanonicalValue(store, candidate)))
        return candidate, recovered -- Core 仍是唯一验真/迁移/Apply/重盖章 Authority。
    end
    return RebuildHistoricalSingleHudCanonical(decoded,stamped,current,raw)
end

-- 中文维护注释（schema7 装分显示格式，2026-09-17）：
-- 问题原因：HUD 信息拆分后，装备分数已拥有独立文字组件，但用户仍只能看完整整数；
-- 同时直接在 schema6 normalizer 增字段会改变所有已盖章 schema6 canonical，破坏升级验真。
-- Authority/数据流：info.gearScoreFormat 是每个 HUD profile 的唯一显示策略 Authority，
-- 只接受 full/compact；Renderer 只消费 detached profile，不拥有/回写设置。player/target 各自保存，
-- “同步自身到目标”通过既有 profile Copy 自然同步。
-- 兼容边界：这里先冻结 schema6 的当前 normalizer，再以新 local 叠加 schema7 字段；旧 schema4/5/6
-- integrity hook 仍捕获上方旧 closure，未知 mismatch 继续 fail-closed。schema6 缺字段迁移为 full，
-- 不改变旧用户视觉。格式只影响显示文字，不改变真实 gearScore 数值、读取频率或业务事实。
local RebuildHistoricalCanonicalSchema6 = RebuildHistoricalCanonical
local NormalizeSchema6State = NormalizeState
local NormalizeSchema6Settings = NormalizeSettings
local NormalizeSchema6HudProfile = NormalizeHudProfile
local HudProfileFromSchema6Settings = HudProfileFromSettings

local function NormalizeGearScoreFormat(value)
    return tostring(value or "full") == "compact" and "compact" or "full"
end

local function NormalizeHudProfile(value, fallback)
    local out = NormalizeSchema6HudProfile(value, fallback)
    local incomingInfo = type(value) == "table" and type(value.info) == "table" and value.info or {}
    local fallbackInfo = type(fallback) == "table" and type(fallback.info) == "table" and fallback.info or {}
    local format = incomingInfo.gearScoreFormat
    if format == nil then format = fallbackInfo.gearScoreFormat end
    out.info = type(out.info) == "table" and out.info or {}
    out.info.gearScoreFormat = NormalizeGearScoreFormat(format)
    return out
end

local function HudProfileFromSettings(settings)
    return NormalizeHudProfile(settings, HudProfileFromSchema6Settings(settings))
end

local function NormalizeSettings(value)
    local out = NormalizeSchema6Settings(value)
    value = type(value) == "table" and value or {}
    local rawInfo = type(value.info) == "table" and value.info or {}
    out.info = type(out.info) == "table" and out.info or {}
    out.info.gearScoreFormat = NormalizeGearScoreFormat(rawInfo.gearScoreFormat)

    out.targetLayout = type(out.targetLayout) == "table" and out.targetLayout or {}
    out.targetLayout.info = type(out.targetLayout.info) == "table" and out.targetLayout.info or {}
    local rawTarget = type(value.targetLayout) == "table" and type(value.targetLayout.info) == "table" and value.targetLayout.info or {}
    local targetFormat = rawTarget.gearScoreFormat
    if targetFormat == nil then targetFormat = out.info.gearScoreFormat end
    out.targetLayout.info.gearScoreFormat = NormalizeGearScoreFormat(targetFormat)
    return out
end

local function NormalizeState(value)
    value = type(value) == "table" and value or {}
    return {settings=NormalizeSettings(value.settings),widgetWindow=NormalizeWindow(value.widgetWindow),widgetVisible=value.widgetVisible==true}
end

-- 中文维护注释（schema7 表示恢复边界）：ArcheRage SaveData 已实证会把 dense 数组的数字索引
-- 回读为字符串索引。schema6 以前的 hook 只认识到当时的当前 schema；升级 schema7 后若不把当前
-- 世代接进同一“先重建候选、再用原 fingerprint 精确验真”的链，397项导入/满1024追踪会在
-- 保存回读或下次加载时被误判丢失并写保护。这里不放宽任何 Hash：仅重建索引表示和已有
-- Floating 单轴精度候选，candidate 仍必须命中磁盘已盖章 fingerprint 才能获得信任。旧 schema4/5/6
-- 委托冻结 hook，避免新 gearScoreFormat 默认污染历史 canonical。
local function RebuildHistoricalCanonical(decoded, stamped, current, raw)
    local meta = type(raw) == "table" and raw.__rsmeta or nil
    local schema = type(meta) == "table" and tonumber(meta.schema) or nil
    if type(meta) == "table" and meta.store == STORE_ID and meta.owner == "v3.buff_display"
        and tonumber(meta.framework) == 3 and schema == 7 then
        local base = NormalizeState(decoded)
        local store = P:GetStore(STORE_ID)
        local baseFp = type(P.FingerprintCanonicalValue) == "function" and P:FingerprintCanonicalValue(store, base) or nil
        local prefix = "schema7/base=" .. tostring(baseFp) .. "/old=" .. tostring(stamped)
        BuffDisplayStoreProbe(prefix)
        if tostring(baseFp) == tostring(stamped) then return base, Copy(decoded) end
        if type(decoded) ~= "table" or type(decoded.settings) ~= "table"
            or type(P.RebuildDenseSequenceForIntegrity) ~= "function" then
            BuffDisplayStoreProbe(prefix .. "/sequence=unavailable")
            return base, Copy(decoded)
        end
        local recovered, changes = Copy(decoded), 0
        local function RebuildGroup(group, keys, limit)
            if type(group) ~= "table" then return true end
            for _, key in ipairs(keys) do
                if group[key] ~= nil then
                    local rows, reason, changed = P:RebuildDenseSequenceForIntegrity(group[key], limit)
                    if rows == nil then return false, key .. ":" .. tostring(reason) end
                    if changed then group[key] = rows; changes = changes + 1 end
                end
            end
            return true
        end
        local ok, reason = RebuildGroup(recovered.settings.tracked, {"buff","debuff","auto"}, 1024)
        if ok then ok, reason = RebuildGroup(recovered.settings.trackedCooldowns, {"skill","mate"}, 256) end
        if not ok or changes == 0 then
            BuffDisplayStoreProbe(prefix .. "/sequence=" .. tostring(reason or "unchanged"))
            if ok and changes == 0 and type(P.RebuildFixed6WindowCanonical) == "function" then
                local candidate, domain = P:RebuildFixed6WindowCanonical(store, decoded, stamped, base, raw, schema, nil)
                if candidate ~= nil then return candidate, domain end
            end
            return base, Copy(decoded)
        end
        local candidate = NormalizeState(recovered)
        BuffDisplayStoreProbe(prefix .. "/sequence=" .. tostring(changes)
            .. "/seqfp=" .. tostring(P:FingerprintCanonicalValue(store, candidate)))
        return candidate, recovered
    end
    return RebuildHistoricalCanonicalSchema6(decoded, stamped, current, raw)
end

-- Lossless schema < 7 -> 7 migration. Persistence calls migrate(raw, from, to)
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

-- 中文维护注释（schema8 追踪范围拆分，2026-09-17）：
-- 问题原因：schema7 的 tracked.buff/debuff/auto 是全局白名单，同一状态无法只显示给自己或只显示给目标；
-- 页面点击行还会立即改写全局选择，用户无法先选择再决定显示范围。
-- Authority/数据流：schema8 将持久化追踪唯一 Authority 收敛为 player/target × buff/debuff/auto 六个有界通道；
-- Aura 仍只提供事实，HUD/管理投影只消费 detached index，分类 override 仍是独立元数据，不拥有追踪选择。
-- 兼容边界：旧 schema7 及更早的全局追踪在迁移时复制到 player+target，视觉行为与升级前一致；
-- historical exact-hash 先由冻结 schema7 closure 验真，再 migrate，未知 mismatch 继续 fail-closed。
-- 实现理由：显式 Buff/Debuff 通道可以独立并存；Auto 只承接旧配置/内置库未人工放置状态。用户第一次
-- 显式放置该 ID 时两边 Auto 都退让，但不会删除任何显式 scope/category，才能真正表达“仅目标/仅自己/双方”。
local NormalizeSchema7StateFinal = NormalizeState
local NormalizeSchema7SettingsFinal = NormalizeSettings
local RebuildHistoricalCanonicalSchema7Final = RebuildHistoricalCanonical
local MigrateStateSchema7 = MigrateState

local TRACKING_SCOPES = { "player", "target" }
local TRACKING_CATEGORIES = { "buff", "debuff", "auto" }

local function EmptyTrackedScopes()
    return {
        player = { buff = {}, debuff = {}, auto = {} },
        target = { buff = {}, debuff = {}, auto = {} },
    }
end

local function NormalizeTrackedScopes(value)
    value = type(value) == "table" and value or {}
    local out = EmptyTrackedScopes()
    local nested = type(value.player) == "table" or type(value.target) == "table"
    if nested then
        for _, scope in ipairs(TRACKING_SCOPES) do
            local src = type(value[scope]) == "table" and value[scope] or {}
            for _, category in ipairs(TRACKING_CATEGORIES) do
                out[scope][category] = NormalizeTrackedIds(src[category])
            end
        end
    else
        -- schema<=7 global whitelist meant "both HUDs". Duplicate, never guess a narrower scope.
        for _, category in ipairs(TRACKING_CATEGORIES) do
            local ids = NormalizeTrackedIds(value[category])
            out.player[category], out.target[category] = Copy(ids), Copy(ids)
        end
    end
    -- Within one scope Auto is only a fallback polarity choice. Explicit channels win over Auto,
    -- but Buff and Debuff are intentionally independent because the four UI actions are toggles.
    for _, scope in ipairs(TRACKING_SCOPES) do
        local explicit = {}
        for _, category in ipairs({ "buff", "debuff" }) do
            for _, id in ipairs(out[scope][category]) do explicit[id] = true end
        end
        local auto = {}
        for _, id in ipairs(out[scope].auto) do if explicit[id] ~= true then auto[#auto + 1] = id end end
        out[scope].auto = auto
    end
    return out
end

local function NormalizeSettings(value)
    local out = NormalizeSchema7SettingsFinal(value)
    local raw = type(value) == "table" and value.tracked or nil
    out.tracked = NormalizeTrackedScopes(raw)
    return out
end

local function NormalizeState(value)
    value = type(value) == "table" and value or {}
    return { settings = NormalizeSettings(value.settings), widgetWindow = NormalizeWindow(value.widgetWindow), widgetVisible = value.widgetVisible == true }
end

-- 中文维护注释（2026-09-18，.18.240 Transport5 scoped-vector prefix recovery）：
-- 问题原因：.239 实机完整 RAW_STORE 证明 RU Native 不只是“整字段省略”。player.auto 的
-- Transport5 marker/count 被省略，但 `chunks` 普通表仍保留 1..19；其中第 19 块又由 16 个
-- token 截成 15 个，而完整 target.auto 仍是 25 块/393 项。因为 marker 已丢，Core 的
-- TransportDecodeValueV5 会把 player.auto 当普通 map 成功解码，无法产生 missing-chunk 错误，
-- 最后只会在 schema8 historical canonical 看到 `player.auto:invalid_index`。
-- Authority：这里只生成一个“表示层恢复候选”，绝不直接 Apply/Save/清 Fence。必须同时满足：
-- 1) CURRENT Framework3/schema8/Transport5；2) 恰好一侧 auto 是另一侧完整 T5 vector 的严格
-- 物理前缀（前置 chunk 逐字相等，最后幸存 chunk 只能相等或是完整 chunk 的逗号边界严格前缀）；
-- 3) 健康 twin 解码为未改写的 dense 正整数列表；4) 用 twin 补回后整份 Store canonical
-- fingerprint 精确命中磁盘原 stamped fingerprint。任何一项不满足都返回 nil，由 Core 继续 Fence。
-- 兼容边界：不处理 buff/debuff、不使用 Catalog/Hash 猜 ID、不把 `{}`/任意 sparse map 当损坏，
-- 也不接受“中间 chunk 不同”“非连续 chunks”“额外键”“marker/count 与 twin 冲突”等形状。
-- 性能：只在已经发生 fingerprint mismatch 的 Load/Save readback 冷路径执行；最多审计 64 个
-- chunk/1024 个 ID，不进入 Tick/扫描/渲染循环。
local function RecoverTransport5ScopedAutoPrefix(decoded, stamped, raw, store, prefix)
    if type(raw) ~= "table" or type(raw.__rsmeta) ~= "table" or tonumber(raw.__rsmeta.transportVersion) ~= 5
        or type(decoded) ~= "table" or type(decoded.settings) ~= "table" or type(decoded.settings.tracked) ~= "table" then
        return nil
    end

    -- 注意：Core 在调用 historical hook 前已经执行 DecodePhysicalEnvelope，因此这里的 `decoded/raw`
    -- 都是逻辑 envelope。健康 T5 vector 已还原成 dense ID 数组；只有 marker 被 Native 丢掉的坏侧
    -- 仍以 `{chunks={...}}` 普通 map 残留。这恰好保留了“幸存物理 chunk 字符串”，足够和健康
    -- twin 重新编码出的期望 chunk 做逐字前缀证明，无需扩大 Core 的 hook 合同或缓存整份物理 raw。
    local chunkSize = 16
    local function DenseIds(value)
        if type(P.RebuildDenseSequenceForIntegrity) ~= "function" then return nil end
        local rows, reason, changed = P:RebuildDenseSequenceForIntegrity(value, 1024)
        if type(rows) ~= "table" or changed == true or #rows <= 32 then return nil, reason end
        for index = 1, #rows do
            local id = rows[index]
            if type(id) ~= "number" or id < 1 or id ~= math.floor(id) then return nil, "id" end
        end
        return rows
    end
    local function BuildChunks(rows)
        local chunks, parts = {}, math.ceil(#rows / chunkSize)
        for part = 1, parts do
            local first = (part - 1) * chunkSize + 1
            local last = math.min(#rows, first + chunkSize - 1)
            local tokens = {}
            for index = first, last do tokens[#tokens + 1] = string.format("%.0f", rows[index]) end
            chunks[part] = table.concat(tokens, ",")
        end
        return chunks, parts
    end
    local function TokenCount(text)
        if type(text) ~= "string" or #text == 0 or #text > 143 or not text:match("^[1-9]%d*[,0-9]*$") then return nil end
        local count = 0
        for token in text:gmatch("[^,]+") do
            local value = tonumber(token)
            if value == nil or value < 1 or value ~= math.floor(value) or string.format("%.0f", value) ~= token then return nil end
            count = count + 1
        end
        return count
    end
    local function PrefixShape(value, sourceRows)
        if type(value) ~= "table" or type(value.chunks) ~= "table" or type(sourceRows) ~= "table" then return nil end
        -- Decode 成功但 marker 已丢时，坏侧只允许 chunks + 可选同值 count；出现任意业务键/额外字段
        -- 都不是本次实机事故形状，必须拒绝而不是把用户数据误当 transport 残片。
        for key in pairs(value) do
            if key ~= "chunks" and key ~= "count" then return nil end
        end
        if value.count ~= nil and tonumber(value.count) ~= #sourceRows then return nil end
        local expected, fullParts = BuildChunks(sourceRows)
        local present, fields, maximum = {}, 0, 0
        for key, text in pairs(value.chunks) do
            local kind, index = type(key), tonumber(key)
            if (kind ~= "number" and kind ~= "string") or index == nil or index ~= math.floor(index)
                or index < 1 or index > fullParts then return nil end
            if kind == "string" and (not key:match("^[1-9]%d*$") or tostring(index) ~= key) then return nil end
            if present[index] ~= nil or TokenCount(text) == nil then return nil end
            present[index], fields, maximum = text, fields + 1, math.max(maximum, index)
        end
        if fields < 1 or maximum ~= fields or maximum > fullParts then return nil end
        local lastPrefix, lastTokens, fullLastTokens = false, nil, nil
        local lastPrefixMode, lastBytes, fullLastBytes = nil, nil, nil
        for part = 1, maximum do
            local text, wanted = present[part], expected[part]
            if part < maximum then
                if text ~= wanted then return nil end
            elseif text ~= wanted then
                -- 中文维护注释（2026-09-18，.18.242 实机 mid-token 截断）：
                -- .240 只观察到“最后一个完整 token 被吃掉”，因此旧实现错误地把合法事故形状
                -- 限死在 `wanted:sub(1,#text+1)==text..","` 的逗号边界。`.241` 的完整 RAW_STORE
                -- 已证明 RU SaveData 还会把最后一个十进制 ID **截在数字中间**：例如健康 twin
                -- 末尾 `...,23524,23642,23956`，损坏侧只剩 `...,23524,236`。这不是业务 ID=236，
                -- 而是物理字符串的字节前缀；若继续按 token 计数判断，会把同一类 Transport5
                -- 表示损坏误判为业务数据变化并永久 Fence。
                --
                -- Authority/安全边界：这里只把“最后幸存 chunk 是健康 twin 对应 chunk 的严格
                -- **字节前缀**”作为候选资格；前面所有 chunk 仍必须逐字相等、chunks 必须连续、
                -- outer map 仍只允许 chunks/count。候选随后仍需用完整 twin 重建整个 auto，并让
                -- **整份 v3.buff_display canonical fingerprint 精确命中磁盘旧 stamp** 才能返回。
                -- 因此这里不是把残缺 `236` 当成 ID，也不是依据 Hash 猜某个 ID；任何合法 scope
                -- 分叉、任意改字节、隐藏在丢失后缀里的用户差异都会在 whole-Store Hash 处拒绝。
                --
                -- 兼容/性能：只在 schema8 + Transport5 + fingerprint mismatch 的冷加载/回读路径
                -- 运行，最多审计 64 chunk/1024 ID；严禁把该逻辑搬进 Tick、HUD 刷新或 aura 扫描。
                -- 未来若出现“中间 chunk 被截/替换”而不是末尾前缀，必须新增独立实机证据和测试，
                -- 不得把本条件放宽成任意 substring/近似匹配。
                if #text >= #wanted or wanted:sub(1, #text) ~= text then return nil end
                lastTokens, fullLastTokens = TokenCount(text), TokenCount(wanted)
                if lastTokens == nil or fullLastTokens == nil then return nil end
                lastPrefix = true
                lastBytes, fullLastBytes = #text, #wanted
                local nextChar = wanted:sub(#text + 1, #text + 1)
                if text:sub(-1) == "," or nextChar == "," then
                    lastPrefixMode = "token"
                else
                    lastPrefixMode = "byte"
                end
            end
        end
        -- marker 已经不在逻辑 map；至少还必须真的少后续 chunk 或截短最后 chunk。完整普通 map
        -- 不属于可接受事故形状，避免未来其它业务表恰好叫 chunks 时被误恢复。
        if maximum >= fullParts and lastPrefix ~= true then return nil end
        return {
            parts = maximum, fullParts = fullParts,
            lastTokens = lastTokens, fullLastTokens = fullLastTokens,
            lastPrefixMode = lastPrefixMode, lastBytes = lastBytes, fullLastBytes = fullLastBytes,
        }
    end

    local tracked = decoded.settings.tracked
    local player = type(tracked.player) == "table" and tracked.player or nil
    local target = type(tracked.target) == "table" and tracked.target or nil
    if player == nil or target == nil then return nil end
    local playerRows = DenseIds(player.auto)
    local targetRows = DenseIds(target.auto)
    local playerPrefix = targetRows and PrefixShape(player.auto, targetRows) or nil
    local targetPrefix = playerRows and PrefixShape(target.auto, playerRows) or nil
    if (playerPrefix ~= nil) == (targetPrefix ~= nil) then return nil end

    local missingScope = playerPrefix and "player" or "target"
    local sourceScope = playerPrefix and "target" or "player"
    local sourceRows = playerPrefix and targetRows or playerRows
    local prefixInfo = playerPrefix or targetPrefix
    local recovered = Copy(decoded)
    recovered.settings.tracked[missingScope].auto = Copy(sourceRows)
    local candidate = NormalizeState(recovered)
    local fingerprint = type(P.FingerprintCanonicalValue) == "function"
        and P:FingerprintCanonicalValue(store, candidate) or nil
    BuffDisplayStoreProbe(tostring(prefix) .. "/t5_prefix_auto=" .. missingScope .. "<-" .. sourceScope
        .. "/parts=" .. tostring(prefixInfo.parts) .. ">" .. tostring(prefixInfo.fullParts)
        .. "/last=" .. tostring(prefixInfo.lastTokens or "=") .. ">" .. tostring(prefixInfo.fullLastTokens or "=")
        .. "/mode=" .. tostring(prefixInfo.lastPrefixMode or "chunk")
        .. "/bytes=" .. tostring(prefixInfo.lastBytes or "=") .. ">" .. tostring(prefixInfo.fullLastBytes or "=")
        .. "/count=" .. tostring(#sourceRows) .. "/fp=" .. tostring(fingerprint))
    if fingerprint ~= nil and tostring(fingerprint) == tostring(stamped) then return candidate, recovered end
    return nil
end

local function RebuildHistoricalCanonical(decoded, stamped, current, raw)
    local meta = type(raw) == "table" and raw.__rsmeta or nil
    local schema = type(meta) == "table" and tonumber(meta.schema) or nil
    if type(meta) == "table" and meta.store == STORE_ID and meta.owner == "v3.buff_display"
        and tonumber(meta.framework) == 3 and schema == 8 then
        local base = NormalizeState(decoded)
        local store = P:GetStore(STORE_ID)
        local baseFp = type(P.FingerprintCanonicalValue) == "function" and P:FingerprintCanonicalValue(store, base) or nil
        local prefix = "schema8/base=" .. tostring(baseFp) .. "/old=" .. tostring(stamped)
        BuffDisplayStoreProbe(prefix)
        if tostring(baseFp) == tostring(stamped) then return base, Copy(decoded) end
        if type(decoded) ~= "table" or type(decoded.settings) ~= "table" or type(decoded.settings.tracked) ~= "table"
            or type(P.RebuildDenseSequenceForIntegrity) ~= "function" then
            BuffDisplayStoreProbe(prefix .. "/sequence=unavailable")
            return base, Copy(decoded)
        end

        -- .18.240：必须先处理“marker/count 已丢但 chunks 普通 map 仍能成功 transport decode”的
        -- T5 截断。若先进入下方 generic dense-sequence 修复，player.auto 会因为键名 `chunks`
        -- 立即得到 invalid_index 并提前返回，永远到不了 Store 专属物理前缀证据。
        if tonumber(meta.transportVersion) == 5 then
            local prefixCandidate, prefixDomain = RecoverTransport5ScopedAutoPrefix(decoded, stamped, raw, store, prefix)
            if type(prefixCandidate) == "table" and type(prefixDomain) == "table" then
                return prefixCandidate, prefixDomain
            end
            local scalarCandidate, scalarDomain = RecoverSchema8DistanceXTransport5Omission(decoded, stamped, current, raw, store, prefix)
            if type(scalarCandidate) == "table" and type(scalarDomain) == "table" then
                return scalarCandidate, scalarDomain
            end
        end
        local recovered, changes = Copy(decoded), 0
        for _, scope in ipairs(TRACKING_SCOPES) do
            local group = type(recovered.settings.tracked[scope]) == "table" and recovered.settings.tracked[scope] or nil
            if group ~= nil then
                for _, category in ipairs(TRACKING_CATEGORIES) do
                    if group[category] ~= nil then
                        local rows, reason, changed = P:RebuildDenseSequenceForIntegrity(group[category], 1024)
                        if rows == nil then
                            BuffDisplayStoreProbe(prefix .. "/sequence=" .. scope .. "." .. category .. ":" .. tostring(reason))
                            return base, Copy(decoded)
                        end
                        if changed then group[category] = rows; changes = changes + 1 end
                    end
                end
            end
        end
        if type(recovered.settings.trackedCooldowns) == "table" then
            for _, kind in ipairs({ "skill", "mate" }) do
                if recovered.settings.trackedCooldowns[kind] ~= nil then
                    local rows, reason, changed = P:RebuildDenseSequenceForIntegrity(recovered.settings.trackedCooldowns[kind], 256)
                    if rows == nil then
                        BuffDisplayStoreProbe(prefix .. "/sequence=cooldown." .. kind .. ":" .. tostring(reason))
                        return base, Copy(decoded)
                    end
                    if changed then recovered.settings.trackedCooldowns[kind] = rows; changes = changes + 1 end
                end
            end
        end
        -- 中文维护注释（2026-09-18，.18.239 Transport5 单侧字段省略恢复）：
        -- .238 实机已经证明 known-pair 本身成功（integrityFail=0 / v3Upgrade=1/1），但立即
        -- SaveData→LoadData 回读出现 `$.settings.tracked.player.auto.1: number vs nil`。Transport5
        -- 对“整个 scoped auto 字段被 Native 省略”不会产生 missing-chunk 错误：父表仍可合法解码，
        -- 随后 schema8 Normalize 才把 nil 变成空列表，因此旧的 chunk 级修复根本没有执行机会。
        -- Authority：这里只在 CURRENT schema8 + Framework3 + Transport5、player/target group 都存在、
        -- 且恰好一侧 `auto` **物理字段为 nil** 时，把另一侧完整 dense ID 列表作为单一候选。候选必须
        -- 重新 Normalize 整份 Store 并精确命中已经盖在磁盘上的 stamped canonical fingerprint；Hash 不命中
        -- 就继续 Fence/回读失败。不会把“空列表”当作缺失、不会修 buff/debuff、不会从 Catalog/Hash 猜 ID，
        -- 也不会 Apply/Save/Clear。这样用户合法把某一 scope 主动清空或让两 scope 分叉时不会被 twin 覆盖。
        -- 数据流：decoded(raw) -> 仅补一处 missing auto 候选 -> NormalizeState -> 全 Store fingerprint -> Core
        -- 再做预算/当前 canonical/Apply 或 readback proof。该分支只位于 Load/Save 冷路径，不进入 Tick/扫描循环。
        if tonumber(meta.transportVersion) == 5 then
            local tracked = recovered.settings.tracked
            local player = type(tracked.player) == "table" and tracked.player or nil
            local target = type(tracked.target) == "table" and tracked.target or nil
            local playerMissing = player ~= nil and player.auto == nil
            local targetMissing = target ~= nil and target.auto == nil
            if player ~= nil and target ~= nil and playerMissing ~= targetMissing then
                local missingScope = playerMissing and "player" or "target"
                local sourceScope = playerMissing and "target" or "player"
                local sourceAuto = tracked[sourceScope].auto
                local rows, twinReason, twinChanged = P:RebuildDenseSequenceForIntegrity(sourceAuto, 1024)
                local valid = type(rows) == "table" and twinChanged ~= true and #rows > 32
                if valid then
                    for index = 1, #rows do
                        local id = rows[index]
                        if type(id) ~= "number" or id < 1 or id ~= math.floor(id) then valid = false; break end
                    end
                end
                if valid then
                    local twinRecovered = Copy(recovered)
                    twinRecovered.settings.tracked[missingScope].auto = Copy(rows)
                    local twinCandidate = NormalizeState(twinRecovered)
                    local twinFp = P:FingerprintCanonicalValue(store, twinCandidate)
                    BuffDisplayStoreProbe(prefix .. "/t5_missing_auto=" .. missingScope .. "<-" .. sourceScope
                        .. "/count=" .. tostring(#rows) .. "/fp=" .. tostring(twinFp))
                    if twinFp ~= nil and tostring(twinFp) == tostring(stamped) then
                        return twinCandidate, twinRecovered
                    end
                else
                    BuffDisplayStoreProbe(prefix .. "/t5_missing_auto_reject=" .. missingScope .. "<-" .. sourceScope
                        .. "/reason=" .. tostring(twinReason or (twinChanged == true and "string_index" or "shape")))
                end
            end
        end

        if changes == 0 then
            BuffDisplayStoreProbe(prefix .. "/sequence=unchanged")
            if type(P.RebuildFixed6WindowCanonical) == "function" then
                local candidate, domain = P:RebuildFixed6WindowCanonical(store, decoded, stamped, base, raw, schema, nil)
                if candidate ~= nil then return candidate, domain end
            end
            return base, Copy(decoded)
        end
        local candidate = NormalizeState(recovered)
        BuffDisplayStoreProbe(prefix .. "/sequence=" .. tostring(changes) .. "/seqfp=" .. tostring(P:FingerprintCanonicalValue(store, candidate)))
        return candidate, recovered
    end
    return RebuildHistoricalCanonicalSchema7Final(decoded, stamped, current, raw)
end

local function MigrateState(value, fromSchema)
    -- 中文维护注释（schema8 current-canonical 边界）：Persistence 会把 migrate(value)（不传 fromSchema）
    -- 同时用作“当前 Domain -> canonical”的纯归一化器。这里绝不能把 nil 当成 0；否则 schema8 已经是
    -- player/target 六通道的值会再次送进 schema7 legacy migrator，嵌套追踪被当成旧全局列表并清空，
    -- 保存时指纹反而给“空追踪”盖章，下一次 Load 会合法地丢失整份追踪。只有 Core 明确传入
    -- fromSchema<8 时才有旧代迁移 Authority；nil/8+ 永远只做当前 schema8 Normalize。
    local sourceSchema = tonumber(fromSchema)
    if sourceSchema == nil or sourceSchema >= 8 then return NormalizeState(value) end
    -- First let the frozen legacy migrator rebuild every pre-schema8 field (HUD/library/cooldowns),
    -- then convert only tracking representation. This keeps migration ownership single and ordered.
    local legacy = MigrateStateSchema7(value, sourceSchema)
    local out = NormalizeState(legacy)
    out.settings.tracked = NormalizeTrackedScopes(type(legacy.settings) == "table" and legacy.settings.tracked or nil)
    return out
end

-- 中文维护注释（2026-09-17，schema8/v4 实机缺块恢复）：
-- 实机报告明确：schema7->8 迁移写回后，SaveData 立即回读在 transport4 的 pN 分块上
-- 出现 missing_chunk。schema8 的迁移语义会把旧全局追踪“逐字复制”到 player/target；因此
-- 对这一次物理事故，另一 scope 是唯一可验证冗余来源。这里只修 physical raw，不碰 Domain。
-- 安全边界：仅 Framework3 + schema8 + transport4 + 当前 Store/owner + missing_chunk_v4。
-- 单侧损坏优先使用完整 twin；若两个迁移副本同段都丢失，只允许由已持久化 importedPacks 对应
-- 的只读 Catalog 构造有限候选，并要求 count 与所有尚存 chunk 逐字一致。Core 随后必须重新
-- transport decode，并继续通过原 Envelope/业务 fingerprint、预算、migrate/apply 全部门禁；
-- 任一不匹配仍 fail-closed，不从 Hash 反推未知 ID，也不以目录覆盖用户配置。
local function RecoverSchema8ScopedTransport4(raw, transportError)
    if type(raw) ~= "table" or not tostring(transportError or ""):find("transport_vector_missing_chunk_v4", 1, true) then
        return nil, "not_schema8_missing_chunk_v4"
    end
    local meta = type(raw.__rsmeta) == "table" and raw.__rsmeta or nil
    if type(meta) ~= "table" or tonumber(meta.framework) ~= 3 or tonumber(meta.schema) ~= 8
        or tonumber(meta.transportVersion) ~= 4 or tostring(meta.store or "") ~= STORE_ID
        or tostring(meta.owner or "") ~= "v3.buff_display" then
        return nil, "transport4_identity_gate"
    end
    local payload = type(raw.payload) == "table" and raw.payload or nil
    local settings = payload and type(payload.settings) == "table" and payload.settings or nil
    local tracked = settings and type(settings.tracked) == "table" and settings.tracked or nil
    local player = tracked and type(tracked.player) == "table" and tracked.player or nil
    local target = tracked and type(tracked.target) == "table" and tracked.target or nil
    if player == nil or target == nil then return nil, "scoped_tracking_missing" end
    -- 中文维护注释（2026-09-18，.18.235 候选回退基线）：物理恢复会原地修改 raw。
    -- 保存一份仅限本次失败 Load 的深拷贝，后续若“健康 twin”能解码但无法命中旧业务指纹，
    -- 需要从事故原貌重新构造 Catalog 候选，不能在已被错误 twin 填过的表上继续叠加修改。
    -- Authority 仍属于 Core：此副本只用于候选生成，不 Apply、不 SaveData、不清除 write fence。
    local originalRaw = Copy(raw)

    local marker, chunkSize, limit = "__rs_t4:a", 16, 2048
    -- 中文维护注释（2026-09-17，.18.233 物理损坏审计）：
    -- .232 实机已经证明“存在的 chunk”本身也可能被 Native 截短：player.auto.p5 只剩 10/16
    -- 个 token。旧 InspectVector 只统计 pN 是否存在，把这种半截字符串当成健康 present，导致连续
    -- 三轮恢复一直围绕 missing chunk 猜候选。这里严格复用 Transport4 decoder 的块级规则做只读
    -- 审计，记录 bad chunk；不把 bad 自动当成 missing、不修改恢复接受条件、不写盘。Authority 仍是
    -- Core DecodePhysicalEnvelope + fingerprint；本函数只让诊断能区分“字段丢失”和“字段内容截断”。
    local function AuditChunk(index, text, count)
        if type(text) ~= "string" then return false, "type" end
        local expected = math.min(chunkSize, count - (index - 1) * chunkSize)
        if #text > 143 then return false, "len" .. tostring(#text) .. "/143" end
        if not text:match("^[1-9]%d*[,0-9]*$") then return false, "syntax" end
        local tokens, rebuilt = {}, {}
        for token in text:gmatch("[^,]+") do
            local n = tonumber(token)
            if not n or n < 1 or n > 9007199254740991 or n ~= math.floor(n)
                or string.format("%.0f", n) ~= token then
                return false, "token" .. tostring(#tokens + 1)
            end
            tokens[#tokens + 1] = token
            rebuilt[#rebuilt + 1] = token
            if #tokens > expected then return false, "count" .. tostring(#tokens) .. "/" .. tostring(expected) end
        end
        if #tokens ~= expected or table.concat(rebuilt, ",") ~= text then
            return false, "count" .. tostring(#tokens) .. "/" .. tostring(expected)
        end
        return true, nil
    end
    local function InspectVector(value)
        if type(value) ~= "table" or value[marker] ~= 1 then return nil, "not_vector" end
        local count = value.count
        if type(count) ~= "number" or count ~= math.floor(count) or count <= 32 or count > limit then return nil, "header" end
        local parts = math.ceil(count / chunkSize)
        local present, missing, bad, fields = {}, {}, {}, 0
        for key, text in pairs(value) do
            fields = fields + 1
            if key ~= marker and key ~= "count" then
                local n = type(key) == "string" and tonumber(key:match("^p([1-9]%d*)$")) or nil
                if n == nil or n > parts or type(text) ~= "string" then return nil, "extra_or_type" end
                if present[n] ~= nil then return nil, "duplicate" end
                present[n] = text
                local healthy, why = AuditChunk(n, text, count)
                if healthy ~= true then bad[n] = tostring(why or "invalid") end
            end
        end
        for i = 1, parts do if present[i] == nil then missing[#missing + 1] = i end end
        return { value = value, count = count, parts = parts, present = present, missing = missing, bad = bad, fields = fields }, nil
    end
    -- 中文维护注释（2026-09-17，.18.234 RU 实机物理恢复）：
    -- .233 已经给出完整证据：player.auto 缺 p1/p2/p3/p4/p19，且 p5 仅剩 10/16；
    -- target.auto 同 count/parts 下 25 个 chunk 全部健康，双方所有健康重叠块相同，唯一差异 p5
    -- 恰好是 player 的截短块，且其 10 个 token 是 target.p5 的严格前缀。旧 SameExisting 把
    -- “已知损坏块”也参与等值比较，因此错误拒绝了最强的冗余 Authority，反而落到 Catalog 猜测。
    -- 新规则只允许：source 整体物理健康；damaged 的所有健康块逐字等于 source；bad 块只能是
    -- count 截短且必须是 source 对应块的规范 token 前缀。候选生成后 Core 仍会用原始 envelope /
    -- canonical fingerprint 对整份逻辑值验真，所以 schema8 用户若曾合法让 player/target 在丢失块
    -- 内分叉，错误 twin 候选会被旧指纹拒绝并继续 Fence；这里没有获得绕过业务 Authority 的权限。
    local function HasBadChunks(info)
        return type(info) == "table" and type(info.bad) == "table" and next(info.bad) ~= nil
    end
    local function IsVectorHealthy(info)
        return type(info) == "table" and #info.missing == 0 and not HasBadChunks(info)
    end
    local function IsStrictChunkPrefix(prefix, full)
        if type(prefix) ~= "string" or type(full) ~= "string" or #prefix >= #full then return false end
        if full:sub(1, #prefix) ~= prefix then return false end
        return full:sub(#prefix + 1, #prefix + 1) == ","
    end
    local function CanRepairFromHealthyTwin(damaged, source)
        if type(damaged) ~= "table" or not IsVectorHealthy(source) then return false end
        if damaged.count ~= source.count or damaged.parts ~= source.parts then return false end
        if #damaged.missing == 0 and not HasBadChunks(damaged) then return false end
        local missing = {}; for _, index in ipairs(damaged.missing) do missing[index] = true end
        for index = 1, damaged.parts do
            local src = source.present[index]
            if type(src) ~= "string" then return false end
            if missing[index] then
                -- Whole chunk disappeared: no local bytes remain to compare. Final fingerprint is the Authority.
            elseif damaged.bad[index] ~= nil then
                local why = tostring(damaged.bad[index])
                local localText = damaged.present[index]
                -- Only the observed RU truncation shape is repairable from a twin. Syntax/token corruption remains fenced.
                if not why:match("^count%d+/%d+$") or not IsStrictChunkPrefix(localText, src) then return false end
            elseif damaged.present[index] ~= src then
                return false
            end
        end
        return true
    end
    local function RepairFromHealthyTwin(damaged, source)
        if not CanRepairFromHealthyTwin(damaged, source) then return false, 0 end
        local touched = {}; for _, index in ipairs(damaged.missing) do touched[index] = true end
        for index in pairs(damaged.bad or {}) do touched[index] = true end
        local repairs = 0
        for index in pairs(touched) do
            damaged.value["p" .. tostring(index)] = source.present[index]
            repairs = repairs + 1
        end
        return repairs > 0, repairs
    end
    -- 维护（.18.229，双 scope 同段丢失）：.228 只允许“另一 scope 完整”时复制缺块，
    -- 但实机 .227→.228 证明两个迁移副本可能在各自 v4 表里同时丢掉同一个 pN；此时 twin
    -- 也没有完整来源。我们仍禁止从 Hash 反推 ID。唯一新增候选来自 Store 已保存的
    -- library.importedPacks + 只读 StatusTrackingCatalogV3：只有候选长度与 vector.count 完全相同、
    -- 所有尚存 chunk 逐字匹配时，才可填补缺段；随后 Core 仍会用原 envelopeFingerprint 与
    -- encodedFingerprint 对整份候选做双重验真。用户手工增删/不同 scope/目录版本不匹配都会
    -- 让候选失败并保持写保护，因此这不是“用内置库覆盖用户配置”。
    local function BuildCatalogCandidates()
        local library = settings and type(settings.library) == "table" and settings.library or nil
        local imported = library and type(library.importedPacks) == "table" and library.importedPacks or nil
        local catalog = S.Data and S.Data.StatusTrackingCatalogV3 or nil
        if imported == nil or type(catalog) ~= "table" or type(catalog.Packs) ~= "table" then
            return nil, "catalog_unavailable"
        end
        local lists = { buff = {}, debuff = {}, auto = {} }
        local seen = { buff = {}, debuff = {}, auto = {} }
        local keys = {}
        for key, version in pairs(imported) do
            local v = tonumber(version)
            if type(key) == "string" and v ~= nil and v > 0 and type(catalog.Packs[key]) == "table" then
                keys[#keys + 1] = key
            end
        end
        table.sort(keys)
        if #keys == 0 then return nil, "catalog_no_imported_pack" end
        for _, key in ipairs(keys) do
            local pack = catalog.Packs[key]
            local importedVersion = tonumber(imported[key]) or 0
            for _, entry in ipairs(type(pack.entries) == "table" and pack.entries or {}) do
                if type(entry) == "table" and entry.kind == "effect"
                    and (tonumber(entry.introducedVersion) or 0) <= importedVersion then
                    local id = math.floor(tonumber(entry.id) or 0)
                    local category = entry.category
                    if category ~= "buff" and category ~= "debuff" then category = "auto" end
                    if id > 0 and seen[category][id] ~= true then
                        seen[category][id] = true
                        lists[category][#lists[category] + 1] = id
                    end
                end
            end
        end
        for _, category in ipairs({ "buff", "debuff", "auto" }) do table.sort(lists[category]) end
        return lists, table.concat(keys, ",")
    end

    local catalogCandidates, catalogProbe
    local singlePackCache = {}
    local function BuildSinglePackCandidates(packKey, maxVersion)
        local catalog = S.Data and S.Data.StatusTrackingCatalogV3 or nil
        local pack = catalog and type(catalog.Packs) == "table" and catalog.Packs[packKey] or nil
        if type(pack) ~= "table" or type(pack.entries) ~= "table" then return nil, "pack_unavailable:" .. tostring(packKey) end
        local lists = { buff = {}, debuff = {}, auto = {} }
        local seen = { buff = {}, debuff = {}, auto = {} }
        for _, entry in ipairs(pack.entries) do
            if type(entry) == "table" and entry.kind == "effect"
                and (maxVersion == nil or (tonumber(entry.introducedVersion) or 0) <= maxVersion) then
                local id = math.floor(tonumber(entry.id) or 0)
                local category = entry.category
                if category ~= "buff" and category ~= "debuff" then category = "auto" end
                if id > 0 and seen[category][id] ~= true then
                    seen[category][id] = true
                    lists[category][#lists[category] + 1] = id
                end
            end
        end
        for _, category in ipairs({ "buff", "debuff", "auto" }) do table.sort(lists[category]) end
        return lists, tostring(packKey)
    end
    local function GetSinglePackCandidates(packKey, maxVersion)
        local cacheKey = tostring(packKey) .. "@" .. tostring(maxVersion or "current")
        if singlePackCache[cacheKey] ~= nil then return singlePackCache[cacheKey] end
        local lists = BuildSinglePackCandidates(packKey, maxVersion)
        singlePackCache[cacheKey] = lists or false
        return lists
    end
    local function IsSubset(base, candidate)
        if type(base) ~= "table" or type(candidate) ~= "table" then return false end
        local set = {}; for _, id in ipairs(candidate) do set[id] = true end
        for _, id in ipairs(base) do if set[id] ~= true then return false end end
        return true
    end
    local function BuildExpectedChunks(ids)
        local expected = {}
        for first = 1, #ids, chunkSize do
            local tokens = {}
            for i = first, math.min(#ids, first + chunkSize - 1) do tokens[#tokens + 1] = string.format("%.0f", ids[i]) end
            expected[#expected + 1] = table.concat(tokens, ",")
        end
        return expected
    end
    local function CandidateMatchesExisting(info, expected, allowCountTruncated)
        for index = 1, info.parts do
            local text = info.present[index]
            if text ~= nil then
                local badReason = type(info.bad) == "table" and info.bad[index] or nil
                if allowCountTruncated == true and badReason ~= nil then
                    -- .18.235：Catalog 仅在“存在内容是候选完整 chunk 的严格规范前缀”时拥有修复
                    -- count 截断块的资格；syntax/token/长度异常仍拒绝。这样不会把任意坏字符串当 missing。
                    local wanted = expected[index]
                    if not tostring(badReason):match("^count%d+/%d+$")
                        or not IsStrictChunkPrefix(text, wanted) then return false, index end
                elseif expected[index] ~= text then
                    return false, index
                end
            end
        end
        return true, nil
    end
    -- 中文维护注释（2026-09-17，.18.232 深度取证，不改变恢复 Authority）：
    -- .228-.231 连续实机均停在 missing_chunk_v4，而“no_candidate”只能证明静态候选没有命中，
    -- 不能回答到底缺哪一块、player/target 幸存区是否一致、同 count 候选从第几块开始偏离。
    -- 这组 helper 只序列化本次失败 Load 已经在内存中的 v4 物理事实；不重新 LoadData、不写盘、
    -- 不尝试新候选，也不把诊断字符串参与 fingerprint。每个 chunk 本来就被 Transport4 限制为
    -- <=143 bytes，因此只记录首个不一致 chunk 的原文/期望值，整体仍有显式长度上限。
    local function ClipRecoveryProbe(value, limitBytes)
        local text = tostring(value or "")
        local limit = tonumber(limitBytes) or 180
        if #text <= limit then return text end
        return text:sub(1, math.max(0, limit - 12)) .. "<cut:" .. tostring(#text) .. ">"
    end
    local function MissingChunkText(info)
        if type(info) ~= "table" or type(info.missing) ~= "table" or #info.missing == 0 then return "-" end
        local out = {}
        for i, index in ipairs(info.missing) do
            if i > 12 then out[#out + 1] = "+" .. tostring(#info.missing - 12); break end
            out[#out + 1] = "p" .. tostring(index)
        end
        return table.concat(out, ",")
    end
    local function IndexListText(values, maxItems)
        local out = {}
        local n = 0
        for index, enabled in pairs(values or {}) do
            if enabled then out[#out + 1] = tonumber(index) or index end
        end
        table.sort(out, function(a,b) return tonumber(a) < tonumber(b) end)
        local text = {}
        for _, index in ipairs(out) do
            n = n + 1
            if n > (maxItems or 12) then text[#text + 1] = "+" .. tostring(#out - (maxItems or 12)); break end
            text[#text + 1] = tostring(index)
        end
        return #text > 0 and table.concat(text, ",") or "-"
    end
    local function BadChunkText(info)
        if type(info) ~= "table" or type(info.bad) ~= "table" then return "-" end
        local keys = {}; for index in pairs(info.bad) do keys[#keys + 1] = index end
        table.sort(keys)
        local out = {}
        for i, index in ipairs(keys) do
            if i > 8 then out[#out + 1] = "+" .. tostring(#keys - 8); break end
            out[#out + 1] = tostring(index) .. ":" .. tostring(info.bad[index])
        end
        return #out > 0 and table.concat(out, ",") or "-"
    end
    local function MissingIndexText(info)
        if type(info) ~= "table" or type(info.missing) ~= "table" or #info.missing == 0 then return "-" end
        local out = {}; for _, index in ipairs(info.missing) do out[#out + 1] = tostring(index) end
        return table.concat(out, ",")
    end
    local function VectorAudit(label, info)
        if type(info) ~= "table" then return tostring(label) .. "=unavailable" end
        return tostring(label) .. "=c" .. tostring(info.count) .. "/p" .. tostring(info.parts)
            .. "/m=" .. MissingIndexText(info) .. "/b=" .. BadChunkText(info)
    end
    local function DescribeTwinVectors(a, b, category)
        if type(a) ~= "table" or type(b) ~= "table" then return "unavailable" end
        local label = tostring(category or "?")
        if a.count ~= b.count or a.parts ~= b.parts then
            return "shape_diff:" .. tostring(a.count) .. "/" .. tostring(a.parts) .. ">" .. tostring(b.count) .. "/" .. tostring(b.parts)
                .. "/" .. VectorAudit("P" .. label, a) .. "/" .. VectorAudit("T" .. label, b)
        end
        local diffSet, firstDiff = {}, nil
        for index = 1, a.parts do
            local av, bv = a.present[index], b.present[index]
            if av ~= nil and bv ~= nil and av ~= bv then diffSet[index] = true; firstDiff = firstDiff or index end
        end
        local prefix = firstDiff and ("diff:p" .. tostring(firstDiff)) or "overlap_equal"
        local out = prefix .. "/" .. VectorAudit("P" .. label, a) .. "/" .. VectorAudit("T" .. label, b)
            .. "/twinDiff=" .. IndexListText(diffSet, 12)
        if firstDiff then
            out = out .. "/p" .. tostring(firstDiff) .. "P=" .. ClipRecoveryProbe(a.present[firstDiff], 210)
                .. "/p" .. tostring(firstDiff) .. "T=" .. ClipRecoveryProbe(b.present[firstDiff], 210)
        end
        return ClipRecoveryProbe(out, 1100)
    end
    local function FillExpectedChunks(info, expected, sourceName, category, scope, allowCountTruncated)
        local touched = {}
        for _, index in ipairs(info.missing) do touched[index] = true end
        if allowCountTruncated == true then
            for index, reason in pairs(info.bad or {}) do
                -- CandidateMatchesExisting 已经证明只有 count 截断 + 严格前缀能够走到这里；再次限制
                -- reason 形状，避免以后 helper 被其它调用点复用时扩大 Store 的修复 Authority。
                if tostring(reason):match("^count%d+/%d+$") then touched[index] = true end
            end
        end
        local repaired = 0
        for index in pairs(touched) do
            local text = expected[index]
            if type(text) ~= "string" then return false, tostring(sourceName) .. "_chunk_missing:" .. scope .. "." .. category .. ":" .. tostring(index) end
            info.value["p" .. tostring(index)] = text
            repaired = repaired + 1
        end
        return true, repaired
    end

    -- 中文维护注释（.18.231，恢复 Authority 修正）：
    -- importedPacks 只记录“这个包曾经导入到哪个版本”，用户之后可以逐条取消追踪；因此它绝不能
    -- 充当“当前追踪集合”的 Authority。此前 .228-.230 把所有水位包先做 union，再拿 union.count
    -- 与损坏 vector.count 比较，导致真实 all=393 + hidden 水位场景被错误重建为 397 候选并永久拒绝。
    -- 这里改为有限候选枚举：union 只是候选之一；每个已知静态包也是独立候选；all/recommended
    -- 作为历史主入口也可单独参与。候选必须同时满足 count 与所有尚存 pN chunk 逐字一致；若多个
    -- 候选的完整 chunk 表不同则拒绝为 ambiguous。真正的最终 Authority 仍在 Core：返回候选后还要
    -- 重新 transport decode，并通过原 encoded/envelope fingerprint、schema、budget、migrate/apply。
    -- 所以这里既不根据水位补回用户已取消 ID，也不从 Hash 反推未知 ID。
    local function RepairFromCatalog(info, category, scope, twinProbe, allowCountTruncated)
        local hasRepairableBad = allowCountTruncated == true and HasBadChunks(info)
        if info == nil or (#info.missing == 0 and not hasRepairableBad) then return true end
        if catalogCandidates == nil then
            catalogCandidates, catalogProbe = BuildCatalogCandidates()
            if catalogCandidates == nil then return false, catalogProbe end
        end

        local catalog = S.Data and S.Data.StatusTrackingCatalogV3 or nil
        local imported = settings and type(settings.library) == "table" and type(settings.library.importedPacks) == "table"
            and settings.library.importedPacks or {}
        local matches, seenRepresentations, countNotes, mismatchNotes = {}, {}, {}, {}
        local function Consider(name, ids)
            if type(ids) ~= "table" then return end
            countNotes[#countNotes + 1] = tostring(name) .. "=" .. tostring(#ids)
            if #ids ~= info.count then return end
            local expected = BuildExpectedChunks(ids)
            local ok, mismatchIndex = CandidateMatchesExisting(info, expected, allowCountTruncated)
            if ok then
                local signature = table.concat(expected, "|")
                if seenRepresentations[signature] == nil then
                    seenRepresentations[signature] = true
                    matches[#matches + 1] = { name = tostring(name), expected = expected }
                end
            elseif #mismatchNotes < 3 then
                local disk = mismatchIndex and info.present[mismatchIndex] or nil
                local want = mismatchIndex and expected[mismatchIndex] or nil
                mismatchNotes[#mismatchNotes + 1] = "sameCount=" .. tostring(name)
                    .. ":mis=p" .. tostring(mismatchIndex or "?")
                    .. ":disk=" .. ClipRecoveryProbe(disk, 180)
                    .. ":want=" .. ClipRecoveryProbe(want, 180)
            end
        end

        -- 兼容旧恢复行为：导入水位 union 仍是一个候选，但不再垄断恢复结论。
        Consider("union", catalogCandidates[category])

        -- 每个已记录水位包都独立尝试；这是这次 393 实机故障的关键：all=393 即使和 hidden
        -- 水位共同存在，也必须保留为单独候选，而不是先被合并成 397。
        local importedKeys = {}
        for key, version in pairs(imported) do
            local v = tonumber(version)
            if type(key) == "string" and v ~= nil and v > 0 and catalog and type(catalog.Packs) == "table"
                and type(catalog.Packs[key]) == "table" then
                importedKeys[#importedKeys + 1] = key
            end
        end
        table.sort(importedKeys)
        for _, key in ipairs(importedKeys) do
            local lists = GetSinglePackCandidates(key, tonumber(imported[key]))
            Consider("pack:" .. key, lists and lists[category] or nil)
        end

        -- 历史状态管理主入口在不同时期由 all/recommended 承担。即便水位表后来因为用户操作或
        -- 版本迁移不再能代表当前选择，这两份静态集合也只作为候选参与；count+幸存 chunk 不匹配
        -- 会立即排除，最终错误候选还会被 Core 原 fingerprint 拒绝。
        for _, key in ipairs({ "all", "recommended" }) do
            local lists = GetSinglePackCandidates(key, nil)
            Consider("pack:" .. key, lists and lists[category] or nil)
        end

        -- 保留 .230 的“all 水位 -> recommended 超集”语义，但现在它只是普通候选，不能覆盖
        -- count 恰好命中 all 的 393 场景，也不能因为先遇到 union count mismatch 就提前返回。
        local allVersion = tonumber(imported.all)
        if allVersion ~= nil and allVersion > 0 then
            local base = GetSinglePackCandidates("all", allVersion)
            local rec = GetSinglePackCandidates("recommended", allVersion)
            local baseIds, recIds = base and base[category] or nil, rec and rec[category] or nil
            if IsSubset(baseIds or {}, recIds or {}) then Consider("recommended_fallback", recIds) end
        end

        if #matches == 0 then
            local detail = "catalog_no_candidate:" .. scope .. "." .. category
                .. "|bucket=" .. scope .. "." .. category
                .. "/count=" .. tostring(info.count)
                .. "/parts=" .. tostring(info.parts)
                .. "/missing=" .. MissingChunkText(info)
                .. "/present=" .. tostring(info.parts - #info.missing)
                .. "/twin=" .. tostring(twinProbe or "-")
                .. "/packs=" .. ClipRecoveryProbe(catalogProbe or "-", 220)
            if #mismatchNotes > 0 then detail = detail .. "/" .. table.concat(mismatchNotes, ";") end
            detail = detail .. "/counts=" .. ClipRecoveryProbe(table.concat(countNotes, ","), 420)
            return false, ClipRecoveryProbe(detail, 1500)
        end
        if #matches > 1 then
            local names = {}; for _, row in ipairs(matches) do names[#names + 1] = row.name end
            return false, "catalog_ambiguous:" .. scope .. "." .. category .. ":" .. table.concat(names, ",")
        end
        local chosen = matches[1]
        local ok, filled = FillExpectedChunks(info, chosen.expected, chosen.name, category, scope, allowCountTruncated)
        if ok then
            catalogProbe = (tostring(catalogProbe or "") .. "+" .. tostring(chosen.name)):gsub("^%+", "")
            return true, filled
        end
        return false, filled
    end

    -- 中文维护注释（2026-09-18，.18.235 Twin 候选指纹回退）：
    -- .18.234 实机证明“完整 target twin”可能与损坏 player 在已经丢失的 chunk 内存在合法 scope 分叉。
    -- 此时 twin 能通过 Transport4 解码，却会得到与旧 encodedFingerprint 不同的业务值。这里允许 Store
    -- 在故障冷路径预计算候选的 canonical fingerprint，仅用于“选哪个候选交给 Core”；它没有验收权限。
    -- Core 后续仍会重新 DecodePhysicalEnvelope、验证 Envelope Seal / schema / 原 fingerprint / budget / migrate / Apply。
    local stampedFingerprint = tostring(meta.encodedFingerprint or meta.payloadFingerprint or "")
    local function CandidateFingerprint(candidateRaw)
        local store = P:GetStore(STORE_ID)
        if type(store) ~= "table" then return nil, "store_unavailable" end
        local logical, decodeErr = P:DecodePhysicalEnvelope(Copy(candidateRaw))
        if type(logical) ~= "table" then return nil, "decode:" .. tostring(decodeErr) end
        local candidatePayload = type(logical.payload) == "table" and logical.payload or nil
        if candidatePayload == nil then return nil, "payload_missing" end
        local canonical, canonicalErr = P:CanonicalIntegrityValue(store, candidatePayload)
        if type(canonical) ~= "table" then return nil, "canonical:" .. tostring(canonicalErr) end
        return P:FingerprintCanonicalValue(store, canonical)
    end

    -- 从事故原始 raw 构造“Catalog 优先”的第二种确定性候选。只有缺块与 count 截断块可由
    -- 静态集合补齐；每个健康幸存 chunk 必须逐字匹配，截断块还必须是完整候选的严格 token 前缀。
    -- 该候选若不能精确命中存档旧指纹，绝不返回；调用方继续保留 .234 的 twin 候选并让 Core Fence。
    local function BuildExactCatalogFallback()
        local candidate = Copy(originalRaw)
        local cPayload = type(candidate.payload) == "table" and candidate.payload or nil
        local cSettings = cPayload and type(cPayload.settings) == "table" and cPayload.settings or nil
        local cTracked = cSettings and type(cSettings.tracked) == "table" and cSettings.tracked or nil
        local cPlayer = cTracked and type(cTracked.player) == "table" and cTracked.player or nil
        local cTarget = cTracked and type(cTracked.target) == "table" and cTracked.target or nil
        if cPlayer == nil or cTarget == nil then return nil, "fallback_scopes_missing" end

        local fallbackRepairs, fallbackKinds = 0, {}
        for _, category in ipairs({ "buff", "debuff", "auto" }) do
            local a = InspectVector(cPlayer[category])
            local b = InspectVector(cTarget[category])
            local aDamaged = a ~= nil and (#a.missing + (HasBadChunks(a) and 1 or 0)) or 0
            local bDamaged = b ~= nil and (#b.missing + (HasBadChunks(b) and 1 or 0)) or 0
            if aDamaged > 0 then
                local twinProbe = DescribeTwinVectors(a, b, category)
                local ok, value = RepairFromCatalog(a, category, "player", twinProbe, true)
                if not ok then return nil, "fallback_player_" .. tostring(value) end
                fallbackRepairs = fallbackRepairs + (tonumber(value) or 0)
                fallbackKinds[#fallbackKinds + 1] = "catalog:player." .. category
            end
            if bDamaged > 0 then
                local twinProbe = DescribeTwinVectors(a, b, category)
                local ok, value = RepairFromCatalog(b, category, "target", twinProbe, true)
                if not ok then return nil, "fallback_target_" .. tostring(value) end
                fallbackRepairs = fallbackRepairs + (tonumber(value) or 0)
                fallbackKinds[#fallbackKinds + 1] = "catalog:target." .. category
            end
        end
        if fallbackRepairs <= 0 then return nil, "fallback_no_repairs" end
        return candidate, table.concat(fallbackKinds, ",")
    end

    local repairs, repairKinds = 0, {}
    for _, category in ipairs({ "buff", "debuff", "auto" }) do
        local a = InspectVector(player[category])
        local b = InspectVector(target[category])
        local aMissing = a ~= nil and #a.missing or 0
        local bMissing = b ~= nil and #b.missing or 0
        local aDamaged = a ~= nil and (aMissing + (HasBadChunks(a) and 1 or 0)) or 0
        local bDamaged = b ~= nil and (bMissing + (HasBadChunks(b) and 1 or 0)) or 0

        -- schema8 在迁移后“初始”两 scope 相同，但用户随后允许独立修改；完整 bucket 的差异合法。
        -- .234 只在“一侧物理完整、另一侧的健康块全部吻合，bad 块还是完整侧的严格截短前缀”时
        -- 生成 twin 候选。它仍只是候选：Core 原始 fingerprint 才决定是否能真正应用。
        if aDamaged > 0 or bDamaged > 0 then
            local twinProbe = DescribeTwinVectors(a, b, category)
            local twinRepaired = false
            if aDamaged > 0 and bDamaged == 0 then
                local ok, count = RepairFromHealthyTwin(a, b)
                if ok then
                    repairs = repairs + count
                    repairKinds[#repairKinds + 1] = "twin:player." .. category
                    twinRepaired = true
                end
            elseif bDamaged > 0 and aDamaged == 0 then
                local ok, count = RepairFromHealthyTwin(b, a)
                if ok then
                    repairs = repairs + count
                    repairKinds[#repairKinds + 1] = "twin:target." .. category
                    twinRepaired = true
                end
            end
            if not twinRepaired then
                -- Catalog recovery still only owns wholly missing chunks. Malformed-present chunks have no static
                -- recovery authority; if no healthy twin can prove them, stay fenced instead of rewriting bytes.
                if HasBadChunks(a) or HasBadChunks(b) then
                    return nil, "twin_repair_unproven:" .. tostring(category) .. "|" .. tostring(twinProbe)
                end
                if aMissing > 0 then
                    local ok, value = RepairFromCatalog(a, category, "player", twinProbe)
                    if not ok then return nil, "catalog_repair_failed:" .. tostring(value) end
                    repairs = repairs + (tonumber(value) or 0); repairKinds[#repairKinds + 1] = "catalog:player." .. category
                end
                if bMissing > 0 then
                    local ok, value = RepairFromCatalog(b, category, "target", twinProbe)
                    if not ok then return nil, "catalog_repair_failed:" .. tostring(value) end
                    repairs = repairs + (tonumber(value) or 0); repairKinds[#repairKinds + 1] = "catalog:target." .. category
                end
            end
        end
    end
    if repairs <= 0 then return nil, "no_repairable_scope_or_catalog_candidate" end

    local primaryFingerprint, primaryFingerprintErr = CandidateFingerprint(raw)
    if stampedFingerprint ~= "" and tostring(primaryFingerprint or "") == stampedFingerprint then
        return raw, "schema8_v4/repairs=" .. tostring(repairs) .. "/" .. table.concat(repairKinds, ",")
            .. "/fp=primary_exact" .. (catalogProbe and ("/packs=" .. tostring(catalogProbe)) or "")
    end

    -- 只有“第一候选可解码但旧指纹不匹配”才值得尝试 Catalog 备选；这正是 .18.234 实机
    -- fp=old>wrongTwin / hook=candidate / seq=unchanged 的形状。若没有旧章或指纹计算本身失败，
    -- 不扩大恢复面，继续把 primary 交回 Core 按原规则拒绝。
    local fallbackProbe = nil
    if stampedFingerprint ~= "" and primaryFingerprint ~= nil then
        local fallbackRaw, fallbackKindsOrErr = BuildExactCatalogFallback()
        if fallbackRaw ~= nil then
            local fallbackFingerprint, fallbackFingerprintErr = CandidateFingerprint(fallbackRaw)
            if tostring(fallbackFingerprint or "") == stampedFingerprint then
                return fallbackRaw, "schema8_v4/repairs=" .. tostring(repairs)
                    .. "/fallback_exact=" .. tostring(fallbackKindsOrErr)
                    .. "/primaryfp=" .. tostring(primaryFingerprint)
                    .. "/fallbackfp=" .. tostring(fallbackFingerprint)
                    .. (catalogProbe and ("/packs=" .. tostring(catalogProbe)) or "")
            end
            fallbackProbe = "fp=" .. tostring(fallbackFingerprint or ("err:" .. tostring(fallbackFingerprintErr)))
        else
            fallbackProbe = tostring(fallbackKindsOrErr)
        end
    end

    -- 保持 .234 的 fail-closed 行为：Catalog 备选没有精确命中时，不篡改为“最像”的数据；
    -- 仍返回原 primary 候选，让 Persistence Authority 在统一业务指纹门禁处拒绝并保持写保护。
    return raw, "schema8_v4/repairs=" .. tostring(repairs) .. "/" .. table.concat(repairKinds, ",")
        .. "/primaryfp=" .. tostring(primaryFingerprint or ("err:" .. tostring(primaryFingerprintErr)))
        .. (fallbackProbe and ("/fallback=" .. ClipRecoveryProbe(fallbackProbe, 360)) or "")
        .. (catalogProbe and ("/packs=" .. tostring(catalogProbe)) or "")
end

-- 中文维护注释（2026-09-18，schema8/Transport4 RU 已知事故恢复桥）：
-- 问题原因：实机 .18.237 完整 RAW_STORE 已证明 player.auto 的 p1/p2/p3/p4/p19
-- 物理缺失且 p5 仅剩 10/16，而 target.auto 25 个分块完整。Transport4 的健康 twin
-- 因而能生成完整 Domain，但当前 canonical=0EBC870A 与事故前盖章 2FBF9352 不同；旧 Hash
-- 本身无法反推出已经丢失的 player-only ID，继续扩大 Catalog/twin Authority 会误吞合法 scope 分叉。
-- Authority/数据流：repairPhysicalTransport 仍只生成候选；Persistence Core 仍是唯一完整性
-- Authority。这里仅复用 Core 已有 recoverKnownLegacyCanonical 最终桥，并且同时锁死旧章、当前章、
-- Framework/schema/transport、Store identity、物理修复成功标记、精确缺块拓扑和恢复后双 scope
-- 393 项同值形状。任一条件不同立即返回 nil，继续 Fence；绝不按“相似度”或 Hash 猜业务 ID。
-- 兼容边界：这是一次已观测 RU Transport4 事故的 bounded allowlist，不是 schema8 通用放行。
-- 恢复成功后 Core 会立即按当前 canonical 重盖章；Store 当前 transportVersion=5，后续 Flush
-- 会改写为 v5 数字 chunk 表，避免再次进入 v4 pN 字符串缺块路径。
-- 风险/维护：若未来再出现不同 old/new fingerprint、不同缺块或不同 scope 业务形状，必须先取得
-- 新完整报告并单独建事故证据，禁止把下列 gate 放宽成前缀/数量近似恢复。
local KNOWN_SCHEMA8_TRANSPORT4_TWIN_INCIDENT = {
    oldFingerprint = "2FBF9352",
    currentFingerprint = "0EBC870A",
    recoveryReason = "schema8_transport4_twin_known_pair_2FBF9352_0EBC870A",
    probeFragments = {
        "schema8_v4/repairs=6/twin:player.auto/primaryfp=0EBC870A",
        "fallback=fallback_player_catalog_no_candidate:player.auto|bucket=player.auto/count=393/parts=25",
        "missing=p1,p2,p3,p4,p19/present=20/twin=diff:p5",
        "Pauto=c393/p25/m=1,2,3,4,19/b=5:count10/16",
        "Tauto=c393/p25/m=-/b=-/twinDiff=5",
        "p5P=664,667,745,770,778,794,795,796,828,854",
        "p5T=664,667,745,770,778,794,795,796,828,854,855,856,857,877,883,886",
    },
}

local function SameDenseIds(a, b)
    if type(a) ~= "table" or type(b) ~= "table" or #a ~= #b then return false end
    for i = 1, #a do
        if tonumber(a[i]) ~= tonumber(b[i]) then return false end
    end
    return true
end

local function RecoverKnownSchema8Transport4TwinIncident(decoded, stampedFingerprint, _currentCanonical, raw)
    local incident = KNOWN_SCHEMA8_TRANSPORT4_TWIN_INCIDENT
    if tostring(stampedFingerprint or "") ~= incident.oldFingerprint then return nil end

    local meta = type(raw) == "table" and raw.__rsmeta or nil
    if type(meta) ~= "table"
        or tostring(meta.store or "") ~= STORE_ID
        or tostring(meta.owner or "") ~= "v3.buff_display"
        or tonumber(meta.framework) ~= 3
        or tonumber(meta.contractVersion) ~= 3
        or tonumber(meta.integrityVersion) ~= 4
        or tonumber(meta.reliabilityContract) ~= 8
        or tonumber(meta.envelopeIntegrityVersion) ~= 1
        or tonumber(meta.schema) ~= 8
        or tonumber(meta.transportVersion) ~= 4
        or tostring(meta.encodedFingerprint or "") ~= incident.oldFingerprint then
        BuffDisplayStoreProbe("knownSchema8V4=" .. incident.oldFingerprint .. "/generation=reject/fw="
            .. tostring(meta and meta.framework) .. "/c=" .. tostring(meta and meta.contractVersion)
            .. "/iv=" .. tostring(meta and meta.integrityVersion) .. "/rel=" .. tostring(meta and meta.reliabilityContract)
            .. "/env=" .. tostring(meta and meta.envelopeIntegrityVersion) .. "/s=" .. tostring(meta and meta.schema)
            .. "/tv=" .. tostring(meta and meta.transportVersion) .. "/rawfp=" .. tostring(meta and meta.encodedFingerprint))
        return nil
    end

    local store = type(P.GetStore) == "function" and P:GetStore(STORE_ID) or nil
    local probe = type(store) == "table" and tostring(store.lastPhysicalTransportRepairProbe or "") or ""
    if type(store) ~= "table" or store.lastPhysicalTransportRepairOk ~= true then
        BuffDisplayStoreProbe("knownSchema8V4=" .. incident.oldFingerprint .. "/physical=reject")
        return nil
    end
    for _, fragment in ipairs(incident.probeFragments) do
        if probe:find(fragment, 1, true) == nil then
            BuffDisplayStoreProbe("knownSchema8V4=" .. incident.oldFingerprint .. "/probe=reject:" .. tostring(fragment))
            return nil
        end
    end

    local current = NormalizeState(decoded)
    local tracked = type(current.settings) == "table" and current.settings.tracked or nil
    local player = type(tracked) == "table" and tracked.player or nil
    local target = type(tracked) == "table" and tracked.target or nil
    local playerAuto = type(player) == "table" and player.auto or nil
    local targetAuto = type(target) == "table" and target.auto or nil
    if type(playerAuto) ~= "table" or type(targetAuto) ~= "table"
        or #playerAuto ~= 393 or #targetAuto ~= 393 or SameDenseIds(playerAuto, targetAuto) ~= true then
        BuffDisplayStoreProbe("knownSchema8V4=" .. incident.oldFingerprint .. "/shape=reject/player="
            .. tostring(type(playerAuto) == "table" and #playerAuto or -1) .. "/target="
            .. tostring(type(targetAuto) == "table" and #targetAuto or -1))
        return nil
    end

    local currentFingerprint = type(P.FingerprintCanonicalValue) == "function"
        and P:FingerprintCanonicalValue(store, current) or nil
    if tostring(currentFingerprint or "") ~= incident.currentFingerprint then
        BuffDisplayStoreProbe("knownSchema8V4=" .. incident.oldFingerprint .. "/current=reject:"
            .. tostring(currentFingerprint) .. "!=" .. incident.currentFingerprint)
        return nil
    end

    BuffDisplayStoreProbe("knownSchema8V4=" .. incident.oldFingerprint .. "/current="
        .. incident.currentFingerprint .. "/shape=393x2/probe=exact")
    return Copy(decoded), incident.recoveryReason
end

local function RecoverKnownBuffDisplayCanonical(decoded, stampedFingerprint, currentCanonical, raw)
    local recovered, reason = RecoverKnownSchema8Transport4TwinIncident(decoded, stampedFingerprint, currentCanonical, raw)
    if type(recovered) == "table" then return recovered, reason end
    return RecoverKnownSchema4SingleHud(decoded, stampedFingerprint, currentCanonical, raw)
end

F.StoreId, F.SchemaVersion = STORE_ID, SCHEMA
F.LayoutAuthorityContractVersion = 3
F.HudCalibrationContractVersion = 1
F.HudLayoutStoreId = HUD_LAYOUT_STORE_ID
F.HudLayoutStoreSchemaVersion = HUD_LAYOUT_STORE_SCHEMA
F.SettingsStoreId = SETTINGS_STORE_ID
F.TrackingManifestStoreId = TRACKING_MANIFEST_STORE_ID
F.TrackingPersistenceContractVersion = 1 -- .18.243: legacy monolith becomes migration-only; runtime tracking commits inactive player/target/meta slots before manifest.
F.LegacyStoreWriteProhibitedContractVersion = 1 -- hard maintenance fence: new code must never durable-save v3.buff_display after the split.
F.HudLayoutStoreContractVersion = 1 -- .18.241: HUD layout owns a small independent Account/Permanent Store; empty Store inherits the already-verified legacy main-store layout.
F.Schema5DualHudMigrationContractVersion = 1
F.Schema6TrackingMigrationContractVersion = 1
F.Schema7GearScoreFormatMigrationContractVersion = 1
F.Schema8TrackingScopeMigrationContractVersion = 1
F.Schema8Transport5RecoveryContractVersion = 8 -- .18.242: current-schema Transport5 recovery additionally accepts a final chunk cut inside a numeric token, but only as an exact byte-prefix candidate authenticated by the original whole-Store fingerprint.
F.Schema8Transport4RecoveryProbeContractVersion = 4 -- .18.235: wrong healthy-twin candidates may fall back to an exact old-fingerprint Catalog reconstruction; Core still re-verifies and remains final Authority.
F.Schema8KnownTransport4IncidentRecoveryContractVersion = 1 -- .18.238: exact 2FBF9352->0EBC870A + six-block RU incident only; Core restamps and Transport5 rewrites after acceptance.
F.Schema8Transport5ScopedOmissionRecoveryContractVersion = 1 -- .18.239: only one physically missing scoped auto field may borrow the intact twin when the entire current Store canonical exactly reproduces the stamped fingerprint.
F.Schema8Transport5ScopedPrefixRecoveryContractVersion = 2 -- .18.242: scoped auto residual recovery treats only the final surviving chunk as a strict byte prefix (token boundary or mid-token); all earlier chunks stay byte-equal and the rebuilt whole Store must exactly match the stamped fingerprint.
F.Schema8Transport5DistanceXOmissionRecoveryContractVersion = 1 -- .18.241: exact stamped fingerprint uniquely inverts only the proven omitted player distance.x integer in [-400,400]; no other field or tracking ID is guessed.
F.LayoutPersistenceBoundaryContractVersion = 3 -- .18.242 postmortem guard: every HUD-only calibration/copy/policy/reset/component mutation must remain isolated in v3.buff_display.layout; routing any of them back through MutateStore(v3.buff_display) is a regression because the monolithic tracking Store has proven lossy on RU.
F.TargetDefaultTemplateContractVersion = 1 -- verified TARGET|EQUIP release preset from HUD_TEMPLATE_V1
F.RangedWeaponReleaseDefaultContractVersion = 1 -- player ranged slot 18 defaults on; untouched v3 configs upgrade once to visual-order v4
F.State = NormalizeState(F.State)
F.StoreLoaded = F.StoreLoaded == true

local function ApplyState(value) F.State = NormalizeState(value) end
if P:GetStore(STORE_ID) == nil then
    local store, err = P:RegisterV3Store({
        id = STORE_ID, owner = "v3.buff_display", scope = P.Scope and P.Scope.Account or "account",
        lifetime = P.Lifetime and P.Lifetime.Permanent or "permanent", schemaVersion = SCHEMA,
        -- 维护：v4 已解决旧 numeric[189] 丢项，但 schema8 六通道实机又证明 pN 字符串分块
        -- 仍可能缺块。v5 把分块收敛到 <=128 的 chunks 数字索引表；旧 v4 永久可读，
        -- 且仅 schema8 迁移产生的 player/target 精确冗余允许做受指纹约束的物理恢复。
        transportVersion = 5,
        repairPhysicalTransport = RecoverSchema8ScopedTransport4,
        legacySchemaVersion = 1, key = P.V3KeyPrefix and (P.V3KeyPrefix .. "buff_display") or STORE_ID,
        -- Budget sized for REAL payloads (2026-09-01): legacy schema 1-3 saves
        -- can carry hundreds of tracked ids per category (one live save held
        -- 713). The old 192-entry / 2800-byte budget rejected every such save
        -- AND write-fenced the store for the whole session — nothing the user
        -- changed ever persisted again (edits, tracked toggles, resets).
        -- Encoded JSON for 713+713 ids plus settings is well under 16KB, which
        -- the client SaveData has always accepted (the legacy path saved it).
        budget = { maxDepth = 8, maxNodes = 32768, maxStringBytes = 65536, maxEntriesPerTable = 2048 },
        default = function() return NormalizeState(nil) end,
        get = function() return NormalizeState(F.State) end,
        apply = ApplyState,
        migrate = function(value, fromSchema) return MigrateState(value, fromSchema) end,
        -- 中文维护注释（schema4→5 完整性迁移）：旧单 HUD 存档必须先由旧 normalizer
        -- 逐字重建 canonical 并命中原 fingerprint，之后才允许 4→5 migrate。known-pair 只作为
        -- 已实机证明的 515E1BF3→3B898E2F 最终桥；未知 Hash 继续 fail-closed。
        rebuildCanonicalForIntegrity = RebuildHistoricalCanonical,
        -- 中文维护注释：当前序列已覆盖保存回读回归，仅声明许可；精确验真由 Core 完成。
        -- 历史世代和未知 Hash 不因此获得回读放行或写入权。
        recoverReadbackRepresentation = true,
        recoverKnownLegacyCanonical = RecoverKnownBuffDisplayCanonical,
        allowIntegrityUpgrade = true,
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
-- never mutate F.State, because F.State is still shared by the legacy main Store and the
-- dedicated layout projection. Only Apply crosses this boundary through the HUD Layout
-- Store durable transaction; Persistence owns rollback if that small write fails. The main
-- tracking Store keeps a compatibility copy for old installs but HUD-only actions never flush it.
-- This prevents an un-applied editor preview from leaking into either Store or the next reload.
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
        -- 中文维护注释：LayoutEditor 必须保留当前 profile 的排列代际；若这里仍硬编码 v3，
        -- 用户保存任意 HUD 微调都会把已升级的远程武器排列降级，下一帧图标顺序跳回旧版。
        layoutPresetVersion = ClampInt(value.layoutPresetVersion, 1, CURRENT_LAYOUT_PRESET_VERSION, defaults.layoutPresetVersion),
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
            -- schema7：gearScoreFormat 属于 player HUD info profile，Layout Store 必须完整携带；
            -- 否则 overlay Apply 会把主 Store 中的 compact/full Authority 丢掉并退回 nil/full。
            gearScoreFormat = NormalizeGearScoreFormat(info.gearScoreFormat or defaults.info.gearScoreFormat),
        },
        components = NormalizeComponents(value.components),
        targetLayout = NormalizeHudProfile(value.targetLayout, HudProfileFromSettings(value)),
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
    settings.targetLayout = Copy(normalized.targetLayout)
    return normalized
end


local LAYOUT_SETTING_KEY_SET = {}
for _, key in ipairs(LAYOUT_SETTING_KEYS) do LAYOUT_SETTING_KEY_SET[key] = true end

local function IsLayoutSettingKey(key)
    key = tostring(key or "")
    if LAYOUT_SETTING_KEY_SET[key] == true then return true end
    if string.sub(key, 1, 6) == "plate." then return true end
    if string.sub(key, 1, 5) == "info." then return true end
    if string.sub(key, 1, 11) == "components." then return true end
    return false
end

local function ApplyHudLayoutStoreState(value)
    -- 中文维护注释（HUD Layout 独立 Authority，2026-09-18）：
    -- 问题原因：状态显示主 Store 同时承载 786+ 追踪 ID 与 HUD 几何；实机证明仅保存
    -- distance.x=-1 也会让 RU SaveData 在“大表”里省略/改写合法字段，随后 durable readback
    -- 以 number(-1) vs number(0) 失败。继续为每个坐标加恢复规则只会扩大猜测面。
    -- Authority/数据流：v3.buff_display.layout 只拥有 LayoutSnapshot；主 v3.buff_display 仍拥有
    -- tracked/classification/窗口/业务策略的历史兼容副本。加载顺序固定为“主 Store 验真并 Apply ->
    -- layout Store 验真并覆盖 HUD 字段”。所有 HUD 编辑事务只写小 Store，绝不再重写追踪大表。
    -- 兼容边界：新 Store 为空时不应用 factory defaults，继续使用主 Store 中已经验真的旧布局；
    -- 一旦新 Store 有值，它就是 HUD layout 的更高优先级 Authority。失败时 Persistence 事务只回滚
    -- 这组布局字段，不碰追踪列表。实现理由：隔离高频/小配置与大数组，缩小 Native serializer
    -- 故障域；Transport3 已对 0/负数做哨兵保护，不需要 Transport5 的大数组分块。
    -- 风险/维护：以后新增 HUD 几何或显示策略字段必须加入 NormalizeLayoutSnapshot，并通过本 Store
    -- 保存；禁止再从 HUD 页面直接 durable-save 主 Store，否则会重新引入同类跨域保存故障。
    if type(F.State) ~= "table" then F.State = NormalizeState(nil) end
    if type(F.State.settings) ~= "table" then F.State.settings = NormalizeSettings(nil) end
    local normalized = ApplyLayoutSnapshotToSettings(F.State.settings, value)
    -- 保存一份已经通过 Persistence 验真的/事务中的 layout Domain。主 Store 以后若被显式重读，
    -- ApplyState 会替换整张 F.State；没有这份小快照，已加载的 layout Store 因 ready=true 不会
    -- 再读磁盘，HUD Authority 就会被主 Store 旧副本悄悄覆盖。快照只含小布局，不含追踪数组。
    F.HudLayoutStoreSnapshot = Copy(normalized)
    if type(F.InvalidateSettingsCache) == "function" then F:InvalidateSettingsCache() end
    return true
end

if P:GetStore(HUD_LAYOUT_STORE_ID) == nil then
    local layoutStore, layoutErr = P:RegisterV3Store({
        id = HUD_LAYOUT_STORE_ID, owner = "v3.buff_display.layout",
        scope = P.Scope and P.Scope.Account or "account",
        lifetime = P.Lifetime and P.Lifetime.Permanent or "permanent",
        schemaVersion = HUD_LAYOUT_STORE_SCHEMA, transportVersion = 3,
        legacySchemaVersion = 1,
        key = P.V3KeyPrefix and (P.V3KeyPrefix .. "buff_display_layout") or HUD_LAYOUT_STORE_ID,
        -- HUD Layout 没有追踪大数组；预算按当前双 profile + 10 组件留足维护余量，避免把主 Store
        -- 的 32K 节点预算复制过来掩盖未来误塞业务数据。注册期 default 会立即验证这条边界。
        budget = { maxDepth = 8, maxNodes = 4096, maxStringBytes = 16384, maxEntriesPerTable = 256 },
        default = function() return NormalizeLayoutSnapshot(nil) end,
        get = function() return LayoutSnapshotFromSettings(F.State and F.State.settings or NormalizeSettings(nil)) end,
        apply = ApplyHudLayoutStoreState,
        allowIntegrityUpgrade = true,
    })
    if layoutStore == nil and S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Error) == "function" then
        S.DiagnosticsManager:Error("buff_display_v3", "BUFF_DISPLAY_LAYOUT_STORE_REGISTER_FAILED", "状态显示 HUD 布局独立存档注册失败", { error = tostring(layoutErr) })
    end
end


------------------------------------------------------------------------
-- Status Display persistence split (.18.243)
--
-- 中文维护注释（2026-09-18，持久化 Authority 拆分）：
-- 问题原因：`v3.buff_display` 曾同时保存 HUD、窗口、分类、库水位和 player/target 各 393+
-- 个 auto ID。RU SaveData 已连续实证会以多种方式破坏该单体 Store：Transport4 缺 pN、
-- Transport5 整字段省略、marker/count 丢失、最后 chunk 截断甚至十进制 ID 中途截断。
-- 继续给旧 Store 增加 Hash 白名单只能追着症状修，且任何 HUD 小改动都会重新经过大表故障域。
--
-- Authority：从本契约开始，旧 `v3.buff_display` 永久降级为 LegacyMigrationSourceOnly；运行时
-- 唯一 Authority 分为：settings 小 Store、layout 小 Store、tracking player/target/meta A/B slot，
-- 以及 tracking manifest。Manifest 是 tracking generation 的最终提交点；inactive slot 全部完成
-- durable SaveData + immediate readback 之前，绝不能切换 active slot。
--
-- 数据流：启动先读 manifest。已有 manifest 时只读 new stores，完全不 Load/Apply 旧大 Store；
-- manifest 为空时才执行一次 Legacy 迁移。用户已明确批准方案 A：若 legacy schema8/T5 中
-- player.auto 是已观测残片而 target.auto 是完整 dense 列表，则仅在这次迁移中以 target.auto
-- 作为 player.auto 基线。该选择不是通用 twin Authority，迁移完成后永不再次执行。
--
-- 兼容边界：旧 Store 不自动 Clear，保留取证/回退证据；new tracking slot 使用 Transport5，
-- 但任何 inactive 写损坏只会让本次 mutation 失败，active manifest 仍指向上一份可靠 generation。
-- settings/meta/layout 均为小 Store，不再承载 393×2 大数组。
--
-- 实现理由：把“能否写入新配置”与“是否破坏上一次可靠配置”解耦。即使 RU 未来仍破坏某次
-- tracking inactive slot，用户最多收到本次保存失败，不会再把整个状态显示启动写保护。
--
-- 风险/维护禁止项：
-- 1) 禁止任何新代码再次 durable-save `v3.buff_display`；
-- 2) 禁止绕过 manifest 直接把 inactive slot 当 active；
-- 3) 禁止用 Hash 反推 ID，禁止把方案 A 扩成日常 player<-target 同步；
-- 4) 新 tracking 字段必须进入 meta/player/target snapshot 与 A/B 提交流程；
-- 5) 本逻辑只在 Load/Save 冷路径运行，严禁搬进 Tick/aura/HUD render 循环。
------------------------------------------------------------------------

local function TablesEqual(a, b, seen)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    seen = seen or {}
    if seen[a] == b then return true end
    seen[a] = b
    for k, v in pairs(a) do if not TablesEqual(v, b[k], seen) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

local function NormalizeSettingsAuthoritySnapshot(value)
    value = type(value) == "table" and value or {}
    local source = type(value.settings) == "table" and value.settings or value
    local canonical = NormalizeSettings(source)
    return {
        settings = {
            showBuffs = canonical.showBuffs,
            showDebuffs = canonical.showDebuffs,
            showHidden = canonical.showHidden,
            playerRows = canonical.playerRows,
            targetRows = canonical.targetRows,
            refreshMs = canonical.refreshMs,
        },
        widgetWindow = NormalizeWindow(value.widgetWindow),
        widgetVisible = value.widgetVisible == true,
    }
end

local function SettingsAuthoritySnapshotFromState(state)
    state = type(state) == "table" and state or F.State
    return NormalizeSettingsAuthoritySnapshot({
        settings = state and state.settings or nil,
        widgetWindow = state and state.widgetWindow or nil,
        widgetVisible = state and state.widgetVisible == true,
    })
end

local function ApplySettingsAuthoritySnapshot(value)
    local normalized = NormalizeSettingsAuthoritySnapshot(value)
    F.State = type(F.State) == "table" and F.State or NormalizeState(nil)
    F.State.settings = type(F.State.settings) == "table" and F.State.settings or NormalizeSettings(nil)
    for key, item in pairs(normalized.settings) do F.State.settings[key] = Copy(item) end
    F.State.widgetWindow = Copy(normalized.widgetWindow)
    F.State.widgetVisible = normalized.widgetVisible == true
    F.SettingsStoreSnapshot = Copy(normalized)
    if type(F.InvalidateSettingsCache) == "function" then F:InvalidateSettingsCache() end
    return true
end

local function NormalizeTrackingGroup(value)
    value = type(value) == "table" and value or {}
    local all = NormalizeTrackedScopes({ player = value })
    return Copy(all.player)
end

local function NormalizeTrackingMeta(value)
    value = type(value) == "table" and value or {}
    local canonical = NormalizeSettings({
        classification = value.classification,
        trackedCooldowns = value.trackedCooldowns,
        library = value.library,
    })
    return {
        classification = Copy(canonical.classification or {}),
        trackedCooldowns = Copy(canonical.trackedCooldowns or { skill = {}, mate = {} }),
        library = Copy(canonical.library or { catalogVersion = 0, importedPacks = {} }),
    }
end

local function TrackingSnapshotFromState(state)
    state = type(state) == "table" and state or F.State
    local settings = type(state) == "table" and type(state.settings) == "table" and state.settings or NormalizeSettings(nil)
    return {
        player = NormalizeTrackingGroup(type(settings.tracked) == "table" and settings.tracked.player or nil),
        target = NormalizeTrackingGroup(type(settings.tracked) == "table" and settings.tracked.target or nil),
        meta = NormalizeTrackingMeta({
            classification = settings.classification,
            trackedCooldowns = settings.trackedCooldowns,
            library = settings.library,
        }),
    }
end

local function ApplyTrackingSnapshot(snapshot)
    snapshot = type(snapshot) == "table" and snapshot or {}
    F.State = type(F.State) == "table" and F.State or NormalizeState(nil)
    F.State.settings = type(F.State.settings) == "table" and F.State.settings or NormalizeSettings(nil)
    F.State.settings.tracked = {
        player = NormalizeTrackingGroup(snapshot.player),
        target = NormalizeTrackingGroup(snapshot.target),
    }
    local meta = NormalizeTrackingMeta(snapshot.meta)
    F.State.settings.classification = Copy(meta.classification)
    F.State.settings.trackedCooldowns = Copy(meta.trackedCooldowns)
    F.State.settings.library = Copy(meta.library)
    if type(F.InvalidateSettingsCache) == "function" then F:InvalidateSettingsCache() end
    return true
end

local function TrackingStoreId(part, slot)
    return TRACKING_STORE_PREFIX .. tostring(part) .. "." .. tostring(slot)
end

F.TrackingSlotCache = type(F.TrackingSlotCache) == "table" and F.TrackingSlotCache or {
    a = { player = NormalizeTrackingGroup(nil), target = NormalizeTrackingGroup(nil), meta = NormalizeTrackingMeta(nil) },
    b = { player = NormalizeTrackingGroup(nil), target = NormalizeTrackingGroup(nil), meta = NormalizeTrackingMeta(nil) },
}
F.TrackingManifest = type(F.TrackingManifest) == "table" and F.TrackingManifest or { generation = 0, slot = nil }

local function NormalizeTrackingManifest(value)
    value = type(value) == "table" and value or {}
    local slot = value.slot == "a" and "a" or (value.slot == "b" and "b" or nil)
    local generation = math.max(0, math.floor(tonumber(value.generation) or 0))
    if generation == 0 then slot = nil end
    if slot == nil then generation = 0 end
    return { generation = generation, slot = slot }
end

local function ApplyTrackingManifest(value)
    F.TrackingManifest = NormalizeTrackingManifest(value)
    return true
end

local function RegisterSplitStore(def)
    if P:GetStore(def.id) ~= nil then return true end
    local store, err = P:RegisterV3Store(def)
    if store == nil then
        if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Error) == "function" then
            S.DiagnosticsManager:Error("buff_display_v3", "BUFF_DISPLAY_SPLIT_STORE_REGISTER_FAILED",
                "状态显示拆分存档注册失败", { store = tostring(def.id), error = tostring(err) })
        end
        return false, err
    end
    return true
end

RegisterSplitStore({
    id = SETTINGS_STORE_ID, owner = SETTINGS_STORE_ID,
    scope = P.Scope and P.Scope.Account or "account", lifetime = P.Lifetime and P.Lifetime.Permanent or "permanent",
    schemaVersion = SETTINGS_STORE_SCHEMA, transportVersion = 3, legacySchemaVersion = 1,
    key = P.V3KeyPrefix and (P.V3KeyPrefix .. "buff_display_settings") or SETTINGS_STORE_ID,
    budget = { maxDepth = 6, maxNodes = 1024, maxStringBytes = 8192, maxEntriesPerTable = 128 },
    default = function() return NormalizeSettingsAuthoritySnapshot(nil) end,
    get = function() return SettingsAuthoritySnapshotFromState(F.State) end,
    apply = ApplySettingsAuthoritySnapshot,
    allowIntegrityUpgrade = true,
})

for _, slot in ipairs(TRACKING_SLOTS) do
    for _, part in ipairs(TRACKING_PARTS) do
        local currentSlot, currentPart = slot, part
        local id = TrackingStoreId(currentPart, currentSlot)
        RegisterSplitStore({
            id = id, owner = id,
            scope = P.Scope and P.Scope.Account or "account", lifetime = P.Lifetime and P.Lifetime.Permanent or "permanent",
            schemaVersion = TRACKING_STORE_SCHEMA,
            transportVersion = currentPart == "meta" and 3 or 5,
            legacySchemaVersion = 1,
            key = P.V3KeyPrefix and (P.V3KeyPrefix .. "buff_display_tracking_" .. currentPart .. "_" .. currentSlot) or id,
            budget = currentPart == "meta"
                and { maxDepth = 6, maxNodes = 2048, maxStringBytes = 16384, maxEntriesPerTable = 1024 }
                or { maxDepth = 6, maxNodes = 8192, maxStringBytes = 32768, maxEntriesPerTable = 2048 },
            default = function()
                return currentPart == "meta" and NormalizeTrackingMeta(nil) or NormalizeTrackingGroup(nil)
            end,
            get = function()
                local row = F.TrackingSlotCache[currentSlot] or {}
                return Copy(row[currentPart] or (currentPart == "meta" and NormalizeTrackingMeta(nil) or NormalizeTrackingGroup(nil)))
            end,
            apply = function(value)
                F.TrackingSlotCache[currentSlot] = type(F.TrackingSlotCache[currentSlot]) == "table" and F.TrackingSlotCache[currentSlot] or {}
                F.TrackingSlotCache[currentSlot][currentPart] = currentPart == "meta"
                    and NormalizeTrackingMeta(value) or NormalizeTrackingGroup(value)
                return true
            end,
            allowIntegrityUpgrade = true,
        })
    end
end

RegisterSplitStore({
    id = TRACKING_MANIFEST_STORE_ID, owner = TRACKING_MANIFEST_STORE_ID,
    scope = P.Scope and P.Scope.Account or "account", lifetime = P.Lifetime and P.Lifetime.Permanent or "permanent",
    schemaVersion = TRACKING_MANIFEST_SCHEMA, transportVersion = 3, legacySchemaVersion = 1,
    key = P.V3KeyPrefix and (P.V3KeyPrefix .. "buff_display_tracking_manifest") or TRACKING_MANIFEST_STORE_ID,
    budget = { maxDepth = 3, maxNodes = 32, maxStringBytes = 256, maxEntriesPerTable = 16 },
    default = function() return { generation = 0, slot = nil } end,
    get = function() return NormalizeTrackingManifest(F.TrackingManifest) end,
    apply = ApplyTrackingManifest,
    allowIntegrityUpgrade = true,
})

local function EnsureSplitStoreLoaded(id, apply)
    local ready = type(P.IsStoreLoaded) == "function" and select(1, P:IsStoreLoaded(id)) == true
    if ready == true then return true, P:GetStore(id) and P:GetStore(id).loadStatus or "ready" end
    local status, value, err = P:LoadStore(id, { apply = apply ~= false })
    if status ~= true and status ~= "empty" then return false, err or tostring(status or "split store load failed") end
    return true, status, value
end

local function ActivateTrackingSlot(slot)
    if slot ~= "a" and slot ~= "b" then return false, "tracking manifest slot unavailable" end
    local row = F.TrackingSlotCache[slot]
    if type(row) ~= "table" or type(row.player) ~= "table" or type(row.target) ~= "table" or type(row.meta) ~= "table" then
        return false, "tracking slot incomplete"
    end
    ApplyTrackingSnapshot(row)
    F.ActiveTrackingSlot = slot
    return true
end

local function EnsureTrackingSlotLoaded(slot)
    for _, part in ipairs(TRACKING_PARTS) do
        local ok, why = EnsureSplitStoreLoaded(TrackingStoreId(part, slot), true)
        if ok ~= true then return false, tostring(part) .. ":" .. tostring(why) end
    end
    return true
end

local function PersistTrackingSlot(slot, snapshot, reason)
    snapshot = type(snapshot) == "table" and snapshot or TrackingSnapshotFromState(F.State)
    local before = Copy(F.TrackingSlotCache[slot])
    for _, part in ipairs(TRACKING_PARTS) do
        local id = TrackingStoreId(part, slot)
        local loaded, loadErr = EnsureSplitStoreLoaded(id, true)
        if loaded ~= true then return false, loadErr end
        local payload = Copy(snapshot[part])
        local ok, err = P:MutateStore(id, function()
            F.TrackingSlotCache[slot][part] = part == "meta" and NormalizeTrackingMeta(payload) or NormalizeTrackingGroup(payload)
            return true
        end, { delayMs = 0, reason = tostring(reason or "tracking_stage") .. ":" .. part .. ":" .. slot,
            durable = true })
        if ok ~= true then
            F.TrackingSlotCache[slot] = Copy(before)
            return false, tostring(part) .. ":" .. tostring(err or "inactive slot save failed")
        end
    end
    return true
end

function F:CommitTrackingSnapshot(snapshot, reason)
    snapshot = type(snapshot) == "table" and snapshot or TrackingSnapshotFromState(self.State)
    local manifestLoaded, manifestWhy = EnsureSplitStoreLoaded(TRACKING_MANIFEST_STORE_ID, true)
    if manifestLoaded ~= true then return false, manifestWhy end
    local beforeManifest = NormalizeTrackingManifest(self.TrackingManifest)
    local nextSlot = beforeManifest.slot == "a" and "b" or "a"
    local staged, stageErr = PersistTrackingSlot(nextSlot, snapshot, reason or "tracking_commit")
    if staged ~= true then return false, stageErr end

    local nextManifest = { generation = beforeManifest.generation + 1, slot = nextSlot }
    local committed, commitErr = P:MutateStore(TRACKING_MANIFEST_STORE_ID, function()
        F.TrackingManifest = Copy(nextManifest)
        return true
    end, { delayMs = 0, reason = tostring(reason or "tracking_commit") .. ":manifest", durable = true })
    if committed ~= true then return false, commitErr or "tracking manifest commit failed" end
    local activated, activateErr = ActivateTrackingSlot(nextSlot)
    if activated ~= true then return false, activateErr end
    return true
end

function F:GetTrackingPersistenceHealth()
    local manifest = NormalizeTrackingManifest(self.TrackingManifest)
    return {
        contract = tonumber(self.TrackingPersistenceContractVersion) or 0,
        generation = manifest.generation,
        slot = manifest.slot,
        legacyMigration = tostring(self.LegacyMigrationStatus or "pending"),
    }
end

local function IsDensePositiveIds(value, limit)
    if type(P.RebuildDenseSequenceForIntegrity) ~= "function" then return nil end
    local rows, reason, changed = P:RebuildDenseSequenceForIntegrity(value, limit or 1024)
    if type(rows) ~= "table" or changed == true then return nil, reason end
    for index = 1, #rows do
        local id = rows[index]
        if type(id) ~= "number" or id < 1 or id ~= math.floor(id) then return nil, "invalid_id" end
    end
    return rows
end

local function BuildLegacyMigrationCandidate()
    local legacy = P:GetStore(STORE_ID)
    if type(legacy) ~= "table" then return NormalizeState(nil), "legacy_missing_default" end
    local key, keyErr = P:ResolveStoreKey(legacy)
    if key == nil then return nil, keyErr or "legacy key unavailable" end
    if S.Api == nil or type(S.Api.LoadData) ~= "function" then return nil, "LoadData unavailable" end
    local raw, loadErr = S.Api:LoadData(key)
    if loadErr ~= nil then return nil, tostring(loadErr) end
    if raw == nil then return NormalizeState(nil), "legacy_empty_default" end
    if type(raw) ~= "table" then return nil, "legacy raw type invalid" end
    local decoded, decodeErr = P:DecodePhysicalEnvelope(raw)
    if decoded == nil then return nil, "legacy transport decode failed:" .. tostring(decodeErr or "unknown") end
    local meta = type(decoded.__rsmeta) == "table" and decoded.__rsmeta or nil
    if type(meta) ~= "table" or tostring(meta.store or "") ~= STORE_ID or tostring(meta.owner or "") ~= "v3.buff_display" then
        return nil, "legacy envelope identity mismatch"
    end
    local payload = type(decoded.payload) == "table" and decoded.payload or nil
    if payload == nil then return nil, "legacy payload missing" end

    local candidate = NormalizeState(payload)
    local rawTracked = type(payload.settings) == "table" and type(payload.settings.tracked) == "table" and payload.settings.tracked or nil
    local playerRaw = type(rawTracked) == "table" and type(rawTracked.player) == "table" and rawTracked.player.auto or nil
    local targetRaw = type(rawTracked) == "table" and type(rawTracked.target) == "table" and rawTracked.target.auto or nil
    local playerRows = IsDensePositiveIds(playerRaw, 1024)
    local targetRows = IsDensePositiveIds(targetRaw, 1024)
    local usedApprovedA = false

    -- 中文维护注释（用户确认方案 A，一次性迁移边界）：
    -- 当前实机 legacy schema8/T5 已物理丢失 player.auto 后半段，旧 Hash 无法恢复用户可能存在的
    -- player-only 差异。用户明确选择“以完整 target.auto 作为一次性 player.auto 迁移基线”。
    -- 这里只在 manifest 尚未建立的 LegacyMigrationSourceOnly 路径执行，并要求：schema8/T5、
    -- target.auto 是完整 dense 列表、player.auto 不是完整 dense、且坏侧仍是已观测 `{chunks=...}`
    -- 残片。迁移完成后该分支永不再运行，也不得被复用为日常双向同步或 readback 恢复规则。
    -- 风险：已永久丢失的 player-only Auto 差异无法证明性恢复；这是用户已知并批准的取舍。
    if playerRows == nil and type(targetRows) == "table" and #targetRows > 32
        and tonumber(meta.schema) == 8 and tonumber(meta.transportVersion) == 5
        and type(playerRaw) == "table" and type(playerRaw.chunks) == "table" then
        candidate.settings.tracked.player.auto = Copy(targetRows)
        usedApprovedA = true
    end
    if type(targetRows) == "table" then candidate.settings.tracked.target.auto = Copy(targetRows) end
    if type(playerRows) == "table" then candidate.settings.tracked.player.auto = Copy(playerRows) end
    candidate = NormalizeState(candidate)
    return candidate, usedApprovedA and "legacy_schema8_t5_user_approved_A" or "legacy_decoded"
end

local function EnsureSettingsStoreLoaded()
    local ok, status = EnsureSplitStoreLoaded(SETTINGS_STORE_ID, true)
    return ok, status
end

function F:MigrateLegacyBuffDisplayOnce()
    local manifestOk, manifestStatus = EnsureSplitStoreLoaded(TRACKING_MANIFEST_STORE_ID, true)
    if manifestOk ~= true then return false, manifestStatus end
    local manifest = NormalizeTrackingManifest(self.TrackingManifest)
    if manifest.slot ~= nil and manifest.generation > 0 then
        self.LegacyMigrationStatus = "already_migrated"
        return true
    end

    local candidate, source = BuildLegacyMigrationCandidate()
    if type(candidate) ~= "table" then
        self.LegacyMigrationStatus = "failed:" .. tostring(source or "legacy_candidate")
        return false, source or "legacy migration candidate unavailable"
    end
    local beforeState = Copy(self.State)
    self.State = NormalizeState(candidate)

    local settingsOk = EnsureSplitStoreLoaded(SETTINGS_STORE_ID, true)
    if settingsOk ~= true then self.State = beforeState; return false, "settings store load failed" end
    local savedSettings, settingsErr = P:MutateStore(SETTINGS_STORE_ID, function() return true end,
        { delayMs = 0, reason = "buff_display_legacy_migration_settings", durable = true })
    if savedSettings ~= true then self.State = beforeState; return false, settingsErr end

    local layoutReady, layoutStatus = EnsureSplitStoreLoaded(HUD_LAYOUT_STORE_ID, false)
    if layoutReady ~= true then self.State = beforeState; return false, layoutStatus end
    if layoutStatus == "empty" then
        local layoutSaved, layoutErr = P:MutateStore(HUD_LAYOUT_STORE_ID, function() return true end,
            { delayMs = 0, reason = "buff_display_legacy_migration_layout", durable = true })
        if layoutSaved ~= true then self.State = beforeState; return false, layoutErr end
    else
        local layoutStore = P:GetStore(HUD_LAYOUT_STORE_ID)
        if type(layoutStore) == "table" and type(layoutStore.lastAppliedValue) == "table" then
            -- reserved for future Core exposure; current path applies below via explicit LoadStore only.
        end
        local _, existingLayout = P:LoadStore(HUD_LAYOUT_STORE_ID, { apply = false, discardDirty = true, discardUnverified = true })
        if type(existingLayout) == "table" then ApplyHudLayoutStoreState(existingLayout) end
    end

    local tracked = TrackingSnapshotFromState(self.State)
    local committed, commitErr = self:CommitTrackingSnapshot(tracked, "buff_display_legacy_migration_tracking")
    if committed ~= true then self.State = beforeState; self.LegacyMigrationStatus = "failed:" .. tostring(commitErr); return false, commitErr end
    self.LegacyMigrationStatus = tostring(source or "legacy_decoded")
    return true
end

function F:GetLayoutSettingsSnapshot()
    return LayoutSnapshotFromSettings(self.State.settings)
end

function F:GetDefaultLayoutSettingsSnapshot()
    return LayoutSnapshotFromSettings(NormalizeSettings(nil))
end

-- 中文维护注释（HUD 校准事务边界，2026-09-11）：
-- CalibrationDraft 由 Presentation 临时持有，箭头/拖动/输入都只改 Draft。只有
-- PersistHudCalibrationSnapshot 才进入 Store MutateStore durable transaction；取消编辑不会
-- 触碰 F.State。player 使用旧字段 Authority，target 使用 targetLayout Authority。
-- 兼容边界：此接口只负责视觉 profile，不复制 headShowAll/追踪 ID/敌我过滤等业务规则。
function F:GetScopeLayoutSettings(scope)
    local settings = self.State.settings
    local player = HudProfileFromSettings(settings)
    if tostring(scope or "player") == "target" then
        return NormalizeHudProfile(settings.targetLayout, player)
    end
    return player
end

function F:GetHudCalibrationSnapshot()
    local player = self:GetScopeLayoutSettings("player")
    local target = self:GetScopeLayoutSettings("target")
    return { player = Copy(player), target = Copy(target) }
end

function F:GetDefaultHudCalibrationSnapshot()
    local defaults = NormalizeSettings(nil)
    local player = HudProfileFromSettings(defaults)
    -- 中文维护注释（目标发行模板默认值）：目标 HUD 已有独立默认 Authority，不能再像
    -- .18.207 那样无条件 target=Copy(player)。否则“恢复当前目标 HUD”会绕过维护者实机校准
    -- 的 TARGET|EQUIP 模板，而 Store 的 ResetLayoutSettings 又使用另一套 target defaults。
    -- 这里统一从 defaults.targetLayout 读取，使新用户、恢复布局和校准恢复目标三条路径一致。
    local target = NormalizeHudProfile(defaults.targetLayout, player)
    return { player = Copy(player), target = Copy(target) }
end

function F:ApplyHudCalibrationSnapshotRaw(snapshot)
    snapshot = type(snapshot) == "table" and snapshot or {}
    local settings = self.State.settings
    local currentPlayer = HudProfileFromSettings(settings)
    local currentTarget = NormalizeHudProfile(settings.targetLayout, currentPlayer)
    local player = NormalizeHudProfile(snapshot.player, currentPlayer)
    -- 中文维护注释（双 profile 部分更新边界）：target 已经是独立 Authority；调用者若
    -- 只提交 player patch，绝不能因为 target 缺席就隐式执行“同步自身 → 目标”。手动同步
    -- 只能由校准器显式把 player Copy 到 snapshot.target。这样导入/未来 API 的部分更新也
    -- 不会意外覆盖用户已经单独调好的目标 HUD。
    local target = NormalizeHudProfile(snapshot.target, currentTarget)
    settings.plateScale = player.plateScale
    settings.plate = Copy(player.plate)
    settings.info = Copy(player.info)
    settings.components = Copy(player.components)
    settings.targetLayout = Copy(target)
    return true
end

function F:PersistHudCalibrationSnapshot(snapshot, reason)
    snapshot = type(snapshot) == "table" and snapshot or {}
    local saved, saveErr = self:MutateHudLayoutStore(function()
        -- 中文维护注释（.18.242 持久化事故复盘/永久边界）：
        -- 问题原因：`.240` 以前“保存并退出”会为了一个 HUD 坐标 durable-save 整个
        -- v3.buff_display，连带序列化 player/target auto（393×2）。RU Native 已连续实证会在
        -- 这个大 Store 中丢 marker/count、截掉后续 chunk，甚至把最后十进制 ID 截在数字中间；
        -- 因此 `复制自身→目标` 本身不是错误，错误是把 HUD Draft 的提交跨到了追踪大 Store。
        -- Authority/数据流：CalibrationDraft -> 本 mutator -> v3.buff_display.layout（唯一 HUD
        -- durable Authority）-> ApplyHudLayoutStoreState；主 v3.buff_display 只保留旧版兼容基线和
        -- tracking/classification 等业务数据。复制自身→目标只在 Draft 中显式 target=Copy(player)，
        -- 绝不能因此触发主 Store SaveData。
        -- 兼容边界：旧用户尚无 layout Store 时先使用已验真的主 Store 布局；第一次 HUD 保存后，
        -- layout Store 成为更高优先级 overlay。若本小 Store 保存失败，Persistence 只回滚布局事务，
        -- 不得回退到“改存主 Store”作为兜底，否则会重新制造本次故障。
        -- 维护禁止项：这里和所有 HUD-only setter/reset/policy API **禁止调用 MutateStore(STORE_ID)**、
        -- SaveStore(STORE_ID) 或 MarkStoreDirty(STORE_ID)。新增 HUD 字段必须进入 NormalizeLayoutSnapshot
        -- 并补充隔离测试；如未来 tracking 大 Store 自身仍出现 RU 损坏，应独立做 tracking 分片，
        -- 不能把 HUD 保存重新耦合回去。该规则是架构边界，不是临时 workaround。
        return self:ApplyHudCalibrationSnapshotRaw(snapshot)
    end, 0, tostring(reason or "buff_display_hud_calibration_apply"), true)
    if saved ~= true then return false, saveErr or "HUD 校准保存失败" end
    if type(F.ReconcileLanes) == "function" then F:ReconcileLanes() end
    if type(F.RefreshScope) == "function" then F:RefreshScope("player"); F:RefreshScope("target") end
    if S.Events ~= nil and type(S.Events.Publish) == "function" then S.Events:Publish("v3.buff_display.settings", "hud_calibration_apply") end
    return true, nil
end

function F:CanPersistLayoutSettings()
    local loaded, loadErr = self:EnsureStoreLoaded()
    if loaded ~= true then return false, loadErr or "状态显示设置尚未读取" end
    return P:CanWrite(HUD_LAYOUT_STORE_ID)
end

function F:PersistLayoutSettingsSnapshot(snapshot, reason)
    -- Apply 是 LayoutEditor 唯一 durable 边界；.18.241 起它只写独立 HUD Layout Store。
    local saved, saveErr = self:MutateHudLayoutStore(function()
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
    -- 中文维护注释：Layout Reset 必须同时重置 player 与 target 两套视觉 Authority。
    -- 若只重置旧 player 字段，targetLayout 会保留旧坐标，用户看到的“恢复默认”将只恢复一半。
    settings.targetLayout = Copy(defaults.targetLayout)
    return true, before
end


function F:PersistResetLayoutSettings(reason)
    -- 中文维护注释：Reset 也必须遵守独立 HUD Layout Authority。若仍只改/存主 Store，已有
    -- layout overlay 会在下次加载重新覆盖默认值，形成“本次看似重置、重载又回来”的双 Authority。
    local saved, saveErr = self:MutateHudLayoutStore(function()
        local ok, err = self:ResetLayoutSettings()
        if ok ~= true then return false, err or "布局重置失败" end
        return true
    end, 0, tostring(reason or "reset_layout_settings"), true)
    if saved ~= true then return false, saveErr or "布局重置保存失败" end
    return true, nil
end

-- Compatibility alias for any old caller. Since .18.79 this is deliberately
-- NON-destructive and has the same scoped semantics as Layout Reset.
function F:ResetSettings()
    return self:ResetLayoutSettings()
end
-- 中文维护注释（远程武器旧默认一次性升级，2026-09-15）：
-- 问题原因：历史玩家 HUD 的 ranged 默认关闭，导致远程职业升级后仍看不到远程武器。
-- Authority/数据流：只有 Persistence 已验真并 Apply 到 F.State 后才检查当前玩家组件；若它仍
-- 完全等于旧发行默认（关闭/x0/y0/26px/font0/alpha1），才在同一个 Store 事务中开启并把
-- layoutPresetVersion 盖为 v4。任何用户主动改过位置/大小/透明度/开关代际都视为用户 Authority。
-- 兼容边界：自定义 ranged 保持 v3 排列和原值；v4 用户以后主动关闭远程也不会被再次打开。
-- 实现理由：不用 schema7、不改变历史 normalizer/fingerprint；失败保存时由 Persistence 回滚，
-- EnsureStoreLoaded 仅记录警告并继续使用原配置，禁止为了新默认破坏启动。
local function IsLegacyUntouchedRanged(component)
    component = type(component) == "table" and component or {}
    return component.enabled == false
        and (tonumber(component.x) or 0) == 0
        and (tonumber(component.y) or 0) == 0
        and (tonumber(component.size) or 26) == 26
        and (tonumber(component.fontSize) or 0) == 0
        and math.abs((tonumber(component.alpha) or 1) - 1) < 0.000001
end

function F:UpgradeRangedWeaponReleaseDefault(persist)
    local settings = self.State and self.State.settings or nil
    if type(settings) ~= "table" then return false, "状态显示设置不可用" end
    if (tonumber(settings.layoutPresetVersion) or LAYOUT_PRESET_VERSION) >= CURRENT_LAYOUT_PRESET_VERSION then
        return true, false
    end
    local ranged = type(settings.components) == "table" and settings.components.ranged or nil
    if IsLegacyUntouchedRanged(ranged) ~= true then return true, false end
    local function ApplyUpgrade()
        local current = self.State.settings
        local component = type(current.components) == "table" and current.components.ranged or nil
        if IsLegacyUntouchedRanged(component) ~= true then return true end
        component.enabled = true
        current.layoutPresetVersion = CURRENT_LAYOUT_PRESET_VERSION
        return true
    end
    if persist == true then
        -- .18.241：layout Store 已在 EnsureStoreLoaded 中先完成加载；默认升级只改 HUD 字段，
        -- 直接写独立 Store，禁止为了一个 ranged 默认再重写追踪大表。
        local ok, err = P:MutateStore(HUD_LAYOUT_STORE_ID, ApplyUpgrade, {
            delayMs = 0, reason = "buff_display_ranged_release_upgrade", durable = true,
        })
        if ok ~= true then return false, err or "远程武器默认升级保存失败" end
    else
        ApplyUpgrade()
        if type(self.InvalidateSettingsCache) == "function" then self:InvalidateSettingsCache() end
    end
    return true, true
end

function F:EnsureHudLayoutStoreLoaded()
    local ready = type(P.IsStoreLoaded) == "function" and select(1, P:IsStoreLoaded(HUD_LAYOUT_STORE_ID)) == true
    if ready == true then
        -- 主 Store 可以被诊断/显式重载独立重新 Apply；layout Store 虽仍处于 ready 状态，
        -- 其 Authority 不能因此丢失。只重放已验证/已事务提交的小快照，不重新 LoadData。
        if type(self.HudLayoutStoreSnapshot) == "table" then
            ApplyLayoutSnapshotToSettings(self.State.settings, self.HudLayoutStoreSnapshot)
            if type(F.InvalidateSettingsCache) == "function" then F:InvalidateSettingsCache() end
        end
        self.HudLayoutStoreLoaded = true
        return true
    end
    local store = P:GetStore(HUD_LAYOUT_STORE_ID)
    if store == nil then return false, "状态显示 HUD 布局存档不可用" end
    -- 必须 apply=false：新 Store 第一次出现时磁盘为空，factory default 不是旧用户的 Authority。
    -- 此时保留刚由主 Store 验真的布局，直到用户第一次修改 HUD 才建立独立 overlay。
    local status, value, err = P:LoadStore(HUD_LAYOUT_STORE_ID, { apply = false })
    if status ~= true and status ~= "empty" then return false, err or tostring(status or "HUD 布局读取失败") end
    if status == true then
        local ok, applyErr = ApplyHudLayoutStoreState(value)
        if ok ~= true then return false, applyErr or "HUD 布局应用失败" end
    end
    self.HudLayoutStoreLoaded = true
    return true
end

function F:EnsureStoreLoaded()
    if self.StoreLoaded == true then return true end

    -- 中文维护注释（.18.243 Runtime Authority 切换）：
    -- 旧 v3.buff_display **不再参与正常启动**。过去 EnsureStoreLoaded 第一件事就是 P:LoadStore(STORE_ID)，
    -- 因此旧大 Store 任意一次 tracking 物理截断都会把整个状态显示再次写保护，即使 layout/settings
    -- 已经拆出。现在启动只读取 new manifest/settings/layout + manifest 指向的 tracking slot；只有
    -- manifest 尚未建立的首次升级才直接只读旧 key 并迁移。迁移后旧 Store 即使仍损坏也只是证据，
    -- 不再成为 blocker。禁止为了“兼容”把 P:LoadStore(STORE_ID) 加回这里。
    local manifestLoaded, manifestStatus = EnsureSplitStoreLoaded(TRACKING_MANIFEST_STORE_ID, true)
    if manifestLoaded ~= true then return false, manifestStatus or "状态显示 Tracking Manifest 读取失败" end
    local manifest = NormalizeTrackingManifest(self.TrackingManifest)
    if manifest.slot == nil or manifest.generation <= 0 then
        local migrated, migrationErr = self:MigrateLegacyBuffDisplayOnce()
        if migrated ~= true then return false, migrationErr or "状态显示旧存档迁移失败" end
        manifest = NormalizeTrackingManifest(self.TrackingManifest)
    end

    local settingsLoaded, settingsErr = EnsureSplitStoreLoaded(SETTINGS_STORE_ID, true)
    if settingsLoaded ~= true then return false, settingsErr or "状态显示 Settings 存档读取失败" end

    local trackingLoaded, trackingErr = EnsureTrackingSlotLoaded(manifest.slot)
    if trackingLoaded ~= true then return false, trackingErr or "状态显示 Tracking Slot 读取失败" end
    local activated, activateErr = ActivateTrackingSlot(manifest.slot)
    if activated ~= true then return false, activateErr or "状态显示 Tracking Authority 激活失败" end

    local layoutLoaded, layoutErr = self:EnsureHudLayoutStoreLoaded()
    if layoutLoaded ~= true then return false, layoutErr or "状态显示 HUD 布局尚未读取" end

    local upgraded, upgradeErr = self:UpgradeRangedWeaponReleaseDefault(true)
    if upgraded ~= true and S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Warn) == "function" then
        S.DiagnosticsManager:Warn("buff_display_v3", "RANGED_DEFAULT_UPGRADE_FAILED", "远程武器默认升级保存失败，已保留原用户配置", { error = tostring(upgradeErr or "unknown") })
    end
    self.StoreLoaded = true
    if type(F.InvalidateSettingsCache) == "function" then F:InvalidateSettingsCache() end
    return true
end

function F:MarkStoreDirty(delayMs, reason)
    -- 中文维护注释（Legacy 主 Store 禁写）：该兼容入口现在只允许标记 settings 小 Store。
    -- 历史调用若仍把它理解成 v3.buff_display 全量保存，会重新把 HUD/追踪带回同一故障域。
    if type(F.InvalidateSettingsCache) == "function" then F:InvalidateSettingsCache() end
    return P:MarkDirty(SETTINGS_STORE_ID, tonumber(delayMs) or 300, reason or "buff_display_settings_changed")
end

function F:MutateStore(mutator, delayMs, reason, durable)
    -- 中文维护注释（.18.243 旧 API 收敛为 settings-only）：
    -- 这是为了保留 Feature 旧调用签名，不是旧 monolith Authority 的别名。调用者只可修改
    -- show*/rows/refresh/widget 等 settings-domain 字段；tracking/meta 必须走 MutateTrackingStore，
    -- HUD 必须走 MutateHudLayoutStore。这里在 mutation 内做跨域快照比较，发现越界立即恢复完整
    -- Domain 并拒绝，防止未来维护者无意间把大数组又接回单 Store。
    if type(P.MutateStore) ~= "function" then return false, "Persistence mutation transaction unavailable" end
    local loaded, loadErr = self:EnsureStoreLoaded()
    if loaded ~= true then return false, loadErr or "状态显示存档尚未读取" end
    local beforeState = Copy(self.State)
    local beforeTracking = TrackingSnapshotFromState(beforeState)
    local beforeLayout = LayoutSnapshotFromSettings(beforeState.settings)
    local ok, err, extra = P:MutateStore(SETTINGS_STORE_ID, function()
        local result, mutationErr, mutationExtra = mutator()
        if result == false then return false, mutationErr, mutationExtra end
        if not TablesEqual(beforeTracking, TrackingSnapshotFromState(self.State))
            or not TablesEqual(beforeLayout, LayoutSnapshotFromSettings(self.State.settings)) then
            ApplyState(beforeState)
            return false, "cross_domain_mutation_rejected: use tracking/layout persistence authority"
        end
        return true, mutationErr, mutationExtra
    end, { delayMs = tonumber(delayMs) or 300, reason = reason or "buff_display_settings_changed", durable = durable == true })
    if type(F.InvalidateSettingsCache) == "function" then F:InvalidateSettingsCache() end
    return ok, err, extra
end

function F:MutateTrackingStore(mutator, reason)
    -- 中文维护注释（Tracking A/B 事务）：先改 detached/current Domain，再把完整 tracking snapshot
    -- 写入 inactive player/target/meta 三个 Store；每个 Store 必须 durable readback 成功，最后才提交
    -- manifest。任意前置失败都恢复内存，并且 manifest 保持旧 generation，因此不会破坏上一份可靠配置。
    -- 该函数故意不提供 debounce：tracking 用户选择属于低频高价值配置，准确率/可恢复性优先于写入延迟。
    local loaded, loadErr = self:EnsureStoreLoaded()
    if loaded ~= true then return false, loadErr or "状态显示 Tracking 尚未读取" end
    local beforeState = Copy(self.State)
    local beforeSettings = SettingsAuthoritySnapshotFromState(beforeState)
    local beforeLayout = LayoutSnapshotFromSettings(beforeState.settings)
    local callOk, result, mutationErr, extra = pcall(mutator)
    if callOk ~= true or result == false then
        ApplyState(beforeState)
        return false, callOk == true and tostring(mutationErr or "tracking mutation rejected") or tostring(result)
    end
    if not TablesEqual(beforeSettings, SettingsAuthoritySnapshotFromState(self.State))
        or not TablesEqual(beforeLayout, LayoutSnapshotFromSettings(self.State.settings)) then
        ApplyState(beforeState)
        return false, "cross_domain_tracking_mutation_rejected"
    end
    local committed, commitErr = self:CommitTrackingSnapshot(TrackingSnapshotFromState(self.State), reason or "tracking_changed")
    if committed ~= true then
        ApplyState(beforeState)
        if type(F.InvalidateSettingsCache) == "function" then F:InvalidateSettingsCache() end
        return false, commitErr or "tracking commit failed"
    end
    if type(F.InvalidateSettingsCache) == "function" then F:InvalidateSettingsCache() end
    return true, mutationErr, extra
end



function F:MutateCompositeStores(mutator, reason)
    -- 中文维护注释（跨域导入事务）：完整导入可能同时修改 settings、HUD layout 与 tracking/meta。
    -- 旧单 Store 可以天然“一次写”，拆分后必须显式协调。这里先在内存完成纯 Domain mutation，
    -- 再写 settings/layout 小 Store，最后写 tracking inactive A/B 并以 manifest 提交。Tracking 始终
    -- 最后提交，因为 manifest 是最大的数据 Authority；若前置小 Store 或 tracking 失败，会把内存
    -- 恢复到 before，并尽力 durable 回写已经成功的小 Store。任何 rollback 写失败都返回明确错误，
    -- 不会偷偷把旧 monolith 当补偿路径。
    local loaded, loadErr = self:EnsureStoreLoaded()
    if loaded ~= true then return false, loadErr or "状态显示存档尚未读取" end
    local before = Copy(self.State)
    local beforeSettings = SettingsAuthoritySnapshotFromState(before)
    local beforeLayout = LayoutSnapshotFromSettings(before.settings)
    local beforeTracking = TrackingSnapshotFromState(before)
    local callOk, result, mutationErr, extra = pcall(mutator)
    if callOk ~= true or result == false then ApplyState(before); return false, callOk == true and tostring(mutationErr or "mutation rejected") or tostring(result) end
    local afterSettings = SettingsAuthoritySnapshotFromState(self.State)
    local afterLayout = LayoutSnapshotFromSettings(self.State.settings)
    local afterTracking = TrackingSnapshotFromState(self.State)
    local settingsChanged = not TablesEqual(beforeSettings, afterSettings)
    local layoutChanged = not TablesEqual(beforeLayout, afterLayout)
    local trackingChanged = not TablesEqual(beforeTracking, afterTracking)

    local function PersistSmall(id, why)
        local ok, err = EnsureSplitStoreLoaded(id, true)
        if ok ~= true then return false, err end
        return P:MutateStore(id, function() return true end, { delayMs = 0, reason = why, durable = true })
    end
    local settingsWritten, layoutWritten = false, false
    if settingsChanged then
        local ok, err = PersistSmall(SETTINGS_STORE_ID, tostring(reason or "composite") .. ":settings")
        if ok ~= true then ApplyState(before); return false, err end
        settingsWritten = true
    end
    if layoutChanged then
        local ok, err = PersistSmall(HUD_LAYOUT_STORE_ID, tostring(reason or "composite") .. ":layout")
        if ok ~= true then
            ApplyState(before)
            if settingsWritten then PersistSmall(SETTINGS_STORE_ID, tostring(reason or "composite") .. ":rollback_settings") end
            return false, err
        end
        layoutWritten = true
        self.HudLayoutStoreSnapshot = Copy(afterLayout)
    end
    if trackingChanged then
        local ok, err = self:CommitTrackingSnapshot(afterTracking, tostring(reason or "composite") .. ":tracking")
        if ok ~= true then
            ApplyState(before)
            local rollbackErrors = {}
            if layoutWritten then local rok,rerr=PersistSmall(HUD_LAYOUT_STORE_ID,tostring(reason or "composite")..":rollback_layout");if rok~=true then rollbackErrors[#rollbackErrors+1]=tostring(rerr) end end
            if settingsWritten then local rok,rerr=PersistSmall(SETTINGS_STORE_ID,tostring(reason or "composite")..":rollback_settings");if rok~=true then rollbackErrors[#rollbackErrors+1]=tostring(rerr) end end
            return false, tostring(err or "tracking commit failed") .. (#rollbackErrors>0 and ("|rollback="..table.concat(rollbackErrors,";")) or "")
        end
    end
    if type(F.InvalidateSettingsCache) == "function" then F:InvalidateSettingsCache() end
    return true, mutationErr, extra
end

function F:MutateHudLayoutStore(mutator, delayMs, reason, durable)
    if type(P.MutateStore) ~= "function" then return false, "Persistence mutation transaction unavailable" end
    local loaded, loadErr = self:EnsureStoreLoaded()
    if loaded ~= true then return false, loadErr or "HUD 布局存档尚未读取" end
    local ok, err, extra = P:MutateStore(HUD_LAYOUT_STORE_ID, function()
        return mutator()
    end, { delayMs = tonumber(delayMs) or 300, reason = reason or "buff_display_layout_changed", durable = durable == true })
    if ok == true then
        -- 非 durable 的策略/组件编辑也已经是当前 Domain Authority；缓存它以防主 Store 独立重读。
        self.HudLayoutStoreSnapshot = self:GetLayoutSettingsSnapshot()
    end
    if type(F.InvalidateSettingsCache) == "function" then F:InvalidateSettingsCache() end
    return ok, err, extra
end

function F:GetComponent(key)
    key = tostring(key or "")
    return self.State.settings.components[key] or nil
end

function F:GetTracked(category, scope)
    category = category == "debuff" and "debuff" or (category == "auto" and "auto" or "buff")
    local tracked = type(self.State.settings.tracked) == "table" and self.State.settings.tracked or {}
    if scope == "player" or scope == "target" then
        local scoped = type(tracked[scope]) == "table" and tracked[scope] or {}
        return Copy(scoped[category] or {})
    end
    -- 兼容旧调用：未给 scope 时返回两个范围的去重并集，只用于冷路径/旧扩展；HUD 热路径使用 BuildTrackedIndex。
    local out, seen = {}, {}
    for _, scopeKey in ipairs({ "player", "target" }) do
        local scoped = type(tracked[scopeKey]) == "table" and tracked[scopeKey] or {}
        for _, id in ipairs(type(scoped[category]) == "table" and scoped[category] or {}) do
            if not seen[id] then seen[id] = true; out[#out + 1] = id end
        end
    end
    table.sort(out)
    return out
end

function F:GetClassification() return Copy(self.State.settings.classification or {}) end

local function RemoveId(list, id)
    local out = {}
    for _, item in ipairs(type(list) == "table" and list or {}) do if item ~= id then out[#out + 1] = item end end
    return out
end

local function HasId(list, id)
    for _, item in ipairs(type(list) == "table" and list or {}) do if item == id then return true end end
    return false
end

local function ScopedTracked(settings, scope)
    settings.tracked = type(settings.tracked) == "table" and settings.tracked or EmptyTrackedScopes()
    settings.tracked[scope] = type(settings.tracked[scope]) == "table" and settings.tracked[scope] or { buff = {}, debuff = {}, auto = {} }
    local scoped = settings.tracked[scope]
    for _, category in ipairs(TRACKING_CATEGORIES) do scoped[category] = type(scoped[category]) == "table" and scoped[category] or {} end
    return scoped
end

-- 中文维护注释（schema8 单通道 Authority）：四个可见按钮只调用此入口；同 ID 可跨 scope/显式类别并存。
-- Auto 只服务旧配置/内置库的“尚未人工放置”状态，并没有可见按钮。用户第一次显式设置 Buff/Debuff 时，
-- 必须让该 ID 的 player/target Auto 一并退让；否则内置库默认导入两边 Auto 后，用户点“仅目标 Buff”仍会被
-- 隐藏的 player Auto 强制显示在自身，违背四按钮模型。这里只清 Auto，不动另一 scope/类别的显式选择。
function F:IsTrackedChannel(id, scope, category)
    id = math.floor(tonumber(id) or 0)
    if id <= 0 or (scope ~= "player" and scope ~= "target")
        or (category ~= "buff" and category ~= "debuff" and category ~= "auto") then return false end
    local tracked = type(self.State.settings.tracked) == "table" and self.State.settings.tracked or {}
    local scoped = type(tracked[scope]) == "table" and tracked[scope] or {}
    return HasId(scoped[category], id)
end

-- Compatibility query. Without a scope this means "tracked anywhere"; with category it accepts same-scope Auto
-- as the old API did. New UI must use IsTrackedChannel to avoid hiding which channel actually owns the ID.
function F:IsTrackedId(id, category, scope)
    id = math.floor(tonumber(id) or 0)
    if id <= 0 then return false end
    local scopes = (scope == "player" or scope == "target") and { scope } or { "player", "target" }
    for _, scopeKey in ipairs(scopes) do
        if category == "buff" or category == "debuff" then
            if self:IsTrackedChannel(id, scopeKey, category) or self:IsTrackedChannel(id, scopeKey, "auto") then return true end
        elseif category == "auto" then
            if self:IsTrackedChannel(id, scopeKey, "auto") then return true end
        else
            for _, bucket in ipairs(TRACKING_CATEGORIES) do if self:IsTrackedChannel(id, scopeKey, bucket) then return true end end
        end
    end
    return false
end

function F:SetTrackedChannel(id, scope, category, enabled)
    id = tonumber(id)
    if id == nil or id ~= math.floor(id) or id <= 0 or id > 2147483647 then return false, "状态 ID 无效" end
    if scope ~= "player" and scope ~= "target" then return false, "追踪范围必须是 player 或 target" end
    if category ~= "buff" and category ~= "debuff" and category ~= "auto" then return false, "追踪类型必须是 buff/debuff/auto" end
    if enabled == true and not self:IsTrackedChannel(id, scope, category) then
        local scoped = type(self.State.settings.tracked[scope]) == "table" and self.State.settings.tracked[scope] or {}
        if #(type(scoped[category]) == "table" and scoped[category] or {}) >= 1024 then return false, "该追踪通道最多 1024 个状态" end
    end
    local ok, err = self:MutateTrackingStore(function()
        local scoped = ScopedTracked(self.State.settings, scope)
        scoped[category] = RemoveId(scoped[category], id)
        if enabled == true then
            if category ~= "auto" then
                -- Manual placement becomes the visible Authority for this ID. Retire hidden Auto in both scopes so
                -- the four-button UI can actually express self-only / target-only without a ghost legacy channel.
                for _, scopeKey in ipairs(TRACKING_SCOPES) do
                    local autoScoped = ScopedTracked(self.State.settings, scopeKey)
                    autoScoped.auto = RemoveId(autoScoped.auto, id)
                end
            elseif HasId(scoped.buff, id) or HasId(scoped.debuff, id) then
                -- Explicit user placement is stronger than library/legacy Auto. Treat re-adding Auto as an idempotent no-op.
                return true
            end
            if #scoped[category] >= 1024 then return false, "该追踪通道最多 1024 个状态" end
            scoped[category][#scoped[category] + 1] = id
            table.sort(scoped[category])
        end
        return true
    end, "tracked_" .. scope .. "_" .. category .. "_" .. tostring(id))
    if ok == true and S.Events and type(S.Events.Publish) == "function" then S.Events:Publish("v3.buff_display.settings", "tracked") end
    return ok, err
end

-- Legacy/global command: enabling means both scopes, preserving schema<=7 semantics; disabling removes all six channels.
-- One Persistence transaction owns the whole compatibility mutation so old callers cannot leave player/target half-written.
function F:SetTrackedId(id, category, enabled)
    id = tonumber(id)
    if id == nil or id ~= math.floor(id) or id <= 0 or id > 2147483647 then return false, "状态 ID 无效" end
    if category ~= "buff" and category ~= "debuff" and category ~= "auto" then category = "auto" end
    local ok, err = self:MutateTrackingStore(function()
        for _, scope in ipairs(TRACKING_SCOPES) do
            local scoped = ScopedTracked(self.State.settings, scope)
            if enabled == true then
                if category == "auto" and (HasId(scoped.buff, id) or HasId(scoped.debuff, id)) then
                    -- preserve explicit scope choices
                else
                    scoped[category] = RemoveId(scoped[category], id)
                    if category ~= "auto" then scoped.auto = RemoveId(scoped.auto, id) end
                    if #scoped[category] >= 1024 then return false, "该追踪通道最多 1024 个状态" end
                    scoped[category][#scoped[category] + 1] = id; table.sort(scoped[category])
                end
            else
                for _, bucket in ipairs(TRACKING_CATEGORIES) do scoped[bucket] = RemoveId(scoped[bucket], id) end
            end
        end
        return true
    end, "tracked_global_" .. category .. "_" .. tostring(id))
    if ok == true and S.Events and type(S.Events.Publish) == "function" then S.Events:Publish("v3.buff_display.settings", "tracked") end
    return ok, err
end

function F:ClearTrackedIds(category, scope)
    local ok, err = self:MutateTrackingStore(function()
        local scopes = (scope == "player" or scope == "target") and { scope } or TRACKING_SCOPES
        for _, scopeKey in ipairs(scopes) do
            local scoped = ScopedTracked(self.State.settings, scopeKey)
            if category == "buff" or category == "debuff" or category == "auto" then scoped[category] = {}
            else for _, bucket in ipairs(TRACKING_CATEGORIES) do scoped[bucket] = {} end end
        end
        return true
    end, "tracked_clear")
    if ok ~= true then return false, err or "清空追踪状态保存失败" end
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
    local marked, markErr = self:MutateHudLayoutStore(function()
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
    -- schema8: classification is metadata only. Tracking placement is scope-aware and must never be rewritten here.
    local marked, markErr = self:MutateTrackingStore(function()
        local classification = self.State.settings.classification or {}
        classification[id] = category
        self.State.settings.classification = classification
        return true
    end, "classification_" .. tostring(id))
    if marked ~= true then return false, markErr or "人工分类保存失败" end
    if S.Events ~= nil and type(S.Events.Publish) == "function" then S.Events:Publish("v3.buff_display.settings", "classification") end
    return true
end

function F:ClearClassification(id)
    id = math.floor(tonumber(id) or 0)
    if id <= 0 then return false, "Buff ID 无效" end
    local marked, markErr = self:MutateTrackingStore(function()
        local classification = self.State.settings.classification or {}
        classification[id] = nil
        self.State.settings.classification = classification
        return true
    end, "classification_clear_" .. tostring(id))
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
    elseif key == "freezeEnabled" then settings.freezeEnabled = false -- 旧导入兼容；实时冻结由 Feature 命令拥有。
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
    -- 当前状态显示页不再使用旧 PersistentBinding；仍保留兼容入口。若未来绑定 HUD layout 字段，
    -- 必须走独立 Store 的 mutation，不能“先改内存再由无 key 的 MarkStoreDirty 写主 Store”。
    if IsLayoutSettingKey(key) then return self:SetSettingValue(key, value) end
    local ok, err = self:ApplySettingRaw(key, value)
    if ok ~= true then return false, err end
    if S.Events ~= nil and type(S.Events.Publish) == "function" then S.Events:Publish("v3.buff_display.settings", tostring(key or "")) end
    return true
end

function F:SetSettingValue(key, value)
    local mutator = IsLayoutSettingKey(key) and self.MutateHudLayoutStore or self.MutateStore
    local marked, markErr = mutator(self, function()
        return self:ApplySettingRaw(key, value)
    end, 300, "setting_" .. tostring(key))
    if marked ~= true then return false, markErr or "状态显示设置保存失败" end
    if S.Events ~= nil and type(S.Events.Publish) == "function" then S.Events:Publish("v3.buff_display.settings", tostring(key or "")) end
    return true
end

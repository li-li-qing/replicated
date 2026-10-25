-- Replicated Suite · 状态显示设置存储
-- 作者：Replicated
-- QQ群：1104129461
-- 只保存显示策略，Aura 会话事实归 AuraObservationV3。旧存档须先按对应 schema 的 canonical 验真，再迁移。
-- player 沿用历史布局字段，targetLayout 独立保存；hidden 是检测来源，分类覆盖与追踪选择分开。
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
-- 结构新增必须升级 schema；旧 canonical 在下方以词法隔离冻结，不能冒用 schema5。
local SCHEMA = 8
-- 布局预设版本独立于 SCHEMA：schema4 引入追踪分类/分类规则，schema5 仅增加第二持久 HUD。几何预设演进使用此计数，持久结构变化必须增加 SCHEMA。
-- 当前紧凑单行装备与血条锚点布局使用局部微调偏移，组件 y 不再表示屏幕偏移，默认均为 0。
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

-- x/y 是相对血条代理矩形的局部偏移；0 由布局函数安排 Buff、Debuff、装备和信息的位置。
-- ranged 默认关闭，wings 默认开启；此处保留图标 24→29、装备 22→26 的历史预设。
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

-- HUD_TEMPLATE_V1 已核实的 TARGET|EQUIP 默认值，只用于新安装和恢复默认。
-- 已有 targetLayout 不覆盖；缺失时仍按兼容规则复制 player。其余组件继承 player 默认值。
local TARGET_EQUIPMENT_TEMPLATE = {
    mainHand = { enabled = true, x = -32, y = 0, size = 22, alpha = 1.0 },
    offHand  = { enabled = true, x = -33, y = 0, size = 22, alpha = 1.0 },
    ranged   = { enabled = true, x = 39,  y = 0, size = 22, alpha = 1.0 },
    wings    = { enabled = true, x = 0,   y = 0, size = 22, alpha = 1.0 },
}

local function NormalizeTrackedIds(value)
    -- 每分类上限 1024：本函数每次加载/保存都会运行，该上限决定真实列表容量。旧 schema1-3 可含数百 ID，实机曾有 713，禁止静默截断。1024 仍满足 maxEntriesPerTable=2048 的 SaveData 预算。
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
        -- 缺失字段必须继承组件专用默认；ranged 等默认关闭组件不能用通用 ~=false 规则意外启用。
        enabled = enabled,
        x = ClampInt(value.x, -400, 400, defaults.x),
        y = ClampInt(value.y, -400, 400, defaults.y),
        size = ClampInt(value.size, 0, 64, defaults.size),
        fontSize = ClampInt(value.fontSize, 0, 32, defaults.fontSize),
        alpha = ClampFloat(value.alpha, 0.1, 1.0, defaults.alpha),
        -- CastBar 专用字段，其他组件忽略：width 为像素长度，showText 控制下方技能名标签。
        width = ClampInt(value.width, 20, 480, defaults.width or 120),
        showText = value.showText ~= false,
        -- Buff/Debuff 行专用布局字段，其他组件忽略。
        spacing = ClampInt(value.spacing, 0, 24, defaults.spacing or 2),
        maxPerRow = ClampInt(value.maxPerRow, 1, 16, defaults.maxPerRow or 8),
        maxRows = ClampInt(value.maxRows, 1, 4, defaults.maxRows or 2),
    }
end

local function NormalizeComponents(value)
    value = type(value) == "table" and value or {}
    local out = {}
    for _, key in ipairs(COMPONENT_KEYS) do
        -- 存储值只按当前默认归一化，缺失字段从默认补齐。遵循 2026-09-01 指令，不按旧默认指纹迁移；旧插件代仅供参考，不沿用其状态。
        out[key] = NormalizeComponent(value[key], COMPONENT_DEFAULTS[key])
    end
    return out
end

-- player 保留旧平面字段，targetLayout 独立保存目标几何；新增视觉字段也要进入此 normalizer。
-- schema4/5/6 的历史 canonical 按原规则验真；schema4 验真后才复制 player 作为初始 target。
-- 对外只返回副本，避免界面直接修改 F.State。
local function NormalizeHudProfile(value, fallback)
    fallback = type(fallback) == "table" and fallback or {}
    if type(value) ~= "table" then return Copy(fallback) end
    local plateFallback = type(fallback.plate) == "table" and fallback.plate or {}
    local infoFallback = type(fallback.info) == "table" and fallback.info or {}
    local componentsFallback = type(fallback.components) == "table" and fallback.components or {}

    -- 按字段叠加 fallback，再统一限幅。部分组件缺失的 fontSize/spacing/maxRows 应继承用户的 player 布局，而非全局默认。
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
    -- 区分 nil 的全新默认请求与没有 targetLayout 的旧设置表；后者遵守 schema5 目标首次继承当前玩家布局规则，只有全新安装/显式 Reset 才用发布目标模板。
    local isFreshDefault = type(value) ~= "table"
    value = type(value) == "table" and value or {}
    local tracked = type(value.tracked) == "table" and value.tracked or {}
    -- RU API 不提供 Native 单位框矩形，NativeBarProxy 以单位屏幕投影点加可校准偏移，由玩家对齐游戏血条；仅用于 left/right/top/bottom/center 几何，不绘制。
    local plate = type(value.plate) == "table" and value.plate or {}
    local info = type(value.info) == "table" and value.info or {}
    -- 兼容旧 schema4 存档中的 headIconSize/headMaxIcons：仅在标准组件字段缺失时折叠这些历史重复字段；归一化状态不保留别名，所有实时消费者共用唯一字段权威。
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
    -- y=0 默认让代理中心位于单位投影点；玩家通过校准模式/plate.y 滑条对齐 Native 血条。默认 plate.y=22 配合 1.2 倍尺寸，比原 26 上移 4px。
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
        -- 旧单 HUD 存档禁止突然套用发行模板；按 schema5 规则，仅首次从用户当前 player 布局初始化 target。
        normalizedTargetProfile = Copy(normalizedPlayerProfile)
    end
    return {
        showBuffs = value.showBuffs ~= false,
        showDebuffs = value.showDebuffs ~= false,
        showHidden = value.showHidden == true,
        -- freezeEnabled 保留已过期/消失的追踪行，沿用旧 Plates 冻结语义；开启时 Feature 保存会话冻结行快照。
        freezeEnabled = value.freezeEnabled == true,
        playerRows = ClampInt(value.playerRows, 1, 64, 24),
        targetRows = ClampInt(value.targetRows, 1, 64, 24),
        -- 依据 2026-09-01 节奏证据，旧默认精确值 400/100 升级为 120/50；它们在此前只有默认来源。其他用户自调值全部保留，保证升级存档使用更快节奏而不重写自定义设置。
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
        -- 总体 plate scale 同时缩放血条、图标和文字。
        plateScale = normalizedPlayerProfile.plateScale,
        -- NativeBarProxy 由玩家通过 x/y/width/height 对齐原生血条，仅参与布局不绘制；enabled/opacity/showName 仅为向后兼容保留，渲染器忽略。
        plate = Copy(normalizedPlayerProfile.plate),
        -- Buff 上方信息行：职业、装备分、距离，各自可切换。
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

-- 冻结 .18.202 之前的 schema4 canonical，仅用于旧档验真，不写盘。
-- 不能简单删除 targetLayout 后重算：当时 plate.y 等缺省规则也有差异。
-- Persistence 负责精确比对旧指纹、4→5 迁移和重新盖章；新增字段必须升级 schema。
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

-- 同名 local 重新绑定当前 normalizer，让 schema4/5 的旧 closure 保留原规则。
-- 先验历史指纹，再迁移、重新盖章。冷却字段只保存选择和几何，目标 CD 组件保持关闭。
local NormalizeSchema5State = NormalizeState
local NormalizeSchema5Settings = NormalizeSettings
local NormalizeSchema5HudProfile = NormalizeHudProfile
local HudProfileFromSchema5Settings = HudProfileFromSettings
local COMPONENT_KEYS = Copy(COMPONENT_KEYS)
COMPONENT_KEYS[#COMPONENT_KEYS + 1] = "cooldowns"
local COMPONENT_DEFAULTS = Copy(COMPONENT_DEFAULTS)
COMPONENT_DEFAULTS.cooldowns = { enabled=false, x=0, y=90, size=29, fontSize=11, alpha=1, spacing=2, maxPerRow=8, maxRows=2 }
-- 历史 canonical 捕获的 LAYOUT_PRESET_VERSION=3 不能改。v4 表示装备从左到右排列；部分旧档已到 v4 却仍关闭 ranged。
-- v5 只补迁移精确匹配旧默认几何的 v3/v4 配置，自定义布局不动；之后用户主动关闭不会再被开启。
local CURRENT_LAYOUT_PRESET_VERSION = 5
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
-- hud.1.1 实机模板：三页偏移 619+619+314，wire=9BF4FA11，raw=1539/3486F051，共 11 条 V2 记录。
-- 仅新安装、默认快照和恢复默认使用；已有布局及历史 closure 的缺省规则保持不变。
-- 坐标为局部 screen-y-v1，不能再按 2560×1440/uiScale=1 乘缩放；Aura 的旧存储 Y 方向相反，本模板均为 0。
-- 只固化导出过的字段，player/target 分别生成独立表。
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
    -- 必须在nil被替换成{}之前区分fresh；空表、旧档缺targetLayout也不是发行模板请求。
    local isFreshDefault = type(value) ~= "table"
    local out = NormalizeSchema5Settings(value)
    value = type(value)=="table" and value or {}
    -- schema6 旧存档中的 v3 必须规范化后仍是 v3，保证历史 Hash 不变；
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
        -- 默认入口集中到这一个纯函数分支；Reset/校准默认均经此处，不保存、不读Native。
        -- target显式覆盖本次全部已验真字段，避免继承历史TARGET装备的-32/-33/22px与远程开启。
        local player = NormalizeHudProfile(VERIFIED_HUD_DEFAULT_PROFILE, HudProfileFromSettings(out))
        -- 原始实机模板保留 ranged=false 作为历史证据；仅在 fresh/reset 入口开启玩家 ranged。
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
-- RU 回读可能把数字序号变成字符串；先无损重建 dense 候选，再用对应 schema 的 canonical 验证原章，不重分类或补 ID。
-- 另有 schema8/Transport5 实机事故：distance.x=-1 被省略，Normalize 回落为 0。仅在原字段为 nil、当前值为 0 时枚举 [-400,400] 的非零整数，整份指纹唯一命中才恢复。
-- 不扩展到其它坐标或追踪字段；只走 mismatch 冷路径。恢复后不重写旧主 Store，后续 HUD 保存改走 layout 小 Store。
local function RecoverSchema8DistanceXTransport5Omission(decoded, stamped, current, raw, store, prefix)
    local settings = type(decoded) == "table" and type(decoded.settings) == "table" and decoded.settings or nil
    local components = type(settings) == "table" and type(settings.components) == "table" and settings.components or nil
    local distance = type(components) == "table" and type(components.distance) == "table" and components.distance or nil
    local canonicalDistance = type(current) == "table" and type(current.settings) == "table"
        and type(current.settings.components) == "table" and type(current.settings.components.distance) == "table"
        and current.settings.components.distance or nil
    -- decoded 已是解开 transport envelope 后、Normalize 之前的 payload；用 distance.x==nil 判断字段省略，不依赖 raw.payload 层级。
    -- current 是归一化后的 canonical，此时缺字段已回落到 0。
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
    -- 只替换旧章唯一证明的 x，避免调用到历史 NormalizeState closure；Core 随后仍按当前 normalizer 重建并再次比章。
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
            -- 该失败形状与已实证跑商共用Floating中心比例。先严格确认
            -- 追踪列表完整且未重建，再在原schema5/6 canonical上尝试单轴精度恢复；不是
            -- 先迁移再比较旧章。复合序列+数值漂移当前不猜，历史ID/双HUD/默认值仍保持原链路。
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

-- gearScoreFormat 按 HUD 独立保存 full/compact，只影响文字。
-- 先冻结 schema6 normalizer，再叠加 schema7 字段；旧 schema4/5/6 hook 仍使用原 closure。schema6 缺字段迁移为 full。
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

-- RU 可能把 dense 数组数字索引变为字符串。schema7 也须先重建索引候选，再精确验证原 fingerprint。
-- 只允许已有的索引表示与 Floating 单轴精度恢复；schema4/5/6 委托冻结 hook，避免新默认值污染旧章。
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

-- schema<7 到 7 必须无损迁移；Persistence 调用 migrate(raw,from,to)，失败时设写保护，保证原始数据不丢失。
local function MigrateState(value, fromSchema)
    value = type(value) == "table" and value or {}
    local settings = type(value.settings) == "table" and value.settings or {}
    local out = NormalizeState(value)

    -- 将旧平面追踪 ID 分配到分类桶；未知 ID 由共享服务分类，默认 buff，禁止丢 ID。schema3 使用 settings.tracked={101,...}，schema4 改分类桶；同时接受 trackedIds、顶层 trackedIds 与平面数组。
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

-- schema8 将追踪分为 player/target × buff/debuff/auto 六通道；旧全局选择在验真后复制到两侧。
-- 分类覆盖仍是独立元数据。显式 Buff/Debuff 可跨 scope 并存；首次显式放置一个 ID 时，两侧 Auto 都退让，其它显式选择保留。
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
        -- schema≤7 全局白名单表示两个 HUD 都使用；必须复制，不能猜测更窄 scope。
        for _, category in ipairs(TRACKING_CATEGORIES) do
            local ids = NormalizeTrackedIds(value[category])
            out.player[category], out.target[category] = Copy(ids), Copy(ids)
        end
    end
    -- 同一 scope 内 Auto 仅作极性回退，显式通道优先；Buff 与 Debuff 刻意独立，因为 UI 四个动作均为切换开关。
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

-- RU 可能丢掉 T5 marker/count，留下截断的 chunks 普通表，transport 解码仍会成功。
-- 仅 Framework3/schema8/Transport5 mismatch 时生成候选：一侧 auto 必须是另一侧完整 vector 的物理前缀，健康侧须解为 dense 正整数列表，补回后整份 canonical 必须精确命中旧章。
-- 不处理 buff/debuff、任意 sparse map、非连续 chunk、额外键或 marker/count 冲突。最多审计 64 chunk/1024 ID，只走 Load/Save 回读冷路径。
local function RecoverTransport5ScopedAutoPrefix(decoded, stamped, raw, store, prefix)
    if type(raw) ~= "table" or type(raw.__rsmeta) ~= "table" or tonumber(raw.__rsmeta.transportVersion) ~= 5
        or type(decoded) ~= "table" or type(decoded.settings) ~= "table" or type(decoded.settings.tracked) ~= "table" then
        return nil
    end

    -- Core 已解开物理 envelope：健康 T5 已是 dense 数组，丢 marker 的坏侧仍是 chunks 普通表。
    -- 将健康侧重新编码后与幸存 chunk 逐字比较，无需扩大 hook 接口或缓存物理 raw。
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
                -- 末尾 chunk 可能截在十进制 ID 中间，例如 ...,23524,236；只能把它当字节前缀，不能当 ID=236。
                -- 前置 chunk 必须逐字相等，chunks 连续，outer map 只含 chunks/count；最后一块须为健康 twin 对应块的严格字节前缀。
                -- 完整 twin 候选还须精确命中整份旧章。仅 schema8/Transport5 mismatch 冷路径，最多 64 chunk/1024 ID；不能扩成任意 substring 或中段修补。
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

        -- 先处理 marker/count 丢失的 T5 chunks 残片；generic dense 修复会因 chunks 键提前报 invalid_index。
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
        -- 仅 CURRENT schema8/Framework3/Transport5、两侧 group 均存在且恰有一侧 auto 物理字段为 nil 时，才用完整 twin 生成候选。
        -- 空列表不算缺失，buff/debuff 不修；整份 Store 重新 Normalize 后必须精确命中旧章，合法 scope 分叉仍会拒绝。
        -- 这里只返回候选，Core 继续预算、验真和 Apply/回读；不写盘、不清 Fence。
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
    -- Core 也会不传 fromSchema 调用 migrate 来归一化当前 Domain。nil/8+ 只能走 schema8 Normalize；仅明确 fromSchema<8 才迁移。
    -- 把 nil 当 0 会将六通道再次送入旧平面迁移器，保存时合法地清空追踪。
    local sourceSchema = tonumber(fromSchema)
    if sourceSchema == nil or sourceSchema >= 8 then return NormalizeState(value) end
    -- 先由固定旧迁移器重建全部 schema8 前字段（HUD/library/cooldowns），再仅转换追踪表示；保证迁移所有权单一且有序。
    local legacy = MigrateStateSchema7(value, sourceSchema)
    local out = NormalizeState(legacy)
    out.settings.tracked = NormalizeTrackedScopes(type(legacy.settings) == "table" and legacy.settings.tracked or nil)
    return out
end

-- T4 物理恢复仅接受当前 Store/owner、Framework3/schema8/Transport4 和 missing_chunk_v4。
-- 优先用完整 twin；双方同段丢失时，才可用 importedPacks 对应的静态 Catalog 生成有限候选，count 与所有幸存 chunk 必须逐字相等。
-- Core 仍重新解码并验证 envelope/业务指纹、预算、迁移和 Apply；不能用目录覆盖用户配置或从 Hash 反推 ID。
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
    -- 物理修复会改 raw，先保留本次失败 Load 的副本。twin 候选指纹不符时，Catalog 候选须从事故原貌重建。
    -- 副本只用于候选生成，不 Apply、写盘或清 Fence。
    local originalRaw = Copy(raw)

    local marker, chunkSize, limit = "__rs_t4:a", 16, 2048
    -- 存在的 pN 也可能只有部分 token。按 Transport4 decoder 规则只读审计 bad chunk，区分字段缺失与内容截短。
    -- 不能把 bad 自动当 missing；最终仍由 Core 解码和原指纹验证。
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
    -- twin 必须整体健康；损坏侧所有健康块逐字相同，bad 块只允许 count 截短且为对应块的规范 token 前缀。
    -- 候选仍须通过整份原指纹；用户在丢失块内的合法 scope 分叉不能被覆盖。
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
                -- 整块物理缺失，没有局部字节可比较；最终指纹是唯一权威。
            elseif damaged.bad[index] ~= nil then
                local why = tostring(damaged.bad[index])
                local localText = damaged.present[index]
                -- 仅允许从健康双份恢复已观察到的 RU 截断形态；语法/token 损坏仍保持写保护。
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
    -- 双方缺同一 pN 时，只能从 importedPacks 和只读 Catalog 生成候选，不能从 Hash 反推 ID。
    -- 长度与所有幸存 chunk 必须逐字匹配，Core 再验证 envelope/encoded 双指纹；用户改动或目录版本不符仍保留写保护。
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
    -- 只序列化本次失败 Load 已有的物理证据，记录首个不一致 chunk 的原文/期望值。每块受 Transport4 的 143 bytes 上限约束。
    -- 不重读、不写盘、不尝试新候选，诊断文本不参与 fingerprint。
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

    -- importedPacks 只是历史导入水位，用户可能已取消部分 ID，不能直接当当前集合。
    -- union、每个静态包及 all/recommended 分别生成有限候选；须匹配 count 和所有幸存 pN，完整 chunk 表有歧义就拒绝。
    -- Core 最后仍验证原 encoded/envelope 指纹、schema、预算和迁移，不根据水位补回已取消的 ID。
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

    -- 完整 twin 也可能与损坏侧丢失部分存在合法差异。冷路径预算候选指纹只用于选候选，最终验真与 Apply 仍由 Core 完成。
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

    -- 从原始 raw 另建 Catalog 候选：只补缺块/count 截短块，健康块须相同，截短块须是严格 token 前缀。
    -- 不能精确命中旧章就保留原 twin 候选，由 Core 继续拒绝。
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

        -- 迁移时两侧相同，之后允许独立编辑；仅损坏侧健康块相同、bad 块为严格前缀时生成 twin 候选，仍由原指纹决定是否接受。
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
                -- Catalog 仅恢复整块缺失。存在但畸形的块没有静态恢复权威；健康双份也无法证明时，继续写保护，禁止重写字节。
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

    -- 仅第一候选可解码但指纹不符时尝试 Catalog；没有旧章或指纹计算失败时，保留 primary 交给 Core 拒绝。
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

-- 已知 Transport4 事故的有限恢复桥：同时匹配 old/new 指纹、Store/owner、Framework/schema/transport、物理修复标记、精确缺块拓扑及恢复后双侧 393 项同值形状。
-- 任一条件不同就拒绝。这是单次实机事故的精确许可，不是 schema8 通用恢复；不能按近似数量、前缀或 Hash 猜 ID。
-- Core 验证后重新盖章，后续 Flush 用 Transport5。其它事故须另有完整证据，不能放宽此门禁。
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
F.TrackingPersistenceContractVersion = 1 -- 旧单体仅用于迁移；运行时追踪先提交 inactive player/target/meta 槽，再提交 manifest。
F.LegacyStoreWriteProhibitedContractVersion = 1 -- 强制维护边界：拆分后新代码禁止 durable-save v3.buff_display。
F.HudLayoutStoreContractVersion = 1 -- HUD 布局拥有独立小型 Account/Permanent Store；空 Store 继承已经核实的旧主 Store 布局。
F.Schema5DualHudMigrationContractVersion = 1
F.Schema6TrackingMigrationContractVersion = 1
F.Schema7GearScoreFormatMigrationContractVersion = 1
F.Schema8TrackingScopeMigrationContractVersion = 1
F.Schema8Transport5RecoveryContractVersion = 8 -- 当前 schema 的 Transport5 恢复可接受末块在数字 token 内截断，但候选必须是精确字节前缀，且通过原全 Store 指纹认证。
F.Schema8Transport4RecoveryProbeContractVersion = 4 -- 不匹配的健康双份候选可以回退到精确旧指纹 Catalog 重建；Core 必须再次核实并保持最终权威。
F.Schema8KnownTransport4IncidentRecoveryContractVersion = 1 -- 仅适用于精确 2FBF9352→0EBC870A 和六块 RU 事故形态；接受后由 Core 重打指纹，Transport5 重写。
F.Schema8Transport5ScopedOmissionRecoveryContractVersion = 1 -- 仅当整个当前 Store canonical 精确复现已盖章指纹时，一个物理缺失的 scoped auto 字段才可借用完整双份。
F.Schema8Transport5ScopedPrefixRecoveryContractVersion = 2 -- scoped auto 残留恢复仅将最后存活块作为严格字节前缀，允许 token 边界或 token 内截断；更早块必须逐字节一致，重建全 Store 必须精确匹配盖章指纹。
F.Schema8Transport5DistanceXOmissionRecoveryContractVersion = 1 -- 仅用精确盖章指纹唯一反演已证实遗漏的 player distance.x 整数，范围 [-400,400]；禁止猜其他字段或追踪 ID。
F.LayoutPersistenceBoundaryContractVersion = 3 -- HUD 校准、复制、策略、重置与组件变更必须隔离在 v3.buff_display.layout；禁止路由回 MutateStore(v3.buff_display)，RU 已证明单体追踪 Store 会丢数据。
F.TargetDefaultTemplateContractVersion = 1 -- HUD_TEMPLATE_V1 核实的 TARGET/EQUIP 发布预设。
F.RangedWeaponReleaseDefaultContractVersion = 2 -- 未修改的 v3/v4 ranged=false 仅升级一次为 v5；v5+ 用户主动关闭仍为权威。
F.State = NormalizeState(F.State)
F.StoreLoaded = F.StoreLoaded == true

local function ApplyState(value) F.State = NormalizeState(value) end
if P:GetStore(STORE_ID) == nil then
    local store, err = P:RegisterV3Store({
        id = STORE_ID, owner = "v3.buff_display", scope = P.Scope and P.Scope.Account or "account",
        lifetime = P.Lifetime and P.Lifetime.Permanent or "permanent", schemaVersion = SCHEMA,
        -- T4 字符串分块仍有缺块实证；T5 改用最多 128 块的数字索引 chunks 表。旧 T4 仍可读，冗余恢复必须受原指纹约束。
        transportVersion = 5,
        repairPhysicalTransport = RecoverSchema8ScopedTransport4,
        legacySchemaVersion = 1, key = P.V3KeyPrefix and (P.V3KeyPrefix .. "buff_display") or STORE_ID,
        -- 旧 schema1-3 每类实测可达 713 个 ID，预算不能沿用 192 条/2800 字节，否则保存失败会让整会话写保护。
        -- 713+713 ID 加设置的编码 JSON 小于 16KB，旧路径已有保存实证。
        budget = { maxDepth = 8, maxNodes = 32768, maxStringBytes = 65536, maxEntriesPerTable = 2048 },
        default = function() return NormalizeState(nil) end,
        get = function() return NormalizeState(F.State) end,
        apply = ApplyState,
        migrate = function(value, fromSchema) return MigrateState(value, fromSchema) end,
        -- 旧单 HUD 先按旧 normalizer 命中原章，再做 4→5 迁移；515E1BF3→3B898E2F 仅是已核实事故的最后恢复桥。
        rebuildCanonicalForIntegrity = RebuildHistoricalCanonical,
        -- 当前序列已覆盖保存回读回归，仅声明许可；精确验真由 Core 完成。
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

-- Preview/Undo/Redo/Reset 只改编辑器 Working 副本；Apply 才经 Layout Store 耐久事务提交，失败由 Persistence 回滚。
-- HUD 操作不能刷写旧主 Store，未应用预览不能泄漏到 F.State 或下次重载。
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
        -- LayoutEditor 必须保留当前 profile 的排列代际；若这里仍硬编码 v3，
        -- 用户保存任意 HUD 微调都会把已升级的远程武器排列降级，下一帧图标顺序跳回旧版。
        layoutPresetVersion = ClampInt(value.layoutPresetVersion, 1, CURRENT_LAYOUT_PRESET_VERSION, defaults.layoutPresetVersion),
        headEnabled = value.headEnabled ~= false,
        headShowAll = value.headShowAll == true,
        headPlayer = value.headPlayer ~= false,
        headTarget = value.headTarget ~= false,
        -- 禁止在这里复用 NormalizeSettings 的历史 100→50 指纹；LayoutEditor 快照已是 schema4 值，不是旧输入。
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
            -- Layout Store 须携带 gearScoreFormat，否则 overlay Apply 会丢掉已保存的 compact/full。
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
    -- RU 大表保存可能省略合法 HUD 字段，因此所有 HUD 编辑只写 v3.buff_display.layout。
    -- 先加载主 Store 的已验真旧布局，再由 layout 覆盖；layout 为空时不能套新默认。事务失败只回滚布局，不能改存主 Store。
    -- 新增 HUD 字段要进入 NormalizeLayoutSnapshot；小布局使用 Transport3 的 0/负数保护，无需 T5 数组分块。
    if type(F.State) ~= "table" then F.State = NormalizeState(nil) end
    if type(F.State.settings) ~= "table" then F.State.settings = NormalizeSettings(nil) end
    local normalized = ApplyLayoutSnapshotToSettings(F.State.settings, value)
    -- 保留已提交的 layout 小快照。主 Store 重读会替换 F.State，而 ready 的 layout Store 不会重读；没有快照就会被旧布局覆盖。
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


-- 旧 v3.buff_display 仅作一次性迁移来源，正常配置分属 settings、layout、tracking player/target/meta A/B 和 manifest。
-- 启动先读 manifest；存在时只加载新 Store。首次迁移也须经旧 recovery hook 和原章验真，不清旧字节。
-- inactive 三个分片全部保存并立即回读成功后，manifest 才切换 generation；失败保留上一代。
-- 禁止再保存旧主 Store、绕过 manifest 或把 twin 恢复扩为日常同步。新追踪字段须进入分片提交流程，所有迁移/提交只走冷路径。

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

local function BuildLegacyMigrationCandidate()
    local legacy = P:GetStore(STORE_ID)
    if type(legacy) ~= "table" then return nil, "legacy migration store unavailable" end
    -- 物理解码成功不代表配置可信。旧来源必须通过 Core 的 seal/schema、历史 canonical、recovery hook 和预算；apply=false 不改当前 Domain、不排旧 Store 重盖章。
    -- 旧来源验真失败前不能写任何新分片。
    local loaded, candidate, loadErr = P:LoadStore(STORE_ID, { apply = false })
    if loaded == "empty" then return NormalizeState(nil), "legacy_empty_default" end
    if loaded ~= true or type(candidate) ~= "table" then
        return nil, loadErr or "legacy integrity validation failed"
    end
    -- 方案 A 的 player.auto 残片只复用已注册的精确前缀恢复证明；Core 已核旧 seal
    -- 与整 Store 原章，未知 scope 差异仍拒绝。此状态标签不是额外恢复权限，也不触发第二次读取。
    local probe = tostring(legacy.lastHistoricalRecoveryProbe or "")
    local usedApprovedA = legacy.lastIntegrityStatus == "verified_canonical_recovered_representation"
        and probe:find("t5_prefix_auto=player<-target", 1, true) ~= nil
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

    -- 空 settings Store 的 factory defaults 不能覆盖刚验真的旧显示/窗口
    -- 配置；仅现存 split settings 拥有更高优先级。先只读加载，再按是否已有 Authority 应用。
    local settingsOk, settingsStatus, settingsValue = EnsureSplitStoreLoaded(SETTINGS_STORE_ID, false)
    if settingsOk ~= true then self.State = beforeState; return false, "settings store load failed" end
    if settingsStatus ~= "empty" then
        local existingSettings = type(settingsValue) == "table" and settingsValue or self.SettingsStoreSnapshot
        if type(existingSettings) == "table" then ApplySettingsAuthoritySnapshot(existingSettings) end
    end
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
            -- 预留给未来 Core 暴露；当前下方仅通过显式 LoadStore 应用。
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

-- 校准只改 Presentation Draft；PersistHudCalibrationSnapshot 才提交，取消不碰 F.State。
-- player/target 独立；此接口只保存视觉 profile，不复制追踪、headShowAll 或敌我策略，调用者只取得副本。
function F:NormalizeHudVisualProfile(value, fallback)
    return NormalizeHudProfile(value, fallback)
end

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

-- 精确显隐复用已有 profile 字段和 layout 小 Store。
-- 名称与图标是两个用户意图；页面仅读此投影，不另存显示状态或改追踪集合。
F.ScopedHudVisibilityContractVersion = 1
F.HudVisibilityDefinitions = {
    {key="className",label="职业名称",kind="text"},
    {key="gearScore",label="装备分数",kind="text"},
    {key="distance",label="距离",kind="text"},
    {key="classIcon",label="职业图标",kind="image",component="class"},
    {key="mainHand",label="主手图标",kind="image",component="mainHand"},
    {key="offHand",label="副手图标",kind="image",component="offHand"},
    {key="ranged",label="远程武器",kind="image",component="ranged"},
    {key="wings",label="背部图标",kind="image",component="wings"},
    {key="buffs",label="Buff 图标",kind="image",component="buffs"},
    {key="debuffs",label="Debuff 图标",kind="image",component="debuffs"},
    {key="cooldowns",label="技能 CD",kind="image",component="cooldowns"},
    {key="castBar",label="施法条",kind="bar",component="castBar"},
    {key="alias",label="自定义名字",kind="text",targetOnly=true},
}

function F:GetHudVisibilityProjection(scope)
    if scope~="player" and scope~="target" then return nil,"HUD 范围无效" end
    local profile=self:GetScopeLayoutSettings(scope)
    local info,components=profile.info or {},profile.components or {}
    local projection={scope=scope,items={}}
    for _,definition in ipairs(self.HudVisibilityDefinitions) do
        local item=Copy(definition)
        item.available=not item.targetOnly or scope=="target"
        local component=components[item.component or item.key] or {}
        if item.key=="className" then item.visible=info.enabled~=false and info.showClass~=false
        elseif item.key=="gearScore" then item.visible=info.enabled~=false and info.showGear~=false and component.enabled~=false
        elseif item.key=="distance" then item.visible=info.enabled~=false and info.showDistance~=false and component.enabled~=false
        elseif item.key=="classIcon" then item.visible=info.enabled~=false and component.enabled~=false
        elseif item.key=="alias" then
            local alias=type(self.GetTargetAliasHudConfigProjection)=="function" and self:GetTargetAliasHudConfigProjection() or nil
            item.available=item.available and alias~=nil
            item.visible=item.available and alias.enabled~=false
        else item.visible=component.enabled~=false end
        projection.items[#projection.items+1]=item
    end
    return projection
end

function F:SetHudVisibility(scope,key,value)
    if scope~="player" and scope~="target" then return false,"HUD 范围无效" end
    if type(value)~="boolean" then return false,"显示状态必须为开或关" end
    local definition
    for _,item in ipairs(self.HudVisibilityDefinitions) do if item.key==key then definition=item;break end end
    if key~="images" and definition==nil then return false,"未知显示项" end
    if key=="alias" then
        if scope~="target" then return false,"自定义名字仅用于目标 HUD" end
        if type(self.SetCurrentTargetAliasDisplayEnabled)~="function" then return false,"目标自定义名字接口不可用" end
        return self:SetCurrentTargetAliasDisplayEnabled(value)
    end
    local ready,err=self:CanPersistLayoutSettings()
    if ready~=true then return false,err end
    local profile=self:GetScopeLayoutSettings(scope)
    local info,components=profile.info,profile.components
    local function ActivateInfo()
        if info.enabled==false then
            -- 旧 master 关闭时四项均隐藏。只恢复所选项，不能顺带复活其他文字/图标。
            info.showClass,info.showGear,info.showDistance=false,false,false
            components.class.enabled,components.gearScore.enabled,components.distance.enabled=false,false,false
            info.enabled=true
        end
    end
    local function Apply(item)
        if value and (item.key=="className" or item.key=="classIcon" or item.key=="gearScore" or item.key=="distance") then ActivateInfo() end
        if item.key=="className" then info.showClass=value
        elseif item.key=="gearScore" then info.showGear=value;components.gearScore.enabled=value
        elseif item.key=="distance" then info.showDistance=value;components.distance.enabled=value
        else components[item.component].enabled=value end
    end
    if key=="images" then
        for _,item in ipairs(self.HudVisibilityDefinitions) do if item.kind=="image" then Apply(item) end end
    else Apply(definition) end
    return self:PersistHudCalibrationSnapshot({[scope]=profile},"hud_visibility:"..scope..":"..key)
end

function F:GetDefaultHudCalibrationSnapshot()
    local defaults = NormalizeSettings(nil)
    local player = HudProfileFromSettings(defaults)
    -- 目标默认统一取 defaults.targetLayout，让新安装、布局恢复和校准恢复使用同一份已核实模板。
    local target = NormalizeHudProfile(defaults.targetLayout, player)
    return { player = Copy(player), target = Copy(target) }
end

function F:ApplyHudCalibrationSnapshotRaw(snapshot)
    snapshot = type(snapshot) == "table" and snapshot or {}
    local settings = self.State.settings
    local currentPlayer = HudProfileFromSettings(settings)
    local currentTarget = NormalizeHudProfile(settings.targetLayout, currentPlayer)
    local player = NormalizeHudProfile(snapshot.player, currentPlayer)
    -- 只提交 player patch 时不能隐式同步 target；同步须由校准器显式复制，避免部分导入覆盖独立目标布局。
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
        -- CalibrationDraft 只提交 v3.buff_display.layout；旧主 Store 的追踪大数组存在 RU 截断实证，不能作为失败兜底。
        -- 没有 layout 的旧用户先使用已验真布局；首次保存后以 layout 为准。新增 HUD 字段也必须进入 NormalizeLayoutSnapshot。
        -- HUD-only setter/reset/policy 不得对 STORE_ID 调用 MutateStore、SaveStore 或 MarkStoreDirty。
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

-- 布局重置仅恢复 HUD 表现默认，保留追踪管理、分类覆盖、浏览过滤/行数、浮窗状态和 Feature 生命周期偏好；破坏性的出厂重置应由未来全局设置入口负责。
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
    -- Layout Reset 必须同时重置 player 与 target 两套视觉 Authority。
    -- 若只重置旧 player 字段，targetLayout 会保留旧坐标，用户看到的“恢复默认”将只恢复一半。
    settings.targetLayout = Copy(defaults.targetLayout)
    return true, before
end


function F:PersistResetLayoutSettings(reason)
    -- Reset 也必须遵守独立 HUD Layout Authority。若仍只改/存主 Store，已有
    -- layout overlay 会在下次加载重新覆盖默认值，形成“本次看似重置、重载又回来”的双 Authority。
    local saved, saveErr = self:MutateHudLayoutStore(function()
        local ok, err = self:ResetLayoutSettings()
        if ok ~= true then return false, err or "布局重置失败" end
        return true
    end, 0, tostring(reason or "reset_layout_settings"), true)
    if saved ~= true then return false, saveErr or "布局重置保存失败" end
    return true, nil
end

-- 旧调用者的兼容别名，保持与布局重置相同的局部、非破坏语义。
function F:ResetSettings()
    return self:ResetLayoutSettings()
end
-- 只对 v3/v4 且 ranged 完全匹配旧默认（关闭/x0/y0/26px/font0/alpha1）的已验真配置，事务开启并推进 v5。
-- 自定义值不动，v5 后用户再关闭也不重开；保存失败回滚并记录警告，继续使用原配置。
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
    local presetVersion = math.floor(tonumber(settings.layoutPresetVersion) or LAYOUT_PRESET_VERSION)
    -- v5+ 明确表示本次兼容水位已经处理；之后 ranged.enabled 无论 true/false 都是
    -- 用户当前选择，绝不能在 Reload 时再次覆盖。v3/v4 仍可能来自旧版默认遗漏。
    if presetVersion >= CURRENT_LAYOUT_PRESET_VERSION then return true, false end
    local ranged = type(settings.components) == "table" and settings.components.ranged or nil
    -- 只修“旧默认原样未动”的 ranged=false。位置/大小/透明度/字体任一不同都视为
    -- 用户已经接管该组件，不自动开启，也不推进代际，避免升级吞掉个性化 HUD。
    if IsLegacyUntouchedRanged(ranged) ~= true then return true, false end
    local function ApplyUpgrade()
        local current = self.State.settings
        local currentPreset = math.floor(tonumber(current.layoutPresetVersion) or LAYOUT_PRESET_VERSION)
        if currentPreset >= CURRENT_LAYOUT_PRESET_VERSION then return true end
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
        -- v5 提交后同步 HudLayoutStoreSnapshot，否则 ready=true 的加载入口会把缓存中的 v4/ranged=false 再覆盖回来。
        self.HudLayoutStoreSnapshot = self:GetLayoutSettingsSnapshot()
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

    -- 正常启动只读 manifest/settings/layout 及 active tracking 分片。仅首次升级在 manifest 为空时只读迁移旧主 Store。
    -- 迁移后旧损坏字节只作证据，不能把 P:LoadStore(STORE_ID) 加回启动路径。
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
    -- 该兼容入口现在只允许标记 settings 小 Store。
    -- 历史调用若仍把它理解成 v3.buff_display 全量保存，会重新把 HUD/追踪带回同一故障域。
    if type(F.InvalidateSettingsCache) == "function" then F:InvalidateSettingsCache() end
    -- 窗口位置、折叠和锁定只提交 settings 小 Store；最终操作立即回读，预览不走此入口。
    if reason == "widget_geometry" or reason == "widget_layout_reset" or reason == "widget_minimized" or reason == "widget_locked" or reason == "widget_lock"
        or reason == "widget_overall_opacity" or reason == "widget_background_opacity" or reason == "widget_text_opacity" or reason == "widget_font_scale" then
        return P:SaveStore(SETTINGS_STORE_ID, { durable=true, consumeDirty=true, reason=reason })
    end
    return P:MarkDirty(SETTINGS_STORE_ID, tonumber(delayMs) or 300, reason or "buff_display_settings_changed")
end

function F:MutateStore(mutator, delayMs, reason, durable)
    -- 保留旧调用签名，但只允许 settings 字段；tracking/meta 走 MutateTrackingStore，HUD 走 MutateHudLayoutStore。
    -- 事务内比较跨域快照，越界立即恢复并拒绝，避免大数组重新接回单 Store。
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
    -- 先写 inactive player/target/meta，逐个耐久回读成功后才提交 manifest。失败恢复内存并保留旧 generation。
    -- 追踪是低频高价值选择，不提供 debounce。
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
    -- 组合导入先改内存，再写 settings/layout，最后提交 tracking A/B 与 manifest。
    -- 失败恢复内存，并尽力回写已成功的小 Store；回滚失败要返回错误，不能用旧主 Store 补偿。
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

-- 显式放置 Buff/Debuff 时，两侧 Auto 都须移除此 ID，否则“仅目标”仍可能被自身 Auto 显示。其它显式 scope/category 选择保留。
function F:IsTrackedChannel(id, scope, category)
    id = math.floor(tonumber(id) or 0)
    if id <= 0 or (scope ~= "player" and scope ~= "target")
        or (category ~= "buff" and category ~= "debuff" and category ~= "auto") then return false end
    local tracked = type(self.State.settings.tracked) == "table" and self.State.settings.tracked or {}
    local scoped = type(tracked[scope]) == "table" and tracked[scope] or {}
    return HasId(scoped[category], id)
end

-- 兼容查询：不传 scope 表示任意位置追踪；传 category 时仍接受同 scope 的 Auto。新 UI 必须用 IsTrackedChannel，明确哪个通道拥有 ID。
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

-- 基础自己/目标开关只作用于该 scope：开启保留人工类别或加入 Auto，关闭移除该侧三桶。
-- 不能借高级显式放置分支清另一侧 Auto；仍用一次 A/B manifest 事务提交。
function F:SetTrackedScope(id, scope, enabled)
    id = tonumber(id)
    if id == nil or id ~= math.floor(id) or id <= 0 or id > 2147483647 then return false, "状态 ID 无效" end
    if scope ~= "player" and scope ~= "target" then return false, "追踪范围必须是 player 或 target" end
    local loaded, loadErr = self:EnsureStoreLoaded()
    if loaded ~= true then return false, loadErr end
    if self:IsTrackedId(id, nil, scope) == (enabled == true) then return true end
    local ok, err = self:MutateTrackingStore(function()
        local scoped = ScopedTracked(self.State.settings, scope)
        if enabled == true then
            if #scoped.auto >= 1024 then return false, "该追踪通道最多 1024 个状态" end
            scoped.auto[#scoped.auto + 1] = id; table.sort(scoped.auto)
        else
            for _, category in ipairs(TRACKING_CATEGORIES) do scoped[category] = RemoveId(scoped[category], id) end
        end
        return true
    end, "tracked_scope_" .. scope .. "_" .. tostring(id))
    if ok == true and S.Events and type(S.Events.Publish) == "function" then S.Events:Publish("v3.buff_display.settings", "tracked") end
    return ok, err
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
                -- 手动放置成为该 ID 的可见权威；退出两个 scope 的隐藏 Auto，保证四按钮 UI 能表达仅自身/仅目标，不能残留不可见旧通道。
                for _, scopeKey in ipairs(TRACKING_SCOPES) do
                    local autoScoped = ScopedTracked(self.State.settings, scopeKey)
                    autoScoped.auto = RemoveId(autoScoped.auto, id)
                end
            elseif HasId(scoped.buff, id) or HasId(scoped.debuff, id) then
                -- 显式用户放置优先于库/旧 Auto；重复添加 Auto 视为幂等无操作。
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

-- 旧全局命令启用时作用于两个 scope，保留 schema≤7 语义；关闭时移除全部六通道。整个兼容修改由同一 Persistence 事务负责，禁止 player/target 只写一半。
function F:SetTrackedId(id, category, enabled)
    id = tonumber(id)
    if id == nil or id ~= math.floor(id) or id <= 0 or id > 2147483647 then return false, "状态 ID 无效" end
    if category ~= "buff" and category ~= "debuff" and category ~= "auto" then category = "auto" end
    local ok, err = self:MutateTrackingStore(function()
        for _, scope in ipairs(TRACKING_SCOPES) do
            local scoped = ScopedTracked(self.State.settings, scope)
            if enabled == true then
                if category == "auto" and (HasId(scoped.buff, id) or HasId(scoped.debuff, id)) then
                    -- 保留显式 scope 选择。
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

function F:ClearTrackedIds(category, scope, includeCooldowns)
    local ok, err = self:MutateTrackingStore(function()
        local scopes = (scope == "player" or scope == "target") and { scope } or TRACKING_SCOPES
        for _, scopeKey in ipairs(scopes) do
            local scoped = ScopedTracked(self.State.settings, scopeKey)
            if category == "buff" or category == "debuff" or category == "auto" then scoped[category] = {}
            else for _, bucket in ipairs(TRACKING_CATEGORIES) do scoped[bucket] = {} end end
        end
        -- 全部取消使用同一 tracking 事务提交状态和两种旧 CD 路由；保留分类、库元数据和显示配置。
        if includeCooldowns == true then self.State.settings.trackedCooldowns = { skill = {}, mate = {} } end
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
    -- classification 只改元数据，不动六通道追踪选择；与 tracking A/B+manifest 同事务回滚。
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
    -- 清人工极性不是取消/迁移追踪；禁止旧 flat-auto 合并残留改动 player/target。
    -- 跟 SetClassification 共用当前 tracking 事务，不改 schema、不擦除旧存档。
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

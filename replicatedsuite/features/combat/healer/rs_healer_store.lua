------------------------------------------------------------------------
-- Replicated Suite V3 - Healer Settings Store
--
-- Permanent V3 Healer policy + presentation state. The Feature enabled flag is
-- intentionally NOT stored here: FeatureRuntime owns enabled/disabled preference. On first V3
-- load this store imports only known policy fields from the historical Healer
-- account store and never clears or overwrites that legacy source.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local P = S.Persistence
if type(P) ~= "table" or type(P.RegisterV3Store) ~= "function" then return end

S.Features = S.Features or {}
S.Features.Healer = S.Features.Healer or {}
local F = S.Features.Healer
local U = S.Utils

local STORE_ID = "v3.healer"
local SCHEMA = 3
local LEGACY_SCHEMA = 222
local LEGACY_KEY = "replicated_healer_recommender_v2"
local LEGACY_BACKUP_KEY = LEGACY_KEY .. "_backup"
local MAX_RULES = 20
local MAX_ROLE_OVERRIDES = 200

local function DeepCopy(value)
    if U ~= nil and type(U.DeepCopy) == "function" then return U.DeepCopy(value) end
    if type(value) ~= "table" then return value end
    local out = {}
    for key, item in pairs(value) do out[key] = DeepCopy(item) end
    return out
end

local function Clamp(value, minimum, maximum, fallback)
    local n = tonumber(value)
    if n == nil or n ~= n then n = tonumber(fallback) or minimum end
    if n < minimum then n = minimum end
    if n > maximum then n = maximum end
    return n
end

local function ClampInt(value, minimum, maximum, fallback)
    return math.floor(Clamp(value, minimum, maximum, fallback) + 0.5)
end

local function CopyColor(value, fallback)
    value = type(value) == "table" and value or {}
    fallback = type(fallback) == "table" and fallback or {}
    return {
        r = Clamp(value.r, 0, 1, fallback.r or 1),
        g = Clamp(value.g, 0, 1, fallback.g or 1),
        b = Clamp(value.b, 0, 1, fallback.b or 1),
        a = Clamp(value.a, 0.05, 1, fallback.a or 1),
    }
end

local function ParseIds(value)
    local out, seen = {}, {}
    if type(value) == "string" then
        local parsed = {}
        for token in string.gmatch(value, "%d+") do parsed[#parsed + 1] = tonumber(token) end
        value = parsed
    end
    for _, raw in ipairs(type(value) == "table" and value or {}) do
        local id = math.floor(tonumber(raw) or 0)
        if id > 0 and seen[id] ~= true then
            seen[id] = true
            out[#out + 1] = id
        end
    end
    return out
end

local function DefaultRule()
    return {
        name = "持续回血", enabled = true, purpose = 1, sourceMode = 1,
        matchMode = 1, ids = { 25875, 220 }, minStacks = 1,
        minRemainingMs = 0, unknownRemainingValid = true,
        healthRangeEnabled = false, healthMin = 0, healthMax = 100,
        effectType = 1, scoreMode = 2, scoreValue = 25, allowStack = false,
        emergencyRetainPercent = 20, countsAsProtection = true,
        displayPriority = 10, rescuePriority = 50,
        color = { r = 0.72, g = 0.30, b = 1.00, a = 0.82 },
        distanceMode = 1, customDistance = 27, healPriorityThreshold = 70,
        excludeDisplayMode = 1, simpleDisplayGroup = false,
    }
end


local function DefaultRaidSections()
    return {
        { x = 0, y = 140, width = 340, height = 196 },
        { x = 0, y = 344, width = 340, height = 196 },
        { x = 360, y = 140, width = 340, height = 196 },
        { x = 360, y = 344, width = 340, height = 196 },
    }
end

local function DefaultPresentation()
    return {
        head = {
            enabled = false, count = 5, effectMode = 1, shapeMode = 4,
            sizes = { 18, 24, 30, 36 }, showName = false,
            showDistance = false, showScore = false, refreshMs = 50,
        },
        raid = {
            enabled = false, effectMode = 1, showRanks = true, rankCount = 10,
            rankFontSize = 10, rankAlpha = 1, rankCorner = 2,
            rankOffsetX = 1, rankOffsetY = 1, proximityMode = true,
            calibration = false, calibrationSection = 1, calibrationScope = 1,
            sections = DefaultRaidSections(),
        },
    }
end

local function NormalizeRect(value, fallback)
    value = type(value) == "table" and value or {}
    fallback = type(fallback) == "table" and fallback or {}
    return {
        x = Clamp(value.x or value.offsetX, -4000, 4000, fallback.x or 0),
        y = Clamp(value.y or value.offsetY, -4000, 4000, fallback.y or 0),
        width = Clamp(value.width, 120, 1200, fallback.width or 340),
        height = Clamp(value.height, 80, 900, fallback.height or 196),
    }
end

local function NormalizePresentation(value)
    local defaults = DefaultPresentation()
    value = type(value) == "table" and value or {}
    local head = type(value.head) == "table" and value.head or {}
    local raid = type(value.raid) == "table" and value.raid or {}
    local sizes = type(head.sizes) == "table" and head.sizes or {}
    local sections = type(raid.sections) == "table" and raid.sections or {}
    local outSections = {}
    for index = 1, 4 do outSections[index] = NormalizeRect(sections[index], defaults.raid.sections[index]) end
    return {
        head = {
            enabled = head.enabled == true,
            count = ClampInt(head.count, 1, 50, defaults.head.count),
            effectMode = ClampInt(head.effectMode, 1, 3, defaults.head.effectMode),
            shapeMode = ClampInt(head.shapeMode, 1, 4, defaults.head.shapeMode),
            sizes = {
                ClampInt(sizes[1], 12, 60, defaults.head.sizes[1]),
                ClampInt(sizes[2], 12, 60, defaults.head.sizes[2]),
                ClampInt(sizes[3], 12, 60, defaults.head.sizes[3]),
                ClampInt(sizes[4], 12, 60, defaults.head.sizes[4]),
            },
            showName = head.showName == true,
            showDistance = head.showDistance == true,
            showScore = head.showScore == true,
            refreshMs = ClampInt(head.refreshMs, 50, 250, defaults.head.refreshMs),
        },
        raid = {
            enabled = raid.enabled == true,
            effectMode = ClampInt(raid.effectMode, 1, 3, defaults.raid.effectMode),
            showRanks = raid.showRanks ~= false,
            rankCount = ClampInt(raid.rankCount, 0, 50, defaults.raid.rankCount),
            rankFontSize = ClampInt(raid.rankFontSize, 8, 20, defaults.raid.rankFontSize),
            rankAlpha = Clamp(raid.rankAlpha, 0.10, 1.00, defaults.raid.rankAlpha),
            rankCorner = ClampInt(raid.rankCorner, 1, 4, defaults.raid.rankCorner),
            rankOffsetX = Clamp(raid.rankOffsetX, -50, 50, defaults.raid.rankOffsetX),
            rankOffsetY = Clamp(raid.rankOffsetY, -50, 50, defaults.raid.rankOffsetY),
            proximityMode = raid.proximityMode ~= false,
            calibration = raid.calibration == true,
            calibrationSection = ClampInt(raid.calibrationSection, 1, 4, defaults.raid.calibrationSection),
            calibrationScope = ClampInt(raid.calibrationScope, 1, 3, defaults.raid.calibrationScope),
            sections = outSections,
        },
    }
end

local function LegacyPresentation(raw)
    if type(raw) ~= "table" then return DefaultPresentation() end
    local defaults = DefaultPresentation()
    local function LegacyRect(value, fallback)
        return NormalizeRect(type(value) == "table" and {
            x = value.offsetX, y = value.offsetY, width = value.width, height = value.height,
        } or nil, fallback)
    end
    return NormalizePresentation({
        head = {
            enabled = true, count = raw.headMarkerCount, effectMode = raw.headEffectMode,
            shapeMode = raw.headShapeMode, sizes = raw.headSizes, showName = raw.showHeadName,
            showDistance = raw.showHeadDistance, showScore = raw.showHeadScore, refreshMs = 50,
        },
        raid = {
            enabled = true, effectMode = raw.raidEffectMode, showRanks = raw.showRaidRanks,
            rankCount = raw.raidRankCount, rankFontSize = raw.raidRankFontSize,
            rankAlpha = raw.raidRankAlpha, rankCorner = raw.raidRankCorner,
            rankOffsetX = raw.raidRankOffsetX, rankOffsetY = raw.raidRankOffsetY,
            proximityMode = raw.proximityMode, calibration = false,
            calibrationSection = raw.raidCalibrationSection, calibrationScope = raw.raidCalibrationScope,
            sections = {
                LegacyRect(raw.raidOverlayTop, defaults.raid.sections[1]),
                LegacyRect(raw.raidOverlayBottom, defaults.raid.sections[2]),
                LegacyRect(raw.raidOverlayTopRaid2, defaults.raid.sections[3]),
                LegacyRect(raw.raidOverlayBottomRaid2, defaults.raid.sections[4]),
            },
        },
    })
end

local function DefaultSettings()
    return {
        maxDistance = 27,
        enterThreshold = 100,
        exitThreshold = 100,
        selfThreshold = 70,
        emergencyThreshold = 50,
        lowHealthThreshold = 70,
        minHoldMs = 500,
        scoreLead = 5,
        healthScanMs = 150,
        buffScanMs = 300,
        weights = { health = 55, distance = 15, missing = 10, unprotected = 20 },
        healthCurveMode = 2,
        healthAccelMode = 2,
        distanceCurveMode = 2,
        distanceEdgePercent = 20,
        missingSensitivity = 30000,
        levelThresholds = { attention = 40, high = 60, emergency = 80 },
        roleScoringEnabled = false,
        roleScores = { normal = 0, mainTank = 15, offTank = 10, healer = 8, unknown = 0 },
        roleOverrides = {},
        rules = { DefaultRule() },
        trackedBuffs = {
            { id = 25875, name = "持续回血", enabled = true, color = { r = 0.72, g = 0.30, b = 1.00, a = 0.84 } },
            { id = 220, name = "持续回血", enabled = true, color = { r = 0.72, g = 0.30, b = 1.00, a = 0.84 } },
        },
        proximityColor = { r = 1.00, g = 0.42, b = 0.68, a = 0.42 },
        lowHealthColor = { r = 1.00, g = 0.48, b = 0.08, a = 0.78 },
        emergencyColor = { r = 1.00, g = 0.08, b = 0.08, a = 0.92 },
    }
end

local function NormalizeWeights(value)
    value = type(value) == "table" and value or {}
    local health = math.max(0, tonumber(value.health) or 55)
    local distance = math.max(0, tonumber(value.distance) or 15)
    local missing = math.max(0, tonumber(value.missing) or 10)
    local unprotected = math.max(0, tonumber(value.unprotected) or 20)
    local total = health + distance + missing + unprotected
    if total <= 0 then return { health = 55, distance = 15, missing = 10, unprotected = 20 } end
    health = health * 100 / total
    distance = distance * 100 / total
    missing = missing * 100 / total
    unprotected = math.max(0, 100 - health - distance - missing)
    return { health = health, distance = distance, missing = missing, unprotected = unprotected }
end

local function NormalizeRule(value)
    if type(value) ~= "table" then value = DefaultRule() end
    local healthMin = Clamp(value.healthMin, 0, 100, 0)
    local healthMax = Clamp(value.healthMax, healthMin, 100, 100)
    return {
        name = tostring(value.name or "未命名规则"),
        enabled = value.enabled ~= false,
        purpose = ClampInt(value.purpose, 1, 5, 5),
        sourceMode = ClampInt(value.sourceMode, 1, 5, 5),
        matchMode = ClampInt(value.matchMode, 1, 2, 1),
        ids = ParseIds(value.ids or {}),
        minStacks = ClampInt(value.minStacks, 1, 99, 1),
        minRemainingMs = ClampInt(value.minRemainingMs, 0, 3600000, 0),
        unknownRemainingValid = value.unknownRemainingValid ~= false,
        healthRangeEnabled = value.healthRangeEnabled == true,
        healthMin = healthMin, healthMax = healthMax,
        effectType = ClampInt(value.effectType, 1, 4, 2),
        scoreMode = ClampInt(value.scoreMode, 1, 2, 1),
        scoreValue = Clamp(value.scoreValue, 0, 500, 0),
        allowStack = value.allowStack == true,
        emergencyRetainPercent = Clamp(value.emergencyRetainPercent, 0, 100, 20),
        countsAsProtection = value.countsAsProtection == true,
        displayPriority = ClampInt(value.displayPriority, 0, 999, 50),
        rescuePriority = ClampInt(value.rescuePriority, 0, 999, 50),
        color = CopyColor(value.color, { r = 1, g = 0.5, b = 0.1, a = 0.8 }),
        distanceMode = ClampInt(value.distanceMode, 1, 2, 1),
        customDistance = Clamp(value.customDistance, 1, 100, 20),
        healPriorityThreshold = Clamp(value.healPriorityThreshold, 0, 100, 70),
        excludeDisplayMode = ClampInt(value.excludeDisplayMode, 1, 2, 1),
        simpleDisplayGroup = value.simpleDisplayGroup == true,
    }
end

local function NormalizeRules(value)
    local out = {}
    for index = 1, math.min(#(type(value) == "table" and value or {}), MAX_RULES) do
        out[#out + 1] = NormalizeRule(value[index])
    end
    if #out == 0 then out[1] = DefaultRule() end
    return out
end

local function NormalizeTracked(value)
    local out, seen = {}, {}
    for _, row in ipairs(type(value) == "table" and value or {}) do
        local id = math.floor(tonumber(type(row) == "table" and row.id) or 0)
        if id > 0 and seen[id] ~= true and #out < MAX_RULES then
            seen[id] = true
            out[#out + 1] = {
                id = id,
                name = tostring(row.name or ("Buff " .. tostring(id))),
                iconPath = tostring(row.iconPath or row.icon or row.path or ""),
                enabled = row.enabled ~= false,
                color = CopyColor(row.color, { r = 0.72, g = 0.30, b = 1.00, a = 0.84 }),
            }
        end
    end
    return out
end

local function NormalizeRoleOverrides(value)
    local out, count = {}, 0
    for name, role in pairs(type(value) == "table" and value or {}) do
        if count >= MAX_ROLE_OVERRIDES then break end
        local key = tostring(name or "")
        if key ~= "" then
            out[key] = ClampInt(role, 1, 5, 1)
            count = count + 1
        end
    end
    return out
end

local function NormalizeSettings(value, legacyImport)
    local defaults = DefaultSettings()
    value = type(value) == "table" and value or {}
    local enterThreshold = Clamp(value.enterThreshold, 1, 100, defaults.enterThreshold)
    local exitThreshold = Clamp(value.exitThreshold, enterThreshold, 100, defaults.exitThreshold)
    local emergencyThreshold = Clamp(value.emergencyThreshold, 1, 100, defaults.emergencyThreshold)
    local lowHealthThreshold = Clamp(value.lowHealthThreshold, emergencyThreshold, 100, defaults.lowHealthThreshold)
    local level = type(value.levelThresholds) == "table" and value.levelThresholds or {}
    local attention = Clamp(level.attention, 1, 98, defaults.levelThresholds.attention)
    local high = Clamp(level.high, attention + 1, 99, defaults.levelThresholds.high)
    local emergency = Clamp(level.emergency, high + 1, 100, defaults.levelThresholds.emergency)
    local roleScores = type(value.roleScores) == "table" and value.roleScores or {}
    -- Legacy SettingsModel treated an absent trackedBuffs field as an empty list.
    -- Do not use Lua's `and/or` idiom here: nil would incorrectly fall through
    -- to V3 defaults and silently create tracking the user never configured.
    local trackedSource = value.trackedBuffs
    if legacyImport ~= true and trackedSource == nil then trackedSource = defaults.trackedBuffs end

    return {
        maxDistance = Clamp(value.maxDistance or value.proximityDistance, 1, 100, defaults.maxDistance),
        enterThreshold = enterThreshold,
        exitThreshold = exitThreshold,
        selfThreshold = Clamp(value.selfThreshold, 1, 100, defaults.selfThreshold),
        emergencyThreshold = emergencyThreshold,
        lowHealthThreshold = lowHealthThreshold,
        minHoldMs = ClampInt(value.minHoldMs, 0, 5000, defaults.minHoldMs),
        scoreLead = Clamp(value.scoreLead, 0, 50, defaults.scoreLead),
        healthScanMs = ClampInt(value.healthScanMs, 100, 1000, defaults.healthScanMs),
        buffScanMs = ClampInt(value.buffScanMs, 200, 2000, defaults.buffScanMs),
        weights = NormalizeWeights(value.weights),
        healthCurveMode = ClampInt(value.healthCurveMode, 1, 2, defaults.healthCurveMode),
        healthAccelMode = ClampInt(value.healthAccelMode, 1, 3, defaults.healthAccelMode),
        distanceCurveMode = ClampInt(value.distanceCurveMode, 1, 2, defaults.distanceCurveMode),
        distanceEdgePercent = Clamp(value.distanceEdgePercent, 5, 80, defaults.distanceEdgePercent),
        missingSensitivity = Clamp(value.missingSensitivity, 5000, 200000, defaults.missingSensitivity),
        levelThresholds = { attention = attention, high = high, emergency = emergency },
        roleScoringEnabled = value.roleScoringEnabled == true,
        roleScores = {
            normal = tonumber(roleScores.normal) or defaults.roleScores.normal,
            mainTank = tonumber(roleScores.mainTank) or defaults.roleScores.mainTank,
            offTank = tonumber(roleScores.offTank) or defaults.roleScores.offTank,
            healer = tonumber(roleScores.healer) or defaults.roleScores.healer,
            unknown = tonumber(roleScores.unknown) or defaults.roleScores.unknown,
        },
        roleOverrides = NormalizeRoleOverrides(value.roleOverrides),
        rules = NormalizeRules(value.rules),
        trackedBuffs = NormalizeTracked(trackedSource),
        proximityColor = CopyColor(value.proximityColor, defaults.proximityColor),
        lowHealthColor = CopyColor(value.lowHealthColor, defaults.lowHealthColor),
        emergencyColor = CopyColor(value.emergencyColor, defaults.emergencyColor),
    }
end

local function NormalizeState(value)
    value = type(value) == "table" and value or {}
    return {
        settings = NormalizeSettings(value.settings or value),
        -- FloatingSurface owns the nested geometry/appearance schema. Keep it
        -- opaque here so future shell migrations do not couple Healer Domain
        -- normalization to Presentation internals.
        widgetWindow = type(value.widgetWindow) == "table" and DeepCopy(value.widgetWindow) or {},
        presentation = NormalizePresentation(value.presentation),
        migration = {
            legacyImported = type(value.migration) == "table" and value.migration.legacyImported == true or false,
            visualImported = type(value.migration) == "table" and value.migration.visualImported == true or false,
            source = type(value.migration) == "table" and tostring(value.migration.source or "none") or "none",
            legacyVersion = type(value.migration) == "table" and math.max(0, math.floor(tonumber(value.migration.legacyVersion) or 0)) or 0,
            futureLegacy = type(value.migration) == "table" and value.migration.futureLegacy == true or false,
        },
    }
end

F.StoreId = STORE_ID
F.State = NormalizeState(F.State)
F.StoreLoaded = F.StoreLoaded == true

local function ApplyState(value) F.State = NormalizeState(value) end

if P:GetStore(STORE_ID) == nil then
    local store, err = P:RegisterV3Store({
        id = STORE_ID,
        owner = "v3.healer",
        scope = P.Scope and P.Scope.Account or "account",
        lifetime = P.Lifetime and P.Lifetime.Permanent or "permanent",
        schemaVersion = SCHEMA,
        legacySchemaVersion = 0,
        key = P.V3KeyPrefix and (P.V3KeyPrefix .. "healer") or "v3.healer",
        budget = { maxDepth = 7, maxNodes = 2400, maxStringBytes = 16000, maxEntriesPerTable = 256 },
        default = function() return NormalizeState(nil) end,
        get = function() return NormalizeState(F.State) end,
        apply = ApplyState,
        migrate = function(value) return NormalizeState(value) end,
    })
    if store == nil and S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Error) == "function" then
        S.DiagnosticsManager:Error("healer_v3", "HEALER_STORE_REGISTER_FAILED", "治疗辅助设置存档注册失败", { error = tostring(err) })
    end
end

local function ReadLegacyCandidate(key)
    if type(P.ReadLegacy) ~= "function" then return nil, "legacy read unavailable" end
    local raw, err = P:ReadLegacy(key)
    if err ~= nil then return nil, err end
    if type(raw) ~= "table" then return nil, nil end
    if type(raw.payload) == "table" then raw = raw.payload end
    return raw, nil
end

function F:ImportLegacySettingsIfPresent()
    local raw, err = ReadLegacyCandidate(LEGACY_KEY)
    local source = "primary"
    if type(raw) ~= "table" then
        raw, err = ReadLegacyCandidate(LEGACY_BACKUP_KEY)
        source = "backup"
    end
    if type(raw) ~= "table" then return true, false, err end

    local version = math.max(0, math.floor(tonumber(raw.settingsVersion) or 0))
    self.State = NormalizeState({
        settings = NormalizeSettings(raw, true),
        presentation = LegacyPresentation(raw),
        migration = {
            legacyImported = true,
            visualImported = true,
            source = source,
            legacyVersion = version,
            futureLegacy = version > LEGACY_SCHEMA,
        },
    })
    local saved, saveErr = P:SaveStore(STORE_ID, { consumeDirty = true, reason = "healer_legacy_import" })
    if saved ~= true then return false, false, saveErr or "legacy import persistence failed" end
    return true, true, nil
end

function F:EnsureStoreLoaded()
    if self.StoreLoaded == true then return true end
    local store = P:GetStore(STORE_ID)
    if store == nil then return false, "治疗辅助设置存档不可用" end
    local status, _, err = P:LoadStore(STORE_ID)
    if status ~= true and status ~= "empty" then return false, err or tostring(status or "读取失败") end
    if status == "empty" then
        ApplyState(nil)
        local imported, _, importErr = self:ImportLegacySettingsIfPresent()
        if imported ~= true then return false, importErr or "旧治疗配置迁移失败" end
    elseif self.State.migration.legacyImported == true and self.State.migration.visualImported ~= true then
        -- Schema 2 imported treatment policy before visual state had a V3 home.
        -- Re-read the immutable legacy source once so custom marker/raid layout
        -- is recovered instead of silently resetting to V3 defaults.
        local raw = nil
        local source = tostring(self.State.migration.source or "primary")
        if source == "backup" then raw = select(1, ReadLegacyCandidate(LEGACY_BACKUP_KEY))
        else raw = select(1, ReadLegacyCandidate(LEGACY_KEY)) end
        if type(raw) ~= "table" then
            raw = select(1, ReadLegacyCandidate(source == "backup" and LEGACY_KEY or LEGACY_BACKUP_KEY))
        end
        if type(raw) == "table" then self.State.presentation = LegacyPresentation(raw) end
        self.State.migration.visualImported = true
        local saved, saveErr = P:SaveStore(STORE_ID, { consumeDirty = true, reason = "healer_visual_schema3_recovery" })
        if saved ~= true then return false, saveErr or "治疗显示配置升级失败" end
    end
    self.StoreLoaded = true
    return true
end

function F:GetSettings() return self.State.settings end
function F:GetMigrationInfo() return DeepCopy(self.State.migration) end
-- Presentation-owned window geometry is a detached read model. Mutations return
-- through the Feature Commands facade and the shared FloatingSurface persistence
-- callback; Widget code never receives the live Store table.
function F:GetWidgetWindowState()
    local floating = S.RSUI and S.RSUI.FloatingSurface or nil
    local policy = { defaultWidth = 430, defaultHeight = 300, minWidth = 280, minHeight = 150,
        defaultOverallOpacity = 0.96, defaultBackgroundOpacity = 1.0, defaultTextOpacity = 1.0 }
    if type(floating) == "table" and type(floating.NormalizeState) == "function" then
        return DeepCopy(floating:NormalizeState(self.State and self.State.widgetWindow, policy))
    end
    return DeepCopy(self.State and self.State.widgetWindow)
end
function F:SetWidgetWindowState(value, reason)
    if type(value) ~= "table" or type(self.State) ~= "table" then return false, "healer widget window state unavailable" end
    local floating = S.RSUI and S.RSUI.FloatingSurface or nil
    local policy = { defaultWidth = 430, defaultHeight = 300, minWidth = 280, minHeight = 150,
        defaultOverallOpacity = 0.96, defaultBackgroundOpacity = 1.0, defaultTextOpacity = 1.0 }
    self.State.widgetWindow = type(floating) == "table" and type(floating.NormalizeState) == "function"
        and floating:NormalizeState(value, policy) or DeepCopy(value)
    return true
end
function F:MarkStoreDirty(delayMs, reason)
    return P:MarkDirty(STORE_ID, tonumber(delayMs) or 350, reason or "healer_setting_changed")
end

local HEALER_SCALAR_SETTINGS = {
    maxDistance=true, enterThreshold=true, exitThreshold=true, selfThreshold=true,
    emergencyThreshold=true, lowHealthThreshold=true, minHoldMs=true, scoreLead=true,
    healthScanMs=true, buffScanMs=true, healthCurveMode=true, healthAccelMode=true,
    distanceCurveMode=true, distanceEdgePercent=true, missingSensitivity=true,
    roleScoringEnabled=true,
}

local function PublishSettingChanged(key)
    if S.Events ~= nil and type(S.Events.Publish) == "function" then
        S.Events:Publish("v3.healer.settings", tostring(key or ""))
    end
end

-- Raw in-memory mutation for RSUI PersistentSettingBinding. The binding owns
-- the write-fence + MarkDirty transaction, so this path must not queue a second
-- Store write. Normalization still runs across the complete policy to preserve
-- threshold invariants such as exit >= enter and low >= emergency.
function F:ApplyScalarSettingRaw(key, value)
    key = tostring(key or "")
    if HEALER_SCALAR_SETTINGS[key] ~= true then return false, "unsupported healer scalar setting: " .. key end
    local nextSettings = DeepCopy(self.State.settings)
    nextSettings[key] = value
    self.State.settings = NormalizeSettings(nextSettings)
    return true
end

function F:ApplySettingFromBinding(key, value)
    local ok, err = self:ApplyScalarSettingRaw(key, value)
    if ok ~= true then return false, err end
    PublishSettingChanged(key)
    return true
end

-- Command/non-RSUI callers own persistence here. Restore the full normalized
-- settings snapshot if MarkDirty is fenced so the live Domain cannot diverge
-- from the authoritative permanent Store.
function F:SetScalarSetting(key, value)
    key = tostring(key or "")
    local before = DeepCopy(self.State.settings)
    local ok, err = self:ApplyScalarSettingRaw(key, value)
    if ok ~= true then return false, err end
    local marked, markErr = self:MarkStoreDirty(350, "healer_scalar:" .. key)
    if marked ~= true then self.State.settings = before; return false, markErr end
    PublishSettingChanged(key)
    return true
end

local HEALER_RULE_KEYS = {
    name=true, enabled=true, purpose=true, sourceMode=true, matchMode=true, ids=true,
    minStacks=true, minRemainingMs=true, unknownRemainingValid=true, healthRangeEnabled=true,
    healthMin=true, healthMax=true, effectType=true, scoreMode=true, scoreValue=true,
    allowStack=true, emergencyRetainPercent=true, countsAsProtection=true, displayPriority=true,
    rescuePriority=true, color=true, distanceMode=true, customDistance=true,
    healPriorityThreshold=true, excludeDisplayMode=true, simpleDisplayGroup=true,
}

local HEALER_TRACKED_KEYS = { id=true, name=true, iconPath=true, enabled=true, color=true }
local HEALER_COLOR_KEYS = { proximityColor=true, lowHealthColor=true, emergencyColor=true }

local function MutateSettings(self, reason, mutator, topic)
    if type(mutator) ~= "function" then return false, "healer settings mutation required" end
    local before = DeepCopy(self.State.settings)
    local nextSettings = DeepCopy(self.State.settings)
    local ok, err = pcall(mutator, nextSettings)
    if ok ~= true then return false, tostring(err) end
    self.State.settings = NormalizeSettings(nextSettings)
    local marked, markErr = self:MarkStoreDirty(350, reason or "healer_settings_command")
    if marked ~= true then
        self.State.settings = before
        return false, markErr or "治疗设置存档写入排队失败"
    end
    PublishSettingChanged(topic or "advanced")
    return true
end

function F:GetRules() return DeepCopy(self.State.settings.rules or {}) end
function F:GetTrackedBuffs() return DeepCopy(self.State.settings.trackedBuffs or {}) end

function F:SetRule(index, key, value)
    index, key = ClampInt(index, 1, MAX_RULES, 1), tostring(key or "")
    if HEALER_RULE_KEYS[key] ~= true then return false, "unsupported healer rule setting: " .. key end
    return MutateSettings(self, "healer_rule:" .. tostring(index) .. ":" .. key, function(settings)
        local rule = settings.rules and settings.rules[index]
        if type(rule) ~= "table" then error("治疗规则不存在") end
        rule[key] = value
    end, "rules")
end

function F:AddRule(template)
    if #(self.State.settings.rules or {}) >= MAX_RULES then return false, "治疗规则已达到上限" end
    return MutateSettings(self, "healer_rule:add", function(settings)
        settings.rules = type(settings.rules) == "table" and settings.rules or {}
        settings.rules[#settings.rules + 1] = type(template) == "table" and DeepCopy(template) or DefaultRule()
    end, "rules")
end

function F:RemoveRule(index)
    index = ClampInt(index, 1, MAX_RULES, 1)
    if #(self.State.settings.rules or {}) <= 1 then return false, "至少保留一条治疗规则" end
    return MutateSettings(self, "healer_rule:remove:" .. tostring(index), function(settings)
        if type(settings.rules) ~= "table" or settings.rules[index] == nil then error("治疗规则不存在") end
        table.remove(settings.rules, index)
    end, "rules")
end

function F:SetTrackedBuff(index, key, value)
    index, key = ClampInt(index, 1, MAX_RULES, 1), tostring(key or "")
    if HEALER_TRACKED_KEYS[key] ~= true then return false, "unsupported tracked buff setting: " .. key end
    return MutateSettings(self, "healer_tracked:" .. tostring(index) .. ":" .. key, function(settings)
        local row = settings.trackedBuffs and settings.trackedBuffs[index]
        if type(row) ~= "table" then error("Tracked Buff 不存在") end
        row[key] = value
    end, "tracked")
end

function F:AddTrackedBuff(id, name, iconPath)
    id = math.floor(tonumber(id) or 0)
    if id <= 0 then return false, "Tracked Buff ID 必须为正整数" end
    return MutateSettings(self, "healer_tracked:add", function(settings)
        settings.trackedBuffs = type(settings.trackedBuffs) == "table" and settings.trackedBuffs or {}
        settings.trackedBuffs[#settings.trackedBuffs + 1] = {
            id = id, name = tostring(name or ("Buff " .. tostring(id))), iconPath = tostring(iconPath or ""),
            enabled = true, color = { r = 0.72, g = 0.30, b = 1.00, a = 0.84 },
        }
    end, "tracked")
end

function F:RemoveTrackedBuff(index)
    index = ClampInt(index, 1, MAX_RULES, 1)
    return MutateSettings(self, "healer_tracked:remove:" .. tostring(index), function(settings)
        if type(settings.trackedBuffs) ~= "table" or settings.trackedBuffs[index] == nil then error("Tracked Buff 不存在") end
        table.remove(settings.trackedBuffs, index)
    end, "tracked")
end

function F:SetHealerColor(key, color)
    key = tostring(key or "")
    if HEALER_COLOR_KEYS[key] ~= true then return false, "unsupported healer color: " .. key end
    return MutateSettings(self, "healer_color:" .. key, function(settings)
        settings[key] = type(color) == "table" and DeepCopy(color) or {}
    end, "colors")
end


function F:GetPresentationSettings(scope)
    local presentation = self.State.presentation or NormalizePresentation(nil)
    if scope == nil then return DeepCopy(presentation) end
    local value = presentation[tostring(scope or "")]
    return type(value) == "table" and DeepCopy(value) or nil
end

local HEAD_PRESENTATION_KEYS = {
    enabled=true, count=true, effectMode=true, shapeMode=true,
    showName=true, showDistance=true, showScore=true, refreshMs=true,
}
local RAID_PRESENTATION_KEYS = {
    enabled=true, effectMode=true, showRanks=true, rankCount=true,
    rankFontSize=true, rankAlpha=true, rankCorner=true, rankOffsetX=true,
    rankOffsetY=true, proximityMode=true, calibration=true,
    calibrationSection=true, calibrationScope=true,
}

local function PublishPresentationChanged(scope, key)
    if S.Events ~= nil and type(S.Events.Publish) == "function" then
        S.Events:Publish("v3.healer.presentation", tostring(scope or ""), tostring(key or ""))
    end
end

function F:ApplyPresentationSettingRaw(scope, key, value)
    scope, key = tostring(scope or ""), tostring(key or "")
    local supported = scope == "head" and HEAD_PRESENTATION_KEYS or (scope == "raid" and RAID_PRESENTATION_KEYS or nil)
    if type(supported) ~= "table" or supported[key] ~= true then
        return false, "unsupported healer presentation setting: " .. scope .. "." .. key
    end
    local nextPresentation = DeepCopy(self.State.presentation)
    nextPresentation[scope][key] = value
    self.State.presentation = NormalizePresentation(nextPresentation)
    return true
end

function F:ApplyPresentationSettingFromBinding(scope, key, value)
    local ok, err = self:ApplyPresentationSettingRaw(scope, key, value)
    if ok ~= true then return false, err end
    PublishPresentationChanged(scope, key)
    return true
end

function F:SetPresentationSetting(scope, key, value)
    local before = DeepCopy(self.State.presentation)
    local ok, err = self:ApplyPresentationSettingRaw(scope, key, value)
    if ok ~= true then return false, err end
    local marked, markErr = self:MarkStoreDirty(350, "healer_presentation:" .. tostring(scope) .. ":" .. tostring(key))
    if marked ~= true then self.State.presentation = before; return false, markErr end
    PublishPresentationChanged(scope, key)
    return true
end

function F:SetRaidSectionRect(index, rect)
    index = ClampInt(index, 1, 4, 1)
    local before = DeepCopy(self.State.presentation)
    local nextPresentation = DeepCopy(self.State.presentation)
    nextPresentation.raid.sections[index] = NormalizeRect(rect, nextPresentation.raid.sections[index])
    self.State.presentation = NormalizePresentation(nextPresentation)
    local marked, err = self:MarkStoreDirty(200, "healer_raid_rect:" .. tostring(index))
    if marked ~= true then self.State.presentation = before; return false, err end
    PublishPresentationChanged("raid", "sections")
    return true
end

function F:ResetRaidLayout()
    local before = DeepCopy(self.State.presentation)
    self.State.presentation.raid.sections = DefaultRaidSections()
    self.State.presentation = NormalizePresentation(self.State.presentation)
    local marked, err = self:MarkStoreDirty(200, "healer_raid_layout_reset")
    if marked ~= true then self.State.presentation = before; return false, err end
    PublishPresentationChanged("raid", "sections")
    return true
end

function F:GetStoreHealth()
    local store = P:GetStore(STORE_ID)
    return {
        loaded = self.StoreLoaded == true,
        writeFenced = type(store) == "table" and store.writeFenced == true or false,
        dirty = type(store) == "table" and store.dirty == true or false,
        migration = self:GetMigrationInfo(),
    }
end

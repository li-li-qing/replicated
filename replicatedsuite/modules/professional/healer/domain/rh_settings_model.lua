ReplicatedSuiteModuleSandbox:Enter('healer', {'ReplicatedHealerBoot', 'ReplicatedHealerConfig', 'ReplicatedHealerModule'})
------------------------------------------------------------------------
-- Replicated Healer - Settings Model v1
--
-- Pure settings-domain Authority.  This module owns defaults, normalization,
-- validation helpers and rule factories.  It deliberately performs no Native
-- UI calls and no SaveData I/O; historical version migration is handled by
-- persistence/rh_settings_migrations.lua.
------------------------------------------------------------------------

ReplicatedHealerSettingsModel = ReplicatedHealerSettingsModel or {}
local M = ReplicatedHealerSettingsModel
M.Version = "1.0"
M.MaxRules = 20
M.metrics = M.metrics or {
    normalizeState = 0,
    normalizeRule = 0,
    normalizeTracked = 0,
    normalizeWeights = 0,
    settingCoercions = 0,
    settingRejects = 0,
}

-- Suite-facing schema is defined here once so Presenter and boot normalization
-- cannot drift apart. Integer enums use the actual Domain label ranges.
M.SuiteSettingSpecs = {
    maxDistance={kind="number",min=1,max=100}, enterThreshold={kind="number",min=1,max=100},
    exitThreshold={kind="number",min=1,max=100}, selfThreshold={kind="number",min=1,max=100},
    emergencyThreshold={kind="number",min=1,max=100}, lowHealthThreshold={kind="number",min=1,max=100},
    proximityMode={kind="boolean"}, proximityDistance={kind="number",min=1,max=100},
    headMarkerCount={kind="number",min=1,max=50,integer=true},
    showHeadName={kind="boolean"}, showHeadDistance={kind="boolean"}, showHeadScore={kind="boolean"},
    showRaidRanks={kind="boolean"}, raidRankCount={kind="number",min=0,max=50,integer=true},
    raidRankFontSize={kind="number",min=8,max=20,integer=true}, raidRankAlpha={kind="number",min=0.10,max=1.00},
    raidRankCorner={kind="number",min=1,max=4,integer=true}, raidRankOffsetX={kind="number",min=-50,max=50},
    raidRankOffsetY={kind="number",min=-50,max=50}, healthScanMs={kind="number",min=50,max=1000,integer=true},
    buffScanMs={kind="number",min=100,max=2000,integer=true}, minHoldMs={kind="number",min=0,max=5000,integer=true},
    scoreLead={kind="number",min=0,max=50}, healthCurveMode={kind="number",min=1,max=2,integer=true},
    healthAccelMode={kind="number",min=1,max=3,integer=true}, distanceCurveMode={kind="number",min=1,max=2,integer=true},
    distanceEdgePercent={kind="number",min=5,max=80}, missingSensitivity={kind="number",min=5000,max=200000},
    raidEffectMode={kind="number",min=1,max=3,integer=true}, headEffectMode={kind="number",min=1,max=3,integer=true},
    headShapeMode={kind="number",min=1,max=4,integer=true}, roleScoringEnabled={kind="boolean"},
    raidCalibrationSection={kind="number",min=1,max=4,integer=true}, raidCalibrationScope={kind="number",min=1,max=3,integer=true},
    manualRaidPage={kind="number",min=1,max=2,integer=true}, manualRaidPageLocked={kind="boolean"},
}
M.SuiteColorKeys = { proximityColor=true, lowHealthColor=true, emergencyColor=true }
M.SuiteWeightKeys = { health=true, distance=true, missing=true, unprotected=true }
M.SuiteLevelKeys = { attention=true, high=true, emergency=true }
M.SuiteRoleScoreKeys = { normal=true, mainTank=true, offTank=true, healer=true, unknown=true }
M.SuiteRuleSpecs = {
    purpose={kind="number",min=1,max=5,integer=true}, sourceMode={kind="number",min=1,max=5,integer=true},
    matchMode={kind="number",min=1,max=2,integer=true}, minStacks={kind="number",min=1,max=99,integer=true},
    minRemainingMs={kind="number",min=0,max=120000,integer=true}, unknownRemainingValid={kind="boolean"},
    healthRangeEnabled={kind="boolean"}, healthMin={kind="number",min=0,max=100}, healthMax={kind="number",min=0,max=100},
    effectType={kind="number",min=1,max=4,integer=true}, scoreMode={kind="number",min=1,max=2,integer=true},
    scoreValue={kind="number",min=0,max=500}, allowStack={kind="boolean"},
    emergencyRetainPercent={kind="number",min=0,max=100}, countsAsProtection={kind="boolean"},
    displayPriority={kind="number",min=0,max=999,integer=true}, rescuePriority={kind="number",min=0,max=999,integer=true},
    distanceMode={kind="number",min=1,max=2,integer=true}, customDistance={kind="number",min=1,max=100},
    healPriorityThreshold={kind="number",min=0,max=100}, excludeDisplayMode={kind="number",min=1,max=2,integer=true},
}

local Suite = rawget(_G, "ReplicatedSuite") or ReplicatedSuite
local Reuse = Suite and Suite.Reuse or rawget(_G, "ReplicatedSuiteShared")
local Clamp = Reuse and Reuse.Value and Reuse.Value.Clamp or function(value, minValue, maxValue)
    value = tonumber(value) or minValue
    if value < minValue then return minValue end
    if value > maxValue then return maxValue end
    return value
end
local DeepCopy = Reuse and Reuse.Table and Reuse.Table.DeepCopy or function(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = M.DeepCopyFallback(item) end
    return result
end
if M.DeepCopyFallback == nil then
    function M.DeepCopyFallback(value)
        if type(value) ~= "table" then return value end
        local result = {}
        for key, item in pairs(value) do result[key] = M.DeepCopyFallback(item) end
        return result
    end
end
if Reuse == nil or Reuse.Table == nil or type(Reuse.Table.DeepCopy) ~= "function" then
    DeepCopy = M.DeepCopyFallback
end

local function Round(value, decimals)
    local multiplier = 10 ^ (decimals or 0)
    return math.floor(((tonumber(value) or 0) * multiplier) + 0.5) / multiplier
end


function M:DeepCopy(value)
    return DeepCopy(value)
end

function M:CopyColor(color, fallback)
    local source = type(color) == "table" and color or fallback or {}
    return {
        r = Clamp(source.r or 1, 0, 1),
        g = Clamp(source.g or 1, 0, 1),
        b = Clamp(source.b or 1, 0, 1),
        a = Clamp(source.a or 1, 0, 1),
    }
end

function M:CopyAnchor(source, fallback, includeSize)
    local sourceTable = type(source) == "table" and source or {}
    local fallbackTable = type(fallback) == "table" and fallback or {}
    local result = {
        horizontal = sourceTable.horizontal == "RIGHT" and "RIGHT" or (fallbackTable.horizontal or "LEFT"),
        vertical = sourceTable.vertical == "BOTTOM" and "BOTTOM" or (fallbackTable.vertical or "TOP"),
        offsetX = tonumber(sourceTable.offsetX) or tonumber(fallbackTable.offsetX) or 0,
        offsetY = tonumber(sourceTable.offsetY) or tonumber(fallbackTable.offsetY) or 0,
    }
    if includeSize then
        result.width = tonumber(sourceTable.width) or tonumber(fallbackTable.width) or 100
        result.height = tonumber(sourceTable.height) or tonumber(fallbackTable.height) or 100
    end
    return result
end

function M:ParseIdList(text)
    local result, seen = {}, {}
    for token in string.gmatch(tostring(text or ""), "%d+") do
        local id = tonumber(token)
        if id ~= nil and id > 0 and not seen[id] then
            seen[id] = true
            result[#result + 1] = id
        end
    end
    return result
end

function M:JoinIdList(ids)
    local parts = {}
    for index = 1, #(ids or {}) do parts[#parts + 1] = tostring(ids[index]) end
    return table.concat(parts, ", ")
end

function M:NewDefaultHealingRule()
    return {
        name = "持续回血",
        enabled = true,
        purpose = 1,
        sourceMode = 1,
        matchMode = 1,
        ids = { 25875, 220 },
        minStacks = 1,
        minRemainingMs = 0,
        unknownRemainingValid = true,
        healthRangeEnabled = false,
        healthMin = 0,
        healthMax = 100,
        effectType = 1,
        scoreMode = 2,
        scoreValue = 25,
        allowStack = false,
        emergencyRetainPercent = 20,
        countsAsProtection = true,
        displayPriority = 10,
        rescuePriority = 50,
        color = { r = 0.72, g = 0.30, b = 1.00, a = 0.82 },
        distanceMode = 1,
        customDistance = 27,
        healPriorityThreshold = 70,
        excludeDisplayMode = 1,
    }
end

function M:NewRuleByPurpose(purpose)
    local rule = self:NewDefaultHealingRule()
    rule.name = "新规则"
    rule.ids = {}
    rule.purpose = tonumber(purpose) or 5
    if rule.purpose == 2 then
        rule.name = "危险状态"
        rule.sourceMode = 2
        rule.effectType = 2
        rule.scoreMode = 1
        rule.scoreValue = 15
        rule.countsAsProtection = false
        rule.displayPriority = 70
        rule.color = { r = 1.00, g = 0.25, b = 0.12, a = 0.82 }
    elseif rule.purpose == 3 then
        rule.name = "控制/解控"
        rule.sourceMode = 2
        rule.effectType = 4
        rule.scoreMode = 1
        rule.scoreValue = 20
        rule.countsAsProtection = false
        rule.displayPriority = 100
        rule.rescuePriority = 100
        rule.distanceMode = 2
        rule.customDistance = 20
        rule.healPriorityThreshold = 70
        rule.color = { r = 0.72, g = 0.28, b = 1.00, a = 0.84 }
    elseif rule.purpose == 4 then
        rule.name = "不可救援"
        rule.sourceMode = 2
        rule.effectType = 3
        rule.scoreMode = 1
        rule.scoreValue = 0
        rule.countsAsProtection = false
        rule.displayPriority = 120
        rule.excludeDisplayMode = 2
        rule.color = { r = 0.55, g = 0.58, b = 0.62, a = 0.72 }
    elseif rule.purpose == 5 then
        rule.name = "通用自定义"
        rule.sourceMode = 5
        rule.effectType = 2
        rule.scoreMode = 1
        rule.scoreValue = 10
        rule.countsAsProtection = false
        rule.displayPriority = 60
        rule.color = { r = 0.20, g = 0.85, b = 1.00, a = 0.78 }
    end
    return rule
end

function M:BuildDefaults(config)
    config = type(config) == "table" and config or ReplicatedHealerConfig or {}
    local defaults = DeepCopy(type(config.Defaults) == "table" and config.Defaults or {})
    if type(defaults.rules) ~= "table" or #defaults.rules == 0 then
        defaults.rules = { self:NewDefaultHealingRule() }
    end
    defaults.settingsVersion = tonumber(config.SettingsVersion) or tonumber(defaults.settingsVersion) or 1
    return defaults
end

function M:NormalizeWeights(target, defaults)
    self.metrics.normalizeWeights = (tonumber(self.metrics.normalizeWeights) or 0) + 1
    target.weights = type(target.weights) == "table" and target.weights or DeepCopy(defaults.weights or {})
    local weights = target.weights
    weights.health = tonumber(weights.health) or tonumber(defaults.weights and defaults.weights.health) or 55
    weights.distance = tonumber(weights.distance) or tonumber(defaults.weights and defaults.weights.distance) or 15
    weights.missing = tonumber(weights.missing) or tonumber(defaults.weights and defaults.weights.missing) or 10
    weights.unprotected = tonumber(weights.unprotected) or tonumber(defaults.weights and defaults.weights.unprotected) or 20
    local total = math.max(0, weights.health) + math.max(0, weights.distance) + math.max(0, weights.missing) + math.max(0, weights.unprotected)
    if total <= 0 then
        weights.health, weights.distance, weights.missing, weights.unprotected = 55, 15, 10, 20
        return weights
    end
    weights.health = Round(math.max(0, weights.health) * 100 / total, 1)
    weights.distance = Round(math.max(0, weights.distance) * 100 / total, 1)
    weights.missing = Round(math.max(0, weights.missing) * 100 / total, 1)
    weights.unprotected = Round(100 - weights.health - weights.distance - weights.missing, 1)
    if weights.unprotected < 0 then
        weights.unprotected = 0
        local subtotal = weights.health + weights.distance + weights.missing
        if subtotal > 0 then
            weights.health = Round(weights.health * 100 / subtotal, 1)
            weights.distance = Round(weights.distance * 100 / subtotal, 1)
            weights.missing = Round(100 - weights.health - weights.distance, 1)
        end
    end
    return weights
end

function M:NormalizeTrackedBuff(entry, fallbackColor)
    self.metrics.normalizeTracked = (tonumber(self.metrics.normalizeTracked) or 0) + 1
    entry = type(entry) == "table" and entry or {}
    entry.id = math.floor(math.max(0, tonumber(entry.id) or 0))
    entry.name = tostring(entry.name or (entry.id > 0 and ("Buff " .. tostring(entry.id)) or "未命名 Buff"))
    entry.iconPath = tostring(entry.iconPath or entry.icon or entry.path or "")
    entry.enabled = entry.enabled ~= false
    entry.color = self:CopyColor(entry.color, fallbackColor or { r = 0.72, g = 0.30, b = 1.00, a = 0.84 })
    return entry
end

function M:NormalizeTrackedBuffList(list)
    local normalized, seen = {}, {}
    if type(list) == "table" then
        for _, entry in ipairs(list) do
            entry = self:NormalizeTrackedBuff(entry)
            if entry.id > 0 and not seen[entry.id] and #normalized < self.MaxRules then
                seen[entry.id] = true
                normalized[#normalized + 1] = entry
            end
        end
    end
    return normalized
end

function M:NormalizeRule(rule)
    self.metrics.normalizeRule = (tonumber(self.metrics.normalizeRule) or 0) + 1
    rule = type(rule) == "table" and rule or self:NewDefaultHealingRule()
    rule.name = tostring(rule.name or "未命名规则")
    rule.enabled = rule.enabled ~= false
    rule.purpose = math.floor(Clamp(rule.purpose or 5, 1, 5))
    rule.sourceMode = math.floor(Clamp(rule.sourceMode or 5, 1, 5))
    rule.matchMode = math.floor(Clamp(rule.matchMode or 1, 1, 2))
    rule.ids = self:ParseIdList(self:JoinIdList(rule.ids or {}))
    rule.minStacks = math.floor(Clamp(rule.minStacks or 1, 1, 99))
    rule.minRemainingMs = math.floor(Clamp(rule.minRemainingMs or 0, 0, 3600000))
    rule.unknownRemainingValid = rule.unknownRemainingValid ~= false
    rule.healthRangeEnabled = rule.healthRangeEnabled == true
    rule.healthMin = Clamp(rule.healthMin or 0, 0, 100)
    rule.healthMax = Clamp(rule.healthMax or 100, rule.healthMin, 100)
    rule.effectType = math.floor(Clamp(rule.effectType or 2, 1, 4))
    rule.scoreMode = math.floor(Clamp(rule.scoreMode or 1, 1, 2))
    rule.scoreValue = Clamp(rule.scoreValue or 0, 0, 500)
    rule.allowStack = rule.allowStack == true
    rule.emergencyRetainPercent = Clamp(rule.emergencyRetainPercent or 20, 0, 100)
    rule.countsAsProtection = rule.countsAsProtection == true
    rule.displayPriority = math.floor(Clamp(rule.displayPriority or 50, 0, 999))
    rule.rescuePriority = math.floor(Clamp(rule.rescuePriority or 50, 0, 999))
    rule.color = self:CopyColor(rule.color, { r = 1, g = 0.5, b = 0.1, a = 0.8 })
    rule.distanceMode = math.floor(Clamp(rule.distanceMode or 1, 1, 2))
    rule.customDistance = Clamp(rule.customDistance or 20, 1, 100)
    rule.healPriorityThreshold = Clamp(rule.healPriorityThreshold or 70, 0, 100)
    rule.excludeDisplayMode = math.floor(Clamp(rule.excludeDisplayMode or 1, 1, 2))
    rule.simpleDisplayGroup = rule.simpleDisplayGroup == true
    return rule
end

function M:NormalizeState(target, defaults, settingsVersion)
    self.metrics.normalizeState = (tonumber(self.metrics.normalizeState) or 0) + 1
    target = type(target) == "table" and target or {}
    defaults = type(defaults) == "table" and defaults or self:BuildDefaults()

    target.settingsVersion = tonumber(settingsVersion) or tonumber(defaults.settingsVersion) or 1
    target.weights = type(target.weights) == "table" and target.weights or DeepCopy(defaults.weights or {})
    target.levelThresholds = type(target.levelThresholds) == "table" and target.levelThresholds or DeepCopy(defaults.levelThresholds or {})
    target.levelColors = type(target.levelColors) == "table" and target.levelColors or DeepCopy(defaults.levelColors or {})
    for index = 1, 4 do target.levelColors[index] = self:CopyColor(target.levelColors[index], defaults.levelColors and defaults.levelColors[index]) end
    target.headSizes = type(target.headSizes) == "table" and target.headSizes or DeepCopy(defaults.headSizes or {18,24,30,36})
    for index = 1, 4 do target.headSizes[index] = math.floor(Clamp(target.headSizes[index] or defaults.headSizes[index], 12, 60)) end

    target.rules = type(target.rules) == "table" and target.rules or { self:NewDefaultHealingRule() }
    while #target.rules > self.MaxRules do table.remove(target.rules) end
    for index = 1, #target.rules do target.rules[index] = self:NormalizeRule(target.rules[index]) end

    target.trackedBuffs = self:NormalizeTrackedBuffList(target.trackedBuffs)
    target.roleScores = type(target.roleScores) == "table" and target.roleScores or DeepCopy(defaults.roleScores or {})
    target.roleScores.normal = tonumber(target.roleScores.normal) or 0
    target.roleScores.mainTank = tonumber(target.roleScores.mainTank) or 15
    target.roleScores.offTank = tonumber(target.roleScores.offTank) or 10
    target.roleScores.healer = tonumber(target.roleScores.healer) or 8
    target.roleScores.unknown = tonumber(target.roleScores.unknown) or 0
    target.roleOverrides = type(target.roleOverrides) == "table" and target.roleOverrides or {}

    target.panelAnchor = self:CopyAnchor(target.panelAnchor, defaults.panelAnchor, false)
    target.recommendWidth = math.floor(Clamp(tonumber(target.recommendWidth) or defaults.recommendWidth or 510, 430, 1000))
    target.recommendHeight = math.floor(Clamp(tonumber(target.recommendHeight) or defaults.recommendHeight or 342, 180, 800))
    target.configAnchor = self:CopyAnchor(target.configAnchor, defaults.configAnchor, false)
    target.launcherAnchor = self:CopyAnchor(target.launcherAnchor, defaults.launcherAnchor, false)
    target.pageSwitcherAnchor = self:CopyAnchor(target.pageSwitcherAnchor, defaults.pageSwitcherAnchor, false)
    target.raidOverlayTop = self:CopyAnchor(target.raidOverlayTop, defaults.raidOverlayTop, true)
    target.raidOverlayBottom = self:CopyAnchor(target.raidOverlayBottom, defaults.raidOverlayBottom, true)
    target.raidOverlayTopRaid2 = self:CopyAnchor(target.raidOverlayTopRaid2, defaults.raidOverlayTopRaid2, true)
    target.raidOverlayBottomRaid2 = self:CopyAnchor(target.raidOverlayBottomRaid2, defaults.raidOverlayBottomRaid2, true)

    target.panelMode = math.floor(Clamp(target.panelMode or 1, 1, 3))
    target.recommendSortMode = math.floor(Clamp(target.recommendSortMode or 1, 1, 2))
    target.raidEffectMode = math.floor(Clamp(target.raidEffectMode or 1, 1, 3))
    target.headEffectMode = math.floor(Clamp(target.headEffectMode or 1, 1, 3))
    target.headShapeMode = math.floor(Clamp(target.headShapeMode or 4, 1, 4))
    target.raidRankCount = math.floor(Clamp(target.raidRankCount or 10, 0, 50))
    target.raidRankFontSize = math.floor(Clamp(target.raidRankFontSize or 10, 8, 20))
    target.raidRankAlpha = Clamp(target.raidRankAlpha or 1, 0.1, 1)
    target.raidRankCorner = math.floor(Clamp(target.raidRankCorner or 2, 1, 4))
    target.raidRankOffsetX = Clamp(target.raidRankOffsetX or 1, -20, 20)
    target.raidRankOffsetY = Clamp(target.raidRankOffsetY or 1, -20, 20)
    target.healthCurveMode = math.floor(Clamp(target.healthCurveMode or 2, 1, 2))
    target.healthAccelMode = math.floor(Clamp(target.healthAccelMode or 2, 1, 3))
    target.distanceCurveMode = math.floor(Clamp(target.distanceCurveMode or 2, 1, 2))
    target.distanceEdgePercent = Clamp(target.distanceEdgePercent or 20, 5, 80)
    target.missingSensitivity = Clamp(target.missingSensitivity or 30000, 5000, 200000)
    target.minHoldMs = math.floor(Clamp(target.minHoldMs or 500, 0, 5000))
    target.scoreLead = Clamp(target.scoreLead or 5, 0, 50)
    target.raidCalibrationSection = math.floor(Clamp(target.raidCalibrationSection or 1, 1, 4))
    target.raidCalibrationScope = math.floor(Clamp(target.raidCalibrationScope or 1, 1, 3))
    target.fullRecommendCount = math.floor(Clamp(target.fullRecommendCount or 10, 1, 100))
    target.miniRecommendCount = math.floor(Clamp(target.miniRecommendCount or 3, 1, 3))
    target.headMarkerCount = math.floor(Clamp(target.headMarkerCount or 5, 1, 50))
    target.healthScanMs = math.floor(Clamp(target.healthScanMs or 100, 50, 1000))
    target.buffScanMs = math.floor(Clamp(target.buffScanMs or 200, 100, 2000))
    target.enterThreshold = Clamp(target.enterThreshold or defaults.enterThreshold or 100, 1, 100)
    target.exitThreshold = Clamp(target.exitThreshold or defaults.exitThreshold or 100, target.enterThreshold, 100)
    target.selfThreshold = Clamp(target.selfThreshold or 70, 1, 100)
    target.emergencyThreshold = Clamp(target.emergencyThreshold or defaults.emergencyThreshold or 50, 1, 100)
    target.lowHealthThreshold = Clamp(target.lowHealthThreshold or defaults.lowHealthThreshold or 70, target.emergencyThreshold, 100)
    target.enabled = target.enabled == true
    target.recommendDetailed = target.recommendDetailed == true
    target.showHeadName = target.showHeadName == true
    target.showHeadDistance = target.showHeadDistance == true
    target.showHeadScore = target.showHeadScore == true
    target.showRaidRanks = target.showRaidRanks ~= false
    target.roleScoringEnabled = target.roleScoringEnabled == true
    target.manualRaidPageLocked = target.manualRaidPageLocked == true
    target.manualRaidPage = math.floor(Clamp(target.manualRaidPage or 1, 1, 2))
    target.proximityMode = target.proximityMode ~= false
    target.proximityDistance = Clamp(tonumber(target.maxDistance) or tonumber(target.proximityDistance) or 27, 1, 100)
    target.maxDistance = target.proximityDistance
    target.proximityColor = self:CopyColor(target.proximityColor, defaults.proximityColor)
    target.lowHealthColor = self:CopyColor(target.lowHealthColor, defaults.lowHealthColor)
    target.emergencyColor = self:CopyColor(target.emergencyColor, defaults.emergencyColor)
    target.levelThresholds.attention = Clamp(target.levelThresholds.attention or 40, 1, 98)
    target.levelThresholds.high = Clamp(target.levelThresholds.high or 60, target.levelThresholds.attention + 1, 99)
    target.levelThresholds.emergency = Clamp(target.levelThresholds.emergency or 80, target.levelThresholds.high + 1, 100)
    self:NormalizeWeights(target, defaults)
    return target
end


local function CoerceBySpec(spec, value)
    if type(spec) ~= "table" then return false, nil, "unsupported setting" end
    if spec.kind == "boolean" then return true, value == true end
    if spec.kind == "number" then
        local number = tonumber(value)
        if number == nil then return false, nil, "numeric setting required" end
        number = Clamp(number, tonumber(spec.min) or number, tonumber(spec.max) or number)
        if spec.integer == true then number = math.floor(number + 0.5) end
        return true, number
    end
    return false, nil, "unsupported setting kind"
end

-- Pure SettingsModel validation/normalization entry used by BindingV2.
-- Unlike CoerceSuiteSetting(), preview reads never mutate model diagnostics;
-- only an actual Domain write is counted as a setting coercion/rejection.
function M:PreviewSuiteSetting(target, key, value)
    key = tostring(key or "")
    local spec = self.SuiteSettingSpecs[key]
    local ok, coerced, err = CoerceBySpec(spec, value)
    if not ok then return false, nil, err end
    if key == "enterThreshold" then
        coerced = Clamp(coerced, 1, tonumber(target and target.exitThreshold) or 100)
    elseif key == "exitThreshold" then
        coerced = Clamp(coerced, tonumber(target and target.enterThreshold) or 1, 100)
    elseif key == "emergencyThreshold" then
        coerced = Clamp(coerced, 1, tonumber(target and target.lowHealthThreshold) or 100)
    elseif key == "lowHealthThreshold" then
        coerced = Clamp(coerced, tonumber(target and target.emergencyThreshold) or 1, 100)
    end
    return true, coerced, nil
end

function M:CoerceSuiteSetting(target, key, value)
    local ok, coerced, err = self:PreviewSuiteSetting(target, key, value)
    if not ok then
        self.metrics.settingRejects = (tonumber(self.metrics.settingRejects) or 0) + 1
        return false, nil, err
    end
    self.metrics.settingCoercions = (tonumber(self.metrics.settingCoercions) or 0) + 1
    return true, coerced, nil
end

function M:CoerceRuleSetting(rule, key, value)
    key = tostring(key or "")
    local spec = self.SuiteRuleSpecs[key]
    local ok, coerced, err = CoerceBySpec(spec, value)
    if not ok then
        self.metrics.settingRejects = (tonumber(self.metrics.settingRejects) or 0) + 1
        return false, nil, err
    end
    if key == "healthMin" then coerced = math.min(coerced, tonumber(rule and rule.healthMax) or 100) end
    if key == "healthMax" then coerced = math.max(coerced, tonumber(rule and rule.healthMin) or 0) end
    self.metrics.settingCoercions = (tonumber(self.metrics.settingCoercions) or 0) + 1
    return true, coerced, nil
end

function M:NormalizeHeadSize(value, fallback)
    return math.floor(Clamp(tonumber(value) or tonumber(fallback) or 18, 12, 60) + 0.5)
end

function M:NormalizeColorChannel(channel, value, fallback)
    channel = tostring(channel or "")
    if channel ~= "r" and channel ~= "g" and channel ~= "b" and channel ~= "a" then return false, nil, "unsupported channel" end
    return true, Clamp(tonumber(value) or tonumber(fallback) or 0, channel == "a" and 0.05 or 0, 1), nil
end

function M:NormalizeLevelThreshold(target, key, value)
    key = tostring(key or "")
    if self.SuiteLevelKeys[key] ~= true then return false, nil, "unsupported level threshold" end
    target = type(target) == "table" and target or {}
    value = tonumber(value) or tonumber(target[key]) or 1
    if key == "attention" then value = Clamp(value, 1, (tonumber(target.high) or 60) - 1)
    elseif key == "high" then value = Clamp(value, (tonumber(target.attention) or 40) + 1, (tonumber(target.emergency) or 80) - 1)
    else value = Clamp(value, (tonumber(target.high) or 60) + 1, 100) end
    return true, math.floor(value + 0.5), nil
end

function M:Describe()
    return {
        version = self.Version,
        maxRules = self.MaxRules,
        normalizeState = tonumber(self.metrics.normalizeState) or 0,
        normalizeRule = tonumber(self.metrics.normalizeRule) or 0,
        normalizeTracked = tonumber(self.metrics.normalizeTracked) or 0,
        normalizeWeights = tonumber(self.metrics.normalizeWeights) or 0,
        settingCoercions = tonumber(self.metrics.settingCoercions) or 0,
        settingRejects = tonumber(self.metrics.settingRejects) or 0,
    }
end

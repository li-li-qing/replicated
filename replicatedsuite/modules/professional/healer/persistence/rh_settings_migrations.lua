ReplicatedSuiteModuleSandbox:Enter('healer', {'ReplicatedHealerBoot', 'ReplicatedHealerConfig', 'ReplicatedHealerModule'})
------------------------------------------------------------------------
-- Replicated Healer - Settings Migrations v1
--
-- Historical one-shot transformations only.  This file must never own normal
-- settings validation or UI behavior; that belongs to rh_settings_model.lua.
------------------------------------------------------------------------

ReplicatedHealerSettingsMigrations = ReplicatedHealerSettingsMigrations or {}
local G = ReplicatedHealerSettingsMigrations
G.Version = "1.0"
G.metrics = G.metrics or { runs = 0, applied = 0, legacyV1 = 0 }

local Model = ReplicatedHealerSettingsModel
if type(Model) ~= "table" then return end

local function Touch(self)
    self.metrics.applied = (tonumber(self.metrics.applied) or 0) + 1
end

function G:ApplyLegacyV1(target, legacy, defaults)
    if type(target) ~= "table" or type(legacy) ~= "table" then return false end
    self.metrics.legacyV1 = (tonumber(self.metrics.legacyV1) or 0) + 1
    target.panelAnchor = Model:CopyAnchor(legacy.panelAnchor, defaults.panelAnchor, false)
    target.launcherAnchor = Model:CopyAnchor(legacy.launcherAnchor, defaults.launcherAnchor, false)
    target.raidOverlayTop = Model:CopyAnchor(legacy.raidOverlayTop, defaults.raidOverlayTop, true)
    target.raidOverlayBottom = Model:CopyAnchor(legacy.raidOverlayBottom, defaults.raidOverlayBottom, true)
    target.raidOverlayTopRaid2 = Model:CopyAnchor(legacy.raidOverlayTopRaid2, defaults.raidOverlayTopRaid2, true)
    target.raidOverlayBottomRaid2 = Model:CopyAnchor(legacy.raidOverlayBottomRaid2, defaults.raidOverlayBottomRaid2, true)
    local panelMode = tonumber(legacy.recommendPanelMode) or tonumber(defaults.panelMode) or 1
    target.panelMode = math.max(1, math.min(3, math.floor(panelMode)))
    Touch(self)
    return true
end

function G:Apply(target, defaults, saved, loadedVersion)
    self.metrics.runs = (tonumber(self.metrics.runs) or 0) + 1
    target = type(target) == "table" and target or {}
    defaults = type(defaults) == "table" and defaults or Model:BuildDefaults()
    loadedVersion = math.max(0, math.floor(tonumber(loadedVersion) or 0))

    for index = 1, #(target.rules or {}) do
        local rule = target.rules[index]
        if type(rule) == "table" then
            if loadedVersion < 210
                and rule.name == "持续回血"
                and math.abs((tonumber(rule.minRemainingMs) or 0) - 2000) < 0.01 then
                rule.minRemainingMs = 0
                Touch(self)
            end
            if loadedVersion < 211
                and rule.name == "持续回血"
                and math.abs((tonumber(rule.customDistance) or 0) - 20) < 0.01 then
                rule.customDistance = 27
                Touch(self)
            end
            if loadedVersion < 213
                and rule.name == "持续回血"
                and type(rule.color) == "table"
                and math.abs((tonumber(rule.color.r) or 0) - 1.00) < 0.01
                and math.abs((tonumber(rule.color.g) or 0) - 0.48) < 0.01
                and math.abs((tonumber(rule.color.b) or 0) - 0.08) < 0.01 then
                rule.color = { r = 0.72, g = 0.30, b = 1.00, a = 0.82 }
                Touch(self)
            end
        end
    end

    -- settings 217: recover explicit tracked Buffs from old rule IDs/colors.
    if loadedVersion < 217 and type(saved) == "table" and type(saved.trackedBuffs) ~= "table" then
        local migrated, seen = {}, {}
        for _, rule in ipairs(target.rules or {}) do
            if type(rule) == "table" and rule.enabled ~= false then
                for _, id in ipairs(rule.ids or {}) do
                    id = tonumber(id)
                    if id ~= nil and id > 0 and not seen[id] and #migrated < Model.MaxRules then
                        seen[id] = true
                        migrated[#migrated + 1] = {
                            id = id,
                            name = tostring(rule.name or ("Buff " .. tostring(id))),
                            enabled = true,
                            color = Model:CopyColor(rule.color, defaults.trackedBuffs and defaults.trackedBuffs[1] and defaults.trackedBuffs[1].color),
                        }
                    end
                end
            end
        end
        target.trackedBuffs = #migrated > 0 and migrated or Model:DeepCopy(defaults.trackedBuffs)
        Touch(self)
    end

    if loadedVersion < 218 and type(target.launcherAnchor) == "table" then
        local a = target.launcherAnchor
        local oldClusterDefault = a.horizontal == "LEFT" and a.vertical == "TOP"
            and math.abs((tonumber(a.offsetX) or 0) - 12) < 0.01
            and math.abs((tonumber(a.offsetY) or 0) - 150) < 0.01
        if oldClusterDefault then
            target.launcherAnchor = Model:CopyAnchor(defaults.launcherAnchor, defaults.launcherAnchor, false)
            Touch(self)
        end
    end

    -- Historical launcher implementations/default anchors.  This compatibility
    -- check is intentionally not version-gated because old incompatible builds
    -- may carry a newer settingsVersion through hand-edited/copy-forward data.
    local launcher = type(target.launcherAnchor) == "table" and target.launcherAnchor or {}
    local oldRightDefault = launcher.horizontal == "RIGHT" and launcher.vertical == "TOP"
        and math.abs((tonumber(launcher.offsetX) or 0) - 24) < 0.01
        and math.abs((tonumber(launcher.offsetY) or 0) - 148) < 0.01
    local compatibleBootstrap = target.launcherImplementation == "bootstrap_v21"
        or target.launcherImplementation == defaults.launcherImplementation
    if oldRightDefault or not compatibleBootstrap then
        target.launcherAnchor = Model:CopyAnchor(defaults.launcherAnchor, defaults.launcherAnchor, false)
        Touch(self)
    end
    target.launcherImplementation = defaults.launcherImplementation

    if loadedVersion < 215 and type(target.launcherAnchor) == "table" then
        local a = target.launcherAnchor
        local oldLauncherDefault = a.horizontal == "LEFT" and a.vertical == "TOP"
            and math.abs((tonumber(a.offsetX) or 0) - 12) < 0.01
            and math.abs((tonumber(a.offsetY) or 0) - 118) < 0.01
        if oldLauncherDefault then
            target.launcherAnchor = Model:CopyAnchor(defaults.launcherAnchor, defaults.launcherAnchor, false)
            Touch(self)
        end
    end
    if loadedVersion == 218 and target.enabled == false then
        target.enabled = true
        Touch(self)
    end
    if loadedVersion < 216 then
        target.launcherAnchor = Model:CopyAnchor(defaults.launcherAnchor, defaults.launcherAnchor, false)
        Touch(self)
    end

    if loadedVersion < 209 then
        local function UsesOldOverlayDefault(rect, oldY)
            return type(rect) == "table"
                and rect.horizontal == "LEFT"
                and rect.vertical == "TOP"
                and math.abs((tonumber(rect.offsetX) or 0) - 0) < 0.01
                and math.abs((tonumber(rect.offsetY) or 0) - oldY) < 0.01
                and math.abs((tonumber(rect.width) or 0) - 500) < 0.01
                and math.abs((tonumber(rect.height) or 0) - 176) < 0.01
        end
        if UsesOldOverlayDefault(target.raidOverlayTop, 175) then
            target.raidOverlayTop = Model:CopyAnchor(defaults.raidOverlayTop, defaults.raidOverlayTop, true)
            Touch(self)
        end
        if UsesOldOverlayDefault(target.raidOverlayBottom, 359) then
            target.raidOverlayBottom = Model:CopyAnchor(defaults.raidOverlayBottom, defaults.raidOverlayBottom, true)
            Touch(self)
        end
    end

    if loadedVersion < 210
        and math.abs((tonumber(target.enterThreshold) or 0) - 90) < 0.01
        and math.abs((tonumber(target.exitThreshold) or 0) - 95) < 0.01 then
        target.enterThreshold = 100
        target.exitThreshold = 100
        Touch(self)
    end
    if loadedVersion < 212 and math.abs((tonumber(target.emergencyThreshold) or 0) - 20) < 0.01 then
        target.emergencyThreshold = 50
        Touch(self)
    end
    if loadedVersion < 221 and tonumber(target.raidEffectMode) == 2 then
        target.raidEffectMode = 1
        Touch(self)
    end

    if loadedVersion < 217 then
        target.proximityMode = true
        local oldRange = type(saved) == "table" and saved.proximityColor or nil
        local usesOldBlue = type(oldRange) == "table"
            and math.abs((tonumber(oldRange.r) or 0) - 0.40) < 0.01
            and math.abs((tonumber(oldRange.g) or 0) - 0.72) < 0.01
            and math.abs((tonumber(oldRange.b) or 0) - 1.00) < 0.01
        if type(saved) ~= "table" or oldRange == nil or usesOldBlue then
            target.proximityColor = Model:CopyColor(defaults.proximityColor)
        end
        if type(saved) ~= "table" or type(saved.lowHealthColor) ~= "table" then
            target.lowHealthColor = Model:CopyColor(defaults.lowHealthColor)
        end
        if type(saved) ~= "table" or type(saved.emergencyColor) ~= "table" then
            target.emergencyColor = Model:CopyColor(defaults.emergencyColor)
        end
        Touch(self)
    end

    return target
end

function G:Describe()
    return {
        version = self.Version,
        runs = tonumber(self.metrics.runs) or 0,
        applied = tonumber(self.metrics.applied) or 0,
        legacyV1 = tonumber(self.metrics.legacyV1) or 0,
    }
end

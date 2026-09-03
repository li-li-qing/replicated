ReplicatedSuiteModuleSandbox:Enter('dps', {'ReplicatedDps', 'ReplicatedDpsConfig'})
------------------------------------------------------------------------
-- Replicated DPS - Sequential schema migrations
-- Author: Replicated
--
-- Migration functions are pure: they never call game APIs and never mutate the
-- source table. Persistence ownership remains in replicateddps_core.lua.
------------------------------------------------------------------------

if ReplicatedDps == nil or ReplicatedDps.Boot == nil then return end

local D = ReplicatedDps
local Boot = D.Boot
Boot:SetPhase("MIGRATIONS_LOADING")

D.Migrations = D.Migrations or {}
local M = D.Migrations

M.CONFIG_SCHEMA_VERSION = 3
M.lastConfigReport = nil

local function DeepCopy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] ~= nil then return seen[value] end
    local result = {}
    seen[value] = result
    for key, item in pairs(value) do
        result[DeepCopy(key, seen)] = DeepCopy(item, seen)
    end
    return result
end

local function MergeDefaults(target, defaults)
    if type(target) ~= "table" then target = {} end
    if type(defaults) ~= "table" then return target end
    for key, value in pairs(defaults) do
        if target[key] == nil then
            target[key] = DeepCopy(value)
        elseif type(value) == "table" and type(target[key]) == "table" then
            MergeDefaults(target[key], value)
        end
    end
    return target
end

local legacyConfigFields = {
    "rankingLimitVersion",
    "friendlyInferencePolicyVersion",
    "nearbyPvePolicyVersion",
    "deterministicRelationPolicyVersion",
    "strictFriendly",
    "extendedFriendly",
    "syncGuildWhenMarkingPlayer",
    "includeNearbyPvePlayers",
    "mergeConfirmedPets",
}

local function RemoveLegacyFields(config, report)
    for _, key in ipairs(legacyConfigFields) do
        if config[key] ~= nil then
            config[key] = nil
            report.changed = true
            report.removedLegacyFields = report.removedLegacyFields + 1
        end
    end
end

local function UpgradeV1ToV2(config, report)
    report.fromVersion = 1
    report.toVersion = 2

    if tonumber(config.rankingLimitVersion) ~= 1 then
        config.displayRows = math.max(100, tonumber(config.displayRows) or 0)
        report.rankingLimitMigrated = true
        report.changed = true
    end

    if tonumber(config.friendlyInferencePolicyVersion) ~= 2
        or tonumber(config.nearbyPvePolicyVersion) ~= 1
        or tonumber(config.deterministicRelationPolicyVersion) ~= 1
        or config.strictFriendly ~= false
        or config.extendedFriendly ~= true
        or config.includeNearbyPvePlayers ~= true then
        report.requiresReclassify = true
    end

    RemoveLegacyFields(config, report)
    config.schemaVersion = 2
    report.changed = true
    return config
end

local function UpgradeV2ToV3(config, report)
    -- v3 changes only startup semantics: combat collection is opt-in.  Force a
    -- one-time disabled state when upgrading so installing this release never
    -- starts background statistics before the player explicitly enables it.
    config.enabled = false
    config.schemaVersion = 3
    report.toVersion = 3
    report.changed = true
    return config
end

function M:UpgradeConfig(source, defaults)
    if type(source) ~= "table" then return nil, nil, "config is not a table" end
    local config = DeepCopy(source)
    local version = tonumber(config.schemaVersion)
    if version == nil or version ~= version or version == math.huge or version == -math.huge then
        version = 1
    end
    version = math.floor(version)
    if version < 1 then return nil, nil, "unsupported config schema " .. tostring(version) end
    if version > self.CONFIG_SCHEMA_VERSION then
        return nil, nil, "future config schema " .. tostring(version)
    end

    local report = {
        fromVersion = version,
        toVersion = version,
        changed = false,
        requiresReclassify = false,
        rankingLimitMigrated = false,
        removedLegacyFields = 0,
        source = "unknown",
        needsSave = false,
    }

    while version < self.CONFIG_SCHEMA_VERSION do
        if version == 1 then
            config = UpgradeV1ToV2(config, report)
            version = 2
        elseif version == 2 then
            config = UpgradeV2ToV3(config, report)
            version = 3
        else
            return nil, nil, "missing migration from schema " .. tostring(version)
        end
    end

    -- A hand-edited or hot-reloaded v2 table may still contain retired v1 keys.
    RemoveLegacyFields(config, report)
    if config.schemaVersion ~= self.CONFIG_SCHEMA_VERSION then
        config.schemaVersion = self.CONFIG_SCHEMA_VERSION
        report.changed = true
    end
    report.toVersion = self.CONFIG_SCHEMA_VERSION
    config = MergeDefaults(config, defaults)
    return config, report, nil
end

function M:SelectConfig(candidates, defaults)
    candidates = type(candidates) == "table" and candidates or {}
    local rejected = {}
    for _, candidate in ipairs(candidates) do
        if type(candidate) == "table" and type(candidate.value) == "table" then
            local config, report, err = self:UpgradeConfig(candidate.value, defaults)
            if config ~= nil then
                report.source = tostring(candidate.source or "unknown")
                report.needsSave = report.changed == true
                    or (report.source ~= "memory" and report.source ~= "primary")
                report.rejectedCandidates = rejected
                self.lastConfigReport = report
                return config, report
            end
            rejected[#rejected + 1] = {
                source = tostring(candidate.source or "unknown"),
                error = tostring(err or "invalid config"),
            }
        end
    end

    local config = MergeDefaults({}, defaults)
    config.schemaVersion = self.CONFIG_SCHEMA_VERSION
    local report = {
        fromVersion = nil,
        toVersion = self.CONFIG_SCHEMA_VERSION,
        changed = true,
        requiresReclassify = false,
        rankingLimitMigrated = false,
        removedLegacyFields = 0,
        source = "defaults",
        needsSave = true,
        rejectedCandidates = rejected,
    }
    self.lastConfigReport = report
    return config, report
end

function M:DescribeConfigReport(report)
    report = type(report) == "table" and report or self.lastConfigReport
    if type(report) ~= "table" then return "配置迁移：无记录" end
    local fromText = report.fromVersion ~= nil and ("v" .. tostring(report.fromVersion)) or "新配置"
    return "配置迁移：" .. fromText .. "→v" .. tostring(report.toVersion)
        .. "；来源=" .. tostring(report.source)
        .. "；重算=" .. (report.requiresReclassify == true and "是" or "否")
        .. "；移除旧字段=" .. tostring(report.removedLegacyFields or 0)
        .. "；拒绝候选=" .. tostring(type(report.rejectedCandidates) == "table" and #report.rejectedCandidates or 0)
end

Boot:CompletePhase("MIGRATIONS_READY")

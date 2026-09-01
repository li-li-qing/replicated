ReplicatedSuiteModuleSandbox:Enter('healer', {'ReplicatedHealerBoot', 'ReplicatedHealerConfig', 'ReplicatedHealerModule'})
------------------------------------------------------------------------
-- Replicated Healer - Settings Bootstrap v1
--
-- Read-only boot Authority.  It loads primary/backup/legacy snapshots, applies
-- one-shot migrations, then asks SettingsModel for final normalization.  It
-- never writes SaveData; durable migration save is requested by Core1 only
-- after the full Healer boot path is known-good.
------------------------------------------------------------------------

ReplicatedHealerSettingsBootstrap = ReplicatedHealerSettingsBootstrap or {}
local B = ReplicatedHealerSettingsBootstrap
B.Version = "1.0"
B.metrics = B.metrics or {
    loads = 0,
    primary = 0,
    backup = 0,
    legacy = 0,
    defaults = 0,
    failures = 0,
    futureSchema = 0,
}

local Model = ReplicatedHealerSettingsModel
local Migrations = ReplicatedHealerSettingsMigrations
if type(Model) ~= "table" or type(Migrations) ~= "table" then return end

local function SafeLoad(key)
    local ok, value = pcall(function() return ADDON:LoadData(key) end)
    if not ok then return nil, tostring(value) end
    return value, nil
end

function B:Load(config)
    self.metrics.loads = (tonumber(self.metrics.loads) or 0) + 1
    config = type(config) == "table" and config or ReplicatedHealerConfig or {}
    local settingsVersion = math.max(1, math.floor(tonumber(config.SettingsVersion) or 1))
    local primaryKey = tostring(config.SaveKey or "replicated_healer_recommender_v2")
    local backupKey = primaryKey .. "_backup"
    local legacyKey = tostring(config.LegacySaveKey or "replicated_healer_recommender_v1")
    local defaults = Model:BuildDefaults(config)
    local target = Model:DeepCopy(defaults)

    local saved, primaryErr = SafeLoad(primaryKey)
    local source = "default"
    local recoveredFromBackup = false
    local backupErr = nil
    if type(saved) == "table" then
        source = "primary"
        self.metrics.primary = (tonumber(self.metrics.primary) or 0) + 1
    else
        local backup
        backup, backupErr = SafeLoad(backupKey)
        if type(backup) == "table" then
            saved = backup
            source = "backup"
            recoveredFromBackup = true
            self.metrics.backup = (tonumber(self.metrics.backup) or 0) + 1
        elseif primaryErr ~= nil or backupErr ~= nil then
            self.metrics.failures = (tonumber(self.metrics.failures) or 0) + 1
            return nil, {
                ok = false,
                error = "配置读取失败：" .. tostring(primaryErr or "primary empty") .. " / " .. tostring(backupErr or "backup empty"),
                primaryError = primaryErr,
                backupError = backupErr,
                defaults = defaults,
            }
        end
    end

    local loadedVersion = type(saved) == "table" and math.max(0, math.floor(tonumber(saved.settingsVersion) or 0)) or 0
    local writeFenceReason = nil
    if loadedVersion > settingsVersion then
        writeFenceReason = "future_settings_schema:" .. tostring(loadedVersion) .. ">" .. tostring(settingsVersion)
        self.metrics.futureSchema = (tonumber(self.metrics.futureSchema) or 0) + 1
    end

    if type(saved) == "table" then
        for key, value in pairs(saved) do target[key] = Model:DeepCopy(value) end
    else
        local legacy, legacyErr = SafeLoad(legacyKey)
        if type(legacy) == "table" then
            source = "legacy_v1"
            Migrations:ApplyLegacyV1(target, legacy, defaults)
            self.metrics.legacy = (tonumber(self.metrics.legacy) or 0) + 1
        else
            self.metrics.defaults = (tonumber(self.metrics.defaults) or 0) + 1
            -- Legacy read errors are intentionally non-fatal when v2 data does
            -- not exist; the user still receives a clean default session.
            if legacyErr ~= nil then source = "default_legacy_unreadable" end
        end
    end

    Migrations:Apply(target, defaults, saved, loadedVersion)
    Model:NormalizeState(target, defaults, settingsVersion)
    if #target.trackedBuffs == 0 and loadedVersion <= 0 then
        target.trackedBuffs = Model:NormalizeTrackedBuffList(Model:DeepCopy(defaults.trackedBuffs))
    end

    local needsMigrationSave = recoveredFromBackup == true
        or source == "legacy_v1"
        or (type(saved) == "table" and loadedVersion < settingsVersion)

    return target, {
        ok = true,
        source = source,
        loadedVersion = loadedVersion,
        settingsVersion = settingsVersion,
        recoveredFromBackup = recoveredFromBackup,
        needsMigrationSave = needsMigrationSave,
        writeFenceReason = writeFenceReason,
        primaryError = primaryErr,
        backupError = backupErr,
        defaults = defaults,
    }
end

function B:Describe()
    return {
        version = self.Version,
        loads = tonumber(self.metrics.loads) or 0,
        primary = tonumber(self.metrics.primary) or 0,
        backup = tonumber(self.metrics.backup) or 0,
        legacy = tonumber(self.metrics.legacy) or 0,
        defaults = tonumber(self.metrics.defaults) or 0,
        failures = tonumber(self.metrics.failures) or 0,
        futureSchema = tonumber(self.metrics.futureSchema) or 0,
    }
end

ReplicatedSuiteModuleSandbox:Enter('healer', {'ReplicatedHealerBoot', 'ReplicatedHealerConfig', 'ReplicatedHealerModule'})
------------------------------------------------------------------------
-- Replicated Healer - Settings Persistence Store v1
--
-- Durable persistence Authority for Healer settings. Boot-time read/migration
-- is owned by rh_settings_bootstrap/rh_settings_migrations; after that validated
-- snapshot exists, every normal mutation is debounced through the Suite
-- Persistence framework. The custom writer preserves the existing
-- backup-first + clear-before-replace safety contract required by ArcheRage RU.
------------------------------------------------------------------------

if ReplicatedHealerCore1Loaded ~= true then return end

ReplicatedHealerSettingsStore = ReplicatedHealerSettingsStore or {}
local H = ReplicatedHealerSettingsStore
H.Version = "1.1"
H.StoreId = "healer.settings"
H.DefaultDelayMs = 750
H.registered = false
H.lastReason = nil
H.lastFlushError = nil
H.metrics = H.metrics or {
    dirtyRequests = 0,
    flushes = 0,
    flushFailures = 0,
    backupWrites = 0,
    primaryWrites = 0,
}

local Suite = rawget(_G, "ReplicatedSuite") or ReplicatedSuite
local Persistence = Suite and Suite.Persistence or nil
local Diagnostics = Suite and Suite.DiagnosticsManager or nil
local LegacySaveState = SaveState

local function Emit(level, code, message, context)
    if type(Diagnostics) == "table" and type(Diagnostics.Emit) == "function" then
        Diagnostics:Emit(level, "healer", code, message, context)
    elseif Suite ~= nil and type(Suite.RecordLog) == "function" then
        Suite.RecordLog(level, "healer", "[" .. tostring(code) .. "] " .. tostring(message))
    end
end

local function Count(code, delta)
    if type(Diagnostics) == "table" and type(Diagnostics.Count) == "function" then
        Diagnostics:Count("healer", code, delta or 1)
    end
end

local function SafeLoad(key)
    if Suite ~= nil and Suite.Api ~= nil and type(Suite.Api.LoadData) == "function" then
        return Suite.Api:LoadData(key)
    end
    local ok, value = pcall(function() return ADDON:LoadData(key) end)
    if not ok then return nil, tostring(value) end
    return value, nil
end

local function SafeClear(key)
    if Suite ~= nil and Suite.Api ~= nil and type(Suite.Api.ClearData) == "function" then
        local ok, err = Suite.Api:ClearData(key)
        if ok == true then return true end
        local remaining, loadErr = SafeLoad(key)
        if loadErr ~= nil then return false, loadErr end
        if remaining == nil or remaining == false then return true end
        return false, err or "ClearData returned false and data still exists"
    end
    local ok, result = pcall(function() return ADDON:ClearData(key) end)
    if ok and result ~= false then return true end
    local remaining, loadErr = SafeLoad(key)
    if loadErr ~= nil then return false, loadErr end
    if remaining == nil or remaining == false then return true end
    return false, ok and "ClearData returned false and data still exists" or tostring(result)
end

local function SafeSave(key, payload)
    if Suite ~= nil and Suite.Api ~= nil and type(Suite.Api.SaveData) == "function" then
        return Suite.Api:SaveData(key, payload)
    end
    local ok, result = pcall(function() return ADDON:SaveData(key, payload) end)
    if not ok then return false, tostring(result) end
    if result == false then return false, "SaveData returned false" end
    return true
end

local function ReplaceSavedTable(key, payload)
    local cleared, clearErr = SafeClear(key)
    if not cleared then return false, clearErr end
    return SafeSave(key, payload)
end

function H:_WriteBackupFirst(primaryKey, encodedPayload)
    if storageWriteFenceReason ~= nil then
        return false, "write fenced: " .. tostring(storageWriteFenceReason)
    end

    local backupKey = tostring(SAVE_KEY_V2_BACKUP or (tostring(primaryKey) .. "_backup"))
    local backupOk, backupErr = ReplaceSavedTable(backupKey, encodedPayload)
    if backupOk ~= true then
        lastSaveError = "备份保存失败：" .. tostring(backupErr or "unknown")
        self.metrics.flushFailures = (tonumber(self.metrics.flushFailures) or 0) + 1
        Count("SETTINGS_BACKUP_SAVE_FAILED", 1)
        Emit("warning", "SETTINGS_BACKUP_SAVE_FAILED", "Healer 设置备份保存失败", {
            key = backupKey,
            error = backupErr,
        })
        return false, lastSaveError
    end
    self.metrics.backupWrites = (tonumber(self.metrics.backupWrites) or 0) + 1

    local primaryOk, primaryErr = ReplaceSavedTable(primaryKey, encodedPayload)
    if primaryOk ~= true then
        lastSaveError = "主配置保存失败（备份已保留）：" .. tostring(primaryErr or "unknown")
        self.metrics.flushFailures = (tonumber(self.metrics.flushFailures) or 0) + 1
        Count("SETTINGS_PRIMARY_SAVE_FAILED", 1)
        Emit("warning", "SETTINGS_PRIMARY_SAVE_FAILED", "Healer 主设置保存失败，最新快照已保留在备份槽", {
            key = primaryKey,
            backupKey = backupKey,
            error = primaryErr,
        })
        return false, lastSaveError
    end
    self.metrics.primaryWrites = (tonumber(self.metrics.primaryWrites) or 0) + 1
    lastSaveError = nil
    return true
end

function H:Register()
    if self.registered == true then return true end
    if ReplicatedSuiteEmbedded ~= true or type(Persistence) ~= "table" or type(Persistence.RegisterStore) ~= "function" then
        return false, "suite persistence unavailable"
    end

    local existing = type(Persistence.GetStore) == "function" and Persistence:GetStore(self.StoreId) or nil
    local store = existing
    if store == nil then
        local registered, registerErr = Persistence:RegisterStore({
            id = self.StoreId,
            owner = "healer",
            contractVersion = 2,
            -- Preserve the existing key semantics during M0. Healer identity
            -- migration is a separate Domain task; do not silently fork saves.
            scope = Persistence.Scope.Account,
            lifetime = Persistence.Lifetime.Permanent,
            key = tostring(SAVE_KEY_V2),
            budget = { maxDepth = 10, maxNodes = 4096, maxStringBytes = 65536, maxEntriesPerTable = 512 },
            schemaVersion = math.max(1, math.floor(tonumber(SETTINGS_VERSION) or 1)),
            -- SettingsBootstrap/Migrations have already produced the validated
            -- current-schema snapshot. Persistence must not run a second
            -- historical migration pass here.
            legacySchemaVersion = math.max(1, math.floor(tonumber(SETTINGS_VERSION) or 1)),
            default = function() return DeepCopy(defaults or {}) end,
            -- Keep legacy Healer fields at the root. Core1 boot loader intentionally
            -- ignores the added __rsmeta field, so old/new builds remain mutually
            -- readable during the staged migration.
            encode = function(value) return DeepCopy(value or {}) end,
            get = function() return DeepCopy(state or {}) end,
            apply = function(value)
                if type(value) ~= "table" then return end
                state = DeepCopy(value)
            end,
            save = function(primaryKey, encodedPayload)
                return H:_WriteBackupFirst(primaryKey, encodedPayload)
            end,
        })
        if registered == nil then
            Emit("warning", "SETTINGS_STORE_REGISTER_FAILED", "Healer Persistence Store 注册失败，将保留旧即时保存路径", {
                error = registerErr,
            })
            return false, registerErr
        end
        store = registered
    end

    -- SettingsBootstrap is boot-load Authority. Mark its validated in-memory
    -- snapshot as loaded rather than reading the same key a second time and
    -- risking double migration/normalization.
    store.loaded = true
    store.loadStatus = "legacy_bootstrap_normalized"
    store.writeFenced = storageWriteFenceReason ~= nil
    store.writeFenceReason = storageWriteFenceReason
    store.lastError = storageWriteFenceReason
    self.registered = true
    Count("SETTINGS_STORE_REGISTERED", 1)
    return true
end

function H:MarkDirty(reason, delayMs)
    self.lastReason = tostring(reason or "settings_changed")
    self.metrics.dirtyRequests = (tonumber(self.metrics.dirtyRequests) or 0) + 1
    Count("SETTINGS_DIRTY", 1)

    if storageWriteFenceReason ~= nil then
        lastSaveError = "配置写保护：" .. tostring(storageWriteFenceReason)
        return false, lastSaveError
    end
    if self.registered ~= true or type(Persistence) ~= "table" then
        return LegacySaveState()
    end
    local ok, err = Persistence:MarkDirty(self.StoreId, tonumber(delayMs) or self.DefaultDelayMs, self.lastReason)
    if ok ~= true then
        lastSaveError = tostring(err or "mark dirty failed")
        return false, lastSaveError
    end
    lastSaveError = nil
    return true
end

function H:Flush(reason)
    self.lastReason = tostring(reason or self.lastReason or "explicit_flush")
    self.metrics.flushes = (tonumber(self.metrics.flushes) or 0) + 1
    Count("SETTINGS_FLUSH", 1)

    if storageWriteFenceReason ~= nil then
        self.lastFlushError = "配置写保护：" .. tostring(storageWriteFenceReason)
        lastSaveError = self.lastFlushError
        return false, self.lastFlushError
    end
    if self.registered ~= true or type(Persistence) ~= "table" then
        local ok = LegacySaveState()
        self.lastFlushError = ok == true and nil or tostring(lastSaveError or "legacy save failed")
        return ok == true, self.lastFlushError
    end

    -- Ensure the current state is considered dirty even if the caller requests
    -- an explicit final save without a preceding UI mutation.
    Persistence:MarkDirty(self.StoreId, 0, self.lastReason)
    local ok, err = Persistence:SaveStore(self.StoreId, { reason = self.lastReason })
    if ok ~= true then
        self.metrics.flushFailures = (tonumber(self.metrics.flushFailures) or 0) + 1
        self.lastFlushError = tostring(err or "save failed")
        lastSaveError = self.lastFlushError
        return false, self.lastFlushError
    end
    self.lastFlushError = nil
    lastSaveError = nil
    return true
end

function H:Describe()
    local store = self.registered == true and Persistence and Persistence:GetStore(self.StoreId) or nil
    return {
        version = tostring(self.Version or "?"),
        registered = self.registered == true,
        storeId = self.StoreId,
        lifetime = store and store.lifetime or "legacy",
        dirty = store and store.dirty == true or false,
        loadStatus = store and store.loadStatus or "legacy",
        writeFenced = storageWriteFenceReason ~= nil or (store and store.writeFenced == true) or false,
        writeFenceReason = storageWriteFenceReason or (store and store.writeFenceReason) or nil,
        lastReason = self.lastReason,
        lastFlushError = self.lastFlushError or lastSaveError,
        dirtyRequests = tonumber(self.metrics.dirtyRequests) or 0,
        flushes = tonumber(self.metrics.flushes) or 0,
        flushFailures = tonumber(self.metrics.flushFailures) or 0,
        backupWrites = tonumber(self.metrics.backupWrites) or 0,
        primaryWrites = tonumber(self.metrics.primaryWrites) or 0,
    }
end

local registeredOk = H:Register()
if registeredOk == true and storageWriteFenceReason == nil and stateNeedsMigrationSave == true then
    local migratedOk, migratedErr = H:Flush("boot_migration")
    if migratedOk == true then
        stateNeedsMigrationSave = false
        Count("SETTINGS_BOOT_MIGRATION_SAVED", 1)
    else
        Emit("warning", "SETTINGS_BOOT_MIGRATION_SAVE_FAILED", "Healer 启动迁移快照保存失败，保留 Dirty/备份恢复能力", {
            error = migratedErr,
        })
    end
end

-- Suite owns runtime lifecycle. Apply the historical enabled flag only after
-- the durable boot snapshot above is safe; this is a session-only override and
-- must never be serialized as part of migration.
if ReplicatedSuiteEmbedded == true and type(state) == "table" then
    state.enabled = false
end

-- Compatibility Proxy. Existing settings controls call SaveState() extensively;
-- they now request a debounced durable save instead of serializing twice for
-- every +/- click. SaveState(true, reason) is the explicit finalization path.
function SaveState(immediate, reason)
    if immediate == true then return H:Flush(reason or "compat_force") end
    return H:MarkDirty(reason or "compat_dirty")
end

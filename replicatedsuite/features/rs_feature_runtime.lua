------------------------------------------------------------------------
-- Replicated Suite V3 - Feature Runtime
--
-- Lifecycle Authority for migrated V3 Features. Planned features may exist in
-- FeatureRegistry without an implementation; they remain unavailable and cost
-- zero runtime work. This manager never starts Legacy ModuleManager entries.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local Registry = S.FeatureRegistry
local P = S.Persistence
if type(Registry) ~= "table" or type(P) ~= "table" then return end

S.FeatureRuntime = {
    version = 3,
    implementations = {},
    state = {},
    order = {},
    preferences = {},
    preferencesLoaded = false,
    preferenceStoreId = "v3.features",
    disableAllFailures = 0,
    lastDisableAllFailures = {},
}
local F = S.FeatureRuntime

local function Emit(level, code, message, context)
    local d = S.DiagnosticsManager
    if type(d) == "table" and type(d.Emit) == "function" then d:Emit(level, "feature_v3", code, message, context) end
end

-- Shared lifecycle topic. Domain publishes facts only; Presentation decides
-- whether a floating widget follows. This is what keeps Feature code from
-- reaching into WidgetHost (and keeps the coupling one-way).
local FEATURE_LIFECYCLE_TOPIC = "v3.feature.lifecycle"
local function PublishLifecycle(id, state, reason)
    if S.Events ~= nil and type(S.Events.Publish) == "function" then
        S.Events:Publish(FEATURE_LIFECYCLE_TOPIC, tostring(id), tostring(state), tostring(reason or ""))
    end
end
F.LifecycleTopic = FEATURE_LIFECYCLE_TOPIC

local function NormalizeId(value)
    return tostring(value or ""):lower():gsub("[^%w_%.%-]", "_"):gsub("_+", "_"):gsub("^_+", ""):gsub("_+$", "")
end


local function NormalizePreferences(value)
    value = type(value) == "table" and value or {}
    local out = {}
    for id, enabled in pairs(value) do
        local normalized = NormalizeId(id)
        if normalized ~= "" and Registry:Get(normalized) ~= nil and type(enabled) == "boolean" then
            out[normalized] = enabled
        end
    end
    return out
end

local function ApplyPreferences(value)
    F.preferences = NormalizePreferences(value)
end

if type(P.RegisterV3Store) == "function" and P:GetStore(F.preferenceStoreId) == nil then
    local store, err = P:RegisterV3Store({
        id = F.preferenceStoreId,
        owner = "v3.features",
        scope = P.Scope.Account,
        lifetime = P.Lifetime.Permanent,
        schemaVersion = 1,
        legacySchemaVersion = 0,
        key = P.V3KeyPrefix .. "features",
        budget = { maxDepth = 4, maxNodes = 160, maxStringBytes = 2048, maxEntriesPerTable = 96 },
        default = function() return {} end,
        get = function() return NormalizePreferences(F.preferences) end,
        apply = ApplyPreferences,
    })
    if store == nil then
        Emit("error", "FEATURE_PREF_STORE_REGISTER_FAILED", "新版功能开关存档注册失败", { error = tostring(err) })
    end
end

function F:EnsurePreferencesLoaded()
    if self.preferencesLoaded == true then return true end
    if P:GetStore(self.preferenceStoreId) == nil then return false, "feature preference store unavailable" end
    local status, _, err = P:LoadStore(self.preferenceStoreId)
    if status == true or status == "empty" then
        if status == "empty" then ApplyPreferences({}) end
        self.preferencesLoaded = true
        return true
    end
    return false, err or tostring(status or "load failed")
end

function F:GetPreferredEnabled(id)
    id = NormalizeId(id)
    local explicit = self.preferences[id]
    if type(explicit) == "boolean" then return explicit, true end
    local meta = Registry:Get(id)
    return meta ~= nil and meta.defaultEnabled == true or false, false
end

function F:SetPreferredEnabled(id, enabled, reason)
    id = NormalizeId(id)
    if Registry:Get(id) == nil then return false, "unknown feature" end
    if self.implementations[id] == nil then return false, "feature not implemented" end
    local loaded, loadErr = self:EnsurePreferencesLoaded()
    if loaded ~= true then return false, loadErr end
    if type(P.CanWrite) ~= "function" then return false, "persistence write preflight unavailable" end
    local writable, writeErr = P:CanWrite(self.preferenceStoreId)
    if writable ~= true then return false, writeErr or "feature preference store write-fenced" end

    local target = enabled == true
    local previousEnabled = self:IsEnabled(id)
    local ok, err
    if target then ok, err = self:Enable(id, reason or "user_enable")
    else ok, err = self:Disable(id, reason or "user_disable") end
    if ok ~= true then return false, err end

    -- Preference table mutation is transactional (MutateStore snapshot/rollback
    -- covers the explicit-preference write); the lifecycle transition above is
    -- rolled back manually below because Enable/Disable side effects cannot be
    -- captured by a persistence snapshot.
    local persisted, persistErr
    if type(P.MutateStore) == "function" then
        persisted, persistErr = P:MutateStore(self.preferenceStoreId, function()
            self.preferences[id] = target
            return true
        end, { delayMs = 350, reason = "feature_preference:" .. id })
    else
        self.preferences[id] = target
        persisted, persistErr = P:MarkDirty(self.preferenceStoreId, 350, "feature_preference:" .. id)
    end
    if persisted == true then return true end

    -- Persistence intent failed after the lifecycle transition. MutateStore has
    -- already restored the explicit preference; restore runtime state so UI can
    -- never report success for a setting that will silently revert on
    -- ReloadAddon.
    local rollbackOk, rollbackErr = true, nil
    if previousEnabled ~= target then
        if previousEnabled then rollbackOk, rollbackErr = self:Enable(id, "preference_persist_rollback")
        else rollbackOk, rollbackErr = self:Disable(id, "preference_persist_rollback") end
    end
    if rollbackOk ~= true then
        Emit("error", "FEATURE_PREF_ROLLBACK_FAILED", "功能开关持久化失败且生命周期回滚失败", {
            feature = id, error = tostring(persistErr or "mark dirty failed"), rollbackError = tostring(rollbackErr or "unknown"),
        })
        return false, tostring(persistErr or "feature preference persistence failed") .. "; rollback failed: " .. tostring(rollbackErr or "unknown")
    end
    return false, persistErr or "feature preference persistence failed"
end

local function Invoke(id, impl, method, ...)
    local fn = impl and impl[method]
    if type(fn) ~= "function" then return true end
    local args, count = { ... }, select("#", ...)
    local ok, a, b = xpcall(function() return fn(impl, unpack(args, 1, count)) end, S.SafeTraceback)
    if not ok then
        Emit("error", "FEATURE_" .. string.upper(method) .. "_FAILED", "V3 Feature 生命周期调用失败", { feature = id, method = method, error = tostring(a) })
        return false, a
    end
    if a == false then return false, b or (method .. " returned false") end
    return true, a
end

function F:RegisterImplementation(featureId, impl)
    local id = NormalizeId(featureId)
    local meta = Registry:Get(id)
    if meta == nil then return false, "feature metadata missing: " .. id end
    if type(impl) ~= "table" then return false, "feature implementation required" end
    if self.implementations[id] ~= nil then return false, "duplicate feature implementation: " .. id end
    for _, method in ipairs({ "Initialize", "Enable", "Disable" }) do
        if type(impl[method]) ~= "function" then return false, "feature requires " .. method .. "(): " .. id end
    end
    self.implementations[id] = impl
    self.state[id] = { initialized = false, enabled = false, faulted = false, lastError = nil, generation = 0 }
    self.order[#self.order + 1] = id
    table.sort(self.order)
    return true
end

function F:IsImplemented(id) return self.implementations[NormalizeId(id)] ~= nil end
function F:IsEnabled(id)
    local row = self.state[NormalizeId(id)]
    return row ~= nil and row.enabled == true
end

function F:Initialize(id)
    id = NormalizeId(id)
    local impl, row = self.implementations[id], self.state[id]
    if impl == nil or row == nil then return false, "feature not implemented" end
    if row.initialized == true then return true end

    -- Business APIs are imported lazily with the Feature that owns them. The
    -- Foundation never pays for every legacy domain simply because the addon
    -- loaded. Implementations may override metadata with ApiDependencies.
    local meta = Registry:Get(id)
    local dependencies = type(impl.ApiDependencies) == "table" and impl.ApiDependencies
        or (meta and meta.apiDependencies) or {}
    if S.ApiImports ~= nil and type(S.ApiImports.Acquire) == "function" then
        local acquired, acquireErr = S.ApiImports:Acquire("feature:" .. id, dependencies)
        if acquired ~= true then
            row.faulted = true
            row.lastError = tostring(acquireErr)
            Emit("error", "FEATURE_API_IMPORT_FAILED", "V3 Feature API 依赖导入失败", { feature = id, error = row.lastError })
            return false, acquireErr
        end
    elseif #dependencies > 0 then
        return false, "api import manager unavailable"
    end

    local ok, err = Invoke(id, impl, "Initialize")
    if ok ~= true then row.faulted = true; row.lastError = tostring(err); return false, err end
    row.initialized, row.faulted, row.lastError = true, false, nil
    row.generation = (tonumber(row.generation) or 0) + 1
    return true
end

function F:Enable(id, reason)
    id = NormalizeId(id)
    local impl, row = self.implementations[id], self.state[id]
    if impl == nil or row == nil then return false, "feature not implemented" end
    if row.enabled == true then return true end
    local initialized, initErr = self:Initialize(id)
    if initialized ~= true then return false, initErr end
    local ok, err = Invoke(id, impl, "Enable", reason or "user")
    if ok ~= true then row.faulted = true; row.lastError = tostring(err); return false, err end
    row.enabled, row.faulted, row.lastError = true, false, nil
    PublishLifecycle(id, "enabled", reason or "user")
    return true
end

function F:Disable(id, reason)
    id = NormalizeId(id)
    local impl, row = self.implementations[id], self.state[id]
    if impl == nil or row == nil then return false, "feature not implemented" end
    -- The row is the public projection, but a previous fault can leave an
    -- implementation-local enabled flag ahead of it. Shutdown must still run
    -- the implementation teardown in that split-brain state.
    if row.enabled ~= true and impl.enabled ~= true then return true end
    local ok, err = Invoke(id, impl, "Disable", reason or "user")
    if ok ~= true then row.faulted = true; row.lastError = tostring(err); return false, err end
    row.enabled = false
    PublishLifecycle(id, "disabled", reason or "user")
    return true
end

local function ForceFeatureDemand(id, reason, cause)
    local demand = S.Demand
    if type(demand) ~= "table" or type(demand.Get) ~= "function" then return true, nil, false end
    local lease = demand:Get("feature:" .. tostring(id))
    if type(lease) ~= "table" or (tonumber(lease.count) or 0) <= 0 or type(lease.ForceQuiesce) ~= "function" then return true, nil, false end
    local ok, err = lease:ForceQuiesce(reason or "feature_shutdown", cause)
    if ok == true then
        -- A forced quiesce is a terminal shutdown fence. Keep the runtime
        -- projection and implementation-local flag aligned even when the
        -- normal Feature:Disable() path failed before reaching them.
        local normalizedId = NormalizeId(id)
        local impl, row = F.implementations[normalizedId], F.state[normalizedId]
        if type(impl) == "table" then impl.enabled = false end
        if type(row) == "table" then
            row.enabled = false
            row.faulted = true
            row.lastError = tostring(cause or "feature disable required forced quiesce")
        end
        PublishLifecycle(id, "disabled", reason or "feature_shutdown")
    end
    return ok == true, err, true
end

function F:DisableAll(reason)
    local failures = {}
    local shutdownReason = reason or "shutdown"
    for index = #self.order, 1, -1 do
        local id = self.order[index]
        local disabled, disableErr = true, nil
        local impl = self.implementations[id]
        if self:IsEnabled(id) or (type(impl) == "table" and impl.enabled == true) then
            disabled, disableErr = self:Disable(id, shutdownReason)
            if disabled ~= true then
                failures[#failures + 1] = tostring(id) .. ":disable:" .. tostring(disableErr or "failed")
            end
        end

        -- A failed Feature Disable must not leave its downstream lease alive.
        -- ForceQuiesce is deliberately a last-resort path: normal Disable keeps
        -- transactional rollback semantics, while this fence makes shutdown and
        -- recovery deterministic even when a native release call fails.
        local quiet, quietErr, hadResidualDemand = ForceFeatureDemand(id, shutdownReason, disableErr)
        if quiet ~= true then
            failures[#failures + 1] = tostring(id) .. ":quiesce:" .. tostring(quietErr or "failed")
        elseif hadResidualDemand == true and disabled == true then
            -- Forced cleanup keeps shutdown safe, but a stale lease is still a
            -- lifecycle failure and must not be reported as a green shutdown.
            failures[#failures + 1] = tostring(id) .. ":stale_demand:forced_quiesce"
        end
    end
    self.lastDisableAllFailures = failures
    if #failures > 0 then
        self.disableAllFailures = (tonumber(self.disableAllFailures) or 0) + #failures
        Emit("error", "FEATURE_DISABLE_ALL_FAILED", "V3 Feature 批量关闭存在失败，已尝试强制静默", {
            reason = tostring(shutdownReason), failures = failures,
        })
        return false, table.concat(failures, ";")
    end
    return true
end

function F:EnableDefaults(reason)
    local loaded, loadErr = self:EnsurePreferencesLoaded()
    if loaded ~= true then return false, loadErr end
    local failures = {}
    for _, id in ipairs(self.order) do
        if self.implementations[id] ~= nil then
            local preferred = self:GetPreferredEnabled(id)
            if preferred == true then
                local ok, err = self:Enable(id, reason or "default_enable")
                if ok ~= true then failures[#failures + 1] = id .. ":" .. tostring(err or "failed") end
            end
        end
    end
    if #failures > 0 then return false, table.concat(failures, ";") end
    return true
end

function F:RefreshEnabled(reason)
    for _, id in ipairs(self.order) do
        local impl, row = self.implementations[id], self.state[id]
        if impl ~= nil and row ~= nil and row.enabled == true and type(impl.Refresh) == "function" then
            local ok, err = Invoke(id, impl, "Refresh", reason or "refresh")
            if ok ~= true then row.faulted = true; row.lastError = tostring(err) end
        end
    end
    return true
end

function F:GetSnapshot(id)
    id = NormalizeId(id)
    local meta, impl, row = Registry:Get(id), self.implementations[id], self.state[id]
    if meta == nil then return nil end
    local health = nil
    if impl ~= nil and type(impl.GetHealth) == "function" then
        local ok, value = xpcall(function() return impl:GetHealth() end, S.SafeTraceback)
        health = ok and value or { ok = false, error = tostring(value) }
    end
    return {
        id = id, name = meta.name, route = meta.route, category = meta.category,
        implemented = impl ~= nil,
        initialized = row and row.initialized == true or false,
        enabled = row and row.enabled == true or false,
        faulted = row and row.faulted == true or false,
        lastError = row and row.lastError or nil,
        preferredEnabled = self:GetPreferredEnabled(id),
        health = health,
    }
end

function F:Describe()
    local implemented, initialized, enabled, faulted = 0, 0, 0, 0
    for _, id in ipairs(Registry.order) do
        local row = self.state[id]
        if self.implementations[id] ~= nil then implemented = implemented + 1 end
        if row and row.initialized then initialized = initialized + 1 end
        if row and row.enabled then enabled = enabled + 1 end
        if row and row.faulted then faulted = faulted + 1 end
    end
    local explicit = 0
    for _ in pairs(self.preferences or {}) do explicit = explicit + 1 end
    return {
        version = self.version, catalog = #Registry.order, implemented = implemented, initialized = initialized,
        enabled = enabled, faulted = faulted, preferencesLoaded = self.preferencesLoaded == true,
        explicitPreferences = explicit, disableAllFailures = tonumber(self.disableAllFailures) or 0,
        lastDisableAllFailures = S.Utils and type(S.Utils.DeepCopy) == "function"
            and S.Utils.DeepCopy(self.lastDisableAllFailures or {}) or self.lastDisableAllFailures or {},
    }
end

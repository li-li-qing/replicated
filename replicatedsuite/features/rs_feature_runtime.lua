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
    version = 5, -- 2026-09-25: add atomic ApplyPreferenceTargets batch lifecycle/preference transaction.
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
F.StartupEnableIntentContractVersion = 1

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

-- 中文维护注释（Framework2 功能总开关兼容）：`v3.features` 是动态 key map，Store
-- default 必须保持空表，因此 Core 无法从 default 推导“哪个 feature=false 被 RU 吞掉”。
-- 对默认开启 Feature，这个 false 会改变下一次登录的真实生命周期，必须单独恢复。
-- 这里最多枚举当前 Registry 中 defaultEnabled=true 且磁盘缺失的子集；候选只有在
-- **完全复现旧 stamped fingerprint** 时才返回给 Persistence。没有精确命中就继续
-- fail-closed，绝不把“缺失”直接猜成 false。当前默认开启项很少，且本函数只在旧
-- Framework2 + Integrity mismatch 冷路径运行，不增加任何 Feature Tick/事件成本。
local function RebuildFeaturePreferenceCanonical(decoded, stampedFingerprint, _, raw)
    if type(raw) ~= "table" or type(raw.__rsmeta) ~= "table" then return nil end
    local framework = tonumber(raw.__rsmeta.framework) or 0
    if framework < 1 or framework > 2 then return nil end
    local store = P:GetStore(F.preferenceStoreId)
    if type(store) ~= "table" then return nil end

    local base = type(raw.payload) == "table" and NormalizePreferences(raw.payload)
        or (type(decoded) == "table" and NormalizePreferences(decoded) or {})
    local missing = {}
    for _, meta in ipairs(Registry:List()) do
        if meta.defaultEnabled == true and base[meta.id] == nil then missing[#missing + 1] = meta.id end
    end
    if #missing < 1 or #missing > 12 then return nil end

    local candidate = S.Utils and type(S.Utils.DeepCopy) == "function" and S.Utils.DeepCopy(base) or {}
    if next(candidate) == nil then for key, value in pairs(base) do candidate[key] = value end end
    local matched = nil
    local probes = 0
    local function Probe(index, selected)
        if matched ~= nil then return end
        if index > #missing then
            if selected < 1 then return end
            probes = probes + 1
            local fingerprint = P:FingerprintCanonicalValue(store, candidate)
            if fingerprint ~= nil and tostring(fingerprint) == tostring(stampedFingerprint) then
                matched = {}
                for key, value in pairs(candidate) do matched[key] = value end
            end
            return
        end
        Probe(index + 1, selected)
        if matched ~= nil then return end
        candidate[missing[index]] = false
        Probe(index + 1, selected + 1)
        candidate[missing[index]] = nil
    end
    Probe(1, 0)
    store.lastHistoricalRecoveryProbe = "feature_default_enabled_false_candidates=" .. tostring(probes)
        .. "/matched=" .. tostring(matched ~= nil)
    if matched == nil then return nil end
    return matched, matched
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
        rebuildCanonicalForIntegrity = RebuildFeaturePreferenceCanonical,
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
    local meta = Registry:Get(id)
    local group = meta and meta.preferenceGroup
    if type(group)=="table" and #group>1 then
        local primary=self.preferences[group[1]]
        if type(primary)=="boolean" then return primary,true end
        -- 仅旧分析开关有显式偏好时保留开启意图；读取不写回存档。
        for _,member in ipairs(group) do if self.preferences[member]==true then return true,true end end
    end
    local explicit = self.preferences[id]
    if type(explicit) == "boolean" then return explicit, true end
    return meta ~= nil and meta.defaultEnabled == true or false, false
end

function F:SetPreferredEnabled(id, enabled, reason)
    -- Registry 的组合元数据声明一次用户开关涉及哪些内部切片；事务仍由 Runtime 独占。
    local groupMeta = Registry:Get(id)
    if groupMeta and type(groupMeta.preferenceGroup)=="table" and #groupMeta.preferenceGroup>1 then
        return self:ApplyPreferenceTargets({[id]=enabled==true}, reason or "group_toggle")
    end
    id = NormalizeId(id)
    if Registry:Get(id) == nil then return false, "unknown feature" end
    if self.implementations[id] == nil then return false, "feature not implemented" end
    local loaded, loadErr = self:EnsurePreferencesLoaded()
    if loaded ~= true then return false, loadErr end
    if type(P.CanWrite) ~= "function" then return false, "persistence write preflight unavailable" end
    local writable, writeErr = P:CanWrite(self.preferenceStoreId)
    if writable ~= true then return false, writeErr or "feature preference store write-fenced" end

    local target = enabled == true
    local previousPreference = self.preferences[id]
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
        -- 中文维护（2026-10-03）：单个开关与批量方案采用同一耐久事务。旧 350ms
        -- 延迟只代表已排期，点击后马上下线/重载可能尚未写入；成功必须已保存并回读验证。
        end, { durable = true, reason = "feature_preference:" .. id })
    else
        self.preferences[id] = target
        if type(P.SaveStore) == "function" then
            persisted, persistErr = P:SaveStore(self.preferenceStoreId, { durable = true, verifyAfterSave = true,
                consumeDirty = true, reason = "feature_preference:" .. id })
        else persisted, persistErr = false, "durable feature preference save unavailable" end
        if persisted ~= true then self.preferences[id] = previousPreference end
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

-- 中文维护注释（2026-09-25，feature-preference-batch-transaction-1）：功能方案需要一次切换多个
-- Feature。逐项调用 SetPreferredEnabled 会在中途失败时留下“前半已经保存、后半未执行”的混合状态，
-- 也会把恢复动作拆成多次磁盘提交。这里由 FeatureRuntime（唯一生命周期 Authority）提供受控批量事务：
-- 先验证全部目标 -> 仅改变 Runtime 生命周期 -> 单次 durable 保存 v3.features；任一步失败都按反向顺序
-- 恢复已经发生的生命周期变化。Persistence.MutateStore 自己负责 preferences RAM/dirty metadata 回滚。
-- 该接口只接受明确 boolean target；调用者决定哪些业务 Feature 参与，Runtime 不推断“生活/战斗”等语义。
function F:ApplyPreferenceTargets(targets, reason)
    -- 维护（2026-09-30，feature-profile-failure-evidence-1）：前两个返回值保持兼容；第三值
    -- 提供真实失败阶段/目标/回滚结果。调用者不得解析本地化错误文本判断失败模块，
    -- 也不能在 rollback 失败时声称“已负责回滚”。只创建本次调用结果，不持久化或扫描 Store。
    local function Failed(message, stage, id, target, rollbackOk, rollbackErr, changed, cause)
        local targetValue
        if type(target) == "boolean" then targetValue = target end
        return false, message, {
            contractVersion = 1, stage = stage, featureId = id,
            targetEnabled = targetValue,
            error = tostring(message), cause = tostring(cause or message),
            rollbackAttempted = (tonumber(changed) or 0) > 0,
            rollbackSucceeded = rollbackOk == true, rollbackError = rollbackErr,
            changed = tonumber(changed) or 0,
        }
    end
    if type(targets) ~= "table" then return Failed("feature preference targets required", "preflight", nil, nil, true) end
    local loaded, loadErr = self:EnsurePreferencesLoaded()
    if loaded ~= true then return Failed(loadErr, "preflight", nil, nil, true) end
    if type(P.CanWrite) ~= "function" then return Failed("persistence write preflight unavailable", "preflight", nil, nil, true) end
    local writable, writeErr = P:CanWrite(self.preferenceStoreId)
    if writable ~= true then return Failed(writeErr or "feature preference store write-fenced", "preflight", nil, nil, true) end
    if type(P.MutateStore) ~= "function" then return Failed("persistence transaction unavailable", "preflight", nil, nil, true) end

    -- 旧方案可能同时含主功能=true、旧隐藏子页=false；以组合第一个（主功能）为准。
    -- 只扩展 Registry 明确声明的组，绝不在 Core 点名业务 Feature。
    local requested={}
    for rawId,target in pairs(targets) do
        local id=NormalizeId(rawId)
        if id=="" or Registry:Get(id)==nil then return Failed("unknown feature: "..tostring(rawId),"preflight",id,target,true) end
        if type(target)~="boolean" then return Failed("feature target must be boolean: "..id,"preflight",id,target,true) end
        if requested[id]~=nil then return Failed("duplicate normalized feature target: "..id,"preflight",id,target,true) end
        requested[id]=target
    end
    local expanded={};for id,target in pairs(requested) do expanded[id]=target end
    for id,target in pairs(requested) do
        local meta=Registry:Get(id)
        local group=meta and meta.preferenceGroup
        if type(group)=="table" and #group>1 then
            local primary=requested[group[1]]
            if primary==nil then primary=target end
            for _,member in ipairs(group) do expanded[member]=primary end
        end
    end
    targets=expanded
    local ordered, normalizedTargets = {}, {}
    for rawId, rawTarget in pairs(targets) do
        local id = NormalizeId(rawId)
        if id == "" or Registry:Get(id) == nil then return Failed("unknown feature: " .. tostring(rawId), "preflight", id, rawTarget, true) end
        if self.implementations[id] == nil then return Failed("feature not implemented: " .. id, "preflight", id, rawTarget, true) end
        if type(rawTarget) ~= "boolean" then return Failed("feature target must be boolean: " .. id, "preflight", id, rawTarget, true) end
        if normalizedTargets[id] ~= nil then return Failed("duplicate normalized feature target: " .. id, "preflight", id, rawTarget, true) end
        normalizedTargets[id] = rawTarget
        ordered[#ordered + 1] = id
    end
    table.sort(ordered)
    if #ordered == 0 then return true, { changed = 0, targets = 0 } end

    local previous, transitioned = {}, {}
    for _, id in ipairs(ordered) do
        previous[id] = { enabled = self:IsEnabled(id) }
    end

    local function RollbackLifecycle(cause)
        local failures = {}
        for index = #transitioned, 1, -1 do
            local id = transitioned[index]
            local wanted = previous[id] and previous[id].enabled == true or false
            local ok, err
            if wanted then ok, err = self:Enable(id, "preference_batch_rollback")
            else ok, err = self:Disable(id, "preference_batch_rollback") end
            if ok ~= true then failures[#failures + 1] = id .. ":" .. tostring(err or "rollback failed") end
        end
        if #failures > 0 then
            Emit("error", "FEATURE_PREF_BATCH_ROLLBACK_FAILED", "批量功能开关事务失败且生命周期回滚不完整", {
                reason = tostring(reason or "batch"), cause = tostring(cause or "unknown"), failures = failures,
            })
            return false, table.concat(failures, ";")
        end
        return true
    end

    for _, id in ipairs(ordered) do
        local target = normalizedTargets[id] == true
        if self:IsEnabled(id) ~= target then
            local ok, err
            if target then ok, err = self:Enable(id, reason or "preference_batch")
            else ok, err = self:Disable(id, reason or "preference_batch") end
            if ok ~= true then
                local rollbackOk, rollbackErr = RollbackLifecycle(err)
                local message = id .. ":" .. tostring(err or "lifecycle transition failed")
                if rollbackOk ~= true then message = message .. "; rollback failed: " .. tostring(rollbackErr) end
                return Failed(message, "lifecycle", id, target, rollbackOk, rollbackErr, #transitioned, err)
            end
            transitioned[#transitioned + 1] = id
        end
    end

    local persisted, persistErr = P:MutateStore(self.preferenceStoreId, function()
        for _, id in ipairs(ordered) do self.preferences[id] = normalizedTargets[id] == true end
        return true
    end, { durable = true, reason = tostring(reason or "feature_preference_batch") })
    if persisted ~= true then
        local rollbackOk, rollbackErr = RollbackLifecycle(persistErr)
        local message = persistErr or "feature preference batch persistence failed"
        if rollbackOk ~= true then message = tostring(message) .. "; rollback failed: " .. tostring(rollbackErr or "unknown") end
        return Failed(message, "persist", nil, nil, rollbackOk, rollbackErr, #transitioned, persistErr)
    end

    Emit("info", "FEATURE_PREF_BATCH_APPLIED", "批量功能开关事务已提交", {
        reason = tostring(reason or "batch"), targets = #ordered, changed = #transitioned,
    })
    return true, { changed = #transitioned, targets = #ordered }
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
        local impl = self.implementations[id]
        if impl ~= nil then
            local preferred, explicit = self:GetPreferredEnabled(id)

            -- Some persistent screen surfaces predate the Feature preference
            -- linkage contract. A Feature may expose a bounded, store-backed
            -- one-time startup intent repair. The generic Runtime owns the
            -- preference transaction; the Feature only proves whether a
            -- historical persistent intent exists. No Feature may silently
            -- override an already-linked explicit user disable on later reloads.
            if preferred ~= true and type(impl.GetStartupEnableIntent) == "function" then
                local intentOk, wanted, intentReason = xpcall(function()
                    return impl:GetStartupEnableIntent(preferred, explicit)
                end, S.SafeTraceback)
                if intentOk ~= true then
                    failures[#failures + 1] = id .. ":startup_intent:" .. tostring(wanted or "failed")
                elseif wanted == true then
                    local repaired, repairErr = self:SetPreferredEnabled(id, true,
                        "startup_intent:" .. tostring(intentReason or "persistent_surface"))
                    if repaired ~= true then
                        failures[#failures + 1] = id .. ":startup_intent_repair:" .. tostring(repairErr or "failed")
                    else
                        preferred = true
                        if type(impl.OnStartupEnableIntentCommitted) == "function" then
                            local linkedCallOk, linkedResult, linkedErr = xpcall(function()
                                return impl:OnStartupEnableIntentCommitted(intentReason or "persistent_surface")
                            end, S.SafeTraceback)
                            if linkedCallOk ~= true or linkedResult ~= true then
                                Emit("warning", "FEATURE_STARTUP_INTENT_LINK_FAILED",
                                    "持久界面启动意图已恢复，但 Feature 链接标记保存失败", {
                                        feature = id, error = tostring(linkedCallOk == true and (linkedErr or "returned_false") or linkedResult),
                                    })
                            end
                        end
                    end
                end
            end

            if preferred == true and self:IsEnabled(id) ~= true then
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

-- 维护（module-controls-diag-2）：导航/工具条只读运行时薄状态，不触发 GetHealth/Store Load。
-- preferred 不是当前运行态；初始化失败或停用回滚必须以 enabled 的实际值着色。
function F:GetControlState(id)
    id = NormalizeId(id)
    local row = self.state[id]
    return { implemented = self.implementations[id] ~= nil, initialized = row and row.initialized == true or false,
        enabled = row and row.enabled == true or false, faulted = row and row.faulted == true or false,
        lastError = row and row.lastError or nil }
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

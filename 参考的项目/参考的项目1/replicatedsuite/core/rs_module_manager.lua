------------------------------------------------------------------------
-- Replicated Suite - Module Manager
-- Author: Replicated
-- Architecture baseline: Replicated Suite v1.1 / 2026-08-15
--
-- Suite Authority only owns module registration/lifecycle/fault isolation.
-- Mutable business/domain state remains inside each module/service.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite

S.ModuleManager = {
    registry = {},
    order = {},
    initialized = false,
    shuttingDown = false,
}
local M = S.ModuleManager

local VALID_CATEGORIES = {
    life = true,
    combat = true,
    utility = true,
    common = true,
    internal = true,
}

local function NormalizeId(value)
    return tostring(value or ""):lower():gsub("[^%w_%-]", "")
end

local function CopyTable(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, child in pairs(value) do result[key] = CopyTable(child) end
    return result
end

local function EnsurePersistedState(id, defaultEnabled)
    S.State.modules = type(S.State.modules) == "table" and S.State.modules or {}
    local state = S.State.modules[id]
    if type(state) ~= "table" then
        state = { enabled = defaultEnabled == true }
        S.State.modules[id] = state
    elseif state.enabled == nil then
        state.enabled = defaultEnabled == true
    end
    return state
end

local function RuntimeState(def)
    def.Runtime = type(def.Runtime) == "table" and def.Runtime or {}
    local runtime = def.Runtime
    if runtime.state == nil then runtime.state = "Loaded" end
    if runtime.failureCount == nil then runtime.failureCount = 0 end
    return runtime
end

-- Module enable/disable is explicit user intent, not a background preference.
-- Do not leave that intent dependent on the next scheduler storage tick: a
-- client reload/logout/character transition can happen before the delayed write
-- runs. Normal callers commit immediately; bulk profile application may request
-- a deferred/coalesced commit and flush once after all module transitions.
local function PersistEnabledIntent(def, enabled, saveMode)
    if def == nil or def.Internal == true then return true end
    EnsurePersistedState(def.Id, def.DefaultEnabled).enabled = enabled == true

    local storage = S.Storage
    if storage == nil then return true end
    if type(storage.RequestSave) == "function" then storage:RequestSave(0) end
    if saveMode == "deferred" or type(storage.SaveNow) ~= "function" then return true end

    local saved = storage:SaveNow()
    if saved ~= true and S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Record) == "function" then
        S.DiagnosticsManager:Record("warning", tostring(def.Id),
            "module intent persistence pending/failed: " .. tostring(storage.lastError or "SaveNow returned false"))
    end
    -- Runtime lifecycle success remains independent from persistence transport.
    -- SaveNow keeps transient failures dirty/backed off, and write fences already
    -- publish a user-facing warning. Never roll the live module back merely
    -- because one persistence attempt failed.
    return saved == true
end

local function RecordFault(def, stage, err)
    local runtime = RuntimeState(def)
    runtime.state = "Faulted"
    runtime.lastStage = tostring(stage or "unknown")
    runtime.lastError = tostring(err or "unknown")
    runtime.lastErrorAt = S.NowMs and S.NowMs() or 0
    runtime.failureCount = (tonumber(runtime.failureCount) or 0) + 1
    runtime.enabled = false

    S.Diagnostics = type(S.Diagnostics) == "table" and S.Diagnostics or {}
    S.Diagnostics.moduleFaults = type(S.Diagnostics.moduleFaults) == "table" and S.Diagnostics.moduleFaults or {}
    S.Diagnostics.moduleFaults[def.Id] = {
        stage = runtime.lastStage,
        error = runtime.lastError,
        at = runtime.lastErrorAt,
        count = runtime.failureCount,
    }

    if def.Internal ~= true then
        local compactError = tostring(runtime.lastError or "unknown"):gsub("[\r\n]+", " ")
        if #compactError > 180 then compactError = string.sub(compactError, 1, 180) .. "…" end
        S.WarnOnce("module_fault:" .. tostring(def.Id) .. ":" .. runtime.lastStage,
            tostring(def.Name or def.Id) .. " 已安全停用：" .. runtime.lastStage .. " 失败 · " .. compactError)
    end
    if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Record) == "function" then
        S.DiagnosticsManager:Record("error", tostring(def.Id), tostring(runtime.lastStage) .. ": " .. tostring(runtime.lastError))
    end
    if S.State ~= nil then S.State:MarkDirty("modules") end
end

local function CallHook(def, hookName, ...)
    local hook = def and def[hookName] or nil
    if type(hook) ~= "function" then return true, nil end
    local args = { ... }
    local argCount = select("#", ...)
    local ok, value = xpcall(function() return hook(def, unpack(args, 1, argCount)) end, S.SafeTraceback)
    if not ok then
        RecordFault(def, hookName, value)
        return false, value
    end
    if value == false then
        local err = tostring(hookName) .. " returned false"
        RecordFault(def, hookName, err)
        return false, err
    end
    return true, value
end

-- UI/settings helpers are not lifecycle Authority.  A transient settings-window
-- failure must never flip runtime.enabled or leave a live module behind while
-- ModuleManager reports it as Faulted/off.
local function CallNonFatalHook(def, hookName, ...)
    local hook = def and def[hookName] or nil
    if type(hook) ~= "function" then return true, nil end
    local args = { ... }
    local argCount = select("#", ...)
    local ok, value = xpcall(function() return hook(def, unpack(args, 1, argCount)) end, S.SafeTraceback)
    if not ok or value == false then
        local err = ok and (tostring(hookName) .. " returned false") or tostring(value)
        if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Record) == "function" then
            S.DiagnosticsManager:Record("warning", tostring(def and def.Id or "module"), tostring(hookName) .. ": " .. err)
        end
        return false, err
    end
    return true, value
end

-- Lifecycle hooks are allowed to allocate event subscriptions, scheduler jobs
-- and module-local drivers before their final success point.  If Enable/Disable
-- faults midway, the failed module must not leave a zombie Runtime behind.
-- Cleanup deliberately bypasses CallHook so the original failure stage/error
-- remains the diagnostic Authority.
local function BestEffortCleanup(def, reason, retryDisableHook)
    if def == nil then return end
    local cleanupErrors = {}

    if retryDisableHook == true and type(def.Disable) == "function" then
        local ok, value = xpcall(function() return def:Disable(reason or "fault_cleanup") end, S.SafeTraceback)
        if not ok or value == false then cleanupErrors[#cleanupErrors + 1] = tostring(value or "Disable returned false") end
    end

    local service = def._service
    local scope = S.Reuse and S.Reuse.OwnerScope
    if scope ~= nil and type(scope.Release) == "function" then
        pcall(function() scope.Release({ events=S.Events, scheduler=S.Scheduler, observation=S.Observation }, def, "professional:" .. tostring(def.Id or "")) end)
        if service ~= nil then pcall(function() scope.Release({ events=S.Events, scheduler=S.Scheduler }, service) end) end
    else
        if S.Events ~= nil and type(S.Events.UnsubscribeOwner) == "function" then
            pcall(function() S.Events:UnsubscribeOwner(def) end)
            if service ~= nil then pcall(function() S.Events:UnsubscribeOwner(service) end) end
        end
        if S.Scheduler ~= nil and type(S.Scheduler.RemoveOwner) == "function" then
            pcall(function() S.Scheduler:RemoveOwner(def) end)
            if service ~= nil then pcall(function() S.Scheduler:RemoveOwner(service) end) end
        end
    end
    if S.Observation ~= nil and type(S.Observation.Unsubscribe) == "function" then
        pcall(function() S.Observation:Unsubscribe("professional:" .. tostring(def.Id or "")) end)
    end

    if #cleanupErrors > 0 and S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Record) == "function" then
        S.DiagnosticsManager:Record("warning", tostring(def.Id or "module"),
            "fault cleanup: " .. table.concat(cleanupErrors, "; "))
    end
end

function M:Register(def)
    if type(def) ~= "table" then return false, "module definition must be table" end
    local id = NormalizeId(def.Id)
    if id == "" then return false, "module Id is required" end
    if self.registry[id] ~= nil then return false, "duplicate module: " .. id end

    def.Id = id
    def.Name = tostring(def.Name or id)
    def.Category = VALID_CATEGORIES[def.Category] and def.Category or "utility"
    def.DefaultEnabled = def.DefaultEnabled == true
    def.Internal = def.Internal == true
    def.Professional = def.Professional == true
    def.SettingsLabel = tostring(def.SettingsLabel or "设置")
    local scope = tostring(def.DataScope or "account"):lower()
    def.DataScope = (scope == "character" or scope == "mixed") and scope or "account"
    def.HudIds = type(def.HudIds) == "table" and CopyTable(def.HudIds) or {}
    RuntimeState(def)

    self.registry[id] = def
    self.order[#self.order + 1] = id
    if def.Internal ~= true and S.SettingsRegistry ~= nil and type(S.SettingsRegistry.RegisterModule) == "function" then
        S.SettingsRegistry:RegisterModule(id, def.Name, tostring(def.SettingsKeywords or def.Name or id))
    end
    return true, def
end

function M:Get(id)
    return self.registry[NormalizeId(id)]
end

function M:IsRegistered(id)
    return self:Get(id) ~= nil
end

function M:IsEnabled(id)
    local def = self:Get(id)
    if def == nil then return false end
    return RuntimeState(def).enabled == true
end

function M:GetPersistedEnabled(id)
    local def = self:Get(id)
    if def == nil then return false end
    return EnsurePersistedState(def.Id, def.DefaultEnabled).enabled == true
end

function M:InitializeOne(id)
    local def = self:Get(id)
    if def == nil then return false, "unknown module" end
    local runtime = RuntimeState(def)
    if runtime.initialized == true then return true end
    if runtime.state == "Faulted" then return false, runtime.lastError end

    local ok, err = CallHook(def, "Initialize")
    if not ok then
        BestEffortCleanup(def, "initialize_fault", true)
        runtime.enabled = false
        runtime.initialized = false
        return false, err
    end
    runtime.initialized = true
    runtime.state = "Initialized"
    return true
end

function M:InitializeAll()
    for _, id in ipairs(self.order) do
        local def = self.registry[id]
        -- Professional domains are intentionally lazy while their Suite module
        -- is disabled. Their source files are already loaded by the consolidated
        -- TOC so static settings remain discoverable, but running Initialize on
        -- every disabled professional module turns an optional/domain-local boot
        -- limitation into a Suite lifecycle Faulted state. Quiet-by-default means
        -- an OFF professional module must remain Disabled until the user enables
        -- it (or opens a path that explicitly requires initialization).
        --
        -- Persisted-ON professional modules are still initialized here and will
        -- fail closed normally if their runtime really cannot start.
        if def ~= nil and (def.Professional ~= true or self:GetPersistedEnabled(id)) then
            self:InitializeOne(id)
        end
    end
    self.initialized = true
    return true
end

function M:Enable(id, persist, saveMode)
    local def = self:Get(id)
    if def == nil then return false, "unknown module" end
    local runtime = RuntimeState(def)
    if runtime.enabled == true then return true end
    if runtime.state == "Faulted" then return false, runtime.lastError or "module faulted" end

    local initialized, initErr = self:InitializeOne(id)
    if not initialized then return false, initErr end

    local ok, err = CallHook(def, "Enable")
    if not ok then
        BestEffortCleanup(def, "enable_fault", true)
        runtime.enabled = false
        if S.HudManager ~= nil and type(S.HudManager.OnModuleEnabledChanged) == "function" then
            S.HudManager:OnModuleEnabledChanged(def.Id, false)
        end
        return false, err
    end
    runtime.enabled = true
    runtime.state = "Enabled"
    runtime.lastEnabledAt = S.NowMs and S.NowMs() or 0

    if persist ~= false and def.Internal ~= true then
        PersistEnabledIntent(def, true, saveMode)
    end
    if S.HudManager ~= nil and type(S.HudManager.OnModuleEnabledChanged) == "function" then
        S.HudManager:OnModuleEnabledChanged(def.Id, true)
    end
    if S.State ~= nil then S.State:MarkDirty("modules") end
    return true
end

function M:Disable(id, persist, reason, saveMode)
    local def = self:Get(id)
    if def == nil then return false, "unknown module" end
    local runtime = RuntimeState(def)

    -- Disable is intentionally idempotent and never clears domain/config data.
    -- A module that has already reached Disabled has completed its cleanup
    -- transition; do not enter a professional Disable hook again merely because
    -- its code/settings remain initialized for searchable settings. Faulted
    -- modules remain eligible for another best-effort cleanup attempt.
    local needsDisableHook = runtime.enabled == true
        or (runtime.initialized == true and runtime.state ~= "Disabled")
    if needsDisableHook then
        local ok, err = CallHook(def, "Disable", reason)
        if not ok then
            -- The user's disable request remains Authority even if a module's
            -- cleanup hook faults. Retry cleanup best-effort, persist OFF and keep
            -- the original Disable fault visible in diagnostics.
            BestEffortCleanup(def, reason or "disable_fault", true)
            runtime.enabled = false
            runtime.lastDisabledAt = S.NowMs and S.NowMs() or 0
            runtime.lastDisableReason = tostring(reason or "user")
            if persist ~= false and def.Internal ~= true then
                PersistEnabledIntent(def, false, saveMode)
            end
            if S.HudManager ~= nil and type(S.HudManager.OnModuleEnabledChanged) == "function" then
                S.HudManager:OnModuleEnabledChanged(def.Id, false)
            end
            if S.State ~= nil then S.State:MarkDirty("modules") end
            return false, err
        end
    end

    runtime.enabled = false
    if runtime.state ~= "Faulted" then runtime.state = "Disabled" end
    runtime.lastDisabledAt = S.NowMs and S.NowMs() or 0
    runtime.lastDisableReason = tostring(reason or "user")

    if persist ~= false and def.Internal ~= true then
        PersistEnabledIntent(def, false, saveMode)
    end
    if S.HudManager ~= nil and type(S.HudManager.OnModuleEnabledChanged) == "function" then
        S.HudManager:OnModuleEnabledChanged(def.Id, false)
    end
    if S.State ~= nil then S.State:MarkDirty("modules") end
    return true
end

function M:SetEnabled(id, enabled, saveMode)
    if enabled == true then return self:Enable(id, true, saveMode) end
    return self:Disable(id, true, "user", saveMode)
end

function M:StartConfiguredModules()
    for _, id in ipairs(self.order) do
        local def = self.registry[id]
        if def ~= nil then
            local enabled = def.Internal == true and def.DefaultEnabled == true or self:GetPersistedEnabled(id)
            if enabled then self:Enable(id, false) else self:Disable(id, false, "startup_disabled") end
        end
    end
end

function M:OpenSettings(id)
    local def = self:Get(id)
    if def == nil then return false, "unknown module" end
    -- A missing settings hook is not success.  The old behaviour silently
    -- returned true and left a live-looking "设置" button that did nothing.
    -- Fail closed so future modules cannot reintroduce dead UI entries.
    if type(def.OpenSettings) ~= "function" then
        return false, "该模块没有可用的设置入口"
    end
    local initialized, err = self:InitializeOne(id)
    if not initialized then return false, err end
    local ok, value = CallNonFatalHook(def, "OpenSettings")
    return ok, value
end

function M:Describe(id)
    local def = self:Get(id)
    if def == nil then return nil end
    local runtime = RuntimeState(def)
    local detail = {
        id = def.Id,
        name = def.Name,
        category = def.Category,
        internal = def.Internal == true,
        professional = def.Professional == true,
        dataScope = def.DataScope,
        enabled = runtime.enabled == true,
        initialized = runtime.initialized == true,
        state = tostring(runtime.state or "Loaded"),
        lastStage = runtime.lastStage,
        lastError = runtime.lastError,
        failureCount = tonumber(runtime.failureCount) or 0,
        hudIds = CopyTable(def.HudIds),
        hasSettings = type(def.OpenSettings) == "function",
        settingsLabel = tostring(def.SettingsLabel or "设置"),
    }
    if type(def.DescribeRuntime) == "function" then
        local ok, extra = xpcall(function() return def:DescribeRuntime() end, S.SafeTraceback)
        if ok and type(extra) == "table" then
            for key, value in pairs(extra) do detail[key] = value end
        elseif not ok then
            detail.describeError = tostring(extra)
        end
    end
    return detail
end

function M:List(includeInternal)
    local result = {}
    for _, id in ipairs(self.order) do
        local def = self.registry[id]
        if def ~= nil and (includeInternal == true or def.Internal ~= true) then
            result[#result + 1] = self:Describe(id)
        end
    end
    return result
end

-- Runtime callbacks live outside lifecycle hook xpcall boundaries.  Modules may
-- report a persistent runtime failure here after their own small transient
-- retry budget is exhausted.  Persisted user intent is intentionally retained
-- so the Modules page can offer an explicit Retry without silently changing
-- the user's configuration.
function M:ReportRuntimeFault(id, stage, err)
    local def = self:Get(id)
    if def == nil then return false, "unknown module" end
    local runtime = RuntimeState(def)
    if runtime.state == "Faulted" then return false, runtime.lastError or "module faulted" end
    RecordFault(def, stage or "Runtime", err or "runtime failure")
    BestEffortCleanup(def, "runtime_fault", true)
    runtime.enabled = false
    if S.HudManager ~= nil and type(S.HudManager.OnModuleEnabledChanged) == "function" then
        S.HudManager:OnModuleEnabledChanged(def.Id, false)
    end
    if S.State ~= nil then S.State:MarkDirty("modules") end
    return false, runtime.lastError
end

function M:Retry(id)
    local def = self:Get(id)
    if def == nil then return false, "unknown module" end
    local runtime = RuntimeState(def)
    runtime.state = runtime.initialized == true and "Initialized" or "Loaded"
    runtime.lastError = nil
    runtime.lastStage = nil
    S.Diagnostics.moduleFaults = type(S.Diagnostics.moduleFaults) == "table" and S.Diagnostics.moduleFaults or {}
    S.Diagnostics.moduleFaults[def.Id] = nil
    if self:GetPersistedEnabled(id) then return self:Enable(id, false) end
    return true
end

function M:Shutdown()
    if self.shuttingDown == true then return end
    self.shuttingDown = true
    for index = #self.order, 1, -1 do
        local def = self.registry[self.order[index]]
        if def ~= nil then
            if RuntimeState(def).enabled == true then self:Disable(def.Id, false, "shutdown") end
            local shutdownOk = CallHook(def, "Shutdown")
            if shutdownOk ~= true then
                -- Shutdown faults must not strand native handlers/jobs just
                -- because the module's final hook failed partway through.
                BestEffortCleanup(def, "shutdown_fault", false)
            end
            local runtime = RuntimeState(def)
            runtime.enabled = false
            runtime.initialized = false
            if runtime.state ~= "Faulted" then runtime.state = "Shutdown" end
        end
    end
    self.shuttingDown = false
end

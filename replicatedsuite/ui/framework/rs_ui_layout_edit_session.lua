------------------------------------------------------------------------
-- Replicated Suite - RSUI Layout Edit Session v1
--
-- Shared session Authority for Reset / Revert / Apply semantics.
--
-- Four-state contract (all snapshots are bounded data copies):
--
--   Persisted       last snapshot confirmed durable by the caller
--       ↕ Apply only
--   SessionBaseline snapshot accepted when this editor session began, or the
--                   last snapshot promoted by a successful Apply
--       ↕ Revert
--   Working         live Domain/layout state edited by PreviewAdapter + History
--       ↕ Reset (stage only; NEVER persists)
--   Defaults        frozen default snapshot for the current session
--
-- Semantics:
--   * Revert: Working <- SessionBaseline. No SaveData / Store write.
--   * Reset : Working <- Defaults. No SaveData / Store clear/write.
--   * Apply : persist current Working explicitly; only after the caller reports
--             durable success do Persisted and SessionBaseline advance.
--
-- Persistence boundary:
--   this model never calls S.Persistence/S.Api directly. The owning Feature or
--   future Workspace adapter supplies persistSnapshot(snapshot, context), and it
--   MUST return true only after the durable write is confirmed. A debounced
--   MarkDirty alone is not sufficient for Apply success.
--
-- History boundary:
--   an optional LayoutEditHistoryModel is observed so successful Record/Undo/
--   Redo refresh Working without polling. Revert/Reset/Apply are history
--   barriers and clear history on success; this prevents Undo from crossing a
--   semantic baseline that no longer matches the live Working state.
--
-- Performance:
--   no Tick / OnUpdate / Scheduler. Snapshot copy/equality is bounded and runs
--   only on session creation, explicit commands, rebase, or History events.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI = S.RSUI
if type(RSUI) ~= "table" then return end

RSUI.LayoutEditSessionContractVersion = 1
RSUI.LayoutEditSessionPersistenceBoundaryContractVersion = 1

local MAX_SNAPSHOT_DEPTH = 8
local DEFAULT_MAX_SNAPSHOT_NODES = 2048
local HARD_MAX_SNAPSHOT_NODES = 8192

RSUI.LayoutEditSessionLimits = {
    maxSnapshotDepth = MAX_SNAPSHOT_DEPTH,
    defaultMaxSnapshotNodes = DEFAULT_MAX_SNAPSHOT_NODES,
    hardMaxSnapshotNodes = HARD_MAX_SNAPSHOT_NODES,
}

local function N(value, fallback)
    local result = tonumber(value)
    if result == nil then result = tonumber(fallback) or 0 end
    return result
end

local function ValidNumber(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function CopyValue(value, depth, state)
    local kind = type(value)
    if kind == "nil" or kind == "boolean" or kind == "string" then return value, nil end
    if kind == "number" then
        if ValidNumber(value) ~= true then return nil, "layout_edit_session_snapshot_number_invalid" end
        return value, nil
    end
    if kind ~= "table" then return nil, "layout_edit_session_snapshot_type_invalid:" .. kind end
    if depth >= MAX_SNAPSHOT_DEPTH then return nil, "layout_edit_session_snapshot_depth_exceeded" end
    if state.stack[value] == true then return nil, "layout_edit_session_snapshot_cycle" end

    state.nodes = state.nodes + 1
    if state.nodes > state.maxNodes then return nil, "layout_edit_session_snapshot_nodes_exceeded" end
    state.stack[value] = true
    local out = {}
    for key, child in pairs(value) do
        local keyType = type(key)
        if keyType ~= "string" and keyType ~= "number" then
            state.stack[value] = nil
            return nil, "layout_edit_session_snapshot_key_invalid:" .. keyType
        end
        if keyType == "number" and ValidNumber(key) ~= true then
            state.stack[value] = nil
            return nil, "layout_edit_session_snapshot_key_number_invalid"
        end
        local copied, err = CopyValue(child, depth + 1, state)
        if err ~= nil then state.stack[value] = nil; return nil, err end
        out[key] = copied
    end
    state.stack[value] = nil
    return out, nil
end

local function CopySnapshot(value, maxNodes)
    if type(value) ~= "table" then return nil, "layout_edit_session_snapshot_table_required" end
    return CopyValue(value, 0, { nodes = 0, maxNodes = maxNodes, stack = {} })
end

local function StateEqual(left, right, depth)
    if left == right then return true end
    if type(left) ~= type(right) then return false end
    if type(left) ~= "table" then return left == right end
    if depth >= MAX_SNAPSHOT_DEPTH then return false end
    for key, value in pairs(left) do
        if right[key] == nil and value ~= nil then return false end
        if StateEqual(value, right[key], depth + 1) ~= true then return false end
    end
    for key, value in pairs(right) do
        if left[key] == nil and value ~= nil then return false end
    end
    return true
end

local function SafeRead(label, callback, owner, maxNodes)
    local ok, value = xpcall(function() return callback(owner) end, S.SafeTraceback)
    if ok ~= true then return nil, "layout_edit_session_" .. tostring(label) .. "_read_failed:" .. tostring(value) end
    local copied, copyErr = CopySnapshot(value, maxNodes)
    if copied == nil then return nil, "layout_edit_session_" .. tostring(label) .. "_invalid:" .. tostring(copyErr) end
    return copied, nil
end

local function SafeApply(label, callback, snapshot, context, owner, maxNodes)
    local copied, copyErr = CopySnapshot(snapshot, maxNodes)
    if copied == nil then return false, copyErr end
    local ok, accepted, detail = xpcall(function() return callback(copied, context, owner) end, S.SafeTraceback)
    if ok ~= true then return false, "layout_edit_session_" .. tostring(label) .. "_failed:" .. tostring(accepted) end
    if accepted ~= true then return false, tostring(detail or ("layout_edit_session_" .. tostring(label) .. "_rejected")) end
    return true, detail
end

local function HistoryValid(model)
    if model == nil then return true end
    return type(model) == "table"
        and type(model.GetSnapshot) == "function"
        and type(model.Clear) == "function"
        and type(model.Subscribe) == "function" and type(model.Unsubscribe) == "function"
end

local Model = {}
Model.__index = Model

function Model:_Reject(reason)
    self.lastError = tostring(reason or "layout_edit_session_rejected")
    RSUI.metrics.layoutEditSessionRejects = (tonumber(RSUI.metrics.layoutEditSessionRejects) or 0) + 1
    return false, self.lastError
end

function Model:_RecomputeFlags()
    self.sessionChanged = StateEqual(self.workingSnapshot, self.baselineSnapshot, 0) ~= true
    self.dirty = StateEqual(self.workingSnapshot, self.persistedSnapshot, 0) ~= true
    self.workingAtDefaults = StateEqual(self.workingSnapshot, self.defaultSnapshot, 0) == true
    self.baselineMatchesPersisted = StateEqual(self.baselineSnapshot, self.persistedSnapshot, 0) == true
end

function Model:_CanPersist()
    if self.blocked == true then return false, self.blockReason or "layout_edit_session_blocked" end
    if type(self.canPersist) ~= "function" then return true, nil end
    local ok, allowed, reason = xpcall(function() return self.canPersist(self) end, S.SafeTraceback)
    if ok ~= true then return false, "layout_edit_session_can_persist_failed:" .. tostring(allowed) end
    if allowed ~= true then return false, tostring(reason or "layout_edit_session_persistence_unavailable") end
    return true, nil
end

function Model:_Changed(reason, detail)
    local snapshot = self:GetCommandSnapshot()
    for token, listener in pairs(self.listeners or {}) do
        if type(listener) == "function" then
            RSUI:Callback("rsui:layout_edit_session:" .. tostring(self.id) .. ":listener:" .. tostring(token),
                listener, self, tostring(reason or "changed"), snapshot, detail)
        end
    end
end

function Model:Subscribe(token, listener)
    token = tostring(token or "")
    if token == "" or type(listener) ~= "function" then return false end
    self.listeners[token] = listener
    return true
end

function Model:Unsubscribe(token)
    token = tostring(token or "")
    if self.listeners[token] == nil then return false end
    self.listeners[token] = nil
    return true
end

function Model:GetCommandSnapshot()
    local persistAllowed, persistReason = self:_CanPersist()
    local fenced = self.busy == true or self.blocked == true
    local dirty = self.dirty == true
    local statusText
    if self.blocked == true then
        statusText = tostring(self.blockReason or "编辑会话已阻断")
    elseif self.busy == true then
        statusText = "处理中"
    elseif dirty then
        statusText = persistAllowed == true and "有未应用修改" or "有未应用修改 · 当前不可保存"
    elseif self.baselineMatchesPersisted ~= true then
        statusText = "会话已同步 · 持久化基线不同"
    else
        statusText = "已同步"
    end
    return {
        contractVersion = tonumber(RSUI.LayoutEditSessionContractVersion) or 0,
        persistenceBoundaryVersion = tonumber(RSUI.LayoutEditSessionPersistenceBoundaryContractVersion) or 0,
        revision = tonumber(self.revision) or 0,
        busy = self.busy == true,
        blocked = self.blocked == true,
        blockReason = self.blockReason,
        dirty = dirty,
        sessionChanged = self.sessionChanged == true,
        canRevert = fenced ~= true and self.sessionChanged == true,
        canReset = fenced ~= true and self.workingAtDefaults ~= true,
        canApply = fenced ~= true and dirty and persistAllowed == true,
        persistAvailable = persistAllowed == true,
        persistReason = persistReason,
        baselineMatchesPersisted = self.baselineMatchesPersisted == true,
        workingAtDefaults = self.workingAtDefaults == true,
        lastCommand = self.lastCommand,
        lastSource = self.lastSource,
        lastError = self.lastError,
        statusText = statusText,
    }
end

function Model:GetStateSnapshot()
    local persisted = CopySnapshot(self.persistedSnapshot, self.maxSnapshotNodes)
    local baseline = CopySnapshot(self.baselineSnapshot, self.maxSnapshotNodes)
    local working = CopySnapshot(self.workingSnapshot, self.maxSnapshotNodes)
    local defaults = CopySnapshot(self.defaultSnapshot, self.maxSnapshotNodes)
    return {
        command = self:GetCommandSnapshot(),
        persisted = persisted,
        baseline = baseline,
        working = working,
        defaults = defaults,
    }
end

function Model:_ReadWorking()
    return SafeRead("working", self.getWorkingSnapshot, self, self.maxSnapshotNodes)
end

function Model:_RefreshWorkingInternal(source, notify)
    local current, err = self:_ReadWorking()
    if current == nil then return false, err end
    local changed = StateEqual(current, self.workingSnapshot, 0) ~= true
    self.workingSnapshot = current
    self:_RecomputeFlags()
    self.lastSource = tostring(source or "working_refresh")
    self.lastError = nil
    if changed then
        self.revision = (tonumber(self.revision) or 0) + 1
        RSUI.metrics.layoutEditSessionRefreshes = (tonumber(RSUI.metrics.layoutEditSessionRefreshes) or 0) + 1
        if notify == true then self:_Changed("working", { source = self.lastSource }) end
    end
    return true, changed
end

function Model:RefreshWorking(source)
    if self.busy == true then return self:_Reject("layout_edit_session_busy") end
    if self.blocked == true then return self:_Reject(self.blockReason or "layout_edit_session_blocked") end
    return self:_RefreshWorkingInternal(source or "external_working", true)
end

function Model:_SetBusy(value, source)
    self.busy = value == true
    self.revision = (tonumber(self.revision) or 0) + 1
    self.lastSource = tostring(source or (self.busy and "busy_begin" or "busy_end"))
    self:_Changed(self.busy and "busy_begin" or "busy_end", { source = self.lastSource })
end

function Model:_Block(reason)
    self.blocked = true
    self.blockReason = tostring(reason or "layout_edit_session_integrity_blocked")
    self.busy = false
    self.revision = (tonumber(self.revision) or 0) + 1
    self.lastError = self.blockReason
    RSUI.metrics.layoutEditSessionBlocks = (tonumber(RSUI.metrics.layoutEditSessionBlocks) or 0) + 1
    self:_Changed("blocked", { reason = self.blockReason })
    return false, self.blockReason
end

function Model:_HistoryBusy()
    if self.historyModel == nil then return false, nil end
    local ok, snapshot = xpcall(function() return self.historyModel:GetSnapshot() end, S.SafeTraceback)
    if ok ~= true or type(snapshot) ~= "table" then return true, "layout_edit_session_history_snapshot_failed" end
    if snapshot.busy == true then return true, "layout_edit_session_history_busy" end
    return false, nil
end

function Model:_ClearHistory(source)
    if self.historyModel == nil then return true, nil end
    local ok, accepted, detail = xpcall(function()
        return self.historyModel:Clear("session_barrier:" .. tostring(source or "command"))
    end, S.SafeTraceback)
    if ok ~= true then return false, "layout_edit_session_history_clear_failed:" .. tostring(accepted) end
    if accepted ~= true then return false, tostring(detail or "layout_edit_session_history_clear_rejected") end
    return true, detail
end

function Model:_RollbackWorking(snapshot, command, primaryError)
    RSUI.metrics.layoutEditSessionRollbackAttempts = (tonumber(RSUI.metrics.layoutEditSessionRollbackAttempts) or 0) + 1
    local applied, applyErr = SafeApply("rollback", self.applyWorkingSnapshot, snapshot, {
        command = tostring(command or "rollback"),
        source = "layout_edit_session_rollback",
        rollback = true,
        persist = false,
        primaryError = tostring(primaryError or "command_failed"),
    }, self, self.maxSnapshotNodes)
    local current, readErr = self:_ReadWorking()
    if current ~= nil then
        self.workingSnapshot = current
        self:_RecomputeFlags()
    end
    if applied ~= true or current == nil or StateEqual(current, snapshot, 0) ~= true then
        RSUI.metrics.layoutEditSessionRollbackFailures = (tonumber(RSUI.metrics.layoutEditSessionRollbackFailures) or 0) + 1
        return false, tostring(applyErr or readErr or "layout_edit_session_rollback_verification_failed")
    end
    return true, nil
end

function Model:_ApplyWorkingTarget(target, command, context)
    local previous, copyErr = CopySnapshot(self.workingSnapshot, self.maxSnapshotNodes)
    if previous == nil then return false, copyErr end
    local applied, applyErr = SafeApply(command, self.applyWorkingSnapshot, target, {
        command = command,
        source = tostring(context and context.source or "layout_edit_session"),
        rollback = false,
        persist = false,
    }, self, self.maxSnapshotNodes)
    if applied ~= true then
        local _, rollbackErr = self:_RollbackWorking(previous, command, applyErr)
        if rollbackErr ~= nil then return self:_Block(tostring(applyErr) .. "|rollback=" .. tostring(rollbackErr)) end
        return false, applyErr
    end

    local current, readErr = self:_ReadWorking()
    if current == nil or StateEqual(current, target, 0) ~= true then
        local primary = tostring(readErr or "layout_edit_session_apply_readback_mismatch")
        local _, rollbackErr = self:_RollbackWorking(previous, command, primary)
        if rollbackErr ~= nil then return self:_Block(primary .. "|rollback=" .. tostring(rollbackErr)) end
        return false, primary
    end
    self.workingSnapshot = current
    self:_RecomputeFlags()
    return true, nil, previous
end

function Model:_FinishCommand(command, detail)
    self.busy = false
    self.lastCommand = tostring(command or "")
    self.lastSource = "command:" .. self.lastCommand
    self.lastError = nil
    self.revision = (tonumber(self.revision) or 0) + 1
    self:_RecomputeFlags()
    RSUI.metrics.layoutEditSessionCommands = (tonumber(RSUI.metrics.layoutEditSessionCommands) or 0) + 1
    self:_Changed("command:" .. self.lastCommand, detail)
    return true, detail
end

function Model:_FailCommand(command, reason)
    self.busy = false
    self.lastCommand = tostring(command or "")
    self.lastSource = "command_failed:" .. self.lastCommand
    self.lastError = tostring(reason or "layout_edit_session_command_failed")
    self.revision = (tonumber(self.revision) or 0) + 1
    self:_RecomputeFlags()
    RSUI.metrics.layoutEditSessionRejects = (tonumber(RSUI.metrics.layoutEditSessionRejects) or 0) + 1
    self:_Changed("command_failed:" .. self.lastCommand, { error = self.lastError })
    return false, self.lastError
end

function Model:ExecuteCommand(command, context)
    command = tostring(command or "")
    if command ~= "revert" and command ~= "reset" and command ~= "apply" then
        return self:_Reject("layout_edit_session_command_invalid:" .. command)
    end
    if self.busy == true then return self:_Reject("layout_edit_session_busy") end
    if self.blocked == true then return self:_Reject(self.blockReason or "layout_edit_session_blocked") end

    local historyBusy, historyErr = self:_HistoryBusy()
    if historyBusy == true then return self:_Reject(historyErr) end
    local refreshed, refreshErr = self:_RefreshWorkingInternal("pre_command:" .. command, true)
    if refreshed ~= true then return self:_Reject(refreshErr) end

    local projected = self:GetCommandSnapshot()
    local allowed = (command == "revert" and projected.canRevert)
        or (command == "reset" and projected.canReset)
        or (command == "apply" and projected.canApply)
    if allowed ~= true then return self:_Reject("layout_edit_session_command_unavailable:" .. command) end

    self:_SetBusy(true, "command_begin:" .. command)

    if command == "revert" or command == "reset" then
        local target = command == "revert" and self.baselineSnapshot or self.defaultSnapshot
        local applied, applyErr, previous = self:_ApplyWorkingTarget(target, command, context)
        if applied ~= true then
            if self.blocked == true then return false, self.blockReason end
            return self:_FailCommand(command, applyErr)
        end
        local historyOk, historyClearErr = self:_ClearHistory(command)
        if historyOk ~= true then
            local rollbackOk, rollbackErr = self:_RollbackWorking(previous, command, historyClearErr)
            if rollbackOk ~= true then
                return self:_Block(tostring(historyClearErr or "layout_edit_session_history_barrier_failed")
                    .. "|rollback=" .. tostring(rollbackErr or "failed"))
            end
            return self:_FailCommand(command, historyClearErr)
        end
        if command == "revert" then
            RSUI.metrics.layoutEditSessionReverts = (tonumber(RSUI.metrics.layoutEditSessionReverts) or 0) + 1
        else
            RSUI.metrics.layoutEditSessionResets = (tonumber(RSUI.metrics.layoutEditSessionResets) or 0) + 1
        end
        return self:_FinishCommand(command, { persisted = false, historyBarrier = true })
    end

    local persistAllowed, persistReason = self:_CanPersist()
    if persistAllowed ~= true then return self:_FailCommand(command, persistReason) end
    local working, copyErr = CopySnapshot(self.workingSnapshot, self.maxSnapshotNodes)
    if working == nil then return self:_FailCommand(command, copyErr) end
    local persisted, persistErr = SafeApply("persist", self.persistSnapshot, working, {
        command = "apply",
        source = tostring(context and context.source or "layout_edit_session"),
        rollback = false,
        persist = true,
        durable = true,
    }, self, self.maxSnapshotNodes)
    if persisted ~= true then
        RSUI.metrics.layoutEditSessionApplyFailures = (tonumber(RSUI.metrics.layoutEditSessionApplyFailures) or 0) + 1
        return self:_FailCommand(command, persistErr)
    end

    self.persistedSnapshot = CopySnapshot(working, self.maxSnapshotNodes)
    self.baselineSnapshot = CopySnapshot(working, self.maxSnapshotNodes)
    self.workingSnapshot = CopySnapshot(working, self.maxSnapshotNodes)
    self:_RecomputeFlags()

    local historyOk, historyClearErr = self:_ClearHistory(command)
    if historyOk ~= true then
        -- Durable persistence already succeeded. Never lie by rolling the
        -- baseline backwards. Fail closed instead so stale History cannot cross
        -- the new durable boundary; Rebase() is the explicit recovery path.
        return self:_Block(tostring(historyClearErr or "layout_edit_session_history_barrier_failed")
            .. "|command=apply|persisted=true")
    end
    RSUI.metrics.layoutEditSessionApplies = (tonumber(RSUI.metrics.layoutEditSessionApplies) or 0) + 1
    return self:_FinishCommand(command, { persisted = true, historyBarrier = true })
end

function Model:Rebase(source)
    if self.busy == true then return self:_Reject("layout_edit_session_busy") end
    local working, workingErr = SafeRead("working", self.getWorkingSnapshot, self, self.maxSnapshotNodes)
    if working == nil then return self:_Reject(workingErr) end
    local persisted, persistedErr = SafeRead("persisted", self.getPersistedSnapshot, self, self.maxSnapshotNodes)
    if persisted == nil then return self:_Reject(persistedErr) end
    local defaults, defaultsErr = SafeRead("defaults", self.getDefaultSnapshot, self, self.maxSnapshotNodes)
    if defaults == nil then return self:_Reject(defaultsErr) end

    self:_SetBusy(true, "rebase_begin")
    local historyOk, historyErr = self:_ClearHistory("rebase")
    if historyOk ~= true then return self:_Block(historyErr) end
    self.workingSnapshot = working
    self.baselineSnapshot = CopySnapshot(working, self.maxSnapshotNodes)
    self.persistedSnapshot = persisted
    self.defaultSnapshot = defaults
    self.blocked, self.blockReason = false, nil
    self.busy = false
    self.lastCommand = "rebase"
    self.lastSource = tostring(source or "rebase")
    self.lastError = nil
    self.revision = (tonumber(self.revision) or 0) + 1
    self:_RecomputeFlags()
    self:_Changed("rebase", { source = self.lastSource })
    return true, nil
end

function Model:Release()
    if self.released == true then return false end
    if self.historyModel ~= nil and type(self.historyModel.Unsubscribe) == "function" then
        pcall(function() self.historyModel:Unsubscribe(self.historyToken) end)
    end
    self.released = true
    self.listeners = {}
    self.historyModel = nil
    self.getWorkingSnapshot = nil
    self.getPersistedSnapshot = nil
    self.getDefaultSnapshot = nil
    self.applyWorkingSnapshot = nil
    self.persistSnapshot = nil
    self.canPersist = nil
    return true
end

function RSUI:CreateLayoutEditSessionModel(options)
    options = type(options) == "table" and options or {}
    if type(options.getWorkingSnapshot) ~= "function" then return nil, "layout_edit_session_get_working_required" end
    if type(options.getPersistedSnapshot) ~= "function" then return nil, "layout_edit_session_get_persisted_required" end
    if type(options.getDefaultSnapshot) ~= "function" then return nil, "layout_edit_session_get_defaults_required" end
    if type(options.applyWorkingSnapshot) ~= "function" then return nil, "layout_edit_session_apply_working_required" end
    if type(options.persistSnapshot) ~= "function" then return nil, "layout_edit_session_persist_required" end
    if options.canPersist ~= nil and type(options.canPersist) ~= "function" then return nil, "layout_edit_session_can_persist_invalid" end
    if HistoryValid(options.historyModel) ~= true then return nil, "layout_edit_session_history_invalid" end

    local maxNodes = math.floor(math.max(64, math.min(N(options.maxSnapshotNodes, DEFAULT_MAX_SNAPSHOT_NODES), HARD_MAX_SNAPSHOT_NODES)))
    local model = setmetatable({
        id = tostring(options.id or "layout_edit_session"),
        maxSnapshotNodes = maxNodes,
        getWorkingSnapshot = options.getWorkingSnapshot,
        getPersistedSnapshot = options.getPersistedSnapshot,
        getDefaultSnapshot = options.getDefaultSnapshot,
        applyWorkingSnapshot = options.applyWorkingSnapshot,
        persistSnapshot = options.persistSnapshot,
        canPersist = options.canPersist,
        historyModel = options.historyModel,
        historyToken = tostring(options.id or "layout_edit_session") .. ":history",
        listeners = {},
        revision = 0,
        busy = false,
        blocked = false,
        blockReason = nil,
        lastCommand = "create",
        lastSource = "create",
        lastError = nil,
        released = false,
    }, Model)

    local working, workingErr = SafeRead("working", model.getWorkingSnapshot, model, maxNodes)
    if working == nil then return nil, workingErr end
    local persisted, persistedErr = SafeRead("persisted", model.getPersistedSnapshot, model, maxNodes)
    if persisted == nil then return nil, persistedErr end
    local defaults, defaultsErr = SafeRead("defaults", model.getDefaultSnapshot, model, maxNodes)
    if defaults == nil then return nil, defaultsErr end

    model.workingSnapshot = working
    model.baselineSnapshot = CopySnapshot(working, maxNodes)
    model.persistedSnapshot = persisted
    model.defaultSnapshot = defaults
    model:_RecomputeFlags()

    if model.historyModel ~= nil then
        local subscribed = model.historyModel:Subscribe(model.historyToken, function(_, reason)
            if model.released == true or model.busy == true or model.blocked == true then return end
            model:_RefreshWorkingInternal("history:" .. tostring(reason or "changed"), true)
        end)
        if subscribed ~= true then return nil, "layout_edit_session_history_subscribe_failed" end
    end

    RSUI.metrics.layoutEditSessionModelsCreated = (tonumber(RSUI.metrics.layoutEditSessionModelsCreated) or 0) + 1
    return model, nil
end

RSUI.LayoutEditSessionModel = Model

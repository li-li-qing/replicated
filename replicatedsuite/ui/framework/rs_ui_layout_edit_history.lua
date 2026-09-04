------------------------------------------------------------------------
-- Replicated Suite - RSUI Layout Edit History Model v1
--
-- Shared reversible-command authority for Layout Editor commits.
--
-- Contract:
--   * only successful editor COMMITs are recorded; preview / drag pulses are
--     never history entries;
--   * every command is stable-key based and before/after key sets must match;
--   * history is bounded (default 64, hard cap 256) and drops the oldest entry;
--   * Undo/Redo moves the cursor only after the external apply transaction
--     succeeds; rejected/failed apply performs a best-effort rollback and leaves
--     history state unchanged;
--   * the model owns no Feature Store and no Native UI. Caller supplies apply /
--     rollback callbacks at the projection/persistence boundary;
--   * optional state snapshots exist for non-Rect editor state such as
--     Anchor/Pivot. They are bounded deep copies, never live table references.
--
-- Performance:
--   no Tick / polling. O(selected) work happens only on Record/Undo/Redo.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI = S.RSUI
if type(RSUI) ~= "table" then return end

RSUI.LayoutEditHistoryContractVersion = 1
RSUI.LayoutEditHistoryObservableContractVersion = 1

local DEFAULT_MAX_COMMANDS = 64
local HARD_MAX_COMMANDS = 256
local DEFAULT_MAX_ITEMS = 128
local HARD_MAX_ITEMS = 512
local MAX_STATE_DEPTH = 6
local MAX_STATE_NODES = 256

local function N(value, fallback)
    local result = tonumber(value)
    if result == nil then result = tonumber(fallback) or 0 end
    return result
end

local function CopyRect(rect)
    if type(rect) ~= "table" then return nil end
    local x, y = tonumber(rect.x), tonumber(rect.y)
    local width, height = tonumber(rect.width or rect.w), tonumber(rect.height or rect.h)
    if x == nil or y == nil or width == nil or height == nil or width <= 0 or height <= 0 then return nil end
    return { x = x, y = y, width = width, height = height }
end

local function NormalizeItems(items, maxItems)
    if type(items) ~= "table" then return nil, nil, "layout_edit_history_items_required" end
    local count = #items
    if count < 1 then return nil, nil, "layout_edit_history_items_empty" end
    if count > maxItems then return nil, nil, "layout_edit_history_item_limit_exceeded:" .. tostring(count) end

    local out, seen, keys = {}, {}, {}
    for index, item in ipairs(items) do
        if type(item) ~= "table" then return nil, nil, "layout_edit_history_item_invalid:" .. tostring(index) end
        local key = item.key ~= nil and tostring(item.key) or ""
        if key == "" then return nil, nil, "layout_edit_history_key_required:" .. tostring(index) end
        if seen[key] then return nil, nil, "layout_edit_history_duplicate_key:" .. key end
        local rect = CopyRect(item.rect or item)
        if rect == nil then return nil, nil, "layout_edit_history_rect_invalid:" .. key end
        seen[key] = true
        keys[#keys + 1] = key
        out[#out + 1] = { key = key, rect = rect }
    end

    table.sort(keys)
    local signatureParts = {}
    for index, key in ipairs(keys) do
        signatureParts[index] = tostring(#key) .. ":" .. key
    end
    return out, table.concat(signatureParts, "|"), nil
end

local function CopyStateValue(value, depth, budget)
    local valueType = type(value)
    if value == nil or valueType == "boolean" or valueType == "string" or valueType == "number" then
        return value, nil
    end
    if valueType ~= "table" then return nil, "layout_edit_history_state_type_unsupported:" .. valueType end
    if depth >= MAX_STATE_DEPTH then return nil, "layout_edit_history_state_depth_exceeded" end

    budget.nodes = budget.nodes + 1
    if budget.nodes > MAX_STATE_NODES then return nil, "layout_edit_history_state_node_limit_exceeded" end

    local out = {}
    for key, child in pairs(value) do
        local keyType = type(key)
        if keyType ~= "string" and keyType ~= "number" then
            return nil, "layout_edit_history_state_key_type_unsupported:" .. keyType
        end
        local copied, err = CopyStateValue(child, depth + 1, budget)
        if err ~= nil then return nil, err end
        out[key] = copied
    end
    return out, nil
end

local function CopyState(state)
    if state == nil then return nil, nil end
    return CopyStateValue(state, 0, { nodes = 0 })
end

local function CopyItems(items)
    local out = {}
    for index, item in ipairs(type(items) == "table" and items or {}) do
        local rect = CopyRect(item.rect)
        if rect == nil then return nil, "layout_edit_history_copy_rect_invalid:" .. tostring(index) end
        out[index] = { key = tostring(item.key or ""), rect = rect }
    end
    return out, nil
end

local function SameNumber(a, b)
    return math.abs(N(a, 0) - N(b, 0)) < 0.0001
end

local function RectEqual(a, b)
    return type(a) == "table" and type(b) == "table"
        and SameNumber(a.x, b.x) and SameNumber(a.y, b.y)
        and SameNumber(a.width, b.width) and SameNumber(a.height, b.height)
end

local function StateEqual(a, b, depth)
    if a == b then return true end
    local typeA, typeB = type(a), type(b)
    if typeA ~= typeB then return false end
    if typeA == "number" then return SameNumber(a, b) end
    if typeA ~= "table" then return a == b end
    if (depth or 0) >= MAX_STATE_DEPTH then return false end
    for key, value in pairs(a) do
        if not StateEqual(value, b[key], (depth or 0) + 1) then return false end
    end
    for key, _ in pairs(b) do
        if a[key] == nil then return false end
    end
    return true
end

local function ItemsEqual(beforeItems, afterItems)
    if #beforeItems ~= #afterItems then return false end
    local afterByKey = {}
    for _, item in ipairs(afterItems) do afterByKey[item.key] = item end
    for _, before in ipairs(beforeItems) do
        local after = afterByKey[before.key]
        if after == nil or RectEqual(before.rect, after.rect) ~= true then return false end
    end
    return true
end

local function SafeCall(label, callback, ...)
    if type(callback) ~= "function" then return false, "layout_edit_history_" .. tostring(label) .. "_callback_required" end
    local args, count = { ... }, select("#", ...)
    local ok, resultA, resultB = xpcall(function()
        return callback(unpack(args, 1, count))
    end, S.SafeTraceback)
    if ok ~= true then return false, "layout_edit_history_" .. tostring(label) .. "_callback_failed:" .. tostring(resultA) end
    if resultA == false then return false, tostring(resultB or ("layout_edit_history_" .. tostring(label) .. "_rejected")) end
    return true, resultB
end

local function CommandSummary(command)
    if type(command) ~= "table" then return nil end
    return {
        id = command.id,
        source = command.source,
        count = #(command.afterItems or {}),
        keySignature = command.keySignature,
        selectionRevision = command.selectionRevision,
    }
end

local Model = {}
Model.__index = Model

function Model:_Reject(reason)
    self.lastError = tostring(reason or "layout_edit_history_rejected")
    RSUI.metrics.layoutEditHistoryRejects = (tonumber(RSUI.metrics.layoutEditHistoryRejects) or 0) + 1
    return false, self.lastError
end

function Model:SetApplyCallbacks(applyCallback, rollbackCallback)
    if applyCallback ~= nil and type(applyCallback) ~= "function" then return self:_Reject("layout_edit_history_apply_callback_invalid") end
    if rollbackCallback ~= nil and type(rollbackCallback) ~= "function" then return self:_Reject("layout_edit_history_rollback_callback_invalid") end
    self.applyCallback = applyCallback
    self.rollbackCallback = rollbackCallback
    self.lastError = nil
    return true, nil
end

function Model:CanUndo()
    return self.busy ~= true and (tonumber(self.cursor) or 0) > 0
end

function Model:CanRedo()
    return self.busy ~= true and (tonumber(self.cursor) or 0) < #(self.commands or {})
end

function Model:GetUndoCommand()
    return CommandSummary(self.commands[self.cursor])
end

function Model:GetRedoCommand()
    return CommandSummary(self.commands[(tonumber(self.cursor) or 0) + 1])
end

function Model:_Changed(reason, detail)
    local snapshot = self:GetSnapshot()
    for token, listener in pairs(self.listeners or {}) do
        if type(listener) == "function" then
            RSUI:Callback("rsui:layout_edit_history:" .. tostring(self.id) .. ":listener:" .. tostring(token),
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

function Model:GetSnapshot()
    return {
        id = self.id,
        contractVersion = tonumber(RSUI.LayoutEditHistoryContractVersion) or 0,
        revision = tonumber(self.revision) or 0,
        count = #(self.commands or {}),
        cursor = tonumber(self.cursor) or 0,
        maxCommands = self.maxCommands,
        maxItems = self.maxItems,
        canUndo = self:CanUndo(),
        canRedo = self:CanRedo(),
        busy = self.busy == true,
        undo = self:GetUndoCommand(),
        redo = self:GetRedoCommand(),
        trims = tonumber(self.trims) or 0,
        lastSource = self.lastSource,
        lastError = self.lastError,
    }
end

function Model:Clear(source)
    if self.busy == true then return self:_Reject("layout_edit_history_busy") end
    self.commands = {}
    self.cursor = 0
    self.revision = (tonumber(self.revision) or 0) + 1
    self.lastSource = tostring(source or "clear")
    self.lastError = nil
    self:_Changed("clear", { source = self.lastSource })
    return true, nil
end

function Model:Record(change)
    if self.busy == true then return self:_Reject("layout_edit_history_busy") end
    if type(change) ~= "table" then return self:_Reject("layout_edit_history_change_required") end

    local beforeItems, beforeSignature, beforeErr = NormalizeItems(change.beforeItems, self.maxItems)
    if beforeItems == nil then return self:_Reject(beforeErr) end
    local afterItems, afterSignature, afterErr = NormalizeItems(change.afterItems, self.maxItems)
    if afterItems == nil then return self:_Reject(afterErr) end
    if beforeSignature ~= afterSignature then return self:_Reject("layout_edit_history_key_set_changed") end

    local beforeState, stateErr = CopyState(change.beforeState)
    if stateErr ~= nil then return self:_Reject(stateErr) end
    local afterState
    afterState, stateErr = CopyState(change.afterState)
    if stateErr ~= nil then return self:_Reject(stateErr) end

    if ItemsEqual(beforeItems, afterItems) and StateEqual(beforeState, afterState, 0) then
        self.lastError = nil
        return false, "layout_edit_history_noop"
    end

    while #self.commands > self.cursor do self.commands[#self.commands] = nil end

    self.nextCommandId = (tonumber(self.nextCommandId) or 0) + 1
    self.commands[#self.commands + 1] = {
        id = self.nextCommandId,
        source = tostring(change.source or "commit"),
        selectionRevision = tonumber(change.selectionRevision) or 0,
        keySignature = beforeSignature,
        beforeItems = beforeItems,
        afterItems = afterItems,
        beforeState = beforeState,
        afterState = afterState,
    }

    if #self.commands > self.maxCommands then
        table.remove(self.commands, 1)
        self.trims = (tonumber(self.trims) or 0) + 1
        RSUI.metrics.layoutEditHistoryTrims = (tonumber(RSUI.metrics.layoutEditHistoryTrims) or 0) + 1
    end

    self.cursor = #self.commands
    self.revision = (tonumber(self.revision) or 0) + 1
    self.lastSource = tostring(change.source or "commit")
    self.lastError = nil
    RSUI.metrics.layoutEditHistoryRecords = (tonumber(RSUI.metrics.layoutEditHistoryRecords) or 0) + 1
    local summary = CommandSummary(self.commands[self.cursor])
    self:_Changed("record", summary)
    return true, summary
end

function Model:_Rollback(command, state, items, direction, primaryError)
    local callback = self.rollbackCallback or self.applyCallback
    if type(callback) ~= "function" then return false, "layout_edit_history_rollback_callback_required" end
    RSUI.metrics.layoutEditHistoryRollbackAttempts = (tonumber(RSUI.metrics.layoutEditHistoryRollbackAttempts) or 0) + 1
    local copiedItems = CopyItems(items)
    local copiedState = CopyState(state)
    local ok, err = SafeCall("rollback", callback, copiedItems or {}, {
        direction = direction,
        rollback = true,
        historyReplay = true,
        command = CommandSummary(command),
        state = copiedState,
        primaryError = tostring(primaryError or "apply_failed"),
    }, self)
    if ok ~= true then
        RSUI.metrics.layoutEditHistoryRollbackFailures = (tonumber(RSUI.metrics.layoutEditHistoryRollbackFailures) or 0) + 1
        return false, err
    end
    return true, nil
end

function Model:_ApplyCommand(command, direction)
    if self.busy == true then return self:_Reject("layout_edit_history_busy") end
    if type(command) ~= "table" then return self:_Reject("layout_edit_history_command_missing") end
    if type(self.applyCallback) ~= "function" then return self:_Reject("layout_edit_history_apply_callback_required") end

    local undo = direction == "undo"
    local targetItems = undo and command.beforeItems or command.afterItems
    local rollbackItems = undo and command.afterItems or command.beforeItems
    local targetState = undo and command.beforeState or command.afterState
    local rollbackState = undo and command.afterState or command.beforeState
    local copiedItems, copyErr = CopyItems(targetItems)
    if copiedItems == nil then return self:_Reject(copyErr) end
    local copiedState, stateErr = CopyState(targetState)
    if stateErr ~= nil then return self:_Reject(stateErr) end

    self.busy = true
    RSUI.metrics.layoutEditHistoryReplays = (tonumber(RSUI.metrics.layoutEditHistoryReplays) or 0) + 1
    local applied, applyErr = SafeCall("apply", self.applyCallback, copiedItems, {
        direction = direction,
        rollback = false,
        historyReplay = true,
        command = CommandSummary(command),
        state = copiedState,
    }, self)

    if applied ~= true then
        local _, rollbackErr = self:_Rollback(command, rollbackState, rollbackItems, direction, applyErr)
        self.busy = false
        local combined = tostring(applyErr or "layout_edit_history_apply_failed")
        if rollbackErr ~= nil then combined = combined .. "|rollback=" .. tostring(rollbackErr) end
        return self:_Reject(combined)
    end

    if undo then self.cursor = self.cursor - 1 else self.cursor = self.cursor + 1 end
    self.busy = false
    self.revision = (tonumber(self.revision) or 0) + 1
    self.lastSource = direction
    self.lastError = nil
    if undo then
        RSUI.metrics.layoutEditHistoryUndos = (tonumber(RSUI.metrics.layoutEditHistoryUndos) or 0) + 1
    else
        RSUI.metrics.layoutEditHistoryRedos = (tonumber(RSUI.metrics.layoutEditHistoryRedos) or 0) + 1
    end
    local summary = CommandSummary(command)
    self:_Changed(direction, summary)
    return true, summary
end

function Model:Undo()
    if not self:CanUndo() then return self:_Reject("layout_edit_history_undo_unavailable") end
    return self:_ApplyCommand(self.commands[self.cursor], "undo")
end

function Model:Redo()
    if not self:CanRedo() then return self:_Reject("layout_edit_history_redo_unavailable") end
    return self:_ApplyCommand(self.commands[self.cursor + 1], "redo")
end

function Model:Release()
    if self.busy == true then return false, "layout_edit_history_busy" end
    self.commands = {}
    self.cursor = 0
    self.applyCallback = nil
    self.rollbackCallback = nil
    self.listeners = {}
    return true, nil
end

function RSUI:CreateLayoutEditHistoryModel(options)
    options = type(options) == "table" and options or {}
    local maxCommands = math.floor(math.max(1, math.min(N(options.maxCommands, DEFAULT_MAX_COMMANDS), HARD_MAX_COMMANDS)))
    local maxItems = math.floor(math.max(1, math.min(N(options.maxItems, DEFAULT_MAX_ITEMS), HARD_MAX_ITEMS)))
    local model = setmetatable({
        id = tostring(options.id or "layout_edit_history"),
        maxCommands = maxCommands,
        maxItems = maxItems,
        commands = {},
        cursor = 0,
        nextCommandId = 0,
        revision = 0,
        trims = 0,
        busy = false,
        applyCallback = nil,
        rollbackCallback = nil,
        listeners = {},
        lastSource = "create",
        lastError = nil,
    }, Model)
    local callbacksOk, callbackErr = model:SetApplyCallbacks(options.apply, options.rollback)
    if callbacksOk ~= true then return nil, callbackErr end
    RSUI.metrics.layoutEditHistoryModelsCreated = (tonumber(RSUI.metrics.layoutEditHistoryModelsCreated) or 0) + 1
    return model, nil
end

RSUI.LayoutEditHistoryModel = Model
RSUI.LayoutEditHistoryLimits = {
    defaultMaxCommands = DEFAULT_MAX_COMMANDS,
    hardMaxCommands = HARD_MAX_COMMANDS,
    defaultMaxItems = DEFAULT_MAX_ITEMS,
    hardMaxItems = HARD_MAX_ITEMS,
    maxStateDepth = MAX_STATE_DEPTH,
    maxStateNodes = MAX_STATE_NODES,
}

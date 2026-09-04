------------------------------------------------------------------------
-- Replicated Suite - RSUI Editor Command Bar v2
--
-- Shared command projection for layout-editor actions.
--
-- Authority boundary:
--   * Undo/Redo availability comes only from LayoutEditHistoryModel snapshots.
--   * Revert/Reset/Apply availability comes only from an optional Session
--     Authority snapshot. This component does not define those semantics and
--     never persists Feature state by itself.
--   * Authority changes are observed through Subscribe/Unsubscribe; there is no
--     Tick, OnUpdate or polling loop and pages never own canUndo/canRedo/dirty.
--
-- Session projection contract:
--   GetCommandSnapshot() -> {
--       revision, busy, blocked, dirty, canRevert, canReset, canApply, statusText
--   }
--   ExecuteCommand("revert"|"reset"|"apply", context)
--   Subscribe(token, listener) / Unsubscribe(token)
--
-- Revert/Reset/Apply semantics are owned by LayoutEditSessionModel. This bar
-- remains a projection/dispatch surface and never writes Feature state itself.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI = S.RSUI
local UI = S.UI
if type(RSUI) ~= "table" or type(UI) ~= "table" then return end

RSUI.EditorCommandBarContractVersion = 2
RSUI.EditorCommandSessionProjectionContractVersion = 2

local function N(value, fallback)
    local result = tonumber(value)
    if result == nil then result = tonumber(fallback) or 0 end
    return result
end

local function HistoryValid(model)
    return type(model) == "table"
        and type(model.GetSnapshot) == "function"
        and type(model.Undo) == "function" and type(model.Redo) == "function"
        and type(model.Subscribe) == "function" and type(model.Unsubscribe) == "function"
end

local function SessionValid(model)
    if model == nil then return true end
    return type(model) == "table"
        and type(model.GetCommandSnapshot) == "function"
        and type(model.ExecuteCommand) == "function"
        and type(model.Subscribe) == "function" and type(model.Unsubscribe) == "function"
end

local function SafeSnapshot(label, callback, owner)
    local ok, value = xpcall(function() return callback(owner) end, S.SafeTraceback)
    if ok ~= true or type(value) ~= "table" then
        return nil, "editor_command_bar_" .. tostring(label) .. "_snapshot_failed"
    end
    return value, nil
end

function RSUI.ProjectEditorCommandState(history, session)
    if type(history) ~= "table" then return nil, "editor_command_bar_history_snapshot_required" end
    if session ~= nil and type(session) ~= "table" then return nil, "editor_command_bar_session_snapshot_invalid" end
    local busy = history.busy == true or (session ~= nil and session.busy == true)
    local blocked = session ~= nil and session.blocked == true
    local fenced = busy or blocked
    return {
        historyRevision = tonumber(history.revision) or 0,
        sessionRevision = session ~= nil and (tonumber(session.revision) or 0) or 0,
        busy = busy,
        blocked = blocked,
        dirty = session ~= nil and session.dirty == true or false,
        sessionChanged = session ~= nil and session.sessionChanged == true or false,
        canUndo = fenced ~= true and history.canUndo == true,
        canRedo = fenced ~= true and history.canRedo == true,
        canRevert = fenced ~= true and session ~= nil and session.canRevert == true,
        canReset = fenced ~= true and session ~= nil and session.canReset == true,
        canApply = fenced ~= true and session ~= nil and session.canApply == true,
        historyCount = tonumber(history.count) or 0,
        historyCursor = tonumber(history.cursor) or 0,
        statusText = session ~= nil and tostring(session.statusText or (session.dirty == true and "有未应用修改" or "已同步")) or "会话未接入",
    }, nil
end

local function Notify(c, command, accepted, detail)
    if type(c.onCommand) ~= "function" then return true end
    RSUI:Callback("rsui:editor_command_bar:" .. tostring(c.id) .. ":command", c.onCommand,
        tostring(command or ""), accepted == true, detail, c:GetSnapshot(), c)
    return true
end

RSUI:RegisterTypeValidator("EditorCommandBar", function(spec)
    if HistoryValid(spec.historyModel) ~= true then return false, "editor_command_bar_history_model_required" end
    if SessionValid(spec.sessionModel) ~= true then return false, "editor_command_bar_session_model_invalid" end
    return true
end)

RSUI:RegisterType("EditorCommandBar", function(spec)
    if HistoryValid(spec.historyModel) ~= true then return nil, "editor_command_bar_history_model_required" end
    if SessionValid(spec.sessionModel) ~= true then return nil, "editor_command_bar_session_model_invalid" end

    local width = math.max(260, N(spec.width, 440))
    local height = math.max(22, N(spec.height, 28))
    local root = UI:CreateEmptyWidget(spec.parent, spec.id, N(spec.x, 0), N(spec.y, 0), width, height, false)
    if root == nil then return nil, "editor_command_bar_create_failed" end

    local c = RSUI:NewComponent("EditorCommandBar", spec, root)
    local BaseSetEnabled = c.SetEnabled
    c.historyModel = spec.historyModel
    c.sessionModel = spec.sessionModel
    c.onCommand = spec.onCommand
    c.historyToken = tostring(spec.id) .. ":history"
    c.sessionToken = tostring(spec.id) .. ":session"
    c.revision = 0
    c.lastSource = "create"
    c.lastError = nil
    c.projected = nil

    local row = RSUI:HorizontalBox({
        id = spec.id .. "_row", parent = c,
        gap = N(spec.gap, 4),
        slot = { hAlign = "fill", vAlign = "fill" },
    })
    if row == nil then return nil, "editor_command_bar_row_failed" end
    c.row = row

    local buttonWidth = math.max(42, N(spec.buttonWidth, 52))
    local function Button(idSuffix, text, action)
        return RSUI:Button({
            id = spec.id .. "_" .. idSuffix, parent = row, text = text,
            compact = true, width = buttonWidth, height = height,
            slot = { size = "fixed", width = buttonWidth, vAlign = "center" },
            onClick = function() return c:Execute(action) end,
        })
    end

    c.undoButton = Button("undo", tostring(spec.undoText or "撤销"), "undo")
    c.redoButton = Button("redo", tostring(spec.redoText or "重做"), "redo")
    c.revertButton = Button("revert", tostring(spec.revertText or "还原"), "revert")
    c.resetButton = Button("reset", tostring(spec.resetText or "重置"), "reset")
    c.applyButton = Button("apply", tostring(spec.applyText or "应用"), "apply")
    c.statusChip = RSUI:StatusChip({
        id = spec.id .. "_status", parent = row, status = "muted", text = "会话未接入",
        minWidth = N(spec.statusMinWidth, 92), maxWidth = N(spec.statusMaxWidth, 220),
        slot = { size = "fill", fill = 1, hAlign = "right", vAlign = "center" },
    })
    if c.undoButton == nil or c.redoButton == nil or c.revertButton == nil
        or c.resetButton == nil or c.applyButton == nil or c.statusChip == nil then
        return nil, "editor_command_bar_children_failed"
    end

    function c:_Project(source)
        local history, historyErr = SafeSnapshot("history", self.historyModel.GetSnapshot, self.historyModel)
        if history == nil then
            self.lastError = historyErr
            return false, historyErr
        end

        local session = nil
        if self.sessionModel ~= nil then
            local sessionErr
            session, sessionErr = SafeSnapshot("session", self.sessionModel.GetCommandSnapshot, self.sessionModel)
            if session == nil then
                self.lastError = sessionErr
                return false, sessionErr
            end
        end

        local projected, projectErr = RSUI.ProjectEditorCommandState(history, session)
        if projected == nil then
            self.lastError = projectErr
            return false, projectErr
        end
        self.projected = projected
        self.revision = (tonumber(self.revision) or 0) + 1
        self.lastSource = tostring(source or "refresh")
        self.lastError = nil
        return true, projected
    end

    function c:_SetCommandEnabled(button, enabled, role)
        local childOk, childErr = self:EnsureChildEnabled(button, enabled, role)
        if childOk ~= true then
            self.lastError = childErr
            RSUI.metrics.editorCommandBarRejects = (tonumber(RSUI.metrics.editorCommandBarRejects) or 0) + 1
            return false, childErr
        end
        return true, nil
    end

    function c:Refresh(source)
        local ok, projected = self:_Project(source)
        if ok ~= true then
            local disabled = {
                { self.undoButton, "undo" }, { self.redoButton, "redo" },
                { self.revertButton, "revert" }, { self.resetButton, "reset" },
                { self.applyButton, "apply" },
            }
            for _, entry in ipairs(disabled) do
                local stateOk, stateErr = self:_SetCommandEnabled(entry[1], false, "command_" .. entry[2])
                if stateOk ~= true then return false, stateErr end
            end
            self.statusChip:SetStatus("error", "命令状态不可用")
            RSUI.metrics.editorCommandBarRejects = (tonumber(RSUI.metrics.editorCommandBarRejects) or 0) + 1
            return false, projected
        end
        local globallyEnabled = self.enabled ~= false
        if globallyEnabled ~= true then
            projected.canUndo, projected.canRedo = false, false
            projected.canRevert, projected.canReset, projected.canApply = false, false, false
        end
        local commandStates = {
            { self.undoButton, projected.canUndo, "undo" },
            { self.redoButton, projected.canRedo, "redo" },
            { self.revertButton, projected.canRevert, "revert" },
            { self.resetButton, projected.canReset, "reset" },
            { self.applyButton, projected.canApply, "apply" },
        }
        for _, entry in ipairs(commandStates) do
            local stateOk, stateErr = self:_SetCommandEnabled(entry[1], entry[2], "command_" .. entry[3])
            if stateOk ~= true then return false, stateErr end
        end
        if projected.blocked then
            self.statusChip:SetStatus("error", projected.statusText or "编辑会话已阻断")
        elseif projected.busy then
            self.statusChip:SetStatus("info", "处理中")
        elseif self.sessionModel == nil then
            self.statusChip:SetStatus("muted", projected.statusText)
        elseif projected.dirty then
            self.statusChip:SetStatus("warning", projected.statusText)
        else
            self.statusChip:SetStatus("success", projected.statusText)
        end
        RSUI.metrics.editorCommandBarRefreshes = (tonumber(RSUI.metrics.editorCommandBarRefreshes) or 0) + 1
        return true, projected
    end

    function c:Execute(command)
        command = tostring(command or "")
        local refreshOk, projected = self:Refresh("pre_execute:" .. command)
        if refreshOk ~= true then return false, projected end

        local allowed = (command == "undo" and projected.canUndo)
            or (command == "redo" and projected.canRedo)
            or (command == "revert" and projected.canRevert)
            or (command == "reset" and projected.canReset)
            or (command == "apply" and projected.canApply)
        if allowed ~= true then
            local reason = "editor_command_bar_command_unavailable:" .. command
            self.lastError = reason
            RSUI.metrics.editorCommandBarRejects = (tonumber(RSUI.metrics.editorCommandBarRejects) or 0) + 1
            Notify(self, command, false, reason)
            return false, reason
        end

        local ok, accepted, detail
        if command == "undo" or command == "redo" then
            local fn = command == "undo" and self.historyModel.Undo or self.historyModel.Redo
            ok, accepted, detail = xpcall(function() return fn(self.historyModel) end, S.SafeTraceback)
        else
            ok, accepted, detail = xpcall(function()
                return self.sessionModel:ExecuteCommand(command, { source = "editor_command_bar", commandBar = self })
            end, S.SafeTraceback)
        end
        if ok ~= true then
            accepted, detail = false, "editor_command_bar_command_failed:" .. tostring(accepted)
        elseif accepted ~= true then
            accepted = false
            detail = tostring(detail or ("editor_command_bar_command_rejected:" .. command))
        end

        self:Refresh("post_execute:" .. command)
        if accepted == true then
            self.lastError = nil
            RSUI.metrics.editorCommandBarActions = (tonumber(RSUI.metrics.editorCommandBarActions) or 0) + 1
        else
            self.lastError = tostring(detail or "editor_command_bar_command_failed")
            RSUI.metrics.editorCommandBarRejects = (tonumber(RSUI.metrics.editorCommandBarRejects) or 0) + 1
        end
        Notify(self, command, accepted, detail)
        return accepted, detail
    end

    function c:SetEnabled(enabled)
        local nextEnabled = enabled ~= false
        if type(BaseSetEnabled) ~= "function" then return self.enabled ~= false, false, "base_enabled_contract_missing" end
        local state, accepted, detail = BaseSetEnabled(self, nextEnabled)
        if accepted ~= true then return state, false, detail end
        if self.projected ~= nil then
            local refreshOk, refreshErr = self:Refresh("enabled_changed")
            if refreshOk ~= true then return state, false, refreshErr end
        end
        return self.enabled, true, nil
    end

    function c:GetSnapshot()
        local projected = self.projected or {}
        return {
            contractVersion = tonumber(RSUI.EditorCommandBarContractVersion) or 0,
            revision = tonumber(self.revision) or 0,
            lastSource = self.lastSource,
            lastError = self.lastError,
            sessionAttached = self.sessionModel ~= nil,
            busy = projected.busy == true,
            blocked = projected.blocked == true,
            dirty = projected.dirty == true,
            sessionChanged = projected.sessionChanged == true,
            canUndo = projected.canUndo == true,
            canRedo = projected.canRedo == true,
            canRevert = projected.canRevert == true,
            canReset = projected.canReset == true,
            canApply = projected.canApply == true,
            historyCount = tonumber(projected.historyCount) or 0,
            historyCursor = tonumber(projected.historyCursor) or 0,
            historyRevision = tonumber(projected.historyRevision) or 0,
            sessionRevision = tonumber(projected.sessionRevision) or 0,
            statusText = projected.statusText,
        }
    end

    function c:Measure(availableW, availableH)
        local desiredW, desiredH = self.row:Measure(availableW, availableH)
        self.desiredWidth = math.max(1, N(desiredW, width))
        self.desiredHeight = math.max(1, N(desiredH, height))
        self.measureDirty = false
        return self.desiredWidth, self.desiredHeight
    end

    function c:Layout(x, y, nextWidth, nextHeight)
        local w = math.max(1, N(nextWidth, self.width or width))
        local h = math.max(1, N(nextHeight, self.height or height))
        self:SetBounds(N(x, 0), N(y, 0), w, h)
        self.row:Layout(0, 0, w, h)
        return h
    end

    local BaseRelease = c.Release
    function c:Release()
        if self.released == true then return false end
        if self.historyModel ~= nil and type(self.historyModel.Unsubscribe) == "function" then
            pcall(function() self.historyModel:Unsubscribe(self.historyToken) end)
        end
        if self.sessionModel ~= nil and type(self.sessionModel.Unsubscribe) == "function" then
            pcall(function() self.sessionModel:Unsubscribe(self.sessionToken) end)
        end
        return BaseRelease(self)
    end

    local historySubscribed = c.historyModel:Subscribe(c.historyToken, function()
        if c.released ~= true then c:Refresh("history_changed") end
    end)
    if historySubscribed ~= true then c:Release(); return nil, "editor_command_bar_history_subscribe_failed" end
    if c.sessionModel ~= nil then
        local sessionSubscribed = c.sessionModel:Subscribe(c.sessionToken, function()
            if c.released ~= true then c:Refresh("session_changed") end
        end)
        if sessionSubscribed ~= true then c:Release(); return nil, "editor_command_bar_session_subscribe_failed" end
    end

    c:SetEnabled(spec.enabled ~= false)
    local refreshOk, refreshErr = c:Refresh("create")
    if refreshOk ~= true then c:Release(); return nil, refreshErr end
    RSUI.metrics.editorCommandBarsCreated = (tonumber(RSUI.metrics.editorCommandBarsCreated) or 0) + 1
    return c
end)

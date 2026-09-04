------------------------------------------------------------------------
-- Replicated Suite V3 - Modal Host v4
--
-- One application-level modal stack. It owns the full-shell scrim and topmost
-- modal visibility so feature pages never invent their own Z-order/blocking
-- rules. Keyboard Escape is deliberately NOT invented: the current RU client
-- contract has no validated generic key handler, so dismissal is explicit.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI = S.RSUI
if type(RSUI) ~= "table" then return end

S.UIV3 = S.UIV3 or {}
S.UIV3.ModalHost = {
    version = 6,
    buildTransactionContractVersion = 1,
    visibilityTransactionContractVersion = 1,
    stack = {},
    root = nil,
    scrim = nil,
    contentRoot = nil,
    keyboardDismissSupported = false,
    failedAttachGeneration = nil,
    failedAttachError = nil,
    stats = { pushes = 0, pops = 0, clears = 0, backdropDismissals = 0, attachFailures = 0, quarantinedRejects = 0, hostWakeups = 0, hostWakeFailures = 0 },
}
local M = S.UIV3.ModalHost

local function SetVisible(instance, visible)
    if instance == nil then return false, "modal_instance_required" end
    if type(instance.SetVisibility) == "function" then
        local ok, changed, accepted, detail = xpcall(function()
            return instance:SetVisibility(visible and "visible" or "collapsed")
        end, S.SafeTraceback)
        if ok ~= true then return false, tostring(changed or "modal_visibility_exception") end
        if accepted == false then return false, tostring(detail or "modal_visibility_rejected") end
        return true, nil
    end
    if type(instance.SetVisible) == "function" then
        local ok, changed, accepted, detail = xpcall(function()
            return instance:SetVisible(visible == true)
        end, S.SafeTraceback)
        if ok ~= true then return false, tostring(changed or "modal_visibility_exception") end
        if accepted == false then return false, tostring(detail or "modal_visibility_rejected") end
        return true, nil
    end
    local native = type(instance) == "table" and instance.root or instance
    if native ~= nil and S.UI ~= nil and type(S.UI.EnsureVisible) == "function" then
        local accepted, _, detail = S.UI:EnsureVisible(native, visible == true, "v3:modal_host")
        if accepted ~= true then return false, tostring(detail or "modal_native_visibility_rejected") end
        return true, nil
    end
    return false, "modal_visibility_contract_unavailable"
end

local function Raise(instance)
    local native = type(instance) == "table" and instance.root or instance
    if native ~= nil and type(native.Raise) == "function" then pcall(function() native:Raise() end) end
end

function M:Attach(root)
    if root == nil then return false end
    if self.root ~= nil and self.root ~= root then return false, "modal host already attached" end
    if tonumber(self.failedAttachGeneration) == tonumber(S.Generation) then
        self.stats.quarantinedRejects = (tonumber(self.stats.quarantinedRejects) or 0) + 1
        return false, tostring(self.failedAttachError or "modal host build quarantined")
    end
    self.root = root
    if self.scrim ~= nil and self.contentRoot ~= nil then
        local hidden, hideErr = SetVisible(root, false)
        if hidden ~= true then return false, hideErr end
        return true
    end

    local ok, _, detail = RSUI:WithBuildScope("modal_host", function()
        self.scrim = RSUI:Border({
            id = "v3_modal_scrim", parent = root, variant = "soft", pickable = true,
            padding = 0, slot = { hAlign = "fill", vAlign = "fill" },
        })
        self.contentRoot = RSUI:Overlay({
            id = "v3_modal_content", parent = root,
            slot = { hAlign = "fill", vAlign = "fill" },
        })
        if self.scrim == nil or self.contentRoot == nil then error("modal host component create failed") end
        if type(self.scrim.RequireOn) ~= "function" then error("modal scrim critical event contract unavailable") end
        local backdropBound, backdropErr = self.scrim:RequireOn(self.scrim.root, "OnClick", function()
            local top = M:GetTop()
            if top ~= nil and top.options.dismissOnBackdrop == true then
                M.stats.backdropDismissals = (tonumber(M.stats.backdropDismissals) or 0) + 1
                return M:Pop(top.id, "backdrop") ~= nil
            end
            return true
        end, "v3:modal_host:backdrop")
        if backdropBound ~= true then error(tostring(backdropErr or "modal backdrop bind failed")) end
        return true
    end)

    if ok ~= true then
        self.scrim, self.contentRoot = nil, nil
        self.failedAttachGeneration = S.Generation
        self.failedAttachError = tostring(detail or "modal host attach failed")
        self.stats.attachFailures = (tonumber(self.stats.attachFailures) or 0) + 1
        if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Error) == "function" then
            S.DiagnosticsManager:Error("ui_v3", "V3_MODAL_BUILD_QUARANTINED", "V3 模态宿主构建失败，本次 Generation 已隔离重试", {
                generation = tostring(S.Generation or ""), error = self.failedAttachError,
            })
        end
        return false, self.failedAttachError
    end
    local hidden, hideErr = SetVisible(root, false)
    if hidden ~= true then return false, hideErr end
    return true
end


function M:EnsureApplicationVisible()
    local shell = S.UIV3 and S.UIV3.Shell or nil
    if type(shell) ~= "table" or type(shell.Open) ~= "function" then
        self.stats.hostWakeFailures = (tonumber(self.stats.hostWakeFailures) or 0) + 1
        return false, "V3 主窗口宿主不可用"
    end
    local adapter = S.UIV3NativeAdapter
    if shell.window ~= nil and type(adapter) == "table" and type(adapter.IsVisible) == "function" then
        local ok, visible = pcall(function() return adapter:IsVisible(shell.window) end)
        if ok == true and visible == true then return true end
    end
    local ok, result, detail = xpcall(function() return shell:Open() end, S.SafeTraceback)
    if ok ~= true or result ~= true then
        self.stats.hostWakeFailures = (tonumber(self.stats.hostWakeFailures) or 0) + 1
        return false, tostring(ok and detail or result or "V3 主窗口打开失败")
    end
    self.stats.hostWakeups = (tonumber(self.stats.hostWakeups) or 0) + 1
    return true
end

function M:GetContentRoot() return self.contentRoot end
function M:GetTop() return self.stack[#self.stack] end
function M:HasModal() return #self.stack > 0 end

function M:Push(id, instance, options)
    id = tostring(id or "")
    if id == "" or instance == nil then return false, "modal identity/instance required" end
    local hostOk, hostErr = self:EnsureApplicationVisible()
    if hostOk ~= true then return false, hostErr end
    if self.root == nil then return false, "modal root unavailable after host wake" end
    options = type(options) == "table" and options or {}

    local existingIndex = nil
    for index = #self.stack, 1, -1 do
        if self.stack[index].id == id then existingIndex = index; break end
    end
    local previous = self:GetTop()
    local targetRow = existingIndex and self.stack[existingIndex] or { id = id, instance = instance, options = options }
    local targetInstance = instance

    if previous ~= nil and previous ~= targetRow then
        local hidden, hideErr = SetVisible(previous.instance, false)
        if hidden ~= true then return false, "modal_previous_hide_failed:" .. tostring(hideErr or "unknown") end
    end
    local shown, showErr = SetVisible(targetInstance, true)
    if shown ~= true then
        if previous ~= nil and previous ~= targetRow then SetVisible(previous.instance, true) end
        return false, "modal_target_show_failed:" .. tostring(showErr or "unknown")
    end
    local hostShown, hostShowErr = SetVisible(self.root, true)
    if hostShown ~= true then
        SetVisible(targetInstance, false)
        if previous ~= nil and previous ~= targetRow then SetVisible(previous.instance, true) end
        return false, "modal_host_show_failed:" .. tostring(hostShowErr or "unknown")
    end

    if existingIndex ~= nil then
        local row = table.remove(self.stack, existingIndex)
        row.instance = instance
        row.options = options
        self.stack[#self.stack + 1] = row
    else
        self.stack[#self.stack + 1] = targetRow
        self.stats.pushes = (tonumber(self.stats.pushes) or 0) + 1
    end
    Raise(instance)
    if type(options.onOpened) == "function" then pcall(options.onOpened, instance, id) end
    if type(RSUI.FlushLayoutQueue) == "function" then RSUI:FlushLayoutQueue(12) end
    return true
end

function M:Pop(id, reason)
    if #self.stack == 0 then return nil end
    local target = id ~= nil and tostring(id) or nil
    for index = #self.stack, 1, -1 do
        local row = self.stack[index]
        if target == nil or row.id == target then
            local nextTop = nil
            for probe = #self.stack, 1, -1 do
                if probe ~= index then nextTop = self.stack[probe]; break end
            end
            local hidden, hideErr = SetVisible(row.instance, false)
            if hidden ~= true then return nil, "modal_pop_hide_failed:" .. tostring(hideErr or "unknown") end
            if nextTop ~= nil then
                local shown, showErr = SetVisible(nextTop.instance, true)
                if shown ~= true then
                    SetVisible(row.instance, true)
                    return nil, "modal_restore_top_failed:" .. tostring(showErr or "unknown")
                end
            else
                local hostHidden, hostHideErr = SetVisible(self.root, false)
                if hostHidden ~= true then
                    SetVisible(row.instance, true)
                    return nil, "modal_host_hide_failed:" .. tostring(hostHideErr or "unknown")
                end
            end
            table.remove(self.stack, index)
            self.stats.pops = (tonumber(self.stats.pops) or 0) + 1
            if type(row.options.onClosed) == "function" then pcall(row.options.onClosed, row.instance, tostring(reason or "pop")) end
            if nextTop ~= nil then Raise(nextTop.instance) end
            if type(RSUI.FlushLayoutQueue) == "function" then RSUI:FlushLayoutQueue(12) end
            return row.instance
        end
    end
    return nil
end

function M:DismissTop(reason)
    local top = self:GetTop()
    if top == nil then return false end
    return self:Pop(top.id, reason or "dismiss") ~= nil
end

function M:Clear(reason)
    while #self.stack > 0 do
        local popped, popErr = self:Pop(nil, reason or "clear")
        if popped == nil then return false, popErr or "modal_clear_failed" end
    end
    if self.root ~= nil then
        local hidden, hideErr = SetVisible(self.root, false)
        if hidden ~= true then return false, hideErr end
    end
    self.stats.clears = (tonumber(self.stats.clears) or 0) + 1
    return true
end

function M:Describe()
    local top = self:GetTop()
    return {
        version = self.version,
        buildTransactionContractVersion = self.buildTransactionContractVersion,
        visibilityTransactionContractVersion = self.visibilityTransactionContractVersion,
        count = #self.stack,
        attached = self.root ~= nil and self.scrim ~= nil and self.contentRoot ~= nil,
        topId = top and top.id or nil,
        keyboardDismissSupported = self.keyboardDismissSupported == true,
        pushes = tonumber(self.stats.pushes) or 0,
        pops = tonumber(self.stats.pops) or 0,
        clears = tonumber(self.stats.clears) or 0,
        backdropDismissals = tonumber(self.stats.backdropDismissals) or 0,
        attachFailures = tonumber(self.stats.attachFailures) or 0,
        quarantinedRejects = tonumber(self.stats.quarantinedRejects) or 0,
        hostWakeups = tonumber(self.stats.hostWakeups) or 0,
        hostWakeFailures = tonumber(self.stats.hostWakeFailures) or 0,
        buildQuarantined = tonumber(self.failedAttachGeneration) == tonumber(S.Generation),
    }
end

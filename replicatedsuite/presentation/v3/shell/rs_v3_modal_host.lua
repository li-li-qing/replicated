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
    version = 5,
    buildTransactionContractVersion = 1,
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
    if instance == nil then return false end
    if type(instance.SetVisibility) == "function" then
        instance:SetVisibility(visible and "visible" or "collapsed")
        return true
    end
    if type(instance.SetVisible) == "function" then
        instance:SetVisible(visible == true)
        return true
    end
    local native = type(instance) == "table" and instance.root or instance
    if native ~= nil and S.UI ~= nil and type(S.UI.SetVisible) == "function" then
        return S.UI:SetVisible(native, visible == true, "v3:modal_host")
    end
    return false
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
        if type(root.SetVisibility) == "function" then root:SetVisibility("collapsed") end
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
        if type(self.scrim.On) == "function" then
            self.scrim:On(self.scrim.root, "OnClick", function()
                local top = M:GetTop()
                if top ~= nil and top.options.dismissOnBackdrop == true then
                    M.stats.backdropDismissals = (tonumber(M.stats.backdropDismissals) or 0) + 1
                    return M:Pop(top.id, "backdrop") ~= nil
                end
                return true
            end, "v3:modal_host:backdrop")
        end
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
    if type(root.SetVisibility) == "function" then root:SetVisibility("collapsed") end
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

    -- An id is unique inside the modal stack. Re-pushing it raises the existing
    -- instance instead of creating duplicate modal authority.
    for index = #self.stack, 1, -1 do
        if self.stack[index].id == id then
            local row = table.remove(self.stack, index)
            row.instance = instance
            row.options = options
            self.stack[#self.stack + 1] = row
            local previous = self.stack[#self.stack - 1]
            if previous ~= nil then SetVisible(previous.instance, false) end
            SetVisible(instance, true)
            if type(self.root.SetVisibility) == "function" then self.root:SetVisibility("visible") end
            Raise(instance)
            return true
        end
    end

    local previous = self:GetTop()
    if previous ~= nil then SetVisible(previous.instance, false) end
    local row = { id = id, instance = instance, options = options }
    self.stack[#self.stack + 1] = row
    SetVisible(instance, true)
    if type(self.root.SetVisibility) == "function" then self.root:SetVisibility("visible") end
    Raise(instance)
    self.stats.pushes = (tonumber(self.stats.pushes) or 0) + 1
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
            table.remove(self.stack, index)
            SetVisible(row.instance, false)
            self.stats.pops = (tonumber(self.stats.pops) or 0) + 1
            if type(row.options.onClosed) == "function" then pcall(row.options.onClosed, row.instance, tostring(reason or "pop")) end
            local top = self:GetTop()
            if top ~= nil then
                SetVisible(top.instance, true)
                Raise(top.instance)
            elseif self.root ~= nil and type(self.root.SetVisibility) == "function" then
                self.root:SetVisibility("collapsed")
            end
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
    while #self.stack > 0 do self:Pop(nil, reason or "clear") end
    if self.root ~= nil and type(self.root.SetVisibility) == "function" then self.root:SetVisibility("collapsed") end
    self.stats.clears = (tonumber(self.stats.clears) or 0) + 1
    return true
end

function M:Describe()
    local top = self:GetTop()
    return {
        version = self.version,
        buildTransactionContractVersion = self.buildTransactionContractVersion,
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

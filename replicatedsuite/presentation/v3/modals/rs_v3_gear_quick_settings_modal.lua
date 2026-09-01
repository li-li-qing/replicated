------------------------------------------------------------------------
-- Replicated Suite V3 - Gear Quick Button Snap Settings Modal
--
-- Presentation only. Exact numeric entry is intentional: the interaction
-- policy is persisted by Gear Feature authority, while this modal owns no
-- independent state and performs no polling / Tick work.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI = S.RSUI
local Feature = S.Features and S.Features.Gear or nil
if type(RSUI) ~= "table" or type(Feature) ~= "table" then return end

S.UIV3 = S.UIV3 or {}
S.UIV3.GearQuickSettingsModalV3 = {
    id = "v3_gear_quick_settings_modal",
    created = false,
    failedGeneration = nil,
    failedError = nil,
}
local M = S.UIV3.GearQuickSettingsModalV3

function M:EnsureCreated()
    if self.created == true and self.card ~= nil then return true end
    if tonumber(self.failedGeneration) == tonumber(S.Generation) then return false, tostring(self.failedError or "换装设置 Modal 已在当前 Generation 隔离") end
    local modalHost = S.UIV3 and S.UIV3.ModalHost or nil
    local parent = type(modalHost) == "table" and type(modalHost.GetContentRoot) == "function" and modalHost:GetContentRoot() or nil
    if parent == nil then return false, "模态窗口宿主尚未挂载" end

    local buildOk, _, buildErr = RSUI:WithBuildScope(self.id .. ":build", function()
        self.card = RSUI:Border({
            id = self.id .. "_card", parent = parent, variant = "card", padding = 12,
            width = 500, minHeight = 310,
            slot = { size = "auto", hAlign = "center", vAlign = "center", padding = 18 },
        })
        if self.card == nil then return false, "快捷按钮吸附设置容器创建失败" end

        local stack = RSUI:VerticalBox({ id = self.id .. "_stack", parent = self.card, gap = 8 })
        if stack == nil then return false, "快捷按钮吸附设置内容栈创建失败" end
        local header = RSUI:HorizontalBox({ id = self.id .. "_header", parent = stack, gap = 8, slot = { size = "fixed", height = 30, hAlign = "fill" } })
        if header == nil then return false, "快捷按钮吸附设置标题栏创建失败" end
        local title = RSUI:Text({ id = self.id .. "_title", parent = header, text = "快捷按钮吸附设置", fontSize = 15, tone = "accent", slot = { size = "fill", fill = 1 } })
        local close = RSUI:Button({ id = self.id .. "_close", parent = header, text = "×", compact = true, slot = { size = "fixed", width = 34 }, onClick = function() return M:Close("close_button") end })
        if title == nil or close == nil then return false, "快捷按钮吸附设置标题控件创建失败" end

        local hint = RSUI:Text({
            id = self.id .. "_hint", parent = stack,
            text = "吸附由 RSUI 底层统一计算；换装按钮可以与其他支持吸附的屏幕按钮贴合。关闭后换装按钮完全自由。",
            fontSize = 9, tone = "muted", overflow = "wrap", maxLines = 2,
            slot = { size = "auto", minHeight = 36, hAlign = "fill" },
        })
        if hint == nil then return false, "快捷按钮吸附设置提示创建失败" end

        self.distanceField = RSUI:NumericField({
            id = self.id .. "_distance", parent = stack,
            label = "吸附距离", hint = "拖动结束时，与其他支持吸附的屏幕按钮进入这个距离（像素）才会自动贴合。",
            min = 1, max = 80, step = 1, integer = true, unit = " px", slider = true, stepButtons = false, inputWidth = 100,
            get = function() return Feature:GetQuickSnapSettings().distance end,
            set = function(value) return Feature.Commands:ApplyQuickSnapDistance(value) end,
            storeId = "v3.gear.index", persistDelayMs = 300, persistReason = "gear_quick_snap_distance",
            slot = { size = "auto", hAlign = "fill" },
        })
        if self.distanceField == nil then return false, "快捷按钮吸附距离控件创建失败" end

        self.gapField = RSUI:NumericField({
            id = self.id .. "_gap", parent = stack,
            label = "按钮间距", hint = "0 = 完全贴合；数值越大，吸附后两个按钮之间保留的空隙越大。",
            min = 0, max = 40, step = 1, integer = true, unit = " px", slider = true, stepButtons = false, inputWidth = 100,
            get = function() return Feature:GetQuickSnapSettings().gap end,
            set = function(value) return Feature.Commands:ApplyQuickButtonGap(value) end,
            storeId = "v3.gear.index", persistDelayMs = 300, persistReason = "gear_quick_button_gap",
            slot = { size = "auto", hAlign = "fill" },
        })
        if self.gapField == nil then return false, "快捷按钮间距控件创建失败" end

        local actions = RSUI:HorizontalBox({ id = self.id .. "_actions", parent = stack, gap = 6, slot = { size = "auto", hAlign = "right" } })
        if actions == nil then return false, "快捷按钮吸附设置操作栏创建失败" end
        local reset = RSUI:Button({
            id = self.id .. "_reset", parent = actions, text = "恢复默认", compact = true, slot = { size = "auto", hAlign = "right" },
            onClick = function()
                local ok = Feature.Commands:ResetQuickSnapSettings()
                if ok == true then M:Refresh() end
                return ok
            end,
        })
        local done = RSUI:Button({ id = self.id .. "_done", parent = actions, text = "完成", compact = true, slot = { size = "auto", hAlign = "right" }, onClick = function() return M:Close("done") end })
        if reset == nil or done == nil then return false, "快捷按钮吸附设置操作控件创建失败" end

        self.card:SetVisibility("collapsed")
        return true
    end)
    if buildOk ~= true then
        self.created = false
        self.failedGeneration = S.Generation
        self.failedError = tostring(buildErr or "换装设置 Modal 构建失败")
        self.card, self.distanceField, self.gapField = nil, nil, nil
        return false, self.failedError
    end
    self.created = true
    return true
end

function M:Refresh()
    if self.distanceField ~= nil and type(self.distanceField.Render) == "function" then self.distanceField:Render() end
    if self.gapField ~= nil and type(self.gapField.Render) == "function" then self.gapField:Render() end
    return true
end

function M:Open()
    local modalHost = S.UIV3 and S.UIV3.ModalHost or nil
    if type(modalHost) ~= "table" or type(modalHost.EnsureApplicationVisible) ~= "function" then return false, "模态窗口宿主不可用" end
    local hostOk, hostErr = modalHost:EnsureApplicationVisible()
    if hostOk ~= true then return false, hostErr end
    local ok, err = self:EnsureCreated()
    if ok ~= true then return false, err end
    self:Refresh()
    modalHost = S.UIV3 and S.UIV3.ModalHost or modalHost
    if type(modalHost) ~= "table" or type(modalHost.Push) ~= "function" then return false, "模态窗口宿主不可用" end
    return modalHost:Push(self.id, self.card, { dismissOnBackdrop = true })
end

function M:Close(reason)
    local modalHost = S.UIV3 and S.UIV3.ModalHost or nil
    if type(modalHost) ~= "table" or type(modalHost.Pop) ~= "function" then return false end
    return modalHost:Pop(self.id, reason or "close") ~= nil
end

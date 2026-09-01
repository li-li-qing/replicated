------------------------------------------------------------------------
-- Replicated Suite - Legacy Bag Organizer Presenter
--
-- Owns the quick 取/放 overlay and the Legacy page refresh bridge.  Storage
-- detection/move planning remain in BagOrganizerService.  The Service injects
-- state through this presenter interface and contains no Native UI mutations.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Presentation = S.Presentation or {}
S.Presentation.Legacy = S.Presentation.Legacy or {}
S.Presentation.Legacy.BagOrganizer = S.Presentation.Legacy.BagOrganizer or {
    panel = nil,
    withdraw = nil,
    deposit = nil,
    lastWithdrawText = nil,
    lastDepositText = nil,
    lastEnabled = nil,
    lastVisible = nil,
}
local P = S.Presentation.Legacy.BagOrganizer

local PANEL_W, PANEL_H = 100, 34

function P:Ensure(service)
    if self.panel ~= nil then return true end
    if type(CreateEmptyWindow) ~= "function" or S.UI == nil then return false end
    local panel = CreateEmptyWindow(S.PhysicalId("bag_organizer_floating"), "UIParent")
    if panel == nil then return false end
    panel:SetExtent(PANEL_W, PANEL_H)
    S.UI:TrySetUILayer(panel, "system")
    if panel.SetDrawPriority ~= nil then pcall(function() panel:SetDrawPriority(12000) end) end
    if panel.Enable ~= nil then pcall(function() panel:Enable(true) end) end
    if panel.Clickable ~= nil then pcall(function() panel:Clickable(true) end) end
    S.Theme:AddBorder(panel, false)
    S.Theme:AddGradientBackground(panel, "card", nil)
    S.Theme:SetOpacity(panel, 1.0)

    local withdraw = S.UI:CreateButton(panel, "bag_organizer_float_withdraw", "取", 4, 4, 44, 26, 11, false, true)
    local deposit = S.UI:CreateButton(panel, "bag_organizer_float_deposit", "放", 52, 4, 44, 26, 11, false, true)
    S.UI:SafeHandler(withdraw, "OnClick", function()
        if service ~= nil and type(service.Begin) == "function" then service:Begin("withdraw") end
    end, "bag_organizer:floating_withdraw")
    S.UI:SafeHandler(deposit, "OnClick", function()
        if service ~= nil and type(service.Begin) == "function" then service:Begin("deposit") end
    end, "bag_organizer:floating_deposit")
    panel:Show(false)
    self.panel, self.withdraw, self.deposit = panel, withdraw, deposit
    return true
end

function P:ApplyFloatingLayout(service)
    if self.panel == nil and not self:Ensure(service) then return false end
    local panel = self.panel
    panel:SetExtent(PANEL_W, PANEL_H)
    if panel.RemoveAllAnchors ~= nil then panel:RemoveAllAnchors() end

    local context = S.Layout:GetContext()
    local edge = math.max(6, tonumber(context.safeTop) or 12)
    local logicalW = tonumber(context.logicalWidth) or 1024
    local logicalH = tonumber(context.logicalHeight) or 768
    local rect = service ~= nil and type(service.ResolveBagAnchorRect) == "function" and service:ResolveBagAnchorRect() or nil

    if type(rect) == "table" then
        local targetX = rect.x + math.max(0, (rect.width - PANEL_W) / 2)
        local targetY = rect.y - PANEL_H - 4
        local placement = "above"
        if targetY < edge then
            targetY = math.max(edge, rect.y + 4)
            placement = "inside-top"
        end
        if S.Layout ~= nil and type(S.Layout.ClampTopLeft) == "function" then
            targetX, targetY = S.Layout:ClampTopLeft(targetX, targetY, PANEL_W, PANEL_H, { edge = edge })
        else
            targetX = math.max(edge, math.min(targetX, math.max(edge, logicalW - edge - PANEL_W)))
            targetY = math.max(edge, math.min(targetY, math.max(edge, logicalH - edge - PANEL_H)))
        end
        panel:AddAnchor("TOPLEFT", "UIParent", math.floor(targetX + 0.5), math.floor(targetY + 0.5))
        if service ~= nil then service.floatingPlacement = placement end
    else
        local safeX = math.max(edge, math.floor((logicalW - PANEL_W) / 2))
        panel:AddAnchor("TOPLEFT", "UIParent", safeX, edge)
        if service ~= nil then service.floatingPlacement = "safe-top-unresolved" end
    end

    S.UI:SetAnchor(self.withdraw, panel, 4, 4); self.withdraw:SetExtent(44, 26)
    S.UI:SetAnchor(self.deposit, panel, 52, 4); self.deposit:SetExtent(44, 26)
    return true
end

function P:RefreshFloating(service, state)
    state = type(state) == "table" and state or {}
    if not self:Ensure(service) then return false end
    self:ApplyFloatingLayout(service)

    local withdrawText = tostring(state.withdrawText or "取")
    local depositText = tostring(state.depositText or "放")
    if self.lastWithdrawText ~= withdrawText then self.lastWithdrawText = withdrawText; self.withdraw:SetText(withdrawText) end
    if self.lastDepositText ~= depositText then self.lastDepositText = depositText; self.deposit:SetText(depositText) end

    local enabled = state.controlsEnabled ~= false
    if self.lastEnabled ~= enabled then
        self.lastEnabled = enabled
        if self.withdraw.Enable ~= nil then self.withdraw:Enable(enabled) end
        if self.deposit.Enable ~= nil then self.deposit:Enable(enabled) end
    end

    local visible = state.shouldShow == true
    if self.lastVisible ~= visible then self.lastVisible = visible; self.panel:Show(visible) end
    if visible and self.panel.Raise ~= nil then pcall(function() self.panel:Raise() end) end
    return true
end

function P:RefreshPage()
    local page = S.UI and S.UI.pages and S.UI.pages.bagorganizer or nil
    if page ~= nil and type(page.Refresh) == "function" then
        local ok, err = xpcall(function() page:Refresh() end, S.SafeTraceback)
        if not ok and S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Record) == "function" then
            S.DiagnosticsManager:Record("warning", "bag_organizer", "page refresh: " .. tostring(err))
        end
    end
    return true
end

function P:HideFloating()
    self.lastVisible = false
    if self.panel ~= nil then pcall(function() self.panel:Show(false) end) end
    return true
end

local service = S.Services and S.Services.BagOrganizer or nil
if service ~= nil and type(service.SetPresenter) == "function" then service:SetPresenter(P) end

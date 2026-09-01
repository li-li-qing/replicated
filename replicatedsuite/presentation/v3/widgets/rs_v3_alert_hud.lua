------------------------------------------------------------------------
-- Replicated Suite V3 - Shared Alert HUD Presenter
--
-- Presentation-only consumer for S.Services.Alerts.  Alerts are push-driven;
-- no timer/scan is owned here.  The service owns expiry/countdown timing.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local Alerts = S.Services and S.Services.Alerts or nil
if type(Alerts) ~= "table" or type(S.UI) ~= "table" then return end

S.UIV3 = S.UIV3 or {}
S.UIV3.AlertHudV3 = S.UIV3.AlertHudV3 or {}
local P = S.UIV3.AlertHudV3
P.version = 1
P.owner = "v3:alert_hud"
P.root = P.root or nil
P.label = P.label or nil
P.background = P.background or nil
P.visible = P.visible == true

local function NewColorDrawable(parent, layer)
    if parent == nil or type(parent.CreateColorDrawable) ~= "function" then return nil end
    local ok, drawable = pcall(function() return parent:CreateColorDrawable(0.02, 0.04, 0.05, 0.82, layer or "artwork") end)
    return ok and drawable or nil
end

function P:EnsureCreated()
    if self.root ~= nil and self.label ~= nil then return true end
    local _,_,_,logicalW = S.Api:GetUiMetrics()
    local width = math.max(280, math.min(720, (tonumber(logicalW) or 1024) - 80))
    local root, err = S.UI:CreateEmptyWidget(UIParent, "v3_alert_hud_root", 0, 0, width, 84, false, self.owner)
    if root == nil then return false, err or "alert_hud_root_create_failed" end
    local bg = NewColorDrawable(root, "artwork")
    local label = S.UI:CreateLabel(root, "v3_alert_hud_label", "", 8, 6, width - 16, 72, 34, "strong", "CENTER", true)
    if bg == nil or label == nil then
        S.UI:SetVisible(root, false, self.owner)
        if type(S.UI.ReleaseOwner)=="function" then S.UI:ReleaseOwner(self.owner) end
        self.root,self.background,self.label=nil,nil,nil
        return false, "alert_hud_child_create_failed"
    end
    self.root, self.background, self.label = root, bg, label
    S.UI:SetAnchor(bg, root, 0, 0, self.owner)
    S.UI:SetExtent(bg, width, 84, self.owner)
    S.UI:SetVisible(root, false, self.owner)
    return true
end

function P:ApplyLayout(cfg)
    if self.root == nil then return false end
    cfg = type(cfg) == "table" and cfg or {}
    local _,_,_,logicalW,logicalH = S.Api:GetUiMetrics()
    logicalW,logicalH=tonumber(logicalW) or 1024,tonumber(logicalH) or 768
    local width = math.max(280, math.min(720, logicalW - 80))
    local height = math.max(64, math.min(110, (tonumber(cfg.fontSize) or 34) * 2.25))
    local x = math.floor((logicalW - width) / 2)
    local y = tostring(cfg.anchorMode or "center") == "top" and 58 or math.floor(logicalH * 0.30)
    S.UI:SetAnchor(self.root, "UIParent", x, y, self.owner)
    S.UI:SetExtent(self.root, width, height, self.owner)
    S.UI:SetAnchor(self.background, self.root, 0, 0, self.owner)
    S.UI:SetExtent(self.background, width, height, self.owner)
    S.UI:SetAnchor(self.label, self.root, 8, 4, self.owner)
    S.UI:SetExtent(self.label, width - 16, height - 8, self.owner)
    S.UI:SetFontSize(self.label, math.max(18, math.min(56, tonumber(cfg.fontSize) or 34)), self.owner)
    return true
end

function P:Show(text, cfg)
    local ok, err = self:EnsureCreated(); if ok ~= true then return false, err end
    self:ApplyLayout(cfg)
    S.UI:SetText(self.label, tostring(text or ""), self.owner)
    S.UI:SetVisible(self.root, true, self.owner)
    S.UI:TrySetUILayer(self.root, "system")
    if type(self.root.Raise) == "function" then pcall(function() self.root:Raise() end) end
    self.visible = true
    return true
end

function P:UpdateText(text)
    if self.label == nil then return false end
    S.UI:SetText(self.label, tostring(text or ""), self.owner)
    return true
end

function P:Hide()
    if self.root ~= nil then S.UI:SetVisible(self.root, false, self.owner) end
    self.visible = false
    return true
end

function P:Describe() return { version=self.version, created=self.root~=nil, visible=self.visible==true } end

Alerts:SetPresenter(P)
Alerts:Start()

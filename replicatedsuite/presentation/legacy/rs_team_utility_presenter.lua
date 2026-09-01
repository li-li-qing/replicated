------------------------------------------------------------------------
-- Replicated Suite - Legacy Team Utility Presenter
--
-- Presentation-only Sacrifice Dance overlay. TeamUtilityService owns roster,
-- buff observation and remaining-time facts; this presenter owns Native UI.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Presentation = S.Presentation or {}
S.Presentation.Legacy = S.Presentation.Legacy or {}
S.Presentation.Legacy.TeamUtility = S.Presentation.Legacy.TeamUtility or { overlays = {} }
local P = S.Presentation.Legacy.TeamUtility
P.overlays = P.overlays or {}
local SAC_DURATION_MS = 10000

local function SafeUiId(unitId)
    return tostring(unitId or "unit"):gsub("[^%w_]", "_")
end

function P:CreateOverlay(unitId)
    if self.overlays[unitId] ~= nil then return self.overlays[unitId] end
    local safeId = SafeUiId(unitId)
    local window = CreateEmptyWindow(S.PhysicalId("sac_" .. safeId), "UIParent")
    if window == nil then return nil end
    window:SetExtent(142, 50)
    if window.EnablePick ~= nil then pcall(function() window:EnablePick(false, true) end) end
    if window.Clickable ~= nil then pcall(function() window:Clickable(false) end) end
    if S.UI ~= nil and type(S.UI.TrySetUILayer) == "function" then S.UI:TrySetUILayer(window, "system") end
    if window.SetDrawPriority ~= nil then pcall(function() window:SetDrawPriority(12000) end) end

    local glow = nil
    if type(window.CreateColorDrawable) == "function" then
        glow = window:CreateColorDrawable(1.00, 0.72, 0.05, 0.92, "background")
        glow:AddAnchor("TOPLEFT", window, 0, 0)
        glow:SetExtent(50, 50)
        glow:SetVisible(true)
    end

    local icon = nil
    if type(window.CreateIconDrawable) == "function" then
        icon = window:CreateIconDrawable("artwork")
        icon:SetExtent(44, 44)
        icon:ClearAllTextures()
        icon:AddTexture("ui/icon/icon_skill_pleasure14.dds")
        icon:AddAnchor("TOPLEFT", window, 3, 3)
        icon:SetVisible(true)
    end

    local label = window:CreateChildWidget("label", S.PhysicalId("sac_label_" .. safeId), 0, true)
    label:AddAnchor("TOPLEFT", window, 54, 2)
    label:SetExtent(86, 22)
    if label.SetAutoResize ~= nil then label:SetAutoResize(false) end
    if label.EnablePick ~= nil then label:EnablePick(false) end
    if S.Theme ~= nil and type(S.Theme.StyleLabel) == "function" then S.Theme:StyleLabel(label, 12, "yellow", ALIGN_LEFT) end
    label:SetText("牺牲之舞")
    label:Show(true)

    local timer = window:CreateChildWidget("label", S.PhysicalId("sac_timer_" .. safeId), 0, true)
    timer:AddAnchor("TOPLEFT", window, 54, 24)
    timer:SetExtent(36, 20)
    if timer.SetAutoResize ~= nil then timer:SetAutoResize(false) end
    if timer.EnablePick ~= nil then timer:EnablePick(false) end
    if S.Theme ~= nil and type(S.Theme.StyleLabel) == "function" then S.Theme:StyleLabel(timer, 11, "text", ALIGN_LEFT) end
    timer:SetText("10.0s")
    timer:Show(true)

    local bar = nil
    if UIParent ~= nil and type(UIParent.CreateWidget) == "function" then
        local ok, created = pcall(function() return UIParent:CreateWidget("statusbar", S.PhysicalId("sac_bar_" .. safeId), window) end)
        if ok then bar = created end
    end
    if bar ~= nil then
        bar:AddAnchor("TOPLEFT", window, 92, 28)
        bar:SetExtent(46, 10)
        if bar.SetBarTexture ~= nil then pcall(function() bar:SetBarTexture("ui/common/hud.dds", "background") end) end
        if bar.SetBarTextureByKey ~= nil then pcall(function() bar:SetBarTextureByKey("casting_status_bar") end) end
        if bar.SetOrientation ~= nil then bar:SetOrientation("HORIZONTAL") end
        if bar.SetBarColor ~= nil then bar:SetBarColor(1, 0.78, 0.10, 1) end
        if bar.SetMinMaxValues ~= nil then bar:SetMinMaxValues(0, SAC_DURATION_MS) end
        if bar.SetValue ~= nil then bar:SetValue(SAC_DURATION_MS) end
        bar:Show(true)
    end

    window:Show(false)
    local overlay = { window=window, icon=icon, glow=glow, label=label, timer=timer, bar=bar, lastTimerTenths=nil }
    self.overlays[unitId] = overlay
    return overlay
end

function P:ShowOverlay(unitId)
    local overlay = self:CreateOverlay(unitId)
    if overlay == nil or overlay.window == nil then return false end
    overlay.window:Show(true)
    return true
end

function P:HideOverlay(unitId)
    local overlay = self.overlays[unitId]
    if overlay ~= nil then overlay.lastTimerTenths = nil end
    if overlay ~= nil and overlay.window ~= nil and type(overlay.window.Show) == "function" then
        pcall(function() overlay.window:Show(false) end)
    end
    return true
end

function P:HideAll()
    for unitId in pairs(self.overlays) do self:HideOverlay(unitId) end
    return true
end

function P:UpdateOverlay(unitId, x, y, remaining)
    local overlay = self:CreateOverlay(unitId)
    if overlay == nil or overlay.window == nil then return false end
    if overlay.window.RemoveAllAnchors ~= nil then overlay.window:RemoveAllAnchors() end
    overlay.window:AddAnchor("TOPLEFT", "UIParent", tonumber(x) - 58, tonumber(y) - 82)
    overlay.window:Show(true)

    remaining = math.max(0, tonumber(remaining) or 0)
    local tenths = math.max(0, math.ceil(remaining / 100))
    if overlay.timer ~= nil and overlay.lastTimerTenths ~= tenths then
        overlay.lastTimerTenths = tenths
        overlay.timer:SetText(string.format("%.1fs", tenths / 10))
    end
    if overlay.bar ~= nil and overlay.bar.SetValue ~= nil then overlay.bar:SetValue(remaining) end
    return true
end

local service = S.Services and S.Services.TeamUtility or nil
if service ~= nil and type(service.SetPresenter) == "function" then service:SetPresenter(P) end

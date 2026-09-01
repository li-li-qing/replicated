------------------------------------------------------------------------
-- Replicated Suite - HUD Manager
-- Author: Replicated
-- Architecture baseline: UI/HUD Spec v1 / 2026-08-15
--
-- HUD visibility and appearance are Suite Authority. Module Enabled, HUD
-- Visible, Collapsed, Lock and appearance inheritance are independent states.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite

S.HudManager = {
    registry = {}, order = {}, editMode = true,
    temporaryHidden = false, temporarySnapshot = nil,
    temporaryUnlockAll = false,
}
local H = S.HudManager

local DEFAULT_MODULE_BY_HUD = {
    task = "tasks", trade = "trade", bond = "bonds", event = "activities",
    treasure = "treasure", fishing = "fishing",
}

local NormalizeId = S.Reuse.Id.Normalize
local function Clamp(value, minimum, maximum)
    local n = tonumber(value) or minimum
    if n < minimum then return minimum end
    if n > maximum then return maximum end
    return n
end
local function RequestSave()
    if S.Storage ~= nil then S.Storage:RequestSave() end
    if S.State ~= nil then S.State:MarkDirty("hud") end
end
local function NormalizePlacement(placement, def)
    if type(placement) ~= "table" then return end
    if placement.visible == nil then placement.visible = def.DefaultVisible == true end
    if placement.mode ~= "standard" and placement.mode ~= "collapsed" and placement.mode ~= "mini" then placement.mode = "standard" end
    if placement.collapsed == nil then placement.collapsed = placement.mode ~= "standard" end
    if placement.locked == nil then placement.locked = def.DefaultLocked == true end
    if placement.clickThrough == nil then placement.clickThrough = false end
    if placement.titleVisible == nil then placement.titleVisible = true end

    -- v1.1 appearance migration: a legacy per-HUD opacity is an explicit
    -- override. HUDs without such a value continue to inherit global defaults.
    if placement.backgroundAlpha == nil and tonumber(placement.opacity) ~= nil then
        placement.backgroundAlpha = Clamp(placement.opacity, 0.0, 1.0)
        if placement.backgroundInherited == nil then placement.backgroundInherited = false end
    end
    if placement.fontInherited == nil then placement.fontInherited = true end
    if placement.backgroundInherited == nil then placement.backgroundInherited = true end
    if placement.compactInherited == nil then placement.compactInherited = true end
    if placement.fontScale ~= nil then placement.fontScale = Clamp(placement.fontScale, 0.50, 2.00) end
    if placement.backgroundAlpha ~= nil then placement.backgroundAlpha = Clamp(placement.backgroundAlpha, 0.0, 1.0) end
end

function H:Register(def)
    if type(def) ~= "table" then return false, "hud definition must be table" end
    local id = NormalizeId(def.Id)
    if id == "" then return false, "HUD Id is required" end
    if self.registry[id] ~= nil then return false, "duplicate HUD: " .. id end
    def.Id = id
    def.ModuleId = NormalizeId(def.ModuleId or DEFAULT_MODULE_BY_HUD[id])
    def.Title = tostring(def.Title or id)
    def.ShortTitle = tostring(def.ShortTitle or def.Title)
    def.Instance = def.Instance
    def.SupportsCollapsed = def.SupportsCollapsed ~= false
    def.SupportsResize = def.SupportsResize ~= false
    def.SupportsFont = def.SupportsFont ~= false
    def.SupportsBackground = def.SupportsBackground ~= false
    def.SupportsCompact = def.SupportsCompact ~= false
    -- Capability-aware inspector flags. Built-in WidgetBase HUDs expose the
    -- concrete methods/refs; professional adapters that cannot honor a control
    -- are intentionally reported as unsupported instead of accepting a no-op.
    def.SupportsClickThrough = def.SupportsClickThrough ~= false
        and type(def.Instance) == "table" and type(def.Instance.SetClickThrough) == "function"
    def.SupportsTitle = def.SupportsTitle ~= false
        and type(def.Instance) == "table" and type(def.Instance.refs) == "table"
        and def.Instance.refs.titleBar ~= nil and def.Instance.refs.titleLabel ~= nil
    def.DefaultVisible = def.DefaultVisible == true
    if S.State ~= nil and S.State.ui ~= nil then
        S.State.ui.widgets = type(S.State.ui.widgets) == "table" and S.State.ui.widgets or {}
        if S.State.ui.widgets[id] == nil then
            S.State.ui.widgets[id] = {
                visible = def.DefaultVisible, mode = "standard", collapsed = false,
                titleVisible = true, locked = def.DefaultLocked == true, clickThrough = false,
                anchorH = def.DefaultAnchorH or "RIGHT", anchorV = def.DefaultAnchorV or "TOP",
                offsetX = tonumber(def.DefaultOffsetX) or 16, offsetY = tonumber(def.DefaultOffsetY) or 80,
                fontInherited = true, backgroundInherited = true, compactInherited = true,
            }
        end
        NormalizePlacement(S.State.ui.widgets[id], def)
    end
    self.registry[id] = def
    self.order[#self.order + 1] = id
    self:Apply(id)
    return true, def
end

function H:Get(id) return self.registry[NormalizeId(id)] end
function H:GetPlacement(id)
    local key = NormalizeId(id)
    return S.State ~= nil and S.State.ui ~= nil and S.State.ui.widgets ~= nil and S.State.ui.widgets[key] or nil
end
function H:IsModuleEnabled(def)
    if def == nil or def.ModuleId == "" then return true end
    if S.ModuleManager == nil or type(S.ModuleManager.IsRegistered) ~= "function" or not S.ModuleManager:IsRegistered(def.ModuleId) then return true end
    return S.ModuleManager:IsEnabled(def.ModuleId)
end
function H:IsVisible(id)
    local p = self:GetPlacement(id); return p ~= nil and p.visible == true
end
function H:IsCollapsed(id)
    local p = self:GetPlacement(id); return p ~= nil and (p.mode == "collapsed" or p.mode == "mini" or p.collapsed == true)
end
function H:IsEffectiveVisible(id)
    local def, p = self:Get(id), self:GetPlacement(id)
    return def ~= nil and p ~= nil and p.visible == true and self.temporaryHidden ~= true and self:IsModuleEnabled(def)
end

function H:GetEffectiveFontScale(id)
    local p = self:GetPlacement(id)
    local global = Clamp(S.State and S.State.settings and S.State.settings.globalHudFontScale or 1.0, 0.50, 2.00)
    if p == nil or p.fontInherited ~= false then return global end
    return Clamp(p.fontScale or global, 0.50, 2.00)
end
function H:GetEffectiveBackgroundAlpha(id)
    local p = self:GetPlacement(id)
    local global = Clamp(S.State and S.State.settings and S.State.settings.globalHudBackgroundAlpha or 0.90, 0.0, 1.0)
    if p == nil or p.backgroundInherited ~= false then return global end
    return Clamp(p.backgroundAlpha or p.opacity or global, 0.0, 1.0)
end
function H:IsCompact(id)
    local p = self:GetPlacement(id)
    local global = S.State and S.State.settings and S.State.settings.globalCompactMode == true
    if p == nil or p.compactInherited ~= false then return global end
    return p.compact == true
end

function H:Apply(id)
    local def = self:Get(id)
    if def == nil or type(def.Instance) ~= "table" then return false end
    local instance = def.Instance
    local visible = self:IsEffectiveVisible(id)
    if type(instance.ApplyEffectiveVisibility) == "function" then
        instance:ApplyEffectiveVisibility(visible, self:IsVisible(id), self:IsModuleEnabled(def))
    elseif instance.window ~= nil and type(instance.window.Show) == "function" then
        instance.window:Show(visible)
    end
    if type(instance.ApplyAppearance) == "function" then instance:ApplyAppearance() end
    if type(instance.ApplyLock) == "function" then
        instance:ApplyLock(self:IsLocked(id), self:GetPlacement(id) and self:GetPlacement(id).locked == true)
    end
    if type(instance.ApplyEditMode) == "function" then instance:ApplyEditMode(self.editMode == true) end
    return true
end
function H:ApplyAll() for _, id in ipairs(self.order) do self:Apply(id) end end

-- Resolution changes are a presentation event, not a persistence event. Built-in
-- WidgetBase HUDs are already reflowed by UIX:ApplyResponsiveLayout; professional
-- HUD adapters get one explicit callback so their Domain-owned saved rectangles
-- can be resolved against the new logical UIParent without being overwritten.
function H:OnMetricsChanged(metricsChanged)
    for _, id in ipairs(self.order) do
        local def = self.registry[id]
        local instance = def and def.Instance or nil
        local isBuiltIn = S.UI ~= nil and type(S.UI.widgets) == "table" and S.UI.widgets[id] == instance
        if type(instance) == "table" and not isBuiltIn then
            if type(instance.OnMetricsChanged) == "function" then
                pcall(function() instance:OnMetricsChanged(metricsChanged == true) end)
            elseif type(instance.ApplyLayout) == "function" then
                pcall(function() instance:ApplyLayout(true) end)
            end
            if type(instance.GetSnapWindows) == "function" and S.Layout ~= nil and type(S.Layout.EnsureWidgetVisible) == "function" then
                local ok, windows = pcall(function() return instance:GetSnapWindows() end)
                if ok and type(windows) == "table" then
                    for _, window in pairs(windows) do
                        pcall(function() S.Layout:EnsureWidgetVisible(window, { onlyWhenVisible = true }) end)
                    end
                end
            end
        end
    end
end

function H:SetVisible(id, visible, persist)
    local p = self:GetPlacement(id); if p == nil then return false end
    p.visible = visible == true; self:Apply(id)
    if persist ~= false then RequestSave() end
    return true
end
function H:ToggleVisible(id) return self:SetVisible(id, not self:IsVisible(id), true) end
function H:SetCollapsed(id, collapsed, persist)
    local p, def = self:GetPlacement(id), self:Get(id)
    if p == nil or def == nil or def.SupportsCollapsed == false then return false end
    p.mode = collapsed == true and "collapsed" or "standard"; p.collapsed = collapsed == true
    if type(def.Instance) == "table" and type(def.Instance.ApplyLayout) == "function" then def.Instance:ApplyLayout(false) end
    self:Apply(id); if persist ~= false then RequestSave() end; return true
end
function H:ToggleCollapsed(id) return self:SetCollapsed(id, not self:IsCollapsed(id), true) end

function H:SetGlobalFontScale(value)
    if S.State == nil then return false end
    S.State.settings.globalHudFontScale = Clamp(value, 0.50, 2.00); self:ApplyAll(); RequestSave(); return true
end
function H:AdjustGlobalFontScale(delta) return self:SetGlobalFontScale((tonumber(S.State.settings.globalHudFontScale) or 1.0) + (tonumber(delta) or 0)) end
function H:SetFontScale(id, value)
    local p, def = self:GetPlacement(id), self:Get(id); if p == nil or def == nil or def.SupportsFont == false then return false end
    p.fontInherited = false; p.fontScale = Clamp(value, 0.50, 2.00); self:Apply(id); RequestSave(); return true
end
function H:AdjustFontScale(id, delta) return self:SetFontScale(id, self:GetEffectiveFontScale(id) + (tonumber(delta) or 0)) end
function H:RestoreFontInheritance(id)
    local p = self:GetPlacement(id); if p == nil then return false end
    p.fontInherited = true; p.fontScale = nil; self:Apply(id); RequestSave(); return true
end

function H:SetGlobalBackgroundAlpha(value)
    if S.State == nil then return false end
    S.State.settings.globalHudBackgroundAlpha = Clamp(value, 0.0, 1.0); self:ApplyAll(); RequestSave(); return true
end
function H:SetBackgroundAlpha(id, value)
    local p, def = self:GetPlacement(id), self:Get(id); if p == nil or def == nil or def.SupportsBackground == false then return false end
    p.backgroundInherited = false; p.backgroundAlpha = Clamp(value, 0.0, 1.0); p.opacity = nil
    self:Apply(id); RequestSave(); return true
end
function H:RestoreBackgroundInheritance(id)
    local p = self:GetPlacement(id); if p == nil then return false end
    p.backgroundInherited = true; p.backgroundAlpha = nil; p.opacity = nil; self:Apply(id); RequestSave(); return true
end

function H:SetGlobalCompact(enabled)
    if S.State == nil then return false end
    S.State.settings.globalCompactMode = enabled == true; self:ApplyAll(); RequestSave(); return true
end
function H:SetCompact(id, enabled)
    local p, def = self:GetPlacement(id), self:Get(id); if p == nil or def == nil or def.SupportsCompact == false then return false end
    p.compactInherited = false; p.compact = enabled == true; self:Apply(id); RequestSave(); return true
end
function H:RestoreCompactInheritance(id)
    local p = self:GetPlacement(id); if p == nil then return false end
    p.compactInherited = true; p.compact = nil; self:Apply(id); RequestSave(); return true
end

function H:OnModuleEnabledChanged(moduleId)
    moduleId = NormalizeId(moduleId)
    for _, id in ipairs(self.order) do local def = self.registry[id]; if def ~= nil and def.ModuleId == moduleId then self:Apply(id) end end
end
function H:SetEditMode(enabled)
    self.editMode = enabled == true
    if not self.editMode then self.temporaryUnlockAll = false end
    self:ApplyAll(); return self.editMode
end
function H:IsEditMode() return self.editMode == true end
function H:SetTemporaryUnlockAll(enabled)
    self.temporaryUnlockAll = self.editMode == true and enabled == true
    self:ApplyAll(); return self.temporaryUnlockAll
end
function H:IsTemporaryUnlockAll() return self.editMode == true and self.temporaryUnlockAll == true end
function H:IsLocked(id)
    local p = self:GetPlacement(id)
    if p == nil then return false end
    if self:IsTemporaryUnlockAll() then return false end
    return p.locked == true
end
function H:SetLocked(id, locked, persist)
    local p = self:GetPlacement(id); if p == nil then return false end
    p.locked = locked == true
    self:Apply(id)
    if persist ~= false then RequestSave() end
    return true
end
function H:ToggleLocked(id)
    local p = self:GetPlacement(id); if p == nil then return false end
    return self:SetLocked(id, p.locked ~= true, true)
end

function H:SetClickThrough(id, enabled, persist)
    local p, def = self:GetPlacement(id), self:Get(id)
    if p == nil or def == nil or def.SupportsClickThrough ~= true then return false end
    p.clickThrough = enabled == true
    if type(def.Instance) == "table" and type(def.Instance.SetClickThrough) == "function" then
        def.Instance:SetClickThrough(p.clickThrough)
    end
    self:Apply(id)
    if persist ~= false then RequestSave() end
    return true
end
function H:ToggleClickThrough(id)
    local p = self:GetPlacement(id); if p == nil then return false end
    return self:SetClickThrough(id, p.clickThrough ~= true, true)
end

function H:SetTitleVisible(id, visible, persist)
    local p, def = self:GetPlacement(id), self:Get(id)
    if p == nil or def == nil or def.SupportsTitle ~= true then return false end
    p.titleVisible = visible == true
    if type(def.Instance) == "table" and type(def.Instance.ApplyLayout) == "function" then def.Instance:ApplyLayout(false) end
    self:Apply(id)
    if persist ~= false then RequestSave() end
    return true
end
function H:ToggleTitleVisible(id)
    local p = self:GetPlacement(id); if p == nil then return false end
    return self:SetTitleVisible(id, p.titleVisible == false, true)
end

function H:SetCustomTitle(id, value, persist)
    local p, def = self:GetPlacement(id), self:Get(id)
    if p == nil or def == nil or def.SupportsTitle ~= true then return false end
    local text = tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
    p.customTitle = text ~= "" and text or nil
    if type(def.Instance) == "table" and type(def.Instance.ApplyLayout) == "function" then def.Instance:ApplyLayout(false) end
    self:Apply(id)
    if persist ~= false then RequestSave() end
    return true
end

function H:GetOverview()
    local overview = { total = 0, preferredVisible = 0, effectiveVisible = 0, locked = 0, clickThrough = 0, collapsed = 0, moduleBlocked = 0 }
    for _, id in ipairs(self.order) do
        local def, p = self.registry[id], self:GetPlacement(id)
        if def ~= nil and p ~= nil then
            overview.total = overview.total + 1
            if p.visible == true then overview.preferredVisible = overview.preferredVisible + 1 end
            if self:IsEffectiveVisible(id) then overview.effectiveVisible = overview.effectiveVisible + 1 end
            if p.locked == true then overview.locked = overview.locked + 1 end
            if p.clickThrough == true then overview.clickThrough = overview.clickThrough + 1 end
            if self:IsCollapsed(id) then overview.collapsed = overview.collapsed + 1 end
            if p.visible == true and not self:IsModuleEnabled(def) then overview.moduleBlocked = overview.moduleBlocked + 1 end
        end
    end
    return overview
end

-- Built-in HUDs persist directly in Suite placement state. Professional HUDs
-- may keep their proven geometry in a module Domain store. These hooks let a
-- HUD layout profile capture/apply that UI-only state without moving business
-- Authority into Suite Core.
function H:CaptureProfileState(id)
    local def, p = self:Get(id), self:GetPlacement(id)
    if def == nil or p == nil or type(def.Instance) ~= "table" then return false end
    if type(def.Instance.CaptureProfileState) == "function" then
        local ok, err = xpcall(function() return def.Instance:CaptureProfileState(p) end, S.SafeTraceback)
        if not ok then
            if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Record) == "function" then
                S.DiagnosticsManager:Record("warning", "hud:" .. tostring(id), "profile capture: " .. tostring(err))
            end
            return false
        end
    end
    return true
end
function H:CaptureAllProfileStates()
    for _, id in ipairs(self.order) do self:CaptureProfileState(id) end
    return true
end
function H:ApplyProfileState(id)
    local def, p = self:Get(id), self:GetPlacement(id)
    if def == nil or p == nil or type(def.Instance) ~= "table" then return false end
    if type(def.Instance.ApplyProfileState) == "function" then
        local ok, err = xpcall(function() return def.Instance:ApplyProfileState(p) end, S.SafeTraceback)
        if not ok then
            if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Record) == "function" then
                S.DiagnosticsManager:Record("warning", "hud:" .. tostring(id), "profile apply: " .. tostring(err))
            end
            return false
        end
    end
    return true
end
function H:ApplyAllProfileStates()
    for _, id in ipairs(self.order) do self:ApplyProfileState(id) end
    return true
end

function H:TemporaryHideAll()
    if self.temporaryHidden == true then return true end
    self.temporaryHidden = true; self.temporarySnapshot = { at = S.NowMs and S.NowMs() or 0 }; self:ApplyAll(); return true
end
function H:RestoreTemporaryHidden()
    if self.temporaryHidden ~= true then return true end
    self.temporaryHidden = false; self.temporarySnapshot = nil; self:ApplyAll(); return true
end

function H:ResetPosition(id)
    local p, def = self:GetPlacement(id), self:Get(id); if p == nil or def == nil then return false end
    p.anchorH = def.DefaultAnchorH or "RIGHT"; p.anchorV = def.DefaultAnchorV or "TOP"
    p.offsetX = tonumber(def.DefaultOffsetX) or 16; p.offsetY = tonumber(def.DefaultOffsetY) or 80
    if type(def.Instance) == "table" and type(def.Instance.ResetPosition) == "function" then def.Instance:ResetPosition()
    elseif type(def.Instance) == "table" and type(def.Instance.ApplyLayout) == "function" then def.Instance:ApplyLayout(true) end
    self:Apply(id); RequestSave(); return true
end

function H:ResetSize(id)
    local p, def = self:GetPlacement(id), self:Get(id); if p == nil or def == nil then return false end
    p.width = nil; p.height = nil
    if type(def.Instance) == "table" and type(def.Instance.ResetSize) == "function" then def.Instance:ResetSize()
    elseif type(def.Instance) == "table" and type(def.Instance.ApplyLayout) == "function" then def.Instance:ApplyLayout(true) end
    self:Apply(id); RequestSave(); return true
end

function H:ResetTitle(id)
    local p = self:GetPlacement(id); local def = self:Get(id); if p == nil or def == nil then return false end
    p.titleVisible = true; p.customTitle = nil
    if type(def.Instance) == "table" and type(def.Instance.ApplyLayout) == "function" then def.Instance:ApplyLayout(false) end
    self:Apply(id); RequestSave(); return true
end

function H:ResetHudAppearance(id)
    local p = self:GetPlacement(id); if p == nil then return false end
    p.fontInherited = true; p.fontScale = nil
    p.backgroundInherited = true; p.backgroundAlpha = nil; p.opacity = nil
    p.compactInherited = true; p.compact = nil
    self:Apply(id); RequestSave(); return true
end

function H:ResetHudAll(id)
    local ok = self:ResetPosition(id); if not ok then return false end
    self:ResetSize(id); self:ResetHudAppearance(id); self:ResetTitle(id)
    return true
end

-- "Find HUD" is intentionally non-destructive: move back to a safe location
-- and ensure an operable technical extent, but preserve visibility, font,
-- background, title policy, collapsed preference and user semantic settings.
function H:Recover(id)
    local p, def = self:GetPlacement(id), self:Get(id)
    if p == nil or def == nil or type(def.Instance) ~= "table" then return false end
    if type(def.Instance.Recover) == "function" then
        local ok = def.Instance:Recover(); if ok == false then return false end
    else
        p.anchorH = def.DefaultAnchorH or "RIGHT"; p.anchorV = def.DefaultAnchorV or "TOP"
        p.offsetX = tonumber(def.DefaultOffsetX) or 16; p.offsetY = tonumber(def.DefaultOffsetY) or 80
        local policy = def.Instance.sizePolicy
        if type(policy) == "table" then
            if tonumber(p.width) ~= nil then p.width = math.max(tonumber(policy.minWidth) or 1, tonumber(p.width)) end
            if tonumber(p.height) ~= nil then p.height = math.max(tonumber(policy.minHeight) or 1, tonumber(p.height)) end
        end
        if type(def.Instance.ApplyLayout) == "function" then def.Instance:ApplyLayout(true) end
    end
    self:Apply(id); RequestSave(); return true
end

function H:RecoverAll()
    for _, id in ipairs(self.order) do self:Recover(id) end
    self.temporaryHidden = false; self.temporarySnapshot = nil; self.temporaryUnlockAll = false; self:ApplyAll(); RequestSave(); return true
end

function H:GetSnapWindows(excludeWindow)
    local result, seen = {}, {}
    local function Add(window)
        if window ~= nil and window ~= excludeWindow and seen[window] ~= true then
            local visible = true
            if type(window.IsVisible) == "function" then local ok, v = pcall(function() return window:IsVisible() end); visible = not ok or v == true end
            if visible then seen[window] = true; result[#result + 1] = window end
        end
    end
    for _, id in ipairs(self.order) do
        local def = self.registry[id]
        if def ~= nil and type(def.Instance) == "table" then
            Add(def.Instance.window)
            if type(def.Instance.GetSnapWindows) == "function" then
                local ok, windows = pcall(function() return def.Instance:GetSnapWindows() end)
                if ok and type(windows) == "table" then for _, window in pairs(windows) do Add(window) end end
            end
        end
    end
    return result
end

function H:List()
    local result = {}
    for _, id in ipairs(self.order) do
        local def, p = self.registry[id], self:GetPlacement(id)
        result[#result + 1] = {
            id=id, title=def.Title, shortTitle=def.ShortTitle, moduleId=def.ModuleId,
            visible=self:IsVisible(id), effectiveVisible=self:IsEffectiveVisible(id), collapsed=self:IsCollapsed(id),
            supportsCollapsed=def.SupportsCollapsed ~= false, supportsResize=def.SupportsResize ~= false,
            supportsFont=def.SupportsFont ~= false, supportsBackground=def.SupportsBackground ~= false,
            supportsCompact=def.SupportsCompact ~= false, supportsClickThrough=def.SupportsClickThrough == true,
            supportsTitle=def.SupportsTitle == true,
            fontScale=self:GetEffectiveFontScale(id), fontInherited=p == nil or p.fontInherited ~= false,
            backgroundAlpha=self:GetEffectiveBackgroundAlpha(id), backgroundInherited=p == nil or p.backgroundInherited ~= false,
            compact=self:IsCompact(id), compactInherited=p == nil or p.compactInherited ~= false,
            locked=p ~= nil and p.locked == true, effectiveLocked=self:IsLocked(id),
            clickThrough=p ~= nil and p.clickThrough == true,
            titleVisible=p == nil or p.titleVisible ~= false, customTitle=p and p.customTitle or nil,
            anchorH=p and p.anchorH or nil, anchorV=p and p.anchorV or nil,
            offsetX=p and p.offsetX or nil, offsetY=p and p.offsetY or nil,
            width=p and p.width or nil, height=p and p.height or nil,
            moduleEnabled=self:IsModuleEnabled(def),
        }
    end
    return result
end

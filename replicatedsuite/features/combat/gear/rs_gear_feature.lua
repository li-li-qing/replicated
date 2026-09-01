------------------------------------------------------------------------
-- Replicated Suite V3 - Gear / Title Feature
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local Runtime = S.FeatureRuntime
if type(Runtime) ~= "table" then return end
S.Features = S.Features or {}; S.Features.Gear = S.Features.Gear or {}
local F = S.Features.Gear
F.Id = "combat_gear"
F.ApiDependencies = { "PLAYER", "EQUIPMENT", "BAG" }
F.enabled = F.enabled == true
F.disableWhenIdle = F.disableWhenIdle == true
F.transientConsumers = type(F.transientConsumers) == "table" and F.transientConsumers or {}
F.transientAutoEnabled = F.transientAutoEnabled == true
F.QuickButtonPolicy = F.QuickButtonPolicy or {}
local QuickPolicy = F.QuickButtonPolicy
QuickPolicy.width = tonumber(QuickPolicy.width) or 104
QuickPolicy.height = tonumber(QuickPolicy.height) or 26
QuickPolicy.gapX = 0
QuickPolicy.gapY = 0
QuickPolicy.defaultBaseX = tonumber(QuickPolicy.defaultBaseX) or 300
QuickPolicy.defaultBaseY = tonumber(QuickPolicy.defaultBaseY) or 100
QuickPolicy.maxColumns = tonumber(QuickPolicy.maxColumns) or 4
QuickPolicy.snapDistance = tonumber(QuickPolicy.snapDistance) or 16

function F:GetQuickHudState()
    self.State.quickHud = type(self.State.quickHud) == "table" and self.State.quickHud or {}
    return self.State.quickHud
end

-- Presentation must not retain the mutable QuickHud table. Domain code keeps
-- using GetQuickHudState internally; this public read model is detached.
function F:GetQuickHudProjection()
    return S.Utils.DeepCopy(self:GetQuickHudState())
end

function F:GetQuickButtonPolicy()
    return S.Utils.DeepCopy(QuickPolicy)
end

function F:SaveQuickHudState(delayMs, reason)
    return self:MarkIndexDirty(tonumber(delayMs) or 300, reason or "gear_quick_buttons")
end

local function ClampInteger(value, fallback, minimum, maximum)
    value = math.floor((tonumber(value) or tonumber(fallback) or 0) + 0.5)
    if minimum ~= nil then value = math.max(tonumber(minimum) or value, value) end
    if maximum ~= nil then value = math.min(tonumber(maximum) or value, value) end
    return value
end

function F:GetQuickSnapSettings()
    local state = self:GetQuickHudState()
    state.snapEnabled = state.snapEnabled ~= false
    state.snapDistance = ClampInteger(state.snapDistance, QuickPolicy.snapDistance, 1, 80)
    state.buttonGap = ClampInteger(state.buttonGap, 0, 0, 40)
    return {
        enabled = state.snapEnabled == true,
        distance = state.snapDistance,
        gap = state.buttonGap,
    }
end


local function PublishQuickSettings(feature)
    if S.Events ~= nil and type(S.Events.Publish) == "function" then S.Events:Publish("v3.gear.quick.settings", feature:GetQuickSnapSettings()) end
end

-- Domain-only setters used by RSUI persistent bindings. They mutate the
-- in-memory Feature state and publish the projection, but Persistence dirty/save
-- ownership stays outside this method. Public SetQuick* methods below preserve
-- the existing immediate-save compatibility contract for non-binding callers.
function F:ApplyQuickSnapEnabled(enabled)
    local loaded, loadErr = self:EnsureStoreLoaded()
    if loaded ~= true then return false, loadErr end
    local state = self:GetQuickHudState()
    local nextValue = enabled == true
    if state.snapEnabled == nextValue then return true end
    state.snapEnabled = nextValue
    PublishQuickSettings(self)
    return true
end

function F:ApplyQuickSnapDistance(value)
    local loaded, loadErr = self:EnsureStoreLoaded()
    if loaded ~= true then return false, loadErr end
    local state = self:GetQuickHudState()
    local nextValue = ClampInteger(value, QuickPolicy.snapDistance, 1, 80)
    if tonumber(state.snapDistance) == nextValue then return true end
    state.snapDistance = nextValue
    PublishQuickSettings(self)
    return true
end

function F:ApplyQuickButtonGap(value)
    local loaded, loadErr = self:EnsureStoreLoaded()
    if loaded ~= true then return false, loadErr end
    local state = self:GetQuickHudState()
    local nextValue = ClampInteger(value, 0, 0, 40)
    if tonumber(state.buttonGap) == nextValue then return true end
    state.buttonGap = nextValue
    PublishQuickSettings(self)
    return true
end

function F:SetQuickSnapEnabled(enabled)
    local state = self:GetQuickHudState()
    local previous = state.snapEnabled
    local nextValue = enabled == true
    if previous == nextValue then return true end
    local ok, err = self:ApplyQuickSnapEnabled(nextValue)
    if ok ~= true then return false, err end
    local saved, saveErr = self:SaveIndexNow("gear_quick_snap_enabled")
    if saved ~= true then self:ApplyQuickSnapEnabled(previous); return false, saveErr end
    return true
end

function F:SetQuickSnapDistance(value)
    local state = self:GetQuickHudState()
    local previous = state.snapDistance
    local nextValue = ClampInteger(value, QuickPolicy.snapDistance, 1, 80)
    if tonumber(previous) == nextValue then return true end
    local ok, err = self:ApplyQuickSnapDistance(nextValue)
    if ok ~= true then return false, err end
    local saved, saveErr = self:SaveIndexNow("gear_quick_snap_distance")
    if saved ~= true then self:ApplyQuickSnapDistance(previous); return false, saveErr end
    return true
end

function F:SetQuickButtonGap(value)
    local state = self:GetQuickHudState()
    local previous = state.buttonGap
    local nextValue = ClampInteger(value, 0, 0, 40)
    if tonumber(previous) == nextValue then return true end
    local ok, err = self:ApplyQuickButtonGap(nextValue)
    if ok ~= true then return false, err end
    local saved, saveErr = self:SaveIndexNow("gear_quick_button_gap")
    if saved ~= true then self:ApplyQuickButtonGap(previous); return false, saveErr end
    return true
end

function F:ResetQuickSnapSettings()
    local loaded, loadErr = self:EnsureStoreLoaded()
    if loaded ~= true then return false, loadErr end
    local state = self:GetQuickHudState()
    local previousEnabled, previousDistance, previousGap = state.snapEnabled, state.snapDistance, state.buttonGap
    state.snapEnabled = true
    state.snapDistance = ClampInteger(QuickPolicy.snapDistance, 16, 1, 80)
    state.buttonGap = 0
    local ok, err = self:SaveIndexNow("gear_quick_snap_reset")
    if ok ~= true then
        state.snapEnabled, state.snapDistance, state.buttonGap = previousEnabled, previousDistance, previousGap
        return false, err
    end
    if S.Events ~= nil and type(S.Events.Publish) == "function" then S.Events:Publish("v3.gear.quick.settings", self:GetQuickSnapSettings()) end
    return true
end

function F:HasQuickSets()
    for _, set in ipairs(self.State.sets or {}) do
        if set.quick ~= false then return true end
    end
    return false
end

function F:GetSetCount()
    return #(self.State and self.State.sets or {})
end

-- Public Projection boundary for Active V3. Gear Pages/Widgets use these
-- methods and Commands rather than retaining the mutable Authority object.
function F:GetRows()
    return self.Authority:GetRows()
end

function F:GetRow(id)
    return self.Authority:GetRow(id)
end

function F:FindSet(id)
    return self.Authority:FindSet(id)
end

function F:GetDraft(id)
    return self.Authority:GetDraft(id)
end

function F:GetQuickRows()
    return self.Authority:GetQuickRows()
end

function F:GetCurrentMatch()
    return self.Authority:GetCurrentMatch()
end

function F:RefreshProjection(reason)
    return self.Authority:Refresh(reason or "presentation_refresh")
end

function F:CreateSet(name) return self.Authority:CreateSet(name) end
function F:DeleteSet(id) return self.Authority:DeleteSet(id) end
function F:MoveSet(id, delta) return self.Authority:MoveSet(id, delta) end
function F:Rename(id, name) return self.Authority:Rename(id, name) end
function F:CaptureDraft(id) return self.Authority:CaptureDraft(id) end
function F:SaveDraft(draft) return self.Authority:SaveDraft(draft) end
function F:SetQuick(id, visible) return self.Authority:SetQuick(id, visible == true) end
function F:SetQuickPosition(id, x, y) return self.Authority:SetQuickPosition(id, x, y) end
function F:ResetQuickPositions() return self.Authority:ResetQuickPositions() end
function F:Validate(id) return self.Authority:Validate(id) end
function F:Start(id) return self.Authority:Start(id) end
function F:DetectCurrentQuickSet(reason) return self.Authority:DetectCurrentQuickSet(reason or "presentation_detect") end


function F:EnsurePersistentQuickRuntime(reason)
    local loaded, loadErr = Runtime:EnsurePreferencesLoaded()
    if loaded ~= true then return false, loadErr end
    local preferred = Runtime:GetPreferredEnabled(self.Id)
    if preferred == true then
        if Runtime:IsEnabled(self.Id) ~= true then return Runtime:Enable(self.Id, reason or "gear_quick_runtime") end
        return true
    end
    -- Creating/showing a per-plan screen button is explicit persistent user
    -- intent. Persist the Gear runtime preference so the button survives page
    -- close and the next UI reload instead of existing only during page scope.
    return Runtime:SetPreferredEnabled(self.Id, true, reason or "gear_quick_runtime")
end

function F:HasTransientConsumers()
    for _ in pairs(self.transientConsumers or {}) do return true end
    return false
end

function F:AcquireTransient(token)
    token = tostring(token or "")
    if token == "" then return false, "gear consumer token required" end
    if self.transientConsumers[token] == true then return true end
    local wasEnabled = Runtime:IsEnabled(self.Id) == true
    if not wasEnabled then
        local ok, err = Runtime:Enable(self.Id, "gear_consumer:" .. token)
        if ok ~= true then return false, err end
        self.transientAutoEnabled = true
    end
    self.transientConsumers[token] = true
    return true
end

function F:MaybeDisableTransient(reason)
    if self:HasTransientConsumers() then return true end
    local runtime = S.Services and S.Services.GearV3 and S.Services.GearV3:GetRuntimeSnapshot() or {}
    if runtime.busy == true then self.disableWhenIdle = true; return true end
    self.disableWhenIdle = false
    local preferred = Runtime:GetPreferredEnabled(self.Id) == true
    if self.transientAutoEnabled == true and preferred ~= true and Runtime:IsEnabled(self.Id) == true then
        self.transientAutoEnabled = false
        return Runtime:Disable(self.Id, reason or "gear_transient_idle")
    end
    self.transientAutoEnabled = false
    return true
end

function F:ReleaseTransient(token)
    token = tostring(token or "")
    if token == "" or self.transientConsumers[token] ~= true then return false end
    self.transientConsumers[token] = nil
    return self:MaybeDisableTransient("gear_transient_idle")
end

-- Global screen-button visibility. This is intentionally NOT a large HUD
-- window: each configured quick plan owns one compact independent button.
--
-- Domain only decides *whether* the screen buttons should exist and keeps the
-- transient consumer lease that keeps the Gear service alive. The actual
-- show/hide is a Presentation reaction to `v3.gear.quick.visibility`.
function F:ShouldShowQuickButtons()
    if self.enabled ~= true then return false end
    local state = self:GetQuickHudState()
    return state.visible ~= false and self:HasQuickSets()
end

function F:SyncQuickButtonsHost(reason)
    -- Domain never touches WidgetHost. Publishing the fact is idempotent and
    -- harmless before the Presentation layer has registered the widget; the
    -- widget resyncs itself when it registers.
    local shouldShow = self:ShouldShowQuickButtons()
    local token = "hud:gear_quick"
    if shouldShow then
        if self.transientConsumers[token] ~= true then self.transientConsumers[token] = true end
    elseif self.transientConsumers[token] == true then
        self.transientConsumers[token] = nil
    end
    if S.Events ~= nil and type(S.Events.Publish) == "function" then
        S.Events:Publish("v3.gear.quick.visibility", shouldShow == true, tostring(reason or "gear_sync"))
    end
    if shouldShow ~= true then return self:MaybeDisableTransient("gear_quick_buttons_idle") end
    return true
end

function F:SetQuickHudVisible(visible, source)
    local loaded, loadErr = self:EnsureStoreLoaded()
    if loaded ~= true then return false, loadErr end
    local state = self:GetQuickHudState()
    local nextValue = visible == true
    if state.visible ~= nextValue then
        state.visible = nextValue
        self:SaveQuickHudState(250, "gear_quick_buttons_visibility")
    end
    if nextValue and Runtime:IsEnabled(self.Id) ~= true and self:HasQuickSets() then
        local ok, err = self:AcquireTransient("hud:gear_quick")
        if ok ~= true then return false, err end
    end
    return self:SyncQuickButtonsHost(source or "gear_page")
end

local QUICK_APPEARANCE_KEYS = { locked = true, overallOpacity = true, backgroundOpacity = true, textOpacity = true }
function F:ApplyQuickHudAppearance(key, value)
    local loaded, loadErr = self:EnsureStoreLoaded()
    if loaded ~= true then return false, loadErr end
    key = tostring(key or "")
    if QUICK_APPEARANCE_KEYS[key] ~= true then return false, "unknown gear quick appearance channel" end
    local state = self:GetQuickHudState()
    local nextValue
    if key == "locked" then
        nextValue = value == true
    else
        nextValue = math.max(0, math.min(1, tonumber(value) or (key == "overallOpacity" and 0.94 or 1.0)))
    end
    if state[key] == nextValue then return true end
    state[key] = nextValue
    return true
end

function F:SetQuickHudAppearance(key, value, persist, reason)
    local normalizedKey = tostring(key or "")
    local state = self:GetQuickHudState()
    local previous = state[normalizedKey]
    local ok, err = self:ApplyQuickHudAppearance(normalizedKey, value)
    if ok ~= true then return false, err end
    if persist ~= false then
        local saved, saveErr = self:SaveQuickHudState(250, reason or ("gear_quick_" .. normalizedKey))
        if saved ~= true then
            self:ApplyQuickHudAppearance(normalizedKey, previous)
            return false, saveErr
        end
    end
    return true
end

function F:Initialize()
    local ok, err = self:EnsureStoreLoaded(); if ok ~= true then return false, err end
    if type(self.Authority) ~= "table" or type(S.Services.GearV3) ~= "table" then return false, "gear authority/service unavailable" end
    self.Authority:Refresh("initialize")
    return true
end

function F:Enable(reason)
    self.enabled = true
    self.disableWhenIdle = false
    S.Services.GearV3:SetEnabled(true)
    self.Authority:Refresh("enable")
    self:SyncQuickButtonsHost(reason or "gear_enable")
    return true
end

function F:Disable(reason)
    self.enabled = false
    self.disableWhenIdle = false
    self.transientConsumers = {}
    self.transientAutoEnabled = false
    -- Presentation hides the screen buttons from `v3.feature.lifecycle`.
    if S.Events ~= nil and type(S.Events.Publish) == "function" then
        S.Events:Publish("v3.gear.quick.visibility", false, tostring(reason or "feature_disable"))
    end
    S.Services.GearV3:SetEnabled(false)
    return true
end

function F:Refresh(reason)
    if self.enabled then return self.Authority:Refresh(reason or "feature_refresh") end
    return true
end

function F:GetHealth()
    local runtime = S.Services.GearV3:GetRuntimeSnapshot()
    local quick = 0
    for _, set in ipairs(self.State.sets or {}) do if set.quick ~= false then quick = quick + 1 end end
    return {
        ok = self.enabled == true,
        sets = #(self.State.sets or {}),
        quick = quick,
        quickHudVisible = self:GetQuickHudState().visible ~= false and quick > 0,
        busy = runtime.busy,
        stage = runtime.stage,
        pendingSetId = runtime.pendingSetId,
    }
end

F.Commands = F.Commands or {}
function F.Commands:SetDisableWhenIdle(value) F.disableWhenIdle = value == true; return true end
function F.Commands:SetQuickHudVisible(visible, source) return F:SetQuickHudVisible(visible == true, source or "gear_command") end
function F.Commands:ApplyQuickHudAppearance(key, value) return F:ApplyQuickHudAppearance(key, value) end
function F.Commands:SetQuickHudAppearance(key, value, persist, reason) return F:SetQuickHudAppearance(key, value, persist, reason) end
function F.Commands:ApplyQuickSnapEnabled(enabled) return F:ApplyQuickSnapEnabled(enabled == true) end
function F.Commands:ApplyQuickSnapDistance(value) return F:ApplyQuickSnapDistance(value) end
function F.Commands:ApplyQuickButtonGap(value) return F:ApplyQuickButtonGap(value) end
function F.Commands:MarkStoreDirty(delayMs, reason) return F:MarkStoreDirty(delayMs, reason) end
function F.Commands:RefreshProjection(reason) return F:RefreshProjection(reason or "gear_command") end
function F.Commands:CreateSet(name) return F:CreateSet(name) end
function F.Commands:DeleteSet(id) return F:DeleteSet(id) end
function F.Commands:MoveSet(id, delta) return F:MoveSet(id, delta) end
function F.Commands:Rename(id, name) return F:Rename(id, name) end
function F.Commands:CaptureDraft(id) return F:CaptureDraft(id) end
function F.Commands:SaveDraft(draft) return F:SaveDraft(draft) end
function F.Commands:SetQuick(id, visible) return F:SetQuick(id, visible == true) end
function F.Commands:SetQuickPosition(id, x, y) return F:SetQuickPosition(id, x, y) end
function F.Commands:ResetQuickPositions() return F:ResetQuickPositions() end
function F.Commands:Validate(id) return F:Validate(id) end
function F.Commands:Start(id) return F:Start(id) end
function F.Commands:DetectCurrentQuickSet(reason) return F:DetectCurrentQuickSet(reason or "gear_command") end
function F.Commands:SyncQuickButtonsHost(reason) return F:SyncQuickButtonsHost(reason or "gear_command") end

local ok, err = Runtime:RegisterImplementation(F.Id, F); if ok ~= true then error(err) end

------------------------------------------------------------------------
-- Replicated Suite V3 - Widget Host
--
-- Registry/lifecycle and common floating-widget management. Feature widgets
-- register factories plus optional preference callbacks; the Host owns the
-- consistent visibility/lock/reset contract without starting Legacy HUDs.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.UIV3 = S.UIV3 or {}
S.UIV3.WidgetHost = {
    version = 13, buildTransactionContractVersion = 1, specs = {}, instances = {}, order = {}, visible = {},
    failedInstances = {}, featureBindings = {}, lifecycleBound = false,
    stats = {
        creates = 0, createFailures = 0, visibilityChanges = 0, lockChanges = 0, layoutResets = 0, opacityChanges = 0, appearanceChanges = 0,
        responsiveReflows = 0, responsiveFailures = 0, nativeCloseNotifications = 0, nativeCloseCleanupFailures = 0,
        lifecycleReactions = 0, lifecycleReactionFailures = 0, lifecycleBindFailures = 0, closeRequests = 0,
        quarantinedRejects = 0,
    },
}
local W = S.UIV3.WidgetHost

local function NormalizeId(value) return tostring(value or "") end

local function EnsurePreferences(spec)
    if type(spec) ~= "table" or type(spec.ensurePreferences) ~= "function" then return true end
    local ok, value, detail = xpcall(spec.ensurePreferences, S.SafeTraceback)
    if not ok then return false, tostring(value or "widget preference load failed") end
    if value == false then return false, tostring(detail or "widget preference load failed") end
    return true
end
local function SafeCall(label, fn, ...)
    if type(fn) ~= "function" then return false, "unsupported" end
    local args, count = { ... }, select("#", ...)
    local ok, a, b = xpcall(function() return fn(unpack(args, 1, count)) end, S.SafeTraceback)
    if not ok then return false, tostring(a or label or "widget action failed") end
    if a == false then return false, b or tostring(label or "widget action failed") end
    return true, a
end

function W:Register(id, spec)
    id = NormalizeId(id)
    if id == "" or type(spec) ~= "table" then return false, "invalid widget spec" end
    if self.specs[id] ~= nil then return false, "duplicate widget: " .. id end
    spec.windowingRequired = spec.windowingRequired ~= false
    spec.featureId = tostring(spec.featureId or "")
    spec.lockable = spec.lockable == true or type(spec.getLocked) == "function" or type(spec.setLocked) == "function"
    spec.minimizable = spec.minimizable == true or type(spec.getMinimized) == "function" or type(spec.setMinimized) == "function"
    spec.resettable = spec.resettable == true or type(spec.resetLayout) == "function"
    spec.opacityAdjustable = spec.opacityAdjustable == true or type(spec.getOpacity) == "function" or type(spec.setOpacity) == "function" or type(spec.getOverallOpacity) == "function" or type(spec.setOverallOpacity) == "function"
    spec.backgroundOpacityAdjustable = spec.backgroundOpacityAdjustable == true or type(spec.getBackgroundOpacity) == "function" or type(spec.setBackgroundOpacity) == "function"
    spec.textOpacityAdjustable = spec.textOpacityAdjustable == true or type(spec.getTextOpacity) == "function" or type(spec.setTextOpacity) == "function"
    spec.fontScaleAdjustable = spec.fontScaleAdjustable == true or type(spec.getFontScale) == "function" or type(spec.setFontScale) == "function"
    self.specs[id] = spec
    self.order[#self.order + 1] = id
    table.sort(self.order)
    return true
end

function W:GetSpec(id) return self.specs[NormalizeId(id)] end
function W:GetInstance(id) return self.instances[NormalizeId(id)] end
function W:IsVisible(id) return self.visible[NormalizeId(id)] == true end

function W:EnsureInstance(id, context)
    id = NormalizeId(id)
    local spec = self.specs[id]
    if spec == nil then return nil, "unknown widget" end
    local instance = self.instances[id]
    if instance ~= nil then return instance end

    local failed = self.failedInstances[id]
    if type(failed) == "table" and tonumber(failed.generation) == tonumber(S.Generation) then
        self.stats.quarantinedRejects = (tonumber(self.stats.quarantinedRejects) or 0) + 1
        return nil, tostring(failed.error or "widget build quarantined")
    end
    if type(spec.create) ~= "function" then return nil, "widget create unavailable" end

    local rsui = S.RSUI
    if type(rsui) ~= "table" or type(rsui.WithBuildScope) ~= "function" then return nil, "RSUI build transaction unavailable" end
    local ok, value, detail = rsui:WithBuildScope("widget:" .. id, function()
        local created, createDetail = spec.create(context or {})
        if created == nil or created == false then return nil, createDetail or "widget create failed" end
        -- Windowing is part of the build contract, not a post-commit preference.
        -- Reject it while the scope is still active so all tracked RSUI objects
        -- roll back together instead of committing a half-valid Native surface.
        if spec.windowingRequired == true and type(created.windowController) ~= "table" then
            return nil, "悬浮组件未接入统一窗口拖动与缩放能力"
        end
        return created
    end)
    if ok ~= true or value == nil then
        local err = tostring(detail or "widget create failed")
        self.failedInstances[id] = { generation = S.Generation, error = err }
        self.stats.createFailures = (tonumber(self.stats.createFailures) or 0) + 1
        if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Error) == "function" then
            S.DiagnosticsManager:Error("ui_v3", "V3_WIDGET_BUILD_QUARANTINED", "V3 悬浮组件构建失败，本次 Generation 已隔离重试", {
                id = id, generation = tostring(S.Generation or ""), error = err,
            })
        end
        return nil, err
    end
    instance = value
    self.instances[id] = instance
    self.stats.creates = (tonumber(self.stats.creates) or 0) + 1
    return instance
end

function W:SetVisible(id, visible, context)
    id = NormalizeId(id)
    local spec = self.specs[id]
    if spec == nil then return false, "unknown widget" end
    local instance = self.instances[id]
    if visible == true and instance == nil then
        local created, createErr = self:EnsureInstance(id, context)
        if created == nil then return false, createErr end
        instance = created
    end
    if instance ~= nil then
        local fn = visible == true and (instance.Show or instance.Open) or (instance.Hide or instance.Close)
        if type(fn) == "function" then
            local ok, result, detail = xpcall(function() return fn(instance, context) end, S.SafeTraceback)
            if not ok then return false, tostring(result or "widget visibility failed") end
            if result == false then return false, tostring(detail or "widget visibility failed") end
        end
    end
    local nextValue = visible == true
    if self.visible[id] ~= nextValue then self.stats.visibilityChanges = (tonumber(self.stats.visibilityChanges) or 0) + 1 end
    self.visible[id] = nextValue
    return true
end


function W:NotifyWindowClosed(id, context)
    id = NormalizeId(id)
    local spec, instance = self.specs[id], self.instances[id]
    if spec == nil then return false, "unknown widget" end
    self.stats.nativeCloseNotifications = (tonumber(self.stats.nativeCloseNotifications) or 0) + 1

    local cleanupOk, cleanupErr = true, nil
    if instance ~= nil and type(instance.OnWindowClosed) == "function" then
        cleanupOk, cleanupErr = SafeCall("widget native close cleanup", function() return instance:OnWindowClosed(context or {}) end)
        if cleanupOk ~= true then
            self.stats.nativeCloseCleanupFailures = (tonumber(self.stats.nativeCloseCleanupFailures) or 0) + 1
        end
    end

    if self.visible[id] == true then self.stats.visibilityChanges = (tonumber(self.stats.visibilityChanges) or 0) + 1 end
    self.visible[id] = false
    if cleanupOk ~= true then return false, cleanupErr end
    return true
end

-- Programmatic close must use the same public contract as the native X button:
-- WindowShell performs the visual close, then onClosed lands here. Nothing in
-- this path calls back into the shell, so there is no Shell→Feature→Host→Hide
-- recursion.
function W:RequestClose(id, context)
    id = NormalizeId(id)
    context = type(context) == "table" and context or {}
    context.source = context.source or "widget_close_request"
    self.stats.closeRequests = (tonumber(self.stats.closeRequests) or 0) + 1
    local instance = self.instances[id]
    if instance ~= nil then
        local shell = instance.shell
        if type(shell) == "table" and type(shell.Close) == "function" then
            local ok, err = shell:Close(tostring(context.source or "close"))
            if ok == true then return true end
            -- fail-open: the shell contract normally hides anyway; fall through
            -- so a broken veto cannot make a window impossible to dismiss.
            if ok == false and context.allowVeto == true then return false, err end
        end
    end
    return self:SetVisible(id, false, context)
end

------------------------------------------------------------------------
-- Feature lifecycle bridge (Presentation side)
--
-- Domain code publishes `v3.feature.lifecycle` and never calls WidgetHost.
-- A widget declares how its visibility is derived from Domain state and the
-- Host performs the reaction. That removes the Domain → Presentation edge
-- while keeping ONE shared implementation instead of N per-feature copies.
------------------------------------------------------------------------
function W:BindFeatureLifecycle(id, options)
    id = NormalizeId(id)
    options = type(options) == "table" and options or {}
    local spec = self.specs[id]
    if spec == nil then return false, "unknown widget" end
    if type(options.enabled) ~= "function" then return false, "feature lifecycle binding requires enabled()" end
    if type(options.preference) ~= "function" then return false, "feature lifecycle binding requires preference()" end
    local previous = self.featureBindings[id]
    self.featureBindings[id] = {
        featureId = tostring(options.featureId or spec.featureId or ""),
        enabled = options.enabled,
        preference = options.preference,
        onShowFailed = type(options.onShowFailed) == "function" and options.onShowFailed or nil,
    }
    local bound = self:_EnsureLifecycleSubscription()
    if bound ~= true then
        self.featureBindings[id] = previous
        return false, "feature lifecycle subscription unavailable"
    end
    return true
end

function W:_EnsureLifecycleSubscription()
    if self.lifecycleBound == true then return true end
    if S.Events == nil or type(S.Events.SubscribeInternal) ~= "function" then
        self.stats.lifecycleBindFailures = (tonumber(self.stats.lifecycleBindFailures) or 0) + 1
        return false
    end
    self.lifecycleBound = S.Events:SubscribeInternal(
        (S.FeatureRuntime ~= nil and S.FeatureRuntime.LifecycleTopic) or "v3.feature.lifecycle",
        self,
        function(_, featureId, state, reason) W:_OnFeatureLifecycle(featureId, state, reason) end) == true
    if self.lifecycleBound ~= true then self.stats.lifecycleBindFailures = (tonumber(self.stats.lifecycleBindFailures) or 0) + 1 end
    return self.lifecycleBound
end

function W:_OnFeatureLifecycle(featureId, state, reason)
    featureId = tostring(featureId or "")
    state = tostring(state or "")
    if state ~= "enabled" and state ~= "disabled" then return true end
    for id, binding in pairs(self.featureBindings) do
        if binding.featureId == featureId then
            self.stats.lifecycleReactions = (tonumber(self.stats.lifecycleReactions) or 0) + 1
            if state == "disabled" then
                if self.visible[id] == true then
                    local ok = self:SetVisible(id, false, { persist = false, source = "feature_lifecycle:" .. tostring(reason or "disable") })
                    if ok ~= true then self.stats.lifecycleReactionFailures = (tonumber(self.stats.lifecycleReactionFailures) or 0) + 1 end
                end
            elseif self.visible[id] ~= true then
                -- Lifecycle callbacks are presentation extensions supplied by a
                -- Feature/widget module. A broken callback must not escape into
                -- the shared event dispatcher and abort reactions for every
                -- other widget in the same event.
                local preferenceOk, preferred = xpcall(binding.preference, S.SafeTraceback)
                if preferenceOk ~= true then
                    self.stats.lifecycleReactionFailures = (tonumber(self.stats.lifecycleReactionFailures) or 0) + 1
                    if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Error) == "function" then
                        S.DiagnosticsManager:Error("ui_v3", "V3_WIDGET_LIFECYCLE_CALLBACK_FAILED", "悬浮组件生命周期偏好回调失败", {
                            id = id, featureId = featureId, callback = "preference", error = tostring(preferred or "unknown"),
                        })
                    end
                elseif preferred == true then
                    local enabledOk, enabled = xpcall(binding.enabled, S.SafeTraceback)
                    if enabledOk ~= true then
                        self.stats.lifecycleReactionFailures = (tonumber(self.stats.lifecycleReactionFailures) or 0) + 1
                        if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Error) == "function" then
                            S.DiagnosticsManager:Error("ui_v3", "V3_WIDGET_LIFECYCLE_CALLBACK_FAILED", "悬浮组件生命周期启用回调失败", {
                                id = id, featureId = featureId, callback = "enabled", error = tostring(enabled or "unknown"),
                            })
                        end
                    elseif enabled == true then
                        local ok = self:SetVisible(id, true, { persist = false, source = "feature_lifecycle:" .. tostring(reason or "enable") })
                        if ok ~= true then
                            self.stats.lifecycleReactionFailures = (tonumber(self.stats.lifecycleReactionFailures) or 0) + 1
                            if binding.onShowFailed ~= nil then pcall(binding.onShowFailed, tostring(reason or "enable")) end
                        end
                    end
                end
            end
        end
    end
    return true
end

-- Domain publishes that its projection changed; the Host decides whether a
-- live widget instance should re-read it. Domain never touches an instance.
function W:NotifyProjectionChanged(id, kind)
    id = NormalizeId(id)
    local instance = self.instances[id]
    if instance == nil or self.visible[id] ~= true then return true end
    if type(instance.ApplyProjection) == "function" then
        local ok, result, detail = xpcall(function() return instance:ApplyProjection(tostring(kind or "projection")) end, S.SafeTraceback)
        if not ok or result == false then
            -- Presentation refresh failures are diagnostic-only; the Domain
            -- transaction that published the change must not roll back.
            if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.WarningRateLimited) == "function" then
                S.DiagnosticsManager:WarningRateLimited("widget_host_v3", "WIDGET_PROJECTION_REFRESH_FAILED", 3000,
                    "悬浮组件投影刷新失败", { id = id, kind = tostring(kind or "projection"), error = tostring(ok and detail or result) })
            end
            return false, tostring(ok and detail or result or "projection refresh failed")
        end
        return true
    end
    if type(instance.Refresh) == "function" then return SafeCall("widget refresh", function() return instance:Refresh() end) end
    return true
end

function W:GetState(id)
    id = NormalizeId(id)
    local spec, instance = self.specs[id], self.instances[id]
    if spec == nil then return nil end
    EnsurePreferences(spec)
    local locked = nil
    if instance ~= nil and type(instance.IsLocked) == "function" then
        local ok, value = pcall(function() return instance:IsLocked() end)
        if ok then locked = value == true end
    elseif type(spec.getLocked) == "function" then
        local ok, value = pcall(spec.getLocked)
        if ok then locked = value == true end
    end

    local minimized = nil
    if instance ~= nil and type(instance.IsMinimized) == "function" then
        local ok, value = pcall(function() return instance:IsMinimized() end)
        if ok then minimized = value == true end
    elseif type(spec.getMinimized) == "function" then
        local ok, value = pcall(spec.getMinimized)
        if ok then minimized = value == true end
    end

    local function FirstNonNil(primary, secondary)
        if primary ~= nil then return primary end
        return secondary
    end

    local function ReadOpacity(instanceMethod, specMethod, fallback)
        local value = nil
        if instance ~= nil and type(instance[instanceMethod]) == "function" then
            local ok, result = pcall(function() return instance[instanceMethod](instance) end)
            if ok then value = tonumber(result) end
        elseif type(spec[specMethod]) == "function" then
            local ok, result = pcall(spec[specMethod])
            if ok then value = tonumber(result) end
        end
        return math.max(0.0, math.min(1.0, tonumber(FirstNonNil(value, FirstNonNil(fallback, 1.0))) or 1.0))
    end

    local overallOpacity
    if instance ~= nil and type(instance.GetOverallOpacity) == "function" then
        overallOpacity = ReadOpacity("GetOverallOpacity", "getOverallOpacity", 1.0)
    elseif instance ~= nil and type(instance.GetOpacity) == "function" then
        overallOpacity = ReadOpacity("GetOpacity", "getOpacity", 1.0)
    elseif type(spec.getOverallOpacity) == "function" then
        overallOpacity = ReadOpacity("GetOverallOpacity", "getOverallOpacity", 1.0)
    else
        overallOpacity = ReadOpacity("GetOpacity", "getOpacity", 1.0)
    end
    local backgroundOpacity = ReadOpacity("GetBackgroundOpacity", "getBackgroundOpacity", 1.0)
    local textOpacity = ReadOpacity("GetTextOpacity", "getTextOpacity", 1.0)
    local function ReadScalar(instanceMethod, specMethod, fallback, minimum, maximum)
        local value = nil
        if instance ~= nil and type(instance[instanceMethod]) == "function" then
            local ok, result = pcall(function() return instance[instanceMethod](instance) end)
            if ok then value = tonumber(result) end
        elseif type(spec[specMethod]) == "function" then
            local ok, result = pcall(spec[specMethod])
            if ok then value = tonumber(result) end
        end
        value = tonumber(FirstNonNil(value, FirstNonNil(fallback, 1.0))) or 1.0
        return math.max(tonumber(minimum) or value, math.min(tonumber(maximum) or value, value))
    end
    local fontScale = ReadScalar("GetFontScale", "getFontScale", 1.0, 0.50, 2.00)
    local overallAdjustable = spec.opacityAdjustable == true
        or (instance ~= nil and (type(instance.SetOverallOpacity) == "function" or type(instance.SetOpacity) == "function"))
    local backgroundAdjustable = spec.backgroundOpacityAdjustable == true or (instance ~= nil and type(instance.SetBackgroundOpacity) == "function")
    local textAdjustable = spec.textOpacityAdjustable == true or (instance ~= nil and type(instance.SetTextOpacity) == "function")
    local fontScaleAdjustable = spec.fontScaleAdjustable == true or (instance ~= nil and type(instance.SetFontScale) == "function")

    return {
        id = id,
        featureId = spec.featureId,
        registered = true,
        created = instance ~= nil,
        visible = self.visible[id] == true,
        windowed = instance ~= nil and type(instance.windowController) == "table" or false,
        lockable = spec.lockable == true or (instance ~= nil and type(instance.SetLocked) == "function"),
        locked = locked == true,
        minimizable = spec.minimizable == true or (instance ~= nil and type(instance.SetMinimized) == "function"),
        minimized = minimized == true,
        resettable = spec.resettable == true or (instance ~= nil and type(instance.ResetLayout) == "function"),
        opacityAdjustable = overallAdjustable, -- compatibility alias
        overallOpacityAdjustable = overallAdjustable,
        backgroundOpacityAdjustable = backgroundAdjustable,
        textOpacityAdjustable = textAdjustable,
        fontScaleAdjustable = fontScaleAdjustable,
        appearanceAdjustable = overallAdjustable or backgroundAdjustable or textAdjustable or fontScaleAdjustable,
        opacity = overallOpacity, -- compatibility alias
        overallOpacity = overallOpacity,
        backgroundOpacity = backgroundOpacity,
        textOpacity = textOpacity,
        fontScale = fontScale,
    }
end

function W:SetLocked(id, locked, persist)
    id = NormalizeId(id)
    local spec, instance = self.specs[id], self.instances[id]
    if spec == nil then return false, "unknown widget" end
    local prepared, prepareErr = EnsurePreferences(spec)
    if prepared ~= true then return false, prepareErr end
    if instance ~= nil and type(instance.SetLocked) == "function" then
        local ok, err = SafeCall("widget lock", function() return instance:SetLocked(locked == true, persist ~= false) end)
        if ok then self.stats.lockChanges = (tonumber(self.stats.lockChanges) or 0) + 1 end
        return ok, err
    end
    if type(spec.setLocked) == "function" then
        local ok, err = SafeCall("widget lock", spec.setLocked, locked == true, persist ~= false)
        if ok then self.stats.lockChanges = (tonumber(self.stats.lockChanges) or 0) + 1 end
        return ok, err
    end
    return false, "widget lock unsupported"
end

function W:SetMinimized(id, minimized, persist)
    id = NormalizeId(id)
    local spec, instance = self.specs[id], self.instances[id]
    if spec == nil then return false, "unknown widget" end
    local prepared, prepareErr = EnsurePreferences(spec)
    if prepared ~= true then return false, prepareErr end
    if instance ~= nil and type(instance.SetMinimized) == "function" then
        return SafeCall("widget minimize", function() return instance:SetMinimized(minimized == true, persist ~= false) end)
    end
    if type(spec.setMinimized) == "function" then return SafeCall("widget minimize", spec.setMinimized, minimized == true, persist ~= false) end
    return false, "widget minimize unsupported"
end

function W:SetAppearance(id, channel, opacity, persist)
    id = NormalizeId(id)
    channel = tostring(channel or "overall"):lower()
    local spec, instance = self.specs[id], self.instances[id]
    if spec == nil then return false, "unknown widget" end
    local prepared, prepareErr = EnsurePreferences(spec)
    if prepared ~= true then return false, prepareErr end
    local value = math.max(0.0, math.min(1.0, tonumber(opacity) or 1.0))

    local instanceMethod, specMethod, label
    if channel == "overall" or channel == "opacity" then
        instanceMethod = instance ~= nil and type(instance.SetOverallOpacity) == "function" and "SetOverallOpacity" or "SetOpacity"
        specMethod = type(spec.setOverallOpacity) == "function" and "setOverallOpacity" or "setOpacity"
        label = "widget overall opacity"
    elseif channel == "background" then
        instanceMethod, specMethod, label = "SetBackgroundOpacity", "setBackgroundOpacity", "widget background opacity"
    elseif channel == "text" then
        instanceMethod, specMethod, label = "SetTextOpacity", "setTextOpacity", "widget text opacity"
    else
        return false, "unknown appearance channel"
    end

    if instance ~= nil and type(instance[instanceMethod]) == "function" then
        local ok, err = SafeCall(label, function() return instance[instanceMethod](instance, value, persist ~= false) end)
        if ok then
            self.stats.appearanceChanges = (tonumber(self.stats.appearanceChanges) or 0) + 1
            if channel == "overall" or channel == "opacity" then self.stats.opacityChanges = (tonumber(self.stats.opacityChanges) or 0) + 1 end
        end
        return ok, err
    end
    if type(spec[specMethod]) == "function" then
        local ok, err = SafeCall(label, spec[specMethod], value, persist ~= false)
        if ok then
            self.stats.appearanceChanges = (tonumber(self.stats.appearanceChanges) or 0) + 1
            if channel == "overall" or channel == "opacity" then self.stats.opacityChanges = (tonumber(self.stats.opacityChanges) or 0) + 1 end
        end
        return ok, err
    end
    return false, "widget appearance channel unsupported"
end

function W:SetOpacity(id, opacity, persist)
    return self:SetAppearance(id, "overall", opacity, persist)
end

-- Font scale is intentionally a separate appearance channel from alpha. It is
-- bounded as a scalar, not normalized to [0,1], and remains local to the
-- floating widget rather than changing the application-wide typography scale.
function W:SetFontScale(id, fontScale, persist)
    id = NormalizeId(id)
    local spec, instance = self.specs[id], self.instances[id]
    if spec == nil then return false, "unknown widget" end
    local prepared, prepareErr = EnsurePreferences(spec)
    if prepared ~= true then return false, prepareErr end
    local value = math.max(0.50, math.min(2.00, tonumber(fontScale) or 1.0))
    if instance ~= nil and type(instance.SetFontScale) == "function" then
        local ok, err = SafeCall("widget font scale", function() return instance:SetFontScale(value, persist ~= false) end)
        if ok then self.stats.appearanceChanges = (tonumber(self.stats.appearanceChanges) or 0) + 1 end
        return ok, err
    end
    if type(spec.setFontScale) == "function" then
        local ok, err = SafeCall("widget font scale", spec.setFontScale, value, persist ~= false)
        if ok then self.stats.appearanceChanges = (tonumber(self.stats.appearanceChanges) or 0) + 1 end
        return ok, err
    end
    return false, "widget font scale unsupported"
end

function W:ResetLayout(id)
    id = NormalizeId(id)
    local spec, instance = self.specs[id], self.instances[id]
    if spec == nil then return false, "unknown widget" end
    local prepared, prepareErr = EnsurePreferences(spec)
    if prepared ~= true then return false, prepareErr end
    if instance ~= nil and type(instance.ResetLayout) == "function" then
        local ok, err = SafeCall("widget layout reset", function() return instance:ResetLayout(true) end)
        if ok then self.stats.layoutResets = (tonumber(self.stats.layoutResets) or 0) + 1 end
        return ok, err
    end
    if type(spec.resetLayout) == "function" then
        local ok, err = SafeCall("widget layout reset", spec.resetLayout)
        if ok then self.stats.layoutResets = (tonumber(self.stats.layoutResets) or 0) + 1 end
        return ok, err
    end
    return false, "widget layout reset unsupported"
end

function W:ResetAllLayouts()
    local failures = {}
    for _, id in ipairs(self.order) do
        local state = self:GetState(id)
        if state ~= nil and state.resettable == true then
            local ok, err = self:ResetLayout(id)
            if ok ~= true then failures[#failures + 1] = id .. ":" .. tostring(err or "failed") end
        end
    end
    return #failures == 0, #failures > 0 and table.concat(failures, ";") or nil
end

function W:HideAll()
    for _, id in ipairs(self.order) do if self.visible[id] then self:SetVisible(id, false, { persist = false, reason = "hide_all" }) end end
    return true
end

-- Responsive changes are application-wide: a visible floating widget must clamp
-- and reflow together with the main shell. Hidden widgets do no work here; they
-- resolve against the latest Layout context the next time they are shown.
function W:ApplyResponsiveLayout(fromMetricsChange)
    local failures = {}
    local reflowed = 0
    for _, id in ipairs(self.order) do
        if self.visible[id] == true then
            local instance = self.instances[id]
            if instance ~= nil and type(instance.ApplyLayout) == "function" then
                local ok, result, detail = xpcall(function() return instance:ApplyLayout(fromMetricsChange == true) end, S.SafeTraceback)
                if not ok or result == false then
                    failures[#failures + 1] = id .. ":" .. tostring(ok and detail or result or "layout failed")
                else
                    reflowed = reflowed + 1
                end
            end
        end
    end
    self.stats.responsiveReflows = (tonumber(self.stats.responsiveReflows) or 0) + reflowed
    self.stats.responsiveFailures = (tonumber(self.stats.responsiveFailures) or 0) + #failures
    return #failures == 0, #failures > 0 and table.concat(failures, ";") or nil
end

function W:Describe()
    local visible, created, windowed, lockable, locked, minimizable, minimized, resettable, opacityAdjustable, appearanceAdjustable, fontScaleAdjustable = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    local quarantined = 0
    for _, row in pairs(self.failedInstances or {}) do if type(row) == "table" and tonumber(row.generation) == tonumber(S.Generation) then quarantined = quarantined + 1 end end
    for _, id in ipairs(self.order) do
        local state = self:GetState(id)
        if state ~= nil then
            if state.created then created = created + 1 end
            if state.visible then visible = visible + 1 end
            if state.windowed then windowed = windowed + 1 end
            if state.lockable then lockable = lockable + 1 end
            if state.locked then locked = locked + 1 end
            if state.minimizable then minimizable = minimizable + 1 end
            if state.minimized then minimized = minimized + 1 end
            if state.resettable then resettable = resettable + 1 end
            if state.opacityAdjustable then opacityAdjustable = opacityAdjustable + 1 end
            if state.appearanceAdjustable then appearanceAdjustable = appearanceAdjustable + 1 end
            if state.fontScaleAdjustable then fontScaleAdjustable = fontScaleAdjustable + 1 end
        end
    end
    return {
        version = self.version, buildTransactionContractVersion = self.buildTransactionContractVersion, registered = #self.order, created = created, visible = visible, windowed = windowed,
        lockable = lockable, locked = locked, minimizable = minimizable, minimized = minimized, resettable = resettable, opacityAdjustable = opacityAdjustable, appearanceAdjustable = appearanceAdjustable, fontScaleAdjustable = fontScaleAdjustable, quarantined = quarantined,
        stats = {
            creates = tonumber(self.stats.creates) or 0,
            createFailures = tonumber(self.stats.createFailures) or 0,
            visibilityChanges = tonumber(self.stats.visibilityChanges) or 0,
            lockChanges = tonumber(self.stats.lockChanges) or 0,
            layoutResets = tonumber(self.stats.layoutResets) or 0,
            opacityChanges = tonumber(self.stats.opacityChanges) or 0,
            appearanceChanges = tonumber(self.stats.appearanceChanges) or 0,
            responsiveReflows = tonumber(self.stats.responsiveReflows) or 0,
            responsiveFailures = tonumber(self.stats.responsiveFailures) or 0,
            nativeCloseNotifications = tonumber(self.stats.nativeCloseNotifications) or 0,
            nativeCloseCleanupFailures = tonumber(self.stats.nativeCloseCleanupFailures) or 0,
            lifecycleReactions = tonumber(self.stats.lifecycleReactions) or 0,
            lifecycleReactionFailures = tonumber(self.stats.lifecycleReactionFailures) or 0,
            lifecycleBindFailures = tonumber(self.stats.lifecycleBindFailures) or 0,
            closeRequests = tonumber(self.stats.closeRequests) or 0,
            quarantinedRejects = tonumber(self.stats.quarantinedRejects) or 0,
        },
        lifecycleBound = self.lifecycleBound == true,
        featureBindings = (function()
            local count = 0
            for _ in pairs(self.featureBindings or {}) do count = count + 1 end
            return count
        end)(),
    }
end

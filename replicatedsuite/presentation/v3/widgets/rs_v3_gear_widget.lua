------------------------------------------------------------------------
-- Replicated Suite V3 - Gear / Title Screen Buttons
--
-- One configured plan -> one compact draggable button. There is deliberately
-- no shared HUD frame: the controls stay small, direct, and independently
-- placeable while one manager owns lifecycle/handlers and never recreates a
-- physical button ID for a different plan.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local UI = S.UI
local Host = S.UIV3 and S.UIV3.WidgetHost or nil
local Feature = S.Features and S.Features.Gear or nil
if type(UI) ~= "table" or type(Host) ~= "table" or type(Feature) ~= "table" then return end

local WIDGET_ID = "combat.gear.quick"
local DETECT_TASK = "v3_gear_quick_detect"

local function Clamp01(value, fallback)
    return math.max(0, math.min(1, tonumber(value) or tonumber(fallback) or 1))
end

local function LogicalRect(widget)
    if S.Layout ~= nil and type(S.Layout.GetLogicalRect) == "function" then
        local ok, x, y, w, h = pcall(function() return S.Layout:GetLogicalRect(widget) end)
        if ok then return tonumber(x), tonumber(y), tonumber(w), tonumber(h) end
    end
    if widget ~= nil and type(widget.GetEffectiveOffset) == "function" then
        local ok, x, y = pcall(function() return widget:GetEffectiveOffset() end)
        if ok then return tonumber(x), tonumber(y), nil, nil end
    end
    return nil, nil, nil, nil
end

local function ScreenContext()
    local c = S.Layout and S.Layout:GetContext() or nil
    return tonumber(c and (c.logicalWidth or c.width)) or 1024,
        tonumber(c and (c.logicalHeight or c.height)) or 768
end

local function IntersectsScreen(x, y, width, height)
    x, y = tonumber(x), tonumber(y)
    if x == nil or y == nil then return false end
    local sw, sh = ScreenContext()
    width, height = tonumber(width) or 104, tonumber(height) or 26
    return x + width > 0 and y + height > 0 and x < sw and y < sh
end

local function DefaultPosition(index)
    local policy = type(Feature.GetQuickButtonPolicy) == "function" and Feature:GetQuickButtonPolicy() or {}
    if S.Layout ~= nil and type(S.Layout.GetSafeSpawn) == "function" then
        local ok, x, y = pcall(function()
            return S.Layout:GetSafeSpawn(index, policy.width or 104, policy.height or 26, {
                baseX = policy.defaultBaseX or 300,
                baseY = policy.defaultBaseY or 100,
                gapX = policy.gapX or 6,
                gapY = policy.gapY or 4,
                maxColumns = policy.maxColumns or 4,
                edge = 8,
            })
        end)
        if ok and tonumber(x) ~= nil and tonumber(y) ~= nil then return math.floor(x + 0.5), math.floor(y + 0.5) end
    end
    local n = math.max(0, (tonumber(index) or 1) - 1)
    local cols = math.max(1, tonumber(policy.maxColumns) or 4)
    return (tonumber(policy.defaultBaseX) or 300) + (n % cols) * ((tonumber(policy.width) or 104) + (tonumber(policy.gapX) or 0)),
        (tonumber(policy.defaultBaseY) or 100) + math.floor(n / cols) * ((tonumber(policy.height) or 26) + (tonumber(policy.gapY) or 0))
end

local function CreateGearQuickWidget()
    local instance = {
        id = WIDGET_ID,
        visible = false,
        subscribed = false,
        buttons = {},
        rows = {},
    }

    function instance:GetState() return Feature:GetQuickHudProjection() end

    function instance:ApplyAppearance(button)
        if button == nil then return end
        local state = self:GetState()
        UI:SetAlpha(button, Clamp01(state.overallOpacity, 0.94), "v3:gear_quick_buttons")
        if S.Theme ~= nil then
            if type(S.Theme.SetBackgroundOpacity) == "function" then S.Theme:SetBackgroundOpacity(button, Clamp01(state.backgroundOpacity, 1.0)) end
            if type(S.Theme.SetTextOpacity) == "function" then S.Theme:SetTextOpacity(button, Clamp01(state.textOpacity, 1.0)) end
        end
    end

    function instance:ResolvePosition(meta, index)
        local policy = type(Feature.GetQuickButtonPolicy) == "function" and Feature:GetQuickButtonPolicy() or {}
        local width, height = tonumber(policy.width) or 104, tonumber(policy.height) or 26
        if meta.quickPositionCustomized == true and tonumber(meta.quickX) ~= nil and tonumber(meta.quickY) ~= nil then
            -- Keep user coordinates authoritative. On a smaller resolution use
            -- a non-persistent safe display fallback only when the saved button
            -- would be completely unreachable.
            if IntersectsScreen(meta.quickX, meta.quickY, width, height) then return meta.quickX, meta.quickY, true end
        end
        local x, y = DefaultPosition(index)
        return x, y, false
    end

    function instance:PlaceButton(record, meta, index, force)
        local button = record and record.button or nil
        if button == nil then return false end
        if record.dragging == true and force ~= true then return true end
        local x, y, customized = self:ResolvePosition(meta, index)
        if force == true or record.lastX ~= x or record.lastY ~= y or record.customized ~= customized then
            UI:SetAnchor(button, UIParent, x, y, "v3:gear_quick_buttons")
            record.lastX, record.lastY, record.customized = x, y, customized
        end
        return true
    end

    function instance:RegisterSnapRecord(record)
        if record == nil or record.button == nil or record.snapRegistered == true then return record ~= nil end
        local snapId = tostring(record.snapId or "")
        if snapId == "" then return false end
        local options = {
            ensureNow = false,
            snapGroup = "screen_buttons",
            snapKind = "button",
            snapEnabledProvider = function()
                local settings = type(Feature.GetQuickSnapSettings) == "function" and Feature:GetQuickSnapSettings() or nil
                return type(settings) ~= "table" or settings.enabled ~= false
            end,
        }
        local ok = false
        if type(UI.RegisterScreenSnap) == "function" then
            ok = UI:RegisterScreenSnap(snapId, record.button, options) == true
        elseif S.Layout ~= nil and type(S.Layout.RegisterScreenSnap) == "function" then
            ok = S.Layout:RegisterScreenSnap(snapId, record.button, options) == true
        end
        record.snapRegistered = ok
        return ok
    end

    function instance:EnsureButton(meta, index)
        local id = tostring(meta.id)
        local record = self.buttons[id]
        if record ~= nil then return record end
        local policy = type(Feature.GetQuickButtonPolicy) == "function" and Feature:GetQuickButtonPolicy() or {}
        local physicalKey = tostring(meta.storageId or meta.id or index)
        local spawnX, spawnY, spawnCustomized = self:ResolvePosition(meta, index)
        local button = UI:CreateButton("UIParent", "v3_gear_quick_button_" .. physicalKey, tostring(meta.name or "换装"), spawnX, spawnY,
            tonumber(policy.width) or 104, tonumber(policy.height) or 26, 10, false, true, "v3:gear_quick_buttons")
        if button == nil then
            if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Error) == "function" then
                S.DiagnosticsManager:Error("gear_v3", "GEAR_QUICK_BUTTON_CREATE_FAILED", "换装屏幕快捷按钮创建失败", {
                    setId = id, storageId = tostring(meta.storageId or ""), physicalKey = physicalKey,
                })
            end
            return nil
        end
        record = {
            button = button, setId = id, storageId = meta.storageId, configured = meta.configured == true,
            dragging = false, ignoreClick = false, present = true,
            lastX = spawnX, lastY = spawnY, customized = spawnCustomized,
            snapId = "screen_snap:gear:" .. physicalKey, snapRegistered = false,
        }
        self.buttons[id] = record
        button.rsHudOwner = "gear_quick_button"
        self:RegisterSnapRecord(record)
        if button.EnableDrag ~= nil then pcall(function() button:EnableDrag(self:GetState().locked ~= true) end) end
        if button.SetDragCondition ~= nil and DC_ALWAYS ~= nil then pcall(function() button:SetDragCondition(DC_ALWAYS) end) end

        UI:SafeHandler(button, "OnDragStart", function()
            if instance.visible ~= true or instance:GetState().locked == true then return false end
            record.dragging = true
            record.ignoreClick = false
            if type(button.StartMoving) == "function" then button:StartMoving() end
            return true
        end, "v3_gear_quick:drag_start:" .. physicalKey)

        UI:SafeHandler(button, "OnDragStop", function()
            if type(button.StopMovingOrSizing) == "function" then pcall(function() button:StopMovingOrSizing() end) end
            record.dragging = false
            record.ignoreClick = true
            local x, y = LogicalRect(button)
            if x ~= nil and y ~= nil then
                local policy = type(Feature.GetQuickButtonPolicy) == "function" and Feature:GetQuickButtonPolicy() or {}
                local snap = type(Feature.GetQuickSnapSettings) == "function" and Feature:GetQuickSnapSettings()
                    or { enabled = true, distance = tonumber(policy.snapDistance) or 16, gap = 0 }
                instance:RegisterSnapRecord(record)
                if type(UI.CommitScreenSnap) == "function" then
                    local committed, resolvedX, resolvedY = UI:CommitScreenSnap(record.snapId, button, {
                        enabled = snap.enabled == true, group = "screen_buttons", kind = "button",
                        distance = tonumber(snap.distance) or tonumber(policy.snapDistance) or 16,
                        gap = tonumber(snap.gap) or 0, owner = "v3:gear_quick_buttons",
                    })
                    if committed == true and tonumber(resolvedX) ~= nil and tonumber(resolvedY) ~= nil then x, y = resolvedX, resolvedY end
                elseif S.Layout ~= nil and type(S.Layout.ResolveScreenSnap) == "function" then
                    local sx, sy, snapped = S.Layout:ResolveScreenSnap(record.snapId, x, y, tonumber(policy.width) or 104, tonumber(policy.height) or 26, {
                        enabled = snap.enabled == true, group = "screen_buttons", kind = "button",
                        distance = tonumber(snap.distance) or tonumber(policy.snapDistance) or 16, gap = tonumber(snap.gap) or 0,
                    })
                    if snapped == true then x, y = sx, sy; UI:SetAnchor(button, UIParent, x, y, "v3:gear_quick_buttons") end
                end
                local ok = Feature.Commands:SetQuickPosition(record.setId, x, y)
                if ok == true then record.lastX, record.lastY, record.customized = math.floor(x + 0.5), math.floor(y + 0.5), true end
            end
            return true
        end, "v3_gear_quick:drag_stop:" .. physicalKey)

        UI:SafeHandler(button, "OnClick", function()
            if record.dragging == true then return false end
            if record.ignoreClick == true then record.ignoreClick = false; return false end
            local runtime = S.Services.GearV3:GetRuntimeSnapshot()
            if runtime.busy == true or record.configured ~= true then return false end
            return Feature.Commands:Start(record.setId)
        end, "v3_gear_quick:click:" .. physicalKey)
        self:ApplyAppearance(button)
        return record
    end

    function instance:BuildRows()
        local rows = Feature:GetQuickRows()
        self.rows = rows or {}
        return self.rows, S.Services.GearV3:GetRuntimeSnapshot(), Feature:GetCurrentMatch()
    end

    function instance:Refresh()
        local rows, runtime, current = self:BuildRows()
        local seen, createFailures = {}, {}
        for _, record in pairs(self.buttons) do record.present = false end
        for index, meta in ipairs(rows) do
            local id = tostring(meta.id)
            seen[id] = true
            local record = self:EnsureButton(meta, index)
            if record == nil then
                createFailures[#createFailures + 1] = tostring(meta.name or meta.id or index)
            else
                record.present = true
                record.setId = id
                record.configured = meta.configured == true
                self:RegisterSnapRecord(record)
                local running = record.configured and runtime.busy == true and tostring(runtime.setId or "") == id
                local isCurrent = record.configured and current and tostring(current.id or "") == id
                local prefix = running and "▶ " or (isCurrent and "● " or (record.configured and "" or "○ "))
                UI:SetText(record.button, prefix .. tostring(meta.name or "换装"), "v3:gear_quick_buttons")
                UI:SetEnabled(record.button, record.configured and (runtime.busy ~= true or running), "v3:gear_quick_buttons")
                UI:SetButtonActive(record.button, running or isCurrent, "v3:gear_quick_buttons")
                if record.button.EnableDrag ~= nil then pcall(function() record.button:EnableDrag(self:GetState().locked ~= true) end) end
                self:ApplyAppearance(record.button)
                self:PlaceButton(record, meta, index, false)
                UI:SetVisible(record.button, self.visible == true, "v3:gear_quick_buttons")
                if self.visible == true and record.button.Raise ~= nil then pcall(function() record.button:Raise() end) end
            end
        end
        for id, record in pairs(self.buttons) do
            if seen[id] ~= true and record.button ~= nil then UI:SetVisible(record.button, false, "v3:gear_quick_buttons") end
        end
        if #createFailures > 0 then
            return false, "屏幕快捷按钮创建失败：" .. table.concat(createFailures, "、")
        end
        return true
    end

    function instance:ScheduleCurrentDetection(reason, delayMs)
        if self.visible ~= true then return false end
        if S.Scheduler == nil or type(S.Scheduler.AddOneShot) ~= "function" then
            Feature.Commands:DetectCurrentQuickSet(reason or "screen_buttons")
            return self:Refresh()
        end
        S.Scheduler:RemoveTask(DETECT_TASK)
        return S.Scheduler:AddOneShot(DETECT_TASK, tonumber(delayMs) or 260, function()
            if instance.visible ~= true then return true end
            Feature.Commands:DetectCurrentQuickSet(reason or "screen_buttons")
            instance:Refresh()
            return true
        end, self, "P2", 2)
    end

    function instance:Subscribe()
        if self.subscribed == true then return true end
        if S.Events == nil or type(S.Events.SubscribeInternal) ~= "function" or type(S.Events.Subscribe) ~= "function" then
            return false, "gear quick event bus unavailable"
        end
        local internalOk = S.Events:SubscribeInternal("v3.gear.updated", self, function(_, a, b)
            if instance.visible ~= true then return end
            local reason = type(b) == "string" and b or (type(a) == "string" and a or "")
            instance:Refresh()
            if reason:find("current_", 1, true) == nil then instance:ScheduleCurrentDetection("gear_updated", 180) end
        end)
        local equipmentOk = internalOk == true and S.Events:Subscribe("UNIT_EQUIPMENT_CHANGED", self, function() instance:ScheduleCurrentDetection("equipment_changed", 260) end) or false
        local titleOk = equipmentOk == true and S.Events:Subscribe("APPELLATION_CHANGED", self, function() instance:ScheduleCurrentDetection("title_changed", 260) end) or false
        if internalOk ~= true or equipmentOk ~= true or titleOk ~= true then
            if type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
            if type(S.Events.UnsubscribeOwner) == "function" then S.Events:UnsubscribeOwner(self) end
            return false, "gear quick event subscription failed"
        end
        self.subscribed = true
        return true
    end

    function instance:Unsubscribe()
        if S.Events ~= nil then
            if type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
            if type(S.Events.UnsubscribeOwner) == "function" then S.Events:UnsubscribeOwner(self) end
        end
        if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(DETECT_TASK) end
        self.subscribed = false
        return true
    end

    function instance:Show()
        self.visible = true
        local subscribed, subscribeErr = self:Subscribe()
        if subscribed ~= true then
            self.visible = false
            self:Unsubscribe()
            return false, subscribeErr or "gear quick subscribe failed"
        end
        local refreshed, refreshErr = self:Refresh()
        if refreshed ~= true then
            self.visible = false
            self:Unsubscribe()
            return false, refreshErr
        end
        self:ScheduleCurrentDetection("show", 80)
        return true
    end

    function instance:Hide()
        self.visible = false
        self:Unsubscribe()
        for _, record in pairs(self.buttons) do
            record.dragging = false
            if record.button ~= nil then
                if type(record.button.StopMovingOrSizing) == "function" then pcall(function() record.button:StopMovingOrSizing() end) end
                UI:SetVisible(record.button, false, "v3:gear_quick_buttons")
            end
        end
        return true
    end

    function instance:SetLocked(value, persist)
        local ok, err = Feature.Commands:SetQuickHudAppearance("locked", value, persist, "gear_quick_buttons_locked")
        if ok ~= true then return false, err end
        local state = self:GetState()
        for _, record in pairs(self.buttons) do
            if record.button ~= nil and record.button.EnableDrag ~= nil then pcall(function() record.button:EnableDrag(not state.locked) end) end
        end
        return true
    end
    function instance:IsLocked() return self:GetState().locked == true end
    function instance:SetOverallOpacity(value, persist) local ok, err = Feature.Commands:SetQuickHudAppearance("overallOpacity", value, persist, "gear_quick_buttons_overall_opacity"); if ok ~= true then return false, err end; for _, r in pairs(self.buttons) do self:ApplyAppearance(r.button) end; return true end
    function instance:GetOverallOpacity() return Clamp01(self:GetState().overallOpacity, 0.94) end
    function instance:SetOpacity(value) return self:SetOverallOpacity(value) end
    function instance:GetOpacity() return self:GetOverallOpacity() end
    function instance:SetBackgroundOpacity(value, persist) local ok, err = Feature.Commands:SetQuickHudAppearance("backgroundOpacity", value, persist, "gear_quick_buttons_background_opacity"); if ok ~= true then return false, err end; for _, r in pairs(self.buttons) do self:ApplyAppearance(r.button) end; return true end
    function instance:GetBackgroundOpacity() return Clamp01(self:GetState().backgroundOpacity, 1) end
    function instance:SetTextOpacity(value, persist) local ok, err = Feature.Commands:SetQuickHudAppearance("textOpacity", value, persist, "gear_quick_buttons_text_opacity"); if ok ~= true then return false, err end; for _, r in pairs(self.buttons) do self:ApplyAppearance(r.button) end; return true end
    function instance:GetTextOpacity() return Clamp01(self:GetState().textOpacity, 1) end

    function instance:ResetLayout()
        local ok, err = Feature.Commands:ResetQuickPositions()
        if ok ~= true then return false, err end
        return self:Refresh()
    end

    function instance:ApplyLayout()
        return self:Refresh()
    end

    return instance
end

local function StateWindow()
    Feature:EnsureStoreLoaded()
    return Feature:GetQuickHudProjection()
end

local ok, err = Host:Register(WIDGET_ID, {
    featureId = "combat_gear",
    create = CreateGearQuickWidget,
    windowingRequired = false,
    ensurePreferences = function() return Feature:EnsureStoreLoaded() end,
    lockable = true,
    resettable = true,
    opacityAdjustable = true,
    backgroundOpacityAdjustable = true,
    textOpacityAdjustable = true,
    getLocked = function() return StateWindow().locked == true end,
    setLocked = function(value, persist)
        return Feature.Commands:SetQuickHudAppearance("locked", value, persist, "gear_quick_buttons_locked")
    end,
    getOverallOpacity = function() return Clamp01(StateWindow().overallOpacity, 0.94) end,
    setOverallOpacity = function(value, persist)
        return Feature.Commands:SetQuickHudAppearance("overallOpacity", value, persist, "gear_quick_buttons_overall_opacity")
    end,
    getOpacity = function() return Clamp01(StateWindow().overallOpacity, 0.94) end,
    setOpacity = function(value, persist)
        return Feature.Commands:SetQuickHudAppearance("overallOpacity", value, persist, "gear_quick_buttons_overall_opacity")
    end,
    getBackgroundOpacity = function() return Clamp01(StateWindow().backgroundOpacity, 1.0) end,
    setBackgroundOpacity = function(value, persist)
        return Feature.Commands:SetQuickHudAppearance("backgroundOpacity", value, persist, "gear_quick_buttons_background_opacity")
    end,
    getTextOpacity = function() return Clamp01(StateWindow().textOpacity, 1.0) end,
    setTextOpacity = function(value, persist)
        return Feature.Commands:SetQuickHudAppearance("textOpacity", value, persist, "gear_quick_buttons_text_opacity")
    end,
    resetLayout = function()
        local instance = Host:GetInstance(WIDGET_ID)
        if instance and instance.ResetLayout then return instance:ResetLayout() end
        return Feature.Commands:ResetQuickPositions()
    end,
})
if ok ~= true then error(err) end

------------------------------------------------------------------------
-- Presentation-owned visibility reaction.
--
-- Domain publishes `v3.gear.quick.visibility` / `v3.feature.lifecycle` and
-- keeps the service lease; only this file touches WidgetHost visibility.
------------------------------------------------------------------------
if S.Events ~= nil and type(S.Events.SubscribeInternal) == "function" then
    local Reaction = { id = "v3:gear_quick:host_reaction" }
    local function Sync(reason, desired)
        local shouldShow = desired
        if shouldShow == nil then
            shouldShow = type(Feature.ShouldShowQuickButtons) == "function" and Feature:ShouldShowQuickButtons() == true or false
        end
        if shouldShow == Host:IsVisible(WIDGET_ID) then return true end
        local ok, showErr = Host:SetVisible(WIDGET_ID, shouldShow, { persist = false, source = tostring(reason or "gear_sync") })
        if ok ~= true and S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.ErrorRateLimited) == "function" then
            S.DiagnosticsManager:ErrorRateLimited("gear_v3", "GEAR_QUICK_BUTTON_HOST_FAILED", 3000,
                "换装屏幕快捷按钮显示/隐藏失败", { error = tostring(showErr or "unknown"), reason = tostring(reason or "gear_sync") })
        end
        return ok, showErr
    end

    Host:BindFeatureLifecycle(WIDGET_ID, {
        featureId = "combat_gear",
        enabled = function() return S.FeatureRuntime:IsEnabled("combat_gear") == true end,
        preference = function()
            return type(Feature.ShouldShowQuickButtons) == "function" and Feature:ShouldShowQuickButtons() == true or false
        end,
    })
    S.Events:SubscribeInternal("v3.gear.quick.visibility", Reaction, function(_, visible, reason)
        Sync(reason, visible == true)
    end)
    if S.FeatureRuntime:IsEnabled("combat_gear") == true then Sync("screen_button_widget_registered") end
elseif S.FeatureRuntime:IsEnabled("combat_gear") == true and type(Feature.Commands) == "table" and type(Feature.Commands.SyncQuickButtonsHost) == "function" then
    Feature.Commands:SyncQuickButtonsHost("screen_button_widget_registered")
end

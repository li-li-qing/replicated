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

local function PlacementFromMeta(meta)
    if type(meta) ~= "table" or tostring(meta.quickCoordinateSpace or "") ~= "logical-edge-v1" then return nil end
    local anchorH, anchorV = tostring(meta.quickAnchorH or ""), tostring(meta.quickAnchorV or "")
    local offsetX, offsetY = tonumber(meta.quickOffsetX), tonumber(meta.quickOffsetY)
    if (anchorH ~= "LEFT" and anchorH ~= "RIGHT") or (anchorV ~= "TOP" and anchorV ~= "BOTTOM")
        or offsetX == nil or offsetY == nil then return nil end
    return {
        coordinateSpace = "logical-edge-v1",
        anchorH = anchorH,
        anchorV = anchorV,
        offsetX = math.max(0, offsetX),
        offsetY = math.max(0, offsetY),
    }
end

local function BuildEdgePlacement(x, y, width, height)
    x, y = tonumber(x), tonumber(y)
    width, height = math.max(1, tonumber(width) or 104), math.max(1, tonumber(height) or 26)
    if x == nil or y == nil then return nil end
    local context = S.Layout and S.Layout:GetContext() or nil
    local fallbackWidth, fallbackHeight = ScreenContext()
    local sw = tonumber(context and context.logicalWidth) or fallbackWidth
    local sh = tonumber(context and context.logicalHeight) or fallbackHeight
    local safeLeft = tonumber(context and context.safeLeft) or 0
    local safeTop = tonumber(context and context.safeTop) or 0
    local safeRight = tonumber(context and context.safeRight) or 0
    local safeBottom = tonumber(context and context.safeBottom) or 0
    x = math.max(safeLeft, math.min(math.max(safeLeft, sw - safeRight - width), x))
    y = math.max(safeTop, math.min(math.max(safeTop, sh - safeBottom - height), y))
    local anchorH = x + width * 0.5 <= sw * 0.5 and "LEFT" or "RIGHT"
    local anchorV = y + height * 0.5 <= sh * 0.5 and "TOP" or "BOTTOM"
    return {
        coordinateSpace = "logical-edge-v1",
        anchorH = anchorH,
        anchorV = anchorV,
        offsetX = anchorH == "RIGHT" and math.max(0, sw - safeRight - x - width) or math.max(0, x - safeLeft),
        offsetY = anchorV == "BOTTOM" and math.max(0, sh - safeBottom - y - height) or math.max(0, y - safeTop),
    }, x, y
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

    function instance:ResolvePosition(meta, index, record)
        local policy = type(Feature.GetQuickButtonPolicy) == "function" and Feature:GetQuickButtonPolicy() or {}
        local width, height = tonumber(policy.width) or 104, tonumber(policy.height) or 26
        if meta.quickPositionCustomized == true and tonumber(meta.quickX) ~= nil and tonumber(meta.quickY) ~= nil then
            local placement = PlacementFromMeta(meta) or (record and record.legacyPlacement or nil)
            if placement ~= nil and S.Layout ~= nil and type(S.Layout.ResolvePlacement) == "function" then
                local ok, x, y = pcall(function()
                    return S.Layout:ResolvePlacement(placement, width, height, meta.quickX, meta.quickY, { mode = "strict" })
                end)
                if ok and tonumber(x) ~= nil and tonumber(y) ~= nil then return x, y, true end
            end
            -- Historical quickX/quickY rows had no responsive anchor. Preserve
            -- their current location on first show; EnsureButton captures an
            -- in-memory edge anchor so later resolution changes still reflow.
            if IntersectsScreen(meta.quickX, meta.quickY, width, height) then return meta.quickX, meta.quickY, true end
        end
        local x, y = DefaultPosition(index)
        return x, y, false
    end

    function instance:PlaceButton(record, meta, index, force)
        local button = record and record.button or nil
        if button == nil then return false end
        if record.dragging == true and force ~= true then return true end
        local x, y, customized = self:ResolvePosition(meta, index, record)
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
        local spawnX, spawnY, spawnCustomized = self:ResolvePosition(meta, index, nil)
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
        if spawnCustomized == true and PlacementFromMeta(meta) == nil then
            record.legacyPlacement = select(1, BuildEdgePlacement(spawnX, spawnY, tonumber(policy.width) or 104, tonumber(policy.height) or 26))
        end
        self.buttons[id] = record
        button.rsHudOwner = "gear_quick_button"
        self:RegisterSnapRecord(record)
        local function FailInteraction(detail)
            if record.snapRegistered == true and type(UI.UnregisterScreenSnap) == "function" then UI:UnregisterScreenSnap(record.snapId) end
            record.snapRegistered = false
            UI:SetVisible(button, false, "v3:gear_quick_buttons")
            self.buttons[id] = nil
            return nil, tostring(detail or "gear_quick_interaction_failed")
        end
        if type(UI.TryInteractionCall) ~= "function" or type(UI.RequireHandler) ~= "function" then
            return FailInteraction("critical_interaction_contract_unavailable")
        end
        local dragEnabled, dragErr = UI:TryInteractionCall(button, "EnableDrag", self:GetState().locked ~= true)
        if dragEnabled ~= true then return FailInteraction("gear_quick_enable_drag_failed:" .. tostring(dragErr or "rejected")) end
        if button.SetDragCondition ~= nil and DC_ALWAYS ~= nil then
            local conditionOk, conditionErr = UI:TryInteractionCall(button, "SetDragCondition", DC_ALWAYS)
            if conditionOk ~= true then return FailInteraction("gear_quick_drag_condition_failed:" .. tostring(conditionErr or "rejected")) end
        end

        local dragStartBound, dragStartErr = UI:RequireHandler(button, "OnDragStart", function()
            if instance.visible ~= true or instance:GetState().locked == true then return false end
            local moving = UI:TryInteractionCall(button, "StartMoving")
            if moving ~= true then return false end
            record.dragging = true
            record.ignoreClick = false
            return true
        end, "v3_gear_quick:drag_start:" .. physicalKey)

        local dragStopBound, dragStopErr = UI:RequireHandler(button, "OnDragStop", function()
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
                local placement = nil
                if S.Layout ~= nil and type(S.Layout.StorePlacement) == "function" then
                    local captured = {}
                    local storedX, storedY = S.Layout:StorePlacement(captured, button, { mode = "strict" })
                    if tonumber(storedX) ~= nil and tonumber(storedY) ~= nil then
                        x, y = storedX, storedY
                        UI:SetAnchor(button, UIParent, x, y, "v3:gear_quick_buttons")
                    end
                    if tostring(captured.coordinateSpace or "") == "logical-edge-v1" then placement = captured end
                end
                if placement == nil then
                    placement, x, y = BuildEdgePlacement(x, y, tonumber(policy.width) or 104, tonumber(policy.height) or 26)
                    if placement ~= nil then UI:SetAnchor(button, UIParent, x, y, "v3:gear_quick_buttons") end
                end
                record.legacyPlacement = placement
                local ok = Feature.Commands:SetQuickPosition(record.setId, x, y, placement)
                if ok == true then record.lastX, record.lastY, record.customized = math.floor(x + 0.5), math.floor(y + 0.5), true end
            end
            return true
        end, "v3_gear_quick:drag_stop:" .. physicalKey)

        local clickBound, clickErr = UI:RequireHandler(button, "OnClick", function()
            if record.dragging == true then return false end
            if record.ignoreClick == true then record.ignoreClick = false; return false end
            local runtime = S.Services.GearV3:GetRuntimeSnapshot()
            if runtime.busy == true or record.configured ~= true then return false end
            return Feature.Commands:Start(record.setId)
        end, "v3_gear_quick:click:" .. physicalKey)
        if dragStartBound ~= true or dragStopBound ~= true or clickBound ~= true then
            return FailInteraction(dragStartErr or dragStopErr or clickErr or "gear_quick_required_handler_failed")
        end
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
                local interactionOk = true
                if type(UI.EnsureEnabled) == "function" then
                    local enableOk = select(1, UI:EnsureEnabled(record.button, record.configured and (runtime.busy ~= true or running), "v3:gear_quick_buttons"))
                    if enableOk ~= true then interactionOk = false; createFailures[#createFailures + 1] = tostring(meta.name or meta.id or index) .. "(启用状态)" end
                else
                    interactionOk = false
                    createFailures[#createFailures + 1] = tostring(meta.name or meta.id or index) .. "(启用契约)"
                end
                UI:SetButtonActive(record.button, running or isCurrent, "v3:gear_quick_buttons")
                if type(UI.TryInteractionCall) == "function" then
                    local dragOk = UI:TryInteractionCall(record.button, "EnableDrag", self:GetState().locked ~= true)
                    if dragOk ~= true then interactionOk = false; createFailures[#createFailures + 1] = tostring(meta.name or meta.id or index) .. "(拖动状态)" end
                else
                    interactionOk = false
                    createFailures[#createFailures + 1] = tostring(meta.name or meta.id or index) .. "(交互契约)"
                end
                self:ApplyAppearance(record.button)
                self:PlaceButton(record, meta, index, false)
                UI:SetVisible(record.button, self.visible == true and interactionOk, "v3:gear_quick_buttons")
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
        if S.Events == nil or type(S.Events.SubscribeInternal) ~= "function" then
            return false, "gear quick event bus unavailable"
        end
        local internalOk = S.Events:SubscribeInternal("v3.gear.updated", self, function(_, a, b)
            if instance.visible ~= true then return end
            local reason = type(b) == "string" and b or (type(a) == "string" and a or "")
            instance:Refresh()
            if reason:find("current_", 1, true) == nil then instance:ScheduleCurrentDetection("gear_updated", 180) end
        end)
        if internalOk ~= true then
            if type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
            if type(S.Events.UnsubscribeOwner) == "function" then S.Events:UnsubscribeOwner(self) end
            return false, "gear quick event subscription failed"
        end
        -- Native change events are accelerators only. ArcheRage RU builds may
        -- omit one of these names; that must never make the screen buttons fail
        -- to exist. Optional registration degrades to the existing Gear refresh
        -- and bounded current-set detection paths.
        if type(S.Events.SubscribeOptional) == "function" then
            S.Events:SubscribeOptional("UNIT_EQUIPMENT_CHANGED", self, function() instance:ScheduleCurrentDetection("equipment_changed", 260) end)
            S.Events:SubscribeOptional("APPELLATION_CHANGED", self, function() instance:ScheduleCurrentDetection("title_changed", 260) end)
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
            if record.button ~= nil then
                if type(UI.TryInteractionCall) ~= "function" then return false, "critical_interaction_contract_unavailable" end
                local dragOk, dragErr = UI:TryInteractionCall(record.button, "EnableDrag", not state.locked)
                if dragOk ~= true then return false, "gear_quick_drag_state_failed:" .. tostring(dragErr or "rejected") end
            end
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

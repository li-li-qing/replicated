ReplicatedSuiteModuleSandbox:Enter('plates', {'ReplicatedPlates'})
------------------------------------------------------------------------
-- Replicated Plates - v0.4.0 unified HUD layout UI
-- One visual template for target / player. Legacy watch-target HUD removed.
------------------------------------------------------------------------
if ReplicatedPlates == nil or ReplicatedPlates.BootError ~= nil or ReplicatedPlates.Storage == nil then return end
local P = ReplicatedPlates
local S = P.Storage
local settings = S:Get()
local uiGeneration = P.Generation

P.UI = {
    windows = {},
    controls = {},
    calibrationScope = nil,
    layoutEditScope = nil,
    layoutEditKey = nil,
    mockPreviewScope = nil,
    plates = {},
}
local U = P.UI
U.suiteHudEffectiveVisibility = { target = false, player = false }
U.suiteHudPreferredVisibility = { target = nil, player = nil }
U.suiteHudLocked = { target = false, player = false }

local SCOPE_ORDER = { "target", "player" }
local SCOPE_META = {
    target = { title = "目标", accent = { 0.20, 0.58, 0.88 }, unit = "target" },
    player = { title = "自己", accent = { 0.24, 0.82, 0.72 }, unit = "player" },
}

local function SafeHandler(widget, eventName, fn, label)
    if widget == nil or type(widget.SetHandler) ~= "function" then return end
    widget:SetHandler(eventName, function(...)
        if P.Generation ~= uiGeneration then return nil end
        local args = { ... }
        local argCount = select("#", ...)
        local ok, result = xpcall(function() return fn(unpack(args, 1, argCount)) end, P.SafeTraceback)
        if not ok then
            P.SafeChat("UI错误 " .. tostring(label or eventName) .. "：" .. tostring(result))
            return nil
        end
        return result
    end)
end

local function SetPick(widget, enabled)
    if widget == nil then return end
    if widget.Enable ~= nil then pcall(function() widget:Enable(true) end) end
    if widget.EnablePick ~= nil then pcall(function() widget:EnablePick(enabled == true, true) end) end
    if widget.Clickable ~= nil then pcall(function() widget:Clickable(enabled == true, true) end) end
end

local function SetPickSelf(widget, enabled)
    if widget == nil then return end
    if widget.Enable ~= nil then pcall(function() widget:Enable(true) end) end
    if widget.EnablePick ~= nil then pcall(function() widget:EnablePick(enabled == true, false) end) end
    if widget.Clickable ~= nil then pcall(function() widget:Clickable(enabled == true, false) end) end
end

local function CreateBackground(parent, r, g, b, a, layer)
    local bg = parent:CreateColorDrawable(r, g, b, a, layer or "background")
    bg:AddAnchor("TOPLEFT", parent, 0, 0)
    bg:AddAnchor("BOTTOMRIGHT", parent, 0, 0)
    return bg
end

local function CreateLabel(parent, id, text, x, y, width, height, fontSize, align)
    local label = parent:CreateChildWidget("label", P.PhysicalId(id), 0, true)
    label:AddAnchor("TOPLEFT", parent, x or 0, y or 0)
    if label.SetAutoResize ~= nil then label:SetAutoResize(false) end
    label:SetExtent(math.max(1, width or 1), math.max(1, height or 1))
    if label.EnablePick ~= nil then label:EnablePick(false) end
    if label.Clickable ~= nil then label:Clickable(false) end
    label.style:SetFontSize(fontSize or 10)
    label.style:SetAlign(align or ALIGN_LEFT)
    label.style:SetColor(1, 1, 1, 1)
    if label.style.SetOutline ~= nil then label.style:SetOutline(true) end
    if label.style.SetEllipsis ~= nil then pcall(function() label.style:SetEllipsis(false) end) end
    label:SetText(tostring(text or ""))
    label:Show(true)
    return label
end

local function StyleButton(button, width, height, fontSize)
    local colors = {
        { 0.07, 0.14, 0.21, 0.99 },
        { 0.14, 0.29, 0.43, 0.99 },
        { 0.035, 0.08, 0.13, 0.99 },
        { 0.07, 0.08, 0.10, 0.75 },
    }
    button.rpStates = button.rpStates or {}
    if #button.rpStates == 0 then
        for index = 1, 4 do
            local c = colors[index]
            local bg = button:CreateColorDrawable(c[1], c[2], c[3], c[4], "background")
            bg:AddAnchor("TOPLEFT", button, 0, 0)
            bg:AddAnchor("BOTTOMRIGHT", button, 0, 0)
            button.rpStates[index] = bg
        end
        if button.SetNormalBackground ~= nil then
            button:SetNormalBackground(button.rpStates[1])
            button:SetHighlightBackground(button.rpStates[2])
            button:SetPushedBackground(button.rpStates[3])
            button:SetDisabledBackground(button.rpStates[4])
        end
    end
    if button.SetAutoResize ~= nil then button:SetAutoResize(false) end
    button:SetExtent(width, height)
    if button.SetWidth ~= nil then button:SetWidth(width) end
    if button.SetHeight ~= nil then button:SetHeight(height) end
    if button.style ~= nil then
        button.style:SetFontSize(fontSize or 10)
        button.style:SetColor(0.96, 0.94, 0.89, 1)
    end
end

local function CreateButton(parent, id, text, x, y, width, height, fontSize)
    local button = parent:CreateChildWidget("button", P.PhysicalId(id), 0, true)
    button:SetText(tostring(text or ""))
    StyleButton(button, width or 90, height or 26, fontSize or 10)
    button:AddAnchor("TOPLEFT", parent, x or 0, y or 0)
    SetPick(button, true)
    button:Show(true)
    return button
end

local function CreateWindow(id, width, height, x, y, visible, useSystemLayer)
    local window = CreateEmptyWindow(P.PhysicalId(id), "UIParent")
    window:SetExtent(width, height)
    -- Only modal/configuration windows belong on the system layer. Runtime
    -- plates must stay on the normal game UI layer so Backpack/Character/etc.
    -- naturally paint above their compact buff/debuff icons.
    if useSystemLayer == true and window.SetUILayer ~= nil then
        pcall(function() window:SetUILayer("system") end)
    end
    window:AddAnchor("TOPLEFT", "UIParent", x or 0, y or 0)
    if window.CorrectOffsetByScreen ~= nil then pcall(function() window:CorrectOffsetByScreen() end) end
    window:Show(visible == true)
    return window
end

local function SaveWindowPosition(bucketName, widget)
    if widget == nil then return end
    local x, y = nil, nil
    if ReplicatedSuiteEmbedded == true and ReplicatedSuite ~= nil and ReplicatedSuite.Layout ~= nil
        and type(ReplicatedSuite.Layout.GetLogicalRect) == "function" then
        local ok, lx, ly = pcall(function() return ReplicatedSuite.Layout:GetLogicalRect(widget) end)
        if ok then x, y = tonumber(lx), tonumber(ly) end
    end
    if (x == nil or y == nil) and type(widget.GetOffset) == "function" then
        local ok, ox, oy = pcall(function() return widget:GetOffset() end)
        if ok then x, y = tonumber(ox), tonumber(oy) end
    end
    if x == nil or y == nil then return end
    local ok, err = S:UpdatePosition(bucketName, x, y)
    if not ok then
        P.SafeChat("保存位置失败：" .. tostring(err or "unknown"))
        local saved = S:Get()[bucketName]
        if type(saved) == "table" and type(widget.RemoveAllAnchors) == "function" then
            widget:RemoveAllAnchors(); widget:AddAnchor("TOPLEFT", "UIParent", saved.x, saved.y)
        end
    end
end

local function AttachWindowDrag(window, handle, bucketName)
    if handle == nil or type(handle.EnableDrag) ~= "function" then return end
    handle:EnableDrag(true)
    local dragKey = "plates_" .. tostring(bucketName or "window")
    SafeHandler(handle, "OnDragStart", function(self)
        self.rpSafeMoving = false
        if ReplicatedSuiteEmbedded == true and ReplicatedSuite ~= nil and ReplicatedSuite.Layout ~= nil
            and type(ReplicatedSuite.Layout.BeginSafeMove) == "function" then
            local ok, moved = pcall(function()
                return ReplicatedSuite.Layout:BeginSafeMove(dragKey, window, { clamp = true })
            end)
            self.rpSafeMoving = ok and moved == true
        end
        if self.rpSafeMoving ~= true and type(window.StartMoving) == "function" then window:StartMoving() end
        return true
    end, bucketName .. ":drag_start")
    SafeHandler(handle, "OnDragStop", function(self)
        if self.rpSafeMoving == true and ReplicatedSuite ~= nil and ReplicatedSuite.Layout ~= nil
            and type(ReplicatedSuite.Layout.EndSafeMove) == "function" then
            pcall(function() ReplicatedSuite.Layout:EndSafeMove(dragKey, false) end)
        elseif type(window.StopMovingOrSizing) == "function" then
            window:StopMovingOrSizing()
        end
        self.rpSafeMoving = false
        if ReplicatedSuiteEmbedded == true and ReplicatedSuite ~= nil and ReplicatedSuite.Layout ~= nil
            and type(ReplicatedSuite.Layout.EnsureWidgetVisible) == "function" then
            pcall(function() ReplicatedSuite.Layout:EnsureWidgetVisible(window, { onlyWhenVisible = true }) end)
        elseif window.CorrectOffsetByScreen ~= nil then
            pcall(function() window:CorrectOffsetByScreen() end)
        end
        SaveWindowPosition(bucketName, window)
        return true
    end, bucketName .. ":drag_stop")
end

local function AttachResizeGrip(window, bucketName, minWidth, minHeight, maxWidth, maxHeight)
    if window == nil or type(window.StartSizing) ~= "function" then return nil end
    if window.UseResizing ~= nil then pcall(function() window:UseResizing(true) end) end
    if window.SetMinResizingExtent ~= nil then
        pcall(function() window:SetMinResizingExtent(minWidth, minHeight) end)
    end
    if window.SetMaxResizingExtent ~= nil then
        pcall(function() window:SetMaxResizingExtent(maxWidth, maxHeight) end)
    end
    local grip = window:CreateChildWidget("emptywidget", P.PhysicalId(bucketName .. "_resize_grip"), 0, true)
    grip:SetExtent(22, 22)
    grip:AddAnchor("BOTTOMRIGHT", window, -2, -2)
    SetPick(grip, true)
    local mark = CreateLabel(grip, bucketName .. "_resize_mark", "拖", 0, 0, 20, 20, 10, ALIGN_CENTER)
    mark.style:SetColor(0.58, 0.78, 0.94, 0.90)
    if grip.EnableDrag ~= nil then grip:EnableDrag(true) end
    SafeHandler(grip, "OnDragStart", function()
        window:StartSizing("BOTTOMRIGHT")
        return true
    end, bucketName .. ":resize_start")
    SafeHandler(grip, "OnDragStop", function()
        if type(window.StopMovingOrSizing) == "function" then window:StopMovingOrSizing() end
        if window.CorrectOffsetByScreen ~= nil then pcall(function() window:CorrectOffsetByScreen() end) end
        SaveWindowPosition(bucketName, window)
        return true
    end, bucketName .. ":resize_stop")
    return grip
end

local function FormatInteger(value)
    value = math.max(0, math.floor((tonumber(value) or 0) + 0.5))
    local result = tostring(value)
    while true do
        local replaced, count = string.gsub(result, "^(-?%d+)(%d%d%d)", "%1,%2")
        result = replaced
        if count == 0 then break end
    end
    return result
end

local function FormatEffectTime(milliseconds)
    local ms = tonumber(milliseconds) or 0
    if ms <= 0 then return "" end
    local seconds = ms / 1000
    if seconds < 10 then return string.format("%.1f", seconds) end
    if seconds < 60 then return tostring(math.floor(seconds + 0.5)) end
    if seconds < 3600 then return tostring(math.floor(seconds / 60 + 0.5)) .. "m" end
    if seconds < 86400 then return tostring(math.floor(seconds / 3600 + 0.5)) .. "h" end
    return tostring(math.floor(seconds / 86400 + 0.5)) .. "d"
end

local function SetIconPath(icon, path)
    if icon == nil then return false end
    if type(path) ~= "string" or path == "" then
        icon:SetVisible(false)
        return false
    end
    icon:ClearAllTextures()
    icon:AddTexture(path)
    icon:SetVisible(true)
    return true
end

local EFFECT_ACCENT = {
    buff = { 0.24, 0.82, 0.44 },
    debuff = { 0.96, 0.30, 0.28 },
    hidden = { 0.72, 0.38, 0.94 },
    cooldown = { 0.98, 0.66, 0.18 },
}

local function CreateEffectSlot(parent, id, effectType)
    local slot = parent:CreateChildWidget("emptywidget", P.PhysicalId(id), 0, true)
    slot:SetExtent(24, 24)
    SetPick(slot, false)
    local border = slot:CreateColorDrawable(0.010, 0.016, 0.024, 0.30, "background")
    border:AddAnchor("TOPLEFT", slot, 0, 0)
    border:AddAnchor("BOTTOMRIGHT", slot, 0, 0)
    local accent = EFFECT_ACCENT[effectType] or EFFECT_ACCENT.buff
    local edge = slot:CreateColorDrawable(accent[1], accent[2], accent[3], 0.82, "artwork")
    edge:AddAnchor("BOTTOMLEFT", slot, 0, 0)
    edge:SetExtent(24, 2)
    local icon = slot:CreateIconDrawable("artwork")
    icon:SetExtent(22, 22)
    icon:AddAnchor("TOPLEFT", slot, 1, 1)
    icon:SetVisible(false)
    local duration = CreateLabel(slot, id .. "_time", "", 1, 11, 22, 12, 10, ALIGN_CENTER)
    local stack = CreateLabel(slot, id .. "_stack", "", 12, 0, 10, 11, 10, ALIGN_RIGHT)
    stack.style:SetColor(0.48, 0.95, 1.0, 1)
    slot:Show(false)
    local record = {
        frame = slot, border = border, edge = edge, icon = icon, duration = duration, stack = stack,
        effectType = effectType, key = nil, iconPath = nil, durationText = nil, stackText = nil, visible = false,
        tooltipEnabled = false, tooltipText = nil, effect = nil,
    }
    -- HUD icons stay click-through by default. Only an explicitly enabled tooltip
    -- makes the individual icon pickable, so ordinary gameplay input is unaffected.
    SafeHandler(slot, "OnEnter", function(self)
        if record.tooltipEnabled == true and type(record.tooltipText) == "string" and record.tooltipText ~= "" and type(SetTooltip) == "function" then
            SetTooltip(record.tooltipText, self)
        end
    end, id .. ":tooltip")
    return record
end

local function WidgetIsVisible(widget)
    if widget == nil or type(widget.IsVisible) ~= "function" then return nil end
    local ok, visible = pcall(widget.IsVisible, widget)
    if not ok then return nil end
    return visible == true
end

local LAYOUT_HANDLE_LABELS = {
    class = "职业",
    gear = "装等",
    loadout = "甲胄/武器",
    distance = "距离",
    buff = "Buff",
    debuff = "Debuff",
    hidden = "Hidden",
    cast = "施法",
    equipment = "装备",
    cooldown = "重要冷却",
    targetOfTarget = "目标的目标",
}

local function LayoutBucket(scope, key)
    local cfg = S:Get()[scope]
    if type(cfg) ~= "table" then return nil end
    if key == "class" then return cfg.class end
    if key == "gear" then return cfg.gear end
    if key == "loadout" then return cfg.loadout end
    if key == "distance" then return cfg.distance end
    if key == "cast" then return cfg.cast end
    if key == "equipment" then return cfg.equipment end
    if key == "cooldown" then return scope == "player" and cfg.cooldowns or nil end
    if key == "targetOfTarget" then return cfg.targetOfTarget end
    if key == "buff" or key == "debuff" or key == "hidden" then
        return type(cfg.effects) == "table" and cfg.effects[key] or nil
    end
    return nil
end

local function LayoutHandleEnabled(scope, key, cfg)
    if type(cfg) ~= "table" then return false end
    if key == "class" then return scope == "target" and cfg.showClass == true end
    if key == "gear" then return scope == "target" and cfg.showGear == true end
    if key == "loadout" then return scope == "target" and cfg.showLoadout == true end
    if key == "distance" then return cfg.showDistance == true end
    if key == "buff" then return cfg.showBuffs == true end
    if key == "debuff" then return cfg.showDebuffs == true end
    if key == "hidden" then return (scope == "target" or scope == "player") and cfg.showHidden == true end
    if key == "cast" then return scope == "target" and cfg.showCast == true end
    if key == "equipment" then return scope == "player" and cfg.showEquipment == true end
    if key == "cooldown" then return scope == "player" and cfg.showImportantCooldowns == true end
    if key == "targetOfTarget" then return scope == "target" and cfg.showTargetOfTarget == true end
    return false
end

local function SaveDraggedLayoutOffset(state, key, dx, dy)
    local bucket = LayoutBucket(state.scope, key)
    if type(bucket) ~= "table" then return false end
    local oldX, oldY, oldDirty = bucket.offsetX, bucket.offsetY, S.dirty
    bucket.offsetX = math.max(-300, math.min(300, math.floor((tonumber(bucket.offsetX) or 0) + dx + 0.5)))
    bucket.offsetY = math.max(-300, math.min(300, math.floor((tonumber(bucket.offsetY) or 0) + dy + 0.5)))
    S:MarkDirty()
    local ok, err = S:Save(true)
    if not ok then
        bucket.offsetX, bucket.offsetY, S.dirty = oldX, oldY, oldDirty
        P.SafeChat("保存" .. tostring(LAYOUT_HANDLE_LABELS[key] or key) .. "位置失败：" .. tostring(err or "unknown"))
        return false
    end
    return true
end

local function EnsureLayoutHandle(state, key)
    state.layoutHandles = state.layoutHandles or {}
    local existing = state.layoutHandles[key]
    if existing ~= nil then return existing end
    local handle = state.frame:CreateChildWidget("emptywidget", P.PhysicalId(state.scope .. "_layout_handle_" .. key), 0, true)
    handle:SetExtent(64, 22)
    SetPick(handle, false)
    if handle.EnableDrag ~= nil then handle:EnableDrag(false) end
    local bg = handle:CreateColorDrawable(0.10, 0.50, 0.86, 0.22, "artwork")
    bg:AddAnchor("TOPLEFT", handle, 0, 0); bg:AddAnchor("BOTTOMRIGHT", handle, 0, 0)
    local edgeTop = handle:CreateColorDrawable(0.32, 0.78, 1.00, 0.92, "artwork")
    edgeTop:AddAnchor("TOPLEFT", handle, 0, 0); edgeTop:SetExtent(64, 1)
    local edgeBottom = handle:CreateColorDrawable(0.32, 0.78, 1.00, 0.92, "artwork")
    edgeBottom:AddAnchor("BOTTOMLEFT", handle, 0, 0); edgeBottom:SetExtent(64, 1)
    local label = CreateLabel(handle, state.scope .. "_layout_handle_label_" .. key, LAYOUT_HANDLE_LABELS[key] or key, 3, 1, 58, 18, 9, ALIGN_CENTER)
    label.style:SetColor(0.78, 0.92, 1.00, 1)
    handle.rpTop = edgeTop
    handle.rpBottom = edgeBottom
    handle.rpLabel = label
    handle.rpKey = key
    handle:Show(false)

    SafeHandler(handle, "OnDragStart", function(self)
        if U.layoutEditScope ~= state.scope then return false end
        state.dragging = true
        if type(self.StartMoving) == "function" then self:StartMoving() end
        local x, y = self:GetOffset()
        self.rpDragStartX, self.rpDragStartY = tonumber(x) or 0, tonumber(y) or 0
        return true
    end, state.scope .. ":layout:" .. key .. ":drag_start")

    SafeHandler(handle, "OnDragStop", function(self)
        if type(self.StopMovingOrSizing) == "function" then self:StopMovingOrSizing() end
        local x, y = self:GetOffset()
        x, y = tonumber(x), tonumber(y)
        local startX, startY = tonumber(self.rpDragStartX), tonumber(self.rpDragStartY)
        state.dragging = false
        if x ~= nil and y ~= nil and startX ~= nil and startY ~= nil then
            local dx, dy = x - startX, y - startY
            if math.abs(dx) >= 0.5 or math.abs(dy) >= 0.5 then
                SaveDraggedLayoutOffset(state, key, dx, dy)
            end
        end
        self.rpDragStartX, self.rpDragStartY = nil, nil
        U:ApplyPlateLayout(state.scope)
        U:RefreshSettingsText()
        if P.Runtime and type(P.Runtime.ForceScope) == "function" then P.Runtime:ForceScope(state.scope) end
        return true
    end, state.scope .. ":layout:" .. key .. ":drag_stop")

    state.layoutHandles[key] = handle
    return handle
end

local function PlaceLayoutHandle(state, key, x, y, width, height)
    local handle = EnsureLayoutHandle(state, key)
    local cfg = S:Get()[state.scope]
    local active = U.layoutEditScope == state.scope
        and (U.layoutEditKey == nil or U.layoutEditKey == key)
        and LayoutHandleEnabled(state.scope, key, cfg)
    local w = math.max(52, math.floor((tonumber(width) or 52) + 0.5))
    local h = math.max(20, math.floor((tonumber(height) or 20) + 0.5))
    handle:RemoveAllAnchors()
    handle:AddAnchor("TOPLEFT", state.frame, math.floor((tonumber(x) or 0) + 0.5), math.floor((tonumber(y) or 0) + 0.5))
    handle:SetExtent(w, h)
    if handle.rpTop ~= nil then handle.rpTop:SetExtent(w, 1) end
    if handle.rpBottom ~= nil then handle.rpBottom:SetExtent(w, 1) end
    if handle.rpLabel ~= nil then handle.rpLabel:SetExtent(math.max(1, w - 6), math.max(18, h - 2)) end
    if handle.EnableDrag ~= nil then handle:EnableDrag(active) end
    SetPickSelf(handle, active)
    handle:Show(active)
end

local function HideLayoutHandles(state)
    for _, handle in pairs(state.layoutHandles or {}) do
        if handle.EnableDrag ~= nil then handle:EnableDrag(false) end
        SetPick(handle, false)
        handle:Show(false)
    end
end

local function HideEffectSlots(slots)
    for _, slot in ipairs(slots) do
        slot.key, slot.iconPath, slot.durationText, slot.stackText = nil, nil, nil, nil
        local actual = WidgetIsVisible(slot.frame)
        if slot.visible ~= false or actual == true then slot.frame:Show(false) end
        slot.visible = false
        slot.icon:SetVisible(false)
    end
end

local function HealthTone(percent)
    if percent <= 0.25 then return "critical", 0.93, 0.16, 0.16 end
    if percent <= 0.60 then return "warning", 0.97, 0.54, 0.10 end
    return "healthy", 0.16, 0.76, 0.38
end

local function CreatePlate(scope)
    local cfg = settings[scope]
    local meta = SCOPE_META[scope]
    local plate = CreateWindow(scope .. "_plate", cfg.width, 110, 5000, 5000, false, false)
    SetPick(plate, false)
    if plate.EnableDrag ~= nil then plate:EnableDrag(false) end

    -- Normal presentation is deliberately transparent: Plates is a compact
    -- BUFF overlay, not a second unit frame. The panel is only visible while
    -- calibrating so the draggable bounds remain obvious.
    local outer = CreateBackground(plate, 0.010, 0.016, 0.027, 0.72, "background")
    outer:SetVisible(false)
    local inner = plate:CreateColorDrawable(0.030, 0.048, 0.068, 0.48, "background")
    inner:AddAnchor("TOPLEFT", plate, 2, 2)
    inner:AddAnchor("BOTTOMRIGHT", plate, -2, -2)
    inner:SetVisible(false)
    local accent = plate:CreateColorDrawable(meta.accent[1], meta.accent[2], meta.accent[3], 0.92, "artwork")
    accent:AddAnchor("TOPLEFT", plate, 0, 0)
    accent:SetExtent(cfg.width, 2)
    accent:SetVisible(false)

    local scopeBadge = CreateLabel(plate, scope .. "_badge", meta.title, 7, 4, 34, 17, 9, ALIGN_LEFT)
    scopeBadge.style:SetColor(meta.accent[1], meta.accent[2], meta.accent[3], 1)
    local name = CreateLabel(plate, scope .. "_name", meta.title, 42, 3, cfg.width - 108, 18, 12, ALIGN_LEFT)
    local distance = CreateLabel(plate, scope .. "_distance", "", cfg.width - 82, 4, 80, 20, 10, ALIGN_RIGHT)
    if distance.style.SetEllipsis ~= nil then pcall(function() distance.style:SetEllipsis(false) end) end
    distance.style:SetColor(0.68, 0.84, 0.96, 1)

    local hpBg = plate:CreateColorDrawable(0.045, 0.058, 0.073, 1, "background")
    hpBg:AddAnchor("TOPLEFT", plate, 7, 24)
    hpBg:SetExtent(cfg.width - 14, 18)
    local hpFill = plate:CreateColorDrawable(0.16, 0.76, 0.38, 1, "artwork")
    hpFill:AddAnchor("TOPLEFT", plate, 7, 24)
    hpFill:SetExtent(cfg.width - 14, 18)
    local percent = CreateLabel(plate, scope .. "_percent", "100%", 9, 23, 52, 20, 10, ALIGN_LEFT)
    local hpText = CreateLabel(plate, scope .. "_health", "0 / 0", 61, 23, cfg.width - 70, 20, 9, ALIGN_RIGHT)
    scopeBadge:Show(false)
    name:Show(false)
    hpBg:SetVisible(false)
    hpFill:SetVisible(false)
    percent:Show(false)
    hpText:Show(false)

    local classIcon = plate:CreateIconDrawable("artwork")
    classIcon:SetExtent(22, 22); classIcon:SetVisible(false)
    local className = CreateLabel(plate, scope .. "_class", "", 35, 0, cfg.width - 40, 26, 12, ALIGN_LEFT)
    className:Show(false)
    local gear = CreateLabel(plate, scope .. "_gear", "", 2, 0, math.floor(cfg.width * 0.50) - 6, 24, 12, ALIGN_LEFT)
    gear:Show(false)
    local loadout = CreateLabel(plate, scope .. "_loadout", "", 2, 0, cfg.width - 4, 22, 11, ALIGN_LEFT)
    loadout:Show(false)
    local loadoutIcons = {}
    for index = 1, 2 do
        local icon = plate:CreateIconDrawable("artwork")
        icon:SetExtent(22, 22); icon:SetVisible(false)
        loadoutIcons[index] = icon
    end
    local targetOfTarget = CreateLabel(plate, scope .. "_target_of_target", "", 8, 0, cfg.width - 16, 20, 9, ALIGN_LEFT)
    targetOfTarget.style:SetColor(0.96, 0.78, 0.36, 1); targetOfTarget:Show(false)

    local state = {
        scope = scope,
        meta = meta,
        frame = plate,
        visible = false,
        dragging = false,
        outer = outer,
        inner = inner,
        accent = accent,
        name = name,
        distance = distance,
        healthBg = hpBg,
        healthFill = hpFill,
        percent = percent,
        healthText = hpText,
        metadata = { classIcon = classIcon, className = className, gear = gear, loadout = loadout, loadoutIcons = loadoutIcons, loadoutCount = 0, targetOfTarget = targetOfTarget, lastClassKey = nil, lastClassIcon = nil, lastGear = nil, lastGearTone = nil, lastLoadout = nil, loadoutVisible = false, lastTargetOfTarget = nil, targetOfTargetVisible = false },
        equipment = { slots = {}, lastSignature = nil },
        captions = {},
        effectSlots = { buff = {}, debuff = {}, hidden = {}, cooldown = {} },
        effectCounts = { buff = 0, debuff = 0, hidden = 0, cooldown = 0 },
        cooldownSnapshots = {},
        cast = {},
        layoutHeight = 48,
        layoutHandles = {},
        last = { name = nil, healthText = nil, percentText = nil, distanceText = nil, distanceTone = nil, fillWidth = -1, healthTone = nil },
    }

    if scope == "player" then
        local equipmentDefs = {
            { key = "glider", short = "G" }, { key = "mainhand", short = "M" },
            { key = "offhand", short = "O" }, { key = "ranged", short = "R" },
        }
        for _, def in ipairs(equipmentDefs) do
            local frame = plate:CreateChildWidget("emptywidget", P.PhysicalId(scope .. "_equipment_" .. def.key), 0, true)
            frame:SetExtent(26, 26); SetPick(frame, false); frame:Show(false)
            local bg = frame:CreateColorDrawable(0.010, 0.016, 0.024, 0.28, "background")
            bg:AddAnchor("TOPLEFT", frame, 0, 0); bg:AddAnchor("BOTTOMRIGHT", frame, 0, 0)
            local icon = frame:CreateIconDrawable("artwork")
            icon:SetExtent(24, 24); icon:AddAnchor("TOPLEFT", frame, 1, 1); icon:SetVisible(false)
            local grade = frame:CreateIconDrawable("artwork")
            grade:SetExtent(24, 24); grade:AddAnchor("CENTER", icon, 0, 0); grade:SetVisible(false)
            local badge = CreateLabel(frame, scope .. "_equipment_badge_" .. def.key, def.short, 1, 0, 10, 10, 7, ALIGN_LEFT)
            badge.style:SetColor(0.78, 0.88, 0.98, 1)
            badge:Show(false)
            state.equipment.slots[def.key] = { frame = frame, icon = icon, grade = grade, badge = badge, iconPath = nil, gradePath = nil, visible = false }
        end
    end

    -- Magic-circle distance label (report 八-P1-1). Anchored to the plate
    -- frame itself: it follows every position tick automatically and hides
    -- with the plate, so no separate HideAll entry is needed. Icon + text are
    -- a single child group so alpha applies to both.
    if scope == "player" then
        local mcGroup = plate:CreateChildWidget("emptywidget", P.PhysicalId("player_magiccircle"), 0, true)
        mcGroup:SetExtent(120, 26)
        SetPick(mcGroup, false)
        if mcGroup.Clickable ~= nil then pcall(function() mcGroup:Clickable(false) end) end
        local mcIcon = mcGroup:CreateIconDrawable("artwork")
        mcIcon:SetExtent(22, 22)
        mcIcon:AddAnchor("LEFT", mcGroup, 0, 0)
        mcIcon:SetVisible(false)
        local mcLabel = CreateLabel(mcGroup, "player_magiccircle_text", "", 26, 0, 92, 22, 11, ALIGN_LEFT)
        mcLabel.style:SetColor(1, 1, 1, 1)
        mcGroup:Show(false)
        state.magicCircle = { frame = mcGroup, icon = mcIcon, label = mcLabel, iconPath = nil, lastText = nil, lastTone = nil }
    end

    local MAX_EFFECT_SLOTS = 12
    local supportedEffects = (scope == "player" or scope == "target") and { "buff", "debuff", "hidden" } or { "buff", "debuff" }
    if scope == "player" then supportedEffects[#supportedEffects + 1] = "cooldown" end
    for _, effectType in ipairs(supportedEffects) do
        for index = 1, MAX_EFFECT_SLOTS do
            state.effectSlots[effectType][index] = CreateEffectSlot(plate, scope .. "_" .. effectType .. "_" .. tostring(index), effectType)
        end
    end

    local castBg = plate:CreateColorDrawable(0.040, 0.052, 0.072, 1, "background")
    local castFill = plate:CreateColorDrawable(0.33, 0.58, 0.97, 1, "artwork")
    -- Drawables are visible immediately after creation on the RU client.  The
    -- old code only hid the icon here, so selecting any target (including self)
    -- could expose an empty 272x16 casting bar until the casting lane ran.  A
    -- cast is opt-in visual state: every cast primitive starts hidden and
    -- UpdateCasting() is the only Authority allowed to show it.
    castBg:SetVisible(false)
    castFill:SetVisible(false)
    local castIcon = plate:CreateIconDrawable("artwork")
    castIcon:SetExtent(20, 20)
    castIcon:SetVisible(false)
    local castName = CreateLabel(plate, scope .. "_cast_name", "", 32, 0, cfg.width - 92, 20, 9, ALIGN_LEFT)
    local castTime = CreateLabel(plate, scope .. "_cast_time", "", cfg.width - 55, 0, 48, 20, 9, ALIGN_RIGHT)
    castName:Show(false)
    castTime:Show(false)
    state.cast = {
        bg = castBg, fill = castFill, icon = castIcon, name = castName, time = castTime,
        y = 0, visible = false, lastName = nil, lastIconPath = nil, lastFillWidth = -1, lastTimeText = nil, lastTone = nil,
    }

    SafeHandler(plate, "OnDragStart", function(self)
        if U.calibrationScope ~= scope then return false end
        if ReplicatedSuiteEmbedded == true and U.suiteHudLocked[scope] == true then return false end
        state.dragging = true
        self.rpSafeMoving = false
        if ReplicatedSuiteEmbedded == true and ReplicatedSuite ~= nil and ReplicatedSuite.Layout ~= nil
            and type(ReplicatedSuite.Layout.BeginSafeMove) == "function" then
            local ok, moved = pcall(function()
                return ReplicatedSuite.Layout:BeginSafeMove("plates_calibration_" .. tostring(scope), self, { clamp = true })
            end)
            self.rpSafeMoving = ok and moved == true
        end
        if self.rpSafeMoving ~= true and type(self.StartMoving) == "function" then self:StartMoving() end
        return true
    end, scope .. ":drag_start")

    SafeHandler(plate, "OnDragStop", function(self)
        if self.rpSafeMoving == true and ReplicatedSuite ~= nil and ReplicatedSuite.Layout ~= nil
            and type(ReplicatedSuite.Layout.EndSafeMove) == "function" then
            pcall(function() ReplicatedSuite.Layout:EndSafeMove("plates_calibration_" .. tostring(scope), false) end)
        elseif type(self.StopMovingOrSizing) == "function" then
            self:StopMovingOrSizing()
        end
        self.rpSafeMoving = false
        state.dragging = false
        local runtime = P.Runtime
        local runtimeState = type(runtime) == "table" and type(runtime.scopes) == "table" and runtime.scopes[scope] or nil
        if type(runtimeState) ~= "table" or runtimeState.positionValid ~= true or runtimeState.identityValid ~= true then return true end
        local x, y = nil, nil
        if ReplicatedSuiteEmbedded == true and ReplicatedSuite ~= nil and ReplicatedSuite.Layout ~= nil
            and type(ReplicatedSuite.Layout.GetLogicalRect) == "function" then
            local ok, lx, ly = pcall(function() return ReplicatedSuite.Layout:GetLogicalRect(self) end)
            if ok then x, y = tonumber(lx), tonumber(ly) end
        end
        if (x == nil or y == nil) and type(self.GetOffset) == "function" then
            local ok, ox, oy = pcall(function() return self:GetOffset() end)
            if ok then x, y = tonumber(ox), tonumber(oy) end
        end
        if x == nil or y == nil then return true end
        local current = S:Get()[scope]
        local oldX, oldY, oldDirty = current.offsetX, current.offsetY, S.dirty
        current.offsetX = math.max(-1200, math.min(1200, math.floor(x - runtimeState.lastScreenX + 0.5)))
        if current.anchorMode == "BOTTOM" then
            local frameHeight = tonumber(state.layoutHeight) or 0
            current.offsetY = math.max(-1200, math.min(1200, math.floor(y + frameHeight - runtimeState.lastScreenY + 0.5)))
        else
            current.offsetY = math.max(-1200, math.min(1200, math.floor(y - runtimeState.lastScreenY + 0.5)))
        end
        S:MarkDirty()
        local ok, err = S:Save(true)
        if not ok then
            current.offsetX, current.offsetY, S.dirty = oldX, oldY, oldDirty
            P.SafeChat("保存" .. meta.title .. "血条偏移失败：" .. tostring(err or "unknown"))
        end
        U:RefreshSettingsText()
        if type(runtime.ForceScope) == "function" then runtime:ForceScope(scope) end
        return true
    end, scope .. ":drag_stop")

    U.plates[scope] = state
    U.windows[scope .. "Plate"] = plate
    return state
end

for _, scope in ipairs(SCOPE_ORDER) do CreatePlate(scope) end

local function EffectRowEnabled(scope, effectType, cfg)
    if effectType == "buff" then return cfg.showBuffs == true end
    if effectType == "debuff" then return cfg.showDebuffs == true end
    if effectType == "cooldown" then return scope == "player" and cfg.showImportantCooldowns == true end
    return (scope == "player" or scope == "target") and cfg.showHidden == true
end

local function EffectMaximum(scope, effectType)
    if effectType == "cooldown" then
        local cfg = S:Get()[scope]
        local layout = type(cfg) == "table" and cfg.cooldowns or nil
        return math.max(1, math.min(12, math.floor(tonumber(type(layout) == "table" and layout.maxCount or 8) or 8)))
    end
    return S:GetEffectLimit(scope, effectType)
end

local function EffectLayout(scope, effectType)
    if effectType == "cooldown" then
        local cfg = S:Get()[scope]
        return type(cfg) == "table" and cfg.cooldowns or nil
    end
    return S:GetEffectLayout(scope, effectType)
end

local function LayoutEffectSlots(state, effectType, y, cfg)
    local slots = state.effectSlots[effectType]
    local maximum = EffectMaximum(state.scope, effectType)
    local layout = EffectLayout(state.scope, effectType)
    if type(layout) ~= "table" then HideEffectSlots(slots); return 0, nil end

    local iconSize = tonumber(layout.iconSize) or 24
    local fontSize = math.max(8, math.min(18, math.floor((tonumber(layout.fontSize) or 10) + 0.5)))
    local gap = math.max(0, math.floor((tonumber(layout.gap) or 2) + 0.5))
    local rowGap = math.max(0, math.floor((tonumber(layout.rowGap) or gap) + 0.5))
    local count = math.max(0, math.min(maximum, tonumber(state.effectCounts and state.effectCounts[effectType]) or 0))
    if U.layoutEditScope == state.scope then count = math.max(1, maximum) end
    if count <= 0 then
        for _, slot in ipairs(slots) do slot.frame:RemoveAllAnchors() end
        return 0, nil
    end

    local baseX = 2 + (tonumber(layout.offsetX) or 0)
    local baseY = y + (tonumber(layout.offsetY) or 0)
    local direction = tostring(layout.direction or "RIGHT")
    local boxX, boxY, boxW, boxH = baseX, baseY, iconSize, iconSize

    if direction == "RIGHT" or direction == "LEFT" then
        local fit = math.max(1, math.floor(math.max(1, cfg.width - 4) / math.max(1, iconSize + gap)))
        local columns = math.max(1, math.min(fit, math.floor(tonumber(layout.columns) or 6)))
        local rows = math.max(1, math.ceil(count / columns))
        local usedColumns = math.min(columns, count)
        boxW = usedColumns * iconSize + math.max(0, usedColumns - 1) * gap
        boxH = rows * iconSize + math.max(0, rows - 1) * rowGap
        if direction == "LEFT" then
            baseX = cfg.width - 2 - iconSize + (tonumber(layout.offsetX) or 0)
            boxX = baseX - boxW + iconSize
        end
        for index, slot in ipairs(slots) do
            slot.frame:RemoveAllAnchors()
            if index <= maximum then
                local zero = index - 1
                local row = math.floor(zero / columns)
                local col = zero % columns
                local dx = col * (iconSize + gap)
                if direction == "LEFT" then dx = -dx end
                local dy = row * (iconSize + rowGap)
                slot.frame:SetExtent(iconSize, iconSize)
                slot.frame:AddAnchor("TOPLEFT", state.frame, baseX + dx, baseY + dy)
                slot.icon:SetExtent(math.max(1, iconSize - 2), math.max(1, iconSize - 2))
                slot.duration.style:SetFontSize(fontSize); slot.stack.style:SetFontSize(fontSize)
                slot.duration:RemoveAllAnchors(); slot.duration:AddAnchor("BOTTOMLEFT", slot.frame, 1, -1)
                slot.duration:SetExtent(math.max(1, iconSize - 2), math.max(11, fontSize + 4))
                slot.stack:RemoveAllAnchors(); slot.stack:AddAnchor("TOPRIGHT", slot.frame, -1, 0)
                slot.stack:SetExtent(math.max(10, math.floor(iconSize * 0.56)), math.max(11, fontSize + 3))
                slot.edge:SetExtent(iconSize, 2)
            end
        end
    else
        local span = count * iconSize + math.max(0, count - 1) * rowGap
        boxW, boxH = iconSize, span
        if direction == "UP" then
            baseY = baseY + span - iconSize
            boxY = baseY - span + iconSize
        end
        for index, slot in ipairs(slots) do
            slot.frame:RemoveAllAnchors()
            if index <= maximum then
                local dy = (index - 1) * (iconSize + rowGap)
                if direction == "UP" then dy = -dy end
                slot.frame:SetExtent(iconSize, iconSize)
                slot.frame:AddAnchor("TOPLEFT", state.frame, baseX, baseY + dy)
                slot.icon:SetExtent(math.max(1, iconSize - 2), math.max(1, iconSize - 2))
                slot.duration.style:SetFontSize(fontSize); slot.stack.style:SetFontSize(fontSize)
                slot.duration:RemoveAllAnchors(); slot.duration:AddAnchor("BOTTOMLEFT", slot.frame, 1, -1)
                slot.duration:SetExtent(math.max(1, iconSize - 2), math.max(11, fontSize + 4))
                slot.stack:RemoveAllAnchors(); slot.stack:AddAnchor("TOPRIGHT", slot.frame, -1, 0)
                slot.stack:SetExtent(math.max(10, math.floor(iconSize * 0.56)), math.max(11, fontSize + 3))
                slot.edge:SetExtent(iconSize, 2)
            end
        end
    end
    return boxH, { x = boxX, y = boxY, width = boxW, height = boxH }
end

local function EquipmentEnabled(cfg, key)
    local eq = cfg.equipment
    if type(eq) ~= "table" then return false end
    if key == "glider" then return eq.showGlider == true end
    if key == "mainhand" then return eq.showMainhand == true end
    if key == "offhand" then return eq.showOffhand == true end
    if key == "ranged" then return eq.showRanged == true end
    return false
end

local EQUIPMENT_ORDER = { "glider", "mainhand", "offhand", "ranged" }

local function LayoutEquipment(state, y, cfg)
    if state.scope ~= "player" or cfg.showEquipment ~= true or type(cfg.equipment) ~= "table" then
        for _, slot in pairs(state.equipment.slots or {}) do
            slot.visible = false
            slot.frame:Show(false)
        end
        return 0, nil
    end
    local eq, size, gap = cfg.equipment, tonumber(cfg.equipment.iconSize) or 26, 3
    local baseX, baseY = 2 + (tonumber(eq.offsetX) or 0), y + (tonumber(eq.offsetY) or 0)
    if eq.direction == "LEFT" then baseX = cfg.width - 2 - size + (tonumber(eq.offsetX) or 0) end
    local enabledCount = 0
    for _, equipmentKey in ipairs(EQUIPMENT_ORDER) do if EquipmentEnabled(cfg, equipmentKey) then enabledCount = enabledCount + 1 end end
    local rowSpan = math.max(size, enabledCount * (size + gap) - gap)
    if eq.direction == "UP" and enabledCount > 0 then baseY = baseY + rowSpan - size end
    local visibleIndex = 0
    for _, key in ipairs(EQUIPMENT_ORDER) do
        local slot = state.equipment.slots[key]
        if slot ~= nil then
            slot.frame:RemoveAllAnchors(); slot.frame:SetExtent(size, size)
            slot.icon:SetExtent(math.max(1, size - 2), math.max(1, size - 2)); slot.grade:SetExtent(math.max(1, size - 2), math.max(1, size - 2))
            if EquipmentEnabled(cfg, key) then
                visibleIndex = visibleIndex + 1
                local dx, dy = 0, 0
                if eq.direction == "LEFT" then dx = -(visibleIndex - 1) * (size + gap)
                elseif eq.direction == "DOWN" then dy = (visibleIndex - 1) * (size + gap)
                elseif eq.direction == "UP" then dy = -(visibleIndex - 1) * (size + gap)
                else dx = (visibleIndex - 1) * (size + gap) end
                slot.frame:AddAnchor("TOPLEFT", state.frame, baseX + dx, baseY + dy)
            else slot.visible = false; slot.frame:Show(false) end
        end
    end
    if visibleIndex == 0 then return 0, nil end
    local boxX, boxY, boxW, boxH = baseX, baseY, rowSpan, size
    local vertical = eq.direction == "UP" or eq.direction == "DOWN"
    if eq.direction == "LEFT" then boxX = baseX - rowSpan + size end
    if eq.direction == "UP" then boxY = baseY - rowSpan + size end
    if vertical then boxW, boxH = size, rowSpan end
    local verticalSpan = vertical and rowSpan or size
    return verticalSpan, { x = boxX, y = boxY, width = boxW, height = boxH }
end

function U:ApplyPlateLayout(scope)
    local state = self.plates[scope]
    local cfg = S:Get()[scope]
    if state == nil or cfg == nil then return end
    local frame = state.frame
    local y = 1
    local sectionGap = math.max(0, math.min(20, tonumber(cfg.sectionGap) or 4))
    HideLayoutHandles(state)
    frame:SetExtent(cfg.width, 48)
    state.accent:SetExtent(cfg.width, 2)
    -- Runtime still reads HP as a validity signal, but the visible overlay is
    -- icon-first and does not duplicate the native unit name/health frame.
    state.name:Show(false)
    state.healthBg:SetVisible(false)
    state.healthFill:SetVisible(false)
    state.percent:Show(false)
    state.healthText:Show(false)
    local distanceCfg = cfg.distance or { fontSize = 12, offsetX = 0, offsetY = 0, warningAt = 25, dangerAt = 30 }
    local distanceFont = math.max(8, math.min(24, tonumber(distanceCfg.fontSize) or 12))
    state.distance.style:SetFontSize(distanceFont)
    if state.distance.style.SetEllipsis ~= nil then pcall(function() state.distance.style:SetEllipsis(false) end) end
    state.healthBg:SetExtent(cfg.width - 14, 18)
    state.healthText:SetExtent(cfg.width - 70, 20)

    -- Target metadata has deterministic rows.  The whole target plate also sits
    -- farther above the native nameplate by default (Schema 9), so a clean
    -- profile cannot overlap the game's name/HP frame.
    if scope == "target" then
        local meta = state.metadata
        local classCfg = type(cfg.class) == "table" and cfg.class or {}
        local gearCfg = type(cfg.gear) == "table" and cfg.gear or {}
        local loadoutCfg = type(cfg.loadout) == "table" and cfg.loadout or {}
        local classSize = math.max(18, math.min(36, tonumber(classCfg.iconSize) or 26))
        local classFont = math.max(9, math.min(20, tonumber(classCfg.fontSize) or 12))
        local gearFont = math.max(9, math.min(20, tonumber(gearCfg.fontSize) or 12))
        local loadoutFont = math.max(9, math.min(20, tonumber(loadoutCfg.fontSize) or 11))
        local loadoutIconSize = math.max(18, math.min(30, loadoutFont + 10))

        meta.className.style:SetFontSize(classFont)
        meta.gear.style:SetFontSize(gearFont)
        meta.loadout.style:SetFontSize(loadoutFont)

        if cfg.showClass == true then
            local classRowY = y
            local classRowHeight = math.max(classSize, classFont + 8)
            local classX = 2 + (tonumber(classCfg.offsetX) or 0)
            local classY = classRowY + (tonumber(classCfg.offsetY) or 0)
            meta.classIcon:SetExtent(classSize, classSize)
            meta.classIcon:RemoveAllAnchors(); meta.classIcon:AddAnchor("TOPLEFT", frame, classX, classY)
            meta.className:RemoveAllAnchors(); meta.className:AddAnchor("TOPLEFT", frame, classX + classSize + 5, classY)
            meta.className:SetExtent(math.max(60, cfg.width - classSize - 11), classRowHeight)
            PlaceLayoutHandle(state, "class", classX, classY, cfg.width - 4, classRowHeight)
            -- Component offset is visual-only. It must never feed back into the
            -- flow cursor, otherwise dragging one element expands the outer HUD
            -- and pushes every component after it.
            y = y + classRowHeight + sectionGap
        else
            meta.classIcon:SetVisible(false); meta.className:Show(false)
        end

        if cfg.showGear == true or cfg.showDistance == true then
            local infoRowY = y
            local infoRowHeight = math.max(22, math.max(gearFont, distanceFont) + 8)
            -- Reserve a center gutter.  Each side owns its own fixed area, so
            -- changing font size cannot make gear score and distance collide.
            local gutter = 12
            local halfWidth = math.floor((cfg.width - gutter - 4) / 2)
            if cfg.showGear == true then
                local gearX = 2 + (tonumber(gearCfg.offsetX) or 0)
                local gearY = infoRowY + (tonumber(gearCfg.offsetY) or 0)
                meta.gear:RemoveAllAnchors(); meta.gear:AddAnchor("TOPLEFT", frame, gearX, gearY)
                meta.gear:SetExtent(halfWidth, infoRowHeight)
                PlaceLayoutHandle(state, "gear", gearX, gearY, halfWidth, infoRowHeight)
            else
                meta.gear:Show(false)
            end
            if cfg.showDistance == true then
                local distanceX = cfg.width - halfWidth - 2 + (tonumber(distanceCfg.offsetX) or 0)
                local distanceY = infoRowY + (tonumber(distanceCfg.offsetY) or 0)
                state.distance:RemoveAllAnchors()
                state.distance:AddAnchor("TOPLEFT", frame, distanceX, distanceY)
                state.distance:SetExtent(halfWidth, infoRowHeight)
                PlaceLayoutHandle(state, "distance", distanceX, distanceY, halfWidth, infoRowHeight)
            end
            -- Gear/distance share one nominal row. Their independent offsets are
            -- presentation coordinates only and cannot resize/reflow the HUD.
            y = y + infoRowHeight + sectionGap
        else
            meta.gear:Show(false)
        end

        -- Do not reserve an empty row while the target's equipment-state buffs
        -- are temporarily unavailable. The row appears as soon as a proven
        -- cloth/leather/plate or weapon-style state is observed. Layout edit mode
        -- still reserves it so the user can position the component.
        local wantLoadoutRow = cfg.showLoadout == true and (meta.loadoutVisible == true or self.layoutEditScope == scope)
        if wantLoadoutRow then
            local loadoutHeight = loadoutIconSize
            local loadoutX = 2 + (tonumber(loadoutCfg.offsetX) or 0)
            local loadoutY = y + (tonumber(loadoutCfg.offsetY) or 0)
            local visibleCount = math.max(1, tonumber(meta.loadoutCount) or 0)
            for index, icon in ipairs(meta.loadoutIcons or {}) do
                icon:SetExtent(loadoutIconSize, loadoutIconSize)
                icon:RemoveAllAnchors(); icon:AddAnchor("TOPLEFT", frame, loadoutX + (index - 1) * (loadoutIconSize + 4), loadoutY)
            end
            local handleWidth = math.max(loadoutIconSize, visibleCount * loadoutIconSize + math.max(0, visibleCount - 1) * 4)
            PlaceLayoutHandle(state, "loadout", loadoutX, loadoutY, handleWidth, loadoutHeight)
            y = y + loadoutHeight + sectionGap
        else
            meta.loadout:Show(false)
            for _, icon in ipairs(meta.loadoutIcons or {}) do icon:SetVisible(false) end
        end
    else
        state.metadata.classIcon:SetVisible(false); state.metadata.className:Show(false); state.metadata.gear:Show(false); state.metadata.loadout:Show(false)
        for _, icon in ipairs(state.metadata.loadoutIcons or {}) do icon:SetVisible(false) end
        if cfg.showDistance == true then
            local distanceWidth = math.max(90, math.min(cfg.width - 4, 72 + distanceFont * 5))
            local distanceRowHeight = math.max(22, distanceFont + 8)
            local distanceX = cfg.width - distanceWidth - 2 + (tonumber(distanceCfg.offsetX) or 0)
            local distanceY = y + (tonumber(distanceCfg.offsetY) or 0)
            state.distance:RemoveAllAnchors()
            state.distance:AddAnchor("TOPLEFT", frame, distanceX, distanceY)
            state.distance:SetExtent(distanceWidth, distanceRowHeight)
            PlaceLayoutHandle(state, "distance", distanceX, distanceY, distanceWidth, distanceRowHeight)
            y = y + distanceRowHeight + 3
        end
    end

    if scope == "target" and cfg.showTargetOfTarget == true then
        local totCfg = type(cfg.targetOfTarget) == "table" and cfg.targetOfTarget or { fontSize = 9, offsetX = 0, offsetY = 0 }
        local totFont = math.max(8, math.min(18, tonumber(totCfg.fontSize) or 9))
        local totHeight = math.max(20, totFont + 8)
        local totX = 8 + (tonumber(totCfg.offsetX) or 0)
        local totY = y + (tonumber(totCfg.offsetY) or 0)
        state.metadata.targetOfTarget.style:SetFontSize(totFont)
        state.metadata.targetOfTarget:RemoveAllAnchors(); state.metadata.targetOfTarget:AddAnchor("TOPLEFT", frame, totX, totY)
        state.metadata.targetOfTarget:SetExtent(cfg.width - 16, totHeight)
        PlaceLayoutHandle(state, "targetOfTarget", totX, totY, cfg.width - 16, totHeight)
        y = y + totHeight + 2
    else state.metadata.targetOfTarget:Show(false) end

    local equipmentSpan, equipmentBox = LayoutEquipment(state, y, cfg)
    if equipmentBox ~= nil then
        PlaceLayoutHandle(state, "equipment", equipmentBox.x, equipmentBox.y, equipmentBox.width, equipmentBox.height)
    end
    if equipmentSpan > 0 then
        -- The equipment strip owns only its nominal flow span. Moving it with
        -- offsetY must not move cooldown/Buff/Debuff lanes below it.
        y = y + equipmentSpan + sectionGap
    end

    if scope == "player" and EffectRowEnabled(scope, "cooldown", cfg) then
        local cooldownSpan, cooldownBox = LayoutEffectSlots(state, "cooldown", y, cfg)
        if cooldownBox ~= nil then PlaceLayoutHandle(state, "cooldown", cooldownBox.x, cooldownBox.y, cooldownBox.width, cooldownBox.height) end
        if cooldownSpan > 0 then
            y = y + cooldownSpan + sectionGap
        end
    elseif state.effectSlots.cooldown ~= nil then
        HideEffectSlots(state.effectSlots.cooldown)
    end

    for _, effectType in ipairs({ "buff", "debuff", "hidden" }) do
        local layout = S:GetEffectLayout(scope, effectType)
        local caption = state.captions[effectType]
        local iconSize = type(layout) == "table" and (tonumber(layout.iconSize) or 24) or 24
        if caption == nil then
            local text = effectType == "buff" and "B" or (effectType == "debuff" and "D" or "H")
            caption = CreateLabel(frame, scope .. "_" .. effectType .. "_caption", text, 6, y, 11, iconSize, 8, ALIGN_CENTER)
            local c = EFFECT_ACCENT[effectType]; caption.style:SetColor(c[1], c[2], c[3], 1)
            state.captions[effectType] = caption
        end
        caption:Show(false)
        if EffectRowEnabled(scope, effectType, cfg) then
            local span, box = LayoutEffectSlots(state, effectType, y, cfg)
            if box ~= nil then PlaceLayoutHandle(state, effectType, box.x, box.y, box.width, box.height) end
            if span > 0 then
                -- Buff/Debuff/Hidden offsets are independent canvas coordinates.
                -- Never let a dragged lane resize the parent or reflow siblings.
                y = y + span + sectionGap
            end
        else
            HideEffectSlots(state.effectSlots[effectType])
        end
    end

    if cfg.showCast == true and scope == "target" and (state.cast.visible == true or self.layoutEditScope == scope) then
        local castCfg = type(cfg.cast) == "table" and cfg.cast or {}
        local castHeight = math.max(10, math.min(40, tonumber(castCfg.height) or 16))
        local castIconSize = math.max(16, math.min(42, tonumber(castCfg.iconSize) or 20))
        local castWidth = tonumber(castCfg.width) or 0
        if castWidth <= 0 then castWidth = math.max(90, (tonumber(cfg.width) or 286) - 14) end
        -- The cast bar is an independent canvas element.  Its explicit width may
        -- exceed the outer HUD width without resizing/reflowing sibling content.
        castWidth = math.max(90, math.min(450, castWidth))
        local showName = castCfg.showName ~= false
        local showTime = castCfg.showTime ~= false
        local nameFont = math.max(8, math.min(24, tonumber(castCfg.nameFontSize) or 9))
        local timeFont = math.max(8, math.min(24, tonumber(castCfg.timeFontSize) or 9))
        local nameOffsetX = tonumber(castCfg.nameOffsetX) or 0
        local nameOffsetY = tonumber(castCfg.nameOffsetY); if nameOffsetY == nil then nameOffsetY = -2 end
        local timeOffsetX = tonumber(castCfg.timeOffsetX) or 0
        local timeOffsetY = tonumber(castCfg.timeOffsetY); if timeOffsetY == nil then timeOffsetY = -2 end

        state.cast.renderWidth = castWidth
        state.cast.y = y + 1 + (tonumber(castCfg.offsetY) or 0)
        local castX = 7 + (tonumber(castCfg.offsetX) or 0)
        local castTop = state.cast.y - math.max(0, math.floor((castIconSize - castHeight) / 2))
        state.cast.bg:RemoveAllAnchors(); state.cast.bg:AddAnchor("TOPLEFT", frame, castX, state.cast.y); state.cast.bg:SetExtent(castWidth, castHeight)
        state.cast.fill:RemoveAllAnchors(); state.cast.fill:AddAnchor("TOPLEFT", frame, castX, state.cast.y); state.cast.fill:SetExtent(math.max(1, math.min(castWidth, tonumber(state.cast.lastFillWidth) or 1)), castHeight)
        state.cast.icon:SetExtent(castIconSize, castIconSize); state.cast.icon:RemoveAllAnchors(); state.cast.icon:AddAnchor("TOPLEFT", frame, castX, castTop)

        local nameHeight = math.max(20, nameFont + 8)
        local timeHeight = math.max(20, timeFont + 8)
        local timeWidth = math.max(62, timeFont * 6 + 8)
        local nameX = castX + castIconSize + 5 + nameOffsetX
        local nameY = state.cast.y + nameOffsetY
        local timeX = castX + castWidth - timeWidth + timeOffsetX
        local timeY = state.cast.y + timeOffsetY
        state.cast.name.style:SetFontSize(nameFont)
        state.cast.time.style:SetFontSize(timeFont)
        state.cast.name:RemoveAllAnchors(); state.cast.name:AddAnchor("TOPLEFT", frame, nameX, nameY)
        state.cast.name:SetExtent(math.max(45, castWidth - castIconSize - timeWidth - 12), nameHeight)
        state.cast.time:RemoveAllAnchors(); state.cast.time:AddAnchor("TOPLEFT", frame, timeX, timeY); state.cast.time:SetExtent(timeWidth, timeHeight)

        local editingCast = self.layoutEditScope == scope and (self.layoutEditKey == nil or self.layoutEditKey == "cast")
        if editingCast and state.cast.visible ~= true then
            -- Layout editing must not require the target to be casting at the
            -- exact moment the user adjusts geometry/text.  Show a local preview
            -- only while the cast component owns the edit transaction.
            state.cast.layoutPreviewVisible = true
            state.cast.bg:SetVisible(true)
            state.cast.fill:SetVisible(true)
            state.cast.fill:SetExtent(math.max(1, math.floor(castWidth * 0.58 + 0.5)), castHeight)
            SetIconPath(state.cast.icon, "ui/icon/icon_skill_buff26.dds")
            state.cast.icon:SetVisible(true)
            state.cast.name:SetText("模拟施法")
            state.cast.time:SetText("1.8 / 3.0")
            state.cast.name:Show(showName)
            state.cast.time:Show(showTime)
        elseif state.cast.visible == true then
            state.cast.layoutPreviewVisible = false
            state.cast.bg:SetVisible(true)
            state.cast.fill:SetVisible(true)
            state.cast.name:Show(showName)
            state.cast.time:Show(showTime)
        else
            state.cast.name:Show(false)
            state.cast.time:Show(false)
        end

        PlaceLayoutHandle(state, "cast", castX, castTop, castWidth, math.max(castHeight, castIconSize))
        local castSpan = math.max(castHeight, castIconSize)
        y = y + castSpan + 5
    else self:UpdateCasting(scope, nil) end
    -- IMPORTANT: `y` is the nominal canvas flow cursor. User offsets never
    -- contribute to it, so the outer frame remains stable while a component is
    -- dragged beyond its visual bounds. Children may render outside this frame;
    -- their own saved offset remains the sole positioning authority.
    local finalHeight = math.max(24, y + 2)
    state.layoutHeight = finalHeight
    frame:SetExtent(cfg.width, finalHeight)
    state.last.fillWidth = -1; state.cast.lastFillWidth = -1

    -- BOTTOM anchoring is the collision fence for variable-height target HUDs.
    -- A new Buff row changes frame height, not the protected lower edge.
    if cfg.anchorMode == "BOTTOM" and state.dragging ~= true then
        local runtime = P.Runtime
        local rt = type(runtime) == "table" and type(runtime.scopes) == "table" and runtime.scopes[scope] or nil
        if type(rt) == "table" and rt.positionValid == true then
            self:MovePlate(scope, rt.lastScreenX + cfg.offsetX, rt.lastScreenY + cfg.offsetY)
        end
    end
end

function U:ApplyAllLayouts()
    for _, scope in ipairs(SCOPE_ORDER) do self:ApplyPlateLayout(scope) end
end

function U:SetCalibration(scope)
    if scope ~= nil and self.plates[scope] == nil then scope = nil end
    self.calibrationScope = scope
    self.layoutEditScope = nil
    self.layoutEditKey = nil
    for _, item in ipairs(SCOPE_ORDER) do
        local state = self.plates[item]
        local enabled = item == scope
        state.dragging = false
        HideLayoutHandles(state)
        if state.frame.EnableDrag ~= nil then state.frame:EnableDrag(enabled) end
        SetPick(state.frame, false)
        SetPickSelf(state.frame, enabled)
        if state.outer ~= nil then state.outer:SetVisible(enabled) end
        if state.inner ~= nil then state.inner:SetVisible(enabled) end
        if state.accent ~= nil then state.accent:SetVisible(enabled) end
        if enabled then self:SetPlateVisible(item, true) end
    end
    self:RefreshSettingsText()
end

function U:SetLayoutEdit(scope, key)
    if scope ~= nil and self.plates[scope] == nil then scope = nil end
    self.layoutEditScope = scope
    self.layoutEditKey = scope ~= nil and key or nil
    self.calibrationScope = nil
    for _, item in ipairs(SCOPE_ORDER) do
        local state = self.plates[item]
        local enabled = item == scope
        state.dragging = false
        if state.frame.EnableDrag ~= nil then state.frame:EnableDrag(false) end
        -- First clear any recursive pick state left by whole-HUD calibration.
        -- Then enable only the plate itself; ApplyPlateLayout explicitly turns
        -- on the blue component handles and leaves every visual child inert.
        SetPick(state.frame, false)
        SetPickSelf(state.frame, enabled)
        if state.outer ~= nil then state.outer:SetVisible(enabled) end
        if state.inner ~= nil then state.inner:SetVisible(enabled) end
        if state.accent ~= nil then state.accent:SetVisible(enabled) end
        self:ApplyPlateLayout(item)
        if enabled then self:SetPlateVisible(item, true) end
    end
    self:RefreshSettingsText()
end

local PREVIEW_ICONS = {
    buff = "ui/icon/icon_skill_buff26.dds",
    debuff = "ui/icon/icon_unknown_item.dds",
    hidden = "ui/icon/icon_skill_buff381.dds",
}

local PREVIEW_BASE_COUNTS = { buff = 6, debuff = 4, hidden = 2 }

local function PreviewEffects(effectType, count)
    local result = {}
    count = math.max(1, math.min(12, math.floor(tonumber(count) or PREVIEW_BASE_COUNTS[effectType] or 6)))
    for index = 1, count do
        -- Keep at least one very short-lived sample and recurring stacked samples.
        -- This makes expiry colour, duration font and stack-size controls visibly
        -- testable in mock mode instead of requiring a matching real aura state.
        local remaining = index == 1 and 1800 or (index == 2 and 3800 or (6 + index * 3) * 1000)
        result[index] = {
            id = tostring(900000 + index), key = "preview:" .. effectType .. ":" .. tostring(index),
            name = (effectType == "buff" and "模拟 Buff " or effectType == "debuff" and "模拟 Debuff " or "模拟 Hidden ") .. tostring(index),
            iconPath = PREVIEW_ICONS[effectType], stack = index % 2 == 0 and (2 + (index % 3)) or 1,
            timeLeftMs = remaining, effectType = effectType,
        }
    end
    return result
end

function U:RefreshMockPreview(scope)
    if self.mockPreviewScope ~= scope then return false end
    for _, effectType in ipairs({ "buff", "debuff", "hidden" }) do
        local layout = S:GetEffectLayout(scope, effectType)
        local configured = type(layout) == "table" and tonumber(layout.maxCount) or nil
        -- Source enough samples to expose max-count/columns/wrapping changes, while
        -- EffectMaximum remains the display Authority and clamps the visible rows.
        local sourceCount = math.max(PREVIEW_BASE_COUNTS[effectType] or 2, math.min(12, math.floor(configured or 0)))
        self:UpdateEffects(scope, effectType, PreviewEffects(effectType, sourceCount), true)
    end
    self:SetPlateVisible(scope, true)
    self:ApplyPlateLayout(scope)
    return true
end

function U:SetPreviewMode(scope, mode)
    if scope ~= "target" and scope ~= "player" then return false end
    mode = mode == "mock" and "mock" or "real"
    if mode == "mock" then
        self.mockPreviewScope = scope
        self:RefreshMockPreview(scope)
    else
        self.mockPreviewScope = nil
        if P.Runtime and P.Runtime.ForceScope then P.Runtime:ForceScope(scope) end
    end
    return true
end

function U:GetPreviewMode(scope)
    return self.mockPreviewScope == scope and "mock" or "real"
end

function U:SetPlateVisible(scope, visible)
    local state = self.plates[scope]
    local cfg = S:Get()[scope]
    if state == nil or cfg == nil then return end
    local preferred = cfg.enabled == true
    if ReplicatedSuiteEmbedded == true and self.suiteHudPreferredVisibility[scope] ~= nil then
        preferred = self.suiteHudPreferredVisibility[scope] == true
    end
    if (self.calibrationScope == scope or self.layoutEditScope == scope) and preferred then
        visible = true
    else
        visible = visible == true and preferred
    end
    if ReplicatedSuiteEmbedded == true and self.suiteHudEffectiveVisibility[scope] ~= true then
        visible = false
    end
    local actual = WidgetIsVisible(state.frame)
    -- Never trust only our Lua-side visibility cache. The RU client can hide a
    -- child/native widget while state.visible remains true (UI rebuild, layer
    -- transition, cutscene, etc.). If that happens, the old early-return made
    -- Plates stay invisible forever until the addon was restarted.
    if state.visible == visible and (actual == nil or actual == visible) then return end
    state.visible = visible
    state.frame:Show(visible)
end

local PROFILE_SCALARS = { "offsetX", "offsetY", "width", "anchorMode", "sectionGap" }
local PROFILE_SUBFIELDS = {
    distance = { "fontSize", "offsetX", "offsetY" },
    cooldowns = { "iconSize", "fontSize", "maxCount", "columns", "gap", "rowGap", "direction", "offsetX", "offsetY" },
    equipment = { "iconSize", "direction", "offsetX", "offsetY" },
    targetOfTarget = { "fontSize", "offsetX", "offsetY" },
    class = { "iconSize", "fontSize", "offsetX", "offsetY" },
    gear = { "fontSize", "offsetX", "offsetY" },
    loadout = { "fontSize", "offsetX", "offsetY" },
    cast = {
        "width", "height", "iconSize", "offsetX", "offsetY",
        "showName", "nameFontSize", "nameOffsetX", "nameOffsetY",
        "showTime", "timeFontSize", "timeOffsetX", "timeOffsetY",
    },
}
local PROFILE_EFFECT_FIELDS = { "iconSize", "fontSize", "maxCount", "columns", "gap", "rowGap", "direction", "offsetX", "offsetY" }

local function CopyAllowed(source, fields)
    local result = {}
    if type(source) ~= "table" then return result end
    for _, key in ipairs(fields or {}) do if source[key] ~= nil then result[key] = source[key] end end
    return result
end
local function ApplyAllowed(target, source, fields)
    if type(target) ~= "table" or type(source) ~= "table" then return end
    for _, key in ipairs(fields or {}) do if source[key] ~= nil then target[key] = source[key] end end
end

function U:SetSuiteHudEffectiveVisible(scope, effective, preferred)
    if self.plates[scope] == nil then return false end
    self.suiteHudEffectiveVisibility[scope] = effective == true
    self.suiteHudPreferredVisibility[scope] = preferred == true
    local cfg = S:Get()[scope]
    -- Keep the legacy Plates field as a compatibility mirror only. Suite HUD
    -- Manager remains the visibility Authority while embedded.
    if type(cfg) == "table" and cfg.enabled ~= (preferred == true) then
        cfg.enabled = preferred == true
        S:MarkDirty()
        S:Save(true)
    end
    if effective ~= true then
        self:SetPlateVisible(scope, false)
    elseif P.Runtime ~= nil and type(P.Runtime.ForceScope) == "function" then
        P.Runtime:ForceScope(scope)
    end
    self:RefreshSettingsText()
    return true
end

function U:SetSuiteHudLocked(scope, locked)
    if self.plates[scope] == nil then return false end
    self.suiteHudLocked[scope] = locked == true
    if locked == true and self.calibrationScope == scope then self:SetCalibration(nil) end
    return true
end

function U:CaptureSuiteHudProfile(scope, placement)
    local cfg = S:Get()[scope]
    if type(cfg) ~= "table" or type(placement) ~= "table" then return false end
    placement.profileExtra = type(placement.profileExtra) == "table" and placement.profileExtra or {}
    local snap = { domainLayoutCaptured = true }
    for _, key in ipairs(PROFILE_SCALARS) do if cfg[key] ~= nil then snap[key] = cfg[key] end end
    for key, fields in pairs(PROFILE_SUBFIELDS) do
        if type(cfg[key]) == "table" then snap[key] = CopyAllowed(cfg[key], fields) end
    end
    if type(cfg.effects) == "table" then
        snap.effects = {}
        for _, effectType in ipairs({ "buff", "debuff", "hidden" }) do
            if type(cfg.effects[effectType]) == "table" then snap.effects[effectType] = CopyAllowed(cfg.effects[effectType], PROFILE_EFFECT_FIELDS) end
        end
    end
    placement.profileExtra.plateLayout = snap
    return true
end

function U:ApplySuiteHudProfile(scope, placement)
    local cfg = S:Get()[scope]
    local extra = type(placement) == "table" and placement.profileExtra or nil
    local snap = type(extra) == "table" and extra.plateLayout or nil
    if type(cfg) ~= "table" or type(snap) ~= "table" or snap.domainLayoutCaptured ~= true then return true end
    for _, key in ipairs(PROFILE_SCALARS) do if snap[key] ~= nil then cfg[key] = snap[key] end end
    for key, fields in pairs(PROFILE_SUBFIELDS) do
        if type(snap[key]) == "table" then
            cfg[key] = type(cfg[key]) == "table" and cfg[key] or {}
            ApplyAllowed(cfg[key], snap[key], fields)
        end
    end
    if type(snap.effects) == "table" then
        cfg.effects = type(cfg.effects) == "table" and cfg.effects or {}
        for _, effectType in ipairs({ "buff", "debuff", "hidden" }) do
            if type(snap.effects[effectType]) == "table" then
                cfg.effects[effectType] = type(cfg.effects[effectType]) == "table" and cfg.effects[effectType] or {}
                ApplyAllowed(cfg.effects[effectType], snap.effects[effectType], PROFILE_EFFECT_FIELDS)
            end
        end
    end
    S:MarkDirty()
    S:Save(true)
    self:ApplyPlateLayout(scope)
    if P.Runtime ~= nil and type(P.Runtime.ForceScope) == "function" then P.Runtime:ForceScope(scope) end
    return true
end

function U:ResetSuiteHudPosition(scope)
    local ok, err = S:ResetPlateOffset(scope)
    if ok then
        self:ApplyPlateLayout(scope)
        if P.Runtime ~= nil and type(P.Runtime.ForceScope) == "function" then P.Runtime:ForceScope(scope) end
    end
    return ok, err
end

function U:MovePlate(scope, x, y)
    local state, cfg = self.plates[scope], S:Get()[scope]
    if state == nil or cfg == nil or state.dragging == true then return end
    local px = math.floor((tonumber(x) or 0) + 0.5)
    local py = math.floor((tonumber(y) or 0) + 0.5)
    if cfg.anchorMode == "BOTTOM" then
        py = py - math.max(1, math.floor((tonumber(state.layoutHeight) or 1) + 0.5))
    end
    state.frame:RemoveAllAnchors()
    state.frame:AddAnchor("TOPLEFT", "UIParent", px, py)
end

function U:ResetPresentation(scope)
    local state = self.plates[scope]
    if state == nil then return end
    state.last = { name = nil, healthText = nil, percentText = nil, distanceText = nil, fillWidth = -1, healthTone = nil }
    state.distance:SetText("")
    for _, effectType in ipairs({ "buff", "debuff", "hidden", "cooldown" }) do
        if state.effectSlots[effectType] ~= nil then HideEffectSlots(state.effectSlots[effectType]) end
        state.effectCounts[effectType] = 0
    end
    state.cooldownSnapshots = {}
    state.metadata.lastClassKey, state.metadata.lastClassIcon, state.metadata.lastGear, state.metadata.lastGearTone, state.metadata.lastTargetOfTarget = nil, nil, nil, nil, nil
    state.metadata.targetOfTargetVisible = false
    state.metadata.classIcon:SetVisible(false); state.metadata.className:Show(false); state.metadata.gear:Show(false); state.metadata.targetOfTarget:Show(false); state.metadata.loadout:Show(false)
    for _, icon in ipairs(state.metadata.loadoutIcons or {}) do icon:SetVisible(false) end
    state.metadata.loadoutVisible = false; state.metadata.loadoutCount = 0; state.metadata.lastLoadout = nil
    for _, slot in pairs(state.equipment.slots or {}) do slot.frame:Show(false); slot.icon:SetVisible(false); slot.grade:SetVisible(false); slot.iconPath = nil; slot.gradePath = nil end
    state.equipment.lastSignature = nil
    self:UpdateCasting(scope, nil)
    self:ApplyPlateLayout(scope)
end

function U:UpdateName(scope, name)
    local state = self.plates[scope]
    if state == nil then return end
    name = tostring(name or "")
    if state.last.name == name then return end
    state.last.name = name
    state.name:SetText(name)
end

function U:UpdateDistance(scope, distance)
    local state, cfg = self.plates[scope], S:Get()[scope]
    if state == nil or cfg == nil then return end
    if cfg.showDistance ~= true or distance == nil then
        if state.last.distanceText ~= "" then state.last.distanceText = ""; state.distance:SetText("") end
        state.last.distanceTone = nil
        return
    end
    local value = tonumber(distance)
    if value == nil then return end
    local text = string.format("%.1fm", value)
    if text ~= state.last.distanceText then state.last.distanceText = text; state.distance:SetText(text) end
    local distanceCfg = cfg.distance or { warningAt = 25, dangerAt = 30 }
    local tone = "normal"
    if value > (tonumber(distanceCfg.dangerAt) or 30) then tone = "danger"
    elseif value > (tonumber(distanceCfg.warningAt) or 25) then tone = "warning" end
    if tone ~= state.last.distanceTone then
        state.last.distanceTone = tone
        if tone == "danger" then state.distance.style:SetColor(1.00, 0.44, 0.36, 1)
        elseif tone == "warning" then state.distance.style:SetColor(1.00, 0.78, 0.32, 1)
        else state.distance.style:SetColor(0.66, 0.88, 1.00, 1) end
    end
end

function U:UpdateHealth(scope, current, maximum)
    local state, cfg = self.plates[scope], S:Get()[scope]
    current, maximum = tonumber(current), tonumber(maximum)
    if state == nil or cfg == nil or current == nil or maximum == nil or maximum <= 0 then return end
    local ratio = math.max(0, math.min(1, current / maximum))
    local maxFill = math.max(1, cfg.width - 14)
    local fillWidth = math.max(1, math.floor(maxFill * ratio + 0.5))
    if fillWidth ~= state.last.fillWidth then state.last.fillWidth = fillWidth; state.healthFill:SetExtent(fillWidth, 18) end
    local tone, r, g, b = HealthTone(ratio)
    if tone ~= state.last.healthTone then state.last.healthTone = tone; state.healthFill:SetColor(r, g, b, 1) end
    local pct = string.format("%d%%", math.floor(ratio * 100 + 0.5))
    if pct ~= state.last.percentText then state.last.percentText = pct; state.percent:SetText(pct) end
    local hp = FormatInteger(current) .. " / " .. FormatInteger(maximum)
    if hp ~= state.last.healthText then state.last.healthText = hp; state.healthText:SetText(hp) end
end

local function ResolveRuleValue(rule, layout, key, fallback)
    if type(rule) == "table" and rule[key] ~= nil then return rule[key] end
    if type(layout) == "table" and layout[key] ~= nil then return layout[key] end
    return fallback
end

local function ApplySlotColor(drawable, color, fallback)
    if drawable == nil or type(drawable.SetColor) ~= "function" then return end
    local value = type(color) == "table" and color or fallback
    value = type(value) == "table" and value or { r=1,g=1,b=1,a=1 }
    drawable:SetColor(tonumber(value.r or value[1]) or 1, tonumber(value.g or value[2]) or 1, tonumber(value.b or value[3]) or 1, tonumber(value.a or value[4]) or 1)
end

local function UpdateEffectSlot(slot, effect, layout)
    if type(effect) ~= "table" or type(effect.iconPath) ~= "string" or effect.iconPath == "" then
        local actual = WidgetIsVisible(slot.frame)
        if slot.visible ~= false or actual == true then slot.frame:Show(false) end
        slot.visible = false
        slot.icon:SetVisible(false)
        slot.effect = nil; slot.tooltipEnabled = false; slot.tooltipText = nil
        SetPick(slot.frame, false)
        return
    end
    if slot.iconPath ~= effect.iconPath then
        slot.iconPath = effect.iconPath
        SetIconPath(slot.icon, effect.iconPath)
    else
        -- Same texture does not imply the native drawable is still visible.
        -- Reassert it so client-side UI rebuilds cannot strand a valid icon.
        slot.icon:SetVisible(true)
    end
    slot.key = effect.key or effect.id
    slot.effect = effect
    local rule = type(effect.trackedEntry) == "table" and effect.trackedEntry or nil
    local baseIconSize = math.max(1, (tonumber(type(layout)=="table" and layout.iconSize) or 24) - 2)
    local requestedIconSize = type(rule)=="table" and tonumber(rule.iconSize) or nil
    if requestedIconSize ~= nil then baseIconSize = math.max(1, math.min(baseIconSize, requestedIconSize - 2)) end
    slot.icon:SetExtent(baseIconSize, baseIconSize)
    local showDuration = ResolveRuleValue(rule, layout, "showDuration", true) ~= false
    local showStack = ResolveRuleValue(rule, layout, "showStack", true) ~= false
    local showBorder = ResolveRuleValue(rule, layout, "showBorder", true) ~= false
    local showTooltip = ResolveRuleValue(rule, layout, "showTooltip", false) == true
    local expireEnabled = ResolveRuleValue(rule, layout, "expireEnabled", false) == true
    local expireThreshold = tonumber(ResolveRuleValue(rule, layout, "expireThreshold", 5)) or 5
    local ms = tonumber(effect.timeLeftMs) or 0
    local expiring = expireEnabled and ms > 0 and ms <= expireThreshold * 1000

    local durationText = showDuration and FormatEffectTime(ms) or ""
    if slot.durationText ~= durationText then slot.durationText = durationText; slot.duration:SetText(durationText) end
    local stack = tonumber(effect.stack) or 0
    local stackText = showStack and stack > 1 and tostring(stack) or ""
    if slot.stackText ~= stackText then slot.stackText = stackText; slot.stack:SetText(stackText) end

    local accent = EFFECT_ACCENT[slot.effectType] or EFFECT_ACCENT.buff
    local fallbackColor = { r=accent[1], g=accent[2], b=accent[3], a=0.92 }
    local edgeColor = expiring and (type(rule) == "table" and rule.expireColor or nil) or (type(rule) == "table" and rule.borderColor or nil)
    if edgeColor == nil then edgeColor = expiring and (type(layout)=="table" and layout.expireColor or nil) or (type(layout)=="table" and layout.borderColor or nil) end
    ApplySlotColor(slot.edge, edgeColor, fallbackColor)
    slot.edge:SetVisible(showBorder)
    if expiring then
        local c = type(edgeColor)=="table" and edgeColor or fallbackColor
        slot.duration.style:SetColor(tonumber(c.r or c[1]) or 1, tonumber(c.g or c[2]) or 0.3, tonumber(c.b or c[3]) or 0.2, 1)
    else
        slot.duration.style:SetColor(1,1,1,1)
    end
    slot.tooltipEnabled = showTooltip
    if showTooltip then
        local name = tostring(effect.name or effect.customName or ("ID " .. tostring(effect.id or "?")))
        local typeName = ({ buff="Buff", debuff="Debuff", hidden="Hidden", cooldown="Cooldown" })[slot.effectType] or tostring(slot.effectType or "")
        local idText = tostring(effect.id or effect.key or "?")
        local stackValue = math.max(1, tonumber(effect.stack) or 1)
        local timeText = FormatEffectTime(ms); if timeText == "" then timeText = "--" end
        slot.tooltipText = name .. "\nID: " .. idText .. " · " .. typeName .. " · " .. tostring(stackValue) .. "层 · " .. timeText
    else
        slot.tooltipText = nil
    end
    SetPick(slot.frame, showTooltip)
    local actual = WidgetIsVisible(slot.frame)
    if slot.visible ~= true or actual == false then slot.frame:Show(true) end
    slot.visible = true
end

function U:UpdateEffects(scope, effectType, effects, internalPreview)
    local state, cfg = self.plates[scope], S:Get()[scope]
    if state == nil or cfg == nil then return end
    if self.mockPreviewScope == scope and internalPreview ~= true then return end
    local slots = state.effectSlots[effectType]
    if slots == nil or EffectRowEnabled(scope, effectType, cfg) ~= true then
        if slots ~= nil then HideEffectSlots(slots) end
        if state.effectCounts[effectType] ~= 0 then
            state.effectCounts[effectType] = 0
            self:ApplyPlateLayout(scope)
        end
        return
    end
    local maximum = EffectMaximum(state.scope, effectType)
    effects = type(effects) == "table" and effects or {}
    local nextCount = math.min(maximum, #effects)
    if state.effectCounts[effectType] ~= nextCount then
        state.effectCounts[effectType] = nextCount
        self:ApplyPlateLayout(scope)
    end
    for index, slot in ipairs(slots) do
        if index <= maximum then UpdateEffectSlot(slot, effects[index], S:GetEffectLayout(scope, effectType))
        elseif slot.visible ~= false then slot.visible = false; slot.frame:Show(false) end
    end
end

-- Important item cooldowns are rendered through the same proven icon primitive
-- as auras, but their data Authority is X2Skill cooldown state, not Unit buffs.
function U:UpdateImportantCooldowns(cooldowns)
    local state = self.plates.player
    if state == nil then return end
    state.cooldownSnapshots = type(cooldowns) == "table" and cooldowns or {}
    self:UpdateEffects("player", "cooldown", state.cooldownSnapshots)
end

-- Lightweight liveness reconciliation. Runtime calls this from a 1s sentinel,
-- not every frame. It repairs Lua/native visibility drift without rescanning
-- effects: the last reliable snapshots remain the data Authority.
function U:ReconcileScope(scope, snapshots)
    local state, cfg = self.plates[scope], S:Get()[scope]
    if state == nil or cfg == nil then return 0 end
    local repaired = 0
    local frameActual = WidgetIsVisible(state.frame)
    local shouldShow = state.visible == true and cfg.enabled == true
    if frameActual ~= nil and frameActual ~= shouldShow then
        state.frame:Show(shouldShow)
        repaired = repaired + 1
    end
    if shouldShow ~= true then return repaired end

    snapshots = type(snapshots) == "table" and snapshots or {}
    local reconcileTypes = scope == "player" and { "buff", "debuff", "hidden", "cooldown" } or { "buff", "debuff", "hidden" }
    for _, effectType in ipairs(reconcileTypes) do
        local slots = state.effectSlots[effectType]
        if slots ~= nil then
            local rowEnabled = EffectRowEnabled(scope, effectType, cfg) == true
            local source = effectType == "cooldown" and state.cooldownSnapshots or snapshots[effectType]
            local effects = rowEnabled and (type(source) == "table" and source or {}) or {}
            local maximum = rowEnabled and EffectMaximum(scope, effectType) or 0
            for index, slot in ipairs(slots) do
                local wanted = index <= maximum and type(effects[index]) == "table"
                local before = WidgetIsVisible(slot.frame)
                if wanted then
                    UpdateEffectSlot(slot, effects[index], S:GetEffectLayout(scope, effectType))
                    if before == false then repaired = repaired + 1 end
                else
                    -- Reconcile every stale slot, including holes inside the
                    -- configured maximum and rows disabled after being visible.
                    UpdateEffectSlot(slot, nil)
                    if before == true then repaired = repaired + 1 end
                end
            end
        end
    end

    -- Equipment uses the same native-widget layer as aura icons and can drift
    -- invisible while Lua still remembers slot.visible=true.  Reassert cached
    -- visibility here without rescanning the bag/equipment APIs.
    if scope == "player" and state.equipment ~= nil and type(state.equipment.slots) == "table" then
        for _, key in ipairs(EQUIPMENT_ORDER) do
            local slot = state.equipment.slots[key]
            if slot ~= nil then
                local wanted = cfg.showEquipment == true and EquipmentEnabled(cfg, key) and slot.visible == true
                local before = WidgetIsVisible(slot.frame)
                if before ~= nil and before ~= wanted then
                    slot.frame:Show(wanted)
                    repaired = repaired + 1
                end
                if wanted then
                    slot.icon:SetVisible(type(slot.iconPath) == "string" and slot.iconPath ~= "")
                    slot.grade:SetVisible(type(slot.gradePath) == "string" and slot.gradePath ~= "")
                elseif before == true then
                    slot.icon:SetVisible(false)
                    slot.grade:SetVisible(false)
                end
            end
        end
    end
    return repaired
end

function U:UpdateTargetOfTarget(name)
    local state, cfg = self.plates.target, S:Get().target
    if state == nil or cfg == nil then return end
    local text = (cfg.showTargetOfTarget == true and type(name) == "string" and name ~= "") and ("目标：" .. name) or ""
    if state.metadata.lastTargetOfTarget ~= text then state.metadata.lastTargetOfTarget = text; state.metadata.targetOfTarget:SetText(text) end
    local visible = text ~= ""
    if state.metadata.targetOfTargetVisible ~= visible then state.metadata.targetOfTargetVisible = visible; state.metadata.targetOfTarget:Show(visible) end
end

function U:UpdateTargetMetadata(classInfo, gearScore, loadoutInfo)
    local state, cfg = self.plates.target, S:Get().target
    if state == nil or cfg == nil then return end
    local meta = state.metadata
    meta.className.style:SetColor(0.42, 0.90, 1.00, 1)
    meta.gear.style:SetColor(1.00, 0.82, 0.32, 1)
    if cfg.showClass == true and type(classInfo) == "table" then
        if meta.lastClassIcon ~= classInfo.iconPath then meta.lastClassIcon = classInfo.iconPath; SetIconPath(meta.classIcon, classInfo.iconPath) end
        meta.classIcon:SetVisible(cfg.class.showIcon == true and type(classInfo.iconPath) == "string" and classInfo.iconPath ~= "")
        local classText = cfg.class.showName == true and tostring(classInfo.name or "") or ""
        if meta.lastClassKey ~= tostring(classInfo.key or "") .. ":" .. classText then
            meta.lastClassKey = tostring(classInfo.key or "") .. ":" .. classText; meta.className:SetText(classText)
        end
        meta.className:Show(classText ~= "")
    else meta.classIcon:SetVisible(false); meta.className:Show(false) end
    if cfg.showGear == true and tonumber(gearScore) ~= nil and tonumber(gearScore) > 0 then
        local score = tonumber(gearScore)
        local text = score >= 1000 and string.format("装等 %.1fk", score / 1000) or ("装等 " .. tostring(math.floor(score + 0.5)))
        if meta.lastGear ~= text then meta.lastGear = text; meta.gear:SetText(text) end
        local gearTone = "bright"
        if meta.lastGearTone ~= gearTone then
            meta.lastGearTone = gearTone
            meta.gear.style:SetColor(1.00, 0.82, 0.32, 1)
        end
        meta.gear:Show(true)
    else meta.gear:Show(false) end

    local items = {}
    if cfg.showLoadout == true and type(loadoutInfo) == "table" and type(loadoutInfo.items) == "table" then items = loadoutInfo.items end
    local signatureParts, visibleCount = {}, 0
    for index, icon in ipairs(meta.loadoutIcons or {}) do
        local item = items[index]
        local path = type(item) == "table" and tostring(item.iconPath or "") or ""
        if type(item) == "table" then
            if path == "" then path = "ui/icon/icon_unknown_item.dds" end
            SetIconPath(icon, path); icon:SetVisible(true); visibleCount = visibleCount + 1
            signatureParts[#signatureParts + 1] = tostring(item.id or "") .. ":" .. path
        else
            icon:SetVisible(false)
        end
    end
    meta.loadout:Show(false)
    local signature = table.concat(signatureParts, "|")
    local wasLoadoutVisible = meta.loadoutVisible == true
    meta.lastLoadout = signature ~= "" and signature or nil
    meta.loadoutCount = visibleCount
    meta.loadoutVisible = visibleCount > 0
    -- Visibility changes alter the target plate height. Reflow immediately so
    -- the metadata row never leaves a blank gap and never overlaps the aura rows.
    if wasLoadoutVisible ~= (meta.loadoutVisible == true) then self:ApplyPlateLayout("target") end
end

function U:UpdateEquipment(snapshot)
    local state, cfg = self.plates.player, S:Get().player
    if state == nil or cfg == nil then return end
    snapshot = type(snapshot) == "table" and snapshot or {}
    for _, key in ipairs(EQUIPMENT_ORDER) do
        local slot = state.equipment.slots[key]
        local item = snapshot[key]
        if slot ~= nil and cfg.showEquipment == true and EquipmentEnabled(cfg, key) and type(item) == "table"
            and type(item.iconPath) == "string" and item.iconPath ~= "" then
            if slot.iconPath ~= item.iconPath then slot.iconPath = item.iconPath; SetIconPath(slot.icon, item.iconPath)
            else slot.icon:SetVisible(true) end
            if type(item.gradeIconPath) == "string" and item.gradeIconPath ~= "" then
                if slot.gradePath ~= item.gradeIconPath then slot.gradePath = item.gradeIconPath; SetIconPath(slot.grade, item.gradeIconPath)
                else slot.grade:SetVisible(true) end
            else
                slot.gradePath = nil; slot.grade:SetVisible(false)
            end
            local frameActual = WidgetIsVisible(slot.frame)
            if slot.visible ~= true or frameActual == false then
                slot.visible = true
                slot.frame:Show(true)
            end
        elseif slot ~= nil then
            if slot.visible ~= false then slot.visible = false; slot.frame:Show(false) end
            slot.icon:SetVisible(false); slot.grade:SetVisible(false)
            -- Clear visibility-sensitive caches. Re-enabling the same item must
            -- re-show its icon even when the texture path did not change.
            slot.iconPath, slot.gradePath = nil, nil
        end
    end
end

function U:UpdateCasting(scope, info)
    local state, cfg = self.plates[scope], S:Get()[scope]
    if state == nil or cfg == nil then return end
    local cast = state.cast
    if scope ~= "target" or cfg.showCast ~= true or type(info) ~= "table" or (tonumber(info.totalMs) or 0) <= 0 then
        if cast.visible ~= false or cast.layoutPreviewVisible == true then
            cast.visible = false
            cast.layoutPreviewVisible = false
            cast.bg:SetVisible(false); cast.fill:SetVisible(false); cast.icon:SetVisible(false); cast.name:Show(false); cast.time:Show(false)
            self:ApplyPlateLayout(scope)
        end
        cast.lastIconPath = nil
        cast.lastTimeText = nil; cast.lastTone = nil
        return
    end
    if cast.visible ~= true then
        cast.visible = true
        cast.layoutPreviewVisible = false
        self:ApplyPlateLayout(scope)
        cast.bg:SetVisible(true); cast.fill:SetVisible(true)
    end
    local castCfg = type(cfg.cast) == "table" and cfg.cast or {}
    cast.name:Show(castCfg.showName ~= false)
    cast.time:Show(castCfg.showTime ~= false)
    local name = tostring(info.name or "")
    if cast.lastName ~= name then cast.lastName = name; cast.name:SetText(name) end
    if cast.lastIconPath ~= info.iconPath then cast.lastIconPath = info.iconPath; SetIconPath(cast.icon, info.iconPath) end
    local total = math.max(1, tonumber(info.totalMs) or 1)
    local current = math.max(0, math.min(total, tonumber(info.currentMs) or 0))
    local renderWidth = tonumber(cast.renderWidth) or (cfg.width - 14)
    local fillWidth = math.max(1, math.floor(renderWidth * (current / total) + 0.5))
    local castHeight = type(cfg.cast) == "table" and (tonumber(cfg.cast.height) or 16) or 16
    if fillWidth ~= cast.lastFillWidth then cast.lastFillWidth = fillWidth; cast.fill:SetExtent(fillWidth, castHeight) end
    local timeText = string.format("%.1f / %.1f", current / 1000, total / 1000)
    if timeText ~= cast.lastTimeText then cast.lastTimeText = timeText; cast.time:SetText(timeText) end
    local tone = info.castingUseable == true and "usable" or "casting"
    if tone ~= cast.lastTone then
        cast.lastTone = tone
        if tone == "usable" then cast.fill:SetColor(0.24, 0.80, 0.72, 1)
        else cast.fill:SetColor(0.33, 0.58, 0.97, 1) end
    end
end

------------------------------------------------------------------------
-- Settings - Suite mode uses only the main-window right panel.
------------------------------------------------------------------------
if ReplicatedSuiteEmbedded == true then
    U.lastRuntimeStatusText, U.lastRuntimeStatusTone = nil, nil
    function U:SetRuntimeStatus(text, tone)
        self.lastRuntimeStatusText = tostring(text or "未知")
        self.lastRuntimeStatusTone = tostring(tone or "idle")
    end
    function U:RefreshSettingsText() end
    function U:SaveSettingsAndForce(scope)
        S:MarkDirty()
        local ok, err = S:Save(true)
        if not ok then P.SafeChat("保存设置失败：" .. tostring(err or "unknown")); return false end
        self:ApplyPlateLayout(scope)
        if P.Runtime ~= nil and type(P.Runtime.ForceScope) == "function" then P.Runtime:ForceScope(scope) end
        return true
    end
    function U:OpenSettings()
        if ReplicatedSuite ~= nil and ReplicatedSuite.UI ~= nil then ReplicatedSuite.UI:ShowPage("plates"); return true end
        return false
    end
    function U:ToggleSettings() return self:OpenSettings() end
    function U:HideRuntimeHud()
        self:SetCalibration(nil)
        for _, scope in ipairs(SCOPE_ORDER) do
            local plateState = self.plates[scope]
            if plateState ~= nil and plateState.frame ~= nil then pcall(function() plateState.frame:Show(false) end) end
        end
    end
    function U:HideAll()
        self:HideRuntimeHud()
        if self.buffCapHost ~= nil then pcall(function() self.buffCapHost:Show(false) end) end
        if P.Manager ~= nil and type(P.Manager.HideAll) == "function" then pcall(function() P.Manager:HideAll() end) end
        if P.Diagnostics ~= nil and type(P.Diagnostics.HideAll) == "function" then pcall(function() P.Diagnostics:HideAll() end) end
    end
else
local sw = settings.settingsWindow
local config = CreateWindow("settings", 620, 468, sw.x, sw.y, false, true)
U.windows.settings = config
SetPick(config, true)
CreateBackground(config, 0.018, 0.028, 0.042, 0.99, "background")

local header = config:CreateChildWidget("emptywidget", P.PhysicalId("settings_header"), 0, true)
header:AddAnchor("TOPLEFT", config, 0, 0); header:SetExtent(620, 40); SetPick(header, true)
CreateBackground(header, 0.050, 0.12, 0.19, 1, "background")
local headerLine = header:CreateColorDrawable(0.20, 0.58, 0.88, 1, "artwork")
headerLine:AddAnchor("BOTTOMLEFT", header, 0, 0); headerLine:SetExtent(620, 2)
CreateLabel(header, "settings_title", "Replicated Plates", 13, 6, 300, 25, 14, ALIGN_LEFT)
local version = CreateLabel(header, "settings_version", "v" .. tostring(P.Version), 438, 9, 122, 20, 9, ALIGN_RIGHT)
version.style:SetColor(0.68, 0.82, 0.95, 1)
local close = CreateButton(header, "settings_close", "X", 576, 6, 32, 27, 13)
AttachWindowDrag(config, header, "settingsWindow")
AttachResizeGrip(config, "settingsWindow", 620, 468, 900, 820)

local intro = CreateLabel(config, "settings_intro", "布局设置只保留一个入口：HUD布局信息。目标 / 自己的组件显示、大小、数量、方向、间距、X/Y 与拖动都在同一个窗口完成。", 16, 50, 588, 38, 10, ALIGN_LEFT)
intro.style:SetColor(0.73, 0.82, 0.91, 1)

local rowControls = {}
local function CreateScopeRow(scope, y)
    local meta, cfg = SCOPE_META[scope], settings[scope]
    local card=config:CreateChildWidget("emptywidget",P.PhysicalId("scope_card_"..scope),0,true)
    card:AddAnchor("TOPLEFT",config,14,y); card:SetExtent(592,58); SetPick(card,false)
    CreateBackground(card,0.025,0.043,0.060,0.72,"background")
    local bar=card:CreateColorDrawable(meta.accent[1],meta.accent[2],meta.accent[3],0.95,"artwork")
    bar:AddAnchor("TOPLEFT",card,0,0); bar:SetExtent(3,58)
    CreateLabel(card,"label_"..scope,meta.title.." HUD",12,16,110,24,11,ALIGN_LEFT)
    local row={}
    row.enabled=CreateButton(config,"enable_"..scope,"显示：开",166,y+14,104,30,9)
    row.hud=CreateButton(config,"hud_"..scope,"编辑 HUD 布局",286,y+14,154,30,9)
    row.reset=CreateButton(config,"reset_"..scope,"恢复推荐布局",456,y+14,136,30,9)
    SafeHandler(row.enabled,"OnClick",function()
        if ReplicatedSuiteEmbedded == true and ReplicatedSuite ~= nil and ReplicatedSuite.HudManager ~= nil then
            ReplicatedSuite.HudManager:ToggleVisible("plates_" .. scope)
            U:RefreshSettingsText()
            if P.Runtime ~= nil and type(P.Runtime.ForceScope) == "function" then P.Runtime:ForceScope(scope) end
            return
        end
        cfg.enabled=not cfg.enabled
        if not cfg.enabled then
            if U.calibrationScope==scope then U:SetCalibration(nil) end
            if U.layoutEditScope==scope then U:SetLayoutEdit(nil) end
            U:SetPlateVisible(scope,false)
        end
        U:SaveSettingsAndForce(scope)
    end,scope..":enable")
    SafeHandler(row.hud,"OnClick",function()
        if P.Manager and type(P.Manager.OpenHUDLayout)=="function" then P.Manager:OpenHUDLayout(scope)
        else P.SafeChat("HUD布局信息模块未完成加载。") end
    end,scope..":hud")
    SafeHandler(row.reset,"OnClick",function()
        if P.Manager and type(P.Manager.ResetHUDScope)=="function" then
            P.Manager:ResetHUDScope(scope)
        elseif P.Manager and type(P.Manager.OpenHUDLayout)=="function" then
            P.Manager:OpenHUDLayout(scope)
            P.SafeChat("请在 HUD布局信息 中点击“恢复整套推荐布局”。")
        end
    end,scope..":reset")
    rowControls[scope]=row
end

CreateScopeRow("target", 98)
CreateScopeRow("player", 164)

local managerButton=CreateButton(config,"open_manager","Buff追踪管理",16,244,136,32,10)
local diagnosticsButton=CreateButton(config,"open_diagnostics","实机诊断",160,244,136,32,10)
local forceRefreshButton=CreateButton(config,"force_refresh","立即刷新",304,244,136,32,10)
local openTargetHud=CreateButton(config,"open_hud_layout","HUD布局信息",448,244,136,32,10)
U.controls.managerButton=managerButton
SafeHandler(openTargetHud,"OnClick",function() if P.Manager and type(P.Manager.OpenHUDLayout)=="function" then P.Manager:OpenHUDLayout("target") else P.SafeChat("HUD布局信息模块未完成加载。") end end,"hud_layout:open")
SafeHandler(managerButton,"OnClick",function() if P.Manager and type(P.Manager.Open)=="function" then P.Manager:Open() else P.SafeChat("追踪管理模块未完成加载。") end end,"manager:open")
SafeHandler(diagnosticsButton,"OnClick",function() if P.Diagnostics and type(P.Diagnostics.Open)=="function" then P.Diagnostics:Open() else P.SafeChat("诊断模块尚未就绪。") end end,"diagnostics:open")
SafeHandler(forceRefreshButton,"OnClick",function()
    if ReplicatedSuiteEmbedded == true and ReplicatedSuite ~= nil and ReplicatedSuite.ModuleManager ~= nil and not ReplicatedSuite.ModuleManager:IsEnabled("plates") then
        P.SafeChat("BUFF显示模块当前未启用；静态布局/追踪设置仍可修改。")
        return
    end
    U:ApplyAllLayouts(); if P.Runtime and type(P.Runtime.ForceAll)=="function" then P.Runtime:ForceAll() end; P.SafeChat("已请求目标 / 自己 HUD 立即刷新。")
end,"runtime:force")

local statusLabel=CreateLabel(config,"runtime_status","运行状态：初始化",16,310,588,22,10,ALIGN_LEFT)
local hintLabel=CreateLabel(config,"settings_hint","目标默认采用底部安全锚点：Buff / Debuff 换行只向上扩展，不再向下挤进游戏原生姓名条。",16,338,588,22,9,ALIGN_LEFT)
hintLabel.style:SetColor(0.65,0.82,0.92,1)
local perfLabel=CreateLabel(config,"perf_hint","位置、字号、图标、数量、每行个数、间距、排列方向和组件拖动全部集中在 HUD布局信息。",16,366,588,22,9,ALIGN_LEFT)
perfLabel.style:SetColor(0.58,0.70,0.80,1)
U.controls.runtimeStatus=statusLabel
U.lastRuntimeStatusText,U.lastRuntimeStatusTone=nil,nil

function U:SetRuntimeStatus(text, tone)
    local nextText = "运行状态：" .. tostring(text or "未知")
    local nextTone = tostring(tone or "idle")
    if nextText ~= self.lastRuntimeStatusText then self.lastRuntimeStatusText = nextText; statusLabel:SetText(nextText) end
    if nextTone ~= self.lastRuntimeStatusTone then
        self.lastRuntimeStatusTone = nextTone
        if nextTone == "ok" then statusLabel.style:SetColor(0.35, 0.92, 0.55, 1)
        elseif nextTone == "error" then statusLabel.style:SetColor(1.00, 0.38, 0.34, 1)
        else statusLabel.style:SetColor(0.74, 0.80, 0.88, 1) end
    end
end

function U:RefreshSettingsText()
    local moduleEnabled = true
    if ReplicatedSuiteEmbedded == true and ReplicatedSuite ~= nil and ReplicatedSuite.ModuleManager ~= nil then
        moduleEnabled = ReplicatedSuite.ModuleManager:IsEnabled("plates")
    end
    if forceRefreshButton ~= nil and forceRefreshButton.Enable ~= nil then forceRefreshButton:Enable(moduleEnabled) end
    if intro ~= nil then
        intro:SetText(moduleEnabled
            and "布局设置只保留一个入口：HUD布局信息。目标 / 自己的组件显示、大小、数量、方向、间距、X/Y 与拖动都在同一个窗口完成。"
            or "当前模块未启用 · 静态布局和追踪设置仍可修改；扫描/立即刷新等 Runtime 动作已禁用。")
    end
    if not moduleEnabled then self:SetRuntimeStatus("当前模块未启用 · 静态设置可修改", "idle") end
    for _,scope in ipairs(SCOPE_ORDER) do
        local cfg,row=S:Get()[scope],rowControls[scope]
        local visible = cfg.enabled == true
        if ReplicatedSuiteEmbedded == true and ReplicatedSuite ~= nil and ReplicatedSuite.HudManager ~= nil and ReplicatedSuite.HudManager:Get("plates_" .. scope) ~= nil then
            visible = ReplicatedSuite.HudManager:IsVisible("plates_" .. scope)
        end
        row.enabled:SetText(visible and "显示：开" or "显示：关")
    end
end

function U:SaveSettingsAndForce(scope)
    S:MarkDirty()
    local ok, err = S:Save(true)
    if not ok then P.SafeChat("保存设置失败：" .. tostring(err or "unknown")) end
    self:ApplyPlateLayout(scope)
    self:RefreshSettingsText()
    if P.Runtime ~= nil and type(P.Runtime.ForceScope) == "function" then P.Runtime:ForceScope(scope) end
end

SafeHandler(close, "OnClick", function()
    if U.calibrationScope ~= nil then U:SetCalibration(nil) end
    if U.layoutEditScope ~= nil then U:SetLayoutEdit(nil) end
    config:Show(false)
end, "settings:close")

------------------------------------------------------------------------
-- Launcher
------------------------------------------------------------------------
local launcherCfg = settings.launcher
local launcher = UIParent:CreateWidget("button", P.PhysicalId("launcher"), "UIParent", "")
launcher:SetText("BUFF显示")
StyleButton(launcher, 88, 26, 11)
launcher:AddAnchor("TOPLEFT", "UIParent", launcherCfg.x, launcherCfg.y)
if launcher.CorrectOffsetByScreen ~= nil then pcall(function() launcher:CorrectOffsetByScreen() end) end
-- The launcher is also a persistent HUD element, not a modal window. Keep it
-- on the normal layer so opening Backpack/Character panels covers it instead
-- of the launcher covering native game UI.
SetPick(launcher, true)
if launcher.EnableDrag ~= nil then launcher:EnableDrag(true) end
launcher:Show(false)
U.controls.launcher = launcher
if ReplicatedSuiteEmbedded ~= true and ReplicatedCombatLauncherPolicy ~= nil and type(ReplicatedCombatLauncherPolicy.Register) == "function" then
    ReplicatedCombatLauncherPolicy:Register("plates", launcher)
else
    pcall(function() launcher:Show(false) end)
end

U.launcherVisible = U.launcherVisible == true
local PLATES_LAUNCHER_CONTENT_ID = 91834
if ReplicatedSuiteEmbedded ~= true and ADDON ~= nil then
    if type(ADDON.RegisterContentWidget) == "function" then
        pcall(function() ADDON:RegisterContentWidget(PLATES_LAUNCHER_CONTENT_ID, launcher) end)
    end
    if type(ADDON.RegisterContentTriggerFunc) == "function" then
        pcall(function()
            ADDON:RegisterContentTriggerFunc(PLATES_LAUNCHER_CONTENT_ID, function(show)
                U.launcherVisible = show == true
                launcher:Show(U.launcherVisible)
            end)
        end)
    end
end
if ReplicatedSuiteEmbedded == true then U.launcherVisible = false end
launcher:Show(U.launcherVisible == true)

SafeHandler(launcher, "OnDragStart", function(self)
    self.rpMoving = true
    self.rpSafeMoving = false
    if ReplicatedSuiteEmbedded == true and ReplicatedSuite ~= nil and ReplicatedSuite.Layout ~= nil
        and type(ReplicatedSuite.Layout.BeginSafeMove) == "function" then
        local ok, moved = pcall(function()
            return ReplicatedSuite.Layout:BeginSafeMove("plates_launcher", self, { clamp = true })
        end)
        self.rpSafeMoving = ok and moved == true
    end
    if self.rpSafeMoving ~= true and type(self.StartMoving) == "function" then self:StartMoving() end
    return true
end, "launcher:drag_start")
SafeHandler(launcher, "OnDragStop", function(self)
    if self.rpSafeMoving == true and ReplicatedSuite ~= nil and ReplicatedSuite.Layout ~= nil
        and type(ReplicatedSuite.Layout.EndSafeMove) == "function" then
        pcall(function() ReplicatedSuite.Layout:EndSafeMove("plates_launcher", false) end)
    elseif type(self.StopMovingOrSizing) == "function" then
        self:StopMovingOrSizing()
    end
    self.rpSafeMoving = false
    self.rpMoving = false; self.rpIgnoreNextClick = true
    if ReplicatedSuiteEmbedded == true and ReplicatedSuite ~= nil and ReplicatedSuite.Layout ~= nil
        and type(ReplicatedSuite.Layout.EnsureWidgetVisible) == "function" then
        pcall(function() ReplicatedSuite.Layout:EnsureWidgetVisible(self, { onlyWhenVisible = true }) end)
    elseif self.CorrectOffsetByScreen ~= nil then
        pcall(function() self:CorrectOffsetByScreen() end)
    end
    SaveWindowPosition("launcher", self)
    return true
end, "launcher:drag_stop")
SafeHandler(launcher, "OnClick", function(self)
    if self.rpMoving == true then return end
    if self.rpIgnoreNextClick == true then self.rpIgnoreNextClick = false; return end
    U:ToggleSettings()
end, "launcher:click")

function U:OpenSettings()
    config:Show(true)
    if config.Raise ~= nil then config:Raise() end
    self:RefreshSettingsText()
end

function U:ToggleSettings()
    local visible = config:IsVisible()
    if visible then
        if self.calibrationScope ~= nil then self:SetCalibration(nil) end
        if self.layoutEditScope ~= nil then self:SetLayoutEdit(nil) end
    end
    config:Show(not visible)
    if not visible and config.Raise ~= nil then config:Raise() end
    self:RefreshSettingsText()
end

function U:HideRuntimeHud()
    self:SetCalibration(nil)
    for _, scope in ipairs(SCOPE_ORDER) do
        local state = self.plates[scope]
        if state ~= nil then pcall(function() state.frame:Show(false) end) end
    end
end

function U:HideAll()
    self:SetCalibration(nil)
    for _, scope in ipairs(SCOPE_ORDER) do
        local state = self.plates[scope]
        if state ~= nil then pcall(function() state.frame:Show(false) end) end
    end
    if self.windows.settings ~= nil then pcall(function() self.windows.settings:Show(false) end) end
    if self.buffCapHost ~= nil then pcall(function() self.buffCapHost:Show(false) end) end
    if self.watchAggroHost ~= nil then pcall(function() self.watchAggroHost:Show(false) end) end
    if self.watchDistHost ~= nil then pcall(function() self.watchDistHost:Show(false) end) end
    if self.linesHost ~= nil then
        for _, pool in pairs(self.linesPools) do
            for _, dot in ipairs(pool.dots) do pcall(function() dot:Show(false) end) end
        end
        pcall(function() self.linesHost:Show(false) end)
    end
    if self.circleHost ~= nil then
        for _, dot in ipairs(self.circleDots) do pcall(function() dot:Show(false) end) end
        pcall(function() self.circleHost:Show(false) end)
    end
    if P.Manager ~= nil and type(P.Manager.HideAll) == "function" then pcall(function() P.Manager:HideAll() end) end
    if P.Diagnostics ~= nil and type(P.Diagnostics.HideAll) == "function" then pcall(function() P.Diagnostics:HideAll() end) end
    if self.controls.launcher ~= nil then pcall(function() self.controls.launcher:Show(false) end) end
end
end

U:ApplyAllLayouts()
U:RefreshSettingsText()
for _, scope in ipairs(SCOPE_ORDER) do U:UpdateCasting(scope, nil) end

------------------------------------------------------------------------
-- Buff-cap warning label (report 八-P0-1)
-- Standalone top label: NOT a HUD (no HudManager, no drag). The host window
-- anchors with the engine "TOP" anchor so the engine centres it horizontally;
-- only the small offsets are ours. Font changes reuse the same host/label and
-- just SetFontSize (engine CreateEmptyWindow with a duplicate id is not a
-- well-defined "recreate", so no destroy/recreate path is used).
------------------------------------------------------------------------
U.buffCapHost = nil
U.buffCapLabel = nil

local function EnsureBuffCapHost()
    if U.buffCapHost ~= nil then return true end
    if type(CreateEmptyWindow) ~= "function" then return false end
    local host = CreateEmptyWindow(P.PhysicalId("buffcap_label"), "UIParent")
    if host == nil then return false end
    host:SetExtent(400, 24)
    if host.EnablePick ~= nil then pcall(function() host:EnablePick(false) end) end
    if host.Clickable ~= nil then pcall(function() host:Clickable(false) end) end
    if host.CorrectOffsetByScreen ~= nil then pcall(function() host:CorrectOffsetByScreen() end) end
    local label = CreateLabel(host, "buffcap_text", "", 0, 0, 400, 24, 12, ALIGN_CENTER)
    U.buffCapHost = host
    U.buffCapLabel = label
    host:Show(false)
    return true
end

local function AnchorBuffCapHost(cfg)
    local host = U.buffCapHost
    if host == nil then return end
    local ox = math.floor((tonumber(cfg and cfg.offsetX) or 0) + 0.5)
    local oy = math.floor((tonumber(cfg and cfg.offsetY) or 8) + 0.5)
    if host.RemoveAllAnchors ~= nil then pcall(function() host:RemoveAllAnchors() end) end
    -- Engine "TOP" centres horizontally; offsets move from there (rp_ui re-anchor
    -- pattern). pcall-guarded: if a client rejects "TOP", fall back to manual
    -- centring and note it in 真机验证.
    if host.AddAnchor ~= nil then pcall(function() host:AddAnchor("TOP", "UIParent", ox, oy) end) end
end

function U:UpdateBuffCapLabel(shown, text, cfg)
    if shown ~= true then
        if U.buffCapHost ~= nil then pcall(function() U.buffCapHost:Show(false) end) end
        return
    end
    if not EnsureBuffCapHost() then return end
    cfg = type(cfg) == "table" and cfg or {}
    local fontSize = math.max(9, math.min(18, math.floor(tonumber(cfg.fontSize) or 12)))
    if U.buffCapLabel ~= nil then
        pcall(function() U.buffCapLabel:SetText(tostring(text or "")) end)
        if U.buffCapLabel.style ~= nil and U.buffCapLabel.style.SetFontSize ~= nil then
            pcall(function() U.buffCapLabel.style:SetFontSize(fontSize) end)
        end
    end
    AnchorBuffCapHost(cfg)
    pcall(function() U.buffCapHost:Show(true) end)
end

-- Magic-circle distance view (report 八-P1-1). view==nil hides; otherwise
-- renders icon (when the buff row exposes one; text-only fallback otherwise)
-- plus the distance text with tone colour and cfg alpha. Position = plate
-- frame anchor + cfg offset (plate-relative: plates carry no global SetScale,
-- so raw offsets are correct; see rp_ui CreateWindow/C10 note).
function U:UpdateMagicCircleView(view, cfg, info)
    local state = self.plates.player
    if state == nil or state.magicCircle == nil then return end
    local mc = state.magicCircle
    if view == nil or type(view) ~= "table" then
        mc.frame:Show(false)
        mc.lastText = nil
        return
    end
    cfg = type(cfg) == "table" and cfg or {}
    local ox = math.floor((tonumber(cfg.offsetX) or 18) + 0.5)
    local oy = math.floor((tonumber(cfg.offsetY) or -6) + 0.5)
    local fontSize = math.max(9, math.min(18, math.floor((tonumber(cfg.fontSize) or 11) + 0.5)))
    local alpha = math.max(30, math.min(100, tonumber(cfg.alpha) or 95)) / 100
    local path = P.Api ~= nil and type(P.Api.IconPath) == "function" and P.Api:IconPath(info) or nil
    if mc.iconPath ~= path then
        mc.iconPath = path
        if type(path) == "string" and path ~= "" then
            mc.icon:ClearAllTextures()
            mc.icon:AddTexture(path)
            mc.icon:SetVisible(true)
        else
            mc.icon:SetVisible(false)
        end
    end
    -- Icon-only fallback: when no icon path is available the label simply
    -- starts at the group origin (26px reserved for the icon stays empty).
    local text = tostring(view.text or "")
    if mc.lastText ~= text then mc.lastText = text; mc.label:SetText(text) end
    local toneKey = tostring(view.tone) .. ":" .. string.format("%.2f", alpha)
    if mc.lastTone ~= toneKey then
        mc.lastTone = toneKey
        local r, g, b
        if view.tone == "max" then r, g, b = 1, 0, 0
        elseif view.tone == "warn" then r, g, b = 1, 0.55, 0
        else r, g, b = 1, 1, 1 end
        mc.label.style:SetColor(r, g, b, alpha)
        if mc.icon.SetColor ~= nil then pcall(function() mc.icon:SetColor(r, g, b, alpha) end) end
    end
    if mc.label.style.SetFontSize ~= nil then pcall(function() mc.label.style:SetFontSize(fontSize) end) end
    if mc.frame.RemoveAllAnchors ~= nil then pcall(function() mc.frame:RemoveAllAnchors() end) end
    mc.frame:AddAnchor("TOPLEFT", state.frame, ox, oy)
    mc.frame:Show(true)
end

------------------------------------------------------------------------
-- watchtarget aggro/distance mini-windows (report 七-C)
-- Two independent HUD windows registered via Suite HudManager
-- (plates_watch_aggro / plates_watch_dist). Each has its own host window;
-- rendering is push-driven from the runtime lane (no polling in the UI).
-- watchtarget token availability is ⚠️ runtime; unreadable -> "--" with the
-- window still visible, zero errors (fail-closed).
------------------------------------------------------------------------
U.watchAggroHost = nil
U.watchAggroLabel = nil
U.watchDistHost = nil
U.watchDistLabel = nil
U.watchVisible = { aggro = false, dist = false }

local WATCH_AGGRO_W = 230
local WATCH_AGGRO_H = 52
local WATCH_DIST_W = 300
local WATCH_DIST_H = 52

local function EnsureWatchWindow(kind)
    if kind == "aggro" and U.watchAggroHost ~= nil then return true end
    if kind == "dist" and U.watchDistHost ~= nil then return true end
    if type(CreateEmptyWindow) ~= "function" then return false end
    if kind == "aggro" then
        local host = CreateEmptyWindow(P.PhysicalId("watch_aggro_window"), "UIParent")
        if host == nil then return false end
        host:SetExtent(WATCH_AGGRO_W, WATCH_AGGRO_H)
        SetPick(host, false)
        if host.CorrectOffsetByScreen ~= nil then pcall(function() host:CorrectOffsetByScreen() end) end
        local title = CreateLabel(host, "watch_aggro_title", "仇恨目标", 10, 4, WATCH_AGGRO_W - 20, 18, 10, ALIGN_LEFT)
        title.style:SetColor(0.96, 0.78, 0.36, 1)
        local label = CreateLabel(host, "watch_aggro_name", "--", 10, 24, WATCH_AGGRO_W - 20, 24, 14, ALIGN_LEFT)
        label.style:SetColor(1, 1, 1, 1)
        U.watchAggroHost = host
        U.watchAggroLabel = label
        host:Show(false)
        return true
    end
    local host = CreateEmptyWindow(P.PhysicalId("watch_dist_window"), "UIParent")
    if host == nil then return false end
    host:SetExtent(WATCH_DIST_W, WATCH_DIST_H)
    SetPick(host, false)
    if host.CorrectOffsetByScreen ~= nil then pcall(function() host:CorrectOffsetByScreen() end) end
    local title = CreateLabel(host, "watch_dist_title", "追踪目标", 10, 4, WATCH_DIST_W - 20, 18, 10, ALIGN_LEFT)
    title.style:SetColor(0.68, 0.84, 0.96, 1)
    local label = CreateLabel(host, "watch_dist_value", "追踪目标 --", 10, 24, WATCH_DIST_W - 20, 24, 14, ALIGN_LEFT)
    label.style:SetColor(1, 1, 1, 1)
    U.watchDistHost = host
    U.watchDistLabel = label
    host:Show(false)
    return true
end

-- Pure threshold -> tone mapping for the distance window. orangeAt/redAt are
-- metres; anything >= redAt is red, >= orangeAt orange, otherwise white.
-- nil distance -> "unknown" tone so the window renders "--" in white.
function U:WatchDistanceTone(distance, orangeAt, redAt)
    local d = tonumber(distance)
    if d == nil or d < 0 then return "unknown" end
    local red = tonumber(redAt)
    local orange = tonumber(orangeAt)
    if red ~= nil and d >= red then return "red" end
    if orange ~= nil and d >= orange then return "orange" end
    return "white"
end

function U:SetWatchWindowVisible(kind, visible)
    kind = kind == "dist" and "dist" or "aggro"
    self.watchVisible[kind] = visible == true
    if kind == "aggro" then
        if self.watchAggroHost == nil then if not EnsureWatchWindow("aggro") then return end end
        pcall(function() self.watchAggroHost:Show(self.watchVisible.aggro) end)
    else
        if self.watchDistHost == nil then if not EnsureWatchWindow("dist") then return end end
        pcall(function() self.watchDistHost:Show(self.watchVisible.dist) end)
    end
end

-- Push-driven render from the runtime lane. aggroName nil -> "--"; distance
-- nil -> "追踪目标 --" white. Tones: >= redAt red, >= orangeAt orange.
function U:RefreshWatchWindows(aggroName, distance, orangeAt, redAt)
    if self.watchVisible.aggro == true then
        if self.watchAggroHost == nil then if not EnsureWatchWindow("aggro") then return end end
        local text = (type(aggroName) == "string" and aggroName ~= "") and aggroName or "--"
        if U.watchAggroLabel ~= nil then
            if U.watchAggroLastText ~= text then
                U.watchAggroLastText = text
                pcall(function() U.watchAggroLabel:SetText(text) end)
            end
            local tone = (type(aggroName) == "string" and aggroName ~= "") and "white" or "muted"
            if U.watchAggroLastTone ~= tone then
                U.watchAggroLastTone = tone
                local r, g, b = (tone == "muted") and { 0.62, 0.66, 0.72 } or { 1, 1, 1 }
                pcall(function() U.watchAggroLabel.style:SetColor(r[1], r[2], r[3], 1) end)
            end
        end
        pcall(function() U.watchAggroHost:Show(true) end)
    end
    if self.watchVisible.dist == true then
        if self.watchDistHost == nil then if not EnsureWatchWindow("dist") then return end end
        local d = tonumber(distance)
        local text = (d ~= nil and d >= 0) and ("追踪目标 " .. string.format("%.0fm", d)) or "追踪目标 --"
        if U.watchDistLastText ~= text then
            U.watchDistLastText = text
            pcall(function() U.watchDistLabel:SetText(text) end)
        end
        local tone = self:WatchDistanceTone(d, orangeAt, redAt)
        if U.watchDistLastTone ~= tone then
            U.watchDistLastTone = tone
            local r, g, b
            if tone == "red" then r, g, b = 1, 0, 0
            elseif tone == "orange" then r, g, b = 1, 0.55, 0
            else r, g, b = 1, 1, 1 end
            pcall(function() U.watchDistLabel.style:SetColor(r, g, b, 1) end)
        end
        pcall(function() U.watchDistHost:Show(true) end)
    end
end

------------------------------------------------------------------------
-- Unit connection lines (report 七-方案B)
-- One host window (system layer) holding four pre-created dot pools (one per
-- pair, <=64 dots each). A dot is a "." label whose font size IS the dot size;
-- the pool is created once and reused (hide stale dots, never destroy/recreate).
-- Rendering is push-driven from the runtime lines lane; the UI never polls.
-- All coordinates are screen-space from A:UnitScreenPoint (native + projection
-- fallback); sizes/offsets honour the S.Layout context where applicable (C10).
------------------------------------------------------------------------
U.linesHost = nil
U.linesPools = {}   -- [pairKey] = { dots = {label,...} }
local LINES_PAIR_COLORS = {
    target = { 0.40, 0.95, 0.55 },          -- green
    targetoftarget = { 0.96, 0.78, 0.36 },  -- yellow
    watchtarget = { 0.55, 0.86, 1.00 },     -- light blue
    watchtargettarget = { 0.95, 0.55, 0.40 }, -- orange
}
local LINES_PAIR_ORDER = { "target", "targetoftarget", "watchtarget", "watchtargettarget" }
local LINES_MAX_DOTS = 64

local function EnsureLinesHost()
    if U.linesHost ~= nil then return true end
    if type(CreateEmptyWindow) ~= "function" then return false end
    local host = CreateEmptyWindow(P.PhysicalId("lines_window"), "UIParent")
    if host == nil then return false end
    host:SetExtent(200, 200)
    SetPick(host, false)
    if host.CorrectOffsetByScreen ~= nil then pcall(function() host:CorrectOffsetByScreen() end) end
    U.linesHost = host
    -- Pre-create four pools.
    for _, key in ipairs(LINES_PAIR_ORDER) do
        local pool = { dots = {} }
        for i = 1, LINES_MAX_DOTS do
            local dot = host:CreateChildWidget("label", P.PhysicalId("lines_" .. key .. "_" .. i), 0, true)
            dot:SetText(".")
            dot:SetExtent(1, 1)
            if dot.EnablePick ~= nil then pcall(function() dot:EnablePick(false) end) end
            if dot.Clickable ~= nil then pcall(function() dot:Clickable(false) end) end
            if dot.style ~= nil then
                dot.style:SetFontSize(15)
                dot.style:SetAlign(ALIGN_CENTER)
                dot.style:SetColor(1, 1, 1, 1)
            end
            dot:Show(false)
            pool.dots[i] = dot
        end
        U.linesPools[key] = pool
    end
    host:Show(false)
    return true
end

-- Push-driven render. lines = { {key=, points={{x,y},...}}, ... } or nil;
-- cfg = lines storage ({dotFontSize, dotAlpha}) or nil. Stale dots from a
-- previous frame are hidden (pool reuse, zero leaks). Unreadable endpoints
-- simply produce an empty lines list -> all dots hidden.
function U:UpdateLinesView(lines, cfg)
    if lines == nil or #lines == 0 then
        if U.linesHost ~= nil then
            for _, pool in pairs(U.linesPools) do
                for _, dot in ipairs(pool.dots) do pcall(function() dot:Show(false) end) end
            end
            pcall(function() U.linesHost:Show(false) end)
        end
        return
    end
    if not EnsureLinesHost() then return end
    cfg = type(cfg) == "table" and cfg or {}
    local fontSize = math.max(8, math.min(40, math.floor(tonumber(cfg.dotFontSize) or 15) + 0.5))
    local alpha = math.max(20, math.min(100, tonumber(cfg.dotAlpha) or 100)) / 100
    local context = ReplicatedSuite ~= nil and ReplicatedSuite.Layout ~= nil
        and type(ReplicatedSuite.Layout.GetContext) == "function"
        and ReplicatedSuite.Layout:GetContext() or {}
    local scale = tonumber(context.addonScale) or 1
    local fontScaled = math.max(8, math.floor(fontSize * scale + 0.5))

    -- Reset all pools first, then fill from the incoming lines.
    local used = {}
    for _, pool in pairs(U.linesPools) do
        for _, dot in ipairs(pool.dots) do pcall(function() dot:Show(false) end) end
    end
    for _, line in ipairs(lines) do
        local key = tostring(line.key or "")
        local pool = U.linesPools[key]
        if pool ~= nil and type(line.points) == "table" then
            local color = LINES_PAIR_COLORS[key] or { 1, 1, 1 }
            local count = math.min(#line.points, #pool.dots)
            for i = 1, count do
                local dot = pool.dots[i]
                local pt = line.points[i]
                local x = math.floor((tonumber(pt.x) or 0) * scale + 0.5)
                local y = math.floor((tonumber(pt.y) or 0) * scale + 0.5)
                if dot.style ~= nil and dot.style.SetFontSize ~= nil then
                    pcall(function() dot.style:SetFontSize(fontScaled) end)
                end
                if dot.style ~= nil and dot.style.SetColor ~= nil then
                    pcall(function() dot.style:SetColor(color[1], color[2], color[3], alpha) end)
                end
                if dot.RemoveAllAnchors ~= nil then pcall(function() dot:RemoveAllAnchors() end) end
                dot:AddAnchor("TOPLEFT", U.linesHost, x, y)
                pcall(function() dot:Show(true) end)
            end
            used[key] = true
        end
    end
    if next(used) ~= nil then
        pcall(function() U.linesHost:Show(true) end)
        if U.linesHost.Raise ~= nil then pcall(function() U.linesHost:Raise() end) end
    else
        pcall(function() U.linesHost:Show(false) end)
    end
end

------------------------------------------------------------------------
-- Player-centred distance circle (F5, easypull safe adaptation)
-- A separate dot pool (independent from the 4 connection-line pools, per
-- F-batch rule). World-space horizontal circle -> screen projection with
-- camera-behind culling (depth>0 only). Sizes/positions honour addonScale
-- (C10); never fixed pixels, never per-frame OnUpdate, never ADDON:SaveData.
------------------------------------------------------------------------
U.circleHost = nil
U.circleDots = {}

local function EnsureCircleHost(maxDots)
    maxDots = math.max(24, math.floor(tonumber(maxDots) or 48))
    if U.circleHost == nil then
        if type(CreateEmptyWindow) ~= "function" then return false end
        local host = CreateEmptyWindow(P.PhysicalId("lines_circle_window"), "UIParent")
        if host == nil then return false end
        host:SetExtent(200, 200)
        SetPick(host, false)
        if host.CorrectOffsetByScreen ~= nil then pcall(function() host:CorrectOffsetByScreen() end) end
        U.circleHost = host
        pcall(function() host:Show(false) end)
    end
    -- Grow the dot pool on demand. The pool used to be sized once, from the
    -- first frame's visible-point count; raising the configured dot count
    -- (e.g. 28 -> 32) then silently truncated angles (min(#screenPoints,
    -- #U.circleDots)). Now it expands up to the requested maximum (bounded by
    -- the 24..128 clamp in rp_storage); extra dots stay hidden, so shrinking
    -- the config later costs nothing.
    for i = #U.circleDots + 1, maxDots do
        local dot = U.circleHost:CreateChildWidget("label", P.PhysicalId("lines_circle_dot_" .. i), 0, true)
        dot:SetText(".")
        dot:SetExtent(1, 1)
        if dot.EnablePick ~= nil then pcall(function() dot:EnablePick(false) end) end
        if dot.Clickable ~= nil then pcall(function() dot:Clickable(false) end) end
        if dot.style ~= nil then
            dot.style:SetFontSize(15)
            dot.style:SetAlign(ALIGN_CENTER)
            dot.style:SetColor(1, 1, 1, 1)
        end
        dot:Show(false)
        U.circleDots[i] = dot
    end
    return true
end

-- Push-driven render from the runtime circle lane. screenPoints = list of
-- visible {x,y} screen points (depth-culled upstream); nil/empty hides all.
-- Colour/font-size/alpha reuse the lines dot configuration (single look).
function U:UpdateCircleView(screenPoints, cfg)
    if screenPoints == nil or #screenPoints == 0 then
        if U.circleHost ~= nil then
            for _, dot in ipairs(U.circleDots) do pcall(function() dot:Show(false) end) end
            pcall(function() U.circleHost:Show(false) end)
        end
        return
    end
    cfg = type(cfg) == "table" and cfg or {}
    local fontSize = math.max(8, math.min(40, math.floor(tonumber(cfg.dotFontSize) or 15) + 0.5))
    local alpha = math.max(20, math.min(100, tonumber(cfg.dotAlpha) or 100)) / 100
    local context = ReplicatedSuite ~= nil and ReplicatedSuite.Layout ~= nil
        and type(ReplicatedSuite.Layout.GetContext) == "function"
        and ReplicatedSuite.Layout:GetContext() or {}
    local scale = tonumber(context.addonScale) or 1
    local fontScaled = math.max(8, math.floor(fontSize * scale + 0.5))
    -- Size the pool from the CONFIGURED dot count, not the visible-point count
    -- (visible count varies with camera angle and could under-provision the
    -- pool; the pool only grows, so requesting the configured max is safe and
    -- keeps every angle available).
    local requestedDots = tonumber(cfg.circle and cfg.circle.dots) or 48
    if not EnsureCircleHost(requestedDots) then return end
    -- Reset all dots, then show the visible ones (pool reuse, zero leaks).
    for _, dot in ipairs(U.circleDots) do pcall(function() dot:Show(false) end) end
    local count = math.min(#screenPoints, #U.circleDots)
    for i = 1, count do
        local dot = U.circleDots[i]
        local pt = screenPoints[i]
        local x = math.floor((tonumber(pt.x) or 0) * scale + 0.5)
        local y = math.floor((tonumber(pt.y) or 0) * scale + 0.5)
        if dot.style ~= nil and dot.style.SetFontSize ~= nil then
            pcall(function() dot.style:SetFontSize(fontScaled) end)
        end
        if dot.style ~= nil and dot.style.SetColor ~= nil then
            pcall(function() dot.style:SetColor(0.55, 0.86, 1.00, alpha) end)
        end
        if dot.RemoveAllAnchors ~= nil then pcall(function() dot:RemoveAllAnchors() end) end
        dot:AddAnchor("TOPLEFT", U.circleHost, x, y)
        pcall(function() dot:Show(true) end)
    end
    pcall(function() U.circleHost:Show(true) end)
end

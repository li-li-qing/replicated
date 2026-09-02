------------------------------------------------------------------------
-- Replicated Suite - RSUI Interaction Services v1
--
-- Graduation interaction layer for the UMG-style RSUI foundation.
-- This file intentionally adds services rather than another wave of widgets.
--
-- Confirmed RU API surface used here:
--   * Widget handlers already validated by Suite: OnEnter / OnLeave / OnClick
--   * Global SetTooltip(text, widget) when exported by the client
--   * Button/Edit SetFocus(), Edit ClearFocus(), global GetFocusedWidgetId()
--
-- Not assumed / not invented:
--   * generic OnKeyDown / OnKeyUp navigation events
--   * reliable global right-click / pointer-delta APIs
-- Therefore ContextMenu is opened explicitly (or from a caller-selected
-- validated event) and keyboard navigation is capability-reported as false.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local UI, RSUI = S.UI, S.RSUI
if type(UI) ~= "table" or type(RSUI) ~= "table" then return end

local function N(v, fallback)
    v = tonumber(v)
    if v == nil then return tonumber(fallback) or 0 end
    return v
end
local function Clamp(v, a, b)
    v, a, b = N(v, a), N(a, 0), N(b, a)
    if v < a then return a end
    if v > b then return b end
    return v
end
local function ResolveNative(target)
    if RSUI:IsComponent(target) then return target:GetRoot(), target end
    if type(target) == "table" then return target, nil end
    return nil, nil
end
local function UiMetrics()
    if S.Api ~= nil and type(S.Api.GetUiMetrics) == "function" then
        local ok, _, _, _, w, h = pcall(function() return S.Api:GetUiMetrics() end)
        if ok and tonumber(w) and tonumber(h) then return tonumber(w), tonumber(h) end
    end
    return 1024, 768
end
local function AnchorRect(target)
    if RSUI:IsComponent(target) and type(RSUI.GetAbsoluteRect) == "function" then
        local rect = RSUI:GetAbsoluteRect(target)
        if rect ~= nil then return rect.x, rect.y, rect.width, rect.height end
    end
    local native = ResolveNative(target)
    if native ~= nil and S.Layout ~= nil and type(S.Layout.GetLogicalRect) == "function" then
        local ok, x, y, w, h = pcall(function() return S.Layout:GetLogicalRect(native) end)
        if ok and tonumber(x) and tonumber(y) then return tonumber(x), tonumber(y), N(w, 1), N(h, 1) end
    end
    return 0, 0, 1, 1
end

local function PointerPosition()
    if S.Api ~= nil and type(S.Api.GetMouseLogicalPosition) == "function" then
        local ok, x, y = pcall(function() return S.Api:GetMouseLogicalPosition() end)
        if ok and tonumber(x) ~= nil and tonumber(y) ~= nil then return tonumber(x), tonumber(y), "mouse" end
    end
    return nil, nil, "target"
end

local function Callback(label, fn, ...)
    if type(fn) ~= "function" then return true, nil end
    if type(RSUI.Callback) == "function" then return RSUI:Callback(label, fn, ...) end
    local args, argc = { ... }, select("#", ...)
    local ok, result = xpcall(function() return fn(unpack(args, 1, argc)) end, S.SafeTraceback)
    return ok, result
end

------------------------------------------------------------------------
-- TooltipService
--
-- Native SetTooltip is preferred when the current RU client exports it because
-- the client owns final cursor-safe placement and dismissal. Otherwise a single
-- pooled RSUI fallback is used. Binding and placement are event-driven only.
------------------------------------------------------------------------
local Tooltip = {
    version = 3,
    bindings = setmetatable({}, { __mode = "k" }),
    fallback = nil,
    owner = "rsui:tooltip_service",
}
RSUI.Tooltip = Tooltip

local function ResolveTooltipText(binding, component)
    local value = binding and binding.text
    if type(value) == "function" then
        local ok, result = Callback("rsui:tooltip_provider", value, component)
        if ok then value = result else value = nil end
    end
    if value == nil and binding ~= nil and type(binding.provider) == "function" then
        local ok, result = Callback("rsui:tooltip_provider", binding.provider, component)
        if ok then value = result end
    end
    return tostring(value or "")
end

function Tooltip:_EnsureFallback()
    if self.fallback ~= nil then return self.fallback end
    local root = UI:CreatePanel(UIParent, "rsui_tooltip_popup", 0, 0, 220, 28, "card", { gradient = true })
    if root == nil then return nil end
    root.rsUiOwner = self.owner
    if type(UI.AdoptWidget) == "function" then UI:AdoptWidget(root, self.owner, "rsui_tooltip_popup") end
    -- Fallback tooltips share the same WrappedText contract as normal RSUI
    -- text. ArcheAge LABEL is single-line; never write a TextLayout string that
    -- contains newlines directly into one Native label.
    local textComponent = RSUI:Text({
        id = "rsui_tooltip_text", parent = root, text = "", x = 8, y = 5, width = 204, height = 18,
        fontSize = 10, tone = "default", overflow = "wrap", maxLines = 8, nativeLineLimit = 8, shadow = true,
    })
    local label = textComponent and textComponent.lineLabels and textComponent.lineLabels[1] or nil
    if textComponent ~= nil and textComponent.root ~= nil then
        textComponent.root.rsUiOwner = self.owner
        if type(UI.AdoptWidget) == "function" then UI:AdoptWidget(textComponent.root, self.owner, "rsui_tooltip_text_host") end
    end
    -- The pooled popup is presentation-only. It must never become a second hit
    -- surface and steal OnLeave/click/wheel from the row that owns the tooltip.
    if type(UI.SetPickable) == "function" then
        UI:SetPickable(root, false, self.owner)
    else
        if type(root.EnablePick) == "function" then pcall(function() root:EnablePick(false) end) end
        if type(root.Clickable) == "function" then pcall(function() root:Clickable(false) end) end
    end
    UI:SetVisible(root, false, self.owner)
    self.fallback = { root = root, label = label, textComponent = textComponent, text = nil }
    return self.fallback
end

function Tooltip:Show(target, text, options)
    options = type(options) == "table" and options or {}
    local native = ResolveNative(target)
    local value = tostring(text or "")
    if native == nil or value == "" then return false, "target_or_text_required" end

    RSUI.metrics.tooltipShows = (tonumber(RSUI.metrics.tooltipShows) or 0) + 1
    -- Sample the pointer before choosing a placement path. Hover tooltips that
    -- opt into cursorFollow (overflow/truncated-text tooltips) must open beside
    -- the cursor, which only the pooled fallback does (it reads PointerPosition
    -- below). The native SetTooltip anchors the tooltip to the bound widget, not
    -- the pointer, so when cursorFollow is requested we skip native entirely.
    local mouseX, mouseY = PointerPosition()
    if type(SetTooltip) == "function" and options.forceFallback ~= true and options.cursorFollow ~= true then
        local ok = pcall(function() SetTooltip(value, native) end)
        if ok then return true, "native" end
    end

    local popup = self:_EnsureFallback()
    if popup == nil or popup.label == nil then return false, "tooltip_unavailable" end
    local fontSize = math.max(8, N(options.fontSize, 10))
    local maxWidth = Clamp(options.maxWidth or 320, 120, 480)
    local width = maxWidth
    if RSUI.TextLayout ~= nil and type(RSUI.TextLayout.MeasureWidth) == "function" then
        width = Clamp(RSUI.TextLayout:MeasureWidth(popup.label, value, fontSize) + 18, 120, maxWidth)
    end
    local vw, vh = UiMetrics()
    local lineHeight = (RSUI.TextLayout and RSUI.TextLayout:LineHeight(popup.label, fontSize)) or 14
    local maxHeight = Clamp(options.maxHeight or 360, 24, math.max(24, vh - 8))
    local heightLineLimit = math.max(1, math.floor((maxHeight - 10) / math.max(1, lineHeight)))
    local maxLines = math.max(1, math.floor(N(options.maxLines, heightLineLimit)))
    maxLines = math.min(maxLines, heightLineLimit)
    local textComponent = popup.textComponent
    if textComponent == nil then return false, "tooltip_wrapped_text_unavailable" end
    textComponent.maxLines = math.max(1, math.min(maxLines, tonumber(textComponent.nativeLineLimit) or 8))
    textComponent:SetFontSize(fontSize)
    textComponent:SetText(value)
    local _, desiredTextHeight = textComponent:Measure(math.max(1, width - 16), math.max(1, maxHeight - 10))
    local lines = math.max(1, math.ceil((tonumber(desiredTextHeight) or lineHeight) / math.max(1, lineHeight)))
    local height = Clamp(lines * lineHeight + 10, 24, maxHeight)
    textComponent:Layout(8, 5, math.max(1, width - 16), math.max(1, height - 10))
    UI:SetExtent(popup.root, width, height, self.owner)

    local x, y, w, h = AnchorRect(target)
    local gap = N(options.gap, 10)
    local mouseX, mouseY = PointerPosition()
    local px, py
    if mouseX ~= nil and mouseY ~= nil then
        -- Match native-tooltip behaviour: open beside the cursor, not at a fixed
        -- table-row corner. No OnUpdate follows the pointer; placement is sampled
        -- once on OnEnter to keep the interaction entirely event-driven.
        px, py = mouseX + gap, mouseY + gap
        if px + width > vw - 4 then px = mouseX - width - gap end
        if py + height > vh - 4 then py = mouseY - height - gap end
    else
        px, py = x + w + gap, y
        if px + width > vw - 4 then px = x - width - gap end
    end
    px = Clamp(px, 4, math.max(4, vw - width - 4))
    py = Clamp(py, 4, math.max(4, vh - height - 4))
    UI:SetAnchor(popup.root, UIParent, px, py, self.owner)
    UI:SetVisible(popup.root, true, self.owner)
    if type(popup.root.Raise) == "function" then pcall(function() popup.root:Raise() end) end
    popup.text = value
    return true, "fallback"
end

function Tooltip:Hide()
    if self.fallback ~= nil and self.fallback.root ~= nil then UI:SetVisible(self.fallback.root, false, self.owner) end
    RSUI.metrics.tooltipHides = (tonumber(RSUI.metrics.tooltipHides) or 0) + 1
    return true
end

function Tooltip:Bind(target, spec)
    local native, component = ResolveNative(target)
    if native == nil then return false, "target_required" end
    spec = type(spec) == "table" and spec or { text = spec }
    -- Raw native widgets have no RSUI event multiplexer. Replacing their
    -- OnEnter/OnLeave handler can break legacy business behaviour, so migration
    -- code must opt in explicitly until the widget itself becomes an RSUI component.
    if component == nil and spec.allowRaw ~= true then return false, "component_required_or_allowRaw" end
    if component ~= nil and self.bindings[native] ~= nil and type(component.Off) == "function" then
        component:Off(native, "OnEnter", "rsui:tooltip_enter")
        component:Off(native, "OnLeave", "rsui:tooltip_leave")
    end
    self.bindings[native] = { text = spec.text, provider = spec.provider, options = spec, component = component }
    local service = self
    local function enter()
        local binding = service.bindings[native]
        if binding == nil then return false end
        local text = ResolveTooltipText(binding, binding.component)
        if text == "" then return false end
        return service:Show(binding.component or native, text, binding.options)
    end
    local function leave()
        -- Native SetTooltip dismisses itself; the explicit hide is only needed
        -- for the pooled fallback and is harmless otherwise.
        service:Hide()
        return true
    end
    local okA, okB
    if component ~= nil and type(component.On) == "function" then
        okA = component:On(native, "OnEnter", enter, "rsui:tooltip_enter")
        okB = component:On(native, "OnLeave", leave, "rsui:tooltip_leave")
    else
        okA = UI:SafeHandler(native, "OnEnter", enter, "rsui:tooltip_enter")
        okB = UI:SafeHandler(native, "OnLeave", leave, "rsui:tooltip_leave")
    end
    if okA or okB then
        RSUI.metrics.tooltipBindings = (tonumber(RSUI.metrics.tooltipBindings) or 0) + 1
        return true
    end
    self.bindings[native] = nil
    return false, "handler_unavailable"
end

-- Reusable binding for any RSUI Text component. Callers choose the hit
-- surface explicitly so complex controls can keep labels mouse-through while a
-- row/card/button owns pointer input. TableView uses its own multi-column variant.
function Tooltip:BindOverflowText(textComponent, hitTarget, spec)
    if not RSUI:IsComponent(textComponent) or type(textComponent.GetOverflowTooltipText) ~= "function" then
        return false, "text_component_required"
    end
    if hitTarget == nil then return false, "hit_target_required" end
    local target = hitTarget
    spec = type(spec) == "table" and spec or {}
    local binding = {}
    for key, value in pairs(spec) do binding[key] = value end
    binding.provider = function() return textComponent:GetOverflowTooltipText() end
    -- Truncated-text tooltips should follow the cursor, not anchor to the cell
    -- (native SetTooltip pins to the bound widget). Force the cursor-following
    -- pooled fallback for this path.
    binding.cursorFollow = true
    return self:Bind(target, binding)
end

function Tooltip:Unbind(target)
    local native, component = ResolveNative(target)
    if native == nil then return false end
    local binding = self.bindings[native]
    component = component or (binding and binding.component)
    if component ~= nil and type(component.Off) == "function" then
        component:Off(native, "OnEnter", "rsui:tooltip_enter")
        component:Off(native, "OnLeave", "rsui:tooltip_leave")
    end
    self.bindings[native] = nil
    self:Hide()
    return true
end

------------------------------------------------------------------------
-- ContextMenuService
--
-- One pooled menu for the Suite. Opening is explicit; callers may bind it to
-- any event already validated for that specific widget. We intentionally do
-- not invent a right-click event name that is absent from ui_functions.lua.
------------------------------------------------------------------------
local ContextMenu = {
    version = 1,
    owner = "rsui:context_menu_service",
    root = nil,
    rows = {},
    items = {},
    open = false,
    maxItems = 24,
    rowHeight = 25,
    padding = 4,
}
RSUI.ContextMenu = ContextMenu

function ContextMenu:_EnsureRoot()
    if self.root ~= nil then return self.root end
    local root = UI:CreatePanel(UIParent, "rsui_context_menu", 0, 0, 180, 30, "card", { gradient = true })
    if root == nil then return nil end
    root.rsUiOwner = self.owner
    if type(UI.AdoptWidget) == "function" then UI:AdoptWidget(root, self.owner, "rsui_context_menu") end
    UI:SetVisible(root, false, self.owner)
    self.root = root
    return root
end

function ContextMenu:_EnsureRow(index)
    if self.rows[index] ~= nil then return self.rows[index] end
    if self:_EnsureRoot() == nil then return nil end
    local button = UI:CreateButton(self.root, "rsui_context_item_" .. tostring(index), "", self.padding, self.padding + (index - 1) * self.rowHeight, 172, self.rowHeight - 1, 10, false, false)
    if button == nil then return nil end
    button.rsUiOwner = self.owner
    if type(UI.AdoptWidget) == "function" then UI:AdoptWidget(button, self.owner, "rsui_context_item_" .. tostring(index)) end
    local service = self
    UI:SafeHandler(button, "OnClick", function()
        local row = service.rows[index]
        local item = row and row.item
        if item == nil or item.enabled == false or item.separator == true then return false end
        local callback = item.onClick or item.action
        local closeFirst = item.closeOnClick ~= false
        if closeFirst then service:Close() end
        RSUI.metrics.contextMenuActions = (tonumber(RSUI.metrics.contextMenuActions) or 0) + 1
        if type(callback) == "function" then Callback("rsui:context_menu:" .. tostring(item.id or index), callback, item, index) end
        return true
    end, "rsui:context_menu_click:" .. tostring(index))
    local row = { button = button, item = nil }
    self.rows[index] = row
    RSUI.metrics.contextMenuRowsCreated = (tonumber(RSUI.metrics.contextMenuRowsCreated) or 0) + 1
    return row
end

local function NormalizeMenuItems(items, maxItems)
    local out = {}
    for index, item in ipairs(type(items) == "table" and items or {}) do
        if #out >= maxItems then break end
        if type(item) ~= "table" then item = { text = tostring(item) } end
        out[#out + 1] = {
            id = tostring(item.id or index),
            text = tostring(item.text or item.label or item.title or ""),
            enabled = item.enabled ~= false,
            separator = item.separator == true,
            checked = item.checked == true,
            tone = item.tone,
            onClick = item.onClick,
            action = item.action,
            closeOnClick = item.closeOnClick,
            source = item,
        }
    end
    return out
end

function ContextMenu:Open(anchor, items, options)
    options = type(options) == "table" and options or {}
    if self:_EnsureRoot() == nil then return false, "context_menu_unavailable" end
    local maxRequested = math.max(1, math.min(self.maxItems, N(options.maxItems, self.maxItems)))
    local normalized = NormalizeMenuItems(items, maxRequested)
    if #normalized == 0 then self:Close(); return false, "items_required" end
    local width = Clamp(options.width or 180, 120, 360)
    if options.autoWidth ~= false and RSUI.TextLayout ~= nil and type(RSUI.TextLayout.MeasureWidth) == "function" then
        local maxMeasured = width
        for _, item in ipairs(normalized) do
            if not item.separator then maxMeasured = math.max(maxMeasured, RSUI.TextLayout:MeasureWidth(nil, item.text, 10) + 42) end
        end
        width = Clamp(maxMeasured, 120, N(options.maxWidth, 360))
    end
    local rowHeight = Clamp(options.rowHeight or self.rowHeight, 20, 36)
    local padding = Clamp(options.padding or self.padding, 2, 12)
    self.rowHeight, self.padding = rowHeight, padding
    local vw, vh = UiMetrics()
    local screenRows = math.max(1, math.floor((math.max(1, vh - 8) - padding * 2) / rowHeight))
    while #normalized > screenRows do table.remove(normalized) end
    self.items = normalized
    local height = padding * 2 + #normalized * rowHeight

    for index, item in ipairs(normalized) do
        local row = self:_EnsureRow(index)
        if row ~= nil then
            row.item = item
            local prefix = item.checked and "✓  " or ""
            local text = item.separator and "────────────" or (prefix .. item.text)
            UI:SetText(row.button, text, self.owner)
            UI:SetExtent(row.button, math.max(1, width - padding * 2), math.max(1, rowHeight - 1), self.owner)
            UI:SetAnchor(row.button, self.root, padding, padding + (index - 1) * rowHeight, self.owner)
            UI:SetEnabled(row.button, item.enabled and not item.separator, self.owner)
            if type(UI.SetLabelTone) == "function" then UI:SetLabelTone(row.button, item.tone or "default", self.owner) end
            UI:SetVisible(row.button, true, self.owner)
        end
    end
    for index = #normalized + 1, #self.rows do
        local row = self.rows[index]
        if row ~= nil and row.button ~= nil then row.item = nil; UI:SetVisible(row.button, false, self.owner) end
    end

    UI:SetExtent(self.root, width, height, self.owner)
    local x, y, w, h = AnchorRect(anchor)
    local px = N(options.x, x)
    local py = N(options.y, y + h + 4)
    if options.position == "right" then px, py = x + w + 4, y end
    if px + width > vw - 4 then px = math.max(4, x + w - width) end
    if py + height > vh - 4 then py = math.max(4, y - height - 4) end
    px, py = Clamp(px, 4, math.max(4, vw - width - 4)), Clamp(py, 4, math.max(4, vh - height - 4))
    UI:SetAnchor(self.root, UIParent, px, py, self.owner)
    UI:SetVisible(self.root, true, self.owner)
    if type(self.root.Raise) == "function" then pcall(function() self.root:Raise() end) end
    self.open = true
    RSUI.metrics.contextMenuOpens = (tonumber(RSUI.metrics.contextMenuOpens) or 0) + 1
    return true
end

function ContextMenu:Close()
    if self.root ~= nil then UI:SetVisible(self.root, false, self.owner) end
    local changed = self.open == true
    self.open = false
    if changed then RSUI.metrics.contextMenuCloses = (tonumber(RSUI.metrics.contextMenuCloses) or 0) + 1 end
    return changed
end

function ContextMenu:IsOpen() return self.open == true end

function ContextMenu:Bind(target, provider, eventName, options)
    local native, component = ResolveNative(target)
    if native == nil or type(provider) ~= "function" then return false, "target_provider_required" end
    options = type(options) == "table" and options or {}
    if component == nil and options.allowRaw ~= true then return false, "component_required_or_allowRaw" end
    -- Default OnClick is deliberately conservative. Callers may pass another
    -- event only after that event is confirmed for the concrete native widget.
    eventName = tostring(eventName or "OnClick")
    local service = self
    local handler = function()
        local ok, items = Callback("rsui:context_provider", provider, component or native)
        if not ok or type(items) ~= "table" then return false end
        return service:Open(component or native, items)
    end
    if component ~= nil and type(component.On) == "function" then
        return component:On(native, eventName, handler, "rsui:context_bind:" .. eventName)
    end
    return UI:SafeHandler(native, eventName, handler, "rsui:context_bind:" .. eventName)
end

------------------------------------------------------------------------
-- FocusService
------------------------------------------------------------------------
local Focus = {
    version = 1,
    keyboardNavigationSupported = false,
    keyboardNavigationReason = "ui_functions.lua confirms SetFocus/GetFocusedWidgetId but does not document generic OnKeyDown/OnKeyUp handlers",
}
RSUI.Focus = Focus

function Focus:Set(target)
    local native = ResolveNative(target)
    if native == nil or type(native.SetFocus) ~= "function" then return false, "set_focus_unavailable" end
    local ok = pcall(function() native:SetFocus() end)
    if ok then RSUI.metrics.focusChanges = (tonumber(RSUI.metrics.focusChanges) or 0) + 1 end
    return ok
end

function Focus:Clear(target)
    local native = ResolveNative(target)
    if native == nil or type(native.ClearFocus) ~= "function" then return false, "clear_focus_unavailable" end
    local ok = pcall(function() native:ClearFocus() end)
    if ok then RSUI.metrics.focusChanges = (tonumber(RSUI.metrics.focusChanges) or 0) + 1 end
    return ok
end

function Focus:GetFocusedWidgetId()
    if type(GetFocusedWidgetId) ~= "function" then return nil, "get_focus_unavailable" end
    local ok, id = pcall(GetFocusedWidgetId)
    if not ok then return nil, "get_focus_failed" end
    return id
end

function Focus:GetCapabilities()
    return {
        setFocus = true,
        getFocusedWidgetId = type(GetFocusedWidgetId) == "function",
        genericKeyboardNavigation = self.keyboardNavigationSupported == true,
        reason = self.keyboardNavigationReason,
    }
end

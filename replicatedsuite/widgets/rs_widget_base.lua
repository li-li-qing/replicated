------------------------------------------------------------------------
-- Replicated Suite - Floating Widget Base
-- Author: Replicated
--
-- Shared Authority for floating-window movement, safe-area clamping, resizing,
-- per-widget background opacity, locking, click-through and compact modes.
------------------------------------------------------------------------

if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite

S.WidgetBase = {}
local WB = S.WidgetBase

local function Clamp(value, minimum, maximum)
    local n = tonumber(value) or minimum
    if n < minimum then return minimum end
    if n > maximum then return maximum end
    return n
end

local function SetPick(widget, enabled)
    if widget == nil then return end
    if widget.EnablePick ~= nil then pcall(function() widget:EnablePick(enabled == true) end) end
    if widget.Clickable ~= nil then pcall(function() widget:Clickable(enabled == true) end) end
end

local OPACITY_STEPS = { 1.00, 0.85, 0.70, 0.55 }
local EVENT_OPACITY_STEPS = { 1.00, 0.85, 0.70, 0.55, 0.35, 0.20, 0.00 }
local function NextOpacity(current, allowZero)
    current = tonumber(current) or tonumber(S.State.settings.opacity) or 0.90
    -- Global opacity can be 90%, which is not one of the compact per-widget
    -- steps. Treat it as the starting value and move to 85%, rather than
    -- snapping to 85% and then accidentally skipping straight to 70%.
    if current > 0.85 and current < 1.00 then return 0.85 end
    local steps = allowZero == true and EVENT_OPACITY_STEPS or OPACITY_STEPS
    for i, value in ipairs(steps) do
        if math.abs(value - current) < 0.001 then
            local nextIndex = i + 1
            if nextIndex > #steps then nextIndex = 1 end
            return steps[nextIndex]
        end
    end
    return 0.85
end

-- Shared hover tooltip for the single-glyph title-bar buttons shared by every
-- floating widget (锁/A-/A+/90%/—).  One Suite-owned panel parented to UIParent
-- serves all widgets, mirroring the entry "R" and main-window chrome tooltips.
local chromeTooltip = nil
local chromeTipLabel = nil
local function EnsureChromeTooltip()
    if chromeTooltip ~= nil then return end
    chromeTooltip = S.UI:CreatePanel("UIParent", "widget_chrome_tooltip", 0, 0, 200, 24, "card")
    chromeTooltip:Show(false)
    chromeTipLabel = S.UI:CreateLabel(chromeTooltip, "widget_chrome_tip_text", "", 8, 4, 184, 18, 9, nil, ALIGN_LEFT)
end
local function ShowWidgetTip(anchor, text)
    if text == nil or text == "" then return end
    EnsureChromeTooltip()
    chromeTipLabel:SetText(text)
    local c = S.Layout:GetContext()
    local x, y, w = S.Layout:GetLogicalRect(anchor)
    local tw, th = 200 * c.addonScale, 24 * c.addonScale
    local tx = x + w + 6 * c.addonScale
    if tx + tw > c.logicalWidth - c.safeRight then tx = x - tw - 6 * c.addonScale end
    local ty = y
    tx, ty = S.Layout:ClampTopLeft(tx, ty, tw, th, { edge = c.safeLeft })
    chromeTooltip:RemoveAllAnchors()
    chromeTooltip:AddAnchor("TOPLEFT", "UIParent", tx, ty)
    chromeTooltip:SetExtent(tw, th)
    chromeTooltip:Show(true)
    if chromeTooltip.Raise ~= nil then pcall(function() chromeTooltip:Raise() end) end
end
local function HideWidgetTip()
    if chromeTooltip ~= nil then chromeTooltip:Show(false) end
end
local function BindWidgetTip(button, text)
    S.UI:SafeHandler(button, "OnEnter", function() ShowWidgetTip(button, text) end, "widget:tip_enter")
    S.UI:SafeHandler(button, "OnLeave", function() HideWidgetTip() end, "widget:tip_leave")
end

function WB:Create(name, title, sizePolicy)
    local placement = S.State.ui.widgets[name]
    local window = CreateEmptyWindow(S.PhysicalId("widget_" .. name), "UIParent")
    window.rsHudOwner = name
    window.rsUiOwner = "hud:" .. tostring(name)
    if S.UI ~= nil and type(S.UI.AdoptWidget) == "function" then S.UI:AdoptWidget(window, window.rsUiOwner, "widget_" .. tostring(name)) end
    -- Persistent HUD widgets stay on the normal UI layer. Native Backpack /
    -- Character / system windows opened later must be able to cover them.
    if window.Enable ~= nil then window:Enable(true) end
    if window.Clickable ~= nil then window:Clickable(true) end
    if window.UseResizing ~= nil then pcall(function() window:UseResizing(true) end) end
    S.Theme:AddBorder(window, false)
    S.Theme:AddGradientBackground(window, "panel", nil)

    local instance = {
        name = name,
        title = title,
        sizePolicy = sizePolicy,
        placement = placement,
        window = window,
        refs = {},
        standardHeight = sizePolicy.height,
        miniHeight = sizePolicy.miniHeight,
        -- Widgets may opt into a denser title bar without changing the shared
        -- chrome defaults used by the other Suite windows.
        chrome = {},
    }

    local titleBar = S.UI:CreatePanel(window, "widget_" .. name .. "_titlebar", 1, 1, 100, 28, "header")
    local titleLabel = S.UI:CreateLabel(titleBar, "widget_" .. name .. "_title", title, 8, 4, 170, 20, 12, nil, ALIGN_LEFT)
    local lockButton = S.UI:CreateButton(titleBar, "widget_" .. name .. "_lock", "锁", 0, 2, 28, 24, 10, false)
    local fontMinusButton = S.UI:CreateButton(titleBar, "widget_" .. name .. "_font_minus", "A-", 0, 2, 28, 24, 8, false)
    local fontPlusButton = S.UI:CreateButton(titleBar, "widget_" .. name .. "_font_plus", "A+", 0, 2, 28, 24, 8, false)
    local opacityButton = S.UI:CreateButton(titleBar, "widget_" .. name .. "_opacity", "90%", 0, 2, 38, 24, 8, false)
    local modeButton = S.UI:CreateButton(titleBar, "widget_" .. name .. "_mode", "收", 0, 2, 28, 24, 10, false)
    local closeButton = S.UI:CreateButton(titleBar, "widget_" .. name .. "_close", "X", 0, 2, 28, 24, 10, false)
    local resizeHandle = S.UI:CreateButton(window, "widget_" .. name .. "_resize", "拖", 0, 0, 18, 18, 8, false)

    instance.refs.titleBar = titleBar
    instance.refs.titleLabel = titleLabel
    instance.refs.lockButton = lockButton
    instance.refs.fontMinusButton = fontMinusButton
    instance.refs.fontPlusButton = fontPlusButton
    instance.refs.opacityButton = opacityButton
    instance.refs.modeButton = modeButton
    instance.refs.closeButton = closeButton
    instance.refs.resizeHandle = resizeHandle

    if type(titleBar.EnableDrag) == "function" then titleBar:EnableDrag(true) end
    if type(titleBar.Clickable) == "function" then titleBar:Clickable(true) end
    if type(resizeHandle.EnableDrag) == "function" then resizeHandle:EnableDrag(true) end

    -- Explain the single-glyph title-bar buttons on hover (shared tooltip).
    BindWidgetTip(lockButton, "锁定 / 拖动 悬浮窗")
    BindWidgetTip(fontMinusButton, "缩小字体")
    BindWidgetTip(fontPlusButton, "放大字体")
    BindWidgetTip(opacityButton, "切换背景透明度")
    BindWidgetTip(modeButton, "折叠 / 展开 悬浮窗")
    BindWidgetTip(closeButton, "关闭悬浮窗；可在 HUD 管理中隐藏此关闭键")

    local function IsEffectivelyLocked()
        if S.HudManager ~= nil and S.HudManager:Get(name) ~= nil then return S.HudManager:IsLocked(name) end
        return placement.locked == true
    end

    S.UI:SafeHandler(titleBar, "OnDragStart", function()
        if IsEffectivelyLocked() or placement.clickThrough == true then return false end
        titleBar.rsMoving = true
        titleBar.rsSafeMoving = S.Layout ~= nil and type(S.Layout.BeginSafeMove) == "function"
            and S.Layout:BeginSafeMove("hud_" .. tostring(name), window, { clamp = true }) == true
        if titleBar.rsSafeMoving == true then return true end
        if type(window.StartMoving) ~= "function" then titleBar.rsMoving = false; return false end
        -- Native fallback only: compact widgets must freeze min/max before
        -- StartMoving() or RU may briefly normalize them to the full extent.
        if placement.mode ~= "standard" and type(instance.ApplyResizePolicy) == "function" then instance:ApplyResizePolicy(false) end
        window:StartMoving()
        return true
    end, "widget:" .. name .. ":drag_start")

    S.UI:SafeHandler(titleBar, "OnDragStop", function()
        if titleBar.rsSafeMoving == true and S.Layout ~= nil and type(S.Layout.EndSafeMove) == "function" then
            S.Layout:EndSafeMove("hud_" .. tostring(name), false)
        elseif type(window.StopMovingOrSizing) == "function" then
            window:StopMovingOrSizing()
        end
        titleBar.rsSafeMoving = false
        titleBar.rsMoving = false
        placement.userMoved = true
        if placement.mode ~= "standard" then
            local compactW, compactH = instance:GetTargetSize()
            instance:ApplyResizePolicy(false, compactW, compactH)
            if window.SetExtent ~= nil then pcall(function() window:SetExtent(compactW, compactH) end) end
        end
        S.Layout:SnapAndStore(placement, window)
        S.Storage:RequestSave()
        instance:ApplyLayout(false)
        return true
    end, "widget:" .. name .. ":drag_stop")

    S.UI:SafeHandler(resizeHandle, "OnDragStart", function()
        if IsEffectivelyLocked() or placement.clickThrough == true or placement.mode ~= "standard" or S.HudManager == nil or S.HudManager:IsEditMode() ~= true then return false end
        if type(window.StartSizing) ~= "function" then return false end
        window:StartSizing("BOTTOMRIGHT")
        return true
    end, "widget:" .. name .. ":resize_start")

    S.UI:SafeHandler(resizeHandle, "OnDragStop", function()
        if type(window.StopMovingOrSizing) == "function" then window:StopMovingOrSizing() end
        if placement.mode ~= "standard" then return true end
        local context = S.Layout:GetContext()
        local _, _, logicalW, logicalH = S.Layout:GetLogicalRect(window)
        local minW = (tonumber(sizePolicy.minWidth) or tonumber(sizePolicy.width) or 300) * context.addonScale
        local minH = (tonumber(sizePolicy.minHeight) or tonumber(sizePolicy.height) or 220) * context.addonScale
        local maxW = math.min((tonumber(sizePolicy.maxWidth) or 1200) * context.addonScale, context.usableWidth)
        local maxH = math.min((tonumber(sizePolicy.maxHeight) or 900) * context.addonScale, context.usableHeight)
        logicalW = Clamp(logicalW, math.min(minW, maxW), maxW)
        logicalH = Clamp(logicalH, math.min(minH, maxH), maxH)
        placement.width = logicalW / context.addonScale
        placement.height = logicalH / context.addonScale
        placement.userMoved = true
        S.Layout:SnapAndStore(placement, window)
        instance:ApplyLayout(false)
        S.Storage:RequestSave()
        return true
    end, "widget:" .. name .. ":resize_stop")

    S.UI:SafeHandler(lockButton, "OnClick", function()
        if S.HudManager ~= nil and S.HudManager:Get(name) ~= nil then
            S.HudManager:ToggleLocked(name)
        else
            placement.locked = not (placement.locked == true)
            instance:RefreshChrome()
            instance:ApplyLayout(false)
            S.Storage:RequestSave()
        end
    end, "widget:" .. name .. ":lock")

    S.UI:SafeHandler(opacityButton, "OnClick", function()
        local current = S.HudManager ~= nil and S.HudManager:GetEffectiveBackgroundAlpha(name) or (tonumber(placement.backgroundAlpha) or tonumber(placement.opacity) or 0.90)
        local nextValue = NextOpacity(current, name == "event")
        if S.HudManager ~= nil and S.HudManager:Get(name) ~= nil then S.HudManager:SetBackgroundAlpha(name, nextValue)
        else placement.backgroundAlpha = nextValue; placement.backgroundInherited = false; placement.opacity = nil; instance:ApplyAppearance(); S.Storage:RequestSave() end
    end, "widget:" .. name .. ":opacity")

    S.UI:SafeHandler(fontMinusButton, "OnClick", function()
        if S.HudManager ~= nil and S.HudManager:Get(name) ~= nil then S.HudManager:AdjustFontScale(name, -0.10) end
    end, "widget:" .. name .. ":font_minus")
    S.UI:SafeHandler(fontPlusButton, "OnClick", function()
        if S.HudManager ~= nil and S.HudManager:Get(name) ~= nil then S.HudManager:AdjustFontScale(name, 0.10) end
    end, "widget:" .. name .. ":font_plus")

    -- The title-bar button is a real minimize/restore toggle.  Previous
    -- versions entered mini mode first; the widget-specific layout then hid
    -- the whole title bar, including the only control that could restore it.
    -- Any legacy mini placement is therefore restored to standard on click.
    S.UI:SafeHandler(modeButton, "OnClick", function()
        HideWidgetTip()
        local collapsed = placement.mode ~= "collapsed" and placement.mode ~= "mini"
        if S.HudManager ~= nil and S.HudManager:Get(name) ~= nil then
            S.HudManager:SetCollapsed(name, collapsed, true)
        else
            placement.mode = collapsed and "collapsed" or "standard"
            placement.collapsed = collapsed
            instance:ApplyLayout(false)
            S.Storage:RequestSave()
        end
    end, "widget:" .. name .. ":mode")

    S.UI:SafeHandler(closeButton, "OnClick", function()
        HideWidgetTip()
        if S.HudManager ~= nil and S.HudManager:Get(name) ~= nil then
            S.HudManager:SetVisible(name, false, true)
        else
            placement.visible = false
            window:Show(false)
            S.Storage:RequestSave()
        end
    end, "widget:" .. name .. ":close")

    function instance:ApplyEffectiveVisibility(visible)
        if type(self.OnEffectiveVisibilityChanged) == "function" then
            pcall(function() self:OnEffectiveVisibilityChanged(visible == true) end)
        end
        if visible == true then
            self:ApplyLayout(false)
            window:Show(true)
            if window.Raise ~= nil then pcall(function() window:Raise() end) end
            if window.CorrectOffsetByScreen ~= nil then pcall(function() window:CorrectOffsetByScreen() end) end
        else
            HideWidgetTip()
            window:Show(false)
        end
    end

    function instance:SetVisible(visible)
        placement.visible = visible == true
        if S.HudManager ~= nil and S.HudManager:Get(name) ~= nil then
            S.HudManager:Apply(name)
        else
            self:ApplyEffectiveVisibility(placement.visible)
        end
    end

    function instance:ApplyLock()
        self:RefreshChrome()
        if placement.clickThrough ~= true then
            if type(titleBar.EnableDrag) == "function" then titleBar:EnableDrag(not IsEffectivelyLocked()) end
            if type(resizeHandle.EnableDrag) == "function" then
                resizeHandle:EnableDrag(not IsEffectivelyLocked() and placement.mode == "standard"
                    and S.HudManager ~= nil and S.HudManager:IsEditMode())
            end
        end
    end

    function instance:SetClickThrough(enabled)
        placement.clickThrough = enabled == true
        SetPick(window, not placement.clickThrough)
        if placement.clickThrough then
            if type(titleBar.EnableDrag) == "function" then titleBar:EnableDrag(false) end
            if type(resizeHandle.EnableDrag) == "function" then resizeHandle:EnableDrag(false) end
        else
            if type(titleBar.EnableDrag) == "function" then titleBar:EnableDrag(not IsEffectivelyLocked()) end
            if type(resizeHandle.EnableDrag) == "function" then resizeHandle:EnableDrag(not IsEffectivelyLocked() and placement.mode == "standard" and S.HudManager ~= nil and S.HudManager:IsEditMode()) end
        end
    end

    function instance:GetFontScale()
        if S.HudManager ~= nil and S.HudManager:Get(name) ~= nil then return S.HudManager:GetEffectiveFontScale(name) end
        return tonumber(placement.fontScale) or 1.0
    end
    function instance:IsCompactMode()
        if S.HudManager ~= nil and S.HudManager:Get(name) ~= nil then return S.HudManager:IsCompact(name) end
        return placement.compact == true
    end
    function instance:RefreshChrome()
        lockButton:SetText(placement.locked and "锁" or "动")
        local displayTitle = tostring(placement.customTitle or "")
        if displayTitle == "" then displayTitle = tostring(title or name) end
        titleLabel:SetText(displayTitle)
        local opacity = S.HudManager ~= nil and S.HudManager:Get(name) ~= nil and S.HudManager:GetEffectiveBackgroundAlpha(name) or (tonumber(placement.backgroundAlpha) or tonumber(placement.opacity) or 0.90)
        opacityButton:SetText(tostring(math.floor(opacity * 100 + 0.5)) .. "%")
        if placement.mode == "standard" then modeButton:SetText("收") else modeButton:SetText("展") end
    end

    -- Apply only drawables/controls owned by this HUD. Ownership is stamped at
    -- creation time; no GetParent()/tree walk is used, avoiding the historical
    -- ArcheRage crash path while still letting Background Alpha reach content.
    function instance:ApplyBackgroundOpacity()
        local opacity = S.HudManager ~= nil and S.HudManager:Get(name) ~= nil and S.HudManager:GetEffectiveBackgroundAlpha(name) or (tonumber(placement.backgroundAlpha) or tonumber(placement.opacity) or 0.90)
        for _, control in pairs(S.UI.controls or {}) do
            if type(control) ~= "table" and type(control) ~= "userdata" then
                -- no-op: ArcheRage widgets are userdata on some builds and tables on others
            end
            if control ~= nil and control.rsHudOwner == name then S.Theme:SetBackgroundOpacity(control, opacity) end
        end
        S.Theme:SetBackgroundOpacity(window, opacity)
        if type(self.OnApplyBackgroundOpacity) == "function" then self:OnApplyBackgroundOpacity(opacity) end
    end

    function instance:ApplyFontScale()
        local scale = self:GetFontScale()
        for _, control in pairs(S.UI.controls or {}) do
            if control ~= nil and control.rsHudOwner == name and tonumber(control.rsBaseFontSize) ~= nil and control.style ~= nil and type(control.style.SetFontSize) == "function" then
                pcall(function() control.style:SetFontSize(math.max(6, tonumber(control.rsBaseFontSize) * scale)) end)
            end
        end
    end

    function instance:ApplyAppearance()
        self:ApplyFontScale()
        self:ApplyBackgroundOpacity()
        self:RefreshChrome()
        if type(self.ApplyLayout) == "function" then self:ApplyLayout(false) end
    end

    function instance:ApplyResizePolicy(standard, width, height, context)
        context = context or S.Layout:GetContext()
        local scale = context.addonScale
        if standard == true then
            local minW = math.min((tonumber(sizePolicy.minWidth) or 260) * scale, context.usableWidth)
            local minH = math.min((tonumber(sizePolicy.minHeight) or 180) * scale, context.usableHeight)
            local maxW = math.min((tonumber(sizePolicy.maxWidth) or 1200) * scale, context.usableWidth)
            local maxH = math.min((tonumber(sizePolicy.maxHeight) or 900) * scale, context.usableHeight)
            if window.UseResizing ~= nil then pcall(function() window:UseResizing(true) end) end
            if window.SetMinResizingExtent ~= nil then pcall(function() window:SetMinResizingExtent(minW, minH) end) end
            if window.SetMaxResizingExtent ~= nil then pcall(function() window:SetMaxResizingExtent(maxW, maxH) end) end
            return
        end

        -- Compact/collapsed windows deliberately violate the standard minimum
        -- height. Pin native min/max to the compact extent and turn resizing off
        -- so StartMoving/StopMoving cannot normalize them back to full size.
        width = tonumber(width)
        height = tonumber(height)
        if width == nil or height == nil then width, height = self:GetTargetSize() end
        if window.UseResizing ~= nil then pcall(function() window:UseResizing(false) end) end
        if window.SetMinResizingExtent ~= nil then pcall(function() window:SetMinResizingExtent(width, height) end) end
        if window.SetMaxResizingExtent ~= nil then pcall(function() window:SetMaxResizingExtent(width, height) end) end
    end

    function instance:GetTargetSize()
        local context = S.Layout:GetContext()
        local scale = context.addonScale
        if placement.mode == "mini" then
            -- Legacy mini mode remains loadable and, critically, keeps enough
            -- height for a visible title bar plus the compact summary.
            return math.min(math.max(260, sizePolicy.miniWidth) * scale, context.usableWidth), math.min(math.max(58, sizePolicy.miniHeight or 0) * scale, context.usableHeight)
        elseif placement.mode == "collapsed" then
            -- Collapsed chrome only needs title + restore. A widget may
            -- explicitly opt into a smaller collapsed width/title height.
            local collapsedW = tonumber(sizePolicy.collapsedWidth) or 260
            local collapsedH = tonumber(self.chrome and self.chrome.titleHeight) or 28
            return math.min(math.max(120, collapsedW) * scale, context.usableWidth), math.min((collapsedH + 2) * scale, context.usableHeight)
        end
        local designW = tonumber(placement.width) or tonumber(sizePolicy.width) or 400
        local designH = tonumber(placement.height) or tonumber(sizePolicy.height) or 300
        designW = Clamp(designW, tonumber(sizePolicy.minWidth) or 260, tonumber(sizePolicy.maxWidth) or 1200)
        designH = Clamp(designH, tonumber(sizePolicy.minHeight) or 180, tonumber(sizePolicy.maxHeight) or 900)
        return math.min(designW * scale, context.usableWidth), math.min(designH * scale, context.usableHeight)
    end

    function instance:ApplyLayout(fromMetricsChange)
        local width, height = self:GetTargetSize()
        local context = S.Layout:GetContext()
        local standard = placement.mode == "standard"
        -- Apply the native resize policy *before* SetExtent/ApplyPlacement.
        -- Both collapse and restore otherwise inherit the previous mode's stale
        -- min/max extents on some RU client builds.
        self:ApplyResizePolicy(standard, width, height, context)
        S.Layout:ApplyPlacement(window, placement, width, height)
        local scale = context.addonScale
        local chrome = type(self.chrome) == "table" and self.chrome or {}
        local titleHeight = (tonumber(chrome.titleHeight) or 28) * scale
        titleBar:SetExtent(width - 2, titleHeight)
        S.UI:SetAnchor(titleBar, window, 1, 1)

        local buttonSize = (tonumber(chrome.buttonSize) or 24) * scale
        local opacityWidth = (tonumber(chrome.opacityWidth) or 38) * scale
        local density = self:IsCompactMode() and 0.72 or 1.00
        local buttonGap = (tonumber(chrome.buttonGap) or 2) * scale * density
        local rightX = width - (tonumber(chrome.rightPadding) or 4) * scale * density
        local compactChrome = placement.mode ~= "standard"
        local showLock = not compactChrome and width >= 150 * scale
        local showOpacity = not compactChrome and width >= 195 * scale
        local showFont = not compactChrome and width >= 250 * scale
        lockButton:Show(showLock)
        fontMinusButton:Show(showFont)
        fontPlusButton:Show(showFont)
        opacityButton:Show(showOpacity)
        modeButton:Show(true)
        -- Long-lived HUDs are hidden from the Suite HUD manager. Do not expose
        -- an in-HUD X that can strand users who do not know how to restore it.
        -- The legacy hudCloseButtonEnabled setting is retained for save migration
        -- compatibility but intentionally no longer drives runtime chrome.
        local showClose = false
        closeButton:Show(false)
        local controls = {}
        if showClose then controls[#controls + 1] = { control = closeButton, width = buttonSize } end
        controls[#controls + 1] = { control = modeButton, width = buttonSize }
        if showOpacity then controls[#controls + 1] = { control = opacityButton, width = opacityWidth } end
        if showFont then
            controls[#controls + 1] = { control = fontPlusButton, width = buttonSize }
            controls[#controls + 1] = { control = fontMinusButton, width = buttonSize }
        end
        if showLock then controls[#controls + 1] = { control = lockButton, width = buttonSize } end
        for _, item in ipairs(controls) do
            rightX = rightX - item.width
            item.control:SetExtent(item.width, buttonSize)
            local buttonY = math.max(0, (titleHeight - buttonSize) / 2)
            S.UI:SetAnchor(item.control, titleBar, rightX, buttonY)
            rightX = rightX - buttonGap
        end
        local titleX = (tonumber(chrome.titleX) or 8) * scale * density
        local titleLabelH = math.max(12 * scale, titleHeight - 4 * scale)
        titleLabel:SetExtent(math.max(30, rightX - titleX), titleLabelH)
        S.UI:SetAnchor(titleLabel, titleBar, titleX, math.max(0, (titleHeight - titleLabelH) / 2))
        if titleLabel.style ~= nil and tonumber(chrome.titleFontSize) ~= nil then
            titleLabel.style:SetFontSize(tonumber(chrome.titleFontSize) * scale * self:GetFontScale())
        end
        if lockButton.style ~= nil and tonumber(chrome.controlFontSize) ~= nil then lockButton.style:SetFontSize(tonumber(chrome.controlFontSize) * scale * self:GetFontScale()) end
        if fontMinusButton.style ~= nil and tonumber(chrome.controlFontSize) ~= nil then fontMinusButton.style:SetFontSize(math.max(6, tonumber(chrome.controlFontSize) * scale * self:GetFontScale())) end
        if fontPlusButton.style ~= nil and tonumber(chrome.controlFontSize) ~= nil then fontPlusButton.style:SetFontSize(math.max(6, tonumber(chrome.controlFontSize) * scale * self:GetFontScale())) end
        if opacityButton.style ~= nil and tonumber(chrome.opacityFontSize) ~= nil then opacityButton.style:SetFontSize(tonumber(chrome.opacityFontSize) * scale * self:GetFontScale()) end
        if modeButton.style ~= nil and tonumber(chrome.controlFontSize) ~= nil then modeButton.style:SetFontSize(tonumber(chrome.controlFontSize) * scale * self:GetFontScale()) end
        if closeButton.style ~= nil and tonumber(chrome.controlFontSize) ~= nil then closeButton.style:SetFontSize(tonumber(chrome.controlFontSize) * scale * self:GetFontScale()) end

        local editMode = S.HudManager ~= nil and S.HudManager:IsEditMode() == true
        local canResize = editMode and standard and not IsEffectivelyLocked() and placement.clickThrough ~= true
        resizeHandle:Show(editMode and standard)
        resizeHandle:SetExtent(18 * scale, 18 * scale)
        if resizeHandle.RemoveAllAnchors ~= nil then resizeHandle:RemoveAllAnchors() end
        resizeHandle:AddAnchor("BOTTOMRIGHT", window, -2 * scale, -2 * scale)
        SetPick(resizeHandle, canResize)
        if type(resizeHandle.EnableDrag) == "function" then resizeHandle:EnableDrag(canResize) end
        -- The resize handle is created before widget-specific content, so raise
        -- it after every layout pass to keep it interactable above scroll rows.
        if resizeHandle.SetDrawPriority ~= nil then pcall(function() resizeHandle:SetDrawPriority(10000) end) end
        if resizeHandle.Raise ~= nil then pcall(function() resizeHandle:Raise() end) end

        -- Base font scaling is applied before module-specific layout so a HUD
        -- with its own responsive typography (for example Activities) can make
        -- the final, content-aware font decision without being overwritten.
        self:ApplyFontScale()
        if self.OnLayout ~= nil then self:OnLayout(width, height, titleHeight, placement.mode, fromMetricsChange == true) end
        self:RefreshChrome()
        self:SetClickThrough(placement.clickThrough == true)
        self:ApplyBackgroundOpacity()
        self:ApplyEditMode(editMode)
        local effectiveVisible = placement.visible == true
        if S.HudManager ~= nil and S.HudManager:Get(name) ~= nil then effectiveVisible = S.HudManager:IsEffectiveVisible(name) end
        window:Show(effectiveVisible)
        if effectiveVisible and window.CorrectOffsetByScreen ~= nil then pcall(function() window:CorrectOffsetByScreen() end) end
    end

    function instance:ApplyEditMode(editing)
        local editMode = editing == true
        local showTitle = placement.mode ~= "standard" or placement.titleVisible ~= false or editMode
        titleBar:Show(showTitle)
        local standard = placement.mode == "standard"
        local canResize = editMode and standard and not IsEffectivelyLocked() and placement.clickThrough ~= true
        resizeHandle:Show(editMode and standard)
        SetPick(resizeHandle, canResize)
        if type(resizeHandle.EnableDrag) == "function" then resizeHandle:EnableDrag(canResize) end
    end

    function instance:Recover()
        -- Find/recover is deliberately non-destructive: keep size, title and
        -- appearance, only ensure the existing HUD remains operable on-screen.
        self:ApplyLayout(false)
        if window.CorrectOffsetByScreen ~= nil then pcall(function() window:CorrectOffsetByScreen() end) end
        if S.Layout ~= nil and type(S.Layout.StorePlacement) == "function" then
            S.Layout:StorePlacement(placement, window)
        end
        return true
    end

    function instance:Destroy()
        HideWidgetTip()
        pcall(function() window:Show(false) end)
    end

    S.UI.widgets[name] = instance
    if S.HudManager ~= nil then
        S.HudManager:Register({ Id=name, Title=title, ShortTitle=sizePolicy.shortTitle or title, Instance=instance })
    else
        window:Show(false)
    end
    return instance
end

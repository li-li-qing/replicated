------------------------------------------------------------------------
-- Replicated Suite - Responsive Layout Authority
------------------------------------------------------------------------

if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local C = S.Constants

S.Layout = {
    context = nil,
    invalidated = true,
    lastSignature = nil,
}
local L = S.Layout

local function Clamp(value, minimum, maximum)
    local number = tonumber(value) or 0
    if number < minimum then return minimum end
    if number > maximum then return maximum end
    return number
end

function L:BuildContext()
    local screenWidth, screenHeight, uiScale, logicalWidth, logicalHeight = S.Api:GetUiMetrics()
    local addonScale = Clamp(S.State.settings.addonScale or 1, C.MinAddonScale, C.MaxAddonScale)
    local designWidth = logicalWidth / addonScale
    local designHeight = logicalHeight / addonScale

    local breakpoint = "ULTRAWIDE"
    if designWidth < C.Breakpoint.COMPACT then
        breakpoint = "COMPACT"
    elseif designWidth < C.Breakpoint.STANDARD then
        breakpoint = "STANDARD"
    elseif designWidth < C.Breakpoint.WIDE then
        breakpoint = "WIDE"
    end

    local columns = 3
    if breakpoint == "COMPACT" then
        columns = designWidth < C.Breakpoint.NARROW_ONE_COLUMN and 1 or 2
    end

    local safe = C.SafeArea
    return {
        screenWidth = screenWidth,
        screenHeight = screenHeight,
        uiScale = uiScale,
        addonScale = addonScale,
        effectiveScale = uiScale * addonScale,
        logicalWidth = logicalWidth,
        logicalHeight = logicalHeight,
        designWidth = designWidth,
        designHeight = designHeight,
        safeLeft = safe,
        safeTop = safe,
        safeRight = safe,
        safeBottom = safe,
        usableWidth = math.max(1, logicalWidth - safe * 2),
        usableHeight = math.max(1, logicalHeight - safe * 2),
        aspectRatio = logicalHeight > 0 and logicalWidth / logicalHeight or 1,
        breakpoint = breakpoint,
        columns = columns,
    }
end

function L:GetContext(force)
    if self.context == nil or self.invalidated == true or force == true then
        self.context = self:BuildContext()
        self.invalidated = false
    end
    return self.context
end

function L:Scale(value)
    return (tonumber(value) or 0) * self:GetContext().addonScale
end

function L:Invalidate()
    self.invalidated = true
end

function L:MakeSignature(context)
    return table.concat({
        tostring(math.floor((context.screenWidth or 0) + 0.5)),
        tostring(math.floor((context.screenHeight or 0) + 0.5)),
        string.format("%.4f", tonumber(context.uiScale) or 1),
        string.format("%.2f", tonumber(context.addonScale) or 1),
        tostring(context.breakpoint),
        tostring(context.columns),
    }, ":")
end

function L:PrimeCurrentSignature()
    local context = self:GetContext(true)
    self.lastSignature = self:MakeSignature(context)
    return context
end

function L:PollChanges()
    local fresh = self:BuildContext()
    local signature = self:MakeSignature(fresh)

    -- Bootstrap is a real layout transition too. Older builds only remembered
    -- the first post-load signature and returned without reflowing. If UIParent
    -- still exposed provisional metrics while the addon was constructing its
    -- widgets, the dashboard stayed packed against those stale dimensions until
    -- the user manually resized the window. Treat the first observation as a
    -- reflow unless Runtime explicitly primed the startup signature.
    if self.lastSignature == nil then
        self.lastSignature = signature
        self.context = fresh
        self.invalidated = false
        if S.UI ~= nil and type(S.UI.ApplyResponsiveLayout) == "function" then
            S.UI:ApplyResponsiveLayout(true)
        end
        return true
    end
    if signature ~= self.lastSignature then
        self.lastSignature = signature
        self.context = fresh
        self.invalidated = false
        if S.UI ~= nil and type(S.UI.ApplyResponsiveLayout) == "function" then
            S.UI:ApplyResponsiveLayout(true)
        end
        return true
    end
    return false
end

function L:GetLogicalRect(widget)
    local context = self:GetContext()
    local x, y, width, height = nil, nil, nil, nil
    if widget ~= nil and widget.GetEffectiveOffset ~= nil then
        local ok, a, b = pcall(function() return widget:GetEffectiveOffset() end)
        if ok then x, y = tonumber(a), tonumber(b) end
    end
    if widget ~= nil and widget.GetEffectiveExtent ~= nil then
        local ok, a, b = pcall(function() return widget:GetEffectiveExtent() end)
        if ok then width, height = tonumber(a), tonumber(b) end
    end
    if x ~= nil and y ~= nil then
        x = x / context.uiScale
        y = y / context.uiScale
    else
        local ok, a, b = pcall(function() return widget:GetOffset() end)
        if ok then x, y = tonumber(a) or 0, tonumber(b) or 0 else x, y = 0, 0 end
    end
    if width ~= nil and height ~= nil then
        width = width / context.uiScale
        height = height / context.uiScale
    else
        width = tonumber(widget and widget:GetWidth()) or 1
        height = tonumber(widget and widget:GetHeight()) or 1
    end
    return x, y, width, height
end

------------------------------------------------------------------------
-- Resolution Safety Authority
--
-- Persistence remains owned by each Domain (Suite placement, DPS rects, Gear
-- quick positions, Healer anchors, etc.).  This layer only guarantees that the
-- live presentation is operable on the CURRENT logical UIParent canvas.  A
-- resolution fallback is therefore deliberately non-persistent unless the user
-- explicitly drags/saves the control in that resolution.
------------------------------------------------------------------------
L.floatingRegistry = L.floatingRegistry or {}
L.safeDrag = L.safeDrag or nil
L.safeDragProxy = L.safeDragProxy or nil

local function WidgetVisible(widget)
    if widget == nil then return false end
    if type(widget.IsVisible) ~= "function" then return true end
    local ok, value = pcall(function() return widget:IsVisible() end)
    return not ok or value == true
end

function L:GetSafeSpawn(index, width, height, options)
    options = type(options) == "table" and options or {}
    local context = self:GetContext()
    local safety = C.ResolutionSafety or {}
    local edge = math.max(0, tonumber(options.edge) or tonumber(safety.edge) or tonumber(C.SafeArea) or 12)
    width = math.max(1, tonumber(width) or 1)
    height = math.max(1, tonumber(height) or 1)
    local maxX = math.max(edge, context.logicalWidth - edge - width)
    local maxY = math.max(edge, context.logicalHeight - edge - height)
    local baseX = Clamp(tonumber(options.baseX) or tonumber(safety.spawnX) or 300, edge, maxX)
    local baseY = Clamp(tonumber(options.baseY) or tonumber(safety.spawnY) or 100, edge, maxY)
    local gapX = math.max(0, tonumber(options.gapX) or tonumber(safety.spawnGapX) or 8)
    local gapY = math.max(0, tonumber(options.gapY) or tonumber(safety.spawnGapY) or 8)
    local stepX = math.max(1, width + gapX)
    local stepY = math.max(1, height + gapY)
    local maxColumns = math.max(1, math.floor(tonumber(options.maxColumns) or tonumber(safety.maxColumns) or 4))
    local columnsThatFit = math.floor((context.logicalWidth - edge - baseX + gapX) / stepX)
    local columns = math.max(1, math.min(maxColumns, columnsThatFit))
    local n = math.max(0, math.floor(tonumber(index) or 1) - 1)
    local x = baseX + (n % columns) * stepX
    local y = baseY + math.floor(n / columns) * stepY
    return Clamp(x, edge, maxX), Clamp(y, edge, maxY)
end

function L:ClampTopLeft(x, y, width, height, options)
    options = type(options) == "table" and options or {}
    local context = self:GetContext()
    local edge = math.max(0, tonumber(options.edge) or context.safeLeft or C.SafeArea or 12)
    width = math.max(1, tonumber(width) or 1)
    height = math.max(1, tonumber(height) or 1)
    local maxX = math.max(edge, context.logicalWidth - edge - math.min(width, math.max(1, context.logicalWidth - edge * 2)))
    local maxY = math.max(edge, context.logicalHeight - edge - math.min(height, math.max(1, context.logicalHeight - edge * 2)))
    return Clamp(tonumber(x) or edge, edge, maxX), Clamp(tonumber(y) or edge, edge, maxY)
end

function L:IsRectFullyVisible(x, y, width, height, options)
    options = type(options) == "table" and options or {}
    local context = self:GetContext()
    local edge = math.max(0, tonumber(options.edge) or context.safeLeft or C.SafeArea or 12)
    x, y = tonumber(x), tonumber(y)
    width, height = math.max(1, tonumber(width) or 1), math.max(1, tonumber(height) or 1)
    if x == nil or y == nil then return false end
    return x >= edge and y >= edge
        and x + width <= context.logicalWidth - edge
        and y + height <= context.logicalHeight - edge
end

function L:EnsureWidgetVisible(widget, options)
    options = type(options) == "table" and options or {}
    if widget == nil then return false end
    if options.onlyWhenVisible ~= false and not WidgetVisible(widget) then return false end
    local context = self:GetContext()
    local x, y, width, height = self:GetLogicalRect(widget)
    local edge = math.max(0, tonumber(options.edge) or context.safeLeft or C.SafeArea or 12)
    local targetWidth, targetHeight = width, height
    if options.fitSize == true then
        targetWidth = math.min(targetWidth, math.max(1, context.logicalWidth - edge * 2))
        targetHeight = math.min(targetHeight, math.max(1, context.logicalHeight - edge * 2))
    end
    local safeX, safeY = self:ClampTopLeft(x, y, targetWidth, targetHeight, { edge = edge })
    local changed = math.abs((tonumber(x) or 0) - safeX) >= 0.5 or math.abs((tonumber(y) or 0) - safeY) >= 0.5
        or math.abs((tonumber(width) or 1) - targetWidth) >= 0.5 or math.abs((tonumber(height) or 1) - targetHeight) >= 0.5
    if changed then
        if widget.RemoveAllAnchors ~= nil then widget:RemoveAllAnchors() end
        widget:AddAnchor("TOPLEFT", "UIParent", safeX, safeY)
        if options.fitSize == true and widget.SetExtent ~= nil then widget:SetExtent(targetWidth, targetHeight) end
    end
    return changed, safeX, safeY, targetWidth, targetHeight
end

function L:RegisterFloating(id, widget, options)
    id = tostring(id or "")
    if id == "" or widget == nil then return false end
    self.floatingRegistry[id] = { widget = widget, options = type(options) == "table" and options or {} }
    local item = self.floatingRegistry[id]
    if item.options.ensureNow ~= false then
        if type(item.options.onMetricsChanged) == "function" then
            pcall(item.options.onMetricsChanged, false)
        else
            self:EnsureWidgetVisible(widget, item.options)
        end
    end
    return true
end

function L:UnregisterFloating(id)
    self.floatingRegistry[tostring(id or "")] = nil
end

function L:RefreshFloatingSafety(metricsChanged)
    if self._refreshingFloatingSafety == true then return end
    self._refreshingFloatingSafety = true
    for _, item in pairs(self.floatingRegistry or {}) do
        local widget = item and item.widget or nil
        local options = item and item.options or nil
        if widget ~= nil and type(options) == "table" then
            if type(options.onMetricsChanged) == "function" then
                pcall(options.onMetricsChanged, metricsChanged == true)
            else
                self:EnsureWidgetVisible(widget, options)
            end
        end
    end
    self._refreshingFloatingSafety = false
end

local function EnsureSafeDragProxy()
    if L.safeDragProxy ~= nil then return L.safeDragProxy end
    if type(CreateEmptyWindow) ~= "function" then return nil end
    local ok, proxy = pcall(function() return CreateEmptyWindow(S.PhysicalId("resolution_drag_proxy"), "UIParent") end)
    if not ok or proxy == nil then return nil end
    proxy:SetExtent(1, 1)
    proxy:AddAnchor("TOPLEFT", "UIParent", 0, 0)
    if proxy.Enable ~= nil then pcall(function() proxy:Enable(true) end) end
    if proxy.Clickable ~= nil then pcall(function() proxy:Clickable(false) end) end
    if proxy.EnablePick ~= nil then pcall(function() proxy:EnablePick(false, true) end) end
    proxy:Show(false)
    L.safeDragProxy = proxy
    return proxy
end

function L:StepSafeMove()
    -- During a safe drag the target is anchored to the native moving proxy, so
    -- CryEngine performs the visual follow at native frame rate with zero Lua
    -- polling. This function remains as a compatibility/query point and only
    -- reports the current logical target position.
    local drag = self.safeDrag
    if type(drag) ~= "table" or drag.target == nil then return false end
    local x, y = self:GetLogicalRect(drag.target)
    drag.lastX, drag.lastY = tonumber(x) or drag.startX, tonumber(y) or drag.startY
    return true
end

function L:BeginSafeMove(key, target, options)
    -- IMPORTANT: do not try to transfer an active drag gesture to a different
    -- invisible window here. ArcheRage RU does not reliably hand the current
    -- mouse-drag capture to a proxy that did not receive OnDragStart itself.
    -- The old global proxy path could therefore return success while the proxy
    -- never moved, which made every caller skip its proven native StartMoving()
    -- fallback and left Suite/Gear/Healer/Plates/HUD windows undraggable.
    --
    -- Resolution safety remains centralized in RegisterFloating(),
    -- RefreshFloatingSafety(), EnsureWidgetVisible() and the drag-stop clamps.
    -- Consumers must use their native drag path unless a module owns a complete
    -- proxy transaction (DPS ranking windows do, including their own frame
    -- driver). Returning false is an explicit capability result, not an error.
    return false
end

function L:EndSafeMove(key, cancel)
    local drag = self.safeDrag
    if type(drag) ~= "table" then return false end
    if key ~= nil and tostring(key) ~= tostring(drag.key) then return false end

    local x, y = drag.startX, drag.startY
    if cancel ~= true and drag.target ~= nil then
        local currentX, currentY = self:GetLogicalRect(drag.target)
        x, y = tonumber(currentX) or drag.startX, tonumber(currentY) or drag.startY
        if drag.clamp ~= false then
            x, y = self:ClampTopLeft(x, y, drag.width, drag.height, drag.options)
        end
    end

    if drag.proxy ~= nil then
        if drag.proxy.StopMovingOrSizing ~= nil then pcall(function() drag.proxy:StopMovingOrSizing() end) end
    end
    if drag.target ~= nil then
        if drag.target.RemoveAllAnchors ~= nil then drag.target:RemoveAllAnchors() end
        drag.target:AddAnchor("TOPLEFT", "UIParent", x, y)
    end
    if drag.proxy ~= nil then
        drag.proxy:Show(false)
        if drag.proxy.RemoveAllAnchors ~= nil then drag.proxy:RemoveAllAnchors() end
        drag.proxy:AddAnchor("TOPLEFT", "UIParent", 0, 0)
        if drag.proxy.SetExtent ~= nil then drag.proxy:SetExtent(1, 1) end
    end
    local width, height = drag.width, drag.height
    self.safeDrag = nil
    return true, x, y, width, height
end

function L:StorePlacement(target, widget)
    if type(target) ~= "table" or widget == nil then return end
    local context = self:GetContext()
    local x, y, width, height = self:GetLogicalRect(widget)
    width = Clamp(width, 1, context.usableWidth)
    height = Clamp(height, 1, context.usableHeight)
    x = Clamp(x, context.safeLeft, math.max(context.safeLeft, context.logicalWidth - context.safeRight - width))
    y = Clamp(y, context.safeTop, math.max(context.safeTop, context.logicalHeight - context.safeBottom - height))

    if x + width / 2 <= context.logicalWidth / 2 then
        target.anchorH = "LEFT"
        target.offsetX = math.max(0, x - context.safeLeft)
    else
        target.anchorH = "RIGHT"
        target.offsetX = math.max(0, context.logicalWidth - context.safeRight - x - width)
    end
    if y + height / 2 <= context.logicalHeight / 2 then
        target.anchorV = "TOP"
        target.offsetY = math.max(0, y - context.safeTop)
    else
        target.anchorV = "BOTTOM"
        target.offsetY = math.max(0, context.logicalHeight - context.safeBottom - y - height)
    end
    target.coordinateSpace = "logical-edge-v1"
    target.savedUiScale = context.uiScale
end

function L:ResolvePlacement(placement, width, height, defaultX, defaultY)
    local context = self:GetContext()
    width = Clamp(width, 1, context.usableWidth)
    height = Clamp(height, 1, context.usableHeight)

    local x = tonumber(defaultX) or context.safeLeft
    local y = tonumber(defaultY) or context.safeTop
    if type(placement) == "table" then
        local offsetX = math.max(0, tonumber(placement.offsetX) or 0)
        local offsetY = math.max(0, tonumber(placement.offsetY) or 0)
        if placement.anchorH == "RIGHT" then
            x = context.logicalWidth - context.safeRight - offsetX - width
        else
            x = context.safeLeft + offsetX
        end
        if placement.anchorV == "BOTTOM" then
            y = context.logicalHeight - context.safeBottom - offsetY - height
        else
            y = context.safeTop + offsetY
        end
    end

    x = Clamp(x, context.safeLeft, math.max(context.safeLeft, context.logicalWidth - context.safeRight - width))
    y = Clamp(y, context.safeTop, math.max(context.safeTop, context.logicalHeight - context.safeBottom - height))
    return x, y, width, height
end

function L:ApplyPlacement(widget, placement, width, height, defaultX, defaultY)
    if widget == nil then return end
    local x, y, resolvedWidth, resolvedHeight = self:ResolvePlacement(placement, width, height, defaultX, defaultY)
    if widget.RemoveAllAnchors ~= nil then widget:RemoveAllAnchors() end
    widget:AddAnchor("TOPLEFT", "UIParent", x, y)
    widget:SetExtent(resolvedWidth, resolvedHeight)
    return x, y, resolvedWidth, resolvedHeight
end

function L:SnapAndStore(target, widget)
    if widget == nil then return end
    local context = self:GetContext()
    local x, y, width, height = self:GetLogicalRect(widget)
    local snap = self:Scale(C.SnapDistance)
    local left = context.safeLeft
    local top = context.safeTop
    local right = context.logicalWidth - context.safeRight - width
    local bottom = context.logicalHeight - context.safeBottom - height

    -- HUD snapping is an editor-only affordance. Normal unlocked HUD dragging
    -- stays free, preventing the "window suddenly jumps" behavior called out in
    -- the v1.1 spec. The main Suite window keeps its historical edge snapping.
    local isHud = widget.rsHudOwner ~= nil
    local snapHud = isHud and S.HudManager ~= nil and S.HudManager:IsEditMode() == true
        and S.State.settings.hudSnapEnabled ~= false
    local snapScreen = (not isHud) or snapHud

    if snapScreen then
        if math.abs(x - left) <= snap then x = left end
        if math.abs(x - right) <= snap then x = right end
        if math.abs(y - top) <= snap then y = top end
        if math.abs(y - bottom) <= snap then y = bottom end
    end

    if snapHud and type(S.HudManager.GetSnapWindows) == "function" then
        local function SnapAxis(value, size, otherValue, otherSize)
            local candidates = {
                otherValue,                         -- left/top align
                otherValue + otherSize - size,      -- right/bottom align
                otherValue + otherSize,             -- place after
                otherValue - size,                  -- place before
            }
            local best, bestDistance = value, snap + 0.001
            for _, candidate in ipairs(candidates) do
                local distance = math.abs(value - candidate)
                if distance <= snap and distance < bestDistance then best, bestDistance = candidate, distance end
            end
            return best
        end
        for _, other in ipairs(S.HudManager:GetSnapWindows(widget)) do
            local ox, oy, ow, oh = self:GetLogicalRect(other)
            x = SnapAxis(x, width, ox, ow)
            y = SnapAxis(y, height, oy, oh)
        end
    end

    -- Persisted/live result always keeps an operable area inside the safe area.
    x = Clamp(x, left, math.max(left, right))
    y = Clamp(y, top, math.max(top, bottom))

    if widget.RemoveAllAnchors ~= nil then widget:RemoveAllAnchors() end
    widget:AddAnchor("TOPLEFT", "UIParent", x, y)
    self:StorePlacement(target, widget)
end

function L:GetMainSpec()
    local context = self:GetContext()
    local scale = context.addonScale
    local placement = S.State.ui.main or {}

    local defaultColumns = context.columns
    local baseWidth, baseHeight
    if defaultColumns == 3 then
        baseWidth, baseHeight = C.MainWindow.threeColumnWidth, C.MainWindow.threeColumnHeight
    elseif defaultColumns == 2 then
        baseWidth, baseHeight = C.MainWindow.twoColumnWidth, C.MainWindow.twoColumnHeight
    else
        baseWidth, baseHeight = C.MainWindow.oneColumnWidth, C.MainWindow.oneColumnHeight
    end

    local designWidth = tonumber(placement.width) or baseWidth
    local designHeight = tonumber(placement.height) or baseHeight
    designWidth = Clamp(designWidth, C.MainWindow.minWidth or 560, C.MainWindow.maxWidth or C.MainWindow.maxReadingWidth or 1180)
    designHeight = Clamp(designHeight, C.MainWindow.minHeight or 600, C.MainWindow.maxHeight or 900)

    local width = math.min(designWidth * scale, context.usableWidth)
    local height = math.min(designHeight * scale, context.usableHeight)

    -- Column count is derived from the *actual* user-sized main window, not
    -- just the physical monitor. This keeps cards readable when the user
    -- narrows the dashboard and lets a wider resized dashboard expose more.
    local actualDesignWidth = width / math.max(0.01, scale)
    local navDesignWidth = 82
    local actualContentDesignWidth = math.max(1, actualDesignWidth - navDesignWidth - (C.Layout.margin or 10) * 3)
    local fontDensity = math.max(1.0, math.min(1.50, tonumber(S.State.settings.fontScale) or 1.2))
    -- Larger typography needs more horizontal breathing room for the three-column
    -- dashboard.  The life page now gives the trade card a vertical two-row span, so
    -- keep two columns down to the practical window minimum instead of falling
    -- into an eight-row one-column stack that cannot fit vertically.
    local oneColumnThreshold = 400
    local threeColumnThreshold = 780 * fontDensity
    local columns = 3
    if actualContentDesignWidth < oneColumnThreshold then
        columns = 1
    elseif actualContentDesignWidth < threeColumnThreshold or context.breakpoint == "COMPACT" then
        columns = 2
    end

    local margin = C.Layout.margin * scale
    local titleHeight = C.Layout.titleHeight * scale * fontDensity
    local tabHeight = C.Layout.tabHeight * scale * math.max(1.0, math.min(1.15, fontDensity))
    local navWidth = navDesignWidth * scale
    local navGap = C.Layout.cardGap * scale
    return {
        width = width,
        height = height,
        columns = columns,
        margin = margin,
        titleHeight = titleHeight,
        tabHeight = tabHeight,
        navWidth = navWidth,
        navGap = navGap,
        contentX = margin + navWidth + navGap,
        contentY = titleHeight + margin,
        contentWidth = math.max(1, width - margin * 2 - navWidth - navGap),
        contentHeight = math.max(1, height - titleHeight - margin * 2),
        gap = C.Layout.cardGap * scale,
        rowHeight = C.Layout.rowHeight * scale * fontDensity,
        compactRowHeight = C.Layout.compactRowHeight * scale * fontDensity,
    }
end


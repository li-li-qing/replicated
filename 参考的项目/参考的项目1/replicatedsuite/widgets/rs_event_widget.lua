------------------------------------------------------------------------
-- Replicated Suite - Compact RU Event floating widget
-- Unified chronological list: activity | time/phase | quest progress.
-- Live conflict zones are normal rows now; Danger 1~5 (no authoritative timer)
-- are sorted behind every timed row by EventService.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.EventWidget = {}

local MAX_ROWS = 20

local function Clamp(value, minimum, maximum)
    local n = tonumber(value) or minimum
    if n < minimum then return minimum end
    if n > maximum then return maximum end
    return n
end

local function ResponsiveValue(width, minWidth, maxWidth, minValue, maxValue)
    local w = tonumber(width) or minWidth
    if w <= minWidth then return minValue end
    if w >= maxWidth then return maxValue end
    local t = (w - minWidth) / math.max(1, maxWidth - minWidth)
    return minValue + (maxValue - minValue) * t
end

local function ResponsiveFont(width, minFont, maxFont)
    return math.floor(ResponsiveValue(width, 140, 420, minFont, maxFont) + 0.5)
end

local function SetEllipsis(label, enabled)
    if label ~= nil and label.style ~= nil and label.style.SetEllipsis ~= nil then
        pcall(function() label.style:SetEllipsis(enabled == true) end)
    end
end

local function SetPick(widget, enabled)
    if widget == nil then return end
    if widget.EnablePick ~= nil then pcall(function() widget:EnablePick(enabled == true) end) end
    if widget.Clickable ~= nil then pcall(function() widget:Clickable(enabled == true) end) end
end

local function EventDisplayName(row, density)
    if type(row) ~= "table" then return "" end
    density = tostring(density or "full")
    if density == "ultra" then
        return tostring(row.microName or row.shortName or row.name or row.fullName or "")
    elseif density == "compact" then
        return tostring(row.shortName or row.name or row.fullName or "")
    end
    return tostring(row.fullName or row.name or "")
end

local function CompactRowStatus(text, density)
    local value = tostring(text or "--")
    density = tostring(density or "full")
    if density == "full" or density == "compact" then return value end

    -- Only the absolute minimum width abbreviates live phase markers. Upcoming
    -- scheduled activities already render the time itself (for example 20分),
    -- so there is no redundant "倒计时" prefix to compress.
    local payload = string.match(value, "^进行中%s+纷争%s+(.+)$")
    if payload ~= nil then return "进行 纷" .. payload end
    payload = string.match(value, "^进行中%s+战争%s+(.+)$")
    if payload ~= nil then return "进行 战" .. payload end
    payload = string.match(value, "^和平%s+(.+)$")
    if payload ~= nil then return "和" .. payload end
    local danger = string.match(value, "^危险(%d)阶段$")
    if danger ~= nil then return "危" .. danger end
    return value
end

function S.EventWidget.Create()
    local widget = S.WidgetBase:Create("event", "活动时间", S.Constants.Widget.event)
    widget.chrome = {
        titleHeight = 21,
        buttonSize = 17,
        opacityWidth = 27,
        buttonGap = 1,
        rightPadding = 2,
        titleX = 4,
        titleFontSize = 10,
        controlFontSize = 9,
        opacityFontSize = 8,
    }
    local win = widget.window
    widget.offset = 0
    widget.visibleRows = 12

    -- Typography buttons are owned by WidgetBase and write the same per-HUD
    -- appearance Authority used by HUD Manager. The legacy eventFontAdjust is
    -- still honored as a migration offset, but there is no second font state.
    local fontMinus = widget.refs.fontMinusButton
    local fontPlus = widget.refs.fontPlusButton

    -- One row = name | time/phase | task progress. All extents are hard column
    -- boundaries, so even a large user font cannot overlap a neighboring field.
    local rows = {}
    for i = 1, MAX_ROWS do
        local idx = i
        local name = S.UI:CreateLabel(win, "event_widget_name_" .. i, "", 0, 0, 180, 18, 10, nil, ALIGN_LEFT)
        local value = S.UI:CreateLabel(win, "event_widget_value_" .. i, "", 0, 0, 100, 18, 10, "blue", ALIGN_CENTER)
        local progress = S.UI:CreateLabel(win, "event_widget_progress_" .. i, "", 0, 0, 28, 18, 10, "yellow", ALIGN_RIGHT)
        SetEllipsis(name, false); SetEllipsis(value, false); SetEllipsis(progress, false)

        local hit = UIParent:CreateWidget("emptywidget", S.PhysicalId("event_widget_hit_" .. i), win)
        hit:SetExtent(280, 18)
        if hit.Enable ~= nil then hit:Enable(true) end
        SetPick(hit, true)
        hit:Show(false)
        rows[i] = { name = name, value = value, progress = progress, hit = hit, data = nil }
        name:Show(false); value:Show(false); progress:Show(false)

        S.UI:SafeHandler(hit, "OnClick", function()
            local row = rows[idx].data
            if row and row.questKey and S.Services and S.Services.Event then S.Services.Event:OpenTask(row) end
        end, "event:row:" .. i)
        S.UI:SafeHandler(hit, "OnRButtonUp", function()
            local row = rows[idx].data
            local service = S.Services and S.Services.Event
            if row ~= nil and service ~= nil and type(service.HideEvent) == "function" then service:HideEvent(row) end
        end, "event:hide:" .. i)
    end

    local mini = S.UI:CreateLabel(win, "event_widget_mini", "活动 --", 8, 4, 300, 22, 10, "blue", ALIGN_LEFT)
    mini:Show(false)

    local liveRefreshMs = 0
    local schedulerProgressSeen = false
    local function AdvanceLiveRefresh(dt)
        if not win:IsVisible() then return end
        local service = S.Services and S.Services.Event
        if service == nil or type(service.AdvanceVisibleClock) ~= "function" then return end
        local elapsed, schedulerProgressed = service:AdvanceVisibleClock(dt)
        liveRefreshMs = liveRefreshMs + (tonumber(elapsed) or 0)
        if schedulerProgressed == true then schedulerProgressSeen = true end
        if liveRefreshMs >= 1000 then
            liveRefreshMs = liveRefreshMs % 1000
            if schedulerProgressSeen ~= true and type(service.Refresh) == "function" then service:Refresh() end
            schedulerProgressSeen = false
            widget:Refresh()
        end
    end
    local liveHandlerInstalled = false
    local function SetLiveRefreshActive(active)
        if active == true and liveHandlerInstalled ~= true and type(win.SetHandler) == "function" then
            local handlerOk, handlerResult = pcall(function()
                return win:SetHandler("OnUpdate", function(_, dt)
                    local token = S.PerformanceMonitor and S.PerformanceMonitor:Begin("onupdate:event_widget") or nil
                    local ok, err = pcall(AdvanceLiveRefresh, dt)
                    if S.PerformanceMonitor ~= nil then S.PerformanceMonitor:End(token) end
                    if not ok then S.WarnOnce("event_widget_live_refresh", "活动悬浮窗刷新异常：" .. tostring(err)) end
                end)
            end)
            liveHandlerInstalled = handlerOk == true and handlerResult ~= false
            if not liveHandlerInstalled then S.WarnOnce("event_widget_live_handler", "活动悬浮窗实时刷新 Handler 绑定失败。") end
        elseif active ~= true and liveHandlerInstalled == true then
            if type(win.ReleaseHandler) == "function" then pcall(function() win:ReleaseHandler("OnUpdate") end) end
            liveHandlerInstalled = false
            liveRefreshMs = 0
            schedulerProgressSeen = false
        end
    end
    widget.OnEffectiveVisibilityChanged = function(_, visible) SetLiveRefreshActive(visible == true) end

    if win.EnableScroll ~= nil then pcall(function() win:EnableScroll(true) end) end
    S.UI:SafeHandler(win, "OnWheelUp", function()
        widget.offset = math.max(0, (tonumber(widget.offset) or 0) - 3)
        widget:Refresh()
    end, "event:wheel_up")
    S.UI:SafeHandler(win, "OnWheelDown", function()
        local events = S.State.data.events or {}
        local limit = math.min(tonumber(S.State.settings.eventMaxRows) or 20, #events)
        local maxOffset = math.max(0, limit - widget.visibleRows)
        widget.offset = math.min(maxOffset, (tonumber(widget.offset) or 0) + 3)
        widget:Refresh()
    end, "event:wheel_down")

    function widget:Refresh()
        local events = S.State.data.events or {}
        local limit = math.min(tonumber(S.State.settings.eventMaxRows) or 20, #events)
        local maxOffset = math.max(0, limit - self.visibleRows)
        self.offset = math.max(0, math.min(tonumber(self.offset) or 0, maxOffset))
        local standard = S.State.ui.widgets.event.mode == "standard"

        for i, w in ipairs(rows) do
            local index = self.offset + i
            local row = (i <= self.visibleRows and index <= limit) and events[index] or nil
            local show = standard and row ~= nil
            w.data = row
            w.name:Show(show); w.value:Show(show); w.progress:Show(show); w.hit:Show(show)
            if show then
                local density = tostring(self.eventDensity or "full")
                w.name:SetText(EventDisplayName(row, density))
                w.value:SetText(CompactRowStatus(row.status, density))
                local progressText = (row.questKey ~= nil and row.progressText ~= nil and row.progressText ~= "--") and tostring(row.progressText) or ""
                w.progress:SetText(progressText)
                S.Theme:SetLabelTone(w.name, row.active == true and "red" or nil)
                S.Theme:SetLabelTone(w.value, row.tone or "blue")
                S.Theme:SetLabelTone(w.progress, progressText ~= "" and (row.progressTone or "yellow") or "muted")
                -- Keep the row pickable for right-click hide even when it has no
                -- quest. Zone-state rows are protected by EventService:HideEvent.
                SetPick(w.hit, S.State.ui.widgets.event.clickThrough ~= true)
            else
                SetPick(w.hit, false)
            end
        end

        local first, second = events[1], events[2]
        local function MiniRow(row)
            if row == nil then return nil end
            local progress = (row.questKey ~= nil and row.progressText ~= nil and row.progressText ~= "--") and (" " .. tostring(row.progressText)) or ""
            return tostring(row.shortName or row.name or "") .. " " .. tostring(row.status or "--") .. progress
        end
        mini:SetText((MiniRow(first) or "暂无活动") .. (second and (" | " .. MiniRow(second)) or ""))
    end

    widget.OnLayout = function(self, width, height, titleHeight, mode)
        local scale = S.Layout:GetContext().addonScale
        local standard = mode == "standard"
        local miniMode = mode == "mini"
        self.refs.titleBar:Show(true)
        mini:Show(miniMode)

        if miniMode then
            mini:SetExtent(width - 16 * scale, math.max(18 * scale, height - titleHeight - 8 * scale))
            S.UI:SetAnchor(mini, win, 8 * scale, titleHeight + 3 * scale)
        end

        if standard then
            local fontAdjust = Clamp(tonumber(S.State.settings.eventFontAdjust) or 0, -2, 4)
            local hudFont = type(self.GetFontScale) == "function" and self:GetFontScale() or 1.0
            -- Architecture v1.1: typography is independent from window width.
            -- Narrow windows change column strategy/short titles, not font size.
            local titleFont = Clamp(10 * hudFont, 7, 24)
            local controlFont = Clamp(9 * hudFont, 7, 22)
            local opacityFont = Clamp(8 * hudFont, 7, 20)
            local rowFont = Clamp((10 + fontAdjust) * hudFont, 7, 28)

            if self.refs.titleLabel ~= nil and self.refs.titleLabel.style ~= nil then self.refs.titleLabel.style:SetFontSize(titleFont) end
            if self.refs.lockButton.style ~= nil then self.refs.lockButton.style:SetFontSize(controlFont) end
            if self.refs.fontMinusButton and self.refs.fontMinusButton.style ~= nil then self.refs.fontMinusButton.style:SetFontSize(controlFont) end
            if self.refs.fontPlusButton and self.refs.fontPlusButton.style ~= nil then self.refs.fontPlusButton.style:SetFontSize(controlFont) end
            if self.refs.modeButton.style ~= nil then self.refs.modeButton.style:SetFontSize(controlFont) end
            if self.refs.opacityButton.style ~= nil then self.refs.opacityButton.style:SetFontSize(opacityFont) end

            if mini.style ~= nil then mini.style:SetFontSize(rowFont) end
            for _, row in ipairs(rows) do
                if row.name.style ~= nil then row.name.style:SetFontSize(rowFont) end
                if row.value.style ~= nil then row.value.style:SetFontSize(rowFont) end
                if row.progress.style ~= nil then row.progress.style:SetFontSize(rowFont) end
            end

            -- No separate top zone strip anymore: content starts directly under
            -- the title bar, giving the list roughly two extra visible rows.
            local listTop = titleHeight + 3
            local bottomPad = 6
            local rowH = math.max(math.floor(ResponsiveValue(width, 115, 420, 18, 22) + 0.5), math.floor(rowFont + 4))
            local fit = math.floor((height - listTop - bottomPad) / math.max(1, rowH))
            self.visibleRows = math.max(1, math.min(MAX_ROWS, fit))

            local density = "full"
            if width < 185 then density = "ultra"
            elseif width < 285 then density = "compact" end

            -- Hard three-column table:
            --   | activity name | semantic state + time/phase | quest progress |
            -- The time column is centred on the widget rather than drifting
            -- toward either edge.  Progress owns a protected right-hand column;
            -- only the activity-name column is allowed to shrink/ellipsis.
            local leftPad = density == "ultra" and 1 or (density == "compact" and 2 or 4)
            local rightPad = density == "ultra" and 1 or (density == "compact" and 2 or 4)
            local gap = density == "ultra" and 1 or (density == "compact" and 2 or 3)
            local progressW = density == "ultra" and 24 or (density == "compact" and 28 or 32)
            local desiredTimeW = density == "ultra" and 78 or (density == "compact" and 108 or 132)
            local minNameW = density == "ultra" and 28 or 34

            local nameX = leftPad
            -- Progress owns the protected right edge. The middle column receives
            -- enough width for the controlled Chinese timer strings first; only
            -- then is the remaining left area assigned to the activity name.
            local progressX = math.max(nameX + 1, width - rightPad - progressW)
            local availableBeforeProgress = math.max(1, progressX - nameX - gap)
            local maxTimeW = math.max(36, availableBeforeProgress - minNameW - gap)
            local timeW = math.min(desiredTimeW, maxTimeW)

            -- Keep the timer visually centered in the whole row when possible,
            -- but never let that centering create a fake narrow timer column.
            -- If centering would reduce the timer's usable width, keep the full
            -- time width and let the name column absorb the pressure instead.
            local centeredValueX = math.floor((width - timeW) / 2)
            local maxValueX = progressX - gap - timeW
            local preferredNameW = math.max(minNameW, math.floor((availableBeforeProgress - timeW - gap) * 0.72))
            local preferredValueX = nameX + preferredNameW + gap
            local valueX = math.min(maxValueX, math.max(nameX + minNameW + gap, math.min(centeredValueX, preferredValueX)))
            local nameW = math.max(8, valueX - nameX - gap)
            self.eventDensity = density

            for i, row in ipairs(rows) do
                local y = listTop + (i - 1) * rowH
                local showByFit = i <= self.visibleRows
                row.name:SetExtent(nameW, rowH)
                row.value:SetExtent(timeW, rowH)
                row.progress:SetExtent(progressW, rowH)
                row.hit:SetExtent(width - 6, rowH)
                S.UI:SetAnchor(row.name, win, nameX, y)
                S.UI:SetAnchor(row.value, win, valueX, y)
                S.UI:SetAnchor(row.progress, win, progressX, y)
                S.UI:SetAnchor(row.hit, win, 3, y)
                if not showByFit then
                    row.name:Show(false); row.value:Show(false); row.progress:Show(false); row.hit:Show(false)
                end
            end
        else
            for _, w in ipairs(rows) do w.name:Show(false); w.value:Show(false); w.progress:Show(false); w.hit:Show(false) end
        end
        self:Refresh()
    end

    widget:ApplyLayout(false)
    return widget
end

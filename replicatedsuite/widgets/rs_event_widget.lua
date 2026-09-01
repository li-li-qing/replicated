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
    return S.UI:SetEllipsis(label, enabled, "hud:event")
end

local function SetPick(widget, enabled)
    return S.UI:SetPickable(widget, enabled, "hud:event")
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

local function EventCountdownToken(seconds)
    local value = math.max(0, math.floor(tonumber(seconds) or 0))
    if value < 60 then return tostring(value) .. "秒" end
    local minutes = math.floor(value / 60)
    if minutes < 60 then return tostring(minutes) .. "分" end
    local hours = math.floor(minutes / 60)
    minutes = minutes % 60
    if hours < 24 then return tostring(hours) .. "时" .. (minutes > 0 and (tostring(minutes) .. "分") or "") end
    local days = math.floor(hours / 24)
    hours = hours % 24
    return tostring(days) .. "天" .. (hours > 0 and (tostring(hours) .. "时") or "")
end

local function RemainingClock(seconds)
    local value = tonumber(seconds)
    if value == nil then return "--" end
    value = math.max(0, math.floor(value))
    local hours = math.floor(value / 3600)
    local minutes = math.floor((value % 3600) / 60)
    local secs = value % 60
    if hours > 0 then return string.format("%02d:%02d:%02d", hours, minutes, secs) end
    return string.format("%02d:%02d", minutes, secs)
end

local function PhaseOnly(row, density)
    if type(row) ~= "table" then return "--" end
    local status = tostring(row.status or "--")
    local seconds = tonumber(row.seconds)
    if seconds == nil then return CompactRowStatus(status, density) end
    local token = EventCountdownToken(seconds)
    if status == token and row.active ~= true then return "即将开始" end
    if status == "进行中 " .. token then return "进行中" end
    if #token > 0 and #status > #token and string.sub(status, -#token) == token then
        local prefix = string.gsub(string.sub(status, 1, #status - #token), "%s+$", "")
        if prefix ~= "" then return CompactRowStatus(prefix, density) end
    end
    return CompactRowStatus(status, density)
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

    -- M3 HUD table header. The wide layout uses four independent semantic
    -- columns (name / phase / remaining / progress); narrow layouts collapse
    -- phase+time into one field rather than shrinking the font.
    local headerName = S.UI:CreateLabel(win, "event_widget_header_name", "活动", 0, 0, 80, 18, 8, "muted", ALIGN_LEFT)
    local headerPhase = S.UI:CreateLabel(win, "event_widget_header_phase", "状态/阶段", 0, 0, 80, 18, 8, "muted", ALIGN_CENTER)
    local headerRemain = S.UI:CreateLabel(win, "event_widget_header_remain", "剩余", 0, 0, 60, 18, 8, "muted", ALIGN_CENTER)
    local headerProgress = S.UI:CreateLabel(win, "event_widget_header_progress", "进度", 0, 0, 36, 18, 8, "muted", ALIGN_RIGHT)

    local rows = {}
    for i = 1, MAX_ROWS do
        local idx = i
        local name = S.UI:CreateLabel(win, "event_widget_name_" .. i, "", 0, 0, 180, 18, 10, nil, ALIGN_LEFT)
        local value = S.UI:CreateLabel(win, "event_widget_value_" .. i, "", 0, 0, 100, 18, 10, "blue", ALIGN_CENTER)
        local remaining = S.UI:CreateLabel(win, "event_widget_remaining_" .. i, "", 0, 0, 64, 18, 10, "blue", ALIGN_CENTER)
        local progress = S.UI:CreateLabel(win, "event_widget_progress_" .. i, "", 0, 0, 28, 18, 10, "yellow", ALIGN_RIGHT)
        SetEllipsis(name, false); SetEllipsis(value, false); SetEllipsis(remaining, false); SetEllipsis(progress, false)

        local hit = UIParent:CreateWidget("emptywidget", S.PhysicalId("event_widget_hit_" .. i), win)
        hit.rsUiOwner = win.rsUiOwner
        if type(S.UI.AdoptWidget) == "function" then S.UI:AdoptWidget(hit, hit.rsUiOwner, "event_widget_hit_" .. i) end
        S.UI:SetExtent(hit, 280, 18, "hud:event")
        S.UI:SetEnabled(hit, true, "hud:event")
        SetPick(hit, true)
        S.UI:SetVisible(hit, false, "hud:event")
        rows[i] = { name = name, value = value, remaining = remaining, progress = progress, hit = hit, data = nil }
        S.UI:SetVisible(name, false, "hud:event"); S.UI:SetVisible(value, false, "hud:event"); S.UI:SetVisible(remaining, false, "hud:event"); S.UI:SetVisible(progress, false, "hud:event")

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
    S.UI:SetVisible(mini, false, "hud:event")

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
            if liveHandlerInstalled and type(S.UI.RegisterHandlerBinding) == "function" then S.UI:RegisterHandlerBinding(win, "OnUpdate") end
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
            S.UI:SetVisible(w.name, show, "hud:event"); S.UI:SetVisible(w.value, show, "hud:event"); S.UI:SetVisible(w.remaining, show and self.eventShowRemaining == true, "hud:event"); S.UI:SetVisible(w.progress, show, "hud:event"); S.UI:SetVisible(w.hit, show, "hud:event")
            if show then
                local density = tostring(self.eventDensity or "full")
                S.UI:SetText(w.name, EventDisplayName(row, density), "hud:event")
                S.UI:SetText(w.value, self.eventShowRemaining == true and PhaseOnly(row, density) or CompactRowStatus(row.status, density), "hud:event")
                S.UI:SetText(w.remaining, RemainingClock(row.seconds), "hud:event")
                local progressText = (row.questKey ~= nil and row.progressText ~= nil and row.progressText ~= "--") and tostring(row.progressText) or ""
                S.UI:SetText(w.progress, progressText, "hud:event")
                S.UI:SetLabelTone(w.name, row.active == true and "red" or nil, "hud:event")
                S.UI:SetLabelTone(w.value, row.tone or "blue", "hud:event")
                S.UI:SetLabelTone(w.remaining, row.tone or "blue", "hud:event")
                S.UI:SetLabelTone(w.progress, progressText ~= "" and (row.progressTone or "yellow") or "muted", "hud:event")
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
        S.UI:SetText(mini, (MiniRow(first) or "暂无活动") .. (second and (" | " .. MiniRow(second)) or ""), "hud:event")
    end

    widget.OnLayout = function(self, width, height, titleHeight, mode)
        local scale = S.Layout:GetContext().addonScale
        local standard = mode == "standard"
        local miniMode = mode == "mini"
        S.UI:SetVisible(self.refs.titleBar, true, "hud:event")
        S.UI:SetVisible(mini, miniMode, "hud:event")

        if miniMode then
            S.UI:SetExtent(mini, width - 16 * scale, math.max(18 * scale, height - titleHeight - 8 * scale), "hud:event")
            S.UI:SetAnchor(mini, win, 8 * scale, titleHeight + 3 * scale, "hud:event")
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

            S.UI:SetFontSize(self.refs.titleLabel, titleFont, "hud:event")
            S.UI:SetFontSize(self.refs.lockButton, controlFont, "hud:event")
            S.UI:SetFontSize(self.refs.fontMinusButton, controlFont, "hud:event")
            S.UI:SetFontSize(self.refs.fontPlusButton, controlFont, "hud:event")
            S.UI:SetFontSize(self.refs.modeButton, controlFont, "hud:event")
            S.UI:SetFontSize(self.refs.opacityButton, opacityFont, "hud:event")

            S.UI:SetFontSize(mini, rowFont, "hud:event")
            for _, header in ipairs({headerName, headerPhase, headerRemain, headerProgress}) do S.UI:SetFontSize(header, math.max(7, rowFont - 2), "hud:event") end
            for _, row in ipairs(rows) do
                S.UI:SetFontSize(row.name, rowFont, "hud:event")
                S.UI:SetFontSize(row.value, rowFont, "hud:event")
                S.UI:SetFontSize(row.remaining, rowFont, "hud:event")
                S.UI:SetFontSize(row.progress, rowFont, "hud:event")
            end

            local headerH = math.max(16, math.floor(rowFont + 3))
            local headerTop = titleHeight + 2
            local listTop = headerTop + headerH + 1
            local bottomPad = 6
            local rowH = math.max(math.floor(ResponsiveValue(width, 115, 420, 18, 22) + 0.5), math.floor(rowFont + 4))
            local fit = math.floor((height - listTop - bottomPad) / math.max(1, rowH))
            self.visibleRows = math.max(1, math.min(MAX_ROWS, fit))

            local density = "full"
            if width < 185 then density = "ultra"
            elseif width < 285 then density = "compact" end

            local leftPad = density == "ultra" and 1 or (density == "compact" and 2 or 4)
            local rightPad = density == "ultra" and 1 or (density == "compact" and 2 or 4)
            local gap = density == "ultra" and 1 or (density == "compact" and 2 or 3)
            local progressW = density == "ultra" and 24 or (density == "compact" and 28 or 34)
            local showRemaining = width >= 230
            local remainW = showRemaining and (density == "compact" and 58 or 66) or 0
            local phaseW = showRemaining and (density == "compact" and 72 or 92) or (density == "ultra" and 82 or 112)
            local minNameW = density == "ultra" and 28 or 40

            local nameX = leftPad
            local progressX = math.max(nameX + 1, width - rightPad - progressW)
            local remainX = progressX - (showRemaining and (gap + remainW) or 0)
            local phaseX = remainX - gap - phaseW
            if not showRemaining then phaseX = progressX - gap - phaseW end
            phaseX = math.max(nameX + minNameW + gap, phaseX)
            local nameW = math.max(8, phaseX - nameX - gap)
            phaseW = math.max(36, (showRemaining and remainX or progressX) - gap - phaseX)
            self.eventDensity = density
            self.eventShowRemaining = showRemaining

            S.UI:SetVisible(headerName, true, "hud:event"); S.UI:SetVisible(headerPhase, true, "hud:event"); S.UI:SetVisible(headerRemain, showRemaining, "hud:event"); S.UI:SetVisible(headerProgress, true, "hud:event")
            S.UI:SetText(headerPhase, showRemaining and "状态/阶段" or "状态 / 剩余", "hud:event")
            S.UI:SetExtent(headerName, nameW, headerH, "hud:event"); S.UI:SetExtent(headerPhase, phaseW, headerH, "hud:event"); S.UI:SetExtent(headerRemain, remainW, headerH, "hud:event"); S.UI:SetExtent(headerProgress, progressW, headerH, "hud:event")
            S.UI:SetAnchor(headerName, win, nameX, headerTop, "hud:event"); S.UI:SetAnchor(headerPhase, win, phaseX, headerTop, "hud:event"); S.UI:SetAnchor(headerRemain, win, remainX, headerTop, "hud:event"); S.UI:SetAnchor(headerProgress, win, progressX, headerTop, "hud:event")

            for i, row in ipairs(rows) do
                local y = listTop + (i - 1) * rowH
                local showByFit = i <= self.visibleRows
                S.UI:SetExtent(row.name, nameW, rowH, "hud:event")
                S.UI:SetExtent(row.value, phaseW, rowH, "hud:event")
                S.UI:SetExtent(row.remaining, remainW, rowH, "hud:event")
                S.UI:SetExtent(row.progress, progressW, rowH, "hud:event")
                S.UI:SetExtent(row.hit, width - 6, rowH, "hud:event")
                S.UI:SetAnchor(row.name, win, nameX, y, "hud:event")
                S.UI:SetAnchor(row.value, win, phaseX, y, "hud:event")
                S.UI:SetAnchor(row.remaining, win, remainX, y, "hud:event")
                S.UI:SetAnchor(row.progress, win, progressX, y, "hud:event")
                S.UI:SetAnchor(row.hit, win, 3, y, "hud:event")
                if not showByFit then
                    S.UI:SetVisible(row.name, false, "hud:event"); S.UI:SetVisible(row.value, false, "hud:event"); S.UI:SetVisible(row.remaining, false, "hud:event"); S.UI:SetVisible(row.progress, false, "hud:event"); S.UI:SetVisible(row.hit, false, "hud:event")
                end
            end
        else
            S.UI:SetVisible(headerName, false, "hud:event"); S.UI:SetVisible(headerPhase, false, "hud:event"); S.UI:SetVisible(headerRemain, false, "hud:event"); S.UI:SetVisible(headerProgress, false, "hud:event")
            for _, w in ipairs(rows) do
                S.UI:SetVisible(w.name, false, "hud:event"); S.UI:SetVisible(w.value, false, "hud:event"); S.UI:SetVisible(w.remaining, false, "hud:event"); S.UI:SetVisible(w.progress, false, "hud:event"); S.UI:SetVisible(w.hit, false, "hud:event")
            end
        end
        self:Refresh()
    end

    widget:ApplyLayout(false)
    return widget
end

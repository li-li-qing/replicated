------------------------------------------------------------------------
-- Replicated Suite - Task floating widget
-- Author: Replicated
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.TaskWidget = {}

function S.TaskWidget.Create()
    local widget = S.WidgetBase:Create("task", "任务追踪", S.Constants.Widget.task)
    local win = widget.window
    widget.scope = "daily"
    widget.onlyIncomplete = S.State.settings.onlyIncompleteTasks == true
    widget.scrollOffset = 0
    widget.visibleRows = 1
    widget.filteredData = {}

    local dailyBtn = S.UI:CreateButton(win, "task_widget_daily", "日常", 10, 35, 62, 24, 9, true)
    local weeklyBtn = S.UI:CreateButton(win, "task_widget_weekly", "周常", 76, 35, 62, 24, 9, false)
    local incompleteBtn = S.UI:CreateButton(win, "task_widget_incomplete", "仅未完成", 142, 35, 92, 24, 9, false)
    local customBtn = S.UI:CreateButton(win, "task_widget_custom", "自定义", 238, 35, 70, 24, 9, false)
    local up = S.UI:CreateButton(win, "task_widget_scroll_up", "^", 0, 0, 20, 20, 8, false)
    local down = S.UI:CreateButton(win, "task_widget_scroll_down", "v", 0, 0, 20, 20, 8, false)
    local rows = {}
    for i = 1, 14 do
        local button = S.UI:CreateButton(win, "task_widget_name_" .. i, "", 12, 0, 250, 23, 10, false)
        if button.style and button.style.SetAlign then pcall(function() button.style:SetAlign(ALIGN_LEFT) end) end
        local value = S.UI:CreateLabel(win, "task_widget_value_" .. i, "", 0, 0, 105, 23, 10, "muted", ALIGN_RIGHT)
        button:Show(false); value:Show(false)
        rows[i] = { name = button, value = value, data = nil }
        local rowWidget = rows[i]
        S.UI:SafeHandler(button, "OnClick", function()
            local r = rowWidget.data
            if r and r.placeholder == true then
                if S.DailyCustomWindow and type(S.DailyCustomWindow.Open)=="function" then S.DailyCustomWindow:Open() end
            elseif r and S.Services and S.Services.Quest then
                S.Services.Quest:OpenGroupDetail(r.scope, r.key)
            end
        end, "task:row:" .. i)
    end
    local mini = S.UI:CreateLabel(win, "task_widget_mini", "任务 --", 8, 4, 270, 22, 10, "yellow", ALIGN_LEFT)
    mini:Show(false)

    local function RefreshButtons()
        dailyBtn:SetText(widget.scope == "daily" and "[日常]" or "日常")
        weeklyBtn:SetText(widget.scope == "weekly" and "[周常]" or "周常")
        incompleteBtn:SetText(widget.onlyIncomplete and "[仅未完成]" or "仅未完成")
    end

    function widget:GetMaxOffset()
        return math.max(0, #(self.filteredData or {}) - math.max(1, self.visibleRows or 1))
    end
    function widget:Scroll(delta)
        self.scrollOffset = math.max(0, math.min(self:GetMaxOffset(), (self.scrollOffset or 0) + (tonumber(delta) or 0)))
        self:Refresh()
    end

    S.UI:SafeHandler(dailyBtn, "OnClick", function() widget.scope = "daily"; widget.scrollOffset = 0; widget:Refresh() end, "task:daily")
    S.UI:SafeHandler(weeklyBtn, "OnClick", function() widget.scope = "weekly"; widget.scrollOffset = 0; widget:Refresh() end, "task:weekly")
    S.UI:SafeHandler(incompleteBtn, "OnClick", function()
        widget.onlyIncomplete = not widget.onlyIncomplete
        widget.scrollOffset = 0
        S.State.settings.onlyIncompleteTasks = widget.onlyIncomplete
        S.State:MarkDirty("quests"); S.Storage:RequestSave(); widget:Refresh()
    end, "task:incomplete")
    S.UI:SafeHandler(customBtn, "OnClick", function()
        if S.DailyCustomWindow and type(S.DailyCustomWindow.Open)=="function" then S.DailyCustomWindow:Open() end
    end, "task:custom")
    S.UI:SafeHandler(up, "OnClick", function() widget:Scroll(-1) end, "task:up")
    S.UI:SafeHandler(down, "OnClick", function() widget:Scroll(1) end, "task:down")
    if win.EnableScroll ~= nil then pcall(function() win:EnableScroll(true) end) end
    S.UI:SafeHandler(win, "OnWheelUp", function() widget:Scroll(-1) end, "task:wheel_up")
    S.UI:SafeHandler(win, "OnWheelDown", function() widget:Scroll(1) end, "task:wheel_down")

    function widget:Refresh()
        widget.onlyIncomplete = S.State.settings.onlyIncompleteTasks == true
        local source = widget.scope == "weekly" and (S.State.data.weekly or {}) or (S.State.data.daily or {})
        local data = {}
        local questService = S.Services and S.Services.Quest
        for _, r in ipairs(source) do
            local tracked = widget.scope ~= "daily" or questService == nil or questService:IsDailyTracked(r.key)
            local completed = r.state == S.Constants.QuestStatus.COMPLETED
            local include = tracked and ((not widget.onlyIncomplete) or (not completed))
            if include and (S.State.settings.showCompletedTasks or not completed) then data[#data + 1] = r end
        end
        if widget.scope == "daily" and questService ~= nil then
            local selected = questService:GetDailyTrackingStats()
            if selected == 0 then
                data = { { placeholder=true, name="尚未选择追踪日常", status="点“自定义”选择", tone="yellow", scope="daily" } }
            end
        end
        self.filteredData = data
        self.scrollOffset = math.max(0, math.min(self.scrollOffset or 0, self:GetMaxOffset()))
        local needScroll = #data > (self.visibleRows or 1)
        local scrollVisible=needScroll and S.State.ui.widgets.task.mode == "standard"
        up:Show(scrollVisible)
        down:Show(scrollVisible)
        if up.Enable then up:Enable(scrollVisible and self.scrollOffset>0) end
        if down.Enable then down:Enable(scrollVisible and self.scrollOffset<self:GetMaxOffset()) end
        for i, w in ipairs(rows) do
            local r = data[self.scrollOffset + i]
            local show = r ~= nil and S.State.ui.widgets.task.mode == "standard" and i <= (self.visibleRows or #rows)
            w.data = r; w.name:Show(show); w.value:Show(show)
            if show then
                w.name:SetText(tostring(r.name or "") .. "  >")
                w.value:SetText(tostring(r.status or "--")); S.Theme:SetLabelTone(w.value, r.tone)
            end
        end
        local s = S.State.data.summary
        mini:SetText("任务 " .. tostring(s.unfinished or 0) .. " 未完成")
        RefreshButtons()
    end

    widget.OnLayout = function(self, width, height, titleHeight, mode)
        local scale = S.Layout:GetContext().addonScale
        local standard = mode == "standard"
        local miniMode = mode == "mini"
        self.refs.titleBar:Show(true)
        dailyBtn:Show(standard); weeklyBtn:Show(standard); incompleteBtn:Show(standard); customBtn:Show(standard); mini:Show(miniMode)
        if not standard then up:Show(false); down:Show(false) end
        if miniMode then mini:SetExtent(width - 16 * scale, math.max(18 * scale, height - titleHeight - 8 * scale)); S.UI:SetAnchor(mini, win, 8 * scale, titleHeight + 3 * scale) end
        if standard then
            local gap=4*scale
            local dailyW,weeklyW,incompleteW=58*scale,58*scale,88*scale
            local customW=math.max(58*scale,width-20*scale-gap*3-dailyW-weeklyW-incompleteW)
            local x=10*scale
            dailyBtn:SetExtent(dailyW,24*scale); S.UI:SetAnchor(dailyBtn,win,x,titleHeight+5*scale); x=x+dailyW+gap
            weeklyBtn:SetExtent(weeklyW,24*scale); S.UI:SetAnchor(weeklyBtn,win,x,titleHeight+5*scale); x=x+weeklyW+gap
            incompleteBtn:SetExtent(incompleteW,24*scale); S.UI:SetAnchor(incompleteBtn,win,x,titleHeight+5*scale); x=x+incompleteW+gap
            customBtn:SetExtent(customW,24*scale); S.UI:SetAnchor(customBtn,win,x,titleHeight+5*scale)
            local rowStart = titleHeight + 36 * scale
            local rowH = 26 * scale
            self.visibleRows = math.max(1, math.min(#rows, math.floor((height - rowStart - 8 * scale) / rowH)))
            local needScroll = #(self.filteredData or {}) > self.visibleRows
            local scrollRail = needScroll and 26 * scale or 6 * scale
            local contentRight = width - scrollRail - 8 * scale
            local statusW = math.min(118 * scale, math.max(88 * scale, contentRight * 0.34))
            local statusX = contentRight - statusW
            for i, w in ipairs(rows) do
                local y = rowStart + (i - 1) * rowH
                w.name:SetExtent(math.max(90 * scale, statusX - 17 * scale), 23 * scale)
                w.value:SetExtent(statusW, 23 * scale)
                S.UI:SetAnchor(w.name, win, 12 * scale, y)
                S.UI:SetAnchor(w.value, win, statusX, y)
            end
            up:SetExtent(20 * scale, 20 * scale); down:SetExtent(20 * scale, 20 * scale)
            S.UI:SetAnchor(up, win, width - 23 * scale, rowStart)
            S.UI:SetAnchor(down, win, width - 23 * scale, math.max(rowStart, height - 23 * scale))
        end
        self:Refresh()
    end

    widget:ApplyLayout(false)
    return widget
end

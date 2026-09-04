------------------------------------------------------------------------
-- Replicated Suite V3 - Task Tracker Page
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI, D = S.RSUI, S.UIV3Design
local PageHost = S.UIV3 and S.UIV3.PageHost or nil
local Feature = S.Features and S.Features.Tasks or nil
if type(RSUI) ~= "table" or type(D) ~= "table" or type(PageHost) ~= "table" or type(Feature) ~= "table" then return end

local ROUTE = "life.tasks"

local function OpenDetail(row)
    if type(row) ~= "table" then return false end
    local modal = S.UIV3 and S.UIV3.QuestDetailModalV3 or nil
    if type(modal) ~= "table" or type(modal.Open) ~= "function" then return false end
    return modal:Open(row.scope or "daily", row.groupKey or row.key, row)
end

local function BuildTaskPage(parent, route)
    local root, rootErr = D:PageRoot(parent, "v3_page_tasks")
    if root == nil then return nil, "页面根组件创建失败：" .. tostring(rootErr or "未知错误") end
    D:PageHeader(root, "v3_tasks_header", "任务追踪",
        "日常 / 周常共享同一份只读任务进度；这里只保存你想追踪哪些任务。点击任务行展开子任务，悬浮窗只显示已追踪项目。",
        "刷新", function()
            local progress = S.Services and S.Services.QuestProgressV3 or nil
            if type(progress) == "table" and type(progress.Refresh) == "function" then progress:Refresh("task_page_manual", false) end
            return Feature.Commands:RefreshProjection("page_manual")
        end)

    local summaryCard = D:InfoCard(root, {
        id = "v3_tasks_summary", title = "追踪概览", value = "--", detail = "--",
        slot = { size = "fixed", height = 84, hAlign = "fill" },
    })

    local currentScope = Feature:GetLastScope()
    if currentScope ~= "weekly" then currentScope = "daily" end
    local trackedOnly = false
    local selectedId = nil
    local tableView = nil

    local row1 = RSUI:HorizontalBox({ id = "v3_tasks_actions_scope", parent = root, gap = 7, slot = { size = "fixed", height = 30, hAlign = "fill" } })
    local dailyButton = RSUI:Button({ id = "v3_tasks_daily", parent = row1, text = "日常", compact = true, slot = { size = "fixed", width = 76 } })
    local weeklyButton = RSUI:Button({ id = "v3_tasks_weekly", parent = row1, text = "周常", compact = true, slot = { size = "fixed", width = 76 } })
    local trackedOnlyButton = RSUI:Button({ id = "v3_tasks_tracked_only", parent = row1, text = "仅追踪：关", compact = true, slot = { size = "fixed", width = 108 } })
    local featureButton = RSUI:Button({ id = "v3_tasks_feature_toggle", parent = row1, text = "关闭功能", compact = true, slot = { size = "fixed", width = 96 } })
    local widgetButton = RSUI:Button({ id = "v3_tasks_widget_toggle", parent = row1, text = "打开悬浮窗", compact = true, slot = { size = "fixed", width = 116 } })

    local row2 = RSUI:HorizontalBox({ id = "v3_tasks_actions_tracking", parent = root, gap = 7, slot = { size = "fixed", height = 30, hAlign = "fill" } })
    local toggleTrackButton = RSUI:Button({ id = "v3_tasks_toggle_track", parent = row2, text = "追踪 / 取消", compact = true, enabled = false, slot = { size = "fixed", width = 112 } })
    local expandButton = RSUI:Button({ id = "v3_tasks_expand", parent = row2, text = "展开 / 收起", compact = true, enabled = false, slot = { size = "fixed", width = 112 } })
    local allButton = RSUI:Button({ id = "v3_tasks_track_all", parent = row2, text = "全部追踪", compact = true, slot = { size = "fixed", width = 96 } })
    local noneButton = RSUI:Button({ id = "v3_tasks_track_none", parent = row2, text = "全部取消", compact = true, slot = { size = "fixed", width = 96 } })
    local hint = RSUI:Text({ id = "v3_tasks_hint", parent = root, text = "--", fontSize = 9, tone = "muted", overflow = "ellipsis", slot = { size = "fixed", height = 20, hAlign = "fill" } })

    local function SelectedParent()
        local row = selectedId and Feature:GetRow(selectedId) or nil
        return type(row) == "table" and row.parent == true and row or nil
    end

    local function FilterRows(rows)
        if trackedOnly ~= true then return rows end
        local result = {}
        for _, row in ipairs(type(rows) == "table" and rows or {}) do
            if row.tracked == true then result[#result + 1] = row end
        end
        return result
    end

    tableView = RSUI:TableView({
        id = "v3_tasks_table", parent = root, items = {},
        rowHeight = 29, headerHeight = 29, desiredRows = 12, overscan = 2,
        scrollbar = true, selectable = true, selectionMode = "single", columnResize = true, headerInteractive = false,
        getKey = function(item) return item and item.id or nil end,
        onItemActivated = function(item)
            if type(item) ~= "table" then return false end
            if item.parent == true then return Feature.Commands:ToggleExpanded(item.scope, item.groupKey) end
            return OpenDetail(item)
        end,
        onSelectionChanged = function(_, _, view)
            selectedId = view and type(view.GetSelectedKey) == "function" and view:GetSelectedKey() or nil
            local row = SelectedParent()
            toggleTrackButton:SetEnabled(row ~= nil)
            expandButton:SetEnabled(row ~= nil and tonumber(row.objectiveCount) > 0)
            if row ~= nil then toggleTrackButton:SetText(row.tracked and "取消追踪" or "加入追踪") else toggleTrackButton:SetText("追踪 / 取消") end
        end,
        columns = {
            { id = "tracked", title = "追踪", field = "trackedText", size = "fill", minWidth = 42, absoluteMinWidth = 28, fill = 0.5,
                getTone = function(item) return item and item.tracked and "green" or "muted" end },
            { id = "cycle", title = "周期", field = "cycleText", size = "fill", minWidth = 46, absoluteMinWidth = 32, fill = 0.6, tone = "muted" },
            { id = "name", title = "任务", field = "name", size = "fill", minWidth = 210, absoluteMinWidth = 100, fill = 1.6,
                getTone = function(item) return item and item.child and (item.related and "accent" or "default") or "default" end },
            { id = "progress", title = "进度", field = "progressText", size = "fill", minWidth = 56, absoluteMinWidth = 36, fill = 0.8,
                getTone = function(item) return item and item.tone or "muted" end },
            { id = "status", title = "状态", field = "status", size = "fill", minWidth = 62, absoluteMinWidth = 42, fill = 0.9,
                getTone = function(item) return item and item.tone or "muted" end },
        },
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })

    local function SetScope(scope)
        scope = tostring(scope or "daily") == "weekly" and "weekly" or "daily"
        if currentScope ~= scope then
            currentScope = scope
            selectedId = nil
            Feature.Commands:SetLastScope(scope)
            local model = tableView and tableView:GetSelectionModel() or nil
            if model ~= nil and type(model.Clear) == "function" then model:Clear("scope_changed") end
        end
        root:Refresh()
        return true
    end

    dailyButton.onClick = function() return SetScope("daily") end
    weeklyButton.onClick = function() return SetScope("weekly") end
    trackedOnlyButton.onClick = function() trackedOnly = not trackedOnly; root:Refresh(); return true end
    toggleTrackButton.onClick = function()
        local row = SelectedParent()
        if row == nil then return false end
        return Feature.Commands:ToggleTracked(row.scope, row.groupKey, "task_page")
    end
    expandButton.onClick = function()
        local row = SelectedParent()
        if row == nil then return false end
        return Feature.Commands:ToggleExpanded(row.scope, row.groupKey)
    end
    allButton.onClick = function() return Feature.Commands:SetAllTracked(currentScope, true, "task_page_all") end
    noneButton.onClick = function() return Feature.Commands:SetAllTracked(currentScope, false, "task_page_none") end
    featureButton.onClick = function()
        if S.FeatureRuntime == nil then return false, "FeatureRuntime 不可用" end
        local enabled = S.FeatureRuntime:IsEnabled("life_tasks") == true
        local target = not enabled
        local ok, err = S.FeatureRuntime:SetPreferredEnabled("life_tasks", target, "task_page")
        if ok ~= true then return false, err end
        if target then
            local acquired, acquireErr = Feature:AcquireConsumer("page:tasks")
            if acquired ~= true then
                local rolledBack, rollbackErr = S.FeatureRuntime:SetPreferredEnabled("life_tasks", false, "task_page_consumer_rollback")
                root:Refresh()
                if rolledBack ~= true then
                    return false, tostring(acquireErr or "任务页面 Consumer 启动失败") .. "；回滚失败：" .. tostring(rollbackErr or "unknown")
                end
                return false, acquireErr or "任务页面 Consumer 启动失败"
            end
            if S.Events ~= nil and type(S.Events.SubscribeInternal) == "function" then
                S.Events:UnsubscribeInternalOwner(root)
                S.Events:SubscribeInternal("v3.tasks.updated", root, function() root:Refresh() end)
            end
        else
            -- FeatureRuntime:Disable already clears the feature Demand transactionally.
            -- Avoid issuing a second Release against a token that no longer exists.
            if S.Events ~= nil and type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(root) end
        end
        root:Refresh()
        return true
    end
    widgetButton.onClick = function()
        local visible = S.UIV3.WidgetHost and S.UIV3.WidgetHost:IsVisible("life.tasks") == true
        return Feature.Commands:SetWidgetVisible(not visible, "task_page")
    end

    for _, binding in ipairs({
        { dailyButton, "daily" }, { weeklyButton, "weekly" }, { trackedOnlyButton, "tracked_only" },
        { toggleTrackButton, "toggle_track" }, { expandButton, "expand" }, { allButton, "all" },
        { noneButton, "none" }, { featureButton, "feature" }, { widgetButton, "widget" },
    }) do
        local button, name = binding[1], binding[2]
        local execute = button.onClick
        button.onClick = function()
            if S.ActionRunner ~= nil and (name == "toggle_track" or name == "all" or name == "none" or name == "feature" or name == "widget") then
                return S.ActionRunner:Run({ id = "tasks." .. name, button = button, idleText = button.spec and button.spec.text, busyText = "处理中…", notify = false, execute = execute })
            end
            return execute()
        end
    end

    function root:Refresh()
        local enabled = S.FeatureRuntime ~= nil and S.FeatureRuntime:IsEnabled("life_tasks") == true
        local rows, revision = Feature:GetRows(currentScope)
        rows = FilterRows(rows)
        tableView:SetItems(rows, "tasks:" .. currentScope .. ":" .. tostring(revision) .. ":" .. tostring(trackedOnly))
        if not enabled then
            tableView:SetViewState("unavailable", { title = "任务追踪已关闭", detail = "启用功能后才会读取日常 / 周常任务进度。" })
        elseif #rows == 0 then
            tableView:SetViewState("empty", { title = trackedOnly and "暂无已追踪任务" or "暂无任务", detail = trackedOnly and "关闭“仅追踪”可查看当前范围内的全部任务。" or "当前范围暂时没有可显示任务。" })
        else
            tableView:SetViewState("ready")
        end
        local summary = Feature:GetSummary(currentScope)
        summaryCard:SetData({
            value = enabled and (tostring(summary.tracked) .. "/" .. tostring(summary.total) .. " 已追踪") or "功能已关闭",
            detail = "未完成 " .. tostring(summary.unfinished) .. " · 可交付 " .. tostring(summary.ready)
                .. " · 已完成 " .. tostring(summary.completed) .. " · 暂不可用 " .. tostring(summary.unavailable)
                .. "\n点击父任务行展开子任务；点击子任务可打开完整详情。",
        })
        dailyButton:SetSelected(currentScope == "daily")
        weeklyButton:SetSelected(currentScope == "weekly")
        trackedOnlyButton:SetSelected(trackedOnly)
        trackedOnlyButton:SetText(trackedOnly and "仅追踪：开" or "仅追踪：关")
        featureButton:SetText(enabled and "关闭功能" or "启用功能")
        local widgetVisible = S.UIV3.WidgetHost and S.UIV3.WidgetHost:IsVisible("life.tasks") == true
        widgetButton:SetEnabled(enabled)
        widgetButton:SetText(widgetVisible and "关闭悬浮窗" or "打开悬浮窗")
        local selected = SelectedParent()
        toggleTrackButton:SetEnabled(enabled and selected ~= nil)
        expandButton:SetEnabled(enabled and selected ~= nil and tonumber(selected.objectiveCount) > 0)
        if selected ~= nil then toggleTrackButton:SetText(selected.tracked and "取消追踪" or "加入追踪") end
        local progress = S.Services and S.Services.QuestProgressV3 or nil
        local health = type(progress) == "table" and type(progress.GetHealth) == "function" and progress:GetHealth(currentScope) or nil
        if enabled and type(health) == "table" then
            hint:SetText((currentScope == "daily" and "日常" or "周常") .. "进度：可用 " .. tostring(health.available or 0) .. "/" .. tostring(health.projections or 0)
                .. " · 共享版本 " .. tostring(health.revision or 0) .. " · 鼠标滚轮可浏览全部任务")
        else
            hint:SetText(enabled and "任务进度数据暂不可用" or "任务追踪功能已关闭")
        end
        return true
    end

    function root:OnActivated()
        local enabled = S.FeatureRuntime ~= nil and S.FeatureRuntime:IsEnabled("life_tasks") == true
        if enabled then
            local ok = Feature:AcquireConsumer("page:tasks")
            if ok ~= true then return false end
            if S.Events ~= nil and type(S.Events.SubscribeInternal) == "function" then
                S.Events:UnsubscribeInternalOwner(self)
                S.Events:SubscribeInternal("v3.tasks.updated", self, function() root:Refresh() end)
            end
        end
        self:Refresh()
        return true
    end

    function root:OnDeactivated()
        if S.Events ~= nil and type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
        Feature:ReleaseConsumer("page:tasks")
        return true
    end

    function root:RefreshData(dirty)
        -- FeatureRuntime/QuestProgress owns gameplay refresh. PageHost only re-renders
        -- the latest projection here so opening/refocusing the page cannot double-scan
        -- QUEST state in the same refresh transaction.
        return self:Refresh()
    end

    root.route = route
    root.tableView = tableView
    return root
end

local ok, err = PageHost:RegisterFactory(ROUTE, BuildTaskPage)
if ok ~= true then error(err) end

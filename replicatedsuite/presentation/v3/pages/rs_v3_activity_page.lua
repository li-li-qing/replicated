------------------------------------------------------------------------
-- Replicated Suite V3 - Activity Page
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI, D = S.RSUI, S.UIV3Design
local PageHost = S.UIV3 and S.UIV3.PageHost or nil
local Feature = S.Features and S.Features.Activities or nil
if type(RSUI) ~= "table" or type(D) ~= "table" or type(PageHost) ~= "table" or type(Feature) ~= "table" then return end

local ROUTE = "life.activities"

local function OpenActivityDetail(row)
    if type(row) ~= "table" then return false end
    local modal = S.UIV3 and S.UIV3.QuestDetailModalV3 or nil
    if type(modal) ~= "table" or type(modal.Open) ~= "function" then return false end
    return modal:Open(row.questScope or "event", row.questKey, row)
end

local function BuildActivityPage(parent, route)
    local root, rootErr = D:PageRoot(parent, "v3_page_activities")
    if root == nil then return nil, "页面根组件创建失败：" .. tostring(rootErr or "未知错误") end
    local function RunAction(id, button, execute, busyText)
        if S.ActionRunner ~= nil then
            return S.ActionRunner:Run({ id = "activities." .. tostring(id), button = button, busyText = busyText or "处理中…", notify = false, execute = execute })
        end
        return execute()
    end
    D:PageHeader(root, "v3_activity_header", "活动", "俄服活动时间表 + 实时区域阶段 + 任务/副本参与进度。任务读取由共享 V3 Progress Service 按需运行，活动页面本身不直接调用游戏任务 API。", "刷新", function()
        return RunAction("refresh", nil, function()
            if S.FeatureRuntime == nil or S.FeatureRuntime:IsEnabled("life_activities") ~= true then return false end
            local progress = S.Services and S.Services.QuestProgressV3 or nil
            if type(progress) == "table" and type(progress.Refresh) == "function" then progress:Refresh("page_manual", true) end
            local refreshed, refreshErr = Feature.Commands:RefreshProjection("page_manual")
            return refreshed, refreshErr
        end, "刷新中…")
    end)

    local summaryCard = D:InfoCard(root, {
        id = "v3_activity_summary", title = "活动数据源", value = "正常", detail = "--",
        slot = { size = "fixed", height = 84, hAlign = "fill" },
    })

    local actionRow = RSUI:HorizontalBox({ id = "v3_activity_actions", parent = root, gap = 7, slot = { size = "fixed", height = 30, hAlign = "fill" } })
    local selectedKey = nil
    local tableView = nil
    local featureButton = RSUI:Button({ id = "v3_activity_feature_toggle", parent = actionRow, text = "关闭功能", compact = true, slot = { size = "fixed", width = 96 } })
    local widgetButton = RSUI:Button({ id = "v3_activity_widget_toggle", parent = actionRow, text = "打开悬浮窗", compact = true, slot = { size = "fixed", width = 116 } })
    widgetButton.onClick = function()
        return RunAction("widget_toggle", widgetButton, function()
            local visible = S.UIV3.WidgetHost and S.UIV3.WidgetHost:IsVisible("life.activities") == true
            local ok, err = Feature.Commands:SetWidgetVisible(not visible, "activity_page")
            if ok == true then root:Refresh() end
            return ok, err
        end)
    end
    featureButton.onClick = function()
        if S.FeatureRuntime == nil then return false, "FeatureRuntime 不可用" end
        local enabled = S.FeatureRuntime:IsEnabled("life_activities") == true
        local target = not enabled
        local ok, err = S.FeatureRuntime:SetPreferredEnabled("life_activities", target, "activity_page")
        if ok ~= true then return false, err end
        if target then
            local acquired, acquireErr = Feature:AcquireConsumer("page:activities")
            if acquired ~= true then
                local rolledBack, rollbackErr = S.FeatureRuntime:SetPreferredEnabled("life_activities", false, "activity_page_consumer_rollback")
                root:Refresh()
                if rolledBack ~= true then
                    return false, tostring(acquireErr or "活动页面 Consumer 启动失败") .. "；回滚失败：" .. tostring(rollbackErr or "unknown")
                end
                return false, acquireErr or "活动页面 Consumer 启动失败"
            end
            if S.Events ~= nil and type(S.Events.SubscribeInternal) == "function" then
                S.Events:UnsubscribeInternalOwner(root)
                S.Events:SubscribeInternal("v3.activities.updated", root, function() root:Refresh() end)
            end
        else
            -- FeatureRuntime:Disable already clears the feature Demand transactionally.
            -- Avoid issuing a second Release against a token that no longer exists.
            if S.Events ~= nil and type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(root) end
        end
        root:Refresh()
        return true
    end
    local featureExecute = featureButton.onClick
    featureButton.onClick = function()
        return RunAction("feature_toggle", featureButton, featureExecute)
    end
    local hideButton = RSUI:Button({
        id = "v3_activity_hide_selected", parent = actionRow, text = "隐藏所选", compact = true, enabled = false, slot = { size = "fixed", width = 96 },
        onClick = function()
            if selectedKey == nil then return false end
            local ok = Feature.Commands:HideEvent(selectedKey)
            if ok then
                selectedKey = nil
                if tableView ~= nil and type(tableView.GetSelectionModel) == "function" then
                    local model = tableView:GetSelectionModel()
                    if model ~= nil and type(model.Clear) == "function" then model:Clear("hidden") end
                end
            end
            return ok
        end,
    })
    local restoreButton = RSUI:Button({ id = "v3_activity_restore_hidden", parent = actionRow, text = "恢复隐藏", compact = true, slot = { size = "fixed", width = 96 } })
    restoreButton.onClick = function()
        return RunAction("restore_hidden", restoreButton, function()
            local ok, err = Feature.Commands:RestoreHiddenEvents()
            if ok ~= false then root:Refresh() end
            return ok ~= false, err
        end)
    end
    local hideExecute = hideButton.onClick
    hideButton.onClick = function() return RunAction("hide_selected", hideButton, hideExecute) end
    local progressHint = RSUI:Text({ id = "v3_activity_progress_hint", parent = root, text = "任务进度：共享数据源按需启动 · 点击活动行查看任务详情 · 鼠标滚轮可浏览全部活动", fontSize = 9, tone = "muted", overflow = "ellipsis", slot = { size = "fixed", height = 20, hAlign = "fill" } })

    tableView = RSUI:TableView({
        id = "v3_activity_table", parent = root, items = {},
        rowHeight = 29, headerHeight = 29, overscan = 2, desiredRows = 12,
        scrollbar = true, selectable = true, selectionMode = "single", columnResize = true, headerInteractive = false,
        getKey = function(item) return item and item.key or nil end,
        onItemActivated = function(item) return OpenActivityDetail(item) end,
        onSelectionChanged = function(_, _, view)
            selectedKey = view and type(view.GetSelectedKey) == "function" and view:GetSelectedKey() or nil
            local row = selectedKey and Feature:GetRow(selectedKey) or nil
            hideButton:SetEnabled(row ~= nil and row.zoneState ~= true)
        end,
        columns = {
            { id = "name", title = "活动", field = "name", size = "fill", minWidth = 126, fill = 1.0,
                getTone = function(item) return item and item.active and "red" or "default" end },
            { id = "status", title = "当前状态 / 倒计时", field = "status", size = "fill", minWidth = 176, fill = 1.35,
                getTone = function(item) return item and item.tone or "muted" end },
            { id = "schedule", title = "来源 / 下次", field = "scheduleText", size = "fill", minWidth = 116, fill = 0.85,
                getTone = function(item) return item and item.zoneState and "accent" or "muted" end },
            { id = "progress", title = "任务 / 参与", field = "progressText", size = "fill", minWidth = 70, absoluteMinWidth = 42, fill = 0.75,
                getTone = function(item) return item and item.progressTone or "muted" end },
        },
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })


    function root:Refresh()
        local enabled = S.FeatureRuntime ~= nil and S.FeatureRuntime:IsEnabled("life_activities") == true
        local rows, revision = Feature:GetRows()
        -- SetItems owns the visible-pool reconcile; do not immediately force a
        -- second row bind for the same revision.
        tableView:SetItems(rows, revision)
        if not enabled then
            tableView:SetViewState("unavailable", { title = "活动功能已关闭", detail = "启用功能后才会读取活动、区域阶段和任务参与进度。" })
        elseif #rows == 0 then
            tableView:SetViewState("empty", { title = "暂无活动", detail = "当前筛选与隐藏规则下没有可显示的活动。" })
        else
            tableView:SetViewState("ready")
        end
        local summary = Feature:GetSummary()
        summaryCard:SetData({
            value = enabled and (tostring(summary.active or 0) .. " 进行中") or "功能已关闭",
            detail = "共 " .. tostring(summary.total or 0) .. " 条 · 2小时内 " .. tostring(summary.withinTwoHours or 0)
                .. " · 实时区域 " .. tostring(summary.liveZones or 0) .. " · 已隐藏 " .. tostring(summary.hidden or 0)
                .. "\n区域状态读取失败 " .. tostring(summary.zoneScanFailures or 0) .. " · 数据版本 " .. tostring(summary.revision or 0),
        })
        local widgetVisible = S.UIV3.WidgetHost and S.UIV3.WidgetHost:IsVisible("life.activities") == true
        featureButton:SetText(enabled and "关闭功能" or "启用功能")
        widgetButton:SetEnabled(enabled)
        widgetButton:SetText(widgetVisible and "关闭悬浮窗" or "打开悬浮窗")
        local selectedRow = selectedKey and Feature:GetRow(selectedKey) or nil
        hideButton:SetEnabled(enabled and selectedRow ~= nil and selectedRow.zoneState ~= true)
        local progress = S.Services and S.Services.QuestProgressV3 or nil
        local health = type(progress) == "table" and type(progress.GetHealth) == "function" and progress:GetHealth() or nil
        if not enabled then
            progressHint:SetText("活动功能已关闭")
        elseif summary.progressAuthority and type(health) == "table" then
            progressHint:SetText("任务 / 副本进度：可用 " .. tostring(health.available or 0) .. "/" .. tostring(health.projections or 0)
                .. " · 数据版本 " .. tostring(health.revision or 0) .. " · 点击活动行查看详情")
        else
            progressHint:SetText("任务 / 副本进度：共享数据源不可用")
        end
        return true
    end

    function root:OnActivated()
        local enabled = S.FeatureRuntime ~= nil and S.FeatureRuntime:IsEnabled("life_activities") == true
        if enabled then
            Feature:AcquireConsumer("page:activities")
            if S.Events ~= nil and type(S.Events.SubscribeInternal) == "function" then
                S.Events:UnsubscribeInternalOwner(self)
                S.Events:SubscribeInternal("v3.activities.updated", self, function() root:Refresh() end)
            end
        end
        self:Refresh()
        return true
    end

    function root:OnDeactivated()
        if S.Events ~= nil and type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
        Feature:ReleaseConsumer("page:activities")
        return true
    end

    function root:RefreshData(dirty)
        local health = type(Feature.GetHealth) == "function" and Feature:GetHealth() or nil
        if tonumber(health and health.consumers) > 0 then Feature.Commands:RefreshProjection(type(dirty) == "table" and dirty.reason or "page_refresh_data", false) end
        return self:Refresh()
    end

    root.route = route
    root.tableView = tableView
    return root
end

local ok, err = PageHost:RegisterFactory(ROUTE, BuildActivityPage)
if ok ~= true then error(err) end

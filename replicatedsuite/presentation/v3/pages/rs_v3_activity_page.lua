-- Replicated Suite · 活动页面
-- 作者：Replicated
-- QQ群：1104129461
-- 总开关复用 PageHost 的按钮，刷新时不能改父级或重复绑定 OnClick。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI, D = S.RSUI, S.UIV3Design
local PageHost = S.UIV3 and S.UIV3.PageHost or nil
local Feature = S.Features and S.Features.Activities or nil
if type(RSUI) ~= "table" or type(D) ~= "table" or type(PageHost) ~= "table" or type(Feature) ~= "table" then return end

local ROUTE = "life.activities"

local function OpenActivityDetail(row)
    if type(row) ~= "table" then return false, "活动行数据不可用" end
    -- 主页面和悬浮组件共用独立详情窗口，Shell 关闭后仍能查看。
    local detail = S.UIV3 and S.UIV3.QuestDetailFloatingV3 or nil
    if type(detail) ~= "table" or type(detail.Open) ~= "function" then
        return false, "QuestDetailFloatingV3 未加载"
    end
    return detail:Open(row.questScope or "event", row.questKey, row)
end

local function BuildActivityPage(parent, route)
    local root, rootErr = D:PageRoot(parent, "v3_page_activities")
    if root == nil then return nil, "页面根组件创建失败：" .. tostring(rootErr or "未知错误") end
    root.consumerHeld = false
    local consumerBinding = { feature = Feature, featureId = "life_activities", token = "page:activities",
        refresh = function(page) return page:Refresh() end }
    local function RunAction(id, button, execute, busyText)
        if S.ActionRunner ~= nil then
            return S.ActionRunner:Run({ id = "activities." .. tostring(id), button = button, busyText = busyText or "处理中…", notify = false, execute = execute })
        end
        return execute()
    end
    -- 时间说明面对玩家；计划结束只是日程估计，实时区域的剩余时间属于当前阶段，两者不能混作首领存活时间。
    D:PageHeader(root, "v3_activity_header", "活动", "“后开始”表示距离开场的时间；“后结束”是计划结束估计。右侧显示计划时段，任务进度单独显示；下方实时区域显示当前阶段。", "刷新", function()
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
    local featureButton = D:ModuleToggleButton({ id = "v3_activity_feature_toggle", parent = actionRow, text = "关闭功能", compact = true, slot = { size = "fixed", width = 96 } })
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
        local synced, syncErr = PageHost:SyncFeatureConsumer(root, consumerBinding, "activity_page_toggle")
        if synced ~= true and target == true then
            local rolledBack, rollbackErr = S.FeatureRuntime:SetPreferredEnabled("life_activities", false, "activity_page_consumer_rollback")
            root.consumerHeld = false; root:Refresh()
            if rolledBack ~= true then return false, tostring(syncErr or "活动页面 Consumer 启动失败") .. "；回滚失败：" .. tostring(rollbackErr or "unknown") end
            return false, syncErr or "活动页面 Consumer 启动失败"
        end
        return root:Refresh()
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
    -- 恢复目录也列出已隐藏和未发生的活动、区域。
    RSUI:Button({id="v3_activity_customize",parent=actionRow,text="自定义",compact=true,slot={size="fixed",width=76},
        onClick=function()return S.UIV3.WorkspacePage:Open("lists","activities")end})
    local progressHint = RSUI:Text({ id = "v3_activity_progress_hint", parent = root, text = "排序：当前活动 → 即将开始（按时间）→ 实时区域（独立视口） · 点击活动行查看任务详情", fontSize = 9, tone = "muted", overflow = "ellipsis", slot = { size = "fixed", height = 20, hAlign = "fill" } })

    -- 时间线与区域各占一个视口，避免长时间线把区域挤出。
    tableView = S.UIV3.ActivityLists:Create({
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
                getTone = function(item) return "default" end },
            { id = "status", title = "时间 / 区域状态", field = "status", size = "fill", minWidth = 176, fill = 1.35,
                getTone = function(item) return item and item.tone or "muted" end },
            { id = "schedule", title = "计划时段 / 来源", field = "scheduleText", size = "fill", minWidth = 116, fill = 0.85,
                getTone = function(item) return item and item.zoneState and "accent" or "muted" end },
            { id = "progress", title = "任务 / 参与", field = "progressText", size = "fill", minWidth = 70, absoluteMinWidth = 42, fill = 0.75,
                getTone = function(item) return item and item.progressTone or "muted" end },
        },
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })


    function root:Refresh()
        local enabled = S.FeatureRuntime ~= nil and S.FeatureRuntime:IsEnabled("life_activities") == true
        local rows, revision = Feature:GetRows()
        -- 三个入口共用个人顺序；各视口排序副本，不改共享数组。
        local workspace=S.UIV3.Workspace
        if workspace then rows=workspace:ProjectRows("activities",rows);revision=tostring(revision)..":"..workspace.revision end
        -- 可见行池的协调由 SetItems 负责；同一 revision 不应紧接着强制再次绑定行。
        tableView:SetItems(rows, revision)
        if not enabled then
            tableView:SetViewState("unavailable", { title = "活动功能已关闭", detail = "启用功能后才会读取活动、区域阶段和任务参与进度。" })
        elseif #rows == 0 then
            tableView:SetViewState("empty", { title = "暂无活动", detail = "当前筛选与隐藏规则下没有可显示的活动。" })
        else
            tableView:SetViewState("ready")
        end
        local summary = Feature:GetSummary()
        local timing = Feature:GetTimingDiagnostics()
        summaryCard:SetData({
            -- timelineActive 是日程中的当前活动，liveZones 是实时区域状态。
            -- summary.active 仅供旧诊断使用，不能把两种含义合计显示。
            value = enabled and ("时间线 " .. tostring(summary.timelineTotal or 0)) or "功能已关闭",
            detail = "当前活动 " .. tostring(summary.timelineActive or 0) .. " · 2小时内 " .. tostring(summary.withinTwoHours or 0)
                .. " · 实时区域 " .. tostring(summary.liveZones or 0) .. " · 已隐藏 " .. tostring(summary.hidden or 0)
                .. "\n服务器样本 " .. tostring(timing.serverSample) .. (timing.fresh and "" or "（已过期/未知）")
                -- 普通页面只显示玩家需要的时间误差说明；来源可信度留在诊断中。
                .. " · 时间按活动日程估算，实际结束时间可能有偏差",
        })
        local widgetVisible = S.UIV3.WidgetHost and S.UIV3.WidgetHost:IsVisible("life.activities") == true
        featureButton:SetText(enabled and "关闭功能" or "启用功能")
        widgetButton:SetEnabled(enabled)
        widgetButton:SetText(widgetVisible and "关闭悬浮窗" or "打开悬浮窗")
        local selectedRow = selectedKey and Feature:GetRow(selectedKey) or nil
        hideButton:SetEnabled(enabled and selectedRow ~= nil)
        local progress = S.Services and S.Services.QuestProgressV3 or nil
        local health = type(progress) == "table" and type(progress.GetHealth) == "function" and progress:GetHealth() or nil
        if not enabled then
            progressHint:SetText("活动功能已关闭")
        elseif summary.progressAuthority and type(health) == "table" then
            progressHint:SetText("时间线按开始/结束时间排序 · 实时区域独立显示 · 任务进度 " .. tostring(health.available or 0) .. "/" .. tostring(health.projections or 0)
                .. " · 点击活动行查看详情")
        else
            progressHint:SetText("任务 / 副本进度：共享数据源不可用")
        end
        return true
    end

    function root:BindUpdates()
        if S.Events == nil or type(S.Events.SubscribeInternal) ~= "function" then return false, "内部事件总线不可用" end
        if type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
        if S.Events:SubscribeInternal("v3.activities.updated", self, function() root:Refresh() end) ~= true
            or S.Events:SubscribeInternal("v3.workspace.updated", self, function(_,kind)if kind=="lists" then root:Refresh() end end) ~= true then
            S.Events:UnsubscribeInternalOwner(self); return false, "活动页面更新事件订阅失败"
        end
        local ok, err = PageHost:BindFeatureConsumerLifecycle(self, consumerBinding)
        if ok ~= true then S.Events:UnsubscribeInternalOwner(self); return false, err end
        return true
    end
    function root:OnActivated()
        local bound, bindErr = self:BindUpdates(); if bound ~= true then return false, bindErr end
        return PageHost:SyncFeatureConsumer(self, consumerBinding, "page_activated")
    end

    function root:OnDeactivated()
        if S.Events ~= nil and type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
        return PageHost:ReleaseFeatureConsumer(self, consumerBinding, "page_deactivated")
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

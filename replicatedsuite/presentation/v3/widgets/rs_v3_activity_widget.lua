------------------------------------------------------------------------
-- Replicated Suite V3 - Activity Floating Widget
-- Presentation content only. Outer HUD chrome/state is owned by RSUI
-- FloatingSurface -> WindowShellV3 -> Windowing.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI = S.RSUI
local Host = S.UIV3 and S.UIV3.WidgetHost or nil
local Feature = S.Features and S.Features.Activities or nil
local Floating = RSUI and RSUI.FloatingSurface or nil
if type(RSUI) ~= "table" or type(Host) ~= "table" or type(Feature) ~= "table" or type(Floating) ~= "table" then return end

local WIDGET_ID = "life.activities"
local OWNER = "v3:widget:activities"

local function SurfacePolicy()
    local size = type(Feature.GetWidgetWindowPolicy) == "function" and Feature:GetWidgetWindowPolicy() or { defaultWidth = 430, defaultHeight = 276, minWidth = 1, minHeight = 1 }
    return {
        defaultWidth = size.defaultWidth, defaultHeight = size.defaultHeight,
        minWidth = size.minWidth, minHeight = size.minHeight,
        defaultOverallOpacity = 0.94, defaultBackgroundOpacity = 1.0, defaultTextOpacity = 1.0,
    }
end

local function PersistSurface(reason, delayMs)
    return Feature.Commands:MarkStoreDirty(delayMs or 250, "widget_" .. tostring(reason or "state"))
end

local function CreateActivityWidget()
    local instance = {
        id = WIDGET_ID,
        owner = OWNER,
        visible = false,
        subscribed = false,
        rows = {},
        lastRevision = -1,
    }

    local surface, err = Floating:Create({
        id = "v3_activity_widget",
        owner = OWNER,
        title = "活动",
        status = "--",
        footer = true,
        footerHeight = 18,
        footerPadding = 1,
        titleHeight = 22,
        titleFontSize = 10,
        titleControlWidth = 21,
        padding = 2,
        gap = 2,
        resizable = true,
        movable = true,
        minimizeMode = "compact",
        boundaryMode = "free",
        defaultPlacement = "top-right",
        statePolicy = SurfacePolicy(),
        getState = function() return Feature:GetWidgetWindowState() end,
        setState = function(value, reason) return Feature.Commands:SetWidgetWindowState(value, reason) end,
        persist = PersistSurface,
        onClosed = function(_, reason)
            return Host:NotifyWindowClosed(WIDGET_ID, { source = tostring(reason or "widget_close"), persist = true })
        end,
    })
    if surface == nil then return nil, err or "活动悬浮窗创建失败" end
    instance.surface = surface
    instance.shell = surface.shell
    instance.window = surface.window
    instance.root = surface.shell.root
    instance.windowController = surface.windowController

    local content = RSUI:VerticalBox({
        id = "v3_activity_widget_content", parent = surface:GetContentRoot(), gap = 5,
        slot = { hAlign = "fill", vAlign = "fill" },
    })
    instance.table = RSUI:TableView({
        id = "v3_activity_widget_table", parent = content,
        items = instance.rows,
        rowHeight = 24, headerHeight = 22, desiredRows = Feature:GetWidgetRows(), overscan = 1,
        scrollbar = true, overlayScrollbar = true, scrollbarWidth = 7, scrollbarGap = 1,
        selectable = false, columnResize = false, headerInteractive = false, columnGap = 2, cellPaddingX = 4, rowFontSize = 10, headerFontSize = 9,
        onItemActivated = function(item)
            local modal = S.UIV3 and S.UIV3.QuestDetailFloatingV3 or nil
            if type(modal) ~= "table" or type(modal.Open) ~= "function" then return false end
            return modal:Open(item and item.questScope or "event", item and item.questKey or nil, item)
        end,
        columns = {
            { id = "name", title = "活动", field = "shortName", size = "fill", minWidth = 62, absoluteMinWidth = 28, fill = 0.75,
                getTone = function(item) return item and item.active and "red" or "default" end },
            { id = "status", title = "状态 / 时间", field = "status", size = "fill", minWidth = 92, absoluteMinWidth = 46, fill = 1.35,
                getTone = function(item) return item and item.tone or "muted" end },
            { id = "progress", title = "进度", field = "progressText", size = "fill", minWidth = 38, absoluteMinWidth = 30, fill = 0.65, resizable = false,
                getTone = function(item) return item and item.progressTone or "muted" end },
        },
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })

    function instance:Refresh()
        -- Feed the virtualized view the full bounded Activity projection. The
        -- viewport (not a pre-truncated data slice) owns how many rows are
        -- visible, so vertical window resizing immediately reveals/hides rows.
        local rows, revision = Feature:GetRows()
        self.rows = rows
        self.lastRevision = tonumber(revision) or self.lastRevision
        self.table:SetItems(rows, revision)
        if #rows == 0 then
            self.table:SetViewState("empty", { title = "暂无活动", detail = "当前没有可显示的活动；隐藏规则和区域状态变化后会自动刷新。" })
        else
            self.table:SetViewState("ready")
        end
        local summary = Feature:GetSummary()
        self.surface:SetStatus("进行中 " .. tostring(summary.active or 0) .. " · 两小时内 " .. tostring(summary.withinTwoHours or 0),
            (tonumber(summary.active) or 0) > 0 and "orange" or "muted")
        return true
    end

    function instance:Subscribe()
        if self.subscribed == true then return true end
        if S.Events ~= nil and type(S.Events.SubscribeInternal) == "function" then
            S.Events:SubscribeInternal("v3.activities.updated", self, function() if instance.visible then instance:Refresh() end end)
        end
        self.subscribed = true
        return true
    end

    function instance:Unsubscribe()
        if self.subscribed ~= true then return true end
        if S.Events ~= nil and type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
        self.subscribed = false
        return true
    end

    function instance:Show(context)
        if self.visible == true then
            self:Refresh()
            return self.surface:Show(true)
        end
        local acquired = false
        self.table:SetViewState("loading", { title = "正在读取活动…", detail = "正在建立活动 Consumer。" })
        local ok, openErr = xpcall(function()
            self:Subscribe()
            local acquireOk, acquireErr = Feature:AcquireConsumer("widget:activities")
            if acquireOk ~= true then error(acquireErr or "活动悬浮窗数据订阅失败") end
            acquired = true
            if self:Refresh() ~= true then error("活动悬浮窗刷新失败") end
            if self.surface:Show(true) ~= true then error("活动悬浮窗显示失败") end
        end, S.SafeTraceback)
        if ok ~= true then
            self.surface:Show(false)
            self:Unsubscribe()
            if acquired then Feature:ReleaseConsumer("widget:activities") end
            self.visible = false
            return false, openErr
        end
        self.visible = true
        if type(context) ~= "table" or context.persist ~= false then
            Feature.Commands:SetWidgetVisible(true, "widget_show")
        end
        return true
    end

    -- FeatureRuntime:Disable clears the whole Demand lease before the widget
    -- hide reaction runs, so the widget's own token is already gone by then.
    -- Treat "feature no longer enabled" as "nothing left to release" instead of
    -- failing the hide, which used to leave the window stuck on screen.
    local function ReleaseWidgetConsumer()
        -- Capture the concrete instance. The old helper referenced an undefined
        -- `self`, throwing before widgetVisible/Host state could be cleared and
        -- allowing the lifecycle bridge to resurrect a just-closed window.
        if instance.visible ~= true then return true end
        if not (S.FeatureRuntime and S.FeatureRuntime:IsEnabled("life_activities") == true) then return true end
        return Feature:ReleaseConsumer("widget:activities")
    end

    function instance:Hide(context)
        local hidden, hideErr = self.surface:Show(false)
        if hidden ~= true then return false, hideErr end
        local released, releaseErr = true, nil
        if self.visible == true then released, releaseErr = ReleaseWidgetConsumer() end
        self.visible = false
        self:Unsubscribe()
        if type(context) ~= "table" or context.persist ~= false then
            Feature.Commands:SetWidgetVisible(false, "widget_hide")
        end
        if released ~= true then return false, releaseErr end
        return true
    end
    function instance:OnWindowClosed(context)
        local released, releaseErr = ReleaseWidgetConsumer()
        self.visible = false
        self:Unsubscribe()
        if type(context) ~= "table" or context.persist ~= false then
            Feature.Commands:ResetWidgetVisibility("widget_native_close")
        end
        if released ~= true then return false, releaseErr end
        return true
    end

    function instance:ApplyProjection(kind)
        -- Visible row count is viewport-owned. Historical widgetRows remains a
        -- persisted compatibility field only; never re-apply it as a runtime cap.
        if tostring(kind or "") == "size" then
            if self.shell.minimized == true then self.surface:SetMinimized(false, false) end
            return self.surface:ApplyLayout(false)
        end
        return self:Refresh()
    end
    function instance:Open(context) return self:Show(context) end
    function instance:Close(context) return self:Hide(context) end
    function instance:ApplyLayout(fromMetricsChange) return self.surface:ApplyLayout(fromMetricsChange == true) end
    function instance:ApplyMinimizedState() return self.surface:ApplyLayout(false) end
    function instance:SetSize(width, height, persist) return self.surface:SetSize(width, height, persist) end
    function instance:SetLocked(value, persist) return self.surface:SetLocked(value, persist) end
    function instance:IsLocked() return self.surface:IsLocked() end
    function instance:GetLocked() return self.surface:IsLocked() end
    function instance:SetMinimized(value, persist) return self.surface:SetMinimized(value, persist) end
    function instance:IsMinimized() return self.surface:IsMinimized() end
    function instance:SetOverallOpacity(value, persist) return self.surface:SetOverallOpacity(value, persist) end
    function instance:GetOverallOpacity() return self.surface:GetOverallOpacity() end
    function instance:SetOpacity(value, persist) return self.surface:SetOverallOpacity(value, persist) end
    function instance:GetOpacity() return self.surface:GetOverallOpacity() end
    function instance:SetBackgroundOpacity(value, persist) return self.surface:SetBackgroundOpacity(value, persist) end
    function instance:GetBackgroundOpacity() return self.surface:GetBackgroundOpacity() end
    function instance:SetTextOpacity(value, persist) return self.surface:SetTextOpacity(value, persist) end
    function instance:GetTextOpacity() return self.surface:GetTextOpacity() end
    function instance:SetFontScale(value, persist) return self.surface:SetFontScale(value, persist) end
    function instance:GetFontScale() return self.surface:GetFontScale() end
    function instance:ResetLayout(persist) return self.surface:ResetLayout(persist) end
    return instance
end

local stateAdapter = Floating:CreateStateAdapter({
    statePolicy = SurfacePolicy(),
    getState = function() return Feature:GetWidgetWindowState() end,
    setState = function(value, reason) return Feature.Commands:SetWidgetWindowState(value, reason) end,
    persist = PersistSurface,
})

local ok, registerErr = Host:Register(WIDGET_ID, {
    featureId = "life_activities",
    create = CreateActivityWidget,
    ensurePreferences = function() return Feature:EnsureStoreLoaded() end,
    lockable = true,
    minimizable = true,
    resettable = true,
    opacityAdjustable = true,
    backgroundOpacityAdjustable = true,
    textOpacityAdjustable = true,
    fontScaleAdjustable = true,
    getLocked = stateAdapter.getLocked,
    setLocked = stateAdapter.setLocked,
    getMinimized = stateAdapter.getMinimized,
    setMinimized = stateAdapter.setMinimized,
    getOverallOpacity = stateAdapter.getOverallOpacity,
    setOverallOpacity = stateAdapter.setOverallOpacity,
    getOpacity = stateAdapter.getOpacity,
    setOpacity = stateAdapter.setOpacity,
    getBackgroundOpacity = stateAdapter.getBackgroundOpacity,
    setBackgroundOpacity = stateAdapter.setBackgroundOpacity,
    getTextOpacity = stateAdapter.getTextOpacity,
    setTextOpacity = stateAdapter.setTextOpacity,
    getFontScale = stateAdapter.getFontScale,
    setFontScale = stateAdapter.setFontScale,
    resetLayout = stateAdapter.resetLayout,
})
if ok ~= true then error(registerErr) end

------------------------------------------------------------------------
-- Presentation-owned lifecycle reaction.
--
-- Domain publishes facts only (`v3.feature.lifecycle`, `v3.activities.*`);
-- the widget decides what to do with them. This replaces the previous
-- Domain → WidgetHost calls inside the Activity Feature.
------------------------------------------------------------------------
if S.Events ~= nil and type(S.Events.SubscribeInternal) == "function" then
    Host:BindFeatureLifecycle(WIDGET_ID, {
        featureId = "life_activities",
        enabled = function() return S.FeatureRuntime ~= nil and S.FeatureRuntime:IsEnabled("life_activities") == true end,
        preference = function() return Feature:GetWidgetVisiblePreference() end,
        onShowFailed = function(reason)
            if type(Feature.Commands) == "table" and type(Feature.Commands.ResetWidgetVisibility) == "function" then
                pcall(Feature.Commands.ResetWidgetVisibility, Feature.Commands, "auto_show_failed:" .. tostring(reason or "enable"))
            end
        end,
    })

    local Reaction = { id = "v3:activities:widget_reaction" }
    S.Events:SubscribeInternal("v3.activities.widget_visibility", Reaction, function(_, visible, source)
        local nextValue = visible == true
        if nextValue == true and not (S.FeatureRuntime and S.FeatureRuntime:IsEnabled("life_activities") == true) then return end
        if Host:IsVisible(WIDGET_ID) == nextValue then return end
        Host:SetVisible(WIDGET_ID, nextValue, { persist = false, source = tostring(source or "domain_state") })
    end)
    S.Events:SubscribeInternal("v3.activities.widget_projection", Reaction, function(_, kind)
        Host:NotifyProjectionChanged(WIDGET_ID, kind)
    end)
end

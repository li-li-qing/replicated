------------------------------------------------------------------------
-- Replicated Suite V3 - Task Tracker Floating Widget
-- Presentation content only. Shared HUD state is bound by RSUI FloatingSurface.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI = S.RSUI
local Host = S.UIV3 and S.UIV3.WidgetHost or nil
local Feature = S.Features and S.Features.Tasks or nil
local Floating = RSUI and RSUI.FloatingSurface or nil
if type(RSUI) ~= "table" or type(Host) ~= "table" or type(Feature) ~= "table" or type(Floating) ~= "table" then return end

local WIDGET_ID = "life.tasks"
local OWNER = "v3:widget:tasks"

local function SurfacePolicy()
    local size = type(Feature.GetWidgetWindowPolicy) == "function" and Feature:GetWidgetWindowPolicy() or { defaultWidth = 420, defaultHeight = 286, minWidth = 1, minHeight = 1 }
    return {
        defaultWidth = size.defaultWidth, defaultHeight = size.defaultHeight,
        minWidth = size.minWidth, minHeight = size.minHeight,
        defaultOverallOpacity = 0.94, defaultBackgroundOpacity = 1.0, defaultTextOpacity = 1.0,
    }
end

local function PersistSurface(reason, delayMs)
    return Feature.Commands:MarkStoreDirty(delayMs or 250, "task_widget_" .. tostring(reason or "state"))
end

local function OpenDetail(row)
    if type(row) ~= "table" then return false end
    local modal = S.UIV3 and S.UIV3.QuestDetailFloatingV3 or nil
    if type(modal) ~= "table" or type(modal.Open) ~= "function" then return false end
    return modal:Open(row.scope or "daily", row.groupKey or row.key, row)
end

local function CreateTaskWidget()
    local instance = { id = WIDGET_ID, owner = OWNER, visible = false, subscribed = false }
    local surface, err = Floating:Create({
        id = "v3_task_tracker_widget",
        owner = OWNER,
        title = "任务追踪",
        status = "--",
        footer = true,
        resizable = true,
        movable = true,
        minimizeMode = "compact",
        boundaryMode = "free",
        defaultPlacement = "center",
        -- Preserve the existing Task Widget size semantics. Its v1 Store saved
        -- native/logical window extents directly; converting those historical
        -- values to addonScale-relative design units here would resize existing
        -- user layouts on upgrade. A future schema migration may opt in explicitly.
        scaleWithAddon = false,
        statePolicy = SurfacePolicy(),
        getState = function() return Feature:GetWidgetWindowState() end,
        setState = function(value, reason) return Feature.Commands:SetWidgetWindowState(value, reason) end,
        persist = PersistSurface,
        onClosed = function(_, reason)
            return Host:NotifyWindowClosed(WIDGET_ID, { source = tostring(reason or "task_widget_close"), persist = true })
        end,
    })
    if surface == nil then return nil, err or "任务追踪悬浮窗创建失败" end
    instance.surface = surface
    instance.shell = surface.shell
    instance.window = surface.window
    instance.windowController = surface.windowController

    local root = RSUI:VerticalBox({ id = "v3_task_widget_content", parent = surface:GetContentRoot(), gap = 5, slot = { hAlign = "fill", vAlign = "fill" } })
    instance.summary = RSUI:Text({ id = "v3_task_widget_summary", parent = root, text = "--", fontSize = 9, tone = "muted", overflow = "ellipsis", slot = { size = "fixed", height = 19, hAlign = "fill" } })
    instance.table = RSUI:TableView({
        id = "v3_task_widget_table", parent = root, items = {},
        rowHeight = 27, headerHeight = 27, desiredRows = Feature:GetWidgetRowCount(), overscan = 2,
        scrollbar = true, selectable = false, columnResize = true, headerInteractive = false,
        getKey = function(item) return item and item.id or nil end,
        onItemActivated = function(item) return OpenDetail(item) end,
        columns = {
            { id = "cycle", title = "周期", field = "cycleText", size = "fill", minWidth = 44, absoluteMinWidth = 28, fill = 0.6, tone = "muted" },
            { id = "name", title = "追踪任务", field = "rawName", size = "fill", minWidth = 190, absoluteMinWidth = 64, fill = 1.5,
                getTone = function(item) return item and item.tone or "default" end },
            { id = "progress", title = "进度", field = "progressText", size = "fill", minWidth = 54, absoluteMinWidth = 36, fill = 0.9,
                getTone = function(item) return item and item.tone or "muted" end },
            { id = "status", title = "状态", field = "status", size = "fill", minWidth = 60, absoluteMinWidth = 40, fill = 0.9,
                getTone = function(item) return item and item.tone or "muted" end },
        },
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })

    function instance:Refresh()
        local rows, revision = Feature:GetWidgetProjection()
        self.table:SetItems(rows, "task_widget:" .. tostring(revision))
        if #rows == 0 then
            self.table:SetViewState("empty", { title = "暂无追踪任务", detail = "在“我的任务追踪”中加入日常 / 周常后会显示在这里。" })
        else
            self.table:SetViewState("ready")
        end
        local summary = Feature:GetSummary()
        self.summary:SetText("追踪 " .. tostring(summary.tracked) .. " · 未完成 " .. tostring(summary.unfinished) .. " · 可交付 " .. tostring(summary.ready))
        self.surface:SetStatus("日常 + 周常 · " .. tostring(#rows) .. " 项", summary.ready > 0 and "orange" or "muted")
        return true
    end

    function instance:Subscribe()
        if self.subscribed == true then return true end
        if S.Events ~= nil and type(S.Events.SubscribeInternal) == "function" then
            S.Events:SubscribeInternal("v3.tasks.updated", self, function() if instance.visible then instance:Refresh() end end)
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
        if self.visible == true then self:Refresh(); return self.surface:Show(true) end
        local acquired = false
        self.table:SetViewState("loading", { title = "正在读取任务…", detail = "正在建立任务进度 Consumer。" })
        local ok, openErr = xpcall(function()
            self:Subscribe()
            local acquireOk, acquireErr = Feature:AcquireConsumer("widget:tasks")
            if acquireOk ~= true then error(acquireErr or "任务追踪数据订阅失败") end
            acquired = true
            self:Refresh()
            if self.surface:Show(true) ~= true then error("任务追踪悬浮窗显示失败") end
        end, S.SafeTraceback)
        if ok ~= true then
            self.surface:Show(false)
            self:Unsubscribe()
            if acquired then Feature:ReleaseConsumer("widget:tasks") end
            self.visible = false
            return false, openErr
        end
        self.visible = true
        if type(context) ~= "table" or context.persist ~= false then
            Feature.Commands:SetWidgetVisible(true, "task_widget_show")
        end
        return true
    end

    -- FeatureRuntime:Disable clears the whole Demand lease before the hide
    -- reaction runs, so the widget token is already gone by then. Treat
    -- "feature no longer enabled" as "nothing left to release"; failing here
    -- used to leave the floating window stuck on screen after a disable.
    local function ReleaseWidgetConsumer()
        -- Capture the concrete instance; using an undefined `self` here makes
        -- native X-close cleanup fail before the persistent visibility bit is
        -- cleared, which can make the lifecycle bridge reopen the widget.
        if instance.visible ~= true then return true end
        if not (S.FeatureRuntime and S.FeatureRuntime:IsEnabled("life_tasks") == true) then return true end
        return Feature:ReleaseConsumer("widget:tasks")
    end

    function instance:Hide(context)
        local hidden, hideErr = self.surface:Show(false)
        if hidden ~= true then return false, hideErr end
        local released, releaseErr = true, nil
        if self.visible == true then released, releaseErr = ReleaseWidgetConsumer() end
        self.visible = false
        self:Unsubscribe()
        if type(context) ~= "table" or context.persist ~= false then
            Feature.Commands:SetWidgetVisible(false, "task_widget_hide")
        end
        if released ~= true then return false, releaseErr end
        return true
    end
    function instance:OnWindowClosed(context)
        local released, releaseErr = ReleaseWidgetConsumer()
        self.visible = false
        self:Unsubscribe()
        if type(context) ~= "table" or context.persist ~= false then
            Feature.Commands:ResetWidgetVisibility("task_widget_native_close")
        end
        if released ~= true then return false, releaseErr end
        return true
    end

    function instance:Open(context) return self:Show(context) end
    function instance:Close(context) return self:Hide(context) end
    function instance:ApplyLayout(fromMetricsChange) return self.surface:ApplyLayout(fromMetricsChange == true) end
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
    function instance:ApplyProjection() return self:Refresh() end
    return instance
end

local stateAdapter = Floating:CreateStateAdapter({
    statePolicy = SurfacePolicy(),
    getState = function() return Feature:GetWidgetWindowState() end,
    setState = function(value, reason) return Feature.Commands:SetWidgetWindowState(value, reason) end,
    persist = PersistSurface,
})

local ok, registerErr = Host:Register(WIDGET_ID, {
    featureId = "life_tasks",
    create = CreateTaskWidget,
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
-- Presentation-owned lifecycle reaction (mirrors the Activity widget).
-- Domain publishes facts; the widget performs the show/hide.
------------------------------------------------------------------------
if S.Events ~= nil and type(S.Events.SubscribeInternal) == "function" then
    Host:BindFeatureLifecycle(WIDGET_ID, {
        featureId = "life_tasks",
        enabled = function() return S.FeatureRuntime ~= nil and S.FeatureRuntime:IsEnabled("life_tasks") == true end,
        preference = function() return Feature:GetWidgetVisiblePreference() end,
        onShowFailed = function(reason)
            if type(Feature.Commands) == "table" and type(Feature.Commands.ResetWidgetVisibility) == "function" then
                pcall(Feature.Commands.ResetWidgetVisibility, Feature.Commands, "auto_show_failed:" .. tostring(reason or "enable"))
            end
        end,
    })
    local Reaction = { id = "v3:tasks:widget_reaction" }
    S.Events:SubscribeInternal("v3.tasks.widget_visibility", Reaction, function(_, visible, source)
        local nextValue = visible == true
        if nextValue == true and not (S.FeatureRuntime and S.FeatureRuntime:IsEnabled("life_tasks") == true) then return end
        if Host:IsVisible(WIDGET_ID) == nextValue then return end
        Host:SetVisible(WIDGET_ID, nextValue, { persist = false, source = tostring(source or "domain_state") })
    end)
end

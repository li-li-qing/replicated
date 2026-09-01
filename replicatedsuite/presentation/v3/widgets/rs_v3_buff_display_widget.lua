------------------------------------------------------------------------
-- Replicated Suite V3 - Buff Display Floating Widget
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI = S.RSUI
local Host = S.UIV3 and S.UIV3.WidgetHost or nil
local Feature = S.Features and S.Features.BuffDisplay or nil
local Floating = RSUI and RSUI.FloatingSurface or nil
if type(RSUI) ~= "table" or type(Host) ~= "table" or type(Feature) ~= "table" or type(Floating) ~= "table" then return end

local ID, OWNER = "combat.buff_display", "v3:widget:buff_display"
local function Policy() return { defaultWidth = 430, defaultHeight = 300, minWidth = 180, minHeight = 100, defaultOverallOpacity = 0.94, defaultBackgroundOpacity = 1, defaultTextOpacity = 1 } end
local function Persist(reason) return Feature.Commands:MarkStoreDirty(250, "widget_" .. tostring(reason or "state")) end

local function CreateWidget()
    local instance = { id = ID, owner = OWNER, visible = false, subscribed = false, rows = {} }
    local surface, err = Floating:Create({ id = "v3_buff_display_widget", owner = OWNER, title = "状态显示", status = "--", footer = true, resizable = true, movable = true, minimizeMode = "compact", boundaryMode = "free", defaultPlacement = "top-right", statePolicy = Policy(), getState = function() return Feature:GetWidgetWindowState() end, setState = function(value, reason) return Feature.Commands:SetWidgetWindowState(value, reason) end, persist = Persist, onClosed = function(_, reason) return Host:NotifyWindowClosed(ID, { source = tostring(reason or "widget_close"), persist = true }) end })
    if surface == nil then return nil, err or "状态显示悬浮窗创建失败" end
    instance.surface, instance.shell, instance.window, instance.root, instance.windowController = surface, surface.shell, surface.window, surface.shell.root, surface.windowController
    local content = RSUI:VerticalBox({ id = "v3_buff_display_widget_content", parent = surface:GetContentRoot(), gap = 4, slot = { hAlign = "fill", vAlign = "fill" } })
    instance.table = RSUI:TableView({ id = "v3_buff_display_widget_table", parent = content, items = {}, rowHeight = 24, headerHeight = 23, desiredRows = 10, overscan = 1, scrollbar = true, selectable = false, headerInteractive = false, columns = {
        { id = "scope", title = "", field = "scopeText", size = "fixed", width = 34, minWidth = 30, sortable = false },
        { id = "name", title = "状态", field = "name", size = "fill", minWidth = 100, fill = 1 },
        { id = "type", title = "类型", field = "effectTypeText", size = "fixed", width = 52, minWidth = 46, sortable = false },
        { id = "stack", title = "层", field = "stack", size = "fixed", width = 32, minWidth = 28, sortable = false },
        { id = "time", title = "剩余", field = "timeText", size = "fixed", width = 50, minWidth = 44, sortable = false },
    }, slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" } })
    function instance:Refresh()
        local rows, revision, coverage = Feature:GetProjection("all", 24)
        local playerCount, targetCount = 0, 0
        for _, row in ipairs(rows) do
            if row.scope == "player" then playerCount = playerCount + 1 else targetCount = targetCount + 1 end
        end
        self.rows = rows
        self.table:SetItems(rows, revision)
        local playerAvailable = type(coverage) == "table" and type(coverage.player) == "table" and coverage.player.available == true
        local targetAvailable = type(coverage) == "table" and type(coverage.target) == "table" and coverage.target.available == true
        local factsAvailable = playerAvailable or targetAvailable
        self.table:SetViewState(not factsAvailable and "unavailable" or (#rows > 0 and "ready" or "empty"), {
            title = not factsAvailable and "状态事实不可用" or "暂无状态",
            detail = not factsAvailable and "共享 Aura 事实读取失败；这不是“没有 Buff”。" or "Aura 已成功读取，但当前筛选没有可显示行。"
        })
        local health = Feature:GetHealth()
        self.surface:SetStatus("自己 " .. tostring(playerCount) .. " · 目标 " .. tostring(targetCount), factsAvailable and "accent" or "warn")
        return true
    end
    function instance:Subscribe()
        if self.subscribed == true then return true end
        if S.Events ~= nil and type(S.Events.SubscribeInternal) == "function" then S.Events:SubscribeInternal("v3.buff_display.updated", self, function() if instance.visible then instance:Refresh() end end) end
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
        local ok, showErr = xpcall(function()
            self:Subscribe()
            local acquireOk, acquireErr = Feature:AcquireConsumer("widget:buff_display")
            if acquireOk ~= true then error(acquireErr or "状态显示悬浮窗订阅失败") end
            acquired = true
            self:Refresh()
            if self.surface:Show(true) ~= true then error("状态显示悬浮窗显示失败") end
        end, S.SafeTraceback)
        if ok ~= true then
            self.surface:Show(false); self:Unsubscribe(); if acquired then Feature:ReleaseConsumer("widget:buff_display") end; self.visible = false
            return false, showErr
        end
        self.visible = true
        if type(context) ~= "table" or context.persist ~= false then Feature.Commands:SetWidgetVisible(true, "show") end
        return true
    end
    function instance:Hide(context)
        if self.visible == true and S.FeatureRuntime:IsEnabled("combat_buff_display") == true then
            local ok, hideErr = Feature:ReleaseConsumer("widget:buff_display")
            if ok ~= true then return false, hideErr end
        end
        self.visible = false; self:Unsubscribe(); self.surface:Show(false)
        if type(context) ~= "table" or context.persist ~= false then Feature.Commands:SetWidgetVisible(false, "hide") end
        return true
    end
    function instance:OnWindowClosed(context)
        local released, releaseErr = true, nil
        if self.visible == true and S.FeatureRuntime:IsEnabled("combat_buff_display") == true then released, releaseErr = Feature:ReleaseConsumer("widget:buff_display") end
        self.visible = false; self:Unsubscribe()
        if type(context) ~= "table" or context.persist ~= false then Feature.Commands:SetWidgetVisible(false, "native_close") end
        if released ~= true then return false, releaseErr end
        return true
    end
    function instance:ApplyProjection() return self:Refresh() end
    function instance:Open(context) return self:Show(context) end
    function instance:Close(context) return self:Hide(context) end
    function instance:ApplyLayout(fromMetricsChange) return self.surface:ApplyLayout(fromMetricsChange == true) end
    function instance:SetSize(w, h, persist) return self.surface:SetSize(w, h, persist) end
    function instance:SetLocked(v, persist) return self.surface:SetLocked(v, persist) end
    function instance:IsLocked() return self.surface:IsLocked() end
    function instance:GetLocked() return self.surface:IsLocked() end
    function instance:SetMinimized(v, persist) return self.surface:SetMinimized(v, persist) end
    function instance:IsMinimized() return self.surface:IsMinimized() end
    function instance:SetOverallOpacity(v, persist) return self.surface:SetOverallOpacity(v, persist) end
    function instance:GetOverallOpacity() return self.surface:GetOverallOpacity() end
    function instance:SetOpacity(v, persist) return self.surface:SetOverallOpacity(v, persist) end
    function instance:GetOpacity() return self.surface:GetOverallOpacity() end
    function instance:SetBackgroundOpacity(v, persist) return self.surface:SetBackgroundOpacity(v, persist) end
    function instance:GetBackgroundOpacity() return self.surface:GetBackgroundOpacity() end
    function instance:SetTextOpacity(v, persist) return self.surface:SetTextOpacity(v, persist) end
    function instance:GetTextOpacity() return self.surface:GetTextOpacity() end
    function instance:ResetLayout(persist) return self.surface:ResetLayout(persist) end
    return instance
end

local adapter = Floating:CreateStateAdapter({ statePolicy = Policy(), getState = function() return Feature:GetWidgetWindowState() end,
    setState = function(value, reason) return Feature.Commands:SetWidgetWindowState(value, reason) end, persist = Persist })
local ok, err = Host:Register(ID, { featureId = "combat_buff_display", create = CreateWidget, ensurePreferences = function() return Feature:EnsureStoreLoaded() end, lockable = true, minimizable = true, resettable = true, opacityAdjustable = true, backgroundOpacityAdjustable = true, textOpacityAdjustable = true, getLocked = adapter.getLocked, setLocked = adapter.setLocked, getMinimized = adapter.getMinimized, setMinimized = adapter.setMinimized, getOverallOpacity = adapter.getOverallOpacity, setOverallOpacity = adapter.setOverallOpacity, getOpacity = adapter.getOpacity, setOpacity = adapter.setOpacity, getBackgroundOpacity = adapter.getBackgroundOpacity, setBackgroundOpacity = adapter.setBackgroundOpacity, getTextOpacity = adapter.getTextOpacity, setTextOpacity = adapter.setTextOpacity, resetLayout = adapter.resetLayout })
if ok ~= true then error(err) end
if S.Events ~= nil and type(S.Events.SubscribeInternal) == "function" then
    Host:BindFeatureLifecycle(ID, { featureId = "combat_buff_display", enabled = function() return S.FeatureRuntime:IsEnabled("combat_buff_display") == true end, preference = function() return Feature:GetWidgetVisible() == true end, onShowFailed = function() Feature.Commands:SetWidgetVisible(false, "auto_show_failed") end })
end

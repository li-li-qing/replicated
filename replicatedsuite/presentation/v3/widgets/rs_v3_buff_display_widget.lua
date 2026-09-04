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
    local surface, err = Floating:Create({ id = "v3_buff_display_widget", owner = OWNER, title = "状态追踪", status = "--", footer = true, resizable = true, movable = true, minimizeMode = "compact", boundaryMode = "free", defaultPlacement = "top-right", statePolicy = Policy(), getState = function() return Feature:GetWidgetWindowState() end, setState = function(value, reason) return Feature.Commands:SetWidgetWindowState(value, reason) end, persist = Persist, onClosed = function(_, reason) return Host:NotifyWindowClosed(ID, { source = tostring(reason or "widget_close"), persist = true }) end })
    if surface == nil then return nil, err or "状态显示悬浮窗创建失败" end
    instance.surface, instance.shell, instance.window, instance.root, instance.windowController = surface, surface.shell, surface.window, surface.shell.root, surface.windowController
    local content = RSUI:VerticalBox({ id = "v3_buff_display_widget_content", parent = surface:GetContentRoot(), gap = 4, slot = { hAlign = "fill", vAlign = "fill" } })
    -- Quick actions: open the settings panel (the game UI can cover the main
    -- window, so an in-widget entry keeps tracking config one click away) and
    -- force a refresh.
    local actionRow = RSUI:HorizontalBox({ id = "v3_buff_display_widget_actions", parent = content, gap = 4, slot = { size = "fixed", height = 26, hAlign = "fill" } })
    local settingsButton = RSUI:Button({ id = "v3_buff_display_widget_settings", parent = actionRow, text = "设置", compact = true, slot = { size = "fixed", width = 56 } })
    local refreshButton = RSUI:Button({ id = "v3_buff_display_widget_refresh", parent = actionRow, text = "刷新", compact = true, slot = { size = "fixed", width = 56 } })
    local actionHint = RSUI:Text({ id = "v3_buff_display_widget_action_hint", parent = actionRow, text = "点击行取消追踪", fontSize = 9, tone = "muted", overflow = "ellipsis", slot = { size = "fill", fill = 1 } })
    settingsButton.onClick = function()
        local shell = S.UIV3 and S.UIV3.shell or nil
        if shell ~= nil and type(shell.Navigate) == "function" then return shell:Navigate("combat.buff_display", { source = "buff_display_widget" }) end
        return true
    end
    refreshButton.onClick = function()
        if type(Feature.Commands) == "table" and type(Feature.Commands.Refresh) == "function" then Feature.Commands:Refresh("widget_manual") end
        return instance:Refresh()
    end
    -- The floating window is a tracking manager, not a live buff mirror: it
    -- lists every tracked id with its icon and lets the player untrack by
    -- clicking a row. Rows use onItemActivated (no selection) so clicking is
    -- the only interaction and cannot deselect into a dead state.
    instance.table = RSUI:TableView({ id = "v3_buff_display_widget_table", parent = content, items = {}, rowHeight = 24, headerHeight = 23, desiredRows = 10, overscan = 1, scrollbar = true, selectable = false, headerInteractive = false,
        onItemActivated = function(item, index, key, view, reason)
            if type(item) ~= "table" or item.id == nil then return true end
            local ok, err = Feature.Commands:SetTrackedId(tonumber(item.id), item.category == "debuff" and "debuff" or "buff", false)
            if ok == true then
                instance:Refresh()
            elseif S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.WarnRateLimited) == "function" then
                S.DiagnosticsManager:WarnRateLimited("buff_display_widget", "TRACKED_UNTrack_FAILED", 3000,
                    "取消追踪失败", { id = tonumber(item.id), error = tostring(err or "unknown") })
            end
            return ok, err
        end,
        columns = {
            { id = "icon", title = "", field = "iconPath", cellType = "icon", iconSize = 16, fallbackIcon = "ui/icon/icon_unknown_item.dds", size = "fixed", width = 24, minWidth = 22, sortable = false, resizable = false },
            { id = "name", title = "已追踪状态", field = "name", size = "fill", minWidth = 96, fill = 1 },
            { id = "type", title = "类型", field = "effectTypeText", size = "fixed", width = 50, minWidth = 44, sortable = false },
            { id = "status", title = "来源", field = "scopeText", size = "fixed", width = 46, minWidth = 40, sortable = false },
        }, slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" } })
    function instance:Refresh()
        local rows, revision = Feature:GetTrackedList()
        local tracked = type(rows) == "table" and rows or {}
        self.rows = tracked
        self.table:SetItems(tracked, revision)
        local liveCount, vanishedCount = 0, 0
        for _, row in ipairs(tracked) do
            if row.vanished == true then vanishedCount = vanishedCount + 1 else liveCount = liveCount + 1 end
        end
        if #tracked > 0 then
            self.table:SetViewState("ready")
            self.surface:SetStatus("已追踪 " .. tostring(liveCount) .. (vanishedCount > 0 and (" · 消失 " .. tostring(vanishedCount)) or ""), "accent")
        else
            self.table:SetViewState("empty", {
                title = "尚未追踪任何状态",
                detail = "点击" .. "状态显示" .. "页面的状态行即可追踪；此窗口用于管理已追踪列表（点击行取消追踪）。",
            })
            self.surface:SetStatus("追踪列表为空 · 请先在状态显示页添加追踪", "warn")
        end
        return true
    end
    function instance:Subscribe()
        if self.subscribed == true then return true end
        if S.Events ~= nil and type(S.Events.SubscribeInternal) == "function" then
            S.Events:SubscribeInternal("v3.buff_display.updated", self, function() if instance.visible then instance:Refresh() end end)
            -- Tracked-id mutations (row click, quick import) also publish the
            -- settings topic; refresh on it too so the tracking manager always
            -- mirrors the authoritative list.
            S.Events:SubscribeInternal("v3.buff_display.settings", self, function() if instance.visible then instance:Refresh() end end)
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
        local ok, showErr = xpcall(function()
            self:Subscribe()
            local acquireOk, acquireErr = Feature:AcquireConsumer("widget:buff_display")
            if acquireOk ~= true then error(acquireErr or "状态显示悬浮窗订阅失败") end
            acquired = true
            -- Fill the projection synchronously (the aura lane only runs on the
            -- next Scheduler frame) so live rows carry their name/icon and the
            -- tracking list is not all-"已消失" placeholders on first open.
            if type(Feature.Commands) == "table" and type(Feature.Commands.Refresh) == "function" then
                Feature.Commands:Refresh("widget_show")
            end
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
        local hidden, hideErr = self.surface:Show(false)
        if hidden ~= true then return false, hideErr end
        local released, releaseErr = true, nil
        if self.visible == true and S.FeatureRuntime:IsEnabled("combat_buff_display") == true then
            released, releaseErr = Feature:ReleaseConsumer("widget:buff_display")
        end
        self.visible = false; self:Unsubscribe()
        if type(context) ~= "table" or context.persist ~= false then Feature.Commands:SetWidgetVisible(false, "hide") end
        if released ~= true then return false, releaseErr end
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

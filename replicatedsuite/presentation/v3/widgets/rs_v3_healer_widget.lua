------------------------------------------------------------------------
-- Replicated Suite V3 - Healer Recommendation Floating Widget
--
-- Compact Presentation consumer. It never scans Unit/Team/Aura directly and
-- never owns a timer. Projection changes arrive through v3.healer.updated.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI = S.RSUI
local Host = S.UIV3 and S.UIV3.WidgetHost or nil
local Floating = RSUI and RSUI.FloatingSurface or nil
local Feature = S.Features and S.Features.Healer or nil
if type(RSUI) ~= "table" or type(Host) ~= "table" or type(Floating) ~= "table" or type(Feature) ~= "table" then return end

local FEATURE_ID = "combat_healer"
local WIDGET_ID = "combat.healer"
local OWNER = "v3:widget:healer"
local CONSUMER = "widget:combat_healer"

local function Policy()
    return {
        defaultWidth = 430, defaultHeight = 300, minWidth = 280, minHeight = 150,
        defaultOverallOpacity = 0.96, defaultBackgroundOpacity = 0.88,
        defaultTextOpacity = 1.0, defaultFontScale = 1.0,
    }
end

local function Persist(reason, delayMs)
    return Feature.Commands:MarkStoreDirty(delayMs or 300, "widget_" .. tostring(reason or "state"))
end

local function N(value, fallback) return tonumber(value) or tonumber(fallback) or 0 end
local function Tone(level)
    level = math.floor(N(level, 1))
    if level >= 4 then return "red" end
    if level == 3 then return "warn" end
    if level == 2 then return "accent" end
    return "green"
end

local function Columns()
    return {
        { id = "rank", title = "#", field = "rankText", size = "fixed", width = 28, minWidth = 26 },
        { id = "name", title = "成员", field = "name", size = "fill", fill = 1.25, minWidth = 88,
            getTone = function(row) return row and row.tone or "default" end },
        { id = "hp", title = "血量", field = "hpText", size = "fixed", width = 62, minWidth = 54,
            getTone = function(row) return row and row.tone or "default" end },
        { id = "distance", title = "距离", field = "distanceText", size = "fixed", width = 58, minWidth = 50 },
        { id = "score", title = "评分", field = "scoreText", size = "fixed", width = 52, minWidth = 46,
            getTone = function(row) return row and row.tone or "default" end },
        { id = "reason", title = "提示", field = "reasonText", size = "fill", fill = 1.2, minWidth = 90 },
    }
end

local function CreateWidget()
    local instance = { id = WIDGET_ID, visible = false, subscribed = false, consumerHeld = false, rows = {}, revision = -1 }
    local surface, err = Floating:Create({
        id = "v3_healer_widget", owner = OWNER, title = "治疗推荐", status = "--", footer = true,
        movable = true, resizable = true, minimizeMode = "compact", boundaryMode = "free", defaultPlacement = "right",
        statePolicy = Policy(), getState = function() return Feature:GetWidgetWindowState() end,
        setState = function(value, reason) return Feature.Commands:SetWidgetWindowState(value, reason) end, persist = Persist,
        onClosed = function(_, reason)
            return Host:NotifyWindowClosed(WIDGET_ID, { persist = false, source = tostring(reason or "widget_close") })
        end,
    })
    if surface == nil then return nil, err or "治疗推荐悬浮窗创建失败" end
    instance.surface, instance.shell, instance.window = surface, surface.shell, surface.window
    instance.root, instance.windowController = surface.shell.root, surface.windowController

    local stack = RSUI:VerticalBox({ id = "v3_healer_widget_stack", parent = surface:GetContentRoot(), gap = 4 })
    instance.summary = RSUI:Text({ id = "v3_healer_widget_summary", parent = stack, text = "等待治疗推荐", fontSize = 9, tone = "strong",
        overflow = "ellipsis", slot = { size = "fixed", height = 20, hAlign = "fill" } })
    instance.table = RSUI:TableView({
        id = "v3_healer_widget_table", parent = stack, items = {}, rowHeight = 23, headerHeight = 22, desiredRows = 8,
        scrollbar = true, selectable = false, columnResize = true, headerInteractive = false, columns = Columns(),
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })
    instance.unavailable = RSUI:Text({ id = "v3_healer_widget_unavailable", parent = stack,
        text = "暂不可评分：0", fontSize = 8, tone = "muted", overflow = "ellipsis", slot = { size = "fixed", height = 18 } })

    function instance:Refresh()
        local projection = Feature:GetProjection(20)
        local health = Feature:GetHealth()
        local runtime = type(health) == "table" and health.runtime or {}
        local count = 0
        for _, item in ipairs(type(projection.recommendations) == "table" and projection.recommendations or {}) do
            if count >= 12 then break end
            count = count + 1
            local row = self.rows[count] or {}
            row.rankText = tostring(item.rank or count)
            row.name = tostring(item.name or "未知成员")
            row.hpText = item.healthPercent ~= nil and string.format("%.0f%%", N(item.healthPercent)) or "--"
            row.distanceText = item.distance ~= nil and string.format("%.0fm", N(item.distance)) or "--"
            row.scoreText = item.finalScore ~= nil and string.format("%.0f", N(item.finalScore)) or "--"
            row.reasonText = tostring(item.colorReason or item.reason or "--")
            row.tone = Tone(item.level)
            self.rows[count] = row
        end
        for index = count + 1, #self.rows do self.rows[index] = nil end
        self.table:SetItems(self.rows, "healer_widget:" .. tostring(projection.revision or 0))
        if runtime.running ~= true then
            self.table:SetViewState("loading", { title = "治疗 Runtime 正在准备", detail = "等待团队与状态观察就绪。" })
        elseif count <= 0 then
            self.table:SetViewState("empty", { title = "当前没有治疗候选", detail = "成员血量健康、超出距离或状态暂不可确认。" })
        else
            self.table:SetViewState("ready")
        end
        self.summary:SetText("推荐 " .. tostring(projection.recommendationCount or 0) .. " 人 · HealthGen " .. tostring(N(runtime.healthGeneration))
            .. " · 距离 " .. tostring(Feature:GetSettingsProjection().maxDistance or 27) .. "m")
        self.unavailable:SetText("暂不可评分：" .. tostring(projection.unavailableCount or 0) .. " · 未知状态不会按‘无 Buff’处理")
        self.unavailable:SetVisible((tonumber(projection.unavailableCount) or 0) > 0)
        self.surface:SetStatus(count > 0 and ("首选：" .. tostring(self.rows[1].name or "--") .. " " .. tostring(self.rows[1].hpText or "")) or "等待候选",
            count > 0 and self.rows[1].tone or "muted")
        self.revision = tonumber(projection.revision) or self.revision
        return true
    end

    function instance:Subscribe()
        if self.subscribed then return true end
        if S.Events == nil or type(S.Events.SubscribeInternal) ~= "function" then return false, "内部事件总线不可用" end
        local updated = S.Events:SubscribeInternal("v3.healer.updated", self, function() if instance.visible then instance:Refresh() end end)
        if updated ~= true then return false, "治疗推荐事件订阅失败" end
        local settings = S.Events:SubscribeInternal("v3.healer.settings", self, function() if instance.visible then instance:Refresh() end end)
        if settings ~= true then
            if type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
            return false, "治疗设置事件订阅失败"
        end
        self.subscribed = true
        return true
    end

    function instance:Unsubscribe()
        if not self.subscribed then return true end
        if S.Events ~= nil and type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
        self.subscribed = false
        return true
    end

    function instance:AcquireConsumer()
        if self.consumerHeld then return true end
        local ok, err = Feature:AcquireConsumer(CONSUMER)
        if ok ~= true then return false, err end
        self.consumerHeld = true
        return true
    end

    function instance:ReleaseConsumer()
        if not self.consumerHeld then return true end
        local ok, err = Feature:ReleaseConsumer(CONSUMER)
        -- FeatureRuntime:Disable clears the complete Demand snapshot before the
        -- lifecycle event asks Presentation to hide. In that valid ordering the
        -- token is already gone; cleanup must converge rather than report a
        -- false widget failure.
        local health = Feature:GetHealth() or {}
        if ok ~= true and (S.FeatureRuntime:IsEnabled(FEATURE_ID) ~= true or (tonumber(health.consumers) or 0) <= 0) then
            ok, err = true, nil
        end
        if ok ~= true then return false, err end
        self.consumerHeld = false
        return true
    end

    function instance:Show(context)
        if S.FeatureRuntime:IsEnabled(FEATURE_ID) ~= true then return false, "治疗辅助功能已关闭" end
        local acquired, acquireErr = self:AcquireConsumer()
        if acquired ~= true then return false, acquireErr end
        local subscribed, subscribeErr = self:Subscribe()
        if subscribed ~= true then self:ReleaseConsumer(); return false, subscribeErr end
        local refreshed, refreshErr = self:Refresh()
        if refreshed ~= true then self:Unsubscribe(); self:ReleaseConsumer(); return false, refreshErr end
        local shown, showErr = self.surface:Show(true)
        if shown ~= true then self:Unsubscribe(); self:ReleaseConsumer(); return false, showErr end
        self.visible = true
        return true
    end

    function instance:Hide(context)
        local shown, showErr = self.surface:Show(false)
        self.visible = false
        self:Unsubscribe()
        local released, releaseErr = self:ReleaseConsumer()
        if shown ~= true then return false, showErr end
        return released, releaseErr
    end

    function instance:OnWindowClosed(context)
        self.visible = false
        self:Unsubscribe()
        return self:ReleaseConsumer()
    end

    function instance:Open(context) return self:Show(context) end
    function instance:Close(context) return self:Hide(context) end
    function instance:ApplyLayout(fromMetricsChange) return self.surface:ApplyLayout(fromMetricsChange == true) end
    function instance:ApplyProjection() return self:Refresh() end
    function instance:SetSize(width, height, persist) return self.surface:SetSize(width, height, persist) end
    function instance:SetLocked(v, p) return self.surface:SetLocked(v, p) end
    function instance:IsLocked() return self.surface:IsLocked() end
    function instance:SetMinimized(v, p) return self.surface:SetMinimized(v, p) end
    function instance:IsMinimized() return self.surface:IsMinimized() end
    function instance:SetOverallOpacity(v, p) return self.surface:SetOverallOpacity(v, p) end
    function instance:GetOverallOpacity() return self.surface:GetOverallOpacity() end
    function instance:SetBackgroundOpacity(v, p) return self.surface:SetBackgroundOpacity(v, p) end
    function instance:GetBackgroundOpacity() return self.surface:GetBackgroundOpacity() end
    function instance:SetTextOpacity(v, p) return self.surface:SetTextOpacity(v, p) end
    function instance:GetTextOpacity() return self.surface:GetTextOpacity() end
    function instance:SetFontScale(v, p) return self.surface:SetFontScale(v, p) end
    function instance:GetFontScale() return self.surface:GetFontScale() end
    function instance:ResetLayout(p) return self.surface:ResetLayout(p) end
    return instance
end

local adapter = Floating:CreateStateAdapter({ statePolicy = Policy(), getState = function() return Feature:GetWidgetWindowState() end,
    setState = function(value, reason) return Feature.Commands:SetWidgetWindowState(value, reason) end, persist = Persist })
local ok, err = Host:Register(WIDGET_ID, {
    featureId = FEATURE_ID, create = CreateWidget, ensurePreferences = function() return Feature:EnsureStoreLoaded() end,
    lockable = true, minimizable = true, resettable = true,
    opacityAdjustable = true, backgroundOpacityAdjustable = true, textOpacityAdjustable = true, fontScaleAdjustable = true,
    getLocked = adapter.getLocked, setLocked = adapter.setLocked,
    getMinimized = adapter.getMinimized, setMinimized = adapter.setMinimized,
    getOverallOpacity = adapter.getOverallOpacity, setOverallOpacity = adapter.setOverallOpacity,
    getBackgroundOpacity = adapter.getBackgroundOpacity, setBackgroundOpacity = adapter.setBackgroundOpacity,
    getTextOpacity = adapter.getTextOpacity, setTextOpacity = adapter.setTextOpacity,
    getFontScale = adapter.getFontScale, setFontScale = adapter.setFontScale,
    resetLayout = adapter.resetLayout,
})
if ok ~= true then error(err) end

local bindOk, bindErr = Host:BindFeatureLifecycle(WIDGET_ID, {
    featureId = FEATURE_ID,
    enabled = function() return S.FeatureRuntime:IsEnabled(FEATURE_ID) == true end,
    preference = function() return true end,
    onShowFailed = function(reason)
        if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.WarningRateLimited) == "function" then
            S.DiagnosticsManager:WarningRateLimited("healer_v3", "HEALER_WIDGET_AUTO_SHOW_FAILED", 3000,
                "治疗推荐悬浮窗自动显示失败", { error = tostring(reason or "unknown") })
        end
    end,
})
if bindOk ~= true then error(bindErr) end

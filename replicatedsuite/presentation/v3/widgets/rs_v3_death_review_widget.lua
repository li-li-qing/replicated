------------------------------------------------------------------------
-- Replicated Suite V3 - Death Review Floating Widget
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI = S.RSUI
local Host = S.UIV3 and S.UIV3.WidgetHost or nil
local Floating = RSUI and RSUI.FloatingSurface or nil
local Feature = S.Features and S.Features.DeathReview or nil
if type(RSUI) ~= "table" or type(Host) ~= "table" or type(Floating) ~= "table" or type(Feature) ~= "table" then return end

local FEATURE_ID = "combat_death_review"
local WIDGET_ID = "combat.death_review"
local OWNER = "v3:widget:death_review"
local function Policy()
    return { defaultWidth = 470, defaultHeight = 330, minWidth = 1, minHeight = 1,
        defaultOverallOpacity = 0.96, defaultBackgroundOpacity = 1.0, defaultTextOpacity = 1.0 }
end
local function Persist(reason, delayMs) return Feature.Commands:MarkStoreDirty(delayMs or 300, "widget_" .. tostring(reason or "state")) end

local function CreateWidget()
    local instance = { id = WIDGET_ID, visible = false, subscribed = false, revision = -1 }
    local surface, err = Floating:Create({
        id = "v3_death_review_widget", owner = OWNER, title = "死亡回顾", status = "--", footer = true,
        movable = true, resizable = true, minimizeMode = "compact", boundaryMode = "free", defaultPlacement = "center",
        statePolicy = Policy(), getState = function() return Feature:GetWidgetWindowState() end,
        setState = function(value, reason) return Feature.Commands:SetWidgetWindowState(value, reason) end, persist = Persist,
        onClosed = function(_, reason)
            return Host:NotifyWindowClosed(WIDGET_ID, { persist = false, source = tostring(reason or "widget_close") })
        end,
    })
    if surface == nil then return nil, err or "死亡回顾悬浮窗创建失败" end
    instance.surface, instance.shell, instance.window = surface, surface.shell, surface.window
    instance.root, instance.windowController = surface.shell.root, surface.windowController

    local stack = RSUI:VerticalBox({ id = "v3_death_review_widget_stack", parent = surface:GetContentRoot(), gap = 5 })
    instance.summary = RSUI:Text({ id = "v3_death_review_widget_summary", parent = stack, text = "暂无死亡记录", fontSize = 10, tone = "strong", overflow = "wrap", maxLines = 4, minHeight = 42, slot = { size = "auto", minHeight = 42, hAlign = "fill" } })
    instance.timeline = RSUI:TableView({
        id = "v3_death_review_widget_timeline", parent = stack, items = {}, rowHeight = 25, headerHeight = 23, desiredRows = 7,
        scrollbar = true, selectable = false, columnResize = true,
        columns = {
            { id = "time", title = "时间", field = "timeText", size = "fixed", width = 46, minWidth = 38 },
            { id = "source", title = "来源", field = "source", size = "fill", minWidth = 74, fill = 0.8 },
            { id = "ability", title = "技能", field = "ability", size = "fill", minWidth = 88, fill = 1.1 },
            { id = "amount", title = "伤害", field = "amount", size = "fixed", width = 58, minWidth = 48, getTone = function() return "red" end },
        },
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })
    instance.debuffs = RSUI:Text({ id = "v3_death_review_widget_debuffs", parent = stack, text = "死亡时 Debuff：--", fontSize = 9, tone = "muted", overflow = "ellipsis", slot = { size = "fixed", height = 20 } })

    function instance:Refresh()
        local projection = Feature:GetProjection({ historyLimit = 1, timelineLimit = 12 })
        local rows, record = projection.timelineRows or {}, projection.record
        self.timeline:SetItems(rows, record and record.serial or 0)
        if record == nil then
            self.summary:SetText("最近死亡记录：--")
            -- The floating widget already has a summary line + footer status.
            -- Keeping the empty-state overlay here duplicated copy in a narrow
            -- viewport and visually stacked two status messages on top of each
            -- other. Show an empty table body instead.
            self.timeline:SetViewState("ready")
            self.debuffs:SetText("死亡时 Debuff：--")
            self.surface:SetStatus("等待记录", "muted")
            return true
        end
        local lethal = type(record.lethal) == "table" and record.lethal or {}
        self.summary:SetText("" .. tostring(record.clock or "--:--:--") .. " · 窗口 " .. string.format("%.1fs", (tonumber(record.windowMs) or 0) / 1000)
            .. " · 总伤害 " .. tostring(record.totalDamage or 0) .. "\n致命：" .. tostring(lethal.source or "--") .. " · " .. tostring(lethal.ability or "--") .. " · " .. tostring(lethal.amount or 0))
        self.timeline:SetViewState(#rows > 0 and "ready" or "empty", #rows > 0 and nil or { title = "没有可用伤害行", detail = "死亡通知已记录，但当前窗口内没有满足最低伤害过滤的受伤事件。" })
        local names = {}
        for _, row in ipairs(record.debuffs or {}) do names[#names + 1] = tostring(row.name or "未知") .. ((tonumber(row.stack) or 0) > 1 and ("×" .. tostring(row.stack)) or "") end
        self.debuffs:SetText("死亡时 Debuff：" .. (#names > 0 and table.concat(names, " · ") or "无 / 未采集"))
        self.surface:SetStatus("记录 #" .. tostring(record.serial or 0), "red")
        return true
    end

    function instance:Subscribe()
        if self.subscribed then return true end
        if S.Events and type(S.Events.SubscribeInternal) == "function" then
            S.Events:SubscribeInternal("v3.death_review.updated", self, function() if instance.visible then instance:Refresh() end end)
        end
        self.subscribed = true
        return true
    end
    function instance:Unsubscribe()
        if not self.subscribed then return true end
        if S.Events and type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
        self.subscribed = false
        return true
    end
    function instance:Show(context)
        if S.FeatureRuntime:IsEnabled(FEATURE_ID) ~= true then return false, "死亡回顾功能已关闭" end
        local subscribed, subscribeErr = self:Subscribe()
        if subscribed ~= true then return false, subscribeErr end
        local refreshed, refreshErr = self:Refresh()
        if refreshed ~= true then self:Unsubscribe(); return false, refreshErr end
        local shown, showErr = self.surface:Show(true)
        if shown ~= true then self:Unsubscribe(); self.visible = false; return false, showErr end
        self.visible = true
        return true
    end
    function instance:Hide(context)
        local hidden, hideErr = self.surface:Show(false)
        if hidden ~= true then return false, hideErr end
        self.visible = false; self:Unsubscribe()
        return true
    end
    function instance:OnWindowClosed(context)
        self.visible = false
        self:Unsubscribe()
        return true
    end
    function instance:Open(context) return self:Show(context) end
    function instance:Close(context) return self:Hide(context) end
    -- Shared responsive/react paths. Without ApplyLayout the floating window
    -- would keep its old geometry after a resolution change.
    function instance:ApplyLayout(fromMetricsChange) return self.surface:ApplyLayout(fromMetricsChange == true) end
    function instance:ApplyProjection() return self:Refresh() end
    function instance:SetSize(width, height, persist) return self.surface:SetSize(width, height, persist) end
    function instance:SetLocked(v,p) return self.surface:SetLocked(v,p) end
    function instance:IsLocked() return self.surface:IsLocked() end
    function instance:SetMinimized(v,p) return self.surface:SetMinimized(v,p) end
    function instance:IsMinimized() return self.surface:IsMinimized() end
    function instance:SetOverallOpacity(v,p) return self.surface:SetOverallOpacity(v,p) end
    function instance:GetOverallOpacity() return self.surface:GetOverallOpacity() end
    function instance:SetBackgroundOpacity(v,p) return self.surface:SetBackgroundOpacity(v,p) end
    function instance:GetBackgroundOpacity() return self.surface:GetBackgroundOpacity() end
    function instance:SetTextOpacity(v,p) return self.surface:SetTextOpacity(v,p) end
    function instance:GetTextOpacity() return self.surface:GetTextOpacity() end
    function instance:SetFontScale(v,p) return self.surface:SetFontScale(v,p) end
    function instance:GetFontScale() return self.surface:GetFontScale() end
    function instance:ResetLayout(p) return self.surface:ResetLayout(p) end
    return instance
end

local adapter = Floating:CreateStateAdapter({ statePolicy = Policy(), getState = function() return Feature:GetWidgetWindowState() end,
    setState = function(value, reason) return Feature.Commands:SetWidgetWindowState(value, reason) end, persist = Persist })
local ok, err = Host:Register(WIDGET_ID, {
    featureId = FEATURE_ID, create = CreateWidget, ensurePreferences = function() return Feature:EnsureStoreLoaded() end,
    lockable = true, minimizable = true, resettable = true, opacityAdjustable = true, backgroundOpacityAdjustable = true, textOpacityAdjustable = true, fontScaleAdjustable = true,
    getLocked = adapter.getLocked, setLocked = adapter.setLocked, getMinimized = adapter.getMinimized, setMinimized = adapter.setMinimized,
    getOverallOpacity = adapter.getOverallOpacity, setOverallOpacity = adapter.setOverallOpacity,
    getBackgroundOpacity = adapter.getBackgroundOpacity, setBackgroundOpacity = adapter.setBackgroundOpacity,
    getTextOpacity = adapter.getTextOpacity, setTextOpacity = adapter.setTextOpacity,
    getFontScale = adapter.getFontScale, setFontScale = adapter.setFontScale, resetLayout = adapter.resetLayout,
})
if ok ~= true then error(err) end

-- Presentation owns automatic visibility reactions. Domain code publishes
-- lifecycle/death facts only and never touches WidgetHost from combat callbacks.
local AutoPresenter = { id = "v3:death_review:auto_presenter" }
if S.Events and type(S.Events.SubscribeInternal) == "function" then
    S.Events:SubscribeInternal("v3.death_review.updated", AutoPresenter, function(_, reason)
        if tostring(reason or "") ~= "death" or S.FeatureRuntime:IsEnabled(FEATURE_ID) ~= true or Feature:GetSettingsProjection().autoShow ~= true then return end
        local okShow, showErr = Host:SetVisible(WIDGET_ID, true, { source = "death_auto", persist = false })
        if okShow ~= true and S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.WarningRateLimited) == "function" then
            S.DiagnosticsManager:WarningRateLimited("death_review_v3", "DEATH_REVIEW_AUTO_SHOW_FAILED", 3000,
                "死亡回顾自动窗口显示失败", { error = tostring(showErr) })
        end
    end)
    S.Events:SubscribeInternal("v3.death_review.lifecycle", AutoPresenter, function(_, state, reason)
        if tostring(state or "") ~= "disabled" then return end
        Host:SetVisible(WIDGET_ID, false, { persist = false, source = tostring(reason or "feature_disable") })
    end)
end

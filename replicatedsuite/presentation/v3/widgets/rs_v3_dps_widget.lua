------------------------------------------------------------------------
-- Replicated Suite V3 - DPS Floating Widget
--
-- Presentation-only live meter. Statistics remain owned by the DPS Feature.
-- Floating geometry/opacity/minimize state is persisted through the DPS store.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI = S.RSUI
local Host = S.UIV3 and S.UIV3.WidgetHost or nil
local Floating = RSUI and RSUI.FloatingSurface or nil
local Feature = S.Features and S.Features.DPS or nil
if type(RSUI) ~= "table" or type(Host) ~= "table" or type(Floating) ~= "table" or type(Feature) ~= "table" then return end

local FEATURE_ID, STORE_ID = "combat_stats", "v3.dps"
local WIDGET_ID = "combat.dps"
local OWNER = "v3:widget:dps"

local function N(value) return math.max(0, math.floor((tonumber(value) or 0) + 0.5)) end
local function CompactNumber(value)
    local n = tonumber(value) or 0
    local abs = math.abs(n)
    if abs < 1000 then return tostring(math.floor(n + 0.5)) end
    if abs >= 1000000000 then return string.format(abs >= 100000000000 and "%.0fB" or "%.1fB", n / 1000000000) end
    if abs >= 1000000 then return string.format(abs >= 100000000 and "%.0fM" or "%.1fM", n / 1000000) end
    return string.format(abs >= 100000 and "%.0fK" or "%.1fK", n / 1000)
end
local function Policy()
    return {
        defaultWidth = 560, defaultHeight = 410, minWidth = 430, minHeight = 250,
        defaultOverallOpacity = 0.96, defaultBackgroundOpacity = 1.0, defaultTextOpacity = 1.0,
        defaultFontScale = 1.0, minFontScale = 0.80, maxFontScale = 1.25,
    }
end
local function Persist(reason, delayMs) return Feature.Commands:MarkStoreDirty(delayMs or 300, "widget_" .. tostring(reason or "state")) end

local function CreateWidget()
    local instance = { id = WIDGET_ID, visible = false, subscribed = false, revision = -1 }
    local surface, err = Floating:Create({
        id = "v3_dps_widget", owner = OWNER, title = "伤害统计", status = "--", footer = true,
        movable = true, resizable = true, minimizeMode = "compact", boundaryMode = "free", defaultPlacement = "right",
        statePolicy = Policy(), getState = function() return Feature:GetWidgetWindowState() end,
        setState = function(value, reason) return Feature.Commands:SetWidgetWindowState(value, reason) end, persist = Persist,
        onClosed = function(_, reason)
            return Host:NotifyWindowClosed(WIDGET_ID, { persist = false, source = tostring(reason or "widget_close") })
        end,
    })
    if surface == nil then return nil, err or "DPS 悬浮窗创建失败" end
    instance.surface, instance.shell, instance.window = surface, surface.shell, surface.window
    instance.root, instance.windowController = surface.shell.root, surface.windowController

    local stack = RSUI:VerticalBox({ id = "v3_dps_widget_stack", parent = surface:GetContentRoot(), gap = 5 })

    -- HUD quick filters share the same Feature settings authority as the full
    -- page. There is no widget-only shadow state: switching here immediately
    -- updates the page, persists through the DPS store and only changes the
    -- projection being displayed (statistics continue accumulating in every
    -- PVE/PVP + relation bucket).
    instance.quickBar = RSUI:HorizontalBox({ id = "v3_dps_widget_quickbar", parent = stack, gap = 6,
        slot = { size = "fixed", height = 26, hAlign = "fill" } })
    instance.modeSelector = RSUI:SegmentedSelector({
        id = "v3_dps_widget_mode", parent = instance.quickBar,
        items = {
            { value = "PVE", text = "PVE", width = 42 },
            { value = "PVP", text = "PVP", width = 42 },
        },
        get = function() return Feature:GetSettingsProjection().mode or "PVE" end,
        set = function(v) return Feature.Commands:ApplySettingFromBinding("mode", v) end,
        storeId = STORE_ID, persistDelayMs = 300, persistReason = "dps_widget_mode",
        height = 24, fontSize = 9, gap = 2,
        slot = { size = "auto", hAlign = "left", vAlign = "fill" },
    })
    instance.sideSelector = RSUI:SegmentedSelector({
        id = "v3_dps_widget_side", parent = instance.quickBar,
        items = {
            { value = "friendly", text = "友方", width = 46 },
            { value = "enemy", text = "敌方", width = 46 },
        },
        get = function() return Feature:GetSettingsProjection().side or "friendly" end,
        set = function(v) return Feature.Commands:ApplySettingFromBinding("side", v) end,
        storeId = STORE_ID, persistDelayMs = 300, persistReason = "dps_widget_side",
        height = 24, fontSize = 9, gap = 2,
        slot = { size = "auto", hAlign = "left", vAlign = "fill" },
    })
    instance.metricSelector = RSUI:SegmentedSelector({
        id = "v3_dps_widget_metric", parent = instance.quickBar,
        items = {
            { value = "damage", text = "伤害", width = 44 },
            { value = "taken", text = "承伤", width = 44 },
            { value = "heal", text = "治疗", width = 44 },
        },
        get = function() return Feature:GetSettingsProjection().metric or "damage" end,
        set = function(v) return Feature.Commands:ApplySettingFromBinding("metric", v) end,
        storeId = STORE_ID, persistDelayMs = 300, persistReason = "dps_widget_metric",
        height = 24, fontSize = 9, gap = 2,
        slot = { size = "auto", hAlign = "left", vAlign = "fill" },
    })

    -- Window appearance is owned by the shared FloatingSurface / WindowShell
    -- title chrome. Do not build a second DPS-specific appearance editor here:
    -- duplicate visual authorities waste native widgets and make failed builds
    -- unrecoverable within the same Generation because native ids are retained.

    instance.summary = RSUI:Text({ id = "v3_dps_widget_summary", parent = stack, text = "尚未开始统计", fontSize = 10,
        tone = "strong", overflow = "wrap", maxLines = 3, minHeight = 28, slot = { size = "auto", minHeight = 28, hAlign = "fill" } })
    instance.table = RSUI:TableView({
        id = "v3_dps_widget_table", parent = stack, items = {}, rowHeight = 22, headerHeight = 22, desiredRows = 12,
        scrollbar = true, selectable = false, columnResize = true,
        columns = {
            { id = "rank", title = "#", field = "rank", size = "fixed", width = 30, minWidth = 26,
                getTone = function(row) return row.self == true and "accent" or "default" end },
            { id = "name", title = "单位", field = "name", size = "fill", minWidth = 100, fill = 1 },
            { id = "damage", title = "伤害", field = "damage", size = "fixed", width = 78, minWidth = 62, format = CompactNumber,
                getTone = function() return "red" end },
            { id = "dps", title = "DPS", field = "dps", size = "fixed", width = 62, minWidth = 50, format = CompactNumber },
            { id = "taken", title = "承伤", field = "taken", size = "fixed", width = 76, minWidth = 60, format = CompactNumber },
            { id = "heal", title = "治疗", field = "heal", size = "fixed", width = 76, minWidth = 60, format = CompactNumber,
                getTone = function() return "green" end },
        },
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })
    instance.detail = RSUI:Text({ id = "v3_dps_widget_detail", parent = stack, text = "--", fontSize = 9,
        tone = "muted", overflow = "wrap", maxLines = 4, minHeight = 34, visible = false,
        slot = { size = "auto", minHeight = 34, hAlign = "fill" } })

    function instance:Refresh()
        local settings = Feature:GetSettingsProjection()
        local projection = Feature:GetProjection({ mode = settings.mode, side = settings.side, metric = settings.metric, displayRows = settings.displayRows })
        local p = projection.projection or {}
        local rows = type(p.rows) == "table" and p.rows or {}
        self.table:SetItems(rows, "dps_widget:" .. tostring(p.revision or 0) .. ":" .. tostring(p.mode or "") .. ":" .. tostring(p.side or "") .. ":" .. tostring(p.metric or ""))
        local totals = type(p.totals) == "table" and p.totals or {}
        local coverage = tostring(projection.coverageState or "INACTIVE")
        local h = projection.health or {}
        local unresolvedTotals = type(p.unresolved) == "table" and type(p.unresolved.totals) == "table" and p.unresolved.totals or {}
        local sideUnknown = type(p.sides) == "table" and type(p.sides.unknown) == "table" and p.sides.unknown or {}
        local sideUnknownTotals = type(sideUnknown.totals) == "table" and sideUnknown.totals or {}
        local truncatedNote = p.truncated == true and (" · 前 " .. tostring(#rows) .. "/" .. tostring(p.totalRows or #rows)) or ""
        -- Render selectors on every projection refresh so changes made on the
        -- full DPS page are reflected in the floating window immediately.
        self.modeSelector:Render()
        self.sideSelector:Render()
        self.metricSelector:Render()
        self.summary:SetText("伤 " .. CompactNumber(totals.damage)
            .. " · 承 " .. CompactNumber(totals.taken)
            .. " · 治 " .. CompactNumber(totals.heal)
            .. " · 单位 " .. tostring(N(totals.actorCount)) .. truncatedNote)
        local pendingAmount = N(unresolvedTotals.damage) + N(unresolvedTotals.taken) + N(unresolvedTotals.heal)
            + N(sideUnknownTotals.damage) + N(sideUnknownTotals.taken) + N(sideUnknownTotals.heal)
        local hasPending = N(h.pendingRows) > 0 or N(h.pendingEvicted) > 0 or pendingAmount > 0
        if hasPending then
            self.detail:SetVisible(true)
            self.detail:SetText("待确认：重放 " .. tostring(N(h.pendingRows))
                .. " · 淘汰 " .. tostring(N(h.pendingEvicted))
                .. " · 模式未定[伤 " .. CompactNumber(unresolvedTotals.damage)
                .. "/承 " .. CompactNumber(unresolvedTotals.taken)
                .. "/治 " .. CompactNumber(unresolvedTotals.heal)
                .. "] · 阵营未定[伤 " .. CompactNumber(sideUnknownTotals.damage)
                .. "/承 " .. CompactNumber(sideUnknownTotals.taken)
                .. "/治 " .. CompactNumber(sideUnknownTotals.heal) .. "]")
            self.detail:SetTone("warn")
        else
            -- Technical replay diagnostics should not permanently consume HUD
            -- height. Reveal them only when the player actually has unresolved
            -- data that may affect the ranking.
            self.detail:SetVisible(false)
        end
        if coverage ~= "FULL" then
            self.surface:SetStatus("覆盖不完整：" .. coverage, "warn")
        else
            self.surface:SetStatus("实时统计", "default")
        end
        return true
    end

    function instance:Subscribe()
        if self.subscribed then return true end
        if S.Events and type(S.Events.SubscribeInternal) == "function" then
            S.Events:SubscribeInternal("v3.dps.updated", self, function() if instance.visible then instance:Refresh() end end)
            S.Events:SubscribeInternal("v3.dps.settings", self, function() if instance.visible then instance:Refresh() end end)
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
        if S.FeatureRuntime:IsEnabled(FEATURE_ID) ~= true then return false, "DPS 功能已关闭" end
        local okSub, subErr = self:Subscribe()
        if okSub ~= true then return false, subErr end
        local okRefresh, refreshErr = self:Refresh()
        if okRefresh ~= true then self:Unsubscribe(); return false, refreshErr end
        local okShow, showErr = self.surface:Show(true)
        if okShow ~= true then self:Unsubscribe(); self.visible = false; return false, showErr end
        self.visible = true
        if type(context) ~= "table" or context.persist ~= false then
            Feature.Commands:SetWidgetVisible(true, "show")
        end
        return true
    end

    function instance:Hide(context)
        local okShow, showErr = self.surface:Show(false)
        if okShow ~= true then return false, showErr end
        self.visible = false
        self:Unsubscribe()
        if type(context) ~= "table" or context.persist ~= false then
            Feature.Commands:SetWidgetVisible(false, "hide")
        end
        return true
    end

    function instance:OnWindowClosed(context)
        self.visible = false
        self:Unsubscribe()
        if type(context) ~= "table" or context.persist ~= false then
            Feature.Commands:SetWidgetVisible(false, "native_close")
        end
        return true
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
    lockable = true, minimizable = true, resettable = true, opacityAdjustable = true, backgroundOpacityAdjustable = true, textOpacityAdjustable = true, fontScaleAdjustable = true,
    getLocked = adapter.getLocked, setLocked = adapter.setLocked, getMinimized = adapter.getMinimized, setMinimized = adapter.setMinimized,
    getOverallOpacity = adapter.getOverallOpacity, setOverallOpacity = adapter.setOverallOpacity,
    getBackgroundOpacity = adapter.getBackgroundOpacity, setBackgroundOpacity = adapter.setBackgroundOpacity,
    getTextOpacity = adapter.getTextOpacity, setTextOpacity = adapter.setTextOpacity,
    getFontScale = adapter.getFontScale, setFontScale = adapter.setFontScale, resetLayout = adapter.resetLayout,
})
if ok ~= true then error(err) end

local bindOk, bindErr = Host:BindFeatureLifecycle(WIDGET_ID, {
    featureId = FEATURE_ID,
    enabled = function() return S.FeatureRuntime:IsEnabled(FEATURE_ID) == true end,
    -- Feature enablement and Presentation visibility are independent.  Only a
    -- user-persisted visible preference may reopen the meter on reload.
    preference = function() return Feature:GetWidgetVisible() == true end,
    onShowFailed = function(reason)
        Feature.Commands:SetWidgetVisible(false, "auto_show_failed")
        if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.WarningRateLimited) == "function" then
            S.DiagnosticsManager:WarningRateLimited("dps_v3", "DPS_WIDGET_AUTO_SHOW_FAILED", 3000,
                "DPS 悬浮窗自动显示失败", { error = tostring(reason or "unknown") })
        end
    end,
})
if bindOk ~= true then error(bindErr) end

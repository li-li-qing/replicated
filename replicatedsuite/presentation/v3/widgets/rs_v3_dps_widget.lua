-- Replicated Suite · 伤害统计悬浮组件
-- 作者：Replicated
-- QQ群：1104129461
-- 仅负责实时计量表现，统计归 DPS Feature；悬浮几何、透明度、最小化状态通过 DPS Store 持久化。
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
local DAMAGE_TEST_DISPLAY = "v3.dps.damage_test_display"

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
    -- 复制 Store 的几何 policy，不另设默认值，避免 Reload 时被两套规则重复规范化。
    return S.Utils.DeepCopy(Feature.WidgetWindowPolicy or {})
end
local function Persist(reason, delayMs) return Feature.Commands:MarkStoreDirty(delayMs or 300, "widget_" .. tostring(reason or "state")) end

local function TestNumber(value)
    local text = string.format("%.0f", value)
    local grouped = text:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
    return grouped
end

local function TestTime(ms, countdown)
    local tenths = countdown and math.ceil(ms / 100) or math.floor(ms / 100)
    if tenths <= 600 then return string.format("%.1f 秒", tenths / 10) end
    return string.format("%d:%02d.%d", math.floor(tenths / 600), math.floor(tenths / 10) % 60, tenths % 10)
end

local function CreateWidget()
    local instance = { id = WIDGET_ID, visible = false, subscribed = false, revision = -1, view = "ranking", testSeconds = 0 }
    local surface, err = Floating:Create({
        id = "v3_dps_widget", owner = OWNER, title = "伤害统计", status = "--", footer = true,
        movable = true, resizable = true, minimizeMode = "compact", boundaryMode = "free", defaultPlacement = "right",
        statePolicy = Policy(), getState = function() return Feature:GetWidgetWindowState() end,
        setState = function(value, reason) return Feature.Commands:SetWidgetWindowState(value, reason) end, persist = Persist,
        onStateChanged = function(surface, _, reason)
            if not instance.visible or instance.view ~= "test" then return end
            if reason ~= "minimized" and reason ~= "layout_reset" and reason ~= "size" then return end
            if instance.durationInput.open and surface:IsMinimized() then instance.durationInput:Close() end
            instance:RefreshDamageTest()
        end,
        onClosed = function(_, reason)
            -- 关闭是用户明确的 durable visibility 选择。过去 persist=false
            -- 只隐藏当前实例，Store 仍保留 widgetVisible=true，Reload/下次登录会再次弹出。
            return Host:NotifyWindowClosed(WIDGET_ID, { persist = true, source = tostring(reason or "widget_close") })
        end,
    })
    if surface == nil then return nil, err or "DPS 悬浮窗创建失败" end
    instance.surface, instance.shell, instance.window = surface, surface.shell, surface.window
    instance.root, instance.windowController = surface.shell.root, surface.windowController

    local root = RSUI:VerticalBox({ id = "v3_dps_widget_views_root", parent = surface:GetContentRoot(), gap = 5,
        slot = { hAlign = "fill", vAlign = "fill" } })
    local views = RSUI:HorizontalBox({ id = "v3_dps_widget_views", parent = root, slot = { size = "fixed", height = 26 } })
    instance.viewSelector = RSUI:SegmentedSelector({
        id = "v3_dps_widget_view", parent = views, itemWidth = 88, height = 26,
        items = { {value="ranking",text="排行"}, {value="test",text="伤害测试"} },
        get = function() return instance.view end,
        set = function(view) return instance:SetView(view) end,
    })
    instance.viewSwitcher = RSUI:WidgetSwitcher({ id = "v3_dps_widget_switcher", parent = root,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" } })
    local stack = RSUI:VerticalBox({ id = "v3_dps_widget_stack", parent = instance.viewSwitcher, gap = 5,
        slot = { hAlign = "fill", vAlign = "fill" } })

    -- HUD 快速筛选与完整页面共用 Feature 设置，不维护组件影子状态；切换立即更新页面、经 DPS Store 持久化，仅改变显示投影，统计仍累积全部 PVE/PVP 与关系桶。
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

    -- 窗口外观由共享 FloatingSurface/WindowShell 标题外框持有；
    -- 不能另建 DPS 专用外观编辑器，重复权威会浪费 Native 控件，且保留的原生 id 使同 Generation 的构建失败无法恢复。

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

    local test = RSUI:VerticalBox({ id = "v3_dps_widget_test", parent = instance.viewSwitcher, gap = 4,
        slot = { hAlign = "fill", vAlign = "center", padding = { left = 8, right = 8 } } })
    instance.testRate = RSUI:Text({ id = "v3_dps_widget_test_rate", parent = test, text = "—", fontSize = 25,
        tone = "strong", align = ALIGN_CENTER, overflow = "shrink", slot = { size = "fixed", height = 38, hAlign = "fill" } })
    RSUI:Text({ id = "v3_dps_widget_test_rate_label", parent = test, text = "平均 DPS", fontSize = 11,
        tone = "muted", align = ALIGN_CENTER, slot = { size = "fixed", height = 20, hAlign = "fill" } })
    local stats = RSUI:HorizontalBox({ id = "v3_dps_widget_test_stats", parent = test, gap = 8,
        slot = { size = "fixed", height = 30, hAlign = "fill" } })
    instance.testDamage = RSUI:Text({ id = "v3_dps_widget_test_damage", parent = stats, overflow = "shrink",
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" } })
    instance.testTime = RSUI:Text({ id = "v3_dps_widget_test_time", parent = stats, align = ALIGN_RIGHT,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" } })
    local actions = RSUI:HorizontalBox({ id = "v3_dps_widget_test_actions", parent = test, gap = 8,
        slot = { size = "fixed", height = 28, hAlign = "fill" } })
    local durations = { { value = 0, text = "自由计时" } }
    for seconds = 5, 60, 5 do durations[#durations + 1] = { value = seconds, text = seconds .. " 秒" } end
    instance.durationInput = RSUI:Dropdown({ id = "v3_dps_widget_test_duration", parent = actions, items = durations,
        maxVisible = 8, height = 28, slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
        get = function() return instance.testSeconds end,
        set = function(seconds)
            if Feature:GetDamageTest().active then return false end
            instance.testSeconds = seconds
            return true
        end,
    })
    instance.testAction = RSUI:Button({ id = "v3_dps_widget_test_action", parent = actions, text = "开始记录",
        slot = { size = "fixed", width = 112, vAlign = "fill" },
        onClick = function()
            local ok, err
            if Feature:GetDamageTest().active then ok, err = Feature.Commands:StopDamageTest()
            else ok, err = Feature.Commands:StartDamageTest(instance.testSeconds) end
            if ok ~= true then surface:SetStatus(err or "记录操作失败", "warn") end
            return ok, err
        end,
    })

    function instance:DrawDamageTest(round)
        local rate = round.status == "idle" and "—" or TestNumber(round.dps)
        local damage = "累计伤害 " .. TestNumber(round.damage)
        local time = round.remainingMs and "剩余 " .. TestTime(round.remainingMs, true)
            or "用时 " .. TestTime(round.elapsedMs)
        -- 读数槽位使用固定几何；恢复窗口时原位绘制最新值，避免等待上一视图的布局队列。
        if rate ~= self.lastTestRate then self.testRate:Render({text=rate}); self.lastTestRate = rate end
        if damage ~= self.lastTestDamage then self.testDamage:Render({text=damage}); self.lastTestDamage = damage end
        if time ~= self.lastTestTime then self.testTime:Render({text=time}); self.lastTestTime = time end
    end

    function instance:StopDamageTestDisplay()
        if self.testDisplayActive and S.Scheduler then S.Scheduler:RemoveTask(DAMAGE_TEST_DISPLAY) end
        self.testDisplayActive = false
    end

    function instance:RefreshDamageTest()
        if self.surface:IsMinimized() then self:StopDamageTestDisplay(); return true end
        local round = Feature:GetDamageTest()
        local running = round.status == "running"
        self.testWaiting = round.status == "waiting"
        self:DrawDamageTest(round)
        self.durationInput:SetEnabled(not round.active)
        self.testAction:SetEnabled(round.active or round.canStart)
        self.testAction:SetText(round.active and "停止记录" or "开始记录")
        if self.testWaiting then self.surface:SetStatus("等待首次伤害", "accent")
        elseif running then self.surface:SetStatus("记录中 · 本人输出", "accent")
        elseif round.reason == "tracking_disabled" and not round.canStart then self.surface:SetStatus("已结算 · 伤害追踪已关闭", "warn")
        elseif round.reason == "tracking_disabled" or round.reason == "feature_disabled" or round.reason == "timer_unavailable" then self.surface:SetStatus("记录中断 · 已结算", "warn")
        elseif not round.canStart then self.surface:SetStatus("请先开启追踪伤害", "warn")
        elseif round.status == "finished" then self.surface:SetStatus("已结算 · 本人输出", "default")
        else self.surface:SetStatus("本人输出", "default") end
        if not running or not self.visible then
            self:StopDamageTestDisplay()
        elseif not self.testDisplayActive and S.Scheduler then
            self.testDisplayActive = S.Scheduler:AddTask(DAMAGE_TEST_DISPLAY, 100, function()
                if self.visible and self.view == "test" and not self.surface:IsMinimized() then
                    self:DrawDamageTest(Feature:GetDamageTest())
                else self:StopDamageTestDisplay() end
                return true
            end, false, self, "P2", 1) == true
        end
        return true
    end

    function instance:SetView(view)
        if self.view == view then return true end
        if view == "ranking" then
            if self.durationInput.open then self.durationInput:Close() end
            self:StopDamageTestDisplay()
        end
        self.view = view
        self.viewSwitcher:SetActiveWidget(view == "test" and test or stack)
        return self:Refresh()
    end

    function instance:Refresh()
        if self.view == "test" then return self:RefreshDamageTest() end
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
        -- 每次投影刷新渲染选择器，使 DPS 完整页修改立即反映在悬浮窗口。
        self.modeSelector:Render()
        self.sideSelector:Render()
        self.metricSelector:Render()
        local summaryChanged = self.summary:SetText("伤 " .. CompactNumber(totals.damage)
            .. " · 承 " .. CompactNumber(totals.taken)
            .. " · 治 " .. CompactNumber(totals.heal)
            .. " · 单位 " .. tostring(N(totals.actorCount)) .. truncatedNote)
        local pendingAmount = N(unresolvedTotals.damage) + N(unresolvedTotals.taken) + N(unresolvedTotals.heal)
            + N(sideUnknownTotals.damage) + N(sideUnknownTotals.taken) + N(sideUnknownTotals.heal)
        local hasPending = N(h.pendingRows) > 0 or N(h.pendingEvicted) > 0 or pendingAmount > 0
        local detailWasShown = not self.detail:IsCollapsed()
        local canLayout = stack.width ~= nil and stack.height ~= nil and not self.surface:IsMinimized()
        local revealAfterLayout = hasPending and not detailWasShown and canLayout
        local detailChanged = false
        if hasPending then
            if not detailWasShown then
                -- 隐藏状态仍参与布局，先取得表格下方的坐标再亮出文字。
                self.detail:SetVisibility(revealAfterLayout and "hidden" or "visible")
            end
            detailChanged = self.detail:SetText("待确认：重放 " .. tostring(N(h.pendingRows))
                .. " · 淘汰 " .. tostring(N(h.pendingEvicted))
                .. " · 模式未定[伤 " .. CompactNumber(unresolvedTotals.damage)
                .. "/承 " .. CompactNumber(unresolvedTotals.taken)
                .. "/治 " .. CompactNumber(unresolvedTotals.heal)
                .. "] · 阵营未定[伤 " .. CompactNumber(sideUnknownTotals.damage)
                .. "/承 " .. CompactNumber(sideUnknownTotals.taken)
                .. "/治 " .. CompactNumber(sideUnknownTotals.heal) .. "]")
            self.detail:SetTone("warn")
        elseif detailWasShown then
            -- 技术回放诊断不应永久占用 HUD 高度；仅玩家有可能影响排行的未解决数据时显示。
            self.detail:SetVisible(false)
        end
        -- WindowShell 的根关闭了自动重排，状态变化只重排当前排行内容，窗口几何仍归外框管理。
        if canLayout and (summaryChanged or detailChanged or hasPending ~= detailWasShown) then
            stack:Layout(stack.x, stack.y, stack.width, stack.height)
        end
        if revealAfterLayout then self.detail:SetVisible(true) end
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
            S.Events:SubscribeInternal("v3.dps.updated", self, function()
                if not instance.visible then return end
                if instance.view == "ranking" then instance:Refresh()
                elseif instance.testWaiting and not instance.surface:IsMinimized() and Feature:GetDamageTest().status ~= "waiting" then
                    instance:RefreshDamageTest()
                end
            end)
            S.Events:SubscribeInternal("v3.dps.settings", self, function() if instance.visible then instance:Refresh() end end)
            S.Events:SubscribeInternal("v3.dps.damage_test", self, function()
                if instance.visible and instance.view == "test" then instance:RefreshDamageTest() end
            end)
        end
        self.subscribed = true
        return true
    end

    function instance:Unsubscribe()
        self:StopDamageTestDisplay()
        if self.durationInput.open then self.durationInput:Close() end
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
        if self.view == "test" then self:RefreshDamageTest() end
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
    -- Feature 启用与表现可见性独立；重载时仅用户持久化可见偏好可重新打开计量表。
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

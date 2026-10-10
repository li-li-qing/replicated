------------------------------------------------------------------------
-- Replicated Suite V3 - Death Review Page
------------------------------------------------------------------------
-- 维护（module-controls-diag-2）：总开关领取PageHost左上角的同一实例；原Feature/Consumer/保存回滚回调不变。
-- 只调整呈现归属，禁止在刷新中另造开关状态、重设Native父级或绑定第二个OnClick；局部选项开关保持原位。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI, D = S.RSUI, S.UIV3Design
local PageHost = S.UIV3 and S.UIV3.PageHost or nil
local Feature = S.Features and S.Features.DeathReview or nil
if type(RSUI) ~= "table" or type(D) ~= "table" or type(PageHost) ~= "table" or type(Feature) ~= "table" then return end

local STORE_ID = "v3.death_review"
local function Settings() return Feature:GetSettingsProjection() end
local CLEAR_CONFIRM_TASK = "v3_death_review_clear_confirm_expire"

-- 维护（F2 页面隔离，2026-09-12）：持久化 Toggle 在 Build 时即 PrepareRead，不能等到
-- OnActivated 才检查存档。失败分支必须早于所有编辑器/Commands/历史投影，否则一次业务
-- 校验失败会升级为 required_component_build_failed 并隔离整页。
-- Authority：Feature/Core 决定能否读写；此页只呈现故障，不以默认值替换、不调用恢复/清档，
-- 不注册事件、不取记录分片、不启用战斗/Aura消费者。正常控件构造错误仍交给 BuildScope。
-- 保护页在本次 Generation 保持只读；完整覆盖补丁后通过既有“重新加载文件”重新准备。
local function BuildProtectedPage(parent, route, reason)
    local makeRoot = D.ScrollablePageRoot or D.PageRoot
    local root, err = makeRoot(D, parent, "v3_page_death_review")
    if root == nil then return nil, err or "死亡回顾保护页创建失败" end
    root.route, root.persistenceUnavailable = route, true
    D:PageHeader(root, "v3_death_review_protected_header", "死亡回顾：配置已保护",
        "配置尚未通过读取校验；历史未清空，编辑、删除和记录开关暂不开放。")
    RSUI:Text({id="v3_death_review_protected_reason",parent=root,
        text="读取失败：" .. tostring(reason or "未知错误"),fontSize=10,tone="warn",overflow="wrap",maxLines=6,
        slot={size="auto",minHeight=64,hAlign="fill"}})
    -- 维护（module-controls-diag-2）：保护页仍有宿主诊断按钮；不依赖错误的UIV3:Navigate，也不启用受保护模块。
    RSUI:Text({id="v3_death_review_protected_hint",parent=root,fontSize=10,tone="muted",overflow="wrap",maxLines=5,
        text="请保留原存档，不要重置配置。短报告未附原档时，无需重复复制相同 Hash；使用随包 tools/rs_udf_evidence.html 离线采集完整 udf 文件夹。采集前退出游戏，先查看文件清单与隐私提示。",
        slot={size="auto",minHeight=60,hAlign="fill"}})
    function root:OnActivated() return true end -- 维护：不重读盘、不订阅、不隐藏写保护状态。
    function root:OnDeactivated() return true end -- 维护：此分支没有消费者/编辑框需要释放。
    return root
end

local function Build(parent, route)
    -- 维护：在任何持久化 Binding 创建之前准备；缺失/抛错也不允许编辑未读默认值。
    local called, loaded, loadErr = false, false, "死亡回顾读取入口不可用"
    if type(Feature.EnsureStoreLoaded)=="function" then
        called, loaded, loadErr = pcall(Feature.EnsureStoreLoaded,Feature)
    end
    if not called or loaded~=true then
        return BuildProtectedPage(parent,route,called and loadErr or loaded or loadErr)
    end
    local root, rootErr = D:PageRoot(parent, "v3_page_death_review")
    if root == nil then error("死亡回顾 PageRoot 创建失败：" .. tostring(rootErr or "unknown")) end
    root.route = route
    root.selectedSerial = nil
    root.rows = {}
    root.subscribed = false
    root.clearConfirmUntil = 0

    D:PageHeader(root, "v3_death_review_header", "死亡回顾", "独立低开销记录死亡前受伤时间线；只消费本地 scope=self 战斗事实，不依赖 DPS。")

    local clearHistory
    local function NowMs() return math.max(0, tonumber(S.NowMs and S.NowMs()) or 0) end
    local function RefreshClearButton()
        local confirming = (tonumber(root.clearConfirmUntil) or 0) >= NowMs()
        if clearHistory ~= nil then clearHistory:SetText(confirming and "再次点击确认" or "清空历史") end
        return confirming
    end

    local top = RSUI:HorizontalBox({ id = "v3_death_review_top", parent = root, gap = 8, slot = { size = "fixed", height = 34, hAlign = "fill" } })
    local featureToggle = D:ModuleToggleButton({ id = "v3_death_review_enable", parent = top, text = "启用死亡回顾", compact = true, slot = { size = "fixed", width = 118 } })
    -- FloatingSurface owns `v3_death_review_widget`; keep the page action on a
    -- distinct logical identity so auto-show and page creation can coexist.
    local showWidget = RSUI:Button({ id = "v3_death_review_widget_toggle", parent = top, text = "查看最近记录", compact = true, slot = { size = "fixed", width = 110 } })
    local layoutButton = RSUI:Button({ id = "v3_death_review_layout_toggle", parent = top, text = "弹窗布局", compact = true, slot = { size = "fixed", width = 88 } })
    local deleteSelected = RSUI:Button({ id = "v3_death_review_delete_selected", parent = top, text = "删除选中", compact = true, enabled = false, slot = { size = "fixed", width = 88 } })
    clearHistory = RSUI:Button({ id = "v3_death_review_clear", parent = top, text = "清空历史", compact = true, slot = { size = "fixed", width = 98 } })
    local settingsButton = RSUI:Button({ id = "v3_death_review_settings_toggle", parent = top, text = "展开设置", compact = true, slot = { size = "fixed", width = 88 } })
    local healthText = RSUI:Text({ id = "v3_death_review_health", parent = top, text = "--", fontSize = 9, tone = "muted", overflow = "ellipsis", slot = { size = "fill", fill = 1 } })

    -- 中文维护：布局入口复用死亡自动弹出的同一个 FloatingSurface；不创建第二份预览窗口或布局配置。
    local widgetHost = S.UIV3.WidgetHost
    local widgetId = "combat.death_review"
    local layoutControls = RSUI:VerticalBox({ id = "v3_death_review_layout_controls", parent = root, gap = 4, slot = { size = "auto", hAlign = "fill" } })
    local layoutActions = RSUI:HorizontalBox({ id = "v3_death_review_layout_actions", parent = layoutControls, gap = 6, slot = { size = "fixed", height = 30, hAlign = "fill" } })
    local lockWidget = RSUI:Button({ id = "v3_death_review_widget_lock", parent = layoutActions, text = "锁定位置", compact = true, slot = { size = "fixed", width = 98 } })
    local resetWidget = RSUI:Button({ id = "v3_death_review_widget_reset", parent = layoutActions, text = "恢复默认布局", compact = true, slot = { size = "fixed", width = 110 } })
    RSUI:Text({ id = "v3_death_review_layout_hint", parent = layoutControls,
        text = "拖动弹窗标题调整位置，拖动边缘或右下角调整大小，松开后自动保存。也可输入宽度和高度；下次死亡弹出时沿用。",
        fontSize = 10, tone = "muted", overflow = "wrap", maxLines = 3, slot = { size = "auto", minHeight = 30, hAlign = "fill" } })
    local sizeRow = RSUI:HorizontalBox({ id = "v3_death_review_widget_size", parent = layoutControls, gap = 8, slot = { size = "auto", hAlign = "fill" } })
    local function ResizeWidget(key, value)
        local instance = widgetHost:GetInstance(widgetId)
        if instance == nil or type(instance.SetSize) ~= "function" then return false, "请先打开弹窗布局" end
        local state = Feature:GetWidgetWindowState() or {}
        local width = key == "width" and value or state.width or 470
        local height = key == "height" and value or state.height or 330
        -- FloatingSurface 拥有原生几何校验、失败回滚及持久化；NumericSetting 不再创建另一条保存路径。
        return instance:SetSize(width, height, true)
    end
    local widgetWidth = D:NumericSetting(sizeRow, { id = "v3_death_review_widget_width", label = "弹窗宽度", min = 420, max = 1400, step = 10, integer = true,
        get = function() return (Feature:GetWidgetWindowState() or {}).width or 470 end,
        set = function(value) return ResizeWidget("width", value) end, slot = { size = "fill", fill = 1 } })
    local widgetHeight = D:NumericSetting(sizeRow, { id = "v3_death_review_widget_height", label = "弹窗高度", min = 300, max = 1000, step = 10, integer = true,
        get = function() return (Feature:GetWidgetWindowState() or {}).height or 330 end,
        set = function(value) return ResizeWidget("height", value) end, slot = { size = "fill", fill = 1 } })
    root.widgetLayoutVisible = false
    layoutControls:SetVisible(false)
    function root:RefreshWidgetLayout()
        local state = Feature:GetWidgetWindowState() or {}
        lockWidget:SetText(state.locked == true and "解锁位置" or "锁定位置")
        if self.widgetLayoutVisible then widgetWidth:Render(); widgetHeight:Render() end
        return true
    end
    function root:SetWidgetLayoutVisible(visible)
        if visible == true then
            local shown, showErr = widgetHost:SetVisible(widgetId, true, { source = "death_review_layout", persist = false })
            if shown ~= true then return false, showErr end
            local restored, restoreErr = widgetHost:SetMinimized(widgetId, false, true)
            if restored ~= true then return false, restoreErr end
            local unlocked, unlockErr = widgetHost:SetLocked(widgetId, false, true)
            if unlocked ~= true then return false, unlockErr end
            local instance = widgetHost:GetInstance(widgetId)
            if instance and instance.windowController then instance.windowController:BringToFront() end
        end
        self.widgetLayoutVisible = visible == true
        layoutControls:SetVisible(self.widgetLayoutVisible)
        layoutButton:SetText(self.widgetLayoutVisible and "收起布局" or "弹窗布局")
        return self:RefreshWidgetLayout()
    end
    layoutButton.spec.onClick = function() return root:SetWidgetLayoutVisible(not root.widgetLayoutVisible) end
    lockWidget.spec.onClick = function()
        local locked = (Feature:GetWidgetWindowState() or {}).locked == true
        local ok, err = widgetHost:SetLocked(widgetId, not locked, true)
        root:RefreshWidgetLayout(); return ok, err
    end
    resetWidget.spec.onClick = function()
        local ok, err = widgetHost:ResetLayout(widgetId)
        root:RefreshWidgetLayout(); return ok, err
    end

    local settings = RSUI:VerticalBox({ id = "v3_death_review_settings", parent = root, gap = 4, slot = { size = "auto", hAlign = "fill" } })
    local settingsTop = RSUI:HorizontalBox({ id = "v3_death_review_settings_top", parent = settings, gap = 6, slot = { size = "auto", hAlign = "fill" } })
    local settingsBottom = RSUI:HorizontalBox({ id = "v3_death_review_settings_bottom", parent = settings, gap = 6, slot = { size = "auto", hAlign = "fill" } })
    local autoShow = RSUI:Toggle({
        id = "v3_death_review_auto", parent = settingsTop, onText = "死亡自动弹出：开", offText = "死亡自动弹出：关",
        get = function() return Settings().autoShow == true end, set = function(v) return Feature.Commands:ApplyAutoShow(v) end,
        storeId = STORE_ID, persistDelayMs = 300, persistReason = "death_review_auto_show", slot = { size = "fixed", width = 142 },
    })
    local showDebuffs = RSUI:Toggle({
        id = "v3_death_review_debuff", parent = settingsTop, onText = "记录状态：开", offText = "记录状态：关",
        get = function() return Settings().showDebuffs == true end, set = function(v) return Feature.Commands:ApplyShowDebuffs(v) end,
        storeId = STORE_ID, persistDelayMs = 300, persistReason = "death_review_debuff", slot = { size = "fixed", width = 132 },
    })
    local windowMs = D:NumericSetting(settingsTop, {
        id = "v3_death_review_window", label = "死亡前时间", hint = "记录死亡前多少秒的受伤事件。", min = 3, max = 20, step = 0.5, integer = false, unit = " 秒",
        get = function() return (tonumber(Settings().windowMs) or 10000) / 1000 end, set = function(v) return Feature.Commands:ApplyWindowMs((tonumber(v) or 10) * 1000) end,
        storeId = STORE_ID, persistDelayMs = 300, persistReason = "death_review_window", slot = { size = "fill", fill = 1 },
    })
    local minDamage = D:NumericSetting(settingsBottom, {
        id = "v3_death_review_min_damage", label = "最低伤害", hint = "低于该数值的单次伤害不进入死亡时间线。", min = 0, max = 5000, step = 50, integer = true,
        get = function() return Settings().minDamage end, set = function(v) return Feature.Commands:ApplyMinDamage(v) end,
        storeId = STORE_ID, persistDelayMs = 300, persistReason = "death_review_min_damage", slot = { size = "fill", fill = 1 },
    })
    local maxHistory = D:NumericSetting(settingsBottom, {
        id = "v3_death_review_max_history", label = "历史条数", hint = "最多保留多少次死亡；完整时间线使用独立分片保存。", min = 1, max = 30, step = 1, integer = true,
        get = function() return Settings().maxHistory end, set = function(v) return Feature.Commands:SetMaxHistory(v) end,
        slot = { size = "fill", fill = 1 },
    })

    root.settingsVisible = false
    settings:SetVisible(false)
    function root:SetSettingsVisible(visible)
        self.settingsVisible = visible == true
        settings:SetVisible(self.settingsVisible)
        settingsButton:SetText(self.settingsVisible and "收起设置" or "展开设置")
        return true
    end

    -- 顶部选择历史，内容区完整留给伤害与状态两列。
    local historyRow = RSUI:HorizontalBox({ id = "v3_death_review_history_row", parent = root, gap = 6,
        slot = { size = "fixed", height = 30, hAlign = "fill" } })
    RSUI:Text({ id = "v3_death_review_history_title", parent = historyRow, text = "历史记录", fontSize = 10,
        tone = "strong", slot = { size = "fixed", width = 62 } })
    local history = RSUI:Dropdown({ id = "v3_death_review_history", parent = historyRow, items = {}, maxVisible = 8,
        placeholder = "暂无死亡记录", get = function() return root.selectedSerial end,
        set = function(serial)
            root.selectedSerial = tonumber(serial)
            deleteSelected:SetEnabled(root.selectedSerial ~= nil)
            return root:RefreshDetail()
        end, slot = { size = "fill", fill = 1 } })
    local detail = S.UIV3.DeathReviewContent:Create(root, "v3_death_review")
    root.detail, root.historyPicker = detail, history
    function root:RefreshDetail()
        local projection = Feature:GetProjection({ serial = self.selectedSerial, historyLimit = 30, timelineLimit = 96 })
        return detail:Render(projection.timelineRows or {}, projection.record)
    end

    function root:Refresh()
        local projection = Feature:GetProjection({ serial = self.selectedSerial, historyLimit = 30, timelineLimit = 96 })
        local enabled = projection.enabled == true
        featureToggle:SetText(enabled and "关闭死亡回顾" or "启用死亡回顾")
        showWidget:SetEnabled(enabled)
        layoutButton:SetEnabled(enabled); lockWidget:SetEnabled(enabled); resetWidget:SetEnabled(enabled)
        self:RefreshWidgetLayout()
        local h = projection.health or {}
        healthText:SetText((enabled and "运行中" or "已关闭") .. " · 历史 " .. tostring(h.history or 0) .. " · 缓冲 " .. tostring(h.incoming or 0)
            .. " · Combat " .. tostring(h.busScope or "none") .. " · Aura " .. tostring(h.auraConsumer == true and "按需" or "关闭")
            .. (h.volatile == true and " · 1 条未保存" or ""))
        healthText:SetTone(enabled and "green" or "muted")
        local previousSerial = self.selectedSerial
        self.rows = projection.historyRows or {}
        local options, selected = {}, nil
        for _, row in ipairs(self.rows) do
            options[#options + 1] = { value = tonumber(row.serial), text = tostring(row.clock or "--:--:--")
                .. " · " .. tostring(row.lethalSource or "--") .. " · " .. tostring(row.lethalAbility or "--")
                .. " · 总伤害 " .. tostring(row.totalDamage or 0) }
            if tonumber(row.serial) == tonumber(previousSerial) then selected = tonumber(row.serial) end
        end
        self.selectedSerial = selected or (#self.rows > 0 and tonumber(self.rows[1].serial) or nil)
        history:SetItems(options)
        history:Render()
        self:RefreshDetail()
        deleteSelected:SetEnabled(self.selectedSerial ~= nil)
        autoShow:Render(); showDebuffs:Render(); windowMs:Render(); minDamage:Render(); maxHistory:Render()
        RefreshClearButton()
        return true
    end

    featureToggle.spec.onClick = function()
        local projection = Feature:GetProjection({ historyLimit = 1, timelineLimit = 1 })
        return S.ActionRunner:Run({ id = "death_review.toggle", button = featureToggle, busyText = "处理中…", notify = true,
            successText = function() return "死亡回顾状态已更新。" end,
            errorText = function(reason) return tostring(reason or "死亡回顾状态切换失败") end,
            execute = function() return Feature.Commands:SetEnabled(not (projection and projection.enabled == true), "death_review_page") end,
            onSuccess = function() root:Refresh() end,
        })
    end
    showWidget.spec.onClick = function() return S.UIV3.WidgetHost:SetVisible("combat.death_review", true, { source = "death_review_page", persist = false }) end
    deleteSelected.spec.onClick = function()
        local serial = tonumber(root.selectedSerial)
        if serial == nil then return false, "请先选择一条死亡记录" end
        return S.ActionRunner:Run({ id = "death_review.delete_selected", button = deleteSelected, busyText = "删除中…", notify = true,
            successText = "已删除选中的死亡回顾记录。", errorText = function(reason) return tostring(reason or "删除失败") end,
            execute = function() return Feature.Commands:DeleteRecord(serial) end,
            onSuccess = function() root.selectedSerial = nil; root:Refresh() end })
    end
    clearHistory.spec.onClick = function()
        local now = NowMs()
        if (tonumber(root.clearConfirmUntil) or 0) < now then
            root.clearConfirmUntil = now + 5000
            RefreshClearButton()
            if S.Scheduler ~= nil and type(S.Scheduler.AddOneShot) == "function" then
                S.Scheduler:AddOneShot(CLEAR_CONFIRM_TASK, 5050, function()
                    root.clearConfirmUntil = 0
                    RefreshClearButton()
                    return true
                end, root, "P4", 1)
            end
            if S.UIV3 and S.UIV3.ToastHost and type(S.UIV3.ToastHost.Notify) == "function" then
                S.UIV3.ToastHost:Notify({ id = "death_review_clear_confirm", title = "确认清空死亡回顾", detail = "5 秒内再次点击“再次点击确认”才会删除当前历史记录。", tone = "yellow", durationMs = 3000 })
            end
            return true
        end
        root.clearConfirmUntil = 0
        return S.ActionRunner:Run({ id = "death_review.clear", button = clearHistory, busyText = "清理中…", notify = true,
            successText = "死亡回顾历史已清空。", errorText = function(reason) return tostring(reason or "清空失败") end,
            execute = function() return Feature.Commands:ClearHistory() end, onSuccess = function() root.selectedSerial = nil; root:Refresh() end })
    end
    settingsButton.spec.onClick = function() return root:SetSettingsVisible(not root.settingsVisible) end

    function root:Subscribe()
        if self.subscribed then return true end
        if S.Events and type(S.Events.SubscribeInternal) == "function" then
            S.Events:SubscribeInternal("v3.death_review.updated", self, function() root:Refresh() end)
            S.Events:SubscribeInternal("v3.death_review.settings", self, function() root:Refresh() end)
            S.Events:SubscribeInternal("v3.death_review.layout", self, function() root:RefreshWidgetLayout() end)
        end
        self.subscribed = true
        return true
    end
    function root:Unsubscribe()
        if not self.subscribed then return true end
        if S.Events and type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
        self.subscribed = false
        return true
    end
    function root:OnActivated()
        local ok, err = Feature:EnsureStoreLoaded(); if ok ~= true then return false, err end
        self:Subscribe(); return self:Refresh()
    end
    function root:OnDeactivated()
        self:Unsubscribe()
        self.clearConfirmUntil = 0
        if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(CLEAR_CONFIRM_TASK) end
        RefreshClearButton()
        return true
    end
    return root
end

local ok, err = PageHost:RegisterFactory("combat.death_review", Build)
if ok ~= true then error(err) end

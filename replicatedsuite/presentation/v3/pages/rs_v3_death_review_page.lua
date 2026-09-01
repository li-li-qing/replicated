------------------------------------------------------------------------
-- Replicated Suite V3 - Death Review Page
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI, D = S.RSUI, S.UIV3Design
local PageHost = S.UIV3 and S.UIV3.PageHost or nil
local Feature = S.Features and S.Features.DeathReview or nil
if type(RSUI) ~= "table" or type(D) ~= "table" or type(PageHost) ~= "table" or type(Feature) ~= "table" then return end

local STORE_ID = "v3.death_review"
local function Settings() return Feature:GetSettingsProjection() end
local CLEAR_CONFIRM_TASK = "v3_death_review_clear_confirm_expire"

local function Build(parent, route)
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
    local featureToggle = RSUI:Button({ id = "v3_death_review_enable", parent = top, text = "启用死亡回顾", compact = true, slot = { size = "fixed", width = 118 } })
    -- FloatingSurface owns `v3_death_review_widget`; keep the page action on a
    -- distinct logical identity so auto-show and page creation can coexist.
    local showWidget = RSUI:Button({ id = "v3_death_review_widget_toggle", parent = top, text = "查看最近记录", compact = true, slot = { size = "fixed", width = 110 } })
    local deleteSelected = RSUI:Button({ id = "v3_death_review_delete_selected", parent = top, text = "删除选中", compact = true, enabled = false, slot = { size = "fixed", width = 88 } })
    clearHistory = RSUI:Button({ id = "v3_death_review_clear", parent = top, text = "清空历史", compact = true, slot = { size = "fixed", width = 98 } })
    local settingsButton = RSUI:Button({ id = "v3_death_review_settings_toggle", parent = top, text = "展开设置", compact = true, slot = { size = "fixed", width = 88 } })
    local healthText = RSUI:Text({ id = "v3_death_review_health", parent = top, text = "--", fontSize = 9, tone = "muted", overflow = "ellipsis", slot = { size = "fill", fill = 1 } })

    local settings = RSUI:VerticalBox({ id = "v3_death_review_settings", parent = root, gap = 4, slot = { size = "auto", hAlign = "fill" } })
    local settingsTop = RSUI:HorizontalBox({ id = "v3_death_review_settings_top", parent = settings, gap = 6, slot = { size = "auto", hAlign = "fill" } })
    local settingsBottom = RSUI:HorizontalBox({ id = "v3_death_review_settings_bottom", parent = settings, gap = 6, slot = { size = "auto", hAlign = "fill" } })
    local autoShow = RSUI:Toggle({
        id = "v3_death_review_auto", parent = settingsTop, onText = "死亡自动弹出：开", offText = "死亡自动弹出：关",
        get = function() return Settings().autoShow == true end, set = function(v) return Feature.Commands:ApplyAutoShow(v) end,
        storeId = STORE_ID, persistDelayMs = 300, persistReason = "death_review_auto_show", slot = { size = "fixed", width = 142 },
    })
    local showDebuffs = RSUI:Toggle({
        id = "v3_death_review_debuff", parent = settingsTop, onText = "记录 Debuff：开", offText = "记录 Debuff：关",
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

    local body = RSUI:HorizontalBox({ id = "v3_death_review_body", parent = root, gap = 8, slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" } })
    local left = RSUI:Border({ id = "v3_death_review_history_panel", parent = body, padding = 5, variant = "card", slot = { size = "fixed", width = 300, vAlign = "fill" } })
    local leftStack = RSUI:VerticalBox({ id = "v3_death_review_history_stack", parent = left, gap = 4 })
    RSUI:Text({ id = "v3_death_review_history_title", parent = leftStack, text = "历史记录", fontSize = 10, tone = "strong", slot = { size = "fixed", height = 20 } })
    local history = RSUI:TableView({
        id = "v3_death_review_history", parent = leftStack, items = {}, rowHeight = 27, headerHeight = 24, scrollbar = true,
        selectable = true, selectionMode = "single", columnResize = true,
        getKey = function(item) return item and item.serial or nil end,
        onSelectionChanged = function(_, _, view)
            root.selectedSerial = view and type(view.GetSelectedKey) == "function" and tonumber(view:GetSelectedKey()) or nil
            deleteSelected:SetEnabled(root.selectedSerial ~= nil)
            if type(root.RefreshDetail) == "function" then root:RefreshDetail() end
        end,
        columns = {
            { id = "clock", title = "时间", field = "clock", size = "fixed", width = 58, minWidth = 48 },
            { id = "lethal", title = "致命来源 / 技能", size = "fill", minWidth = 110, fill = 1,
                getText = function(item) return tostring(item.lethalSource or "--") .. " · " .. tostring(item.lethalAbility or "--") end },
            { id = "total", title = "总伤害", field = "totalDamage", size = "fixed", width = 62, minWidth = 50, getTone = function() return "red" end },
        },
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })

    local right = RSUI:Border({ id = "v3_death_review_detail_panel", parent = body, padding = 5, variant = "card", slot = { size = "fill", fill = 1, vAlign = "fill" } })
    local rightStack = RSUI:VerticalBox({ id = "v3_death_review_detail_stack", parent = right, gap = 4 })
    local summary = RSUI:Text({ id = "v3_death_review_summary", parent = rightStack, text = "请选择一条死亡记录", fontSize = 10, tone = "strong", overflow = "wrap", slot = { size = "fixed", height = 42 } })
    local timeline = RSUI:TableView({
        id = "v3_death_review_timeline", parent = rightStack, items = {}, rowHeight = 26, headerHeight = 24, scrollbar = true,
        selectable = false, columnResize = true,
        columns = {
            { id = "time", title = "距死亡", field = "timeText", size = "fixed", width = 56, minWidth = 44 },
            { id = "source", title = "来源", field = "source", size = "fill", minWidth = 82, fill = 0.8 },
            { id = "ability", title = "技能", field = "ability", size = "fill", minWidth = 100, fill = 1.2 },
            { id = "amount", title = "伤害", field = "amount", size = "fixed", width = 66, minWidth = 50, getTone = function() return "red" end },
        },
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })
    local debuffs = RSUI:Text({ id = "v3_death_review_detail_debuffs", parent = rightStack, text = "死亡时 Debuff：--", fontSize = 9, tone = "muted", overflow = "wrap", slot = { size = "fixed", height = 34 } })

    function root:RefreshDetail()
        local projection = Feature:GetProjection({ serial = self.selectedSerial, historyLimit = 30, timelineLimit = 96 })
        local rows, record = projection.timelineRows or {}, projection.record
        timeline:SetItems(rows, record and record.serial or 0)
        if record == nil then
            summary:SetText("请选择一条死亡记录")
            timeline:SetViewState("empty", { title = "未选择记录", detail = "从左侧历史中选择一次死亡查看完整时间线。" })
            debuffs:SetText("死亡时 Debuff：--")
            return true
        end
        local lethal = type(record.lethal) == "table" and record.lethal or {}
        summary:SetText(tostring(record.clock or "--:--:--") .. " · 总伤害 " .. tostring(record.totalDamage or 0)
            .. " · 窗口 " .. string.format("%.1fs", (tonumber(record.windowMs) or 0) / 1000)
            .. "\n致命：" .. tostring(lethal.source or "--") .. " · " .. tostring(lethal.ability or "--") .. " · " .. tostring(lethal.amount or 0))
        timeline:SetViewState(#rows > 0 and "ready" or "empty", #rows > 0 and nil or { title = "没有伤害行", detail = "该死亡记录中没有满足过滤条件的受伤事件。" })
        local names = {}
        for _, row in ipairs(record.debuffs or {}) do names[#names + 1] = tostring(row.name or "未知") .. ((tonumber(row.stack) or 0) > 1 and ("×" .. tostring(row.stack)) or "") end
        debuffs:SetText("死亡时 Debuff：" .. (#names > 0 and table.concat(names, " · ") or "无 / 未采集"))
        return true
    end

    function root:Refresh()
        local projection = Feature:GetProjection({ serial = self.selectedSerial, historyLimit = 30, timelineLimit = 96 })
        local enabled = projection.enabled == true
        featureToggle:SetText(enabled and "关闭死亡回顾" or "启用死亡回顾")
        showWidget:SetEnabled(enabled)
        local h = projection.health or {}
        healthText:SetText((enabled and "运行中" or "已关闭") .. " · 历史 " .. tostring(h.history or 0) .. " · 缓冲 " .. tostring(h.incoming or 0)
            .. " · Combat " .. tostring(h.busScope or "none") .. " · Aura " .. tostring(h.auraConsumer == true and "按需" or "关闭")
            .. (h.volatile == true and " · 1 条未保存" or ""))
        healthText:SetTone(enabled and "green" or "muted")
        local previousSerial = self.selectedSerial
        self.rows = projection.historyRows or {}
        history:SetItems(self.rows, h.revision or 0)
        if #self.rows == 0 then
            history:SetViewState("empty", { title = "暂无死亡记录", detail = enabled and "发生死亡后会记录最近受伤时间线。" or "先启用死亡回顾；功能关闭时不会监听战斗事件。" })
            self.selectedSerial = nil
            history:ClearSelection()
        else
            history:SetViewState("ready")
            local selectedIndex = nil
            for index, row in ipairs(self.rows) do if tonumber(row.serial) == tonumber(previousSerial) then selectedIndex = index; break end end
            if selectedIndex == nil then selectedIndex = 1; self.selectedSerial = tonumber(self.rows[1].serial) end
            history:SetSelectedIndex(selectedIndex)
        end
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
    for _, button in ipairs({ featureToggle, showWidget, deleteSelected, clearHistory, settingsButton }) do
        if button.root ~= nil then S.UI:SafeHandler(button.root, "OnClick", function() return button.spec.onClick() end, "v3_death_review:" .. tostring(button.id)) end
    end

    function root:Subscribe()
        if self.subscribed then return true end
        if S.Events and type(S.Events.SubscribeInternal) == "function" then
            S.Events:SubscribeInternal("v3.death_review.updated", self, function() root:Refresh() end)
            S.Events:SubscribeInternal("v3.death_review.settings", self, function() root:Refresh() end)
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

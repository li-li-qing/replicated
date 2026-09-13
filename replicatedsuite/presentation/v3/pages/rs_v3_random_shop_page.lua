------------------------------------------------------------------------
-- Replicated Suite V3 - Random Shop observer page
-- 维护（2026-09-12）：使用真实Feature投影、Command和内部事件，不另开Native读取/存档通道。
-- 数值草稿归RSUI NumericField；实时文本与操作回执分开，1秒观察不能擦掉输入或保存失败。
-- 页面隐藏即释放自己的需求；设置保存不等于常驻运行，阈值提示只在本页，不占用首领HUD。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI, D = S.RSUI, S.UIV3Design
local PageHost = S.UIV3 and S.UIV3.PageHost or nil
local Feature = S.Features and S.Features.RandomShop or nil
if type(RSUI) ~= "table" or type(D) ~= "table" or type(PageHost) ~= "table" or type(Feature) ~= "table" then return end
local ROUTE, ID = "tools.random_shop", "v3_random_shop_"
local KIND = { start = "新观察起点", increase = "读数增加", decrease = "读数下降：新起点",
    unavailable = "读取中断", manual = "手动重设起点" }
local function Num(value) return value ~= nil and tostring(value) or "--" end
local function Delta(value) return value == nil and "--" or (value > 0 and "+" .. tostring(value) or tostring(value)) end

local function BuildPage(parent, route)
    -- 维护：顺序设置页用共享滚动根和自动换行按钮，窄屏不靠硬编码Native坐标/二次缩放兜底。
    local root, err = D:ScrollablePageRoot(parent, { id = "v3_page_random_shop", gap = 7, padding = 2 })
    if root == nil then return nil, err end
    root.route, root.consumerHeld = route, false
    local called, loaded, loadErr = pcall(Feature.EnsureStoreLoaded, Feature)
    if called ~= true or loaded ~= true then
        -- 维护：先验证配置再创建绑定。坏档不投影成可写默认值；保留诊断入口，无重置/保存副作用。
        root.persistenceUnavailable = true
        D:PageHeader(root, ID .. "protected_header", "随机商店计数：配置已保护", "配置未通过读取校验，未清空旧设置，也未开始观察。")
        RSUI:Text({ id = ID .. "protected_reason", parent = root, text = tostring((called and loadErr or loaded) or "配置不可用"),
            fontSize = 10, tone = "warn", overflow = "wrap", slot = { size = "auto", minHeight = 40, hAlign = "fill" } })
        RSUI:Button({ id = ID .. "diagnostics", parent = root, text = "打开诊断与维护", compact = true,
            slot = { size = "fixed", height = 30, width = 160 }, onClick = function()
                local shell = S.UIV3 and S.UIV3.Shell
                if not shell or type(shell.Navigate) ~= "function" then return false, "诊断导航不可用" end
                return shell:Navigate("system.diagnostics", { source = "random_shop_protected" })
            end })
        function root:OnActivated() return true end
        function root:OnDeactivated() return true end
        return root
    end
    D:PageHeader(root, ID .. "header", "随机商店计数", "读取游戏返回的原始计数；自动读取仅在本页可见时运行，不会刷新或购买商店物品。")
    local actions = RSUI:UniformGrid({ id = ID .. "actions", parent = root, minCellWidth = 148, minCellHeight = 30,
        maxColumns = 2, gap = 6, slot = { size = "auto", hAlign = "fill" } })
    local actionStatus, toggle, readButton, resetButton, autoToggle, threshold
    local function Result(ok, actionErr, message)
        if root.Refresh then root:Refresh() end
        if actionStatus then actionStatus:SetText(ok == true and message or ("操作失败：" .. tostring(actionErr or "未执行"))) end
        return ok, actionErr
    end
    toggle = RSUI:Button({ id = ID .. "toggle", parent = actions, text = "启用功能", compact = true,
        slot = { size = "fill", hAlign = "fill" }, onClick = function()
            local target = S.FeatureRuntime:IsEnabled(Feature.Id) ~= true
            local ok, actionErr = S.FeatureRuntime:SetPreferredEnabled(Feature.Id, target, "random_shop_page_toggle")
            if ok ~= true then return Result(ok, actionErr) end
            local acquired, acquireErr = root:SyncConsumer()
            if acquired ~= true and target then
                local reverted, revertErr = S.FeatureRuntime:SetPreferredEnabled(Feature.Id, false, "random_shop_acquire_rollback")
                if reverted ~= true then acquireErr = tostring(acquireErr) .. "；启用回滚失败：" .. tostring(revertErr) end
                return Result(false, acquireErr)
            end
            return Result(true, nil, target and "功能已启用，开关偏好由统一配置管理。" or "功能已关闭；观察已停止，设置保留。")
        end })
    readButton = RSUI:Button({ id = ID .. "header_action", parent = actions, text = "读取计数", compact = true,
        slot = { size = "fill", hAlign = "fill" }, onClick = function()
            local ok, readErr = Feature.Commands:Refresh("random_shop_page_manual")
            return Result(ok, readErr, Feature:GetProjection().available and "已读取当前计数；没有执行商店刷新。" or "读取完成，但当前计数未知；未以0替代。")
        end })
    autoToggle = RSUI:Toggle({ id = ID .. "auto_read", parent = actions, onText = "可见页自动读取：开", offText = "可见页自动读取：关",
        slot = { size = "fill", hAlign = "fill" }, get = function() return Feature:GetProjection().autoRead end,
        set = function(value)
            local ok, saveErr = Feature.Commands:SetAutoRead(value)
            return Result(ok, saveErr, "自动读取偏好已保存并回读；关页后停止。")
        end })
    resetButton = RSUI:Button({ id = ID .. "reset_baseline", parent = actions, text = "重设观察起点", compact = true,
        slot = { size = "fill", hAlign = "fill" }, onClick = function()
            local ok, resetErr = Feature.Commands:ResetBaseline()
            return Result(ok, resetErr, "仅重新设置本次观察起点；没有清空游戏计数或修改存档。")
        end })
    threshold = D:CompactNumericSetting(root, { id = ID .. "threshold", label = "个人提示阈值", min = 0, max = 1000000,
        slider = false, integer = true, step = 1, inputWidth = 86, labelWidth = 100, applyButton = true,
        get = function() return Feature:GetProjection().threshold end,
        set = function(value)
            local ok, saveErr = Feature.Commands:SetThreshold(value)
            return Result(ok, saveErr, "个人阈值已保存并回读；0关闭，达到时只在本页提示。")
        end })
    actionStatus = RSUI:Text({ id = ID .. "action_status", parent = root, text = "默认手动读取；阈值0关闭提示，输入后点击应用。",
        fontSize = 9, tone = "muted", overflow = "wrap", slot = { size = "auto", minHeight = 22, hAlign = "fill" } })
    local card = D:InfoCard(root, { id = ID .. "card", title = "原始计数", value = "等待读取", detail = "",
        detailMaxLines = 4, slot = { size = "auto", minHeight = 82, hAlign = "fill" } })
    local reminder = RSUI:Text({ id = ID .. "reminder", parent = root, text = "", fontSize = 11, tone = "accent", overflow = "wrap",
        slot = { size = "auto", minHeight = 24, hAlign = "fill" } })
    local tableView = RSUI:TableView({ id = ID .. "history", parent = root, items = {}, rowHeight = 26, headerHeight = 27,
        desiredRows = 4, scrollbar = true, selectable = false, columnResize = false,
        getKey = function(row) return row.key end, slot = { size = "fixed", height = 145, hAlign = "fill" },
        columns = {
            { id = "count", title = "采样值", size = "fixed", width = 100, minWidth = 72, getText = function(r) return Num(r.count) end },
            { id = "delta", title = "相邻差值", size = "fixed", width = 95, minWidth = 75, getText = function(r) return Delta(r.delta) end },
            { id = "kind", title = "最近变化（最多12条）", size = "fill", minWidth = 160, getText = function(r) return KIND[r.kind] or "未知" end },
        } })
    local status = RSUI:Text({ id = ID .. "status", parent = root, text = "", fontSize = 9, tone = "muted", overflow = "wrap",
        slot = { size = "auto", minHeight = 35, hAlign = "fill" } })
    RSUI:Text({ id = ID .. "limits", parent = root,
        text = "注意：差值不是花费、剩余次数或每日额度。下降/读取中断会另起一段；无法识别同数值的商店切换。关页或重载不保留采样历史。",
        fontSize = 9, tone = "muted", overflow = "wrap", slot = { size = "auto", minHeight = 35, hAlign = "fill" } })

    function root:Refresh()
        local p = Feature:GetProjection()
        toggle:SetText(p.enabled and "关闭功能" or "启用功能")
        readButton:SetEnabled(p.enabled and self._shopActive == true)
        resetButton:SetEnabled(p.enabled and p.available and self._shopActive == true)
        -- 维护：只刷新绑定，NumericField会保护编辑中的草稿；不得在观察回调中SetText到原生编辑框。
        autoToggle:Render(); threshold:Render()
        if not p.enabled then card:SetData({ value = "功能已关闭", detail = "设置保留；显式启用后才读取。" })
        elseif not p.available then card:SetData({ value = "未知", detail = p.error or "当前未获得有效读数。" })
        else card:SetData({ value = Num(p.refreshCount), detail = "本段起点：" .. Num(p.baseline) .. "  ·  与起点差值：" .. Delta(p.sinceBaseline)
            .. "\n" .. (p.polling and "可见页每1秒读取一次" or "手动读取；此值为上次采样") }) end
        local messages = { off = "个人阈值提示已关闭（0）。", unknown = "计数未知，暂不判断是否达到个人阈值。",
            reached = "已达到个人阈值 " .. Num(p.threshold) .. "（不是游戏限额）。",
            below = "未达到个人阈值 " .. Num(p.threshold) .. "（仅本页提示）。" }
        reminder:SetText(messages[p.reminderState] or "")
        local historyKey = p.history[1] and p.history[1].key or "empty"
        if self._historyKey ~= historyKey then tableView:SetItems(p.history); self._historyKey = historyKey end
        tableView:SetViewState(#p.history > 0 and "ready" or "empty", { title = "暂无观察记录", detail = "启用后读取计数；只保留本段观察的最近变化。" })
        local h = Feature:GetHealth()
        status:SetText((p.observing and "观察需求已建立" or "观察已停止") .. " · 采样 " .. Num(h.refreshes) .. " / 失败 " .. Num(h.failures)
            .. " · 返回类型 " .. (h.rawType or "尚未读取") .. " · " .. p.patch
            .. (p.lifecycleError and ("\n" .. p.lifecycleError) or ""))
        return true
    end
    -- 维护：token属于页面实例，不能固定为路由。缓存旧页面退场不得释放新页面的需求。
    local token, generation = "page:random_shop:" .. tostring(root), S.Generation
    function root:SyncConsumer()
        if self._shopActive ~= true then return true end
        if S.FeatureRuntime:IsEnabled(Feature.Id) ~= true then self.consumerHeld = false; return self:Refresh() end
        local ok, acquireErr = Feature:AcquireConsumer(token)
        self.consumerHeld = ok == true
        if ok ~= true then return false, acquireErr end
        return self:Refresh()
    end
    function root:OnActivated()
        if self.released then return false, "页面已经释放" end
        if self._shopActive then return self:SyncConsumer() end
        self._shopActive = true
        local events = S.Events
        if not events or type(events.SubscribeInternal) ~= "function" then self._shopActive = false; return false, "内部事件总线不可用" end
        local bound = events:SubscribeInternal(Feature.UpdateTopic, self, function(_, id)
            if root._shopActive ~= true or S.Generation ~= generation or id ~= Feature.Id then return end
            if not Feature:GetProjection().enabled then root.consumerHeld = false end
            root:Refresh()
        end)
        local lifecycle = events:SubscribeInternal("v3.feature.lifecycle", self, function(_, id)
            if root._shopActive ~= true or S.Generation ~= generation or id ~= Feature.Id then return end
            local ok, syncErr = root:SyncConsumer(); if ok ~= true then Result(false, syncErr) end
        end)
        if bound ~= true or lifecycle ~= true then self:OnDeactivated(); return false, "内部事件订阅失败" end
        local ok, acquireErr = self:SyncConsumer()
        if ok ~= true then self:OnDeactivated(); return false, acquireErr end
        return true
    end
    function root:OnDeactivated()
        -- 维护：先撤监听/active，再释放需求，避免清空投影同步发布导致已经隐藏的页再绘制。
        self._shopActive = false
        if S.Events and S.Events.UnsubscribeInternalOwner then S.Events:UnsubscribeInternalOwner(self) end
        if self.consumerHeld then
            local ok, releaseErr = Feature:ReleaseConsumer(token)
            if ok ~= true then return false, releaseErr end
            self.consumerHeld = false
        end
        return true
    end
    local release = root.Release
    function root:Release()
        self:OnDeactivated()
        return release(self)
    end
    root.tableView = tableView
    return root
end
local ok, err = PageHost:RegisterFactory(ROUTE, BuildPage)
if ok ~= true then error(err) end

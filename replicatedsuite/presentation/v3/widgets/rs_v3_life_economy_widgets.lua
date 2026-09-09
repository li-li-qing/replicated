------------------------------------------------------------------------
-- Replicated Suite V3 - Life Economy Floating Widgets
--
-- Trade/Bonds/Treasure/Fishing are independent FloatingSurface consumers.  The page may be
-- closed while the HUD remains live; closing the HUD releases only its own
-- Demand token.  No polling/tick is owned by Presentation.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI = S.RSUI
local Host = S.UIV3 and S.UIV3.WidgetHost or nil
local Floating = RSUI and RSUI.FloatingSurface or nil
if type(RSUI) ~= "table" or type(Host) ~= "table" or type(Floating) ~= "table" then return end

local function ZoneItems(rows)
    local out = {}
    for _, row in ipairs(type(rows) == "table" and rows or {}) do
        out[#out + 1] = { value = row.id, text = tostring(row.displayName or row.name or ("地区 " .. tostring(row.id or "?"))) }
    end
    return out
end

local function FindZoneName(projection, id)
    id = tonumber(id)
    if id == nil then return "--" end
    for _, list in ipairs({ projection and projection.zones or {}, projection and projection.sellableZones or {} }) do
        for _, row in ipairs(list) do
            if tonumber(row.id) == id then return tostring(row.name or row.displayName or id) end
        end
    end
    return tostring(id)
end

local function Register(spec)
    local featureId = tostring(spec.featureId or "")
    if featureId == "" then return false, "生活悬浮窗 featureId 缺失: " .. tostring(spec.widgetId) end
    local Feature = S.Features and S.Features[spec.featureName] or nil
    if type(Feature) ~= "table" then return false, "生活悬浮窗 Feature 缺失: " .. tostring(spec.featureName) end
    if type(Feature.GetProjection) ~= "function" or type(Feature.GetWidgetWindowState) ~= "function"
        or type(Feature.GetWidgetVisible) ~= "function" or type(Feature.AcquireConsumer) ~= "function"
        or type(Feature.ReleaseConsumer) ~= "function" or type(Feature.Commands) ~= "table" then
        return false, "生活悬浮窗 Feature 契约不完整: " .. tostring(spec.widgetId)
    end

    local function Policy()
        return type(Feature.GetWidgetWindowPolicy) == "function" and Feature:GetWidgetWindowPolicy()
            or { defaultWidth = spec.width or 470, defaultHeight = spec.height or 310, minWidth = 240, minHeight = 140,
                defaultOverallOpacity = 0.94, defaultBackgroundOpacity = 1.0, defaultTextOpacity = 1.0 }
    end
    local function Persist(reason)
        return Feature.Commands:MarkStoreDirty(250, "widget_" .. tostring(reason or "state"))
    end

    local function CreateWidget()
        local instance = { id = spec.widgetId, owner = spec.owner, visible = false, subscribed = false }
        local surface, createErr = Floating:Create({
            id = spec.rootId, owner = spec.owner, title = spec.title, status = "--",
            footer = true, resizable = true, movable = true, minimizeMode = "compact", boundaryMode = "free",
            defaultPlacement = "top-right", statePolicy = Policy(),
            getState = function() return Feature:GetWidgetWindowState() end,
            setState = function(value, reason) return Feature.Commands:SetWidgetWindowState(value, reason) end,
            persist = Persist,
            onClosed = function(_, reason)
                return Host:NotifyWindowClosed(spec.widgetId, { source = tostring(reason or "widget_close"), persist = true })
            end,
        })
        if surface == nil then return nil, createErr or (spec.title .. "悬浮窗创建失败") end
        instance.surface, instance.shell, instance.window = surface, surface.shell, surface.window
        instance.root, instance.windowController = surface.shell.root, surface.windowController
        local content = RSUI:VerticalBox({ id = spec.contentId, parent = surface:GetContentRoot(), gap = 4,
            slot = { hAlign = "fill", vAlign = "fill" } })
        if type(spec.buildControls) == "function" then
            local controlsOk, controlsErr = spec.buildControls(instance, content, Feature)
            if controlsOk == false then return nil, controlsErr or (spec.title .. "悬浮窗控制条创建失败") end
        end
        instance.table = RSUI:TableView({
            id = spec.tableId, parent = content, items = {}, rowHeight = 24, headerHeight = 23, desiredRows = 10,
            overscan = 1, scrollbar = true, selectable = spec.selectable == true, selectionMode = "single", columnResize = true, headerInteractive = false,
            columns = spec.columns, slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
        })
        if spec.selectable == true and type(spec.onSelection) == "function" then
            instance.table.onSelectionChanged = function(index)
                local row = instance.table:GetItem(index)
                return spec.onSelection(instance, row, Feature)
            end
        end

        function instance:Refresh()
            local projection = Feature:GetProjection() or {}
            local rows = type(spec.rows) == "function" and spec.rows(projection) or (projection.rows or {})
            rows = type(rows) == "table" and rows or {}
            self.table:SetItems(rows, projection.revision or 0)
            if type(spec.refreshControls) == "function" then spec.refreshControls(self, projection, rows, Feature) end
            if projection.status == "unavailable" or projection.status == "error" then
                self.table:SetViewState("unavailable", { title = spec.title .. "数据不可用", detail = tostring(projection.error or "事实读取失败") })
            elseif #rows == 0 then
                self.table:SetViewState("empty", { title = spec.emptyTitle, detail = spec.emptyDetail })
            else
                self.table:SetViewState("ready")
            end
            self.surface:SetStatus(spec.status(projection, rows), projection.status == "ready" and "accent" or (projection.status == "loading" and "yellow" or "muted"))
            return true
        end
        function instance:Subscribe()
            if self.subscribed then return true end
            if S.Events ~= nil and type(S.Events.SubscribeInternal) == "function" and type(Feature.UpdateTopic) == "string" then
                S.Events:SubscribeInternal(Feature.UpdateTopic, self, function() if instance.visible then instance:Refresh() end end)
            end
            self.subscribed = true
            return true
        end
        function instance:Unsubscribe()
            if self.subscribed and S.Events ~= nil and type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
            self.subscribed = false
            return true
        end
        local function ReleaseConsumer()
            if instance.visible ~= true then return true end
            if not (S.FeatureRuntime and S.FeatureRuntime:IsEnabled(featureId) == true) then return true end
            return Feature:ReleaseConsumer("widget:" .. spec.token)
        end
        function instance:Show(context)
            if self.visible then self:Refresh(); return self.surface:Show(true) end
            local acquired = false
            local ok, openErr = xpcall(function()
                if not (S.FeatureRuntime and S.FeatureRuntime:IsEnabled(featureId) == true) then error(spec.title .. "功能已关闭") end
                self:Subscribe()
                local acquireOk, acquireErr = Feature:AcquireConsumer("widget:" .. spec.token)
                if acquireOk ~= true then error(acquireErr or (spec.title .. " Consumer 获取失败")) end
                acquired = true
                self:Refresh()
                if self.surface:Show(true) ~= true then error(spec.title .. "悬浮窗显示失败") end
            end, S.SafeTraceback)
            if ok ~= true then
                self.surface:Show(false); self:Unsubscribe()
                if acquired then Feature:ReleaseConsumer("widget:" .. spec.token) end
                self.visible = false
                return false, openErr
            end
            self.visible = true
            if type(context) ~= "table" or context.persist ~= false then Feature.Commands:SetWidgetVisible(true, "show") end
            return true
        end
        function instance:Hide(context)
            local hidden, hideErr = self.surface:Show(false)
            if hidden ~= true then return false, hideErr end
            local released, releaseErr = true, nil
            if self.visible then released, releaseErr = ReleaseConsumer() end
            self.visible = false; self:Unsubscribe()
            if type(context) ~= "table" or context.persist ~= false then Feature.Commands:SetWidgetVisible(false, "hide") end
            if released ~= true then return false, releaseErr end
            return true
        end
        function instance:OnWindowClosed(context)
            local released, releaseErr = ReleaseConsumer()
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
    local ok, err = Host:Register(spec.widgetId, {
        featureId = featureId, create = CreateWidget, ensurePreferences = function() return Feature:Initialize() end,
        lockable = true, minimizable = true, resettable = true, opacityAdjustable = true, backgroundOpacityAdjustable = true, textOpacityAdjustable = true,
        getLocked = adapter.getLocked, setLocked = adapter.setLocked, getMinimized = adapter.getMinimized, setMinimized = adapter.setMinimized,
        getOverallOpacity = adapter.getOverallOpacity, setOverallOpacity = adapter.setOverallOpacity, getOpacity = adapter.getOpacity, setOpacity = adapter.setOpacity,
        getBackgroundOpacity = adapter.getBackgroundOpacity, setBackgroundOpacity = adapter.setBackgroundOpacity,
        getTextOpacity = adapter.getTextOpacity, setTextOpacity = adapter.setTextOpacity, resetLayout = adapter.resetLayout,
    })
    if ok ~= true then return false, err end
    if S.Events ~= nil and type(S.Events.SubscribeInternal) == "function" then
        Host:BindFeatureLifecycle(spec.widgetId, {
            featureId = featureId,
            enabled = function() return S.FeatureRuntime:IsEnabled(featureId) == true end,
            preference = function() return Feature:GetWidgetVisible() == true end,
            onShowFailed = function() Feature.Commands:SetWidgetVisible(false, "auto_show_failed") end,
        })
    end
    return true
end

local ok, err = Register({
    featureName = "Trade", featureId = "life_trade", widgetId = "life.trade", token = "life_trade", owner = "v3:widget:life_trade",
    rootId = "v3_life_trade_widget", contentId = "v3_life_trade_widget_content", tableId = "v3_life_trade_widget_table", title = "跑商货率",
    emptyTitle = "暂无货率", emptyDetail = "直接在悬浮窗选择起点和目的地；服务器货率返回后自动更新。",
    buildControls = function(instance, content, Feature)
        if type(Feature.Commands.SetFrom) ~= "function" or type(Feature.Commands.SetTo) ~= "function"
            or type(Feature.Commands.SetRatioMode) ~= "function" or type(Feature.Commands.SetCommerceMode) ~= "function"
            or type(Feature.Commands.QuotePendingMaterials) ~= "function" or type(Feature.Commands.ToggleCurrentFavorite) ~= "function"
            or type(Feature.Commands.SelectFavorite) ~= "function" or type(Feature.Commands.SetSortMode) ~= "function" then
            return false, "跑商悬浮窗 Feature 路线/收藏/询价命令缺失"
        end
        -- 中文维护注释：跑商 HUD 固定为“路线 / 快捷动作 / 收藏与排序”三行；只重排 Presentation，不复制货率、售价或询价 Authority。
        -- 中文维护注释：原有语义控件 ID 必须继续复用，保证绑定、诊断与升级兼容不因布局重构失效。
        local routeBox = RSUI:VerticalBox({ id = "v3_life_trade_widget_route", parent = content, gap = 3, -- 中文维护注释：三行控件以 3px 间距收敛为紧凑操作区，避免悬浮窗像完整应用页面。
            slot = { size = "fixed", height = 90, hAlign = "fill" } }) -- 中文维护注释：28+28+28 加两段 3px 间距恰好 90px，禁止用 fill 抢占货物表格空间。
        local routeRow = RSUI:HorizontalBox({ id = "v3_life_trade_widget_from_row", parent = routeBox, gap = 4, -- 中文维护注释：起点与目的地合并到同一行，保留旧 from 行 ID 以维持诊断连续性。
            slot = { size = "fixed", height = 28, hAlign = "fill" } }) -- 中文维护注释：路线选择行固定 28px，低分辨率下优先压缩文字而不是增加悬浮窗高度。
        RSUI:Text({ id = "v3_life_trade_widget_from_label", parent = routeRow, text = "起", fontSize = 9, tone = "muted", -- 中文维护注释：用单字标签降低横向占用，语义仍由原控件 ID 和下拉框 placeholder 保持明确。
            slot = { size = "fixed", width = 18 } }) -- 中文维护注释：标签固定 18px，给两个路线下拉框留下最低 100px 可用宽度。
        instance.fromDropdown = RSUI:Dropdown({ id = "v3_life_trade_widget_from", parent = routeRow, items = {}, maxVisible = 10, popupWidth = 210, placeholder = "起点", -- 中文维护注释：下拉逻辑与 Command 边界不变，仅缩小 popup 宽度以匹配紧凑 HUD。
            get = function() return (Feature:GetRouteSettings() or {}).fromZone end, set = function(v) return Feature.Commands:SetFrom(v) end, -- 中文维护注释：起点状态继续由 Feature route settings/Command 管理，Widget 不持有副本。
            slot = { size = "fill", fill = 1, minWidth = 100 } }) -- 中文维护注释：使用 fill 让路线下拉框随悬浮窗缩放，并守住 1024×768 场景下的最小可操作宽度。
        RSUI:Text({ id = "v3_life_trade_widget_route_arrow", parent = routeRow, text = "→", fontSize = 9, tone = "muted", -- 中文维护注释：新增纯 Presentation 路线方向符号，不参与路线值、请求或持久化。
            slot = { size = "fixed", width = 16 } }) -- 中文维护注释：方向符固定窄宽，避免不同地区名称长度导致控件顺序漂移。
        RSUI:Text({ id = "v3_life_trade_widget_to_label", parent = routeRow, text = "到", fontSize = 9, tone = "muted", -- 中文维护注释：目的地标签压缩为单字，仍复用旧 to label ID 保持 UI 诊断稳定。
            slot = { size = "fixed", width = 18 } }) -- 中文维护注释：固定 18px 防止标签挤占目的地下拉框。
        instance.toDropdown = RSUI:Dropdown({ id = "v3_life_trade_widget_to", parent = routeRow, items = {}, maxVisible = 10, popupWidth = 210, placeholder = "目的地", -- 中文维护注释：目的地下拉仅缩减视觉尺寸，选区过滤与服务器货率 Authority 完全不变。
            get = function() return (Feature:GetRouteSettings() or {}).toZone end, set = function(v) return Feature.Commands:SetTo(v) end, -- 中文维护注释：继续通过 Feature Command 写路线，Widget 禁止直接改 Trade.State。
            slot = { size = "fill", fill = 1, minWidth = 100 } }) -- 中文维护注释：与起点等权自适应，保证紧凑窗口仍能清晰选择两个地区。

        local modeRow = RSUI:HorizontalBox({ id = "v3_life_trade_widget_mode_row", parent = routeBox, gap = 4, -- 中文维护注释：第二行集中高频操作，减少鼠标移动和垂直占用。
            slot = { size = "fixed", height = 28, hAlign = "fill" } }) -- 中文维护注释：快捷动作保持单行 28px；功能启停/询价行为仍由 Feature Commands 负责。
        instance.ratioButton = RSUI:Button({ id = "v3_life_trade_widget_ratio_mode", parent = modeRow, text = "实时货率", compact = true, -- 中文维护注释：缩短按钮文案但保留 current/full 二态 Command 语义。
            slot = { size = "fill", fill = 1, minWidth = 70 } }) -- 中文维护注释：用弹性宽度适配 320px 最小窗口，不额外创建模式状态。
        instance.ratioButton.onClick = function()
            local projection = Feature:GetProjection() or {}
            local ok, modeErr = Feature.Commands:SetRatioMode(projection.ratioMode == "full" and "current" or "full")
            if ok == true then instance:Refresh() end
            return ok, modeErr
        end
        instance.commerceButton = RSUI:Button({ id = "v3_life_trade_widget_commerce_mode", parent = modeRow, text = "计熟练", compact = true, -- 中文维护注释：经商熟练度开关只改显示文案，实际售价公式仍由 TradePayoutV3/Feature Authority 提供。
            slot = { size = "fill", fill = 1, minWidth = 64 } }) -- 中文维护注释：最小 64px 保证中文状态可辨识，同时让询价/收藏按钮共存于同一行。
        instance.commerceButton.onClick = function()
            local projection = Feature:GetProjection() or {}
            local ok, modeErr = Feature.Commands:SetCommerceMode(projection.commerceMode == "off" and "observe" or "off")
            if ok == true then instance:Refresh() end
            return ok, modeErr
        end
        instance.quoteButton = RSUI:Button({ id = "v3_life_trade_widget_quote", parent = modeRow, text = "询价", compact = true, -- 中文维护注释：材料询价缩为高频短标签，SingleFlight/请求超时等 Authority 契约不在 Widget 中改动。
            slot = { size = "fill", fill = 0.85, minWidth = 56 } }) -- 中文维护注释：询价按钮略低 fill 权重，优先给模式按钮留足状态文本空间。
        instance.quoteButton.onClick = function()
            local ok, quoteErr = Feature.Commands:QuotePendingMaterials()
            if ok == true then instance:Refresh() end
            return ok, quoteErr
        end
        instance.favoriteButton = RSUI:Button({ id = "v3_life_trade_widget_favorite_toggle", parent = modeRow, text = "收藏", compact = true, -- 中文维护注释：收藏切换搬到快捷动作行但保留原控件 ID/Command，旧用户数据无需迁移。
            slot = { size = "fill", fill = 0.85, minWidth = 56 } }) -- 中文维护注释：与询价保持同等紧凑预算，不增加额外行高。
        instance.favoriteButton.onClick = function()
            local ok, favoriteErr = Feature.Commands:ToggleCurrentFavorite()
            if ok == true then instance:Refresh() end
            return ok, favoriteErr
        end

        local favoriteRow = RSUI:HorizontalBox({ id = "v3_life_trade_widget_favorite_row", parent = routeBox, gap = 4, -- 中文维护注释：第三行合并收藏路线选择与排序，替代旧版额外排序行。
            slot = { size = "fixed", height = 28, hAlign = "fill" } }) -- 中文维护注释：固定 28px 完成三行总高度约束，表格获得更多可见行。
        instance.favoriteDropdown = RSUI:Dropdown({ id = "v3_life_trade_widget_favorite", parent = favoriteRow, items = {}, maxVisible = 10, popupWidth = 230, placeholder = "收藏路线", -- 中文维护注释：收藏路线 Popup 适度缩宽，列表数据仍完全来自 Feature projection。
            get = function() local projection = Feature:GetProjection() or {}; return projection.currentRouteFavorite and projection.currentFavoriteKey or nil end, -- 中文维护注释：只读取投影中的当前收藏键，不在 Presentation 计算或复制收藏集合。
            set = function(value) return Feature.Commands:SelectFavorite(value) end, slot = { size = "fill", fill = 1.25, minWidth = 110 } }) -- 中文维护注释：收藏选择继续通过 Command 写入，较高 fill 权重保证长路线名称优先获得空间。
        RSUI:Text({ id = "v3_life_trade_widget_sort_label", parent = favoriteRow, text = "排序", fontSize = 8, tone = "muted", -- 中文维护注释：排序标签缩小字号与宽度，为三段选择器留出稳定空间。
            slot = { size = "fixed", width = 28 } }) -- 中文维护注释：固定标签宽度避免排序段因语言长度产生抖动。
        instance.sortSelector = RSUI:SegmentedSelector({
            id = "v3_life_trade_widget_sort", parent = favoriteRow, itemWidth = 34, gap = 1, height = 22, fontSize = 8, -- 中文维护注释：复用稳定 sort ID，将三段选择器压缩到 104px 左右且保留 one-of-many 语义。
            items = {
                { value = "ratio", text = "货率" },
                { value = "price", text = "售价" },
                { value = "name", text = "名字" },
            },
            get = function() return (Feature:GetProjection() or {}).sortMode or "ratio" end,
            set = function(value) return Feature.Commands:SetSortMode(value) end,
            slot = { size = "auto", hAlign = "right", vAlign = "fill" }, -- 中文维护注释：排序控件靠右固定自身宽度，收藏下拉框吸收剩余空间。
        })
        return instance.fromDropdown ~= nil and instance.toDropdown ~= nil and instance.ratioButton ~= nil
            and instance.commerceButton ~= nil and instance.quoteButton ~= nil and instance.favoriteDropdown ~= nil
            and instance.favoriteButton ~= nil and instance.sortSelector ~= nil, "跑商悬浮窗路线/模式/收藏控件创建失败"
    end,
    refreshControls = function(instance, projection)
        local fromItems, toItems = ZoneItems(projection.zones), ZoneItems(projection.sellableZones)
        if instance.fromDropdown then instance.fromDropdown:SetItems(fromItems); instance.fromDropdown:SetEnabled(#fromItems > 0); instance.fromDropdown:Render() end
        if instance.toDropdown then instance.toDropdown:SetItems(toItems); instance.toDropdown:SetEnabled(#toItems > 0); instance.toDropdown:Render() end
        local pending = math.max(0, tonumber(projection.pendingQuoteCount) or 0)
        if instance.ratioButton then instance.ratioButton:SetText(projection.ratioMode == "full" and ("满" .. tostring(projection.fullRatio or 130) .. "%") or "实时货率") end -- 中文维护注释：刷新时使用短状态文案；ratioMode/fullRatio 仍只从 Feature projection 读取。
        if instance.commerceButton then instance.commerceButton:SetText(projection.commerceMode == "off" and "忽略熟练" or "计熟练") end -- 中文维护注释：经商模式只更新按钮文本，不在 Widget 重新计算熟练度或售价。
        if instance.quoteButton then
            instance.quoteButton:SetEnabled(pending > 0)
            instance.quoteButton:SetText(pending > 0 and ("询价(" .. tostring(pending) .. ")") or "询价") -- 中文维护注释：保留待询价数量反馈，同时去掉冗长“材料”前缀以降低横向预算。
        end
        local favoriteItems = type(projection.favoriteItems) == "table" and projection.favoriteItems or {}
        if instance.favoriteDropdown then instance.favoriteDropdown:SetItems(favoriteItems); instance.favoriteDropdown:SetEnabled(#favoriteItems > 0); instance.favoriteDropdown:Render() end
        if instance.favoriteButton then
            instance.favoriteButton:SetEnabled(projection.fromZone ~= nil and projection.toZone ~= nil)
            instance.favoriteButton:SetText(projection.currentRouteFavorite == true and "取消" or "收藏") -- 中文维护注释：当前路线已收藏时使用短“取消”状态，收藏事实仍由 Feature projection 决定。
        end
        if instance.sortSelector then
            instance.sortSelector:SetEnabled(#(projection.rows or {}) > 0)
            instance.sortSelector:Render()
        end
    end,
    selectable = true,
    onSelection = function(instance, row, Feature)
        if type(row) ~= "table" or row.key == nil then return false end
        if type(Feature.Commands.SelectRow) == "function" then
            local ok, selectErr = Feature.Commands:SelectRow(row.key)
            if ok ~= true then return false, selectErr end
        end
        local detail = S.UIV3 and S.UIV3.TradeDetailFloatingV3 or nil
        if type(detail) ~= "table" or type(detail.Open) ~= "function" then return false, "贸易品详情悬浮窗不可用" end
        return detail:Open(row.key)
    end,
    columns = {
        { id = "name", title = "货物", field = "name", size = "fill", minWidth = 108, fill = 1 }, -- 中文维护注释：货物列仍负责吸收剩余宽度，仅略降最小值以支持 320px 紧凑窗口。
        { id = "rate", title = "货率", field = "rate", size = "fixed", width = 54, minWidth = 48, getTone = function(item) return item and item.tone or "muted" end }, -- 中文维护注释：货率列收紧但保留原 tone 规则，不改变 130%/实时货率业务判断。
        { id = "price", title = "售价", field = "price", size = "fixed", width = 74, minWidth = 60 }, -- 中文维护注释：售价列缩窄到可读金币文本预算，字段来源仍是 Authority 已计算结果。
        { id = "profit", title = "毛利", field = "profit", size = "fixed", width = 78, minWidth = 64 }, -- 中文维护注释：毛利列仅调整 Presentation 宽度，不更改材料成本/询价公式。
    },
    status = function(projection, rows)
        local pending = math.max(0, tonumber(projection.pendingQuoteCount) or 0)
        local fallback = projection.zoneFallback == true and " · 静态起点候选" or ""
        local ratio = projection.ratioMode == "full" and (" · 满" .. tostring(projection.fullRatio or 130) .. "%") or " · 实时"
        local commerce = ""
        if projection.commerceMode == "observe" then
            if projection.commerceStatus == "ready" and projection.commerceSkill ~= nil then
                local skill = math.max(0, tonumber(projection.commerceSkill) or 0)
                commerce = " · 经商 " .. tostring(math.floor(skill + 0.5))
                    .. "×" .. string.format("%.3f", 1 + (skill / 10000 * 0.05))
            else
                commerce = " · 经商不可读"
            end
        else
            commerce = " · 熟练忽略"
        end
        local favorites = type(projection.favoriteItems) == "table" and #projection.favoriteItems or 0
        local sort = (projection.sortMode == "price" and " · 售价序")
            or (projection.sortMode == "name" and " · 名字序（[]优先）")
            or " · 货率序"
        local inFlight = math.max(0, tonumber(projection.quoteInFlightCount) or 0)
        local unresolvedIdentity = math.max(0, tonumber(projection.unresolvedIdentityCount) or 0)
        return FindZoneName(projection, projection.fromZone) .. " → " .. FindZoneName(projection, projection.toZone) .. " · " .. tostring(#rows) .. "种" -- 中文维护注释：底栏首段保留路线与货物数量，去掉多余空格以适配窄窗口。
            .. ratio .. commerce .. " · 收藏" .. tostring(favorites) .. sort -- 中文维护注释：模式、熟练度、收藏和排序仍由投影状态拼接，不引入额外计算。
            .. (pending > 0 and (" · 待询价" .. tostring(pending)) or "") -- 中文维护注释：仅在有待处理材料时显示计数，避免常态底栏冗长。
            .. (inFlight > 0 and (" · 询价中" .. tostring(inFlight)) or "") -- 中文维护注释：保留正在询价状态，便于确认 SingleFlight 请求仍在工作。
            .. (unresolvedIdentity > 0 and (" · 待解析" .. tostring(unresolvedIdentity)) or "") .. fallback -- 中文维护注释：身份解析与回退警告仍完整保留，只压缩标签文字。
    end,
})
if ok ~= true then error(err) end

ok, err = Register({
    featureName = "Bonds", featureId = "life_bonds", widgetId = "life.bonds", token = "life_bonds", owner = "v3:widget:life_bonds",
    rootId = "v3_life_bonds_widget", contentId = "v3_life_bonds_widget_content", tableId = "v3_life_bonds_widget_table", title = "债券 / 居民板",
    emptyTitle = "暂无居民板条目", emptyDetail = "居民板事实不可用或当前筛选没有条目。",
    buildControls = function(instance, content, Feature)
        if type(Feature.GetBondFilter) ~= "function" or type(Feature.Commands.SetSortMode) ~= "function"
            or type(Feature.Commands.SetBondFilterOption) ~= "function" or type(Feature.Commands.SetDuplicatePriority) ~= "function" then
            return false, "债券悬浮窗筛选命令缺失"
        end
        local bar = RSUI:HorizontalBox({ id = "v3_life_bonds_widget_toolbar", parent = content, gap = 4, slot = { size = "fixed", height = 28, hAlign = "fill" } })
        local function Apply(command)
            local ok, commandErr = command()
            if ok == true then instance:Refresh() end
            return ok, commandErr
        end
        instance.bondSortButton = RSUI:Button({ id = "v3_life_bonds_widget_sort", parent = bar, text = "数量序", compact = true, slot = { size = "fixed", width = 62 } })
        instance.bondSortButton.onClick = function()
            local state = Feature:GetBondFilter()
            return Apply(function() return Feature.Commands:SetSortMode(state.sortMode == "quantity" and "continent" or "quantity") end)
        end
        instance.bondFilterButtons = {}
        local function Toggle(id, label, key, width)
            local button = RSUI:Button({ id = id, parent = bar, text = label, compact = true, slot = { size = "fixed", width = width or 44 } })
            button.onClick = function()
                local state = Feature:GetBondFilter()
                return Apply(function() return Feature.Commands:SetBondFilterOption(key, not state[key]) end)
            end
            instance.bondFilterButtons[key] = button
            return button
        end
        Toggle("v3_life_bonds_widget_q20", "20", "q20", 38)
        Toggle("v3_life_bonds_widget_q60", "60", "q60", 38)
        Toggle("v3_life_bonds_widget_q100", "100", "q100", 42)
        Toggle("v3_life_bonds_widget_auroria", "原陆", "auroria", 48)
        Toggle("v3_life_bonds_widget_dedupe", "去重", "excludeSame", 48)
        instance.bondPriorityButton = RSUI:Button({ id = "v3_life_bonds_widget_priority", parent = bar, text = "优先西", compact = true, slot = { size = "fixed", width = 58 } })
        instance.bondPriorityButton.onClick = function()
            local state = Feature:GetBondFilter()
            return Apply(function() return Feature.Commands:SetDuplicatePriority(state.priority == "west" and "east" or "west") end)
        end
        return true
    end,
    refreshControls = function(instance, _, _, Feature)
        local state = Feature:GetBondFilter()
        if instance.bondSortButton then instance.bondSortButton:SetText(state.sortMode == "quantity" and "大陆序" or "数量序") end
        for key, button in pairs(instance.bondFilterButtons or {}) do
            local label = ({ q20 = "20", q60 = "60", q100 = "100", auroria = "原陆", excludeSame = "去重" })[key] or key
            button:SetText(label .. (state[key] and "✓" or "×"))
        end
        if instance.bondPriorityButton then instance.bondPriorityButton:SetText(state.priority == "east" and "优先东" or "优先西") end
    end,
    columns = {
        { id = "text", title = "居民板", field = "text", size = "fill", minWidth = 150, fill = 1 },
        { id = "quantity", title = "需", field = "quantity", size = "fixed", width = 42, minWidth = 36 },
        { id = "resource", title = "有", field = "resourceText", size = "fixed", width = 42, minWidth = 36 },
        { id = "shortage", title = "缺", field = "shortageText", size = "fixed", width = 42, minWidth = 36 },
        { id = "status", title = "状态", field = "statusText", size = "fixed", width = 72, minWidth = 58, getTone = function(item) return item and item.tone or "muted" end },
    },
    status = function(projection, rows)
        local extra = projection.resourceStatus and (" · 资源 " .. tostring(projection.resourceStatus)) or ""
        return tostring(#rows) .. " 条" .. extra
    end,
})
if ok ~= true then error(err) end

ok, err = Register({
    featureName = "Treasure", featureId = "life_treasure", widgetId = "life.treasure", token = "life_treasure", owner = "v3:widget:life_treasure",
    rootId = "v3_life_treasure_widget", contentId = "v3_life_treasure_widget_content", tableId = "v3_life_treasure_widget_table", title = "寻宝助手",
    emptyTitle = "没有可用藏宝图", emptyDetail = "背包中没有读取到带坐标的藏宝图。", selectable = true,
    rows = function(projection)
        local rows = projection.maps or {}
        for _, row in ipairs(rows) do row.directionText = tostring(row.direction or "--") .. (row.distance and (" · " .. tostring(math.floor(row.distance + 0.5)) .. "m") or "") end
        return rows
    end,
    onSelection = function(instance, row, Feature)
        if row == nil or row.key == nil then return false end
        local ok, err = Feature.Commands:Select(row.key); if ok then instance:Refresh() end; return ok, err
    end,
    columns = {
        { id="name", title="藏宝图", field="name", size="fill", minWidth=120, fill=1 },
        { id="direction", title="方向 / 距离", field="directionText", size="fixed", width=110, minWidth=90 },
    },
    status = function(projection, rows)
        local selected = projection.selected
        return selected and (tostring(selected.direction or "--") .. (selected.distance and (" · " .. tostring(math.floor(selected.distance + 0.5)) .. "m") or "")) or (tostring(#rows) .. " 张")
    end,
})
if ok ~= true then error(err) end

ok, err = Register({
    featureName = "Fishing", featureId = "life_fishing", widgetId = "life.fishing", token = "life_fishing", owner = "v3:widget:life_fishing",
    rootId = "v3_life_fishing_widget", contentId = "v3_life_fishing_widget_content", tableId = "v3_life_fishing_widget_table", title = "钓鱼助手",
    emptyTitle = "等待鱼动作", emptyDetail = "选中鱼后会根据已核动作 Buff 给出技能栏建议。",
    rows = function(projection) return { { key="fishing", message=projection.message or "等待鱼动作", buffText=projection.buffId and tostring(projection.buffId) or "--", slotText=projection.slot and tostring(projection.slot) or "--", statusText=projection.status or "--" } } end,
    columns = {
        { id="message", title="当前动作 / 建议", field="message", size="fill", minWidth=150, fill=1 },
        { id="slot", title="技能栏", field="slotText", size="fixed", width=58, minWidth=50 },
        { id="buff", title="动作ID", field="buffText", size="fixed", width=70, minWidth=60 },
    },
    status = function(projection) return tostring(projection.message or projection.status or "等待鱼动作") end,
})
if ok ~= true then error(err) end

S.UIV3 = S.UIV3 or {}
S.UIV3.LifeEconomyWidgetsV3 = { version = 3, widgetIds = { "life.trade", "life.bonds", "life.treasure", "life.fishing" } }

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
            if self.visible then
                local released, releaseErr = ReleaseConsumer()
                if released ~= true then return false, releaseErr end
                self.visible = false; self:Unsubscribe()
            end
            self.surface:Show(false)
            if type(context) ~= "table" or context.persist ~= false then Feature.Commands:SetWidgetVisible(false, "hide") end
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
        local row = RSUI:HorizontalBox({ id = "v3_life_trade_widget_route", parent = content, gap = 4, slot = { size = "fixed", height = 30, hAlign = "fill" } })
        instance.fromDropdown = RSUI:Dropdown({ id = "v3_life_trade_widget_from", parent = row, items = {}, maxVisible = 10, popupWidth = 220,
            get = function() return (Feature:GetRouteSettings() or {}).fromZone end, set = function(v) return Feature.Commands:SetFrom(v) end, slot = { size = "fill", fill = 1, minWidth = 100 } })
        instance.toDropdown = RSUI:Dropdown({ id = "v3_life_trade_widget_to", parent = row, items = {}, maxVisible = 10, popupWidth = 220,
            get = function() return (Feature:GetRouteSettings() or {}).toZone end, set = function(v) return Feature.Commands:SetTo(v) end, slot = { size = "fill", fill = 1, minWidth = 100 } })
        local fp = RSUI:Button({ id = "v3_life_trade_widget_from_prev", parent = row, text = "起◀", compact = true, slot = { size = "fixed", width = 40 } })
        local fn = RSUI:Button({ id = "v3_life_trade_widget_from_next", parent = row, text = "起▶", compact = true, slot = { size = "fixed", width = 40 } })
        local tp = RSUI:Button({ id = "v3_life_trade_widget_to_prev", parent = row, text = "终◀", compact = true, slot = { size = "fixed", width = 40 } })
        local tn = RSUI:Button({ id = "v3_life_trade_widget_to_next", parent = row, text = "终▶", compact = true, slot = { size = "fixed", width = 40 } })
        local function cycle(command, delta) local ok, err = command(Feature.Commands, delta); if ok then instance:Refresh() end; return ok, err end
        fp.onClick=function() return cycle(Feature.Commands.CycleFrom,-1) end; fn.onClick=function() return cycle(Feature.Commands.CycleFrom,1) end
        tp.onClick=function() return cycle(Feature.Commands.CycleTo,-1) end; tn.onClick=function() return cycle(Feature.Commands.CycleTo,1) end
        for _, b in ipairs({fp,fn,tp,tn}) do if b.root then S.UI:SafeHandler(b.root,"OnClick",b.onClick,"v3_life_trade_widget:"..tostring(b.id)) end end
        return instance.fromDropdown ~= nil and instance.toDropdown ~= nil, "跑商悬浮窗路线控件创建失败"
    end,
    refreshControls = function(instance, projection)
        local fromItems, toItems = ZoneItems(projection.zones), ZoneItems(projection.sellableZones)
        if instance.fromDropdown then instance.fromDropdown:SetItems(fromItems); instance.fromDropdown:SetEnabled(#fromItems>0); instance.fromDropdown:Render() end
        if instance.toDropdown then instance.toDropdown:SetItems(toItems); instance.toDropdown:SetEnabled(#toItems>0); instance.toDropdown:Render() end
    end,
    columns = {
        { id = "name", title = "货物", field = "name", size = "fill", minWidth = 120, fill = 1 },
        { id = "rate", title = "货率", field = "rate", size = "fixed", width = 58, minWidth = 50, getTone = function(item) return item and item.tone or "muted" end },
        { id = "price", title = "售价", field = "price", size = "fixed", width = 82, minWidth = 64 },
        { id = "profit", title = "毛利", field = "profit", size = "fixed", width = 90, minWidth = 68 },
    },
    status = function(projection, rows)
        return FindZoneName(projection, projection.fromZone) .. " → " .. FindZoneName(projection, projection.toZone) .. " · " .. tostring(#rows) .. " 种"
    end,
})
if ok ~= true then error(err) end

ok, err = Register({
    featureName = "Bonds", featureId = "life_bonds", widgetId = "life.bonds", token = "life_bonds", owner = "v3:widget:life_bonds",
    rootId = "v3_life_bonds_widget", contentId = "v3_life_bonds_widget_content", tableId = "v3_life_bonds_widget_table", title = "债券 / 居民板",
    emptyTitle = "暂无居民板条目", emptyDetail = "居民板事实不可用或当前筛选没有条目。",
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
S.UIV3.LifeEconomyWidgetsV3 = { version = 2, widgetIds = { "life.trade", "life.bonds", "life.treasure", "life.fishing" } }

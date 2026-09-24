-- 维护（2026-09-18，startup-source-recovery）：本文件在故障包中有 3 处未解决的 Git 合并冲突。
-- 已对照用户此前完整 V3 工程恢复有效实现；Authority、调用数据流和存档协议仍由下方原实现负责，
-- 不通过清配置、跳过加载或恢复 Legacy 绕过错误。兼容边界：须与完整 toc.g 及 .18.247 UI 配套；
-- 后续合并必须先检查冲突标记、清单完整性与 Lua 语法，再做运行时验收；注释不增加运行期开销。
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

-- 中文维护注释（2026-09-24，债券悬浮窗筛选下拉）：与主页面共享同一业务 value 语义，
-- 但 Presentation 实例各自拥有 Native Dropdown；Feature/Store 是唯一状态 Authority，不 Reparent 控件。
local BOND_ORDER_ITEMS = {
    { value = "continent:west_first", text = "按大陆 · 西→东" },
    { value = "continent:east_first", text = "按大陆 · 东→西" },
    { value = "quantity:west_first", text = "按数量 · 少→多" },
    { value = "quantity:east_first", text = "按数量 · 多→少" },
    { value = "material:west_first", text = "按材料 · 正序" },
    { value = "material:east_first", text = "按材料 · 倒序" },
}
local function BondScopeLabel(mask)
    if mask == 15 then return "全部 · 20/60/100/原陆" end
    if mask == 7 then return "主大陆 · 20/60/100" end
    if mask == 8 then return "仅原大陆" end
    if mask == 0 then return "全部关闭" end
    local parts = {}
    if mask % 2 >= 1 then parts[#parts + 1] = "20" end
    if math.floor(mask / 2) % 2 >= 1 then parts[#parts + 1] = "60" end
    if math.floor(mask / 4) % 2 >= 1 then parts[#parts + 1] = "100" end
    if math.floor(mask / 8) % 2 >= 1 then parts[#parts + 1] = "原陆" end
    return "筛选 · " .. table.concat(parts, "+")
end
local BOND_SCOPE_ITEMS = {}
for _, mask in ipairs({ 15, 7, 8, 1, 2, 4, 3, 5, 6, 9, 10, 12, 11, 13, 14, 0 }) do
    BOND_SCOPE_ITEMS[#BOND_SCOPE_ITEMS + 1] = { value = mask, text = BondScopeLabel(mask) }
end
local BOND_DUPLICATE_ITEMS = {
    { value = "all", text = "重复 · 全部" },
    { value = "west", text = "重复 · 留西" },
    { value = "east", text = "重复 · 留东" },
}

-- 维护（overview-content-1）：页面与悬浮窗共用内容构建器而非Reparent原生窗口。
-- 每个实例独立id/owner/控件，Feature投影/Command唯一，构建和刷新绝不发出材料询价。
local Contents={specs={}}
S.UIV3.LifeEconomyContent=Contents
local function BuildBody(instance,parent,spec,Feature)
        local content = RSUI:VerticalBox({ id = instance.contentPrefix .. "content", parent = parent, gap = 4,
            slot = { size="fill", fill=1, hAlign = "fill", vAlign = "fill" } }) -- 填满卡片余量，否则auto只给空表一行高度。
        instance.content=content
        instance.controls=RSUI:VerticalBox({id=instance.contentPrefix.."controls",parent=content,gap=3,slot={size="auto",hAlign="fill"}})
        if type(spec.buildControls) == "function" then
            local controlsOk, controlsErr = spec.buildControls(instance, instance.controls, Feature)
            if controlsOk == false then return nil, controlsErr or (spec.title .. "悬浮窗控制条创建失败") end
        end
        -- 维护（2026-09-24，trade-floating-native-budget-2）：TableView 的 desiredRows/overscan 会决定首次
        -- Refresh 时需要建立的可复用 Native 行池。18.298 为跑商悬浮窗恢复“添加/移除收藏”独立行后，数据区比
        -- 18.297 少约 30px，因此 Trade HUD 行池同步从 7 收到 6，避免为了恢复一个轻量 Button 又把首次 Native
        -- 分配峰值抬回去。ListView 仍通过复用/滚动访问全部数据，Trade Authority/rows 完全不裁剪。
        -- 中文维护注释（2026-09-24，债券窄窗预算）：Bonds 控制条现在为两行 Dropdown 以兼容 280px
        -- 最小悬浮宽度，因此把初始 Native 行池从 10 收到 7；滚动/复用仍可访问全部 rows，不裁业务数据。
        local desiredRows = instance.overview and 6 or (spec.featureName == "Trade" and 6 or 10)
        if instance.overview ~= true and spec.featureName == "Bonds" then desiredRows = 7 end
        local overscanRows = spec.featureName == "Trade" and 0 or 1
        instance.table = RSUI:TableView({
            id = instance.contentPrefix .. "table", parent = content, items = {}, rowHeight = instance.overview and 26 or 24, headerHeight = instance.overview and 26 or 23, desiredRows = desiredRows,
            rowFitMode = spec.featureName == "Trade" and "adaptive_tail" or "fixed", rowFitMin = instance.overview and 22 or 20, rowFitMax = instance.overview and 30 or 28,
            overscan = overscanRows, scrollbar = true, selectable = spec.selectable == true, selectionMode = "single", columnResize = true, headerInteractive = false,
            columns = S.Utils.DeepCopy(spec.columns), slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
        })
        if spec.selectable == true and type(spec.onSelection) == "function" then
            instance.table.onSelectionChanged = function(index)
                local row = instance.table:GetItem(index)
                return spec.onSelection(instance, row, Feature)
            end
        end
        if type(spec.onItemActivated) == "function" then
            -- 中文维护注释（table-activation-contract-1）：RSUI TableView 的真实回调签名为
            -- (item,index,key,view,reason)。旧实现把第一个 item 当成 index，在简化 mock 中能通过、
            -- 实机双击却取不到行。Presentation 直接消费 item；仅在兼容旧测试/调用方时按 index 回退。
            instance.table.onItemActivated = function(item, index, key, view, reason)
                local row = item
                if type(row) ~= "table" and tonumber(index) ~= nil then row = instance.table:GetItem(index) end
                return spec.onItemActivated(instance, row, Feature, reason)
            end
        end

    return true
end
local function RefreshBody(self,spec,Feature)
            local projection = Feature:GetProjection() or {}
            local rows = type(spec.rows) == "function" and spec.rows(projection) or (projection.rows or {})
            rows = type(rows) == "table" and rows or {}
            self.table:SetItems(rows, projection.revision or 0)
            -- 维护（2026-09-24，life-widget-control-refresh-isolation-1）：Feature Projection/rows 与顶部交互控件属于
            -- 两个不同的 Presentation 子域。18.297 中任一 Dropdown/按钮同步异常都会从 refreshControls 抛出，导致整个
            -- RefreshBody 中止；即使 Authority 已有正确路线数据，TableView 仍停在默认“暂无数据”，Show() 最终只显示
            -- “数据刷新失败”。现在单独隔离控件同步：失败只降级顶部控件并记模块诊断，数据表与状态继续消费已经取得的
            -- detached Projection。这里不吞 Authority/TableView 错误，也不创建轮询/重试，因此不会形成第二数据 Authority。
            local controlRefreshFailed, controlRefreshError = false, nil
            if type(spec.refreshControls) == "function" then
                local controlOk, controlResult, controlErr = xpcall(function()
                    return spec.refreshControls(self, projection, rows, Feature)
                end, S.SafeTraceback)
                if controlOk ~= true or controlResult == false then
                    controlRefreshFailed = true
                    controlRefreshError = controlOk and controlErr or controlResult
                    local diagnostics = S.DiagnosticsManager
                    if type(diagnostics) == "table" and type(diagnostics.WarnRateLimited) == "function" then
                        diagnostics:WarnRateLimited("ui_v3", "LIFE_WIDGET_CONTROL_REFRESH_FAILED", 3000,
                            spec.title .. "悬浮窗顶部控件同步失败；数据表继续显示现有投影", {
                                featureId = tostring(spec.featureId or ""), widgetId = tostring(spec.widgetId or ""),
                                phase = "refresh_controls", error = tostring(controlRefreshError or "unknown"),
                            })
                    end
                end
            end
            if projection.status == "unavailable" or projection.status == "error" then
                self.table:SetViewState("unavailable", { title = spec.title .. "数据不可用", detail = tostring(projection.error or "事实读取失败") })
            elseif spec.featureName == "Trade" and projection.status == "loading" and #rows == 0 then
                -- 中文维护注释（trade-native-cooldown-1）：货率查询是异步 Native 事件。旧 UI 在 loading 时仍显示“暂无货率”，
                -- 用户会误以为刷新按钮无效并连续点击，从而更容易撞服务器冷却。只改变 Presentation 文案；请求节流仍由 Trade Authority 所有。
                self.table:SetViewState("empty", { title = "正在查询货率", detail = "等待服务器返回货率；无需连续点击刷新。" })
            elseif spec.featureName == "Trade" and projection.status == "cooldown" and #rows == 0 then
                local remaining = math.max(0, tonumber(projection.cooldownRemainingMs) or 0)
                self.table:SetViewState("empty", { title = "等待服务器查询冷却", detail = "约 " .. tostring(math.ceil(remaining / 1000)) .. " 秒后自动重试。" })
            elseif spec.featureName == "Trade" and projection.viewMode == "cargo" and #rows == 0 then
                local cargo = projection.cargo or {}
                local title = cargo.status == "not_trade" and "背部不是已识别贸易品" or (cargo.status == "empty" and "当前没有背负贸易品" or "随身贸易品暂无目的地货率")
                self.table:SetViewState("empty", { title = title, detail = tostring(cargo.error or "背上贸易包后会自动识别，并串行刷新可售目的地。") })
            elseif spec.featureName == "Trade" and projection.viewMode == "tracked" and #rows == 0 then
                -- 维护（2026-09-23，trade-view-help-1）：空的“关注货物”不能伪装成“暂无货率”，否则新用户不知道如何产生数据。
                self.table:SetViewState("empty", { title = "还没有关注货物", detail = "切回“当前路线全部货物”，单击选择一行后点“关注货物”。" })
            elseif #rows == 0 then
                self.table:SetViewState("empty", { title = spec.emptyTitle, detail = spec.emptyDetail })
            else
                self.table:SetViewState("ready")
            end
            -- 首页仅压缩重复说明；保留来源错误，报价 Authority 仍在共享 Feature。
            local statusText = spec.status(projection, rows)
            if self.overview and spec.featureName == "Trade" then
                local batch = projection.quoteBatch or {}
                statusText = tostring(#rows) .. " 种货物 · 待询价 " .. tostring(projection.pendingQuoteCount or 0)
                    .. (batch.active and (" · 正在询价 " .. tostring(batch.completed or 0) .. "/" .. tostring(batch.total or 0))
                        or (" · 每批最多4项"))
                if projection.status == "error" or projection.status == "unavailable" then statusText=tostring(projection.error or "货率读取失败") end
            end
            local statusTone = projection.status == "ready" and "accent" or (projection.status == "loading" and "yellow" or "muted")
            if controlRefreshFailed then
                statusText = tostring(statusText or "数据已更新") .. " · 顶部控件同步异常"
                statusTone = "yellow"
            end
            self.surface:SetStatus(statusText, statusTone)
            return true
        end

-- overview 仅是显示密度，不持有额外消费者、报价缓存或保存副本。
-- 同一查询按钮在首页批次进行中可取消；高级搜索继续留在完整页面/原悬浮窗。
function Contents:Create(parent,name,prefix,options)
    local spec=self.specs[name];local Feature=S.Features and S.Features[name]
    if not spec or not Feature then return nil,"经济内容不可用："..tostring(name) end
    local instance={contentPrefix=prefix,visible=true,overview=type(options)=="table" and options.overview==true}
    local ok,err=BuildBody(instance,parent,spec,Feature);if not ok then return nil,err end
    local status=RSUI:Text({id=prefix.."status",parent=instance.content,text="--",fontSize=9,tone="muted",overflow="ellipsis",slot={size="fixed",height=18}})
    instance.surface={SetStatus=function(_,v)status:SetText(v);return true end}
    function instance:Refresh()return RefreshBody(self,spec,Feature)end
    function instance:SetAvailable(available,reason)
        self.controls:SetVisible(available)
        if available then return self:Refresh() end
        self.table:SetItems({},"unavailable");self.table:SetViewState("empty",{title=reason or "未启用",detail="点击右上角打开功能页面；首页不会自动启用模块。"})
        status:SetText(reason or "未启用");return true
    end
    return instance
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

    Contents.specs[spec.featureName]=spec

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
        instance.contentPrefix=spec.rootId.."_"
        local bodyOk,bodyErr=BuildBody(instance,surface:GetContentRoot(),spec,Feature)
        if not bodyOk then return nil,bodyErr end
        function instance:Refresh()return RefreshBody(self,spec,Feature)end
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
        local function ReportOpenIssue(level, code, message, phase, detail, acquired)
            local diagnostics = S.DiagnosticsManager
            local fn = type(diagnostics) == "table" and diagnostics[level] or nil
            if type(fn) ~= "function" then return false end
            -- 维护（2026-09-24，life-widget-open-transaction-2）：悬浮窗属于 Presentation，但诊断必须显式带
            -- featureId/widgetId，才能归属到对应模块。该函数只在用户打开/持久化失败边沿执行，不进入刷新热路径。
            fn(diagnostics, "ui_v3", code, message, {
                featureId = featureId, widgetId = tostring(spec.widgetId or ""), route = tostring(spec.widgetId or ""),
                phase = tostring(phase or "unknown"), consumerAcquired = tostring(acquired == true), error = tostring(detail or ""),
            })
            return true
        end
        function instance:Show(context)
            if self.visible then
                local shown, showErr = self.surface:Show(true)
                if shown ~= true then return false, showErr end
                local refreshOk, refreshResult, refreshErr = xpcall(function() return self:Refresh() end, S.SafeTraceback)
                if refreshOk ~= true or refreshResult == false then
                    ReportOpenIssue("Warn", "LIFE_WIDGET_REFRESH_FAILED", spec.title .. "悬浮窗刷新失败，窗口保持打开", "refresh_visible",
                        refreshOk and refreshErr or refreshResult, true)
                    self.surface:SetStatus("数据刷新失败，可稍后重试", "yellow")
                end
                return true
            end

            local acquired = false
            local phase = "feature_gate"
            -- 维护（2026-09-24，life-widget-open-transaction-2）：打开事务只覆盖“Feature 可用 -> 订阅 -> Consumer
            -- lease -> Native Surface 显示”。数据投影刷新不再属于可见性提交条件。旧顺序先 Refresh 后 Show，任意一次
            -- Presentation 刷新异常都会回滚 Consumer 并隐藏窗口，外观上就是“按钮无反应”；更严重的是错误细节还被通用
            -- “悬浮窗显示失败”覆盖。现在先提交可见 Surface，再以独立保护域刷新内容，Authority 与资源释放仍保持对称。
            local ok, openErr = xpcall(function()
                if not (S.FeatureRuntime and S.FeatureRuntime:IsEnabled(featureId) == true) then error(spec.title .. "功能已关闭") end
                phase = "subscribe"
                local subscribeOk, subscribeErr = self:Subscribe()
                if subscribeOk ~= true then error(subscribeErr or (spec.title .. "事件订阅失败")) end
                phase = "acquire_consumer"
                local acquireOk, acquireErr = Feature:AcquireConsumer("widget:" .. spec.token)
                if acquireOk ~= true then error(acquireErr or (spec.title .. " Consumer 获取失败")) end
                acquired = true
                phase = "surface_show"
                local shown, showErr = self.surface:Show(true)
                if shown ~= true then error(spec.title .. "悬浮窗显示失败：" .. tostring(showErr or "unknown")) end
            end, S.SafeTraceback)
            if ok ~= true then
                local rollbackHideOk, rollbackHideErr = self.surface:Show(false)
                self:Unsubscribe()
                if acquired then Feature:ReleaseConsumer("widget:" .. spec.token) end
                self.visible = false
                ReportOpenIssue("Error", "LIFE_WIDGET_OPEN_FAILED", spec.title .. "悬浮窗打开失败", phase,
                    tostring(openErr or "unknown") .. (rollbackHideOk ~= true and (" | rollbackHide=" .. tostring(rollbackHideErr or "failed")) or ""), acquired)
                return false, openErr
            end

            self.visible = true
            phase = "refresh_after_show"
            local refreshOk, refreshResult, refreshErr = xpcall(function() return self:Refresh() end, S.SafeTraceback)
            if refreshOk ~= true or refreshResult == false then
                -- 内容刷新是 Projection 层失败，不能夺走已经成功建立的窗口/Consumer 生命周期。
                -- 保留窗口让用户仍可关闭/重置布局，并把根因写入模块诊断；后续正常 Feature 更新会再次 Refresh。
                ReportOpenIssue("Warn", "LIFE_WIDGET_REFRESH_FAILED", spec.title .. "悬浮窗已打开，但首次数据刷新失败", phase,
                    refreshOk and refreshErr or refreshResult, acquired)
                self.surface:SetStatus("数据刷新失败，可稍后重试", "yellow")
            end
            if type(context) ~= "table" or context.persist ~= false then
                local persistOk, persistErr = Feature.Commands:SetWidgetVisible(true, "show")
                if persistOk ~= true then
                    -- 可见性已经由 Host/Native 成功提交；存档失败只影响下次自动恢复，不能反向隐藏当前窗口造成双 Authority。
                    ReportOpenIssue("Warn", "LIFE_WIDGET_VISIBILITY_PERSIST_FAILED", spec.title .. "悬浮窗已打开，但可见偏好保存失败",
                        "persist_visibility", persistErr, acquired)
                end
            end
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
            or type(Feature.Commands.SetViewMode) ~= "function" or type(Feature.Commands.SelectFavorite) ~= "function"
            or type(Feature.Commands.ToggleCurrentFavorite) ~= "function" or type(Feature.Commands.ToggleTrackedProduct) ~= "function"
            or type(Feature.Commands.QuoteRowMaterials) ~= "function" then
            return false, "跑商悬浮窗 Feature 路线/显示/收藏/关注/单行询价命令缺失"
        end

        -- 维护（2026-09-24，trade-floating-favorite-restore-1）：18.297 为压缩 Native 预算把“新增/移除当前路线收藏”
        -- 从 HUD 一并删掉，只留下收藏路线下拉选择，造成常用闭环断裂。收藏是 Feature Authority 中已经存在的轻量命令，
        -- 不应为了节省一个 Button 而强迫用户回主页面。浮窗恢复第三个紧凑行：路线；收藏选择+添加/移除；显示范围+关注。
        -- 首页 overview 继续保持两行密度，不复制收藏管理按钮。所有状态仍来自同一个 Trade Projection/Commands，旧 Store 不变。
        local floatingFavoriteManagement = instance.overview ~= true
        local routeControlHeight = floatingFavoriteManagement and 88 or 58
        local routeBox = RSUI:VerticalBox({
            id = (instance.contentPrefix or "v3_life_trade_widget_") .. "route", parent = content, gap = 2,
            slot = { size = "fixed", height = routeControlHeight, hAlign = "fill" },
        })
        instance.routeBox = routeBox
        instance.routeControlHeight = routeControlHeight

        local routeRow = RSUI:HorizontalBox({
            id = (instance.contentPrefix or "v3_life_trade_widget_") .. "route_row", parent = routeBox, gap = 4,
            slot = { size = "fixed", height = 28, hAlign = "fill" },
        })
        instance.fromDropdown = RSUI:Dropdown({
            id = (instance.contentPrefix or "v3_life_trade_widget_") .. "from", parent = routeRow, items = {}, maxVisible = 6,
            popupWidth = 210, placeholder = "起点",
            get = function() return (Feature:GetRouteSettings() or {}).fromZone end,
            set = function(v) return Feature.Commands:SetFrom(v) end,
            slot = { size = "fill", fill = 1, minWidth = 92 },
        })
        RSUI:Text({
            id = (instance.contentPrefix or "v3_life_trade_widget_") .. "route_arrow", parent = routeRow, text = "→", fontSize = 9, tone = "muted",
            slot = { size = "fixed", width = 14 },
        })
        instance.toDropdown = RSUI:Dropdown({
            id = (instance.contentPrefix or "v3_life_trade_widget_") .. "to", parent = routeRow, items = {}, maxVisible = 6,
            popupWidth = 210, placeholder = "目的地",
            get = function() return (Feature:GetRouteSettings() or {}).toZone end,
            set = function(v) return Feature.Commands:SetTo(v) end,
            slot = { size = "fill", fill = 1, minWidth = 92 },
        })
        instance.refreshButton = RSUI:Button({
            id = (instance.contentPrefix or "v3_life_trade_widget_") .. "refresh", parent = routeRow, text = "刷新", compact = true,
            slot = { size = "fixed", width = 48 },
        })
        instance.refreshButton.onClick = function()
            local reason = instance.overview and "overview_manual" or "widget_manual"
            local ok, refreshErr = Feature.Commands:Refresh(reason)
            if ok == true then instance:Refresh() end
            return ok, refreshErr
        end

        local favoriteRow = RSUI:HorizontalBox({
            id = (instance.contentPrefix or "v3_life_trade_widget_") .. "favorite_row", parent = routeBox, gap = 4,
            slot = { size = "fixed", height = 28, hAlign = "fill" },
        })
        instance.favoriteDropdown = RSUI:Dropdown({
            id = (instance.contentPrefix or "v3_life_trade_widget_") .. "favorite", parent = favoriteRow, items = {}, maxVisible = 6,
            popupWidth = 230, placeholder = "收藏路线",
            get = function()
                local projection = Feature:GetProjection() or {}
                return projection.currentRouteFavorite and projection.currentFavoriteKey or nil
            end,
            set = function(value)
                local ok, commandErr = Feature.Commands:SelectFavorite(value)
                if ok == true then instance:Refresh() end
                return ok, commandErr
            end,
            slot = { size = "fill", fill = 1.25, minWidth = 120 },
        })
        if floatingFavoriteManagement then
            instance.favoriteButton = RSUI:Button({
                id = (instance.contentPrefix or "v3_life_trade_widget_") .. "favorite_toggle", parent = favoriteRow,
                text = "添加收藏", compact = true, slot = { size = "fixed", width = 82 },
            })
            instance.favoriteButton.onClick = function()
                local ok, favoriteErr = Feature.Commands:ToggleCurrentFavorite()
                if ok == true then instance:Refresh() end
                return ok, favoriteErr
            end
        end

        local modeRow = favoriteRow
        if floatingFavoriteManagement then
            modeRow = RSUI:HorizontalBox({
                id = (instance.contentPrefix or "v3_life_trade_widget_") .. "mode_row", parent = routeBox, gap = 4,
                slot = { size = "fixed", height = 28, hAlign = "fill" },
            })
        end
        -- 维护（2026-09-24，trade-floating-native-budget-2）：显示模式固定只有 3 个值，继续使用无 popup 的
        -- SegmentedSelector。恢复收藏能力只增加一个 Button，不恢复旧排序/显示 Dropdown，避免 Native Window 预算回退。
        instance.viewSelector = RSUI:SegmentedSelector({
            id = (instance.contentPrefix or "v3_life_trade_widget_") .. "view_mode", parent = modeRow,
            items = {
                { value = "all", text = "全部" },
                { value = "tracked", text = "关注" },
                { value = "cargo", text = "随身" },
            },
            itemWidth = 40, gap = 2, height = 26, fontSize = 9,
            get = function() return (Feature:GetProjection() or {}).viewMode or "all" end,
            set = function(value)
                local ok, commandErr = Feature.Commands:SetViewMode(value)
                if ok == true then instance:Refresh() end
                return ok, commandErr
            end,
            slot = { size = "fixed", width = 124, vAlign = "fill" },
        })
        instance.trackButton = RSUI:Button({
            id = (instance.contentPrefix or "v3_life_trade_widget_") .. "track", parent = modeRow, text = "关注货物", compact = true,
            slot = { size = "fixed", width = 74 },
        })
        instance.trackButton.onClick = function()
            local row = type(Feature.GetSelectedRow) == "function" and Feature:GetSelectedRow() or nil
            if type(row) ~= "table" or row.key == nil then return false, "请先单击选择一个货物" end
            local ok, trackErr = Feature.Commands:ToggleTrackedProduct(row.itemType or row.key)
            if ok == true then instance:Refresh() end
            return ok, trackErr
        end

        return instance.fromDropdown ~= nil and instance.toDropdown ~= nil and instance.favoriteDropdown ~= nil
            and (instance.overview == true or instance.favoriteButton ~= nil)
            and instance.viewSelector ~= nil and instance.trackButton ~= nil,
            "跑商悬浮窗紧凑控制条创建失败"
    end,
    refreshControls = function(instance, projection, rows, Feature)
        -- 维护（2026-09-24，trade-widget-feature-arg-1）：RefreshBody 明确以第四参数传入 Feature；
        -- 18.298 恢复“关注货物”按钮后这里仍保留旧的二参签名，Lua 因而把 Feature 解析成 nil 全局，
        -- 每次路线/报价 Publish 都会触发 LIFE_WIDGET_CONTROL_REFRESH_FAILED。Presentation 只消费传入的
        -- Feature Command/read-model，不缓存第二份 Domain 状态；rows 参数保留统一 WidgetSpec 签名但不持有。
        local fromItems, toItems = ZoneItems(projection.zones), ZoneItems(projection.sellableZones)
        local routeControlsEnabled = projection.viewMode ~= "cargo"
        if instance.fromDropdown then
            instance.fromDropdown:SetItems(fromItems)
            instance.fromDropdown:SetEnabled(routeControlsEnabled and #fromItems > 0)
            instance.fromDropdown:Render()
        end
        if instance.toDropdown then
            instance.toDropdown:SetItems(toItems)
            instance.toDropdown:SetEnabled(routeControlsEnabled and #toItems > 0)
            instance.toDropdown:Render()
        end
        if instance.refreshButton then
            instance.refreshButton:SetEnabled(projection.viewMode == "cargo" or (projection.fromZone ~= nil and projection.toZone ~= nil))
            if projection.isRefreshing == true then instance.refreshButton:SetText("刷新中") else instance.refreshButton:SetText("刷新") end
        end
        local favoriteItems = type(projection.favoriteItems) == "table" and projection.favoriteItems or {}
        if instance.favoriteDropdown then
            instance.favoriteDropdown:SetItems(favoriteItems)
            instance.favoriteDropdown:SetEnabled(routeControlsEnabled and #favoriteItems > 0)
            instance.favoriteDropdown:Render()
        end
        if instance.favoriteButton then
            -- 维护（2026-09-24，trade-floating-favorite-restore-1）：按钮只提交当前 from/to 的收藏切换；
            -- 文案完全由 Projection 的 currentRouteFavorite 回读，Presentation 不缓存第二份收藏状态。
            local canFavorite = routeControlsEnabled and projection.fromZone ~= nil and projection.toZone ~= nil
            instance.favoriteButton:SetEnabled(canFavorite)
            instance.favoriteButton:SetText(projection.currentRouteFavorite == true and "移除收藏" or "添加收藏")
        end
        if instance.viewSelector then
            instance.viewSelector:SetEnabled(true)
            instance.viewSelector:Render()
        end
        if instance.trackButton then
            local row = type(Feature.GetSelectedRow) == "function" and Feature:GetSelectedRow() or nil
            local canTrack = type(row) == "table" and (tonumber(row.itemType) ~= nil or row.key ~= nil)
            instance.trackButton:SetEnabled(canTrack)
            instance.trackButton:SetText(canTrack and (row.tracked == true and "取消关注" or "关注货物") or "关注货物")
        end
    end,
    selectable = true,
    onSelection = function(instance, row, Feature)
        -- 维护（2026-09-23，trade-row-double-click-2）：单击只选择，但要立即同步“关注货物”按钮状态；
        -- 不弹详情、不发询价，第二次点击仍能稳定进入同一行的双击识别。
        if type(row) ~= "table" or row.key == nil then return false end
        if type(Feature.Commands.SelectRow) ~= "function" then return true end
        local ok, selectErr = Feature.Commands:SelectRow(row.key)
        if ok == true and instance.trackButton then
            local selected = type(Feature.GetSelectedRow) == "function" and Feature:GetSelectedRow() or row
            instance.trackButton:SetEnabled(type(selected) == "table")
            instance.trackButton:SetText(type(selected) == "table" and selected.tracked == true and "取消关注" or "关注货物")
        end
        return ok, selectErr
    end,
    onItemActivated = function(instance, row, Feature)
        if type(row) ~= "table" or row.key == nil then return false end
        -- RSUI ListView 的 activated 回调当前按每次 row click 触发；Trade 在 Presentation 层做 opt-in 双击识别，
        -- 不改变其他 TableView 的单击激活契约。状态只保存在这个悬浮窗实例，不进入 Feature/配置存档。
        local now = type(S.NowMs) == "function" and tonumber(S.NowMs()) or 0
        local key = tostring(row.key)
        local previousAt = tonumber(instance.tradeLastActivateAt) or -100000
        local isDouble = instance.tradeLastActivateKey == key and now >= previousAt and (now - previousAt) <= 450
        instance.tradeLastActivateKey, instance.tradeLastActivateAt = key, now
        if not isDouble then return true end
        instance.tradeLastActivateKey, instance.tradeLastActivateAt = nil, 0
        local ok, quoteErr = Feature.Commands:QuoteRowMaterials(row.key)
        if ok == true then
            instance:Refresh()
        elseif instance.surface ~= nil and type(instance.surface.SetStatus) == "function" then
            instance.surface:SetStatus("无法查询毛利：" .. tostring(quoteErr or "材料不可询价"), "yellow")
        end
        return ok, quoteErr
    end,
    columns = {
        { id = "name", title = "货物", field = "name", size = "fill", minWidth = 108, fill = 1 }, -- 中文维护注释：货物列仍负责吸收剩余宽度，仅略降最小值以支持 320px 紧凑窗口。
        { id = "rate", title = "货率", field = "rate", size = "fixed", width = 54, minWidth = 48, getTone = function(item) return item and item.tone or "muted" end }, -- 中文维护注释：货率列收紧但保留原 tone 规则，不改变 130%/实时货率业务判断。
        { id = "price", title = "售价", field = "price", size = "fixed", width = 74, minWidth = 60 }, -- 中文维护注释：售价列缩窄到可读金币文本预算，字段来源仍是 Authority 已计算结果。
        { id = "profit", title = "毛利", field = "profit", size = "fixed", width = 78, minWidth = 64 }, -- 中文维护注释：毛利列仅调整 Presentation 宽度，不更改材料成本/询价公式。
    },
    status = function(projection, rows)
        -- 维护（2026-09-23，trade-floating-status-density-2）：悬浮窗底部只显示当前动作/下一步操作，
        -- 不再重复路线、排序、熟练度、计数等已经能从控件或表格看出的信息。
        if projection.status == "error" or projection.status == "unavailable" then
            return tostring(projection.error or "跑商数据不可用")
        end
        local batch = projection.quoteBatch or {}
        if batch.active == true then
            local label = tostring(batch.label or "所选货物")
            return "正在查询「" .. label .. "」材料 " .. tostring(batch.completed or 0) .. "/" .. tostring(batch.total or 0) .. " · 毛利会自动更新"
        end
        local remaining = math.max(0, tonumber(projection.cooldownRemainingMs) or 0)
        if projection.routeStatus == "cooldown" and remaining > 0 then
            return "路线已切换 · 服务器冷却约 " .. tostring(math.ceil(remaining / 1000)) .. " 秒后自动读取"
        end
        if projection.isRefreshing == true then return "正在刷新货率 · 当前列表会保留上一份可用数据" end
        if projection.viewMode == "tracked" then return "只看关注货物 · 单击选择可关注/取消关注 · 双击查询毛利" end
        if projection.viewMode == "cargo" then
            local cargo = projection.cargo or {}
            return "随身贸易包：" .. tostring(cargo.name or cargo.legacyName or "未识别") .. " · 自动比较目的地"
        end
        local age = tonumber(projection.ratioAgeMs)
        local ageText = age ~= nil and age >= 10000 and (" · 数据" .. tostring(math.floor(age / 1000)) .. "秒前") or ""
        return "单击选择货物 · 双击查询材料并计算毛利" .. ageText
    end,
})
if ok ~= true then error(err) end

ok, err = Register({
    featureName = "Bonds", featureId = "life_bonds", widgetId = "life.bonds", token = "life_bonds", owner = "v3:widget:life_bonds",
    rootId = "v3_life_bonds_widget", contentId = "v3_life_bonds_widget_content", tableId = "v3_life_bonds_widget_table", title = "债券 / 居民板",
    emptyTitle = "暂无居民板条目", emptyDetail = "居民板事实不可用或当前筛选没有条目。",
    selectable = true,
    onSelection = function(instance, row, Feature)
        if row == nil or row.key == nil then return false end
        if type(Feature.Commands.SelectRow) == "function" then
            return Feature.Commands:SelectRow(row.key)
        end
        return true
    end,
    onItemActivated = function(instance, row, Feature)
        if row == nil then return false end
        local floating = S.UIV3 and S.UIV3.QuestDetailFloatingV3 or nil
        if type(floating) == "table" and type(floating.Open) == "function" then
            return floating:Open("bonds", row.key, row)
        end
        return false
    end,
    buildControls = function(instance, content, Feature)
        if type(Feature.GetDisplayOrderKey) ~= "function" or type(Feature.GetFilterMask) ~= "function" or type(Feature.GetDuplicateMode) ~= "function"
            or type(Feature.Commands.SetDisplayOrder) ~= "function" or type(Feature.Commands.SetFilterMask) ~= "function"
            or type(Feature.Commands.SetDuplicateMode) ~= "function" then
            return false, "债券悬浮窗下拉筛选命令缺失"
        end
        -- 中文维护注释（2026-09-24，悬浮窗控制收敛）：旧版一行塞 8 个 Button，500px 以下会压缩、
        -- 语义也难以理解。改为 3 个 Dropdown：排列/显示范围/重复策略。Set 回调只调用原子 Feature Command；
        -- RSUI Dropdown v4 会先关闭 popup 再提交，同步 Publish 不会重入仍打开的 Native popup。
        -- 悬浮窗允许用户缩到 280px；三个 Dropdown 若强塞一行，minWidth 总和会超过窗口并再次造成
        -- 裁切/不可点击。这里用两行：第一行“排列 + 重复策略”，第二行“显示范围”独占整行。
        local bar = RSUI:VerticalBox({ id = (instance.contentPrefix or "v3_life_bonds_widget_") .. "toolbar", parent = content, gap = 4, slot = { size = "fixed", height = 60, hAlign = "fill" } })
        local primaryRow = RSUI:HorizontalBox({ id = (instance.contentPrefix or "v3_life_bonds_widget_") .. "toolbar_primary", parent = bar, gap = 4, slot = { size = "fixed", height = 28, hAlign = "fill" } })
        instance.bondOrderDropdown = RSUI:Dropdown({
            id = (instance.contentPrefix or "v3_life_bonds_widget_") .. "order", parent = primaryRow, items = BOND_ORDER_ITEMS, maxVisible = 6, popupWidth = 205,
            get = function() return Feature:GetDisplayOrderKey() end,
            set = function(value)
                local mode, order = string.match(tostring(value or ""), "^([^:]+):(.+)$")
                return Feature.Commands:SetDisplayOrder(mode, order)
            end,
            slot = { size = "fill", fill = 1.15, minWidth = 118 },
        })
        instance.bondDuplicateDropdown = RSUI:Dropdown({
            id = (instance.contentPrefix or "v3_life_bonds_widget_") .. "duplicate", parent = primaryRow, items = BOND_DUPLICATE_ITEMS, maxVisible = 3, popupWidth = 180,
            get = function() return Feature:GetDuplicateMode() end,
            set = function(value) return Feature.Commands:SetDuplicateMode(value) end,
            slot = { size = "fill", fill = 0.85, minWidth = 104 },
        })
        local scopeRow = RSUI:HorizontalBox({ id = (instance.contentPrefix or "v3_life_bonds_widget_") .. "toolbar_scope", parent = bar, gap = 4, slot = { size = "fixed", height = 28, hAlign = "fill" } })
        instance.bondScopeDropdown = RSUI:Dropdown({
            id = (instance.contentPrefix or "v3_life_bonds_widget_") .. "scope", parent = scopeRow, items = BOND_SCOPE_ITEMS, maxVisible = 9, popupWidth = 230,
            get = function() return Feature:GetFilterMask() end,
            set = function(value) return Feature.Commands:SetFilterMask(value) end,
            slot = { size = "fill", fill = 1, minWidth = 180 },
        })
        return true
    end,
    refreshControls = function(instance)
        for _, dropdown in ipairs({ instance.bondOrderDropdown, instance.bondScopeDropdown, instance.bondDuplicateDropdown }) do
            if dropdown then dropdown:SetEnabled(true); dropdown:Render() end
        end
    end,
    columns = {
        -- 中文维护注释（2026-09-15，多大陆来源可见）：大陆列直接显示 Authority row.continent，
        -- 让同日西/东快照合并后仍可辨认来源。悬浮窗不重新根据文本/材料猜大陆。
        { id = "continent", title = "大陆", field = "continent", size = "fixed", width = 54, minWidth = 48 },
        { id = "text", title = "居民板", field = "text", size = "fill", minWidth = 100, fill = 1 },
        { id = "material", title = "材料", field = "name", size = "fixed", width = 60, minWidth = 52 },
        { id = "quantity", title = "需", field = "quantity", size = "fixed", width = 34, minWidth = 30 },
        { id = "resource", title = "有", field = "resourceText", size = "fixed", width = 34, minWidth = 30 },
        { id = "shortage", title = "缺", field = "shortageText", size = "fixed", width = 34, minWidth = 30 },
        { id = "status", title = "状态", field = "statusText", size = "fixed", width = 58, minWidth = 50, getTone = function(item) return item and item.tone or "muted" end },
    },
    status = function(projection, rows)
        local coverage = type(projection.dailySnapshotStatus) == "table" and projection.dailySnapshotStatus or {}
        local current = projection.boardScope == "west" and "西" or (projection.boardScope == "east" and "东" or (projection.boardScope == "auroria" and "原" or "?"))
        return tostring(#rows) .. "条 · 当前" .. current .. " · 今日 西" .. (coverage.west and "✓" or "×")
            .. " 东" .. (coverage.east and "✓" or "×") .. " 原" .. (coverage.auroria and "✓" or "×")
    end,
})
if ok ~= true then error(err) end

ok, err = Register({
    featureName = "Treasure", featureId = "life_treasure", widgetId = "life.treasure", token = "life_treasure", owner = "v3:widget:life_treasure",
    rootId = "v3_life_treasure_widget", contentId = "v3_life_treasure_widget_content", tableId = "v3_life_treasure_widget_table", title = "寻宝助手",
    emptyTitle = "没有可用藏宝图", emptyDetail = "背包中没有读取到带坐标的藏宝图。", selectable = true,
    buildControls = function(instance, content, Feature)
        -- 中文维护注释（2026-09-16，寻宝悬浮窗地图动作）：悬浮窗只提供显式“地图定位”入口，Native X2Map 调用仍由 Feature Command/Capability Gate 所有；
        -- 不在 Presentation 保存坐标、worldId 或第二份选择状态。按钮自身不启动 Scheduler，也不会因为悬浮窗刷新自动打开地图。
        if type(Feature.Commands.ShowSelectedOnMap) ~= "function" then return false, "寻宝地图定位命令缺失" end
        local row = RSUI:HorizontalBox({ id = (instance.contentPrefix or "v3_life_treasure_widget_") .. "actions", parent = content, gap = 4, slot = { size = "fixed", height = 28, hAlign = "fill" } })
        instance.treasureMapButton = RSUI:Button({ id = (instance.contentPrefix or "v3_life_treasure_widget_") .. "map", parent = row, text = "地图定位", compact = true, slot = { size = "fill", fill = 1, minWidth = 90 } })
        instance.treasureMapButton.onClick = function()
            local actionOk, actionErr = Feature.Commands:ShowSelectedOnMap()
            instance:Refresh()
            return actionOk, actionErr
        end
        return true
    end,
    refreshControls = function(instance, projection)
        if instance.treasureMapButton then instance.treasureMapButton:SetEnabled(type(projection.selected) == "table") end
    end,
    rows = function(projection)
        local rows = projection.maps or {}
        for _, row in ipairs(rows) do row.directionText = tostring(row.direction or "--") .. (row.distance and (" · " .. tostring(math.floor(row.distance + 0.5)) .. "m") or "") end
        return rows
    end,
    onSelection = function(instance, row, Feature)
        if row == nil or row.key == nil then return false end
        local selectOk, selectErr = Feature.Commands:Select(row.key); if selectOk then instance:Refresh() end; return selectOk, selectErr
    end,
    onItemActivated = function(instance, row, Feature)
        -- 中文维护注释（2026-09-16，双击快捷定位）：单击继续只改变当前追踪目标；双击才在 Select 成功后触发地图定位，
        -- 避免用户浏览列表时地图反复弹出。两步都走同一 Feature Commands，不绕过持久选择或 Capability Gate。
        if type(row) ~= "table" or row.key == nil then return false end
        local selectOk, selectErr = Feature.Commands:Select(row.key)
        if selectOk ~= true then return false, selectErr end
        local mapOk, mapErr = Feature.Commands:ShowSelectedOnMap()
        instance:Refresh()
        return mapOk, mapErr
    end,
    columns = {
        { id="name", title="藏宝图", field="name", size="fill", minWidth=120, fill=1 },
        { id="direction", title="方向 / 距离", field="directionText", size="fixed", width=110, minWidth=90 },
    },
    status = function(projection, rows)
        if projection.lastMapActionError ~= nil then return "地图定位失败 · " .. tostring(projection.lastMapActionError) end
        local selected = projection.selected
        return selected and (tostring(selected.direction or "--") .. (selected.distance and (" · " .. tostring(math.floor(selected.distance + 0.5)) .. "m") or "")) or (tostring(#rows) .. " 张")
    end,
})
if ok ~= true then error(err) end

ok, err = Register({
    featureName = "Fishing", featureId = "life_fishing", widgetId = "life.fishing", token = "life_fishing", owner = "v3:widget:life_fishing",
    rootId = "v3_life_fishing_widget", contentId = "v3_life_fishing_widget_content", tableId = "v3_life_fishing_widget_table", title = "钓鱼助手",
    emptyTitle = "等待鱼动作", emptyDetail = "选中鱼后会根据已核动作 Buff 给出技能栏建议。",
    buildControls = function(instance, content, Feature)
        -- 中文维护注释（2026-09-16，Auto-R 悬浮入口）：主页面与 HUD 必须共享 Fishing.Commands 的可逆 Hotkey 事务；
        -- HUD 不持有 autoArmed 副本、不直接调用 X2Hotkey。ArmAuto 成功后 Auto-R 自有 Demand lease 会继续维持观察，关闭主菜单不影响钓鱼流程。
        if type(Feature.Commands.ArmAuto) ~= "function" or type(Feature.Commands.DisarmAuto) ~= "function" then return false, "钓鱼自动 R 命令缺失" end
        local row = RSUI:HorizontalBox({ id = (instance.contentPrefix or "v3_life_fishing_widget_") .. "auto_row", parent = content, gap = 4, slot = { size = "fixed", height = 28, hAlign = "fill" } })
        instance.fishingAutoButton = RSUI:Button({ id = (instance.contentPrefix or "v3_life_fishing_widget_") .. "auto", parent = row, text = "启用自动 R", compact = true, slot = { size = "fill", fill = 1, minWidth = 100 } })
        instance.fishingAutoButton.onClick = function()
            local projection = Feature:GetProjection() or {}
            local armed = projection.autoArmed == true
            local actionOk, actionErr
            -- 中文维护注释（2026-09-16，Lua 条件表达式陷阱）：不能写成 `armed and DisarmAuto() or ArmAuto()`。
            -- DisarmAuto 合法地返回 false（例如恢复事务暂时失败）时，`or` 会继续执行 ArmAuto，造成一次“关闭”点击反而重新启用。
            -- 用显式分支保证一个点击只提交一个用户意图；失败由原 Hotkey Authority 保留/恢复状态，Presentation 只刷新结果。
            if armed then
                actionOk, actionErr = Feature.Commands:DisarmAuto()
            else
                actionOk, actionErr = Feature.Commands:ArmAuto()
            end
            instance:Refresh()
            return actionOk, actionErr
        end
        return true
    end,
    refreshControls = function(instance, projection)
        if instance.fishingAutoButton then
            -- 中文维护注释：已 armed 时即使战斗导致 autoAvailable=false 也必须允许点击“关闭自动 R”；Disarm 会按既有事务进入延迟恢复，不能把退出按钮禁掉。
            local armed = projection.autoArmed == true
            local autoAvailable = projection.autoAvailable == true
            instance.fishingAutoButton:SetText(armed and "关闭自动 R" or (autoAvailable and "启用自动 R" or "自动 R 不可用"))
            instance.fishingAutoButton:SetEnabled(armed or autoAvailable)
        end
    end,
    rows = function(projection) return { { key="fishing", message=projection.message or "等待鱼动作", buffText=projection.buffId and tostring(projection.buffId) or "--", slotText=projection.slot and tostring(projection.slot) or "--", statusText=projection.status or "--" } } end,
    columns = {
        { id="message", title="当前动作 / 建议", field="message", size="fill", minWidth=150, fill=1 },
        { id="slot", title="技能栏", field="slotText", size="fixed", width=58, minWidth=50 },
        { id="buff", title="动作ID", field="buffText", size="fixed", width=70, minWidth=60 },
    },
    status = function(projection)
        if projection.autoArmed ~= true and projection.autoAvailable ~= true and projection.autoBlockedReason ~= nil then return tostring(projection.autoBlockedReason) end
        return tostring(projection.message or projection.status or "等待鱼动作")
    end,
})
if ok ~= true then error(err) end

S.UIV3 = S.UIV3 or {}
-- 中文维护注释（2026-09-24，生活 HUD 契约 v7）：在不改变 Trade Authority/Store 的前提下恢复悬浮窗当前路线
-- 添加/移除收藏，并把顶部控件刷新故障与数据表投影隔离；旧窗口位置、可见性、收藏与路线配置全部沿用。
-- 子契约用于 Acceptance/静态回归防止后续“压缩 UI”再次误删收藏闭环或让控件异常遮蔽有效路线数据。
S.UIV3.LifeEconomyWidgetsV3 = { version = 8, tradeFloatingFavoriteContractVersion = 1, tradeControlRefreshIsolationContractVersion = 1, bondsMaterialColumnContractVersion = 3, bondsMultiContinentContractVersion = 3, bondsDropdownControlsContractVersion = 2, bondsResidentBoardFamilyContractVersion = 1, treasureMapLocationContractVersion = 2, fishingFloatingAutoRContractVersion = 1, widgetIds = { "life.trade", "life.bonds", "life.treasure", "life.fishing" } }

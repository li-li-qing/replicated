------------------------------------------------------------------------
-- Replicated Suite V3 - Instance Browser Page
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI, D = S.RSUI, S.UIV3Design
local PageHost = S.UIV3 and S.UIV3.PageHost or nil
local Feature = S.Features and S.Features.InstanceBrowser or nil
if type(RSUI) ~= "table" or type(D) ~= "table" or type(PageHost) ~= "table" or type(Feature) ~= "table" then return end

local ROUTE = "tools.instance_browser"

local function BuildPage(parent, route)
    local root, rootErr = D:PageRoot(parent, "v3_page_instance_browser")
    if root == nil then return nil, "页面根组件创建失败：" .. tostring(rootErr or "未知错误") end
    root.consumerHeld = false
    root.selectedId = nil
    root.filterMode = "all"

    D:PageHeader(root, "v3_instances_header", "副本目录",
        "只读浏览客户端当前实例分类、入场次数和运行时副本ID。数据库区域ID 与运行时副本ID 严格分开，名称匹配只记录为待核验证据。",
        "完整刷新", function()
            if S.FeatureRuntime:IsEnabled("tools_instance_browser") ~= true then return false, "副本目录功能已关闭" end
            if S.ActionRunner == nil then return Feature.Commands:Refresh("page_manual", true) end
            return S.ActionRunner:Run({ id = "instances.full_refresh", notify = false, execute = function() return Feature.Commands:Refresh("page_manual", true) end })
        end)

    local summaryCard = D:InfoCard(root, {
        id = "v3_instances_summary", title = "实例概览", value = "--", detail = "--",
        slot = { size = "fixed", height = 82, hAlign = "fill" },
    })

    local actions = RSUI:HorizontalBox({ id = "v3_instances_filters", parent = root, gap = 7, slot = { size = "fixed", height = 30, hAlign = "fill" } })
    local toggle = RSUI:Button({ id = "v3_instances_toggle", parent = actions, text = "启用功能", compact = true, slot = { size = "fixed", width = 92 } })
    local allButton = RSUI:Button({ id = "v3_instances_filter_all", parent = actions, text = "全部", compact = true, slot = { size = "fixed", width = 72 } })
    local availableButton = RSUI:Button({ id = "v3_instances_filter_available", parent = actions, text = "可进入", compact = true, slot = { size = "fixed", width = 78 } })
    local limitedButton = RSUI:Button({ id = "v3_instances_filter_limited", parent = actions, text = "有限次数", compact = true, slot = { size = "fixed", width = 88 } })
    local unmappedButton = RSUI:Button({ id = "v3_instances_filter_unmapped", parent = actions, text = "待核验", compact = true, slot = { size = "fixed", width = 78 } })
    local hint = RSUI:Text({ id = "v3_instances_filter_hint", parent = actions, text = "", fontSize = 9, tone = "muted", overflow = "ellipsis", slot = { size = "fill", fill = 1 } })

    local selectedCard = D:InfoCard(root, {
        id = "v3_instances_selected", title = "选中副本", value = "未选择", detail = "点击列表行查看 运行时 / 数据库身份与入场次数。",
        detailMaxLines = 2, slot = { size = "fixed", height = 76, hAlign = "fill" },
    })

    local tableView = RSUI:TableView({
        id = "v3_instances_table", parent = root, items = {},
        rowHeight = 29, headerHeight = 29, desiredRows = 13, overscan = 2,
        scrollbar = true, selectable = true, selectionMode = "single", columnResize = true, headerInteractive = false,
        getKey = function(item) return item and item.id or nil end,
        onSelectionChanged = function(_, _, view)
            root.selectedId = view and type(view.GetSelectedKey) == "function" and view:GetSelectedKey() or nil
            root:RefreshSelection()
        end,
        columns = {
            { id = "kind", title = "分类", field = "kindText", size = "fixed", width = 110, minWidth = 72, maxWidth = 180, tone = "muted" },
            { id = "name", title = "副本", field = "name", size = "fill", minWidth = 220, fill = 1.0 },
            { id = "entry", title = "入场", field = "entryText", size = "fixed", width = 76, minWidth = 54, maxWidth = 108,
                getTone = function(item) return item and item.limitUsed and "green" or "default" end },
            { id = "available", title = "当前状态", field = "availabilityText", size = "fixed", width = 96, minWidth = 72, maxWidth = 132,
                getTone = function(item) return item and item.availabilityTone or "muted" end },
            { id = "identity", title = "身份", field = "identityText", size = "fixed", width = 124, minWidth = 86, maxWidth = 176,
                getTone = function(item) return item and item.identityTone or "muted" end },
        },
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })

    local function SetFilter(mode)
        root.filterMode = tostring(mode or "all")
        root:Refresh()
        return true
    end
    allButton.onClick = function() return SetFilter("all") end
    availableButton.onClick = function() return SetFilter("available") end
    limitedButton.onClick = function() return SetFilter("limited") end
    unmappedButton.onClick = function() return SetFilter("unmapped") end
    for _, binding in ipairs({
        { allButton, "all" }, { availableButton, "available" }, { limitedButton, "limited" }, { unmappedButton, "unmapped" },
    }) do
        local button, label = binding[1], binding[2]
        if button.root ~= nil then S.UI:SafeHandler(button.root, "OnClick", function() return button.onClick() end, "v3_instances:" .. label) end
    end

    function root:FilteredRows()
        local rows = Feature:GetRows()
        local mode = tostring(self.filterMode or "all")
        if mode == "all" then return rows end
        local result = {}
        for _, row in ipairs(type(rows) == "table" and rows or {}) do
            local include = mode == "available" and row.available == true
                or mode == "limited" and row.limited == true
                or mode == "unmapped" and row.staticKey == nil
            if include then result[#result + 1] = row end
        end
        return result
    end

    function root:RefreshSelection()
        local row = self.selectedId and Feature:GetRow(self.selectedId) or nil
        if type(row) ~= "table" then
            selectedCard:SetData({ value = "未选择", detail = "点击列表行查看 运行时 / 数据库身份与入场次数。" })
            return true
        end
        local detail = row.runtimeText
        if row.detailAvailable then
            detail = detail .. " · 入场 " .. tostring(row.entryText)
        else
            detail = detail .. " · 详情数据未就绪"
        end
        if row.staticKey ~= nil then detail = detail .. " · 静态键 " .. tostring(row.staticKey) end
        selectedCard:SetData({ title = tostring(row.kindText), value = tostring(row.name), detail = detail })
        return true
    end

    function root:Refresh()
        local enabled = S.FeatureRuntime:IsEnabled("tools_instance_browser") == true
        toggle:SetText(enabled and "关闭功能" or "启用功能")
        if not enabled then
            self.selectedId = nil
            tableView:SetItems({}, "instances:disabled")
            tableView:SetViewState("empty", { title = "副本目录已关闭", detail = "打开页面不会自动启用功能；点击“启用功能”后才建立实例目录 Consumer。" })
            summaryCard:SetData({ value = "功能已关闭", detail = "未读取实例目录，也未启动 InstanceCatalogV3。" })
            selectedCard:SetData({ title = "选中副本", value = "未选择", detail = "功能启用后可浏览副本。" })
            hint:SetText("功能已关闭 · 运行资源已释放")
            return true
        end
        local rows, revision = Feature:GetRows()
        local filtered = self:FilteredRows()
        tableView:SetItems(filtered, "instances:" .. tostring(revision) .. ":" .. tostring(self.filterMode))
        if #filtered == 0 then
            local filterName = ({ all = "全部", available = "当前可进入", limited = "有限入场次数", unmapped = "待核验" })[self.filterMode] or "当前"
            tableView:SetViewState("empty", { title = "暂无副本", detail = filterName .. "筛选下没有可显示的副本记录。" })
        else
            tableView:SetViewState("ready")
        end
        local summary = Feature:GetSummary()
        summaryCard:SetData({
            value = tostring(summary.total or 0) .. " 个实例",
            detail = "分类 " .. tostring(summary.kinds or 0)
                .. " · 详情就绪 " .. tostring(summary.detailReady or 0)
                .. " · 静态身份匹配 " .. tostring(summary.mapped or 0)
                .. " · 待核验 " .. tostring(summary.unmapped or 0),
        })
        local filterText = ({ all = "全部", available = "当前可进入", limited = "有限入场次数", unmapped = "运行时ID待核验" })[self.filterMode] or "全部"
        hint:SetText("筛选：" .. filterText .. " · 当前显示 " .. tostring(#filtered))
        allButton:SetText("全部"); allButton:SetSelected(self.filterMode == "all")
        availableButton:SetText("可进入"); availableButton:SetSelected(self.filterMode == "available")
        limitedButton:SetText("有限次数"); limitedButton:SetSelected(self.filterMode == "limited")
        unmappedButton:SetText("待核验"); unmappedButton:SetSelected(self.filterMode == "unmapped")
        self:RefreshSelection()
        return true
    end

    function root:BindUpdates()
        if S.Events == nil or type(S.Events.SubscribeInternal) ~= "function" then return true end
        if type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
        return S.Events:SubscribeInternal("v3.instance_browser.updated", self, function() root:Refresh() end)
    end

    function root:UnbindUpdates()
        if S.Events ~= nil and type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
        return true
    end

    toggle.onClick = function()
        local target = S.FeatureRuntime:IsEnabled("tools_instance_browser") ~= true
        local changed, changeErr = S.FeatureRuntime:SetPreferredEnabled("tools_instance_browser", target, "instance_page_toggle")
        if changed ~= true then return false, changeErr end
        if target then
            local acquired, acquireErr = Feature:AcquireConsumer("page:instance_browser")
            if acquired ~= true then
                local rolledBack, rollbackErr = S.FeatureRuntime:SetPreferredEnabled("tools_instance_browser", false, "instance_page_acquire_rollback")
                root.consumerHeld = false
                root:Refresh()
                if rolledBack ~= true then return false, tostring(acquireErr or "Consumer 启动失败") .. "；回滚失败：" .. tostring(rollbackErr or "unknown") end
                return false, acquireErr
            end
            root.consumerHeld = true
            root:BindUpdates()
        else
            root.consumerHeld = false
            root:UnbindUpdates()
        end
        root:Refresh()
        return true
    end
    if toggle.root ~= nil then S.UI:SafeHandler(toggle.root, "OnClick", toggle.onClick, "v3_instances:toggle") end

    function root:OnActivated()
        if S.FeatureRuntime == nil then tableView:SetViewState("error", { detail = "FeatureRuntime 不可用" }); return false, "feature runtime unavailable" end
        if S.FeatureRuntime:IsEnabled("tools_instance_browser") ~= true then self.consumerHeld = false; return self:Refresh() end
        tableView:SetViewState("loading", { title = "正在读取副本目录…", detail = "正在建立实例目录 Consumer。" })
        local acquired, acquireErr = Feature:AcquireConsumer("page:instance_browser")
        if acquired ~= true then tableView:SetViewState("error", { detail = tostring(acquireErr or "副本目录 Consumer 获取失败") }); return false, acquireErr end
        self.consumerHeld = true
        self:BindUpdates()
        return self:Refresh()
    end

    function root:OnDeactivated()
        self:UnbindUpdates()
        if self.consumerHeld then Feature:ReleaseConsumer("page:instance_browser"); self.consumerHeld = false end
        return true
    end

    function root:RefreshData(dirty)
        return self:Refresh()
    end

    root.route = route
    root.tableView = tableView
    return root
end

local ok, err = PageHost:RegisterFactory(ROUTE, BuildPage)
if ok ~= true then error(err) end

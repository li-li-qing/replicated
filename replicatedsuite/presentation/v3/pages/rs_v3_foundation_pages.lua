------------------------------------------------------------------------
-- Replicated Suite V3 - Foundation Pages
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI, D = S.RSUI, S.UIV3Design
S.UIV3 = S.UIV3 or {}
local PageHost = S.UIV3.PageHost
if type(RSUI) ~= "table" or type(D) ~= "table" or type(PageHost) ~= "table" then return end

-- Persistent bindings use stable store contracts owned by the Domain. Keep the
-- identifiers local to Presentation instead of reading Feature implementation
-- fields such as StoreId/IndexStoreId.
local ACTIVITIES_STORE_ID = "v3.activities"
local GEAR_INDEX_STORE_ID = "v3.gear.index"
local PERSISTENCE_ACCEPTANCE_STORE_IDS = {
    "v3.buff_display",
    "v3.healer",
    GEAR_INDEX_STORE_ID,
    ACTIVITIES_STORE_ID,
    "v3.tasks",
    "v3.dps",
    "v3.life.trade",
}
local PERSISTENCE_ACCEPTANCE_STORE_PREFIXES = { "v3.gear.payload." }

S.UIV3.Pages = S.UIV3.Pages or {}
local Pages = S.UIV3.Pages

local STATUS_NAMES = {
    foundation = "框架基础",
    migrated_m1 = "已迁移",
    planned = "待迁移",
    planned_verified = "API已确认 · 待开发",
    planned_partial = "部分能力可用 · 待开发",
    planned_research = "API待实机验证",
    runtime_blocked = "运行时阻塞",
    implemented = "已实现",
    pending = "待迁移",
    enabled = "已启用",
    disabled = "已关闭",
}
local CATEGORY_NAMES = { home = "首页", combat = "战斗", life = "生活", tools = "工具", system = "系统" }
local API_READINESS_NAMES = { official = "官方已开放", official_write = "官方写能力已开放", official_restricted = "官方开放但有限制", official_narrow = "官方仅开放窄能力", partial = "部分能力可用", research = "等待实机验证", unknown = "未分类" }
local BOOT_STAGE_NAMES = {
    bootstrap = "启动准备", api_validate = "接口校验", static_validate = "静态数据校验", static_seal = "静态数据封存",
    app_state_load = "应用设置读取", layout_prime = "布局准备", presentation_hosts = "界面宿主准备", event_bus_start = "事件总线启动",
    scheduler_tasks = "调度任务准备", scheduler_start = "调度器启动", feature_defaults = "功能状态恢复", foundation_refresh = "基础数据刷新",
    layout_finalize = "界面布局完成", esc_register = "系统菜单注册", ready = "完成",
}
local function StatusName(value)
    local key = tostring(value or "planned")
    if key:match("^migrated_") then return "已迁移" end
    if key:match("^implemented") then return "已实现" end
    if key == "runtime_blocked" then return "运行时阻塞" end
    return STATUS_NAMES[key] or "待迁移"
end
local function CategoryName(value) return CATEGORY_NAMES[tostring(value or "system")] or "其它" end
local function ApiReadinessName(value) return API_READINESS_NAMES[tostring(value or "unknown")] or "待确认" end
local function FormatApiDependencies(meta)
    local rows = type(meta) == "table" and meta.apiDependencies or nil
    if type(rows) ~= "table" or #rows == 0 then return "无显式依赖" end
    local out = {}
    for i = 1, math.min(#rows, 3) do out[#out + 1] = tostring(rows[i]) end
    if #rows > 3 then out[#out + 1] = "+" .. tostring(#rows - 3) end
    return table.concat(out, " · ")
end

local function BuildHome(parent, route)
    local root, rootErr = D:PageRoot(parent, "v3_page_home")
    if root == nil then return nil, "页面根组件创建失败：" .. tostring(rootErr or "未知错误") end
    D:PageHeader(root, "v3_home_header", "今日总览", "新版工作台。每个功能按照独立数据源、生命周期、存档和悬浮组件逐步迁入。")

    local grid = RSUI:UniformGrid({
        id = "v3_home_grid", parent = root, minCellWidth = 210, minCellHeight = 82, maxColumns = 2, gap = 10,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })
    local cards = {
        { "activity", "活动 / 世界状态", "已迁移", "俄服时间表、实时区域阶段、任务/副本参与进度与独立活动悬浮窗已经接入。" },
        { "trade", "跑商当前路线", "已接入 · 部分能力可用", "当前可见路线、货率与多材料投影；完整自动路线决策或实机字段仍待确认。" },
        { "bond", "债券 / 居民板", "已接入 · 部分能力可用", "七类居民板已读取；居民完成状态仍待确认。" },
        { "tasks", "我的任务追踪", "已迁移", "日常 / 周常使用独立追踪选择，支持子任务展开和悬浮追踪，并共享只读任务进度数据源。" },
        { "today", "今日统计", "范围待确认", "当前仅展示已接入的活动与任务摘要；金币、经验、荣誉和生活点等今日统计范围仍待确认。" },
    }
    for _, row in ipairs(cards) do
        D:InfoCard(grid, {
            id = "v3_home_card_" .. row[1], title = row[2], value = row[3], detail = row[4], detailMaxLines = 4,
            slot = { hAlign = "fill", vAlign = "fill" },
        })
    end
    root.route = route
    return root
end

local function BuildFeaturePlaceholder(parent, route, feature)
    local id = "v3_page_" .. tostring(route):gsub("[^%w]", "_")
    local root, rootErr = D:PageRoot(parent, id)
    if root == nil then return nil, "页面根组件创建失败：" .. tostring(rootErr or "未知错误") end
    D:PageHeader(root, id .. "_header", feature and feature.name or "功能页面", feature and feature.description or "该功能尚未迁入新版框架。")
    local status = feature and tostring(feature.status or "planned") or "planned"
    D:InfoCard(root, {
        id = id .. "_contract", title = "功能迁移状态", value = StatusName(status),
        detail = "生命周期：独立管理\n旧实现只作为行为和数据参考；当前页面不会启动旧界面或旧运行逻辑。",
        detailMaxLines = 3,
        slot = { size = "fixed", height = 104, hAlign = "fill" },
    })
    D:EmptyState(root, id .. "_empty", "等待新版迁移", "迁移顺序：核对真实数据源 → 独立存档 → 数据投影 → 页面 / 悬浮组件 → 自动验收。")
    root.route, root.feature = route, feature
    return root
end

local function BuildFeatures(parent, route)
    local root, rootErr = D:PageRoot(parent, "v3_page_system_features")
    if root == nil then return nil, "页面根组件创建失败：" .. tostring(rootErr or "未知错误") end
    D:PageHeader(root, "v3_features_header", "功能模块", "这里管理已经迁入新版框架的功能生命周期；尚未迁移的功能保持零运行成本。")
    local selectedId = nil
    local revision = 0
    local detailCard = D:InfoCard(root, {
        id = "v3_features_detail", title = "功能状态", value = "请选择功能", detail = "已迁入的功能可以独立启用或关闭。",
        detailMaxLines = 5, slot = { size = "fixed", height = 126, hAlign = "fill" },
    })
    local actionRow = RSUI:HorizontalBox({ id = "v3_features_actions", parent = root, gap = 8, slot = { size = "fixed", height = 34, hAlign = "fill" } })
    local toggleButton = RSUI:Button({ id = "v3_features_toggle", parent = actionRow, text = "启用 / 关闭", compact = true, enabled = false, slot = { size = "fixed", width = 120 } })
    local preferenceText = RSUI:Text({ id = "v3_features_preference", parent = actionRow, text = "", fontSize = 9, tone = "muted", overflow = "ellipsis", slot = { size = "fill", fill = 1 } })

    local list = nil
    local function ItemAt(index)
        local id = S.FeatureRegistry.order[index]
        local feature = id and S.FeatureRegistry.features[id] or nil
        if feature == nil then return nil end
        local snapshot = S.FeatureRuntime and S.FeatureRuntime:GetSnapshot(id) or nil
        local runState
        if snapshot == nil or snapshot.implemented ~= true then runState = "未迁移"
        elseif snapshot.faulted == true then runState = "故障"
        elseif snapshot.enabled == true then runState = "运行中"
        else runState = "已关闭" end
        return { id = id, text = feature.name .. "  ·  " .. CategoryName(feature.category) .. "  ·  " .. runState }
    end

    list = RSUI:ListView({
        id = "v3_features_list", parent = root, rowHeight = 28, overscan = 1, selectable = true, selectionMode = "single", scrollbar = true,
        getCount = function() return #(S.FeatureRegistry and S.FeatureRegistry.order or {}) end,
        getItem = function(index) return ItemAt(index) end,
        getKey = function(item) return item and item.id or nil end,
        itemText = function(item) return item and item.text or "" end,
        onSelectionChanged = function(index)
            local item = index and ItemAt(index) or nil
            selectedId = item and item.id or nil
            if type(root.RefreshSelection) == "function" then root:RefreshSelection() end
        end,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })

    function root:RefreshSelection()
        local id = selectedId
        local meta = id and S.FeatureRegistry:Get(id) or nil
        local snapshot = id and S.FeatureRuntime and S.FeatureRuntime:GetSnapshot(id) or nil
        if meta == nil or snapshot == nil then
            detailCard:SetData({ title = "功能状态", value = "请选择功能", detail = "已迁入的功能可以独立启用或关闭。" })
            toggleButton:SetEnabled(false)
            toggleButton:SetText("启用 / 关闭")
            preferenceText:SetText("")
            return true
        end
        local value
        local tone = "default"
        if snapshot.implemented ~= true then value = "等待迁移"
        elseif snapshot.faulted == true then value = "运行故障"; tone = "red"
        elseif snapshot.enabled == true then value = "正在运行"; tone = "green"
        else value = "已关闭"; tone = "muted" end
        local preferred, explicit = S.FeatureRuntime:GetPreferredEnabled(id)
        detailCard:SetData({
            title = meta.name,
            value = value,
            detail = "分类：" .. CategoryName(meta.category) .. " · 迁移状态：" .. StatusName(meta.status)
                .. "\nAPI：" .. ApiReadinessName(meta.apiReadiness) .. " · " .. tostring(meta.apiPolicy or "none")
                .. "\n依赖：" .. FormatApiDependencies(meta)
                .. "\n运行偏好：" .. (preferred and "启用" or "关闭") .. (explicit and "（用户设置）" or "（默认）"),
        })
        detailCard.valueText:SetTone(tone)
        toggleButton:SetEnabled(snapshot.implemented == true and snapshot.faulted ~= true)
        toggleButton:SetText(snapshot.enabled == true and "关闭功能" or "启用功能")
        preferenceText:SetText(snapshot.implemented == true and "关闭后会释放该功能自己的事件、调度任务和悬浮组件。" or "尚未迁移，不会启动旧逻辑。")
        return true
    end

    toggleButton.onClick = function()
        if selectedId == nil or S.FeatureRuntime == nil then return false end
        local snapshot = S.FeatureRuntime:GetSnapshot(selectedId)
        if snapshot == nil or snapshot.implemented ~= true then return false end
        local ok = S.FeatureRuntime:SetPreferredEnabled(selectedId, snapshot.enabled ~= true, "feature_manager")
        if ok == true then
            revision = revision + 1
            list:RefreshVisible("features:" .. tostring(revision), true)
            root:RefreshSelection()
        end
        return ok
    end

    function root:OnActivated()
        if S.FeatureRuntime ~= nil and type(S.FeatureRuntime.EnsurePreferencesLoaded) == "function" then S.FeatureRuntime:EnsurePreferencesLoaded() end
        revision = revision + 1
        list:RefreshVisible("features:" .. tostring(revision), true)
        self:RefreshSelection()
        return true
    end
    root.list = list; root.route = route
    return root
end

local function BuildWidgets(parent, route)
    local root, rootErr = D:ScrollablePageRoot(parent, "v3_page_system_widgets")
    if root == nil then return nil, "页面根组件创建失败：" .. tostring(rootErr or "未知错误") end
    D:PageHeader(root, "v3_widgets_header", "悬浮组件", "这里只管理已经迁入新版框架的独立悬浮组件；位置、锁定和布局恢复由统一组件宿主管理。")
    local function AdoptWidgetAction(button, id)
        if type(button) ~= "table" or type(button.spec) ~= "table" or type(button.spec.onClick) ~= "function" then return button end
        local execute = button.spec.onClick
        button.spec.onClick = function()
            if S.ActionRunner ~= nil and type(S.ActionRunner.Run) == "function" then
                return S.ActionRunner:Run({ id = "widgets." .. tostring(id), button = button, busyText = "处理中…", notify = false, execute = execute })
            end
            return execute()
        end
        return button
    end
    local statusCard = D:InfoCard(root, { id = "v3_widgets_status", title = "悬浮组件宿主", value = "正常", detail = "--", slot = { size = "fixed", height = 86, hAlign = "fill" } })

    local activityRow = RSUI:Border({ id = "v3_widgets_activity_row", parent = root, variant = "soft", padding = 8,
        minHeight = 490, slot = { size = "auto", minHeight = 490, hAlign = "fill" } })
    local activityStack = RSUI:VerticalBox({ id = "v3_widgets_activity_stack", parent = activityRow, gap = 6 })
    local activityLine = RSUI:HorizontalBox({ id = "v3_widgets_activity_line", parent = activityStack, gap = 8, slot = { size = "fixed", height = 24, hAlign = "fill" } })
    RSUI:Text({ id = "v3_widgets_activity_name", parent = activityLine, text = "活动", fontSize = 11, tone = "default", overflow = "ellipsis", slot = { size = "fill", fill = 1 } })
    local activityState = RSUI:Text({ id = "v3_widgets_activity_state", parent = activityLine, text = "已关闭", fontSize = 9, tone = "muted", overflow = "ellipsis", slot = { size = "auto" } })
    local actions = RSUI:HorizontalBox({ id = "v3_widgets_activity_actions", parent = activityStack, gap = 7, slot = { size = "fixed", height = 30, hAlign = "fill" } })
    local activityButton = RSUI:Button({ id = "v3_widgets_activity_toggle", parent = actions, text = "打开", compact = true, slot = { size = "fixed", width = 72 },
        onClick = function()
            local feature = S.Features and S.Features.Activities or nil
            if type(feature) ~= "table" or type(feature.Commands) ~= "table" or type(feature.Commands.SetWidgetVisible) ~= "function" then return false end
            local visible = S.UIV3.WidgetHost and S.UIV3.WidgetHost:IsVisible("life.activities") == true
            local ok = feature.Commands:SetWidgetVisible(not visible, "widget_manager")
            if ok == true and type(root.Refresh) == "function" then root:Refresh() end
            return ok
        end })
    local activityLock = RSUI:Button({ id = "v3_widgets_activity_lock", parent = actions, text = "锁定位置", compact = true, slot = { size = "fixed", width = 88 },
        onClick = function()
            local host = S.UIV3 and S.UIV3.WidgetHost or nil
            local state = host and host:GetState("life.activities") or nil
            if state == nil or state.lockable ~= true then return false end
            local ok = host:SetLocked("life.activities", state.locked ~= true)
            if ok == true and type(root.Refresh) == "function" then root:Refresh() end
            return ok
        end })
    local activityReset = RSUI:Button({ id = "v3_widgets_activity_reset", parent = actions, text = "恢复默认位置", compact = true, slot = { size = "fixed", width = 106 },
        onClick = function()
            local host = S.UIV3 and S.UIV3.WidgetHost or nil
            if host == nil then return false end
            local ok = host:ResetLayout("life.activities")
            if ok == true and type(root.Refresh) == "function" then root:Refresh() end
            return ok
        end })
    AdoptWidgetAction(activityButton, "activity_toggle")
    AdoptWidgetAction(activityLock, "activity_lock")
    AdoptWidgetAction(activityReset, "activity_reset")
    local activityHint = RSUI:Text({ id = "v3_widgets_activity_hint", parent = actions, text = "", fontSize = 9, tone = "muted", overflow = "ellipsis", slot = { size = "fill", fill = 1 } })
    local overallOpacityField = D:NumericSetting(activityStack, {
        id = "v3_widgets_activity_overall_opacity", label = "整体透明度", hint = "作用于整个悬浮窗，并与背景/文字透明度相乘；可直接输入 0–100。",
        min = 0, max = 100, step = 1, integer = true, unit = "%", slider = true, stepButtons = false,
        get = function()
            local host = S.UIV3 and S.UIV3.WidgetHost or nil
            local state = host and host:GetState("life.activities") or nil
            return math.floor((tonumber(state and state.overallOpacity) or 0.94) * 100 + 0.5)
        end,
        set = function(value)
            local host = S.UIV3 and S.UIV3.WidgetHost or nil
            if host == nil then return false, "悬浮组件宿主不可用" end
            return host:SetAppearance("life.activities", "overall", (tonumber(value) or 94) / 100, false)
        end,
        storeId = ACTIVITIES_STORE_ID, persistDelayMs = 250, persistReason = "activity_widget_overall_opacity",
        slot = { size = "auto", minHeight = 62, hAlign = "fill" },
    })
    local backgroundOpacityField = D:NumericSetting(activityStack, {
        id = "v3_widgets_activity_background_opacity", label = "背景透明度", hint = "只调整面板、边框、按钮等背景，不降低文字清晰度；可直接输入 0–100。",
        min = 0, max = 100, step = 1, integer = true, unit = "%", slider = true, stepButtons = false,
        get = function()
            local host = S.UIV3 and S.UIV3.WidgetHost or nil
            local state = host and host:GetState("life.activities") or nil
            return math.floor((tonumber(state and state.backgroundOpacity) or 1.0) * 100 + 0.5)
        end,
        set = function(value)
            local host = S.UIV3 and S.UIV3.WidgetHost or nil
            if host == nil then return false, "悬浮组件宿主不可用" end
            return host:SetAppearance("life.activities", "background", (tonumber(value) or 100) / 100, false)
        end,
        storeId = ACTIVITIES_STORE_ID, persistDelayMs = 250, persistReason = "activity_widget_background_opacity",
        slot = { size = "auto", minHeight = 62, hAlign = "fill" },
    })
    local textOpacityField = D:NumericSetting(activityStack, {
        id = "v3_widgets_activity_text_opacity", label = "文字透明度", hint = "只调整标题、状态、表格文字和按钮文字；可直接输入 0–100。",
        min = 0, max = 100, step = 1, integer = true, unit = "%", slider = true, stepButtons = false,
        get = function()
            local host = S.UIV3 and S.UIV3.WidgetHost or nil
            local state = host and host:GetState("life.activities") or nil
            return math.floor((tonumber(state and state.textOpacity) or 1.0) * 100 + 0.5)
        end,
        set = function(value)
            local host = S.UIV3 and S.UIV3.WidgetHost or nil
            if host == nil then return false, "悬浮组件宿主不可用" end
            return host:SetAppearance("life.activities", "text", (tonumber(value) or 100) / 100, false)
        end,
        storeId = ACTIVITIES_STORE_ID, persistDelayMs = 250, persistReason = "activity_widget_text_opacity",
        slot = { size = "auto", minHeight = 62, hAlign = "fill" },
    })
    local activityFeature = S.Features and S.Features.Activities or nil
    local activitySize = activityFeature and type(activityFeature.GetWidgetWindowPolicy) == "function" and activityFeature:GetWidgetWindowPolicy()
        or { defaultWidth = 430, defaultHeight = 276, minWidth = 1, minHeight = 1 }
    local widthField = D:NumericSetting(activityStack, {
        id = "v3_widgets_activity_width", label = "窗口宽度", hint = "可直接输入精确宽度；不设屏幕/预设上限，也可以继续拖动边缘调整。",
        min = activitySize.minWidth, step = 1, integer = true, unit = " px", slider = false, stepButtons = false,
        get = function()
            local feature = S.Features and S.Features.Activities or nil
            local state = feature and type(feature.GetWidgetWindowState) == "function" and feature:GetWidgetWindowState() or nil
            return tonumber(state and state.width) or activitySize.defaultWidth
        end,
        set = function(value)
            local feature = S.Features and S.Features.Activities or nil
            if feature == nil or type(feature.Commands) ~= "table" or type(feature.Commands.SetWidgetSize) ~= "function" then return false, "活动悬浮窗尺寸设置不可用" end
            return feature.Commands:SetWidgetSize(value, nil, "widget_manager_width")
        end,
        storeId = ACTIVITIES_STORE_ID, persistDelayMs = 250, persistReason = "activity_widget_width",
        slot = { size = "auto", minHeight = 62, hAlign = "fill" },
    })
    local heightField = D:NumericSetting(activityStack, {
        id = "v3_widgets_activity_height", label = "窗口高度", hint = "可直接输入精确高度；实际可见活动行数会随窗口高度自动增减，不再使用固定显示行数上限。",
        min = activitySize.minHeight, step = 1, integer = true, unit = " px", slider = false, stepButtons = false,
        get = function()
            local feature = S.Features and S.Features.Activities or nil
            local state = feature and type(feature.GetWidgetWindowState) == "function" and feature:GetWidgetWindowState() or nil
            return tonumber(state and state.height) or activitySize.defaultHeight
        end,
        set = function(value)
            local feature = S.Features and S.Features.Activities or nil
            if feature == nil or type(feature.Commands) ~= "table" or type(feature.Commands.SetWidgetSize) ~= "function" then return false, "活动悬浮窗尺寸设置不可用" end
            return feature.Commands:SetWidgetSize(nil, value, "widget_manager_height")
        end,
        storeId = ACTIVITIES_STORE_ID, persistDelayMs = 250, persistReason = "activity_widget_height",
        slot = { size = "auto", minHeight = 62, hAlign = "fill" },
    })

    local gearRow = RSUI:Border({ id = "v3_widgets_gear_row", parent = root, variant = "soft", padding = 8,
        minHeight = 315, slot = { size = "auto", minHeight = 315, hAlign = "fill" } })
    local gearStack = RSUI:VerticalBox({ id = "v3_widgets_gear_stack", parent = gearRow, gap = 6 })
    local gearLine = RSUI:HorizontalBox({ id = "v3_widgets_gear_line", parent = gearStack, gap = 8, slot = { size = "fixed", height = 24, hAlign = "fill" } })
    RSUI:Text({ id = "v3_widgets_gear_name", parent = gearLine, text = "换装快捷按钮", fontSize = 11, tone = "default", overflow = "ellipsis", slot = { size = "fill", fill = 1 } })
    local gearStateText = RSUI:Text({ id = "v3_widgets_gear_state", parent = gearLine, text = "已关闭", fontSize = 9, tone = "muted", overflow = "ellipsis", slot = { size = "auto" } })
    local gearActions = RSUI:HorizontalBox({ id = "v3_widgets_gear_actions", parent = gearStack, gap = 7, slot = { size = "fixed", height = 30, hAlign = "fill" } })
    local gearButton = RSUI:Button({ id = "v3_widgets_gear_toggle", parent = gearActions, text = "打开", compact = true, slot = { size = "fixed", width = 72 },
        onClick = function()
            local feature = S.Features and S.Features.Gear or nil
            local host = S.UIV3 and S.UIV3.WidgetHost or nil
            if type(feature) ~= "table" or type(feature.Commands) ~= "table" or type(feature.Commands.SetQuickHudVisible) ~= "function" or type(host) ~= "table" then return false end
            local ok = feature.Commands:SetQuickHudVisible(host:IsVisible("combat.gear.quick") ~= true, "widget_manager")
            if ok == true and type(root.Refresh) == "function" then root:Refresh() end
            return ok
        end })
    local gearLock = RSUI:Button({ id = "v3_widgets_gear_lock", parent = gearActions, text = "锁定位置", compact = true, slot = { size = "fixed", width = 88 },
        onClick = function()
            local host = S.UIV3 and S.UIV3.WidgetHost or nil
            local state = host and host:GetState("combat.gear.quick") or nil
            if state == nil or state.lockable ~= true then return false end
            local ok = host:SetLocked("combat.gear.quick", state.locked ~= true)
            if ok == true and type(root.Refresh) == "function" then root:Refresh() end
            return ok
        end })
    local gearReset = RSUI:Button({ id = "v3_widgets_gear_reset", parent = gearActions, text = "恢复默认位置", compact = true, slot = { size = "fixed", width = 106 },
        onClick = function()
            local host = S.UIV3 and S.UIV3.WidgetHost or nil
            if host == nil then return false end
            local ok = host:ResetLayout("combat.gear.quick")
            if ok == true and type(root.Refresh) == "function" then root:Refresh() end
            return ok
        end })
    AdoptWidgetAction(gearButton, "gear_toggle")
    AdoptWidgetAction(gearLock, "gear_lock")
    AdoptWidgetAction(gearReset, "gear_reset")
    local gearHint = RSUI:Text({ id = "v3_widgets_gear_hint", parent = gearActions, text = "", fontSize = 9, tone = "muted", overflow = "ellipsis", slot = { size = "fill", fill = 1 } })

    local function GearAppearanceGet(channel, fallback)
        local host = S.UIV3 and S.UIV3.WidgetHost or nil
        local state = host and host:GetState("combat.gear.quick") or nil
        return math.floor((tonumber(state and state[channel]) or fallback) * 100 + 0.5)
    end
    local function GearAppearanceSet(channel, value)
        local host = S.UIV3 and S.UIV3.WidgetHost or nil
        if host == nil then return false, "悬浮组件宿主不可用" end
        return host:SetAppearance("combat.gear.quick", channel, (tonumber(value) or 100) / 100, false)
    end
    local gearOverallOpacityField = D:NumericSetting(gearStack, {
        id = "v3_widgets_gear_overall_opacity", label = "整体透明度", hint = "同时作用于所有换装快捷按钮，并与背景/文字透明度相乘；可直接输入 0–100。",
        min = 0, max = 100, step = 1, integer = true, unit = "%", slider = true, stepButtons = false,
        get = function() return GearAppearanceGet("overallOpacity", 0.94) end,
        set = function(value) return GearAppearanceSet("overall", value) end,
        storeId = GEAR_INDEX_STORE_ID, persistDelayMs = 250, persistReason = "gear_quick_overall_opacity",
        slot = { size = "auto", minHeight = 62, hAlign = "fill" },
    })
    local gearBackgroundOpacityField = D:NumericSetting(gearStack, {
        id = "v3_widgets_gear_background_opacity", label = "背景透明度", hint = "只调整所有换装快捷按钮的背景，不降低文字清晰度。",
        min = 0, max = 100, step = 1, integer = true, unit = "%", slider = true, stepButtons = false,
        get = function() return GearAppearanceGet("backgroundOpacity", 1.0) end,
        set = function(value) return GearAppearanceSet("background", value) end,
        storeId = GEAR_INDEX_STORE_ID, persistDelayMs = 250, persistReason = "gear_quick_background_opacity",
        slot = { size = "auto", minHeight = 62, hAlign = "fill" },
    })
    local gearTextOpacityField = D:NumericSetting(gearStack, {
        id = "v3_widgets_gear_text_opacity", label = "文字透明度", hint = "只调整换装按钮上的方案名称文字。",
        min = 0, max = 100, step = 1, integer = true, unit = "%", slider = true, stepButtons = false,
        get = function() return GearAppearanceGet("textOpacity", 1.0) end,
        set = function(value) return GearAppearanceSet("text", value) end,
        storeId = GEAR_INDEX_STORE_ID, persistDelayMs = 250, persistReason = "gear_quick_text_opacity",
        slot = { size = "auto", minHeight = 62, hAlign = "fill" },
    })


    D:EmptyState(root, "v3_widgets_next", "更多悬浮组件继续迁移", "活动、任务追踪与换装快捷按钮已经使用统一悬浮组件宿主；跑商、债券、寻宝、钓鱼以及更多战斗悬浮组件会继续按独立生命周期迁入。")

    function root:Refresh()
        local host = S.UIV3 and S.UIV3.WidgetHost or nil
        local snapshot = host and host:Describe() or {}
        statusCard:SetData({ value = "正常", detail = "已登记 " .. tostring(snapshot.registered or 0) .. " · 已创建 " .. tostring(snapshot.created or 0) .. " · 正在显示 " .. tostring(snapshot.visible or 0) .. " · 已锁定 " .. tostring(snapshot.locked or 0) })
        local state = host and host:GetState("life.activities") or nil
        local visible = state ~= nil and state.visible == true
        local locked = state ~= nil and state.locked == true
        activityState:SetText(visible and (locked and "正在显示 · 已锁定" or "正在显示") or (locked and "已关闭 · 已锁定" or "已关闭"))
        activityState:SetTone(visible and "green" or "muted")
        activityButton:SetText(visible and "关闭" or "打开")
        activityLock:SetEnabled(state ~= nil and state.lockable == true)
        activityLock:SetText(locked and "解除锁定" or "锁定位置")
        activityReset:SetEnabled(state ~= nil and state.resettable == true)
        activityHint:SetText(locked and "锁定后禁止拖动和缩放" or "可拖动、缩放并保存位置")
        local overallOpacityEnabled = state ~= nil and state.overallOpacityAdjustable == true
        local backgroundOpacityEnabled = state ~= nil and state.backgroundOpacityAdjustable == true
        local textOpacityEnabled = state ~= nil and state.textOpacityAdjustable == true
        overallOpacityField:SetEnabled(overallOpacityEnabled)
        overallOpacityField:Render()
        backgroundOpacityField:SetEnabled(backgroundOpacityEnabled)
        backgroundOpacityField:Render()
        textOpacityField:SetEnabled(textOpacityEnabled)
        textOpacityField:Render()
        widthField:SetEnabled(S.Features ~= nil and S.Features.Activities ~= nil)
        widthField:Render()
        heightField:SetEnabled(S.Features ~= nil and S.Features.Activities ~= nil)
        heightField:Render()

        local gearState = host and host:GetState("combat.gear.quick") or nil
        local gearVisible = gearState ~= nil and gearState.visible == true
        local gearLocked = gearState ~= nil and gearState.locked == true
        gearStateText:SetText(gearVisible and (gearLocked and "正在显示 · 已锁定" or "正在显示") or (gearLocked and "已关闭 · 已锁定" or "已关闭"))
        gearStateText:SetTone(gearVisible and "green" or "muted")
        gearButton:SetText(gearVisible and "关闭" or "打开")
        gearLock:SetEnabled(gearState ~= nil and gearState.lockable == true)
        gearLock:SetText(gearLocked and "解除锁定" or "锁定位置")
        gearReset:SetEnabled(gearState ~= nil and gearState.resettable == true)
        gearHint:SetText(gearLocked and "锁定后所有换装快捷按钮禁止拖动" or "每套方案一个独立快捷按钮；可分别自由拖到任意位置")
        gearOverallOpacityField:SetEnabled(gearState ~= nil and gearState.overallOpacityAdjustable == true)
        gearOverallOpacityField:Render()
        gearBackgroundOpacityField:SetEnabled(gearState ~= nil and gearState.backgroundOpacityAdjustable == true)
        gearBackgroundOpacityField:Render()
        gearTextOpacityField:SetEnabled(gearState ~= nil and gearState.textOpacityAdjustable == true)
        gearTextOpacityField:Render()
        return true
    end
    function root:OnActivated() return self:Refresh() end
    root.numericFields = {
        opacity = overallOpacityField, -- compatibility alias for existing diagnostics
        overallOpacity = overallOpacityField, backgroundOpacity = backgroundOpacityField, textOpacity = textOpacityField,
        width = widthField, height = heightField,
        gearOverallOpacity = gearOverallOpacityField, gearBackgroundOpacity = gearBackgroundOpacityField, gearTextOpacity = gearTextOpacityField,
    }
    root:Refresh(); root.route = route
    return root
end

local function BuildSettings(parent, route)
    local root, rootErr = D:ScrollablePageRoot(parent, "v3_page_system_settings")
    if root == nil then return nil, "页面根组件创建失败：" .. tostring(rootErr or "未知错误") end
    D:PageHeader(root, "v3_settings_header", "全局设置", "这里只保存应用级设置。业务设置由对应功能自己管理。")
    local state = S.UIV3 and S.UIV3.ShellState or {}
    local shellSize = S.UIV3 and S.UIV3.ShellSizePolicy or { defaultWidth = 1040, defaultHeight = 700, minWidth = 1, minHeight = 1 }
    local routeRow = S.UIV3 and S.UIV3.Router and S.UIV3.Router:Get(state.lastRoute or "home") or nil
    local shellCard = D:InfoCard(root, { id = "v3_settings_shell", title = "主窗口", value = tostring(math.floor(tonumber(state.width) or shellSize.defaultWidth)) .. " × " .. tostring(math.floor(tonumber(state.height) or shellSize.defaultHeight)),
        detail = "当前页面：" .. tostring(routeRow and routeRow.title or "今日总览") .. "\n窗口位置、大小和最小化状态由新版主窗口存档独立保存。", detailMaxLines = 3,
        slot = { size = "fixed", height = 100, hAlign = "fill" } })

    local function ApplyUiSetting(key, value)
        if S.AppState == nil or type(S.AppState.Set) ~= "function" then return false, "应用设置不可用" end
        local previous = S.AppState.settings and S.AppState.settings[key] or nil
        local ok, err = S.AppState:Set(key, value, false)
        if ok ~= true then return false, err end
        if S.Layout ~= nil and type(S.Layout.Invalidate) == "function" then S.Layout:Invalidate() end
        local layoutOk = true
        if S.Layout ~= nil and type(S.Layout.RefreshNow) == "function" then
            layoutOk = S.Layout:RefreshNow(true) ~= false
        elseif S.UIHostManager ~= nil and type(S.UIHostManager.ApplyResponsiveLayout) == "function" then
            local applied = S.UIHostManager:ApplyResponsiveLayout(true)
            layoutOk = applied ~= false
        end
        if layoutOk ~= true then
            S.AppState:Set(key, previous, false)
            if S.Layout ~= nil and type(S.Layout.Invalidate) == "function" then S.Layout:Invalidate() end
            if S.Layout ~= nil and type(S.Layout.RefreshNow) == "function" then pcall(function() S.Layout:RefreshNow(true) end) end
            return false, "界面布局应用失败"
        end
        return true
    end

    local function ApplyShellSize(width, height)
        local shellState = S.UIV3 and S.UIV3.ShellState or nil
        local shell = S.UIV3 and S.UIV3.Shell or nil
        if shellState == nil or shell == nil then return false, "主窗口不可用" end
        local previous = { width = shellState.width, height = shellState.height, minimized = shellState.minimized }
        if width ~= nil then shellState.width = math.max(shellSize.minWidth, tonumber(width) or shellSize.defaultWidth) end
        if height ~= nil then shellState.height = math.max(shellSize.minHeight, tonumber(height) or shellSize.defaultHeight) end
        shellState.minimized = false
        if type(shell.ApplyMinimizedState) == "function" then shell:ApplyMinimizedState(false) end
        local ok = shell:ApplyLayout(false)
        if ok ~= true then
            shellState.width, shellState.height, shellState.minimized = previous.width, previous.height, previous.minimized
            if type(shell.ApplyMinimizedState) == "function" then pcall(function() shell:ApplyMinimizedState(previous.minimized == true) end) end
            pcall(function() shell:ApplyLayout(false) end)
            return false, "主窗口布局应用失败"
        end
        return true
    end

    local function RunSettingAction(id, execute)
        if S.ActionRunner ~= nil and type(S.ActionRunner.Run) == "function" then
            return S.ActionRunner:Run({ id = "settings." .. tostring(id), execute = execute, notify = false })
        end
        return execute()
    end

    local windowActions = RSUI:HorizontalBox({ id = "v3_settings_window_actions", parent = root, gap = 8, slot = { size = "fixed", height = 34, hAlign = "fill" } })
    RSUI:Button({ id = "v3_settings_center", parent = windowActions, text = "主窗口居中", compact = true, slot = { size = "fixed", width = 120 }, onClick = function()
        return RunSettingAction("center", function()
            local shellState = S.UIV3 and S.UIV3.ShellState or nil
            local shell = S.UIV3 and S.UIV3.Shell or nil
            if shellState == nil or shell == nil then return false end
            shellState.userMoved = false
            shellState.minimized = false
            if type(shell.ApplyMinimizedState) == "function" then shell:ApplyMinimizedState(false) end
            local ok = shell:ApplyLayout(false)
            if ok == true and type(S.UIV3.MarkShellStoreDirty) == "function" then S.UIV3:MarkShellStoreDirty(250, "settings_center") end
            return ok
        end)
    end })
    RSUI:Button({ id = "v3_settings_default_size", parent = windowActions, text = "恢复默认大小", compact = true, slot = { size = "fixed", width = 130 }, onClick = function()
        return RunSettingAction("default_size", function()
            local ok = ApplyShellSize(shellSize.defaultWidth, shellSize.defaultHeight)
            if ok == true and type(S.UIV3.MarkShellStoreDirty) == "function" then S.UIV3:MarkShellStoreDirty(250, "settings_default_size") end
            if ok == true then shellCard:SetData({ value = tostring(shellSize.defaultWidth) .. " × " .. tostring(shellSize.defaultHeight) }) end
            return ok
        end)
    end })
    RSUI:Button({ id = "v3_settings_reset_widgets", parent = windowActions, text = "恢复全部窗口位置", compact = true, slot = { size = "fixed", width = 146 }, onClick = function()
        return RunSettingAction("reset_all_windows", function()
            local shellState = S.UIV3 and S.UIV3.ShellState or nil
            local shell = S.UIV3 and S.UIV3.Shell or nil
            local host = S.UIV3 and S.UIV3.WidgetHost or nil
            if shellState == nil or shell == nil or host == nil then return false end
            shellState.userMoved = false
            shellState.minimized = false
            shellState.x, shellState.y, shellState.anchorH, shellState.anchorV = nil, nil, nil, nil
            shellState.offsetX, shellState.offsetY, shellState.coordinateSpace, shellState.savedUiScale = nil, nil, nil, nil
            if type(shell.ApplyMinimizedState) == "function" then shell:ApplyMinimizedState(false) end
            local shellOk = shell:ApplyLayout(false)
            local widgetsOk = type(host.ResetAllLayouts) == "function" and host:ResetAllLayouts() or false
            local launcherOk = type(S.UIV3.ResetLauncherPlacement) == "function" and S.UIV3:ResetLauncherPlacement(true) or false
            if shellOk == true and type(S.UIV3.MarkShellStoreDirty) == "function" then S.UIV3:MarkShellStoreDirty(250, "settings_reset_all_windows") end
            return shellOk == true and widgetsOk == true and launcherOk == true
        end)
    end })

    local windowPolicy = RSUI:HorizontalBox({ id = "v3_settings_window_policy", parent = root, gap = 8, slot = { size = "fixed", height = 32, hAlign = "fill" } })
    local shellLockButton = RSUI:Button({ id = "v3_settings_shell_lock", parent = windowPolicy, text = "锁定主窗口", compact = true, slot = { size = "fixed", width = 112 }, onClick = function()
        return RunSettingAction("shell_lock", function()
            local shell = S.UIV3 and S.UIV3.Shell or nil
            if shell == nil or type(shell.SetLocked) ~= "function" then return false end
            local ok = shell:SetLocked(not shell:IsLocked(), true)
            if ok == true and type(root.Refresh) == "function" then root:Refresh() end
            return ok
        end)
    end })
    local shellLockHint = RSUI:Text({ id = "v3_settings_shell_lock_hint", parent = windowPolicy, text = "", fontSize = 9, tone = "muted", overflow = "ellipsis", slot = { size = "fill", fill = 1 } })

    local shellWidthField = D:NumericSetting(root, {
        id = "v3_settings_shell_width", label = "主窗口宽度", hint = "直接输入设计宽度；不设屏幕/预设上限，拖动边缘缩放与这里使用同一份尺寸。",
        min = shellSize.minWidth, step = 1, integer = true, unit = " px", slider = false, stepButtons = false,
        get = function() return tonumber(S.UIV3 and S.UIV3.ShellState and S.UIV3.ShellState.width) or shellSize.defaultWidth end,
        set = function(value) return ApplyShellSize(value, nil) end,
        storeId = S.UIV3 and S.UIV3.ShellStoreId or nil, persistDelayMs = 250, persistReason = "settings_width",
    })
    local shellHeightField = D:NumericSetting(root, {
        id = "v3_settings_shell_height", label = "主窗口高度", hint = "直接输入设计高度；不设屏幕/预设上限，也不会通过预设按钮循环。",
        min = shellSize.minHeight, step = 1, integer = true, unit = " px", slider = false, stepButtons = false,
        get = function() return tonumber(S.UIV3 and S.UIV3.ShellState and S.UIV3.ShellState.height) or shellSize.defaultHeight end,
        set = function(value) return ApplyShellSize(nil, value) end,
        storeId = S.UIV3 and S.UIV3.ShellStoreId or nil, persistDelayMs = 250, persistReason = "settings_height",
    })
    local scaleField = D:NumericSetting(root, {
        id = "v3_settings_ui_scale", label = "界面缩放", hint = "可直接输入 75–125 的百分比；不使用档位轮换按钮。",
        min = 75, max = 125, step = 1, integer = true, unit = "%", slider = true, stepButtons = false,
        get = function() return math.floor(((S.AppState and S.AppState.settings and tonumber(S.AppState.settings.addonScale)) or 1) * 100 + 0.5) end,
        set = function(value) return ApplyUiSetting("addonScale", (tonumber(value) or 100) / 100) end,
        storeId = S.AppState and S.AppState.storeId or nil, persistDelayMs = 500, persistReason = "settings_addon_scale",
    })
    local fontField = D:NumericSetting(root, {
        id = "v3_settings_font_scale", label = "字体缩放", hint = "可直接输入 75–150 的百分比；输入框始终显示精确值。",
        min = 75, max = 150, step = 1, integer = true, unit = "%", slider = true, stepButtons = false,
        get = function() return math.floor(((S.AppState and S.AppState.settings and tonumber(S.AppState.settings.fontScale)) or 1) * 100 + 0.5) end,
        set = function(value) return ApplyUiSetting("fontScale", (tonumber(value) or 100) / 100) end,
        storeId = S.AppState and S.AppState.storeId or nil, persistDelayMs = 500, persistReason = "settings_font_scale",
    })

    D:StatusRow(root, "v3_settings_appearance", "界面外观", "深色（当前）", "default")

    function root:Refresh()
        local shellState = S.UIV3 and S.UIV3.ShellState or {}
        shellWidthField:Render()
        shellHeightField:Render()
        scaleField:Render()
        fontField:Render()
        shellCard:SetData({ value = tostring(math.floor(tonumber(shellState.width) or shellSize.defaultWidth)) .. " × " .. tostring(math.floor(tonumber(shellState.height) or shellSize.defaultHeight)) })
        shellLockButton:SetText(shellState.locked == true and "解除窗口锁定" or "锁定主窗口")
        shellLockHint:SetText(shellState.locked == true and "已锁定：标题栏拖动和边缘缩放暂时关闭" or "未锁定：可以拖动标题栏并从八个方向调整大小")
        return true
    end
    function root:OnActivated() return self:Refresh() end
    root.numericFields = { width = shellWidthField, height = shellHeightField, scale = scaleField, font = fontField }
    root:Refresh()
    root.route = route
    return root
end


local function BuildPersistenceAcceptanceCopyText()
    local persistence = S.Persistence
    if type(persistence) ~= "table" or type(persistence.BuildRuntimeAcceptanceSnapshot) ~= "function" then
        return nil, "存档验收快照能力不可用"
    end
    local snapshot = persistence:BuildRuntimeAcceptanceSnapshot({
        ids = PERSISTENCE_ACCEPTANCE_STORE_IDS,
        prefixes = PERSISTENCE_ACCEPTANCE_STORE_PREFIXES,
    })
    if type(snapshot) ~= "table" then return nil, "存档验收快照未返回结果" end

    local missingCount = #(snapshot.exactMissing or {})
    local parts = {
        "存档验收A" .. tostring(snapshot.contractVersion or "?")
            .. "｜" .. tostring(snapshot.buildTag or S.BuildTag or "?")
            .. "｜G" .. tostring(snapshot.generation or 0)
            .. "｜Store " .. tostring(snapshot.total or 0)
            .. "/FP " .. tostring(snapshot.fingerprinted or 0)
            .. "/Load " .. tostring(snapshot.loaded or 0)
            .. "/Dirty " .. tostring(snapshot.dirty or 0)
            .. "/Fence " .. tostring(snapshot.fenced or 0)
            .. "/Missing " .. tostring(missingCount)
            .. "｜ALL=" .. tostring(snapshot.aggregateFingerprint or "?"),
    }

    if missingCount > 0 then
        local values = {}
        for i = 1, math.min(missingCount, 4) do values[#values + 1] = tostring(snapshot.exactMissing[i]) end
        if missingCount > #values then values[#values + 1] = "+" .. tostring(missingCount - #values) end
        parts[#parts + 1] = "缺失=" .. table.concat(values, ",")
    end

    local detail, payloadRows, payloadHidden = {}, 0, 0
    for _, row in ipairs(snapshot.rows or {}) do
        local isPayload = tostring(row.id or ""):sub(1, #PERSISTENCE_ACCEPTANCE_STORE_PREFIXES[1]) == PERSISTENCE_ACCEPTANCE_STORE_PREFIXES[1]
        local include = not isPayload or payloadRows < 8
        if include then
            if isPayload then payloadRows = payloadRows + 1 end
            local state = "L" .. tostring(row.loaded == true and 1 or 0)
                .. "D" .. tostring(row.dirty == true and 1 or 0)
                .. "F" .. tostring(row.writeFenced == true and 1 or 0)
                .. "S" .. tostring(row.schema or "?")
                .. "R" .. tostring(row.dirtyRevision or 0) .. "/" .. tostring(row.lastSavedRevision or 0)
            local fingerprint = tostring(row.fingerprint or (row.error and ("ERR:" .. tostring(row.error)) or "?"))
            fingerprint = fingerprint:gsub("[\r\n]+", " ")
            if #fingerprint > 72 then fingerprint = fingerprint:sub(1, 72) .. "…" end
            detail[#detail + 1] = tostring(row.id or "?") .. "=" .. fingerprint .. "[" .. state .. "]"
        elseif isPayload then
            payloadHidden = payloadHidden + 1
        end
    end
    if payloadHidden > 0 then detail[#detail + 1] = "v3.gear.payload.*=+" .. tostring(payloadHidden) .. "(ALL已包含)" end
    if #detail > 0 then parts[#parts + 1] = table.concat(detail, " | ") end
    return table.concat(parts, " ║ "), nil, snapshot
end

local function BuildDiagnostics(parent, route)
    local root, rootErr = D:ScrollablePageRoot(parent, "v3_page_system_diagnostics")
    if root == nil then return nil, "页面根组件创建失败：" .. tostring(rootErr or "未知错误") end
    D:PageHeader(root, "v3_diag_header", "诊断与维护", "用于检查框架健康状态、界面所有权、功能生命周期、存档、调度器和原生接口。")

    local function RunDiagnosticAction(id, execute, options)
        options = type(options) == "table" and options or {}
        if S.ActionRunner ~= nil and type(S.ActionRunner.Run) == "function" then
            return S.ActionRunner:Run({
                id = "diagnostics." .. tostring(id),
                execute = execute,
                notify = options.notify == true,
                successTitle = options.successTitle or "自检完成",
                errorTitle = options.errorTitle or "自检发现问题",
                successText = options.successText,
                errorText = options.errorText,
            })
        end
        return execute()
    end

    local actionRow = RSUI:HorizontalBox({ id = "v3_diag_actions", parent = root, gap = 8, slot = { size = "fixed", height = 34, hAlign = "fill" } })
    RSUI:Button({ id = "v3_diag_refresh", parent = actionRow, text = "刷新诊断", compact = true, slot = { size = "fixed", width = 104 }, onClick = function()
        return RunDiagnosticAction("refresh", function() return type(root.Refresh) == "function" and root:Refresh() or false end)
    end })
    RSUI:Button({ id = "v3_diag_full_check", parent = actionRow, text = "运行完整自检", compact = true, slot = { size = "fixed", width = 120 }, onClick = function()
        return RunDiagnosticAction("full_check", function()
            if S.FoundationGate == nil or type(S.FoundationGate.Run) ~= "function" then return false, "基础框架自检不可用" end
            local report = S.FoundationGate:Run({ skipSequences = true })
            if type(root.Refresh) == "function" then root:Refresh(report) end
            if type(report) ~= "table" then return false, "自检未返回报告" end
            local summary = "阻断 " .. tostring(report.blockers or 0) .. " · 警告 " .. tostring(report.warnings or 0)
            -- The diagnostic action itself succeeded even when the report finds
            -- blockers. Do not emit ACTION_FAILED for a healthy self-check that
            -- merely discovered a real problem; that fake fault can hide the
            -- original page/native error in the recent-fault window.
            local toastHost = S.UIV3 and S.UIV3.ToastHost or nil
            if type(toastHost) == "table" and type(toastHost.Notify) == "function" then
                toastHost:Notify({
                    id = "v3_full_check_result",
                    title = tostring(report.status or "") == "READY" and "完整自检通过" or "完整自检完成",
                    detail = summary,
                    tone = (tonumber(report.blockers) or 0) > 0 and "red" or ((tonumber(report.warnings) or 0) > 0 and "yellow" or "green"),
                    durationMs = 3600,
                })
            end
            return true, summary
        end, { notify = false })
    end })
    RSUI:Button({ id = "v3_diag_output", parent = actionRow, text = "输出诊断摘要", compact = true, slot = { size = "fixed", width = 124 }, onClick = function()
        return RunDiagnosticAction("output", function()
            if S.FoundationGate == nil or type(S.FoundationGate.BuildCopyText) ~= "function" then return false end
            local text = S.FoundationGate:BuildCopyText(false)
            if type(S.SafeChat) == "function" then S.SafeChat(text, "info", "diagnostics") end
            return true
        end)
    end })
    local actionRow2 = RSUI:HorizontalBox({ id = "v3_diag_actions_2", parent = root, gap = 8, slot = { size = "fixed", height = 34, hAlign = "fill" } })
    RSUI:Button({ id = "v3_diag_reload", parent = actionRow2, text = "重新加载文件", compact = true, slot = { size = "fixed", width = 130 }, onClick = function()
        return RunDiagnosticAction("reload", function()
            -- ReloadCodeFromDisk is the single reload/Flush Authority. Do not
            -- pre-Flush here: a swallowed first failure would double-attempt a
            -- write and hide the exact store id + reason needed for acceptance.
            if type(S.ReloadCodeFromDisk) ~= "function" then return false end
            return S.ReloadCodeFromDisk("v3_diagnostics")
        end)
    end })
    RSUI:Button({ id = "v3_diag_toast_test", parent = actionRow2, text = "测试通知", compact = true, slot = { size = "fixed", width = 96 }, onClick = function()
        return RunDiagnosticAction("toast_test", function()
            local host = S.UIV3 and S.UIV3.ToastHost or nil
            if host == nil or type(host.Notify) ~= "function" then return false end
            return host:Notify({ title = "测试通知", detail = "通知宿主工作正常；该提示会自动消失。", tone = "green", durationMs = 3200 }) ~= nil
        end)
    end })
    RSUI:Text({ id = "v3_diag_reload_hint", parent = actionRow2, text = "重载会先执行唯一严格 Flush；失败会取消重载并保留 Store ID + 原因。完整自检只读取快照。", fontSize = 9, tone = "muted", overflow = "ellipsis", slot = { size = "fill", fill = 1 } })
    local actionRow3 = RSUI:HorizontalBox({ id = "v3_diag_actions_3", parent = root, gap = 8, slot = { size = "fixed", height = 34, hAlign = "fill" } })
    RSUI:Button({ id = "v3_diag_persistence_acceptance", parent = actionRow3, text = "输出存档验收", compact = true, slot = { size = "fixed", width = 130 }, onClick = function()
        return RunDiagnosticAction("persistence_acceptance", function()
            local text, err = BuildPersistenceAcceptanceCopyText()
            if text == nil then return false, err or "存档验收快照失败" end
            if type(S.SafeChat) == "function" then S.SafeChat(text, "info", "diagnostics") end
            return true
        end)
    end })
    RSUI:Text({ id = "v3_diag_persistence_acceptance_hint", parent = actionRow3, text = "只读当前 Domain 指纹，不写 SaveData；Fresh Reload 前后各复制一次，ALL 与单 Store 指纹应保持一致。", fontSize = 9, tone = "muted", overflow = "ellipsis", slot = { size = "fill", fill = 1 } })

    local card = D:InfoCard(root, { id = "v3_diag_gate", title = "基础框架检查", value = "检查中", detail = "尚未运行", slot = { size = "fixed", height = 104, hAlign = "fill" } })
    local hostRow = D:StatusRow(root, "v3_diag_host", "界面宿主", "-", "default")
    local featureRow = D:StatusRow(root, "v3_diag_features", "功能目录", "-", "default")
    local widgetRow = D:StatusRow(root, "v3_diag_widgets", "悬浮组件", "-", "default")
    local windowRow = D:StatusRow(root, "v3_diag_windowing", "窗口基础能力", "-", "default")
    local modalRow = D:StatusRow(root, "v3_diag_modal", "模态窗口宿主", "-", "default")
    local toastRow = D:StatusRow(root, "v3_diag_toast", "通知宿主", "-", "default")
    local persistenceRow = D:StatusRow(root, "v3_diag_persistence", "新版存档", "-", "default")
    local persistenceIncidentRow = D:StatusRow(root, "v3_diag_persistence_incident", "最近存档落盘", "-", "default")
    local schedulerRow = D:StatusRow(root, "v3_diag_scheduler", "统一调度器", "-", "default")
    local runtimeFoundationRow = D:StatusRow(root, "v3_diag_runtime_foundation", "共享运行基础", "-", "default")
    local combatFoundationRow = D:StatusRow(root, "v3_diag_combat_foundation", "战斗事实基础", "-", "default")
    local interactionFoundationRow = D:StatusRow(root, "v3_diag_interaction_foundation", "UI 交互基础", "-", "default")
    local uiStateFoundationRow = D:StatusRow(root, "v3_diag_ui_state_foundation", "UI 状态 / 持久化", "-", "default")
    local eventRow = D:StatusRow(root, "v3_diag_events", "统一事件总线", "-", "default")
    local nativeRow = D:StatusRow(root, "v3_diag_native", "原生接口", "-", "default")
    local authorityRow = D:StatusRow(root, "v3_diag_authority", "界面所有权", "-", "default")
    local sequenceRow = D:StatusRow(root, "v3_diag_sequence", "自动验收", "-", "default")
    local bootRow = D:StatusRow(root, "v3_diag_boot", "启动状态", "-", "default")

    local function CountTable(tbl)
        local count = 0
        for _ in pairs(type(tbl) == "table" and tbl or {}) do count = count + 1 end
        return count
    end

    function root:Refresh(gateOverride)
        local gate = type(gateOverride) == "table" and gateOverride
            or (S.FoundationGate and S.FoundationGate:Run({ skipSequences = true }) or nil)
        local host = S.UIHostManager and S.UIHostManager:Describe() or {}
        local features = S.FeatureRegistry and S.FeatureRegistry:Describe() or {}
        local widgets = S.UIV3.WidgetHost and S.UIV3.WidgetHost:Describe() or {}
        local windowing = S.RSUI and S.RSUI.Windowing and S.RSUI.Windowing:Describe() or {}
        local modal = S.UIV3 and S.UIV3.ModalHost and S.UIV3.ModalHost:Describe() or {}
        local toast = S.UIV3 and S.UIV3.ToastHost and S.UIV3.ToastHost:Describe() or {}
        local persistence = S.Persistence and S.Persistence:Describe() or {}
        local native = S.NativeCapabilities and S.NativeCapabilities:Describe() or {}
        local imports = native.imports or {}
        local authority = S.UI and type(S.UI.GetAuthoritySnapshot) == "function" and S.UI:GetAuthoritySnapshot() or {}
        local scheduler = S.Scheduler or {}
        local eventBus = S.Events or {}
        local sequences = gate and gate.sequences or (S.FoundationGate and S.FoundationGate.lastSequences) or {}
        local demand = S.Demand and type(S.Demand.Describe) == "function" and S.Demand:Describe() or {}
        local refresh = S.RefreshCoordinator and type(S.RefreshCoordinator.Describe) == "function" and S.RefreshCoordinator:Describe() or {}
        local combatBus = S.Services and S.Services.CombatEventBusV3 and type(S.Services.CombatEventBusV3.GetHealth) == "function" and S.Services.CombatEventBusV3:GetHealth() or {}
        local buffDisplay = S.Features and S.Features.BuffDisplay and type(S.Features.BuffDisplay.GetHealth) == "function" and S.Features.BuffDisplay:GetHealth() or {}
        local unitIdentity = S.Services and S.Services.UnitIdentityV3 and type(S.Services.UnitIdentityV3.GetHealth) == "function" and S.Services.UnitIdentityV3:GetHealth() or {}
        local deathReview = S.Features and S.Features.DeathReview and type(S.Features.DeathReview.GetHealth) == "function" and S.Features.DeathReview:GetHealth() or {}
        local viewState = S.RSUI and S.RSUI.ViewState and type(S.RSUI.ViewState.GetSnapshot) == "function" and S.RSUI.ViewState:GetSnapshot() or {}
        local actions = S.ActionRunner and type(S.ActionRunner.GetSnapshot) == "function" and S.ActionRunner:GetSnapshot() or {}
        local bindings = S.UI and S.UI.Binding and type(S.UI.Binding.GetSnapshot) == "function" and S.UI.Binding:GetSnapshot() or {}
        local floating = S.RSUI and S.RSUI.FloatingSurface and type(S.RSUI.FloatingSurface.GetSnapshot) == "function" and S.RSUI.FloatingSurface:GetSnapshot() or {}
        local snap = S.Layout and type(S.Layout.GetScreenSnapSnapshot) == "function" and S.Layout:GetScreenSnapSnapshot() or {}

        if gate ~= nil then
            local healthy = tostring(gate.status or "") == "READY" and (tonumber(gate.blockers) or 0) == 0
            card:SetData({ value = healthy and "正常" or "需要处理", detail = "阻断 " .. tostring(gate.blockers or 0) .. " · 警告 " .. tostring(gate.warnings or 0) .. " · 检查项 " .. tostring(#(gate.checks or {})) })
        end
        hostRow.valueText:SetText("当前 " .. tostring(host.activeId == "v3" and "新版" or host.activeId or "未知") .. " · 共 " .. tostring(host.total or 0))
        featureRow.valueText:SetText("已登记 " .. tostring(features.total or 0) .. " · 运行 " .. tostring(S.FeatureRuntime and S.FeatureRuntime:Describe().enabled or 0))
        widgetRow.valueText:SetText("登记 " .. tostring(widgets.registered or 0) .. " · 显示 " .. tostring(widgets.visible or 0) .. " · 锁定 " .. tostring(widgets.locked or 0))
        windowRow.valueText:SetText("接入 " .. tostring(windowing.attached or 0) .. " · 拖动 " .. tostring(windowing.drags or 0) .. " · 缩放 " .. tostring(windowing.resizes or 0))
        modalRow.valueText:SetText((modal.attached == true and "正常" or "未挂载") .. " · 当前 " .. tostring(modal.count or 0))
        toastRow.valueText:SetText((toast.attached == true and "正常" or "未挂载") .. " · 当前 " .. tostring(toast.active or 0) .. " · 自动关闭 " .. tostring(toast.autoDismissals or 0))
        persistenceRow.valueText:SetText("存档 " .. tostring(persistence.total or 0) .. " · 待写 " .. tostring(persistence.dirty or 0) .. " · 写入保护 " .. tostring(persistence.fenced or 0))
        local lastFlush = type(persistence.lastFlush) == "table" and persistence.lastFlush or nil
        local flushFailures = lastFlush and type(lastFlush.failures) == "table" and lastFlush.failures or {}
        if lastFlush ~= nil and lastFlush.ok == false then
            local first = tostring(flushFailures[1] or "未知 Store:save failed"):gsub("[\r\n]+", " ")
            persistenceIncidentRow.valueText:SetText("失败 " .. tostring(#flushFailures) .. " 项 · " .. first)
        elseif (tonumber(persistence.fenced) or 0) > 0 then
            local first = nil
            for _, row in ipairs(persistence.rows or {}) do
                if row.writeFenced == true then
                    first = tostring(row.id or "?") .. ":" .. tostring(row.writeFenceReason or row.lastError or "write_fenced")
                    break
                end
            end
            persistenceIncidentRow.valueText:SetText("写保护 " .. tostring(persistence.fenced or 0) .. " 项 · " .. tostring(first or "请输出诊断摘要"))
        elseif lastFlush ~= nil and lastFlush.ok == true then
            persistenceIncidentRow.valueText:SetText("成功 · 当前待写 " .. tostring(persistence.dirty or 0))
        else
            persistenceIncidentRow.valueText:SetText("尚未执行本进程 Flush · 当前待写 " .. tostring(persistence.dirty or 0))
        end
        local taskCount, enabledTasks = 0, 0
        for _, task in pairs(type(scheduler.tasks) == "table" and scheduler.tasks or {}) do taskCount = taskCount + 1; if task.enabled == true then enabledTasks = enabledTasks + 1 end end
        local backlog = type(scheduler.DescribeBacklog) == "function" and scheduler:DescribeBacklog() or {}
        schedulerRow.valueText:SetText("任务 " .. tostring(enabledTasks) .. "/" .. tostring(taskCount) .. " · 待执行 " .. tostring(backlog.pending or 0))
        runtimeFoundationRow.valueText:SetText("Demand " .. tostring(demand.active or 0) .. "/" .. tostring(demand.leases or 0)
            .. " · Refresh pending " .. tostring(refresh.pending or 0)
            .. " · rollbackFail " .. tostring(demand.rollbackFailures or 0)
            .. " · quiesceFail " .. tostring(demand.quiesceFailures or 0))
        combatFoundationRow.valueText:SetText("Bus " .. tostring(combatBus.running == true and "运行" or "空闲")
            .. " · Consumer " .. tostring(combatBus.consumers or 0)
            .. " · Coverage " .. tostring(combatBus.coverageState or "INACTIVE")
            .. " · Host " .. tostring(combatBus.globalHosts or 0) .. "/2"
            .. " · Park " .. tostring(combatBus.privateParked == true and 1 or 0) .. "/" .. tostring(combatBus.globalParkedHosts or 0)
            .. " · J " .. tostring(combatBus.journalPending or 0) .. "/" .. tostring(combatBus.journalReplayed or 0) .. "/" .. tostring(combatBus.journalDropped or 0)
            .. " · Facts " .. tostring(combatBus.received or 0) .. "/" .. tostring(combatBus.delivered or 0)
            .. " · Mut " .. tostring(combatBus.factMutationErrors or 0)
            .. " · BuffDisplay " .. tostring(buffDisplay.ok == true and "ON" or "off") .. "/" .. tostring(buffDisplay.consumers or 0)
            .. " · Aura " .. tostring(buffDisplay.auraHeld == true and "held" or "idle")
            .. " · Identity " .. tostring(unitIdentity.cache or 0) .. "/" .. tostring(unitIdentity.cacheMax or 0)
            .. " · DeathReview " .. tostring(deathReview.ok == true and "ON" or "off")
            .. " H" .. tostring(deathReview.history or 0) .. "/D" .. tostring(deathReview.deaths or 0)
            .. "/Q" .. tostring(deathReview.pendingDeath == true and 1 or 0) .. "/F" .. tostring(deathReview.deferredFinalizeFailures or 0))
        interactionFoundationRow.valueText:SetText("View R/E/Err " .. tostring(viewState.states and viewState.states.ready or 0)
            .. "/" .. tostring(viewState.states and viewState.states.empty or 0) .. "/" .. tostring(viewState.states and viewState.states.error or 0)
            .. " · Action busy " .. tostring(actions.busy or 0) .. " · failed " .. tostring(actions.failed or 0))
        uiStateFoundationRow.valueText:SetText("Floating " .. tostring(floating.active or 0) .. " · Snap " .. tostring(snap.registered or 0)
            .. " · Binding A/P/D/E " .. tostring(bindings.active or 0) .. "/" .. tostring(bindings.persistentActive or 0)
            .. "/" .. tostring(bindings.dirty or 0) .. "/" .. tostring(bindings.errored or 0))
        eventRow.valueText:SetText("原生事件 " .. tostring(CountTable(eventBus.registered)) .. " · 内部通道 " .. tostring(CountTable(eventBus.internalListeners)))
        nativeRow.valueText:SetText("基础接口 " .. tostring(imports.core or 0) .. " · 功能接口 " .. tostring(imports.feature or 0) .. " · 对象 " .. tostring(imports.objects or 0))
        authorityRow.valueText:SetText("违规 " .. tostring(authority.violations or 0) .. " · 冲突 " .. tostring(authority.conflicts or 0))
        if sequences.skipped == true then
            sequenceRow.valueText:SetText("已登记 " .. tostring(sequences.registered or sequences.total or 0) .. " · 实机诊断不执行状态变更序列")
        else
            sequenceRow.valueText:SetText("通过 " .. tostring(sequences.passed or 0) .. "/" .. tostring(sequences.total or 0) .. " · 失败 " .. tostring(sequences.failed or 0))
        end
        local rawStage = tostring(S.BootStage or "unknown")
        bootRow.valueText:SetText((S.Ready == true and "已就绪" or "未就绪") .. " · 阶段 " .. tostring(BOOT_STAGE_NAMES[rawStage] or "未知"))
        return true
    end
    function root:OnActivated() return self:Refresh() end
    root:Refresh(); root.route = route
    return root
end

Pages.BuildHome = BuildHome
Pages.BuildFeaturePlaceholder = BuildFeaturePlaceholder
Pages.BuildFeatures = BuildFeatures
Pages.BuildWidgets = BuildWidgets
Pages.BuildSettings = BuildSettings
Pages.BuildDiagnostics = BuildDiagnostics

local registrations = {
    ["home"] = BuildHome,
    ["system.features"] = BuildFeatures,
    ["system.widgets"] = BuildWidgets,
    ["system.settings"] = BuildSettings,
    ["system.diagnostics"] = BuildDiagnostics,
}
for route, factory in pairs(registrations) do
    local ok, err = PageHost:RegisterFactory(route, factory)
    if ok ~= true then error(err) end
end
local fallbackOk, fallbackErr = PageHost:RegisterFactory("*", BuildFeaturePlaceholder)
if fallbackOk ~= true then error(fallbackErr) end

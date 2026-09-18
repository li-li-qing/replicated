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
    "v3.death_review",
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

-- 维护（overview-content-1）：统一首页入口不变；独立内容模块仅拥有UI，
-- 不能启动关闭的Feature、复用原生浮窗或复制业务数据。初始化失败照常报告。
local function BuildHome(parent, route)
    local home=S.UIV3 and S.UIV3.HomeOverview
    if not home or type(home.Build)~="function" then return nil,"今日总览内容模块未加载" end
    return home:Build(parent, route)
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
    -- 维护（2026-09-15，numeric-range-v2）：透明度百分比是归一化业务量，不属于“推荐窗口”。
    -- 明确固定 0..100，防止通用自适应 Slider 把非法精确输入扩展成新的范围；Authority 仍由 WidgetHost/Feature
    -- 回读确认，旧 appearance 配置与持久化键不变。
    local overallOpacityField = D:NumericSetting(activityStack, {
        id = "v3_widgets_activity_overall_opacity", label = "整体透明度", hint = "作用于整个悬浮窗，并与背景/文字透明度相乘；可直接输入 0–100。",
        min = 0, max = 100, hardMin = 0, hardMax = 100, fixedRange = true, step = 1, integer = true, unit = "%", slider = true, stepButtons = false,
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
        min = 0, max = 100, hardMin = 0, hardMax = 100, fixedRange = true, step = 1, integer = true, unit = "%", slider = true, stepButtons = false,
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
        min = 0, max = 100, hardMin = 0, hardMax = 100, fixedRange = true, step = 1, integer = true, unit = "%", slider = true, stepButtons = false,
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
    -- 同一 Numeric Range v2 规则：换装快捷按钮透明度是真实 0..100 百分比，因此保留 fixedRange。
    -- 这里只声明 Presentation 安全语义，不新增 Store，也不改变 Gear Appearance 的 Authority/升级兼容。
    local gearOverallOpacityField = D:NumericSetting(gearStack, {
        id = "v3_widgets_gear_overall_opacity", label = "整体透明度", hint = "同时作用于所有换装快捷按钮，并与背景/文字透明度相乘；可直接输入 0–100。",
        min = 0, max = 100, hardMin = 0, hardMax = 100, fixedRange = true, step = 1, integer = true, unit = "%", slider = true, stepButtons = false,
        get = function() return GearAppearanceGet("overallOpacity", 0.94) end,
        set = function(value) return GearAppearanceSet("overall", value) end,
        storeId = GEAR_INDEX_STORE_ID, persistDelayMs = 250, persistReason = "gear_quick_overall_opacity",
        slot = { size = "auto", minHeight = 62, hAlign = "fill" },
    })
    local gearBackgroundOpacityField = D:NumericSetting(gearStack, {
        id = "v3_widgets_gear_background_opacity", label = "背景透明度", hint = "只调整所有换装快捷按钮的背景，不降低文字清晰度。",
        min = 0, max = 100, hardMin = 0, hardMax = 100, fixedRange = true, step = 1, integer = true, unit = "%", slider = true, stepButtons = false,
        get = function() return GearAppearanceGet("backgroundOpacity", 1.0) end,
        set = function(value) return GearAppearanceSet("background", value) end,
        storeId = GEAR_INDEX_STORE_ID, persistDelayMs = 250, persistReason = "gear_quick_background_opacity",
        slot = { size = "auto", minHeight = 62, hAlign = "fill" },
    })
    local gearTextOpacityField = D:NumericSetting(gearStack, {
        id = "v3_widgets_gear_text_opacity", label = "文字透明度", hint = "只调整换装按钮上的方案名称文字。",
        min = 0, max = 100, hardMin = 0, hardMax = 100, fixedRange = true, step = 1, integer = true, unit = "%", slider = true, stepButtons = false,
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
            shellState.savedLogicalWidth, shellState.savedLogicalHeight = nil, nil
            shellState.normalizedCenterX, shellState.normalizedCenterY = nil, nil
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

    local detail, payloadRows, payloadHidden, deathProbe = {}, 0, 0, nil
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
            if tostring(row.id or "") == "v3.death_review" and type(row.historicalRecoveryProbe) == "string"
                and row.historicalRecoveryProbe ~= "" then
                deathProbe = row.historicalRecoveryProbe:gsub("[\r\n]+", " ")
                if #deathProbe > 180 then deathProbe = deathProbe:sub(1, 180) .. "…" end
            end
        elseif isPayload then
            payloadHidden = payloadHidden + 1
        end
    end
    if payloadHidden > 0 then detail[#detail + 1] = "v3.gear.payload.*=+" .. tostring(payloadHidden) .. "(ALL已包含)" end
    if deathProbe ~= nil then parts[#parts + 1] = "DRProbe=" .. deathProbe end
    if #detail > 0 then parts[#parts + 1] = table.concat(detail, " | ") end
    return table.concat(parts, " ║ "), nil, snapshot
end

local function BuildDiagnostics(parent, route)
    -- 维护（2026-09-12）：旧ScrollBox的OuterSize只读子项Measure，不采用slot.height；
    -- 原生编辑框不是Border的RSUI content，因此Border测量为0，实际布局复现宿主高仅1。
    -- 同时回执早于编辑框写入。诊断主体为run/print与前后翻页+单正文，采用Foundation VerticalBox fill，
    -- 由共享布局分配正文空间，无Tick/自制滚动/新弹窗；不更改其他长设置页的ScrollBox。
    local root, rootErr = D:PageRoot(parent,{id="v3_page_system_diagnostics",gap=6})
    if root==nil then return nil,"页面根组件创建失败："..tostring(rootErr or "未知错误") end
    root.route=route
    -- 中文维护注释（2026-09-18，module-diagnostics-system-scope-1）：全局诊断页不删除，
    -- 但职责固定为 Core/Foundation/完整维护取证；普通业务故障的默认入口已经迁到模块页右上角。
    -- 禁止为了“方便”把所有 Feature 的日常诊断再次塞回这里；只有维护者明确需要全局证据时才使用
    -- 下方完整报告。这个页面的旧复制框继续保持兼容，不允许为了修模块 DiagnosticCopyBox 去改普通输入生命周期。
    D:PageHeader(root,"v3_diag_header","系统诊断与维护",
        "这里保留 Core / Foundation 的完整维护自检。业务模块故障请优先使用对应页面右上角“诊断”，只采集该模块的错误、Store 与运行状态；完整报告仅在维护底层框架时使用。")
    local actions=RSUI:HorizontalBox({id="v3_diag_actions",parent=root,gap=8,slot={size="fixed",height=32,hAlign="fill"}})
    local runButton=RSUI:Button({id="v3_diag_full_check",parent=actions,text="运行自检",compact=true,slot={size="fixed",width=120}})
    local printButton=RSUI:Button({id="v3_diag_output",parent=actions,text="打印故障报告",compact=true,slot={size="fixed",width=144}})
    local fullReportButton=RSUI:Button({id="v3_diag_output_full",parent=actions,text="完整报告",compact=true,slot={size="fixed",width=112}})
    local card=D:InfoCard(root,{id="v3_diag_gate",title="自检结果",value="尚未运行",
        detail="不会清除历史错误、修改配置或解除写保护。",slot={size="fixed",height=60,hAlign="fill"}})
    local status=RSUI:Text({id="v3_diag_report_status",parent=root,fontSize=10,tone="accent",overflow="wrap",maxLines=3,
        text="系统报告用于 Core / Foundation 维护，仍完整保留本次加载阻断与故障 Store 取证；业务模块请优先使用模块右上角诊断，避免复制无关内容。",
        slot={size="fixed",height=50,hAlign="fill"}})
    -- 维护：导航独立于run/print，不创建N个Native编辑框；复用同一框显示逻辑编辑框1..N，
    -- 节省控件/焦点资源。前后按钮达到边界即禁用；没有隐式轮转、没有新事件或后台任务。
    local navigation=RSUI:HorizontalBox({id="v3_diag_report_navigation",parent=root,gap=8,slot={size="fixed",height=30,hAlign="fill"}})
    local previousButton=RSUI:Button({id="v3_diag_report_prev",parent=navigation,text="上一页",compact=true,slot={size="fixed",width=96}})
    local pageLabel=RSUI:Text({id="v3_diag_report_page",parent=navigation,text="0 / 0",slot={size="fixed",width=90}})
    local nextButton=RSUI:Button({id="v3_diag_report_next",parent=navigation,text="下一页",compact=true,slot={size="fixed",width=96}})
    local host=RSUI:Border({id="v3_diag_report_host",parent=root,padding=4,variant="card",
        slot={size="fill",fill=1,hAlign="fill",vAlign="fill"}})
    local ui=S.UI
    local editor,editorReady,editorError
    if host and host.root and type(ui)=="table" and type(ui.CreateMultiEditBox)=="function" then
        -- 原生容量须实际回读，不能因 SetMaxTextLength(1MiB) 不抛错就认定支持1MiB。
        -- 维护（2026-09-12）：32KiB只为请求值，RU本次回报9215。交付按实际返回容量
        -- 分段，无返回时保守3500，再以真实回读协商；两个主操作之外是明确的上一页/下一页。
        local ok,value,err=pcall(ui.CreateMultiEditBox,ui,host.root,"v3_diag_report_edit",4,4,300,96,32768)
        if ok then editor=value;editorError=err else editorError=value end
        if editor and type(editor.SetText)=="function" and type(editor.GetText)=="function" and type(ui.BindDeferredInputActivation)=="function" then
            local bound,accepted,bindErr=pcall(ui.BindDeferredInputActivation,ui,editor,host.owner,"v3_diag_report_edit",
                {preserveFocusedSelection=true}) -- 维护：仅此复制框启用实时焦点身份保护，不影响业务表单。
            editorReady=bound and accepted==true
            if not editorReady then editorError=bound and bindErr or accepted end
        end
        if editor and not editorReady then
            if type(ui.RetireInputWidget)=="function" then pcall(ui.RetireInputWidget,ui,editor,host.owner,"diagnostic_editor_unavailable") end
            if type(editor.Show)=="function" then pcall(editor.Show,editor,false) end
            editor=nil
        end
    end
    -- 维护（report-selection-1）：原先每次同尺寸布局仍进入Native几何回读修复，
    -- GetWidth/GetEffectiveOffset抖动时会重设Extent/Anchor并破坏Native选区。
    -- 此原生框几何只由本宿主提交：已成功的相同逻辑尺寸/父级不再重复写；真实resize或失败重试仍执行。
    -- 不改变共享RSUI的strict规则，不用SetText/SetFocus轮询“维持”选区；缓存随页面生命周期释放。
    local geometryError, geometryWidth, geometryHeight, geometryParent
    local copyStats={textWrites=0,geometryApplications=0,geometrySkips=0}
    local function CopyNow()return type(S.NowMs)=="function" and S.NowMs() or 0 end
    local function WriteReportText(text,reason)
        copyStats.textWrites=copyStats.textWrites+1;copyStats.lastTextReason=reason
        copyStats.lastTextAt=CopyNow();copyStats.lastTextBytes=#text
        return pcall(editor.SetText,editor,text)
    end
    function root:GetReportInputSnapshot()
        local input={available=false}
        if editor and type(ui.GetCopyInputSnapshot)=="function" then input=ui:GetCopyInputSnapshot(editor) end
        return {patch="report-selection-1",available=editorReady==true,input=input,
            textWrites=copyStats.textWrites,lastTextReason=copyStats.lastTextReason,
            lastTextAt=copyStats.lastTextAt,lastTextBytes=copyStats.lastTextBytes,
            geometryApplications=copyStats.geometryApplications,geometrySkips=copyStats.geometrySkips,
            lastGeometryAt=copyStats.lastGeometryAt,geometryError=geometryError}
    end
    if host and type(host.Layout)=="function" then
        local arrange=host.Layout
        function host:Layout(x,y,width,height)
            local result=arrange(self,x,y,width,height)
            -- 原生多行框不属于RSUI子组件，故在宿主layout时交给共享Extent/Anchor事务；
            -- 只用一个左上锚+明确尺寸，避免固定300宽/双锚与不同分辨率相冲突。
            if editor then
                local w,h=math.max(1,width-8),math.max(1,height-8)
                if geometryError==nil and geometryWidth==w and geometryHeight==h and geometryParent==self.root then
                    copyStats.geometrySkips=copyStats.geometrySkips+1
                    return result
                end
                copyStats.geometryApplications=copyStats.geometryApplications+1;copyStats.lastGeometryAt=CopyNow()
                local ok,accepted,_,err=pcall(ui.EnsureExtent,ui,editor,w,h,self.owner)
                geometryError=not(ok and accepted==true) and (err or "editor_extent_failed") or nil
                local anchored,yes,_,anchorErr=pcall(ui.EnsureAnchor,ui,editor,self.root,4,4,self.owner)
                if not anchored or yes~=true then geometryError=anchorErr or "editor_anchor_failed" end
                -- 维护：只有整组原生几何提交成功才能缓存；失败不伪装no-op，后续布局必须再试。
                if geometryError==nil then geometryWidth,geometryHeight,geometryParent=w,h,self.root end
            end
            return result
        end
    end
    local function ClearReport()
        root.selfCheckText,root.selfCheckMeta=nil,nil
        -- 同一快照分段缓存只属于此页；运行新自检/隐藏一起释放，禁止持久化或跨快照混页。
        root.selfCheckDelivery,root.selfCheckPart,root.selfCheckRetry=nil,nil,nil
        if editor then WriteReportText("","clear_report") end -- 维护：显式清空也计入输入诊断，不记录正文。
    end
    local function Backend(method)
        local diagnostic=S.DiagnosticsManager
        if type(diagnostic)~="table" or type(diagnostic[method])~="function" then return nil,"统一自检后端不可用，请完整覆盖补丁后重新加载文件。" end
        return diagnostic
    end
    local function Execute(id,fn)
        if type(S.ActionRunner)=="table" and type(S.ActionRunner.Run)=="function" then
            return S.ActionRunner:Run({id="diagnostics."..id,execute=fn,notify=false,errorTitle="诊断操作失败"})
        end
        local ok,a,b=pcall(fn)
        if not ok then status:SetText("诊断操作异常："..tostring(a));return false,tostring(a) end
        return a,b
    end
    function root:Refresh(result)
        -- 显示/刷新结果不回填正文、不自动读盘，不破坏用户选区和本次打印快照。
        local diagnostic=S.DiagnosticsManager
        local check=type(result)=="table" and result or (type(diagnostic)=="table" and diagnostic.lastSelfCheck)
        if type(check)~="table" then card:SetData({value="尚未运行",detail="点击运行自检，或直接打印报告。"})
        elseif check.status=="ERROR" then card:SetData({value="自检执行异常",detail="仍可打印其余证据；执行异常不等于检查通过。"})
        else card:SetData({value=(tonumber(check.blockers)or 0)>0 and "需要处理" or ((tonumber(check.warnings)or 0)>0 and "存在警告" or "检查通过"),
            detail="阻断 "..tostring(check.blockers or 0).." · 警告 "..tostring(check.warnings or 0).." · 检查项 "..tostring(#(check.checks or {}))}) end
        return true
    end
    -- 维护：一个Native编辑框承载多份独立页文本。快照/边界在首次打印确定，上一页/下一页
    -- 只读这份快照，绝不能重跑Gate、读取Store或变更报告ID。失败不推进页码、不重分段。
    local function Navigation()
        local session,index=root.selfCheckDelivery,root.selfCheckPart or 0
        local count=session and session.parts or 0
        previousButton:SetEnabled(index>1)
        nextButton:SetEnabled(index>0 and index<count)
        pageLabel:SetText(index..' / '..count)
    end
    local function DescribePage(view)
        if view.state=='failed' then
            status:SetText('报告框未交付 ['..tostring(view.code)..'] '..tostring(view.error or '')..'；本次快照未更换，请重试当前操作。')
        else
            local meta=root.selfCheckMeta
            status:SetText('报告 #'..tostring(meta.id)..' · 原文 '..#root.selfCheckText..' 字节 · 第 '..view.index..'/'..view.parts
                ..' 页。Ctrl+A、Ctrl+C复制当前页；用上一页/下一页翻页。打印会生成新报告。'
                ..(meta.partial and ' 部分来源不可用或超过总安全上限，具体原因在正文。' or ''))
        end
        Navigation()
    end
    local function Present(text,meta,requested)
        root.selfCheckText,root.selfCheckMeta=text,meta;root:Refresh(meta.check)
        if not editorReady or not editor then return {state='failed',code='NO_EDITOR',error=editorError or 'multiline_editor_unavailable'} end
        local transport=S.ReportCopyTransport
        if type(transport)~='table' or type(transport.BuildTextPages)~='function' or type(transport.GetTextPage)~='function' then
            return {state='failed',code='PAGES_MISSING',error='请完整覆盖补丁后使用重新加载文件'}
        end
        -- 原生布局和焦点先于写入；用户翻页可重新激活输入，但后台刷新不抢选区。
        if type(root.Layout)=='function' and root.width and root.height then
            local ok,err=pcall(root.Layout,root,root.x or 0,root.y or 0,root.width,root.height)
            if not ok then return {state='failed',code='LAYOUT_FAILED',error=err} end
        end
        if geometryError then return {state='failed',code='GEOMETRY_FAILED',error=geometryError} end
        local shown,accepted=pcall(ui.EnsureVisible,ui,editor,true,host.owner)
        if not shown or accepted~=true then return {state='failed',code='SHOW_FAILED'} end
        local focused=false
        if type(ui.ActivateInputWidget)=='function' then local ok,value=pcall(ui.ActivateInputWidget,ui,editor,host.owner,'diagnostic_page_copy');focused=ok and value==true end
        local session=root.selfCheckDelivery
        local locked=(root.selfCheckPart or 0)>0
        local cap=session and session.capacity or 3500
        if not session and type(editor.MaxTextLength)=='function' then
            local ok,n=pcall(editor.MaxTextLength,editor);n=ok and tonumber(n) or nil
            if n and n==n and n>0 and n<math.huge then cap=math.min(cap,math.floor(n)) end
        end
        local index=requested or 1
        local trace
        for attempt=1,8 do
            if not session then
                local err;session,err=transport:BuildTextPages(text,cap,meta.id)
                if not session then return {state='failed',code='TEXT_CAPACITY',error=err} end
            end
            local payload,err=transport:GetTextPage(session,index)
            if not payload then return {state='failed',code='PAGE_RANGE',error=err} end
            local wrote,result=WriteReportText(payload,"present_page") -- 维护：只在用户打印/翻页时更换正文。
            if wrote and result~=false and type(editor.SetCursorOffset)=='function' then pcall(editor.SetCursorOffset,editor,0) end
            local read,actual=pcall(editor.GetText,editor)
            -- Wire无字面CR/LF，允许控件插入排版换行；原字符串换行已显式转义。
            local compare=read and type(actual)=='string' and actual:gsub('[\r\n]','') or actual
            local exact;exact,trace=transport:VerifyEditorReadback({kind='plain',wire='error_pages1',capacity=cap},payload,compare)
            trace.writeOk,trace.writeRejected,trace.readOk,trace.attempts=wrote,result==false,read,attempt
            if wrote and result~=false and read and exact then
                root.selfCheckDelivery,root.selfCheckPart=session,index
                return {state=session.parts==1 and 'plain' or 'part',code='OK',index=index,parts=session.parts,
                    bytes=#payload,focused=focused,readback=trace,wire='error_pages1'}
            end
            -- 尚未展示首段时才能缩小容量；之后保持边界，避免用户已复制的页失去意义。
            if locked or cap<=512 or attempt==8 then break end
            cap=math.max(512,math.floor(cap/2));session=nil
        end
        WriteReportText("","delivery_failed") -- 维护：失败交付显式清空，不能留着截断页冒充成功。
        return {state='failed',code='TEXT_READBACK',readback=trace,error=transport:FormatReadback(trace)}
    end
    runButton.onClick=function()
        return Execute('run_self_check',function()
            local diagnostic,err=Backend('RunSelfCheck');if not diagnostic then status:SetText(err);return false,err end
            ClearReport();Navigation()
            if editor and type(ui.DeactivateInputWidget)=='function' then pcall(ui.DeactivateInputWidget,ui,editor,host.owner,'diagnostic_new_check') end
            root:Refresh(diagnostic:RunSelfCheck());status:SetText('自检已完成；复现期间记录的错误仍保留。优先打印故障报告，只有维护者要求时再用完整报告。')
            return true
        end)
    end
    -- 中文维护注释（2026-09-18，.18.237 故障报告 Authority 回归修复）：
    -- 原因：诊断页“打印故障报告”曾误接历史兼容 PrintFocusedSelfCheckReport；Focused 会在 Presentation
    -- 分页之前先把证据压到 3500 bytes，导致真实 RU 报告出现 PAGE=1/1 但正文已有 <cut>/<text_omitted>，
    -- 丢失恰好用于判断 Store 恢复候选的尾部证据。Authority/数据流：Diagnostics 的 BuildPaged 仍是
    -- 本次加载故障快照 Authority，Persistence/Store 只提供只读取证；Presentation 只持有固定 text/meta
    -- 并按 Native 编辑框回读容量分页，上一页/下一页不得重新 RunSelfCheck/LoadData。兼容边界：
    -- PrintFocusedSelfCheckReport API 保留给旧工具/专项测试，但不再作为用户默认按钮；不改变 Store schema、
    -- fingerprint/Fence、恢复候选或写盘行为。风险：完整故障证据可能产生更多页，这是为了不丢证据的预期结果；
    -- 页数增加不能通过重新引入预裁剪来“优化”。
    printButton.onClick=function()
        return Execute('print_self_check',function()
            local diagnostic,err=Backend('PrintPagedSelfCheckReport');if not diagnostic then status:SetText(err);return false,err end
            ClearReport();Navigation()
            local ok,text,meta=diagnostic:PrintPagedSelfCheckReport(Present)
            if ok~=true or type(text)~='string' or type(meta)~='table' then status:SetText('故障报告生成失败：'..tostring(text));return false,tostring(text) end
            DescribePage(meta.presentation)
            return meta.delivered==true or meta.partReady==true
        end)
    end
    fullReportButton.onClick=function()
        return Execute('print_full_self_check',function()
            local diagnostic,err=Backend('PrintPagedSelfCheckReport');if not diagnostic then status:SetText(err);return false,err end
            ClearReport();Navigation()
            local ok,text,meta=diagnostic:PrintPagedSelfCheckReport(Present)
            if ok~=true or type(text)~='string' or type(meta)~='table' then status:SetText('完整报告生成失败：'..tostring(text));return false,tostring(text) end
            DescribePage(meta.presentation)
            return meta.delivered==true or meta.partReady==true
        end)
    end
    local function MovePage(delta)
        return Execute('report_page',function()
            local session=root.selfCheckDelivery;local index=(root.selfCheckPart or 0)+delta
            if not session or index<1 or index>session.parts then return false,'report_page_boundary' end
            local view=Present(root.selfCheckText,root.selfCheckMeta,index)
            DescribePage(view)
            return view.state~='failed',view.error
        end)
    end
    previousButton.onClick=function()return MovePage(-1)end
    nextButton.onClick=function()return MovePage(1)end
    Navigation()
    function root:OnActivated()
        -- 维护：重开可重新验证物理布局；在新复制选区建立前执行，不在等待Ctrl+C时回填。
        geometryWidth,geometryHeight,geometryParent=nil,nil,nil
        if editor and type(editor.Show)=="function" then pcall(editor.Show,editor,true) end
        return self:Refresh()
    end
    function root:OnDeactivated()
        ClearReport();Navigation()
        if editor and type(ui.DeactivateInputWidget)=="function" then pcall(ui.DeactivateInputWidget,ui,editor,host.owner,"diagnostic_page_hidden") end
        if editor and type(editor.Show)=="function" then pcall(editor.Show,editor,false) end
        status:SetText("报告文本已随页面关闭释放；错误历史保留，打印可生成新报告。")
        return true
    end
    if not editorReady then status:SetText("报告框不可用："..tostring(editorError or "multiline_editor_unavailable").."。打印将如实返回交付失败，不会声称正文已显示。") end
    root:Refresh()
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

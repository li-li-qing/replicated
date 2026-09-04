------------------------------------------------------------------------
-- Replicated Suite V3 - Buff Display Page (UI_IMPLEMENTING / workspace v2)
--
-- Three authoritative surfaces only:
--   1) 追踪管理  : one virtual TableView for player + target facts.
--   2) HUD 布局  : Element Tree + LayoutEditorWorkspace v2 + LayoutEditSession.
--                  Working state is page-local and NEVER registered as the
--                  Persistence getter. Preview/Undo/Redo/Reset/Revert are
--                  non-durable; Apply is the only durable layout write.
--   3) 导入导出  : tracked-id quick import + full Store export/import.
--
-- Presentation consumes only BuffDisplay projection/commands.  The page loads
-- the Store before constructing editable controls, so a disabled Feature can
-- never edit defaults over an unread saved payload.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI, D = S.RSUI, S.UIV3Design
local PageHost = S.UIV3 and S.UIV3.PageHost or nil
local WidgetHost = S.UIV3 and S.UIV3.WidgetHost or nil
local Feature = S.Features and S.Features.BuffDisplay or nil
if type(RSUI) ~= "table" or type(D) ~= "table" or type(PageHost) ~= "table" or type(WidgetHost) ~= "table" or type(Feature) ~= "table" then return end

local ROUTE = "combat.buff_display"
local TAB_KEYS = { "track", "layout", "transfer" }
local EDITOR_CANVAS = { x = 0, y = 0, width = 640, height = 320 }
local COMPONENT_META = {
    buffs     = { title = "Buff 图标",     desc = "血条上方追踪 Buff" },
    debuffs   = { title = "Debuff 图标",   desc = "血条下方追踪 Debuff" },
    distance  = { title = "距离",           desc = "顶部信息行中的距离" },
    class     = { title = "职业",           desc = "顶部信息行中的职业" },
    gearScore = { title = "装分",           desc = "顶部信息行中的装备评分" },
    mainHand  = { title = "主手",           desc = "左侧装备区主手" },
    offHand   = { title = "副手",           desc = "左侧装备区副手（靠近血条）" },
    ranged    = { title = "远程",           desc = "左侧装备区远程武器" },
    wings     = { title = "背部",           desc = "右侧背部 / 滑翔翼" },
    castBar   = { title = "读条",           desc = "血条下方施法条" },
}

local function Copy(value)
    if type(S.Utils) == "table" and type(S.Utils.DeepCopy) == "function" then return S.Utils.DeepCopy(value) end
    if type(value) ~= "table" then return value end
    local out = {}
    for key, child in pairs(value) do out[key] = Copy(child) end
    return out
end

local function Clamp(value, minValue, maxValue, fallback)
    value = tonumber(value)
    if value == nil then value = tonumber(fallback) or 0 end
    if value < minValue then value = minValue end
    if value > maxValue then value = maxValue end
    return value
end

local function Round(value) return math.floor((tonumber(value) or 0) + 0.5) end

local function MatchRow(row, query)
    query = tostring(query or ""):lower()
    if query == "" then return true end
    return string.find(tostring(row.name or ""):lower(), query, 1, true) ~= nil
        or string.find(tostring(row.id or ""), query, 1, true) ~= nil
        or string.find(tostring(row.effectTypeText or ""):lower(), query, 1, true) ~= nil
        or string.find(tostring(row.scopeText or ""):lower(), query, 1, true) ~= nil
end

local function ReadNativeText(widget)
    if widget ~= nil and type(widget.GetText) == "function" then
        local ok, text = pcall(widget.GetText, widget)
        if ok and type(text) == "string" then return text end
    end
    return ""
end

local function WriteNativeText(widget, text)
    if widget ~= nil and type(widget.SetText) == "function" then pcall(widget.SetText, widget, tostring(text or "")) end
end

local function BuildPage(parent, route)
    -- Editable pages must load their Store before controls are created.  This is
    -- deliberately earlier than Feature enable/consumer acquisition.
    if type(Feature.EnsureStoreLoaded) == "function" then
        local loaded, loadErr = Feature:EnsureStoreLoaded()
        if loaded ~= true then return nil, "状态显示配置读取失败：" .. tostring(loadErr or "未知错误") end
    end

    local root, rootErr = D:PageRoot(parent, "v3_page_buff_display")
    if root == nil then return nil, "状态显示页面根组件创建失败：" .. tostring(rootErr or "未知错误") end
    root.activeTab, root.filterText, root.quickText, root.importCategory = "track", "", "", "auto"
    root.layoutWorking = Copy(Feature.Commands:GetLayoutSettingsSnapshot())
    root.selectedLayoutKey = "buffs"

    D:PageHeader(root, "v3_buff_display_header", "状态显示", "统一管理状态追踪与头顶 HUD；HUD 布局只有点击“应用”才会写入存档。", "刷新", function()
        return Feature.Commands:Refresh("page_manual")
    end)

    local actionRow = RSUI:HorizontalBox({ id = "v3_buff_display_actions", parent = root, gap = 6, slot = { size = "fixed", height = 30, hAlign = "fill" } })
    local featureButton = RSUI:Button({ id = "v3_buff_display_feature_toggle", parent = actionRow, text = "启用功能", compact = true, slot = { size = "fixed", width = 96 } })
    local widgetButton = RSUI:Button({ id = "v3_buff_display_widget_toggle", parent = actionRow, text = "打开悬浮窗", compact = true, slot = { size = "fixed", width = 116 } })
    local persistHint = RSUI:Text({ id = "v3_buff_display_persist_hint", parent = actionRow, text = "配置已读取", fontSize = 9, tone = "muted", overflow = "ellipsis", slot = { size = "fill", fill = 1, hAlign = "right" } })

    local function ApplySetting(key, value)
        local ok, err = Feature.Commands:SetSetting(key, value)
        if ok == true then root:Refresh() end
        return ok, err
    end

    local switcher
    local transferEdit = nil
    local layoutWorkspace = nil
    local selectedControls = {}
    local globalLayoutControls = {}

    local tabSelector, tabSelectorErr = RSUI:SegmentedSelector({
        id = "v3_buff_display_tabs", parent = root, maxItems = 3, gap = 2, height = 26, fontSize = 10,
        items = {
            { value = "track", text = "追踪管理", width = 104 },
            { value = "layout", text = "HUD 布局", width = 104 },
            { value = "transfer", text = "导入导出", width = 104 },
        },
        get = function() return root.activeTab or "track" end,
        set = function(value)
            root.activeTab = tostring(value or "track")
            return type(root.SwitchTab) == "function" and root:SwitchTab(root.activeTab) or true
        end,
        slot = { size = "fixed", height = 30, hAlign = "fill" },
    })
    if tabSelector == nil then error("状态显示页签选择器创建失败：" .. tostring(tabSelectorErr or "unknown")) end
    switcher = RSUI:WidgetSwitcher({ id = "v3_buff_display_tab_switcher", parent = root, activeIndex = 1, measureMode = "active", slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" } })

    ------------------------------------------------------------------
    -- Tab 1: 追踪管理 - one virtual table / one interaction contract.
    ------------------------------------------------------------------
    local tabTrack = RSUI:VerticalBox({ id = "v3_buff_display_tab_track", parent = switcher, gap = 6, slot = { hAlign = "fill", vAlign = "fill" } })
    local filterRow = RSUI:HorizontalBox({ id = "v3_buff_display_track_filters", parent = tabTrack, gap = 6, slot = { size = "fixed", height = 28, hAlign = "fill" } })
    local buffButton = RSUI:Button({ id = "v3_buff_display_filter_buff", parent = filterRow, text = "Buff：开", compact = true, slot = { size = "fixed", width = 76 } })
    local debuffButton = RSUI:Button({ id = "v3_buff_display_filter_debuff", parent = filterRow, text = "Debuff：开", compact = true, slot = { size = "fixed", width = 86 } })
    local hiddenButton = RSUI:Button({ id = "v3_buff_display_filter_hidden", parent = filterRow, text = "只看隐藏：关", compact = true, slot = { size = "fixed", width = 92 } })
    local searchInput = RSUI:TextInput({
        id = "v3_buff_display_search", parent = filterRow, value = "", maxLength = 48, buildOptional = true,
        allowEmpty = true, submitOnLostFocus = false,
        get = function() return root.filterText or "" end,
        set = function(v) root.filterText = tostring(v or ""); return true end,
        onSubmit = function(value) root.filterText = tostring(value or ""); return root:Refresh() end,
        slot = { size = "fill", fill = 1, minWidth = 90 },
    })
    if searchInput == nil then searchInput = RSUI:Text({ id = "v3_buff_display_search_unavailable", parent = filterRow, text = "搜索框不可用", fontSize = 9, tone = "warn", slot = { size = "fill", fill = 1 } }) end
    local searchClear = RSUI:Button({ id = "v3_buff_display_search_clear", parent = filterRow, text = "清空筛选", compact = true, slot = { size = "fixed", width = 72 } })

    local trackAction = RSUI:HorizontalBox({ id = "v3_buff_display_track_actions", parent = tabTrack, gap = 6, slot = { size = "fixed", height = 28, hAlign = "fill" } })
    local selectedText = RSUI:Text({ id = "v3_buff_display_selected", parent = trackAction, text = "点击状态行可追踪 / 取消追踪", fontSize = 9, tone = "muted", overflow = "ellipsis", slot = { size = "fill", fill = 1, minWidth = 150 } })
    local freezeButton = RSUI:Button({ id = "v3_buff_display_track_freeze", parent = trackAction, text = "冻结列表：关", compact = true, slot = { size = "fixed", width = 96 } })
    local clearTrackButton = RSUI:Button({ id = "v3_buff_display_track_clear", parent = trackAction, text = "清空追踪", compact = true, slot = { size = "fixed", width = 78 } })
    local probeButton = RSUI:Button({ id = "v3_buff_display_track_probe", parent = trackAction, text = "字段诊断", compact = true, slot = { size = "fixed", width = 78 } })

    local function ToggleRowTracked(item)
        if type(item) ~= "table" or item.id == nil then return true end
        local target = item.tracked ~= true
        local category = item.category == "debuff" and "debuff" or "buff"
        local ok, err = Feature.Commands:SetTrackedId(tonumber(item.id), category, target)
        selectedText:SetText(ok == true
            and ((target and "已追踪：" or "已取消追踪：") .. tostring(item.name or item.id) .. " · ID " .. tostring(item.id))
            or ("追踪失败：" .. tostring(item.name or item.id) .. " · " .. tostring(err or "未知错误")))
        if ok == true then root:Refresh() end
        return ok, err
    end

    local trackingPanel = RSUI:Border({ id = "v3_buff_display_tracking_panel", parent = tabTrack, padding = 5, variant = "card", slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" } })
    local trackingStack = RSUI:VerticalBox({ id = "v3_buff_display_tracking_stack", parent = trackingPanel, gap = 3, slot = { hAlign = "fill", vAlign = "fill" } })
    local trackingCaption = RSUI:Text({ id = "v3_buff_display_tracking_caption", parent = trackingStack, text = "当前状态", fontSize = 10, tone = "strong", slot = { size = "fixed", height = 20 } })
    local trackingTable = RSUI:TableView({
        id = "v3_buff_display_tracking_table", parent = trackingStack, items = {}, rowHeight = 25, headerHeight = 23, desiredRows = 12,
        overscan = 2, scrollbar = true, selectable = false, columnResize = true, headerInteractive = false,
        onItemActivated = ToggleRowTracked,
        columns = {
            { id = "scope", title = "来源", field = "scopeText", size = "fixed", width = 48, minWidth = 44, sortable = false },
            { id = "id", title = "ID", field = "id", size = "fixed", width = 52, minWidth = 44, sortable = false },
            { id = "icon", title = "", field = "iconPath", cellType = "icon", iconSize = 18, fallbackIcon = "ui/icon/icon_unknown_item.dds", size = "fixed", width = 25, minWidth = 24, sortable = false, resizable = false },
            { id = "name", title = "状态", field = "name", size = "fill", minWidth = 110, fill = 1, getTone = function(item)
                if type(item) ~= "table" then return "default" end
                if item.effectType == "debuff" then return "red" end
                if item.detectionSource == "hidden" or item.frozen == true then return "muted" end
                return "default"
            end },
            { id = "type", title = "类型", field = "effectTypeText", size = "fixed", width = 54, minWidth = 48, sortable = false },
            { id = "stack", title = "层", field = "stack", size = "fixed", width = 34, minWidth = 30, sortable = false },
            { id = "time", title = "剩余", field = "timeText", size = "fixed", width = 52, minWidth = 44, sortable = false },
            { id = "tracked", title = "追踪", field = "trackedText", size = "fixed", width = 56, minWidth = 50, sortable = false, getTone = function(item) return item and item.tracked == true and "green" or "muted" end },
        },
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })

    ------------------------------------------------------------------
    -- Tab 2: HUD layout - isolated Working + reusable Workspace.
    ------------------------------------------------------------------
    local tabLayout = RSUI:VerticalBox({ id = "v3_buff_display_tab_layout", parent = switcher, gap = 5, slot = { hAlign = "fill", vAlign = "fill" } })
    local layoutToggleRow = RSUI:HorizontalBox({ id = "v3_buff_display_layout_global_toggles", parent = tabLayout, gap = 5, slot = { size = "fixed", height = 28, hAlign = "fill" } })

    local function Working() return type(root.layoutWorking) == "table" and root.layoutWorking or {} end
    local function WorkingComponent(key)
        local components = type(Working().components) == "table" and Working().components or {}
        return type(components[key]) == "table" and components[key] or nil
    end
    local function NotifyWorking(source, refreshSource)
        if layoutWorkspace ~= nil then
            if refreshSource == true then return layoutWorkspace:RefreshFromSource(source or "working") end
            local session = layoutWorkspace:GetSessionModel()
            if session ~= nil and type(session.RefreshWorking) == "function" then return session:RefreshWorking(source or "working") end
        end
        return true
    end
    local function SetWorkingValue(key, value, source)
        Working()[key] = value
        NotifyWorking(source or ("layout_" .. tostring(key)), true)
        if type(root.RefreshLayoutControls) == "function" then root:RefreshLayoutControls() end
        return true
    end

    local globalToggleSpecs = {
        { key = "headEnabled", on = "HUD：开", off = "HUD：关", width = 82 },
        { key = "headShowAll", on = "全部：开", off = "全部：关", width = 82 },
        { key = "headPlayer", on = "自己：开", off = "自己：关", width = 82 },
        { key = "headTarget", on = "目标：开", off = "目标：关", width = 82 },
        { key = "headShowStacks", on = "层数：开", off = "层数：关", width = 82 },
        { key = "headShowTime", on = "时间：开", off = "时间：关", width = 82 },
    }
    for _, spec in ipairs(globalToggleSpecs) do
        local toggle = RSUI:Toggle({
            id = "v3_buff_display_layout_global_" .. spec.key, parent = layoutToggleRow, width = spec.width, height = 24,
            onText = spec.on, offText = spec.off,
            get = function() return Working()[spec.key] ~= false end,
            set = function(v) return SetWorkingValue(spec.key, v == true, "layout_global_" .. spec.key) end,
            slot = { size = "fixed", width = spec.width },
        })
        if toggle ~= nil then globalLayoutControls[#globalLayoutControls + 1] = toggle end
    end

    local globalGrid = RSUI:UniformGrid({ id = "v3_buff_display_layout_global_grid", parent = tabLayout, minCellWidth = 220, minCellHeight = 30, maxColumns = 3, gap = 4, slot = { size = "auto", hAlign = "fill" } })
    local refreshField = D:CompactNumericSetting(globalGrid, {
        id = "v3_buff_display_layout_refresh", label = "位置刷新", min = 25, max = 2000, step = 25, integer = true, unit = "ms", slider = true,
        get = function() return tonumber(Working().headRefreshMs) or 100 end,
        set = function(v) return SetWorkingValue("headRefreshMs", Round(v), "layout_refresh_ms") end,
        slot = { size = "fill", fill = 1 },
    })
    local scaleField = D:CompactNumericSetting(globalGrid, {
        id = "v3_buff_display_layout_scale", label = "全局缩放", min = 0.5, max = 2.0, step = 0.05, integer = false, slider = true,
        get = function() return tonumber(Working().plateScale) or 1 end,
        set = function(v) return SetWorkingValue("plateScale", Clamp(v, 0.5, 2, 1), "layout_scale") end,
        slot = { size = "fill", fill = 1 },
    })
    if refreshField then globalLayoutControls[#globalLayoutControls + 1] = refreshField end
    if scaleField then globalLayoutControls[#globalLayoutControls + 1] = scaleField end

    local layoutBody = RSUI:HorizontalBox({ id = "v3_buff_display_layout_body", parent = tabLayout, gap = 6, slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" } })
    local treePanel = RSUI:Border({ id = "v3_buff_display_layout_tree_panel", parent = layoutBody, padding = 5, variant = "card", slot = { size = "fixed", width = 176, minWidth = 160, hAlign = "fill", vAlign = "fill" } })
    local treeStack = RSUI:VerticalBox({ id = "v3_buff_display_layout_tree_stack", parent = treePanel, gap = 3, slot = { hAlign = "fill", vAlign = "fill" } })
    RSUI:Text({ id = "v3_buff_display_layout_tree_title", parent = treeStack, text = "元素树", fontSize = 10, tone = "strong", slot = { size = "fixed", height = 20 } })

    if type(RSUI.CreateSelectionModel) ~= "function" or type(RSUI.TreeView) ~= "function" then
        return nil, "状态显示 HUD 布局依赖未就绪：SelectionModel/TreeView"
    end
    local layoutSelection = RSUI:CreateSelectionModel({ id = "v3_buff_display_layout_selection", mode = "single", selectedKeys = { "buffs" } })
    local treeNodes = {
        { key = "plate", text = "血条基准" },
        { key = "buffs", text = "Buff 图标" },
        { key = "debuffs", text = "Debuff 图标" },
        { key = "info", text = "顶部信息", children = {
            { key = "class", text = "职业" }, { key = "gearScore", text = "装分" }, { key = "distance", text = "距离" },
        } },
        { key = "leftGroup", text = "左侧装备", children = {
            { key = "offHand", text = "副手" }, { key = "mainHand", text = "主手" }, { key = "ranged", text = "远程" },
        } },
        { key = "rightGroup", text = "右侧装备", children = { { key = "wings", text = "背部" } } },
        { key = "castBar", text = "读条" },
    }
    local layoutTree = RSUI:TreeView({
        id = "v3_buff_display_layout_tree", parent = treeStack, nodes = treeNodes, selectionModel = layoutSelection,
        defaultExpandedDepth = 2, desiredRows = 13, rowHeight = 23, maxNodes = 32,
        onSelectionChanged = function(key)
            root.selectedLayoutKey = tostring(key or "")
            if type(root.RefreshLayoutControls) == "function" then root:RefreshLayoutControls() end
        end,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })
    if layoutTree == nil then return nil, "状态显示 Element Tree 创建失败" end

    local function ComponentSize(key)
        local component = WorkingComponent(key) or {}
        if key == "buffs" or key == "debuffs" then
            local size = Clamp(component.size, 8, 64, 29)
            local perRow = Clamp(component.maxPerRow, 1, 16, 8)
            local rows = Clamp(component.maxRows, 1, 4, 2)
            local spacing = Clamp(component.spacing, 0, 24, 2)
            return size * perRow + spacing * math.max(0, perRow - 1), size * rows + spacing * math.max(0, rows - 1)
        elseif key == "castBar" then
            return Clamp(component.width, 20, 480, 120), math.max(10, Clamp(component.size, 4, 64, 7) + 6)
        elseif key == "class" or key == "gearScore" or key == "distance" then
            local info = type(Working().info) == "table" and Working().info or {}
            local font = Clamp(info.fontSize, 8, 24, 10)
            return key == "gearScore" and 92 or 70, font + 10
        end
        local size = Clamp(component.size, 8, 64, 26)
        return size, size
    end

    local RectForKey
    RectForKey = function(key)
        key = tostring(key or "")
        local w = Working()
        local plate = type(w.plate) == "table" and w.plate or {}
        local info = type(w.info) == "table" and w.info or {}
        local px = Round(plate.x or 0)
        local py = Round(plate.y or 0)
        if key == "plate" then return { x = 245 + px, y = 150 + py, width = Clamp(plate.width, 80, 320, 150), height = Clamp(plate.height, 8, 40, 20) } end
        if key == "info" then return { x = 230 + Round(info.x or 0), y = 86 + Round(info.y or 0), width = 180, height = Clamp(info.fontSize, 8, 24, 10) + 10 } end
        if key == "leftGroup" then
            local a, b, c = RectForKey("offHand"), RectForKey("mainHand"), RectForKey("ranged")
            local minX = math.min(a.x, b.x, c.x); local minY = math.min(a.y, b.y, c.y)
            local maxX = math.max(a.x + a.width, b.x + b.width, c.x + c.width); local maxY = math.max(a.y + a.height, b.y + b.height, c.y + c.height)
            return { x = minX, y = minY, width = maxX - minX, height = maxY - minY }
        end
        if key == "rightGroup" then return RectForKey("wings") end

        local component = WorkingComponent(key) or {}
        local width, height = ComponentSize(key)
        local x, y
        if key == "buffs" then x, y = 320 - width / 2, 80
        elseif key == "debuffs" then x, y = 320 - width / 2, 184
        elseif key == "class" then x, y = 238 + Round(info.x or 0), 86 + Round(info.y or 0)
        elseif key == "gearScore" then x, y = 306 + Round(info.x or 0), 86 + Round(info.y or 0)
        elseif key == "distance" then x, y = 402 + Round(info.x or 0), 86 + Round(info.y or 0)
        elseif key == "offHand" then x, y = 209, 147
        elseif key == "mainHand" then x, y = 176, 147
        elseif key == "ranged" then x, y = 143, 147
        elseif key == "wings" then x, y = 405, 147
        elseif key == "castBar" then x, y = 320 - width / 2, 226
        else x, y = 300, 150 end
        if key ~= "class" and key ~= "gearScore" and key ~= "distance" then
            x = x + Round(component.x or 0); y = y + Round(component.y or 0)
        end
        return { x = x, y = y, width = width, height = height }
    end

    local function ApplyRect(key, rect)
        key, rect = tostring(key or ""), type(rect) == "table" and rect or {}
        local old = RectForKey(key)
        if old == nil then return false, "未知 HUD 元素：" .. key end
        local dx, dy = Round((tonumber(rect.x) or old.x) - old.x), Round((tonumber(rect.y) or old.y) - old.y)
        local w = Working()
        local function ShiftComponent(componentKey)
            local component = WorkingComponent(componentKey)
            if component == nil then return end
            component.x = Round(Clamp((component.x or 0) + dx, -400, 400, 0))
            component.y = Round(Clamp((component.y or 0) + dy, -400, 400, 0))
        end
        if key == "plate" then
            w.plate = type(w.plate) == "table" and w.plate or {}
            w.plate.x = Round(Clamp((w.plate.x or 0) + dx, -200, 200, 0))
            w.plate.y = Round(Clamp((w.plate.y or 0) + dy, -500, 500, 0))
            w.plate.width = Round(Clamp(rect.width, 80, 320, old.width))
            w.plate.height = Round(Clamp(rect.height, 8, 40, old.height))
        elseif key == "info" or key == "class" or key == "gearScore" or key == "distance" then
            w.info = type(w.info) == "table" and w.info or {}
            w.info.x = Round(Clamp((w.info.x or 0) + dx, -200, 200, 0))
            w.info.y = Round(Clamp((w.info.y or 0) + dy, -80, 80, 0))
        elseif key == "leftGroup" then
            ShiftComponent("offHand"); ShiftComponent("mainHand"); ShiftComponent("ranged")
        elseif key == "rightGroup" then ShiftComponent("wings")
        elseif key == "castBar" then
            ShiftComponent(key)
            local component = WorkingComponent(key)
            component.width = Round(Clamp(rect.width, 20, 480, old.width))
            component.size = Round(Clamp((tonumber(rect.height) or old.height) - 6, 4, 64, component.size or 7))
        else ShiftComponent(key) end
        return true
    end

    local function ApplyItems(items)
        for _, item in ipairs(type(items) == "table" and items or {}) do
            local ok, err = ApplyRect(item.key, item.rect)
            if ok ~= true then return false, err end
        end
        return true
    end

    local function ItemConstraints(key)
        key = tostring(key or "")
        local rect = RectForKey(key)
        if key == "plate" then return { minWidth = 80, maxWidth = 320, minHeight = 8, maxHeight = 40 } end
        if key == "castBar" then return { minWidth = 20, maxWidth = 480, minHeight = 10, maxHeight = 70 } end
        return { minWidth = rect.width, maxWidth = rect.width, minHeight = rect.height, maxHeight = rect.height }
    end

    local function ViewportPointerToEditorLocal(viewportX, viewportY, controller)
        -- LayoutEditorGesture samples viewport-logical coordinates. This page
        -- edits rectangles in the LayoutEditorOverlay's own local 640x320
        -- space, so identity conversion is invalid whenever the page/window is
        -- not at viewport origin. Resolve the live native overlay root on every
        -- gesture sample; no cached geometry survives responsive reflow/ScaleBox/UI scale.
        local selectionOverlay = type(controller) == "table" and controller.overlay or nil
        local editorOverlay = type(selectionOverlay) == "table" and selectionOverlay.parentComponent or nil
        local nativeRoot = type(editorOverlay) == "table" and editorOverlay.root or nil
        if nativeRoot == nil or type(S.Layout) ~= "table" or type(S.Layout.GetLogicalRect) ~= "function" then
            return nil, nil
        end
        local ok, originX, originY, liveWidth, liveHeight = pcall(function() return S.Layout:GetLogicalRect(nativeRoot) end)
        viewportX, viewportY = tonumber(viewportX), tonumber(viewportY)
        originX, originY = tonumber(originX), tonumber(originY)
        liveWidth, liveHeight = tonumber(liveWidth), tonumber(liveHeight)
        local editorWidth, editorHeight = tonumber(EDITOR_CANVAS.width), tonumber(EDITOR_CANVAS.height)
        if ok ~= true or viewportX == nil or viewportY == nil or originX == nil or originY == nil
            or liveWidth == nil or liveHeight == nil or liveWidth <= 0 or liveHeight <= 0
            or editorWidth == nil or editorHeight == nil or editorWidth <= 0 or editorHeight <= 0 then
            return nil, nil
        end
        return (viewportX - originX) * editorWidth / liveWidth,
            (viewportY - originY) * editorHeight / liveHeight
    end

    layoutWorkspace = RSUI:CreateLayoutEditorWorkspace({
        id = "v3_buff_display_layout_editor", parent = layoutBody, selectionModel = layoutSelection,
        canvasRect = EDITOR_CANVAS, coordinateSpace = "local", pointerToLocal = ViewportPointerToEditorLocal, maxSelected = 1,
        autoOpenInspectorOnSelection = true,
        minWidth = 4, minHeight = 4, maxWidth = 640, maxHeight = 320,
        getRect = function(key) return RectForKey(key) end,
        getParentRect = function() return EDITOR_CANVAS end,
        getItemConstraints = ItemConstraints,
        onPreview = function(items) return ApplyItems(items) end,
        onCommit = function(items) return ApplyItems(items) end,
        onCancel = function(items) ApplyItems(items); return true end,
        editSession = {
            getWorkingSnapshot = function() return Copy(root.layoutWorking) end,
            getPersistedSnapshot = function() return Copy(Feature.Commands:GetLayoutSettingsSnapshot()) end,
            getDefaultSnapshot = function() return Copy(Feature.Commands:GetDefaultLayoutSettingsSnapshot()) end,
            applyWorkingSnapshot = function(snapshot)
                root.layoutWorking = Copy(snapshot)
                if type(root.RefreshLayoutControls) == "function" then root:RefreshLayoutControls() end
                return true
            end,
            persistSnapshot = function(snapshot)
                local ok, err = Feature.Commands:PersistLayoutSettingsSnapshot(snapshot, "layout_editor_apply")
                if ok == true then root.layoutWorking = Copy(Feature.Commands:GetLayoutSettingsSnapshot()) end
                return ok, err
            end,
            canPersist = function() return Feature.Commands:CanPersistLayoutSettings() end,
            maxSnapshotNodes = 512,
        },
        onEditorCommand = function(command, accepted, detail)
            if accepted == true and command == "apply" then persistHint:SetText("HUD 布局已安全写入存档")
            elseif accepted == true then persistHint:SetText("HUD 布局为预览状态 · 点击应用才保存")
            else persistHint:SetText("HUD 布局操作失败：" .. tostring(detail or command)) end
            if type(root.RefreshLayoutControls) == "function" then root:RefreshLayoutControls() end
        end,
        onEditSessionChanged = function(reason, snapshot)
            if type(snapshot) == "table" and snapshot.dirty == true then persistHint:SetText("HUD 布局有未应用修改") end
        end,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })
    if layoutWorkspace == nil then return nil, "状态显示 LayoutEditorWorkspace v2 创建失败" end

    RSUI:Text({ id = "v3_buff_display_layout_preview_hint", parent = layoutWorkspace.previewHost,
        text = "HUD 逻辑预览 · 中央为血条基准\n拖动选中框调整位置；血条 / 读条支持缩放。", fontSize = 10, tone = "muted", overflow = "wrap", maxLines = 3,
        slot = { hAlign = "center", vAlign = "center" } })

    local selectedTitle = RSUI:Text({ id = "v3_buff_display_layout_selected_title", parent = layoutWorkspace.inspectorHost, text = "元素属性", fontSize = 10, tone = "strong", slot = { size = "auto", hAlign = "fill" } })
    local selectedEnabled = RSUI:Toggle({
        id = "v3_buff_display_layout_selected_enabled", parent = layoutWorkspace.inspectorHost, width = 112, height = 24,
        onText = "显示：开", offText = "显示：关",
        get = function()
            local key = root.selectedLayoutKey
            if key == "info" then return type(Working().info) == "table" and Working().info.enabled ~= false end
            local component = WorkingComponent(key); return component ~= nil and component.enabled ~= false
        end,
        set = function(v)
            local key = root.selectedLayoutKey
            if key == "info" then Working().info.enabled = v == true
            else local component = WorkingComponent(key); if component == nil then return false, "该元素没有显示开关" end; component.enabled = v == true end
            NotifyWorking("layout_selected_enabled", true); root:RefreshLayoutControls(); return true
        end,
        slot = { size = "fixed", width = 112 },
    })
    selectedControls[#selectedControls + 1] = selectedEnabled

    local selectedGrid = RSUI:UniformGrid({ id = "v3_buff_display_layout_selected_grid", parent = layoutWorkspace.inspectorHost, minCellWidth = 190, minCellHeight = 30, maxColumns = 1, gap = 3, slot = { size = "auto", hAlign = "fill" } })
    local function AddSelectedField(name, label, minValue, maxValue, step, integer, unit, getValue, setValue, visibleFor)
        local field = D:CompactNumericSetting(selectedGrid, {
            id = "v3_buff_display_layout_selected_" .. name, label = label, min = minValue, max = maxValue, step = step,
            integer = integer ~= false, unit = unit, slider = true, get = getValue,
            set = function(v) local ok, err = setValue(v); if ok == true then NotifyWorking("layout_selected_" .. name, true); root:RefreshLayoutControls() end; return ok, err end,
            slot = { size = "fill", fill = 1 },
        })
        if field ~= nil then
            field._layoutVisibleFor = visibleFor
            selectedControls[#selectedControls + 1] = field
        end
        return field
    end
    AddSelectedField("size", "尺寸", 4, 64, 1, true, "px",
        function() local c = WorkingComponent(root.selectedLayoutKey); return c and (c.size or 0) or 0 end,
        function(v) local c = WorkingComponent(root.selectedLayoutKey); if not c then return false, "该元素没有尺寸属性" end; c.size = Round(Clamp(v, 4, 64, c.size or 26)); return true end,
        function(key) return WorkingComponent(key) ~= nil end)
    AddSelectedField("font", "字号", 8, 32, 1, true, "px",
        function()
            if root.selectedLayoutKey == "info" then return tonumber(Working().info and Working().info.fontSize) or 10 end
            local c = WorkingComponent(root.selectedLayoutKey); return c and (c.fontSize or 10) or 10
        end,
        function(v)
            if root.selectedLayoutKey == "info" then Working().info.fontSize = Round(Clamp(v, 8, 24, 10)); return true end
            local c = WorkingComponent(root.selectedLayoutKey); if not c or c.fontSize == nil then return false, "该元素没有字号属性" end
            c.fontSize = Round(Clamp(v, 8, 32, c.fontSize)); return true
        end,
        function(key) local c = WorkingComponent(key); return key == "info" or (c and c.fontSize ~= nil) end)
    AddSelectedField("alpha", "透明度", 0.1, 1.0, 0.05, false, "",
        function() local c = WorkingComponent(root.selectedLayoutKey); return c and (c.alpha or 1) or 1 end,
        function(v) local c = WorkingComponent(root.selectedLayoutKey); if not c or c.alpha == nil then return false, "该元素没有透明度属性" end; c.alpha = Clamp(v, 0.1, 1, c.alpha); return true end,
        function(key) local c = WorkingComponent(key); return c and c.alpha ~= nil end)
    AddSelectedField("spacing", "图标间距", 0, 24, 1, true, "px",
        function() local c = WorkingComponent(root.selectedLayoutKey); return c and (c.spacing or 0) or 0 end,
        function(v) local c = WorkingComponent(root.selectedLayoutKey); if not c or c.spacing == nil then return false, "该元素没有间距属性" end; c.spacing = Round(Clamp(v, 0, 24, c.spacing)); return true end,
        function(key) return key == "buffs" or key == "debuffs" end)
    AddSelectedField("per_row", "每行数量", 1, 16, 1, true, "",
        function() local c = WorkingComponent(root.selectedLayoutKey); return c and (c.maxPerRow or 8) or 8 end,
        function(v) local c = WorkingComponent(root.selectedLayoutKey); if not c or c.maxPerRow == nil then return false, "该元素没有行容量属性" end; c.maxPerRow = Round(Clamp(v, 1, 16, c.maxPerRow)); return true end,
        function(key) return key == "buffs" or key == "debuffs" end)
    AddSelectedField("rows", "最大行数", 1, 4, 1, true, "",
        function() local c = WorkingComponent(root.selectedLayoutKey); return c and (c.maxRows or 2) or 2 end,
        function(v) local c = WorkingComponent(root.selectedLayoutKey); if not c or c.maxRows == nil then return false, "该元素没有行数属性" end; c.maxRows = Round(Clamp(v, 1, 4, c.maxRows)); return true end,
        function(key) return key == "buffs" or key == "debuffs" end)

    local castTextToggle = RSUI:Toggle({
        id = "v3_buff_display_layout_cast_text", parent = layoutWorkspace.inspectorHost, width = 118, height = 24,
        onText = "施法名：开", offText = "施法名：关",
        get = function() local c = WorkingComponent("castBar"); return c ~= nil and c.showText ~= false end,
        set = function(v) local c = WorkingComponent("castBar"); if not c then return false end; c.showText = v == true; NotifyWorking("layout_cast_text", false); return true end,
        slot = { size = "fixed", width = 118 },
    })
    castTextToggle._layoutVisibleFor = function(key) return key == "castBar" end
    selectedControls[#selectedControls + 1] = castTextToggle

    function root:RefreshLayoutControls()
        local key = tostring(self.selectedLayoutKey or "")
        local meta = COMPONENT_META[key]
        local title = meta and meta.title or ({ plate = "血条基准", info = "顶部信息", leftGroup = "左侧装备组", rightGroup = "右侧装备组" })[key] or "元素属性"
        selectedTitle:SetText(title .. (meta and (" · " .. meta.desc) or ""))
        for _, control in ipairs(globalLayoutControls) do if control ~= nil and type(control.Render) == "function" then control:Render() end end
        for _, control in ipairs(selectedControls) do
            if control ~= nil then
                local visible = true
                if type(control._layoutVisibleFor) == "function" then visible = control._layoutVisibleFor(key) == true
                elseif control == selectedEnabled then visible = (key == "info" or WorkingComponent(key) ~= nil) end
                if type(control.Show) == "function" then control:Show(visible) end
                if visible and type(control.Render) == "function" then control:Render() end
            end
        end
        return true
    end
    root:RefreshLayoutControls()
    layoutTree:SetSelectedKey("buffs")

    ------------------------------------------------------------------
    -- Tab 3: Import / Export.
    ------------------------------------------------------------------
    local tabTransfer = RSUI:VerticalBox({ id = "v3_buff_display_tab_transfer", parent = switcher, gap = 6, slot = { hAlign = "fill", vAlign = "fill" } })
    RSUI:Text({ id = "v3_buff_display_transfer_quick_title", parent = tabTransfer, text = "快速导入追踪 ID", fontSize = 11, tone = "strong", slot = { size = "fixed", height = 22 } })
    local quickRow = RSUI:HorizontalBox({ id = "v3_buff_display_transfer_quick_row", parent = tabTransfer, gap = 6, slot = { size = "fixed", height = 28, hAlign = "fill" } })
    local quickInput = RSUI:TextInput({
        id = "v3_buff_display_transfer_quick_input", parent = quickRow, value = "", maxLength = 256, buildOptional = true,
        allowEmpty = true, submitOnLostFocus = false, get = function() return root.quickText or "" end,
        set = function(v) root.quickText = tostring(v or ""); return true end,
        onSubmit = function(value) root.quickText = tostring(value or ""); return true end,
        slot = { size = "fill", fill = 1, minWidth = 90 },
    })
    if quickInput == nil then quickInput = RSUI:Text({ id = "v3_buff_display_transfer_quick_unavailable", parent = quickRow, text = "ID 输入框不可用", fontSize = 9, tone = "warn", slot = { size = "fill", fill = 1 } }) end
    local categorySelector, categorySelectorErr = RSUI:SegmentedSelector({
        id = "v3_buff_display_transfer_category", parent = quickRow, maxItems = 3, gap = 2, height = 24, fontSize = 9,
        items = { { value = "auto", text = "自动分类", width = 76 }, { value = "buff", text = "归入 Buff", width = 78 }, { value = "debuff", text = "归入 Debuff", width = 88 } },
        get = function() return root.importCategory or "auto" end,
        set = function(v) root.importCategory = tostring(v or "auto"); return true end,
        slot = { size = "auto" },
    })
    if categorySelector == nil then error("状态显示导入分类选择器创建失败：" .. tostring(categorySelectorErr or "unknown")) end
    local quickImport = RSUI:Button({ id = "v3_buff_display_transfer_quick_import", parent = quickRow, text = "合并导入", compact = true, slot = { size = "fixed", width = 78 } })
    local quickOverwrite = RSUI:Button({ id = "v3_buff_display_transfer_quick_overwrite", parent = quickRow, text = "覆盖导入", compact = true, slot = { size = "fixed", width = 78 } })
    local transferStatus = RSUI:Text({ id = "v3_buff_display_transfer_status", parent = tabTransfer, text = "当前追踪：--", fontSize = 9, tone = "muted", overflow = "wrap", maxLines = 3, slot = { size = "auto", minHeight = 32, hAlign = "fill" } })
    RSUI:Text({ id = "v3_buff_display_transfer_full_title", parent = tabTransfer, text = "完整导出 / 导入", fontSize = 11, tone = "strong", slot = { size = "fixed", height = 22 } })
    local transferEditHost = RSUI:Border({ id = "v3_buff_display_transfer_edit_host", parent = tabTransfer, padding = 0, variant = "card", slot = { size = "fixed", height = 168, hAlign = "fill" } })
    local transferEditAvailable = false
    if transferEditHost ~= nil and transferEditHost.root ~= nil then
        transferEdit = S.UI:CreateMultiEditBox(transferEditHost.root, "v3_buff_display_transfer_edit", 4, 4, 560, 158, 65535)
        if transferEdit ~= nil and transferEdit.AddAnchor ~= nil then pcall(transferEdit.AddAnchor, transferEdit, "BOTTOMRIGHT", transferEditHost.root, -4, -4) end
        transferEditAvailable = transferEdit ~= nil
    end
    local transferBtnRow = RSUI:HorizontalBox({ id = "v3_buff_display_transfer_buttons", parent = tabTransfer, gap = 6, slot = { size = "fixed", height = 28, hAlign = "fill" } })
    local exportBtn = RSUI:Button({ id = "v3_buff_display_transfer_export", parent = transferBtnRow, text = "导出到文本框", compact = true, slot = { size = "fixed", width = 110 } })
    local importTextBtn = RSUI:Button({ id = "v3_buff_display_transfer_import", parent = transferBtnRow, text = "从文本框导入（合并）", compact = true, slot = { size = "fixed", width = 156 } })
    local clearTextBtn = RSUI:Button({ id = "v3_buff_display_transfer_clear", parent = transferBtnRow, text = "清空文本框", compact = true, slot = { size = "fixed", width = 92 } })
    if transferEditAvailable ~= true then transferStatus:SetText("当前客户端不支持多行文本输入框；可使用上方快速导入。"); exportBtn:SetEnabled(false); importTextBtn:SetEnabled(false); clearTextBtn:SetEnabled(false) end

    ------------------------------------------------------------------
    -- Refresh / tab switching.
    ------------------------------------------------------------------
    function root:RefreshTransferStatus()
        local settings = Feature:GetSettingsProjection() or {}
        local tracked = type(settings.tracked) == "table" and settings.tracked or {}
        local buffCount = #(type(tracked.buff) == "table" and tracked.buff or {})
        local debuffCount = #(type(tracked.debuff) == "table" and tracked.debuff or {})
        transferStatus:SetText("当前追踪：Buff " .. tostring(buffCount) .. " · Debuff " .. tostring(debuffCount) .. "（每类上限 1024）。")
        return true
    end

    function root:Refresh()
        local settings = Feature:GetSettingsProjection() or {}
        local enabled = S.FeatureRuntime ~= nil and S.FeatureRuntime:IsEnabled("combat_buff_display") == true
        local allRows, revision, coverage = Feature:GetProjection("all", 512)
        local query, hiddenOnly = tostring(self.filterText or ""), settings.showHidden == true
        local filtered, playerCount, targetCount = {}, 0, 0
        for _, row in ipairs(allRows or {}) do
            if MatchRow(row, query) and (hiddenOnly ~= true or row.detectionSource == "hidden") then
                filtered[#filtered + 1] = row
                if row.scope == "player" then playerCount = playerCount + 1 else targetCount = targetCount + 1 end
            end
        end
        trackingTable:SetItems(filtered, "all:" .. tostring(revision or 0) .. ":" .. tostring(query) .. ":" .. tostring(hiddenOnly))
        local playerCoverage = type(coverage) == "table" and coverage.player or nil
        local targetCoverage = type(coverage) == "table" and coverage.target or nil
        local anyAvailable = enabled and ((type(playerCoverage) == "table" and playerCoverage.available == true) or (type(targetCoverage) == "table" and targetCoverage.available == true))
        trackingTable:SetViewState(not enabled and "unavailable" or (not anyAvailable and "unavailable" or (#filtered > 0 and "ready" or "empty")), {
            title = not enabled and "功能已关闭" or (not anyAvailable and "状态事实暂不可用" or "没有符合筛选的状态"),
            detail = not enabled and "启用功能后按需读取共享 Aura 事实。" or (not anyAvailable and "当前没有可读取的自己/目标状态事实。" or "调整筛选或等待状态变化。"),
        })
        trackingCaption:SetText("当前状态 · " .. tostring(#filtered) .. " · 自己 " .. tostring(playerCount) .. " · 目标 " .. tostring(targetCount))
        featureButton:SetText(enabled and "关闭功能" or "启用功能")
        widgetButton:SetEnabled(enabled)
        widgetButton:SetText(WidgetHost:IsVisible("combat.buff_display") and "关闭悬浮窗" or "打开悬浮窗")
        buffButton:SetText("Buff：" .. (settings.showBuffs ~= false and "开" or "关"))
        debuffButton:SetText("Debuff：" .. (settings.showDebuffs ~= false and "开" or "关"))
        hiddenButton:SetText("只看隐藏：" .. (settings.showHidden == true and "开" or "关"))
        freezeButton:SetText("冻结列表：" .. (settings.freezeEnabled == true and "开" or "关"))
        if self.activeTab == "layout" then self:RefreshLayoutControls() end
        if self.activeTab == "transfer" then self:RefreshTransferStatus() end
        return true
    end

    function root:SwitchTab(value)
        value = tostring(value or "track")
        local index = 1
        for i, key in ipairs(TAB_KEYS) do if key == value then index = i break end end
        switcher:SetActiveIndex(index)
        if transferEdit ~= nil and type(transferEdit.Show) == "function" then transferEdit:Show(value == "transfer") end
        if value == "layout" then
            self:RefreshLayoutControls()
            if layoutWorkspace ~= nil then
                layoutWorkspace:RefreshFromSource("tab_open")
                if layoutWorkspace:GetMode() == "drawer" then layoutWorkspace:SetDrawerOpen(true, true) end
            end
        elseif value == "transfer" then self:RefreshTransferStatus() end
        return true
    end

    ------------------------------------------------------------------
    -- Handlers.
    ------------------------------------------------------------------
    featureButton.onClick = function()
        local enabled = S.FeatureRuntime:IsEnabled("combat_buff_display") == true
        local target = not enabled
        local ok, err = S.FeatureRuntime:SetPreferredEnabled("combat_buff_display", target, "buff_display_page")
        if ok ~= true then return false, err end
        if target then
            local acquired, acquireErr = Feature:AcquireConsumer("page:buff_display")
            if acquired ~= true then S.FeatureRuntime:SetPreferredEnabled("combat_buff_display", false, "buff_display_consumer_rollback"); root:Refresh(); return false, acquireErr or "状态显示 Consumer 启动失败" end
            if S.Events ~= nil and type(S.Events.UnsubscribeInternalOwner) == "function" and type(S.Events.SubscribeInternal) == "function" then
                S.Events:UnsubscribeInternalOwner(root); S.Events:SubscribeInternal("v3.buff_display.updated", root, function() if root.activeTab == "track" then root:Refresh() end end)
            end
            Feature.Commands:Refresh("page_enable")
        elseif S.Events ~= nil and type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(root) end
        return root:Refresh()
    end
    widgetButton.onClick = function() return WidgetHost:SetVisible("combat.buff_display", not WidgetHost:IsVisible("combat.buff_display"), { source = "buff_display_page" }) end
    buffButton.onClick = function() local settings = Feature:GetSettingsProjection(); return ApplySetting("showBuffs", not (settings.showBuffs ~= false)) end
    debuffButton.onClick = function() local settings = Feature:GetSettingsProjection(); return ApplySetting("showDebuffs", not (settings.showDebuffs ~= false)) end
    hiddenButton.onClick = function() local settings = Feature:GetSettingsProjection(); return ApplySetting("showHidden", not (settings.showHidden == true)) end
    freezeButton.onClick = function() local settings = Feature:GetSettingsProjection(); return ApplySetting("freezeEnabled", not (settings.freezeEnabled == true)) end
    searchClear.onClick = function() root.filterText = ""; if searchInput ~= nil and type(searchInput.SetValue) == "function" then searchInput:SetValue("", false, "search_clear") end; return root:Refresh() end
    clearTrackButton.onClick = function() local ok, err = Feature.Commands:ClearTrackedIds(); if ok then root:Refresh() end; return ok, err end
    probeButton.onClick = function() local ok, summary = Feature.Commands:ProbeAuraFields(); selectedText:SetText(ok and ("字段诊断已输出到聊天框 · " .. tostring(summary)) or tostring(summary or "诊断失败")); return ok, summary end

    local function QuickImportText(mode)
        local text = quickInput ~= nil and type(quickInput.GetDraftValue) == "function" and tostring(quickInput:GetDraftValue() or "") or ""
        if text == "" then transferStatus:SetText("请先填写要导入的 Buff ID（逗号/换行分隔）。"); return true end
        local ok, err = Feature.Commands:ImportTrackedIds(text, root.importCategory or "auto", mode or "merge")
        if ok then root:Refresh(); transferStatus:SetText(tostring(err or "导入完成")) else transferStatus:SetText("导入失败：" .. tostring(err or "未知错误")) end
        return true
    end
    quickImport.onClick = function() return QuickImportText("merge") end
    quickOverwrite.onClick = function() return QuickImportText("overwrite") end
    exportBtn.onClick = function()
        if transferEdit == nil then transferStatus:SetText("多行文本框不可用，无法导出。"); return true end
        local data = Feature.Commands:ExportAll(); WriteNativeText(transferEdit, Feature.Commands:SerializeExport(data))
        local tracked = type(data) == "table" and type(data.tracked) == "table" and data.tracked or {}
        transferStatus:SetText("已导出 Buff " .. tostring(#(tracked.buff or {})) .. " · Debuff " .. tostring(#(tracked.debuff or {})) .. " 到文本框。")
        return true
    end
    importTextBtn.onClick = function()
        if transferEdit == nil then transferStatus:SetText("多行文本框不可用，无法导入。"); return true end
        local text = ReadNativeText(transferEdit); if text == "" then transferStatus:SetText("文本框为空。"); return true end
        local parsed = Feature.Commands:ParseImportText(text)
        if parsed == nil or type(parsed) ~= "table" then transferStatus:SetText("导入文本解析失败。"); return true end
        if type(parsed.errors) == "table" and #parsed.errors > 0 then transferStatus:SetText("解析失败 " .. tostring(#parsed.errors) .. " 处：" .. tostring(parsed.errors[1])); return true end
        local ok, err = Feature.Commands:ImportAll(parsed.data, "merge")
        if ok ~= true then transferStatus:SetText("导入失败：" .. tostring(err or "未知错误")); return true end
        root:Refresh(); transferStatus:SetText(tostring(err or "导入完成")); return true
    end
    clearTextBtn.onClick = function() WriteNativeText(transferEdit, ""); transferStatus:SetText("文本框已清空。"); return true end

    ------------------------------------------------------------------
    -- Lifecycle.  Re-activation always rebases the isolated editor from the
    -- durable Store so abandoned page-local edits cannot survive navigation.
    ------------------------------------------------------------------
    function root:OnActivated()
        local loaded, loadErr = Feature:EnsureStoreLoaded()
        if loaded ~= true then return false, loadErr or "状态显示配置读取失败" end
        self.layoutWorking = Copy(Feature.Commands:GetLayoutSettingsSnapshot())
        if layoutWorkspace ~= nil then
            local rebased, rebaseErr = layoutWorkspace:RebaseEditSession("page_activated")
            if rebased ~= true then return false, rebaseErr end
            layoutWorkspace:RefreshFromSource("page_activated")
        end
        persistHint:SetText("配置已读取 · HUD 修改仅在“应用”后保存")
        if S.FeatureRuntime:IsEnabled("combat_buff_display") == true then
            local ok, err = Feature:AcquireConsumer("page:buff_display"); if ok ~= true then return false, err end
            if S.Events ~= nil and type(S.Events.UnsubscribeInternalOwner) == "function" and type(S.Events.SubscribeInternal) == "function" then
                S.Events:UnsubscribeInternalOwner(self); S.Events:SubscribeInternal("v3.buff_display.updated", self, function()
                    -- Aura facts update the tracking table, not the isolated HUD
                    -- editor Working state.  Do not re-render the editor at Aura
                    -- cadence; shared controls still protect active drafts, and
                    -- this boundary also removes needless editor work while the
                    -- user is dragging/typing in the Layout tab.
                    if root.activeTab == "track" then root:Refresh() end
                end)
            end
            Feature.Commands:Refresh("page_activated")
        end
        return self:Refresh()
    end
    function root:OnDeactivated()
        if S.Events ~= nil and type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
        Feature:ReleaseConsumer("page:buff_display")
        -- No persistence action here. Un-applied HUD Working state is page-local
        -- and will be rebased from the durable Store on the next activation.
        return true
    end
    function root:RefreshData() return self:Refresh() end
    root.route = route
    return root
end

local ok, err = PageHost:RegisterFactory(ROUTE, BuildPage)
if ok ~= true then error(err) end

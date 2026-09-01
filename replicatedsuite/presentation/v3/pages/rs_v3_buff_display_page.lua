------------------------------------------------------------------------
-- Replicated Suite V3 - Buff Display Page (four-tab layout)
--
--  * Tab 1  状态追踪: Buff/Debuff/隐藏 filter + keyword search + row-click
--            tracked toggle on player/target projections.
--  * Tab 2  头顶显示: head scope toggles (自己/目标), 层数/时间 flags and
--            icon size / max icons / offset Y / refresh interval fields.
--  * Tab 3  布局外观: ten head components (buffs..castBar), each with an
--            enabled toggle and x/y/size/fontSize/alpha NumericControls,
--            written through Feature.Commands:SetComponentField (schema 4).
--  * Tab 4  导入导出: quick tracked-id import (merge/overwrite) plus full
--            export/import text backed by the Feature store's own
--            parse/serialize commands.
--
-- Presentation consumes only BuffDisplay projection/commands.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI, D = S.RSUI, S.UIV3Design
local PageHost = S.UIV3 and S.UIV3.PageHost or nil
local WidgetHost = S.UIV3 and S.UIV3.WidgetHost or nil
local Feature = S.Features and S.Features.BuffDisplay or nil
if type(RSUI) ~= "table" or type(D) ~= "table" or type(PageHost) ~= "table" or type(WidgetHost) ~= "table" or type(Feature) ~= "table" then return end

local ROUTE = "combat.buff_display"
local TAB_KEYS = { "track", "head", "layout", "transfer" }
local COMPONENT_META = {
    buffs     = { title = "Buff 图标",     desc = "已追踪 Buff 的图标行（按最多图标数截断）" },
    debuffs   = { title = "Debuff 图标",   desc = "已追踪 Debuff 的图标行" },
    distance  = { title = "距离",           desc = "目标距离文本（自动 m/km 换算）" },
    class     = { title = "职业",           desc = "目标职业文本" },
    gearScore = { title = "装分",           desc = "目标装备评分文本" },
    mainHand  = { title = "主手",           desc = "主手武器图标" },
    offHand   = { title = "副手",           desc = "副手武器图标" },
    ranged    = { title = "远程",           desc = "远程武器图标" },
    wings     = { title = "背部",           desc = "背部 / 滑翔翼装备图标" },
    castBar   = { title = "读条",           desc = "目标施法进度条" },
}

local function CoverageText(scope, coverage)
    coverage = type(coverage) == "table" and coverage or {}
    if coverage.available ~= true then return scope .. "：不可用" end
    local state = coverage.complete == true and coverage.reliable == true and "完整" or "待确认"
    return scope .. "：" .. state .. " · Buff " .. tostring(coverage.buffCount or 0)
        .. " · Debuff " .. tostring(coverage.debuffCount or 0) .. " · Hidden " .. tostring(coverage.hiddenCount or 0)
end

-- Keyword search over the projection rows (name / id / type text).
local function MatchRow(row, query)
    query = tostring(query or ""):lower()
    if query == "" then return true end
    local name = tostring(row.name or ""):lower()
    local idText = tostring(row.id or "")
    local typeText = tostring(row.effectTypeText or ""):lower()
    return string.find(name, query, 1, true) ~= nil
        or string.find(idText, query, 1, true) ~= nil
        or string.find(typeText, query, 1, true) ~= nil
end

local function ReadNativeText(widget)
    if widget ~= nil and type(widget.GetText) == "function" then
        local ok, text = pcall(widget.GetText, widget)
        if ok and type(text) == "string" then return text end
    end
    return ""
end

local function WriteNativeText(widget, text)
    if widget ~= nil and type(widget.SetText) == "function" then
        pcall(widget.SetText, widget, tostring(text or ""))
    end
end

local function BuildPage(parent, route)
    local root, rootErr = D:PageRoot(parent, "v3_page_buff_display")
    if root == nil then return nil, "状态显示页面根组件创建失败：" .. tostring(rootErr or "未知错误") end
    root.activeTab, root.filterText, root.quickText, root.importCategory = "track", "", "", "auto"
    D:PageHeader(root, "v3_buff_display_header", "状态显示", "追踪自己/目标的 Buff、Debuff 与隐藏状态；可把选中的 Buff 固定显示在自己或目标头顶。", "刷新", function()
        return Feature.Commands:Refresh("page_manual")
    end)

    local summary = D:InfoCard(root, { id = "v3_buff_display_summary", title = "共享事实层", value = "功能已关闭", detail = "启用后按需读取 AuraObservationV3。", slot = { size = "fixed", height = 76, hAlign = "fill" } })
    local actionRow = RSUI:HorizontalBox({ id = "v3_buff_display_actions", parent = root, gap = 6, slot = { size = "fixed", height = 30, hAlign = "fill" } })
    local featureButton = RSUI:Button({ id = "v3_buff_display_feature_toggle", parent = actionRow, text = "启用功能", compact = true, slot = { size = "fixed", width = 96 } })
    local widgetButton = RSUI:Button({ id = "v3_buff_display_widget_toggle", parent = actionRow, text = "打开悬浮窗", compact = true, slot = { size = "fixed", width = 116 } })
    local function Apply(key, value)
        local ok, err = Feature.Commands:SetSetting(key, value)
        if ok == true then root:Refresh() end
        return ok, err
    end

    -- Tab bar + content switcher. The selector is added to the root before the
    -- switcher so it renders on top; its callbacks capture the `switcher` local
    -- by reference and only run on user clicks, after the full build completes.
    local switcher
    local transferEdit = nil
    local headToggles, headFields = {}, {}
    local cardToggles, cardFields = {}, {}
    local tabSelector, tabSelectorErr = RSUI:SegmentedSelector({
        id = "v3_buff_display_tabs", parent = root, maxItems = 4, gap = 2, height = 26, fontSize = 10,
        items = {
            { value = "track", text = "状态追踪", width = 96 },
            { value = "head", text = "头顶显示", width = 96 },
            { value = "layout", text = "布局外观", width = 96 },
            { value = "transfer", text = "导入导出", width = 96 },
        },
        get = function() return root.activeTab or "track" end,
        set = function(value)
            root.activeTab = tostring(value or "track")
            if type(root.SwitchTab) == "function" then return root:SwitchTab(root.activeTab) end
            return true
        end,
        slot = { size = "fixed", height = 30, hAlign = "fill" },
    })
    if tabSelector == nil then error("状态显示页签选择器创建失败：" .. tostring(tabSelectorErr or "unknown")) end
    switcher = RSUI:WidgetSwitcher({ id = "v3_buff_display_tab_switcher", parent = root, activeIndex = 1, measureMode = "active", slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" } })

    ------------------------------------------------------------------
    -- Tab 1: 状态追踪
    ------------------------------------------------------------------
    local tabTrack = RSUI:VerticalBox({ id = "v3_buff_display_tab_track", parent = switcher, gap = 6, slot = { hAlign = "fill", vAlign = "fill" } })
    local filterRow = RSUI:HorizontalBox({ id = "v3_buff_display_tab_track_filters", parent = tabTrack, gap = 6, slot = { size = "fixed", height = 28, hAlign = "fill" } })
    local buffButton = RSUI:Button({ id = "v3_buff_display_filter_buff", parent = filterRow, text = "Buff：开", compact = true, slot = { size = "fixed", width = 76 } })
    local debuffButton = RSUI:Button({ id = "v3_buff_display_filter_debuff", parent = filterRow, text = "Debuff：开", compact = true, slot = { size = "fixed", width = 86 } })
    local hiddenButton = RSUI:Button({ id = "v3_buff_display_filter_hidden", parent = filterRow, text = "只看隐藏：关", compact = true, slot = { size = "fixed", width = 88 } })
    local searchInput, searchInputErr = RSUI:TextInput({
        id = "v3_buff_display_search", parent = filterRow, value = "", maxLength = 48, buildOptional = true,
        allowEmpty = true, submitOnLostFocus = false,
        get = function() return root.filterText or "" end,
        set = function(v) root.filterText = tostring(v or ""); return true end,
        onSubmit = function(value)
            root.filterText = tostring(value or "")
            return root:Refresh()
        end,
        slot = { size = "fill", fill = 1, minWidth = 90 },
    })
    if searchInput == nil then
        searchInput = RSUI:Text({ id = "v3_buff_display_search_unavailable", parent = filterRow, text = "搜索框不可用", fontSize = 9, tone = "warn", overflow = "ellipsis", slot = { size = "fill", fill = 1 } })
    end
    local searchClear = RSUI:Button({ id = "v3_buff_display_search_clear", parent = filterRow, text = "清空筛选", compact = true, slot = { size = "fixed", width = 72 } })

    local trackRow = RSUI:HorizontalBox({ id = "v3_buff_display_tab_track_actions", parent = tabTrack, gap = 6, slot = { size = "fixed", height = 28, hAlign = "fill" } })
    local selectedText = RSUI:Text({ id = "v3_buff_display_selected", parent = trackRow, text = "选中状态：无", fontSize = 9, tone = "muted", overflow = "ellipsis", slot = { size = "fill", fill = 1, minWidth = 120 } })
    local trackButton = RSUI:Button({ id = "v3_buff_display_track_add", parent = trackRow, text = "追踪选中", compact = true, slot = { size = "fixed", width = 78 } })
    local untrackButton = RSUI:Button({ id = "v3_buff_display_track_remove", parent = trackRow, text = "取消追踪", compact = true, slot = { size = "fixed", width = 78 } })
    local clearTrackButton = RSUI:Button({ id = "v3_buff_display_track_clear", parent = trackRow, text = "清空追踪", compact = true, slot = { size = "fixed", width = 78 } })

    -- DataView callbacks must be supplied at construction. TableView snapshots
    -- them into its internal ListView; assigning tableView.onSelectionChanged or
    -- tableView.onItemActivated afterwards leaves the native row click path nil.
    root.selectedBuffId, root.selectedBuffName, root.selectedBuffCategory = nil, nil, nil
    local function SelectFrom(tableView, index)
        if type(tableView) ~= "table" or type(tableView.GetItem) ~= "function" then return false end
        local row = tableView:GetItem(index)
        root.selectedBuffId = row and tonumber(row.id) or nil
        root.selectedBuffName = row and tostring(row.name or row.id or "") or nil
        root.selectedBuffCategory = row and (row.category == "debuff" and "debuff" or "buff") or nil
        selectedText:SetText(root.selectedBuffId and ("选中状态：" .. tostring(root.selectedBuffName) .. " · ID " .. tostring(root.selectedBuffId)) or "选中状态：无")
        return true
    end
    local function ToggleRowTracked(item, index, key, view, reason)
        if type(item) ~= "table" or item.id == nil then return true end
        local ok, err = Feature.Commands:SetTrackedId(tonumber(item.id), item.category == "debuff" and "debuff" or "buff", not (item.tracked == true))
        if ok == true then root:Refresh() end
        return ok, err
    end

    local tableRow = RSUI:HorizontalBox({ id = "v3_buff_display_tables", parent = tabTrack, gap = 7, slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" } })
    local function MakeTable(id, title)
        local panel = RSUI:Border({ id = id .. "_panel", parent = tableRow, padding = 5, variant = "card", slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" } })
        local stack = RSUI:VerticalBox({ id = id .. "_stack", parent = panel, gap = 3, slot = { hAlign = "fill", vAlign = "fill" } })
        local caption = RSUI:Text({ id = id .. "_caption", parent = stack, text = title, fontSize = 10, tone = "strong", slot = { size = "fixed", height = 20 } })
        local tableView = RSUI:TableView({
            id = id .. "_table", parent = stack, items = {}, rowHeight = 25, headerHeight = 23, desiredRows = 8,
            overscan = 1, scrollbar = true, selectable = true, selectionMode = "single", columnResize = true, headerInteractive = false,
            onSelectionChanged = function(index, previousIndex, view)
                return SelectFrom(view, index)
            end,
            onItemActivated = ToggleRowTracked,
            columns = {
                { id = "icon", title = "", field = "iconPath", cellType = "icon", iconSize = 18, fallbackIcon = "ui/icon/icon_unknown_item.dds", size = "fixed", width = 25, minWidth = 24, sortable = false, resizable = false },
                { id = "name", title = "状态", field = "name", size = "fill", minWidth = 90, fill = 1, getTone = function(item) return item and item.effectType == "debuff" and "red" or (item and item.effectType == "hidden" and "muted" or "default") end },
                { id = "type", title = "类型", field = "effectTypeText", size = "fixed", width = 54, minWidth = 48, sortable = false },
                { id = "stack", title = "层", field = "stack", size = "fixed", width = 36, minWidth = 30, sortable = false },
                { id = "time", title = "剩余", field = "timeText", size = "fixed", width = 52, minWidth = 44, sortable = false },
                { id = "tracked", title = "追踪", field = "trackedText", size = "fixed", width = 48, minWidth = 42, sortable = false, getTone = function(item) return item and item.tracked == true and "green" or "muted" end },
            },
            slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
        })
        return caption, tableView
    end
    local playerCaption, playerTable = MakeTable("v3_buff_display_player", "自己")
    local targetCaption, targetTable = MakeTable("v3_buff_display_target", "目标")
    local hint = RSUI:Text({ id = "v3_buff_display_hint", parent = tabTrack, text = "点击状态行可切换追踪；Aura 事实未知时保留待确认状态，不把缺失数据伪装成无 Buff。", fontSize = 9, tone = "muted", overflow = "ellipsis", slot = { size = "fixed", height = 20, hAlign = "fill" } })

    ------------------------------------------------------------------
    -- Tab 2: 头顶显示
    ------------------------------------------------------------------
    local tabHead = RSUI:VerticalBox({ id = "v3_buff_display_tab_head", parent = switcher, gap = 6, slot = { hAlign = "fill", vAlign = "fill" } })
    local headToggleRow = RSUI:HorizontalBox({ id = "v3_buff_display_tab_head_toggles", parent = tabHead, gap = 6, slot = { size = "fixed", height = 30, hAlign = "fill" } })
    -- 勾选即见：头顶显示开关从关→开时，若功能尚未启用则自动启用并持有页面
    -- Consumer（与 featureButton 的启用路径同源，避免用户只开开关却看不到图标的
    -- 体验断崖——参考 addon 开箱即用，本页对"启用功能"与"头顶显示"联动）。
    local function EnsureHeadFeature()
        if S.FeatureRuntime ~= nil and S.FeatureRuntime:IsEnabled("combat_buff_display") == true then return true end
        local ok, err = S.FeatureRuntime:SetPreferredEnabled("combat_buff_display", true, "head_toggle_auto_enable")
        if ok ~= true then return false, err end
        local acquired, acquireErr = Feature:AcquireConsumer("page:buff_display")
        if acquired ~= true then
            S.FeatureRuntime:SetPreferredEnabled("combat_buff_display", false, "buff_display_consumer_rollback")
            return false, acquireErr or "状态显示 Consumer 启动失败"
        end
        if S.Events ~= nil and type(S.Events.UnsubscribeInternalOwner) == "function" and type(S.Events.SubscribeInternal) == "function" then
            S.Events:UnsubscribeInternalOwner(root)
            S.Events:SubscribeInternal("v3.buff_display.updated", root, function() root:Refresh() end)
        end
        return true
    end
    local function AddHeadToggle(key, onText, offText, width)
        local toggle = RSUI:Toggle({
            id = "v3_buff_display_tab_head_" .. key, parent = headToggleRow, width = width, height = 26,
            onText = onText, offText = offText,
            get = function() return (Feature:GetSettingsProjection() or {})[key] ~= false end,
            set = function(v)
                if key == "headEnabled" and v == true then EnsureHeadFeature() end
                return Apply(key, v == true)
            end,
            slot = { size = "fixed", width = width },
        })
        if toggle ~= nil then headToggles[#headToggles + 1] = toggle end
        return toggle
    end
    AddHeadToggle("headEnabled", "头顶显示：开", "头顶显示：关", 122)
    AddHeadToggle("headShowAll", "全部显示：开", "全部显示：关", 104)
    AddHeadToggle("headPlayer", "自己：开", "自己：关", 84)
    AddHeadToggle("headTarget", "目标：开", "目标：关", 84)
    AddHeadToggle("headShowStacks", "层数：开", "层数：关", 88)
    AddHeadToggle("headShowTime", "时间：开", "时间：关", 88)

    local headGrid = RSUI:UniformGrid({ id = "v3_buff_display_head_settings", parent = tabHead, minCellWidth = 180, minCellHeight = 30, maxColumns = 4, gap = 5, slot = { size = "auto", minHeight = 30, hAlign = "fill" } })
    local function AddHeadField(spec)
        local field = D:CompactNumericSetting(headGrid, spec)
        if field ~= nil then headFields[#headFields + 1] = field end
        return field
    end
    AddHeadField({ id = "v3_buff_display_head_icon_size", label = "图标大小", min = 16, max = 40, step = 1, integer = true, unit = "px", slider = true,
        get = function() return (Feature:GetSettingsProjection() or {}).headIconSize or 24 end, set = function(v) return Feature.Commands:SetSetting("headIconSize", v) end, slot = { size = "fill", fill = 1 } })
    AddHeadField({ id = "v3_buff_display_head_max_icons", label = "最多图标", min = 1, max = 12, step = 1, integer = true, slider = true,
        get = function() return (Feature:GetSettingsProjection() or {}).headMaxIcons or 8 end, set = function(v) return Feature.Commands:SetSetting("headMaxIcons", v) end, slot = { size = "fill", fill = 1 } })
    AddHeadField({ id = "v3_buff_display_head_offset", label = "上下位置", min = -180, max = 80, step = 2, integer = true, unit = "px", slider = true,
        get = function() return (Feature:GetSettingsProjection() or {}).headOffsetY or -108 end, set = function(v) return Feature.Commands:SetSetting("headOffsetY", v) end, slot = { size = "fill", fill = 1 } })
    AddHeadField({ id = "v3_buff_display_head_refresh", label = "位置刷新", min = 50, max = 500, step = 25, integer = true, unit = "ms", slider = true,
        get = function() return (Feature:GetSettingsProjection() or {}).headRefreshMs or 100 end, set = function(v) return Feature.Commands:SetSetting("headRefreshMs", v) end, slot = { size = "fill", fill = 1 } })

    ------------------------------------------------------------------
    -- Tab 3: 布局外观（10 个头顶组件卡片）
    ------------------------------------------------------------------
    local tabLayout = RSUI:VerticalBox({ id = "v3_buff_display_tab_layout", parent = switcher, gap = 4, slot = { hAlign = "fill", vAlign = "fill" } })
    local layoutScroll = RSUI:ScrollBox({
        id = "v3_buff_display_tab_layout_scroll", parent = tabLayout,
        orientation = "vertical", gap = 6, scrollStep = 2, scrollbar = true,
        reserveScrollbar = true, scrollbarWidth = 14, scrollbarGap = 4,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })
    local function BuildComponentCard(key, meta)
        local cardId = "v3_buff_display_tab_layout_cmp_" .. key
        local card = RSUI:Border({ id = cardId, parent = layoutScroll, padding = 6, variant = "card", slot = { size = "auto", hAlign = "fill" } })
        local stack = RSUI:VerticalBox({ id = cardId .. "_stack", parent = card, gap = 3 })
        local header = RSUI:HorizontalBox({ id = cardId .. "_header", parent = stack, gap = 8, slot = { size = "fixed", height = 26, hAlign = "fill" } })
        RSUI:Text({ id = cardId .. "_title", parent = header, text = meta.title, fontSize = 11, tone = "strong", slot = { size = "auto" } })
        RSUI:Text({ id = cardId .. "_desc", parent = header, text = meta.desc, fontSize = 9, tone = "muted", overflow = "ellipsis", slot = { size = "fill", fill = 1 } })
        local enabledToggle = RSUI:Toggle({
            id = cardId .. "_enabled", parent = header, width = 84, height = 22,
            onText = "显示：开", offText = "显示：关",
            get = function()
                local components = (Feature:GetSettingsProjection() or {}).components or {}
                local component = components[key] or {}
                return component.enabled ~= false
            end,
            set = function(v) return Feature.Commands:SetComponentField(key, "enabled", v == true) end,
            slot = { size = "fixed", width = 88 },
        })
        if enabledToggle ~= nil then cardToggles[#cardToggles + 1] = enabledToggle end
        local grid = RSUI:UniformGrid({ id = cardId .. "_grid", parent = stack, minCellWidth = 240, minCellHeight = 30, maxColumns = 2, gap = 4, slot = { size = "auto", hAlign = "fill" } })
        local function AddField(fieldKey, label, min, max, step, unit, integer)
            local field = D:CompactNumericSetting(grid, {
                id = cardId .. "_" .. fieldKey, label = label, min = min, max = max, step = step, integer = integer ~= false, unit = unit, slider = true,
                get = function()
                    local components = (Feature:GetSettingsProjection() or {}).components or {}
                    local component = components[key] or {}
                    local value = component[fieldKey]
                    return value ~= nil and value or 0
                end,
                set = function(v) return Feature.Commands:SetComponentField(key, fieldKey, v) end,
                slot = { size = "fill", fill = 1, hAlign = "fill" },
            })
            if field ~= nil then cardFields[#cardFields + 1] = field end
            return field
        end
        AddField("x", "X 偏移", -400, 400, 2, "px", true)
        AddField("y", "Y 偏移", -400, 400, 2, "px", true)
        AddField("size", "尺寸", 0, 64, 1, "px", true)
        AddField("fontSize", "字号", 0, 32, 1, "px", true)
        AddField("alpha", "透明度", 0.1, 1.0, 0.05, "", false)
        return card
    end
    for _, key in ipairs({ "buffs", "debuffs", "distance", "class", "gearScore", "mainHand", "offHand", "ranged", "wings", "castBar" }) do
        local meta = COMPONENT_META[key] or { title = key, desc = "" }
        BuildComponentCard(key, meta)
    end

    ------------------------------------------------------------------
    -- Tab 4: 导入导出
    ------------------------------------------------------------------
    local tabTransfer = RSUI:VerticalBox({ id = "v3_buff_display_tab_transfer", parent = switcher, gap = 6, slot = { hAlign = "fill", vAlign = "fill" } })
    RSUI:Text({ id = "v3_buff_display_tab_transfer_quick_title", parent = tabTransfer, text = "快速导入追踪 ID", fontSize = 11, tone = "strong", slot = { size = "fixed", height = 22 } })
    local quickRow = RSUI:HorizontalBox({ id = "v3_buff_display_tab_transfer_quick_row", parent = tabTransfer, gap = 6, slot = { size = "fixed", height = 28, hAlign = "fill" } })
    local quickInput, quickInputErr = RSUI:TextInput({
        id = "v3_buff_display_tab_transfer_quick_input", parent = quickRow, value = "", maxLength = 256, buildOptional = true,
        allowEmpty = true, submitOnLostFocus = false,
        get = function() return root.quickText or "" end,
        set = function(v) root.quickText = tostring(v or ""); return true end,
        onSubmit = function(value) root.quickText = tostring(value or ""); return true end,
        slot = { size = "fill", fill = 1, minWidth = 90 },
    })
    if quickInput == nil then
        quickInput = RSUI:Text({ id = "v3_buff_display_tab_transfer_quick_input_unavailable", parent = quickRow, text = "ID 输入框不可用", fontSize = 9, tone = "warn", overflow = "ellipsis", slot = { size = "fill", fill = 1 } })
    end
    local categorySelector, categorySelectorErr = RSUI:SegmentedSelector({
        id = "v3_buff_display_tab_transfer_category", parent = quickRow, maxItems = 3, gap = 2, height = 24, fontSize = 9,
        items = {
            { value = "auto", text = "自动分类", width = 76 },
            { value = "buff", text = "归入 Buff", width = 78 },
            { value = "debuff", text = "归入 Debuff", width = 88 },
        },
        get = function() return root.importCategory or "auto" end,
        set = function(v) root.importCategory = tostring(v or "auto"); return true end,
        slot = { size = "auto" },
    })
    if categorySelector == nil then error("状态显示导入分类选择器创建失败：" .. tostring(categorySelectorErr or "unknown")) end
    local quickImport = RSUI:Button({ id = "v3_buff_display_tab_transfer_quick_import", parent = quickRow, text = "合并导入", compact = true, slot = { size = "fixed", width = 78 } })
    local quickOverwrite = RSUI:Button({ id = "v3_buff_display_tab_transfer_quick_overwrite", parent = quickRow, text = "覆盖导入", compact = true, slot = { size = "fixed", width = 78 } })

    local transferStatus = RSUI:Text({ id = "v3_buff_display_tab_transfer_status", parent = tabTransfer, text = "当前追踪：--", fontSize = 9, tone = "muted", overflow = "wrap", maxLines = 3, slot = { size = "auto", minHeight = 32, hAlign = "fill" } })

    RSUI:Text({ id = "v3_buff_display_tab_transfer_full_title", parent = tabTransfer, text = "完整导出 / 导入", fontSize = 11, tone = "strong", slot = { size = "fixed", height = 22 } })
    local transferEditHost = RSUI:Border({ id = "v3_buff_display_tab_transfer_edit_host", parent = tabTransfer, padding = 0, variant = "card", slot = { size = "fixed", height = 168, hAlign = "fill" } })
    local transferEditAvailable = false
    if transferEditHost ~= nil and transferEditHost.root ~= nil then
        transferEdit = S.UI:CreateMultiEditBox(transferEditHost.root, "v3_buff_display_tab_transfer_edit", 4, 4, 560, 158, 65535)
        if transferEdit ~= nil and transferEdit.AddAnchor ~= nil and transferEditHost.root ~= nil then
            pcall(transferEdit.AddAnchor, transferEdit, "BOTTOMRIGHT", transferEditHost.root, -4, -4)
        end
        transferEditAvailable = transferEdit ~= nil
    end
    local transferBtnRow = RSUI:HorizontalBox({ id = "v3_buff_display_tab_transfer_buttons", parent = tabTransfer, gap = 6, slot = { size = "fixed", height = 28, hAlign = "fill" } })
    local exportBtn = RSUI:Button({ id = "v3_buff_display_tab_transfer_export", parent = transferBtnRow, text = "导出到文本框", compact = true, slot = { size = "fixed", width = 110 } })
    local importTextBtn = RSUI:Button({ id = "v3_buff_display_tab_transfer_import", parent = transferBtnRow, text = "从文本框导入（合并）", compact = true, slot = { size = "fixed", width = 156 } })
    local clearTextBtn = RSUI:Button({ id = "v3_buff_display_tab_transfer_clear", parent = transferBtnRow, text = "清空文本框", compact = true, slot = { size = "fixed", width = 92 } })
    if transferEditAvailable ~= true then
        transferStatus:SetText("当前客户端不支持多行文本输入框；可使用上方快速导入，或检查 EDITBOX_MULTILINE 支持。")
        exportBtn:SetEnabled(false)
        importTextBtn:SetEnabled(false)
        clearTextBtn:SetEnabled(false)
    end

    ------------------------------------------------------------------
    -- Refresh
    ------------------------------------------------------------------
    function root:Refresh()
        local settings = type(Feature.GetSettingsProjection) == "function" and Feature:GetSettingsProjection() or {}
        local enabled = S.FeatureRuntime ~= nil and S.FeatureRuntime:IsEnabled("combat_buff_display") == true
        local query = tostring(self.filterText or "")
        local hiddenOnly = settings.showHidden == true
        local playerRows, playerRevision, playerCoverage = Feature:GetProjection("player")
        local targetRows, targetRevision, targetCoverage = Feature:GetProjection("target")
        local filteredPlayer, filteredTarget = {}, {}
        for _, row in ipairs(playerRows or {}) do if MatchRow(row, query) and (hiddenOnly ~= true or row.detectionSource == "hidden") then filteredPlayer[#filteredPlayer + 1] = row end end
        for _, row in ipairs(targetRows or {}) do if MatchRow(row, query) and (hiddenOnly ~= true or row.detectionSource == "hidden") then filteredTarget[#filteredTarget + 1] = row end end
        playerTable:SetItems(filteredPlayer, playerRevision)
        targetTable:SetItems(filteredTarget, targetRevision)
        local playerAvailable = enabled and type(playerCoverage) == "table" and playerCoverage.available == true
        local targetAvailable = enabled and type(targetCoverage) == "table" and targetCoverage.available == true
        playerTable:SetViewState(not enabled and "unavailable" or (not playerAvailable and "unavailable" or (#filteredPlayer > 0 and "ready" or "empty")), {
            title = not enabled and "功能已关闭" or (not playerAvailable and "自己状态事实不可用" or "暂无自己状态"),
            detail = not enabled and "启用功能后按需读取共享 Aura 事实。" or (not playerAvailable and tostring(playerCoverage and playerCoverage.error or "Aura 读取失败") or "当前 Aura 事实已成功读取，但没有符合筛选的状态行。")
        })
        targetTable:SetViewState(not enabled and "unavailable" or (not targetAvailable and "unavailable" or (#filteredTarget > 0 and "ready" or "empty")), {
            title = not enabled and "功能已关闭" or (not targetAvailable and "目标状态事实不可用" or "暂无目标状态"),
            detail = not enabled and "启用功能后按需读取共享 Aura 事实。" or (not targetAvailable and tostring(targetCoverage and targetCoverage.error or "Aura 读取失败/当前无可读目标") or "目标 Aura 事实已成功读取，但没有符合筛选的状态行。")
        })
        playerCaption:SetText(CoverageText("自己", playerCoverage))
        targetCaption:SetText(CoverageText("目标", targetCoverage))
        summary:SetData({ value = enabled and "共享 Aura 已接入" or "功能已关闭", detail = CoverageText("自己", playerCoverage) .. "\n" .. CoverageText("目标", targetCoverage) .. " · projection " .. tostring(math.max(tonumber(playerRevision) or 0, tonumber(targetRevision) or 0)) })
        featureButton:SetText(enabled and "关闭功能" or "启用功能")
        widgetButton:SetEnabled(enabled)
        widgetButton:SetText(WidgetHost:IsVisible("combat.buff_display") and "关闭悬浮窗" or "打开悬浮窗")
        buffButton:SetText("Buff：" .. (settings.showBuffs ~= false and "开" or "关"))
        debuffButton:SetText("Debuff：" .. (settings.showDebuffs ~= false and "开" or "关"))
        hiddenButton:SetText("只看隐藏：" .. (settings.showHidden == true and "开" or "关"))
        local tracked = type(settings.tracked) == "table" and settings.tracked or {}
        local trackedCount = #(type(tracked.buff) == "table" and tracked.buff or {}) + #(type(tracked.debuff) == "table" and tracked.debuff or {})
        hint:SetText(enabled and ("BUFF/目标变化事件驱动 + " .. tostring(settings.refreshMs or 400) .. "ms 低频兜底；已追踪 " .. tostring(trackedCount) .. " 个状态；头顶" .. (settings.headShowAll == true and "全部显示（不受追踪限制）" or "仅显示已追踪") .. "，位置刷新 " .. tostring(settings.headRefreshMs or 100) .. "ms，点击行可切换追踪；只看隐藏仅显示客户端隐藏来源行。") or "状态显示功能未启用。")
        -- Keep the active tab's controls in sync with the authoritative store.
        if self.activeTab == "head" then
            for _, toggle in ipairs(headToggles) do if type(toggle.Render) == "function" then toggle:Render() end end
            for _, field in ipairs(headFields) do if type(field.Render) == "function" then field:Render() end end
        elseif self.activeTab == "layout" then
            for _, toggle in ipairs(cardToggles) do if type(toggle.Render) == "function" then toggle:Render() end end
            for _, field in ipairs(cardFields) do if type(field.Render) == "function" then field:Render() end end
        elseif self.activeTab == "transfer" then
            if type(self.RefreshTransferStatus) == "function" then self:RefreshTransferStatus() end
        end
        return true
    end

    function root:RefreshTransferStatus()
        local settings = type(Feature.GetSettingsProjection) == "function" and Feature:GetSettingsProjection() or {}
        local tracked = type(settings.tracked) == "table" and settings.tracked or {}
        local buffCount = #(type(tracked.buff) == "table" and tracked.buff or {})
        local debuffCount = #(type(tracked.debuff) == "table" and tracked.debuff or {})
        transferStatus:SetText("当前追踪：Buff " .. tostring(buffCount) .. " · Debuff " .. tostring(debuffCount) .. "（每类上限 32）。导出文本为 ReplicatedSuite 状态显示格式，可跨存档迁移。")
        return true
    end

    function root:SwitchTab(value)
        value = tostring(value or "track")
        local index = 1
        for i, key in ipairs(TAB_KEYS) do if key == value then index = i break end end
        switcher:SetActiveIndex(index)
        if transferEdit ~= nil and type(transferEdit.Show) == "function" then transferEdit:Show(value == "transfer") end
        if value == "head" then
            for _, toggle in ipairs(headToggles) do if type(toggle.Render) == "function" then toggle:Render() end end
            for _, field in ipairs(headFields) do if type(field.Render) == "function" then field:Render() end end
        elseif value == "layout" then
            for _, toggle in ipairs(cardToggles) do if type(toggle.Render) == "function" then toggle:Render() end end
            for _, field in ipairs(cardFields) do if type(field.Render) == "function" then field:Render() end end
        elseif value == "transfer" then
            if type(self.RefreshTransferStatus) == "function" then self:RefreshTransferStatus() end
        end
        return true
    end

    ------------------------------------------------------------------
    -- Handlers
    ------------------------------------------------------------------
    featureButton.onClick = function()
        local enabled = S.FeatureRuntime:IsEnabled("combat_buff_display") == true
        local target = not enabled
        local ok, err = S.FeatureRuntime:SetPreferredEnabled("combat_buff_display", target, "buff_display_page")
        if ok ~= true then return false, err end
        if target then
            local acquired, acquireErr = Feature:AcquireConsumer("page:buff_display")
            if acquired ~= true then
                S.FeatureRuntime:SetPreferredEnabled("combat_buff_display", false, "buff_display_consumer_rollback")
                root:Refresh()
                return false, acquireErr or "状态显示 Consumer 启动失败"
            end
            if S.Events ~= nil and type(S.Events.UnsubscribeInternalOwner) == "function" and type(S.Events.SubscribeInternal) == "function" then
                S.Events:UnsubscribeInternalOwner(root)
                S.Events:SubscribeInternal("v3.buff_display.updated", root, function() root:Refresh() end)
            end
        else
            if S.Events ~= nil and type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(root) end
        end
        return root:Refresh()
    end
    widgetButton.onClick = function()
        return WidgetHost:SetVisible("combat.buff_display", not WidgetHost:IsVisible("combat.buff_display"), { source = "buff_display_page" })
    end
    buffButton.onClick = function() local settings = Feature:GetSettingsProjection(); return Apply("showBuffs", not (settings.showBuffs ~= false)) end
    debuffButton.onClick = function() local settings = Feature:GetSettingsProjection(); return Apply("showDebuffs", not (settings.showDebuffs ~= false)) end
    hiddenButton.onClick = function() local settings = Feature:GetSettingsProjection(); return Apply("showHidden", not (settings.showHidden == true)) end
    searchClear.onClick = function()
        root.filterText = ""
        if searchInput ~= nil and type(searchInput.SetValue) == "function" then searchInput:SetValue("", false, "search_clear") end
        return root:Refresh()
    end
    trackButton.onClick = function()
        if root.selectedBuffId == nil then return false, "请先在自己或目标列表选择一个状态" end
        local ok, err = Feature.Commands:SetTrackedId(root.selectedBuffId, root.selectedBuffCategory, true)
        if ok then root:Refresh() end
        return ok, err
    end
    untrackButton.onClick = function()
        if root.selectedBuffId == nil then return false, "请先选择要取消追踪的状态" end
        local ok, err = Feature.Commands:SetTrackedId(root.selectedBuffId, root.selectedBuffCategory, false)
        if ok then root:Refresh() end
        return ok, err
    end
    clearTrackButton.onClick = function() local ok, err = Feature.Commands:ClearTrackedIds(); if ok then root:Refresh() end; return ok, err end

    local function QuickImportText(mode)
        local text = ""
        if quickInput ~= nil and type(quickInput.GetDraftValue) == "function" then text = tostring(quickInput:GetDraftValue() or "") end
        if text == "" then transferStatus:SetText("请先在输入框中填写要导入的 Buff ID（逗号/换行分隔）。"); return true end
        local ok, err = Feature.Commands:ImportTrackedIds(text, root.importCategory or "auto", mode or "merge")
        if ok == true then
            root:Refresh()
            transferStatus:SetText(tostring(err or "导入完成"))
        else
            transferStatus:SetText("导入失败：" .. tostring(err or "未知错误"))
        end
        return true
    end
    quickImport.onClick = function() return QuickImportText("merge") end
    quickOverwrite.onClick = function() return QuickImportText("overwrite") end

    exportBtn.onClick = function()
        if transferEdit == nil then transferStatus:SetText("多行文本框不可用，无法导出。"); return true end
        local data = Feature.Commands:ExportAll()
        local text = Feature.Commands:SerializeExport(data)
        WriteNativeText(transferEdit, text)
        local tracked = type(data) == "table" and type(data.tracked) == "table" and data.tracked or {}
        transferStatus:SetText("已导出 Buff " .. tostring(#(type(tracked.buff) == "table" and tracked.buff or {})) .. " · Debuff " .. tostring(#(type(tracked.debuff) == "table" and tracked.debuff or {})) .. " 到文本框。")
        return true
    end
    importTextBtn.onClick = function()
        if transferEdit == nil then transferStatus:SetText("多行文本框不可用，无法导入。"); return true end
        local text = ReadNativeText(transferEdit)
        if text == "" then transferStatus:SetText("文本框为空，无可导入内容。"); return true end
        local parsed = Feature.Commands:ParseImportText(text)
        if parsed == nil or type(parsed) ~= "table" then transferStatus:SetText("导入文本解析失败。"); return true end
        if type(parsed.errors) == "table" and #parsed.errors > 0 then
            local first = table.concat(parsed.errors, "；")
            if #first > 160 then first = string.sub(first, 1, 160) .. "……" end
            transferStatus:SetText("解析失败 " .. tostring(#parsed.errors) .. " 处：" .. first)
            return true
        end
        local ok, err = Feature.Commands:ImportAll(parsed.data, "merge")
        if ok ~= true then transferStatus:SetText("导入失败：" .. tostring(err or "未知错误")); return true end
        root:Refresh()
        local warnings = type(parsed.warnings) == "table" and parsed.warnings or {}
        transferStatus:SetText(tostring(err or "导入完成") .. (#warnings > 0 and ("；警告 " .. tostring(#warnings) .. " 条") or ""))
        return true
    end
    clearTextBtn.onClick = function()
        WriteNativeText(transferEdit, "")
        transferStatus:SetText("文本框已清空。")
        return true
    end

    for _, button in ipairs({ featureButton, widgetButton, buffButton, debuffButton, hiddenButton, searchClear, trackButton, untrackButton, clearTrackButton, quickImport, quickOverwrite, exportBtn, importTextBtn, clearTextBtn }) do
        if button ~= nil and button.root ~= nil then S.UI:SafeHandler(button.root, "OnClick", button.onClick, "v3_buff_display:" .. tostring(button.id or "action")) end
    end

    ------------------------------------------------------------------
    -- Lifecycle
    ------------------------------------------------------------------
    function root:OnActivated()
        if S.FeatureRuntime:IsEnabled("combat_buff_display") == true then
            local ok, err = Feature:AcquireConsumer("page:buff_display")
            if ok ~= true then return false, err end
            if S.Events ~= nil and type(S.Events.UnsubscribeInternalOwner) == "function" and type(S.Events.SubscribeInternal) == "function" then
                S.Events:UnsubscribeInternalOwner(self)
                S.Events:SubscribeInternal("v3.buff_display.updated", self, function() root:Refresh() end)
            end
        end
        return self:Refresh()
    end
    function root:OnDeactivated()
        if S.Events ~= nil and type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
        Feature:ReleaseConsumer("page:buff_display")
        return true
    end
    function root:RefreshData() return self:Refresh() end
    root.route = route
    return root
end

local ok, err = PageHost:RegisterFactory(ROUTE, BuildPage)
if ok ~= true then error(err) end

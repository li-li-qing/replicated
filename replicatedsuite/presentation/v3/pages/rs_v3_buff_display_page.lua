------------------------------------------------------------------------
-- Replicated Suite V3 - Buff Display Page (four-tab layout)
--
--  * Tab 1  状态追踪: Buff/Debuff/隐藏 filter + keyword search + row-click
--            tracked toggle on player/target projections; 冻结列表 toggle keeps
--            vanished tracked rows in the list (freezeEnabled).
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
    D:PageHeader(root, "v3_buff_display_header", "状态显示", "追踪自己/目标的 Buff、Debuff 与隐藏状态；点击状态行切换追踪。", "刷新", function()
        return Feature.Commands:Refresh("page_manual")
    end)

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
    -- Row-click is the primary track interaction (onItemActivated). The old
    -- 追踪选中/取消追踪 buttons were removed per UX request; 清空追踪 and the
    -- freeze-list toggle stay as list-level operations.
    local selectedText = RSUI:Text({ id = "v3_buff_display_selected", parent = trackRow, text = "点击状态行可追踪 / 取消追踪", fontSize = 9, tone = "muted", overflow = "ellipsis", slot = { size = "fill", fill = 1, minWidth = 150 } })
    local freezeButton = RSUI:Button({ id = "v3_buff_display_track_freeze", parent = trackRow, text = "冻结列表：关", compact = true, slot = { size = "fixed", width = 96 } })
    local clearTrackButton = RSUI:Button({ id = "v3_buff_display_track_clear", parent = trackRow, text = "清空追踪", compact = true, slot = { size = "fixed", width = 78 } })
    -- Restores every display/layout setting (column widths, sizes, gaps,
    -- presets, refresh cadence, tracked ids) to current defaults; used when a
    -- stale saved layout makes list content hard to read.
    local resetButton = RSUI:Button({ id = "v3_buff_display_track_reset", parent = trackRow, text = "恢复默认", compact = true, slot = { size = "fixed", width = 78 } })
    -- One-shot live probe: prints the RAW buff-table shapes the client returns
    -- to chat, so name-field questions are answered with evidence, not guesses.
    local probeButton = RSUI:Button({ id = "v3_buff_display_track_probe", parent = trackRow, text = "字段诊断", compact = true, slot = { size = "fixed", width = 78 } })

    -- DataView callbacks must be supplied at construction. TableView snapshots
    -- them into its internal ListView; assigning tableView.onSelectionChanged or
    -- tableView.onItemActivated afterwards leaves the native row click path nil.
    -- Row activation mirrors the gear editor's proven interaction: selectable =
    -- false + onItemActivated, so a row click goes straight to the activate
    -- path (no SelectionModel round-trip) and toggles tracking immediately.
    root.selectedBuffId, root.selectedBuffName, root.selectedBuffCategory = nil, nil, nil
    local function ToggleRowTracked(item, index, key, view, reason)
        if type(item) ~= "table" or item.id == nil then return true end
        local target = not (item.tracked == true)
        local ok, err = Feature.Commands:SetTrackedId(tonumber(item.id), item.category == "debuff" and "debuff" or "buff", target)
        if ok == true then
            selectedText:SetText((target == true and "已追踪：" or "已取消追踪：") .. tostring(item.name or item.id or "") .. " · ID " .. tostring(item.id))
            root:Refresh()
        else
            -- Surface command failures (e.g. the 32-id cap or an invalid id)
            -- instead of a silent dead click, so the user sees why the toggle
            -- did not apply and the failure is diagnosable in the client.
            selectedText:SetText("追踪失败：" .. tostring(item.name or item.id or "") .. " · " .. tostring(err or "未知错误"))
        end
        return ok, err
    end

    local tableRow = RSUI:HorizontalBox({ id = "v3_buff_display_tables", parent = tabTrack, gap = 7, slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" } })
    local function MakeTable(id, title)
        local panel = RSUI:Border({ id = id .. "_panel", parent = tableRow, padding = 5, variant = "card", slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" } })
        local stack = RSUI:VerticalBox({ id = id .. "_stack", parent = panel, gap = 3, slot = { hAlign = "fill", vAlign = "fill" } })
        local caption = RSUI:Text({ id = id .. "_caption", parent = stack, text = title, fontSize = 10, tone = "strong", slot = { size = "fixed", height = 20 } })
        local tableView = RSUI:TableView({
            id = id .. "_table", parent = stack, items = {}, rowHeight = 25, headerHeight = 23, desiredRows = 8,
            overscan = 1, scrollbar = true, selectable = false, columnResize = true, headerInteractive = false,
            onItemActivated = ToggleRowTracked,
            columns = {
                { id = "id", title = "ID", field = "id", size = "fixed", width = 52, minWidth = 44, sortable = false },
                { id = "icon", title = "", field = "iconPath", cellType = "icon", iconSize = 18, fallbackIcon = "ui/icon/icon_unknown_item.dds", size = "fixed", width = 25, minWidth = 24, sortable = false, resizable = false },
                { id = "name", title = "状态", field = "name", size = "fill", minWidth = 90, fill = 1, getTone = function(item)
                    if type(item) ~= "table" then return "default" end
                    if item.effectType == "debuff" then return "red" end
                    if item.detectionSource == "hidden" or item.frozen == true then return "muted" end
                    return "default"
                end },
                { id = "type", title = "类型", field = "effectTypeText", size = "fixed", width = 54, minWidth = 48, sortable = false },
                { id = "stack", title = "层", field = "stack", size = "fixed", width = 36, minWidth = 30, sortable = false },
                { id = "time", title = "剩余", field = "timeText", size = "fixed", width = 52, minWidth = 44, sortable = false },
                { id = "tracked", title = "追踪", field = "trackedText", size = "fixed", width = 56, minWidth = 50, sortable = false, getTone = function(item) return item and item.tracked == true and "green" or "muted" end },
            },
            slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
        })
        return caption, tableView
    end
    local playerCaption, playerTable = MakeTable("v3_buff_display_player", "自己")
    local targetCaption, targetTable = MakeTable("v3_buff_display_target", "目标")

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
    AddHeadField({ id = "v3_buff_display_head_refresh", label = "位置刷新", min = 1, max = 2000, step = 25, integer = true, unit = "ms", slider = true,
        get = function() return (Feature:GetSettingsProjection() or {}).headRefreshMs or 100 end, set = function(v) return Feature.Commands:SetSetting("headRefreshMs", v) end, slot = { size = "fill", fill = 1 } })

    -- Schema 5: virtual health-bar anchor (aligned onto the native bar by the
    -- player) + global scale + info row controls. Nothing is drawn for the bar
    -- itself — the game's own health bar renders it.
    local plateRow = RSUI:HorizontalBox({ id = "v3_buff_display_plate_actions", parent = tabHead, gap = 6, slot = { size = "fixed", height = 30, hAlign = "fill" } })
    local infoToggle = RSUI:Toggle({
        id = "v3_buff_display_info_enabled", parent = plateRow, width = 104, height = 26,
        onText = "信息行：开", offText = "信息行：关",
        get = function() return (Feature:GetSettingsProjection() or {}).info ~= nil and (Feature:GetSettingsProjection() or {}).info.enabled ~= false end,
        set = function(v) return Feature.Commands:SetSetting("info.enabled", v == true) end,
        slot = { size = "fixed", width = 104 },
    })
    if infoToggle ~= nil then headToggles[#headToggles + 1] = infoToggle end
    local plateGrid = RSUI:UniformGrid({ id = "v3_buff_display_plate_settings", parent = tabHead, minCellWidth = 180, minCellHeight = 30, maxColumns = 4, gap = 5, slot = { size = "auto", minHeight = 30, hAlign = "fill" } })
    local function AddPlateField(spec)
        local field = D:CompactNumericSetting(plateGrid, spec)
        if field ~= nil then headFields[#headFields + 1] = field end
        return field
    end
    AddPlateField({ id = "v3_buff_display_plate_width", label = "血条宽度", min = 80, max = 320, step = 4, integer = true, unit = "px", slider = true,
        get = function() return (Feature:GetSettingsProjection() or {}).plate and (Feature:GetSettingsProjection() or {}).plate.width or 150 end, set = function(v) return Feature.Commands:SetSetting("plate.width", v) end, slot = { size = "fill", fill = 1 } })
    AddPlateField({ id = "v3_buff_display_plate_height", label = "血条高度", min = 8, max = 40, step = 1, integer = true, unit = "px", slider = true,
        get = function() return (Feature:GetSettingsProjection() or {}).plate and (Feature:GetSettingsProjection() or {}).plate.height or 20 end, set = function(v) return Feature.Commands:SetSetting("plate.height", v) end, slot = { size = "fill", fill = 1 } })
    AddPlateField({ id = "v3_buff_display_plate_x", label = "血条 X", min = -200, max = 200, step = 2, integer = true, slider = true,
        get = function() return (Feature:GetSettingsProjection() or {}).plate and (Feature:GetSettingsProjection() or {}).plate.x or 0 end, set = function(v) return Feature.Commands:SetSetting("plate.x", v) end, slot = { size = "fill", fill = 1 } })
    AddPlateField({ id = "v3_buff_display_plate_y", label = "血条 Y (对齐原生血条)", min = -500, max = 500, step = 5, integer = true, slider = true,
        get = function() return (Feature:GetSettingsProjection() or {}).plate and (Feature:GetSettingsProjection() or {}).plate.y or 0 end, set = function(v) return Feature.Commands:SetSetting("plate.y", v) end, slot = { size = "fill", fill = 1 } })
    AddPlateField({ id = "v3_buff_display_plate_scale", label = "全局缩放", min = 0.5, max = 2, step = 0.05, integer = false, slider = true,
        get = function() return (Feature:GetSettingsProjection() or {}).plateScale or 1 end, set = function(v) return Feature.Commands:SetSetting("plateScale", v) end, slot = { size = "fill", fill = 1 } })
    local infoGrid = RSUI:UniformGrid({ id = "v3_buff_display_info_settings", parent = tabHead, minCellWidth = 180, minCellHeight = 30, maxColumns = 4, gap = 5, slot = { size = "auto", minHeight = 30, hAlign = "fill" } })
    local function AddInfoField(spec)
        local field = D:CompactNumericSetting(infoGrid, spec)
        if field ~= nil then headFields[#headFields + 1] = field end
        return field
    end
    AddInfoField({ id = "v3_buff_display_info_font", label = "信息行字号", min = 8, max = 24, step = 1, integer = true, slider = true,
        get = function() return (Feature:GetSettingsProjection() or {}).info and (Feature:GetSettingsProjection() or {}).info.fontSize or 10 end, set = function(v) return Feature.Commands:SetSetting("info.fontSize", v) end, slot = { size = "fill", fill = 1 } })
    AddInfoField({ id = "v3_buff_display_info_x", label = "信息行 X", min = -200, max = 200, step = 2, integer = true, slider = true,
        get = function() return (Feature:GetSettingsProjection() or {}).info and (Feature:GetSettingsProjection() or {}).info.x or 0 end, set = function(v) return Feature.Commands:SetSetting("info.x", v) end, slot = { size = "fill", fill = 1 } })
    AddInfoField({ id = "v3_buff_display_info_y", label = "信息行 Y", min = -80, max = 80, step = 2, integer = true, slider = true,
        get = function() return (Feature:GetSettingsProjection() or {}).info and (Feature:GetSettingsProjection() or {}).info.y or 0 end, set = function(v) return Feature.Commands:SetSetting("info.y", v) end, slot = { size = "fill", fill = 1 } })
    local infoToggles = {
        { key = "showClass", text = "职业", on = "职业：开", off = "职业：关" },
        { key = "showGear", text = "装分", on = "装分：开", off = "装分：关" },
        { key = "showDistance", text = "距离", on = "距离：开", off = "距离：关" },
    }
    for _, toggleSpec in ipairs(infoToggles) do
        local t = RSUI:Toggle({
            id = "v3_buff_display_info_" .. toggleSpec.key, parent = tabHead, width = 96, height = 26,
            onText = toggleSpec.on, offText = toggleSpec.off,
            get = function()
                local info = (Feature:GetSettingsProjection() or {}).info or {}
                return info[toggleSpec.key] ~= false
            end,
            set = function(v) return Feature.Commands:SetSetting("info." .. toggleSpec.key, v == true) end,
            slot = { size = "fixed", width = 96 },
        })
        if t ~= nil then headToggles[#headToggles + 1] = t end
    end

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
                set = function(v)
                    local ok, err = Feature.Commands:SetComponentField(key, fieldKey, v)
                    -- A rejected write (e.g. store write-fence) must not look
                    -- like a silent dead control; surface it to diagnostics so
                    -- the client log pinpoints why the value snapped back.
                    if ok ~= true and S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.WarnRateLimited) == "function" then
                        S.DiagnosticsManager:WarnRateLimited("buff_display_page", "COMPONENT_FIELD_REJECTED", 3000,
                            "组件设置保存失败", { component = key, field = fieldKey, error = tostring(err or "unknown"), value = tostring(v) })
                    end
                    return ok, err
                end,
                slot = { size = "fill", fill = 1, hAlign = "fill" },
            })
            if field ~= nil then cardFields[#cardFields + 1] = field end
            return field
        end
        -- class/gearScore/distance merge into the single InfoRow; their own
        -- x/y have no runtime meaning (position is owned by info.x/info.y), so
        -- we don't expose dead position controls for them. Equipment and cast
        -- components keep x/y as local anchor-relative fine-tune offsets.
        local isInfoField = key == "class" or key == "gearScore" or key == "distance"
        if not isInfoField then
            AddField("x", "X 偏移", -400, 400, 2, "px", true)
            AddField("y", "Y 偏移", -400, 400, 2, "px", true)
        end
        AddField("size", "尺寸", 0, 64, 1, "px", true)
        if not isInfoField then
            AddField("fontSize", "字号", 0, 32, 1, "px", true)
        end
        AddField("alpha", "透明度", 0.1, 1.0, 0.05, "", false)
        if key == "buffs" or key == "debuffs" then
            AddField("spacing", "图标间距", 0, 24, 1, "px", true)
            AddField("maxPerRow", "每行数量", 1, 16, 1, "", true)
            AddField("maxRows", "最大行数", 1, 4, 1, "", true)
        end
        if key == "castBar" then
            AddField("width", "条宽", 20, 480, 4, "px", true)
            local showTextToggle = RSUI:Toggle({
                id = cardId .. "_showText", parent = stack, width = 116, height = 22,
                onText = "施法名：开", offText = "施法名：关",
                get = function()
                    local components = (Feature:GetSettingsProjection() or {}).components or {}
                    local component = components[key] or {}
                    return component.showText ~= false
                end,
                set = function(v) return Feature.Commands:SetComponentField(key, "showText", v == true) end,
                slot = { size = "fixed", width = 116 },
            })
            if showTextToggle ~= nil then cardToggles[#cardToggles + 1] = showTextToggle end
        end
        return card
    end
    -- Grouped layout: components are grouped by their anchor-relative region so
    -- the player sees Buff / Debuff / 顶部信息 / 左右装备 / 读条 instead of ten
    -- flat cards. class/gearScore/distance expose only their enable toggle (the
    -- row position is owned by the top-info section, not per-component).
    local function CardGroup(title)
        RSUI:Text({ id = "v3_buff_display_tab_layout_group_" .. tostring(title), parent = layoutScroll,
            text = "── " .. tostring(title) .. " ──", fontSize = 10, tone = "strong", slot = { size = "auto", hAlign = "fill" } })
    end
    local groups = {
        { "Buff", { "buffs" } },
        { "Debuff", { "debuffs" } },
        { "顶部信息", { "class", "gearScore", "distance" } },
        { "左侧装备", { "mainHand", "offHand" } },
        { "右侧装备", { "wings", "ranged" } },
        { "读条", { "castBar" } },
    }
    for _, group in ipairs(groups) do
        CardGroup(group[1])
        for _, key in ipairs(group[2]) do
            local meta = COMPONENT_META[key] or { title = key, desc = "" }
            BuildComponentCard(key, meta)
        end
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
        local hiddenEmptyDetail = hiddenOnly and "已开启只看隐藏，但当前没有客户端隐藏来源（Hidden Buff）的状态行；潜行/隐匿等效果出现时会显示在这里。" or "当前 Aura 事实已成功读取，但没有符合筛选的状态行。"
        playerTable:SetViewState(not enabled and "unavailable" or (not playerAvailable and "unavailable" or (#filteredPlayer > 0 and "ready" or "empty")), {
            title = not enabled and "功能已关闭" or (not playerAvailable and "自己状态事实不可用" or "暂无自己状态"),
            detail = not enabled and "启用功能后按需读取共享 Aura 事实。" or (not playerAvailable and tostring(playerCoverage and playerCoverage.error or "Aura 读取失败") or hiddenEmptyDetail)
        })
        targetTable:SetViewState(not enabled and "unavailable" or (not targetAvailable and "unavailable" or (#filteredTarget > 0 and "ready" or "empty")), {
            title = not enabled and "功能已关闭" or (not targetAvailable and "目标状态事实不可用" or "暂无目标状态"),
            detail = not enabled and "启用功能后按需读取共享 Aura 事实。" or (not targetAvailable and tostring(targetCoverage and targetCoverage.error or "Aura 读取失败/当前无可读目标") or hiddenEmptyDetail)
        })
        playerCaption:SetText("自己 · " .. tostring(#filteredPlayer) .. " 个状态")
        targetCaption:SetText("目标 · " .. tostring(#filteredTarget) .. " 个状态")
        featureButton:SetText(enabled and "关闭功能" or "启用功能")
        widgetButton:SetEnabled(enabled)
        widgetButton:SetText(WidgetHost:IsVisible("combat.buff_display") and "关闭悬浮窗" or "打开悬浮窗")
        buffButton:SetText("Buff：" .. (settings.showBuffs ~= false and "开" or "关"))
        debuffButton:SetText("Debuff：" .. (settings.showDebuffs ~= false and "开" or "关"))
        hiddenButton:SetText("只看隐藏：" .. (settings.showHidden == true and "开" or "关"))
        freezeButton:SetText("冻结列表：" .. (settings.freezeEnabled == true and "开" or "关"))
        local tracked = type(settings.tracked) == "table" and settings.tracked or {}
        local trackedCount = #(type(tracked.buff) == "table" and tracked.buff or {}) + #(type(tracked.debuff) == "table" and tracked.debuff or {})
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
            -- Fill the projection synchronously; the aura lane only runs on the
            -- next Scheduler frame, and the first paint must not show an empty
            -- table (the reload-first-open symptom).
            Feature.Commands:Refresh("page_enable")
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
    freezeButton.onClick = function() local settings = Feature:GetSettingsProjection(); return Apply("freezeEnabled", not (settings.freezeEnabled == true)) end
    clearTrackButton.onClick = function() local ok, err = Feature.Commands:ClearTrackedIds(); if ok then root:Refresh() end; return ok, err end
    resetButton.onClick = function()
        local ok, err = Feature.Commands:ResetAllSettings()
        if ok == true then
            selectedText:SetText("已恢复默认显示与布局设置")
            root:Refresh()
        else
            selectedText:SetText("恢复默认失败：" .. tostring(err or "未知错误"))
        end
        return ok, err
    end
    probeButton.onClick = function()
        local ok, summary = Feature.Commands:ProbeAuraFields()
        selectedText:SetText(ok == true and ("字段诊断已输出到聊天框 · " .. tostring(summary)) or tostring(summary or "诊断失败"))
        root:Refresh()
        return ok, summary
    end

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

    for _, button in ipairs({ featureButton, widgetButton, buffButton, debuffButton, hiddenButton, searchClear, freezeButton, clearTrackButton, resetButton, probeButton, quickImport, quickOverwrite, exportBtn, importTextBtn, clearTextBtn }) do
        if button ~= nil and button.root ~= nil then S.UI:SafeHandler(button.root, "OnClick", button.onClick, "v3_buff_display:" .. tostring(button.id or "action")) end
    end

    ------------------------------------------------------------------
    -- Lifecycle
    ------------------------------------------------------------------
    function root:OnActivated()
        if S.FeatureRuntime:IsEnabled("combat_buff_display") == true then
            -- Reload flow: the Feature is already enabled with a loaded store,
            -- but the aura lane only fills the projection on the next Scheduler
            -- frame. Refresh synchronously here so the first open shows facts
            -- and tracked state immediately instead of an empty/untracked table
            -- that only recovers after a close/reopen cycle.
            if type(Feature.EnsureStoreLoaded) == "function" then Feature:EnsureStoreLoaded() end
            local ok, err = Feature:AcquireConsumer("page:buff_display")
            if ok ~= true then return false, err end
            if S.Events ~= nil and type(S.Events.UnsubscribeInternalOwner) == "function" and type(S.Events.SubscribeInternal) == "function" then
                S.Events:UnsubscribeInternalOwner(self)
                S.Events:SubscribeInternal("v3.buff_display.updated", self, function() root:Refresh() end)
            end
            Feature.Commands:Refresh("page_activated")
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

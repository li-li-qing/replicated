------------------------------------------------------------------------
-- Replicated Suite V3 - Buff Display Page (UI_IMPLEMENTING / HUD calibration v1)
--
-- Three authoritative surfaces only:
--   1) 追踪管理  : one virtual TableView for player + target facts.
--   2) HUD 布局  : policy controls + standalone in-world HUD calibration entry.
--                  Calibration owns a detached player/target draft and only
--                  Save & Exit crosses the Persistence boundary.
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

    D:PageHeader(root, "v3_buff_display_header", "状态显示", "统一管理状态追踪与头顶 HUD；HUD 校准会暂时最小化主菜单，在真实游戏画面上调整。", "刷新", function()
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
    local layoutPolicyControls = {}
    local layoutProfileSummary = nil
    local calibrationButton = nil

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
    -- Tab 2: HUD layout policy + standalone real-screen calibration.
    ------------------------------------------------------------------
    local tabLayout = RSUI:VerticalBox({ id = "v3_buff_display_tab_layout", parent = switcher, gap = 7, slot = { hAlign = "fill", vAlign = "fill" } })

    -- 中文维护注释（页面职责收敛，2026-09-11）：旧页把 640x320 的假画布塞在主菜单内部，
    -- 用户打开菜单后真实角色头顶 HUD 被遮住，拖动结果也无法和实际画面对齐。这里不再维护
    -- 第二套布局几何编辑器；主菜单只保留低频业务策略，几何/字体/图标/行数由独立
    -- BuffHudCalibrationV3 在真实 UIParent 上编辑。Authority 仍是 BuffDisplay Store。
    local introCard = RSUI:Border({ id = "v3_buff_display_layout_intro_card", parent = tabLayout, padding = 8, variant = "card",
        minHeight = 112, slot = { size = "auto", minHeight = 112, hAlign = "fill" } })
    local introStack = RSUI:VerticalBox({ id = "v3_buff_display_layout_intro_stack", parent = introCard, gap = 4, slot = { hAlign = "fill" } })
    RSUI:Text({ id = "v3_buff_display_layout_intro_title", parent = introStack, text = "HUD 校准模式", fontSize = 12, tone = "strong", slot = { size = "fixed", height = 22 } })
    RSUI:Text({ id = "v3_buff_display_layout_intro_text", parent = introStack, text = "点击“调整 HUD”后主菜单会临时最小化。可分别校准自己 / 目标 HUD，拖动预览框或用方向键、数值框精调；目标 HUD 可手动一键同步自身布局。", fontSize = 10, tone = "muted", overflow = "wrap", maxLines = 3, slot = { size = "auto", minHeight = 38, hAlign = "fill" } })
    local launchRow = RSUI:HorizontalBox({ id = "v3_buff_display_layout_launch_row", parent = introStack, gap = 8, slot = { size = "fixed", height = 32, hAlign = "fill" } })
    calibrationButton = RSUI:Button({ id = "v3_buff_display_layout_open_calibration", parent = launchRow, text = "调整 HUD", compact = false, slot = { size = "fixed", width = 132 } })
    layoutProfileSummary = RSUI:Text({ id = "v3_buff_display_layout_profile_summary", parent = launchRow, text = "自己 / 目标：独立布局", fontSize = 9, tone = "muted", overflow = "ellipsis", slot = { size = "fill", fill = 1, vAlign = "center" } })

    -- 中文维护注释（HUD 布局页响应式重排，2026-09-11）：旧版把 6 个固定宽度开关塞进
    -- 单行 HorizontalBox，再把刷新滑块塞进同一张 auto-height 卡片；在 1k/0.8 UI Scale 下
    -- 子控件宽度超过内容区且 CompactNumericSetting 自己需要多行高度，最终出现截图中的重叠。
    -- Authority 仍由 Feature Settings 持有；这里只改变 Presentation 排版，不复制任何设置状态。
    -- 三块职责固定为“校准入口 / 显示策略 / 刷新设置”，以后新增策略优先进入 Grid，禁止重新
    -- 回到一行固定按钮堆叠。
    -- 中文维护注释（.18.206 Measure 修复）：RSUI Border:Measure() 读取的是 Border 自身 spec.minHeight，
    -- 不是父 VerticalBox 的 slot.minHeight。.18.205 只把最小高度写进 slot，Native 子控件实际需要更高
    -- 时父布局仍可能按过小 desiredHeight 排下一个卡片，造成截图中的边框/文本重叠。本版把 minHeight
    -- 同时声明在组件 spec 与 slot：spec 是 Measure Authority，slot 只作为父容器的下限提示。该修复
    -- 仅影响 Presentation 几何，不读写 Store，也不改变响应式 Grid 的列数 Authority。
    local policyCard = RSUI:Border({ id = "v3_buff_display_layout_policy_card", parent = tabLayout, padding = 8, variant = "card",
        minHeight = 132, slot = { size = "auto", minHeight = 132, hAlign = "fill" } })
    local policyStack = RSUI:VerticalBox({ id = "v3_buff_display_layout_policy_stack", parent = policyCard, gap = 6, slot = { hAlign = "fill" } })
    RSUI:Text({ id = "v3_buff_display_layout_policy_title", parent = policyStack, text = "显示策略", fontSize = 11, tone = "strong", slot = { size = "fixed", height = 20 } })
    local policyToggleGrid = RSUI:UniformGrid({ id = "v3_buff_display_layout_policy_toggle_grid", parent = policyStack, minCellWidth = 96, minCellHeight = 28, maxColumns = 3, gap = 5, slot = { size = "auto", hAlign = "fill" } })
    local policySpecs = {
        { key="headEnabled", on="HUD：开", off="HUD：关", trueOnly=false },
        { key="headShowAll", on="全部：开", off="全部：关", trueOnly=true },
        { key="headPlayer", on="自己：开", off="自己：关", trueOnly=false },
        { key="headTarget", on="目标：开", off="目标：关", trueOnly=false },
        { key="headShowStacks", on="层数：开", off="层数：关", trueOnly=false },
        { key="headShowTime", on="时间：开", off="时间：关", trueOnly=false },
    }
    for _, spec in ipairs(policySpecs) do
        local key, trueOnly = spec.key, spec.trueOnly == true
        local toggle = RSUI:Toggle({
            id = "v3_buff_display_layout_policy_" .. key, parent = policyToggleGrid, width = 94, height = 24,
            onText = spec.on, offText = spec.off,
            get = function()
                local settings = Feature:GetSettingsProjection() or {}
                return trueOnly and settings[key] == true or (not trueOnly and settings[key] ~= false)
            end,
            set = function(value) return ApplySetting(key, value == true) end,
            slot = { size = "auto", hAlign = "left", vAlign = "center" },
        })
        if toggle ~= nil then layoutPolicyControls[#layoutPolicyControls + 1] = toggle end
    end
    RSUI:Text({ id = "v3_buff_display_layout_policy_hint", parent = policyStack, text = "这里仅控制 HUD 是否运行和通用文字显示；各组件位置、图标、字号、间距和尺寸统一在“调整 HUD”里设置。", fontSize = 9, tone = "muted", overflow = "wrap", maxLines = 2, slot = { size = "auto", minHeight = 28, hAlign = "fill" } })

    local refreshCard = RSUI:Border({ id = "v3_buff_display_layout_refresh_card", parent = tabLayout, padding = 8, variant = "card",
        minHeight = 104, slot = { size = "auto", minHeight = 104, hAlign = "fill" } })
    local refreshStack = RSUI:VerticalBox({ id = "v3_buff_display_layout_refresh_stack", parent = refreshCard, gap = 5, slot = { hAlign = "fill" } })
    RSUI:Text({ id = "v3_buff_display_layout_refresh_title", parent = refreshStack, text = "刷新设置", fontSize = 11, tone = "strong", slot = { size = "fixed", height = 20 } })
    local refreshGrid = RSUI:UniformGrid({ id = "v3_buff_display_layout_refresh_grid", parent = refreshStack, minCellWidth = 320, minCellHeight = 34, maxColumns = 1, gap = 4, slot = { size = "auto", hAlign = "fill" } })
    local refreshField = D:CompactNumericSetting(refreshGrid, {
        id = "v3_buff_display_layout_refresh", label = "HUD 刷新", min = 25, max = 2000, hardMin = 1, hardMax = 2000, step = 25, integer = true, unit = "ms", slider = true,
        get = function() return tonumber((Feature:GetSettingsProjection() or {}).headRefreshMs) or 50 end,
        set = function(v) return ApplySetting("headRefreshMs", math.floor((tonumber(v) or 50) + 0.5)) end,
        slot = { size = "fill", fill = 1 },
    })
    if refreshField ~= nil then layoutPolicyControls[#layoutPolicyControls + 1] = refreshField end
    RSUI:Text({ id = "v3_buff_display_layout_refresh_hint", parent = refreshStack, text = "PVP 推荐保持 50ms；只有在低性能设备或大规模战斗中需要时再提高。", fontSize = 9, tone = "muted", overflow = "wrap", maxLines = 2, slot = { size = "auto", minHeight = 26, hAlign = "fill" } })

    function root:RefreshLayoutControls()
        for _, control in ipairs(layoutPolicyControls) do
            if control ~= nil and type(control.Render) == "function" then control:Render() end
        end
        if layoutProfileSummary ~= nil then
            local snapshot = Feature.Commands:GetHudCalibrationSnapshot()
            local player = type(snapshot) == "table" and snapshot.player or nil
            local target = type(snapshot) == "table" and snapshot.target or nil
            local pScale = type(player) == "table" and tonumber(player.plateScale) or 1
            local tScale = type(target) == "table" and tonumber(target.plateScale) or 1
            layoutProfileSummary:SetText(string.format("自己 / 目标独立保存 · 缩放 %.2f / %.2f · 保存并退出后写入存档", pScale or 1, tScale or 1))
        end
        return true
    end

    calibrationButton.onClick = function()
        local calibration = S.UIV3 and S.UIV3.BuffHudCalibrationV3 or nil
        if type(calibration) ~= "table" or type(calibration.Open) ~= "function" then return false, "HUD 校准模块未加载" end
        local ok, err = calibration:Open({ source = "status_display_page", scope = "player", onExit = function(saved, restored, restoreErr)
            if saved == true then persistHint:SetText("HUD 校准已保存 · 自己 / 目标配置已写入")
            else persistHint:SetText("HUD 校准已取消 · 未保存本次修改") end
            if restored ~= true and restoreErr ~= nil then persistHint:SetText("HUD 校准已退出，但主菜单恢复异常：" .. tostring(restoreErr)) end
            if type(root.RefreshLayoutControls) == "function" then root:RefreshLayoutControls() end
        end })
        if ok ~= true then return false, err or "HUD 校准启动失败" end
        persistHint:SetText("HUD 校准中 · 保存并退出后写入配置")
        return true
    end
    root:RefreshLayoutControls()

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
        if transferEditAvailable == true then
            local activationOk, activationErr = S.UI:BindDeferredInputActivation(transferEdit, transferEditHost.owner,
                "v3_buff_display_transfer_edit")
            if activationOk ~= true then
                if type(S.UI.RetireInputWidget) == "function" then
                    pcall(function() S.UI:RetireInputWidget(transferEdit, transferEditHost.owner, "multiline_activation_unavailable") end)
                end
                if type(S.UI.SetVisible) == "function" then pcall(function() S.UI:SetVisible(transferEdit, false, transferEditHost.owner) end) end
                transferEditAvailable = false
                if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.WarningRateLimited) == "function" then
                    S.DiagnosticsManager:WarningRateLimited("buff_display_v3", "BUFF_MULTILINE_INPUT_ACTIVATION_UNAVAILABLE", 5000,
                        "状态显示多行输入框无法建立安全键盘激活契约，已禁用以避免吞掉游戏按键",
                        { error = tostring(activationErr or "activation bind failed") })
                end
            end
        end
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
    -- Lifecycle. HUD calibration draft is owned by the standalone overlay, not
    -- by this page; page navigation therefore never commits or replays geometry.
    ------------------------------------------------------------------
    function root:OnActivated()
        local loaded, loadErr = Feature:EnsureStoreLoaded()
        if loaded ~= true then return false, loadErr or "状态显示配置读取失败" end
        persistHint:SetText("配置已读取 · HUD 校准仅在“保存并退出”后写入")
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
        -- 校准器若仍开启，Shell 已被临时最小化，因此正常页面导航不会走到这里；
        -- 即使页面被宿主回收，Detached Draft 仍不会越过 Persistence boundary。
        return true
    end
    function root:RefreshData() return self:Refresh() end
    root.route = route
    return root
end

-- 中文维护注释（页面 Measure 契约）：v1 证明 HUD 布局三卡片把 minHeight 写入组件 spec，
-- 而不是只写父 slot。Foundation/Acceptance 只读该声明来阻止热重载残留 .205 页面继续运行；
-- 不创建额外 UI、不改变 Store Authority。
Feature.HudLayoutPageMeasureContractVersion = 1

local ok, err = PageHost:RegisterFactory(ROUTE, BuildPage)
if ok ~= true then error(err) end

------------------------------------------------------------------------
-- Replicated Suite - Plates / BUFF Combat Workspace (M5 v5)
--
-- Deep RSUI migration for Replicated Plates.
--
-- Authority boundary:
--   * this file does not call X2* APIs;
--   * all reads/writes go through ReplicatedPlates.WorkspacePresenter;
--   * persistent tracking/settings stay in Plates Storage Authority;
--   * live scan/render stays in Plates Runtime/Manager Authority;
--   * legacy UI2 remains available as a safe advanced fallback.
--
-- Performance:
--   * only the active section refreshes on the 1s combat-workspace timer;
--   * tracking TableView is virtualized; large libraries do not allocate one
--     native row per aura;
--   * tracked rows are revision-cached by the presenter;
--   * capture/discovery rows are session-serial cached;
--   * native diagnostic probing happens only after the user clicks Generate.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI = S.RSUI
if type(RSUI) ~= "table" then return end

S.CombatPlatesWorkspace = S.CombatPlatesWorkspace or {}
local WP = S.CombatPlatesWorkspace

local SECTION_ORDER = {
    "overview", "tracking", "alerts", "buffcap", "magiccircle",
    "layout", "lines", "colors", "transfer", "diag",
}
local SECTION_LABEL = {
    overview = "显示总览", tracking = "状态追踪", alerts = "战斗警报",
    buffcap = "BUFF上限", magiccircle = "魔法阵",
    layout = "外观布局", lines = "单位连线", colors = "颜色样式",
    transfer = "导入导出", diag = "诊断",
}
local SCOPE_LABEL = { target = "目标 HUD", player = "自身 HUD" }
local EFFECT_LABEL = { buff = "Buff", debuff = "Debuff", hidden = "Hidden" }
local CATEGORY_LABEL = {
    HARD_CC = "硬控", SOFT_CC = "软控", IMMUNITY = "免控", BREAK = "解控",
    HEAL_REDUCE = "减疗", HEAL = "治疗", DEFENSE = "防御", BURST = "爆发",
    EQUIP = "装备", MOBILITY = "位移", COMBO = "连招", OTHER = "其它",
}

local QUICK_COLORS = {
    { key = "green", name = "绿", value = { r = 0.24, g = 0.82, b = 0.44, a = 0.92 } },
    { key = "red", name = "红", value = { r = 0.96, g = 0.30, b = 0.28, a = 0.92 } },
    { key = "purple", name = "紫", value = { r = 0.72, g = 0.38, b = 0.94, a = 0.92 } },
    { key = "cyan", name = "青", value = { r = 0.24, g = 0.78, b = 0.94, a = 0.92 } },
    { key = "gold", name = "金", value = { r = 0.95, g = 0.72, b = 0.24, a = 0.92 } },
}

local function ExportPlates()
    local sandbox = ReplicatedSuiteModuleSandbox
    local value = sandbox ~= nil and sandbox:GetExport("plates", "ReplicatedPlates") or nil
    if value == nil then value = rawget(_G, "ReplicatedPlates") end
    return value
end

local function Presenter()
    local p = ExportPlates()
    return p and p.WorkspacePresenter or nil
end

local function SafeChat(text)
    if S.SafeChat ~= nil then S.SafeChat(tostring(text or "")) end
end

local function BoolText(value)
    return value == true and "开" or "关"
end

local function ToneForBool(value)
    return value == true and "green" or "muted"
end

local function NowSeconds()
    if S.Utils ~= nil and type(S.Utils.NowMs) == "function" then
        return math.max(0, tonumber(S.Utils.NowMs()) or 0) / 1000
    end
    if type(S.NowMs) == "function" then return math.max(0, tonumber(S.NowMs()) or 0) / 1000 end
    if type(GetTime) == "function" then
        local ok, value = pcall(GetTime)
        if ok then return math.max(0, tonumber(value) or 0) end
    end
    return 0
end

local function CategoryText(value)
    value = tostring(value or "")
    return CATEGORY_LABEL[value] or (value ~= "" and value or "--")
end

local function GetNativeText(widget)
    if widget ~= nil and type(widget.GetText) == "function" then
        local ok, value = pcall(function() return widget:GetText() end)
        if ok then return tostring(value or "") end
    end
    return ""
end

local function SetNativeText(widget, value)
    if widget ~= nil and type(widget.SetText) == "function" then pcall(function() widget:SetText(tostring(value or "")) end) end
end

local function ActionButton(parent, id, text, width, fn, fill)
    return RSUI:Button({
        id = id, parent = parent, text = text, fontSize = 8, compact = true, gradient = true,
        slot = fill == true
            and { size = "fill", fill = 1, minWidth = tonumber(width) or 46, hAlign = "fill" }
            or { size = "fixed", width = tonumber(width) or 68, hAlign = "fill" },
        onClick = fn,
    })
end

local function CreateSelectableRow(prefix, list, poolIndex, tableView, onActivate)
    local row = RSUI:TableRow({
        id = prefix .. "_row_" .. tostring(poolIndex), parent = list,
        columns = tableView.columns, resolvedWidths = tableView.resolvedWidths,
        rowHeight = tableView.rowHeight, columnGap = tableView.columnGap, pickable = true,
    })
    if row ~= nil and row.root ~= nil then
        S.UI:SafeHandler(row.root, "OnClick", function()
            local index = row.itemIndex
            if index ~= nil and type(tableView.SetSelectedIndex) == "function" then tableView:SetSelectedIndex(index) end
            if type(onActivate) == "function" and row.item ~= nil then onActivate(row.item, false) end
            return true
        end, prefix .. ":click:" .. tostring(poolIndex))
        S.UI:SafeHandler(row.root, "OnRButtonUp", function()
            if type(onActivate) == "function" and row.item ~= nil then onActivate(row.item, true) end
            return true
        end, prefix .. ":right:" .. tostring(poolIndex))
    end
    return row
end

local function CreatePage(parent, id, scroll)
    local page = RSUI:Border({ id = id, parent = parent, padding = 4, variant = "soft", gradient = false })
    if page and page.root and page.root.rsBorder and page.root.rsBorder.SetVisible then page.root.rsBorder:SetVisible(false) end
    if page and page.root and page.root.rsBackground and page.root.rsBackground.SetVisible then page.root.rsBackground:SetVisible(false) end
    local stack
    if scroll == true then
        stack = RSUI:ScrollBox({ id = id .. "_scroll", parent = page, orientation = "vertical", gap = 5, scrollStep = 2, padding = 2 })
    else
        stack = RSUI:VerticalBox({ id = id .. "_stack", parent = page, gap = 5 })
    end
    return page, stack
end

local function CreateNativeEditRow(parent, id, maxLength, buttonText, buttonFn, hint)
    local host = RSUI:Border({
        id = id .. "_host", parent = parent, height = 32, padding = 0, variant = "card", gradient = false,
        slot = { size = "fixed", height = 32, hAlign = "fill" },
    })
    local edit, button
    if host and host.root then
        edit = S.UI:CreateEditBox(host.root, id .. "_edit", 4, 4, 250, 24, maxLength or 48)
        button = S.UI:CreateButton(host.root, id .. "_button", buttonText or "应用", 260, 4, 72, 24, 8, false, true)
        if button then
            S.UI:SafeHandler(button, "OnClick", function()
                if type(buttonFn) == "function" then buttonFn(GetNativeText(edit), edit) end
                return true
            end, id .. ":apply")
        end
    end
    if hint ~= nil then
        RSUI:Text({ id = id .. "_hint", parent = parent, text = hint, tone = "muted", fontSize = 8, overflow = "ellipsis",
            slot = { size = "fixed", height = 18, hAlign = "fill" } })
    end
    return edit, button, host
end

local function CreateNativeMultiEdit(parent, id, height, maxLength)
    local host = RSUI:Border({
        id = id .. "_host", parent = parent, height = height or 170, padding = 0, variant = "card", gradient = false,
        slot = { size = "fixed", height = height or 170, hAlign = "fill" },
    })
    local edit
    if host and host.root then edit = S.UI:CreateMultiEditBox(host.root, id .. "_edit", 4, 4, 510, (height or 170) - 8, maxLength or 65535) end
    return edit, host
end

local function CreateNumberRow(parent, id, label, getter, setter, step, minimum, maximum, suffix)
    local row = RSUI:HorizontalBox({
        id = id, parent = parent, gap = 4,
        slot = { size = "fixed", height = 28, hAlign = "fill" },
    })
    local title = RSUI:Text({
        id = id .. "_label", parent = row, text = label, fontSize = 9, overflow = "ellipsis",
        slot = { size = "fill", fill = 1, minWidth = 110, hAlign = "fill", vAlign = "center" },
    })
    local valueText = RSUI:Text({
        id = id .. "_value", parent = row, text = "--", tone = "accent", fontSize = 9, align = ALIGN_CENTER,
        slot = { size = "fixed", width = 72, hAlign = "fill", vAlign = "center" },
    })
    local function Apply(delta)
        local current = tonumber(getter()) or 0
        local nextValue = current + delta
        if minimum ~= nil then nextValue = math.max(minimum, nextValue) end
        if maximum ~= nil then nextValue = math.min(maximum, nextValue) end
        local ok, err = setter(nextValue)
        if ok ~= true and err ~= nil then SafeChat(label .. "设置失败：" .. tostring(err)) end
    end
    local minus = ActionButton(row, id .. "_minus", "-", 34, function() Apply(-(tonumber(step) or 1)); return true end)
    local plus = ActionButton(row, id .. "_plus", "+", 34, function() Apply(tonumber(step) or 1); return true end)
    local control = { row = row, title = title, value = valueText, minus = minus, plus = plus }
    function control:Refresh()
        local value = getter()
        if type(value) == "number" and math.floor(value) ~= value then value = string.format("%.1f", value) end
        self.value:SetText(tostring(value ~= nil and value or "--") .. tostring(suffix or ""))
    end
    return control
end

local function RefreshTableCount(tableView, oldCount, newCount, reason)
    if oldCount ~= newCount then
        if tableView.list and type(tableView.list.InvalidateMeasure) == "function" then tableView.list:InvalidateMeasure(reason or "count") end
        if type(tableView.InvalidateMeasure) == "function" then tableView:InvalidateMeasure(reason or "count") end
    end
end

function WP:Build(workspace, parent)
    local view = {
        section = "overview",
        navButtons = {}, pages = {},
        overviewScope = "target",
        trackScope = "target", trackEffect = "buff", trackSource = "tracked",
        trackRows = {}, trackSignature = nil, selectedTrackId = nil, knownRows = {}, searchQuery = "",
        alertRows = {}, selectedAlertKey = nil,
        layoutScope = "target", layoutEffect = "buff",
        colorScope = "target", colorEffect = "buff", colorField = "borderColor",
        transferMode = "all", transferChunks = {}, transferChunkIndex = 1, transferPolicy = "merge",
        importPreview = nil, diagGenerated = false,
        clearTrackedArmedAt = 0,
    }

    view.component = RSUI:Border({ id = "combat_plates_v5_root", parent = parent, width = 100, height = 100, padding = 4, variant = "soft", gradient = false })
    view.root = view.component and view.component.root or nil
    if view.root == nil then return nil end
    if view.root.rsBorder and view.root.rsBorder.SetVisible then view.root.rsBorder:SetVisible(false) end
    if view.root.rsBackground and view.root.rsBackground.SetVisible then view.root.rsBackground:SetVisible(false) end
    view.stack = RSUI:VerticalBox({ id = "combat_plates_v5_stack", parent = view.component, gap = 5 })

    view.summary = RSUI:Text({
        id = "combat_plates_v5_summary", parent = view.stack, text = "BUFF显示：--", tone = "muted", fontSize = 9, overflow = "ellipsis",
        slot = { size = "fixed", height = 20, hAlign = "fill" },
    })
    view.body = RSUI:HorizontalBox({
        id = "combat_plates_v5_body", parent = view.stack, gap = 6,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })
    view.navCard = RSUI:Border({
        id = "combat_plates_v5_nav", parent = view.body, width = 116, padding = 5, variant = "card", gradient = true,
        slot = { size = "fixed", width = 116, hAlign = "fill", vAlign = "fill" },
    })
    view.navStack = RSUI:VerticalBox({ id = "combat_plates_v5_nav_stack", parent = view.navCard, gap = 3 })
    RSUI:Text({ id = "combat_plates_v5_nav_title", parent = view.navStack, text = "BUFF 工作台", tone = "accent", fontSize = 10,
        slot = { size = "fixed", height = 22, hAlign = "fill" } })
    for _, section in ipairs(SECTION_ORDER) do
        local key = section
        view.navButtons[key] = ActionButton(view.navStack, "combat_plates_v5_nav_" .. key, SECTION_LABEL[key], 104, function()
            view:SetSection(key)
            return true
        end)
    end
    ActionButton(view.navStack, "combat_plates_v5_legacy", "旧高级设置", 104, function()
        workspace:SetMode("settings")
        return true
    end)

    view.switcher = RSUI:WidgetSwitcher({
        id = "combat_plates_v5_switcher", parent = view.body, activeIndex = 1,
        slot = { size = "fill", fill = 1, minWidth = 280, hAlign = "fill", vAlign = "fill" },
    })

    local function RegisterPage(section, scroll)
        local page, stack = CreatePage(view.switcher, "combat_plates_v5_" .. section, scroll)
        view.pages[section] = { page = page, stack = stack }
        return page, stack
    end

    ------------------------------------------------------------------------
    -- Overview / display
    ------------------------------------------------------------------------
    local _, overview = RegisterPage("overview", false)
    view.overviewToolbar = RSUI:HorizontalBox({ id = "combat_plates_v5_overview_toolbar", parent = overview, gap = 4,
        slot = { size = "fixed", height = 28, hAlign = "fill" } })
    view.overviewTarget = ActionButton(view.overviewToolbar, "combat_plates_v5_overview_target", "目标 HUD", 74, function() view.overviewScope = "target"; view:RefreshOverview(true); return true end)
    view.overviewPlayer = ActionButton(view.overviewToolbar, "combat_plates_v5_overview_player", "自身 HUD", 74, function() view.overviewScope = "player"; view:RefreshOverview(true); return true end)
    view.captureToggle = ActionButton(view.overviewToolbar, "combat_plates_v5_capture", "持续检测", 76, function()
        local p = Presenter(); if p then local o = p:GetOverview(); p:SetCaptureEnabled(not (o.capture and o.capture.enabled), view.trackScope, view.trackEffect) end
        view:Refresh(true); return true
    end)
    ActionButton(view.overviewToolbar, "combat_plates_v5_hud_manager", "HUD 管理", 70, function()
        if S.UI and type(S.UI.ShowPage) == "function" then S.UI:ShowPage("hud") end
        return true
    end, true)

    local laneColumns = {
        { id = "scope", title = "HUD", width = 64, minWidth = 54, absoluteMinWidth = 40, field = "scopeText" },
        { id = "effect", title = "类型", width = 58, minWidth = 48, absoluteMinWidth = 38, field = "effectText" },
        { id = "tracked", title = "追踪", width = 52, minWidth = 44, absoluteMinWidth = 34, field = "trackedText", getTone = function(r) return r and r.trackedTone or "muted" end },
        { id = "discovered", title = "发现", width = 52, minWidth = 44, absoluteMinWidth = 34, field = "discoveredText", tone = "muted" },
        { id = "display", title = "显示策略", size = "fill", minWidth = 110, absoluteMinWidth = 68, field = "displayText", getTone = function(r) return r and r.displayTone or "muted" end },
    }
    view.laneRows = {}
    view.laneTable = RSUI:TableView({
        id = "combat_plates_v5_lanes", parent = overview, columns = laneColumns, rowHeight = 23, headerHeight = 22, columnGap = 3,
        items = view.laneRows, overscan = 1, maxPoolSize = 10,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })
    view.displayActions = RSUI:HorizontalBox({ id = "combat_plates_v5_display_actions", parent = overview, gap = 4,
        slot = { size = "fixed", height = 28, hAlign = "fill" } })
    view.displayHud = ActionButton(view.displayActions, "combat_plates_v5_display_hud", "HUD", 66, function() view:ToggleOverviewHud(); return true end)
    view.displayBuff = ActionButton(view.displayActions, "combat_plates_v5_display_buff", "Buff", 58, function() view:TogglePlateField("showBuffs"); return true end)
    view.displayDebuff = ActionButton(view.displayActions, "combat_plates_v5_display_debuff", "Debuff", 62, function() view:TogglePlateField("showDebuffs"); return true end)
    view.displayHidden = ActionButton(view.displayActions, "combat_plates_v5_display_hidden", "Hidden", 62, function() view:TogglePlateField("showHidden"); return true end)
    view.displayFilter = ActionButton(view.displayActions, "combat_plates_v5_display_filter", "筛选", 74, function() view:TogglePlateField("trackedOnly"); return true end)
    view.displayDiscovery = ActionButton(view.displayActions, "combat_plates_v5_display_discovery", "候选发现", 78, function() view:TogglePlateField("autoPvPRelevant"); return true end, true)
    view.displayExtra = RSUI:HorizontalBox({ id = "combat_plates_v5_display_extra", parent = overview, gap = 4,
        slot = { size = "fixed", height = 28, hAlign = "fill" } })
    for i = 1, 4 do view["displayExtra" .. i] = ActionButton(view.displayExtra, "combat_plates_v5_display_extra_" .. i, "--", 86, function() view:ToggleExtra(i); return true end, i == 4) end
    view.displayHint = RSUI:Text({ id = "combat_plates_v5_display_hint", parent = overview,
        text = "Hidden 始终是严格白名单；会话发现只进入候选管理，不会自动加入 HUD。", tone = "muted", fontSize = 8, overflow = "ellipsis",
        slot = { size = "fixed", height = 18, hAlign = "fill" } })

    ------------------------------------------------------------------------
    -- Tracking
    ------------------------------------------------------------------------
    local _, tracking = RegisterPage("tracking", false)
    view.trackToolbar = RSUI:HorizontalBox({ id = "combat_plates_v5_track_toolbar", parent = tracking, gap = 4,
        slot = { size = "fixed", height = 28, hAlign = "fill" } })
    view.trackScopeTarget = ActionButton(view.trackToolbar, "combat_plates_v5_track_target", "目标", 56, function() view.trackScope = "target"; view:RefreshTracking(true); return true end)
    view.trackScopePlayer = ActionButton(view.trackToolbar, "combat_plates_v5_track_player", "自己", 56, function() view.trackScope = "player"; view:RefreshTracking(true); return true end)
    view.trackBuff = ActionButton(view.trackToolbar, "combat_plates_v5_track_buff", "Buff", 52, function() view.trackEffect = "buff"; view:RefreshTracking(true); return true end)
    view.trackDebuff = ActionButton(view.trackToolbar, "combat_plates_v5_track_debuff", "Debuff", 58, function() view.trackEffect = "debuff"; view:RefreshTracking(true); return true end)
    view.trackHidden = ActionButton(view.trackToolbar, "combat_plates_v5_track_hidden", "Hidden", 58, function() view.trackEffect = "hidden"; view:RefreshTracking(true); return true end)
    view.trackSourceButton = ActionButton(view.trackToolbar, "combat_plates_v5_track_source", "来源：已追踪", 92, function() view:CycleTrackSource(); return true end, true)

    view.trackEdit = CreateNativeEditRow(tracking, "combat_plates_v5_track_input", 64, "添加 ID", function(text)
        local p = Presenter(); if not p then return end
        local ok, err = p:AddTracked(view.trackScope, view.trackEffect, text)
        if ok ~= true then SafeChat("追踪添加失败：" .. tostring(err or "未知原因")) else SetNativeText(view.trackEdit, "") end
        view.trackSignature = nil; view:RefreshTracking(true)
    end, "输入数字 ID 可直接加入；搜索状态库使用下面按钮。")
    view.trackSearchRow = RSUI:HorizontalBox({ id = "combat_plates_v5_track_search_row", parent = tracking, gap = 4,
        slot = { size = "fixed", height = 28, hAlign = "fill" } })
    view.trackSearchButton = ActionButton(view.trackSearchRow, "combat_plates_v5_track_search", "搜索状态库", 82, function()
        local p = Presenter(); if not p then return true end
        view.searchQuery = GetNativeText(view.trackEdit)
        view.knownRows = p:SearchKnown(view.searchQuery, view.trackEffect, 50)
        view.trackSource = "known"; view.trackSignature = nil; view:RefreshTracking(true); return true
    end)
    view.captureButton = ActionButton(view.trackSearchRow, "combat_plates_v5_track_capture", "持续检测", 72, function()
        local p = Presenter(); if p then local o = p:GetOverview(); p:SetCaptureEnabled(not (o.capture and o.capture.enabled), view.trackScope, view.trackEffect) end
        view:RefreshTracking(true); return true
    end)
    view.captureSticky = ActionButton(view.trackSearchRow, "combat_plates_v5_track_sticky", "捕获保持", 72, function()
        local p = Presenter(); if p then local o = p:GetOverview(); p:SetCaptureSticky(not (o.capture and o.capture.sticky)) end
        view:RefreshTracking(true); return true
    end)
    view.captureClear = ActionButton(view.trackSearchRow, "combat_plates_v5_track_clear_capture", "清空捕获", 72, function()
        local p = Presenter(); if p then p:ClearCapture(view.trackScope, view.trackEffect, true) end
        view.trackSignature = nil; view:RefreshTracking(true); return true
    end, true)

    local TRACK_FALLBACK_ICON = {
        buff = "ui/icon/icon_skill_buff26.dds",
        debuff = "ui/icon/icon_unknown_item.dds",
        hidden = "ui/icon/icon_skill_buff381.dds",
    }
    local trackColumns = {
        { id = "icon", title = "", width = 30, minWidth = 28, absoluteMinWidth = 26, cellType = "icon", iconSize = 22, resizable = false,
          getIcon = function(row)
              local path = row and tostring(row.iconPath or "") or ""
              if path ~= "" then return path end
              return TRACK_FALLBACK_ICON[view.trackEffect] or "ui/icon/icon_unknown_item.dds"
          end },
        { id = "id", title = "ID", width = 68, minWidth = 54, absoluteMinWidth = 44, field = "id" },
        { id = "name", title = "状态名称", size = "fill", minWidth = 120, absoluteMinWidth = 68, field = "name" },
        { id = "category", title = "分类", width = 68, minWidth = 54, absoluteMinWidth = 42, field = "categoryText" },
        { id = "state", title = "状态", width = 58, minWidth = 48, absoluteMinWidth = 38, field = "stateText", getTone = function(r) return r and r.stateTone or "muted" end },
        { id = "priority", title = "优先", width = 46, minWidth = 40, absoluteMinWidth = 34, field = "priorityText" },
    }
    view.trackTable = RSUI:TableView({
        id = "combat_plates_v5_track_table", parent = tracking, columns = trackColumns, rowHeight = 28, headerHeight = 24, columnGap = 2, cellPaddingX = 4, fontSize = 9,
        getCount = function() return #view.trackRows end, getItem = function(index) return view.trackRows[index] end,
        getKey = function(row, index) return row and row.id or index end,
        selectable = true, selectionMode = "single", overscan = 2, maxPoolSize = 30,
        rowFactory = function(list, poolIndex, tableView)
            return CreateSelectableRow("combat_plates_v5_track", list, poolIndex, tableView, function(row, rightClick)
                if row then view.selectedTrackId = row.id end
                if rightClick and row then view:PrimaryTrackAction(row) end
                view:RefreshTrackSelection()
            end)
        end,
        onSelectionChanged = function(index)
            local row = index and view.trackRows[index] or nil
            view.selectedTrackId = row and row.id or nil
            view:RefreshTrackSelection()
        end,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })
    view.trackSelection = RSUI:Text({ id = "combat_plates_v5_track_selection", parent = tracking, text = "请选择一条状态", tone = "muted", fontSize = 8, overflow = "ellipsis",
        slot = { size = "fixed", height = 18, hAlign = "fill" } })
    view.trackActions = RSUI:HorizontalBox({ id = "combat_plates_v5_track_actions", parent = tracking, gap = 4,
        slot = { size = "fixed", height = 28, hAlign = "fill" } })
    view.trackPrimary = ActionButton(view.trackActions, "combat_plates_v5_track_primary", "启用 / 停用", 80, function() view:PrimaryTrackAction(view:GetSelectedTrackRow()); return true end)
    view.trackPriorityDown = ActionButton(view.trackActions, "combat_plates_v5_track_pri_down", "优先 -", 58, function() view:AdjustSelectedPriority(-1); return true end)
    view.trackPriorityUp = ActionButton(view.trackActions, "combat_plates_v5_track_pri_up", "优先 +", 58, function() view:AdjustSelectedPriority(1); return true end)
    view.trackDuration = ActionButton(view.trackActions, "combat_plates_v5_track_duration", "时间", 52, function() view:ToggleTrackedTri("showDuration"); return true end)
    view.trackStack = ActionButton(view.trackActions, "combat_plates_v5_track_stack", "层数", 52, function() view:ToggleTrackedTri("showStack"); return true end)
    view.trackBorder = ActionButton(view.trackActions, "combat_plates_v5_track_border", "边框", 52, function() view:ToggleTrackedTri("showBorder"); return true end)
    view.trackMore = ActionButton(view.trackActions, "combat_plates_v5_track_more", "高级追踪", 70, function() workspace:SetSection("tracking"); return true end, true)
    view.trackDanger = RSUI:HorizontalBox({ id = "combat_plates_v5_track_danger", parent = tracking, gap = 4,
        slot = { size = "fixed", height = 28, hAlign = "fill" } })
    view.trackRemove = ActionButton(view.trackDanger, "combat_plates_v5_track_remove", "移除选中", 70, function() view:RemoveSelectedTrack(); return true end)
    view.trackForget = ActionButton(view.trackDanger, "combat_plates_v5_track_forget", "忘记候选", 70, function() view:ForgetSelected(); return true end)
    view.trackClearAll = ActionButton(view.trackDanger, "combat_plates_v5_track_clear_all", "清空所有追踪", 84, function() view:ClearAllTracked(); return true end, true)

    ------------------------------------------------------------------------
    -- Alerts
    ------------------------------------------------------------------------
    local _, alerts = RegisterPage("alerts", false)
    view.alertToolbar = RSUI:HorizontalBox({ id = "combat_plates_v5_alert_toolbar", parent = alerts, gap = 4,
        slot = { size = "fixed", height = 28, hAlign = "fill" } })
    view.alertEnabled = ActionButton(view.alertToolbar, "combat_plates_v5_alert_enabled", "战斗警报", 72, function() view:ToggleTop("alerts", { "enabled" }, "UpdateAlerts"); return true end)
    view.alertScope = ActionButton(view.alertToolbar, "combat_plates_v5_alert_scope", "范围", 84, function() local p=Presenter(); if p then p:CycleAlertScope() end; view:RefreshAlerts(true); return true end)
    view.alertStyle = ActionButton(view.alertToolbar, "combat_plates_v5_alert_style", "样式", 88, function() local p=Presenter(); if p then p:CycleAlertStyle() end; view:RefreshAlerts(true); return true end)
    view.alertAnchor = ActionButton(view.alertToolbar, "combat_plates_v5_alert_anchor", "位置", 84, function() local p=Presenter(); if p then p:CycleAlertAnchor() end; view:RefreshAlerts(true); return true end)
    ActionButton(view.alertToolbar, "combat_plates_v5_alert_preview", "预览", 58, function() local p=Presenter(); if p then local ok,e=p:PreviewAlert(); if ok~=true then SafeChat(tostring(e)) end end; return true end)
    ActionButton(view.alertToolbar, "combat_plates_v5_alert_sim", "完整模拟", 72, function() local p=Presenter(); if p then local ok,e=p:SimulateAlert(); if ok~=true then SafeChat("模拟失败："..tostring(e)) end end; return true end, true)
    view.alertScale = CreateNumberRow(alerts, "combat_plates_v5_alert_scale", "警报大小", function() local p=Presenter(); local o=p and p:GetOverview(); return o and o.alerts and o.alerts.scale or 100 end,
        function(v) local p=Presenter(); return p and p:SetTopValue("alerts", { "scale" }, math.floor(v+0.5), "UpdateAlerts") end, 5, 60, 200, "%")
    local alertColumns = {
        { id = "state", title = "状态", width = 56, minWidth = 46, absoluteMinWidth = 38, field = "stateText", getTone = function(r) return r and r.stateTone or "muted" end },
        { id = "alert", title = "警报", width = 100, minWidth = 78, absoluteMinWidth = 56, field = "alert" },
        { id = "kind", title = "类型", width = 58, minWidth = 48, absoluteMinWidth = 38, field = "kindText" },
        { id = "detail", title = "匹配依据", size = "fill", minWidth = 150, absoluteMinWidth = 80, field = "detail", tone = "muted" },
    }
    view.alertTable = RSUI:TableView({
        id = "combat_plates_v5_alert_table", parent = alerts, columns = alertColumns, rowHeight = 24, headerHeight = 22, columnGap = 3,
        getCount = function() return #view.alertRows end, getItem = function(i) return view.alertRows[i] end, getKey = function(r,i) return r and r.key or i end,
        selectable = true, selectionMode = "single", overscan = 1, maxPoolSize = 16,
        rowFactory = function(list, poolIndex, tableView) return CreateSelectableRow("combat_plates_v5_alert", list, poolIndex, tableView, function(row, rightClick)
            if row then view.selectedAlertKey = row.key end
            if rightClick and row then view:ToggleAlertRow(row) end
        end) end,
        onSelectionChanged = function(index) local row=index and view.alertRows[index] or nil; view.selectedAlertKey=row and row.key or nil end,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })
    view.alertFooter = RSUI:HorizontalBox({ id = "combat_plates_v5_alert_footer", parent = alerts, gap = 4,
        slot = { size = "fixed", height = 28, hAlign = "fill" } })
    ActionButton(view.alertFooter, "combat_plates_v5_alert_toggle_selected", "切换选中警报", 92, function() view:ToggleSelectedAlert(); return true end)
    ActionButton(view.alertFooter, "combat_plates_v5_alert_advanced", "自定义警报 / 高级", 112, function() workspace:SetSection("alerts"); return true end, true)

    ------------------------------------------------------------------------
    -- Buff cap
    ------------------------------------------------------------------------
    local _, buffcap = RegisterPage("buffcap", true)
    view.buffcapEnabled = ActionButton(buffcap, "combat_plates_v5_buffcap_enabled", "BUFF上限提醒", 106, function() view:ToggleTop("buffcap", { "enabled" }, "UpdateBuffCap"); return true end)
    view.buffcapControls = {
        CreateNumberRow(buffcap, "combat_plates_v5_buffcap_threshold", "提醒阈值", function() return view:GetTop("buffcap", {"threshold"}, 36) end, function(v) return view:SetTop("buffcap", {"threshold"}, math.floor(v+0.5), "UpdateBuffCap") end, 1, 20, 50),
        CreateNumberRow(buffcap, "combat_plates_v5_buffcap_font", "字号", function() return view:GetTop("buffcap", {"fontSize"}, 12) end, function(v) return view:SetTop("buffcap", {"fontSize"}, math.floor(v+0.5), "UpdateBuffCap") end, 1, 9, 18),
        CreateNumberRow(buffcap, "combat_plates_v5_buffcap_x", "横向偏移", function() return view:GetTop("buffcap", {"offsetX"}, 0) end, function(v) return view:SetTop("buffcap", {"offsetX"}, math.floor(v+0.5), "UpdateBuffCap") end, 10, -400, 400),
        CreateNumberRow(buffcap, "combat_plates_v5_buffcap_y", "纵向偏移", function() return view:GetTop("buffcap", {"offsetY"}, 8) end, function(v) return view:SetTop("buffcap", {"offsetY"}, math.floor(v+0.5), "UpdateBuffCap") end, 10, 0, 400),
    }
    RSUI:Text({ id = "combat_plates_v5_buffcap_hint", parent = buffcap, text = "该提醒读取 Runtime 已有 Buff 计数；修改后仅触发已有 UpdateBuffCap，不新增扫描。", tone = "muted", fontSize = 8,
        slot = { size = "fixed", height = 34, hAlign = "fill" } })

    ------------------------------------------------------------------------
    -- Magic circle
    ------------------------------------------------------------------------
    local _, magic = RegisterPage("magiccircle", true)
    view.magicEnabled = ActionButton(magic, "combat_plates_v5_magic_enabled", "魔法阵距离提醒", 112, function() view:ToggleTop("magiccircle", {"enabled"}, "UpdateMagicCircle"); return true end)
    view.magicControls = {
        CreateNumberRow(magic, "combat_plates_v5_magic_warn", "警告距离", function() return view:GetTop("magiccircle", {"warnM"}, 25) end, function(v) return view:SetTop("magiccircle", {"warnM"}, v, "UpdateMagicCircle") end, 0.5, 10, 40, "m"),
        CreateNumberRow(magic, "combat_plates_v5_magic_max", "最大距离", function() return view:GetTop("magiccircle", {"maxM"}, 29.9) end, function(v) return view:SetTop("magiccircle", {"maxM"}, v, "UpdateMagicCircle") end, 0.5, 15, 45, "m"),
        CreateNumberRow(magic, "combat_plates_v5_magic_font", "字号", function() return view:GetTop("magiccircle", {"fontSize"}, 11) end, function(v) return view:SetTop("magiccircle", {"fontSize"}, math.floor(v+0.5), "UpdateMagicCircle") end, 1, 9, 18),
        CreateNumberRow(magic, "combat_plates_v5_magic_alpha", "透明度", function() return view:GetTop("magiccircle", {"alpha"}, 95) end, function(v) return view:SetTop("magiccircle", {"alpha"}, math.floor(v+0.5), "UpdateMagicCircle") end, 5, 30, 100, "%"),
        CreateNumberRow(magic, "combat_plates_v5_magic_x", "横向偏移", function() return view:GetTop("magiccircle", {"offsetX"}, 200) end, function(v) return view:SetTop("magiccircle", {"offsetX"}, math.floor(v+0.5), "UpdateMagicCircle") end, 2, -200, 200),
        CreateNumberRow(magic, "combat_plates_v5_magic_y", "纵向偏移", function() return view:GetTop("magiccircle", {"offsetY"}, -6) end, function(v) return view:SetTop("magiccircle", {"offsetY"}, math.floor(v+0.5), "UpdateMagicCircle") end, 2, -200, 200),
    }
    view.magicIds = RSUI:Text({ id = "combat_plates_v5_magic_ids", parent = magic, text = "Buff ID：--", tone = "muted", fontSize = 8,
        slot = { size = "fixed", height = 22, hAlign = "fill" } })
    RSUI:Text({ id = "combat_plates_v5_magic_hint", parent = magic, text = "Buff ID 仍以当前经过验证的数据为 Authority；这里只读展示，不在 UI 中猜测/改写。", tone = "muted", fontSize = 8,
        slot = { size = "fixed", height = 34, hAlign = "fill" } })

    ------------------------------------------------------------------------
    -- Layout
    ------------------------------------------------------------------------
    local _, layout = RegisterPage("layout", true)
    view.layoutToolbar = RSUI:HorizontalBox({ id = "combat_plates_v5_layout_toolbar", parent = layout, gap = 4,
        slot = { size = "fixed", height = 28, hAlign = "fill" } })
    view.layoutTarget = ActionButton(view.layoutToolbar, "combat_plates_v5_layout_target", "目标 HUD", 72, function() view.layoutScope="target"; view:RefreshLayout(true); return true end)
    view.layoutPlayer = ActionButton(view.layoutToolbar, "combat_plates_v5_layout_player", "自身 HUD", 72, function() view.layoutScope="player"; view:RefreshLayout(true); return true end)
    view.layoutEffect = ActionButton(view.layoutToolbar, "combat_plates_v5_layout_effect", "区域：Buff", 78, function() view:CycleLayoutEffect(); return true end)
    view.layoutPreview = ActionButton(view.layoutToolbar, "combat_plates_v5_layout_preview", "预览：真实", 78, function() view:TogglePreview(); return true end)
    ActionButton(view.layoutToolbar, "combat_plates_v5_layout_drag_all", "拖动整体", 68, function() local p=Presenter(); if p then p:StartCalibration(view.layoutScope, "overall") end; return true end)
    ActionButton(view.layoutToolbar, "combat_plates_v5_layout_drag_part", "拖动区域", 68, function() local p=Presenter(); if p then p:StartCalibration(view.layoutScope, view.layoutEffect) end; return true end, true)
    view.layoutToggleRow = RSUI:HorizontalBox({ id = "combat_plates_v5_layout_toggles", parent = layout, gap = 4,
        slot = { size = "fixed", height = 28, hAlign = "fill" } })
    view.layoutDuration = ActionButton(view.layoutToggleRow, "combat_plates_v5_layout_duration", "时间", 58, function() view:ToggleEffect("showDuration"); return true end)
    view.layoutStack = ActionButton(view.layoutToggleRow, "combat_plates_v5_layout_stack", "层数", 58, function() view:ToggleEffect("showStack"); return true end)
    view.layoutBorder = ActionButton(view.layoutToggleRow, "combat_plates_v5_layout_border", "边框", 58, function() view:ToggleEffect("showBorder"); return true end)
    view.layoutTooltip = ActionButton(view.layoutToggleRow, "combat_plates_v5_layout_tooltip", "悬浮", 58, function() view:ToggleEffect("showTooltip"); return true end)
    view.layoutExpire = ActionButton(view.layoutToggleRow, "combat_plates_v5_layout_expire", "到期变色", 72, function() view:ToggleEffect("expireEnabled"); return true end)
    view.layoutDirection = ActionButton(view.layoutToggleRow, "combat_plates_v5_layout_direction", "方向：RIGHT", 86, function() local p=Presenter(); if p then p:CycleEffectDirection(view.layoutScope,view.layoutEffect) end; view:RefreshLayout(true); return true end, true)
    view.layoutControls = {
        CreateNumberRow(layout, "combat_plates_v5_layout_width", "HUD 宽度", function() return view:GetPlate({"width"},286) end, function(v) return view:SetPlate({"width"},math.floor(v+0.5)) end, 10, 230, 460),
        CreateNumberRow(layout, "combat_plates_v5_layout_section_gap", "区域间距", function() return view:GetPlate({"sectionGap"},4) end, function(v) return view:SetPlate({"sectionGap"},math.floor(v+0.5)) end, 1, 0, 20),
        CreateNumberRow(layout, "combat_plates_v5_layout_icon", "图标大小", function() return view:GetEffect("iconSize",24) end, function(v) return view:SetEffect("iconSize",math.floor(v+0.5)) end, 1, 18, 42),
        CreateNumberRow(layout, "combat_plates_v5_layout_font", "文字大小", function() return view:GetEffect("fontSize",10) end, function(v) return view:SetEffect("fontSize",math.floor(v+0.5)) end, 1, 8, 18),
        CreateNumberRow(layout, "combat_plates_v5_layout_max", "最大图标数", function() return view:GetEffect("maxCount",8) end, function(v) return view:SetEffect("maxCount",math.floor(v+0.5)) end, 1, 1, 12),
        CreateNumberRow(layout, "combat_plates_v5_layout_cols", "每行列数", function() return view:GetEffect("columns",6) end, function(v) return view:SetEffect("columns",math.floor(v+0.5)) end, 1, 1, 12),
        CreateNumberRow(layout, "combat_plates_v5_layout_gap", "图标间距", function() return view:GetEffect("gap",2) end, function(v) return view:SetEffect("gap",math.floor(v+0.5)) end, 1, 0, 12),
        CreateNumberRow(layout, "combat_plates_v5_layout_rowgap", "行间距", function() return view:GetEffect("rowGap",2) end, function(v) return view:SetEffect("rowGap",math.floor(v+0.5)) end, 1, 0, 12),
        CreateNumberRow(layout, "combat_plates_v5_layout_x", "区域 X 偏移", function() return view:GetEffect("offsetX",0) end, function(v) return view:SetEffect("offsetX",math.floor(v+0.5)) end, 2, -300, 300),
        CreateNumberRow(layout, "combat_plates_v5_layout_y", "区域 Y 偏移", function() return view:GetEffect("offsetY",0) end, function(v) return view:SetEffect("offsetY",math.floor(v+0.5)) end, 2, -300, 300),
        CreateNumberRow(layout, "combat_plates_v5_layout_expire_threshold", "到期阈值", function() return view:GetEffect("expireThreshold",5) end, function(v) return view:SetEffect("expireThreshold",math.floor(v+0.5)) end, 1, 1, 60, "s"),
    }
    view.layoutExtra = RSUI:HorizontalBox({ id = "combat_plates_v5_layout_extra", parent = layout, gap = 4,
        slot = { size = "fixed", height = 28, hAlign = "fill" } })
    view.layoutExtra1 = ActionButton(view.layoutExtra, "combat_plates_v5_layout_extra1", "--", 86, function() view:ToggleLayoutExtra(1); return true end)
    view.layoutExtra2 = ActionButton(view.layoutExtra, "combat_plates_v5_layout_extra2", "--", 86, function() view:ToggleLayoutExtra(2); return true end)
    view.layoutExtra3 = ActionButton(view.layoutExtra, "combat_plates_v5_layout_extra3", "--", 86, function() view:ToggleLayoutExtra(3); return true end)
    ActionButton(view.layoutExtra, "combat_plates_v5_layout_reset_effect", "恢复区域默认", 86, function() local p=Presenter(); if p then p:ResetEffectLayout(view.layoutScope,view.layoutEffect) end; view:RefreshLayout(true); return true end)
    ActionButton(view.layoutExtra, "combat_plates_v5_layout_stop", "结束校准", 70, function() local p=Presenter(); if p then p:StopCalibration() end; return true end)
    ActionButton(view.layoutExtra, "combat_plates_v5_layout_advanced", "高级组件布局", 90, function() workspace:SetSection("layout"); return true end, true)

    ------------------------------------------------------------------------
    -- Lines
    ------------------------------------------------------------------------
    local _, lines = RegisterPage("lines", true)
    view.linesEnabled = ActionButton(lines, "combat_plates_v5_lines_enabled", "单位连线", 86, function() view:ToggleTop("lines", {"enabled"}, "UpdateLines"); return true end)
    view.linePairs = RSUI:HorizontalBox({ id = "combat_plates_v5_line_pairs", parent = lines, gap = 4,
        slot = { size = "fixed", height = 28, hAlign = "fill" } })
    view.lineTarget = ActionButton(view.linePairs, "combat_plates_v5_line_target", "目标", 62, function() view:ToggleTop("lines", {"pairs","target"}, "UpdateLines"); return true end)
    view.lineToT = ActionButton(view.linePairs, "combat_plates_v5_line_tot", "目标的目标", 78, function() view:ToggleTop("lines", {"pairs","targetoftarget"}, "UpdateLines"); return true end)
    view.lineWatch = ActionButton(view.linePairs, "combat_plates_v5_line_watch", "追踪目标", 72, function() view:ToggleTop("lines", {"pairs","watchtarget"}, "UpdateLines"); return true end)
    view.lineWatchTarget = ActionButton(view.linePairs, "combat_plates_v5_line_watch_target", "追踪目标的目标", 94, function() view:ToggleTop("lines", {"pairs","watchtargettarget"}, "UpdateLines"); return true end, true)
    view.lineOrigin = RSUI:HorizontalBox({ id = "combat_plates_v5_line_origin", parent = lines, gap = 4,
        slot = { size = "fixed", height = 28, hAlign = "fill" } })
    view.lineTargetOrigin = ActionButton(view.lineOrigin, "combat_plates_v5_line_target_origin", "目标线起点", 96, function() view:ToggleTop("lines", {"targetFromPlayer"}, "UpdateLines"); return true end)
    view.lineWatchOrigin = ActionButton(view.lineOrigin, "combat_plates_v5_line_watch_origin", "追踪线起点", 96, function() view:ToggleTop("lines", {"watchFromPlayer"}, "UpdateLines"); return true end)
    view.circleEnabled = ActionButton(view.lineOrigin, "combat_plates_v5_circle_enabled", "自身距离圆", 86, function() view:ToggleTop("lines", {"circle","enabled"}, "UpdateLines"); return true end, true)
    view.lineControls = {
        CreateNumberRow(lines, "combat_plates_v5_lines_min", "最小点数", function() return view:GetTop("lines", {"minDots"},8) end, function(v) return view:SetTop("lines", {"minDots"},math.floor(v+0.5),"UpdateLines") end, 1, 4, 128),
        CreateNumberRow(lines, "combat_plates_v5_lines_max", "最大点数", function() return view:GetTop("lines", {"maxDots"},64) end, function(v) return view:SetTop("lines", {"maxDots"},math.floor(v+0.5),"UpdateLines") end, 4, 4, 128),
        CreateNumberRow(lines, "combat_plates_v5_lines_font", "点大小", function() return view:GetTop("lines", {"dotFontSize"},15) end, function(v) return view:SetTop("lines", {"dotFontSize"},math.floor(v+0.5),"UpdateLines") end, 1, 8, 40),
        CreateNumberRow(lines, "combat_plates_v5_lines_alpha", "点透明度", function() return view:GetTop("lines", {"dotAlpha"},100) end, function(v) return view:SetTop("lines", {"dotAlpha"},math.floor(v+0.5),"UpdateLines") end, 5, 20, 100, "%"),
        CreateNumberRow(lines, "combat_plates_v5_lines_update", "连线更新频率", function() return view:GetTop("lines", {"updateMs"},100) end, function(v) return view:SetTop("lines", {"updateMs"},math.floor(v/10+0.5)*10,"UpdateLines") end, 10, 50, 500, "ms"),
        CreateNumberRow(lines, "combat_plates_v5_circle_radius", "距离圆半径", function() return view:GetTop("lines", {"circle","radiusM"},20) end, function(v) return view:SetTop("lines", {"circle","radiusM"},math.floor(v+0.5),"UpdateLines") end, 1, 5, 50, "m"),
        CreateNumberRow(lines, "combat_plates_v5_circle_dots", "距离圆点数", function() return view:GetTop("lines", {"circle","dots"},72) end, function(v) return view:SetTop("lines", {"circle","dots"},math.floor(v/4+0.5)*4,"UpdateLines") end, 4, 24, 128),
    }

    ------------------------------------------------------------------------
    -- Colors
    ------------------------------------------------------------------------
    local _, colors = RegisterPage("colors", true)
    view.colorToolbar = RSUI:HorizontalBox({ id = "combat_plates_v5_color_toolbar", parent = colors, gap = 4,
        slot = { size = "fixed", height = 28, hAlign = "fill" } })
    view.colorScopeButton = ActionButton(view.colorToolbar, "combat_plates_v5_color_scope", "目标 HUD", 76, function() view.colorScope = view.colorScope=="target" and "player" or "target"; view:RefreshColors(true); return true end)
    view.colorEffectButton = ActionButton(view.colorToolbar, "combat_plates_v5_color_effect", "Buff", 62, function() view:CycleColorEffect(); return true end)
    view.colorFieldButton = ActionButton(view.colorToolbar, "combat_plates_v5_color_field", "边框颜色", 78, function() view.colorField = view.colorField=="borderColor" and "expireColor" or "borderColor"; view:RefreshColors(true); return true end)
    ActionButton(view.colorToolbar, "combat_plates_v5_color_advanced", "完整颜色编辑器", 98, function() workspace:SetSection("colors"); return true end, true)
    view.colorHint = RSUI:Text({ id = "combat_plates_v5_color_hint", parent = colors, text = "快速预设作用于当前 HUD / 当前状态类型。单条状态颜色请在追踪页选择后进入高级颜色。", tone = "muted", fontSize = 8,
        slot = { size = "fixed", height = 34, hAlign = "fill" } })
    view.colorPresetRow = RSUI:HorizontalBox({ id = "combat_plates_v5_color_presets", parent = colors, gap = 4,
        slot = { size = "fixed", height = 30, hAlign = "fill" } })
    for _, def in ipairs(QUICK_COLORS) do
        local colorDef = def
        ActionButton(view.colorPresetRow, "combat_plates_v5_color_" .. def.key, def.name, 54, function()
            local p = Presenter(); if p then p:SetEffectColor(view.colorScope,view.colorEffect,view.colorField,colorDef.value) end
            view:RefreshColors(true); return true
        end, def == QUICK_COLORS[#QUICK_COLORS])
    end
    view.colorState = RSUI:Text({ id = "combat_plates_v5_color_state", parent = colors, text = "当前颜色：--", tone = "accent", fontSize = 9,
        slot = { size = "fixed", height = 22, hAlign = "fill" } })
    RSUI:Text({ id = "combat_plates_v5_color_note", parent = colors, text = "颜色修改仍落入 Plates Storage；这里不保存第二份主题状态。", tone = "muted", fontSize = 8,
        slot = { size = "fixed", height = 22, hAlign = "fill" } })

    ------------------------------------------------------------------------
    -- Transfer
    ------------------------------------------------------------------------
    local _, transfer = RegisterPage("transfer", false)
    view.transferToolbar = RSUI:HorizontalBox({ id = "combat_plates_v5_transfer_toolbar", parent = transfer, gap = 4,
        slot = { size = "fixed", height = 28, hAlign = "fill" } })
    view.transferModeButton = ActionButton(view.transferToolbar, "combat_plates_v5_transfer_mode", "模式：全部配置", 100, function() view:CycleTransferMode(); return true end)
    view.transferExport = ActionButton(view.transferToolbar, "combat_plates_v5_transfer_export", "导出", 56, function() view:ExportTransfer(); return true end)
    view.transferParse = ActionButton(view.transferToolbar, "combat_plates_v5_transfer_parse", "解析导入", 72, function() view:PreviewTransfer(); return true end)
    view.transferCommit = ActionButton(view.transferToolbar, "combat_plates_v5_transfer_commit", "确认导入", 72, function() view:CommitTransfer(); return true end)
    view.transferPolicyButton = ActionButton(view.transferToolbar, "combat_plates_v5_transfer_policy", "状态库：合并", 88, function() view.transferPolicy=view.transferPolicy=="merge" and "replace" or "merge"; view:RefreshTransfer(); return true end, true)
    view.transferEdit = CreateNativeMultiEdit(transfer, "combat_plates_v5_transfer", 178, 65535)
    view.transferChunkRow = RSUI:HorizontalBox({ id = "combat_plates_v5_transfer_chunk_row", parent = transfer, gap = 4,
        slot = { size = "fixed", height = 28, hAlign = "fill" } })
    ActionButton(view.transferChunkRow, "combat_plates_v5_transfer_prev", "上一片", 62, function() view:MoveTransferChunk(-1); return true end)
    ActionButton(view.transferChunkRow, "combat_plates_v5_transfer_next", "下一片", 62, function() view:MoveTransferChunk(1); return true end)
    ActionButton(view.transferChunkRow, "combat_plates_v5_transfer_stage_commit", "提交状态库", 78, function() view:CommitAuraStage(); return true end)
    ActionButton(view.transferChunkRow, "combat_plates_v5_transfer_stage_reset", "清空暂存", 70, function() local p=Presenter(); if p then p:ResetAuraImportStage() end; view:RefreshTransfer(); return true end)
    ActionButton(view.transferChunkRow, "combat_plates_v5_transfer_preset", "导入内置实战库", 100, function() view:ImportPreset(); return true end, true)
    view.transferStatus = RSUI:Text({ id = "combat_plates_v5_transfer_status", parent = transfer, text = "导入导出就绪", tone = "muted", fontSize = 8, overflow = "ellipsis",
        slot = { size = "fixed", height = 36, hAlign = "fill" } })
    RSUI:Text({ id = "combat_plates_v5_transfer_hint", parent = transfer, text = "状态库使用 RPPLATESAURA3 分片：逐片粘贴→解析，完整批次通过校验后再提交；普通配置可直接解析/确认。", tone = "muted", fontSize = 8,
        slot = { size = "fixed", height = 36, hAlign = "fill" } })

    ------------------------------------------------------------------------
    -- Diagnostics
    ------------------------------------------------------------------------
    local _, diag = RegisterPage("diag", false)
    view.diagToolbar = RSUI:HorizontalBox({ id = "combat_plates_v5_diag_toolbar", parent = diag, gap = 4,
        slot = { size = "fixed", height = 28, hAlign = "fill" } })
    ActionButton(view.diagToolbar, "combat_plates_v5_diag_generate", "生成完整诊断", 94, function() view:GenerateDiagnostics(); return true end)
    ActionButton(view.diagToolbar, "combat_plates_v5_diag_refresh", "刷新摘要", 72, function() view:RefreshDiagnostics(true); return true end)
    ActionButton(view.diagToolbar, "combat_plates_v5_diag_legacy", "旧诊断窗口", 82, function() workspace:SetSection("diag"); return true end, true)
    view.diagSummary = RSUI:Text({ id = "combat_plates_v5_diag_summary", parent = diag, text = "Runtime：--", tone = "muted", fontSize = 8,
        slot = { size = "fixed", height = 42, hAlign = "fill" } })
    view.diagEdit = CreateNativeMultiEdit(diag, "combat_plates_v5_diag", 210, 65535)
    view.diagHint = RSUI:Text({ id = "combat_plates_v5_diag_hint", parent = diag,
        text = "完整诊断会主动读取 API Capability / 当前单位状态，因此只在点击“生成完整诊断”时执行，不进入刷新循环。", tone = "muted", fontSize = 8,
        slot = { size = "fixed", height = 36, hAlign = "fill" } })

    ------------------------------------------------------------------------
    -- Methods
    ------------------------------------------------------------------------
    function view:SetSection(section)
        if self.pages[section] == nil then section = "overview" end
        self.section = section
        local index = 1
        for i, key in ipairs(SECTION_ORDER) do if key == section then index = i; break end end
        self.switcher:SetActiveIndex(index)
        for _, key in ipairs(SECTION_ORDER) do
            local button = self.navButtons[key]
            if button then button:SetText((key == section and "▶ " or "") .. SECTION_LABEL[key]) end
        end
        self:Refresh(true)
        return true
    end

    function view:GetOverviewData()
        local p = Presenter(); return p and p:GetOverview() or nil
    end

    function view:ToggleOverviewHud()
        local p = Presenter(); local o = p and p:GetOverview(); if not p or not o then return end
        local visible = self.overviewScope == "target" and o.targetHudVisible or o.playerHudVisible
        local ok, err = p:SetHudVisible(self.overviewScope, not visible)
        if ok == false and err then SafeChat("HUD切换失败：" .. tostring(err)) end
        self:RefreshOverview(true)
    end

    function view:TogglePlateField(key)
        local p = Presenter(); if p then local ok,e=p:TogglePlate(self.overviewScope,key); if ok~=true and e then SafeChat(tostring(e)) end end
        self:RefreshOverview(true)
    end

    function view:ToggleExtra(index)
        local key
        if self.overviewScope == "target" then key = ({"showCast","showDistance","showClass","showGear"})[index]
        else key = ({"showEquipment","showImportantCooldowns",nil,nil})[index] end
        if key then self:TogglePlateField(key) end
    end

    function view:RefreshOverview()
        local p = Presenter(); local o = p and p:GetOverview()
        if not o then self.summary:SetText("BUFF显示 Presenter 尚未初始化"); self.summary:SetTone("red"); return false end
        local scopeData = self.overviewScope == "target" and o.target or o.player
        self.overviewTarget:SetText((self.overviewScope=="target" and "[选] " or "").."目标 HUD")
        self.overviewPlayer:SetText((self.overviewScope=="player" and "[选] " or "").."自身 HUD")
        self.captureToggle:SetText("持续检测："..BoolText(o.capture and o.capture.enabled))
        local lanes = p:GetLaneRows() or {}
        local rows = {}
        for _, lane in ipairs(lanes) do
            rows[#rows+1] = {
                scopeText = lane.scope=="target" and "目标" or "自己", effectText = EFFECT_LABEL[lane.effectType] or lane.effectType,
                trackedText = tostring(lane.activeTracked).."/"..tostring(lane.tracked), trackedTone = lane.activeTracked>0 and "green" or "muted",
                discoveredText = tostring(lane.discovered),
                displayText = lane.enabled and (lane.trackedOnly and "仅追踪" or "全部实时状态") or "隐藏",
                displayTone = lane.enabled and "green" or "muted",
            }
        end
        self.laneTable:SetItems(rows, "lanes:"..tostring(o.trackingRevision)..":"..tostring(o.capture and o.capture.serial)..":"..tostring(#rows))
        self.laneRows = rows
        local visible = self.overviewScope=="target" and o.targetHudVisible or o.playerHudVisible
        self.displayHud:SetText("HUD："..BoolText(visible))
        self.displayBuff:SetText("Buff："..BoolText(scopeData.showBuffs))
        self.displayDebuff:SetText("Debuff："..BoolText(scopeData.showDebuffs))
        self.displayHidden:SetText("Hidden："..BoolText(scopeData.showHidden))
        self.displayFilter:SetText(scopeData.trackedOnly and "筛选：仅追踪" or "筛选：全部")
        self.displayDiscovery:SetText("候选发现："..BoolText(scopeData.autoPvPRelevant))
        if self.overviewScope=="target" then
            self.displayExtra1:SetText("施法条："..BoolText(scopeData.showCast)); self.displayExtra1:SetEnabled(true)
            self.displayExtra2:SetText("距离："..BoolText(scopeData.showDistance)); self.displayExtra2:SetEnabled(true)
            self.displayExtra3:SetText("职业："..BoolText(scopeData.showClass)); self.displayExtra3:SetEnabled(true)
            self.displayExtra4:SetText("装等："..BoolText(scopeData.showGear)); self.displayExtra4:SetEnabled(true)
        else
            self.displayExtra1:SetText("装备："..BoolText(scopeData.showEquipment)); self.displayExtra1:SetEnabled(true)
            self.displayExtra2:SetText("重要冷却："..BoolText(scopeData.showImportantCooldowns)); self.displayExtra2:SetEnabled(true)
            self.displayExtra3:SetText("目标专属"); self.displayExtra3:SetEnabled(false)
            self.displayExtra4:SetText("目标专属"); self.displayExtra4:SetEnabled(false)
        end
        local running = o.runtime and o.runtime.running == true
        self.summary:SetTone(running and "green" or "yellow")
        self.summary:SetText("Runtime "..(running and "运行" or "停止").." · 状态库 "..tostring(o.auraCount or 0).." · 目标HUD "..(o.targetHudVisible and "显示" or "隐藏").." · 自身HUD "..(o.playerHudVisible and "显示" or "隐藏").." · 持续检测 "..BoolText(o.capture and o.capture.enabled))
        return true
    end

    function view:CycleTrackSource()
        local order = { tracked="capture", capture="discovered", discovered="known", known="tracked" }
        self.trackSource = order[self.trackSource] or "tracked"
        self.trackSignature = nil; self:RefreshTracking(true)
    end

    function view:GetSelectedTrackRow()
        if self.selectedTrackId == nil then return nil end
        for _, row in ipairs(self.trackRows) do if tostring(row.id)==tostring(self.selectedTrackId) then return row end end
        return nil
    end

    function view:NormalizeTrackRows(rows, source)
        local normalized = {}
        for _, row in ipairs(type(rows)=="table" and rows or {}) do
            local copy = {}
            for k,v in pairs(row) do copy[k]=v end
            copy.categoryText = CategoryText(copy.category)
            copy.effectType = self.trackEffect
            copy.iconPath = tostring(copy.iconPath or "")
            if source == "tracked" then
                copy.stateText = copy.enabled ~= false and "启用" or "停用"; copy.stateTone = copy.enabled ~= false and "green" or "muted"
                copy.priorityText = tostring(copy.priority or 0)
            else
                copy.stateText = copy.tracked == true and "已追踪" or "候选"; copy.stateTone = copy.tracked == true and "green" or "yellow"
                copy.priorityText = "--"
            end
            if tostring(copy.name or "") == "" then copy.name = "ID "..tostring(copy.id or "") end
            normalized[#normalized+1]=copy
        end
        return normalized
    end

    function view:RefreshTracking(force)
        local p = Presenter(); if not p then return false end
        local rows, revision
        if self.trackSource=="tracked" then rows,revision=p:GetTrackedRows(self.trackScope,self.trackEffect)
        elseif self.trackSource=="capture" then rows,revision=p:GetCaptureRows(self.trackScope,self.trackEffect)
        elseif self.trackSource=="discovered" then rows,revision=p:GetDiscoveredRows(self.trackScope,self.trackEffect)
        else rows,revision=self.knownRows,"known:"..tostring(self.searchQuery) end
        local signature = table.concat({self.trackScope,self.trackEffect,self.trackSource,tostring(revision),tostring(p:GetTrackingRevision())},":")
        if force or signature~=self.trackSignature then
            local old=#self.trackRows
            self.trackRows=self:NormalizeTrackRows(rows,self.trackSource)
            self.trackSignature=signature
            RefreshTableCount(self.trackTable,old,#self.trackRows,"plates_tracking_count")
            self.trackTable:RefreshVisible(signature,true)
            if self.selectedTrackId~=nil and self:GetSelectedTrackRow()==nil then self.selectedTrackId=nil end
        end
        local o=p:GetOverview()
        self.trackScopeTarget:SetText((self.trackScope=="target" and "[选] " or "").."目标")
        self.trackScopePlayer:SetText((self.trackScope=="player" and "[选] " or "").."自己")
        self.trackBuff:SetText((self.trackEffect=="buff" and "[选] " or "").."Buff")
        self.trackDebuff:SetText((self.trackEffect=="debuff" and "[选] " or "").."Debuff")
        self.trackHidden:SetText((self.trackEffect=="hidden" and "[选] " or "").."Hidden")
        local sourceLabel={tracked="已追踪",capture="持续捕获",discovered="实战发现",known="状态库"}
        self.trackSourceButton:SetText("来源："..tostring(sourceLabel[self.trackSource] or self.trackSource))
        self.captureButton:SetText("持续检测："..BoolText(o and o.capture and o.capture.enabled))
        self.captureSticky:SetText("捕获保持："..BoolText(o and o.capture and o.capture.sticky))
        self:RefreshTrackSelection()
        return true
    end

    function view:RefreshTrackSelection()
        local row=self:GetSelectedTrackRow()
        if not row then
            self.trackSelection:SetText("请选择一条状态；右键行执行主要操作。")
            for _,b in ipairs({self.trackPrimary,self.trackPriorityDown,self.trackPriorityUp,self.trackDuration,self.trackStack,self.trackBorder,self.trackRemove,self.trackForget}) do if b then b:SetEnabled(false) end end
            return
        end
        self.trackSelection:SetText((EFFECT_LABEL[self.trackEffect] or self.trackEffect).." · ID "..tostring(row.id).." · "..tostring(row.name).." · "..CategoryText(row.category))
        local tracked=self.trackSource=="tracked"
        self.trackPrimary:SetEnabled(true); self.trackPrimary:SetText(tracked and (row.enabled~=false and "停用" or "启用") or (row.tracked and "已追踪" or "加入追踪"))
        self.trackPriorityDown:SetEnabled(tracked);self.trackPriorityUp:SetEnabled(tracked);self.trackDuration:SetEnabled(tracked);self.trackStack:SetEnabled(tracked);self.trackBorder:SetEnabled(tracked)
        self.trackRemove:SetEnabled(tracked)
        self.trackForget:SetEnabled(self.trackSource=="discovered")
        if tracked then
            local function tri(v) if v==nil then return "继承" end return v==true and "开" or "关" end
            self.trackDuration:SetText("时间："..tri(row.showDuration)); self.trackStack:SetText("层数："..tri(row.showStack)); self.trackBorder:SetText("边框："..tri(row.showBorder))
        else
            self.trackDuration:SetText("时间");self.trackStack:SetText("层数");self.trackBorder:SetText("边框")
        end
    end

    function view:PrimaryTrackAction(row)
        row=row or self:GetSelectedTrackRow(); if not row then return end
        local p=Presenter(); if not p then return end
        local ok,err
        if self.trackSource=="tracked" then ok,err=p:UpdateTracked(self.trackScope,self.trackEffect,row.id,{enabled=not(row.enabled~=false)})
        elseif row.tracked~=true then ok,err=p:AddTracked(self.trackScope,self.trackEffect,row.id,row) else ok=true end
        if ok~=true and err then SafeChat("追踪操作失败："..tostring(err)) end
        self.trackSignature=nil;self:RefreshTracking(true)
    end

    function view:AdjustSelectedPriority(delta)
        local row=self:GetSelectedTrackRow();local p=Presenter();if not row or not p or self.trackSource~="tracked" then return end
        local value=math.max(-100,math.min(100,(tonumber(row.priority) or 0)+delta))
        local ok,e=p:UpdateTracked(self.trackScope,self.trackEffect,row.id,{priority=value});if ok~=true and e then SafeChat(tostring(e)) end
        self.trackSignature=nil;self:RefreshTracking(true)
    end

    function view:ToggleTrackedTri(field)
        local row=self:GetSelectedTrackRow();local p=Presenter();if not row or not p or self.trackSource~="tracked" then return end
        local current=row[field];local changes,clear
        if current==nil then changes={[field]=true}
        elseif current==true then changes={[field]=false}
        else clear={field} end
        local ok,e=p:UpdateTracked(self.trackScope,self.trackEffect,row.id,changes,clear);if ok~=true and e then SafeChat(tostring(e)) end
        self.trackSignature=nil;self:RefreshTracking(true)
    end

    function view:RemoveSelectedTrack()
        local row=self:GetSelectedTrackRow();local p=Presenter();if not row or not p or self.trackSource~="tracked" then return end
        local ok,e=p:RemoveTracked(self.trackScope,self.trackEffect,row.id);if ok~=true and e then SafeChat("移除失败："..tostring(e)) end
        self.selectedTrackId=nil;self.trackSignature=nil;self:RefreshTracking(true)
    end

    function view:ForgetSelected()
        local row=self:GetSelectedTrackRow();local p=Presenter();if not row or not p or self.trackSource~="discovered" then return end
        p:ForgetDiscovered(self.trackScope,self.trackEffect,row.id);self.selectedTrackId=nil;self.trackSignature=nil;self:RefreshTracking(true)
    end

    function view:ClearAllTracked()
        local now=NowSeconds()
        if now-(tonumber(self.clearTrackedArmedAt) or 0)>5 then self.clearTrackedArmedAt=now;SafeChat("危险操作：5秒内再次点击“清空所有追踪”确认。") return end
        self.clearTrackedArmedAt=0
        local p=Presenter();if not p then return end
        local ok,count=p:ClearAllTracked();if ok~=true then SafeChat("清空失败："..tostring(count)) else SafeChat("已清空全部 HUD 的追踪状态，共 "..tostring(count or 0).." 条。") end
        self.selectedTrackId=nil;self.trackSignature=nil;self:RefreshTracking(true)
    end

    function view:RefreshAlerts()
        local p=Presenter();if not p then return false end
        local o=p:GetOverview();local cfg=o.alerts or {}
        self.alertEnabled:SetText("战斗警报："..BoolText(cfg.enabled))
        local scopeText=cfg.scope=="target" and "目标" or cfg.scope=="player" and "自己" or "目标+自己"
        self.alertScope:SetText("范围："..scopeText);self.alertStyle:SetText("样式："..((cfg.style=="countdown") and "倒计时" or "大字"));self.alertAnchor:SetText("位置："..((cfg.anchorMode=="center") and "中央" or "顶部"))
        self.alertScale:Refresh()
        local raw=p:GetAlertRows() or {};local old=#self.alertRows;self.alertRows={}
        for _,row in ipairs(raw) do self.alertRows[#self.alertRows+1]={key=row.key,alert=row.alert,kindText=row.kind=="debuff" and "Debuff" or "施法",detail=row.detail,stateText=row.enabled and "启用" or "停用",stateTone=row.enabled and "green" or "muted",enabled=row.enabled} end
        RefreshTableCount(self.alertTable,old,#self.alertRows,"plates_alert_count");self.alertTable:RefreshVisible("alerts:"..tostring(cfg.enabled)..":"..tostring(cfg.scope)..":"..tostring(cfg.style)..":"..tostring(cfg.scale),true)
        return true
    end

    function view:GetSelectedAlertRow() if not self.selectedAlertKey then return nil end;for _,r in ipairs(self.alertRows) do if r.key==self.selectedAlertKey then return r end end end
    function view:ToggleAlertRow(row) row=row or self:GetSelectedAlertRow();local p=Presenter();if row and p then p:SetAlertItem(row.key,not row.enabled);self:RefreshAlerts(true) end end
    function view:ToggleSelectedAlert() self:ToggleAlertRow(self:GetSelectedAlertRow()) end

    function view:GetTop(block,path,fallback)
        local p=Presenter();local o=p and p:GetOverview();local node=o and o[block] or nil
        for _,k in ipairs(path or {}) do if type(node)~="table" then return fallback end;node=node[k] end
        return node==nil and fallback or node
    end
    function view:SetTop(block,path,value,runtimeMethod) local p=Presenter();if not p then return false end;local ok,e=p:SetTopValue(block,path,value,runtimeMethod);if ok~=true and e then SafeChat(tostring(e)) end;self:Refresh(true);return ok,e end
    function view:ToggleTop(block,path,runtimeMethod) local p=Presenter();if p then local ok,e=p:ToggleTop(block,path,runtimeMethod);if ok~=true and e then SafeChat(tostring(e)) end end;self:Refresh(true) end

    function view:RefreshBuffcap()
        local enabled=self:GetTop("buffcap",{"enabled"},true);self.buffcapEnabled:SetText("BUFF上限提醒："..BoolText(enabled));for _,c in ipairs(self.buffcapControls) do c:Refresh() end
    end
    function view:RefreshMagic()
        self.magicEnabled:SetText("魔法阵距离提醒："..BoolText(self:GetTop("magiccircle",{"enabled"},false)));for _,c in ipairs(self.magicControls) do c:Refresh() end
        local ids=self:GetTop("magiccircle",{"buffIds"},{});self.magicIds:SetText("追踪 Buff ID："..table.concat(type(ids)=="table" and ids or {},","))
    end

    function view:GetPlate(path,fallback) local p=Presenter();return p and p:GetPlateValue(self.layoutScope,path,fallback) or fallback end
    function view:SetPlate(path,value) local p=Presenter();local ok,e=p and p:SetPlateValue(self.layoutScope,path,value);if ok~=true and e then SafeChat(tostring(e)) end;self:RefreshLayout(true);return ok,e end
    function view:GetEffect(key,fallback) return self:GetPlate({"effects",self.layoutEffect,key},fallback) end
    function view:SetEffect(key,value) local p=Presenter();local ok,e=p and p:SetEffectValue(self.layoutScope,self.layoutEffect,key,value);if ok~=true and e then SafeChat(tostring(e)) end;self:RefreshLayout(true);return ok,e end
    function view:ToggleEffect(key) self:SetEffect(key,not(self:GetEffect(key,false)==true)) end
    function view:CycleLayoutEffect() self.layoutEffect=self.layoutEffect=="buff" and "debuff" or self.layoutEffect=="debuff" and "hidden" or "buff";self:RefreshLayout(true) end
    function view:TogglePreview() local p=Presenter();if not p then return end;local plates=ExportPlates();local mode=plates and plates.UI and plates.UI.GetPreviewMode and plates.UI:GetPreviewMode(self.layoutScope) or "real";p:SetPreviewMode(self.layoutScope,mode=="mock" and "real" or "mock");self:RefreshLayout(true) end
    function view:ToggleLayoutExtra(index)
        local key=self.layoutScope=="target" and ({"showCast","showDistance","showClass"})[index] or ({"showEquipment","showImportantCooldowns",nil})[index]
        if key then local p=Presenter();if p then p:TogglePlate(self.layoutScope,key) end;self:RefreshLayout(true) end
    end
    function view:RefreshLayout()
        self.layoutTarget:SetText((self.layoutScope=="target" and "[选] " or "").."目标 HUD");self.layoutPlayer:SetText((self.layoutScope=="player" and "[选] " or "").."自身 HUD");self.layoutEffect:SetText("区域："..(EFFECT_LABEL[self.layoutEffect] or self.layoutEffect))
        local plates=ExportPlates();local mode=plates and plates.UI and plates.UI.GetPreviewMode and plates.UI:GetPreviewMode(self.layoutScope) or "real";self.layoutPreview:SetText("预览："..(mode=="mock" and "模拟" or "真实"))
        local function toggleText(button,label,key) button:SetText(label.."："..BoolText(self:GetEffect(key,false))) end
        toggleText(self.layoutDuration,"时间","showDuration");toggleText(self.layoutStack,"层数","showStack");toggleText(self.layoutBorder,"边框","showBorder");toggleText(self.layoutTooltip,"悬浮","showTooltip");toggleText(self.layoutExpire,"到期","expireEnabled")
        self.layoutDirection:SetText("方向："..tostring(self:GetEffect("direction","RIGHT")))
        for _,c in ipairs(self.layoutControls) do c:Refresh() end
        if self.layoutScope=="target" then
            self.layoutExtra1:SetText("施法条："..BoolText(self:GetPlate({"showCast"},true)));self.layoutExtra1:SetEnabled(true)
            self.layoutExtra2:SetText("距离："..BoolText(self:GetPlate({"showDistance"},true)));self.layoutExtra2:SetEnabled(true)
            self.layoutExtra3:SetText("职业："..BoolText(self:GetPlate({"showClass"},true)));self.layoutExtra3:SetEnabled(true)
        else
            self.layoutExtra1:SetText("装备："..BoolText(self:GetPlate({"showEquipment"},false)));self.layoutExtra1:SetEnabled(true)
            self.layoutExtra2:SetText("冷却："..BoolText(self:GetPlate({"showImportantCooldowns"},true)));self.layoutExtra2:SetEnabled(true)
            self.layoutExtra3:SetText("目标专属");self.layoutExtra3:SetEnabled(false)
        end
    end

    function view:RefreshLines()
        local enabled=self:GetTop("lines",{"enabled"},false);self.linesEnabled:SetText("单位连线："..BoolText(enabled))
        local function pair(button,label,key) button:SetText(label.."："..BoolText(self:GetTop("lines",{"pairs",key},false))) end
        pair(self.lineTarget,"目标","target");pair(self.lineToT,"目标的目标","targetoftarget");pair(self.lineWatch,"追踪目标","watchtarget");pair(self.lineWatchTarget,"追踪目标的目标","watchtargettarget")
        self.lineTargetOrigin:SetText("目标线起点："..(self:GetTop("lines",{"targetFromPlayer"},false) and "玩家" or "目标"));self.lineWatchOrigin:SetText("追踪线起点："..(self:GetTop("lines",{"watchFromPlayer"},false) and "玩家" or "追踪目标"));self.circleEnabled:SetText("距离圆："..BoolText(self:GetTop("lines",{"circle","enabled"},false)))
        for _,c in ipairs(self.lineControls) do c:Refresh() end
    end

    function view:CycleColorEffect() self.colorEffect=self.colorEffect=="buff" and "debuff" or self.colorEffect=="debuff" and "hidden" or "buff";self:RefreshColors(true) end
    function view:RefreshColors()
        self.colorScopeButton:SetText(SCOPE_LABEL[self.colorScope] or self.colorScope);self.colorEffectButton:SetText(EFFECT_LABEL[self.colorEffect] or self.colorEffect);self.colorFieldButton:SetText(self.colorField=="borderColor" and "边框颜色" or "到期颜色")
        local p=Presenter();local c=p and p:GetPlateValue(self.colorScope,{"effects",self.colorEffect,self.colorField},{}) or {};self.colorState:SetText(string.format("当前：R %.2f  G %.2f  B %.2f  A %.2f",tonumber(c.r or c[1]) or 0,tonumber(c.g or c[2]) or 0,tonumber(c.b or c[3]) or 0,tonumber(c.a or c[4]) or 0))
    end

    function view:CycleTransferMode()
        local order={all="tracking",tracking="layout",layout="rule",rule="library",library="all"};self.transferMode=order[self.transferMode] or "all";self.transferChunks={};self.transferChunkIndex=1;self.importPreview=nil;self:RefreshTransfer()
    end
    function view:RefreshTransfer()
        local labels={all="全部配置",tracking="追踪规则",layout="布局",rule="选中规则",library="状态库分片"};self.transferModeButton:SetText("模式："..tostring(labels[self.transferMode] or self.transferMode));self.transferPolicyButton:SetText("状态库："..(self.transferPolicy=="replace" and "替换" or "合并"))
        local p=Presenter();local stage=p and p:GetAuraImportStageInfo() or nil
        local chunkText=#self.transferChunks>0 and (" · 导出片 "..tostring(self.transferChunkIndex).."/"..tostring(#self.transferChunks)) or ""
        local stageText=type(stage)=="table" and (" · 导入暂存 "..tostring(stage.received or stage.count or 0).."/"..tostring(stage.total or stage.expected or "?") ) or ""
        self.transferStatus:SetText("当前模式："..tostring(labels[self.transferMode] or self.transferMode)..chunkText..stageText..(self.importPreview and (" · 已解析："..tostring(self.importPreview)) or ""))
    end
    function view:ExportTransfer()
        local p=Presenter();if not p then return end
        local result,e,info=p:Export(self.transferMode,self.trackScope,self.trackEffect,self.selectedTrackId)
        if self.transferMode=="library" and type(result)=="table" then self.transferChunks=result;self.transferChunkIndex=1;SetNativeText(self.transferEdit,result[1] or "");self.importPreview="导出状态库 "..tostring(#result).." 片"
        elseif result~=nil then self.transferChunks={};SetNativeText(self.transferEdit,result);self.importPreview="已导出"
        else SafeChat("导出失败："..tostring(e or "未知原因")) end
        self:RefreshTransfer()
    end
    function view:MoveTransferChunk(delta) if #self.transferChunks<=0 then return end;self.transferChunkIndex=math.max(1,math.min(#self.transferChunks,self.transferChunkIndex+delta));SetNativeText(self.transferEdit,self.transferChunks[self.transferChunkIndex] or "");self:RefreshTransfer() end
    function view:PreviewTransfer()
        local p=Presenter();if not p then return end;local text=GetNativeText(self.transferEdit);local ok,e,info=p:PreviewImport(text)
        if ok==true then self.importPreview=type(info)=="table" and (info.label or info.kind or "解析成功") or "解析成功" else self.importPreview=nil;SafeChat("导入解析失败："..tostring(e or info or "未知原因")) end;self:RefreshTransfer()
    end
    function view:CommitTransfer()
        local p=Presenter();if not p then return end;local ok,e,info=p:CommitImport(GetNativeText(self.transferEdit));if ok==true then SafeChat("BUFF显示配置导入完成。") else SafeChat("导入失败："..tostring(e or info or "未知原因")) end;self.importPreview=nil;self:RefreshTransfer();self:Refresh(true)
    end
    function view:CommitAuraStage() local p=Presenter();if not p then return end;local ok,e=p:CommitAuraImport(self.transferPolicy);if ok==true then SafeChat("状态库导入提交完成。") else SafeChat("状态库提交失败："..tostring(e or "未知原因")) end;self:RefreshTransfer();self:Refresh(true) end
    function view:ImportPreset() local p=Presenter();if not p then return end;local ok,e=p:ImportCorePreset();if ok==true then SafeChat("内置实战状态库已导入。") else SafeChat("实战库导入失败："..tostring(e or "未知原因")) end;self.trackSignature=nil;self:Refresh(true) end

    function view:RefreshDiagnostics()
        local p=Presenter();local d=p and p:GetDiagnosticsSnapshot();if not d then self.diagSummary:SetText("诊断 Presenter 不可用");self.diagSummary:SetTone("red");return end
        self.diagSummary:SetTone(d.running and "green" or "yellow");self.diagSummary:SetText("Runtime "..(d.running and "运行" or "停止").." · Heartbeat "..tostring(d.heartbeat).." · 成功更新 "..tostring(d.successfulUpdates).." · FrameBudget "..tostring(d.budgetGranted).."/"..tostring(d.budgetRequests).." · Deferred "..tostring(d.budgetDeferred).." · 可见状态 "..tostring(d.effectVisible).." / Peak "..tostring(d.effectPeak))
    end
    function view:GenerateDiagnostics() local p=Presenter();if not p then return end;local report,e=p:BuildDiagnostics();if report then SetNativeText(self.diagEdit,report);self.diagGenerated=true;SafeChat("BUFF显示：完整诊断已生成，可 Ctrl+A / Ctrl+C 复制。") else SafeChat("诊断生成失败："..tostring(e)) end;self:RefreshDiagnostics(true) end

    function view:Refresh(force)
        local p=Presenter();if not p then self.summary:SetText("BUFF显示 Workspace Presenter 未就绪");self.summary:SetTone("red");return false end
        if self.section=="overview" then self:RefreshOverview(force)
        elseif self.section=="tracking" then self:RefreshTracking(force)
        elseif self.section=="alerts" then self:RefreshAlerts(force)
        elseif self.section=="buffcap" then self:RefreshOverview(false);self:RefreshBuffcap()
        elseif self.section=="magiccircle" then self:RefreshOverview(false);self:RefreshMagic()
        elseif self.section=="layout" then self:RefreshOverview(false);self:RefreshLayout(force)
        elseif self.section=="lines" then self:RefreshOverview(false);self:RefreshLines()
        elseif self.section=="colors" then self:RefreshOverview(false);self:RefreshColors(force)
        elseif self.section=="transfer" then self:RefreshOverview(false);self:RefreshTransfer()
        elseif self.section=="diag" then self:RefreshOverview(false);self:RefreshDiagnostics(force) end
        return true
    end

    view:SetSection("overview")
    return view
end

------------------------------------------------------------------------
-- Replicated Suite - Gear Combat Workspace (M5 v4)
--
-- Deep RSUI migration for Replicated Gear.
--
-- Authority / performance boundary:
--   * periodic Refresh() reads only Gear WorkspacePresenter snapshots;
--   * equipment/title capture and validation are explicit button actions only;
--   * persistence stays in Gear Core; swap execution stays in Gear Runtime;
--   * 19 equipment slots use one bounded TileView pool (no per-frame rebuild);
--   * no X2 API is called directly from this UI file.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI = S.RSUI
if type(RSUI) ~= "table" then return end

S.CombatGearWorkspace = S.CombatGearWorkspace or {}
local WG = S.CombatGearWorkspace

local function ExportGear()
    local sandbox = ReplicatedSuiteModuleSandbox
    local value = sandbox ~= nil and sandbox:GetExport("gear", "ReplicatedGear") or nil
    if value == nil then value = rawget(_G, "ReplicatedGear") end
    return value
end

local function Presenter()
    local g = ExportGear()
    return g and g.WorkspacePresenter or nil
end

local function SafeChat(text)
    if S.SafeChat ~= nil then S.SafeChat(tostring(text or "")) end
end

local function NowMs()
    return S.NowMs ~= nil and S.NowMs() or 0
end

local function ActionButton(parent, id, text, width, fn, fill)
    return RSUI:Button({
        id = id, parent = parent, text = text, fontSize = 8, compact = true, gradient = true,
        slot = fill == true
            and { size = "fill", fill = 1, minWidth = tonumber(width) or 48, hAlign = "fill" }
            or { size = "fixed", width = tonumber(width) or 68, hAlign = "fill" },
        onClick = fn,
    })
end

local function SetNativeEnabled(widget, enabled)
    if widget == nil then return end
    if type(widget.Enable) == "function" then pcall(function() widget:Enable(enabled == true) end) end
end

local function SetNativeText(widget, text)
    if widget ~= nil and type(widget.SetText) == "function" then pcall(function() widget:SetText(tostring(text or "")) end) end
end

local function GetNativeText(widget)
    if widget == nil or type(widget.GetText) ~= "function" then return "" end
    local ok, value = pcall(function() return widget:GetText() end)
    return ok and tostring(value or "") or ""
end

local function Trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$") or ""
end

local function BuildSetSignature(rows, revision)
    local parts = { tostring(revision or 0) }
    for _, row in ipairs(rows or {}) do
        parts[#parts + 1] = table.concat({
            tostring(row.id), tostring(row.name), tostring(row.configured), tostring(row.quick),
            tostring(row.managedCount), tostring(row.titleManaged), tostring(row.payloadRevision),
        }, ":")
    end
    return table.concat(parts, "|")
end

local function CreateSetRow(prefix, list, poolIndex, tableView, view)
    local row = RSUI:TableRow({
        id = prefix .. "_row_" .. tostring(poolIndex), parent = list,
        columns = tableView.columns, resolvedWidths = tableView.resolvedWidths,
        rowHeight = tableView.rowHeight, columnGap = tableView.columnGap, pickable = true,
    })
    if row ~= nil and row.root ~= nil then
        S.UI:SafeHandler(row.root, "OnClick", function()
            if row.item == nil then return true end
            if view:RequestSelect(row.item.id) == true then
                local index = row.itemIndex
                if index ~= nil and type(tableView.SetSelectedIndex) == "function" then tableView:SetSelectedIndex(index) end
            end
            return true
        end, prefix .. ":click:" .. tostring(poolIndex))
        S.UI:SafeHandler(row.root, "OnRButtonUp", function()
            if row.item ~= nil and row.item.configuredRaw == true then
                if view:RequestSelect(row.item.id, true) == true then view:StartSelected() end
            end
            return true
        end, prefix .. ":right:" .. tostring(poolIndex))
    end
    return row
end

local function PhaseLabel(stage)
    local map = {
        IDLE = "空闲", ACTION = "更换装备", VERIFY = "验证装备",
        FINAL_VERIFY = "整套验证", TITLE_VERIFY = "切换称号",
        WEAPON_PASS_VERIFY = "武器对账", WEAPON_RETRY = "武器重试",
    }
    return map[tostring(stage or "IDLE")] or tostring(stage or "--")
end

function WG:Build(workspace, parent)
    local view = {
        selectedId = nil,
        draft = nil,
        draftDirty = false,
        draftGeneration = 0,
        listRows = {},
        listRevision = -1,
        listSignature = "",
        selectArmId = nil,
        selectArmAt = 0,
        deleteArmId = nil,
        deleteArmAt = 0,
        subview = "editor",
        slotRows = {},
        validation = nil,
        validationRows = {},
        runtimeSignature = "",
    }

    view.component = RSUI:Border({
        id = "combat_gear_v4_root", parent = parent,
        width = 100, height = 100, padding = 6, variant = "soft", gradient = false,
    })
    view.root = view.component and view.component.root or nil
    if view.root == nil then return nil end
    if view.root.rsBorder and view.root.rsBorder.SetVisible then view.root.rsBorder:SetVisible(false) end
    if view.root.rsBackground and view.root.rsBackground.SetVisible then view.root.rsBackground:SetVisible(false) end
    view.stack = RSUI:VerticalBox({ id = "combat_gear_v4_stack", parent = view.component, gap = 5 })

    ------------------------------------------------------------------------
    -- Global toolbar / status.
    ------------------------------------------------------------------------
    view.toolbar = RSUI:HorizontalBox({
        id = "combat_gear_v4_toolbar", parent = view.stack, gap = 4,
        slot = { size = "fixed", height = 28, hAlign = "fill" },
    })
    view.tabEditor = ActionButton(view.toolbar, "combat_gear_v4_tab_editor", "方案编辑", 72, function() view:SetSubview("editor"); return true end)
    view.tabRuntime = ActionButton(view.toolbar, "combat_gear_v4_tab_runtime", "执行 / 诊断", 82, function() view:SetSubview("runtime"); return true end)
    view.swapTop = ActionButton(view.toolbar, "combat_gear_v4_swap_top", "立即换装", 74, function() view:StartSelected(); return true end)
    view.quickHud = ActionButton(view.toolbar, "combat_gear_v4_quick_hud", "快捷HUD", 68, function()
        if S.HudManager and S.HudManager:Get("gear_quick") then S.HudManager:ToggleVisible("gear_quick") end
        return true
    end)
    view.hudManager = ActionButton(view.toolbar, "combat_gear_v4_hud_manager", "HUD管理", 68, function()
        if S.UI and type(S.UI.ShowPage) == "function" then S.UI:ShowPage("hud") end
        return true
    end)
    view.settings = ActionButton(view.toolbar, "combat_gear_v4_settings", "高级设置", 68, function()
        workspace:SetMode("settings")
        return true
    end, true)

    view.summary = RSUI:Text({
        id = "combat_gear_v4_summary", parent = view.stack,
        text = "一键换装：--", tone = "muted", fontSize = 9, overflow = "ellipsis",
        slot = { size = "fixed", height = 20, hAlign = "fill" },
    })

    ------------------------------------------------------------------------
    -- Body: fixed scheme browser + right workspace.
    ------------------------------------------------------------------------
    view.body = RSUI:HorizontalBox({
        id = "combat_gear_v4_body", parent = view.stack, gap = 6,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })

    view.leftCard = RSUI:Border({
        id = "combat_gear_v4_left", parent = view.body, padding = 6, variant = "card", gradient = true,
        slot = { size = "fixed", width = 238, hAlign = "fill", vAlign = "fill" },
    })
    view.leftStack = RSUI:VerticalBox({ id = "combat_gear_v4_left_stack", parent = view.leftCard, gap = 5 })
    view.leftTitle = RSUI:Text({
        id = "combat_gear_v4_left_title", parent = view.leftStack,
        text = "换装方案", tone = "accent", fontSize = 11, overflow = "ellipsis",
        slot = { size = "fixed", height = 22, hAlign = "fill" },
    })

    -- Small local composite: RSUI has no string-input standard type by design,
    -- so keep one native EditBox in this business composite instead of adding a
    -- 48th Foundation widget type.
    view.createHost = RSUI:Border({
        id = "combat_gear_v4_create_host", parent = view.leftStack,
        height = 30, padding = 0, variant = "soft", gradient = false,
        slot = { size = "fixed", height = 30, hAlign = "fill" },
    })
    if view.createHost and view.createHost.root then
        view.newNameEdit = S.UI:CreateEditBox(view.createHost.root, "combat_gear_v4_new_name", 0, 3, 164, 24, 36)
        view.newButton = S.UI:CreateButton(view.createHost.root, "combat_gear_v4_new_button", "新建", 168, 3, 54, 24, 8, false, true)
        if view.newButton then
            S.UI:SafeHandler(view.newButton, "OnClick", function()
                view:CreateSet(GetNativeText(view.newNameEdit))
                return true
            end, "gear_v4:new")
        end
    end

    local setColumns = {
        { id = "order", title = "#", width = 28, minWidth = 24, absoluteMinWidth = 22, field = "order" },
        { id = "name", title = "方案", size = "fill", minWidth = 86, absoluteMinWidth = 56, field = "name" },
        { id = "state", title = "状态", width = 58, minWidth = 48, absoluteMinWidth = 42, field = "state", getTone = function(row) return row and row.stateTone or "muted" end },
    }
    view.setTable = RSUI:TableView({
        id = "combat_gear_v4_sets", parent = view.leftStack,
        columns = setColumns, rowHeight = 24, headerHeight = 22, columnGap = 2,
        getCount = function() return #view.listRows end,
        getItem = function(index) return view.listRows[index] end,
        getKey = function(row, index) return row and row.id or index end,
        selectable = true, selectionMode = "single", overscan = 2, maxPoolSize = 28,
        rowFactory = function(list, poolIndex, tableView) return CreateSetRow("combat_gear_v4_sets", list, poolIndex, tableView, view) end,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })
    view.leftHint = RSUI:Text({
        id = "combat_gear_v4_left_hint", parent = view.leftStack,
        text = "右键已配置方案可立即切换", tone = "muted", fontSize = 8, overflow = "ellipsis",
        slot = { size = "fixed", height = 18, hAlign = "fill" },
    })

    view.rightCard = RSUI:Border({
        id = "combat_gear_v4_right", parent = view.body, padding = 6, variant = "card", gradient = true,
        slot = { size = "fill", fill = 1, minWidth = 320, hAlign = "fill", vAlign = "fill" },
    })
    view.rightStack = RSUI:VerticalBox({ id = "combat_gear_v4_right_stack", parent = view.rightCard, gap = 5 })
    view.rightTitle = RSUI:Text({
        id = "combat_gear_v4_right_title", parent = view.rightStack,
        text = "当前方案：--", tone = "accent", fontSize = 11, overflow = "ellipsis",
        slot = { size = "fixed", height = 22, hAlign = "fill" },
    })
    view.switcher = RSUI:WidgetSwitcher({
        id = "combat_gear_v4_switcher", parent = view.rightStack, activeIndex = 1,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })

    ------------------------------------------------------------------------
    -- Editor pane.
    ------------------------------------------------------------------------
    view.editorPage = RSUI:Border({ id = "combat_gear_v4_editor", parent = view.switcher, padding = 0, variant = "soft", gradient = false })
    view.editorStack = RSUI:VerticalBox({ id = "combat_gear_v4_editor_stack", parent = view.editorPage, gap = 5 })

    view.editNameHost = RSUI:Border({
        id = "combat_gear_v4_name_host", parent = view.editorStack,
        height = 30, padding = 0, variant = "soft", gradient = false,
        slot = { size = "fixed", height = 30, hAlign = "fill" },
    })
    if view.editNameHost and view.editNameHost.root then
        view.nameEdit = S.UI:CreateEditBox(view.editNameHost.root, "combat_gear_v4_name_edit", 0, 3, 240, 24, 36)
        view.renameButton = S.UI:CreateButton(view.editNameHost.root, "combat_gear_v4_name_save", "保存名称", 246, 3, 72, 24, 8, false, true)
        if view.renameButton then
            S.UI:SafeHandler(view.renameButton, "OnClick", function()
                view:SaveNameOnly()
                return true
            end, "gear_v4:rename")
        end
    end

    view.editActions = RSUI:HorizontalBox({
        id = "combat_gear_v4_edit_actions", parent = view.editorStack, gap = 4,
        slot = { size = "fixed", height = 28, hAlign = "fill" },
    })
    view.captureButton = ActionButton(view.editActions, "combat_gear_v4_capture", "获取当前配置", 88, function() view:CaptureCurrent(); return true end)
    view.saveButton = ActionButton(view.editActions, "combat_gear_v4_save", "保存更改", 76, function() view:SaveDraft(); return true end)
    view.discardButton = ActionButton(view.editActions, "combat_gear_v4_discard", "撤销", 54, function() view:ReloadDraft(true); return true end)
    view.quickToggle = ActionButton(view.editActions, "combat_gear_v4_quick_toggle", "快捷按钮", 72, function() view:ToggleQuick(); return true end)
    view.moveUp = ActionButton(view.editActions, "combat_gear_v4_move_up", "上移", 48, function() view:MoveSelected(-1); return true end)
    view.moveDown = ActionButton(view.editActions, "combat_gear_v4_move_down", "下移", 48, function() view:MoveSelected(1); return true end)
    view.deleteButton = ActionButton(view.editActions, "combat_gear_v4_delete", "删除", 48, function() view:DeleteSelected(); return true end, true)

    view.editState = RSUI:Text({
        id = "combat_gear_v4_edit_state", parent = view.editorStack,
        text = "请选择一个方案", tone = "muted", fontSize = 8, overflow = "ellipsis",
        slot = { size = "fixed", height = 18, hAlign = "fill" },
    })

    view.presets = RSUI:HorizontalBox({
        id = "combat_gear_v4_presets", parent = view.editorStack, gap = 4,
        slot = { size = "fixed", height = 28, hAlign = "fill" },
    })
    ActionButton(view.presets, "combat_gear_v4_preset_all", "全部装备", 68, function() view:ApplyPreset("ALL"); return true end)
    ActionButton(view.presets, "combat_gear_v4_preset_weapon", "仅武器", 62, function() view:ApplyPreset("WEAPON"); return true end)
    ActionButton(view.presets, "combat_gear_v4_preset_armor", "防具 / 饰品", 78, function() view:ApplyPreset("ARMOR"); return true end)
    ActionButton(view.presets, "combat_gear_v4_preset_title", "仅称号", 62, function() view:ApplyPreset("TITLE"); return true end)
    ActionButton(view.presets, "combat_gear_v4_preset_none", "清空参与", 68, function() view:ApplyPreset("NONE"); return true end, true)

    local tileView
    tileView = RSUI:TileView({
        id = "combat_gear_v4_slots", parent = view.editorStack,
        minTileWidth = 118, tileWidth = 138, maxTileWidth = 190, tileHeight = 48,
        gap = 4, desiredColumns = 4, maxColumns = 5, overscanRows = 1, maxPoolSize = 24,
        getCount = function() return #view.slotRows end,
        getItem = function(index) return view.slotRows[index] end,
        getKey = function(row, index) return row and tostring(row.slot) or tostring(index) end,
        tileFactory = function(_, poolIndex)
            return RSUI:Button({
                id = "combat_gear_v4_slot_tile_" .. tostring(poolIndex),
                parent = tileView, text = "", fontSize = 8, compact = true, gradient = true,
                width = 138, height = 48,
                onClick = function(button)
                    local index = button.state and button.state.tileIndex or nil
                    local row = index and view.slotRows[index] or nil
                    if row ~= nil then view:ToggleManaged(row.slot) end
                    return true
                end,
            })
        end,
        bindTile = function(tile, row)
            if tile == nil then return end
            if row == nil then tile:SetText(""); tile:SetEnabled(false); return end
            local prefix = row.empty and "— " or (row.managed and "√ " or "○ ")
            local text = prefix .. tostring(row.slotName or "装备") .. "\n" .. tostring(row.displayName or "未读取")
            tile:SetText(text)
            tile:SetEnabled(row.toggleable == true)
        end,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })
    view.slotView = tileView

    view.titleRow = RSUI:HorizontalBox({
        id = "combat_gear_v4_title_row", parent = view.editorStack, gap = 4,
        slot = { size = "fixed", height = 28, hAlign = "fill" },
    })
    view.titleText = RSUI:Text({
        id = "combat_gear_v4_title_text", parent = view.titleRow,
        text = "称号：--", tone = "muted", fontSize = 8, overflow = "ellipsis",
        slot = { size = "fill", fill = 1, minWidth = 120, hAlign = "fill", vAlign = "center" },
    })
    view.titleToggle = ActionButton(view.titleRow, "combat_gear_v4_title_toggle", "称号参与", 72, function() view:ToggleTitle(); return true end)

    ------------------------------------------------------------------------
    -- Runtime / diagnostics pane.
    ------------------------------------------------------------------------
    view.runtimePage = RSUI:Border({ id = "combat_gear_v4_runtime", parent = view.switcher, padding = 0, variant = "soft", gradient = false })
    view.runtimeStack = RSUI:VerticalBox({ id = "combat_gear_v4_runtime_stack", parent = view.runtimePage, gap = 5 })
    view.runtimeActions = RSUI:HorizontalBox({
        id = "combat_gear_v4_runtime_actions", parent = view.runtimeStack, gap = 4,
        slot = { size = "fixed", height = 28, hAlign = "fill" },
    })
    ActionButton(view.runtimeActions, "combat_gear_v4_validate", "检查当前状态", 88, function() view:ValidateSelected(); return true end)
    ActionButton(view.runtimeActions, "combat_gear_v4_runtime_swap", "立即换装", 74, function() view:StartSelected(); return true end)
    view.snapButton = ActionButton(view.runtimeActions, "combat_gear_v4_snap", "按钮吸附", 70, function() view:ToggleSnap(); return true end)
    ActionButton(view.runtimeActions, "combat_gear_v4_runtime_hud", "打开HUD管理", 86, function()
        if S.UI and type(S.UI.ShowPage) == "function" then S.UI:ShowPage("hud") end
        return true
    end, true)

    local runtimeColumns = {
        { id = "feature", title = "运行状态", width = 118, minWidth = 86, absoluteMinWidth = 62, field = "feature" },
        { id = "value", title = "当前", width = 110, minWidth = 78, absoluteMinWidth = 54, field = "value", getTone = function(row) return row and row.tone or "muted" end },
        { id = "detail", title = "说明", size = "fill", minWidth = 180, absoluteMinWidth = 92, field = "detail", tone = "muted" },
    }
    view.runtimeRows = {}
    view.runtimeTable = RSUI:TableView({
        id = "combat_gear_v4_runtime_table", parent = view.runtimeStack,
        columns = runtimeColumns, rowHeight = 24, headerHeight = 22, columnGap = 3,
        items = view.runtimeRows, overscan = 1, maxPoolSize = 12,
        slot = { size = "fixed", height = 194, hAlign = "fill" },
    })

    view.validationText = RSUI:Text({
        id = "combat_gear_v4_validation_text", parent = view.runtimeStack,
        text = "状态检查只在点击“检查当前状态”时读取装备，不在后台轮询。", tone = "muted", fontSize = 8, overflow = "ellipsis",
        slot = { size = "fixed", height = 20, hAlign = "fill" },
    })
    local mismatchColumns = {
        { id = "slot", title = "未匹配部位", width = 92, minWidth = 70, absoluteMinWidth = 52, field = "slot" },
        { id = "expected", title = "目标", size = "fill", minWidth = 160, absoluteMinWidth = 80, field = "expected" },
        { id = "kind", title = "类型 / 原因", width = 98, minWidth = 70, absoluteMinWidth = 50, field = "kind", tone = "muted" },
    }
    view.validationTable = RSUI:TableView({
        id = "combat_gear_v4_validation_table", parent = view.runtimeStack,
        columns = mismatchColumns, rowHeight = 24, headerHeight = 22, columnGap = 3,
        items = view.validationRows, overscan = 1, maxPoolSize = 20,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })

    ------------------------------------------------------------------------
    -- Local draft + actions.
    ------------------------------------------------------------------------
    function view:IsBusy()
        local p = Presenter()
        return p ~= nil and type(p.IsBusy) == "function" and p:IsBusy() == true or false
    end

    function view:MarkDraftDirty(reason)
        self.draftDirty = true
        self.draftGeneration = self.draftGeneration + 1
        self.validation = nil
        self.validationRows = {}
        if self.validationTable then self.validationTable:SetItems(self.validationRows, "dirty:" .. tostring(self.draftGeneration)) end
        self:RefreshDraftPresentation(reason)
    end

    function view:RequestSelect(id, rightClick)
        id = id ~= nil and tostring(id) or nil
        if id == nil then return false end
        if tostring(self.selectedId or "") == id then return true end
        if self.draftDirty == true then
            local now = NowMs()
            if self.selectArmId ~= id or now - (tonumber(self.selectArmAt) or 0) > 5000 then
                self.selectArmId, self.selectArmAt = id, now
                SafeChat("当前换装有未保存修改；再次选择“" .. tostring((function()
                    for _, row in ipairs(self.listRows) do if row.id == id then return row.name end end
                    return id
                end)()) .. "”将丢弃这些修改。")
                return false
            end
        end
        self.selectArmId, self.selectArmAt = nil, 0
        self.selectedId = id
        self:ReloadDraft(false)
        return true
    end

    function view:ReloadDraft(chat)
        local p = Presenter()
        if p == nil or self.selectedId == nil then
            self.draft, self.draftDirty = nil, false
            self:RefreshDraftPresentation("none")
            return false
        end
        local draft = p:GetDraft(self.selectedId)
        if draft == nil then
            self.draft, self.draftDirty = nil, false
            self:RefreshDraftPresentation("missing")
            return false
        end
        self.draft = draft
        self.draftDirty = false
        self.draftGeneration = self.draftGeneration + 1
        self.validation, self.validationRows = nil, {}
        if self.validationTable then self.validationTable:SetItems(self.validationRows, "reload:" .. tostring(self.draftGeneration)) end
        SetNativeText(self.nameEdit, draft.name or "")
        self:RefreshDraftPresentation("reload")
        if chat == true then SafeChat("已撤销当前未保存修改。") end
        return true
    end

    function view:CreateSet(name)
        if self.draftDirty == true then
            SafeChat("当前方案有未保存修改；请先保存或撤销后再新建方案。")
            return false
        end
        local p = Presenter()
        if p == nil then SafeChat("Gear WorkspacePresenter 尚未初始化。"); return false end
        name = Trim(name)
        if name == "" then
            name = "换装" .. tostring(#self.listRows + 1)
        end
        local id, err = p:CreateSet(name)
        if id == nil then SafeChat("新建换装失败：" .. tostring(err or "未知原因")); return false end
        SetNativeText(self.newNameEdit, "")
        self.listRevision = -1
        self:RefreshList(true)
        self.selectedId = tostring(id)
        self:ReloadDraft(false)
        for index, row in ipairs(self.listRows) do
            if row.id == self.selectedId and self.setTable.SetSelectedIndex then self.setTable:SetSelectedIndex(index); break end
        end
        SafeChat("已新建换装方案：“" .. tostring(name) .. "”。穿好装备后点击“获取当前配置”。")
        return true
    end

    function view:SaveNameOnly()
        if self.draft == nil then SafeChat("请先选择方案。"); return false end
        local p = Presenter()
        if p == nil then return false end
        local nextName = Trim(GetNativeText(self.nameEdit))
        if nextName == "" then SafeChat("换装名称不能为空。"); return false end
        local metadata = p:GetDraft(self.draft.id)
        if metadata == nil then SafeChat("换装已经不存在。"); return false end
        metadata.name = nextName
        metadata.quick = self.draft.quick ~= false
        local ok, err = p:CommitMetadata(metadata)
        if ok ~= true then SafeChat("保存名称失败：" .. tostring(err or "未知原因")); return false end
        self.draft.name = nextName
        self.listRevision = -1
        self:RefreshList(true)
        self:RefreshDraftPresentation("rename")
        return true
    end

    function view:CaptureCurrent()
        if self.selectedId == nil then SafeChat("请先选择或新建一个换装方案。"); return false end
        local p = Presenter()
        if p == nil then return false end
        local draft, err = p:CaptureDraft(self.selectedId)
        if draft == nil then SafeChat("读取当前配置失败：" .. tostring(err or "未知原因")); return false end
        local nextName = Trim(GetNativeText(self.nameEdit))
        if nextName ~= "" then draft.name = nextName end
        if self.draft and self.draft.quick == false then draft.quick = false end
        if self.draft and type(self.draft.title) == "table" and self.draft.title.apply == false and type(draft.title) == "table" then
            draft.title.apply = false
        end
        self.draft = draft
        self:MarkDraftDirty("capture")
        SafeChat("已读取当前装备与称号；现在选择参与部位，然后点击“保存更改”。")
        return true
    end

    function view:SaveDraft()
        if self.draft == nil then SafeChat("没有可保存的换装方案。"); return false end
        local p = Presenter()
        if p == nil then return false end
        local nextName = Trim(GetNativeText(self.nameEdit))
        if nextName ~= "" then self.draft.name = nextName end
        local ok, err
        if self.draft.configured == true then ok, err = p:CommitPayload(self.draft) else ok, err = p:CommitMetadata(self.draft) end
        if ok ~= true then SafeChat("保存换装失败：" .. tostring(err or "未知原因")); return false end
        self.draftDirty = false
        self.listRevision = -1
        self:RefreshList(true)
        self:ReloadDraft(false)
        SafeChat("已保存“" .. tostring(self.draft and self.draft.name or "换装") .. "”。")
        return true
    end

    function view:ToggleQuick()
        if self.draft == nil then return false end
        local p = Presenter(); if p == nil then return false end
        local nextValue = self.draft.quick == false
        local ok, err = p:SetQuickEnabled(self.draft.id, nextValue)
        if ok ~= true then SafeChat("快捷按钮设置失败：" .. tostring(err or "未知原因")); return false end
        self.draft.quick = nextValue
        self.listRevision = -1
        self:RefreshList(true)
        self:RefreshDraftPresentation("quick")
        return true
    end

    function view:MoveSelected(delta)
        if self.selectedId == nil then return false end
        local p = Presenter(); if p == nil then return false end
        local ok, err = p:MoveSet(self.selectedId, delta)
        if ok ~= true then if err then SafeChat("调整顺序失败：" .. tostring(err)) end; return false end
        self.listRevision = -1
        self:RefreshList(true)
        for index, row in ipairs(self.listRows) do
            if row.id == self.selectedId and self.setTable.SetSelectedIndex then self.setTable:SetSelectedIndex(index); break end
        end
        return true
    end

    function view:DeleteSelected()
        if self.selectedId == nil then return false end
        if self.draftDirty then SafeChat("请先保存或撤销当前修改，再删除方案。"); return false end
        local now = NowMs()
        if self.deleteArmId ~= self.selectedId or now - (tonumber(self.deleteArmAt) or 0) > 5000 then
            self.deleteArmId, self.deleteArmAt = self.selectedId, now
            SafeChat("再次点击“删除”确认删除当前换装方案（5秒内有效）。")
            return false
        end
        local p = Presenter(); if p == nil then return false end
        local oldId = self.selectedId
        local ok, err = p:DeleteSet(oldId)
        if ok ~= true then SafeChat("删除换装失败：" .. tostring(err or "未知原因")); return false end
        self.deleteArmId, self.deleteArmAt = nil, 0
        self.selectedId, self.draft, self.draftDirty = nil, nil, false
        self.listRevision = -1
        self:RefreshList(true)
        if self.listRows[1] then self.selectedId = self.listRows[1].id; self:ReloadDraft(false); if self.setTable.SetSelectedIndex then self.setTable:SetSelectedIndex(1) end end
        SafeChat("换装方案已删除。")
        return true
    end

    function view:ApplyPreset(mode)
        if self:IsBusy() then SafeChat("换装正在执行，暂不能修改参与部位。"); return false end
        if self.draft == nil then SafeChat("请先选择方案并获取当前配置。"); return false end
        local p = Presenter(); if p == nil then return false end
        local changed, titleMissing = p:ApplyPreset(self.draft, mode)
        if changed == true then self:MarkDraftDirty("preset:" .. tostring(mode)) else self:RefreshDraftPresentation("preset") end
        if titleMissing == true then SafeChat("当前方案没有可切换的称号信息；请先选择称号后重新获取当前配置。") end
        return changed == true
    end

    function view:ToggleManaged(slot)
        if self:IsBusy() then SafeChat("换装正在执行，暂不能修改参与部位。"); return false end
        if self.draft == nil then return false end
        local p = Presenter(); if p == nil then return false end
        local ok, result = p:ToggleManagedSlot(self.draft, slot)
        if ok ~= true then SafeChat(tostring(result or "该部位不可编辑")); return false end
        self:MarkDraftDirty("slot:" .. tostring(slot))
        return true
    end

    function view:ToggleTitle()
        if self:IsBusy() then SafeChat("换装正在执行，暂不能修改称号参与状态。"); return false end
        if self.draft == nil then return false end
        local p = Presenter(); if p == nil then return false end
        local ok, result = p:ToggleTitle(self.draft)
        if ok ~= true then SafeChat(tostring(result or "称号不可编辑")); return false end
        self:MarkDraftDirty("title")
        return true
    end

    function view:ToggleSnap()
        local p = Presenter(); if p == nil then return false end
        local ok, err = p:SetQuickSnapEnabled(not p:IsQuickSnapEnabled())
        if ok ~= true then SafeChat("快捷按钮吸附设置失败：" .. tostring(err or "未知原因")); return false end
        self:RefreshRuntime(true)
        return true
    end

    function view:StartSelected()
        if self.selectedId == nil then SafeChat("请先选择换装方案。"); return false end
        if self.draftDirty then SafeChat("当前方案有未保存修改；请先保存或撤销后再执行换装。"); return false end
        local p = Presenter(); if p == nil then return false end
        local ok, err = p:Start(self.selectedId)
        if ok == false and err ~= nil then SafeChat("换装失败：" .. tostring(err)) end
        self:RefreshRuntime(true)
        self:RefreshSummary()
        return ok ~= false
    end

    function view:ValidateSelected()
        if self.selectedId == nil then SafeChat("请先选择换装方案。"); return false end
        if self.draftDirty then SafeChat("当前方案有未保存修改；检查的是已保存方案，请先保存或撤销。"); return false end
        local p = Presenter(); if p == nil then return false end
        local result, err = p:ValidateSet(self.selectedId)
        if result == nil then SafeChat("检查失败：" .. tostring(err or "未知原因")); return false end
        self.validation = result
        self.validationRows = result.rows or {}
        self.validationTable:SetItems(self.validationRows, "validation:" .. tostring(result.checkedAt or NowMs()))
        if result.matched == true then
            self.validationText:SetTone("green")
            self.validationText:SetText("当前装备与称号已经完全符合所选方案。")
        else
            self.validationText:SetTone("yellow")
            self.validationText:SetText("当前仍有 " .. tostring(#self.validationRows) .. " 项未达到目标；列表仅来自本次显式检查。")
        end
        return true
    end

    ------------------------------------------------------------------------
    -- Presentation refresh.
    ------------------------------------------------------------------------
    function view:RefreshList(force)
        local p = Presenter()
        if p == nil then return false end
        local revision = p:GetRevision()
        if force ~= true and revision == self.listRevision then return false end
        local rows, actualRevision = p:GetSetRows()
        for _, row in ipairs(rows or {}) do
            row.order = tostring(row.order or "")
            row.configuredRaw = row.configured == true
            row.state = row.configured and (row.quick and "就绪" or "就绪") or "待配置"
            row.stateTone = row.configured and "green" or "yellow"
            if row.quick == false and row.configured then row.state = "无快捷"; row.stateTone = "muted" end
        end
        self.listRows = rows or {}
        self.listRevision = tonumber(actualRevision) or revision
        local signature = BuildSetSignature(self.listRows, self.listRevision)
        if force == true or signature ~= self.listSignature then
            self.listSignature = signature
            self.setTable:SetItems(self.listRows, signature)
        end
        local found = false
        if self.selectedId ~= nil then
            for _, row in ipairs(self.listRows) do if row.id == tostring(self.selectedId) then found = true; break end end
        end
        if not found then
            self.selectedId = self.listRows[1] and self.listRows[1].id or nil
            if self.selectedId ~= nil then self:ReloadDraft(false) else self.draft, self.draftDirty = nil, false; self:RefreshDraftPresentation("empty") end
        elseif self.draftDirty ~= true and self.draft ~= nil and tostring(self.draft.id) == tostring(self.selectedId) then
            -- External metadata/payload changes (legacy advanced editor, reload,
            -- profile action) are reflected only when no local unsaved draft exists.
            self:ReloadDraft(false)
        end
        return true
    end

    function view:RefreshDraftPresentation(reason)
        local p = Presenter()
        local draft = self.draft
        local busy = self:IsBusy()
        local enabled = draft ~= nil and not busy
        SetNativeEnabled(self.nameEdit, enabled)
        SetNativeEnabled(self.renameButton, enabled)
        if draft == nil then
            self.rightTitle:SetText("当前方案：--")
            self.editState:SetText("请选择或新建换装方案。")
            self.editState:SetTone("muted")
            self.titleText:SetText("称号：--")
            self.slotRows = {}
            self.slotView:SetItems(self.slotRows, "empty:" .. tostring(self.draftGeneration))
            return
        end

        self.rightTitle:SetText("当前方案：" .. tostring(draft.name or draft.id) .. (self.draftDirty and "  *未保存" or ""))
        if reason ~= "rename_typing" then SetNativeText(self.nameEdit, draft.name or "") end
        local managed = p and p:GetManagedCount(draft) or 0
        local configured = draft.configured == true
        local titleManaged = type(draft.title) == "table" and draft.title.apply == true
        self.editState:SetTone(self.draftDirty and "yellow" or (configured and "green" or "muted"))
        self.editState:SetText((configured and "已读取配置" or "尚未读取当前装备")
            .. " · 参与 " .. tostring(managed) .. " 个装备部位"
            .. (titleManaged and " + 称号" or "")
            .. (self.draftDirty and " · 有未保存修改" or ""))
        if self.quickToggle then self.quickToggle:SetText(draft.quick == false and "快捷按钮：关" or "快捷按钮：开") end
        self.titleText:SetText("称号：" .. tostring(p and p:GetTitleText(draft) or "--") .. (titleManaged and " · 参与" or " · 保持当前"))
        self.titleText:SetTone(titleManaged and "green" or "muted")

        local bySlot = {}
        for _, item in ipairs(draft.items or {}) do bySlot[tonumber(item.slot)] = item end
        local slots = p and p:GetSlotDefinitions() or {}
        local rows = {}
        for index, slot in ipairs(slots) do
            local item = bySlot[tonumber(slot.slot)]
            local row = {
                id = tostring(slot.slot), slot = slot.slot, slotName = slot.name, weapon = slot.weapon == true,
                empty = item == nil or item.empty == true,
                managed = item ~= nil and item.empty ~= true and item.managed ~= false,
                toggleable = enabled and item ~= nil and item.empty ~= true,
            }
            if item == nil then
                row.displayName = "未读取"
            elseif item.empty == true then
                row.displayName = "空（保持当前）"
            else
                local grade = item.grade ~= nil and (" [G" .. tostring(item.grade) .. "]") or ""
                row.displayName = tostring(item.name or "未知装备") .. grade
            end
            rows[index] = row
        end
        self.slotRows = rows
        self.draftGeneration = self.draftGeneration + 1
        self.slotView:SetItems(self.slotRows, "draft:" .. tostring(self.draftGeneration))
    end

    function view:RefreshRuntime(force)
        local p = Presenter()
        if p == nil then return false end
        local rt = p:GetRuntimeSnapshot()
        self.lastRuntimeSnapshot = rt
        local selected = self.draft
        local configured = selected ~= nil and selected.configured == true
        local inCombatText = rt.inCombat == nil and "未知" or (rt.inCombat and "战斗中" or "脱战")
        local rows = {
            { feature = "执行状态", value = rt.busy and "切换中" or "空闲", tone = rt.busy and "yellow" or "green", detail = rt.busy and ((rt.setName or "--") .. " · " .. PhaseLabel(rt.stage) .. " · " .. tostring(rt.index) .. "/" .. tostring(rt.total)) or "等待换装操作" },
            { feature = "战斗安全", value = inCombatText, tone = rt.inCombat and "red" or (rt.inCombat == false and "green" or "muted"), detail = rt.inCombat and "RU 客户端会拒绝 Addon 自动装备接口；不会在战斗中反复尝试" or "脱战时可执行自动换装" },
            { feature = "当前方案", value = selected and (configured and "已配置" or "待配置") or "未选择", tone = configured and "green" or "yellow", detail = selected and tostring(selected.name or selected.id) or "先从左侧选择方案" },
            { feature = "快捷按钮吸附", value = p:IsQuickSnapEnabled() and "开" or "关", tone = p:IsQuickSnapEnabled() and "green" or "muted", detail = "仅控制 Gear 独立快捷按钮之间的吸附" },
            { feature = "存储状态", value = rt.writeFence and "写保护" or (rt.persistenceDegraded and "仅备份" or "正常"), tone = rt.writeFence and "red" or (rt.persistenceDegraded and "yellow" or "green"), detail = rt.writeFence and tostring(rt.writeFence) or (rt.persistenceDegraded and "主槽写入异常；备份已保留" or "Core 双槽持久化可写") },
            { feature = "活动方案", value = rt.activeSetId and tostring(rt.activeSetId) or "--", tone = rt.activeSetId and "green" or "muted", detail = rt.switchingSetId and ("正在切换 " .. tostring(rt.switchingSetId)) or "以最终装备对账结果为准" },
        }
        local sigParts = {}
        for _, row in ipairs(rows) do sigParts[#sigParts + 1] = row.feature .. ":" .. row.value .. ":" .. row.detail end
        local signature = table.concat(sigParts, "|")
        if force == true or signature ~= self.runtimeSignature then
            self.runtimeSignature = signature
            self.runtimeRows = rows
            self.runtimeTable:SetItems(rows, signature)
        end
        if self.snapButton then self.snapButton:SetText(p:IsQuickSnapEnabled() and "按钮吸附：开" or "按钮吸附：关") end
        return true
    end

    function view:RefreshSummary()
        local p = Presenter()
        if p == nil then
            self.summary:SetTone("red"); self.summary:SetText("Gear WorkspacePresenter 尚未初始化")
            return false
        end
        local rt = self.lastRuntimeSnapshot or p:GetRuntimeSnapshot()
        local selected = self.draft
        local text = "方案 " .. tostring(#self.listRows)
            .. " · 当前 " .. tostring(selected and selected.name or "--")
            .. " · " .. (selected and selected.configured and ("参与 " .. tostring(p:GetManagedCount(selected)) .. " 件") or "待配置")
            .. " · " .. (rt.busy and ("正在" .. PhaseLabel(rt.stage)) or "空闲")
        if rt.inCombat == true then text = text .. " · 战斗中自动换装受客户端限制" end
        self.summary:SetTone(rt.inCombat and "yellow" or (rt.busy and "yellow" or "green"))
        self.summary:SetText(text)
        return true
    end

    function view:SetSubview(name)
        self.subview = name == "runtime" and "runtime" or "editor"
        self.switcher:SetActiveIndex(self.subview == "editor" and 1 or 2)
        self.tabEditor:SetSelected(self.subview == "editor")
        self.tabRuntime:SetSelected(self.subview == "runtime")
        if self.subview == "runtime" then self:RefreshRuntime(true) else self:RefreshDraftPresentation("subview") end
        return true
    end

    function view:Refresh(force)
        local p = Presenter()
        if p == nil then
            self.summary:SetText("Gear 深度工作区尚未就绪"); self.summary:SetTone("red")
            return false
        end
        self:RefreshList(force == true)
        self:RefreshRuntime(force == true)
        self:RefreshSummary()
        local busy = self:IsBusy()
        if self.lastBusy ~= busy then
            self.lastBusy = busy
            self:RefreshDraftPresentation("busy_state")
        end
        local hasDraft = self.draft ~= nil
        local canEdit = hasDraft and not busy
        for _, button in ipairs({ self.captureButton, self.saveButton, self.discardButton, self.quickToggle, self.moveUp, self.moveDown, self.deleteButton, self.titleToggle }) do
            if button and type(button.SetEnabled) == "function" then button:SetEnabled(canEdit) end
        end
        SetNativeEnabled(self.newNameEdit, not busy)
        SetNativeEnabled(self.newButton, not busy)
        SetNativeEnabled(self.nameEdit, canEdit)
        SetNativeEnabled(self.renameButton, canEdit)
        return true
    end

    view:SetSubview("editor")
    view:Refresh(true)
    return view
end

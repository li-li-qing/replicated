------------------------------------------------------------------------
-- Replicated Suite - HUD Manager Workspace (M4)
--
-- One presentation surface for the Suite HUD Authority. The page consumes
-- HudManager snapshots only; it does not own module state, geometry or native
-- observations. The HUD list uses RSUI TableView + SelectionModel so the number
-- of native rows remains bounded even as professional HUD adapters grow.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI = S.RSUI
if type(RSUI) ~= "table" then return end

S.HudPage = {}
local P = S.HudPage

local BG_STEPS = { 1.00, 0.85, 0.70, 0.55, 0.35, 0.20, 0.00 }

local function Percent(value)
    return tostring(math.floor((tonumber(value) or 0) * 100 + 0.5)) .. "%"
end

local function NextBackground(value)
    local current = tonumber(value) or 0.90
    if current > 0.85 and current < 1.00 then return 0.85 end
    for index, step in ipairs(BG_STEPS) do
        if math.abs(step - current) < 0.001 then return BG_STEPS[index < #BG_STEPS and index + 1 or 1] end
    end
    return 0.85
end

local function Trim(value)
    return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function RequestHudSave()
    if S.Storage ~= nil and type(S.Storage.RequestSave) == "function" then S.Storage:RequestSave() end
    if S.State ~= nil and type(S.State.MarkDirty) == "function" then S.State:MarkDirty("hud") end
end

local function BuildHudRows()
    local rows = {}
    for _, item in ipairs(S.HudManager and S.HudManager:List() or {}) do
        local state
        local tone
        if item.visible ~= true then
            state, tone = "隐藏", "muted"
        elseif item.effectiveVisible == true then
            state, tone = "显示中", "green"
        elseif item.moduleEnabled == false then
            state, tone = "模块关闭", "yellow"
        elseif S.HudManager.temporaryHidden == true then
            state, tone = "临时隐藏", "yellow"
        else
            state, tone = "已保存", "yellow"
        end
        local flags = {}
        if item.collapsed then flags[#flags + 1] = "收" end
        if item.locked then flags[#flags + 1] = "锁" end
        if item.clickThrough then flags[#flags + 1] = "穿" end
        rows[#rows + 1] = {
            id = item.id,
            title = item.title,
            module = item.moduleId ~= "" and item.moduleId or "Suite",
            state = state,
            stateTone = tone,
            flags = #flags > 0 and table.concat(flags, "/") or "--",
            source = item,
        }
    end
    return rows
end

local function HudRowsRevision(rows)
    local parts = { tostring(#rows) }
    for _, row in ipairs(rows) do
        parts[#parts + 1] = table.concat({ tostring(row.id), tostring(row.state), tostring(row.flags) }, ":")
    end
    return table.concat(parts, "|")
end

local function CreateSelectableRow(list, poolIndex, tableView)
    local row = RSUI:TableRow({
        id = "hud_manager_row_" .. tostring(poolIndex),
        parent = list,
        columns = tableView.columns,
        resolvedWidths = tableView.resolvedWidths,
        rowHeight = tableView.rowHeight,
        columnGap = tableView.columnGap,
        pickable = true,
    })
    if row ~= nil and row.root ~= nil then
        S.UI:SafeHandler(row.root, "OnClick", function()
            local index = row.itemIndex
            if index ~= nil then tableView:SetSelectedIndex(index) end
            return true
        end, "hud:manager_row:" .. tostring(poolIndex))
    end
    return row
end

local function CreateButton(parent, id, text, width)
    local button = S.UI:CreateButton(parent, id, text, 0, 0, width or 72, 24, 8, false)
    button.rsDesignWidth = width or 72
    return button
end

function P.Create(parent)
    local page = {
        key = "hud",
        parent = parent,
        rows = {},
        selectedId = nil,
        recoverArmedAt = 0,
        resetAllArmedAt = 0,
        resetAllArmedId = nil,
        profileDeleteArmedAt = 0,
        profileDeleteArmedName = nil,
    }

    page.root = S.UI:CreatePanel(parent, "hud_page", 0, 0, 100, 100, "soft")
    if page.root.rsBorder and page.root.rsBorder.SetVisible then page.root.rsBorder:SetVisible(false) end
    if page.root.rsBackground and page.root.rsBackground.SetVisible then page.root.rsBackground:SetVisible(false) end

    page.title = S.UI:CreateLabel(page.root, "hud_title", "HUD 管理中心", 0, 0, 400, 28, 16, nil, ALIGN_LEFT)
    page.note = S.UI:CreateLabel(page.root, "hud_note", "显示、锁定、穿透、尺寸与外观统一由 HUD Authority 管理；模块关闭不会抹掉 HUD 偏好。", 0, 0, 800, 20, 9, "muted", ALIGN_LEFT)

    ------------------------------------------------------------------------
    -- Global HUD controls / overview.
    ------------------------------------------------------------------------
    page.overview = S.UI:CreatePanel(page.root, "hud_overview_card", 0, 0, 100, 76, "card")
    page.overviewTitle = S.UI:CreateLabel(page.overview, "hud_overview_title", "全局 HUD", 8, 5, 120, 20, 11, "yellow", ALIGN_LEFT)
    page.overviewStats = S.UI:CreateLabel(page.overview, "hud_overview_stats", "--", 130, 5, 500, 20, 9, "muted", ALIGN_LEFT)

    page.edit = CreateButton(page.overview, "hud_edit", "编辑布局", 76)
    page.unlock = CreateButton(page.overview, "hud_unlock", "临时解锁", 76)
    page.snap = CreateButton(page.overview, "hud_snap", "吸附", 58)
    page.temp = CreateButton(page.overview, "hud_temp", "临时隐藏", 72)
    page.recover = CreateButton(page.overview, "hud_recover", "恢复全部", 76)
    page.globalFontMinus = CreateButton(page.overview, "hud_global_font_minus", "全局字 -", 62)
    page.globalFontPlus = CreateButton(page.overview, "hud_global_font_plus", "全局字 +", 62)
    page.globalBg = CreateButton(page.overview, "hud_global_bg", "背景", 66)
    page.globalCompact = CreateButton(page.overview, "hud_global_compact", "紧凑", 66)
    page.globalButtons = { page.edit, page.unlock, page.snap, page.temp, page.recover, page.globalFontMinus, page.globalFontPlus, page.globalBg, page.globalCompact }

    S.UI:SafeHandler(page.edit, "OnClick", function()
        S.HudManager:SetEditMode(not S.HudManager:IsEditMode()); page:Refresh()
    end, "hud:edit")
    S.UI:SafeHandler(page.unlock, "OnClick", function()
        if not S.HudManager:IsEditMode() then S.HudManager:SetEditMode(true) end
        S.HudManager:SetTemporaryUnlockAll(not S.HudManager:IsTemporaryUnlockAll()); page:Refresh()
    end, "hud:unlock")
    S.UI:SafeHandler(page.snap, "OnClick", function()
        S.State.settings.hudSnapEnabled = not (S.State.settings.hudSnapEnabled ~= false)
        RequestHudSave(); page:Refresh()
    end, "hud:snap")
    S.UI:SafeHandler(page.temp, "OnClick", function()
        if S.HudManager.temporaryHidden then S.HudManager:RestoreTemporaryHidden() else S.HudManager:TemporaryHideAll() end
        page:Refresh()
    end, "hud:temp")
    S.UI:SafeHandler(page.recover, "OnClick", function()
        local now = S.NowMs and S.NowMs() or 0
        if now - (tonumber(page.recoverArmedAt) or 0) <= 5000 then
            page.recoverArmedAt = 0
            S.HudManager:RecoverAll()
            S.SafeChat("已执行 HUD 紧急恢复：位置已拉回安全区域。")
        else
            page.recoverArmedAt = now
            S.SafeChat("再次点击“恢复全部”确认。此操作主要用于找回跑到屏幕外的 HUD。")
        end
        page:Refresh()
    end, "hud:recover_all")
    S.UI:SafeHandler(page.globalFontMinus, "OnClick", function() S.HudManager:AdjustGlobalFontScale(-0.10); page:Refresh() end, "hud:gfont_minus")
    S.UI:SafeHandler(page.globalFontPlus, "OnClick", function() S.HudManager:AdjustGlobalFontScale(0.10); page:Refresh() end, "hud:gfont_plus")
    S.UI:SafeHandler(page.globalBg, "OnClick", function()
        S.HudManager:SetGlobalBackgroundAlpha(NextBackground(S.State.settings.globalHudBackgroundAlpha)); page:Refresh()
    end, "hud:gbg")
    S.UI:SafeHandler(page.globalCompact, "OnClick", function()
        S.HudManager:SetGlobalCompact(not (S.State.settings.globalCompactMode == true)); page:Refresh()
    end, "hud:gcompact")

    ------------------------------------------------------------------------
    -- Left: virtualized HUD list + SelectionModel.
    ------------------------------------------------------------------------
    page.listCard = S.UI:CreatePanel(page.root, "hud_list_card", 0, 0, 100, 100, "card")
    page.listTitle = S.UI:CreateLabel(page.listCard, "hud_list_title", "已注册 HUD", 8, 5, 200, 22, 11, "yellow", ALIGN_LEFT)
    page.listHint = S.UI:CreateLabel(page.listCard, "hud_list_hint", "滚轮浏览 · 点击一行编辑", 8, 27, 260, 18, 8, "muted", ALIGN_LEFT)

    local columns = {
        { id = "title", title = "HUD", size = "fill", minWidth = 90, absoluteMinWidth = 52, field = "title" },
        { id = "module", title = "模块", width = 66, minWidth = 52, absoluteMinWidth = 38, field = "module", tone = "muted" },
        { id = "state", title = "状态", width = 64, minWidth = 52, absoluteMinWidth = 40, field = "state", getTone = function(row) return row and row.stateTone or "muted" end },
        { id = "flags", title = "模式", width = 48, minWidth = 40, absoluteMinWidth = 30, field = "flags", tone = "muted" },
    }
    page.table = RSUI:TableView({
        id = "hud_manager_table", parent = page.listCard,
        columns = columns, rowHeight = 22, headerHeight = 22, columnGap = 2,
        items = page.rows, overscan = 2, maxPoolSize = 24,
        selectable = true, selectionMode = "single",
        getKey = function(row, index) return row and row.id or index end,
        rowFactory = function(list, poolIndex, tableView) return CreateSelectableRow(list, poolIndex, tableView) end,
        onSelectionChanged = function(index)
            local row = index and page.rows[index] or nil
            if row ~= nil then page.selectedId = row.id end
            page:RefreshInspector()
        end,
    })

    ------------------------------------------------------------------------
    -- Right: capability-aware HUD inspector.
    ------------------------------------------------------------------------
    page.inspector = S.UI:CreatePanel(page.root, "hud_inspector_card", 0, 0, 100, 100, "card")
    page.detailTitle = S.UI:CreateLabel(page.inspector, "hud_detail_title", "当前 HUD：--", 8, 5, 360, 22, 12, "yellow", ALIGN_LEFT)
    page.detailState = S.UI:CreateLabel(page.inspector, "hud_detail_state", "--", 8, 29, 500, 19, 9, "muted", ALIGN_LEFT)
    page.detailGeometry = S.UI:CreateLabel(page.inspector, "hud_detail_geometry", "位置：--", 8, 49, 500, 19, 8, "muted", ALIGN_LEFT)
    page.detailCaps = S.UI:CreateLabel(page.inspector, "hud_detail_caps", "能力：--", 8, 69, 500, 19, 8, "muted", ALIGN_LEFT)

    page.show = CreateButton(page.inspector, "hud_detail_show", "显示", 62)
    page.collapse = CreateButton(page.inspector, "hud_detail_collapse", "折叠", 62)
    page.lock = CreateButton(page.inspector, "hud_detail_lock", "锁定", 62)
    page.pass = CreateButton(page.inspector, "hud_detail_pass", "穿透", 66)
    page.titleVisible = CreateButton(page.inspector, "hud_detail_title_visible", "标题栏", 66)
    page.find = CreateButton(page.inspector, "hud_detail_find", "找回", 56)
    page.resetPos = CreateButton(page.inspector, "hud_detail_pos", "恢复位置", 68)
    page.resetSize = CreateButton(page.inspector, "hud_detail_size", "恢复大小", 68)

    page.fontMinus = CreateButton(page.inspector, "hud_detail_font_minus", "字体 -", 58)
    page.fontPlus = CreateButton(page.inspector, "hud_detail_font_plus", "字体 +", 58)
    page.fontInherit = CreateButton(page.inspector, "hud_detail_font_inherit", "继承字体", 70)
    page.bg = CreateButton(page.inspector, "hud_detail_bg", "背景", 66)
    page.bgInherit = CreateButton(page.inspector, "hud_detail_bg_inherit", "继承背景", 70)
    page.compact = CreateButton(page.inspector, "hud_detail_compact", "紧凑", 62)
    page.compactInherit = CreateButton(page.inspector, "hud_detail_compact_inherit", "继承紧凑", 70)

    page.moduleSettings = CreateButton(page.inspector, "hud_detail_module_settings", "模块设置", 72)
    page.resetTitle = CreateButton(page.inspector, "hud_detail_title_reset", "恢复标题", 68)
    page.resetAppearance = CreateButton(page.inspector, "hud_detail_appearance", "恢复外观", 68)
    page.resetAll = CreateButton(page.inspector, "hud_detail_all", "全部恢复", 68)

    page.titleEditLabel = S.UI:CreateLabel(page.inspector, "hud_custom_title_label", "显示名称", 8, 0, 60, 22, 8, "muted", ALIGN_LEFT)
    page.titleEdit = S.UI:CreateEditBox(page.inspector, "hud_custom_title_edit", 0, 0, 120, 24, 40)
    page.titleApply = CreateButton(page.inspector, "hud_custom_title_apply", "应用", 48)

    page.detailButtons = {
        page.show, page.collapse, page.lock, page.pass, page.titleVisible, page.find, page.resetPos, page.resetSize,
        page.fontMinus, page.fontPlus, page.fontInherit, page.bg, page.bgInherit, page.compact, page.compactInherit,
        page.moduleSettings, page.resetTitle, page.resetAppearance, page.resetAll,
    }

    local function Selected() return page.selectedId end
    S.UI:SafeHandler(page.show, "OnClick", function() local id = Selected(); if id then S.HudManager:ToggleVisible(id) end; page:Refresh() end, "hud:detail_show")
    S.UI:SafeHandler(page.collapse, "OnClick", function() local id = Selected(); if id then S.HudManager:ToggleCollapsed(id) end; page:Refresh() end, "hud:detail_collapse")
    S.UI:SafeHandler(page.lock, "OnClick", function() local id = Selected(); if id then S.HudManager:ToggleLocked(id) end; page:Refresh() end, "hud:detail_lock")
    S.UI:SafeHandler(page.pass, "OnClick", function() local id = Selected(); if id then S.HudManager:ToggleClickThrough(id) end; page:Refresh() end, "hud:detail_pass")
    S.UI:SafeHandler(page.titleVisible, "OnClick", function() local id = Selected(); if id then S.HudManager:ToggleTitleVisible(id) end; page:Refresh() end, "hud:detail_title_visible")
    S.UI:SafeHandler(page.find, "OnClick", function() local id = Selected(); if id then S.HudManager:Recover(id) end; page:Refresh() end, "hud:detail_find")
    S.UI:SafeHandler(page.resetPos, "OnClick", function() local id = Selected(); if id then S.HudManager:ResetPosition(id) end; page:Refresh() end, "hud:detail_pos")
    S.UI:SafeHandler(page.resetSize, "OnClick", function() local id = Selected(); if id then S.HudManager:ResetSize(id) end; page:Refresh() end, "hud:detail_size")
    S.UI:SafeHandler(page.fontMinus, "OnClick", function() local id = Selected(); if id then S.HudManager:AdjustFontScale(id, -0.10) end; page:Refresh() end, "hud:detail_font_minus")
    S.UI:SafeHandler(page.fontPlus, "OnClick", function() local id = Selected(); if id then S.HudManager:AdjustFontScale(id, 0.10) end; page:Refresh() end, "hud:detail_font_plus")
    S.UI:SafeHandler(page.fontInherit, "OnClick", function() local id = Selected(); if id then S.HudManager:RestoreFontInheritance(id) end; page:Refresh() end, "hud:detail_font_inherit")
    S.UI:SafeHandler(page.bg, "OnClick", function() local id = Selected(); if id then S.HudManager:SetBackgroundAlpha(id, NextBackground(S.HudManager:GetEffectiveBackgroundAlpha(id))) end; page:Refresh() end, "hud:detail_bg")
    S.UI:SafeHandler(page.bgInherit, "OnClick", function() local id = Selected(); if id then S.HudManager:RestoreBackgroundInheritance(id) end; page:Refresh() end, "hud:detail_bg_inherit")
    S.UI:SafeHandler(page.compact, "OnClick", function() local id = Selected(); if id then S.HudManager:SetCompact(id, not S.HudManager:IsCompact(id)) end; page:Refresh() end, "hud:detail_compact")
    S.UI:SafeHandler(page.compactInherit, "OnClick", function() local id = Selected(); if id then S.HudManager:RestoreCompactInheritance(id) end; page:Refresh() end, "hud:detail_compact_inherit")
    S.UI:SafeHandler(page.moduleSettings, "OnClick", function()
        local def = Selected() and S.HudManager:Get(Selected()) or nil
        if def ~= nil and def.ModuleId ~= "" and S.ModuleManager ~= nil then
            local ok, err = S.ModuleManager:OpenSettings(def.ModuleId)
            if not ok then S.SafeChat("模块设置暂不可用：" .. tostring(err or def.ModuleId)) end
        end
    end, "hud:detail_module_settings")
    S.UI:SafeHandler(page.resetTitle, "OnClick", function() local id = Selected(); if id then S.HudManager:ResetTitle(id) end; page:Refresh() end, "hud:detail_title_reset")
    S.UI:SafeHandler(page.resetAppearance, "OnClick", function() local id = Selected(); if id then S.HudManager:ResetHudAppearance(id) end; page:Refresh() end, "hud:detail_appearance")
    S.UI:SafeHandler(page.resetAll, "OnClick", function()
        local id = Selected(); if id == nil then return end
        local now = S.NowMs and S.NowMs() or 0
        if page.resetAllArmedId == id and now - (tonumber(page.resetAllArmedAt) or 0) <= 5000 then
            page.resetAllArmedAt, page.resetAllArmedId = 0, nil
            S.HudManager:ResetHudAll(id)
            S.SafeChat("已恢复当前 HUD 默认布局与外观：" .. tostring(id))
        else
            page.resetAllArmedAt, page.resetAllArmedId = now, id
            S.SafeChat("再次点击“全部恢复”确认当前 HUD。")
        end
        page:Refresh()
    end, "hud:detail_all")
    S.UI:SafeHandler(page.titleApply, "OnClick", function()
        local id = Selected()
        if id ~= nil and page.titleEdit ~= nil then S.HudManager:SetCustomTitle(id, page.titleEdit:GetText(), true) end
        page:Refresh()
    end, "hud:custom_title_apply")

    ------------------------------------------------------------------------
    -- HUD layout profiles. Geometry + UI appearance only; business state stays
    -- with each module Authority and professional adapters capture extra state.
    ------------------------------------------------------------------------
    page.profile = S.UI:CreatePanel(page.root, "hud_profile_card", 0, 0, 100, 62, "card")
    page.profileLabel = S.UI:CreateLabel(page.profile, "hud_profile_label", "HUD 布局方案", 8, 5, 90, 20, 10, "yellow", ALIGN_LEFT)
    page.profileHint = S.UI:CreateLabel(page.profile, "hud_profile_hint", "保存 / 应用当前所有 HUD 的位置、尺寸与显示外观", 104, 5, 430, 20, 8, "muted", ALIGN_LEFT)
    page.profileEdit = S.UI:CreateEditBox(page.profile, "hud_profile_edit", 8, 30, 150, 24, 32)
    page.nextProfile = CreateButton(page.profile, "hud_profile_next", "选择", 50)
    page.saveProfile = CreateButton(page.profile, "hud_profile_save", "保存布局", 64)
    page.applyProfile = CreateButton(page.profile, "hud_profile_apply", "应用布局", 64)
    page.deleteProfile = CreateButton(page.profile, "hud_profile_delete", "删除", 50)
    page.profileButtons = { page.nextProfile, page.saveProfile, page.applyProfile, page.deleteProfile }

    local function ProfileName()
        local value = page.profileEdit and page.profileEdit:GetText() or page.selectedProfileName or ""
        return Trim(value)
    end
    S.UI:SafeHandler(page.nextProfile, "OnClick", function()
        local name = S.Profiles:NextName("hud", ProfileName())
        if name == nil then
            S.SafeChat("还没有已保存的 HUD 布局方案。")
        elseif page.profileEdit ~= nil and page.profileEdit.SetText ~= nil then
            page.profileEdit:SetText(name)
        else
            page.selectedProfileName = name
        end
        page:Refresh()
    end, "hud:profile_next")
    S.UI:SafeHandler(page.saveProfile, "OnClick", function()
        if page.profileEdit == nil then S.SafeChat("当前客户端输入框不可用，暂不能新建 HUD 方案名称。"); return end
        local name = ProfileName(); if name == "" then S.SafeChat("请输入 HUD 布局方案名称。"); return end
        page.selectedProfileName = name
        local ok, err = S.Profiles:SaveHud(name)
        if ok == false then S.SafeChat(tostring(err or "HUD 布局保存失败")) else S.SafeChat("已保存 HUD 布局：" .. name) end
        page:Refresh()
    end, "hud:profile_save")
    S.UI:SafeHandler(page.applyProfile, "OnClick", function()
        local ok, err = S.Profiles:ApplyHud(ProfileName()); if not ok then S.SafeChat(tostring(err)) end; page:Refresh()
    end, "hud:profile_apply")
    S.UI:SafeHandler(page.deleteProfile, "OnClick", function()
        local name = ProfileName(); if name == "" then S.SafeChat("请选择或输入 HUD 布局方案名称。"); return end
        local now = S.NowMs and S.NowMs() or 0
        if page.profileDeleteArmedName == name and now - (tonumber(page.profileDeleteArmedAt) or 0) <= 5000 then
            local ok, err = S.Profiles:Delete("hud", name)
            page.profileDeleteArmedName, page.profileDeleteArmedAt = nil, 0
            if ok then S.SafeChat("已删除 HUD 布局：" .. name) else S.SafeChat(tostring(err)) end
        else
            page.profileDeleteArmedName, page.profileDeleteArmedAt = name, now
            S.SafeChat("再次点击删除确认 HUD 布局：" .. name)
        end
        page:Refresh()
    end, "hud:profile_delete")

    function page:RefreshInspector()
        local id = self.selectedId
        local def = id and S.HudManager:Get(id) or nil
        local placement = id and S.HudManager:GetPlacement(id) or nil
        local has = def ~= nil and placement ~= nil

        self.detailTitle:SetText(has and ("当前 HUD：" .. tostring(placement.customTitle or def.Title)) or "当前 HUD：--")
        if not has then
            self.detailState:SetText("从左侧选择一个 HUD。")
            self.detailGeometry:SetText("位置：--")
            self.detailCaps:SetText("能力：--")
        else
            local preferred = placement.visible == true
            local effective = S.HudManager:IsEffectiveVisible(id)
            local moduleEnabled = S.HudManager:IsModuleEnabled(def)
            self.detailState:SetText("显示偏好 " .. (preferred and "开" or "关") .. " · 实际 " .. (effective and "可见" or "隐藏") .. " · 模块 " .. (moduleEnabled and "启用" or "关闭"))
            local size = (tonumber(placement.width) ~= nil and tonumber(placement.height) ~= nil)
                and (tostring(math.floor(tonumber(placement.width))) .. "×" .. tostring(math.floor(tonumber(placement.height)))) or "默认"
            self.detailGeometry:SetText("位置 " .. tostring(placement.anchorH or "--") .. "/" .. tostring(placement.anchorV or "--") .. "  X " .. tostring(math.floor(tonumber(placement.offsetX) or 0)) .. "  Y " .. tostring(math.floor(tonumber(placement.offsetY) or 0)) .. " · 大小 " .. size)
            local caps = {}
            if def.SupportsResize ~= false then caps[#caps + 1] = "尺寸" end
            if def.SupportsFont ~= false then caps[#caps + 1] = "字体" end
            if def.SupportsBackground ~= false then caps[#caps + 1] = "背景" end
            if def.SupportsCompact ~= false then caps[#caps + 1] = "紧凑" end
            if def.SupportsClickThrough == true then caps[#caps + 1] = "穿透" end
            if def.SupportsTitle == true then caps[#caps + 1] = "标题" end
            self.detailCaps:SetText("能力：" .. (#caps > 0 and table.concat(caps, " / ") or "此 HUD 由专业模块管理外观"))
        end

        self.show:Enable(has); self.show:SetText(has and (placement.visible and "隐藏 HUD" or "显示 HUD") or "显示")
        self.collapse:Show(has and def.SupportsCollapsed ~= false); self.collapse:Enable(has and def.SupportsCollapsed ~= false); self.collapse:SetText(has and S.HudManager:IsCollapsed(id) and "展开" or "折叠")
        self.lock:Enable(has); self.lock:SetText(has and placement.locked and "解锁" or "锁定")
        self.pass:Show(has and def.SupportsClickThrough == true); self.pass:Enable(has and def.SupportsClickThrough == true); self.pass:SetText(has and placement.clickThrough and "穿透：开" or "穿透：关")
        self.titleVisible:Show(has and def.SupportsTitle == true); self.titleVisible:Enable(has and def.SupportsTitle == true); self.titleVisible:SetText(has and placement.titleVisible == false and "标题：隐" or "标题：显")
        self.find:Enable(has); self.resetPos:Enable(has)
        self.resetSize:Show(has and def.SupportsResize ~= false); self.resetSize:Enable(has and def.SupportsResize ~= false)

        local fontCap = has and def.SupportsFont ~= false
        self.fontMinus:Show(fontCap); self.fontPlus:Show(fontCap); self.fontInherit:Show(fontCap)
        if fontCap then self.fontInherit:SetText(placement.fontInherited ~= false and ("继承 " .. Percent(S.HudManager:GetEffectiveFontScale(id))) or ("独立 " .. Percent(S.HudManager:GetEffectiveFontScale(id)))) end

        local bgCap = has and def.SupportsBackground ~= false
        self.bg:Show(bgCap); self.bgInherit:Show(bgCap)
        if bgCap then
            self.bg:SetText("背景 " .. Percent(S.HudManager:GetEffectiveBackgroundAlpha(id)))
            self.bgInherit:SetText(placement.backgroundInherited ~= false and "继承背景" or "独立背景")
        end

        local compactCap = has and def.SupportsCompact ~= false
        self.compact:Show(compactCap); self.compactInherit:Show(compactCap)
        if compactCap then
            self.compact:SetText(S.HudManager:IsCompact(id) and "紧凑：开" or "紧凑：关")
            self.compactInherit:SetText(placement.compactInherited ~= false and "继承紧凑" or "独立紧凑")
        end

        local canOpenModule = has and def.ModuleId ~= "" and S.ModuleManager ~= nil and S.ModuleManager:IsRegistered(def.ModuleId)
        self.moduleSettings:Show(canOpenModule); self.moduleSettings:Enable(canOpenModule)
        self.resetTitle:Show(has and def.SupportsTitle == true); self.resetTitle:Enable(has and def.SupportsTitle == true)
        self.resetAppearance:Enable(has); self.resetAll:Enable(has)
        self.resetAll:SetText(has and self.resetAllArmedId == id and self.resetAllArmedAt > 0 and "再次确认" or "全部恢复")

        local titleCap = has and def.SupportsTitle == true
        self.titleEditLabel:Show(titleCap)
        self.titleApply:Show(titleCap and self.titleEdit ~= nil); self.titleApply:Enable(titleCap and self.titleEdit ~= nil)
        if self.titleEdit ~= nil then
            self.titleEdit:Show(titleCap)
            if titleCap and self.titleEdit.SetText ~= nil then self.titleEdit:SetText(tostring(placement.customTitle or "")) end
        end
    end

    function page:Refresh()
        local now = S.NowMs and S.NowMs() or 0
        if now - (tonumber(self.recoverArmedAt) or 0) > 5000 then self.recoverArmedAt = 0 end
        if now - (tonumber(self.resetAllArmedAt) or 0) > 5000 then self.resetAllArmedAt, self.resetAllArmedId = 0, nil end
        if now - (tonumber(self.profileDeleteArmedAt) or 0) > 5000 then self.profileDeleteArmedAt, self.profileDeleteArmedName = 0, nil end

        local overview = S.HudManager:GetOverview()
        self.overviewStats:SetText(string.format("注册 %d · 显示 %d/%d · 锁定 %d · 穿透 %d · 折叠 %d", overview.total, overview.effectiveVisible, overview.preferredVisible, overview.locked, overview.clickThrough, overview.collapsed))
        self.edit:SetText(S.HudManager:IsEditMode() and "编辑：开" or "编辑：关")
        self.unlock:SetText(S.HudManager:IsTemporaryUnlockAll() and "解锁：开" or "临时解锁")
        self.unlock:Enable(S.HudManager:IsEditMode())
        self.snap:SetText(S.State.settings.hudSnapEnabled ~= false and "吸附：开" or "吸附：关")
        self.temp:SetText(S.HudManager.temporaryHidden and "恢复显示" or "临时隐藏")
        self.recover:SetText(self.recoverArmedAt > 0 and "再次确认" or "恢复全部")
        self.globalFontMinus:SetText("全局字 -")
        self.globalFontPlus:SetText("全局字 +")
        self.globalBg:SetText("背景 " .. Percent(S.State.settings.globalHudBackgroundAlpha))
        self.globalCompact:SetText(S.State.settings.globalCompactMode == true and "紧凑：开" or "紧凑：关")

        local rows = BuildHudRows()
        self.rows = rows
        self.table:SetItems(rows, HudRowsRevision(rows))
        if self.selectedId == nil and #rows > 0 then self.selectedId = rows[1].id end
        local selectedIndex = nil
        for index, row in ipairs(rows) do if row.id == self.selectedId then selectedIndex = index; break end end
        if selectedIndex == nil and #rows > 0 then selectedIndex, self.selectedId = 1, rows[1].id end
        if selectedIndex ~= nil then self.table:SetSelectedIndex(selectedIndex) end
        self:RefreshInspector()

        local name = ProfileName()
        local profileStore = type(S.State.profiles) == "table" and S.State.profiles or {}
        local hudProfiles = type(profileStore.huds) == "table" and profileStore.huds or {}
        local hasProfiles = S.Profiles and S.Profiles:NextName("hud", "") ~= nil
        self.saveProfile:Enable(self.profileEdit ~= nil)
        self.nextProfile:Enable(hasProfiles)
        self.applyProfile:Enable(name ~= "" and type(hudProfiles[name]) == "table")
        self.deleteProfile:Enable(name ~= "" and type(hudProfiles[name]) == "table")
        self.deleteProfile:SetText(self.profileDeleteArmedName == name and self.profileDeleteArmedAt > 0 and "再删" or "删除")
        return true
    end

    local function LayoutButtonFlow(buttons, parentPanel, startY, width, scale, rowHeight, gap)
        local x, y = 8 * scale, startY
        local right = math.max(x + 1, width - 8 * scale)
        local lineH = rowHeight or 24 * scale
        local spacing = gap or 4 * scale
        for _, button in ipairs(buttons) do
            if button ~= nil and (button.IsVisible == nil or button:IsVisible()) then
                local desired = (tonumber(button.rsDesignWidth) or 64) * scale
                local bw = math.min(math.max(42 * scale, desired), math.max(42 * scale, right - 8 * scale))
                if x > 8 * scale and x + bw > right then x, y = 8 * scale, y + lineH + spacing end
                button:SetExtent(bw, lineH); S.UI:SetAnchor(button, parentPanel, x, y)
                x = x + bw + spacing
            end
        end
        return y + lineH
    end

    function page:ApplyLayout(spec)
        S.UI:SetAnchor(self.root, parent, 0, 0, "hud")
        S.UI:SetExtent(self.root, spec.contentWidth, spec.contentHeight, "hud")
        local scale = S.Layout:GetContext().addonScale
        local pad, gap = 10 * scale, 7 * scale
        local full = math.max(1, spec.contentWidth - pad * 2)

        S.UI:SetExtent(self.title, full, 27 * scale, "hud"); S.UI:SetAnchor(self.title, self.root, pad, 5 * scale, "hud")
        S.UI:SetExtent(self.note, full, 20 * scale, "hud"); S.UI:SetAnchor(self.note, self.root, pad, 31 * scale, "hud")

        local overviewY, overviewH = 54 * scale, 77 * scale
        S.UI:SetExtent(self.overview, full, overviewH, "hud"); S.UI:SetAnchor(self.overview, self.root, pad, overviewY, "hud")
        S.UI:SetExtent(self.overviewTitle, 112 * scale, 20 * scale, "hud"); S.UI:SetAnchor(self.overviewTitle, self.overview, 8 * scale, 5 * scale, "hud")
        S.UI:SetExtent(self.overviewStats, math.max(1, full - 130 * scale), 20 * scale, "hud"); S.UI:SetAnchor(self.overviewStats, self.overview, 120 * scale, 5 * scale, "hud")
        LayoutButtonFlow(self.globalButtons, self.overview, 31 * scale, full, scale, 23 * scale, 4 * scale)

        local profileH = 63 * scale
        local profileY = math.max(overviewY + overviewH + gap, spec.contentHeight - profileH - 6 * scale)
        S.UI:SetExtent(self.profile, full, profileH, "hud"); S.UI:SetAnchor(self.profile, self.root, pad, profileY, "hud")
        S.UI:SetExtent(self.profileLabel, 92 * scale, 20 * scale, "hud"); S.UI:SetAnchor(self.profileLabel, self.profile, 8 * scale, 5 * scale, "hud")
        S.UI:SetExtent(self.profileHint, math.max(1, full - 108 * scale), 20 * scale, "hud"); S.UI:SetAnchor(self.profileHint, self.profile, 102 * scale, 5 * scale, "hud")
        local px = 8 * scale
        if self.profileEdit ~= nil then
            local editW = math.max(82 * scale, math.min(160 * scale, full * 0.28))
            self.profileEdit:SetExtent(editW, 24 * scale); S.UI:SetAnchor(self.profileEdit, self.profile, px, 31 * scale, "hud"); px = px + editW + 5 * scale
        end
        local remain = math.max(1, full - px - 8 * scale)
        local bw = math.max(40 * scale, (remain - 5 * scale * (#self.profileButtons - 1)) / #self.profileButtons)
        for _, button in ipairs(self.profileButtons) do button:SetExtent(bw, 24 * scale); S.UI:SetAnchor(button, self.profile, px, 31 * scale, "hud"); px = px + bw + 5 * scale end

        local centerY = overviewY + overviewH + gap
        local centerH = math.max(80 * scale, profileY - centerY - gap)
        local stacked = full < 660 * scale
        local listX, listY, listW, listH
        local inspectorX, inspectorY, inspectorW, inspectorH
        if not stacked then
            listW = math.max(240 * scale, full * 0.43)
            inspectorW = math.max(1, full - listW - gap)
            listX, listY, listH = pad, centerY, centerH
            inspectorX, inspectorY, inspectorH = pad + listW + gap, centerY, centerH
        else
            local topH = math.max(120 * scale, centerH * 0.44)
            listX, listY, listW, listH = pad, centerY, full, topH
            inspectorX, inspectorY, inspectorW, inspectorH = pad, centerY + topH + gap, full, math.max(1, centerH - topH - gap)
        end

        S.UI:SetExtent(self.listCard, listW, listH, "hud"); S.UI:SetAnchor(self.listCard, self.root, listX, listY, "hud")
        S.UI:SetExtent(self.listTitle, math.max(1, listW - 16 * scale), 21 * scale, "hud"); S.UI:SetAnchor(self.listTitle, self.listCard, 8 * scale, 5 * scale, "hud")
        S.UI:SetExtent(self.listHint, math.max(1, listW - 16 * scale), 18 * scale, "hud"); S.UI:SetAnchor(self.listHint, self.listCard, 8 * scale, 26 * scale, "hud")
        self.table:Layout(8 * scale, 47 * scale, math.max(1, listW - 16 * scale), math.max(1, listH - 55 * scale))

        S.UI:SetExtent(self.inspector, inspectorW, inspectorH, "hud"); S.UI:SetAnchor(self.inspector, self.root, inspectorX, inspectorY, "hud")
        local inner = math.max(1, inspectorW - 16 * scale)
        S.UI:SetExtent(self.detailTitle, inner, 22 * scale, "hud"); S.UI:SetAnchor(self.detailTitle, self.inspector, 8 * scale, 5 * scale, "hud")
        S.UI:SetExtent(self.detailState, inner, 19 * scale, "hud"); S.UI:SetAnchor(self.detailState, self.inspector, 8 * scale, 28 * scale, "hud")
        S.UI:SetExtent(self.detailGeometry, inner, 19 * scale, "hud"); S.UI:SetAnchor(self.detailGeometry, self.inspector, 8 * scale, 48 * scale, "hud")
        S.UI:SetExtent(self.detailCaps, inner, 19 * scale, "hud"); S.UI:SetAnchor(self.detailCaps, self.inspector, 8 * scale, 68 * scale, "hud")

        local buttonsEnd = LayoutButtonFlow(self.detailButtons, self.inspector, 93 * scale, inspectorW, scale, 23 * scale, 4 * scale)
        local titleY = math.min(math.max(buttonsEnd + 5 * scale, 94 * scale), math.max(94 * scale, inspectorH - 29 * scale))
        S.UI:SetExtent(self.titleEditLabel, 58 * scale, 22 * scale, "hud"); S.UI:SetAnchor(self.titleEditLabel, self.inspector, 8 * scale, titleY + 1 * scale, "hud")
        local titleX = 70 * scale
        local applyW = 48 * scale
        if self.titleEdit ~= nil then
            self.titleEdit:SetExtent(math.max(60 * scale, inspectorW - titleX - applyW - 20 * scale), 24 * scale)
            S.UI:SetAnchor(self.titleEdit, self.inspector, titleX, titleY, "hud")
        end
        self.titleApply:SetExtent(applyW, 24 * scale); S.UI:SetAnchor(self.titleApply, self.inspector, inspectorW - applyW - 8 * scale, titleY, "hud")

        self:Refresh()
    end

    page:Refresh()
    S.UI.pages.hud = page
    return page
end

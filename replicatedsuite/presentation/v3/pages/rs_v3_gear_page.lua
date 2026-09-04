------------------------------------------------------------------------
-- Replicated Suite V3 - Gear / Title Page M5
--
-- Two-column loadout editor: the left management rail stays compact while the
-- right side shows all 19 equipment slots + title as two semantic 10-row groups.
-- Larger rows prioritize fast visual configuration over dense spreadsheet data.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI, D = S.RSUI, S.UIV3Design
local PageHost = S.UIV3 and S.UIV3.PageHost or nil
local Feature = S.Features and S.Features.Gear or nil
if type(RSUI) ~= "table" or type(D) ~= "table" or type(PageHost) ~= "table" or type(Feature) ~= "table" then return end
local ROUTE = "combat.gear"

local Trim = S.Utils.Trim
-- Both edit fields on this page are RSUI TextInput components (WU1 layout
-- migration). Read/write through the component API first so the layout-owned
-- control never gets a text value written behind the component's back; the raw
-- native branch stays as a fallback for any legacy surface.
local function SetNativeText(widget, text)
    if widget == nil then return false end
    if type(widget.SetValue) == "function" then return widget:SetValue(tostring(text or "")) end
    if S.UI ~= nil and type(S.UI.SetText) == "function" then
        return S.UI:SetText(widget, tostring(text or ""), widget.rsUiOwner or "v3:gear_page")
    end
    return false
end
local function GetNativeText(widget)
    if widget == nil then return "" end
    -- GetDraftValue() reads the live native text even before the field commits,
    -- which is exactly what the Create/Rename actions need when the user clicks
    -- the button without leaving the edit box.
    if type(widget.GetDraftValue) == "function" then return tostring(widget:GetDraftValue() or "") end
    if type(widget.GetText) ~= "function" then return "" end
    local ok, value = pcall(function() return widget:GetText() end)
    return ok and tostring(value or "") or ""
end
local function EnhancementText(name)
    local sign, number = tostring(name or ""):match("^([%+%-]?)(%d+)%s+")
    if number == nil then return "--" end
    if sign == "" then sign = "+" end
    return sign .. tostring(number)
end
local function ModifierCount(signature)
    local text = Trim(signature)
    if text == "" then return 0 end
    local count = 1
    for _ in text:gmatch(";") do count = count + 1 end
    return count
end
local function SlotCategory(slot)
    slot = tonumber(slot)
    if S.Services.GearV3:IsWeaponSlot(slot) then return "武器" end
    if slot == 2 or slot == 10 or slot == 11 or slot == 12 or slot == 13 then return "饰品" end
    if slot == 28 then return "时装" end
    return "防具"
end

local function CompactValidationText(text)
    local map = {
        ["未检查"] = "未查",
        ["不匹配"] = "不符",
        ["未设置"] = "未设",
    }
    return map[tostring(text or "")] or tostring(text or "")
end

local function CompactSavedItemText(name, enhance, grade, modifierCount, isTitle)
    local base = tostring(name or "")
    if isTitle ~= true then base = base:gsub("^[%+%-]?%d+%s+", "") end
    if isTitle == true or base == "（空）" or base == "（未设置）" then return base end
    local parts = {}
    if tostring(enhance or "--") ~= "--" then parts[#parts + 1] = tostring(enhance) end
    if tonumber(grade) ~= nil then parts[#parts + 1] = "品质" .. tostring(math.floor(tonumber(grade))) end
    if tonumber(modifierCount) ~= nil and tonumber(modifierCount) > 0 then parts[#parts + 1] = tostring(math.floor(tonumber(modifierCount))) .. "词条" end
    if #parts == 0 then return base end
    return base .. " · " .. table.concat(parts, "·")
end

local function BuildPage(parent, route)
    local root, rootErr = D:PageRoot(parent, "v3_page_gear")
    if root == nil then return nil, "页面根组件创建失败：" .. tostring(rootErr or "未知错误") end
    root.pageConsumerHeld = false
    root.selectedId = nil
    root.draft = nil
    root.validation = nil
    root.deleteArmedUntil = 0

    D:PageHeader(root, "v3_gear_header", "换装 / 称号",
        "装备与效果称号属于同一套方案。右侧按防具/时装与饰品/武器/称号双列展示，点击任意行即可切换参与。",
        "刷新", function() Feature.Commands:RefreshProjection("page_manual"); root:Refresh(); return true end)

    local body = RSUI:HorizontalBox({
        id = "v3_gear_body", parent = root, gap = 7,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })

    ------------------------------------------------------------------------
    -- Left: plan library + all plan-management controls. This deliberately
    -- consumes the blank area under short plan lists so the right editor can
    -- devote nearly its full height to the actual equipment configuration.
    ------------------------------------------------------------------------
    local left = RSUI:Border({
        id = "v3_gear_left", parent = body, padding = 6, variant = "card", gradient = true,
        slot = { size = "fixed", width = 210, vAlign = "fill" },
    })
    -- The management rail used to be one flat VerticalBox of 14 controls with no
    -- visual grouping (the "杂乱/丑陋" the user flagged). It is now a scrollable
    -- stack of titled GroupBoxes so the rail stays operable at any window height
    -- and each control cluster reads as a single semantic unit. Priority order:
    -- data source (方案库) -> edit/commit/apply (当前方案) -> quick participation
    -- presets (参与范围) -> screen+snap (屏幕快捷与吸附) -> order/delete
    -- (顺序与删除) -> live feedback (状态与反馈). Lower groups scroll instead of
    -- clipping on short windows, so the layout never regresses to the old soup.
    local leftStack = RSUI:ScrollBox({
        id = "v3_gear_left_scroll", parent = left, orientation = "vertical", gap = 10, padding = 4,
        scrollbar = true, reserveScrollbar = true, scrollbarWidth = 12, scrollbarGap = 3,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })

    -- Titled section: a soft GroupBox wrapping a single VerticalBox content. The
    -- helper exists only so every group shares identical header/surface tokens.
    local function GearGroup(parent, id, title)
        local box = RSUI:GroupBox({ id = id, parent = parent, title = title, variant = "soft", gap = 4, padding = 8, slot = { size = "auto", hAlign = "fill" } })
        local inner = RSUI:VerticalBox({ id = id .. "_inner", parent = box, gap = 4 })
        return box, inner
    end

    ------------------------------------------------------------------------
    -- Group 1: 方案库 (plan data source + identity)
    ------------------------------------------------------------------------
    local gLib, gLibInner = GearGroup(leftStack, "v3_gear_group_library", "方案库")
    -- WU1: the input/action pair used to be two raw native widgets pinned at
    -- hand-computed pixels (x=4 / x=138, width 130 / 54) inside the host panel.
    -- That island was invisible to Measure/Arrange, so any change to the left
    -- rail width or UI scale pushed the button out of the panel. Both controls
    -- are now declarative RSUI children: the input absorbs the remaining width
    -- while the button keeps a fixed 54px.
    local createHost = RSUI:Panel({ id = "v3_gear_create_host", parent = gLibInner, variant = "soft", height = 31, slot = { size = "fixed", height = 31, hAlign = "fill" } })
    local createRow = RSUI:HorizontalBox({ id = "v3_gear_create_row", parent = createHost, gap = 4, padding = 4, slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" } })
    local createEdit = RSUI:TextInput({ id = "v3_gear_create_edit", parent = createRow, maxLength = 32, height = 23, slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "center" } })
    local createButton = RSUI:Button({ id = "v3_gear_create_button", parent = createRow, text = "新建", compact = true, slot = { size = "fixed", width = 54, vAlign = "center" } })

    local setTable = RSUI:TableView({
        id = "v3_gear_sets", parent = gLibInner, items = {}, rowHeight = 22, headerHeight = 22, desiredRows = 4,
        scrollbar = true, selectable = true, selectionMode = "single", columnResize = true,
        getKey = function(item) return item and item.id or nil end,
        onSelectionChanged = function(_, _, view)
            if root.syncingPlanSelection == true then return end
            root.selectedId = view and type(view.GetSelectedKey) == "function" and view:GetSelectedKey() or nil
            root:LoadDraft()
        end,
        columns = {
            { id = "name", title = "方案", field = "name", size = "fill", minWidth = 80, fill = 1 },
            { id = "state", title = "状态", field = "stateText", size = "fixed", width = 58, minWidth = 40, getTone = function(item) return item and item.configured and "green" or "muted" end },
        },
        slot = { size = "fixed", height = 100, hAlign = "fill", vAlign = "fill" },
    })

    local leftStats = RSUI:Text({
        id = "v3_gear_left_stats", parent = gLibInner, text = "方案 0 · 已配置 0 · 快捷按钮 0",
        fontSize = 8, tone = "muted", overflow = "ellipsis", slot = { size = "fixed", height = 18 },
    })

    -- WU1: same migration as the create row - declarative input/fixed button
    -- instead of pixel-pinned native widgets (x=4 / x=137, width 129 / 55).
    local nameHost = RSUI:Panel({ id = "v3_gear_name_host", parent = gLibInner, variant = "soft", height = 30, slot = { size = "fixed", height = 30, hAlign = "fill" } })
    local nameRow = RSUI:HorizontalBox({ id = "v3_gear_name_row", parent = nameHost, gap = 4, padding = 4, slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" } })
    local nameEdit = RSUI:TextInput({ id = "v3_gear_name_edit", parent = nameRow, maxLength = 36, height = 22, slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "center" } })
    local saveName = RSUI:Button({ id = "v3_gear_name_button", parent = nameRow, text = "改名", compact = true, slot = { size = "fixed", width = 55, vAlign = "center" } })

    ------------------------------------------------------------------------
    -- Group 2: 当前方案 (read current -> save -> validate -> apply)
    ------------------------------------------------------------------------
    local gCur, gCurInner = GearGroup(leftStack, "v3_gear_group_current", "当前方案")
    local action1 = RSUI:HorizontalBox({ id = "v3_gear_actions_1", parent = gCurInner, gap = 4, slot = { size = "fixed", height = 25, hAlign = "fill" } })
    local capture = RSUI:Button({ id = "v3_gear_capture", parent = action1, text = "获取当前", compact = true, slot = { size = "fill", fill = 1 } })
    local save = RSUI:Button({ id = "v3_gear_save", parent = action1, text = "保存方案", compact = true, slot = { size = "fill", fill = 1 } })
    local action2 = RSUI:HorizontalBox({ id = "v3_gear_actions_2", parent = gCurInner, gap = 4, slot = { size = "fixed", height = 25, hAlign = "fill" } })
    local validate = RSUI:Button({ id = "v3_gear_validate", parent = action2, text = "检查状态", compact = true, slot = { size = "fill", fill = 1 } })
    local apply = RSUI:Button({ id = "v3_gear_apply", parent = action2, text = "立即换装", compact = true, slot = { size = "fill", fill = 1 } })

    ------------------------------------------------------------------------
    -- Group 3: 参与范围 (quick participation presets)
    ------------------------------------------------------------------------
    local gPart, gPartInner = GearGroup(leftStack, "v3_gear_group_participation", "参与范围")
    local presets1 = RSUI:HorizontalBox({ id = "v3_gear_presets_1", parent = gPartInner, gap = 4, slot = { size = "fixed", height = 24, hAlign = "fill" } })
    local pAll = RSUI:Button({ id = "v3_gear_p_all", parent = presets1, text = "全部", compact = true, slot = { size = "fill", fill = 1 } })
    local pWeapon = RSUI:Button({ id = "v3_gear_p_weapon", parent = presets1, text = "仅武器", compact = true, slot = { size = "fill", fill = 1 } })
    local pArmor = RSUI:Button({ id = "v3_gear_p_armor", parent = presets1, text = "防具饰品", compact = true, slot = { size = "fill", fill = 1 } })
    local presets2 = RSUI:HorizontalBox({ id = "v3_gear_presets_2", parent = gPartInner, gap = 4, slot = { size = "fixed", height = 24, hAlign = "fill" } })
    local pTitle = RSUI:Button({ id = "v3_gear_p_title", parent = presets2, text = "仅称号", compact = true, slot = { size = "fill", fill = 1 } })
    local pNone = RSUI:Button({ id = "v3_gear_p_none", parent = presets2, text = "清空参与", compact = true, slot = { size = "fill", fill = 1 } })

    ------------------------------------------------------------------------
    -- Group 4: 屏幕快捷与吸附
    ------------------------------------------------------------------------
    local gSnap, gSnapInner = GearGroup(leftStack, "v3_gear_group_screen", "屏幕快捷与吸附")
    local screenButton = RSUI:Button({ id = "v3_gear_screen_button", parent = gSnapInner, text = "屏幕快捷按钮：--", compact = true, slot = { size = "fixed", height = 24, hAlign = "fill" } })
    local snapActions = RSUI:HorizontalBox({ id = "v3_gear_snap_actions", parent = gSnapInner, gap = 4, slot = { size = "fixed", height = 24, hAlign = "fill" } })
    local snapToggle = RSUI:Toggle({
        id = "v3_gear_snap_toggle", parent = snapActions, onText = "按钮吸附：开", offText = "按钮吸附：关", compact = true,
        get = function() return Feature:GetQuickSnapSettings().enabled == true end,
        set = function(value) return Feature.Commands:ApplyQuickSnapEnabled(value) end,
        storeId = "v3.gear.index", persistDelayMs = 300, persistReason = "gear_quick_snap_enabled",
        slot = { size = "fill", fill = 1, hAlign = "fill" },
    })
    local snapSettings = RSUI:Button({ id = "v3_gear_snap_settings", parent = snapActions, text = "设置", compact = true, slot = { size = "fixed", width = 58 } })

    ------------------------------------------------------------------------
    -- Group 5: 顺序与删除
    ------------------------------------------------------------------------
    local gOrder, gOrderInner = GearGroup(leftStack, "v3_gear_group_order", "顺序与删除")
    local orderActions = RSUI:HorizontalBox({ id = "v3_gear_order_actions", parent = gOrderInner, gap = 4, slot = { size = "fixed", height = 24, hAlign = "fill" } })
    local moveUp = RSUI:Button({ id = "v3_gear_up", parent = orderActions, text = "上移", compact = true, slot = { size = "fill", fill = 1 } })
    local moveDown = RSUI:Button({ id = "v3_gear_down", parent = orderActions, text = "下移", compact = true, slot = { size = "fill", fill = 1 } })
    local deleteButton = RSUI:Button({ id = "v3_gear_delete", parent = orderActions, text = "删除", compact = true, slot = { size = "fill", fill = 1 } })

    ------------------------------------------------------------------------
    -- Group 6: 状态与反馈 (live runtime + editor status)
    ------------------------------------------------------------------------
    local gStatus, gStatusInner = GearGroup(leftStack, "v3_gear_group_status", "状态与反馈")
    local runtimeStatus = RSUI:Text({
        id = "v3_gear_runtime_state", parent = gStatusInner, text = "运行：空闲",
        fontSize = 8, tone = "muted", overflow = "ellipsis", slot = { size = "fixed", height = 17 },
    })
    local status = RSUI:Text({
        id = "v3_gear_editor_state", parent = gStatusInner, text = "请选择或新建方案。",
        fontSize = 8, tone = "muted", overflow = "ellipsis", slot = { size = "fixed", height = 18 },
    })

    ------------------------------------------------------------------------
    -- Right: almost all available height belongs to the actual configuration.
    ------------------------------------------------------------------------
    local right = RSUI:Border({
        id = "v3_gear_right", parent = body, padding = 6, variant = "card", gradient = true,
        slot = { size = "fill", fill = 1, vAlign = "fill" },
    })
    local rightStack = RSUI:VerticalBox({ id = "v3_gear_right_stack", parent = right, gap = 3 })

    local titleText = RSUI:Text({
        id = "v3_gear_editor_title", parent = rightStack, text = "请选择方案", fontSize = 11, tone = "strong", overflow = "ellipsis",
        slot = { size = "fixed", height = 20 },
    })
    local editorMeta = RSUI:Text({
        id = "v3_gear_editor_meta", parent = rightStack, text = "参与 0/20 · 武器 0 · 其它/称号 0",
        fontSize = 8, tone = "muted", overflow = "ellipsis", slot = { size = "fixed", height = 17 },
    })

    local function ToggleManagedItem(item)
        if type(item) ~= "table" or type(root.draft) ~= "table" then return false end
        if item.isTitle == true then
            if type(root.draft.title) ~= "table" or type(root.draft.title.effect) ~= "table" or root.draft.title.effect.id == nil then
                root:SetStatus("当前方案没有可切换的效果称号，请重新获取当前配置。", "yellow")
                return false
            end
            root.draft.title.apply = root.draft.title.apply ~= true
        else
            for _, saved in ipairs(root.draft.items or {}) do
                if tonumber(saved.slot) == tonumber(item.slot) and saved.empty ~= true then
                    saved.managed = saved.managed == false
                    break
                end
            end
        end
        root.validation = nil
        root:RefreshEditor()
        return true
    end

    local editorColumns = {
        { id = "participate", title = "参与", field = "managedText", size = "fixed", width = 40, minWidth = 28, getTone = function(item) return item and item.managed and "green" or "muted" end },
        { id = "slot", title = "部位", field = "slotName", size = "fixed", width = 48, minWidth = 30 },
        { id = "item", title = "装备 / 属性", field = "compactText", size = "fill", minWidth = 90, fill = 1 },
        { id = "verify", title = "状态", field = "validationShort", size = "fixed", width = 44, minWidth = 28, getTone = function(item) return item and item.validationTone or "muted" end },
    }

    local dualHost = RSUI:HorizontalBox({
        id = "v3_gear_dual_editor", parent = rightStack, gap = 6,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })

    local armorPanel = RSUI:Border({
        id = "v3_gear_armor_panel", parent = dualHost, padding = 4, variant = "soft",
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })
    local armorStack = RSUI:VerticalBox({ id = "v3_gear_armor_stack", parent = armorPanel, gap = 3 })
    local armorTitle = RSUI:Text({
        id = "v3_gear_armor_title", parent = armorStack, text = "防具 / 时装 · 0/10 参与",
        fontSize = 10, tone = "strong", slot = { size = "fixed", height = 21 },
    })
    local armorTable = RSUI:TableView({
        id = "v3_gear_armor_slots", parent = armorStack, items = {}, rowHeight = 28, headerHeight = 25, desiredRows = 10,
        scrollbar = true, selectable = false, columnResize = true, rowFontSize = 11, headerFontSize = 10,
        onItemActivated = ToggleManagedItem,
        columns = editorColumns,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })

    local combatPanel = RSUI:Border({
        id = "v3_gear_combat_panel", parent = dualHost, padding = 4, variant = "soft",
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })
    local combatStack = RSUI:VerticalBox({ id = "v3_gear_combat_stack", parent = combatPanel, gap = 3 })
    local combatTitle = RSUI:Text({
        id = "v3_gear_combat_title", parent = combatStack, text = "饰品 / 武器 / 称号 · 0/10 参与",
        fontSize = 10, tone = "strong", slot = { size = "fixed", height = 21 },
    })
    local combatTable = RSUI:TableView({
        id = "v3_gear_combat_slots", parent = combatStack, items = {}, rowHeight = 28, headerHeight = 25, desiredRows = 10,
        scrollbar = true, selectable = false, columnResize = true, rowFontSize = 11, headerFontSize = 10,
        onItemActivated = ToggleManagedItem,
        columns = editorColumns,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })



    function root:SetStatus(text, tone)
        status:SetText(text or "")
        status:SetTone(tone or "muted")
    end
    function root:FindSelectedMeta() return self.selectedId and Feature:FindSet(self.selectedId) or nil end

    function root:LoadDraft()
        self.validation = nil
        if self.selectedId == nil then self.draft = nil; self:RefreshEditor(); return true end
        local draft, err = Feature:GetDraft(self.selectedId)
        if draft == nil then self.draft = nil; self:SetStatus(tostring(err), "red"); self:RefreshEditor(); return false end
        self.draft = draft
        SetNativeText(nameEdit, draft.name)
        self:SetStatus(draft.configured and "方案已载入；点击任意装备/称号行即可切换是否参与。" or "尚未配置，请穿好装备并选择效果称号后点击“获取当前”。", draft.configured and "muted" or "yellow")
        self:RefreshEditor()
        return true
    end

    function root:BuildSlotRows()
        local mismatchBySlot, titleMismatch = {}, false
        if type(self.validation) == "table" then
            for _, row in ipairs(self.validation.rows or {}) do
                if tonumber(row.slot) ~= nil then mismatchBySlot[tonumber(row.slot)] = true end
                if tostring(row.slotName or "") == "称号" then titleMismatch = true end
            end
        end
        local rows = {}
        for _, item in ipairs(type(self.draft) == "table" and self.draft.items or {}) do
            local empty = item.empty == true
            local managed = not empty and item.managed ~= false
            local verifyText, verifyTone = "未检查", "muted"
            if empty then verifyText, verifyTone = "空位", "muted"
            elseif not managed then verifyText, verifyTone = "忽略", "muted"
            elseif type(self.validation) == "table" then
                if mismatchBySlot[tonumber(item.slot)] == true then verifyText, verifyTone = "不匹配", "yellow"
                else verifyText, verifyTone = "匹配", "green" end
            end
            local grade = tonumber(item.grade)
            local enhance = empty and "--" or EnhancementText(item.name)
            local detail = enhance
            if not empty and grade ~= nil then detail = enhance .. "·品质" .. tostring(math.floor(grade)) end
            local modCount = empty and 0 or ModifierCount(item.modifierSignature)
            rows[#rows + 1] = {
                slot = item.slot,
                slotName = tostring(item.slotName or item.key or item.slot),
                name = empty and "（空）" or tostring(item.name or "未知装备"),
                managed = managed,
                managedText = empty and "--" or (managed and "参与" or "忽略"),
                kindText = SlotCategory(item.slot),
                detailText = detail,
                modifierText = empty and "--" or (modCount > 0 and (tostring(modCount) .. "词条") or "无"),
                compactText = CompactSavedItemText(empty and "（空）" or tostring(item.name or "未知装备"), enhance, grade, modCount, false),
                validationText = verifyText,
                validationShort = CompactValidationText(verifyText),
                validationTone = verifyTone,
            }
        end

        local title = type(self.draft) == "table" and self.draft.title or nil
        local hasTitle = type(title) == "table" and type(title.effect) == "table" and title.effect.id ~= nil
        local managed = hasTitle and title.apply == true
        local verifyText, verifyTone = "未检查", "muted"
        if not hasTitle then verifyText, verifyTone = "未设置", "muted"
        elseif not managed then verifyText, verifyTone = "忽略", "muted"
        elseif type(self.validation) == "table" then verifyText, verifyTone = titleMismatch and "不匹配" or "匹配", titleMismatch and "yellow" or "green" end
        rows[#rows + 1] = {
            isTitle = true,
            slot = nil,
            slotName = "效果称号",
            name = hasTitle and S.Services.GearV3:TitleText(title) or "（未设置）",
            managed = managed,
            managedText = hasTitle and (managed and "参与" or "忽略") or "--",
            kindText = "称号",
            detailText = "--",
            modifierText = "--",
            compactText = CompactSavedItemText(hasTitle and S.Services.GearV3:TitleText(title) or "（未设置）", "--", nil, 0, true),
            validationText = verifyText,
            validationShort = CompactValidationText(verifyText),
            validationTone = verifyTone,
        }
        return rows
    end

    function root:RefreshEditor()
        local draft = self.draft
        if type(draft) ~= "table" then
            titleText:SetText("请选择方案")
            SetNativeText(nameEdit, "")
            armorTable:SetItems({}, "gear:none:armor")
            combatTable:SetItems({}, "gear:none:combat")
            armorTitle:SetText("防具 / 时装 · 0/10 参与")
            combatTitle:SetText("饰品 / 武器 / 称号 · 0/10 参与")
            screenButton:SetText("屏幕快捷按钮：--")
            editorMeta:SetText("参与 0/20 · 武器 0 · 其它/称号 0")
            return true
        end

        titleText:SetText(tostring(draft.name) .. (draft.configured and " · 已配置" or " · 未配置") .. " · rev " .. tostring(draft.payloadRevision or 0))
        screenButton:SetText("屏幕快捷按钮：" .. (draft.quick ~= false and "显示" or "隐藏"))

        local rows = self:BuildSlotRows()
        local managed, weapon, other = 0, 0, 0
        for _, row in ipairs(rows) do
            if row.managed then
                managed = managed + 1
                if row.kindText == "武器" then weapon = weapon + 1 else other = other + 1 end
            end
        end
        editorMeta:SetText("参与 " .. tostring(managed) .. "/20 · 武器 " .. tostring(weapon) .. " · 其它/称号 " .. tostring(other))

        local armorRows, combatRows = {}, {}
        local armorManaged, combatManaged = 0, 0
        for _, row in ipairs(rows) do
            if row.kindText == "防具" or row.kindText == "时装" then
                armorRows[#armorRows + 1] = row
                if row.managed then armorManaged = armorManaged + 1 end
            else
                combatRows[#combatRows + 1] = row
                if row.managed then combatManaged = combatManaged + 1 end
            end
        end
        armorTitle:SetText("防具 / 时装 · " .. tostring(armorManaged) .. "/" .. tostring(#armorRows) .. " 参与")
        combatTitle:SetText("饰品 / 武器 / 称号 · " .. tostring(combatManaged) .. "/" .. tostring(#combatRows) .. " 参与")

        local token = table.concat({ "gear:draft", tostring(draft.id), tostring(draft.capturedAt or 0), tostring(draft.payloadRevision or 0), tostring(managed), tostring(self.validation and self.validation.checkedAt or 0) }, ":")
        armorTable:SetItems(armorRows, token .. ":armor")
        combatTable:SetItems(combatRows, token .. ":combat")
        return true
    end

    function root:RefreshRuntime()
        local r = S.Services.GearV3:GetRuntimeSnapshot()
        local state = r.busy and ("执行中 " .. tostring(r.index) .. "/" .. tostring(r.total)) or (r.stage == "FAILED" and "执行失败" or r.stage == "DONE" and "执行完成" or "空闲")
        local detail = Trim(r.message)
        local validationText = ""
        if self.validation ~= nil then validationText = self.validation.matched and " · 检查：完全匹配" or (" · 检查：" .. tostring(#(self.validation.rows or {})) .. " 项不匹配") end
        runtimeStatus:SetText("运行：" .. state .. validationText .. (detail ~= "" and (" · " .. detail) or ""))
        runtimeStatus:SetTone(r.stage == "FAILED" and "red" or (r.busy and "yellow" or (r.stage == "DONE" and "green" or "muted")))
    end

    function root:RefreshPlanList()
        local rows, revision = Feature:GetRows()
        local configured, quickCount, selectedIndex = 0, 0, nil
        local selectedId = self.selectedId ~= nil and tostring(self.selectedId) or nil
        for index, row in ipairs(rows or {}) do
            if selectedId ~= nil and tostring(row.id or "") == selectedId then selectedIndex = index end
            if row.configured then configured = configured + 1 end
            if row.quick then quickCount = quickCount + 1 end
        end

        -- Business state owns only the stable selected id.  The shared RSUI
        -- SelectionVisual owns every selected-row highlight; Gear no longer
        -- injects marker text, special tones, or a feature-specific "当前" row.
        if selectedId ~= nil and selectedIndex == nil then
            self.selectedId, self.draft, self.validation = nil, nil, nil
        end

        setTable:SetItems(rows, "gear:sets:" .. tostring(revision))
        self.syncingPlanSelection = true
        if selectedIndex ~= nil then
            setTable:SetSelectedIndex(selectedIndex)
            setTable:EnsureIndexVisible(selectedIndex)
        else
            setTable:ClearSelection()
        end
        self.syncingPlanSelection = false

        leftStats:SetText("方案 " .. tostring(#(rows or {})) .. " · 已配置 " .. tostring(configured) .. " · 快捷按钮 " .. tostring(quickCount))
        return true
    end

    function root:Refresh()
        self:RefreshPlanList()
        if snapToggle ~= nil and type(snapToggle.Render) == "function" then snapToggle:Render() end
        self:RefreshEditor()
        self:RefreshRuntime()
        return true
    end

    function root:CreateSet()
        local name = Trim(GetNativeText(createEdit)); if name == "" then name = "换装" .. tostring(Feature:GetSetCount() + 1) end
        local id, warning = Feature.Commands:CreateSet(name)
        if id == nil then self:SetStatus(tostring(warning), "red"); return false end
        SetNativeText(createEdit, "")
        self.selectedId = id
        self:LoadDraft()
        self:Refresh()
        if warning ~= nil then
            self:SetStatus(tostring(warning), "yellow")
        else
            self:SetStatus("方案已创建；独立屏幕快捷按钮已同步。保存配置后即可点击换装。", "green")
        end
        return true
    end

    function root:Capture()
        if self.selectedId == nil then self:SetStatus("请先选择方案", "yellow"); return false end
        local draft, err = Feature.Commands:CaptureDraft(self.selectedId)
        if draft == nil then self:SetStatus(tostring(err), "red"); return false end
        self.draft = draft
        self.validation = nil
        SetNativeText(nameEdit, draft.name)
        self:SetStatus("已读取 19 个装备部位和当前效果称号；直接点击表格行调整参与范围。", "green")
        self:RefreshEditor()
        return true
    end

    function root:Save()
        if type(self.draft) ~= "table" then self:SetStatus("请先选择方案", "yellow"); return false end
        local name = Trim(GetNativeText(nameEdit)); if name ~= "" then self.draft.name = name end
        local ok, err = Feature.Commands:SaveDraft(self.draft)
        if ok ~= true then self:SetStatus(tostring(err), "red"); return false end
        self:LoadDraft()
        self:Refresh()
        self:SetStatus("方案已安全保存；该方案的屏幕快捷按钮会立即同步。", "green")
        return true
    end

    function root:ApplyPreset(mode)
        if type(self.draft) ~= "table" then return false end
        local title = self.draft.title
        for _, item in ipairs(self.draft.items or {}) do
            if item.empty ~= true then
                if mode == "ALL" then item.managed = true
                elseif mode == "WEAPON" then item.managed = S.Services.GearV3:IsWeaponSlot(item.slot)
                elseif mode == "ARMOR" then item.managed = not S.Services.GearV3:IsWeaponSlot(item.slot)
                else item.managed = false end
            end
        end
        local hasTitle = type(title) == "table" and type(title.effect) == "table" and title.effect.id ~= nil
        if hasTitle then title.apply = mode == "ALL" or mode == "TITLE" end
        self.validation = nil
        self:RefreshEditor()
        return true
    end

    function root:OpenQuickSnapSettings()
        local modal = S.UIV3 and S.UIV3.GearQuickSettingsModalV3 or nil
        if type(modal) ~= "table" or type(modal.Open) ~= "function" then
            self:SetStatus("快捷按钮吸附设置暂不可用。", "red")
            return false
        end
        local ok, err = modal:Open()
        if ok ~= true then self:SetStatus(tostring(err or "打开吸附设置失败"), "red") end
        return ok
    end

    function root:ToggleQuick()
        if type(self.draft) ~= "table" then self:SetStatus("请先选择方案", "yellow"); return false end
        local nextValue = self.draft.quick == false
        local ok, warning = Feature.Commands:SetQuick(self.draft.id, nextValue)
        if ok ~= true then self:SetStatus(tostring(warning), "red"); return false end
        self.draft.quick = nextValue
        if warning ~= nil then
            self:SetStatus("方案显示设置已保存，但快捷按钮同步存在警告：" .. tostring(warning), "yellow")
        else
            self:SetStatus(nextValue and (self.draft.configured == true and "已显示该方案的独立屏幕快捷按钮；可自由拖到任意位置。" or "快捷按钮已显示；保存方案后即可点击换装。") or "已隐藏该方案的屏幕快捷按钮。", "green")
        end
        self:Refresh()
        return true
    end

    function root:Validate()
        if self.selectedId == nil then self:SetStatus("请先选择方案", "yellow"); return false end
        local result, err = Feature.Commands:Validate(self.selectedId)
        if result == nil then self:SetStatus(tostring(err), "red"); return false end
        self.validation = result
        self:SetStatus(result.matched and "当前装备和称号与方案完全一致。" or ("检测到 " .. tostring(#(result.rows or {})) .. " 项未匹配；对应行已标出。"), result.matched and "green" or "yellow")
        self:RefreshEditor()
        self:RefreshRuntime()
        return true
    end

    function root:Apply()
        if self.selectedId == nil then self:SetStatus("请先选择方案", "yellow"); return false end
        local ok, err = Feature.Commands:Start(self.selectedId)
        self:SetStatus(ok and "已启动换装事务。" or tostring(err), ok and "green" or "yellow")
        self:RefreshRuntime()
        return ok
    end

    function root:RenameOnly()
        if type(self.draft) ~= "table" then return false end
        local name = Trim(GetNativeText(nameEdit))
        local ok, err = Feature.Commands:Rename(self.draft.id, name)
        if ok ~= true then self:SetStatus(tostring(err), "red"); return false end
        self.draft.name = name
        self:SetStatus("方案名称已保存。", "green")
        self:Refresh()
        return true
    end

    function root:MoveSelected(delta)
        if self.selectedId == nil then return false end
        local ok, err = Feature.Commands:MoveSet(self.selectedId, delta)
        if ok ~= true then self:SetStatus(tostring(err), "red"); return false end
        self:Refresh()
        return true
    end

    function root:DeleteSelected()
        if self.selectedId == nil then return false end
        local now = S.NowMs and S.NowMs() or 0
        if now > (tonumber(self.deleteArmedUntil) or 0) then
            self.deleteArmedUntil = now + 3500
            deleteButton:SetText("确认")
            self:SetStatus("再次点击“确认”才会删除当前方案；3.5 秒后自动取消。", "yellow")
            return false
        end
        local id = self.selectedId
        self.deleteArmedUntil = 0
        deleteButton:SetText("删除")
        local ok, err = Feature.Commands:DeleteSet(id)
        if ok ~= true then self:SetStatus(tostring(err), "red"); return false end
        self.selectedId, self.draft, self.validation = nil, nil, nil
        self:SetStatus("方案已删除。", "green")
        self:Refresh()
        return true
    end

    -- Buttons keep a single RSUI-owned native OnClick handler. Late-bound page
    -- actions are assigned to the component action slot so enabled/release/event
    -- mux fences remain authoritative.
    createButton.onClick = function() return root:CreateSet() end
    saveName.onClick = function() return root:RenameOnly() end
    local bindings = {
        { capture, function() return root:Capture() end, "gear.capture", "读取中…" },
        { save, function() return root:Save() end, "gear.save", "保存中…" },
        { validate, function() return root:Validate() end, "gear.validate", "检查中…" },
        { apply, function() return root:Apply() end, "gear.apply", "启动中…" },
        { pAll, function() return root:ApplyPreset("ALL") end }, { pWeapon, function() return root:ApplyPreset("WEAPON") end }, { pArmor, function() return root:ApplyPreset("ARMOR") end },
        { pTitle, function() return root:ApplyPreset("TITLE") end }, { pNone, function() return root:ApplyPreset("NONE") end },
        { screenButton, function() return root:ToggleQuick() end }, { snapSettings, function() return root:OpenQuickSnapSettings() end },
        { moveUp, function() return root:MoveSelected(-1) end }, { moveDown, function() return root:MoveSelected(1) end }, { deleteButton, function() return root:DeleteSelected() end },
    }
    for _, pair in ipairs(bindings) do
        local button, execute, actionId, busyText = pair[1], pair[2], pair[3], pair[4]
        local handler = execute
        if actionId ~= nil and S.ActionRunner ~= nil then
            handler = function()
                return S.ActionRunner:Run({
                    id = actionId, button = button, idleText = button.spec and button.spec.text, busyText = busyText,
                    notify = false, execute = execute,
                })
            end
        end
        button.onClick = handler
    end

    function root:OnActivated()
        Feature.Commands:SetDisableWhenIdle(false)
        self.deleteArmedUntil = 0
        deleteButton:SetText("删除")
        local ok, err = Feature:AcquireTransient("page:gear")
        if ok ~= true then return false, err end
        self.pageConsumerHeld = true
        if S.Events ~= nil and type(S.Events.SubscribeInternal) == "function" then
            S.Events:UnsubscribeInternalOwner(self)
            S.Events:SubscribeInternal("v3.gear.updated", self, function() root:Refresh() end)
        end
        Feature.Commands:RefreshProjection("page_enter")
        self:Refresh()
        return true
    end

    function root:OnDeactivated()
        if S.Events ~= nil then S.Events:UnsubscribeInternalOwner(self) end
        self.deleteArmedUntil = 0
        deleteButton:SetText("删除")
        if self.pageConsumerHeld == true then Feature:ReleaseTransient("page:gear"); self.pageConsumerHeld = false end
        return true
    end

    function root:RefreshData(dirty)
        self:RefreshRuntime()
        return true
    end

    root.route = route
    return root
end

local ok, err = PageHost:RegisterFactory(ROUTE, BuildPage)
if ok ~= true then error(err) end

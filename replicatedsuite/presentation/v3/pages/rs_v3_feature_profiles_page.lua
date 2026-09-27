------------------------------------------------------------------------
-- Replicated Suite V3 - Feature Profiles Page
--
-- Presentation Proxy only. The page edits profile intent through
-- FeatureProfiles.Commands; FeatureRuntime remains the only lifecycle writer.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI, D = S.RSUI, S.UIV3Design
local PageHost = S.UIV3 and S.UIV3.PageHost or nil
local Feature = S.Features and S.Features.FeatureProfiles or nil
if type(RSUI) ~= "table" or type(D) ~= "table" or type(PageHost) ~= "table" or type(Feature) ~= "table" then return end

local ROUTE = "tools.feature_profiles"

-- 中文维护（2026-09-25，feature-profile-input-action-1）：Native EditBox 的 OnLostFocus
-- 可能晚于“新建/改名”按钮 OnClick。这里读取 TextInput 的 action draft，而不是只读已提交
-- Binding；否则用户已经看到并输入名称，命令仍会收到空字符串。Presentation 只读取草稿并
-- 提交给 Feature Commands，Store/方案 Authority 仍完全属于 FeatureProfiles。
local function ReadActionText(input)
    if input == nil then return "" end
    if type(input.GetActionValue) == "function" then return tostring(input:GetActionValue() or "") end
    if type(input.GetDraftValue) == "function" then return tostring(input:GetDraftValue() or "") end
    if type(input.GetValue) == "function" then return tostring(input:GetValue() or "") end
    return ""
end

local function BuildPage(parent, route)
    local root, rootErr = D:PageRoot(parent, "v3_page_feature_profiles")
    if root == nil then return nil, "页面根组件创建失败：" .. tostring(rootErr or "未知错误") end

    root.consumerHeld = false
    root.pageActive = false
    root.selectedProfileId = nil
    root.selectedFeatureId = nil

    D:PageHeader(root, "v3_feature_profiles_header", "功能方案",
        "创建任意方案并选择需要开启的功能。应用时开启方案内功能、关闭其它可控业务功能；各模块自己的配置、悬浮窗位置和业务数据不会被清空。",
        "刷新", function() return Feature.Commands:Refresh("feature_profiles_page_manual") end)

    local body = RSUI:HorizontalBox({
        id = "v3_feature_profiles_body", parent = root, gap = 7,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })

    ------------------------------------------------------------------------
    -- Left: profile library + profile-level commands.
    ------------------------------------------------------------------------
    local left = RSUI:Border({
        id = "v3_feature_profiles_left", parent = body, variant = "card", gradient = true, padding = 6,
        slot = { size = "fixed", width = 330, minWidth = 286, hAlign = "fill", vAlign = "fill" },
    })
    local leftStack = RSUI:VerticalBox({ id = "v3_feature_profiles_left_stack", parent = left, gap = 5 })

    RSUI:Text({ id = "v3_feature_profiles_library_title", parent = leftStack, text = "方案列表", fontSize = 11, tone = "strong",
        slot = { size = "fixed", height = 20, hAlign = "fill" } })

    local createRow = RSUI:HorizontalBox({ id = "v3_feature_profiles_create_row", parent = leftStack, gap = 5,
        slot = { size = "fixed", height = 29, hAlign = "fill" } })
    local createInput = RSUI:TextInput({ id = "v3_feature_profiles_create_name", parent = createRow, value = "", maxLength = 32,
        allowEmpty = false, placeholder = "新方案名称", slot = { size = "fill", fill = 1, minWidth = 118 } })
    local createButton = RSUI:Button({ id = "v3_feature_profiles_create", parent = createRow, text = "新建", compact = true,
        slot = { size = "fixed", width = 62 } })

    local profileTable = RSUI:TableView({
        id = "v3_feature_profiles_list", parent = leftStack, items = {}, rowHeight = 27, headerHeight = 27, desiredRows = 7,
        scrollbar = true, selectable = true, selectionMode = "single", columnResize = true, headerInteractive = false,
        getKey = function(row) return row and row.profileId or nil end,
        onSelectionChanged = function(_, _, view)
            local key = view and type(view.GetSelectedKey) == "function" and view:GetSelectedKey() or nil
            root.selectedProfileId = tonumber(key)
            root.selectedFeatureId = nil
            if root.selectedProfileId ~= nil then Feature.Commands:SelectProfile(root.selectedProfileId) end
            root:RefreshEditor(true)
        end,
        columns = {
            { id = "name", title = "方案", field = "name", size = "fill", minWidth = 110, fill = 1.3,
                getTone = function(row) return row and row.active and "green" or "default" end },
            { id = "modules", title = "开启", field = "moduleText", size = "fixed", width = 58, minWidth = 48 },
            { id = "quick", title = "按钮", field = "quickText", size = "fixed", width = 54, minWidth = 46,
                getTone = function(row) return row and row.quick and "accent" or "muted" end },
            { id = "status", title = "状态", field = "statusText", size = "fixed", width = 62, minWidth = 52,
                getTone = function(row) return row and row.tone or "muted" end },
        },
        slot = { size = "fixed", height = 222, hAlign = "fill" },
    })

    local renameRow = RSUI:HorizontalBox({ id = "v3_feature_profiles_rename_row", parent = leftStack, gap = 5,
        slot = { size = "fixed", height = 29, hAlign = "fill" } })
    local renameInput = RSUI:TextInput({ id = "v3_feature_profiles_rename_name", parent = renameRow, value = "", maxLength = 32,
        allowEmpty = false, placeholder = "选中方案后改名", slot = { size = "fill", fill = 1, minWidth = 118 } })
    local renameButton = RSUI:Button({ id = "v3_feature_profiles_rename", parent = renameRow, text = "改名", compact = true,
        slot = { size = "fixed", width = 62 } })

    local applyRow = RSUI:HorizontalBox({ id = "v3_feature_profiles_apply_row", parent = leftStack, gap = 5,
        slot = { size = "fixed", height = 27, hAlign = "fill" } })
    local applyButton = RSUI:Button({ id = "v3_feature_profiles_apply", parent = applyRow, text = "应用方案", compact = true,
        slot = { size = "fill", fill = 1 } })
    local captureButton = RSUI:Button({ id = "v3_feature_profiles_capture", parent = applyRow, text = "捕获当前", compact = true,
        slot = { size = "fill", fill = 1 } })

    local quickRow = RSUI:HorizontalBox({ id = "v3_feature_profiles_quick_row", parent = leftStack, gap = 5,
        slot = { size = "fixed", height = 27, hAlign = "fill" } })
    local quickButton = RSUI:Button({ id = "v3_feature_profiles_quick", parent = quickRow, text = "快捷按钮：--", compact = true,
        slot = { size = "fill", fill = 1 } })
    local moveUpButton = RSUI:Button({ id = "v3_feature_profiles_up", parent = quickRow, text = "上移", compact = true,
        slot = { size = "fixed", width = 54 } })
    local moveDownButton = RSUI:Button({ id = "v3_feature_profiles_down", parent = quickRow, text = "下移", compact = true,
        slot = { size = "fixed", width = 54 } })

    local deleteRow = RSUI:HorizontalBox({ id = "v3_feature_profiles_delete_row", parent = leftStack, gap = 5,
        slot = { size = "fixed", height = 27, hAlign = "fill" } })
    local resetPositionsButton = RSUI:Button({ id = "v3_feature_profiles_reset_positions", parent = deleteRow, text = "重置按钮位置", compact = true,
        slot = { size = "fill", fill = 1 } })
    local deleteButton = RSUI:Button({ id = "v3_feature_profiles_delete", parent = deleteRow, text = "删除选中", compact = true,
        slot = { size = "fill", fill = 1 } })

    local summaryText = RSUI:Text({ id = "v3_feature_profiles_summary", parent = leftStack, text = "--", fontSize = 8, tone = "muted",
        overflow = "wrap", maxLines = 3, slot = { size = "auto", minHeight = 34, hAlign = "fill" } })
    local statusText = RSUI:Text({ id = "v3_feature_profiles_status", parent = leftStack, text = "请选择或新建方案。", fontSize = 8, tone = "muted",
        overflow = "wrap", maxLines = 4, slot = { size = "fill", fill = 1, minHeight = 38, hAlign = "fill", vAlign = "fill" } })

    ------------------------------------------------------------------------
    -- Right: selected profile's complete feature target state.
    ------------------------------------------------------------------------
    local right = RSUI:Border({
        id = "v3_feature_profiles_right", parent = body, variant = "card", gradient = true, padding = 6,
        slot = { size = "fill", fill = 1, minWidth = 360, hAlign = "fill", vAlign = "fill" },
    })
    local rightStack = RSUI:VerticalBox({ id = "v3_feature_profiles_right_stack", parent = right, gap = 5 })
    local selectedTitle = RSUI:Text({ id = "v3_feature_profiles_selected_title", parent = rightStack, text = "未选择方案", fontSize = 11, tone = "strong",
        overflow = "ellipsis", slot = { size = "fixed", height = 20, hAlign = "fill" } })
    local selectedHint = RSUI:Text({ id = "v3_feature_profiles_selected_hint", parent = rightStack,
        text = "双击功能行可切换方案目标；“当前”列只显示运行状态，不直接修改模块配置。", fontSize = 8, tone = "muted", overflow = "wrap", maxLines = 2,
        slot = { size = "auto", minHeight = 26, hAlign = "fill" } })

    local moduleTable
    local moduleEnableButton, moduleDisableButton
    moduleTable = RSUI:TableView({
        id = "v3_feature_profiles_modules", parent = rightStack, items = {}, rowHeight = 27, headerHeight = 27, desiredRows = 14,
        scrollbar = true, selectable = true, selectionMode = "single", columnResize = true, headerInteractive = false,
        getKey = function(row) return row and row.featureId or nil end,
        onSelectionChanged = function(_, _, view)
            root.selectedFeatureId = view and type(view.GetSelectedKey) == "function" and view:GetSelectedKey() or nil
            local has = root.selectedProfileId ~= nil and root.selectedFeatureId ~= nil
            moduleEnableButton:SetEnabled(has)
            moduleDisableButton:SetEnabled(has)
        end,
        onItemActivated = function(item)
            if type(item) ~= "table" or root.selectedProfileId == nil then return false, "请先选择方案" end
            local ok, err = Feature.Commands:SetModule(root.selectedProfileId, item.featureId, item.targetEnabled ~= true)
            if ok ~= true then root:SetActionStatus("修改失败：" .. tostring(err or "未执行"), "warn") end
            return ok, err
        end,
        columns = {
            { id = "category", title = "分类", field = "category", size = "fixed", width = 64, minWidth = 48, tone = "muted" },
            { id = "name", title = "功能", field = "name", size = "fill", minWidth = 150, fill = 1.3 },
            { id = "target", title = "方案", field = "targetText", size = "fixed", width = 66, minWidth = 54,
                getTone = function(row) return row and row.targetEnabled and "green" or "muted" end },
            { id = "runtime", title = "当前", field = "runtimeText", size = "fixed", width = 66, minWidth = 54,
                getTone = function(row) return row and row.runtimeEnabled and "accent" or "muted" end },
            { id = "match", title = "一致", size = "fixed", width = 52, minWidth = 44,
                getText = function(row) return row and row.matches and "是" or "否" end,
                getTone = function(row) return row and row.matches and "success" or "warn" end },
        },
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })

    local moduleActions = RSUI:HorizontalBox({ id = "v3_feature_profiles_module_actions", parent = rightStack, gap = 6,
        slot = { size = "fixed", height = 28, hAlign = "fill" } })
    moduleEnableButton = RSUI:Button({ id = "v3_feature_profiles_module_enable", parent = moduleActions, text = "设为开启", compact = true, enabled = false,
        slot = { size = "fixed", width = 90 } })
    moduleDisableButton = RSUI:Button({ id = "v3_feature_profiles_module_disable", parent = moduleActions, text = "设为关闭", compact = true, enabled = false,
        slot = { size = "fixed", width = 90 } })
    local moduleActionHint = RSUI:Text({ id = "v3_feature_profiles_module_action_hint", parent = moduleActions,
        text = "未勾选的可控功能在应用方案时会关闭；基础设施与本功能自身不进入此列表。", fontSize = 8, tone = "muted", overflow = "ellipsis",
        slot = { size = "fill", fill = 1 } })

    local function ProfileRow(projection, profileId)
        for index, row in ipairs(type(projection) == "table" and projection.rows or {}) do
            if tonumber(row.profileId) == tonumber(profileId) then return row, index end
        end
        return nil, nil
    end

    function root:SetActionStatus(message, tone)
        statusText:SetText(tostring(message or ""))
        if S.Theme ~= nil and type(S.Theme.SetLabelTone) == "function" then S.Theme:SetLabelTone(statusText, tone or "muted") end
        return true
    end

    function root:RefreshEditor(selectionChanged)
        local projection = Feature:GetProjection() or {}
        if self.selectedProfileId == nil then self.selectedProfileId = tonumber(projection.selectedId) end
        local row, index = ProfileRow(projection, self.selectedProfileId)
        if row == nil then
            self.selectedProfileId = nil
            self.selectedFeatureId = nil
            selectedTitle:SetText("未选择方案")
            renameInput:SetEnabled(false)
            for _, button in ipairs({ renameButton, applyButton, captureButton, quickButton, moveUpButton, moveDownButton, deleteButton }) do button:SetEnabled(false) end
            moduleEnableButton:SetEnabled(false); moduleDisableButton:SetEnabled(false)
            moduleTable:SetItems({}, "feature_profiles:empty")
            moduleTable:SetViewState("empty", { title = "尚无方案", detail = "在左侧输入名称并新建方案；不会自动创建“生活/战斗”等预设。" })
            return true
        end

        if profileTable:GetSelectedKey() ~= row.profileId then profileTable:SetSelectedIndex(index) end
        if selectionChanged == true and type(renameInput.SetValue) == "function" then renameInput:SetValue(row.name, false, "feature_profile_selected") end
        selectedTitle:SetText("方案：" .. tostring(row.name) .. (row.active and "  · 当前生效" or (row.dirty and "  · 已偏离" or "")))
        renameInput:SetEnabled(true)
        local featureEnabled = S.FeatureRuntime and S.FeatureRuntime:IsEnabled(Feature.Id) == true
        renameButton:SetEnabled(true); captureButton:SetEnabled(true); quickButton:SetEnabled(true); moveUpButton:SetEnabled(true); moveDownButton:SetEnabled(true); deleteButton:SetEnabled(true)
        applyButton:SetEnabled(featureEnabled)
        quickButton:SetText(row.quick and "快捷按钮：显示" or "快捷按钮：隐藏")

        moduleTable:SetItems(projection.moduleRows or {}, "feature_profiles:modules:" .. tostring(projection.revision or 0))
        if #(projection.moduleRows or {}) > 0 then moduleTable:SetViewState("ready")
        else moduleTable:SetViewState("empty", { title = "没有可控业务功能", detail = "基础设施、Shell 与运行时受保护功能不会进入方案。" }) end
        if self.selectedFeatureId ~= nil then
            local selectedIndex = nil
            for i, module in ipairs(projection.moduleRows or {}) do if tostring(module.featureId) == tostring(self.selectedFeatureId) then selectedIndex = i; break end end
            if selectedIndex ~= nil and moduleTable:GetSelectedKey() ~= self.selectedFeatureId then moduleTable:SetSelectedIndex(selectedIndex) end
        end
        local hasModule = self.selectedFeatureId ~= nil
        moduleEnableButton:SetEnabled(hasModule)
        moduleDisableButton:SetEnabled(hasModule)
        return true
    end

    function root:Refresh()
        local projection = Feature:GetProjection() or {}
        local selectedBefore = self.selectedProfileId
        if selectedBefore == nil then self.selectedProfileId = tonumber(projection.selectedId) end
        profileTable:SetItems(projection.rows or {}, "feature_profiles:profiles:" .. tostring(projection.revision or 0))
        if #(projection.rows or {}) > 0 then profileTable:SetViewState("ready")
        else profileTable:SetViewState("empty", { title = "暂无功能方案", detail = "方案完全由你自己创建，不附带任何内置“生活/战斗”模板。" }) end
        self:RefreshEditor(selectedBefore ~= self.selectedProfileId)
        local enabled = S.FeatureRuntime and S.FeatureRuntime:IsEnabled(Feature.Id) == true
        summaryText:SetText("方案 " .. tostring(projection.profileCount or 0) .. "/" .. tostring(projection.profileLimit or 0)
            .. " · 可控功能 " .. tostring(projection.controllableCount or 0)
            .. " · 功能方案 " .. (enabled and "已启用" or "已关闭")
            .. (projection.dirty and "\n最近应用的方案已因手动开关变化而偏离；不会自动覆盖保存。" or ""))
        if projection.lastOperation ~= nil and tostring(projection.lastOperation) ~= "" then self:SetActionStatus(projection.lastOperation, projection.error and "warn" or "muted") end
        return true
    end

    local function RequireProfile()
        if root.selectedProfileId == nil then return nil, "请先选择一个方案" end
        return root.selectedProfileId
    end

    createButton.onClick = function()
        local name = ReadActionText(createInput)
        local ok, result = Feature.Commands:CreateProfile(name)
        if ok ~= true then root:SetActionStatus("新建失败：" .. tostring(result or "未执行"), "warn"); return false, result end
        root.selectedProfileId = tonumber(result)
        if type(createInput.SetValue) == "function" then createInput:SetValue("", false, "feature_profile_created") end
        root:Refresh(); root:SetActionStatus("方案已创建；请在右侧选择需要开启的功能。", "success")
        return true
    end
    renameButton.onClick = function()
        local id, guardErr = RequireProfile(); if id == nil then return false, guardErr end
        local name = ReadActionText(renameInput)
        local ok, err = Feature.Commands:RenameProfile(id, name)
        if ok ~= true then root:SetActionStatus("改名失败：" .. tostring(err or "未执行"), "warn"); return false, err end
        root:Refresh(); root:SetActionStatus("方案名称已保存。", "success"); return true
    end
    applyButton.onClick = function()
        local id, guardErr = RequireProfile(); if id == nil then return false, guardErr end
        if not (S.FeatureRuntime and S.FeatureRuntime:IsEnabled(Feature.Id) == true) then return false, "功能方案模块已关闭" end
        local ok, result = Feature.Commands:ApplyProfile(id)
        root:Refresh()
        root:SetActionStatus(ok == true and tostring(result or "方案已应用。") or ("应用失败：" .. tostring(result or "未执行")), ok == true and "success" or "warn")
        return ok, result
    end
    captureButton.onClick = function()
        local id, guardErr = RequireProfile(); if id == nil then return false, guardErr end
        local ok, err = Feature.Commands:CaptureCurrent(id)
        root:Refresh(); root:SetActionStatus(ok == true and "已把当前可控功能开关覆盖到该方案。" or ("捕获失败：" .. tostring(err or "未执行")), ok == true and "success" or "warn")
        return ok, err
    end
    quickButton.onClick = function()
        local id, guardErr = RequireProfile(); if id == nil then return false, guardErr end
        local projection = Feature:GetProjection(); local row = ProfileRow(projection, id)
        if row == nil then return false, "方案不存在" end
        local ok, err = Feature.Commands:SetQuick(id, row.quick ~= true)
        root:Refresh(); return ok, err
    end
    moveUpButton.onClick = function()
        local id, guardErr = RequireProfile(); if id == nil then return false, guardErr end
        local ok, err = Feature.Commands:MoveProfile(id, -1); root:Refresh(); return ok, err
    end
    moveDownButton.onClick = function()
        local id, guardErr = RequireProfile(); if id == nil then return false, guardErr end
        local ok, err = Feature.Commands:MoveProfile(id, 1); root:Refresh(); return ok, err
    end
    deleteButton.onClick = function()
        local id, guardErr = RequireProfile(); if id == nil then return false, guardErr end
        local ok, err = Feature.Commands:DeleteProfile(id)
        if ok ~= true then root:SetActionStatus("删除失败：" .. tostring(err or "未执行"), "warn"); return false, err end
        root.selectedProfileId = nil; root.selectedFeatureId = nil
        root:Refresh(); root:SetActionStatus("方案已删除；当前已经开启/关闭的功能不会因此变化。", "muted")
        return true
    end
    resetPositionsButton.onClick = function()
        local ok, err = Feature.Commands:ResetQuickPositions()
        root:SetActionStatus(ok == true and "所有方案快捷按钮位置已恢复默认。" or ("重置失败：" .. tostring(err or "未执行")), ok == true and "success" or "warn")
        return ok, err
    end
    moduleEnableButton.onClick = function()
        local id, guardErr = RequireProfile(); if id == nil then return false, guardErr end
        if root.selectedFeatureId == nil then return false, "请先选择一个功能" end
        local ok, err = Feature.Commands:SetModule(id, root.selectedFeatureId, true); root:Refresh(); return ok, err
    end
    moduleDisableButton.onClick = function()
        local id, guardErr = RequireProfile(); if id == nil then return false, guardErr end
        if root.selectedFeatureId == nil then return false, "请先选择一个功能" end
        local ok, err = Feature.Commands:SetModule(id, root.selectedFeatureId, false); root:Refresh(); return ok, err
    end

    local token = "page:feature_profiles:" .. tostring(root)
    function root:SyncConsumer()
        if self.pageActive ~= true then return true end
        local enabled = S.FeatureRuntime and S.FeatureRuntime:IsEnabled(Feature.Id) == true
        if not enabled then self.consumerHeld = false; return self:Refresh() end
        if self.consumerHeld ~= true then
            local ok, err = Feature:AcquireConsumer(token)
            if ok ~= true then return false, err end
            self.consumerHeld = true
        end
        return self:Refresh()
    end

    function root:OnActivated()
        if self.pageActive == true then return self:SyncConsumer() end
        self.pageActive = true
        if not (S.Events and type(S.Events.SubscribeInternal) == "function") then self.pageActive = false; return false, "内部事件总线不可用" end
        local updateOk = S.Events:SubscribeInternal(Feature.UpdateTopic, self, function()
            if root.pageActive == true then root:Refresh() end
        end)
        local lifecycleOk = S.Events:SubscribeInternal("v3.feature.lifecycle", self, function(_, featureId)
            if root.pageActive ~= true or tostring(featureId or "") ~= Feature.Id then return end
            root:SyncConsumer()
        end)
        if updateOk ~= true or lifecycleOk ~= true then self:OnDeactivated(); return false, "功能方案页面事件订阅失败" end
        local ok, err = self:SyncConsumer()
        if ok ~= true then self:OnDeactivated(); return false, err end
        return true
    end

    function root:OnDeactivated()
        self.pageActive = false
        if S.Events and type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
        if self.consumerHeld == true then
            if S.FeatureRuntime and S.FeatureRuntime:IsEnabled(Feature.Id) == true then
                local ok, err = Feature:ReleaseConsumer(token)
                if ok ~= true then return false, err end
            end
            self.consumerHeld = false
        end
        return true
    end

    local release = root.Release
    function root:Release()
        self:OnDeactivated()
        return release(self)
    end

    root:Refresh()
    return root
end

local ok, err = PageHost:RegisterFactory(ROUTE, BuildPage)
if ok ~= true then error(err) end

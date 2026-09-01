------------------------------------------------------------------------
-- Replicated Suite - Bag Organizer Page
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.BagOrganizerPage = {}

local function Service()
    return S.Services and S.Services.BagOrganizer or nil
end

local function ModuleState()
    return S.ModuleManager and S.ModuleManager:Describe("bag_organizer") or nil
end

local function Enable(widget, enabled)
    if widget and widget.Enable then widget:Enable(enabled == true) end
end

local function CycleNumber(options, current)
    local idx = 1
    for i, v in ipairs(options) do
        if tonumber(v) == tonumber(current) then idx = i; break end
    end
    idx = idx + 1
    if idx > #options then idx = 1 end
    return options[idx]
end

function S.BagOrganizerPage.Create(parent)
    local page = { key = "bagorganizer", root = S.UI:CreatePanel(parent, "bag_organizer_page", 0, 0, 100, 100, "soft") }
    if page.root.rsBorder and page.root.rsBorder.SetVisible then page.root.rsBorder:SetVisible(false) end
    if page.root.rsBackground and page.root.rsBackground.SetVisible then page.root.rsBackground:SetVisible(false) end

    page.title = S.UI:CreateLabel(page.root, "bag_organizer_title", "整理背包", 0, 0, 260, 28, 16, nil, ALIGN_LEFT)
    page.note = S.UI:CreateLabel(page.root, "bag_organizer_note",
        "取：从当前打开的仓库/箱子取出背包已有同类物品；放：把背包同类物品放入当前仓库/箱子。", 0, 0, 680, 22, 9, "muted", ALIGN_LEFT)
    page.moduleState = S.UI:CreateLabel(page.root, "bag_organizer_module_state", "", 0, 0, 100, 24, 10, "muted", ALIGN_RIGHT)
    page.moduleToggle = S.UI:CreateButton(page.root, "bag_organizer_module_toggle", "关闭整理背包", 0, 0, 108, 27, 9, false)
    page.retry = S.UI:CreateButton(page.root, "bag_organizer_retry", "重试", 0, 0, 54, 27, 9, false)

    page.actionCard = S.UI:CreatePanel(page.root, "bag_organizer_action_card", 0, 0, 100, 100, "card")
    page.actionTitle = S.UI:CreateLabel(page.root, "bag_organizer_action_title", "快速整理", 0, 0, 160, 22, 13, nil, ALIGN_LEFT)
    page.actionHint = S.UI:CreateLabel(page.root, "bag_organizer_action_hint",
        "打开仓库或箱子时，取/放显示在背包上方；关闭当前仓储后自动隐藏。1024×768 下会自动限制在屏幕内。", 0, 0, 520, 20, 9, "muted", ALIGN_LEFT)
    page.withdraw = S.UI:CreateButton(page.root, "bag_organizer_withdraw", "取", 0, 0, 120, 44, 15, false, true)
    page.deposit = S.UI:CreateButton(page.root, "bag_organizer_deposit", "放", 0, 0, 120, 44, 15, false, true)
    page.cancel = S.UI:CreateButton(page.root, "bag_organizer_cancel", "停止当前整理", 0, 0, 104, 28, 9, false)
    page.status = S.UI:CreateLabel(page.root, "bag_organizer_status", "等待操作", 0, 0, 420, 24, 10, "yellow", ALIGN_LEFT)

    page.settingsCard = S.UI:CreatePanel(page.root, "bag_organizer_settings_card", 0, 0, 100, 100, "card")
    page.settingsTitle = S.UI:CreateLabel(page.root, "bag_organizer_settings_title", "设置", 0, 0, 120, 22, 13, nil, ALIGN_LEFT)
    page.showButtons = S.UI:CreateButton(page.root, "bag_organizer_show_buttons", "仓储快捷按钮：开", 0, 0, 150, 28, 9, false)
    page.requireBank = S.UI:CreateButton(page.root, "bag_organizer_require_bank", "要求仓储打开：开", 0, 0, 150, 28, 9, false)
    page.buttonSide = S.UI:CreateButton(page.root, "bag_organizer_button_side", "按钮位置：背包上方", 0, 0, 150, 28, 9, false)
    page.interval = S.UI:CreateButton(page.root, "bag_organizer_interval", "移动间隔：250ms", 0, 0, 150, 28, 9, false)
    page.fallback = S.UI:CreateButton(page.root, "bag_organizer_fallback", "名称回退：开", 0, 0, 150, 28, 9, false)
    page.maxMoves = S.UI:CreateButton(page.root, "bag_organizer_max_moves", "单次上限：全部", 0, 0, 150, 28, 9, false)
    page.report = S.UI:CreateButton(page.root, "bag_organizer_report", "完成提示：开", 0, 0, 150, 28, 9, false)
    page.settingsHint = S.UI:CreateLabel(page.root, "bag_organizer_settings_hint",
        "严格身份优先使用 itemType；客户端不给 itemType 时，名称回退使用 名称 + 品质 + category_id。关闭名称回退后，缺少 itemType 的物品不会移动。",
        0, 0, 580, 42, 8, "muted", ALIGN_LEFT)

    page.blacklistCard = S.UI:CreatePanel(page.root, "bag_organizer_blacklist_card", 0, 0, 100, 100, "card")
    page.blacklistTitle = S.UI:CreateLabel(page.root, "bag_organizer_blacklist_title", "黑名单", 0, 0, 120, 22, 13, nil, ALIGN_LEFT)
    page.blacklistStorage = S.UI:CreateLabel(page.root, "bag_organizer_blacklist_storage", "当前仓储：关闭", 0, 0, 220, 20, 9, "muted", ALIGN_LEFT)
    page.blacklistToggle = S.UI:CreateButton(page.root, "bag_organizer_blacklist_toggle", "黑名单：开", 0, 0, 140, 28, 9, false)
    page.blacklistManage = S.UI:CreateButton(page.root, "bag_organizer_blacklist_manage", "管理黑名单…", 0, 0, 140, 28, 9, false)

    page.diagCard = S.UI:CreatePanel(page.root, "bag_organizer_diag_card", 0, 0, 100, 100, "card")
    page.diagTitle = S.UI:CreateLabel(page.root, "bag_organizer_diag_title", "诊断", 0, 0, 120, 22, 13, nil, ALIGN_LEFT)
    page.diagRun = S.UI:CreateButton(page.root, "bag_organizer_diag_run", "扫描一次", 0, 0, 86, 28, 9, false)
    page.diagText = S.UI:CreateLabel(page.root, "bag_organizer_diag_text", "尚未扫描", 0, 0, 520, 42, 9, "muted", ALIGN_LEFT)

    S.UI:SafeHandler(page.moduleToggle, "OnClick", function()
        if not S.ModuleManager then return end
        local enabled = S.ModuleManager:IsEnabled("bag_organizer")
        local ok, err = S.ModuleManager:SetEnabled("bag_organizer", not enabled)
        if ok ~= true then S.SafeChat("整理背包切换失败：" .. tostring(err or "未知原因")) end
        page:Refresh()
    end, "bag_organizer:module_toggle")

    S.UI:SafeHandler(page.retry, "OnClick", function()
        if S.ModuleManager then
            local ok, err = S.ModuleManager:Retry("bag_organizer")
            if ok ~= true then S.SafeChat("整理背包重试失败：" .. tostring(err or "未知原因")) end
        end
        page:Refresh()
    end, "bag_organizer:retry")

    S.UI:SafeHandler(page.withdraw, "OnClick", function()
        local svc = Service(); if svc then svc:Begin("withdraw") end
        page:Refresh()
    end, "bag_organizer:withdraw")
    S.UI:SafeHandler(page.deposit, "OnClick", function()
        local svc = Service(); if svc then svc:Begin("deposit") end
        page:Refresh()
    end, "bag_organizer:deposit")
    S.UI:SafeHandler(page.cancel, "OnClick", function()
        local svc = Service(); if svc then svc:Cancel() end
        page:Refresh()
    end, "bag_organizer:cancel")

    S.UI:SafeHandler(page.showButtons, "OnClick", function()
        S.State.settings.bagOrganizerShowBagButtons = not (S.State.settings.bagOrganizerShowBagButtons == true)
        if Service() then Service():RefreshFloating() end
        S.Storage:RequestSave(); page:Refresh()
    end, "bag_organizer:show_buttons")
    S.UI:SafeHandler(page.requireBank, "OnClick", function()
        S.State.settings.bagOrganizerRequireBankOpen = not (S.State.settings.bagOrganizerRequireBankOpen == true)
        S.Storage:RequestSave(); page:Refresh()
    end, "bag_organizer:require_bank")
    S.UI:SafeHandler(page.buttonSide, "OnClick", function()
        S.SafeChat("整理背包快捷按钮固定在背包上方；仓库和箱子共用。")
        page:Refresh()
    end, "bag_organizer:button_side")
    S.UI:SafeHandler(page.interval, "OnClick", function()
        S.State.settings.bagOrganizerMoveIntervalMs = CycleNumber({ 200, 250, 300, 400, 500, 750, 1000 }, S.State.settings.bagOrganizerMoveIntervalMs)
        S.Storage:RequestSave(); page:Refresh()
    end, "bag_organizer:interval")
    S.UI:SafeHandler(page.fallback, "OnClick", function()
        S.State.settings.bagOrganizerAllowNameFallback = not (S.State.settings.bagOrganizerAllowNameFallback == true)
        S.Storage:RequestSave(); page:Refresh()
    end, "bag_organizer:fallback")
    S.UI:SafeHandler(page.maxMoves, "OnClick", function()
        S.State.settings.bagOrganizerMaxMoves = CycleNumber({ 0, 30, 60, 120, 200 }, S.State.settings.bagOrganizerMaxMoves)
        S.Storage:RequestSave(); page:Refresh()
    end, "bag_organizer:max_moves")
    S.UI:SafeHandler(page.report, "OnClick", function()
        S.State.settings.bagOrganizerReportResults = not (S.State.settings.bagOrganizerReportResults == true)
        S.Storage:RequestSave(); page:Refresh()
    end, "bag_organizer:report")
    S.UI:SafeHandler(page.diagRun, "OnClick", function()
        local svc = Service(); if svc then svc:RunDiagnostics() end
        page:Refresh()
    end, "bag_organizer:diagnostics")

    S.UI:SafeHandler(page.blacklistToggle, "OnClick", function()
        local blacklist = S.State.settings.bagOrganizerBlacklist
        if type(blacklist) ~= "table" then
            blacklist = { enabled = false, bank = { categories = {}, items = {} }, coffer = { categories = {}, items = {} } }
            S.State.settings.bagOrganizerBlacklist = blacklist
        end
        blacklist.enabled = not (blacklist.enabled == true)
        S.Storage:RequestSave(); page:Refresh()
    end, "bag_organizer:blacklist_toggle")

    S.UI:SafeHandler(page.blacklistManage, "OnClick", function()
        if S.BagOrganizerBlacklistWindow ~= nil and type(S.BagOrganizerBlacklistWindow.Show) == "function" then
            S.BagOrganizerBlacklistWindow:Show(true)
        else
            S.SafeChat("黑名单管理窗口未加载。")
        end
        page:Refresh()
    end, "bag_organizer:blacklist_manage")

    function page:Refresh()
        local desc = ModuleState()
        local enabled = desc and desc.enabled == true
        if desc == nil then
            self.moduleState:SetText("未注册"); S.Theme:SetLabelTone(self.moduleState, "red")
        elseif desc.state == "Faulted" then
            self.moduleState:SetText("初始化失败"); S.Theme:SetLabelTone(self.moduleState, "red")
        elseif enabled then
            self.moduleState:SetText("运行中"); S.Theme:SetLabelTone(self.moduleState, "green")
        else
            self.moduleState:SetText("已关闭"); S.Theme:SetLabelTone(self.moduleState, "muted")
        end
        self.moduleToggle:SetText(enabled and "关闭整理背包" or "启用整理背包")
        self.retry:Show(desc ~= nil and desc.state == "Faulted")

        local svc = Service()
        local busy = svc and svc.busy == true
        self.withdraw:SetText(busy and svc.direction == "withdraw" and "取…" or "取")
        self.deposit:SetText(busy and svc.direction == "deposit" and "放…" or "放")
        self.cancel:Show(busy == true)
        self.status:SetText(svc and tostring(svc.lastMessage or "等待操作") or "服务未加载")

        self.showButtons:SetText(S.State.settings.bagOrganizerShowBagButtons == true and "仓储快捷按钮：开" or "仓储快捷按钮：关")
        self.requireBank:SetText(S.State.settings.bagOrganizerRequireBankOpen == true and "要求仓储打开：开" or "要求仓储打开：关")
        self.buttonSide:SetText("按钮位置：背包上方")
        self.interval:SetText("移动间隔：" .. tostring(math.floor(tonumber(S.State.settings.bagOrganizerMoveIntervalMs) or 250)) .. "ms")
        self.fallback:SetText(S.State.settings.bagOrganizerAllowNameFallback == true and "名称回退：开" or "名称回退：关")
        local maxMoves = math.max(0, math.floor(tonumber(S.State.settings.bagOrganizerMaxMoves) or 0))
        self.maxMoves:SetText(maxMoves == 0 and "单次上限：全部" or ("单次上限：" .. tostring(maxMoves)))
        self.report:SetText(S.State.settings.bagOrganizerReportResults == true and "完成提示：开" or "完成提示：关")

        local blacklist = S.State.settings.bagOrganizerBlacklist
        self.blacklistToggle:SetText(type(blacklist) == "table" and blacklist.enabled == true and "黑名单：开" or "黑名单：关")

        if svc then
            local quickVisible = svc.floatingVisible == true
            local storageKind, storageSource = svc:GetOpenStorageKind()
            local storageName = storageKind == "coffer" and "箱子" or (storageKind == "bank" and "仓库" or "关闭")
            self.blacklistStorage:SetText("当前仓储：" .. storageName)
            local rect = svc.lastBagAnchorRect
            local rectText = type(rect) == "table"
                and string.format("%.0f,%.0f %.0fx%.0f", tonumber(rect.x) or 0, tonumber(rect.y) or 0, tonumber(rect.width) or 0, tonumber(rect.height) or 0)
                or "无"
            self.diagText:SetText(string.format("背包 %d · %s %d · ID %d · 回退 %d · 无身份 %d\n仓储检测：%s (%s) · 快捷条：%s · 位置：%s\n背包锚点：%s · %s",
                tonumber(svc.lastBagCount) or 0, storageName, tonumber(svc.lastBankCount) or 0,
                tonumber(svc.lastTypedCount) or 0, tonumber(svc.lastFallbackCount) or 0,
                tonumber(svc.lastUnknownCount) or 0,
                storageName, tostring(storageSource or "none"),
                quickVisible and "显示" or "隐藏", tostring(svc.floatingPlacement or "unknown"),
                tostring(svc.lastBagAnchorSource or "none"), rectText))
        else
            self.diagText:SetText("服务未加载")
            self.blacklistStorage:SetText("当前仓储：关闭")
        end

        local usable = enabled and desc ~= nil and desc.state ~= "Faulted" and busy ~= true
        Enable(self.withdraw, usable); Enable(self.deposit, usable); Enable(self.diagRun, usable)
        Enable(self.cancel, enabled and busy)
        for _, widget in ipairs({ self.showButtons, self.requireBank, self.interval, self.fallback, self.maxMoves, self.report, self.blacklistToggle, self.blacklistManage }) do
            Enable(widget, desc ~= nil and desc.state ~= "Faulted")
        end
        -- Placement is intentionally fixed by product design: bank/coffer open ->
        -- controls above the bag; current storage closed -> controls hidden.
        Enable(self.buttonSide, false)
    end

    function page:ApplyLayout(spec)
        S.UI:SetAnchor(self.root, parent, 0, 0); self.root:SetExtent(spec.contentWidth, spec.contentHeight)
        local sc = S.Layout:GetContext().addonScale
        local pad = 12 * sc
        local full = math.max(1, spec.contentWidth - pad * 2)
        local right = pad + full
        -- At the technical 560px Suite minimum the content column is only
        -- ~450px wide. Keep every setting readable by collapsing to two
        -- columns instead of shrinking four long Chinese labels into ellipses.
        local narrow = full < 560 * sc

        self.title:SetExtent(math.max(120 * sc, full - 290 * sc), 28 * sc); S.UI:SetAnchor(self.title, self.root, pad, 7 * sc)
        self.moduleToggle:SetExtent(108 * sc, 27 * sc); S.UI:SetAnchor(self.moduleToggle, self.root, right - 108 * sc, 6 * sc)
        self.retry:SetExtent(54 * sc, 27 * sc); S.UI:SetAnchor(self.retry, self.root, right - 168 * sc, 6 * sc)
        self.moduleState:SetExtent(94 * sc, 24 * sc); S.UI:SetAnchor(self.moduleState, self.root, right - 268 * sc, 8 * sc)
        self.note:SetExtent(full, 22 * sc); S.UI:SetAnchor(self.note, self.root, pad, 39 * sc)

        local top = 66 * sc
        local actionH = (narrow and 136 or 148) * sc
        self.actionCard:SetExtent(full, actionH); S.UI:SetAnchor(self.actionCard, self.root, pad, top)
        self.actionTitle:SetExtent(full - 24 * sc, 22 * sc); S.UI:SetAnchor(self.actionTitle, self.root, pad + 12 * sc, top + 10 * sc)
        self.actionHint:SetExtent(full - 24 * sc, 20 * sc); S.UI:SetAnchor(self.actionHint, self.root, pad + 12 * sc, top + 34 * sc)
        self.withdraw:SetExtent(120 * sc, 44 * sc); S.UI:SetAnchor(self.withdraw, self.root, pad + 12 * sc, top + 62 * sc)
        self.deposit:SetExtent(120 * sc, 44 * sc); S.UI:SetAnchor(self.deposit, self.root, pad + 140 * sc, top + 62 * sc)
        self.cancel:SetExtent(104 * sc, 28 * sc); S.UI:SetAnchor(self.cancel, self.root, pad + 268 * sc, top + 70 * sc)
        self.status:SetExtent(math.max(120 * sc, full - 24 * sc), 24 * sc); S.UI:SetAnchor(self.status, self.root, pad + 12 * sc, top + (narrow and 108 or 116) * sc)

        local gap = (narrow and 8 or 10) * sc
        local settingsY = top + actionH + gap
        local settingsH = (narrow and 218 or 184) * sc
        self.settingsCard:SetExtent(full, settingsH); S.UI:SetAnchor(self.settingsCard, self.root, pad, settingsY)
        self.settingsTitle:SetExtent(full - 24 * sc, 22 * sc); S.UI:SetAnchor(self.settingsTitle, self.root, pad + 12 * sc, settingsY + 10 * sc)
        local buttonGap = 6 * sc
        local x0 = pad + 12 * sc
        if narrow then
            local buttonW = math.max(1, (full - 24 * sc - buttonGap) / 2)
            local rows = {
                { self.showButtons, self.requireBank },
                { self.buttonSide, self.interval },
                { self.fallback, self.maxMoves },
                { self.report },
            }
            local rowY = settingsY + 38 * sc
            for rowIndex, row in ipairs(rows) do
                for columnIndex, widget in ipairs(row) do
                    widget:SetExtent(buttonW, 28 * sc)
                    S.UI:SetAnchor(widget, self.root, x0 + (columnIndex - 1) * (buttonW + buttonGap), rowY + (rowIndex - 1) * 32 * sc)
                end
            end
            self.settingsHint:SetExtent(full - 24 * sc, 42 * sc); S.UI:SetAnchor(self.settingsHint, self.root, x0, settingsY + 168 * sc)
        else
            local buttonW = math.max(110 * sc, (full - 24 * sc - buttonGap * 3) / 4)
            local y1 = settingsY + 40 * sc
            local y2 = settingsY + 74 * sc
            local row1 = { self.showButtons, self.requireBank, self.buttonSide, self.interval }
            local row2 = { self.fallback, self.maxMoves, self.report }
            for i, widget in ipairs(row1) do
                widget:SetExtent(buttonW, 28 * sc); S.UI:SetAnchor(widget, self.root, x0 + (i - 1) * (buttonW + buttonGap), y1)
            end
            for i, widget in ipairs(row2) do
                widget:SetExtent(buttonW, 28 * sc); S.UI:SetAnchor(widget, self.root, x0 + (i - 1) * (buttonW + buttonGap), y2)
            end
            self.settingsHint:SetExtent(full - 24 * sc, 52 * sc); S.UI:SetAnchor(self.settingsHint, self.root, x0, settingsY + 112 * sc)
        end

        local blacklistY = settingsY + settingsH + gap
        local blacklistH = 64 * sc
        self.blacklistCard:SetExtent(full, blacklistH); S.UI:SetAnchor(self.blacklistCard, self.root, pad, blacklistY)
        self.blacklistTitle:SetExtent(120 * sc, 22 * sc); S.UI:SetAnchor(self.blacklistTitle, self.root, pad + 12 * sc, blacklistY + 8 * sc)
        self.blacklistStorage:SetExtent((narrow and 150 or 220) * sc, 20 * sc); S.UI:SetAnchor(self.blacklistStorage, self.root, pad + 12 * sc + 128 * sc, blacklistY + 10 * sc)
        if narrow then
            -- Two-column rule, same as the settings card on narrow layouts.
            local buttonW = math.max(1, (full - 24 * sc - buttonGap) / 2)
            self.blacklistToggle:SetExtent(buttonW, 28 * sc); S.UI:SetAnchor(self.blacklistToggle, self.root, pad + 12 * sc, blacklistY + 34 * sc)
            self.blacklistManage:SetExtent(buttonW, 28 * sc); S.UI:SetAnchor(self.blacklistManage, self.root, pad + 12 * sc + buttonW + buttonGap, blacklistY + 34 * sc)
        else
            self.blacklistToggle:SetExtent(140 * sc, 28 * sc); S.UI:SetAnchor(self.blacklistToggle, self.root, pad + 12 * sc, blacklistY + 34 * sc)
            self.blacklistManage:SetExtent(140 * sc, 28 * sc); S.UI:SetAnchor(self.blacklistManage, self.root, pad + 12 * sc + 146 * sc, blacklistY + 34 * sc)
        end

        local diagY = blacklistY + blacklistH + gap
        local diagH = math.max(76 * sc, spec.contentHeight - diagY - pad)
        self.diagCard:SetExtent(full, diagH); S.UI:SetAnchor(self.diagCard, self.root, pad, diagY)
        self.diagTitle:SetExtent(120 * sc, 22 * sc); S.UI:SetAnchor(self.diagTitle, self.root, pad + 12 * sc, diagY + 10 * sc)
        self.diagRun:SetExtent(86 * sc, 28 * sc); S.UI:SetAnchor(self.diagRun, self.root, right - 98 * sc, diagY + 8 * sc)
        self.diagText:SetExtent(full - 24 * sc, math.max(26 * sc, diagH - 48 * sc)); S.UI:SetAnchor(self.diagText, self.root, pad + 12 * sc, diagY + 42 * sc)
        self:Refresh()
    end

    S.UI.pages.bagorganizer = page
    return page
end

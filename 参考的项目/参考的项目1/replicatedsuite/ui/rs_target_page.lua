------------------------------------------------------------------------
-- Replicated Suite - 目标检测 page (Target Detection Authority inspector)
--
-- Consumes the shared Target Detection Service. This page never scans the game
-- itself: it is a read Proxy. Global detection mode is an explicit user toggle;
-- while the page is visible it also subscribes as a full inspector consumer so
-- its rows stay live without leaving the service permanently enabled.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.TargetPage = {}

local PAGE_OWNER = "target_page"
local EFFECT_TYPES = { "buff", "debuff", "hidden" }
local EFFECT_LABELS = { buff = "Buff", debuff = "Debuff", hidden = "Hidden" }

local function GetService()
    return S.TargetService
end

local function GetPlatesStorage()
    if ReplicatedSuiteModuleSandbox == nil then return nil end
    local ok, plates = pcall(function() return ReplicatedSuiteModuleSandbox:GetExport("plates", "ReplicatedPlates") end)
    if not ok or type(plates) ~= "table" or type(plates.Storage) ~= "table" then return nil end
    return plates.Storage
end

local function IsTracked(scope, effectType, id)
    local storage = GetPlatesStorage()
    if storage == nil or type(storage.IsTracked) ~= "function" then return false end
    scope = scope == "player" and "player" or "target"
    return storage:IsTracked(scope, effectType, id) == true
end

local function ToggleTrack(scope, effectType, effect, page)
    local storage = GetPlatesStorage()
    if storage == nil then
        S.SafeChat("BUFF显示存储不可用，无法追加追踪。")
        return
    end
    local id = tostring(effect.stableId or effect.id or "")
    if id == "" or id:match("^%d+$") == nil then
        S.SafeChat("该状态没有稳定数字 ID，无法追踪。")
        return
    end
    scope = scope == "player" and "player" or "target"
    if storage:IsTracked(scope, effectType, id) then
        local ok, err = storage:RemoveTracked(scope, effectType, id)
        if not ok then S.SafeChat("取消追踪失败：" .. tostring(err or "unknown")) end
    else
        local ok, err = storage:AddTracked(scope, effectType, id, {
            name = tostring(effect.name or ""),
            iconPath = tostring(effect.iconPath or ""),
        })
        if not ok then S.SafeChat("追加追踪失败：" .. tostring(err or "unknown")) end
    end
    if page ~= nil and type(page.Refresh) == "function" then page:Refresh() end
end

local function FormatRemaining(ms)
    local value = tonumber(ms)
    if value == nil then return "--" end
    if value >= 60000 then return tostring(math.floor(value / 60000 + 0.5)) .. "分" end
    return tostring(math.floor(value / 1000 + 0.5)) .. "秒"
end

local function SetEffectIcon(icon, path)
    if icon == nil then return end
    if type(path) ~= "string" or path == "" then
        icon:SetVisible(false)
        return
    end
    pcall(function()
        icon:ClearAllTextures()
        icon:AddTexture(path)
        icon:SetVisible(true)
    end)
end

function S.TargetPage.Create(parent)
    local page = {
        root = S.UI:CreatePanel(parent, "target_page", 0, 0, 100, 100, "soft"),
        effectRows = {},
        effectType = "buff",
        captureScope = "target",
        visibleEffectRows = 10,
    }
    if page.root.rsBorder and page.root.rsBorder.SetVisible then page.root.rsBorder:SetVisible(false) end
    if page.root.rsBackground and page.root.rsBackground.SetVisible then page.root.rsBackground:SetVisible(false) end

    page.title = S.UI:CreateLabel(page.root, "target_title", "目标检测", 12, 8, 360, 28, 16, nil, ALIGN_LEFT)

    page.globalToggle = S.UI:CreateButton(page.root, "target_control_global", "全局检测：关", 12, 46, 150, 27, 9, false)
    page.retainToggle = S.UI:CreateButton(page.root, "target_control_retain", "队列保留：开", 168, 46, 150, 27, 9, false)
    page.captureToggle = S.UI:CreateButton(page.root, "target_control_capture", "开始持续检测", 324, 46, 150, 27, 9, false)
    page.scanNow = S.UI:CreateButton(page.root, "target_control_scan", "立即扫描", 12, 79, 150, 27, 9, false)
    page.clearQueue = S.UI:CreateButton(page.root, "target_control_clear", "清空队列", 168, 79, 150, 27, 9, false)
    page.printDiag = S.UI:CreateButton(page.root, "target_control_print", "打印一次诊断", 324, 79, 150, 27, 9, false)

    page.infoTitle = S.UI:CreateLabel(page.root, "target_section_current", "当前目标", 12, 116, 200, 20, 12, nil, ALIGN_LEFT)
    page.infoLines = {}
    for i = 1, 5 do
        page.infoLines[i] = S.UI:CreateLabel(page.root, "target_current_line_" .. i, "", 12, 140 + (i - 1) * 20, 720, 18, 10, i == 1 and nil or "muted", ALIGN_LEFT)
    end

    page.effectsTitle = S.UI:CreateLabel(page.root, "target_section_effects", "状态检测", 12, 250, 200, 20, 12, nil, ALIGN_LEFT)
    page.scopeToggle = S.UI:CreateButton(page.root, "target_effects_scope", "对象：目标", 228, 274, 96, 25, 9, false)
    for index, effectType in ipairs(EFFECT_TYPES) do
        -- Copy the loop variable into a fresh local so the click handler is not
        -- bound to the shared loop upvalue (Lua 5.1 closure semantics).
        local currentType = effectType
        local b = S.UI:CreateButton(page.root, "target_effects_tab_" .. currentType, EFFECT_LABELS[currentType], 12 + (index - 1) * 70, 274, 64, 25, 9, index == 1)
        S.UI:SafeHandler(b, "OnClick", function()
            page.effectType = currentType
            local service = GetService()
            if service ~= nil and type(service.SetCaptureLane) == "function" then
                service:SetCaptureLane(page.captureScope, page.effectType)
            end
            page:Refresh()
        end, "target:effects_tab:" .. currentType)
        page.effectsTabs = page.effectsTabs or {}
        page.effectsTabs[currentType] = b
    end
    page.effectsHint = S.UI:CreateLabel(page.root, "target_effects_hint", "点击行追加/取消追踪（追踪白名单由 BUFF显示 Authority 管理）", 12, 302, 720, 16, 8, "muted", ALIGN_LEFT)
    for i = 1, 10 do
        local rowIndex = i
        local row = S.UI:CreateButton(page.root, "target_effects_row_" .. rowIndex, "", 12, 322 + (rowIndex - 1) * 22, 720, 20, 9, false)
        row.rsEffectIcon = row.CreateIconDrawable and row:CreateIconDrawable("artwork") or nil
        if row.rsEffectIcon ~= nil then
            row.rsEffectIcon:SetExtent(18, 18)
            row.rsEffectIcon:AddAnchor("LEFT", row, 4, 0)
            row.rsEffectIcon:SetVisible(false)
        end
        page.effectRows[rowIndex] = row
        S.UI:SafeHandler(row, "OnClick", function()
            local effect = page.effectRowData and page.effectRowData[rowIndex] or nil
            if effect ~= nil then ToggleTrack(page.captureScope, page.effectType, effect, page) end
        end, "target:effects_row:" .. rowIndex)
    end

    page.diagTitle = S.UI:CreateLabel(page.root, "target_section_diag", "诊断", 12, 546, 200, 20, 12, nil, ALIGN_LEFT)
    page.diagLines = {}
    for i = 1, 4 do
        page.diagLines[i] = S.UI:CreateLabel(page.root, "target_diag_line_" .. i, "", 12, 570 + (i - 1) * 18, 720, 16, 9, "muted", ALIGN_LEFT)
    end

    S.UI:SafeHandler(page.scopeToggle, "OnClick", function()
        page.captureScope = page.captureScope == "target" and "player" or "target"
        local service = GetService()
        if service ~= nil and type(service.SetCaptureLane) == "function" then
            service:SetCaptureLane(page.captureScope, page.effectType)
        end
        page:Refresh()
    end, "target:effects_scope")

    S.UI:SafeHandler(page.globalToggle, "OnClick", function()
        local service = GetService()
        if service == nil then return end
        service:SetGlobalDetection(not service.globalDetection)
        page:Refresh()
    end, "target:control:global")
    S.UI:SafeHandler(page.retainToggle, "OnClick", function()
        local service = GetService()
        if service == nil then return end
        service:SetQueueRetain(not service:IsQueueRetain())
        page:Refresh()
    end, "target:control:retain")
    S.UI:SafeHandler(page.captureToggle, "OnClick", function()
        local service = GetService()
        if service == nil then return end
        if service:IsCaptureEnabled() then
            service:StopCapture()
        else
            service:StartCapture(page.captureScope, page.effectType)
        end
        page:Refresh()
    end, "target:control:capture")
    S.UI:SafeHandler(page.scanNow, "OnClick", function()
        local service = GetService()
        if service == nil then return end
        service:ScanNow(page.captureScope)
        page:Refresh()
    end, "target:control:scan")
    S.UI:SafeHandler(page.clearQueue, "OnClick", function()
        local service = GetService()
        if service == nil then return end
        service:ClearQueue()
        page:Refresh()
    end, "target:control:clear")
    S.UI:SafeHandler(page.printDiag, "OnClick", function()
        local service = GetService()
        if service == nil then return end
        service:PrintDiagnostic()
    end, "target:control:print")

    function page:Refresh()
        local service = GetService()
        if service == nil then return end
        local isVisiblePage = S.UI ~= nil and S.UI.currentPage == "target"
        -- ApplyLayout() is invoked for every page during a shell reflow, including
        -- hidden pages. Never let that lifecycle path resurrect a hidden inspector
        -- subscription and keep all target scanner lanes running in the background.
        if isVisiblePage then
            local wanted = { "identity", "vitals", "distance", "profession", "gear", "targetOfTarget" }
            if self.captureScope == "target" then wanted[#wanted + 1] = "effects" end
            local wantedSignature = table.concat(wanted, ",")
            if self._subscribed ~= true or self._subscriptionSignature ~= wantedSignature then
                service:Subscribe(PAGE_OWNER, wanted)
                self._subscribed = true
                self._subscriptionSignature = wantedSignature
            end
        elseif self._subscribed == true then
            service:Unsubscribe(PAGE_OWNER)
            self._subscribed = false
        end

        local d = service:Describe()
        if d.captureEnabled == true then
            self.captureScope = d.captureScope == "player" and "player" or "target"
            self.effectType = (d.captureEffectType == "debuff" or d.captureEffectType == "hidden") and d.captureEffectType or "buff"
        end

        self.globalToggle:SetText(d.globalDetection and "全局检测：开" or "全局检测：关")
        S.Theme:SetButtonActive(self.globalToggle, d.globalDetection == true)
        self.retainToggle:SetText(d.captureSticky and "队列保留：开" or "队列保留：关")
        self.captureToggle:SetText(d.captureEnabled and "停止持续检测" or "开始持续检测")
        self.scopeToggle:SetText(self.captureScope == "player" and "对象：自己" or "对象：目标")
        S.Theme:SetButtonActive(self.scopeToggle, self.captureScope == "player")

        local info = {}
        if d.hasTarget then
            info[1] = "名称：" .. tostring(d.name or "--") .. " · 类型：" .. tostring(d.identity.kind) .. " · 关系：" .. tostring(d.identity.relation)
            local hpText = d.vitals.valid == true
                and (tostring(d.vitals.hp or "?") .. "/" .. tostring(d.vitals.maxHp or "?"))
                or "不可用"
            local distanceText = d.distance.valid == true and tostring(d.distance.value or "不可用") or "不可用"
            info[2] = "血量：" .. hpText
                .. (d.vitals.valid == true and d.vitals.dead and " · 已死亡" or "") .. " · 距离：" .. distanceText
            info[3] = "职业：" .. tostring(d.profession.name or "未知") .. " · 装等：" .. tostring(d.gear.score or "不可用")
            info[4] = "Buff/Debuff/Hidden：" .. tostring(d.effectCounts.buff) .. "/" .. tostring(d.effectCounts.debuff) .. "/" .. tostring(d.effectCounts.hidden)
            info[5] = "目标的目标：" .. tostring(d.targetOfTarget and d.targetOfTarget.name or "未知")
        else
            info[1] = "当前无目标（" .. tostring(d.validity) .. "）"
            info[2] = ""
            info[3] = ""
            info[4] = ""
            info[5] = ""
        end
        for i = 1, 5 do self.infoLines[i]:SetText(info[i] or "") end

        for _, effectType in ipairs(EFFECT_TYPES) do
            local b = self.effectsTabs[effectType]
            if b ~= nil then S.Theme:SetButtonActive(b, self.effectType == effectType) end
        end

        local effects = type(service.GetInspectionEffects) == "function"
            and service:GetInspectionEffects(self.captureScope, self.effectType)
            or service:GetEffects(self.effectType) or {}
        page.effectRowData = {}
        local visibleRows = math.max(1, math.min(#self.effectRows, tonumber(self.visibleEffectRows) or #self.effectRows))
        for i = 1, #self.effectRows do
            local effect = i <= visibleRows and effects[i] or nil
            local row = self.effectRows[i]
            if effect ~= nil then
                page.effectRowData[i] = effect
                local tracked = IsTracked(self.captureScope, self.effectType, effect.stableId or effect.id)
                local sourceText = effect.captured == true and "已捕获" or "当前"
                row:SetText(string.format("[%s] %s | ID %s | %d层 | %s | %s",
                    sourceText, tostring(effect.name or "?"), tostring(effect.id or "?"), tonumber(effect.stack) or 0,
                    FormatRemaining(effect.remainingMs), tracked and "已追踪" or "未追踪"))
                SetEffectIcon(row.rsEffectIcon, tostring(effect.iconPath or ""))
                row:Show(true)
                S.Theme:SetButtonActive(row, tracked)
            else
                page.effectRowData[i] = nil
                row:SetText("")
                SetEffectIcon(row.rsEffectIcon, "")
                row:Show(false)
            end
        end

        self.diagLines[1]:SetText("Revision " .. tostring(d.revision) .. " · " .. tostring(d.changedReason) .. " · " .. tostring(d.validity) .. " · Key " .. tostring(d.key or "--"))
        self.diagLines[2]:SetText("数据源：name=" .. tostring(d.sourceStatus.name) .. " unitId=" .. tostring(d.sourceStatus.unitId)
            .. " identity=" .. tostring(d.sourceStatus.identity) .. " dps=" .. tostring(d.sourceStatus.identity_dps) .. " vitals=" .. tostring(d.sourceStatus.vitals) .. " distance=" .. tostring(d.sourceStatus.distance))
        self.diagLines[3]:SetText("profession=" .. tostring(d.sourceStatus.profession) .. " gear=" .. tostring(d.sourceStatus.gear)
            .. " buff=" .. tostring(d.sourceStatus.effects_buff) .. " debuff=" .. tostring(d.sourceStatus.effects_debuff) .. " hidden=" .. tostring(d.sourceStatus.effects_hidden))
        self.diagLines[4]:SetText("消费者 " .. tostring(d.consumerCount) .. " · 缓存 " .. tostring(d.cacheSize)
            .. " · 命中/未命中 " .. tostring(d.cacheHits) .. "/" .. tostring(d.cacheMisses)
            .. " · lanes fast=" .. tostring(d.lanes.fast == true) .. " normal=" .. tostring(d.lanes.normal == true) .. " slow=" .. tostring(d.lanes.slow == true))

        -- While visible, keep the row text live through the Suite scheduler (no
        -- new OnUpdate owner). The task is removed as soon as the page hides.
        if S.Scheduler ~= nil and type(S.Scheduler.AddTask) == "function" and isVisiblePage then
            if page._liveTaskAdded ~= true then
                page._liveTaskAdded = true
                S.Scheduler:AddTask("target_page_refresh", 500, function()
                    if S.UI == nil or S.UI.currentPage ~= "target" then return end
                    local ok, err = xpcall(function() page:Refresh() end, S.SafeTraceback)
                    if not ok and S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Record) == "function" then
                        S.DiagnosticsManager:Record("warning", "target_page", tostring(err))
                    end
                end, false, page, "P4")
            end
        end
    end

    function page:OnPageHidden()
        local service = GetService()
        if service ~= nil and self._subscribed == true then service:Unsubscribe(PAGE_OWNER) end
        self._subscribed = false
        self._subscriptionSignature = nil
        if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then
            S.Scheduler:RemoveTask("target_page_refresh")
        end
        page._liveTaskAdded = false
    end

    function page:ApplyLayout(spec)
        S.UI:SetAnchor(self.root, parent, 0, 0)
        self.root:SetExtent(spec.contentWidth, spec.contentHeight)
        local sc = S.Layout:GetContext().addonScale
        local pad = 12 * sc
        local full = math.max(1, spec.contentWidth - pad * 2)
        local three = math.max(1, (full - 12 * sc) / 3)

        self.title:SetExtent(full, 28 * sc); S.UI:SetAnchor(self.title, self.root, pad, 8 * sc)

        self.globalToggle:SetExtent(three, 27 * sc); S.UI:SetAnchor(self.globalToggle, self.root, pad, 46 * sc)
        self.retainToggle:SetExtent(three, 27 * sc); S.UI:SetAnchor(self.retainToggle, self.root, pad + three + 6 * sc, 46 * sc)
        self.captureToggle:SetExtent(three, 27 * sc); S.UI:SetAnchor(self.captureToggle, self.root, pad + (three + 6 * sc) * 2, 46 * sc)
        self.scanNow:SetExtent(three, 27 * sc); S.UI:SetAnchor(self.scanNow, self.root, pad, 79 * sc)
        self.clearQueue:SetExtent(three, 27 * sc); S.UI:SetAnchor(self.clearQueue, self.root, pad + three + 6 * sc, 79 * sc)
        self.printDiag:SetExtent(three, 27 * sc); S.UI:SetAnchor(self.printDiag, self.root, pad + (three + 6 * sc) * 2, 79 * sc)

        self.infoTitle:SetExtent(full, 20 * sc); S.UI:SetAnchor(self.infoTitle, self.root, pad, 116 * sc)
        for i = 1, 5 do
            self.infoLines[i]:SetExtent(full, 18 * sc)
            S.UI:SetAnchor(self.infoLines[i], self.root, pad, 138 * sc + (i - 1) * 20 * sc)
        end

        self.effectsTitle:SetExtent(full, 20 * sc); S.UI:SetAnchor(self.effectsTitle, self.root, pad, 244 * sc)
        for index, effectType in ipairs(EFFECT_TYPES) do
            local b = self.effectsTabs[effectType]
            b:SetExtent(64 * sc, 25 * sc)
            S.UI:SetAnchor(b, self.root, pad + (index - 1) * 70 * sc, 268 * sc)
        end
        self.scopeToggle:SetExtent(96 * sc, 25 * sc)
        S.UI:SetAnchor(self.scopeToggle, self.root, pad + 216 * sc, 268 * sc)
        self.effectsHint:SetExtent(full, 16 * sc); S.UI:SetAnchor(self.effectsHint, self.root, pad, 296 * sc)

        -- The main Suite window can shrink to 600px. Keep diagnostics inside the
        -- content rect and dynamically use the remaining height for effect rows
        -- instead of letting the fixed ten-row list overflow below the page.
        local rowsTop = 316 * sc
        local diagBlockHeight = 96 * sc
        local diagY = math.max(rowsTop + 30 * sc, spec.contentHeight - diagBlockHeight)
        local availableRows = math.floor((diagY - rowsTop - 8 * sc) / (22 * sc))
        self.visibleEffectRows = math.max(1, math.min(#self.effectRows, availableRows))
        for i = 1, #self.effectRows do
            self.effectRows[i]:SetExtent(full, 20 * sc)
            S.UI:SetAnchor(self.effectRows[i], self.root, pad, rowsTop + (i - 1) * 22 * sc)
            if i > self.visibleEffectRows then self.effectRows[i]:Show(false) end
        end

        self.diagTitle:SetExtent(full, 20 * sc); S.UI:SetAnchor(self.diagTitle, self.root, pad, diagY)
        for i = 1, 4 do
            self.diagLines[i]:SetExtent(full, 16 * sc)
            S.UI:SetAnchor(self.diagLines[i], self.root, pad, diagY + 22 * sc + (i - 1) * 18 * sc)
        end
        self:Refresh()
    end

    page:Refresh()
    S.UI.pages.target = page
    return page
end

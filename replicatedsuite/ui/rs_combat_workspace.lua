------------------------------------------------------------------------
-- Replicated Suite - Combat Workspaces (M5 v1)
--
-- Purpose:
--   * turn Team / DPS / Healer / Gear / Plates into real combat workspaces;
--   * keep each professional module's existing Domain + persistence Authority;
--   * present high-frequency read views with RSUI TableView virtualization;
--   * keep the mature legacy editor as an embedded "高级设置" surface while
--     migration proceeds, so M5 never deletes working controls in one jump;
--   * use scheduler-bound refresh only while the relevant workspace is visible.
--
-- Authority boundary:
--   This file is Presentation/Proxy only. It never scans X2 APIs directly and
--   never persists a second copy of professional state. Every action delegates
--   to ModuleManager, HudManager, Suite services or the module's exported
--   facade/Domain.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI = S.RSUI
if type(RSUI) ~= "table" then return end

S.CombatWorkspace = {}
local CWS = S.CombatWorkspace

local function Export(moduleId, exportName)
    local sandbox = ReplicatedSuiteModuleSandbox
    local value = sandbox ~= nil and sandbox:GetExport(moduleId, exportName) or nil
    if value == nil then value = rawget(_G, tostring(exportName or "")) end
    return value
end

local function BoolText(value)
    return value == true and "开" or "关"
end

local function ModuleText(moduleId)
    local detail = S.ModuleManager ~= nil and S.ModuleManager:Describe(moduleId) or nil
    if detail == nil then return "未注册", "red", false end
    if detail.state == "Faulted" then return "初始化失败", "red", detail.enabled == true end
    if detail.enabled == true then return "运行中", "green", true end
    return "已关闭", "muted", false
end

local function CompactNumber(value)
    local n = tonumber(value) or 0
    local abs = math.abs(n)
    local suffix, divisor = "", 1
    if abs >= 1000000000 then suffix, divisor = "b", 1000000000
    elseif abs >= 1000000 then suffix, divisor = "m", 1000000
    elseif abs >= 1000 then suffix, divisor = "k", 1000 end
    if divisor == 1 then return tostring(math.floor(n + (n >= 0 and 0.5 or -0.5))) end
    local scaled = n / divisor
    if math.abs(scaled) >= 100 then return string.format("%.0f%s", scaled, suffix) end
    if math.abs(scaled) >= 10 then return string.format("%.1f%s", scaled, suffix) end
    return string.format("%.2f%s", scaled, suffix)
end

local function CreateSelectableRow(prefix, list, poolIndex, tableView, onActivate)
    local row = RSUI:TableRow({
        id = prefix .. "_row_" .. tostring(poolIndex),
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
            if index ~= nil and type(tableView.SetSelectedIndex) == "function" then tableView:SetSelectedIndex(index) end
            if type(onActivate) == "function" and row.item ~= nil then onActivate(row.item, false) end
            return true
        end, prefix .. ":row_click:" .. tostring(poolIndex))
        S.UI:SafeHandler(row.root, "OnRButtonUp", function()
            if type(onActivate) == "function" and row.item ~= nil then onActivate(row.item, true) end
            return true
        end, prefix .. ":row_right:" .. tostring(poolIndex))
    end
    return row
end

local function CreateOverviewRoot(parent, id)
    local view = {}
    view.component = RSUI:Border({
        id = id .. "_overview", parent = parent,
        width = 100, height = 100, padding = 6, variant = "soft", gradient = false,
    })
    view.root = view.component and view.component.root or nil
    if view.root == nil then return nil end
    if view.root.rsBorder and view.root.rsBorder.SetVisible then view.root.rsBorder:SetVisible(false) end
    if view.root.rsBackground and view.root.rsBackground.SetVisible then view.root.rsBackground:SetVisible(false) end
    view.stack = RSUI:VerticalBox({ id = id .. "_overview_stack", parent = view.component, gap = 6 })
    return view
end

local function CreateActionRow(parent, id, actions)
    local row = RSUI:HorizontalBox({
        id = id, parent = parent, gap = 4,
        slot = { size = "fixed", height = 28, hAlign = "fill" },
    })
    local buttons = {}
    for index, action in ipairs(actions or {}) do
        buttons[index] = RSUI:Button({
            id = id .. "_action_" .. tostring(index), parent = row,
            text = tostring(action.text or "操作"), fontSize = 8, compact = true, gradient = true,
            slot = action.fill == true
                and { size = "fill", fill = tonumber(action.weight) or 1, minWidth = tonumber(action.minWidth) or 46, hAlign = "fill" }
                or { size = "fixed", width = tonumber(action.width) or 72, hAlign = "fill" },
            onClick = action.onClick,
        })
    end
    return row, buttons
end

local function SetRows(tableView, rows, signature, cache)
    signature = tostring(signature or "")
    -- Non-selectable overview tables include every displayed field in the
    -- signature. If it did not change, keep the existing item array/pool bound
    -- exactly as-is and avoid even a diff-only visible-row rebind.
    if cache.signature == signature then return false end
    cache.signature = signature
    tableView:SetItems(rows, signature)
    return true
end

------------------------------------------------------------------------
-- Generic workspace wrapper. Legacy editor remains a sibling page root so a
-- wrapper failure can safely fall back to the already-created mature page.
------------------------------------------------------------------------
local function WrapLegacy(parent, key, moduleId, title, subtitle, legacyPage, overviewBuilder, refreshInterval)
    if legacyPage == nil or legacyPage.root == nil then return legacyPage end

    local page = {
        key = key,
        parent = parent,
        moduleId = moduleId,
        legacy = legacyPage,
        mode = "overview",
        lastSpec = nil,
        refreshTask = "combat_workspace_refresh_" .. tostring(key),
        refreshInterval = math.max(250, tonumber(refreshInterval) or 1000),
        refreshScheduled = false,
    }

    page.component = RSUI:Border({
        id = "combat_workspace_" .. key, parent = parent,
        width = 100, height = 100, padding = 0, variant = "soft", gradient = false,
    })
    page.root = page.component and page.component.root or nil
    if page.root == nil then return legacyPage end
    if page.root.rsBorder and page.root.rsBorder.SetVisible then page.root.rsBorder:SetVisible(false) end
    if page.root.rsBackground and page.root.rsBackground.SetVisible then page.root.rsBackground:SetVisible(false) end

    page.stack = RSUI:VerticalBox({ id = "combat_workspace_" .. key .. "_stack", parent = page.component, gap = 6 })
    page.header = RSUI:Border({
        id = "combat_workspace_" .. key .. "_header", parent = page.stack,
        height = 58, padding = { left = 8, right = 8, top = 5, bottom = 5 },
        variant = "card", gradient = true, accentStrip = 2,
        slot = { size = "fixed", height = 58, hAlign = "fill" },
    })
    page.headerRow = RSUI:HorizontalBox({ id = "combat_workspace_" .. key .. "_header_row", parent = page.header, gap = 4 })
    page.titleStack = RSUI:VerticalBox({
        id = "combat_workspace_" .. key .. "_title_stack", parent = page.headerRow, gap = 1,
        slot = { size = "fill", fill = 1, minWidth = 100, hAlign = "fill" },
    })
    page.title = RSUI:Text({
        id = "combat_workspace_" .. key .. "_title", parent = page.titleStack,
        text = title, tone = "accent", fontSize = 13, shadow = true, overflow = "ellipsis",
        slot = { size = "fixed", height = 23, hAlign = "fill" },
    })
    page.subtitle = RSUI:Text({
        id = "combat_workspace_" .. key .. "_subtitle", parent = page.titleStack,
        text = subtitle, tone = "muted", fontSize = 8, overflow = "ellipsis",
        slot = { size = "fixed", height = 18, hAlign = "fill" },
    })
    page.status = RSUI:Text({
        id = "combat_workspace_" .. key .. "_status", parent = page.headerRow,
        text = "--", tone = "muted", fontSize = 9, overflow = "ellipsis",
        slot = { size = "fixed", width = 76, hAlign = "fill", vAlign = "center" },
    })
    page.overviewTab = RSUI:Button({
        id = "combat_workspace_" .. key .. "_tab_overview", parent = page.headerRow,
        text = "总览", fontSize = 8, compact = true, selected = true,
        slot = { size = "fixed", width = 52, hAlign = "fill" },
        onClick = function() page:SetMode("overview"); return true end,
    })
    page.settingsTab = RSUI:Button({
        id = "combat_workspace_" .. key .. "_tab_settings", parent = page.headerRow,
        text = "高级设置", fontSize = 8, compact = true,
        slot = { size = "fixed", width = 68, hAlign = "fill" },
        onClick = function() page:SetMode("settings"); return true end,
    })
    page.moduleToggle = RSUI:Button({
        id = "combat_workspace_" .. key .. "_module", parent = page.headerRow,
        text = "启用模块", fontSize = 8, compact = true,
        slot = { size = "fixed", width = 68, hAlign = "fill" },
        onClick = function()
            if S.ModuleManager ~= nil then
                local ok, err = S.ModuleManager:SetEnabled(moduleId, not S.ModuleManager:IsEnabled(moduleId))
                if ok ~= true then S.SafeChat(title .. " 切换失败：" .. tostring(err or "未知原因")) end
            end
            page:Refresh()
            return true
        end,
    })
    page.hudManager = RSUI:Button({
        id = "combat_workspace_" .. key .. "_hud", parent = page.headerRow,
        text = "HUD", fontSize = 8, compact = true,
        slot = { size = "fixed", width = 42, hAlign = "fill" },
        onClick = function()
            if S.UI ~= nil and type(S.UI.ShowPage) == "function" then S.UI:ShowPage("hud") end
            return true
        end,
    })

    page.body = RSUI:Border({
        id = "combat_workspace_" .. key .. "_body", parent = page.stack,
        width = 100, height = 100, padding = 0, variant = "soft", gradient = false,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })
    if page.body.root.rsBorder and page.body.root.rsBorder.SetVisible then page.body.root.rsBorder:SetVisible(false) end
    if page.body.root.rsBackground and page.body.root.rsBackground.SetVisible then page.body.root.rsBackground:SetVisible(false) end

    local okOverview, overview = xpcall(function() return overviewBuilder(page, page.body.root) end, S.SafeTraceback)
    if not okOverview or overview == nil or overview.root == nil then
        S.WarnOnce("combat_workspace_overview:" .. key, "战斗总览创建失败，保留旧页面：" .. tostring(overview))
        page.root:Show(false)
        S.UI.pages[key] = legacyPage
        return legacyPage
    end
    page.overview = overview

    function page:IsActive()
        return S.UI ~= nil and S.UI.currentPage == self.key
            and S.State ~= nil and S.State.ui ~= nil and S.State.ui.main ~= nil
            and S.State.ui.main.collapsed ~= true
    end

    function page:StopRefreshTask()
        if self.refreshScheduled and S.Scheduler ~= nil then S.Scheduler:RemoveTask(self.refreshTask) end
        self.refreshScheduled = false
    end

    function page:EnsureRefreshTask()
        if self.mode ~= "overview" or not self:IsActive() or S.Scheduler == nil then
            self:StopRefreshTask()
            return
        end
        if self.refreshScheduled then return end
        self.refreshScheduled = true
        S.Scheduler:AddTask(self.refreshTask, self.refreshInterval, function()
            if not page:IsActive() or page.mode ~= "overview" then page:StopRefreshTask(); return end
            if page.overview ~= nil and type(page.overview.Refresh) == "function" then
                local ok, err = xpcall(function() page.overview:Refresh(false) end, S.SafeTraceback)
                if not ok then S.WarnOnce("combat_workspace_tick:" .. key, "战斗总览刷新异常：" .. tostring(err)) end
            end
        end, false, page, "P4")
    end

    function page:RefreshHeader()
        local text, tone, enabled = ModuleText(self.moduleId)
        self.status:SetText(text)
        self.status:SetTone(tone)
        self.moduleToggle:SetText(enabled and "关闭模块" or "启用模块")
        if type(self.overviewTab.SetSelected) == "function" then self.overviewTab:SetSelected(self.mode == "overview") end
        if type(self.settingsTab.SetSelected) == "function" then self.settingsTab:SetSelected(self.mode == "settings") end
    end

    function page:SetMode(mode, reflow)
        mode = mode == "settings" and "settings" or "overview"
        self.mode = mode
        self:RefreshHeader()
        if self.overview ~= nil and self.overview.root ~= nil then self.overview.root:Show(mode == "overview") end
        if self.body ~= nil and self.body.root ~= nil then self.body.root:Show(mode == "overview") end
        if self.legacy ~= nil and self.legacy.root ~= nil then self.legacy.root:Show(mode == "settings" and self:IsActive()) end
        if mode == "settings" and self.legacy ~= nil and type(self.legacy.Refresh) == "function" then
            local ok, err = xpcall(function() self.legacy:Refresh() end, S.SafeTraceback)
            if not ok then S.WarnOnce("combat_legacy_refresh:" .. key, "高级设置刷新异常：" .. tostring(err)) end
        elseif mode == "overview" and self.overview ~= nil and type(self.overview.Refresh) == "function" then
            self.overview:Refresh(true)
        end
        if reflow ~= false and self.lastSpec ~= nil then self:ApplyLayout(self.lastSpec) end
        self:EnsureRefreshTask()
        return true
    end

    function page:SetSection(sectionId, reflow)
        self:SetMode("settings", false)
        local ok = false
        if self.legacy ~= nil and type(self.legacy.SetSection) == "function" then
            ok = self.legacy:SetSection(sectionId, false) == true
        end
        if reflow ~= false and self.lastSpec ~= nil then self:ApplyLayout(self.lastSpec) end
        self:Refresh()
        return ok
    end

    function page:Refresh()
        self:RefreshHeader()
        if not self:IsActive() then
            if self.legacy ~= nil and self.legacy.root ~= nil then self.legacy.root:Show(false) end
            self:StopRefreshTask()
            return false
        end
        if self.mode == "overview" then
            self.body.root:Show(true)
            self.overview.root:Show(true)
            self.legacy.root:Show(false)
            if type(self.overview.Refresh) == "function" then self.overview:Refresh(true) end
        else
            self.body.root:Show(false)
            self.overview.root:Show(false)
            self.legacy.root:Show(true)
            if type(self.legacy.Refresh) == "function" then self.legacy:Refresh() end
        end
        self:EnsureRefreshTask()
        return true
    end

    function page:OnPageHidden()
        self:StopRefreshTask()
        if self.legacy ~= nil and self.legacy.root ~= nil then self.legacy.root:Show(false) end
        if self.legacy ~= nil and type(self.legacy.OnPageHidden) == "function" then
            pcall(function() self.legacy:OnPageHidden() end)
        end
    end

    function page:ApplyLayout(spec)
        spec = spec or S.Layout:GetMainSpec()
        self.lastSpec = spec
        local width = math.max(1, tonumber(spec.contentWidth) or 1)
        local height = math.max(1, tonumber(spec.contentHeight) or 1)
        local scale = S.Layout:GetContext().addonScale
        self.component:LayoutIfNeeded(0, 0, width, height)

        local headerH = 58 * scale
        local gap = 6 * scale
        if self.mode == "overview" then
            self.body.root:Show(true)
            local bodyW = tonumber(self.body.width) or width
            local bodyH = tonumber(self.body.height) or math.max(1, height - headerH - gap)
            if self.body.root.GetWidth ~= nil then
                local okW, valueW = pcall(function() return self.body.root:GetWidth() end)
                if okW and tonumber(valueW) ~= nil and tonumber(valueW) > 0 then bodyW = tonumber(valueW) end
            end
            if self.body.root.GetHeight ~= nil then
                local okH, valueH = pcall(function() return self.body.root:GetHeight() end)
                if okH and tonumber(valueH) ~= nil and tonumber(valueH) > 0 then bodyH = tonumber(valueH) end
            end
            self.overview.component:LayoutIfNeeded(0, 0, bodyW, bodyH)
            self.overview.root:Show(self:IsActive())
            self.legacy.root:Show(false)
        else
            self.body.root:Show(false)
            self.overview.root:Show(false)
            local legacyH = math.max(1, height - headerH - gap)
            if type(self.legacy.ApplyLayout) == "function" then
                local legacySpec = { contentWidth = width, contentHeight = legacyH }
                local ok, err = xpcall(function() self.legacy:ApplyLayout(legacySpec) end, S.SafeTraceback)
                if not ok then S.WarnOnce("combat_legacy_layout:" .. key, "高级设置布局异常：" .. tostring(err)) end
            end
            if self.legacy.root ~= nil then
                S.UI:SetAnchor(self.legacy.root, parent, 0, headerH + gap)
                self.legacy.root:Show(self:IsActive())
            end
        end
    end

    page:SetMode("overview", false)
    legacyPage.root:Show(false)
    S.UI.pages[key] = page
    return page
end

------------------------------------------------------------------------
-- Team overview
------------------------------------------------------------------------
local function BuildTeamOverview(workspace, parent)
    -- M5 v6 deep Team Utility workspace.  Keep the original M5 v1 overview as
    -- a safe fallback so a presentation failure can never remove the mature
    -- legacy Team Utility page.
    if S.CombatTeamWorkspace ~= nil and type(S.CombatTeamWorkspace.Build) == "function" then
        local ok, upgraded = xpcall(function() return S.CombatTeamWorkspace:Build(workspace, parent) end, S.SafeTraceback)
        if ok and upgraded ~= nil and upgraded.root ~= nil then return upgraded end
        S.WarnOnce("combat_team_v6_fallback", "团队辅助深度工作区创建失败，已回退 M5 v1 总览：" .. tostring(upgraded))
    end
    local view = CreateOverviewRoot(parent, "combat_team")
    if view == nil then return nil end
    view.cache = {}
    view.rows = {}

    CreateActionRow(view.stack, "combat_team_actions", {
        { text = "立即应用职责", width = 88, onClick = function()
            local svc = S.Services and S.Services.TeamUtility
            if svc and type(svc.ApplyRole) == "function" then svc:ApplyRole("workspace", true) end
            workspace:Refresh(); return true
        end },
        { text = "Buff / 职业检查", width = 104, onClick = function()
            local svc = S.Services and S.Services.TeamUtility
            if svc and type(svc.RunBuffCheck) == "function" then svc:RunBuffCheck() end
            workspace:Refresh(); return true
        end },
        { text = "攻城装备检查", width = 92, onClick = function()
            local svc = S.Services and S.Services.TeamUtility
            if svc and type(svc.RunSiegeCheck) == "function" then svc:RunSiegeCheck() end
            workspace:Refresh(); return true
        end },
        { text = "死亡回顾历史", width = 92, onClick = function()
            local review = S.Services and S.Services.DamageReview
            if review and type(review.OpenHistory) == "function" then review:OpenHistory()
            elseif review and type(review.ToggleHistory) == "function" then review:ToggleHistory() end
            return true
        end },
        { text = "详细设置", fill = true, onClick = function() workspace:SetMode("settings"); return true end },
    })

    view.summary = RSUI:Text({
        id = "combat_team_summary", parent = view.stack,
        text = "团队状态：--", tone = "muted", fontSize = 9, overflow = "ellipsis",
        slot = { size = "fixed", height = 20, hAlign = "fill" },
    })
    local columns = {
        { id = "feature", title = "功能", width = 112, minWidth = 80, absoluteMinWidth = 54, field = "feature" },
        { id = "state", title = "状态", width = 72, minWidth = 56, absoluteMinWidth = 40, field = "state", getTone = function(row) return row and row.tone or "muted" end },
        { id = "detail", title = "实时信息", size = "fill", minWidth = 140, absoluteMinWidth = 72, field = "detail", tone = "muted" },
    }
    view.table = RSUI:TableView({
        id = "combat_team_table", parent = view.stack,
        columns = columns, rowHeight = 24, headerHeight = 22, columnGap = 3, items = view.rows,
        overscan = 1, maxPoolSize = 12,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })

    function view:Refresh()
        local stateData = S.State ~= nil and type(S.State.data) == "table" and S.State.data or {}
        local data = type(stateData.teamUtility) == "table" and stateData.teamUtility or {}
        local settings = S.State ~= nil and type(S.State.settings) == "table" and S.State.settings or {}
        local review = S.Services and S.Services.DamageReview
        local reviewLine = review and type(review.GetStatusLine) == "function" and review:GetStatusLine() or "独立记录可用"
        local markerScale = tonumber(data.markerScale) or 1.20
        local roleMode = S.Services and S.Services.TeamUtility and type(S.Services.TeamUtility.GetRoleModeLabel) == "function"
            and S.Services.TeamUtility:GetRoleModeLabel() or "智能"
        local rows = {
            { feature = "自动职责", state = BoolText(settings.teamAutoRoleEnabled), tone = settings.teamAutoRoleEnabled and "green" or "muted", detail = tostring(data.roleStatus or "等待团队状态") .. " · " .. tostring(roleMode) },
            { feature = "牺牲之舞高亮", state = BoolText(settings.sacMarkerEnabled), tone = settings.sacMarkerEnabled and "green" or "muted", detail = "候选 " .. tostring(data.sacCandidates or 0) .. " · 施放中 " .. tostring(data.sacActive or 0) },
            { feature = "死亡伤害回顾", state = BoolText(settings.damageReviewEnabled ~= false), tone = settings.damageReviewEnabled ~= false and "green" or "muted", detail = tostring(reviewLine) },
            { feature = "原生团队标记", state = data.markerScaleAvailable == false and "API不可用" or "可用", tone = data.markerScaleAvailable == false and "red" or "green", detail = "缩放 " .. tostring(math.floor(markerScale * 100 + 0.5)) .. "%" },
        }
        local signature = table.concat({
            tostring(settings.teamAutoRoleEnabled), tostring(data.roleStatus), tostring(data.sacCandidates), tostring(data.sacActive),
            tostring(settings.damageReviewEnabled), tostring(markerScale), tostring(data.markerScaleAvailable), tostring(reviewLine), tostring(roleMode),
        }, "|")
        SetRows(self.table, rows, signature, self.cache)
        self.rows = rows
        self.summary:SetText("团队辅助将操作留在 Service Authority；Buff/攻城检查只在点击时执行，不做额外后台全团扫描。")
        return true
    end
    return view
end

------------------------------------------------------------------------
-- DPS overview
------------------------------------------------------------------------
local function BuildDpsOverview(workspace, parent)
    -- M5 v2 deep workspace is isolated in rs_dps_workspace.lua.  Keep the
    -- M5 v1 overview below as a safe fallback so one deep-view construction
    -- failure can never make the mature DPS page unavailable.
    if S.CombatDpsWorkspace ~= nil and type(S.CombatDpsWorkspace.Build) == "function" then
        local ok, upgraded = xpcall(function() return S.CombatDpsWorkspace:Build(workspace, parent) end, S.SafeTraceback)
        if ok and upgraded ~= nil and upgraded.root ~= nil then return upgraded end
        S.WarnOnce("combat_dps_v2_fallback", "DPS 深度工作区创建失败，已回退 M5 v1 总览：" .. tostring(upgraded))
    end
    local view = CreateOverviewRoot(parent, "combat_dps")
    if view == nil then return nil end
    view.rows = {}
    view.count = 0
    view.revision = 0
    view.side = "friendly"
    view.selectedKey = nil
    view.selectedSource = nil

    view.toolbar, view.actions = CreateActionRow(view.stack, "combat_dps_actions", {
        { text = "模式：PVP", width = 76, onClick = function()
            local d = Export("dps", "ReplicatedDps")
            if d and d.State and d.State.config and d.UI and type(d.UI.SetMode) == "function" then
                d.UI:SetMode(d.State.config.currentMode == "PVP" and "PVE" or "PVP")
            end
            view:Refresh(true); return true
        end },
        { text = "页面：伤害", width = 86, onClick = function()
            local d = Export("dps", "ReplicatedDps")
            if d and d.State and d.State.config and d.UI and type(d.UI.SetPage) == "function" then
                local current = tostring(d.State.config.currentPage or "DAMAGE")
                local nextPage = current == "DAMAGE" and "TAKEN" or (current == "TAKEN" and "HEAL" or "DAMAGE")
                d.UI:SetPage(nextPage)
            end
            view:Refresh(true); return true
        end },
        { text = "阵营：友军", width = 80, onClick = function()
            view.side = view.side == "friendly" and "enemy" or "friendly"
            view.selectedKey, view.selectedSource = nil, nil
            view:Refresh(true); return true
        end },
        { text = "切换当前HUD", width = 82, onClick = function()
            local hudId = view.side == "friendly" and "dps_friendly" or "dps_enemy"
            if S.HudManager and S.HudManager:Get(hudId) then S.HudManager:ToggleVisible(hudId) end
            return true
        end },
        { text = "清空 / 恢复", width = 80, onClick = function()
            local d = Export("dps", "ReplicatedDps")
            if d and d.UI and type(d.UI.ShowClearConfirmation) == "function" then d.UI:ShowClearConfirmation() end
            return true
        end },
        { text = "高级设置", fill = true, onClick = function() workspace:SetMode("settings"); return true end },
    })

    view.summary = RSUI:Text({
        id = "combat_dps_summary", parent = view.stack,
        text = "排行榜：--", tone = "muted", fontSize = 9, overflow = "ellipsis",
        slot = { size = "fixed", height = 20, hAlign = "fill" },
    })
    local columns = {
        { id = "rank", title = "#", width = 34, minWidth = 28, absoluteMinWidth = 24, field = "rank" },
        { id = "name", title = "玩家 / 单位", size = "fill", minWidth = 120, absoluteMinWidth = 60, field = "name" },
        { id = "value", title = "累计", width = 78, minWidth = 62, absoluteMinWidth = 44, field = "valueText" },
        { id = "rate", title = "每秒", width = 72, minWidth = 58, absoluteMinWidth = 42, field = "rateText", tone = "muted" },
        { id = "percent", title = "占比", width = 58, minWidth = 48, absoluteMinWidth = 36, field = "percentText" },
    }
    view.table = RSUI:TableView({
        id = "combat_dps_table", parent = view.stack,
        columns = columns, rowHeight = 22, headerHeight = 22, columnGap = 3,
        getCount = function() return view.count end,
        getItem = function(index) return view.rows[index] end,
        getKey = function(row, index) return row and row.key or index end,
        overscan = 2, maxPoolSize = 28, selectable = true, selectionMode = "single",
        rowFactory = function(list, poolIndex, tableView)
            return CreateSelectableRow("combat_dps", list, poolIndex, tableView, function(row, rightClick)
                if row ~= nil then
                    view.selectedKey = row.key
                    view.selectedSource = row.source
                    if rightClick then
                        local d = Export("dps", "ReplicatedDps")
                        if d and d.UI and type(d.UI.ShowDetail) == "function" then d.UI:ShowDetail(view.side, row.source) end
                    end
                    view:RefreshDetail()
                end
            end)
        end,
        onSelectionChanged = function(index)
            local row = index and view.rows[index] or nil
            view.selectedKey = row and row.key or nil
            view.selectedSource = row and row.source or nil
            view:RefreshDetail()
        end,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })

    view.detailRow = RSUI:HorizontalBox({
        id = "combat_dps_detail_row", parent = view.stack, gap = 4,
        slot = { size = "fixed", height = 28, hAlign = "fill" },
    })
    view.detailText = RSUI:Text({
        id = "combat_dps_detail_text", parent = view.detailRow,
        text = "点击排行榜行查看；右键直接打开技能/目标详情。", tone = "muted", fontSize = 8, overflow = "ellipsis",
        slot = { size = "fill", fill = 1, minWidth = 60, hAlign = "fill", vAlign = "center" },
    })
    view.detailButton = RSUI:Button({
        id = "combat_dps_detail_button", parent = view.detailRow,
        text = "打开详情", fontSize = 8, compact = true,
        slot = { size = "fixed", width = 64, hAlign = "fill" },
        onClick = function()
            local d = Export("dps", "ReplicatedDps")
            if d and d.UI and type(d.UI.ShowDetail) == "function" and view.selectedSource ~= nil then
                d.UI:ShowDetail(view.side, view.selectedSource)
            end
            return true
        end,
    })

    function view:RefreshDetail()
        local row = nil
        if self.selectedKey ~= nil then
            for i = 1, self.count do if self.rows[i] and self.rows[i].key == self.selectedKey then row = self.rows[i]; break end end
        end
        if row == nil then
            self.detailText:SetText("点击排行榜行查看；右键直接打开技能/目标详情。")
            return
        end
        self.detailText:SetText(tostring(row.name) .. " · 累计 " .. tostring(row.valueText) .. " · " .. tostring(row.rateText) .. "/s · " .. tostring(row.percentText))
    end

    function view:Refresh()
        local d = Export("dps", "ReplicatedDps")
        if d == nil or d.State == nil or d.State.config == nil or d.Stats == nil or type(d.Stats.BuildRanking) ~= "function" then
            self.count = 0
            self.summary:SetText("DPS Domain 尚未初始化")
            self.summary:SetTone("red")
            self.table:RefreshVisible("dps:unavailable", true)
            return false
        end
        local mode = tostring(d.State.config.currentMode or "PVP")
        local metricPage = tostring(d.State.config.currentPage or "DAMAGE")
        if metricPage ~= "DAMAGE" and metricPage ~= "TAKEN" and metricPage ~= "HEAL" then metricPage = "DAMAGE" end
        self.actions[1]:SetText("模式：" .. mode)
        local pageLabel = metricPage == "TAKEN" and "承伤" or (metricPage == "HEAL" and "治疗" or "伤害")
        self.actions[2]:SetText("页面：" .. pageLabel)
        self.actions[3]:SetText("阵营：" .. (self.side == "friendly" and "友军" or "敌军"))

        local ok, ranking, total, metric, _, analysisView = xpcall(function()
            return d.Stats:BuildRanking(mode, self.side, metricPage)
        end, S.SafeTraceback)
        if not ok then
            self.summary:SetText("排行榜读取失败：" .. tostring(ranking))
            self.summary:SetTone("red")
            return false
        end
        ranking = type(ranking) == "table" and ranking or {}
        local limit = math.min(#ranking, math.max(1, math.floor(tonumber(d.State.config.displayRows) or 100)))
        local oldCount = self.count
        for index = 1, limit do
            local item = ranking[index]
            local row = self.rows[index] or {}
            row.rank = tostring(index)
            row.key = tostring(item.key or index)
            row.name = tostring(item.name or "未知")
            row.valueText = CompactNumber(item.value)
            row.rateText = CompactNumber(item.rate)
            row.percentText = string.format("%.1f%%", tonumber(item.percent) or 0)
            row.source = item
            self.rows[index] = row
        end
        for index = limit + 1, oldCount do self.rows[index] = nil end
        self.count = limit
        self.revision = self.revision + 1
        if oldCount ~= limit then
            if self.table.list and type(self.table.list.InvalidateMeasure) == "function" then self.table.list:InvalidateMeasure("dps_count") end
            if type(self.table.InvalidateMeasure) == "function" then self.table:InvalidateMeasure("dps_count") end
            if self.table.width and self.table.height then self.table:LayoutIfNeeded(self.table.x or 0, self.table.y or 0, self.table.width, self.table.height, true) end
        end
        self.table:RefreshVisible("dps:" .. tostring(self.revision), true)
        local analysis = type(analysisView) == "table" and analysisView.enabled == true
        local cacheState = type(d.Stats.IsRankingCacheCurrent) == "function" and d.Stats:IsRankingCacheCurrent(mode, self.side, metricPage)
        self.summary:SetTone(cacheState and "green" or "yellow")
        self.summary:SetText(string.format("%s · %s · %s · %d 行 · 总计 %s%s",
            mode, self.side == "friendly" and "友军" or "敌军", pageLabel, limit, CompactNumber(total), analysis and " · Boss/目标分析" or ""))
        self:RefreshDetail()
        return true
    end
    return view
end

------------------------------------------------------------------------
-- Healer overview
------------------------------------------------------------------------
local function BuildHealerOverview(workspace, parent)
    -- M5 v3 deep workspace is isolated in rs_healer_workspace.lua. Keep the
    -- M5 v1 overview below as a safe fallback; a presentation construction
    -- failure must never make the mature Healer settings/editor unavailable.
    if S.CombatHealerWorkspace ~= nil and type(S.CombatHealerWorkspace.Build) == "function" then
        local ok, upgraded = xpcall(function() return S.CombatHealerWorkspace:Build(workspace, parent) end, S.SafeTraceback)
        if ok and upgraded ~= nil and upgraded.root ~= nil then return upgraded end
        S.WarnOnce("combat_healer_v3_fallback", "Healer 深度工作区创建失败，已回退 M5 v1 总览：" .. tostring(upgraded))
    end
    local view = CreateOverviewRoot(parent, "combat_healer")
    if view == nil then return nil end
    view.cache, view.rows = {}, {}

    CreateActionRow(view.stack, "combat_healer_actions", {
        { text = "基础阈值", width = 74, onClick = function() workspace:SetSection("basic"); return true end },
        { text = "BUFF条件", width = 74, onClick = function() workspace:SetSection("buffs"); return true end },
        { text = "团队显示", width = 74, onClick = function() workspace:SetSection("team"); return true end },
        { text = "职责评分", width = 74, onClick = function() workspace:SetSection("roles"); return true end },
        { text = "位置校准", width = 74, onClick = function() workspace:SetSection("cal"); return true end },
        { text = "高级设置", fill = true, onClick = function() workspace:SetMode("settings"); return true end },
    })
    view.summary = RSUI:Text({
        id = "combat_healer_summary", parent = view.stack,
        text = "治疗辅助：--", tone = "muted", fontSize = 9, overflow = "ellipsis",
        slot = { size = "fixed", height = 20, hAlign = "fill" },
    })
    local columns = {
        { id = "feature", title = "参数 / 状态", width = 128, minWidth = 90, absoluteMinWidth = 58, field = "feature" },
        { id = "value", title = "当前", width = 92, minWidth = 68, absoluteMinWidth = 46, field = "value", getTone = function(row) return row and row.tone or "muted" end },
        { id = "detail", title = "说明", size = "fill", minWidth = 150, absoluteMinWidth = 80, field = "detail", tone = "muted" },
    }
    view.table = RSUI:TableView({
        id = "combat_healer_table", parent = view.stack,
        columns = columns, rowHeight = 24, headerHeight = 22, columnGap = 3,
        items = view.rows, overscan = 1, maxPoolSize = 14,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })

    function view:Refresh()
        local h = Export("healer", "ReplicatedHealerModule")
        if h == nil then
            self.summary:SetText("治疗辅助 Domain 尚未初始化")
            self.summary:SetTone("red")
            return false
        end
        local runtime = type(h.GetRuntimeDiagnostics) == "function" and h:GetRuntimeDiagnostics() or {}
        local function Setting(key, fallback)
            if type(h.GetSuiteSetting) == "function" then
                local value = h:GetSuiteSetting(key)
                if value ~= nil then return value end
            end
            return fallback
        end
        local rules = type(h.GetSuiteRules) == "function" and h:GetSuiteRules() or {}
        local tracked = type(h.GetTrackedBuffCount) == "function" and h:GetTrackedBuffCount() or 0
        local maxDistance = Setting("maxDistance", 27)
        local lowHealth = Setting("lowHealthThreshold", 70)
        local emergency = Setting("emergencyThreshold", 50)
        local headMarkerCount = Setting("headMarkerCount", 5)
        local ruleCount = #(rules or {})
        local rows = {
            { feature = "团队成员", value = tostring(runtime.rosterCount or 0), tone = (tonumber(runtime.rosterCount) or 0) > 0 and "green" or "muted", detail = "Roster Authority 当前识别人数" },
            { feature = "治疗距离", value = tostring(maxDistance) .. "m", tone = "green", detail = "治疗推荐与距离底色的主距离阈值" },
            { feature = "低血量阈值", value = tostring(lowHealth) .. "%", tone = "yellow", detail = "低血量显示/评分阈值" },
            { feature = "紧急阈值", value = tostring(emergency) .. "%", tone = "red", detail = "紧急救援优先级" },
            { feature = "头顶推荐数量", value = tostring(headMarkerCount), tone = "green", detail = "头顶标记最大推荐人数" },
            { feature = "BUFF条件组", value = tostring(ruleCount), tone = ruleCount > 0 and "green" or "muted", detail = "用于评分/显示的条件规则" },
            { feature = "追踪 Buff", value = tostring(tracked), tone = (tonumber(tracked) or 0) > 0 and "green" or "muted", detail = "仅消费 Healer Domain 追踪列表" },
        }
        local recommendationInfo = type(runtime.recommendationDomain) == "table" and runtime.recommendationDomain or {}
        local signatureParts = { tostring(runtime.rosterCount), tostring(maxDistance), tostring(lowHealth), tostring(emergency), tostring(headMarkerCount), tostring(ruleCount), tostring(tracked) }
        SetRows(self.table, rows, table.concat(signatureParts, "|"), self.cache)
        self.rows = rows
        self.summary:SetTone("green")
        self.summary:SetText("Roster " .. tostring(runtime.rosterMode or "none") .. " · HealthGen " .. tostring(runtime.healthGeneration or 0) .. " · StatusGen " .. tostring(runtime.statusGeneration or 0) .. (next(recommendationInfo) ~= nil and " · 推荐 Domain 已连接" or ""))
        return true
    end
    return view
end

------------------------------------------------------------------------
-- Gear overview
------------------------------------------------------------------------
local function BuildGearOverview(workspace, parent)
    -- M5 v4 deep Gear workspace lives in rs_gear_workspace.lua. Keep the M5 v1
    -- overview below as a safe fallback; the mature legacy editor remains the
    -- final fallback surface if the new presentation cannot be constructed.
    if S.CombatGearWorkspace ~= nil and type(S.CombatGearWorkspace.Build) == "function" then
        local ok, upgraded = xpcall(function() return S.CombatGearWorkspace:Build(workspace, parent) end, S.SafeTraceback)
        if ok and upgraded ~= nil and upgraded.root ~= nil then return upgraded end
        S.WarnOnce("combat_gear_v4_fallback", "Gear 深度工作区创建失败，已回退 M5 v1 总览：" .. tostring(upgraded))
    end
    local view = CreateOverviewRoot(parent, "combat_gear")
    if view == nil then return nil end
    view.rows, view.count, view.revision = {}, 0, 0
    view.selectedId = nil

    view.toolbar, view.actions = CreateActionRow(view.stack, "combat_gear_actions", {
        { text = "立即换装", width = 74, onClick = function()
            local g = Export("gear", "ReplicatedGear")
            if g and g.Runtime and type(g.Runtime.Start) == "function" and view.selectedId ~= nil then
                local ok, err = g.Runtime:Start(view.selectedId)
                if ok == false and err ~= nil then S.SafeChat("换装失败：" .. tostring(err)) end
            end
            view:Refresh(true); return true
        end },
        { text = "编辑选中", width = 74, onClick = function()
            local g = Export("gear", "ReplicatedGear")
            workspace:SetSection("sets", false)
            if g and g.UI and type(g.UI.SelectSet) == "function" and view.selectedId ~= nil then g.UI:SelectSet(view.selectedId) end
            if workspace.lastSpec then workspace:ApplyLayout(workspace.lastSpec) end
            workspace:Refresh(); return true
        end },
        { text = "切换快捷HUD", width = 88, onClick = function()
            if S.HudManager and S.HudManager:Get("gear_quick") then S.HudManager:ToggleVisible("gear_quick") end
            return true
        end },
        { text = "高级设置", fill = true, onClick = function() workspace:SetMode("settings"); return true end },
    })
    view.summary = RSUI:Text({
        id = "combat_gear_summary", parent = view.stack,
        text = "换装方案：--", tone = "muted", fontSize = 9, overflow = "ellipsis",
        slot = { size = "fixed", height = 20, hAlign = "fill" },
    })
    local columns = {
        { id = "order", title = "#", width = 34, minWidth = 28, absoluteMinWidth = 24, field = "order" },
        { id = "name", title = "方案名称", size = "fill", minWidth = 120, absoluteMinWidth = 64, field = "name" },
        { id = "configured", title = "配置", width = 68, minWidth = 54, absoluteMinWidth = 40, field = "configured", getTone = function(row) return row and row.configuredTone or "muted" end },
        { id = "quick", title = "快捷按钮", width = 72, minWidth = 58, absoluteMinWidth = 42, field = "quick", getTone = function(row) return row and row.quickTone or "muted" end },
        { id = "status", title = "状态", width = 92, minWidth = 66, absoluteMinWidth = 48, field = "status", getTone = function(row) return row and row.statusTone or "muted" end },
    }
    view.table = RSUI:TableView({
        id = "combat_gear_table", parent = view.stack,
        columns = columns, rowHeight = 24, headerHeight = 22, columnGap = 3,
        getCount = function() return view.count end,
        getItem = function(index) return view.rows[index] end,
        getKey = function(row, index) return row and row.id or index end,
        overscan = 2, maxPoolSize = 24, selectable = true, selectionMode = "single",
        rowFactory = function(list, poolIndex, tableView)
            return CreateSelectableRow("combat_gear", list, poolIndex, tableView, function(row, rightClick)
                if row then view.selectedId = row.id end
                if rightClick and row then
                    local g = Export("gear", "ReplicatedGear")
                    if g and g.Runtime and type(g.Runtime.Start) == "function" and row.configuredRaw == true then g.Runtime:Start(row.id) end
                end
            end)
        end,
        onSelectionChanged = function(index)
            local row = index and view.rows[index] or nil
            view.selectedId = row and row.id or nil
        end,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })

    function view:Refresh()
        local g = Export("gear", "ReplicatedGear")
        local core = g and g.Core or nil
        if core == nil or type(core.GetSets) ~= "function" then
            self.count = 0; self.summary:SetText("Gear Domain 尚未初始化"); self.summary:SetTone("red")
            self.table:RefreshVisible("gear:unavailable", true); return false
        end
        local sets = core:GetSets(true)
        local busy = g.Runtime and ((type(g.Runtime.IsBusy) == "function" and g.Runtime:IsBusy()) or g.Runtime.busy == true) or false
        local oldCount = self.count
        local configuredCount = 0
        for index, set in ipairs(sets) do
            if set.configured == true then configuredCount = configuredCount + 1 end
            local row = self.rows[index] or {}
            row.id = tostring(set.id or index)
            row.order = tostring(index)
            row.name = tostring(set.name or row.id)
            row.configuredRaw = set.configured == true
            row.configured = row.configuredRaw and "已配置" or "待配置"
            row.configuredTone = row.configuredRaw and "green" or "yellow"
            row.quick = set.quick == false and "关闭" or "显示"
            row.quickTone = set.quick == false and "muted" or "green"
            row.status = busy and "执行中" or (row.configuredRaw and "可切换" or "需编辑")
            row.statusTone = busy and "yellow" or (row.configuredRaw and "green" or "muted")
            self.rows[index] = row
        end
        for index = #sets + 1, oldCount do self.rows[index] = nil end
        self.count = #sets
        self.revision = self.revision + 1
        if oldCount ~= self.count then
            if self.table.list and type(self.table.list.InvalidateMeasure) == "function" then self.table.list:InvalidateMeasure("gear_count") end
            if type(self.table.InvalidateMeasure) == "function" then self.table:InvalidateMeasure("gear_count") end
        end
        self.table:RefreshVisible("gear:" .. tostring(self.revision), true)
        if self.selectedId == nil and self.rows[1] ~= nil then self.selectedId = self.rows[1].id end
        self.summary:SetTone(busy and "yellow" or "green")
        self.summary:SetText("方案 " .. tostring(self.count) .. " · 已配置 " .. tostring(configuredCount) .. " · " .. (busy and "正在执行换装" or "空闲") .. " · 右键方案可直接切换")
        return true
    end
    return view
end

------------------------------------------------------------------------
-- Plates overview
------------------------------------------------------------------------
local function BuildPlatesOverview(workspace, parent)
    -- M5 v5 deep Plates workspace is isolated in rs_plates_workspace.lua.
    -- Keep the M5 v1 overview below as a safe fallback so a presentation-only
    -- failure never removes access to the mature Plates settings/runtime.
    if S.CombatPlatesWorkspace ~= nil and type(S.CombatPlatesWorkspace.Build) == "function" then
        local ok, upgraded = xpcall(function() return S.CombatPlatesWorkspace:Build(workspace, parent) end, S.SafeTraceback)
        if ok and upgraded ~= nil and upgraded.root ~= nil then return upgraded end
        S.WarnOnce("combat_plates_v5_fallback", "BUFF显示深度工作区创建失败，已回退 M5 v1 总览：" .. tostring(upgraded))
    end
    local view = CreateOverviewRoot(parent, "combat_plates")
    if view == nil then return nil end
    view.cache, view.rows = {}, {}

    CreateActionRow(view.stack, "combat_plates_actions", {
        { text = "目标HUD布局", width = 84, onClick = function() workspace:SetSection("layout", false); local p = Export("plates", "ReplicatedPlates"); if p and p.Manager and type(p.Manager.OpenHUDLayout)=="function" then p.Manager:OpenHUDLayout("target") end; if workspace.lastSpec then workspace:ApplyLayout(workspace.lastSpec) end; return true end },
        { text = "自己HUD布局", width = 84, onClick = function() workspace:SetSection("layout", false); local p = Export("plates", "ReplicatedPlates"); if p and p.Manager and type(p.Manager.OpenHUDLayout)=="function" then p.Manager:OpenHUDLayout("player") end; if workspace.lastSpec then workspace:ApplyLayout(workspace.lastSpec) end; return true end },
        { text = "状态追踪", width = 74, onClick = function() workspace:SetSection("tracking"); return true end },
        { text = "战斗警报", width = 74, onClick = function() workspace:SetSection("alerts"); return true end },
        { text = "外观颜色", width = 74, onClick = function() workspace:SetSection("colors"); return true end },
        { text = "高级设置", fill = true, onClick = function() workspace:SetMode("settings"); return true end },
    })
    view.summary = RSUI:Text({
        id = "combat_plates_summary", parent = view.stack,
        text = "BUFF显示：--", tone = "muted", fontSize = 9, overflow = "ellipsis",
        slot = { size = "fixed", height = 20, hAlign = "fill" },
    })
    local columns = {
        { id = "scope", title = "HUD", width = 72, minWidth = 58, absoluteMinWidth = 40, field = "scope" },
        { id = "effect", title = "类型", width = 68, minWidth = 52, absoluteMinWidth = 38, field = "effect" },
        { id = "tracked", title = "追踪", width = 60, minWidth = 48, absoluteMinWidth = 36, field = "tracked", getTone = function(row) return row and row.trackedTone or "muted" end },
        { id = "discovered", title = "本局发现", width = 72, minWidth = 58, absoluteMinWidth = 42, field = "discovered", tone = "muted" },
        { id = "display", title = "显示策略", size = "fill", minWidth = 120, absoluteMinWidth = 68, field = "display", getTone = function(row) return row and row.displayTone or "muted" end },
    }
    view.table = RSUI:TableView({
        id = "combat_plates_table", parent = view.stack,
        columns = columns, rowHeight = 24, headerHeight = 22, columnGap = 3,
        items = view.rows, overscan = 1, maxPoolSize = 12,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })

    function view:Refresh()
        local p = Export("plates", "ReplicatedPlates")
        if p == nil or p.Storage == nil then
            self.summary:SetText("BUFF显示 Domain 尚未初始化")
            self.summary:SetTone("red")
            return false
        end
        local rows, sig = {}, {}
        local scopeLabels = { target = "目标", player = "自己" }
        local effectLabels = { buff = "Buff", debuff = "Debuff", hidden = "Hidden" }
        for _, scope in ipairs({ "target", "player" }) do
            local plate = type(p.Storage.GetPlate) == "function" and p.Storage:GetPlate(scope) or {}
            for _, effect in ipairs({ "buff", "debuff", "hidden" }) do
                local trackedCount = type(p.Storage.TrackedCount) == "function" and p.Storage:TrackedCount(scope, effect) or 0
                local discovered = p.Manager and type(p.Manager.GetDiscoveredCount) == "function" and p.Manager:GetDiscoveredCount(scope, effect) or 0
                local enabled
                if effect == "buff" then enabled = plate.showBuffs ~= false
                elseif effect == "debuff" then enabled = plate.showDebuffs ~= false
                else enabled = plate.showHidden == true end
                local trackedOnly = plate.trackedOnly ~= false or effect == "hidden"
                local row = {
                    scope = scopeLabels[scope], effect = effectLabels[effect],
                    tracked = tostring(trackedCount), trackedTone = trackedCount > 0 and "green" or "muted",
                    discovered = tostring(discovered),
                    display = enabled and (trackedOnly and "仅追踪" or "全部实时状态") or "该类型隐藏",
                    displayTone = enabled and "green" or "muted",
                }
                rows[#rows + 1] = row
                sig[#sig + 1] = table.concat({ scope, effect, tostring(trackedCount), tostring(discovered), tostring(enabled), tostring(trackedOnly) }, ":")
            end
        end
        SetRows(self.table, rows, table.concat(sig, "|"), self.cache)
        self.rows = rows
        local targetHud = S.HudManager and S.HudManager:Get("plates_target") and S.HudManager:IsVisible("plates_target") == true
        local playerHud = S.HudManager and S.HudManager:Get("plates_player") and S.HudManager:IsVisible("plates_player") == true
        local running = p.Runtime == nil or p.Runtime.running ~= false
        self.summary:SetTone(running and "green" or "yellow")
        self.summary:SetText("Runtime " .. (running and "运行" or "停止") .. " · 目标HUD " .. (targetHud and "显示" or "隐藏") .. " · 自己HUD " .. (playerHud and "显示" or "隐藏") .. " · 发现只进入管理器，不会自动追踪")
        return true
    end
    return view
end

------------------------------------------------------------------------
-- Build all five combat workspaces from mature legacy pages.
------------------------------------------------------------------------
function CWS.CreateAll(parent, legacy)
    legacy = type(legacy) == "table" and legacy or {}
    local result = {}
    local definitions = {
        { key = "team", moduleId = "team_utility", title = "团队辅助", subtitle = "团队职责 / Buff检查 / 牺牲之舞 / 死亡回顾", legacy = legacy.team, builder = BuildTeamOverview, interval = 1000 },
        { key = "dps", moduleId = "dps", title = "伤害统计", subtitle = "PVP / PVE · 伤害 / 承伤 / 治疗 · 友军 / 敌军", legacy = legacy.dps, builder = BuildDpsOverview, interval = 500 },
        { key = "healer", moduleId = "healer", title = "治疗辅助", subtitle = "救援评分 / BUFF条件 / 团队高亮 / 位置校准", legacy = legacy.healer, builder = BuildHealerOverview, interval = 1000 },
        { key = "gear", moduleId = "gear", title = "一键换装", subtitle = "方案工作区 / 快速执行 / 战斗安全切换", legacy = legacy.gear, builder = BuildGearOverview, interval = 1000 },
        { key = "plates", moduleId = "plates", title = "BUFF显示", subtitle = "HUD / 状态追踪 / 战斗警报 / 外观布局 / 导入诊断", legacy = legacy.plates, builder = BuildPlatesOverview, interval = 1000 },
    }
    for _, def in ipairs(definitions) do
        local page = def.legacy
        if page ~= nil then
            local ok, wrapped = xpcall(function()
                return WrapLegacy(parent, def.key, def.moduleId, def.title, def.subtitle, def.legacy, def.builder, def.interval)
            end, S.SafeTraceback)
            if ok and wrapped ~= nil then
                page = wrapped
            else
                S.WarnOnce("combat_workspace_wrap:" .. tostring(def.key), "M5 战斗工作区创建失败，已保留旧页面：" .. tostring(wrapped))
                S.UI.pages[def.key] = def.legacy
            end
        end
        result[def.key] = page
        result[#result + 1] = page
    end
    return result
end

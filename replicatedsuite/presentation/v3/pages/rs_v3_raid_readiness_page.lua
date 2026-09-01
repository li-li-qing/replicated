------------------------------------------------------------------------
-- Replicated Suite V3 - Raid Readiness Page
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI, D = S.RSUI, S.UIV3Design
local PageHost = S.UIV3 and S.UIV3.PageHost or nil
local Feature = S.Features and S.Features.RaidReadiness or nil
if type(RSUI) ~= "table" or type(D) ~= "table" or type(PageHost) ~= "table" or type(Feature) ~= "table" then return end

local STORE_ID = "v3.raid_readiness"
local function Settings() return Feature:GetSettingsProjection() end
local ROUTE = "combat.raid_readiness"

local function RunAction(id, button, execute, busyText)
    if S.ActionRunner ~= nil then
        return S.ActionRunner:Run({ id = "raid_readiness." .. tostring(id), button = button, busyText = busyText or "处理中…", notify = true, execute = execute })
    end
    return execute()
end

local function Columns()
    return {
        { id = "status", title = "状态", field = "statusText", size = "fixed", width = 70, minWidth = 60,
            getTone = function(item) return item and item.tone or "muted" end },
        { id = "name", title = "成员", field = "name", size = "fill", minWidth = 120, fill = 1.2 },
        { id = "role", title = "职责", field = "roleText", size = "fixed", width = 92, minWidth = 76 },
        { id = "gear", title = "装分", field = "gearText", size = "fixed", width = 82, minWidth = 68,
            getTone = function(item)
                if item and item.status == "failed" then return "red" end
                if item and item.gearScore == nil then return "muted" end
                return "default"
            end },
        { id = "distance", title = "距离", field = "distanceText", size = "fixed", width = 74, minWidth = 62 },
        { id = "aura", title = "关键增益", field = "auraText", size = "fixed", width = 104, minWidth = 88,
            getTone = function(item)
                if item and item.requiredAuraCount and item.requiredAuraCount > 0 then
                    if item.status == "failed" then return "red" end
                    if item.status == "unknown" then return "warn" end
                    return "green"
                end
                return "muted"
            end },
        { id = "detail", title = "说明", field = "detailText", size = "fill", minWidth = 180, fill = 1.8,
            getTone = function(item) return item and item.status == "failed" and "red" or (item and item.status == "unknown" and "warn" or "muted") end },
    }
end

local function BuildPage(parent, route)
    local loaded, loadErr = Feature:EnsureStoreLoaded()
    if loaded ~= true then return nil, "团队战备设置读取失败：" .. tostring(loadErr or "未知错误") end
    local root, rootErr = D:PageRoot(parent, "v3_page_raid_readiness")
    if root == nil then return nil, "页面根组件创建失败：" .. tostring(rootErr or "未知错误") end

    D:PageHeader(root, "v3_raid_readiness_header", "团队战备检查",
        "按需检查当前团队的装分、职责与关键增益。只在你主动运行检查时读取增益，不依赖 DPS，也不会常驻扫描团队 Buff。")

    local summaryCard = D:InfoCard(root, {
        id = "v3_raid_readiness_summary", title = "检查状态", value = "尚未检查",
        detail = "打开页面只维护轻量团队名单；点击“运行检查”后才分片读取成员信息。",
        slot = { size = "auto", minHeight = 78, hAlign = "fill" },
    })

    local settingsPanel = RSUI:Border({ id = "v3_raid_readiness_settings_panel", parent = root, padding = 6, variant = "card",
        slot = { size = "auto", minHeight = 122, hAlign = "fill" } })
    local settingsStack = RSUI:VerticalBox({ id = "v3_raid_readiness_settings_stack", parent = settingsPanel, gap = 5 })
    local settingsTop = RSUI:HorizontalBox({ id = "v3_raid_readiness_settings_top", parent = settingsStack, gap = 8,
        slot = { size = "auto", minHeight = 58, hAlign = "fill" } })

    local gearField = D:NumericSetting(settingsTop, {
        id = "v3_raid_readiness_min_gear", label = "最低装分", hint = "0 = 不作为通过条件；读取失败会标记为“待确认”，不会伪造失败。",
        min = 0, max = 50000, step = 100, integer = true, unit = "", slider = true, stepButtons = false,
        get = function() return Settings().minGearScore end,
        set = function(v) return Feature.Commands:ApplySettingFromBinding("minGearScore", v) end,
        storeId = STORE_ID, persistDelayMs = 300, persistReason = "raid_readiness_min_gear",
        slot = { size = "fill", fill = 1, hAlign = "fill" },
    })

    local toggles = RSUI:VerticalBox({ id = "v3_raid_readiness_toggles", parent = settingsTop, gap = 4,
        slot = { size = "fixed", width = 220 } })
    local hiddenToggle = RSUI:Toggle({
        id = "v3_raid_readiness_hidden", parent = toggles, onText = "关键增益：含隐藏 Buff", offText = "关键增益：仅普通 Buff",
        get = function() return Settings().includeHidden == true end,
        set = function(v) return Feature.Commands:ApplySettingFromBinding("includeHidden", v == true) end,
        storeId = STORE_ID, persistDelayMs = 300, persistReason = "raid_readiness_hidden",
        slot = { size = "fixed", height = 26, hAlign = "fill" },
    })
    local issuesToggle = RSUI:Toggle({
        id = "v3_raid_readiness_issues", parent = toggles, onText = "列表：只看问题", offText = "列表：显示全部",
        get = function() return Settings().showOnlyIssues == true end,
        set = function(v) return Feature.Commands:ApplySettingFromBinding("showOnlyIssues", v == true) end,
        storeId = STORE_ID, persistDelayMs = 300, persistReason = "raid_readiness_filter",
        slot = { size = "fixed", height = 26, hAlign = "fill" },
    })

    local auraRow = RSUI:HorizontalBox({ id = "v3_raid_readiness_aura_row", parent = settingsStack, gap = 6,
        slot = { size = "fixed", height = 29, hAlign = "fill" } })
    RSUI:Text({ id = "v3_raid_readiness_aura_label", parent = auraRow, text = "关键 Buff ID", fontSize = 9, tone = "strong",
        slot = { size = "fixed", width = 90 } })
    local auraInput, auraInputErr = RSUI:TextInput({
        id = "v3_raid_readiness_aura_input", parent = auraRow, value = Feature:GetRequiredAuraText(), maxLength = 220, buildOptional = true,
        allowEmpty = true, submitOnLostFocus = true,
        get = function() return Feature:GetRequiredAuraText() end,
        set = function(v) return Feature.Commands:ApplySettingFromBinding("requiredAuraIds", v) end,
        storeId = STORE_ID, persistDelayMs = 300, persistReason = "raid_readiness_required_auras",
        onSubmit = function() return true end,
        slot = { size = "fill", fill = 1, hAlign = "fill" },
    })
    if auraInput == nil then
        auraInput = RSUI:Text({ id = "v3_raid_readiness_aura_input_unavailable", parent = auraRow,
            text = "当前客户端文本输入框不可用；装分检查仍可使用。", fontSize = 9, tone = "warn", overflow = "ellipsis",
            slot = { size = "fill", fill = 1, hAlign = "fill" } })
        if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.WarningRateLimited) == "function" then
            S.DiagnosticsManager:WarningRateLimited("raid_readiness_v3", "RAID_READINESS_TEXT_INPUT_UNAVAILABLE", 5000,
                "团队战备关键 Buff 输入框不可用；页面已降级继续打开", { error = tostring(auraInputErr or "native editbox unavailable") })
        end
    end
    RSUI:Text({ id = "v3_raid_readiness_aura_hint", parent = auraRow,
        text = "留空 = 不判定增益；支持逗号/空格分隔，最多 " .. tostring(Settings().maxRequiredAuras or 24) .. " 个。项目不会内置猜测 ID。",
        fontSize = 8, tone = "muted", overflow = "ellipsis", slot = { size = "fixed", width = 330 } })

    local actions = RSUI:HorizontalBox({ id = "v3_raid_readiness_actions", parent = root, gap = 6,
        slot = { size = "fixed", height = 31, hAlign = "fill" } })
    local featureButton = RSUI:Button({ id = "v3_raid_readiness_feature_toggle", parent = actions, text = "启用功能", compact = true,
        slot = { size = "fixed", width = 96 } })
    local scanButton = RSUI:Button({ id = "v3_raid_readiness_scan", parent = actions, text = "运行检查", compact = true,
        slot = { size = "fixed", width = 96 } })
    local rosterButton = RSUI:Button({ id = "v3_raid_readiness_roster", parent = actions, text = "刷新名单", compact = true,
        slot = { size = "fixed", width = 96 } })
    local cancelButton = RSUI:Button({ id = "v3_raid_readiness_cancel", parent = actions, text = "取消检查", compact = true,
        slot = { size = "fixed", width = 96 } })
    local actionHint = RSUI:Text({ id = "v3_raid_readiness_action_hint", parent = actions,
        text = "检查是一次性的：完成或离开页面后自动释放 Aura Consumer。", fontSize = 8, tone = "muted", overflow = "ellipsis",
        slot = { size = "fill", fill = 1 } })

    local selectedKey = nil
    local tableView = RSUI:TableView({
        id = "v3_raid_readiness_table", parent = root, items = {}, rowHeight = 25, headerHeight = 27, desiredRows = 12,
        scrollbar = true, selectable = true, selectionMode = "single", columnResize = true, headerInteractive = false,
        getKey = function(item) return item and item.key or nil end,
        onSelectionChanged = function(_, _, view)
            selectedKey = view and type(view.GetSelectedKey) == "function" and view:GetSelectedKey() or nil
            if type(root.RefreshSelection) == "function" then root:RefreshSelection() end
        end,
        columns = Columns(),
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })

    local detail = RSUI:Text({ id = "v3_raid_readiness_detail", parent = root,
        text = "成员详情：点击列表中的成员。", fontSize = 9, tone = "muted", overflow = "wrap",
        slot = { size = "auto", minHeight = 34, hAlign = "fill" } })

    function root:RefreshSelection()
        local row = selectedKey and Feature:GetRow(selectedKey) or nil
        if row == nil then detail:SetText("成员详情：点击列表中的成员。"); return true end
        local missing = type(row.missingAuraIds) == "table" and #row.missingAuraIds > 0 and table.concat(row.missingAuraIds, ",") or "无"
        detail:SetText(tostring(row.name) .. " · " .. tostring(row.roleText) .. " · 装分 " .. tostring(row.gearText)
            .. " · 距离 " .. tostring(row.distanceText) .. " · 缺失关键增益 " .. tostring(missing)
            .. "\n" .. tostring(row.detailText or ""))
        return true
    end

    function root:Refresh()
        local enabled = S.FeatureRuntime ~= nil and S.FeatureRuntime:IsEnabled("combat_raid_readiness") == true
        local settings = Settings()
        local rows, revision = Feature:GetRows(settings.showOnlyIssues == true)
        tableView:SetItems(rows, revision)
        local summary = Feature:GetSummary()
        local roster = S.Services and S.Services.TeamRosterV3 or nil
        local rosterHealth = type(roster) == "table" and type(roster.GetHealth) == "function" and roster:GetHealth() or nil
        local rosterCount = type(rosterHealth) == "table" and tonumber(rosterHealth.members) or 0

        if enabled ~= true then
            tableView:SetViewState("unavailable", { title = "团队战备检查已关闭", detail = "启用后仍不会常驻扫描 Buff；只有主动运行检查才读取增益。" })
        elseif summary.scanning == true then
            tableView:SetViewState(#rows > 0 and "ready" or "loading", { title = "正在分片检查", detail = tostring(summary.completed or 0) .. "/" .. tostring(summary.scanTotal or 0) })
        elseif summary.total <= 0 then
            tableView:SetViewState("empty", { title = "尚未运行检查", detail = "当前团队名单 " .. tostring(rosterCount) .. " 人。配置需要的规则后点击“运行检查”。" })
        elseif #rows == 0 and settings.showOnlyIssues == true then
            tableView:SetViewState("empty", { title = "没有问题成员", detail = "当前结果中没有“未通过”或“待确认”的成员。" })
        else
            tableView:SetViewState("ready")
        end

        local value
        if enabled ~= true then value = "功能已关闭"
        elseif summary.scanning == true then value = "检查中 " .. tostring(summary.completed or 0) .. "/" .. tostring(summary.scanTotal or 0)
        elseif summary.total > 0 then value = "通过 " .. tostring(summary.ready or 0) .. " · 未通过 " .. tostring(summary.failed or 0)
        else value = "等待检查" end
        summaryCard:SetData({
            value = value,
            detail = "团队名单 " .. tostring(rosterCount) .. " 人 · 待确认 " .. tostring(summary.unknown or 0)
                .. " · 信息 " .. tostring(summary.info or 0) .. " · 结果版本 " .. tostring(summary.revision or 0)
                .. "\n最低装分 " .. tostring(settings.minGearScore or 0) .. " · 关键 Buff " .. tostring(#(settings.requiredAuraIds or {}))
                .. " 个 · 隐藏 Buff " .. (settings.includeHidden == true and "参与检查" or "不检查"),
        })
        featureButton:SetText(enabled and "关闭功能" or "启用功能")
        scanButton:SetEnabled(enabled and summary.scanning ~= true)
        rosterButton:SetEnabled(enabled)
        cancelButton:SetEnabled(summary.scanning == true)
        self:RefreshSelection()
        return true
    end

    featureButton.onClick = function()
        return RunAction("feature_toggle", featureButton, function()
            if S.FeatureRuntime == nil then return false, "FeatureRuntime 不可用" end
            local enabled = S.FeatureRuntime:IsEnabled("combat_raid_readiness") == true
            local target = not enabled
            local ok, err = S.FeatureRuntime:SetPreferredEnabled("combat_raid_readiness", target, "raid_readiness_page")
            if ok ~= true then return false, err end
            if target then
                local acquired, acquireErr = Feature:AcquireConsumer("page:raid_readiness")
                if acquired ~= true then
                    S.FeatureRuntime:SetPreferredEnabled("combat_raid_readiness", false, "raid_readiness_consumer_rollback")
                    return false, acquireErr
                end
            end
            root:Refresh()
            return true, target and "团队战备检查已启用" or "团队战备检查已关闭"
        end)
    end
    scanButton.onClick = function()
        return RunAction("scan", scanButton, function()
            local ok, err = Feature.Commands:RunScan("page_manual")
            if ok == true then root:Refresh() end
            return ok, err or "已开始分片检查"
        end, "启动检查…")
    end
    rosterButton.onClick = function()
        return RunAction("roster_refresh", rosterButton, function()
            local roster = S.Services and S.Services.TeamRosterV3 or nil
            if type(roster) ~= "table" or type(roster.ScheduleRefresh) ~= "function" then return false, "团队名单服务不可用" end
            local ok, err = roster:ScheduleRefresh(80, "raid_readiness_manual")
            return ok ~= false, err or "已请求刷新团队名单"
        end)
    end
    cancelButton.onClick = function()
        return RunAction("cancel", cancelButton, function()
            local ok = Feature.Commands:CancelScan("page_cancel")
            root:Refresh()
            return ok, "检查已取消"
        end)
    end
    for _, pair in ipairs({ { featureButton, "feature" }, { scanButton, "scan" }, { rosterButton, "roster" }, { cancelButton, "cancel" } }) do
        local button, key = pair[1], pair[2]
        if button.root ~= nil then
            local buttonRef, keyRef = button, key
            S.UI:SafeHandler(button.root, "OnClick", function() return buttonRef.onClick() end, "v3_raid_readiness:" .. keyRef)
        end
    end

    function root:Subscribe()
        if S.Events == nil or type(S.Events.SubscribeInternal) ~= "function" or type(S.Events.UnsubscribeInternalOwner) ~= "function" then
            return false, "内部事件总线不可用"
        end
        S.Events:UnsubscribeInternalOwner(self)
        local topics = { "v3.raid_readiness.updated", "v3.team_roster.updated", "v3.raid_readiness.settings" }
        for _, topic in ipairs(topics) do
            local topicRef = topic -- Lua 5.1: never capture the generic-for variable directly.
            local ok = S.Events:SubscribeInternal(topicRef, self, function() root:Refresh() end)
            if ok ~= true then
                S.Events:UnsubscribeInternalOwner(self)
                return false, "页面事件订阅失败：" .. tostring(topicRef)
            end
        end
        return true
    end

    function root:OnActivated()
        local loaded, loadErr = Feature:EnsureStoreLoaded()
        if loaded ~= true then return false, loadErr end
        local subscribed, subscribeErr = self:Subscribe()
        if subscribed ~= true then return false, subscribeErr end
        local enabled = S.FeatureRuntime ~= nil and S.FeatureRuntime:IsEnabled("combat_raid_readiness") == true
        if enabled then
            local ok, err = Feature:AcquireConsumer("page:raid_readiness")
            if ok ~= true then
                S.Events:UnsubscribeInternalOwner(self)
                return false, err
            end
        end
        self:Refresh()
        return true
    end

    function root:OnDeactivated()
        if S.Events ~= nil and type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
        Feature.Commands:CancelScan("page_deactivated")
        Feature:ReleaseConsumer("page:raid_readiness")
        return true
    end

    root.route = route
    root.tableView = tableView
    return root
end

local ok, err = PageHost:RegisterFactory(ROUTE, BuildPage)
if ok ~= true then error(err) end

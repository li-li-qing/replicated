------------------------------------------------------------------------
-- Replicated Suite - Settings
-- Author: Replicated
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.SettingsPage = {}

local function NextOption(list, current)
    local index = 1
    for i, value in ipairs(list or {}) do if tonumber(value) == tonumber(current) then index = i; break end end
    index = index + 1; if index > #(list or {}) then index = 1 end
    return list[index]
end

local WIDGET_OPACITY = { 1.00, 0.85, 0.70, 0.55 }
local EVENT_WIDGET_OPACITY = { 1.00, 0.85, 0.70, 0.55, 0.00 }
local function CycleWidgetOpacity(name)
    local placement = S.State.ui.widgets and S.State.ui.widgets[name]
    if type(placement) ~= "table" then return end
    local options = name == "event" and EVENT_WIDGET_OPACITY or WIDGET_OPACITY
    placement.opacity = NextOption(options, placement.opacity or S.State.settings.opacity or 0.90)
    local widget = S.UI.widgets and S.UI.widgets[name]
    if widget and widget.ApplyLayout then widget:ApplyLayout(false) end
    S.Storage:RequestSave()
end

local function WidgetOpacityText(name, label)
    local placement = S.State.ui.widgets and S.State.ui.widgets[name] or {}
    local opacity = tonumber(placement.opacity) or tonumber(S.State.settings.opacity) or 0.90
    return label .. "背景：" .. tostring(math.floor(opacity * 100 + 0.5)) .. "%"
end

function S.SettingsPage.Create(parent)
    local page = { root = S.UI:CreatePanel(parent, "settings_page", 0, 0, 100, 100, "soft"), scaleButtons = {} }
    if page.root.rsBorder and page.root.rsBorder.SetVisible then page.root.rsBorder:SetVisible(false) end
    if page.root.rsBackground and page.root.rsBackground.SetVisible then page.root.rsBackground:SetVisible(false) end

    page.title = S.UI:CreateLabel(page.root, "settings_title", "Replicated Suite 设置", 12, 12, 360, 28, 16, nil, ALIGN_LEFT)
    page.scaleLabel = S.UI:CreateLabel(page.root, "settings_scale_label", "整体 UI 缩放", 12, 52, 120, 24, 11, nil, ALIGN_LEFT)
    page.scaleValue = S.UI:CreateLabel(page.root, "settings_scale_value", "100%", 140, 52, 70, 24, 11, "blue", ALIGN_RIGHT)

    for i, scale in ipairs(S.Constants.ScaleOptions) do
        local b = S.UI:CreateButton(page.root, "settings_scale_" .. i, tostring(math.floor(scale * 100 + 0.5)) .. "%", 12 + (i - 1) * 66, 82, 60, 27, 9, false)
        page.scaleButtons[i] = { button = b, scale = scale }
        S.UI:SafeHandler(b, "OnClick", function()
            S.State.settings.addonScale = scale
            S.Layout:Invalidate(); S.Layout:GetContext(true); S.UI:ApplyResponsiveLayout(true); page:Refresh(); S.Storage:RequestSave()
        end, "settings:scale:" .. i)
    end

    page.fontSize = S.UI:CreateButton(page.root, "settings_font_size", "字体大小：120%", 12, 126, 170, 28, 9, false)
    page.opacity = S.UI:CreateButton(page.root, "settings_opacity", "整窗透明：90%", 190, 126, 170, 28, 9, false)
    page.contentOpacity = S.UI:CreateButton(page.root, "settings_content_opacity", "内容背景：100%", 368, 126, 150, 28, 9, false)
    page.startPage = S.UI:CreateButton(page.root, "settings_start_page", "启动页：首页", 526, 126, 150, 28, 9, false)
    S.UI:SafeHandler(page.fontSize, "OnClick", function()
        S.State.settings.fontScale = NextOption(S.Constants.FontScaleOptions, S.State.settings.fontScale)
        S.Theme:RefreshTypography(); S.UI:ApplyResponsiveLayout(false); page:Refresh(); S.Storage:RequestSave()
    end, "settings:font_size")
    S.UI:SafeHandler(page.opacity, "OnClick", function()
        S.State.settings.opacity = NextOption({1.00,0.90,0.80,0.70,0.60,0.50,0.40,0.35}, tonumber(S.State.settings.opacity) or 0.90)
        S.UI:ApplyResponsiveLayout(false); page:Refresh(); S.Storage:RequestSave()
    end, "settings:opacity")
    S.UI:SafeHandler(page.contentOpacity, "OnClick", function()
        S.State.settings.contentOpacity = NextOption({1.00,0.85,0.70,0.55,0.40,0.25,0.10,0.00}, tonumber(S.State.settings.contentOpacity) or 1.00)
        S.UI:ApplyResponsiveLayout(false); page:Refresh(); S.Storage:RequestSave()
    end, "settings:content_opacity")
    S.UI:SafeHandler(page.startPage, "OnClick", function()
        local options={"life","team","dps","healer","gear","plates","bagorganizer","modules","hud","quick","settings","diagnostics","last"}
        local current=tostring(S.State.settings.defaultStartPage or "life")
        if current=="target" then current="plates"; S.State.settings.defaultStartPage="plates" end
        local idx=1
        for i,v in ipairs(options) do if v==current then idx=i break end end
        idx=idx+1; if idx>#options then idx=1 end
        S.State.settings.defaultStartPage=options[idx]; page:Refresh(); S.Storage:RequestSave()
    end, "settings:start_page")

    page.dataRefresh = S.UI:CreateButton(page.root, "settings_data_refresh", "数据刷新：15秒", 12, 168, 170, 28, 9, false)
    page.refreshNow = S.UI:CreateButton(page.root, "settings_refresh_now", "立即刷新全部数据", 190, 168, 170, 28, 9, false)
    S.UI:SafeHandler(page.dataRefresh, "OnClick", function()
        S.State.settings.dataRefreshMs = NextOption(S.Constants.DataRefreshOptionsMs, S.State.settings.dataRefreshMs)
        if S.Runtime and S.Runtime.ApplyRefreshSettings then S.Runtime:ApplyRefreshSettings() end
        page:Refresh(); S.Storage:RequestSave()
    end, "settings:data_refresh")
    S.UI:SafeHandler(page.refreshNow, "OnClick", function()
        if S.Runtime and S.Runtime.RefreshAll then S.Runtime:RefreshAll(true, true) end
    end, "settings:refresh_now")

    page.tradeAuto = S.UI:CreateButton(page.root, "settings_trade_auto", "货率自动刷新：关", 12, 210, 170, 28, 9, false)
    page.tradeInterval = S.UI:CreateButton(page.root, "settings_trade_interval", "货率刷新：120秒", 190, 210, 170, 28, 9, false)
    S.UI:SafeHandler(page.tradeAuto, "OnClick", function()
        S.State.settings.tradeAutoRefresh = not S.State.settings.tradeAutoRefresh; page:Refresh(); S.Storage:RequestSave()
    end, "settings:trade_auto")
    S.UI:SafeHandler(page.tradeInterval, "OnClick", function()
        S.State.settings.tradeAutoRefreshMs = NextOption(S.Constants.TradeRefreshOptionsMs, S.State.settings.tradeAutoRefreshMs)
        if S.Runtime and S.Runtime.ApplyRefreshSettings then S.Runtime:ApplyRefreshSettings() end
        page:Refresh(); S.Storage:RequestSave()
    end, "settings:trade_interval")

    page.eventRows = S.UI:CreateButton(page.root, "settings_event_rows", "活动显示：20", 12, 252, 150, 28, 9, false)
    page.eventReminder = S.UI:CreateButton(page.root, "settings_event_reminder", "活动提醒：关", 168, 252, 150, 28, 9, false)
    page.tradeSort = S.UI:CreateButton(page.root, "settings_trade_sort", "跑商排序：货率", 324, 252, 150, 28, 9, false)
    S.UI:SafeHandler(page.eventRows, "OnClick", function()
        local values = { 8, 12, 16, 20 }
        S.State.settings.eventMaxRows = NextOption(values, S.State.settings.eventMaxRows)
        page:Refresh(); S.State:MarkDirty("events"); S.Storage:RequestSave()
    end, "settings:event_rows")
    S.UI:SafeHandler(page.eventReminder, "OnClick", function()
        local mode=tostring(S.State.settings.eventReminderMode or "off")
        if mode=="off" then mode="5" elseif mode=="5" then mode="15_5" else mode="off" end
        S.State.settings.eventReminderMode=mode
        if S.Services and S.Services.Event and mode=="off" then
            S.Services.Event.reminderBootstrapped=false
        end
        page:Refresh(); S.Storage:RequestSave()
    end, "settings:event_reminder")
    S.UI:SafeHandler(page.tradeSort, "OnClick", function()
        S.State.settings.tradeSortMode = S.State.settings.tradeSortMode == "ratio" and "price" or "ratio"
        page:Refresh()
        if S.Services and S.Services.Trade and S.State.data.trade.status == "ready" then S.Services.Trade:Request(true) end
        S.Storage:RequestSave()
    end, "settings:trade_sort")
    -- Reuse right-click on the existing controls instead of adding another
    -- settings row: the settings page must still fit the 600px main-window
    -- minimum at 120% UI scale.
    S.UI:SafeHandler(page.eventRows, "OnRButtonUp", function()
        local service = S.Services and S.Services.Event
        if service and type(service.RestoreHiddenEvents) == "function" and service:GetHiddenCount() > 0 then
            service:RestoreHiddenEvents(); page:Refresh()
        end
    end, "settings:event_rows_restore_hidden")
    S.UI:SafeHandler(page.tradeSort, "OnRButtonUp", function()
        local service = S.Services and S.Services.Trade
        if service and type(service.GetFavorites) == "function" and #service:GetFavorites() > 0 then
            service:StoreFavorites({}); page:Refresh()
        end
    end, "settings:trade_sort_clear_favorites")

    page.taskCompleted = S.UI:CreateButton(page.root, "settings_task_completed", "已完成任务：显示", 12, 294, 150, 28, 9, false)
    page.taskIncomplete = S.UI:CreateButton(page.root, "settings_task_incomplete", "任务过滤：全部", 168, 294, 150, 28, 9, false)
    page.dailyCustom = S.UI:CreateButton(page.root, "settings_daily_custom", "自定义日常", 324, 294, 150, 28, 9, false)
    S.UI:SafeHandler(page.taskCompleted, "OnClick", function()
        S.State.settings.showCompletedTasks = not S.State.settings.showCompletedTasks; page:Refresh(); S.State:MarkDirty("quests"); S.Storage:RequestSave()
    end, "settings:task_completed")
    S.UI:SafeHandler(page.taskIncomplete, "OnClick", function()
        S.State.settings.onlyIncompleteTasks = not S.State.settings.onlyIncompleteTasks; page:Refresh(); S.State:MarkDirty("quests"); S.Storage:RequestSave()
    end, "settings:task_filter")
    S.UI:SafeHandler(page.dailyCustom, "OnClick", function()
        if S.DailyCustomWindow and type(S.DailyCustomWindow.Open)=="function" then S.DailyCustomWindow:Open() end
    end, "settings:daily_custom")

    page.entryLock = S.UI:CreateButton(page.root, "settings_entry_lock", "主入口：可拖动", 12, 336, 170, 28, 9, false)
    page.mainLock = S.UI:CreateButton(page.root, "settings_main_lock", "主面板：可拖动", 190, 336, 170, 28, 9, false)
    page.hudEdit = S.UI:CreateButton(page.root, "settings_hud_edit", "HUD编辑：关", 368, 336, 150, 28, 9, false)
    S.UI:SafeHandler(page.entryLock, "OnClick", function()
        S.State.settings.entryLocked = not S.State.settings.entryLocked; page:Refresh(); S.Storage:RequestSave()
    end, "settings:entry_lock")
    S.UI:SafeHandler(page.mainLock, "OnClick", function()
        S.State.settings.mainLocked = not S.State.settings.mainLocked; page:Refresh(); if S.MainWindow then S.MainWindow:RefreshChrome() end; S.Storage:RequestSave()
    end, "settings:main_lock")
    S.UI:SafeHandler(page.hudEdit, "OnClick", function()
        if S.HudManager ~= nil then S.HudManager:SetEditMode(not S.HudManager:IsEditMode()) end
        page:Refresh()
    end, "settings:hud_edit")

    page.taskOpacity = S.UI:CreateButton(page.root, "settings_task_opacity", "任务窗背景：90%", 12, 378, 170, 28, 9, false)
    page.tradeOpacity = S.UI:CreateButton(page.root, "settings_trade_opacity", "跑商窗背景：90%", 190, 378, 170, 28, 9, false)
    page.bondOpacity = S.UI:CreateButton(page.root, "settings_bond_opacity", "债券窗背景：90%", 12, 420, 170, 28, 9, false)
    page.eventOpacity = S.UI:CreateButton(page.root, "settings_event_opacity", "活动窗背景：90%", 190, 420, 170, 28, 9, false)
    page.treasureOpacity = S.UI:CreateButton(page.root, "settings_treasure_opacity", "寻宝窗背景：90%", 12, 462, 170, 28, 9, false)
    page.fishingOpacity = S.UI:CreateButton(page.root, "settings_fishing_opacity", "钓鱼窗背景：90%", 190, 462, 170, 28, 9, false)
    S.UI:SafeHandler(page.taskOpacity, "OnClick", function() CycleWidgetOpacity("task"); page:Refresh() end, "settings:task_opacity")
    S.UI:SafeHandler(page.tradeOpacity, "OnClick", function() CycleWidgetOpacity("trade"); page:Refresh() end, "settings:trade_opacity")
    S.UI:SafeHandler(page.bondOpacity, "OnClick", function() CycleWidgetOpacity("bond"); page:Refresh() end, "settings:bond_opacity")
    S.UI:SafeHandler(page.eventOpacity, "OnClick", function() CycleWidgetOpacity("event"); page:Refresh() end, "settings:event_opacity")
    S.UI:SafeHandler(page.treasureOpacity, "OnClick", function() CycleWidgetOpacity("treasure"); page:Refresh() end, "settings:treasure_opacity")
    S.UI:SafeHandler(page.fishingOpacity, "OnClick", function() CycleWidgetOpacity("fishing"); page:Refresh() end, "settings:fishing_opacity")

    -- Keep creation-time anchors unique too. ApplyLayout will replace these
    -- positions, but duplicate initial anchors made the last action row overlap
    -- the treasure/fishing row if a client painted the page before first reflow.
    page.reloadAll = S.UI:CreateButton(page.root, "settings_reload_all", "刷新数据 / UI", 12, 504, 170, 28, 9, false)
    page.reloadCode = S.UI:CreateButton(page.root, "settings_reload_code", "重载插件代码", 190, 504, 170, 28, 9, false)
    page.restore = S.UI:CreateButton(page.root, "settings_restore", "恢复默认布局 / 大小", 368, 504, 150, 28, 9, false)
    page.factoryReset = S.UI:CreateButton(page.root, "settings_factory_reset", "恢复全部默认设置", 526, 504, 150, 28, 9, false)
    page.note = S.UI:CreateLabel(page.root, "settings_note", "“恢复默认布局”只改位置/大小；“恢复全部默认设置”会清空 Suite 与专业模块全部保存数据并重新载入。", 12, 544, 620, 24, 9, "muted", ALIGN_LEFT)
    S.UI:SafeHandler(page.reloadAll, "OnClick", function()
        if type(S.SafeSuiteRefresh) == "function" then
            S.SafeSuiteRefresh("settings")
        elseif type(S.ForceUiReload) == "function" then
            S.ForceUiReload("settings")
        else
            S.SafeChat("刷新失败：Suite 内部刷新函数不可用。")
        end
    end, "settings:reload_all")
    S.UI:SafeHandler(page.reloadCode, "OnClick", function()
        if type(S.ReloadCodeFromDisk) == "function" then
            S.ReloadCodeFromDisk("settings")
        else
            S.SafeChat("重载失败：代码重载入口不可用。")
        end
    end, "settings:reload_code")
    S.UI:SafeHandler(page.restore, "OnClick", function()
        local now=S.NowMs and S.NowMs() or 0
        if now-(tonumber(page.restoreArmedAt) or 0)>5000 then
            page.restoreArmedAt=now
            page.restore:SetText("再次点击确认恢复")
            if S.Scheduler and type(S.Scheduler.AddTask)=="function" then
                S.Scheduler:RemoveTask("settings_restore_confirm_expire")
                S.Scheduler:AddTask("settings_restore_confirm_expire",5100,function()
                    S.Scheduler:RemoveTask("settings_restore_confirm_expire")
                    if (S.NowMs and S.NowMs() or 0)-(tonumber(page.restoreArmedAt) or 0)>=5000 then
                        page.restoreArmedAt=0
                        if page.restore and page.restore.SetText then page.restore:SetText("恢复默认布局 / 大小") end
                    end
                end,false,page,"P5")
            end
            S.SafeChat("恢复默认布局会重置主窗口和全部 HUD 的位置/大小；5秒内再次点击确认。")
            return
        end
        page.restoreArmedAt=0
        S.State.ui.entry.anchorH, S.State.ui.entry.anchorV, S.State.ui.entry.offsetX, S.State.ui.entry.offsetY = "LEFT", "TOP", 16, 170
        S.State.ui.main.anchorH, S.State.ui.main.anchorV, S.State.ui.main.offsetX, S.State.ui.main.offsetY = "LEFT", "TOP", 95, 105
        S.State.ui.main.width, S.State.ui.main.height, S.State.ui.main.collapsed = nil, nil, false
        local d = { task = { 16, 80 }, trade = { 16, 120 }, bond = { 16, 160 }, event = { 16, 200 }, treasure = { 16, 240 }, fishing = { 16, 280 } }
        for n, v in pairs(d) do
            local p = S.State.ui.widgets[n]
            p.anchorH, p.anchorV, p.offsetX, p.offsetY = "RIGHT", "TOP", v[1], v[2]
            p.width, p.height, p.opacity, p.userMoved = nil, nil, nil, false
        end
        -- Professional HUDs (DPS/BUFF/Gear) are owned by HudManager and were
        -- previously omitted from this global reset. Reset only position/size so
        -- visibility and semantic appearance preferences stay intact.
        if S.HudManager and type(S.HudManager.List)=="function" then
            for _,hud in ipairs(S.HudManager:List()) do
                if hud and hud.id then
                    if type(S.HudManager.ResetPosition)=="function" then S.HudManager:ResetPosition(hud.id) end
                    if hud.supportsResize~=false and type(S.HudManager.ResetSize)=="function" then S.HudManager:ResetSize(hud.id) end
                end
            end
        end
        S.UI:ApplyResponsiveLayout(true); S.Storage:RequestSave(0); page:Refresh()
    end, "settings:restore")

    S.UI:SafeHandler(page.factoryReset, "OnClick", function()
        local now=S.NowMs and S.NowMs() or 0
        if now-(tonumber(page.factoryResetArmedAt) or 0)>8000 then
            page.factoryResetArmedAt=now
            page.factoryReset:SetText("再次点击确认全部重置")
            if S.Scheduler and type(S.Scheduler.AddTask)=="function" then
                S.Scheduler:RemoveTask("settings_factory_reset_confirm_expire")
                S.Scheduler:AddTask("settings_factory_reset_confirm_expire",8100,function()
                    S.Scheduler:RemoveTask("settings_factory_reset_confirm_expire")
                    if (S.NowMs and S.NowMs() or 0)-(tonumber(page.factoryResetArmedAt) or 0)>=8000 then
                        page.factoryResetArmedAt=0
                        if page.factoryReset and page.factoryReset.SetText then page.factoryReset:SetText("恢复全部默认设置") end
                    end
                end,false,page,"P5")
            end
            S.SafeChat("警告：这会清空 Suite、HUD、换装方案、治疗设置、BUFF追踪/布局、DPS配置/规则/统计等全部保存数据。8秒内再次点击确认。")
            return
        end

        page.factoryResetArmedAt=0
        page.factoryReset:SetText("正在清空全部配置")
        local ok, summary = false, nil
        if S.Storage and type(S.Storage.ResetAllPersistedData)=="function" then
            ok, summary = S.Storage:ResetAllPersistedData()
        else
            summary = { error = "Storage 出厂重置入口不可用" }
        end
        if ok~=true then
            local detail=type(summary)=="table" and summary.error or summary
            S.SafeChat("恢复全部默认设置失败，未重新载入："..tostring(detail or "unknown"))
            page.factoryReset:SetText("恢复全部默认设置")
            return
        end

        local count=type(summary)=="table" and tonumber(summary.cleared) or nil
        S.SafeChat("已清空"..tostring(count or 0).."个保存槽，正在以首次安装状态重新载入。")
        if type(S.ReloadCodeFromDisk)=="function" then
            local reloadOk=S.ReloadCodeFromDisk("factory_reset")
            if reloadOk~=true then
                S.SafeChat("保存数据已清空，但自动重载失败；为避免旧内存状态重新写回，当前会话已保持写保护，请手动重新登录或使用“载”。")
                page.factoryReset:SetText("已清空，等待重载")
            end
        else
            S.SafeChat("保存数据已清空，但重载入口不可用；请重新登录后继续测试。")
            page.factoryReset:SetText("已清空，等待重载")
        end
    end, "settings:factory_reset")

    function page:Refresh()
        local now=S.NowMs and S.NowMs() or 0
        if now-(tonumber(self.restoreArmedAt) or 0)>5000 then self.restoreArmedAt=0 end
        if now-(tonumber(self.factoryResetArmedAt) or 0)>8000 then self.factoryResetArmedAt=0 end
        self.restore:SetText((tonumber(self.restoreArmedAt) or 0)>0 and "再次点击确认恢复" or "恢复默认布局 / 大小")
        local resetPending=S.Storage and S.Storage.factoryResetPending==true
        self.factoryReset:SetText(resetPending and "已清空，等待重载" or ((tonumber(self.factoryResetArmedAt) or 0)>0 and "再次点击确认全部重置" or "恢复全部默认设置"))
        if self.factoryReset.Enable then self.factoryReset:Enable(resetPending~=true) end
        self.scaleValue:SetText(tostring(math.floor((S.State.settings.addonScale or 1) * 100 + 0.5)) .. "%")
        self.fontSize:SetText("字体大小：" .. tostring(math.floor((S.State.settings.fontScale or 1.2) * 100 + 0.5)) .. "%")
        self.opacity:SetText("整窗透明：" .. tostring(math.floor((S.State.settings.opacity or 0.9) * 100 + 0.5)) .. "%")
        self.contentOpacity:SetText("内容背景：" .. tostring(math.floor((S.State.settings.contentOpacity or 1.0) * 100 + 0.5)) .. "%")
        local pageLabels={life="首页",team="团队辅助",activity="首页",dps="伤害统计",healer="治疗辅助",gear="一键换装",plates="BUFF显示",target="BUFF显示",bagorganizer="整理背包",modules="模块",hud="HUD",quick="快捷",settings="设置",diagnostics="诊断",last="上次页面"}
        self.startPage:SetText("启动页："..tostring(pageLabels[tostring(S.State.settings.defaultStartPage or "life")] or "首页"))
        self.dataRefresh:SetText("数据刷新：" .. tostring(math.floor((S.State.settings.dataRefreshMs or 15000) / 1000)) .. "秒")
        self.tradeAuto:SetText(S.State.settings.tradeAutoRefresh and "货率自动刷新：开" or "货率自动刷新：关")
        self.tradeInterval:SetText("货率刷新：" .. tostring(math.floor((S.State.settings.tradeAutoRefreshMs or 120000) / 1000)) .. "秒")
        local eventService = S.Services and S.Services.Event
        local tradeService = S.Services and S.Services.Trade
        local hiddenCount = eventService and type(eventService.GetHiddenCount) == "function" and eventService:GetHiddenCount() or 0
        local favoriteCount = tradeService and type(tradeService.GetFavorites) == "function" and #tradeService:GetFavorites() or 0
        self.eventRows:SetText("活动显示：" .. tostring(S.State.settings.eventMaxRows or 20) .. (hiddenCount > 0 and (" 隐" .. tostring(hiddenCount)) or ""))
        local reminderMode=tostring(S.State.settings.eventReminderMode or "off")
        self.eventReminder:SetText(reminderMode=="15_5" and "提醒：15/5/开始" or reminderMode=="5" and "提醒：5分/开始" or "活动提醒：关")
        self.tradeSort:SetText((S.State.settings.tradeSortMode == "price" and "跑商排序：售价" or "跑商排序：货率") .. (favoriteCount > 0 and (" 收藏" .. tostring(favoriteCount)) or ""))
        self.taskCompleted:SetText(S.State.settings.showCompletedTasks and "已完成任务：显示" or "已完成任务：隐藏")
        self.taskIncomplete:SetText(S.State.settings.onlyIncompleteTasks and "任务过滤：仅未完成" or "任务过滤：全部")
        local questService=S.Services and S.Services.Quest
        local selected,total=0,0
        if questService and type(questService.GetDailyTrackingStats)=="function" then selected,total=questService:GetDailyTrackingStats() end
        self.dailyCustom:SetText("自定义日常："..tostring(selected).."/"..tostring(total))
        self.entryLock:SetText(S.State.settings.entryLocked and "主入口：已锁定" or "主入口：可拖动")
        self.mainLock:SetText(S.State.settings.mainLocked and "主面板：已锁定" or "主面板：可拖动")
        self.hudEdit:SetText(S.HudManager ~= nil and S.HudManager:IsEditMode() and "HUD编辑：开" or "HUD编辑：关")
        self.taskOpacity:SetText(WidgetOpacityText("task", "任务窗"))
        self.tradeOpacity:SetText(WidgetOpacityText("trade", "跑商窗"))
        self.bondOpacity:SetText(WidgetOpacityText("bond", "债券窗"))
        self.eventOpacity:SetText(WidgetOpacityText("event", "活动窗"))
        self.treasureOpacity:SetText(WidgetOpacityText("treasure", "寻宝窗"))
        self.fishingOpacity:SetText(WidgetOpacityText("fishing", "钓鱼窗"))
    end

    function page:ApplyLayout(spec)
        S.UI:SetAnchor(self.root, parent, 0, 0)
        self.root:SetExtent(spec.contentWidth, spec.contentHeight)

        local scale = S.Layout:GetContext().addonScale
        local pad = 12 * scale
        local gap = 8 * scale
        local full = math.max(1, spec.contentWidth - pad * 2)

        self.title:SetExtent(full, 28 * scale)
        S.UI:SetAnchor(self.title, self.root, pad, 8 * scale)
        self.scaleLabel:SetExtent(120 * scale, 22 * scale)
        S.UI:SetAnchor(self.scaleLabel, self.root, pad, 42 * scale)
        self.scaleValue:SetExtent(70 * scale, 22 * scale)
        S.UI:SetAnchor(self.scaleValue, self.root, pad + 122 * scale, 42 * scale)

        local scaleY = 68 * scale
        local scaleGap = 6 * scale
        local scaleButtonW = math.max(44 * scale, (full - scaleGap * 4) / 5)
        local scaleButtonH = 26 * scale
        for i, item in ipairs(self.scaleButtons) do
            item.button:SetExtent(scaleButtonW, scaleButtonH)
            S.UI:SetAnchor(item.button, self.root, pad + (i - 1) * (scaleButtonW + scaleGap), scaleY)
        end

        -- All remaining settings are ten control rows plus one note.  Their
        -- vertical step is solved from the current viewport, so 600px main
        -- windows and enlarged UI scales cannot push the bottom controls out of
        -- bounds or stack them on top of one another.
        local rowsTop = scaleY + scaleButtonH + 10 * scale
        local noteH = 22 * scale
        local bottomPad = 8 * scale
        local rowCount = 10
        local available = math.max(rowCount * 25 * scale, spec.contentHeight - rowsTop - noteH - bottomPad - 4 * scale)
        local step = math.max(25 * scale, math.min(40 * scale, available / rowCount))
        local rowH = math.max(22 * scale, math.min(30 * scale, step - 5 * scale))

        local two = math.max(1, (full - gap) / 2)
        local three = math.max(1, (full - gap * 2) / 3)
        local function Pair(a, b, py)
            a:SetExtent(two, rowH); b:SetExtent(two, rowH)
            S.UI:SetAnchor(a, page.root, pad, py)
            S.UI:SetAnchor(b, page.root, pad + two + gap, py)
        end
        local function Triple(a, b, c, py)
            a:SetExtent(three, rowH); b:SetExtent(three, rowH); c:SetExtent(three, rowH)
            S.UI:SetAnchor(a, page.root, pad, py)
            S.UI:SetAnchor(b, page.root, pad + three + gap, py)
            S.UI:SetAnchor(c, page.root, pad + (three + gap) * 2, py)
        end
        local four = math.max(1, (full - gap * 3) / 4)
        local function Quad(a, b, c, d, py)
            local items={a,b,c,d}
            for i,item in ipairs(items) do
                item:SetExtent(four,rowH)
                S.UI:SetAnchor(item,page.root,pad+(i-1)*(four+gap),py)
            end
        end

        local y = rowsTop
        Quad(self.fontSize, self.opacity, self.contentOpacity, self.startPage, y); y = y + step
        Pair(self.dataRefresh, self.refreshNow, y); y = y + step
        Pair(self.tradeAuto, self.tradeInterval, y); y = y + step
        Triple(self.eventRows, self.eventReminder, self.tradeSort, y); y = y + step
        Triple(self.taskCompleted, self.taskIncomplete, self.dailyCustom, y); y = y + step
        Triple(self.entryLock, self.mainLock, self.hudEdit, y); y = y + step
        Pair(self.taskOpacity, self.tradeOpacity, y); y = y + step
        Pair(self.bondOpacity, self.eventOpacity, y); y = y + step
        Pair(self.treasureOpacity, self.fishingOpacity, y); y = y + step
        Quad(self.reloadAll, self.reloadCode, self.restore, self.factoryReset, y); y = y + step

        local noteY = math.min(y + 1 * scale, spec.contentHeight - noteH - bottomPad)
        self.note:SetExtent(full, noteH)
        S.UI:SetAnchor(self.note, self.root, pad, math.max(rowsTop, noteY))
        self:Refresh()
    end

    page:Refresh(); S.UI.pages.settings = page; return page
end

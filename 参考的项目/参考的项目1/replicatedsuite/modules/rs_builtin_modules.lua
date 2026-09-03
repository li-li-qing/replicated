------------------------------------------------------------------------
-- Replicated Suite - Built-in module registrations
-- Author: Replicated
--
-- Native Suite services run through ModuleManager. Professional modules are
-- registered separately by rs_professional_modules.lua and share this same
-- lifecycle Authority; no standalone addon bridge remains.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local M = S.ModuleManager
if M == nil then return end

local function RemoveTasks(names)
    if S.Scheduler == nil then return end
    for _, name in ipairs(names or {}) do S.Scheduler:RemoveTask(name) end
end

local function StopService(service, taskNames)
    local stopOk, stopErr = true, nil
    if service ~= nil and type(service.Stop) == "function" then
        stopOk, stopErr = xpcall(function() return service:Stop() end, S.SafeTraceback)
    end
    -- Cleanup is unconditional even when service:Stop() faults. ModuleManager
    -- must never report Disabled while Suite-owned event/scheduler work survives.
    if S.Events ~= nil and type(S.Events.UnsubscribeOwner) == "function" and service ~= nil then
        S.Events:UnsubscribeOwner(service)
    end
    if S.Scheduler ~= nil and type(S.Scheduler.RemoveOwner) == "function" and service ~= nil then
        S.Scheduler:RemoveOwner(service)
    end
    RemoveTasks(taskNames)
    if not stopOk then error(tostring(stopErr or "service Stop failed")) end
    if stopErr == false then error("service Stop returned false") end
    return true
end


local function ShowSuitePage(pageId)
    return S.UI ~= nil and type(S.UI.ShowPage) == "function" and S.UI:ShowPage(pageId) == true
end

local function OpenDailyTrackingSettings()
    if S.DailyCustomWindow ~= nil and type(S.DailyCustomWindow.Open) == "function" then
        S.DailyCustomWindow:Open()
        return true
    end
    return ShowSuitePage("life")
end

local function OpenBondSettings()
    local widget = S.UI and S.UI.widgets and S.UI.widgets.bond or nil
    if widget ~= nil and type(widget.OpenSettingsPanel) == "function" then
        widget:OpenSettingsPanel()
        return true
    end
    -- Do not silently succeed when the dedicated settings surface is missing.
    -- Opening 首页 at least exposes the resident-board card and its 设置 entry.
    return ShowSuitePage("life")
end


local function ServiceModule(def)
    local serviceGetter = def.Service
    local taskNames = def.Tasks or {}
    if S.Scheduler ~= nil and type(S.Scheduler.SetTaskModule) == "function" then
        for _, taskName in ipairs(taskNames) do S.Scheduler:SetTaskModule(taskName, def.Id) end
    end
    M:Register({
        Id = def.Id,
        Name = def.Name,
        Category = def.Category or "life",
        DefaultEnabled = def.DefaultEnabled ~= false,
        Internal = def.Internal == true,
        Professional = def.Professional == true,
        DataScope = def.DataScope or "account",
        HudIds = def.HudIds or {},
        OpenSettings = def.OpenSettings,
        SettingsLabel = def.SettingsLabel,
        Initialize = function(self)
            local service = serviceGetter()
            if service == nil then error("service unavailable") end
            self._service = service
            if S.Events ~= nil and type(S.Events.BindOwner) == "function" then S.Events:BindOwner(service, def.Id) end
            return true
        end,
        Enable = function(self)
            local service = self._service or serviceGetter()
            if service == nil then return false end
            if type(service.Start) == "function" then
                local result = service:Start()
                if result == false then error("service Start returned false") end
            end
            return true
        end,
        Disable = function(self)
            return StopService(self._service or serviceGetter(), taskNames)
        end,
        DescribeRuntime = function(self)
            local service = self._service or serviceGetter()
            return {
                serviceReady = service ~= nil,
                scheduledTasks = taskNames,
            }
        end,
    })
end

ServiceModule({
    Id="tasks", Name="任务 / 日常", HudIds={"task"}, DataScope="character", SettingsLabel="追踪",
    Service=function() return S.Services and S.Services.Quest end,
    OpenSettings=OpenDailyTrackingSettings,
    Tasks={"quest_safety", "quest_debounce"},
})

ServiceModule({
    Id="resources", Name="资源统计", DataScope="character",
    Service=function() return S.Services and S.Services.Resource end,
    OpenSettings=function() return ShowSuitePage("settings") end,
    Tasks={"resource_safety", "resource_debounce"},
})

ServiceModule({
    Id="character", Name="角色信息", Category="common", Internal=true, DataScope="character",
    Service=function() return S.Services and S.Services.Character end,
    Tasks={"character_safety", "character_debounce"},
})

ServiceModule({
    Id="trade", Name="跑商 / 材料价格", HudIds={"trade"}, DataScope="account",
    Service=function() return S.Services and S.Services.Trade end,
    OpenSettings=function() return ShowSuitePage("settings") end,
    -- CraftAssist is owned by the trade lifecycle and must retain that module
    -- attribution even though it uses its own scheduler task names.
    Tasks={"trade_timeout", "trade_auto", "craft_assist_visibility", "craft_assist_probe"},
})

ServiceModule({
    Id="auction", Name="拍卖查询队列", Category="internal", Internal=true,
    Service=function() return S.Services and S.Services.Auction end,
    Tasks={"auction_queue"},
})

ServiceModule({
    Id="bonds", Name="债券 / 居民板", HudIds={"bond"}, DataScope="account",
    Service=function() return S.Services and S.Services.Resident end,
    OpenSettings=OpenBondSettings,
    Tasks={"resident_safety", "resident_stage_safety"},
})

ServiceModule({
    Id="activities", Name="活动时间", HudIds={"event"}, DataScope="account",
    Service=function() return S.Services and S.Services.Event end,
    OpenSettings=function() return ShowSuitePage("settings") end,
    Tasks={"event_timer", "event_dynamic_zone_scan"},
})

ServiceModule({
    Id="treasure", Name="藏宝图", HudIds={"treasure"}, DataScope="account", SettingsLabel="控制",
    Service=function() return S.Services and S.Services.Treasure end,
    OpenSettings=function() return ShowSuitePage("quick") end,
    Tasks={"treasure_position", "treasure_map_refresh", "treasure_world_refresh"},
})

ServiceModule({
    Id="fishing", Name="钓鱼辅助", HudIds={"fishing"}, DataScope="account", SettingsLabel="控制",
    Service=function() return S.Services and S.Services.Fishing end,
    OpenSettings=function() return ShowSuitePage("quick") end,
    Tasks={"fishing_poll"},
})

ServiceModule({
    Id="bag_organizer", Name="整理背包", Category="utility", DataScope="account", SettingsLabel="设置",
    Service=function() return S.Services and S.Services.BagOrganizer end,
    OpenSettings=function() return ShowSuitePage("bagorganizer") end,
    Tasks={"bag_organizer_move_queue"},
})

ServiceModule({
    Id="auction_favorites", Name="拍卖行收藏夹", Category="utility", DataScope="account",
    Service=function() return S.Services and S.Services.AuctionFavorites end,
    Tasks={"auction_favorites_watch"},
})

ServiceModule({
    Id="team_utility", Name="团队辅助", Category="utility", DataScope="character",
    Service=function() return S.Services and S.Services.TeamUtility end,
    OpenSettings=function() return S.UI and type(S.UI.ShowPage)=="function" and S.UI:ShowPage("team") or false end,
    Tasks={
        "team_utility_role_debounce", "team_utility_role_verify", "team_utility_role_watch",
        "team_utility_world_scan", "team_utility_roster_settle", "team_utility_roster_scan",
        "team_utility_sac_scan", "team_utility_sac_position", "team_utility_damage_review",
    },
})

ServiceModule({
    Id="professional_status", Name="专业模块状态", Category="internal", Internal=true,
    Service=function() return S.Services and S.Services.Professional end,
    Tasks={"professional_status"},
})

------------------------------------------------------------------------
-- Replicated Suite - Runtime
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S=ReplicatedSuite
S.Runtime={started=false, firstOpenRefreshDone=false, lastOpenRefreshMs=-1}; local R=S.Runtime
if S.PerformanceMonitor ~= nil and type(S.PerformanceMonitor.MarkStartup) == "function" then S.PerformanceMonitor:MarkStartup("toc_loaded") end

function R:Stop()
    -- Stop is a best-effort quiescence fence, not merely a state transition.
    -- Always tear down native callbacks/tasks even when a previous partial Start
    -- never reached started=true; hot reload calls this before replacing Core.
    S.Ready = false
    self.started = false
    if S.TargetService and type(S.TargetService.Stop) == "function" then pcall(function() S.TargetService:Stop() end) end
    if S.ModuleManager then pcall(function() S.ModuleManager:Shutdown() end) end
    if S.Storage and S.Storage.dirty then pcall(function() S.Storage:SaveNow() end) end
    if S.Events then pcall(function() S.Events:Stop() end) end
    if S.Scheduler then pcall(function() S.Scheduler:Stop() end) end
    if S.UI then pcall(function() S.UI:HideAll() end) end
end

function R:InstallSchedulerTasks()
    S.Scheduler:AddTask("layout",S.Constants.Refresh.layoutMs,function() S.Layout:PollChanges() end,true,nil,"P4")
    S.Scheduler:AddTask("storage",S.Constants.Refresh.storageMs,function() S.Storage:Tick() end,false,nil,"P2")
    -- UnitNameWithWorld can be cold for a short period after login/reload.  A
    -- bounded low-frequency resolver applies an existing Character Override as
    -- soon as identity becomes authoritative, even when no user action happens
    -- to trigger a save. It removes itself permanently after success.
    if S.Storage ~= nil and S.Storage.characterKey == nil then
        S.Scheduler:AddTask("character_scope_resolve",1000,function()
            if S.Storage:TryResolveDeferredCharacterScope() == true then
                S.Scheduler:RemoveTask("character_scope_resolve")
            end
        end,false,S.Storage,"P2")
    end
    -- Cheap identity watchdog: one world-qualified name getter every 15s. It is
    -- only a fallback for clients that keep the same addon generation across a
    -- character switch without delivering a usable ENTERED_WORLD edge.
    S.Scheduler:AddTask("character_scope_watch",15000,function()
        if S.Storage ~= nil then S.Storage:RefreshCharacterScope("watch") end
    end,false,S.Storage,"P5")

    if S.Events ~= nil and S.Storage ~= nil then
        S.Events:Subscribe("ENTERED_WORLD", S.Storage, function()
            -- World APIs may still expose the previous/no player identity for a
            -- few frames. Keep a bounded 3s retry lane rather than trusting the
            -- first callback or running a permanent fast poll.
            local attempts = 0
            S.Scheduler:RemoveTask("character_scope_world_retry")
            S.Scheduler:AddTask("character_scope_world_retry",500,function()
                attempts = attempts + 1
                S.Storage:RefreshCharacterScope("entered_world")
                if attempts >= 6 then S.Scheduler:RemoveTask("character_scope_world_retry") end
            end,false,S.Storage,"P2")
        end)
    end
    S.Scheduler:AddTask("ui_flush",S.Constants.Refresh.uiFlushMs,function()
        if S.State:HasDirty() then S.UI:RefreshData(S.State:ConsumeDirty()) end
    end,false,nil,"P4")
    S.Scheduler:AddTask("observation_prune",5000,function()
        if S.Observation and type(S.Observation.Prune)=="function" then S.Observation:Prune(120000) end
    end,false,nil,"P5")
end


function R:OnCharacterScopeResolved()
    -- Storage owns persistence/scope materialization; Runtime owns side-effect
    -- reconciliation. A Character Override can arrive after services already
    -- started when UnitNameWithWorld was cold during bootstrap, or after an
    -- in-generation character switch. Re-apply only character-scoped behavior
    -- immediately; rebuild data projections after a short world-settle delay so
    -- State Authority and visible/cache projections cannot remain on different
    -- characters.
    local teamUtility = S.Services and S.Services.TeamUtility or nil
    if teamUtility ~= nil and type(teamUtility.ReconcileCharacterSettings) == "function" then
        local ok, err = xpcall(function()
            teamUtility:ReconcileCharacterSettings("character_scope_resolved")
        end, S.SafeTraceback)
        if not ok and S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Record) == "function" then
            S.DiagnosticsManager:Record("warning", "runtime", "character settings reconcile: " .. tostring(err))
        end
    end

    -- Do not perform bag/quest/map API work while Storage is committing the
    -- scope transition. The scheduler is the single timing Authority and this
    -- one-shot task also coalesces multiple ENTERED_WORLD retries.
    if S.Scheduler == nil or type(S.Scheduler.AddTask) ~= "function" then return end
    S.Scheduler:RemoveTask("character_scope_projection_refresh")
    S.Scheduler:AddTask("character_scope_projection_refresh", 500, function()
        S.Scheduler:RemoveTask("character_scope_projection_refresh")

        local function IsEnabled(moduleId)
            local mm = S.ModuleManager
            if mm == nil or type(mm.IsRegistered) ~= "function" or not mm:IsRegistered(moduleId) then return true end
            return mm:IsEnabled(moduleId)
        end
        local function RefreshService(moduleId, serviceName)
            if not IsEnabled(moduleId) then return end
            local service = S.Services and S.Services[serviceName] or nil
            if service == nil or type(service.Refresh) ~= "function" then return end
            local ok, err = xpcall(function() service:Refresh() end, S.SafeTraceback)
            if not ok and S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Record) == "function" then
                S.DiagnosticsManager:Record("warning", "runtime", "character projection " .. tostring(serviceName) .. ": " .. tostring(err))
            end
        end

        -- Resource owns a bag snapshot/cache. A scope change invalidates that
        -- cache even if the client did not emit BAG_UPDATE in the expected order.
        local resource = S.Services and S.Services.Resource or nil
        if resource ~= nil then
            resource.activeBagId = nil
            resource.bagSnapshot = nil
            resource.bagDirty = true
        end

        -- Quest projection materializes dailyTracking/eventDailyDone first; the
        -- Event projection consumes its eventQuestProgress, so preserve order.
        RefreshService("tasks", "Quest")
        RefreshService("resources", "Resource")
        RefreshService("activities", "Event")
        if S.State ~= nil and type(S.State.MarkDirty) == "function" then S.State:MarkDirty("all") end
    end, false, S.Storage, "P2")
end

function R:ApplyRefreshSettings()
    local dataMs = math.max(5000, math.min(60000, tonumber(S.State.settings.dataRefreshMs) or 15000))
    local tradeMs = math.max(30000, math.min(300000, tonumber(S.State.settings.tradeAutoRefreshMs) or 120000))
    if S.Scheduler and S.Scheduler.tasks then
        if S.Scheduler.tasks.quest_safety then S.Scheduler.tasks.quest_safety.intervalMs = dataMs end
        if S.Scheduler.tasks.resource_safety then S.Scheduler.tasks.resource_safety.intervalMs = dataMs end
        if S.Scheduler.tasks.character_safety then S.Scheduler.tasks.character_safety.intervalMs = dataMs end
        if S.Scheduler.tasks.resident_safety then S.Scheduler.tasks.resident_safety.intervalMs = math.max(dataMs, 15000) end
        if S.Scheduler.tasks.trade_auto then S.Scheduler.tasks.trade_auto.intervalMs = tradeMs end
    end
end

-- Refresh the authoritative data snapshot.  flushNow is reserved for explicit
-- user-visible transitions (first/open main window and manual refresh): those
-- paths must not wait for the 120 ms dirty flush before row text appears.
-- Periodic/background callers keep the normal batched UI path.
local function ModuleEnabled(id)
    if S.ModuleManager == nil or type(S.ModuleManager.IsRegistered) ~= "function" or not S.ModuleManager:IsRegistered(id) then return true end
    return S.ModuleManager:IsEnabled(id)
end

function R:RefreshAll(includeTrade, flushNow)
    local ordered = {
        { "tasks", S.Services and S.Services.Quest },
        { "resources", S.Services and S.Services.Resource },
        { "character", S.Services and S.Services.Character },
        { "bonds", S.Services and S.Services.Resident },
        { "activities", S.Services and S.Services.Event },
        { "professional_status", S.Services and S.Services.Professional },
    }
    for _, pair in ipairs(ordered) do
        local moduleId, service = pair[1], pair[2]
        if ModuleEnabled(moduleId) and service and type(service.Refresh) == "function" then
            local ok, err = xpcall(function() service:Refresh() end, S.SafeTraceback)
            if not ok then S.SafeChat("手动刷新失败：" .. tostring(err)) end
        end
    end
    if ModuleEnabled("bonds") and S.Services and S.Services.Resident and type(S.Services.Resident.RefreshStages)=="function" then pcall(function() S.Services.Resident:RefreshStages() end) end
    if ModuleEnabled("treasure") and S.Services and S.Services.Treasure and type(S.Services.Treasure.RefreshMaps)=="function" then pcall(function() S.Services.Treasure:RefreshMaps() end) end
    if includeTrade ~= false and ModuleEnabled("trade") and S.Services and S.Services.Trade and type(S.Services.Trade.Request) == "function" then
        S.Services.Trade:Request(true)
    end
    S.State:MarkDirty("all")
    if flushNow == true and S.UI ~= nil and type(S.UI.RefreshData) == "function" then
        S.UI:RefreshData(S.State:ConsumeDirty())
    end
end

-- The client can load/reload an addon before every world-backed X2 service is
-- ready, and ENTERED_WORLD may already have fired before our subscriptions are
-- installed.  Opening the Suite is explicit user intent to see current data, so
-- take a fresh snapshot synchronously and publish it immediately.  This does
-- not issue an auction query or force a trade-rate network request.
function R:RefreshForMainOpen()
    local now = tonumber(S.NowMs and S.NowMs()) or 0
    if self.firstOpenRefreshDone == true and self.lastOpenRefreshMs >= 0 and now - self.lastOpenRefreshMs < 750 then return end
    self.firstOpenRefreshDone = true
    self.lastOpenRefreshMs = now
    self:RefreshAll(false, true)
end

-- Two bounded warm-up retries bridge the short window where native world data
-- exists a few frames after addon startup.  They run on the Suite scheduler,
-- never own OnUpdate/Tick themselves, and never query auction/trade prices.
function R:InstallBootstrapDataWarmup()
    local delays = { 450, 1800 }
    for index, delayMs in ipairs(delays) do
        local taskName = "bootstrap_data_" .. tostring(index)
        S.Scheduler:RemoveTask(taskName)
        S.Scheduler:AddTask(taskName, delayMs, function()
            S.Scheduler:RemoveTask(taskName)
            R:RefreshAll(false, true)
        end, false)
    end
end

function R:StartModules()
    if S.ModuleManager == nil then error("module manager unavailable") end
    S.ModuleManager:InitializeAll()
    S.ModuleManager:StartConfiguredModules()
end

local SUITE_CONTENT_ID = 91730

function R:RegisterEscMenu()
    local window = S.UI ~= nil and S.UI.windows ~= nil and S.UI.windows.main or nil
    if window == nil then return false end
    if ReplicatedEscMenuPolicy == nil then return false end

    local contentOk, contentErr = ReplicatedEscMenuPolicy:RegisterContent(SUITE_CONTENT_ID, window, function(show)
        if S.Ready ~= true or self.started ~= true then return end
        local currentVisible = window:IsVisible() == true
        local desiredVisible = ReplicatedEscMenuPolicy:ResolveVisibility(show, currentVisible)
        if desiredVisible ~= currentVisible then
            S.UI:ToggleMain()
        elseif desiredVisible and window.Raise ~= nil then
            window:Raise()
        end
    end)
    if contentOk ~= true then
        S.WarnOnce("esc_content", "ESC 菜单内容入口注册失败：" .. tostring(contentErr or "unknown"))
        return false
    end
    local buttonOk, buttonErr = ReplicatedEscMenuPolicy:RegisterButton(3, SUITE_CONTENT_ID, "info", "Replicated Suite")
    if buttonOk ~= true then
        S.WarnOnce("esc_button", "ESC 菜单按钮注册失败：" .. tostring(buttonErr or "unknown"))
        return false
    end
    return true
end

function R:Start()
    if self.started then return true end

    S.Ready = false
    S.BootError = nil
    local stage = "start"
    local function EnterStage(name)
        stage = tostring(name or "unknown")
        S.BootStage = stage
        if S.PerformanceMonitor ~= nil and type(S.PerformanceMonitor.MarkStartup) == "function" then S.PerformanceMonitor:MarkStartup("start:" .. stage) end
    end

    local success, failure = xpcall(function()
        EnterStage("api_validate")
        if S.Api == nil or type(S.Api.Validate) ~= "function" then error("API boundary unavailable") end
        local apiOk, apiErr = S.Api:Validate()
        if not apiOk then error("API validation: " .. tostring(apiErr)) end

        -- Storage must be inside the startup fault fence. Audit5 called Load()
        -- before xpcall, so one unexpected legacy-save shape could abort the
        -- whole runtime without publishing BootError, leaving only the bootstrap
        -- R button and no diagnostic path.
        EnterStage("storage_load")
        if S.Storage == nil or type(S.Storage.Load) ~= "function" then error("storage unavailable") end
        S.Storage:Load()

        EnterStage("layout_prime")
        S.Layout:Invalidate()
        S.Layout:PrimeCurrentSignature()

        EnterStage("hud_create")
        -- Register long-lived HUD instances before constructing the HUD page so
        -- central HUD Authority can enumerate every built-in surface immediately.
        S.TaskWidget.Create()
        S.TradeWidget.Create()
        S.BondWidget.Create()
        S.EventWidget.Create()
        S.TreasureWidget.Create()
        S.FishingWidget.Create()

        EnterStage("shell_create")
        S.MainWindow.Create()
        S.MainButton.Create()
        S.QuestDetailWindow.Create()
        S.DailyCustomWindow.Create()
        S.TradeDetailWindow.Create()
        S.UI:ApplyResponsiveLayout(false)

        EnterStage("event_bus_start")
        if S.Events:Start() ~= true then error("private event bus failed to start") end

        EnterStage("scheduler_tasks")
        R:InstallSchedulerTasks()

        EnterStage("scheduler_start")
        if S.Scheduler:Start() ~= true then error("monotonic scheduler failed to start") end

        EnterStage("modules_start")
        R:StartModules()

        EnterStage("target_service")
        if S.TargetService ~= nil and type(S.TargetService.Start) == "function" then
            if S.TargetService:Start() ~= true then error("target service failed to start") end
        elseif S.TargetService ~= nil and type(S.TargetService.Initialize) == "function" then
            -- Compatibility fence for an older service shape.
            S.TargetService:Initialize()
        end

        EnterStage("refresh_settings")
        R:ApplyRefreshSettings()

        EnterStage("initial_snapshot")
        S.State:MarkDirty("all")
        S.UI:RefreshData(S.State:ConsumeDirty())

        EnterStage("bootstrap_warmup")
        R:InstallBootstrapDataWarmup()

        EnterStage("layout_finalize")
        S.UI:ApplyResponsiveLayout(false)

        EnterStage("esc_register")
        R:RegisterEscMenu()
    end, S.SafeTraceback)

    if not success then
        self.started = false
        S.Ready = false
        S.BootStage = stage
        S.BootError = "runtime/" .. tostring(stage) .. ": " .. tostring(failure)
        S.SafeChat("初始化失败 [" .. tostring(stage) .. "]：" .. tostring(failure))
        if S.ModuleManager then pcall(function() S.ModuleManager:Shutdown() end) end
        if S.Events then pcall(function() S.Events:Stop() end) end
        if S.Scheduler then pcall(function() S.Scheduler:Stop() end) end
        if S.UI then pcall(function() S.UI:HideAll(true) end) end
        if type(S.ActivateRecoveryEntry) == "function" then
            pcall(function() S.ActivateRecoveryEntry() end)
        elseif S.RecoveryEntry ~= nil then
            pcall(function() S.RecoveryEntry:Show(true) end)
        end
        return false
    end

    self.started = true
    S.Ready = true
    S.BootStage = "ready"
    if S.PerformanceMonitor ~= nil and type(S.PerformanceMonitor.MarkStartup) == "function" then S.PerformanceMonitor:MarkStartup("ready") end
    S.BootError = nil
    if rawget(_G, "ReplicatedSuiteFactoryResetPending") == true then
        rawset(_G, "ReplicatedSuiteFactoryResetPending", nil)
    end
    return true
end

R:Start()

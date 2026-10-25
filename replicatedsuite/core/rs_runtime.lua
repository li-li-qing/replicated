-- Replicated Suite · 运行生命周期
-- 作者：Replicated
-- QQ群：1104129461
-- 管理基础层、Scheduler、事件总线、FeatureRuntime 和表现宿主的生命周期，不再驱动旧 services/modules/HUD manager。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite

S.Runtime = {
    version = 5,
    started = false,
    firstOpenRefreshDone = false,
    lastOpenRefreshMs = -1,
    escRegistered = false,
    escRegistrationAttempts = 0,
    escRetryScheduled = false,
    lastEscError = nil,
    startupDegraded = false,
    startupWarnings = {},
    inputQuiescenceContractVersion = 1,
}
local R = S.Runtime

if S.PerformanceMonitor ~= nil and type(S.PerformanceMonitor.MarkStartup) == "function" then
    S.PerformanceMonitor:MarkStartup("toc_loaded")
end

local function EnterStage(name)
    S.BootStage = tostring(name or "unknown")
    if S.PerformanceMonitor ~= nil and type(S.PerformanceMonitor.MarkStartup) == "function" then
        S.PerformanceMonitor:MarkStartup("start:" .. S.BootStage)
    end
end

local function RecordStartupDegradation(stage, detail)
    local row = { stage = tostring(stage or "unknown"), detail = tostring(detail or "degraded") }
    R.startupDegraded = true
    R.startupWarnings = type(R.startupWarnings) == "table" and R.startupWarnings or {}
    if #R.startupWarnings < 8 then R.startupWarnings[#R.startupWarnings + 1] = row end
    local diagnostics = S.DiagnosticsManager
    if type(diagnostics) == "table" and type(diagnostics.Emit) == "function" then
        diagnostics:Emit("warning", "runtime", "RUNTIME_STARTUP_DEGRADED",
            "Runtime 已隔离非核心启动故障并继续提供主界面", { stage = row.stage, error = row.detail })
    end
end

function R:Stop()
    -- 热重载与正常销毁共用幂等静止隔离。
    S.Ready = false
    self.started = false
    if type(S.UI) == "table" and type(S.UI.QuiesceKeyboardInput) == "function" then
        pcall(function() S.UI:QuiesceKeyboardInput("runtime_stop", false) end)
    end
    -- 销毁或热重载不能激活 EditBox 键盘所有者。R 启动器仍是引导恢复路径；只有下方实际启动失败才显式显示命令输入。
    if type(S.SetRecoveryCommandBarVisible) == "function" then
        pcall(function() S.SetRecoveryCommandBarVisible(false) end)
    end

    -- 先完成耐久屏障，再销毁 Feature；Disable/Stop 可能清缓存或瞬态数据，之后 Flush 会覆盖健康配置。
    -- DisableAll 后不能再做第二次 Flush。
    local persistenceOk, persistenceErr = true, nil
    if S.Persistence ~= nil and type(S.Persistence.Flush) == "function" then
        local callOk, flushed, failures = pcall(function() return S.Persistence:Flush() end)
        if callOk ~= true or flushed ~= true then
            persistenceOk = false
            if callOk ~= true then
                persistenceErr = tostring(flushed or "persistence flush exception")
            elseif type(failures) == "table" then
                persistenceErr = table.concat(failures, ";")
            else
                persistenceErr = tostring(failures or "persistence flush failed")
            end
            if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Emit) == "function" then
                S.DiagnosticsManager:Emit("error", "runtime", "RUNTIME_STOP_PERSISTENCE_FAILED",
                    "Runtime 关闭前配置未能全部安全落盘；已继续静默资源但未再次写入 teardown 状态",
                    { error = persistenceErr })
            end
        end
    end

    local featureOk, featureErr = true, nil
    if S.FeatureRuntime ~= nil and type(S.FeatureRuntime.DisableAll) == "function" then
        local callOk, disabled, disableErr = pcall(function() return S.FeatureRuntime:DisableAll("shutdown") end)
        if callOk ~= true or disabled ~= true then
            featureOk = false
            featureErr = callOk == true and tostring(disableErr or "feature disable failed") or tostring(disabled)
        end
    end
    if S.RefreshCoordinator ~= nil and type(S.RefreshCoordinator.ClearAll) == "function" then
        pcall(function() S.RefreshCoordinator:ClearAll() end)
    end
    -- 共享 Service 的租约不一定属于 Feature；ClearAll 失败不能被 pcall 的“调用未抛错”吞掉。
    -- 无论释放是否成功仍继续停 Events/Scheduler/外壳，最后向调用者返回失败，保留正常重试入口。
    local demandOk, demandErr = true, nil
    if S.Demand ~= nil and type(S.Demand.ClearAll) == "function" then
        local callOk, cleared, clearErr = pcall(function() return S.Demand:ClearAll("runtime_stop") end)
        if callOk ~= true or cleared ~= true then
            demandOk = false
            demandErr = callOk == true and tostring(clearErr or "demand cleanup failed") or tostring(cleared)
            if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Emit) == "function" then
                S.DiagnosticsManager:Emit("error", "runtime", "RUNTIME_STOP_DEMAND_FAILED",
                    "Runtime 关闭时共享需求释放失败；已继续静默事件、任务和外壳", { error = demandErr })
            end
        end
    end
    if S.Layout and type(S.Layout.StopMetricsEvents) == "function" then pcall(function() S.Layout:StopMetricsEvents() end) end
    if S.Events ~= nil and type(S.Events.Stop) == "function" then pcall(function() S.Events:Stop() end) end
    if S.Scheduler ~= nil and type(S.Scheduler.Stop) == "function" then pcall(function() S.Scheduler:Stop() end) end
    self.escRetryScheduled = false
    if S.UIHostManager ~= nil and type(S.UIHostManager.HideAll) == "function" then
        pcall(function() S.UIHostManager:HideAll(false) end)
    end
    if persistenceOk ~= true then return false, persistenceErr end
    if featureOk ~= true then return false, featureErr end
    if demandOk ~= true then return false, demandErr end
    return true
end

function R:InstallSchedulerTasks()
    local scheduler = S.Scheduler
    if scheduler == nil or type(scheduler.AddTask) ~= "function" then return false, "scheduler unavailable" end

    -- 基础任务须整批安装；任一失败都回滚，不能仅安装部分 Persistence/Layout/Observation 后报告启动成功。
    local installed = {}
    local function Add(name, intervalMs, callback, runImmediately, owner, priority)
        local ok = scheduler:AddTask(name, intervalMs, callback, runImmediately, owner, priority)
        if ok == true then installed[#installed + 1] = name; return true end
        for _, installedName in ipairs(installed) do scheduler:RemoveTask(installedName) end
        return false
    end

    -- 共享 Scheduler 驱动周期任务。事件总线和 Scheduler 启动后，Layout 才安装通知与有限稳定采样，不永久轮询 metrics。

    if Add("v3_persistence", math.max(200, tonumber(S.Constants.Refresh.storageMs) or 200), function()
        if S.Persistence ~= nil and type(S.Persistence.Tick) == "function" then S.Persistence:Tick() end
    end, false, S.Persistence, "P2") ~= true then return false, "persistence scheduler task registration failed" end

    if Add("v3_observation_prune", 5000, function()
        if S.Observation ~= nil and type(S.Observation.Prune) == "function" then S.Observation:Prune(120000) end
    end, false, S.Observation, "P5") ~= true then return false, "observation prune scheduler task registration failed" end
    return true
end

function R:RegisterPresentationHosts()
    local manager = S.UIHostManager
    if manager == nil or type(manager.IsRegistered) ~= "function" then return false, "UIHostManager unavailable" end
    if manager:IsRegistered("v3") ~= true then return false, "V3 presentation host adapter not registered" end
    if manager:IsRegistered("legacy") == true then return false, "Legacy presentation host must not be active" end
    manager.defaultId = "v3"
    manager.activeId = "v3"
    return true
end

local SUITE_CONTENT_ID = 91730
local ESC_RETRY_TASK = "runtime_esc_registration_retry"

local function EmitEsc(level, code, message, context)
    local diagnostics = S.DiagnosticsManager
    if type(diagnostics) == "table" and type(diagnostics.Emit) == "function" then
        diagnostics:Emit(level, "runtime", code, message, context)
    end
end

function R:RegisterEscMenu(reason)
    local manager = S.UIHostManager
    local esc = S.NativeEscBridge
    if type(esc) == "table" and type(esc.IsReady) == "function" and esc:IsReady(SUITE_CONTENT_ID) == true then
        self.escRegistered = true
        self.lastEscError = nil
        return true
    end

    self.escRegistrationAttempts = (tonumber(self.escRegistrationAttempts) or 0) + 1
    local function Fail(detail)
        self.escRegistered = false
        self.lastEscError = tostring(detail or "unknown")
        EmitEsc("warning", "ESC_REGISTRATION_FAILED", "系统菜单入口注册失败；R 恢复入口仍可使用", {
            reason = tostring(reason or "runtime"),
            attempt = tonumber(self.escRegistrationAttempts) or 0,
            error = self.lastEscError,
        })
        return false, self.lastEscError
    end

    if manager == nil or type(manager.GetWindow) ~= "function" then return Fail("UIHostManager unavailable") end
    if type(esc) ~= "table" or type(esc.RegisterContent) ~= "function" or type(esc.RegisterButton) ~= "function" then
        return Fail("NativeEscBridge unavailable")
    end
    local window = manager:GetWindow("v3")
    if window == nil then return Fail("V3 host window unavailable") end

    local contentOk, contentErr = esc:RegisterContent(SUITE_CONTENT_ID, window, function(show)
        if S.Ready ~= true or R.started ~= true then return end
        local currentVisible = false
        if type(window.IsVisible) == "function" then
            local visibleOk, visible = pcall(function() return window:IsVisible() end)
            if visibleOk == true then
                currentVisible = visible == true
            else
                EmitEsc("warning", "ESC_VISIBILITY_READ_FAILED", "系统菜单读取主界面可见性失败", { error = tostring(visible) })
            end
        end
        local desiredVisible = esc:ResolveVisibility(show, currentVisible)
        if desiredVisible ~= currentVisible then
            local toggleOk, toggleErr = manager:Toggle("v3")
            if toggleOk ~= true then
                EmitEsc("error", "ESC_HOST_TOGGLE_FAILED", "系统菜单切换主界面失败", { error = tostring(toggleErr or "unknown") })
            end
        elseif desiredVisible and type(window.Raise) == "function" then
            local raiseOk, raiseErr = pcall(function() return window:Raise() end)
            if raiseOk ~= true then
                EmitEsc("warning", "ESC_HOST_RAISE_FAILED", "系统菜单提升主界面层级失败", { error = tostring(raiseErr or "unknown") })
            end
        end
    end)
    if contentOk ~= true then
        S.WarnOnce("esc_content", "系统菜单内容入口注册失败：" .. tostring(contentErr or "unknown"))
        return Fail(contentErr or "content registration failed")
    end

    local buttonOk, buttonErr = esc:RegisterButton(3, SUITE_CONTENT_ID, "info", "上古世纪综合辅助")
    if buttonOk ~= true then
        S.WarnOnce("esc_button", "系统菜单按钮注册失败：" .. tostring(buttonErr or "unknown"))
        return Fail(buttonErr or "button registration failed")
    end

    self.escRegistered = true
    self.lastEscError = nil
    if (tonumber(self.escRegistrationAttempts) or 0) > 1 then
        EmitEsc("info", "ESC_REGISTRATION_RECOVERED", "系统菜单入口已在有限重试后恢复", {
            reason = tostring(reason or "runtime"), attempt = tonumber(self.escRegistrationAttempts) or 0,
        })
    end
    return true
end

function R:ScheduleEscRegistrationRetry(delayMs)
    if self.escRegistered == true or self.escRetryScheduled == true then return true end
    local scheduler = S.Scheduler
    if type(scheduler) ~= "table" or type(scheduler.AddOneShot) ~= "function" then
        return false, "scheduler one-shot unavailable"
    end
    self.escRetryScheduled = true
    local added = scheduler:AddOneShot(ESC_RETRY_TASK, math.max(250, tonumber(delayMs) or 750), function()
        R.escRetryScheduled = false
        if S.Ready ~= true or R.started ~= true then return false end
        return R:RegisterEscMenu("bounded_retry")
    end, self, "P4", 1)
    if added ~= true then
        self.escRetryScheduled = false
        return false, "ESC retry task registration failed"
    end
    return true
end

function R:Describe()
    local bridge = S.NativeEscBridge
    local bridgeInfo = type(bridge) == "table" and type(bridge.Describe) == "function" and bridge:Describe(SUITE_CONTENT_ID) or nil
    local registered = self.escRegistered == true
    if type(bridge) == "table" and type(bridge.IsReady) == "function" then registered = bridge:IsReady(SUITE_CONTENT_ID) == true end
    return {
        version = self.version,
        started = self.started == true,
        escRegistered = registered,
        escRegistrationAttempts = tonumber(self.escRegistrationAttempts) or 0,
        escRetryScheduled = self.escRetryScheduled == true,
        lastEscError = self.lastEscError,
        startupDegraded = self.startupDegraded == true,
        startupWarnings = self.startupWarnings,
        startupWarningCount = #(type(self.startupWarnings) == "table" and self.startupWarnings or {}),
        escBridge = bridgeInfo,
    }
end

function R:RefreshAll(_, flushNow)
    -- 保留引导或开发刷新动作的兼容名称；V3 刷新归 Feature，不扫描旧 Service 清单。
    if S.FeatureRuntime ~= nil and type(S.FeatureRuntime.RefreshEnabled) == "function" then
        S.FeatureRuntime:RefreshEnabled("manual_refresh")
    end
    if flushNow == true and S.UIHostManager ~= nil and type(S.UIHostManager.RefreshData) == "function" then
        S.UIHostManager:RefreshData({ reason = "manual_refresh", generation = S.Generation })
    end
    return true
end

function R:RefreshForMainOpen()
    local now = tonumber(S.NowMs and S.NowMs()) or 0
    if self.firstOpenRefreshDone == true and self.lastOpenRefreshMs >= 0 and now - self.lastOpenRefreshMs < 500 then return true end
    self.firstOpenRefreshDone = true
    self.lastOpenRefreshMs = now
    if S.FeatureRuntime ~= nil and type(S.FeatureRuntime.RefreshEnabled) == "function" then
        S.FeatureRuntime:RefreshEnabled("main_open")
    end
    if S.UIHostManager ~= nil and type(S.UIHostManager.RefreshData) == "function" then
        S.UIHostManager:RefreshData({ reason = "main_open", generation = S.Generation })
    end
    return true
end

local function ValidateStaticData()
    if S.GameDataRegistry ~= nil and type(S.GameDataRegistry.Validate) == "function" then
        local report = S.GameDataRegistry:Validate()
        if report.ok ~= true and S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Warn) == "function" then
            S.DiagnosticsManager:Warn("game_data", "REGISTRY_VALIDATION_ISSUES", "共享游戏数据注册表存在校验问题", {
                errors = tonumber(report.errors) or 0,
                warnings = tonumber(report.warnings) or 0,
                records = tonumber(report.totalRecords) or 0,
            })
        end
    end
    if S.StaticDataV2 ~= nil and type(S.StaticDataV2.Validate) == "function" then
        local report = S.StaticDataV2:Validate()
        if report.ok ~= true and S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Warn) == "function" then
            S.DiagnosticsManager:Warn("static_data_v2", "VALIDATION_ISSUES", "Static Data V2 存在校验问题", {
                errors = #(report.errors or {}), warnings = #(report.warnings or {}), records = tonumber(report.records) or 0,
            })
        end
    end
end

local function SealStaticData()
    if S.GameDataRegistry ~= nil and type(S.GameDataRegistry.Seal) == "function" then S.GameDataRegistry:Seal("v3_runtime_start") end
    if S.StaticDataV2 ~= nil and type(S.StaticDataV2.Seal) == "function" then S.StaticDataV2:Seal("v3_runtime_start") end
end

function R:Start()
    if self.started == true then return true end
    S.Ready = false
    S.BootError = nil
    self.startupDegraded = false
    self.startupWarnings = {}

    local success, failure = xpcall(function()
        EnterStage("api_validate")
        if S.Api == nil or type(S.Api.Validate) ~= "function" then error("API boundary unavailable") end
        local apiOk, apiErr = S.Api:Validate()
        if apiOk ~= true then error("API validation: " .. tostring(apiErr)) end

        EnterStage("static_validate")
        ValidateStaticData()

        EnterStage("static_seal")
        SealStaticData()

        EnterStage("app_state_load")
        if S.AppState == nil or type(S.AppState.EnsureLoaded) ~= "function" then error("V3 AppState unavailable") end
        local stateOk, stateErr = S.AppState:EnsureLoaded()
        if stateOk ~= true then error("V3 AppState load failed: " .. tostring(stateErr or "unknown")) end

        EnterStage("layout_prime")
        if S.Layout == nil then error("Layout unavailable") end
        S.Layout:Invalidate()
        S.Layout:PrimeCurrentSignature()
        if S.UIV3 ~= nil and type(S.UIV3.EnsureLauncherStoreLoaded) == "function" then
            local launcherOk, launcherErr = S.UIV3:EnsureLauncherStoreLoaded()
            if launcherOk ~= true then error("launcher store load failed: " .. tostring(launcherErr or "unknown")) end
            if type(S.UIV3.ApplyLauncherPlacement) == "function" then S.UIV3:ApplyLauncherPlacement() end
        end

        EnterStage("presentation_hosts")
        local hostOk, hostErr = self:RegisterPresentationHosts()
        if hostOk ~= true then error("presentation host registration: " .. tostring(hostErr or "failed")) end
        local host, hostCreateErr = S.UIHostManager:Ensure("v3")
        if host == nil then error("default presentation host create failed: v3 · " .. tostring(hostCreateErr or "unknown")) end

        EnterStage("event_bus_start")
        if S.Events == nil or S.Events:Start() ~= true then error("private event bus failed to start") end

        EnterStage("scheduler_tasks")
        local tasksOk, tasksErr = self:InstallSchedulerTasks()
        if tasksOk ~= true then error(tasksErr or "scheduler task install failed") end

        EnterStage("scheduler_start")
        if S.Scheduler == nil or S.Scheduler:Start() ~= true then error("monotonic scheduler failed to start") end
        if S.Layout and type(S.Layout.StartMetricsEvents) == "function" then S.Layout:StartMetricsEvents() end

        EnterStage("feature_defaults")
        if S.FeatureRuntime ~= nil and type(S.FeatureRuntime.EnableDefaults) == "function" then
            local featureOk, featureErr = S.FeatureRuntime:EnableDefaults("runtime_start")
            -- Feature 偏好/API/Store 故障只停该功能并显示诊断；主外壳继续 Ready，供用户检查或禁用。
            if featureOk ~= true then RecordStartupDegradation("feature_defaults", featureErr or "default feature enable failed") end
        end

        EnterStage("foundation_refresh")
        S.UIHostManager:RefreshData({ reason = "foundation_start", generation = S.Generation })

        EnterStage("layout_finalize")
        local layoutOk, layoutErr = S.UIHostManager:ApplyResponsiveLayout(false)
        if layoutOk ~= true then error("V3 layout failed: " .. tostring(layoutErr or "unknown")) end

        EnterStage("esc_register")
        self:RegisterEscMenu("startup")
    end, S.SafeTraceback)

    if success ~= true then
        self.started = false
        S.Ready = false
        S.BootError = "runtime/" .. tostring(S.BootStage or "unknown") .. ": " .. tostring(failure)
        S.SafeChat("初始化失败 [" .. tostring(S.BootStage or "unknown") .. "]：" .. tostring(failure))
        -- 启动回滚也先保存已加载/迁移的 dirty Store，再允许 Feature 释放 Domain；保存失败留证，销毁仍继续。
        if S.Persistence ~= nil and type(S.Persistence.Flush) == "function" then
            pcall(function() S.Persistence:Flush() end)
        end
        if S.FeatureRuntime ~= nil then pcall(function() S.FeatureRuntime:DisableAll("startup_failure") end) end
        if S.RefreshCoordinator ~= nil and type(S.RefreshCoordinator.ClearAll) == "function" then pcall(function() S.RefreshCoordinator:ClearAll() end) end
        if S.Demand ~= nil and type(S.Demand.ClearAll) == "function" then pcall(function() S.Demand:ClearAll("startup_failure") end) end
        -- 失败回滚也释放通知 owner/单次任务，旧代不能复活窗口。
        if S.Layout and type(S.Layout.StopMetricsEvents) == "function" then pcall(function() S.Layout:StopMetricsEvents() end) end
        if S.Events ~= nil then pcall(function() S.Events:Stop() end) end
        if S.Scheduler ~= nil then pcall(function() S.Scheduler:Stop() end) end
        if S.UIHostManager ~= nil then pcall(function() S.UIHostManager:HideAll(true) end) end
        if type(S.ActivateRecoveryEntry) == "function" then pcall(function() S.ActivateRecoveryEntry() end) end
        if type(S.SetRecoveryCommandBarVisible) == "function" then
            pcall(function() S.SetRecoveryCommandBarVisible(true) end)
        end
        return false
    end

    self.started = true
    S.Ready = true
    S.BootStage = "ready"
    S.BootError = nil
    -- 正常 UI 健康时隐藏应急 editbox，避免争抢聊天或输入焦点；R 启动器仍保留。
    if type(S.SetRecoveryCommandBarVisible) == "function" then
        pcall(function() S.SetRecoveryCommandBarVisible(false) end)
    end
    -- 宿主构造可能在逻辑隐藏外壳下创建可见原生 EditBox；只清除已证明属于 Suite 的焦点，再把正常游戏输入交还
    -- 客户端。
    if type(S.UI) == "table" and type(S.UI.QuiesceKeyboardInput) == "function" then
        pcall(function() S.UI:QuiesceKeyboardInput("runtime_ready", false) end)
    end
    if self.escRegistered ~= true then
        local retryOk, retryErr = self:ScheduleEscRegistrationRetry(750)
        if retryOk ~= true then
            self.lastEscError = tostring(retryErr or self.lastEscError or "ESC retry unavailable")
            EmitEsc("warning", "ESC_RETRY_UNAVAILABLE", "系统菜单入口首次注册失败且有限重试无法调度", { error = self.lastEscError })
        end
    end
    if S.PerformanceMonitor ~= nil and type(S.PerformanceMonitor.MarkStartup) == "function" then
        S.PerformanceMonitor:MarkStartup("ready")
    end
    return true
end

R:Start()

-- Replicated Suite · 插件引导入口
-- 作者：Replicated
-- QQ群：1104129461
ReplicatedSuite = ReplicatedSuite or {}
local S = ReplicatedSuite

-- V3 是当前运行架构；已移除的 Legacy/Professional 与 globals 不能从引导重新加载。
S.ArchitectureMode = "v3_rebuild"

-- 在 TOC 继续加载 V3 运行体前保留轻量进程时间基准，仅作诊断，不持久化。
local bootOs = rawget(_G, "os")
local bootNow = nil
if type(bootOs) == "table" and type(bootOs.clock) == "function" then
    local ok, value = pcall(bootOs.clock)
    if ok and type(value) == "number" then bootNow = value * 1000 end
end
S.BootLoadStartedAt = bootNow

-- 先停止上一轮运行任务，再替换热重载引用。
local previousRuntime = rawget(S, "Runtime")
local previousUI = rawget(S, "UI")
if type(previousRuntime) == "table" and type(previousRuntime.Stop) == "function" then
    pcall(function() previousRuntime:Stop() end)
end
if type(previousUI) == "table" and type(previousUI.QuiesceKeyboardInput) == "function" then
    pcall(function() previousUI:QuiesceKeyboardInput("bootstrap_hot_reload", true) end)
end
if type(previousUI) == "table" and type(previousUI.HideAll) == "function" then
    pcall(function() previousUI:HideAll() end)
end
local previousRecoveryEntry = rawget(S, "RecoveryEntry")
if previousRecoveryEntry ~= nil and type(previousRecoveryEntry.Show) == "function" then
    pcall(function() previousRecoveryEntry:Show(false) end)
end
local previousRecoveryCommandBar = rawget(S, "RecoveryCommandBar")
if previousRecoveryCommandBar ~= nil then
    local edit = previousRecoveryCommandBar.edit
    if edit ~= nil then
        -- 隐藏 RU EditBox 可能跨插件重载保留键盘焦点；释放处理器或隐藏旧代际前必须归还焦点。
        if type(edit.ClearFocus) == "function" then pcall(function() edit:ClearFocus() end) end
        if type(edit.EnableKeyboard) == "function" then pcall(function() edit:EnableKeyboard(false) end) end
        if type(edit.EnableFocus) == "function" then pcall(function() edit:EnableFocus(false) end) end
        if type(edit.ReleaseHandler) == "function" then
            pcall(function() edit:ReleaseHandler("OnEnterPressed") end)
        end
    end
    if type(previousRecoveryCommandBar.Show) == "function" then
        pcall(function() previousRecoveryCommandBar:Show(false) end)
    end
end
S.RecoveryEntry = nil
S.RecoveryEntryHealthy = false
S.RecoveryEntryError = nil
S.RecoveryCommandBar = nil
S.RecoveryCommandHealthy = false
S.RecoveryCommandError = nil
-- ReloadAddon 可能保留根表；须清除旧 pending gate 和 detached reload host，否则下次开发重载会被旧状态阻断。
local previousCodeReloadHost = rawget(S, "CodeReloadHost")
if previousCodeReloadHost ~= nil then
    if type(previousCodeReloadHost.ReleaseHandler) == "function" then
        pcall(function() previousCodeReloadHost:ReleaseHandler("OnUpdate") end)
    end
    if type(previousCodeReloadHost.Show) == "function" then
        pcall(function() previousCodeReloadHost:Show(false) end)
    end
end
S.CodeReloadHost = nil
S.CodeReloadPending = false
-- bootstrap 与恢复安装阶段不能触碰受限 r_VSync，它在 RU ArcheRage 会触发真实 UI 重载。只解绑旧代际残留辅助
-- 回调，恢复时不写控制台变量。
local previousRestoreHost = rawget(S, "ReloadRestoreHost")
if previousRestoreHost ~= nil then
    if type(previousRestoreHost.ReleaseHandler) == "function" then
        pcall(function() previousRestoreHost:ReleaseHandler("OnUpdate") end)
    end
    if type(previousRestoreHost.Show) == "function" then pcall(function() previousRestoreHost:Show(false) end) end
end
S.ReloadRestoreHost = nil
S.ReloadRestoreOriginal = nil
S.ReloadRestorePending = false

S.Author = "Replicated"
S.Name = "Replicated Suite"
S.Version = "1.2"
S.BuildTag = "v3-m1.16.0.18.332-phase2-life-bundle-slice-complete"
S.Generation = (tonumber(S.Generation) or 0) + 1
S.Config = type(ReplicatedSuiteConfig) == "table" and ReplicatedSuiteConfig or {}
S.SaveKey = tostring(S.Config.SaveKey or "replicated_suite_v1")
S.MainWindowTitle = tostring(S.Config.MainWindowTitle or "作者：Replicated     qq群：1104129461")
S.Ready = false
S.BootStage = "bootstrap"
S.BootError = nil
S.NativeContract = nil
S.NativeImports = nil
S.NativeObjectFactory = nil
S.NativeEscBridge = nil
S.NativeCapabilities = nil
S.Api = nil
S.ApiImports = nil
S.AppState = nil
S.State = nil
S.Storage = nil
S.Persistence = nil
S.UIHostManager = nil
S.FoundationGate = nil
S.Layout = nil
S.Scheduler = nil
S.RefreshCoordinator = nil
S.Demand = nil
S.Events = nil
S.ModuleManager = nil
S.HudManager = nil
S.ApiCapabilities = nil
S.SettingsRegistry = nil
S.Profiles = nil
S.DiagnosticsManager = nil
S.Observation = nil
S.Theme = nil
S.UI = nil
S.RSUI = nil
S.UIV3 = nil
S.UIV3Host = nil
S.UIV3NativeAdapter = nil
S.UIV3Design = nil
S.FeatureRegistry = nil
S.FeatureRuntime = nil
S.Features = nil
-- 根表可跨 UI 重载保留，须清除旧代际引用；原生实例已在上方停止并隐藏。
S.MainWindow = nil
S.MainButton = nil
S.AppShell = nil
S.ProfessionalPages = nil
S.LifeWorkspace = nil
S.CombatWorkspace = nil
S.TeamWorkspace = nil
S.TaskWidget = nil
S.TradeWidget = nil
S.BondWidget = nil
S.EventWidget = nil
S.TreasureWidget = nil
S.FishingWidget = nil
S.WidgetBase = nil
S.Runtime = nil
S.Services = nil
S.Data = nil
S.GameIds = nil
S.GameDataRegistry = nil
S.StaticDataV2 = nil
S.Utils = nil

-- 当前代际的有界日志汇集 Suite 通知和诊断记录，长会话也不能无限增长。
S.LogBuffer = {}
S.LogSequence = 0
S.LogDropped = 0
S.LogBufferMax = 200
-- 采集失败计数属于当前 generation；不能让诊断异常递归写日志。
S.SelfCheckCaptureFailures = 0

local function RecordLog(level, source, message)
    local buffer = S.LogBuffer
    if type(buffer) ~= "table" then
        buffer = {}
        S.LogBuffer = buffer
    end
    S.LogSequence = (tonumber(S.LogSequence) or 0) + 1
    buffer[#buffer + 1] = {
        seq = S.LogSequence,
        level = tostring(level or "info"),
        source = tostring(source or "suite"),
        message = tostring(message or ""),
        at = type(S.NowMs) == "function" and (tonumber(S.NowMs()) or 0) or 0,
    }
    -- warning/error 进入同一有界错误环，避免 info 挤掉根因。先验 Generation，不投递到旧 manager。
    -- Diagnostics 不反写 RecordLog；采集异常只计数，原日志仍保留。
    local diagnostic = S.DiagnosticsManager
    if (level == "error" or level == "warning" or level == "warn") and type(diagnostic) == "table"
        and diagnostic.SelfCheckGeneration == S.Generation and type(diagnostic.CaptureSelfCheckIssue) == "function" then
        local captured = pcall(diagnostic.CaptureSelfCheckIssue, diagnostic, buffer[#buffer])
        if not captured then S.SelfCheckCaptureFailures = (S.SelfCheckCaptureFailures or 0) + 1 end
    end
    local limit = math.max(20, tonumber(S.LogBufferMax) or 200)
    while #buffer > limit do
        table.remove(buffer, 1)
        S.LogDropped = (tonumber(S.LogDropped) or 0) + 1
    end
end

local function DispatchSystemChat(text)
    text = tostring(text or "")
    if X2Chat ~= nil and X2Chat.DispatchChatMessage ~= nil then
        local ok = pcall(function() X2Chat:DispatchChatMessage(CMF_SYSTEM, text) end)
        if ok then return true end
    end
    if ADDON ~= nil and ADDON.ChatLog ~= nil then
        local ok = pcall(function() ADDON:ChatLog(text) end)
        if ok then return true end
    end
    return false
end

local function SafeTraceback(err)
    if debug ~= nil and debug.traceback ~= nil then
        return debug.traceback(tostring(err), 2)
    end
    return tostring(err)
end

local function SafeChat(message, level, source)
    local body = tostring(message or "")
    RecordLog(level or "info", source or "chat", body)
    return DispatchSystemChat("[上古世纪综合辅助] " .. body)
end

-- RU 的 UI:GetCurrentTimeStamp() 可能存在却在插件中冻结；debounce/timeout/timer 使用 OnUpdate 驱动的单调时间。
S.Clock = { elapsedMs = 0 }
local function NowMs()
    local value = tonumber(S.Clock and S.Clock.elapsedMs) or 0
    if value ~= value or value == math.huge or value == -math.huge then return 0 end
    return math.max(0, value)
end
local function AdvanceClock(deltaMs)
    local delta = tonumber(deltaMs) or 0
    if delta ~= delta or delta == math.huge or delta == -math.huge or delta < 0 then delta = 0 end
    if delta > 0 and delta < 1 then delta = delta * 1000 end
    if delta > 1000 then delta = 1000 end
    S.Clock.elapsedMs = NowMs() + delta
    return S.Clock.elapsedMs
end

S.Diagnostics = { seen = {} }
function S.WarnOnce(key, message)
    key = tostring(key or message or "warning")
    if S.Diagnostics.seen[key] == true then return end
    S.Diagnostics.seen[key] = true
    -- WarnOnce 按 warning 进入错误历史，保持原去重规则。
    SafeChat(message, "warning", "suite.warn_once")
end

-- 长原生路径曾触发重复登记，追加代际尾缀仍可能超长。逻辑 ID 保持可读，原生名称改用完整代际和递增序号。
-- 反向映射仅供诊断，业务不能依赖物理名。
local function Base36(value, width)
    local alphabet = "0123456789abcdefghijklmnopqrstuvwxyz"
    local n = math.max(0, math.floor(tonumber(value) or 0))
    local out = ""
    repeat
        local digit = (n % 36) + 1
        out = alphabet:sub(digit, digit) .. out
        n = math.floor(n / 36)
    until n <= 0
    width = math.max(0, math.floor(tonumber(width) or 0))
    while #out < width do out = "0" .. out end
    return out
end

S.NativeIdentity = {
    -- 2026-10-06 实机警告中的祖先路径均为 259 字节，单节点短名仍可能累加超长。
    -- 当前 generation+序号通常约 5..8 字节，只在创建时分配；259 是日志观测边界，并非已验证 Native 上限。
    version = 3,
    maxPhysicalLength = 15,
    sequence = 0,
    logicalToPhysical = {},
    physicalToLogical = {},
    requests = 0,
    collisions = 0,
    maxObservedLength = 0,
}

function S.NativeIdentity:Build(logicalId, generation, collisionSalt)
    local gen = math.max(0, math.floor(tonumber(generation) or 0))
    self.sequence=(tonumber(self.sequence) or 0)+1
    -- 不取 generation 模、不截断名字；极端超长值仍由 NativeObjectFactory 原有长度门拒绝。
    return "rs"..Base36(gen).."_"..Base36(self.sequence)
end

function S.PhysicalId(id)
    local logical = tostring(id or "widget")
    local registry = S.NativeIdentity
    registry.requests = (tonumber(registry.requests) or 0) + 1
    local cached = registry.logicalToPhysical[logical]
    if cached ~= nil then return cached end

    local attempt = 0
    local physical = nil
    while attempt < 32 do
        physical = registry:Build(logical, S.Generation, attempt)
        local previous = registry.physicalToLogical[physical]
        if previous == nil or previous == logical then break end
        registry.collisions = (tonumber(registry.collisions) or 0) + 1
        attempt = attempt + 1
        physical = nil
    end
    if physical == nil then
        -- 代际内唯一序号通常使此分支不可达；仍确定性失败，不能退回不安全长 ID。
        physical = registry:Build("identity_collision_" .. logical, S.Generation, 31)
    end
    registry.logicalToPhysical[logical] = physical
    registry.physicalToLogical[physical] = logical
    registry.maxObservedLength = math.max(tonumber(registry.maxObservedLength) or 0, #physical)
    return physical
end

function S.DescribeNativeIdentity()
    local registry = S.NativeIdentity or {}
    local mapped = 0
    for _ in pairs(registry.logicalToPhysical or {}) do mapped = mapped + 1 end
    return {
        version = tonumber(registry.version) or 0,
        maxPhysicalLength = tonumber(registry.maxPhysicalLength) or 0,
        maxObservedLength = tonumber(registry.maxObservedLength) or 0,
        requests = tonumber(registry.requests) or 0,
        mapped = mapped,
        collisions = tonumber(registry.collisions) or 0,
    }
end

S.SafeTraceback = SafeTraceback
S.SafeChat = SafeChat
S.RecordLog = RecordLog
S.DispatchSystemChat = DispatchSystemChat
S.NowMs = NowMs
S.AdvanceClock = AdvanceClock

-- Native 导入在 bootstrap 后执行。恢复 R 先在此创建，保证后续 TOC 出错时仍有游戏内重载入口；
-- Runtime 成功后接管同一控件。
local externalRecovery = rawget(_G, "ReplicatedSuiteRecovery")
if type(externalRecovery) == "table" and externalRecovery.button ~= nil and type(externalRecovery.button.Show) == "function" then
    pcall(function() externalRecovery.button:Show(false) end)
end
-- 旧前置引导恢复所有者不在 toc.g 中；释放残留代际，使 R 只归 bootstrap 所有。
ReplicatedSuiteRecovery = nil
local function BootStatusText()
    local stage = tostring(S.BootStage or "bootstrap")
    local err = S.BootError ~= nil and tostring(S.BootError) or "插件尚未完成初始化"
    return "阶段=" .. stage
        .. "；R=" .. tostring(S.RecoveryEntryHealthy == true)
        .. "；CMD=" .. tostring(S.RecoveryCommandHealthy == true)
        .. "；" .. err
end

-- 旧热重载设置页可能仍引用兼容名称；此函数只刷新 Suite 内部数据和布局，不重载插件、不切换 VSync、不写控制台变量。
local function SafeSuiteRefresh(source)
    if S.Ready ~= true or S.Runtime == nil or S.Runtime.started ~= true then
        SafeChat("刷新未执行：插件尚未就绪；" .. BootStatusText())
        return false
    end

    local ok, err = xpcall(function()
        if type(S.Runtime.RefreshAll) == "function" then S.Runtime:RefreshAll(true, true) end
        if S.Layout ~= nil then
            if type(S.Layout.Invalidate) == "function" then S.Layout:Invalidate() end
            if type(S.Layout.GetContext) == "function" then S.Layout:GetContext(true) end
        end
        if S.UIHostManager ~= nil and type(S.UIHostManager.ApplyResponsiveLayout) == "function" and S.UIHostManager:GetActive() ~= nil then
            S.UIHostManager:ApplyResponsiveLayout(true)
        end
    end, S.SafeTraceback)
    if not ok then
        SafeChat("插件内部刷新失败：" .. tostring(err))
        return false
    end
    if source == "recovery" or source == "settings" then
        SafeChat("已刷新插件数据与界面；未重新载入游戏界面。")
    end
    return true
end
S.SafeSuiteRefresh = SafeSuiteRefresh
S.ForceUiReload = SafeSuiteRefresh

-- 不能从插件自有 Widget 或 OnUpdate 回调调用 ReloadAddon：2026-08-15 实机在销毁仍在 dispatcher 栈上的宿主后崩溃。
-- 显式重载沿用已验证 uirefresh 的 r_VSync 切换，触发文件重读，不创建会自毁的回调宿主。
S.RecoveryReloadContractVersion = 1
S.LastReloadFlushFailure = nil

local function ReloadCodeFromDisk(source, options)
    options = type(options) == "table" and options or {}
    local requireDurable = options.requireDurable == true

    if X2Option == nil or type(X2Option.SetConsoleVariable) ~= "function" then
        SafeChat("重载失败：游戏界面刷新接口不可用。")
        return false
    end

    -- 恢复重载先尝试耐久屏障；损坏 Store 不能锁死加载修复的入口，须记录失败并警告后继续。
    -- 关闭或事务调用可传 requireDurable=true，要求屏障通过。
    S.LastReloadFlushFailure = nil
    if S.Persistence ~= nil and type(S.Persistence.Flush) == "function" then
        local callOk, flushed, failures = pcall(function() return S.Persistence:Flush() end)
        if callOk ~= true or flushed ~= true then
            local detail = nil
            if callOk ~= true then
                detail = tostring(flushed or "Flush exception")
            elseif type(failures) == "table" and #failures > 0 then
                detail = table.concat(failures, "；", 1, math.min(#failures, 2))
                if #failures > 2 then detail = detail .. "；另有 " .. tostring(#failures - 2) .. " 项" end
            else
                detail = tostring(failures or "存在未保存配置")
            end
            S.LastReloadFlushFailure = {
                source = tostring(source or "unknown"),
                detail = tostring(detail or "flush_failed"),
                requireDurable = requireDurable,
            }
            if requireDurable then
                SafeChat("重载已取消：调用方要求全部配置安全落盘。" .. (detail ~= "" and (" " .. detail) or ""))
                return false
            end
            SafeChat("警告：部分配置保存失败，但将继续重新加载文件以便修复故障；本次未保存修改可能丢失。"
                .. (detail ~= "" and (" " .. detail) or ""))
            if type(S.RecordLog) == "function" then
                S.RecordLog("warning", "recovery", "reload continuing after persistence flush failure: " .. tostring(detail or "flush_failed"))
            end
        end
    end

    local current = nil
    if type(X2Option.GetConsoleVariable) == "function" then
        local readOk, value = pcall(function() return X2Option:GetConsoleVariable("r_VSync") end)
        if readOk and value ~= nil then current = tostring(value) end
    end

    -- 先读当前 r_VSync 再产生真实切换；不能另建 OnUpdate 宿主切回，以免第二次刷新再次触发生命周期危险。
    if current == nil then
        SafeChat("重载失败：无法读取客户端界面刷新开关；已取消，避免盲目修改客户端设置。")
        return false
    end

    local normalized = string.lower(current)
    local nextValue = (normalized == "1" or normalized == "1.0" or normalized == "true") and "0" or "1"

    SafeChat("正在重新载入游戏界面与插件文件。")
    local writeOk, writeResult = pcall(function()
        return X2Option:SetConsoleVariable("r_VSync", nextValue)
    end)
    if not writeOk or writeResult == false then
        SafeChat("重载失败：" .. tostring((not writeOk and writeResult) or "SetConsoleVariable returned false"))
        return false
    end
    return true
end
S.ReloadCodeFromDisk = ReloadCodeFromDisk

local function BootstrapNativeAccepted(widget, methodName, ...)
    local method = widget and widget[methodName] or nil
    if type(method) ~= "function" then return false, "method_unavailable:" .. tostring(methodName) end
    local args = { ... }
    local ok, result = pcall(function() return method(widget, unpack(args)) end)
    if ok ~= true then return false, tostring(result or "native_call_failed") end
    if result == false then return false, "native_rejected:" .. tostring(methodName) end
    return true, nil
end

local RECOVERY_BUTTON_SIZE = 30
local RECOVERY_DRAG_MOVE_EPSILON = 2
local RECOVERY_COMMAND_WIDTH = 174
local RECOVERY_COMMAND_HEIGHT = 30
S.RecoveryLauncherContractVersion = 2
S.RecoveryLauncherLogicalSize = RECOVERY_BUTTON_SIZE
S.RecoveryLauncherDragThreshold = RECOVERY_DRAG_MOVE_EPSILON
S.RecoveryCommandContractVersion = 2
S.RecoveryInputIsolationContractVersion = 1

local RecoveryLeftClick

local function NormalizeRecoveryCommand(text)
    text = tostring(text or "")
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    text = text:gsub("^/+", "")
    return string.lower(text)
end

function S.ExecuteRecoveryCommand(text)
    local command = NormalizeRecoveryCommand(text)
    if command == "" then return false, "empty_command" end

    if command == "reload" or command == "rsreload" or command == "rs reload" then
        return ReloadCodeFromDisk("recovery_command")
    end
    if command == "diag" or command == "rsdiag" or command == "rs diag" then
        SafeChat(BootStatusText())
        return true
    end
    if command == "open" or command == "rsopen" or command == "rs open" then
        return RecoveryLeftClick()
    end
    if command == "help" or command == "rshelp" or command == "rs help" then
        SafeChat("RS恢复命令：reload=重载界面/插件，diag=启动诊断，open=打开主界面。")
        return true
    end

    SafeChat("未知RS恢复命令：" .. tostring(command) .. "。可用：reload / diag / open / help")
    return false, "unknown_command"
end

function S.SetRecoveryCommandBarVisible(visible)
    local bar = S.RecoveryCommandBar
    if bar == nil or type(bar.Show) ~= "function" then return false end
    local edit = bar.edit
    local wantVisible = visible == true

    -- RU 隐藏 EditBox 仍可能保留焦点；可见性切换时显式归还，隐藏时关闭 keyboard/focus。
    if edit ~= nil and type(edit.ClearFocus) == "function" then
        pcall(function() edit:ClearFocus() end)
    end
    if edit ~= nil and wantVisible then
        if type(edit.EnableFocus) == "function" then pcall(function() edit:EnableFocus(true) end) end
        if type(edit.EnableKeyboard) == "function" then pcall(function() edit:EnableKeyboard(true) end) end
    end

    -- ArcheAge 原生布尔 setter 可能返回施加后的状态，因此 Show(false) 返回 false 不表示传输失败。
    local ok = pcall(function() bar:Show(wantVisible) end)

    if edit ~= nil then
        if type(edit.ClearFocus) == "function" then pcall(function() edit:ClearFocus() end) end
        if not wantVisible then
            if type(edit.EnableKeyboard) == "function" then pcall(function() edit:EnableKeyboard(false) end) end
            if type(edit.EnableFocus) == "function" then pcall(function() edit:EnableFocus(false) end) end
        end
    end
    return ok == true
end

function S.InstallRecoveryCommandBar()
    S.RecoveryCommandHealthy = false
    S.RecoveryCommandError = nil
    local factory = S.NativeObjectFactory
    if type(factory) ~= "table" or type(factory.CreateWindow) ~= "function" or type(factory.CreateChildByObject) ~= "function" then
        S.RecoveryCommandError = "native factory unavailable"
        return false, S.RecoveryCommandError
    end

    local bar, createErr = factory:CreateWindow(S.PhysicalId("recovery_command_bar"), "UIParent", "")
    if bar == nil then
        S.RecoveryCommandError = tostring(createErr or "recovery command bar create failed")
        return false, S.RecoveryCommandError
    end
    bar.rsUiOwner = "bootstrap:recovery_command"
    bar.rsUiLogicalId = "recovery_command_bar"
    local configured, configureErr = pcall(function()
        if type(bar.SetCloseOnEscape) == "function" then pcall(function() bar:SetCloseOnEscape(false) end) end
        if type(bar.SetWindowModal) == "function" then pcall(function() bar:SetWindowModal(false) end) end
        if type(bar.SetUILayer) == "function" then pcall(function() bar:SetUILayer("system") end) end
        bar:SetExtent(RECOVERY_COMMAND_WIDTH, RECOVERY_COMMAND_HEIGHT)
        if type(bar.RemoveAllAnchors) == "function" then bar:RemoveAllAnchors() end
        bar:AddAnchor("TOPLEFT", "UIParent", 334, 100)
        if type(bar.Enable) == "function" then pcall(function() bar:Enable(true) end) end
        if type(bar.EnablePick) == "function" then pcall(function() bar:EnablePick(true) end) end
        if type(bar.CreateColorDrawable) == "function" then
            local bg = bar:CreateColorDrawable(0.015, 0.022, 0.032, 0.94, "background")
            if bg ~= nil and type(bg.AddAnchor) == "function" then
                bg:AddAnchor("TOPLEFT", bar, 0, 0)
                bg:AddAnchor("BOTTOMRIGHT", bar, 0, 0)
            end
        end
    end)
    if configured ~= true then
        pcall(function() bar:Show(false) end)
        S.RecoveryCommandError = tostring(configureErr or "recovery command bar configure failed")
        return false, S.RecoveryCommandError
    end

    local label = factory:CreateChildByObject(bar, "LABEL", S.PhysicalId("recovery_command_label"), 0, true)
    if label ~= nil then
        pcall(function()
            label:SetExtent(28, 24)
            label:SetText("RS>")
            label:AddAnchor("LEFT", bar, 4, 0)
            label:Show(true)
        end)
        bar.label = label
    end

    local edit = factory:CreateChildByObject(bar, "X2_EDITBOX", S.PhysicalId("recovery_command_edit"), 0, true)
    if edit == nil then edit = factory:CreateChildByObject(bar, "EDITBOX", S.PhysicalId("recovery_command_edit_fallback"), 0, true) end
    if edit == nil then
        pcall(function() bar:Show(false) end)
        S.RecoveryCommandError = "recovery command edit unavailable"
        return false, S.RecoveryCommandError
    end
    if type(edit.ClearFocus) ~= "function" then
        pcall(function() bar:Show(false) end)
        S.RecoveryCommandError = "recovery command ClearFocus unavailable"
        return false, S.RecoveryCommandError
    end
    bar.edit = edit
    local editOk, editErr = pcall(function()
        edit:SetExtent(136, 24)
        if type(edit.SetInset) == "function" then edit:SetInset(5, 5, 5, 5) end
        if type(edit.Enable) == "function" then edit:Enable(true) end
        -- 恢复输入创建时不能短暂启用键盘，RU 即使随后隐藏也可能留住焦点；仅显式显示时激活。
        if type(edit.EnableFocus) == "function" then edit:EnableFocus(false) end
        if type(edit.EnableKeyboard) == "function" then edit:EnableKeyboard(false) end
        if type(edit.EnablePick) == "function" then edit:EnablePick(true) end
        if type(edit.Clickable) == "function" then edit:Clickable(true) end
        if type(edit.SetReClickable) == "function" then edit:SetReClickable(true) end
        if type(edit.SetReadOnly) == "function" then edit:SetReadOnly(false) end
        if type(edit.UseSelectAllWhenFocused) == "function" then edit:UseSelectAllWhenFocused(true) end
        if type(edit.SetMaxTextLength) == "function" then edit:SetMaxTextLength(32) end
        edit:SetText("")
        edit:AddAnchor("LEFT", bar, 32, 0)
        edit:Show(true)
        edit:ClearFocus()
    end)
    if editOk ~= true then
        pcall(function() bar:Show(false) end)
        S.RecoveryCommandError = tostring(editErr or "recovery command edit configure failed")
        return false, S.RecoveryCommandError
    end

    local function SubmitRecoveryCommand()
        local text = ""
        if type(edit.GetText) == "function" then
            local ok, value = pcall(function() return edit:GetText() end)
            if ok == true then text = tostring(value or "") end
        end
        if type(edit.SetText) == "function" then pcall(function() edit:SetText("") end) end
        if type(edit.ClearFocus) == "function" then pcall(function() edit:ClearFocus() end) end
        if NormalizeRecoveryCommand(text) == "" then return true end
        local ok, result, err = pcall(function() return S.ExecuteRecoveryCommand(text) end)
        if ok ~= true then
            SafeChat("RS恢复命令执行失败：" .. tostring(result or "未知错误"))
            return false
        end
        if result ~= true and err ~= "unknown_command" then
            SafeChat("RS恢复命令未完成：" .. tostring(err or "未知原因"))
        end
        return result == true
    end

    -- 恢复输入只用已验证的 OnEnterPressed；不能套用 WoW slash 登记或猜测编辑事件。
    local enterBound = false
    if type(edit.SetHandler) == "function" then
        local ok, result = pcall(edit.SetHandler, edit, "OnEnterPressed", SubmitRecoveryCommand)
        enterBound = ok == true and result ~= false
    end
    if enterBound ~= true then
        pcall(function() bar:Show(false) end)
        S.RecoveryCommandError = "recovery command enter handler unavailable"
        return false, S.RecoveryCommandError
    end

    S.RecoveryCommandBar = bar
    S.RecoveryCommandHealthy = true
    S.RecoveryCommandError = nil
    -- 正常 bootstrap 不激活键盘；运行失败可稍后显式展示应急输入，但成功启动不能暴露任何短暂启用键盘的 EditBox。
    S.SetRecoveryCommandBarVisible(false)
    return true
end

local function ReadRecoveryPosition(button, pinnedScale)
    -- 恢复入口使用统一 logical 校准；手势冻结单位，禁止无条件 / uiScale。
    if button == nil then return nil, nil end
    if S.Layout ~= nil and type(S.Layout.GetWindowLogicalRect) == "function" then
        local ok, x, y = pcall(function()
            local px, py = S.Layout:GetWindowLogicalRect(button, pinnedScale)
            return px, py
        end)
        if ok == true and tonumber(x) ~= nil and tonumber(y) ~= nil then return tonumber(x), tonumber(y) end
    end
    if type(button.GetEffectiveOffset) == "function" then
        local ok, x, y = pcall(function() return button:GetEffectiveOffset() end)
        if ok == true and tonumber(x) ~= nil and tonumber(y) ~= nil then return tonumber(x), tonumber(y) end
    end
    if type(button.GetOffset) == "function" then
        local ok, x, y = pcall(function() return button:GetOffset() end)
        if ok == true and tonumber(x) ~= nil and tonumber(y) ~= nil then return tonumber(x), tonumber(y) end
    end
    return nil, nil
end

local function CreateBootstrapRecoveryEntry()
    local factory = S.NativeObjectFactory
    if type(factory) ~= "table" or type(factory.CreateButton) ~= "function" then return nil end
    local button, createErr = factory:CreateButton(S.PhysicalId("recovery_entry"), "UIParent", "")
    if button == nil then
        SafeChat("恢复入口创建失败：" .. tostring(createErr or "未知错误"))
        return nil
    end
    local configured, configureErr = pcall(function()
        button:SetText("R")
        if type(button.SetStyle) == "function" then pcall(function() button:SetStyle("text_default") end) end
        -- RU 原生 Button 自动尺寸可能把单字启动器撑回样式最小文本宽度；强制紧凑恢复尺寸前先禁用自动缩放，与
        -- Theme:StyleButton 一致。
        if type(button.SetAutoResize) == "function" then pcall(function() button:SetAutoResize(false) end) end
        if type(button.SetExtent) == "function" then button:SetExtent(RECOVERY_BUTTON_SIZE, RECOVERY_BUTTON_SIZE) end
        if type(button.SetWidth) == "function" then pcall(function() button:SetWidth(RECOVERY_BUTTON_SIZE) end) end
        if type(button.SetHeight) == "function" then pcall(function() button:SetHeight(RECOVERY_BUTTON_SIZE) end) end
        if type(button.RemoveAllAnchors) == "function" then button:RemoveAllAnchors() end
        button:AddAnchor("TOPLEFT", "UIParent", 300, 100)
        if type(button.Enable) == "function" then
            local ok, err = BootstrapNativeAccepted(button, "Enable", true); if ok ~= true then error(err) end
        end
        if type(button.EnablePick) == "function" then
            local ok, err = BootstrapNativeAccepted(button, "EnablePick", true); if ok ~= true then error(err) end
        end
        if type(button.Clickable) == "function" then
            local ok, err = BootstrapNativeAccepted(button, "Clickable", true); if ok ~= true then error(err) end
        end
        local showOk, showErr = BootstrapNativeAccepted(button, "Show", true); if showOk ~= true then error(showErr) end
    end)
    if configured ~= true then
        SafeChat("恢复入口配置失败：" .. tostring(configureErr or "未知错误"))
        pcall(function() button:Show(false) end)
        return nil
    end
    return button
end

RecoveryLeftClick = function()
    local button = S.RecoveryEntry
    if button ~= nil and button.rsIgnoreClick == true then
        button.rsIgnoreClick = false
        return true
    end
    if S.Ready == true and S.UIHostManager ~= nil and type(S.UIHostManager.Toggle) == "function" then
        if S.Runtime ~= nil and S.Runtime.escRegistered ~= true and type(S.Runtime.RegisterEscMenu) == "function" then
            pcall(function() S.Runtime:RegisterEscMenu("recovery_click") end)
        end
        local ok, err = S.UIHostManager:Toggle()
        if ok == true then return true end
        SafeChat("新版主界面打开失败：" .. tostring(err or "未知错误"))
        return false
    end
    SafeChat("插件尚未就绪；" .. BootStatusText())
    return false
end

local function RecoveryRightClick()
    -- 显式应急或开发入口；左键只负责启动。
    return ReloadCodeFromDisk("recovery")
end

local function InstallRecoveryHandlers(button)
    if button == nil or type(button.SetHandler) ~= "function" then return false end
    if type(button.EnableDrag) == "function" then
        local dragOk, dragResult = pcall(function() return button:EnableDrag(true) end)
        if dragOk ~= true or dragResult == false then SafeChat("恢复入口拖动能力启用失败。") end
        -- 部分 RU WidgetBase/Button 需要显式拖动条件，仅 EnableDrag 可能无法触达 OnDragStart。
        if dragOk == true and dragResult ~= false and type(button.SetDragCondition) == "function" and DC_ALWAYS ~= nil then
            local conditionOk, conditionResult = pcall(function() return button:SetDragCondition(DC_ALWAYS) end)
            if conditionOk ~= true or conditionResult == false then SafeChat("恢复入口拖动条件启用失败。") end
        end
    end
    local leftOk, leftResult = pcall(button.SetHandler, button, "OnClick", RecoveryLeftClick)
    local rightOk, rightResult = pcall(button.SetHandler, button, "OnRButtonUp", RecoveryRightClick)
    local dragStartOk, dragStartResult = pcall(button.SetHandler, button, "OnDragStart", function()
        if S.UIV3 and S.UIV3.LauncherState and S.UIV3.LauncherState.locked == true then return false end -- Launcher 偏好晚加载；锁定不能阻断左右键恢复动作。
        if type(button.StartMoving) ~= "function" then return false end
        -- 早期 Bootstrap 不依赖 V3；可用时仅在开始读一次单位与 viewport 身份。
        if S.Layout and type(S.Layout.GetWindowLogicalRect)=="function" then
            local _,_,_,_,unit=S.Layout:GetWindowLogicalRect(button)
            button.rsGeometryUnitScale=unit and unit.effectiveScale or nil
            button.rsDragViewport=S.Layout:MakeSignature(S.Layout:GetContext())
        end
        button.rsDragStartX, button.rsDragStartY = ReadRecoveryPosition(button,button.rsGeometryUnitScale)
        local ok, result = pcall(function() return button:StartMoving() end)
        button.rsMoving = ok == true and result ~= false
        return button.rsMoving
    end)
    local dragStopOk, dragStopResult = pcall(button.SetHandler, button, "OnDragStop", function()
        -- Reset 取消后迟到 DragStop 没有写权限，不再次保存旧坐标。
        if button.rsMoving~=true then return true end
        if type(button.StopMovingOrSizing)=="function" then pcall(button.StopMovingOrSizing,button) end
        local endX,endY=ReadRecoveryPosition(button,button.rsGeometryUnitScale)
        local startX,startY=tonumber(button.rsDragStartX),tonumber(button.rsDragStartY)
        local moved=startX~=nil and startY~=nil and endX~=nil and endY~=nil
            and (math.abs(endX-startX)>RECOVERY_DRAG_MOVE_EPSILON or math.abs(endY-startY)>RECOVERY_DRAG_MOVE_EPSILON)
        button.rsMoving=false;button.rsDragStartX,button.rsDragStartY,button.rsGeometryUnitScale=nil,nil,nil
        button.rsIgnoreClick=moved==true
        local L,V=S.Layout,S.UIV3
        if moved and L and type(L.StorePlacementRect)=="function" and V and type(V.LauncherState)=="table" then
            local live=L:GetContext(true)
            local changed=button.rsDragViewport~=nil and button.rsDragViewport~=L:MakeSignature(live)
            button.rsDragViewport=nil
            if changed then return V:ApplyLauncherPlacement() end
            local x,y=endX,endY
            if type(L.ResolveScreenSnap)=="function" then
                local sx,sy,snapped=L:ResolveScreenSnap("v3_launcher",x,y,RECOVERY_BUTTON_SIZE,RECOVERY_BUTTON_SIZE,
                    {enabled=true,group="screen_buttons",kind="button",distance=16,gap=0})
                if snapped then x,y=sx,sy end
            end
            -- 只提交已冻结的逻辑矩形，Native 接受后再保存；不能重读 GetLogicalRect 造成二次缩放。
            local candidate={userMoved=true}
            x,y=L:StorePlacementRect(candidate,x,y,RECOVERY_BUTTON_SIZE,RECOVERY_BUTTON_SIZE,{mode="strict"})
            local windowing=S.RSUI and S.RSUI.Windowing
            local accepted,err
            if windowing and type(windowing.ApplyGeometry)=="function" then
                accepted,err=windowing:ApplyGeometry(button,"v3:launcher",x,y,RECOVERY_BUTTON_SIZE,RECOVERY_BUTTON_SIZE,true)
            else
                accepted,err=pcall(function()
                    if button:RemoveAllAnchors()==false then error("launcher_anchor_clear_rejected") end
                    if button:AddAnchor("TOPLEFT","UIParent",x,y)==false then error("launcher_anchor_rejected") end
                end)
            end
            if accepted~=true then return false,err end
            local before={};for k,v in pairs(V.LauncherState)do before[k]=v;V.LauncherState[k]=nil end
            for k,v in pairs(candidate)do V.LauncherState[k]=v end
            if type(V.MarkLauncherStoreDirty)=="function" then
                local called,saved,saveErr=pcall(V.MarkLauncherStoreDirty,V,0,"launcher_drag")
                if not called or saved==false then
                    for k in pairs(V.LauncherState)do V.LauncherState[k]=nil end
                    for k,v in pairs(before)do V.LauncherState[k]=v end
                    if type(V.ApplyLauncherPlacement)=="function" then V:ApplyLauncherPlacement() end
                    return false,called and saveErr or saved
                end
            end
        end
        return true
    end)
    local leftBound = leftOk and leftResult ~= false
    local rightBound = rightOk and rightResult ~= false
    if not leftBound then SafeChat("恢复入口左键绑定失败：" .. tostring(leftOk and "回调绑定被客户端拒绝" or leftResult)) end
    if not rightBound then SafeChat("恢复入口右键重载不可用：" .. tostring(rightOk and "回调绑定被客户端拒绝" or rightResult)) end
    local dragStartBound = dragStartOk and dragStartResult ~= false
    local dragStopBound = dragStopOk and dragStopResult ~= false
    if not dragStartBound or not dragStopBound then SafeChat("恢复入口拖动绑定不可用。") end
    -- 左键是最小恢复路径；右键重载仅为可选开发便利，不能使启动器自身失败。
    return leftBound
end

function S.ActivateRecoveryEntry()
    local button = S.RecoveryEntry
    if button == nil then return false end
    local handlerOk = InstallRecoveryHandlers(button)
    local stateOk, stateErr = pcall(function()
        button:SetText("R")
        if type(button.Enable) == "function" then
            local ok, err = BootstrapNativeAccepted(button, "Enable", true); if ok ~= true then error(err) end
        end
        if type(button.EnablePick) == "function" then
            local ok, err = BootstrapNativeAccepted(button, "EnablePick", true); if ok ~= true then error(err) end
        end
        if type(button.Clickable) == "function" then
            local ok, err = BootstrapNativeAccepted(button, "Clickable", true); if ok ~= true then error(err) end
        end
        local showOk, showErr = BootstrapNativeAccepted(button, "Show", true); if showOk ~= true then error(showErr) end
    end)
    if stateOk ~= true then
        S.RecoveryEntryHealthy = false
        S.RecoveryEntryError = tostring(stateErr or "recovery state restore failed")
        SafeChat("恢复入口交互状态恢复失败：" .. tostring(stateErr or "未知错误"))
        return false
    end
    if handlerOk ~= true then
        S.RecoveryEntryHealthy = false
        S.RecoveryEntryError = "recovery left-click binding unavailable"
        return false
    end
    S.RecoveryEntryHealthy = true
    S.RecoveryEntryError = nil
    return true
end

function S.InstallBootstrapRecoveryEntry()
    S.RecoveryEntryHealthy = false
    S.RecoveryEntryError = nil
    if S.RecoveryEntry ~= nil and type(S.RecoveryEntry.Show) == "function" then
        pcall(function() S.RecoveryEntry:Show(false) end)
    end
    S.RecoveryEntry = CreateBootstrapRecoveryEntry()
    if S.RecoveryEntry == nil then
        S.RecoveryEntryError = "recovery entry unavailable"
        return false, S.RecoveryEntryError
    end
    local handlerOk = InstallRecoveryHandlers(S.RecoveryEntry)
    if handlerOk ~= true then
        S.RecoveryEntryError = "recovery left-click binding unavailable"
        return false, S.RecoveryEntryError
    end
    S.RecoveryEntryHealthy = true
    return true
end

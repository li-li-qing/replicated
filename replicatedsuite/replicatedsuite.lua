------------------------------------------------------------------------
-- Replicated Suite · 插件引导入口
-- 作者：Replicated
-- QQ群：1104129461
--
-- 插件引导入口；当前构建标识由下方 BuildTag 声明。
------------------------------------------------------------------------
ReplicatedSuite = ReplicatedSuite or {}
local S = ReplicatedSuite

-- V3 重建是唯一活动应用架构；旧 Legacy/Professional 源码与 globals 树已物理删除，不是运行依赖，也不能通过
-- bootstrap 重新引入。
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
-- ReloadAddon 成功后可能保留全局 ReplicatedSuite 表并重新执行 bootstrap。不能继承旧代际 pending gate 或
-- detached reload host，否则一次成功循环后下次开发重载可能永久阻断。
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
S.BuildTag = "v3-m1.16.0.18.332-phase2-life-bundle-slice-complete" -- 当前构建标签。
-- 生活领域按 Treasure/Fishing/Bonds/Trade 分为独立 Feature；共享装配归
-- features/life/shared/rs_life_slice_factory.lua，与 features/shared/rs_feature_slice_factory.lua
-- 的业务装配语义不同，不能强行合并。跨 Feature 有界常量归 rs_shared_bounds.lua，拍卖读模型共享。
-- 每个 Feature 在 toc.g 仅登记一次；不能恢复已退役 rs_life_m16_bundle.lua 或 rs_business_bridge.lua。
-- 进一步拆分 Trade 的货率/材料投影/报价/缓存/诊断须先完成 RU 实机 Fresh Reload、旧配置、自动刷新、
-- 报价和材料缓存验收。拆分不能改 Store ID/schema、Feature ID/route、Commands、Projection 形状、
-- Scheduler 任务名、Event topic 或用户配置语义；源码合并先查完整清单和冲突，不能清配置绕过。
-- 2026-09-28 历史结构验证：生活拆分 Install/Lua5.1 为 282，Full Runner 为 0 FAIL，
-- feature-split 通过，Native audit 0/0/0，Architecture 47；业务拆分 Install/Lua5.1 为 278，
-- Full Runner 为 0 FAIL，feature-split 59/59，Native audit 0/0/0，Architecture 48。
-- 原业务 chunk 局部槽由 188 降至 104；这些是当时证据，不代替当前版本或实机验收。
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
-- 旧 Presentation/Widget 入口在 V3 仅作参考；ArcheRage 可跨 UI 重载保留 ReplicatedSuite 根表，因此须显式清
-- 除跨代际 Lua 引用。原生实例已由上方 previousRuntime/previousUI 静止过程隐藏。
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

-- 代际内唯一有界诊断日志汇集每条 Suite 聊天通知和 DiagnosticsManager 记录，使用户能打印一条易复制消息，不需
-- 收集分散聊天行。长时间 MMO 会话也不能因诊断启用而增长无界 Lua 表。
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
    -- 早期/运行时 warning/error 通过同一日志入口交给
    -- Diagnostics 的有界错误环，避免 200 条 info 把原始异常挤掉。先验证 generation，
    -- 防热重载把新错误投到旧 manager；仅错误路径受保护调用，不新增 Tick/持久化。
    -- Diagnostics 不反写 RecordLog，因此不递归；采集失败只计数，原日志仍保留。
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

-- 运行调度绝不依赖 UI:GetCurrentTimeStamp()。Replicated Gear 的 RU 证据表明 API 可存在但在插件执行中冻结；
-- OnUpdate 拥有的单调时钟才是 debounce、timeout、timer 的唯一时间权威。
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
    -- WarnOnce 原来走默认 info，保存/后台任务故障无法进入错误历史；只补充已有
    -- warning 语义，不推断普通聊天是错误，不改变 once 去重或业务控制流。
    SafeChat(message, "warning", "suite.warn_once")
end

-- 原生控件名称不能承载长逻辑路径；M1.14 RU 日志证实长语义路径参与重复登记失败，客户端未公开安全长度契约，也
-- 可能内部归一化或截断，给长路径追加代际尾缀仍不够。RSUI 逻辑 ID 保持可读，投影为有界不透明原生身份；完整代
-- 际加代际内序号避免热重载别名，不为每层花费 23 字节。反向映射仅作诊断，业务或表现不能依赖物理值。
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
    -- 2026-10-06：实机重复警告的深层路径全部显示为259字节。单节23字节的旧策略
    -- 没有控制祖先路径累加。使用当前 generation + 唯一递增序号，普通节点约5..8字节。
    -- 逻辑ID/窗口Store/owner不变，不重设父级；只在新建时分配，反向映射继续供诊断使用。
    -- 259是观察到的日志边界，不宣称已验证Native内部上限；截断模型及实机回归分开。
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

-- 原生对象和 API 在本 bootstrap 后由 replicatedsuite/native/* 导入；bootstrap 不消费旧 globals，也不拥有客
-- 户端 ABI 常量。恢复 R 按钮在引导中直接创建，因为 toc 最后加载 rs_runtime.lua，中间模块语法或运行错误也必
-- 须留下游戏内重载入口。运行体成功后接管同一控件并升级为正常主题启动器。
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

-- 显式开发 UI/插件文件重载的唯一“载”入口须遵守原生生命周期：不能从待重载插件自有 Widget 回调直接调用
-- ADDON:ReloadAddon()，也不能经插件自有 OnUpdate 延后调用。2026-08-15 实机崩溃证实 ReloadAddon 会在
-- rs_code_reload_host 原生 dispatcher 仍在栈上时销毁宿主，Lua 返回后仍发生 EXCEPTION_ACCESS_VIOLATION。此显
-- 式按钮路径采用已验证 uirefresh 的直接 r_VSync 切换，触发加载屏 UI 刷新和文件重读，不创建会自毁的回调所有
-- 者。
S.RecoveryReloadContractVersion = 1
S.LastReloadFlushFailure = nil

local function ReloadCodeFromDisk(source, options)
    options = type(options) == "table" and options or {}
    local requireDurable = options.requireDurable == true

    if X2Option == nil or type(X2Option.SetConsoleVariable) ~= "function" then
        SafeChat("重载失败：游戏界面刷新接口不可用。")
        return false
    end

    -- 重载是替换磁盘文件后的开发或恢复出口。Persistence 尽力完成耐久屏障，但损坏 Store 不能锁死唯一能加载修
    -- 复的路径。调用者可显式 requireDurable=true 要求严格耐久（如关闭或事务流程）；恢复重载记录精确失败证据
    -- ，并明显警告数据丢失后继续。
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

    -- 显式动作沿用已验证 ArcheRage uirefresh 原语；读取当前值后产生真实边沿，不猜写入是否忽略。不创建恢复
    -- OnUpdate 宿主，因为切回该变量会触发第二次 UI 刷新并重新引入原生生命周期危险。
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

    -- 恢复输入是应急表面，不拥有常驻键盘权威。RU 隐藏 EditBox 可保留焦点，每次可见性转换须显式归还焦点；隐
    -- 藏时同时关闭 keyboard/focus 输入。
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
        -- 恢复输入创建时必须惰性；即使几帧后隐藏，曾启用 keyboard 的 RU EditBox 也可能保留键盘所有权。
        -- bootstrap 不能短暂启用 keyboard/focus，只有 SetRecoveryCommandBarVisible(true) 可激活。
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

    -- ArcheAge 客户端脚本已验证 editbox 的 OnEnterPressed；不能捏造 WoW 式 slash 登记表或未验证编辑事件，恢
    -- 复输入须限定已知 RU ABI。
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
        if S.UIV3 and S.UIV3.LauncherState and S.UIV3.LauncherState.locked == true then return false end -- 晚加载的 Launcher 偏好保护 Bootstrap 入口，锁定仍保留左右键
                                                                                                         -- 恢复动作。
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
            -- 唯一提交逻辑矩形 -> 临时边缘意图 -> Native 接受 -> 原 Store。不能再
            -- StorePlacement/GetLogicalRect 重读，否则 RU 已是逻辑单位的 effective 值会重复除缩放。
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

------------------------------------------------------------------------
-- Replicated Suite - Bootstrap
-- Author: Replicated
-- Version: 1.2 (V3-only; current BuildTag is declared below)
------------------------------------------------------------------------
ReplicatedSuite = ReplicatedSuite or {}
local S = ReplicatedSuite

-- V3 rebuild is the only active application architecture. Legacy / Professional
-- source and the old globals tree have been physically removed; they are not
-- runtime dependencies and must not be reintroduced through bootstrap.
S.ArchitectureMode = "v3_rebuild"

-- Preserve a lightweight process-time baseline before the TOC continues loading
-- the V3 runtime. It is diagnostic-only and never persisted.
local bootOs = rawget(_G, "os")
local bootNow = nil
if type(bootOs) == "table" and type(bootOs.clock) == "function" then
    local ok, value = pcall(bootOs.clock)
    if ok and type(value) == "number" then bootNow = value * 1000 end
end
S.BootLoadStartedAt = bootNow

-- Quiesce the previous hot-reload generation before replacing references.
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
        -- A hidden RU EditBox may retain keyboard focus across addon reloads.
        -- Always return focus before releasing handlers/hiding the old generation.
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
-- A successful ReloadAddon may preserve the global ReplicatedSuite table while
-- re-executing bootstrap. Never inherit the previous generation's pending gate
-- or detached reload host, otherwise the next developer reload could stay
-- permanently blocked after one successful cycle.
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
-- Audit5 used an r_VSync toggle as a supposed "safe UI refresh" edge.
-- RU ArcheRage proves that changing this restricted console variable can trigger
-- a real UI reload. Never touch it from Suite bootstrap/recovery again. Detach
-- any stale helper callback from an older generation, but deliberately do not
-- write the console variable while recovering.
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
S.BuildTag = "v3-m1.16.0.18.145-numeric-apply-adaptive-point-size"
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
-- Legacy Presentation/Widget entry points are reference-only in V3 rebuild.
-- Explicitly clear cross-generation Lua references because ArcheRage may keep
-- the ReplicatedSuite root table alive across UI reloads. Native instances were
-- already hidden by previousRuntime/previousUI quiescence above.
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

-- One bounded, generation-local diagnostic log Authority.  Every Suite chat
-- notice and every DiagnosticsManager record is mirrored here so the user can
-- print one copy-friendly diagnostic message instead of collecting many
-- scattered chat rows.  Keep it bounded: long MMO sessions must not grow an
-- unbounded Lua table merely because diagnostics are enabled.
S.LogBuffer = {}
S.LogSequence = 0
S.LogDropped = 0
S.LogBufferMax = 200

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

-- Runtime scheduling must never depend on UI:GetCurrentTimeStamp().  The same
-- RU client issue was already proven in Replicated Gear: the API can exist but
-- remain frozen inside Addon execution.  One OnUpdate-owned monotonic clock is
-- therefore the only timing Authority for Suite debounce, timeout and timers.
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
    SafeChat(message)
end

-- ArcheAge native widget names are not a safe place for long logical paths.
-- The M1.14 RU log proves that long semantic native paths participated in
-- duplicate-registration failures; the client does not expose a documented
-- safe name-length contract to addons.  Treat the physical name as a bounded,
-- opaque identity instead of assuming an unbounded logical path is safe.  A
-- generation suffix at the end of the old path is also insufficient because
-- native identity must remain distinct even when the client normalizes/truncates
-- names internally.
--
-- Keep logical IDs readable in RSUI, but project them to a compact deterministic
-- native identity.  Generation participates in both the visible token and the
-- hash so hot reloads cannot alias a previous native generation.  The reverse
-- map is diagnostic-only; business/presentation code must never depend on the
-- physical value.
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

local function IdentityHash(text, multiplier, seed, modulus)
    text = tostring(text or "")
    local hash = tonumber(seed) or 17
    local mul = tonumber(multiplier) or 131
    local mod = tonumber(modulus) or 2147483647
    for index = 1, #text do
        -- All intermediate integers stay far below IEEE-754's exact-integer
        -- ceiling, so this is deterministic on the client's number-only Lua.
        hash = (hash * mul + string.byte(text, index) + index) % mod
    end
    return math.floor(hash)
end

local function IdentityHint(logicalId)
    local clean = tostring(logicalId or "widget"):lower():gsub("[^%w_]+", "_")
    local tail = clean:match("([%w]+)$") or clean
    if tail == "" then tail = "widget" end
    return tail:sub(1, 5)
end

S.NativeIdentity = {
    version = 2,
    maxPhysicalLength = 23,
    logicalToPhysical = {},
    physicalToLogical = {},
    requests = 0,
    collisions = 0,
    maxObservedLength = 0,
}

function S.NativeIdentity:Build(logicalId, generation, collisionSalt)
    local logical = tostring(logicalId or "widget")
    local gen = math.max(0, math.floor(tonumber(generation) or 0))
    local salt = math.max(0, math.floor(tonumber(collisionSalt) or 0))
    local source = logical .. "#g" .. tostring(gen) .. (salt > 0 and ("#c" .. tostring(salt)) or "")
    local genToken = Base36(gen % 1296, 2)
    local hint = IdentityHint(logical)
    local h1 = Base36(IdentityHash(source, 131, 17, 2147483647), 6)
    local h2 = Base36(IdentityHash(source, 137, 53, 2147483629), 6)
    local physical = "rs" .. genToken .. "_" .. hint .. "_" .. h1 .. h2
    -- Defensive assertion kept local instead of throwing through bootstrap.
    if #physical > self.maxPhysicalLength then
        physical = physical:sub(1, self.maxPhysicalLength)
    end
    return physical
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
        -- Practically unreachable with two independent 31-bit hashes.  Fail
        -- deterministically rather than falling back to the unsafe long ID.
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

-- Native objects and APIs are imported by replicatedsuite/native/* immediately
-- after this bootstrap file. Bootstrap itself intentionally consumes no legacy
-- globals and owns no client ABI constants.

------------------------------------------------------------------------
-- Bootstrap recovery entry
--
-- This button is deliberately created in the bootstrap file instead of the
-- normal UI factory.  The toc loads rs_runtime.lua last, so a syntax/runtime
-- error in any intermediate module used to leave the player with no "R" entry
-- and therefore no in-game way to trigger the Suite reload command.  The
-- bootstrap entry survives that partial-load state.  A successful runtime
-- later adopts the same widget and upgrades it to the normal themed launcher.
------------------------------------------------------------------------
local externalRecovery = rawget(_G, "ReplicatedSuiteRecovery")
if type(externalRecovery) == "table" and externalRecovery.button ~= nil and type(externalRecovery.button.Show) == "function" then
    pcall(function() externalRecovery.button:Show(false) end)
end
-- v0.3.23 created a second pre-bootstrap recovery owner. It is no longer part
-- of toc.g; release the stale generation so only the bootstrap-owned R remains.
ReplicatedSuiteRecovery = nil
local function BootStatusText()
    local stage = tostring(S.BootStage or "bootstrap")
    local err = S.BootError ~= nil and tostring(S.BootError) or "插件尚未完成初始化"
    return "阶段=" .. stage
        .. "；R=" .. tostring(S.RecoveryEntryHealthy == true)
        .. "；CMD=" .. tostring(S.RecoveryCommandHealthy == true)
        .. "；" .. err
end

-- Backward-compatible function name retained because the settings page in older
-- hot-reload generations may still reference it. It no longer reloads the addon,
-- toggles VSync, or writes any client console variable. This is a Suite-internal
-- data/layout refresh only.
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

------------------------------------------------------------------------
-- Explicit developer UI / addon-file reload
--
-- IMPORTANT NATIVE LIFETIME RULE:
-- Never call ADDON:ReloadAddon() from a widget callback owned by the addon
-- being reloaded, and never defer it through an addon-owned OnUpdate host.
-- The 2026-08-15 live crash proved that ReloadAddon can destroy that host while
-- its native OnUpdate dispatcher is still on the stack (rs_code_reload_host),
-- causing an EXCEPTION_ACCESS_VIOLATION after Lua has already returned control.
--
-- ArcheRage's established uirefresh path toggles r_VSync directly from the
-- explicit button callback. That produces the loading-screen UI refresh and
-- rereads addon files without constructing a self-destructing callback owner.
-- This function is therefore the single explicit "载" Authority.
------------------------------------------------------------------------
S.RecoveryReloadContractVersion = 1
S.LastReloadFlushFailure = nil

local function ReloadCodeFromDisk(source, options)
    options = type(options) == "table" and options or {}
    local requireDurable = options.requireDurable == true

    if X2Option == nil or type(X2Option.SetConsoleVariable) ~= "function" then
        SafeChat("重载失败：游戏界面刷新接口不可用。")
        return false
    end

    -- Reload is first and foremost the developer/recovery escape hatch used
    -- after files on disk have been replaced. Persistence therefore performs a
    -- best-effort durability barrier, but a broken Store must never deadlock the
    -- only path capable of loading the fix for that Store. Strict durability is
    -- still available to callers that explicitly set requireDurable=true (for
    -- example shutdown/transactional flows); recovery reload records the exact
    -- failure evidence and continues with a loud data-loss warning.
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

    -- Match the proven ArcheRage uirefresh primitive. A readable current value
    -- lets us always create a real edge instead of guessing whether the write
    -- will be ignored. We intentionally do not create a restore OnUpdate host:
    -- changing this variable back would trigger a second UI refresh and recreate
    -- the exact native lifetime hazard this hotfix removes.
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

    -- Recovery input is a break-glass surface, never a keyboard Authority.
    -- RU may keep focus on a hidden EditBox, so every visibility transition
    -- explicitly returns focus. Hidden state also disables keyboard/focus input.
    if edit ~= nil and type(edit.ClearFocus) == "function" then
        pcall(function() edit:ClearFocus() end)
    end
    if edit ~= nil and wantVisible then
        if type(edit.EnableFocus) == "function" then pcall(function() edit:EnableFocus(true) end) end
        if type(edit.EnableKeyboard) == "function" then pcall(function() edit:EnableKeyboard(true) end) end
    end

    -- ArcheAge boolean native setters may return the state being applied.
    -- Therefore Show(false) returning false is not a transport failure.
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
        -- Recovery input must be born inert. RU can retain keyboard ownership
        -- from an EditBox that was keyboard-enabled even if it is hidden a few
        -- frames later, so bootstrap must never briefly enable keyboard/focus.
        -- SetRecoveryCommandBarVisible(true) is the only authority that arms it.
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

    -- OnEnterPressed is verified in the ArcheAge client scripts for editboxes.
    -- Do not invent/fallback to WoW-style slash registries or unverified edit
    -- events: this bootstrap recovery surface must remain inside known RU ABI.
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
    -- Normal bootstrap is intentionally keyboard-inert. Runtime failure may
    -- explicitly reveal this break-glass input later, but successful startup
    -- must never expose even a transient keyboard-enabled EditBox.
    S.SetRecoveryCommandBarVisible(false)
    return true
end

local function ReadRecoveryPosition(button)
    if button == nil then return nil, nil end
    if S.Layout ~= nil and type(S.Layout.GetLogicalRect) == "function" then
        local ok, x, y = pcall(function()
            local px, py = S.Layout:GetLogicalRect(button)
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
        -- Native Button auto-resize can re-expand a one-letter launcher to the
        -- style's minimum text footprint on RU. Disable it before forcing the
        -- compact recovery extent, matching Theme:StyleButton's size discipline.
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
    -- Explicit emergency/developer path.  Left click remains a pure launcher.
    return ReloadCodeFromDisk("recovery")
end

local function InstallRecoveryHandlers(button)
    if button == nil or type(button.SetHandler) ~= "function" then return false end
    if type(button.EnableDrag) == "function" then
        local dragOk, dragResult = pcall(function() return button:EnableDrag(true) end)
        if dragOk ~= true or dragResult == false then SafeChat("恢复入口拖动能力启用失败。") end
        -- RU requires an explicit drag condition on some WidgetBase/Button
        -- implementations; EnableDrag alone can leave OnDragStart unreachable.
        if dragOk == true and dragResult ~= false and type(button.SetDragCondition) == "function" and DC_ALWAYS ~= nil then
            local conditionOk, conditionResult = pcall(function() return button:SetDragCondition(DC_ALWAYS) end)
            if conditionOk ~= true or conditionResult == false then SafeChat("恢复入口拖动条件启用失败。") end
        end
    end
    local leftOk, leftResult = pcall(button.SetHandler, button, "OnClick", RecoveryLeftClick)
    local rightOk, rightResult = pcall(button.SetHandler, button, "OnRButtonUp", RecoveryRightClick)
    local dragStartOk, dragStartResult = pcall(button.SetHandler, button, "OnDragStart", function()
        if type(button.StartMoving) ~= "function" then return false end
        button.rsDragStartX, button.rsDragStartY = ReadRecoveryPosition(button)
        local ok, result = pcall(function() return button:StartMoving() end)
        button.rsMoving = ok == true and result ~= false
        return button.rsMoving
    end)
    local dragStopOk, dragStopResult = pcall(button.SetHandler, button, "OnDragStop", function()
        if button.rsMoving == true and type(button.StopMovingOrSizing) == "function" then pcall(function() button:StopMovingOrSizing() end) end
        local endX, endY = ReadRecoveryPosition(button)
        local startX, startY = tonumber(button.rsDragStartX), tonumber(button.rsDragStartY)
        local moved = startX ~= nil and startY ~= nil and endX ~= nil and endY ~= nil
            and (math.abs(endX - startX) > RECOVERY_DRAG_MOVE_EPSILON or math.abs(endY - startY) > RECOVERY_DRAG_MOVE_EPSILON)
        button.rsMoving = false
        button.rsDragStartX, button.rsDragStartY = nil, nil
        -- Some RU builds emit DragStart/DragStop even for a normal click. Suppress
        -- the following OnClick only when geometry actually moved; otherwise the
        -- recovery launcher would consume every click forever.
        button.rsIgnoreClick = moved == true
        if moved == true and S.Layout ~= nil and type(S.Layout.StorePlacement) == "function" and S.UIV3 ~= nil and type(S.UIV3.LauncherState) == "table" then
            -- The launcher participates in the same framework-owned screen-button
            -- snap group as Gear and future floating buttons.  Snap is resolved
            -- once at drag stop; there is no Tick/mouse polling.
            if S.UI ~= nil and type(S.UI.CommitScreenSnap) == "function" then
                S.UI:CommitScreenSnap("v3_launcher", button, {
                    enabled = true, group = "screen_buttons", kind = "button", distance = 16, gap = 0, owner = "v3:launcher_snap",
                })
            elseif type(S.Layout.ResolveScreenSnap) == "function" and type(S.Layout.GetLogicalRect) == "function" then
                local currentX, currentY, currentW, currentH = S.Layout:GetLogicalRect(button)
                local snapX, snapY, snapped = S.Layout:ResolveScreenSnap("v3_launcher", currentX, currentY, currentW, currentH, {
                    enabled = true, group = "screen_buttons", kind = "button", distance = 16, gap = 0,
                })
                if snapped == true and tonumber(snapX) ~= nil and tonumber(snapY) ~= nil then
                    if type(button.RemoveAllAnchors) == "function" then button:RemoveAllAnchors() end
                    button:AddAnchor("TOPLEFT", "UIParent", snapX, snapY)
                end
            end
            local _, _, width, height = S.Layout:GetLogicalRect(button)
            local x, y = S.Layout:StorePlacement(S.UIV3.LauncherState, button, {
                mode = "free",
            })
            S.UIV3.LauncherState.userMoved = true
            if tonumber(x) ~= nil and tonumber(y) ~= nil then
                if type(button.RemoveAllAnchors) == "function" then button:RemoveAllAnchors() end
                button:AddAnchor("TOPLEFT", "UIParent", x, y)
            end
            if type(S.UIV3.MarkLauncherStoreDirty) == "function" then pcall(function() S.UIV3:MarkLauncherStoreDirty(150, "launcher_drag") end) end
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
    -- Left click is the minimum viable recovery path; right-click reload is an
    -- optional developer convenience and must not make the launcher itself fail.
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

------------------------------------------------------------------------
-- Replicated Suite - Bootstrap
-- Author: Replicated
-- Version: 1.2 (正式版; development string: 1.2.0-architecture-v1.1-daily-trade-favorites)
------------------------------------------------------------------------
ReplicatedSuite = ReplicatedSuite or {}
local S = ReplicatedSuite

-- Preserve a lightweight process-time baseline before the TOC starts loading
-- the large professional modules. It is diagnostic-only and never persisted.
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
if type(previousUI) == "table" and type(previousUI.HideAll) == "function" then
    pcall(function() previousUI:HideAll() end)
end
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
S.Generation = (tonumber(S.Generation) or 0) + 1
S.Config = type(ReplicatedSuiteConfig) == "table" and ReplicatedSuiteConfig or {}
S.SaveKey = tostring(S.Config.SaveKey or "replicated_suite_v1")
S.MainWindowTitle = tostring(S.Config.MainWindowTitle or "作者：Replicated     qq群：1104129461")
S.Ready = false
S.BootStage = "bootstrap"
S.BootError = nil
S.Api = nil
S.State = nil
S.Storage = nil
S.Layout = nil
S.Scheduler = nil
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
S.WidgetBase = nil
S.Runtime = nil
S.Services = nil
S.Data = nil
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
    return DispatchSystemChat("[Replicated Suite] " .. body)
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

function S.PhysicalId(id)
    return "rs_" .. tostring(id or "widget") .. "_g" .. tostring(S.Generation)
end

S.SafeTraceback = SafeTraceback
S.SafeChat = SafeChat
S.RecordLog = RecordLog
S.DispatchSystemChat = DispatchSystemChat
S.NowMs = NowMs
S.AdvanceClock = AdvanceClock

if API_TYPE == nil and ADDON ~= nil and ADDON.ImportAPI ~= nil then
    pcall(function() ADDON:ImportAPI(8) end)
end
if API_TYPE == nil or OBJECT_TYPE == nil then
    S.BootError = "globals/apitypes.lua unavailable"
    SafeChat("未找到 globals/apitypes.lua，Replicated Suite 无法初始化。")
    return
end

local objectImports = {
    OBJECT_TYPE.TEXT_STYLE,
    OBJECT_TYPE.BUTTON,
    OBJECT_TYPE.DRAWABLE,
    OBJECT_TYPE.COLOR_DRAWABLE,
    OBJECT_TYPE.WINDOW,
    OBJECT_TYPE.LABEL,
    OBJECT_TYPE.EMPTY_WIDGET,
}
if OBJECT_TYPE.ICON_DRAWABLE ~= nil then objectImports[#objectImports + 1] = OBJECT_TYPE.ICON_DRAWABLE end
if OBJECT_TYPE.STATUS_BAR ~= nil then objectImports[#objectImports + 1] = OBJECT_TYPE.STATUS_BAR end
if OBJECT_TYPE.SLIDER ~= nil then objectImports[#objectImports + 1] = OBJECT_TYPE.SLIDER end
for index, objectType in ipairs(objectImports) do
    local ok, err = pcall(function() return ADDON:ImportObject(objectType) end)
    if not ok then
        S.BootError = "object import #" .. tostring(index) .. ":" .. tostring(err)
        SafeChat("UI 对象导入失败：" .. tostring(err))
        return
    end
end
-- Edit controls are optional in several ArcheRage client builds.  They are
-- useful for native Suite pages (profile/set names) but must never become a
-- bootstrap dependency: pages can fall back to button-only editing when the
-- object type/widget constructor is unavailable.
if OBJECT_TYPE.EDITBOX ~= nil then pcall(function() ADDON:ImportObject(OBJECT_TYPE.EDITBOX) end) end
if OBJECT_TYPE.X2_EDITBOX ~= nil then pcall(function() ADDON:ImportObject(OBJECT_TYPE.X2_EDITBOX) end) end

local apiNames = {
    "CHAT", "BAG", "PLAYER", "QUEST", "STORE", "TIME", "UNIT",
    "MAP", "ACHIEVEMENT", "RESIDENT", "ABILITY", "LOCALE", "EQUIPMENT", "OPTION", "AUCTION", "HOTKEY", "TEAM", "BANK", "COFFER",
    -- Instance-entrance UI reads (红龙巢穴 / 血之使者卡杜姆 entry counter).
    "BATTLE_FIELD",
}
for _, name in ipairs(apiNames) do
    local def = API_TYPE[name]
    if type(def) == "table" and def.id ~= nil then
        local ok, err = pcall(function() return ADDON:ImportAPI(def.id) end)
        if not ok then
            S.BootError = "API " .. name .. ":" .. tostring(err)
            SafeChat("API 导入失败 " .. name .. "：" .. tostring(err))
            return
        end
    end
end

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
    local err = S.BootError ~= nil and tostring(S.BootError) or "Suite 尚未完成初始化"
    return "阶段=" .. stage .. "；" .. err
end

local function RevealExistingSuiteShell()
    if S.UI == nil or S.UI.windows == nil or S.UI.windows.main == nil then return false end
    local window = S.UI.windows.main
    local ok = pcall(function()
        if S.UI.pages ~= nil and S.UI.pages.diagnostics ~= nil and type(S.UI.ShowPage) == "function" then
            S.UI:ShowPage("diagnostics")
        end
        window:Show(true)
        if type(window.Raise) == "function" then window:Raise() end
    end)
    return ok == true
end

-- Backward-compatible function name retained because the settings page in older
-- hot-reload generations may still reference it. It no longer reloads the addon,
-- toggles VSync, or writes any client console variable. This is a Suite-internal
-- data/layout refresh only.
local function SafeSuiteRefresh(source)
    if S.Ready ~= true or S.Runtime == nil or S.Runtime.started ~= true then
        RevealExistingSuiteShell()
        SafeChat("刷新未执行：Suite 尚未就绪；" .. BootStatusText())
        return false
    end

    if S.Storage ~= nil and S.Storage.dirty == true and type(S.Storage.SaveNow) == "function" then
        pcall(function() S.Storage:SaveNow() end)
    end

    local ok, err = xpcall(function()
        if type(S.Runtime.RefreshAll) == "function" then S.Runtime:RefreshAll(true, true) end
        if S.Layout ~= nil then
            if type(S.Layout.Invalidate) == "function" then S.Layout:Invalidate() end
            if type(S.Layout.GetContext) == "function" then S.Layout:GetContext(true) end
        end
        if S.UI ~= nil and type(S.UI.ApplyResponsiveLayout) == "function" then
            S.UI:ApplyResponsiveLayout(true)
        end
    end, S.SafeTraceback)
    if not ok then
        SafeChat("Suite 内部刷新失败：" .. tostring(err))
        return false
    end
    if source == "recovery" or source == "settings" then
        SafeChat("已刷新 Suite 数据与界面；未重新载入游戏 UI。")
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
local function ReloadCodeFromDisk(source)
    if X2Option == nil or type(X2Option.SetConsoleVariable) ~= "function" then
        SafeChat("重载失败：UI 刷新接口不可用。")
        return false
    end

    -- Save Suite persistence before the UI generation is replaced. Do not stop
    -- Runtime manually here: the UI refresh owns teardown/rebuild, and stopping
    -- Runtime before a failed console write would strand the current generation.
    if S.Storage ~= nil and S.Storage.dirty == true and type(S.Storage.SaveNow) == "function" then
        pcall(function() S.Storage:SaveNow() end)
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
        SafeChat("重载失败：无法读取 r_VSync；已取消，避免盲目修改客户端设置。")
        return false
    end

    local normalized = string.lower(current)
    local nextValue = (normalized == "1" or normalized == "1.0" or normalized == "true") and "0" or "1"

    SafeChat("正在重新载入 UI 与 Replicated Suite 文件。")
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

local function CreateBootstrapRecoveryEntry()
    if UIParent == nil or type(UIParent.CreateWidget) ~= "function" then return nil end
    local ok, button = pcall(function()
        local widget = UIParent:CreateWidget("button", S.PhysicalId("recovery_entry"), "UIParent", "")
        widget:SetText("R")
        if type(widget.SetStyle) == "function" then pcall(function() widget:SetStyle("text_default") end) end
        if type(widget.SetExtent) == "function" then widget:SetExtent(42, 42) end
        if type(widget.RemoveAllAnchors) == "function" then widget:RemoveAllAnchors() end
        widget:AddAnchor("TOPLEFT", "UIParent", 300, 100)
        if type(widget.Enable) == "function" then widget:Enable(true) end
        if type(widget.EnablePick) == "function" then widget:EnablePick(true) end
        if type(widget.Clickable) == "function" then widget:Clickable(true) end
        widget:Show(true)
        return widget
    end)
    if not ok or button == nil then
        SafeChat("恢复入口创建失败：" .. tostring(button or "unknown"))
        return nil
    end

    return button
end

local function RecoveryLeftClick()
    if S.Ready == true and S.UI ~= nil and type(S.UI.ToggleMain) == "function" then
        S.UI:ToggleMain()
        return true
    end
    RevealExistingSuiteShell()
    SafeChat("Suite 尚未就绪；" .. BootStatusText())
    return false
end

local function RecoveryRightClick()
    -- Explicit emergency/developer path.  Left click remains a pure launcher.
    return ReloadCodeFromDisk("recovery")
end

local function InstallRecoveryHandlers(button)
    if button == nil or type(button.SetHandler) ~= "function" then return false end
    local leftOk, leftResult = pcall(button.SetHandler, button, "OnClick", RecoveryLeftClick)
    local rightOk, rightResult = pcall(button.SetHandler, button, "OnRButtonUp", RecoveryRightClick)
    local leftBound = leftOk and leftResult ~= false
    local rightBound = rightOk and rightResult ~= false
    if not leftBound then SafeChat("恢复入口左键绑定失败：" .. tostring(leftOk and "SetHandler returned false" or leftResult)) end
    if not rightBound then SafeChat("恢复入口右键重载不可用：" .. tostring(rightOk and "SetHandler returned false" or rightResult)) end
    -- Left click is the minimum viable recovery path; right-click reload is an
    -- optional developer convenience and must not make the launcher itself fail.
    return leftBound
end

function S.ActivateRecoveryEntry()
    local button = S.RecoveryEntry
    if button == nil then return false end
    local handlerOk = InstallRecoveryHandlers(button)
    pcall(function()
        button:SetText("R")
        if type(button.Enable) == "function" then button:Enable(true) end
        if type(button.EnablePick) == "function" then button:EnablePick(true) end
        if type(button.Clickable) == "function" then button:Clickable(true) end
        button:Show(true)
    end)
    return handlerOk
end

S.RecoveryEntry = CreateBootstrapRecoveryEntry()
InstallRecoveryHandlers(S.RecoveryEntry)

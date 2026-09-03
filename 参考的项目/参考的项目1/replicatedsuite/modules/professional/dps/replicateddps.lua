ReplicatedSuiteModuleSandbox:Enter('dps', {'ReplicatedDps', 'ReplicatedDpsConfig'})

-- A Suite factory reset clears the persisted DPS Authorities before UI reload.
-- The RU reload path may preserve Lua globals, and DPS normally treats its
-- in-memory State as a recovery candidate. Drop the previous generation here so
-- a reset really boots exactly like a first install instead of resurrecting RAM.
if rawget(_G, "ReplicatedSuiteFactoryResetPending") == true then
    local previous = rawget(_G, "ReplicatedDps")
    if type(previous) == "table" then
        if type(previous.Runtime) == "table" and type(previous.Runtime.Stop) == "function" then
            pcall(function() previous.Runtime:Stop() end)
        end
        if type(previous.Boot) == "table" and previous.Boot.launcher ~= nil then
            pcall(function() previous.Boot.launcher:Show(false) end)
        end
    end
    ReplicatedDps = {}
end
------------------------------------------------------------------------
-- Replicated DPS - Bootstrap
-- Author: Replicated
-- Folder: replicateddps
--
-- This file deliberately stays small. It creates the visible launcher
-- before the heavier UI/statistics modules are compiled and executed.
------------------------------------------------------------------------

ReplicatedDps = ReplicatedDps or {}
local D = ReplicatedDps
D.Author = "Replicated"
D.Name = "Replicated DPS"
D.Version = "0.3.0-rc30"
D.Boot = D.Boot or {}

local Boot = D.Boot
Boot.phase = "BOOTSTRAP_CREATING"
Boot.lastCompletedPhase = Boot.lastCompletedPhase or "none"
Boot.error = nil
Boot.failedModule = nil
Boot.openSettings = nil
Boot.onLauncherDragStop = nil
Boot.onLauncherDragStart = nil
Boot.generation = (Boot.generation or 0) + 1

local function SafeChat(message)
    local text = "[Replicated DPS] " .. tostring(message)
    if X2Chat ~= nil and X2Chat.DispatchChatMessage ~= nil then
        pcall(function()
            X2Chat:DispatchChatMessage(CMF_SYSTEM, text)
        end)
    elseif ADDON ~= nil and ADDON.ChatLog ~= nil then
        pcall(function()
            ADDON:ChatLog(text)
        end)
    end
end

Boot.SafeChat = SafeChat

local function SafeTraceback(err)
    if debug ~= nil and debug.traceback ~= nil then
        return debug.traceback(tostring(err), 2)
    end
    return tostring(err)
end

Boot.SafeTraceback = SafeTraceback

Boot.launcherClock = Boot.launcherClock or { lastRaw = nil, lastMs = 0, offset = 0 }
Boot.launcherVisible = false

local function LauncherNowMs()
    local clock = Boot.launcherClock
    if UI ~= nil and UI.GetCurrentTimeStamp ~= nil then
        local ok, value = pcall(function() return UI:GetCurrentTimeStamp() end)
        local raw = ok and tonumber(value) or nil
        if raw ~= nil and raw == raw and raw ~= math.huge and raw ~= -math.huge and raw >= 0 then
            raw = math.floor(raw + 0.5)
            local lastRaw = tonumber(clock.lastRaw)
            local lastMs = math.max(0, tonumber(clock.lastMs) or 0)
            local offset = math.max(0, tonumber(clock.offset) or 0)
            if lastRaw ~= nil and raw < lastRaw then offset = math.max(offset, lastMs - raw) end
            local result = math.max(lastMs, raw + offset)
            clock.lastRaw, clock.lastMs, clock.offset = raw, result, offset
            return result
        end
    end
    return math.max(0, tonumber(clock.lastMs) or 0)
end

function Boot:SetPhase(phase)
    self.phase = tostring(phase or "UNKNOWN")
end

function Boot:CompletePhase(phase)
    self.phase = tostring(phase or self.phase or "UNKNOWN")
    self.lastCompletedPhase = self.phase
end

function Boot:Fail(moduleName, err)
    self.phase = "FAILED"
    self.failedModule = tostring(moduleName or "unknown")
    self.error = tostring(err or "unknown error")
    SafeChat(
        "初始化失败；模块=" .. self.failedModule
        .. "，最后阶段=" .. tostring(self.lastCompletedPhase)
        .. "，错误=" .. self.error
    )
end

function Boot:ReportCurrentFailure()
    if self.error ~= nil then
        SafeChat(
            "当前不可用；模块=" .. tostring(self.failedModule or "unknown")
            .. "，最后阶段=" .. tostring(self.lastCompletedPhase)
            .. "，错误=" .. tostring(self.error)
        )
        return
    end
    SafeChat(
        "入口已加载，但核心尚未完成。当前阶段=" .. tostring(self.phase)
        .. "，最后完成=" .. tostring(self.lastCompletedPhase)
        .. "。请检查 toc.g 中的 core/ui/runtime 文件。"
    )
end

if API_TYPE == nil and ADDON ~= nil and ADDON.ImportAPI ~= nil then
    pcall(function()
        ADDON:ImportAPI(8)
    end)
end

if API_TYPE == nil then
    SafeChat("未找到 globals/apitypes.lua，无法创建插件入口。")
    Boot:Fail("bootstrap", "API_TYPE is nil")
    return
end

local bootstrapImports = {
    function() ADDON:ImportAPI(API_TYPE.CHAT.id) end,
    function() ADDON:ImportObject(OBJECT_TYPE.TEXT_STYLE) end,
    function() ADDON:ImportObject(OBJECT_TYPE.BUTTON) end,
    function() ADDON:ImportObject(OBJECT_TYPE.DRAWABLE) end,
    function() ADDON:ImportObject(OBJECT_TYPE.COLOR_DRAWABLE) end,
    function() ADDON:ImportObject(OBJECT_TYPE.EMPTY_WIDGET) end,
}

for _, importFn in ipairs(bootstrapImports) do
    pcall(importFn)
end

local function ApplyLauncherStyle(button)
    local colors = {
        { 0.14, 0.21, 0.29, 0.97 },
        { 0.23, 0.35, 0.47, 0.99 },
        { 0.08, 0.13, 0.19, 0.99 },
        { 0.08, 0.09, 0.11, 0.72 },
    }

    button.repdpsLauncherColors = colors
    button.repdpsRefs = button.repdpsRefs or {}
    if button.repdpsRefs.backgrounds == nil then
        button.repdpsRefs.backgrounds = {}
        for i = 1, 4 do
            local c = colors[i]
            local bg = button:CreateColorDrawable(c[1], c[2], c[3], c[4], "background")
            if bg ~= nil then
                bg:AddAnchor("TOPLEFT", button, 0, 0)
                bg:AddAnchor("BOTTOMRIGHT", button, 0, 0)
            end
            button.repdpsRefs.backgrounds[i] = bg
        end
        if button.SetNormalBackground ~= nil then
            button:SetNormalBackground(button.repdpsRefs.backgrounds[1])
            button:SetHighlightBackground(button.repdpsRefs.backgrounds[2])
            button:SetPushedBackground(button.repdpsRefs.backgrounds[3])
            button:SetDisabledBackground(button.repdpsRefs.backgrounds[4])
        end
    end

    if button.SetAutoResize ~= nil then
        button:SetAutoResize(false)
    end
    button:SetExtent(88, 26)
    if button.SetWidth ~= nil then button:SetWidth(88) end
    if button.SetHeight ~= nil then button:SetHeight(26) end
    if button.style ~= nil then
        if button.style.SetFontSize ~= nil then button.style:SetFontSize(11) end
        if button.style.SetColor ~= nil then button.style:SetColor(0.96, 0.92, 0.82, 1) end
    end
end

-- Only the four launcher background drawables are faded.  The label itself
-- stays fully opaque so a low background opacity never makes the DPS entry
-- unreadable against the game scene.  The runtime config is loaded after the
-- bootstrap launcher is created, therefore UI layout reapplies this value once
-- D.State.config becomes authoritative.
function Boot:ApplyLauncherOpacity(opacity)
    local button = self.launcher
    if button == nil or button.repdpsRefs == nil then return end
    local value = tonumber(opacity) or 1.00
    if value < 0.20 then value = 0.20 elseif value > 1.00 then value = 1.00 end
    local colors = button.repdpsLauncherColors or {
        { 0.14, 0.21, 0.29, 0.97 },
        { 0.23, 0.35, 0.47, 0.99 },
        { 0.08, 0.13, 0.19, 0.99 },
        { 0.08, 0.09, 0.11, 0.72 },
    }
    local backgrounds = button.repdpsRefs.backgrounds
    if type(backgrounds) ~= "table" then return end
    for i = 1, 4 do
        local bg = backgrounds[i]
        local c = colors[i]
        if bg ~= nil and c ~= nil and bg.SetColor ~= nil then
            pcall(function() bg:SetColor(c[1], c[2], c[3], c[4] * value) end)
        end
    end
end

local launcher = Boot.launcher
if ReplicatedSuiteEmbedded == true then
    -- Suite left navigation is the only launcher Authority in embedded mode.
    -- Do not create the historical standalone button or any of its handlers.
    -- The DPS Domain remains loaded/configurable through the Suite page.
    if launcher ~= nil and type(launcher.Show) == "function" then pcall(function() launcher:Show(false) end) end
    Boot.launcher = nil
    Boot.launcherVisible = false
    Boot.launcherHandlersInstalled = false
else
    if launcher == nil then
        local ok, result = xpcall(function()
            local button = UIParent:CreateWidget("button", "repdps_launcher", "UIParent", "")
            button:SetText("战斗统计")
            ApplyLauncherStyle(button)
            button:AddAnchor("TOPLEFT", "UIParent", 300, 100)
            if button.Enable ~= nil then button:Enable(true) end
            if button.Clickable ~= nil then button:Clickable(true) end
            if button.EnableDrag ~= nil then button:EnableDrag(true) end
            button:Show(false)
            return button
        end, SafeTraceback)
        if not ok or result == nil then Boot:Fail("bootstrap:create_launcher", result); return end
        launcher = result
        Boot.launcher = launcher
    else
        pcall(function()
            launcher:SetText("战斗统计")
            ApplyLauncherStyle(launcher)
            if launcher.Enable ~= nil then launcher:Enable(true) end
            if launcher.Clickable ~= nil then launcher:Clickable(true) end
            if launcher.EnableDrag ~= nil then launcher:EnableDrag(true) end
            launcher:Show(false)
        end)
    end

    if ReplicatedCombatLauncherPolicy ~= nil and type(ReplicatedCombatLauncherPolicy.Register) == "function" then
        ReplicatedCombatLauncherPolicy:Register("dps", launcher)
    end
    local DPS_LAUNCHER_CONTENT_ID = 91831
    if ADDON ~= nil then
        if type(ADDON.RegisterContentWidget) == "function" then pcall(function() ADDON:RegisterContentWidget(DPS_LAUNCHER_CONTENT_ID, launcher) end) end
        if type(ADDON.RegisterContentTriggerFunc) == "function" then
            pcall(function()
                ADDON:RegisterContentTriggerFunc(DPS_LAUNCHER_CONTENT_ID, function(show)
                    Boot.launcherVisible = show == true
                    launcher:Show(Boot.launcherVisible)
                end)
            end)
        end
    end
    launcher:Show(Boot.launcherVisible == true)

    if Boot.launcherHandlersInstalled ~= true then
        launcher:SetHandler("OnDragStart", function(self)
            self.repdpsMoving = true
            self.repdpsSafeMoving = false
            if Boot.onLauncherDragStart ~= nil then pcall(Boot.onLauncherDragStart, self) end
            if ReplicatedSuiteEmbedded == true and ReplicatedSuite ~= nil and ReplicatedSuite.Layout ~= nil
                and type(ReplicatedSuite.Layout.BeginSafeMove) == "function" then
                local ok, moved = pcall(function()
                    return ReplicatedSuite.Layout:BeginSafeMove("dps_launcher", self, { clamp = true })
                end)
                self.repdpsSafeMoving = ok and moved == true
            end
            if self.repdpsSafeMoving ~= true then self:StartMoving() end
            return true
        end)
        launcher:SetHandler("OnDragStop", function(self)
            if self.repdpsSafeMoving == true and ReplicatedSuite ~= nil and ReplicatedSuite.Layout ~= nil
                and type(ReplicatedSuite.Layout.EndSafeMove) == "function" then
                pcall(function() ReplicatedSuite.Layout:EndSafeMove("dps_launcher", false) end)
            else
                self:StopMovingOrSizing()
            end
            self.repdpsSafeMoving = false
            self.repdpsMoving = false; self.repdpsDragStoppedClock = LauncherNowMs()
            if Boot.onLauncherDragStop ~= nil then
                local ok, err = pcall(Boot.onLauncherDragStop, self)
                if not ok then SafeChat("保存入口位置失败：" .. tostring(err)) end
            end
        end)
        launcher:SetHandler("OnClick", function(self)
            local now = LauncherNowMs()
            if self.repdpsDragStoppedClock ~= nil and now - self.repdpsDragStoppedClock <= 180 then return end
            if Boot.openSettings ~= nil then
                local ok, err = xpcall(Boot.openSettings, SafeTraceback)
                if not ok then Boot:Fail("launcher:open_settings", err) end
                return
            end
            Boot:ReportCurrentFailure()
        end)
        Boot.launcherHandlersInstalled = true
    end
end

Boot:CompletePhase("BOOTSTRAP_READY")

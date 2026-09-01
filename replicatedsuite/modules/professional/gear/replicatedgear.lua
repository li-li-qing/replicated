ReplicatedSuiteModuleSandbox:Enter('gear', {'ReplicatedGear', 'ReplicatedGearConfig'})
------------------------------------------------------------------------
-- Replicated Gear - Bootstrap
-- Author: Replicated
-- Version: 0.1.0-rc25
------------------------------------------------------------------------

ReplicatedGear = ReplicatedGear or {}
local G = ReplicatedGear

-- A Lua/UI hot reload can leave the previous generation's widgets and OnUpdate
-- driver alive.  Quiesce that generation before replacing module references so
-- a failed reload can never fall back to stale Core/UI/Runtime objects.
local previousUI = rawget(G, "UI")
local previousRuntime = rawget(G, "Runtime")
if type(previousRuntime) == "table" then
    previousRuntime.busy = false
    previousRuntime.session = nil
    previousRuntime.stage = "IDLE"
end
if type(previousUI) == "table" and type(previousUI.HideAll) == "function" then
    pcall(function() previousUI:HideAll() end)
end
G.Api = nil
G.Core = nil
G.UI = nil
G.Runtime = nil
G.WorkspacePresenter = nil
G.BootError = nil

G.Author = "Replicated"
G.Name = "Replicated Gear"
G.Version = "0.1.0-rc26"
G.SaveKey = "replicated_gear_v1"
G.Generation = (tonumber(G.Generation) or 0) + 1
G.Ready = false

local function SafeTraceback(err)
    if debug ~= nil and debug.traceback ~= nil then
        return debug.traceback(tostring(err), 2)
    end
    return tostring(err)
end

local function SafeChat(message)
    local text = "[Replicated Gear] " .. tostring(message or "")
    if X2Chat ~= nil and X2Chat.DispatchChatMessage ~= nil then
        pcall(function() X2Chat:DispatchChatMessage(CMF_SYSTEM, text) end)
    elseif ADDON ~= nil and ADDON.ChatLog ~= nil then
        pcall(function() ADDON:ChatLog(text) end)
    end
end

local clock = { lastRaw = nil, lastMs = 0, offset = 0 }
local function NowMs()
    if UI ~= nil and UI.GetCurrentTimeStamp ~= nil then
        local ok, raw = pcall(function() return UI:GetCurrentTimeStamp() end)
        raw = ok and tonumber(raw) or nil
        if raw ~= nil and raw == raw and raw >= 0 and raw ~= math.huge then
            raw = math.floor(raw + 0.5)
            if clock.lastRaw ~= nil and raw < clock.lastRaw then
                clock.offset = math.max(clock.offset or 0, (clock.lastMs or 0) - raw)
            end
            local result = math.max(clock.lastMs or 0, raw + (clock.offset or 0))
            clock.lastRaw, clock.lastMs = raw, result
            return result
        end
    end
    return math.max(0, tonumber(clock.lastMs) or 0)
end

G.SafeTraceback = SafeTraceback
G.SafeChat = SafeChat
G.NowMs = NowMs

if API_TYPE == nil and ADDON ~= nil and ADDON.ImportAPI ~= nil then
    pcall(function() return ADDON:ImportAPI(8) end)
end

if API_TYPE == nil then
    SafeChat("未找到 globals/apitypes.lua。请先安装 ArcheRage 官方 globals 依赖。")
    G.BootError = "API_TYPE is nil"
    return
end

local imports = {
    function() return ADDON:ImportAPI(API_TYPE.CHAT.id) end,
    function() return ADDON:ImportAPI(API_TYPE.UNIT.id) end,
    function() return ADDON:ImportAPI(API_TYPE.PLAYER.id) end,
    function() return ADDON:ImportAPI(API_TYPE.EQUIPMENT.id) end,
    function() return ADDON:ImportAPI(API_TYPE.BAG.id) end,
    function() return ADDON:ImportObject(OBJECT_TYPE.TEXT_STYLE) end,
    function() return ADDON:ImportObject(OBJECT_TYPE.BUTTON) end,
    function() return ADDON:ImportObject(OBJECT_TYPE.DRAWABLE) end,
    function() return ADDON:ImportObject(OBJECT_TYPE.COLOR_DRAWABLE) end,
    function() return ADDON:ImportObject(OBJECT_TYPE.WINDOW) end,
    function() return ADDON:ImportObject(OBJECT_TYPE.LABEL) end,
    function() return OBJECT_TYPE.EDITBOX == nil or ADDON:ImportObject(OBJECT_TYPE.EDITBOX) end,
    function() return OBJECT_TYPE.X2_EDITBOX == nil or ADDON:ImportObject(OBJECT_TYPE.X2_EDITBOX) end,
    function() return ADDON:ImportObject(OBJECT_TYPE.EMPTY_WIDGET) end,
}

for index, fn in ipairs(imports) do
    -- ImportAPI/ImportObject return semantics are not documented.  Treat only
    -- an actual Lua/API exception as import failure; rg_api.lua then validates
    -- the concrete required methods before Core is allowed to start.
    local ok, result = pcall(fn)
    if not ok then
        local reason = tostring(result)
        G.BootError = "import #" .. tostring(index) .. ": " .. reason
        SafeChat("依赖/API导入失败（#" .. tostring(index) .. "）：" .. reason)
        return
    end
end

G.BootError = nil

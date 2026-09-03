ReplicatedSuiteModuleSandbox:Enter('plates', {'ReplicatedPlates'})
------------------------------------------------------------------------
-- Replicated Plates - Bootstrap
-- Author: Replicated
-- Version: 0.6.0-aura-library
------------------------------------------------------------------------

ReplicatedPlates = ReplicatedPlates or {}
local P = ReplicatedPlates

-- ArcheRage can keep widgets from a previous Lua hot-reload generation alive.
-- Quiesce the previous generation before replacing module references. Every
-- runtime/UI handler also carries a generation guard, so stale generations
-- become inert even if the client retains their physical widgets temporarily.
local previousRuntime = rawget(P, "Runtime")
local previousUI = rawget(P, "UI")
if type(previousRuntime) == "table" and type(previousRuntime.Stop) == "function" then
    pcall(function() previousRuntime:Stop() end)
end
if type(previousUI) == "table" and type(previousUI.HideAll) == "function" then
    pcall(function() previousUI:HideAll() end)
end

P.Author = "Replicated"
P.Name = "Replicated Plates"
P.Version = "0.6.0-aura-library"
P.ContentId = 91733
P.SaveKey = "replicated_plates_v1"
P.BackupSaveKey = "replicated_plates_v1_backup"
P.SchemaVersion = 19
P.Generation = (tonumber(P.Generation) or 0) + 1
P.Ready = false
P.BootError = nil
P.Api = nil
P.Storage = nil
P.UI = nil
P.Runtime = nil
P.Integration = nil
P.Diagnostics = nil

local function SafeTraceback(err)
    if debug ~= nil and debug.traceback ~= nil then
        return debug.traceback(tostring(err), 2)
    end
    return tostring(err)
end

local function SafeChat(message)
    local body = tostring(message or "")
    local text = "[Replicated Plates] " .. body
    -- Embedded professional modules must feed the Suite's single diagnostic
    -- log Authority.  Previously Plates printed directly to chat, so a layout
    -- error could be visible on screen while "打印全部日志" still reported
    -- zero entries.  Keep standalone behaviour unchanged.
    if ReplicatedSuiteEmbedded == true and ReplicatedSuite ~= nil then
        if type(ReplicatedSuite.RecordLog) == "function" then
            local level = (body:find("失败", 1, true) or body:find("错误", 1, true) or body:find("不可用", 1, true)) and "error" or "info"
            pcall(function() ReplicatedSuite.RecordLog(level, "plates", body) end)
        end
        if type(ReplicatedSuite.DispatchSystemChat) == "function" then
            pcall(function() ReplicatedSuite.DispatchSystemChat(text) end)
            return
        end
    end
    if X2Chat ~= nil and X2Chat.DispatchChatMessage ~= nil then
        pcall(function() X2Chat:DispatchChatMessage(CMF_SYSTEM, text) end)
    elseif ADDON ~= nil and ADDON.ChatLog ~= nil then
        pcall(function() ADDON:ChatLog(text) end)
    end
end

function P.PhysicalId(id)
    return "rp_" .. tostring(id or "widget") .. "_g" .. tostring(P.Generation)
end

P.SafeTraceback = SafeTraceback
P.SafeChat = SafeChat

if API_TYPE == nil and ADDON ~= nil and ADDON.ImportAPI ~= nil then
    pcall(function() ADDON:ImportAPI(8) end)
end

if API_TYPE == nil or OBJECT_TYPE == nil then
    P.BootError = "globals/apitypes.lua unavailable"
    SafeChat("未找到 globals/apitypes.lua，无法初始化。")
    return
end

local imports = {
    function() return ADDON:ImportAPI(API_TYPE.CHAT.id) end,
    function() return ADDON:ImportAPI(API_TYPE.UNIT.id) end,
    function() return ADDON:ImportAPI(API_TYPE.SKILL.id) end,
    function() return API_TYPE.ABILITY == nil or ADDON:ImportAPI(API_TYPE.ABILITY.id) end,
    function() return ADDON:ImportAPI(API_TYPE.LOCALE.id) end,
    function() return ADDON:ImportAPI(API_TYPE.EQUIPMENT.id) end,
    function() return ADDON:ImportObject(OBJECT_TYPE.TEXT_STYLE) end,
    function() return ADDON:ImportObject(OBJECT_TYPE.BUTTON) end,
    function() return ADDON:ImportObject(OBJECT_TYPE.DRAWABLE) end,
    function() return ADDON:ImportObject(OBJECT_TYPE.COLOR_DRAWABLE) end,
    function() return ADDON:ImportObject(OBJECT_TYPE.ICON_DRAWABLE) end,
    function() return ADDON:ImportObject(OBJECT_TYPE.STATUS_BAR) end,
    function() return OBJECT_TYPE.SLIDER == nil or ADDON:ImportObject(OBJECT_TYPE.SLIDER) end,
    function() return ADDON:ImportObject(OBJECT_TYPE.WINDOW) end,
    function() return ADDON:ImportObject(OBJECT_TYPE.LABEL) end,
    function() return ADDON:ImportObject(OBJECT_TYPE.EMPTY_WIDGET) end,
    function() return OBJECT_TYPE.EDITBOX == nil or ADDON:ImportObject(OBJECT_TYPE.EDITBOX) end,
    function() return OBJECT_TYPE.EDITBOX_MULTILINE == nil or ADDON:ImportObject(OBJECT_TYPE.EDITBOX_MULTILINE) end,
    function() return OBJECT_TYPE.X2_EDITBOX == nil or ADDON:ImportObject(OBJECT_TYPE.X2_EDITBOX) end,
}

for index, importFn in ipairs(imports) do
    local ok, result = pcall(importFn)
    if not ok then
        P.BootError = "import #" .. tostring(index) .. ": " .. tostring(result)
        SafeChat("依赖/API导入失败（#" .. tostring(index) .. "）：" .. tostring(result))
        return
    end
end

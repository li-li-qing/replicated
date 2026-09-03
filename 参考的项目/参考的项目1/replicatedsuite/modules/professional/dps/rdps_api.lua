ReplicatedSuiteModuleSandbox:Enter('dps', {'ReplicatedDps', 'ReplicatedDpsConfig'})
------------------------------------------------------------------------
-- Replicated DPS - Official API facade and capability boundary
-- Author: Replicated
--
-- This module owns every post-bootstrap call to game APIs. Capabilities are
-- explicitly classified according to the user-provided z_api_functions files.
-- "allowed" only authorizes the API call itself; consumers still parse return
-- values conservatively when the current RU contract does not document a stable
-- row schema (notably GetUnitsInSight).
------------------------------------------------------------------------

if ReplicatedDps == nil or ReplicatedDps.Boot == nil then return end

local D = ReplicatedDps
local Boot = D.Boot
Boot:SetPhase("API_FACADE_LOADING")

D.Api = D.Api or {}
local A = D.Api

A.ContractStatus = {
    ALLOWED = "allowed",
    OPTIONAL_NOT_ALLOWED = "optional-not-allowed",
    UNDECLARED = "undeclared",
}

A.capabilities = type(A.capabilities) == "table" and A.capabilities or {}
A.imports = type(A.imports) == "table" and A.imports or {}
A.diagnosticsFlushedGeneration = tonumber(A.diagnosticsFlushedGeneration) or 0

local definitions = {
    ["addon.chat_log"] = { objectName = "ADDON", methodName = "ChatLog", contractStatus = "allowed", formalUseAllowed = true },
    ["addon.load_data"] = { objectName = "ADDON", methodName = "LoadData", contractStatus = "allowed", formalUseAllowed = true },
    ["addon.save_data"] = { objectName = "ADDON", methodName = "SaveData", contractStatus = "allowed", formalUseAllowed = true },
    ["addon.clear_data"] = { objectName = "ADDON", methodName = "ClearData", contractStatus = "allowed", formalUseAllowed = true },
    ["addon.register_content_widget"] = { objectName = "ADDON", methodName = "RegisterContentWidget", contractStatus = "allowed", formalUseAllowed = true },
    ["addon.register_content_trigger"] = { objectName = "ADDON", methodName = "RegisterContentTriggerFunc", contractStatus = "allowed", formalUseAllowed = true },
    ["addon.add_esc_menu_button"] = { objectName = "ADDON", methodName = "AddEscMenuButton", contractStatus = "allowed", formalUseAllowed = true },
    ["addon.get_content_main_script_pos_vis"] = { objectName = "ADDON", methodName = "GetContentMainScriptPosVis", contractStatus = "allowed", formalUseAllowed = true },
    ["chat.dispatch_system"] = { objectName = "X2Chat", methodName = "DispatchChatMessage", contractStatus = "allowed", formalUseAllowed = true },
    ["unit.get_unit_id"] = { objectName = "X2Unit", methodName = "GetUnitId", contractStatus = "allowed", formalUseAllowed = true },
    ["unit.unit_name"] = { objectName = "X2Unit", methodName = "UnitName", contractStatus = "allowed", formalUseAllowed = true },
    ["unit.unit_name_with_world"] = { objectName = "X2Unit", methodName = "UnitNameWithWorld", contractStatus = "allowed", formalUseAllowed = true },
    ["unit.debuff_count"] = { objectName = "X2Unit", methodName = "UnitDeBuffCount", contractStatus = "allowed", formalUseAllowed = true },
    ["unit.debuff_tooltip"] = { objectName = "X2Unit", methodName = "UnitDeBuffTooltip", contractStatus = "allowed", formalUseAllowed = true },
    ["unit.debuff_entry"] = { objectName = "X2Unit", methodName = "UnitDeBuff", contractStatus = "allowed", formalUseAllowed = true },
    ["unit.get_target_unit_id"] = { objectName = "X2Unit", methodName = "GetTargetUnitId", contractStatus = "allowed", formalUseAllowed = true },
    ["unit.get_unit_name_by_id"] = { objectName = "X2Unit", methodName = "GetUnitNameById", contractStatus = "allowed", formalUseAllowed = true },
    ["unit.get_unit_info_by_id"] = { objectName = "X2Unit", methodName = "GetUnitInfoById", contractStatus = "allowed", formalUseAllowed = true },
    ["unit.unit_info_diagnostic"] = { objectName = "X2Unit", methodName = "UnitInfo", contractStatus = "allowed", formalUseAllowed = true, diagnosticOnly = true },
    ["unit.unit_modifier_info_diagnostic"] = { objectName = "X2Unit", methodName = "UnitModifierInfo", contractStatus = "allowed", formalUseAllowed = true, diagnosticOnly = true },
    ["social.is_friend"] = { objectName = "X2Friend", methodName = "IsMyFriend", contractStatus = "allowed", formalUseAllowed = true, softPriorOnly = true },
    ["social.is_expedition_member"] = { objectName = "X2Faction", methodName = "IsMyExpeditionMember", contractStatus = "allowed", formalUseAllowed = true, softPriorOnly = true },
    ["world.current_world_name"] = { objectName = "X2World", methodName = "GetCurrentWorldName", contractStatus = "allowed", formalUseAllowed = true, namespaceFallbackOnly = true },
}

local function GetGlobal(name)
    if _G == nil then return nil end
    return _G[name]
end

local function CopyDefinition(target, source)
    target.objectName = source.objectName
    target.methodName = source.methodName
    target.contractStatus = source.contractStatus
    target.formalUseAllowed = source.formalUseAllowed == true
    target.diagnosticOnly = source.diagnosticOnly == true
    target.softPriorOnly = source.softPriorOnly == true
    target.namespaceFallbackOnly = source.namespaceFallbackOnly == true
    target.experimental = source.experimental == true
end

for name, definition in pairs(definitions) do
    local capability = type(A.capabilities[name]) == "table" and A.capabilities[name] or {}
    CopyDefinition(capability, definition)
    capability.callCount = math.max(0, math.floor(tonumber(capability.callCount) or 0))
    capability.failureCount = math.max(0, math.floor(tonumber(capability.failureCount) or 0))
    capability.hasBeenCalled = capability.callCount > 0
    capability.lastCallSucceeded = capability.hasBeenCalled and capability.lastCallSucceeded == true or false
    capability.lastError = tostring(capability.lastError or "")
    A.capabilities[name] = capability
end

local apiImportByObject = {
    X2Chat = "CHAT",
    X2Unit = "UNIT",
    X2World = "WORLD",
    X2Friend = "FRIEND",
    X2Faction = "FACTION",
}

local function ProbeCapability(name)
    local capability = A.capabilities[name]
    if type(capability) ~= "table" then return nil, nil, nil end
    local object = GetGlobal(capability.objectName)
    local fn = type(object) == "table" and object[capability.methodName] or nil
    capability.functionPresent = type(fn) == "function"
    if capability.objectName == "ADDON" then
        capability.imported = true
    else
        local apiName = apiImportByObject[capability.objectName]
        local importState = apiName ~= nil and A.imports["api:" .. apiName] or nil
        capability.imported = type(importState) == "table" and importState.imported == true
    end
    return capability, object, fn
end

local function RecordCall(capability, ok, result)
    if type(capability) ~= "table" then return end
    capability.callCount = math.max(0, math.floor(tonumber(capability.callCount) or 0)) + 1
    capability.hasBeenCalled = true
    capability.lastCallSucceeded = ok == true
    if ok then
        capability.lastError = ""
    else
        capability.failureCount = math.max(0, math.floor(tonumber(capability.failureCount) or 0)) + 1
        capability.lastError = tostring(result)
    end
end

local function InvokeOne(name, ...)
    local capability, object, fn = ProbeCapability(name)
    if capability == nil then return false, "unknown capability: " .. tostring(name) end
    if type(fn) ~= "function" then
        RecordCall(capability, false, "function unavailable")
        return false, "function unavailable"
    end
    local ok, result = pcall(fn, object, ...)
    RecordCall(capability, ok, result)
    return ok, result
end

local function InvokeResults(name, ...)
    local capability, object, fn = ProbeCapability(name)
    if capability == nil then return false, "unknown capability: " .. tostring(name) end
    if type(fn) ~= "function" then
        RecordCall(capability, false, "function unavailable")
        return false, "function unavailable"
    end
    local ok, a, b, c, d, e = pcall(fn, object, ...)
    RecordCall(capability, ok, a)
    return ok, a, b, c, d, e
end

local function RecordImport(kind, name, contractStatus, required, ok, detail)
    local key = tostring(kind) .. ":" .. tostring(name)
    local state = type(A.imports[key]) == "table" and A.imports[key] or {}
    state.kind = kind
    state.name = name
    state.contractStatus = contractStatus
    state.required = required == true
    state.imported = ok == true
    state.lastError = ok and nil or tostring(detail)
    A.imports[key] = state
    return state
end

function A:ImportApi(apiName, contractStatus, required)
    local status = contractStatus or self.ContractStatus.ALLOWED
    local entry = API_TYPE ~= nil and API_TYPE[apiName] or nil
    if ADDON == nil or type(ADDON.ImportAPI) ~= "function" then
        RecordImport("api", apiName, status, required, false, "ADDON:ImportAPI unavailable")
        return false, "ADDON:ImportAPI unavailable"
    end
    if type(entry) ~= "table" or entry.id == nil then
        RecordImport("api", apiName, status, required, false, "API_TYPE entry unavailable")
        return false, "API_TYPE entry unavailable"
    end
    local ok, result = pcall(ADDON.ImportAPI, ADDON, entry.id)
    local imported = ok and result ~= false
    local detail = ok and (result == false and "returned false" or nil) or result
    RecordImport("api", apiName, status, required, imported, detail)
    return imported, detail
end

function A:ImportObject(objectName, required)
    local entry = OBJECT_TYPE ~= nil and OBJECT_TYPE[objectName] or nil
    if ADDON == nil or type(ADDON.ImportObject) ~= "function" then
        RecordImport("object", objectName, self.ContractStatus.ALLOWED, required, false, "ADDON:ImportObject unavailable")
        return false, "ADDON:ImportObject unavailable"
    end
    if entry == nil then
        RecordImport("object", objectName, self.ContractStatus.ALLOWED, required, false, "OBJECT_TYPE entry unavailable")
        return false, "OBJECT_TYPE entry unavailable"
    end
    local ok, result = pcall(ADDON.ImportObject, ADDON, entry)
    local imported = ok and result ~= false
    local detail = ok and (result == false and "returned false" or nil) or result
    RecordImport("object", objectName, self.ContractStatus.ALLOWED, required, imported, detail)
    return imported, detail
end

function A:InitializeImports()
    local requiredApis = { "CHAT", "UNIT" }
    for _, apiName in ipairs(requiredApis) do
        local ok, err = self:ImportApi(apiName, self.ContractStatus.ALLOWED, true)
        if not ok then return false, "api " .. tostring(apiName) .. ": " .. tostring(err) end
    end

    local requiredObjects = {
        "TEXT_STYLE", "BUTTON", "DRAWABLE", "COLOR_DRAWABLE", "WINDOW", "LABEL", "EMPTY_WIDGET",
    }
    for _, objectName in ipairs(requiredObjects) do
        local ok, err = self:ImportObject(objectName, true)
        if not ok then return false, "object " .. tostring(objectName) .. ": " .. tostring(err) end
    end

    -- DPS 图标明细属于可降级能力：图标对象缺失时仍保留文字统计。
    self:ImportObject("ICON_DRAWABLE", false)
    self:ImportApi("WORLD", self.ContractStatus.ALLOWED, false)
    self:ImportApi("FRIEND", self.ContractStatus.ALLOWED, false)
    self:ImportApi("FACTION", self.ContractStatus.ALLOWED, false)
    self:ProbeAll()
    return true
end

function A:ProbeAll()
    for name in pairs(self.capabilities) do ProbeCapability(name) end
    D.Capabilities = D.Capabilities or {}
    D.Capabilities.world = self.imports["api:WORLD"] ~= nil and self.imports["api:WORLD"].imported == true
    D.Capabilities.friend = self.imports["api:FRIEND"] ~= nil and self.imports["api:FRIEND"].imported == true
    D.Capabilities.faction = self.imports["api:FACTION"] ~= nil and self.imports["api:FACTION"].imported == true
    D.Capabilities.family = false
end

function A:Has(name)
    local capability = ProbeCapability(name)
    return type(capability) == "table" and capability.functionPresent == true
end

function A:GetCapability(name)
    ProbeCapability(name)
    return self.capabilities[name]
end

local function SharedUnitRead(field, actor, ttlMs, fetchFn)
    if ReplicatedSuiteEmbedded == true and ReplicatedSuite ~= nil and ReplicatedSuite.Observation ~= nil then
        return ReplicatedSuite.Observation:ReadField("professional:dps", actor, field, fetchFn, ttlMs)
    end
    return fetchFn()
end

function A:GetUnitName(unitToken)
    return SharedUnitRead("UnitName", unitToken, 250, function() local ok,value=InvokeOne("unit.unit_name",unitToken); return ok and value or nil end)
end

-- Roster layout discovery must distinguish an unsupported native unit-token
-- spelling (pcall=false) from a valid but currently empty team slot
-- (pcall=true, value=nil). The regular cached getter intentionally exposes only
-- the value, so discovery uses this narrow status-preserving read instead.
function A:TryGetUnitName(unitToken)
    return InvokeOne("unit.unit_name", unitToken)
end

function A:GetUnitNameWithWorld(unitToken)
    return SharedUnitRead("UnitNameWithWorld", unitToken, 250, function() local ok,value=InvokeOne("unit.unit_name_with_world",unitToken); return ok and value or nil end)
end

function A:GetUnitId(unitToken)
    return SharedUnitRead("GetUnitId", unitToken, 75, function() local ok,value=InvokeOne("unit.get_unit_id",unitToken); return ok and value or nil end)
end

function A:GetTargetUnitId()
    return SharedUnitRead("GetTargetUnitId", "target", 0, function() local ok,value=InvokeOne("unit.get_target_unit_id"); return ok and value or nil end)
end

function A:GetUnitNameById(stableId)
    return SharedUnitRead("GetUnitNameById", stableId, 1000, function() local ok,value=InvokeOne("unit.get_unit_name_by_id",stableId); return ok and value or nil end)
end

-- Official allowed API. Runtime consumers still parse the returned value
-- conservatively: only explicit unit/object type fields and known UO_* values
-- may become formal type evidence. Unknown layouts remain UNKNOWN.
function A:GetUnitInfoById(stableId)
    stableId=tostring(stableId or "")
    return SharedUnitRead("GetUnitInfoById", stableId, 250, function() local ok,value=InvokeOne("unit.get_unit_info_by_id",stableId); return ok and value or nil end)
end

function A:GetCurrentTargetRawSnapshot()
    if not self:Has("unit.unit_name") then return nil, nil, nil, nil end
    local idBefore = self:GetTargetUnitId()
    local name = self:GetUnitName("target")
    local idAfter = self:GetTargetUnitId()
    local stableId = nil
    if idBefore ~= nil and idAfter ~= nil and tostring(idBefore) == tostring(idAfter) then
        stableId = idAfter
    end
    return name, stableId, idBefore, idAfter
end

function A:GetWorldNameOptional()
    local ok, value = InvokeOne("world.current_world_name")
    return ok and value or nil
end

function A:IsFriendSoftPrior(characterName)
    if not self:Has("social.is_friend") then return false, "function unavailable" end
    return InvokeOne("social.is_friend", characterName)
end

function A:IsExpeditionMemberSoftPrior(characterName)
    if not self:Has("social.is_expedition_member") then return false, "function unavailable" end
    return InvokeOne("social.is_expedition_member", characterName)
end

function A:SampleUnitInfoForDiagnostics(unitToken, stableId)
    local infoOk, info = false, nil
    local modifierOk, modifier = false, nil
    local byIdOk, byId = false, nil
    if unitToken ~= nil and self:Has("unit.unit_info_diagnostic") then
        infoOk, info = InvokeOne("unit.unit_info_diagnostic", unitToken)
    end
    if unitToken ~= nil and self:Has("unit.unit_modifier_info_diagnostic") then
        modifierOk, modifier = InvokeOne("unit.unit_modifier_info_diagnostic", unitToken)
    end
    if stableId ~= nil and self:Has("unit.get_unit_info_by_id") then
        byIdOk, byId = InvokeOne("unit.get_unit_info_by_id", tostring(stableId))
    end
    return infoOk, info, modifierOk, modifier, byIdOk, byId
end

function A:GetPlayerDebuffCount()
    local ok, result = InvokeOne("unit.debuff_count", "player")
    if not ok then return 0 end
    return math.max(0, math.floor(tonumber(result) or 0))
end

function A:GetPlayerDebuffTooltip(index)
    local ok, result = InvokeOne("unit.debuff_tooltip", "player", index)
    if not ok then return nil end
    return result
end

function A:GetPlayerDebuffEntry(index)
    local ok, result = InvokeOne("unit.debuff_entry", "player", index)
    if not ok then return nil end
    return result
end

function A:GetContentMainScriptPosVis(contentId)
    return InvokeResults("addon.get_content_main_script_pos_vis", contentId)
end

function A:LoadData(key)
    return InvokeOne("addon.load_data", key)
end

function A:SaveData(key, value)
    return InvokeOne("addon.save_data", key, value)
end

function A:ClearData(key)
    return InvokeOne("addon.clear_data", key)
end

function A:WriteDebugLog(message)
    return InvokeOne("addon.chat_log", tostring(message))
end

function A:DispatchSystemMessage(filter, message)
    return InvokeOne("chat.dispatch_system", filter, tostring(message))
end

function A:RegisterContentWidget(contentId, widget)
    return InvokeOne("addon.register_content_widget", contentId, widget)
end

function A:RegisterContentTrigger(contentId, callback)
    return InvokeOne("addon.register_content_trigger", contentId, callback)
end

function A:AddEscMenuButton(categoryId, contentId, iconKey, name)
    return InvokeOne("addon.add_esc_menu_button", categoryId, contentId, iconKey, name)
end

function A:GetStatusLine()
    self:ProbeAll()
    local allowedPresent = 0
    local allowedTotal = 0
    for _, capability in pairs(self.capabilities) do
        if capability.contractStatus == self.ContractStatus.ALLOWED then
            allowedTotal = allowedTotal + 1
            if capability.functionPresent == true then allowedPresent = allowedPresent + 1 end
        end
    end
    local friend = self:Has("social.is_friend") and "可用" or "不可用"
    local expedition = self:Has("social.is_expedition_member") and "可用" or "不可用"
    return "API：公开 " .. tostring(allowedPresent) .. "/" .. tostring(allowedTotal)
        .. "；软先验 好友=" .. friend .. " 公会=" .. expedition
end

function A:FlushDiagnostics(diagnostics)
    if type(diagnostics) ~= "table" or type(diagnostics.AddInfo) ~= "function" then return end
    if self.diagnosticsFlushedGeneration == Boot.generation then return end
    self.diagnosticsFlushedGeneration = Boot.generation
    diagnostics:AddInfo("api", self:GetStatusLine())
end

Boot:CompletePhase("API_FACADE_READY")

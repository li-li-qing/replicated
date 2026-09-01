ReplicatedSuiteModuleSandbox:Enter('gear', {'ReplicatedGear', 'ReplicatedGearConfig'})
------------------------------------------------------------------------
-- Replicated Gear - Official API boundary
-- Only APIs marked Allowed in the supplied z_api_functions are used here.
------------------------------------------------------------------------

if ReplicatedGear == nil or ReplicatedGear.BootError ~= nil then return end
local G = ReplicatedGear

G.Api = {}
local A = G.Api

local function ValidateRequiredApis()
    local required = {
        { ADDON, "LoadData", "ADDON:LoadData" },
        { ADDON, "SaveData", "ADDON:SaveData" },
        { ADDON, "ClearData", "ADDON:ClearData" },
        { X2Unit, "UnitName", "X2Unit:UnitName" },
        { X2Unit, "UnitNameWithWorld", "X2Unit:UnitNameWithWorld" },
        { X2Equipment, "GetEquippedItemTooltipInfo", "X2Equipment:GetEquippedItemTooltipInfo" },
        { X2Equipment, "GetEquippedItemType", "X2Equipment:GetEquippedItemType" },
        { X2Bag, "GetBagItemInfo", "X2Bag:GetBagItemInfo" },
        { X2Bag, "EquipBagItem", "X2Bag:EquipBagItem" },
        { X2Player, "GetShowingAppellation", "X2Player:GetShowingAppellation" },
        { X2Player, "GetEffectAppellation", "X2Player:GetEffectAppellation" },
        { X2Player, "ChangeAppellation", "X2Player:ChangeAppellation" },
    }
    for _, entry in ipairs(required) do
        local object, methodName, label = entry[1], entry[2], entry[3]
        if object == nil or type(object[methodName]) ~= "function" then
            return false, tostring(label) .. " unavailable"
        end
    end
    return true
end

local apiOk, apiErr = ValidateRequiredApis()
if not apiOk then
    G.BootError = "api: " .. tostring(apiErr)
    G.SafeChat("API初始化失败：" .. tostring(apiErr))
    return
end

local function InvokeOne(object, methodName, ...)
    if object == nil then return false, nil, "object unavailable" end
    local method = object[methodName]
    if type(method) ~= "function" then return false, nil, methodName .. " unavailable" end
    local args = { ... }
    local argCount = select("#", ...)
    local ok, value = pcall(function() return method(object, unpack(args, 1, argCount)) end)
    if not ok then return false, nil, tostring(value) end
    return true, value, nil
end

local function InvokeAction(object, methodName, ...)
    local ok, value, err = InvokeOne(object, methodName, ...)
    if not ok then return false, err end
    -- ArcheRage APIs are inconsistent: some successful actions return nil,
    -- while an explicit boolean false is a real refusal/failure.
    if value == false then return false, methodName .. " returned false" end
    return true, value
end


function A:RegisterContentWidget(contentId, widget)
    return InvokeAction(ADDON, "RegisterContentWidget", contentId, widget)
end

function A:RegisterContentTrigger(contentId, callback)
    return InvokeAction(ADDON, "RegisterContentTriggerFunc", contentId, callback)
end

function A:AddEscMenuButton(categoryId, contentId, iconKey, name)
    return InvokeAction(ADDON, "AddEscMenuButton", categoryId, contentId, iconKey, name)
end

function A:LoadData(key)
    local ok, value, err = InvokeOne(ADDON, "LoadData", key)
    if not ok then return nil, err end
    return value, nil
end

function A:SaveData(key, value)
    return InvokeAction(ADDON, "SaveData", key, value)
end

function A:ClearData(key)
    return InvokeAction(ADDON, "ClearData", key)
end

function A:GetPlayerName()
    local ok, value, err = InvokeOne(X2Unit, "UnitName", "player")
    if not ok then return nil, err end
    return value, nil
end

function A:GetPlayerNameWithWorld()
    local ok, value, err = InvokeOne(X2Unit, "UnitNameWithWorld", "player")
    if not ok then return nil, err end
    return value, nil
end

function A:GetEquippedItemTooltipInfo(slot)
    local ok, value, err = InvokeOne(X2Equipment, "GetEquippedItemTooltipInfo", slot, true)
    if not ok then return nil, err end
    return value, nil
end

function A:GetEquippedItemType(slot)
    local ok, value, err = InvokeOne(X2Equipment, "GetEquippedItemType", slot)
    if not ok then return nil, err end
    return value, nil
end

function A:GetBagItemInfo(bagId, slot)
    local ok, value, err = InvokeOne(X2Bag, "GetBagItemInfo", bagId, slot)
    if not ok then return nil, err end
    return value, nil
end

function A:EquipBagItem(slot, isAuxEquip)
    return InvokeAction(X2Bag, "EquipBagItem", slot, isAuxEquip == true)
end

-- Community GearSwap-compatible raw action path.  The public ArcheRage
-- GearSwap does not interpret EquipBagItem's Lua return value; it simply issues
-- the action and later reconciles the equipped slots.  Keep that exact semantic
-- for weapon work so an explicit false/nil return cannot suppress the action
-- pipeline.  Only a Lua call error is treated as a dispatch failure here.
function A:EquipBagItemDirect(slot, isAuxEquip)
    if X2Bag == nil or type(X2Bag.EquipBagItem) ~= "function" then
        return false, nil, "EquipBagItem unavailable"
    end
    local ok, value = pcall(function()
        return X2Bag:EquipBagItem(slot, isAuxEquip == true)
    end)
    if not ok then return false, nil, tostring(value) end
    return true, value, nil
end

function A:GetShowingAppellation()
    local ok, value, err = InvokeOne(X2Player, "GetShowingAppellation")
    if not ok then return nil, err end
    return value, nil
end

function A:GetEffectAppellation()
    local ok, value, err = InvokeOne(X2Player, "GetEffectAppellation")
    if not ok then return nil, err end
    return value, nil
end

-- X2Player:PlayerInCombat() was enabled by ArcheRage on 2026-06-09.  It is used
-- to defer armor/accessory/title work that is documented as unavailable in combat.
-- The weapon compatibility path intentionally does not use this as a client-side
-- gate; the actual equipped slots remain the success Authority.
function A:IsPlayerInCombat()
    if X2Player == nil or type(X2Player.PlayerInCombat) ~= "function" then
        return false, "PlayerInCombat unavailable"
    end
    local ok, value, err = InvokeOne(X2Player, "PlayerInCombat")
    if not ok then return false, err end
    return value == true, nil
end

function A:ChangeAppellation(nameType, effectType)
    return InvokeAction(X2Player, "ChangeAppellation", nameType, effectType)
end

function A:Chat(message)
    G.SafeChat(message)
end

-- Replicated Suite Gear regression: a loadout where only costume and title differ
-- must reach both actions. This reproduces the .18.253 selector regression where
-- false made already-correct gear look mismatched, then costume verification never
-- succeeded and title (which intentionally runs after gear) was never reached.
local servicePath = (arg and arg[1]) or 'services/rs_gear_service_v3.lua'

ReplicatedSuite = {
    BootError = nil,
    Services = {},
    Utils = {
        Trim = function(v) return tostring(v or ''):match('^%s*(.-)%s*$') or '' end,
        DeepCopy = function(v)
            if type(v) ~= 'table' then return v end
            local out = {}; for k,x in pairs(v) do out[k] = x end; return out
        end,
    },
    Api = {},
    Events = { Publish = function() end },
    Scheduler = {},
}
local S = ReplicatedSuite
local now = 1000
S.NowMs = function() return now end
function S.Api:CallCapability(_, object, methodName, ...)
    if object == nil or type(object[methodName]) ~= 'function' then return false, nil, 'unavailable' end
    local ok, a, b, c = pcall(object[methodName], object, ...)
    if not ok then return false, nil, tostring(a) end
    return true, a, nil, b, c
end
function S.Api:IsCapabilityAllowed(_) return true end
function S.Scheduler:SetTaskModule() end
function S.Scheduler:AddTask(_, name, _, fn)
    S.Scheduler.name, S.Scheduler.fn = name, fn
    return true
end
function S.Scheduler:RemoveTask() self.fn = nil end

local equipped, bag = {}, {}
X2Equipment = {}
function X2Equipment:GetEquippedItemTooltipInfo(slot, targetEquippedItem)
    -- Historical Gear path: true is the selector that returns the player's gear
    -- in this observed client family; false reproduces the regression.
    if targetEquippedItem ~= true then return nil end
    return equipped[tonumber(slot)]
end
X2Bag = {}
function X2Bag:Capacity() return 40 end
function X2Bag:GetBagItemInfo(_, slot) return bag[tonumber(slot)] end
function X2Bag:EquipBagItem(slot)
    local item = bag[tonumber(slot)]
    if type(item) ~= 'table' then return false end
    equipped[28] = item
    return true
end
local currentEffect = 22
X2Player = {}
function X2Player:PlayerInCombat() return false end
function X2Player:GetShowingAppellation() return { 11, '展示称号' } end
function X2Player:GetEffectAppellation() return { currentEffect, '效果称号' .. tostring(currentEffect) } end
function X2Player:ChangeAppellation(_, effect)
    currentEffect = tonumber(effect) or effect
    return true
end

assert(dofile(servicePath) == nil)
local G = assert(S.Services.GearV3, 'GearV3 missing')
G:SetEnabled(true)

local payload = { configured = true, items = {}, title = {
    apply = true,
    showing = { id = 11, values = {11, '展示称号'} },
    effect = { id = 33, values = {33, '目标称号'} },
    displayName = '目标称号',
}}
for _, def in ipairs(G.EquipmentSlots) do
    local current = { name = '装备' .. tostring(def.slot), itemGrade = 5, itemType = 1000 + def.slot, icon = 'icon/' .. tostring(def.slot) }
    local wantedName = current.name
    if def.slot == 28 then
        current = { name = '旧时装', itemGrade = 5, itemType = 1028, icon = 'icon/costume_old' }
        wantedName = '新时装'
        bag[1] = { name = wantedName, itemGrade = 5, itemType = 2028, icon = 'icon/costume_new' }
    end
    equipped[def.slot] = current
    payload.items[#payload.items + 1] = {
        slot = def.slot, key = def.key, slotName = def.name, alternative = def.alternative == true,
        empty = false, managed = true, name = wantedName, grade = 5,
        itemType = def.slot == 28 and 2028 or current.itemType, modifierSignature = '',
    }
end

local ok, err = G:Start('costume-title-probe', payload)
assert(ok == true, tostring(err))
for _ = 1, 20 do
    if G.runtime.busy ~= true then break end
    now = now + 220
    G:RuntimeTick()
end
assert(G.runtime.busy == false, 'runtime did not finish')
assert(type(equipped[28]) == 'table' and equipped[28].name == '新时装',
    'FAIL: costume was not equipped')
assert(currentEffect == 33, 'FAIL: title action was never reached; current=' .. tostring(currentEffect))
assert(G.runtime.stage == 'DONE', 'FAIL: transaction ended as ' .. tostring(G.runtime.stage) .. ': ' .. tostring(G.runtime.message))
print('GEAR COSTUME/TITLE APPLY RESULT 3 passed / 0 failed')

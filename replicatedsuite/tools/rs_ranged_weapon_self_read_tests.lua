-- Development-only compatibility regression.
-- HUD/status reads and loadout-transaction reads intentionally have separate
-- selector contracts.  The .18.253 bug came from forcing one assumption onto
-- both domains.  Keep GetEquipped(false) for the HUD path; Gear transactions
-- use GetLoadoutEquipped(true), covered by the costume/title regressions.
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
    Events = nil,
}
local S = ReplicatedSuite
S.NowMs = function() return 1000 end
function S.Api:CallCapability(_, object, methodName, ...)
    if object == nil or type(object[methodName]) ~= 'function' then return false, nil, 'unavailable' end
    local ok, value = pcall(object[methodName], object, ...)
    if not ok then return false, nil, tostring(value) end
    return true, value, nil
end
function S.Api:IsCapabilityAllowed(_) return true end

local seen = {}
X2Equipment = {}
function X2Equipment:GetEquippedItemTooltipInfo(slot, targetEquippedItem)
    seen[#seen + 1] = { slot = tonumber(slot), selector = targetEquippedItem }
    if targetEquippedItem ~= false then return nil end
    return { name='Test Bow', icon='test/ranged.dds', itemGrade=4, itemType=1018 }
end
X2Bag = {}
function X2Bag:Capacity() return 40 end
function X2Bag:GetBagItemInfo() return nil end
X2Player = {}
function X2Player:PlayerInCombat() return false end
function X2Player:GetShowingAppellation() return {11, 'Show'} end
function X2Player:GetEffectAppellation() return {22, 'Effect'} end
function X2Player:ChangeAppellation() return true end

assert(dofile('services/rs_gear_service_v3.lua') == nil)
local G = assert(S.Services.GearV3, 'GearV3 unavailable')
local ranged, err = G:GetEquipped(18)
assert(err == nil, tostring(err))
assert(type(ranged) == 'table' and ranged.icon == 'test/ranged.dds', 'HUD self ranged slot was not returned')
assert(#seen == 1 and seen[1].slot == 18 and seen[1].selector == false,
    'HUD GetEquipped must keep its false-selector contract')
assert(type(G.GetLoadoutEquipped) == 'function', 'Gear loadout reader must be a separate API')
print('PASS HUD ranged read stays isolated from Gear loadout selector')

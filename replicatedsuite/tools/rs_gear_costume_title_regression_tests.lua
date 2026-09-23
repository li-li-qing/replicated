-- Replicated Suite regression: GearV3 must use the legacy-proven self-equipment
-- selector for loadout reconciliation.  If the selector is inverted, every
-- already-correct gear slot becomes a phantom mismatch; costume (slot 28) and
-- title are then pushed to the tail of a long transaction.
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
local now = 1000
S.NowMs = function() return now end
function S.Api:CallCapability(_, object, methodName, ...)
    if object == nil or type(object[methodName]) ~= 'function' then return false, nil, 'unavailable' end
    local ok, a, b, c = pcall(object[methodName], object, ...)
    if not ok then return false, nil, tostring(a) end
    return true, a, nil, b, c
end
function S.Api:IsCapabilityAllowed(_) return true end

local equipped = {}
local bag = {}
X2Equipment = {}
function X2Equipment:GetEquippedItemTooltipInfo(slot, targetEquippedItem)
    -- Model the behavior used by the previously working Gear implementation:
    -- the Gear self-equipment path passes true.  The .18.253 regression changed
    -- it to false, which makes this client family return no self tooltip.
    if targetEquippedItem ~= true then return nil end
    return equipped[tonumber(slot)]
end
X2Bag = {}
function X2Bag:Capacity() return 40 end
function X2Bag:GetBagItemInfo(_, slot) return bag[tonumber(slot)] end
function X2Bag:EquipBagItem(_, _) return true end
X2Player = {}
function X2Player:PlayerInCombat() return false end
function X2Player:GetShowingAppellation() return { 11, '当前展示称号' } end
function X2Player:GetEffectAppellation() return { 22, '当前效果称号' } end
function X2Player:ChangeAppellation(_, _) return true end

assert(dofile('services/rs_gear_service_v3.lua') == nil)
local G = assert(S.Services.GearV3, 'GearV3 missing')

local payload = { configured = true, items = {}, title = {
    apply = true,
    showing = { id = 11, values = { 11, '目标展示称号' } },
    effect = { id = 33, values = { 33, '目标效果称号' } },
    displayName = '目标效果称号',
}}
for index, def in ipairs(G.EquipmentSlots) do
    local row = { name = '装备' .. tostring(def.slot), itemGrade = 5, itemType = 1000 + def.slot, icon = 'icon/' .. tostring(def.slot) }
    equipped[def.slot] = row
    bag[index] = row
    payload.items[#payload.items + 1] = {
        slot = def.slot, key = def.key, slotName = def.name, alternative = def.alternative == true,
        empty = false, managed = true, name = row.name, grade = 5, itemType = row.itemType,
        modifierSignature = '',
    }
end

local costume = G:GetLoadoutEquipped(28)
assert(type(costume) == 'table' and costume.name == '装备28',
    'FAIL: GearV3 loadout selector lost costume slot 28')

local matched, mismatches = G:ValidatePayload(payload)
assert(matched == false, 'title is intentionally different in this probe')
assert(#mismatches == 1 and mismatches[1].slotName == '称号',
    'FAIL: already-equipped gear became phantom mismatches before title; count=' .. tostring(#mismatches))

local session = G:BuildSession('probe', payload, mismatches, { weaponOnly = false })
assert(#session.queue == 0, 'FAIL: phantom gear queue delays costume/title; queue=' .. tostring(#session.queue))
assert(session.titlePending == true, 'FAIL: title must remain the only pending action')

print('GEAR COSTUME/TITLE REGRESSION RESULT 4 passed / 0 failed')

-- Regression: an empty slot in an old loadout must become managed when
-- "获取当前" sees equipment there. A consciously unchecked occupied slot stays unchecked.
ReplicatedSuite = {
    BootError = nil,
    Services = {},
    Utils = {
        Trim = function(value) return tostring(value or ''):match('^%s*(.-)%s*$') end,
    },
    Api = {},
}
local S = ReplicatedSuite
S.NowMs = function() return 1000 end
function S.Api:CallCapability(_, object, method, ...)
    local ok, value = pcall(object[method], object, ...)
    if not ok then return false, nil, value end
    return true, value, nil
end

local equipped = {}
X2Equipment = {}
function X2Equipment:GetEquippedItemTooltipInfo(slot, selector)
    assert(selector == true, 'loadout selector changed')
    return equipped[slot]
end
X2Player = {
    GetEffectAppellation = function() return { 3, 'effect' } end,
    GetShowingAppellation = function() return { 2, 'showing' } end,
}

dofile('services/rs_gear_service_v3.lua')
local G = assert(S.Services.GearV3)
equipped[17] = { name = '测试副手', itemType = 17001, itemGrade = 5 }
equipped[16] = { name = '测试主手', itemType = 16001, itemGrade = 5 }

local previous = {
    configured = true,
    items = {
        { slot = 17, empty = true, managed = false },
        { slot = 16, empty = false, managed = false },
    },
}
local captured, err = G:CapturePayload(previous)
assert(captured, tostring(err))
local bySlot = {}
for _, item in ipairs(captured.items) do bySlot[item.slot] = item end
assert(bySlot[17].empty == false, 'equipped offhand lost')
assert(bySlot[17].managed == true, 'old empty offhand remained disabled after recapture')
assert(bySlot[17].itemType == 17001, 'offhand identity lost')
assert(bySlot[16].managed == false, 'explicitly unchecked occupied mainhand changed')
print('GEAR OFFHAND RECAPTURE RESULT 4 passed / 0 failed')

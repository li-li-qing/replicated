-- Replicated Suite GearV3 regression: a loadout owns only the title EFFECT.
-- Saved showing/name is a historical snapshot and must never be replayed.
-- nameType=0 is a valid "show no title" selector for ChangeAppellation.
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
}
local S = ReplicatedSuite
S.NowMs = function() return 1000 end
function S.Api:CallCapability(_, object, methodName, ...)
    if object == nil or type(object[methodName]) ~= 'function' then return false, nil, 'unavailable' end
    local ok, a, b, c = pcall(object[methodName], object, ...)
    if not ok then return false, nil, tostring(a) end
    return true, a, nil, b, c
end
function S.Api:IsCapabilityAllowed(_) return true end

X2Equipment = {}
X2Bag = {}
local currentEffect = 77
local currentShowingRaw = { 0, '' }
local lastNameType, lastEffectType = nil, nil
X2Player = {}
function X2Player:PlayerInCombat() return false end
function X2Player:GetShowingAppellation() return currentShowingRaw end
function X2Player:GetEffectAppellation() return { currentEffect, '效果' .. tostring(currentEffect) } end
function X2Player:ChangeAppellation(nameType, effectType)
    lastNameType, lastEffectType = nameType, effectType
    -- This deliberately rejects the stale save-time display title.  The current
    -- character is showing no title, represented by the valid selector 0.
    if tonumber(nameType) ~= 0 then return false end
    currentEffect = tonumber(effectType) or effectType
    return true
end

assert(dofile(servicePath) == nil)
local G = assert(S.Services.GearV3, 'GearV3 missing')
assert((tonumber(G.TitleEffectAuthorityContractVersion) or 0) >= 1, 'effect authority contract missing')

local payload = {
    configured = true,
    items = {},
    title = {
        apply = true,
        -- Intentionally mismatched/stale: this was the visible title at save time.
        showing = { id = 12345, name = '保存时展示称号A', values = { 12345, '保存时展示称号A' } },
        effect = { id = 88, name = '保存的效果称号B', values = { 88, '保存的效果称号B' } },
        displayName = '保存时展示称号A',
    },
}

-- UI text must represent the effect authority, not the saved display title.
assert(G:TitleText(payload.title) == '保存的效果称号B', 'FAIL: TitleText still prefers saved display title')

local ok, reason = G:ApplyTitle(payload)
assert(ok == true, 'FAIL: effect-only title apply failed: ' .. tostring(reason))
assert(lastNameType == 0, 'FAIL: valid current nameType=0 was replaced by stale saved showing: ' .. tostring(lastNameType))
assert(lastEffectType == 88, 'FAIL: wrong target effectType: ' .. tostring(lastEffectType))
assert(currentEffect == 88, 'FAIL: effect did not change')

-- A different current display title must also be preserved at execution time;
-- the saved showing=12345 remains non-authoritative.
currentEffect = 88
currentShowingRaw = { 456, '当前展示称号C' }
payload.title.effect.id = 99
payload.title.effect.name = '效果称号D'
lastNameType, lastEffectType = nil, nil
local ok2, reason2 = G:ApplyTitle(payload)
assert(ok2 == true, 'FAIL: current-display preservation failed: ' .. tostring(reason2))
assert(lastNameType == 456, 'FAIL: current display title was not preserved: ' .. tostring(lastNameType))
assert(lastEffectType == 99, 'FAIL: second effectType mismatch: ' .. tostring(lastEffectType))

-- Successful getter returning nil means no visible title; mirror the proven
-- titleswap behavior and use selector 0 instead of replaying saved showing.
currentEffect = 99
currentShowingRaw = nil
payload.title.effect.id = 111
lastNameType, lastEffectType = nil, nil
local ok3, reason3 = G:ApplyTitle(payload)
assert(ok3 == true, 'FAIL: nil showing should map to nameType=0: ' .. tostring(reason3))
assert(lastNameType == 0 and lastEffectType == 111, 'FAIL: nil showing fallback used stale save-time nameType')

-- Saving a scheme must remain possible when the non-authoritative display-title
-- getter is temporarily unavailable.  Effect capture is the only required title read.
local originalShowing = X2Player.GetShowingAppellation
X2Player.GetShowingAppellation = function() error('transient showing read failure') end
currentEffect = 222
local captured, captureErr = G:CaptureTitle()
assert(type(captured) == 'table', 'FAIL: effect capture was blocked by showing getter: ' .. tostring(captureErr))
assert(captured.apply == true and captured.effect and captured.effect.id == 222, 'FAIL: captured effect authority incorrect')
assert(captured.showing == nil, 'FAIL: failed showing read should remain non-authoritative nil snapshot')
X2Player.GetShowingAppellation = originalShowing

print('GEAR TITLE EFFECT AUTHORITY RESULT 12 passed / 0 failed')

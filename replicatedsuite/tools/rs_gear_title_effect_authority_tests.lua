------------------------------------------------------------------------
-- Replicated Suite · 称号效果归属测试
-- 作者：Replicated
-- QQ群：1104129461
--
-- GearV3 配装方案只管理称号效果。
-- 存档中的 showing/name 只是历史快照，不能重新应用；ChangeAppellation 的 nameType=0 合法表示不显示称号。
------------------------------------------------------------------------
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
    -- 故意拒绝保存时的过期显示称号；当前角色不显示称号，
    -- 由合法选择器 0 表示。
    -- 维护（2026-09-30）：每个场景允许“当前”展示名，包括后续456；拒绝保存时12345。
    -- 原替身硬编码只接受0，第二场景实际上拒绝了动作，却被生产层忽略false掩盖。
    local expectedNameType = type(currentShowingRaw) == "table" and tonumber(currentShowingRaw[1]) or 0
    if tonumber(nameType) ~= expectedNameType then return false end
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
        -- 故意提供不一致的旧显示称号，模拟保存时的历史快照。
        showing = { id = 12345, name = '保存时展示称号A', values = { 12345, '保存时展示称号A' } },
        effect = { id = 88, name = '保存的效果称号B', values = { 88, '保存的效果称号B' } },
        displayName = '保存时展示称号A',
    },
}

-- UI 文本必须反映称号效果，不能采用存档中的显示称号。
assert(G:TitleText(payload.title) == '保存的效果称号B', 'FAIL: TitleText still prefers saved display title')

local ok, reason = G:ApplyTitle(payload)
assert(ok == true, 'FAIL: effect-only title apply failed: ' .. tostring(reason))
assert(lastNameType == 0, 'FAIL: valid current nameType=0 was replaced by stale saved showing: ' .. tostring(lastNameType))
assert(lastEffectType == 88, 'FAIL: wrong target effectType: ' .. tostring(lastEffectType))
assert(currentEffect == 88, 'FAIL: effect did not change')

-- 执行时当前显示称号已变化也应保留；存档 showing=12345 不具有覆盖权。
currentEffect = 88
currentShowingRaw = { 456, '当前展示称号C' }
payload.title.effect.id = 99
payload.title.effect.name = '效果称号D'
lastNameType, lastEffectType = nil, nil
local ok2, reason2 = G:ApplyTitle(payload)
assert(ok2 == true, 'FAIL: current-display preservation failed: ' .. tostring(reason2))
assert(lastNameType == 456, 'FAIL: current display title was not preserved: ' .. tostring(lastNameType))
assert(lastEffectType == 99, 'FAIL: second effectType mismatch: ' .. tostring(lastEffectType))
assert(currentEffect == 99, 'FAIL: second title action did not apply')

-- Getter 成功返回 nil 表示没有显示称号；按已证明的 titleswap 行为使用选择器 0，不能重放存档 showing。
currentEffect = 99
currentShowingRaw = nil
payload.title.effect.id = 111
lastNameType, lastEffectType = nil, nil
local ok3, reason3 = G:ApplyTitle(payload)
assert(ok3 == true, 'FAIL: nil showing should map to nameType=0: ' .. tostring(reason3))
assert(lastNameType == 0 and lastEffectType == 111, 'FAIL: nil showing fallback used stale save-time nameType')

-- 非权威的显示称号 Getter 暂时不可用时仍应允许保存方案；唯一必需的称号读取是效果采集。
local originalShowing = X2Player.GetShowingAppellation
X2Player.GetShowingAppellation = function() error('transient showing read failure') end
currentEffect = 222
local captured, captureErr = G:CaptureTitle()
assert(type(captured) == 'table', 'FAIL: effect capture was blocked by showing getter: ' .. tostring(captureErr))
assert(captured.apply == true and captured.effect and captured.effect.id == 222, 'FAIL: captured effect authority incorrect')
assert(captured.showing == nil, 'FAIL: failed showing read should remain non-authoritative nil snapshot')
X2Player.GetShowingAppellation = originalShowing

print('GEAR TITLE EFFECT AUTHORITY: PASS')

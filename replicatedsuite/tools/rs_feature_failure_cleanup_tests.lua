------------------------------------------------------------------------
-- Replicated Suite · 启用失败清理回归
-- 作者：Replicated
-- QQ群：1104129461
-- 维护：生产 FeatureRuntime / Gear / Demand 承担被测事务，依赖仅注入可控失败。
-- 此文件不进 TOC、不读真实存档；验证失败后的释放和重试，不代表 RU 实机验收。
------------------------------------------------------------------------
local passed, failed = 0, 0
local function Test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then passed = passed + 1; print('PASS feature-failure-cleanup ' .. name)
    else failed = failed + 1; print('FAIL feature-failure-cleanup ' .. name .. ': ' .. tostring(err)) end
end
local function Copy(value)
    if type(value) ~= 'table' then return value end
    local out = {}; for key, item in pairs(value) do out[key] = Copy(item) end; return out
end
local function Boot()
    local S = { Generation = 1, SafeTraceback = debug.traceback, Utils = { DeepCopy = Copy }, Features = {}, Services = {} }
    ReplicatedSuite = S
    S.FeatureRegistry = { Get = function(_, id) return { id = id } end, IsAccessible = function() return true end }
    S.Persistence = { GetStore = function() return {} end }
    S.ApiImports = { Acquire = function() return true end }
    S.Events = { SubscribeInternal = function() return true end, UnsubscribeInternal = function() return true end,
        Publish = function() return true end }
    dofile('core/rs_demand.lua'); dofile('features/rs_feature_runtime.lua')
    return S, S.FeatureRuntime
end
Test('real Gear projection exception releases enabled service', function()
    local S, R = Boot(); local active = false
    S.Services.GearV3 = { SetEnabled = function(_, value) active = value; return true end }
    S.Features.Gear = { Commands = {}, EnsureIndexLoaded = function() return true end,
        Authority = { Refresh = function() error('injected projection failure') end } }
    dofile('features/combat/gear/rs_gear_feature.lua')
    local F = S.Features.Gear; R.state[F.Id].initialized = true
    local ok, err = R:Enable(F.Id, 'test')
    assert(ok == false and tostring(err):find('injected projection failure', 1, true))
    assert(not active and not F.enabled and not R:IsEnabled(F.Id), 'failed enable left Gear service running')
end)
-- 部分实现会先清局部 enabled 再报错；清理权不能依赖该布尔值，否则隐藏副作用无重试入口。
for _, throws in ipairs({ false, true }) do
    Test('failed enable cleans unflagged side effect ' .. tostring(throws), function()
        local _, R = Boot(); local active, stops = false, 0
        local F = { Initialize = function() return true end,
            Enable = function() active = true; if throws then error('enable failed') end; return false, 'enable failed' end,
            Disable = function(_, reason) assert(reason == 'startup_failure'); active = false; stops = stops + 1; return true end }
        assert(R:RegisterImplementation('probe', F)); assert(R:Enable('probe') == false)
        assert(not active and stops == 1, 'failure skipped implementation cleanup')
        assert(R.state.probe.faulted and R.state.probe.lastError:find('enable failed', 1, true))
    end)
end
Test('failed cleanup is visible and DisableAll retries even with both enabled flags false', function()
    local _, R = Boot(); local active, stops = false, 0
    local F = { Initialize = function() return true end,
        Enable = function() active = true; return false, 'enable failed' end,
        Disable = function() stops = stops + 1; if stops == 1 then return false, 'cleanup rejected' end; active = false; return true end }
    assert(R:RegisterImplementation('probe', F))
    local ok, err = R:Enable('probe')
    assert(ok == false and tostring(err):find('cleanup rejected', 1, true), 'cleanup failure hidden by initial failure')
    assert(active and R.state.probe.cleanupPending == true)
    assert(R:DisableAll('shutdown')); assert(not active and stops == 2 and not R.state.probe.cleanupPending)
end)
Test('retry enable first resolves unfinished cleanup', function()
    local _, R = Boot(); local starts, stops = 0, 0
    local F = { Initialize = function() return true end,
        Enable = function() starts = starts + 1; if starts == 1 then return false, 'enable failed' end; return true end,
        Disable = function() stops = stops + 1; if stops <= 2 then return false, 'cleanup blocked' end; return true end }
    assert(R:RegisterImplementation('probe', F)); assert(R:Enable('probe') == false)
    assert(R:Enable('probe') == false and starts == 1, 'new startup ran over unresolved cleanup')
    assert(R:Enable('probe') and starts == 2 and stops == 3)
end)
Test('healthy disabled implementation is not stopped again', function()
    local _, R = Boot(); local stops = 0
    local F = { Initialize = function() return true end, Enable = function() return true end,
        Disable = function() stops = stops + 1; return true end }
    assert(R:RegisterImplementation('probe', F)); assert(R:Disable('probe')); assert(stops == 0)
    assert(R:Enable('probe')); assert(R:Disable('probe')); assert(R:Disable('probe')); assert(stops == 1)
end)
-- 启动失败后实现可已自行清 enabled，Disable 也会提前返回；真实 Demand 的逆向失败仍必须收尾。
Test('real Healer failed demand rollback is quiesced before Enable returns', function()
    local S, R = Boot(); local roster, aura, stops = 0, 0, 0
    S.Services.TeamRosterV3 = { AcquireConsumer = function() roster = roster + 1; return true end,
        ReleaseConsumer = function() roster = roster - 1; return true end }
    S.Features.HealerAuraBridge = { ReadAccurate = function() end,
        Start = function() aura = aura + 1; return true end, Stop = function() aura = aura - 1; return true end }
    S.Features.Healer = { EnsureStoreLoaded = function() return true end, Roster = {}, Recommendation = {},
        HealthRuntime = { running = false, Start = function() return false, 'health start rejected' end,
            Stop = function() stops = stops + 1; if stops == 1 then return false, 'health stop rejected' end; return true end } }
    S.Events.UnsubscribeOwner = function() return true end
    dofile('features/combat/healer/rs_healer_feature.lua')
    local F = S.Features.Healer; assert(R:Enable(F.Id) == false)
    -- Health 从未启动，quiesce 不必再次 Stop；需要验证真实已持有的名单/光环租约均已释放。
    assert(roster == 0 and aura == 0 and stops >= 1 and F.Demand.needsQuiesce ~= true,
        'implementation early exit concealed failed Demand rollback')
end)
-- 实际 Native Authority 保存旧 CVar；故障模型只拒绝指定写入，不替换 Restore/Apply 算法。
local function BootNameplate(mode, restoreRejections)
    local S, R = Boot()
    local native = { name_tag_mark_size_ratio = 1, overhead_marker_fixed_size = 1, name_tag_hp_width = 70,
        name_tag_hp_height = 7, name_tag_hp_width_on_bgmode = 158, name_tag_hp_height_on_bgmode = 38 }
    local control = { restoreRejections = restoreRejections, applyRejected = false }
    S.Api = { CallCapability = function(_, _, _, _, name) return true, native[name] end,
        ActionCapability = function(_, _, _, _, name, value)
            value = tonumber(value)
            if name == 'name_tag_mark_size_ratio' and value == 1 and control.restoreRejections > 0 then
                control.restoreRejections = control.restoreRejections - 1; return false, 'restore rejected'
            end
            if mode == 'apply' and name == 'name_tag_hp_width' and value == 140 and not control.applyRejected then
                control.applyRejected = true; return false, 'apply rejected'
            end
            native[name] = value; return true
        end }
    S.Events.BindOwner = function() return true end
    S.Events.Subscribe = function() return false end
    S.Events.UnsubscribeOwner = function() return true end
    dofile('features/combat/nameplate_visuals/rs_nameplate_visuals_authority.lua')
    local F = S.Features.NameplateVisuals
    F.EnsureStoreLoaded = function() return true end
    F.GetSettings = function() return { markerWidth = 92, markerFixedSize = true,
        hpWidth = 140, hpHeight = 14, bgHpWidth = 200, bgHpHeight = 48 } end
    F.Authority.ReadSystemCfgSnapshot = function() return {}, nil end
    dofile('features/combat/nameplate_visuals/rs_nameplate_visuals_feature.lua')
    return S, R, F, native, control
end
for _, mode in ipairs({ 'subscription', 'apply' }) do
    Test('real Nameplate ' .. mode .. ' failure retains baseline until cleanup succeeds', function()
        local _, R, F, native = BootNameplate(mode, mode == 'apply' and 2 or 1)
        assert(R:Enable(F.Id) == false)
        assert(native.name_tag_mark_size_ratio == 1 and native.name_tag_hp_width == 70,
            'failed enable discarded the old Native values before successful restoration')
        assert(F.Authority.baseline == nil and not R.state[F.Id].cleanupPending)
    end)
end
Test('Nameplate persistent restoration failure remains retryable through DisableAll', function()
    local _, R, F, native, control = BootNameplate('subscription', 99)
    assert(R:Enable(F.Id) == false)
    assert(F.Authority.baseline ~= nil and R.state[F.Id].cleanupPending, 'lost unresolved Native restoration obligation')
    control.restoreRejections = 0
    assert(R:DisableAll('shutdown')); assert(native.name_tag_mark_size_ratio == 1)
    assert(F.Authority.baseline == nil and not R.state[F.Id].cleanupPending)
end)
print('FEATURE FAILURE CLEANUP RESULT ' .. passed .. ' passed / ' .. failed .. ' failed (' .. _VERSION .. ')')
if failed > 0 then error('feature failure cleanup failures: ' .. failed) end

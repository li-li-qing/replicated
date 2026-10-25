-- Replicated Suite · DPS 下游租约清理回归
-- 使用真实 Demand、FeatureRuntime、Analytics 与 DPS；仅替代 Native Bus 和关系服务的失败边界。
-- 本文件不进 TOC，不访问真实 UDF；失败释放不能丢失重试凭证，也不能误清其它 Owner。
local passed, failed = 0, 0
local function Test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then passed = passed + 1; print('PASS dps-dependency-cleanup ' .. name)
    else failed = failed + 1; print('FAIL dps-dependency-cleanup ' .. name .. ': ' .. tostring(err)) end
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
    S.Events = { SubscribeInternal = function() return true end, UnsubscribeInternal = function() return true end,
        Publish = function() return true end }
    dofile('core/rs_demand.lua'); dofile('features/rs_feature_runtime.lua')
    local controls = { busFailure = false, relationFailure = false, busReleases = 0, relationReleases = 0 }
    S.Services.CombatEventBusV3 = { Subscribe = function() return true end,
        Unsubscribe = function()
            controls.busReleases = controls.busReleases + 1
            -- Native 释放栈可能同步回入上游；回归沿真实 Demand 的忙碌窗口触发，不手工伪造标志。
            if type(controls.busOnRelease) == 'function' then controls.busOnRelease() end
            if controls.busFailure then return false, 'injected native release failure' end
            return true
        end }
    local relation = {}
    relation.demand = assert(S.Demand:Create({ id = 'test.combat_relation', owner = relation,
        reconcile = function(_, before, after)
            if before.consumers.dps ~= nil and after.consumers.dps == nil then
                controls.relationReleases = controls.relationReleases + 1
                if controls.relationFailure then return false, 'injected relation release failure' end
            end
            return true
        end }))
    function relation:AcquireConsumer(token, options) return self.demand:Acquire(token, options) end
    function relation:ReleaseConsumer(token) return self.demand:Release(token) end
    S.Services.CombatRelationV3 = relation
    dofile('services/rs_combat_analytics_v3.lua')
    local analytics = S.Services.CombatAnalyticsV3
    analytics:SetStatisticsPolicy(function() return { metrics = { 'dps_core' }, scope = 'self' } end)
    S.Features.DPS = { EnsureStoreLoaded = function() return true end, Domain = { ResetTransient = function() return true end } }
    dofile('features/combat/dps/rs_dps_feature.lua')
    assert(S.FeatureRuntime:Enable('combat_stats', 'test'))
    return S, S.FeatureRuntime, S.Features.DPS, analytics, relation, controls
end

-- 回归目标：第一次 quiesce 失败后不得清掉 held，第二次清理必须再次触达真实 Analytics 租约。
Test('failed analytics release remains retryable', function()
    local _, runtime, feature, analytics, relation, controls = Boot()
    controls.busFailure = true
    assert(runtime:DisableAll('test_shutdown') == false)
    assert(feature.analyticsHeld == true, 'failed release erased analytics retry ownership')
    assert(analytics:HasConsumer('dps_core') and feature.Demand.needsQuiesce)
    assert(not relation.demand:Has('dps'), 'independent relation cleanup must still run')
    local before = controls.busReleases
    controls.busFailure = false
    assert(runtime:Disable('combat_stats', 'retry'))
    assert(controls.busReleases > before, 'retry never reached the retained native resource')
    assert(not analytics:HasConsumer('dps_core') and not analytics.busSubscribed)
    assert(not feature.analyticsHeld and not feature.Demand.needsQuiesce and not runtime:IsEnabled('combat_stats'))
end)

-- 回归目标：关系租约释放失败与 Analytics 释放失败必须各自保留凭证，不能靠统一清布尔值冒充静默。
Test('failed relation release remains retryable', function()
    local _, runtime, feature, analytics, relation, controls = Boot()
    controls.relationFailure = true
    assert(runtime:DisableAll('test_shutdown') == false)
    assert(feature.relationHeld == true, 'failed release erased relation retry ownership')
    assert(relation.demand:Has('dps') and feature.Demand.needsQuiesce)
    assert(not analytics:HasConsumer('dps_core'), 'independent analytics cleanup must still run')
    local before = controls.relationReleases
    controls.relationFailure = false
    assert(runtime:Disable('combat_stats', 'retry'))
    assert(controls.relationReleases > before and not relation.demand:Has('dps'))
    assert(not feature.relationHeld and not feature.Demand.needsQuiesce)
end)

-- 回归目标：Core 已撤销本 Owner 时只对齐对应标志，不能释放共享服务上其它消费者。
Test('confirmed absent dependencies preserve other owners', function()
    local _, _, feature, analytics, relation = Boot()
    assert(analytics:AcquireConsumer('other_analytics', { metrics = { 'dps_core' } }))
    assert(relation:AcquireConsumer('other_relation', {}))
    assert(analytics:ReleaseConsumer('dps_core'))
    assert(relation:ReleaseConsumer('dps'))
    assert((feature.Demand:ForceQuiesce('dependencies_already_cleared')), 'confirmed absent dependency prevented cleanup')
    assert(not feature.analyticsHeld and not feature.relationHeld and not feature.Demand.needsQuiesce)
    assert(analytics:HasConsumer('other_analytics') and analytics.busSubscribed)
    assert(relation.demand:Has('other_relation'))
end)

-- 回归目标：缺少查询能力或返回未知不能被当成 Has=false，失败后必须继续保留需要释放的 Owner。
for _, evidence in ipairs({ 'missing', 'unknown', 'throws' }) do
    Test('unknown analytics membership keeps failed release ' .. evidence, function()
        local _, _, feature, analytics = Boot()
        analytics.Demand = nil
        analytics.HasConsumer = function()
            if evidence == 'throws' then error('injected membership failure') end
            return nil
        end
        if evidence == 'missing' then analytics.HasConsumer = nil end
        analytics.ReleaseConsumer = function() return false, 'injected unknown release failure' end
        assert(feature.Demand:ForceQuiesce('test') == false)
        assert(feature.analyticsHeld == true and feature.Demand.needsQuiesce)
    end)
end

-- 回归目标：空 token 只是消费者意图已撤销；下游仍明确 needsQuiesce 时不能吞掉资源故障。
Test('absent token with pending dependency cleanup stays failed', function()
    local _, _, feature, analytics, _, controls = Boot()
    controls.busFailure = true
    assert(analytics.Demand:ForceQuiesce('native_failure') == false)
    assert(not analytics:HasConsumer('dps_core') and analytics.Demand.needsQuiesce)
    assert(feature.Demand:ForceQuiesce('retry') == false)
    assert(feature.analyticsHeld and feature.Demand.needsQuiesce)
end)

-- 回归目标：Release 的临时 Has=false 尚未提交；内层静默必须失败并保留 held，外层回滚后仍能真正释放。
Test('transitioning dependency cannot confirm provisional absence', function()
    local _, _, feature, analytics, _, controls = Boot()
    local nestedResult
    controls.busFailure = true
    controls.busOnRelease = function()
        assert(analytics.Demand.transitioning and not analytics:HasConsumer('dps_core'))
        nestedResult = feature.Demand:ForceQuiesce('inside_analytics_release')
    end
    assert(analytics:ReleaseConsumer('dps_core') == false)
    assert(nestedResult == false, 'in-flight Has=false was accepted as committed release')
    assert(feature.analyticsHeld and feature.Demand.needsQuiesce and analytics:HasConsumer('dps_core'))
    controls.busOnRelease, controls.busFailure = nil, false
    assert((feature.Demand:Clear('retry_after_rollback')), 'settled rollback could not be retried')
    assert(not feature.analyticsHeld and not analytics:HasConsumer('dps_core') and not analytics.busSubscribed)
end)

-- 回归目标：意图先撤销再静默时，quiescing 内的 Has=false 仍非最终资源结算，不能吞掉即将返回的释放失败。
Test('quiescing dependency cannot confirm provisional absence', function()
    local _, _, feature, analytics, _, controls = Boot()
    assert(analytics.Demand:ForceClear())
    local nestedResult
    controls.busFailure = true
    controls.busOnRelease = function()
        assert(analytics.Demand.quiescing and not analytics:HasConsumer('dps_core'))
        nestedResult = feature.Demand:ForceQuiesce('inside_analytics_quiesce')
    end
    assert(analytics.Demand:ForceQuiesce('native_quiesce') == false)
    assert(nestedResult == false, 'unfinished quiesce was accepted as committed release')
    assert(feature.analyticsHeld and feature.Demand.needsQuiesce and analytics.Demand.needsQuiesce)
    controls.busOnRelease, controls.busFailure = nil, false
    assert((analytics.Demand:Clear('dependency_retry')), 'dependency quiesce could not be retried')
    assert((feature.Demand:Clear('owner_retry')), 'confirmed settled dependency could not be aligned')
    assert(not feature.analyticsHeld and not analytics.busSubscribed and not feature.Demand.needsQuiesce)
end)

print('DPS_DEPENDENCY_CLEANUP_TESTS ' .. (failed == 0 and 'PASS' or 'FAIL') .. ' passed=' .. passed .. ' failed=' .. failed)
if failed > 0 then os.exit(1) end

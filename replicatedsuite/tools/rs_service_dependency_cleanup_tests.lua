------------------------------------------------------------------------
-- Replicated Suite · 共享服务依赖释放失败回归
-- 中文维护注释：加载真实 Demand/Events/Scheduler 与三层任务服务，只替代原生只读 getter；
-- 用实际重入拒绝和故障子租约证明释放失败不会丢 held，且全局已静默的子 token 可以安全重试。
-- 不加载 Persistence、不读取真实 UDF；不进入 toc.g。
------------------------------------------------------------------------
local passed, failed = 0, 0
local function Test(name, callback)
    local ok, err = xpcall(callback, debug.traceback)
    if ok then passed=passed+1; print('PASS service-dependency-cleanup '..name)
    else failed=failed+1; print('FAIL service-dependency-cleanup '..name..': '..tostring(err)) end
end
local function Equal(actual, expected, message)
    assert(actual==expected, (message or 'unexpected value')..': expected '..tostring(expected)..', got '..tostring(actual))
end
local function Copy(value)
    if type(value)~='table' then return value end
    local out={};for key,item in pairs(value) do out[key]=Copy(item) end;return out
end
local function Boot()
    -- 中文维护注释：空的已就绪原生目录足以让真实 Start/Stop 分配和释放任务，避免用伪服务代替被测生命周期。
    ReplicatedSuite={Generation=1,Services={},Data={},Utils={DeepCopy=Copy},
        NowMs=function() return 1000 end,SafeTraceback=debug.traceback,Api={}}
    local S=ReplicatedSuite
    function S.Api:IsCapabilityAllowed() return true end
    function S.Api:CallCapability(_,host,method,...)
        if type(host)~='table' or type(host[method])~='function' then return false end
        return pcall(host[method],host,...)
    end
    X2Quest={GetActiveQuestListCount=function() return 0 end}
    X2BattleField={GetInstanceUiKindList=function() return {} end,
        GetInstanceListByKind=function() return {} end,GetDetailInstanceInfo=function() return {} end}
    dofile('core/rs_demand.lua')
    dofile('core/rs_scheduler.lua')
    dofile('core/rs_events.lua')
    dofile('services/rs_instance_catalog_v3.lua')
    dofile('services/rs_quest_progress_v3.lua')
    -- 中文维护注释：本测试无任何配方，不替换任务事实或租约；Identity 只需满足空列表投影的依赖边界。
    S.Services.TradeMaterialIdentityV3={ResolveStatic=function() return nil end}
    dofile('services/rs_daily_auction_materials_v3.lua')
    return S,S.Services.DailyAuctionMaterialsV3,S.Services.QuestProgressV3,S.Services.InstanceCatalogV3
end
local function AssertQuiet(S,service)
    Equal(service.consumerCount,0)
    Equal(service.running,false)
    Equal(S.Scheduler.tasks[service.safetyTask],nil,'last consumer leaked safety polling')
end

Test('healthy daily consumers release quest only after the last consumer',function()
    local S,D,P=Boot()
    assert(D:AcquireConsumer('one'));assert(D:AcquireConsumer('two'))
    assert(D:ReleaseConsumer('one'));Equal(P.consumerCount,1);Equal(P.running,true)
    assert(D:ReleaseConsumer('two'));Equal(D.questHeld,false);AssertQuiet(S,P)
    Equal(D:ReleaseConsumer('two'),false)
end)

Test('daily release rejected by a real quest transition preserves its retryable lease',function()
    local S,D,P=Boot();assert(D:AcquireConsumer('sidecar'))
    local observer, released={},nil
    S.Events:SubscribeInternal('v3.quest_progress.refreshed',observer,function()
        released=D:ReleaseConsumer('sidecar')
    end)
    assert(P:AcquireConsumer('other',{instances=false}))
    S.Events:UnsubscribeInternalOwner(observer)
    Equal(released,false,'downstream transition rejection was concealed')
    Equal(D.consumerCount,1);Equal(D.questHeld,true);Equal(P.Demand:Has(D.questConsumerToken),true)
    assert(P:ReleaseConsumer('other'));assert(D:ReleaseConsumer('sidecar'));AssertQuiet(S,P)
end)

Test('daily quiesce failure stays visible at count zero and clears on retry',function()
    local S,D,P=Boot();assert(D:AcquireConsumer('sidecar'))
    local observer, quiesced={},nil
    S.Events:SubscribeInternal('v3.quest_progress.refreshed',observer,function()
        quiesced=D.Demand:ForceQuiesce('reentrant_shutdown')
    end)
    assert(P:AcquireConsumer('other',{instances=false}))
    S.Events:UnsubscribeInternalOwner(observer)
    Equal(quiesced,false);Equal(D.consumerCount,0);Equal(D.questHeld,true);Equal(D.Demand.needsQuiesce,true)
    assert(P:ReleaseConsumer('other'));Equal(P.consumerCount,1)
    assert(D.Demand:Clear('retry'));Equal(D.questHeld,false);Equal(D.Demand.needsQuiesce,false);AssertQuiet(S,P)
end)

for _,missing in ipairs({'service','release_method'}) do
    Test('daily missing quest '..missing..' cannot acknowledge cleanup',function()
        local S,D,P=Boot();assert(D:AcquireConsumer('sidecar'))
        local release=P.ReleaseConsumer
        if missing=='service' then S.Services.QuestProgressV3=nil else P.ReleaseConsumer=nil end
        Equal(D.Demand:ForceQuiesce('dependency_unavailable'),false)
        Equal(D.questHeld,true);Equal(D.Demand.needsQuiesce,true);Equal(P.consumerCount,1)
        S.Services.QuestProgressV3=P;P.ReleaseConsumer=release
        assert(D.Demand:Clear('dependency_restored'));AssertQuiet(S,P)
    end)
end

Test('daily unknown release failure without child demand proof remains a failure',function()
    local S,D,P=Boot();assert(D:AcquireConsumer('sidecar'))
    S.Services.QuestProgressV3={ReleaseConsumer=function() return false,'unknown cleanup failure' end}
    Equal(D.Demand:ForceQuiesce('unknown_failure'),false);Equal(D.questHeld,true)
    S.Services.QuestProgressV3=P
    assert(D.Demand:Clear('restored'));AssertQuiet(S,P)
end)

Test('daily recognizes its already quiesced child token without dropping other consumers',function()
    local S,D,P=Boot();assert(D:AcquireConsumer('sidecar'))
    assert(P.Demand:ForceQuiesce('global_child_cleanup'));AssertQuiet(S,P)
    assert(P:AcquireConsumer('other',{instances=false}))
    assert(D.Demand:ForceQuiesce('parent_retry'));Equal(D.questHeld,false)
    Equal(P.consumerCount,1);Equal(P.Demand:Has('other'),true)
    assert(P:ReleaseConsumer('other'));AssertQuiet(S,P)
end)

Test('daily child with no token but failed quiesce cannot be declared released',function()
    local S,D,P=Boot();assert(D:AcquireConsumer('sidecar'))
    local quiesce=P.Demand.quiesce
    P.Demand.quiesce=function() return false,'injected child cleanup failure' end
    Equal(P.Demand:ForceQuiesce('child_failed'),false)
    Equal(D.Demand:ForceQuiesce('parent_retry'),false);Equal(D.questHeld,true)
    P.Demand.quiesce=quiesce;assert(P.Demand:Clear('child_recovered'))
    assert(D.Demand:Clear('parent_recovered'));Equal(D.questHeld,false);AssertQuiet(S,P)
end)

for _,busy in ipairs({'transition','quiesce'}) do
    Test('daily missing child token during '..busy..' is not confirmed cleanup',function()
        local S,D,P=Boot();assert(D:AcquireConsumer('sidecar'))
        assert(P.Demand:ForceQuiesce('global_child_cleanup'))
        local quiesced
        -- 中文维护注释：Has=false 必须与已结算状态一起使用；这些真实重入窗口不能被当成子层已静默。
        if busy=='transition' then
            local observer={}
            S.Events:SubscribeInternal('v3.quest_progress.refreshed',observer,function()
                quiesced=D.Demand:ForceQuiesce('parent_busy_retry')
            end)
            assert(P:AcquireConsumer('other',{instances=false}))
            S.Events:UnsubscribeInternalOwner(observer)
        else
            local quiesce=P.Demand.quiesce
            P.Demand.quiesce=function(...)
                quiesced=D.Demand:ForceQuiesce('parent_busy_retry')
                return quiesce(...)
            end
            assert(P.Demand:ForceQuiesce('empty_child_retry'))
            P.Demand.quiesce=quiesce
        end
        Equal(quiesced,false);Equal(D.questHeld,true);Equal(D.Demand.needsQuiesce,true)
        assert(D.Demand:Clear('parent_settled_retry'));Equal(D.questHeld,false)
        if busy=='transition' then Equal(P.consumerCount,1);assert(P:ReleaseConsumer('other')) end
        AssertQuiet(S,P)
    end)
end

Test('quest retries after global cleanup already removed its instance token',function()
    local S,D,P,C=Boot();assert(P:AcquireConsumer('activity',{instances=true}))
    -- 中文维护注释：只注入子 Demand 正反事务拒绝，保留 Catalog 的真实 quiesce/Stop 和资源释放。
    local reconcile, reject=C.Demand.reconcile,true
    C.Demand.reconcile=function(...)
        if reject then return false,'injected instance transition failure' end
        return reconcile(...)
    end
    Equal(S.Demand:ClearAll('first_shutdown'),false)
    Equal(P.consumerCount,0);Equal(P.Demand.needsQuiesce,true);Equal(P.instanceConsumerHeld,true)
    Equal(C.Demand:Has(P.instanceConsumerToken),false);Equal(C.Demand.needsQuiesce,false);AssertQuiet(S,C)
    reject=false
    Equal(S.Demand:ClearAll('retry_shutdown'),true,'parent could not recognize globally released child token')
    Equal(P.instanceConsumerHeld,false);Equal(P.Demand.needsQuiesce,false);AssertQuiet(S,P)
    assert(P:AcquireConsumer('recovered_activity',{instances=true}))
    assert(P:ReleaseConsumer('recovered_activity'));AssertQuiet(S,P);AssertQuiet(S,C)
end)

Test('quest recognizing a globally cleared token preserves unrelated instance demand',function()
    local S,D,P,C=Boot();assert(P:AcquireConsumer('activity',{instances=true}))
    assert(C.Demand:ForceQuiesce('global_child_cleanup'));assert(C:AcquireConsumer('other'))
    assert(P.Demand:ForceQuiesce('parent_retry'));Equal(P.instanceConsumerHeld,false)
    Equal(C.consumerCount,1);Equal(C.Demand:Has('other'),true);Equal(C.running,true)
    assert(C:ReleaseConsumer('other'));AssertQuiet(S,C);AssertQuiet(S,P)
end)

for _,missing in ipairs({'service','release_method'}) do
    Test('quest missing instance '..missing..' cannot acknowledge cleanup',function()
        local S,D,P,C=Boot();assert(P:AcquireConsumer('activity',{instances=true}))
        local release=C.ReleaseConsumer
        if missing=='service' then S.Services.InstanceCatalogV3=nil else C.ReleaseConsumer=nil end
        Equal(P.Demand:ForceQuiesce('dependency_unavailable'),false)
        Equal(P.instanceConsumerHeld,true);Equal(P.Demand.needsQuiesce,true);Equal(C.consumerCount,1)
        S.Services.InstanceCatalogV3=C;C.ReleaseConsumer=release
        assert(P.Demand:Clear('dependency_restored'));AssertQuiet(S,P);AssertQuiet(S,C)
    end)
end

Test('quest child with no token but failed quiesce cannot be declared released',function()
    local S,D,P,C=Boot();assert(P:AcquireConsumer('activity',{instances=true}))
    local quiesce=C.Demand.quiesce
    C.Demand.quiesce=function() return false,'injected instance cleanup failure' end
    Equal(C.Demand:ForceQuiesce('child_failed'),false)
    Equal(P.Demand:ForceQuiesce('parent_retry'),false);Equal(P.instanceConsumerHeld,true)
    C.Demand.quiesce=quiesce;assert(C.Demand:Clear('child_recovered'))
    Equal(P.Demand:Clear('parent_recovered'),true,'recovered child left parent permanently faulted')
    Equal(P.instanceConsumerHeld,false);AssertQuiet(S,P);AssertQuiet(S,C)
end)

print(string.format('SERVICE DEPENDENCY CLEANUP RESULT %d passed / %d failed (Lua %s)',passed,failed,_VERSION))
if failed>0 then error('service dependency cleanup failures: '..failed) end

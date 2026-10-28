-- Feature 的真实 Store/Scheduler 回归；job 桩仅证明生命周期契约，不证明求解算法。
local passed,failed=0,0
local TASK='tools_craft_plan_compare'
local function Test(name,fn)
    local ok,why=xpcall(fn,debug.traceback)
    if ok then passed=passed+1;print('PASS craft-compare-feature '..name)
    else failed=failed+1;print('FAIL craft-compare-feature '..name..': '..tostring(why))end
end
local function Boot(disk,realSolver)
    local h=dofile('tools/rs_gear_page_test_host.lua')({disk=disk});local S=h.S
    dofile('core/rs_demand.lua');dofile('features/shared/rs_shared_bounds.lua');dofile('features/shared/rs_feature_slice_factory.lua')
    dofile('features/tools/craft/rs_craft_feature.lua');dofile('features/tools/craft/rs_craft_plan_domain.lua')
    local D=S.CraftPlanDomain
    h.jobs={};h.priceRevision=1
    if realSolver then dofile('features/tools/craft/rs_craft_plan_solver.lua') else
    D.Compare=D.Compare or function()return {recommendation={available=false}}end
    -- 求解器尚在并行实施。这里让任务需多个调度块，断言真实 Feature 的保存/失效/发布行为。
    D.CreateCompareJob=function(plan,facts)
        local job={plan=D.Copy(plan),facts=D.Copy(facts),status='searching',states=0};h.jobs[#h.jobs+1]=job;return job
    end
    D.StepCompareJob=function(job,units)
        assert(units>=1 and units<=200);job.states=job.states+units
        if job.states>=400 then job.status='completed' end
        h.softMs=(h.softMs or 0)+1
        return job.status,units
    end
    D.GetCompareSnapshot=function(job)
        local ready=job.status=='completed'
        return {status=job.status,states=job.states,result={recommendations={
            cash={objective='cash',available=ready,allocations={['1:0:*']={mode='buy'}}},
            combined={objective='combined',available=ready,allocations={['1:0:*']={mode='craft'}}}}}}
    end
    D.PauseCompareJob=function(job,why)job.status='paused';job.reason=why;return true end
    D.ResumeCompareJob=function(job)job.status='searching';return true end
    D.CancelCompareJob=function(job,why)job.status='cancelled';job.reason=why;return true end
    end
    S.Services.MaterialPriceServiceV3={GetRevision=function()return h.priceRevision end,
        GetPrice=function(_,id)return id==1 and realSolver and 300 or 100,{freshness=realSolver and 'fresh' or 'stale',source='saved'} end,Topic='test_price'}
    dofile('features/tools/craft/rs_craft_plan_feature.lua')
    h.F=S.Features.tools_craft;h.C=h.F.Commands;h.F.enabled=true;h.F.consumerCount=1;h.F.ReadPlanRecipeTypes=nil
    h.F.ReadPlanRecipe=function(_,id)return {id=tostring(id),product={itemType=1,grade=0,count=1,name='合成产物'},
        labor=16,feeCopper=0,materials={{itemType=2,grade=0,count=1,name='合成原料'}}}end
    h.projection=function()return h.F:GetProjection().plan end
    h.run=function()S.Scheduler:RunTask(TASK)end
    h.finish=function()for _=1,4 do if not S.Scheduler:GetTaskState(TASK).registered then break end;h.run()end end
    return h
end
local function Ready(h)assert(h.C:RecipeImportLink('|if11;合成产物|r',1));h.projection()end
local function CompleteInventory(h)
    h.S.ApiImports={Acquire=function()return true end}
    h.S.Features.tools_bag={GetStorageWindowContext=function()return {status='ready',visible=true}end}
    h.S.Services.InventorySnapshotV3={BuildSnapshot=function()return {capacity=10,readErrors=0,unknown=0,fallback=0,rows={}}end}
    assert(h.C:PlanRefreshInventory(true))
end
Test('progress preserves input revision and publishes a detached envelope',function()
    local h=Boot();Ready(h);local rev=h.projection().revision
    local ok,e=h.C:PlanCompare();assert(ok and e.status=='searching','compare must start an asynchronous job')
    assert(h.S.Scheduler:GetTaskState(TASK).registered,'compare must use the real scheduler')
    h.run();local p=h.projection();assert(p.revision==rev and p.comparison.states==200,'progress cannot invalidate itself')
    p.comparison.states=999;assert(h.projection().comparison.states==200)
    h.finish();assert(h.projection().comparison.status=='completed')
end)
Test('comparison progress reuses the plan evaluation while public snapshots stay detached',function()
    local h=Boot();Ready(h);local before=h.projection();local calls=0
    local evaluate=h.S.CraftPlanDomain.Evaluate
    h.S.CraftPlanDomain.Evaluate=function(...)calls=calls+1;return evaluate(...)end
    assert(h.C:PlanCompare());h.run()
    local progress=h.projection()
    assert(calls==0,'search progress recomputed the unchanged current allocation')
    assert(progress.revision==before.revision and progress.comparison.states==200)
    progress.evaluation.rows[1].demand=999
    progress.comparison.states=999
    assert(h.projection().evaluation.rows[1].demand==1 and h.projection().comparison.states==200)
    local light=h.F:GetPlanComparisonProjection();assert(light.revision==before.revision and light.comparison.states==200)
    light.comparison.states=123;assert(h.F:GetPlanComparisonProjection().comparison.states==200)
    assert(calls==0,'the lightweight comparison projection evaluated materials')
    h.priceRevision=h.priceRevision+1
    local invalid=h.F:GetPlanComparisonProjection()
    assert(invalid.revision~=before.revision and not invalid.comparison and h.jobs[1].status=='cancelled')
    assert(calls==0,'price invalidation must not synchronously rebuild the plan')
    h.projection();assert(calls==1,'changed facts must still refresh the current evaluation')
end)
Test('wall pause continues the same snapshot and cancel and restart retire old work',function()
    local h=Boot();Ready(h);assert(h.C:PlanCompare());local first=h.jobs[1]
    h.ms=h.ms+10000;h.run();assert(h.projection().comparison.status=='paused' and first.states==0)
    assert(h.C:PlanContinueCompare());h.run();assert(first.states==200)
    assert(h.C:PlanCancelCompare());assert(first.status=='cancelled' and not h.S.Scheduler:GetTaskState(TASK).registered)
    assert(h.C:PlanCompare());local second=h.jobs[2];assert(h.C:PlanCompare());assert(second.status=='cancelled')
end)
Test('a price revision rejects completed advice and stops pending work',function()
    local h=Boot();Ready(h);local _,e=h.C:PlanCompare();h.finish()
    h.priceRevision=2;assert(not h.C:PlanApplyRecommendation(e.revision,nil,'cash'))
    assert(h.C:PlanCompare());local job=h.jobs[2];h.priceRevision=3;h.run()
    assert(job.status=='cancelled' and not h.S.Scheduler:GetTaskState(TASK).registered)
end)
Test('explicit objectives apply separately and undo survives a rejected save',function()
    local h=Boot();Ready(h)
    for _,objective in ipairs({'cash','combined'})do
        local _,e=h.C:PlanCompare();h.finish();assert(h.C:PlanApplyRecommendation(e.revision,nil,objective))
        assert(h.projection().allocations['1:0:*'].mode==(objective=='cash' and 'buy' or 'craft'))
        assert(h.C:PlanUndo())
    end
    local _,e=h.C:PlanCompare();h.finish();h.failSave=true
    assert(not h.C:PlanApplyRecommendation(e.revision,nil,'cash'),'apply must report durable save refusal')
    assert(not h.projection().allocations['1:0:*']);assert(not h.C:PlanUndo(),'failed apply cannot create a new undo')
end)
Test('manual purchase restriction persists and skips quotes and direct searches',function()
    local h=Boot();Ready(h);assert(h.C:PlanSetPurchaseBlocked('2:0:*',true))
    local p=h.projection();assert(p.purchasePolicies['2:0:*'].state=='forbidden' and p.purchasePolicies['2:0:*'].binding=='unknown')
    local calls={};h.S.Services.PriceQuoteQueueV3={RequestQuote=function(_,owner,id,grade,done)calls[#calls+1]=id;done({status='ready'});return true end}
    h.S.Services.AuctionSearchBridgeV3={Search=function()error('forbidden item must not reach auction')end}
    assert(h.C:PlanCalibrate());assert(#calls==1 and calls[1]==1)
    assert(not h.C:PlanSearch('2:0:*'));assert(not h.C:PlanSetAllocation('2:0:*','mixed',1,0))
    assert(Boot(h.disk).projection().purchasePolicies['2:0:*'].state=='forbidden')
    assert(h.C:PlanSetPurchaseBlocked('2:0:*',false));assert(h.projection().purchasePolicies['2:0:*'].state~='forbidden')
end)
Test('static binding requires matching item ID while quote errors retain reference prices',function()
    local h=Boot()
    h.S.Data=h.S.Data or {};h.S.Data.TradeStaticV2={GetMaterialByItemId=function(_,id)
        return {itemId=id==2 and 2 or 999,auctionable=false,costKind='bound_resource'}end}
    Ready(h);local p=h.projection();assert(p.purchasePolicies['2:0:*'].binding=='bound' and p.purchasePolicies['1:0:*'].binding=='unknown')
    h.S.Services.PriceQuoteQueueV3={RequestQuote=function(_,owner,id,grade,done)done({status='failed',error='auction_search_empty'});return true end}
    assert(h.C:PlanCalibrate('1:0:*'));p=h.projection()
    assert(p.quoteItems['1:0:*'].status=='none' and p.prices['1:0:*'].price==100 and p.prices['1:0:*'].freshness=='stale')
    assert(p.purchasePolicies['1:0:*'].binding=='unknown')
    assert(h.C:PlanCompare());assert(h.jobs[1].facts.quoteStates['1:0:*'].status=='none')
end)
Test('old stores migrate without restriction loss and malformed restrictions fail closed',function()
    local h=Boot();Ready(h);local restored=Boot(h.disk);assert(restored.projection().status~='unavailable')
    assert(restored.C:PlanSetPurchaseBlocked('2:0:*',true));local store=restored.S.Persistence:GetStore('v3.craft_plans')
    local value=store.get();value.plans[value.active].purchaseBlocks['2:0:*']='yes';store.apply(value,'test_invalid')
    assert(restored.projection().status=='unavailable')
end)
Test('quantity and consumer lifecycle cancel old jobs without requiring a projection',function()
    local h=Boot();Ready(h);assert(h.C:PlanCompare());local job=h.jobs[1]
    assert(h.C:PlanSetQuantity(h.projection().targets[1].id,2));assert(job.status=='cancelled')
    assert(h.C:PlanCompare());job=h.jobs[2];h.F.consumerCount=0;assert(h.F:ReconcileDemand(nil,{count=1},{count=0}));assert(job.status=='cancelled')
end)
Test('blocking a queued material cancels pending quotes and a refused save preserves the previous restriction',function()
    local h=Boot();Ready(h);local requests,cancelled={},0
    h.S.Services.PriceQuoteQueueV3={RequestQuote=function(_,owner,id,grade,done)requests[#requests+1]={id=id,done=done};return true end,
        CancelRequester=function()cancelled=cancelled+1 end}
    assert(h.C:PlanCalibrate());assert(#requests==1)
    assert(h.C:PlanSetPurchaseBlocked('2:0:*',true));assert(cancelled==1,'changing restriction must retire queued auction work')
    requests[1].done({status='ready'});assert(#requests==1,'retired callback cannot start a now forbidden query')
    h.failSave=true;assert(not h.C:PlanSetPurchaseBlocked('2:0:*',false))
    assert(h.projection().purchasePolicies['2:0:*'].state=='forbidden')
end)
Test('forbidden buy mode succeeds when the evaluated demand is entirely held in inventory',function()
    local h=Boot();Ready(h);assert(h.C:PlanSetPurchaseBlocked('2:0:*',true))
    h.S.Services.InventorySnapshotV3={BuildSnapshot=function()return {readErrors=0,unknown=0,fallback=0,rows={{itemType=2,grade=0,stack=1}}}end}
    assert(h.C:PlanRefreshInventory(false));assert(h.C:PlanSetAllocation('2:0:*','buy'),'owned materials do not require an auction purchase')
end)
Test('a block retains auto-observed material identity after cold reload',function()
    local h=Boot();Ready(h);local store=h.S.Persistence:GetStore('v3.craft_plans');local value=store.get()
    value.recipes={};value.choices={};value.catalog['2:0:*'].autoObserved=true
    store.apply(value,'test_auto_cache');assert(h.C:PlanSetPurchaseBlocked('2:0:*',true))
    local p=Boot(h.disk).projection();assert(p.recipeCatalog['2:0:*'] and p.purchasePolicies['2:0:*'].state=='forbidden')
end)
Test('a scheduler block uses the performance timer while the frame clock stays constant',function()
    local h=Boot();Ready(h);local frameNow=h.ms
    h.S.PerformanceMonitor={timer=function()return h.softMs or 0 end,Begin=function()end,End=function()end}
    assert(h.C:PlanCompare());h.run()
    local e=h.projection().comparison
    assert(e.states==2 and h.ms==frameNow and h.S.Scheduler:GetTaskState(TASK).registered,
        'a fixed OnUpdate clock must not disable the available 2ms soft cutoff')
    assert(e.softBudgetClock=='performance_timer')
end)
Test('missing or invalid performance clocks degrade to the bounded unit budget',function()
    for _,mode in ipairs({'missing','nil','nan','backwards'})do
        local h=Boot();Ready(h)
        if mode~='missing' then
            h.S.PerformanceMonitor={Begin=function()end,End=function()end,timer=function()
                if mode=='nan' then return 0/0 end
                if mode=='backwards' then return -(h.softMs or 0) end
            end}
        end
        assert(h.C:PlanCompare());h.run();local e=h.projection().comparison
        assert(e.states==200 and e.softBudgetClock=='unavailable',mode..' must report unit-only fallback')
    end
end)
Test('unverified native binding fields never become a forbidden policy',function()
    local h=Boot();h.F.ReadPlanRecipe=function()return {id='11',product={itemType=44773,grade=0,count=1,name='取证产物',
        soul_bind='normal',soul_bind_type=1,soul_bound=0,auction_only=false},materials={{itemType=9001570,grade=0,count=1,name='取证材料',soul_bind_type=2}}}end
    assert(h.C:RecipeImportLink('|if11;取证产物|r',1));local p=h.projection()
    assert(p.purchasePolicies['44773:0:*'].state=='unknown' and p.purchasePolicies['9001570:0:*'].binding=='unknown')
end)
Test('undo save refusal keeps the accepted allocation and leaves undo retryable',function()
    local h=Boot();Ready(h);local _,e=h.C:PlanCompare();h.finish();assert(h.C:PlanApplyRecommendation(e.revision,nil,'cash'))
    h.failSave=true;assert(not h.C:PlanUndo(),'undo must preserve the previous accepted plan when saving fails')
    assert(h.projection().allocations['1:0:*'].mode=='buy');h.failSave=false
    assert(h.C:PlanUndo());assert(not h.projection().allocations['1:0:*'])
end)
Test('a progress consumer may cancel without resurrecting the task or faulting the scheduler',function()
    local h=Boot();Ready(h);local owner={};local cancelled=false
    assert(h.S.Events:SubscribeInternal(h.F.UpdateTopic,owner,function(_,_,reason)
        if reason=='plan_compare_progress' and not cancelled then cancelled=true;h.C:PlanCancelCompare() end
    end))
    local ok=h.C:PlanCompare();assert(ok==false or h.jobs[1].status=='cancelled')
    assert(not h.S.Scheduler:GetTaskState(TASK).registered)
end)
Test('an input mutation during initial comparison publication cannot schedule the retired snapshot',function()
    local h=Boot();Ready(h);local changed=false;local target=h.projection().targets[1].id
    assert(h.S.Events:SubscribeInternal(h.F.UpdateTopic,{},function(_,_,reason)
        if reason=='plan_compare_progress' and not changed then changed=true;assert(h.C:PlanSetQuantity(target,2)) end
    end))
    assert(h.C:PlanCompare()==false);assert(h.jobs[1].status=='cancelled' and not h.S.Scheduler:GetTaskState(TASK).registered)
end)
Test('real solver integrates through the scheduler and both explicit objectives apply different plans',function()
    local h=Boot(nil,true);Ready(h);CompleteInventory(h);assert(h.C:PlanMarkBase('2:0:*'));assert(h.C:PlanSetLaborValue(20))
    for _,objective in ipairs({'cash','combined'})do
        local ok,e=h.C:PlanCompare();assert(ok);h.finish();local p=h.projection()
        assert(p.comparison.status=='completed' and p.comparison.result.recommendations[objective].status=='optimal')
        assert(h.C:PlanApplyRecommendation(e.revision,nil,objective))
        p=h.projection();assert(p.allocations['1:0:*'].mode==(objective=='cash' and 'craft' or 'buy'))
        assert(h.C:PlanUndo())
    end
end)
Test('real solver retains a forbidden purchase as unavailable rather than using its saved price',function()
    local h=Boot(nil,true);Ready(h);CompleteInventory(h);assert(h.C:PlanMarkBase('2:0:*'));assert(h.C:PlanSetPurchaseBlocked('2:0:*',true))
    assert(h.C:PlanCompare());h.finish();local p=h.projection()
    assert(p.comparison.status=='completed');local result=p.comparison.result
    assert(not result.manual.costComplete and result.recommendations.cash.evaluation.cashCopper==300)
    assert(result.recommendations.cash.allocations['1:0:*'].mode=='buy')
end)
Test('tree expansion changes presentation without invalidating an active comparison',function()
    local h=Boot();Ready(h);local _,e=h.C:PlanCompare();local job=h.jobs[1]
    assert(h.C:PlanSetExpanded('2:0:*',true));assert(h.projection().expanded['2:0:*'])
    assert(h.projection().revision==e.revision and job.status=='searching','presentation cannot change the calculation inputs')
    h.finish();assert(h.C:PlanApplyRecommendation(e.revision,nil,'cash'))
end)
print('craft-compare-feature tests: '..passed..' passed, '..failed..' failed')
if failed>0 then error('craft compare feature regression')end

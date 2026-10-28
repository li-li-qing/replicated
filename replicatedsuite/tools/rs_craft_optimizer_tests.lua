-- 制作最优解反例与独立穷举；全部配方为合成数据。
-- 作者：Replicated；QQ群：1104129461
ReplicatedSuite={}
dofile('features/tools/craft/rs_craft_plan_domain.lua')
local solver=io.open('features/tools/craft/rs_craft_plan_solver.lua','r')
if solver then solver:close();dofile('features/tools/craft/rs_craft_plan_solver.lua') end
local D=ReplicatedSuite.CraftPlanDomain
local passed,failed=0,0
local function Test(name,fn)
    local ok,why=xpcall(fn,debug.traceback)
    if ok then passed=passed+1;print('PASS optimizer '..name)
    else failed=failed+1;print('FAIL optimizer '..name..': '..tostring(why)) end
end
local function K(id) return id..':*:*' end
local function Recipe(id,output,labor,fee,materials)
    return {id=tostring(id),product={itemType=id,count=output},labor=labor,feeCopper=fee,materials=materials}
end
Test('all integer batches include crafting one from inventory and buying the other two',function()
    local facts={inventoryComplete=true,inventory={[K(2)]=1},catalog={[K(2)]={base=true}},
        recipes={[K(1)]=Recipe(1,1,0,0,{{itemType=2,count=1}})},prices={[K(1)]={price=10,freshness='fresh'},[K(2)]={price=100,freshness='fresh'}}}
    local r=D.Compare({targets={{itemType=1,count=3}},laborValueCopper=1},facts)
    assert(r.recommendations and r.recommendations.cash.evaluation.cashCopper==20,'must find 1 craft + 2 buy = 20')
    assert(r.recommendations.cash.status=='optimal')
end)
Test('expanded is presentation only',function()
    local facts={inventoryComplete=true,inventory={},recipes={
        [K(1)]=Recipe(1,1,10,0,{{itemType=2,count=1}}),[K(2)]=Recipe(2,1,50,0,{{itemType=3,count=1}})},
        prices={[K(2)]={price=2},[K(3)]={price=1}}}
    local p={targets={{itemType=1,count=1}},expanded={[K(2)]=true},allocations={[K(2)]={mode='buy'}}}
    assert(D.Evaluate(p,facts).labor==10,'buying an expanded intermediate must stop labor propagation')
end)
local function Quote(price) return {price=price,freshness='fresh'} end
local function Small()
    return {targets={{itemType=1,count=1}},laborValueCopper=1},
        {inventoryComplete=true,inventory={},catalog={[K(2)]={base=true}},
        recipes={[K(1)]=Recipe(1,1,2,0,{{itemType=2,count=1}})},prices={[K(1)]=Quote(10),[K(2)]=Quote(1)}}
end
local function Finish(job)
    local units=0
    repeat
        local status,used=D.StepCompareJob(job,17);assert(used<=17);units=units+used
        if status=='paused' then assert(D.ResumeCompareJob(job)) end
        assert(units<3000000,'synthetic graph exceeded test work bound')
    until job.status~='searching'
    return D.GetCompareSnapshot(job)
end
local function Alloy()
    local facts={inventoryComplete=true,inventory={},catalog={},recipes={},prices={}}
    facts.recipes[K(1)]=Recipe(1,1,10,0,{{itemType=2,count=8},{itemType=3,count=1},
        {itemType=4,count=1},{itemType=5,count=1}})
    for id=2,4 do
        facts.recipes[K(id)]=Recipe(id,1,5,0,{{itemType=id+10,count=3}})
        facts.prices[K(id)]=Quote(100);facts.prices[K(id+10)]=Quote(1)
        facts.catalog[K(id+10)]={base=true}
    end
    facts.recipes[K(5)]=Recipe(5,1,10,0,{{itemType=15,count=20},{itemType=16,count=20},{itemType=17,count=3}})
    facts.prices[K(5)]=Quote(100)
    for id=15,17 do facts.catalog[K(id)]={base=true};facts.prices[K(id)]=Quote(1) end
    facts.prices[K(1)]=Quote(1000)
    return facts
end
Test('all sixteen full alloy recipe labor paths and whole-item buying',function()
    local facts=Alloy()
    local expected={10,20,15,25,15,25,20,30,50,60,55,65,55,65,60,70}
    for mask=0,15 do
        local p={targets={{itemType=1,count=1}},allocations={},expanded={}}
        for i=1,4 do
            -- 四位从高到低依次是铁、铜、银、双花；铁锭劳力来自八次真实制作。
            p.allocations[K(i+1)]={mode=math.floor(mask/2^(4-i))%2==1 and 'craft' or 'buy'}
            p.expanded[K(i+1)]=true
        end
        local e=D.Evaluate(p,facts)
        assert(e.labor==expected[mask+1],'labor path '..mask)
        if mask>=8 then assert(e.byKey[K(2)].batches==8 and e.byKey[K(12)].demand==24) end
        if mask%2==1 then
            assert(e.byKey[K(15)].demand==20 and e.byKey[K(16)].demand==20 and e.byKey[K(17)].demand==3)
        end
    end
    assert(D.Evaluate({targets={{itemType=1,count=1}}},facts,'buy').labor==0)
end)
Test('alloy batching inventory and mixed intermediate purchasing preserve labor',function()
    local f=Alloy()
    local p={targets={{itemType=1,count=3}},allocations={}}
    assert(D.Evaluate(p,f,'raw').labor==210)
    f.inventory={[K(1)]=1,[K(2)]=3,[K(3)]=1,[K(4)]=2,[K(5)]=1}
    local e=D.Evaluate(p,f,'raw')
    assert(e.labor==100 and e.byKey[K(2)].batches==13 and e.byKey[K(12)].demand==39)
    assert(e.byKey[K(3)].batches==1 and e.byKey[K(4)].batches==0 and e.byKey[K(5)].batches==1)
    f.inventory[K(1)]=nil
    p.allocations={[K(2)]={mode='mixed',buy=5,craft=16},[K(3)]={mode='mixed',buy=1,craft=1},
        [K(4)]={mode='buy'},[K(5)]={mode='mixed',buy=1,craft=1}}
    e=D.Evaluate(p,f)
    assert(e.costComplete and e.labor==125 and e.byKey[K(2)].batches==16 and e.byKey[K(12)].demand==48)
    assert(e.byKey[K(15)].demand==20 and e.byKey[K(17)].demand==3)
end)
local function Same(a,b,path)
    assert(type(a)==type(b),'type '..path)
    if type(a)~='table' then assert(a==b,'value '..path);return end
    for k,v in pairs(a) do Same(v,b[k],path..'.'..tostring(k)) end
    for k in pairs(b) do assert(a[k]~=nil,'extra '..path..'.'..tostring(k)) end
end
Test('job-local evaluation context preserves routes and reduces repeated inventory work',function()
    local f=Alloy()
    for id=12,17 do f.inventory[K(id)]=3 end
    for id=100,299 do f.inventory[K(id)]=2 end
    local p={targets={{itemType=1,count=2}},allocations={}}
    local context={facts=f}
    D.Evaluate(p,f,'raw',nil,context)
    local plainUnits,cachedUnits=0,0
    local plain=D.Evaluate(p,f,'raw',function() plainUnits=plainUnits+1 end)
    local cached=D.Evaluate(p,f,'raw',function() cachedUnits=cachedUnits+1 end,context)
    Same(plain,cached,'raw')
    assert(cachedUnits<plainUnits/2,'warm context must avoid unrelated inventory scans: '..cachedUnits..' / '..plainUnits)
    for _,route in ipairs({'buy','manual','raw','buy','raw'}) do
        local selected=route~='manual' and route or nil
        Same(D.Evaluate(p,f,selected),D.Evaluate(p,f,selected,nil,context),route)
    end
    local other=Alloy();other.inventory={[K(1)]=2}
    Same(D.Evaluate(p,other,'raw'),D.Evaluate(p,other,'raw',nil,context),'other facts')
end)
Test('route-local inventory ambiguity and quality variant identity survive cached matches',function()
    local f={inventoryComplete=true,inventory={['2:3:a']=2,['2:4:a']=1,['2:3:b']=3},
        recipes={[K(1)]=Recipe(1,1,1,0,{{itemType=2,count=1}})},prices={}}
    local p={targets={{itemType=1,count=1},{itemType=2,grade=3,variant='a',count=1}}}
    local context={facts=f}
    local raw=D.Evaluate(p,f,'raw',nil,context)
    assert(raw.byKey['2:3:a'].owned==0 and raw.byKey['2:3:a'].inventoryUncertain)
    local buy=D.Evaluate(p,f,'buy',nil,context)
    assert(buy.byKey['2:3:a'].owned==1 and not buy.byKey['2:3:a'].inventoryUncertain)
    Same(buy,D.Evaluate(p,f,'buy'),'narrow route')
    Same(raw,D.Evaluate(p,f,'raw'),'broad route')
    local e=D.Evaluate({targets={{itemType=2,grade=4,variant='b',count=1}}},f,nil,nil,context)
    assert(e.rows[1].owned==0,'grade and variant cannot be merged')
    e=D.Evaluate({targets={{itemType=2,count=1}}},f,nil,nil,context)
    assert(e.rows[1].owned==1 and e.rows[1].inventoryUncertain and not e.costComplete)
end)
Test('cash and combined optimize independently including zero labor valuation',function()
    local p,f=Small();f.recipes[K(1)].labor=20
    local r=D.Compare(p,f).recommendations
    assert(r.cash.status=='optimal' and r.cash.evaluation.cashCopper==1)
    assert(r.combined.status=='optimal' and r.combined.evaluation.combinedCopper==10)
    p.laborValueCopper=0;r=D.Compare(p,f).recommendations
    assert(r.combined.status=='optimal' and r.combined.evaluation.cashCopper==1)
    p.laborValueCopper=nil;r=D.Compare(p,f).recommendations
    assert(r.cash.available and r.combined.status=='unavailable')
end)
Test('shared target and intermediate demand deduct inventory once before batching',function()
    local p,f=Small();p.targets={{itemType=1,count=2},{itemType=3,count=1}}
    f.recipes[K(3)]=Recipe(3,1,0,0,{{itemType=2,count=3}});f.prices[K(3)]=Quote(100)
    f.inventory[K(2)]=4
    local r=D.Compare(p,f).recommendations.cash
    assert(r.status=='optimal' and r.evaluation.cashCopper==1)
    assert(r.evaluation.byKey[K(2)].owned==4 and r.evaluation.byKey[K(2)].demand==5)
end)
Test('equal cost favors fewer batches',function()
    local p,f=Small();f.recipes[K(1)].labor=0;f.prices[K(1)]=Quote(1)
    local r=D.Compare(p,f).recommendations
    assert(r.cash.batches==0 and r.cash.allocations[K(1)].mode=='buy')
    assert(r.combined.batches==0)
end)
Test('missing prices fees recipes and labor block only the relevant proof',function()
    local p,f=Small();f.prices[K(1)]=nil
    local r=D.Compare(p,f).recommendations
    assert(r.cash.available and r.cash.status=='incomplete_data')
    p,f=Small();f.recipes[K(1)].feeCopper=nil
    r=D.Compare(p,f).recommendations
    assert(r.cash.available and r.cash.evaluation.cashCopper==10 and r.cash.status=='incomplete_data')
    p,f=Small();f.recipes[K(1)].labor=nil
    r=D.Compare(p,f).recommendations
    assert(r.cash.available and r.cash.status=='optimal' and r.cash.evaluation.cashCopper==1)
    assert(r.combined.available and r.combined.status=='incomplete_data' and r.combined.evaluation.cashCopper==10)
    p,f=Small();f.catalog[K(2)]=nil
    assert(D.Compare(p,f).recommendations.cash.status=='incomplete_data')
    f.catalog[K(2)]={base=true}
    assert(D.Compare(p,f).recommendations.cash.status=='optimal')
    f.inventoryComplete=false
    r=D.Compare(p,f).recommendations
    assert(not r.cash.available and r.cash.status=='incomplete_data')
end)
Test('stale prices remain estimates and cannot establish optimality',function()
    local p,f=Small();f.prices[K(1)].freshness='stale'
    local r=D.Compare(p,f).recommendations.cash
    assert(r.available and r.status=='incomplete_data','even an unused stale alternative blocks current-price proof')
    for _,status in ipairs({'failed','none','querying'}) do
        p,f=Small();f.quoteStates={[K(1)]={status=status}}
        assert(D.Compare(p,f).recommendations.cash.status=='incomplete_data')
    end
end)
Test('native and user purchase restrictions also apply to raw base materials',function()
    local p,f=Small();f.purchasePolicies={[K(1)]={state='forbidden',binding='bound'}}
    f.recipes[K(1)].feeCopper=100
    local r=D.Compare(p,f).recommendations.cash
    assert(r.status=='optimal' and r.evaluation.cashCopper==101)
    assert(not D.Evaluate(p,f,'buy').costComplete)
    p.purchaseBlocks={[K(2)]=true}
    assert(not D.Evaluate(p,f,'raw').costComplete)
    r=D.Compare(p,f).recommendations.cash
    assert(r.status=='infeasible' and not r.available)
    p,f=Small();p.purchaseBlocks={[K(1)]=true};f.prices[K(1)]=nil
    assert(D.Compare(p,f).recommendations.cash.status=='optimal','forbidden missing quote is not an unknown purchase branch')
end)
Test('state pauses wall-clock pauses cancellation and snapshots are explicit',function()
    local p,f=Small();p.targets[1].count=3
    local job=D.CreateCompareJob(p,f,{maxStatesPerRound=1})
    local initial=D.GetCompareSnapshot(job)
    assert(initial.result.recommendation.available==false and initial.result.recommendations.cash.status=='searching')
    assert(D.PauseCompareJob(job,'wall_clock') and D.GetCompareSnapshot(job).reason=='wall_clock')
    assert(select(2,D.StepCompareJob(job,200))==0 and D.ResumeCompareJob(job))
    local snapshot=Finish(job)
    assert(snapshot.status=='completed' and snapshot.result.recommendations.cash.status=='optimal')
    assert(snapshot.plan==nil and snapshot.thread==nil and snapshot.nodes==nil)
    assert(D.CancelCompareJob(job,'input_changed'))
    assert(D.GetCompareSnapshot(job).result.recommendations.cash.status=='cancelled')
end)
Test('full graph validation is independent of current buy allocation and expansion',function()
    local p,f=Small();p.allocations={[K(1)]={mode='buy'}}
    f.recipes[K(2)]=Recipe(2,1,0,0,{{itemType=1,count=1}})
    local s=Finish(D.CreateCompareJob(p,f))
    assert(s.status=='unsupported' and s.reason=='cycle')
end)
Test('nonfinite negative and overflowing input is rejected',function()
    for _,bad in ipairs({-1,0/0,math.huge,1000000001}) do
        local p,f=Small();f.prices[K(1)].price=bad
        assert(Finish(D.CreateCompareJob(p,f)).status=='unsupported')
        p,f=Small();p.targets[1].count=bad
        assert(Finish(D.CreateCompareJob(p,f)).status=='unsupported')
        p,f=Small();f.inventory[K(2)]=bad
        assert(Finish(D.CreateCompareJob(p,f)).status=='unsupported')
    end
    local p,f=Small();p.targets[1].count=1000000000;f.recipes[K(1)].materials[1].count=2
    -- 大数量仍按预算返回；不会在一帧遍历十亿批次。
    local j=D.CreateCompareJob(p,f,{maxStatesPerRound=20});D.StepCompareJob(j,10000)
    assert(j.status=='paused')
end)
Test('an overflowing purchase branch cannot hide an affordable single craft batch',function()
    local p,f=Small();p.targets[1].count=10000
    f.prices[K(1)]=Quote(1000000000)
    f.recipes[K(1)].product.count=10000;f.recipes[K(1)].labor=0
    local r=D.Compare(p,f).recommendations.cash
    assert(r.status=='optimal' and r.evaluation.cashCopper==1)
end)
Test('labor accumulation and combined-money overflow never prune the cash optimum',function()
    local p,f=Small();p.targets[1].count=2;p.laborValueCopper=0
    f.recipes[K(1)].labor=1000000000;f.prices[K(2)]=Quote(0)
    local r=D.Compare(p,f).recommendations
    assert(r.cash.status=='optimal' and r.cash.evaluation.cashCopper==0 and r.cash.batches==2)
    assert(not r.cash.evaluation.laborComplete and r.combined.status=='incomplete_data')
    p.laborValueCopper=1000000000
    r=D.Compare(p,f).recommendations
    assert(r.cash.status=='optimal' and r.cash.evaluation.cashCopper==0)
end)
Test('ambiguous inventory and canonical alias requirements cannot fake an optimum',function()
    local p,f=Small();f.inventory={['2:3:*']=1}
    assert(Finish(D.CreateCompareJob(p,f)).reason=='inventory_match_unverified')
    p,f=Small();p.targets={{itemType=1,count=1},{itemType=1,grade=0,count=1}}
    f.itemGrades={[K(1)]=0}
    assert(Finish(D.CreateCompareJob(p,f)).status=='unsupported')
    p,f=Small();f.recipes[K(1)].product.grade=3;p.targets[1].grade=2
    f.recipes['1:2:*']=f.recipes[K(1)]
    assert(Finish(D.CreateCompareJob(p,f)).reason=='product_identity_conflict')
end)
Test('graph target node edge and depth limits are checked incrementally',function()
    local p,f=Small();p.targets={}
    for i=1,65 do p.targets[i]={itemType=1,count=1} end
    assert(Finish(D.CreateCompareJob(p,f)).reason=='target_limit')
    p,f=Small();f.recipes[K(1)].materials={}
    for i=2,514 do f.recipes[K(1)].materials[#f.recipes[K(1)].materials+1]={itemType=i,count=1} end
    assert(Finish(D.CreateCompareJob(p,f)).reason=='graph_nodes')
    p,f=Small();f.recipes[K(1)].materials={}
    for i=1,4097 do f.recipes[K(1)].materials[i]={itemType=2,count=1} end
    assert(Finish(D.CreateCompareJob(p,f)).reason=='graph_edges')
    p,f=Small()
    for i=1,25 do f.recipes[K(i)]=Recipe(i,1,0,0,{{itemType=i+1,count=1}}) end
    assert(Finish(D.CreateCompareJob(p,f)).reason=='graph_depth')
end)
Test('a valid graph at the 512-node boundary completes through bounded steps',function()
    local p,f=Small();f.recipes[K(1)].materials={};f.recipes[K(1)].labor=0
    for id=2,512 do
        f.recipes[K(1)].materials[#f.recipes[K(1)].materials+1]={itemType=id,count=1}
        f.catalog[K(id)]={base=true};f.prices[K(id)]=Quote(0)
    end
    local r=Finish(D.CreateCompareJob(p,f)).result.recommendations.cash
    assert(r.status=='optimal' and r.evaluation.cashCopper==0)
end)
-- 独立参考解不调用 Domain，不复用图遍历、库存匹配、回滚或剪枝。
-- 合成图节点编号已是拓扑顺序；每条分支复制完整需求数组并穷举所有合法批次。
local function Exhaustive(p,f,n)
    local bestCash,bestCombined,cashBatches,combinedBatches
    local demand={};for i=1,n do demand[i]=0 end
    for _,t in ipairs(p.targets) do demand[t.itemType]=demand[t.itemType]+t.count end
    local function Walk(id,need,cash,labor,batches)
        if id>n then
            local combined=cash+p.laborValueCopper*labor
            if not bestCash or cash<bestCash or (cash==bestCash and batches<cashBatches) then bestCash,cashBatches=cash,batches end
            if not bestCombined or combined<bestCombined or (combined==bestCombined and batches<combinedBatches) then
                bestCombined,combinedBatches=combined,batches
            end
            return
        end
        local shortage=math.max(0,need[id]-(f.inventory[K(id)] or 0))
        local r=f.recipes[K(id)]
        local limit=r and math.ceil(shortage/r.product.count) or 0
        for b=0,limit do
            local buy=math.max(0,shortage-b*(r and r.product.count or 0))
            if buy==0 or not (p.purchaseBlocks or {})[K(id)] then
                local nextNeed={};for i=1,n do nextNeed[i]=need[i] end
                if r then for _,m in ipairs(r.materials) do nextNeed[m.itemType]=nextNeed[m.itemType]+b*m.count end end
                Walk(id+1,nextNeed,cash+buy*f.prices[K(id)].price+b*(r and r.feeCopper or 0),
                    labor+b*(r and r.labor or 0),batches+b)
            end
        end
    end
    Walk(1,demand,0,0,0)
    return bestCash,bestCombined,cashBatches,combinedBatches
end
Test('eighty seeded small DAGs match independent exhaustive dual-objective search',function()
    math.randomseed(110412)
    for trial=1,80 do
        local n=5
        local p={targets={{itemType=1,count=math.random(1,3)},{itemType=2,count=math.random(1,2)}},
            laborValueCopper=math.random(0,4),purchaseBlocks={}}
        local f={inventoryComplete=true,inventory={},catalog={},recipes={},prices={}}
        for i=1,n do
            f.prices[K(i)]=Quote(math.random(0,15));f.inventory[K(i)]=math.random(0,2)
            if i<4 then
                local materials={{itemType=i+1,count=math.random(1,2)},{itemType=5,count=1}}
                f.recipes[K(i)]=Recipe(i,math.random(1,3),math.random(0,5),math.random(0,3),materials)
                if math.random(1,5)==1 then p.purchaseBlocks[K(i)]=true end
            else f.catalog[K(i)]={base=true} end
        end
        local cash,combined,cb,lb=Exhaustive(p,f,n)
        local r=Finish(D.CreateCompareJob(p,f)).result.recommendations
        assert(r.cash.status=='optimal' and r.combined.status=='optimal','proof '..trial)
        assert(r.cash.evaluation.cashCopper==cash and r.combined.evaluation.combinedCopper==combined,'cost '..trial)
        assert(r.cash.batches==cb and r.combined.batches==lb,'tie '..trial)
    end
end)
print('OPTIMIZER RESULT '..passed..' passed / '..failed..' failed')
if failed>0 then os.exit(1) end

-- 制作计划的整数批次搜索；输入由 Feature 持有 detached 快照。
-- 作者：Replicated；QQ群：1104129461
-- 图、库存、传播、回滚逐项让出执行权；单轮预算只暂停，不丢失搜索栈。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local D=ReplicatedSuite.CraftPlanDomain
if not D then return end
local MONEY=9000000000000
local function Number(value,limit,integer)
    local n=tonumber(value)
    if not n or n~=n or n<0 or n>limit or (integer and n~=math.floor(n)) then return nil end
    return n
end
local function Yield(state) coroutine.yield(state and 'state' or 'unit') end
local function Fail(job,reason) job.status='unsupported';job.reason=reason end
local function Identity(item,recipe,observed,stock)
    local key=D.Key(item)
    if not key then return nil end
    local grade,source
    if stock then grade,source=D.ResolveItemGrade(item)
    else grade,source=D.ResolveRequirementGrade(item,recipe and recipe.product,observed) end
    if source=='invalid_grade' then return nil end
    return tostring(tonumber(item.itemType))..':'..tostring(grade==nil and '*' or grade)..':'..tostring(item.variant or '*')
end
local function Overlap(a,b)
    local ai,ag,av=a:match('^([^:]+):([^:]+):(.+)$')
    local bi,bg,bv=b:match('^([^:]+):([^:]+):(.+)$')
    return ai==bi and (ag==bg or ag=='*' or bg=='*') and (av==bv or av=='*' or bv=='*')
end
local function CloneAllocations(source)
    local copy={}
    for key,a in pairs(source) do Yield();copy[key]={mode=a.mode,buy=a.buy,craft=a.craft} end
    return copy
end
local function Run(job)
    local plan,facts=job.plan,job.facts
    local nodes,postorder,targets,identityOwners={}, {}, {}, {}
    local count,edges,targetCount=0,0,0
    local recipes=facts.recipes or {}
    local lambda=plan.laborValueCopper~=nil and Number(plan.laborValueCopper,D.MaxQuantity,false) or nil
    if plan.laborValueCopper~=nil and not lambda then Fail(job,'invalid_labor_value');return end
    job.lambda=lambda
    job.noPrune=lambda and lambda~=math.floor(lambda) or false
    local function Visit(item,depth)
        Yield()
        local key=D.Key(item)
        if not key then Fail(job,'invalid_identity');return end
        if depth>D.MaxDepth then Fail(job,'graph_depth');return end
        local previous=nodes[key]
        if previous then
            if previous.mark==1 then Fail(job,'cycle') end
            return
        end
        count=count+1
        if count>D.MaxNodes then Fail(job,'graph_nodes');return end
        local recipe=recipes[key]
        local identity=Identity(item,recipe,(facts.itemGrades or {})[key])
        if not identity then Fail(job,'invalid_identity');return end
        for other,owner in pairs(identityOwners) do
            Yield()
            if Overlap(identity,other) and owner~=key then Fail(job,'identity_conflict');return end
        end
        identityOwners[identity]=key
        local n={key=key,item=item,identity=identity,mark=1,children={},stock=0}
        nodes[key]=n
        n.blocked=(plan.purchaseBlocks or {})[key]==true or ((facts.purchasePolicies or {})[key] or {}).state=='forbidden'
        local quote=(facts.prices or {})[key]
        if type(quote)=='table' and quote.price~=nil then
            n.price=Number(quote.price,D.MaxQuantity,false)
            if n.price==nil then Fail(job,'invalid_price');return end
            if n.price~=math.floor(n.price) then job.noPrune=true end
            local source=tostring(quote.source or ''):gsub('^legacy:','')
            local state=(facts.quoteStates or {})[key]
            if not n.blocked and (quote.freshness~='fresh' or quote.candidatePrice~=nil or source=='name_search_direct_unit'
                or (type(state)=='table' and (state.status~='ready' or state.priceAccepted==false))) then job.stale=true end
        end
        n.unknownRecipe=not ((facts.catalog or {})[key] or {}).base
        if recipe~=nil then
            if type(recipe)~='table' then Fail(job,'invalid_recipe');return end
            local product=recipe.product
            if product~=nil and (type(product)~='table' or not D.Key(product)) then Fail(job,'invalid_product');return end
            if product and product.count~=nil and not D.Integer(product.count) then Fail(job,'invalid_output');return end
            if product and not select(1,D.ProductMatches(item,product)) then Fail(job,'product_identity_conflict');return end
            n.output=product and D.Integer(product.count)
            n.fee=recipe.feeCopper~=nil and Number(recipe.feeCopper,D.MaxQuantity,true) or nil
            n.labor=recipe.labor~=nil and Number(recipe.labor,D.MaxQuantity,true) or nil
            if recipe.feeCopper~=nil and n.fee==nil then Fail(job,'invalid_fee');return end
            if recipe.labor~=nil and n.labor==nil then Fail(job,'invalid_labor');return end
            if recipe.materials~=nil and type(recipe.materials)~='table' then Fail(job,'invalid_materials');return end
            for _,m in ipairs(recipe.materials or {}) do
                Yield()
                edges=edges+1
                if edges>4096 then Fail(job,'graph_edges');return end
                if type(m)~='table' or not D.Key(m) or not D.Integer(m.count) then Fail(job,'invalid_material');return end
                n.children[#n.children+1]={key=D.Key(m),count=D.Integer(m.count)}
                Visit(m,depth+1)
                if job.status=='unsupported' then return end
            end
            n.craft=n.output~=nil and product~=nil and select(2,D.ProductMatches(item,product))
                and #n.children>0 and not recipe.incomplete
            n.unknownRecipe=not n.craft
        end
        n.mark=2;postorder[#postorder+1]=n
    end
    for _,target in ipairs(plan.targets or {}) do
        Yield()
        targetCount=targetCount+1
        if targetCount>64 then Fail(job,'target_limit');return end
        if type(target)~='table' or not D.Key(target) or not D.Integer(target.count) then Fail(job,'invalid_target');return end
        local key=D.Key(target)
        targets[key]=(targets[key] or 0)+D.Integer(target.count)
        if targets[key]>D.MaxQuantity then Fail(job,'quantity_limit');return end
        Visit(target,1)
        if job.status=='unsupported' then return end
    end
    if targetCount==0 then job.status='completed';job.finished=true;job.reason='empty_plan';return end
    local order={}
    for i=#postorder,1,-1 do Yield();order[#order+1]=postorder[i] end
    -- DFS 首次遇见的深度不一定是 DAG 最长路径；按拓扑顺序再核验一次。
    local depths={}
    for key in pairs(targets) do Yield();depths[key]=1 end
    for _,n in ipairs(order) do
        Yield()
        for _,edge in ipairs(n.children) do
            Yield();depths[edge.key]=math.max(depths[edge.key] or 1,(depths[n.key] or 1)+1)
            if depths[edge.key]>D.MaxDepth then Fail(job,'graph_depth');return end
        end
    end
    local inventoryIdentities,stockCount={},0
    for key,value in pairs(facts.inventory or {}) do
        Yield();stockCount=stockCount+1
        if stockCount>4096 then Fail(job,'inventory_limit');return end
        local stock=Number(value,D.MaxQuantity,true)
        if stock==nil or type(key)~='string' then Fail(job,'invalid_inventory');return end
        local id,grade,variant=key:match('^([^:]+):([^:]+):(.+)$')
        if not id or (grade~='*' and tonumber(grade)==nil) then Fail(job,'invalid_inventory_identity');return end
        local identity=Identity({itemType=tonumber(id),grade=grade~='*' and tonumber(grade) or nil,variant=variant},nil,nil,true)
        if not identity then Fail(job,'invalid_inventory_identity');return end
        if stock>0 then
            if inventoryIdentities[identity] then Fail(job,'inventory_alias_conflict');return end
            inventoryIdentities[identity]=true
            for _,n in ipairs(order) do
                Yield()
                if Overlap(identity,n.identity) then
                    if identity~=n.identity then Fail(job,'inventory_match_unverified');return end
                    n.stock=n.stock+stock
                    if n.stock>D.MaxQuantity then Fail(job,'quantity_limit');return end
                end
            end
        end
    end
    local bagCount=0
    for _,value in pairs(facts.bagInventory or {}) do
        Yield();bagCount=bagCount+1
        if bagCount>4096 or Number(value,D.MaxQuantity,true)==nil then Fail(job,'invalid_bag_inventory');return end
    end
    -- 行展示和推荐使用同一个评估器；检查点使这三份基线也能跨调度片运行。
    job.result.manual=D.Evaluate(plan,facts,nil,Yield)
    job.result.raw=D.Evaluate(plan,facts,'raw',Yield)
    job.result.buy=D.Evaluate(plan,facts,'buy',Yield)
    local demands,allocations={},{}
    for key,value in pairs(targets) do Yield();demands[key]=value end
    local unknownCash,unknownCombined=facts.inventoryComplete~=true or job.stale==true,facts.inventoryComplete~=true or job.stale==true
    local bestCash,bestCombined
    local function Better(old,value,batches)
        return not old or value<old.score or (value==old.score and batches<old.batches)
    end
    local function Save(score,batches)
        local a=CloneAllocations(allocations)
        local candidate={targets=plan.targets,allocations=a,purchaseBlocks=plan.purchaseBlocks,laborValueCopper=lambda}
        local evaluation=D.Evaluate(candidate,facts,nil,Yield)
        return {score=score,batches=batches,allocations=a,evaluation=evaluation}
    end
    local function Search(index,cash,labor,batches)
        Yield(true)
        if job.status=='unsupported' then return end
        local combined=lambda and labor~=nil and cash+lambda*labor or nil
        if combined and combined>MONEY then job.combinedRange=true end
        -- 唯一下界是已经结算的非负成本。共享库存和批次让单件边际价不能作为下界。
        local cashDone=bestCash and (cash>bestCash.score or (cash==bestCash.score and batches>=bestCash.batches))
        local combinedDone=not lambda or combined==nil or combined>MONEY or (bestCombined and
            (combined>bestCombined.score or (combined==bestCombined.score and batches>=bestCombined.batches)))
        if not job.noPrune and cashDone and combinedDone then return end
        if index>#order then
            if facts.inventoryComplete==true then
                -- 非整数铜价不做浮点下界剪枝，并以展示评估器的累加顺序比较最终候选。
                if job.noPrune then
                    local found=Save(cash,batches)
                    local e=found.evaluation
                    if e.costComplete and Better(bestCash,e.cashCopper,batches) then
                        found.score=e.cashCopper;bestCash=found;job.bestCash=found
                    end
                    if e.combinedCopper and Better(bestCombined,e.combinedCopper,batches) then
                        local other={score=e.combinedCopper,batches=batches,allocations=found.allocations,evaluation=e}
                        bestCombined=other;job.bestCombined=other
                    end
                    return
                end
                if Better(bestCash,cash,batches) then
                    local found=Save(cash,batches)
                    if found.evaluation.costComplete then bestCash=found;job.bestCash=found end
                end
                if combined and combined<=MONEY and Better(bestCombined,combined,batches) then
                    local found=Save(combined,batches)
                    if found.evaluation.combinedCopper~=nil then bestCombined=found;job.bestCombined=found end
                end
            end
            return
        end
        local n=order[index]
        local need=demands[n.key] or 0
        local shortage=math.max(0,need-n.stock)
        if shortage==0 then Search(index+1,cash,labor,batches);return end
        if n.unknownRecipe then unknownCash=true;unknownCombined=true end
        if not n.blocked and n.price==nil then unknownCash=true;unknownCombined=true end
        if n.craft and n.fee==nil then unknownCash=true;unknownCombined=true end
        if n.craft and n.labor==nil then unknownCombined=true end
        job.unknownCash,job.unknownCombined=unknownCash,unknownCombined
        local maxBatches=n.craft and n.fee~=nil and math.ceil(shortage/n.output) or 0
        -- 超出满足当前汇总需求的批次不会有收益；不搜索无用的超额生产。
        local firstBatch=(n.blocked or n.price==nil) and maxBatches or 0
        for craftBatches=firstBatch,maxBatches do
            Yield(true)
            local craft=craftBatches>0 and math.min(shortage,craftBatches*n.output) or 0
            local buy=shortage-craft
            if buy==0 or (not n.blocked and n.price~=nil) then
                local nextCash=cash+buy*(n.price or 0)+craftBatches*(n.fee or 0)
                local nextLabor=labor~=nil and (craftBatches==0 or n.labor~=nil)
                    and labor+craftBatches*(n.labor or 0) or nil
                if nextLabor and nextLabor>D.MaxQuantity then
                    -- 劳力合计越界只阻止含劳力证明；现金仍有完整且独立的成本。
                    nextLabor=nil;unknownCombined=true;job.unknownCombined=true
                end
                local valid=nextCash<=MONEY and (craftBatches==0 or craftBatches*n.output<=D.MaxQuantity)
                local undo={}
                if valid then
                    for _,edge in ipairs(n.children) do
                        Yield()
                        if craftBatches>0 then
                            local old=demands[edge.key] or 0
                            undo[#undo+1]={key=edge.key,value=old}
                            demands[edge.key]=old+craftBatches*edge.count
                            if demands[edge.key]>D.MaxQuantity then valid=false;break end
                        end
                    end
                end
                if valid then
                    allocations[n.key]=buy==0 and {mode='craft'} or (craft==0 and {mode='buy'} or {mode='mixed',buy=buy,craft=craft})
                    Search(index+1,nextCash,nextLabor,batches+craftBatches)
                    if job.status=='unsupported' then return end
                    allocations[n.key]=nil
                else
                    -- 越界属于这一条候选，不可因此丢掉其它合法的买做组合。
                    job.rangeExceeded=true
                end
                for i=#undo,1,-1 do Yield();demands[undo[i].key]=undo[i].value end
            end
        end
    end
    Search(1,0,0,0)
    if job.status=='unsupported' then return end
    job.unknownCash,job.unknownCombined=unknownCash,unknownCombined
    job.finished=true
    if not bestCash and job.rangeExceeded and not unknownCash then Fail(job,'candidate_range')
    else job.status='completed' end
end
function D.CreateCompareJob(plan,facts,options)
    options=options or {}
    local limit=Number(options.maxStatesPerRound or options.stateBudget or 100000,100000,true)
    local job={plan=plan or {},facts=facts or {},status='searching',states=0,roundStates=0,
        stateLimit=limit and math.max(1,limit) or 100000,lambda=Number((plan or {}).laborValueCopper,D.MaxQuantity,false),result={recommendations={}}}
    job.thread=coroutine.create(function() Run(job) end)
    return job
end
function D.StepCompareJob(job,maxUnits)
    if not job or job.status~='searching' then return job and job.status or 'unavailable',0 end
    local units=Number(maxUnits or 200,100000,true) or 0
    local used=0
    while used<units and job.status=='searching' do
        local ok,tag=coroutine.resume(job.thread)
        used=used+1
        if not ok then Fail(job,'solver_error');job.error=tostring(tag);break end
        if tag=='state' then
            job.states=job.states+1;job.roundStates=job.roundStates+1
            if job.roundStates>=job.stateLimit then D.PauseCompareJob(job,'state_budget') end
        end
        if coroutine.status(job.thread)=='dead' then break end
    end
    return job.status,used
end
function D.PauseCompareJob(job,reason)
    if not job or job.status~='searching' then return false end
    job.status='paused';job.reason=reason or 'paused';return true
end
function D.ResumeCompareJob(job)
    if not job or job.status~='paused' then return false end
    job.status='searching';job.reason=nil;job.roundStates=0;return true
end
function D.CancelCompareJob(job,reason)
    if not job or job.status=='cancelled' then return false end
    job.status='cancelled';job.reason=reason or 'cancelled';job.thread=nil;return true
end
function D.GetCompareSnapshot(job)
    if not job then return {status='unavailable',states=0,result={recommendations={}}} end
    local function Recommendation(objective,best,unknown)
        local status=job.status
        if status=='cancelled' or status=='unsupported' then -- 终止原因优先于完成状态和缺少折价。
        elseif objective=='combined' and not job.lambda then status='unavailable'
        elseif job.finished and job.status=='completed' then
            status=unknown and 'incomplete_data' or (best and 'optimal' or 'infeasible')
            if objective=='combined' and not best and job.combinedRange and not unknown then status='unsupported' end
        end
        return {objective=objective,status=status,available=best~=nil and status~='unsupported' and status~='cancelled',
            evaluation=best and best.evaluation or nil,allocations=best and best.allocations or nil,
            states=job.states,batches=best and best.batches or nil,partial=status~='optimal',kind='integer_batches'}
    end
    local cash=Recommendation('cash',job.bestCash,job.unknownCash)
    local combined=Recommendation('combined',job.bestCombined,job.unknownCombined)
    return {status=job.status,states=job.states,reason=job.reason,result={manual=job.result.manual,
        raw=job.result.raw,buy=job.result.buy,recommendations={cash=cash,combined=combined},
        recommendation=job.lambda and combined or cash}}
end
function D.Compare(plan,facts,options)
    local job=D.CreateCompareJob(plan,facts,options)
    -- 便捷入口有总工作量上限；生产界面由 Scheduler 继续同一个 job。
    local remaining=1000000
    while job.status=='searching' and remaining>0 do
        local _,used=D.StepCompareJob(job,math.min(200,remaining));remaining=remaining-used
    end
    if job.status=='searching' then D.PauseCompareJob(job,'work_budget') end
    return D.GetCompareSnapshot(job).result
end

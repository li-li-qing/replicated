-- Replicated Suite · 制作计划命令与持久化
-- 归属 tools_craft；旧制作台上下文 Store 不变。数量/来源/展开只做本地计算。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S=ReplicatedSuite
local F=S.Features and S.Features.tools_craft
local D,P=S.CraftPlanDomain,S.Persistence
if not F or not D or not P then return end
local Copy=D.Copy
local STORE='v3.craft_plans'
local OWNER='v3.tools_craft.plan'
local TASK='tools_craft_plan_recipes'
local state, revision, generation, cached = nil,0,0,nil
local quoteGeneration=0
local inventory, inventoryComplete, inventoryNote, inventoryScope = {},false,'库存未核对',nil
local bagInventory={}
local priceOwner={}
local scan, quoteBatch, recommendation, undo = nil,nil,nil,nil
local quoteOwners, priceRevision = {}, nil
local quoteResult,quoteItems=nil,{}
local quoteGradeOverrides={}
-- 最后一轮证据独立于小窗会话；撤销 Consumer 后仍可导出，下一轮显式询价才替换。
local priceAudit={results={}}
local costProbes={}
local function RememberCostProbe(id,evidence)
    if type(evidence)~='table' then return end
    local key=tostring(id)
    if not costProbes[key] then
        local count=0;for _ in pairs(costProbes)do count=count+1 end
        if count>=16 then costProbes[next(costProbes)]=nil end
    end
    costProbes[key]={baseStatus=evidence.baseStatus,baseShape=evidence.baseShape,baseNumbers=evidence.baseNumbers,
        baseError=evidence.baseError,source=evidence.source,labor=evidence.labor,feeCopper=evidence.feeCopper,
        itemInfo=Copy(evidence.itemInfo),productGradeSource=evidence.productGradeSource}
end
local function MergeRecipeCosts(record,old)
    old=old or {}
    if old.product and D.Key(old.product)~=D.Key(record.product) then return end
    for _,field in ipairs({'labor','feeCopper'})do
        local source=field=='labor' and 'laborSource' or 'feeSource'
        if old[field]~=nil and (old[source]=='manual' or not record.costSource) then
            record[field]=old[field];record[source]=old[source]
        end
    end
    if record.laborSource=='manual' or record.feeSource=='manual' then record.costSource='manual'
    elseif not record.costSource then record.costSource=old.costSource end
end
local sessionRevision=0
local shareOwner={}
local shareCaptureActive=false
-- 仅保留阶段和计数，不记录聊天内容或发送者。
local receiveTrace={attempts=0,events=0,accepted=0,ignored=0,stage="idle",history={}}
local function TraceReceive(stage,reason)
    receiveTrace.stage=stage
    receiveTrace.reason=reason and tostring(reason):sub(1,256) or nil
    local history=receiveTrace.history
    history[#history+1]={stage=stage,reason=receiveTrace.reason,at=S.NowMs and S.NowMs() or nil}
    if #history>12 then table.remove(history,1) end
end
local importFeedback=nil
local importFeedbackSequence=0
local pendingShare=nil
local scanResult=nil
local ResetSession
local function DefaultPlan(id,name) return {id=id,name=name,targets={},allocations={},nextTarget=1} end
local function Default()
    return {active='p1',nextPlan=2,plans={p1=DefaultPlan('p1','制作计划')},recipes={},catalog={},choices={}}
end
-- 自动反查结果是可重建的会话缓存；只把用户明确保存/选择/校准的配方写入 Native。
local function PersistentSnapshot()
    local saved=Copy(state or Default())
    local required={}
    for _,plan in pairs(saved.plans or {})do
        for _,target in pairs(plan.targets or {})do required[D.Key(target)]=true end
        for key in pairs(plan.allocations or {})do required[key]=true end
    end
    for id,recipe in pairs(saved.recipes or {})do
        if recipe.autoObserved==true and not recipe.shared and not recipe.userChosen
            and (not recipe.costSource or recipe.costSource=='local_file') then
            saved.recipes[id]=nil
        end
    end
    for key,id in pairs(saved.choices or {})do
        if not saved.recipes[id] then saved.choices[key]=nil else required[key]=true end
    end
    for _,recipe in pairs(saved.recipes or {})do
        local key=D.Key(recipe.product);if key then required[key]=true end
        for _,item in ipairs(recipe.materials or {})do key=D.Key(item);if key then required[key]=true end end
    end
    for key,entry in pairs(saved.catalog or {})do
        if entry.autoObserved==true and not required[key] and entry.baseSource~='manual' then saved.catalog[key]=nil
        else
            local ids={}
            for _,id in ipairs(entry.recipeIds or {})do if saved.recipes[id] then ids[#ids+1]=id end end
            if entry.recipeIds then entry.recipeIds=ids end
            if #ids==0 and entry.status=='ready' then entry.status=nil end
        end
    end
    return saved
end
local function Load()
    local ok,err=P:PrepareRead(STORE)
    if ok~=true then return false,err end
    if type(state)~='table' or type(state.plans)~='table' or type(state.plans[state.active])~='table'
        or type(state.recipes)~='table' or type(state.catalog)~='table' or type(state.choices)~='table'
        or not D.Integer(state.nextPlan) then return false,'计划存档结构无法确认，保留原数据' end
    for _,plan in pairs(state.plans)do
        if type(plan)~='table' or type(plan.targets)~='table' or type(plan.allocations)~='table'
            or not D.Integer(plan.nextTarget) then return false,'计划条目结构无法确认，保留原数据' end
        for id,target in pairs(plan.targets)do
            if type(id)~='string' or type(target)~='table' or target.id~=id or not D.Key(target) or not D.Integer(target.count) then
                return false,'目标条目无法确认，保留原数据'
            end
        end
        for key,allocation in pairs(plan.allocations)do
            if type(key)~='string' or type(allocation)~='table' then return false,'来源分配无法确认，保留原数据' end
        end
    end
    for id,recipe in pairs(state.recipes)do
        if type(recipe)~='table' or recipe.id~=id or not D.Key(recipe.product)
            or not D.Integer(recipe.product.count) or type(recipe.materials)~='table' then
            return false,'配方记录无法确认，保留原数据'
        end
        for _,item in pairs(recipe.materials)do
            if not D.Key(item) or not D.Integer(item.count) then return false,'配方材料无法确认，保留原数据' end
        end
    end
    for key,entry in pairs(state.catalog)do
        if type(entry)~='table' or D.Key(entry.item)~=key then return false,'物品目录无法确认，保留原数据' end
    end
    return state~=nil, state==nil and '计划存档未就绪' or nil
end
if P:GetStore(STORE)==nil then
    local store,err=P:RegisterV3Store({id=STORE,owner=OWNER,scope=P.Scope.Character,lifetime=P.Lifetime.Permanent,
        schemaVersion=1,legacySchemaVersion=0,key=P.V3KeyPrefix..'craft_plans',
        nativeByteBudget=14336, -- Native 实测在 16383 字节截断；拒绝必须发生在写入前。
        recoverableReplacement=true, -- 只允许用户显式清空本角色的损坏计划，Core 校验归属并回读。
        requireFailureBarrier=true, -- 计划不是可丢弃的缓存，普通保存失败仍须耐久屏障。
        budget={maxDepth=10,maxNodes=16000,maxEntriesPerTable=256,maxStringBytes=65536},
        default=Default,get=PersistentSnapshot,
        apply=function(value,reason)
            state=Copy(value);cached=nil
            if ResetSession and not tostring(reason or ''):find('^mutation_rollback:') then ResetSession() end
        end,migrate=function(value)return value end})
    if not store then error(err or 'craft plan store registration failed') end
end
local function Notify(reason)
    revision=revision+1;cached=nil;recommendation=nil
    if S.Events and type(S.Events.Publish)=='function' then S.Events:Publish(F.UpdateTopic,revision,reason or 'plan_local') end
end
local function ImportReceipt(ok,message,reason)
    importFeedbackSequence=importFeedbackSequence+1
    importFeedback={id=importFeedbackSequence,ok=ok==true,message=tostring(message or '')}
    Notify(reason or 'plan_share_feedback')
end
local function LivePendingShare()
    if pendingShare and (not S.NowMs or S.NowMs()>=pendingShare.expiresAt
        or pendingShare.sessionRevision~=sessionRevision or not state or pendingShare.planId~=state.active) then
        TraceReceive(S.NowMs and S.NowMs()>=pendingShare.expiresAt and 'expired' or 'context_changed')
        pendingShare=nil;cached=nil
    end
    return pendingShare
end
local function Active() return state.plans[state.active] end
-- 同一产物可有多张配方；独立条目的根配方固定，不能串用上次另一条目的全局选择。
local function ChosenRecipe(key)
    local plan=Active()
    local root=plan.sourceRecipeId and state.recipes[plan.sourceRecipeId]
    local item=state.catalog[key] and state.catalog[key].item
    if root and item and D.ProductMatches(item,root.product) then
        for _,target in pairs(plan.targets or {})do if D.Key(target)==key then return root.id end end
    end
    return state.choices[key]
end
local function EffectiveChoices()
    local choices=Copy(state.choices)
    local plan=Active();local root=plan.sourceRecipeId and state.recipes[plan.sourceRecipeId]
    if root then
        for _,target in pairs(plan.targets or {})do
            if D.ProductMatches(target,root.product) then choices[D.Key(target)]=root.id end
        end
    end
    return choices
end
local function QuoteGrade(key,item)
    local id=ChosenRecipe(key)
    local recipe=state.recipes[id or '']
    local observed=quoteGradeOverrides[key]
    return D.ResolveRequirementGrade(item,recipe and recipe.product,observed and observed.recipeId==id and observed.grade or nil)
end
local function Count(t) local n=0;for _ in pairs(t or {})do n=n+1 end;return n end
local function Sorted(t)
    local keys={};for k in pairs(t or {})do keys[#keys+1]=k end;table.sort(keys);return keys
end
local function CheckNativeBudget()
    local store=P:GetStore(STORE);local transport=S.PersistenceTransport
    if not store or not store.nativeByteBudget or not transport or type(transport.EstimateNativeBytes)~='function' then
        return false,'存档物理预算检查不可用'
    end
    local physical,why=P:EncodePhysicalEnvelope({__rsmeta={framework=P.FrameworkVersion,transportVersion=store.transportVersion},
        payload=PersistentSnapshot()})
    if not physical then return false,'存档编码检查失败：'..tostring(why) end
    -- 预留完整 Store 元数据及封印的空间；最终写入仍由 Core 对真实 envelope 再次检查。
    local bytes=transport.EstimateNativeBytes(physical)+1024
    if bytes>store.nativeByteBudget then return false,'native_byte_budget_exceeded:'..bytes..'>'..store.nativeByteBudget..'；计划过大，已保留原存档' end
    return true
end
local function Mutate(reason,fn,durable)
    local ok,err=Load();if not ok then return false,err end
    -- Core 回滚的是可持久化快照；失败时也要保留本会话尚未写入的自动材料缓存。
    local before=Copy(state)
    local changed,why=P:MutateStore(STORE,function()
        local accepted,detail=fn(Active())
        if accepted~=true then return accepted,detail end
        return CheckNativeBudget()
    end,{delayMs=300,reason=reason,durable=durable==true})
    if changed~=true then state=before;cached=nil;return false,why or '计划保存失败，已回滚' end
    if reason=='plan_create' or reason=='plan_select' or reason=='plan_delete'
        or reason=='recipe_select' or reason=='recipe_delete' then pendingShare=nil end
    if reason~='plan_recommendation_apply' and reason~='plan_undo' then undo=nil end
    Notify(reason);return true
end
local function Running()
    if F.enabled~=true or (tonumber(F.consumerCount) or 0)<=0 then return false,'先启用并打开配方制作' end
    return true
end
local function CancelQuotes(reason)
    quoteGeneration=quoteGeneration+1
    local queue=S.Services and S.Services.PriceQuoteQueueV3
    if quoteBatch then
        -- 未完成的查询不会再回调本会话；释放前冻结已有队列时序，避免关窗后丢失请求关联。
        local current=quoteItems[quoteBatch.currentKey]
        local health=queue and type(queue.Describe)=='function' and queue:Describe()
        local pending=health and health.pendingDetail
        if current and pending and pending.requester==current.requester then
            for _,field in ipairs({'requestedAt','dispatchedAt','queueDeadlineAt','deadlineAt','searchGeneration'})do current[field]=pending[field] end
        end
        quoteResult=Copy(quoteBatch);quoteResult.status='stopped';quoteResult.reason=reason or 'cancelled'
        quoteResult.completedAt=S.NowMs and S.NowMs() or 0
        priceAudit.batch=quoteResult;priceAudit.currentRequester=nil
    end
    quoteBatch=nil
    -- 先使回调失效再释放，CancelRequester 允许同步通知消费者。
    local owners=quoteOwners;quoteOwners={}
    if queue and type(queue.CancelRequester)=='function' then
        for owner in pairs(owners)do queue:CancelRequester(owner) end
    end
    for _,item in pairs(quoteItems)do
        if item.status=='querying' then
            item.status='stopped';item.reason=reason or 'cancelled';item.code=item.reason;item.completedAt=S.NowMs and S.NowMs() or 0
        end
    end
end
local function Cancel()
    generation=generation+1;scan=nil
    if S.Scheduler then S.Scheduler:RemoveTask(TASK) end
    CancelQuotes('cancelled')
    quoteResult=nil
end
ResetSession=function()
    sessionRevision=sessionRevision+1
    cached=nil
    importFeedback=nil
    pendingShare=nil
    scanResult=nil
    Cancel();quoteResult=nil;quoteItems={};costProbes={};inventory={};bagInventory={};inventoryComplete=false;inventoryScope=nil;inventoryNote='角色/存档重新载入，库存待核对'
    quoteGradeOverrides={}
    undo=nil;recommendation=nil;revision=revision+1
end
local function AddTarget(plan,item,count)
    local key=D.Key(item)
    if not key or not D.Integer(count) then return false,'目标数量须为 1 至 10 亿的整数' end
    for _,target in pairs(plan.targets)do
        if D.Key(target)==key then
            if not D.Integer(target.count+count) then return false,'目标数量超过上限' end
            target.count=target.count+count;return true
        end
    end
    if Count(plan.targets)>=32 then return false,'一份计划最多 32 个目标' end
    local row=Copy(item);row.id='t'..plan.nextTarget;row.count=count
    plan.nextTarget=plan.nextTarget+1;plan.targets[row.id]=row;return true
end
local function RecipeSheet(id)
    for _,planId in ipairs(Sorted(state.plans))do
        local plan=state.plans[planId]
        if plan.sourceRecipeId==id then return plan end
    end
end
local function OpenRecipeSheet(record,count)
    local id=tostring(record.id)
    local sheet=RecipeSheet(id)
    if not sheet then
        for _,planId in ipairs(Sorted(state.plans))do
            local plan=state.plans[planId]
            if plan.recipeSheet and not plan.sourceRecipeId and Count(plan.targets)==0 then sheet=plan;break end
        end
        if not sheet then
            if Count(state.plans)>=140 then return false,'已保存计划/配方条目达到上限' end
            local planId='p'..state.nextPlan;state.nextPlan=state.nextPlan+1
            sheet=DefaultPlan(planId,record.product.name or ('配方 '..id));state.plans[planId]=sheet
        end
        sheet.name=record.product.name or ('配方 '..id)
        sheet.recipeSheet=true;sheet.sourceRecipeId=id
        local ok,why=AddTarget(sheet,record.product,count or 1);if not ok then return false,why end
    elseif Count(sheet.targets)==0 then
        local ok,why=AddTarget(sheet,record.product,count or 1);if not ok then return false,why end
    else
        for _,target in pairs(sheet.targets)do
            if not D.ProductMatches(target,record.product) then return false,'配方产物身份发生变化，请核对后重新收录' end
        end
    end
    state.active=sheet.id;state.choices[D.Key(record.product)]=id
    return true
end
local function LibraryEntries()
    local roots={}
    for id,recipe in pairs(state.recipes)do if recipe.shared then roots[id]=true end end
    -- 已有混合计划不迁移、不清空；保留其中已选根配方的显式打开入口。
    for _,plan in pairs(state.plans)do
        if plan.sourceRecipeId then roots[plan.sourceRecipeId]=true end
        for _,target in pairs(plan.targets)do
            local id=state.choices[D.Key(target)];if id then roots[id]=true end
        end
    end
    local entries={}
    local labels={}
    for id in pairs(roots)do
        local recipe=state.recipes[id]
        if recipe and not recipe.libraryHidden then
            local sheet=RecipeSheet(id)
            entries[#entries+1]={value=id,text=(sheet and sheet.name or recipe.product.name or ('配方 '..id)),
                planId=sheet and sheet.id,item=Copy(recipe.product)}
            local label=entries[#entries].text;labels[label]=(labels[label] or 0)+1
        end
    end
    for _,entry in ipairs(entries)do if labels[entry.text]>1 then entry.text=entry.text..' [#'..entry.value..']' end end
    table.sort(entries,function(a,b)if a.text==b.text then return a.value<b.value end;return a.text<b.text end)
    return entries
end
local function Snapshot()
    local plan=Copy(Active());plan.targets={}
    for _,id in ipairs(Sorted(Active().targets))do plan.targets[#plan.targets+1]=Copy(Active().targets[id])end
    return plan
end
local function Facts(plan)
    local facts={recipes={},catalog=Copy(state.catalog),inventory=Copy(inventory),bagInventory=Copy(bagInventory),inventoryComplete=inventoryComplete,prices={},itemGrades={}}
    local all={}
    for key,entry in pairs(state.catalog)do
        all[key]=entry.item
        local selected=ChosenRecipe(key)
        if selected and state.recipes[selected] then
            facts.recipes[key]=Copy(state.recipes[selected])
            if entry.status=='recipe_fields_unknown' then facts.recipes[key].incomplete=true end
        end
    end
    for _,recipe in pairs(state.recipes)do
        all[D.Key(recipe.product)]=recipe.product
        for _,item in ipairs(recipe.materials)do all[D.Key(item)]=item end
    end
    for _,item in ipairs(plan.targets)do all[D.Key(item)]=item end
    local prices=S.Services and S.Services.MaterialPriceServiceV3
    for key,item in pairs(all)do
        local grade,source=QuoteGrade(key,item)
        facts.itemGrades[key]=grade
        if item and not (quoteItems[key] and quoteItems[key].status=='none') and prices and type(prices.GetPrice)=='function' then
            local price,meta
            if grade~=nil then price,meta=prices:GetPrice(item.itemType,grade) end
            if price~=nil then
                facts.prices[key]=Copy(meta or {});facts.prices[key].price=price
                facts.prices[key].quoteGrade=grade;facts.prices[key].gradeSource=source
            end
        end
    end
    return facts
end
local function Projection()
    local ok,err=Load()
    if not ok then
        local replaceable=P:CanReplaceCorrupt(STORE)==true
        return {status='unavailable',error=tostring(err),canResetCorrupt=replaceable,targets={},plans={},rows={},revision=revision}
    end
    local priceService=S.Services and S.Services.MaterialPriceServiceV3
    local nextPriceRevision=priceService and type(priceService.GetRevision)=='function' and priceService:GetRevision() or nil
    if nextPriceRevision~=priceRevision then
        priceRevision=nextPriceRevision;revision=revision+1;cached=nil;recommendation=nil
    end
    LivePendingShare()
    if cached then return Copy(cached) end
    local plan=Snapshot()
    local facts=Facts(plan)
    local result=D.Evaluate(plan,facts)
    local plans,targets,options,contextRecipes={},{},{},{}
    for _,id in ipairs(Sorted(state.plans))do plans[#plans+1]={value=id,text=state.plans[id].name}end
    for _,item in ipairs(plan.targets)do local row=Copy(item);row.key=D.Key(item);targets[#targets+1]=row end
    local known={}
    -- 已核静态中文物品子集只提供名称/身份，不假定配方、产量或品质。
    for id,name in pairs(S.Data and S.Data.Localization and S.Data.Localization.items or {})do
        local item={itemType=tonumber(id),name=name}
        local key=D.Key(item)
        if key and type(name)=='string' then known[key]=item end
    end
    for key,entry in pairs(state.catalog)do known[key]=entry.item end
    for _,key in ipairs(Sorted(known))do
        local item=known[key]
        options[#options+1]={value=key,text=item.name or ('物品 '..item.itemType),item=Copy(item)}
    end
    contextRecipes=LibraryEntries()
    cached={revision=revision,sessionRevision=sessionRevision,activeId=state.active,name=plan.name,plans=plans,targets=targets,
        rows=result.rows,evaluation=result,catalog=options,allocations=Copy(plan.allocations),prices=Copy(facts.prices),
        laborValueCopper=plan.laborValueCopper,inventoryNote=inventoryNote,inventoryComplete=inventoryComplete,inventoryScope=inventoryScope,
        recipeCatalog=Copy(state.catalog),recipes=Copy(state.recipes),choices=EffectiveChoices(),
        shareCaptureActive=shareCaptureActive,pendingShare=Copy(pendingShare),importFeedback=Copy(importFeedback),
        contextRecipeOptions=contextRecipes,
        libraryEntries=Copy(contextRecipes),libraryActiveId=plan.sourceRecipeId,
        scan=Copy(scan),scanResult=Copy(scanResult),quote=Copy(quoteBatch or quoteResult),quoteItems=Copy(quoteItems),status=result.complete and 'ready' or 'incomplete'}
    return Copy(cached)
end
local baseProjection=F.GetProjection
function F:GetProjection()
    local projection=baseProjection(self) or {};projection.plan=Projection();return projection
end
function F:GetRecipeReadDiagnostics()
    local active=state and state.plans and state.plans[state.active] or nil
    local targets={}
    for _,item in pairs(active and active.targets or {})do
        if #targets>=12 then break end
        targets[#targets+1]=tostring(item.name or '')..' item='..tostring(item.itemType)..' count='..tostring(item.count)
    end
    table.sort(targets)
    return {targets=targets,scan=Copy(scan),result=Copy(scanResult),costProbes=Copy(costProbes),
        receive=Copy(receiveTrace),shareCaptureActive=shareCaptureActive,pendingShare=pendingShare~=nil,
        traces=Copy((scan and scan.traces) or (scanResult and scanResult.traces) or {})}
end
function F:GetPriceReadDiagnostics()
    local value=Copy(priceAudit)
    value.currentSessionRevision=sessionRevision;value.sameSession=value.sessionRevision==sessionRevision
    value.coverage='last_explicit_batch; cached_only; closing_popup_preserves_results'
    local queue=S.Services and S.Services.PriceQuoteQueueV3
    if queue and type(queue.Describe)=='function' then
        local health=queue:Describe()
        value.queue={pending=health.pending,queueLength=health.queueLength,intervalMs=health.intervalMs,
            activity=Copy(health.activity),nativeAdmission=Copy(health.nativeAdmission),pendingDetail=Copy(health.pendingDetail)}
    end
    return value
end
function F:GetPriceListingDiagnostics()
    local query=S.Services and S.Services.AuctionQueryV3
    if not query or type(query.DescribePriceEvidenceDetail)~='function' then return {available=false} end
    local types,generations={},{}
    for _,row in pairs(priceAudit.results)do
        types[row.itemType]=true
        if row.searchGeneration then generations[row.searchGeneration]=true end
    end
    local queue=S.Services and S.Services.PriceQuoteQueueV3
    local health=queue and type(queue.Describe)=='function' and queue:Describe()
    local pending=health and health.pendingDetail
    if pending and pending.requester==priceAudit.currentRequester and pending.searchGeneration then
        types[pending.itemType]=true;generations[pending.searchGeneration]=true
    end
    local value=query:DescribePriceEvidenceDetail(types,generations)
    value.coverage='current_batch_generations_still_in_shared_16_request_ring; no_native_reads'
    return value
end
local C=F.Commands
local function ResumeRecipeRead()
    if Running() and type(F.ReadPlanRecipeTypes)=='function' and S.Scheduler then
        local started,readError=C:PlanReadRecipes()
        return started and '；正在展开下级配方' or ('；下级可重读：'..tostring(readError))
    end
    return ''
end
-- 用户明确清空损坏计划后才写空值；仅本角色、同 Store 且物理回读通过才解除保护。
function C:PlanResetCorrupt()
    local running,why=Running();if not running then return false,why end
    local replaceable,reason=P:CanReplaceCorrupt(STORE)
    if replaceable~=true then return false,reason or '无法确认损坏计划归属' end
    local fresh=Default()
    local saved,err=P:SaveValue(STORE,fresh,{replaceCorrupt=true,allowUnloadedWrite=true,durable=true,reason='craft_plan_reset_corrupt'})
    if saved~=true then return false,err or '计划重建失败' end
    state=fresh;cached=nil;ResetSession();Notify('plan_reset_corrupt')
    return true,'已清空损坏计划，请重新接收配方'
end
function C:PlanAddTarget(item,count)
    return Mutate('plan_add',function(plan)
        if plan.recipeSheet then return false,'当前为独立配方；请新建手动计划后添加其它目标' end
        local ok,err=AddTarget(plan,item,D.Integer(count))
        if ok then local key=D.Key(item);state.catalog[key]=state.catalog[key] or {item=Copy(item)} end
        return ok,err
    end)
end
function C:PlanSetQuantity(id,count)
    count=D.Integer(count);if not count then return false,'数量须为正整数' end
    return Mutate('plan_quantity',function(plan)
        if not plan.targets[id] then return false,'目标已移除' end
        plan.targets[id].count=count;return true
    end,true)
end
function C:PlanRemoveTarget(id)
    return Mutate('plan_remove',function(plan)
        if plan.recipeSheet then return false,'请用删除配方移除当前条目' end
        plan.targets[id]=nil;return true
    end)
end
function C:PlanSetAllocation(key,mode,buy,craft)
    if mode~='buy' and mode~='craft' and mode~='mixed' then return false,'来源无效' end
    if mode=='mixed' and (not D.Integer(buy,true) or not D.Integer(craft,true)) then return false,'混合数量须为非负整数' end
    return Mutate('plan_allocation',function(plan)
        if not state.catalog[key] then return false,'物品身份未知' end
        plan.allocations[key]={mode=mode,buy=D.Integer(buy,true),craft=D.Integer(craft,true)};return true
    end)
end
function C:PlanSetLaborValue(value)
    if value~=nil and not D.Integer(value,true) then return false,'每点劳力折价使用非负整数铜' end
    return Mutate('plan_labor_value',function(plan)plan.laborValueCopper=value;return true end)
end
function C:PlanSetRecipeCosts(key,labor,fee)
    if labor==nil and fee==nil then return false,'请至少填写劳力或手续费中的一项' end
    if (labor~=nil and not D.Integer(labor,true)) or (fee~=nil and not D.Integer(fee,true)) then
        return false,'每次劳力、手续费（铜）须为非负整数'
    end
    labor,fee=D.Integer(labor,true),D.Integer(fee,true)
    return Mutate('plan_recipe_costs',function()
        local recipe=state.recipes[ChosenRecipe(key) or '']
        if not recipe then return false,'先读取并选择配方' end
        if labor~=nil then recipe.labor=labor;recipe.laborSource='manual' end
        if fee~=nil then recipe.feeCopper=fee;recipe.feeSource='manual' end
        recipe.costSource='manual';return true
    end,true)
end
function C:PlanMarkBase(key)
    return Mutate('plan_base_confirmed',function()
        local entry=state.catalog[key]
        if not entry then return false,'物品身份未知' end
        if state.choices[key] then return false,'已有选定配方；请用购买来源控制中间材料' end
        entry.base=true;entry.baseSource='manual';return true
    end)
end
local function Name(value)
    value=tostring(value or ''):match('^%s*(.-)%s*$')
    if value=='' or #value>96 or value:find('[%c]') then return nil end
    return value
end
function C:PlanRename(name)
    name=Name(name);if not name then return false,'名称须为 1 至 96 字节' end
    return Mutate('plan_rename',function(plan)plan.name=name;return true end,true)
end
local function Create(name,duplicate)
    name=Name(name);if not name then return false,'计划名称不能为空' end
    Cancel();undo=nil
    return Mutate('plan_create',function(plan)
        local manualCount=0
        for _,saved in pairs(state.plans)do if not saved.recipeSheet then manualCount=manualCount+1 end end
        if manualCount>=12 or Count(state.plans)>=140 then return false,'最多保存 12 份手动计划' end
        local id='p'..state.nextPlan;state.nextPlan=state.nextPlan+1
        state.plans[id]=duplicate and Copy(plan) or DefaultPlan(id,name)
        state.plans[id].id=id;state.plans[id].name=name
        state.plans[id].recipeSheet=nil;state.plans[id].sourceRecipeId=nil
        state.active=id;return true
    end)
end
function C:PlanNew(name)return Create(name or '新计划',false)end
function C:PlanCopy(name)return Create(name or '计划副本',true)end
function C:PlanSelect(id)
    local loaded,loadError=Load();if not loaded then return false,loadError end
    if state.plans[id] and state.plans[id].sourceRecipeId then return C:RecipeOpen(state.plans[id].sourceRecipeId) end
    Cancel();undo=nil
    return Mutate('plan_select',function()if not state.plans[id] then return false,'计划不存在' end;state.active=id;return true end)
end
function C:PlanDelete()
    local loaded,why=Load();if not loaded then return false,why end
    if Active().sourceRecipeId then return C:RecipeDelete(Active().sourceRecipeId) end
    Cancel();undo=nil
    return Mutate('plan_delete',function()
        if Count(state.plans)<=1 then state.plans[state.active]=DefaultPlan(state.active,'制作计划')
        else state.plans[state.active]=nil;state.active=Sorted(state.plans)[1] end
        return true
    end)
end
function C:PlanImportCurrent(count,craftId)
    local ok,err=Running();if not ok then return false,err end
    local current=baseProjection(F).craft or {}
    local chosen
    for _,recipe in ipairs(current.recipes or {})do if not craftId or tostring(recipe.craftType)==tostring(craftId)then chosen=recipe;break end end
    if not chosen or not chosen.product or #chosen.product.items~=1 then return false,'先选择并读取一个具有明确产物的制作配方' end
    local p=chosen.product.items[1]
    local item={itemType=p.itemType,grade=p.grade,name=p.name,count=p.count}
    if not D.Key(item) or not D.Integer(p.count) then return false,'产物身份或产量未确认' end
    return Mutate('plan_import',function(plan)
        if plan.recipeSheet then return false,'当前为独立配方，请接收新配方或新建手动计划' end
        local added,why=AddTarget(plan,item,D.Integer(count) or 1);if not added then return false,why end
        local key=D.Key(item);local materials={}
        for _,m in ipairs(chosen.materials and chosen.materials.items or {})do
            local row={itemType=m.itemType,grade=m.grade,name=m.name,count=m.count}
            if not D.Key(row) or not D.Integer(row.count) then return false,'材料字段未确认' end
            materials[#materials+1]=row
        end
        if #materials==0 or chosen.materials.truncated or chosen.product.truncated then return false,'材料不完整' end
        local id=tostring(chosen.craftType)
        local old=state.recipes[id] or {}
        state.recipes[id]={id=id,product=item,materials=materials,labor=old.labor,feeCopper=old.feeCopper,costSource=old.costSource,source='craft_context'}
        state.catalog[key]={item=Copy(item),recipeIds={id}};state.choices[key]=id
        for _,m in ipairs(materials)do local k=D.Key(m);state.catalog[k]=state.catalog[k] or {item=Copy(m)} end
        return true
    end)
end
function C:PlanChooseRecipe(key,id)
    return Mutate('plan_recipe_choice',function()
        local item=state.catalog[key] and state.catalog[key].item
        if not state.recipes[id] or not D.ProductMatches(item,state.recipes[id].product) then return false,'配方与物品不匹配' end
        local root=Active().sourceRecipeId and state.recipes[Active().sourceRecipeId]
        if root and D.Key(root.product)==key and id~=root.id then return false,'请从已保存配方中切换该根配方' end
        state.recipes[id].userChosen=true;state.choices[key]=id;return true
    end)
end
function C:PlanSelectContext(id)
    local ok,err=Load();if not ok then return false,err end
    if not state.recipes[tostring(id)] then return false,'配方尚未导入' end
    return C:SetCraftType(tonumber(id))
end
function C:PlanAddSavedRecipe(id,count)
    return Mutate('plan_add_saved_recipe',function(plan)
        if plan.recipeSheet then return false,'当前为独立配方；请在配方列表中切换，或新建手动计划' end
        local recipe=state.recipes[tostring(id)]
        if not recipe then return false,'配方尚未收录，请先接收一次分享。' end
        local ok,why=AddTarget(plan,recipe.product,D.Integer(count));if not ok then return false,why end
        state.choices[D.Key(recipe.product)]=recipe.id;return true
    end)
end
-- 从独立配方加入新目标时复制为手动计划，原配方条目保持不变。
local function AppendTarget(plan,item,count,recipeId)
        local key=D.Key(item)
        local root=plan.sourceRecipeId and state.recipes[plan.sourceRecipeId]
        if recipeId and root and D.Key(root.product)==key and root.id~=recipeId then
            return false,'同一物品的不同配方不能混入同一目标'
        end
        if plan.recipeSheet then
            local manualCount=0
            for _,saved in pairs(state.plans)do if not saved.recipeSheet then manualCount=manualCount+1 end end
            if manualCount>=12 or Count(state.plans)>=140 then return false,'最多保存 12 份手动计划' end
            local newId='p'..state.nextPlan;state.nextPlan=state.nextPlan+1
            local combined=Copy(plan);combined.id=newId;combined.name=Name(plan.name..' · 组合') or ('组合计划 '..newId)
            combined.recipeSheet=nil;combined.sourceRecipeId=nil
            state.plans[newId]=combined;state.active=newId;plan=combined
            if root then state.choices[D.Key(root.product)]=root.id end
        end
        for _,target in pairs(plan.targets)do
            if recipeId and D.Key(target)==key and state.choices[key] and state.choices[key]~=recipeId then
                return false,'同一目标已有不同配方，请先确认配方选择'
            end
        end
        local added,err=AddTarget(plan,item,count);if not added then return false,err end
        state.catalog[key]=state.catalog[key] or {item=Copy(item)}
        if recipeId then state.choices[key]=recipeId end
        return true
end
function C:PlanAppendSavedRecipe(id,count)
    id=tostring(id or '');count=D.Integer(count)
    if not count then return false,'目标数量须为正整数' end
    local loaded,why=Load();if not loaded then return false,why end
    local recipe=state.recipes[id]
    if not recipe then return false,'配方尚未收录' end
    Cancel()
    local ok,err=Mutate('plan_append_saved_recipe',function(plan)return AppendTarget(plan,recipe.product,count,id)end,true)
    if ok then return true,'已加入目标'..ResumeRecipeRead() end
    return false,err
end
function C:PlanAppendCatalogItem(key,count)
    count=D.Integer(count)
    if not count then return false,'目标数量须为正整数' end
    local loaded,why=Load();if not loaded then return false,why end
    local item
    for _,option in ipairs(Projection().catalog or {})do if option.value==key then item=option.item;break end end
    if not item then return false,'物品不在本地已收录目录' end
    Cancel()
    local ok,err=Mutate('plan_append_catalog_item',function(plan)return AppendTarget(plan,item,count)end,true)
    if ok then return true,'已加入目标'..ResumeRecipeRead() end
    return false,err
end
-- 删除只回收不再被任何配方条目或手动计划引用的缓存；共享下级与可选配方仍保留。
local function CollectUnusedRecipes()
    local recipes,items,pending={},{},{}
    local function KeepItem(key)
        if key and not items[key] then items[key]=true;pending[#pending+1]=key end
    end
    local function KeepRecipe(id)
        local record=state.recipes[id]
        if not record or recipes[id] then return end
        recipes[id]=true;KeepItem(D.Key(record.product))
        for _,item in ipairs(record.materials)do KeepItem(D.Key(item))end
    end
    for _,plan in pairs(state.plans)do
        if plan.sourceRecipeId then KeepRecipe(plan.sourceRecipeId) end
        for _,target in pairs(plan.targets)do KeepItem(D.Key(target))end
    end
    for id,record in pairs(state.recipes)do if record.shared and not record.libraryHidden then KeepRecipe(id) end end
    local cursor=1
    while cursor<=#pending do
        local key=pending[cursor];cursor=cursor+1
        KeepRecipe(state.choices[key])
        local entry=state.catalog[key]
        for _,id in ipairs(entry and entry.recipeIds or {})do KeepRecipe(id)end
    end
    for id in pairs(state.recipes)do if not recipes[id] then state.recipes[id]=nil end end
    for key in pairs(state.catalog)do if not items[key] then state.catalog[key]=nil end end
    for key,id in pairs(state.choices)do if not items[key] or not state.recipes[id] then state.choices[key]=nil end end
end
function C:RecipeOpen(id)
    id=tostring(id)
    local loaded,loadError=Load();if not loaded then return false,loadError end
    if Active().sourceRecipeId==id and scan then return true,'正在展开当前配方材料链' end
    Cancel();scanResult=nil
    local ok,why=Mutate('recipe_select',function()
        local recipe=state.recipes[id]
        if not recipe or recipe.libraryHidden then return false,'配方已删除或尚未收录' end
        return OpenRecipeSheet(recipe,1)
    end,true)
    if ok then
        local message='已打开：'..tostring(Active().name)
        -- 显式切换重新取得当前条目的有界读链，避免连续收录取消旧扫描后一直缺下级。
        message=message..ResumeRecipeRead()
        ImportReceipt(true,message,'recipe_opened');return true,message
    end
    return false,why
end
function C:RecipeDelete(id)
    id=tostring(id);Cancel();scanResult=nil
    local ok,why=Mutate('recipe_delete',function()
        local recipe=state.recipes[id];if not recipe then return false,'配方不存在' end
        recipe.libraryHidden=true
        local sheet=RecipeSheet(id)
        if sheet then
            local wasActive=state.active==sheet.id
            state.plans[sheet.id]=nil
            if wasActive then
                local nextId
                for _,planId in ipairs(Sorted(state.plans))do
                    if state.plans[planId].sourceRecipeId then nextId=planId;break end
                end
                if nextId then state.active=nextId else
                    local empty=DefaultPlan(sheet.id,'未选择配方');empty.recipeSheet=true
                    state.plans[sheet.id]=empty;state.active=sheet.id
                end
            end
        end
        CollectUnusedRecipes()
        return true
    end,true)
    if ok then
        local message='已删除配方'
        if Active().sourceRecipeId then message=message..'；当前：'..tostring(Active().name)..ResumeRecipeRead() end
        ImportReceipt(true,message,'recipe_deleted');return true,message
    end
    return false,why
end
local function StoreImportedRecipe(record,sharedRoot)
    local key=D.Key(record and record.product)
    if not key or not D.Integer(record.product.count) or not D.Integer(record.id) then return false,'配方身份/每次产量未确认' end
    if type(record.materials)~='table' or #record.materials==0 then return false,'配方材料未确认' end
    local id=tostring(record.id)
    if not state.recipes[id] and Count(state.recipes)>=128 then return false,'已收录配方达到上限' end
    local old=state.recipes[id] or {}
    local saved=Copy(record);saved.id=id;saved.autoObserved=nil;saved.userChosen=old.userChosen
    saved.shared=sharedRoot or old.shared
    saved.libraryHidden=not sharedRoot and old.libraryHidden or nil
    MergeRecipeCosts(saved,old)
    local function Remember(item)
        local itemKey=D.Key(item)
        if not itemKey or not D.Integer(item.count) then return false,'材料身份/用量不完整' end
        if not state.catalog[itemKey] then
            if Count(state.catalog)>=256 then return false,'已收录物品达到上限' end
            state.catalog[itemKey]={item=Copy(item)}
        end
        return true
    end
    local ok,why=Remember(saved.product);if not ok then return false,why end
    for _,item in ipairs(saved.materials)do ok,why=Remember(item);if not ok then return false,why end end
    state.recipes[id]=saved
    local entry=state.catalog[key]
    entry.item=Copy(saved.product);entry.status='ready';entry.base=false
    entry.recipeIds=entry.recipeIds or {}
    local found=false;for _,value in ipairs(entry.recipeIds)do if value==id then found=true end end
    if not found then entry.recipeIds[#entry.recipeIds+1]=id end
    state.choices[key]=id
    return true
end
local function ImportRecipe(reference,count,outputCount,mode,materialKey)
    local ok,err=Running();if not ok then return false,err end
    ok,err=Load();if not ok then return false,err end
    if mode==nil and Active().recipeSheet then mode='recipe' end
    count=D.Integer(count);if not count then return false,'目标件数须为正整数' end
    if outputCount~=nil and not D.Integer(outputCount) then return false,'手填每次产量须为正整数' end
    if type(F.ReadPlanRecipe)~='function' then return false,'配方读取边界不可用' end
    local recipe,readErr,costEvidence=F:ReadPlanRecipe(reference.craftType,{outputCount=outputCount})
    RememberCostProbe(reference.craftType,costEvidence)
    if not recipe then return false,readErr or '配方读取失败' end
    local verified,shareError=D.ValidateRecipeShare(reference,recipe)
    if not verified then return false,shareError end
    if reference.itemType and recipe.product.itemType~=reference.itemType then
        return false,'所选配方与制作页显示的产物不一致，请重新选中配方后再加入。'
    end
    if mode=='material' and not D.ProductMatches(state.catalog[materialKey] and state.catalog[materialKey].item,recipe.product) then
        return false,'分享配方的产物与所选材料不匹配'
    end
    if not recipe.product.name or recipe.product.name=='' or recipe.product.name=='已识别物品' then recipe.product.name=reference.name end
    if mode=='recipe' then Cancel();scanResult=nil end
    local saved,saveErr=Mutate('plan_generic_share_import',function(plan)
        local recorded,recordErr=StoreImportedRecipe(recipe,mode~='material')
        if not recorded then return false,recordErr end
        if mode=='recipe' then return OpenRecipeSheet(recipe,count) end
        if mode=='material' then
            local entry=state.catalog[materialKey];entry.recipeIds=entry.recipeIds or {}
            local found=false;for _,id in ipairs(entry.recipeIds)do if id==recipe.id then found=true end end
            if not found then entry.recipeIds[#entry.recipeIds+1]=recipe.id end
            entry.status='ready';entry.base=false;state.choices[materialKey]=recipe.id
            return true
        end
        return AddTarget(plan,recipe.product,count)
    end,mode=='recipe' or mode=='material')
    if not saved then return false,saveErr end
    local message=(mode=='material' and '已补入材料配方：' or mode=='recipe' and '已独立保存并打开：' or '已加入 ')..tostring(recipe.product.name or '配方产物')
    if type(F.ReadPlanRecipeTypes)=='function' and S.Scheduler then
        local started,scanErr=C:PlanReadRecipes()
        message=message..(started and '；正在展开下级配方' or ('；下级可手动重读：'..tostring(scanErr)))
    end
    ImportReceipt(true,message,'plan_share_imported')
    return true,message
end
function C:PlanImportLink(text,count,outputCount,mode,materialKey)
    local reference,why=D.ParseRecipeShare(text,true)
    if not reference then return false,why end
    return ImportRecipe(reference,count,outputCount,mode,materialKey)
end
function C:RecipeImportLink(text,count,outputCount)return C:PlanImportLink(text,count,outputCount,'recipe')end
function C:PlanImportSelected(count,outputCount)
    local ok,err=Running();if not ok then return false,err end
    if F.NativeAutoEntryAvailable==false then return false,F.NativeAutoEntryReason end
    local surface=S.Services and S.Services.CraftSurfaceV3
    if not surface or type(surface.ReadSelectedRecipe)~='function' then return false,'制作页读取不可用，可使用名称搜索或更多导入。' end
    local reference,why=surface:ReadSelectedRecipe()
    if not reference then return false,why end
    return ImportRecipe(reference,count,outputCount)
end
function C:PlanCancelReceiveShare(owner)
    if pendingShare and (owner==nil or pendingShare.owner==owner) then
        pendingShare=nil;ImportReceipt(true,'已取消接收配方分享','plan_share_receive_cancel')
    end
    return true,'已取消此窗口的接收'
end
function C:PlanReceiveShare(count,outputCount,owner,mode,materialKey)
    receiveTrace.attempts=receiveTrace.attempts+1
    local ok,why=Running();if not ok then TraceReceive('not_running',why);return false,why end
    ok,why=Load();if not ok then TraceReceive('store_unavailable',why);return false,why end
    owner=owner or 'feature:tools_craft'
    if LivePendingShare() and pendingShare.owner==owner and pendingShare.mode==mode and pendingShare.materialKey==materialKey then
        pendingShare=nil;TraceReceive('cancelled');ImportReceipt(true,'已取消接收配方分享','plan_share_receive_cancel');return true,'已取消接收配方分享'
    end
    if not shareCaptureActive then TraceReceive('event_unavailable');return false,'聊天分享事件不可用，请使用更多导入中的粘贴链接。' end
    count=D.Integer(count)
    if not count or (outputCount~=nil and not D.Integer(outputCount)) then return false,'请检查目标件数和每次产量。' end
    if type(S.NowMs)~='function' then return false,'限时接收不可用，请粘贴配方链接。' end
    pendingShare={count=count,outputCount=outputCount,expiresAt=S.NowMs()+60000,planId=state.active,sessionRevision=sessionRevision,owner=owner,mode=mode,materialKey=materialKey}
    TraceReceive('waiting')
    local message='等待本人配方分享（60秒）：在 O 页分享并发送，无需命令；再点可取消。'
    ImportReceipt(true,message,'plan_share_receive_armed');return true,message
end
function C:RecipeReceive(count,outputCount,owner)return C:PlanReceiveShare(count,outputCount,owner,'recipe')end
function C:RecipeReceiveMaterial(key,owner,outputCount)
    local ok,why=Load();if not ok then return false,why end
    if not state.catalog[key] then return false,'先选择需要补配方的材料' end
    return C:PlanReceiveShare(1,outputCount,owner,'material',key)
end
function C:PlanImportOwnChat(sender,message)
    if type(message)~='string' then return false,'not_recipe_command' end
    local command=message:match('^/rsrecipe%s+')~=nil
    local waiting=LivePendingShare()
    if not command and not waiting then return false,'not_recipe_command' end
    receiveTrace.events=receiveTrace.events+1
    local reference,parseError,share=D.ParseRecipeShare(message,true)
    if not reference and not command and not share.hasMarkup then
        receiveTrace.ignored=receiveTrace.ignored+1;return false,'not_recipe_command'
    end
    local running,why=Running();if not running then TraceReceive('not_running',why);return false,why end
    local call=S.FeatureSliceFactory and S.FeatureSliceFactory.Call
    if not call then TraceReceive('identity_unavailable');return false,'player_identity_unavailable' end
    local fullOk,fullName=call('X2Unit:UnitNameWithWorld',nil,'UnitNameWithWorld','player')
    local plainOk,plainName=call('X2Unit:UnitName',nil,'UnitName','player')
    if not ((fullOk and type(fullName)=='string' and sender==fullName) or
        (plainOk and type(plainName)=='string' and sender==plainName)) then TraceReceive('sender_not_local');return false,'not_local_player' end
    receiveTrace.lastShare=share
    if not reference then
        TraceReceive('link_not_recognized',parseError)
        ImportReceipt(false,'未识别配方分享：'..tostring(parseError)..(waiting and '；仍在等待下一条分享' or ''),'plan_share_link_rejected')
        return false,parseError
    end
    local loaded,loadError=Load();if not loaded then TraceReceive('store_unavailable',loadError);return false,loadError end
    waiting=not command and LivePendingShare() or nil
    if not command and not waiting then return false,'recipe_receive_expired' end
    local ok,why=C:PlanImportLink(message,waiting and waiting.count or 1,waiting and waiting.outputCount or nil,
        command and 'recipe' or (waiting and waiting.mode),waiting and waiting.materialKey)
    if ok then
        receiveTrace.accepted=receiveTrace.accepted+1;TraceReceive('imported')
        pendingShare=nil;cached=nil;Notify('plan_share_received')
    end
    if not ok then
        TraceReceive('import_failed',why)
        ImportReceipt(false,why,'plan_share_import_failed')
    end
    return ok,why
end
function C:PlanReadRecipes()
    local ok,err=Running();if not ok then return false,err end
    ok,err=Load();if not ok then return false,err end
    if scan then return false,'配方读取中' end
    if type(F.ReadPlanRecipeTypes)~='function' or type(F.ReadPlanRecipe)~='function' then return false,'配方读取边界不可用' end
    local pending,queued,seen={},{},{}
    local queueLimited=false
    local function Queue(item)
        local key=D.Key(item);if not key then return end
        local hint=D.Integer(item.recipeHint)
        if seen[key] and (not hint or seen[key][hint]) then return end
        local job=queued[key]
        if not job then
            if #pending>=128 then queueLimited=true;return end
            job={item=Copy(item),hints={}};queued[key]=job;pending[#pending+1]=key
        end
        if hint and Count(job.hints)<8 then job.hints[hint]=true end
    end
    for _,target in pairs(Active().targets)do Queue(target) end
    if #pending==0 then return false,'先加入目标' end
    local token=generation
    scan={done=0,pending=#pending,errors=0,failures={},traces={},traceOmitted=0};scanResult=nil
    local function Trace(value)
        if #scan.traces<32 then scan.traces[#scan.traces+1]=tostring(value):sub(1,768)
        else scan.traceOmitted=scan.traceOmitted+1 end
    end
    local function Finish(limited)
        local issues={}
        for _,key in ipairs(Sorted(scan.failures))do
            if #issues>=12 then break end
            issues[#issues+1]=scan.failures[key]
        end
        scanResult={status=(limited or #issues>0) and 'partial' or 'complete',done=scan.done,pending=#pending,
            truncated=limited==true,issues=issues,traces=Copy(scan.traces),traceOmitted=scan.traceOmitted}
        scan=nil;S.Scheduler:RemoveTask(TASK)
        ImportReceipt(#issues==0 and not limited,limited and '配方展开达到本轮上限；仍有下级待核对' or
            (#issues>0 and ('已收录配方；'..#issues..' 类下级待核对：'..issues[1].reason) or '配方材料链已展开'),
            limited and 'plan_recipe_limit' or 'plan_recipes_done')
    end
    local function Drain()
        if token~=generation or F.enabled~=true then return end
        -- 先判断预算再出队，不能取走第65项后误报全部完成。
        if #pending==0 or scan.done>=64 then Finish(#pending>0 or queueLimited);return end
        local key=table.remove(pending,1)
        local job=queued[key];queued[key]=nil
        local item=job.item
        do
            seen[key]=seen[key] or {}
            for hint in pairs(job.hints)do seen[key][hint]=true end
            scan.done=scan.done+1
            local ids,why=F:ReadPlanRecipeTypes(item.itemType,item)
            local selected=state.recipes[ChosenRecipe(key) or '']
            -- 分享或手选配方优先保留；反查可能只列出另一种同产物配方，不能静默换方。
            if selected and not D.ProductMatches(item,selected.product) then selected=nil end
            local candidates,known={},{}
            local function Candidate(id)
                id=D.Integer(id)
                if id and not known[id] and #candidates<8 then candidates[#candidates+1]=id;known[id]=true end
            end
            if selected then Candidate(selected.id) end
            -- item_info.craftType 是独立的配方线索，读取后仍须核验产物身份；不能当物品ID。
            for _,hint in ipairs(Sorted(seen[key]))do Candidate(hint) end
            for _,id in ipairs(ids or {})do Candidate(id) end
            if #candidates>0 or ids then ids=candidates end
            Trace('item='..key..' name='..tostring(item.name or '')..' lookup='..tostring(why or 'ok')..
                ' candidates='..table.concat(candidates,','))
            if ids then
                local records={};local failure=why
                for index,id in ipairs(ids)do
                    if index>8 then break end
                    local previous=state.recipes[tostring(id)]
                    local options={expectedProduct=item}
                    if previous and previous.outputSource=='manual' then options.outputCount=previous.product.count end
                    local record,readError,evidence=F:ReadPlanRecipe(id,options)
                    RememberCostProbe(id,evidence)
                    local fields={}
                    for _,field in ipairs({'productStatus','materialStatus','productRows','materialRows','productItemType','productGrade','productCount',
                        'productUseGrade','nativeProductGrade','productTruncated','materialTruncated','productError','materialError','productShape','materialShape','materialFields'})do
                        if evidence and evidence[field]~=nil then fields[#fields+1]=field..'='..tostring(evidence[field]) end
                    end
                    Trace('item='..key..' candidate='..tostring(id)..' result='..tostring(readError or (record and 'read' or 'unknown'))..
                        (record and (' productKey='..tostring(D.Key(record.product))) or '')..' '..table.concat(fields,' '))
                    if not record then failure=tostring(readError or '配方字段不完整') end
                    if not record and selected and tostring(id)==selected.id then record=Copy(selected) end
                    if record and previous and (not record.product.name or record.product.name=='') then record.product.name=previous.product.name end
                    if record and D.ProductMatches(item,record.product) then
                        if record.product.name=='已识别物品' or not record.product.name then record.product.name=item.name end
                        records[#records+1]=record
                    elseif record then failure='配方产物身份/品质与材料不匹配' end
                end
                local saved=Mutate('plan_recipe_observed',function()
                    local addedRecipes=0
                    for _,record in ipairs(records)do if not state.recipes[record.id] then addedRecipes=addedRecipes+1 end end
                    if Count(state.recipes)+addedRecipes>128 then return false,'配方缓存达到上限' end
                    local entry=state.catalog[key] or {item=Copy(item),autoObserved=true}
                    entry.recipeIds={};entry.status=#records>0 and 'ready' or ((#ids>0 and #records==0) and 'recipe_fields_unknown' or why)
                    -- Native 空返回尚无可靠无配方契约；只有用户明确确认的原料可作完整叶子。
                    entry.base=entry.baseSource=='manual' and entry.base==true
                    for _,record in ipairs(records)do
                        local old=state.recipes[record.id]
                        record.autoObserved=old and old.autoObserved or (not old and true or nil)
                        record.userChosen=old and old.userChosen or nil
                        old=old or {}
                        MergeRecipeCosts(record,old)
                        record.shared,record.libraryHidden=old.shared,old.libraryHidden
                        state.recipes[record.id]=Copy(record);entry.recipeIds[#entry.recipeIds+1]=record.id
                        for _,m in ipairs(record.materials)do
                            local k=D.Key(m)
                            if not state.catalog[k] then
                                if Count(state.catalog)>=256 then return false,'物品目录达到上限' end
                                state.catalog[k]={item=Copy(m),autoObserved=true}
                            end
                        end
                    end
                    state.catalog[key]=entry
                    if not selected and #records==1 then state.choices[key]=records[1].id end
                    return true
                end)
                if saved then
                    local recipe=state.recipes[ChosenRecipe(key) or '']
                    if recipe then
                        local _,certain=D.ProductMatches(item,recipe.product)
                        scan.failures[key]=not certain and {key=key,itemType=item.itemType,name=item.name,
                            reason='产物品质待核，已显示下级预览'} or nil
                        for _,m in ipairs(recipe.materials)do Queue(m) end
                    elseif not (state.catalog[key] and state.catalog[key].base) then
                        scan.failures[key]={key=key,itemType=item.itemType,name=item.name,
                            reason=tostring(failure or (#records>1 and '有多个配方，请选择' or '未返回下级配方；可补配方或确认为原料')):sub(1,192)}
                    end
                else
                    scan.failures[key]={key=key,itemType=item.itemType,name=item.name,reason='下级配方保存失败'}
                end
            else scan.failures[key]={key=key,itemType=item.itemType,name=item.name,reason=tostring(why or '配方读取失败'):sub(1,192)} end
        end
        if scan then scan.pending=#pending;cached=nil end
    end
    local added,why=S.Scheduler:AddTask(TASK,100,Drain,false,F,'P2',1)
    if added~=true then scan=nil;return false,why end
    Notify('plan_recipes_start');return true,'已开始有界读取配方链'
end
function C:PlanRefreshInventory(includeBank)
    local ok,err=Running();if not ok then return false,err end
    local service=S.Services and S.Services.InventorySnapshotV3
    if not service then return false,'库存服务不可用' end
    -- 不与历史箱子相加：同一次明确操作重读背包和可读银行；通用保管箱无稳定身份，暂不纳入。
    local ledger={};local complete=true
    if includeBank then
        if not S.ApiImports or not S.ApiImports:Acquire(OWNER,{'X2Bank:Capacity','X2Bank:GetBagItemInfo','ADDON:GetContent','ADDON:GetContentMainScriptPosVis'}) then
            inventoryComplete=false;inventoryScope=nil;inventoryNote='银行读取能力不可用，请重新核对'
            Notify('plan_inventory_unavailable');return false,inventoryNote
        end
        local bag=S.Features and S.Features.tools_bag
        local window=bag and type(bag.GetStorageWindowContext)=='function' and bag:GetStorageWindowContext('bank') or nil
        if not window or window.status~='ready' or window.visible~=true then
            inventoryComplete=false;inventoryScope=nil;inventoryNote='请打开银行并等待窗口可见后重新核对'
            Notify('plan_inventory_unavailable');return false,inventoryNote
        end
    end
    for _,scope in ipairs(includeBank and {'bag','bank'} or {'bag'})do
        local snapshot,why=service:BuildSnapshot(scope)
        if not snapshot or snapshot.truncated or snapshot.readErrors~=0 or snapshot.unknown~=0 or snapshot.fallback~=0 or snapshot.fallbackUsed==true
            or (scope=='bank' and (not tonumber(snapshot.capacity) or tonumber(snapshot.capacity)<=0)) then
            complete=false;inventoryNote=tostring(why or (scope=='bank' and '银行未打开或容量不可确认' or '库存字段不完整'))
        else
            local rows={}
            for _,row in ipairs(snapshot.rows)do rows[#rows+1]={itemType=tonumber(row.itemType),grade=row.grade,count=row.stack}end
            if not D.ReplaceSnapshot(ledger,scope,revision+1,rows,true) then complete=false end
        end
    end
    inventory=D.Inventory(ledger)
    -- 背包读取成功不代表银行为空；只在两处都核对后宣称库存完整。
    inventoryScope=complete and (includeBank and 'bag_bank' or 'bag') or nil
    inventoryComplete=complete and includeBank==true
    bagInventory=ledger.bag and Copy(ledger.bag.counts) or {}
    if complete then inventoryNote=includeBank and '本次核对：背包＋银行；不含保管箱，移动后请重新核对' or '本次核对：背包；银行/保管箱未纳入' end
    Notify('plan_inventory');return complete,inventoryNote
end
function C:PlanCompare()
    local ok,err=Load();if not ok then return false,err end
    Projection()
    local plan=Snapshot();local facts=Facts(plan)
    recommendation={revision=revision,result=D.Compare(plan,facts)}
    return true,Copy(recommendation)
end
function C:PlanApplyRecommendation(expected,key)
    Projection()
    if not recommendation or expected~=revision or recommendation.revision~=revision then return false,'建议已失效，请重新比较' end
    if not recommendation.result.recommendation.available then return false,'缺少有效成本，无法采纳建议' end
    local allocation=Copy(recommendation.result.recommendation.allocations)
    undo=Copy(Active().allocations)
    return Mutate('plan_recommendation_apply',function(plan)
        if key then plan.allocations[key]=Copy(allocation[key]) else plan.allocations=allocation end
        return true
    end)
end
function C:PlanUndo()
    if not undo then return false,'没有可撤销的来源调整' end
    local previous=Copy(undo)
    local ok,err=Mutate('plan_undo',function(plan)plan.allocations=previous;return true end)
    if ok then undo=nil end;return ok,err
end
function C:PlanSearch(key)
    local ok,err=Running();if not ok then return false,err end
    ok,err=Load();if not ok then return false,err end
    local item=state.catalog[key] and state.catalog[key].item
    if not item or not item.name or item.name=='' then return false,'物品名称未确认，请先读取配方' end
    local bridge=S.Services and S.Services.AuctionSearchBridgeV3
    if not bridge then return false,'拍卖搜索服务不可用' end
    return bridge:Search(OWNER..':search',item.name,{priority='user'})
end
function C:PlanCalibrate(key)
    local ok,err=Running();if not ok then return false,err end
    ok,err=Load();if not ok then return false,err end
    if quoteBatch then return false,'查询中，请等待完成或停止本轮查询' end
    local queue=S.Services and S.Services.PriceQuoteQueueV3
    if not queue then return false,'报价队列不可用' end
    local plan=Projection();local rows,seen,truncated={},{},false
    -- 查价遍历配方树，不能只取实际采购行，否则“购买”分支下面的预览材料永远查不到。
    local function Walk(itemKey,depth)
        if seen[itemKey] then return end
        if depth>24 or #rows>=512 then truncated=true;return end
        seen[itemKey]=true
        local entry=state.catalog[itemKey]
        if entry and entry.item then rows[#rows+1]={key=itemKey,item=Copy(entry.item)} end
        if key then return end
        local recipe=plan.recipes[(plan.choices or {})[itemKey] or '']
        for _,material in ipairs(recipe and recipe.materials or {})do
            local child=D.Key(material);if child then Walk(child,depth+1) end
        end
    end
    if key then Walk(key,0) else for _,target in ipairs(plan.targets or {})do Walk(target.key,0) end end
    if #rows==0 then return false,'当前没有可查询的配方物品' end
    quoteGeneration=quoteGeneration+1;local token=quoteGeneration
    local batch={status='querying',total=#rows,requested=0,completed=0,failed=0,empty=0,truncated=truncated,
        startedAt=S.NowMs and S.NowMs() or 0}
    quoteBatch,quoteResult=batch,nil
    priceAudit={batch=batch,results={},sessionRevision=sessionRevision,generation=token,planId=state.active}
    local Next
    Next=function()
        if token~=quoteGeneration or quoteBatch~=batch then return end
        local row=rows[batch.completed+1]
        if not row then
            batch.status='completed';batch.completedAt=S.NowMs and S.NowMs() or 0
            priceAudit.currentRequester=nil;quoteResult=Copy(batch);quoteBatch=nil;Notify('plan_price_complete');return
        end
        batch.currentName=row.item.name;batch.currentKey=row.key;batch.requested=batch.requested+1
        local grade,gradeSource=QuoteGrade(row.key,row.item)
        local gradeResolution
        if grade==nil and row.item.grade==nil and type(F.ReadPlanRecipe)=='function' then
            local id=ChosenRecipe(row.key)
            if id then
                -- 已保存计划可能只有产物 ID。明确询价时补读该根配方的品质，不改目标键、不重置数量或手工成本。
                local record,why,evidence=F:ReadPlanRecipe(tonumber(id),{expectedProduct=row.item,forceNative=true})
                if token~=quoteGeneration or quoteBatch~=batch then return end
                RememberCostProbe(id,evidence)
                gradeResolution={recipeId=id,error=why,itemInfo=Copy(evidence and evidence.itemInfo),
                    productGrade=record and record.product and record.product.grade}
                if record and select(2,D.ProductMatches(row.item,record.product)) then
                    local observed=D.ResolveRequirementGrade(row.item,record.product)
                    if observed~=nil then
                        quoteGradeOverrides[row.key]={recipeId=id,grade=observed};cached=nil
                        grade,gradeSource=QuoteGrade(row.key,row.item)
                    end
                end
            end
        end
        local owner=OWNER..':quote:'..token..':'..row.key
        local result={status='querying',name=row.item.name,itemType=row.item.itemType,recipeGrade=row.item.grade,
            quoteGrade=grade,gradeSource=gradeSource,gradeResolution=gradeResolution,requester=owner,requestedAt=S.NowMs and S.NowMs() or 0}
        quoteItems[row.key]=result;priceAudit.results[row.key]=result;priceAudit.currentRequester=owner
        Notify('plan_price_dispatch')
        if token~=quoteGeneration or quoteBatch~=batch then return end
        quoteOwners[owner]=true
        local consumed=false
        local function Done(snapshot)
            if consumed or token~=quoteGeneration or quoteBatch~=batch then return end
            consumed=true;quoteOwners[owner]=nil
            local status=type(snapshot)=='table' and snapshot.status or 'failed'
            local reason=type(snapshot)=='table' and tostring(snapshot.error or snapshot.reason or status) or 'invalid_result'
            if type(snapshot)=='table' then
                for _,field in ipairs({'requestedAt','dispatchedAt','queueDeadlineAt','deadlineAt','completedAt','searchGeneration',
                    'price','observedPrice','priceAccepted','referenceStored','priceDecision','priceSource'})do result[field]=snapshot[field] end
                result.code=snapshot.errorCode
            end
            result.reason=reason;result.code=result.code or (status~='ready' and reason or nil)
            result.completedAt=result.completedAt or (S.NowMs and S.NowMs() or 0)
            priceAudit.currentRequester=nil
            if status=='blocked' and (reason=='native_auction_visible' or reason=='native_auction_visibility_unknown') then
                result.status='stopped'
                CancelQuotes(reason);Notify('plan_price_stopped');return
            end
            local empty=reason=='auction_search_empty'
            result.status=status=='ready' and 'ready' or empty and 'none' or 'failed'
            batch.completed=batch.completed+1
            if empty then batch.empty=batch.empty+1 elseif status~='ready' then batch.failed=batch.failed+1 end
            Next()
        end
        local accepted,why=queue:RequestQuote(owner,row.item.itemType,grade,Done,nil,
            {force=true,priority='user',singleQuery=true,searchName=row.item.name,waitForDispatch=true,
             deadlineAt=(S.NowMs and S.NowMs() or 0)+600000})
        if accepted~=true then Done({status='failed',errorCode=why,
            error=why=='strict_search_grade_invalid' and '物品品质待核，本项未发起拍卖搜索' or why or 'request_rejected'}) end
    end
    Next()
    return true,'开始逐个查询 '..#rows..' 个物品；打开拍卖行会停止本轮查询'
end
function C:PlanCancelPrices()CancelQuotes('cancelled');Notify('plan_price_stopped');return true,'已停止价格查询' end
function C:PlanCancel()Cancel();Notify('plan_cancel');return true end
local baseDisable=F.Disable
function F:Disable(reason)
    Cancel();inventory={};bagInventory={};inventoryComplete=false;inventoryScope=nil;inventoryNote='库存待重新核对';undo=nil
    if S.Events and type(S.Events.UnsubscribeInternalOwner)=='function' then S.Events:UnsubscribeInternalOwner(priceOwner) end
    if S.Events and type(S.Events.UnsubscribeOwner)=='function' then S.Events:UnsubscribeOwner(shareOwner) end
    shareCaptureActive=false;pendingShare=nil
    cached=nil;return baseDisable(self,reason)
end
local baseDemand=F.ReconcileDemand
function F:ReconcileDemand(lease,before,after)
    local ok,err=baseDemand(self,lease,before,after)
    if ok~=true then return ok,err end
    if S.Events and type(S.Events.UnsubscribeInternalOwner)=='function' then S.Events:UnsubscribeInternalOwner(priceOwner) end
    if S.Events and type(S.Events.UnsubscribeOwner)=='function' then S.Events:UnsubscribeOwner(shareOwner) end
    shareCaptureActive=false
    if (tonumber(after and after.count) or 0)<=0 then
        ResetSession()
    elseif S.Events and type(S.Events.SubscribeInternal)=='function' then
        local prices=S.Services and S.Services.MaterialPriceServiceV3
        if prices and prices.Topic then
            local subscribed,why=S.Events:SubscribeInternal(prices.Topic,priceOwner,function()
                if F.enabled and (tonumber(F.consumerCount) or 0)>0 then Notify('plan_shared_price_changed') end
            end)
            if subscribed~=true then return false,why end
        end
    end
    if (tonumber(after and after.count) or 0)>0 and S.Events and type(S.Events.SubscribeOptional)=='function' then
        if type(S.Events.BindOwner)=='function' then S.Events:BindOwner(shareOwner,F.Id) end
        shareCaptureActive=S.Events:SubscribeOptional('CHAT_MESSAGE',shareOwner,function(owner,...)
            if F.enabled then
                -- 只保留参数类型和链接 ID/标记，不保存聊天正文或发送者，便于区分参数错位与链接解析失败。
                if LivePendingShare() then
                    local packet={argCount=select('#',...),slots={}}
                    for index=1,math.min(packet.argCount,8)do
                        local value=select(index,...);local slot={kind=type(value)}
                        if type(value)=='string' then
                            slot.bytes=#value
                            if index~=3 then local _,_,summary=D.ParseRecipeShare(value,true);slot.share=summary end
                        end
                        packet.slots[index]=slot
                    end
                    receiveTrace.lastPacket=packet
                    local messageSlot=packet.slots[4]
                    if messageSlot and messageSlot.share and messageSlot.share.hasMarkup then
                        receiveTrace.lastCandidatePacket=packet
                    end
                end
                local sender,message=select(3,...),select(4,...)
                return C:PlanImportOwnChat(sender,message)
            end
        end)==true
        cached=nil
    end
    return true
end
F.CraftPlanContractVersion=3

------------------------------------------------------------------------
-- 跑商材料报价 V3：每次操作只查缺失身份一次；缓存/SWR 与前台有界任务分离。
-- 不拥有配方数量、售价或毛利算法；不直接调用 Native；不新增周期 Scheduler lane。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Services = S.Services or {}
local T = { version = 3, ContractVersion = 1, presentationBoundary = 'service_only',
    operations = {}, ownerEpochs = {}, sequence = 0, timeoutMs = 5000, maxOperations = 16,
    failures = {}, failureTtlMs = 30000, maxFailures = 512 }
S.Services.TradeMaterialQuoteServiceV3 = T
local function Now() return type(S.NowMs) == 'function' and (tonumber(S.NowMs()) or 0) or 0 end
local function Copy(v)
    if type(v) ~= 'table' then return v end
    local out = {}; for k, x in pairs(v) do out[k] = Copy(x) end; return out
end
local function Identity(m)
    -- 中文维护：普通材料品质 0 是有效身份；未知/NaN 不能默认成 1 或进入共享价格缓存。
    local id, grade = tonumber(m.itemType), tonumber(m.itemGrade)
    if not id or id ~= id or id == math.huge or id < 1 or id ~= math.floor(id)
        or not grade or grade ~= grade or grade < 0 or grade > 20 or grade ~= math.floor(grade) then return nil end
    return tostring(id)..':'..tostring(grade), id, grade
end
local function Snapshot(op)
    return { requester = op.requester, active = op.active, total = #op.materials,
        known = op.known, unknown = op.unknown, complete = not op.active and op.unknown == 0,
        state = op.active and 'quoting' or (op.unknown == 0 and 'ready' or (op.known > 0 and 'partial' or 'failed')),
        -- 中文维护：TXT 要能区分材料尚在等待与发包后的超时，保留当前阶段的预算来源。
        createdAt = op.createdAt, completedAt = op.completedAt, results = Copy(op.results),
        deadlineAt=op.deadlineAt, stageStartedAt=op.stageStartedAt, stageBudgetMs=op.stageBudgetMs,
        queueDepthAtStage=op.queueDepthAtStage, currentQuoteKey=op.currentQuoteKey }
end
local function Notify(op)
    if type(op.callback) == 'function' then pcall(op.callback, Snapshot(op)) end
end
-- 中文维护（2026-10-02）：TXT 须能解释“再次点击为何没有再发包”。只读现有操作与
-- 失败缓存的身份/时间/结果，不清过期项、不延长 TTL、不触发重试，也不暴露 callback。
function T:DescribeDiagnostics()
    local operations = {}
    for requester, op in pairs(self.operations) do
        local snapshot = Snapshot(op)
        snapshot.owner, snapshot.nativeRequester = op.owner, op.nativeRequester
        snapshot.materials = Copy(op.materials)
        operations[requester] = snapshot
    end
    return { version=self.version, timeoutMs=self.timeoutMs, failureTtlMs=self.failureTtlMs,
        -- 中文维护：使新 TXT 能明确证明分阶段计时补丁已加载，无须改变整个 Addon 版本号。
        deadlinePolicy='per_material_bounded_queue_then_5s_response',
        maxFailures=self.maxFailures, maxOperations=self.maxOperations, capturedAt=Now(),
        operations=operations, failures=Copy(self.failures), ownerEpochs=Copy(self.ownerEpochs),
        coverage='retained_operations_and_failure_cache; describe_does_not_expire_or_retry' }
end
local function RememberFailure(key, result)
    -- 交互阻断不是无货；玩家关闭拍卖行后的新操作必须重新核对可见性，不能回放过期阻断。
    -- 中文维护（215703）：排队/响应超时不是无货证据，不把它缓存三十秒阻止用户重新显式操作。
    if result.status == 'blocked' or result.status == 'timeout' then return end
    local count, oldest, at = 0, nil, math.huge
    for k, value in pairs(T.failures) do count=count+1;if value.at < at then oldest,at=k,value.at end end
    if count >= T.maxFailures and T.failures[key] == nil then T.failures[oldest] = nil end
    T.failures[key] = { at = Now(), result = Copy(result) }
end
local function AddResult(op, material, result)
    if op.results[material.quoteKey] ~= nil then return end
    result = Copy(result or {});result.materialKey = material.materialKey
    local messages = {
        native_auction_visible = '原生拍卖行正在使用；已停止本次查询，关闭后可重试',
        native_auction_visibility_unknown = '无法确认原生拍卖窗口已关闭；本次查询已停止',
        auction_user_search_pending = '原生拍卖搜索仍在处理；本次查询已停止',
        auction_response_drain = '正在隔离旧拍卖回包；本次查询已停止',
        strict_buyout_not_found = '没有匹配身份与品质的有效一口价；材料价格未知',
        -- 保持未知价格；空回包可能来自过滤/名称/Native 缓存，不能把它说成品质不匹配或确定无货。
        auction_search_empty = '原生搜索返回 0 条挂单；材料价格未知，请导出诊断核对搜索回包',
        auction_search_count_invalid = '原生搜索结果数量不可读；材料价格未知',
        quote_deadline = '实时查询超时；部分材料价格未知',
        quote_queue_wait_timeout = '报价排队等待超时；材料价格未知，可重新询价',
        search_name_unavailable = '材料搜索名称不可用；材料价格未知',
    }
    result.error = messages[result.error] or result.error
    result.itemType, result.itemGrade = material.itemType, material.itemGrade
    op.results[material.quoteKey] = result
    if result.status == 'ready' and tonumber(result.price) and result.price > 0 then
        op.known = op.known + 1
    else op.unknown = op.unknown + 1 end
end
local function Finish(op)
    if not op.active then return end
    op.active, op.completedAt = false, Now()
    if T.operations[op.requester] == op then T.operations[op.requester] = nil end
    if S.Scheduler then S.Scheduler:RemoveTask(op.taskName) end
    Notify(op)
end
function T:CancelRequester(requester)
    local op = self.operations[tostring(requester or '')]
    if op == nil then return true end
    op.active = false; op.cancelled = true; self.operations[op.requester] = nil
    if S.Scheduler then S.Scheduler:RemoveTask(op.taskName) end
    local queue = S.Services.PriceQuoteQueueV3
    if queue then queue:CancelRequester(op.nativeRequester) end
    return true
end
function T:CancelOwner(owner)
    owner = tostring(owner or 'life_trade')
    self.ownerEpochs[owner] = (self.ownerEpochs[owner] or 0) + 1
    local requests = {}
    for requester,op in pairs(self.operations) do if op.owner == tostring(owner or 'life_trade') then requests[#requests+1]=requester end end
    for _,requester in ipairs(requests) do self:CancelRequester(requester) end
    local prices = S.Services.MaterialPriceServiceV3
    if prices and type(prices.CancelRevalidationOwner)=='function' then prices:CancelRevalidationOwner(owner) end
    return true
end
function T:QueueRefresh(materials, options)
    local prices = S.Services.MaterialPriceServiceV3
    if not prices or type(prices.QueueRevalidate) ~= 'function' then return false, 'material_price_service_unavailable' end
    options = Copy(options or {});options.singleQuery=true;options.cachedOnly=true
    return prices:QueueRevalidate(materials, options)
end
local function NextMissing(op)
    if not op.active or T.operations[op.requester] ~= op then return end
    local material
    while op.index <= #op.materials do
        local m = op.materials[op.index];op.index=op.index+1
        if op.results[m.quoteKey] == nil then material=m;break end
    end
    if material == nil then Finish(op);return end
    local prices = S.Services.MaterialPriceServiceV3
    -- 相邻/共享配方刚完成的材料可直接复用，无需第二次发包。
    local price,meta = prices:GetTradePrice(material.itemType,material.itemGrade)
    if price then AddResult(op,material,{status='ready',price=price,cached=true,freshness=meta.freshness});Notify(op);return NextMissing(op) end
    local failure = T.failures[material.quoteKey]
    if failure and Now() >= failure.at and Now()-failure.at < T.failureTtlMs then
        AddResult(op,material,failure.result);Notify(op);return NextMissing(op)
    end
    -- 中文维护（215703）：整张配方不能从点击时共享五秒总预算，否则相邻货物排队就耗尽期限。
    -- 每个有限材料阶段独立有界：前方最多 Queue.maxQueue 个槽，每槽按原 Query 隔离上限加 lane
    -- 间隔预算，外加本材料五秒响应期。不加查询/重试、不缩短原生隔离，也不扫描 Native。
    local queue=S.Services.PriceQuoteQueueV3
    local query=S.Services.AuctionQueryV3
    local depth=queue and (#(queue.queue or {})+#(queue.admissionWaiting or {})+(queue.pending and 1 or 0)) or 0
    local interval=queue and tonumber(queue.intervalMs) or 1000
    local isolation=query and tonumber(query.timeoutMs) or 8000
    local budget=T.timeoutMs+(math.min(depth,queue and queue.maxQueue or 64)+1)*(isolation+interval)
    op.stageStartedAt,op.stageBudgetMs,op.queueDepthAtStage,op.currentQuoteKey=Now(),budget,depth,material.quoteKey
    op.deadlineAt=Now()+budget
    local added=S.Scheduler and type(S.Scheduler.AddOneShot)=='function' and S.Scheduler:AddOneShot(op.taskName,budget,function()
        if not op.active or T.operations[op.requester]~=op then return end
        -- 只撤销 watcher；在途无 token Native 仍按原 timeout 隔离。遗漏项全部明确未知，不写失败缓存。
        if queue then queue:CancelRequester(op.nativeRequester) end
        for _,m in ipairs(op.materials)do if not op.results[m.quoteKey] then
            AddResult(op,m,{status='timeout',error='报价排队等待超时，部分材料价格未知'})
        end end
        Finish(op)
    end,T,'P2',1)
    if added~=true then
        for _,m in ipairs(op.materials)do if not op.results[m.quoteKey] then AddResult(op,m,{status='failed',error='timeout_guard_unavailable'})end end
        Finish(op);return
    end
    local ok,err = prices:RequestQuoteOnce(material,function(result)
        if not op.active or T.operations[op.requester] ~= op or op.results[material.quoteKey] then return end
        -- 每个回调只能完成本 operation 的当前身份；共享事件不能替代此归属证据。
        if type(result) ~= 'table' or tonumber(result.itemType) ~= material.itemType or tonumber(result.itemGrade) ~= material.itemGrade then return end
        if result.status ~= 'ready' then RememberFailure(material.quoteKey,result) end
        AddResult(op,material,result);Notify(op);NextMissing(op)
    end,{requester=op.nativeRequester,priority='user',deadlineAt=op.deadlineAt,waitForDispatch=true})
    if ok ~= true then
        local result={status='failed',error=tostring(err or 'quote_unavailable')}
        RememberFailure(material.quoteKey,result);AddResult(op,material,result);Notify(op);NextMissing(op)
    end
end
function T:RequestRecipe(requester, materials, callback, options)
    requester=tostring(requester or '');options=type(options)=='table' and options or {}
    if requester=='' then return false,'requester_required' end
    if self.operations[requester] then return true,'pending' end
    local prices=S.Services.MaterialPriceServiceV3
    if not prices or type(prices.GetTradePrice)~='function' or type(prices.RequestQuoteOnce)~='function' then return false,'material_price_service_unavailable' end
    local count=0;for _ in pairs(self.operations)do count=count+1 end
    if count>=self.maxOperations then return false,'too_many_operations' end
    self.sequence=self.sequence+1
    local op={requester=requester,owner=tostring(options.owner or 'life_trade'),callback=callback,active=true,
        materials={},results={},known=0,unknown=0,index=1,createdAt=Now(),
        taskName='v3_trade_material_deadline:'..self.sequence,nativeRequester='trade_material:'..self.sequence}
    op.ownerEpoch = self.ownerEpochs[op.owner] or 0
    local seen,refresh={},{}
    for _,raw in ipairs(type(materials)=='table' and materials or {})do
        if type(raw)=='table' and raw.auctionable~=false and raw.includeInCost~=false then
            local key,id,grade=Identity(raw)
            if key and not seen[key] then
                seen[key]=true;local m=Copy(raw);m.quoteKey,m.itemType,m.itemGrade=key,id,grade;op.materials[#op.materials+1]=m
                local price,meta=prices:GetTradePrice(id,grade)
                if price then
                    AddResult(op,m,{status='ready',price=price,cached=true,freshness=meta.freshness})
                    if meta.freshness=='warm' or meta.freshness=='stale' then refresh[#refresh+1]=m end
                end
            elseif not key then
                -- 未知身份也必须计入未知成本；不偷偷省略，更不能用零填补。
                local m=Copy(raw);m.quoteKey='unknown:'..(#op.materials+1);op.materials[#op.materials+1]=m
                AddResult(op,m,{status='unavailable',error='material_identity_unavailable'})
            end
        end
    end
    self.operations[requester]=op
    if op.known+op.unknown < #op.materials then
        -- 当前缺价阶段在 NextMissing 中安装一次性 guard；已缓存配方仍立即完成，不占用排队预算。
        Notify(op);NextMissing(op)
    else Finish(op) end
    -- 前台缺价先入队；已有旧价后台刷新不能挡住本次毛利终态。
    if #refresh>0 and not op.cancelled and op.ownerEpoch == (self.ownerEpochs[op.owner] or 0) then self:QueueRefresh(refresh,{owner=op.owner}) end
    return true,op.active and 'queued' or (op.unknown == 0 and 'ready' or (op.known > 0 and 'partial' or 'failed'))
end

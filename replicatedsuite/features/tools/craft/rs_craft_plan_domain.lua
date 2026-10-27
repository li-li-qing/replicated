-- Replicated Suite · 制作计划纯计算
-- 所有输入均为 detached 基础值；这里不读取游戏、不询价、不写存档。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local D = { MaxQuantity = 1000000000, MaxNodes = 512, MaxDepth = 24 }
ReplicatedSuite.CraftPlanDomain = D
local function Integer(v, zero)
    local n = tonumber(v)
    if not n or n ~= n or n > D.MaxQuantity or n < (zero and 0 or 1) or n ~= math.floor(n) then return nil end
    return n
end
D.Integer = Integer
-- craftinglist 分享入口使用 |if<craftType>;名称|r；只解码明确配方链接，不执行导入文本。
function D.ParseRecipeShare(value)
    if type(value)~='string' or value=='' or #value>2048 then return nil,'请粘贴一条配方分享链接（最多 2048 字节）' end
    local id,name,count=nil,nil,0
    for candidate,label in value:gmatch('|if(%d+)[;:]([^|]*)')do
        count=count+1;id=Integer(candidate);name=label
    end
    if count~=1 or not id then return nil,'需要一条有效配方链接，不能把物品编号直接作为配方编号' end
    name=tostring(name or ''):match('^%s*(.-)%s*$')
    if #name>192 or name:find('[%c]') then name='' end
    return {craftType=id,name=name~='' and name or nil,source='craft_share_link'}
end
local function Copy(v)
    if type(v) ~= 'table' then return v end
    local r = {}; for k,x in pairs(v) do r[k] = Copy(x) end; return r
end
D.Copy = Copy
function D.Key(item)
    if type(item) ~= 'table' or not Integer(item.itemType) then return nil end
    if item.grade ~= nil and not Integer(item.grade, true) then return nil end
    return tostring(Integer(item.itemType)) .. ':' .. tostring(item.grade == nil and '*' or item.grade) .. ':' .. tostring(item.variant or '*')
end
local function Keys(t)
    local r={}; for k in pairs(t or {}) do r[#r+1]=k end; table.sort(r); return r
end

function D.Evaluate(plan, facts, route)
    plan, facts = plan or {}, facts or {}
    local result = { rows={}, byKey={}, purchases={}, steps={}, issues={}, missingPrices={},
        complete=true, costComplete=true, valueComplete=true, laborComplete=true, priceStale=false, cashCopper=0, valueCopper=0,
        ownedValueCopper=0, labor=0, feeCopper=0, route=route or 'manual' }
    local function Issue(code, key)
        result.issues[#result.issues+1]={code=code,key=key}; result.complete=false
    end
    local demands, items, parents, mark, order, cyclic, targetKeys = {}, {}, {}, {}, {}, {}, {}
    local recipes, allocations = facts.recipes or {}, plan.allocations or {}
    local nodes, edges = 0, 0
    local function Allocation(key)
        if route=='buy' then return {mode='buy'} end
        if route=='raw' then return {mode='craft'} end
        -- 目标默认制作，中间材料默认购买；已有手动安排始终优先。
        return allocations[key] or {mode=targetKeys[key] and 'craft' or 'buy'}
    end
    local function Visit(key, depth)
        if mark[key]==1 then cyclic[key]=true; Issue('cycle',key); return end
        if mark[key]==2 then return end
        nodes=nodes+1
        if nodes>D.MaxNodes or depth>D.MaxDepth then Issue('graph_limit',key); return end
        mark[key]=1
        local recipe, a = recipes[key], Allocation(key)
        if a.mode~='buy' and (a.mode~='mixed' or tonumber(a.craft)~=0) and type(recipe)=='table' then
            for _, material in ipairs(recipe.materials or {}) do
                local child = D.Key(material)
                if not child or type(material)~='table' or not Integer(material.count) then Issue('invalid_material',key)
                else
                    edges=edges+1
                    if edges>4096 then Issue('edge_limit',key); break end
                    items[child]=material
                    parents[child]=parents[child] or {}; parents[child][key]=true
                    Visit(child,depth+1)
                end
            end
        end
        mark[key]=2; order[#order+1]=key
    end
    local targetCount=0
    for _,target in ipairs(plan.targets or {}) do
        targetCount=targetCount+1
        if targetCount>64 then Issue('target_limit'); break end
        local key = D.Key(target)
        local count = type(target)=='table' and Integer(target.count) or nil
        if not key or not count then Issue('invalid_target')
        else
            items[key]=target; targetKeys[key]=true; demands[key]=(demands[key] or 0)+count
            if demands[key]>D.MaxQuantity then Issue('quantity_limit',key); demands[key]=0 end
        end
    end
    if targetCount==0 then Issue('empty_plan') end
    for _,key in ipairs(Keys(demands)) do Visit(key,1) end
    local remaining=Copy(facts.inventory or {})
    local remainingBag=Copy(facts.bagInventory or facts.inventory or {})
    local function Matches(requirement,stock)
        local rt,rg,rv=requirement:match('^([^:]+):([^:]+):(.+)$')
        local st,sg,sv=stock:match('^([^:]+):([^:]+):(.+)$')
        return rt~=nil and rt==st and (rg=='*' or rg==sg) and (rv=='*' or rv==sv)
    end
    local stockKeys=Keys(remaining)
    local matchCounts={}
    for _,stock in ipairs(stockKeys)do
        local count=0
        for key in pairs(items)do if Matches(key,stock) then count=count+1 end end
        matchCounts[stock]=count
    end
    local function Consume(key,need)
        local owned,fromBag,uncertain=0,0,false
        for _,stock in ipairs(stockKeys)do
            local count=Integer(remaining[stock],true) or 0
            if count>0 and Matches(key,stock) then
                local ambiguous=matchCounts[stock]>1
                if ambiguous then uncertain=true;Issue('inventory_match_ambiguous',key)
                else
                    local _,requestedGrade=key:match('^([^:]+):([^:]+):')
                    local _,stockGrade=stock:match('^([^:]+):([^:]+):')
                    if requestedGrade=='*' and stockGrade~='*' then uncertain=true end
                    local take=math.min(count,need-owned)
                    local bag=math.min(take,Integer(remainingBag[stock],true) or 0)
                    remaining[stock]=count-take;remainingBag[stock]=(Integer(remainingBag[stock],true) or 0)-bag
                    owned=owned+take;fromBag=fromBag+bag
                    if owned==need then break end
                end
            end
        end
        if uncertain then Issue('inventory_grade_unverified',key) end
        return owned,fromBag,uncertain
    end
    -- 先收齐所有上游需求，再抵扣库存和取整；不能在树的各分支里各自扣一遍。
    for index=#order,1,-1 do
        local key=order[index]
        local need=demands[key] or 0
        if need>0 then
            local item, recipe, a = items[key], recipes[key], Allocation(key)
            local owned,bagHeld,inventoryUncertain=Consume(key,need)
            local row={key=key,item=Copy(item),demand=need,owned=owned,fromBank=math.max(0,owned-bagHeld),shortage=need-owned,buy=0,craft=0,
                inventoryUncertain=inventoryUncertain,batches=0,surplus=0,parents=Keys(parents[key]),unallocated=0}
            result.byKey[key]=row; result.rows[#result.rows+1]=row
            if a.mode=='mixed' then
                row.buy, row.craft = Integer(a.buy,true), Integer(a.craft,true)
                if row.buy==nil or row.craft==nil then row.buy,row.craft=0,0; Issue('invalid_allocation',key) end
                row.unallocated=row.shortage-row.buy-row.craft
                if row.unallocated~=0 then Issue('allocation_mismatch',key) end
            elseif a.mode=='buy' then row.buy=row.shortage
            elseif a.mode=='craft' then row.craft=row.shortage
            else Issue('invalid_source',key) end
            if row.buy>0 then
                result.purchases[#result.purchases+1]=row
                -- 购买不依赖子配方；保留未知标记供用户查看或补充。
                if route~='buy' and not recipe and not ((facts.catalog or {})[key] or {}).base then
                    row.recipeUnknown=true
                end
            end
            if row.craft>0 then
                if not recipe and ((facts.catalog or {})[key] or {}).base and route=='raw' then
                    row.buy,row.craft=row.buy+row.craft,0; result.purchases[#result.purchases+1]=row
                elseif type(recipe)~='table' or D.Key(recipe.product)~=key or not Integer(recipe.product.count)
                    or type(recipe.materials)~='table' or #recipe.materials==0 or recipe.incomplete then
                    Issue('recipe_incomplete',key)
                elseif cyclic[key] then Issue('cycle',key)
                else
                    row.recipeId=recipe.id; row.batches=math.ceil(row.craft/recipe.product.count)
                    row.surplus=row.batches*recipe.product.count-row.craft
                    if row.batches*recipe.product.count>D.MaxQuantity then Issue('quantity_limit',key)
                    else
                        for _,m in ipairs(recipe.materials) do
                            local child, count=D.Key(m), Integer(m.count)
                            if child and count then
                                local total=(demands[child] or 0)+row.batches*count
                                if total>D.MaxQuantity then Issue('quantity_limit',child) else demands[child]=total end
                            end
                        end
                    end
                    local labor=Integer(recipe.labor,true)
                    if labor and result.labor+row.batches*labor<=D.MaxQuantity then result.labor=result.labor+row.batches*labor
                    else result.laborComplete=false; result.issues[#result.issues+1]={code='labor_unknown',key=key} end
                    local fee=Integer(recipe.feeCopper,true)
                    if fee and result.feeCopper+row.batches*fee<=9000000000000 then result.feeCopper=result.feeCopper+row.batches*fee
                    else result.costComplete=false; result.issues[#result.issues+1]={code='fee_unknown',key=key} end
                    result.steps[#result.steps+1]=row
                end
            end
            local quote=(facts.prices or {})[key]
            local price=type(quote)=='table' and tonumber(quote.price) or nil
            if not price or price~=price or price<0 or price>D.MaxQuantity then price=nil end
            row.price,row.priceMeta=price,Copy(quote)
            if row.buy+owned>0 then
                if price then
                    local source=tostring(quote.source or ''):gsub('^legacy:','')
                    if quote.freshness~='fresh' or quote.candidatePrice~=nil or source=='name_search_direct_unit' then
                        result.priceStale=true
                    end
                    local cash,ownedValue=row.buy*price,owned*price
                    if cash+result.cashCopper>9000000000000 or ownedValue+result.ownedValueCopper>9000000000000 then
                        Issue('money_limit',key);result.costComplete=false
                    else
                        result.cashCopper=result.cashCopper+cash
                        result.ownedValueCopper=result.ownedValueCopper+ownedValue
                    end
                else
                    if row.buy>0 then result.costComplete=false;result.missingPrices[#result.missingPrices+1]=key end
                    if owned>0 then result.valueComplete=false end
                end
            end
        end
    end
    -- 先做底层原料，再做上层产物。
    local reversed={}; for i=#result.steps,1,-1 do reversed[#reversed+1]=result.steps[i] end; result.steps=reversed
    result.cashCopper=result.cashCopper+result.feeCopper
    result.valueCopper=result.cashCopper+result.ownedValueCopper
    result.valueComplete=result.valueComplete and result.costComplete
    if facts.inventoryComplete~=true then Issue('inventory_unknown') end
    local laborValue=tonumber(plan.laborValueCopper)
    if laborValue and laborValue>=0 and result.laborComplete then
        result.combinedCopper=result.cashCopper+result.labor*laborValue
    end
    result.costComplete=result.costComplete and result.complete
    return result
end

function D.Compare(plan,facts)
    local r={manual=D.Evaluate(plan,facts),raw=D.Evaluate(plan,facts,'raw'),buy=D.Evaluate(plan,facts,'buy')}
    local candidate=Copy(plan); candidate.allocations=candidate.allocations or {}
    local best=r.manual
    local laborPriced=tonumber(plan.laborValueCopper)~=nil
    local function Score(value)
        if not value.costComplete or (laborPriced and not value.laborComplete) then return nil end
        return value.combinedCopper or value.cashCopper
    end
    local partial=Score(r.manual)==nil or Score(r.raw)==nil or Score(r.buy)==nil
    -- 有界逐项候选比较，包含批次和共享库存；不宣称全局最优。
    local tries=0
    for _,key in ipairs(Keys(facts.recipes)) do
        if tries>=32 then break end
        if best.byKey[key] then
            tries=tries+1
            local previous=candidate.allocations[key]
            local row=best.byKey[key]
            local mode=previous and previous.mode or ((tonumber(row.craft) or 0)>0 and 'craft' or 'buy')
            candidate.allocations[key]={mode=mode=='buy' and 'craft' or 'buy'}
            local value=D.Evaluate(candidate,facts)
            local before, after=Score(best), Score(value)
            if not after then partial=true end
            if after and (not before or after<before) then best=value else candidate.allocations[key]=previous end
        end
    end
    r.recommendation={evaluation=best,allocations=Copy(candidate.allocations),compared=tries,kind='bounded_candidates',
        available=Score(best)~=nil,partial=partial}
    return r
end

function D.ReplaceSnapshot(ledger,source,generation,rows,complete)
    if type(source)~='string' or source=='' or not Integer(generation,true) or complete~=true then return false end
    if ledger[source] and generation<=ledger[source].generation then return false end
    local counts={}
    for _,row in ipairs(rows or {}) do
        local key,count=D.Key(row),Integer(row.count,true)
        if not key or not count then return false end
        counts[key]=(counts[key] or 0)+count
        if counts[key]>D.MaxQuantity then return false end
    end
    ledger[source]={generation=generation,counts=counts,trusted=true}; return true
end
function D.InvalidateInventory(ledger)
    for _,source in pairs(ledger or {}) do source.trusted=false end
end
function D.Inventory(ledger)
    local counts={}
    for _,source in pairs(ledger or {}) do
        if source.trusted then
            for key,count in pairs(source.counts) do counts[key]=(counts[key] or 0)+count end
        end
    end
    return counts
end

function D.Budget(need,lots,coverageVerified)
    need=Integer(need)
    local r={covered=0,cashCopper=0,surplus=0,shortage=need or 0,complete=false,scope='observed_lots',method='unit_price_order'}
    if not need then return r end
    local seen, sorted={},{}
    for index,lot in ipairs(lots or {}) do
        if index>512 then coverageVerified=false; break end
        local count,total=Integer(lot.count),tonumber(lot.totalCopper)
        if type(lot.id)~='string' or lot.id=='' then coverageVerified=false
        elseif not seen[lot.id] and count and total and total>=0 and total<=D.MaxQuantity then
            seen[lot.id]=true; sorted[#sorted+1]={id=lot.id,count=count,totalCopper=total}
        end
    end
    table.sort(sorted,function(a,b)
        local x,y=a.totalCopper/a.count,b.totalCopper/b.count
        if x==y then return a.id<b.id end; return x<y
    end)
    for _,lot in ipairs(sorted) do
        if r.covered>=need then break end
        r.covered=r.covered+lot.count; r.cashCopper=r.cashCopper+lot.totalCopper
    end
    r.surplus=math.max(0,r.covered-need); r.shortage=math.max(0,need-r.covered)
    r.complete=r.shortage==0 and coverageVerified==true
    return r
end

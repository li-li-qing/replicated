-- Replicated Suite · 制作计划纯计算
-- 所有输入均为 detached 基础值；这里不读取游戏、不询价、不写存档。
-- 作者：Replicated；QQ群：1104129461
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
function D.ParseRecipeShare(value,allowLinkedItems)
    local summary={bytes=type(value)=='string' and #value or 0,linkCount=0,ids={},tags={}}
    local limit=allowLinkedItems==true and 8192 or 2048
    if type(value)~='string' or value=='' or #value>limit then
        summary.code='share_size_invalid';return nil,'请粘贴配方分享链接（最多 '..limit..' 字节）',summary
    end
    local kinds={}
    for tag in value:gmatch('|([%a]+)')do
        summary.hasMarkup=true;tag=tag:sub(1,16)
        if not kinds[tag] and #summary.tags<8 then summary.tags[#summary.tags+1]=tag;kinds[tag]=true end
    end
    local links={}
    for candidate,label in value:gmatch('|if(%d+)[;:]([^|%]]*)')do
        summary.linkCount=summary.linkCount+1
        if summary.linkCount>66 then summary.code='share_link_limit';return nil,'分享链接数量超过本轮上限',summary end
        local id=Integer(candidate)
        if not id then summary.code='share_id_invalid';return nil,'分享链接编号无效',summary end
        if #summary.ids<16 then summary.ids[#summary.ids+1]=id end
        label=tostring(label or ''):match('^%s*(.-)%s*$')
        if #label>192 or label:find('[%c]') then label='' end
        links[#links+1]={id=id,name=label~='' and label or nil}
    end
    if #links==0 or (#links~=1 and allowLinkedItems~=true) then
        summary.code=#links==0 and 'share_link_missing' or 'share_multiple_links'
        return nil,'需要一条有效配方链接，不能把物品编号直接作为配方编号',summary
    end
    summary.code='parsed'
    local linkedItems={};for index=2,#links do linkedItems[#linkedItems+1]=links[index] end
    return {craftType=links[1].id,name=links[1].name,source='craft_share_link',linkedItems=linkedItems},nil,summary
end
-- 完整分享可能带产物/材料链接；只有原生配方能核实这些附带链接时才接受，不能随意取多个配方中的第一个。
function D.ValidateRecipeShare(reference,recipe)
    if type(reference.linkedItems)~='table' or #reference.linkedItems==0 then return true end
    local function Label(value)
        if type(value)~='string' then return nil end
        value=value:match('^%s*(.-)%s*$'):gsub('^%[',''):gsub('%]$','')
        return value~='' and value or nil
    end
    local sharedName,nativeName=Label(reference.name),Label(recipe.product and recipe.product.name)
    if sharedName and nativeName and sharedName~=nativeName then
        return false,'分享包含多个链接，首个链接与配方产物名称不匹配'
    end
    local allowed={}
    local function Add(item)
        if type(item)=='table' and Integer(item.itemType) then
            local id=Integer(item.itemType);allowed[id]=allowed[id] or {}
            local name=Label(item.name);if name then allowed[id][name]=true end
        end
    end
    Add(recipe.product);for _,item in ipairs(recipe.materials or {})do Add(item) end
    for _,link in ipairs(reference.linkedItems)do
        local names=allowed[link.id]
        if not names or (next(names)~=nil and not names[Label(link.name) or '']) then
            return false,'分享包含无法核对的附带链接；请单独分享一张配方'
        end
    end
    return true
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
-- 查询/匹配身份与持久化键分开：不能因补齐固定品质使已保存的计划键失效。
function D.ResolveItemGrade(item)
    local grade=type(item)=='table' and tonumber(item.grade) or nil
    if type(item)=='table' and item.grade~=nil and (not Integer(grade,true) or grade>20) then return nil,'invalid_grade' end
    if grade~=nil and grade~=0 then return grade,'explicit' end
    local catalog=ReplicatedSuite.Data and ReplicatedSuite.Data.CraftRecipeCatalog
    local record=catalog and catalog.items and type(item)=='table' and catalog.items[tonumber(item.itemType)]
    local fixed=type(record)=='table' and Integer(record.fixedGrade,true) or nil
    if fixed and fixed<=20 then return fixed,'fixed_item_catalog' end
    return grade,grade==0 and 'unverified_zero' or 'unspecified'
end
-- 同物品产物品质未返回时允许查看配方，但不能当作已验证的制作方案。
function D.ProductMatches(required,product)
    if not D.Key(required) or not D.Key(product) or tonumber(required.itemType)~=tonumber(product.itemType) then return false,false end
    if required.variant~=nil and required.variant~='*' and required.variant~=product.variant then return false,false end
    local requiredGrade,requiredSource=D.ResolveItemGrade(required)
    local productGrade,productSource=D.ResolveItemGrade(product)
    if requiredSource=='invalid_grade' or productSource=='invalid_grade' then return false,false end
    if requiredGrade~=nil then
        if productGrade==nil then return true,false end
        if requiredGrade~=productGrade then return false,false end
    end
    return true,true
end
function D.ResolveRequirementGrade(item,product,observedGrade)
    local grade,source=D.ResolveItemGrade(item)
    if grade==nil and type(item)=='table' and item.grade==nil and select(2,D.ProductMatches(item,product)) then
        grade=D.ResolveItemGrade(product)
        if grade~=nil then source='selected_recipe_product' end
    end
    local observed=Integer(observedGrade,true)
    if grade==nil and type(item)=='table' and item.grade==nil and observed and observed<=20 then
        grade,source=observed,'native_recipe_product'
    end
    return grade,source
end
local function Keys(t)
    local r={}; for k in pairs(t or {}) do r[#r+1]=k end; table.sort(r); return r
end

function D.Evaluate(plan, facts, route, checkpoint)
    local function Tick() if checkpoint then checkpoint() end end
    local function Copy(v)
        if type(v)~='table' then return v end
        local out={}
        for key,value in pairs(v) do Tick();out[key]=Copy(value) end
        return out
    end
    plan, facts = plan or {}, facts or {}
    local result = { rows={}, byKey={}, purchases={}, steps={}, issues={}, missingPrices={},
        complete=true, costComplete=true, valueComplete=true, laborComplete=true, priceStale=false, cashCopper=0, valueCopper=0,
        ownedValueCopper=0, labor=0, feeCopper=0,feeComplete=true,purchaseCount=0,pricedPurchaseCount=0, route=route or 'manual' }
    local function Issue(code, key)
        result.issues[#result.issues+1]={code=code,key=key}; result.complete=false
    end
    local demands, items, parents, mark, order, cyclic, targetKeys = {}, {}, {}, {}, {}, {}, {}
    local recipes, allocations = facts.recipes or {}, plan.allocations or {}
    local nodes, edges = 0, 0
    local function Allocation(key)
        if route=='buy' then return {mode='buy'} end
        if route=='raw' then return {mode='craft'} end
        -- 展开只影响树的显示；成本始终服从用户分配。
        if targetKeys[key] then return allocations[key] or {mode='craft'} end
        return allocations[key] or {mode='buy'}
    end
    local function Visit(key, depth)
        Tick()
        if mark[key]==1 then cyclic[key]=true; Issue('cycle',key); return end
        if mark[key]==2 then return end
        nodes=nodes+1
        if nodes>D.MaxNodes or depth>D.MaxDepth then Issue('graph_limit',key); return end
        mark[key]=1
        local recipe, a = recipes[key], Allocation(key)
        if a.mode~='buy' and (a.mode~='mixed' or tonumber(a.craft)~=0) and type(recipe)=='table' then
            for _, material in ipairs(recipe.materials or {}) do
                Tick()
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
        Tick()
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
    local remaining,remainingBag={},{}
    for key,count in pairs(facts.inventory or {}) do Tick();remaining[key]=count end
    for key,count in pairs(facts.bagInventory or facts.inventory or {}) do Tick();remainingBag[key]=count end
    local requirementKeys,stockIdentities={},{}
    local function MatchKey(key,isRequirement)
        local identities=isRequirement and requirementKeys or stockIdentities
        if identities[key] then return identities[key] end
        local id,grade,variant=key:match('^([^:]+):([^:]+):(.+)$')
        if grade=='0' or grade=='*' then
            local resolved
            if isRequirement and items[key] then
                resolved=D.ResolveRequirementGrade(items[key],recipes[key] and recipes[key].product,(facts.itemGrades or {})[key])
            else
                -- 选中配方只能明确需求；不能给品质缺失的背包物品强套该品质。
                resolved=D.ResolveItemGrade({itemType=tonumber(id),grade=tonumber(grade)})
            end
            if resolved~=nil then identities[key]=id..':'..tostring(resolved)..':'..variant end
        end
        identities[key]=identities[key] or key;return identities[key]
    end
    local function Matches(requirement,stock)
        local rt,rg,rv=MatchKey(requirement,true):match('^([^:]+):([^:]+):(.+)$')
        local st,sg,sv=MatchKey(stock):match('^([^:]+):([^:]+):(.+)$')
        return rt~=nil and rt==st and (rg=='*' or rg==sg) and (rv=='*' or rv==sv)
    end
    local stockKeys=Keys(remaining)
    local matchCounts={}
    for _,stock in ipairs(stockKeys)do
        Tick()
        local count,seen=0,{}
        for key in pairs(items)do
            Tick()
            local identity=MatchKey(key,true)
            if not seen[identity] and Matches(key,stock) then count=count+1;seen[identity]=true end
        end
        matchCounts[stock]=count
    end
    local function Consume(key,need)
        local owned,fromBag,uncertain=0,0,false
        for _,stock in ipairs(stockKeys)do
        Tick()
            local count=Integer(remaining[stock],true) or 0
            if count>0 and Matches(key,stock) then
                local ambiguous=matchCounts[stock]>1
                if ambiguous then uncertain=true;Issue('inventory_match_ambiguous',key)
                else
                    local _,requestedGrade=MatchKey(key,true):match('^([^:]+):([^:]+):')
                    local _,stockGrade=MatchKey(stock):match('^([^:]+):([^:]+):')
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
        Tick()
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
                elseif type(recipe)~='table' or not select(2,D.ProductMatches(item,recipe.product)) or not Integer(recipe.product.count)
                    or type(recipe.materials)~='table' or #recipe.materials==0 or recipe.incomplete then
                    Issue('recipe_incomplete',key)
                elseif cyclic[key] then Issue('cycle',key)
                else
                    row.recipeId=recipe.id; row.batches=math.ceil(row.craft/recipe.product.count)
                    row.surplus=row.batches*recipe.product.count-row.craft
                    if row.batches*recipe.product.count>D.MaxQuantity then Issue('quantity_limit',key)
                    else
                        for _,m in ipairs(recipe.materials) do
                            Tick()
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
                    else result.costComplete=false;result.feeComplete=false; result.issues[#result.issues+1]={code='fee_unknown',key=key} end
                    result.steps[#result.steps+1]=row
                end
            end
            if row.buy>0 and ((plan.purchaseBlocks or {})[key]==true or ((facts.purchasePolicies or {})[key] or {}).state=='forbidden') then
                Issue('purchase_forbidden',key)
            end
            local quote=(facts.prices or {})[key]
            local price=type(quote)=='table' and tonumber(quote.price) or nil
            if not price or price~=price or price<0 or price>D.MaxQuantity then price=nil end
            row.price,row.priceMeta=price,Copy(quote)
            if row.buy>0 then
                result.purchaseCount=result.purchaseCount+1
                if price then result.pricedPurchaseCount=result.pricedPurchaseCount+1 end
            end
            if row.buy+owned>0 then
                if price then
                    local source=tostring(quote.source or ''):gsub('^legacy:','')
                    local quoteState=(facts.quoteStates or {})[key]
                    if quote.freshness~='fresh' or quote.candidatePrice~=nil or source=='name_search_direct_unit'
                        or (type(quoteState)=='table' and (quoteState.status~='ready' or quoteState.priceAccepted==false)) then
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
    result.materialCopper=result.cashCopper
    result.materialCostComplete=result.complete and #result.missingPrices==0
    result.cashCopper=result.cashCopper+result.feeCopper
    result.valueCopper=result.cashCopper+result.ownedValueCopper
    if result.cashCopper>9000000000000 then Issue('money_limit');result.costComplete=false end
    if result.valueCopper>9000000000000 then result.valueComplete=false end
    if facts.inventoryComplete~=true then Issue('inventory_unknown') end
    result.costComplete=result.costComplete and result.complete
    result.valueComplete=result.valueComplete and result.costComplete
    local laborValue=tonumber(plan.laborValueCopper)
    -- 未知库存或缺价时，部分现金合计不能被当作完整的含劳力成本。
    if result.costComplete and laborValue and laborValue==laborValue and laborValue>=0 and laborValue<=D.MaxQuantity and result.laborComplete then
        local combined=result.cashCopper+result.labor*laborValue
        if combined<=9000000000000 then result.combinedCopper=combined end
    end
    return result
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

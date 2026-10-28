-- 配方库与递归材料链回归；Native 配方为明确的合成数据。
-- 作者：Replicated
-- QQ群：1104129461
local passed,failed=0,0
local function Test(name,fn)
    local ok,why=xpcall(fn,debug.traceback)
    if ok then passed=passed+1;print('PASS craft-library '..name)
    else failed=failed+1;print('FAIL craft-library '..name..': '..tostring(why))end
end
local function Boot(disk)
    local h=dofile('tools/rs_gear_page_test_host.lua')({disk=disk})
    local S=h.S
    dofile('core/rs_demand.lua');dofile('features/shared/rs_shared_bounds.lua');dofile('features/shared/rs_feature_slice_factory.lua')
    dofile('features/tools/craft/rs_craft_feature.lua');dofile('features/tools/craft/rs_craft_plan_domain.lua');dofile('features/tools/craft/rs_craft_plan_solver.lua');dofile('features/tools/craft/rs_craft_plan_feature.lua')
    local F=S.Features.tools_craft
    h.nativeRecipeRead=F.ReadPlanRecipe;h.nativeRecipeTypes=F.ReadPlanRecipeTypes
    F.enabled=true;F.consumerCount=1
    F.ReadPlanRecipeTypes=nil
    F.ReadPlanRecipe=function(_,id)
        return {id=tostring(id),product={itemType=id,count=1,name='合成配方 '..id},materials={{itemType=1000+id,count=3,name='合成材料'}}}
    end
    h.F=F;h.C=F.Commands
    h.projection=function()return F:GetProjection().plan end
    h.drain=function()
        for _=1,160 do if not S.Scheduler:GetTaskState('tools_craft_plan_recipes') then break end;S.Scheduler:RunTask('tools_craft_plan_recipes')end
    end
    return h
end
Test('a native recipe share containing verified product and material links is received once through the real chat bus',function()
    local h=Boot();local F,C,S=h.F,h.C,h.S
    F.ReadPlanRecipe=function()return {id='6802',product={itemType=32934,count=1,name='竹笼鹅窝'},
        materials={{itemType=19940,count=3,grade=0,name='小鹅'},{itemType=3433,count=10,grade=0,name='竹竿'}}}end
    assert(F:ReconcileDemand(nil,{count=1},{count=1}));assert(C:RecipeReceive(1,nil,'test-owner'))
    S.Events:Dispatch('CHAT_MESSAGE',1,nil,'GearTest@World',
        '|if6802;竹笼鹅窝|r 产物 |if32934;竹笼鹅窝|r 材料 |if19940;小鹅|r |if3433;竹竿|r')
    local d=F:GetRecipeReadDiagnostics()
    assert(d.receive.accepted==1 and not d.pendingShare,'linked materials must not make a valid recipe share ambiguous')
    local p=h.projection();assert(p.libraryActiveId=='6802' and #p.targets==1 and p.targets[1].itemType==32934)
    assert(d.receive.lastPacket.slots[4].share.linkCount==4,'diagnostics must retain link structure without chat text or names')
    assert(d.receive.lastPacket.slots[3].text==nil and d.receive.lastPacket.slots[4].text==nil)
end)
Test('a second unrelated recipe link is rejected before plan mutation and ordinary chat cannot erase the failure',function()
    local h=Boot();local F,C,S=h.F,h.C,h.S
    F.ReadPlanRecipe=function()return {id='11',product={itemType=101,count=1,name='配方甲'},
        materials={{itemType=201,count=3,name='原料'}}}end
    assert(F:ReconcileDemand(nil,{count=1},{count=1}));assert(C:RecipeReceive(1,nil,'test-owner'))
    local writes=h.writes
    for _,message in ipairs({'|if11;配方甲|r |if22;配方乙|r','|if11;配方甲|r |if201;错误材料名|r',
        '|if11;另一种产物|r |if201;原料|r'})do
        S.Events:Dispatch('CHAT_MESSAGE',1,0,'GearTest@World',message)
        local d=F:GetRecipeReadDiagnostics()
        assert(h.writes==writes and d.pendingShare and d.receive.stage=='import_failed')
        assert(h.projection().importFeedback.message:find('链接',1,true),'a rejected own share must explain its cause')
    end
    S.Events:Dispatch('CHAT_MESSAGE',1,0,'someone','普通聊天')
    assert(F:GetRecipeReadDiagnostics().receive.stage=='import_failed','unrelated chat must not overwrite the last receipt failure')
end)
Test('linked item identity stays verifiable when native recipe fields omit display names',function()
    local h=Boot();local F,C,S=h.F,h.C,h.S
    F.ReadPlanRecipe=function()return {id='6802',product={itemType=32934,count=1},
        materials={{itemType=3433,count=10,grade=0}}}end
    assert(F:ReconcileDemand(nil,{count=1},{count=1}));assert(C:RecipeReceive(1,nil,'test-owner'))
    S.Events:Dispatch('CHAT_MESSAGE',1,0,'GearTest@World','|if6802;竹笼鹅窝|r |if32934;竹笼鹅窝|r |if3433;竹竿|r')
    assert(F:GetRecipeReadDiagnostics().receive.accepted==1,'native item IDs must suffice when native names are absent')
    assert(h.projection().targets[1].name=='竹笼鹅窝')
end)
Test('a bracket-terminated attached link is checked by its label without storing the closing markup',function()
    local h=Boot();local F,C,S=h.F,h.C,h.S
    F.ReadPlanRecipe=function()return {id='6802',product={itemType=32934,count=1,name='竹笼鹅窝'},
        materials={{itemType=3433,count=10,grade=0,name='竹竿'}}}end
    assert(F:ReconcileDemand(nil,{count=1},{count=1}));assert(C:RecipeReceive(1,nil,'test-owner'))
    S.Events:Dispatch('CHAT_MESSAGE',1,0,'GearTest@World','[|if6802;竹笼鹅窝] [|if3433;竹竿]')
    assert(F:GetRecipeReadDiagnostics().receive.accepted==1)
end)
Test('unrecognized own markup retains bounded parser and native argument evidence after unrelated chat',function()
    local h=Boot();local F,C,S=h.F,h.C,h.S
    assert(F:ReconcileDemand(nil,{count=1},{count=1}));assert(C:RecipeReceive(1,nil,'test-owner'))
    local writes=h.writes
    S.Events:Dispatch('CHAT_MESSAGE',1,nil,'GearTest@World','私聊正文 |cf6802;竹笼鹅窝|r',{},nil)
    local d=F:GetRecipeReadDiagnostics()
    assert(h.writes==writes and d.pendingShare and d.receive.lastShare.code=='share_link_missing')
    assert(h.projection().importFeedback.ok==false and h.projection().importFeedback.message:find('仍在等待',1,true))
    S.Events:Dispatch('CHAT_MESSAGE',1,0,'another player','普通聊天')
    d=F:GetRecipeReadDiagnostics()
    assert(d.receive.stage=='link_not_recognized' and d.receive.ignored==1)
    local packet=d.receive.lastCandidatePacket
    assert(packet.argCount==6 and packet.slots[2].kind=='nil' and packet.slots[6].kind=='nil')
    assert(packet.slots[4].share.tags[1]=='cf' and packet.slots[4].share.code=='share_link_missing')
    assert(packet.slots[3].text==nil and packet.slots[4].text==nil and packet.slots[3].share==nil)
    d.receive.lastShare.code='mutated'
    assert(F:GetRecipeReadDiagnostics().receive.lastShare.code=='share_link_missing','diagnostic snapshots must not mutate live receipt state')
end)
Test('native item metadata keeps scalar and nil returns and reads a verified table from a later return slot',function()
    for _,mode in ipairs({'later_table','scalar_only','conflicting_tables','scalar_without_detail'})do
        local h=Boot();local S,F=h.S,h.F
        if mode~='scalar_without_detail' then dofile('core/rs_diagnostic_detail.lua') end
        S.ApiImports={Acquire=function()return true end}
        local original=S.Api.CallCapability
        local native={GetItemInfoByType=function(_,id)
            assert(id==32934)
            if mode=='later_table' then return 73,nil,{itemType=32934,itemGrade=0},false end
            if mode=='scalar_only' then return 0 end
            if mode=='scalar_without_detail' then return 0,false end
            return {itemType=32934,itemGrade=2},{itemType=32934,itemGrade=3}
        end}
        S.Api.CallCapability=function(self,capability,object,method,id,...)
            if capability=='X2Craft:GetCraftProductInfo' then return true,{{itemType=32934,amount=1,useGrade=false,productGrade=0}} end
            if capability=='X2Craft:GetCraftMaterialInfo' then return true,{{amount=3,mainGrade=false,item_info={itemType=3433,itemGrade=0}}} end
            if capability=='X2Item:GetItemInfoByType' then return self:Call(native,method,id) end
            return original(self,capability,object,method,id,...)
        end
        local r,_,d=h.nativeRecipeRead(F,11)
        if mode=='later_table' then
            assert(r.product.grade==0 and d.itemInfo.selectedReturn==3)
            assert(d.itemInfo.returnTypes[1]=='number' and d.itemInfo.returnTypes[2]=='nil' and d.itemInfo.returnTypes[3]=='table')
            assert(d.itemInfo.returns[1]==73 and d.itemInfo.returns[4]==false)
        elseif mode=='scalar_only' then
            assert(r.product.grade==nil and d.itemInfo.returns[1]==0,'an unverified numeric return must not be treated as grade zero')
        elseif mode=='scalar_without_detail' then
            assert(r.product.grade==nil and d.itemInfo.returns[1]==0 and d.itemInfo.returns[2]==false,'scalar evidence must survive without the detail service')
        else assert(r.product.grade==nil and d.itemInfo.reason=='metadata_grade_ambiguous') end
    end
end)
Test('a restored bamboo nest with missing product grade resolves native item metadata before its first auction search',function()
    local h=Boot();local S,F,C=h.S,h.F,h.C
    F.ReadPlanRecipe=function()return {id='11',product={itemType=32934,count=1,name='竹笼鹅窝'},materials={
        {itemType=19940,count=3,grade=0,name='小鹅'},{itemType=3433,count=10,grade=0,name='竹竿'},
        {itemType=27142,count=5,grade=0,name='蠕动的蚯蚓'}}}end
    assert(C:RecipeImportLink('|if11;竹笼鹅窝|r',1))
    F.ReadPlanRecipe=h.nativeRecipeRead
    local metadataReads=0;local original=S.Api.CallCapability
    S.ApiImports={Acquire=function(_,owner,dependencies)
        assert(owner=='feature:tools_craft:item_metadata' and dependencies[1]=='X2Item:GetItemInfoByType');return true
    end}
    S.Api.CallCapability=function(self,capability,object,method,id,...)
        if capability=='X2Craft:GetCraftProductInfo' then return true,{{itemType=32934,amount=1,item_name='竹笼鹅窝',useGrade=false,productGrade=0}} end
        if capability=='X2Craft:GetCraftMaterialInfo' then return true,{
            {amount=3,mainGrade=false,item_info={itemType=19940,itemGrade=0}}, {amount=10,mainGrade=false,item_info={itemType=3433,itemGrade=0}},
            {amount=5,mainGrade=false,item_info={itemType=27142,itemGrade=0}}} end
        if capability=='X2Item:GetItemInfoByType' then
            assert(id==32934);metadataReads=metadataReads+1;return true,{itemType=32934,itemGrade=0,name='竹笼鹅窝'}
        end
        return original(self,capability,object,method,id,...)
    end
    local requests={}
    S.Services.PriceQuoteQueueV3={RequestQuote=function(_,owner,id,grade,done)
        assert(grade~=nil,'metadata must resolve quality before submitting the strict request')
        requests[#requests+1]={id=id,grade=grade,done=done};return true
    end}
    S.Services.MaterialPriceServiceV3={GetPrice=function(_,id,grade)assert(grade==0);return 200,{itemGrade=0,freshness='fresh'}end}
    assert(C:PlanCalibrate());assert(requests[1].id==32934 and requests[1].grade==0 and metadataReads==1)
    for index=1,4 do requests[index].done({status='ready',itemType=requests[index].id,itemGrade=0,price=200})end
    local p=h.projection()
    assert(p.targets[1].key=='32934:*:*' and p.prices['32934:*:*'].price==200 and p.quote.failed==0)
    assert(h.nativeRecipeRead(F,11).product.grade==0 and metadataReads==1,'successful immutable item metadata must be cached')
    S.Api.CallCapability=function()error('export must not perform native reads')end
    assert(F:GetPriceReadDiagnostics().results['32934:*:*'].gradeResolution.itemInfo.grade==0)
    assert(F:GetRecipeReadDiagnostics().costProbes['11'].itemInfo.grade==0)
    local D=S.CraftPlanDomain
    local e=D.Evaluate({targets={{itemType=32934,count=3}},allocations={['32934:*:*']={mode='buy'}}},
        {inventoryComplete=true,inventory={['32934:0:*']=1,['32934:3:*']=8},prices={['32934:*:*']={price=200}},
            itemGrades={['32934:*:*']=0}})
    assert(e.rows[1].owned==1 and e.cashCopper==400 and not e.rows[1].inventoryUncertain)
end)
Test('unreadable or mismatched native item metadata remains unknown and can be retried explicitly',function()
    for _,kind in ipairs({'nil','missing_grade','wrong_item','fractional_item','fractional_grade','text_grade','import_failed'})do
        local h=Boot();local S,F=h.S,h.F;local reads=0;local fixed=false
        S.ApiImports={Acquire=function()return kind~='import_failed','metadata_import_failed' end}
        local original=S.Api.CallCapability
        S.Api.CallCapability=function(self,capability,object,method,id,...)
            if capability=='X2Craft:GetCraftProductInfo' then return true,{{itemType=32934,amount=1,useGrade=false,productGrade=0}} end
            if capability=='X2Craft:GetCraftMaterialInfo' then return true,{{amount=3,mainGrade=false,item_info={itemType=3433,itemGrade=0}}} end
            if capability=='X2Item:GetItemInfoByType' then
                reads=reads+1;if fixed then return true,{itemType=32934,itemGrade=0} end
                if kind=='nil' then return true,nil end
                local info={itemType=kind=='wrong_item' and 999 or 32934,itemGrade=0}
                if kind=='fractional_grade' then info.itemGrade=1.5 elseif kind=='text_grade' then info.itemGrade='Lv.1 普通'
                elseif kind=='missing_grade' then info.itemGrade=nil elseif kind=='fractional_item' then info.itemType=32934.5 end
                return true,info
            end
            return original(self,capability,object,method,id,...)
        end
        local record,_,evidence=h.nativeRecipeRead(F,11)
        assert(record.product.grade==nil and evidence.itemInfo.status~='ready',kind)
        if kind~='import_failed' then
            fixed=true;assert(h.nativeRecipeRead(F,11).product.grade==0 and reads==2,'failed metadata must not be cached as a usable grade')
        else assert(reads==0,'failed import must not fall through to a raw native call')end
    end
end)
Test('product grade inheritance and missing product identity never invoke the fixed-item metadata fallback',function()
    for _,kind in ipairs({'declared','inherited','missing_item','unknown_inheritance','wrapped_materials'})do
        local h=Boot();local S,F=h.S,h.F
        S.ApiImports={Acquire=function()error('this recipe must not import default item metadata')end}
        local original=S.Api.CallCapability
        S.Api.CallCapability=function(self,capability,object,method,id,...)
            if capability=='X2Craft:GetCraftProductInfo' then
                local product={itemType=32934,amount=1,item_name='测试产物',useGrade=false,productGrade=0}
                if kind=='declared' then product.useGrade=true;product.productGrade=3 end
                if kind=='missing_item' then product.itemType=nil end
                return true,{product}
            end
            if capability=='X2Craft:GetCraftMaterialInfo' then
                local material={amount=3,mainGrade=false,item_info={itemType=3433,itemGrade=2}}
                if kind=='inherited' then material.mainGrade=true elseif kind=='unknown_inheritance' then material.mainGrade=nil end
                if kind=='wrapped_materials' then return true,{materials={material}} end
                return true,{material}
            end
            return original(self,capability,object,method,id,...)
        end
        local record=h.nativeRecipeRead(F,11)
        if kind=='declared' then assert(record.product.grade==3)
        elseif kind=='inherited' then assert(record.product.grade==2)
        elseif kind=='missing_item' then assert(record==nil)
        else assert(record.product.grade==nil) end
    end
end)
Test('canceling during product-grade resolution cannot resume the batch or publish the old grade into the new session',function()
    local h=Boot();assert(h.C:RecipeImportLink('|if1;成品|r',1))
    h.F.ReadPlanRecipe=function()
        assert(h.C:PlanCancelPrices())
        return {id='1',product={itemType=1,count=1,grade=0},materials={{itemType=1001,count=3,grade=0}}}
    end
    h.S.Services.PriceQuoteQueueV3={RequestQuote=function()error('canceled grade resolution must not submit an auction request')end}
    h.S.Services.MaterialPriceServiceV3={GetPrice=function()error('canceled grade evidence must not become a usable price identity')end}
    assert(h.C:PlanCalibrate())
    local p=h.projection();assert(p.quote.status=='stopped' and p.prices['1:*:*']==nil)
end)
Test('fixed recipe lookup shares the same verified material quality as auction lookup',function()
    local h=Boot();local S,F=h.S,h.F
    dofile('data/rs_craft_recipe_catalog.lua')
    S.Data.CraftRecipeCatalog.records['11']={product={itemType=46156,count=1,grade=2},materials={{itemType=8319,count=2,grade=1}}}
    S.Api.CallCapability=function()error('a verified local recipe must not fall through to native')end
    local expected={itemType=46156,grade=0}
    assert(h.nativeRecipeTypes(F,46156,expected)[1]==11)
    assert(h.nativeRecipeRead(F,11,{expectedProduct=expected}).source=='local_file')
end)
Test('context quote commands use parsed grade and fixed material quality consistently',function()
    local h=Boot();dofile('data/rs_craft_recipe_catalog.lua')
    local calls={}
    h.S.Services.PriceQuoteQueueV3={maxQueue=64,RequestQuote=function(_,owner,id,grade)
        calls[#calls+1]={id=id,grade=grade};return true
    end}
    h.F.CraftProjection={recipes={{materials={items={
        {itemType=46156,grade=0,costStatus='explicit_quote_required'},
        {itemType=90001,grade=3,costStatus='explicit_quote_required'},
        {itemType=90002,costStatus='explicit_quote_required'},
        {itemType=90002,grade=0,costStatus='explicit_quote_required'},
    }}}}}
    local ok,_,requested,skipped=h.C:QuotePendingMaterials();assert(ok and requested==3 and skipped==1)
    assert(calls[1].grade==2 and calls[2].grade==3 and calls[3].grade==0,'parsed grade must reach the shared queue')
    assert(h.C:QuoteMaterial(46156,0));assert(calls[4].grade==2)
end)
Test('native declared product quality replaces a placeholder zero but conflicting explicit qualities fail closed',function()
    local h=Boot();local infoGrade=0
    local original=h.S.Api.CallCapability
    h.S.Api.CallCapability=function(self,capability,...)
        if capability=='X2Craft:GetCraftProductInfo' then return true,{{amount=1,useGrade=true,productGrade=3,item_info={itemType=90001,itemGrade=infoGrade}}} end
        if capability=='X2Craft:GetCraftMaterialInfo' then return true,{{amount=2,item_info={itemType=90002,itemGrade=1}}} end
        return original(self,capability,...)
    end
    assert(h.nativeRecipeRead(h.F,11).product.grade==3)
    infoGrade=2
    local recipe,why=h.nativeRecipeRead(h.F,11)
    assert(recipe==nil and why:find('品质',1,true),'two conflicting explicit qualities cannot silently become a valid recipe')
end)
Test('unknown quality never reads the basic quality cache while a chosen verified product can supply it',function()
    local h=Boot();local reads={}
    assert(h.C:RecipeImportLink('|if1;成品|r',1))
    h.S.Services.MaterialPriceServiceV3={GetPrice=function(_,id,grade)
        assert(grade~=nil,'unknown quality must not address an implicit basic-quality price');reads[id]=grade;return 50,{itemGrade=grade}
    end}
    assert(next(h.projection().prices)==nil)
    -- 用户重新读取的同一根配方补齐产物品质；保存目标的原始键保持不变。
    h.F.ReadPlanRecipeTypes=function()return {} end
    h.F.ReadPlanRecipe=function()return {id='1',product={itemType=1,count=1,grade=3,name='成品'},materials={{itemType=1001,count=3,grade=1}}}end
    assert(h.C:PlanReadRecipes());h.drain()
    local p=h.projection()
    assert(p.targets[1].key=='1:*:*' and p.prices['1:*:*'].price==50 and reads[1]==3)
end)
Test('a selected product quality constrains inventory as well as quotes without counting another quality as owned',function()
    local h=Boot();local D=h.S.CraftPlanDomain
    local result=D.Evaluate({targets={{itemType=1,count=4}},allocations={['1:*:*']={mode='buy'}}},
        {inventoryComplete=true,inventory={['1:1:*']=9,['1:3:*']=2,['1:*:*']=8},prices={['1:*:*']={price=50}},
            recipes={['1:*:*']={product={itemType=1,grade=3,count=1},materials={{itemType=2,count=1}}}}})
    local row=result.rows[1]
    assert(row.owned==2 and row.buy==2 and result.cashCopper==100 and not row.inventoryUncertain)
end)
Test('a rejected unknown-quality target remains unpriced and the batch proceeds to a known-quality material',function()
    local h=Boot();local searches=0
    h.F.ReadPlanRecipe=function()return {id='1',product={itemType=1,count=1},materials={{itemType=1001,count=3,grade=0}}}end
    assert(h.C:RecipeImportLink('|if1;成品|r',1))
    h.S.Services.PriceQuoteQueueV3={RequestQuote=function(_,owner,id,grade,done)
        if grade==nil then return false,'strict_search_grade_invalid' end
        searches=searches+1;done({status='ready',itemType=id,itemGrade=grade,price=50});return true
    end}
    assert(h.C:PlanCalibrate())
    local p=h.projection()
    assert(searches==1 and p.quote.status=='completed' and p.quote.failed==1 and p.quote.completed==2)
    assert(p.quoteItems['1:*:*'].code=='strict_search_grade_invalid' and p.prices['1:*:*']==nil)
    assert(p.quoteItems['1001:0:*'].status=='ready','a valid zero-quality material must still be queried')
end)
Test('known fixed material grade is shared by auction requests, cached prices and inventory matching',function()
    local h=Boot();local F,C,S=h.F,h.C,h.S
    dofile('data/rs_craft_recipe_catalog.lua')
    F.ReadPlanRecipe=function()return {id='1',product={itemType=1,count=1,name='成品'},materials={{itemType=46156,count=3,grade=0,name='新月石晶'}}}end
    S.Services.MaterialPriceServiceV3={GetPrice=function(_,id,grade)
        if id==46156 then assert(grade==2,'craft placeholder grade must not be used as auction quality');return 50,{freshness='fresh',itemGrade=2} end
    end}
    assert(C:RecipeImportLink('|if1;成品|r',2))
    local calls={}
    S.Services.PriceQuoteQueueV3={RequestQuote=function(_,owner,id,grade,done)
        calls[#calls+1]={owner=owner,id=id,grade=grade,done=done};return true
    end}
    assert(C:PlanCalibrate());calls[1].done({status='ready'})
    assert(calls[2].id==46156 and calls[2].grade==2)
    calls[2].done({status='ready',itemGrade=2,price=50,searchGeneration=2})
    assert(h.projection().prices['46156:0:*'].price==50)
    local D=S.CraftPlanDomain
    local result=D.Evaluate({targets={{itemType=46156,grade=0,count=6}},allocations={['46156:0:*']={mode='buy'}}},
        {inventoryComplete=true,inventory={['46156:2:*']=2},prices={['46156:0:*']={price=50}}})
    assert(result.rows[1].owned==2 and result.rows[1].buy==4 and result.cashCopper==200)
    assert(D.ResolveItemGrade({itemType=46156,grade=3})==3,'explicit nonzero quality must remain strict')
    assert(D.ResolveItemGrade({itemType=99999,grade=0})==0,'unknown items must not borrow a default quality')
    assert(D.ResolveItemGrade({itemType=8319,grade=0})==0,'RU ordinary material grade zero must remain valid')
    assert(D.ResolveItemGrade({itemType=8319})==0,'a known ordinary material must not fall back to basic icon index one')
    assert(D.ResolveItemGrade({itemType=46156,grade=21})==nil,'invalid explicit quality must not read quality-one prices')
    assert(D.Key({itemType=46156,grade=0})=='46156:0:*','normalization must not invalidate existing plan keys')
    local aliases=D.Evaluate({targets={{itemType=46156,grade=0,count=3},{itemType=46156,grade=2,count=4}},
        allocations={['46156:0:*']={mode='buy'},['46156:2:*']={mode='buy'}}},
        {inventoryComplete=true,inventory={['46156:2:*']=5},prices={['46156:0:*']={price=50},['46156:2:*']={price=50}}})
    assert(aliases.cashCopper==100 and aliases.rows[1].owned+aliases.rows[2].owned==5,
        'fixed-quality aliases must share the same stock once without claiming an ambiguous quality')
end)
Test('price diagnostics retain failure identity after the popup releases demand without making native calls',function()
    local h=Boot()
    h.F.ReadPlanRecipe=function()return {id='1',product={itemType=1,count=1,name='成品'},materials={{itemType=1001,count=3,name='原料'}}}end
    assert(h.C:RecipeImportLink('|if1;成品|r',1))
    local callback
    h.S.Services.PriceQuoteQueueV3={RequestQuote=function(_,owner,id,grade,done)callback=done;return true end,
        CancelRequester=function()return true end}
    assert(h.C:PlanCalibrate())
    callback({status='unavailable',error='有挂单但品质不同',errorCode='strict_grade_mismatch',itemGrade=0,
        requestedAt=100,dispatchedAt=200,completedAt=300,searchGeneration=4})
    assert(h.F:ReconcileDemand(nil,{count=1},{count=0}))
    h.S.Api.CallCapability=function()error('diagnostics must not call Native')end
    local d=h.F:GetPriceReadDiagnostics()
    assert(d.batch.status=='stopped' and d.results['1:*:*'].code=='strict_grade_mismatch')
    assert(d.results['1:*:*'].searchGeneration==4 and d.results['1:*:*'].name=='成品')
end)
Test('closing a live request retains its dispatch identity before the queue releases it',function()
    local h=Boot();assert(h.C:RecipeImportLink('|if1;成品|r',1))
    local pending
    h.S.Services.PriceQuoteQueueV3={RequestQuote=function(_,owner,id,grade)
        pending={requester=owner,itemType=id,searchGeneration=17,dispatchedAt=200,deadlineAt=5200};return true
    end,Describe=function()return {pendingDetail=pending}end,CancelRequester=function()pending=nil;return true end}
    assert(h.C:PlanCalibrate());assert(h.C:PlanCancelPrices())
    local d=h.F:GetPriceReadDiagnostics()
    assert(d.results['1:*:*'].searchGeneration==17 and d.results['1:*:*'].dispatchedAt==200)
    assert(d.results['1:*:*'].status=='stopped' and d.batch.status=='stopped')
end)
Test('unmatched buyout samples remain a failed lookup rather than an empty market',function()
    local h=Boot()
    h.F.ReadPlanRecipe=function()return {id='1',product={itemType=1,count=1,grade=1},materials={{itemType=1001,count=3,grade=1}}}end
    assert(h.C:RecipeImportLink('|if1;成品|r',1))
    local calls={}
    h.S.Services.MaterialPriceServiceV3={GetPrice=function()return 50,{freshness='fresh'}end}
    h.S.Services.PriceQuoteQueueV3={RequestQuote=function(_,owner,id,grade,done)
        calls[#calls+1]=done;return true
    end}
    assert(h.C:PlanCalibrate());calls[1]({status='unavailable',error='strict_buyout_not_found'})
    local p=h.projection()
    assert(p.quoteItems['1:1:*'].status=='failed' and p.prices['1:1:*'].price==50)
    assert(#calls==2,'a mismatched sample must still advance to the next material once')
end)
Test('labor-only calibration persists and survives recipe refresh without setting an unknown fee to zero',function()
    local h=Boot();assert(h.C:RecipeImportLink('|if11;木材|r',2))
    assert(h.C:PlanSetRecipeCosts('11:*:*',5,nil))
    assert(h.projection().recipes['11'].labor==5 and h.projection().recipes['11'].feeCopper==nil)
    assert(h.C:RecipeImportLink('|if11;木材|r',2))
    local reload=Boot(h.disk)
    assert(reload.projection().recipes['11'].labor==5 and reload.projection().recipes['11'].feeCopper==nil)
    assert(not reload.C:PlanSetRecipeCosts('11:*:*',nil,nil))
end)
Test('fixed recipe file supplies materials and costs without querying native APIs or storing auction prices',function()
    local h=Boot();local S,F=h.S,h.F
    S.Data=S.Data or {};S.Data.CraftRecipeCatalog={schemaVersion=1,records={
        ['11']={product={itemType=11,count=2,name='木材'},materials={{itemType=12,count=3,name='原木'}},labor=5,feeCopper=0,price=99999}}}
    local nativeCalls=0
    local apiCall=S.Api.CallCapability
    S.Api.CallCapability=function(self,capability,...)
        if capability:find('X2Craft:',1,true)==1 then nativeCalls=nativeCalls+1;return false,nil,'not expected' end
        return apiCall(self,capability,...)
    end
    local recipe=assert(h.nativeRecipeRead(F,11))
    local ids=assert(h.nativeRecipeTypes(F,11))
    assert(nativeCalls==0 and ids[1]==11)
    assert(recipe.product.count==2 and recipe.materials[1].count==3 and recipe.labor==5 and recipe.feeCopper==0)
    assert(recipe.source=='local_file' and recipe.price==nil,'fixed recipes must not freeze auction prices')
    F.ReadPlanRecipe=h.nativeRecipeRead
    assert(h.C:RecipeImportLink('|if11;木材|r',4))
    assert(h.projection().recipes['11'].labor==5,'import must retain fixed-file labor')
    assert(h.C:PlanSetRecipeCosts('11:*:*',8,nil))
    S.Data.CraftRecipeCatalog.records['11'].feeCopper=12
    assert(h.C:RecipeImportLink('|if11;木材|r',4))
    local changed=h.projection().recipes['11']
    assert(changed.labor==8 and changed.feeCopper==12,'manual labor must not prevent a fixed-file fee update')
end)
Test('native base cost fields are observable but unverified labor is not silently accepted',function()
    local h=Boot();local S,F=h.S,h.F
    local original=S.Api.CallCapability
    S.Api.CallCapability=function(self,capability,object,method,...)
        if capability=='X2Craft:GetCraftProductInfo' then return true,{{itemType=11,amount=1,item_name='木材',useGrade=true,productGrade=0}} end
        if capability=='X2Craft:GetCraftMaterialInfo' then return true,{{amount=3,item_info={itemType=12,itemGrade=0,name='原木'}}} end
        if capability=='X2Craft:GetCraftBaseInfo' then return true,{labor=5,fee=10} end
        return original(self,capability,object,method,...)
    end
    local recipe,why,evidence=h.nativeRecipeRead(F,11)
    assert(recipe,why);assert(recipe.labor==nil and recipe.feeCopper==nil)
    assert(evidence.baseStatus=='table' and evidence.baseNumbers:find('labor=5',1,true))
    F.ReadPlanRecipe=h.nativeRecipeRead
    assert(h.C:RecipeImportLink('|if11;木材|r',1))
    assert(F:GetRecipeReadDiagnostics().costProbes['11'].baseNumbers:find('labor=5',1,true))
end)
Test('native needed_lp is adopted as labor while the unverified generic fields stay out',function()
    local h=Boot();local S,F=h.S,h.F
    local original=S.Api.CallCapability
    S.Api.CallCapability=function(self,capability,object,method,...)
        if capability=='X2Craft:GetCraftProductInfo' then return true,{{itemType=11,amount=1,item_name='木材',useGrade=true,productGrade=0}} end
        if capability=='X2Craft:GetCraftMaterialInfo' then return true,{{amount=3,item_info={itemType=12,itemGrade=0,name='原木'}}} end
        if capability=='X2Craft:GetCraftBaseInfo' then return true,{needed_lp=400,consume_lp=500,cost=14,labor=5,fee=10} end
        return original(self,capability,object,method,...)
    end
    local recipe,why,evidence=h.nativeRecipeRead(F,11)
    assert(recipe,why)
    assert(recipe.labor==400 and recipe.laborSource=='native_base','needed_lp is the measured field and must be adopted')
    assert(recipe.feeCopper==nil,'cost units are still unverified and must not become a fee')
    assert(evidence.baseNumbers:find('needed_lp=400',1,true),'base evidence must keep exposing the raw numbers')
end)
Test('a fixed recipe of another grade cannot replace the required native recipe',function()
    local h=Boot();local S,F=h.S,h.F
    S.Data=S.Data or {};S.Data.CraftRecipeCatalog={schemaVersion=1,records={
        ['11']={product={itemType=11,count=1,grade=3},materials={{itemType=12,count=3,grade=0}},labor=5}}}
    local original=S.Api.CallCapability
    S.Api.CallCapability=function(self,capability,object,method,...)
        if capability=='X2Craft:GetCraftTypeByItemType' then return true,{12} end
        if capability=='X2Craft:GetCraftProductInfo' then return true,{{itemType=11,amount=1,useGrade=true,productGrade=0}} end
        if capability=='X2Craft:GetCraftMaterialInfo' then return true,{{amount=2,item_info={itemType=12,itemGrade=0}}} end
        return original(self,capability,object,method,...)
    end
    local expected={itemType=11,grade=0}
    assert(h.nativeRecipeTypes(F,11,expected)[1]==12)
    local recipe=assert(h.nativeRecipeRead(F,11,{expectedProduct=expected}))
    assert(recipe.source=='X2Craft' and recipe.product.grade==0 and recipe.materials[1].count==2)
end)
Test('estimate charges a purchased intermediate once and exposes missing purchase prices',function()
    local h=Boot();local D=h.S.CraftPlanDomain
    local plan={targets={{itemType=1,count=2}},allocations={}}
    local facts={inventoryComplete=false,inventory={},catalog={},recipes={
        ['1:*:*']={id='1',product={itemType=1,count=1},materials={{itemType=2,count=3},{itemType=4,count=1}},labor=5},
        ['2:*:*']={id='2',product={itemType=2,count=1},materials={{itemType=3,count=3}},labor=2}},
        prices={['1:*:*']={price=999},['2:*:*']={price=5},['3:*:*']={price=1}}}
    local r=D.Evaluate(plan,facts)
    assert(r.materialCopper==30 and r.purchaseCount==2 and r.pricedPurchaseCount==1)
    assert(not r.materialCostComplete and not r.feeComplete and r.labor==10)
    assert(#r.missingPrices==1 and r.missingPrices[1]=='4:*:*')
end)
Test('explicit reset rebuilds only the owned corrupt plan and reception works after reload',function()
    local seed=Boot();assert(seed.C:RecipeImportLink('|if11;测试配方|r',1))
    local key=seed.S.Persistence:GetStore('v3.craft_plans').resolvedKey
    local disk=seed.Copy(seed.disk);local payload=disk[key].payload
    assert(type(payload)=='table');local first=next(payload);assert(first);payload[first]=nil
    local h=Boot(disk);local plan=h.projection()
    assert(plan.status=='unavailable' and plan.canResetCorrupt,'damaged owned data must offer explicit recovery: '..tostring(plan.error))
    local store=h.S.Persistence:GetStore('v3.craft_plans');assert(store.writeFenced)
    h.failSave=true;assert(not h.C:PlanResetCorrupt());h.failSave=false
    assert(store.writeFenced and store.needsBarrierVerify,'failed replacement must keep the fence and require a durability barrier')
    local ok,why=h.C:PlanResetCorrupt();assert(ok,tostring(why))
    assert(not store.writeFenced and #h.projection().targets==0)
    assert(h.F:ReconcileDemand(nil,{count=1},{count=1}))
    assert(h.C:RecipeReceive(1,nil,'test-owner'))
    h.S.Events:Dispatch('CHAT_MESSAGE',1,0,'GearTest@World','|if22;新配方|r')
    assert(h.projection().libraryActiveId=='22')
    local reload=Boot(h.disk);assert(reload.projection().libraryActiveId=='22')
end)
Test('reset does not publish success when native readback differs',function()
    local seed=Boot();assert(seed.C:RecipeImportLink('|if11;测试配方|r',1))
    local key=seed.S.Persistence:GetStore('v3.craft_plans').resolvedKey
    local disk=seed.Copy(seed.disk);local payload=disk[key].payload;payload[next(payload)]=nil
    local h=Boot(disk);assert(h.projection().canResetCorrupt)
    local originalSave,originalLoad=ADDON.SaveData,ADDON.LoadData
    local intercept=false
    ADDON.SaveData=function(self,k,value)local ok=originalSave(self,k,value);if k==key then intercept=true end;return ok end
    ADDON.LoadData=function(self,k)if intercept and k==key then return {} end;return originalLoad(self,k)end
    local ok,why=h.C:PlanResetCorrupt()
    assert(not ok and tostring(why):find('readback_verify_failed',1,true))
    assert(h.S.Persistence:GetStore('v3.craft_plans').writeFenced and h.projection().status=='unavailable')
end)
Test('reset refuses unknown ownership and healthy plans without writing',function()
    local seed=Boot();assert(seed.C:RecipeImportLink('|if11;测试配方|r',1))
    local key=seed.S.Persistence:GetStore('v3.craft_plans').resolvedKey
    local disk=seed.Copy(seed.disk);disk[key].__rsmeta.owner='other_owner'
    local h=Boot(disk);local plan=h.projection();assert(plan.status=='unavailable' and not plan.canResetCorrupt)
    local writes=h.writes;assert(not h.C:PlanResetCorrupt() and h.writes==writes)
    local clean=Boot();assert(clean.C:RecipeImportLink('|if12;正常|r',1))
    writes=clean.writes;assert(not clean.C:PlanResetCorrupt() and clean.writes==writes)
end)
Test('combined labor cost is unavailable until both inventory and prices are complete',function()
    local h=Boot();local D=h.S.CraftPlanDomain
    local plan={targets={{itemType=11,name='木材',count=1}},allocations={},laborValueCopper=10}
    local facts={recipes={},inventory={},bagInventory={},prices={},inventoryComplete=false}
    local unknown=D.Evaluate(plan,facts,'buy')
    assert(not unknown.costComplete and not unknown.valueComplete and unknown.combinedCopper==nil)
    facts.inventoryComplete=true;facts.prices['11:*:*']={price=25}
    local complete=D.Evaluate(plan,facts,'buy')
    assert(complete.costComplete and complete.combinedCopper==25)
end)
Test('one-shot reception follows the real owner-first event bus and survives reload',function()
    local h=Boot();local C,F,S=h.C,h.F,h.S
    assert(F:ReconcileDemand(nil,{count=1},{count=1}))
    assert(C:RecipeReceive(1,nil,'test-owner'))
    S.Events:Dispatch('CHAT_MESSAGE',1,0,'other','|if11;配方甲|r')
    assert(F:GetRecipeReadDiagnostics().receive.stage=='sender_not_local')
    assert(h.projection().pendingShare,'another player cannot consume the one-shot receiver')
    S.Events:Dispatch('CHAT_MESSAGE',1,0,'GearTest@World','|if11;配方甲|r')
    local d=F:GetRecipeReadDiagnostics()
    assert(d.receive.stage=='imported' and d.receive.accepted==1 and not d.pendingShare)
    assert(h.projection().libraryActiveId=='11')
    local fresh=Boot(h.disk)
    assert(fresh.projection().libraryActiveId=='11','received recipe must persist across a cold reload')
end)
Test('corrupt plan prevents reception before listening and exposes the failure stage',function()
    local h=Boot();local S,C,F=h.S,h.C,h.F
    local original=S.Persistence.PrepareRead
    S.Persistence.PrepareRead=function(self,id,...)
        if id=='v3.craft_plans' then return false,'integrity_failed:fingerprint_mismatch' end
        return original(self,id,...)
    end
    local writes=h.writes
    local ok,why=C:RecipeReceive(1,nil,'test-owner')
    assert(not ok and tostring(why):find('integrity_failed',1,true))
    local d=F:GetRecipeReadDiagnostics()
    assert(d.receive.stage=='store_unavailable' and d.receive.attempts==1 and not d.pendingShare)
    assert(h.writes==writes,'rejecting reception must not overwrite the damaged plan')
end)
Test('each shared recipe has independent quantity/name and selecting it never appends to another recipe',function()
    local h=Boot();local C=h.C
    assert(type(C.RecipeImportLink)=='function','independent recipe import must exist')
    assert(C:RecipeImportLink('|if11;配方甲|r',2))
    local a=h.projection();assert(#a.targets==1 and a.targets[1].itemType==11)
    assert(C:PlanRename('我的配方甲'))
    assert(C:RecipeImportLink('|if22;配方乙|r',4))
    local b=h.projection();assert(#b.targets==1 and b.targets[1].itemType==22 and b.activeId~=a.activeId)
    assert(C:RecipeOpen('11'))
    local back=h.projection();assert(#back.targets==1 and back.targets[1].count==2 and back.name=='我的配方甲')
    assert(C:RecipeImportLink('|if11;配方甲|r',1))
    assert(h.projection().targets[1].count==2,'re-sharing updates the recipe without accumulating or resetting its saved quantity')
    h.failSave=true;assert(not C:RecipeDelete('11'));h.failSave=false
    assert(h.projection().name=='我的配方甲','refused deletion must roll back')
    assert(C:RecipeDelete('11'))
    assert(not C:RecipeOpen('11'),'deleted library entries must not reappear from legacy targets')
    assert(C:RecipeOpen('22') and h.projection().targets[1].count==4)
end)
Test('oversized craft plans are rejected before the native store is touched',function()
    local h=Boot();local F,C,P=h.F,h.C,h.S.Persistence
    local store=P:GetStore('v3.craft_plans')
    assert(store.nativeByteBudget==14336,'craft plans must declare the native physical byte limit')
    assert(C:RecipeImportLink('|if1;原计划|r',1))
    local before=h.Copy(h.disk[store.resolvedKey]);local writes=h.writes
    F.ReadPlanRecipe=function(_,id)
        local materials={}
        for i=1,100 do materials[#materials+1]={itemType=10000+i,count=1,name='超长材料'..i}end
        return {id=tostring(id),product={itemType=id,count=1,name='大配方'},materials=materials}
    end
    local ok,why=C:RecipeImportLink('|if2;大配方|r',1)
    assert(not ok and tostring(why):find('native_byte_budget_exceeded',1,true),'oversize must fail explicitly')
    assert(h.writes==writes,'budget rejection must happen before Native SaveData')
    assert(h.disk[store.resolvedKey].__rsmeta.encodedFingerprint==before.__rsmeta.encodedFingerprint,
        'the previously committed snapshot must remain untouched')
    assert(h.projection().libraryActiveId=='1','rejected mutation must restore the old in-memory plan')
end)
Test('automatic recipe discovery stays in memory while explicit choices and costs survive reload',function()
    local h=Boot();local F,C,P=h.F,h.C,h.S.Persistence
    F.ReadPlanRecipe=function(_,id)
        return {id=tostring(id),product={itemType=id,count=1,name='配方'..id},
            materials={{itemType=id+1,count=1,name='材料'..(id+1),recipeHint=id+1}}}
    end
    F.ReadPlanRecipeTypes=function(_,item)if item<24 then return {item} end;return {}end
    assert(C:RecipeImportLink('|if1;目标|r',1));h.drain()
    assert(h.projection().recipes['20'],'deep discovery should be usable in the current session')
    assert(C:PlanChooseRecipe('2:*:*','2'))
    assert(C:PlanSetRecipeCosts('2:*:*',5,0))
    h.failSave=true;assert(not C:RecipeImportLink('|if99;保存失败|r',1));h.failSave=false
    assert(h.projection().recipes['20'],'a rejected durable action must not erase the current session cache')
    local ok,why=P:SaveStore('v3.craft_plans',{durable=true});assert(ok,why)
    local restored=Boot(h.disk).projection()
    assert(restored.libraryActiveId=='1' and restored.recipes['2'].labor==5 and restored.choices['2:*:*']=='2',
        'explicit recipe choice and labor must survive cold reload')
    assert(not restored.recipes['20'],'automatically discovered cache must not bloat the saved plan')
end)
Test('non-durable user edits cannot queue a plan that exceeds the native budget',function()
    local h=Boot();local F,C,P=h.F,h.C,h.S.Persistence
    F.ReadPlanRecipe=function(_,id)
        return {id=tostring(id),product={itemType=id,count=1,name=string.rep('配',35)..id},
            materials={{itemType=id+1,count=1,name=string.rep('材',35)..id,recipeHint=id+1}}}
    end
    F.ReadPlanRecipeTypes=function(_,id)if id<24 then return {id} end;return {}end
    assert(C:RecipeImportLink('|if1;目标|r',1));h.drain()
    local rejected=false
    for id=2,23 do
        local ok,why=C:PlanChooseRecipe(id..':*:*',tostring(id))
        if not ok then assert(tostring(why):find('native_byte_budget_exceeded',1,true),why);rejected=true;break end
    end
    assert(rejected,'test must cross the physical limit')
    local ok,why=P:SaveStore('v3.craft_plans',{durable=true});assert(ok,why)
end)
Test('same-product recipes retain their own root on fallback, generic selection and cold reload',function()
    local h=Boot();local C=h.C
    h.F.ReadPlanRecipe=function(_,id)
        return {id=tostring(id),product={itemType=100,count=1,name='同名产物'},materials={{itemType=id+200,count=2}}}
    end
    assert(C:RecipeImportLink('|if11;同名产物|r',2))
    local first=h.projection().activeId
    assert(C:RecipeImportLink('|if22;同名产物|r',4))
    local entries=h.projection().libraryEntries
    assert(entries[1].text~=entries[2].text,'same-name recipes need a visible identity suffix')
    assert(C:PlanSelect(first))
    local p=h.projection()
    assert(p.choices['100:*:*']=='11' and p.evaluation.byKey['211:*:*'] and not p.evaluation.byKey['222:*:*'])
    assert(C:RecipeOpen('22'));assert(C:RecipeDelete('22'))
    p=h.projection()
    assert(p.libraryActiveId=='11' and p.choices['100:*:*']=='11' and p.evaluation.byKey['211:*:*'])
    assert(C:PlanRename('冷加载保留'))
    local reloaded=Boot(h.disk);local restored=reloaded.projection()
    assert(restored.name=='冷加载保留' and restored.targets[1].count==2 and restored.choices['100:*:*']=='11')
    assert(#restored.libraryEntries==1 and not reloaded.C:RecipeOpen('22'))
end)
Test('a valid late material hint in a shared DAG is still read and scan failures remain visible',function()
    local h=Boot();local F,C=h.F,h.C
    local records={
        [1]={id='1',product={itemType=1,count=1},materials={{itemType=2,count=1,recipeHint=2},{itemType=3,count=1,recipeHint=3}}},
        [2]={id='2',product={itemType=2,count=1},materials={{itemType=4,count=1}}},
        [3]={id='3',product={itemType=3,count=1},materials={{itemType=4,count=1,recipeHint=4}}},
        [4]={id='4',product={itemType=4,count=1},materials={{itemType=5,count=3}}},
    }
    F.ReadPlanRecipe=function(_,id)return records[id] end
    F.ReadPlanRecipeTypes=function()return {} end
    assert(C:PlanImportLink('|if1;合成共享材料链|r',1));h.drain()
    assert(C:PlanSetAllocation('2:*:*','craft'))
    assert(C:PlanSetAllocation('3:*:*','craft'))
    assert(C:PlanSetAllocation('4:*:*','craft'))
    local p=h.projection()
    assert(p.recipes['4'] and p.choices['4:*:*']=='4','late hint must not be lost because the key was already seen')
    assert(p.evaluation.byKey['5:*:*'].demand==6,'both branches must expand into the shared child quantity')
    assert(p.scanResult and p.scanResult.status=='partial' and #p.scanResult.issues>0,'unresolved leaves must retain bounded scan evidence')
end)
Test('recipe diagnostics retain each candidate failure and observed fields',function()
    local h=Boot();local F,C=h.F,h.C
    F.ReadPlanRecipeTypes=function(_,id)if id==43483 then return {88,89} end;return {} end
    F.ReadPlanRecipe=function(_,id)
        if id==10280 then return {id='10280',product={itemType=44773,count=1,name='赤石'},
            materials={{itemType=43483,grade=0,count=1,name='深邃赤石'}}} end
        return nil,'产物数量未知',{productStatus='ready',productItemType=43483,materialStatus='ready'}
    end
    assert(C:RecipeImportLink('|if10280;赤石|r',1));h.drain()
    local d=F:GetRecipeReadDiagnostics();local text=table.concat(d.traces or {},'\n')
    assert(text:find('43483:0:*',1,true) and text:find('88',1,true) and text:find('89',1,true),text)
    assert(text:find('产物数量未知',1,true) and text:find('productItemType=43483',1,true),text)
end)
Test('live grade-zero materials can show ungraded product recipes without claiming verified craft cost',function()
    local h=Boot();local F,C=h.F,h.C
    local records={
        [10280]={id='10280',product={itemType=44773,count=1,name='秀丽的新月赤石'},
            materials={{itemType=43483,grade=0,count=1,name='深邃的新月赤石'}}},
        [10266]={id='10266',product={itemType=43483,count=1,name='深邃的新月赤石'},
            materials={{itemType=43476,grade=0,count=1,name='下级赤石'}}},
        [10267]={id='10267',product={itemType=43483,grade=2,count=1},materials={{itemType=8,count=1}}},
    }
    F.ReadPlanRecipe=function(_,id)return records[id] end
    F.ReadPlanRecipeTypes=function(_,id)if id==43483 then return {10266,10267} end;return {} end
    assert(C:RecipeImportLink('|if10280;秀丽的新月赤石|r',1));h.drain()
    local p=h.projection();assert(p.choices['43483:0:*']=='10266' and p.recipes['10266'],
        'the matching item with unreported output grade should remain available for preview')
    assert(not p.recipes['10267'],'a known different output grade must be rejected')
    assert(C:PlanSetAllocation('43483:0:*','craft'))
    p=h.projection();assert(not p.evaluation.complete and not p.evaluation.byKey['43476:0:*'],
        'unknown output grade must not be treated as a verified crafting cost')
    assert(C:PlanImportLink('|if10266;深邃的新月赤石|r',1,nil,'material','43483:0:*'),
        'manual subrecipe import must also retain a grade-unverified preview')
    assert(h.projection().choices['43483:0:*']=='10266')
end)
Test('recipe edits are durable and library sheets do not consume the manual plan quota',function()
    local h=Boot();local C=h.C
    -- 这里专测逻辑计划额度；实际 Native 字节上限由独立回归覆盖。
    h.S.Persistence:GetStore('v3.craft_plans').nativeByteBudget=2000000
    for id=1,13 do assert(C:RecipeImportLink('|if'..id..';合成配方|r',1))end
    h.failSave=true
    assert(not C:PlanRename('应回滚'))
    assert(not C:PlanSetQuantity(h.projection().targets[1].id,9))
    h.failSave=false
    assert(h.projection().name~='应回滚' and h.projection().targets[1].count==1)
    assert(C:PlanCopy('独立的手动计划'))
    assert(not h.projection().libraryActiveId,'copying a recipe sheet must create a manual plan')
    assert(C:RecipeOpen('13'))
    assert(C:PlanDelete())
    assert(not C:RecipeOpen('13'),'generic delete must also remove the selected library entry')
end)
Test('the explicitly advertised chat command also saves separate recipes',function()
    local h=Boot();local C=h.C
    assert(C:PlanImportOwnChat('GearTest@World','/rsrecipe |if11;配方甲|r'))
    assert(C:PlanSetQuantity(h.projection().targets[1].id,3))
    assert(C:PlanImportOwnChat('GearTest@World','/rsrecipe |if22;配方乙|r'))
    assert(#h.projection().targets==1 and h.projection().libraryActiveId=='22')
    assert(C:RecipeOpen('11') and h.projection().targets[1].count==3)
end)
Test('independent recipe sheets reject mixed targets while manual plans still accept them',function()
    local h=Boot();local C=h.C
    assert(C:RecipeImportLink('|if11;配方甲|r',1))
    local id=h.projection().targets[1].id
    assert(not C:PlanAddTarget({itemType=22,name='另一个目标'},1))
    assert(not C:PlanRemoveTarget(id),'delete the library entry rather than leaving an empty sheet')
    assert(#h.projection().targets==1)
    assert(C:PlanNew('手动多目标'))
    assert(C:PlanAddTarget({itemType=22,name='目标乙'},1))
    assert(C:PlanAddSavedRecipe('11',1) and #h.projection().targets==2)
end)
Test('deleted unused recipes release capacity without dropping shared subrecipes',function()
    local h=Boot();local C=h.C
    -- 无物理截断的逻辑容量模型；生产环境仍由 Native 字节预算拒绝超限写入。
    h.S.Persistence:GetStore('v3.craft_plans').nativeByteBudget=2000000
    h.F.ReadPlanRecipe=function(_,id)
        return {id=tostring(id),product={itemType=id,count=1,name='合成配方 '..id},materials={{itemType=id==9999 and 8888 or 9999,count=2}}}
    end
    assert(C:RecipeImportLink('|if1;合成配方|r',1))
    assert(C:PlanImportLink('|if9999;共享子配方|r',1,nil,'material','9999:*:*'))
    for id=2,127 do assert(C:RecipeImportLink('|if'..id..';合成配方|r',1))end
    assert(C:RecipeDelete('1'))
    assert(C:RecipeImportLink('|if129;新增配方|r',1),'deleting an unused root must release a recipe slot')
    assert(h.projection().recipes['9999'],'shared subrecipe is still referenced and must survive collection')
    assert(C:RecipeOpen('2'))
    assert(C:PlanSetAllocation('9999:*:*','craft'))
    assert(h.projection().evaluation.byKey['8888:*:*'])
end)
Test('ten cloth expands into thirty wool and material-only import does not add another root',function()
    local h=Boot();local F,C=h.F,h.C
    local records={
        [11]={id='11',product={itemType=11,count=1,name='亮纹布料（合成）'},materials={{itemType=12,count=10,name='布料',recipeHint=12},{itemType=13,count=1,name='柔顺剂'}}},
        [12]={id='12',product={itemType=12,count=1,name='布料'},materials={{itemType=14,count=3,name='绵羊毛'}}},
    }
    F.ReadPlanRecipe=function(_,id)return records[id] end
    F.ReadPlanRecipeTypes=function()return {}end
    assert(C:RecipeImportLink('|if11;亮纹布料|r',1));h.drain()
    assert(C:PlanSetAllocation('12:*:*','craft'))
    local p=h.projection()
    assert(p.evaluation.byKey['12:*:*'].demand==10 and p.evaluation.byKey['14:*:*'].demand==30)
    assert(p.evaluation.byKey['13:*:*'].demand==1 and #p.targets==1)
    assert(not C:PlanImportLink('|if12;布料|r',1,nil,'material','13:*:*'))
    assert(C:PlanImportLink('|if12;布料|r',1,nil,'material','12:*:*'))
    assert(#h.projection().targets==1,'supplementing a material recipe must not create a second finished target')
end)
Test('the unprocessed 65th node remains counted as truncation',function()
    local h=Boot();local F,C=h.F,h.C
    F.ReadPlanRecipe=function(_,id)return {id=tostring(id),product={itemType=id,count=1},materials={{itemType=id+1,count=1,recipeHint=id+1}}}end
    F.ReadPlanRecipeTypes=function()return {}end
    assert(C:PlanImportLink('|if1;合成长链|r',1));h.drain()
    local p=h.projection()
    assert(p.scanResult and p.scanResult.truncated and p.scanResult.pending>0 and p.scanResult.status=='partial')
    assert(not p.recipes['65'],'the 65th node must not be read beyond the budget')
end)
Test('opening an interrupted recipe resumes its material read and does not cancel the same active scan',function()
    local h=Boot();local F,C=h.F,h.C
    F.ReadPlanRecipeTypes=function()return {}end
    F.ReadPlanRecipe=function(_,id)
        if id==11 then return {id='11',product={itemType=11,count=1},materials={{itemType=12,count=2,recipeHint=12}}}end
        if id==12 then return {id='12',product={itemType=12,count=1},materials={{itemType=13,count=3}}}end
        if id==22 then return {id='22',product={itemType=22,count=1},materials={{itemType=23,count=1}}}end
    end
    assert(C:RecipeImportLink('|if11;合成甲|r',1))
    local firstId=h.projection().activeId
    assert(C:RecipeImportLink('|if22;合成乙|r',1));h.drain()
    assert(not h.projection().recipes['12'])
    assert(C:PlanSelect(firstId));assert(h.projection().scan,'generic selection must resume the interrupted read')
    h.S.Scheduler:RunTask('tools_craft_plan_recipes')
    local done=h.projection().scan.done
    assert(C:RecipeOpen('11') and h.projection().scan.done==done,'opening the active entry must not cancel its read')
    h.drain()
    assert(C:PlanSetAllocation('12:*:*','craft'))
    assert(h.projection().evaluation.byKey['13:*:*'].demand==6)
    assert(C:RecipeImportLink('|if22;合成乙|r',1));h.drain()
    assert(C:RecipeDelete('22') and h.projection().scan,'deletion fallback must resume the active recipe read')
    h.drain();assert(h.projection().evaluation.byKey['13:*:*'].demand==6)
end)
Test('adding a saved recipe to a recipe sheet creates a multi-target plan without changing the sheet',function()
    local h=Boot();local C=h.C
    assert(C:RecipeImportLink('|if11;配方甲|r',2))
    local original=h.projection().activeId
    assert(C:RecipeImportLink('|if22;配方乙|r',1))
    assert(C:RecipeOpen('11'))
    assert(type(C.PlanAppendSavedRecipe)=='function','the popup needs an atomic add-to-plan command')
    h.failSave=true
    assert(not C:PlanAppendSavedRecipe('22',3) and h.projection().activeId==original,
        'failed durable save must keep the original independent recipe selected')
    h.failSave=false
    assert(C:PlanAppendSavedRecipe('22',3))
    local combined=h.projection()
    assert(combined.activeId~=original and #combined.targets==2)
    local amounts={};for _,target in ipairs(combined.targets)do amounts[target.itemType]=target.count end
    assert(amounts[11]==2 and amounts[22]==3)
    assert(C:RecipeOpen('11'))
    assert(h.projection().activeId==original and #h.projection().targets==1 and h.projection().targets[1].count==2)
    assert(type(C.PlanAppendCatalogItem)=='function')
    assert(C:PlanAppendCatalogItem('22:*:*',4))
    local catalogPlan=h.projection();local catalogAmounts={}
    for _,target in ipairs(catalogPlan.targets)do catalogAmounts[target.itemType]=target.count end
    assert(catalogAmounts[11]==2 and catalogAmounts[22]==4)
end)
Test('quoting a preview ingredient neither interrupts recipe discovery nor requires an active demand',function()
    local h=Boot();local F,C=h.F,h.C
    local records={
        [1]={id='1',product={itemType=1,count=1,name='成品'},materials={{itemType=2,count=3,name='木材',recipeHint=2}}},
        [2]={id='2',product={itemType=2,count=1,name='木材'},materials={{itemType=3,count=4,name='原木'}}},
    }
    F.ReadPlanRecipe=function(_,id)return records[id]end
    F.ReadPlanRecipeTypes=function()return {}end
    assert(C:RecipeImportLink('|if1;成品|r',1));h.drain()
    assert(not h.projection().evaluation.byKey['3:*:*'])
    assert(C:PlanReadRecipes() and h.projection().scan)
    local requested
    h.S.Services.PriceQuoteQueueV3={RequestQuote=function(_,_,id)requested=id;return true end}
    assert(C:PlanCalibrate('3:*:*'))
    assert(requested==3 and h.projection().scan,'quote must preserve the active recipe scan')
    for _,row in ipairs(h.projection().evaluation.rows)do
        assert(row.key~='3:*:*','a preview price request must not create a demand row')
    end
end)
Test('price batch walks preview recipes once and advances only after each result',function()
    local h=Boot();local F,C=h.F,h.C
    local records={
        [1]={id='1',product={itemType=1,count=1,name='成品'},materials={{itemType=2,count=3,name='木材',recipeHint=2},{itemType=3,count=1,name='原木'}}},
        [2]={id='2',product={itemType=2,count=1,name='木材'},materials={{itemType=3,count=4,name='原木'}}},
    }
    F.ReadPlanRecipe=function(_,id)return records[id]end;F.ReadPlanRecipeTypes=function()return {}end
    assert(C:RecipeImportLink('|if1;成品|r',1));h.drain()
    local calls={}
    h.S.Services.MaterialPriceServiceV3={GetPrice=function()return 50,{freshness='fresh'}end}
    h.S.Services.PriceQuoteQueueV3={RequestQuote=function(_,owner,id,grade,done)
        calls[#calls+1]={owner=owner,id=id,done=done};return true
    end}
    assert(C:PlanCalibrate());assert(#calls==1,'a batch must have only one outstanding request')
    calls[1].done({status='ready'});assert(#calls==2)
    calls[2].done({status='unavailable',error='auction_search_empty'});assert(#calls==3)
    calls[3].done({status='ready'});assert(#calls==3,'a shared ingredient must be searched once')
    local p=h.projection()
    assert(p.quote.status=='completed' and p.quote.completed==3 and p.quote.empty==1)
    assert(p.quoteItems['2:*:*'].status=='none','empty search must be distinct from a request failure')
    assert(p.prices['2:*:*']==nil,'an empty current result must not remain a purchasable cached price')
end)
Test('opening the auction stops the batch and ignores late price callbacks',function()
    local h=Boot();assert(h.C:RecipeImportLink('|if1;成品|r',1))
    local calls,cancelled={},{}
    h.S.Services.PriceQuoteQueueV3={RequestQuote=function(_,owner,id,grade,done)
        calls[#calls+1]={owner=owner,done=done};return true
    end,CancelRequester=function(_,owner)cancelled[owner]=true end}
    assert(h.C:PlanCalibrate());assert(#calls==1)
    calls[1].done({status='blocked',error='native_auction_visible'})
    assert(#calls==1,'manual auction use must prevent subsequent dispatches')
    local p=h.projection();assert(p.quote.status=='stopped' and p.quote.reason=='native_auction_visible')
    calls[1].done({status='ready'})
    assert(h.projection().quote.status=='stopped' and #calls==1,'late completion cannot restart a stopped batch')
end)
Test('a bag-only scan does not claim that the bank is known or the total cost complete',function()
    local h=Boot();local F,C=h.F,h.C
    F.ReadPlanRecipe=function()return {id='1',product={itemType=1,count=1,name='成品'},
        materials={{itemType=2,count=3,name='原木'}},labor=5,feeCopper=0}end
    local bankCount,bankCapacity=2,20
    h.S.Services.InventorySnapshotV3={BuildSnapshot=function(_,scope)
        return {rows={{itemType=2,stack=scope=='bag' and 4 or bankCount}},
            capacity=scope=='bank' and bankCapacity or 20,truncated=false,readErrors=0,unknown=0,fallback=0}
    end}
    h.S.ApiImports={Acquire=function()return true end}
    local bankVisible=true
    h.S.Features=h.S.Features or {};h.S.Features.tools_bag={GetStorageWindowContext=function()
        return {status='ready',visible=bankVisible}
    end}
    h.S.Services.MaterialPriceServiceV3={GetPrice=function(_,id)if id==2 then return 10,{freshness='fresh'} end end}
    assert(C:RecipeImportLink('|if1;成品|r',2))
    assert(C:PlanRefreshInventory(false))
    local partial=h.projection()
    assert(partial.inventoryScope=='bag' and not partial.inventoryComplete)
    assert(partial.evaluation.byKey['2:*:*'].owned==4 and not partial.evaluation.costComplete)
    assert(C:PlanRefreshInventory(true))
    local complete=h.projection()
    assert(complete.inventoryScope=='bag_bank' and complete.inventoryComplete)
    assert(complete.evaluation.byKey['2:*:*'].owned==6 and complete.evaluation.byKey['2:*:*'].shortage==0)
    assert(C:PlanRefreshInventory(true) and h.projection().evaluation.byKey['2:*:*'].owned==6,
        'repeated scans must replace the snapshots rather than double-count them')
    bankVisible=false
    assert(not C:PlanRefreshInventory(true) and not h.projection().inventoryComplete,
        'cached bank capacity is not proof that the bank window is open')
    bankVisible=true
    bankCapacity=0
    assert(not C:PlanRefreshInventory(true) and not h.projection().inventoryComplete,
        'an unreadable or closed bank must not be treated as a confirmed empty bank')
end)
Test('item grade metadata is readable for plain materials and cached across reads',function()
    local h=Boot();local S,F=h.S,h.F
    assert(type(F.GetItemGrade)=='function','item grade reader must be reachable from the plan feature')
    local reads=0;local original=S.Api.CallCapability
    S.ApiImports={Acquire=function(_,owner,dependencies)
        assert(owner=='feature:tools_craft:item_metadata' and dependencies[1]=='X2Item:GetItemInfoByType');return true
    end}
    S.Api.CallCapability=function(self,capability,object,method,id,...)
        if capability=='X2Item:GetItemInfoByType' then reads=reads+1;return true,{itemType=id,itemGrade=2} end
        return original(self,capability,object,method,id,...)
    end
    local grade=select(1,F:GetItemGrade(19940))
    assert(grade==2,'a plain material must resolve its quality from item metadata')
    assert(select(1,F:GetItemGrade(19940))==2 and reads==1,'successful metadata must be cached')
end)
Test('integer search improves the hand-made allocation',function()
    local h=Boot();local D=h.S.CraftPlanDomain
    local facts={inventoryComplete=true,inventory={},recipes={
        ['1:*:*']={id='1',product={itemType=1,count=1},materials={{itemType=2,count=1}},labor=10,feeCopper=0},
        ['2:*:*']={id='2',product={itemType=2,count=1},materials={{itemType=3,count=2}},labor=5,feeCopper=0}},
        prices={['2:*:*']={price=300,freshness='fresh'},['3:*:*']={price=100,freshness='fresh'}}}
    -- 用户手动把 2 号设成买：300。自制只要 2*100。
    local plan={targets={{itemType=1,count=1}},allocations={['2:*:*']={mode='buy'}},laborValueCopper=10}
    local comparison=D.Compare(plan,facts)
    assert(comparison.manual.cashCopper==300)
    assert(comparison.recommendation.kind=='integer_batches','the recommendation must use the complete batch search')
    assert(comparison.recommendation.allocations['2:*:*'].mode=='craft')
    assert(comparison.recommendation.evaluation.cashCopper==200)
end)
Test('a target switched to buying stops expanding its materials',function()
    local h=Boot();local D=h.S.CraftPlanDomain
    local facts={inventoryComplete=true,inventory={},recipes={
        ['1:*:*']={id='1',product={itemType=1,count=1},materials={{itemType=2,count=8}},labor=10,feeCopper=0}},
        prices={['1:*:*']={price=500,freshness='fresh'},['2:*:*']={price=100,freshness='fresh'}}}
    -- 目标默认自制：8 个材料 × 100。
    local craft=D.Evaluate({targets={{itemType=1,count=1}},allocations={}},facts)
    assert(craft.cashCopper==800)
    -- 显式选「成品」：直接买成品，不再下探材料。
    local buy=D.Evaluate({targets={{itemType=1,count=1}},allocations={['1:*:*']={mode='buy'}}},facts)
    assert(buy.cashCopper==500 and buy.byKey['2:*:*']==nil,'buying the target must not expand its materials')
end)
Test('recommendation evaluates crafting an intermediate that defaults to buying',function()
    local h=Boot();local D=h.S.CraftPlanDomain
    local facts={inventoryComplete=true,inventory={},catalog={['3:*:*']={base=true}},
        recipes={['1:*:*']={id='1',product={itemType=1,count=1},materials={{itemType=2,count=3}},labor=5,feeCopper=0},
            ['2:*:*']={id='2',product={itemType=2,count=1},materials={{itemType=3,count=4}},labor=2,feeCopper=0}},
        prices={['1:*:*']={price=100},['2:*:*']={price=10},['3:*:*']={price=1}}}
    local plan={targets={{itemType=1,count=2}},allocations={}}
    local comparison=D.Compare(plan,facts)
    assert(comparison.manual.cashCopper==60 and comparison.manual.byKey['2:*:*'].buy==6)
    assert(comparison.recommendation.evaluation.cashCopper==24)
    assert(comparison.recommendation.allocations['2:*:*'].mode=='craft' and not plan.allocations['2:*:*'])
end)
Test('recommendation reaches the whole-batch boundary when craft output does not divide the shortage',function()
    local h=Boot();local D=h.S.CraftPlanDomain
    -- 缺口 50、每批产出 30：全做要 2 批并留下 10 个余料，全买更贵，最优是 1 批加买 20。
    local facts={inventoryComplete=true,inventory={},
        recipes={['1:*:*']={id='1',product={itemType=1,count=30},materials={{itemType=2,count=10}},labor=0,feeCopper=0}},
        prices={['1:*:*']={price=10},['2:*:*']={price=25}}}
    local plan={targets={{itemType=1,count=50}},allocations={}}
    local comparison=D.Compare(plan,facts)
    assert(comparison.manual.cashCopper==500,'the default plan crafts two batches')
    local chosen=comparison.recommendation.allocations['1:*:*']
    assert(chosen and chosen.mode=='mixed' and chosen.buy==20 and chosen.craft==30,
        'recommendation should keep one batch and buy the remainder')
    assert(comparison.recommendation.evaluation.cashCopper==450)
end)
Test('integer batches handle an exact output multiple',function()
    local h=Boot();local D=h.S.CraftPlanDomain
    local facts={inventoryComplete=true,inventory={},
        recipes={['1:*:*']={id='1',product={itemType=1,count=30},materials={{itemType=2,count=10}},feeCopper=0}},
        prices={['1:*:*']={price=10},['2:*:*']={price=25}}}
    local comparison=D.Compare({targets={{itemType=1,count=60}},allocations={}},facts)
    assert(comparison.recommendations.cash.evaluation.cashCopper==500,'two batches are cheapest for this exact multiple')
end)
Test('cash recommendation remains available with unknown labor when labor is not priced',function()
    local h=Boot();local D=h.S.CraftPlanDomain
    local facts={inventoryComplete=true,inventory={},catalog={['3:*:*']={base=true}},
        recipes={['1:*:*']={id='1',product={itemType=1,count=1},materials={{itemType=2,count=3}},feeCopper=0},
            ['2:*:*']={id='2',product={itemType=2,count=1},materials={{itemType=3,count=4}},feeCopper=0}},
        prices={['1:*:*']={price=100},['2:*:*']={price=10},['3:*:*']={price=1}}}
    local comparison=D.Compare({targets={{itemType=1,count=2}},allocations={}},facts)
    assert(comparison.recommendation.available and comparison.recommendation.evaluation.cashCopper==24)
    assert(not comparison.recommendation.evaluation.laborComplete)
end)
Test('an incomplete comparison cannot be applied as a recommendation',function()
    local h=Boot();local ok,comparison=h.C:PlanCompare()
    assert(ok and comparison.result.recommendation.available==false)
    assert(not h.C:PlanApplyRecommendation(comparison.revision))
end)
Test('route comparisons disclose stale prices while retaining the saved estimate',function()
    local h=Boot();local D=h.S.CraftPlanDomain
    local facts={inventoryComplete=true,inventory={},recipes={
        ['1:*:*']={id='1',product={itemType=1,count=1},materials={{itemType=2,count=3}},labor=5,feeCopper=0},
    },prices={['2:*:*']={price=10,freshness='stale'}}}
    local result=D.Evaluate({targets={{itemType=1,count=2}},allocations={}},facts)
    assert(result.cashCopper==60 and result.costComplete and result.priceStale==true)
end)
Test('a purchased material does not need a known subrecipe for a complete cost',function()
    local h=Boot();local D=h.S.CraftPlanDomain
    local result=D.Evaluate({targets={{itemType=1,count=2}},allocations={}},
        {inventoryComplete=true,inventory={},recipes={
            ['1:*:*']={id='1',product={itemType=1,count=1},materials={{itemType=2,count=3}},labor=5,feeCopper=0},
        },prices={['2:*:*']={price=10}}})
    assert(result.complete and result.costComplete and result.cashCopper==60)
    assert(result.byKey['2:*:*'].recipeUnknown and result.byKey['2:*:*'].buy==6)
end)
Test('wildcard materials consume graded inventory without counting it twice',function()
    local D=Boot().S.CraftPlanDomain
    local facts={inventoryComplete=true,inventory={['2:1:*']=4,['2:2:*']=2},bagInventory={['2:1:*']=3},
        recipes={['1:*:*']={id='1',product={itemType=1,count=1},materials={{itemType=2,count=3}},labor=0,feeCopper=0}},prices={}}
    local result=D.Evaluate({targets={{itemType=1,count=2}}},facts)
    assert(result.byKey['2:*:*'].owned==6 and result.byKey['2:*:*'].fromBank==3)
    assert(not result.costComplete and result.byKey['2:*:*'].inventoryUncertain,
        'unverified grade matching must remain provisional')
    facts.inventory={['2:*:*']=6};facts.bagInventory={['2:*:*']=3}
    local known=D.Evaluate({targets={{itemType=1,count=2}}},facts)
    assert(known.costComplete and known.cashCopper==0 and known.valueComplete==false)
    facts.inventory={['2:1:*']=4,['2:2:*']=2}
    local conflicting=D.Evaluate({targets={{itemType=1,count=2},{itemType=2,grade=1,count=2}},allocations={['2:1:*']={mode='buy'}}},facts)
    assert(not conflicting.complete,'overlapping graded and wildcard demands must not double consume stock')
end)
Test('finished targets default to crafting and intermediate materials default to buying',function()
    local h=Boot();local D=h.S.CraftPlanDomain
    local facts={inventoryComplete=true,inventory={},catalog={['3:*:*']={base=true}},
        recipes={
            ['1:*:*']={id='1',product={itemType=1,count=1},materials={{itemType=2,count=3}},labor=5,feeCopper=0},
            ['2:*:*']={id='2',product={itemType=2,count=1},materials={{itemType=3,count=4}},labor=2,feeCopper=0},
        },prices={['1:*:*']={price=100},['2:*:*']={price=10},['3:*:*']={price=2}}}
    local plan={targets={{itemType=1,count=2}},allocations={}}
    local result=D.Evaluate(plan,facts)
    assert(result.byKey['1:*:*'].craft==2 and result.byKey['1:*:*'].buy==0)
    assert(result.byKey['2:*:*'].buy==6 and result.byKey['2:*:*'].craft==0)
    assert(not result.byKey['3:*:*'] and result.cashCopper==60 and result.labor==10)
    plan.allocations['2:*:*']={mode='craft'}
    result=D.Evaluate(plan,facts)
    assert(result.byKey['2:*:*'].craft==6 and result.byKey['3:*:*'].buy==24)
    assert(result.cashCopper==48 and result.labor==22)
    plan.allocations['1:*:*']={mode='buy'}
    result=D.Evaluate(plan,facts)
    assert(result.byKey['1:*:*'].buy==2 and not result.byKey['2:*:*'] and result.labor==0)
end)
print('CRAFT LIBRARY RESULT '..passed..' passed / '..failed..' failed')
if failed>0 then os.exit(1)end

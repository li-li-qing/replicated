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
    dofile('features/tools/craft/rs_craft_feature.lua');dofile('features/tools/craft/rs_craft_plan_domain.lua');dofile('features/tools/craft/rs_craft_plan_feature.lua')
    local F=S.Features.tools_craft
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
Test('recipe edits are durable and library sheets do not consume the manual plan quota',function()
    local h=Boot();local C=h.C
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

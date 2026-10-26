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
    assert(C:RecipeOpen('2') and h.projection().evaluation.byKey['8888:*:*'])
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
    assert(h.projection().evaluation.byKey['13:*:*'].demand==6)
    assert(C:RecipeImportLink('|if22;合成乙|r',1));h.drain()
    assert(C:RecipeDelete('22') and h.projection().scan,'deletion fallback must resume the active recipe read')
    h.drain();assert(h.projection().evaluation.byKey['13:*:*'].demand==6)
end)
print('CRAFT LIBRARY RESULT '..passed..' passed / '..failed..' failed')
if failed>0 then os.exit(1)end

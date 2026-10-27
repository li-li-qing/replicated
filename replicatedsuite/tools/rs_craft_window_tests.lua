-- 配方小窗：真实 RSUI、WindowShell、FloatingSurface 与 Windowing；Native 绘制/鼠标为替身。
-- 作者：Replicated
-- QQ群：1104129461
local passed,failed=0,0
local function Test(name,fn)
    local ok,why=xpcall(fn,debug.traceback)
    if ok then passed=passed+1;print('PASS craft-window '..name)
    else failed=failed+1;print('FAIL craft-window '..name..': '..tostring(why))end
end
local function Boot(scale,options)
    options=options or {}
    local h=dofile('tools/rs_gear_page_test_host.lua')({})
    local S,UI,R=h.S,h.S.UI,h.S.RSUI
    dofile('ui/framework/rs_ui_forms.lua')
    S.PhysicalId=function(value)return tostring(value)end
    local function Augment(n)
        function n:GetOffset()return self.x,self.y end
        function n:GetExtent()return self.width,self.height end
        function n:GetEffectiveOffset()
            local p=self.parent;local x,y=0,0
            if type(p)=='table' and p.GetEffectiveOffset then x,y=p:GetEffectiveOffset()end
            return x+self.x,y+self.y
        end
        function n:GetEffectiveExtent()return self.width,self.height end
        function n:SetUILayer()return true end
        function n:SetCloseOnEscape()return true end
        function n:SetWindowModal()return true end
        function n:SetDrawPriority()return true end
        function n:Raise()return true end
        function n:EnableDrag()return true end
        function n:SetDragCondition()return true end
        function n:StartMoving()self.moving=true;return true end
        function n:StopMovingOrSizing()self.moving=false;return true end
        function n:SetAlpha(value)self.alpha=value;return true end
        return n
    end
    UIParent=Augment(h.Native(nil,'UIParent',0,0,1280,768))
    for _,name in ipairs({'CreateEmptyWidget','CreatePanel','CreateButton','CreateLabel'})do
        local create=UI[name];UI[name]=function(...)return Augment(create(...))end
    end
    S.NativeObjectFactory={CreateWindow=function(_,id)return Augment(h.Native(UIParent,id,0,0,1,1))end}
    UI.ClaimNativeAuthority=function()return true end
    UI.InvalidateNativeState=function()return true end
    UI.SetAlpha=function(_,n,v)n.alpha=v;return true end
    UI.EnsureAlpha=function(_,n,v)n.alpha=v;return true,false end
    UI.BeginNativeGeometryLease=function()return true end
    UI.EndNativeGeometryLease=function()return true end
    R.ApplyOpacityChannels=function()return true end
    R.ApplyFontScale=function()return true end
    R.WindowPreferences={GetTopmost=function()return false end,SetTopmost=function()return true end}
    dofile('data/rs_data_registry.lua');dofile('data/ids/rs_item_ids.lua');dofile('data/ids/rs_quest_ids.lua');dofile('core/rs_constants.lua')
    dofile('core/rs_layout.lua')
    S.Layout.GetContext=function()return {logicalWidth=1280,logicalHeight=768,usableWidth=1280,usableHeight=768,
        safeLeft=0,safeTop=0,safeRight=0,safeBottom=0,addonScale=scale,uiScale=1,effectiveScale=1}end
    dofile('ui/framework/rs_ui_windowing.lua')
    dofile('ui/framework/rs_ui_window_shell_v3.lua')
    dofile('ui/framework/rs_ui_floating_surface.lua')
    local held,stored=false,h.Copy(options.saved)
    local rows={}
    for i=1,20 do rows[i]={key=tostring(i),item={itemType=i,name='材料 '..i},demand=i,owned=0,shortage=i}end
    S.Features.tools_craft={Id='tools_craft',UpdateTopic='craft.updated',Commands={
        SetCraftWindowState=function(_,value)
            if h.failWindowSave then return false,'injected window save rejection' end
            stored=h.Copy(value);return true
        end,
    },GetCraftWindowState=function()return h.Copy(stored)end,
        GetProjection=function()return {autoSidecar=false,plan=h.plan or {evaluation={rows=rows}}}end,
        Initialize=function()return true end,
        AcquireConsumer=function()held=true;return true end,HasConsumer=function()return held end,
        ReleaseConsumer=function()held=false;return true end}
    h.feature=S.Features.tools_craft
    if options.configure then options.configure(h,h.feature)end
    S.Services.CraftSurfaceV3={GetSnapshot=function()return {status='unknown'}end}
    dofile('presentation/v3/widgets/rs_v3_widget_host.lua')
    dofile('presentation/v3/widgets/rs_v3_craft_sidecar.lua')
    assert(S.UIV3.CraftSidecar:OpenManual())
    h.window=S.UIV3.WidgetHost:GetInstance('tools.craft_sidecar')
    h.saved=function()return stored end
    h.viewport=function(width,height)
        UIParent.width,UIParent.height=width,height
        S.Layout.GetContext=function()return {logicalWidth=width,logicalHeight=height,usableWidth=width,usableHeight=height,
            safeLeft=0,safeTop=0,safeRight=0,safeBottom=0,addonScale=scale,uiScale=1,effectiveScale=1}end
    end
    return h
end

Test('title drag is enabled and reopen preserves the committed position',function()
    local h=Boot(1)
    local w=h.window
    local handle=w.windowController.dragHandle
    assert(handle.events.OnDragStart(),'the popup title must be draggable by default')
    w.shell.window.x,w.shell.window.y=200,120
    assert(handle.events.OnDragStop())
    local x,y=w.shell.window.x,w.shell.window.y
    assert(h.saved(),'a successful drag must persist the popup state')
    assert(w:Hide())
    assert(h.S.UIV3.CraftSidecar:OpenManual())
    assert(w.shell.window.x==x and w.shell.window.y==y,'reopen must not anchor the popup to the right edge')
end)

Test('offscreen saved intent is recovered and viewport changes keep the complete popup reachable',function()
    local h=Boot(1,{saved={width=360,height=430,locked=false,userMoved=true,
        coordinateSpace='logical-free-v2',x=10000,y=-1000}})
    local frame=h.window.shell.window
    assert(frame.x>=0 and frame.y>=0 and frame.x+frame.width<=1280 and frame.y+frame.height<=768)
    h.viewport(640,360)
    assert(h.window:ApplyLayout(true))
    assert(frame.x>=0 and frame.y>=0 and frame.x+frame.width<=640 and frame.y+frame.height<=360)
end)

Test('drag and reset rejection restore Native geometry and state, recovery returns the window to centre',function()
    local h=Boot(1)
    local w=h.window
    local handle=w.windowController.dragHandle
    assert(handle.events.OnDragStart())
    w.shell.window.x,w.shell.window.y=200,120
    assert(handle.events.OnDragStop())
    h.failWindowSave=true
    assert(handle.events.OnDragStart())
    w.shell.window.x,w.shell.window.y=700,200
    assert(not handle.events.OnDragStop())
    assert(w.shell.window.x==200 and w.shell.window.y==120,'rejected drag must restore the old Native position')
    assert(not h.S.UIV3.CraftSidecar:ResetPosition())
    assert(w.shell.window.x==200 and w.shell.window.y==120,'rejected reset must leave the old position visible')
    h.failWindowSave=false
    assert(h.S.UIV3.CraftSidecar:ResetPosition())
    assert(w.shell.window.x==460 and w.shell.window.y==169,'recovery should use the centred default intent')
    assert(not h.saved().userMoved)
end)

for _,scale in ipairs({.75,1,1.5,2})do
    Test('window and controls remain inside their bounds at addon scale '..scale,function()
        local h=Boot(scale)
        local w=h.window
        local frame=w.shell.window
        assert(frame.x>=0 and frame.y>=0 and frame.x+frame.width<=1280 and frame.y+frame.height<=768,
            'scaled popup must fit the game viewport')
        local count=0
        local function Check(node)
            if node.visibility=='collapsed' or node.visible==false or node.viewportVisible==false then return end
            local parent=node.parentComponent
            if parent and node.width and parent.width then
                assert((node.x or 0)>=-.1 and (node.y or 0)>=-.1 and (node.x or 0)+node.width<=parent.width+.1
                    and (node.y or 0)+node.height<=parent.height+.1,
                    'content escapes parent: '..node.id..' '..tostring(node.x)..','..tostring(node.y)..' '..node.width..'x'..node.height..' parent '..parent.width..'x'..parent.height)
                count=count+1
            end
            for _,child in ipairs(node.children or {})do Check(child)end
        end
        Check(w.shell.root)
        assert(count>20,'the real Shell and material table descendants must participate in layout')
    end)
end

Test('real popup controls manage a single recipe and show the recursive material tree',function()
    local received,receivedMaterial,opened,deleted,imported
    local function Configure(h,F)
        local function Plan(id)
            local p={activeId='p'..id,libraryActiveId=id,name=id=='11' and '亮纹布料' or '第二份配方',
                libraryEntries={{value='11',text='亮纹布料'},{value='22',text='第二份配方'}},
                targets={{id='t1',key='11:*:*',itemType=11,count=1}},choices={['11:*:*']='11',['12:*:*']='12'},
                recipes={['11']={materials={{itemType=12},{itemType=13}}},['12']={materials={{itemType=14}}}},
                evaluation={byKey={}},inventoryComplete=false}
            for i,name in ipairs({'亮纹布料','布料','柔顺剂','绵羊毛'})do
                local itemType=i+10;local key=itemType..':*:*'
                p.evaluation.byKey[key]={key=key,item={itemType=itemType,name=name},demand=({1,10,1,30})[i],owned=0,shortage=1,recipeUnknown=i>=3}
            end
            return p
        end
        h.plan=Plan('11')
        local C=F.Commands
        C.RecipeOpen=function(_,id)opened=id;h.plan=Plan(id);return true end
        C.PlanAddSavedRecipe=function()error('switching must never append')end
        C.PlanRename=function(_,name)h.plan.name=name;return true end
        C.PlanSetQuantity=function(_,id,count)assert(id=='t1');h.plan.targets[1].count=count;return true end
        C.RecipeDelete=function(_,id)deleted=id;h.plan=Plan('22');h.plan.libraryEntries={{value='22',text='第二份配方'}};return true end
        C.PlanReceiveShare=function()error('the popup must prefer independent recipe receiving')end
        C.RecipeReceive=function(_,count,output)received={count,output};return true end
        C.RecipeReceiveMaterial=function(_,key)receivedMaterial=key;return true end
        C.RecipeImportLink=function(_,value,count,output)imported={value,count,output};return true end
    end
    local h=Boot(1,{configure=Configure});local w=h.window
    local function Find(id,node)
        node=node or w.shell.root;if node.id==id then return node end
        for _,child in ipairs(node.children or {})do local found=Find(id,child);if found then return found end end
    end
    local function Click(suffix)return assert(Find('v3_craft_sidecar_'..suffix),'missing control '..suffix):Click()end
    assert(w.table:GetItemCount()==4)
    assert(w.table:GetItem(3).name:find('绵羊毛',1,true) and w.table:GetItem(3).need=='30')
    w.table:SetSelectedIndex(1);assert(Click('expand'));assert(w.table:GetItemCount()==1)
    assert(Click('expand'));assert(w.table:GetItemCount()==4)
    w.table:SetSelectedIndex(2);assert(Click('receive_material'));assert(receivedMaterial=='12:*:*')
    w.outputCount:SetValue('3',false)
    assert(Click('add_plan') and received and received[1]==1 and received[2]==3,
        'the popup must pass an explicitly calibrated recipe output when receiving a share')
    assert(Click('manage'))
    w.shareInput:SetValue('|if11;亮纹布料|r',false);w.outputCount:SetValue('2',false)
    assert(Click('import_link') and imported[1]=='|if11;亮纹布料|r' and imported[3]==2)
    w.nameInput:SetValue('我的布料配方',false);assert(Click('rename'));assert(h.plan.name=='我的布料配方')
    assert(w.quantity.input:BeginEditing('test'));w.quantity.input.root.text='5'
    assert(w.quantity.apply:Click());assert(h.plan.targets[1].count==5)
    assert(w.quantity.input:BeginEditing('old_session'));w.quantity.input.root.text='9'
    h.plan.sessionRevision=2;h.plan.name='新会话配方';h.plan.targets[1].count=3;w:Refresh()
    assert(w.nameInput:GetDraftValue()=='新会话配方','same plan id in a new session must replace the old name draft')
    assert(w.quantity.apply:Click());assert(h.plan.targets[1].count==3,'old numeric draft must not write into a new session')
    w.search:SetValue('亮纹',false);assert(Click('filter'));assert(#w.recipe.items==1)
    assert(Click('clear_filter'));assert(#w.recipe.items==2)
    assert(w.recipe:SetSelectedValue('22'),tostring(w.recipe.rsUiDegradedReason))
    assert(opened=='22','selected recipe command must run: '..tostring(opened))
    assert(not w.selectedMaterial,'switch must clear the previous material selection: '..tostring(w.table:GetSelectedIndex()))
    assert(Click('delete') and not deleted,'first delete click must only arm the confirmation')
    assert(Click('delete') and deleted=='22');assert(#w.recipe.items==1)
end)
Test('selected material can preview subrecipe, change source and search without leaving popup',function()
    local calls={}
    local h=Boot(1,{configure=function(host,F)
        host.plan={activeId='p1',sessionRevision=1,name='测试计划',inventoryComplete=true,
            targets={{id='t1',key='1:*:*',itemType=1,count=2}},allocations={},
            choices={['1:*:*']='1',['2:*:*']='2'},
            recipes={['1']={product={itemType=1,count=1},materials={{itemType=2,count=3,name='木材'}}},
                ['2']={product={itemType=2,count=1},materials={{itemType=3,count=4,name='原木'}}}},
            evaluation={cashCopper=60,valueCopper=60,labor=10,laborComplete=true,costComplete=true,byKey={
                ['1:*:*']={key='1:*:*',item={itemType=1,name='成品'},demand=2,owned=0,shortage=2,craft=2,buy=0},
                ['2:*:*']={key='2:*:*',item={itemType=2,name='木材'},demand=6,owned=0,shortage=6,craft=0,buy=6,price=10}}}}
        F.Commands.PlanSetAllocation=function(_,key,mode,buy,craft)
            calls[#calls+1]=key..':'..mode..(mode=='mixed' and (':'..buy..':'..craft) or '');return true
        end
        F.Commands.PlanSearch=function(_,key)calls[#calls+1]=key..':search';return true end
        F.Commands.PlanCalibrate=function(_,key)calls[#calls+1]=key..':quote';return true end
    end})
    local w=h.window
    assert(w.table.height>=81,'compact popup must leave at least three material rows visible; height='..tostring(w.table.height))
    assert(w.table:GetItemCount()==3,'purchased intermediate must still show its recipe preview')
    assert(w.table:GetItem(3).preview==true and w.table:GetItem(3).need=='4/次',
        'preview shows per-batch ingredient amount without counting it as a purchase')
    local function Find(id,node)
        node=node or w.shell.root;if node.id==id then return node end
        for _,child in ipairs(node.children or {})do local found=Find(id,child);if found then return found end end
    end
    local function Click(suffix)return assert(Find('v3_craft_sidecar_'..suffix),'missing '..suffix):Click()end
    w.table:SetSelectedIndex(2)
    assert(#calls==0,'selecting and previewing must not send an auction query')
    assert(Click('buy') and Click('craft') and Click('search_auction') and Click('quote_one'))
    assert(table.concat(calls,',')=='2:*:*:buy,2:*:*:craft,2:*:*:search,2:*:*:quote')
    assert(Click('mixed'))
    w.mixedBuy:SetValue('2',false);w.mixedCraft:SetValue('4',false)
    assert(Click('apply_mixed'))
    assert(calls[#calls]=='2:*:*:mixed:2:4','mixed amounts must be applied to the selected material')
    h.feature.Commands.PlanSearch=function()return false,'拍卖窗口不可用' end
    assert(not Click('search_auction'))
    assert(w.status.text:find('拍卖窗口不可用',1,true),'a failed action must not be overwritten by selection refresh')
end)
Test('shared material rows show per-parent need while inventory is labeled as shared',function()
    local h=Boot(1,{configure=function(host)
        host.plan={activeId='p1',sessionRevision=1,name='双目标',inventoryComplete=true,
            targets={{id='t1',key='1:*:*',itemType=1,count=1},{id='t2',key='2:*:*',itemType=2,count=1}},
            choices={['1:*:*']='1',['2:*:*']='2',['3:*:*']='3'},
            recipes={['1']={materials={{itemType=3,count=40,name='原木'}}},
                ['2']={materials={{itemType=3,count=30,name='原木'}}},
                ['3']={materials={{itemType=4,count=1,name='树皮'}}}},
            evaluation={byKey={
                ['1:*:*']={key='1:*:*',item={itemType=1,name='武器'},demand=1,owned=0,shortage=1,craft=1,batches=1,parents={}},
                ['2:*:*']={key='2:*:*',item={itemType=2,name='防具'},demand=1,owned=0,shortage=1,craft=1,batches=1,parents={}},
                ['3:*:*']={key='3:*:*',item={itemType=3,name='原木'},demand=70,owned=50,shortage=20,craft=20,batches=20,parents={'1:*:*','2:*:*'}},
                ['4:*:*']={key='4:*:*',item={itemType=4,name='树皮'},demand=20,owned=0,shortage=20,buy=20,craft=0,parents={'3:*:*'}}}}}
    end})
    local w=h.window
    assert(w.table:GetItemCount()==6)
    assert(w.table:GetItem(2).need=='40' and w.table:GetItem(5).need=='30',
        'each parent must show its own contribution instead of repeating the total of 70')
    assert(w.table:GetItem(2).held=='合50' and w.table:GetItem(5).shortage=='合20',
        'shared stock and shortage must be explicitly labeled as aggregate')
    w.table:SetSelectedIndex(2)
    local function Find(id,node)
        node=node or w.shell.root;if node.id==id then return node end
        for _,child in ipairs(node.children or {})do local found=Find(id,child);if found then return found end end
    end
    assert(Find('v3_craft_sidecar_expand'):Click())
    assert(w.table:GetItemCount()==5,'collapsing one occurrence must not collapse the other branch')
end)
Test('popup actions drive the real plan and update the visible purchase and labor totals',function()
    local searched
    local h=Boot(1,{configure=function(host,uiFeature)
        local S=host.S
        dofile('core/rs_demand.lua');dofile('features/shared/rs_shared_bounds.lua');dofile('features/shared/rs_feature_slice_factory.lua')
        dofile('features/tools/craft/rs_craft_feature.lua');dofile('features/tools/craft/rs_craft_plan_domain.lua')
        dofile('features/tools/craft/rs_craft_plan_feature.lua')
        local F=S.Features.tools_craft
        F.enabled=true;F.consumerCount=1
        F.ReadPlanRecipe=function()
            return {id='1',product={itemType=1,count=1,name='木材'},
                materials={{itemType=2,count=3,name='原木'}}}
        end
        F.ReadPlanRecipeTypes=nil
        S.Services.InventorySnapshotV3={BuildSnapshot=function(_,scope)
            return {rows=scope=='bank' and {} or {{itemType=2,stack=4}},capacity=20,truncated=false,readErrors=0,unknown=0,fallback=0}
        end}
        S.ApiImports={Acquire=function()return true end}
        S.Features.tools_bag={GetStorageWindowContext=function()return {status='ready',visible=true}end}
        S.Services.MaterialPriceServiceV3={GetPrice=function(_,id)
            if id==2 then return 10,{freshness='fresh'} end
        end}
        S.Services.AuctionSearchBridgeV3={Search=function(_,_,name)searched=name;return true end}
        assert(F.Commands:RecipeImportLink('|if1;木材|r',2))
        assert(F.Commands:PlanSetRecipeCosts('1:*:*',5,0))
        assert(F.Commands:PlanRefreshInventory(false))
        uiFeature.Commands=F.Commands
        uiFeature.GetProjection=function()return F:GetProjection()end
        S.Features.tools_craft=uiFeature
    end})
    local w=h.window
    assert(w.table:GetItemCount()==2)
    assert(w.table:GetItem(2).need=='6' and w.table:GetItem(2).held=='包4' and w.table:GetItem(2).shortage=='?')
    assert(w.summary.text:find('10',1,true),'two crafting batches must show ten labor')
    w.table:SetSelectedIndex(2)
    local function Find(id,node)
        node=node or w.shell.root;if node.id==id then return node end
        for _,child in ipairs(node.children or {})do local found=Find(id,child);if found then return found end end
    end
    assert(Find('v3_craft_sidecar_search_auction'):Click() and searched=='原木')
    assert(Find('v3_craft_sidecar_buy'):Click())
    assert(Find('v3_craft_sidecar_manage'):Click())
    assert(Find('v3_craft_sidecar_bank'):Click())
    assert(Find('v3_craft_sidecar_manage'):Click())
    assert(w.table:GetItem(2).held=='4')
    assert(w.table:GetItem(2).shortage=='2')
end)
Test('management mode temporarily replaces the material list without moving the compact window',function()
    local h=Boot(1);local w=h.window;local frame=w.shell.window
    local function Find(id,node)
        node=node or w.shell.root;if node.id==id then return node end
        for _,child in ipairs(node.children or {})do local found=Find(id,child);if found then return found end end
    end
    assert(Find('v3_craft_sidecar_manage'):Click())
    h.S.RSUI:FlushLayoutQueue()
    assert(w.table.visibility=='collapsed','management controls must not squeeze the material list to zero')
    assert(w.manualLabor:ParticipatesInLayout() and w.shareInput:ParticipatesInLayout())
    assert(frame.width==360 and frame.height==430)
    assert(Find('v3_craft_sidecar_manage'):Click())
    h.S.RSUI:FlushLayoutQueue()
    assert(w.table.visibility=='visible' and w.table.height>=81)
end)
Test('popup shows selected stale price and allows explicit labor calibration',function()
    local saved
    local h=Boot(1,{configure=function(host,F)
        host.plan={activeId='p1',sessionRevision=1,name='计划',inventoryComplete=true,
            targets={{id='t1',key='1:*:*',itemType=1,count=2}},allocations={},
            choices={['1:*:*']='1'},recipes={['1']={product={itemType=1,count=1},materials={}}},
            prices={['1:*:*']={price=25,freshness='stale',ageMinutes=60}},
            evaluation={costComplete=true,laborComplete=true,cashCopper=10001,valueCopper=10001,labor=10,
                byKey={['1:*:*']={key='1:*:*',item={itemType=1,name='木材'},demand=2,owned=0,shortage=2,craft=2,buy=0,price=25}}}}
        F.Commands.PlanSetRecipeCosts=function(_,key,labor,fee)saved={key,labor,fee};return true end
    end})
    local w=h.window;w.table:SetSelectedIndex(1)
    assert(w.status.text:find('旧',1,true),'selected price must disclose that it is stale')
    assert(w.summary.text:find('1金00银01铜',1,true),'the popup must not truncate copper from the total')
    local function Find(id,node)
        node=node or w.shell.root;if node.id==id then return node end
        for _,child in ipairs(node.children or {})do local found=Find(id,child);if found then return found end end
    end
    assert(Find('v3_craft_sidecar_manage'):Click())
    assert(w.selectedMaterial and w.selectedMaterial.itemKey=='1:*:*')
    w.manualLabor:SetValue('5',false);w.manualFee:SetValue('0',false);w.currentLabor:SetValue('20',false)
    assert(Find('v3_craft_sidecar_save_labor'):Click())
    assert(saved and saved[1]=='1:*:*' and saved[2]==5 and saved[3]==0)
    assert(Find('v3_craft_sidecar_manage'):Click())
    assert(w.laborStatus.text:find('足够',1,true) and w.laborStatus.state.tone=='success')
end)
Test('quantity editor follows the selected target in a multi-target plan',function()
    local edited
    local h=Boot(1,{configure=function(host,F)
        host.plan={activeId='p1',sessionRevision=1,name='组合计划',inventoryComplete=true,
            targets={{id='t1',key='1:*:*',itemType=1,count=2},{id='t2',key='2:*:*',itemType=2,count=4}},
            recipes={},choices={},allocations={},evaluation={byKey={
                ['1:*:*']={key='1:*:*',item={itemType=1,name='甲'},demand=2,owned=0,shortage=2,craft=2},
                ['2:*:*']={key='2:*:*',item={itemType=2,name='乙'},demand=4,owned=0,shortage=4,craft=4}}}}
        F.Commands.PlanSetQuantity=function(_,id,count)edited={id,count};return true end
    end})
    local w=h.window;w.table:SetSelectedIndex(2)
    assert(w.quantity.input:BeginEditing('target-two'));w.quantity.input.root.text='7'
    assert(w.quantity.apply:Click())
    assert(edited and edited[1]=='t2' and edited[2]==7,'changing the second target must not edit the first')
end)
Test('popup adds a saved target and compares routes without replacing the active plan',function()
    local added,applied,catalogAdded,chosen,cancelled
    local h=Boot(1,{configure=function(host,F)
        host.plan={activeId='p1',sessionRevision=1,revision=7,name='测试计划',inventoryComplete=true,
            libraryActiveId='11',libraryEntries={{value='11',text='木材'},{value='22',text='铁锭'}},
            catalog={{value='33:*:*',text='原木',item={itemType=33,name='原木'}}},
            plans={{value='p1',text='测试计划'}},
            targets={{id='t1',key='11:*:*',itemType=11,count=2}},choices={},
            recipeCatalog={['11:*:*']={recipeIds={'11','12'}}},recipes={['11']={product={count=1}},['12']={product={count=2}}},allocations={},
            evaluation={costComplete=true,laborComplete=true,cashCopper=60,valueCopper=60,labor=10,
                byKey={['11:*:*']={key='11:*:*',item={itemType=11,name='木材'},demand=2,owned=0,shortage=2,buy=0,craft=2}}}}
        F.Commands.PlanAppendSavedRecipe=function(_,id,count)added={id,count};return true end
        F.Commands.PlanAppendCatalogItem=function(_,key,count)catalogAdded={key,count};return true end
        F.Commands.PlanChooseRecipe=function(_,key,id)chosen={key,id};return true end
        F.Commands.PlanReadRecipes=function()return true end
        F.Commands.PlanCancel=function()cancelled=true;return true end
        F.Commands.PlanCompare=function()
            local raw={costComplete=true,laborComplete=true,cashCopper=60,combinedCopper=160,valueCopper=60,labor=10}
            local buy={costComplete=true,laborComplete=true,cashCopper=200,combinedCopper=200,valueCopper=200,labor=0}
            return true,{revision=7,result={manual=raw,raw=raw,buy=buy,recommendation={evaluation=raw,available=true}}}
        end
        F.Commands.PlanApplyRecommendation=function(_,revision,key)applied={revision,key};return true end
    end})
    local w=h.window
    local function Find(id,node)
        node=node or w.shell.root;if node.id==id then return node end
        for _,child in ipairs(node.children or {})do local found=Find(id,child);if found then return found end end
    end
    local function Click(suffix)return assert(Find('v3_craft_sidecar_'..suffix),'missing '..suffix):Click()end
    w.table:SetSelectedIndex(1);assert(Click('manage'))
    assert(w.materialRecipe:SetSelectedValue('12') and chosen[1]=='11:*:*' and chosen[2]=='12')
    assert(Click('cancel_work') and cancelled);assert(Click('manage'))
    assert(Click('add_target'));assert(w.addRecipe:SetSelectedValue('22'))
    assert(Click('confirm_target'));assert(added and added[1]=='22' and added[2]==1)
    assert(Click('add_target'));w.search:SetValue('原木',false);assert(Click('filter'))
    assert(#w.addRecipe.items==1 and w.addRecipe.items[1].value=='item:33:*:*',
        'search must filter both saved recipes and locally known items')
    assert(not Click('confirm_target'),'a hidden earlier selection must not be added after filtering')
    assert(w.addRecipe:SetSelectedValue('item:33:*:*'))
    assert(Click('confirm_target'));assert(catalogAdded and catalogAdded[1]=='33:*:*' and catalogAdded[2]==1)
    assert(Click('compare'))
    assert(w.compareText.text:find('原料',1,true) and w.compareText.text:find('成品',1,true),w.compareText.text)
    assert(w.compareText.text:find('含劳力',1,true) and w.compareText.text:find('1银60铜',1,true),w.compareText.text)
    assert(w.table.visibility=='collapsed','comparison should have room without squeezing the material list')
    assert(Click('apply_all') and applied[1]==7 and applied[2]==nil)
    assert(w.table.visibility=='visible','applying a comparison should restore the material list')
end)
print('CRAFT WINDOW RESULT '..passed..' passed / '..failed..' failed')
if failed>0 then os.exit(1)end

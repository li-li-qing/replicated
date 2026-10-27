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
    local nativeUiScale=options.nativeUiScale or 1
    dofile('ui/framework/rs_ui_forms.lua')
    S.PhysicalId=function(value)return tostring(value)end
    local function Augment(n)
        function n:GetOffset()return self.x,self.y end
        function n:GetExtent()return self.width,self.height end
        function n:GetEffectiveOffset()
            local p=self.parent;local x,y=0,0
            if type(p)=='table' and p.GetEffectiveOffset then x,y=p:GetEffectiveOffset()end
            return x+self.x*nativeUiScale,y+self.y*nativeUiScale
        end
        function n:GetEffectiveExtent()return self.width*nativeUiScale,self.height*nativeUiScale end
        function n:SetUILayer()return true end
        function n:SetCloseOnEscape()return true end
        function n:SetWindowModal()return true end
        function n:SetDrawPriority()return true end
        function n:Raise()return true end
        function n:EnableDrag()return true end
        function n:SetDragCondition()return true end
        function n:StartMoving()self.moving=true;return true end
        function n:StartSizing()self.moving=true;return true end
        function n:StopMovingOrSizing()self.moving=false;return true end
        function n:SetAlpha(value)self.alpha=value;return true end
        return n
    end
    UIParent=Augment(h.Native(nil,'UIParent',0,0,1280,768))
    for _,name in ipairs({'CreateEmptyWidget','CreatePanel','CreateButton','CreateLabel'})do
        local create,kind=UI[name],name
        UI[name]=function(...)local native=Augment(create(...));native.nativeFactory=kind;return native end
    end
    S.NativeObjectFactory={CreateWindow=function(_,id)return Augment(h.Native(UIParent,id,0,0,1,1))end}
    UI.ClaimNativeAuthority=function()return true end
    UI.InvalidateNativeState=function()return true end
    UI.SetAlpha=function(_,n,v)n.alpha=v;return true end
    UI.EnsureAlpha=function(_,n,v)n.alpha=v;return true,false end
    h.geometryLeases={}
    UI.BeginNativeGeometryLease=function(_,widget)h.geometryLeases[widget]=true;return true end
    UI.EndNativeGeometryLease=function(_,widget)h.geometryLeases[widget]=nil;return true end
    R.ApplyOpacityChannels=function()return true end
    R.ApplyFontScale=function()return true end
    R.WindowPreferences={GetTopmost=function()return false end,SetTopmost=function()return true end}
    dofile('data/rs_data_registry.lua');dofile('data/ids/rs_item_ids.lua');dofile('data/ids/rs_quest_ids.lua');dofile('core/rs_constants.lua')
    dofile('core/rs_layout.lua')
    S.Layout.GetContext=function()return {logicalWidth=1280,logicalHeight=768,usableWidth=1280,usableHeight=768,
        safeLeft=0,safeTop=0,safeRight=0,safeBottom=0,addonScale=scale,uiScale=nativeUiScale,effectiveScale=nativeUiScale}end
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
            safeLeft=0,safeTop=0,safeRight=0,safeBottom=0,addonScale=scale,uiScale=nativeUiScale,effectiveScale=nativeUiScale}end
    end
    return h
end

Test('get subrecipes is visible and clickable in the default compact view without overlapping other actions',function()
    for _,scale in ipairs({0.8,1,1.35})do
        local calls=0
        local h=Boot(scale,{configure=function(host,F)
            host.plan={activeId='p1',sessionRevision=1,targets={{id='t1',key='1:*:*',itemType=1,count=1}},recipes={},
                evaluation={rows={},byKey={}}}
            F.Commands.PlanReadRecipes=function()
                calls=calls+1;host.plan.scan={done=0,pending=2};return true,'正在获取子配方'
            end
        end})
        local w=h.window
        local function Find(id,node)
            node=node or w.shell.root;if node.id==id then return node end
            for _,child in ipairs(node.children or {})do local hit=Find(id,child);if hit then return hit end end
        end
        local button=assert(Find('v3_craft_sidecar_read_chain'),'default view must retain the get-subrecipes action')
        local recipeRow=Find('v3_craft_sidecar_recipe_row')
        assert(button.parentComponent==recipeRow and button:ParticipatesInLayout() and recipeRow:ParticipatesInLayout())
        assert(button.root.visible~=false and button.width>=80 and button.height>0 and button.enabled)
        assert(button.root:GetText()=='获取子配方')
        for _,component in ipairs(recipeRow.children)do
            if component:ParticipatesInLayout() then
                assert(component.x>=0 and component.x+component.width<=recipeRow.width+0.1,'top action must fit the compact row')
            end
        end
        local children={}
        for _,component in ipairs(recipeRow.children)do if component:ParticipatesInLayout() then children[#children+1]=component end end
        for i=1,#children-1 do assert(children[i].x+children[i].width<=children[i+1].x+0.1,'top actions must not overlap')end
        assert(Find('v3_craft_sidecar_controls').height<=66,'restoring the action must not add a new top row')
        assert(button.root.events.OnClick(button.root,'LeftButton') and calls==1,'Native click must reach the recipe-read command')
        assert(button.root:GetText()=='读取中' and not button.enabled)
        assert(not button:Click() and calls==1,'an active scan must not dispatch duplicate work')
        h.plan.scan=nil;w:Refresh()
        assert(button.enabled and button.root:GetText()=='获取子配方','completed scans must restore the visible action')
        assert(h.S.UIV3.CraftSidecar:Describe().recipeReadAction.visibility=='visible')
    end
end)
Test('get subrecipes stays visible while unavailable and reports a read failure without claiming to be running',function()
    local h=Boot(1,{configure=function(host,F)
        host.plan={activeId='p1',sessionRevision=1,targets={},recipes={},evaluation={rows={},byKey={}}}
        F.Commands.PlanReadRecipes=function()return false,'配方读取能力不可用' end
    end})
    local w=h.window
    assert(w.readChain and w.readChain.root.visible~=false and not w.readChain.enabled)
    h.plan.targets={{id='t1',key='1:*:*',itemType=1,count=1}};w:Refresh()
    assert(w.readChain:Click()==false and w.status.text:find('配方读取能力不可用',1,true))
    assert(w.readChain.enabled and w.readChain.root:GetText()=='获取子配方')
end)
Test('an own-share parse failure stays visible beside a selected material while reception remains armed',function()
    local h=Boot(1,{configure=function(host,uiFeature)
        local S=host.S
        dofile('core/rs_demand.lua');dofile('features/shared/rs_shared_bounds.lua');dofile('features/shared/rs_feature_slice_factory.lua')
        dofile('features/tools/craft/rs_craft_feature.lua');dofile('features/tools/craft/rs_craft_plan_domain.lua')
        dofile('features/tools/craft/rs_craft_plan_feature.lua')
        local F=S.Features.tools_craft;F.enabled=true;F.consumerCount=1
        F.ReadPlanRecipe=function()return {id='11',product={itemType=1,count=1,name='成品'},
            materials={{itemType=2,count=2,name='材料'}}}end
        F.ReadPlanRecipeTypes=nil
        assert(F.Commands:RecipeImportLink('|if11;成品|r',1))
        assert(F:ReconcileDemand(nil,{count=1},{count=1}))
        uiFeature.Commands=F.Commands;uiFeature.GetProjection=function()return F:GetProjection()end
        uiFeature.UpdateTopic=F.UpdateTopic;S.Features.tools_craft=uiFeature
    end})
    local w=h.window
    w.table:SetSelectedIndex(2)
    assert(h.feature.Commands:RecipeReceive(1,nil,'test-owner'))
    h.S.Events:Dispatch('CHAT_MESSAGE',1,0,'GearTest@World','|cf11;成品|r')
    assert(w.status.text:find('未识别配方分享',1,true),'selection details must not erase a receipt error in the same refresh')
    w:Refresh()
    assert(w.status.text:find('仍在等待下一条分享',1,true),'background refresh must retain an active receipt failure')
    assert(h.feature:GetProjection().plan.pendingShare)
    h.S.Events:Dispatch('CHAT_MESSAGE',1,0,'GearTest@World','|if11;成品|r |if2;材料|r')
    assert(not h.feature:GetProjection().plan.pendingShare)
    local receipt=h.feature:GetProjection().plan.importFeedback
    assert(w.status.text:find('已独立保存并打开',1,true),'successful reception must replace the failure feedback; actual='..tostring(w.status.text)..'; receipt='..tostring(receipt and receipt.message))
end)
Test('clicking get subrecipes runs the actual feature scan and refreshes newly discovered child rows',function()
    local h=Boot(1,{configure=function(host,uiFeature)
        local S=host.S
        dofile('core/rs_demand.lua');dofile('features/shared/rs_shared_bounds.lua');dofile('features/shared/rs_feature_slice_factory.lua')
        dofile('features/tools/craft/rs_craft_feature.lua');dofile('features/tools/craft/rs_craft_plan_domain.lua')
        dofile('features/tools/craft/rs_craft_plan_feature.lua')
        local F=S.Features.tools_craft;F.enabled=true;F.consumerCount=1
        local recipes={
            [11]={id='11',product={itemType=1,count=1,grade=0,name='成品'},
                materials={{itemType=2,count=2,grade=0,name='中间材料',recipeHint=12}}},
            [12]={id='12',product={itemType=2,count=1,grade=0,name='中间材料'},
                materials={{itemType=3,count=3,grade=0,name='下级原料'}}},
        }
        F.ReadPlanRecipe=function(_,id)return assert(recipes[id],'unexpected recipe identity')end
        F.ReadPlanRecipeTypes=nil -- 先模拟只接收到根配方，尚未自动读取子配方。
        assert(F.Commands:RecipeImportLink('|if11;成品|r',2))
        F.ReadPlanRecipeTypes=function(_,id)return id==1 and {11} or id==2 and {12} or {} end
        uiFeature.Commands=F.Commands;uiFeature.GetProjection=function()return F:GetProjection()end
        uiFeature.UpdateTopic=F.UpdateTopic;S.Features.tools_craft=uiFeature
    end})
    local w=h.window
    assert(w.table:GetItemCount()==2,'before reading there must be only the root and its direct material')
    assert(w.readChain.root.events.OnClick(w.readChain.root,'LeftButton'))
    assert(h.S.Scheduler:GetTaskState('tools_craft_plan_recipes').registered)
    assert(w.readChain.root:GetText()=='读取中' and not w.readChain.enabled)
    for _=1,20 do
        if not h.S.Scheduler:GetTaskState('tools_craft_plan_recipes').registered then break end
        h.S.Scheduler:RunTask('tools_craft_plan_recipes')
    end
    assert(w.table:GetItemCount()==3,'scan completion must publish newly discovered children to the visible list')
    assert(w.table:GetItem(2).need=='4' and w.table:GetItem(3).need=='预12','reading recipes must preserve the target quantity')
    assert(w.readChain.enabled and w.readChain.root:GetText()=='获取子配方')
    assert(h.S.UIV3.CraftSidecar:Describe().lastAction=='v3_craft_sidecar_read_chain')
end)
Test('material rows disclose a quality mismatch without presenting it as no listings',function()
    local h=Boot(1,{configure=function(host)
        local row={key='46156:0:*',item={itemType=46156,name='新月石晶'},demand=3,owned=0,shortage=3}
        host.plan={targets={{id='t1',key=row.key,itemType=46156,count=3}},recipes={},
            evaluation={rows={row},byKey={[row.key]=row}},
            quoteItems={['46156:0:*']={status='failed',code='strict_grade_mismatch',quoteGrade=2,reason='已读挂单品质与所需品质不符'}}}
    end})
    local w=h.window
    assert(w.table:GetItem(1).unitPrice=='品质不符')
    w.table:SetSelectedIndex(1)
    assert(w.status.text:find('查询品质 2',1,true) and w.status.text:find('已读挂单品质与所需品质不符',1,true))
end)
Test('a verified fixed-quality subrecipe is not described as an unknown product quality',function()
    local h=Boot(1,{configure=function(host)
        dofile('data/rs_craft_recipe_catalog.lua');dofile('features/tools/craft/rs_craft_plan_domain.lua')
        local row={key='46156:0:*',item={itemType=46156,name='新月石晶',grade=0},demand=3,owned=0,shortage=3}
        host.plan={targets={{id='t1',key=row.key,itemType=46156,count=3}},choices={[row.key]='11'},
            recipes={['11']={product={itemType=46156,count=5},materials={{itemType=8319,count=3,grade=0}}}},
            evaluation={rows={row},byKey={[row.key]=row}}}
    end})
    h.window.table:SetSelectedIndex(1)
    assert(not h.window.status.text:find('产物品质待核',1,true))
end)
Test('query button shows running state and stops prices without stopping recipe discovery',function()
    local cancelled=0
    local h=Boot(1,{configure=function(host,F)
        host.plan={evaluation={rows={{key='2:*:*',item={itemType=2,name='原木'},demand=3,owned=0,shortage=3}}},
            quote={status='querying',total=2,completed=1}}
        F.Commands.PlanCancelPrices=function()cancelled=cancelled+1;return true end
    end})
    local quote=h.window.quote
    assert(quote.root:GetText()=='查询中','native button must display the active query state')
    assert(quote:Click() and cancelled==1,'clicking the running button must cancel only price work')
end)
Test('all-material price action is visible beside quantity in the compact window',function()
    local submitted=0
    local h=Boot(1,{configure=function(_,F)
        F.Commands.PlanCalibrate=function(_,key)assert(key==nil);submitted=submitted+1;return true end
    end})
    local w=h.window;local button=w.quote
    assert(button.root:GetText()=='获取全部价格')
    assert(button.parent==w.quantity.parent,'the price action must share the quantity row')
    assert(button:ParticipatesInLayout() and button.root.visible~=false)
    assert(button.x>=0 and button.x+button.width<=button.parent.width+0.1,'price action must fit the compact row')
    assert(button.root.events.OnClick(button.root,'LeftButton') and submitted==1)
end)
Test('selected recipe labor can be saved without an invented fee or opening management',function()
    local saved
    local h=Boot(1,{configure=function(host,F)
        host.plan={activeId='p1',sessionRevision=1,targets={{id='t1',key='1:*:*',itemType=1,count=2}},
            choices={['1:*:*']='1'},recipes={['1']={product={itemType=1,count=1},materials={}}},
            evaluation={byKey={['1:*:*']={item={itemType=1,name='木材'},demand=2,owned=0,shortage=2,craft=2}}}}
        F.Commands.PlanSetRecipeCosts=function(_,key,labor,fee)saved={key=key,labor=labor,fee=fee};return true end
    end})
    local w=h.window;w.table:SetSelectedIndex(1)
    assert(w.manualLabor:ParticipatesInLayout() and w.manualLabor.parent.visibility~='collapsed','manual labor must be accessible')
    w.manualLabor:SetValue('5',false);w.manualFee:SetValue('',false)
    local function Find(node)
        if node.id=='v3_craft_sidecar_save_labor' then return node end
        for _,child in ipairs(node.children or {})do local found=Find(child);if found then return found end end
    end
    assert(Find(w.shell.root):Click())
    assert(saved and saved.labor==5 and saved.fee==nil,'unknown fee must stay unknown')
end)
Test('summary shows the known total and missing-price coverage without presenting it as a complete cost',function()
    local h=Boot(1,{configure=function(host)
        host.plan={evaluation={rows={{key='1:*:*',item={itemType=1,name='材料'},demand=2,owned=0,shortage=2}},
            cashCopper=12345,materialCopper=12000,feeCopper=345,feeComplete=false,labor=5,laborComplete=false,
            missingPrices={'4:*:*'},purchaseCount=2,pricedPurchaseCount=1}}
    end})
    h.S.RSUI:FlushLayoutQueue()
    local lines={};for _,label in ipairs(h.window.summary.lineLabels or {})do
        if label.visible~=false then lines[#lines+1]=label:GetText() end
    end
    local text=table.concat(lines,'\n')
    assert(text:find('已知合计 1金23银45铜',1,true),text)
    assert(text:find('缺价 1项未计入',1,true) and text:find('有价 1/2',1,true),text)
    assert(text:find('待填',1,true),text)
end)
Test('material header separators resize adjacent columns',function()
    local h=Boot(1,{saved={width=600,height=650,locked=false}})
    local view=h.window.table
    local record=assert(view.columnResizeHandles[1],'the material column divider must accept input')
    local before=view.resolvedWidths[1]
    assert(record.root.events.OnDragStart());record.root.x=record.root.x+20
    assert(record.root.events.OnDragStop())
    assert(view.resolvedWidths[1]>before+10,'a header drag must change visible material column width')
end)
Test('compact workflow keeps two top rows and settings never expands the popup',function()
    local route
    local h=Boot(1,{configure=function(host)
        host.S.UIV3.shell={Navigate=function(_,value)route=value;return true end}
    end})
    local w=h.window
    local function Find(id,node)
        node=node or w.shell.root;if node.id==id then return node end
        for _,child in ipairs(node.children or {})do local hit=Find(id,child);if hit then return hit end end
    end
    local top=Find('v3_craft_sidecar_controls')
    assert(top.height<=66,'recipe, quantity and query must fit in two rows')
    local before=w.table.height
    assert(Find('v3_craft_sidecar_settings'):Click() and route=='tools.craft_assist')
    assert(w.table.height==before,'advanced settings must not insert extra rows into the material viewport')
    assert(w.table.y==0,'the list must start at the top of its split pane')
end)
Test('dragging the divider adjusts the material viewport',function()
    local stored=170;local reject=false
    local function Configure(_,F)
        F.GetCraftListSplit=function()return stored end
        F.Commands.SetCraftListSplit=function(_,value)if reject then return false,'injected failure' end;stored=value;return true end
    end
    local h=Boot(1,{saved={width=500,height=650,locked=false},configure=Configure});local w=h.window
    local split=w.bodySplit;local handle=assert(split.dividerDrag)
    assert(handle.nativeFactory=='CreateButton','the client drag surface must use the same native Button kind as the screen handle')
    local before=w.table.height
    assert(split.dragEvidence.raises>0 and split.dragEvidence.handlers,'divider must be raised and have drag handlers')
    assert(handle.events.OnDragStart());handle.y=handle.y+55;assert(handle.events.OnDragStop())
    local diagnostics=h.S.UIV3.CraftSidecar:Describe().divider
    assert(diagnostics.starts==1 and diagnostics.stops==1 and diagnostics.delta==55 and diagnostics.status=='stopped')
    assert(w.table.height>before+40,'dragging down must enlarge the material list above the divider')
    local restored=Boot(1,{saved={width=500,height=650,locked=false},configure=Configure})
    assert(math.abs(restored.window.bodySplit.primarySize-stored)<1,'divider position must survive cold reload')
    reject=true
    assert(handle.events.OnDragStart());handle.y=handle.y-30;assert(not handle.events.OnDragStop())
    assert(math.abs(split.primarySize-stored)<1,'rejected save must restore the last saved divider position')
    reject=false
    assert(handle.events.OnDragStart());handle.y=handle.y-55;assert(handle.events.OnDragStop())
    assert(w.table.height>=before-1,'dragging up must restore the material list')
end)
Test('divider motion uses the same logical distance at native UI scale 0.8',function()
    local h=Boot(1,{nativeUiScale=0.8,saved={width=500,height=650,locked=false}})
    local split=h.window.bodySplit;local handle=split.dividerDrag
    local before=split:ResolvePrimary(split.height)
    assert(handle.events.OnDragStart());handle.y=handle.y+50;assert(handle.events.OnDragStop())
    local after=split:ResolvePrimary(split.height)
    assert(math.abs(after-before-50)<0.01,'50 logical units must not become 40 at UI scale 0.8: '..tostring(after-before))
    assert(not h.geometryLeases[handle],'the completed gesture must release geometry ownership')
end)
Test('window resize persists the visible material split together with the window',function()
    local stored=170
    local function Configure(_,F)
        F.GetCraftListSplit=function()return stored end
        local save=F.Commands.SetCraftWindowState
        F.Commands.SetCraftWindowState=function(self,value,primary)
            local ok,why=save(self,value)
            if ok and primary then stored=primary end
            return ok,why
        end
    end
    local h=Boot(1,{saved={width=500,height=650,locked=false},configure=Configure})
    local w=h.window;local handle=w.windowController.handles.bottom_right
    assert(handle.events.OnDragStart());w.shell.window.height=720;assert(handle.events.OnDragStop())
    local visibleHeight=w.table.height
    local reload=Boot(1,{saved=h.saved(),configure=Configure})
    assert(math.abs(reload.window.table.height-visibleHeight)<1,'cold reload must preserve the resized list height')
end)
Test('closing during divider drag cancels capture and ignores a late stop',function()
    local commits=0
    local h=Boot(1,{configure=function(_,F)
        F.Commands.SetCraftListSplit=function()commits=commits+1;return true end
    end})
    local w=h.window;local split=w.bodySplit;local handle=split.dividerDrag
    assert(handle.events.OnDragStart())
    local _,accepted=split:SetVisibility(true);assert(accepted and split.dragging,'reapplying visible state must not cancel a gesture')
    handle.y=handle.y+40
    assert(w:Hide())
    assert(not split.dragging and not handle.moving,'hiding must stop native motion')
    assert(h.S.Scheduler:GetTaskState(split.dragTaskName).registered==false,'hiding must stop drag work')
    assert(not h.geometryLeases[handle],'hiding must release the geometry lease')
    assert(handle.events.OnDragStop());assert(commits==0,'a late stop must not save a cancelled gesture')
end)
Test('a rejected native move releases its lease without saving',function()
    local saves=0
    local h=Boot(1,{configure=function(_,F)F.Commands.SetCraftListSplit=function()saves=saves+1;return true end end})
    local split=h.window.bodySplit;local handle=split.dividerDrag
    local original=h.S.UI.TryInteractionCall
    h.S.UI.TryInteractionCall=function(self,widget,method,...)
        if widget==handle and method=='StartMoving' then return false,'native move rejected' end
        return original(self,widget,method,...)
    end
    assert(not handle.events.OnDragStart())
    assert(not split.dragging and not h.geometryLeases[handle])
    assert(not h.S.Scheduler:GetTaskState(split.dragTaskName).registered)
    assert(handle.events.OnDragStop() and saves==0)
end)
Test('workflow controls bind explanations to the shared tooltip service',function()
    local bound={}
    local h=Boot(1,{configure=function(host)
        host.S.RSUI.Tooltip={Bind=function(_,target,spec)
            bound[target.id]=spec.text or spec.provider;return true
        end}
    end})
    assert(bound.v3_craft_sidecar_add_plan and bound.v3_craft_sidecar_search_auction)
    assert(bound.v3_craft_sidecar_quantity_input and bound.v3_craft_sidecar_quantity_apply)
    assert(bound.v3_craft_sidecar_split_divider_drag and bound.v3_craft_sidecar_buy and bound.v3_craft_sidecar_craft)
end)
Test('native hover invokes the shared tooltip without disabling the button',function()
    local shown
    SetTooltip=function(text,target)shown={text=text,target=target}end
    local h=Boot(1,{configure=function()dofile('ui/framework/rs_ui_interactions.lua')end})
    local function Find(id,node)
        if node.id==id then return node end
        for _,child in ipairs(node.children or {})do local hit=Find(id,child);if hit then return hit end end
    end
    local btn=assert(Find('v3_craft_sidecar_manage',h.window.shell.root))
    assert(btn.root.events.OnEnter and btn.root.events.OnLeave)
    assert(btn.root.events.OnEnter() and shown and shown.text:find('管理',1,true))
    assert(btn.root.events.OnLeave() and btn:Click())
    SetTooltip=nil
end)
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

Test('resize grows the material list and survives close and cold reload',function()
    local h=Boot(1);local w=h.window;local frame=w.shell.window
    assert(frame.width==360 and frame.height==430,'new windows retain the compact default')
    local oldWidth,oldHeight=w.table.width,w.table.height
    local handle=assert(w.windowController.handles.bottom_right,'resize corner must be available')
    assert(handle.events.OnDragStart())
    frame.width,frame.height=580,620
    assert(handle.events.OnDragStop())
    assert(h.saved().width==580 and h.saved().height==620,'resized dimensions must be persisted')
    assert(w.table.width>oldWidth and w.table.height>oldHeight,'material list must use expanded space')
    h.failWindowSave=true
    assert(handle.events.OnDragStart());frame.width,frame.height=700,650
    assert(not handle.events.OnDragStop(),'failed size save must be reported')
    assert(frame.width==580 and frame.height==620 and h.saved().width==580,'rejected size must roll back')
    h.failWindowSave=false
    assert(w:Hide());assert(h.S.UIV3.CraftSidecar:OpenManual())
    assert(frame.width==580 and frame.height==620,'reopen must retain resized dimensions')
    local fresh=Boot(1,{saved=h.saved()})
    assert(fresh.window.shell.window.width==580 and fresh.window.shell.window.height==620,'cold reload must restore size')
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
    assert(w.table:GetItem(3).preview==true and w.table:GetItem(3).need=='预24',
        'preview scales the hypothetical ingredient amount without counting it as a purchase')
    h.plan.evaluation.byKey['2:*:*'].demand=9;assert(w:Refresh())
    assert(w.table:GetItem(3).need=='预36','preview quantities must follow changed parent demand')
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
Test('unresolved child recipes remain visible and actionable even for preview rows',function()
    local h=Boot(1,{configure=function(host)
        host.plan={activeId='p1',sessionRevision=1,name='赤石配方',inventoryComplete=true,
            targets={{id='t1',key='44773:*:*',itemType=44773,count=1}},
            choices={['44773:*:*']='10280'},
            recipeCatalog={['43483:0:*']={status='recipe_fields_unknown'}},
            recipes={['10280']={product={itemType=44773,count=1},materials={
                {itemType=43483,grade=0,count=1,name='深邃的新月赤石'},
                {itemType=46156,grade=0,count=30,name='新月石晶'},
                {itemType=8319,grade=0,count=30,name='合金锭'}}}},
            evaluation={byKey={['44773:*:*']={key='44773:*:*',item={itemType=44773,name='秀丽的新月赤石'},
                demand=1,owned=1,shortage=0,craft=0}}}}
    end})
    local w=h.window
    assert(w.table:GetItemCount()==4,'all three direct materials must remain visible when the target is owned')
    assert(w.table:GetItem(2).name:find('?',1,true),'unresolved preview must be marked')
    w.table:SetSelectedIndex(2)
    assert(w.status.text:find('下级',1,true) and w.status.text:find('重读',1,true),w.status.text)
end)
Test('previewed subrecipe with unknown output grade discloses the cost limitation',function()
    local h=Boot(1,{configure=function(host)
        host.plan={activeId='p1',sessionRevision=1,inventoryComplete=true,
            targets={{id='t1',key='44773:*:*',itemType=44773,count=1}},
            choices={['44773:*:*']='10280',['43483:0:*']='10266'},
            recipes={['10280']={materials={{itemType=43483,grade=0,count=1,name='深邃赤石'}}},
                ['10266']={product={itemType=43483,count=1},materials={{itemType=43476,grade=0,count=1,name='原料'}}}},
            evaluation={byKey={['44773:*:*']={item={itemType=44773,name='赤石'},demand=1,owned=0,shortage=1,craft=1,batches=1},
                ['43483:0:*']={item={itemType=43483,grade=0,name='深邃赤石'},demand=1,owned=0,shortage=1,buy=1,craft=0}}}}
    end})
    local w=h.window;assert(w.table:GetItemCount()==3,'unverified product quality must not hide submaterials')
    w.table:SetSelectedIndex(2)
    assert(w.status.text:find('产物品质待核',1,true),w.status.text)
end)
Test('material row click collapses and expands its own nested branch while retaining selection',function()
    local h=Boot(1,{configure=function(host)
        host.plan={activeId='p1',sessionRevision=1,inventoryComplete=true,
            targets={{id='t1',key='1:*:*',itemType=1,count=1}},choices={['1:*:*']='1',['2:*:*']='2'},
            recipes={['1']={product={itemType=1,count=1},materials={{itemType=2,count=1,name='子配方'},{itemType=4,count=1,name='其他材料'}}},
                ['2']={product={itemType=2,count=1},materials={{itemType=3,count=2,name='下级材料'}}}},
            evaluation={byKey={['1:*:*']={item={itemType=1,name='目标'},demand=1,owned=0,shortage=1,craft=1,batches=1},
                ['2:*:*']={item={itemType=2,name='子配方'},demand=1,owned=0,shortage=1,buy=1,craft=0},
                ['4:*:*']={item={itemType=4,name='其他材料'},demand=1,owned=0,shortage=1,buy=1,craft=0}}}}
    end})
    local w=h.window;local list=w.table:GetListView()
    local function ClickRow(index)
        local row=assert(list:GetRowForIndex(index));local handler=assert(row.root.events.OnClick)
        return handler(row.root,'LeftButton')
    end
    assert(w.table:GetItemCount()==4)
    assert(w.table:GetItem(2).name:find('[-]',1,true),'expanded branches must have a visible marker')
    assert(ClickRow(2));assert(w.table:GetItemCount()==3,'click must collapse the chosen branch')
    assert(w.table:GetItem(2).name:find('[+]',1,true),'collapsed branches must have a visible marker')
    assert(list:GetRowForIndex(2).cells[1].root:GetText():find('[+]',1,true),'the native row must show the collapsed marker')
    assert(w.selectedMaterial and w.selectedMaterial.itemKey=='2:*:*','collapse must retain the selected material')
    assert(ClickRow(2));assert(w.table:GetItemCount()==4,'second click must expand it again')
    assert(w.selectedMaterial and w.selectedMaterial.itemKey=='2:*:*')
end)
Test('collapsing a scrolled branch preserves its identity and can reopen it',function()
    local h=Boot(1,{configure=function(host)
        local materials,choices,recipes={}, {['1:*:*']='1'}, {}
        for i=2,16 do
            materials[#materials+1]={itemType=i,count=1,name='材料'..i}
            choices[i..':*:*']=tostring(i)
            recipes[tostring(i)]={product={itemType=i,count=1},materials={{itemType=100+i,count=1,name='下级'..i}}}
        end
        recipes['1']={product={itemType=1,count=1},materials=materials}
        host.plan={activeId='p1',sessionRevision=1,targets={{id='t1',key='1:*:*',itemType=1,count=1}},
            choices=choices,recipes=recipes,inventoryComplete=true,
            evaluation={byKey={['1:*:*']={item={itemType=1,name='目标'},demand=1,owned=0,shortage=1,craft=1,batches=1}}}}
    end})
    local w=h.window;local list=w.table:GetListView();local key=w.table:GetItem(20).key
    w.table:ScrollToIndex(20);assert(list:HandleRowClick(20));assert(w.selectedMaterial and w.selectedMaterial.key==key)
    local index=w.table:GetSelectedIndex();assert(index and w.table:GetItem(index).key==key)
    assert(list:HandleRowClick(index));assert(w.selectedMaterial and w.selectedMaterial.key==key)
    assert(w.table:GetItemCount()==31,'reopening must restore the collapsed child')
end)
Test('each row displays per-batch labor and cached unit price without inventing unknown values',function()
    local h=Boot(1,{configure=function(host)
        host.plan={activeId='p1',sessionRevision=1,inventoryComplete=true,
            targets={{id='t1',key='1:*:*',itemType=1,count=1}},choices={['1:*:*']='1',['2:*:*']='2'},
            recipes={['1']={product={itemType=1,count=1},labor=5,materials={{itemType=2,count=3,name='木材'}}},
                ['2']={product={itemType=2,count=1},labor=8,materials={{itemType=3,count=2,name='原木'}}}},
            prices={['2:*:*']={price=123,freshness='stale'}},
            evaluation={byKey={['1:*:*']={item={itemType=1,name='目标'},demand=1,owned=0,shortage=1,craft=1,batches=1},
                ['2:*:*']={item={itemType=2,name='木材'},demand=3,owned=0,shortage=3,buy=3,craft=0}}}}
    end})
    local w=h.window;assert(w.table:GetItem(1).labor=='5/次')
    assert(w.table:GetItem(2).labor=='8/次' and w.table:GetItem(2).unitPrice=='~1银23铜')
    assert(w.table:GetItem(3).labor=='—' and w.table:GetItem(3).unitPrice=='—')
    local widths=w.table:GetResolvedColumns();local total=0
    for _,column in ipairs(widths)do assert(column.width>0);total=total+column.width end
    assert(#widths==6 and total<=w.table.width+1,'all six columns must fit the default popup')
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
    assert(w.quantity.input:BeginEditing('quantity_blur'));w.quantity.input.root.text='3'
    h.S.UI.focused=nil
    assert(w.quantity.input.root.events.OnLostFocus())
    assert(w.table:GetItem(2).need=='9' and w.summary.text:find('15',1,true),
        'leaving the quantity input must recalculate visible materials and labor')
    local visibleRow=assert(w.table:GetListView():GetRowForIndex(2))
    assert(visibleRow.cells[2].text=='9' and visibleRow.cells[2].root:GetText()=='9',
        'the native label must update, not merely the backing item')
    local rendered=h.S.UIV3.CraftSidecar:Describe().render
    assert(rendered.rows[2].need=='9' and rendered.rows[2].visibleNeed=='9','diagnostics must expose model and visible row values')
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
    assert(w.table:GetItem(2).shortage=='5')
end)
Test('live-shaped recipe fields recalculate native visible quantities from one to ten',function()
    local h=Boot(1,{configure=function(host,uiFeature)
        local S=host.S
        dofile('core/rs_demand.lua');dofile('features/shared/rs_shared_bounds.lua');dofile('features/shared/rs_feature_slice_factory.lua')
        dofile('features/tools/craft/rs_craft_feature.lua');dofile('features/tools/craft/rs_craft_plan_domain.lua')
        dofile('features/tools/craft/rs_craft_plan_feature.lua')
        local F=S.Features.tools_craft;F.enabled=true;F.consumerCount=1
        local original=S.Api.CallCapability
        S.Api.CallCapability=function(self,capability,object,method,id,...)
            if capability=='X2Craft:GetCraftProductInfo' then
                return true,{{itemType=id==10280 and 44773 or 43483,amount=1,item_name='测试赤石',useGrade=false,productGrade=0}}
            elseif capability=='X2Craft:GetCraftMaterialInfo' then
                if id==10280 then return true,{
                    {amount=1,count=200,mainGrade=false,item_info={itemType=43483,itemGrade=0,item_name='深邃赤石'}},
                    {amount=30,count=200,mainGrade=false,item_info={itemType=46156,itemGrade=0,item_name='新月石晶'}},
                    {amount=30,count=200,mainGrade=false,item_info={itemType=8319,itemGrade=0,item_name='合金锭'}}}end
                return true,{{amount=1,count=200,mainGrade=false,item_info={itemType=43476,itemGrade=0,item_name='下级赤石'}}}
            elseif capability=='X2Craft:GetCraftTypeByItemType' then
                return true,id==44773 and {10280} or id==43483 and {10266} or {}
            end
            return original(self,capability,object,method,id,...)
        end
        assert(F.Commands:RecipeImportLink('|if10280;秀丽的新月赤石|r',1))
        for _=1,20 do
            if not S.Scheduler:GetTaskState('tools_craft_plan_recipes').registered then break end
            S.Scheduler:RunTask('tools_craft_plan_recipes')
        end
        uiFeature.Commands=F.Commands;uiFeature.GetProjection=function()return F:GetProjection()end;S.Features.tools_craft=uiFeature
    end})
    local w=h.window
    assert(w.table:GetItemCount()==5,'root, three materials and a preview must be present')
    assert(w.table:GetListView():GetRowForIndex(2).cells[2].root:GetText()=='1')
    assert(w.quantity.input:BeginEditing('ten_items'));w.quantity.input.root.text='10';assert(w.quantity.apply:Click())
    local list=w.table:GetListView()
    assert(list:GetRowForIndex(1).cells[2].root:GetText()=='10')
    assert(list:GetRowForIndex(2).cells[2].root:GetText()=='10')
    assert(list:GetRowForIndex(3).cells[2].root:GetText()=='预10')
    w.table:ScrollToIndex(5)
    assert(list:GetRowForIndex(5).cells[2].root:GetText()=='300','a scrolled material must also bind the new quantity')
    w.table:ScrollToIndex(2);w.table:SetSelectedIndex(2)
    assert(w.status.text:find('产物品质待核',1,true),w.status.text)
end)

Test('management mode keeps a selectable material list without moving the compact window',function()
    local h=Boot(1);local w=h.window;local frame=w.shell.window
    local function Find(id,node)
        node=node or w.shell.root;if node.id==id then return node end
        for _,child in ipairs(node.children or {})do local found=Find(id,child);if found then return found end end
    end
    assert(Find('v3_craft_sidecar_tree_actions').visibility=='collapsed','default view should prioritize material space')
    assert(Find('v3_craft_sidecar_manage'):Click())
    h.S.RSUI:FlushLayoutQueue()
    assert(w.table.visibility=='visible' and w.table.height>=53,'management must retain at least one selectable material row: '..tostring(w.table.height))
    w.table:SetSelectedIndex(1);assert(w.selectedMaterial,'a material must be selectable while management controls are visible')
    w.planIdentity='previous-plan';w:Refresh()
    assert(w.table.visibility=='visible','changing plan in management mode must keep the list visible')
    assert(Find('v3_craft_sidecar_manage').text=='返回材料','management mode needs a visible exit to the material list')
    assert(Find('v3_craft_sidecar_tree_actions').visibility=='visible','advanced recipe actions remain available in management')
    assert(w.manualLabor:ParticipatesInLayout() and w.shareInput:ParticipatesInLayout())
    assert(frame.width==360 and frame.height==430)
    assert(Find('v3_craft_sidecar_manage'):Click())
    h.S.RSUI:FlushLayoutQueue()
    assert(w.table.visibility=='visible' and w.table.height>=81)
end)
Test('switching popup modes keeps visible rows separated and actionable',function()
    local h=Boot(1);local w=h.window
    local function Find(id,node)
        node=node or w.shell.root;if node.id==id then return node end
        for _,child in ipairs(node.children or {})do local found=Find(id,child);if found then return found end end
    end
    local function Check()
        h.S.RSUI:FlushLayoutQueue()
        local root=assert(Find('v3_craft_sidecar_controls'));local previous;local count=0
        for _,node in ipairs(root.children)do
            if node.visibility~='collapsed' and node.visible~=false and type(node.y)=='number' and type(node.height)=='number' then
                if previous then assert(node.y>=previous.y+previous.height-0.1,
                    previous.id..' overlaps '..node.id)end
                assert(node.y+node.height<=root.height+0.1,node.id..' extends outside controls y='..tostring(node.y)..' height='..tostring(node.height)..' root='..tostring(root.height)..' split='..tostring(w.bodySplit.height)..' minimum='..tostring(w.bodySplit.minPrimary))
                previous=node;count=count+1
            end
        end
        assert(count>=2,'the two compact workflow rows must have layout geometry')
    end
    Check();assert(Find('v3_craft_sidecar_manage'):Click());Check()
    assert(Find('v3_craft_sidecar_add_target'):Click());Check()
    assert(Find('v3_craft_sidecar_manage'):Click());Check()
    assert(Find('v3_craft_sidecar_manage'):Click());Check()
end)
Test('native click reports why an unavailable expansion cannot run',function()
    local h=Boot(1);local w=h.window
    local function Find(id,node)
        node=node or w.shell.root;if node.id==id then return node end
        for _,child in ipairs(node.children or {})do local found=Find(id,child);if found then return found end end
    end
    w.table:SetSelectedIndex(1)
    local expand=assert(Find('v3_craft_sidecar_expand'))
    assert(type(expand.root.events.OnClick)=='function','test must call the native handler')
    assert(not expand.root.events.OnClick(expand.root,'LeftButton'))
    assert(w.status.text:find('暂无可展开',1,true),w.status.text)
    local evidence=h.S.UIV3.CraftSidecar:Describe()
    assert(evidence.lastAction=='v3_craft_sidecar_expand' and evidence.lastActionResult=='rejected',
        'diagnostics must distinguish a handled rejection from a click that never reached the callback')
    local manage=assert(Find('v3_craft_sidecar_manage'))
    assert(manage.root.events.OnClick(manage.root,'LeftButton') and manage.text=='返回材料')
    assert(manage.root.events.OnClick(manage.root,'LeftButton') and w.table.visibility=='visible')
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
Test('an unavailable plan never substitutes the trade specialty recipe list',function()
    local unavailable=true
    local h=Boot(1,{configure=function(_,F)
        F.GetProjection=function()return {plan=unavailable and {status='unavailable',error='存档暂不可用',targets={},rows={}}
                or {status='ready',activeId='p1',sessionRevision=1,libraryEntries={},targets={},recipes={},evaluation={byKey={},rows={}}},
            recipeOptions={{value='trade_1',text='测试特产'}}}end
    end})
    assert(#h.window.recipe.items==0 and #h.window.addRecipe.items==0,
        'the crafting library cannot silently fall back to trade recipes')
    assert(h.window.status.text:find('存档暂不可用',1,true),'the real read failure must be visible')
    unavailable=false;assert(h.window:Refresh())
    assert(not h.window.status.text:find('存档暂不可用',1,true),'recovery must clear the old read failure')
end)
Test('a fenced plan explains why reception is blocked and retains diagnostic detail',function()
    local h=Boot(1,{configure=function(_,F)
        F.GetProjection=function()return {plan={status='unavailable',error='integrity_failed:fingerprint_mismatch',targets={},rows={}}}end
        F.Commands.PlanReceiveShare=function()return false,'integrity_failed:fingerprint_mismatch' end
        F.Commands.RecipeReceive=F.Commands.PlanReceiveShare
    end})
    local w=h.window
    assert(w.status.text:find('存档损坏',1,true) and w.status.text:find('保护',1,true))
    local function Find(node)
        if node.id=='v3_craft_sidecar_add_plan' then return node end
        for _,child in ipairs(node.children or {})do local hit=Find(child);if hit then return hit end end
    end
    assert(not Find(w.shell.root):Click())
    assert(w.status.text:find('存档损坏',1,true),'a failed receive must explain the fence in the window')
    local d=h.S.UIV3.CraftSidecar:Describe()
    assert(d.lastActionResult=='rejected' and d.lastActionError:find('integrity_failed',1,true))
    assert(w:Refresh() and w.status.text:find('存档损坏',1,true),'refresh must retain a clear failure explanation')
end)
Test('only eligible damaged plans expose an explicit reset action',function()
    local reset=false
    local h=Boot(1,{configure=function(host,F)
        host.plan={status='unavailable',error='integrity_failed:fingerprint_mismatch',canResetCorrupt=true,targets={},rows={}}
        F.Commands.PlanResetCorrupt=function()
            reset=true;host.plan={status='ready',activeId='p1',sessionRevision=1,targets={},plans={},recipes={},evaluation={byKey={},rows={}}}
            return true,'已清空损坏计划'
        end
    end})
    local function Find(id,node)
        if node.id==id then return node end
        for _,child in ipairs(node.children or {})do local hit=Find(id,child);if hit then return hit end end
    end
    local row=Find('v3_craft_sidecar_reset_row',h.window.shell.root)
    local button=Find('v3_craft_sidecar_reset_corrupt',h.window.shell.root)
    assert(row:ParticipatesInLayout() and button:Click() and reset)
    assert(not row:ParticipatesInLayout(),'healthy plan must not expose the destructive reset action')
end)
Test('a missing plan cannot display materials from an old trade context',function()
    local h=Boot(1,{configure=function(_,F)
        F.GetProjection=function()return {recipeOptions={{value='trade',text='某地特产'}},
            craft={recipes={{craftType=77,materials={items={{itemType=22,name='特产旧材料',count=2}}}}}}}end
    end})
    assert(#h.window.recipe.items==0 and h.window.table:GetItemCount()==0,
        'the floating craft plan must not render stale trade recipe data')
    assert(h.window.status.text:find('计划',1,true),'a missing plan must be explained')
end)
print('CRAFT WINDOW RESULT '..passed..' passed / '..failed..' failed')
if failed>0 then os.exit(1)end

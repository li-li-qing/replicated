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
    local received,receivedMaterial,opened,deleted
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
        C.RecipeReceive=function()received=true;return true end
        C.RecipeReceiveMaterial=function(_,key)receivedMaterial=key;return true end
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
    assert(Click('add_plan') and received)
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
print('CRAFT WINDOW RESULT '..passed..' passed / '..failed..' failed')
if failed>0 then os.exit(1)end

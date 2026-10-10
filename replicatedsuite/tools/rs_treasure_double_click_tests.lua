-- 真实RSUI行按钮、选择、页面和共用助手内容；Native与Feature地图动作仅为边界模型。
local NewHost=dofile('tools/rs_workspace_home_test_host.lua')
local passed=0
local function Test(name,fn)fn();passed=passed+1;print('PASS treasure-click '..name)end
local function Boot()
    local S,_,_,_,_,h=NewHost({visible={},enabled={life_treasure=true},skipLayout=true})
    local f=S.Features.Treasure
    local state={maps={{key='a',name='藏宝图甲',text='坐标甲'},{key='b',name='藏宝图乙',text='坐标乙'}},revision=1,opens=0}
    f.Commands.Refresh=function()return true end
    f.Commands.Select=function(_,key)
        state.selects=(state.selects or 0)+1
        if state.rejectSelect then return false,'选择保存失败' end
        for _,row in ipairs(state.maps)do if row.key==key then state.selected=row;state.revision=state.revision+1;return true end end
        return false,'藏宝图已失效'
    end
    f.Commands.ShowSelectedOnMap=function()
        if not state.selected then return false,'没有选择' end
        if state.rejectMap then state.lastMapActionError='地图能力暂不可用';return false,state.lastMapActionError end
        state.opens=state.opens+1;state.opened=state.selected.key;state.lastMapActionError=nil;return true
    end
    function f:GetProjection()return {maps=state.maps,selected=state.selected,revision=state.revision,status='ready',lastMapActionError=state.lastMapActionError}end
    dofile('presentation/v3/shell/rs_v3_page_host.lua')
    dofile('presentation/v3/pages/rs_v3_life_m16_pages.lua')
    local parent=h.Native(nil,'treasure_click_parent',0,0,850,700)
    local page=assert(S.UIV3.PageHost.factories['life.treasure'](parent,'life.treasure'))
    assert(page:OnActivated());page:Layout(0,0,850,700)
    local content=assert(S.UIV3.LifeEconomyContent:Create(parent,'Treasure','test_treasure_'))
    assert(content:Refresh());content.content:Layout(0,0,470,310)
    local function Click(view,index,ms)
        h.ms=ms;local row=assert(view.list:GetRowForIndex(index));local button=assert(row.root.events.OnClick,'real row button handler absent')
        return button(row.root,'LeftButton')
    end
    local function Find(root,id)
        if root.id==id then return root end
        for _,child in ipairs(root.children or {})do local found=Find(child,id);if found then return found end end
    end
    return S,h,state,page,content,Click,Find
end
Test('main menu single click selects and double click opens the same map exactly once',function()
    local S,h,state,page,content,Click=Boot()
    Click(page.tableView,1,1000);assert(state.selected.key=='a' and state.opens==0 and state.selects==1)
    Click(page.tableView,1,1250);assert(state.opens==1 and state.opened=='a' and state.selects==2,'main menu double click did not open map or duplicated selection writes')
    Click(page.tableView,1,1300);assert(state.opens==1,'third click reopened map')
end)
Test('assistant has a visible hint and also requires a genuine double click',function()
    local S,h,state,page,content,Click=Boot()
    assert(content.treasureInteractionHint and content.treasureInteractionHint.text:find('双击藏宝图',1,true),'assistant instruction missing')
    assert(content.treasureInteractionHint.height>=18,'assistant hint has no readable slot')
    Click(content.table,2,1000);assert(state.selected.key=='b' and state.opens==0,'single assistant click opened map')
    Click(content.table,2,1450);assert(state.opens==1 and state.opened=='b')
end)
Test('different rows slow clicks and a backwards clock never form a double click',function()
    local S,h,state,page,content,Click=Boot()
    for _,view in ipairs({page.tableView,content.table})do
        Click(view,1,2000);Click(view,2,2100);assert(state.opens==0)
        Click(view,2,2600);assert(state.opens==0)
        Click(view,2,2500);assert(state.opens==0)
    end
end)
Test('page and assistant click timing stays independent while sharing selected map',function()
    local S,h,state,page,content,Click=Boot()
    Click(page.tableView,1,1000);Click(content.table,1,1100);assert(state.opens==0,'two surfaces accidentally formed a double click')
    Click(content.table,1,1200);assert(state.opens==1 and state.opened=='a')
    Click(page.tableView,2,1250);Click(page.tableView,2,1300);assert(state.opens==2 and state.opened=='b')
end)
Test('failed selection prevents map action and failed map action is visibly explained',function()
    local S,h,state,page,content,Click,Find=Boot()
    Click(page.tableView,1,1000);state.rejectSelect=true;Click(page.tableView,1,1200);assert(state.opens==0)
    state.rejectSelect=false;state.rejectMap=true
    Click(page.tableView,2,2000);Click(page.tableView,2,2200)
    local status=assert(Find(page,'v3_treasure_status'))
    assert(state.opens==0 and status.text:find('地图能力暂不可用',1,true),'map failure absent from main menu')
    Click(content.table,2,3000);Click(content.table,2,3200)
    assert(state.opens==0 and content.treasureInteractionHint.text:find('地图能力暂不可用',1,true),'map failure absent from assistant')
end)
Test('deactivation and hidden assistant reset a pending first click',function()
    local S,h,state,page,content,Click=Boot()
    Click(page.tableView,1,1000);assert(page:OnDeactivated());assert(page:OnActivated())
    Click(page.tableView,1,1200);assert(state.opens==0,'page reopened with a pending double click')
    Click(content.table,2,2000);assert(content:SetAvailable(false));assert(content:SetAvailable(true))
    Click(content.table,2,2200);assert(state.opens==0,'assistant restored with a pending double click')
end)
Test('clicking an already highlighted row restores tracking after another surface changed it',function()
    local S,h,state,page,content,Click=Boot()
    Click(page.tableView,1,1000);Click(content.table,2,1600);assert(state.selected.key=='b')
    Click(page.tableView,1,2200);assert(state.selected.key=='a' and state.opens==0,'single page click left another surface target selected')
    Click(content.table,2,2800);assert(state.selected.key=='b' and state.opens==0,'single assistant click did not restore tracking')
end)
Test('disabled feature refuses activation and disable-enable cancels a pending click',function()
    local S,h,state,page,content,Click=Boot()
    Click(page.tableView,1,1000)
    assert(S.FeatureRuntime:SetPreferredEnabled('life_treasure',false));page:Refresh()
    Click(page.tableView,1,1100);Click(page.tableView,1,1200)
    assert(state.opens==0,'disabled main page still opened a treasure map')
    assert(S.FeatureRuntime:SetPreferredEnabled('life_treasure',true));page:Refresh()
    Click(page.tableView,1,1250);assert(state.opens==0,'re-enabled page kept disabled click timing')
end)
Test('a rejected first selection cannot become a map action after recovery',function()
    local S,h,state,page,content,Click=Boot()
    state.rejectSelect=true;Click(page.tableView,1,1000);assert(state.selected==nil and state.opens==0)
    state.rejectSelect=false;Click(page.tableView,1,1200)
    assert(state.selected.key=='a' and state.opens==0,'failed first click armed map activation')
    Click(page.tableView,1,1300);assert(state.opens==1)
end)
Test('refresh synchronizes both highlights without issuing a selection or map action',function()
    local S,h,state,page,content,Click=Boot()
    Click(page.tableView,1,1000);page:Refresh();content:Refresh()
    assert(state.selects==1 and state.opens==0 and page.tableView:GetSelectedIndex()==1 and content.table:GetSelectedIndex()==1)
    Click(content.table,2,1600);page:Refresh();content:Refresh()
    assert(state.selects==2 and state.opens==0 and page.tableView:GetSelectedIndex()==2 and content.table:GetSelectedIndex()==2)
    state.rejectSelect=true;Click(page.tableView,1,2200)
    assert(state.selected.key=='b' and page.tableView:GetSelectedIndex()==2,'failed command left an unauthoritative row highlighted')
end)
print('TREASURE_DOUBLE_CLICK PASS: '..passed..' cases (Native/Feature action boundaries modeled)')

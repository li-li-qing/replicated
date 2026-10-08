-- Main bag settings: real Feature/Store/Demand/PageHost/RSUI, Native inventory and RAM disk only.
-- Offline interaction/geometry contract, not RU acceptance; never loaded by toc.g.
local passed,failed=0,0
local function T(name,fn)local ok,e=xpcall(fn,debug.traceback);if ok then passed=passed+1;print('PASS bag-page '..name)else failed=failed+1;print('FAIL bag-page '..name..': '..tostring(e))end end
local Boot=dofile('tools/rs_bag_action_test_host.lua')
local function Build(options)
    options=options or {bag={{itemType=100,name='苹果',stack=5},{itemType=200,name='蔬菜',stack=200}}}
    local h=Boot(options);local S,F=h.S,h.F;assert(h.page:OnDeactivated())
    S.FeatureRuntime.IsEnabled=function(_,id)return id=='tools_bag' and F.enabled==true end
    dofile('features/rs_feature_registry.lua');dofile('presentation/v3/shell/rs_v3_page_host.lua')
    dofile('presentation/v3/pages/rs_v3_business_pages.lua')
    local parent=h.Native(UIParent,'bag-page-parent',0,0,640,560)
    local page=assert(S.UIV3.PageHost.factories['tools.bag_organizer'](parent,'tools.bag_organizer'))
    assert(page:OnActivated());assert(page:Refresh())
    local widgets={};local function Index(n)widgets[n.id]=n;for _,child in ipairs(n.children or {})do Index(child)end end;Index(page)
    local function Layout(w,height)
        parent:SetExtent(w,height);page:SetBounds(0,0,w,height);page:InvalidateMeasure('test_viewport');S.RSUI:FlushLayoutQueue(32)
        assert(S.RSUI:GetLayoutQueueSnapshot().pending==0,'bag layout queue did not converge')
    end
    Layout(640,560)
    local function Click(id)
        local component=assert(widgets[id],id);return component.root.events.OnClick(component.root,'LeftButton')
    end
    local function Action(index)
        Layout(640,560);local row=assert(page.tableView.list.poolByIndex[index]).row
        local button=assert(row.cells[4]);return button.root.events.OnClick(button.root,'LeftButton')
    end
    return h,S,F,page,widgets,Layout,Click,Action
end
T('main menu exposes the floating settings list and direct Add Remove actions',function()
    local h,S,F,page,w,Layout,Click,Action=Build()
    assert(w.v3_business_tools_bag_settings_tabs,'main menu still uses blacklist dropdown configuration')
    assert(not w.v3_business_tools_bag_blacklist_picker,'old selection and separate delete workflow remains')
    assert(#page.tableView.columns==4 and page.tableView.columns[4].cellType=='button','main bag lacks a per-item blacklist action')
    assert(#page.tableView.list.items==2 and page.tableView.list.items[1].name=='苹果')
    local reads=h.inventoryReads;assert(Action(1));assert(#F:GetProjection().blacklistRows==1)
    assert(page.tableView.list.items[1].blocked==true);assert(Action(1));assert(#F:GetProjection().blacklistRows==0)
    assert(h.inventoryReads==reads,'rendering or direct blacklist selection scanned native inventory')
    local _,coldS,coldF=Build({disk=h.disk,bag=h.bag});assert(#coldF:GetProjection().blacklistRows==0,'removed item returned after reload')
end)
T('blacklist tab shows absent saved items and name ID filters never change configuration',function()
    local h,S,F,page,w,Layout,Click,Action=Build();assert(F.Commands:AddGlobalBlacklistItem(999,'不在背包'))
    assert(w.v3_business_tools_bag_settings_tabs.spec.set('blacklist'));Layout(640,560)
    assert(#page.tableView.list.items==1 and page.tableView.list.items[1].itemType==999,'absent saved item cannot be removed')
    assert(page.tableView.list.items[1].blocked==true,'blacklist source item lost blocked status')
    local removed,removeErr=Action(1);assert(removed,tostring(removeErr));assert(#F:GetProjection().blacklistRows==0,'absent item remains saved')
    assert(w.v3_business_tools_bag_settings_tabs.spec.set('bag'))
    local writes,reads=h.writes,h.inventoryReads
    w.v3_business_tools_bag_blacklist_item_input:SetValue('苹果',false);assert(Click('v3_business_tools_bag_filter_apply'))
    assert(#page.tableView.list.items==1 and page.tableView.list.items[1].itemType==100)
    w.v3_business_tools_bag_blacklist_item_input:SetValue('200',false);assert(Click('v3_business_tools_bag_filter_apply'))
    assert(#page.tableView.list.items==1 and page.tableView.list.items[1].itemType==200)
    assert(Click('v3_business_tools_bag_filter_clear') and #page.tableView.list.items==2)
    assert(h.writes==writes and h.inventoryReads==reads,'filtering scans or saves instead of using cached rows')
end)
T('failed save keeps the committed item state and explicit name ID adding still works',function()
    local h,S,F,page,w,Layout,Click,Action=Build();h.failSave=true
    assert(Action(1)==false and #F:GetProjection().blacklistRows==0)
    assert(w.v3_business_tools_bag_blacklist_status.text:find('保存失败',1,true),'save rejection is invisible')
    h.failSave=false;w.v3_business_tools_bag_blacklist_item_input:SetValue('苹果',false)
    assert(Click('v3_business_tools_bag_blacklist_item_add'));assert(#F:GetProjection().blacklistRows==1)
    assert(Click('v3_business_tools_bag_blacklist_toggle'));assert(F:GetProjection().blacklist.enabled==false)
end)
T('minimum and normal main-menu widths retain list space and every settings action',function()
    local h,S,F,page,w,Layout=Build()
    for _,size in ipairs({{560,460},{800,650}})do
        for _,source in ipairs({'bag','blacklist','bag'})do
            assert(w.v3_business_tools_bag_settings_tabs.spec.set(source));Layout(size[1],size[2])
            assert(page.tableView.height>=120,'settings still crowd out the item list')
            for _,id in ipairs({'v3_business_tools_bag_settings_tabs','v3_business_tools_bag_blacklist_toggle','v3_business_tools_bag_filter_apply','v3_business_tools_bag_filter_clear','v3_business_tools_bag_blacklist_item_add','v3_business_tools_bag_quick_take','v3_business_tools_bag_quick_put','v3_business_tools_bag_quick_all_put'})do
                assert(h:VisibleRect(w[id]),'settings action is clipped '..id)
            end
            local sum=0;for _,column in ipairs(page.tableView:GetResolvedColumns())do sum=sum+column.width;if column.id=='action'then assert(column.width>=64,'per-item action clipped')end end
            assert(sum<=page.tableView.width,'item columns escape the viewport')
        end
    end
end)
T('visible page retains one lease and geometry heartbeat does not rebind the item list',function()
    local h,S,F,page,w,Layout=Build();assert(F.consumerCount==1)
    local sets=0;local original=page.tableView.SetItems
    page.tableView.SetItems=function(self,...)sets=sets+1;return original(self,...)end
    local reads=h.inventoryReads
    for i=1,20 do S.Events:Publish(F.UpdateTopic,F.Authority.revision,'bag_quick_visible_heartbeat')end
    assert(sets==0 and h.inventoryReads==reads,'geometry heartbeat rebuilds or scans the full item list')
    assert(page:OnDeactivated());assert(F.consumerCount==0);assert(page:OnDeactivated());assert(F.consumerCount==0)
    assert(page:OnActivated());assert(F.consumerCount==1)
end)
print(('BAG_PAGE_RESULT passed=%d failed=%d'):format(passed,failed));if failed>0 then os.exit(1)end

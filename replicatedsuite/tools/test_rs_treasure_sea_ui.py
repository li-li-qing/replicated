"""海上资料点复用原生地图箭头；真实 RSUI/Feature，Native 叶节点为离线模型。"""
from pathlib import Path
import os
import unittest
from lupa.lua51 import LuaRuntime
from test_rs_treasure_compass_runtime import ROOT

HOST = r'''
h=dofile('tools/rs_gear_page_test_host.lua')({width=820,height=680})
local S=h.S
-- Popup位置求解使用真实实现；这里只提供Native几何的离线读数。
S.Layout=S.Layout or {}
S.Layout.ResolveSuiteOwnedViewportLogicalRect=function(_,n)
 local x,y,p=0,0,n
 while p do x=x+(p.x or 0);y=y+(p.y or 0);p=p.parent end
 return x,y,n.width,n.height,{}
end
dofile('ui/framework/rs_ui_popup_positioning.lua')
h.mapCalls={}
X2Map={ShowWorldmapLocation=function(_,zone,x,y,z)
 h.mapCalls[#h.mapCalls+1]={zone=zone,x=x,y=y,z=z};return not h.rejectNativeMap
end}
local call=S.Api.CallCapability
S.Api.CallCapability=function(self,cap,...)
 if cap=='X2Unit:GetUnitWorldPositionByTarget' then return true,21503,nil,28672,0 end
 return call(self,cap,...)
end
S.Services.InventorySnapshotV3={BuildSnapshot=function()return {rows={},bagId=1,readErrors=0}end,ReadSlot=function()return true,nil end}
dofile('core/rs_demand.lua');dofile('features/life/shared/rs_life_slice_factory.lua')
dofile('data/rs_treasure_sea_points.lua');dofile('features/life/treasure/rs_treasure_sea_catalog.lua');dofile('features/life/treasure/rs_treasure_feature.lua')
f=S.Features.Treasure;assert(f:Initialize());assert(f:Enable());assert(f:AcquireConsumer('test:page'))
assert(f.Commands:SetViewKind('ships'));assert(f.Commands:SetRegion('gold-sea'))
S.Features.Trade=f;S.Features.Bonds=f;S.Features.Fishing=f -- 未打开的其它生活模块仅提供宿主契约。
S.UIV3.WidgetHost={specs={},BindFeatureLifecycle=function()return true end,
 Register=function(self,id,spec)self.specs[id]=spec;return true end,IsVisible=function()return false end}
S.UI.CreateWindowShell=function()error('native arrow action must not create an atlas window')end
dofile('ui/framework/rs_ui_floating_surface.lua') -- 真实状态适配器；内容测试不创建外层窗口。
dofile('presentation/v3/widgets/rs_v3_treasure_controls.lua')
dofile('presentation/v3/widgets/rs_v3_life_economy_widgets.lua')
local PH=S.UIV3.PageHost
PH.BindFeatureConsumerLifecycle=function()return true end
PH.SyncFeatureConsumer=function(_,page,binding)
 if not page.consumerHeld then assert(f:AcquireConsumer(binding.token));page.consumerHeld=true end
 return page:Refresh()
end
PH.ReleaseFeatureConsumer=function(_,page,binding)page.consumerHeld=false;return f:ReleaseConsumer(binding.token)end
S.UI.CreateSlider=function(_,parent,id,x,y,w,ht,minimum,maximum,step,value)
 local n=h.Native(parent,id,x,y,w,ht);n.value=value
 function n:GetValue()return self.value end;function n:SetValue(v)self.value=v;return true end
 function n:SetRange()return true,true end;return n
end
dofile('ui/framework/rs_ui_numeric_range_store.lua');dofile('ui/framework/rs_ui_forms.lua');dofile('ui/framework/rs_ui_settings_foundation.lua')
dofile('presentation/v3/pages/rs_v3_life_m16_pages.lua')
'''


class SeaUiTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.previous=Path.cwd()
        os.chdir(ROOT)

    @classmethod
    def tearDownClass(cls):
        os.chdir(cls.previous)

    def boot(self):
        lua=LuaRuntime(unpack_returned_tuples=True)
        lua.execute(HOST)
        return lua

    def test_compact_controls_select_nearest_then_show_the_same_target_on_native_map(self):
        self.boot().execute('''
        local S=h.S;local parent=h.Native(nil,'sea_controls_parent',0,0,700,180)
        local body=assert(S.RSUI:VerticalBox({id='sea_controls_body',parent=parent,gap=4}))
        local controls=S.UIV3.TreasureControlsV3:Build(body,f,'sea_controls_',{})
        assert(not controls.map.enabled,'map action enabled without a target')
        assert(controls.nearest.root.events.OnClick(controls.nearest.root,'LeftButton'))
        local selected=f:GetProjection().selected;assert(selected and #h.mapCalls==0)
        controls:Refresh(f:GetProjection());assert(controls.map.enabled)
        assert(controls.map.root.events.OnClick(controls.map.root,'LeftButton'))
        assert(#h.mapCalls==1 and h.mapCalls[1].zone==39)
        assert(h.mapCalls[1].x==selected.worldX and h.mapCalls[1].y==selected.worldY)
        assert(S.UIV3.TreasureSeaMapV3==nil)
        ''')

    def test_double_click_for_each_sea_kind_uses_existing_native_map_command(self):
        for kind in ('seabugs','ships'):
            lua=self.boot();lua.globals().test_kind=kind
            lua.execute('''
            assert(f.Commands:SetViewKind(test_kind));assert(f.Commands:SetRegion('gold-sea'))
            local row=f:GetProjection().rows[1];local interaction=h.S.UIV3.TreasureMapInteraction
            local instance={Refresh=function()return true end}
            assert(interaction:Activate(instance,row,f));assert(#h.mapCalls==0)
            h.ms=h.ms+100;assert(interaction:Activate(instance,row,f))
            assert(#h.mapCalls==1 and h.mapCalls[1].zone==39 and h.mapCalls[1].x==row.worldX)
            assert(f.Authority.selected.key==row.key and f.trackingConsumerHeld)
            ''')

    def test_main_page_keeps_list_space_and_native_map_button_after_region_filter(self):
        self.boot().execute('''
        local parent=h.Native(nil,'treasure_parent',0,0,700,520)
        local page,why=h.S.UIV3.PageHost.factories['life.treasure'](parent,'life.treasure')
        assert(page,why);assert(page:OnActivated());page:Layout(0,0,700,520)
        assert(page.tableView.height>200 and page.treasureRefreshField.visible==false)
        assert(f.Commands:SetRegion('whale-strait'));assert(page:Refresh())
        assert(page.tableView:GetItemCount()==3)
        for _,size in ipairs({{620,440},{700,520},{1040,700}})do
          parent.width,parent.height=size[1],size[2];page:Layout(0,0,size[1],size[2])
          assert(page.tableView.height>120)
          for _,c in ipairs({page.treasureControls.kind,page.treasureControls.region,page.treasureControls.nearest,page.treasureControls.map,page.treasureControls.settings})do
            local ok,why=h:VisibleRect(c);assert(ok,why)
          end
        end
        assert(page.treasureControls.nearest.root.events.OnClick(page.treasureControls.nearest.root,'LeftButton'))
        local key=f.Authority.selected.key;assert(page:Refresh())
        assert(page.treasureControls.map.root.events.OnClick(page.treasureControls.map.root,'LeftButton'))
        assert(#h.mapCalls==1 and h.mapCalls[1].zone==104)
        assert(page:OnDeactivated());assert(f:ReleaseConsumer('test:page'))
        assert(f.Authority.selected.key==key and f.consumerCount==1)
        assert(f.Commands:StopTracking());assert(f.consumerCount==0)
        ''')

    def test_assistant_content_map_action_uses_native_arrow_and_shares_selection(self):
        self.boot().execute('''
        local parent=h.Native(nil,'treasure_widget_parent',0,0,500,340)
        local instance,why=h.S.UIV3.LifeEconomyContent:Create(parent,'Treasure','sea_assistant_',{})
        assert(instance,why);assert(instance:Refresh());instance.content:Layout(0,0,500,340)
        assert(instance.treasureNearestButton.root.events.OnClick(instance.treasureNearestButton.root,'LeftButton'))
        local selected=f.Authority.selected;assert(instance:Refresh())
        assert(instance.treasureMapButton.root.text=='地图定位')
        assert(instance.treasureMapButton.root.events.OnClick(instance.treasureMapButton.root,'LeftButton'))
        assert(#h.mapCalls==1 and h.mapCalls[1].zone==39 and h.mapCalls[1].x==selected.worldX)
        ''')

    def test_runtime_load_chain_has_no_retired_atlas_or_texture_dependency(self):
        toc=(ROOT/'toc.g').read_text(encoding='utf-8-sig')
        self.assertFalse('rs_v3_treasure_sea_map.lua' in toc,'retired atlas still enters the runtime')
        self.assertFalse((ROOT/'presentation/v3/widgets/rs_v3_treasure_sea_map.lua').exists())
        self.assertFalse((ROOT/'data/treasure_maps').exists())
        self.assertNotIn('IMAGE_DRAWABLE',(ROOT/'native/rs_native_contract.lua').read_text(encoding='utf-8-sig'))

    def test_assistant_next_and_round_progress_are_visible_and_use_shared_marks(self):
        self.boot().execute('''
        local parent=h.Native(nil,'round_widget_parent',0,0,390,260)
        local instance,why=h.S.UIV3.LifeEconomyContent:Create(parent,'Treasure','round_assistant_',{})
        assert(instance,why);assert(f.Commands:SetRegion('whale-strait'));assert(instance:Refresh())
        assert(instance.treasureNextButton,'floating assistant has no next point action')
        assert(instance.treasureNearestButton.root.events.OnClick(instance.treasureNearestButton.root,'LeftButton'))
        local key=f.Authority.selected.key;assert(instance:Refresh())
        assert(instance.treasureNextButton.root.events.OnClick(instance.treasureNextButton.root,'LeftButton'))
        assert(f.Authority.visited[key]=='searched' and f.Authority.selected.key~=key)
        assert(instance:Refresh());assert(instance.treasureInteractionHint.text:find('1/3',1,true))
        assert(instance.treasureInteractionHint.text:find('待搜 2',1,true))
        local marked;for i=1,instance.table:GetItemCount()do local row=instance.table:GetItem(i);if row.key==key then marked=row end end
        assert(marked and marked.visitText=='本轮已搜查','assistant hides the searched status')
        for _,width in ipairs({240,390,500})do
            parent.width=width;instance.content:Layout(0,0,width,260)
            for _,control in ipairs({instance.treasureMapButton,instance.treasureNearestButton,instance.treasureNextButton,
                instance.treasureKindDropdown,instance.treasureRegionDropdown,instance.treasureSettingsDropdown})do
                local visible,reason=h:VisibleRect(control);assert(visible,reason)
            end
            assert(instance.table.height>80,'round controls consumed the point list')
        end
        assert(instance.treasureSettingsDropdown:SetValue('undo'))
        assert(f.Authority.visited[key]==nil)
        ''')

    def test_floating_selectors_and_settings_work_without_opening_the_main_page(self):
        self.boot().execute('''
        local parent=h.Native(nil,'compact_parent',0,0,216,172)
        local instance=assert(h.S.UIV3.LifeEconomyContent:Create(parent,'Treasure','compact_',{}))
        assert(instance.treasureKindDropdown,'floating category selector missing')
        assert(instance.treasureKindDropdown:SetValue('seabugs'))
        assert(instance.treasureRegionDropdown:SetValue('silent-sea'))
        assert(f:GetProjection().viewKind=='seabugs' and f:GetProjection().region=='silent-sea')
        assert(instance.treasureKindDropdown:SetValue('maps'));assert(not instance.treasureRegionDropdown.enabled)
        assert(instance.treasureKindDropdown:SetValue('ships'));assert(instance.treasureRegionDropdown:SetValue('whale-strait'))
        assert(instance.treasureSettingsDropdown:SetValue('timer:720'))
        assert(f:GetProjection().shipRespawnMinutes==720)
        assert(instance.treasureSettingsDropdown.root.text:find('设置',1,true),'settings trigger kept an action label')
        instance.content:Layout(0,0,216,172)
        for _,c in ipairs({instance.treasureKindDropdown,instance.treasureRegionDropdown,instance.treasureSettingsDropdown,
            instance.treasureMapButton,instance.treasureNearestButton,instance.treasureNextButton})do
            local visible,why=h:VisibleRect(c);assert(visible,why)
        end
        assert(instance.table.height>=60,'compact settings consumed the point list')
        assert(instance.treasureSettingsDropdown:SetValue('round'));assert(f:GetProjection().roundVisited==0)
        ''')

    def test_compact_dropdown_click_closes_before_shared_command_and_leaving_closes_popup(self):
        self.boot().execute('''
        local parent=h.Native(nil,'click_parent',0,0,390,260)
        local instance=assert(h.S.UIV3.LifeEconomyContent:Create(parent,'Treasure','click_',{}));instance:Refresh()
        instance.content:Layout(0,0,390,260)
        local choice=instance.treasureKindDropdown
        local command=f.Commands.SetViewKind
        f.Commands.SetViewKind=function(self,value)assert(not choice.open,'command reentered open popup');return command(self,value)end
        assert(choice.root.events.OnClick(choice.root,'LeftButton'));assert(choice.open)
        local button=choice.optionButtons[2];assert(button.events.OnClick(button,'LeftButton'))
        assert(f:GetProjection().viewKind=='seabugs' and not choice.open)
        local menu=instance.treasureSettingsDropdown
        assert(menu.root.events.OnClick(menu.root,'LeftButton'));assert(menu.open)
        assert(instance:SetAvailable(false));assert(not menu.open)
        -- 共享表单的默认宽度下限保持100；只有显式紧凑控件允许窄触发器。
        local normal=assert(h.S.RSUI:Dropdown({id='normal_width',parent=parent,items={{value=1,text='test'}},get=function()return 1 end,set=function()return true end}))
        normal:Layout(0,0,48,24);assert(normal.width==100)
        choice:Layout(0,0,60,24);assert(choice.width==60)
        ''')


if __name__=='__main__':
    unittest.main()

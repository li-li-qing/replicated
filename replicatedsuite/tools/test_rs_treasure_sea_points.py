"""海上资料点接入真实寻宝 Feature，Lua 5.1；不代表 RU 实机验收。"""
from pathlib import Path
import unittest
from lupa.lua51 import LuaRuntime
from test_rs_treasure_compass_runtime import HOST, ROOT


class SeaPointsTests(unittest.TestCase):
    def boot(self):
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute(HOST)
        lua.execute("ReplicatedSuite.Persistence.MutateStore=function(_,id,fn,options) H.roundSaves=(H.roundSaves or 0)+1;H.roundSaveOptions=options;return fn() end")
        lua.execute("ReplicatedSuite.LifeSliceFactory.Call=function(cap) if cap=='X2Unit:GetCurrentZoneGroup' then return true,H.currentZoneGroup or 2 end;if H.positionUnavailable then return false,nil,'unavailable' end;return true,H.wx or 21503,nil,H.wy or 28672,0 end")
        lua.execute("H.mapCalls={};ReplicatedSuite.LifeSliceFactory.Action=function(cap,object,method,zone,x,y,z) H.mapCalls[#H.mapCalls+1]={zone=zone,x=x,y=y,z=z};if H.rejectNativeMap then return false,'native location rejected' end;return true end")
        for rel in ("data/rs_treasure_sea_points.lua", "features/life/treasure/rs_treasure_sea_catalog.lua"):
            if (ROOT / rel).exists():
                lua.execute((ROOT / rel).read_text(encoding="utf-8-sig"))
        lua.execute("ReplicatedSuite.Utils={DeepCopy=ReplicatedSuite.LifeSliceFactory.Copy};ReplicatedSuite.SafeTraceback=debug.traceback")
        lua.execute((ROOT / "core/rs_demand.lua").read_text(encoding="utf-8-sig"))
        lua.execute((ROOT / "features/life/treasure/rs_treasure_feature.lua").read_text(encoding="utf-8-sig"))
        lua.execute("function H.Start() local f=ReplicatedSuite.Features.Treasure;f.enabled=true;assert(f:AcquireConsumer('test:page'));return f end")
        self.assertIsNotNone(lua.globals().ReplicatedSuite.Features.Treasure.Commands.SetViewKind,
                             "缺少海上点位分类命令")
        return lua

    def test_region_filter_nearest_and_data_identity(self):
        self.boot().execute('''
        local f=H.Start();assert(f.Commands:SetViewKind('seabugs'))
        assert(f.Commands:SetRegion('silent-sea'))
        local p=f:GetProjection();assert(#p.rows==21)
        for _,row in ipairs(p.rows) do assert(row.region=='silent-sea' and row.kind=='seabugs') end
        assert(f.Commands:TrackNearest());assert(f.Authority.selected.key=='seabugs:silent-sea:4')
        assert(f.Commands:SetViewKind('ships'));assert(f.Commands:SetRegion('all'))
        assert(#f:GetProjection().rows==444)
        assert(f.Commands:SetRegion('whale-strait'));assert(#f:GetProjection().rows==3)
        assert(not f.Commands:SetRegion('made-up'));assert(f:GetProjection().region=='whale-strait')
        ''')

    def test_static_target_survives_empty_and_unreadable_bag(self):
        self.boot().execute('''
        local f=H.Start();assert(f.Commands:SetViewKind('seabugs'));assert(f.Commands:SetRegion('silent-sea'))
        assert(f.Commands:TrackNearest());local key=f.Authority.selected.key
        local scans,reads=H.scans,H.reads;H.items={};H.fail=true
        H.Tick(3500);assert(f.Commands:Refresh());assert(f.Authority.selected.key==key)
        assert(f.Authority.status=='ready' and H.scans==scans and H.reads==reads)
        assert(f.Authority:UpdateCompass());assert(#f.Authority.compass.points>0)
        assert(#H.mapCalls==0,'tracking or refresh opened the native map without a user action')
        assert(f.Commands:ShowSelectedOnMap());assert(H.mapCalls[1].zone==36)
        ''')

    def test_filter_and_player_motion_do_not_switch_or_reorder_target(self):
        self.boot().execute('''
        local f=H.Start();assert(f.Commands:SetViewKind('ships'));assert(f.Commands:SetRegion('whale-strait'))
        local rows=f:GetProjection().rows;assert(f.Commands:Select(rows[2].key));local key=f.Authority.selected.key
        H.wx,H.wy=10000,10000
        H.Tick(500);assert(f.Authority.selected.key==key)
        local after=f:GetProjection().rows;for i,row in ipairs(rows)do assert(after[i].key==row.key)end
        assert(f.Commands:SetRegion('silent-sea'));assert(f.Authority.selected.key==key)
        local p=f:GetProjection();p.selected.worldX=0;assert(f.Authority.selected.worldX~=0)
        ''')

    def test_manual_round_skip_undo_and_reset(self):
        self.boot().execute('''
        local f=H.Start();assert(f.Commands:SetViewKind('ships'));assert(f.Commands:SetRegion('whale-strait'))
        assert(f.Commands:TrackNearest());local first=f.Authority.selected.key
        assert(f.Commands:VisitAndNext('searched'));assert(f.Authority.selected.key~=first)
        assert(f.Commands:UndoVisit());assert(f.Authority.selected.key==first)
        for i=1,3 do assert(f.Commands:VisitAndNext('skipped')) end
        assert(f.Authority.selected==nil and f:GetProjection().roundVisited==3)
        assert(not f.Commands:TrackNearest());assert(f.Commands:ResetRound());assert(f.Commands:TrackNearest())
        assert(f:GetProjection().roundVisited==0)
        ''')

    def test_unknown_player_position_does_not_choose_an_arbitrary_nearest(self):
        self.boot().execute('''
        local f=H.Start();assert(f.Commands:SetViewKind('seabugs'))
        H.positionUnavailable=true
        assert(not f.Commands:TrackNearest());assert(f.Authority.selected.kind~='seabugs')
        f.enabled=false;assert(not f.Commands:Select('seabugs:silent-sea:1'))
        ''')

    def test_finished_round_does_not_resurrect_a_bag_target_on_next_tick(self):
        self.boot().execute('''
        local f=H.Start();assert(f.Commands:SetViewKind('ships'));assert(f.Commands:SetRegion('whale-strait'))
        assert(f.Commands:TrackNearest());for i=1,3 do assert(f.Commands:VisitAndNext('searched')) end
        H.Tick(3500);assert(f.Authority.selected==nil,'completed round silently selected a bag map')
        assert(f.Commands:Refresh());assert(f.Authority.selected==nil)
        ''')

    def test_world_coordinates_native_zone_and_source_status_are_consistent(self):
        self.boot().execute('''
        local c=ReplicatedSuite.TreasureSeaCatalog
        local point=c:Get('seabugs:silent-sea:1')
        assert(math.abs(point.worldX-19366.4)<0.001 and math.abs(point.worldY-23096.888888889)<0.001)
        assert(point.zoneGroupId==36)
        local p=c:Get('ships:freedom-sea:24');assert(p.sourceStatus=='source_confirmed')
        assert(c:Get('ships:freedom-sea:23').sourceStatus=='unconfirmed')
        point.worldX=0;assert(c:Get('seabugs:silent-sea:1').worldX>0)
        ''')

    def test_all_sea_regions_use_their_native_zone_and_selected_world_coordinates(self):
        self.boot().execute('''
        local f=H.Start();H.currentZoneGroup=2
        local zones={['silent-sea']=36,['lost-sea']=30,['gold-sea']=39,['freedom-sea']=59,
          ['ship-grave']=36,['crescent-sea']=40,['whale-strait']=104,['pirate-sea']=60}
        for region,zone in pairs(zones)do
          local row=ReplicatedSuite.TreasureSeaCatalog:List('ships',region)[1]
          assert(row and f.Commands:Select(row.key));assert(f.Commands:ShowSelectedOnMap())
          local call=H.mapCalls[#H.mapCalls]
          assert(call.zone==zone and call.x==row.worldX and call.y==row.worldY and call.z==0)
          assert(f:GetProjection().lastMapZoneSource=='sea_catalog')
        end
        assert(#H.mapCalls==8)
        ''')

    def test_unknown_sea_zone_does_not_fall_back_to_player_land_region(self):
        self.boot().execute('''
        local f=H.Start();assert(f.Commands:Select('ships:gold-sea:2'))
        f.Authority.selected.zoneGroupId=nil;H.currentZoneGroup=2
        assert(not f.Commands:ShowSelectedOnMap());assert(#H.mapCalls==0)
        assert(f:GetProjection().lastMapZoneSource=='unresolved')
        assert(f.Authority.selected.key=='ships:gold-sea:2')
        ''')

    def test_native_map_failure_keeps_tracking_and_records_exact_request_in_health(self):
        self.boot().execute('''
        local f=H.Start();assert(f.Commands:Select('seabugs:gold-sea:13'))
        H.rejectNativeMap=true;assert(not f.Commands:ShowSelectedOnMap())
        local d=f:GetHealth();assert(d.nativeMap.lastError=='native location rejected')
        assert(d.nativeMap.lastRequest.zoneGroupId==39 and d.nativeMap.lastRequest.key==d.selected.key)
        assert(d.trackingConsumerHeld and H.tasks.v3_life_treasure_compass)
        d.nativeMap.lastRequest.x=0;assert(f:GetHealth().nativeMap.lastRequest.x~=0)
        ''')

    def test_explicit_tracking_survives_map_close_and_stop_releases_last_consumer(self):
        self.boot().execute('''
        local f=H.Start();assert(f.Commands:SetViewKind('seabugs'));assert(f.Commands:TrackNearest())
        local key=f.Authority.selected.key;assert(f:ReleaseConsumer('test:page'))
        assert(f.consumerCount==1 and H.tasks.v3_life_treasure_compass,'closing UI stopped explicit tracking')
        H.Tick(500);assert(f.Authority.selected.key==key)
        assert(f.Commands:StopTracking());assert(f.consumerCount==0 and next(H.tasks)==nil)
        assert(#f.Authority.compass.points==0)
        ''')

    def test_arrival_only_means_near_the_coordinate_and_never_marks_searched(self):
        self.boot().execute('''
        local f=H.Start();assert(f.Commands:Select('seabugs:silent-sea:1'))
        local p=f.Authority.selected
        ReplicatedSuite.Services.ScreenProjectionV3.GetUnitWorldPosition=function(_,_,localSpace)
          if localSpace then return 100,200,10 end;return p.worldX,p.worldY,0
        end
        assert(f.Authority:UpdateCompass());assert(f.Authority.compass.distanceLabel.text:find('坐标附近',1,true))
        assert(f.Authority.visited[p.key]==nil)
        ''')

    def test_successful_sea_tracking_clears_previous_native_map_error(self):
        self.boot().execute('''
        local f=H.Start();H.rejectNativeMap=true
        assert(not f.Commands:ShowSelectedOnMap());assert(f:GetProjection().lastMapActionError)
        assert(f.Commands:SetViewKind('seabugs'));assert(f.Commands:TrackNearest())
        local p=f:GetProjection();assert(p.selected.kind=='seabugs' and p.lastMapActionError==nil,
          'successful sea tracking still reports an old native map failure')
        ''')

    def test_diagnostics_are_detached_and_do_not_sample_or_change_tracking(self):
        lua=self.boot()
        self.assertIsNotNone(lua.globals().ReplicatedSuite.Features.Treasure.GetHealth,
                             '寻宝诊断缺少当前目标和区域状态')
        lua.execute('''
        local f=H.Start();assert(f.Commands:SetViewKind('ships'));assert(f.Commands:SetRegion('whale-strait'));assert(f.Commands:TrackNearest())
        local scans,reads,count,revision=H.scans,H.reads,f.consumerCount,f.Authority.revision
        local key=f.Authority.selected.key
        local d=f:GetHealth();assert(d.viewKind=='ships' and d.region=='whale-strait' and d.filteredPointCount==3)
        assert(d.catalogCounts.seabugs==60 and d.catalogCounts.ships==444 and d.selected.key==key)
        d.selected.worldX=0;assert(f.Authority.selected.worldX~=0)
        assert(H.scans==scans and H.reads==reads and f.consumerCount==count and f.Authority.revision==revision)
        ''')

    def test_real_module_report_includes_current_tracking_health(self):
        lua=self.boot()
        lua.execute('''
        local S=ReplicatedSuite;local f=H.Start()
        S.FeatureRegistry={order={'life_treasure'},features={life_treasure={id='life_treasure',name='寻宝',route='life.treasure',authority='v3.life.treasure'}}}
        function S.FeatureRegistry:Get(id)return self.features[id]end
        function S.FeatureRegistry:List()return {self.features.life_treasure}end
        function S.FeatureRegistry:GetByRoute()return self.features.life_treasure end
        S.FeatureRuntime.implementations={life_treasure=f}
        S.FeatureRuntime.state={life_treasure={initialized=true,enabled=true,faulted=false}}
        S.FeatureRuntime.IsImplemented=function()return true end;S.FeatureRuntime.IsEnabled=function()return true end
        S.Persistence.Describe=function()return {rows={}}end
        assert(f.Commands:SetViewKind('ships'));assert(f.Commands:SetRegion('whale-strait'));assert(f.Commands:TrackNearest())
        ''')
        for rel in ('core/rs_diagnostic_detail.lua','core/rs_module_diagnostics.lua'):
            lua.execute((ROOT/rel).read_text(encoding='utf-8-sig'))
        lua.execute('''
        local before=ReplicatedSuite.Features.Treasure.Authority.revision
        local report,err,detail=ReplicatedSuite.ModuleDiagnosticsHub:BuildReport('life_treasure',{detailed=true})
        assert(report,err);assert(detail:find('[DETAIL_SOURCE feature.health]',1,true),'health absent from exported report')
        assert(detail:find('whale-strait',1,true) and detail:find('catalogCounts',1,true))
        assert(ReplicatedSuite.Features.Treasure.Authority.revision==before)
        ''')


if __name__ == "__main__":
    unittest.main()

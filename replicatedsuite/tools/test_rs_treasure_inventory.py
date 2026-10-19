"""真实 Lua 5.1/库存快照/存档/调度；仅替代 Native，不代表 RU 实机验收。"""
import os
from pathlib import Path
import unittest
from lupa.lua51 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]
HOST = r'''
h=dofile('tools/rs_bag_action_test_host.lua')({disk=TEST_DISK,capacity=20,storageCapacity=20})
local S=h.S
function Map(sec,zone,stack)
 return {itemType=24581,category_id=9000022,name='Карта сокровищ',stackCount=stack or 1,
 longitudeDir='E',longitudeDeg=1,longitudeMin=0,longitudeSec=sec or 0,
 latitudeDir='N',latitudeDeg=2,latitudeMin=0,latitudeSec=0,zoneGroupId=zone}
end
h.nativeWrites=0
function h:MoveNow(slot)
 local item=assert(self.storage[slot],'Native received an empty/stale slot')
 for i=1,self.capacity do if not self.bag[i] then
  self.bag[i]=item;table.remove(self.storage,slot);return true
 end end
 return false
end
function X2Coffer:GetBagItemInfo(slot)
 h.inventoryReads=h.inventoryReads+1
 if h.failSlot==slot then error('read rejected')end
 return h.Copy(h.storage[slot] or {})
end
function X2Coffer:MoveToEmptyBagSlot(slot)
 h.nativeWrites=h.nativeWrites+1
 if h.rejectMove then return false end
 if h.delayMove then h.pendingSlot=slot;return true end
 return h:MoveNow(slot)
end
X2Unit.GetUnitWorldPositionByTarget=function()return 21504,nil,28672,0 end
S.GameIds={Zone={ById={[2]={continentKey='west'},[4]={continentKey='east'},[54]={continentKey='auroria'}}}}
dofile('features/life/shared/rs_life_slice_factory.lua')
dofile('data/rs_treasure_sea_points.lua');dofile('features/life/treasure/rs_treasure_sea_catalog.lua')
dofile('features/life/treasure/rs_treasure_feature.lua')
f=S.Features.Treasure
'''


class TreasureInventoryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.previous = Path.cwd()
        os.chdir(ROOT)

    @classmethod
    def tearDownClass(cls):
        os.chdir(cls.previous)

    def boot(self, disk=None, character=None):
        lua = LuaRuntime(unpack_returned_tuples=True)
        if disk is not None:
            lua.globals().TEST_DISK = lua.table_from(disk, recursive=True)
        lua.execute(HOST)
        if character is not None:
            lua.globals().TEST_CHARACTER = character
            lua.execute('X2Unit.UnitNameWithWorld=function()return TEST_CHARACTER end')
        source = ROOT / 'features/life/treasure/rs_treasure_inventory.lua'
        if source.exists():
            lua.execute(source.read_text(encoding='utf-8-sig'))
        self.assertIsNotNone(lua.globals().f.Inventory, '寻宝尚未接入坐标库存模块')
        lua.execute('''
        assert(f:Initialize());assert(f:Enable());assert(f:AcquireConsumer('test:inventory'))
        function h:Step()
         self.ms=self.ms+250
         if self.S.Scheduler.tasks.v3_life_treasure_withdraw then
          assert(self.S.Scheduler:RunTask('v3_life_treasure_withdraw'))
         end
        end
        function h:Drain() for i=1,40 do self:Step() end end
        function Refresh()assert(f:Refresh());return f:GetProjection()end
        function Group()for _,r in ipairs(f:GetProjection().rows)do if r.worldX==22528 then return r end end end
        ''')
        return lua

    def test_exact_coordinates_group_across_bag_and_three_replaced_box_snapshots(self):
        self.boot().execute('''
        h.bag={Map(0,2)};h.storage={Map(0,2),Map(0,2),Map(1,4)};Refresh()
        assert(f.Commands:RegisterCoffer(1));assert(f.Commands:RegisterCoffer(1))
        h.storage={Map(0,2)};assert(f.Commands:RegisterCoffer(2))
        h.storage={Map(0,2),Map(0,2),Map(0,2)};assert(f.Commands:RegisterCoffer(3))
        local p=Refresh();assert(#p.rows==2 and p.rows[1].count==7)
        assert(p.rows[1].bagCount==1 and p.rows[1].cofferCount==6)
        assert(p.rows[1].sourceText:find('箱1',1,true) and p.rows[1].sourceText:find('箱3',1,true))
        h.storage={};assert(f.Commands:RegisterCoffer(1));assert(Group().count==5)
        p.rows[1].count=99;assert(Group().count==5,'projection aliases authority')
        ''')

    def test_fractional_seconds_are_not_merged_by_truncated_display_text(self):
        self.boot().execute('''
        h.bag={Map(0.1,2),Map(0.2,2),Map(0.1,2)};local p=Refresh()
        assert(#p.rows==2 and p.rows[1].count==2 and p.rows[2].count==1)
        assert(p.rows[1].key~=p.rows[2].key)
        ''')

    def test_continent_filter_uses_item_region_and_allows_explicit_unknown_classification(self):
        self.boot().execute('''
        h.bag={Map(0,2),Map(1,4),Map(2,54),Map(3,36),Map(4)};local p=Refresh()
        for _,key in ipairs({'west','east','auroria','sea','unknown'})do
         assert(f.Commands:SetRegion(key));p=f:GetProjection();assert(#p.rows==1 and p.rows[1].continent==key)
        end
        local row=p.rows[1];assert(f.Commands:SetCoordinateContinent(row.key,'sea'))
        assert(#f:GetProjection().rows==0);assert(f.Commands:SetRegion('sea'));assert(#f:GetProjection().rows==2)
        assert(not f.Commands:SetRegion('invalid'));assert(not f.Commands:SetCoordinateContinent(row.key,'invalid'))
        assert(f.Commands:SetRegion('all'));assert(#f:GetProjection().rows==5)
        ''')

    def test_partial_scan_and_save_failure_keep_previous_box_counts(self):
        self.boot().execute('''
        h.storage={Map(0,2)};assert(f.Commands:RegisterCoffer(1));assert(Group().count==1)
        h.storage={Map(0,2),Map(0,2)};h.failSlot=2
        assert(not f.Commands:RegisterCoffer(1));assert(Group().count==1)
        h.failSlot=nil;h.failSave=true;assert(not f.Commands:RegisterCoffer(1));assert(Group().count==1)
        assert(h.clears==0)
        ''')

    def test_missing_coordinates_on_known_treasure_map_do_not_silently_replace_snapshot(self):
        self.boot().execute('''
        h.storage={Map(0,2)};assert(f.Commands:RegisterCoffer(1))
        h.storage={Map(0,2)};h.storage[1].longitudeSec=nil
        assert(not f.Commands:RegisterCoffer(1));assert(Group().count==1)
        h.storageVisible=false;assert(not f.Commands:RegisterCoffer(2))
        ''')

    def test_withdraw_two_maps_rechecks_compressed_slots_and_counts_observed_moves(self):
        self.boot().execute('''
        h.storage={Map(0,2),Map(0,2),Map(1,4)};assert(f.Commands:RegisterCoffer(1))
        local key=Group().key;assert(f.Commands:WithdrawCoordinate(1,key,2));h:Drain()
        local p=Refresh();assert(h.nativeWrites==2 and #h.bag==2 and #h.storage==1)
        assert(Group().count==2 and Group().bagCount==2 and Group().cofferCount==0)
        assert(p.withdraw.status=='done' and p.withdraw.moved==2)
        ''')

    def test_native_rejection_delay_and_timeout_do_not_invent_success_or_repeat_writes(self):
        for mode in ('rejectMove', 'delayMove'):
            with self.subTest(mode=mode):
                self.boot().execute('''
                h.storage={Map(0,2)};assert(f.Commands:RegisterCoffer(1))
                h.MODE=true;assert(f.Commands:WithdrawCoordinate(1,Group().key,1));h:Drain()
                assert(h.nativeWrites==1 and f:GetProjection().withdraw.moved==0)
                assert(f:GetProjection().withdraw.status=='failed')
                if h.delayMove then assert(f:GetProjection().inventoryUncertain and Group().count==0 and Group().uncertainCount==1)
                else assert(Group().count==1)end
                '''.replace('h.MODE', 'h.' + mode))

    def test_delayed_native_move_is_confirmed_on_a_later_tick(self):
        self.boot().execute('''
        h.storage={Map(0,2)};assert(f.Commands:RegisterCoffer(1));h.delayMove=true
        assert(f.Commands:WithdrawCoordinate(1,Group().key,1));h:Step();h:Step()
        assert(f:GetProjection().withdraw.moved==0 and h.nativeWrites==1)
        assert(h:MoveNow(h.pendingSlot));h:Step();h:Drain()
        assert(f:GetProjection().withdraw.moved==1 and h.nativeWrites==1)
        ''')

    def test_changed_box_closed_window_full_bag_and_disable_stop_without_wrong_move(self):
        for action in ('h.storage={Map(1,4)}', 'h.storageVisible=false',
                       "for i=1,h.capacity do h.bag[i]={itemType=100+i,name='other'}end",
                       "assert(f:Disable('test'))", 'assert(f.Commands:CancelWithdrawal())'):
            with self.subTest(action=action):
                self.boot().execute('''
                h.storage={Map(0,2),Map(0,2)};assert(f.Commands:RegisterCoffer(1))
                assert(f.Commands:WithdrawCoordinate(1,Group().key,2))
                ACTION;h:Drain();assert(h.nativeWrites==0)
                assert(not h.S.Scheduler.tasks.v3_life_treasure_withdraw)
                '''.replace('ACTION', action))

    def test_register_different_box_and_duplicate_withdraw_are_rejected_during_job(self):
        self.boot().execute('''
        h.storage={Map(0,2),Map(0,2)};assert(f.Commands:RegisterCoffer(1))
        assert(f.Commands:WithdrawCoordinate(1,Group().key,2))
        assert(not f.Commands:RegisterCoffer(2));assert(not f.Commands:WithdrawCoordinate(1,Group().key,1))
        assert(f.Commands:CancelWithdrawal());h:Drain();assert(h.nativeWrites==0)
        ''')

    def test_new_store_roundtrip_keeps_old_treasure_store_canonical_unchanged(self):
        lua = self.boot()
        lua.execute('''
        oldState=h.Copy(f.State)
        h.storage={Map(0,2),Map(0,2)};assert(f.Commands:RegisterCoffer(1))
        assert(f.Commands:SetCoordinateContinent(Group().key,'east'));assert(f.Commands:SetRegion('east'))
        assert(f.State.inventory==nil and f.State.boxes==nil and f.State.continentFilter==nil)
        assert(f.Inventory.storeId~='v3.life.treasure')
        local store=h.S.Persistence:GetStore(f.Inventory.storeId)
        assert(store.scope==h.S.Persistence.Scope.Character)
        ''')
        # Re-initialize within the same VM with a fresh module state and an unloaded Store.
        lua.execute('''
        local I=f.Inventory;I.loaded=false;I.State={filter='all',sort='count',boxes={},overrides={}}
        h.S.Persistence:GetStore(I.storeId).loaded=false
        assert(I:Initialize());I:RebuildGroups()
        assert(Group().count==2 and Group().continent=='east' and f:GetProjection().region=='east')
        assert(f:GetProjection().boundCofferId==nil,'reload revived a physical box binding')
        ''')

    def test_ui_register_assign_filter_and_withdraw_controls_use_feature_commands(self):
        lua=self.boot()
        lua.execute((ROOT/'presentation/v3/widgets/rs_v3_treasure_controls.lua').read_text(encoding='utf-8-sig'))
        lua.execute('''
        local S=h.S;local parent=h.Native(nil,'inventory_controls_parent',0,0,700,240)
        local body=assert(S.RSUI:VerticalBox({id='inventory_controls_body',parent=parent,gap=4}))
        h.storage={Map(0,2),Map(0,2)}
        local c=S.UIV3.TreasureControlsV3:Build(body,f,'inventory_controls_',{
          onResult=function(ok,err)lastControlResult=ok;lastControlError=err;if controls then controls:Refresh(f:GetProjection())end end})
        controls=c
        assert(c.register,'缺少箱子登记按钮')
        h.failSave=true
        assert(not c.register.root.events.OnClick(c.register.root,'LeftButton'))
        assert(lastControlResult==false and lastControlError and not c.take.enabled,'保存失败没有通过界面操作反馈')
        h.failSave=false
        assert(c.register.root.events.OnClick(c.register.root,'LeftButton'));c:Refresh(f:GetProjection())
        assert(f.Commands:Select(Group().key));c:Refresh(f:GetProjection())
        assert(c.assign:SetValue('east'));assert(c.region:SetValue('east'));c:Refresh(f:GetProjection())
        assert(#f:GetProjection().rows==1 and c.take.enabled)
        assert(c.take.root.events.OnClick(c.take.root,'LeftButton'));h:Drain()
        assert(#h.bag==2)
        body:Layout(0,0,600,240)
        assert(c.register.root.width>70 and c.take.root.width>70,'控件没有获得实际布局')
        ''')

    def test_projection_and_diagnostics_do_not_scan_native_or_write_stores(self):
        self.boot().execute('''
        h.storage={Map(0,2)};assert(f.Commands:RegisterCoffer(1))
        local reads,writes=h.inventoryReads,h.writes
        for i=1,10 do f:GetProjection();f:GetHealth()end
        assert(h.inventoryReads==reads and h.writes==writes)
        ''')

    def test_published_inventory_update_already_contains_new_group_rows(self):
        self.boot().execute('''
        local seen
        h.S.Events:SubscribeInternal(f.UpdateTopic,{},function()seen=f:GetProjection()end)
        h.bag={Map(0,2),Map(0,2)};Refresh()
        assert(seen and #seen.rows==1 and seen.rows[1].count==2)
        ''')

    def test_persistence_callback_cannot_make_withdraw_use_a_replaced_slot(self):
        self.boot().execute('''
        h.storage={Map(0,2)};assert(f.Commands:RegisterCoffer(1))
        assert(f.Commands:WithdrawCoordinate(1,Group().key,1))
        local save=ADDON.SaveData;local changed=false
        ADDON.SaveData=function(self,...)
          local ok=save(self,...)
          if not changed then changed=true;h.storage={Map(1,4)}end
          return ok
        end
        h:Drain();assert(h.nativeWrites==0 and #h.bag==0)
        ''')

    def test_persisted_pending_move_requires_reregistration_after_reload(self):
        self.boot().execute('''
        h.storage={Map(0,2)};assert(f.Commands:RegisterCoffer(1));h.delayMove=true
        assert(f.Commands:WithdrawCoordinate(1,Group().key,1));h:Step()
        assert(f.Inventory.State.pendingCoffer=='1')
        assert(f.Commands:CancelWithdrawal());f.Inventory.loaded=false
        h.S.Persistence:GetStore(f.Inventory.storeId).loaded=false;assert(f.Inventory:Initialize())
        assert(Group().count==0 and Group().uncertainCount==1 and f:GetProjection().inventoryUncertain)
        assert(not f.Commands:WithdrawCoordinate(1,Group().key,1))
        h.delayMove=false;assert(f.Commands:RegisterCoffer(1));assert(Group().count==1)
        ''')

    def test_full_chest_snapshot_is_chunked_and_roundtrips_in_a_new_lua_vm(self):
        lua=self.boot()
        lua.execute('''
        h.storageCapacity=150
        for i=1,150 do local item=Map(0,2);item.longitudeDeg=1+math.floor((i-1)/60);item.longitudeSec=(i-1)%60;h.storage[i]=item end
        assert(f.Commands:RegisterCoffer(1));assert(f.Inventory.State.boxes['1'].records==150)
        local chunks=f.Inventory.State.boxes['1'].chunks;assert(#chunks>1)
        for _,chunk in ipairs(chunks)do assert(#chunk<=1024)end
        assert(f:GetProjection().coffers['1'].chunks==nil,'presentation copies serialized bulk data')
        ''')
        def plain(v):
            if hasattr(v, 'items'):
                return {k: plain(value) for k, value in v.items()}
            return v
        disk=plain(lua.globals().h.disk)
        fresh=self.boot(disk)
        fresh.execute("assert(#f:GetProjection().rows==150 and f:GetProjection().totalMapCount==150);assert(f:GetProjection().boundCofferId==nil)")

    def test_cached_only_selection_survives_refresh_and_fails_map_location_without_its_region(self):
        self.boot().execute('''
        h.storage={Map(0)};assert(f.Commands:RegisterCoffer(1))
        local key=Group().key;assert(f.Commands:Select(key));assert(f.Authority.selected.kind=='catalog')
        h.bag={Map(1,2)};Refresh();assert(f:GetProjection().selected.key==key)
        assert(not f.Commands:ShowSelectedOnMap())
        assert(f:GetProjection().selected.key==key)
        ''')

    def test_fractional_seconds_are_distinguishable_and_large_native_quantity_is_preserved(self):
        self.boot().execute('''
        h.storage={Map(0.1,2),Map(0.2,2),Map(1,2,300)}
        assert(f.Commands:RegisterCoffer(1));local p=f:GetProjection();assert(p.totalMapCount==302)
        assert(p.rows[2].text~=p.rows[3].text,'different exact coordinates have identical labels')
        ''')

    def test_selected_exact_coordinate_survives_identical_legacy_keys_after_reorder(self):
        for refresh in ('Refresh()', 'assert(f.Authority:CheckInventory())'):
            with self.subTest(refresh=refresh):
                self.boot().execute('''
                h.bag={Map(0.1,2),Map(0.2,2)};local p=Refresh();local key=p.rows[1].key
                assert(f.Commands:Select(key));h.bag={h.bag[2],h.bag[1]};REFRESH
                assert(f:GetProjection().selected.key==key,'slot reorder changed the selected exact coordinate')
                '''.replace('REFRESH', refresh))

    def test_four_value_native_window_geometry_uses_existing_storage_visibility_contract(self):
        self.boot().execute('''
        ADDON.GetContentMainScriptPosVis=function()return 100,100,400,500 end
        h.storage={Map(0,2)};assert(f.Commands:RegisterCoffer(1))
        ADDON.GetContentMainScriptPosVis=function()return 100,100,400,500,false end
        assert(not f.Commands:RegisterCoffer(1))
        ADDON.GetContentMainScriptPosVis=function()return nil end
        assert(not f.Commands:RegisterCoffer(1),'unknown visibility was treated as open')
        ADDON.GetContent=function()return {IsVisible=function()return true end}end
        assert(f.Commands:RegisterCoffer(1),'explicitly visible native content was ignored')
        ''')

    def test_cached_target_adopts_later_item_region_evidence(self):
        self.boot().execute('''
        h.storage={Map(0)};assert(f.Commands:RegisterCoffer(1));assert(f.Commands:Select(Group().key))
        h.bag={Map(0,2)};Refresh()
        assert(f.Authority.selected.kind=='catalog' and f.Authority.selected.zoneGroupId==2)
        ''')

    def test_registered_chests_are_isolated_between_characters(self):
        lua=self.boot(character='TreasureOne@World')
        lua.execute("h.storage={Map(0,2)};assert(f.Commands:RegisterCoffer(1))")
        def plain(value):
            return {k: plain(v) for k, v in value.items()} if hasattr(value, 'items') else value
        disk=plain(lua.globals().h.disk)
        self.boot(disk, character='TreasureTwo@World').execute("assert(#f:GetProjection().rows==0 and next(f.Inventory.State.boxes)==nil)")
        self.boot(disk, character='TreasureOne@World').execute("assert(Group().count==1)")

    def test_explicit_chest_scan_reads_each_slot_once(self):
        self.boot().execute('''
        h.storage={Map(0,2),Map(1,4)};local before=h.inventoryReads
        assert(f.Commands:RegisterCoffer(1));assert(h.inventoryReads-before<=h.storageCapacity)
        ''')


if __name__ == '__main__':
    unittest.main()

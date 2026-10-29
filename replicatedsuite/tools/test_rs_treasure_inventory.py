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
        function NextCoffer()
         h.S.Events:Dispatch('COFFER_INTERACTION_END')
         h.S.Events:Dispatch('COFFER_INTERACTION_START')
        end
        ''')
        return lua

    def floating(self):
        lua=self.boot()
        lua.execute('''
        local S=h.S
        S.UIV3.WidgetHost={Register=function()return true end,BindFeatureLifecycle=function()return true end}
        S.Features.Trade=f;S.Features.Bonds=f;S.Features.Fishing=f
        S.UI.CreateWindowShell=function()error('content test must not create a native root window')end
        dofile('ui/framework/rs_ui_floating_surface.lua')
        dofile('presentation/v3/widgets/rs_v3_life_economy_widgets.lua')
        parent=h.Native(nil,'withdraw_assistant_parent',0,0,390,240)
        content=assert(S.UIV3.LifeEconomyContent:Create(parent,'Treasure','withdraw_assistant_'))
        assert(content:Refresh())
        function Click(control)return control.root.events.OnClick(control.root,'LeftButton')end
        function SelectCoordinate(key)
         content:Refresh();content.content:Layout(0,0,390,240)
         for index=1,#f:GetProjection().rows do
          local item=content.table:GetItem(index)
          if item.key==key then
           local row=assert(content.table.list:GetRowForIndex(index))
           assert(Click(row));return
          end
         end
         error('coordinate is absent from the real table')
        end
        ''')
        return lua

    def test_floating_withdraws_all_selected_coordinates_from_current_box_and_preserves_other_sources(self):
        self.floating().execute('''
        local take=assert(content.treasureWithdrawButton,'assistant has no coordinate withdrawal button')
        assert(content.treasureCancelWithdrawButton,'assistant has no withdrawal cancellation button')
        h.storage={Map(0,2),Map(0,2),Map(0,2)};assert(Click(content.treasureIdentifyButton))
        NextCoffer();h.storage={Map(0,2),Map(0.1,2),Map(0,2),Map(2,4),Map(0,2),Map(0,2)}
        assert(Click(content.treasureIdentifyButton));local key=Group().key;SelectCoordinate(key)
        assert(take.enabled==true and f:GetProjection().boundCofferId=='2')
        local reads,writes=h.inventoryReads,h.writes
        for i=1,5 do content:Refresh()end
        assert(h.inventoryReads==reads and h.writes==writes,'button rendering performs inventory work')
        assert(Click(take));assert(h.nativeWrites==0,'click bypassed the serial withdrawal scheduler')
        assert(take.enabled==false and content.treasureCancelWithdrawButton.enabled==true)
        assert(f:GetProjection().withdraw.limit==4,'all was silently capped at the old two-map default')
        h:Step();content:Refresh()
        assert(h.nativeWrites==1 and f:GetProjection().withdraw.moved==0)
        assert(content.treasureInteractionHint.text:find('0/4',1,true),'sent move was presented as confirmed')
        h:Step();content:Refresh()
        assert(content.treasureInteractionHint.text:find('1/4',1,true),'confirmed progress is absent')
        h:Drain();content:Refresh()
        local p=Refresh()
        assert(h.nativeWrites==4 and #h.bag==4 and #h.storage==2)
        assert(h.storage[1].longitudeSec==0.1 and h.storage[2].longitudeSec==2,'a different exact coordinate was moved')
        assert(Group().cofferCount==3 and Group().bagCount==4 and Group().boxes['1']==3)
        assert(p.withdraw.status=='done' and p.withdraw.moved==4)
        assert(content.treasureInteractionHint.text:find('已取出 4 张',1,true))
        assert(take.enabled==false and content.treasureCancelWithdrawButton.enabled==false)
        content:DisposeHeaderSettings()
        ''')

    def test_floating_withdrawal_uses_the_latest_shared_selection_instead_of_its_old_projection(self):
        self.floating().execute('''
        h.storage={Map(0,2),Map(1,4),Map(0,2),Map(1,4),Map(1,4)}
        assert(Click(content.treasureIdentifyButton));local old=Group().key;SelectCoordinate(old)
        local target
        for _,row in ipairs(f:GetProjection().rows)do if row.key~=old then target=row.key end end
        assert(target and f.Commands:Select(target)) -- 另一个界面变更共享选择，当前浮窗尚未刷新。
        assert(content.treasureControlProjection.selected.groupKey==old)
        assert(Click(content.treasureWithdrawButton));assert(f.Inventory.job.key==target)
        h:Drain();content:Refresh()
        assert(h.nativeWrites==3 and #h.storage==2 and h.storage[1].longitudeSec==0 and h.storage[2].longitudeSec==0)
        content:DisposeHeaderSettings()
        ''')

    def test_floating_stop_button_stops_the_existing_job_without_a_second_native_move(self):
        self.floating().execute('''
        local take=assert(content.treasureWithdrawButton,'assistant has no coordinate withdrawal button')
        local stop=assert(content.treasureCancelWithdrawButton,'assistant has no stop button')
        h.storage={Map(0,2),Map(0,2),Map(0,2)};assert(Click(content.treasureIdentifyButton))
        SelectCoordinate(Group().key);assert(Click(take));h:Step();h:Step();content:Refresh()
        assert(f:GetProjection().withdraw.moved==1 and h.nativeWrites==1)
        assert(Click(stop));h:Drain();content:Refresh()
        assert(f:GetProjection().withdraw.status=='cancelled' and h.nativeWrites==1 and #h.storage==2)
        assert(content.treasureInteractionHint.text:find('已停止',1,true))
        assert(stop.enabled==false and take.enabled==false)
        assert(Click(content.treasureIdentifyButton));assert(f:GetProjection().scannedCofferCount==1)
        assert(take.enabled==true,'same-box rescan cannot resume remaining maps')
        content:DisposeHeaderSettings()
        ''')

    def test_floating_withdrawal_requires_current_box_and_selected_coordinate_and_fits_compact_windows(self):
        self.floating().execute('''
        local take=assert(content.treasureWithdrawButton,'assistant has no coordinate withdrawal button')
        local stop=assert(content.treasureCancelWithdrawButton)
        assert(take.enabled==false and stop.enabled==false)
        h.bag={Map(2,4)};Refresh();h.storage={Map(0,2)};assert(Click(content.treasureIdentifyButton))
        SelectCoordinate(f.Inventory.CoordinateKey(f.Authority.maps[1]));assert(take.enabled==false)
        SelectCoordinate(Group().key);assert(take.enabled==true)
        for _,width in ipairs({240,390,640})do for _,height in ipairs({140,240})do
         parent.width,parent.height=width,height;content.content:Layout(0,0,width,height)
         for _,button in ipairs({content.treasureIdentifyButton,take,stop,content.treasureMapButton})do
          local visible,why=h:VisibleRect(button);assert(visible,why)
         end
        end end
        NextCoffer();content:Refresh();assert(take.enabled==false)
        assert(not Click(take) and h.nativeWrites==0)
        assert(f.Commands:SetViewKind('ships'));content:Refresh()
        assert(content.treasureWithdrawRow.visible==false,'storage actions leak into the sea view')
        content:DisposeHeaderSettings()
        ''')

    def test_floating_reports_full_bag_and_switching_box_stops_withdrawal(self):
        for mode in ('full', 'switch', 'reject'):
            with self.subTest(mode=mode):
                lua=self.floating();lua.globals().MODE=mode
                lua.execute('''
                local take=assert(content.treasureWithdrawButton,'assistant has no coordinate withdrawal button')
                h.storage={Map(0,2),Map(0,2)};assert(Click(content.treasureIdentifyButton))
                SelectCoordinate(Group().key)
                if MODE=='full' then for i=1,h.capacity do h.bag[i]={itemType=100+i,name='other'}end end
                if MODE=='reject' then h.rejectMove=true end
                assert(Click(take))
                if MODE=='switch' then NextCoffer()end
                h:Drain();content:Refresh()
                assert(f.Inventory.job==nil and content.treasureCancelWithdrawButton.enabled==false)
                if MODE=='full' then
                 assert(h.nativeWrites==0 and content.treasureInteractionHint.text:find('背包已满',1,true))
                elseif MODE=='switch' then
                 assert(h.nativeWrites==0 and content.treasureInteractionHint.text:find('关闭或切换',1,true))
                else
                 local err=f:GetProjection().withdraw.error
                 assert(h.nativeWrites==1 and err and content.treasureInteractionHint.text:find(err,1,true))
                end
                content:DisposeHeaderSettings()
                ''')

    def test_exact_coordinates_group_across_bag_and_three_replaced_box_snapshots(self):
        self.boot().execute('''
        h.bag={Map(0,2)};h.storage={Map(0,2),Map(0,2),Map(1,4)};Refresh()
        assert(f.Commands:RegisterCoffer(1));assert(f.Commands:RegisterCoffer(1))
        h.storage={Map(0,2)};assert(f.Commands:RegisterCoffer(2))
        h.storage={Map(0,2),Map(0,2),Map(0,2)};assert(f.Commands:RegisterCoffer(3))
        local p=Refresh();assert(#p.rows==2 and p.rows[1].count==7)
        assert(p.rows[1].bagCount==1 and p.rows[1].cofferCount==6)
        assert(p.rows[1].sourceText:find('记录1',1,true) and p.rows[1].sourceText:find('记录3',1,true))
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
        assert(c.box==nil,'one-click recognition still requires a manual chest selection')
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

    def test_current_coffer_button_starts_a_round_and_appends_without_choosing_box_ids(self):
        self.boot().execute('''
        h.storage={Map(9,2)};assert(f.Commands:RegisterCoffer(3))
        h.storage={Map(0,2),Map(0,2)};assert(f.Commands:IdentifyCurrentCoffer())
        local p=f:GetProjection();assert(p.scannedCofferCount==1 and p.sharedCoordinateCount==0)
        assert(f.Inventory.State.boxes['3']==nil,'legacy numbered records leaked into the new round')
        NextCoffer();h.storage={Map(0,2),Map(1,4)};assert(f.Commands:IdentifyCurrentCoffer())
        p=f:GetProjection();assert(p.scannedCofferCount==2 and p.sharedCoordinateCount==1)
        assert(Group().cofferCount==3 and Group().cofferSourceCount==2)
        assert(p.boundCofferId=='2' and p.cofferItems==nil,'manual box selector survived the one-button workflow')
        ''')

    def test_identical_boxes_are_separate_scans_but_same_box_stacks_are_not_cross_box_matches(self):
        self.boot().execute('''
        h.bag={Map(0,2)};h.storage={Map(0,2),Map(0,2)};Refresh()
        assert(f.Commands:IdentifyCurrentCoffer());assert(f:GetProjection().sharedCoordinateCount==0)
        NextCoffer();assert(f.Commands:IdentifyCurrentCoffer()) -- 两个物理箱可有完全相同内容。
        local p=f:GetProjection();assert(p.scannedCofferCount==2 and p.sharedCoordinateCount==1)
        assert(Group().count==5 and Group().cofferCount==4 and Group().cofferSourceCount==2)
        ''')

    def test_more_than_thirty_two_scans_grow_dynamically_and_reset_preserves_bag_maps(self):
        self.boot().execute('''
        h.bag={Map(0,2)};Refresh();h.storageCapacity=1
        for i=1,35 do NextCoffer();h.storage={Map(0,2)};assert(f.Commands:IdentifyCurrentCoffer()) end
        local p=f:GetProjection();assert(p.scannedCofferCount==35 and Group().cofferSourceCount==35)
        assert(Group().cofferCount==35 and p.boundCofferId=='35')
        assert(f.Commands:ResetCofferRound());p=f:GetProjection()
        assert(p.scannedCofferCount==0 and p.sharedCoordinateCount==0 and Group().count==1)
        assert(p.boundCofferId==nil and next(f.Inventory.State.boxes)==nil)
        assert(f.Commands:IdentifyCurrentCoffer());assert(f:GetProjection().boundCofferId=='1')
        ''')

    def test_failed_first_identification_does_not_clear_legacy_or_append_partial_records(self):
        self.boot().execute('''
        h.storage={Map(0,2)};assert(f.Commands:RegisterCoffer(2))
        h.storageVisible=false;assert(not f.Commands:IdentifyCurrentCoffer())
        h.storageVisible=true;h.failSlot=2;assert(not f.Commands:IdentifyCurrentCoffer())
        h.failSlot=nil;h.failSave=true;assert(not f.Commands:IdentifyCurrentCoffer())
        assert(f.Inventory.State.boxes['2'] and Group().count==1 and not f.Inventory.State.scanRound)
        h.failSave=false;assert(f.Commands:IdentifyCurrentCoffer())
        h.failSave=true;assert(not f.Commands:ResetCofferRound())
        assert(f:GetProjection().scannedCofferCount==1 and Group().count==1)
        ''')

    def test_round_survives_reload_and_clear_and_scan_are_blocked_during_withdrawal(self):
        self.boot().execute('''
        h.storage={Map(0,2)};assert(f.Commands:IdentifyCurrentCoffer())
        local I=f.Inventory;I.loaded=false;h.S.Persistence:GetStore(I.storeId).loaded=false
        assert(I:Initialize());assert(f:GetProjection().scannedCofferCount==1)
        h.storage={Map(1,4)};assert(f.Commands:IdentifyCurrentCoffer())
        assert(f:GetProjection().scannedCofferCount==2 and I.State.boxes['1'])
        local row=f:GetProjection().rows[2];assert(f.Commands:WithdrawCoordinate('2',row.key,1))
        assert(not f.Commands:ResetCofferRound());assert(not f.Commands:IdentifyCurrentCoffer())
        assert(f:GetProjection().scannedCofferCount==2);assert(f.Commands:CancelWithdrawal())
        ''')

    def test_floating_button_scans_real_inventory_and_settings_clear_the_same_round(self):
        self.boot().execute('''
        local S=h.S
        S.UIV3.WidgetHost={Register=function()return true end,BindFeatureLifecycle=function()return true end}
        S.Features.Trade=f;S.Features.Bonds=f;S.Features.Fishing=f
        S.UI.CreateWindowShell=function()error('content test must not create a native root window')end
        dofile('ui/framework/rs_ui_floating_surface.lua')
        dofile('presentation/v3/widgets/rs_v3_life_economy_widgets.lua')
        local parent=h.Native(nil,'coffer_assistant_parent',0,0,390,240)
        local content=assert(S.UIV3.LifeEconomyContent:Create(parent,'Treasure','coffer_assistant_'))
        local button=assert(content.treasureIdentifyButton,'floating assistant has no one-click coffer recognition')
        h.storage={Map(0,2)}
        assert(button.root.events.OnClick(button.root,'LeftButton'))
        assert(f:GetProjection().scannedCofferCount==1)
        assert(button.root.events.OnClick(button.root,'LeftButton'))
        assert(f:GetProjection().scannedCofferCount==1 and f:GetProjection().sharedCoordinateCount==0)
        NextCoffer();assert(button.root.events.OnClick(button.root,'LeftButton'))
        assert(f:GetProjection().sharedCoordinateCount==1)
        assert(content.treasureInteractionHint.text:find('跨箱同坐标 1',1,true))
        for _,width in ipairs({240,390,640})do
            parent.width=width;content.content:Layout(0,0,width,240)
            local visible,why=h:VisibleRect(button);assert(visible,why)
            assert(button.root.width>=108,'recognition button clipped in compact assistant')
        end
        assert(content.treasureSettingsDropdown:SetValue('clear_coffers'))
        assert(f:GetProjection().scannedCofferCount==0 and f:GetProjection().sharedCoordinateCount==0)
        h.storageVisible=false
        assert(not button.root.events.OnClick(button.root,'LeftButton'))
        assert(content.treasureInteractionHint.text:find('请先打开保管箱',1,true),'closed-box failure is invisible')
        assert(f.Commands:SetViewKind('ships'));content:Refresh();assert(button.visible==false)
        content:DisposeHeaderSettings()
        ''')

    def test_new_round_survives_a_fresh_vm_and_first_scan_clears_an_old_cached_target(self):
        lua=self.boot()
        lua.execute('''
        h.storage={Map(9,2)};assert(f.Commands:RegisterCoffer(3))
        local key=f:GetProjection().rows[1].key;assert(f.Commands:Select(key))
        h.storage={Map(0,2)};assert(f.Commands:IdentifyCurrentCoffer())
        assert(f:GetProjection().selected==nil,'old-round cached-only target survived the replacement')
        ''')
        def plain(value):
            return {k: plain(v) for k, v in value.items()} if hasattr(value, 'items') else value
        fresh=self.boot(plain(lua.globals().h.disk))
        fresh.execute('''
        assert(f:GetProjection().scannedCofferCount==1 and f:GetProjection().cofferRoundStarted)
        h.storage={Map(1,4)};assert(f.Commands:IdentifyCurrentCoffer())
        assert(f:GetProjection().scannedCofferCount==2 and f.Inventory.State.boxes['1'])
        ''')

    def test_repeated_clicks_update_the_same_open_box_even_after_contents_change(self):
        self.boot().execute('''
        h.storage={Map(0,2)};assert(f.Commands:IdentifyCurrentCoffer())
        for i=1,5 do h.ms=h.ms+1500;assert(f.Commands:IdentifyCurrentCoffer()) end
        assert(f:GetProjection().scannedCofferCount==1 and Group().count==1)
        assert(f:GetProjection().sharedCoordinateCount==0 and f:GetProjection().boundCofferId=='1')
        h.storage={Map(0,2),Map(0,2),Map(1,4)};assert(f.Commands:IdentifyCurrentCoffer())
        assert(f:GetProjection().scannedCofferCount==1 and Group().count==2)
        assert(f:GetProjection().totalMapCount==3 and f:GetProjection().sharedCoordinateCount==0)
        assert(f.Commands:CancelWithdrawal());assert(f.Commands:IdentifyCurrentCoffer())
        assert(f:GetProjection().scannedCofferCount==1,'withdrawal binding was used as box identity')
        ''')

    def test_coffer_start_alone_invalidates_the_binding_and_stops_pending_withdrawal(self):
        self.boot().execute('''
        h.storage={Map(0,2)};assert(f.Commands:IdentifyCurrentCoffer())
        assert(f.Commands:WithdrawCoordinate('1',Group().key,1))
        h.S.Events:Dispatch('COFFER_INTERACTION_START');h:Drain()
        assert(h.nativeWrites==0 and f.Inventory.job==nil and f.Inventory.bound==nil)
        assert(f.Commands:IdentifyCurrentCoffer())
        assert(f:GetProjection().scannedCofferCount==2 and Group().cofferSourceCount==2)
        ''')

    def test_coffer_switch_during_withdrawal_scan_cancels_without_using_a_stale_binding(self):
        for stage in ('validate', 'step'):
            with self.subTest(stage=stage):
                lua=self.boot();lua.globals().STAGE=stage
                lua.execute('''
                h.storage={Map(0,2)};assert(f.Commands:IdentifyCurrentCoffer())
                if STAGE=='step' then assert(f.Commands:WithdrawCoordinate('1',Group().key,1))end
                local read=X2Coffer.GetBagItemInfo;local changed=false
                X2Coffer.GetBagItemInfo=function(self,...)
                 if not changed then changed=true;NextCoffer()end
                 return read(self,...)
                end
                if STAGE=='validate' then assert(not f.Commands:WithdrawCoordinate('1',Group().key,1))
                else h:Drain()end
                assert(changed and h.nativeWrites==0 and f.Inventory.job==nil)
                ''')

    def test_coffer_switch_during_move_confirmation_keeps_the_job_cancelled(self):
        for stage in ('coffer', 'bag', 'save'):
            with self.subTest(stage=stage):
                lua=self.boot();lua.globals().STAGE=stage
                lua.execute('''
                h.storage={Map(0,2),Map(0,2)};assert(f.Commands:IdentifyCurrentCoffer())
                assert(f.Commands:WithdrawCoordinate('1',Group().key,2));h:Step()
                assert(h.nativeWrites==1 and f.Inventory.State.pendingCoffer=='1')
                local changed=false
                local function Switch()if not changed then changed=true;NextCoffer()end end
                if STAGE=='save' then
                 local save=ADDON.SaveData
                 ADDON.SaveData=function(self,...)local ok=save(self,...);Switch();return ok end
                elseif STAGE=='coffer' then
                 local read=X2Coffer.GetBagItemInfo
                 X2Coffer.GetBagItemInfo=function(self,...)Switch();return read(self,...)end
                else
                 local read=X2Bag.GetBagItemInfo
                 X2Bag.GetBagItemInfo=function(self,...)Switch();return read(self,...)end
                end
                h:Drain()
                assert(changed and h.nativeWrites==1 and f.Inventory.job==nil and not f.Inventory.bound)
                ''')

    def test_window_close_fallback_releases_record_without_scanning_or_saving(self):
        self.boot().execute('''
        h.storage={Map(0,2)};assert(f.Commands:IdentifyCurrentCoffer())
        local writes,reads=h.writes,h.inventoryReads
        h.storageVisible=false;f.Authority:CheckInventory()
        assert(h.writes==writes and h.inventoryReads==reads)
        h.storageVisible=true;assert(f.Commands:IdentifyCurrentCoffer())
        assert(f:GetProjection().scannedCofferCount==2)
        ''')

    def test_coffer_event_ownership_is_released_and_reacquired_once_with_demand(self):
        self.boot().execute('''
        local E=h.S.Events
        local function Count()
         local n=0
         for _,listeners in pairs(E.listeners)do for _,row in ipairs(listeners)do
          if row.owner==f.Inventory then n=n+1 end
         end end
         return n
        end
        assert(Count()==2,'coffer lifecycle is not observed')
        assert(f:ReleaseConsumer('test:inventory'));assert(Count()==0)
        assert(f:AcquireConsumer('test:inventory'));assert(Count()==2)
        assert(f:AcquireConsumer('test:inventory:second'));assert(Count()==2)
        assert(f:Disable());assert(Count()==0)
        ''')

    def test_failed_update_keeps_the_same_record_and_a_coffer_switch_during_scan_is_rejected(self):
        self.boot().execute('''
        h.storage={Map(0,2)};assert(f.Commands:IdentifyCurrentCoffer())
        h.storage={Map(0,2),Map(0,2)};h.failSave=true
        assert(not f.Commands:IdentifyCurrentCoffer());assert(Group().count==1)
        h.failSave=false;assert(f.Commands:IdentifyCurrentCoffer())
        assert(f:GetProjection().scannedCofferCount==1 and Group().count==2)
        local read=X2Coffer.GetBagItemInfo;local changed=false
        X2Coffer.GetBagItemInfo=function(self,slot)
         if not changed then changed=true;NextCoffer()end
         return read(self,slot)
        end
        assert(not f.Commands:IdentifyCurrentCoffer(),'a scan spanning two interactions was committed')
        assert(f:GetProjection().scannedCofferCount==1)
        ''')

    def test_global_coffer_events_use_the_shared_bridge_and_preserve_other_owners(self):
        self.boot().execute('''
        local E,I=h.S.Events,f.Inventory;I:WatchCofferInteraction(false)
        local handlers,releases={},0
        UIParent.SetEventHandler=function(_,name,callback)handlers[name]=callback end
        UIParent.ReleaseEventHandler=function(_,name,callback)
         assert(handlers[name]==callback);handlers[name]=nil;releases=releases+1
        end
        E.running=true;I:WatchCofferInteraction(true)
        assert(I.cofferEventChannels.COFFER_INTERACTION_START=='global')
        local other,received={},0
        assert(E:SubscribeGlobalOptional('COFFER_INTERACTION_START',other,function()received=received+1 end))
        h.storage={Map(0,2)};assert(f.Commands:IdentifyCurrentCoffer())
        local reads,writes=h.inventoryReads,h.writes
        handlers.COFFER_INTERACTION_START()
        assert(I.openRecord==nil and I.bound==nil and I.cofferEventCount==1)
        assert(I.lastCofferBoundary=='COFFER_INTERACTION_START')
        assert(h.inventoryReads==reads and h.writes==writes,'event scanned or saved a box')
        assert(f.Commands:IdentifyCurrentCoffer());assert(f:GetProjection().scannedCofferCount==2)
        I:WatchCofferInteraction(false);assert(releases==1 and handlers.COFFER_INTERACTION_START)
        local count=I.cofferEventCount;handlers.COFFER_INTERACTION_START()
        assert(I.cofferEventCount==count and received==2)
        E:UnsubscribeGlobalOwner(other);assert(releases==2)
        ''')

    def test_large_multi_box_snapshot_uses_shared_paging_and_keeps_previous_round_on_failure(self):
        self.boot().execute('''
        h.storageCapacity=200
        for i=1,200 do local item=Map(0,2);item.longitudeDeg=1+math.floor((i-1)/60);item.longitudeSec=(i-1)%60;h.storage[i]=item end
        assert(f.Commands:IdentifyCurrentCoffer())
        NextCoffer();assert(f.Commands:IdentifyCurrentCoffer())
        local I,P=f.Inventory,h.S.Persistence;local store=P:GetStore(I.storeId)
        assert(store.nativePaged==true and h.disk[store.resolvedKey].__rsPaged,'large snapshot must use shared transactional paging')
        for _,raw in pairs(h.disk)do
            assert(h.S.PersistenceTransport.EstimateNativeBytes(raw)<=14336,'physical save exceeds the native budget')
        end
        I.loaded=false;store.loaded=false;assert(I:Initialize())
        assert(f:GetProjection().scannedCofferCount==2 and f:GetProjection().totalMapCount==400)
        h.failSave=true;assert(not f.Commands:ResetCofferRound());h.failSave=false
        assert(f:GetProjection().scannedCofferCount==2 and f:GetProjection().totalMapCount==400,'failed reset lost the previous full snapshot')
        I.loaded=false;store.loaded=false;assert(I:Initialize())
        assert(f:GetProjection().totalMapCount==400,'failed reset changed durable data')
        ''')

    def test_corrupt_snapshot_keeps_recovery_ui_and_is_reset_only_by_explicit_command(self):
        self.boot().execute('''
        h.storage={Map(0,2)};assert(f.Commands:IdentifyCurrentCoffer())
        local I,P=f.Inventory,h.S.Persistence;local store=P:GetStore(I.storeId)
        local raw=h.disk[store.resolvedKey]
        raw.payload.boxes['1'].chunks[1]='truncated snapshot'
        I.loaded=false;store.loaded=false
        local writes=h.writes
        assert(f:Initialize(),'corrupt derived records locked the entire feature')
        assert(not I.loaded and store.writeFenced and h.writes==writes)
        local unavailable=f:GetProjection()
        assert(unavailable.scannedCofferCount==0 and unavailable.inventoryError and unavailable.inventoryRepairable)
        assert(unavailable.inventoryHint:find('修复损坏记录',1,true))
        assert(not f.Commands:IdentifyCurrentCoffer());assert(h.writes==writes)
        h.failSave=true;assert(not f.Commands:ResetCofferRound())
        assert(not I.loaded and store.writeFenced)
        h.failSave=false;assert(f.Commands:ResetCofferRound())
        assert(I.loaded and not store.writeFenced and f:GetProjection().scannedCofferCount==0)
        assert(not f:GetProjection().inventoryRepairable and f:GetProjection().inventoryHint:find('放弃 1',1,true))
        assert(store.lastVerifyOk==true and not store.needsBarrierVerify)
        assert(f.Commands:IdentifyCurrentCoffer());assert(f:GetProjection().scannedCofferCount==1)
        I.loaded=false;store.loaded=false;assert(I:Initialize())
        assert(f:GetProjection().scannedCofferCount==1)
        ''')

    def test_reset_cannot_override_future_schema(self):
        self.boot().execute('''
        h.storage={Map(0,2)};assert(f.Commands:IdentifyCurrentCoffer())
        local I,P=f.Inventory,h.S.Persistence;local store=P:GetStore(I.storeId)
        local version=store.schemaVersion;store.schemaVersion=version+1
        assert(P:SaveStore(I.storeId,{durable=true}));store.schemaVersion=version
        I.loaded=false;store.loaded=false;local writes=h.writes
        assert(f:Initialize());assert(not I.loaded)
        assert(not f.Commands:ResetCofferRound());assert(h.writes==writes)
        ''')

    def test_reset_cannot_override_temporary_load_failure(self):
        self.boot().execute('''
        h.storage={Map(0,2)};assert(f.Commands:IdentifyCurrentCoffer())
        local I,P=f.Inventory,h.S.Persistence;local store=P:GetStore(I.storeId)
        I.loaded=false;store.loaded=false;local writes=h.writes
        h.S.Api.LoadData=function()return nil,'temporary read failure' end
        assert(f:Initialize());assert(not I.loaded)
        assert(not f.Commands:ResetCofferRound());assert(h.writes==writes)
        ''')


    def test_decoder_accepts_long_and_crlf_chunks_and_salvages_a_truncated_tail(self):
        self.boot().execute('''
        local I=f.Inventory
        local line='100.5|200.5|0|1|W 1 2\\n'
        -- 落盘后块比内存切块长：读回上限必须容得下，否则整箱记录被判成损坏后连坐整个存档。
        local long=string.rep(line,80)
        assert(#long>1024 and #long<=2048)
        assert(#I.DecodeBox({records=80,chunks={long}})==80)
        -- 客户端把换行写成 \\r\\n，行尾的 \\r 不能被当成控制字符拒收。
        assert(#I.DecodeBox({records=80,chunks={string.rep('100.5|200.5|0|1|W 1 2\\r\\n',80)}})==80)
        -- 末块被 UDF 截断：正常读取必须拒绝，重建路径保留前面完整的记录。
        local cut=long..'100.5|200.5|0|1|W'
        assert(not pcall(I.DecodeBox,{records=81,chunks={cut}}))
        assert(#I.DecodeBox({records=81,chunks={cut}},true)==80)
        -- 只有末块允许不闭合；中间块断了说明不是尾部截断，抢救也不能放过。
        assert(not pcall(I.DecodeBox,{records=81,chunks={cut,'100.5|200.5|0|1|W 3 4\\n'}},true))
        ''')


    def legacy_shards(self, lua):
        lua.execute('''
        local I,P=f.Inventory,h.S.Persistence
        local root=h.Copy(I.State)
        for id,box in pairs(root.boxes)do
            local storeId='v3.life.treasure.box.'..id
            if not P:GetStore(storeId)then
                assert(P:RegisterV3Store({id=storeId,owner='v3.life.treasure',scope=P.Scope.Character,lifetime=P.Lifetime.Permanent,
                    schemaVersion=1,legacySchemaVersion=0,key=P.V3KeyPrefix..'v3_life_treasure_box_'..id,
                    budget={maxDepth=5,maxNodes=8000,maxEntriesPerTable=512,maxStringBytes=65536},
                    recoverableReplacement=true,default=function()return {records=0,chunks={},stamp=''}end,
                    get=function()return box end,apply=function()end}))
            end
            assert(P:PrepareRead(storeId));assert(P:SaveValue(storeId,box,{durable=true}))
            root.boxes[id]={records=box.records,stamp=box.stamp}
        end
        assert(P:SaveValue(I.storeId,root,{durable=true}))
        I.loaded=false;P:GetStore(I.storeId).loaded=false
        ''')

    def test_legacy_per_box_shards_import_without_writes_and_consolidate_on_explicit_change(self):
        lua=self.boot()
        lua.execute("h.storage={Map(0,2)};assert(f.Commands:IdentifyCurrentCoffer());NextCoffer();h.storage={Map(1,2)};assert(f.Commands:IdentifyCurrentCoffer())")
        self.legacy_shards(lua)
        lua.execute('''
        local I,P=f.Inventory,h.S.Persistence;local writes=h.writes
        assert(I:Initialize());assert(h.writes==writes,'import must not rewrite old shards during reads')
        assert(f:GetProjection().scannedCofferCount==2 and f:GetProjection().totalMapCount==2)
        assert(I:SetFilter('west'))
        local root=P:ReadPhysicalStore(P:GetStore(I.storeId),P:GetStore(I.storeId).resolvedKey)
        local decoded=P:DecodePhysicalEnvelope(root)
        assert(decoded.payload.boxes['1'].chunks and decoded.payload.boxes['2'].chunks,'explicit save did not consolidate old shards')
        I.loaded=false;P:GetStore(I.storeId).loaded=false;assert(I:Initialize())
        assert(f:GetProjection().totalMapCount==2)
        ''')

    def test_broken_legacy_shard_reset_preserves_later_healthy_boxes_and_retry_after_save_failure(self):
        lua=self.boot()
        lua.execute("h.storage={Map(0,2)};assert(f.Commands:IdentifyCurrentCoffer());NextCoffer();h.storage={Map(1,2)};assert(f.Commands:IdentifyCurrentCoffer())")
        self.legacy_shards(lua)
        lua.execute('''
        local I,P=f.Inventory,h.S.Persistence
        local bad=P:GetStore('v3.life.treasure.box.1');h.disk[bad.resolvedKey].payload.chunks[1]='truncated snapshot'
        bad.loaded=false
        assert(not I:Initialize())
        h.failSave=true;assert(not I:ResetCofferRound());h.failSave=false
        assert(I.State.boxes['2'] and I.State.boxes['2'].chunks,'failed repair lost the healthy box in memory')
        assert(I:ResetCofferRound())
        assert(not I.State.boxes['1'] and I.State.boxes['2'],'repair discarded an unvisited healthy shard')
        assert(f:GetProjection().scannedCofferCount==1 and f:GetProjection().totalMapCount==1)
        I.loaded=false;P:GetStore(I.storeId).loaded=false;assert(I:Initialize())
        assert(f:GetProjection().scannedCofferCount==1)
        ''')

    def test_legacy_shard_future_format_and_temporary_read_failure_cannot_be_discarded(self):
        for mode in ('future','temporary'):
            lua=self.boot()
            lua.execute("h.storage={Map(0,2)};assert(f.Commands:IdentifyCurrentCoffer())")
            self.legacy_shards(lua)
            lua.globals().TEST_FAILURE_MODE=mode
            lua.execute('''
            local I,P=f.Inventory,h.S.Persistence;local slice=P:GetStore('v3.life.treasure.box.1')
            if TEST_FAILURE_MODE=='future' then
                local version=slice.schemaVersion;slice.schemaVersion=version+1
                local box={records=1,chunks={I:Pack({maps={{worldX=22528,worldY=30720,count=1,text='W 1 0 0'}}}).chunks[1]},stamp=''}
                assert(P:SaveValue(slice.id,box,{durable=true}));slice.schemaVersion=version
            else
                local read=h.S.Api.LoadData
                h.S.Api.LoadData=function(self,key,...)if key==slice.resolvedKey then return nil,'temporary shard read failure' end return read(self,key,...)end
            end
            slice.loaded=false;local writes=h.writes
            assert(not I:Initialize());assert(not I:ResetCofferRound())
            assert(h.writes==writes and I.State.boxes['1'],'unknown/temporary shard failure was destructively repaired')
            ''')

    def test_recovery_preserves_empty_boxes_settings_stamps_and_pending_move(self):
        self.boot().execute('''
        local I,P=f.Inventory,h.S.Persistence;local store=P:GetStore(I.storeId)
        local value={filter='east',sort='coordinate',overrides={['coord:1:2']='sea'},pendingCoffer='3',scanRound=true,boxes={}}
        value.boxes['1']={records=1,chunks={'1|2|0|1|saved coordinate\\n'},stamp='original one'}
        value.boxes['2']={records=0,chunks={},stamp='original empty'}
        value.boxes['3']={records=2,chunks={'3|4|0|1|complete coordinate\\n5|6|0|1|second coordinate\\n'},stamp='original three'}
        assert(P:SaveValue(I.storeId,value,{durable=true}))
        local raw=h.disk[store.resolvedKey]
        raw.payload.boxes['3'].chunks[1]='3|4|0|1|complete coordinate\\ntruncated tail'
        local before=h.Copy(raw);I.loaded=false;store.loaded=false;assert(not I:Initialize())
        h.failSave=true;assert(not I:ResetCofferRound());h.failSave=false
        assert(P:FingerprintCanonicalValue(store,h.disk[store.resolvedKey])==P:FingerprintCanonicalValue(store,before),'failed repair changed old disk')
        assert(not I.loaded and store.writeFenced)
        assert(I:ResetCofferRound())
        assert(I.State.filter=='east' and I.State.sort=='coordinate' and I.State.overrides['coord:1:2']=='sea','repair discarded settings')
        assert(I.State.pendingCoffer=='3','repair confirmed an uncertain move')
        assert(I.State.boxes['2'] and I.State.boxes['2'].records==0,'repair discarded a valid empty box')
        assert(I.State.boxes['1'].chunks[1]==value.boxes['1'].chunks[1],'healthy box was repacked')
        for id,box in pairs(I.State.boxes)do assert(box.stamp==value.boxes[id].stamp,'repair invented a new scan timestamp')end
        assert(f:GetProjection().scannedCofferCount==3 and f:GetProjection().inventoryUncertain)
        I.loaded=false;store.loaded=false;assert(I:Initialize())
        assert(I.State.boxes['2'] and I.State.pendingCoffer=='3' and I.State.filter=='east')
        ''')

    def test_recovery_aborts_when_fenced_root_cannot_be_reread(self):
        self.boot().execute('''
        h.storage={Map(0,2)};assert(f.Commands:IdentifyCurrentCoffer())
        local I,P=f.Inventory,h.S.Persistence;local store=P:GetStore(I.storeId)
        h.disk[store.resolvedKey].payload.boxes['1'].chunks[1]='truncated tail'
        I.loaded=false;store.loaded=false;assert(not I:Initialize())
        local writes=h.writes
        h.S.Api.LoadData=function()return nil,'temporary read failure' end
        assert(not I:ResetCofferRound(),'failed reread was replaced with empty records')
        assert(h.writes==writes and not I.loaded)
        ''')

    def test_recovery_removes_broken_suffix_even_when_declared_records_are_complete(self):
        self.boot().execute('''
        h.storage={Map(0,2)};assert(f.Commands:IdentifyCurrentCoffer())
        local I,P=f.Inventory,h.S.Persistence;local store=P:GetStore(I.storeId)
        local box=h.disk[store.resolvedKey].payload.boxes['1']
        box.chunks[1]=box.chunks[1]..'broken suffix'
        I.loaded=false;store.loaded=false;assert(not I:Initialize())
        assert(I:ResetCofferRound());assert(f:GetProjection().totalMapCount==1)
        I.loaded=false;store.loaded=false;assert(I:Initialize())
        ''')

    def test_recovery_does_not_reuse_cached_ownership_for_a_new_future_root(self):
        self.boot().execute('''
        h.storage={Map(0,2)};assert(f.Commands:IdentifyCurrentCoffer())
        local I,P=f.Inventory,h.S.Persistence;local store=P:GetStore(I.storeId)
        local healthy=h.Copy(h.disk[store.resolvedKey])
        store.schemaVersion=store.schemaVersion+1
        assert(P:SaveValue(I.storeId,I.State,{durable=true}));store.schemaVersion=store.schemaVersion-1
        local future=h.Copy(h.disk[store.resolvedKey]);h.disk[store.resolvedKey]=healthy
        healthy.payload.boxes['1'].chunks[1]='truncated tail'
        I.loaded=false;store.loaded=false;assert(not I:Initialize())
        h.disk[store.resolvedKey]=future;local writes=h.writes
        assert(not I:ResetCofferRound());assert(h.writes==writes and not I.loaded)
        ''')

    def test_recovery_does_not_overwrite_a_newer_healthy_root(self):
        self.boot().execute('''
        h.storage={Map(0,2)};assert(f.Commands:IdentifyCurrentCoffer())
        local I,P=f.Inventory,h.S.Persistence;local store=P:GetStore(I.storeId)
        local healthy=h.Copy(h.disk[store.resolvedKey])
        h.disk[store.resolvedKey].payload.boxes['1'].chunks[1]='truncated tail'
        I.loaded=false;store.loaded=false;assert(not I:Initialize())
        h.disk[store.resolvedKey]=healthy;local writes=h.writes
        assert(not I:ResetCofferRound(),'repair became a clear after the fault disappeared')
        assert(h.writes==writes and I.loaded and f:GetProjection().totalMapCount==1)
        ''')

    def test_settings_distinguish_corrupt_repair_from_healthy_clear(self):
        lua=self.floating()
        lua.execute('''
        local function Label(p)
            for _,item in ipairs(content.treasureSettingsItems(p))do if item.value=='clear_coffers' then return item.text end end
        end
        assert(Label({inventoryRepairable=true}):find('修复损坏记录',1,true))
        assert(Label({inventoryRepairable=false}):find('清空本轮记录',1,true))
        ''')

    def test_explicit_corrupt_root_recovery_keeps_complete_lines_only_and_reports_loss(self):
        self.boot().execute('''
        h.storage={Map(0,2),Map(1,2)};assert(f.Commands:IdentifyCurrentCoffer())
        local I,P=f.Inventory,h.S.Persistence;local store=P:GetStore(I.storeId)
        local raw=h.disk[store.resolvedKey];local box=raw.payload.boxes['1']
        box.chunks[1]=box.chunks[1]:match('^([^\\n]+\\n)')..'truncated tail'
        I.loaded=false;store.loaded=false;assert(not I:Initialize())
        assert(I:ResetCofferRound())
        assert(f:GetProjection().scannedCofferCount==1 and f:GetProjection().totalMapCount==1)
        assert(I.lastError:find('抢救 1',1,true) and I.lastError:find('放弃 1',1,true),'partial recovery did not disclose discarded lines')
        I.loaded=false;store.loaded=false;assert(I:Initialize());assert(f:GetProjection().totalMapCount==1)
        ''')

if __name__ == '__main__':
    unittest.main()

"""中文维护：Lua 5.1 执行真实寻宝/Theme；Native 替身只证明离线契约，不代表 RU 像素验收。"""
from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]

HOST = r'''
local function Copy(t)
 if type(t)~='table' then return t end
 local r={};for k,v in pairs(t)do r[k]=Copy(v)end;return r
end
H={now=0,scans=0,reads=0,tasks={},items={},fail=false,events={},points={}}
local function Item(sec)return {name='map',itemType=1,longitudeDir='E',longitudeDeg=0,longitudeMin=0,longitudeSec=sec or 0,latitudeDir='N',latitudeDeg=0,latitudeMin=0,latitudeSec=0}end
H.items[1]=Item(0);H.Item=Item
ReplicatedSuite={Features={},Services={},Persistence={},FeatureRuntime={RegisterImplementation=function()return true end},NowMs=function()return H.now end}
local S=ReplicatedSuite
S.Demand={Create=function()return {Clear=function()return true end}end}
S.Events={Publish=function(_,topic,...)H.events[topic]={...};return true end}
S.Scheduler={AddTask=function(_,id,ms,fn)H.tasks[id]={ms=ms,fn=fn};return true end,RemoveTask=function(_,id)H.tasks[id]=nil end,SetTaskModule=function()end}
S.Scheduler.AddHighFrequencyTask=S.Scheduler.AddTask -- 中文维护：通道存在性保留；下方单独使用真实 Scheduler 验证间隔。
S.LifeSliceFactory={Copy=Copy,Number=tonumber,Text=function(v)return tostring(v or '')end,Action=function()return true end,
 Call=function()return true,21503,nil,28672,0 end,
 InstallLifeWidgetContract=function(f)function f:GetWidgetVisible()return self.State.widgetVisible end end,
 RegisterStore=function()end,LoadStore=function()return true end,
 PersistLifeMutation=function(f,_,fn)return fn(f.State)end,
 PublishFeatureUpdate=function(f,rev,reason)return S.Events:Publish(f.UpdateTopic,rev,reason)end}
S.Api={IsCapabilityAllowed=function()return true end}
S.Services.InventorySnapshotV3={
 BuildSnapshot=function()
  H.scans=H.scans+1;if H.fail then return nil,'read failed' end
  local r={rows={},bagId=1,readErrors=0};for slot in pairs(H.items)do r.rows[#r.rows+1]={slot=slot,itemType=1}end;return r
 end,
 ReadSlot=function(_,_,slot)H.reads=H.reads+1;if H.fail then return false,nil,'read failed' end;return true,H.items[slot] end,
 ReadPhysicalBagSlot=function(_,slot)H.reads=H.reads+1;return true,H.items[slot],nil,1 end}
S.Services.ScreenProjectionV3={
 GetUnitWorldPosition=function(_,_,isLocal)if isLocal then return 100,200,10 end;return 21503,28672,0 end,
 ProjectWorldBatch=function(_,points,options)
  H.points=Copy(points);H.options=Copy(options);local r={};for i,p in ipairs(points)do r[i]={x=p.x,y=p.y,visible=true}end;return r,'mock',{}
 end}
function H.Start()
 local f=S.Features.Treasure;f.enabled=true;f.consumerCount=1;assert(f:ReconcileDemand(nil,{count=0},{count=1}));return f
end
function H.Tick(ms)
 H.now=H.now+ms;local t=H.tasks.v3_life_treasure_position;assert(t,'position task missing');t.fn()
end
'''


class TreasureCompassRuntimeTests(unittest.TestCase):
    def boot(self):
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute(HOST)
        lua.execute((ROOT / "features/life/treasure/rs_treasure_feature.lua").read_text(encoding="utf-8-sig"))
        return lua

    def test_final_map_consumption_clears_rows_selection_and_guidance(self):
        self.boot().execute('''
        local f=H.Start();assert(f.Authority.selected)
        H.items={};H.Tick(500)
        assert(f.Authority.selected==nil,'consumed final map remains selected')
        assert(#f.Authority.maps==0 and f.Authority.status=='empty')
        assert(f.State.selectedKey==nil)
        assert(#f.Authority.compass.points==0)
        ''')

    def test_replaced_slot_selects_remaining_map_and_detects_new_maps(self):
        self.boot().execute('''
        local f=H.Start();local old=f.Authority.selected.key
        H.items={[2]=H.Item(1)};H.Tick(500)
        assert(f.Authority.selected.slot==2 and f.Authority.selected.key~=old)
        H.items[3]=H.Item(2);H.Tick(3000)
        assert(#f.Authority.maps==2,'new map was never observed')
        ''')

    def test_read_failure_is_unknown_and_does_not_claim_empty(self):
        self.boot().execute('''
        local f=H.Start();H.fail=true;H.Tick(500)
        assert(f.Authority.status=='unavailable','read failure still presents a ready map')
        assert(f.Authority.selected~=nil,'unknown read erased last known selection')
        assert(#f.Authority.compass.points==0)
        H.fail=false;H.Tick(3000);assert(f.Authority.status=='ready')
        ''')

    def test_compass_uses_world_delta_and_local_projection_without_bag_scan(self):
        self.boot().execute('''
        local f=H.Start();assert(type(f.Authority.UpdateCompass)=='function','compass missing')
        local scans,reads=H.scans,H.reads
        assert(f.Authority:UpdateCompass());assert(H.scans==scans and H.reads==reads)
        assert(#H.points==96,'unbounded or missing ring/arrow geometry')
        assert(H.options.rigidBatch and H.options.aspectSafeCamera)
        assert(H.options.anchorWorld.x==100 and H.options.anchorWorld.y==200)
        assert(H.points[80].x>100 and math.abs(H.points[80].y-200)<0.001,'east treasure points wrong way')
        f:ReconcileDemand(nil,{count=1},{count=0})
        assert(next(H.tasks)==nil and #f.Authority.compass.points==0,'last consumer leaked compass task')
        ''')

    def test_transparent_shadow_survives_palette_refresh_without_outline(self):
        lua = LuaRuntime()
        lua.execute("ReplicatedSuite={Constants={Color={text={1,1,1,1},textMuted={1,1,1,1}}}}")
        lua.execute((ROOT / "core/rs_theme.lua").read_text(encoding="utf-8-sig"))
        lua.execute('''
        local style={SetColor=function()end,SetOutline=function(self,v)self.outline=v end,SetShadow=function(self,v)self.shadow=v end}
        local w={style=style,rsLabelTone='default'};local t=ReplicatedSuite.Theme
        t:SetBackgroundOpacity(w,0);assert(style.outline==false and style.shadow==true,'transparent text has blurry outline')
        t:RefreshTextColor(w);assert(style.outline==false and style.shadow==true)
        t:SetBackgroundOpacity(w,1);assert(style.outline==false)
        style.SetOutline=nil;t:SetBackgroundOpacity(w,0)
        ''')

    def test_presenter_reuses_pool_hides_consumed_target_and_retries_rejected_anchor(self):
        # 中文维护：执行真实 Presenter；UI 替身记录接受/拒写，禁止把点池数量与离线显示状态当成 RU 像素证据。
        lua = self.boot()
        lua.execute('''
        H.labels=0;H.reject=false;H.env=1
        ReplicatedSuite.Layout={GetUiEnvironmentRevision=function()return H.env end}
        ReplicatedSuite.UI={
         CreateOverlayWindow=function()return {visible=false}end,
         CreateLabel=function()H.labels=H.labels+1;return {}end,
         SetPickable=function()return true end,
         SetColor=function(_,w,r,g,b)w.color={r,g,b};return true end,
         EnsureFontSize=function(_,w,v)w.font=v;return true end,
         InvalidateNativeState=function()return true end,
         SetVisible=function(_,w,v)w.visible=v;return true end,
         EnsureAnchor=function(_,w,_,x,y)if H.reject then return false end;w.x=x;w.y=y;return true end}
        ReplicatedSuite.Events.SubscribeInternal=function(_,topic,_,fn)H.callback=fn;return true end
        ''')
        lua.execute((ROOT / "presentation/v3/widgets/rs_v3_treasure_compass.lua").read_text(encoding="utf-8-sig"))
        lua.execute('''
        local f=H.Start();assert(f.Authority:UpdateCompass())
        local p=ReplicatedSuite.UIV3.TreasureCompassV3
        assert(p:Render() and H.labels==96 and p.host.visible)
        assert(p:Render() and H.labels==96,'pool grew on same frame')
        local old=p.pool[1].x;H.reject=true;f.Authority.compass.points[1].x=old+10
        p:Render();assert(p.pool[1].x==old and p.pool[1].root.visible==false)
        H.reject=false;p:Render();assert(p.pool[1].x==old+10 and p.pool[1].root.visible)
        local label=p.pool[1].root;label.x=nil;label.color=nil;label.font=0;H.env=2
        p:Render();assert(label.x==old+10 and label.color and label.font==15 and H.labels==96,'UI environment did not restore existing dots')
        f.Authority.compass.points[1].visible=false;p:Render();assert(p.pool[1].root.visible==false)
        H.items={};H.Tick(500);H.callback();assert(p.host.visible==false)
        ''')

    def test_real_scheduler_preserves_visual_interval(self):
        # 中文维护：使用真实调度器证明视觉通道保留 33ms，普通 AddTask 的 50ms 下限不能被桩漏掉。
        lua = self.boot()
        lua.execute((ROOT / "core/rs_scheduler.lua").read_text(encoding="utf-8-sig"))
        lua.execute("H.Start();assert(ReplicatedSuite.Scheduler.tasks.v3_life_treasure_compass.intervalMs==33,'visual interval clamped')")

    def test_real_inventory_does_not_resurrect_consumed_map_from_other_view(self):
        # 中文维护：真实共享服务的兼容视图保留旧值，物理视图成功为空时必须清目标。
        lua = self.boot()
        lua.execute('''
        X2Bag={};H.physical=true;H.legacy=true
        ReplicatedSuite.Api.CallCapability=function(_,cap,_,_,bagId,slot)
         if cap=='X2Bag:Capacity' then return true,2,nil end
         if slot==1 and ((bagId==1 and H.physical) or (bagId==0 and H.legacy)) then return true,H.Item(),nil end
         return true,nil,nil
        end
        ''')
        lua.execute((ROOT / "services/rs_inventory_snapshot_v3.lua").read_text(encoding="utf-8-sig"))
        lua.execute('''
        local f=H.Start();assert(f.Authority.selected.bagId==1)
        H.physical=false;H.Tick(500)
        assert(f.Authority.status=='empty' and #f.Authority.maps==0 and f.Authority.selected==nil,'legacy view resurrected final map')
        ''')

    def test_initial_compatibility_view_still_works_and_is_then_locked(self):
        # 中文维护：锁视图只影响已证明的会话，不能破坏最初 bag1 无数据而 bag0 可读的 RU 兼容路径。
        lua = self.boot()
        lua.execute('''
        X2Bag={};H.legacy=true
        ReplicatedSuite.Api.CallCapability=function(_,cap,_,_,bagId,slot)
         if cap=='X2Bag:Capacity' then return true,2,nil end
         if bagId==0 and slot==1 and H.legacy then return true,H.Item(),nil end
         return true,nil,nil
        end
        ''')
        lua.execute((ROOT / "services/rs_inventory_snapshot_v3.lua").read_text(encoding="utf-8-sig"))
        lua.execute('''
        local f=H.Start();assert(f.Authority.selected.bagId==0 and f.Authority.inventoryFallbackUsed)
        H.legacy=false;H.Tick(500);assert(f.Authority.status=='empty' and #f.Authority.maps==0)
        ''')


if __name__ == "__main__":
    unittest.main()

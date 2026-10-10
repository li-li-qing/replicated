"""Lua5.1真实寻宝逻辑的操作预算回归；Native替身计数不代表游戏CPU/FPS。"""
import unittest
from lupa.lua51 import LuaRuntime
from test_rs_treasure_compass_runtime import ROOT, HOST, UI_HOST

PERF_HOST = r'''
local S=ReplicatedSuite
H.cost={trig=0,sqrt=0,project=0,ui={},events={}}
local sin,cos,sqrt=math.sin,math.cos,math.sqrt
math.sin=function(v)H.cost.trig=H.cost.trig+1;return sin(v)end
math.cos=function(v)H.cost.trig=H.cost.trig+1;return cos(v)end
math.sqrt=function(v)H.cost.sqrt=H.cost.sqrt+1;return sqrt(v)end
local project=S.Services.ScreenProjectionV3.ProjectWorldBatch
S.Services.ScreenProjectionV3.ProjectWorldBatch=function(self,points,options)
 H.cost.project=H.cost.project+1
 -- 相机替身的yaw三角函数不是被测Feature几何开销。
 math.sin,math.cos=sin,cos
 local rows,source,facts=project(self,points,options)
 math.sin=function(v)H.cost.trig=H.cost.trig+1;return sin(v)end
 math.cos=function(v)H.cost.trig=H.cost.trig+1;return cos(v)end
 return rows,source,facts
end
local publish=S.Events.Publish
S.Events.Publish=function(self,topic,...)
 H.cost.events[topic]=(H.cost.events[topic] or 0)+1;return publish(self,topic,...)
end
local setVisible=S.UI.SetVisible
S.UI.SetVisible=function(self,n,v,...)
 if H.rejectVisible==n then return false end
 return setVisible(self,n,v,...)
end
S.UI.EnsureVisible=function(_,n,v)
 if H.rejectVisible==n then return false,false,'native visibility rejected' end
 local changed=n.visible~=v;n.visible=v;return true,changed
end
local wrapped={}
for name,fn in pairs(S.UI)do wrapped[name]=fn end
for name,fn in pairs(wrapped)do
 S.UI[name]=function(...)
  H.cost.ui[name]=(H.cost.ui[name] or 0)+1;return fn(...)
 end
end
function H.ResetCost()H.cost={trig=0,sqrt=0,project=0,ui={},events={}}end
'''


class TreasurePerformanceTests(unittest.TestCase):
    def boot(self):
        lua=LuaRuntime(unpack_returned_tuples=True)
        lua.execute(HOST);lua.execute(UI_HOST);lua.execute(PERF_HOST)
        lua.execute((ROOT/'features/life/treasure/rs_treasure_feature.lua').read_text(encoding='utf-8-sig'))
        lua.execute((ROOT/'presentation/v3/widgets/rs_v3_treasure_compass.lua').read_text(encoding='utf-8-sig'))
        lua.execute('H.Start();H.Render();H.ResetCost()')
        return lua

    def test_stationary_frames_keep_33ms_projection_but_do_not_rebuild_static_trigonometry(self):
        self.boot().execute('''
        local scans,reads=H.scans,H.reads
        for i=1,30 do H.Render() end
        assert(H.cost.trig==0,'fixed geometry repeats per-frame trigonometry')
        assert(H.cost.sqrt==30,'readability guard computes sqrt once per ring dot')
        assert(H.cost.project==30 and H.scans==scans and H.reads==reads,'optimization throttles camera updates or scans inventory')
        ''')

    def test_unchanged_frame_stops_duplicate_visibility_and_extent_adapter_calls(self):
        self.boot().execute('''
        for i=1,30 do H.Render() end
        local calls=H.cost.ui
        assert((calls.SetVisible or 0)+(calls.EnsureVisible or 0)==0,'same frame keeps calling visibility adapters')
        assert((calls.EnsureExtent or 0)==0,'same viewport keeps submitting overlay extent')
        assert((calls.CreateEmptyWidget or 0)==0 and (calls.CreateLabel or 0)==0,'stable scene recreates native objects')
        ''')

    def test_idle_position_does_not_republish_list_data_but_target_change_still_does(self):
        self.boot().execute('''
        local f=ReplicatedSuite.Features.Treasure
        for i=1,5 do assert(f.Authority:UpdatePosition()) end
        assert((H.cost.events[f.UpdateTopic] or 0)==0,'stationary position rebuilds the life lists')
        H.items[2]=H.Item(100);assert(f.Authority:Refresh());assert(f.Authority:UpdatePosition())
        local second=f.Authority.maps[2];assert(second and second.key~=f.Authority.selected.key)
        second.distance=f.Authority.selected.distance;second.direction=f.Authority.selected.direction
        H.ResetCost();assert(f:Select(second.key))
        assert((H.cost.events[f.UpdateTopic] or 0)==1,'equal distance on another target silently changes selection')
        ''')

    def test_enter_leave_ring_reuses_existing_world_point_working_tables(self):
        self.boot().execute('''
        local f=ReplicatedSuite.Features.Treasure;local a=f.Authority
        local old=a.compassWorldPoints[250]
        a.selected.worldX=21503;a.selected.worldY=28672;H.Render()
        assert(a.compass.near and #a.compass.points==169)
        a.selected.worldX=21503+100;H.Render()
        assert(a.compassWorldPoints[250]==old,'near/far transition reallocates discarded arrow points')
        assert(H.cost.trig==0,'near/far transition rebuilds fixed templates')
        ''')

    def test_style_change_rebuilds_geometry_once_and_preserves_world_distance(self):
        self.boot().execute('''
        local f=ReplicatedSuite.Features.Treasure;local old=f.Authority.compass.distance
        f.CompassStyle.radius=3;H.Render();assert(H.cost.trig>0)
        assert(math.abs(H.points[1].x-103)<0.000001 and f.Authority.compass.distance==old)
        H.ResetCost();H.Render();assert(H.cost.trig==0,'style cache never becomes stable')
        ''')

    def test_last_consumer_and_disable_release_private_workspace_then_rebuild_on_demand(self):
        self.boot().execute('''
        local f=ReplicatedSuite.Features.Treasure;local a=f.Authority
        local function Released()
         assert(a.compassWorldPoints==nil and a.compassWorldPointPool==nil and a.compassGeometry==nil,
          'inactive treasure retained its private geometry workspace')
         assert(next(H.tasks)==nil and #a.compass.points==0,'inactive treasure retained scheduled guidance')
        end
        assert(a.compassWorldPointPool and a.compassGeometry)
        f.consumerCount=0;assert(f:ReconcileDemand(nil,{count=1},{count=0}));Released()
        H.Start();H.Render();assert(a.compassWorldPointPool and #a.compassWorldPoints==310)
        assert(f:Disable());Released()
        H.Start();H.Render();assert(a.compassGeometry and #a.compass.points==306)
        ''')

    def test_visibility_rejection_retries_and_environment_change_invalidates_hidden_host(self):
        self.boot().execute('''
        local f=ReplicatedSuite.Features.Treasure;local p=ReplicatedSuite.UIV3.TreasureCompassV3
        H.rejectVisible=p.pool[1].root;f.Authority.compass.points[1].visible=false
        assert(p:Render()==false or H.rejectVisible.visible==true)
        H.rejectVisible=nil;assert(p:Render());assert(p.pool[1].root.visible==false)
        H.behind=true;H.Render();assert(p.host.visible==false)
        p.host.visible=true;H.env=H.env+1;H.Render()
        assert(p.host.visible==false,'hidden-host visibility cache survives environment reset')
        H.behind=false;H.Render();assert(p.host.visible)
        ''')

    def test_real_visibility_facade_accepts_false_state_retries_exceptions_and_handles_noop(self):
        lua=self.boot()
        lua.execute('H.savedUI={};for k,v in pairs(ReplicatedSuite.UI)do H.savedUI[k]=v end')
        lua.execute((ROOT/'ui/rs_ui_framework.lua').read_text(encoding='utf-8-sig'))
        lua.execute('''
        local ui=ReplicatedSuite.UI
        -- 保留真实显隐、失效和Native状态缓存；其余Native绘制边界仍是既有模型。
        for key,value in pairs(H.savedUI)do
         if key~='EnsureVisible' and key~='SetVisible' and key~='InvalidateNativeState' then ui[key]=value end
        end
        H.showCalls=0
        local p=ReplicatedSuite.UIV3.TreasureCompassV3
        local function Attach(root)
         function root:IsVisible()return self.visible end
         function root:Show(value)
          H.showCalls=H.showCalls+1
          if self.rejectShow then error('controlled Native Show failure') end
          self.visible=value;return value -- false代表成功隐藏，符合真实Facade的boolean状态契约。
         end
        end
        Attach(p.host)
        for _,dot in ipairs(p.pool)do Attach(dot.root)end
        for _,label in ipairs(p.cardinalLabels)do Attach(label.root)end
        Attach(p.distanceLabel.root)
        H.env=H.env+1;H.Render();assert(p.host.visible and p.pool[1].root.visible)
        local dot=p.pool[1];local before=H.showCalls
        dot.visible=nil;assert(p:Render())
        assert(dot.root.visible and H.showCalls==before,'accepted no-op was mistaken for rejection')
        dot.root.rejectShow=true;ReplicatedSuite.Features.Treasure.Authority.compass.points[1].visible=false
        p:Render();assert(dot.root.visible and dot.visible~=false,'failed Native hide committed visibility cache')
        dot.root.rejectShow=false;p:Render();assert(not dot.root.visible,'failed Native hide never retried')
        H.behind=true;H.Render();assert(not p.host.visible,'false Native state return rejected a successful hide')
        p.host.visible=true;H.env=H.env+1;H.Render();assert(not p.host.visible,'hidden environment reset was skipped')
        H.behind=false;H.Render();assert(p.host.visible)
        ''')


if __name__=='__main__':
    unittest.main()

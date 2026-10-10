"""实际 Lua5.1 Feature/Presenter，Native 绘制替身；覆盖 GroundCompass 对照行为。"""
import unittest
from lupa.lua51 import LuaRuntime
from test_rs_treasure_compass_runtime import ROOT, HOST, UI_HOST




class TreasureGroundCompassVisualTests(unittest.TestCase):
    def boot(self):
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute(HOST)
        lua.execute(UI_HOST)
        lua.execute((ROOT / "features/life/treasure/rs_treasure_feature.lua").read_text(encoding="utf-8-sig"))
        lua.execute((ROOT / "presentation/v3/widgets/rs_v3_treasure_compass.lua").read_text(encoding="utf-8-sig"))
        lua.execute("H.Start()")
        return lua

    def test_ring_ticks_filled_arrow_and_four_cardinals_are_one_ground_projection(self):
        self.boot().execute('''
        local f,p=H.Render();local frame=f.Authority.compass
        assert(#frame.cardinals==4,'missing direction text')
        local kinds={};for _,point in ipairs(frame.points)do kinds[point.kind]=(kinds[point.kind] or 0)+1 end
        assert(kinds.ring==120 and kinds.tick==48 and kinds.arrow>=100 and kinds.center==1,'incomplete ring/tick/solid-arrow geometry')
        assert(frame.cardinals[1].text=='北' and frame.cardinals[2].text=='东' and frame.cardinals[3].text=='南' and frame.cardinals[4].text=='西')
        assert(frame.cardinals[1].y<frame.center.y and frame.cardinals[2].x>frame.center.x,'cardinal world directions swapped')
        assert(H.points[1].z==8.4 and H.options.anchorWorld.z==10,'ground offset mixed with head anchor')
        assert(#H.points<=320 and #p.pool<=316,'unbounded projection/drawable pool')
        ''')

    def test_native_colored_rectangles_have_real_extents_and_do_not_grow_on_refresh(self):
        self.boot().execute('''
        local f,p=H.Render();assert(H.draws>0,'ring still relies on clipped dot text')
        assert(H.labels==5,'four directions and distance labels missing')
        for _,n in ipairs(p.pool)do assert(n.root.width>=3 and n.root.height>=3 and n.root.pickable==false and n.drawable) end
        assert(p.host.width==1280 and p.host.height==800,'overlay may clip dots beyond 200px')
        local nodes,draws,labels=H.nodes,H.draws,H.labels
        for i=1,20 do H.Render() end
        assert(H.nodes==nodes and H.draws==draws and H.labels==labels,'repaint adds native widgets or layers')
        ''')

    def test_distance_is_screen_bottom_fixed_and_formats_meters_kilometers_and_arrival(self):
        self.boot().execute('''
        local f,p=H.Render();local a=f.Authority
        a.selected.worldX=21503+1200;a.selected.worldY=28672;H.Render()
        local first=a.compass.distanceLabel;assert(first.text=='1.20 km')
        local x,y=first.x,first.y
        H.yaw=math.pi/2;H.Render();local nextLabel=a.compass.distanceLabel
        assert(math.abs(nextLabel.x-x)<0.001 and math.abs(nextLabel.y-y)<0.001,'distance rotates around the ring')
        for _,card in ipairs(a.compass.cardinals)do assert(nextLabel.y>=card.y+20,'distance overlaps a direction label') end
        a.selected.worldX=21503+123;H.Render();assert(a.compass.distanceLabel.text=='123 m')
        a.selected.worldX=21503+9;H.Render();assert(a.compass.distanceLabel.text=='已到达')
        a.selected.worldX=21503+12345;H.Render();assert(a.compass.distanceLabel.text=='12.3 km')
        ''')

    def boot_real_projection(self):
        # 真实批量投影保留透视分母；仅替换 Native 相机/单位输入与共享绘制宿主。
        # 低俯角反例旧算法让南标签 y=754.87、距离 y=763.66，12号文字重叠。
        lua = self.boot()
        lua.execute('''
        UIParent={GetScreenWidth=function()return 1280 end,GetScreenHeight=function()return 800 end}
        X2Unit={};H.cameraBack=6.5;H.cameraHeight=0.5;H.cameraYaw=0;H.cameraFov=1
        ReplicatedSuite.Services.ScreenProjectionV3={}
        ReplicatedSuite.Api.CallGlobalCapability=function()return false,nil,'native projector unavailable'end
        ReplicatedSuite.Api.CallCapability=function(_,cap,obj,method,token,isLocal)
         if cap=='X2Unit:GetUnitWorldPositionByTarget' then
          if isLocal then return true,100,nil,200,10 end
          return true,21503,nil,28672,0
         end
         if cap=='X2Unit:GetUnitScreenPosition' then return true,640,nil,400,1 end
         local dx=H.cameraBack*math.sin(H.cameraYaw)
         local dy=H.cameraBack*math.cos(H.cameraYaw)
         if cap=='UIParent:GetViewCameraPos' then return true,{x=100-dx,y=200-dy,z=10+H.cameraHeight},nil end
         if cap=='UIParent:GetViewCameraDir' then
          local length=math.sqrt(H.cameraBack*H.cameraBack+H.cameraHeight*H.cameraHeight)
          return true,{x=dx/length,y=dy/length,z=-H.cameraHeight/length},nil
         end
         if cap=='UIParent:GetViewCameraFov' then return true,H.cameraFov,nil end
         return false,nil,'unhandled:'..tostring(cap)
        end
        ''')
        lua.execute((ROOT / "services/rs_screen_projection_v3.lua").read_text(encoding="utf-8-sig"))
        return lua

    def test_real_perspective_keeps_distance_below_cardinal_text_at_multiple_camera_yaws(self):
        lua = self.boot_real_projection()
        lua.execute('''
        local cameras={{6.5,0.5},{3,6},{8,4}}
        for _,camera in ipairs(cameras)do
         H.cameraBack,H.cameraHeight=camera[1],camera[2]
         for degree=0,345,15 do
          H.cameraYaw=degree*math.pi/180
          local f,p=H.Render();local frame=f.Authority.compass
          local facts=ReplicatedSuite.Services.ScreenProjectionV3.lastWorldBatch
          assert(facts.rigidSource=='camera' and facts.calibrationStatus=='applied','real camera batch was bypassed')
          local distance=frame.distanceLabel
          assert(distance and distance.visible and p.distanceLabel.root.visible,'distance label missing on valid ground projection')
          for i,card in ipairs(frame.cardinals)do
           if card.visible then
            assert(distance.y>=card.y+26-0.000001,'perspective distance text overlaps a cardinal label')
            local directionRoot=p.cardinalLabels[i].root
            assert(p.distanceLabel.root.y>=directionRoot.y+directionRoot.height+4,'native label rectangles overlap after pixel rounding')
           end
          end
         end
        end
        ''')

    def test_real_projection_hides_tiny_or_collapsed_cardinals_and_recovers_the_same_drawables(self):
        self.boot_real_projection().execute('''
        H.cameraBack=8;H.cameraHeight=4;H.cameraFov=1.57
        local f,p=H.Render();assert(p.host.visible,'ordinary ground compass missing')
        local selected=f.Authority.selected.key
        local nodes,draws,labels=H.nodes,H.draws,H.labels
        local cameras={{20,5,'tiny'},{10,-1.6,'collapsed'}}
        for _,camera in ipairs(cameras)do
         H.cameraBack,H.cameraHeight=camera[1],camera[2]
         H.Render();local frame=f.Authority.compass;local radius=0
         for _,point in ipairs(frame.points)do
          if point.kind=='ring' and point.visible then
           radius=math.max(radius,math.sqrt((point.x-frame.center.x)^2+(point.y-frame.center.y)^2))
          end
         end
         if camera[3]=='tiny' then
          assert(radius<65,'far-camera counterexample no longer projects a tiny ring')
          assert(math.abs(frame.cardinals[1].y-frame.cardinals[3].y)>24,'tiny ring case accidentally depends on cardinal collision')
         else
          assert(radius>65,'collapsed-ground counterexample was only a tiny ring')
          local north,south=frame.cardinals[1],frame.cardinals[3]
          assert(math.abs(north.x-south.x)<1 and math.abs(north.y-south.y)<1,'ground-plane counterexample no longer collapses the labels')
         end
         assert(not p.host.visible,'tiny or collapsed compass still displays overlapping direction text')
         assert(f.Authority.selected.key==selected and #frame.points>0,'presentation hiding changed treasure selection or compass data')
         assert(H.nodes==nodes and H.draws==draws and H.labels==labels,'invalid camera grows the drawable pool')
         H.cameraBack=8;H.cameraHeight=4;H.Render()
         assert(p.host.visible and p.distanceLabel.root.visible,'compass did not recover after ordinary camera resumed')
         assert(H.nodes==nodes and H.draws==draws and H.labels==labels,'recovery rebuilt native drawables')
        end
        ''')

    def test_entering_ring_turns_it_gold_hides_arrow_and_leaving_restores(self):
        self.boot().execute('''
        local f,p=H.Render();local a=f.Authority;local total=H.draws
        local ring=p.pool[1].drawable;assert(ring.color[1]==0.15 and ring.color[2]==0.9)
        a.selected.worldX=21503+a.compass.radius;a.selected.worldY=28672;H.Render()
        assert(a.compass.near and ring.color[1]==1 and ring.color[2]==0.78,'arrival ring did not turn gold')
        for _,point in ipairs(a.compass.points)do assert(point.kind~='arrow','arrow remains inside ring') end
        assert(a.compass.distanceLabel.text=='已到达')
        a.selected.worldX=21503+100;H.Render();assert(not a.compass.near and ring.color[1]==0.15 and H.draws==total)
        local hasArrow=false;for _,point in ipairs(a.compass.points)do if point.kind=='arrow' then hasArrow=true end end;assert(hasArrow)
        ''')

    def test_rejected_native_color_and_text_stay_hidden_and_retry(self):
        self.boot().execute('''
        local f,p=H.Render();local a=f.Authority;local oldColor=p.pool[1].color
        H.rejectColor=true;a.selected.worldX=21503;H.Render()
        assert(p.pool[1].color==oldColor and not p.pool[1].root.visible,'rejected color was certified')
        H.rejectColor=false;H.Render();assert(p.pool[1].root.visible and p.pool[1].color~=oldColor)
        H.rejectText=true;a.selected.worldX=21503+321;H.Render()
        assert(not p.distanceLabel.root.visible,'old distance remains visible after new text rejected')
        H.rejectText=false;H.Render();assert(p.distanceLabel.root.visible and p.distanceLabel.root.text=='321 m')
        ''')

    def test_camera_loss_consumption_and_last_consumer_hide_all_visuals_without_scan_in_render(self):
        self.boot().execute('''
        local f,p=H.Render();local scans,reads=H.scans,H.reads
        H.Render();assert(H.scans==scans and H.reads==reads,'visual frame scans inventory')
        H.behind=true;H.Render();assert(not p.host.visible)
        H.behind=false;H.Render();assert(p.host.visible)
        H.items={};H.Tick(500);H.callback();assert(not p.host.visible)
        f:ReconcileDemand(nil,{count=1},{count=0});assert(next(H.tasks)==nil)
        ''')

    def test_environment_change_replays_drawables_labels_and_local_coordinates(self):
        self.boot().execute('''
        local f,p=H.Render();local dot=p.pool[1];local oldX=dot.x;local count=H.draws
        dot.drawable.color=nil;dot.root.x=nil;p.distanceLabel.root.text=nil;p.distanceLabel.root.font=0
        H.env=H.env+1;H.Render()
        assert(dot.root.x==oldX and dot.drawable.color and p.distanceLabel.root.font==12)
        assert(p.distanceLabel.root.text==f.Authority.compass.distanceLabel.text and H.draws==count)
        assert(dot.x==math.floor(f.Authority.compass.points[1].x-H.originX-dot.root.width/2+0.5),'origin or scale applied twice')
        ''')

    def test_implausible_world_delta_never_draws_a_wrong_arrow(self):
        self.boot().execute('''
        local f,p=H.Render();f.Authority.selected.worldX=21503+70000
        f.Authority:UpdateCompass();p:Render();assert(not p.host.visible and #f.Authority.compass.points==0)
        ''')

    def test_failed_drawable_creation_and_anchor_never_grow_owned_layers_per_frame(self):
        self.boot().execute('''
        local p=ReplicatedSuite.UIV3.TreasureCompassV3
        ReplicatedSuite.Features.Treasure.Authority:UpdateCompass()
        H.rejectDrawable=true
        for i=1,20 do assert(p:Render()==false) end
        assert(H.nodes==1 and H.draws==1 and p.pool[1].root and not p.host.visible,'failed creation leaks native controls')
        H.rejectDrawable=false;H.env=H.env+1;H.rejectDrawableAnchor=true
        for i=1,20 do assert(p:Render()==false) end
        assert(H.nodes==1 and H.draws==2 and p.pool[1].drawable,'failed anchor recreates drawable')
        H.rejectDrawableAnchor=false;assert(p:Render());assert(p.host.visible)
        local count=#ReplicatedSuite.Features.Treasure.Authority.compass.points
        assert(H.nodes==count and H.draws==count+1 and H.labels==5,'recovery changed fixed pool ownership')
        ''')


if __name__ == "__main__":
    unittest.main()

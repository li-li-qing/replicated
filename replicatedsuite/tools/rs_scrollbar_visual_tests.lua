-- Actual RSUI ScrollBox/ListView/TableView/TileView; only native drawing and input are controlled.
-- A native gradient method may exist yet return nil. This must not erase the position indicator.
local passed,total=0,0
local function Test(name,fn)
 total=total+1;local ok,err=xpcall(fn,debug.traceback)
 if ok then passed=passed+1;print('PASS scrollbar '..name)else print('FAIL scrollbar '..name..': '..tostring(err))end
end
local function Boot(options)
 options=options or {}
 local h=dofile('tools/rs_gear_page_test_host.lua')();local S=h.S;local UI=S.UI
 h.gradientCalls,h.drawCount=0,0
 local create=UI.CreateEmptyWidget
 UI.CreateEmptyWidget=function(self,...)
  local n=create(self,...);n.drawables={}
  function n:CreateColorDrawable(r,g,b,a,layer)
   if options.rejectThumb and self.id:match('_thumb$') then return nil end
   local d={rgba={r,g,b,a},layer=layer,anchors={}}
   function d:AddAnchor(point,parent,x,y)self.anchors[#self.anchors+1]={point,parent,x,y}end
   n.drawables[#n.drawables+1]=d;h.drawCount=h.drawCount+1;return d
  end
  function n:CreateThreeColorDrawable()h.gradientCalls=h.gradientCalls+1;return nil end
  function n:GetEffectiveOffset()return self.x,self.y end
  function n:EnableDrag()end
  function n:StartMoving()self.moving=true end
  function n:StopMovingOrSizing()self.moving=false end
  return n
 end
 dofile('ui/framework/rs_ui_scrollbar.lua')
 h.parent=h.Native(nil,'scroll_test_parent',0,0,500,500)
 h.R=S.RSUI
 return h,S
end
local function Items(count)local r={};for i=1,count do r[i]={key=i,name='Row '..i}end;return r end
local function Create(h,kind,count)
 local R=h.R;local spec={id='scroll_visual_'..kind,parent=h.parent,items=Items(count),rowHeight=20,
  itemText=function(row)return row.name end,viewState=false,padding=0,tileWidth=50,tileHeight=20}
 local c
 if kind=='ScrollBox' then
  c=R:ScrollBox(spec)
  for i=1,count do local label=R:Text({id=c.id..'_row'..i,parent=c.root,text='Row '..i,height=20});c:AddChild(label,{height=20})end
 elseif kind=='TableView' then spec.columns={{key='name',title='Name'}};c=R:TableView(spec)
 else c=R[kind](R,spec)end
 assert(c and not c.rsUiDegraded,'control failed to construct '..kind)
 c:Layout(0,0,180,100)
 local host=c.list or c;local bar=assert(host.scrollbar,'no shared scrollbar '..kind)
 return c,host,bar
end
local function AssertVisual(bar)
 assert(bar.track.shown and bar.thumb.shown,'scrollable content has no visible thumb')
 local draw=bar.thumb.drawables[1];assert(draw,'gradient nil erased the thumb')
 assert(draw.rgba[4]==1,'thumb must have explicit opaque alpha')
 local rail=assert(bar.track.drawables[1]);local a,b=draw.rgba,rail.rgba
 -- 用户要求仅比轨道略浅；既不能相同而不可见，也不能恢复刺眼的高对比配色。
 for i=1,3 do local delta=a[i]-b[i];assert(delta>=0.025 and delta<=0.08,'thumb must be only slightly lighter than rail')end
 assert(#draw.anchors==2 and draw.anchors[1][2]==bar.thumb and draw.anchors[2][2]==bar.thumb,'fill does not follow resized thumb')
end
Test('all four scrollable controls render an opaque indicator when gradient is unavailable',function()
 local h=Boot()
 for _,kind in ipairs({'ScrollBox','ListView','TableView','TileView'})do local _,_,bar=Create(h,kind,60);AssertVisual(bar)end
 assert(h.gradientCalls==0,'scrollbar still depends on gradient rendering')
end)
Test('wheel and offsets move the thumb between exact top middle and bottom without allocating drawables',function()
 local h=Boot();local c,host,bar=Create(h,'TableView',40);local count=#bar.thumb.drawables+#bar.track.drawables
 assert(bar.thumb.y==0);assert(host.root.events.OnWheelDown(host.root));assert(bar.thumb.y>0)
 host:SetScrollOffset(math.floor(host:GetMaxOffset()/2));assert(bar.thumb.y>0 and bar.thumb.y<bar.travel)
 host:ScrollToBottom();assert(bar.thumb.y==bar.travel)
 host:ScrollToTop();assert(bar.thumb.y==0 and #bar.thumb.drawables+#bar.track.drawables==count);AssertVisual(bar)
end)
Test('table rail starts at the header top and retains its full height on list-only scrolls',function()
 local h=Boot();local c=assert(h.R:TableView({id='table_header_top',parent=h.parent,items=Items(20),
  rowHeight=21,headerHeight=20,viewState=false,padding={left=3,top=5,right=4,bottom=6},columns={{key='name',title='Name'}}}))
 c:Layout(17,13,360,115);local host=c.list;local bar=assert(host.scrollbar)
 assert(bar.track.parent==c.root,'rail still belongs to the body and is clipped below the header')
 local ok,rail=h:VisibleRect({root=bar.track});assert(ok,rail)
 local _,header=h:VisibleRect(c.header);local _,thumb=h:VisibleRect({root=bar.thumb})
 assert(rail.y==header.y and thumb.y==header.y,'top row leaves a header-sized gap above the thumb')
 assert(rail.h==104 and host.visibleCapacity==4,'full-height rail changed the body viewport capacity')
 host:ScrollToBottom();assert(bar.thumb.y+bar.thumb.height==bar.track.height)
 assert(bar.track.y==5 and bar.track.height==104,'body-only refresh shortened the rail')
 while host.scrollOffset>0 do assert(host.root.events.OnWheelUp(host.root))end
 local atTop,top=h:VisibleRect({root=bar.thumb});assert(atTop,top);assert(top.y==header.y)
end)
Test('dragging a table thumb from bottom to top and releasing snaps to the header edge',function()
 local h,S=Boot();local c,host,bar=Create(h,'TableView',40)
 host:ScrollToBottom();local drag=bar.dragProxy;assert(drag.events.OnDragStart())
 drag.y=drag.y-bar.travel-10;S.Scheduler.tasks[bar.taskName].callback();assert(host.scrollOffset==0)
 assert(drag.events.OnDragStop());assert(not bar.dragging and not S.Scheduler.tasks[bar.taskName])
 local ok,thumb=h:VisibleRect({root=bar.thumb});assert(ok,thumb)
 local _,header=h:VisibleRect(c.header);assert(thumb.y==header.y and drag.y==0,'release kept the old body-top gap')
end)
Test('table rail follows header toggles and bounds while wheel over the rail shares the row offset',function()
 local h=Boot();local c,host,bar=Create(h,'TableView',40)
 for _,widget in ipairs({bar.track,bar.thumb,bar.dragProxy})do
  assert(widget.events.OnWheelDown,'wheel input over scrollbar has no handler')
  local offset=host.scrollOffset;assert(widget.events.OnWheelDown(widget));assert(host.scrollOffset==offset+1)
 end
 assert(c:SetHeaderVisible(false));c:Layout(20,25,300,150);host:ScrollToTop()
 assert(bar.track.height==150 and bar.track.y==0 and host.visibleCapacity==7)
 assert(c:SetHeaderVisible(true));c:Layout(20,25,300,150)
 assert(bar.track.height==150 and bar.track.y==0 and host.visibleCapacity==6)
 c:SetItems(Items(2));assert(not bar.track.shown and not bar.thumb.shown)
 c:SetItems(Items(50));assert(bar.track.shown and bar.track.height==150 and bar.thumb.y==0)
 local ok,thumb=h:VisibleRect({root=bar.thumb});assert(ok,thumb)
 c:SetViewportVisible(false);assert(not h:VisibleRect({root=bar.thumb}),'hidden table leaked its sibling rail')
 c:SetViewportVisible(true);assert(h:VisibleRect({root=bar.thumb}))
 c:Release();assert(not bar.track.shown and not bar.thumb.shown and not bar.dragProxy.events.OnDragStart)
end)
Test('resize and huge lists keep the indicator inside short and tall viewports',function()
 local h=Boot();local c,host,bar=Create(h,'ListView',5000)
 for _,height in ipairs({15,40,120,300,1600/1.2})do
  c:Layout(0,0,2560/1.2,height);host:ScrollToBottom();AssertVisual(bar)
  assert(bar.thumb.y>=0 and bar.thumb.y+bar.thumb.height<=bar.track.height+0.01,'thumb escaped viewport')
 end
end)
Test('drag reaches bottom and disabling mid gesture releases its interactive task',function()
 local h,S=Boot();local _,host,bar=Create(h,'ListView',50);local drag=bar.dragProxy
 assert(drag.events.OnDragStart());assert(S.Scheduler.tasks[bar.taskName] and bar.dragging)
 drag.y=drag.y+bar.travel;S.Scheduler.tasks[bar.taskName].callback()
 assert(host.scrollOffset==host:GetMaxOffset() and bar.thumb.y==bar.travel)
 assert(bar:SetEnabled(false));assert(not bar.dragging and not S.Scheduler.tasks[bar.taskName] and not drag.pickable)
 assert(bar:SetEnabled(true));bar:Release();assert(not bar.thumb.shown and not bar.track.shown and not drag.events.OnDragStart)
end)
Test('empty and fitting content hide the rail and position indicator',function()
 local h=Boot();local c,host,bar=Create(h,'ListView',40)
 c:SetItems(Items(1));assert(not bar.thumb.shown and not bar.track.shown and not bar.dragProxy.shown)
 c:SetItems({});assert(host:GetMaxOffset()==0 and not bar.thumb.shown)
end)
Test('horizontal scroll uses the same visual contract and tracks its x position',function()
 local h=Boot();local host={id='horizontal',owner='test',root=h.parent,scrollOffset=0}
 local bar=assert(h.R.ScrollbarBehavior:Attach(host,{orientation='horizontal',
  getMaxOffset=function()return 80 end,getOffset=function(v)return v.scrollOffset end,
  setOffset=function(v,value)v.scrollOffset=value;return true end}))
 assert(bar:Layout(0,0,200,14,20,100));AssertVisual(bar);assert(bar.thumb.x==0)
 host.scrollOffset=80;assert(bar:Layout(0,0,200,14,20,100));assert(bar.thumb.x==bar.travel and bar.thumb.width==40)
end)
Test('rejected thumb drawing reports degraded construction instead of an invisible usable scrollbar',function()
 local h=Boot({rejectThumb=true})
 local host={id='no_draw',root=h.parent,owner='test'}
 local bar,err=h.R.ScrollbarBehavior:Attach(host,{})
 assert(bar==nil and tostring(err):find('thumb_drawable',1,true),'missing drawable silently accepted')
end)
print(string.format('SCROLLBAR_VISUAL: %d/%d passed (%s)',passed,total,_VERSION))
if passed~=total then error('scrollbar visual regressions')end

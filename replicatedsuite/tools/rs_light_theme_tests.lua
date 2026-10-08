-- 中文维护：真实 Theme/NativePrimitive/RSUI/DiffRenderer；仅 Native 对象为可控替身。
-- 验证配色切换不会变成控件重建、输入/几何事务或业务查询；不冒充 RU 客户端像素实测。
local passed,failed=0,0
local function Test(name,fn)local ok,e=xpcall(fn,debug.traceback);if ok then passed=passed+1;print('PASS light-theme '..name)else failed=failed+1;print('FAIL light-theme '..name..': '..e)end end
local function Eq(a,b)for i=1,4 do assert(math.abs((a[i] or 1)-(b[i] or 1))<.000001,'color mismatch channel '..i)end end
local function Boot()
 local h={drawables=0,geometry=0,textWrites=0,focusWrites=0,widgets=0,ms=1000}
 local function Native(parent,id)
  h.widgets=h.widgets+1
  local n={id=id,parent=parent,width=500,height=500,x=0,y=0,shown=true,enabled=true,text='',events={},draws={}}
  n.style={SetColor=function(self,...)self.rgba={...}end,SetShadow=function(self,v)self.shadow=v end,
   SetAlign=function()end,SetFontSize=function(self,v)self.font=v end,SetEllipsis=function()end}
  n.guideTextStyle={SetColor=n.style.SetColor,SetAlign=function()end}
  function n:SetExtent(w,ht)h.geometry=h.geometry+1;self.width=w;self.height=ht end
  function n:GetWidth()return self.width end;function n:GetHeight()return self.height end
  function n:SetWidth(w)self.width=w end;function n:SetHeight(ht)self.height=ht end
  function n:AddAnchor(point,p,x,y)h.geometry=h.geometry+1;if not self.drawable then self.x=x or 0;self.y=y or 0 end end
  function n:RemoveAllAnchors()h.geometry=h.geometry+1 end
  function n:GetEffectiveOffset()return self.x,self.y end
  function n:GetParent()return self.parent end
  function n:SetText(v)h.textWrites=h.textWrites+1;self.text=v end;function n:GetText()return self.text end
  function n:SetColor(...)self.rgba={...}end;function n:SetAlpha(v)self.alpha=v end
  function n:Show(v)self.shown=v end;function n:IsVisible()return self.shown end
  function n:Enable(v)self.enabled=v end;function n:EnablePick(v)self.pickable=v end
  function n:EnableKeyboard(v)self.keyboard=v end;function n:EnableFocus(v)self.focusable=v end
  function n:SetFocus()h.focusWrites=h.focusWrites+1;h.focusId=self.rsNativePhysicalId end
  function n:ClearFocus()h.focusWrites=h.focusWrites+1;h.focusId=nil end
  function n:SetHandler(key,fn)self.events[key]=fn end;function n:ReleaseHandler(key)self.events[key]=nil end
  function n:SetCursorColor(...)self.caret={...}end;function n:SetCursorHeight(v)self.caretHeight=v end
  function n:SetGuideText(v)self.guide=v end
  function n:CreateColorDrawable(r,g,b,a)
   local d=Native(self,self.id..'_drawable');d.drawable=true;d.rgba={r,g,b,a};self.draws[#self.draws+1]=d;h.drawables=h.drawables+1;return d
  end
  function n:CreateThreeColorDrawable()return nil end -- 有方法却无渐变能力的 RU 降级路径。
  function n:CreateChildWidgetByType()end;function n:CreateChildWidget()end
  for _,name in ipairs({'SetInset','SetReadOnly','UseSelectAllWhenFocused','SetReClickable','ClearTextOnEnter','SetMaxTextLength','SetAutoResize',
   'SetNormalBackground','SetHighlightBackground','SetPushedBackground','SetDisabledBackground','EnableDrag','StartMoving','StopMovingOrSizing','SetDragCondition','Raise','SetUILayer'})do n[name]=function()end end
  return n
 end
 h.Native=Native;UIParent=Native(nil,'UIParent');ALIGN_LEFT=1;ALIGN_CENTER=2;ALIGN_RIGHT=3;ALIGN_TOP_LEFT=4
 GetFocusedWidgetId=function()return h.focusId end
 ReplicatedSuite={Generation=1,Features={},Services={},NowMs=function()return h.ms end,PhysicalId=function(id)return 'test_'..id end,
  SafeTraceback=tostring,SafeChat=function()end,RecordLog=function()end,WarnOnce=function()end,
  Layout={GetContext=function()return {addonScale=1,uiScale=1}end},
  GameIds={Item={BLUE_SALT_BOND=1,BOND_MATERIAL={},AURORIA_BOND_MATERIAL={}},Quest={ResidentBond={MaterialByQuantity={},AuroriaByTokenQuantity={}}}}}
 local S=ReplicatedSuite
 S.NativeObjectFactory={CreateChildByObject=function(_,p,kind,id)return Native(p,id)end,CreateChild=function(_,p,kind,id)return Native(p,id)end}
 for _,name in ipairs({'CreateEmptyWidget','CreateButton','CreateLabel','CreateWindow'})do S.NativeObjectFactory[name]=function(_,p,id)return Native(p,id)end end
 S.NativeObjectFactory.Create=function(_,kind,id)return Native(UIParent,id)end
 for _,path in ipairs({'core/rs_utils.lua','core/rs_reuse.lua','core/rs_events.lua','core/rs_scheduler.lua',
  'core/rs_constants.lua','ui/framework/rs_ui_tokens.lua','core/rs_theme.lua','core/rs_workspace_theme.lua',
  'ui/rs_ui_native_primitives.lua','ui/rs_ui_framework.lua','ui/framework/rs_ui_binding_v2.lua','ui/framework/rs_ui_component_core.lua',
  'ui/framework/rs_ui_panels.lua','ui/framework/rs_ui_primitives.lua','ui/framework/rs_ui_scrollbar.lua','ui/framework/rs_ui_controls.lua','ui/framework/rs_ui_adaptive_panels.lua',
  'ui/framework/rs_ui_selection.lua','ui/framework/rs_ui_view_state.lua','ui/framework/rs_ui_data_views.lua'})do dofile(path)end
 h.S=S;h.UI=S.UI;h.R=S.RSUI;return h
end
Test('single and multiline inputs retain draft focus selection and geometry while every input color changes',function()
 local h=Boot();local S,UI=h.S,h.UI
 local single=assert(UI:CreateEditBox(UIParent,'single',0,0,180,24,64))
 local multi=assert(UI:CreateMultiEditBox(UIParent,'multi',0,28,200,100,512))
 single.text='未提交草稿';single.selected=true;single.keyboard=true;h.focusId=single.rsNativePhysicalId
 assert(UI:SetEditBoxFocusVisual(single,true));local border=single.rsUiEditBorderDrawable
 local dark={unpack(single.rsUiEditBackgroundDrawable.rgba)};local count,geo,txt,focus=h.drawables,h.geometry,h.textWrites,h.focusWrites
 for _,name in ipairs({'light','nord','dusk','dawn','sage'})do
  assert(S.Theme:ApplyWorkspacePalette(name));Eq(single.style.rgba,S.UITokens.input.text);Eq(multi.style.rgba,S.UITokens.input.text)
  Eq(single.rsUiEditBackgroundDrawable.rgba,S.UITokens.input.background);Eq(border.rgba,S.UITokens.input.focus)
  Eq(single.guideTextStyle.rgba,S.UITokens.input.placeholder);Eq(single.caret,S.UITokens.input.caret)
  assert(single.text=='未提交草稿' and single.selected and single.keyboard and h.focusId==single.rsNativePhysicalId)
  assert(h.geometry==geo and h.textWrites==txt and h.focusWrites==focus and h.drawables==count)
 end
 assert(S.Theme:ApplyWorkspacePalette('dark'));Eq(single.rsUiEditBackgroundDrawable.rgba,dark)
 assert(UI:SetEditBoxFocusVisual(single,false));Eq(border.rgba,S.UITokens.input.border)
end)
local function Items()local v={};for i=1,60 do v[i]={key=i,name='Row '..i}end;return v end
Test('all scroll families repaint existing rails and thumbs and preserve exact offsets',function()
 local h=Boot();local S,R=h.S,h.R
 local bars={}
 for _,kind in ipairs({'ScrollBox','ListView','TableView','TileView'})do
  local spec={id='view_'..kind,parent=UIParent,items=Items(),rowHeight=20,tileWidth=60,tileHeight=20,viewState=false,padding=0,itemText=function(r)return r.name end}
  local c
  if kind=='ScrollBox'then c=assert(R:ScrollBox(spec));for i=1,60 do c:AddChild(assert(R:Text({id='scroll_row'..i,parent=c,text='Row '..i,height=20})),{height=20})end
  elseif kind=='TableView'then spec.columns={{key='name',title='Name'},{key='key',title='ID'}};c=assert(R:TableView(spec))
  else c=assert(R[kind](R,spec))end
  c:Layout(0,0,260,120);local host=c.list or c;assert(not host.rsUiDegraded,tostring(host.rsUiDegradedReason));host:SetScrollOffset(3)
  bars[#bars+1]={bar=assert(host.scrollbar),host=host,y=host.scrollbar.thumb.y,offset=host.scrollOffset}
 end
 local count,geo=h.drawables,h.geometry
 for _,name in ipairs({'light','nord','dusk','dawn','sage'})do
  assert(S.Theme:ApplyWorkspacePalette(name))
  for _,v in ipairs(bars)do Eq(v.bar.trackDrawable.rgba,S.UITokens.scrollbar.track);Eq(v.bar.thumbDrawable.rgba,S.UITokens.scrollbar.thumb)
   assert(v.bar.thumb.y==v.y and v.host.scrollOffset==v.offset and v.bar.thumbDrawable.rgba[4]==1)end
  assert(h.drawables==count and h.geometry==geo)
 end
 assert(S.Theme:ApplyWorkspacePalette('dark'));for _,v in ipairs(bars)do Eq(v.bar.thumbDrawable.rgba,S.UITokens.scrollbar.thumb)end
end)
Test('selected pooled rows and grids update in place without rebinding data',function()
 local h=Boot();local S,R=h.S,h.R;local data=Items()
 local c=assert(R:TableView({id='table',parent=UIParent,items=data,rowHeight=20,selectable=true,viewState=false,columns={{key='name',title='Name'},{key='key',title='ID'}}}))
 c:Layout(0,0,300,120);c:SetSelectedIndex(1);assert(c:GetSelectedIndex()==1,'selection failed')
 local slot=assert(c.list.poolByIndex[1],'first item is not bound');local row=slot.row;local visual=assert(row.rsSelectionVisual,'selection visual missing, key='..tostring(slot.boundKey)..', selected='..tostring(row.state.selected))
 local fill,root=visual.fill,row.root;local count=h.drawables
 for _,name in ipairs({'light','dark','nord','dusk','dawn','sage','gold','contrast','light','dark'})do
  assert(S.Theme:ApplyWorkspacePalette(name));assert(row.root==root and visual.fill==fill and c:GetSelectedIndex()==1 and c.list.items==data)
  Eq(row.bottomGridLine.rgba,S.Constants.Color.dividerSoft);Eq(c.header.bottomGridLine.rgba,S.Constants.Color.divider)
  local active=S.UITokens.button.active;Eq(fill.rgba,{active[1],active[2],active[3],.88})
 end
 assert(h.drawables==count)
end)
Test('disabled slider and active slider take correct palette without changing values',function()
 local h=Boot();local S,UI=h.S,h.UI
 local a=assert(UI:CreateSlider(UIParent,'slider_a',0,0,180,22,0,100,1,35));local b=assert(UI:CreateSlider(UIParent,'slider_b',0,30,180,22,0,100,1,70))
 assert(b:SetEnabled(false));local count,geo=h.drawables,h.geometry
 for _,name in ipairs({'light','nord','dusk','dawn','sage'})do
  assert(S.Theme:ApplyWorkspacePalette(name));Eq(a.rsTrack.rgba,S.UITokens.slider.track);Eq(b.rsTrack.rgba,S.UITokens.slider.disabled)
  assert(a:GetValue()==35 and b:GetValue()==70 and b.rsEnabled==false and h.geometry==geo and h.drawables==count)
 end
 assert(b:SetEnabled(true));Eq(b.rsTrack.rgba,S.UITokens.slider.track)
end)
Test('late controls use saved active palette and manual HUD points are never recolored',function()
 local h=Boot();local S,UI=h.S,h.UI;assert(S.Theme:ApplyWorkspacePalette('light'))
 local late=assert(UI:CreateButton(UIParent,'late','test',0,0,80,24,11,false,{gradient=false}));Eq(late.style.rgba,S.Constants.Color.text)
 local world=assert(UI:CreateLabel(UIParent,'world','Player',0,0,100,20,12,'default','LEFT',true));S.Theme:SetWorldTextPalette(world)
 local before={unpack(world.style.rgba)};local point=assert(UI:CreateLabel(UIParent,'point','.',0,0,10,10,15));point.rsManualTypography=true
 point.style:SetColor(.3,.8,.2,.6);local custom={unpack(point.style.rgba)}
 assert(S.Theme:ApplyWorkspacePalette('dark'));assert(S.Theme:ApplyWorkspacePalette('light'));Eq(world.style.rgba,before);Eq(point.style.rgba,custom)
end)
print('LIGHT THEME RESULT '..passed..' passed / '..failed..' failed');if failed>0 then error('light theme failures')end

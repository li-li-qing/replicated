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
   SetOutline=function(self,v)self.outline=v end, -- 中文维护（2026-10-09）：记录原生描边值，透明文字必须关闭粗描边。
   SetAlign=function()end,SetFontSize=function(self,v)self.font=v end,SetEllipsis=function()end}
  n.guideTextStyle={SetColor=n.style.SetColor,SetAlign=function()end,SetShadow=n.style.SetShadow,SetOutline=n.style.SetOutline}
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
 -- 工厂原生根创建签名为 id,parent；嵌套面板的 parent 可是对象，不能把它误作 id。
 for _,name in ipairs({'CreateEmptyWidget','CreateButton','CreateWindow'})do S.NativeObjectFactory[name]=function(_,id,p)return Native(type(p)=='table' and p or UIParent,id)end end
 S.NativeObjectFactory.Create=function(_,kind,id)return Native(UIParent,id)end
 for _,path in ipairs({'core/rs_utils.lua','core/rs_reuse.lua','core/rs_events.lua','core/rs_scheduler.lua',
  'core/rs_constants.lua','ui/framework/rs_ui_tokens.lua','core/rs_theme.lua','core/rs_workspace_theme.lua',
  'ui/rs_ui_native_primitives.lua','ui/rs_ui_framework.lua','ui/framework/rs_ui_binding_v2.lua','ui/framework/rs_ui_component_core.lua',
  'ui/framework/rs_ui_panels.lua','ui/framework/rs_ui_primitives.lua','ui/framework/rs_ui_scrollbar.lua','ui/framework/rs_ui_controls.lua','ui/framework/rs_ui_adaptive_panels.lua',
  'ui/framework/rs_ui_selection.lua','ui/framework/rs_ui_view_state.lua','ui/framework/rs_ui_data_views.lua','ui/framework/rs_ui_layout_templates.lua',
  'ui/framework/rs_ui_containers.lua','ui/framework/rs_ui_forms.lua'})do dofile(path)end
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
-- 中文维护（2026-10-08）：滚动装饰属于宿主的背景通道；透明/半透明/恢复、文字独立及切主题都不能改滚动事务。
Test('all scrollbar families follow background opacity through palette changes',function()
 local h=Boot();local S,R=h.S,h.R;local views={}
 for _,kind in ipairs({'ScrollBox','ListView','TableView','TileView'})do
  local spec={id='opacity_'..kind,parent=UIParent,items=Items(),rowHeight=20,tileWidth=60,tileHeight=20,viewState=false,padding=0,itemText=function(r)return r.name end}
  local c
  if kind=='ScrollBox'then c=assert(R:ScrollBox(spec));for i=1,60 do c:AddChild(assert(R:Text({id='opacity_row'..i,parent=c,text='Row '..i,height=20})),{height=20})end
  elseif kind=='TableView'then spec.columns={{key='name',title='Name'}};c=assert(R:TableView(spec))
  else c=assert(R[kind](R,spec))end
  c:Layout(0,0,260,120);local host=c.list or c;host:SetScrollOffset(3)
  views[#views+1]={view=c,host=host,bar=assert(host.scrollbar),offset=host.scrollOffset,y=host.scrollbar.thumb.y}
 end
 local count,geometry=h.drawables,h.geometry
 for _,opacity in ipairs({0,.35,1})do
  for _,v in ipairs(views)do assert(R:ApplyOpacityChannels(v.view,opacity,.7))end
  for _,palette in ipairs({'light','nord','dark'})do
   assert(S.Theme:ApplyWorkspacePalette(palette))
   for _,v in ipairs(views)do
    local rail,thumb=S.UITokens.scrollbar.track,S.UITokens.scrollbar.thumb
    Eq(v.bar.trackDrawable.rgba,{rail[1],rail[2],rail[3],rail[4]*opacity})
    Eq(v.bar.thumbDrawable.rgba,{thumb[1],thumb[2],thumb[3],thumb[4]*opacity})
    assert(v.host.scrollOffset==v.offset and v.bar.thumb.y==v.y and v.bar.dragProxy.pickable,'opacity changed scrollbar input or position')
    assert(R:ApplyOpacityChannels(v.view,nil,.2));assert(v.bar.thumbDrawable.rgba[4]==thumb[4]*opacity,'text opacity changed scrollbar')
   end
   assert(h.drawables==count and h.geometry==geometry,'opacity rebuilt or laid out scrollbar')
  end
 end
end)
Test('late scrollbar binding inherits the existing host background opacity',function()
 local h=Boot();local S,R=h.S,h.R
 local c=assert(R:ListView({id='late_opacity',parent=UIParent,items=Items(),viewState=false,rowHeight=20}))
 assert(R:ApplyOpacityChannels(c,0,nil));c.scrollbar:Release()
 local bar=assert(R.ScrollbarBehavior:Attach(c,{id='late_opacity_bar',getMaxOffset=function()return 20 end,getOffset=function()return 0 end,setOffset=function()return true end}))
 assert(bar.trackDrawable.rgba[4]==0 and bar.thumbDrawable.rgba[4]==0,'new scrollbar flashed opaque on transparent host')
 assert(R:ApplyOpacityChannels(c,.5,nil));assert(bar.trackDrawable.rgba[4]==S.UITokens.scrollbar.track[4]*.5)
 bar:Release()
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
Test('transparent readable text reaches existing and lazy wrapped lines without outline or new widgets',function()
 -- 中文维护：使用真实 RSUI 换行池/外观继承/调色板；缺陷反例是 root 已透明而子行仍无描边。
 local h=Boot();local S,R=h.S,h.R
 local c=assert(R:Text({id='transparent_wrap',parent=UIParent,text='first',overflow='wrap',fontSize=12,maxLines=4,nativeLineLimit=4}))
 c:Layout(0,0,180,80);local first=assert(c.lineLabels[1]);assert(R:ApplyOpacityChannels(c,0,1))
 assert(first.style.outline==false and first.style.shadow==true)
 local late=assert(c:_EnsureLine(2));assert(late.style.outline==false and late.style.shadow==true,'late wrapped line did not inherit readable text')
 local count=h.widgets;assert(S.Theme:ApplyWorkspacePalette('light'));assert(S.Theme:ApplyWorkspacePalette('dark'))
 assert(first.style.outline==false and late.style.outline==false and first.style.shadow and late.style.shadow and h.widgets==count)
 assert(R:ApplyOpacityChannels(c,1,nil));assert(first.style.outline==false and late.style.outline==false)
end)
-- 中文维护（2026-10-09）：反例覆盖旧逻辑在 alpha=0 打开粗描边、alpha=.2 仍用浅底深色字；Native 不证明实际阴影像素。
Test('light palettes switch transparent text to bright shadowed colors and restore opaque colors',function()
 local h=Boot();local S,UI=h.S,h.UI
 local label=assert(UI:CreateLabel(UIParent,'readable', '中文小字',0,0,180,24,12,'default','LEFT',false))
 local muted=assert(UI:CreateLabel(UIParent,'readable_muted','辅助说明',0,24,180,24,12,'muted','LEFT',false))
 local danger=assert(UI:CreateLabel(UIParent,'readable_danger','失败',0,48,180,24,12,'danger','LEFT',false))
 local count,geo,txt,focus=h.widgets,h.geometry,h.textWrites,h.focusWrites
 for _,name in ipairs({'light','dawn','sage'})do
  assert(S.Theme:ApplyWorkspacePalette(name))
  S.Theme:SetBackgroundOpacity(label,1);Eq(label.style.rgba,S.Constants.Color.text);assert(label.style.shadow==false)
  for _,alpha in ipairs({.5,.2,0})do
   for _,w in ipairs({label,muted,danger})do S.Theme:SetBackgroundOpacity(w,alpha);assert(w.style.outline==false and w.style.shadow==true)end
   assert(label.style.rgba[1]>.8 and label.style.rgba[2]>.8,'transparent primary text remains dark')
   assert(muted.style.rgba[1]>.7 and muted.style.rgba[4]==1,'auxiliary text too faint')
   assert(danger.style.rgba[1]>danger.style.rgba[2]*2,'failure color lost its meaning')
   S.Theme:SetTextOpacity(label,.35);assert(math.abs(label.style.rgba[4]-.35)<.000001)
   S.Theme:SetBackgroundOpacity(label,alpha);assert(math.abs(label.style.rgba[4]-.35)<.000001,'background changed text alpha')
  end
  S.Theme:SetTextOpacity(label,1);S.Theme:SetBackgroundOpacity(label,1)
  Eq(label.style.rgba,S.Constants.Color.text);assert(label.style.outline==false and label.style.shadow==false)
 end
 assert(h.widgets==count and h.geometry==geo and h.textWrites==txt and h.focusWrites==focus,'readability touched layout or input')
end)
Test('transparent input placeholder caret and theme changes preserve draft and opacity',function()
 local h=Boot();local S,UI=h.S,h.UI
 local input=assert(UI:CreateEditBox(UIParent,'readable_input',0,0,180,24,64))
 input.text='未提交草稿';input.selected=true;h.focusId=input.rsNativePhysicalId
 S.Theme:SetTextOpacity(input,.4);S.Theme:SetBackgroundOpacity(input,.2)
 for _,name in ipairs({'light','dark','dawn','sage','light'})do
  assert(S.Theme:ApplyWorkspacePalette(name))
  assert(input.style.rgba[1]>.7 and input.guideTextStyle.rgba[1]>.6,'input or guide remains dark')
  assert(input.style.shadow==true and input.guideTextStyle.shadow==true and input.style.outline==false)
  assert(math.abs(input.style.rgba[4]-.4)<.000001 and math.abs(input.guideTextStyle.rgba[4]-.4)<.000001)
  assert(math.max(input.caret[1],input.caret[2],input.caret[3])>.6,'transparent caret remains dark')
  assert(math.abs(input.rsUiEditBackgroundDrawable.rgba[4]-S.UITokens.input.background[4]*.2)<.000001,'input kept an opaque light background behind bright text')
  UI:ConfigureEditCaret(input,24)
  assert(math.max(input.caret[1],input.caret[2],input.caret[3])>.6,'caret layout restored the dark light-palette color')
  assert(input.text=='未提交草稿' and input.selected and h.focusId==input.rsNativePhysicalId)
 end
 S.Theme:SetBackgroundOpacity(input,1);Eq(input.style.rgba,{40/255,51/255,61/255,.4});assert(input.style.shadow==false)
end)
Test('manual HUD glyphs keep their color outline and shadow when appearance is inherited',function()
 local h=Boot();local S,UI=h.S,h.UI
 local w=assert(UI:CreateLabel(UIParent,'manual_readability','.',0,0,20,20,15,'default','LEFT',false))
 w.rsManualTypography=true;w.style.rgba={.2,.4,.6,.8};w.style.outline=true;w.style.shadow=false
 S.Theme:SetBackgroundOpacity(w,0);assert(S.Theme:ApplyWorkspacePalette('light'))
 Eq(w.style.rgba,{.2,.4,.6,.8});assert(w.style.outline==true and w.style.shadow==false,'theme took manual glyph ownership')
end)
Test('multiline input inherits transparent surface and restores its background without losing text',function()
 local h=Boot();local S,UI=h.S,h.UI
 assert(S.Theme:ApplyWorkspacePalette('light'))
 local w=assert(UI:CreateMultiEditBox(UIParent,'transparent_multi',0,0,200,100,512));w.text='第一行\n第二行'
 S.Theme:SetTextOpacity(w,.7);S.Theme:SetBackgroundOpacity(w,0)
 assert(w.rsUiEditBackgroundDrawable.rgba[4]==0 and w.style.rgba[1]>.8 and w.style.shadow==true and w.style.outline==false)
 assert(S.Theme:ApplyWorkspacePalette('sage'));assert(w.style.rgba[1]>.8 and math.abs(w.style.rgba[4]-.7)<.000001)
 S.Theme:SetBackgroundOpacity(w,1)
 assert(w.rsUiEditBackgroundDrawable.rgba[4]==S.UITokens.input.background[4] and w.style.shadow==false and w.text=='第一行\n第二行')
end)
Test('rejected outline disable retries instead of caching a blurry state',function()
 local h=Boot();local S=h.S;local attempts=0
 local w={style={SetOutline=function(_,enabled)attempts=attempts+1;if attempts==1 then return false end end}}
 assert(S.Theme:SetTextOutline(w,false)==false,'rejected disable reported accepted')
 assert(S.Theme:SetTextOutline(w,false)==true and attempts==2,'rejected disable was cached')
end)
Test('group titles and collapse indicators inherit transparency without changing collapse input',function()
 local h=Boot();local S,R=h.S,h.R
 assert(S.Theme:ApplyWorkspacePalette('light'))
 local group=assert(R:GroupBox({id='readable_group',parent=UIParent,title='主菜单外观'}))
 local collapse=assert(R:CollapsibleGroup({id='readable_collapse',parent=UIParent,title='高级设置'}))
 local count,geo=h.widgets,h.geometry
 for _,c in ipairs({group,collapse})do
  assert(R:ApplyOpacityChannels(c,0,.5))
  assert(c.title.style.rgba[1]>.8 and c.title.style.shadow==true and c.title.style.outline==false,'native group title missed transparent policy')
  assert(math.abs(c.title.style.rgba[4]-.5)<.000001)
 end
 assert(collapse.chevron.style.rgba[1]>.7 and collapse.chevron.style.shadow==true and math.abs(collapse.chevron.style.rgba[4]-.5)<.000001)
 assert(collapse:SetExpanded(false,true) and collapse:SetExpanded(true,true),'appearance broke collapse')
 for _,c in ipairs({group,collapse})do
  assert(R:ApplyOpacityChannels(c,1,1));Eq(c.title.style.rgba,S.Constants.Color.text);assert(c.title.style.shadow==false)
 end
 assert(h.widgets==count and h.geometry==geo,'appearance rebuilt group or changed geometry')
end)
Test('warning aliases and fallback tones remain readable on transparent light surfaces',function()
 local h=Boot();local S,UI=h.S,h.UI;assert(S.Theme:ApplyWorkspacePalette('light'))
 local warning=assert(UI:CreateLabel(UIParent,'readable_warn','读取失败',0,0,180,24,12,'warn','LEFT',false))
 local fallback=assert(UI:CreateLabel(UIParent,'readable_fallback','等待中',0,24,180,24,12,'pending','LEFT',false))
 S.Theme:SetBackgroundOpacity(warning,0);S.Theme:SetBackgroundOpacity(fallback,0)
 assert(warning.style.rgba[1]>.8 and warning.style.rgba[2]>.6 and warning.style.rgba[3]<.4,'warn alias kept dark default text')
 assert(fallback.style.rgba[1]>.8 and fallback.style.shadow==true,'fallback tone kept dark default text')
end)
Test('section and form section title strips inherit both background and text channels',function()
 local h=Boot();local S,R=h.S,h.R;assert(S.Theme:ApplyWorkspacePalette('light'))
 S.Constants.Theme.modern=false -- 此宿主只提供实色 Drawable，Section 以受支持的实色表面验证通道。
 for _,kind in ipairs({'Section','FormSection'})do
  local c=assert(R[kind](R,{id='readable_'..kind,parent=UIParent,title='设置',gradient=false}));local raw=c.raw
  assert(R:ApplyOpacityChannels(c,0,.5))
  assert(raw.header.rsBackground.rgba[4]==0,'section title strip kept opaque light background')
  assert(raw.title.style.rgba[1]>.8 and raw.title.style.shadow==true and math.abs(raw.title.style.rgba[4]-.5)<.000001)
  assert(R:ApplyOpacityChannels(c,1,1));Eq(raw.title.style.rgba,S.Constants.Color.text)
  assert(raw.header.rsBackground.rgba[4]==S.Constants.Color.cardHeader[4] and raw.title.style.shadow==false)
 end
end)
print('LIGHT THEME RESULT '..passed..' passed / '..failed..' failed');if failed>0 then error('light theme failures')end

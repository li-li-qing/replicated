-- 真实首页/RSUI 控件及 Command 绑定；仅替换顶层 Surface 与 RU 屏幕定位边界。
-- 不加载游戏，不将离线布局和点击链验收冒充 RU 实测。
local Host=dofile('tools/rs_workspace_home_test_host.lua')
local pass,fail=0,0
local function Test(name,fn)
 local ok,err=xpcall(fn,debug.traceback)
 if ok then pass=pass+1;print('PASS home settings '..name)else fail=fail+1;print('FAIL home settings '..name..': '..tostring(err))end
end
local function Boot()
 local S,p,n,c,enabled,h=Host({visible={'trade','bonds'},enabled={life_trade=true,life_bonds=true,life_daily_stats=true}})
 local surfaces={}
 S.RSUI.FloatingSurface.Create=function(_,spec)
  local native=h.Native(nil,spec.id,0,0,380,300)
  local body=assert(S.RSUI:VerticalBox({id=spec.id..'_body',parent=native,slot={size='fill',fill=1}}))
  local surface={spec=spec,body=body,visible=false}
  function surface:GetContentRoot()return body end
  function surface:SetStatus(text)self.status=text;return true end
  function surface:SetMinimized()return true end
  function surface:Show(value)self.visible=value~=false;body:Layout(0,0,380,230);return true end
  function surface:Layout(width)native:SetExtent(width,300);body:Layout(0,0,width,230);return true end
  function surface:Close()self.visible=false;return spec.onClosed(self)end
  function surface:Destroy()self.destroyed=true;body:Release();return true end
  surfaces[#surfaces+1]=surface;return surface
 end
 S.RSUI.PopupPositioning={
  ResolveDropdown=function(_,control,opts)return {width=opts.popupWidth,height=opts.rowHeight*math.min(#control.items,opts.maxVisible)},nil,{visibleRows=opts.maxVisible}end,
  ApplyNativeRelativePopup=function(_,popup,control,owner,opts)popup:SetExtent(opts.width,opts.height);return true end,
  CorrectNativePopupToScreen=function()return true end,
 }
 local state={fromZone=1,toZone=2,viewMode='all',currentFavoriteKey='route-a',currentRouteFavorite=true}
 local F=S.Features.Trade
 function F:GetProjection()
  return {rows={{key='cargo-a',itemType=99,name='测试货物'}},revision=1,status='ready',
   fromZone=state.fromZone,toZone=state.toZone,viewMode=state.viewMode,
   zones={{id=1,name='起点甲'},{id=3,name='起点丙'}},sellableZones={{id=2,name='目的乙'},{id=4,name='目的丁'}},
   favoriteItems={{value='route-a',text='起点甲 → 目的乙'},{value='route-b',text='起点丙 → 目的丁'}},
   currentFavoriteKey=state.currentFavoriteKey,currentRouteFavorite=state.currentRouteFavorite}
 end
 function F:GetSelectedRow()return {key='cargo-a',itemType=99}end
 F.Commands.SetFrom=function(_,v)if v==999 then return false,'地区不可用' end;state.fromZone=v;return true end
 F.Commands.SetTo=function(_,v)state.toZone=v;return true end
 F.Commands.SelectFavorite=function(_,v)state.currentFavoriteKey=v;state.fromZone=3;state.toZone=4;return true end
 F.Commands.SetViewMode=function(_,v)state.viewMode=v;return true end
 F.Commands.Refresh=function()c.manualRefresh=(c.manualRefresh or 0)+1;return true end
 local B=S.Features.Bonds;local bond={order='continent:west_first',mask=7,duplicate='all'}
 function B:GetDisplayOrderKey()return bond.order end
 function B:GetFilterMask()return bond.mask end
 function B:GetDuplicateMode()return bond.duplicate end
 B.Commands.SetDisplayOrder=function(_,mode,order)bond.order=mode..':'..order;return true end
 B.Commands.SetFilterMask=function(_,mask)bond.mask=mask;return true end
 B.Commands.SetDuplicateMode=function(_,mode)bond.duplicate=mode;return true end
 assert(p:OnActivated())
 local function Settings(key)
  for _,card in ipairs(p.cards)do if card.spec.key==key then return card.content.headerSettings,card.content end end
 end
 return S,p,n,c,enabled,surfaces,state,bond,Settings,h
end
Test('settings are lazy and each trade field has its own dropdown',function()
 local S,p,n,c,e,s,state,bond,Settings=Boot()
 assert(#s==0,'home eagerly allocated settings windows')
 assert(n.v3_home_trade_settings.onClick())
 local panel=assert(Settings('trade'));assert(panel.controls.fromDropdown and panel.controls.toDropdown and panel.controls.favoriteDropdown)
 assert(panel.surface.visible and #s==1)
 assert(c.quotes==0 and c.enabledWrites==0,'opening settings issued a query or enabled a feature')
 assert(n.v3_home_trade_settings.onClick());assert(not panel.surface.visible)
 assert(n.v3_home_trade_settings.onClick());assert(#s==1,'reopening recreated native controls')
end)
Test('trade selections read back authoritative route and failed commands retain old value',function()
 local S,p,n,c,e,s,state,bond,Settings=Boot();assert(n.v3_home_trade_settings.onClick())
 local panel=Settings('trade');local controls=panel.controls
 assert(controls.fromDropdown:SetSelectedValue(3));assert(state.fromZone==3 and controls.fromDropdown:GetValue()==3)
 assert(controls.toDropdown:SetSelectedValue(4));assert(state.toZone==4)
 assert(controls.favoriteDropdown:SetSelectedValue('route-b'))
 assert(controls.fromDropdown.value==3 and controls.toDropdown.value==4,'favorite did not update route fields')
 assert(not controls.fromDropdown:SetSelectedValue(999));assert(state.fromZone==3 and controls.fromDropdown.value==3)
 assert(panel.surface.status:find('地区不可用',1,true),'failed save has no visible explanation')
 assert(c.quotes==0,'route selection issued a material quote')
end)
Test('child dropdowns keep settings open and close on card/page exit',function()
 local S,p,n,c,e,s,state,bond,Settings=Boot();assert(n.v3_home_trade_settings.onClick())
 local panel,content=Settings('trade');local controls=panel.controls
 assert(controls.fromDropdown:Open());assert(panel.surface.visible)
 assert(controls.toDropdown:Open());assert(not controls.fromDropdown.open and controls.toDropdown.open)
 assert(content:SetAvailable(false,'未启用'));assert(not panel.surface.visible and not controls.toDropdown.open)
 assert(content:SetAvailable(true));assert(n.v3_home_trade_settings.onClick());assert(controls.favoriteDropdown:Open())
 assert(p:OnDeactivated());assert(not panel.surface.visible and not controls.favoriteDropdown.open)
end)
Test('cargo mode disables route choices and explicit refresh remains the only refresh trigger',function()
 local S,p,n,c,e,s,state,bond,Settings=Boot();assert(n.v3_home_trade_settings.onClick())
 local controls=Settings('trade').controls
 assert(controls.viewSelector:SetValue('cargo'))
 assert(not controls.fromDropdown.enabled and not controls.toDropdown.enabled and not controls.favoriteDropdown.enabled)
 assert(not controls.fromDropdown:SetSelectedValue(3));assert(state.fromZone==1)
 assert(c.manualRefresh==nil);assert(controls.refreshButton.onClick());assert(c.manualRefresh==1)
 assert(c.quotes==0)
end)
Test('bonds exposes three independent choices and disposal destroys settings surfaces',function()
 local S,p,n,c,e,s,state,bond,Settings=Boot();assert(n.v3_home_bonds_settings.onClick())
 local panel=Settings('bonds');local controls=panel.controls
 assert(controls.orderDropdown:SetSelectedValue('quantity:east_first'));assert(bond.order=='quantity:east_first')
 assert(controls.scopeDropdown:SetSelectedValue(8));assert(bond.mask==8)
 assert(controls.duplicateDropdown:SetSelectedValue('west'));assert(bond.duplicate=='west')
 assert(panel.surface.visible and controls.orderDropdown.value==bond.order and controls.scopeDropdown.value==bond.mask)
 assert(p:OnDispose());assert(panel.surface.destroyed and not panel.surface.visible)
 assert(c.quotes==0 and c.enabledWrites==0)
end)
Test('opening bonds closes trade and its expanded options',function()
 local S,p,n,c,e,s,state,bond,Settings=Boot();assert(n.v3_home_trade_settings.onClick())
 local trade=Settings('trade');assert(trade.controls.fromDropdown:Open())
 assert(n.v3_home_bonds_settings.onClick())
 assert(Settings('bonds').surface.visible and not trade.surface.visible and not trade.controls.fromDropdown.open)
end)
Test('narrow form rows stay inside the window and actions use existing commands',function()
 local S,p,n,c,e,s,state,bond,Settings,h=Boot();local F=S.Features.Trade;local favorite,tracked=0,0
 F.Commands.ToggleCurrentFavorite=function()favorite=favorite+1;return true end
 F.Commands.ToggleTrackedProduct=function(_,id)assert(id==99);tracked=tracked+1;return true end
 assert(n.v3_home_trade_settings.onClick());local panel=Settings('trade');local controls=panel.controls
 for _,width in ipairs({320,380,520})do
  panel.surface:Layout(width)
  for _,control in pairs(controls)do
   local ok,why=h:VisibleRect(control);assert(ok,control.id..':'..tostring(why))
  end
 end
 assert(controls.favoriteButton.onClick() and favorite==1)
 assert(controls.trackButton.onClick() and tracked==1)
 assert(c.quotes==0)
end)
Test('real FloatingSurface and WindowShell build, show, minimize and dispose the form',function()
 local S,p,n,c,e,s,state,bond,Settings,h=Boot()
 local R,UI=S.RSUI,S.UI;local proxy=R.FloatingSurface
 S.PhysicalId=function(id)return id end
 S.Constants={SafeArea=12,MinAddonScale=.5,MaxAddonScale=2,Breakpoint={COMPACT=1150,STANDARD=1700,WIDE=2300,NARROW_ONE_COLUMN=760}}
 S.AppState={settings={addonScale=1}}
 UIParent=h.Native(nil,'UIParent',0,0,1280,768)
 S.Api.GetUiMetrics=function()return {logicalWidth=1280,logicalHeight=768,screenWidth=1280,screenHeight=768,uiScale=1,effectiveUiScale=1,source='test'}end
 S.NativeObjectFactory={CreateWindow=function(_,id)
  local native=h.Native(UIParent,id,0,0,1,1)
  function native:SetUILayer(value)self.layer=value;return true end
  function native:SetCloseOnEscape()return true end
  function native:SetWindowModal()return true end
  function native:SetDrawPriority()return true end
  return native
 end}
 UI.ClaimNativeAuthority=function()return true end
 UI.SetAlpha=function(_,native,value)native.alpha=value;return true end
 UI.EnsureAlpha=function(_,native,value)native.alpha=value;return true,false end
 UI.InvalidateNativeState=function()return true end
 R.ApplyOpacityChannels=function()return true end;R.ApplyFontScale=function()return true end
 R.WindowPreferences={GetTopmost=function()return false end,SetTopmost=function()return true end}
 dofile('core/rs_layout.lua')
 dofile('ui/framework/rs_ui_windowing.lua')
 dofile('ui/framework/rs_ui_window_shell_v3.lua')
 dofile('ui/framework/rs_ui_floating_surface.lua')
 -- 内容构建器已经引用宿主 Floating 表；补入真实实现，保持它与其他 RSUI 控件在同一 Suite 实例中。
 for key,value in pairs(R.FloatingSurface)do proxy[key]=value end
 assert(n.v3_home_trade_settings.onClick())
 local panel=Settings('trade');assert(panel.surface.shell and panel.surface.visible)
 for _,control in pairs(panel.controls)do local ok,why=h:VisibleRect(control);assert(ok,control.id..':'..tostring(why))end
 assert(panel.controls.fromDropdown:Open())
 assert(panel.surface:SetMinimized(true,false));assert(not panel.controls.fromDropdown.open)
 assert(n.v3_home_bonds_settings.onClick());local bonds=Settings('bonds')
 for _,control in pairs(bonds.controls)do local ok,why=h:VisibleRect(control);assert(ok,control.id..':'..tostring(why))end
 assert(p:OnDispose());assert(not panel.surface.visible)
 assert(c.quotes==0 and c.enabledWrites==0)
end)
print('HOME ECONOMY SETTINGS: '..pass..' passed, '..fail..' failed')
if fail>0 then os.exit(1)end

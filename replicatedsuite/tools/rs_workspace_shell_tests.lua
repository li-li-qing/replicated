-- Actual Shell/RSUI/Router/Workspace layout; only Native and page payloads are controlled.
local passed,failed=0,0
local function Test(name,fn)local ok,err=xpcall(fn,debug.traceback);if ok then passed=passed+1;print('PASS workspace-shell '..name)else failed=failed+1;print('FAIL workspace-shell '..name..': '..tostring(err))end end
local function Boot(options)
 options=options or {}
 local h=dofile('tools/rs_gear_page_test_host.lua')({disk=options.disk});local S=h.S;local V=S.UIV3;local enabled={life_tasks=true}
 if options.mainAppearance then
  S.UI.CreateSlider=function(_,p,id,x,y,w,ht,mn,mx,step,value)
   local n=h.Native(p,id,x,y,w,ht);n.value=value
   function n:SetValue(v)self.value=v end;function n:GetValue()return self.value end
   function n:SetRange(mn,mx,step)self.min,self.max,self.step=mn,mx,step end
   function n:SetValueChangedHandler(fn)self.valueChanged=fn end
   return n
  end
  S.UI.EnsureAlpha=function(_,n,value)
   if h.rejectAlpha==value then return false,false,'synthetic alpha rejection'end
   n.alpha=value;return true,true
  end
  dofile('ui/framework/rs_ui_forms.lua')
  dofile('presentation/v3/rs_v3_shell_store.lua');dofile('presentation/v3/rs_v3_main_appearance_store.lua')
 end
 S.FeatureRuntime.IsEnabled=function(_,id)return enabled[id]==true end
 S.FeatureRuntime.GetControlState=function(_,id)return {enabled=enabled[id]==true,faulted=false,implemented=true}end
 S.FeatureRuntime.SetPreferredEnabled=function()error('UI preference enabled feature')end
 S.FeatureRuntime.GetHealth=function()error('full health poll')end
 dofile('features/rs_feature_registry.lua');dofile('presentation/v3/navigation/rs_v3_router.lua');dofile('presentation/v3/rs_v3_workspace.lua')
 dofile('presentation/v3/shell/rs_v3_module_controls.lua')
 if not options.mainAppearance then V.ShellState={width=1000,height=700}end
 V.ShellSizePolicy={defaultWidth=1000,defaultHeight=700,minWidth=400,minHeight=400}
 V.WorkspacePage={requestedTab='navigation'}
 -- Shell 现经 Core Placement 求完整视口；复用真实求解，Native 屏幕读数仍由宿主控制。
 dofile('data/rs_data_registry.lua');dofile('data/rs_static_data_v2.lua')
 dofile('data/ids/rs_item_ids.lua');dofile('data/ids/rs_quest_ids.lua')
 dofile('core/rs_constants.lua');dofile('core/rs_layout.lua')
 S.Layout.GetContext=function()return {logicalWidth=1024,logicalHeight=768,addonScale=1,uiScale=1,
  usableWidth=1024,usableHeight=768,safeLeft=0,safeRight=0,safeTop=0,safeBottom=0}end
 S.UIV3NativeAdapter={CreateRootWindow=function(_,id)return h.Native(nil,id,0,0,1000,700)end,
  ApplyRect=function(_,n,owner,x,y,w,ht)n.x=x;n.y=y;n.width=w;n.height=ht;return true end,
  SetVisible=function(_,n,owner,v)n.shown=v;return true end,IsVisible=function(_,n)return n.shown==true end,Raise=function()return true end,
  SetRootLayer=function()return true end}
 V.PageHost.Attach=function()return true end;V.PageHost.Navigate=function(_,id)h.route=id;return true end
 V.PageHost.SetVisible=function()return true end;V.PageHost.RefreshData=function()return true end
 V.ModalHost={Attach=function()return true end,Clear=function()end};V.ToastHost={Attach=function()return true end,Clear=function()end}
 if options.actualWorkspaceHost then
  -- 中文维护：Shell 在加载时绑定 PageHost，按真实 TOC 顺序先加载实际宿主，不能建好 Shell 后替换成另一实例。
  dofile('presentation/v3/shell/rs_v3_page_host.lua');dofile('presentation/v3/pages/rs_v3_workspace_page.lua')
  V.PageHost:RegisterFactory('home',function(p)return S.RSUI:VerticalBox({id='appearance_home_test',parent=p})end)
 end
 S.RSUI.Windowing={ApplyGeometry=function(_,n,owner,x,y,w,ht)n.x=x;n.y=y;n.width=w;n.height=ht;return true end,
 Attach=function(_,spec)return {IsInteracting=function()return false end,IsResizing=function()return false end,
  SetLocked=function()return true end,SetResizeEnabled=function()return true end,LayoutHandles=function()return true end,BringToFront=function()return true end,
  SetOpacity=function(_,value)local ok,_,why=S.UI:EnsureAlpha(spec.window,value,spec.owner);return ok,value,true,why end}end}
 dofile('presentation/v3/rs_v3_shell.lua');local shell=V.Shell;assert(shell:Create());assert(shell:Open())
 local nodes={};local function Walk(node)nodes[node.id]=node;for _,child in ipairs(node.children or {})do Walk(child)end end;Walk(shell.root)
 return shell,S,h,nodes,enabled
end
Test('sidebar favorites order and hidden recovery preserve native parents',function()
 local shell,S,h,n=Boot();local W=S.UIV3.Workspace;local b=shell.navButtons['life.fishing'];local parent=b.root.parent
 assert(W:SetNavigation('life.fishing','favorite',true));assert(shell.navScroll.children[2]==b)
 assert(W:SetNavigation('life.fishing','hidden',true));assert(not b.visible and b.root.parent==parent)
 shell.navMode='all';assert(shell:RefreshNavigation(true));assert(b.visible and shell.navButtons['system.workspace'].visible)
 assert(W:Reset('navigation'));assert(b.visible and b.root.parent==parent)
end)
Test('actual state filter, summary and committed search use current runtime',function()
 local shell,S,h,n,enabled=Boot();shell.navMode='enabled';shell:RefreshNavigation(true)
 assert(shell.navButtons['life.tasks'].visible and not shell.navButtons['life.fishing'].visible)
 enabled.life_fishing=true;shell:RefreshFeatureStates('life_fishing')
 assert(shell.navButtons['life.fishing'].visible and shell.runningButton.text:find('已开启 2',1,true))
 shell.navMode='all';shell:RefreshNavigation(true);local edit=n.v3_nav_search_text
 assert(edit:BeginEditing('test'));edit.root.text='钓鱼';assert(n.v3_nav_search_apply.onClick())
 assert(shell.navButtons['life.fishing'].visible and not shell.navButtons['life.tasks'].visible)
 assert(n.v3_nav_search_clear.onClick());assert(shell.navButtons['life.tasks'].visible)
end)
Test('recovery controls remain within sidebar at small resolution',function()
 local shell,S,h,n=Boot();assert(shell:ApplyLayout(false,1000,700))
 assert(shell.navScroll.height>=100,'fixed editor chrome consumed the entire sidebar')
 for _,id in ipairs({'v3_nav_tools','v3_nav_search_row','v3_shell_system_frame','v3_shell_nav_pager'})do
  local c=assert(n[id]);assert(c.y>=0 and c.y+c.height<=c.parentComponent.height+1,id..' escaped parent')
 end
 assert(n.v3_nav_customize.onClick());assert(h.route=='system.workspace')
end)
Test('compact page spacing restores the normal shell padding when leaving home',function()
 local shell,S,h,n=Boot();local H=S.UIV3.PageHost
 H.compactPageChrome=true;assert(shell:ApplyLayout(false))
 assert(shell.contentFrame.padding.top==6 and shell.contentRoot.y==6,'compact content padding was ignored')
 local height=shell.contentRoot.height
 H.compactPageChrome=false;assert(shell:ApplyLayout(false))
 assert(shell.contentFrame.padding.top==14 and shell.contentRoot.y==14,'normal page padding was not restored')
 assert(shell.contentRoot.height==height-16,'saved outer space did not reach the page viewport')
end)
Test('actual page host compacts existing controls without changing their parents',function()
 local shell,S,h,n=Boot();dofile('presentation/v3/shell/rs_v3_page_host.lua')
 local H=S.UIV3.PageHost;local parent=S.RSUI:Overlay({id='compact_host_test',parent=h.Native(nil,'host_native',0,0,850,700)})
 assert(H:Attach(parent));H:RegisterFactory('home',function(p)return S.RSUI:VerticalBox({id='compact_home_test',parent=p})end)
 H:RegisterFactory('life.tasks',function(p)return S.RSUI:VerticalBox({id='normal_tasks_test',parent=p})end)
 local home=assert(H:CreatePage('home'));home.compactPageChrome=true
 assert(H:Navigate('home'));parent:Layout(0,0,850,700)
 local bar=H.moduleControls.home;local nativeParent=bar.root.root.parent
 assert(H.controlsSwitcher.slot.height==24 and H.frame.gap==2,'host toolbar kept normal spacing')
 assert(H:Navigate('life.tasks'));assert(H.controlsSwitcher.slot.height==32 and H.frame.gap==6)
 assert(H:Navigate('home'));parent:Layout(0,0,850,700)
 assert(bar.root.root.parent==nativeParent and H.controlsSwitcher.slot.height==24,'returning home recreated or moved the control bar')
 assert(bar.diagnostics.root.parent==bar.root.root,'diagnostics left the shared host bar')
 for _,control in ipairs({bar.toggle,bar.diagnostics})do local ok,why=h:VisibleRect(control);assert(ok,tostring(why))end
end)
Test('appearance shortcut stays clickable in the main title bar and opens the actual theme editor',function()
 local shell,S,h,n=Boot({actualWorkspaceHost=true});local H=S.UIV3.PageHost
 local shortcut=assert(n.v3_shell_appearance_button,'appearance entry missing from main title bar')
 local parent=shortcut.root.parent
 for _,width in ipairs({400,620,1000})do
  assert(shell:ApplyLayout(false,width,700))
  local previousRight=0
  for _,id in ipairs({'v3_shell_running','v3_shell_appearance_button','v3_shell_diag_button','v3_shell_topmost_button','v3_shell_minimize_button','v3_shell_close_button'})do
   local button=assert(n[id]);assert(button.x>=previousRight and button.x+button.width<=button.parentComponent.width+1,id..' overlaps or leaves title bar at '..width)
   previousRight=button.x+button.width
   local visible,why=h:VisibleRect(button);assert(visible,why)
  end
  assert(shell:Navigate('home'));S.UIV3.WorkspacePage.requestedTab='navigation'
  assert(shortcut.root.events.OnClick(shortcut.root,'LeftButton'))
  assert(shell.lastRoute=='system.workspace' and H.pages['system.workspace'].tab=='appearance','shortcut opened the wrong workspace section')
  local page=H.pages['system.workspace'];assert(#page.rows==8 and page:SelectId('light'))
  assert(shortcut.root.parent==parent,'header button was reparented')
 end
 assert(H.pages['system.workspace']:PerformAction(1));assert(S.UIV3.Workspace:GetSettings().appearance=='light')
 assert(shell:Close('test'));assert(shell:Open());assert(shortcut.root.events.OnClick(shortcut.root,'LeftButton'))
 assert(H.pages['system.workspace'].tab=='appearance')
end)
Test('release label, support line and menu tips use visible open edges',function()
 local shell,S,h,n=Boot()
 assert(shell.brandTitle.text:find('QQ群:1104129461   正式版5.0',1,true),'release label missing beside QQ group')
 assert(n.v3_shell_support_text.text=='如果觉得功能好用，可以邮件给作者提供一点打赏','support line missing')
 local tips={
  '债券功能','装备升级或者翻新','血条太大挡视野','想给朋友取别称吗',
  '经常被圣所盾聚到','整理背包怕放错物品','死于不明吗',
 }
 local seen={}
 for i=1,#tips do
  local displayed=assert(n.v3_shell_menu_tip).text
  assert(displayed:find(tips[i],1,true),'wrong tip on open '..i..': '..displayed)
  assert(not seen[displayed],'tip repeated before all seven appeared')
  seen[displayed]=true
  assert(shell:Navigate('home'))
  assert(n.v3_shell_menu_tip.text==displayed,'navigation rotated tip while menu was already visible')
  assert(shell:Close('tip_test'))
  assert(shell:Open())
 end
 assert(n.v3_shell_menu_tip.text:find(tips[1],1,true),'tips did not cycle after seven opens')
 assert(h.writes==0,'tip rotation wrote configuration')
 for _,width in ipairs({400,1000}) do
  assert(shell:ApplyLayout(false,width,700))
  assert(n.v3_shell_menu_tip.x+n.v3_shell_menu_tip.width<=n.v3_shell_menu_tip.parentComponent.width+1,'tip escaped footer')
 end
end)
Test('main menu appearance entry exposes actual numeric controls and preview writes nothing',function()
 local shell,S,h,n=Boot({actualWorkspaceHost=true,mainAppearance=true})
 assert(n.v3_shell_appearance_button.root.events.OnClick(n.v3_shell_appearance_button.root,'LeftButton'))
 local page=S.UIV3.PageHost.pages['system.workspace'];assert(page.tab=='appearance')
 for _,key in ipairs({'overallOpacity','backgroundOpacity','textOpacity','fontScale'})do assert(page.mainAppearanceFields[key],key..' missing')end
 local field=page.mainAppearanceFields.overallOpacity;local writes=h.writes
 assert(field.slider:Preview(65,'test'));assert(shell.window.alpha==0.65 and S.UIV3.MainAppearance:GetSettings().overallOpacity==1)
 assert(h.writes==writes,'drag preview saved data')
 assert(field.slider:CommitValue(65,'slider'));assert(S.UIV3.MainAppearance:GetSettings().overallOpacity==0.65 and h.writes==writes+1)
 for _,width in ipairs({620,760,1000})do
  assert(shell:ApplyLayout(false,width,700))
  for _,f in pairs(page.mainAppearanceFields)do assert(h:VisibleRect(f.slider));assert(h:VisibleRect(f.input))end
 end
end)
Test('main menu background zero and text alpha persist and newly created page inherits all channels',function()
 local shell,S,h,n=Boot({actualWorkspaceHost=true,mainAppearance=true})
 assert(shell:SetAppearance({backgroundOpacity=0,textOpacity=0.45,fontScale=1.25},true))
 assert(shell.root.appearanceBackgroundOpacity==0 and shell.root.appearanceTextOpacity==0.45 and shell.root.appearanceFontScale==1.25)
 assert(shell:Navigate('home'));local home=S.UIV3.PageHost.pages.home
 assert(home.appearanceBackgroundOpacity==0 and home.appearanceTextOpacity==0.45 and home.appearanceFontScale==1.25)
 local text=assert(S.RSUI:Text({id='late_main_appearance_row',parent=home,text='late row'}))
 assert(text.appearanceBackgroundOpacity==0 and text.appearanceTextOpacity==0.45 and text.appearanceFontScale==1.25)
end)
Test('main menu appearance survives real store reload without changing old shell schema or geometry',function()
 local shell,S,h=Boot({actualWorkspaceHost=true,mainAppearance=true})
 assert(shell:SetAppearance({overallOpacity=0.72,backgroundOpacity=0.30,textOpacity=0.80,fontScale=1.10},true))
 local before=h.Copy(S.UIV3.ShellState);local shellStore=S.Persistence:GetStore('v3.shell')
 assert(shellStore.schemaVersion==7 and shellStore.dirty~=true)
 local other,otherS=Boot({actualWorkspaceHost=true,mainAppearance=true,disk=h.disk})
 local saved=otherS.UIV3.MainAppearance:GetSettings()
 assert(saved.overallOpacity==0.72 and saved.backgroundOpacity==0.30 and saved.textOpacity==0.80 and saved.fontScale==1.10)
 assert(other.window.alpha==0.72 and other.root.appearanceBackgroundOpacity==0.30)
 assert(S.UIV3.ShellState.width==before.width and S.UIV3.ShellState.height==before.height and S.UIV3.ShellState.userMoved==before.userMoved)
 assert(otherS.Persistence:GetStore('v3.shell').schemaVersion==7)
end)
Test('rejected appearance save rolls visual preview and committed values back',function()
 local shell,S,h,n=Boot({actualWorkspaceHost=true,mainAppearance=true})
 assert(n.v3_shell_appearance_button.root.events.OnClick(n.v3_shell_appearance_button.root,'LeftButton'))
 local field=S.UIV3.PageHost.pages['system.workspace'].mainAppearanceFields.overallOpacity
 assert(field.slider:Preview(40,'test'));h.failSave=true
 assert(field.slider:CommitValue(40,'slider')==false)
 assert(shell.window.alpha==1 and S.UIV3.MainAppearance:GetSettings().overallOpacity==1)
 h.failSave=false;h.rejectAlpha=0.4;local writes=h.writes
 assert(shell:SetAppearance({overallOpacity=0.4},true)==false);assert(h.writes==writes and shell.window.alpha==1)
end)
Test('closing or leaving appearance cancels uncommitted preview and reset keeps geometry',function()
 local shell,S,h,n=Boot({actualWorkspaceHost=true,mainAppearance=true})
 assert(n.v3_shell_appearance_button.root.events.OnClick(n.v3_shell_appearance_button.root,'LeftButton'))
 local page=S.UIV3.PageHost.pages['system.workspace'];local field=page.mainAppearanceFields.overallOpacity
 assert(field.slider:Preview(55,'test'));local writes=h.writes
 assert(page:SetTab('navigation'));assert(shell.window.alpha==1 and h.writes==writes)
 assert(page:SetTab('appearance'));assert(field.slider:Preview(55,'test'));assert(shell:Close('test'))
 assert(shell.window.alpha==1 and h.writes==writes);assert(shell:Open())
 assert(shell:SetAppearance({overallOpacity=0.7,backgroundOpacity=0.4,textOpacity=0.6,fontScale=1.2},true))
 local state=h.Copy(S.UIV3.ShellState);assert(shell:ResetAppearance())
 for _,value in pairs(S.UIV3.MainAppearance:GetSettings())do assert(value==1)end
 assert(shell.window.alpha==1 and shell.root.appearanceFontScale==1)
 assert(S.UIV3.ShellState.width==state.width and S.UIV3.ShellState.height==state.height and S.UIV3.ShellState.x==state.x)
end)
Test('large and small font settings retain usable header and main appearance controls',function()
 local shell,S,h,n=Boot({actualWorkspaceHost=true,mainAppearance=true})
 assert(n.v3_shell_appearance_button.root.events.OnClick(n.v3_shell_appearance_button.root,'LeftButton'))
 local page=S.UIV3.PageHost.pages['system.workspace']
 for _,font in ipairs({0.5,2,1})do
  assert(shell:SetAppearance({fontScale=font},true))
  assert(shell.brandTitle.slot.height==20*math.max(1,font) and shell.topBar.slot.height==50*math.max(1,font))
  for _,width in ipairs({520,620,1000})do
   assert(shell:ApplyLayout(false,width,700))
   assert(h:VisibleRect(n.v3_shell_appearance_button))
   for _,field in pairs(page.mainAppearanceFields)do assert(h:VisibleRect(field.slider));assert(h:VisibleRect(field.input))end
  end
 end
end)
Test('damaged appearance save leaves the main menu usable and refuses overwrite',function()
 local shell,S,h=Boot({actualWorkspaceHost=true,mainAppearance=true})
 assert(shell:SetAppearance({overallOpacity=0.6},true))
 local store=S.Persistence:GetStore(S.UIV3.MainAppearance.storeId);local key=S.Persistence:ResolveStoreKey(store)
 h.disk[key].__rsmeta.encodedFingerprint='modified stamp'
 local other,otherS,otherH=Boot({actualWorkspaceHost=true,mainAppearance=true,disk=h.disk})
 local guarded=otherS.Persistence:GetStore(otherS.UIV3.MainAppearance.storeId)
 assert(guarded.writeFenced and other.created and other.mainAppearanceLoadError)
 local writes=otherH.writes;assert(other:SetAppearance({backgroundOpacity=0.5},true)==false)
 assert(otherH.writes==writes and other.window.shown and otherS.UIV3.MainAppearance:GetSettings().overallOpacity==1)
end)
Test('main appearance diagnostics are owned by workspace and never load or save settings',function()
 local shell,S,h=Boot({actualWorkspaceHost=true,mainAppearance=true})
 dofile('core/rs_diagnostic_detail.lua');dofile('core/rs_module_diagnostics.lua')
 local A=S.UIV3.MainAppearance;assert(A:RegisterDiagnostics())
 assert(S.ModuleDiagnosticsHub:_ResolveByStore(A.storeId,A.storeId)=='system_workspace')
 local reads,writes=h.reads,h.writes
 local report,err,detail=S.ModuleDiagnosticsHub:BuildReport('system_workspace',{detailed=true})
 assert(report,err);assert(report:find(A.storeId,1,true) and detail:find('provider.main_appearance',1,true))
 assert(h.reads==reads and h.writes==writes)
end)
print('WORKSPACE SHELL RESULT '..passed..' passed / '..failed..' failed');if failed>0 then error('workspace shell failures')end

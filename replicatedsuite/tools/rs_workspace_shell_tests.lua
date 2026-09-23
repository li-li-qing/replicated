-- Actual Shell/RSUI/Router/Workspace layout; only Native and page payloads are controlled.
local passed,failed=0,0
local function Test(name,fn)local ok,err=xpcall(fn,debug.traceback);if ok then passed=passed+1;print('PASS workspace-shell '..name)else failed=failed+1;print('FAIL workspace-shell '..name..': '..tostring(err))end end
local function Boot()
 local h=dofile('tools/rs_gear_page_test_host.lua')();local S=h.S;local V=S.UIV3;local enabled={life_tasks=true}
 S.FeatureRuntime.IsEnabled=function(_,id)return enabled[id]==true end
 S.FeatureRuntime.GetControlState=function(_,id)return {enabled=enabled[id]==true,faulted=false,implemented=true}end
 S.FeatureRuntime.SetPreferredEnabled=function()error('UI preference enabled feature')end
 S.FeatureRuntime.GetHealth=function()error('full health poll')end
 dofile('features/rs_feature_registry.lua');dofile('presentation/v3/navigation/rs_v3_router.lua');dofile('presentation/v3/rs_v3_workspace.lua')
 dofile('presentation/v3/shell/rs_v3_module_controls.lua')
 V.ShellState={width=1000,height=700};V.ShellSizePolicy={defaultWidth=1000,defaultHeight=700,minWidth=400,minHeight=400}
 V.WorkspacePage={requestedTab='navigation'}
 S.Layout={GetContext=function()return {logicalWidth=1024,logicalHeight=768,addonScale=1}end,
  ClampRecoverableTopLeft=function(_,x,y)return math.max(0,x),math.max(0,y)end}
 S.UIV3NativeAdapter={CreateRootWindow=function(_,id)return h.Native(nil,id,0,0,1000,700)end,
  ApplyRect=function(_,n,owner,x,y,w,ht)n.x=x;n.y=y;n.width=w;n.height=ht;return true end,
  SetVisible=function(_,n,owner,v)n.shown=v;return true end,Raise=function()return true end,
  SetRootLayer=function()return true end}
 V.PageHost.Attach=function()return true end;V.PageHost.Navigate=function(_,id)h.route=id;return true end
 V.PageHost.SetVisible=function()return true end;V.PageHost.RefreshData=function()return true end
 V.ModalHost={Attach=function()return true end,Clear=function()end};V.ToastHost={Attach=function()return true end,Clear=function()end}
 S.RSUI.Windowing={Attach=function()return {IsInteracting=function()return false end,IsResizing=function()return false end,
  SetLocked=function()return true end,SetResizeEnabled=function()return true end,LayoutHandles=function()return true end,BringToFront=function()return true end}end}
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
print('WORKSPACE SHELL RESULT '..passed..' passed / '..failed..' failed');if failed>0 then error('workspace shell failures')end

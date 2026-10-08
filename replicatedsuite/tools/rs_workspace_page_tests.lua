local passed,failed=0,0
local function Test(name,fn)local ok,e=xpcall(fn,debug.traceback);if ok then passed=passed+1;print('PASS '..name)else failed=failed+1;print('FAIL '..name..' '..tostring(e))end end
local function Boot()
 local h=dofile('tools/rs_gear_page_test_host.lua')();local S=h.S
 dofile('features/rs_feature_registry.lua');dofile('presentation/v3/navigation/rs_v3_router.lua')
 S.FeatureRuntime.GetControlState=function(_,id)return {implemented=true,enabled=id=='life_tasks',faulted=false}end
 S.FeatureRuntime.SetPreferredEnabled=function()error('unexpected runtime enable during preference editing')end
 dofile('presentation/v3/rs_v3_workspace.lua')
 assert(io.open('presentation/v3/pages/rs_v3_workspace_page.lua','r'),'missing workspace page')
 dofile('presentation/v3/pages/rs_v3_workspace_page.lua')
 local parent=h.Native(nil,'workspace_parent',0,0,620,490)
 local root=assert(S.UIV3.PageHost.factories['system.workspace'](parent,'system.workspace'));assert(root:OnActivated());root:Layout(0,0,620,490)
 return root,S,h
end
Test('navigation hides and restores without losing entry',function()
 local root,S=Boot();assert(root:SetTab('navigation'));assert(root:SelectId('life.tasks'))
 assert(root:PerformAction(1));assert(S.UIV3.Workspace:GetNavPreference('life.tasks').favorite)
 assert(root:PerformAction(2));assert(S.UIV3.Workspace:GetNavPreference('life.tasks').hidden);assert(root:SelectId('life.tasks'))
 assert(root:PerformAction(2));assert(not S.UIV3.Workspace:GetNavPreference('life.tasks').hidden)
 assert(root:SelectId('home'));assert(root.actionButtons[1].enabled==false and root.actionButtons[2].enabled==false)
 assert(root:OnDeactivated())
end)
Test('home empty list keeps a recovery editor and layout fits',function()
 local root,S,h=Boot();assert(root:SetTab('home'))
 for _,c in ipairs(S.UIV3.Workspace:GetCards(true))do root:SelectId(c.id);assert(root:PerformAction(1))end
 assert(#S.UIV3.Workspace:GetCards()==0 and #root.rows==7)
 root:Layout(0,0,440,410)
 for _,button in ipairs(root.actionButtons)do if button.visible then assert(button.width>0 and button.x+button.width<=button.parentComponent.width+1)end end
end)
Test('feature view omits shell and health never queried',function()
 local root,S=Boot();S.FeatureRuntime.GetHealth=function()error('health queried')end;S.FeatureRuntime.GetSnapshot=function()error('snapshot queried')end
 assert(root:SetTab('features'));assert(#root.rows==1 and root.rows[1].id=='life_tasks')
 assert(root:SetFilter('all'));assert(#root.rows>10)
 assert(root:SetTab('appearance'));root:SelectId('gold');assert(root:PerformAction(1));assert(S.UIV3.Workspace:GetSettings().appearance=='gold')
end)
Test('appearance page exposes and applies neutral light theme',function()
 local root,S=Boot();assert(root:SetTab('appearance'));assert(root:SelectId('light'),'light theme missing from appearance list')
 assert(root:PerformAction(1));assert(S.UIV3.Workspace:GetSettings().appearance=='light')
end)
Test('appearance dropdown remains usable after moving the shortcut to the main title bar',function()
 local root,S,h=Boot()
 local function Find(node,id)
  if node.id==id then return node end
  for _,child in ipairs(node.children or {})do local found=Find(child,id);if found then return found end end
 end
 assert(not Find(root,'v3_workspace_appearance_shortcut'),'moved appearance button still duplicated inside the page')
 local selector=assert(Find(root,'v3_workspace_tabs'))
 for _,width in ipairs({440,620})do
  for _,tab in ipairs({'navigation','home','lists','windows','features','appearance'})do
   assert(root:SetTab(tab));root:Layout(0,0,width,410)
   assert(selector.visible and selector.enabled,'workspace selector hidden or disabled in '..tab)
   local visible,why=h:VisibleRect(selector);assert(visible,why)
   assert(selector:SetSelectedValue('appearance',false,'test'))
   assert(root.tab=='appearance' and root:SelectId('light'),'selector did not open the theme list')
  end
 end
 assert(root:PerformAction(1));assert(S.UIV3.Workspace:GetSettings().appearance=='light')
end)
Test('partial native theme repaint is not reported as fully applied',function()
 local root,S=Boot();assert(root:SetTab('appearance'));assert(root:SelectId('light'))
 S.Theme={workspacePaletteFailures=1};local ok,why=root:PerformAction(1)
 assert(ok==false and why:find('主题已保存',1,true));assert(S.UIV3.Workspace:GetSettings().appearance=='light')
end)
Test('all new palette choices are reachable and applicable through the appearance page',function()
 local root,S=Boot();assert(root:SetTab('appearance'));assert(#root.rows==8,'incomplete appearance catalog')
 for _,name in ipairs({'nord','dusk','dawn','sage'})do
  assert(root:SelectId(name),'new palette missing from appearance page: '..name)
  assert(root:PerformAction(1));assert(S.UIV3.Workspace:GetSettings().appearance==name)
 end
end)
print('WORKSPACE PAGE RESULT '..passed..' passed / '..failed..' failed');if failed>0 then error('workspace page failures')end

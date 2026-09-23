-- Module diagnostics header injection contract.
-- The diagnostic affordance must be generated centrally by PageHost/DesignSystem,
-- not copied into every feature page. It must never initialize/enable a feature.
local passed,failed=0,0
local function Test(name,fn)local ok,err=pcall(fn);if ok then passed=passed+1;print('PASS module-diag-header '..name)else failed=failed+1;print('FAIL module-diag-header '..name..': '..tostring(err))end end
local function Boot()
  ReplicatedSuite={Generation=1,RSUI={},UIV3={},SafeTraceback=function(e)return tostring(e)end}
  local S=ReplicatedSuite
  local calls={open={},init=0,enable=0,nodes={}}
  local Node=function(spec)
    local n={id=spec and spec.id,text=spec and spec.text,parent=spec and spec.parent,children={},spec=spec or {}}
    if n.parent and n.parent.children then n.parent.children[#n.parent.children+1]=n end
    if n.id then calls.nodes[n.id]=n end
    return n
  end
  for _,k in ipairs({'VerticalBox','HorizontalBox','Text','Button','ScrollBox'}) do
    S.RSUI[k]=function(_,spec)return Node(spec or {})end
  end
  S.RSUI.WidgetSwitcher=function(_,spec)
    local n=Node(spec or {});function n:SetActiveWidget(w)self.active=w;return true end;return n
  end
  S.RSUI.WithBuildScope=function(_,id,fn)local ok,a,b=pcall(fn);if ok then return true,a,b end;return false,nil,a end
  S.FeatureRegistry={}
  local features={
    ['combat.test']={id='combat_test',route='combat.test',name='测试模块',initialized=false,enabled=false},
    ['system.diagnostics']={id='system_diagnostics',route='system.diagnostics',name='系统诊断',initialized=true,enabled=true},
  }
  function S.FeatureRegistry:GetByRoute(route)return features[route]end
  function S.FeatureRegistry:InitializeFeature()calls.init=calls.init+1;return true end
  function S.FeatureRegistry:SetEnabled()calls.enable=calls.enable+1;return true end
  S.UIV3.ModuleDiagnosticsWindowV3={}
  function S.UIV3.ModuleDiagnosticsWindowV3:Open(id)calls.open[#calls.open+1]=id;return true end
  dofile('presentation/v3/shell/rs_v3_page_host.lua')
  dofile('ui/design_system/rs_ui_design_system_v3.lua')
  local H=S.UIV3.PageHost
  H:Attach(Node({id='host'}))
  H:RegisterFactory('combat.test',function(parent,route,feature)
    local root=S.UIV3Design:PageRoot(parent,'test_root')
    S.UIV3Design:PageHeader(root,'test_header','测试','subtitle','刷新',function()return true end)
    return root
  end)
  H:RegisterFactory('system.diagnostics',function(parent,route,feature)
    local root=S.UIV3Design:PageRoot(parent,'system_root')
    S.UIV3Design:PageHeader(root,'system_header','系统诊断','system')
    return root
  end)
  return S,H,calls
end
Test('feature page automatically receives diagnostic button',function()
  local S,H,c=Boot();assert(H:CreatePage('combat.test'));local b=c.nodes['test_header_diagnostics'];assert(b and b.text=='诊断')
end)
Test('diagnostic click opens current feature only and never starts feature',function()
  local S,H,c=Boot();H:CreatePage('combat.test');local b=c.nodes['test_header_diagnostics'];assert(type(b.spec.onClick)=='function');assert(b.spec.onClick());assert(c.open[1]=='combat_test');assert(c.init==0 and c.enable==0)
end)
Test('existing header action remains alongside diagnostic button',function()
  local S,H,c=Boot();H:CreatePage('combat.test');assert(c.nodes['test_header_action']);assert(c.nodes['test_header_diagnostics'])
end)
Test('system diagnostics page does not recursively inject module diagnostic button',function()
  local S,H,c=Boot();H:CreatePage('system.diagnostics');assert(c.nodes['system_header_diagnostics']==nil)
end)
Test('build context is cleared when factory throws',function()
  local S,H,c=Boot();H:RegisterFactory('combat.fail',function()error('boom')end)
  S.FeatureRegistry.GetByRoute=function(_,route) if route=='combat.fail' then return {id='combat_fail',route=route,name='失败模块'} end return nil end
  local page,err=H:CreatePage('combat.fail');assert(page==nil);assert(H:GetBuildContext()==nil)
end)
Test('build context is cleared after factory returns',function()
  local S,H,c=Boot();H:CreatePage('combat.test');assert(H:GetBuildContext()==nil)
end)
print('MODULE DIAGNOSTICS HEADER RESULT '..passed..' passed / '..failed..' failed ('.._VERSION..')')
if failed>0 then error('module diagnostics header failures: '..failed)end

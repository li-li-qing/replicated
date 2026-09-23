local p,f=0,0
local function T(n,fn)local ok,e=xpcall(fn,debug.traceback);if ok then p=p+1;print('PASS '..n)else f=f+1;print('FAIL '..n..' '..e)end end
local function Boot()
 local h=dofile('tools/rs_gear_page_test_host.lua')();local S=h.S
 dofile('features/rs_feature_registry.lua');dofile('presentation/v3/navigation/rs_v3_router.lua');dofile('presentation/v3/rs_v3_workspace.lua')
 local enabled={life_tasks=true,life_activities=true,life_trade=true,life_bonds=true};local held={}
 S.FeatureRuntime.IsEnabled=function(_,id)return enabled[id]==true end
 S.FeatureRuntime.SetPreferredEnabled=function()error('implicit enable')end
 for _,name in ipairs({'Tasks','Activities','Trade','Bonds'})do
  local F={UpdateTopic='test:'..name};S.Features[name]=F
  function F:AcquireConsumer(token)assert(not held[token],'duplicate consumer');held[token]=true;return true end
  function F:ReleaseConsumer(token)held[token]=nil;return true end
  function F:GetRows()return {{key='e',name='event',fullName='event',status='等待'}},1 end
  function F:GetOverviewProjection(opts)return {rows={{id=opts.scope..':a',scope=opts.scope,groupKey='a',rawName='任务',status='进行中',tracked=true}},revision=1}end
 end
 S.Features.DailyLedger={GetProjection=function()return {rows={},day='2026-09-18'}end}
 dofile('presentation/v3/pages/rs_v3_home_overview.lua')
 local root=assert(S.UIV3.HomeOverview:Build(h.Native(nil,'home_test',0,0,900,640),'home'))
 return root,S,held
end
T('five cards no leases before arrange and correct scope',function()
 local root,S,held=Boot();assert(#root.cards==5,'home must have separate daily weekly cards')
 assert(root:OnActivated());assert(next(held)==nil,'unarranged home acquired consumer')
 root:Layout(0,0,980,730);assert(root:RefreshData());assert(held['home:daily'] and held['home:weekly'])
 assert(root.cards[1].table:GetItem(1).scope=='daily');assert(root.cards[2].table:GetItem(1).scope=='weekly')
 assert(root:OnDeactivated());assert(next(held)==nil)
end)
T('scroll hides releases and empty preferences survives',function()
 local root,S,held=Boot();assert(root:OnActivated());root:Layout(0,0,560,440);root:RefreshData()
 assert(held['home:daily'] and not held['home:weekly']);root.grid:ScrollToBottom();root:RefreshData();assert(not held['home:daily'])
 for _,card in ipairs(S.UIV3.Workspace:GetCards(true))do assert(S.UIV3.Workspace:SetCardVisible(card.id,false))end
 root:Layout(0,0,560,440);root:RefreshData();assert(next(held)==nil);assert(root.empty.visible)
end)
T('reordering cards never reparents and disabled never enabled',function()
 local root,S,held=Boot();assert(root:OnActivated());root:Layout(0,0,900,640);root:RefreshData()
 local original={};for _,card in ipairs(root.cards)do original[card.spec.key]=card.panel.root.parent end
 assert(S.UIV3.Workspace:MoveCard('weekly',-1));root:Layout(0,0,900,640);root:RefreshData()
 for _,card in ipairs(root.cards)do assert(card.panel.root.parent==original[card.spec.key])end
 S.FeatureRuntime.IsEnabled=function()return false end;S.Events:Publish('v3.feature.lifecycle','life_tasks');root:RefreshData();assert(root.cards[1].table:GetItem(1)==nil)
end)
print('HOME WORKSPACE RESULT '..p..' passed / '..f..' failed');if f>0 then error('home failures')end

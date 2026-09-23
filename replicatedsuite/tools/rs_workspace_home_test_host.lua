-- Shared actual RSUI/Persistence home host for .247. Game data is a controlled dependency; no test code enters runtime.
return function(options)
 options=options or {}
 local h=dofile('tools/rs_gear_page_test_host.lua')();local S=h.S;local counts={quotes=0,enabledWrites=0,pauseWrites=0,reads=0,acquired=0,released=0,widgetWrites=0}
 local enabled=options.enabled or {life_trade=true,life_activities=true,life_tasks=true,life_bonds=false,life_daily_stats=true}
 S.FeatureRuntime.IsEnabled=function(_,key)return enabled[key]==true end
 S.FeatureRuntime.SetPreferredEnabled=function(_,key,v)counts.enabledWrites=counts.enabledWrites+1;enabled[key]=v;return true end
 local function Feature(name,id,topic)
  local F={Id=id,UpdateTopic=topic,consumers={},Commands={}}
  function F:AcquireConsumer(token)if not self.consumers[token] then self.consumers[token]=true;counts.acquired=counts.acquired+1 end;return true end
  function F:ReleaseConsumer(token)assert(self.consumers[token],'release missing token');self.consumers[token]=nil;counts.released=counts.released+1;return true end
  function F:GetProjection()counts.reads=counts.reads+1;return {rows={{key='a',name='货物',rate='130%',price='1金',profit='缺价',text='板',quantity=20}},revision=1,zones={{id=1,name='甲'}},sellableZones={{id=2,name='乙'}},fromZone=1,toZone=2,favoriteItems={},pendingQuoteCount=2,quoteBatch={active=false,total=0,completed=0},status='ready'} end
  function F:GetRows()return {{key='event',shortName='征兆',status='1分钟',progressText='0/4'}},1 end
  function F:GetWidgetProjection()return {{id='quest',rawName='任务',cycleText='每日',status='进行中',progressText='1/2'}},1 end
  function F:GetOverviewProjection(opts)self.lastFilters=opts;return {rows={{id=opts.scope..':quest',groupKey='quest',scope=opts.scope,rawName='任务',cycleText=opts.scope=='daily' and '日常' or '周常',status='进行中',progressText='1/2',tracked=true,available=true}},revision=1,summary={tracked=1,unfinished=1}}end
  function F:GetWidgetWindowState()return {}end;function F:GetWidgetVisible()return false end
  function F:GetRouteSettings()return {fromZone=1,toZone=2}end;function F:GetBondFilter()return {sortMode='continent',continentOrder='west_first',q20=true,q60=true,q100=true,auroria=true,excludeSame=false,priority='west'}end;function F:GetContinentOrder()return 'west_first'end
  for _,k in ipairs({'SetFrom','SetTo','SetSortMode','SetRatioMode','SetCommerceMode','ToggleCurrentFavorite','SelectFavorite','SetBondFilterOption','SetContinentOrder','SetDuplicatePriority','SetWidgetWindowState','MarkStoreDirty','SetWidgetVisible'}) do F.Commands[k]=function()return true end end
  F.Commands.QuotePendingMaterials=function(_,mode)counts.quotes=counts.quotes+1;counts.lastMode=mode;return true end
  F.Commands.CancelQuoteBatch=function()counts.cancelled=true;return true end
  S.Features[name]=F;return F
 end
 Feature('Trade','life_trade','v3.life.trade.updated');Feature('Activities','life_activities','v3.activities.updated')
 Feature('Tasks','life_tasks','v3.tasks.updated');Feature('Bonds','life_bonds','v3.life.bonds.updated');Feature('Treasure','life_treasure','treasure');Feature('Fishing','life_fishing','fishing')
 S.Features.DailyLedger={paused=false,SetPaused=function(self,v)self.paused=v==true;counts.pauseWrites=counts.pauseWrites+1;return true end,GetProjection=function(self)local rows={};for _,k in ipairs({'gold','honor','experience','living'})do rows[#rows+1]={key=k,name=k,status=self.paused and 'paused' or 'unconnected'}end;return {day='2026-09-12',rows=rows,enabled=true,paused=self.paused,revision=1}end}
 local widgetVisible={}
 S.UIV3.WidgetHost={
  Register=function()return true end,BindFeatureLifecycle=function()return true end,
  IsVisible=function(_,id)return widgetVisible[id]==true end,
  SetVisible=function(_,id,value,context)counts.widgetWrites=counts.widgetWrites+1;counts.lastWidget=id;widgetVisible[id]=value==true;return true end
 }
 S.RSUI.FloatingSurface={CreateStateAdapter=function()return {}end}
 dofile('presentation/v3/widgets/rs_v3_life_economy_widgets.lua')
 dofile('features/rs_feature_registry.lua');dofile('presentation/v3/navigation/rs_v3_router.lua')
 dofile('presentation/v3/rs_v3_workspace.lua')
 if options.visible then assert(S.UIV3.Workspace:Change('home',function()local v={};for _,key in ipairs(options.visible)do v[key]=true end;for _,card in ipairs(S.UIV3.Workspace:GetCards(true))do S.UIV3.Workspace.state.home.hidden[card.id]=not v[card.id] or nil end;return true end))end
 dofile('presentation/v3/pages/rs_v3_home_overview.lua')
 local parent=h.Native(nil,'home_parent',0,0,850,700)
 local page=assert(S.UIV3.HomeOverview:Build(parent,'home'));if not options.skipLayout then page:Layout(0,0,850,700)end
 local index={};local function Walk(n)index[n.id]=n;for _,v in ipairs(n.children or {})do Walk(v)end end;Walk(page)
 return S,page,index,counts,enabled,h
end

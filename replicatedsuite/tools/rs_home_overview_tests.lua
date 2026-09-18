-- Actual RSUI layout and EventBus; Feature facts + Native widgets are controlled test inputs.
local pass,fail=0,0
local function Test(n,f)local ok,e=pcall(f);if ok then pass=pass+1;print('PASS home '..n)else fail=fail+1;print('FAIL home '..n..': '..tostring(e))end end
local function Boot()
 local h=dofile('tools/rs_gear_page_test_host.lua')();local S=h.S;local counts={quotes=0,enabledWrites=0,pauseWrites=0,reads=0,acquired=0,released=0,widgetWrites=0}
 local enabled={life_trade=true,life_activities=true,life_tasks=true,life_bonds=false,life_daily_stats=true}
 S.FeatureRuntime.IsEnabled=function(_,key)return enabled[key]==true end
 S.FeatureRuntime.SetPreferredEnabled=function(_,key,v)counts.enabledWrites=counts.enabledWrites+1;enabled[key]=v;return true end
 local function Feature(name,id,topic)
  local F={Id=id,UpdateTopic=topic,consumers={},Commands={}}
  function F:AcquireConsumer(token)if not self.consumers[token] then self.consumers[token]=true;counts.acquired=counts.acquired+1 end;return true end
  function F:ReleaseConsumer(token)assert(self.consumers[token],'release missing token');self.consumers[token]=nil;counts.released=counts.released+1;return true end
  function F:GetProjection()counts.reads=counts.reads+1;return {rows={{key='a',name='货物',rate='130%',price='1金',profit='缺价',text='板',quantity=20}},revision=1,zones={{id=1,name='甲'}},sellableZones={{id=2,name='乙'}},fromZone=1,toZone=2,favoriteItems={},pendingQuoteCount=2,quoteBatch={active=false,total=0,completed=0},status='ready'} end
  function F:GetRows()return {{key='event',shortName='征兆',status='1分钟',progressText='0/4'}},1 end
  function F:GetWidgetProjection()return {{id='quest',rawName='任务',cycleText='每日',status='进行中',progressText='1/2'}},1 end
  function F:GetOverviewProjection()return {rows={{id='daily:quest',groupKey='quest',scope='daily',rawName='任务',cycleText='日常',status='进行中',progressText='1/2',tracked=true,available=true}},revision=1,summary={tracked=1,unfinished=1}}end
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
 dofile('presentation/v3/pages/rs_v3_home_overview.lua')
 local parent=h.Native(nil,'home_parent',0,0,850,700)
 local page=assert(S.UIV3.HomeOverview:Build(parent,'home'));page:Layout(0,0,850,700)
 local index={};local function Walk(n)index[n.id]=n;for _,v in ipairs(n.children or {})do Walk(v)end end;Walk(page)
 return S,page,index,counts,enabled
end
Test('home renders live activities and trade data instead of placeholder cards',function()
 local S,p,n,c=Boot();assert(p:OnActivated());assert(n.v3_home_activity_table:GetItemCount()==1);assert(n.v3_home_trade_table:GetItemCount()==1)
 assert(c.quotes==0 and c.enabledWrites==0,'opening home triggered quote or forced feature enable')
 assert(n.v3_home_trade_table.height>30,'unmeasured data table')
end)
Test('independent consumer ownership does not release another floating window',function()
 local S,p,n,c=Boot();S.Features.Trade.consumers['widget:trade']=true
 assert(p:OnActivated());local a=c.acquired;p:OnActivated();assert(c.acquired==a)
 assert(p:OnDeactivated());assert(S.Features.Trade.consumers['widget:trade']);assert(c.acquired==c.released)
end)
Test('disabled bonds shows off and does not start native collection',function()
 local S,p,n,c=Boot();p:OnActivated();p:SetWorkspace('tasks');assert(not next(S.Features.Bonds.consumers));assert(n.v3_home_bonds_table:GetViewState()=='empty' or n.v3_home_bonds_table:GetViewState()=='unavailable')
end)
Test('same content builder supports unique widget and home control identities',function()
 local S,p,n,c=Boot();assert(n.v3_home_trade_from and n.v3_home_trade_to)
 -- Named home controls remain unique; advanced searches are intentionally only
 -- on full trade views. Ordinary click retains the default bounded batch.
 assert(n.v3_home_trade_quote and not n.v3_home_trade_cancel_quote)
 assert(not n.v3_home_trade_full_quote)
 assert(n.v3_home_trade_quote.onClick());assert(c.quotes==1 and c.lastMode==nil)
end)
Test('small viewport stacks cards instead of squeezing four feature panels',function()
 local S,p,n=Boot();local grid=n.v3_home_data_grid;assert(grid:ResolveColumns(640,4)==1);assert(grid:ResolveColumns(850,4)==2)
 for _,w in ipairs({640,800,1080,1700})do
  p:Layout(0,0,w,650)
  local seen={}
  for _,workspace in ipairs({'world','tasks'})do p:SetWorkspace(workspace)
   for slot=1,2 do p:SetCompactCard(slot)
    for _,card in ipairs(p.cards)do if card.panel.viewportVisible then
     seen[card.spec.name]=true;local t=card.table or card.content.table;assert(t.height>30,'collapsed table')
     assert(card.panel.y>=0 and card.panel.y+card.panel.height<=grid.height+0.1,'viewport escape')
    end end
   end
  end
  for _,name in ipairs({'Activities','Trade','Tasks','Bonds'})do assert(seen[name],'inaccessible card '..name)end
 end
end)
Test('unconnected gains never render fabricated zero',function()
 local S,p,n=Boot();p:OnActivated();assert(n.v3_home_stat_gold.text=='—' and n.v3_home_stat_source_gold.text=='待接入')
end)
Test('economy body fills card and keeps useful visible rows',function()
 local S,p,n,c=Boot();p:OnActivated();p:Layout(0,0,850,700)
 assert(n.v3_home_trade_table.height>150,'economy body shrank to only one row')
end)
Test('home navigation uses Shell authority instead of missing UIV3.Navigate shim',function()
 local S,p,n=Boot();local route
 S.UIV3.Navigate=nil
 S.UIV3.Shell={Navigate=function(_,r)route=r;return true end}
 assert(n.v3_home_trade_open.onClick());assert(route=='life.trade')
end)

Test('home cards expose direct floating-window buttons and can enable a disabled feature before opening',function()
 local S,p,n,c,enabled=Boot()
 assert(n.v3_home_activity_widget and n.v3_home_trade_widget and n.v3_home_tasks_widget and n.v3_home_bonds_widget, 'missing home floating shortcuts')
 assert(n.v3_home_trade_widget.onClick());assert(c.lastWidget=='life.trade' and c.widgetWrites==1)
 assert(enabled.life_bonds==false)
 assert(n.v3_home_bonds_widget.onClick());assert(enabled.life_bonds==true,'disabled bonds was not enabled by explicit floating shortcut')
 assert(c.lastWidget=='life.bonds' and c.widgetWrites==2)
end)

Test('non-trade feature changes coalesce once and deactivate cancels pending work',function()
 local S,p,n,c=Boot();p:OnActivated();local before=c.reads
 for i=1,20 do S.Events:Publish('v3.activities.updated')end
 assert(c.reads==before and S.Scheduler.tasks.v3_home_refresh)
 p:OnDeactivated();assert(not S.Scheduler.tasks.v3_home_refresh);assert(c.quotes==0)
end)
Test('pause button uses transient ledger pause instead of feature preference write',function()
 local S,p,n,c=Boot();assert(p:OnActivated());assert(n.v3_home_stats_toggle.text=='暂停统计')
 assert(n.v3_home_stats_toggle.onClick());assert(S.Features.DailyLedger.paused==true and c.pauseWrites==1 and c.enabledWrites==0)
 p:RefreshData();assert(n.v3_home_stats_toggle.text=='继续统计')
 assert(n.v3_home_stats_toggle.onClick());assert(S.Features.DailyLedger.paused==false and c.pauseWrites==2 and c.enabledWrites==0)
end)


Test('registered native delta source stays probing until first real change',function()
 local S,p,n=Boot()
 S.Features.DailyLedger.GetProjection=function()
  return {day='2026-09-13',enabled=true,paused=false,verifiedSources=0,rows={
   {key='gold',status='probing',value=nil},{key='honor',status='probing',value=nil},
   {key='experience',status='unconnected',value=nil},{key='living',status='probing',value=nil}}}
 end
 assert(p:OnActivated())
 assert(n.v3_home_stat_gold.text=='—')
 assert(n.v3_home_stat_source_gold.text=='监听中 · 等待变化')
end)

Test('daily ledger update refreshes statistic cards immediately without scheduler delay',function()
 local S,p,n,c=Boot();local value=100
 S.Features.DailyLedger.GetProjection=function(self)
  return {day='2026-09-13',enabled=true,paused=false,verifiedSources=1,rows={
   {key='gold',status='ready',value=value},{key='honor',status='unconnected',value=nil},
   {key='experience',status='unconnected',value=nil},{key='living',status='unconnected',value=nil}}}
 end
 assert(p:OnActivated());local before=n.v3_home_stat_gold.text
 value=500;S.Events:Publish('v3.daily_ledger.updated')
 assert(n.v3_home_stat_gold.text~=before,'gold card stayed stale after ledger event')
 assert(S.Scheduler.tasks.v3_home_refresh==nil,'ledger update should not wait on shared 100ms refresh task')
end)


Test('visible home trade card applies trade updates immediately without the shared delayed refresh queue',function()
 local S,p,n,c=Boot()
 local rows={{key='before',name='旧货物',rate='100%',price='1金',profit='--'}}
 local revision=1
 S.Features.Trade.GetProjection=function()
  c.reads=c.reads+1
  return {rows=rows,revision=revision,zones={{id=1,name='甲'}},sellableZones={{id=2,name='乙'}},fromZone=1,toZone=2,
   favoriteItems={},pendingQuoteCount=0,quoteBatch={active=false,total=0,completed=0},status='ready'}
 end
 assert(p:OnActivated())
 assert(n.v3_home_trade_table:GetItem(1).key=='before')
 rows={{key='after',name='新货物',rate='130%',price='2金',profit='--'}};revision=2
 S.Events:Publish('v3.life.trade.updated')
 assert(n.v3_home_trade_table:GetItem(1).key=='after',
  'home trade view stayed stale until the generic 100ms whole-page refresh ran')
 assert(not S.Scheduler.tasks.v3_home_refresh,
  'trade-only projection updates should not depend on the shared delayed whole-page refresh task')
end)

print('HOME RESULT '..pass..' passed / '..fail..' failed');if fail>0 then error('home tests failed')end

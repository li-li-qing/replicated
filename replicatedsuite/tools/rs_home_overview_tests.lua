-- .247 migration of home regression: personalization replaces mutually exclusive tabs.
-- Preserve data, lease, explicit-enable, statistics and immediate trade assertions.
local pass,fail=0,0
local function Test(n,f)local ok,e=xpcall(f,debug.traceback);if ok then pass=pass+1;print('PASS home '..n)else fail=fail+1;print('FAIL home '..n..': '..tostring(e))end end
local Host=dofile('tools/rs_workspace_home_test_host.lua')
local function Boot()return Host({visible={'activities','trade'}})end
local function Show(S,p,keys)
 local chosen={};for _,k in ipairs(keys)do chosen[k]=true end
 assert(S.UIV3.Workspace:Change('home',function()for _,c in ipairs(S.UIV3.Workspace:GetCards(true))do S.UIV3.Workspace.state.home.hidden[c.id]=not chosen[c.id] or nil end;return true end))
 p:Layout(0,0,p.width,p.height);p:RefreshData()
end
local function Drain(S,p)
 S.Scheduler:RemoveTask('v3_home_refresh');p.refreshQueued=false;p:RefreshData()
end
Test('home renders live activities and trade data instead of placeholder cards',function()
 local S,p,n,c=Boot();assert(p:OnActivated());assert(n.v3_home_activities_table:GetItemCount()==1);assert(n.v3_home_trade_table:GetItemCount()==1)
 assert(c.quotes==0 and c.enabledWrites==0,'opening home triggered quote or forced feature enable')
 assert(n.v3_home_trade_table.height>30,'unmeasured data table')
end)
Test('independent consumer ownership does not release another floating window',function()
 local S,p,n,c=Boot();S.Features.Trade.consumers['widget:trade']=true
 assert(p:OnActivated());local a=c.acquired;p:OnActivated();assert(c.acquired==a)
 assert(p:OnDeactivated());assert(S.Features.Trade.consumers['widget:trade']);assert(c.acquired==c.released)
end)
Test('disabled bonds shows off and does not start native collection',function()
 local S,p,n,c=Boot();p:OnActivated();Show(S,p,{'daily','bonds'});assert(not next(S.Features.Bonds.consumers));assert(n.v3_home_bonds_table:GetViewState()=='empty' or n.v3_home_bonds_table:GetViewState()=='unavailable')
end)
Test('same content builder supports unique widget and home control identities',function()
 local S,p,n,c=Boot();assert(n.v3_home_trade_from and n.v3_home_trade_to)
 -- Named home controls remain unique; advanced searches are intentionally only
 -- on full trade views. Ordinary click retains the default bounded batch.
 assert(n.v3_home_trade_quote and not n.v3_home_trade_cancel_quote)
 assert(not n.v3_home_trade_full_quote)
 assert(n.v3_home_trade_quote.onClick());assert(c.quotes==1 and c.lastMode==nil)
end)
Test('small viewport exposes each configured card through row scrolling',function()
 local S,p,n=Boot();Show(S,p,{'daily','weekly','activities','bonds','trade'});local grid=p.grid
 assert(grid:ResolveColumns(640)==1 and grid:ResolveColumns(850)==2)
 for _,w in ipairs({440,640,800,1080,1700})do
  p:Layout(0,0,w,650);local seen={}
  for offset=0,grid.maxScrollOffset do
   grid:SetScrollOffset(offset);p:RefreshData()
   for _,card in ipairs(p.cards)do if card.panel.viewportVisible then
    seen[card.spec.key]=true;local t=card.table or card.content.table
    assert(t.height>30,'collapsed table '..card.spec.key)
    assert(card.panel.y>=0 and card.panel.y+card.panel.height<=grid.height+0.1,'viewport escape')
   end end
  end
  for _,key in ipairs({'daily','weekly','activities','bonds','trade'})do assert(seen[key],'inaccessible card '..key)end
 end
end)
Test('unconnected gains never render fabricated zero',function()
 local S,p,n=Boot();p:OnActivated();assert(n.v3_home_stat_gold.text=='—')
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
 assert(n.v3_home_activities_widget and n.v3_home_trade_widget and n.v3_home_daily_widget and n.v3_home_bonds_widget, 'missing home floating shortcuts')
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
 assert(n.v3_home_stat_living.text=='—' and not n.v3_home_stat_source_gold)
end)

Test('daily ledger update refreshes statistic cards immediately without scheduler delay',function()
 local S,p,n,c=Boot();local value=100
 S.Features.DailyLedger.GetProjection=function(self)
  return {day='2026-09-13',enabled=true,paused=false,verifiedSources=1,rows={
   {key='gold',status='ready',value=value},{key='honor',status='unconnected',value=nil},
   {key='experience',status='unconnected',value=nil},{key='living',status='unconnected',value=nil}}}
 end
 assert(p:OnActivated());Drain(S,p);local before=n.v3_home_stat_gold.text
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
 assert(p:OnActivated());Drain(S,p)
 assert(n.v3_home_trade_table:GetItem(1).key=='before')
 rows={{key='after',name='新货物',rate='130%',price='2金',profit='--'}};revision=2
 S.Events:Publish('v3.life.trade.updated')
 assert(n.v3_home_trade_table:GetItem(1).key=='after',
  'home trade view stayed stale until the generic 100ms whole-page refresh ran')
 assert(not S.Scheduler.tasks.v3_home_refresh,
  'trade-only projection updates should not depend on the shared delayed whole-page refresh task')
end)

Test('explicit enable-and-open rolls back only the newly enabled feature on window failure',function()
 local S,p,n,c,enabled=Boot();S.UIV3.WidgetHost.SetVisible=function()return false,'create_failed'end
 assert(n.v3_home_bonds_widget.onClick()==false);assert(enabled.life_bonds==false and c.enabledWrites==2)
 local before=c.enabledWrites;assert(n.v3_home_trade_widget.onClick()==false)
 assert(enabled.life_trade==true and c.enabledWrites==before,'opening failure stopped an existing feature')
end)
print('HOME RESULT '..pass..' passed / '..fail..' failed');if fail>0 then error('home tests failed')end

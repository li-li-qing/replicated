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
 local S,p,n,c=Boot();assert(n.v3_home_trade_settings and not n.v3_home_trade_from and not n.v3_home_trade_to)
 -- 中文维护注释（2026-09-28，Phase 0 测试基线校正）：本用例原先断言首页卡存在 `v3_home_trade_quote`
 -- 且不存在 cancel/full 变体，然后点击它并期望一次批量询价。当前 Authority
 -- （presentation/v3/widgets/rs_v3_life_economy_widgets.lua:105 “构建和刷新绝不发出材料询价”、
 -- :443 只要求“单行询价” QuoteRowMaterials）已不再在首页卡提供批量询价按钮：批量/高级询价只属于
 -- 完整跑商页（rs_v3_business_pages.lua:1002 / rs_v3_life_m16_pages.lua:198）。核对 .298 归档里的同名
 -- 模块后发现当时同样没有 `_quote` 控件（QuotePendingMaterials 引用为 0），因此这是长期存在的过期断言，
 -- 不是本轮回归。改为证明当前契约：首页卡只暴露有界默认动作，绝不伪造批量/高级询价入口。
 assert(not n.v3_home_trade_quote and not n.v3_home_trade_cancel_quote and not n.v3_home_trade_full_quote)
 assert(n.v3_home_trade_table,'home trade card lost its data table')
 assert(c.quotes==0,'building the home card issued a batch quote')
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
 local S,p,n=Boot();p:OnActivated();assert(n.v3_home_stat_gold.text=='--')
end)
Test('one-row economy body fits actual content instead of reserving empty rows',function()
 local S,p,n,c=Boot();p:OnActivated();p:Layout(0,0,850,700)
 assert(n.v3_home_trade_table.height>=48 and n.v3_home_trade_table.height<=70,'one-row economy kept oversized empty space')
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
 assert(n.v3_home_stat_gold.text=='--')
 assert(n.v3_home_stat_living.text=='--' and not n.v3_home_stat_source_gold)
end)

Test('statistic signs retain copper totals and distinguish unknown from genuine zero',function()
 local S,p,n,c=Boot();local value=-123456
 S.Features.DailyLedger.GetProjection=function()
  return {day='2026-10-04',enabled=true,paused=false,rows={
   {key='gold',status='ready',value=value},{key='honor',status='ready',value=-19},
   {key='experience',status='unconnected'},{key='living',status='ready',value=0}}}
 end
 assert(p:OnActivated())
 assert(n.v3_home_stat_gold.text=='-12金34银56铜' and n.v3_home_stat_gold.state.tone=='orange')
 assert(n.v3_home_stat_honor.text=='-19' and n.v3_home_stat_experience.text=='--' and n.v3_home_stat_living.text=='+0')
 value=-10000;assert(p:RefreshStats());assert(n.v3_home_stat_gold.text=='-1金0银')
 value=-1;assert(p:RefreshStats());assert(n.v3_home_stat_gold.text=='-0金0银1铜')
 value=1611;assert(p:RefreshStats());assert(n.v3_home_stat_gold.text=='+0金16银11铜')
 value=0;assert(p:RefreshStats());assert(n.v3_home_stat_gold.text=='0金')
 value=-520000000;assert(p:RefreshStats());assert(n.v3_home_stat_gold.text=='-52000金0银')
 S.Features.DailyLedger.GetProjection=function()return {rows={}}end
 assert(p:RefreshStats());assert(n.v3_home_stat_gold.text=='--' and n.v3_home_stat_living.text=='--')
 assert(c.pauseWrites==0 and c.enabledWrites==0,'presentation changed statistic preferences')
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
Test('compact home adds harvest and reminder cards with three responsive columns',function()
 local S,p,n,c=Host();assert(p:OnActivated());p:Layout(0,0,1160,780);p:RefreshData()
 assert(#p.cards==7 and p.cardByKey.stats and p.cardByKey.reminders,'missing compact cards')
 assert(p.grid:ResolveColumns(1160)==3 and p.grid:ResolveColumns(850)==2 and p.grid:ResolveColumns(440)==1)
 assert(n.v3_home_stats_title.text=='今日收获' and n.v3_home_reminders_title.text=='装备与每日提醒')
 assert(n.v3_home_stat_gold and n.v3_home_reminder_costume and n.v3_home_reminder_underwear)
 assert(n.v3_home_reminder_daily and n.v3_home_reminder_guild)
 assert(p.cardByKey.stats.panel.height<=200 and p.cardByKey.reminders.panel.height<=200)
 assert(p.cardByKey.trade.panel.height<=110,'one-row trade retained a large fixed card')
 assert(c.enabledWrites==0 and c.quotes==0,'compact layout changed business state')
end)
Test('all seven compact cards remain accessible without overlap or native reparenting',function()
 local S,p,n=Host();assert(p:OnActivated());local parents={}
 for _,card in ipairs(p.cards)do parents[card.spec.key]=card.panel.root.parent end
 for _,size in ipairs({{440,470},{850,700},{1160,780},{1700,950}})do
  p:Layout(0,0,size[1],size[2]);local seen={}
  for offset=0,p.grid.maxScrollOffset do
   p.grid:SetScrollOffset(offset);p:RefreshData();local visible={}
   for _,card in ipairs(p.cards)do if card.panel.viewportVisible then
    seen[card.spec.key]=true;visible[#visible+1]=card.panel
    assert(card.panel.y>=0 and card.panel.y+card.panel.height<=p.grid.height+0.1,'card escaped viewport')
    assert(card.panel.root.parent==parents[card.spec.key],'card reparented')
    local t=card.table or card.content and card.content.table
    if t then assert(t.height>=48,'unusable compact table '..card.spec.key)end
   end end
   for i,a in ipairs(visible)do for j=i+1,#visible do local b=visible[j]
    assert(a.x+a.width<=b.x+0.1 or b.x+b.width<=a.x+0.1 or a.y+a.height<=b.y+0.1 or b.y+b.height<=a.y+0.1,'overlapping compact cards')
   end end
  end
  for _,card in ipairs(p.cards)do assert(seen[card.spec.key],'unreachable '..card.spec.key)end
 end
end)
local function ReminderFixture(h)
 ES_COSPLAY,ES_UNDERPANTS='costume','underwear';TADT_TODAY,TADT_EXPEDITION='daily','guild'
 h.reminderReads=0
 X2Equipment.GetEquippedItemTooltipInfo=function(_,slot,selector)
  h.reminderReads=h.reminderReads+1;assert(selector==false)
  return {name='测试装备',evolvingInfo={remainTime={year=0,month=0,day=slot=='costume' and 2 or 0,hour=0,minute=0,second=0}}}
 end
 X2Achievement={GetTodayAssignmentInfo=function(_,kind,index)
  h.reminderReads=h.reminderReads+1;return {status=kind=='daily' and index==1 and 1 or 2}
 end}
end
Test('visible reminder card paints actual read model and manual refresh without enabling features',function()
 local S,p,n,c,_,h=Host({visible={'stats','reminders'},configureReminders=ReminderFixture,skipLayout=true})
 assert(h.reminderReads==0);p:OnActivated();assert(h.reminderReads==0,'unmeasured card scanned Native')
 p:Layout(0,0,850,700);p:RefreshData();assert(h.reminderReads==16)
 assert(n.v3_home_reminder_costume.text=='剩余 2天' and n.v3_home_reminder_underwear.text=='已到期')
 assert(n.v3_home_reminder_daily.text=='还有 1项未接' and n.v3_home_reminder_guild.text=='已接 7/7')
 assert(n.v3_home_reminders_refresh.onClick() and h.reminderReads==32)
 assert(c.enabledWrites==0 and c.quotes==0 and c.pauseWrites==0)
end)
Test('hiding reminders immediately releases reads and does not restart on layout or snapshots',function()
 local S,p,n,c,_,h=Host({visible={'stats','reminders'},configureReminders=ReminderFixture})
 assert(p:OnActivated());local C=S.Services.HomeRemindersV3;assert(C.running)
 for _,size in ipairs({{440,650},{1160,780},{850,700}})do p:Layout(0,0,size[1],size[2]);p:RefreshData()end
 assert(h.reminderReads==16,'layout re-acquired a held reminder lease')
 local reads=h.reminderReads;assert(S.UIV3.Workspace:SetCardVisible('reminders',false))
 assert(not C.running and not S.Scheduler.tasks[C.taskName],'hidden card retained Native task')
 assert(n.v3_home_reminders_refresh.onClick()==false)
 p:RefreshData();C:GetHealth();assert(h.reminderReads==reads)
 assert(S.UIV3.Workspace:SetCardVisible('reminders',true));p:RefreshData();assert(C.running and h.reminderReads==reads+16)
 assert(p:OnDeactivated());assert(not C.running and not S.Scheduler.tasks[C.taskName])
end)
Test('permanent costume and underwear paint permanent text in the visible compact card',function()
 local S,p,n,c,_,h=Host({visible={'reminders'},configureReminders=function(host)
  ReminderFixture(host)
  X2Equipment.GetEquippedItemTooltipInfo=function(_,slot,selector)
   host.reminderReads=host.reminderReads+1;assert(selector==false)
   return {itemType=90001,name='永久装备',evolvingInfo={modifier={}}}
  end
 end})
 assert(p:OnActivated());assert(n.v3_home_reminder_costume.text=='永久' and n.v3_home_reminder_underwear.text=='永久')
 assert(h.reminderReads==16 and c.enabledWrites==0 and c.pauseWrites==0)
 assert(S.Services.HomeRemindersV3:GetHealth().rows[1].expirationEvidence.policy=='identified_item_without_countdown')
end)
Test('legacy statistics option hides the compact harvest card without pausing the ledger',function()
 local S,p,n,c=Host({visible={'stats','reminders'}});assert(p:OnActivated())
 assert(p.cardByKey.stats.panel.viewportVisible);assert(S.UIV3.Workspace:SetOption('stats',false))
 assert(not p.cardByKey.stats.panel.viewportVisible and c.pauseWrites==0 and c.enabledWrites==0)
 assert(S.UIV3.Workspace:SetCardVisible('stats',true));assert(p.cardByKey.stats.panel.viewportVisible)
end)
Test('complete diagnostics include reminder raw expiry and assignment evidence without getters or writes',function()
 local S,p,n,c,_,h=Host({visible={'reminders'},configureReminders=ReminderFixture,diagnostics=true})
 assert(p:OnActivated());local reads,writes=h.reminderReads,h.writes
 local report,err,full=S.ModuleDiagnosticsHub:BuildReport('life_daily_stats',{detailed=true});assert(report,err)
 assert(full:find('home_reminders',1,true) and full:find('expirationEvidence',1,true) and full:find('samples',1,true),'reminder evidence absent')
 assert(h.reminderReads==reads and h.writes==writes,'diagnostics changed live state')
 assert(p:OnDeactivated());S.ModuleDiagnosticsHub:BuildReport('life_daily_stats',{detailed=true})
 assert(h.reminderReads==reads and not S.Services.HomeRemindersV3.running,'hidden diagnostics started reminders')
end)
Test('compact activity card retains separately scrollable timeline and live regions',function()
 local S,p=Host({visible={'activities'}});local rows={}
 for i=1,12 do rows[#rows+1]={key='time'..i,shortName='活动'..i,status='1分钟',progressText='0/4'}end
 for i=1,5 do rows[#rows+1]={key='live'..i,shortName='实时'..i,status='进行中',progressText='0/4',presentationSection='live'}end
 S.Features.Activities.GetRows=function()return rows,2 end;assert(p:OnActivated())
 for _,size in ipairs({{440,470},{850,700},{1160,780}})do
  p:Layout(0,0,size[1],size[2]);p:RefreshData();local t=p.cardByKey.activities.table
  assert(t.timeline and t.live and t:GetItemCount()==17,'activity sections/data lost')
  assert(t.timeline.height>=t.timeline.headerHeight+t.timeline.rowHeight and t.live.height>=t.live.headerHeight+t.live.rowHeight,'unusable activity section')
  t.timeline:SetScrollOffset(11);t.live:SetScrollOffset(4)
  assert(t.timeline.list.scrollOffset>0 or t.timeline.list.visibleCapacity>=12,'timeline neither fits nor scrolls')
  local liveOffset=t.live.list.scrollOffset
  assert(liveOffset>0 or t.live.list.visibleCapacity>=5,'live regions neither fit nor scroll')
  t.timeline:SetScrollOffset(0);assert(t.live.list.scrollOffset==liveOffset,'timeline reset scrolled live section')
 end
end)
Test('screenshot-sized home has no body toolbars and uses free height for actual rows',function()
 local S,p,n,c=Host({enabled={life_tasks=true,life_trade=true,life_bonds=true,life_activities=true,life_daily_stats=true}})
 S.Features.Tasks.GetOverviewProjection=function(_,opts)local rows={};for i=1,(opts.scope=='daily' and 20 or 4)do rows[i]={id=opts.scope..i,scope=opts.scope,rawName='任务'..i,status='进行中',progressText='0/1'}end;return {rows=rows,revision=2}end
 for _,name in ipairs({'Trade','Bonds'})do local F=S.Features[name];local old=F.GetProjection
  F.GetProjection=function(self)local result=old(self);result.rows={};for i=1,(name=='Trade' and 8 or 3)do result.rows[i]={key=name..i,name='货物'..i,text='居民板'..i,rate='105%',price='1金',profit='--'}end;return result end
 end
 S.Features.Activities.GetRows=function()local rows={};for i=1,8 do rows[i]={key='activity'..i,shortName='活动'..i,status='进行中',presentationSection=i>3 and 'live' or nil}end;return rows,2 end
 assert(p:OnActivated());p:Layout(0,0,845,700);for i=1,3 do p:RefreshData()end
 for _,card in ipairs(p.cards)do assert(card.panel.viewportVisible,'compact screenshot still hides '..card.spec.key)end
 assert(p.cardByKey.stats.panel.height<=140 and p.cardByKey.bonds.panel.height<=145,'short cards retained empty space')
 assert(p.cardByKey.weekly.panel.height<=160,'short weekly list retained empty space')
 assert(p.cardByKey.daily.table.list.visibleCapacity>=8,'free column height did not reveal more daily tasks')
 assert(p.cardByKey.trade.content.table.list.visibleCapacity>=8,'eight cargo rows still require scrolling')
 assert(p.grid.height-p.grid.totalContentHeight<22,'a usable whole row remains unused below the cards')
 assert(n.v3_home_trade_settings and n.v3_home_bonds_settings,'title settings missing')
 assert(not n.v3_home_trade_route and not n.v3_home_bonds_settings_row,'toolbar still inside content')
 assert(p.cardByKey.trade.content.controls.parentComponent==n.v3_home_trade_header)
 assert(p.cardByKey.bonds.content.controls.parentComponent==n.v3_home_bonds_header)
 assert(c.quotes==0 and c.enabledWrites==0,'density update changed business state')
end)
Test('single line home header keeps actions reachable at narrow and wide widths',function()
 local S,p,n,c,_,h=Host({visible={'reminders'}});assert(p:OnActivated())
 assert(p.compactPageChrome==true,'home did not request compact host spacing')
 for _,width in ipairs({310,440,700,845,1160})do
  p.parent.width=width;p:Layout(0,0,width,700)
  assert(p.grid.y<=28,'home header still occupies two rows')
  for _,id in ipairs({'v3_home_customize','v3_home_previous','v3_home_next'})do
   local ok,why=h:VisibleRect(n[id]);assert(ok,id..':'..tostring(why))
  end
 end
 assert(c.quotes==0 and c.enabledWrites==0)
end)
Test('actual home and module host share a compact header and retain native controls',function()
 local S,old,n,c,_,h=Host({deferBuild=true})
 dofile('presentation/v3/shell/rs_v3_module_controls.lua');dofile('presentation/v3/shell/rs_v3_page_host.lua')
 local H=S.UIV3.PageHost;local native=h.Native(nil,'home_host_native',0,0,845,700)
 local frame=S.RSUI:Border({id='home_host_border',parent=native,padding=6})
 local parent=S.RSUI:Overlay({id='home_host_root',parent=frame});assert(H:Attach(parent))
 H:RegisterFactory('home',function(p)return S.UIV3.HomeOverview:Build(p,'home')end)
 assert(H:Navigate('home'));frame:Layout(0,0,845,700)
 local p=H.pages.home;assert(p:RefreshData());S.RSUI:FlushLayoutQueue(32)
 local nodes={};local function Walk(node)nodes[node.id]=node;for _,child in ipairs(node.children or {})do Walk(child)end end;Walk(frame)
 local ok,rect=h:VisibleRect(p.grid);assert(ok,tostring(rect));assert(rect.y<=58,'shared host still leaves the large top band')
 local bar=H.moduleControls.home
 for _,control in ipairs({bar.toggle,bar.diagnostics,nodes.v3_home_customize,nodes.v3_home_next})do
  local shown,reason=h:VisibleRect(control);assert(shown,tostring(reason))
 end
 assert(nodes.v3_home_diagnostics==nil,'compact header duplicated the shared diagnostics button')
 assert(c.quotes==0 and c.enabledWrites==0,'host spacing changed business state')
 H:RegisterFactory('life.tasks',function(parent)return S.RSUI:VerticalBox({id='home_host_tasks',parent=parent})end)
 assert(H:Navigate('life.tasks'));assert(p.active==false and not H.compactPageChrome)
end)
Test('equipment and quest reminders occupy two paired rows without overlap',function()
 local S,p,n,c,_,h=Host({visible={'reminders'},configureReminders=ReminderFixture});assert(p:OnActivated())
 for _,width in ipairs({440,845,1160})do
  p.parent.width=width;p:Layout(0,0,width,700)
  local function Rect(key)local ok,rect=h:VisibleRect(n['v3_home_reminder_'..key]);assert(ok,tostring(rect));return rect end
  local a,b,d,g=Rect('costume'),Rect('underwear'),Rect('daily'),Rect('guild')
  assert(a.y==b.y and d.y==g.y and d.y>a.y,'reminders still occupy four rows')
  assert(a.x+a.w<=b.x and d.x+d.w<=g.x,'paired reminder fields overlap')
  assert(p.cardByKey.reminders.panel.height<=80,'two-row reminder card retained empty space')
  assert(not n.v3_home_reminders_status.visible,'normal reminders reserve an unnecessary footer')
 end
 assert(n.v3_home_reminder_costume.text=='剩余 2天' and n.v3_home_reminder_daily.text=='还有 1项未接')
 assert(h.reminderReads==16 and c.enabledWrites==0,'layout read Native or wrote business preferences')
end)
Test('reminder failures appear on demand and release their height after recovery',function()
 local S,p,n,c=Host({visible={'reminders'},configureReminders=ReminderFixture})
 local service=S.Services.HomeRemindersV3;local acquire=service.AcquireConsumer
 service.AcquireConsumer=function()return false,'test_failure'end
 assert(p:OnActivated());assert(n.v3_home_reminders_status.visible and n.v3_home_reminders_status.text:find('test_failure',1,true))
 assert(p.cardByKey.reminders.panel.height>=90,'compact card clipped its failure message')
 service.AcquireConsumer=acquire;assert(p:RefreshData())
 assert(not n.v3_home_reminders_status.visible and p.cardByKey.reminders.panel.height<=80,'recovered reminders kept failure space')
end)
Test('more rows reflow from cached projections and short lists shrink again',function()
 local S,p,n,c=Host({visible={'daily','stats'}});local count=5
 S.Features.Tasks.GetOverviewProjection=function(_,opts)local rows={};for i=1,count do rows[i]={id=opts.scope..i,rawName='任务'..i,status='进行中',progressText='0/1'}end;return {rows=rows,revision=count}end
 assert(p:OnActivated());p:RefreshData();local before=p.cardByKey.daily.panel.height
 count=12;p:RefreshData();assert(p.cardByKey.daily.panel.height>before and p.cardByKey.daily.table.list.visibleCapacity>=12,'new rows above the baseline cap did not reflow')
 count=1;p:RefreshData();assert(p.cardByKey.daily.panel.height<=105,'short list kept expanded height')
 assert(c.quotes==0 and c.enabledWrites==0)
end)
Test('settings form triggers remain reachable without putting fields into the home cards',function()
 local S,p,n,c,_,h=Host({visible={'trade','bonds'},enabled={life_trade=true,life_bonds=true}});assert(p:OnActivated())
 p:RefreshData();local trade=n.v3_home_trade_settings;local bonds=n.v3_home_bonds_settings
 -- 平铺菜单动作覆盖迁移至 rs_home_economy_settings_tests.lua，验证独立表单的绑定与关闭链。
 assert(type(trade.onClick)=='function' and type(bonds.onClick)=='function','settings form trigger missing')
 assert(trade.root.text:find('设置',1,true) and bonds.root.text:find('设置',1,true),'settings trigger lost its label')
 assert(not p.cardByKey.trade.content.headerSettings and not p.cardByKey.bonds.content.headerSettings,'home eagerly created form controls')
 for _,key in ipairs({'v3_home_trade_settings','v3_home_bonds_settings','v3_home_trade_open','v3_home_trade_widget'})do local ok,why=h:VisibleRect(n[key]);assert(ok,key..':'..tostring(why))end
 assert(c.quotes==0 and c.enabledWrites==0)
end)
Test('compact trade retains double-click quoting and separate materials details',function()
 local S,p,n,c,_,h=Host({visible={'trade'}});assert(p:OnActivated());local view=p.cardByKey.trade.content.table
 local quoted,opened=0,0;S.Features.Trade.Commands.QuoteRowMaterials=function(_,key)assert(key=='a');quoted=quoted+1;return true end
 S.UIV3.TradeDetailFloatingV3={Open=function(_,key)assert(key=='a');opened=opened+1;return true end}
 local row=view:GetItem(1);assert(view.onItemActivated(row,1,'a') and quoted==0)
 h.ms=h.ms+100;assert(view.onItemActivated(row,1,'a') and quoted==1)
 local detail;for _,column in ipairs(view.columns)do if column.id=='detail'then detail=column end end
 assert(detail and detail.onClick(row) and opened==1 and quoted==1,'materials button quoted instead of opening')
 assert(view.onItemActivated(row,1,'a') and quoted==1,'details failed to reset double click')
end)
Test('price-only updates preserve card rectangles and table scroll position',function()
 local S,p=Host({visible={'trade','stats','reminders'}});local rows={};for i=1,12 do rows[i]={key='cargo'..i,name='货物',rate='100%',price='1金',profit='--'}end
 local F=S.Features.Trade;local projection=F.GetProjection;F.GetProjection=function(self)local value=projection(self);value.rows=rows;return value end
 assert(p:OnActivated());p:RefreshData();local card=p.cardByKey.trade;local view=card.content.table;view:SetScrollOffset(3)
 local before=card.panel.x..':'..card.panel.y..':'..card.panel.height;local offset=view.list.scrollOffset
 for i=1,20 do rows[1].profit=i..'金';S.Events:Publish('v3.life.trade.updated')end
 assert(card.panel.x..':'..card.panel.y..':'..card.panel.height==before and view.list.scrollOffset==offset,'quote repaint moved cards or reset scroll')
end)
print('HOME RESULT '..pass..' passed / '..fail..' failed');if fail>0 then error('home tests failed')end

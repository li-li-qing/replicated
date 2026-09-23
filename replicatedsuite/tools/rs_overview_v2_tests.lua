-- Maintenance: actual RSUI layout/Feature/Service code, only Native data and
-- parent widget are substitutes. These are not RU client visual acceptance.
local pass,fail=0,0
local function Test(name,fn)
    local ok,err=xpcall(fn,debug.traceback)
    if ok then pass=pass+1;print('PASS overview-v2 '..name)else fail=fail+1;print('FAIL overview-v2 '..name..': '..tostring(err))end
end
local function TaskBoot()
    local h=dofile('tools/rs_gear_page_test_host.lua')();local S=h.S
    dofile('core/rs_demand.lua');S.UI.CreateWindowShell=function()end;dofile('ui/framework/rs_ui_floating_surface.lua')
    S.Utils.ServerDateKey=function()return '2026-09-12'end
    S.Data={QuestGroups={daily={{key='d1',title='日常甲',quests={1}},{key='d2',title='日常乙',quests={2}},{key='d3',title='暂不可用',quests={3}}},weekly={{key='w1',title='周常甲',quests={4}}}}}
    local data={d1={available=true,completed=0,total=1,readyCount=1,activeCount=1,text='0/1'},d2={available=true,completed=1,total=1,text='1/1'},w1={available=true,completed=0,total=1,activeCount=1,text='0/1'}}
    S.Services.QuestProgressV3={GetProgress=function(_,_,key)return data[key]end}
    dofile('features/life/tasks/rs_task_store.lua');dofile('features/life/tasks/rs_task_authority.lua');dofile('features/life/tasks/rs_task_feature.lua')
    local F=S.Features.Tasks;assert(F:EnsureStoreLoaded());F.enabled=true;assert(F.Authority:Refresh('test'))
    return S,F,h
end
Test('task overview includes both scopes without copying native observations',function()
    local S,F=TaskBoot();local p=F:GetOverviewProjection({scope='all',view='tracked',status='all'})
    assert(#p.rows==4 and p.summary.ready==1 and p.summary.completed==1 and p.summary.unavailable==1)
    assert(p.rows[1].groupKey=='d1' and p.rows[1].scope=='daily')
end)
Test('task filtering never changes saved tracking or expanded widget rows',function()
    local S,F,h=TaskBoot();local writes=h.writes;F.Authority:SetExpanded('daily','d1',true)
    local p=F:GetOverviewProjection({scope='daily',view='all',status='unfinished',query='日常'})
    assert(#p.rows==1 and p.rows[1].groupKey=='d1');assert(h.writes==writes)
    local a=F:GetOverviewProjection({scope='all',view='tracked'});local b=F:GetOverviewProjection({scope='all',view='tracked'})
    assert(a==b,'revision cache is not reused')
end)
Test('task tracking toggles invalidate only its projection and survive store reload',function()
    local S,F=TaskBoot();assert(F.Commands:ToggleTracked('daily','d1','test'))
    assert(#F:GetOverviewProjection({view='tracked'}).rows==3)
    assert(#F:GetOverviewProjection({view='all'}).rows==4)
    assert(S.Persistence:Flush(F.StoreId));local st=S.Persistence:GetStore(F.StoreId);st.loaded=false;F.storeLoaded=false
    assert(F:EnsureStoreLoaded());assert(not F:IsTracked('daily','d1'))
end)
-- Old workspace-tab/draft controls moved to the shared personal workbench in .247.
-- These tests retain their lifecycle, layout, source and explicit-detail acceptance.
local HomeBoot=dofile('tools/rs_workspace_home_test_host.lua')
local function Show(S,p,keys)
 local chosen={};for _,k in ipairs(keys)do chosen[k]=true end
 assert(S.UIV3.Workspace:Change('home',function()for _,c in ipairs(S.UIV3.Workspace:GetCards(true))do S.UIV3.Workspace.state.home.hidden[c.id]=not chosen[c.id] or nil end;return true end))
 p:Layout(0,0,p.width,p.height);p:RefreshData()
end
local function Drain(S,p)S.Scheduler:RemoveTask('v3_home_refresh');p.refreshQueued=false;p:RefreshData()end
Test('five named home cards replace mutually exclusive legacy workspace tabs',function()
 local S,p,n=HomeBoot();assert(not n.v3_home_workspace_tabs and #p.cards==5)
 assert(n.v3_home_daily_title.text=='日常任务' and n.v3_home_weekly_title.text=='周常任务')
 assert(n.v3_home_customize and n.v3_home_previous and n.v3_home_next)
end)
Test('compact KPIs preserve unknown amounts without repeated source paragraphs',function()
 local S,p,n=HomeBoot();p:OnActivated();assert(n.v3_home_stat_gold.text=='—')
 assert(n.v3_home_stats_grid.height<=60 and not n.v3_home_stat_source_gold)
end)
Test('only arranged visible cards retain leases; hidden page leaves other views alive',function()
 local S,p,n,c=HomeBoot();S.Features.Tasks.consumers['widget:tasks']=true;p:OnActivated()
 assert(S.Features.Tasks.consumers['home:daily'] and S.Features.Tasks.consumers['home:weekly'])
 Show(S,p,{'activities','trade'});assert(not S.Features.Tasks.consumers['home:daily'] and not S.Features.Tasks.consumers['home:weekly'])
 assert(S.Features.Trade.consumers['home:trade']);p:OnDeactivated()
 assert(S.Features.Tasks.consumers['widget:tasks'] and c.acquired==c.released)
end)
Test('all widths retain bounded cards and readable tables through scrolling',function()
 local S,p,n=HomeBoot();p:OnActivated()
 for _,width in ipairs({440,580,680,850,1100,1650})do
  p:Layout(0,0,width,640)
  for offset=0,p.grid.maxScrollOffset do p.grid:SetScrollOffset(offset);p:RefreshData()
   for _,card in ipairs(p.cards)do if card.panel.viewportVisible then
    local t=card.table or card.content.table;assert(t.height>=90,'table collapsed '..width..' '..card.spec.key)
    assert(card.panel.y>=0 and card.panel.y+card.panel.height<=p.grid.height+0.1);assert(card.panel.width>=300)
   end end
  end
 end
end)
Test('daily and weekly customization request the correct shared editor source',function()
 local S,p,n=HomeBoot();local calls={}
 S.UIV3.WorkspacePage={Open=function(_,tab,scope)calls[#calls+1]=tab..':'..scope;return true end}
 assert(n.v3_home_daily_customize.onClick() and n.v3_home_weekly_customize.onClick())
 assert(calls[1]=='lists:daily' and calls[2]=='lists:weekly')
end)
Test('hidden task changes do no page work; visible trade updates locally',function()
 local S,p,n,c=HomeBoot({visible={'activities','trade'}});p:OnActivated();Drain(S,p);local before=c.reads
 S.Events:Publish('v3.tasks.updated');assert(not S.Scheduler.tasks.v3_home_refresh and c.reads==before)
 S.Events:Publish('v3.life.trade.updated');assert(c.reads>before)
 assert(not S.Scheduler.tasks.v3_home_refresh,'trade-local update queued unrelated cards')
end)
Test('overview keeps bounded manual quote and no automatic query',function()
 local S,p,n,c=HomeBoot({visible={'trade'}});p:OnActivated()
 assert(n.v3_home_trade_quote and n.v3_home_trade_from and not n.v3_home_trade_full_quote and c.quotes==0)
end)
Test('hiding home does not alter task attention',function()
 local S,p,n,c=HomeBoot();local changes=0
 S.Features.Tasks.Commands.ToggleTracked=function()changes=changes+1;return true end
 p:OnActivated();p:OnDeactivated();assert(changes==0)
end)
Test('task selection only selects; explicit detail uses stable scope and identity',function()
 local S,p,n=HomeBoot();local opens=0
 S.UIV3.QuestDetailFloatingV3={Open=function(_,scope,key)assert(scope=='daily' and key=='quest');opens=opens+1;return true end}
 p:OnActivated();n.v3_home_daily_table.list:HandleRowClick(1)
 assert(opens==0 and p.cardByKey.daily.selected.groupKey=='quest')
 assert(n.v3_home_daily_detail.onClick() and opens==1)
end)
Test('first activation cannot acquire consumers before first layout',function()
 local S,p,n,c=HomeBoot({skipLayout=true});p:OnActivated();assert(c.acquired==0)
 p:Layout(0,0,880,730);p:RefreshData();assert(S.Features.Tasks.consumers['home:daily'])
 p:OnDeactivated();assert(c.acquired==c.released)
end)
print('OVERVIEW V2 RESULT '..pass..' passed / '..fail..' failed');if fail>0 then error('overview v2 tests failed')end

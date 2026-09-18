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
local function HomeBoot(skipLayout)
    local h=dofile('tools/rs_gear_page_test_host.lua')();local S=h.S
    local enabled={life_activities=true,life_trade=true,life_tasks=true,life_bonds=true,life_daily_stats=true}
    local c={acquired=0,released=0,reads=0,quotes=0}
    S.FeatureRuntime.IsEnabled=function(_,key)return enabled[key]==true end
    S.FeatureRuntime.SetPreferredEnabled=function(_,key,v)enabled[key]=v;return true end
    for _,def in ipairs({{'Activities','life_activities','v3.activities.updated'},{'Trade','life_trade','v3.life.trade.updated'},{'Tasks','life_tasks','v3.tasks.updated'},{'Bonds','life_bonds','v3.life.bonds.updated'},{'Treasure','life_treasure','treasure'},{'Fishing','life_fishing','fishing'}})do
        local F={Id=def[2],UpdateTopic=def[3],consumers={},Commands={},enabled=true}
        function F:AcquireConsumer(t)assert(not self.consumers[t]);self.consumers[t]=true;c.acquired=c.acquired+1;return true end
        function F:ReleaseConsumer(t)assert(self.consumers[t]);self.consumers[t]=nil;c.released=c.released+1;return true end
        function F:GetProjection()c.reads=c.reads+1;return {rows={{key='r',name='双冠丘陵特产',rate='130%',price='22金53银',profit='待询价'}},revision=1,zones={{id=1,name='双冠丘陵'}},sellableZones={{id=2,name='十字星平原'}},fromZone=1,toZone=2,favoriteItems={},pendingQuoteCount=4,quoteBatch={active=false,total=0},status='ready'}end
        function F:GetRows()c.reads=c.reads+1;return {{key='a',shortName='迷雾',status='进行中 9分',progressText='0/4',questKey='a',questScope='event'}},1 end
        function F:GetWidgetProjection()return {},1 end
        function F:GetOverviewProjection(opts)c.reads=c.reads+1;self.lastFilters=opts;return {rows={{id='daily:d1',key='d1',groupKey='d1',scope='daily',rawName='完成任务',cycleText='日常',progressText='1/2',status='进行中',tracked=true,available=true}},revision=1,summary={total=1,tracked=1,completed=0,ready=0,unfinished=1,unavailable=0}}end
        function F:GetWidgetWindowState()return {}end;function F:GetWidgetVisible()return false end
        function F:GetRouteSettings()return {fromZone=1,toZone=2}end;function F:GetBondFilter()return {sortMode='continent',continentOrder='west_first',q20=true,q60=true,q100=true,auroria=true,excludeSame=false,priority='west'}end;function F:GetContinentOrder()return 'west_first'end
        for _,k in ipairs({'SetFrom','SetTo','SetSortMode','SetRatioMode','SetCommerceMode','ToggleCurrentFavorite','SelectFavorite','SetBondFilterOption','SetContinentOrder','SetDuplicatePriority','SetWidgetWindowState','MarkStoreDirty','SetWidgetVisible','ToggleTracked'})do F.Commands[k]=function()return true end end
        F.Commands.QuotePendingMaterials=function()c.quotes=c.quotes+1;return true end
        F.Commands.CancelQuoteBatch=function()return true end
        S.Features[def[1]]=F
    end
    S.Features.DailyLedger={GetProjection=function()local rows={};for _,k in ipairs({'gold','honor','experience','living'})do rows[#rows+1]={key=k,status='unconnected'}end;return {day='2026-09-12',rows=rows,enabled=true}end}
    S.UIV3.WidgetHost={Register=function()return true end,BindFeatureLifecycle=function()return true end}
    S.RSUI.FloatingSurface={CreateStateAdapter=function()return {}end}
    dofile('presentation/v3/widgets/rs_v3_life_economy_widgets.lua');dofile('presentation/v3/pages/rs_v3_home_overview.lua')
    local parent=h.Native(nil,'overview_parent',0,0,880,730)
    local p=assert(S.UIV3.HomeOverview:Build(parent,'home'));if not skipLayout then p:Layout(0,0,880,730)end
    local nodes={};local function walk(x)nodes[x.id]=x;for _,v in ipairs(x.children or {})do walk(v)end end;walk(p)
    return S,p,nodes,c,h,enabled
end
Test('home named workspace tabs replace hidden next-row navigation',function()
    local S,p,n,c=HomeBoot();assert(n.v3_home_workspace_tabs and not n.v3_home_scroll_next)
    assert(p:SetWorkspace('tasks'));assert(p.workspace=='tasks');assert(n.v3_home_tasks_panel.viewportVisible~=false)
end)
Test('KPI cards are measured surfaces and no repeated disconnected paragraphs',function()
    local S,p,n=HomeBoot();assert(p:OnActivated());assert(n.v3_home_stat_box_gold.kind=='GroupBox' or n.v3_home_stat_box_gold.type=='GroupBox')
    assert(n.v3_home_stat_gold.text=='—');assert(n.v3_home_stat_source_gold.text=='待接入')
    assert(n.v3_home_stats_grid.height<=94,'KPI area wastes data viewport')
end)
Test('only visible workspace retains consumers and hiding leaves other views alive',function()
    local S,p,n,c=HomeBoot();S.Features.Tasks.consumers['widget:tasks']=true
    p:OnActivated();assert(not S.Features.Tasks.consumers['home:tasks'] and not S.Features.Bonds.consumers['home:bonds'])
    p:SetWorkspace('tasks');assert(S.Features.Tasks.consumers['home:tasks'] and not S.Features.Trade.consumers['home:trade'])
    p:OnDeactivated();assert(S.Features.Tasks.consumers['widget:tasks']);assert(c.acquired==c.released)
end)
Test('compact width keeps one accessible named card with readable table',function()
    local S,p,n,c=HomeBoot();p:OnActivated()
    for _,width in ipairs({580,680,850,1100,1650})do
        p:Layout(0,0,width,640)
        for _,workspace in ipairs({'world','tasks'})do
            p:SetWorkspace(workspace)
            for _,slot in ipairs({1,2})do p:SetCompactCard(slot)
                for _,card in ipairs(p.cards)do if card.panel.viewportVisible~=false then
                    local t=card.table or card.content.table;assert(t.height>=100,'table collapsed at '..width..' '..card.spec.name)
                    assert(card.panel.y>=0 and card.panel.y+card.panel.height<=n.v3_home_data_grid.height+0.1)
                    assert(card.panel.width>=300)
                end end
            end
        end
    end
end)
Test('task controls preserve key selection and use command for tracking',function()
    local S,p,n,c=HomeBoot();p:OnActivated();p:SetWorkspace('tasks')
    assert(n.v3_home_tasks_scope and n.v3_home_tasks_filter and n.v3_home_tasks_view and n.v3_home_tasks_query)
    assert(n.v3_home_tasks_toggle and n.v3_home_tasks_detail)
    local calls=0;S.Features.Tasks.Commands.ToggleTracked=function(_,scope,key)calls=calls+1;assert(scope=='daily' and key=='d1');return true end
    p:SelectTask({groupKey='d1',scope='daily',id='daily:d1'})
    assert(n.v3_home_tasks_toggle.onClick());assert(calls==1)
end)
Test('hidden features avoid broad work while visible trade refreshes locally',function()
    local S,p,n,c=HomeBoot();p:OnActivated();local before=c.reads
    S.Events:Publish('v3.tasks.updated');assert(not S.Scheduler.tasks.v3_home_refresh and c.reads==before)
    S.Events:Publish('v3.life.trade.updated')
    assert(c.reads>before,'visible trade update did not refresh its local content')
    assert(not S.Scheduler.tasks.v3_home_refresh,'trade-local refresh unexpectedly queued a broad home refresh')
end)
Test('overview quote mode hides costly advanced actions without removing widget controls',function()
    local S,p,n,c=HomeBoot();p:OnActivated()
    assert(n.v3_home_trade_quote and n.v3_home_trade_from)
    assert(not n.v3_home_trade_full_quote,'overview still exposes full-search controls')
    assert(c.quotes==0)
end)
Test('hiding task card releases active draft focus without changing tracking',function()
 local S,p,n,c,h=HomeBoot();p:OnActivated();p:SetWorkspace('tasks')
 local edit=n.v3_home_tasks_query;assert(edit:BeginEditing('test'));edit.root.text='未提交草稿'
 p:SetWorkspace('world');assert(not edit:IsEditing() and not edit.root.rsUiKeyboardArmed)
 assert(p.taskFilters.query=='')
end)
Test('task selection does not auto-open detail and explicit detail does',function()
 local S,p,n,c=HomeBoot();local opens=0
 S.UIV3.QuestDetailFloatingV3={Open=function()opens=opens+1;return true end}
 p:OnActivated();p:SetWorkspace('tasks');n.v3_home_tasks_table.list:HandleRowClick(1)
 assert(opens==0 and p.selectedTask.groupKey=='d1')
 assert(n.v3_home_tasks_detail.onClick() and opens==1)
end)
Test('search button commits native draft through the real TextInput lifecycle',function()
 local S,p,n,c=HomeBoot();p:OnActivated();p:SetWorkspace('tasks')
 local edit=n.v3_home_tasks_query;assert(edit:BeginEditing('test'));edit.root.text='材料'
 assert(n.v3_home_tasks_search.onClick());assert(p.taskFilters.query=='材料' and not edit:IsEditing())
 assert(n.v3_home_tasks_clear_search.onClick());assert(p.taskFilters.query=='')
end)

Test('activation before first layout never acquires hidden task cards',function()
 local S,p,n,c=HomeBoot(true);p:OnActivated()
 assert(not S.Features.Tasks.consumers['home:tasks'] and not S.Features.Bonds.consumers['home:bonds'])
 p:Layout(0,0,880,730);p:RefreshData();assert(S.Features.Trade.consumers['home:trade'])
 p:OnDeactivated();assert(c.acquired==c.released)
end)
_G.RSOverviewV2TestHost=HomeBoot
print('OVERVIEW V2 RESULT '..pass..' passed / '..fail..' failed');if fail>0 then error('overview v2 tests failed')end

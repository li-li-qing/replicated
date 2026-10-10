-- 战斗统计首次进入布局：真实 PageHost、RSUI、Feature 投影，Native 使用开发期替身。
-- 不进入 toc.g，不访问玩家存档，不冒充 RU 客户端实测。
local NativeHost=dofile('tools/rs_gear_page_test_host.lua')
local function Boot(width,height,options)
    options=options or {}
    local h=NativeHost({width=width,height=height});local S=h.S
    -- 配置页通过真实 PageHost 创建，必须提供 NumericField 所用的 Native Slider 叶节点。
    S.UI.CreateSlider=function(_,parent,id,x,y,w,ht,mn,mx,step,value)
        local n=h.Native(parent,id,x,y,w,ht);n.value=value
        function n:SetValue(v)self.value=v end;function n:GetValue()return self.value end
        function n:SetRange(a,b)self.min,self.max=a,b end
        function n:SetValueChangedHandler(fn)self.valueChanged=fn end
        return n
    end
    dofile('ui/framework/rs_ui_text_layout.lua')
    dofile('ui/framework/rs_ui_scrollbar.lua')
    dofile('ui/framework/rs_ui_forms.lua')
    S.UIV3.WidgetHost={IsVisible=function()return false end}
    S.UIV3.Router={routes={},Get=function(self,id)return self.routes[id]end,
        Register=function(self,id,meta)meta.id=id;self.routes[id]=meta;return true end}
    S.UIV3.Shell={Navigate=function(_,route,context)
        h.navigationCalls=(h.navigationCalls or 0)+1
        return S.UIV3.PageHost:Navigate(route,context)
    end}
    S.FeatureRuntime.GetSnapshot=function(_,id)
        local f=id=='combat_stats' and S.Features.DPS or S.Features.CombatAnalytics
        return {enabled=f and f.enabled==true}
    end
    S.Services.CombatEventBusV3={Subscribe=function()return true end,Unsubscribe=function()return true end,GetHealth=function()return {coverageState='INACTIVE'}end}
    S.Services.UnitIdentityV3={player={name='GearTest'},IsPlayerName=function(_,name)return name=='GearTest'end,RefreshPlayerIdentity=function(self)return self.player end}
    local function Relation(name)return name=='GearTest' and 'SELF' or 'OPPONENT' end
    S.Services.CombatRelationV3={AcquireConsumer=function()return true end,ReleaseConsumer=function()return true end,GetHealth=function()return {} end,
        GetUnit=function(_,name)return {kind=name=='Npc' and 'NPC' or 'PLAYER',relation=Relation(name)}end,
        GetRelationAt=function(_,name)return Relation(name)end,
        RecordCombatFact=function(_,fact)return true,{sourceRelation=Relation(fact.sourceName),targetRelation=Relation(fact.targetName)}end}
    dofile('core/rs_demand.lua')
    dofile('services/rs_combat_analytics_v3.lua')
    dofile('features/combat/analytics/rs_combat_metric_common.lua')
    dofile('features/combat/analytics/rs_combat_analytics_metrics.lua')
    dofile('features/combat/analytics/rs_combat_analytics_store.lua')
    dofile('features/combat/analytics/rs_combat_personal_history.lua')
    dofile('features/combat/analytics/rs_combat_analytics_feature.lua')
    dofile('features/combat/dps/rs_dps_store.lua')
    dofile('features/combat/dps/rs_dps_feature.lua')
    dofile('features/combat/dps/rs_dps_domain.lua')
    assert(S.Features.DPS:Initialize());assert(S.Features.DPS:Enable('layout_test'))
    if options.scope then assert(S.Features.CombatAnalytics.Commands:SetCollectionScope(options.scope)) end
    if not options.empty then
        S.Services.CombatAnalyticsV3:_DispatchFact({category='damage',kind='damage',sourceName='GearTest',targetName='Npc',
            sourceKind='PLAYER',targetKind='NPC',amount=100,receivedAt=h.ms,sequence=1,abilityId=11,abilityName='Hit'})
    end
    dofile('presentation/v3/shell/rs_v3_page_host.lua')
    S.FeatureRegistry={Get=function(_,id)if id=='combat_stats'then return {id=id,route='combat.stats',name='战斗统计与分析'}end end,
        GetByRoute=function(self,route)if route=='combat.stats'then return self:Get('combat_stats')end end,
        IsAccessible=function(_,id)return id=='combat_stats'end}
    dofile('core/rs_module_diagnostics.lua')
    dofile('presentation/v3/pages/rs_v3_combat_statistics_controls.lua')
    dofile('presentation/v3/pages/rs_v3_combat_personal_history_page.lua')
    dofile('presentation/v3/pages/rs_v3_combat_statistics_settings_page.lua')
    dofile('presentation/v3/pages/rs_v3_dps_page.lua')
    h.H=S.UIV3.PageHost
    assert(h.H:Attach(h.page.spec.parent))
    assert(h.H:RegisterFactory('test.blank',function(parent)return S.UIV3Design:PageRoot(parent,{id='stats_test_blank'})end))
    assert(h.H:Navigate('test.blank'));h.H.switcher:LayoutIfNeeded(0,0,width,height,true);S.RSUI:FlushLayoutQueue(32)
    local build=h.H.factories['combat.stats']
    h.H.factories['combat.stats']=function(...)
        local p=assert(build(...));local activate=p.OnActivated
        function p:OnActivated(...)
            h.beforeActivation={selected=self.selectedRow~=nil,detailToken=self.detailLayoutToken,paintIssues={}}
            local function Find(n,id)
                if n.id==id then return n end
                for _,ch in ipairs(n.children or {})do local found=Find(ch,id);if found then return found end end
            end
            h.beforeActivation.counterpartShown=Find(self,'v3_dps_counterpart_table').visible
            local function Check(n)
                local root=n.root;local shown=true
                while root do if root.shown==false then shown=false;break end;root=root.parent end
                if shown and n.width and n.height then
                    local inside,reason=h:VisibleRect(n)
                    if not inside then h.beforeActivation.paintIssues[#h.beforeActivation.paintIssues+1]=n.id..':'..tostring(reason)end
                end
                for _,ch in ipairs(n.children or {})do Check(ch)end
            end
            Check(self)
            return activate(self,...)
        end
        return p
    end
    assert(h.H:Navigate('combat.stats'))
    h.stats=h.H.pages['combat.stats'];h.tree={}
    local function Index(n)h.tree[n.id]=n;for _,ch in ipairs(n.children or {})do Index(ch)end end
    Index(h.stats)
    function h:Arrange(w,ht)
        self.page.spec.parent.width=w;self.page.spec.parent.height=ht
        self.H.switcher:LayoutIfNeeded(0,0,w,ht,true)
        self.S.RSUI:FlushLayoutQueue(32)
        return true
    end
    function h:AssertContained()
        for id,n in pairs(self.tree)do
            local root=n.root;local shown=true
            while root do if root.shown==false then shown=false;break end;root=root.parent end
            if shown and n.width and n.height then
                local ok,err=self:VisibleRect(n);assert(ok,id..': '..tostring(err))
            end
        end
    end
    return h
end

local passed,failed=0,0
local function Test(name,fn)
    local ok,err=xpcall(fn,debug.traceback)
    if ok then passed=passed+1;print('PASS combat-layout '..name)
    else failed=failed+1;print('FAIL combat-layout '..name..': '..tostring(err)) end
end
Test('first switcher layout already reflects the selected self actor',function()
    local h=Boot(620,680)
    assert(h.beforeActivation.selected,'first layout happened before self actor projection was prepared')
    assert(h.beforeActivation.detailToken=='true:true','first layout had unprepared detail visibility')
    assert(h.beforeActivation.counterpartShown==false,'inactive table painted during the first layout')
    assert(#h.beforeActivation.paintIssues==0,table.concat(h.beforeActivation.paintIssues,' / '))
end)
for _,scope in ipairs({'self','all'})do
    for _,size in ipairs({{940,680},{620,680},{480,680},{620,420},{480,420}})do
        Test(scope..' first entry contained at '..size[1]..'x'..size[2],function()
            local h=Boot(size[1],size[2],{scope=scope});h:Arrange(size[1],size[2]);h:AssertContained()
            assert(#h.beforeActivation.paintIssues==0,table.concat(h.beforeActivation.paintIssues,' / '))
            if scope=='all' then assert(h.stats:SelectActor(1));h:Arrange(size[1],size[2]);h:AssertContained()end
        end)
    end
end
Test('short detail pane can scroll to an operable skill table',function()
    local h=Boot(620,420);h:Arrange(620,420)
    local stack=h.tree.v3_dps_detail_stack
    assert(type(stack.ScrollToBottom)=='function','short pane lacks viewport scrolling')
    stack:ScrollToBottom();h.S.RSUI:FlushLayoutQueue(32);h:AssertContained()
    local tableView=h.tree.v3_dps_ability_table
    assert(h:VisibleRect(tableView),'skill table is unreachable')
    assert(tableView.height>=43,'not enough room for a header and a skill row')
end)
Test('native wheel events reach the short detail viewport',function()
    local h=Boot(480,420);h:Arrange(480,420)
    local stack=h.tree.v3_dps_detail_stack
    local down=assert(stack.root.events.OnWheelDown,'native wheel handler missing')
    for i=1,4 do down(stack.root)end
    h.S.RSUI:FlushLayoutQueue(32);h:AssertContained()
    assert(stack.scrollOffset>0 and h:VisibleRect(h.tree.v3_dps_ability_table),'wheel did not reveal skill table')
end)
Test('resize down and restore keeps selection and does not rebuild',function()
    local h=Boot(620,680);h:Arrange(620,680);local selected=h.stats.selectedActorKey
    local builds=h.H.stats.builds;local writes=h.writes
    for _,size in ipairs({{480,420},{940,680},{620,420},{620,680}})do
        h:Arrange(size[1],size[2]);h:AssertContained()
        assert(h.stats.selectedActorKey==selected,'resize lost actor selection')
    end
    assert(h.H.stats.builds==builds and h.writes==writes,'layout rebuilt pages or wrote preferences')
end)
Test('empty session first entry remains contained',function()
    local h=Boot(480,420,{empty=true});h:Arrange(480,420);h:AssertContained()
    assert(h.stats.selectedRow==nil)
end)
Test('route reentry reuses the prepared page',function()
    local h=Boot(480,420);h:Arrange(480,420);local page=h.stats
    assert(h.H:Navigate('test.blank'));assert(h.H:Navigate('combat.stats'));h:Arrange(480,420);h:AssertContained()
    assert(h.H.pages['combat.stats']==page and page.statisticsLayoutPasses>0)
end)
Test('pending and counterpart views stay inside the short pane',function()
    local h=Boot(620,420);h:Arrange(620,420)
    for _,pending in ipairs({true,false})do
        h.stats.pendingView=pending;h.stats.detailView='counterparts';assert(h.stats:RefreshDetail());h:Arrange(620,420)
        local stack=h.tree.v3_dps_detail_stack
        if stack.ScrollToBottom then stack:ScrollToBottom();h.S.RSUI:FlushLayoutQueue(32)end
        h:AssertContained()
    end
end)
Test('layout diagnostics read existing geometry without side effects',function()
    local h=Boot(620,420);h:Arrange(620,420)
    local read
    for _,provider in ipairs(h.S.ModuleDiagnosticsHub.providers.combat_stats or {})do
        if provider.id=='combat_statistics_layout'then read=provider.fn end
    end
    assert(read,'layout provider missing from real ModuleDiagnosticsHub')
    local writes=h.writes;local tasks=0;for _ in pairs(h.S.Scheduler.tasks)do tasks=tasks+1 end
    local layouts=h.S.RSUI.metrics.layouts;local p=assert(read())
    assert(p.firstLayout and p.current and p.current.page.width==620,'page geometry missing')
    p.current.page.width=1;assert(read().current.page.width==620,'diagnostic exposed mutable state')
    assert(h.writes==writes and h.S.RSUI.metrics.layouts==layouts,'diagnostic changed presentation or store')
    local after=0;for _ in pairs(h.S.Scheduler.tasks)do after=after+1 end;assert(after==tasks)
end)
Test('unchanged combat refresh does not repeat layout',function()
    local h=Boot(620,680);h:Arrange(620,680);local passes=h.stats.statisticsLayoutPasses;local writes=h.writes
    for i=1,100 do assert(h.stats:RefreshStats());h.S.RSUI:FlushLayoutQueue(32)end
    assert(h.stats.statisticsLayoutPasses==passes,'unchanged projection kept invalidating page layout')
    assert(h.writes==writes,'refresh wrote preferences')
end)
Test('new facts still update overview and skill detail after a skipped refresh',function()
    local h=Boot(620,680);h:Arrange(620,680)
    assert(h.stats:RefreshStats());h.S.RSUI:FlushLayoutQueue(32)
    local function Damage(sequence,source,amount)
        h.ms=h.ms+100
        h.S.Services.CombatAnalyticsV3:_DispatchFact({category='damage',kind='damage',sourceName=source,targetName='Npc',
            sourceKind='PLAYER',targetKind='NPC',amount=amount,receivedAt=h.ms,sequence=sequence,abilityId=11,abilityName='Hit'})
    end
    Damage(2,'GearTest',75);assert(h.stats:RefreshStats());h:Arrange(620,680)
    assert(h.tree.v3_dps_overview_table.list.items[1].damage==175,'overview stayed at an old value')
    assert(h.tree.v3_dps_ability_table.list.items[1].amount==175,'skill detail stayed at an old value')
    assert(h.S.Features.CombatAnalytics.Commands:SetCollectionScope('all'))
    Damage(3,'GearTest',90);Damage(4,'Other',200);assert(h.stats:RefreshStats())
    assert(h.stats:ApplyRankingSort('damage','desc',h.tree.v3_dps_overview_table))
    assert(h.tree.v3_dps_overview_table.list.items[1].name=='Other','descending sort was skipped')
    assert(h.stats:ApplyRankingSort('damage','asc',h.tree.v3_dps_overview_table))
    -- 全员总览保留目标 NPC 的承伤行，其伤害为零；玩家行仍应按90→200排列。
    local order={};for i,row in ipairs(h.tree.v3_dps_overview_table.list.items)do order[row.name]=i end
    assert(order.GearTest and order.Other and order.GearTest<order.Other,'ascending sort was skipped')
    h:Arrange(620,680);h:AssertContained()
end)
-- Native 故障模型：按下期间隐藏任一祖先会取消本次点击；仍使用真实战斗投影、布局和 OnClick。
for _,case in ipairs({
    {id='v3_dps_mode',check=function(h)return h.stats.detailMode=='PVP'end},
    {id='v3_dps_metric_segment_3',check=function(h)return h.S.Features.DPS:GetSettingsProjection().metric=='heal'end},
    {id='v3_dps_detail_selector_segment_2',check=function(h)return h.stats.detailView=='counterparts'end},
})do
    Test('one click survives a new combat fact: '..case.id,function()
        local h=Boot(620,680);h:Arrange(620,680)
        local button=assert(h.tree[case.id]);assert(h:VisibleRect(button))
        local ancestors={};local n=button.root
        while n do ancestors[n]=true;n=n.parent end
        local cancelled=false;local ensure=h.UI.EnsureVisible
        h.UI.EnsureVisible=function(ui,n,visible,...)
            if ancestors[n] and n.shown~=false and visible==false then cancelled=true end
            return ensure(ui,n,visible,...)
        end
        h.ms=h.ms+100
        h.S.Services.CombatAnalyticsV3:_DispatchFact({category='damage',kind='damage',sourceName='GearTest',targetName='Npc',
            sourceKind='PLAYER',targetKind='NPC',amount=75,receivedAt=h.ms,sequence=2,abilityId=11,abilityName='Hit'})
        assert(h.stats:RefreshStats());h.S.RSUI:FlushLayoutQueue(32)
        assert(not cancelled,'combat refresh hid the pressed button ancestor and cancelled its click')
        assert(button.root.events.OnClick(button.root,'LeftButton'),'single native click rejected')
        assert(case.check(h),'single click did not switch the requested view')
    end)
end
-- 顶部三子页在真实 PageHost 中反复切换；点击经 Native OnClick，不直接调用 SetValue。
local views={
    {route='combat.stats',id='damage',segment=1},
    {route='combat.personal_history',id='history',segment=2},
    {route='combat.statistics_settings',id='settings',segment=3},
}
local function PageTree(page)
    local tree={};local function Index(n)tree[n.id]=n;for _,ch in ipairs(n.children or {})do Index(ch)end end
    Index(page);return tree
end
local function PressDuringRefresh(h,button)
    assert(h:VisibleRect(button),'top button is not reachable')
    local ancestors={};local n=button.root
    while n do ancestors[n]=true;n=n.parent end
    local cancelled=false;local ensure=h.UI.EnsureVisible
    h.UI.EnsureVisible=function(ui,n,visible,...)
        if ancestors[n] and n.shown~=false and visible==false then cancelled=true end
        return ensure(ui,n,visible,...)
    end
    -- 历史页重提交列表、设置页刷新当前投影、总览页消费战斗事件；保留真实订阅派发。
    h.S.Events:Publish('v3.combat_analytics.updated')
    h.S.Events:Publish('v3.combat_analytics.feature_updated','click_regression')
    h.S.Events:Publish('v3.dps.settings','click_regression')
    h.S.RSUI:FlushLayoutQueue(32)
    h.UI.EnsureVisible=ensure
    assert(not cancelled,'top button ancestor was hidden during refresh')
    assert(button.root.events.OnClick(button.root,'LeftButton'),'single top button click rejected')
    h.S.RSUI:FlushLayoutQueue(32)
end
for _,width in ipairs({620,480})do
    for _,view in ipairs(views)do
        Test('top navigation one click from '..view.id..' at '..width,function()
            local h=Boot(width,680)
            assert(h.H:Navigate(view.route));h:Arrange(width,680)
            local current=view
            for iteration=1,6 do
                local target=views[(current.segment%3)+1]
                local tree=PageTree(h.H.pages[current.route])
                local calls=h.navigationCalls or 0
                PressDuringRefresh(h,assert(tree['v3_statistics_'..current.id..'_views_segment_'..target.segment]))
                assert(h.H.activeRoute==target.route,'one click did not reach target subpage')
                assert(h.navigationCalls==calls+1,'one click navigated more than once')
                current=target
            end
        end)
        Test('top collection scope one click on '..view.id..' at '..width,function()
            local h=Boot(width,680)
            assert(h.H:Navigate(view.route));h:Arrange(width,680)
            local tree=PageTree(h.H.pages[view.route]);local F=h.S.Features.CombatAnalytics
            local calls=0;local command=F.Commands.SetCollectionScope
            F.Commands.SetCollectionScope=function(self,value)calls=calls+1;return command(self,value)end
            local selector=assert(tree['v3_statistics_'..view.id..'_scope'])
            for iteration=1,4 do
                local value=iteration%2==1 and 'all' or 'self';local index=value=='all' and 2 or 1
                PressDuringRefresh(h,assert(tree['v3_statistics_'..view.id..'_scope_segment_'..index]))
                assert(F:GetCollectionScope()==value and selector:GetValue()==value,'one click did not set collection scope')
                assert(selector.buttons[index].state.selected==true,'scope highlight does not match authority')
                assert(calls==iteration,'one click submitted duplicate scope commands')
                assert(h.H.activeRoute==view.route,'scope click unexpectedly changed route')
            end
            assert(not h.S.LastInternalEventError,'refresh subscription failed')
        end)
    end
end
print('RESULT combat-layout passed='..passed..' failed='..failed)
if failed>0 then os.exit(1)end

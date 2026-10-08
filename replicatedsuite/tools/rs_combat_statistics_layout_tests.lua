-- 战斗统计首次进入布局：真实 PageHost、RSUI、Feature 投影，Native 使用开发期替身。
-- 不进入 toc.g，不访问玩家存档，不冒充 RU 客户端实测。
local NativeHost=dofile('tools/rs_gear_page_test_host.lua')
local function Boot(width,height,options)
    options=options or {}
    local h=NativeHost({width=width,height=height});local S=h.S
    dofile('ui/framework/rs_ui_text_layout.lua')
    dofile('ui/framework/rs_ui_scrollbar.lua')
    dofile('ui/framework/rs_ui_forms.lua')
    S.UIV3.WidgetHost={IsVisible=function()return false end}
    S.UIV3.Router={Get=function()return nil end,Register=function()return {} end}
    S.UIV3.Shell={Navigate=function()return true end}
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
        GetByRoute=function(self,route)if route=='combat.stats'then return self:Get('combat_stats')end end}
    dofile('core/rs_module_diagnostics.lua')
    dofile('presentation/v3/pages/rs_v3_combat_statistics_controls.lua')
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
print('RESULT combat-layout passed='..passed..' failed='..failed)
if failed>0 then os.exit(1)end

-- Real RSUI layout and feature commands, with the existing native widget test host.
local h=dofile('tools/rs_gear_page_test_host.lua')({width=820,height=680})
local S=h.S
dofile('features/rs_feature_registry.lua')
dofile('ui/framework/rs_ui_forms.lua')
S.UIV3.WidgetHost={IsVisible=function() return false end}
S.UIV3.Router={Get=function() return nil end,Register=function() return {} end}
S.UIV3.Shell={Navigate=function() return true end}
S.FeatureRuntime.GetSnapshot=function(_,id) local f=id=='combat_stats' and S.Features.DPS or S.Features.CombatAnalytics;return {enabled=f and f.enabled==true} end
S.Services.CombatEventBusV3={Subscribe=function() return true end,Unsubscribe=function() return true end,GetHealth=function() return {coverageState='INACTIVE'} end}
S.Services.UnitIdentityV3={player={name='GearTest'},IsPlayerName=function(_,name) return name=='GearTest' end,RefreshPlayerIdentity=function(self) return self.player end}
S.Services.CombatRelationV3={AcquireConsumer=function() return true end,ReleaseConsumer=function() return true end,GetHealth=function() return {} end}
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
dofile('presentation/v3/pages/rs_v3_combat_statistics_controls.lua')
dofile('presentation/v3/pages/rs_v3_combat_statistics_settings_page.lua')
dofile('presentation/v3/pages/rs_v3_combat_personal_history_page.lua')
dofile('presentation/v3/pages/rs_v3_dps_page.lua')
dofile('presentation/v3/pages/rs_v3_combat_analytics_page.lua')
local function Index(node,out) out[node.id]=node;for _,child in ipairs(node.children or {}) do Index(child,out) end end
local function Fields(widget) local out={} for _,column in ipairs(widget:GetColumns()) do out[column.id]=true end return out end
local statsPage
for _,route in ipairs({'combat.stats','combat.statistics_settings','combat.personal_history','combat.analytics'}) do
    local page=assert(S.UIV3.PageHost.factories[route](h.page.spec.parent))
    assert(page:OnActivated())
    local tree={};Index(page,tree)
    if route=='combat.stats' then
        statsPage=page
        local tableView=assert(tree.v3_dps_overview_table)
        local fields=Fields(tableView)
        for _,id in ipairs({'damage','kills','heal','taken','deaths'}) do assert(fields[id],'missing basic column '..id) end
        assert(not fields.npcKills and not fields.assists and not fields.dps,'overview contains only the agreed basic statistic columns')
        for _,width in ipairs({940,620,480}) do
            h.page.spec.parent.width=width;page:Layout(0,0,width,680)
            local ok,reason=h:VisibleRect(tableView);assert(ok,tostring(reason))
            for _,cell in ipairs(tableView.header.cells) do local visible,detail=h:VisibleRect(cell);assert(visible,tostring(detail)) end
        end
        assert(page:ApplyRankingSort('assists','desc',tableView)==false,'removed column must not be sortable')
        assert(page:ApplyRankingSort('npcKills','desc',tableView)==false,'retired NPC column remains sortable')
        local nav=assert(tree.v3_statistics_damage_views)
        for _,item in ipairs(nav.items) do assert(item.value~='analysis','paused advanced page must not remain in navigation') end
    elseif route=='combat.statistics_settings' then
        assert(tree.v3_statistics_config_metric_kills,'kill/death preference remains usable')
        for _,id in ipairs({'encounter','casts','performance','control','songcraft','utility','aura','mechanics'}) do assert(not tree['v3_statistics_config_metric_'..id],'paused toggle remains visible '..id) end
    elseif route=='combat.personal_history' then
        local fields=Fields(assert(tree.v3_personal_history_table))
        for _,id in ipairs({'damage','healing','taken','kills','deaths'}) do assert(fields[id],'missing history column '..id) end
        assert(not fields.npcKills and not fields.assists,'retired columns remain in history UI')
    else
        local selector=assert(page.valueSelectors.kills)
        for _,item in ipairs(selector.items) do assert(item.value~='npcKills' and item.value~='assists','retired selector on legacy route') end
    end
    assert(page:OnDeactivated())
end
assert(S.Services.CombatAnalyticsV3.consumerCount==0,'views do not acquire combat collection leases')
local cases,caseOptions={},{}
S.FoundationGate={RegisterSequenceCase=function(_,id,fn,opt) cases[id]=fn;caseOptions[id]=opt end}
dofile('features/combat/analytics/rs_combat_analytics_acceptance.lua')
local valueCase=assert(cases.v3_m16_18_15_analytics_value_switch_contract)
assert(valueCase(),'current value self-check rejected retired NPC removal')
local f=S.Features.CombatAnalytics;local selected=f.State.selectedValues.kills
f.State.selectedValues.kills='npcKills'
assert(valueCase() and f.State.selectedValues.kills=='npcKills' and f:GetSelectedValueKey('kills')=='kills','self-check changed legacy preference or rejected fallback')
f.State.selectedValues.kills=selected
-- 运行真实个人历史门禁，避免只测页面而遗漏 schema 升级后的运行时阻断。
local historyCaseId='v3_combat_statistics_personal_history_contract'
local historyCase=assert(cases[historyCaseId])
assert(caseOptions[historyCaseId].runtime==true,'personal history contract must run in live self-check')
local history=S.Features.CombatAnalytics.PersonalHistory
local historyStore=assert(S.Persistence:GetStore(history.StoreId))
local before={reads=h.reads,writes=h.writes,clears=h.clears,loaded=historyStore.loaded,
    dirty=historyStore.dirty,dirtyRevision=historyStore.dirtyRevision,historyRevision=history.revision,
    consumers=S.Services.CombatAnalyticsV3.consumerCount,activeMetrics=#S.Services.CombatAnalyticsV3.activeMetricOrder}
local ok,detail=historyCase()
assert(ok,'current registered personal history store rejected: '..tostring(detail))
for _,change in ipairs({{field='schemaVersion',value=1},{field='owner',value='wrong_owner'},
    {field='scope',value=S.Persistence.Scope.Account},{field='lifetime',value=S.Persistence.Lifetime.Session}}) do
    local previous=historyStore[change.field];historyStore[change.field]=change.value
    local accepted,reason=historyCase();historyStore[change.field]=previous
    assert(accepted==false and reason=='personal_history_store','invalid history contract accepted: '..change.field)
end
assert(historyCase(),'restored history store contract rejected')
assert(h.reads==before.reads and h.writes==before.writes and h.clears==before.clears,'runtime contract touched persistence transport')
assert(historyStore.loaded==before.loaded and historyStore.dirty==before.dirty
    and historyStore.dirtyRevision==before.dirtyRevision and history.revision==before.historyRevision,'runtime contract mutated history')
assert(S.Services.CombatAnalyticsV3.consumerCount==before.consumers
    and #S.Services.CombatAnalyticsV3.activeMetricOrder==before.activeMetrics,'runtime contract changed combat collection')
assert(cases.v3_m16_18_15_analytics_value_switch_contract(),'actual value-switch diagnostic accepts deaths and rejects assists')
-- 已确认击杀但没有伤害/技能归属时，技能未确认行也必须可打开玩家名单。
local metric=assert(S.Services.CombatAnalyticsV3:GetMetric('kills'))
assert(metric.OnFact(metric,{category='death',kind='kill_notice',sourceName='GearTest',sourceKind='PLAYER',
    targetName='ConfirmedPlayer',targetKind='PLAYER',receivedAt=1000}))
local killOnly=S.Features.DPS:GetActorDetail({mode='PVP',side='friendly',actorKey='name:geartest',actorName='GearTest',metric='damage'})
assert(killOnly.actor and #killOnly.abilities==1 and killOnly.abilities[1].name=='技能未确认','kill-only actor/unknown skill omitted')
assert(killOnly.abilities[1].kills==1 and killOnly.abilities[1].killTargets[1].name=='ConfirmedPlayer')
local page=assert(statsPage);assert(page:OnActivated())
local tree={};Index(page,tree)
assert(page:SelectActor(1));assert(Fields(tree.v3_dps_ability_table).kills,'skill kill count column missing')
assert(tree.v3_dps_ability_table:SetSelectedIndex(1))
assert(page.detailView=='kill_targets' and tree.v3_dps_skill_kill_targets_table.visible==true,'skill click did not open victims')
assert(tree.v3_dps_skill_kill_targets_table:GetItem(1).name=='ConfirmedPlayer')
page.detailView='skills';assert(page:RefreshDetail())
assert(tree.v3_dps_ability_table:ActivateItem(1,'click'),'selected skill cannot reopen its kill list')
assert(page.detailView=='kill_targets' and page.selectedSkillKillKey=='__unknown_skill__')
assert(page:SelectActor(1));assert(page.selectedSkillKillKey=='__unknown_skill__','same actor refresh lost the selected skill filter')
for _,width in ipairs({940,620,480}) do
    h.page.spec.parent.width=width;page:Layout(0,0,width,420)
    tree.v3_dps_detail_stack:ScrollToBottom();S.RSUI:FlushLayoutQueue(32)
    assert(h:VisibleRect(tree.v3_dps_skill_kill_targets_table))
end
assert(page:OnDeactivated())
print('PASS basic statistics + personal history runtime contract / read-only checks / kill-only skill row / exact victim drill-down / narrow layout / quiet lifecycle')

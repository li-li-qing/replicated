-- Replicated Suite · 战斗基础统计界面测试
-- 作者：Replicated
-- QQ群：1104129461
-- 使用真实 RSUI 布局和功能命令，复用已有原生控件测试宿主。
local h=dofile('tools/rs_gear_page_test_host.lua')({width=820,height=680})
local S=h.S
-- 几何取自可控 Native 父链；弹层的位置求解、打开、关闭及选项按钮使用生产实现。
S.Layout={GetContext=function()return {logicalWidth=1024,logicalHeight=768}end,
    ResolveSuiteOwnedViewportLogicalRect=function(_,native)
        local x,y,current=0,0,native
        while current do x=x+(current.x or 0);y=y+(current.y or 0);current=current.parent end
        return x,y,native.width,native.height
    end}
dofile('ui/framework/rs_ui_popup_positioning.lua')
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
dofile('core/rs_report_copy_transport.lua') -- 与真实 TOC 的复制协议/历史来源模块保持一致；门禁只检查存在，不实际交换。
dofile('features/combat/analytics/rs_combat_history_transfer.lua')
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
-- 使用真实每日入账生成跨日样本，防止界面只验证列名却没有可选日期和每日击杀/死亡。
local history=S.Features.CombatAnalytics.PersonalHistory
for _,sample in ipairs({{5,2,3},{7,5,1},{9,3,2}}) do
    S.Utils.GetServerTime=function() return {year=2026,month=10,day=sample[1],hour=12,minute=30} end
    h.ms=h.ms+1500;assert(history:Record({kills=sample[2],deaths=sample[3]}))
end
local statsPage,historyPage
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
        assert(not tree.v3_statistics_config_count_source,'two independent counting modes remain visible')
        assert(tree.v3_statistics_config_count_source_note.text:find('同一个击杀数',1,true))
        assert(not tree.v3_statistics_config_honor_add,'inert amount-matching configuration remains visible')
        local damage,healing=assert(tree.v3_statistics_config_track_damage),assert(tree.v3_statistics_config_track_healing)
        assert(damage:SetValue(false));assert(healing:SetValue(false))
        local preferences=S.Features.DPS:GetSettingsProjection()
        assert(preferences.trackDamage==false and preferences.trackHealing==false,'collection toggles must update saved feature settings')
        assert(damage:SetValue(true));assert(healing:SetValue(true))
        for _,width in ipairs({820,620,480}) do
            h.page.spec.parent.width=width;page:Layout(0,0,width,680)
            assert(h:VisibleRect(damage));assert(h:VisibleRect(healing))
        end
        for _,id in ipairs({'encounter','casts','performance','control','songcraft','utility','aura','mechanics'}) do assert(not tree['v3_statistics_config_metric_'..id],'paused toggle remains visible '..id) end
    elseif route=='combat.personal_history' then
        historyPage=page
        local daily=assert(tree.v3_personal_history_table)
        local fields=Fields(daily)
        for _,id in ipairs({'damage','healing','taken','kills','deaths'}) do assert(fields[id],'missing history column '..id) end
        assert(not fields.npcKills and not fields.assists,'retired columns remain in history UI')
        local from,to=assert(tree.v3_personal_history_from),assert(tree.v3_personal_history_to)
        assert(from.kind=='Dropdown' and to.kind=='Dropdown','history dates must be selectable, without manual input')
        assert(#from.items==4 and from.items[2].value=='2026-10-09' and from.items[4].value=='2026-10-05','dropdown must list all recorded dates, latest first')
        assert(daily:GetColumns()[2].id=='kills' and daily:GetColumns()[3].id=='deaths','daily kill/death counts must follow their date')
        assert(daily:GetItem(1).date=='2026-10-09' and daily:GetItem(1).kills==3 and daily:GetItem(1).deaths==2)
        -- 追踪偏好同时决定历史展示；不能把未采集的项目呈现成零，也不能清除以前的数据。
        h.ms=h.ms+1500;assert(history:Record({damage=120,taken=60,healing=80}));assert(page:RefreshData())
        local savedRevision=history.revision
        local function VisibleHistoryTable(node)
            if node.kind=='TableView' and node.visible~=false and node.id:find('v3_personal_history_table',1,true) then return node end
            for _,child in ipairs(node.children or {}) do local found=VisibleHistoryTable(child);if found then return found end end
        end
        local summary=tree.v3_personal_history_totals
        local dps=S.Features.DPS
        assert(dps.Commands:SetTrackingEnabled('damage',false));assert(dps.Commands:SetTrackingEnabled('healing',false))
        local compact=assert(VisibleHistoryTable(page));local compactFields=Fields(compact)
        assert(not compactFields.damage and not compactFields.taken and not compactFields.healing and compactFields.kills and compactFields.deaths,'disabled amounts must disappear from history columns: '..tostring(S.LastInternalEventError and S.LastInternalEventError.error))
        assert(not summary.text:find('伤害',1,true) and not summary.text:find('承伤',1,true) and not summary.text:find('治疗',1,true),'disabled amounts must disappear from history totals')
        assert(dps.Commands:SetTrackingEnabled('healing',true))
        local healingFields=Fields(assert(VisibleHistoryTable(page)))
        assert(healingFields.healing and not healingFields.damage and not healingFields.taken,'healing visibility must be independent')
        assert(summary.text:find('治疗 80',1,true) and not summary.text:find('伤害',1,true),'re-enabled healing must show its preserved history')
        assert(dps.Commands:SetTrackingEnabled('damage',true));assert(dps.Commands:SetTrackingEnabled('healing',false))
        local damageFields=Fields(assert(VisibleHistoryTable(page)))
        assert(damageFields.damage and damageFields.taken and not damageFields.healing,'damage preference controls damage and taken together')
        assert(summary.text:find('伤害 120',1,true) and summary.text:find('承伤 60',1,true) and not summary.text:find('治疗',1,true))
        assert(dps.Commands:SetTrackingEnabled('healing',true))
        assert(history.revision==savedRevision and history.state.totals.damage==120 and history.state.totals.healing==80,'display switches must preserve history')
        local refreshed={};Index(page,refreshed)
        local tableHost=assert(refreshed.v3_personal_history_table_host)
        for i=1,6 do
            assert(dps.Commands:SetTrackingEnabled('damage',false));assert(dps.Commands:SetTrackingEnabled('healing',false))
            local compactView=assert(VisibleHistoryTable(page))
            for _,width in ipairs({820,480}) do
                h.page.spec.parent.width=width;page:Layout(0,0,width,680)
                assert(h:VisibleRect(compactView))
                for _,cell in ipairs(compactView.header.cells) do assert(h:VisibleRect(cell)) end
            end
            assert(dps.Commands:SetTrackingEnabled('damage',true));assert(dps.Commands:SetTrackingEnabled('healing',true))
        end
        assert(#tableHost.children==4,'repeated setting changes must reuse the four bounded column layouts')
        daily=assert(VisibleHistoryTable(page))
        local beforeReads,beforeWrites,beforeRevision=h.reads,h.writes,history.revision
        assert(from:SetValue('2026-10-07'));assert(to:SetValue('2026-10-07'))
        assert(daily:GetItem(1).date=='2026-10-07' and daily:GetItem(1).kills==5 and daily:GetItem(1).deaths==1 and not daily:GetItem(2),'selection must immediately show the chosen day')
        assert(#from.items==4 and #to.items==4,'range filtering must not hide other selectable days')
        assert(from:SetValue('2026-10-09'));assert(to:GetValue()=='2026-10-09','start after end must adjust the other bound')
        assert(to:SetValue('2026-10-05'));assert(from:GetValue()=='2026-10-05','end before start must adjust the other bound')
        assert(tree.v3_personal_history_all.spec.onClick());assert(from:GetValue()=='' and to:GetValue()=='' and daily:GetItem(3))
        assert(h.reads==beforeReads and h.writes==beforeWrites and history.revision==beforeRevision,'read-only date selection must not mutate or reload history')
        for _,width in ipairs({820,620,480}) do
            h.page.spec.parent.width=width;page:Layout(0,0,width,680)
            assert(h:VisibleRect(from));assert(h:VisibleRect(to))
            for _,cell in ipairs(daily.header.cells) do local visible,detail=h:VisibleRect(cell);assert(visible,tostring(detail)) end
        end
        -- 走真实 Native 弹层选项回调，覆盖关闭弹层后同步刷新日期列表的重入路径。
        assert(from:Open());assert(from.optionButtons[3].events.OnClick());assert(from:GetValue()=='2026-10-07' and from.open==false)
        assert(to:SetValue('2026-10-07'))
        S.Utils.GetServerTime=function() return {year=2026,month=10,day=11,hour=9,minute=10} end
        h.ms=h.ms+1500;assert(history:Record({kills=8,deaths=4}));assert(page:RefreshData())
        assert(#from.items==5 and from.items[2].value=='2026-10-11','newly recorded dates must enter both selectors')
        assert(from:GetValue()=='2026-10-07' and to:GetValue()=='2026-10-07' and daily:GetItem(1).kills==5,'new combat samples must preserve the selected day')
        assert(tree.v3_personal_history_all.spec.onClick())
        -- 满额日账新增一天会归档最旧日；已选边界仍须明确显示，不能退成“请选择”却暗中筛选。
        local original=history.state;local days={}
        for i=0,2047 do
            local date=string.format('%04d-%02d-%02d',2020+math.floor(i/336),math.floor(i%336/28)+1,i%28+1)
            days[date]={kills=1,deaths=2}
        end
        history.state=history:NormalizeState({days=days,totals={kills=2048,deaths=4096}});history.revision=history.revision+1
        assert(page:RefreshData());assert(from:SetValue('2020-01-01'));assert(to:SetValue('2020-01-01'))
        assert(daily:GetItem(1).kills==1 and daily:GetItem(1).deaths==2)
        h.ms=h.ms+1500;assert(history:Record({kills=1}));assert(page:RefreshData())
        assert(from:GetValue()=='2020-01-01' and to:GetValue()=='2020-01-01' and from.selectedIndex>0 and to.selectedIndex>0,'archiving a selected date must not hide the active boundary')
        assert(from.items[from.selectedIndex].text:find('无每日明细',1,true),'archived selection must explain the missing daily row')
        assert(tree.v3_personal_history_daily_summary.text:find('筛选不完整',1,true),'archive warning must be visible above the daily table')
        assert(tree.v3_personal_history_all.spec.onClick());assert(#from.items==2049 and #to.items==2049,'clearing filters must remove temporary boundary choices')
        history.state=original;history.revision=history.revision+1;assert(page:RefreshData())
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
-- 同额同帧的野外荣誉分别记次；切换展示不改写已确认击杀，也不伪造击杀名单。
local analytics=S.Services.CombatAnalyticsV3
assert(S.Features.DPS:Enable('honor_ui_test'))
assert(S.Features.DPS.Commands:SetTrackingEnabled('damage',false))
assert(S.Features.DPS.Commands:SetTrackingEnabled('healing',false))
assert(analytics.activeMetrics.kills and not analytics.activeMetrics.dps_core and not analytics.activeMetrics.personal_history,
    'kill-only honor counting restarted amount consumers')
local nativeListeners=0
for _,listener in ipairs(S.Events.listeners.PLAYER_HONOR_POINT_CHANGED_IN_HPW or {})do
    if listener.owner==analytics then nativeListeners=nativeListeners+1 end
end
assert(nativeListeners==1,'two feature consumers registered duplicate honor callbacks')
local chatA,chatB={shown=0},{shown=0}
for _,chat in ipairs({chatA,chatB})do
    assert(S.Events:SubscribeOptional('PLAYER_HONOR_POINT_CHANGED_IN_HPW',chat,function(owner)owner.shown=owner.shown+1 end))
end
for i=1,14 do
    S.Events:Dispatch('PLAYER_HONOR_POINT_CHANGED_IN_HPW',21)
    S.Events:Dispatch('CHAT_MESSAGE','system','+21','A')
    S.Events:Dispatch('CHAT_MESSAGE','system','+21','B')
end
assert(chatA.shown==14 and chatB.shown==14,'chat display fixture did not render both windows')
S.Events:Unsubscribe('PLAYER_HONOR_POINT_CHANGED_IN_HPW',chatA);S.Events:Unsubscribe('PLAYER_HONOR_POINT_CHANGED_IN_HPW',chatB)
assert(f:GetPersonalHistoryProjection().totals.honorKills==nil,'same-value assist-like reward established kills')
assert(f.Commands:SetSelectedValue('kills','honorParticipations')==false)
f.State.selectedValues.kills='honorParticipations'
assert(page:OnActivated());assert(page:RefreshStats())
local overview=assert(S.Features.DPS:GetCombatOverview());local own
for _,row in ipairs(overview.rows) do if row.self then own=row end end
assert(own and own.kills==1 and own.honorParticipations==14 and own.confirmedKills==1,'raw honor evidence replaced unified kills')
assert(tree.v3_dps_health.text:find('击杀玩家',1,true),'unified kill label is not visible')
assert(f.Commands:SetSelectedValue('kills','honorKills')==false)
f.State.selectedValues.kills='honorKills' -- 已保存旧偏好只回退展示，不改写认证原值。
assert(page:RefreshStats())
assert(S.Features.DPS:GetCombatOverview().rows[1].kills==1)
assert(tree.v3_dps_health.text:find('击杀玩家',1,true),'unsafe old preference did not fall back to unified kills')
assert(f.Commands:SetSelectedValue('kills','kills'))
assert(S.Features.DPS:GetCombatOverview().rows[1].kills==1,'returning to confirmed kills kept the honor count')
assert(page:OnDeactivated())
assert(historyPage)
local historyTree={};Index(historyPage,historyTree)
assert(f.Commands:SetSelectedValue('kills','honorParticipations')==false)
f.State.selectedValues.kills='honorParticipations'
assert(historyPage:OnActivated())
assert(historyTree.v3_personal_history_totals.text:find('击杀玩家',1,true),'history still displays independent honor counts')
local historyTable=assert(historyTree.v3_personal_history_table)
local scoreColumn=historyTable:GetColumns()[2]
assert(scoreColumn.getText({kills=3})=='3')
assert(scoreColumn.getText({kills=3,honorParticipations=14})=='3','unmatched honor changed the kill total')
assert(f.Commands:SetSelectedValue('kills','honorKills')==false)
f.State.selectedValues.kills='honorKills';assert(historyPage:RefreshData())
assert(historyTree.v3_personal_history_totals.text:find('击杀玩家',1,true))
assert(scoreColumn.getText({kills=3,honorParticipations=14,honorKills=14})=='3','old estimates were shown as kills')
assert(f.Commands:SetSelectedValue('kills','kills'))
assert(historyTree.v3_personal_history_totals.text:find('击杀玩家',1,true),'history did not retain unified count')
assert(scoreColumn.getText({kills=3,honorParticipations=14})=='3')
assert(historyPage:OnDeactivated())
-- 真实共享事件 -> Scheduler补记 -> 总览/历史，同一人头后到明确通知仍只计一次。
assert(analytics:ResetMetric('kills','unified_honor_ui'))
local beforeSupplement=f:GetPersonalHistoryProjection().totals.kills
S.Events:Dispatch('PLAYER_HONOR_POINT_CHANGED_IN_HPW',84)
h.ms=h.ms+1600;assert(S.Scheduler:RunTask('v3_combat_kills_honor'));S.Scheduler:RemoveTask('v3_combat_kills_honor')
assert(page:OnActivated());assert(page:RefreshStats())
local unified=S.Features.DPS:GetCombatOverview().rows[1]
assert(unified.kills==1 and unified.honorAssistedKills==1,'honor supplement did not enter the same overview kill count')
assert(f:GetPersonalHistoryProjection().totals.kills==beforeSupplement+1)
assert(analytics:_DispatchFact({category='death',kind='kill_notice',sourceName='GearTest',targetName='HonorVictim',targetKind='PLAYER',
    receivedAt=h.ms,rawEventType='UNIT_KILL_STREAK',rawNotice2=1,rawNotice3=5}))
unified=S.Features.DPS:GetCombatOverview().rows[1]
assert(unified.kills==1 and unified.honorAssistedKills==0,'late native attribution doubled the kill or left false unknown-target metadata')
assert(f:GetPersonalHistoryProjection().totals.kills==beforeSupplement+1)
assert(historyPage:OnActivated());assert(historyPage:RefreshData())
assert(historyTree.v3_personal_history_totals.text:find('击杀玩家 '..tostring(beforeSupplement+1),1,true),'history UI failed to show the unified increment')
assert(page:OnDeactivated());assert(historyPage:OnDeactivated())
print('PASS basic statistics + personal history runtime contract / read-only checks / kill-only skill row / exact victim drill-down / narrow layout / quiet lifecycle')

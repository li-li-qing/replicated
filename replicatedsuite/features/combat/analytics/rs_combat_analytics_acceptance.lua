------------------------------------------------------------------------
-- Replicated Suite V3 - Combat Analytics Acceptance
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S=ReplicatedSuite
local G=S.FoundationGate
local F=S.Features and S.Features.CombatAnalytics or nil
local A=S.Services and S.Services.CombatAnalyticsV3 or nil
local C=F and F.MetricCommon or nil
if type(G)~="table" or type(G.RegisterSequenceCase)~="function" or type(F)~="table" or type(A)~="table" or type(C)~="table" then return end
local function Fail(v) return false,tostring(v or "combat_analytics_acceptance_failed") end

G:RegisterSequenceCase("v3_m16_combat_analytics_contract",function()
    local meta=S.FeatureRegistry and S.FeatureRegistry:Get("combat_analytics") or nil
    if meta==nil or tostring(meta.status)~="migrated_m16_foundation" or tostring(meta.authority)~="v3.combat_analytics" then return Fail("metadata") end
    if S.FeatureRuntime==nil or S.FeatureRuntime:IsImplemented("combat_analytics")~=true then return Fail("feature_implementation") end
    local store=S.Persistence and S.Persistence:GetStore(F.StoreId or "v3.combat_analytics") or nil
    if store==nil or tonumber(store.schemaVersion)~=1 or tostring(store.owner)~="v3.combat_analytics" then return Fail("store") end
    if (tonumber(A.version) or 0)<3 or type(A.RegisterMetric)~="function" or type(A.AcquireConsumer)~="function" or type(A.GetMetricProjection)~="function" or type(A.GetMetricActorDetail)~="function" or type(A.ResetMetrics)~="function" or type(A.HasConsumer)~="function" or type(A.NotifyMetricChanged)~="function" then return Fail("authority") end
    local required={"encounter","kills","casts","performance","control","songcraft","utility","aura","mechanics"}
    for _,id in ipairs(required) do if A:GetMetric(id)==nil then return Fail("metric_missing:"..id) end end
    if #A:ListMetrics(false)<9 then return Fail("public_metric_count") end
    local catalog=S.Data and S.Data.CombatAbilityCatalog or nil;local ch=type(catalog)=="table" and catalog:GetHealth() or nil
    if type(ch)~="table" or (tonumber(ch.skills) or 0)<100 or (tonumber(ch.songs) or 0)<4 then return Fail("ability_catalog") end
    local mechanics=S.Data and S.Data.CombatMechanicCatalog or nil;if type(mechanics)~="table" or type(mechanics.FindCast)~="function" then return Fail("mechanic_catalog") end
    if S.UIV3==nil or S.UIV3.PageHost==nil or S.UIV3.PageHost.factories["combat.analytics"]==nil then return Fail("page") end
    if (tonumber(S.Events and S.Events.version) or 0) < 3 or type(S.Events.SubscribeOptional)~="function" then return Fail("optional_event_contract") end
    if (tonumber(S.Services and S.Services.CombatEventBusV3 and S.Services.CombatEventBusV3.version) or 0) < 6 then return Fail("combat_bus_version") end
    return true
end)

G:RegisterSequenceCase("v3_m16_18_15_analytics_value_switch_contract",function()
    if type(F.ApplyStoreRaw)~="function" or type(F.GetSelectedValueKey)~="function" or type(F.IsAnalyticsValueKey)~="function" or type(F.GetValueSelectorModels)~="function" then return Fail("value_switch_api") end
    local selectorModels=F:GetValueSelectorModels()
    if type(selectorModels)~="table" or #selectorModels~=#(F.PublicMetricIds or {}) then return Fail("value_selector_models") end
    for _,metricId in ipairs(F.PublicMetricIds or {}) do
        local options=type(F.GetValueOptions)=="function" and F:GetValueOptions(metricId) or {}
        for _,option in ipairs(options) do
            if F:IsAnalyticsValueKey(metricId,option and option.value)~=true then return Fail("value_option_drift:"..tostring(metricId)..":"..tostring(option and option.value)) end
        end
    end
    local state=F.State
    if type(state)~="table" or type(state.selectedValues)~="table" then return Fail("value_switch_state") end
    local previous=state.selectedValues.kills
    local ok,err=F:ApplyStoreRaw("selectedValue","kills","assists")
    if ok~=true or F:GetSelectedValueKey("kills")~="assists" then state.selectedValues.kills=previous;return Fail(err or "kills_assists_switch") end
    local invalid=F:ApplyStoreRaw("selectedValue","kills","not_a_metric_value")
    state.selectedValues.kills=previous
    if invalid==true then return Fail("invalid_value_must_reject") end
    return true
end)

G:RegisterSequenceCase("v3_m16_metric_common_bounded_queue",function()
    local q=C:NewBoundedQueue(8)
    for i=1,5000 do C:QueuePush(q,{at=i,value=i}) end
    if q.count~=8 or q.evicted~=4992 then return Fail("queue_count") end
    local rows=C:QueueToArray(q,false,20)
    if #rows~=8 or rows[1].value~=4993 or rows[8].value~=5000 then return Fail("queue_sparse_iteration") end
    C:QueuePruneBefore(q,4998)
    local remain=C:QueueToArray(q,false,20)
    if #remain~=3 or remain[1].value~=4998 or remain[3].value~=5000 then return Fail("queue_prune") end
    return true
end)

G:RegisterSequenceCase("v3_m16_11_actor_drilldown_contract",function()
    if type(A.GetMetricActorDetail)~="function" or type(F.GetActorDetail)~="function" then return Fail("drilldown_api") end
    local metric=A:GetMetric("kills")
    if type(metric)~="table" or type(metric.state)~="table" then return Fail("drilldown_metric") end
    local saved=metric.state
    local actor={key="name:AcceptanceActor",name="AcceptanceActor",kills=2,details={killTargets={TargetA=2,TargetB=1}}}
    metric.state={actors={[actor.key]=actor},actorCount=1,maxActors=512}
    local detail,err=A:GetMetricActorDetail("kills",actor.key,{limit=8,maxSections=4})
    metric.state=saved
    if type(detail)~="table" or type(detail.actor)~="table" or detail.actor.name~="AcceptanceActor" then return Fail(err or "drilldown_actor") end
    if type(detail.sections)~="table" or detail.sections[1]==nil or detail.sections[1].id~="killTargets" then return Fail("drilldown_sections") end
    if detail.sections[1].rows[1].name~="TargetA" or tonumber(detail.sections[1].rows[1].value)~=2 then return Fail("drilldown_rank") end
    return true
end)

G:RegisterSequenceCase("v3_m16_aura_normalization_contract",function()
    local bus=S.Services and S.Services.CombatEventBusV3 or nil
    if type(bus)~="table" or type(bus.DescribeEventType)~="function" then return Fail("bus") end
    local a=bus:DescribeEventType("SPELL_DEBUFF_APPLIED")
    local b=bus:DescribeEventType("SPELL_BUFF_REMOVED")
    if type(a)~="table" or a.category~="aura" or a.kind~="aura_apply" or a.auraType~="debuff" then return Fail("debuff_apply") end
    if type(b)~="table" or b.category~="aura" or b.kind~="aura_remove" or b.auraType~="buff" then return Fail("buff_remove") end
    return true
end)
G:RegisterSequenceCase("v3_m16_01_empty_consumer_release",function()
    -- Acceptance must not activate/reset a real user metric. The held->empty
    -- transition is covered by the pure runtime harness; here we only assert
    -- that an absent empty consumer can never materialize into Demand.
    local token="acceptance_combat_analytics_empty"
    A:ReleaseConsumer(token,"acceptance_cleanup")
    local acquired=A:AcquireConsumer(token,{metrics={}},"acceptance_empty_acquire")
    if acquired==true or A:HasConsumer(token)==true then return Fail("empty_acquire_must_reject") end
    local updated,err=A:UpdateConsumer(token,{metrics={}},"acceptance_empty_update")
    if updated~=true or A:HasConsumer(token)==true then return Fail(err or "empty_update_must_remain_released") end
    local health=A:GetHealth()
    if (tonumber(health.emptyConsumers) or 0)~=0 then return Fail("empty_consumer_health") end
    return true
end)

G:RegisterSequenceCase("v3_m16_01_public_reset_boundary",function()
    if type(A.ResetMetrics)~="function" then return Fail("reset_metrics_missing") end
    local hidden=A:GetMetric("dps_core")
    if hidden~=nil and hidden.hidden~=true then return Fail("dps_core_not_hidden") end
    for _,id in ipairs(F.PublicMetricIds or {}) do if A:GetMetric(id)==nil then return Fail("public_metric_missing:"..tostring(id)) end end
    return true
end)

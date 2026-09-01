------------------------------------------------------------------------
-- Replicated Suite V3 - Combat Analytics Feature
-- Lifecycle / settings / projection boundary. No native combat handlers here.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S=ReplicatedSuite
local Runtime=S.FeatureRuntime
S.Features=S.Features or {};S.Features.CombatAnalytics=S.Features.CombatAnalytics or {}
local F=S.Features.CombatAnalytics
if type(Runtime)~="table" then return end

F.Id="combat_analytics"
F.enabled=F.enabled==true
F.consumerToken="combat_analytics_feature"
F.analyticsHeld=F.analyticsHeld==true

local VALUE_OPTIONS={
    encounter={{value="durationMs",text="战斗时长"},{value="damage",text="战斗伤害"},{value="healing",text="战斗治疗"},{value="deaths",text="死亡"}},
    kills={{value="kills",text="击杀"},{value="assists",text="助攻"},{value="deaths",text="死亡"}},
    casts={{value="skillActivities",text="技能活动"},{value="exactCasts",text="本机精确施法"}},
    performance={{value="peak5sDps",text="5秒峰值DPS"},{value="peak5sDamage",text="5秒峰值伤害"},{value="highestHit",text="最高单击"},{value="damage",text="总伤害"},{value="deaths",text="死亡"}},
    control={{value="controlHits",text="控制命中"},{value="controlActivities",text="控制释放"},{value="controlMs",text="控制时长"},{value="controlled",text="被控次数"},{value="controlledMs",text="被控时长"}},
    songcraft={{value="songMs",text="演奏时长"},{value="songStarts",text="开始演奏"},{value="songSwitches",text="切歌"},{value="songActivities",text="演奏活动"},{value="songBuffMs",text="歌曲覆盖时长"},{value="songBuffApplies",text="歌曲覆盖次数"}},
    utility={{value="utilityActivities",text="辅助技能活动"},{value="utilityExact",text="本机精确使用"},{value="interrupt",text="打断技能活动"},{value="dispel",text="驱散技能活动"},{value="cleanse",text="净化/解控技能活动"},{value="resurrection",text="复活技能活动"},{value="defensive",text="防御技能活动"}},
    aura={{value="buffUptimeMs",text="Buff观察时长"},{value="debuffUptimeMs",text="Debuff观察时长"},{value="buffApplies",text="Buff施加"},{value="debuffApplies",text="Debuff施加"}},
    mechanics={{value="mechanics",text="机制命中"}},
}
local function Analytics() return S.Services and S.Services.CombatAnalyticsV3 or nil end
local function PublicSet() local out={};for _,id in ipairs(F.PublicMetricIds or {}) do out[id]=true end;return out end
local PUBLIC_SET=PublicSet()
local function ValidMetric(id) id=tostring(id or "");return PUBLIC_SET[id] and id or "kills" end
local function EmitUpdated(reason) if S.Events and type(S.Events.Publish)=="function" then S.Events:Publish("v3.combat_analytics.feature_updated",tostring(reason or "updated")) end end
function F:GetValueOptions(id) id=ValidMetric(id);return type(S.Utils)=="table" and S.Utils.DeepCopy(VALUE_OPTIONS[id] or {}) or (VALUE_OPTIONS[id] or {}) end
function F:GetValueSelectorModels()
    local out={}
    for _,metricId in ipairs(self.PublicMetricIds or {}) do
        out[#out+1]={id=tostring(metricId),options=self:GetValueOptions(metricId)}
    end
    return out
end
function F:GetEnabledMetricIds()
    local out={};for _,id in ipairs(self.PublicMetricIds or {}) do if self:IsMetricPreferenceEnabled(id) then out[#out+1]=id end end;return out
end
function F:Initialize()
    local ok,err=self:EnsureStoreLoaded();if ok~=true then return false,err end
    local a=Analytics();if type(a)~="table" or type(a.AcquireConsumer)~="function" then return false,"Combat Analytics Authority unavailable" end
    return true
end
function F:_AcquireOrUpdate(reason)
    local a=Analytics();if type(a)~="table" then return false,"Combat Analytics unavailable" end
    local ids=self:GetEnabledMetricIds()
    local ok,err=a:UpdateConsumer(self.consumerToken,{metrics=ids},reason or "analytics_update")
    if ok~=true then return false,err end
    self.analyticsHeld=#ids>0
    if type(a.HasConsumer)=="function" then self.analyticsHeld=a:HasConsumer(self.consumerToken) end
    return true
end
function F:_Release(reason)
    if self.analyticsHeld~=true then return true end
    local a=Analytics();if type(a)~="table" then return false,"Combat Analytics release unavailable" end
    local ok,err=a:ReleaseConsumer(self.consumerToken,reason or "analytics_release")
    if ok~=true then return false,err end
    self.analyticsHeld=false;return true
end
function F:Enable(reason)
    if self.enabled==true then return true end
    local ok,err=self:_AcquireOrUpdate(reason or "feature_enable");if ok~=true then return false,err end
    self.enabled=true;EmitUpdated("enabled");return true
end
function F:Disable(reason)
    if self.enabled~=true then return true end
    local ok,err=self:_Release(reason or "feature_disable");if ok~=true then return false,err end
    self.enabled=false;EmitUpdated("disabled");return true
end

local function PersistTransaction(apply,rollback,reason)
    local ok,err=apply();if ok~=true then return false,err end
    local dirty,dirtyErr=F:MarkAnalyticsStoreDirty(300,reason)
    if dirty==true then return true end
    rollback();return false,dirtyErr or "战斗分析设置保存排队失败"
end
function F:SetSelectedMetric(id)
    id=ValidMetric(id);local old=self.State.selectedMetric
    return PersistTransaction(function() return self:ApplyStoreRaw("selectedMetric",nil,id) end,function() self.State.selectedMetric=old end,"analytics_selected_metric")
end
function F:SetSelectedValueKey(id,key)
    id=ValidMetric(id);local old=self.State.selectedValues[id]
    return PersistTransaction(function() return self:ApplyStoreRaw("selectedValue",id,key) end,function() self.State.selectedValues[id]=old end,"analytics_value:"..id)
end
function F:SetMetricEnabled(id,enabled)
    id=ValidMetric(id);local old=self.State.metricEnabled[id];local target=enabled==true
    if old==target then return true end
    local ok,err=self:ApplyStoreRaw("metricEnabled",id,target);if ok~=true then return false,err end
    if self.enabled==true then
        local runtimeOk,runtimeErr=self:_AcquireOrUpdate("metric_toggle:"..id)
        if runtimeOk~=true then self.State.metricEnabled[id]=old;return false,runtimeErr end
    end
    local dirty,dirtyErr=self:MarkAnalyticsStoreDirty(300,"analytics_metric:"..id)
    if dirty==true then EmitUpdated("metric:"..id);return true end
    self.State.metricEnabled[id]=old
    if self.enabled==true then
        local rollbackOk,rollbackErr=self:_AcquireOrUpdate("metric_persist_rollback:"..id)
        if rollbackOk~=true then return false,tostring(dirtyErr or "persist failed").."; runtime rollback failed: "..tostring(rollbackErr) end
    end
    return false,dirtyErr or "指标设置保存排队失败"
end
function F:ClearMetric(id)
    id=ValidMetric(id);local a=Analytics();if type(a)~="table" then return false,"Combat Analytics unavailable" end
    return a:ResetMetric(id,"user_clear")
end
function F:ClearAll()
    local a=Analytics();if type(a)~="table" or type(a.ResetMetrics)~="function" then return false,"Combat Analytics reset unavailable" end
    return a:ResetMetrics(self.PublicMetricIds or {},"user_clear_all")
end
function F:GetProjection(metricId,options)
    metricId=ValidMetric(metricId or self:GetSelectedMetric());options=type(options)=="table" and options or {}
    if options.valueKey==nil then options.valueKey=self:GetSelectedValueKey(metricId) end
    local a=Analytics();local p,err
    if type(a)=="table" then p,err=a:GetMetricProjection(metricId,options) else err="Combat Analytics unavailable" end
    local runtime=S.FeatureRuntime and S.FeatureRuntime:GetSnapshot(self.Id) or nil
    return {enabled=runtime and runtime.enabled==true or false,metricId=metricId,metricEnabled=self:IsMetricPreferenceEnabled(metricId),settings=self:GetAnalyticsSettings(),metrics=type(a)=="table" and a:ListMetrics(false) or {},projection=p,error=err,health=type(a)=="table" and a:GetHealth() or nil}
end
function F:GetActorDetail(metricId, actorKey, options)
    metricId = ValidMetric(metricId or self:GetSelectedMetric())
    local a = Analytics()
    if type(a) ~= "table" or type(a.GetMetricActorDetail) ~= "function" then return nil, "战斗分析明细不可用" end
    local detail, err = a:GetMetricActorDetail(metricId, actorKey, options)
    if detail == nil then return nil, err end
    return type(S.Utils) == "table" and S.Utils.DeepCopy(detail) or detail
end

function F:Compare(metricId,left,right,valueKey)
    local result=self:GetProjection(metricId,{valueKey=valueKey});local rows=result.projection and result.projection.rows or {};left=tostring(left or "");right=tostring(right or "")
    local out={leftName=left,rightName=right,left=nil,right=nil,valueKey=result.projection and result.projection.valueKey or valueKey}
    for _,row in ipairs(rows) do if row.name==left then out.left=row end;if row.name==right then out.right=row end end
    return out
end
function F:GetHealth()
    local a=Analytics();return {ok=self.enabled==true,analyticsHeld=self.analyticsHeld==true,enabledMetrics=#self:GetEnabledMetricIds(),analytics=type(a)=="table" and a:GetHealth() or nil}
end
F.Commands=F.Commands or {}
function F.Commands:SetEnabled(value,reason) return S.FeatureRuntime:SetPreferredEnabled(F.Id,value==true,reason or "combat_analytics_page") end
function F.Commands:SetMetricEnabled(id,value) return F:SetMetricEnabled(id,value) end
function F.Commands:SetSelectedMetric(id) return F:SetSelectedMetric(id) end
function F.Commands:SetSelectedValue(id,key) return F:SetSelectedValueKey(id,key) end
function F.Commands:ClearMetric(id) return F:ClearMetric(id) end
function F.Commands:ClearAll() return F:ClearAll() end
function F.Commands:GetActorDetail(id,key,options) return F:GetActorDetail(id,key,options) end

local ok,err=Runtime:RegisterImplementation(F.Id,F);if ok~=true then error(err) end

------------------------------------------------------------------------
-- Replicated Suite · 战斗分析功能入口
-- 作者：Replicated
-- QQ群：1104129461
--
-- 生命周期、设置与投影边界；这里不处理 Native 战斗事件。
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
    kills={{value="kills",text="击杀玩家"},{value="deaths",text="死亡"}},
}
local function Analytics() return S.Services and S.Services.CombatAnalyticsV3 or nil end
local function PublicSet() local out={};for _,id in ipairs(F.PublicMetricIds or {}) do out[id]=true end;return out end
local PUBLIC_SET=PublicSet()
local function ValidMetric(id) id=tostring(id or "");return PUBLIC_SET[id] and id or "kills" end
local function EmitUpdated(reason) if S.Events and type(S.Events.Publish)=="function" then S.Events:Publish("v3.combat_analytics.feature_updated",tostring(reason or "updated")) end end
function F:GetValueOptions(id) return type(S.Utils)=="table" and S.Utils.DeepCopy(VALUE_OPTIONS[id] or {}) or (VALUE_OPTIONS[id] or {}) end
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
    local ok,err=a:AcquireStatisticsConsumer(self.consumerToken,reason or "analytics_update")
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
    self.enabled=true;self:ScheduleSystemKillEvidence("collection_start");EmitUpdated("enabled");return true
end
function F:Disable(reason)
    if self.enabled~=true then return true end
    local ok,err=self:_Release(reason or "feature_disable");if ok~=true then return false,err end
    self.enabled=false;EmitUpdated("disabled");return true
end

-- 系统累计只做取证：沿已有 Scheduler 合并一次尾部采样，每5秒最多读一组本人资料，无循环轮询。
function F:ScheduleSystemKillEvidence(reason)
    local identity=S.Services and S.Services.UnitIdentityV3;local scheduler=S.Scheduler
    if not identity or type(identity.CapturePlayerKillEvidence)~="function" or not scheduler then return false end
    if self.systemKillSampleScheduled then return true end
    local now=tonumber(S.NowMs and S.NowMs()) or 0
    local delay=math.max(250,(tonumber(identity.playerKillEvidenceAt) or -5000)+5000-now)
    self.systemKillSampleScheduled=true;local generation=S.Generation
    local ok=scheduler:AddOneShot("v3_combat_system_kill_evidence",delay,function()
        self.systemKillSampleScheduled=false
        local a=Analytics()
        if generation~=S.Generation or not a or a.activeMetrics.kills~=true then return true end
        identity:CapturePlayerKillEvidence(reason);return true
    end,self,"P3",1)
    if ok~=true then self.systemKillSampleScheduled=false end
    return ok==true
end
function F:CancelSystemKillEvidence()
    if S.Scheduler then S.Scheduler:RemoveTask("v3_combat_system_kill_evidence") end
    self.systemKillSampleScheduled=false;return true
end

local function PersistTransaction(apply,reason)
    return F:MutateAnalyticsStore(function() return apply() end,300,reason)
end
function F:SetSelectedMetric(id)
    if not PUBLIC_SET[id] then return false,"metric suspended" end
    return PersistTransaction(function() return self:ApplyStoreRaw("selectedMetric",nil,id) end,"analytics_selected_metric")
end
function F:SetSelectedValueKey(id,key)
    if not PUBLIC_SET[id] then return false,"metric suspended" end
    local ok,err=PersistTransaction(function() return self:ApplyStoreRaw("selectedValue",id,key) end,"analytics_value:"..id)
    if ok then EmitUpdated("selected_value:"..id) end
    return ok,err
end
function F:SetHonorKillAmount(value,enabled)
    -- 列表只控制荣誉辅助证据，不改变统一击杀数的展示口径。
    local loaded,loadErr=self:EnsureStoreLoaded();if not loaded then return false,loadErr end
    local amount=self:NormalizeHonorKillAmount(value)
    if not amount then return false,"请输入1至1000000的整数荣誉值" end
    local amounts=self:GetHonorKillAmounts();local found
    for i,n in ipairs(amounts) do if n==amount then found=i;break end end
    if enabled==true then
        if found then return true end
        if #amounts>=16 then return false,"最多配置16种击杀荣誉值" end
        amounts[#amounts+1]=amount;table.sort(amounts)
    else
        if not found then return true end
        table.remove(amounts,found)
    end
    local ok,err=PersistTransaction(function()self.State.honorKillAmounts=amounts;return true end,"honor_kill_amounts")
    if ok then EmitUpdated("honor_kill_amounts") end
    return ok,err
end
function F:SetMetricEnabled(id,enabled)
    if not PUBLIC_SET[id] then return false,"metric suspended" end
    local old=self.State.metricEnabled[id];local target=enabled==true
    if old==target then return true end
    local mutationOk,mutationErr=self:MutateAnalyticsStore(function()
        local ok,err=self:ApplyStoreRaw("metricEnabled",id,target);if ok~=true then return false,err end
        local runtimeOk,runtimeErr=Analytics():RefreshStatisticsConsumers("metric_toggle:"..id)
        if runtimeOk~=true then return false,runtimeErr end
        return true
    end,300,"analytics_metric:"..id)
    if mutationOk==true then EmitUpdated("metric:"..id);return true end
    do
        local rollbackOk,rollbackErr=Analytics():RefreshStatisticsConsumers("metric_persist_rollback:"..id)
        if rollbackOk~=true then return false,tostring(mutationErr or "persist failed").."; runtime rollback failed: "..tostring(rollbackErr) end
    end
    return false,mutationErr or "指标设置保存排队失败"
end

function F:ClearMetric(id)
    if not PUBLIC_SET[id] then return false,"metric suspended" end
    local a=Analytics();if type(a)~="table" then return false,"Combat Analytics unavailable" end
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
    local runtime=S.FeatureRuntime and S.FeatureRuntime:GetSnapshot("combat_stats") or nil
    if not (runtime and runtime.enabled == true) then runtime=S.FeatureRuntime and S.FeatureRuntime:GetSnapshot(self.Id) or nil end
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
-- 合并后的伤害统计诊断必须包含击杀/死亡与个人历史。
-- 这里只读已加载状态，不调用 EnsureLoaded、GetProjection、Record 或任何战斗回调。
function F:DescribeDiagnosticDetail()
    local a=Analytics()
    local kills=a and a:GetMetric("kills")
    local bus=S.Services and S.Services.CombatEventBusV3
    local history=self.PersonalHistory
    local totals=history and history.state and history.state.totals or {}
    local hub=S.ModuleDiagnosticsHub
    return {available=true,scope=a and a:GetCollectionScope(),enabled=self.enabled==true,
        honorKillAssistance={enabled=true,excludedAssistAmounts={3,12},matchAmounts=self:GetHonorKillAmounts()},
        honorIngress=a and type(a.GetHonorIngressDiagnostics)=="function" and a:GetHonorIngressDiagnostics() or {available=false},
        legacyHonorKillAmounts=type(self.State.honorKillAmounts)=="table" and self:GetHonorKillAmounts() or nil,
        analytics=a and a:GetHealth(),
        -- 本人资料由身份服务按业务事件有界采样；导出只看缓存，不在诊断 getter 中触发 Native 查询。
        systemKillEvidence=S.Services and S.Services.UnitIdentityV3 and type(S.Services.UnitIdentityV3.GetPlayerKillEvidence)=="function"
            and S.Services.UnitIdentityV3:GetPlayerKillEvidence() or {available=false},
        -- 只读连接 Bus 原生入口→Analytics 过滤→kills 结算；生成报告不能补计或启动采集。
        ingress=a and type(a.GetDeathIngressDiagnostics)=="function" and a:GetDeathIngressDiagnostics() or {available=false},
        kills=kills and type(kills.GetDiagnosticDetail)=="function" and kills:GetDiagnosticDetail() or {available=false},
        bus=bus and type(bus.GetDiagnosticDetail)=="function" and bus:GetDiagnosticDetail()
            or {health=bus and type(bus.GetHealth)=="function" and bus:GetHealth()},
        relatedErrors=hub and type(hub.GetRecent)=="function" and hub:GetRecent(self.Id) or {},
        history={storeId=history and history.StoreId,loaded=history and history.loaded==true,revision=history and history.revision,
            error=history and history.lastError,failures=history and history.failures,
            transfer=history and type(history.GetTransferDiagnostics)=='function' and history:GetTransferDiagnostics() or {available=false}, -- 覆盖历史导出/原生展示失败，纯读缓存。
            totals={kills=totals.kills,inferredKills=totals.inferredKills,honorParticipations=totals.honorParticipations,honorKills=totals.honorKills,
                deaths=totals.deaths,damage=totals.damage,taken=totals.taken,healing=totals.healing}}}
end
F.Commands=F.Commands or {}
function F.Commands:SetEnabled(value,reason) return S.FeatureRuntime:ApplyPreferenceTargets({combat_stats=value==true,combat_analytics=value==true},reason or "combat_statistics_page") end
function F:SetCollectionScope(scope)
    if scope ~= "self" and scope ~= "all" then return false,"invalid collection scope" end
    local loaded,loadErr=self:EnsureStoreLoaded();if loaded~=true then return false,loadErr end
    local old=self:GetCollectionScope();if old==scope then return true end
    local a=Analytics()
    local ok,err=self:MutateAnalyticsStore(function()
        self.State.collectionScope=scope
        return a:ApplyCollectionScope(scope)
    end,300,"statistics_scope",true)
    if ok~=true then
        local restored,restoreErr=a:ApplyCollectionScope(old)
        if restored~=true then return false,tostring(err).."; scope rollback: "..tostring(restoreErr) end
        return false,err
    end
    local resetOk,resetErr=a:ResetAll("collection_scope_changed")
    if resetOk~=true then return false,resetErr end
    EmitUpdated("scope")
    return true
end
function F.Commands:SetCollectionScope(scope) return F:SetCollectionScope(scope) end
function F:GetPersonalHistoryProjection(options)
    return self.PersonalHistory and self.PersonalHistory:GetProjection(options) or {available=false,error="个人历史不可用"}
end
Analytics():SetStatisticsPolicy(function()
    local ok,err=F:EnsureStoreLoaded();if ok~=true then return nil,err end
    if not F.PersonalHistory then return nil,"personal history unavailable" end
    ok,err=F.PersonalHistory:EnsureLoaded(true);if ok~=true then return nil,err end
    local ids={"kills"}
    local dps=S.Features and S.Features.DPS
    local trackAmounts=true
    if dps and type(dps.IsTrackingCategoryEnabled)=="function" then
        ok,err=dps:EnsureStoreLoaded();if ok~=true then return nil,err end
        trackAmounts=dps:IsTrackingCategoryEnabled("damage") or dps:IsTrackingCategoryEnabled("heal")
    end
    -- 击杀/死亡直接写个人历史，不依赖金额指标；只记战绩时真正释放 DPS 和金额历史的事件消费者。
    if trackAmounts then
        ids[#ids+1]="personal_history"
        if Analytics():GetMetric("dps_core")~=nil then ids[#ids+1]="dps_core" end
    end
    return {metrics=ids,scope=F:GetCollectionScope()}
end)
function F.Commands:SetMetricEnabled(id,value) return F:SetMetricEnabled(id,value) end
function F.Commands:SetSelectedMetric(id) return F:SetSelectedMetric(id) end
function F.Commands:SetSelectedValue(id,key) return F:SetSelectedValueKey(id,key) end
function F.Commands:AddHonorKillAmount(value) return F:SetHonorKillAmount(value,true) end
function F.Commands:RemoveHonorKillAmount(value) return F:SetHonorKillAmount(value,false) end
function F.Commands:ClearMetric(id) return F:ClearMetric(id) end
function F.Commands:ClearAll() return F:ClearAll() end
function F.Commands:GetActorDetail(id,key,options) return F:GetActorDetail(id,key,options) end

local ok,err=Runtime:RegisterImplementation(F.Id,F);if ok~=true then error(err) end
local hub=S.ModuleDiagnosticsHub
if hub and type(hub.RegisterProvider)=="function" then
    for _,moduleId in ipairs({"combat_stats",F.Id}) do
        hub:RegisterProvider(moduleId,"combat_statistics",function()return F:DescribeDiagnosticDetail()end,30,{detailOnly=true})
    end
    -- 隐藏的旧分析入口与主入口共享 Store，明确绑定到用户实际导出的主模块。
    if type(hub.RegisterStoreOwner)=="function" then
        hub:RegisterStoreOwner("combat_stats",F.StoreId)
        if F.PersonalHistory then hub:RegisterStoreOwner("combat_stats",F.PersonalHistory.StoreId) end
    end
end

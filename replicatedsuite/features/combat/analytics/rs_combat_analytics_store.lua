------------------------------------------------------------------------
-- Replicated Suite V3 - Combat Analytics Store
-- 永久指标偏好与统一采集范围；个人战绩归独立 Character Store，实时排行仍为会话数据。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local P = S.Persistence
if type(P) ~= "table" or type(P.RegisterV3Store) ~= "function" then return end

S.Features = S.Features or {}
S.Features.CombatAnalytics = S.Features.CombatAnalytics or {}
local F = S.Features.CombatAnalytics
local U = S.Utils

local STORE_ID = "v3.combat_analytics"
local SCHEMA = 2
local PUBLIC_METRICS = { "encounter", "kills", "casts", "performance", "control", "songcraft", "utility", "aura", "mechanics" }
local METRIC_SET = {}; for _, id in ipairs(PUBLIC_METRICS) do METRIC_SET[id] = true end
local DEFAULT_VALUES = {
    encounter = "durationMs", kills = "kills", casts = "skillActivities", performance = "peak5sDps",
    control = "controlHits", songcraft = "songMs", utility = "utilityActivities", aura = "buffUptimeMs", mechanics = "mechanics",
}
local VALID_VALUES = {
    encounter={durationMs=true,damage=true,healing=true,deaths=true},
    -- 已删除的NPC/助攻选项只参与旧档规范化，保持原指纹；运行期由 IsAnalyticsValueKey 拒绝。
    kills={kills=true,npcKills=true,assists=true,deaths=true},
    casts={skillActivities=true,exactCasts=true},
    performance={peak5sDps=true,peak5sDamage=true,highestHit=true,damage=true,deaths=true},
    control={controlHits=true,controlActivities=true,controlMs=true,controlled=true,controlledMs=true},
    songcraft={songMs=true,songStarts=true,songSwitches=true,songActivities=true,songBuffMs=true,songBuffApplies=true},
    utility={utilityActivities=true,utilityExact=true,interrupt=true,dispel=true,cleanse=true,resurrection=true,defensive=true},
    aura={buffUptimeMs=true,debuffUptimeMs=true,buffApplies=true,debuffApplies=true},
    mechanics={mechanics=true},
}

local function Copy(value) return type(U)=="table" and type(U.DeepCopy)=="function" and U.DeepCopy(value) or value end
local function MetricId(value)
    local id=tostring(value or ""):lower():gsub("[^%w_%.%-]","_")
    return METRIC_SET[id] and id or "kills"
end
local function ValueKey(id,value)
    id=MetricId(id)
    local raw=tostring(value or "")
    return VALID_VALUES[id] and VALID_VALUES[id][raw] and raw or DEFAULT_VALUES[id]
end
local function NormalizeState(value)
    value=type(value)=="table" and value or {}
    local enabled, selectedValues = {}, {}
    local sourceEnabled=type(value.metricEnabled)=="table" and value.metricEnabled or {}
    local sourceValues=type(value.selectedValues)=="table" and value.selectedValues or {}
    for _,id in ipairs(PUBLIC_METRICS) do
        enabled[id] = sourceEnabled[id] ~= false
        selectedValues[id] = ValueKey(id, sourceValues[id])
    end
    return {
        collectionScope = value.collectionScope == "all" and "all" or "self",
        selectedMetric = MetricId(value.selectedMetric),
        metricEnabled = enabled,
        selectedValues = selectedValues,
    }
end

F.StoreId=STORE_ID
-- 保留 schema2 的完整规范化字段以兼容旧指纹；运行期只开放击杀/死亡。
-- 伤害、治疗、承伤沿用 dps_core，历史偏好不能重新启动已暂停的分析。
F.PublicMetricIds={"kills"}
F.State=NormalizeState(F.State)
F.StoreLoaded=F.StoreLoaded==true
local function Apply(value) F.State=NormalizeState(value) end

-- schema1 的原指纹不含 collectionScope。先按旧固定字段投影复现原章，再迁移为默认 self；
-- 仅返回候选，Envelope/预算/旧指纹精确匹配与重新保存均由 Persistence 负责，未知损坏仍写保护。
local function RebuildSchema1Canonical(value,_,_,raw)
    local meta=type(raw)=="table" and raw.__rsmeta or nil
    if type(meta)~="table" or meta.store~=STORE_ID or meta.owner~=STORE_ID or tonumber(meta.schema)~=1
        or type(value)~="table" or value.collectionScope~=nil then return nil end
    local historical=NormalizeState(value);historical.collectionScope=nil
    return historical,NormalizeState(value)
end

if P:GetStore(STORE_ID)==nil then
    local store,err=P:RegisterV3Store({
        id=STORE_ID, owner="v3.combat_analytics",
        scope=P.Scope and P.Scope.Account or "account", lifetime=P.Lifetime and P.Lifetime.Permanent or "permanent",
        schemaVersion=SCHEMA, legacySchemaVersion=0,
        key=P.V3KeyPrefix and (P.V3KeyPrefix.."combat_analytics") or STORE_ID,
        budget={maxDepth=5,maxNodes=320,maxStringBytes=5000,maxEntriesPerTable=48},
        rebuildCanonicalForIntegrity=RebuildSchema1Canonical,
        default=function() return NormalizeState(nil) end,
        get=function() return NormalizeState(F.State) end,
        apply=Apply, migrate=function(v) return NormalizeState(v) end,
    })
    if store==nil and S.DiagnosticsManager and type(S.DiagnosticsManager.Error)=="function" then
        S.DiagnosticsManager:Error("combat_analytics","ANALYTICS_STORE_REGISTER_FAILED","战斗分析设置存档注册失败",{error=tostring(err)})
    end
end

function F:EnsureStoreLoaded()
    if type(P.IsStoreLoaded)=="function" and P:IsStoreLoaded(STORE_ID)==true then self.StoreLoaded=true; return true end
    if P:GetStore(STORE_ID)==nil then return false,"战斗分析设置存档不可用" end
    local status,_,err=P:LoadStore(STORE_ID)
    if status~=true and status~="empty" then return false,err or tostring(status or "读取失败") end
    if status=="empty" then Apply(nil) end
    self.StoreLoaded=true
    return true
end
function F:GetAnalyticsSettings()
    local out=Copy(self.State)
    -- DeepCopy不可用时也不能让公开选项回退改写用于校验的原偏好。
    if out==self.State then
        out={};for key,value in pairs(self.State) do out[key]=value end
        out.selectedValues={};for key,value in pairs(self.State.selectedValues) do out.selectedValues[key]=value end
    end
    out.selectedValues.kills=self:GetSelectedValueKey("kills")
    return out
end
function F:GetCollectionScope() return self.State.collectionScope == "all" and "all" or "self" end
function F:IsMetricPreferenceEnabled(id) return id=="kills" and self.State.metricEnabled.kills~=false end
function F:GetSelectedMetric() return "kills" end
function F:IsAnalyticsValueKey(id,value)
    return id=="kills" and (value=="kills" or value=="deaths")
end
function F:GetSelectedValueKey(id)
    local value=id=="kills" and self.State.selectedValues.kills or nil
    return self:IsAnalyticsValueKey(id,value) and value or "kills"
end
function F:ApplyStoreRaw(kind,id,value)
    kind=tostring(kind or "")
    if kind=="selectedMetric" then
        if value~="kills" then return false,"metric suspended" end
        self.State.selectedMetric="kills";return true
    end
    if id~="kills" then return false,"metric suspended" end
    if kind=="metricEnabled" then self.State.metricEnabled[id]=value==true;return true end
    if kind=="selectedValue" then
        local v=tostring(value or "")
        if self:IsAnalyticsValueKey(id,v)~=true then return false,"invalid analytics value key" end
        self.State.selectedValues[id]=v
        return true
    end
    return false,"unknown analytics setting"
end
function F:MutateAnalyticsStore(mutator,delayMs,reason,durable)
    return P:MutateStore(STORE_ID,function() return mutator() end,{delayMs=tonumber(delayMs) or 300,reason=tostring(reason or "combat_analytics_changed"),durable=durable==true})
end

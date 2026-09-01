------------------------------------------------------------------------
-- Replicated Suite V3 - Combat Analytics Store
-- Permanent preferences only. Live combat analytics remains session-only.
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
local SCHEMA = 1
local PUBLIC_METRICS = { "encounter", "kills", "casts", "performance", "control", "songcraft", "utility", "aura", "mechanics" }
local METRIC_SET = {}; for _, id in ipairs(PUBLIC_METRICS) do METRIC_SET[id] = true end
local DEFAULT_VALUES = {
    encounter = "durationMs", kills = "kills", casts = "skillActivities", performance = "peak5sDps",
    control = "controlHits", songcraft = "songMs", utility = "utilityActivities", aura = "buffUptimeMs", mechanics = "mechanics",
}
local VALID_VALUES = {
    encounter={durationMs=true,damage=true,healing=true,deaths=true},
    kills={kills=true,assists=true,deaths=true},
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
        selectedMetric = MetricId(value.selectedMetric),
        metricEnabled = enabled,
        selectedValues = selectedValues,
    }
end

F.StoreId=STORE_ID
F.PublicMetricIds=PUBLIC_METRICS
F.State=NormalizeState(F.State)
F.StoreLoaded=F.StoreLoaded==true
local function Apply(value) F.State=NormalizeState(value) end

if P:GetStore(STORE_ID)==nil then
    local store,err=P:RegisterV3Store({
        id=STORE_ID, owner="v3.combat_analytics",
        scope=P.Scope and P.Scope.Account or "account", lifetime=P.Lifetime and P.Lifetime.Permanent or "permanent",
        schemaVersion=SCHEMA, legacySchemaVersion=0,
        key=P.V3KeyPrefix and (P.V3KeyPrefix.."combat_analytics") or STORE_ID,
        budget={maxDepth=5,maxNodes=320,maxStringBytes=5000,maxEntriesPerTable=48},
        default=function() return NormalizeState(nil) end,
        get=function() return NormalizeState(F.State) end,
        apply=Apply, migrate=function(v) return NormalizeState(v) end,
    })
    if store==nil and S.DiagnosticsManager and type(S.DiagnosticsManager.Error)=="function" then
        S.DiagnosticsManager:Error("combat_analytics","ANALYTICS_STORE_REGISTER_FAILED","战斗分析设置存档注册失败",{error=tostring(err)})
    end
end

function F:EnsureStoreLoaded()
    if self.StoreLoaded==true then return true end
    if P:GetStore(STORE_ID)==nil then return false,"战斗分析设置存档不可用" end
    local status,_,err=P:LoadStore(STORE_ID)
    if status~=true and status~="empty" then return false,err or tostring(status or "读取失败") end
    if status=="empty" then Apply(nil) end
    self.StoreLoaded=true
    return true
end
function F:GetAnalyticsSettings() return Copy(self.State) end
function F:IsMetricPreferenceEnabled(id) id=MetricId(id); return self.State.metricEnabled[id]~=false end
function F:GetSelectedMetric() return MetricId(self.State.selectedMetric) end
function F:IsAnalyticsValueKey(id,value)
    id=MetricId(id);local raw=tostring(value or "")
    return VALID_VALUES[id]~=nil and VALID_VALUES[id][raw]==true
end
function F:GetSelectedValueKey(id) id=MetricId(id); return ValueKey(id, self.State.selectedValues[id]) end
function F:ApplyStoreRaw(kind,id,value)
    kind=tostring(kind or "")
    if kind=="selectedMetric" then self.State.selectedMetric=MetricId(value);return true end
    id=MetricId(id)
    if kind=="metricEnabled" then self.State.metricEnabled[id]=value==true;return true end
    if kind=="selectedValue" then
        local v=tostring(value or "")
        if self:IsAnalyticsValueKey(id,v)~=true then return false,"invalid analytics value key" end
        self.State.selectedValues[id]=v
        return true
    end
    return false,"unknown analytics setting"
end
function F:MarkAnalyticsStoreDirty(delayMs,reason) return P:MarkDirty(STORE_ID,tonumber(delayMs) or 300,reason or "combat_analytics_changed") end

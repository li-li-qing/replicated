------------------------------------------------------------------------
-- Replicated Suite V3 - Housing Feature Lifecycle
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local Runtime = S.FeatureRuntime
S.Features = S.Features or {}
S.Features.Housing = S.Features.Housing or {}
local F = S.Features.Housing
if type(Runtime) ~= "table" or type(F.Authority) ~= "table" then return end

F.Id = "life_housing"
F.ApiDependencies = { "X2House:GetCurrentHousingTaxInfo", "X2House:GetHouseOwnerName", "X2House:GetHouseName", "X2House:GetHouseType" }
F.enabled = F.enabled == true

function F:Initialize() return true end
function F:ReconcileDemand(_, before, after)
    if (tonumber(before and before.count) or 0) <= 0 and (tonumber(after and after.count) or 0) > 0 then
        return self.Authority:Refresh("housing_consumer_acquire")
    end
    return true
end
if S.Demand == nil or type(S.Demand.Create) ~= "function" then error("Demand unavailable for Housing") end
local demand, demandErr = S.Demand:Create({
    id = "feature:" .. F.Id, owner = F, projectionOwner = F,
    projectionConsumersField = "consumers", projectionCountField = "consumerCount",
    reconcile = function(lease, before, after) return F:ReconcileDemand(lease, before, after) end,
})
if demand == nil then error(demandErr) end
F.Demand = demand

function F:AcquireConsumer(token)
    if self.enabled ~= true then return false, "housing feature disabled" end
    return self.Demand:Acquire(token, {}, "housing_consumer")
end
function F:ReleaseConsumer(token) return self.Demand:Release(token, "housing_consumer") end
function F:Enable() self.enabled = true; return true end
function F:Disable(reason)
    local cleared, clearErr = self.Demand:Clear(reason or "housing_feature_disable")
    if cleared ~= true then return false, clearErr end
    self.enabled = false
    return true
end
function F:Refresh(reason)
    if self.enabled ~= true or self.consumerCount <= 0 then return true end
    return self.Authority:Refresh(reason or "housing_refresh")
end
function F:GetProjection() return self.Authority:GetProjection() end
function F:GetHealth()
    local health = self.Authority:GetHealth()
    health.enabled, health.consumers = self.enabled == true, self.consumerCount
    return health
end

F.Commands = F.Commands or {}
function F.Commands:Refresh(reason) return F:Refresh(reason or "housing_command") end

local ok, err = Runtime:RegisterImplementation(F.Id, F)
if ok ~= true then error(err) end

------------------------------------------------------------------------
-- Replicated Suite V3 - Instance Browser Feature
--
-- Page-scoped feature. X2BattleField is imported only when this feature is
-- initialized; InstanceCatalogV3 runs only while a consumer is visible.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local Runtime = S.FeatureRuntime
if type(Runtime) ~= "table" then return end

S.Features = S.Features or {}
S.Features.InstanceBrowser = S.Features.InstanceBrowser or {}
local F = S.Features.InstanceBrowser
F.Id = "tools_instance_browser"
F.ApiDependencies = { "BATTLE_FIELD" }
F.enabled = F.enabled == true
F.consumers = {}
F.consumerCount = 0
F.serviceConsumerToken = "feature:tools_instance_browser"
F.serviceConsumerHeld = false
F.subscribed = false

function F:Initialize()
    local service = S.Services and S.Services.InstanceCatalogV3 or nil
    if type(service) ~= "table" then return false, "instance catalog service unavailable" end
    if type(self.Authority) ~= "table" then return false, "instance browser authority unavailable" end
    return true
end

function F:Subscribe()
    if self.subscribed == true then return true end
    if S.Events == nil or type(S.Events.SubscribeInternal) ~= "function" then return false, "internal event bus unavailable" end
    local subscribed = S.Events:SubscribeInternal("v3.instances.updated", self, function()
        if F.enabled == true and F.consumerCount > 0 then F.Authority:Refresh("instance_service") end
    end)
    if subscribed ~= true then return false, "instance service internal subscribe failed" end
    self.subscribed = true
    return true
end

function F:Unsubscribe()
    if self.subscribed ~= true then return true end
    if S.Events ~= nil and type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
    self.subscribed = false
    return true
end

function F:ReconcileDemand(before, after)
    local beforeCount = tonumber(before and before.count) or 0
    local afterCount = tonumber(after and after.count) or 0
    if beforeCount == 0 and afterCount > 0 then
        local service = S.Services and S.Services.InstanceCatalogV3 or nil
        if type(service) ~= "table" or type(service.AcquireConsumer) ~= "function" then
            return false, "instance catalog service unavailable"
        end
        local ok, err = service:AcquireConsumer(self.serviceConsumerToken)
        if ok ~= true then return false, err end
        self.serviceConsumerHeld = true
        local subscribed, subErr = self:Subscribe()
        if subscribed ~= true then return false, subErr end
        local refreshed, refreshErr = self.Authority:Refresh("consumer_acquired")
        if refreshed == false then return false, refreshErr or "instance browser refresh failed" end
    elseif beforeCount > 0 and afterCount == 0 then
        self:Unsubscribe()
        if self.serviceConsumerHeld == true then
            local service = S.Services and S.Services.InstanceCatalogV3 or nil
            if type(service) ~= "table" or type(service.ReleaseConsumer) ~= "function" then
                return false, "instance catalog release unavailable"
            end
            local released, releaseErr = service:ReleaseConsumer(self.serviceConsumerToken)
            if released ~= true then return false, releaseErr or "instance catalog release failed" end
            self.serviceConsumerHeld = false
        end
        self.Authority:ResetTransient()
    end
    return true
end

if S.Demand == nil or type(S.Demand.Create) ~= "function" then error("Demand unavailable for InstanceBrowser") end
local instanceFeatureDemand, instanceFeatureDemandErr = S.Demand:Create({
    id = "feature:" .. F.Id,
    owner = F,
    projectionOwner = F,
    projectionConsumersField = "consumers",
    projectionCountField = "consumerCount",
    reconcile = function(_, before, after) return F:ReconcileDemand(before, after) end,
    quiesce = function(_, reason, cause) return F:QuiesceDemand(reason, cause) end,
})
if instanceFeatureDemand == nil then error(instanceFeatureDemandErr) end
F.Demand = instanceFeatureDemand

function F:AcquireConsumer(token)
    if self.enabled ~= true then return false, "instance browser disabled" end
    return self.Demand:Acquire(token, {}, "instance_browser_consumer")
end

function F:ReleaseConsumer(token)
    return self.Demand:Release(token, "instance_browser_consumer")
end

function F:QuiesceDemand(reason, cause)
    local ok = self:Unsubscribe() == true
    if self.serviceConsumerHeld == true then
        local service = S.Services and S.Services.InstanceCatalogV3 or nil
        if type(service) ~= "table" or type(service.ReleaseConsumer) ~= "function" then
            ok = false
        else
            local released = service:ReleaseConsumer(self.serviceConsumerToken)
            if released ~= true then ok = false else self.serviceConsumerHeld = false end
        end
    end
    self.Authority:ResetTransient()
    return ok
end

function F:Enable(reason)
    if self.enabled == true then return true end
    self.enabled = true
    return true
end

function F:Disable(reason)
    if self.enabled ~= true then return true end
    local cleared, clearErr = self.Demand:Clear(reason or "feature_disable")
    if cleared ~= true then return false, clearErr end
    self.enabled = false
    return true
end

function F:Refresh(reason, fullDiscovery)
    if self.enabled ~= true or self.consumerCount <= 0 then return true end
    local service = S.Services and S.Services.InstanceCatalogV3 or nil
    if type(service) ~= "table" then return false, "instance catalog service unavailable" end
    local ok, err = service:Refresh(reason or "feature_refresh", fullDiscovery == true)
    if ok ~= true then return false, err end
    return self.Authority:Refresh(reason or "feature_refresh")
end

-- Public Projection boundary for Active V3. Pages consume these snapshots
-- instead of retaining the Instance Authority object.
function F:GetRows()
    return self.Authority:GetRows()
end

function F:GetRow(id)
    return self.Authority:GetRow(id)
end

function F:GetSummary()
    return self.Authority:GetSummary()
end

function F:GetHealth()
    local service = S.Services and S.Services.InstanceCatalogV3 or nil
    local serviceHealth = type(service) == "table" and type(service.GetHealth) == "function" and service:GetHealth() or nil
    local summary = self.Authority:GetSummary()
    return {
        ok = self.enabled == true,
        consumers = self.consumerCount,
        rows = summary.total,
        mapped = summary.mapped,
        unmapped = summary.unmapped,
        serviceRunning = type(serviceHealth) == "table" and serviceHealth.running == true or false,
        serviceRevision = type(serviceHealth) == "table" and serviceHealth.revision or 0,
        refreshFailures = type(serviceHealth) == "table" and serviceHealth.refreshFailures or 0,
    }
end

F.Commands = F.Commands or {}
function F.Commands:Refresh(reason, fullDiscovery) return F:Refresh(reason or "instance_command", fullDiscovery == true) end

local ok, err = Runtime:RegisterImplementation(F.Id, F)
if ok ~= true then error(err) end

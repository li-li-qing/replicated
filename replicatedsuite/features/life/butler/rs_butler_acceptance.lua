------------------------------------------------------------------------
-- Replicated Suite V3 - Butler Acceptance
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local G = S.FoundationGate
local F = S.Features and S.Features.Butler or nil
if type(G) ~= "table" or type(G.RegisterSequenceCase) ~= "function" or type(F) ~= "table" then return end
G:RegisterSequenceCase("v3_butler_read_only_contract", function()
    local meta = S.FeatureRegistry and S.FeatureRegistry:Get("life_butler") or nil
    if meta == nil or tostring(meta.status) ~= "migrated_v3_read_only" or tostring(meta.authority) ~= "v3.butler" then return false, "metadata_contract" end
    if S.FeatureRuntime == nil or S.FeatureRuntime:IsImplemented("life_butler") ~= true then return false, "implementation_missing" end
    if type(F.Authority) ~= "table" or type(F.GetProjection) ~= "function" or type(F.GetHealth) ~= "function"
        or type(F.Demand) ~= "table" or type(F.Demand.Acquire) ~= "function" or type(F.Demand.Release) ~= "function" or type(F.Demand.Clear) ~= "function" then return false, "projection_or_demand_contract" end
    if type(F.Commands) ~= "table" or type(F.Commands.Refresh) ~= "function" then return false, "command_contract" end
    return true
end)

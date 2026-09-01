------------------------------------------------------------------------
-- Replicated Suite V3 - Random Shop Acceptance
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local G = S.FoundationGate
local F = S.Features and S.Features.RandomShop or nil
if type(G) ~= "table" or type(G.RegisterSequenceCase) ~= "function" or type(F) ~= "table" then return end
G:RegisterSequenceCase("v3_random_shop_read_only_contract", function()
    local meta = S.FeatureRegistry and S.FeatureRegistry:Get("tools_random_shop") or nil
    if meta == nil or tostring(meta.status) ~= "migrated_v3_read_only" or tostring(meta.authority) ~= "v3.random_shop" then return false, "metadata_contract" end
    if S.FeatureRuntime == nil or S.FeatureRuntime:IsImplemented("tools_random_shop") ~= true then return false, "implementation_missing" end
    if type(F.Authority) ~= "table" or type(F.GetProjection) ~= "function" or type(F.GetHealth) ~= "function"
        or type(F.Demand) ~= "table" or type(F.Demand.Acquire) ~= "function" or type(F.Demand.Release) ~= "function" or type(F.Demand.Clear) ~= "function" then return false, "projection_or_demand_contract" end
    if type(F.Commands) ~= "table" or type(F.Commands.Refresh) ~= "function" then return false, "command_contract" end
    return true
end)

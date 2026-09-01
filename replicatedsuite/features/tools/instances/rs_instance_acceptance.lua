------------------------------------------------------------------------
-- Replicated Suite V3 - Instance Browser Acceptance
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local G = S.FoundationGate
local F = S.Features and S.Features.InstanceBrowser or nil
if type(G) ~= "table" or type(G.RegisterSequenceCase) ~= "function" or type(F) ~= "table" then return end

local function Fail(message) return false, tostring(message or "instance_acceptance_failed") end

G:RegisterSequenceCase("v3_m1_instance_browser", function()
    local meta = S.FeatureRegistry and S.FeatureRegistry:Get("tools_instance_browser") or nil
    if meta == nil or tostring(meta.status) ~= "migrated_m1" or tostring(meta.authority) ~= "v3.instances" then return Fail("metadata_contract") end
    if S.FeatureRuntime == nil or S.FeatureRuntime:IsImplemented("tools_instance_browser") ~= true then return Fail("implementation_missing") end
    local service = S.Services and S.Services.InstanceCatalogV3 or nil
    if type(service) ~= "table" or type(service.GetRows) ~= "function" or type(service.GetEntryProgress) ~= "function" then return Fail("service_contract") end
    if S.UIV3 == nil or S.UIV3.PageHost == nil or S.UIV3.PageHost.factories["tools.instance_browser"] == nil then return Fail("page_contract") end
    if S.Services ~= nil and S.Services.QuestProgressV3 ~= nil and type(S.Services.QuestProgressV3.GetInstanceProgress) ~= "function" then return Fail("quest_progress_bridge") end
    return true
end)

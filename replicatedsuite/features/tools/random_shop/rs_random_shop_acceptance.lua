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
    -- 维护：仅检查新观察/设置契约，不在诊断序列里读取游戏、写档或改变用户Consumer。
    if tonumber(F.ObservationContractVersion) ~= 2 or F.Patch ~= "random-shop-observer-1"
        or type(F.Commands.SetAutoRead) ~= "function" or type(F.Commands.SetThreshold) ~= "function"
        or type(F.Commands.ResetBaseline) ~= "function" or type(F.EnsureStoreLoaded) ~= "function" then
        return false, "observer_settings_contract"
    end
    local store = S.Persistence and S.Persistence:GetStore("v3.random_shop")
    if store == nil or store.registrationBudgetOk ~= true or store.scope ~= S.Persistence.Scope.Account
        or tonumber(store.schemaVersion) ~= 1 then return false, "settings_store_contract" end
    if meta.navigationIncomplete ~= true or meta.settingsCapable ~= true then return false, "acceptance_scope_contract" end
    return true
end)

-- Replicated Suite · 藏宝图助手契约验收
-- 作者：Replicated
-- QQ群：1104129461
-- 验证观察版本、更新主题与 Demand 生命周期；实现缺失明确失败，由 sequence_harness 报告。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local G = S.FoundationGate
if type(G) ~= "table" or type(G.RegisterSequenceCase) ~= "function" then return end
local F = S.Features and S.Features.Treasure or nil

local function Fail(message) return false, tostring(message or "treasure_observation_failed") end

-- 运行时只做只读诊断；完整序列测试仅离线执行。
G:RegisterSequenceCase("v3_life_treasure_observation_contract", function()
    if type(F) ~= "table" then return Fail("implementation_not_registered") end
    if (tonumber(F.ObservationContractVersion) or 0) < 1 then return Fail("observation_contract_version") end
    if type(F.UpdateTopic) ~= "string" then return Fail("observation_update_topic_type") end
    if F.UpdateTopic == "" then return Fail("observation_update_topic_empty") end
    if type(F.Demand) ~= "table" then return Fail("demand_missing") end
    if type(F.Demand.Acquire) ~= "function" or type(F.Demand.Release) ~= "function" then
        return Fail("demand_lifecycle_contract")
    end
    return true
end, { runtime = true })

G:RegisterSequenceCase("v3_life_treasure_inventory_contract",function()
    if not F or (tonumber(F.InventoryContractVersion) or 0)<1 then return Fail("treasure_inventory_component_missing")end
    if not F.Inventory or F.Inventory.storeId~="v3.life.treasure.inventory" then return Fail("treasure_inventory_store_missing")end
    for _,name in ipairs({"RegisterCoffer","WithdrawCoordinate","CancelWithdrawal","SetCoordinateContinent","SetInventorySort"})do
        if type(F.Commands[name])~="function" then return Fail("treasure_inventory_command_"..name)end
    end
    return true
end,{runtime=true})

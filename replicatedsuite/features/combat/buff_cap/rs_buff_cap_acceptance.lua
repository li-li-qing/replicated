------------------------------------------------------------------------
-- Replicated Suite · 状态数量提醒契约验收
-- 作者：Replicated
-- QQ群：1104129461
--
-- 验证实现存在、ObservationContractVersion≥1、UpdateTopic为非空string，并存在Demand订阅生命周期。
-- Core不直接依赖业务实现表；验收失败为blocker，由sequence_harness报告。架构审计不跳过注释，说明禁止添加业务表加字段的点号引用。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local G = S.FoundationGate
if type(G) ~= "table" or type(G.RegisterSequenceCase) ~= "function" then return end
local F = S.Features and S.Features.combat_buff_cap or nil

local function Fail(message) return false, tostring(message or "buff_cap_observation_failed") end

-- 显式接回只读运行时诊断；完整序列仍保留给离线验收。
G:RegisterSequenceCase("v3_combat_buff_cap_observation_contract", function()
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

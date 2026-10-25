-- Replicated Suite · 范围辅助契约验收
-- 作者：Replicated
-- QQ群：1104129461
-- 只查 visual_guides 版本和米数投影契约，不读取目标；距离样本由 Feature Demand 采集。失败由 sequence_harness 报告。

if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local G = S.FoundationGate
if type(G) ~= "table" or type(G.RegisterSequenceCase) ~= "function" then return end
local F = S.Features and S.Features.combat_range_assist or nil

local function Fail(message) return false, tostring(message or "range_assist_acceptance_failed") end

-- 运行时只做只读诊断；完整序列测试仅离线执行。
G:RegisterSequenceCase("v3_combat_range_assist_visual_guide_contract", function()
    if type(F) ~= "table" then return Fail("implementation_not_registered") end
    if (tonumber(F.VisualGuideContractVersion) or 0) < 9 then return Fail("visual_guide_contract_version") end
    if (tonumber(F.WorldSpaceContractVersion) or 0) < 3 then return Fail("world_space_contract_version") end
    if (tonumber(F.ProjectionFactsContractVersion) or 0) < 7 then return Fail("projection_facts_contract_version") end
    if (tonumber(F.AnchorCalibrationContractVersion) or 0) < 2 then return Fail("anchor_calibration_contract_version") end
    if (tonumber(F.MetricDistanceContractVersion) or 0) < 1 then return Fail("metric_distance_contract_version") end
    return true
end, { runtime = true })

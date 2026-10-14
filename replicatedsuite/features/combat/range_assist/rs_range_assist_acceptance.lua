------------------------------------------------------------------------
-- Replicated Suite · 范围辅助契约验收
-- 作者：Replicated
-- QQ群：1104129461
--
-- 验证visual_guides涉及的五项契约版本，保留原有逐项下限。失败为blocker，由sequence_harness报告。
-- 仅校验投影/米数契约，不读target；真实UnitDistance样本仅由RangeAssist的Demand按需采集。
-- 架构审计不跳过注释，说明禁止添加业务表加字段的点号引用。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local G = S.FoundationGate
if type(G) ~= "table" or type(G.RegisterSequenceCase) ~= "function" then return end
local F = S.Features and S.Features.combat_range_assist or nil

local function Fail(message) return false, tostring(message or "range_assist_acceptance_failed") end

-- 显式接回只读运行时诊断；完整序列仍保留给离线验收。
G:RegisterSequenceCase("v3_combat_range_assist_visual_guide_contract", function()
    if type(F) ~= "table" then return Fail("implementation_not_registered") end
    if (tonumber(F.VisualGuideContractVersion) or 0) < 9 then return Fail("visual_guide_contract_version") end
    if (tonumber(F.WorldSpaceContractVersion) or 0) < 3 then return Fail("world_space_contract_version") end
    if (tonumber(F.ProjectionFactsContractVersion) or 0) < 7 then return Fail("projection_facts_contract_version") end
    if (tonumber(F.AnchorCalibrationContractVersion) or 0) < 2 then return Fail("anchor_calibration_contract_version") end
    if (tonumber(F.MetricDistanceContractVersion) or 0) < 1 then return Fail("metric_distance_contract_version") end
    return true
end, { runtime = true })

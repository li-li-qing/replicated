------------------------------------------------------------------------
-- Replicated Suite · 单位连线契约验收
-- 作者：Replicated
-- QQ群：1104129461
--
-- 验证visual_guides涉及的五项契约版本，保留原有逐项下限；Core不直接点名业务实现，失败为blocker，由sequence_harness报告。
-- 架构审计不跳过注释，说明禁止添加业务表加字段的点号引用。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local G = S.FoundationGate
if type(G) ~= "table" or type(G.RegisterSequenceCase) ~= "function" then return end
local F = S.Features and S.Features.combat_unit_lines or nil

local function Fail(message) return false, tostring(message or "unit_lines_acceptance_failed") end

-- 显式接回只读运行时诊断；完整序列仍保留给离线验收。
G:RegisterSequenceCase("v3_combat_unit_lines_visual_guide_contract", function()
    if type(F) ~= "table" then return Fail("implementation_not_registered") end
    if (tonumber(F.VisualGuideContractVersion) or 0) < 5 then return Fail("visual_guide_contract_version") end
    if (tonumber(F.AdaptiveDensityContractVersion) or 0) < 2 then return Fail("adaptive_density_contract_version") end
    if (tonumber(F.SmoothRefreshContractVersion) or 0) < 1 then return Fail("smooth_refresh_contract_version") end
    if (tonumber(F.FrontHemisphereContractVersion) or 0) < 1 then return Fail("front_hemisphere_contract_version") end
    if (tonumber(F.ProjectionConsistencyContractVersion) or 0) < 1 then return Fail("projection_consistency_contract_version") end
    return true
end, { runtime = true })

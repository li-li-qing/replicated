------------------------------------------------------------------------
-- Replicated Suite V3 - combat_unit_lines Visual Guide Contract Acceptance
--
-- Phase 3 Batch H（2026-09-29，core-feature-decoupling-1）：本文件承载单位连线与视觉引导配合的
-- 五个契约版本。它们原先由 core/rs_foundation_gate.lua 的 v3_combat_life_usability_contract 里的
-- visual_guides 判定点名检查；搬到这里之后 Core 不再认识具体业务 Feature。失败同样是 blocker
-- （sequence case 失败 → sequence_harness 检查）。
--
-- 判定与旧版**逐条等价**（注释里不要写出带点号的“表名+字段”形式：rs_architecture_audit 是行级正则
-- 且不跳过注释，说明文字会被重新计成 CORE_FEATURE 债务）。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local G = S.FoundationGate
if type(G) ~= "table" or type(G.RegisterSequenceCase) ~= "function" then return end
local F = S.Features and S.Features.combat_unit_lines or nil

local function Fail(message) return false, tostring(message or "unit_lines_acceptance_failed") end

G:RegisterSequenceCase("v3_combat_unit_lines_visual_guide_contract", function()
    if type(F) ~= "table" then return Fail("implementation_not_registered") end
    if (tonumber(F.VisualGuideContractVersion) or 0) < 5 then return Fail("visual_guide_contract_version") end
    if (tonumber(F.AdaptiveDensityContractVersion) or 0) < 2 then return Fail("adaptive_density_contract_version") end
    if (tonumber(F.SmoothRefreshContractVersion) or 0) < 1 then return Fail("smooth_refresh_contract_version") end
    if (tonumber(F.FrontHemisphereContractVersion) or 0) < 1 then return Fail("front_hemisphere_contract_version") end
    if (tonumber(F.ProjectionConsistencyContractVersion) or 0) < 1 then return Fail("projection_consistency_contract_version") end
    return true
end)

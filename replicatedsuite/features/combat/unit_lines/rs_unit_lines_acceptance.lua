-- Replicated Suite · 单位连线契约验收
-- 作者：Replicated
-- QQ群：1104129461
-- 检查 visual_guides 的五项版本下限，失败由 sequence_harness 报告。

if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local G = S.FoundationGate
if type(G) ~= "table" or type(G.RegisterSequenceCase) ~= "function" then return end
local F = S.Features and S.Features.combat_unit_lines or nil

local function Fail(message) return false, tostring(message or "unit_lines_acceptance_failed") end

-- 运行时只做只读诊断；完整序列测试仅离线执行。
G:RegisterSequenceCase("v3_combat_unit_lines_visual_guide_contract", function()
    if type(F) ~= "table" then return Fail("implementation_not_registered") end
    if (tonumber(F.VisualGuideContractVersion) or 0) < 5 then return Fail("visual_guide_contract_version") end
    if (tonumber(F.AdaptiveDensityContractVersion) or 0) < 2 then return Fail("adaptive_density_contract_version") end
    if (tonumber(F.SmoothRefreshContractVersion) or 0) < 1 then return Fail("smooth_refresh_contract_version") end
    if (tonumber(F.FrontHemisphereContractVersion) or 0) < 1 then return Fail("front_hemisphere_contract_version") end
    if (tonumber(F.ProjectionConsistencyContractVersion) or 0) < 1 then return Fail("projection_consistency_contract_version") end
    return true
end, { runtime = true })

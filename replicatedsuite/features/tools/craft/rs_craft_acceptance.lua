------------------------------------------------------------------------
-- Replicated Suite · 制作台助手契约验收
-- 作者：Replicated
-- QQ群：1104129461
--
-- 验证制作Feature自身用户选择与Sidecar契约，保留各项下限；实现缺失不得静默返回，失败为blocker，由sequence_harness报告。
-- CraftSurfaceV3/CraftSidecar服务与UI契约仍归Foundation；只覆盖产品仍保留的tools_craft，禁止为已删除制作规划能力保留空壳检查。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local G = S.FoundationGate
if type(G) ~= "table" or type(G.RegisterSequenceCase) ~= "function" then return end
local F = S.Features and S.Features.tools_craft or nil

local function Fail(message) return false, tostring(message or "craft_acceptance_failed") end

-- 显式接回只读运行时诊断；完整序列仍保留给离线验收。
G:RegisterSequenceCase("v3_tools_craft_contract", function()
    if type(F) ~= "table" then return Fail("implementation_not_registered") end
    -- v3_craft_user_selection_contract 的 Feature 侧
    if (tonumber(F.CraftUserSelectionContractVersion) or 0) < 1 then return Fail("craft_user_selection_contract_version") end
    if type(F.Commands) ~= "table" or type(F.Commands.SelectRecipe) ~= "function" then return Fail("craft_select_recipe_command") end
    -- v3_craft_sidecar_contract 的 Feature 侧
    if (tonumber(F.CraftSidecarContractVersion) or 0) < 1 then return Fail("craft_sidecar_contract_version") end
    if type(F.Commands.SetAutoSidecar) ~= "function" then return Fail("craft_auto_sidecar_command") end
    return true
end, { runtime = true })

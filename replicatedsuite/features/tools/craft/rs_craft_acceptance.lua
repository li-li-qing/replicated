------------------------------------------------------------------------
-- Replicated Suite V3 - tools_craft Contract Acceptance
--
-- Phase 3 Batch I（2026-09-29，core-feature-decoupling-1）：本文件承载制作助手的 Feature 侧契约。
-- 它们原先由 core/rs_foundation_gate.lua 的两个 AddCheck（v3_craft_user_selection_contract /
-- v3_craft_sidecar_contract）直接点名实现表检查；搬到这里之后 Core 不再认识具体业务 Feature。
-- 失败同样是 blocker（sequence case 失败 → sequence_harness 检查）。
--
-- 边界：**同一条 AddCheck 里的 Service / UIV3 契约留在 Foundation**（CraftSurfaceV3 / CraftSidecar
-- —— 它们不是 Feature 债）。本文件只承载“这个 Feature 自己必须提供什么”。
-- 判定与旧版**逐条等价**（下限照搬），外加“实现缺失不再静默 return”。
--
-- 历史提醒：2026-09-15 曾删除制作规划相关能力，Foundation 里那条 blocker 只覆盖仍在产品中的
-- tools_craft。搬过来之后这个边界不变 —— 本文件不得为已移除的功能保留空壳检查。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local G = S.FoundationGate
if type(G) ~= "table" or type(G.RegisterSequenceCase) ~= "function" then return end
local F = S.Features and S.Features.tools_craft or nil

local function Fail(message) return false, tostring(message or "craft_acceptance_failed") end

G:RegisterSequenceCase("v3_tools_craft_contract", function()
    if type(F) ~= "table" then return Fail("implementation_not_registered") end
    -- v3_craft_user_selection_contract 的 Feature 侧
    if (tonumber(F.CraftUserSelectionContractVersion) or 0) < 1 then return Fail("craft_user_selection_contract_version") end
    if type(F.Commands) ~= "table" or type(F.Commands.SelectRecipe) ~= "function" then return Fail("craft_select_recipe_command") end
    -- v3_craft_sidecar_contract 的 Feature 侧
    if (tonumber(F.CraftSidecarContractVersion) or 0) < 1 then return Fail("craft_sidecar_contract_version") end
    if type(F.Commands.SetAutoSidecar) ~= "function" then return Fail("craft_auto_sidecar_command") end
    return true
end)

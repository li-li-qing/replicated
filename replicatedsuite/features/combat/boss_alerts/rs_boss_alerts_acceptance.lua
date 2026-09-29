------------------------------------------------------------------------
-- Replicated Suite V3 - combat_boss_alerts HUD Contract Acceptance
--
-- Phase 3 Batch H（2026-09-29，core-feature-decoupling-1）：本文件承载首领机制 HUD 与实时事实桥的
-- 契约版本。这两项原先由 core/rs_foundation_gate.lua 的 v3_combat_life_usability_contract 里的
-- boss_hud 判定点名检查；搬到这里之后 Core 不再认识具体业务 Feature。失败同样是 blocker
-- （sequence case 失败 → sequence_harness 检查）。
--
-- 判定与旧版**等价或更严**（注释里不要写出带点号的“表名+字段”形式：rs_architecture_audit 是行级
-- 正则且不跳过注释，说明文字会被重新计成 CORE_FEATURE 债务）：
--   * 旧版：实现表存在 + HUD 契约 >= 2 + 实时事实桥契约 >= 1
--   * 本文件：同上，外加 HUD 呈现投影必须可用（旧判定只看版本号，不看投影是否真能取到）
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local G = S.FoundationGate
if type(G) ~= "table" or type(G.RegisterSequenceCase) ~= "function" then return end
local F = S.Features and S.Features.combat_boss_alerts or nil

local function Fail(message) return false, tostring(message or "boss_alerts_acceptance_failed") end

G:RegisterSequenceCase("v3_combat_boss_alerts_hud_contract", function()
    if type(F) ~= "table" then return Fail("implementation_not_registered") end
    if (tonumber(F.HudContractVersion) or 0) < 2 then return Fail("hud_contract_version") end
    if (tonumber(F.RealtimeFactBridgeContractVersion) or 0) < 1 then return Fail("realtime_fact_bridge_contract_version") end
    if type(F._bossDiag) ~= "table" then return Fail("boss_diagnostics_projection_missing") end
    return true
end)

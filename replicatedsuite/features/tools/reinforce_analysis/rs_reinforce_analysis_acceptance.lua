------------------------------------------------------------------------
-- Replicated Suite V3 - tools_reinforce_analysis Runtime Block Acceptance
--
-- Phase 3 Batch F（2026-09-29，core-feature-decoupling-1）：本文件承载该 Feature 的**运行时阻塞真值**
-- （SlotProbeRuntimeBlocked）。该项原先由 core/rs_foundation_gate.lua 的 v3_feature_truth_contract
-- 硬编码点名检查；搬到这里之后 Core 不再认识具体业务 Feature。失败同样是 blocker
-- （sequence case 失败 → sequence_harness 检查）。
--
-- 语义（与旧判定逐条等价，注释里不要写出带点号的“表名+字段”形式：rs_architecture_audit 是行级
-- 正则且不跳过注释，说明文字会被重新计成 CORE_FEATURE 债务）：
--   强化槽位探测在 RU 上不可用，因此 Feature 必须显式声明自己被硬阻塞 —— 这是“如实的部分能力标注”，
--   不能靠“没实现所以自然失败”蒙过去。声明为 true 才算诚实。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local G = S.FoundationGate
if type(G) ~= "table" or type(G.RegisterSequenceCase) ~= "function" then return end
local F = S.Features and S.Features.tools_reinforce_analysis or nil

local function Fail(message) return false, tostring(message or "reinforce_analysis_truth_failed") end

G:RegisterSequenceCase("v3_tools_reinforce_analysis_runtime_block_contract", function()
    if type(F) ~= "table" then return Fail("implementation_not_registered") end
    if F.SlotProbeRuntimeBlocked ~= true then return Fail("slot_probe_runtime_block_missing") end
    return true
end)

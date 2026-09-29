------------------------------------------------------------------------
-- Replicated Suite V3 - life_treasure Demand Observation Acceptance
--
-- Phase 3 Batch E（2026-09-29，core-feature-decoupling-1）：本文件承载该 Feature 的**观察契约**
-- （ObservationContractVersion + UpdateTopic）。这两项原先由 core/rs_foundation_gate.lua 的
-- v3_dynamic_observation_contract 硬编码点名检查；搬到这里之后 Core 不再认识具体业务 Feature。
-- 失败同样是 blocker —— sequence case 失败会落 sequence_harness 检查。
--
-- 判定与旧版**等价或更严**（注释里不要写出带点号的“表名+字段”形式：rs_architecture_audit 是
-- 行级正则且不跳过注释，说明文字会被重新计成 CORE_FEATURE 债务）：
--   * 旧版：实现表存在 + 契约版本 >= 1 + topic 是 string
--   * 本文件：同上，外加 topic 非空、且 Demand 确实存在（没有 Demand 就没有订阅生命周期，topic 形同虚设）
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local G = S.FoundationGate
if type(G) ~= "table" or type(G.RegisterSequenceCase) ~= "function" then return end
local F = S.Features and S.Features.Treasure or nil

local function Fail(message) return false, tostring(message or "treasure_observation_failed") end

G:RegisterSequenceCase("v3_life_treasure_observation_contract", function()
    if type(F) ~= "table" then return Fail("implementation_not_registered") end
    if (tonumber(F.ObservationContractVersion) or 0) < 1 then return Fail("observation_contract_version") end
    if type(F.UpdateTopic) ~= "string" then return Fail("observation_update_topic_type") end
    if F.UpdateTopic == "" then return Fail("observation_update_topic_empty") end
    if type(F.Demand) ~= "table" then return Fail("demand_missing") end
    if type(F.Demand.Acquire) ~= "function" or type(F.Demand.Release) ~= "function" then
        return Fail("demand_lifecycle_contract")
    end
    return true
end)

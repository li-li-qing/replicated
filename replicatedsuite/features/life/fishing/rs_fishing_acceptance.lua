------------------------------------------------------------------------
-- Replicated Suite V3 - life_fishing Demand Observation Acceptance
--
-- Phase 3 Batch E（2026-09-29，core-feature-decoupling-1）：本文件承载该 Feature 的**观察契约**
-- （ObservationContractVersion + UpdateTopic）。这两项原先由 core/rs_foundation_gate.lua 的
-- v3_dynamic_observation_contract 硬编码点名检查；搬到这里之后 Core 不再认识具体业务 Feature。
-- 失败同样是 blocker —— sequence case 失败会落 sequence_harness 检查。
--
-- 注意：本文件**只**承载观察契约。Fishing 的 Auto-R 热键事务契约由
-- v3_feature_truth_contract 那一组负责（Phase 3 Batch F 范围），不要顺手搬进来。
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
local F = S.Features and S.Features.Fishing or nil

local function Fail(message) return false, tostring(message or "fishing_observation_failed") end

G:RegisterSequenceCase("v3_life_fishing_observation_contract", function()
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

-- Phase 3 Batch F（2026-09-29，core-feature-decoupling-1）：Auto-R 事务契约。
-- 原先由 core/rs_foundation_gate.lua 的 v3_feature_truth_contract 硬编码点名 Fishing 检查；
-- 搬到这里之后 Core 不再认识具体业务 Feature。判定与旧版**逐条等价**：
--   * Auto-R 不得被硬阻塞（旧 gate 曾把“必须硬阻塞”当真值，导致真实事务恢复后仍被基础验收判失败）
--   * Feature 侧热键契约 >= v3；独立热键事务服务的 TransactionContractVersion >= v3
-- 兼容边界不变：这里只验证契约存在，**不执行任何 Native 热键读写**；RU 写键行为仍由
-- FishingHotkeyV3 的 capability gate / 战斗门 / 持久恢复快照保护。
G:RegisterSequenceCase("v3_life_fishing_auto_r_transaction_contract", function()
    if type(F) ~= "table" then return Fail("implementation_not_registered") end
    if F.HotkeyRuntimeBlocked == true then return Fail("auto_r_hard_blocked") end
    if (tonumber(F.HotkeyContractVersion) or 0) < 3 then return Fail("hotkey_contract_version") end
    local hotkey = S.Services and S.Services.FishingHotkeyV3 or nil
    if type(hotkey) ~= "table" then return Fail("fishing_hotkey_service_missing") end
    if (tonumber(hotkey.TransactionContractVersion) or 0) < 3 then return Fail("hotkey_transaction_contract_version") end
    return true
end)

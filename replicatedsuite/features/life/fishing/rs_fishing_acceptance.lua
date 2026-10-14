------------------------------------------------------------------------
-- Replicated Suite · 钓鱼助手契约验收
-- 作者：Replicated
-- QQ群：1104129461
--
-- 仅验证观察契约：实现存在、ObservationContractVersion≥1、UpdateTopic非空string、Demand存在。
-- Auto-R热键事务仍由v3_feature_truth_contract负责，禁止混入此验收；失败为blocker，由sequence_harness报告。
-- 架构审计不跳过注释，说明禁止添加业务表加字段的点号引用。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local G = S.FoundationGate
if type(G) ~= "table" or type(G.RegisterSequenceCase) ~= "function" then return end
local F = S.Features and S.Features.Fishing or nil

local function Fail(message) return false, tostring(message or "fishing_observation_failed") end

-- 显式接回只读运行时诊断；完整序列仍保留给离线验收。
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
end, { runtime = true })

-- Auto-R 事务契约。
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
end, { runtime = true })

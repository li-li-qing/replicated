-- Replicated Suite · 钓鱼助手契约验收
-- 作者：Replicated
-- QQ群：1104129461
-- 验证观察版本、更新主题和 Demand；热键事务另行检查，所有 case 均不执行 Native 写键。失败由 sequence_harness 报告。

if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local G = S.FoundationGate
if type(G) ~= "table" or type(G.RegisterSequenceCase) ~= "function" then return end
local F = S.Features and S.Features.Fishing or nil

local function Fail(message) return false, tostring(message or "fishing_observation_failed") end

-- 运行时只做只读诊断；完整序列测试仅离线执行。
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

-- 只检查 Auto-R 未被硬阻塞、Feature 热键契约>=3 和独立事务服务契约>=3，不执行 Native 热键读写。
-- 实机写键仍须经过能力门、战斗门、持久恢复快照与 readback。
G:RegisterSequenceCase("v3_life_fishing_auto_r_transaction_contract", function()
    if type(F) ~= "table" then return Fail("implementation_not_registered") end
    if F.HotkeyRuntimeBlocked == true then return Fail("auto_r_hard_blocked") end
    if (tonumber(F.HotkeyContractVersion) or 0) < 3 then return Fail("hotkey_contract_version") end
    local hotkey = S.Services and S.Services.FishingHotkeyV3 or nil
    if type(hotkey) ~= "table" then return Fail("fishing_hotkey_service_missing") end
    if (tonumber(hotkey.TransactionContractVersion) or 0) < 3 then return Fail("hotkey_transaction_contract_version") end
    return true
end, { runtime = true })

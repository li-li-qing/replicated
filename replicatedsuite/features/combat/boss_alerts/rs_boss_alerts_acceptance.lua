------------------------------------------------------------------------
-- Replicated Suite · 首领机制提示契约验收
-- 作者：Replicated
-- QQ群：1104129461
--
-- 验证首领HUD契约≥2、实时事实桥契约≥1与实现存在；必须注册诊断provider，观察运行中必须有真实诊断表。
-- 关闭/尚未开始观察是合法状态，禁止验收强制开启或制造空统计。失败为blocker，由sequence_harness报告。
-- rs_architecture_audit按行匹配且不跳过注释，说明中禁止加入业务实现表加字段的点号形式，避免被计作CORE_FEATURE依赖。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local G = S.FoundationGate
if type(G) ~= "table" or type(G.RegisterSequenceCase) ~= "function" then return end
local F = S.Features and S.Features.combat_boss_alerts or nil

local function Fail(message) return false, tostring(message or "boss_alerts_acceptance_failed") end

-- 显式接回只读运行时诊断；完整序列仍保留给离线验收。
G:RegisterSequenceCase("v3_combat_boss_alerts_hud_contract", function()
    if type(F) ~= "table" then return Fail("implementation_not_registered") end
    if (tonumber(F.HudContractVersion) or 0) < 2 then return Fail("hud_contract_version") end
    if (tonumber(F.RealtimeFactBridgeContractVersion) or 0) < 1 then return Fail("realtime_fact_bridge_contract_version") end
    -- 诊断表由 BossStartObservation 在首次
    -- 真实观察租约建立后创建。冷启动关闭/HUD 禁用时 nil 合法；检查只读 provider 接线，
    -- 不 Get/Enable/Acquire、不分配假表。已经观察中的缺表或已存在的畸形值仍须阻断。
    local providers = S.FeatureHealthProviders
    if type(providers) ~= "table" or type(providers.Has) ~= "function"
        or type(providers.Get) ~= "function" or providers:Has("boss_alerts_diagnostics") ~= true then
        return Fail("boss_diagnostics_provider_missing")
    end
    if F._bossObservationStarted == true and type(F._bossDiag) ~= "table" then
        return Fail("boss_diagnostics_projection_missing")
    end
    if F._bossDiag ~= nil and type(F._bossDiag) ~= "table" then
        return Fail("boss_diagnostics_projection_invalid")
    end
    return true
end, { runtime = true })

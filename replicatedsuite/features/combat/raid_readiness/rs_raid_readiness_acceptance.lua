------------------------------------------------------------------------
-- Replicated Suite V3 - Raid Readiness Acceptance
--
-- Static/non-destructive contract checks only. Runtime team inspection remains
-- user initiated and is never started by Foundation diagnostics.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local G = S.FoundationGate
if type(G) ~= "table" or type(G.RegisterSequenceCase) ~= "function" then return end
-- 中文维护注释（Phase 3 Batch A，2026-09-29，core-feature-decoupling-1）：本文件是 RaidReadiness 的
-- **唯一契约 Authority**。原先 F 缺失时这里静默 return，把“实现根本没注册”留给 Foundation 的硬编码
-- 断言兜底；Phase 3 正在删掉那处硬编码，所以这里必须**无条件注册** case，并在实现缺失时明确失败 ——
-- 否则搬迁之后“Feature 加载失败”会从 blocker 静默退化成“没有检查”。
local F = S.Features and S.Features.RaidReadiness or nil

local function Fail(message) return false, tostring(message or "raid_readiness_acceptance_failed") end

-- 维护（2026-09-30，refactor-live-gate-1）：显式接回只读运行时诊断；完整序列仍保留给离线验收。
G:RegisterSequenceCase("v3_m16_14_raid_readiness_contract", function()
    if type(F) ~= "table" then return Fail("implementation_not_registered") end
    local meta = S.FeatureRegistry and S.FeatureRegistry:Get("combat_raid_readiness") or nil
    if meta == nil or tostring(meta.status) ~= "migrated_m16_14"
        or tostring(meta.lifecycle) ~= "on_demand_scan"
        or tostring(meta.authority):find("v3.raid_readiness", 1, true) == nil
        or meta.widgetCapable == true or meta.settingsCapable ~= true or meta.defaultEnabled == true then
        return Fail("metadata_contract")
    end
    if S.FeatureRuntime == nil or S.FeatureRuntime:IsImplemented("combat_raid_readiness") ~= true then
        return Fail("implementation_missing")
    end

    local store = S.Persistence and S.Persistence:GetStore(F.StoreId or "v3.raid_readiness") or nil
    if store == nil or tostring(store.owner or "") ~= "v3.raid_readiness"
        or tostring(store.scope or "") ~= tostring(S.Persistence.Scope.Account)
        or tonumber(store.schemaVersion) ~= 1 then
        return Fail("store_contract")
    end
    if type(F.GetSettings) ~= "function" or type(F.ApplySettingRaw) ~= "function"
        or type(F.EnsureStoreLoaded) ~= "function" or type(F.RunScan) ~= "function"
        or type(F.AcquireAuraLease) ~= "function" or type(F.ReleaseAuraLease) ~= "function"
        or F.Demand == nil or type(F.Commands) ~= "table"
        or type(F.Commands.ApplySettingFromBinding) ~= "function" or type(F.Commands.MarkStoreDirty) ~= "function" then
        return Fail("feature_contract")
    end

    local authority = F.Authority
    if type(authority) ~= "table" or (tonumber(authority.version) or 0) < 1
        or type(authority.StartScan) ~= "function" or type(authority.CancelScan) ~= "function"
        or type(authority.GetRows) ~= "function" or type(authority.GetSummary) ~= "function" then
        return Fail("authority_contract")
    end

    local roster = S.Services and S.Services.TeamRosterV3 or nil
    local aura = S.Services and S.Services.AuraObservationV3 or nil
    if type(roster) ~= "table" or (tonumber(roster.version) or 0) < 4
        or type(roster.AcquireConsumer) ~= "function" or type(roster.GetSnapshot) ~= "function" then
        return Fail("roster_contract")
    end
    if type(aura) ~= "table" or (tonumber(aura.version) or 0) < 2
        or type(aura.GetSnapshot) ~= "function" or type(aura.GetStatusMap) ~= "function"
        or type(aura.EvaluateRequiredEffects) ~= "function" or type(aura.AcquireConsumer) ~= "function" then
        return Fail("aura_phase12b_contract")
    end

    local page = S.UIV3 and S.UIV3.PageHost and S.UIV3.PageHost.factories
        and S.UIV3.PageHost.factories["combat.raid_readiness"] or nil
    if page == nil then return Fail("page_contract") end

    local teamApi = S.NativeContract and type(S.NativeContract.GetApi) == "function" and S.NativeContract:GetApi("TEAM") or nil
    if type(teamApi) ~= "table" or tonumber(teamApi.id) ~= 38 or tostring(teamApi.nativeName or "") ~= "X2Team" then
        return Fail("team_native_contract")
    end

    -- A dormant feature must not retain the expensive Aura lease. If another
    -- consumer has explicitly opened the page / started a scan, do not flag it.
    -- 维护（Phase 3 Batch A）：这段是从 Foundation 的 raid_readiness_runtime_scope 搬过来的，
    -- 搬迁时保持**不弱于**原判定 —— 原判定在无 consumer 时同时要求 rosterHeld / auraHeld /
    -- scanning 三者都为 false，并且 scanning/auraHeld 之间存在依赖顺序，逐条保留：
    --   scanning=true 必须有 roster；auraHeld=true 必须正在 scanning。
    if (tonumber(F.consumerCount) or 0) <= 0 then
        if F.rosterHeld == true then return Fail("dormant_roster_lease") end
        if F.auraHeld == true then return Fail("dormant_aura_lease") end
        if F.scanning == true then return Fail("dormant_scan") end
    end
    if F.scanning == true and F.rosterHeld ~= true then return Fail("scan_without_roster_lease") end
    if F.auraHeld == true and F.scanning ~= true then return Fail("aura_without_scan") end
    return true
end, { runtime = true })

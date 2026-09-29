------------------------------------------------------------------------
-- Replicated Suite V3 - combat_team_tools Contract Acceptance
--
-- Phase 3 Batch K（2026-09-29，core-feature-decoupling-1）：本文件承载团队工具的 Feature 侧契约，
-- 分两个 case 对应原先 Foundation 里的两条判定：
--   v3_team_role_contract         → 角色/自动职责 + 名单租约的生命周期契约
--   v3_team_visual_marker_contract→ 视觉/标记快照 + 牺牲之舞 + 自动职责默认开启
-- 它们原先由 core/rs_foundation_gate.lua 直接点名实现表检查；搬到这里之后 Core 不再认识具体业务
-- Feature。失败同样是 blocker（sequence case 失败 → sequence_harness 检查）。
--
-- 边界：**同一条判定里的 Service / Data / UIV3 契约留在 Foundation**
-- （TeamRosterV3 的团队边沿 settle、静态职责目录及其两个已确认职业组合、TeamSacOverlay 的呈现契约）
-- —— 它们不是 Feature 债。判断标准是“这段契约的主语是 Feature 还是 Core/Service”。
-- 判定与旧版**逐条等价**（下限照搬），外加“实现缺失不再静默 return”。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local G = S.FoundationGate
if type(G) ~= "table" or type(G.RegisterSequenceCase) ~= "function" then return end
local F = S.Features and S.Features.combat_team_tools or nil

local function Fail(message) return false, tostring(message or "team_tools_acceptance_failed") end

G:RegisterSequenceCase("v3_combat_team_tools_role_contract", function()
    if type(F) ~= "table" then return Fail("implementation_not_registered") end
    -- 中文维护注释（2026-09-16）：v3 才包含独立 Event owner/roster lease 与关→开重建观察，
    -- 所以自动职责契约版本不能只看目录版本 —— 这里逐条照搬旧下限。
    if (tonumber(F.TeamRoleContractVersion) or 0) < 2 then return Fail("team_role_contract_version") end
    if (tonumber(F.AutoRoleContractVersion) or 0) < 3 then return Fail("auto_role_contract_version") end
    if (tonumber(F.AutoRoleCatalogContractVersion) or 0) < 2 then return Fail("auto_role_catalog_contract_version") end
    if (tonumber(F.AutoRoleRosterLeaseContractVersion) or 0) < 1 then return Fail("auto_role_roster_lease_contract_version") end
    if type(F.Commands) ~= "table" or type(F.Commands.SetRole) ~= "function" then return Fail("set_role_command") end
    return true
end)

G:RegisterSequenceCase("v3_combat_team_tools_visual_marker_contract", function()
    if type(F) ~= "table" then return Fail("implementation_not_registered") end
    -- 中文维护注释：visual v2 固化“牺牲之舞 fresh default=on + schema1 旧关闭语义迁移”；
    -- marker 快照沿用串行写入/回读确认契约；sac 要求 schema2/default-on Store；
    -- 自动职责 fresh Store 默认开启，但旧用户显式 false 必须继续由 Store 持久化（本文件只查声明）。
    if (tonumber(F.TeamVisualContractVersion) or 0) < 2 then return Fail("team_visual_contract_version") end
    if (tonumber(F.TeamMarkerSnapshotContractVersion) or 0) < 1 then return Fail("team_marker_snapshot_contract_version") end
    if (tonumber(F.TeamSacContractVersion) or 0) < 2 then return Fail("team_sac_contract_version") end
    if (tonumber(F.AutoRoleDefaultOnContractVersion) or 0) < 1 then return Fail("auto_role_default_on_contract_version") end
    if type(F.Commands) ~= "table" then return Fail("commands_table_missing") end
    for _, name in ipairs({ "SetSacHighlightEnabled", "SaveRaidMarkers", "RestoreRaidMarkers",
        "ClearSavedRaidMarkers" }) do
        if type(F.Commands[name]) ~= "function" then return Fail("team_visual_command:" .. name) end
    end
    return true
end)

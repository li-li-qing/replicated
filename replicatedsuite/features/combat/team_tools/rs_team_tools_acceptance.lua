-- Replicated Suite · 团队职责工具契约验收
-- 作者：Replicated
-- QQ群：1104129461
-- 两个case分别验证职责/自动职责及名单租约生命周期，与视觉/标记快照、牺牲之舞和自动职责默认启用。
-- TeamRosterV3团队边沿settle、静态职责目录与两个已确认组合、TeamSacOverlay表现契约仍归Foundation；按契约主语区分Feature与Core/Service责任。
-- 保留各项契约下限，缺实现不得静默返回；失败为blocker，由sequence_harness报告。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local G = S.FoundationGate
if type(G) ~= "table" or type(G.RegisterSequenceCase) ~= "function" then return end
local F = S.Features and S.Features.combat_team_tools or nil
local Visual = S.Features and S.Features.combat_sac_highlight or nil -- 拆分后的契约各自检查真实实现，不用职责 Feature 代理视觉能力。

local function Fail(message) return false, tostring(message or "team_tools_acceptance_failed") end

-- 运行时只做只读诊断；完整序列测试仅离线执行。
G:RegisterSequenceCase("v3_combat_team_tools_role_contract", function()
    if type(F) ~= "table" then return Fail("implementation_not_registered") end
    -- v3 才包含独立 Event owner/roster lease 与关→开重建观察，
    -- 所以自动职责契约版本不能只看目录版本 —— 这里逐条照搬旧下限。
    if (tonumber(F.TeamRoleContractVersion) or 0) < 2 then return Fail("team_role_contract_version") end
    if (tonumber(F.AutoRoleContractVersion) or 0) < 3 then return Fail("auto_role_contract_version") end
    if (tonumber(F.AutoRoleCatalogContractVersion) or 0) < 2 then return Fail("auto_role_catalog_contract_version") end
    if (tonumber(F.AutoRoleRosterLeaseContractVersion) or 0) < 1 then return Fail("auto_role_roster_lease_contract_version") end
    if (tonumber(F.AutoRoleDefaultOnContractVersion) or 0) < 1 then return Fail("auto_role_default_on_contract_version") end -- 默认职责语义只归职责 Feature，视觉门禁不再依赖另一实现。
    if type(F.Commands) ~= "table" or type(F.Commands.SetRole) ~= "function" then return Fail("set_role_command") end
    return true
end, { runtime = true })

G:RegisterSequenceCase("v3_combat_team_tools_visual_marker_contract", function()
    if type(Visual) ~= "table" then return Fail("visual_implementation_not_registered") end
    -- visual v2 固化“牺牲之舞 fresh default=on + schema1 旧关闭语义迁移”；
    -- marker 快照沿用串行写入/回读确认契约；sac 要求 schema2/default-on Store；
    -- 自动职责 fresh Store 默认开启，但旧用户显式 false 必须继续由 Store 持久化（本文件只查声明）。
    if (tonumber(Visual.TeamVisualContractVersion) or 0) < 2 then return Fail("team_visual_contract_version") end
    if (tonumber(Visual.TeamMarkerSnapshotContractVersion) or 0) < 1 then return Fail("team_marker_snapshot_contract_version") end
    if (tonumber(Visual.TeamSacContractVersion) or 0) < 2 then return Fail("team_sac_contract_version") end
    if type(Visual.Commands) ~= "table" then return Fail("commands_table_missing") end
    for _, name in ipairs({ "SetSacHighlightEnabled", "SaveRaidMarkers", "RestoreRaidMarkers",
        "ClearSavedRaidMarkers" }) do
        if type(Visual.Commands[name]) ~= "function" then return Fail("team_visual_command:" .. name) end
    end
    return true
end, { runtime = true })

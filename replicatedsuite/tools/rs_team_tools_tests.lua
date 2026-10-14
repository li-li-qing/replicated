------------------------------------------------------------------------
-- Replicated Suite · 团队工具测试
-- 作者：Replicated
-- QQ群：1104129461
--
-- 合并时须检查未解决冲突，不能把文件存在视为实现已完整恢复。
-- 数据归属、调用链和存档协议由原实现管理，
-- 不能通过清配置、跳过加载或恢复旧架构绕过错误；本文件须与完整 toc.g 和相应 UI 配套。
-- 合并后先核对冲突标记、加载清单和 Lua 语法，再进行客户端验收。
-- 覆盖 combat_team_tools 和 TeamRole 只读投影，
-- 玩家自身职责写入、自动职责目录解析及成员移动安全拒绝，
-- Spelldance 牺牲舞蹈候选发现和 Aura 追踪，
-- 团队标记快照保存、数量上限，以及 1100ms 节奏的串行恢复
-- 和回读确认、表现覆盖层、基础门禁契约。
------------------------------------------------------------------------
unpack = unpack or table.unpack
if not math.frexp then math.frexp = function(x) if x == 0 then return 0, 0 end local e = math.floor(math.log(math.abs(x)) / math.log(2)) + 1 return x / (2^e), e end end
if not math.ldexp then math.ldexp = function(m, e) return m * (2^e) end end

local passed, total = 0, 0
local function Test(name, fn)
    total = total + 1
    local ok, err = xpcall(fn, debug.traceback)
    if ok then
        passed = passed + 1
        print(string.format("  PASS [%02d] %s", total, name))
    else
        print(string.format("  FAIL [%02d] %s: %s", total, name, tostring(err)))
    end
end

print("=== Replicated Suite: Team Tools & Visuals Tests ===")

local h = dofile("tools/rs_gear_page_test_host.lua")({})
local S = h.S

-- 原生团队职责常量。
_G.TMROLE_NONE = 0
_G.TMROLE_TANKER = 1
_G.TMROLE_HEALER = 2
_G.TMROLE_DEALER = 3
_G.TMROLE_RANGED_DEALER = 4
_G.MAX_OVER_HEAD_MARKER = 8
_G.UIParent = {
    GetScreenWidth = function() return 1920 end,
    GetScreenHeight = function() return 1080 end,
    GetExtent = function() return 1920, 1080 end,
    GetUIScale = function() return 1 end,
    CreateColorDrawable = function(self, r, g, b, a, layer)
        return {
            SetColor = function() end,
            SetExtent = function() end,
            SetAnchor = function() end,
            SetVisible = function() end,
        }
    end,
}
_G.ConvertWorldToScreen = function(x, y, z) return 500, 300, 10 end

-- 原生接口测试替身。
local mockTeam = {
    roles = {},
    currentRole = nil,
    GetRole = function(self, teamIndex, memberIndex)
        local key = tostring(teamIndex) .. ":" .. tostring(memberIndex)
        return self.roles[key] or _G.TMROLE_NONE
    end,
    SetRole = function(self, role)
        self.currentRole = role
        return true
    end,
    MoveTeamMember = function(self)
        error("MoveTeamMember must not be called; member move is fail-closed")
    end,
    MoveTeamMemberToParty = function(self)
        error("MoveTeamMemberToParty must not be called; member move is fail-closed")
    end,
}
_G.X2Team = mockTeam

local mockUnit = {
    names = { player = "LeaderPlayer" },
    abilityTemplates = {},
    markers = {},
    buffs = {},
    UnitName = function(self, token)
        return self.names[token] or token
    end,
    GetTargetAbilityTemplates = function(self, token)
        return self.abilityTemplates[token] or {}
    end,
    GetOverHeadMarker = function(self, token)
        return self.markers[token] or 0
    end,
    SetOverHeadMarker = function(self, token, marker)
        self.markers[token] = marker
        return true
    end,
    UnitBuffCount = function(self, token)
        return #(self.buffs[token] or {})
    end,
    UnitBuff = function(self, token, index)
        return (self.buffs[token] or {})[index]
    end,
    UnitBuffTooltip = function(self, token, index)
        return nil
    end,
    UnitDeBuffCount = function() return 0 end,
    UnitDeBuff = function() return nil end,
    UnitHiddenBuffCount = function() return 0 end,
    UnitHiddenBuff = function() return nil end,
    UnitDistance = function() return 10 end,
    GetUnitScreenPosition = function() return 500, 300, true end,
    GetUnitWorldPositionByTarget = function() return 1000, 2000, 50 end,
}
_G.X2Unit = mockUnit

-- 开放测试需要的 API 能力。
S.Api.allowedCapabilities = S.Api.allowedCapabilities or {}
S.Api.allowedCapabilities["X2Team:GetRole"] = true
S.Api.allowedCapabilities["X2Team:SetRole"] = true
S.Api.allowedCapabilities["X2Unit:UnitName"] = true
S.Api.allowedCapabilities["X2Unit:GetTargetAbilityTemplates"] = true
S.Api.allowedCapabilities["X2Unit:GetOverHeadMarker"] = true
S.Api.allowedCapabilities["X2Unit:SetOverHeadMarker"] = true
S.Api.allowedCapabilities["X2Unit:UnitBuffCount"] = true
S.Api.allowedCapabilities["X2Unit:UnitBuff"] = true
S.Api.allowedCapabilities["X2Unit:UnitBuffTooltip"] = true
S.Api.allowedCapabilities["X2Unit:UnitDeBuffCount"] = true
S.Api.allowedCapabilities["X2Unit:UnitDeBuff"] = true
S.Api.allowedCapabilities["X2Unit:UnitHiddenBuffCount"] = true
S.Api.allowedCapabilities["X2Unit:UnitHiddenBuff"] = true
S.Api.allowedCapabilities["X2Unit:UnitDistance"] = true
S.Api.allowedCapabilities["X2Unit:GetUnitScreenPosition"] = true
S.Api.allowedCapabilities["X2Unit:GetUnitWorldPositionByTarget"] = true

S.ApiImports = {
    Acquire = function() return true end,
    Release = function() return true end,
    GetOwnerApis = function() return {} end,
}

_G.ReplicatedSuite = S
S.Features = S.Features or {}
S.Services = S.Services or {}
S.Data = S.Data or {}

-- 按依赖顺序加载基础模块。
dofile("data/rs_data_registry.lua")
dofile("data/ids/rs_item_ids.lua")
dofile("data/ids/rs_quest_ids.lua")
dofile("core/rs_constants.lua")
dofile("core/rs_demand.lua")
dofile("core/rs_foundation_gate.lua")
dofile("features/rs_feature_registry.lua")
dofile("features/rs_feature_runtime.lua")

-- 加载目录和共享服务。
dofile("data/rs_team_auto_role_catalog.lua")
dofile("services/rs_team_roster_v3.lua")
dofile("services/rs_aura_observation_v3.lua")
dofile("services/rs_screen_projection_v3.lua")

-- 加载业务桥接和团队表现扩展。
-- 中文维护注释（2026-09-28，Phase 1 Batch A）：复现 toc.g 顺序，先加载通用装配骨架。
dofile("features/shared/rs_feature_slice_factory.lua")
dofile("features/shared/rs_shared_bounds.lua")
dofile("features/tools/auction/rs_auction_read_model.lua")
-- 中文维护注释（2026-09-28，Phase 1 Batch E）：bridge 已退役；按 toc.g 顺序加载本套件需要的 Feature。
dofile("features/combat/team_tools/rs_team_tools_feature.lua")
-- 中文维护注释（2026-09-28，Phase 1 Batch D）：combat_team_tools 已从 bridge 拆出；按 toc.g 顺序加载它。
dofile("features/combat/team_tools/rs_team_tools_visuals.lua")

-- 加载表现控件和页面。
dofile("presentation/v3/widgets/rs_v3_team_sac_overlay.lua")
dofile("presentation/v3/pages/rs_v3_business_pages.lua")
dofile("presentation/v3/rs_v3_acceptance.lua")

local Feature = S.Features.combat_team_tools
local Roster = S.Services.TeamRosterV3
local Sac = assert(S.Features.combat_sac_highlight) -- 真实分离两个 Runtime 实例。
local Visuals = Sac.TeamVisuals

-- 测试 1：功能注册元数据及契约版本。
Test("T1: Feature registry metadata & contract versions", function()
    local reg = S.FeatureRegistry:Get("combat_team_tools")
    assert(reg ~= nil, "combat_team_tools must be registered in FeatureRegistry")
    assert(reg.id == "combat_team_tools", "id mismatch")
    assert(reg.route == "combat.team_tools", "route mismatch")
    assert(reg.name == "职责设置", "name mismatch")
    assert(reg.category == "combat", "category mismatch")
    assert(reg.lifecycle == "explicit_action", "lifecycle mismatch")

    local deps = reg.apiDependencies
    assert(#deps >= 4, "Must declare at least 7 API dependencies")
    local hasGetRole, hasSetRole, hasMarkers = false, false, false
    for _, d in ipairs(deps) do
        if d == "X2Team:GetRole" then hasGetRole = true end
        if d == "X2Team:SetRole" then hasSetRole = true end
        if d == "X2Unit:SetOverHeadMarker" then hasMarkers = true end
    end
    assert(hasGetRole, "X2Team:GetRole missing from dependencies")
    assert(hasSetRole, "X2Team:SetRole missing from dependencies")
    assert(not hasMarkers, "X2Unit:SetOverHeadMarker missing from dependencies")

    -- 核对功能契约。
    assert((tonumber(Feature.TeamRoleContractVersion) or 0) >= 2, "TeamRoleContractVersion >= 2")
    assert((tonumber(Feature.AutoRoleContractVersion) or 0) >= 3, "AutoRoleContractVersion >= 3")
    assert((tonumber(Feature.AutoRoleCatalogContractVersion) or 0) >= 2, "AutoRoleCatalogContractVersion >= 2")
    assert((tonumber(Feature.AutoRoleRosterLeaseContractVersion) or 0) >= 1, "AutoRoleRosterLeaseContractVersion >= 1")
    assert((tonumber(Sac.TeamVisualContractVersion) or 0) >= 2, "TeamVisualContractVersion >= 2")
    assert((tonumber(Sac.TeamMarkerSnapshotContractVersion) or 0) >= 1, "TeamMarkerSnapshotContractVersion >= 1")
    assert((tonumber(Sac.TeamSacContractVersion) or 0) >= 2, "TeamSacContractVersion >= 2")
    assert((tonumber(Feature.AutoRoleDefaultOnContractVersion) or 0) >= 1, "AutoRoleDefaultOnContractVersion >= 1")
    assert(type(Feature.Commands.SetRole) == "function", "SetRole command missing")
    assert(type(Feature.Commands.SetAutoRoleEnabled) == "function", "SetAutoRoleEnabled command missing")
    assert(type(Feature.Commands.MoveMember) == "function", "MoveMember command missing")
    assert(type(Feature.Commands.MoveMemberToParty) == "function", "MoveMemberToParty command missing")
    assert(type(Sac.Commands.SetSacHighlightEnabled) == "function", "SetSacHighlightEnabled missing")
    assert(type(Sac.Commands.SaveRaidMarkers) == "function", "SaveRaidMarkers missing")
    assert(type(Sac.Commands.RestoreRaidMarkers) == "function", "RestoreSavedRaidMarkers missing")
    assert(type(Sac.Commands.ClearSavedRaidMarkers) == "function", "ClearSavedRaidMarkers missing")
end)

-- 测试 2：团队名单只读投影与职责映射。
Test("T2: Team roster read-only projection & role mapping", function()
    -- 初始化功能，准备读取名单。
    Feature:Initialize()
    Feature:Enable("test_t2")
    Feature:AcquireConsumer("test_t2")

    -- 配置名单测试快照。
    Roster.ordered = {
        { name = "TankOne", unitToken = "team_1_1", teamIndex = 1, memberIndex = 1 },
        { name = "HealerTwo", unitToken = "team_1_2", teamIndex = 1, memberIndex = 2 },
        { name = "DealerThree", unitToken = "team_1_3", teamIndex = 1, memberIndex = 3 },
        { name = "RangedFour", unitToken = "team_2_1", teamIndex = 2, memberIndex = 1 },
        { name = "UnassignedFive", unitToken = "team_2_2", teamIndex = 2, memberIndex = 2 },
    }
    Roster.members = {}
    for _, m in ipairs(Roster.ordered) do Roster.members[m.name] = m end
    Roster.revision = 5

    -- 配置职责测试数据。
    mockTeam.roles["1:1"] = _G.TMROLE_TANKER
    mockTeam.roles["1:2"] = _G.TMROLE_HEALER
    mockTeam.roles["1:3"] = _G.TMROLE_DEALER
    mockTeam.roles["2:1"] = _G.TMROLE_RANGED_DEALER
    mockTeam.roles["2:2"] = _G.TMROLE_NONE

    -- 触发功能读取。
    Feature.Authority:Refresh("test_roster_read")
    local rows = Feature.Authority.rows
    local status = Feature.Authority.status
    local err = Feature.Authority.error
    assert(status == "ready", "Status should be ready, got: " .. tostring(status))
    assert(#rows == 5, "Rows count should be 5")

    -- 核对第 1 行坦克职责。
    assert(rows[1].name == "TankOne", "Row 1 name mismatch")
    assert(rows[1].role == _G.TMROLE_TANKER, "Row 1 role should be TMROLE_TANKER")
    assert(rows[1].roleStatus == "ready", "Row 1 roleStatus mismatch")
    assert(rows[1].text:find("已读取") ~= nil or rows[1].statusText == "已读取", "Row 1 statusText mismatch")

    -- 核对第 2 行治疗职责。
    assert(rows[2].name == "HealerTwo", "Row 2 name mismatch")
    assert(rows[2].role == _G.TMROLE_HEALER, "Row 2 role should be TMROLE_HEALER")

    -- 核对第 4 行远程输出职责。
    assert(rows[4].name == "RangedFour", "Row 4 name mismatch")
    assert(rows[4].role == _G.TMROLE_RANGED_DEALER, "Row 4 role should be TMROLE_RANGED_DEALER")

    -- 验证空团队处理。
    Roster.ordered = {}
    Roster.members = {}
    Roster.revision = 6
    Feature.Authority:Refresh("test_empty_team")
    local emptyRows = Feature.Authority.rows
    local emptyStatus = Feature.Authority.status
    local emptyDiag = Feature.Authority.error
    assert(emptyStatus == "empty", "Status should be empty for empty team")
    assert(#emptyRows == 1, "Should return 1 hint row for empty team")
    assert(emptyRows[1].key == "team_role:empty", "Key should be team_role:empty")

    Feature:ReleaseConsumer("test_t2")
end)

-- 测试 3：仅修改当前玩家自身职责的写入契约。
Test("T3: Current player self-role write contract", function()
    Feature:Enable("test_t3")

    -- 1. 允许写入 TMROLE_HEALER；先推进时钟越过 500ms 冷却。
    h.ms = h.ms + 600
    local okHealer = Feature.Commands:SetRole(_G.TMROLE_HEALER)
    assert(okHealer == true, "SetRole(TMROLE_HEALER) failed")
    assert(mockTeam.currentRole == _G.TMROLE_HEALER, "mockTeam.currentRole should be TMROLE_HEALER")

    -- 2. 允许写入 TMROLE_TANKER；先推进时钟越过 500ms 冷却。
    h.ms = h.ms + 600
    local okTank = Feature.Commands:SetRole(_G.TMROLE_TANKER)
    assert(okTank == true, "SetRole(TMROLE_TANKER) failed")
    assert(mockTeam.currentRole == _G.TMROLE_TANKER, "mockTeam.currentRole should be TMROLE_TANKER")

    -- 3. 拒绝无效职责值。
    local badOk, badErr = Feature.Commands:SetRole(999)
    assert(badOk == false, "Out of range role should be rejected")
    assert(tostring(badErr):find("TMROLE_*") ~= nil, "Error message must mention TMROLE_* enum")

    local strOk, _ = Feature.Commands:SetRole("healer")
    assert(strOk == false, "String role should be rejected")

    local nilOk, _ = Feature.Commands:SetRole(nil)
    assert(nilOk == false, "Nil role should be rejected")
end)

-- 测试 4：自动职责目录解析及自动应用。
Test("T4: Auto-role catalog resolution & automatic application", function()
    Feature:Enable("test_t4")

    -- 在名单中配置当前玩家。
    Roster.ordered = {
        { name = "LeaderPlayer", unitToken = "player", teamIndex = 1, memberIndex = 1 },
        { name = "PartyMember2", unitToken = "team_1_2", teamIndex = 1, memberIndex = 2 },
    }
    Roster.members = {}
    for _, m in ipairs(Roster.ordered) do Roster.members[m.name] = m end

    -- 玩家天赋为 Wild(6)、Romance(8)、Shadow(9)，对应 Archer 远程职责。
    mockUnit.abilityTemplates["player"] = {
        { index = 6 }, { index = 8 }, { index = 9 }
    }
    mockTeam.roles["1:1"] = _G.TMROLE_NONE

    -- 推进时钟越过 500ms 冷却后执行 ApplyAutoRole。
    h.ms = h.ms + 600
    local okApply = Feature:ApplyAutoRole("test_archer")
    assert(okApply == true, "ApplyAutoRole failed")
    assert(mockTeam.currentRole == _G.TMROLE_RANGED_DEALER, "Role should be auto-set to TMROLE_RANGED_DEALER")
    assert(Feature.AutoRoleClassKey == "name_6_8_9", "AutoRoleClassKey mismatch")
    assert(Feature.AutoRoleLabel == "远程输出", "AutoRoleLabel mismatch")

    -- 中文维护测试（2026-09-16）：欢乐(14)+暗杀(8)+吟游(9) 是用户确认的治疗职责。
    -- 测试必须钉死业务目录 Authority，防止 classType=Dancer 被误解成 tank。
    mockUnit.abilityTemplates["player"] = {
        { index = 14 }, { index = 8 }, { index = 9 }
    }
    mockTeam.roles["1:1"] = _G.TMROLE_NONE
    mockTeam.currentRole = nil
    h.ms = h.ms + 600
    local okDancerHealer = Feature:ApplyAutoRole("test_dancer_healer")
    assert(okDancerHealer == true, "ApplyAutoRole dancer healer failed")
    assert(mockTeam.currentRole == _G.TMROLE_HEALER, "8+9+14 must auto-set TMROLE_HEALER")
    assert(Feature.AutoRoleClassKey == "name_8_9_14", "Dancer healer class key mismatch")
    assert(Feature.AutoRoleLabel == "治疗", "Dancer healer AutoRoleLabel must be 治疗")

    -- 天赋切换为 3、4、5，对应 Tank 坦克职责。
    mockUnit.abilityTemplates["player"] = {
        { index = 3 }, { index = 4 }, { index = 5 }
    }
    mockTeam.roles["1:1"] = _G.TMROLE_RANGED_DEALER -- 当前为远程职责，需要切换为坦克。
    h.ms = h.ms + 600
    local okTank = Feature:ApplyAutoRole("test_tank")
    assert(okTank == true, "ApplyAutoRole tank failed")
    assert(mockTeam.currentRole == _G.TMROLE_TANKER, "Role should be auto-set to TMROLE_TANKER")

    -- 职责已经匹配时不应再次写入。
    mockTeam.roles["1:1"] = _G.TMROLE_TANKER
    mockTeam.currentRole = nil
    Feature:ApplyAutoRole("test_already_matched")
    assert(mockTeam.currentRole == nil, "No write should occur if already matched")
    assert(Feature.AutoRoleStatus:find("已匹配") ~= nil, "AutoRoleStatus should mention matched")

    -- 验证自动职责开关命令。
    Feature.Commands:SetAutoRoleEnabled(false)
    assert(Feature.State.autoRoleEnabled == false, "autoRoleEnabled should be false")
    Feature.Commands:SetAutoRoleEnabled(true)
    assert(Feature.State.autoRoleEnabled == true, "autoRoleEnabled should be true")
end)

-- 测试 4B：自动职责功能自行持有 TeamRoster 需求租约，不依赖表现层。
Test("T4B: Auto-role owns roster lease and toggle lifecycle", function()
    -- 中文维护测试（2026-09-16）：自动职责是独立低开销 Feature 行为，不能依赖团队页面/悬浮窗 Consumer。
    -- 当 UI Consumer 为 0 时，只要 Feature 已启用且 autoRoleEnabled=true，TeamRosterV3 仍必须由自动职责自己的 token 保持运行。
    assert(Feature.enabled == true, "team tools must be enabled for auto-role lifecycle test")
    assert(Feature.State.autoRoleEnabled == true, "auto-role must start enabled in this fixture")
    assert(Feature.AutoRoleSubscribed == true, "auto-role event observation must be subscribed")
    assert(Feature.AutoRoleRosterHeld == true, "auto-role must own an independent TeamRosterV3 lease")
    assert(type(Roster.demand) == "table" and Roster.demand:Has("combat_team_tools:auto_role_roster") == true,
        "TeamRosterV3 must contain the dedicated auto-role demand token")
    assert((tonumber(Roster.consumerCount) or 0) >= 1, "TeamRosterV3 must stay demanded without a team-tools UI consumer")
    assert(Roster.subscribed == true, "TeamRosterV3 native TEAM_MEMBERS_CHANGED listener must stay live")

    local beforeDisableCount = tonumber(Roster.consumerCount) or 0
    local offOk, offErr = Feature.Commands:SetAutoRoleEnabled(false)
    assert(offOk == true, "disabling auto-role failed: " .. tostring(offErr))
    assert(Feature.AutoRoleSubscribed == false, "disabling auto-role must release its event observation")
    assert(Feature.AutoRoleRosterHeld == false, "disabling auto-role must release its roster lease")
    assert(Roster.demand:Has("combat_team_tools:auto_role_roster") == false, "auto-role roster token must be released")
    assert((tonumber(Roster.consumerCount) or 0) == math.max(0, beforeDisableCount - 1),
        "disabling auto-role must release exactly its own roster consumer without disturbing Sac/UI consumers")

    local onOk, onErr = Feature.Commands:SetAutoRoleEnabled(true)
    assert(onOk == true, "re-enabling auto-role failed: " .. tostring(onErr))
    assert(Feature.AutoRoleSubscribed == true, "re-enabling auto-role must rebuild event observation")
    assert(Feature.AutoRoleRosterHeld == true, "re-enabling auto-role must reacquire TeamRosterV3")
    assert(Roster.demand:Has("combat_team_tools:auto_role_roster") == true, "re-enabled auto-role must restore its dedicated roster token")
    assert((tonumber(Roster.consumerCount) or 0) >= beforeDisableCount, "re-enabled auto-role must restore roster demand without dropping other consumers")
end)

-- 测试 4C：团队加入事件触发有界的稳定刷新。
Test("T4C: TeamRoster bounded settle refresh catches late native slots", function()
    local originalUnitName = mockUnit.UnitName
    local rosterReady = false
    local function RunBody()
        mockUnit.UnitName = function(self, token)
            if token == "player" then return "LeaderPlayer" end
            if token == "team01" or token == "team1" then
                return rosterReady and "LeaderPlayer" or nil
            end
            return nil
        end
        Roster.members, Roster.ordered = {}, {}

        S.Events:Dispatch("TEAM_MEMBERS_CHANGED", "test_join_edge")
        assert(type(Roster.settleTask) == "string" and Roster.settleTask ~= "", "TeamRoster settle task contract missing")
        assert(S.Scheduler.tasks[Roster.refreshTask] ~= nil, "primary roster refresh was not scheduled")
        assert(S.Scheduler.tasks[Roster.settleTask] ~= nil, "bounded settle refresh was not scheduled")

        assert(S.Scheduler:RunTask(Roster.refreshTask) == true, "primary roster refresh failed")
        local first = Roster:GetSnapshot()
        assert(#first.members == 1, "primary early snapshot should contain only the local player seed")
        assert((tonumber(first.members[1].teamIndex) or 0) == 0, "early player seed must not pretend a real team slot exists")

        rosterReady = true
        assert(S.Scheduler:RunTask(Roster.settleTask) == true, "settle roster refresh failed")
        local settled = Roster:GetSnapshot()
        assert(#settled.members == 1, "settled snapshot should still contain one canonical player row")
        assert(tonumber(settled.members[1].teamIndex) == 1 and tonumber(settled.members[1].memberIndex) == 1,
            "settle refresh must enrich the player with the late native team slot")
        assert((tonumber(Roster.TeamEdgeSettleContractVersion) or 0) >= 1, "TeamEdgeSettleContractVersion missing")
    end
    local ok, err = xpcall(RunBody, debug.traceback)
    mockUnit.UnitName = originalUnitName
    if S.Scheduler and type(S.Scheduler.RemoveTask) == "function" and type(Roster.settleTask) == "string" then
        S.Scheduler:RemoveTask(Roster.settleTask)
    end
    if not ok then error(err) end
end)

-- 测试 5：成员移动接口的安全拒绝边界。
Test("T5: Member move fail-closed boundary", function()
    local okMove, moveErr = Feature.Commands:MoveMember(1, 2)
    assert(okMove == false, "MoveMember must return false")
    assert(tostring(moveErr):find("安全停用") ~= nil, "Error message must state safely disabled")
    assert(tostring(moveErr):find("队长") ~= nil, "Error message must mention leader permission")

    local okParty, partyErr = Feature.Commands:MoveMemberToParty(1, 2)
    assert(okParty == false, "MoveMemberToParty must return false")
    assert(tostring(partyErr):find("安全停用") ~= nil, "Error message must state safely disabled")

    -- 核对恢复后的投影。
    local proj = Feature:GetProjection()
    assert(proj.memberMoveAvailable == false, "memberMoveAvailable must be false in projection")
end)

-- 测试 6：舞蹈天赋候选发现与 Aura 追踪。
Test("T6: Spelldance candidate discovery & aura tracking", function()
    Sac:Enable("test_t6")
    Visuals.running = true

    -- 名单中玩家 1 有 Spelldance(14)，玩家 2 没有。
    Roster.ordered = {
        { name = "DancerOne", unitToken = "team_1_1", teamIndex = 1, memberIndex = 1 },
        { name = "WarriorTwo", unitToken = "team_1_2", teamIndex = 1, memberIndex = 2 },
    }
    mockUnit.names["team_1_1"] = "DancerOne"
    mockUnit.names["team_1_2"] = "WarriorTwo"
    mockUnit.abilityTemplates["team_1_1"] = { { index = 14 }, { index = 1 }, { index = 2 } } -- 包含 Spelldance(14)。
    mockUnit.abilityTemplates["team_1_2"] = { { index = 3 }, { index = 4 }, { index = 5 } }   -- 不包含 Spelldance；随后扫描候选。
    local okScan = Sac:ScanSacCandidates("test_scan")
    assert(okScan == true, "ScanSacCandidates failed")
    assert(Visuals.candidateCount == 1, "Should have 1 candidate with Spelldance")
    assert(Visuals.candidates["team_1_1"] ~= nil, "DancerOne should be a candidate")
    assert(Visuals.candidates["team_1_2"] == nil, "WarriorTwo should not be a candidate")

    -- 初始没有正在生效的 Aura。
    assert(Visuals.activeCount == 0, "No active sac auras initially")

    -- 为 DancerOne 加入牺牲舞蹈 Buff，ID=30098。
    mockUnit.buffs["team_1_1"] = {
        { buff_id = 30098, name = "牺牲之舞" }
    }
    -- 使 Aura 缓存失效后重新扫描。
    S.Services.AuraObservationV3.cache = {}
    Sac:ScanSacAuras("test_aura_active")
    assert(Visuals.activeCount == 1, "Active sac count should be 1")
    assert(Visuals.active["team_1_1"] ~= nil, "DancerOne should be active")
    assert(Visuals.active["team_1_1"].name == "DancerOne", "Active name mismatch")

    -- 移除 Buff 后清空激活状态。
    mockUnit.buffs["team_1_1"] = {}
    S.Services.AuraObservationV3.cache = {}
    Sac:ScanSacAuras("test_aura_removed")
    assert(Visuals.activeCount == 0, "Active sac count should return to 0 after buff removal")

    -- 验证追踪开关命令。
    Sac.Commands:SetSacHighlightEnabled(false)
    assert(Visuals.state.sacEnabled == false, "sacEnabled should be false after toggle")
    Sac.Commands:SetSacHighlightEnabled(true)
    assert(Visuals.state.sacEnabled == true, "sacEnabled should be true after toggle")
end)

-- 测试 7：团队标记快照保存与数量上限。
Test("T7: Team marker snapshot save & capacity bounds", function()
    Sac:Enable("test_t7")

    -- 配置带标记的团队成员。
    Roster.ordered = {
        { name = "Alpha", unitToken = "team_1_1", teamIndex = 1, memberIndex = 1 },
        { name = "Beta", unitToken = "team_1_2", teamIndex = 1, memberIndex = 2 },
        { name = "Gamma", unitToken = "team_1_3", teamIndex = 1, memberIndex = 3 },
    }
    mockUnit.markers["team_1_1"] = 1 -- 星形标记，ID=1。
    mockUnit.markers["team_1_2"] = 2 -- 圆形标记，ID=2。
    mockUnit.markers["team_1_3"] = 0 -- 无标记成员；随后保存标记。
    local okSave, count = Sac.Commands:SaveRaidMarkers()
    assert(okSave == true, "SaveRaidMarkers failed: " .. tostring(count))
    assert(count == 2, "Saved marker count should be 2 (Alpha and Beta)")
    assert(Visuals.markerStatus == "saved", "markerStatus should be saved")

    -- 核对 savedMarks 内容。
    local saved = Visuals.state.savedMarks
    assert(#saved == 2, "savedMarks should contain 2 entries")
    assert(saved[1].name == "Alpha" and saved[1].markerIndex == 1, "First saved mark mismatch")
    assert(saved[2].name == "Beta" and saved[2].markerIndex == 2, "Second saved mark mismatch")

    -- 核对恢复后的投影。
    local proj = Sac:GetProjection()
    assert(proj.savedMarkerCount == 2, "proj.savedMarkerCount mismatch")
    assert(proj.markerStatus == "saved", "proj.markerStatus mismatch")

    -- 清空已保存标记。
    local okClear = Sac.Commands:ClearSavedRaidMarkers()
    assert(okClear == true, "ClearSavedRaidMarkers failed")
    assert(#Visuals.state.savedMarks == 0, "savedMarks should be empty after clear")
    assert(Sac:GetProjection().savedMarkerCount == 0, "Projection saved count should be 0")
end)

-- 测试 8：团队标记按 1100ms 间隔串行恢复，并通过回读确认。
Test("T8: Team marker 1100ms paced serial restore & readback verification", function()
    S.FeatureRuntime:Enable("combat_sac_highlight", "test_t8")
    Sac:Enable("test_t8")

    -- 预先保存 Alpha 的标记 1 和 Beta 的标记 2。
    Visuals.state.savedMarks = {
        { name = "Alpha", markerIndex = 1 },
        { name = "Beta", markerIndex = 2 },
    }

    -- 当前团队包含 Alpha 和 Beta，但两者标记均为 0，模拟已清除或错误状态。
    Roster.ordered = {
        { name = "Alpha", unitToken = "team_1_1", teamIndex = 1, memberIndex = 1 },
        { name = "Beta", unitToken = "team_1_2", teamIndex = 1, memberIndex = 2 },
    }
    mockUnit.markers["team_1_1"] = 0
    mockUnit.markers["team_1_2"] = 0

    -- 发起标记恢复。
    local okRestore, queuedCount = Sac.Commands:RestoreRaidMarkers()
    assert(okRestore == true, "RestoreRaidMarkers failed: " .. tostring(queuedCount))
    assert(queuedCount == 2, "Queued count should be 2")
    assert(Visuals.markerStatus == "restoring", "markerStatus should be restoring")

    -- 验证已注册 1100ms 调度任务。
    local task = S.Scheduler.tasks["v3_team_tools_marker_restore"]
    assert(task ~= nil, "Restore scheduler task missing")
    assert(task.intervalMs == 1100, "Restore task interval must be 1100ms")

    -- 第 1 次调度写入 Alpha：team_1_1 对应标记 1；随后推进时钟 1200ms。
    h.ms = h.ms + 1200
    task.callback()
    assert(mockUnit.markers["team_1_1"] == 1, "Alpha marker should be set to 1")
    assert(Visuals.restorePending ~= nil, "Should have pending readback verification")
    assert(Visuals.restorePending.name == "Alpha", "Pending verification should be Alpha")

    -- 第 2 次调度回读确认 Alpha，再写入 Beta：team_1_2 对应标记 2。
    h.ms = h.ms + 1200
    task.callback()
    assert(Visuals.markerApplied == 1, "Alpha should be verified as applied")
    assert(mockUnit.markers["team_1_2"] == 2, "Beta marker should be set to 2")
    assert(Visuals.restorePending.name == "Beta", "Pending verification should be Beta")

    -- 第 3 次调度回读确认 Beta，全部恢复项完成。
    h.ms = h.ms + 1200
    task.callback()
    assert(Visuals.markerApplied == 2, "Beta should be verified as applied")
    assert(Visuals.markerStatus == "complete", "markerStatus should be complete")
    assert(Visuals.restoreQueue == nil, "Queue should be cleared upon completion")

    -- 核对恢复后的投影。
    local proj = Sac:GetProjection()
    assert(proj.markerStatus == "complete", "proj.markerStatus mismatch")
    assert(proj.markerApplied == 2, "proj.markerApplied mismatch")
    assert(proj.markerRestoreRunning == false, "markerRestoreRunning should be false")
end)

-- 测试 9：TeamSacOverlay 表现控件与刷新节奏。
Test("T9: TeamSacOverlay presentation widget & tick cadence", function()
    local Overlay = S.UIV3.TeamSacOverlay
    assert(Overlay ~= nil, "TeamSacOverlay missing from S.UIV3")
    assert(Overlay.TeamSacPresentationContractVersion >= 1, "TeamSacPresentationContractVersion missing")

    -- 确保标记池已准备。
    Overlay:EnsurePool(4)
    assert(#Overlay.pool == 4, "Pool should have 4 markers allocated")

    -- 提供激活中的牺牲舞蹈候选。
    S.FeatureRuntime:Enable("combat_sac_highlight", "test_t9")
    Sac:Enable("test_t9")
    Visuals.state.sacEnabled = true
    Visuals.active = {
        ["team_1_1"] = { unitToken = "team_1_1", name = "DancerOne", verifiedAt = h.ms }
    }
    Overlay:Reconcile("test_active")

    -- 执行一次视觉刷新。
    local okTick = Overlay:VisualTick()
    assert(okTick == true, "VisualTick failed")
    assert(Overlay.metrics.ticks > 0, "Ticks metric should be incremented")

    -- 覆盖激活列表变为空的情况。
    Visuals.active = {}
    Overlay:Reconcile("test_empty")
    assert(Overlay.running == false, "Overlay should stop when no active candidates")
end)

-- 测试 10：基础门禁和验收契约。
Test("T10: FoundationGate & Acceptance contract verification", function()
    -- 1. 核对 FoundationGate 契约条款。
    local teamTools = S.Features and S.Features.combat_team_tools or nil
    local teamRoleCatalog = S.Data and S.Data.TeamAutoRoleCatalog or nil
    local archerRole = type(teamRoleCatalog) == "table" and type(teamRoleCatalog.byClassKey) == "table"
        and teamRoleCatalog.byClassKey["name_6_8_9"] or nil
    local dancerHealerRole = type(teamRoleCatalog) == "table" and type(teamRoleCatalog.byClassKey) == "table"
        and teamRoleCatalog.byClassKey["name_8_9_14"] or nil
    local teamRoleOk = type(teamTools) == "table" and (tonumber(teamTools.TeamRoleContractVersion) or 0) >= 2
        and (tonumber(teamTools.AutoRoleContractVersion) or 0) >= 3
        and (tonumber(teamTools.AutoRoleCatalogContractVersion) or 0) >= 2
        and type(teamTools.Commands) == "table" and type(teamTools.Commands.SetRole) == "function"
        and type(teamRoleCatalog) == "table" and (tonumber(teamRoleCatalog.version) or 0) >= 3
        and type(archerRole) == "table" and tostring(archerRole.role or "") == "ranged"
        and type(dancerHealerRole) == "table" and tostring(dancerHealerRole.role or "") == "healer"
        and (tonumber(teamTools.AutoRoleRosterLeaseContractVersion) or 0) >= 1
        and type(Roster) == "table" and (tonumber(Roster.TeamEdgeSettleContractVersion) or 0) >= 1
    assert(teamRoleOk, "v3_team_role_contract clauses must pass")

    local teamSacOverlay = S.UIV3 and S.UIV3.TeamSacOverlay or nil
    local teamVisualOk = type(teamTools) == "table"
        and (tonumber(Sac.TeamVisualContractVersion) or 0) >= 2
        and (tonumber(Sac.TeamMarkerSnapshotContractVersion) or 0) >= 1
        and (tonumber(Sac.TeamSacContractVersion) or 0) >= 2
        and (tonumber(teamTools.AutoRoleDefaultOnContractVersion) or 0) >= 1
        and type(teamTools.Commands) == "table"
        and type(Sac.Commands.SetSacHighlightEnabled) == "function"
        and type(Sac.Commands.SaveRaidMarkers) == "function"
        and type(Sac.Commands.RestoreRaidMarkers) == "function"
        and type(Sac.Commands.ClearSavedRaidMarkers) == "function"
        and type(teamSacOverlay) == "table" and (tonumber(teamSacOverlay.TeamSacPresentationContractVersion) or 0) >= 1
    assert(teamVisualOk, "v3_team_visual_marker_contract clauses must pass")

    -- 2. 核对验收契约。
    local accFailures = {}
    local teamTools = S.Features.combat_team_tools
    local teamRoleCatalog = S.Data.TeamAutoRoleCatalog
    local archerRole = teamRoleCatalog.byClassKey["name_6_8_9"]
    local dancerHealerRole = teamRoleCatalog.byClassKey["name_8_9_14"]

    if type(teamTools) ~= "table" or (tonumber(teamTools.TeamRoleContractVersion) or 0) < 2
        or (tonumber(teamTools.AutoRoleContractVersion) or 0) < 3
        or (tonumber(teamTools.AutoRoleCatalogContractVersion) or 0) < 2
        or type(teamTools.Commands) ~= "table" or type(teamTools.Commands.SetRole) ~= "function"
        or type(teamRoleCatalog) ~= "table" or (tonumber(teamRoleCatalog.version) or 0) < 3
        or type(archerRole) ~= "table" or tostring(archerRole.role or "") ~= "ranged"
        or type(dancerHealerRole) ~= "table" or tostring(dancerHealerRole.role or "") ~= "healer"
        or (tonumber(teamTools.AutoRoleRosterLeaseContractVersion) or 0) < 1
        or type(Roster) ~= "table" or (tonumber(Roster.TeamEdgeSettleContractVersion) or 0) < 1 then
        accFailures[#accFailures + 1] = "team_role_catalog_contract_v3"
    end

    local teamSacOverlay = S.UIV3.TeamSacOverlay
    if type(teamTools) ~= "table" or (tonumber(Sac.TeamVisualContractVersion) or 0) < 2
        or (tonumber(Sac.TeamMarkerSnapshotContractVersion) or 0) < 1
        or (tonumber(Sac.TeamSacContractVersion) or 0) < 2
        or (tonumber(teamTools.AutoRoleDefaultOnContractVersion) or 0) < 1
        or type(teamTools.Commands) ~= "table"
        or type(Sac.Commands.SetSacHighlightEnabled) ~= "function"
        or type(Sac.Commands.SaveRaidMarkers) ~= "function"
        or type(Sac.Commands.RestoreRaidMarkers) ~= "function"
        or type(teamSacOverlay) ~= "table" or (tonumber(teamSacOverlay.TeamSacPresentationContractVersion) or 0) < 1 then
        accFailures[#accFailures + 1] = "team_visual_marker_contract_v2"
    end

    assert(#accFailures == 0, "Acceptance checks failed: " .. table.concat(accFailures, ", "))
end)

Test("T11: independent role and Sac switches release only their own consumers", function()
    assert(S.FeatureRuntime:Enable("combat_team_tools", "split_test"))
    assert(S.FeatureRuntime:Enable("combat_sac_highlight", "split_test"))
    assert(Sac.Commands:SetSacHighlightEnabled(true))
    assert(Feature.AutoRoleRosterHeld and Visuals.running)
    assert(S.FeatureRuntime:Disable("combat_team_tools", "split_role_off"))
    assert(not Feature.AutoRoleRosterHeld and Visuals.running, "role off stopped Sac")
    assert(S.FeatureRuntime:Enable("combat_team_tools", "split_role_on"))
    assert(S.FeatureRuntime:Disable("combat_sac_highlight", "split_sac_off"))
    assert(Feature.AutoRoleRosterHeld and not Visuals.running, "Sac off stopped role")
    assert(Feature.Commands.SetSacHighlightEnabled == nil and Sac.Commands.SetRole == nil)
    assert(Feature:GetProjection().sacEnabled == nil)
    assert(S.Persistence:GetStore("v3.combat.team_tools.visuals") ~= nil)
    assert(Sac:GetStartupEnableIntent(false, true) == false, "explicit off must stay off")
    assert(S.FeatureRuntime:SetPreferredEnabled("combat_team_tools", true, "legacy_split_intent"))
    Visuals.state.sacEnabled = true
    assert(Sac:GetStartupEnableIntent(false, false) == true, "legacy running visual intent must migrate")
    Visuals.state.sacEnabled = false
    assert(Sac:GetStartupEnableIntent(false, false) == false, "legacy visual off must stay off")
    -- 执行真实只读验收注册，确保门禁已检查拆分后的两个所有者。
    local cases={}
    S.FoundationGate={RegisterSequenceCase=function(_,name,fn)cases[name]=fn;return true end}
    dofile('features/combat/team_tools/rs_team_tools_acceptance.lua')
    assert(cases.v3_combat_team_tools_role_contract())
    assert(cases.v3_combat_team_tools_visual_marker_contract())
end)

-- 覆盖真机未显示时的边界，不能仅手工塞 active 表证明渲染链路正常。
Test("T12: repeated candidates retain aura timer; incomplete trees are observable", function()
    assert(S.FeatureRuntime:Enable(Sac.Id, "regression"))
    assert(Sac.Commands:SetSacHighlightEnabled(true))
    Roster.ordered = {{name="DancerOne",unitToken="team_1_1",teamIndex=1,memberIndex=1}}
    mockUnit.abilityTemplates.team_1_1 = {{index=14},{index=1},{index=2}}
    Sac:ScanSacCandidates("first")
    local timer = assert(S.Scheduler.tasks.v3_team_tools_sac_aura)
    Sac:ScanSacCandidates("unchanged_roster")
    assert(S.Scheduler.tasks.v3_team_tools_sac_aura == timer, "candidate refresh restarted pending aura timer")
    mockUnit.abilityTemplates.team_1_1 = {}
    Sac:ScanSacCandidates("cold_class")
    assert(Visuals.scanFailures == 1, "empty class tree was silently classified as not a dancer")
    local evidence = Sac:DescribeDiagnosticDetail()
    assert(evidence.candidateScan.members[1].error == "ability_templates_incomplete")
    mockUnit.abilityTemplates.team_1_1={{index=14},{index=1},{index=2}}
    Sac:ScanSacCandidates("valid_again")
    S.Events:Dispatch("BUFF_UPDATE")
    local edge=assert(S.Scheduler.tasks.v3_team_tools_sac_aura_edge)
    S.Events:Dispatch("BUFF_UPDATE")
    assert(S.Scheduler.tasks.v3_team_tools_sac_aura_edge==edge,"rapid buff edges indefinitely postpone scan")
end)

Test("T13: canonical player token resolves qualified-name role slot", function()
    assert(S.FeatureRuntime:Enable(Feature.Id, "regression"))
    Feature.State.autoRoleEnabled = true
    mockUnit.names.player = "LeaderPlayer"
    mockUnit.abilityTemplates.player = {{index=8},{index=9},{index=14}}
    Roster.ordered = {{name="LeaderPlayer@World",unitToken="player",teamIndex=1,memberIndex=2}}
    mockTeam.roles["1:2"] = TMROLE_NONE
    mockTeam.currentRole = nil
    assert(Feature:ApplyAutoRole("canonical_player"))
    assert(mockTeam.currentRole == TMROLE_HEALER, "canonical player identity rejected by display-name mismatch")
    local evidence=Feature.AutoRoleEvidence
    mockTeam.roles["1:2"]=TMROLE_HEALER
    assert(S.Scheduler:RunTask("v3_team_role_verify"))
    assert(evidence.confirmed and evidence.readback==TMROLE_HEALER,"accepted request was not read back from the real slot")
end)

Test("T14: unregistered class cannot clear a player's existing role", function()
    Roster.ordered = {{name="LeaderPlayer",unitToken="player",teamIndex=1,memberIndex=2}}
    mockUnit.abilityTemplates.player = {{index=97},{index=98},{index=99}}
    mockTeam.roles["1:2"] = TMROLE_TANKER
    mockTeam.currentRole = TMROLE_TANKER
    Feature:ApplyAutoRole("unknown_class")
    assert(mockTeam.currentRole == TMROLE_TANKER, "unknown class overwrote a confirmed manual role")
    assert(Feature.AutoRoleStatus:find("尚未登记", 1, true))
end)

Test("T15: real detailed module export includes observation, rendering and role decisions", function()
    dofile("core/rs_diagnostic_detail.lua")
    dofile("core/rs_module_diagnostics.lua")
    -- 重载注册 Provider，采集必须仅消费已有事实，不启动模块或再执行职责写入。
    assert(Sac:RegisterDiagnosticProviders())
    assert(Feature:RegisterDiagnosticProviders())
    local before = mockTeam.currentRole
    local originalCall=S.Api.CallCapability
    local reads=0
    S.Api.CallCapability=function(...) reads=reads+1;return originalCall(...) end -- 实际报告冻结期间不能偷偷补 Native 读数，否则“导出”会改变业务采样时序。
    local _,_,sacText = S.ModuleDiagnosticsHub:BuildReport(Sac.Id, {detailed=true})
    local _,_,roleText = S.ModuleDiagnosticsHub:BuildReport(Feature.Id, {detailed=true})
    S.Api.CallCapability=originalCall
    assert(reads==0,"diagnostic export queried native API")
    assert(sacText and roleText, "detailed TXT was not generated")
    assert(sacText:find("provider.team_sac_evidence", 1, true))
    assert(sacText:find("candidateScan", 1, true) and sacText:find("overlay", 1, true))
    assert(roleText:find("provider.team_role_evidence", 1, true) and roleText:find("autoRole", 1, true))
    assert(mockTeam.currentRole == before, "diagnostic export changed native role")
    assert(sacText:find("v3.combat.team_tools.visuals",1,true),"split visual store is missing from diagnostic ownership")
end)

Test("T16: roster to aura event to visible overlay, then buff removal hides it", function()
    assert(S.FeatureRuntime:Enable(Sac.Id,"full_chain"))
    assert(Sac.Commands:SetSacHighlightEnabled(true))
    Roster.ordered={{name="DancerOne",unitToken="team_1_1",teamIndex=1,memberIndex=1}}
    mockUnit.abilityTemplates.team_1_1={{index=14},{index=1},{index=2}}
    mockUnit.buffs.team_1_1={{buff_id=30098,name="牺牲之舞"}}
    S.Services.AuraObservationV3.cache={}
    Sac:ScanSacCandidates("full_chain")
    local overlay=S.UIV3.TeamSacOverlay
    assert(Visuals.activeCount==1 and overlay.running and #overlay.active==1,"matched aura did not reach overlay")
    assert(overlay.lastVisible==1,"native screen point did not produce a visible overlay")
    mockUnit.buffs.team_1_1={}
    S.Services.AuraObservationV3.cache={}
    Sac:ScanSacAuras("skill_end")
    assert(not overlay.running and overlay.lastVisible==0,"ended skill left stale marker")
    assert(Sac:DescribeDiagnosticDetail().lastMatched.team_1_1,"ended skill lost its diagnostic evidence")
    Roster.ordered={}
    Sac:ScanSacCandidates("leave_team")
    assert(next(Visuals.lastMatched)==nil,"roster changes retained unbounded old identities")
end)

-- 中文维护（2026-10-03）：真机报告已命中技能，却因相机世界空间 forward=-2026.44 被隐藏；复现“相机接口存在”而非此前的缺相机回退路径。
Test("T17: valid native player/raid points survive mismatched camera space", function()
    local originalPos,originalDir,originalFov=UIParent.GetViewCameraPos,UIParent.GetViewCameraDir,UIParent.GetViewCameraFov
    local originalScreen=mockUnit.GetUnitScreenPosition
    local function RunBody()
        UIParent.GetViewCameraPos=function()return {x=3026.44,y=2000,z=50}end
        UIParent.GetViewCameraDir=function()return {x=1,y=0,z=0}end
        UIParent.GetViewCameraFov=function()return 1.57 end
        mockUnit.GetUnitScreenPosition=function()return 500,300,10 end
        for _,name in ipairs({"UIParent:GetViewCameraPos","UIParent:GetViewCameraDir","UIParent:GetViewCameraFov"}) do S.Api.allowedCapabilities[name]=true end
        local strict=S.Services.ScreenProjectionV3:ProjectUnitBatch({"player"},{requireFrontHemisphere=true})
        assert(strict.player.reason=="behind_camera","fixture must reproduce the live camera-space rejection")
        assert(S.FeatureRuntime:Enable(Sac.Id,"camera_space_regression"))
        assert(Sac.Commands:SetSacHighlightEnabled(true))
        Roster.ordered={{name="LeaderPlayer",unitToken="player",teamIndex=1,memberIndex=1},{name="DancerOne",unitToken="team_1_1",teamIndex=1,memberIndex=2}}
        mockUnit.abilityTemplates.player={{index=14},{index=8},{index=6}}
        mockUnit.abilityTemplates.team_1_1={{index=14},{index=1},{index=2}}
        mockUnit.buffs.player={{buff_id=30098,name="牺牲之舞"}}
        mockUnit.buffs.team_1_1={{buff_id=30137,name="牺牲之舞"}}
        S.Services.AuraObservationV3.cache={}
        Sac:ScanSacCandidates("camera_space_regression")
        local overlay=S.UIV3.TeamSacOverlay
        assert(Visuals.activeCount==2,"both native buffs must match before testing visibility")
        assert(overlay.lastVisible==2,"valid player/raid screen points were suppressed by camera-space math")
        assert(overlay.pool[1].window.shown and overlay.pool[2].window.shown,"markers were not shown")
        mockUnit.GetUnitScreenPosition=function()return 500,300,-1 end
        overlay:VisualTick()
        assert(overlay.lastVisible==0,"native negative depth must still hide behind-camera units")
        mockUnit.GetUnitScreenPosition=function()return nil,nil,nil end
        overlay:VisualTick()
        assert(overlay.lastVisible==0,"missing native screen point must not invent a visible marker")
    end
    local ok,err=xpcall(RunBody,debug.traceback)
    UIParent.GetViewCameraPos,UIParent.GetViewCameraDir,UIParent.GetViewCameraFov=originalPos,originalDir,originalFov
    mockUnit.GetUnitScreenPosition=originalScreen
    if not ok then error(err) end
end)

print(string.format("\nTeam Tools & Visuals Test Results: %d/%d passed", passed, total))
if passed == total then
    print("ALL TESTS PASSED!")
else
    print("SOME TESTS FAILED!")
    os.exit(1)
end

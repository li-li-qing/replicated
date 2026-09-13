------------------------------------------------------------------------
-- Replicated Suite V3 - Team Tools Test Suite (B10)
--
-- Tests combat_team_tools Feature, TeamRole read-only projection,
-- player self-role write, auto-role catalog resolution, member move fail-closed,
-- Spelldance (Sacrifice Dance) candidate discovery & aura tracking,
-- team marker snapshot save & capacity bounds, 1100ms paced serial restore
-- with readback verification, presentation overlay, and FoundationGate contracts.
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

-- Native Team Role Constants
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

-- Native Mocks
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

-- Allow API capabilities
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

-- Load foundation modules
dofile("data/rs_data_registry.lua")
dofile("data/ids/rs_item_ids.lua")
dofile("data/ids/rs_quest_ids.lua")
dofile("core/rs_constants.lua")
dofile("core/rs_demand.lua")
dofile("core/rs_foundation_gate.lua")
dofile("features/rs_feature_registry.lua")
dofile("features/rs_feature_runtime.lua")

-- Load catalogs and services
dofile("data/rs_team_auto_role_catalog.lua")
dofile("services/rs_team_roster_v3.lua")
dofile("services/rs_aura_observation_v3.lua")
dofile("services/rs_screen_projection_v3.lua")

-- Load business bridge and team visuals extension
dofile("features/rs_business_bridge.lua")
dofile("features/combat/team_tools/rs_team_tools_visuals.lua")

-- Presentation widgets and pages
dofile("presentation/v3/widgets/rs_v3_team_sac_overlay.lua")
dofile("presentation/v3/pages/rs_v3_business_pages.lua")
dofile("presentation/v3/rs_v3_acceptance.lua")

local Feature = S.Features.combat_team_tools
local Roster = S.Services.TeamRosterV3
local Visuals = Feature.TeamVisuals

------------------------------------------------------------------------
-- Test 1: Feature Registry Metadata & Contract Versions
------------------------------------------------------------------------
Test("T1: Feature registry metadata & contract versions", function()
    local reg = S.FeatureRegistry:Get("combat_team_tools")
    assert(reg ~= nil, "combat_team_tools must be registered in FeatureRegistry")
    assert(reg.id == "combat_team_tools", "id mismatch")
    assert(reg.route == "combat.team_tools", "route mismatch")
    assert(reg.name == "团队中心", "name mismatch")
    assert(reg.category == "combat", "category mismatch")
    assert(reg.lifecycle == "explicit_action", "lifecycle mismatch")

    local deps = reg.apiDependencies
    assert(#deps >= 7, "Must declare at least 7 API dependencies")
    local hasGetRole, hasSetRole, hasMarkers = false, false, false
    for _, d in ipairs(deps) do
        if d == "X2Team:GetRole" then hasGetRole = true end
        if d == "X2Team:SetRole" then hasSetRole = true end
        if d == "X2Unit:SetOverHeadMarker" then hasMarkers = true end
    end
    assert(hasGetRole, "X2Team:GetRole missing from dependencies")
    assert(hasSetRole, "X2Team:SetRole missing from dependencies")
    assert(hasMarkers, "X2Unit:SetOverHeadMarker missing from dependencies")

    -- Contracts
    assert((tonumber(Feature.TeamRoleContractVersion) or 0) >= 2, "TeamRoleContractVersion >= 2")
    assert((tonumber(Feature.AutoRoleCatalogContractVersion) or 0) >= 1, "AutoRoleCatalogContractVersion >= 1")
    assert((tonumber(Feature.TeamVisualContractVersion) or 0) >= 2, "TeamVisualContractVersion >= 2")
    assert((tonumber(Feature.TeamMarkerSnapshotContractVersion) or 0) >= 1, "TeamMarkerSnapshotContractVersion >= 1")
    assert((tonumber(Feature.TeamSacContractVersion) or 0) >= 2, "TeamSacContractVersion >= 2")
    assert((tonumber(Feature.AutoRoleDefaultOnContractVersion) or 0) >= 1, "AutoRoleDefaultOnContractVersion >= 1")
    assert(type(Feature.Commands.SetRole) == "function", "SetRole command missing")
    assert(type(Feature.Commands.SetAutoRoleEnabled) == "function", "SetAutoRoleEnabled command missing")
    assert(type(Feature.Commands.MoveMember) == "function", "MoveMember command missing")
    assert(type(Feature.Commands.MoveMemberToParty) == "function", "MoveMemberToParty command missing")
    assert(type(Feature.Commands.SetSacHighlightEnabled) == "function", "SetSacHighlightEnabled missing")
    assert(type(Feature.Commands.SaveRaidMarkers) == "function", "SaveRaidMarkers missing")
    assert(type(Feature.Commands.RestoreRaidMarkers) == "function", "RestoreSavedRaidMarkers missing")
    assert(type(Feature.Commands.ClearSavedRaidMarkers) == "function", "ClearSavedRaidMarkers missing")
end)

------------------------------------------------------------------------
-- Test 2: Team Roster Read-Only Projection & Role Mapping
------------------------------------------------------------------------
Test("T2: Team roster read-only projection & role mapping", function()
    -- Initialize Feature
    Feature:Initialize()
    Feature:Enable("test_t2")
    Feature:AcquireConsumer("test_t2")

    -- Setup mock roster snapshot
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

    -- Configure mock roles
    mockTeam.roles["1:1"] = _G.TMROLE_TANKER
    mockTeam.roles["1:2"] = _G.TMROLE_HEALER
    mockTeam.roles["1:3"] = _G.TMROLE_DEALER
    mockTeam.roles["2:1"] = _G.TMROLE_RANGED_DEALER
    mockTeam.roles["2:2"] = _G.TMROLE_NONE

    -- Trigger Feature Read
    Feature.Authority:Refresh("test_roster_read")
    local rows = Feature.Authority.rows
    local status = Feature.Authority.status
    local err = Feature.Authority.error
    assert(status == "ready", "Status should be ready, got: " .. tostring(status))
    assert(#rows == 5, "Rows count should be 5")

    -- Check Row 1: Tank
    assert(rows[1].name == "TankOne", "Row 1 name mismatch")
    assert(rows[1].role == _G.TMROLE_TANKER, "Row 1 role should be TMROLE_TANKER")
    assert(rows[1].roleStatus == "ready", "Row 1 roleStatus mismatch")
    assert(rows[1].text:find("已读取") ~= nil or rows[1].statusText == "已读取", "Row 1 statusText mismatch")

    -- Check Row 2: Healer
    assert(rows[2].name == "HealerTwo", "Row 2 name mismatch")
    assert(rows[2].role == _G.TMROLE_HEALER, "Row 2 role should be TMROLE_HEALER")

    -- Check Row 4: Ranged Dealer
    assert(rows[4].name == "RangedFour", "Row 4 name mismatch")
    assert(rows[4].role == _G.TMROLE_RANGED_DEALER, "Row 4 role should be TMROLE_RANGED_DEALER")

    -- Check Empty Team Handling
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

------------------------------------------------------------------------
-- Test 3: Current Player Self-Role Write Contract
------------------------------------------------------------------------
Test("T3: Current player self-role write contract", function()
    Feature:Enable("test_t3")

    -- 1. Valid role write: SetRole to TMROLE_HEALER (advance clock for 500ms cooldown)
    h.ms = h.ms + 600
    local okHealer = Feature.Commands:SetRole(_G.TMROLE_HEALER)
    assert(okHealer == true, "SetRole(TMROLE_HEALER) failed")
    assert(mockTeam.currentRole == _G.TMROLE_HEALER, "mockTeam.currentRole should be TMROLE_HEALER")

    -- 2. Valid role write: SetRole to TMROLE_TANKER (advance clock past 500ms cooldown)
    h.ms = h.ms + 600
    local okTank = Feature.Commands:SetRole(_G.TMROLE_TANKER)
    assert(okTank == true, "SetRole(TMROLE_TANKER) failed")
    assert(mockTeam.currentRole == _G.TMROLE_TANKER, "mockTeam.currentRole should be TMROLE_TANKER")

    -- 3. Invalid role value rejection
    local badOk, badErr = Feature.Commands:SetRole(999)
    assert(badOk == false, "Out of range role should be rejected")
    assert(tostring(badErr):find("TMROLE_*") ~= nil, "Error message must mention TMROLE_* enum")

    local strOk, _ = Feature.Commands:SetRole("healer")
    assert(strOk == false, "String role should be rejected")

    local nilOk, _ = Feature.Commands:SetRole(nil)
    assert(nilOk == false, "Nil role should be rejected")
end)

------------------------------------------------------------------------
-- Test 4: Auto-Role Catalog Resolution & Automatic Application
------------------------------------------------------------------------
Test("T4: Auto-role catalog resolution & automatic application", function()
    Feature:Enable("test_t4")

    -- Set up current player in roster
    Roster.ordered = {
        { name = "LeaderPlayer", unitToken = "player", teamIndex = 1, memberIndex = 1 },
        { name = "PartyMember2", unitToken = "team_1_2", teamIndex = 1, memberIndex = 2 },
    }
    Roster.members = {}
    for _, m in ipairs(Roster.ordered) do Roster.members[m.name] = m end

    -- Setup ability templates for player: Wild (6), Romance (8), Shadow (9) -> Archer (ranged)
    mockUnit.abilityTemplates["player"] = {
        { index = 6 }, { index = 8 }, { index = 9 }
    }
    mockTeam.roles["1:1"] = _G.TMROLE_NONE

    -- Execute ApplyAutoRole (advance clock for 500ms cooldown)
    h.ms = h.ms + 600
    local okApply = Feature:ApplyAutoRole("test_archer")
    assert(okApply == true, "ApplyAutoRole failed")
    assert(mockTeam.currentRole == _G.TMROLE_RANGED_DEALER, "Role should be auto-set to TMROLE_RANGED_DEALER")
    assert(Feature.AutoRoleClassKey == "name_6_8_9", "AutoRoleClassKey mismatch")
    assert(Feature.AutoRoleLabel == "远程输出", "AutoRoleLabel mismatch")

    -- Change ability templates to Tank: 3, 4, 5 -> Tank (tank)
    mockUnit.abilityTemplates["player"] = {
        { index = 3 }, { index = 4 }, { index = 5 }
    }
    mockTeam.roles["1:1"] = _G.TMROLE_RANGED_DEALER -- currently ranged, needs switch to tank
    h.ms = h.ms + 600
    local okTank = Feature:ApplyAutoRole("test_tank")
    assert(okTank == true, "ApplyAutoRole tank failed")
    assert(mockTeam.currentRole == _G.TMROLE_TANKER, "Role should be auto-set to TMROLE_TANKER")

    -- If already matched, no write needed
    mockTeam.roles["1:1"] = _G.TMROLE_TANKER
    mockTeam.currentRole = nil
    Feature:ApplyAutoRole("test_already_matched")
    assert(mockTeam.currentRole == nil, "No write should occur if already matched")
    assert(Feature.AutoRoleStatus:find("已匹配") ~= nil, "AutoRoleStatus should mention matched")

    -- AutoRole toggle command
    Feature.Commands:SetAutoRoleEnabled(false)
    assert(Feature.State.autoRoleEnabled == false, "autoRoleEnabled should be false")
    Feature.Commands:SetAutoRoleEnabled(true)
    assert(Feature.State.autoRoleEnabled == true, "autoRoleEnabled should be true")
end)

------------------------------------------------------------------------
-- Test 5: Member Move Fail-Closed Boundary
------------------------------------------------------------------------
Test("T5: Member move fail-closed boundary", function()
    local okMove, moveErr = Feature.Commands:MoveMember(1, 2)
    assert(okMove == false, "MoveMember must return false")
    assert(tostring(moveErr):find("安全停用") ~= nil, "Error message must state safely disabled")
    assert(tostring(moveErr):find("队长") ~= nil, "Error message must mention leader permission")

    local okParty, partyErr = Feature.Commands:MoveMemberToParty(1, 2)
    assert(okParty == false, "MoveMemberToParty must return false")
    assert(tostring(partyErr):find("安全停用") ~= nil, "Error message must state safely disabled")

    -- Projection check
    local proj = Feature:GetProjection()
    assert(proj.memberMoveAvailable == false, "memberMoveAvailable must be false in projection")
end)

------------------------------------------------------------------------
-- Test 6: Spelldance Candidate Discovery & Aura Tracking
------------------------------------------------------------------------
Test("T6: Spelldance candidate discovery & aura tracking", function()
    Feature:Enable("test_t6")
    Visuals.running = true

    -- Setup Roster: Player 1 has Spelldance (14), Player 2 does not
    Roster.ordered = {
        { name = "DancerOne", unitToken = "team_1_1", teamIndex = 1, memberIndex = 1 },
        { name = "WarriorTwo", unitToken = "team_1_2", teamIndex = 1, memberIndex = 2 },
    }
    mockUnit.names["team_1_1"] = "DancerOne"
    mockUnit.names["team_1_2"] = "WarriorTwo"
    mockUnit.abilityTemplates["team_1_1"] = { { index = 14 }, { index = 1 }, { index = 2 } } -- Has Spelldance (14)
    mockUnit.abilityTemplates["team_1_2"] = { { index = 3 }, { index = 4 }, { index = 5 } }   -- No Spelldance

    -- Scan candidates
    local okScan = Feature:ScanSacCandidates("test_scan")
    assert(okScan == true, "ScanSacCandidates failed")
    assert(Visuals.candidateCount == 1, "Should have 1 candidate with Spelldance")
    assert(Visuals.candidates["team_1_1"] ~= nil, "DancerOne should be a candidate")
    assert(Visuals.candidates["team_1_2"] == nil, "WarriorTwo should not be a candidate")

    -- Initially no active auras
    assert(Visuals.activeCount == 0, "No active sac auras initially")

    -- Add Sacrifice Dance Buff (ID: 30098) to DancerOne
    mockUnit.buffs["team_1_1"] = {
        { buff_id = 30098, name = "牺牲之舞" }
    }
    -- Invalidate Aura cache and scan
    S.Services.AuraObservationV3.cache = {}
    Feature:ScanSacAuras("test_aura_active")
    assert(Visuals.activeCount == 1, "Active sac count should be 1")
    assert(Visuals.active["team_1_1"] ~= nil, "DancerOne should be active")
    assert(Visuals.active["team_1_1"].name == "DancerOne", "Active name mismatch")

    -- Remove Buff -> active cleared
    mockUnit.buffs["team_1_1"] = {}
    S.Services.AuraObservationV3.cache = {}
    Feature:ScanSacAuras("test_aura_removed")
    assert(Visuals.activeCount == 0, "Active sac count should return to 0 after buff removal")

    -- Toggle Command
    Feature.Commands:SetSacHighlightEnabled(false)
    assert(Visuals.state.sacEnabled == false, "sacEnabled should be false after toggle")
    Feature.Commands:SetSacHighlightEnabled(true)
    assert(Visuals.state.sacEnabled == true, "sacEnabled should be true after toggle")
end)

------------------------------------------------------------------------
-- Test 7: Team Marker Snapshot Save & Capacity Bounds
------------------------------------------------------------------------
Test("T7: Team marker snapshot save & capacity bounds", function()
    Feature:Enable("test_t7")

    -- Setup roster members with markers
    Roster.ordered = {
        { name = "Alpha", unitToken = "team_1_1", teamIndex = 1, memberIndex = 1 },
        { name = "Beta", unitToken = "team_1_2", teamIndex = 1, memberIndex = 2 },
        { name = "Gamma", unitToken = "team_1_3", teamIndex = 1, memberIndex = 3 },
    }
    mockUnit.markers["team_1_1"] = 1 -- Star / Marker 1
    mockUnit.markers["team_1_2"] = 2 -- Circle / Marker 2
    mockUnit.markers["team_1_3"] = 0 -- No marker

    -- Save markers
    local okSave, count = Feature.Commands:SaveRaidMarkers()
    assert(okSave == true, "SaveRaidMarkers failed: " .. tostring(count))
    assert(count == 2, "Saved marker count should be 2 (Alpha and Beta)")
    assert(Visuals.markerStatus == "saved", "markerStatus should be saved")

    -- Check savedMarks content
    local saved = Visuals.state.savedMarks
    assert(#saved == 2, "savedMarks should contain 2 entries")
    assert(saved[1].name == "Alpha" and saved[1].markerIndex == 1, "First saved mark mismatch")
    assert(saved[2].name == "Beta" and saved[2].markerIndex == 2, "Second saved mark mismatch")

    -- Projection check
    local proj = Feature:GetProjection()
    assert(proj.savedMarkerCount == 2, "proj.savedMarkerCount mismatch")
    assert(proj.markerStatus == "saved", "proj.markerStatus mismatch")

    -- Clear saved markers
    local okClear = Feature.Commands:ClearSavedRaidMarkers()
    assert(okClear == true, "ClearSavedRaidMarkers failed")
    assert(#Visuals.state.savedMarks == 0, "savedMarks should be empty after clear")
    assert(Feature:GetProjection().savedMarkerCount == 0, "Projection saved count should be 0")
end)

------------------------------------------------------------------------
-- Test 8: Team Marker 1100ms Paced Serial Restore & Readback Verification
------------------------------------------------------------------------
Test("T8: Team marker 1100ms paced serial restore & readback verification", function()
    S.FeatureRuntime:Enable("combat_team_tools", "test_t8")
    Feature:Enable("test_t8")

    -- Pre-populate saved marks: Alpha -> Marker 1, Beta -> Marker 2
    Visuals.state.savedMarks = {
        { name = "Alpha", markerIndex = 1 },
        { name = "Beta", markerIndex = 2 },
    }

    -- Current team has Alpha and Beta, but markers are currently 0 (cleared/wrong)
    Roster.ordered = {
        { name = "Alpha", unitToken = "team_1_1", teamIndex = 1, memberIndex = 1 },
        { name = "Beta", unitToken = "team_1_2", teamIndex = 1, memberIndex = 2 },
    }
    mockUnit.markers["team_1_1"] = 0
    mockUnit.markers["team_1_2"] = 0

    -- Initiate restore
    local okRestore, queuedCount = Feature.Commands:RestoreRaidMarkers()
    assert(okRestore == true, "RestoreRaidMarkers failed: " .. tostring(queuedCount))
    assert(queuedCount == 2, "Queued count should be 2")
    assert(Visuals.markerStatus == "restoring", "markerStatus should be restoring")

    -- Verify 1100ms scheduler task was registered
    local task = S.Scheduler.tasks["v3_team_tools_marker_restore"]
    assert(task ~= nil, "Restore scheduler task missing")
    assert(task.intervalMs == 1100, "Restore task interval must be 1100ms")

    -- Tick 1: Writes marker for Alpha (team_1_1 -> marker 1), advance clock by 1200ms
    h.ms = h.ms + 1200
    task.callback()
    assert(mockUnit.markers["team_1_1"] == 1, "Alpha marker should be set to 1")
    assert(Visuals.restorePending ~= nil, "Should have pending readback verification")
    assert(Visuals.restorePending.name == "Alpha", "Pending verification should be Alpha")

    -- Tick 2: Readback verifies Alpha -> Writes marker for Beta (team_1_2 -> marker 2)
    h.ms = h.ms + 1200
    task.callback()
    assert(Visuals.markerApplied == 1, "Alpha should be verified as applied")
    assert(mockUnit.markers["team_1_2"] == 2, "Beta marker should be set to 2")
    assert(Visuals.restorePending.name == "Beta", "Pending verification should be Beta")

    -- Tick 3: Readback verifies Beta -> All items finished
    h.ms = h.ms + 1200
    task.callback()
    assert(Visuals.markerApplied == 2, "Beta should be verified as applied")
    assert(Visuals.markerStatus == "complete", "markerStatus should be complete")
    assert(Visuals.restoreQueue == nil, "Queue should be cleared upon completion")

    -- Projection check
    local proj = Feature:GetProjection()
    assert(proj.markerStatus == "complete", "proj.markerStatus mismatch")
    assert(proj.markerApplied == 2, "proj.markerApplied mismatch")
    assert(proj.markerRestoreRunning == false, "markerRestoreRunning should be false")
end)

------------------------------------------------------------------------
-- Test 9: TeamSacOverlay Presentation Widget & Tick Cadence
------------------------------------------------------------------------
Test("T9: TeamSacOverlay presentation widget & tick cadence", function()
    local Overlay = S.UIV3.TeamSacOverlay
    assert(Overlay ~= nil, "TeamSacOverlay missing from S.UIV3")
    assert(Overlay.TeamSacPresentationContractVersion >= 1, "TeamSacPresentationContractVersion missing")

    -- Ensure marker pool
    Overlay:EnsurePool(4)
    assert(#Overlay.pool == 4, "Pool should have 4 markers allocated")

    -- Active sac candidate present
    S.FeatureRuntime:Enable("combat_team_tools", "test_t9")
    Feature:Enable("test_t9")
    Visuals.state.sacEnabled = true
    Visuals.active = {
        ["team_1_1"] = { unitToken = "team_1_1", name = "DancerOne", verifiedAt = h.ms }
    }
    Overlay:Reconcile("test_active")

    -- Visual tick execution
    local okTick = Overlay:VisualTick()
    assert(okTick == true, "VisualTick failed")
    assert(Overlay.metrics.ticks > 0, "Ticks metric should be incremented")

    -- When active list becomes empty
    Visuals.active = {}
    Overlay:Reconcile("test_empty")
    assert(Overlay.running == false, "Overlay should stop when no active candidates")
end)

------------------------------------------------------------------------
-- Test 10: FoundationGate & Acceptance Contract Verification
------------------------------------------------------------------------
Test("T10: FoundationGate & Acceptance contract verification", function()
    -- 1. FoundationGate contract clauses
    local teamTools = S.Features and S.Features.combat_team_tools or nil
    local teamRoleCatalog = S.Data and S.Data.TeamAutoRoleCatalog or nil
    local archerRole = type(teamRoleCatalog) == "table" and type(teamRoleCatalog.byClassKey) == "table"
        and teamRoleCatalog.byClassKey["name_6_8_9"] or nil
    local teamRoleOk = type(teamTools) == "table" and (tonumber(teamTools.TeamRoleContractVersion) or 0) >= 2
        and (tonumber(teamTools.AutoRoleCatalogContractVersion) or 0) >= 1
        and type(teamTools.Commands) == "table" and type(teamTools.Commands.SetRole) == "function"
        and type(teamRoleCatalog) == "table" and (tonumber(teamRoleCatalog.version) or 0) >= 2
        and type(archerRole) == "table" and tostring(archerRole.role or "") == "ranged"
    assert(teamRoleOk, "v3_team_role_contract clauses must pass")

    local teamSacOverlay = S.UIV3 and S.UIV3.TeamSacOverlay or nil
    local teamVisualOk = type(teamTools) == "table"
        and (tonumber(teamTools.TeamVisualContractVersion) or 0) >= 2
        and (tonumber(teamTools.TeamMarkerSnapshotContractVersion) or 0) >= 1
        and (tonumber(teamTools.TeamSacContractVersion) or 0) >= 2
        and (tonumber(teamTools.AutoRoleDefaultOnContractVersion) or 0) >= 1
        and type(teamTools.Commands) == "table"
        and type(teamTools.Commands.SetSacHighlightEnabled) == "function"
        and type(teamTools.Commands.SaveRaidMarkers) == "function"
        and type(teamTools.Commands.RestoreRaidMarkers) == "function"
        and type(teamTools.Commands.ClearSavedRaidMarkers) == "function"
        and type(teamSacOverlay) == "table" and (tonumber(teamSacOverlay.TeamSacPresentationContractVersion) or 0) >= 1
    assert(teamVisualOk, "v3_team_visual_marker_contract clauses must pass")

    -- 2. Acceptance Verification
    local accFailures = {}
    local teamTools = S.Features.combat_team_tools
    local teamRoleCatalog = S.Data.TeamAutoRoleCatalog
    local archerRole = teamRoleCatalog.byClassKey["name_6_8_9"]

    if type(teamTools) ~= "table" or (tonumber(teamTools.TeamRoleContractVersion) or 0) < 2
        or (tonumber(teamTools.AutoRoleCatalogContractVersion) or 0) < 1
        or type(teamTools.Commands) ~= "table" or type(teamTools.Commands.SetRole) ~= "function"
        or type(teamRoleCatalog) ~= "table" or (tonumber(teamRoleCatalog.version) or 0) < 2
        or type(archerRole) ~= "table" or tostring(archerRole.role or "") ~= "ranged" then
        accFailures[#accFailures + 1] = "team_role_catalog_contract_v3"
    end

    local teamSacOverlay = S.UIV3.TeamSacOverlay
    if type(teamTools) ~= "table" or (tonumber(teamTools.TeamVisualContractVersion) or 0) < 2
        or (tonumber(teamTools.TeamMarkerSnapshotContractVersion) or 0) < 1
        or (tonumber(teamTools.TeamSacContractVersion) or 0) < 2
        or (tonumber(teamTools.AutoRoleDefaultOnContractVersion) or 0) < 1
        or type(teamTools.Commands) ~= "table"
        or type(teamTools.Commands.SetSacHighlightEnabled) ~= "function"
        or type(teamTools.Commands.SaveRaidMarkers) ~= "function"
        or type(teamTools.Commands.RestoreRaidMarkers) ~= "function"
        or type(teamSacOverlay) ~= "table" or (tonumber(teamSacOverlay.TeamSacPresentationContractVersion) or 0) < 1 then
        accFailures[#accFailures + 1] = "team_visual_marker_contract_v2"
    end

    assert(#accFailures == 0, "Acceptance checks failed: " .. table.concat(accFailures, ", "))
end)

print(string.format("\nTeam Tools & Visuals Test Results: %d/%d passed", passed, total))
if passed == total then
    print("ALL TESTS PASSED!")
else
    print("SOME TESTS FAILED!")
    os.exit(1)
end

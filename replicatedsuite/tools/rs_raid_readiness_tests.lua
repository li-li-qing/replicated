------------------------------------------------------------------------
-- Replicated Suite V3 - Raid Readiness Test Suite (B11)
--
-- Tests combat_raid_readiness Feature, Settings & Store persistence,
-- Demand lifecycle & Aura lease isolation, sliced async scan execution,
-- Role inspection & fallback, GearScore parsing with comma=false fix,
-- Aura observation & required Buff evaluation, Distance inspection &
-- multi-metric status aggregation, Paging & showOnlyIssues filter,
-- PageHost factory integration, and FoundationGate / Acceptance contracts.
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

print("=== Replicated Suite: Raid Readiness Tests ===")

local h = dofile("tools/rs_gear_page_test_host.lua")({})
local S = h.S

-- Native Team Role Constants
_G.TMROLE_NONE = 0
_G.TMROLE_TANKER = 1
_G.TMROLE_HEALER = 2
_G.TMROLE_DEALER = 3
_G.TMROLE_RANGED_DEALER = 4

-- Viewport mock for UIParent
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

-- Native Mocks
local mockTeam = {
    roles = {},
    GetRole = function(self, teamIndex, memberIndex)
        local key = tostring(teamIndex) .. ":" .. tostring(memberIndex)
        return self.roles[key] or _G.TMROLE_NONE
    end,
}
_G.X2Team = mockTeam

local mockUnit = {
    gearScores = {},
    distances = {},
    UnitGearScore = function(self, token, comma)
        return self.gearScores[token]
    end,
    UnitDistance = function(self, token)
        return self.distances[token]
    end,
}
_G.X2Unit = mockUnit

-- Allow API capabilities
S.Api.allowedCapabilities = S.Api.allowedCapabilities or {}
S.Api.allowedCapabilities["X2Team:GetRole"] = true
S.Api.allowedCapabilities["X2Unit:UnitGearScore"] = true
S.Api.allowedCapabilities["X2Unit:UnitDistance"] = true

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
dofile("native/rs_native_contract.lua")
dofile("core/rs_constants.lua")
dofile("core/rs_demand.lua")
dofile("core/rs_foundation_gate.lua")
dofile("features/rs_feature_registry.lua")
dofile("features/rs_feature_runtime.lua")

-- Load services
dofile("services/rs_team_roster_v3.lua")
dofile("services/rs_aura_observation_v3.lua")

-- Load form and numeric components for page integration
dofile("ui/framework/rs_ui_numeric_range_store.lua")
dofile("ui/framework/rs_ui_forms.lua")

-- Load raid readiness feature, store, authority, acceptance, and page
dofile("features/combat/raid_readiness/rs_raid_readiness_store.lua")
dofile("features/combat/raid_readiness/rs_raid_readiness_authority.lua")
dofile("features/combat/raid_readiness/rs_raid_readiness_feature.lua")
dofile("features/combat/raid_readiness/rs_raid_readiness_acceptance.lua")
dofile("presentation/v3/pages/rs_v3_raid_readiness_page.lua")

local Feature = S.Features.RaidReadiness
local Authority = Feature.Authority
local Roster = S.Services.TeamRosterV3
local Aura = S.Services.AuraObservationV3

------------------------------------------------------------------------
-- Test 1: Feature Registry Metadata & Navigation Hierarchy
------------------------------------------------------------------------
Test("T1: Feature registry metadata & navigation hierarchy", function()
    local reg = S.FeatureRegistry:Get("combat_raid_readiness")
    assert(reg ~= nil, "combat_raid_readiness must be registered in FeatureRegistry")
    assert(reg.id == "combat_raid_readiness", "id mismatch")
    assert(reg.route == "combat.raid_readiness", "route mismatch")
    assert(reg.name == "团队战备检查", "name mismatch")
    assert(reg.category == "combat", "category mismatch")
    assert(reg.status == "migrated_m16_14", "status mismatch: " .. tostring(reg.status))
    assert(reg.lifecycle == "on_demand_scan", "lifecycle mismatch: " .. tostring(reg.lifecycle))
    assert(reg.authority == "v3.raid_readiness + v3.team_roster + v3.aura_observation", "authority mismatch")
    assert(reg.defaultEnabled == false, "defaultEnabled must be false")
    assert(reg.widgetCapable == false, "widgetCapable must be false")
    assert(reg.settingsCapable == true, "settingsCapable must be true")
    assert(reg.navigationParentRoute == "combat.team_tools", "navigationParentRoute must be combat.team_tools")
    assert(reg.navigationVisible == false, "navigationVisible must be false")
end)

------------------------------------------------------------------------
-- Test 2: Store Persistence & Settings Bounds
------------------------------------------------------------------------
Test("T2: Store persistence & settings bounds", function()
    local loaded, loadErr = Feature:EnsureStoreLoaded()
    assert(loaded == true, "EnsureStoreLoaded failed: " .. tostring(loadErr))
    assert(Feature.StoreLoaded == true, "StoreLoaded must be true")

    -- Check default settings
    local s = Feature:GetSettings()
    assert(type(s) == "table", "GetSettings must return table")
    assert(s.minGearScore == 0, "default minGearScore should be 0")
    assert(#s.requiredAuraIds == 0, "default requiredAuraIds should be empty")
    assert(s.includeHidden == true, "default includeHidden should be true")
    assert(s.showOnlyIssues == false, "default showOnlyIssues should be false")

    -- Test minGearScore clamp
    Feature:ApplySettingRaw("minGearScore", -500)
    assert(s.minGearScore == 0, "negative gearScore must clamp to 0")
    Feature:ApplySettingRaw("minGearScore", 99999)
    assert(s.minGearScore == 50000, "gearScore > 50000 must clamp to 50000")
    Feature:ApplySettingRaw("minGearScore", 16500)
    assert(s.minGearScore == 16500, "valid gearScore set to 16500")

    -- Test requiredAuraIds parsing from string with comma/space separation & sorting
    Feature:ApplySettingRaw("requiredAuraIds", "30141, 30098 30137 30098")
    assert(#s.requiredAuraIds == 3, "requiredAuraIds should deduplicate to 3 items")
    assert(s.requiredAuraIds[1] == 30098, "item 1 should be sorted: 30098")
    assert(s.requiredAuraIds[2] == 30137, "item 2 should be sorted: 30137")
    assert(s.requiredAuraIds[3] == 30141, "item 3 should be sorted: 30141")

    -- Test GetRequiredAuraText
    local auraText = Feature:GetRequiredAuraText()
    assert(auraText == "30098,30137,30141", "GetRequiredAuraText mismatch: " .. tostring(auraText))

    -- Test binding application & event publishing
    local publishedTopic = nil
    S.Events:SubscribeInternal("v3.raid_readiness.settings", "test_listener", function(_, key)
        publishedTopic = key
    end)
    local okBinding = Feature.Commands:ApplySettingFromBinding("showOnlyIssues", true)
    assert(okBinding == true, "ApplySettingFromBinding failed")
    assert(s.showOnlyIssues == true, "showOnlyIssues should be true")
    assert(publishedTopic == "showOnlyIssues", "settings changed event should publish key")

    -- Test SetSettingValue
    local okSet = Feature:SetSettingValue("includeHidden", false)
    assert(okSet == true, "SetSettingValue failed")
    assert(s.includeHidden == false, "includeHidden should be false")

    -- Clean up listener
    S.Events:UnsubscribeInternal("v3.raid_readiness.settings", "test_listener")
end)

------------------------------------------------------------------------
-- Test 3: Demand Lifecycle & Consumer Management
------------------------------------------------------------------------
Test("T3: Demand lifecycle & consumer management", function()
    -- 1. Initial dormant state
    assert(Feature.enabled == false, "Feature initially disabled")
    assert(Feature.consumerCount == 0, "consumerCount initially 0")
    assert(Feature.rosterHeld == false, "rosterHeld initially false")
    assert(Feature.auraHeld == false, "auraHeld initially false")

    -- 2. Enable feature
    Feature:Enable("test_enable")
    assert(Feature.enabled == true, "Feature should be enabled")

    -- 3. Acquire consumer (simulates Page open)
    local okAcquire = Feature:AcquireConsumer("test_page_c1")
    assert(okAcquire == true, "AcquireConsumer failed")
    assert(Feature.consumerCount == 1, "consumerCount should be 1")
    assert(Feature.rosterHeld == true, "rosterHeld should be true on active page")
    assert(Feature.auraHeld == false, "auraHeld must remain false while not scanning")

    -- 4. Release consumer (simulates Page close)
    local okRelease = Feature:ReleaseConsumer("test_page_c1")
    assert(okRelease == true, "ReleaseConsumer failed")
    assert(Feature.consumerCount == 0, "consumerCount should be 0")
    assert(Feature.rosterHeld == false, "rosterHeld must be false when dormant")
    assert(Feature.auraHeld == false, "auraHeld must be false when dormant")

    -- 5. QuiesceDemand
    Feature:AcquireConsumer("test_page_c2")
    assert(Feature.rosterHeld == true, "rosterHeld should be true")
    Feature:QuiesceDemand("test_quiesce")
    assert(Feature.rosterHeld == false, "rosterHeld should be released on quiesce")
    assert(Feature.auraHeld == false, "auraHeld should be released on quiesce")
end)

------------------------------------------------------------------------
-- Test 4: Scan Scheduling & Sliced Pacing
------------------------------------------------------------------------
Test("T4: Scan scheduling & sliced pacing", function()
    Feature:Disable("test_t4")

    -- 1. StartScan when disabled should fail
    local failDisabled, errDisabled = Feature:RunScan("disabled_test")
    assert(failDisabled == false, "RunScan when disabled must fail")
    assert(tostring(errDisabled):find("未启用") ~= nil, "Error must mention 未启用")

    Feature:Enable("test_t4")

    -- 2. StartScan when consumerCount == 0 should fail
    local failNoConsumer, errNoConsumer = Feature:RunScan("no_consumer_test")
    assert(failNoConsumer == false, "RunScan without consumer must fail")
    assert(tostring(errNoConsumer):find("没有活动页面") ~= nil, "Error must mention 没有活动页面")

    -- Acquire page consumer
    Feature:AcquireConsumer("test_scan_page")

    -- 3. StartScan with empty roster should fail
    Roster.ordered = {}
    Roster.members = {}
    local failEmpty, errEmpty = Feature:RunScan("empty_roster_test")
    assert(failEmpty == false, "RunScan with empty roster must fail")
    assert(tostring(errEmpty):find("没有可检查的团队成员") ~= nil, "Error must mention 没有可检查的团队成员")

    -- 4. Setup 3 members in roster, clear requiredAuraIds -> batchSize is 8
    Roster.ordered = {
        { name = "MemberOne", unitToken = "team_1_1", teamIndex = 1, memberIndex = 1 },
        { name = "MemberTwo", unitToken = "team_1_2", teamIndex = 1, memberIndex = 2 },
        { name = "MemberThree", unitToken = "team_1_3", teamIndex = 1, memberIndex = 3 },
    }
    Roster.members = {}
    for _, m in ipairs(Roster.ordered) do Roster.members[m.name] = m end
    Feature:ApplySettingRaw("requiredAuraIds", "")
    Feature:ApplySettingRaw("minGearScore", 0)

    local okScan, scanMsg = Feature:RunScan("fast_batch_test")
    assert(okScan == true, "RunScan failed: " .. tostring(scanMsg))
    assert(Authority:IsScanning() == true, "Authority should be scanning")

    -- Verify scheduler task was registered
    local taskName = "raid_readiness_scan_" .. tostring(Authority.scan.generation)
    local task = S.Scheduler.tasks[taskName]
    assert(task ~= nil, "Scheduler task missing: " .. tostring(taskName))

    -- Execute slice callback (completes all 3 members in 1 batch)
    task.callback()
    assert(Authority:IsScanning() == false, "Scan should be complete")
    assert(Authority.scan.completed == 3, "All 3 members should be completed")
    assert(Authority.scan.total == 3, "Total should be 3")
    assert(#Authority.rows == 3, "Should produce 3 rows")

    Feature:ReleaseConsumer("test_scan_page")
end)

------------------------------------------------------------------------
-- Test 5: Role Inspection & Fallback Mapping
------------------------------------------------------------------------
Test("T5: Role inspection & fallback mapping", function()
    Feature:Enable("test_t5")
    Feature:AcquireConsumer("test_t5_page")

    Roster.ordered = {
        { name = "SelfPlayer", unitToken = "player", teamIndex = 0, memberIndex = 0 },
        { name = "TankPlayer", unitToken = "team_1_1", teamIndex = 1, memberIndex = 1 },
        { name = "HealerPlayer", unitToken = "team_1_2", teamIndex = 1, memberIndex = 2 },
        { name = "DealerPlayer", unitToken = "team_1_3", teamIndex = 1, memberIndex = 3 },
        { name = "RangedPlayer", unitToken = "team_2_1", teamIndex = 2, memberIndex = 1 },
        { name = "UnassignedPlayer", unitToken = "team_2_2", teamIndex = 2, memberIndex = 2 },
    }
    Roster.members = {}
    for _, m in ipairs(Roster.ordered) do Roster.members[m.name] = m end

    mockTeam.roles["1:1"] = _G.TMROLE_TANKER
    mockTeam.roles["1:2"] = _G.TMROLE_HEALER
    mockTeam.roles["1:3"] = _G.TMROLE_DEALER
    mockTeam.roles["2:1"] = _G.TMROLE_RANGED_DEALER
    mockTeam.roles["2:2"] = _G.TMROLE_NONE

    Feature:RunScan("role_test")
    local taskName = "raid_readiness_scan_" .. tostring(Authority.scan.generation)
    S.Scheduler.tasks[taskName].callback()

    local rows = Authority.rows
    assert(#rows == 6, "Should have 6 rows")

    -- Check player self-role
    assert(rows[1].name == "SelfPlayer", "Row 1 mismatch")
    assert(rows[1].roleText == "自己", "Player teamIndex 0 should have roleText '自己'")

    -- Check Tank
    assert(rows[2].name == "TankPlayer", "Row 2 mismatch")
    assert(rows[2].role == _G.TMROLE_TANKER, "Row 2 role should be TMROLE_TANKER")
    assert(rows[2].roleText == "坦克", "Row 2 roleText should be '坦克'")

    -- Check Healer
    assert(rows[3].name == "HealerPlayer", "Row 3 mismatch")
    assert(rows[3].role == _G.TMROLE_HEALER, "Row 3 role should be TMROLE_HEALER")
    assert(rows[3].roleText == "治疗", "Row 3 roleText should be '治疗'")

    -- Check Dealer
    assert(rows[4].name == "DealerPlayer", "Row 4 mismatch")
    assert(rows[4].role == _G.TMROLE_DEALER, "Row 4 role should be TMROLE_DEALER")
    assert(rows[4].roleText == "输出", "Row 4 roleText should be '输出'")

    -- Check Ranged Dealer
    assert(rows[5].name == "RangedPlayer", "Row 5 mismatch")
    assert(rows[5].role == _G.TMROLE_RANGED_DEALER, "Row 5 role should be TMROLE_RANGED_DEALER")
    assert(rows[5].roleText == "远程输出", "Row 5 roleText should be '远程输出'")

    -- Check Unassigned
    assert(rows[6].name == "UnassignedPlayer", "Row 6 mismatch")
    assert(rows[6].role == _G.TMROLE_NONE, "Row 6 role should be TMROLE_NONE")
    assert(rows[6].roleText == "未标记", "Row 6 roleText should be '未标记'")

    Feature:ReleaseConsumer("test_t5_page")
end)

------------------------------------------------------------------------
-- Test 6: GearScore Inspection & Threshold Checking
------------------------------------------------------------------------
Test("T6: GearScore inspection & threshold checking", function()
    Feature:Enable("test_t6")
    Feature:AcquireConsumer("test_t6_page")
    Feature:ApplySettingRaw("minGearScore", 15000)
    Feature:ApplySettingRaw("requiredAuraIds", "")

    Roster.ordered = {
        { name = "HighGear", unitToken = "team_1_1", teamIndex = 1, memberIndex = 1 },
        { name = "LowGear", unitToken = "team_1_2", teamIndex = 1, memberIndex = 2 },
        { name = "UnreadableGear", unitToken = "team_1_3", teamIndex = 1, memberIndex = 3 },
    }
    Roster.members = {}
    for _, m in ipairs(Roster.ordered) do Roster.members[m.name] = m end

    -- High gear: 18,500 (with comma formatting from RU native)
    mockUnit.gearScores["team_1_1"] = "18,500"
    -- Low gear: 12,345
    mockUnit.gearScores["team_1_2"] = "12,345"
    -- Unreadable: nil
    mockUnit.gearScores["team_1_3"] = nil

    Feature:RunScan("gear_test")
    local taskName = "raid_readiness_scan_" .. tostring(Authority.scan.generation)
    S.Scheduler.tasks[taskName].callback()

    local rows = Authority.rows
    assert(#rows == 3, "Should have 3 rows")

    -- High gear passes
    assert(rows[1].name == "HighGear", "Row 1 mismatch")
    assert(rows[1].gearScore == 18500, "Row 1 gearScore should be 18500")
    assert(rows[1].gearText == "18500", "Row 1 gearText should be '18500'")
    assert(rows[1].status == "ready", "Row 1 status should be ready")
    assert(rows[1].tone == "green", "Row 1 tone should be green")

    -- Low gear fails
    assert(rows[2].name == "LowGear", "Row 2 mismatch")
    assert(rows[2].gearScore == 12345, "Row 2 gearScore should be 12345")
    assert(rows[2].status == "failed", "Row 2 status should be failed")
    assert(rows[2].tone == "red", "Row 2 tone should be red")
    assert(rows[2].detailText:find("装分不足 12345/15000") ~= nil, "Detail text must report gear deficit")

    -- Unreadable gear is unknown
    assert(rows[3].name == "UnreadableGear", "Row 3 mismatch")
    assert(rows[3].gearScore == nil, "Row 3 gearScore should be nil")
    assert(rows[3].gearText == "—", "Row 3 gearText should be '—'")
    assert(rows[3].status == "unknown", "Row 3 status should be unknown")
    assert(rows[3].tone == "warn", "Row 3 tone should be warn")
    assert(rows[3].detailText:find("装分不可读") ~= nil, "Detail text must report gear unreadable")

    Feature:ReleaseConsumer("test_t6_page")
end)

------------------------------------------------------------------------
-- Test 7: Aura Observation & Required Buff Evaluation
------------------------------------------------------------------------
Test("T7: Aura observation & required buff evaluation", function()
    Feature:Enable("test_t7")
    Feature:AcquireConsumer("test_t7_page")
    Feature:ApplySettingRaw("minGearScore", 0)
    Feature:ApplySettingRaw("requiredAuraIds", "30098, 30137")

    Roster.ordered = {
        { name = "FullBuffs", unitToken = "team_1_1", teamIndex = 1, memberIndex = 1 },
        { name = "MissingBuffs", unitToken = "team_1_2", teamIndex = 1, memberIndex = 2 },
        { name = "BrokenAura", unitToken = "team_1_3", teamIndex = 1, memberIndex = 3 },
    }
    Roster.members = {}
    for _, m in ipairs(Roster.ordered) do Roster.members[m.name] = m end

    -- Mock Aura observation snapshots
    local originalGetSnapshot = Aura.GetSnapshot
    Aura.GetSnapshot = function(self, token, options)
        if token == "team_1_1" then
            -- Has 30098 and 30137
            return {
                buff = {
                    available = true,
                    complete = true,
                    reliable = true,
                    rows = { { effectId = 30098, data = { buff_id = 30098 } }, { effectId = 30137, data = { buff_id = 30137 } } },
                },
            }
        elseif token == "team_1_2" then
            -- Has only 30098, missing 30137
            return {
                buff = {
                    available = true,
                    complete = true,
                    reliable = true,
                    rows = { { effectId = 30098, data = { buff_id = 30098 } } },
                },
            }
        elseif token == "team_1_3" then
            -- Snapshot returns nil (broken)
            return nil
        end
        return { buff = { available = true, complete = true, reliable = true, rows = {} } }
    end

    -- RunScan: requiredAuraIds present -> batchSize is 1
    local okScan = Feature:RunScan("aura_test")
    assert(okScan == true, "RunScan failed")
    assert(Feature.auraHeld == true, "Aura lease must be held during scan")

    -- Sliced execution: 3 members with batchSize 1 -> 3 scheduler ticks
    for slice = 1, 3 do
        local taskName = "raid_readiness_scan_" .. tostring(Authority.scan.generation)
        local task = S.Scheduler.tasks[taskName]
        assert(task ~= nil, "Scheduler task missing on slice " .. tostring(slice))
        task.callback()
    end

    assert(Authority:IsScanning() == false, "Scan should be complete")
    assert(Feature.auraHeld == false, "Aura lease must be released after scan completion")

    local rows = Authority.rows
    assert(#rows == 3, "Should have 3 rows")

    -- FullBuffs passes
    assert(rows[1].name == "FullBuffs", "Row 1 mismatch")
    assert(rows[1].status == "ready", "Row 1 status should be ready")
    assert(rows[1].auraText == "齐全 2/2", "Row 1 auraText should be '齐全 2/2'")

    -- MissingBuffs fails
    assert(rows[2].name == "MissingBuffs", "Row 2 mismatch")
    assert(rows[2].status == "failed", "Row 2 status should be failed")
    assert(rows[2].auraText == "缺 1", "Row 2 auraText should be '缺 1'")
    assert(#rows[2].missingAuraIds == 1 and rows[2].missingAuraIds[1] == 30137, "missingAuraIds should contain 30137")
    assert(rows[2].detailText:find("缺增益 30137") ~= nil, "detailText should mention missing 30137")

    -- BrokenAura is unknown
    assert(rows[3].name == "BrokenAura", "Row 3 mismatch")
    assert(rows[3].status == "unknown", "Row 3 status should be unknown")
    assert(rows[3].auraText == "待确认", "Row 3 auraText should be '待确认'")
    assert(rows[3].detailText:find("增益扫描不完整") ~= nil, "detailText should mention incomplete aura scan")

    -- Restore original method
    Aura.GetSnapshot = originalGetSnapshot
    Feature:ReleaseConsumer("test_t7_page")
end)

------------------------------------------------------------------------
-- Test 8: Distance Observation & Multi-Metric Aggregation
------------------------------------------------------------------------
Test("T8: Distance observation & multi-metric aggregation", function()
    Feature:Enable("test_t8")
    Feature:AcquireConsumer("test_t8_page")
    Feature:ApplySettingRaw("minGearScore", 10000)
    Feature:ApplySettingRaw("requiredAuraIds", "")

    Roster.ordered = {
        { name = "NearMember", unitToken = "team_1_1", teamIndex = 1, memberIndex = 1 },
        { name = "FarMember", unitToken = "team_1_2", teamIndex = 1, memberIndex = 2 },
        { name = "UnknownDistMember", unitToken = "team_1_3", teamIndex = 1, memberIndex = 3 },
    }
    Roster.members = {}
    for _, m in ipairs(Roster.ordered) do Roster.members[m.name] = m end

    mockUnit.gearScores["team_1_1"] = "12000"
    mockUnit.gearScores["team_1_2"] = "12000"
    mockUnit.gearScores["team_1_3"] = "12000"

    mockUnit.distances["team_1_1"] = 5.2
    mockUnit.distances["team_1_2"] = 48.7
    mockUnit.distances["team_1_3"] = -1 -- invalid / out of range

    Feature:RunScan("dist_test")
    local taskName = "raid_readiness_scan_" .. tostring(Authority.scan.generation)
    S.Scheduler.tasks[taskName].callback()

    local rows = Authority.rows
    assert(#rows == 3, "Should have 3 rows")

    assert(rows[1].distance == 5.2, "Row 1 distance mismatch")
    assert(rows[1].distanceText == "5.2m", "Row 1 distanceText mismatch: " .. tostring(rows[1].distanceText))

    assert(rows[2].distance == 48.7, "Row 2 distance mismatch")
    assert(rows[2].distanceText == "48.7m", "Row 2 distanceText mismatch: " .. tostring(rows[2].distanceText))

    assert(rows[3].distance == nil, "Row 3 distance should be nil for negative distance")
    assert(rows[3].distanceText == "—", "Row 3 distanceText should be '—'")

    -- Check aggregation tone and status
    -- All 3 members have gearScore 12000 >= 10000 and distance is not a failure criterion
    assert(rows[1].status == "ready", "Row 1 should be ready")
    assert(rows[1].tone == "green", "Row 1 tone should be green")

    Feature:ReleaseConsumer("test_t8_page")
end)

------------------------------------------------------------------------
-- Test 9: Paging, Filtering & PageHost Integration
------------------------------------------------------------------------
Test("T9: Paging, filtering & PageHost integration", function()
    Feature:Enable("test_t9")
    Feature:AcquireConsumer("test_t9_page")
    Feature:ApplySettingRaw("minGearScore", 15000)
    Feature:ApplySettingRaw("requiredAuraIds", "")

    Roster.ordered = {
        { name = "PassOne", unitToken = "team_1_1", teamIndex = 1, memberIndex = 1 },
        { name = "FailTwo", unitToken = "team_1_2", teamIndex = 1, memberIndex = 2 },
        { name = "UnknownThree", unitToken = "team_1_3", teamIndex = 1, memberIndex = 3 },
    }
    Roster.members = {}
    for _, m in ipairs(Roster.ordered) do Roster.members[m.name] = m end

    mockUnit.gearScores["team_1_1"] = "20000" -- pass
    mockUnit.gearScores["team_1_2"] = "8000"  -- fail
    mockUnit.gearScores["team_1_3"] = nil     -- unknown

    Feature:RunScan("filter_test")
    local taskName = "raid_readiness_scan_" .. tostring(Authority.scan.generation)
    S.Scheduler.tasks[taskName].callback()

    -- 1. All rows: GetRows(false)
    local allRows, rev = Feature:GetRows(false)
    assert(#allRows == 3, "GetRows(false) should return all 3 rows")

    -- 2. Show only issues: GetRows(true)
    local issueRows, _ = Feature:GetRows(true)
    assert(#issueRows == 2, "GetRows(true) should return 2 rows (failed + unknown)")
    assert(issueRows[1].status == "failed", "First issue should be failed")
    assert(issueRows[2].status == "unknown", "Second issue should be unknown")

    -- 3. GetRow by key
    local singleRow = Feature:GetRow(allRows[1].key)
    assert(singleRow ~= nil, "GetRow by key should return member")
    assert(singleRow.name == "PassOne", "GetRow name mismatch")

    -- 4. GetSummary
    local summary = Feature:GetSummary()
    assert(summary.total == 3, "summary.total should be 3")
    assert(summary.ready == 1, "summary.ready should be 1")
    assert(summary.failed == 1, "summary.failed should be 1")
    assert(summary.unknown == 1, "summary.unknown should be 1")
    assert(summary.scanning == false, "summary.scanning should be false")

    -- 5. PageHost Integration
    local factory = S.UIV3.PageHost.factories["combat.raid_readiness"]
    assert(type(factory) == "function", "PageHost factory for combat.raid_readiness missing")

    local fakeParent = S.UI:CreatePanel(UIParent, "fake_parent", 0, 0, 800, 600)
    local pageRoot, pageErr = factory(fakeParent, "combat.raid_readiness")
    assert(pageRoot ~= nil, "Page instantiation failed: " .. tostring(pageErr))
    assert(type(pageRoot.Refresh) == "function", "pageRoot.Refresh missing")
    assert(type(pageRoot.OnActivated) == "function", "pageRoot.OnActivated missing")
    assert(type(pageRoot.OnDeactivated) == "function", "pageRoot.OnDeactivated missing")

    -- Refresh page
    local okRefresh = pageRoot:Refresh()
    assert(okRefresh == true, "pageRoot:Refresh() failed")

    Feature:ReleaseConsumer("test_t9_page")
end)

------------------------------------------------------------------------
-- Test 10: FoundationGate & Acceptance Contracts
------------------------------------------------------------------------
Test("T10: FoundationGate & Acceptance contracts", function()
    -- 1. Acceptance Sequence Case
    local seqFn = S.FoundationGate.sequenceCases and S.FoundationGate.sequenceCases["v3_m16_14_raid_readiness_contract"]
    assert(type(seqFn) == "function", "Sequence case v3_m16_14_raid_readiness_contract missing")
    local okSeq, seqErr = seqFn()
    assert(okSeq == true, "Acceptance sequence case failed: " .. tostring(seqErr))

    -- 2. FoundationGate contract clause assertions
    local readiness = S.Features and S.Features.RaidReadiness or nil
    local readinessMeta = S.FeatureRegistry and S.FeatureRegistry:Get("combat_raid_readiness") or nil
    local readinessStore = S.Persistence and type(S.Persistence.GetStore) == "function" and S.Persistence:GetStore("v3.raid_readiness") or nil
    local readinessPage = S.UIV3 and S.UIV3.PageHost and S.UIV3.PageHost.factories and S.UIV3.PageHost.factories["combat.raid_readiness"] or nil
    local teamNative = S.NativeContract and type(S.NativeContract.GetApi) == "function" and S.NativeContract:GetApi("TEAM") or nil

    local contractOk = readiness ~= nil and type(readiness.Authority) == "table"
        and (tonumber(readiness.Authority.version) or 0) >= 1 and type(readiness.RunScan) == "function"
        and type(readiness.Authority.StartScan) == "function" and type(readiness.Authority.CancelScan) == "function"
        and type(readiness.Commands) == "table" and type(readiness.Commands.ApplySettingFromBinding) == "function"
        and type(readiness.Commands.MarkStoreDirty) == "function"
        and readiness.Demand ~= nil and readinessStore ~= nil and readinessPage ~= nil
        and readinessMeta ~= nil and tostring(readinessMeta.status) == "migrated_m16_14"
        and tostring(readinessMeta.lifecycle) == "on_demand_scan"
        and type(teamNative) == "table" and tonumber(teamNative.id) == 38
    assert(contractOk, "raid_readiness_v3_contract clauses must pass")

    -- 3. Runtime Scope check (dormancy invariant)
    local readinessHealth = readiness and type(readiness.GetHealth) == "function" and readiness:GetHealth() or nil
    assert(readinessHealth ~= nil, "readinessHealth missing")
    local scopeOk = ((tonumber(readinessHealth.consumers) or 0) > 0 or (readinessHealth.rosterHeld ~= true and readinessHealth.auraHeld ~= true and readinessHealth.scanning ~= true))
        and (readinessHealth.scanning ~= true or readinessHealth.rosterHeld == true)
        and (readinessHealth.auraHeld ~= true or readinessHealth.scanning == true)
    assert(scopeOk, "raid_readiness_runtime_scope dormancy clauses must pass")
end)

print(string.format("\nTeam Raid Readiness Test Results: %d/%d passed", passed, total))
if passed == total then
    print("ALL TESTS PASSED!")
else
    print("SOME TESTS FAILED!")
    os.exit(1)
end

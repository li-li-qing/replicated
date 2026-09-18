-- Maintenance: comprehensive regression suite for Activity feature, authority, store,
-- live zone mapping (Whalesong/Aegis), taskTailMinutes, and floating widget lifecycle.
local pass, fail = 0, 0
local function Test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then
        pass = pass + 1
        print("PASS activity " .. name)
    else
        fail = fail + 1
        print("FAIL activity " .. name .. ": " .. tostring(err))
    end
end

local function ActivityBoot(options)
    options = options or {}
    local h = dofile("tools/rs_gear_page_test_host.lua")(options)
    local S = h.S
    S.UI.CreateWindowShell = function()
        return {
            SetTitle = function() end,
            SetFooter = function() end,
            SetMinSize = function() end,
            SetMaxSize = function() end,
            SetResizable = function() end,
            SetCloseHandler = function() end,
            SetMinimizeHandler = function() end,
            SetLockHandler = function() end,
            SetOpacity = function() end,
            SetMinimized = function() end,
            SetLocked = function() end,
            SetExtent = function() end,
            Show = function() end,
            Hide = function() end,
        }
    end
    dofile("core/rs_demand.lua")
    dofile("ui/framework/rs_ui_floating_surface.lua")
    dofile("data/rs_data_registry.lua")
    dofile("data/ids/rs_quest_ids.lua")
    dofile("data/ids/rs_instance_ids.lua")
    dofile("data/rs_event_data.lua")
    dofile("data/rs_quest_data.lua")

    X2Map = {
        GetZoneStateInfoByZoneId = function(_, zoneId)
            if options.failZoneScan then return nil end
            return {
                conflictState = options.zoneState or 6, -- WAR
                remainTime = options.remainTime or 3600,
            }
        end,
    }

    S.Services.InstanceCatalogV3 = {
        GetHealth = function() return { running = true, consumers = 1 } end,
        GetEntryProgress = function() return { available = true, completed = 0, total = 1, text = "0/1" } end,
        AcquireConsumer = function() return true end,
        ReleaseConsumer = function() return true end,
    }

    local questProgressData = {
        whalesong = { text = "1/3", tone = "yellow", tailInFlightCount = 1 },
        aegis = { text = "2/3", tone = "green", tailInFlightCount = 0 },
        crimson = { text = "3/6", tone = "yellow", tailInFlightCount = options.crimsonTailInFlight or 0 },
        ghost = { text = "0/4", tone = "muted", tailInFlightCount = 0 },
    }
    S.Services.QuestProgressV3 = {
        GetHealth = function() return { running = true, consumers = 1, instanceDemand = true } end,
        GetQuestProgress = function(_, scope, key) return questProgressData[key] end,
        GetInstanceProgress = function(_, scope, key) return { text = "0/1", tone = "muted" } end,
        GetGroupDetail = function(_, scope, key, opts)
            return {
                title = "详情:" .. tostring(key),
                summaryText = "摘要测试",
                children = { { key = "c1", category = "主线", name = "阶段一", status = "完成" } }
            }
        end,
        AcquireConsumer = function() return true end,
        ReleaseConsumer = function() return true end,
    }

    S.UIV3 = S.UIV3 or {}
    S.UIV3.QuestDetailModalV3 = { Open = function() return true end }
    S.UIV3.QuestDetailFloatingV3 = {
        Open = function(_, scope, key, sourceRow)
            h.lastDetailOpen = { scope = scope, key = key, row = sourceRow }
            return true
        end
    }

    dofile("features/life/activities/rs_activity_store.lua")
    dofile("features/life/activities/rs_activity_authority.lua")
    dofile("features/life/activities/rs_activity_feature.lua")
    dofile("features/life/activities/rs_activity_acceptance.lua")

    UIParent = UIParent or {}
    UIParent.GetServerTimeTable = function()
        return options.serverTime or {
            year = 2026,
            month = 9,
            day = 13, -- Sunday
            hour = 12,
            minute = 0,
            second = 0,
        }
    end

    local F = S.Features.Activities
    assert(F, "S.Features.Activities is nil!")
    assert(F:EnsureStoreLoaded())
    assert(F:Initialize())
    assert(F:Enable("test_boot"))
    return S, F, h
end

Test("feature metadata and contracts exist", function()
    local S, F, h = ActivityBoot()
    assert(F.Id == "life_activities")
    assert(F.PersistenceStoreSchemaContractVersion == 8)
    assert(F.PersistenceWindowCanonicalContractVersion == 1)
    assert(F.KnownLegacyCanonicalRecoveryContractVersion >= 1)
    assert(type(F.Commands) == "table")
    assert(type(F.Commands.MarkStoreDirty) == "function")
    assert(type(F.Commands.SetWidgetWindowState) == "function")
end)

Test("live zone rows include whalesong and aegis with valid quest keys", function()
    local S, F, h = ActivityBoot()
    assert(F.Authority:ScanTrackedZones())
    assert(F.Authority:Refresh("test"))
    local rows = F.Authority:GetRows()
    local foundWhalesong, foundAegis = false, false
    for _, row in ipairs(rows) do
        if row.zoneId == 103 then
            foundWhalesong = true
            assert(row.questKey == "whalesong", "whalesong questKey missing: " .. tostring(row.questKey))
            assert(row.questScope == "event", "whalesong questScope missing")
            assert(row.progressText == "1/3", "whalesong progressText missing: " .. tostring(row.progressText))
        elseif row.zoneId == 102 then
            foundAegis = true
            assert(row.questKey == "aegis", "aegis questKey missing: " .. tostring(row.questKey))
            assert(row.questScope == "event", "aegis questScope missing")
            assert(row.progressText == "2/3", "aegis progressText missing: " .. tostring(row.progressText))
        end
    end
    assert(foundWhalesong, "Whalesong zone 103 not found in rows")
    assert(foundAegis, "Aegis zone 102 not found in rows")
end)

Test("activating live zone row opens QuestDetailFloating with correct questKey", function()
    local S, F, h = ActivityBoot()
    assert(F.Authority:ScanTrackedZones())
    assert(F.Authority:Refresh("test"))
    local row = F.Authority:GetRow("zone:103")
    assert(row ~= nil, "zone:103 row not found")
    local ok = S.UIV3.QuestDetailFloatingV3:Open(row.questScope or "event", row.questKey, row)
    assert(ok == true)
    assert(h.lastDetailOpen ~= nil)
    assert(h.lastDetailOpen.key == "whalesong")
    assert(h.lastDetailOpen.scope == "event")
end)

Test("taskTailMinutes keeps event active when tailInFlightCount > 0", function()
    -- Mock server time to 12:45 (start was 12:20, duration 10m -> ended 12:30, tail until 13:50)
    -- Crimson Rift runs at 12:20 on all days. At 12:45, elapsed is 25m.
    -- Without tail: elapsed (25m) >= duration (10m) -> inactive.
    -- With tail (tailInFlightCount=1): tailDuration is 90m -> active!
    local S, F, h = ActivityBoot({ crimsonTailInFlight = 1 })
    -- Set server clock anchor at Sunday 12:45:00
    -- day 1 (Sunday), hour 12, minute 45
    F.Authority.clockAnchor = {
        weekSeconds = (0 * 86400) + (12 * 3600) + (45 * 60),
        atMs = h.ms,
        dateSerial = 739000,
        daySeconds = (12 * 3600) + (45 * 60),
    }
    F.Authority.lastClockSampleAtMs = h.ms
    assert(F.Authority:Refresh("test_tail"))
    local crimsonRow = F.Authority:GetRow("event:征兆之痕")
    assert(crimsonRow ~= nil, "crimson row not found")
    assert(crimsonRow.active == true, "crimson should be active during tail in flight")
    assert(crimsonRow.tone == "default", "ordinary scheduled activity time must stay white during active tail")
    assert(not tostring(crimsonRow.status or ""):find("进行中", 1, true), "ordinary activity status must not show 进行中")
    -- 90m - 25m = 65m = 1时5分
    assert(crimsonRow.seconds == 65 * 60, "remaining tail seconds should be 65m, got: " .. tostring(crimsonRow.seconds))
end)


Test("activity status text removes 进行中 and zone tones encode only semantic state", function()
    local cases = {
        { state = 6, tone = "red", word = "战争" },
        { state = 5, tone = "orange", word = "纷争" },
        { state = 7, tone = "blue", word = "和平" },
    }
    for _, case in ipairs(cases) do
        local S, F, h = ActivityBoot({ zoneState = case.state, remainTime = 1800 })
        assert(F.Authority:ScanTrackedZones())
        assert(F.Authority:Refresh("semantic_tone"))
        local found = false
        for _, row in ipairs(F.Authority:GetRows()) do
            assert(not tostring(row.status or ""):find("进行中", 1, true), "activity UI status leaked 进行中: " .. tostring(row.status))
            if row.zoneState == true and tostring(row.status or ""):find(case.word, 1, true) then
                found = true
                assert(row.tone == case.tone, case.word .. " tone expected " .. case.tone .. " got " .. tostring(row.tone))
            elseif row.zoneState ~= true then
                assert(row.tone == "default", "ordinary activity time must be white/default: " .. tostring(row.name) .. "/" .. tostring(row.tone))
            end
        end
        assert(found, "missing semantic zone row for " .. case.word)
    end
end)

Test("special boss countdown keeps war semantic red", function()
    -- 中文维护注释（2026-09-15）：103 特殊首领倒计时仍发生在 WAR 状态内；
    -- UI 规范以区域语义为颜色 Authority，因此不能再用黄色覆盖战争红色。
    local S, F, h = ActivityBoot({ zoneState = 6, remainTime = 80 * 60 })
    assert(F.Authority:ScanTrackedZones())
    assert(F.Authority:Refresh("war_boss_tone"))
    local row = assert(F.Authority:GetRow("zone:103"), "missing zone 103 special boss countdown row")
    assert(not tostring(row.status or ""):find("战争", 1, true), "test fixture did not enter special boss countdown band")
    assert(row.tone == "red", "WAR special boss countdown must remain red, got " .. tostring(row.tone))
end)

Test("whalesong and aegis stages sort after <=3h activities but before >3h activities", function()
    -- 中文维护测试（2026-09-16）：鲸鱼/烛台的“阶段”既可能是带 remainTime 的战争/纷争，
    -- 也可能是没有倒计时的危险1~5阶段。排序 Authority 必须按业务阶段身份分带，而不能只看 sortSeconds。
    -- 产品规则：普通进行中最前；普通 <=3h；鲸鱼/烛台已知阶段；普通 >3h；最后才是其它无时限状态。
    for _, zoneState in ipairs({ 6, 2 }) do -- WAR timed + TROUBLE_2 untimed
        local S, F, h = ActivityBoot({ zoneState = zoneState, remainTime = 60 * 60 })
        assert(F.Authority:ScanTrackedZones())
        assert(F.Authority:Refresh("priority_band:" .. tostring(zoneState)))
        local rows = F.Authority:GetRows()
        local specialPositions, shortOrdinaryPositions, longOrdinaryPositions = {}, {}, {}
        for index, row in ipairs(rows) do
            local seconds = tonumber(row.sortSeconds)
            local isTimed = seconds ~= nil and seconds ~= math.huge
            local isSpecial = tonumber(row.zoneId) == 102 or tonumber(row.zoneId) == 103
            if isSpecial and row.phaseKnown == true then
                specialPositions[#specialPositions + 1] = index
            elseif isTimed and row.active ~= true and seconds <= 3 * 60 * 60 then
                shortOrdinaryPositions[#shortOrdinaryPositions + 1] = index
            elseif isTimed and row.active ~= true and seconds > 3 * 60 * 60 then
                longOrdinaryPositions[#longOrdinaryPositions + 1] = index
            end
        end
        assert(#specialPositions == 2, "fixture must expose both known Whalesong and Aegis stages for state " .. tostring(zoneState))
        assert(#shortOrdinaryPositions > 0, "fixture needs at least one <=3h ordinary activity")
        assert(#longOrdinaryPositions > 0, "fixture needs at least one >3h ordinary activity")
        local firstSpecial = math.min(unpack(specialPositions))
        local lastSpecial = math.max(unpack(specialPositions))
        local lastShort = math.max(unpack(shortOrdinaryPositions))
        local firstLong = math.min(unpack(longOrdinaryPositions))
        assert(lastShort < firstSpecial, "all <=3h ordinary activities must sort before Whalesong/Aegis stages; state=" .. tostring(zoneState))
        assert(lastSpecial < firstLong, "Whalesong/Aegis stages must sort before every >3h ordinary activity; state=" .. tostring(zoneState))
    end
end)

Test("demand acquisition starts and releases scheduler tasks", function()
    local S, F, h = ActivityBoot()
    assert(F.Demand.count == 0)
    assert(F.consumerCount == 0)
    local timerTask = S.Scheduler.tasks[F.timerTask]
    local zoneTask = S.Scheduler.tasks[F.zoneTask]
    assert(timerTask.enabled == false)
    assert(zoneTask.enabled == false)

    assert(F:AcquireConsumer("test_consumer"))
    assert(F.Demand.count == 1)
    assert(F.consumerCount == 1)
    assert(timerTask.enabled == true)
    assert(zoneTask.enabled == true)

    assert(F:ReleaseConsumer("test_consumer"))
    assert(F.Demand.count == 0)
    assert(F.consumerCount == 0)
    assert(timerTask.enabled == false)
    assert(zoneTask.enabled == false)
end)

Test("hide and restore events persists properly", function()
    local S, F, h = ActivityBoot()
    assert(F.Authority:Refresh("test"))
    local initialRows = F.Authority:GetRows()
    local initialCount = #initialRows

    -- Hide Grimghast Rift
    local hideOk, hideErr = F.Commands:HideEvent("event:迷雾战争")
    assert(hideOk == true, "HideEvent failed: " .. tostring(hideErr))
    local hiddenRows = F.Authority:GetRows()
    assert(#hiddenRows == initialCount - 1, "row count should decrease by 1")
    assert(F.Authority:GetRow("event:迷雾战争") == nil, "hidden event should not be in rows")

    -- Restore
    local restoreOk, restoreErr = F.Commands:RestoreHiddenEvents()
    assert(restoreOk == true, "RestoreHiddenEvents failed: " .. tostring(restoreErr))
    local restoredRows = F.Authority:GetRows()
    assert(#restoredRows == initialCount, "row count should be restored")
    assert(F.Authority:GetRow("event:迷雾战争") ~= nil, "restored event should be back in rows")
end)

Test("store schema 8 normalization and window persistence", function()
    local S, F, h = ActivityBoot()
    local initialWrites = h.writes
    local ok, err = F.Commands:SetWidgetSize(500, 320, "test_resize")
    assert(ok == true, "SetWidgetSize failed: " .. tostring(err))
    assert(F:GetWidgetWindowState().width == 500)
    assert(F:GetWidgetWindowState().height == 320)
    assert(S.Persistence:Flush(F.StoreId))
    assert(h.writes > initialWrites, "store should be flushed to disk")
end)

print(string.format("ACTIVITY SUITE RESULT: %d passed, %d failed", pass, fail))
if fail > 0 then error("activity suite failures: " .. fail) end

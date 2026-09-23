-- 维护（2026-09-18，startup-source-recovery）：本文件在故障包中有 3 处未解决的 Git 合并冲突。
-- 已对照用户此前完整 V3 工程恢复有效实现；Authority、调用数据流和存档协议仍由下方原实现负责，
-- 不通过清配置、跳过加载或恢复 Legacy 绕过错误。兼容边界：须与完整 toc.g 及 .18.247 UI 配套；
-- 后续合并必须先检查冲突标记、清单完整性与 Lua 语法，再做运行时验收；注释不增加运行期开销。
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
    assert((tonumber(F.Authority and F.Authority.ActivityTimelineSortContractVersion) or 0) >= 2, "Activity Timeline v2 contract missing")
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
    assert(crimsonRow.tone == "red", "active scheduled activity must render red during active tail")
    assert(not tostring(crimsonRow.status or ""):find("进行中", 1, true), "ordinary activity status must not show 进行中")
    -- 90m - 25m = 65m = 1时5分
    assert(crimsonRow.seconds == 65 * 60, "remaining tail seconds should be 65m, got: " .. tostring(crimsonRow.seconds))
end)


Test("activity status text removes 进行中 while timeline active is red and live zones keep semantic tones", function()
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
                local untilStart = tonumber(row.secondsUntilStart) or tonumber(row.seconds) or math.huge
                local expected = (row.active == true or (untilStart > 0 and untilStart <= 600)) and "red" or "default"
                assert(row.tone == expected, "timeline tone mismatch for " .. tostring(row.name) .. ": expected " .. expected .. " got " .. tostring(row.tone))
            end
        end
        assert(found, "missing semantic zone row for " .. case.word)
    end
end)

Test("upcoming timeline turns red at ten minutes and stays default above ten minutes", function()
    -- 2026-09-19 UI policy: upcoming activities inside the final 10 minutes are urgent and must be red.
    -- Authority owns this threshold so Activity page / Home / floating widget consume one consistent row.tone.
    local S, F, h = ActivityBoot()

    F.Authority.clockAnchor = {
        weekSeconds = (0 * 86400) + (12 * 3600) + (10 * 60),
        atMs = h.ms, dateSerial = 739000, daySeconds = (12 * 3600) + (10 * 60),
        absolute = 739000 * 86400 + (12 * 3600) + (10 * 60), precision = "second",
    }
    F.Authority.lastClockValidAtMs = h.ms
    F.Authority.lastClockSampleAtMs = h.ms
    F.Authority.lastClockSample = { absolute = F.Authority.clockAnchor.absolute, atMs = h.ms, changedAtMs = h.ms }
    assert(F.Authority:Refresh("ten_minute_urgent"))
    local atTen = assert(F.Authority:GetRow("event:征兆之痕"), "missing crimson row at 10m")
    assert(atTen.active ~= true, "10m row must still be upcoming")
    assert(atTen.secondsUntilStart == 600, "expected exactly 600s, got " .. tostring(atTen.secondsUntilStart))
    assert(atTen.tone == "red", "upcoming activity at 10m must be red")

    F.Authority.clockAnchor.weekSeconds = (0 * 86400) + (12 * 3600) + (9 * 60) + 59
    F.Authority.clockAnchor.daySeconds = (12 * 3600) + (9 * 60) + 59
    F.Authority.clockAnchor.absolute = 739000 * 86400 + F.Authority.clockAnchor.daySeconds
    F.Authority.lastClockSample.absolute = F.Authority.clockAnchor.absolute
    assert(F.Authority:Refresh("ten_minute_plus_one"))
    local overTen = assert(F.Authority:GetRow("event:征兆之痕"), "missing crimson row at 10m01s")
    assert(overTen.secondsUntilStart == 601, "expected 601s, got " .. tostring(overTen.secondsUntilStart))
    assert(overTen.tone == "default", "upcoming activity above 10m must stay default")
end)

Test("whalesong boss becomes a timed timeline occurrence while live row keeps war semantics", function()
    -- Activity Timeline v2：区域状态与可计算的活动时间点必须拆开。103 仍在 WAR，
    -- live row 只描述战争；Boss 倒计时作为独立 dynamic occurrence 进入时间线。
    local S, F, h = ActivityBoot({ zoneState = 6, remainTime = 80 * 60 })
    assert(F.Authority:ScanTrackedZones())
    assert(F.Authority:Refresh("war_boss_timeline"))
    local live = assert(F.Authority:GetRow("zone:103"), "missing zone 103 live row")
    assert(live.presentationSection == "live", "Whalesong zone row must stay in live section")
    assert(tostring(live.status or ""):find("战争", 1, true), "live row must keep WAR semantic text")
    assert(live.tone == "red", "WAR live row must remain red")
    local boss = assert(F.Authority:GetRow("dynamic:zone:103:whalesong_boss"), "missing Whalesong boss timeline occurrence")
    assert(boss.presentationSection == "timeline")
    assert(boss.timelineState == "upcoming")
    assert(boss.secondsUntilStart == 3 * 60, "Boss should start in 3m after RU live calibration, got " .. tostring(boss.secondsUntilStart))
    assert(boss.tone == "red", "3m upcoming boss must use urgent red tone")
end)

Test("whalesong boss flips active at 77m war remainder and stays active until 76m", function()
    -- 2026-09-19 RU live observation: the old 76m trigger was one minute late.
    -- Keep this as a server-calibration regression: at 76m30s the Boss has already spawned,
    -- so the projection must be active rather than still claiming a future countdown.
    local S, F, h = ActivityBoot({ zoneState = 6, remainTime = (76 * 60) + 30 })
    assert(F.Authority:ScanTrackedZones())
    assert(F.Authority:Refresh("whalesong_live_calibration"))
    local boss = assert(F.Authority:GetRow("dynamic:zone:103:whalesong_boss"), "missing calibrated Whalesong boss occurrence")
    assert(boss.timelineState == "active", "76m30s should already be active, got " .. tostring(boss.timelineState))
    assert(boss.secondsUntilEnd == 30, "active band should end at 76m remainder, got " .. tostring(boss.secondsUntilEnd))
end)

Test("timeline rows sort purely by temporal semantics and always precede live state rows", function()
    local S, F, h = ActivityBoot({ zoneState = 6, remainTime = 60 * 60 })
    assert(F.Authority:ScanTrackedZones())
    assert(F.Authority:Refresh("timeline_v2_sort"))
    local rows = F.Authority:GetRows()
    local sawLive = false
    local previousUpcoming = -1
    local previousActiveEnd = -1
    local inUpcoming = false
    local timelineCount, liveCount = 0, 0
    for _, row in ipairs(rows) do
        if row.presentationSection == "live" then
            sawLive = true
            liveCount = liveCount + 1
        else
            assert(row.presentationSection == "timeline", "unexpected projection section: " .. tostring(row.presentationSection))
            assert(not sawLive, "timeline row appeared after live-state section: " .. tostring(row.key))
            timelineCount = timelineCount + 1
            if row.timelineState == "active" then
                assert(not inUpcoming, "active timeline row appeared after upcoming row")
                local remain = assert(tonumber(row.secondsUntilEnd), "active row missing secondsUntilEnd")
                assert(remain >= previousActiveEnd, "active rows must sort by time-to-end")
                previousActiveEnd = remain
            else
                inUpcoming = true
                assert(row.timelineState == "upcoming", "timeline row missing upcoming state")
                local start = assert(tonumber(row.secondsUntilStart), "upcoming row missing secondsUntilStart")
                assert(start >= previousUpcoming, "upcoming rows must sort by time-to-start")
                previousUpcoming = start
            end
        end
    end
    assert(timelineCount > 0, "timeline section empty")
    assert(liveCount >= #(S.Data.ZoneStateWatch or {}), "live section incomplete")
end)

Test("aegis conflict derives an upcoming timeline occurrence without moving its live-state row", function()
    local S, F, h = ActivityBoot({ zoneState = 5, remainTime = 30 * 60 }) -- BATTLE / 纷争
    assert(F.Authority:ScanTrackedZones())
    assert(F.Authority:Refresh("aegis_dynamic_timeline"))
    local live = assert(F.Authority:GetRow("zone:102"), "missing Aegis live row")
    assert(live.presentationSection == "live")
    assert(tostring(live.status or ""):find("纷争", 1, true), "Aegis live row must expose conflict state")
    local event = assert(F.Authority:GetRow("dynamic:zone:102:aegis"), "missing Aegis dynamic occurrence")
    assert(event.presentationSection == "timeline")
    assert(event.timelineState == "upcoming")
    assert(event.secondsUntilStart == 30 * 60)
    assert(event.questKey == "aegis")
end)

Test("cinderstone and ynystere conflict states derive purification timeline occurrences", function()
    -- timeUntil 值得借鉴的是把可计算的区域事件变成时间线 occurrence；我们只复用已有 5s zone snapshot，
    -- 不照搬它的 OnUpdate / Quest 扫描，也不在 WAR 后伪造 15 分钟计时。
    local S, F, h = ActivityBoot({ zoneState = 5, remainTime = 25 * 60 })
    assert(F.Authority:ScanTrackedZones())
    assert(F.Authority:Refresh("purify_dynamic_timeline"))
    local cinder = assert(F.Authority:GetRow("dynamic:zone:20:cinderstone_purify"), "missing Cinderstone purification occurrence")
    local ynys = assert(F.Authority:GetRow("dynamic:zone:17:ynystere_purify"), "missing Ynystere purification occurrence")
    assert(cinder.timelineState == "upcoming" and cinder.secondsUntilStart == 25 * 60)
    assert(ynys.timelineState == "upcoming" and ynys.secondsUntilStart == 25 * 60)
    assert(cinder.questKey == "cinderstone_purify")
    assert(ynys.questKey == "ynystere_purify")
    assert(F.Authority:GetRow("zone:20").presentationSection == "live")
    assert(F.Authority:GetRow("zone:17").presentationSection == "live")
end)

Test("garden migrates from timeline countdown to live row when war starts", function()
    -- 2026-09-19 product rule: Garden must never be duplicated across the two presentation sections.
    -- Before WAR, keep the authoritative countdown in the timeline so players can prepare for the four Garden bosses.
    -- Once Native zone state confirms WAR, remove that countdown occurrence and show Garden only in the live section.
    local S1, F1, h1 = ActivityBoot({ zoneState = 5, remainTime = 20 * 60 }) -- BATTLE / 20m until WAR
    assert(F1.Authority:ScanTrackedZones())
    assert(F1.Authority:Refresh("garden_prewar"))
    local upcoming = assert(F1.Authority:GetRow("dynamic:zone:133:garden_boss"), "Garden countdown missing before WAR")
    assert(upcoming.presentationSection == "timeline", "Garden pre-WAR row must be timeline")
    assert(upcoming.timelineState == "upcoming", "Garden pre-WAR row must be upcoming")
    assert(upcoming.secondsUntilStart == 20 * 60, "Garden pre-WAR countdown mismatch: " .. tostring(upcoming.secondsUntilStart))
    assert(F1.Authority:GetRow("zone:133:garden_boss") == nil, "Garden must not also appear in live section before WAR")

    -- Same Authority instance receives the next Native snapshot: verify the row actually migrates, not merely that cold boots differ.
    F1.Authority.zoneStates[133] = 6
    F1.Authority.zoneRemainSeconds[133] = 110 * 60
    F1.Authority.zoneObservedAtMs[133] = h1.ms
    assert(F1.Authority:Refresh("garden_war"))
    assert(F1.Authority:GetRow("dynamic:zone:133:garden_boss") == nil, "Garden countdown must disappear after WAR starts")
    local live = assert(F1.Authority:GetRow("zone:133:garden_boss"), "Garden live row missing during WAR")
    assert(live.presentationSection == "live", "Garden WAR row must be live")
    assert(live.active == true, "Garden live row must be active during WAR")
    assert(tostring(live.status or ""):find("战争", 1, true), "Garden WAR row must expose WAR status: " .. tostring(live.status))
    assert(live.seconds == 110 * 60, "Garden WAR remaining time mismatch: " .. tostring(live.seconds))
end)

Test("live-state rows keep curated zone order instead of being ranked by remaining time", function()
    local S, F, h = ActivityBoot({ zoneState = 6, remainTime = 60 * 60 })
    assert(F.Authority:ScanTrackedZones())
    assert(F.Authority:Refresh("live_order"))
    local live = F.Authority:GetLiveRows()
    local expected = { 20, 17, 103, 102 }
    for index, zoneId in ipairs(expected) do
        assert(live[index] ~= nil, "missing live row at index " .. tostring(index))
        assert(tonumber(live[index].zoneId) == zoneId, "live order changed at " .. tostring(index) .. ": " .. tostring(live[index].zoneId))
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

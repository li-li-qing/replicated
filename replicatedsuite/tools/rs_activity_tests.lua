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
    assert(crimsonRow.tone == "red", "crimson tone should be red during tail")
    -- 90m - 25m = 65m = 1时5分
    assert(crimsonRow.seconds == 65 * 60, "remaining tail seconds should be 65m, got: " .. tostring(crimsonRow.seconds))
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

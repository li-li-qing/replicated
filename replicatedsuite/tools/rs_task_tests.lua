-- Maintenance: comprehensive regression suite for Task Tracker (life.tasks)
-- feature, authority, store, tracking sets, expansion hierarchy, overview projection, and widget lifecycle.
local pass, fail = 0, 0
local function Test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then
        pass = pass + 1
        print("PASS task " .. name)
    else
        fail = fail + 1
        print("FAIL task " .. name .. ": " .. tostring(err))
    end
end

local function TaskBoot(options)
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

    local progressMap = options.progressMap or {
        guild = { completed = 1, total = 2, readyCount = 0, activeCount = 1, text = "1/2", available = true },
        family = { completed = 2, total = 2, readyCount = 0, activeCount = 0, text = "2/2", available = true },
        honor = { completed = 0, total = 1, readyCount = 1, activeCount = 0, text = "0/1", available = true },
        west_hiram = { completed = 0, total = 2, readyCount = 0, activeCount = 0, text = "0/2", available = true },
        east_hiram = { completed = 2, total = 2, readyCount = 0, activeCount = 0, text = "2/2", available = true },
        akasch = { completed = 0, total = 1, readyCount = 0, activeCount = 0, text = "0/1", available = true },
    }

    local questProgressConsumers = 0
    S.Services.QuestProgressV3 = {
        consumerCount = 0,
        GetHealth = function(_, scope)
            return { running = true, consumers = questProgressConsumers, projections = 6, available = 6, revision = 1 }
        end,
        GetProgress = function(_, scope, key)
            return progressMap[key] or { completed = 0, total = 1, readyCount = 0, activeCount = 0, text = "0/1", available = true }
        end,
        GetGroupDetail = function(_, scope, key, opts)
            return {
                title = "测试详情:" .. tostring(key),
                summaryText = "任务详情摘要",
                children = {
                    { key = "stage1", category = "主任务", name = "阶段一:探索", status = "已完成", tone = "green", questId = 1001, related = false },
                    { key = "stage2", category = "主任务", name = "阶段二:决战", status = "进行中", tone = "yellow", questId = 1002, related = false },
                },
            }
        end,
        AcquireConsumer = function()
            questProgressConsumers = questProgressConsumers + 1
            return true
        end,
        ReleaseConsumer = function()
            questProgressConsumers = math.max(0, questProgressConsumers - 1)
            return true
        end,
    }

    S.UIV3 = S.UIV3 or {}
    S.UIV3.QuestDetailFloatingV3 = {
        Open = function(_, scope, key, sourceRow)
            h.lastDetailOpen = { scope = scope, key = key, row = sourceRow }
            return true
        end,
    }

    dofile("features/life/tasks/rs_task_store.lua")
    dofile("features/life/tasks/rs_task_authority.lua")
    dofile("features/life/tasks/rs_task_feature.lua")
    dofile("features/life/tasks/rs_task_acceptance.lua")

    local F = S.Features.Tasks
    assert(F, "S.Features.Tasks unavailable")
    assert(F:EnsureStoreLoaded())
    assert(F:Initialize())
    assert(F:Enable("test_boot"))
    assert(F.Authority:Refresh("boot"))
    return S, F, h
end

Test("feature metadata and contracts exist", function()
    local S, F, h = TaskBoot()
    assert(F.Id == "life_tasks")
    assert(F.PersistenceCodecVersion == 2)
    assert(F.PersistenceMutationContractVersion == 2)
    assert(type(F.Commands) == "table")
    assert(type(F.Commands.ToggleTracked) == "function")
    assert(type(F.Commands.SetAllTracked) == "function")
    assert(type(F.Commands.ToggleExpanded) == "function")
    assert(type(F.Commands.SetWidgetWindowState) == "function")
end)

Test("daily and weekly group rows are isolated and non-empty", function()
    local S, F, h = TaskBoot()
    local dailyRows = F:GetRows("daily")
    local weeklyRows = F:GetRows("weekly")
    assert(#dailyRows > 0, "daily rows should not be empty")
    assert(#weeklyRows > 0, "weekly rows should not be empty")
    for _, row in ipairs(dailyRows) do
        assert(row.scope == "daily")
        assert(row.parent == true)
        assert(string.sub(row.id, 1, 6) == "daily:")
    end
    for _, row in ipairs(weeklyRows) do
        assert(row.scope == "weekly")
        assert(row.parent == true)
        assert(string.sub(row.id, 1, 7) == "weekly:")
    end
end)

Test("default tracking tracks all groups until explicitly configured", function()
    local S, F, h = TaskBoot()
    local dailyBucket = F:GetTracking("daily")
    assert(dailyBucket.configured == false, "initial daily tracking should be unconfigured")
    assert(F:IsTracked("daily", "guild") == true, "unconfigured daily should default to tracked")
    assert(F:IsTracked("weekly", "west_hiram") == true, "unconfigured weekly should default to tracked")
end)

Test("individual tracking toggle strictly scopes to daily vs weekly", function()
    local S, F, h = TaskBoot()
    -- Untrack daily guild
    assert(F:SetTracked("daily", "guild", false, "test"))
    assert(F:IsTracked("daily", "guild") == false, "daily guild should be untracked")
    assert(F:GetTracking("daily").configured == true, "daily should now be configured")

    -- Weekly west_hiram remains tracked and unmutated
    assert(F:IsTracked("weekly", "west_hiram") == true, "weekly tracking should remain untouched")
    assert(F:GetTracking("weekly").configured == false, "weekly tracking should still be unconfigured")

    -- Retrack daily guild
    assert(F:SetTracked("daily", "guild", true, "test"))
    assert(F:IsTracked("daily", "guild") == true, "daily guild should be retracked")
end)

Test("bulk tracking commands (all/none) are scoped strictly", function()
    local S, F, h = TaskBoot()
    -- Set all daily untracked
    assert(F.Commands:SetAllTracked("daily", false, "test_none"))
    local dailyKeys = F.Authority:GetGroupKeys("daily")
    for _, key in ipairs(dailyKeys) do
        assert(F:IsTracked("daily", key) == false, "daily key " .. key .. " should be untracked")
    end
    -- Weekly remains tracked
    local weeklyKeys = F.Authority:GetGroupKeys("weekly")
    for _, key in ipairs(weeklyKeys) do
        assert(F:IsTracked("weekly", key) == true, "weekly key " .. key .. " should remain tracked")
    end

    -- Set all daily tracked
    assert(F.Commands:SetAllTracked("daily", true, "test_all"))
    for _, key in ipairs(dailyKeys) do
        assert(F:IsTracked("daily", key) == true, "daily key " .. key .. " should be tracked")
    end
end)

Test("expanding parent task inserts child rows with :child: index", function()
    local S, F, h = TaskBoot()
    local initialRows = F:GetRows("daily")
    local initialCount = #initialRows

    -- Toggle expand guild task
    assert(F.Commands:ToggleExpanded("daily", "guild"))
    local expandedRows = F:GetRows("daily")
    assert(#expandedRows > initialCount, "rows should increase when expanded")

    local foundChild = false
    for _, row in ipairs(expandedRows) do
        if row.id == "daily:guild:child:1" then
            foundChild = true
            assert(row.parent == false, "child row parent should be false")
            assert(row.child == true, "child row child should be true")
            assert(row.groupKey == "guild", "child row groupKey should be guild")
            assert(row.questId == 1001, "child row questId should be 1001")
        end
    end
    assert(foundChild, "daily:guild:child:1 not found in expanded rows")

    -- Collapse guild task
    assert(F.Commands:ToggleExpanded("daily", "guild"))
    local collapsedRows = F:GetRows("daily")
    assert(#collapsedRows == initialCount, "rows should restore to initial count when collapsed")
    assert(F.Authority:GetRow("daily:guild:child:1") == nil, "child row should be removed from lookup")
end)

Test("widget rows only include tracked parent tasks sorted by priority", function()
    local S, F, h = TaskBoot()
    -- Untrack weekly west_hiram
    assert(F:SetTracked("weekly", "west_hiram", false, "test"))
    local widgetRows = F.Authority:GetWidgetRows()
    for _, row in ipairs(widgetRows) do
        assert(row.tracked == true, "widget rows must only include tracked tasks")
        assert(row.id ~= "weekly:west_hiram", "untracked west_hiram must not be in widget rows")
    end

    -- Check sorting priority: ready (honor, 0/1 readyCount=1) should precede in_progress (guild) and completed (family)
    local honorIndex, guildIndex, familyIndex
    for i, row in ipairs(widgetRows) do
        if row.key == "honor" then honorIndex = i end
        if row.key == "guild" then guildIndex = i end
        if row.key == "family" then familyIndex = i end
    end
    if honorIndex and guildIndex then
        assert(honorIndex < guildIndex, "ready task (honor) must appear before in_progress task (guild)")
    end
    if guildIndex and familyIndex then
        assert(guildIndex < familyIndex, "in_progress task (guild) must appear before completed task (family)")
    end
end)

Test("overview projection supports scope, view, and query filters", function()
    local S, F, h = TaskBoot()
    local pAll = F:GetOverviewProjection({ scope = "all", view = "all", status = "all" })
    assert(type(pAll.rows) == "table" and #pAll.rows > 0)
    assert(pAll.summary.total >= #pAll.rows)

    local pDaily = F:GetOverviewProjection({ scope = "daily", view = "all", status = "all" })
    for _, row in ipairs(pDaily.rows) do
        assert(row.scope == "daily")
    end

    local pQuery = F:GetOverviewProjection({ scope = "all", view = "all", status = "all", query = "悉拉玛" })
    for _, row in ipairs(pQuery.rows) do
        local text = tostring(row.rawName or row.name or "")
        assert(string.find(text, "悉拉玛") ~= nil, "row should match query text: " .. text)
    end
end)

Test("demand acquisition starts and releases quest progress service", function()
    local S, F, h = TaskBoot()
    assert(F.Demand.count == 0)
    assert(F.consumerCount == 0)
    assert(F.progressConsumerHeld == false)

    assert(F:AcquireConsumer("test_tasks_consumer"))
    assert(F.Demand.count == 1)
    assert(F.consumerCount == 1)
    assert(F.progressConsumerHeld == true)

    assert(F:ReleaseConsumer("test_tasks_consumer"))
    assert(F.Demand.count == 0)
    assert(F.consumerCount == 0)
    assert(F.progressConsumerHeld == false)
end)

Test("task store schema 1 normalization and window persistence", function()
    local S, F, h = TaskBoot()
    local initialWrites = h.writes
    local ok, err = F.Commands:SetWidgetWindowState({
        width = 480, height = 310, minimized = false, locked = true,
        overallOpacity = 0.9, backgroundOpacity = 0.85, textOpacity = 1.0, userMoved = true,
    })
    assert(ok == true, "SetWidgetWindowState failed: " .. tostring(err))
    local win = F:GetWidgetWindowState()
    assert(win.width == 480)
    assert(win.height == 310)
    assert(win.locked == true)
    assert(F:MarkStoreDirty(0, "test_flush"))
    assert(S.Persistence:Flush(F.StoreId))
    assert(h.writes > initialWrites, "store should be written to disk")
end)

print(string.format("TASK SUITE RESULT: %d passed, %d failed", pass, fail))
if fail > 0 then error("task suite failures: " .. fail) end

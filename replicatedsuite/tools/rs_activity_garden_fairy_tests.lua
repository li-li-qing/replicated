------------------------------------------------------------------------
-- Replicated Suite - Garden Fairy Request Activity Tests
--
-- Covers the 2026-09-22 mapping of Garden of the Gods dynamic activity to
-- Fairy Request / 精灵的委托 (Quest 10056). The quest is score-based internally,
-- while the Activity completion contract is binary: unfinished 0/1, ready/completed 1/1.
------------------------------------------------------------------------
local passed, failed = 0, 0
local function Test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then passed = passed + 1; print("PASS garden_fairy " .. name)
    else failed = failed + 1; print("FAIL garden_fairy " .. name .. ": " .. tostring(err)) end
end
local function Eq(actual, expected, message)
    if actual ~= expected then error((message or "mismatch") .. ": expected=" .. tostring(expected) .. " actual=" .. tostring(actual), 2) end
end

local function Auto(seed)
    seed = type(seed) == "table" and seed or {}
    return setmetatable(seed, {
        __index = function(t, key)
            if type(key) == "number" then return nil end
            local child = Auto({})
            rawset(t, key, child)
            return child
        end,
    })
end

Test("quest group maps verified quest 10056 as scoreQuest", function()
    ReplicatedSuite = {
        BootError = nil,
        Data = { OfficialNames = { QuestGroup = Auto({}) } },
        GameIds = {
            Quest = Auto({ Activity = Auto({ gardenFairyRequest = { 10056 } }) }),
            Instance = Auto({}),
        },
    }
    dofile("data/rs_quest_data.lua")
    local group = assert(ReplicatedSuite.Data.ActivityQuestGroups.garden_fairy, "garden_fairy group missing")
    Eq(group.kind, "scoreQuest", "group kind")
    Eq(group.progressSelectionEnabled, false, "score quest selection")
    Eq(#group.objectives, 1, "objective count")
    Eq(group.objectives[1].quests[1], 10056, "quest id")
end)

Test("zone 133 links both timeline and live Garden rows to garden_fairy", function()
    ReplicatedSuite = { BootError = nil, Data = { OfficialNames = { Event = {} } } }
    dofile("data/rs_event_data.lua")
    local garden = assert(ReplicatedSuite.Data.DynamicEventZones[133], "garden zone definition missing")
    Eq(garden.questScope, "event", "garden quest scope")
    Eq(garden.questKey, "garden_fairy", "garden quest key")

    local authority = assert(io.open("features/life/activities/rs_activity_authority.lua", "r"), "authority source missing"):read("*a")
    if not authority:find("questScope = garden.questScope, questKey = garden.questKey", 1, true) then
        error("Garden live row does not forward quest mapping")
    end
    if not authority:find("self:AttachProgress(row)", 1, true) then
        error("Garden live row does not attach quest progress")
    end
end)

Test("scoreQuest compact snapshot keeps binary activity completion", function()
    local QS = {
        NOT_ACCEPTED = "NOT_ACCEPTED", IN_PROGRESS = "IN_PROGRESS",
        READY_TO_TURN_IN = "READY_TO_TURN_IN", COMPLETED = "COMPLETED", UNKNOWN = "UNKNOWN",
    }
    ReplicatedSuite = {
        BootError = nil,
        Services = {},
        Constants = { QuestStatus = QS },
        Demand = {
            Create = function(_, options)
                return {
                    Has = function() return false end,
                    Acquire = function() return true, true end,
                    Release = function() return true end,
                    Clear = function() return true end,
                }
            end,
        },
    }
    dofile("services/rs_quest_progress_v3.lua")
    local service = assert(ReplicatedSuite.Services.QuestProgressV3, "quest progress service missing")
    local group = { kind = "scoreQuest", objectives = { { quests = { 10056 } } }, progressSelectionEnabled = false }

    local states = {
        { QS.NOT_ACCEPTED, "0/1", "muted", 0 },
        { QS.IN_PROGRESS, "0/1", "yellow", 0 },
        { QS.READY_TO_TURN_IN, "1/1", "orange", 1 },
        { QS.COMPLETED, "1/1", "green", 1 },
    }
    for _, case in ipairs(states) do
        service.ObjectiveState = function() return case[1] end
        local snapshot = service:BuildQuestSnapshot("garden_fairy", group, {}, true)
        Eq(snapshot.kind, "scoreQuest", "snapshot kind")
        Eq(snapshot.text, case[2], "snapshot text for " .. case[1])
        Eq(snapshot.tone, case[3], "snapshot tone for " .. case[1])
        Eq(snapshot.completed, case[4], "snapshot completion for " .. case[1])
        Eq(snapshot.total, 1, "snapshot total")
        Eq(snapshot.progressSelectionEnabled, false, "score selection disabled")
    end
end)

Test("scoreQuest detail UI shows 0/1 completion while preserving Journal detail", function()
    local source = assert(io.open("presentation/v3/widgets/rs_v3_quest_detail_floating.lua", "r"), "detail source missing"):read("*a")
    if not source:find('"主进度 " .. tostring(math.min(completed, 1)) .. "/1"', 1, true) then
        error("scoreQuest detail does not expose binary activity progress")
    end
    if not source:find("实时积分和奖励阶段以游戏任务日志目标为准", 1, true) then
        error("scoreQuest detail no longer documents Journal score authority")
    end
end)

print(string.format("GARDEN FAIRY RESULT: %d passed, %d failed", passed, failed))
if failed > 0 then error("garden fairy suite failures: " .. tostring(failed)) end

------------------------------------------------------------------------
-- Replicated Suite - Activity Progress Selection Data Policy Tests
--
-- Verifies the data-Authority contract introduced in .18.281:
-- every verified multi-objective activity is selectable by default, while
-- single-objective and instance-raid groups keep a fixed denominator.
------------------------------------------------------------------------
local passed, failed = 0, 0
local function Test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then passed = passed + 1; print("PASS activity_progress_data " .. name)
    else failed = failed + 1; print("FAIL activity_progress_data " .. name .. ": " .. tostring(err)) end
end
local function Eq(actual, expected, message)
    if actual ~= expected then error((message or "mismatch") .. ": expected=" .. tostring(expected) .. " actual=" .. tostring(actual), 2) end
end

local function Auto(seed)
    seed = type(seed) == "table" and seed or {}
    return setmetatable(seed, {
        __index = function(t, key)
            if type(key) == "number" then return nil end -- keep ipairs over unknown ID arrays finite
            local child = Auto({})
            rawset(t, key, child)
            return child
        end,
    })
end

ReplicatedSuite = {
    BootError = nil,
    Data = { OfficialNames = { QuestGroup = Auto({}) } },
    GameIds = { Quest = Auto({}), Instance = Auto({}) },
}

dofile("data/rs_quest_data.lua")
local G = assert(ReplicatedSuite.Data.ActivityQuestGroups, "activity groups missing")

local expectedSelectable = {
    whalesong = 3, crimson = 6, sungold_crimson = 6, ghost = 4, aegis = 3,
    hiram_t6 = 4, jmg = 3, akasch_guard = 4, rookborne_festival = 5, abyssal = 2,
}

Test("all verified multi-objective groups are selectable", function()
    for key, count in pairs(expectedSelectable) do
        local group = assert(G[key], "missing group " .. key)
        Eq(#group.objectives, count, key .. " objective count")
        Eq(group.progressSelectionEnabled, true, key .. " must support personal denominator selection")
    end
end)

Test("single-objective groups remain fixed denominator", function()
    local fixed = {
        "halcy", "lusca", "hasla_shadow", "cinderstone_purify", "ynystere_purify",
        "guardian_scramble", "wonderland_nightmare", "dragon_power", "black_dragon",
        "kraken", "leviathan", "charybdis", "garden_anthalon", "garden_fairy",
    }
    for _, key in ipairs(fixed) do
        local group = assert(G[key], "missing group " .. key)
        Eq(#group.objectives, 1, key .. " objective count")
        Eq(group.progressSelectionEnabled, false, key .. " must keep fixed 1/1 denominator")
    end
end)

Test("instance raids never expose quest selection", function()
    for _, key in ipairs({ "red_dragon", "kadum" }) do
        local group = assert(G[key], "missing group " .. key)
        Eq(group.kind, "instanceRaid", key .. " kind")
        Eq(#group.objectives, 0, key .. " objective count")
        Eq(group.progressSelectionEnabled, false, key .. " must not expose quest selection")
    end
end)

print(string.format("ACTIVITY PROGRESS SELECTION DATA RESULT: %d passed, %d failed", passed, failed))
if failed > 0 then error("activity progress selection data suite failures: " .. tostring(failed)) end

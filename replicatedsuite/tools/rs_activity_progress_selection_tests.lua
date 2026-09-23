------------------------------------------------------------------------
-- Replicated Suite - Activity Personal Progress Projection Tests
--
-- Development-only offline suite. Reproduces the Crimson Rift requirement:
-- default six selected => 0/6; keep stages 4-6 => 0/3; complete stage 4 => 1/3.
------------------------------------------------------------------------
local passed, failed = 0, 0
local function Test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then passed = passed + 1; print("PASS activity_progress " .. name)
    else failed = failed + 1; print("FAIL activity_progress " .. name .. ": " .. tostring(err)) end
end
local function Eq(actual, expected, message)
    if actual ~= expected then error((message or "mismatch") .. ": expected=" .. tostring(expected) .. " actual=" .. tostring(actual), 2) end
end

local selection = nil -- nil means implicit all, exactly like production Store.
local snapshot = {
    key = "crimson", kind = "quest", available = true, completed = 0, total = 6,
    activeCount = 0, readyCount = 0, relatedActiveCount = 0, relatedReadyCount = 0,
    tailInFlightCount = 0, text = "0/6", tone = "muted", progressSelectionEnabled = true,
    objectiveStates = {},
}
for index = 1, 6 do
    snapshot.objectiveStates[index] = {
        key = "main:" .. tostring(index), trackingKey = "main:" .. tostring(index), state = "NOT_ACCEPTED",
        completed = false, ready = false, active = false,
    }
end

ReplicatedSuite = {
    BootError = nil,
    Constants = { QuestStatus = {
        IN_PROGRESS = "IN_PROGRESS", READY_TO_TURN_IN = "READY_TO_TURN_IN", COMPLETED = "COMPLETED", NOT_ACCEPTED = "NOT_ACCEPTED",
    } },
    Services = {}, Features = { Activities = { Authority = {} } },
    FeatureRuntime = { RegisterImplementation = function() return true end },
    Demand = { Create = function(_, spec)
        return {
            Acquire = function() return true end, Release = function() return true end, Clear = function() return true end,
            GetSnapshot = function() return { count = 0 } end, spec = spec,
        }
    end },
    Events = { Publish = function() return true end },
}
local S = ReplicatedSuite
local F = S.Features.Activities
function F.Authority:SetQuestProgressProvider(fn) self.questProvider = fn; return true end
function F.Authority:SetInstanceProgressProvider(fn) self.instanceProvider = fn; return true end
function F.Authority:Refresh(reason) self.refreshReason = reason; return true end
function F.Authority:GetSummary() return { total=0, active=0, timelineActive=0, timelineTotal=0, liveActive=0, liveZones=0 } end
function F.Authority:GetTimingDiagnostics() return {} end

local function Tokens(values)
    local out = {}; for _, value in ipairs(values or {}) do out[#out + 1] = tostring(type(value)=="table" and value.trackingKey or value) end; return out
end
function F:GetDetailProgressSelection(eventKey, eligible)
    local ordered = Tokens(eligible); local out = {}
    if selection == nil then for _, token in ipairs(ordered) do out[token] = true end; return out, false, true, nil end
    for _, token in ipairs(ordered) do if selection[token] == true then out[token] = true end end
    return out, true, true, nil
end
function F:SetDetailProgressTaskSelected(eventKey, token, enabled, eligible)
    local ordered = Tokens(eligible); local known = {}; for _, candidate in ipairs(ordered) do known[candidate] = true end
    if known[token] ~= true then return false, "not eligible" end
    local current = self:GetDetailProgressSelection(eventKey, ordered)
    current[token] = enabled == true or nil
    local count = 0; for _, value in pairs(current) do if value == true then count = count + 1 end end
    if count < 1 then return false, "至少保留 1 个活动进度任务" end
    if count == #ordered then selection = nil else selection = current end
    return true
end
F.EnsureStoreLoaded = function() return true end
F.MutateStore = function() return true end
F.State = { widgetWindow = {}, hiddenEvents = {}, widgetRows = 8 }

local progress = { ActivityObjectiveFactsContractVersion = 1 }
S.Services.QuestProgressV3 = progress
function progress:GetQuestProgress(scope, key)
    local out = {}; for k,v in pairs(snapshot) do out[k]=v end
    out.objectiveStates = {}; for i,row in ipairs(snapshot.objectiveStates) do local r={};for k,v in pairs(row)do r[k]=v end;out.objectiveStates[i]=r end
    return out
end
function progress:GetInstanceProgress() return nil end
function progress:GetHealth() return { revision=1, available=1, refreshFailures=0 } end

dofile("features/life/activities/rs_activity_feature.lua")
assert(F:Initialize() == true, "activity feature initialize failed")

local function RawDetail()
    local children = {}
    for index = 1, 6 do
        local fact = snapshot.objectiveStates[index]
        children[#children + 1] = {
            key = "main:" .. tostring(index), trackingKey = fact.trackingKey, category = "主任务",
            name = "征兆阶段" .. tostring(index), status = fact.completed and "已完成" or "未接",
            state = fact.state, counted = true, related = false,
        }
        if index == 4 then
            children[#children + 1] = { key="journal:4:1", journal=true, parentTrackingKey=fact.trackingKey,
                category="目标", name="└ 目标 0/30", status="", counted=false, related=false }
        end
    end
    children[#children + 1] = { key="related:1", trackingKey="related:guard", category="关联", name="征兆守护", status="已完成", state="COMPLETED", counted=false, related=true }
    children[#children + 1] = { key="related:2", trackingKey="related:path", category="荣耀之路", name="猎犬", status="已完成", state="COMPLETED", counted=false, related=true }
    return {
        scope="event", key="crimson", title="征兆之痕", kind="activity", progressSelectionEnabled=true,
        completed=0, total=6, activeCount=0, readyCount=0, relatedCount=2, children=children,
    }
end

Test("Activity Authority provider uses personalized projection contract", function()
    selection = { ["main:4"] = true, ["main:5"] = true, ["main:6"] = true }
    local projected = F.Authority.questProvider("event", "crimson")
    Eq(projected.completed, 0); Eq(projected.total, 3); Eq(projected.text, "0/3")
end)

Test("default Crimson Rift remains all six => 0/6", function()
    selection = nil
    local projected = F:ProjectActivityProgress("event", "crimson", progress:GetQuestProgress("event", "crimson"))
    Eq(projected.completed, 0); Eq(projected.total, 6); Eq(projected.text, "0/6")
    Eq(projected.progressSelectionSelected, 6); Eq(projected.progressSelectionEligible, 6)
    Eq(projected.progressSelectionConfigured, false)
end)

Test("keeping only stages 4-6 changes compact progress to 0/3", function()
    selection = { ["main:4"] = true, ["main:5"] = true, ["main:6"] = true }
    local projected = F:ProjectActivityProgress("event", "crimson", progress:GetQuestProgress("event", "crimson"))
    Eq(projected.completed, 0); Eq(projected.total, 3); Eq(projected.text, "0/3")
    Eq(projected.progressSelectionSelected, 3); Eq(projected.progressSelectionEligible, 6)
end)

Test("completion inside selected subset increments numerator => 1/3", function()
    selection = { ["main:4"] = true, ["main:5"] = true, ["main:6"] = true }
    snapshot.objectiveStates[4].completed = true; snapshot.objectiveStates[4].state = "COMPLETED"
    local projected = F:ProjectActivityProgress("event", "crimson", progress:GetQuestProgress("event", "crimson"))
    Eq(projected.completed, 1); Eq(projected.total, 3); Eq(projected.text, "1/3")
end)

Test("completed unselected stage does not affect numerator", function()
    selection = { ["main:4"] = true, ["main:5"] = true, ["main:6"] = true }
    snapshot.objectiveStates[1].completed = true; snapshot.objectiveStates[1].state = "COMPLETED"
    snapshot.objectiveStates[4].completed = false; snapshot.objectiveStates[4].state = "NOT_ACCEPTED"
    local projected = F:ProjectActivityProgress("event", "crimson", progress:GetQuestProgress("event", "crimson"))
    Eq(projected.completed, 0); Eq(projected.total, 3); Eq(projected.text, "0/3")
end)

Test("detail uses identical denominator and related rows never count", function()
    selection = { ["main:4"] = true, ["main:5"] = true, ["main:6"] = true }
    snapshot.objectiveStates[4].completed = true; snapshot.objectiveStates[4].state = "COMPLETED"
    local detail = RawDetail()
    -- Mirror current quest fact into detail row 4.
    local mainIndex = 0
    for _, row in ipairs(detail.children) do
        if row.counted == true and row.related ~= true then
            mainIndex = mainIndex + 1
            local fact = snapshot.objectiveStates[mainIndex]
            row.state = fact.state; row.status = fact.completed and "已完成" or "未接"
        end
    end
    local projected = F:ProjectActivityDetail(detail)
    Eq(projected.completed, 1); Eq(projected.total, 3)
    Eq(projected.progressSelectionSelected, 3); Eq(projected.progressSelectionEligible, 6)
    local selectedMain, selectedRelated = 0, 0
    for _, row in ipairs(projected.children) do
        if row.progressSelectable == true and row.progressSelected == true then selectedMain = selectedMain + 1 end
        if row.related == true and row.progressSelected == true then selectedRelated = selectedRelated + 1 end
    end
    Eq(selectedMain, 3); Eq(selectedRelated, 0, "related task entered denominator")
end)

Test("non-opt-in activities preserve QuestProgress fixed denominator", function()
    local raw = progress:GetQuestProgress("event", "crimson"); raw.key="other"; raw.progressSelectionEnabled=false; raw.text="2/6"; raw.completed=2
    local projected = F:ProjectActivityProgress("event", "other", raw)
    Eq(projected, raw, "non-opt-in snapshot should pass through")
    Eq(projected.text, "2/6")
end)

print(string.format("ACTIVITY PROGRESS SELECTION RESULT: %d passed, %d failed", passed, failed))
if failed > 0 then error("activity progress selection suite failures: " .. tostring(failed)) end

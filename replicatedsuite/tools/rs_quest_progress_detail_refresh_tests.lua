-- QuestProgressV3 detail-refresh contract regression. Development-only; not in toc.g.
local pass, fail = 0, 0
local function Test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then pass = pass + 1; print("PASS quest_progress_detail " .. name)
    else fail = fail + 1; print("FAIL quest_progress_detail " .. name .. ": " .. tostring(err)) end
end

local function Boot()
    local now = 1000
    ReplicatedSuite = {
        BootError = nil,
        Generation = 1,
        Services = {},
        Data = {
            EventQuestProgress = {
                demo = { key = "demo", title = "演示活动", kind = "activity", objectives = { { title = "阶段一", quests = { 100 } } }, relatedObjectives = {} },
                raid = { key = "raid", title = "演示副本", kind = "instanceRaid", objectives = {}, instanceRaid = { matchNames = { "Raid" }, maxEntry = 1 } },
            },
            QuestGroups = { daily = {}, weekly = {} },
        },
        Constants = { QuestStatus = { NOT_ACCEPTED="NOT_ACCEPTED",IN_PROGRESS="IN_PROGRESS",READY_TO_TURN_IN="READY_TO_TURN_IN",COMPLETED="COMPLETED",UNKNOWN="UNKNOWN" } },
        Utils = {},
        SafeTraceback = function(err) return tostring(err) end,
        NowMs = function() return now end,
    }
    local S = ReplicatedSuite
    function S.Utils.DeepCopy(value)
        if type(value) ~= "table" then return value end
        local out = {}; for key, item in pairs(value) do out[key] = S.Utils.DeepCopy(item) end; return out
    end

    local published = {}
    S.Events = { internal = {}, native = {} }
    function S.Events:BindOwner() return true end
    function S.Events:Subscribe(name, owner, callback) self.native[name] = { owner = owner, callback = callback }; return true end
    function S.Events:SubscribeInternal(name, owner, callback) self.internal[name] = self.internal[name] or {}; self.internal[name][owner] = callback; return true end
    function S.Events:UnsubscribeOwner() return true end
    function S.Events:UnsubscribeInternalOwner(owner) for _, b in pairs(self.internal) do b[owner] = nil end; return true end
    function S.Events:Publish(name, ...)
        published[#published + 1] = { name = name, args = { ... } }
        for owner, callback in pairs(self.internal[name] or {}) do callback(owner, ...) end
        return true
    end
    S.Scheduler = {}
    function S.Scheduler:AddTask() return true end
    function S.Scheduler:SetTaskModule() return true end
    function S.Scheduler:RemoveTask() return true end

    S.Api = {}
    function S.Api:IsCapabilityAllowed() return true end
    function S.Api:CallCapability(_, host, method, ...)
        local fn = host and host[method]
        if type(fn) ~= "function" then return false, nil end
        return true, fn(host, ...)
    end

    local objectiveText = "击败目标 17/30"
    X2Quest = {}
    function X2Quest:GetActiveQuestListCount() return 1 end
    function X2Quest:GetActiveQuestType(index) if index == 1 then return 100 end end
    function X2Quest:IsCompleted() return false end
    function X2Quest:IsReadyForCompleteQuest() return false end
    function X2Quest:GetQuestContextMainTitle() return "阶段一任务" end
    function X2Quest:GetQuestJournalObjectiveCount(index) assert(index == 1); return 1 end
    function X2Quest:GetQuestJournalObjectiveText(index, obj) assert(index == 1 and obj == 1); return objectiveText end

    S.Services.InstanceCatalogV3 = {
        AcquireConsumer = function() return true end,
        ReleaseConsumer = function() return true end,
        GetEntryProgress = function() return { available=true,completed=0,total=1,text="0/1",tone="muted",enterCount=0,maxEnterCount=1 } end,
        Refresh = function() return true end,
    }

    dofile("core/rs_demand.lua")
    dofile("services/rs_quest_progress_v3.lua")
    return S, S.Services.QuestProgressV3, published, function(value) objectiveText = value; now = now + 250 end
end

Test("successful refresh epoch publishes even when projection revision is unchanged", function()
    local S, P, events = Boot()
    assert(P:AcquireConsumer("test:detail", { instances = false }))
    local revision = P.revision
    local updatedBefore, refreshedBefore = 0, 0
    for _, event in ipairs(events) do if event.name == "v3.quest_progress.updated" then updatedBefore=updatedBefore+1 elseif event.name == "v3.quest_progress.refreshed" then refreshedBefore=refreshedBefore+1 end end
    assert(P:Refresh("same_projection"))
    local updatedAfter, refreshedAfter = 0, 0
    for _, event in ipairs(events) do if event.name == "v3.quest_progress.updated" then updatedAfter=updatedAfter+1 elseif event.name == "v3.quest_progress.refreshed" then refreshedAfter=refreshedAfter+1 end end
    assert(P.revision == revision, "unchanged projection must not bump business revision")
    assert(updatedAfter == updatedBefore, "unchanged projection unexpectedly published updated")
    assert(refreshedAfter == refreshedBefore + 1, "successful refresh epoch was not published")
end)

Test("journal objective text rereads after refresh cache invalidation", function()
    local S, P, events, SetObjective = Boot()
    assert(P:AcquireConsumer("test:detail", { instances = false }))
    local first = assert(P:GetGroupDetail("event", "demo", { journal = true }))
    assert(first.children[2] and first.children[2].name == "└ 击败目标 17/30", "initial journal objective mismatch")
    SetObjective("击败目标 18/30")
    assert(P:Refresh("objective_only"))
    local second = assert(P:GetGroupDetail("event", "demo", { journal = true }))
    assert(second.children[2] and second.children[2].name == "└ 击败目标 18/30", "journal cache was not invalidated/refreshed")
end)

Test("group kind exposes static demand requirement without exposing group table", function()
    local S, P = Boot()
    assert(P:GetGroupKind("event", "demo") == "activity")
    assert(P:GetGroupKind("event", "raid") == "instanceRaid")
    assert(P:GetGroupKind("event", "missing") == nil)
end)

print(string.format("QUEST PROGRESS DETAIL REFRESH RESULT: %d passed, %d failed", pass, fail))
if fail > 0 then error("quest progress detail refresh failures: " .. fail) end

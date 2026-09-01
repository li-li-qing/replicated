------------------------------------------------------------------------
-- Replicated Suite V3 - Shared Quest / Instance Progress Service
--
-- Read-only gameplay projection shared by Activity and the future Task Tracker.
-- It never owns UI or persistence and never revives the Legacy QuestService.
--
-- Authority:
--   * Quest membership/completion: X2Quest read-only getters.
--   * Instance entry counters: InstanceCatalogV3 projection (X2BattleField is owned there).
--   * Quest/instance semantic grouping: data/rs_quest_data.lua.
--
-- Performance:
--   * No Tick / OnUpdate.
--   * Native quest reads are event-driven plus a 15s safety refresh while at
--     least one consumer exists.
--   * Instance discovery/counters are delegated to InstanceCatalogV3 and only
--     acquired for consumers that explicitly request event-instance progress.
--   * Consumers read immutable-style projection tables; presentation never calls
--     X2Quest/X2BattleField directly.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Services = S.Services or {}

local P = {
    Id = "v3.quest_progress",
    consumers = {},
    consumerCount = 0,
    running = false,
    revision = 0,
    updatedAtMs = -1,
    snapshots = {},
    scopeSnapshots = { daily = {}, weekly = {} },
    activeIndex = {},
    refreshQuestStateCache = nil,
    instanceConsumerToken = "service:v3.quest_progress:instances",
    instanceConsumerHeld = false,
    questTitleCache = {},
    safetyTask = "v3_quest_progress_safety",
    refreshFailures = 0,
}
P.presentationBoundary = "service_only"
S.Services.QuestProgressV3 = P

local QS = S.Constants and S.Constants.QuestStatus or {
    NOT_ACCEPTED = "NOT_ACCEPTED", IN_PROGRESS = "IN_PROGRESS",
    READY_TO_TURN_IN = "READY_TO_TURN_IN", COMPLETED = "COMPLETED",
    UNKNOWN = "UNKNOWN",
}

local QUEST_EVENTS = {
    "QUEST_CONTEXT_UPDATED",
    "QUEST_CONTEXT_OBJECTIVE_EVENT",
    "UPDATE_COMPLETED_QUEST_INFO",
    "ADD_GIVEN_QUEST_INFO",
    "REMOVE_GIVEN_QUEST_INFO",
    "COMPLETE_QUEST_CONTEXT_NPC",
    "COMPLETE_QUEST_CONTEXT_DOODAD",
    "ENTERED_WORLD",
}

local function NowMs()
    return math.max(0, tonumber(S.NowMs and S.NowMs()) or 0)
end

local function Capability(name)
    return S.Api ~= nil and type(S.Api.IsCapabilityAllowed) == "function"
        and S.Api:IsCapabilityAllowed(name) == true
end

local function ObjectiveList(group)
    if type(group) ~= "table" then return {} end
    if type(group.objectives) == "table" and #group.objectives > 0 then return group.objectives end
    local result = {}
    for _, qid in ipairs(type(group.quests) == "table" and group.quests or {}) do
        result[#result + 1] = { quests = { qid } }
    end
    return result
end

local function RelatedList(group)
    return type(group) == "table" and type(group.relatedObjectives) == "table" and group.relatedObjectives or {}
end

local function SnapshotEqual(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    return a.available == b.available
        and a.completed == b.completed
        and a.total == b.total
        and a.activeCount == b.activeCount
        and a.readyCount == b.readyCount
        and a.relatedActiveCount == b.relatedActiveCount
        and a.relatedReadyCount == b.relatedReadyCount
        and a.tailInFlightCount == b.tailInFlightCount
        and a.text == b.text
        and a.tone == b.tone
        and a.instanceType == b.instanceType
        and a.enterCount == b.enterCount
        and a.maxEnterCount == b.maxEnterCount
end

local function CopySnapshot(value)
    if type(value) ~= "table" then return nil end
    local copy = {}
    for key, item in pairs(value) do copy[key] = item end
    return copy
end

function P:BuildActiveIndex()
    local map = {}
    if Capability("X2Quest:GetActiveQuestListCount") ~= true
        or Capability("X2Quest:GetActiveQuestType") ~= true then
        return map, false
    end
    local questHost = rawget(_G, "X2Quest")
    if questHost == nil then return map, false end
    local okCount, count = S.Api:CallCapability("X2Quest:GetActiveQuestListCount", questHost, "GetActiveQuestListCount")
    if okCount ~= true then return map, false end
    count = math.max(0, math.floor(tonumber(count) or 0))
    for index = 1, count do
        local okId, qid = S.Api:CallCapability("X2Quest:GetActiveQuestType", questHost, "GetActiveQuestType", index)
        qid = okId and tonumber(qid) or nil
        if qid ~= nil then map[qid] = index end
    end
    return map, true
end

function P:QuestState(qid, activeIndex)
    qid = tonumber(qid)
    if qid == nil then return QS.UNKNOWN end
    local cache = type(self.refreshQuestStateCache) == "table" and self.refreshQuestStateCache or nil
    if cache ~= nil and cache[qid] ~= nil then return cache[qid] end

    local questHost = rawget(_G, "X2Quest")
    if questHost == nil then return QS.UNKNOWN end
    local state = QS.NOT_ACCEPTED

    if Capability("X2Quest:IsCompleted") then
        local okDone, done = S.Api:CallCapability("X2Quest:IsCompleted", questHost, "IsCompleted", qid)
        if okDone and done == true then state = QS.COMPLETED end
    end

    if state ~= QS.COMPLETED and type(activeIndex) == "table" and activeIndex[qid] ~= nil then
        if Capability("X2Quest:IsReadyForCompleteQuest") then
            local okReady, ready = S.Api:CallCapability("X2Quest:IsReadyForCompleteQuest", questHost, "IsReadyForCompleteQuest", qid)
            if okReady and ready == true then state = QS.READY_TO_TURN_IN else state = QS.IN_PROGRESS end
        else
            state = QS.IN_PROGRESS
        end
    end
    if cache ~= nil then cache[qid] = state end
    return state
end

function P:ObjectiveState(objective, activeIndex)
    objective = type(objective) == "table" and objective or {}
    local inProgress = false
    for _, qid in ipairs(type(objective.quests) == "table" and objective.quests or {}) do
        local state = self:QuestState(qid, activeIndex)
        if state == QS.COMPLETED then return QS.COMPLETED end
        if state == QS.READY_TO_TURN_IN then return QS.READY_TO_TURN_IN end
        if state == QS.IN_PROGRESS then inProgress = true end
    end
    return inProgress and QS.IN_PROGRESS or QS.NOT_ACCEPTED
end

local function ProgressTone(completed, total, activeCount, readyCount, available)
    if available ~= true then return "muted" end
    if total > 0 and completed >= total then return readyCount > 0 and "orange" or "green" end
    if readyCount > 0 then return "orange" end
    if activeCount > 0 or completed > 0 then return "yellow" end
    return "muted"
end

function P:BuildQuestSnapshot(key, group, activeIndex, questAvailable)
    local objectives = ObjectiveList(group)
    local completed, activeCount, readyCount, tailInFlightCount = 0, 0, 0, 0
    for _, objective in ipairs(objectives) do
        local state = self:ObjectiveState(objective, activeIndex)
        if state == QS.COMPLETED then
            completed = completed + 1
        elseif state == QS.READY_TO_TURN_IN then
            completed = completed + 1
            readyCount = readyCount + 1
        elseif state == QS.IN_PROGRESS then
            activeCount = activeCount + 1
        end
        if objective.keepsEventAlive == true and (state == QS.IN_PROGRESS or state == QS.READY_TO_TURN_IN) then
            tailInFlightCount = tailInFlightCount + 1
        end
    end

    local relatedActive, relatedReady = 0, 0
    for _, objective in ipairs(RelatedList(group)) do
        local state = self:ObjectiveState(objective, activeIndex)
        if state == QS.IN_PROGRESS then relatedActive = relatedActive + 1 end
        if state == QS.READY_TO_TURN_IN then relatedReady = relatedReady + 1 end
        if objective.keepsEventAlive == true and (state == QS.IN_PROGRESS or state == QS.READY_TO_TURN_IN) then
            tailInFlightCount = tailInFlightCount + 1
        end
    end

    local total = #objectives
    local available = questAvailable == true and total > 0
    return {
        key = tostring(key), kind = "quest", available = available,
        completed = completed, total = total,
        activeCount = activeCount, readyCount = readyCount,
        relatedActiveCount = relatedActive, relatedReadyCount = relatedReady,
        tailInFlightCount = tailInFlightCount,
        text = available and (tostring(completed) .. "/" .. tostring(total)) or "--",
        tone = ProgressTone(completed, total, activeCount, readyCount, available),
    }
end

local function GroupKey(group, index)
    if type(group) ~= "table" then return tostring(index or "") end
    local key = tostring(group.key or "")
    if key ~= "" then return key end
    return tostring(index or "")
end

function P:BuildScopeSnapshots(scope, groups, activeIndex, questAvailable)
    local result = {}
    for index, group in ipairs(type(groups) == "table" and groups or {}) do
        if type(group) == "table" and group.kind ~= "instanceRaid" then
            local key = GroupKey(group, index)
            if key ~= "" then result[key] = self:BuildQuestSnapshot(key, group, activeIndex, questAvailable) end
        end
    end
    return result
end

local function SnapshotMapEqual(a, b)
    a = type(a) == "table" and a or {}
    b = type(b) == "table" and b or {}
    for key, value in pairs(b) do if SnapshotEqual(a[key], value) ~= true then return false end end
    for key in pairs(a) do if b[key] == nil then return false end end
    return true
end

local function InstanceDefinitions()
    local result = {}
    for key, definition in pairs(S.Data and S.Data.EventQuestProgress or {}) do
        if type(definition) == "table" and definition.kind == "instanceRaid" and type(definition.instanceRaid) == "table" then
            result[tostring(key)] = definition
        end
    end
    return result
end

function P:HasInstanceDemand()
    for _, options in pairs(type(self.consumers) == "table" and self.consumers or {}) do
        if type(options) == "table" and options.instances == true then return true end
    end
    return false
end

function P:SyncInstanceConsumer()
    local needsInstances = self:HasInstanceDemand()
    local service = S.Services and S.Services.InstanceCatalogV3 or nil
    if needsInstances and self.instanceConsumerHeld ~= true then
        if type(service) ~= "table" or type(service.AcquireConsumer) ~= "function" then
            return false, "instance catalog service unavailable"
        end
        local ok, err = service:AcquireConsumer(self.instanceConsumerToken)
        if ok ~= true then return false, err end
        self.instanceConsumerHeld = true
        return true
    end
    if needsInstances ~= true and self.instanceConsumerHeld == true then
        if type(service) ~= "table" or type(service.ReleaseConsumer) ~= "function" then
            return false, "instance catalog release unavailable"
        end
        local ok, err = service:ReleaseConsumer(self.instanceConsumerToken)
        if ok ~= true then return false, err or "instance catalog release failed" end
        self.instanceConsumerHeld = false
    end
    return true
end

function P:RefreshInstances(nextSnapshots, forceDiscovery)
    local definitions = InstanceDefinitions()
    if next(definitions) == nil then return true end
    local service = S.Services and S.Services.InstanceCatalogV3 or nil
    if self:HasInstanceDemand() ~= true or type(service) ~= "table" or type(service.GetEntryProgress) ~= "function" then
        for key in pairs(definitions) do
            nextSnapshots[key] = { key = key, kind = "instanceRaid", available = false, text = "--", tone = "muted", completed = 0, total = 1 }
        end
        return false
    end

    if forceDiscovery == true and type(service.Refresh) == "function" then
        service:Refresh("quest_progress_force_instance", true)
    end
    for key, definition in pairs(definitions) do
        local raid = type(definition.instanceRaid) == "table" and definition.instanceRaid or {}
        local snapshot = service:GetEntryProgress(raid.matchNames, raid.maxEntry)
        snapshot = type(snapshot) == "table" and snapshot or { available = false, completed = 0, total = 1, text = "--", tone = "muted" }
        snapshot.key = key
        snapshot.kind = "instanceRaid"
        nextSnapshots[key] = snapshot
    end
    return true
end

function P:Refresh(reason, forceInstanceDiscovery)
    local ok, err = xpcall(function()
        local activeIndex, questAvailable = self:BuildActiveIndex()
        self.refreshQuestStateCache = {}

        local nextSnapshots = {}
        for key, group in pairs(S.Data and S.Data.EventQuestProgress or {}) do
            if type(group) == "table" and group.kind ~= "instanceRaid" then
                nextSnapshots[tostring(key)] = self:BuildQuestSnapshot(key, group, activeIndex, questAvailable)
            end
        end
        self:RefreshInstances(nextSnapshots, forceInstanceDiscovery == true)

        local questGroups = S.Data and S.Data.QuestGroups or {}
        local nextScopes = {
            daily = self:BuildScopeSnapshots("daily", questGroups.daily, activeIndex, questAvailable),
            weekly = self:BuildScopeSnapshots("weekly", questGroups.weekly, activeIndex, questAvailable),
        }

        local changed = SnapshotMapEqual(self.snapshots, nextSnapshots) ~= true
            or SnapshotMapEqual(self.scopeSnapshots and self.scopeSnapshots.daily, nextScopes.daily) ~= true
            or SnapshotMapEqual(self.scopeSnapshots and self.scopeSnapshots.weekly, nextScopes.weekly) ~= true

        self.activeIndex = activeIndex
        self.snapshots = nextSnapshots
        self.scopeSnapshots = nextScopes
        self.refreshQuestStateCache = nil
        self.updatedAtMs = NowMs()
        if changed then
            self.revision = (tonumber(self.revision) or 0) + 1
            if S.Events ~= nil and type(S.Events.Publish) == "function" then
                S.Events:Publish("v3.quest_progress.updated", self.revision, tostring(reason or "refresh"))
            end
        end
    end, S.SafeTraceback)
    self.refreshQuestStateCache = nil
    if ok ~= true then
        self.refreshFailures = (tonumber(self.refreshFailures) or 0) + 1
        if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Record) == "function" then
            S.DiagnosticsManager:Record("warning", "v3.quest_progress", "新版任务进度刷新失败: " .. tostring(err))
        end
        return false, err
    end
    return true
end

function P:RequestRefresh(delayMs, reason)
    if self.running ~= true or self.consumerCount <= 0 then return false end
    local coordinator = S.RefreshCoordinator
    if type(coordinator) ~= "table" or type(coordinator.Request) ~= "function" then
        return self:Refresh(reason or "request")
    end
    return coordinator:Request({
        key = "quest_progress",
        owner = self,
        delayMs = math.max(100, tonumber(delayMs) or 200),
        reason = reason or "quest_event",
        moduleId = self.Id,
        priority = "P2",
        cost = 2,
        callback = function(_, latestReason) return P:Refresh(latestReason or "quest_event") end,
    })
end

function P:Start()
    if self.running == true then return true end
    if S.Events == nil or S.Scheduler == nil then return false, "event/scheduler unavailable" end
    S.Events:BindOwner(self, self.Id)
    for _, eventName in ipairs(QUEST_EVENTS) do
        if S.Events:Subscribe(eventName, self, function()
            P:RequestRefresh(200, eventName)
        end) ~= true then
            S.Events:UnsubscribeOwner(self)
            return false, "quest event subscribe failed: " .. tostring(eventName)
        end
    end
    if type(S.Events.SubscribeInternal) ~= "function" or S.Events:SubscribeInternal("v3.instances.updated", self, function()
        if P.running == true and P:HasInstanceDemand() then P:RequestRefresh(100, "instance_catalog") end
    end) ~= true then
        S.Events:UnsubscribeOwner(self)
        if type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
        return false, "instance progress internal subscribe failed"
    end
    local added = S.Scheduler:AddTask(self.safetyTask, 15000, function()
        if P.consumerCount > 0 then P:Refresh("safety") end
    end, false, self, "P3", 2)
    if added ~= true then
        S.Events:UnsubscribeOwner(self)
        if type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
        return false, "quest progress safety task registration failed"
    end
    S.Scheduler:SetTaskModule(self.safetyTask, self.Id)
    self.running = true
    return self:Refresh("start", false)
end

function P:Stop()
    if self.running ~= true then return true end
    self.running = false
    if S.Events ~= nil then
        S.Events:UnsubscribeOwner(self)
        if type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
    end
    if S.RefreshCoordinator ~= nil and type(S.RefreshCoordinator.Cancel) == "function" then
        S.RefreshCoordinator:Cancel(self, "quest_progress")
    end
    if S.Scheduler ~= nil then S.Scheduler:RemoveTask(self.safetyTask) end
    return true
end

function P:ReconcileDemand(before, after, context)
    local beforeCount = tonumber(before and before.count) or 0
    local afterCount = tonumber(after and after.count) or 0
    if beforeCount == 0 and afterCount > 0 then
        local synced, syncErr = self:SyncInstanceConsumer()
        if synced ~= true then return false, syncErr end
        return self:Start()
    end
    if beforeCount > 0 and afterCount == 0 then
        self:Stop()
        return self:SyncInstanceConsumer()
    end

    local synced, syncErr = self:SyncInstanceConsumer()
    if synced ~= true then return false, syncErr end
    if afterCount > 0 and not (context and context.rollback == true) then
        local wantsInstances = self:HasInstanceDemand()
        return self:Refresh("consumer_options_changed", wantsInstances)
    end
    return true
end

function P:QuiesceDemand(reason, cause)
    local ok = self:Stop() == true
    if self.instanceConsumerHeld == true then
        local service = S.Services and S.Services.InstanceCatalogV3 or nil
        if type(service) ~= "table" or type(service.ReleaseConsumer) ~= "function" then
            ok = false
        else
            local released = service:ReleaseConsumer(self.instanceConsumerToken)
            if released ~= true then ok = false else self.instanceConsumerHeld = false end
        end
    end
    return ok
end

if S.Demand == nil or type(S.Demand.Create) ~= "function" then error("Demand unavailable for QuestProgressV3") end
local questDemand, questDemandErr = S.Demand:Create({
    id = P.Id,
    owner = P,
    projectionOwner = P,
    projectionConsumersField = "consumers",
    projectionCountField = "consumerCount",
    normalize = function(options)
        options = type(options) == "table" and options or {}
        return { instances = options.instances == true }
    end,
    reconcile = function(_, before, after, context) return P:ReconcileDemand(before, after, context) end,
    quiesce = function(_, reason, cause) return P:QuiesceDemand(reason, cause) end,
})
if questDemand == nil then error(questDemandErr) end
P.Demand = questDemand

function P:AcquireConsumer(token, options)
    return self.Demand:Acquire(token, options, "quest_progress_consumer")
end

function P:ReleaseConsumer(token)
    return self.Demand:Release(token, "quest_progress_consumer")
end

function P:GetProgress(scope, key)
    scope = tostring(scope or "event")
    key = tostring(key or "")
    if scope == "event" then return CopySnapshot(self.snapshots[key]) end
    local bucket = type(self.scopeSnapshots) == "table" and self.scopeSnapshots[scope] or nil
    if type(bucket) ~= "table" then return nil end
    return CopySnapshot(bucket[key])
end

function P:GetQuestProgress(scope, key)
    local value = self:GetProgress(scope, key)
    if value == nil or value.kind == "instanceRaid" then return nil end
    return value
end

function P:GetInstanceProgress(scope, key)
    local value = self:GetProgress(scope, key)
    if value == nil or value.kind ~= "instanceRaid" then return nil end
    return value
end

local DETAIL_STATE_PRIORITY = {
    [QS.COMPLETED] = 4,
    [QS.READY_TO_TURN_IN] = 3,
    [QS.IN_PROGRESS] = 2,
    [QS.NOT_ACCEPTED] = 1,
    [QS.UNKNOWN] = 0,
}
local DETAIL_STATE_TEXT = {
    [QS.COMPLETED] = "已完成",
    [QS.READY_TO_TURN_IN] = "可交付",
    [QS.IN_PROGRESS] = "进行中",
    [QS.NOT_ACCEPTED] = "未接",
    [QS.UNKNOWN] = "未知",
}
local DETAIL_STATE_TONE = {
    [QS.COMPLETED] = "green",
    [QS.READY_TO_TURN_IN] = "orange",
    [QS.IN_PROGRESS] = "yellow",
    [QS.NOT_ACCEPTED] = "muted",
    [QS.UNKNOWN] = "red",
}

function P:QuestTitle(qid, fallback)
    qid = tonumber(qid)
    if qid == nil then return tostring(fallback or "任务") end
    local cached = self.questTitleCache[qid]
    if type(cached) == "string" and cached ~= "" then return cached end
    if Capability("X2Quest:GetQuestContextMainTitle") then
        local questHost = rawget(_G, "X2Quest")
        if questHost ~= nil then
            local ok, title = S.Api:CallCapability("X2Quest:GetQuestContextMainTitle", questHost, "GetQuestContextMainTitle", qid)
            if ok == true and type(title) == "string" and title ~= "" then
                self.questTitleCache[qid] = title
                return title
            end
        end
    end
    return tostring(fallback or ("任务 " .. tostring(qid)))
end

function P:ResolveObjectiveDetail(objective, index, related)
    objective = type(objective) == "table" and objective or {}
    local bestState, bestQuest = QS.UNKNOWN, nil
    local bestPriority = -1
    local variants = {}
    for _, rawId in ipairs(type(objective.quests) == "table" and objective.quests or {}) do
        local qid = tonumber(rawId)
        if qid ~= nil then
            variants[#variants + 1] = qid
            local state = self:QuestState(qid, self.activeIndex)
            local priority = DETAIL_STATE_PRIORITY[state] or 0
            if priority > bestPriority then
                bestPriority, bestState, bestQuest = priority, state, qid
            end
        end
    end
    if bestQuest == nil and variants[1] ~= nil then bestQuest = variants[1] end
    if bestState == QS.UNKNOWN and bestQuest ~= nil then bestState = self:QuestState(bestQuest, self.activeIndex) end

    local role = tostring(objective.role or "")
    local fallback = role ~= "" and role or ((related == true and "关联任务 " or "任务阶段 ") .. tostring(index or 1))
    local title = self:QuestTitle(bestQuest, fallback)
    if role ~= "" and title ~= role and string.find(title, role, 1, true) == nil then
        title = role .. " · " .. title
    end
    local category = related == true and (role ~= "" and role or "关联") or "主任务"
    return {
        key = (related == true and "related:" or "main:") .. tostring(index or 1),
        category = category,
        name = title,
        status = DETAIL_STATE_TEXT[bestState] or "未知",
        tone = DETAIL_STATE_TONE[bestState] or "muted",
        state = bestState,
        questId = bestQuest,
        variants = variants,
        related = related == true,
        counted = related ~= true,
        keepsEventAlive = objective.keepsEventAlive == true,
    }
end

local function FindGroup(scope, key)
    scope, key = tostring(scope or "event"), tostring(key or "")
    if key == "" then return nil end
    if scope == "event" then
        return S.Data and S.Data.EventQuestProgress and S.Data.EventQuestProgress[key] or nil
    end
    local groups = S.Data and S.Data.QuestGroups and S.Data.QuestGroups[scope] or nil
    if type(groups) ~= "table" then return nil end
    for _, group in ipairs(groups) do
        if type(group) == "table" and tostring(group.key or "") == key then return group end
    end
    return nil
end

function P:GetGroupDetail(scope, key)
    scope, key = tostring(scope or "event"), tostring(key or "")
    if key == "" then return nil end
    local group = FindGroup(scope, key)
    if type(group) ~= "table" then return nil end

    if group.kind == "instanceRaid" then
        local snapshot = self:GetInstanceProgress("event", key)
        local available = type(snapshot) == "table" and snapshot.available == true
        local entered = available and (tonumber(snapshot.completed) or 0) > 0
        local count = available and math.max(0, math.floor(tonumber(snapshot.enterCount) or 0)) or 0
        local rawMax = available and math.max(0, math.floor(tonumber(snapshot.maxEnterCount) or 0)) or 0
        local configuredMax = math.max(1, math.floor(tonumber(group.instanceRaid and group.instanceRaid.maxEntry) or 1))
        local displayMax = rawMax > 0 and rawMax ~= 1000 and rawMax or configuredMax
        return {
            scope = scope, key = key, title = tostring(group.title or key), kind = "instanceRaid",
            completed = entered and 1 or 0, total = 1, activeCount = 0, readyCount = 0, relatedCount = 0,
            summaryText = available and ("副本参与 " .. tostring(math.min(count, displayMax)) .. "/" .. tostring(displayMax)) or "副本参与状态暂不可用",
            children = {
                {
                    key = "instance_entry", category = "副本", name = "副本参与次数",
                    status = available and (entered and "已完成" or (tostring(math.min(count, displayMax)) .. "/" .. tostring(displayMax))) or "暂不可用",
                    tone = available and (entered and "green" or "muted") or "red",
                    state = entered and QS.COMPLETED or (available and QS.NOT_ACCEPTED or QS.UNKNOWN),
                    related = false, counted = true,
                },
            },
        }
    end

    local children = {}
    local completed, activeCount, readyCount = 0, 0, 0
    for index, objective in ipairs(ObjectiveList(group)) do
        local row = self:ResolveObjectiveDetail(objective, index, false)
        children[#children + 1] = row
        if row.state == QS.COMPLETED then completed = completed + 1
        elseif row.state == QS.READY_TO_TURN_IN then completed = completed + 1; readyCount = readyCount + 1
        elseif row.state == QS.IN_PROGRESS then activeCount = activeCount + 1 end
    end
    local relatedCount = 0
    for index, objective in ipairs(RelatedList(group)) do
        relatedCount = relatedCount + 1
        children[#children + 1] = self:ResolveObjectiveDetail(objective, index, true)
    end
    local total = #ObjectiveList(group)
    local summary = total > 0 and ("已完成 " .. tostring(completed) .. "/" .. tostring(total)) or "暂无主任务"
    if readyCount > 0 then summary = summary .. " · " .. tostring(readyCount) .. " 项可交付" end
    if activeCount > 0 then summary = summary .. " · " .. tostring(activeCount) .. " 项进行中" end
    if relatedCount > 0 then summary = summary .. " · " .. tostring(relatedCount) .. " 项关联任务" end
    return {
        scope = scope, key = key, title = tostring(group.title or key), kind = tostring(group.kind or "activity"),
        completed = completed, total = total, activeCount = activeCount, readyCount = readyCount, relatedCount = relatedCount,
        summaryText = summary, children = children,
    }
end

function P:GetHealth(scope)
    scope = tostring(scope or "event")
    local maps = {}
    if scope == "all" then
        maps = { self.snapshots, self.scopeSnapshots and self.scopeSnapshots.daily, self.scopeSnapshots and self.scopeSnapshots.weekly }
    elseif scope == "event" then
        maps = { self.snapshots }
    else
        maps = { self.scopeSnapshots and self.scopeSnapshots[scope] }
    end
    local available, total = 0, 0
    for _, bucket in ipairs(maps) do
        for _, value in pairs(type(bucket) == "table" and bucket or {}) do
            total = total + 1
            if value.available == true then available = available + 1 end
        end
    end
    return {
        ok = self.running == true or self.consumerCount == 0,
        running = self.running == true,
        consumers = self.consumerCount,
        revision = self.revision,
        projections = total,
        available = available,
        refreshFailures = self.refreshFailures,
        instanceDemand = self:HasInstanceDemand(),
        instanceConsumerHeld = self.instanceConsumerHeld == true,
        updatedAtMs = self.updatedAtMs,
        scope = scope,
    }
end

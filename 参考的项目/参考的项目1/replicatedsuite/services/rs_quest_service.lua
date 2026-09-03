------------------------------------------------------------------------
-- Replicated Suite - Quest Authority
-- Author: Replicated
--
-- RU whitelist-safe quest state. Exact objective counters are not exposed by
-- the supplied allowed API, therefore progress here means reliable logical
-- sub-task completion (completed/total), never a guessed objective counter.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Services = S.Services or {}
S.Services.Quest = {}
local Q = S.Services.Quest
local QS = S.Constants.QuestStatus
local EVENT_TASK_TRACKING_FORMAT = 3

local STATUS_TEXT = {
    [QS.NOT_ACCEPTED] = "未接", [QS.IN_PROGRESS] = "进行中",
    [QS.READY_TO_TURN_IN] = "可交付", [QS.COMPLETED] = "已完成",
    [QS.UNAVAILABLE] = "未解锁", [QS.UNKNOWN] = "未知",
}
local STATUS_TONE = {
    [QS.NOT_ACCEPTED] = "muted", [QS.IN_PROGRESS] = "yellow",
    [QS.READY_TO_TURN_IN] = "orange", [QS.COMPLETED] = "green",
    [QS.UNAVAILABLE] = "muted", [QS.UNKNOWN] = "red",
}
local PRIORITY = {
    [QS.READY_TO_TURN_IN] = 1, [QS.IN_PROGRESS] = 2,
    [QS.NOT_ACCEPTED] = 3, [QS.UNKNOWN] = 4,
    [QS.UNAVAILABLE] = 5, [QS.COMPLETED] = 6,
}

-- Legacy migration hook. Older Suite builds tracked the repeatable
-- Cinderstone/Ynystere competition itself and needed a local once-per-day latch.
-- Current data tracks the actual once-per-day Industry Dynamo reward quests, so
-- X2Quest:IsCompleted is the Authority and no event key needs local latching.
local REPEATABLE_DAILY_EVENT_KEYS = {}
Q.lastRepeatableActive = {}
Q.pendingCompletionEvent = false

function Q:GetEventDailyDone()
    S.State.life = type(S.State.life)=="table" and S.State.life or {}
    local dateKey=S.Utils.ServerDateKey()
    local bucket=S.State.life.eventDailyDone
    -- Cold-window guard (2026-08-24): right after login/reload the server time
    -- table can be unavailable and ServerDateKey() returns "unknown". Treating
    -- that as a different day would wipe the restored same-day keys AND write
    -- the empty bucket back over the saved one. Keep the existing bucket until
    -- a real date is known.
    if dateKey ~= "unknown" and (type(bucket)~="table" or tostring(bucket.dateKey or "")~=tostring(dateKey)) then
        bucket={dateKey=dateKey,keys={}}
        S.State.life.eventDailyDone=bucket
        S.Storage:RequestSave(0)
    end
    if type(bucket)~="table" then bucket={dateKey=dateKey,keys={}}; S.State.life.eventDailyDone=bucket end
    if type(bucket.keys)~="table" then bucket.keys={} end
    return bucket
end

function Q:IsEventDailyDone(key)
    local bucket=self:GetEventDailyDone()
    return bucket.keys[tostring(key or "")]==true
end

function Q:SetEventDailyDone(key)
    key=tostring(key or "")
    if REPEATABLE_DAILY_EVENT_KEYS[key]==nil then return false end
    local bucket=self:GetEventDailyDone()
    if bucket.keys[key]==true then return false end
    bucket.keys[key]=true
    S.Storage:RequestSave(0)
    return true
end

function Q:CaptureRepeatableDailyCompletion(activeIndex)
    activeIndex=type(activeIndex)=="table" and activeIndex or {}
    local previous=type(self.lastRepeatableActive)=="table" and self.lastRepeatableActive or {}
    if self.pendingCompletionEvent==true then
        for key,qids in pairs(REPEATABLE_DAILY_EVENT_KEYS) do
            local wasActive=false
            local stillActive=false
            for qid in pairs(qids) do
                if previous[qid]==true then wasActive=true end
                if activeIndex[qid]~=nil then stillActive=true end
            end
            if wasActive and not stillActive then self:SetEventDailyDone(key) end
        end
    end
    self.pendingCompletionEvent=false
    local nextActive={}
    for _,qids in pairs(REPEATABLE_DAILY_EVENT_KEYS) do
        for qid in pairs(qids) do if activeIndex[qid]~=nil then nextActive[qid]=true end end
    end
    self.lastRepeatableActive=nextActive
end


function Q:BuildActiveIndex()
    local map, count = {}, 0
    local ok, value = S.Api:CallCapability("X2Quest:GetActiveQuestListCount", X2Quest, "GetActiveQuestListCount")
    if ok then count = tonumber(value) or 0 end
    for index = 1, count do
        local okId, qid = S.Api:CallCapability("X2Quest:GetActiveQuestType", X2Quest, "GetActiveQuestType", index)
        qid = okId and tonumber(qid) or nil
        if qid ~= nil then map[qid] = index end
    end
    return map
end

function Q:QuestTitle(qid, fallback)
    local ok, title = S.Api:CallCapability("X2Quest:GetQuestContextMainTitle", X2Quest, "GetQuestContextMainTitle", qid)
    if ok and type(title) == "string" and title ~= "" then return title end
    return fallback or ("任务 " .. tostring(qid))
end

function Q:QuestState(qid, activeIndex)
    -- Completion must win over active-list membership. ArcheRage can keep a
    -- quest context in the active list while its objective is already complete.
    local okDone, done = S.Api:CallCapability("X2Quest:IsCompleted", X2Quest, "IsCompleted", qid)
    if okDone and done == true then return QS.COMPLETED, activeIndex[qid] end

    -- IMPORTANT: IsCompleted() means the quest has been handed in / entered the
    -- completed history. A player who has already satisfied every objective but
    -- has not handed the quest in yet remains in the active list. The official
    -- RU whitelist now exposes IsReadyForCompleteQuest(), so represent that
    -- state explicitly instead of misreporting it as unfinished.
    if activeIndex[qid] ~= nil then
        local okReady, ready = S.Api:CallCapability("X2Quest:IsReadyForCompleteQuest", X2Quest, "IsReadyForCompleteQuest", qid)
        if okReady and ready == true then return QS.READY_TO_TURN_IN, activeIndex[qid] end
        return QS.IN_PROGRESS, activeIndex[qid]
    end
    return QS.NOT_ACCEPTED, nil
end

local function ObjectiveList(group)
    if type(group.objectives) == "table" and #group.objectives > 0 then return group.objectives end
    local result = {}
    for _, qid in ipairs(group.quests or {}) do result[#result + 1] = { quests = { qid } } end
    return result
end

local function RelatedObjectiveList(group)
    if type(group) ~= "table" or type(group.relatedObjectives) ~= "table" then return {} end
    return group.relatedObjectives
end

local function ObjectiveTrackingKey(objective, related, index)
    objective = type(objective)=="table" and objective or {}
    if objective.trackingKey~=nil and tostring(objective.trackingKey)~="" then
        return (related==true and "r:" or "c:")..tostring(objective.trackingKey)
    end
    local parts = {}
    for _, qid in ipairs(type(objective.quests)=="table" and objective.quests or {}) do
        parts[#parts+1] = tostring(qid)
    end
    if #parts>0 then return (related==true and "r:" or "c:")..table.concat(parts,",") end
    return (related==true and "r:" or "c:").."idx:"..tostring(index or 0)..":"..tostring(objective.title or objective.role or "task")
end

function Q:GetEventTaskTracking()
    S.State.life = type(S.State.life) == "table" and S.State.life or {}
    local tracking = S.State.life.eventTaskTracking
    if type(tracking) ~= "table" then
        tracking = { formatVersion = EVENT_TASK_TRACKING_FORMAT, groups = {} }
        S.State.life.eventTaskTracking = tracking
    else
        local formatVersion = tonumber(tracking.formatVersion) or 1
        if formatVersion == 2 then
            -- Format 2 stored only positive selections in group.keys.  For a
            -- canonical objective, however, absence also meant an explicit OFF
            -- after the group had been configured.  That sparse representation
            -- is unsafe across state copies/default reconciliation because the
            -- same missing key also means "use the default".  Format 3 stores
            -- an explicit boolean for every user-touched/current objective.
            local migratedGroups = {}
            for groupKey, oldGroup in pairs(type(tracking.groups)=="table" and tracking.groups or {}) do
                if type(oldGroup)=="table" then
                    local migrated = { configured = oldGroup.configured == true, keys = {} }
                    local definition = S.Data and S.Data.EventQuestProgress and S.Data.EventQuestProgress[tostring(groupKey)]
                    local oldKeys = type(oldGroup.keys)=="table" and oldGroup.keys or {}
                    if migrated.configured and type(definition)=="table" then
                        for index, objective in ipairs(ObjectiveList(definition)) do
                            local key = ObjectiveTrackingKey(objective,false,index)
                            migrated.keys[key] = oldKeys[key] == true
                        end
                        for index, objective in ipairs(RelatedObjectiveList(definition)) do
                            local key = ObjectiveTrackingKey(objective,true,index)
                            migrated.keys[key] = oldKeys[key] == true
                        end
                    else
                        for key, enabled in pairs(oldKeys) do
                            if enabled==true or enabled==false then migrated.keys[tostring(key)] = enabled==true end
                        end
                    end
                    migratedGroups[tostring(groupKey)] = migrated
                end
            end
            tracking = { formatVersion = EVENT_TASK_TRACKING_FORMAT, groups = migratedGroups }
            S.State.life.eventTaskTracking = tracking
            if S.Storage ~= nil and type(S.Storage.RequestSave) == "function" then S.Storage:RequestSave(0) end
        elseif formatVersion ~= EVENT_TASK_TRACKING_FORMAT then
            -- Format 1 used the same visual check mark for both completion and
            -- tracking and made the whole quest row clickable. Saved selections
            -- from that build are ambiguous, so reset them exactly once.
            tracking = { formatVersion = EVENT_TASK_TRACKING_FORMAT, groups = {} }
            S.State.life.eventTaskTracking = tracking
            if S.Storage ~= nil and type(S.Storage.RequestSave) == "function" then S.Storage:RequestSave(0) end
        end
    end
    if type(tracking.groups) ~= "table" then tracking.groups = {} end
    tracking.formatVersion = EVENT_TASK_TRACKING_FORMAT
    return tracking
end

function Q:GetEventTaskTrackingGroup(groupKey)
    groupKey=tostring(groupKey or "")
    if groupKey=="" then return nil end
    local tracking=self:GetEventTaskTracking()
    local group=tracking.groups[groupKey]
    if type(group)~="table" then return nil end
    if type(group.keys)~="table" then group.keys={} end
    return group
end

function Q:IsEventObjectiveTracked(groupKey, objective, related, index)
    local defaultTracked = related ~= true
    local group=self:GetEventTaskTrackingGroup(groupKey)
    if group==nil or group.configured~=true then return defaultTracked end
    local stored = group.keys[ObjectiveTrackingKey(objective,related,index)]
    if stored == nil then return defaultTracked end
    return stored == true
end

function Q:EnsureEventTaskTrackingConfigured(groupKey)
    groupKey=tostring(groupKey or "")
    if groupKey=="" then return nil end
    local definition=S.Data and S.Data.EventQuestProgress and S.Data.EventQuestProgress[groupKey]
    if type(definition)~="table" then return nil end
    local tracking=self:GetEventTaskTracking()
    local group=tracking.groups[groupKey]
    if type(group)~="table" then group={configured=false,keys={}}; tracking.groups[groupKey]=group end
    if type(group.keys)~="table" then group.keys={} end
    if group.configured==true then return group end
    -- Format 3 is override-based: nil means use the objective default
    -- (canonical=true, related=false). Do not prefill a whitelist here.
    group.keys={}
    group.configured=true
    return group
end

local function FindEventObjectiveByTrackingKey(definition, trackingKey)
    if type(definition)~="table" then return nil end
    trackingKey=tostring(trackingKey or "")
    if trackingKey=="" then return nil end
    for index,objective in ipairs(ObjectiveList(definition)) do
        if ObjectiveTrackingKey(objective,false,index)==trackingKey then
            return objective,false,index
        end
    end
    for index,objective in ipairs(RelatedObjectiveList(definition)) do
        if ObjectiveTrackingKey(objective,true,index)==trackingKey then
            return objective,true,index
        end
    end
    return nil
end

function Q:GetEventObjectiveTrackedByKey(groupKey, trackingKey)
    groupKey=tostring(groupKey or "")
    trackingKey=tostring(trackingKey or "")
    if groupKey=="" or trackingKey=="" then return nil end
    local definition=S.Data and S.Data.EventQuestProgress and S.Data.EventQuestProgress[groupKey]
    local objective,related,index=FindEventObjectiveByTrackingKey(definition,trackingKey)
    if objective==nil then return nil end
    return self:IsEventObjectiveTracked(groupKey,objective,related,index)==true
end

function Q:SetEventObjectiveTracked(groupKey, trackingKey, enabled)
    groupKey=tostring(groupKey or "")
    trackingKey=tostring(trackingKey or "")
    if groupKey=="" or trackingKey=="" then return false,nil end
    local definition=S.Data and S.Data.EventQuestProgress and S.Data.EventQuestProgress[groupKey]
    local objective,related,index=FindEventObjectiveByTrackingKey(definition,trackingKey)
    if objective==nil then return false,nil end

    local group=self:EnsureEventTaskTrackingConfigured(groupKey)
    if group==nil then return false,nil end
    local target=enabled==true
    -- Persist both sides explicitly. `false` is a real user choice; nil is
    -- reserved for "never customized / use the objective default".
    group.keys[trackingKey]=target

    -- Verify against the tracking Authority before refreshing dependent views.
    -- The UI must never decide the next state from a cached detail-row snapshot.
    local applied=self:IsEventObjectiveTracked(groupKey,objective,related,index)==true
    if applied~=target then return false,applied end

    if S.Storage ~= nil and type(S.Storage.RequestSave)=="function" then S.Storage:RequestSave() end

    -- Tracking is presentation policy, not quest-state Authority. Do not run the
    -- whole Quest Refresh synchronously from a native button OnClick: that path
    -- performs multiple X2Quest reads, marks the detail window dirty and may
    -- replace the row model while the client is still dispatching the click.
    -- Recompute only the activity x/y projection now; the normal quest event/data
    -- refresh remains responsible for authoritative quest-state changes.
    local activeIndex=self:BuildActiveIndex()
    self:RefreshEventQuestProgress(activeIndex)
    self:ScanInstanceRaids()
    S.State:MarkDirty("quests")
    if S.Services and S.Services.Event and type(S.Services.Event.Refresh)=="function" then S.Services.Event:Refresh() end
    return true,applied
end

function Q:ToggleEventObjectiveTracked(groupKey, trackingKey)
    -- Freeze the Character-scope Authority before reading the current value. If
    -- world-qualified identity resolves after this click, a late persisted
    -- Character Override must not overwrite the user's just-applied selection.
    if S.Storage ~= nil and type(S.Storage.TryResolveDeferredCharacterScope)=="function" then
        S.Storage:TryResolveDeferredCharacterScope()
    end

    -- Read the current value from Quest Service Authority at click time. Using
    -- item.tracked from the rendered row is unsafe because quest/event refreshes
    -- can replace that snapshot between two clicks.
    local current=self:GetEventObjectiveTrackedByKey(groupKey,trackingKey)
    if current==nil then return false,nil end
    return self:SetEventObjectiveTracked(groupKey,trackingKey,current~=true)
end

function Q:ObjectiveState(objective, activeIndex)
    local quests = objective.quests or {}
    local activeQid, readyQid, completedQid = nil, nil, nil
    for _, qid in ipairs(quests) do
        local state = self:QuestState(qid, activeIndex)
        -- Variant groups are mutually exclusive logical objectives. Scan every
        -- variant before deciding. State precedence is intentionally:
        -- COMPLETED > READY_TO_TURN_IN > IN_PROGRESS > NOT_ACCEPTED.
        if state == QS.COMPLETED and completedQid == nil then completedQid = qid end
        if state == QS.READY_TO_TURN_IN and readyQid == nil then readyQid = qid end
        if state == QS.IN_PROGRESS and activeQid == nil then activeQid = qid end
    end
    if completedQid ~= nil then return QS.COMPLETED, completedQid end
    if readyQid ~= nil then return QS.READY_TO_TURN_IN, readyQid end
    if activeQid ~= nil then return QS.IN_PROGRESS, activeQid end
    return QS.NOT_ACCEPTED, quests[1]
end

local function Row(group, state, completed, total, activeCount)
    local progress = total > 0 and (" " .. tostring(completed or 0) .. "/" .. tostring(total)) or ""
    return {
        key = group.key, name = group.title,
        status = (STATUS_TEXT[state] or "未知") .. progress,
        tone = STATUS_TONE[state] or "red", state = state,
        completed = completed or 0, total = total or 0,
        activeCount = activeCount or 0, priority = PRIORITY[state] or 9,
    }
end

function Q:GroupState(group, activeIndex)
    if group.kind == "guildAchievement" then return self:GuildState(group, activeIndex) end
    local objectives = ObjectiveList(group)
    local completed, ready, active = 0, 0, 0
    for _, objective in ipairs(objectives) do
        local state = self:ObjectiveState(objective, activeIndex)
        -- For logical activity progress, READY_TO_TURN_IN means the objective
        -- itself is finished. Keep the group orange/"可交付" until hand-in, but
        -- count it in x/y so users do not see 2/3 after actually finishing 3/3.
        if state == QS.COMPLETED then completed = completed + 1
        elseif state == QS.READY_TO_TURN_IN then completed = completed + 1; ready = ready + 1
        elseif state == QS.IN_PROGRESS then active = active + 1 end
    end
    local total = #objectives
    local state
    if total > 0 and completed == total then
        state = ready > 0 and QS.READY_TO_TURN_IN or QS.COMPLETED
    elseif active > 0 or completed > 0 then
        state = QS.IN_PROGRESS
    else
        state = QS.NOT_ACCEPTED
    end
    local row = Row(group, state, completed, total, active)
    row.readyCount = ready
    return row
end

function Q:GuildState(group, activeIndex)
    local available, complete = 0, 0
    if TADT_EXPEDITION ~= nil and S.Api ~= nil and type(S.Api.IsCapabilityAllowed) == "function"
        and S.Api:IsCapabilityAllowed("X2Achievement:GetTodayAssignmentInfo") == true then
        for i = 1, 7 do
            local ok, info = S.Api:CallCapability("X2Achievement:GetTodayAssignmentInfo", X2Achievement, "GetTodayAssignmentInfo", TADT_EXPEDITION, i)
            if ok and type(info) == "table" then
                local status = tonumber(info.status)
                if status == 2 then available = available + 1 elseif status == 3 then complete = complete + 1 end
            end
        end
        local total = available + complete
        if total > 0 then
            if available > 0 then return Row(group, QS.IN_PROGRESS, complete, total, available) end
            return Row(group, QS.COMPLETED, complete, total, 0)
        end
    end
    for _, qid in ipairs(group.quests or {}) do
        if activeIndex[qid] ~= nil then return Row(group, QS.IN_PROGRESS, 0, #group.quests, 1) end
    end
    return Row(group, QS.NOT_ACCEPTED, 0, #group.quests, 0)
end

-- Daily tracking is presentation policy, not quest-state Authority.  The
-- service continues to resolve every curated daily so event links/details stay
-- correct, while dashboards and summary counts consume only the selected set.
function Q:GetDailyTracking()
    S.State.life = type(S.State.life) == "table" and S.State.life or {}
    local tracking = S.State.life.dailyTracking
    if type(tracking) ~= "table" then
        tracking = { configured=false, keys={} }
        S.State.life.dailyTracking = tracking
    end
    if type(tracking.keys) ~= "table" then tracking.keys = {} end
    return tracking
end

local function IsoDateKey(value)
    if type(value) ~= "string" then return nil end
    local year, month, day = string.match(value, "^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    year, month, day = tonumber(year), tonumber(month), tonumber(day)
    if year == nil or month == nil or day == nil then return nil end
    if year < 2000 or month < 1 or month > 12 or day < 1 or day > 31 then return nil end
    return year * 10000 + month * 100 + day
end

local function CurrentServerDateKey()
    -- Server date is the Authority for seasonal visibility.  Never use the
    -- player's OS clock here: RU users can run the client from any timezone.
    if S.Utils ~= nil and type(S.Utils.ServerDateKey) == "function" then
        local value = IsoDateKey(S.Utils.ServerDateKey())
        if value ~= nil then return value end
    end
    if UIParent ~= nil and type(UIParent.GetServerTimeTable) == "function" then
        local ok, value = pcall(UIParent.GetServerTimeTable, UIParent)
        if ok and type(value) == "table" then
            local year = tonumber(value.year)
            local month = tonumber(value.month)
            local day = tonumber(value.day)
            if year ~= nil and month ~= nil and day ~= nil
                and year >= 2000 and month >= 1 and month <= 12 and day >= 1 and day <= 31 then
                return year * 10000 + month * 100 + day
            end
        end
    end
    return nil
end

local function DailyGroupDateEnabled(group, today)
    if type(group) ~= "table" then return false end
    if today == nil then
        -- Fail open if the server clock is temporarily unavailable. Hiding a
        -- valid limited-time activity is worse than showing it briefly.
        return true
    end
    local fromKey = IsoDateKey(group.activeFrom)
    local untilKey = IsoDateKey(group.activeUntil)
    if fromKey ~= nil and today < fromKey then return false end
    if untilKey ~= nil and today > untilKey then return false end
    return true
end

function Q:GetDailyGroups()
    local source = (S.Data.QuestGroups and S.Data.QuestGroups.daily) or {}
    local today = CurrentServerDateKey()
    local result = {}
    for _, group in ipairs(source) do
        if DailyGroupDateEnabled(group, today) then
            result[#result + 1] = group
        end
    end
    return result
end

function Q:IsDailyTracked(key)
    key = tostring(key or "")
    if key == "" then return false end
    local tracking = self:GetDailyTracking()
    if tracking.configured ~= true then return true end
    return tracking.keys[key] == true
end

function Q:EnsureDailyTrackingConfigured()
    local tracking = self:GetDailyTracking()
    if tracking.configured == true then return tracking end
    local keys = {}
    for _, group in ipairs(self:GetDailyGroups()) do
        if group.key ~= nil then keys[tostring(group.key)] = true end
    end
    tracking.configured = true
    tracking.keys = keys
    return tracking
end

function Q:GetDailyTrackingStats()
    local total, selected = 0, 0
    for _, group in ipairs(self:GetDailyGroups()) do
        if group.key ~= nil then
            total = total + 1
            if self:IsDailyTracked(group.key) then selected = selected + 1 end
        end
    end
    return selected, total
end

function Q:GetTrackedDailyRows(rows)
    local result = {}
    for _, row in ipairs(type(rows)=="table" and rows or {}) do
        if self:IsDailyTracked(row.key) then result[#result + 1] = row end
    end
    return result
end

function Q:RecomputeTrackedSummary()
    local unfinished = 0
    for _, row in ipairs(S.State.data.daily or {}) do
        if self:IsDailyTracked(row.key)
            and row.state ~= QS.COMPLETED
            and row.state ~= QS.UNAVAILABLE then
            unfinished = unfinished + 1
        end
    end
    S.State.data.summary.unfinished = unfinished
end

function Q:SetDailyTracked(key, enabled)
    key = tostring(key or "")
    if key == "" or self:FindGroup("daily", key) == nil then return false end
    local tracking = self:EnsureDailyTrackingConfigured()
    if enabled == true then tracking.keys[key] = true else tracking.keys[key] = nil end
    self:RecomputeTrackedSummary()
    S.State:MarkDirty("quests")
    S.Storage:RequestSave()
    return true
end

function Q:ToggleDailyTracked(key)
    return self:SetDailyTracked(key, not self:IsDailyTracked(key))
end

function Q:SetAllDailyTracked(enabled)
    local tracking = self:GetDailyTracking()
    tracking.configured = true
    tracking.keys = {}
    if enabled == true then
        for _, group in ipairs(self:GetDailyGroups()) do
            if group.key ~= nil then tracking.keys[tostring(group.key)] = true end
        end
    end
    self:RecomputeTrackedSummary()
    S.State:MarkDirty("quests")
    S.Storage:RequestSave()
end

function Q:FindGroup(scope, key)
    -- Event rows have a dedicated logical-objective model whose denominator is
    -- exactly the progress shown by the event panel (e.g. Whalesong 3/3,
    -- Aegis 3/3, purification 1/1). Build a read-only group from that model so
    -- clicking a live-zone chip opens details matching the displayed progress.
    if scope == "event" then
        local definition = S.Data.EventQuestProgress and S.Data.EventQuestProgress[key]
        if type(definition) ~= "table" then return nil end
        return {
            key = key,
            title = definition.title or tostring(key or "活动任务"),
            objectives = definition.objectives or {},
            relatedObjectives = definition.relatedObjectives or {},
            -- instanceRaid groups (红龙巢穴 / 血之使者卡杜姆) keep their kind and
            -- raid config so GetGroupDetail renders the entry-counter row.
            kind = definition.kind or "event",
            instanceRaid = definition.instanceRaid,
        }
    end
    local groups
    if scope == "daily" then
        groups = self:GetDailyGroups()
    else
        groups = S.Data.QuestGroups and S.Data.QuestGroups[scope]
    end
    if type(groups) ~= "table" then return nil end
    for _, group in ipairs(groups) do if group.key == key then return group end end
    return nil
end

function Q:GetGroupDetail(scope, key)
    local group = self:FindGroup(scope, key)
    if group == nil then return nil end
    -- Instance-raid detail: one row describing the account entry counter
    -- ("1/1" = entered = completed).  There are no quest children to track.
    if group.kind == "instanceRaid" then return self:InstanceRaidGroupDetail(group) end
    local active = self:BuildActiveIndex()
    local children, completed, readyCount, activeCount, trackedTotal = {}, 0, 0, 0, 0
    local objectives = ObjectiveList(group)

    local function AppendObjective(objective, objectiveIndex, defaultCounted, relatedIndex)
        local state, chosenQid = self:ObjectiveState(objective, active)
        local isRelated=relatedIndex~=nil
        local trackingKey=ObjectiveTrackingKey(objective,isRelated,relatedIndex or objectiveIndex)
        -- Do not use Lua's `a and b or c` as a ternary here. `false` is a
        -- meaningful tracking value: for canonical event objectives the old
        -- expression turned an explicit OFF back into `defaultCounted == true`
        -- during detail Reload, while the HUD correctly stayed untracked.
        local tracked
        local counted
        if scope == "event" then
            tracked = self:IsEventObjectiveTracked(key, objective, isRelated, relatedIndex or objectiveIndex) == true
            counted = tracked
        else
            tracked = defaultCounted == true
            counted = defaultCounted == true
        end
        if counted then
            trackedTotal=trackedTotal+1
            if state == QS.COMPLETED then
                completed = completed + 1
            elseif state == QS.READY_TO_TURN_IN then
                completed = completed + 1
                readyCount = readyCount + 1
            elseif state == QS.IN_PROGRESS then
                activeCount = activeCount + 1
            end
        end

        local title = objective.title
        if title == nil or title == "" then
            title = self:QuestTitle(chosenQid, "任务 " .. tostring(chosenQid or objectiveIndex))
        end
        local role = tostring(objective.role or "")
        if role ~= "" then title = "[" .. role .. "] " .. tostring(title) end

        children[#children + 1] = {
            id = chosenQid, objectiveIndex = objectiveIndex,
            name = title, status = STATUS_TEXT[state] or "未知",
            tone = STATUS_TONE[state] or "red", state = state,
            active = state == QS.IN_PROGRESS,
            ready = state == QS.READY_TO_TURN_IN,
            variants = objective.quests,
            counted = counted,
            tracked = tracked,
            trackingKey = trackingKey,
            trackingSelectable = scope=="event",
        }
    end

    for objectiveIndex, objective in ipairs(objectives) do
        AppendObjective(objective, objectiveIndex, true, nil)
    end
    for relatedIndex, objective in ipairs(RelatedObjectiveList(group)) do
        -- Related quests default to untracked but remain user-selectable in the
        -- event detail view. A high sort index preserves stable order within the
        -- same state while active/ready related Boss tasks can still surface.
        AppendObjective(objective, 1000 + relatedIndex, false, relatedIndex)
    end

    table.sort(children, function(a, b)
        -- Event detail rows are controls as well as status display. Keep their
        -- positions stable while quest events refresh so a tracking click can
        -- never appear to jump to a different task. Daily/weekly detail keeps
        -- the historical state-priority ordering.
        if scope == "event" then
            return (tonumber(a.objectiveIndex) or 0) < (tonumber(b.objectiveIndex) or 0)
        end
        local ap, bp = PRIORITY[a.state] or 9, PRIORITY[b.state] or 9
        if ap ~= bp then return ap < bp end
        return (tonumber(a.objectiveIndex) or 0) < (tonumber(b.objectiveIndex) or 0)
    end)
    local total = scope=="event" and trackedTotal or #objectives
    return {
        scope = scope, key = key, title = group.title, kind = group.kind,
        children = children, completed = completed, total = total,
        activeCount = activeCount,
        readyCount = readyCount,
        relatedCount = #RelatedObjectiveList(group),
        progressText = total > 0 and ("已完成 " .. tostring(completed) .. "/" .. tostring(total)
            .. (readyCount > 0 and (" · " .. tostring(readyCount) .. " 项可交付") or "")
            .. (activeCount > 0 and (" · " .. tostring(activeCount) .. " 项进行中") or "")
            .. (scope~="event" and #RelatedObjectiveList(group) > 0 and (" · 另记录 " .. tostring(#RelatedObjectiveList(group)) .. " 项关联任务") or ""))
            or (scope=="event" and "未选择追踪任务" or "暂无可识别子任务"),
    }
end

function Q:OpenGroupDetail(scope, key)
    if S.QuestDetailWindow ~= nil and type(S.QuestDetailWindow.Open) == "function" then S.QuestDetailWindow:Open(scope, key) end
end

-- Detail projection for instance-raid groups (红龙巢穴 / 血之使者卡杜姆).
-- These raids have no quest children: the single row reports the account entry
-- counter from the latest instance scan ("1/1" = entered = completed).
function Q:InstanceRaidGroupDetail(group)
    local key = tostring(group.key or "")
    local snapshot = S.State.data.instanceRaidEntries
    local entry = type(snapshot) == "table" and snapshot[key] or nil
    local raidConfig = type(group.instanceRaid) == "table" and group.instanceRaid or {}
    local configuredMax = tonumber(raidConfig.maxEntry) or 1
    local state, tone, status, completed
    if entry ~= nil then
        local enterCount = math.max(0, tonumber(entry.enterCount) or 0)
        local maxEnter = tonumber(entry.maxEnterCount) or configuredMax
        if entry.entered == true then
            state, tone, completed = QS.COMPLETED, "green", 1
            status = "已完成 " .. tostring(enterCount) .. "/" .. tostring(maxEnter)
        else
            state, tone, completed = QS.NOT_ACCEPTED, "muted", 0
            status = "未进入 " .. tostring(enterCount) .. "/" .. tostring(maxEnter)
        end
    else
        state, tone, completed = QS.UNKNOWN, "red", 0
        status = "副本入场状态暂不可用"
    end
    local child = {
        id = nil, objectiveIndex = 1,
        name = "副本入场次数（每账号 1 次）",
        status = status, tone = tone, state = state,
        active = false, ready = false,
        variants = {},
        counted = true, tracked = true,
        trackingKey = "instance_entry",
        trackingSelectable = false,
    }
    return {
        scope = "event", key = key, title = group.title or tostring(key),
        kind = "instanceRaid",
        children = { child },
        completed = completed, total = 1,
        activeCount = 0, readyCount = 0,
        relatedCount = 0,
        progressText = entry ~= nil and status or "副本入场状态暂不可用",
    }
end

function Q:IsQuestCompleted(qid)
    qid = tonumber(qid)
    if qid == nil then return false end
    local ok, done = S.Api:CallCapability("X2Quest:IsCompleted", X2Quest, "IsCompleted", qid)
    return ok and done == true
end

function Q:SortRows(rows)
    table.sort(rows, function(a, b)
        if a.priority ~= b.priority then return a.priority < b.priority end
        return tostring(a.name) < tostring(b.name)
    end)
end

function Q:RefreshEventQuestProgress(activeIndex)
    local result = {}
    for key, definition in pairs((S.Data and S.Data.EventQuestProgress) or {}) do
        -- Instance-raid rows (kind == "instanceRaid": 红龙巢穴 / 血之使者卡杜姆)
        -- are NOT quests.  Their progress is published by ScanInstanceRaids from
        -- the client instance entry counter; projecting an empty quest snapshot
        -- here would clobber that data on every quest refresh.
        if type(definition) ~= "table" or definition.kind == "instanceRaid" then
            -- skipped: instance-raid Authority lives in ScanInstanceRaids
        else
        local objectives = type(definition) == "table" and definition.objectives or nil
        if type(objectives) == "table" then
            local completed, ready, active = 0, 0, 0
            local tailInFlight = 0
            local total=0
            for index, objective in ipairs(objectives) do
                local state = self:ObjectiveState(objective, activeIndex)
                local tracked=self:IsEventObjectiveTracked(key,objective,false,index)
                if tracked then
                    total=total+1
                    if state == QS.COMPLETED then completed = completed + 1
                    elseif state == QS.READY_TO_TURN_IN then completed = completed + 1; ready = ready + 1
                    elseif state == QS.IN_PROGRESS then active = active + 1 end
                end
                if tracked and objective.keepsEventAlive == true
                    and (state == QS.IN_PROGRESS or state == QS.READY_TO_TURN_IN) then
                    tailInFlight = tailInFlight + 1
                end
            end

            local relatedActive, relatedReady = 0, 0
            for index, objective in ipairs(RelatedObjectiveList(definition)) do
                local state = self:ObjectiveState(objective, activeIndex)
                if state == QS.IN_PROGRESS then relatedActive = relatedActive + 1
                elseif state == QS.READY_TO_TURN_IN then relatedReady = relatedReady + 1 end
                local tracked=self:IsEventObjectiveTracked(key,objective,true,index)
                if tracked then
                    total=total+1
                    if state == QS.COMPLETED then completed=completed+1
                    elseif state == QS.READY_TO_TURN_IN then completed=completed+1; ready=ready+1
                    elseif state == QS.IN_PROGRESS then active=active+1 end
                end
                if tracked and objective.keepsEventAlive == true
                    and (state == QS.IN_PROGRESS or state == QS.READY_TO_TURN_IN) then
                    tailInFlight = tailInFlight + 1
                end
            end

            local logicalKey=tostring(key)
            if REPEATABLE_DAILY_EVENT_KEYS[logicalKey]~=nil then
                if total>0 and completed>=total then self:SetEventDailyDone(logicalKey) end
                if self:IsEventDailyDone(logicalKey) then completed=total; active=0 end
            end
            result[logicalKey] = {
                completed = completed, total = total, activeCount = active, readyCount = ready,
                relatedActiveCount = relatedActive, relatedReadyCount = relatedReady,
                tailInFlightCount = tailInFlight,
                text = total > 0 and (tostring(completed) .. "/" .. tostring(total)) or "--",
                dailyLatched = REPEATABLE_DAILY_EVENT_KEYS[logicalKey]~=nil and self:IsEventDailyDone(logicalKey) or false,
            }
        end
        end
    end
    S.State.data.eventQuestProgress = result
end

------------------------------------------------------------------------
-- Instance-raid Authority (红龙巢穴 / 血之使者卡杜姆)
--
-- These activities are team raids, NOT quests: each account has ONE entry per
-- reset and the client's instance-entrance UI reports the used counter as
-- "cur/max" (e.g. "1/1" after the account entered).  The RU addon whitelist
-- exposes the underlying getters since 2026-05-19:
--
--   X2BattleField:GetInstanceUiKindList()        -> kinds { name, type, ... }
--   X2BattleField:GetInstanceListByKind(kind)    -> instances { type, ... }
--   X2BattleField:GetInstanceName(instanceType)  -> localized display name
--   X2BattleField:GetDetailInstanceInfo(instanceType) -> { name, enterCount,
--                                                          maxEnterCount, ... }
--
-- instanceType ids are server data and are NOT documented, so the Suite
-- discovers each raid at runtime by matching the localized instance name
-- (zh_cn/en_us/ru candidates from the data table) and caches the resolved id
-- per session.  Steady-state scans only re-read GetDetailInstanceInfo for the
-- cached ids, so the periodic refresh stays cheap.  A raid counts as completed
-- when enterCount >= maxEnterCount and the limit is a real entry limit
-- (maxEnterCount > 0 and ~= 1000; the client uses 1000 for "unlimited").
------------------------------------------------------------------------
Q.instanceRaidTypes = {}
Q.instanceRaidMissing = {}

local function InstanceRaidDefinitions()
    local result = {}
    local source = S.Data and S.Data.EventQuestProgress
    if type(source) ~= "table" then return result end
    for key, definition in pairs(source) do
        if type(definition) == "table" and definition.kind == "instanceRaid"
            and type(definition.instanceRaid) == "table" then
            result[tostring(key)] = definition
        end
    end
    return result
end

local function InstanceRaidCapabilityAllowed()
    if S.Api == nil or type(S.Api.IsCapabilityAllowed) ~= "function" then return false end
    if S.Api:IsCapabilityAllowed("X2BattleField:GetInstanceUiKindList") ~= true then return false end
    if S.Api:IsCapabilityAllowed("X2BattleField:GetInstanceListByKind") ~= true then return false end
    if S.Api:IsCapabilityAllowed("X2BattleField:GetDetailInstanceInfo") ~= true then return false end
    return true
end

local function MatchInstanceRaidKey(name, definitions)
    local n = string.lower(tostring(name or ""))
    if n == "" then return nil end
    for key, definition in pairs(definitions) do
        local candidates = type(definition.instanceRaid) == "table"
            and type(definition.instanceRaid.matchNames) == "table"
            and definition.instanceRaid.matchNames or {}
        for _, candidate in ipairs(candidates) do
            local c = string.lower(tostring(candidate))
            if c ~= "" and string.find(n, c, 1, true) ~= nil then return key end
        end
    end
    return nil
end

function Q:ScanInstanceRaids()
    -- Fault isolation: the instance-entrance getters run against live client
    -- state that can be unavailable (entrance UI never opened, data not pushed
    -- yet, API temporarily blocked).  This scan is a projection-only helper and
    -- must NEVER break Q:Refresh or the quest detail click path, regardless of
    -- what the client returns.
    local ok, err = xpcall(function() self:ScanInstanceRaidsInner() end, S.SafeTraceback)
    if not ok then
        if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Record) == "function" then
            S.DiagnosticsManager:Record("warning", "quest", "instance raid 扫描失败: " .. tostring(err))
        end
    end
    return ok
end

function Q:ScanInstanceRaidsInner()
    local definitions = InstanceRaidDefinitions()
    if next(definitions) == nil then return end
    if InstanceRaidCapabilityAllowed() ~= true then return end
    local battleField = rawget(_G, "X2BattleField")
    if battleField == nil then return end

    local types = type(self.instanceRaidTypes) == "table" and self.instanceRaidTypes or {}
    self.instanceRaidTypes = types
    self.instanceRaidMissing = type(self.instanceRaidMissing) == "table" and self.instanceRaidMissing or {}

    -- Discovery pass: resolve the instanceType id for every raid that does not
    -- have one cached yet.  Iterate kinds -> instance lists -> names and stop
    -- once every raid is resolved (steady-state scans skip this loop entirely).
    local needsDiscovery = false
    for key in pairs(definitions) do
        if types[key] == nil then needsDiscovery = true break end
    end
    if needsDiscovery then
        local seenNames = {}
        local function RememberSeenName(value)
            local text = tostring(value or "")
            if text == "" then return end
            for _, existing in ipairs(seenNames) do if existing == text then return end end
            if #seenNames < 16 then seenNames[#seenNames + 1] = text end
        end
        local okKinds, kinds = S.Api:CallCapability("X2BattleField:GetInstanceUiKindList", battleField, "GetInstanceUiKindList")
        if okKinds and type(kinds) == "table" then
            for _, kind in ipairs(kinds) do
                if type(kind) == "table" and kind.type ~= nil then
                    local okList, list = S.Api:CallCapability("X2BattleField:GetInstanceListByKind", battleField, "GetInstanceListByKind", kind.type)
                    if okList and type(list) == "table" then
                        for _, entry in ipairs(list) do
                            if type(entry) == "table" and entry.type ~= nil then
                                -- The list entry itself carries no name; resolve it
                                -- via GetInstanceName (cheap) and fall back to the
                                -- detail name.
                                local name = nil
                                local okName, instanceName = S.Api:CallCapability("X2BattleField:GetInstanceName", battleField, "GetInstanceName", entry.type)
                                if okName and type(instanceName) == "string" and instanceName ~= "" then
                                    name = instanceName
                                else
                                    local okDetail, detail = S.Api:CallCapability("X2BattleField:GetDetailInstanceInfo", battleField, "GetDetailInstanceInfo", entry.type)
                                    if okDetail and type(detail) == "table" and type(detail.name) == "string" then name = detail.name end
                                end
                                RememberSeenName(name)
                                local key = MatchInstanceRaidKey(name, definitions)
                                if key ~= nil and types[key] == nil then
                                    types[key] = entry.type
                                end
                            end
                        end
                    end
                end
                -- Early exit once every raid is resolved.
                local remaining = 0
                for key in pairs(definitions) do if types[key] == nil then remaining = remaining + 1 end end
                if remaining == 0 then break end
            end
        end
        -- Diagnostics: if a raid could not be resolved, surface the instance
        -- names actually seen so the matchNames table can be corrected.
        if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Record) == "function" then
            local seen = #seenNames > 0 and ("；当前实例面板名称: " .. table.concat(seenNames, " / ")) or ""
            for key in pairs(definitions) do
                if types[key] == nil then
                    S.DiagnosticsManager:Record("warning", "quest", "instance raid 未识别: " .. tostring(key)
                        .. "（客户端实例面板名称与 matchNames 不匹配，请核对 rs_quest_data.lua" .. seen .. "）")
                end
            end
        end
    end

    -- Counter pass: read the entry counters for every resolved raid and publish
    -- the canonical eventQuestProgress snapshot consumed by EventService.
    local snapshot = S.State.data.instanceRaidEntries
    if type(snapshot) ~= "table" then snapshot = {}; S.State.data.instanceRaidEntries = snapshot end
    local changed = false
    for key, definition in pairs(definitions) do
        local instanceType = types[key]
        if instanceType ~= nil then
            local okInfo, info = S.Api:CallCapability("X2BattleField:GetDetailInstanceInfo", battleField, "GetDetailInstanceInfo", instanceType)
            if okInfo and type(info) == "table" then
                self.instanceRaidMissing[key] = 0
                local enterCount = math.max(0, tonumber(info.enterCount) or 0)
                local maxEnterCount = tonumber(info.maxEnterCount) or 0
                local entered = maxEnterCount > 0 and maxEnterCount ~= 1000 and enterCount >= maxEnterCount
                local displayMax = (maxEnterCount > 0 and maxEnterCount ~= 1000) and maxEnterCount
                    or (type(definition.instanceRaid) == "table" and tonumber(definition.instanceRaid.maxEntry) or 1) or 1
                local nextEntry = {
                    instanceType = instanceType,
                    name = tostring(type(info.name) == "string" and info.name ~= "" and info.name
                        or (snapshot[key] and snapshot[key].name) or definition.title or key),
                    enterCount = enterCount,
                    maxEnterCount = maxEnterCount,
                    entered = entered,
                    available = info.available == true,
                    matchedAt = S.NowMs(),
                }
                local previous = snapshot[key]
                S.State.data.eventQuestProgress[key] = {
                    completed = entered and 1 or 0,
                    total = 1,
                    activeCount = 0,
                    readyCount = 0,
                    tailInFlightCount = 0,
                    relatedActiveCount = 0,
                    relatedReadyCount = 0,
                    dailyLatched = false,
                    text = entered and ("1/" .. tostring(displayMax)) or ("0/" .. tostring(displayMax)),
                }
                snapshot[key] = nextEntry
                if previous == nil or previous.entered ~= entered or previous.enterCount ~= enterCount then
                    changed = true
                end
            else
                -- Detail read failed (server data not pushed yet). Keep the last
                -- snapshot; drop a stale instanceType after repeated failures so
                -- a later discovery pass can re-resolve it.
                local misses = (self.instanceRaidMissing[key] or 0) + 1
                self.instanceRaidMissing[key] = misses
                if misses >= 3 then
                    types[key] = nil
                    self.instanceRaidMissing[key] = nil
                end
            end
        end
    end
    if changed then
        S.State:MarkDirty("events")
        if S.Services and S.Services.Event and type(S.Services.Event.Refresh) == "function" then
            S.Services.Event:Refresh()
        end
    end
end

function Q:Refresh()
    if S.Api == nil or type(S.Api.IsCapabilityAllowed) ~= "function"
        or S.Api:IsCapabilityAllowed("X2Quest:GetActiveQuestListCount") ~= true then
        S.State.data.daily, S.State.data.weekly = {}, {}
        S.State.data.summary.unfinished, S.State.data.summary.turnIn = 0, 0
        -- Instance-raid rows (红龙巢穴 / 卡杜姆) do not depend on X2Quest; keep
        -- their entry-counter projection alive even when quest reads are blocked.
        self:ScanInstanceRaids()
        S.State:MarkDirty("quests"); return
    end
    local active, daily, weekly = self:BuildActiveIndex(), {}, {}
    self:CaptureRepeatableDailyCompletion(active)
    self:RefreshEventQuestProgress(active)
    self:ScanInstanceRaids()
    for _, group in ipairs(self:GetDailyGroups()) do local row=self:GroupState(group,active); row.scope="daily"; daily[#daily+1]=row end
    for _, group in ipairs((S.Data.QuestGroups and S.Data.QuestGroups.weekly) or {}) do local row=self:GroupState(group,active); row.scope="weekly"; weekly[#weekly+1]=row end
    self:SortRows(daily); self:SortRows(weekly)
    S.State.data.daily, S.State.data.weekly = daily, weekly
    self:RecomputeTrackedSummary()
    local turnIn = 0
    for _, row in ipairs(daily) do
        if self:IsDailyTracked(row.key) and row.state == QS.READY_TO_TURN_IN then turnIn = turnIn + 1 end
    end
    S.State.data.summary.turnIn = turnIn
    S.State:MarkDirty("quests")
    self:RequestDerivedRefresh(active)
end

function Q:RequestDerivedRefresh(active)
    -- Derived "Today" Auction Favorites are quest-runtime data, not saved user
    -- favorites. Rebuild them from this exact active-index snapshot so accept,
    -- abandon, completion and turn-in state cannot drift from the Daily panel.
    -- These projections are independent consumers of the just-published quest
    -- snapshot.  Run them on the next scheduler frame so an event debounce
    -- does not also perform auction/resident work in the same callback.
    if S.Scheduler == nil or type(S.Scheduler.AddTask) ~= "function" then return end
    local taskName = "quest_derived_refresh"
    S.Scheduler:RemoveTask(taskName)
    S.Scheduler:AddTask(taskName, 50, function()
        S.Scheduler:RemoveTask(taskName)
        if S.Services.AuctionFavorites and type(S.Services.AuctionFavorites.RefreshTodayQuestItems) == "function" then
            S.Services.AuctionFavorites:RefreshTodayQuestItems(active)
        end
        if S.Services.Resident and type(S.Services.Resident.RefreshCompletion) == "function" then S.Services.Resident:RefreshCompletion() end
    end, true, self, "P4")
end

function Q:RequestRefresh(delayMs)
    S.Scheduler:AddTask("quest_debounce", math.max(100, tonumber(delayMs) or 200), function() S.Scheduler:RemoveTask("quest_debounce"); Q:Refresh() end, true, self, "P2")
end

function Q:Start()
    local events={"QUEST_CONTEXT_UPDATED","QUEST_CONTEXT_OBJECTIVE_EVENT","UPDATE_COMPLETED_QUEST_INFO","ADD_GIVEN_QUEST_INFO","REMOVE_GIVEN_QUEST_INFO","ACHIEVEMENT_UPDATE","COMPLETE_ACHIEVEMENT","ENTERED_WORLD",
        -- Instance-raid entry counters are server-pushed through the instance
        -- entrance events; re-scan right after the player enters a raid so the
        -- 红龙巢穴 / 卡杜姆 rows flip to "1/1" promptly.
        "UPDATE_INSTANCE_VISIT_COUNT","INSTANT_GAME_VISIT_COUNT_RESET"}
    for _,eventName in ipairs(events) do S.Events:Subscribe(eventName,self,function() Q:RequestRefresh(200) end) end
    for _,eventName in ipairs({"COMPLETE_QUEST_CONTEXT_NPC","COMPLETE_QUEST_CONTEXT_DOODAD"}) do
        S.Events:Subscribe(eventName,self,function()
            Q.pendingCompletionEvent=true
            Q:RequestRefresh(200)
        end)
    end
    S.Scheduler:AddTask("quest_safety",S.Constants.Refresh.questSafetyMs,function() Q:Refresh() end,false,self,"P3")
    self:Refresh()
end

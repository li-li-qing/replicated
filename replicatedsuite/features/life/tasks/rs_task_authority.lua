------------------------------------------------------------------------
-- Replicated Suite V3 - Task Tracker Authority
--
-- Presentation projection for curated daily/weekly quest groups. It owns no
-- gameplay truth: QuestProgressService V3 is the only quest-state reader, while
-- Task Store owns the user's tracking choices.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Features = S.Features or {}
S.Features.Tasks = S.Features.Tasks or {}
local Feature = S.Features.Tasks

local A = {
    version = 1,
    revision = 0,
    rows = { daily = {}, weekly = {} },
    rowById = {},
    expanded = { daily = {}, weekly = {} },
    updatedAtMs = -1,
}
Feature.Authority = A

local VALID_SCOPE = { daily = true, weekly = true }
local SCOPE_TEXT = { daily = "日常", weekly = "周常" }
local STATUS_PRIORITY = { ["可交付"] = 1, ["进行中"] = 2, ["未接"] = 3, ["已完成"] = 4, ["暂不可用"] = 5 }

local function IsoDateKey(value)
    local year, month, day = string.match(tostring(value or ""), "^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    year, month, day = tonumber(year), tonumber(month), tonumber(day)
    if year == nil or month == nil or day == nil then return nil end
    if year < 2000 or month < 1 or month > 12 or day < 1 or day > 31 then return nil end
    return year * 10000 + month * 100 + day
end

local function CurrentServerDateKey()
    if S.Utils ~= nil and type(S.Utils.ServerDateKey) == "function" then
        local value = IsoDateKey(S.Utils.ServerDateKey())
        if value ~= nil then return value end
    end
    if UIParent ~= nil and type(UIParent.GetServerTimeTable) == "function" then
        local ok, value = pcall(UIParent.GetServerTimeTable, UIParent)
        if ok and type(value) == "table" then
            local year, month, day = tonumber(value.year), tonumber(value.month), tonumber(value.day)
            if year ~= nil and month ~= nil and day ~= nil then return year * 10000 + month * 100 + day end
        end
    end
    return nil
end

local function DateEnabled(group, today)
    if type(group) ~= "table" or today == nil then return true end
    local fromKey, untilKey = IsoDateKey(group.activeFrom), IsoDateKey(group.activeUntil)
    if fromKey ~= nil and today < fromKey then return false end
    if untilKey ~= nil and today > untilKey then return false end
    return true
end

local function ObjectiveCount(group)
    if type(group) ~= "table" then return 0 end
    if type(group.objectives) == "table" and #group.objectives > 0 then return #group.objectives end
    return #(type(group.quests) == "table" and group.quests or {})
end

function A:GetGroups(scope)
    scope = tostring(scope or "daily")
    if VALID_SCOPE[scope] ~= true then return {} end
    local source = S.Data and S.Data.QuestGroups and S.Data.QuestGroups[scope] or {}
    if scope ~= "daily" then return source end
    local today, result = CurrentServerDateKey(), {}
    for _, group in ipairs(type(source) == "table" and source or {}) do
        if DateEnabled(group, today) then result[#result + 1] = group end
    end
    return result
end

function A:GetGroupKeys(scope)
    local result = {}
    for _, group in ipairs(self:GetGroups(scope)) do
        local key = tostring(type(group) == "table" and group.key or "")
        if key ~= "" then result[#result + 1] = key end
    end
    return result
end

local function ResolveStatus(snapshot)
    if type(snapshot) ~= "table" or snapshot.available ~= true then return "暂不可用", "muted" end
    local completed, total = tonumber(snapshot.completed) or 0, tonumber(snapshot.total) or 0
    local ready, active = tonumber(snapshot.readyCount) or 0, tonumber(snapshot.activeCount) or 0
    if ready > 0 then return "可交付", "orange" end
    if total > 0 and completed >= total then return "已完成", "green" end
    if active > 0 or completed > 0 then return "进行中", "yellow" end
    return "未接", "muted"
end

function A:ProjectParent(scope, group)
    local key = tostring(type(group) == "table" and group.key or "")
    if key == "" then return nil end
    local progress = S.Services and S.Services.QuestProgressV3 or nil
    local snapshot = type(progress) == "table" and type(progress.GetProgress) == "function" and progress:GetProgress(scope, key) or nil
    local status, tone = ResolveStatus(snapshot)
    local tracked = Feature:IsTracked(scope, key)
    local expanded = self.expanded[scope] and self.expanded[scope][key] == true
    local count = ObjectiveCount(group)
    return {
        id = scope .. ":" .. key,
        key = key,
        groupKey = key,
        scope = scope,
        cycleText = SCOPE_TEXT[scope] or scope,
        name = (count > 0 and (expanded and "▼ " or "▶ ") or "") .. tostring(group.title or key),
        rawName = tostring(group.title or key),
        progressText = type(snapshot) == "table" and tostring(snapshot.text or "--") or "--",
        status = status,
        tone = tone,
        tracked = tracked,
        trackedText = tracked and "✓" or "",
        expanded = expanded,
        parent = true,
        child = false,
        objectiveCount = count,
        completed = type(snapshot) == "table" and tonumber(snapshot.completed) or 0,
        total = type(snapshot) == "table" and tonumber(snapshot.total) or count,
        readyCount = type(snapshot) == "table" and tonumber(snapshot.readyCount) or 0,
        activeCount = type(snapshot) == "table" and tonumber(snapshot.activeCount) or 0,
        available = type(snapshot) == "table" and snapshot.available == true or false,
    }
end

function A:BuildRows(scope)
    scope = tostring(scope or "daily")
    if VALID_SCOPE[scope] ~= true then return {} end
    local result = {}
    for _, group in ipairs(self:GetGroups(scope)) do
        local parent = self:ProjectParent(scope, group)
        if parent ~= nil then
            result[#result + 1] = parent
            if parent.expanded == true then
                local progress = S.Services and S.Services.QuestProgressV3 or nil
                local detail = type(progress) == "table" and type(progress.GetGroupDetail) == "function" and progress:GetGroupDetail(scope, parent.groupKey) or nil
                for index, child in ipairs(type(detail) == "table" and type(detail.children) == "table" and detail.children or {}) do
                    result[#result + 1] = {
                        id = parent.id .. ":child:" .. tostring(index),
                        key = parent.groupKey,
                        groupKey = parent.groupKey,
                        scope = scope,
                        cycleText = "",
                        name = "    └ " .. tostring(child.name or "任务"),
                        rawName = tostring(child.name or "任务"),
                        progressText = tostring(child.category or ""),
                        status = tostring(child.status or "未知"),
                        tone = tostring(child.tone or "muted"),
                        tracked = parent.tracked,
                        trackedText = "",
                        parent = false,
                        child = true,
                        questId = child.questId,
                        related = child.related == true,
                    }
                end
            end
        end
    end
    return result
end

function A:Refresh(reason)
    self.rows.daily = self:BuildRows("daily")
    self.rows.weekly = self:BuildRows("weekly")
    self.rowById = {}
    for _, scope in ipairs({ "daily", "weekly" }) do
        for _, row in ipairs(self.rows[scope]) do self.rowById[row.id] = row end
    end
    self.revision = (tonumber(self.revision) or 0) + 1
    self.updatedAtMs = math.max(0, tonumber(S.NowMs and S.NowMs()) or 0)
    if S.Events ~= nil and type(S.Events.Publish) == "function" then
        S.Events:Publish("v3.tasks.updated", self.revision, tostring(reason or "refresh"))
    end
    return true
end

function A:GetRows(scope)
    scope = VALID_SCOPE[tostring(scope or "")] and tostring(scope) or "daily"
    return self.rows[scope] or {}, self.revision
end

function A:GetRow(id)
    return self.rowById[tostring(id or "")]
end

function A:SetExpanded(scope, key, expanded)
    scope, key = tostring(scope or "daily"), tostring(key or "")
    if VALID_SCOPE[scope] ~= true or key == "" then return false end
    self.expanded[scope] = self.expanded[scope] or {}
    if expanded == true then self.expanded[scope][key] = true else self.expanded[scope][key] = nil end
    return self:Refresh("expand")
end

function A:ToggleExpanded(scope, key)
    local bucket = self.expanded[tostring(scope or "daily")] or {}
    return self:SetExpanded(scope, key, bucket[tostring(key or "")] ~= true)
end

function A:GetSummary(scope)
    local scopes = VALID_SCOPE[tostring(scope or "")] and { tostring(scope) } or { "daily", "weekly" }
    local result = { total = 0, tracked = 0, unfinished = 0, ready = 0, completed = 0, unavailable = 0 }
    for _, currentScope in ipairs(scopes) do
        for _, group in ipairs(self:GetGroups(currentScope)) do
            local row = self:ProjectParent(currentScope, group)
            if row ~= nil then
                result.total = result.total + 1
                if row.tracked then
                    result.tracked = result.tracked + 1
                    if row.status == "已完成" then result.completed = result.completed + 1
                    elseif row.status == "可交付" then result.ready = result.ready + 1; result.unfinished = result.unfinished + 1
                    elseif row.status == "暂不可用" then result.unavailable = result.unavailable + 1; result.unfinished = result.unfinished + 1
                    else result.unfinished = result.unfinished + 1 end
                end
            end
        end
    end
    return result
end

function A:GetWidgetRows()
    local rows = {}
    for _, scope in ipairs({ "daily", "weekly" }) do
        for _, group in ipairs(self:GetGroups(scope)) do
            local row = self:ProjectParent(scope, group)
            if row ~= nil and row.tracked == true then rows[#rows + 1] = row end
        end
    end
    table.sort(rows, function(a, b)
        local ap, bp = STATUS_PRIORITY[a.status] or 99, STATUS_PRIORITY[b.status] or 99
        if ap ~= bp then return ap < bp end
        if a.scope ~= b.scope then return a.scope == "daily" end
        return tostring(a.rawName or a.name) < tostring(b.rawName or b.name)
    end)
    return rows, self.revision
end

function A:ResetTransient()
    self.expanded = { daily = {}, weekly = {} }
    self.rows = { daily = {}, weekly = {} }
    self.rowById = {}
    return true
end

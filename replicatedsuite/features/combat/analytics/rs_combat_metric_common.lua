------------------------------------------------------------------------
-- Replicated Suite V3 - Combat Analytics Metric Common
-- Bounded containers and projection helpers shared by every metric plugin.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Features = S.Features or {}
S.Features.CombatAnalytics = S.Features.CombatAnalytics or {}
local M = { version = 2 }
S.Features.CombatAnalytics.MetricCommon = M

function M:NowMs() return math.max(0, tonumber(S.NowMs and S.NowMs()) or 0) end
function M:Trim(value) return tostring(value or ""):match("^%s*(.-)%s*$") or "" end
function M:ActorKey(name, stableId)
    local text = self:Trim(name)
    -- Exact display name is the cross-fact key because stable ids are not
    -- guaranteed on every CombatFact. Keep Name@World intact to avoid collision.
    if text ~= "" then return "name:" .. text end
    local id = stableId ~= nil and tostring(stableId) or ""
    if id ~= "" then return "id:" .. id end
    return nil
end

function M:NewBoundedQueue(maxItems)
    return { rows = {}, head = 1, tail = 0, count = 0, max = math.max(1, tonumber(maxItems) or 128), evicted = 0 }
end
local function CompactQueue(queue)
    local compact = {}
    for index = math.max(1, tonumber(queue.head) or 1), math.max(0, tonumber(queue.tail) or 0) do
        local row = queue.rows[index]
        if row ~= nil then compact[#compact + 1] = row end
    end
    queue.rows, queue.head, queue.tail = compact, 1, #compact
end
function M:QueuePush(queue, value)
    if type(queue) ~= "table" then return false, nil end
    local evicted
    while (tonumber(queue.count) or 0) >= (tonumber(queue.max) or 1) do
        local head = math.max(1, tonumber(queue.head) or 1)
        evicted = queue.rows[head]
        queue.rows[head] = nil
        queue.head = head + 1
        queue.count = math.max(0, (tonumber(queue.count) or 0) - 1)
        queue.evicted = (tonumber(queue.evicted) or 0) + 1
    end
    queue.tail = (tonumber(queue.tail) or 0) + 1
    queue.rows[queue.tail] = value
    queue.count = (tonumber(queue.count) or 0) + 1
    if queue.head > 256 and queue.head > queue.tail / 2 then CompactQueue(queue) end
    return true, evicted
end
function M:QueueLast(queue)
    if type(queue) ~= "table" or (tonumber(queue.count) or 0) <= 0 then return nil end
    return queue.rows[math.max(0, tonumber(queue.tail) or 0)]
end
function M:QueueEach(queue, callback)
    if type(queue) ~= "table" or type(callback) ~= "function" then return end
    for index = math.max(1, tonumber(queue.head) or 1), math.max(0, tonumber(queue.tail) or 0) do
        local row = queue.rows[index]
        if row ~= nil then callback(row, index) end
    end
end
function M:QueuePruneBefore(queue, cutoff, onRemove)
    if type(queue) ~= "table" then return 0 end
    local removed = 0
    while (tonumber(queue.count) or 0) > 0 and queue.head <= queue.tail do
        local row = queue.rows[queue.head]
        if row ~= nil and (tonumber(row.at) or 0) >= cutoff then break end
        queue.rows[queue.head] = nil
        queue.head = queue.head + 1
        queue.count = math.max(0, (tonumber(queue.count) or 0) - 1)
        removed = removed + 1
        if row ~= nil and type(onRemove) == "function" then onRemove(row) end
    end
    if queue.count <= 0 then queue.rows, queue.head, queue.tail = {}, 1, 0
    elseif queue.head > 256 and queue.head > queue.tail / 2 then CompactQueue(queue) end
    return removed
end
function M:QueueToArray(queue, newestFirst, limit)
    local rows = {}
    self:QueueEach(queue, function(row) rows[#rows + 1] = row end)
    if newestFirst == true then
        local reversed = {}
        for i = #rows, 1, -1 do reversed[#reversed + 1] = rows[i] end
        rows = reversed
    end
    local max = math.max(0, tonumber(limit) or #rows)
    while #rows > max do rows[#rows] = nil end
    return rows
end

function M:NewActorState(maxActors)
    return { actors = {}, actorCount = 0, maxActors = math.max(1, tonumber(maxActors) or 512), actorOverflow = 0 }
end
function M:EnsureActor(state, name, stableId)
    if type(state) ~= "table" then return nil end
    local key = self:ActorKey(name, stableId)
    if key == nil then return nil end
    local actor = state.actors[key]
    if actor ~= nil then
        if (actor.name == nil or actor.name == "") and self:Trim(name) ~= "" then actor.name = self:Trim(name) end
        return actor
    end
    if (tonumber(state.actorCount) or 0) >= (tonumber(state.maxActors) or 512) then
        state.actorOverflow = (tonumber(state.actorOverflow) or 0) + 1
        return nil
    end
    actor = { key = key, name = self:Trim(name), stableId = stableId, firstAt = nil, lastAt = nil, details = {} }
    state.actors[key] = actor
    state.actorCount = (tonumber(state.actorCount) or 0) + 1
    return actor
end
function M:Touch(actor, at)
    if type(actor) ~= "table" then return end
    at = tonumber(at) or self:NowMs()
    if actor.firstAt == nil or at < actor.firstAt then actor.firstAt = at end
    if actor.lastAt == nil or at > actor.lastAt then actor.lastAt = at end
end
function M:AddCounter(actor, key, amount)
    if type(actor) ~= "table" then return 0 end
    actor[key] = (tonumber(actor[key]) or 0) + (tonumber(amount) or 0)
    return actor[key]
end
function M:AddMapValue(map, key, amount, maxKeys, owner, countKey, overflowKey)
    if type(map) ~= "table" then return false end
    key = tostring(key or "")
    if key == "" then key = "未知" end
    if map[key] == nil then
        local count = owner and (tonumber(owner[countKey]) or 0) or 0
        if owner ~= nil and count >= (tonumber(maxKeys) or 128) then
            owner[overflowKey or "detailOverflow"] = (tonumber(owner[overflowKey or "detailOverflow"]) or 0) + 1
            return false
        end
        map[key] = 0
        if owner ~= nil then owner[countKey] = count + 1 end
    end
    map[key] = (tonumber(map[key]) or 0) + (tonumber(amount) or 0)
    return true
end
function M:MapRows(map, limit, valueName)
    local rows = {}
    for key, value in pairs(type(map) == "table" and map or {}) do
        rows[#rows + 1] = { key = key, name = key, value = tonumber(value) or 0, [valueName or "count"] = tonumber(value) or 0 }
    end
    table.sort(rows, function(a, b) if a.value ~= b.value then return a.value > b.value end return tostring(a.name) < tostring(b.name) end)
    local max = math.max(0, tonumber(limit) or #rows)
    while #rows > max do rows[#rows] = nil end
    return rows
end
function M:RankActors(state, valueKey, limit, options)
    local rows = {}
    options = type(options) == "table" and options or {}
    for _, actor in pairs(type(state) == "table" and state.actors or {}) do
        local value = type(options.valueFn) == "function" and tonumber(options.valueFn(actor, valueKey)) or tonumber(actor[valueKey])
        value = value or 0
        if value ~= 0 or options.includeZero == true then
            local row = { key = actor.key, name = actor.name ~= "" and actor.name or actor.key, value = value, firstAt = actor.firstAt, lastAt = actor.lastAt }
            for _, field in ipairs(type(options.copyFields) == "table" and options.copyFields or {}) do row[field] = actor[field] end
            rows[#rows + 1] = row
        end
    end
    table.sort(rows, function(a, b) if a.value ~= b.value then return a.value > b.value end return tostring(a.name) < tostring(b.name) end)
    local max = math.max(0, tonumber(limit) or #rows)
    while #rows > max do rows[#rows] = nil end
    for i, row in ipairs(rows) do row.rank = i end
    return rows
end
function M:ClearTable(tbl) for key in pairs(type(tbl) == "table" and tbl or {}) do tbl[key] = nil end end
function M:Finite(value, fallback)
    value = tonumber(value)
    if value == nil or value ~= value or value == math.huge or value == -math.huge then return fallback end
    return value
end

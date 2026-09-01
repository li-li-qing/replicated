------------------------------------------------------------------------
-- Replicated Suite V3 - Aura Observation Domain (Phase 12B shared fact projection)
--
-- Shared read-only fact cache for Buff / Debuff / Hidden Buff lanes.
-- It owns native observation facts only.  Healer/Plates/Boss/etc. retain all
-- business interpretation.  No Tick, no background scan: consumers explicitly
-- request snapshots and a short bounded cache coalesces duplicate reads.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Services = S.Services or {}

local A = {
    Id = "v3.aura_observation",
    version = 2,
    cache = {},
    cacheCount = 0,
    cacheMax = 96,
    defaultTtlMs = 120,
    revision = 0,
    nativeReads = 0,
    tooltipFallbacks = 0,
    scanFailures = 0,
}
A.presentationBoundary = "service_only"
S.Services.AuraObservationV3 = A

local LANES = {
    buff = { count = "UnitBuffCount", data = "UnitBuff", tip = "UnitBuffTooltip", sourceMask = 1 },
    debuff = { count = "UnitDeBuffCount", data = "UnitDeBuff", tip = "UnitDeBuffTooltip", sourceMask = 2 },
    hidden = { count = "UnitHiddenBuffCount", data = "UnitHiddenBuff", tip = "UnitHiddenBuffTooltip", sourceMask = 4 },
}

local STATUS_KEYS = {
    stack = { "stack", "stackCount", "count" },
    timeLeft = { "timeLeft", "time_left", "remainTime", "remainingTime", "remain_time" },
    name = { "name", "buffName" },
    icon = { "path", "iconPath", "icon_path", "icon", "skillIcon", "skill_icon", "texture" },
}

local function NowMs() return math.max(0, tonumber(S.NowMs and S.NowMs()) or 0) end
local function Clamp(value, minimum, maximum)
    value = math.floor(tonumber(value) or minimum)
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

local function CopyShallow(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for key, item in pairs(value) do
        if type(item) ~= "table" then out[key] = item end
    end
    return out
end

local function ExtractEffectId(data, tooltip)
    local function Pick(row)
        if type(row) ~= "table" then return nil end
        return tonumber(row.effectId or row.effect_id or row.buff_id or row.buffId or row.buffID or row.id or row.buffType or row.buff_type or row.type)
    end
    return Pick(data) or Pick(tooltip)
end

local function PickNumber(primary, secondary, keys)
    local function Pick(row)
        if type(row) == "table" then
            for _, key in ipairs(keys) do
                local value = tonumber(row[key])
                if value ~= nil then return value end
            end
        end
        return nil
    end
    return Pick(primary) or Pick(secondary)
end

local function PickString(primary, secondary, keys)
    local function Pick(row)
        if type(row) == "table" then
            for _, key in ipairs(keys) do
                local value = row[key]
                if type(value) == "string" and value ~= "" then return value end
            end
        end
        return nil
    end
    return Pick(primary) or Pick(secondary)
end

local function AddSourceMask(mask, sourceMask)
    mask = math.max(0, math.floor(tonumber(mask) or 0))
    sourceMask = math.max(1, math.floor(tonumber(sourceMask) or 1))
    if math.floor(mask / sourceMask) % 2 == 0 then mask = mask + sourceMask end
    return mask
end

local function CopyLane(row)
    if type(row) ~= "table" then return { available = false, reliable = false, count = 0, scanned = 0, limit = 0, rows = {} } end
    local out = {
        available = row.available == true,
        reliable = row.reliable == true,
        complete = row.complete == true,
        count = tonumber(row.count) or 0,
        scanned = tonumber(row.scanned) or 0,
        limit = tonumber(row.limit) or 0,
        at = tonumber(row.at) or 0,
        rows = {},
    }
    for index, item in ipairs(type(row.rows) == "table" and row.rows or {}) do
        out.rows[index] = {
            index = tonumber(item.index) or index,
            effectId = item.effectId,
            data = CopyShallow(item.data),
            tooltip = CopyShallow(item.tooltip),
        }
    end
    return out
end

function A:_CacheKey(unitId)
    return tostring(unitId or "")
end

function A:_PruneOne()
    local oldestKey, oldestAt
    for key, entry in pairs(self.cache) do
        local at = tonumber(entry and entry.at) or 0
        if oldestAt == nil or at < oldestAt then oldestKey, oldestAt = key, at end
    end
    if oldestKey ~= nil then self.cache[oldestKey] = nil; self.cacheCount = math.max(0, self.cacheCount - 1) end
end

function A:_Store(key, entry)
    if self.cache[key] == nil then self.cacheCount = self.cacheCount + 1 end
    self.cache[key] = entry
    while self.cacheCount > self.cacheMax do self:_PruneOne() end
end

function A:_LaneGate(lane)
    local spec = LANES[lane]
    if spec == nil or S.Api == nil or X2Unit == nil then return nil, false, false, false end
    local prefix = "X2Unit:"
    local canCount = S.Api:IsCapabilityAllowed(prefix .. spec.count) == true
    local canData = S.Api:IsCapabilityAllowed(prefix .. spec.data) == true
    local canTip = S.Api:IsCapabilityAllowed(prefix .. spec.tip) == true
    return spec, canCount, canData, canTip
end

function A:_ScanLane(unitId, lane, limit)
    local spec, canCount, canData, canTip = self:_LaneGate(lane)
    if spec == nil or canCount ~= true then return { available = false, reliable = false, count = 0, scanned = 0, limit = limit, rows = {} } end

    self.nativeReads = self.nativeReads + 1
    local okCount, rawCount = S.Api:Call(X2Unit, spec.count, unitId)
    if okCount ~= true then
        self.scanFailures = self.scanFailures + 1
        return { available = false, reliable = false, count = 0, scanned = 0, limit = limit, rows = {} }
    end

    local count = math.max(0, math.floor(tonumber(rawCount) or 0))
    local scanned = math.min(count, limit)
    local rows, reliable = {}, canData == true
    if canData ~= true and canTip ~= true then reliable = false end

    local dataWorking, tipWorking = canData == true, canTip == true
    for index = 1, scanned do
        local data, tooltip = nil, nil
        if dataWorking then
            self.nativeReads = self.nativeReads + 1
            local okData, value = S.Api:Call(X2Unit, spec.data, unitId, index)
            if okData == true then data = value else dataWorking, reliable = false, false end
        end
        local effectId = ExtractEffectId(data, nil)
        if effectId == nil and tipWorking then
            self.nativeReads = self.nativeReads + 1
            self.tooltipFallbacks = self.tooltipFallbacks + 1
            local okTip, value = S.Api:Call(X2Unit, spec.tip, unitId, index)
            if okTip == true then tooltip = value else tipWorking, reliable = false, false end
            effectId = ExtractEffectId(data, tooltip)
        end
        rows[#rows + 1] = {
            index = index,
            effectId = effectId,
            data = CopyShallow(data),
            tooltip = CopyShallow(tooltip),
        }
    end
    local complete = scanned >= count
    if complete ~= true then reliable = false end
    return { available = true, reliable = reliable, complete = complete, count = count, scanned = scanned, limit = limit, rows = rows }
end

function A:AcquireConsumer(token, options)
    if self.Demand == nil then return false, "aura demand unavailable" end
    return self.Demand:Acquire(token, options, "aura_consumer")
end

function A:ReleaseConsumer(token)
    if self.Demand == nil then return false, "aura demand unavailable" end
    return self.Demand:Release(token, "aura_consumer")
end

function A:ClearCache()
    self.cache, self.cacheCount = {}, 0
    return true
end

function A:GetSnapshot(unitId, options)
    options = type(options) == "table" and options or {}
    if self.Demand == nil or self.Demand.count <= 0 then return nil, "aura service has no consumer" end
    local key = self:_CacheKey(unitId)
    if key == "" then return nil, "unit id required" end

    local ttlMs = Clamp(options.ttlMs or self.defaultTtlMs, 0, 2000)
    local requested = {
        buff = options.buff ~= false and Clamp(options.buffLimit or options.limit or 64, 0, 256) or 0,
        debuff = options.debuff ~= false and Clamp(options.debuffLimit or options.limit or 64, 0, 256) or 0,
        hidden = options.hidden == true and Clamp(options.hiddenLimit or options.limit or 64, 0, 256) or 0,
    }
    local now = NowMs()
    local cached = self.cache[key]
    local entry = type(cached) == "table" and cached or { unitId = key }
    local changed = false
    for lane, limit in pairs(requested) do
        if limit > 0 then
            local existing = entry[lane]
            local fresh = type(existing) == "table" and now - (tonumber(existing.at) or 0) <= ttlMs
            local covered = fresh and (existing.complete == true or (tonumber(existing.limit) or 0) >= limit)
            if covered ~= true then
                local scanned = self:_ScanLane(unitId, lane, limit)
                scanned.at = now
                entry[lane] = scanned
                changed = true
            end
        end
    end

    if changed == true or cached == nil then
        entry.at = now
        self.revision = self.revision + 1
        entry.revision = self.revision
        self:_Store(key, entry)
        cached = entry
    else
        cached = entry
    end

    return {
        unitId = key,
        revision = tonumber(cached.revision) or 0,
        at = tonumber(cached.at) or 0,
        buff = requested.buff > 0 and CopyLane(cached.buff) or nil,
        debuff = requested.debuff > 0 and CopyLane(cached.debuff) or nil,
        hidden = requested.hidden > 0 and CopyLane(cached.hidden) or nil,
    }
end

-- Build a normalized read-only status projection from an already captured
-- snapshot. This performs no Native reads and deliberately owns no business
-- meaning: consumers such as Healer / Plates / Raid Readiness decide what an
-- effect means. The projection mirrors the stable facts legacy consumers need
-- (id/source/stack/time/name/icon) so they no longer have to rescan X2Unit.
function A:GetStatusMap(snapshot, options)
    snapshot = type(snapshot) == "table" and snapshot or {}
    options = type(options) == "table" and options or {}
    local requested = {
        buff = options.buff ~= false,
        debuff = options.debuff == true,
        hidden = options.hidden == true,
    }
    local map = {}
    local meta = { available = true, complete = true, reliable = true, rows = 0, lanes = 0 }

    for _, lane in ipairs({ "buff", "debuff", "hidden" }) do
        if requested[lane] == true then
            meta.lanes = meta.lanes + 1
            local laneRow = snapshot[lane]
            if type(laneRow) ~= "table" or laneRow.available ~= true then
                meta.available, meta.complete, meta.reliable = false, false, false
            else
                if laneRow.complete ~= true then meta.complete = false end
                if laneRow.reliable ~= true then meta.reliable = false end
                local laneSpec = LANES[lane]
                for _, item in ipairs(type(laneRow.rows) == "table" and laneRow.rows or {}) do
                    meta.rows = meta.rows + 1
                    local id = tonumber(item.effectId) or ExtractEffectId(item.data, item.tooltip)
                    if id ~= nil then
                        local data, tooltip = item.data, item.tooltip
                        local stack = PickNumber(tooltip, data, STATUS_KEYS.stack) or 1
                        local timeLeft = PickNumber(tooltip, data, STATUS_KEYS.timeLeft)
                        local name = PickString(tooltip, data, STATUS_KEYS.name) or tostring(id)
                        local iconPath = PickString(tooltip, data, STATUS_KEYS.icon) or ""
                        local entry = map[id]
                        if entry == nil then
                            entry = {
                                id = id, stack = stack, timeLeft = timeLeft, timeKnown = timeLeft ~= nil,
                                sourceMask = 0, sources = {}, name = name, iconPath = iconPath,
                            }
                            map[id] = entry
                        else
                            entry.stack = math.max(tonumber(entry.stack) or 1, stack)
                            if (entry.name == nil or entry.name == "" or entry.name == tostring(entry.id)) and name ~= "" then entry.name = name end
                            if (entry.iconPath == nil or entry.iconPath == "") and iconPath ~= "" then entry.iconPath = iconPath end
                            if timeLeft ~= nil and (entry.timeKnown ~= true or timeLeft > (tonumber(entry.timeLeft) or 0)) then
                                entry.timeLeft, entry.timeKnown = timeLeft, true
                            end
                        end
                        entry.sourceMask = AddSourceMask(entry.sourceMask, laneSpec and laneSpec.sourceMask or 1)
                        entry.sources[lane] = true
                    end
                end
            end
        end
    end
    if meta.lanes == 0 then meta.available, meta.complete, meta.reliable = false, false, false end
    return map, meta
end

-- Presence evaluation is intentionally conservative. If a required ID is not
-- observed while the requested lanes are incomplete/unreliable, the result is
-- unknown (ok=nil), never a fabricated failure. This is suitable for raid
-- readiness and later Healer/Plates migrations.
function A:EvaluateRequiredEffects(snapshot, requiredIds, options)
    requiredIds = type(requiredIds) == "table" and requiredIds or {}
    local statusMap, meta = self:GetStatusMap(snapshot, options)
    local present, missing, seen = {}, {}, {}
    for _, rawId in ipairs(requiredIds) do
        local id = tonumber(rawId)
        if id ~= nil and id > 0 and seen[id] ~= true then
            seen[id] = true
            if statusMap[id] ~= nil then present[#present + 1] = id else missing[#missing + 1] = id end
        end
    end
    local configured = next(seen) ~= nil
    local ok = true
    if #missing > 0 then
        if meta.available == true and meta.complete == true and meta.reliable == true then ok = false else ok = nil end
    end
    return { configured = configured, ok = ok, present = present, missing = missing, meta = meta, statusMap = statusMap }
end

function A:GetHealth()
    return {
        ok = self.Demand ~= nil,
        consumers = self.Demand and self.Demand.count or 0,
        cache = self.cacheCount,
        revision = self.revision,
        nativeReads = self.nativeReads,
        tooltipFallbacks = self.tooltipFallbacks,
        scanFailures = self.scanFailures,
    }
end

if S.Demand ~= nil and type(S.Demand.Create) == "function" then
    local lease, err = S.Demand:Create({
        id = A.Id,
        owner = A,
        projectionOwner = A,
        projectionConsumersField = "consumers",
        projectionCountField = "consumerCount",
        normalize = function(options)
            options = type(options) == "table" and options or {}
            return { purpose = tostring(options.purpose or "generic") }
        end,
        reconcile = function(_, before, after)
            if (tonumber(after.count) or 0) == 0 and (tonumber(before.count) or 0) > 0 then A:ClearCache() end
            return true
        end,
        quiesce = function() A:ClearCache(); return true end,
    })
    if lease == nil then error(err) end
    A.Demand = lease
else
    error("Demand foundation unavailable for AuraObservationV3")
end

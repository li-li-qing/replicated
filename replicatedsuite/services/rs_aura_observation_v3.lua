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

-- Buff-id -> name/icon resolution fallback. The RU client's UnitBuff rows
-- frequently omit the name field entirely (real-machine evidence 2026-09-01:
-- the status list rendered raw effect ids in the name column), so unresolved
-- ids go through the RU-enabled X2Ability:GetBuffTooltip — the same cached
-- chain as the mature Plates module (rp_api GetBuffInfoById) and
-- rs_target_service. Bounded cache; a miss is remembered as false so an
-- unknown id costs at most a few calls per session.
local buffInfoCache, buffInfoCacheCount = {}, 0
local BUFF_INFO_CACHE_MAX = 512
local function FirstIconPath(info)
    if type(info) ~= "table" then return nil end
    local path = info.path or info.iconPath or info.icon_path or info.icon
        or info.skillIcon or info.skill_icon or info.texture
    return type(path) == "string" and path ~= "" and path or nil
end
local function ResolveBuffInfoById(id)
    local key = tostring(id)
    if key:match("^%d+$") == nil then return nil end
    local cached = buffInfoCache[key]
    if cached ~= nil then return cached ~= false and cached or nil end
    if buffInfoCacheCount >= BUFF_INFO_CACHE_MAX then
        buffInfoCache, buffInfoCacheCount = {}, 0
    end
    local api = S.Api
    local gateOpen = type(api) == "table" and type(api.CallCapability) == "function"
        and X2Ability ~= nil
        and (type(api.IsCapabilityAllowed) ~= "function"
            or api:IsCapabilityAllowed("X2Ability:GetBuffTooltip") == true)
    if gateOpen ~= true then
        buffInfoCache[key], buffInfoCacheCount = false, buffInfoCacheCount + 1
        return nil
    end
    local numericId = tonumber(key)
    -- Item level is irrelevant for ordinary combat auras on current RU; try the
    -- cheap/common values and stop on the first structurally useful tooltip.
    -- Community docs describe builds where GetBuffTooltip returns tooltip TEXT
    -- (a string) instead of a table; the first line of a buff tooltip is the
    -- buff name, so accept that shape too.
    for _, itemLevel in ipairs({ 0, 1, 55 }) do
        local ok, info = api:CallCapability("X2Ability:GetBuffTooltip", X2Ability, "GetBuffTooltip", numericId, itemLevel)
        if ok == true and type(info) == "string" and info ~= "" then
            local firstLine = string.match(info, "^([^\r\n]+)") or ""
            firstLine = string.match(firstLine, "^%s*(.-)%s*$") or ""
            if firstLine ~= "" and string.match(firstLine, "^%d+$") == nil then
                local resolved = { name = firstLine, iconPath = "" }
                buffInfoCache[key], buffInfoCacheCount = resolved, buffInfoCacheCount + 1
                return resolved
            end
        end
        if ok == true and type(info) == "table" then
            local iconPath = FirstIconPath(info)
            local name = tostring(info.name or "")
            if iconPath ~= nil or name ~= "" then
                local resolved = { name = name, iconPath = iconPath or "" }
                buffInfoCache[key], buffInfoCacheCount = resolved, buffInfoCacheCount + 1
                return resolved
            end
        end
    end
    buffInfoCache[key], buffInfoCacheCount = false, buffInfoCacheCount + 1
    return nil
end

-- Read-only cache probe for the scan path: returns the cached resolution (or
-- nil for unknown/missed ids) WITHOUT issuing native reads or caching a miss.
local function PeekBuffInfo(id)
    local cached = buffInfoCache[tostring(id)]
    if cached == nil then return nil end
    return cached ~= false and cached or nil
end

-- Conservative name extraction from trailing native returns (A:Call surfaces
-- up to three extras). A display name is a short, non-numeric string with no
-- path separators or file extensions; anything else (ids, icon paths, tooltip
-- text blobs) is rejected rather than guessed.
local function NameFromExtra(extra)
    if type(extra) ~= "table" then return nil end
    for i = 1, #extra do
        local v = extra[i]
        if type(v) == "string" and v ~= "" and #v <= 64
            and string.match(v, "^%d+$") == nil
            and string.find(v, "/", 1, true) == nil
            and string.find(v, "\\", 1, true) == nil
            and string.find(v, ".dds", 1, true) == nil
            and string.find(v, "\n", 1, true) == nil then
            return v
        end
    end
    return nil
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
            extra = CopyShallow(item.extra),
            tooltipExtra = CopyShallow(item.tooltipExtra),
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
        local dataExtra, tipExtra = nil, nil
        if dataWorking then
            self.nativeReads = self.nativeReads + 1
            -- A:Call surfaces trailing native returns at positions 4-6; some RU
            -- builds move the display name OUT of the row table into a second
            -- return, so capture them instead of dropping them.
            local okData, value, _, b2, c2, d2 = S.Api:Call(X2Unit, spec.data, unitId, index)
            if okData == true then
                data = value
                if b2 ~= nil or c2 ~= nil or d2 ~= nil then dataExtra = { b2, c2, d2 } end
            else
                dataWorking, reliable = false, false
            end
        end
        local effectId = ExtractEffectId(data, nil)
        -- RU unit rows frequently omit the name field. When the id is missing
        -- OR the row carries no usable name and the ability-tooltip cache
        -- cannot resolve that id yet, fetch the tooltip row — the plates-proven
        -- co-authority (rp_api reads tip.name / extra.name alike). Gating on
        -- the cache keeps steady-state scans free of extra tooltip reads: only
        -- first-seen ids pay one tooltip read, then the ability cache answers.
        local rowName = PickString(data, nil, STATUS_KEYS.name) or NameFromExtra(dataExtra)
        if tipWorking and (effectId == nil or (rowName == nil and PeekBuffInfo(effectId) == nil)) then
            self.nativeReads = self.nativeReads + 1
            self.tooltipFallbacks = self.tooltipFallbacks + 1
            local okTip, value, _, tb, tc, td = S.Api:Call(X2Unit, spec.tip, unitId, index)
            if okTip == true then
                tooltip = value
                if tb ~= nil or tc ~= nil or td ~= nil then tipExtra = { tb, tc, td } end
            else
                tipWorking, reliable = false, false
            end
            if effectId == nil then effectId = ExtractEffectId(data, tooltip) end
        end
        rows[#rows + 1] = {
            index = index,
            effectId = effectId,
            data = CopyShallow(data),
            tooltip = CopyShallow(tooltip),
            extra = dataExtra,
            tooltipExtra = tipExtra,
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
                        local name = PickString(tooltip, data, STATUS_KEYS.name) or ""
                        local iconPath = PickString(tooltip, data, STATUS_KEYS.icon) or ""
                        -- Unit rows often carry neither name nor (rarely) icon on
                        -- current RU; a placeholder name equal to the raw id (or a
                        -- missing icon) triggers the cached ability-tooltip lookup.
                        -- Trailing native returns are checked first (zero cost).
                        if name == "" or name == tostring(id) then
                            local extraName = NameFromExtra(item.extra) or NameFromExtra(item.tooltipExtra)
                            if extraName ~= nil then name = extraName end
                        end
                        if name == "" or name == tostring(id) or iconPath == "" then
                            local resolved = ResolveBuffInfoById(id)
                            if resolved ~= nil then
                                if name == "" or name == tostring(id) then name = resolved.name end
                                if iconPath == "" then iconPath = resolved.iconPath end
                            end
                        end
                        if name == "" then name = tostring(id) end
                        -- Cache positive unit-row/tooltip resolutions so
                        -- _ScanLane's PeekBuffInfo gate stops re-fetching the
                        -- tooltip for an id whose name is already known.
                        if name ~= tostring(id) and buffInfoCache[tostring(id)] == nil
                            and (PickString(data, nil, STATUS_KEYS.name) == nil) then
                            buffInfoCache[tostring(id)] = { name = name, iconPath = iconPath }
                            buffInfoCacheCount = buffInfoCacheCount + 1
                            if buffInfoCacheCount >= BUFF_INFO_CACHE_MAX then
                                buffInfoCache, buffInfoCacheCount = {}, 0
                            end
                        end
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

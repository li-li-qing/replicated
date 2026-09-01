------------------------------------------------------------------------
-- Replicated Suite V3 - Buff Display Pure Projection
-- No Native/API access. Converts AuraObservationV3 StatusMap facts and
-- Feature runtime-lane data into bounded detached rows for Page/Widget
-- consumers.
--
-- Classification contract (schema 4):
--   * user-visible category is only "buff" | "debuff"
--   * hidden / special_rule are detection sources resolved by the shared
--     StatusClassificationV3 service, never user-facing categories
--   * tracked lookups use a prebuilt O(1) index when provided
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Features = S.Features or {}
S.Features.BuffDisplay = S.Features.BuffDisplay or {}
local F = S.Features.BuffDisplay

local function Classification()
    return S.Services and S.Services.StatusClassificationV3 or nil
end

-- O(1) tracked index: { buff = {[id]=true}, debuff = {[id]=true} }.
-- Falls back to building from settings.tracked when callers pass nothing.
local function BuildTrackedIndex(settings)
    local index = { buff = {}, debuff = {} }
    settings = type(settings) == "table" and settings or {}
    local tracked = type(settings.tracked) == "table" and settings.tracked or {}
    for _, id in ipairs(type(tracked.buff) == "table" and tracked.buff or {}) do
        id = math.floor(tonumber(id) or 0)
        if id > 0 then index.buff[id] = true end
    end
    for _, id in ipairs(type(tracked.debuff) == "table" and tracked.debuff or {}) do
        id = math.floor(tonumber(id) or 0)
        if id > 0 then index.debuff[id] = true end
    end
    return index
end

local function SortRows(a, b)
    local at, bt = tonumber(a.timeLeft), tonumber(b.timeLeft)
    if at ~= nil and bt ~= nil and at ~= bt then return at < bt end
    if at ~= nil and bt == nil then return true end
    if at == nil and bt ~= nil then return false end
    return (tonumber(a.id) or 0) < (tonumber(b.id) or 0)
end

-- Convert a StatusMap (AuraObservationV3 facts) into detached display rows.
-- signature: (statusMap, meta, settings, scope, limit, trackedIndex)
function F.ProjectStatusMap(statusMap, meta, settings, scope, limit, trackedIndex)
    statusMap, settings = type(statusMap) == "table" and statusMap or {}, type(settings) == "table" and settings or {}
    trackedIndex = type(trackedIndex) == "table" and trackedIndex or BuildTrackedIndex(settings)
    local classification = Classification()
    local rows, seen = {}, {}
    for id, entry in pairs(statusMap) do
        local kind = classification ~= nil and classification:ClassifyEntry(entry, settings.classification)
            or { category = entry.sources and entry.sources.debuff == true and "debuff" or "buff",
                 detectionSource = entry.sources and entry.sources.hidden == true and "hidden" or "normal" }
        local category = kind.category or "buff"
        -- Hidden-sourced statuses are an independent fact source: they must never
        -- be suppressed by the buff/debuff category toggles (the page's 只看隐藏
        -- filter owns them), otherwise a hidden effect the player wants to inspect
        -- silently vanishes the moment one category is toggled off.
        local hiddenSource = kind.detectionSource == "hidden"
        local allowed = hiddenSource == true
            or (category == "buff" and settings.showBuffs ~= false)
            or (category == "debuff" and settings.showDebuffs ~= false)
        if allowed == true and seen[id] ~= true then
            seen[id] = true
            local timeLeft = tonumber(entry.timeLeft)
            local idNum = math.floor(tonumber(id) or 0)
            local tracked = trackedIndex[category] ~= nil and trackedIndex[category][idNum] == true
            rows[#rows + 1] = {
                key = tostring(scope or "unit") .. ":" .. tostring(id), id = idNum,
                name = tostring(entry.name or id), iconPath = tostring(entry.iconPath or ""),
                category = category, detectionSource = kind.detectionSource or "normal",
                effectType = category, effectTypeText = category == "debuff" and "Debuff" or "Buff",
                stack = math.max(1, math.floor(tonumber(entry.stack) or 1)), timeLeft = timeLeft,
                timeText = timeLeft ~= nil and (tostring(math.max(0, math.floor(timeLeft / 1000 + 0.5))) .. "s") or "--",
                sourceMask = tonumber(entry.sourceMask) or 0, timeKnown = timeLeft ~= nil,
                tracked = tracked == true,
                trackedText = tracked == true and "已追踪" or "",
            }
        end
    end
    table.sort(rows, SortRows)
    limit = math.max(1, math.floor(tonumber(limit) or #rows))
    while #rows > limit do rows[#rows] = nil end
    return rows, {
        available = type(meta) == "table" and meta.available == true,
        complete = type(meta) == "table" and meta.complete == true,
        reliable = type(meta) == "table" and meta.reliable == true,
        total = #rows, revision = type(meta) == "table" and tonumber(meta.revision) or 0,
    }
end

------------------------------------------------------------------------
-- Head-plate projection. `laneData` is produced by the Feature runtime lanes:
--   { buffRows, debuffRows, distance, class, gearScore,
--     mainHand={icon,gradeIconPath,name}, offHand, ranged, wings,
--     cast={casting, spellName, currMs, totalMs} }
-- Returns only enabled components; tracked rows are bounded per component.
--
-- show-all semantics: headShowAll is an explicit opt-in. It can show ordinary
-- untracked Buff/Debuff rows, but a Hidden-sourced status NEVER bypasses the
-- explicit tracked whitelist. This keeps "observed Hidden" separate from
-- "displayed Hidden" even when the user enables show-all mode.
------------------------------------------------------------------------
local function BoundedTracked(rows, settings, category, trackedIndex)
    rows = type(rows) == "table" and rows or {}
    trackedIndex = type(trackedIndex) == "table" and trackedIndex or BuildTrackedIndex(settings)
    local maxIcons = math.max(1, math.min(12, math.floor(tonumber(settings.headMaxIcons) or 8)))
    local out = {}
    local showAll = settings.headShowAll == true
    for _, row in ipairs(rows) do
        local idNum = math.floor(tonumber(row.id) or 0)
        local isTracked = trackedIndex[category] ~= nil and trackedIndex[category][idNum] == true
        local hiddenSource = row.detectionSource == "hidden"
        if isTracked == true or (showAll == true and hiddenSource ~= true) then
            local copy = {}
            for key, value in pairs(row) do copy[key] = value end
            out[#out + 1] = copy
            if #out >= maxIcons then break end
        end
    end
    return out
end

-- Components are copied so the projection never exposes the live store table;
-- presentation reads a detached snapshot (boundary rule: consumers never own or
-- mutate Authority-owned state through a projection).
local function CopyComponents(components)
    local out = {}
    for key, component in pairs(type(components) == "table" and components or {}) do
        if type(component) == "table" then
            local copy = {}
            for field, value in pairs(component) do copy[field] = value end
            out[key] = copy
        else
            out[key] = component
        end
    end
    return out
end

function F.ProjectPlates(laneData, settings)
    laneData, settings = type(laneData) == "table" and laneData or {}, type(settings) == "table" and settings or {}
    local components = CopyComponents(settings.components)
    local trackedIndex = BuildTrackedIndex(settings)
    local out = { components = components, buffs = {}, debuffs = {} }
    out.buffs = BoundedTracked(laneData.buffRows, settings, "buff", trackedIndex)
    out.debuffs = BoundedTracked(laneData.debuffRows, settings, "debuff", trackedIndex)

    local distance = tonumber(laneData.distance)
    if distance ~= nil then
        if distance < 1000 then
            out.distance = { value = string.format("%.1f", distance) .. "m" }
        else
            out.distance = { value = string.format("%.2f", distance / 1000) .. "km" }
        end
    end
    if laneData.class ~= nil then
        local class = type(laneData.class) == "table" and laneData.class or { name = laneData.class }
        out.class = {
            value = tostring(class.name or ""),
            icon = type(class.icon) == "string" and class.icon or "",
        }
    end
    if laneData.gearScore ~= nil then out.gearScore = { value = tostring(math.floor(tonumber(laneData.gearScore) or 0)) } end
    for _, key in ipairs({ "mainHand", "offHand", "ranged", "wings" }) do
        local item = type(laneData[key]) == "table" and laneData[key] or nil
        if item ~= nil and (item.icon ~= nil or item.name ~= nil) then
            out[key] = {
                icon = tostring(item.icon or ""),
                gradeIconPath = tostring(item.gradeIconPath or ""),
                name = tostring(item.name or ""),
            }
        end
    end
    if type(laneData.cast) == "table" and laneData.cast.casting == true then
        out.cast = {
            spellName = tostring(laneData.cast.spellName or ""),
            currMs = math.max(0, math.floor(tonumber(laneData.cast.currMs) or 0)),
            totalMs = math.max(1, math.floor(tonumber(laneData.cast.totalMs) or 1)),
        }
    end
    return out
end

F.ProjectPlatesContractVersion = 3

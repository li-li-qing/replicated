------------------------------------------------------------------------
-- Replicated Suite V3 - Buff Display Feature (Runtime Lanes)
--
-- AuraObservationV3 stays the single Aura Authority. This Feature owns:
--   * scope policy (player/target) and bounded projection for the page table
--   * six independent runtime lanes, each gated by the components it feeds:
--       aura      -> Buff/Debuff facts (page table + head buffs/debuffs)
--       position  -> unit screen projection (all head components)
--       distance  -> UnitDistance (distance component)
--       metadata  -> GetTargetAbilityTemplates class (class component)
--       equipment -> UnitGearScore + equipped slots (gearScore/weapons/wings)
--       cast      -> UnitCastingInfo (castBar component)
--   * O(1) tracked index rebuilt on demand
--   * tracked-id import / full export-import with schema migration awareness
--
-- Closing a component stops its lane tasks and clears its cached facts; hiding
-- the window is NOT the same as disabling a component. Demand leases are still
-- reconciled through the shared Feature Runtime.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local Runtime = S.FeatureRuntime
S.Features = S.Features or {}
S.Features.BuffDisplay = S.Features.BuffDisplay or {}
local F = S.Features.BuffDisplay
if type(Runtime) ~= "table" then return end

F.Id = "combat_buff_display"
F.enabled = F.enabled == true
F.consumers, F.consumerCount = {}, 0
F.auraHeld = false
F.taskName = "v3_buff_display_refresh"          -- aura lane task (contract kept)
F.eventTaskName = "v3_buff_display_event_refresh"
F.eventSubscribed = false
F.eventEdges = tonumber(F.eventEdges) or 0
F.revision = tonumber(F.revision) or 0
F.settingsRevision = tonumber(F.settingsRevision) or 0
F.projections = F.projections or { player = {}, target = {} }
F.coverage = F.coverage or { player = {}, target = {} }
F.laneData = F.laneData or { player = {}, target = {} }
F.trackedIndex = F.trackedIndex or { buff = {}, debuff = {} }
F.lanes = F.lanes or {
    -- The aura lane intentionally keeps the historical contract task name so
    -- FoundationGate / GetHealth() keep observing the same scheduled task the
    -- Feature has always advertised.
    aura      = { active = false, revision = 0, task = "v3_buff_display_refresh",     priority = "P3", cost = 2 },
    position  = { active = false, revision = 0, task = "v3_buff_display_lane_position",  priority = "P2", cost = 1 },
    distance  = { active = false, revision = 0, task = "v3_buff_display_lane_distance",  priority = "P2", cost = 1 },
    metadata  = { active = false, revision = 0, task = "v3_buff_display_lane_metadata",  priority = "P3", cost = 1 },
    equipment = { active = false, revision = 0, task = "v3_buff_display_lane_equipment", priority = "P3", cost = 2 },
    cast      = { active = false, revision = 0, task = "v3_buff_display_lane_cast",      priority = "P2", cost = 1 },
}
-- A file-scoped reload must not leave the aura lane pointing at a stale task
-- name; the contract name is the single source of truth.
F.lanes.aura.task = F.taskName

local function Aura() return S.Services and S.Services.AuraObservationV3 or nil end
local function Settings() return F.State and F.State.settings or {} end
local function Classification() return S.Services and S.Services.StatusClassificationV3 or nil end
local function Projection() return S.Services and S.Services.ScreenProjectionV3 or nil end
local function Api() return S.Api or nil end
local function Publish(event, arg)
    if S.Events ~= nil and type(S.Events.Publish) == "function" then S.Events:Publish(event, arg) end
end

-- Client globals are resolved through _G on purpose. The bundled RU API surface
-- is not guaranteed to expose these names at load time, and capturing a nil
-- X2*/constant at file scope would permanently disable the call path. Capability
-- hosts are resolved per call by S.Api:ResolveCapabilityHost().
local function Global(name)
    local value = rawget(_G, name)
    if value == nil then return nil end
    return value
end
-- Detached settings snapshot cache. Presentation reads settings through
-- GetSettingsProjection() dozens of times per refresh; without a store-revision
-- gate every read would deep-copy the whole settings table.
local function CopySettings()
    if S.Utils ~= nil and type(S.Utils.DeepCopy) == "function" then return S.Utils.DeepCopy(F.State.settings) end
    local out = {}
    for key, value in pairs(F.State.settings) do out[key] = value end
    return out
end
local settingsCache, settingsCacheRevision = nil, -1
local function SettingsRevision() return tonumber(F.settingsRevision) or 0 end
function F:InvalidateSettingsCache()
    self.settingsRevision = SettingsRevision() + 1
    settingsCache, settingsCacheRevision = nil, -1
    return true
end

local COMPONENT_KEYS = { "buffs", "debuffs", "distance", "class", "gearScore", "mainHand", "offHand", "ranged", "wings", "castBar" }

local function SplitLines(text)
    local lines = {}
    text = tostring(text or "")
    local start = 1
    while true do
        local _, stop = string.find(text, "\r?\n", start)
        if stop == nil then
            lines[#lines + 1] = string.sub(text, start)
            break
        end
        lines[#lines + 1] = string.sub(text, start, stop - 1)
        start = stop + 1
    end
    return lines
end

local function ComponentEnabled(key)
    local component = Settings().components and Settings().components[key] or nil
    return component ~= nil and component.enabled ~= false
end

local function AnyHeadComponent()
    for _, key in ipairs(COMPONENT_KEYS) do if ComponentEnabled(key) then return true end end
    return false
end

local function HeadScopeActive()
    local settings = Settings()
    -- headEnabled is the master switch the head renderer already honors
    -- (VisualTick/Start/Reconcile); the lane gates must match it so turning the
    -- head display off also stops the position/distance/metadata/equipment/cast
    -- lanes instead of leaving them polling for a hidden renderer.
    return settings.headEnabled ~= false and AnyHeadComponent()
        and (settings.headPlayer ~= false or settings.headTarget ~= false)
end

local function LaneInterval(laneKey)
    local settings = Settings()
    if laneKey == "aura" then return settings.refreshMs or 400 end
    if laneKey == "position" or laneKey == "distance" or laneKey == "cast" then return settings.headRefreshMs or 100 end
    if laneKey == "metadata" then return 1000 end
    if laneKey == "equipment" then return 2000 end
    return 400
end

-- Schedule a lane task. Intervals below the background floor (50 ms) go to the
-- high-frequency lane, which allows down to 1 ms and is never clamped upward.
-- Reconcile is deliberately idempotent: an unchanged active lane keeps its
-- existing Scheduler task instead of remove/add churn and runImmediately spikes.
local function SetLaneActive(laneKey, needed, callback, runImmediately)
    local lane = F.lanes[laneKey]
    if lane == nil then return false end
    if needed ~= true then
        if lane.active == true then
            if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(lane.task) end
            lane.active = false
            lane.interval = nil
        end
        return true
    end
    if S.Scheduler == nil then return false end
    local interval = math.max(1, math.floor(tonumber(LaneInterval(laneKey)) or 400))
    local taskExists = S.Scheduler.tasks ~= nil and S.Scheduler.tasks[lane.task] ~= nil
    if lane.active == true and lane.interval == interval and taskExists then return true end
    S.Scheduler:RemoveTask(lane.task)
    local ok
    if interval < 50 then
        if type(S.Scheduler.AddHighFrequencyTask) ~= "function" then lane.active = false; lane.interval = nil; return false end
        ok = S.Scheduler:AddHighFrequencyTask(lane.task, interval, callback, runImmediately, F, lane.priority, lane.cost)
    else
        if type(S.Scheduler.AddTask) ~= "function" then lane.active = false; lane.interval = nil; return false end
        ok = S.Scheduler:AddTask(lane.task, interval, callback, runImmediately, F, lane.priority, lane.cost)
    end
    if ok == true and type(S.Scheduler.SetTaskModule) == "function" then S.Scheduler:SetTaskModule(lane.task, F.Id) end
    lane.active = ok == true
    lane.interval = ok == true and interval or nil
    return ok
end

local function BumpLane(laneKey)
    local lane = F.lanes[laneKey]
    if lane ~= nil then lane.revision = (tonumber(lane.revision) or 0) + 1 end
end

------------------------------------------------------------------------
-- Lane tick handlers
------------------------------------------------------------------------

function F:RefreshScope(scope)
    scope = tostring(scope or "")
    if scope ~= "player" and scope ~= "target" then return false, "invalid buff display scope" end
    local aura = Aura()
    if type(aura) ~= "table" or type(aura.GetSnapshot) ~= "function" or type(aura.GetStatusMap) ~= "function" then
        self.projections[scope], self.coverage[scope] = {}, { available = false, complete = false, reliable = false, total = 0, error = "AuraObservationV3 unavailable" }
        return false, "AuraObservationV3 unavailable"
    end
    local settings = Settings()
    local snapshot, snapshotErr = aura:GetSnapshot(scope, {
        buff = true, debuff = true, hidden = true, limit = 64, ttlMs = math.max(1, tonumber(settings.refreshMs) or 400),
    })
    if type(snapshot) ~= "table" then
        self.projections[scope], self.coverage[scope] = {}, { available = false, complete = false, reliable = false, total = 0, error = snapshotErr }
        return false, snapshotErr or "aura snapshot unavailable"
    end
    local statusMap, meta = aura:GetStatusMap(snapshot, { buff = true, debuff = true, hidden = true })
    local limit = scope == "player" and settings.playerRows or settings.targetRows
    self.trackedIndex = self:BuildTrackedIndex(settings)
    local rows, coverage = self.ProjectStatusMap(statusMap, {
        available = meta and meta.available, complete = meta and meta.complete, reliable = meta and meta.reliable,
        revision = snapshot.revision,
    }, settings, scope, limit, self.trackedIndex)
    coverage.scannedAt, coverage.buffCount = tonumber(snapshot.at) or 0, snapshot.buff and tonumber(snapshot.buff.count) or 0
    coverage.debuffCount, coverage.hiddenCount = snapshot.debuff and tonumber(snapshot.debuff.count) or 0, snapshot.hidden and tonumber(snapshot.hidden.count) or 0
    self.projections[scope], self.coverage[scope] = rows, coverage
    -- cached category rows for the head plates renderer
    local lane = self.laneData[scope] or {}
    lane.buffRows, lane.debuffRows = {}, {}
    for _, row in ipairs(rows) do
        if row.category == "debuff" then lane.debuffRows[#lane.debuffRows + 1] = row else lane.buffRows[#lane.buffRows + 1] = row end
    end
    self.laneData[scope] = lane
    return true
end

function F:BuildTrackedIndex(settings)
    settings = type(settings) == "table" and settings or Settings()
    local index = { buff = {}, debuff = {} }
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

-- Tracking is a user-setting mutation, not a Native Aura mutation. Re-stamp the
-- already bounded projection rows immediately so the table's 追踪 column and the
-- head whitelist react in the same click without forcing another Aura scan.
function F:SyncTrackedProjectionFlags()
    local index = self.trackedIndex or self:BuildTrackedIndex(Settings())
    for _, scope in ipairs({ "player", "target" }) do
        for _, row in ipairs(self.projections[scope] or {}) do
            local category = row.category == "debuff" and "debuff" or "buff"
            local id = math.floor(tonumber(row.id) or 0)
            local tracked = id > 0 and type(index[category]) == "table" and index[category][id] == true
            row.tracked = tracked == true
            row.trackedText = tracked == true and "追踪" or ""
        end
    end
    self.revision = (tonumber(self.revision) or 0) + 1
    Publish("v3.buff_display.updated", "tracked_projection")
    Publish("v3.buff_display.plates.updated", "tracked_projection")
    return true
end

function F:Refresh(reason)
    if self.auraHeld ~= true then return false, "buff display aura lease not held" end
    self:RefreshScope("player")
    self:RefreshScope("target")
    BumpLane("aura")
    self.revision = self.revision + 1
    Publish("v3.buff_display.updated", tostring(reason or "refresh"))
    Publish("v3.buff_display.plates.updated", tostring(reason or "refresh"))
    return true
end

local function ScopeHeadEnabled(scope)
    local settings = Settings()
    if scope == "player" then return settings.headPlayer ~= false end
    if scope == "target" then return settings.headTarget ~= false end
    return false
end

local function ProjectScope(scope)
    local projection = Projection()
    if type(projection) ~= "table" or type(projection.ProjectUnitFlexible) ~= "function" then
        local lane = F.laneData[scope] or {}
        lane.x, lane.y, lane.depth, lane.source = nil, nil, nil, nil
        lane.projectErr = "projection_service_unavailable"
        F.laneData[scope] = lane
        return false
    end
    local x, y, depth, err, source = projection:ProjectUnitFlexible(scope)
    local lane = F.laneData[scope] or {}
    local changed = lane.x ~= x or lane.y ~= y or lane.depth ~= depth
    if x ~= nil and y ~= nil and depth ~= nil then
        lane.x, lane.y, lane.depth, lane.source = x, y, depth, source
        lane.projectErr = nil
    else
        lane.x, lane.y, lane.depth, lane.source = nil, nil, nil, nil
        lane.projectErr = err or "projection_failed"
    end
    F.laneData[scope] = lane
    return changed
end

function F:PositionTick()
    if (tonumber(self.consumerCount) or 0) <= 0 then return true end
    local changed = false
    for _, scope in ipairs({ "player", "target" }) do
        if ScopeHeadEnabled(scope) then changed = ProjectScope(scope) or changed end
    end
    BumpLane("position")
    if changed == true then Publish("v3.buff_display.plates.updated", "position") end
    return true
end

local function NormalizeDistance(value)
    if type(value) == "table" then value = value.distance end
    local n = tonumber(value)
    return n ~= nil and n >= 0 and n or nil
end

function F:DistanceTick()
    if (tonumber(self.consumerCount) or 0) <= 0 then return true end
    local api = Api()
    local changed = false
    -- Distance is meaningful for the target; player self-distance is 0 by definition.
    if ScopeHeadEnabled("target") then
        local lane = self.laneData.target or {}
        local value = nil
        if api ~= nil and type(api.CallCapability) == "function" and X2Unit ~= nil then
            local ok, raw = api:CallCapability("X2Unit:UnitDistance", X2Unit, "UnitDistance", "target")
            value = ok and NormalizeDistance(raw) or nil
        elseif type(Global("UnitDistance")) == "function" then
            local unitDistance = Global("UnitDistance")
            local ok, raw = pcall(unitDistance, "target")
            value = ok and NormalizeDistance(raw) or nil
        end
        if lane.distance ~= value then lane.distance, changed = value, true end
        self.laneData.target = lane
    end
    BumpLane("distance")
    if changed == true then Publish("v3.buff_display.plates.updated", "distance") end
    return true
end

local function ReadClass(scope)
    local api = Api()
    if api == nil or type(api.CallCapability) ~= "function" then return nil end
    local ok, templates = api:CallCapability("X2Unit:GetTargetAbilityTemplates", X2Unit, "GetTargetAbilityTemplates", scope)
    if ok ~= true or type(templates) ~= "table" or templates[1] == nil or templates[2] == nil or templates[3] == nil then return nil end
    local indices = { tonumber(templates[1].index), tonumber(templates[2].index), tonumber(templates[3].index) }
    if indices[1] == nil or indices[2] == nil or indices[3] == nil then return nil end
    table.sort(indices)
    local key = string.format("name_%d_%d_%d", indices[1], indices[2], indices[3])
    if key == "name_30_30_30" then return nil end
    local x2Locale, combinedText = Global("X2Locale"), Global("COMBINED_ABILITY_NAME_TEXT")
    if x2Locale == nil or type(x2Locale.LocalizeUiText) ~= "function" or combinedText == nil then return nil end
    local localizedOk, localized = api:CallCapability("X2Locale:LocalizeUiText", x2Locale, "LocalizeUiText", combinedText, key, "")
    if localizedOk ~= true or localized == nil or tostring(localized) == "" then return nil end
    return tostring(localized)
end

function F:MetadataTick()
    if (tonumber(self.consumerCount) or 0) <= 0 then return true end
    local changed = false
    for _, scope in ipairs({ "player", "target" }) do
        if ScopeHeadEnabled(scope) and ComponentEnabled("class") then
            local lane = self.laneData[scope] or {}
            local value = ReadClass(scope)
            if lane.class ~= value then lane.class, changed = value, true end
            self.laneData[scope] = lane
        end
    end
    BumpLane("metadata")
    if changed == true then Publish("v3.buff_display.plates.updated", "metadata") end
    return true
end

-- Equip-slot constants are not guaranteed client globals at load time; resolve
-- them through the safe global reader so a missing constant degrades to the
-- documented slot fallback instead of faulting the lane.
local EQUIPMENT_SLOTS = {
    mainHand = function() local v = Global("ES_MAINHAND"); return type(v) == "number" and v or 16 end,
    offHand = function() local v = Global("ES_OFFHAND"); return type(v) == "number" and v or 17 end,
    ranged = function() local v = Global("ES_RANGED"); return type(v) == "number" and v or 18 end,
    wings = function() local v = Global("ES_BACKPACK"); return type(v) == "number" and v or nil end,
}

-- slotId: numeric equip slot; scope: "player" (own gear) or "target" (target gear).
-- The API's second argument is targetEquippedItem: true only for target reads,
-- matching the rest of the codebase (rg_api/rs_gear_service_v3 pass true for
-- target context, rp_api/rs_character_service pass false for own gear).
local function ReadEquippedIcon(slotId, scope)
    if slotId == nil then return nil end
    local api = Api()
    local equipment = Global("X2Equipment")
    if api == nil or type(api.CallCapability) ~= "function" or equipment == nil then return nil end
    local ok, item = api:CallCapability("X2Equipment:GetEquippedItemTooltipInfo", equipment, "GetEquippedItemTooltipInfo", slotId, scope == "target")
    if ok ~= true or type(item) ~= "table" then return nil end
    local icon = tostring(item.icon or item.iconPath or item.path or "")
    local rawGradeIcon = item.gradeIcon or item.grade_icon
    local gradeIconPath = type(rawGradeIcon) == "string" and rawGradeIcon or ""
    local name = tostring(item.name or item.itemName or "")
    if icon == "" and name == "" then return nil end
    return { icon = icon, gradeIconPath = gradeIconPath, name = name }
end

local function SameEquipmentItem(left, right)
    if left == nil or right == nil then return left == right end
    if type(left) ~= "table" or type(right) ~= "table" then return false end
    return tostring(left.icon or "") == tostring(right.icon or "")
        and tostring(left.gradeIconPath or "") == tostring(right.gradeIconPath or "")
        and tostring(left.name or "") == tostring(right.name or "")
end

function F:EquipmentTick()
    if (tonumber(self.consumerCount) or 0) <= 0 then return true end
    local changed = false
    local api = Api()
    for _, scope in ipairs({ "player", "target" }) do
        if ScopeHeadEnabled(scope) then
            local lane = self.laneData[scope] or {}
            -- gear score
            if ComponentEnabled("gearScore") then
                local score = nil
                if api ~= nil and type(api.CallCapability) == "function" and X2Unit ~= nil then
                    local ok, raw = api:CallCapability("X2Unit:UnitGearScore", X2Unit, "UnitGearScore", scope, true)
                    local n = ok and tonumber(raw) or nil
                    if n ~= nil and n > 0 then score = n end
                end
                if lane.gearScore ~= score then lane.gearScore, changed = score, true end
            end
            -- weapon / glider icons. Grade overlay is part of the same tooltip
            -- fact and therefore adds no Native read; compare it as well so a
            -- quality change cannot be hidden behind an unchanged base icon.
            for _, key in ipairs({ "mainHand", "offHand", "ranged", "wings" }) do
                if ComponentEnabled(key) then
                    local slotId = EQUIPMENT_SLOTS[key]()
                    local item = ReadEquippedIcon(slotId, scope)
                    if not SameEquipmentItem(lane[key], item) then lane[key], changed = item, true end
                end
            end
            self.laneData[scope] = lane
        end
    end
    BumpLane("equipment")
    if changed == true then Publish("v3.buff_display.plates.updated", "equipment") end
    return true
end

function F:CastTick()
    if (tonumber(self.consumerCount) or 0) <= 0 then return true end
    local api = Api()
    local changed = false
    for _, scope in ipairs({ "player", "target" }) do
        if ScopeHeadEnabled(scope) and ComponentEnabled("castBar") then
            local lane = self.laneData[scope] or {}
            local cast = nil
            if api ~= nil and type(api.CallCapability) == "function" and X2Unit ~= nil then
                local ok, info = api:CallCapability("X2Unit:UnitCastingInfo", X2Unit, "UnitCastingInfo", scope)
                if ok == true and type(info) == "table" and info.showTargetCastingTime ~= false
                    and info.spellName ~= nil and tostring(info.spellName) ~= "" then
                    cast = {
                        casting = true,
                        spellName = tostring(info.spellName),
                        currMs = math.max(0, math.floor(tonumber(info.currCastingTime) or 0)),
                        totalMs = math.max(1, math.floor(tonumber(info.castingTime) or 1)),
                    }
                end
            end
            local old = lane.cast
            local same = type(old) == "table" and type(cast) == "table"
                and old.spellName == cast.spellName and old.totalMs == cast.totalMs
                and math.abs((old.currMs or 0) - (cast.currMs or 0)) < 50
            if same ~= true then lane.cast, changed = cast, true end
            self.laneData[scope] = lane
        end
    end
    BumpLane("cast")
    if changed == true then Publish("v3.buff_display.plates.updated", "cast") end
    return true
end

------------------------------------------------------------------------
-- Lane reconciliation (component gating + demand)
------------------------------------------------------------------------

local function LaneNeeds(laneKey, settings)
    local positionActive = HeadScopeActive()
    if laneKey == "aura" then
        return (settings.showBuffs ~= false or settings.showDebuffs ~= false)
            and (ComponentEnabled("buffs") or ComponentEnabled("debuffs") or (tonumber(F.consumerCount) or 0) > 0)
    end
    if laneKey == "position" then return positionActive end
    if laneKey == "distance" then return positionActive and ComponentEnabled("distance") end
    if laneKey == "metadata" then return positionActive and ComponentEnabled("class") end
    if laneKey == "equipment" then
        return positionActive and (ComponentEnabled("gearScore") or ComponentEnabled("mainHand")
            or ComponentEnabled("offHand") or ComponentEnabled("ranged") or ComponentEnabled("wings"))
    end
    if laneKey == "cast" then return positionActive and ComponentEnabled("castBar") end
    return false
end

function F:ReconcileLanes()
    if self.enabled ~= true or (tonumber(self.consumerCount) or 0) <= 0 then
        for laneKey in pairs(self.lanes) do SetLaneActive(laneKey, false, nil) end
        self.laneData = { player = {}, target = {} }
        return true
    end
    local settings = Settings()
    SetLaneActive("aura", LaneNeeds("aura", settings), function() return F:Refresh("aura_lane") end, true)
    SetLaneActive("position", LaneNeeds("position", settings), function() return F:PositionTick() end, true)
    SetLaneActive("distance", LaneNeeds("distance", settings), function() return F:DistanceTick() end, true)
    SetLaneActive("metadata", LaneNeeds("metadata", settings), function() return F:MetadataTick() end, true)
    SetLaneActive("equipment", LaneNeeds("equipment", settings), function() return F:EquipmentTick() end, true)
    SetLaneActive("cast", LaneNeeds("cast", settings), function() return F:CastTick() end, true)
    return true
end

------------------------------------------------------------------------
-- Projection accessors
------------------------------------------------------------------------

function F:GetProjection(scope, limit)
    scope = tostring(scope or "player")
    if scope == "all" then
        local rows = {}
        for _, name in ipairs({ "player", "target" }) do
            for _, row in ipairs(self.projections[name] or {}) do
                local copy = {}
                for key, value in pairs(row) do copy[key] = value end
                copy.scope, copy.scopeText = name, name == "player" and "自己" or "目标"
                rows[#rows + 1] = copy
            end
        end
        limit = math.max(1, math.floor(tonumber(limit) or #rows))
        while #rows > limit do rows[#rows] = nil end
        return rows, self.revision, { player = self.coverage.player, target = self.coverage.target }
    end
    return self.projections[scope] or {}, self.revision, self.coverage[scope] or { available = false, complete = false, reliable = false }
end

function F:GetSettingsProjection()
    local current = SettingsRevision()
    if settingsCache ~= nil and settingsCacheRevision == current then return S.Utils.DeepCopy(settingsCache) end
    local snapshot = CopySettings()
    settingsCache, settingsCacheRevision = snapshot, current
    return S.Utils.DeepCopy(snapshot)
end

-- Head plates projection for the renderer: enabled components + bounded rows.
function F:GetPlatesProjection(scope)
    scope = tostring(scope or "player")
    local laneData = self.laneData[scope] or {}
    local plates = self.ProjectPlates(laneData, Settings())
    local maxRevision = 0
    for _, lane in pairs(self.lanes) do maxRevision = math.max(maxRevision, tonumber(lane.revision) or 0) end
    return plates, maxRevision
end

-- Screen anchor (logical RSUI space) for the head-plate renderer.
function F:GetPlatesAnchor(scope)
    scope = tostring(scope or "player")
    local lane = self.laneData[scope] or {}
    return lane.x, lane.y, lane.depth, lane.source
end

-- Legacy accessor kept for old consumers: tracked BUFF rows only.
function F:GetTrackedHeadProjection(scope)
    scope = tostring(scope or "player")
    if scope ~= "player" and scope ~= "target" then return {} end
    local settings = Settings()
    local maxIcons = math.max(1, math.min(12, math.floor(tonumber(settings.headMaxIcons) or 8)))
    local out = {}
    for _, row in ipairs(self.projections[scope] or {}) do
        if row.tracked == true and row.category ~= "debuff" then
            local copy = {}
            for key, value in pairs(row) do copy[key] = value end
            out[#out + 1] = copy
            if #out >= maxIcons then break end
        end
    end
    return out, self.revision, S.Utils.DeepCopy(self.coverage[scope] or {})
end

------------------------------------------------------------------------
-- Aura consumer lease (unchanged contract)
------------------------------------------------------------------------

function F:_AcquireAura()
    if self.auraHeld == true then return true end
    local aura = Aura()
    if type(aura) ~= "table" or type(aura.AcquireConsumer) ~= "function" then return false, "共享 Aura 服务不可用" end
    local ok, err = aura:AcquireConsumer("buff_display:aura", { purpose = "buff_display" })
    if ok ~= true then return false, err end
    self.auraHeld = true
    return true
end

function F:_ReleaseAura()
    if self.auraHeld ~= true then return true end
    local aura = Aura()
    if type(aura) ~= "table" or type(aura.ReleaseConsumer) ~= "function" then return false, "共享 Aura 服务释放不可用" end
    local ok, err = aura:ReleaseConsumer("buff_display:aura")
    if ok ~= true then return false, err end
    self.auraHeld = false
    return true
end

-- Contract-compatible aura task wrappers (the aura lane is the periodic task).
function F:_StartTask()
    return SetLaneActive("aura", true, function() return F:Refresh("scheduled") end, true)
end
function F:_StopTask()
    return SetLaneActive("aura", false, nil)
end

function F:_QueueEventRefresh(reason, delayMs)
    if self.enabled ~= true or (tonumber(self.consumerCount) or 0) <= 0 then return true end
    if S.Scheduler == nil or type(S.Scheduler.AddOneShot) ~= "function" then return false, "统一调度器 one-shot 不可用" end
    S.Scheduler:RemoveTask(self.eventTaskName)
    local eventReason = tostring(reason or "event")
    local ok = S.Scheduler:AddOneShot(self.eventTaskName, math.max(80, tonumber(delayMs) or 120), function()
        if F.enabled == true and (tonumber(F.consumerCount) or 0) > 0 then
            -- Aura events refresh only Aura facts. They must not trigger class,
            -- equipment or cast Native reads; those lanes own their cadence.
            F:Refresh(eventReason)
            if eventReason == "target_changed" then
                local settings = Settings()
                if LaneNeeds("position", settings) then F:PositionTick() end
                if LaneNeeds("distance", settings) then F:DistanceTick() end
                if LaneNeeds("metadata", settings) then F:MetadataTick() end
                if LaneNeeds("equipment", settings) then F:EquipmentTick() end
                if LaneNeeds("cast", settings) then F:CastTick() end
            end
            return true
        end
        return true
    end, self, "P2", 1)
    if ok == true and type(S.Scheduler.SetTaskModule) == "function" then S.Scheduler:SetTaskModule(self.eventTaskName, self.Id, true) end
    return ok == true, ok == true and nil or "状态显示事件合并任务创建失败"
end

function F:_StartEvents()
    if self.eventSubscribed == true then return true end
    if S.Events == nil or type(S.Events.SubscribeOptional) ~= "function" then return true end
    local any = false
    if S.Events:SubscribeOptional("BUFF_UPDATE", self, function()
        F.eventEdges = (tonumber(F.eventEdges) or 0) + 1
        return F:_QueueEventRefresh("buff_update", 120)
    end) == true then any = true end
    if S.Events:SubscribeOptional("DEBUFF_UPDATE", self, function()
        F.eventEdges = (tonumber(F.eventEdges) or 0) + 1
        return F:_QueueEventRefresh("debuff_update", 120)
    end) == true then any = true end
    if S.Events:SubscribeOptional("TARGET_CHANGED", self, function()
        F.eventEdges = (tonumber(F.eventEdges) or 0) + 1
        return F:_QueueEventRefresh("target_changed", 80)
    end) == true then any = true end
    -- internal: re-gate lanes when any display setting changes
    if type(S.Events.SubscribeInternal) == "function" then
        S.Events:UnsubscribeInternalOwner(self)
        S.Events:SubscribeInternal("v3.buff_display.settings", self, function()
            self.trackedIndex = self:BuildTrackedIndex(Settings())
            return self:ReconcileLanes()
        end)
        any = true
    end
    self.eventSubscribed = any
    return true
end

function F:_StopEvents()
    if S.Events ~= nil and type(S.Events.UnsubscribeOwner) == "function" then S.Events:UnsubscribeOwner(self) end
    if S.Events ~= nil and type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
    if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(self.eventTaskName) end
    self.eventSubscribed = false
    return true
end

function F:ReconcileDemand(before, after)
    local beforeCount, afterCount = tonumber(before and before.count) or 0, tonumber(after and after.count) or 0
    if beforeCount <= 0 and afterCount > 0 then
        local ok, err = self:_AcquireAura()
        if ok ~= true then return false, err end
        ok, err = self:_StartTask()
        if ok ~= true then self:_ReleaseAura(); return false, err end
        self:_StartEvents()
        self:ReconcileLanes()
    elseif beforeCount > 0 and afterCount <= 0 then
        self:_StopEvents()
        for laneKey in pairs(self.lanes) do SetLaneActive(laneKey, false, nil) end
        local ok, err = self:_ReleaseAura()
        if ok ~= true then return false, err end
        self.projections = { player = {}, target = {} }
        self.coverage = { player = {}, target = {} }
        self.laneData = { player = {}, target = {} }
    end
    return true
end

if S.Demand == nil or type(S.Demand.Create) ~= "function" then error("Demand unavailable for BuffDisplay") end
local demand, demandErr = S.Demand:Create({
    id = "feature:" .. F.Id, owner = F, projectionOwner = F,
    projectionConsumersField = "consumers", projectionCountField = "consumerCount",
    reconcile = function(_, before, after) return F:ReconcileDemand(before, after) end,
    quiesce = function()
        F:_StopEvents()
        for laneKey in pairs(F.lanes) do SetLaneActive(laneKey, false, nil) end
        F:_ReleaseAura()
        F.laneData = { player = {}, target = {} }
        return true
    end,
})
if demand == nil then error(demandErr) end
F.Demand = demand

function F:Initialize()
    local ok, err = self:EnsureStoreLoaded()
    if ok ~= true then return false, err end
    local aura = Aura()
    if type(aura) ~= "table" or type(aura.GetSnapshot) ~= "function" or type(aura.GetStatusMap) ~= "function" then
        return false, "AuraObservationV3 unavailable"
    end
    local classification = Classification()
    if type(classification) ~= "table" or type(classification.ClassifyEntry) ~= "function" then
        return false, "StatusClassificationV3 unavailable"
    end
    local projection = Projection()
    if type(projection) ~= "table" or type(projection.ProjectUnit) ~= "function" then
        return false, "ScreenProjectionV3 unavailable"
    end
    if type(self.ProjectStatusMap) ~= "function" or type(self.ProjectPlates) ~= "function" then
        return false, "状态显示投影模块未完整加载"
    end
    self.trackedIndex = self:BuildTrackedIndex(Settings())
    return true
end

function F:AcquireConsumer(token)
    if self.enabled ~= true then return false, "状态显示功能未启用" end
    return self.Demand:Acquire(token, {}, "buff_display_consumer")
end
function F:ReleaseConsumer(token) return self.Demand:Release(token, "buff_display_consumer") end
function F:Enable() self.enabled = true; return true end
function F:Disable(reason)
    if self.enabled ~= true then return true end
    local ok, err = self.Demand:Clear(reason or "feature_disable")
    if ok ~= true then return false, err end
    self.enabled = false
    return true
end
function F:GetHealth()
    local aura = Aura()
    local ah = type(aura) == "table" and type(aura.GetHealth) == "function" and aura:GetHealth() or {}
    local activeLanes = {}
    for laneKey, lane in pairs(self.lanes) do if lane.active == true then activeLanes[#activeLanes + 1] = laneKey end end
    table.sort(activeLanes)
    return { ok = self.enabled == true, consumers = self.consumerCount, auraHeld = self.auraHeld == true,
        revision = self.revision, player = self.coverage.player, target = self.coverage.target,
        eventSubscribed = self.eventSubscribed == true, eventEdges = tonumber(self.eventEdges) or 0,
        eventRefreshPending = S.Scheduler ~= nil and S.Scheduler.tasks and S.Scheduler.tasks[self.eventTaskName] ~= nil,
        observationContractVersion = 2,
        activeLanes = activeLanes,
        auraConsumers = tonumber(ah.consumers) or 0, taskActive = S.Scheduler ~= nil and S.Scheduler.tasks and S.Scheduler.tasks[self.taskName] ~= nil }
end

function F:GetWidgetVisible() return self.State and self.State.widgetVisible == true end
function F:GetWidgetWindowState()
    local value = self.State and self.State.widgetWindow or nil
    local floating = S.RSUI and S.RSUI.FloatingSurface or nil
    local policy = { defaultWidth = 430, defaultHeight = 300, minWidth = 180, minHeight = 100,
        defaultOverallOpacity = 0.94, defaultBackgroundOpacity = 1.0, defaultTextOpacity = 1.0 }
    if type(floating) == "table" and type(floating.NormalizeState) == "function" then
        return S.Utils.DeepCopy(floating:NormalizeState(value, policy))
    end
    return S.Utils.DeepCopy(value)
end
function F:SetWidgetWindowState(value, reason)
    if type(value) ~= "table" or type(self.State) ~= "table" then return false, "buff display widget window state unavailable" end
    local floating = S.RSUI and S.RSUI.FloatingSurface or nil
    local policy = { defaultWidth = 430, defaultHeight = 300, minWidth = 180, minHeight = 100,
        defaultOverallOpacity = 0.94, defaultBackgroundOpacity = 1.0, defaultTextOpacity = 1.0 }
    self.State.widgetWindow = type(floating) == "table" and type(floating.NormalizeState) == "function"
        and floating:NormalizeState(value, policy) or S.Utils.DeepCopy(value)
    return true
end
function F:SetWidgetVisible(value, reason)
    if self.State == nil then return false, "状态显示设置不可用" end
    local before = self.State.widgetVisible == true
    self.State.widgetVisible = value == true
    local ok, err = self:MarkStoreDirty(250, "widget_" .. tostring(reason or "visibility"))
    if ok ~= true then self.State.widgetVisible = before; return false, err or "状态显示显隐保存失败" end
    return true
end

------------------------------------------------------------------------
-- Import / Export
------------------------------------------------------------------------

-- Parse a plain tracked-id text. Commas, semicolons and whitespace are valid
-- separators. Invalid entries do not invalidate the valid remainder.
function F:ParseTrackedText(text)
    text = tostring(text or "")
    local ids, seen, errors, duplicates = {}, {}, {}, 0
    for _, raw in ipairs(SplitLines(text)) do
        local comment = string.find(raw, "#", 1, true)
        local line = comment ~= nil and string.sub(raw, 1, comment - 1) or raw
        for token in line:gmatch("[^,%s;]+") do
            local id = tonumber(token)
            if id == nil or id ~= math.floor(id) or id <= 0 then
                errors[#errors + 1] = "无效 ID：" .. tostring(token)
            elseif seen[id] == true then
                duplicates = duplicates + 1
            else
                seen[id] = true
                ids[#ids + 1] = id
            end
        end
    end
    table.sort(ids)
    return { ids = ids, errors = errors, duplicates = duplicates }
end

-- Quick tracked-id import. category: "buff" | "debuff" | "auto".
-- mode: "merge" keeps existing tracked ids, "overwrite" replaces the category.
function F:ImportTrackedIds(text, category, mode)
    local parsed = self:ParseTrackedText(text)
    if type(parsed) ~= "table" then return false, "追踪 ID 解析失败" end
    if #parsed.ids == 0 then
        local suffix = #parsed.errors > 0 and ("；非法 " .. tostring(#parsed.errors) .. " 项") or ""
        return false, "没有可导入的 Buff ID" .. suffix
    end
    local before = S.Utils.DeepCopy(self.State.settings)
    local settings = self.State.settings
    local targetCategories = {}
    if category == "debuff" then targetCategories[1] = "debuff"
    elseif category == "buff" then targetCategories[1] = "buff"
    else targetCategories[1], targetCategories[2] = "buff", "debuff" end
    for _, bucket in ipairs(targetCategories) do
        local existing = mode == "overwrite" and {} or S.Utils.DeepCopy(settings.tracked[bucket] or {})
        local seen = {}
        for _, id in ipairs(existing) do seen[id] = true end
        for _, id in ipairs(parsed.ids) do
            local bucketCategory = bucket
            if category == "auto" or category == nil then
                local classification = Classification()
                if classification ~= nil and type(classification.ClassifyId) == "function" then
                    local kind = classification:ClassifyId(id, settings.classification)
                    if kind ~= nil and kind.category == "debuff" then bucketCategory = "debuff" else bucketCategory = "buff" end
                end
            end
            if bucketCategory == bucket and seen[id] ~= true and #existing < 32 then
                seen[id] = true
                existing[#existing + 1] = id
            end
        end
        table.sort(existing)
        settings.tracked[bucket] = existing
    end
    local marked, markErr = self:MarkStoreDirty(250, "import_tracked")
    if marked ~= true then self.State.settings = before; return false, markErr or "追踪 ID 导入保存失败" end
    self.trackedIndex = self:BuildTrackedIndex(settings)
    self:SyncTrackedProjectionFlags()
    Publish("v3.buff_display.settings", "tracked")
    local details = { "有效 " .. tostring(#parsed.ids) }
    if (tonumber(parsed.duplicates) or 0) > 0 then details[#details + 1] = "重复 " .. tostring(parsed.duplicates) end
    if #parsed.errors > 0 then details[#details + 1] = "非法 " .. tostring(#parsed.errors) end
    return true, "导入完成：" .. table.concat(details, " · ")
end

-- Full export: schema version + tracked + components + classification + policy.
function F:ExportAll()
    local settings = Settings()
    return {
        format = "replicatedsuite.buff_display",
        schemaVersion = self.SchemaVersion or 4,
        tracked = S.Utils.DeepCopy(settings.tracked or { buff = {}, debuff = {} }),
        components = S.Utils.DeepCopy(settings.components or {}),
        classification = S.Utils.DeepCopy(settings.classification or {}),
        settings = {
            showBuffs = settings.showBuffs ~= false, showDebuffs = settings.showDebuffs ~= false,
            playerRows = settings.playerRows, targetRows = settings.targetRows,
            refreshMs = settings.refreshMs, headEnabled = settings.headEnabled ~= false,
            headShowAll = settings.headShowAll == true,
            headPlayer = settings.headPlayer ~= false, headTarget = settings.headTarget ~= false,
            headRefreshMs = settings.headRefreshMs, headMaxIcons = settings.headMaxIcons,
            headShowStacks = settings.headShowStacks ~= false, headShowTime = settings.headShowTime ~= false,
        },
    }
end

-- Line-based serialization for the multi-line edit box.
function F:SerializeExport(data)
    data = type(data) == "table" and data or {}
    local lines = {
        "# ReplicatedSuite 状态显示导出",
        "VERSION=" .. tostring(data.schemaVersion or self.SchemaVersion or 4),
        "FORMAT=" .. tostring(data.format or "replicatedsuite.buff_display"),
    }
    for _, category in ipairs({ "buff", "debuff" }) do
        local ids = type(data.tracked) == "table" and type(data.tracked[category]) == "table" and data.tracked[category] or {}
        if #ids > 0 then lines[#lines + 1] = string.upper(category) .. "=" .. table.concat(ids, ",") end
    end
    local classification = type(data.classification) == "table" and data.classification or {}
    for id, category in pairs(classification) do lines[#lines + 1] = "CLASSIFICATION=" .. tostring(id) .. ":" .. tostring(category) end
    for _, key in ipairs(COMPONENT_KEYS) do
        local component = type(data.components) == "table" and data.components[key] or nil
        if type(component) == "table" then
            lines[#lines + 1] = "COMPONENT=" .. key .. ":enabled:" .. (component.enabled ~= false and "1" or "0")
            lines[#lines + 1] = "COMPONENT=" .. key .. ":x:" .. tostring(component.x or 0)
            lines[#lines + 1] = "COMPONENT=" .. key .. ":y:" .. tostring(component.y or 0)
            lines[#lines + 1] = "COMPONENT=" .. key .. ":size:" .. tostring(component.size or 0)
            lines[#lines + 1] = "COMPONENT=" .. key .. ":fontSize:" .. tostring(component.fontSize or 0)
            lines[#lines + 1] = "COMPONENT=" .. key .. ":alpha:" .. tostring(component.alpha or 1)
        end
    end
    local policy = type(data.settings) == "table" and data.settings or {}
    for _, key in ipairs({ "refreshMs", "headRefreshMs", "headMaxIcons", "playerRows", "targetRows", "showBuffs", "showDebuffs", "headEnabled", "headShowAll", "headPlayer", "headTarget", "headShowStacks", "headShowTime" }) do
        if policy[key] ~= nil then lines[#lines + 1] = "SETTING=" .. key .. ":" .. tostring(policy[key]) end
    end
    return table.concat(lines, "\n")
end

-- Parse full-export text. Returns { data = table, errors = {line:n msg}, warnings = {...} }.
function F:ParseImportText(text)
    text = tostring(text or "")
    local data = { tracked = { buff = {}, debuff = {} }, components = {}, classification = {}, settings = {}, schemaVersion = 4 }
    local errors, warnings = {}, {}
    local seenTracked = {}
    for index, raw in ipairs(SplitLines(text)) do
        local line = raw:gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local eq = string.find(line, "=", 1, true)
            if eq == nil then errors[#errors + 1] = "第 " .. tostring(index) .. " 行缺少 =： " .. tostring(raw); else
                local key, value = string.sub(line, 1, eq - 1), string.sub(line, eq + 1)
                key = key:gsub("%s+", ""):upper()
                value = value:gsub("%s+", "")
                if key == "VERSION" then
                    local version = tonumber(value)
                    if version ~= nil then data.schemaVersion = math.floor(version) end
                elseif key == "BUFF" or key == "DEBUFF" then
                    local bucket = key == "DEBUFF" and "debuff" or "buff"
                    for token in value:gmatch("[^,;]+") do
                        token = token:gsub("%s+", "")
                        local id = tonumber(token)
                        if id ~= nil and id == math.floor(id) and id > 0 then
                            if seenTracked[id] ~= true then
                                seenTracked[id] = true
                                if #data.tracked[bucket] < 32 then data.tracked[bucket][#data.tracked[bucket] + 1] = id
                                else warnings[#warnings + 1] = "第 " .. tostring(index) .. " 行：单类最多 32 个，已截断" end
                            end
                        else
                            errors[#errors + 1] = "第 " .. tostring(index) .. " 行：无效 ID " .. tostring(token)
                        end
                    end
                elseif key == "CLASSIFICATION" then
                    local colon = string.find(value, ":", 1, true)
                    if colon == nil then errors[#errors + 1] = "第 " .. tostring(index) .. " 行：分类格式应为 id:buff|debuff" else
                        local id = tonumber(string.sub(value, 1, colon - 1))
                        local category = string.sub(value, colon + 1):lower()
                        if id ~= nil and id > 0 and (category == "buff" or category == "debuff") then
                            data.classification[id] = category
                        else
                            errors[#errors + 1] = "第 " .. tostring(index) .. " 行：无效分类 " .. tostring(value)
                        end
                    end
                elseif key == "COMPONENT" then
                    local parts = {}
                    for part in value:gmatch("[^:]+") do parts[#parts + 1] = part end
                    if #parts < 3 then errors[#errors + 1] = "第 " .. tostring(index) .. " 行：组件格式应为 key:field:value" else
                        local componentKey, field, rawValue = parts[1], parts[2], parts[3]
                        local known = false
                        for _, ck in ipairs(COMPONENT_KEYS) do if ck == componentKey then known = true break end end
                        if not known then errors[#errors + 1] = "第 " .. tostring(index) .. " 行：未知组件 " .. tostring(componentKey) else
                            local component = data.components[componentKey] or {}
                            if field == "enabled" then component.enabled = rawValue == "1" or rawValue == "true"
                            elseif field == "x" or field == "y" or field == "size" or field == "fontSize" then
                                local n = tonumber(rawValue)
                                if n == nil then errors[#errors + 1] = "第 " .. tostring(index) .. " 行：无效数值 " .. tostring(rawValue)
                                else component[field] = math.floor(n) end
                            elseif field == "alpha" then
                                local n = tonumber(rawValue)
                                if n == nil then errors[#errors + 1] = "第 " .. tostring(index) .. " 行：无效透明度 " .. tostring(rawValue)
                                else component[field] = n end
                            else errors[#errors + 1] = "第 " .. tostring(index) .. " 行：未知组件字段 " .. tostring(field) end
                            data.components[componentKey] = component
                        end
                    end
                elseif key == "SETTING" then
                    local colon = string.find(value, ":", 1, true)
                    if colon == nil then errors[#errors + 1] = "第 " .. tostring(index) .. " 行：设置格式应为 key:value" else
                        data.settings[string.sub(value, 1, colon - 1)] = string.sub(value, colon + 1)
                    end
                else
                    warnings[#warnings + 1] = "第 " .. tostring(index) .. " 行：忽略未知条目 " .. tostring(key)
                end
            end
        end
    end
    table.sort(data.tracked.buff)
    table.sort(data.tracked.debuff)
    return { data = data, errors = errors, warnings = warnings }
end

-- Apply parsed full-export data. mode "merge" only adds missing tracked ids and
-- applies components/classification that are explicitly present; "overwrite"
-- replaces tracked lists entirely (policy fields always overwrite when present).
function F:ImportAll(data, mode)
    if type(data) ~= "table" then return false, "导入数据无效" end
    local before = S.Utils.DeepCopy(self.State.settings)
    local settings = self.State.settings
    local classification = Classification()

    if type(data.tracked) == "table" then
        for _, category in ipairs({ "buff", "debuff" }) do
            local ids = type(data.tracked[category]) == "table" and data.tracked[category] or {}
            local existing = mode == "overwrite" and {} or S.Utils.DeepCopy(settings.tracked[category] or {})
            local seen = {}
            for _, id in ipairs(existing) do seen[id] = true end
            for _, id in ipairs(ids) do
                id = math.floor(tonumber(id) or 0)
                if id > 0 and seen[id] ~= true and #existing < 32 then seen[id] = true; existing[#existing + 1] = id end
            end
            table.sort(existing)
            settings.tracked[category] = existing
        end
    end
    if type(data.classification) == "table" and next(data.classification) ~= nil then
        local merged = S.Utils.DeepCopy(settings.classification or {})
        for id, category in pairs(data.classification) do
            local numeric = math.floor(tonumber(id) or 0)
            if numeric > 0 and (category == "buff" or category == "debuff") then merged[numeric] = category end
        end
        settings.classification = merged
        if classification ~= nil and type(classification.ApplyOverrides) == "function" then classification:ApplyOverrides(merged) end
    end
    if type(data.components) == "table" then
        for _, key in ipairs(COMPONENT_KEYS) do
            local component = data.components[key]
            if type(component) == "table" and next(component) ~= nil then
                local target = settings.components[key]
                if target ~= nil then
                    for field, value in pairs(component) do
                        if field == "enabled" then target.enabled = value ~= false
                        elseif field == "x" or field == "y" then target[field] = math.max(-400, math.min(400, math.floor(tonumber(value) or target[field])))
                        elseif field == "size" then target.size = math.max(0, math.min(64, math.floor(tonumber(value) or target.size)))
                        elseif field == "fontSize" then target.fontSize = math.max(0, math.min(32, math.floor(tonumber(value) or target.fontSize)))
                        elseif field == "alpha" then target.alpha = math.max(0.1, math.min(1, tonumber(value) or target.alpha)) end
                    end
                end
            end
        end
    end
    local policy = type(data.settings) == "table" and data.settings or {}
    for key, value in pairs(policy) do
        if key == "refreshMs" or key == "headRefreshMs" then settings[key] = math.max(1, math.min(2000, math.floor(tonumber(value) or settings[key])))
        elseif key == "headMaxIcons" then settings.headMaxIcons = math.max(1, math.min(12, math.floor(tonumber(value) or settings.headMaxIcons)))
        elseif key == "playerRows" or key == "targetRows" then settings[key] = math.max(1, math.min(64, math.floor(tonumber(value) or settings[key])))
        elseif key == "showBuffs" or key == "showDebuffs" or key == "headEnabled" or key == "headShowAll" or key == "headPlayer" or key == "headTarget" or key == "headShowStacks" or key == "headShowTime" then
            local raw = tostring(value):lower()
            settings[key] = raw == "1" or raw == "true"
        end
    end
    local marked, markErr = self:MarkStoreDirty(250, "import_all")
    if marked ~= true then self.State.settings = before; return false, markErr or "完整导入保存失败" end
    self.trackedIndex = self:BuildTrackedIndex(settings)
    self:SyncTrackedProjectionFlags()
    self:ReconcileLanes()
    Publish("v3.buff_display.settings", "import")
    return true, "完整导入成功"
end

F.Commands = {
    Refresh = function(_, reason) return F:Refresh(reason or "buff_display_command") end,
    SetSetting = function(_, key, value)
        local ok, err = F:SetSettingValue(key, value)
        if ok == true then F:ReconcileLanes() end
        return ok, err
    end,
    SetTrackedId = function(_, id, category, enabled)
        local ok, err = F:SetTrackedId(id, category, enabled)
        if ok == true then
            F.trackedIndex = F:BuildTrackedIndex(Settings())
            F:SyncTrackedProjectionFlags()
        end
        return ok, err
    end,
    ClearTrackedIds = function(_, category)
        local ok, err = F:ClearTrackedIds(category)
        if ok == true then
            F.trackedIndex = F:BuildTrackedIndex(Settings())
            F:SyncTrackedProjectionFlags()
        end
        return ok, err
    end,
    SetComponentField = function(_, componentKey, field, value)
        return F:SetComponentField(componentKey, field, value)
    end,
    SetClassification = function(_, id, category)
        local ok, err = F:SetClassification(id, category)
        if ok == true then
            local classification = Classification()
            if classification ~= nil and type(classification.SetOverride) == "function" then classification:SetOverride(id, category) end
        end
        return ok, err
    end,
    ClearClassification = function(_, id)
        local ok, err = F:ClearClassification(id)
        if ok == true then
            local classification = Classification()
            if classification ~= nil and type(classification.ClearOverride) == "function" then classification:ClearOverride(id) end
        end
        return ok, err
    end,
    ApplySettingFromBinding = function(_, key, value) return F:ApplySettingFromBinding(key, value) end,
    MarkStoreDirty = function(_, delayMs, reason) return F:MarkStoreDirty(delayMs, reason) end,
    GetSettings = function() return F:GetSettings() end,
    GetWidgetVisible = function() return F:GetWidgetVisible() end,
    SetWidgetVisible = function(_, value, reason) return F:SetWidgetVisible(value, reason) end,
    SetWidgetWindowState = function(_, value, reason) return F:SetWidgetWindowState(value, reason) end,
    ParseTrackedText = function(_, text) return F:ParseTrackedText(text) end,
    ImportTrackedIds = function(_, text, category, mode) return F:ImportTrackedIds(text, category, mode) end,
    ExportAll = function() return F:ExportAll() end,
    SerializeExport = function(_, data) return F:SerializeExport(data) end,
    ParseImportText = function(_, text) return F:ParseImportText(text) end,
    ImportAll = function(_, data, mode) return F:ImportAll(data, mode) end,
}

local ok, err = Runtime:RegisterImplementation(F.Id, F)
if ok ~= true then error(err) end

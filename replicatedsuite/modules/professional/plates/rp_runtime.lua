ReplicatedSuiteModuleSandbox:Enter('plates', {'ReplicatedPlates', 'ReplicatedPlatesModule'})
------------------------------------------------------------------------
-- Replicated Plates - Single runtime host (v0.6.1 + Suite FrameBudget / warm watchdog recovery)
-- One host owns target/player. No per-plate OnUpdate handlers.
------------------------------------------------------------------------
if ReplicatedPlates == nil or ReplicatedPlates.BootError ~= nil or ReplicatedPlates.Api == nil or ReplicatedPlates.Storage == nil or ReplicatedPlates.UI == nil then return end
local P, A, S, U = ReplicatedPlates, ReplicatedPlates.Api, ReplicatedPlates.Storage, ReplicatedPlates.UI
-- `_G` is the isolated module environment; use the root-fallback lookup.
local SuitePerformance = ReplicatedSuite and ReplicatedSuite.PerformanceMonitor or nil
local SuiteFrameBudget = ReplicatedSuite and ReplicatedSuite.FrameBudget or nil
local SuiteDiagnostics = ReplicatedSuite and ReplicatedSuite.DiagnosticsManager or nil
local runtimeGeneration = P.Generation
local apiOk, apiErr = A:Validate()
if not apiOk then P.BootError = "api validation: " .. tostring(apiErr); P.SafeChat("API校验失败：" .. tostring(apiErr)); return end

local SCOPE_ORDER = { "target", "player" }
local UNIT_TOKEN = { target = "target", player = "player" }
local EFFECT_INTERVAL = { target = 120, player = 100 }
local PlatesData = ReplicatedSuite and ReplicatedSuite.GameIds and ReplicatedSuite.GameIds.Plates or nil
local PlatesManager = ReplicatedPlates and ReplicatedPlates.Manager or nil

-- Plates keeps its single native OnUpdate host, but heavy/optional lanes ask the
-- Suite FrameBudget Authority for permission before consuming their accumulated
-- work. P0/P1 correctness lanes are never denied by the broker; P2-P5 lanes
-- preserve their accumulator when deferred, so no work is silently lost.
local LANE_BUDGET = {
    position            = { priority=1, cost=1 },
    metadata            = { priority=3, cost=1 },
    target_extras       = { priority=3, cost=1 },
    equipment           = { priority=3, cost=2 },
    important_cooldowns = { priority=3, cost=2 },
    health              = { priority=1, cost=1 },
    distance            = { priority=2, cost=1 },
    effects             = { priority=2, cost=2 },
    casting             = { priority=1, cost=1 },
    capture             = { priority=4, cost=2 },
    buffcap             = { priority=4, cost=1 },
    magiccircle         = { priority=3, cost=1 },
    watchtarget         = { priority=3, cost=1 },
    alerts              = { priority=2, cost=2 },
    lines               = { priority=4, cost=2 },
    circle              = { priority=4, cost=3 },
    discovery           = { priority=5, cost=2 },
    manager             = { priority=5, cost=2 },
    watchdog            = { priority=5, cost=1 },
}

-- Static records are discovery seeds only. The displayed countdown is always
-- read from the live RU client via X2Skill:GetCooldown/GetMateCooldown.
-- Keeping ids here avoids action-bar scans and lets the library grow without
-- adding per-frame work. "mate" entries probe both cooldown APIs because RU
-- Powerstone/Groa builds have exposed these skills through different paths.
local IMPORTANT_COOLDOWN_LIBRARY = PlatesData and PlatesData.ImportantCooldownEntries or {}

P.Runtime = {
    generation = runtimeGeneration,
    running = false,
    driver = nil,
    positionAccumulator = 999999,
    healthAccumulator = 999999,
    metadataAccumulator = 999999,
    targetMetaAccumulator = 999999,
    distanceAccumulator = 999999,
    castAccumulator = 999999,
    cooldownAccumulator = 999999,
    managerAccumulator = 999999,
    discoveryAccumulator = 999999,
    captureAccumulator = 999999,
    buffcapAccumulator = 999999,
    magicCircleAccumulator = 999999,
    watchAccumulator = 999999,
    alertsAccumulator = 999999,
    linesAccumulator = 999999,
    circleAccumulator = 999999,
    -- G1: one-shot circle diagnostics (zero-visible streak + missing projector).
    circleZeroStreak = 0,
    circleZeroWarned = nil,
    circleNoProjectorWarned = nil,
    positionIntervalMs = 16,
    healthIntervalMs = 80,
    metadataIntervalMs = 200,
    targetMetaIntervalMs = 1000,
    distanceIntervalMs = 180,
    castIntervalMs = 50,
    cooldownIntervalMs = 200,
    managerIntervalMs = 200,
    discoveryIntervalMs = 200,
    captureIntervalMs = 100,
    buffcapIntervalMs = 1000,
    magicCircleIntervalMs = 200,
    watchIntervalMs = 200,
    alertsIntervalMs = 200,
    linesIntervalMs = 100,
    circleIntervalMs = 100,
    forceGlobal = true,
    equipmentDirty = true,
    equippedItemSkillEntries = {},
    cooldownCache = {},
    cooldownProbeCursor = 1,
    cooldownProbeBudget = 6,
    scopes = {},
    lastAnyVisible = nil,
    scopeFailed = { target = false, player = false },
    laneErrors = {},
    magicCircleState = nil,
    heartbeatSerial = 0,
    successfulUpdateSerial = 0,
    watchdog = nil,
    watchdogRecoveries = 0,
    watchdogRecoveryAttempts = 0,
    watchdogRecoverySuccesses = 0,
    watchdogBudgetDeferrals = 0,
    watchdogRecoveryPending = false,
    visibilityRepairs = 0,
    budget = { requests=0, granted=0, deferred=0, starvation=0, byLane={} },
}
local R = P.Runtime

for index, scope in ipairs(SCOPE_ORDER) do
    R.scopes[scope] = {
        scope = scope,
        unit = UNIT_TOKEN[scope],
        positionValid = false,
        identityValid = false,
        lastScreenX = 0,
        lastScreenY = 0,
        lastAnchorX = nil,
        lastAnchorY = nil,
        lastSignature = nil,
        force = true,
        effectsAccumulator = 999999 - (index - 1) * 45,
        castIconHint = nil,
        positionReadFailures = 0,
        healthReadFailures = 0,
        identityReadFailures = 0,
        lastIdentityName = nil,
        effectSnapshots = { buff = {}, debuff = {}, hidden = {} },
        effectEmptyStreak = { buff = 0, debuff = 0, hidden = 0 },
        effectReadFailures = { buff = 0, debuff = 0, hidden = 0 },
        trackedOnlyFallback = { buff = false, debuff = false, hidden = false },
    }
end

local function DeltaMs(dt)
    local value = tonumber(dt) or 0
    if value ~= value or value == math.huge or value == -math.huge or value < 0 then value = 0 end
    if value > 0 and value <= 1.5 then value = value * 1000 end
    if value <= 0 then value = 16 end
    return math.min(250, value)
end

local function BudgetPolicy(label)
    local base = tostring(label or ""):match("^[^:]+") or tostring(label or "")
    return LANE_BUDGET[base] or { priority=3, cost=1 }
end

function R:TryBudgetLane(label, accumulatorMs, intervalMs)
    if ReplicatedSuiteEmbedded ~= true or SuiteFrameBudget == nil or type(SuiteFrameBudget.Request) ~= "function" then
        return true, "standalone"
    end
    label = tostring(label or "unknown")
    local policy = BudgetPolicy(label)
    local metrics = self.budget or { requests=0, granted=0, deferred=0, starvation=0, byLane={} }
    self.budget = metrics
    metrics.byLane = metrics.byLane or {}
    local lane = metrics.byLane[label]
    if lane == nil then
        lane = { requests=0, granted=0, deferred=0, consecutiveDefers=0, maxConsecutiveDefers=0, starvation=0, lastReason="" }
        metrics.byLane[label] = lane
    end
    local interval = math.max(1, tonumber(intervalMs) or 1)
    local lateRatio = math.max(0, (tonumber(accumulatorMs) or 0) / interval)
    metrics.requests = (tonumber(metrics.requests) or 0) + 1
    lane.requests = (tonumber(lane.requests) or 0) + 1
    local allowed, reason = SuiteFrameBudget:Request("plates:" .. label, policy.priority, policy.cost, lane.consecutiveDefers or 0, lateRatio)
    lane.lastReason = tostring(reason or "")
    if allowed then
        metrics.granted = (tonumber(metrics.granted) or 0) + 1
        lane.granted = (tonumber(lane.granted) or 0) + 1
        if reason == "starvation" then
            metrics.starvation = (tonumber(metrics.starvation) or 0) + 1
            lane.starvation = (tonumber(lane.starvation) or 0) + 1
        end
        lane.consecutiveDefers = 0
        return true, reason
    end
    metrics.deferred = (tonumber(metrics.deferred) or 0) + 1
    lane.deferred = (tonumber(lane.deferred) or 0) + 1
    lane.consecutiveDefers = (tonumber(lane.consecutiveDefers) or 0) + 1
    lane.maxConsecutiveDefers = math.max(tonumber(lane.maxConsecutiveDefers) or 0, lane.consecutiveDefers)
    return false, reason
end

function R:RequestWarmRecovery()
    -- Do not ForceAll and do not execute Runtime from inside the watchdog. Mark
    -- only correctness/visibility lanes due; the normal host will recover them
    -- on subsequent rendered frames under the same FrameBudget policy.
    self.positionAccumulator = math.max(tonumber(self.positionAccumulator) or 0, self.positionIntervalMs)
    self.healthAccumulator = math.max(tonumber(self.healthAccumulator) or 0, self.healthIntervalMs)
    self.metadataAccumulator = math.max(tonumber(self.metadataAccumulator) or 0, self.metadataIntervalMs)
    self.distanceAccumulator = math.max(tonumber(self.distanceAccumulator) or 0, self.distanceIntervalMs)
    self.castAccumulator = math.max(tonumber(self.castAccumulator) or 0, self.castIntervalMs)
    for _, scope in ipairs(SCOPE_ORDER) do
        local st = self.scopes[scope]
        if st ~= nil then st.effectsAccumulator = math.max(tonumber(st.effectsAccumulator) or 0, EFFECT_INTERVAL[scope]) end
    end
    self.watchdogRecoveryPending = true
end

function R:GetRuntimeDiagnostics()
    local budgetRows = {}
    for label, lane in pairs(self.budget and self.budget.byLane or {}) do
        if (tonumber(lane.deferred) or 0) > 0 or (tonumber(lane.starvation) or 0) > 0 then
            budgetRows[#budgetRows + 1] = {
                label=label, requests=tonumber(lane.requests) or 0, granted=tonumber(lane.granted) or 0,
                deferred=tonumber(lane.deferred) or 0, starvation=tonumber(lane.starvation) or 0,
                consecutiveDefers=tonumber(lane.consecutiveDefers) or 0, maxConsecutiveDefers=tonumber(lane.maxConsecutiveDefers) or 0,
                lastReason=tostring(lane.lastReason or ""),
            }
        end
    end
    table.sort(budgetRows, function(a,b)
        if a.deferred ~= b.deferred then return a.deferred > b.deferred end
        return tostring(a.label) < tostring(b.label)
    end)
    while #budgetRows > 8 do table.remove(budgetRows) end
    local storageHealth = type(S.GetHealth) == "function" and S:GetHealth() or nil
    local managerHealth = PlatesManager and type(PlatesManager.GetHealth) == "function" and PlatesManager:GetHealth() or nil
    return {
        version="1.2", running=self.running == true, heartbeat=tonumber(self.heartbeatSerial) or 0, successfulUpdates=tonumber(self.successfulUpdateSerial) or 0,
        watchdog={
            recoveries=tonumber(self.watchdogRecoveries) or 0, attempts=tonumber(self.watchdogRecoveryAttempts) or 0,
            successes=tonumber(self.watchdogRecoverySuccesses) or 0, budgetDeferrals=tonumber(self.watchdogBudgetDeferrals) or 0,
            pending=self.watchdogRecoveryPending == true, visibilityRepairs=tonumber(self.visibilityRepairs) or 0,
        },
        budget={
            requests=tonumber(self.budget and self.budget.requests) or 0, granted=tonumber(self.budget and self.budget.granted) or 0,
            deferred=tonumber(self.budget and self.budget.deferred) or 0, starvation=tonumber(self.budget and self.budget.starvation) or 0,
            topDeferred=budgetRows,
        },
        storage=storageHealth,
        storageConcerns=storageHealth and {
            persistence=storageHealth.persistence,
            tracking=storageHealth.tracking,
            auraLibrary=storageHealth.auraLibrary,
        } or nil,
        manager=managerHealth,
        managerConcerns=managerHealth and {
            catalog=managerHealth.catalog,
            discovery=managerHealth.discovery,
            capture=managerHealth.capture,
            importStage=managerHealth.importStage,
        } or nil,
        dataRelations={
            curated=PlatesData ~= nil and PlatesData.verified == false,
            confidence=PlatesData and PlatesData.confidence or "unknown",
            importantCooldowns=PlatesData and #(PlatesData.ImportantCooldownIds or {}) or 0,
            magicCircleBuffs=PlatesData and #(PlatesData.MagicCircleBuffIds or {}) or 0,
            targetArmorEffects=PlatesData and #(PlatesData.TargetArmorEffectIds or {}) or 0,
            targetWeaponEffects=PlatesData and #(PlatesData.TargetWeaponEffectIds or {}) or 0,
            timerCorrections=PlatesData and #(PlatesData.EffectTimerCorrectionIds or {}) or 0,
        },
        ui=P.UI ~= nil and type(P.UI.GetPerformanceSnapshot) == "function" and P.UI:GetPerformanceSnapshot() or nil,
    }
end

local function UnitSignature(unit)
    local id, name = A:GetUnitId(unit), A:GetUnitName(unit)
    if id ~= nil then return "id:" .. tostring(id), name end
    if name ~= nil then return "name:" .. tostring(name), name end
    return nil, nil
end

local function CandidateIconFromSpellEvent(args)
    for _, value in ipairs(args) do
        if type(value) == "string" and string.find(value, ".dds", 1, true) ~= nil then return value end
        if type(value) == "table" then
            local path = value.path or value.iconPath or value.icon_path or value.icon
            if type(path) == "string" and path ~= "" then return path end
            local id = tonumber(value.skillId or value.skill_id or value.skillType or value.skill_type)
            if id ~= nil then
                local resolved = A:ResolveSkillIcon(id)
                if resolved ~= nil then return resolved end
            end
        end
    end
    return nil
end

function R:ForceScope(scope)
    local st = self.scopes[scope]
    if st == nil then return end
    st.force = true
    st.effectsAccumulator = EFFECT_INTERVAL[scope]
    if scope == "player" then
        self.equipmentDirty = true
        self.cooldownAccumulator = self.cooldownIntervalMs
    end
    self.positionAccumulator = self.positionIntervalMs
    self.healthAccumulator = self.healthIntervalMs
    self.metadataAccumulator = self.metadataIntervalMs
    self.targetMetaAccumulator = self.targetMetaIntervalMs
    self.distanceAccumulator = self.distanceIntervalMs
    self.castAccumulator = self.castIntervalMs
end

function R:ForceAll()
    self.forceGlobal = true
    for _, scope in ipairs(SCOPE_ORDER) do self:ForceScope(scope) end
end

function R:ResetScope(scope)
    local st = self.scopes[scope]
    if st == nil then return end
    st.positionValid = false; st.identityValid = false; st.lastAnchorX = nil; st.lastAnchorY = nil; st.lastSignature = nil; st.castIconHint = nil; st.force = true
    st.positionReadFailures = 0; st.healthReadFailures = 0; st.identityReadFailures = 0; st.lastIdentityName = nil
    st.effectSnapshots = { buff = {}, debuff = {}, hidden = {} }
    st.effectEmptyStreak = { buff = 0, debuff = 0, hidden = 0 }
    st.effectReadFailures = { buff = 0, debuff = 0, hidden = 0 }
    st.trackedOnlyFallback = { buff = false, debuff = false, hidden = false }
    if U.calibrationScope == scope then U:SetCalibration(nil) end
    if U.layoutEditScope == scope then U:SetLayoutEdit(nil) end
    U:ResetPresentation(scope)
    U:SetPlateVisible(scope, false)
end

-- Isolate each runtime lane. A persistent exception in target metadata,
-- equipment, manager discovery, etc. must never starve the player Buff lane.
function R:SafeLane(label, scope, method, ...)
    if type(method) ~= "function" then return false end
    local ok, err = pcall(method, self, ...)
    if ok then
        self.laneErrors[label] = nil
        return true
    end
    local text = tostring(err or "unknown")
    if scope ~= nil and self.scopeFailed[scope] ~= nil then
        self.scopeFailed[scope] = true
        local st = self.scopes[scope]
        if st ~= nil then st.force = true end
    end
    if self.laneErrors[label] ~= text then
        self.laneErrors[label] = text
    end
    return false
end

function R:UpdatePosition(scope)
    local st, cfg = self.scopes[scope], S:Get()[scope]
    if st == nil or cfg == nil then return end
    local function InvalidatePosition()
        local wasValid = st.positionValid == true
        st.positionValid = false; st.identityValid = false; st.lastAnchorX = nil; st.lastAnchorY = nil
        if wasValid then
            st.lastSignature = nil; st.castIconHint = nil; st.force = true
            if U.calibrationScope == scope then U:SetCalibration(nil) end
            if U.layoutEditScope == scope then U:SetLayoutEdit(nil) end
            U:ResetPresentation(scope)
        end
        U:SetPlateVisible(scope, false)
    end
    if cfg.enabled ~= true then st.positionReadFailures = 0; InvalidatePosition(); return end
    -- Projection fallback: native GetUnitScreenPosition can transiently return
    -- nil for a frame while the client rebuilds nameplates; UnitScreenPoint
    -- bridges those frames with a world->screen projection when enabled.
    local x, y, z = A:UnitScreenPoint(st.unit)
    if x == nil or y == nil or z == nil or z <= 0 then
        st.positionReadFailures = (tonumber(st.positionReadFailures) or 0) + 1
        -- GetUnitScreenPosition can transiently return nil for a frame while the
        -- client rebuilds native nameplates. Do not erase the whole presentation
        -- (including valid Buff icons) on a single missed sample.
        if st.positionReadFailures >= 3 then InvalidatePosition() end
        return
    end
    st.positionReadFailures = 0
    local becameVisible = st.positionValid ~= true
    st.positionValid = true; st.lastScreenX = x; st.lastScreenY = y
    if becameVisible then
        -- Do not expose stale HP/effects/metadata for up to one lane interval
        -- when a unit returns on-screen. Force every relevant lane now.
        self:ForceScope(scope)
    end
    local anchorX = math.floor(x + cfg.offsetX + 0.5)
    local anchorY = math.floor(y + cfg.offsetY + 0.5)
    local uiState = U.plates[scope]
    if uiState ~= nil and uiState.dragging ~= true then
        if st.force or st.lastAnchorX == nil or st.lastAnchorY == nil or math.abs(anchorX - st.lastAnchorX) >= 1 or math.abs(anchorY - st.lastAnchorY) >= 1 then
            st.lastAnchorX, st.lastAnchorY = anchorX, anchorY
            U:MovePlate(scope, anchorX, anchorY)
        end
    end
end

function R:UpdateMetadata(scope)
    local st, cfg = self.scopes[scope], S:Get()[scope]
    if st == nil or cfg == nil or cfg.enabled ~= true then return end
    local signature, name = UnitSignature(st.unit)
    if name == nil then
        st.identityReadFailures = (tonumber(st.identityReadFailures) or 0) + 1
        -- UnitName/GetUnitId may transiently disappear while native plates are
        -- rebuilt. Keep the last valid presentation for two misses instead of
        -- clearing every Buff icon immediately.
        if st.identityReadFailures < 3 and st.identityValid == true then return end
        st.identityValid = false
        if U.calibrationScope == scope then U:SetCalibration(nil) end
        if U.layoutEditScope == scope then U:SetLayoutEdit(nil) end
        U:SetPlateVisible(scope, false)
        return
    end
    st.identityReadFailures = 0
    local sameName = st.lastIdentityName ~= nil and tostring(st.lastIdentityName) == tostring(name)
    if signature ~= st.lastSignature then
        if st.lastSignature == nil or not sameName then
            st.lastSignature = signature; st.castIconHint = nil; st.force = true; U:ResetPresentation(scope)
        else
            -- Some RU client frames expose GetUnitId intermittently, causing the
            -- signature to alternate between id:* and name:* for the same unit.
            -- Do not treat that representation change as a different player.
            st.lastSignature = signature
        end
    end
    st.lastIdentityName = name
    st.identityValid = true
    U:UpdateName(scope, name)
end

function R:UpdateHealth(scope)
    local st, cfg = self.scopes[scope], S:Get()[scope]
    if st == nil or cfg == nil or cfg.enabled ~= true or st.positionValid ~= true or st.identityValid ~= true then return end
    local current, maximum = A:GetHealth(st.unit)
    if current == nil or maximum == nil then
        st.healthReadFailures = (tonumber(st.healthReadFailures) or 0) + 1
        if st.healthReadFailures >= 3 then U:SetPlateVisible(scope, false) end
        return
    end
    st.healthReadFailures = 0
    U:UpdateHealth(scope, current, maximum)
    -- Health is the final display gate. Position only moves the HUD and
    -- metadata only validates identity, preventing lane visibility races.
    U:SetPlateVisible(scope, true)
end

function R:UpdateDistance(scope)
    local st, cfg = self.scopes[scope], S:Get()[scope]
    if st == nil or cfg == nil or cfg.enabled ~= true or st.positionValid ~= true or st.identityValid ~= true then return end
    if cfg.showDistance ~= true then U:UpdateDistance(scope, nil); return end
    U:UpdateDistance(scope, A:GetDistance(st.unit))
end

function R:UpdateEffects(scope)
    local st, cfg = self.scopes[scope], S:Get()[scope]
    if st == nil or cfg == nil or cfg.enabled ~= true or st.positionValid ~= true or st.identityValid ~= true then return end
    local trackedOnly = cfg.trackedOnly == true
    st.effectReadFailures = st.effectReadFailures or {}

    local function Read(effectType, enabled)
        if enabled ~= true then
            st.effectReadFailures[effectType] = 0
            return {}, true
        end
        -- Explicit tracking is the sole display whitelist when trackedOnly is on.
        -- Session discovery may collect candidate PvP effects for the manager,
        -- but it must never bypass the user's tracking choice and inject hidden
        -- or system auras into the visible HUD.
        local tracked=S:GetTracked(scope,effectType)
        -- Tracking is a strict display whitelist whenever tracked-only is enabled.
        -- Empty means zero visible effects; it must never silently become "show all".
        -- Hidden remains strict regardless of the Buff/Debuff filter mode.
        local activeTracked = 0
        if type(tracked) == "table" then
            for _, entry in pairs(tracked) do
                if type(entry) == "table" and entry.enabled ~= false then activeTracked = activeTracked + 1 end
            end
        end
        local hasTracked = activeTracked > 0
        st.trackedOnlyFallback = st.trackedOnlyFallback or {}
        st.trackedOnlyFallback[effectType] = false
        st.hiddenWhitelistEmpty = st.hiddenWhitelistEmpty or false
        if effectType == "hidden" then
            st.hiddenWhitelistEmpty = not hasTracked
            if not hasTracked then return {}, true end
        elseif trackedOnly and not hasTracked then
            return {}, true
        end
        local effectiveTrackedOnly = effectType == "hidden" or trackedOnly
        local effects, reliable = A:GetEffects(
            st.unit,
            effectType,
            S:GetEffectLimit(scope, effectType),
            tracked,
            effectiveTrackedOnly
        )
        if reliable == false then
            st.effectReadFailures[effectType] = (tonumber(st.effectReadFailures[effectType]) or 0) + 1
            return nil, false
        end
        st.effectReadFailures[effectType] = 0
        return effects, true
    end

    local function Commit(effectType, enabled)
        local effects, reliable = Read(effectType, enabled)
        st.effectSnapshots = st.effectSnapshots or { buff = {}, debuff = {}, hidden = {} }
        st.effectEmptyStreak = st.effectEmptyStreak or { buff = 0, debuff = 0, hidden = 0 }
        if enabled ~= true then
            st.effectSnapshots[effectType] = {}
            st.effectEmptyStreak[effectType] = 0
            U:UpdateEffects(scope, effectType, {})
            return
        end
        -- Any API read failure or an incomplete tracked row keeps the last
        -- reliable snapshot. This prevents one bad UnitBuff/Tooltip poll from
        -- making the player's icon row disappear.
        if reliable ~= true then return end
        if #effects > 0 then
            st.effectSnapshots[effectType] = effects
            st.effectEmptyStreak[effectType] = 0
            U:UpdateEffects(scope, effectType, effects)
            return
        end
        -- A strict empty Hidden whitelist is an authoritative configuration
        -- change, not a transient API empty sample. Clear it immediately so a
        -- previously visible Hidden icon cannot linger for the normal debounce.
        if effectType == "hidden" and st.hiddenWhitelistEmpty == true then
            st.effectSnapshots.hidden = {}
            st.effectEmptyStreak.hidden = 0
            U:UpdateEffects(scope, "hidden", {})
            return
        end
        local previous = st.effectSnapshots[effectType]
        if type(previous) == "table" and #previous > 0 then
            st.effectEmptyStreak[effectType] = (tonumber(st.effectEmptyStreak[effectType]) or 0) + 1
            -- Require three consecutive reliable empty reads before clearing a
            -- previously visible lane. At current intervals this is only about
            -- 0.3-0.5s, but absorbs short client-side aura list rebuilds.
            if st.effectEmptyStreak[effectType] < 3 then return end
        end
        st.effectSnapshots[effectType] = {}
        st.effectEmptyStreak[effectType] = 0
        U:UpdateEffects(scope, effectType, {})
    end

    Commit("buff", cfg.showBuffs)
    Commit("debuff", cfg.showDebuffs)
    if scope == "player" or scope == "target" then Commit("hidden", cfg.showHidden) end
end

function R:UpdateTargetExtras()
    local st, cfg = self.scopes.target, S:Get().target
    if st == nil or cfg == nil or cfg.enabled ~= true or st.positionValid ~= true or st.identityValid ~= true then U:UpdateTargetMetadata(nil, nil, nil); U:UpdateTargetOfTarget(nil); return end
    local classInfo = cfg.showClass == true and A:GetClassInfo("target") or nil
    local gearScore = cfg.showGear == true and A:GetGearScore("target") or nil
    local loadoutInfo = cfg.showLoadout == true and A:GetTargetCombatLoadout("target") or nil
    local targetOfTarget = cfg.showTargetOfTarget == true and A:GetUnitName("targettarget") or nil
    U:UpdateTargetMetadata(classInfo, gearScore, loadoutInfo)
    U:UpdateTargetOfTarget(targetOfTarget)
end

function R:UpdateEquipment()
    local cfg = S:Get().player
    self.equipmentDirty = false
    if cfg == nil or cfg.enabled ~= true then
        self.equippedItemSkillEntries = {}
        self.cooldownCache = {}
        U:UpdateEquipment({})
        U:UpdateImportantCooldowns({})
        return
    end

    -- Cooldown tracking needs only the equipped glider tooltip and runs on
    -- equipment-change events, never on the 200ms cooldown poll itself.
    local needSnapshot = cfg.showEquipment == true or cfg.showImportantCooldowns == true
    local snapshot = needSnapshot and A:GetEquipmentSnapshot() or {}
    local equippedEntries, seenSkill = {}, {}
    if type(snapshot) == "table" then
        for equipmentKey, item in pairs(snapshot) do
            if type(item) == "table" and type(item.skillIds) == "table" then
                for _, rawId in ipairs(item.skillIds) do
                    local id = tonumber(rawId)
                    if id ~= nil and id > 0 and seenSkill[id] ~= true then
                        seenSkill[id] = true
                        local itemName = tostring(item.name or item.label or equipmentKey or "装备")
                        equippedEntries[#equippedEntries + 1] = {
                            id=id, kind="skill", group=equipmentKey == "glider" and "glider" or "equipment",
                            priority=equipmentKey == "glider" and 1 or 8,
                            label=itemName .. " / 装备技能 " .. tostring(id), dynamic=true,
                        }
                    end
                end
            end
        end
    end
    self.equippedItemSkillEntries = equippedEntries
    U:UpdateEquipment(cfg.showEquipment == true and snapshot or {})
    self.cooldownAccumulator = self.cooldownIntervalMs
end

-- X2Skill's public announcement names only "remain and duration" and older
-- client branches have surfaced cooldown values in different time units. Aura
-- rendering here is millisecond-based, so normalize at the boundary. The
-- database duration is only a unit-disambiguation hint; it never becomes the
-- displayed countdown or replaces live client Authority.
local function NormalizeCooldownMs(entry, remain, duration)
    remain, duration = tonumber(remain), tonumber(duration)
    if remain == nil then return nil, duration end
    local scale = 1000
    local expected = tonumber(entry and entry.expectedSec)
    if duration ~= nil and duration > 0 and expected ~= nil and expected > 0 then
        local secondsDistance = math.abs(duration - expected)
        local millisecondsDistance = math.abs(duration - expected * 1000)
        scale = secondsDistance <= millisecondsDistance and 1000 or 1
    elseif duration ~= nil and duration > 0 then
        -- Current tracked glider/Groa cooldowns are short combat timers. A total
        -- duration above ten minutes in raw units is therefore already ms.
        scale = duration <= 600 and 1000 or 1
    elseif remain > 600 then
        scale = 1
    end
    return math.max(0, remain * scale), duration ~= nil and math.max(0, duration * scale) or nil
end

local function QueryCooldown(entry)
    local skillRemain, skillDuration = A:GetSkillCooldown(entry.id, true)
    skillRemain, skillDuration = NormalizeCooldownMs(entry, skillRemain, skillDuration)
    local remain, duration = skillRemain, skillDuration
    if entry.kind == "mate" then
        local mateRemain, mateDuration = A:GetMateSkillCooldown(entry.id, true)
        mateRemain, mateDuration = NormalizeCooldownMs(entry, mateRemain, mateDuration)
        if mateRemain ~= nil and (remain == nil or mateRemain > remain) then remain = mateRemain end
        if mateDuration ~= nil and (duration == nil or mateDuration > duration) then duration = mateDuration end
    end
    if remain == nil then return 0, duration end
    return remain, duration
end

local function DynamicEquippedEntries(entries)
    local result, seen = {}, {}
    for _, source in ipairs(type(entries) == "table" and entries or {}) do
        local id = tonumber(type(source) == "table" and source.id or nil)
        if id ~= nil and id > 0 and seen[id] ~= true then
            seen[id] = true
            result[#result + 1] = source
        end
    end
    return result, seen
end

function R:UpdateImportantCooldowns()
    local cfg = S:Get().player
    if cfg == nil or cfg.enabled ~= true or cfg.showImportantCooldowns ~= true then
        self.cooldownCache = {}
        U:UpdateImportantCooldowns({})
        return
    end

    local dynamicEntries, dynamicSeen = DynamicEquippedEntries(self.equippedItemSkillEntries)
    local cache = self.cooldownCache

    -- Activation ids discovered from currently equipped items are always
    -- exact-probed. This is the primary path for server-custom wings and other
    -- equipment use-effects that are not yet in the curated static library.
    for _, entry in ipairs(dynamicEntries) do
        local remain, duration = QueryCooldown(entry)
        cache[entry.id] = { remain=remain, duration=duration, entry=entry, active=remain > 40 }
    end

    -- Active library timers remain exact. Inactive ids are round-robin probed
    -- with a fixed budget, so a larger future library cannot turn into a linear
    -- per-frame API scan. At 200ms/6 probes, the current library detects a new CD
    -- in under one second while active countdowns stay live.
    local activeSeen = {}
    -- A swapped-out item may still be cooling down. Keep an already-active
    -- dynamic id exact-probed until it expires; otherwise its last value would
    -- freeze after the equipment tooltip no longer contains that id.
    for id, item in pairs(cache) do
        if item ~= nil and item.active == true and type(item.entry) == "table" and item.entry.dynamic == true and dynamicSeen[id] ~= true then
            local remain, duration = QueryCooldown(item.entry)
            item.remain, item.duration, item.active = remain, duration, remain > 40
            activeSeen[id] = true
        end
    end
    for _, entry in ipairs(IMPORTANT_COOLDOWN_LIBRARY) do
        local item = cache[entry.id]
        if item ~= nil and item.active == true and dynamicSeen[entry.id] ~= true and activeSeen[entry.id] ~= true then
            local remain, duration = QueryCooldown(entry)
            item.remain, item.duration, item.entry, item.active = remain, duration, entry, remain > 40
            activeSeen[entry.id] = true
        end
    end

    local libraryCount = #IMPORTANT_COOLDOWN_LIBRARY
    local budget = math.max(1, math.min(libraryCount, tonumber(self.cooldownProbeBudget) or 6))
    local cursor = math.max(1, math.min(libraryCount, tonumber(self.cooldownProbeCursor) or 1))
    local probed, visited = 0, 0
    while probed < budget and visited < libraryCount and libraryCount > 0 do
        local entry = IMPORTANT_COOLDOWN_LIBRARY[cursor]
        if entry ~= nil and dynamicSeen[entry.id] ~= true and activeSeen[entry.id] ~= true then
            local remain, duration = QueryCooldown(entry)
            cache[entry.id] = { remain=remain, duration=duration, entry=entry, active=remain > 40 }
            probed = probed + 1
        end
        visited = visited + 1
        cursor = cursor + 1
        if cursor > libraryCount then cursor = 1 end
    end
    self.cooldownProbeCursor = cursor

    -- Inactive dynamic records from equipment that has since been removed are
    -- no longer useful. Bound cache growth even if the player swaps many items.
    local staleDynamic = {}
    for id, item in pairs(cache) do
        if item ~= nil and item.active ~= true and type(item.entry) == "table" and item.entry.dynamic == true and dynamicSeen[id] ~= true then
            staleDynamic[#staleDynamic + 1] = id
        end
    end
    for _, id in ipairs(staleDynamic) do cache[id] = nil end

    local cooldowns = {}
    for _, item in pairs(cache) do
        if item.active == true and tonumber(item.remain) ~= nil and item.remain > 40 and type(item.entry) == "table" then
            local info = A:GetSkillInfo(item.entry.id, item.entry.label)
            if type(info) == "table" then
                cooldowns[#cooldowns + 1] = {
                    key = "cooldown:" .. tostring(item.entry.id),
                    id = tostring(item.entry.id),
                    name = tostring(info.name or item.entry.label or item.entry.id),
                    iconPath = info.iconPath,
                    timeLeftMs = item.remain,
                    totalMs = item.duration,
                    stack = 0,
                    priority = tonumber(item.entry.priority) or 999,
                }
            end
        end
    end
    table.sort(cooldowns, function(a,b)
        local ap, bp = tonumber(a.priority) or 999, tonumber(b.priority) or 999
        if ap ~= bp then return ap < bp end
        local ar, br = tonumber(a.timeLeftMs) or 0, tonumber(b.timeLeftMs) or 0
        if ar ~= br then return ar < br end
        return tostring(a.id or "") < tostring(b.id or "")
    end)
    U:UpdateImportantCooldowns(cooldowns)
end

function R:UpdateCasting()
    local scope = "target"
    local st, cfg = self.scopes[scope], S:Get()[scope]
    if cfg.enabled ~= true or cfg.showCast ~= true or st.positionValid ~= true or st.identityValid ~= true then U:UpdateCasting(scope, nil); return end
    local info = A:GetCastingInfo(st.unit)
    if type(info) == "table" and info.iconPath == nil and st.castIconHint ~= nil then info.iconPath = st.castIconHint end
    U:UpdateCasting(scope, info)
end

-- Pure decision for the buff-cap label (report 八-P0-1). Zero side effects so
-- it is unit-testable: count >= threshold shows the warning text.
function R:BuffCapDecision(count, cfg)
    if type(cfg) ~= "table" or cfg.enabled ~= true then return false, nil end
    count = tonumber(count)
    if count == nil then return false, nil end
    local threshold = math.floor(tonumber(cfg.threshold) or 36)
    if count < threshold then return false, nil end
    return true, "BUFF " .. tostring(count) .. " · 已接近上限"
end

function R:UpdateBuffCap()
    local cfg = S:Get().buffcap
    -- Visibility short-circuit: disabled means no API read at all.
    if type(cfg) ~= "table" or cfg.enabled ~= true then
        U:UpdateBuffCapLabel(false, nil, nil)
        return
    end
    local count = A:UnitBuffCount("player")
    local shown, text = self:BuffCapDecision(count, cfg)
    U:UpdateBuffCapLabel(shown, text, cfg)
end

-- Magic-circle distance tracker (report 八-P1-1). Pure step, zero side
-- effects so it is unit-testable.
--   state    = { active = bool, origin = {x,y,z}|nil } (the caller-owned state)
--   isActive = buff presence this tick (bool)
--   nowPos   = current player world position (x,y,z) or nil when the position
--              read transiently failed
--   cfg      = plates storage .magiccircle
-- Returns new state and a view: nil (hidden) or { text="23.4m", tone="normal"|"warn"|"max" }.
-- Semantics:
--   * onset (inactive->active with a usable nowPos) captures origin once; the
--     origin is NEVER re-captured while the same buff stays active.
--   * while active, distance = 3D distance from origin; <warnM normal,
--     >=warnM warn, >=maxM max (invalid warnM/maxM are auto-swapped).
--   * buff gone -> clear origin, view=nil.
--   * nowPos nil while active -> view=nil but origin is KEPT (transient
--     position loss must not reset the circle centre).
function R:MagicCircleStep(state, isActive, nowPos, cfg)
    state = type(state) == "table" and state or { active = false, origin = nil }
    local warnM = tonumber(cfg and cfg.warnM) or 25
    local maxM = tonumber(cfg and cfg.maxM) or 29.9
    if maxM < warnM then warnM, maxM = maxM, warnM end
    if isActive ~= true then
        return { active = false, origin = nil }, nil
    end
    if state.active ~= true then
        -- Onset: capture the circle centre only when a position is readable.
        if nowPos == nil then return { active = true, origin = nil }, nil end
        return { active = true, origin = { x = nowPos.x, y = nowPos.y, z = nowPos.z } }, nil
    end
    if state.origin == nil then
        -- Active but no origin yet (onset position was missing): still no
        -- distance; keep waiting for the first readable position as the centre.
        if nowPos ~= nil then
            return { active = true, origin = { x = nowPos.x, y = nowPos.y, z = nowPos.z } }, nil
        end
        return { active = true, origin = nil }, nil
    end
    if nowPos == nil then
        -- Transient position loss: hide the label but keep the origin.
        return { active = true, origin = state.origin }, nil
    end
    local dx = nowPos.x - state.origin.x
    local dy = nowPos.y - state.origin.y
    local dz = nowPos.z - state.origin.z
    local distance = math.sqrt((dx * dx) + (dy * dy) + (dz * dz))
    local tone = "normal"
    if distance >= maxM then tone = "max"
    elseif distance >= warnM then tone = "warn" end
    return { active = true, origin = state.origin },
        { text = string.format("%.1fm", distance), tone = tone }
end

-- Magic-circle lane. Visibility short-circuit mirrors UpdateBuffCap: disabled
-- means zero API reads. Order matters: buff scan first, and only on a hit do we
-- read the player world position (no position read when the buff is absent).
function R:UpdateMagicCircle()
    local cfg = S:Get().magiccircle
    if type(cfg) ~= "table" or cfg.enabled ~= true then
        U:UpdateMagicCircleView(nil, nil, nil)
        return
    end
    local buffId, info = A:FindPlayerBuff(type(cfg.buffIds) == "table" and cfg.buffIds or {})
    local nextState = self.magicCircleState
    if type(nextState) ~= "table" then nextState = { active = false, origin = nil } end
    if buffId == nil then
        -- Buff gone: run the pure step so the state machine clears properly
        -- (keeps onset detection working for the next cast).
        local newState, view = self:MagicCircleStep(nextState, false, nil, cfg)
        self.magicCircleState = newState
        U:UpdateMagicCircleView(view, nil, nil)
        return
    end
    local x, y, z = A:UnitWorldPosition("player")
    local nowPos = (x ~= nil and y ~= nil and z ~= nil) and { x = x, y = y, z = z } or nil
    local newState, view = self:MagicCircleStep(nextState, true, nowPos, cfg)
    self.magicCircleState = newState
    U:UpdateMagicCircleView(view, cfg, info)
end

-- watchtarget aggro/distance windows (report 七-C). Visibility gate: the
-- windows render only when the corresponding storage switch is on AND the
-- Suite HudManager made the window visible (watchVisible). Data comes from the
-- shared TargetService watchAggro/watchDist fields when subscribed (rp_api
-- falls back to direct reads otherwise). Unreadable -> "--" (fail-closed).
function R:UpdateWatchWindows()
    local cfg = S:Get().watchtarget
    if type(cfg) ~= "table" then return end
    local aggroOn = cfg.aggroEnabled == true
    local distOn = cfg.distEnabled == true
    if aggroOn ~= U.watchVisible.aggro then U:SetWatchWindowVisible("aggro", aggroOn) end
    if distOn ~= U.watchVisible.dist then U:SetWatchWindowVisible("dist", distOn) end
    if not aggroOn and not distOn then return end

    -- Subscribe the shared TargetService lanes only while a watch window is
    -- actually wanted (demand-driven; no subscriber -> the service does zero
    -- reads). rp_api still falls back to direct reads, so a missing service is
    -- never a hard failure.
    if ReplicatedSuite ~= nil and ReplicatedSuite.TargetService ~= nil
        and type(ReplicatedSuite.TargetService.Subscribe) == "function" then
        local fields = {}
        if aggroOn then fields[#fields + 1] = "watchAggro" end
        if distOn then fields[#fields + 1] = "watchDist" end
        if #fields > 0 then ReplicatedSuite.TargetService:Subscribe("plates_watchtarget", fields) end
    end

    local aggroName, distance = nil, nil
    if aggroOn then aggroName = A:GetWatchTargetName() end
    if distOn then distance = A:GetWatchTargetDistance() end
    U:RefreshWatchWindows(aggroName, distance, cfg.orangeAt, cfg.redAt)
end

-- Pure alert matcher (report 七-方案A). Zero side effects so it is unit
-- testable. Inputs:
--   casts   list of { name=string, remainingMs=number|nil } (current casts)
--   debuffs list of { id=number|string } (active debuff ids)
--   data    S.Data.BossAlerts list (each { key, kind, names={...}, debuffId,
--           alert, style })
--   cfg     plates storage .alerts ({ enabled, items={[key]=bool},
--           custom={[debuffId]=text} })
-- Returns a list of alerts to push: { key, text, style, remainingMs }.
-- Matching: cast by multilingual name (string.find plain on names), debuff by
-- numeric id; custom debuff alerts (cfg.custom) are appended. items[key] ==
-- false disables a built-in alert (missing -> enabled).
function R:AlertMatch(casts, debuffs, data, cfg)
    local result = {}
    if type(cfg) ~= "table" or cfg.enabled ~= true then return result end
    local items = type(cfg.items) == "table" and cfg.items or {}
    local dataList = type(data) == "table" and data or {}
    local castsList = type(casts) == "table" and casts or {}
    local debuffsList = type(debuffs) == "table" and debuffs or {}

    local function PushAlert(key, text, style, remainingMs)
        if items[key] == false then return end
        result[#result + 1] = {
            key = key,
            text = tostring(text or ""),
            style = style == "countdown" and "countdown" or "bigtext",
            remainingMs = math.max(0, tonumber(remainingMs) or 0),
        }
    end

    -- Cast matches: iterate casts and built-in cast entries.
    for _, entry in ipairs(dataList) do
        if entry.kind == "cast" and type(entry.names) == "table" then
            for _, cast in ipairs(castsList) do
                local castName = tostring(cast.name or "")
                if castName ~= "" then
                    for _, alias in ipairs(entry.names) do
                        if string.find(castName, tostring(alias), 1, true) ~= nil then
                            PushAlert(entry.key, entry.alert, entry.style, cast.remainingMs)
                            break
                        end
                    end
                end
            end
        elseif entry.kind == "debuff" and tonumber(entry.debuffId) ~= nil then
            local wanted = tostring(math.floor(tonumber(entry.debuffId)))
            for _, debuff in ipairs(debuffsList) do
                if tostring(debuff.id) == wanted then
                    PushAlert(entry.key, entry.alert, entry.style, nil)
                    break
                end
            end
        end
    end

    -- Custom debuff alerts: cfg.custom = { [debuffId]=text }.
    local custom = type(cfg.custom) == "table" and cfg.custom or {}
    for id, text in pairs(custom) do
        local wanted = tostring(tonumber(id) or id)
        for _, debuff in ipairs(debuffsList) do
            if tostring(debuff.id) == wanted then
                result[#result + 1] = {
                    key = "custom:" .. wanted,
                    text = tostring(text),
                    style = "bigtext",
                    remainingMs = 0,
                }
                break
            end
        end
    end
    return result
end

-- Alert lane. Visibility short-circuit mirrors UpdateMagicCircle: disabled
-- means zero API reads. Reads casts for the configured scopes (target/player)
-- and the debuff id list, then pushes matches through the shared Alerts
-- channel. Push-side dedupe (same text re-arms) keeps this cheap.
function R:UpdateAlerts()
    local cfg = S:Get().alerts
    if type(cfg) ~= "table" or cfg.enabled ~= true then
        if ReplicatedSuite ~= nil and ReplicatedSuite.Services ~= nil
            and ReplicatedSuite.Services.Alerts ~= nil
            and type(ReplicatedSuite.Services.Alerts.Hide) == "function" then
            ReplicatedSuite.Services.Alerts:Hide()
        end
        return
    end
    local data = ReplicatedSuite ~= nil and ReplicatedSuite.Data and ReplicatedSuite.Data.BossAlerts or nil
    local scope = tostring(cfg.scope or "target+player")
    local casts = {}
    local units = {}
    if scope == "target" or scope == "target+player" then units[#units + 1] = "target" end
    if scope == "player" or scope == "target+player" then units[#units + 1] = "player" end
    for _, unit in ipairs(units) do
        local info = A:GetCastingInfo(unit)
        if type(info) == "table" and info.name ~= nil then
            casts[#casts + 1] = {
                name = info.name,
                remainingMs = (tonumber(info.totalMs) or 0) - (tonumber(info.currentMs) or 0),
            }
        end
    end
    -- Debuff ids for the same scopes (id-only scan, no tooltip decode).
    local debuffs = {}
    for _, unit in ipairs(units) do
        local list = A:GetEffectIds(unit, "debuff")
        if type(list) == "table" then
            for _, id in ipairs(list) do debuffs[#debuffs + 1] = { id = id } end
        end
    end
    local matches = self:AlertMatch(casts, debuffs, data, cfg)
    local alerts = ReplicatedSuite ~= nil and ReplicatedSuite.Services
        and ReplicatedSuite.Services.Alerts or nil
    if alerts == nil or type(alerts.Push) ~= "function" then return end
    for _, match in ipairs(matches) do
        local payload = { text = match.text, style = match.style, remainingMs = match.remainingMs }
        if match.style == "countdown" then payload.durationMs = 6000 else payload.durationMs = 3000 end
        alerts:Push(payload)
    end
end

-- F3: simulate a boss alert through the REAL pipeline (AlertMatch -> Push ->
-- countdown/bigtext render -> expire). This is NOT the shortcut preview path:
-- it injects a mock cast row and lets AlertMatch + UpdateAlerts' push logic run
-- unchanged, so the user can test the full pipeline (position/size/style)
-- without fighting a boss. The text is prefixed with "[模拟]" to distinguish it
-- from real alerts. key selects which built-in cast alert to fake (defaults to
-- the first cast entry); returns the number of pushed alerts.
function R:SimulateAlert(key)
    local data = ReplicatedSuite ~= nil and ReplicatedSuite.Data and ReplicatedSuite.Data.BossAlerts or nil
    if type(data) ~= "table" or #data == 0 then return 0 end
    local entry = nil
    for _, candidate in ipairs(data) do
        if candidate.kind == "cast" then
            if key == nil or tostring(candidate.key) == tostring(key) then
                entry = candidate
                break
            end
        end
    end
    if entry == nil then
        -- fall back to the first cast entry when key matched nothing
        for _, candidate in ipairs(data) do
            if candidate.kind == "cast" then entry = candidate; break end
        end
    end
    if entry == nil or type(entry.names) ~= "table" or entry.names[1] == nil then return 0 end

    local cfg = S:Get().alerts
    if type(cfg) ~= "table" or cfg.enabled ~= true then
        P.SafeChat("模拟警报：请先开启“战斗警报”总开关")
        return 0
    end
    local mockCast = { name = tostring(entry.names[1]), remainingMs = 5000 }
    local matches = self:AlertMatch({ mockCast }, {}, data, cfg)
    local alerts = ReplicatedSuite ~= nil and ReplicatedSuite.Services
        and ReplicatedSuite.Services.Alerts or nil
    if alerts == nil or type(alerts.Push) ~= "function" then return 0 end
    local pushed = 0
    for _, match in ipairs(matches) do
        local payload = {
            text = "[模拟] " .. tostring(match.text),
            style = match.style,
            remainingMs = 5000,
        }
        if match.style == "countdown" then payload.durationMs = 6000 else payload.durationMs = 3000 end
        alerts:Push(payload)
        pushed = pushed + 1
    end
    if pushed == 0 then P.SafeChat("模拟警报：该警报被开关禁用或未匹配") end
    return pushed
end

-- Pure dot interpolation (report 七-方案B). Zero side effects so it is unit
-- testable. Returns a list of screen-space points from start to end (inclusive
-- of both endpoints) whose count is derived from the screen distance and clamped
-- to [minDots, maxDots]. Equal or unreadable coordinates produce a single point.
function R:LinesInterpolate(x1, y1, x2, y2, minDots, maxDots)
    x1, y1, x2, y2 = tonumber(x1), tonumber(y1), tonumber(x2), tonumber(y2)
    if x1 == nil or y1 == nil or x2 == nil or y2 == nil then return {} end
    minDots = math.max(1, math.floor(tonumber(minDots) or 8))
    maxDots = math.max(minDots, math.floor(tonumber(maxDots) or 64))
    local dx, dy = x2 - x1, y2 - y1
    local distance = math.sqrt((dx * dx) + (dy * dy))
    local count = math.max(minDots, math.min(maxDots, math.floor(distance / 6 + 0.5)))
    local points = {}
    for i = 1, count do
        local t = (count <= 1) and 0 or ((i - 1) / (count - 1))
        points[#points + 1] = { x = x1 + dx * t, y = y1 + dy * t }
    end
    return points
end

-- Connection-lines lane (report 七-方案B). <=100ms cadence; disabled or no
-- enabled pair short-circuits to zero API reads. Each enabled pair reads both
-- endpoints via A:UnitScreenPoint (native + projection fallback), interpolates
-- dots, and hands them to the UI pool renderer. watchtarget pairs are OFF by
-- default (they depend on the C lane's token availability).
local LINE_PAIRS = {
    { key = "target",          from = "player",          to = "target",          playerStart = "targetFromPlayer" },
    { key = "targetoftarget",  from = "target",          to = "targettarget",    playerStart = nil },
    { key = "watchtarget",     from = "player",          to = "watchtarget",     playerStart = "watchFromPlayer" },
    { key = "watchtargettarget", from = "watchtarget",   to = "watchtargettarget", playerStart = nil },
}
function R:UpdateLines()
    local cfg = S:Get().lines
    if type(cfg) ~= "table" or cfg.enabled ~= true then
        U:UpdateLinesView(nil, nil)
        return
    end
    local pairs = type(cfg.pairs) == "table" and cfg.pairs or {}
    local lines = {}
    for _, pair in ipairs(LINE_PAIRS) do
        if pairs[pair.key] == true then
            local fromUnit, toUnit = pair.to, pair.from
            local playerStartKey = pair.playerStart
            if playerStartKey ~= nil and cfg[playerStartKey] == true then
                fromUnit, toUnit = pair.from, pair.to
            end
            local ax, ay, az = A:UnitScreenPoint(fromUnit)
            local bx, by, bz = A:UnitScreenPoint(toUnit)
            local points = self:LinesInterpolate(ax, ay, bx, by, cfg.minDots, cfg.maxDots)
            if #points > 0 then
                lines[#lines + 1] = { key = pair.key, points = points }
            end
        end
    end
    U:UpdateLinesView(lines, cfg)
end

-- F5: player-centred distance circle. Pure world-space circle generation:
-- horizontal circle in the x/y plane (world "ground"), z is height; each point
-- sits at (cx+cosθ·R, cy+sinθ·R, pz+zOffset). Zero side effects, unit-testable.
-- Returns { {x,y,z}, ... } with exactly `dots` points.
function R:CirclePoints(cx, cy, pz, radiusM, dots, zOffset)
    cx, cy, pz, radiusM = tonumber(cx), tonumber(cy), tonumber(pz), tonumber(radiusM)
    if cx == nil or cy == nil or pz == nil or radiusM == nil then return {} end
    dots = math.max(4, math.floor(tonumber(dots) or 48))
    zOffset = tonumber(zOffset) or 0.8
    local points = {}
    for i = 1, dots do
        local angle = ((i - 1) / dots) * math.pi * 2
        points[#points + 1] = {
            x = cx + math.cos(angle) * radiusM,
            y = cy + math.sin(angle) * radiusM,
            z = pz + zOffset,
        }
    end
    return points
end

-- F5: project world-space circle points to screen, culling camera-behind dots.
-- Uses the shared A:ProjectWorldToScreen dual-fallback (ConvertWorldToScreen ->
-- WorldToScreen, G1). The THIRD return value is depth: only depth ~= nil and
-- depth > 0 counts as visible (mirrors easypull :686). Returns { {x,y}, ... }.
function R:ProjectCirclePoints(points)
    local visible = {}
    if type(A.ProjectWorldToScreen) ~= "function" then return visible end
    for _, pt in ipairs(type(points) == "table" and points or {}) do
        local sx, sy, depth = A:ProjectWorldToScreen(pt.x, pt.y, pt.z)
        local d = tonumber(depth)
        if sx ~= nil and sy ~= nil and d ~= nil and d > 0 then
            visible[#visible + 1] = { x = sx, y = sy }
        end
    end
    return visible
end

-- F5: distance-circle lane. 100ms cadence; disabled -> zero API reads. Reads
-- the player position in the ConvertWorldToScreen coordinate space
-- (isLocal=true, verified easypull pipeline; G1), generates the horizontal
-- circle, projects it with depth culling, and hands the visible screen points
-- to the UI circle pool.
-- One-shot diagnostics: when enabled and readable but projection yields zero
-- visible points for N consecutive ticks (~2s), chat once (reset on re-enable
-- or reload); a missing projection function gets the same one-shot note.
function R:UpdateCircle()
    local cfg = S:Get().lines
    if type(cfg) ~= "table" or type(cfg.circle) ~= "table" or cfg.circle.enabled ~= true then
        -- re-armed on disable/re-enable so the next broken session reports again
        self.circleZeroStreak = 0
        self.circleZeroWarned = nil
        self.circleNoProjectorWarned = nil
        U:UpdateCircleView(nil, nil)
        return
    end
    -- Projection availability: native ConvertWorldToScreen OR the camera-based
    -- manual projection (UIParent camera getters, absorbed WorldToScreen.lua).
    local noProjector = type(ConvertWorldToScreen) ~= "function"
        and (UIParent == nil or type(UIParent.GetViewCameraPos) ~= "function"
            or type(UIParent.GetViewCameraDir) ~= "function")
    if noProjector then
        if self.circleNoProjectorWarned ~= true then
            self.circleNoProjectorWarned = true
            if P.SafeChat ~= nil then P.SafeChat("[距离圆] 投影不可用：ConvertWorldToScreen 缺失且无相机投影支持") end
        end
        U:UpdateCircleView(nil, nil)
        return
    end
    local px, py, pz = A:UnitWorldPosition("player", true) -- easypull-verified space
    if px == nil or py == nil or pz == nil then
        U:UpdateCircleView(nil, nil)
        return
    end
    local world = self:CirclePoints(px, py, pz, cfg.circle.radiusM, cfg.circle.dots, cfg.circle.zOffset)
    local screen = self:ProjectCirclePoints(world)
    U:UpdateCircleView(screen, cfg)
    if #screen == 0 then
        self.circleZeroStreak = (tonumber(self.circleZeroStreak) or 0) + 1
        if self.circleZeroStreak >= 20 and self.circleZeroWarned ~= true then
            self.circleZeroWarned = true
            if P.SafeChat ~= nil then P.SafeChat("[距离圆] 投影无可见点：坐标空间或投影 API 异常") end
        end
    else
        self.circleZeroStreak = 0
    end
end

function R:OnUpdate(dt)
    if P.Generation ~= runtimeGeneration or self.running ~= true then return end
    self.heartbeatSerial = (tonumber(self.heartbeatSerial) or 0) + 1
    for _, scope in ipairs(SCOPE_ORDER) do self.scopeFailed[scope] = false end

    local delta = DeltaMs(dt)
    self.positionAccumulator = self.positionAccumulator + delta
    self.healthAccumulator = self.healthAccumulator + delta
    self.metadataAccumulator = self.metadataAccumulator + delta
    self.targetMetaAccumulator = self.targetMetaAccumulator + delta
    self.distanceAccumulator = self.distanceAccumulator + delta
    self.castAccumulator = self.castAccumulator + delta
    self.cooldownAccumulator = self.cooldownAccumulator + delta
    self.managerAccumulator = self.managerAccumulator + delta
    self.discoveryAccumulator = self.discoveryAccumulator + delta
    self.captureAccumulator = self.captureAccumulator + delta
    self.buffcapAccumulator = self.buffcapAccumulator + delta
    self.magicCircleAccumulator = self.magicCircleAccumulator + delta
    self.watchAccumulator = self.watchAccumulator + delta
    self.alertsAccumulator = self.alertsAccumulator + delta
    self.linesAccumulator = self.linesAccumulator + delta
    self.circleAccumulator = self.circleAccumulator + delta
    for _, scope in ipairs(SCOPE_ORDER) do self.scopes[scope].effectsAccumulator = self.scopes[scope].effectsAccumulator + delta end

    local due = self.forceGlobal or self.positionAccumulator >= self.positionIntervalMs
    if due and self:TryBudgetLane("position", self.positionAccumulator, self.positionIntervalMs) then
        self.positionAccumulator = 0
        for _, scope in ipairs(SCOPE_ORDER) do self:SafeLane("position:" .. scope, scope, R.UpdatePosition, scope) end
    end

    due = self.forceGlobal or self.metadataAccumulator >= self.metadataIntervalMs
    if due and self:TryBudgetLane("metadata", self.metadataAccumulator, self.metadataIntervalMs) then
        self.metadataAccumulator = 0
        for _, scope in ipairs(SCOPE_ORDER) do self:SafeLane("metadata:" .. scope, scope, R.UpdateMetadata, scope) end
    end

    due = self.forceGlobal or self.targetMetaAccumulator >= self.targetMetaIntervalMs
    if due and self:TryBudgetLane("target_extras", self.targetMetaAccumulator, self.targetMetaIntervalMs) then
        self.targetMetaAccumulator = 0
        self:SafeLane("target_extras", "target", R.UpdateTargetExtras)
    end

    if (self.forceGlobal or self.equipmentDirty == true) and self:TryBudgetLane("equipment", self.forceGlobal and 999999 or 1, 1) then
        self:SafeLane("equipment", "player", R.UpdateEquipment)
    end

    due = self.forceGlobal or self.cooldownAccumulator >= self.cooldownIntervalMs
    if due and self:TryBudgetLane("important_cooldowns", self.cooldownAccumulator, self.cooldownIntervalMs) then
        self.cooldownAccumulator = 0
        self:SafeLane("important_cooldowns", "player", R.UpdateImportantCooldowns)
    end

    due = self.forceGlobal or self.healthAccumulator >= self.healthIntervalMs
    if due and self:TryBudgetLane("health", self.healthAccumulator, self.healthIntervalMs) then
        self.healthAccumulator = 0
        for _, scope in ipairs(SCOPE_ORDER) do self:SafeLane("health:" .. scope, scope, R.UpdateHealth, scope) end
    end

    due = self.forceGlobal or self.distanceAccumulator >= self.distanceIntervalMs
    if due and self:TryBudgetLane("distance", self.distanceAccumulator, self.distanceIntervalMs) then
        self.distanceAccumulator = 0
        self:SafeLane("distance:target", "target", R.UpdateDistance, "target")
    end

    for _, scope in ipairs(SCOPE_ORDER) do
        local st = self.scopes[scope]
        due = self.forceGlobal or st.force or st.effectsAccumulator >= EFFECT_INTERVAL[scope]
        if due and self:TryBudgetLane("effects:" .. scope, st.effectsAccumulator, EFFECT_INTERVAL[scope]) then
            st.effectsAccumulator = 0
            self:SafeLane("effects:" .. scope, scope, R.UpdateEffects, scope)
        end
    end

    due = self.forceGlobal or self.castAccumulator >= self.castIntervalMs
    if due and self:TryBudgetLane("casting", self.castAccumulator, self.castIntervalMs) then
        self.castAccumulator = 0
        self:SafeLane("casting", "target", R.UpdateCasting)
    end

    if self.captureAccumulator >= self.captureIntervalMs
        and self:TryBudgetLane("capture", self.captureAccumulator, self.captureIntervalMs) then
        self.captureAccumulator = 0
        if P.Manager ~= nil and type(P.Manager.CaptureFast) == "function" and P.Manager:IsCaptureEnabled() then
            local captureOk, captureErr = pcall(P.Manager.CaptureFast, P.Manager)
            if captureOk then self.laneErrors.capture = nil
            else
                local text = tostring(captureErr or "unknown")
                if self.laneErrors.capture ~= text then self.laneErrors.capture = text end
            end
        end
    end

    due = self.forceGlobal or self.buffcapAccumulator >= self.buffcapIntervalMs
    if due and self:TryBudgetLane("buffcap", self.buffcapAccumulator, self.buffcapIntervalMs) then
        self.buffcapAccumulator = 0
        self:SafeLane("buffcap", nil, R.UpdateBuffCap)
    end

    due = self.forceGlobal or self.magicCircleAccumulator >= self.magicCircleIntervalMs
    if due and self:TryBudgetLane("magiccircle", self.magicCircleAccumulator, self.magicCircleIntervalMs) then
        self.magicCircleAccumulator = 0
        self:SafeLane("magiccircle", nil, R.UpdateMagicCircle)
    end

    due = self.forceGlobal or self.watchAccumulator >= self.watchIntervalMs
    if due and self:TryBudgetLane("watchtarget", self.watchAccumulator, self.watchIntervalMs) then
        self.watchAccumulator = 0
        self:SafeLane("watchtarget", nil, R.UpdateWatchWindows)
    end

    due = self.forceGlobal or self.alertsAccumulator >= self.alertsIntervalMs
    if due and self:TryBudgetLane("alerts", self.alertsAccumulator, self.alertsIntervalMs) then
        self.alertsAccumulator = 0
        self:SafeLane("alerts", nil, R.UpdateAlerts)
    end

    local linesCfg = S:Get().lines
    local linesMs = math.max(50, math.min(500, math.floor(tonumber(linesCfg and linesCfg.updateMs) or 100)))
    due = self.forceGlobal or self.linesAccumulator >= linesMs
    if due and self:TryBudgetLane("lines", self.linesAccumulator, linesMs) then
        self.linesAccumulator = 0
        self:SafeLane("lines", nil, R.UpdateLines)
    end

    due = self.forceGlobal or self.circleAccumulator >= self.circleIntervalMs
    if due and self:TryBudgetLane("circle", self.circleAccumulator, self.circleIntervalMs) then
        self.circleAccumulator = 0
        self:SafeLane("circle", nil, R.UpdateCircle)
    end

    if self.discoveryAccumulator >= self.discoveryIntervalMs
        and self:TryBudgetLane("discovery", self.discoveryAccumulator, self.discoveryIntervalMs) then
        self.discoveryAccumulator = 0
        if P.Manager ~= nil and type(P.Manager.ObserveCombat) == "function" then
            local discoveryOk, discoveryErr = pcall(P.Manager.ObserveCombat, P.Manager)
            if discoveryOk then self.laneErrors.discovery = nil
            else
                local text = tostring(discoveryErr or "unknown")
                if self.laneErrors.discovery ~= text then self.laneErrors.discovery = text end
            end
        end
    end

    if self.managerAccumulator >= self.managerIntervalMs
        and self:TryBudgetLane("manager", self.managerAccumulator, self.managerIntervalMs) then
        self.managerAccumulator = 0
        if P.Manager ~= nil and type(P.Manager.RuntimeRefresh) == "function" then
            local managerOk, managerErr = pcall(P.Manager.RuntimeRefresh, P.Manager)
            if managerOk then self.laneErrors.manager = nil
            else
                local text = tostring(managerErr or "unknown")
                if self.laneErrors.manager ~= text then self.laneErrors.manager = text end
            end
        end
    end

    for _, scope in ipairs(SCOPE_ORDER) do
        self.scopes[scope].force = self.scopeFailed[scope] == true
    end
    self.forceGlobal = false

    local any = false
    for _, scope in ipairs(SCOPE_ORDER) do
        local st = self.scopes[scope]
        if st.positionValid == true and st.identityValid == true then any = true; break end
    end
    if any ~= self.lastAnyVisible then
        self.lastAnyVisible = any
        U:SetRuntimeStatus(any and "目标 / 自己 HUD Runtime 运行中" or "等待可见单位", any and "ok" or "idle")
    end
end

function R:OnEvent(event, ...)
    if P.Generation ~= runtimeGeneration or self.running ~= true then return end
    if event == "BUFF_UPDATE" or event == "DEBUFF_UPDATE" then
        if P.Manager ~= nil and type(P.Manager.CaptureEvent) == "function" and P.Manager:IsCaptureEnabled() then
            local hint = event == "DEBUFF_UPDATE" and "debuff" or "buff"
            pcall(P.Manager.CaptureEvent, P.Manager, hint)
        end
        return
    end
    if event == "TARGET_CHANGED" then self:ResetScope("target"); self:ForceScope("target"); return end
    if event == "UNIT_EQUIPMENT_CHANGED" then
        self.equipmentDirty = true
        self.cooldownAccumulator = self.cooldownIntervalMs
        return
    end
    if event == "SPELLCAST_START" then
        local _, _, caster = ...
        if caster == "target" then self.scopes.target.castIconHint = CandidateIconFromSpellEvent({ ... }); self.castAccumulator = self.castIntervalMs end
        return
    end
    if event == "SPELLCAST_STOP" or event == "SPELLCAST_SUCCEEDED" then
        local caster = ...
        if caster == "target" then self.scopes.target.castIconHint = nil; self.castAccumulator = self.castIntervalMs; U:UpdateCasting("target", nil) end
    end
end

local lastRuntimeError = nil
local runtimeFailureCount = 0
local RuntimeEventHandler = nil
local RuntimeUpdateHandler = nil
local WatchdogUpdateHandler = nil
local watchdogElapsed = 0
local watchdogObservedHeartbeat = tonumber(R.heartbeatSerial) or 0

local function ReleaseWidgetHandler(widget, handlerName)
    local shared = rawget(_G, "ReplicatedSuiteShared")
    local native = shared and shared.NativeSafe or nil
    if native ~= nil and type(native.ReleaseHandler) == "function" then return native.ReleaseHandler(widget, handlerName) end
    if widget == nil or type(widget.ReleaseHandler) ~= "function" then return end
    if type(widget.HasHandler) == "function" then
        local ok, has = pcall(widget.HasHandler, widget, handlerName)
        if ok and has ~= true then return end
    end
    pcall(widget.ReleaseHandler, widget, handlerName)
end

local function ReleaseRuntimeHandlers()
    -- Hidden native windows are not enough for Module Disabled semantics: an
    -- event registration can still dispatch into Lua, and an inactive handler
    -- still leaves avoidable callback/lifetime surface. Release both callback
    -- lanes; StartModule installs them again without recreating Domain state.
    ReleaseWidgetHandler(R.driver, "OnEvent")
    ReleaseWidgetHandler(R.driver, "OnUpdate")
    ReleaseWidgetHandler(R.watchdog, "OnUpdate")
end

local function BindWidgetHandler(widget, handlerName, handler)
    local shared = rawget(_G, "ReplicatedSuiteShared")
    local native = shared and shared.NativeSafe or nil
    if native ~= nil and type(native.BindHandler) == "function" then return native.BindHandler(widget, handlerName, handler) end
    if widget == nil or type(widget.SetHandler) ~= "function" then
        return false, tostring(handlerName) .. " host unavailable"
    end
    local ok, result = pcall(widget.SetHandler, widget, handlerName, handler)
    if not ok then return false, tostring(result or "unknown") end
    if result == false then return false, tostring(handlerName) .. " SetHandler returned false" end
    return true
end

local function InstallRuntimeHandlers()
    if R.driver ~= nil and type(R.driver.SetHandler) == "function" then
        ReleaseWidgetHandler(R.driver, "OnEvent")
        ReleaseWidgetHandler(R.driver, "OnUpdate")
        local eventOk, eventErr = BindWidgetHandler(R.driver, "OnEvent", RuntimeEventHandler)
        if not eventOk then ReleaseRuntimeHandlers(); return false, eventErr end
        local updateOk, updateErr = BindWidgetHandler(R.driver, "OnUpdate", RuntimeUpdateHandler)
        if not updateOk then ReleaseRuntimeHandlers(); return false, updateErr end
    else
        return false, "runtime driver unavailable"
    end
    if R.watchdog ~= nil and type(R.watchdog.SetHandler) == "function" then
        ReleaseWidgetHandler(R.watchdog, "OnUpdate")
        local watchdogOk, watchdogErr = BindWidgetHandler(R.watchdog, "OnUpdate", WatchdogUpdateHandler)
        if not watchdogOk then ReleaseRuntimeHandlers(); return false, watchdogErr end
    else
        return false, "runtime watchdog unavailable"
    end
    return true
end

function R:Stop(reason)
    -- UI2 uses a short delayed save for continuous colour/style edits. Plates
    -- owns its own sharded SaveData Authority, so Suite Storage cannot flush
    -- that dirty state for us. Commit it at the Runtime boundary before native
    -- handlers are released. Factory reset explicitly fences old-generation
    -- writes so cleared data can never be resurrected.
    if rawget(_G, "ReplicatedSuiteFactoryResetPending") ~= true
        and P.Storage ~= nil and P.Storage.dirty == true
        and type(P.Storage.Save) == "function" then
        local ok, saved, saveErr = pcall(P.Storage.Save, P.Storage, true)
        if (not ok or saved ~= true) and tostring(reason or "") ~= "shutdown" then
            P.SafeChat("BUFF显示设置收尾保存失败：" .. tostring(ok and saveErr or saved or "unknown"))
        end
    end
    runtimeFailureCount = 0
    lastRuntimeError = nil
    self.running = false
    ReleaseRuntimeHandlers()
    if self.driver ~= nil then pcall(function() self.driver:Show(false) end) end
    if self.watchdog ~= nil then pcall(function() self.watchdog:Show(false) end) end
    if U ~= nil and type(U.HideRuntimeHud) == "function" then pcall(function() U:HideRuntimeHud() end) end
    -- Stop the shared alert channel with the module (hides any active alert).
    if ReplicatedSuite ~= nil and ReplicatedSuite.Services ~= nil
        and ReplicatedSuite.Services.Alerts ~= nil
        and type(ReplicatedSuite.Services.Alerts.Stop) == "function" then
        pcall(ReplicatedSuite.Services.Alerts.Stop, ReplicatedSuite.Services.Alerts)
    end
    return true
end

RuntimeUpdateHandler = function(_, dt)
    if P.Generation ~= runtimeGeneration then return end
    local heartbeatBefore = tonumber(R.heartbeatSerial) or 0
    local token = SuitePerformance and SuitePerformance:Begin("onupdate:plates_runtime", "plates") or nil
    local pass, err = pcall(R.OnUpdate, R, dt)
    if SuitePerformance ~= nil then SuitePerformance:End(token) end
    local heartbeatAfter = tonumber(R.heartbeatSerial) or 0
    if pass and heartbeatAfter > heartbeatBefore then
        -- Count only a real Runtime pass. R:OnUpdate intentionally returns
        -- early while stopped, so a successful pcall alone is not liveness.
        R.successfulUpdateSerial = (tonumber(R.successfulUpdateSerial) or 0) + 1
        if lastRuntimeError ~= nil then
            local any = R.lastAnyVisible == true
            U:SetRuntimeStatus(any and "目标 / 自己 HUD Runtime 运行中" or "等待可见单位", any and "ok" or "idle")
        end
        lastRuntimeError = nil
        runtimeFailureCount = 0
        if R.watchdogRecoveryPending == true then
            R.watchdogRecoveryPending = false
            R.watchdogRecoverySuccesses = (tonumber(R.watchdogRecoverySuccesses) or 0) + 1
            R.laneErrors.watchdog = nil
            if SuiteDiagnostics ~= nil and type(SuiteDiagnostics.Info) == "function" then
                pcall(SuiteDiagnostics.Info, SuiteDiagnostics, "plates", "WATCHDOG_RECOVERY_OK", "Plates Runtime 已在正常帧恢复", { heartbeat=heartbeatAfter })
            end
        end
        return
    elseif pass then
        return
    end
    local text = tostring(err or "unknown")
    runtimeFailureCount = runtimeFailureCount + 1
    U:SetRuntimeStatus("主刷新异常，正在隔离确认", "warn")
    if text ~= lastRuntimeError then lastRuntimeError = text end
    if ReplicatedSuiteEmbedded == true and runtimeFailureCount >= 3
        and ReplicatedSuite ~= nil and ReplicatedSuite.ModuleManager ~= nil
        and type(ReplicatedSuite.ModuleManager.ReportRuntimeFault) == "function" then
        ReplicatedSuite.ModuleManager:ReportRuntimeFault("plates", "OnUpdate", text)
    end
end

RuntimeEventHandler = function(_, event, ...)
    if P.Generation ~= runtimeGeneration or R.running ~= true then return end
    local label = event == "BUFF_UPDATE" and "event:plates_buff" or (event == "DEBUFF_UPDATE" and "event:plates_debuff" or "event:plates")
    local token = SuitePerformance and SuitePerformance:Begin(label, "plates") or nil
    local args = { ... }
    local argCount = select("#", ...)
    local pass, err = xpcall(function() R:OnEvent(event, unpack(args, 1, argCount)) end, P.SafeTraceback)
    if SuitePerformance ~= nil then SuitePerformance:End(token) end
    if not pass then R.lastEventError = tostring(err or "unknown") end
end

local ok, driverOrErr = xpcall(function()
    local driver = CreateEmptyWindow(P.PhysicalId("runtime_driver"), "UIParent")
    driver:SetExtent(1, 1); driver:AddAnchor("TOPLEFT", "UIParent", 0, 0)
    if driver.EnablePick ~= nil then driver:EnablePick(false, true) end
    if driver.Clickable ~= nil then driver:Clickable(false, true) end
    driver:RegisterEvent("TARGET_CHANGED")
    driver:RegisterEvent("BUFF_UPDATE")
    driver:RegisterEvent("DEBUFF_UPDATE")
    driver:RegisterEvent("UNIT_EQUIPMENT_CHANGED")
    driver:RegisterEvent("SPELLCAST_START")
    driver:RegisterEvent("SPELLCAST_STOP")
    driver:RegisterEvent("SPELLCAST_SUCCEEDED")
    driver:Show(false)
    return driver
end, P.SafeTraceback)
if not ok or driverOrErr == nil then P.BootError = "runtime driver: " .. tostring(driverOrErr); P.SafeChat("运行时初始化失败：" .. tostring(driverOrErr)); return end

R.driver = driverOrErr
R.running = false
P.Ready = true

-- Independent 1-second liveness sentinel. It performs no normal effect scans.
-- It only exists while Plates Runtime is enabled; Module Disabled releases its
-- OnUpdate handler completely instead of relying on a hidden host to early-out.
WatchdogUpdateHandler = function(_, dt)
    if P.Generation ~= runtimeGeneration or R.running ~= true then return end
    watchdogElapsed = watchdogElapsed + DeltaMs(dt)
    if watchdogElapsed < 1000 then return end

    -- Watchdog is a P5 health lane. If the Suite is under pressure, postpone the
    -- check instead of competing with combat/readability work. The elapsed value
    -- is intentionally preserved so starvation protection can eventually grant
    -- the health check.
    local watchdogAllowed = R:TryBudgetLane("watchdog", watchdogElapsed, 1000)
    if not watchdogAllowed then
        R.watchdogBudgetDeferrals = (tonumber(R.watchdogBudgetDeferrals) or 0) + 1
        return
    end
    watchdogElapsed = 0

    local currentHeartbeat = tonumber(R.heartbeatSerial) or 0
    if currentHeartbeat == watchdogObservedHeartbeat then
        R.watchdogRecoveries = (tonumber(R.watchdogRecoveries) or 0) + 1
        R.watchdogRecoveryAttempts = (tonumber(R.watchdogRecoveryAttempts) or 0) + 1
        local rebound = false
        if R.driver ~= nil then
            if type(R.driver.Show) == "function" then pcall(R.driver.Show, R.driver, true) end
            if type(R.driver.SetHandler) == "function" then
                ReleaseWidgetHandler(R.driver, "OnUpdate")
                local okBind = BindWidgetHandler(R.driver, "OnUpdate", RuntimeUpdateHandler)
                rebound = okBind == true
            end
        end
        if rebound then
            -- Never call R:OnUpdate from the watchdog and never ForceAll here.
            -- Mark a bounded warm refresh and let the regular runtime host make
            -- progress over subsequent rendered frames under FrameBudget.
            R:RequestWarmRecovery()
            R.laneErrors.watchdog = nil
            if SuiteDiagnostics ~= nil and type(SuiteDiagnostics.WarnRateLimited) == "function" then
                pcall(SuiteDiagnostics.WarnRateLimited, SuiteDiagnostics, "plates", "WATCHDOG_REBIND", 5000,
                    "Plates Runtime 心跳停滞，已重绑主刷新并安排温和恢复", { heartbeat=currentHeartbeat, attempts=R.watchdogRecoveryAttempts })
            end
        else
            local text = "Runtime watchdog failed to rebind OnUpdate"
            if R.laneErrors.watchdog ~= text then R.laneErrors.watchdog = text end
            if SuiteDiagnostics ~= nil and type(SuiteDiagnostics.ErrorRateLimited) == "function" then
                pcall(SuiteDiagnostics.ErrorRateLimited, SuiteDiagnostics, "plates", "WATCHDOG_REBIND_FAILED", 5000, text, { heartbeat=currentHeartbeat })
            end
        end
    end
    watchdogObservedHeartbeat = currentHeartbeat

    if type(U.ReconcileScope) == "function" then
        for _, scope in ipairs(SCOPE_ORDER) do
            local st = R.scopes[scope]
            if st ~= nil then
                local okRepair, repaired = pcall(U.ReconcileScope, U, scope, st.effectSnapshots)
                if okRepair and tonumber(repaired) ~= nil then
                    R.visibilityRepairs = (tonumber(R.visibilityRepairs) or 0) + tonumber(repaired)
                end
            end
        end
    end
end

local watchdogOk, watchdogOrErr = xpcall(function()
    local watchdog = CreateEmptyWindow(P.PhysicalId("runtime_watchdog"), "UIParent")
    watchdog:SetExtent(1, 1); watchdog:AddAnchor("TOPLEFT", "UIParent", 1, 0)
    if watchdog.EnablePick ~= nil then watchdog:EnablePick(false, true) end
    if watchdog.Clickable ~= nil then watchdog:Clickable(false, true) end
    watchdog:Show(false)
    return watchdog
end, P.SafeTraceback)
if watchdogOk and watchdogOrErr ~= nil then
    R.watchdog = watchdogOrErr
else
    R.watchdogInitError = tostring(watchdogOrErr or "unknown")
end

U:SetRuntimeStatus("等待可见单位", "idle")


function R:StartModule()
    if P.BootError ~= nil then return false end
    runtimeFailureCount = 0
    lastRuntimeError = nil
    watchdogElapsed = 0
    watchdogObservedHeartbeat = tonumber(self.heartbeatSerial) or 0
    local handlersOk, handlersErr = InstallRuntimeHandlers()
    if not handlersOk then
        self.running = false
        U:SetRuntimeStatus("运行时处理器安装失败", "error")
        if handlersErr ~= nil then self.lastEventError = tostring(handlersErr) end
        return false
    end
    self.running = true
    if self.driver ~= nil then pcall(function() self.driver:Show(true) end) end
    if self.watchdog ~= nil then pcall(function() self.watchdog:Show(true) end) end
    -- Combat alerts ride the plates module lifecycle: start the shared Alerts
    -- channel so UpdateAlerts can push. Embedded mode keeps the module's own
    -- runtime gated by Suite ModuleManager; Alerts is cheap and demand-driven.
    if ReplicatedSuite ~= nil and ReplicatedSuite.Services ~= nil
        and ReplicatedSuite.Services.Alerts ~= nil
        and type(ReplicatedSuite.Services.Alerts.Start) == "function" then
        pcall(ReplicatedSuite.Services.Alerts.Start, ReplicatedSuite.Services.Alerts)
    end
    self:ForceAll()
    P.Ready = true
    return true
end

ReplicatedPlatesModule = ReplicatedPlatesModule or {}
ReplicatedPlatesModule.Version = "1.1"
function ReplicatedPlatesModule:GetRuntimeDiagnostics()
    return R:GetRuntimeDiagnostics()
end

if ReplicatedSuiteEmbedded == true then
    R:Stop()
else
    R:StartModule()
end

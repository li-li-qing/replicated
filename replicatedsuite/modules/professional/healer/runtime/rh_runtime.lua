ReplicatedSuiteModuleSandbox:Enter('healer', {'ReplicatedHealerBoot', 'ReplicatedHealerConfig', 'ReplicatedHealerModule'})
------------------------------------------------------------------------
-- Replicated Healer - Runtime v1.3
--
-- Frame-sliced execution Authority for the Healer Domain.
--
-- Design goals:
--   * preserve the configured healthScanMs / buffScanMs semantic cadence;
--   * never scan a whole 50/100-player raid in one rendered frame;
--   * stage a complete health/status generation, then commit atomically;
--   * use Suite FrameBudget as a soft policy for deferrable lanes;
--   * keep recommendation scoring/sorting in Recommendation Domain;
--   * route Native projection through dedicated Presenter objects.
--
-- The runtime deliberately does not create another OnUpdate. Core2 keeps the
-- single historical Healer update host and delegates each callback here.
------------------------------------------------------------------------

if ReplicatedHealerCore1Loaded ~= true then return end

ReplicatedHealerRuntime = ReplicatedHealerRuntime or {}
local R = ReplicatedHealerRuntime

R.Version = "1.3"
R.HealthSliceMembers = 20
R.StatusSliceMembers = 8
R.RosterSlotSliceMembers = 16
R.RosterRoleSliceMembers = 8
R.RosterPollMs = 1000
R.VisualMs = 30       -- visual pass target interval (was 50)
R.MetricsMs = 500

R.health = R.health or {
    active=false, cursor=1, members={}, snapshot=nil, recommendations={}, unavailable={},
    candidateMemory=nil, statusUpdates=nil, pendingMember=nil, pendingSnapshot=nil,
    statusDisplayTracking=false, startedAt=0,
}
R.status = R.status or { active=false, cursor=1, members={}, cache=nil, startedAt=0 }
R.visual = R.visual or { recommendation=true, markers=true, raid=true }
R.deferByLane = R.deferByLane or { roster=0, status=0, visual=0, settings=0 }
R.deferByLane.roster = tonumber(R.deferByLane.roster) or 0
R.rosterSignature = R.rosterSignature or nil
R.statusGeneration = tonumber(R.statusGeneration) or 0
R.healthGeneration = tonumber(R.healthGeneration) or 0
R.metrics = R.metrics or {
    rosterChanges=0,
    healthCyclesStarted=0, healthCyclesCompleted=0, healthMembers=0, maxHealthSlice=0,
    healthStatusRefreshes=0, maxHealthStatusRefreshSlice=0,
    statusCyclesStarted=0, statusCyclesCompleted=0, statusMembers=0, maxStatusSlice=0,
    visualPasses=0, visualDeferred=0, rosterDeferred=0, statusDeferred=0, settingsDeferred=0,
    runtimeResets=0,
}

local function Profile(label, callback, argument)
    local monitor = ReplicatedSuite and ReplicatedSuite.PerformanceMonitor or nil
    if monitor == nil or monitor.capture == nil or monitor.capture.finished == true then
        return callback(argument)
    end
    local token = monitor:Begin(label, "healer")
    local result = callback(argument)
    monitor:End(token)
    return result
end


local function RunStatusSliceProfile(runtime)
    return runtime:RunStatusSlice()
end

local function RunHealthSliceProfile(runtime)
    return runtime:RunHealthSlice()
end

local function RunRosterSliceProfile(runtime)
    local domain = ReplicatedHealerRoster
    if domain == nil or type(domain.RunSlice) ~= "function" then return false end
    return domain:RunSlice(runtime.RosterSlotSliceMembers, runtime.RosterRoleSliceMembers)
end

local function RunObserverTickProfile(args)
    local observer = args and args.observer or nil
    if observer == nil or type(observer.Tick) ~= "function" then return false end
    return observer:Tick(args.deltaMs, args.runtimeEnabled, args.rosterStable, args.rosterPollMs)
end

local function ClearArray(value)
    if type(value) ~= "table" then return {} end
    for index = #value, 1, -1 do value[index] = nil end
    return value
end

local function CopyRoster(target)
    target = ClearArray(target)
    for index = 1, #(roster or {}) do target[index] = roster[index] end
    return target
end

local function BuildRosterSignature()
    local parts = { tostring(rosterMode or "none"), ":", tostring(#(roster or {})) }
    for index = 1, #(roster or {}) do
        local member = roster[index]
        parts[#parts + 1] = "|"
        parts[#parts + 1] = tostring(member and member.key or "")
        parts[#parts + 1] = "#"
        parts[#parts + 1] = tostring(member and member.name or "")
        parts[#parts + 1] = "@"
        parts[#parts + 1] = tostring(member and member.role or 0)
    end
    return table.concat(parts)
end

local function DiagnosticsCount(code, delta)
    local diagnostics = ReplicatedSuite and ReplicatedSuite.DiagnosticsManager or nil
    if diagnostics ~= nil and type(diagnostics.Count) == "function" then
        diagnostics:Count("healer", code, delta or 1)
    end
end

function R:MarkVisualDirty(kind)
    if kind == nil or kind == "all" then
        self.visual.recommendation = true
        self.visual.markers = true
        self.visual.raid = true
        return
    end
    if self.visual[kind] ~= nil then self.visual[kind] = true end
end

function R:AbortCycles()
    self.health.active = false
    self.health.cursor = 1
    self.health.snapshot = nil
    self.health.candidateMemory = nil
    self.health.statusUpdates = nil
    self.health.pendingMember = nil
    self.health.pendingSnapshot = nil
    self.health.statusDisplayTracking = false
    ClearArray(self.health.members)
    ClearArray(self.health.recommendations)
    ClearArray(self.health.unavailable)

    self.status.active = false
    self.status.cursor = 1
    self.status.cache = nil
    ClearArray(self.status.members)
end

function R:Reset(reason, clearDomainCaches)
    self:AbortCycles()
    self.deferByLane.roster = 0
    self.deferByLane.status = 0
    self.deferByLane.visual = 0
    self.deferByLane.settings = 0
    self.metrics.runtimeResets = (tonumber(self.metrics.runtimeResets) or 0) + 1
    if clearDomainCaches == true then
        healthSnapshot = {}
        statusCache = {}
        recommendations = {}
        unavailable = {}
        previousRanks = {}
        candidateMemory = {}
        self.rosterSignature = nil
        self.statusGeneration = 0
        self.healthGeneration = 0
    end
    self:MarkVisualDirty("all")
    if ReplicatedHealerRoster ~= nil then
        if tostring(reason or "") == "enable" and type(ReplicatedHealerRoster.Invalidate) == "function" then
            -- A disabled module may have missed native team events. Do not let
            -- the previous session's roster feed a new Recommendation cycle.
            ReplicatedHealerRoster:Invalidate(false, "runtime_enable")
        elseif tostring(reason or "") ~= "disable" and type(ReplicatedHealerRoster.Request) == "function" then
            ReplicatedHealerRoster:Request("runtime_reset", true)
        end
    end
    if reason ~= nil then DiagnosticsCount("RUNTIME_RESET", 1) end
end

function R:InvalidateRoster(clearDomainCaches)
    self.rosterSignature = nil
    self:AbortCycles()
    if ReplicatedHealerRoster ~= nil and type(ReplicatedHealerRoster.Invalidate) == "function" then
        ReplicatedHealerRoster:Invalidate(false, "runtime_invalidate")
    end
    if clearDomainCaches == true then
        healthSnapshot = {}
        statusCache = {}
        recommendations = {}
        unavailable = {}
        previousRanks = {}
        candidateMemory = {}
        self.statusGeneration = 0
        self.healthGeneration = 0
    end
    self:MarkVisualDirty("all")
end

function R:OnRosterRebuilt()
    local signature = BuildRosterSignature()
    if signature == self.rosterSignature then return false end

    self.rosterSignature = signature
    self.metrics.rosterChanges = (tonumber(self.metrics.rosterChanges) or 0) + 1
    self:AbortCycles()

    -- A different roster invalidates every key-indexed generation. Keeping old
    -- rows would make an old teammate briefly influence a new recommendation.
    healthSnapshot = {}
    statusCache = {}
    recommendations = {}
    unavailable = {}
    previousRanks = {}
    candidateMemory = {}
    self.statusGeneration = 0
    self.healthGeneration = 0

    healthElapsed = math.max(tonumber(healthElapsed) or 0, tonumber(state and state.healthScanMs) or 100)
    buffElapsed = math.max(tonumber(buffElapsed) or 0, tonumber(state and state.buffScanMs) or 200)
    self:MarkVisualDirty("all")
    DiagnosticsCount("ROSTER_GENERATION_CHANGED", 1)
    return true
end

function R:OnScoringPolicyChanged(reason)
    -- Scoring configuration is Domain policy. Abort only staged generations so
    -- one atomic Recommendation generation never mixes old/new scoring rules.
    self:AbortCycles()
    healthElapsed = math.max(tonumber(healthElapsed) or 0, tonumber(state and state.healthScanMs) or 100)
    buffElapsed = math.max(tonumber(buffElapsed) or 0, tonumber(state and state.buffScanMs) or 200)
    self:MarkVisualDirty("all")
    DiagnosticsCount("SCORING_POLICY_CHANGED", 1)
end

function R:OnStatusSnapshotCommitted()
    self.statusGeneration = (tonumber(self.statusGeneration) or 0) + 1
    self.metrics.statusCyclesCompleted = (tonumber(self.metrics.statusCyclesCompleted) or 0) + 1
    -- Status affects rescue score and raid tint. Force one health generation so
    -- every recommendation observes the newly committed status generation.
    healthElapsed = math.max(tonumber(healthElapsed) or 0, tonumber(state and state.healthScanMs) or 100)
    self.visual.raid = true
end

function R:OnHealthSnapshotCommitted()
    self.healthGeneration = (tonumber(self.healthGeneration) or 0) + 1
    self.metrics.healthCyclesCompleted = (tonumber(self.metrics.healthCyclesCompleted) or 0) + 1
    self:MarkVisualDirty("all")
end

function R:_RequestLane(lane, priority, costUnits, lateRatio)
    local budget = ReplicatedSuite and ReplicatedSuite.FrameBudget or nil
    if budget == nil or type(budget.Request) ~= "function" then
        self.deferByLane[lane] = 0
        return true, "no_budget"
    end

    local deferCount = math.max(0, math.floor(tonumber(self.deferByLane[lane]) or 0))
    local granted, reason = budget:Request("healer:" .. tostring(lane), priority, costUnits or 1, deferCount, lateRatio or 0)
    if granted then
        self.deferByLane[lane] = 0
        return true, reason
    end

    self.deferByLane[lane] = deferCount + 1
    if lane == "roster" then
        self.metrics.rosterDeferred = (tonumber(self.metrics.rosterDeferred) or 0) + 1
    elseif lane == "status" then
        self.metrics.statusDeferred = (tonumber(self.metrics.statusDeferred) or 0) + 1
    elseif lane == "visual" then
        self.metrics.visualDeferred = (tonumber(self.metrics.visualDeferred) or 0) + 1
    elseif lane == "settings" then
        self.metrics.settingsDeferred = (tonumber(self.metrics.settingsDeferred) or 0) + 1
    end
    return false, reason
end

function R:StartStatusCycle()
    local cycle = self.status
    cycle.active = true
    cycle.cursor = 1
    cycle.members = CopyRoster(cycle.members)
    cycle.cache = {}
    cycle.startedAt = animationClock
    self.metrics.statusCyclesStarted = (tonumber(self.metrics.statusCyclesStarted) or 0) + 1
    if #cycle.members == 0 then
        cycle.active = false
        if ReplicatedHealerStatusCache ~= nil and type(ReplicatedHealerStatusCache.Commit) == "function" then
            ReplicatedHealerStatusCache:Commit({})
        else
            CommitStatusSnapshot({})
        end
    end
end

function R:RunStatusSlice()
    local cycle = self.status
    if cycle.active ~= true then return false end
    local total = #cycle.members
    local first = cycle.cursor
    local last = math.min(total, first + math.max(1, math.floor(tonumber(self.StatusSliceMembers) or 8)) - 1)
    local processed = 0

    for index = first, last do
        local member = cycle.members[index]
        if member ~= nil then
            local statusDomain = ReplicatedHealerStatusCache
            local statuses, scannedAt
            if statusDomain ~= nil and type(statusDomain.Read) == "function" then
                statuses, scannedAt = statusDomain:Read(member)
            else
                statuses, scannedAt = ReadUnitStatuses(member)
            end
            cycle.cache[member.key] = { statuses=statuses, scannedAt=scannedAt }
            processed = processed + 1
        end
    end
    cycle.cursor = last + 1
    self.metrics.statusMembers = (tonumber(self.metrics.statusMembers) or 0) + processed
    self.metrics.maxStatusSlice = math.max(tonumber(self.metrics.maxStatusSlice) or 0, processed)

    if cycle.cursor > total then
        local committed = cycle.cache or {}
        cycle.active = false
        cycle.cursor = 1
        cycle.cache = nil
        ClearArray(cycle.members)
        if ReplicatedHealerStatusCache ~= nil and type(ReplicatedHealerStatusCache.Commit) == "function" then
            ReplicatedHealerStatusCache:Commit(committed)
        else
            CommitStatusSnapshot(committed)
        end
        DiagnosticsCount("STATUS_GENERATION_COMMITTED", 1)
        return true
    end
    return false
end

function R:StartHealthCycle()
    local cycle = self.health
    cycle.active = true
    cycle.cursor = 1
    cycle.members = CopyRoster(cycle.members)
    cycle.snapshot = {}
    cycle.recommendations = ClearArray(cycle.recommendations)
    cycle.unavailable = ClearArray(cycle.unavailable)
    local recommendationDomain = ReplicatedHealerRecommendation
    cycle.candidateMemory = recommendationDomain ~= nil and type(recommendationDomain.CopyCandidateMemorySnapshot) == "function"
        and recommendationDomain.CopyCandidateMemorySnapshot() or CopyCandidateMemorySnapshot()
    cycle.statusUpdates = {}
    cycle.pendingMember = nil
    cycle.pendingSnapshot = nil
    -- Rule/tag discovery is not repeated inside the 100-member hot loop.
    if recommendationDomain ~= nil and type(recommendationDomain.HasActiveStatusDisplayTracking) == "function" then
        cycle.statusDisplayTracking = recommendationDomain.HasActiveStatusDisplayTracking() == true
    else
        cycle.statusDisplayTracking = HasActiveStatusDisplayTracking() == true
    end
    cycle.startedAt = animationClock
    self.metrics.healthCyclesStarted = (tonumber(self.metrics.healthCyclesStarted) or 0) + 1
    if #cycle.members == 0 then
        cycle.active = false
        if ReplicatedHealerRecommendation ~= nil and type(ReplicatedHealerRecommendation.Publish) == "function" then
            ReplicatedHealerRecommendation:Publish({}, {}, {}, cycle.candidateMemory, nil)
        else
            PublishHealthRecommendationGeneration({}, {}, {}, cycle.candidateMemory, nil)
        end
        cycle.candidateMemory = nil
        cycle.statusUpdates = nil
    end
end

function R:RunHealthSlice()
    local cycle = self.health
    if cycle.active ~= true then return false end
    local total = #cycle.members
    local maxMembers = math.max(1, math.floor(tonumber(self.HealthSliceMembers) or 20))
    local maxStatusRefresh = math.max(1, math.floor(tonumber(self.StatusSliceMembers) or 8))
    local processed = 0
    local refreshedStatuses = 0

    -- One Recommendation Generation processes current health and any required
    -- emergency/status refresh for the same member in the same slice. This is
    -- the important accuracy path: the old EvaluateMember() could force-refresh
    -- Buffs when health was critical. We keep that rule, but cap expensive
    -- status reads per frame instead of letting the final commit rescan 100
    -- emergency players synchronously.
    while cycle.cursor <= total and processed < maxMembers do
        local member = cycle.members[cycle.cursor]
        if member == nil then
            cycle.cursor = cycle.cursor + 1
            processed = processed + 1
        else
            local snapshot = nil
            if cycle.pendingMember == member and cycle.pendingSnapshot ~= nil then
                snapshot = cycle.pendingSnapshot
            else
                local current = tonumber(SafeUnitCall("UnitHealth", member.unitId))
                local maximum = tonumber(SafeUnitCall("UnitMaxHealth", member.unitId))
                local distance = ReadDistance(member.unitId, member.isSelf)
                if current ~= nil and maximum ~= nil and maximum > 0 and distance ~= nil then
                    snapshot = {
                        currentHealth = current,
                        maxHealth = maximum,
                        missingHealth = math.max(0, maximum - current),
                        healthPercent = Clamp(current / maximum * 100, 0, 100),
                        distance = distance,
                    }
                end
            end

            local statuses = nil
            if snapshot ~= nil then
                local cached = cycle.statusUpdates[member.key] or statusCache[member.key]
                local recommendationDomain = ReplicatedHealerRecommendation
                local shouldRefresh
                if recommendationDomain ~= nil and type(recommendationDomain.ShouldRefreshMemberStatuses) == "function" then
                    shouldRefresh = recommendationDomain.ShouldRefreshMemberStatuses(
                        member, snapshot, cached, animationClock, cycle.statusDisplayTracking)
                else
                    shouldRefresh = ShouldRefreshMemberStatuses(
                        member, snapshot, cached, animationClock, cycle.statusDisplayTracking)
                end
                if shouldRefresh and refreshedStatuses >= maxStatusRefresh then
                    -- Do not consume this member with a stale status snapshot.
                    -- Re-read its health next frame when an expensive status
                    -- refresh slot is available. Accuracy is preferred to one
                    -- fewer native reads. Preserve the already-read health
                    -- snapshot so the next frame does not call the same three
                    -- Native health/distance getters again.
                    cycle.pendingMember = member
                    cycle.pendingSnapshot = snapshot
                    break
                end
                if shouldRefresh then
                    local statusDomain = ReplicatedHealerStatusCache
                    local readStatuses, scannedAt
                    if statusDomain ~= nil and type(statusDomain.Read) == "function" then
                        readStatuses, scannedAt = statusDomain:Read(member)
                    else
                        readStatuses, scannedAt = ReadUnitStatuses(member)
                    end
                    local update = { statuses = readStatuses, scannedAt = scannedAt }
                    cycle.statusUpdates[member.key] = update
                    statuses = readStatuses
                    refreshedStatuses = refreshedStatuses + 1
                else
                    statuses = cached and cached.statuses or {}
                end
            end

            cycle.pendingMember = nil
            cycle.pendingSnapshot = nil
            cycle.snapshot[member.key] = snapshot
            local recommendationDomain = ReplicatedHealerRecommendation
            local candidate, unavailableCandidate
            if recommendationDomain ~= nil and type(recommendationDomain.Evaluate) == "function" then
                candidate, unavailableCandidate = recommendationDomain:Evaluate(
                    member, snapshot, statuses or {}, cycle.candidateMemory, cycle.startedAt)
            else
                candidate, unavailableCandidate = EvaluateMemberFromData(
                    member, snapshot, statuses or {}, cycle.candidateMemory, cycle.startedAt)
            end
            if candidate ~= nil then cycle.recommendations[#cycle.recommendations + 1] = candidate end
            if unavailableCandidate ~= nil then cycle.unavailable[#cycle.unavailable + 1] = unavailableCandidate end

            cycle.cursor = cycle.cursor + 1
            processed = processed + 1
        end
    end

    self.metrics.healthMembers = (tonumber(self.metrics.healthMembers) or 0) + processed
    self.metrics.maxHealthSlice = math.max(tonumber(self.metrics.maxHealthSlice) or 0, processed)
    self.metrics.healthStatusRefreshes = (tonumber(self.metrics.healthStatusRefreshes) or 0) + refreshedStatuses
    self.metrics.maxHealthStatusRefreshSlice = math.max(
        tonumber(self.metrics.maxHealthStatusRefreshSlice) or 0, refreshedStatuses)

    if cycle.cursor > total then
        local committedHealth = cycle.snapshot or {}
        local committedRecommendations = cycle.recommendations or {}
        local committedUnavailable = cycle.unavailable or {}
        local committedMemory = cycle.candidateMemory or {}
        local committedStatuses = cycle.statusUpdates or {}
        cycle.active = false
        cycle.cursor = 1
        cycle.snapshot = nil
        cycle.candidateMemory = nil
        cycle.statusUpdates = nil
        cycle.pendingMember = nil
        cycle.pendingSnapshot = nil
        cycle.statusDisplayTracking = false
        cycle.recommendations = {}
        cycle.unavailable = {}
        ClearArray(cycle.members)
        if ReplicatedHealerRecommendation ~= nil and type(ReplicatedHealerRecommendation.Publish) == "function" then
            ReplicatedHealerRecommendation:Publish(
                committedHealth, committedRecommendations, committedUnavailable, committedMemory, committedStatuses)
        else
            PublishHealthRecommendationGeneration(
                committedHealth, committedRecommendations, committedUnavailable, committedMemory, committedStatuses)
        end
        DiagnosticsCount("HEALTH_GENERATION_COMMITTED", 1)
        if refreshedStatuses > 0 then DiagnosticsCount("HEALTH_TARGETED_STATUS_REFRESH", refreshedStatuses) end
        return true
    end
    if refreshedStatuses > 0 then DiagnosticsCount("HEALTH_TARGETED_STATUS_REFRESH", refreshedStatuses) end
    return false
end

function R:_RunVisualPass()
    local animateHead = state ~= nil and state.enabled == true and #(recommendations or {}) > 0
    local animateRaid = state ~= nil and state.enabled == true and #(recommendations or {}) > 0
        and tonumber(state.raidEffectMode) ~= 1
    local animateRecommendation = ReplicatedSuiteEmbedded ~= true and animateRaid

    local needRecommendation = self.visual.recommendation == true or animateRecommendation
    local needMarkers = self.visual.markers == true or animateHead
    local needRaid = self.visual.raid == true or animateRaid
    if not needRecommendation and not needMarkers and not needRaid then return false end

    -- Visual lane uses P1 priority so raid overlay / head markers are not
    -- starved during heavy combat frames. The cost is low (just widget
    -- position/color updates, no Native reads).
    local granted = self:_RequestLane("visual", "P1", 1, math.max(1, (tonumber(visualElapsed) or 0) / self.VisualMs))
    if not granted then return false end

    if needRecommendation then
        local listPresenter = ReplicatedHealerRecommendationListPresenter
        local refreshRecommendation = listPresenter ~= nil and listPresenter.RefreshNow or RefreshRecommendationPanel
        if type(refreshRecommendation) == "function" then
            if listPresenter ~= nil and refreshRecommendation == listPresenter.RefreshNow then
                Profile("healer:visual_recommendations", refreshRecommendation, listPresenter)
            else
                Profile("healer:visual_recommendations", refreshRecommendation)
            end
        end
        self.visual.recommendation = false
    end
    if needMarkers then
        local markerPresenter = ReplicatedHealerMarkerPresenter
        local refreshMarkers = markerPresenter ~= nil and markerPresenter.Refresh or RefreshHeadMarkers
        if type(refreshMarkers) == "function" then Profile("healer:head_markers", refreshMarkers) end
        self.visual.markers = false
    end
    if needRaid then
        local raidPresenter = ReplicatedHealerRaidPresenter
        local refreshRaid = raidPresenter ~= nil and raidPresenter.Refresh or RefreshRaidHighlights
        if type(refreshRaid) == "function" then Profile("healer:raid_highlights", refreshRaid) end
        self.visual.raid = false
    end
    self.metrics.visualPasses = (tonumber(self.metrics.visualPasses) or 0) + 1
    return true
end

function R:Tick(dt)
    local deltaMs = math.max(0, tonumber(dt) or 0)
    animationClock = (tonumber(animationClock) or 0) + deltaMs
    healthElapsed = (tonumber(healthElapsed) or 0) + deltaMs
    buffElapsed = (tonumber(buffElapsed) or 0) + deltaMs
    rosterElapsed = (tonumber(rosterElapsed) or 0) + deltaMs
    visualElapsed = (tonumber(visualElapsed) or 0) + deltaMs
    metricsElapsed = (tonumber(metricsElapsed) or 0) + deltaMs

    teamRosterSettleRemainingMs = math.max(0, (tonumber(teamRosterSettleRemainingMs) or 0) - deltaMs)
    local teamRosterStable = teamRosterSettleRemainingMs <= 0

    if state ~= nil and state.enabled == true and teamRosterStable then
        local rosterDomain = ReplicatedHealerRoster
        if rosterElapsed >= self.RosterPollMs then
            rosterElapsed = 0
            if rosterDomain ~= nil and type(rosterDomain.Request) == "function" then
                rosterDomain:Request("fallback_poll", false)
            elseif type(RebuildRoster) == "function" then
                -- Compatibility fallback only; normal Suite builds always load
                -- domain/rh_roster.lua before this Runtime.
                Profile("healer:roster_rebuild_fallback", RebuildRoster)
            end
        end

        if rosterDomain ~= nil and (rosterDomain.requestPending == true or (rosterDomain.cycle and rosterDomain.cycle.active == true)) then
            local granted = self:_RequestLane("roster", "P2", 1, math.max(1, (tonumber(rosterElapsed) or 0) / self.RosterPollMs))
            if granted then Profile("healer:roster_slice", RunRosterSliceProfile, self) end
        end

        local rosterReady = rosterDomain == nil or type(rosterDomain.IsReady) ~= "function" or rosterDomain:IsReady()
        if rosterReady then
            if self.status.active ~= true and buffElapsed >= math.max(100, tonumber(state.buffScanMs) or 200) then
                buffElapsed = 0
                self:StartStatusCycle()
            end

            local initialStatusPending = (tonumber(self.statusGeneration) or 0) <= 0
            local healthWorkedThisFrame = false

            -- The very first roster generation preserves the historical order:
            -- complete Status first, then publish the first Recommendation.
            if not initialStatusPending then
                if self.health.active ~= true
                    and healthElapsed >= math.max(50, tonumber(state.healthScanMs) or 100) then
                    healthElapsed = 0
                    self:StartHealthCycle()
                end
                if self.health.active == true then
                    -- Health/Recommendation is the correctness lane. It can itself
                    -- perform up to StatusSliceMembers targeted emergency refreshes,
                    -- so do not also run the periodic Status lane in the same frame.
                    self:_RequestLane("health", "P1", 1, 0)
                    Profile("healer:health_slice", RunHealthSliceProfile, self)
                    healthWorkedThisFrame = true
                end
            end

            if self.status.active == true and not healthWorkedThisFrame then
                local interval = math.max(100, tonumber(state.buffScanMs) or 200)
                local lateRatio = math.max(0, ((tonumber(animationClock) or 0) - (tonumber(self.status.startedAt) or 0)) / interval)
                local granted = self:_RequestLane("status", "P2", 2, lateRatio)
                if granted then Profile("healer:status_slice", RunStatusSliceProfile, self) end
            end
        end
    end

    -- Buff observer owns its own one-member cadence. Runtime only supplies the
    -- current stability/enabled context; observer reads never publish into the
    -- raid Status Generation.
    local observer = ReplicatedHealerBuffObserver
    if observer ~= nil and type(observer.Tick) == "function" then
        self.observerProfileArgs = self.observerProfileArgs or {}
        local args = self.observerProfileArgs
        args.observer = observer
        args.deltaMs = deltaMs
        args.runtimeEnabled = state ~= nil and state.enabled == true
        args.rosterStable = teamRosterStable
        args.rosterPollMs = self.RosterPollMs
        Profile("healer:observer_tick", RunObserverTickProfile, args)
    end

    if visualElapsed >= self.VisualMs then
        visualElapsed = 0
        self:_RunVisualPass()

        -- Z-order recovery is lifecycle correctness, not cosmetic animation. Do
        -- it independently of the deferrable visual lane after the native raid
        -- frame settle window closes.
        if teamRosterStable and teamRosterZOrderPending == true then
            teamRosterZOrderPending = false
            local raidPresenter = ReplicatedHealerRaidPresenter
            local ensureZOrder = raidPresenter ~= nil and raidPresenter.EnsureZOrder or EnsureRaidOverlayZOrder
            if type(ensureZOrder) == "function" then
                for sectionIndex = 1, 4 do
                    local overlay = raidOverlays and raidOverlays[sectionIndex] or nil
                    local visible = overlay ~= nil and overlay.window ~= nil and overlay.window:IsVisible()
                    ensureZOrder(overlay, visible == true)
                end
            end
        end
    end

    if metricsElapsed >= self.MetricsMs then
        metricsElapsed = 0
        if type(HasViewportChanged) == "function" and HasViewportChanged() then
            Profile("healer:layout", LayoutAll)
            self:MarkVisualDirty("all")
        end
        if configWindow ~= nil and configWindow:IsVisible() and type(RefreshSettingsUi) == "function" then
            local granted = self:_RequestLane("settings", "P4", 1, 1)
            if granted then Profile("healer:settings_refresh", RefreshSettingsUi) end
        end
    end
end

function R:Describe()
    local healthTotal = #(self.health.members or {})
    local statusTotal = #(self.status.members or {})
    local rosterInfo = ReplicatedHealerRoster ~= nil and type(ReplicatedHealerRoster.Describe) == "function"
        and ReplicatedHealerRoster:Describe() or nil
    local apiInfo = ReplicatedHealerApi ~= nil and type(ReplicatedHealerApi.Describe) == "function"
        and ReplicatedHealerApi:Describe() or nil
    local statusInfo = ReplicatedHealerStatusCache ~= nil and type(ReplicatedHealerStatusCache.Describe) == "function"
        and ReplicatedHealerStatusCache:Describe() or nil
    local recommendationInfo = ReplicatedHealerRecommendation ~= nil and type(ReplicatedHealerRecommendation.Describe) == "function"
        and ReplicatedHealerRecommendation:Describe() or nil
    local markerInfo = ReplicatedHealerMarkerPresenter ~= nil and type(ReplicatedHealerMarkerPresenter.Describe) == "function"
        and ReplicatedHealerMarkerPresenter:Describe() or nil
    local raidInfo = ReplicatedHealerRaidPresenter ~= nil and type(ReplicatedHealerRaidPresenter.Describe) == "function"
        and ReplicatedHealerRaidPresenter:Describe() or nil
    local listInfo = ReplicatedHealerRecommendationListPresenter ~= nil and type(ReplicatedHealerRecommendationListPresenter.Describe) == "function"
        and ReplicatedHealerRecommendationListPresenter:Describe() or nil
    local observerInfo = ReplicatedHealerBuffObserver ~= nil and type(ReplicatedHealerBuffObserver.Describe) == "function"
        and ReplicatedHealerBuffObserver:Describe() or nil
    local settingsStoreInfo = ReplicatedHealerSettingsStore ~= nil and type(ReplicatedHealerSettingsStore.Describe) == "function"
        and ReplicatedHealerSettingsStore:Describe() or nil
    return {
        version = tostring(self.Version or "?"),
        rosterMode = tostring(rosterMode or "none"),
        rosterCount = #(roster or {}),
        roster = rosterInfo,
        api = apiInfo,
        statusDomain = statusInfo,
        recommendationDomain = recommendationInfo,
        markerPresenter = markerInfo,
        raidPresenter = raidInfo,
        recommendationListPresenter = listInfo,
        buffObserver = observerInfo,
        settingsStore = settingsStoreInfo,
        statusGeneration = tonumber(self.statusGeneration) or 0,
        healthGeneration = tonumber(self.healthGeneration) or 0,
        health = {
            active = self.health.active == true,
            cursor = tonumber(self.health.cursor) or 1,
            total = healthTotal,
            slice = tonumber(self.HealthSliceMembers) or 20,
            started = tonumber(self.metrics.healthCyclesStarted) or 0,
            completed = tonumber(self.metrics.healthCyclesCompleted) or 0,
            members = tonumber(self.metrics.healthMembers) or 0,
            maxSlice = tonumber(self.metrics.maxHealthSlice) or 0,
            targetedStatusRefreshes = tonumber(self.metrics.healthStatusRefreshes) or 0,
            maxTargetedStatusRefreshSlice = tonumber(self.metrics.maxHealthStatusRefreshSlice) or 0,
        },
        status = {
            active = self.status.active == true,
            cursor = tonumber(self.status.cursor) or 1,
            total = statusTotal,
            slice = tonumber(self.StatusSliceMembers) or 8,
            started = tonumber(self.metrics.statusCyclesStarted) or 0,
            completed = tonumber(self.metrics.statusCyclesCompleted) or 0,
            members = tonumber(self.metrics.statusMembers) or 0,
            maxSlice = tonumber(self.metrics.maxStatusSlice) or 0,
        },
        visual = {
            dirtyRecommendation = self.visual.recommendation == true,
            dirtyMarkers = self.visual.markers == true,
            dirtyRaid = self.visual.raid == true,
            passes = tonumber(self.metrics.visualPasses) or 0,
        },
        deferred = {
            roster = tonumber(self.metrics.rosterDeferred) or 0,
            status = tonumber(self.metrics.statusDeferred) or 0,
            visual = tonumber(self.metrics.visualDeferred) or 0,
            settings = tonumber(self.metrics.settingsDeferred) or 0,
        },
        rosterChanges = tonumber(self.metrics.rosterChanges) or 0,
        runtimeResets = tonumber(self.metrics.runtimeResets) or 0,
    }
end

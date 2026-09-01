------------------------------------------------------------------------
-- Replicated Suite V3 - Healer Recommendation Domain
--
-- Pure Healer business Authority extracted from the proven Professional Healer
-- formula. It owns rule matching, rescue scoring, hysteresis, stable sorting and
-- atomic publication. It performs no Native reads, no scheduling and no UI.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Features = S.Features or {}
S.Features.Healer = S.Features.Healer or {}
local F = S.Features.Healer
local U = S.Utils

local SOURCE_BUFF = 1
local SOURCE_DEBUFF = 2
local SOURCE_HIDDEN = 4

local D = {
    version = 1,
    revision = 0,
    healthSnapshot = {},
    statusCache = {},
    candidateMemory = {},
    recommendations = {},
    unavailable = {},
    previousRanks = {},
    metrics = {
        evaluations = 0, publications = 0, statusCommits = 0,
        statusMerges = 0, resets = 0,
    },
}
D.presentationBoundary = "feature_projection"
F.Recommendation = D

local function Settings()
    return type(F.GetSettings) == "function" and F:GetSettings() or {}
end
local function Clamp(value, minimum, maximum)
    value = tonumber(value) or minimum
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end
local function DeepCopy(value)
    if U ~= nil and type(U.DeepCopy) == "function" then return U.DeepCopy(value) end
    return value
end
local function CopyColor(color, fallback)
    local source = type(color) == "table" and color or fallback or {}
    return {
        r = Clamp(source.r or 1, 0, 1), g = Clamp(source.g or 1, 0, 1),
        b = Clamp(source.b or 1, 0, 1), a = Clamp(source.a or 1, 0, 1),
    }
end

local function SourceModeAccepts(sourceMode, sourceMask)
    if sourceMode == 1 then
        return sourceMask % 2 == 1
    elseif sourceMode == 2 then
        return math.floor(sourceMask / SOURCE_DEBUFF) % 2 == 1
    elseif sourceMode == 3 then
        return math.floor(sourceMask / SOURCE_HIDDEN) % 2 == 1
    elseif sourceMode == 4 then
        return sourceMask % 2 == 1 or math.floor(sourceMask / SOURCE_DEBUFF) % 2 == 1
    end
    return sourceMask > 0
end

local function IsStatusValidForRule(status, rule)
    if status == nil or not SourceModeAccepts(rule.sourceMode, status.sourceMask or 0) then return false end
    if (status.stack or 1) < rule.minStacks then return false end
    if status.timeKnown then
        if (status.timeLeft or 0) < rule.minRemainingMs then return false end
    elseif not rule.unknownRemainingValid then
        return false
    end
    return true
end

local function RuleMatches(settings, rule, statuses, healthPercent, distance)
    if not rule.enabled or #(rule.ids or {}) == 0 then return false, {} end
    if rule.healthRangeEnabled and (healthPercent < rule.healthMin or healthPercent > rule.healthMax) then return false, {} end
    local ruleDistance = rule.distanceMode == 2 and rule.customDistance or settings.maxDistance
    if distance == nil or distance > ruleDistance then return false, {} end
    local matched = {}
    for _, id in ipairs(rule.ids or {}) do
        if IsStatusValidForRule(statuses[id], rule) then
            matched[#matched + 1] = id
        elseif rule.matchMode == 2 then
            return false, {}
        end
    end
    if rule.matchMode == 1 then return #matched > 0, matched end
    return #matched == #(rule.ids or {}), matched
end

local function HasSimpleDisplayGroups(settings)
    for _, rule in ipairs(settings.rules or {}) do
        if rule ~= nil and rule.simpleDisplayGroup == true then return true end
    end
    return false
end

local function FindTrackedBuffMatch(settings, statuses)
    if type(statuses) ~= "table" then return nil, nil end
    for index, tracked in ipairs(settings.trackedBuffs or {}) do
        if tracked.enabled ~= false and tracked.id ~= nil then
            local status = statuses[tonumber(tracked.id)]
            if status ~= nil then return tracked, status, index end
        end
    end
    return nil, nil, nil
end

local function ResolveHealingDisplayState(settings, healthPercent, distance, statuses, highestDisplayRule)
    if healthPercent == nil or healthPercent <= 0 or distance == nil or distance > settings.maxDistance then return nil, nil, 0, nil end
    if healthPercent <= settings.emergencyThreshold then return CopyColor(settings.emergencyColor), "紧急生命", 5, nil end
    if highestDisplayRule ~= nil and highestDisplayRule.rule ~= nil then
        local rule = highestDisplayRule.rule
        return CopyColor(rule.color), tostring(rule.name or "状态条件"), 4, rule
    end
    if not HasSimpleDisplayGroups(settings) then
        local tracked, status = FindTrackedBuffMatch(settings, statuses)
        if tracked ~= nil then
            local displayName = status ~= nil and status.name or tracked.name
            return CopyColor(tracked.color), tostring(displayName or tracked.name or "追踪 Buff"), 3, tracked
        end
    end
    if healthPercent <= settings.lowHealthThreshold then return CopyColor(settings.lowHealthColor), "低血量", 2, nil end
    return CopyColor(settings.proximityColor), "治疗范围", 1, nil
end

local function FindHighestDisplayRuleMatch(settings, statuses, healthPercent, distance)
    local best = nil
    for ruleIndex, rule in ipairs(settings.rules or {}) do
        if rule ~= nil and rule.simpleDisplayGroup == true then
            local matched, matchedIds = RuleMatches(settings, rule, statuses or {}, healthPercent, distance)
            if matched then
                local candidate = { rule = rule, ruleIndex = ruleIndex, matchedIds = matchedIds }
                if best == nil
                    or rule.displayPriority > best.rule.displayPriority
                    or (rule.displayPriority == best.rule.displayPriority and ruleIndex < best.ruleIndex) then
                    best = candidate
                end
            end
        end
    end
    return best
end

local function HealthDangerScore(settings, healthPercent)
    local danger = Clamp(1 - healthPercent / 100, 0, 1)
    if settings.healthCurveMode == 1 then return danger end
    local exponent = settings.healthAccelMode == 1 and 1.35 or (settings.healthAccelMode == 3 and 2.25 or 1.75)
    return danger ^ exponent
end

local function DistanceScore(settings, distance)
    local normalized = Clamp(distance / math.max(1, settings.maxDistance), 0, 1)
    if settings.distanceCurveMode == 1 then return 1 - normalized end
    local edgeStart = Clamp(1 - settings.distanceEdgePercent / 100, 0.05, 0.95)
    if normalized <= edgeStart then return 1 - (normalized / edgeStart) * 0.25 end
    local edgeProgress = (normalized - edgeStart) / math.max(0.01, 1 - edgeStart)
    return Clamp(0.75 * (1 - edgeProgress * edgeProgress), 0, 1)
end

local function MissingHealthScore(settings, missingHealth)
    local sensitivity = math.max(1, settings.missingSensitivity)
    return 1 - math.exp(-math.max(0, missingHealth) / sensitivity)
end

local function GetRoleScore(settings, role)
    if not settings.roleScoringEnabled then return 0 end
    local scores = settings.roleScores or {}
    if role == 2 then return scores.mainTank or 0 end
    if role == 3 then return scores.offTank or 0 end
    if role == 4 then return scores.healer or 0 end
    if role == 5 then return scores.unknown or 0 end
    return scores.normal or 0
end

local function GetLevelForScore(settings, score, forceEmergency, healthPercent)
    local thresholds = settings.levelThresholds or {}
    if forceEmergency or healthPercent <= settings.emergencyThreshold or score >= (thresholds.emergency or 80) then return 4 end
    if score >= (thresholds.high or 60) then return 3 end
    if score >= (thresholds.attention or 40) then return 2 end
    return 1
end

function D:HasActiveStatusDisplayTracking()
    local settings = Settings()
    if HasSimpleDisplayGroups(settings) then
        for _, rule in ipairs(settings.rules or {}) do
            if rule ~= nil and rule.simpleDisplayGroup == true and rule.enabled ~= false
                and type(rule.ids) == "table" and #rule.ids > 0 then return true end
        end
        return false
    end
    for _, tracked in ipairs(settings.trackedBuffs or {}) do
        if tracked ~= nil and tracked.enabled ~= false then return true end
    end
    return false
end

function D:ShouldRefreshMemberStatuses(member, snapshot, cached, nowMs, statusDisplayTracking)
    if snapshot == nil then return false end
    local settings = Settings()
    local healthPercent = tonumber(snapshot.healthPercent) or 100
    local now = tonumber(nowMs) or 0
    local tracking = statusDisplayTracking
    if tracking == nil then tracking = self:HasActiveStatusDisplayTracking() end
    return cached == nil
        or (healthPercent <= settings.emergencyThreshold and now - (cached.scannedAt or 0) > 80)
        or (healthPercent <= (member.isSelf and settings.selfThreshold or settings.enterThreshold)
            and now - (cached and cached.scannedAt or 0) > settings.buffScanMs)
        or (tracking == true and now - (cached and cached.scannedAt or 0) > settings.buffScanMs)
end

function D:CopyCandidateMemorySnapshot()
    local result = {}
    for key, row in pairs(self.candidateMemory or {}) do
        if type(row) == "table" then result[key] = { active = row.active == true, enteredAt = tonumber(row.enteredAt) or 0 } end
    end
    return result
end

function D:Evaluate(member, snapshot, statuses, memoryStore, evaluationTime)
    self.metrics.evaluations = (tonumber(self.metrics.evaluations) or 0) + 1
    local settings = Settings()
    memoryStore = type(memoryStore) == "table" and memoryStore or self.candidateMemory
    statuses = type(statuses) == "table" and statuses or {}
    local evalNow = tonumber(evaluationTime) or 0
    if snapshot == nil or snapshot.currentHealth <= 0 or snapshot.maxHealth <= 0 or snapshot.distance == nil then
        memoryStore[member.key] = nil
        return nil, nil
    end
    local healthPercent = snapshot.healthPercent
    local distance = snapshot.distance
    if distance > settings.maxDistance then
        memoryStore[member.key] = nil
        return nil, nil
    end

    local matchedRules = {}
    local exclusion = nil
    local forceEmergency = false
    local forcePriority = 0
    local hasProtection = false
    local highestDisplayRule = nil

    for ruleIndex, rule in ipairs(settings.rules or {}) do
        local matched, matchedIds = RuleMatches(settings, rule, statuses, healthPercent, distance)
        if matched then
            local match = { rule = rule, ruleIndex = ruleIndex, matchedIds = matchedIds }
            matchedRules[#matchedRules + 1] = match
            if rule.countsAsProtection then hasProtection = true end
            if rule.effectType == 3 then
                if exclusion == nil or rule.displayPriority > exclusion.rule.displayPriority then exclusion = match end
            elseif rule.effectType == 4 then
                forceEmergency = true
                forcePriority = math.max(forcePriority, rule.rescuePriority)
            end
            if rule.simpleDisplayGroup == true and (highestDisplayRule == nil
                or rule.displayPriority > highestDisplayRule.rule.displayPriority
                or (rule.displayPriority == highestDisplayRule.rule.displayPriority and ruleIndex < highestDisplayRule.ruleIndex)) then
                highestDisplayRule = match
            end
        end
    end

    local memory = memoryStore[member.key]
    local enterThreshold = member.isSelf and settings.selfThreshold or settings.enterThreshold
    local meetsEntry = healthPercent < enterThreshold or forceEmergency
    local baseEligible = meetsEntry
    if memory ~= nil and memory.active and healthPercent < settings.exitThreshold then baseEligible = true end
    if exclusion ~= nil then
        memoryStore[member.key] = nil
        if baseEligible and exclusion.rule.excludeDisplayMode == 2 then
            return nil, {
                key = member.key, name = member.name, raidIndex = member.raidIndex,
                distance = distance, healthPercent = healthPercent, reason = exclusion.rule.name,
            }
        end
        return nil, nil
    end
    if not baseEligible then
        if memory ~= nil and memory.active and evalNow - (memory.enteredAt or 0) < settings.minHoldMs then
            baseEligible = true
        else
            memoryStore[member.key] = nil
            return nil, nil
        end
    end
    if memory == nil then
        memory = { active = true, enteredAt = evalNow }
        memoryStore[member.key] = memory
    else
        memory.active = true
    end

    local weights = settings.weights or {}
    local weightHealth = (weights.health or 55) / 100
    local weightDistance = (weights.distance or 15) / 100
    local weightMissing = (weights.missing or 10) / 100
    local weightUnprotected = (weights.unprotected or 20) / 100
    local healthFactor = HealthDangerScore(settings, healthPercent)
    local distanceFactor = DistanceScore(settings, distance)
    local missingFactor = MissingHealthScore(settings, snapshot.missingHealth)
    local protectionFactor = hasProtection and 0 or 1
    local baseScore = 100 * (
        healthFactor * weightHealth
        + distanceFactor * weightDistance
        + missingFactor * weightMissing
        + protectionFactor * weightUnprotected
    )
    local roleScore = GetRoleScore(settings, member.role)

    local percentIncrease, percentDecrease = 0, 0
    local fixedIncrease, fixedDecrease = 0, 0
    local bestNonStackPercentIncrease, bestNonStackPercentDecrease = 0, 0
    local bestNonStackFixedIncrease, bestNonStackFixedDecrease = 0, 0
    local reasons = {}

    for _, match in ipairs(matchedRules) do
        local rule = match.rule
        if rule.effectType == 1 or rule.effectType == 2 then
            local magnitude = rule.scoreValue
            if rule.effectType == 1 and healthPercent <= settings.emergencyThreshold then
                magnitude = magnitude * rule.emergencyRetainPercent / 100
            end
            local isIncrease = rule.effectType == 2
            if rule.scoreMode == 2 then
                if rule.allowStack then
                    if isIncrease then percentIncrease = percentIncrease + magnitude else percentDecrease = percentDecrease + magnitude end
                else
                    if isIncrease then bestNonStackPercentIncrease = math.max(bestNonStackPercentIncrease, magnitude)
                    else bestNonStackPercentDecrease = math.max(bestNonStackPercentDecrease, magnitude) end
                end
            else
                if rule.allowStack then
                    if isIncrease then fixedIncrease = fixedIncrease + magnitude else fixedDecrease = fixedDecrease + magnitude end
                else
                    if isIncrease then bestNonStackFixedIncrease = math.max(bestNonStackFixedIncrease, magnitude)
                    else bestNonStackFixedDecrease = math.max(bestNonStackFixedDecrease, magnitude) end
                end
            end
            reasons[#reasons + 1] = rule.name
        elseif rule.effectType == 4 then
            reasons[#reasons + 1] = rule.name
        end
    end

    percentIncrease = percentIncrease + bestNonStackPercentIncrease
    percentDecrease = percentDecrease + bestNonStackPercentDecrease
    fixedIncrease = fixedIncrease + bestNonStackFixedIncrease
    fixedDecrease = fixedDecrease + bestNonStackFixedDecrease
    local percentNet = Clamp(percentIncrease - percentDecrease, -90, 200)
    local finalScore = baseScore * (1 + percentNet / 100) + fixedIncrease - fixedDecrease + roleScore
    finalScore = Clamp(finalScore, 0, 100)
    local level = GetLevelForScore(settings, finalScore, forceEmergency, healthPercent)

    local color, colorReason, visualPriority = ResolveHealingDisplayState(settings, healthPercent, distance, statuses, highestDisplayRule)
    if color == nil then
        color = CopyColor(settings.proximityColor)
        colorReason = "治疗范围"
        visualPriority = 1
    end

    local reasonText = #reasons > 0 and table.concat(reasons, ",") or (hasProtection and "已有保护" or "无保护")
    return {
        key = member.key,
        unitId = member.unitToken or member.unitId,
        unitToken = member.unitToken or member.unitId,
        name = member.name,
        raidIndex = member.raidIndex,
        memberIndex = member.memberIndex,
        isSelf = member.isSelf,
        role = member.role,
        currentHealth = snapshot.currentHealth,
        maxHealth = snapshot.maxHealth,
        healthPercent = healthPercent,
        missingHealth = snapshot.missingHealth,
        distance = distance,
        baseScore = baseScore,
        finalScore = finalScore,
        level = level,
        forceEmergency = forceEmergency,
        forcePriority = forcePriority,
        visualPriority = visualPriority,
        hasProtection = hasProtection,
        color = color,
        colorReason = colorReason,
        reason = reasonText,
        reasons = reasons,
        tieBreaker = (tonumber(member.raidIndex) or 0) * 1000 + (tonumber(member.memberIndex) or 0),
    }, nil
end

function D:_CandidateBefore(left, right)
    local settings = Settings()
    if left.visualPriority ~= right.visualPriority then return left.visualPriority > right.visualPriority end
    if left.forceEmergency ~= right.forceEmergency then return left.forceEmergency end
    if left.forceEmergency and right.forceEmergency and left.forcePriority ~= right.forcePriority then return left.forcePriority > right.forcePriority end
    local scoreDifference = left.finalScore - right.finalScore
    local leftPrevious = self.previousRanks[left.key]
    local rightPrevious = self.previousRanks[right.key]
    if leftPrevious ~= nil and rightPrevious ~= nil and math.abs(scoreDifference) < settings.scoreLead then return leftPrevious < rightPrevious end
    if left.finalScore ~= right.finalScore then return left.finalScore > right.finalScore end
    if left.healthPercent ~= right.healthPercent then return left.healthPercent < right.healthPercent end
    if left.distance ~= right.distance then return left.distance < right.distance end
    if left.tieBreaker ~= right.tieBreaker then return left.tieBreaker < right.tieBreaker end
    return tostring(left.key or "") < tostring(right.key or "")
end

function D:MergeTargetedStatusUpdates(statusUpdates)
    if type(statusUpdates) ~= "table" then return end
    for key, update in pairs(statusUpdates) do
        if type(update) == "table" then
            local current = self.statusCache[key]
            local currentAt = current and tonumber(current.scannedAt) or -1
            local updateAt = tonumber(update.scannedAt) or -1
            if current == nil or updateAt >= currentAt then
                self.statusCache[key] = update
                self.metrics.statusMerges = (tonumber(self.metrics.statusMerges) or 0) + 1
            end
        end
    end
end

function D:CommitStatusGeneration(nextCache)
    nextCache = type(nextCache) == "table" and nextCache or {}
    for key, current in pairs(self.statusCache or {}) do
        local staged = nextCache[key]
        local currentAt = current and tonumber(current.scannedAt) or -1
        local stagedAt = staged and tonumber(staged.scannedAt) or -1
        if currentAt > stagedAt then nextCache[key] = current end
    end
    self.statusCache = nextCache
    self.metrics.statusCommits = (tonumber(self.metrics.statusCommits) or 0) + 1
    return true
end

function D:GetStatusRow(key) return self.statusCache[tostring(key or "")] end

function D:Publish(nextHealth, nextRecommendations, nextUnavailable, nextCandidateMemory, statusUpdates)
    self.metrics.publications = (tonumber(self.metrics.publications) or 0) + 1
    self:MergeTargetedStatusUpdates(statusUpdates)
    self.healthSnapshot = type(nextHealth) == "table" and nextHealth or {}
    nextRecommendations = type(nextRecommendations) == "table" and nextRecommendations or {}
    nextUnavailable = type(nextUnavailable) == "table" and nextUnavailable or {}
    local domain = self
    table.sort(nextRecommendations, function(left, right) return domain:_CandidateBefore(left, right) end)
    for index = 1, #nextRecommendations do nextRecommendations[index].rank = index end
    self.recommendations = nextRecommendations
    self.unavailable = nextUnavailable
    if type(nextCandidateMemory) == "table" then self.candidateMemory = nextCandidateMemory end
    self.previousRanks = {}
    for index = 1, #self.recommendations do self.previousRanks[self.recommendations[index].key] = index end
    self.revision = self.revision + 1
    if S.Events ~= nil and type(S.Events.Publish) == "function" then
        S.Events:Publish("v3.healer.updated", self.revision, #self.recommendations)
    end
    return true
end

function D:ResetTransient(reason)
    self.healthSnapshot = {}
    self.statusCache = {}
    self.candidateMemory = {}
    self.recommendations = {}
    self.unavailable = {}
    self.previousRanks = {}
    self.revision = self.revision + 1
    self.metrics.resets = (tonumber(self.metrics.resets) or 0) + 1
    if S.Events ~= nil and type(S.Events.Publish) == "function" then S.Events:Publish("v3.healer.updated", self.revision, 0) end
    return true
end

function D:GetProjection(limit)
    limit = math.max(0, math.floor(tonumber(limit) or 50))
    local rows = {}
    for index = 1, math.min(limit, #self.recommendations) do rows[index] = DeepCopy(self.recommendations[index]) end
    local unavailable = {}
    for index = 1, math.min(limit, #self.unavailable) do unavailable[index] = DeepCopy(self.unavailable[index]) end
    return {
        revision = self.revision,
        recommendationCount = #self.recommendations,
        unavailableCount = #self.unavailable,
        recommendations = rows,
        unavailable = unavailable,
    }
end

-- Raid Overlay projection. This restores the legacy whole-roster visual
-- semantics without restoring a second observer: every row is derived only from
-- the already committed Health/Status generations. Presentation receives color,
-- slot and optional recommendation rank, never the mutable Domain caches.
function D:GetRaidDisplayProjection(members, options)
    local settings = Settings()
    members = type(members) == "table" and members or {}
    options = type(options) == "table" and options or {}
    local proximityMode = options.proximityMode ~= false
    local candidateByKey = {}
    for _, candidate in ipairs(self.recommendations or {}) do
        candidateByKey[tostring(candidate.key or "")] = candidate
    end
    local rows = {}
    local candidateCount = 0
    for _, member in ipairs(members) do
        local key = tostring(member and member.key or "")
        local snapshot = key ~= "" and self.healthSnapshot and self.healthSnapshot[key] or nil
        if type(snapshot) == "table" and tonumber(snapshot.currentHealth) and tonumber(snapshot.currentHealth) > 0
            and tonumber(snapshot.maxHealth) and tonumber(snapshot.maxHealth) > 0 and tonumber(snapshot.distance) ~= nil then
            local healthPercent = tonumber(snapshot.healthPercent) or 0
            local distance = tonumber(snapshot.distance)
            if healthPercent > 0 and distance <= settings.maxDistance then
                local candidate = candidateByKey[key]
                local color, colorReason, visualPriority = nil, nil, 0
                if type(candidate) == "table" then
                    color = CopyColor(candidate.color, settings.proximityColor)
                    colorReason = tostring(candidate.colorReason or "治疗推荐")
                    visualPriority = tonumber(candidate.visualPriority) or 1
                else
                    local statusRow = self.statusCache and self.statusCache[key] or nil
                    local statuses = type(statusRow) == "table" and type(statusRow.statuses) == "table" and statusRow.statuses or {}
                    local displayRule = FindHighestDisplayRuleMatch(settings, statuses, healthPercent, distance)
                    color, colorReason, visualPriority = ResolveHealingDisplayState(settings, healthPercent, distance, statuses, displayRule)
                end
                if color ~= nil and (type(candidate) == "table" or proximityMode or visualPriority > 1) then
                    local row = {
                        key = key,
                        raidIndex = tonumber(member.raidIndex) or 0,
                        memberIndex = tonumber(member.memberIndex) or 0,
                        healthPercent = healthPercent,
                        distance = distance,
                        color = CopyColor(color),
                        colorReason = colorReason,
                        visualPriority = visualPriority,
                        isCandidate = type(candidate) == "table",
                        rank = type(candidate) == "table" and tonumber(candidate.rank) or nil,
                    }
                    rows[#rows + 1] = row
                    if row.isCandidate then candidateCount = candidateCount + 1 end
                end
            end
        end
    end
    return {
        revision = self.revision,
        rosterCount = #members,
        candidateCount = candidateCount,
        rows = rows,
    }
end

-- Selected-member projection for Presentation. StatusMap remains Domain-owned;
-- callers receive a detached, sorted array so UI code cannot mutate the cache
-- or depend on hash iteration order. This method performs no Native reads.
function D:GetMemberProjection(key)
    key = tostring(key or "")
    if key == "" then return nil end
    local candidate = nil
    for _, row in ipairs(self.recommendations or {}) do
        if tostring(row.key or "") == key then candidate = row; break end
    end
    local unavailable = nil
    if candidate == nil then
        for _, row in ipairs(self.unavailable or {}) do
            if tostring(row.key or "") == key then unavailable = row; break end
        end
    end
    local statusRow = self.statusCache and self.statusCache[key] or nil
    local statuses = {}
    local statusMap = type(statusRow) == "table" and statusRow.statuses or nil
    for id, row in pairs(type(statusMap) == "table" and statusMap or {}) do
        if type(row) == "table" then
            local item = DeepCopy(row)
            item.id = tonumber(item.id) or tonumber(id) or 0
            statuses[#statuses + 1] = item
        end
    end
    table.sort(statuses, function(left, right)
        local lm = tonumber(left and left.sourceMask) or 0
        local rm = tonumber(right and right.sourceMask) or 0
        if lm ~= rm then return lm < rm end
        return (tonumber(left and left.id) or 0) < (tonumber(right and right.id) or 0)
    end)
    local health = self.healthSnapshot and self.healthSnapshot[key] or nil
    if candidate == nil and unavailable == nil and health == nil and statusRow == nil then return nil end
    return {
        key = key,
        revision = self.revision,
        candidate = candidate and DeepCopy(candidate) or nil,
        unavailable = unavailable and DeepCopy(unavailable) or nil,
        health = health and DeepCopy(health) or nil,
        statusScannedAt = type(statusRow) == "table" and tonumber(statusRow.scannedAt) or nil,
        statuses = statuses,
    }
end

function D:GetHealth()
    local statusMembers = 0
    for _ in pairs(self.statusCache or {}) do statusMembers = statusMembers + 1 end
    return {
        version = self.version,
        revision = self.revision,
        recommendations = #self.recommendations,
        unavailable = #self.unavailable,
        statusMembers = statusMembers,
        evaluations = tonumber(self.metrics.evaluations) or 0,
        publications = tonumber(self.metrics.publications) or 0,
        statusCommits = tonumber(self.metrics.statusCommits) or 0,
        statusMerges = tonumber(self.metrics.statusMerges) or 0,
        resets = tonumber(self.metrics.resets) or 0,
    }
end

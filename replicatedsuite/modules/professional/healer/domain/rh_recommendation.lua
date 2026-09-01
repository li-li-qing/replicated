ReplicatedSuiteModuleSandbox:Enter('healer', {'ReplicatedHealerBoot', 'ReplicatedHealerConfig', 'ReplicatedHealerModule'})
------------------------------------------------------------------------
-- Replicated Healer - Recommendation Domain v1
--
-- Authority for eligibility, rescue scoring, display priority, stable sorting
-- and atomic Recommendation publication. Native reads remain in rh_api and
-- status observations remain in rh_status_cache.
------------------------------------------------------------------------

if ReplicatedHealerCore1Loaded ~= true then return end

ReplicatedHealerRecommendation = ReplicatedHealerRecommendation or {}
local D = ReplicatedHealerRecommendation
D.Version = "1.0"
D.metrics = D.metrics or { evaluations=0, publications=0, compatibilityFullScans=0 }

function SourceModeAccepts(sourceMode, sourceMask)
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

function IsStatusValidForRule(status, rule)
	if status == nil or not SourceModeAccepts(rule.sourceMode, status.sourceMask or 0) then
		return false
	end
	if (status.stack or 1) < rule.minStacks then
		return false
	end
	if status.timeKnown then
		if (status.timeLeft or 0) < rule.minRemainingMs then
			return false
		end
	elseif not rule.unknownRemainingValid then
		return false
	end
	return true
end

function RuleMatches(rule, statuses, healthPercent, distance)
	if not rule.enabled or #rule.ids == 0 then
		return false, {}
	end
	if rule.healthRangeEnabled and (healthPercent < rule.healthMin or healthPercent > rule.healthMax) then
		return false, {}
	end
	local ruleDistance = rule.distanceMode == 2 and rule.customDistance or state.maxDistance
	if distance == nil or distance > ruleDistance then
		return false, {}
	end
	local matched = {}
	for _, id in ipairs(rule.ids) do
		if IsStatusValidForRule(statuses[id], rule) then
			matched[#matched + 1] = id
		elseif rule.matchMode == 2 then
			return false, {}
		end
	end
	if rule.matchMode == 1 then
		return #matched > 0, matched
	end
	return #matched == #rule.ids, matched
end

function FindTrackedBuffMatch(statuses)
	if type(statuses) ~= "table" then
		return nil, nil
	end
	for index, tracked in ipairs(state.trackedBuffs or {}) do
		if tracked.enabled ~= false and tracked.id ~= nil then
			local status = statuses[tonumber(tracked.id)]
			if status ~= nil then
				return tracked, status, index
			end
		end
	end
	return nil, nil, nil
end

-- Display priority is deliberately deterministic and separate from rescue
-- scoring: emergency > matched condition group > legacy tracked Buff >
-- low health > in-range base.  Simple condition groups therefore affect only
-- presentation and never silently change rescue scoring.
function ResolveHealingDisplayState(healthPercent, distance, statuses, highestDisplayRule)
	if healthPercent == nil or healthPercent <= 0 or distance == nil or distance > state.maxDistance then
		return nil, nil, 0, nil
	end
	if healthPercent <= state.emergencyThreshold then
		return CopyColor(state.emergencyColor), "紧急生命", 5, nil
	end
	if highestDisplayRule ~= nil and highestDisplayRule.rule ~= nil then
		local rule = highestDisplayRule.rule
		return CopyColor(rule.color), tostring(rule.name or "状态条件"), 4, rule
	end
	if not HasSimpleDisplayGroups() then
		local tracked, status = FindTrackedBuffMatch(statuses)
		if tracked ~= nil then
			local displayName = status ~= nil and status.name or tracked.name
			return CopyColor(tracked.color), tostring(displayName or tracked.name or "追踪 Buff"), 3, tracked
		end
	end
	if healthPercent <= state.lowHealthThreshold then
		return CopyColor(state.lowHealthColor), "低血量", 2, nil
	end
	return CopyColor(state.proximityColor), "治疗范围", 1, nil
end

function HealthDangerScore(healthPercent)
	local danger = Clamp(1 - healthPercent / 100, 0, 1)
	if state.healthCurveMode == 1 then
		return danger
	end
	local exponent = state.healthAccelMode == 1 and 1.35 or (state.healthAccelMode == 3 and 2.25 or 1.75)
	return danger ^ exponent
end

function DistanceScore(distance)
	local normalized = Clamp(distance / math.max(1, state.maxDistance), 0, 1)
	if state.distanceCurveMode == 1 then
		return 1 - normalized
	end
	local edgeStart = Clamp(1 - state.distanceEdgePercent / 100, 0.05, 0.95)
	if normalized <= edgeStart then
		return 1 - (normalized / edgeStart) * 0.25
	end
	local edgeProgress = (normalized - edgeStart) / math.max(0.01, 1 - edgeStart)
	return Clamp(0.75 * (1 - edgeProgress * edgeProgress), 0, 1)
end

function MissingHealthScore(missingHealth)
	local sensitivity = math.max(1, state.missingSensitivity)
	return 1 - math.exp(-math.max(0, missingHealth) / sensitivity)
end

function GetRoleScore(role)
	if not state.roleScoringEnabled then
		return 0
	end
	if role == 2 then
		return state.roleScores.mainTank or 0
	elseif role == 3 then
		return state.roleScores.offTank or 0
	elseif role == 4 then
		return state.roleScores.healer or 0
	elseif role == 5 then
		return state.roleScores.unknown or 0
	end
	return state.roleScores.normal or 0
end

function GetLevelForScore(score, forceEmergency, healthPercent)
	if forceEmergency or healthPercent <= state.emergencyThreshold or score >= state.levelThresholds.emergency then
		return 4
	elseif score >= state.levelThresholds.high then
		return 3
	elseif score >= state.levelThresholds.attention then
		return 2
	end
	return 1
end

function HasSimpleDisplayGroups()
	for _, rule in ipairs(state.rules or {}) do
		if rule ~= nil and rule.simpleDisplayGroup == true then return true end
	end
	return false
end

function HasActiveStatusDisplayTracking()
	local hasSimpleGroups = HasSimpleDisplayGroups()
	if hasSimpleGroups then
		for _, rule in ipairs(state.rules or {}) do
			if rule ~= nil and rule.simpleDisplayGroup == true and rule.enabled ~= false
				and type(rule.ids) == "table" and #rule.ids > 0 then return true end
		end
		return false
	end
	-- Compatibility only: legacy direct Buff colors remain active until the user
	-- creates the first new condition group.  From that point the group model is
	-- the sole display-color Authority, avoiding two hidden systems fighting.
	for _, tracked in ipairs(state.trackedBuffs or {}) do
		if tracked ~= nil and tracked.enabled ~= false then return true end
	end
	return false
end

function FindHighestDisplayRuleMatch(statuses, healthPercent, distance)
	local best = nil
	for ruleIndex, rule in ipairs(state.rules or {}) do
		if rule.simpleDisplayGroup == true then
			local matched, matchedIds = RuleMatches(rule, statuses or {}, healthPercent, distance)
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

function ShouldRefreshMemberStatuses(member, snapshot, cached, nowMs, statusDisplayTracking)
	if snapshot == nil then return false end
	local healthPercent = tonumber(snapshot.healthPercent) or 100
	local now = tonumber(nowMs) or tonumber(animationClock) or 0
	local tracking = statusDisplayTracking
	if tracking == nil then tracking = HasActiveStatusDisplayTracking() end
	return cached == nil
		or (healthPercent <= state.emergencyThreshold and now - (cached.scannedAt or 0) > 80)
		or (healthPercent <= (member.isSelf and state.selfThreshold or state.enterThreshold)
			and now - (cached and cached.scannedAt or 0) > state.buffScanMs)
		or (tracking == true and now - (cached and cached.scannedAt or 0) > state.buffScanMs)
end

function CopyCandidateMemorySnapshot()
	local result = {}
	for key, row in pairs(candidateMemory or {}) do
		if type(row) == "table" then
			result[key] = { active = row.active == true, enteredAt = tonumber(row.enteredAt) or 0 }
		end
	end
	return result
end

function EvaluateMemberFromData(member, snapshot, statuses, memoryStore, evaluationTime)
	memoryStore = type(memoryStore) == "table" and memoryStore or candidateMemory
	statuses = type(statuses) == "table" and statuses or {}
	local evalNow = tonumber(evaluationTime) or tonumber(animationClock) or 0
	if snapshot == nil or snapshot.currentHealth <= 0 or snapshot.maxHealth <= 0 or snapshot.distance == nil then
		memoryStore[member.key] = nil
		return nil, nil
	end
	local healthPercent = snapshot.healthPercent
	local distance = snapshot.distance
	if distance > state.maxDistance then
		memoryStore[member.key] = nil
		return nil, nil
	end

	local matchedRules = {}
	local exclusion = nil
	local forceEmergency = false
	local forcePriority = 0
	local hasProtection = false
	local highestProtectionRule = nil
	local highestDisplayRule = nil

	for ruleIndex, rule in ipairs(state.rules) do
		local matched, matchedIds = RuleMatches(rule, statuses, healthPercent, distance)
		if matched then
			local match = { rule = rule, ruleIndex = ruleIndex, matchedIds = matchedIds }
			matchedRules[#matchedRules + 1] = match
			if rule.countsAsProtection then
				hasProtection = true
				if highestProtectionRule == nil
					or rule.displayPriority > highestProtectionRule.rule.displayPriority
					or (rule.displayPriority == highestProtectionRule.rule.displayPriority
						and ruleIndex < highestProtectionRule.ruleIndex) then
					highestProtectionRule = match
				end
			end
			if rule.effectType == 3 then
				if exclusion == nil or rule.displayPriority > exclusion.rule.displayPriority then
					exclusion = match
				end
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
	local enterThreshold = member.isSelf and state.selfThreshold or state.enterThreshold
	local meetsEntry = healthPercent < enterThreshold or forceEmergency
	local baseEligible = meetsEntry
	if memory ~= nil and memory.active and healthPercent < state.exitThreshold then
		baseEligible = true
	end
	if exclusion ~= nil then
		memoryStore[member.key] = nil
		if baseEligible and exclusion.rule.excludeDisplayMode == 2 then
			return nil, {
				key = member.key,
				name = member.name,
				raidIndex = member.raidIndex,
				distance = distance,
				healthPercent = healthPercent,
				reason = exclusion.rule.name,
			}
		end
		return nil, nil
	end
	if not baseEligible then
		if memory ~= nil and memory.active and evalNow - (memory.enteredAt or 0) < state.minHoldMs then
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

	local weightHealth = state.weights.health / 100
	local weightDistance = state.weights.distance / 100
	local weightMissing = state.weights.missing / 100
	local weightUnprotected = state.weights.unprotected / 100
	local healthFactor = HealthDangerScore(healthPercent)
	local distanceFactor = DistanceScore(distance)
	local missingFactor = MissingHealthScore(snapshot.missingHealth)
	local protectionFactor = hasProtection and 0 or 1
	local baseScore = 100 * (
		healthFactor * weightHealth
		+ distanceFactor * weightDistance
		+ missingFactor * weightMissing
		+ protectionFactor * weightUnprotected
	)
	local roleScore = GetRoleScore(member.role)

	local percentIncrease = 0
	local percentDecrease = 0
	local fixedIncrease = 0
	local fixedDecrease = 0
	local bestNonStackPercentIncrease = 0
	local bestNonStackPercentDecrease = 0
	local bestNonStackFixedIncrease = 0
	local bestNonStackFixedDecrease = 0
	local reasons = {}

	for _, match in ipairs(matchedRules) do
		local rule = match.rule
		if rule.effectType == 1 or rule.effectType == 2 then
			local magnitude = rule.scoreValue
			if rule.effectType == 1 and healthPercent <= state.emergencyThreshold then
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
	local level = GetLevelForScore(finalScore, forceEmergency, healthPercent)

	local color, colorReason, visualPriority = ResolveHealingDisplayState(healthPercent, distance, statuses, highestDisplayRule)
	if color == nil then
		color = CopyColor(state.proximityColor)
		colorReason = "治疗范围"
		visualPriority = 1
	end

	local reasonText = #reasons > 0 and table.concat(reasons, ",") or (hasProtection and "已有保护" or "无保护")
	return {
		key = member.key,
		unitId = member.unitId,
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


function EvaluateMember(member)
	local snapshot = healthSnapshot[member.key]
	if snapshot == nil then
		candidateMemory[member.key] = nil
		return nil, nil
	end
	local cached = statusCache[member.key]
	local shouldRefresh = ShouldRefreshMemberStatuses(member, snapshot, cached, animationClock)
	local statuses = shouldRefresh and ScanUnitStatuses(member) or (cached and cached.statuses or nil)
	if statuses == nil then statuses = ScanUnitStatuses(member) end
	return EvaluateMemberFromData(member, snapshot, statuses, candidateMemory, animationClock)
end

function CandidateBefore(left, right)
	if left.visualPriority ~= right.visualPriority then
		return left.visualPriority > right.visualPriority
	end
	if left.forceEmergency ~= right.forceEmergency then
		return left.forceEmergency
	end
	if left.forceEmergency and right.forceEmergency and left.forcePriority ~= right.forcePriority then
		return left.forcePriority > right.forcePriority
	end
	local scoreDifference = left.finalScore - right.finalScore
	local leftPrevious = previousRanks[left.key]
	local rightPrevious = previousRanks[right.key]
	if leftPrevious ~= nil and rightPrevious ~= nil and math.abs(scoreDifference) < state.scoreLead then
		return leftPrevious < rightPrevious
	end
	if left.finalScore ~= right.finalScore then
		return left.finalScore > right.finalScore
	end
	if left.healthPercent ~= right.healthPercent then
		return left.healthPercent < right.healthPercent
	end
	if left.distance ~= right.distance then
		return left.distance < right.distance
	end
	if left.tieBreaker ~= right.tieBreaker then
		return left.tieBreaker < right.tieBreaker
	end
	return tostring(left.key or "") < tostring(right.key or "")
end

function MergeTargetedStatusUpdates(statusUpdates)
	if type(statusUpdates) ~= "table" then return end
	for key, update in pairs(statusUpdates) do
		if type(update) == "table" then
			local current = statusCache[key]
			local currentAt = current and tonumber(current.scannedAt) or -1
			local updateAt = tonumber(update.scannedAt) or -1
			if current == nil or updateAt >= currentAt then statusCache[key] = update end
		end
	end
end

function PublishHealthRecommendationGeneration(nextHealth, nextRecommendations, nextUnavailable, nextCandidateMemory, statusUpdates)
	MergeTargetedStatusUpdates(statusUpdates)
	healthSnapshot = type(nextHealth) == "table" and nextHealth or {}
	nextRecommendations = type(nextRecommendations) == "table" and nextRecommendations or {}
	nextUnavailable = type(nextUnavailable) == "table" and nextUnavailable or {}
	table.sort(nextRecommendations, CandidateBefore)
	for index = 1, #nextRecommendations do
		nextRecommendations[index].rank = index
	end
	recommendations = nextRecommendations
	unavailable = nextUnavailable
	if type(nextCandidateMemory) == "table" then candidateMemory = nextCandidateMemory end
	previousRanks = {}
	for index = 1, #recommendations do
		previousRanks[recommendations[index].key] = index
	end
	if recommendScrollOffset > math.max(0, #recommendations - RECOMMEND_VISIBLE_ROWS) then
		recommendScrollOffset = math.max(0, #recommendations - RECOMMEND_VISIBLE_ROWS)
	end
	if ReplicatedHealerRuntime ~= nil and type(ReplicatedHealerRuntime.OnHealthSnapshotCommitted) == "function" then
		ReplicatedHealerRuntime:OnHealthSnapshotCommitted()
	end
end

function CommitHealthSnapshotAndRecommendations(nextHealth)
	-- Compatibility full-scan path. Runtime v1 builds the same candidate data
	-- incrementally and calls PublishHealthRecommendationGeneration directly.
	healthSnapshot = type(nextHealth) == "table" and nextHealth or {}
	local nextRecommendations = {}
	local nextUnavailable = {}
	for _, member in ipairs(roster) do
		local candidate, unavailableCandidate = EvaluateMember(member)
		if candidate ~= nil then nextRecommendations[#nextRecommendations + 1] = candidate end
		if unavailableCandidate ~= nil then nextUnavailable[#nextUnavailable + 1] = unavailableCandidate end
	end
	PublishHealthRecommendationGeneration(healthSnapshot, nextRecommendations, nextUnavailable, candidateMemory, nil)
end

function ScanHealthAndBuildRecommendations()
	local nextHealth = {}
	for _, member in ipairs(roster) do
		local current = tonumber(SafeUnitCall("UnitHealth", member.unitId))
		local maximum = tonumber(SafeUnitCall("UnitMaxHealth", member.unitId))
		local distance = ReadDistance(member.unitId, member.isSelf)
		if current ~= nil and maximum ~= nil and maximum > 0 and distance ~= nil then
			nextHealth[member.key] = {
				currentHealth = current,
				maxHealth = maximum,
				missingHealth = math.max(0, maximum - current),
				healthPercent = Clamp(current / maximum * 100, 0, 100),
				distance = distance,
			}
		end
	end
	CommitHealthSnapshotAndRecommendations(nextHealth)
end



-- Stable Domain facade. Global function names above are compatibility proxies
-- for historical callers; Runtime should prefer this table.
D.SourceModeAccepts = SourceModeAccepts
D.IsStatusValidForRule = IsStatusValidForRule
D.RuleMatches = RuleMatches
D.FindTrackedBuffMatch = FindTrackedBuffMatch
D.ResolveHealingDisplayState = ResolveHealingDisplayState
D.HealthDangerScore = HealthDangerScore
D.DistanceScore = DistanceScore
D.MissingHealthScore = MissingHealthScore
D.GetRoleScore = GetRoleScore
D.GetLevelForScore = GetLevelForScore
D.HasSimpleDisplayGroups = HasSimpleDisplayGroups
D.HasActiveStatusDisplayTracking = HasActiveStatusDisplayTracking
D.FindHighestDisplayRuleMatch = FindHighestDisplayRuleMatch
D.ShouldRefreshMemberStatuses = ShouldRefreshMemberStatuses
D.CopyCandidateMemorySnapshot = CopyCandidateMemorySnapshot
D.EvaluateMemberFromData = EvaluateMemberFromData
D.EvaluateMember = EvaluateMember
D.CandidateBefore = CandidateBefore
D.MergeTargetedStatusUpdates = MergeTargetedStatusUpdates
D.PublishGeneration = PublishHealthRecommendationGeneration
D.CommitHealthSnapshot = CommitHealthSnapshotAndRecommendations
D.ScanHealthAndBuildRecommendations = ScanHealthAndBuildRecommendations

local RawEvaluateMemberFromData = D.EvaluateMemberFromData
function D:Evaluate(member, snapshot, statuses, memoryStore, evaluationTime)
    self.metrics.evaluations = (tonumber(self.metrics.evaluations) or 0) + 1
    return RawEvaluateMemberFromData(member, snapshot, statuses, memoryStore, evaluationTime)
end

local RawPublishGeneration = D.PublishGeneration
function D:Publish(nextHealth, nextRecommendations, nextUnavailable, nextCandidateMemory, statusUpdates)
    self.metrics.publications = (tonumber(self.metrics.publications) or 0) + 1
    return RawPublishGeneration(nextHealth, nextRecommendations, nextUnavailable, nextCandidateMemory, statusUpdates)
end

function D:Describe()
    return {
        version=tostring(self.Version or "?"),
        recommendations=#(recommendations or {}),
        unavailable=#(unavailable or {}),
        evaluations=tonumber(self.metrics.evaluations) or 0,
        publications=tonumber(self.metrics.publications) or 0,
        previousRankCount=(function() local n=0 for _ in pairs(previousRanks or {}) do n=n+1 end return n end)(),
    }
end

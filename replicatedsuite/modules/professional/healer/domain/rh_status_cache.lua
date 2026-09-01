ReplicatedSuiteModuleSandbox:Enter('healer', {'ReplicatedHealerBoot', 'ReplicatedHealerConfig', 'ReplicatedHealerModule'})
------------------------------------------------------------------------
-- Replicated Healer - Status Cache Domain v1
--
-- Authority for Healer Buff/Debuff/Hidden-Buff observation snapshots.
-- The historical Core1 global functions are retained only as compatibility
-- proxies while Runtime and new code call ReplicatedHealerStatusCache.
------------------------------------------------------------------------

if ReplicatedHealerCore1Loaded ~= true then return end

ReplicatedHealerStatusCache = ReplicatedHealerStatusCache or {}
local D = ReplicatedHealerStatusCache
D.Version = "1.1"
D.metrics = D.metrics or {
    reads=0, commits=0, directRefreshes=0,
    sharedReads=0, sharedAccepted=0, sharedFallbacks=0, sharedErrors=0,
}

function ReadTooltip(unitId, index, sourceBit)
	local tooltip = nil
	if sourceBit == SOURCE_BUFF then
		tooltip = SafeUnitCall("UnitBuffTooltip", unitId, index)
	elseif sourceBit == SOURCE_DEBUFF then
		tooltip = SafeUnitCall("UnitDeBuffTooltip", unitId, index)
	elseif sourceBit == SOURCE_HIDDEN then
		tooltip = SafeUnitCall("UnitHiddenBuffTooltip", unitId, index)
	end
	return type(tooltip) == "table" and tooltip or nil
end

local function StatusId(info)
	if type(info) ~= "table" then return nil end
	return tonumber(
		info.buff_id or info.buffId or info.buffID or info.id
		or info.buffType or info.buff_type or info.type
	)
end

local function StatusTimeLeft(info)
	if type(info) ~= "table" then return nil end
	return tonumber(
		info.timeLeft or info.time_left or info.remainTime
		or info.remainingTime or info.remain_time
	)
end

local function StatusIcon(info)
	if type(info) ~= "table" then return nil end
	for _,key in ipairs({"path","iconPath","icon_path","icon","skillIcon","skill_icon","texture"}) do
		local value=info[key]
		if type(value)=="string" and value~="" then return value end
	end
	return nil
end

function MergeStatus(statuses, extra, tooltip, sourceBit)
	extra = type(extra) == "table" and extra or {}
	tooltip = type(tooltip) == "table" and tooltip or {}
	local extraId = StatusId(extra)
	local tooltipId = StatusId(tooltip)
	local id = extraId or tooltipId
	if id == nil then
		statusScanDiagnostics.skippedNoId = (tonumber(statusScanDiagnostics.skippedNoId) or 0) + 1
		return
	end
	if extraId == nil and tooltipId ~= nil then
		statusScanDiagnostics.tooltipOnly = (tonumber(statusScanDiagnostics.tooltipOnly) or 0) + 1
	end

	local stack = tonumber(tooltip.stack or tooltip.stackCount or tooltip.count)
		or tonumber(extra.stack or extra.stackCount or extra.count) or 1
	local timeLeft = StatusTimeLeft(tooltip) or StatusTimeLeft(extra)
	local name = tostring(tooltip.name or tooltip.buffName or extra.name or extra.buffName or id)
	local iconPath = StatusIcon(tooltip) or StatusIcon(extra) or ""
	local entry = statuses[id]
	if entry == nil then
		entry = {
			id = id,
			stack = stack,
			timeLeft = timeLeft,
			timeKnown = timeLeft ~= nil,
			sourceMask = sourceBit,
			name = name,
			iconPath = iconPath,
		}
		statuses[id] = entry
	else
		entry.stack = math.max(entry.stack or 1, stack)
		entry.sourceMask = (entry.sourceMask or 0) + (entry.sourceMask % (sourceBit * 2) < sourceBit and sourceBit or 0)
		if (entry.name == nil or entry.name == "" or entry.name == tostring(entry.id)) and name ~= "" then entry.name = name end
		if (entry.iconPath == nil or entry.iconPath == "") and iconPath ~= "" then entry.iconPath = iconPath end
		if timeLeft ~= nil then
			if not entry.timeKnown or timeLeft > (entry.timeLeft or 0) then
				entry.timeLeft = timeLeft
			end
			entry.timeKnown = true
		end
	end
end

local function ReadUnitStatusesDirect(member)
	local statuses = {}
	-- Extra parentheses force exactly one Lua result. This client returns no
	-- values (rather than nil) for temporarily invalid team units.
	local buffCount = tonumber(SafeUnitCall("UnitBuffCount", member.unitId)) or 0
	for index = 1, buffCount do
		MergeStatus(statuses, SafeUnitCall("UnitBuff", member.unitId, index), ReadTooltip(member.unitId, index, SOURCE_BUFF), SOURCE_BUFF)
	end
	local debuffCount = tonumber(SafeUnitCall("UnitDeBuffCount", member.unitId)) or 0
	for index = 1, debuffCount do
		MergeStatus(statuses, SafeUnitCall("UnitDeBuff", member.unitId, index), ReadTooltip(member.unitId, index, SOURCE_DEBUFF), SOURCE_DEBUFF)
	end
	local hiddenCount = tonumber(SafeUnitCall("UnitHiddenBuffCount", member.unitId)) or 0
	for index = 1, hiddenCount do
		MergeStatus(statuses, SafeUnitCall("UnitHiddenBuff", member.unitId, index), ReadTooltip(member.unitId, index, SOURCE_HIDDEN), SOURCE_HIDDEN)
	end

	local resolved = 0
	for _ in pairs(statuses) do resolved = resolved + 1 end
	statusScanDiagnostics.scans = (tonumber(statusScanDiagnostics.scans) or 0) + 1
	statusScanDiagnostics.directScans = (tonumber(statusScanDiagnostics.directScans) or 0) + 1
	statusScanDiagnostics.lastSource = "direct"
	statusScanDiagnostics.lastMember = tostring(member.name or member.unitId or member.key or "")
	statusScanDiagnostics.lastBuffCount = buffCount
	statusScanDiagnostics.lastDebuffCount = debuffCount
	statusScanDiagnostics.lastHiddenCount = hiddenCount
	statusScanDiagnostics.lastResolved = resolved
	statusScanDiagnostics.lastScannedAt = animationClock
	return statuses, animationClock
end

local function ReadSharedStatuses(member)
	local suite = ReplicatedSuite
	local bridge = type(suite) == "table" and suite.Features and suite.Features.HealerAuraBridge or nil
	if type(bridge) ~= "table" or bridge.held ~= true or type(bridge.Read) ~= "function" then return nil, nil, "shared_bridge_inactive" end
	D.metrics.sharedReads = (tonumber(D.metrics.sharedReads) or 0) + 1
	local statuses, coverage, err = bridge:Read(member.unitId, { ttlMs = 80, limit = 256 })
	if type(statuses) ~= "table" or type(coverage) ~= "table" then
		D.metrics.sharedErrors = (tonumber(D.metrics.sharedErrors) or 0) + 1
		return nil, coverage, err or "shared_status_unavailable"
	end
	-- Healer recommendation accuracy is stricter than a display-only consumer.
	-- Missing rules/statuses may change rescue scoring, so partial or unreliable
	-- shared coverage is never consumed as if absence were proven. Fall back to
	-- the historical direct read only for this degraded case.
	if coverage.available ~= true or coverage.complete ~= true or coverage.reliable ~= true then
		D.metrics.sharedFallbacks = (tonumber(D.metrics.sharedFallbacks) or 0) + 1
		return nil, coverage, "shared_status_degraded"
	end
	D.metrics.sharedAccepted = (tonumber(D.metrics.sharedAccepted) or 0) + 1
	statusScanDiagnostics.scans = (tonumber(statusScanDiagnostics.scans) or 0) + 1
	statusScanDiagnostics.sharedScans = (tonumber(statusScanDiagnostics.sharedScans) or 0) + 1
	statusScanDiagnostics.lastSource = "aura_v3"
	statusScanDiagnostics.lastMember = tostring(member.name or member.unitId or member.key or "")
	statusScanDiagnostics.lastBuffCount = tonumber(coverage.buffCount) or 0
	statusScanDiagnostics.lastDebuffCount = tonumber(coverage.debuffCount) or 0
	statusScanDiagnostics.lastHiddenCount = tonumber(coverage.hiddenCount) or 0
	statusScanDiagnostics.lastResolved = tonumber(coverage.rows) or 0
	statusScanDiagnostics.lastScannedAt = tonumber(coverage.scannedAt) or animationClock
	return statuses, tonumber(coverage.scannedAt) or animationClock, nil
end

function ReadUnitStatuses(member)
	local statuses, scannedAt = ReadSharedStatuses(member)
	if statuses ~= nil then return statuses, scannedAt end
	return ReadUnitStatusesDirect(member)
end

function ScanUnitStatuses(member)
	local statuses, scannedAt = ReadUnitStatuses(member)
	statusCache[member.key] = { statuses = statuses, scannedAt = scannedAt }
	return statuses
end

function CommitStatusSnapshot(nextCache)
	nextCache = type(nextCache) == "table" and nextCache or {}
	-- A periodic Status Generation may overlap a Health Generation that performs
	-- targeted emergency refreshes. Preserve the newer per-member observation so
	-- an older staged full-scan row can never overwrite a fresher critical read.
	for key, current in pairs(statusCache or {}) do
		local staged = nextCache[key]
		local currentAt = current and tonumber(current.scannedAt) or -1
		local stagedAt = staged and tonumber(staged.scannedAt) or -1
		if currentAt > stagedAt then nextCache[key] = current end
	end
	statusCache = nextCache
	if ReplicatedHealerRuntime ~= nil and type(ReplicatedHealerRuntime.OnStatusSnapshotCommitted) == "function" then
		ReplicatedHealerRuntime:OnStatusSnapshotCommitted()
	end
	return statusCache
end

function GetStatuses(member, forceRefresh)
	local cached = statusCache[member.key]
	if forceRefresh or cached == nil then
		return ScanUnitStatuses(member)
	end
	return cached.statuses
end

function ScanAllStatuses()
	local nextCache = {}
	for _, member in ipairs(roster) do
		local statuses, scannedAt = ReadUnitStatuses(member)
		nextCache[member.key] = { statuses = statuses, scannedAt = scannedAt }
	end
	CommitStatusSnapshot(nextCache)
end



-- Domain facade. Runtime uses these stable entry points; historical globals
-- above remain Compatibility Proxies for settings/observer code still being
-- migrated out of Core2.
D.ReadUnitStatuses = ReadUnitStatuses
D.ScanUnitStatuses = ScanUnitStatuses
D.CommitSnapshot = CommitStatusSnapshot
D.GetStatuses = GetStatuses
D.ScanAll = ScanAllStatuses

local RawReadUnitStatuses = D.ReadUnitStatuses
function D:Read(member)
    self.metrics.reads = (tonumber(self.metrics.reads) or 0) + 1
    return RawReadUnitStatuses(member)
end

local RawScanUnitStatuses = D.ScanUnitStatuses
function D:RefreshMember(member)
    self.metrics.directRefreshes = (tonumber(self.metrics.directRefreshes) or 0) + 1
    return RawScanUnitStatuses(member)
end

local RawCommitSnapshot = D.CommitSnapshot
function D:Commit(nextCache)
    self.metrics.commits = (tonumber(self.metrics.commits) or 0) + 1
    return RawCommitSnapshot(nextCache)
end

function D:Describe()
    local members = 0
    for _ in pairs(statusCache or {}) do members = members + 1 end
    return {
        version=tostring(self.Version or "?"),
        members=members,
        reads=tonumber(self.metrics.reads) or 0,
        commits=tonumber(self.metrics.commits) or 0,
        directRefreshes=tonumber(self.metrics.directRefreshes) or 0,
        sharedReads=tonumber(self.metrics.sharedReads) or 0,
        sharedAccepted=tonumber(self.metrics.sharedAccepted) or 0,
        sharedFallbacks=tonumber(self.metrics.sharedFallbacks) or 0,
        sharedErrors=tonumber(self.metrics.sharedErrors) or 0,
        scans=tonumber(statusScanDiagnostics and statusScanDiagnostics.scans) or 0,
        sharedScans=tonumber(statusScanDiagnostics and statusScanDiagnostics.sharedScans) or 0,
        directScans=tonumber(statusScanDiagnostics and statusScanDiagnostics.directScans) or 0,
        lastSource=tostring(statusScanDiagnostics and statusScanDiagnostics.lastSource or "none"),
        skippedNoId=tonumber(statusScanDiagnostics and statusScanDiagnostics.skippedNoId) or 0,
        tooltipOnly=tonumber(statusScanDiagnostics and statusScanDiagnostics.tooltipOnly) or 0,
    }
end

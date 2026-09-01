ReplicatedSuiteModuleSandbox:Enter('healer', {'ReplicatedHealerBoot', 'ReplicatedHealerConfig', 'ReplicatedHealerModule'})
------------------------------------------------------------------------
-- Replicated Healer - Roster Domain v1
--
-- Authority for Healer's team-member snapshot.
--
-- Native TEAM_MEMBERS_CHANGED is only an invalidation signal. The Domain waits
-- for Core2's native settle fence, then builds a complete roster generation in
-- slices and commits it atomically. Periodic polling remains a safety fallback.
--
-- Role reads are intentionally decoupled from the 1s roster poll. Stable
-- members reuse their previous role and the native X2Team:GetRole call is only
-- repeated after RoleRefreshMs or an explicit membership invalidation. This
-- removes the old 50/100 GetRole calls per second on an unchanged raid.
------------------------------------------------------------------------

if ReplicatedHealerCore1Loaded ~= true or ReplicatedHealerApi == nil then return end

ReplicatedHealerRoster = ReplicatedHealerRoster or {}
local R = ReplicatedHealerRoster
local A = ReplicatedHealerApi

R.Version = "1.0"
R.SlotSliceMembers = 16
R.RoleSliceMembers = 8
R.RoleRefreshMs = 5000
R.generation = tonumber(R.generation) or 0
R.ready = R.ready == true
R.invalidated = R.invalidated ~= false
R.requestPending = R.requestPending ~= false
R.requestReason = R.requestReason or "startup"
R.forceRoles = R.forceRoles == true
R.lastRoleRefreshAt = tonumber(R.lastRoleRefreshAt) or -100000
R.metrics = R.metrics or {
    generationsStarted = 0,
    generationsCommitted = 0,
    generationsChanged = 0,
    slotReads = 0,
    roleReads = 0,
    rolesReused = 0,
    maxSlotSlice = 0,
    maxRoleSlice = 0,
    invalidations = 0,
    immediateRebuilds = 0,
    reclassifications = 0,
}
R.cycle = R.cycle or {
    active = false,
    phase = "idle",
    mode = "none",
    playerName = nil,
    maxSlots = 0,
    slotCursor = 1,
    roleCursor = 1,
    staged = {},
    byKey = {},
    previousByIdentity = {},
    refreshRoles = false,
    needNativeRoles = false,
    reason = nil,
}

local function DiagnosticsCount(code, delta)
    local diagnostics = ReplicatedSuite and ReplicatedSuite.DiagnosticsManager or nil
    if diagnostics ~= nil and type(diagnostics.Count) == "function" then
        diagnostics:Count("healer_roster", code, delta or 1)
    end
end

local function ClearArray(value)
    if type(value) ~= "table" then return {} end
    for index = #value, 1, -1 do value[index] = nil end
    return value
end

local function ClearMap(value)
    if type(value) ~= "table" then return {} end
    for key in pairs(value) do value[key] = nil end
    return value
end

local function IdentityKey(name, raidIndex, memberIndex)
    return tostring(raidIndex or 1) .. ":" .. tostring(memberIndex or 0) .. ":" .. tostring(name or "")
end

function R:GetUnitKey(raidIndex, memberIndex, unitId, name)
    return tostring(raidIndex or 1) .. ":" .. tostring(memberIndex or 0) .. ":" .. tostring(unitId or "") .. ":" .. tostring(name or "")
end

function R:FindNormalRaidUnit(memberIndex)
    local unitId = string.format("team%d", memberIndex)
    local name = A:CallUnit("UnitName", unitId)
    if name ~= nil then return unitId, name end
    unitId = string.format("team%02d", memberIndex)
    name = A:CallUnit("UnitName", unitId)
    if name ~= nil then return unitId, name end
    return nil, nil
end

function R:FindCoRaidUnit(raidIndex, memberIndex)
    local unitId = string.format("team_%d_%d", raidIndex, memberIndex)
    local name = A:CallUnit("UnitName", unitId)
    if name ~= nil then return unitId, name end
    unitId = string.format("team_%02d_%02d", raidIndex, memberIndex)
    name = A:CallUnit("UnitName", unitId)
    if name ~= nil then return unitId, name end
    return nil, nil
end

function R:_ResetCycle()
    local cycle = self.cycle
    cycle.active = false
    cycle.phase = "idle"
    cycle.mode = "none"
    cycle.playerName = nil
    cycle.maxSlots = 0
    cycle.slotCursor = 1
    cycle.roleCursor = 1
    cycle.refreshRoles = false
    cycle.needNativeRoles = false
    cycle.reason = nil
    cycle.staged = ClearArray(cycle.staged)
    cycle.byKey = ClearMap(cycle.byKey)
    cycle.previousByIdentity = ClearMap(cycle.previousByIdentity)
end

function R:Request(reason, forceRoles)
    reason = tostring(reason or "request")
    if reason == "fallback_poll" and (self.requestPending == true or self.cycle.active == true) then
        return false
    end
    self.requestPending = true
    self.requestReason = reason
    if forceRoles == true then self.forceRoles = true end
    return true
end

function R:Invalidate(clearCommitted, reason)
    self.metrics.invalidations = (tonumber(self.metrics.invalidations) or 0) + 1
    self:_ResetCycle()
    self.ready = false
    self.invalidated = true
    self:Request(reason or "invalidate", true)
    if clearCommitted == true then
        roster = {}
        rosterByKey = {}
        rosterMode = "none"
    end
    DiagnosticsCount("ROSTER_INVALIDATED", 1)
end

function R:_BuildPreviousIndex()
    local index = self.cycle.previousByIdentity
    ClearMap(index)
    for _, member in ipairs(roster or {}) do
        if member ~= nil then
            index[IdentityKey(member.name, member.raidIndex, member.memberIndex)] = member
        end
    end
end

function R:_ShouldRefreshRoles(forceRoles)
    if forceRoles == true then return true end
    local now = tonumber(animationClock) or 0
    return now - (tonumber(self.lastRoleRefreshAt) or -100000) >= math.max(1000, tonumber(self.RoleRefreshMs) or 5000)
end

function R:StartGeneration(reason, forceRoles)
    if self.cycle.active == true then return false, "active" end

    self.requestPending = false
    reason = tostring(reason or self.requestReason or "poll")
    forceRoles = forceRoles == true or self.forceRoles == true
    self.forceRoles = false

    local cycle = self.cycle
    self:_ResetCycle()
    cycle = self.cycle
    cycle.active = true
    cycle.phase = "slots"
    cycle.reason = reason
    cycle.playerName = A:CallUnit("UnitName", "player")
    cycle.needNativeRoles = state ~= nil and state.roleScoringEnabled == true
    cycle.refreshRoles = cycle.needNativeRoles and self:_ShouldRefreshRoles(forceRoles) or false
    self:_BuildPreviousIndex()

    local _, coName = self:FindCoRaidUnit(1, 1)
    local _, normalName = self:FindNormalRaidUnit(1)
    if coName ~= nil then
        cycle.mode = "coraid"
        cycle.maxSlots = MAX_CO_RAID_MEMBERS or 100
    elseif normalName ~= nil then
        cycle.mode = "raid"
        cycle.maxSlots = MAX_RAID_MEMBERS or 50
    elseif cycle.playerName ~= nil then
        cycle.mode = "solo"
        cycle.maxSlots = 0
        local member = {
            unitId = "player",
            name = cycle.playerName,
            raidIndex = 1,
            memberIndex = 1,
            isSelf = true,
            officialRole = nil,
            roleResolved = true,
        }
        member.key = self:GetUnitKey(1, 1, "player", cycle.playerName)
        member.role = 1
        cycle.staged[1] = member
        cycle.byKey[member.key] = member
        cycle.phase = "commit"
    else
        cycle.mode = "none"
        cycle.maxSlots = 0
        cycle.phase = "commit"
    end

    self.metrics.generationsStarted = (tonumber(self.metrics.generationsStarted) or 0) + 1
    DiagnosticsCount("ROSTER_GENERATION_STARTED", 1)
    return true
end

function R:_AppendMember(unitId, name, raidIndex, memberIndex)
    local cycle = self.cycle
    local previous = cycle.previousByIdentity[IdentityKey(name, raidIndex, memberIndex)]
    local member = {
        unitId = unitId,
        name = name,
        raidIndex = raidIndex,
        memberIndex = memberIndex,
        isSelf = cycle.playerName ~= nil and name == cycle.playerName,
        officialRole = nil,
        roleResolved = false,
    }
    member.key = self:GetUnitKey(raidIndex, memberIndex, unitId, name)

    if cycle.needNativeRoles ~= true then
        -- Role score is disabled: do not touch X2Team:GetRole at all. Overrides
        -- are still applied by ClassifyRole(), but GetRoleScore() returns zero.
        if previous ~= nil then member.officialRole = previous.officialRole end
        member.roleResolved = true
        self.metrics.rolesReused = (tonumber(self.metrics.rolesReused) or 0) + (previous ~= nil and 1 or 0)
    elseif previous ~= nil and cycle.refreshRoles ~= true then
        member.officialRole = previous.officialRole
        member.roleResolved = true
        self.metrics.rolesReused = (tonumber(self.metrics.rolesReused) or 0) + 1
    end

    cycle.staged[#cycle.staged + 1] = member
    cycle.byKey[member.key] = member
end

function R:RunSlotSlice(maxMembers)
    local cycle = self.cycle
    if cycle.active ~= true or cycle.phase ~= "slots" then return false end

    maxMembers = math.max(1, math.floor(tonumber(maxMembers) or tonumber(self.SlotSliceMembers) or 16))
    local processed = 0
    while cycle.slotCursor <= cycle.maxSlots and processed < maxMembers do
        local slot = cycle.slotCursor
        local raidIndex, memberIndex, unitId, name
        if cycle.mode == "coraid" then
            raidIndex = math.floor((slot - 1) / (MAX_RAID_MEMBERS or 50)) + 1
            memberIndex = ((slot - 1) % (MAX_RAID_MEMBERS or 50)) + 1
            unitId, name = self:FindCoRaidUnit(raidIndex, memberIndex)
        else
            raidIndex = 1
            memberIndex = slot
            unitId, name = self:FindNormalRaidUnit(memberIndex)
        end
        if unitId ~= nil and name ~= nil then self:_AppendMember(unitId, name, raidIndex, memberIndex) end
        cycle.slotCursor = slot + 1
        processed = processed + 1
    end

    self.metrics.slotReads = (tonumber(self.metrics.slotReads) or 0) + processed
    self.metrics.maxSlotSlice = math.max(tonumber(self.metrics.maxSlotSlice) or 0, processed)

    if cycle.slotCursor > cycle.maxSlots then
        cycle.roleCursor = 1
        cycle.phase = "roles"
    end
    return true
end

function R:RunRoleSlice(maxMembers)
    local cycle = self.cycle
    if cycle.active ~= true or cycle.phase ~= "roles" then return false end

    maxMembers = math.max(1, math.floor(tonumber(maxMembers) or tonumber(self.RoleSliceMembers) or 8))
    local nativeReads = 0
    while cycle.roleCursor <= #cycle.staged and nativeReads < maxMembers do
        local member = cycle.staged[cycle.roleCursor]
        if member ~= nil and member.roleResolved ~= true then
            member.officialRole = A:GetRole(member.raidIndex, member.memberIndex)
            member.roleResolved = true
            nativeReads = nativeReads + 1
            self.metrics.roleReads = (tonumber(self.metrics.roleReads) or 0) + 1
        end
        cycle.roleCursor = cycle.roleCursor + 1
    end
    self.metrics.maxRoleSlice = math.max(tonumber(self.metrics.maxRoleSlice) or 0, nativeReads)

    if cycle.roleCursor > #cycle.staged then
        if cycle.refreshRoles == true then self.lastRoleRefreshAt = tonumber(animationClock) or 0 end
        cycle.phase = "commit"
    end
    return true
end

local function BuildCommittedSignature(mode, members)
    local parts = { tostring(mode or "none"), ":", tostring(#(members or {})) }
    for _, member in ipairs(members or {}) do
        parts[#parts + 1] = "|"
        parts[#parts + 1] = tostring(member.key or "")
        parts[#parts + 1] = "@"
        parts[#parts + 1] = tostring(member.role or 0)
    end
    return table.concat(parts)
end

function R:Commit()
    local cycle = self.cycle
    if cycle.active ~= true or cycle.phase ~= "commit" then return false end

    for _, member in ipairs(cycle.staged) do
        if member.role == nil then member.role = ClassifyRole(member) end
    end

    local oldSignature = BuildCommittedSignature(rosterMode, roster)
    local newSignature = BuildCommittedSignature(cycle.mode, cycle.staged)

    roster = cycle.staged
    rosterByKey = cycle.byKey
    rosterMode = cycle.mode

    -- Detach committed containers from the staging cycle before resetting it.
    cycle.staged = {}
    cycle.byKey = {}
    cycle.previousByIdentity = {}
    cycle.active = false
    cycle.phase = "idle"

    self.generation = (tonumber(self.generation) or 0) + 1
    self.ready = true
    self.invalidated = false
    self.metrics.generationsCommitted = (tonumber(self.metrics.generationsCommitted) or 0) + 1
    if oldSignature ~= newSignature then
        self.metrics.generationsChanged = (tonumber(self.metrics.generationsChanged) or 0) + 1
        DiagnosticsCount("ROSTER_GENERATION_CHANGED", 1)
    end
    DiagnosticsCount("ROSTER_GENERATION_COMMITTED", 1)

    if ReplicatedHealerRuntime ~= nil and type(ReplicatedHealerRuntime.OnRosterRebuilt) == "function" then
        ReplicatedHealerRuntime:OnRosterRebuilt()
    end
    return true
end

function R:RunSlice(slotBudget, roleBudget)
    if self.cycle.active ~= true then
        if self.requestPending ~= true then return false end
        self:StartGeneration(self.requestReason, self.forceRoles)
    end

    local phase = self.cycle.phase
    if phase == "slots" then
        self:RunSlotSlice(slotBudget)
    elseif phase == "roles" then
        self:RunRoleSlice(roleBudget)
    end
    if self.cycle.phase == "commit" then self:Commit() end
    return true
end

function R:RebuildImmediate(reason, forceRoles)
    self.metrics.immediateRebuilds = (tonumber(self.metrics.immediateRebuilds) or 0) + 1
    self:_ResetCycle()
    self.requestPending = false
    self.forceRoles = false
    self:StartGeneration(reason or "immediate", forceRoles == true)
    local guard = 0
    while self.cycle.active == true and guard < 32 do
        guard = guard + 1
        if self.cycle.phase == "slots" then
            self:RunSlotSlice(MAX_CO_RAID_MEMBERS or 100)
        elseif self.cycle.phase == "roles" then
            self:RunRoleSlice(MAX_CO_RAID_MEMBERS or 100)
        elseif self.cycle.phase == "commit" then
            self:Commit()
        else
            break
        end
    end
    if self.cycle.active == true then
        DiagnosticsCount("ROSTER_IMMEDIATE_GUARD_HIT", 1)
        return false
    end
    return true
end

function R:Reclassify()
    local changed = false
    for _, member in ipairs(roster or {}) do
        local nextRole = ClassifyRole(member)
        if tonumber(member.role) ~= tonumber(nextRole) then
            member.role = nextRole
            changed = true
        end
    end
    self.metrics.reclassifications = (tonumber(self.metrics.reclassifications) or 0) + 1
    if changed and ReplicatedHealerRuntime ~= nil and type(ReplicatedHealerRuntime.OnRosterRebuilt) == "function" then
        ReplicatedHealerRuntime:OnRosterRebuilt()
    end
    return changed
end

function R:IsReady()
    -- A soft fallback poll may build the next generation while the last
    -- committed roster remains safe to consume. Hard invalidation (membership
    -- event/startup) closes the gate until the new atomic generation commits.
    return self.ready == true and self.invalidated ~= true
end

function R:Describe()
    return {
        version = tostring(self.Version or "?"),
        generation = tonumber(self.generation) or 0,
        ready = self:IsReady(),
        invalidated = self.invalidated == true,
        requestPending = self.requestPending == true,
        requestReason = tostring(self.requestReason or ""),
        mode = tostring(rosterMode or "none"),
        count = #(roster or {}),
        cycle = {
            active = self.cycle.active == true,
            phase = tostring(self.cycle.phase or "idle"),
            slotCursor = tonumber(self.cycle.slotCursor) or 1,
            maxSlots = tonumber(self.cycle.maxSlots) or 0,
            roleCursor = tonumber(self.cycle.roleCursor) or 1,
            staged = #(self.cycle.staged or {}),
            refreshRoles = self.cycle.refreshRoles == true,
            needNativeRoles = self.cycle.needNativeRoles == true,
        },
        metrics = {
            generationsStarted = tonumber(self.metrics.generationsStarted) or 0,
            generationsCommitted = tonumber(self.metrics.generationsCommitted) or 0,
            generationsChanged = tonumber(self.metrics.generationsChanged) or 0,
            slotReads = tonumber(self.metrics.slotReads) or 0,
            roleReads = tonumber(self.metrics.roleReads) or 0,
            rolesReused = tonumber(self.metrics.rolesReused) or 0,
            maxSlotSlice = tonumber(self.metrics.maxSlotSlice) or 0,
            maxRoleSlice = tonumber(self.metrics.maxRoleSlice) or 0,
            invalidations = tonumber(self.metrics.invalidations) or 0,
            immediateRebuilds = tonumber(self.metrics.immediateRebuilds) or 0,
            reclassifications = tonumber(self.metrics.reclassifications) or 0,
        },
    }
end

-- Compatibility facade for historical Core code. Periodic Runtime code uses the
-- sliced Domain API directly; RebuildRoster() is retained only for explicit
-- user/operator actions that require an immediate snapshot.
function GetUnitKey(raidIndex, memberIndex, unitId, name)
    return R:GetUnitKey(raidIndex, memberIndex, unitId, name)
end

function FindNormalRaidUnit(memberIndex)
    return R:FindNormalRaidUnit(memberIndex)
end

function FindCoRaidUnit(raidIndex, memberIndex)
    return R:FindCoRaidUnit(raidIndex, memberIndex)
end

function RebuildRoster()
    return R:RebuildImmediate("legacy_explicit", false)
end

------------------------------------------------------------------------
-- Replicated Suite V3 - Healer Roster Domain
--
-- Healer-specific projection over TeamRosterV3. TeamRoster remains the only
-- Authority that discovers team unit tokens. This Domain adds only the Healer
-- stable key / self flag / optional role classification required by the legacy
-- recommendation formula. X2Team:GetRole is read only when role scoring is on
-- and is refreshed in bounded slices (5s TTL), never per health scan.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Features = S.Features or {}
S.Features.Healer = S.Features.Healer or {}
local F = S.Features.Healer
local U = S.Utils

local R = {
    version = 1,
    revision = 0,
    sourceRevision = -1,
    ready = false,
    members = {},
    byKey = {},
    roleCursor = 1,
    roleRefreshAt = -100000,
    roleRefreshMs = 5000,
    roleSliceMembers = 8,
    roleCycleActive = false,
    roleForce = false,
    metrics = {
        projections = 0, roleReads = 0, roleFailures = 0, rolesReused = 0,
        maxRoleSlice = 0, invalidations = 0,
    },
}
R.presentationBoundary = "feature_domain"
F.Roster = R

local function NowMs() return math.max(0, tonumber(S.NowMs and S.NowMs()) or 0) end
local function DeepCopy(value)
    if U ~= nil and type(U.DeepCopy) == "function" then return U.DeepCopy(value) end
    return value
end
local function Trim(value)
    if U ~= nil and type(U.Trim) == "function" then return U.Trim(value) end
    return tostring(value or ""):match("^%s*(.-)%s*$") or ""
end
local function TeamRoster() return S.Services and S.Services.TeamRosterV3 or nil end
local function Settings()
    return type(F.GetSettings) == "function" and F:GetSettings() or {}
end

local function IdentityKey(member)
    return string.format("%d:%d:%s", tonumber(member.teamIndex) or 0, tonumber(member.memberIndex) or 0, string.lower(Trim(member.name)))
end

local function ReadOfficialRole(member)
    if type(member) ~= "table" then return nil, nil end
    local teamIndex = tonumber(member.teamIndex) or 0
    local memberIndex = tonumber(member.memberIndex) or 0
    if teamIndex <= 0 or memberIndex <= 0 then return nil, nil end
    if S.Api == nil or type(S.Api.CallCapability) ~= "function" then return nil, "api unavailable" end
    local ok, value, err = S.Api:CallCapability("X2Team:GetRole", X2Team, "GetRole", teamIndex, memberIndex)
    if ok ~= true then return nil, err or "role read failed" end
    return value, nil
end

local function ClassifyRole(member, settings)
    settings = type(settings) == "table" and settings or {}
    local overrides = type(settings.roleOverrides) == "table" and settings.roleOverrides or {}
    local override = overrides[member.name]
    if override ~= nil then
        local value = math.floor(tonumber(override) or 1)
        if value < 1 then value = 1 elseif value > 5 then value = 5 end
        return value
    end
    local raw = member.officialRole
    if raw == nil and member.isSelf == true and (tonumber(member.teamIndex) or 0) <= 0 then return 1 end
    if raw == nil then return 5 end
    local text = string.lower(tostring(raw))
    if string.find(text, "main", 1, true) and string.find(text, "tank", 1, true) then return 2 end
    if string.find(text, "tank", 1, true) then return 3 end
    if string.find(text, "heal", 1, true) then return 4 end
    local numeric = tonumber(raw)
    if numeric == 1 then return 2 end
    if numeric == 2 then return 4 end
    if numeric ~= nil and numeric > 0 then return 1 end
    return 5
end

function R:Invalidate(reason)
    self.ready = false
    self.roleCycleActive = false
    self.roleCursor = 1
    self.roleForce = true
    self.metrics.invalidations = (tonumber(self.metrics.invalidations) or 0) + 1
    return true
end

function R:SyncFromShared(reason, forceRoles)
    local service = TeamRoster()
    if type(service) ~= "table" or type(service.GetSnapshot) ~= "function" then return false, "TeamRosterV3 unavailable" end
    local snapshot = service:GetSnapshot()
    if type(snapshot) ~= "table" then return false, "TeamRosterV3 snapshot unavailable" end
    local settings = Settings()
    local previous = self.byKey or {}
    local nextMembers, nextByKey = {}, {}

    for _, row in ipairs(type(snapshot.members) == "table" and snapshot.members or {}) do
        local name = Trim(row.name)
        local token = tostring(row.unitToken or "")
        if name ~= "" and token ~= "" then
            local member = {
                name = name,
                unitToken = token,
                unitId = token,
                teamIndex = tonumber(row.teamIndex) or 0,
                raidIndex = math.max(1, tonumber(row.teamIndex) or 1),
                memberIndex = math.max(1, tonumber(row.memberIndex) or 1),
                isSelf = token == "player",
                officialRole = nil,
                role = nil,
            }
            member.key = IdentityKey(member)
            local old = previous[member.key]
            if type(old) == "table" then
                member.officialRole = old.officialRole
                member.role = old.role
                self.metrics.rolesReused = (tonumber(self.metrics.rolesReused) or 0) + 1
            end
            nextMembers[#nextMembers + 1] = member
            nextByKey[member.key] = member
        end
    end

    self.members, self.byKey = nextMembers, nextByKey
    self.sourceRevision = tonumber(snapshot.revision) or self.sourceRevision
    self.revision = self.revision + 1
    self.metrics.projections = (tonumber(self.metrics.projections) or 0) + 1

    local needRoles = settings.roleScoringEnabled == true
    local roleExpired = NowMs() - (tonumber(self.roleRefreshAt) or -100000) >= self.roleRefreshMs
    self.roleCycleActive = needRoles and (#nextMembers > 0) and (forceRoles == true or self.roleForce == true or roleExpired)
    self.roleCursor = 1
    self.roleForce = false
    if self.roleCycleActive ~= true then
        for _, member in ipairs(self.members) do member.role = ClassifyRole(member, settings) end
        self.ready = true
    else
        self.ready = false
    end
    return true
end

function R:RunRoleSlice()
    if self.roleCycleActive ~= true then return self.ready == true end
    local settings = Settings()
    if settings.roleScoringEnabled ~= true then
        self.roleCycleActive = false
        for _, member in ipairs(self.members) do member.role = ClassifyRole(member, settings) end
        self.ready = true
        return true
    end

    local reads = 0
    local maximum = math.max(1, math.floor(tonumber(self.roleSliceMembers) or 8))
    while self.roleCursor <= #self.members and reads < maximum do
        local member = self.members[self.roleCursor]
        if member ~= nil and (tonumber(member.teamIndex) or 0) > 0 and (tonumber(member.memberIndex) or 0) > 0 then
            local value, err = ReadOfficialRole(member)
            reads = reads + 1
            self.metrics.roleReads = (tonumber(self.metrics.roleReads) or 0) + 1
            if err ~= nil then self.metrics.roleFailures = (tonumber(self.metrics.roleFailures) or 0) + 1 end
            if value ~= nil then member.officialRole = value end
        end
        if member ~= nil then member.role = ClassifyRole(member, settings) end
        self.roleCursor = self.roleCursor + 1
    end
    self.metrics.maxRoleSlice = math.max(tonumber(self.metrics.maxRoleSlice) or 0, reads)

    if self.roleCursor > #self.members then
        self.roleCycleActive = false
        self.roleCursor = 1
        self.roleRefreshAt = NowMs()
        for _, member in ipairs(self.members) do
            if member.role == nil then member.role = ClassifyRole(member, settings) end
        end
        self.ready = true
        self.revision = self.revision + 1
        return true
    end
    return false
end

function R:RefreshRolesIfDue()
    local settings = Settings()
    if settings.roleScoringEnabled ~= true then return false end
    if self.roleCycleActive == true then return true end
    if NowMs() - (tonumber(self.roleRefreshAt) or -100000) < self.roleRefreshMs then return false end
    self.roleCycleActive = #self.members > 0
    self.roleCursor = 1
    if self.roleCycleActive then self.ready = false end
    return self.roleCycleActive
end

function R:IsReady() return self.ready == true end
function R:GetSnapshot()
    return { revision = self.revision, sourceRevision = self.sourceRevision, count = #self.members, members = DeepCopy(self.members) }
end
function R:GetHealth()
    return {
        version = self.version,
        ready = self.ready == true,
        members = #self.members,
        revision = self.revision,
        sourceRevision = self.sourceRevision,
        roleCycleActive = self.roleCycleActive == true,
        roleReads = tonumber(self.metrics.roleReads) or 0,
        roleFailures = tonumber(self.metrics.roleFailures) or 0,
        rolesReused = tonumber(self.metrics.rolesReused) or 0,
        maxRoleSlice = tonumber(self.metrics.maxRoleSlice) or 0,
        projections = tonumber(self.metrics.projections) or 0,
        invalidations = tonumber(self.metrics.invalidations) or 0,
    }
end

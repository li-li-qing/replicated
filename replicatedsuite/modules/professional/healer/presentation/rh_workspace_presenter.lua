ReplicatedSuiteModuleSandbox:Enter('healer', {'ReplicatedHealerBoot', 'ReplicatedHealerConfig', 'ReplicatedHealerModule'})
------------------------------------------------------------------------
-- Replicated Healer - Combat Workspace Presenter v1
--
-- Read-only projection bridge for the Suite M5-v3 Healer workspace.
--
-- Authority boundary:
--   * Roster remains owned by domain/rh_roster.lua.
--   * Health / Recommendation remains owned by domain/rh_recommendation.lua.
--   * Status cache remains owned by domain/rh_status_cache.lua.
--   * Settings mutations remain owned by rh_settings_presenter + SettingsModel.
--   * This presenter NEVER calls X2Unit/X2Team and NEVER starts a synchronous
--     roster/status scan from the workspace refresh lane.
--
-- Performance contract:
--   * snapshots are bounded by the committed raid roster (<= 100 members);
--   * the Suite polls cheap revision counters first and only rebuilds TableView
--     rows when a committed generation actually changed;
--   * member status projection reads the committed cache only and is performed
--     for the selected member, never for the full roster on a timer.
------------------------------------------------------------------------

if ReplicatedHealerCore1Loaded ~= true or type(ReplicatedHealerModule) ~= "table" then return end

ReplicatedHealerWorkspacePresenter = ReplicatedHealerWorkspacePresenter or {}
local P = ReplicatedHealerWorkspacePresenter
local HM = ReplicatedHealerModule
P.Version = "1.0"
P.metrics = P.metrics or {
    revisions = 0,
    recommendationSnapshots = 0,
    rosterSnapshots = 0,
    memberSnapshots = 0,
    statusSnapshots = 0,
}

local function CopyColorSafe(color)
    if type(color) ~= "table" then return nil end
    return {
        r = tonumber(color.r) or 1,
        g = tonumber(color.g) or 1,
        b = tonumber(color.b) or 1,
        a = tonumber(color.a) or 1,
    }
end

local function RecommendationRevision()
    local domain = ReplicatedHealerRecommendation
    return tonumber(domain and domain.metrics and domain.metrics.publications) or 0
end

local function RosterGeneration()
    return tonumber(ReplicatedHealerRoster and ReplicatedHealerRoster.generation) or 0
end

local function HealthGeneration()
    return tonumber(ReplicatedHealerRuntime and ReplicatedHealerRuntime.healthGeneration) or 0
end

local function StatusGeneration()
    return tonumber(ReplicatedHealerRuntime and ReplicatedHealerRuntime.statusGeneration) or 0
end

local function FindRecommendation(key)
    key = tostring(key or "")
    if key == "" then return nil end
    for _, row in ipairs(recommendations or {}) do
        if tostring(row and row.key or "") == key then return row end
    end
    return nil
end

local function FindMember(key)
    key = tostring(key or "")
    if key == "" then return nil end
    if type(rosterByKey) == "table" and rosterByKey[key] ~= nil then return rosterByKey[key] end
    for _, member in ipairs(roster or {}) do
        if tostring(member and member.key or "") == key then return member end
    end
    return nil
end

local function ProjectRecommendation(row)
    if type(row) ~= "table" then return nil end
    return {
        key = tostring(row.key or ""),
        unitId = row.unitId,
        name = tostring(row.name or "未知成员"),
        rank = tonumber(row.rank) or 0,
        raidIndex = tonumber(row.raidIndex) or 1,
        memberIndex = tonumber(row.memberIndex) or 0,
        isSelf = row.isSelf == true,
        role = tonumber(row.role) or 1,
        currentHealth = tonumber(row.currentHealth) or 0,
        maxHealth = tonumber(row.maxHealth) or 0,
        missingHealth = tonumber(row.missingHealth) or 0,
        healthPercent = tonumber(row.healthPercent) or 0,
        distance = tonumber(row.distance),
        baseScore = tonumber(row.baseScore) or 0,
        finalScore = tonumber(row.finalScore) or 0,
        level = tonumber(row.level) or 1,
        forceEmergency = row.forceEmergency == true,
        visualPriority = tonumber(row.visualPriority) or 0,
        hasProtection = row.hasProtection == true,
        color = CopyColorSafe(row.color),
        colorReason = tostring(row.colorReason or ""),
        reason = tostring(row.reason or ""),
    }
end

function HM:GetWorkspaceRevisions()
    P.metrics.revisions = (tonumber(P.metrics.revisions) or 0) + 1
    return {
        recommendation = RecommendationRevision(),
        roster = RosterGeneration(),
        health = HealthGeneration(),
        status = StatusGeneration(),
        rosterMode = tostring(rosterMode or "none"),
        rosterCount = #(roster or {}),
        recommendationCount = #(recommendations or {}),
        unavailableCount = #(unavailable or {}),
        runtimeEnabled = state ~= nil and state.enabled == true,
        rosterReady = ReplicatedHealerRoster ~= nil and type(ReplicatedHealerRoster.IsReady) == "function"
            and ReplicatedHealerRoster:IsReady() == true or false,
    }
end

function HM:GetWorkspaceRecommendations(limit)
    P.metrics.recommendationSnapshots = (tonumber(P.metrics.recommendationSnapshots) or 0) + 1
    limit = math.max(1, math.min(100, math.floor(tonumber(limit) or 100)))
    local out = {}
    local count = math.min(limit, #(recommendations or {}))
    for index = 1, count do out[index] = ProjectRecommendation(recommendations[index]) end
    return out, RecommendationRevision()
end

function HM:GetWorkspaceRosterSnapshot(limit)
    P.metrics.rosterSnapshots = (tonumber(P.metrics.rosterSnapshots) or 0) + 1
    limit = math.max(1, math.min(100, math.floor(tonumber(limit) or 100)))
    local rankByKey = {}
    for index, candidate in ipairs(recommendations or {}) do
        rankByKey[tostring(candidate.key or "")] = tonumber(candidate.rank) or index
    end
    local out = {}
    local count = math.min(limit, #(roster or {}))
    for index = 1, count do
        local member = roster[index]
        local key = tostring(member and member.key or "")
        local health = type(healthSnapshot) == "table" and healthSnapshot[key] or nil
        out[index] = {
            key = key,
            name = tostring(member and member.name or "未知成员"),
            raidIndex = tonumber(member and member.raidIndex) or 1,
            memberIndex = tonumber(member and member.memberIndex) or index,
            isSelf = member and member.isSelf == true or false,
            role = tonumber(member and member.role) or 1,
            recommendationRank = rankByKey[key],
            currentHealth = tonumber(health and health.currentHealth) or 0,
            maxHealth = tonumber(health and health.maxHealth) or 0,
            healthPercent = tonumber(health and health.healthPercent),
            missingHealth = tonumber(health and health.missingHealth) or 0,
            distance = tonumber(health and health.distance),
        }
    end
    return out, RosterGeneration(), HealthGeneration()
end

function HM:GetWorkspaceMemberSnapshot(key)
    P.metrics.memberSnapshots = (tonumber(P.metrics.memberSnapshots) or 0) + 1
    local member = FindMember(key)
    if member == nil then return nil end
    key = tostring(member.key or key or "")
    local health = type(healthSnapshot) == "table" and healthSnapshot[key] or nil
    local candidate = FindRecommendation(key)
    local cached = type(statusCache) == "table" and statusCache[key] or nil
    local statusCount = 0
    if type(cached) == "table" and type(cached.statuses) == "table" then
        for _ in pairs(cached.statuses) do statusCount = statusCount + 1 end
    end
    local result = ProjectRecommendation(candidate) or {
        key = key,
        name = tostring(member.name or "未知成员"),
        role = tonumber(member.role) or 1,
        raidIndex = tonumber(member.raidIndex) or 1,
        memberIndex = tonumber(member.memberIndex) or 0,
        isSelf = member.isSelf == true,
    }
    result.currentHealth = tonumber(health and health.currentHealth) or tonumber(result.currentHealth) or 0
    result.maxHealth = tonumber(health and health.maxHealth) or tonumber(result.maxHealth) or 0
    result.healthPercent = tonumber(health and health.healthPercent) or tonumber(result.healthPercent)
    result.missingHealth = tonumber(health and health.missingHealth) or tonumber(result.missingHealth) or 0
    result.distance = tonumber(health and health.distance) or tonumber(result.distance)
    result.statusCount = statusCount
    result.statusScannedAt = tonumber(cached and cached.scannedAt) or 0
    result.isRecommended = candidate ~= nil
    return result
end

function HM:GetWorkspaceCommittedStatuses(key, limit)
    P.metrics.statusSnapshots = (tonumber(P.metrics.statusSnapshots) or 0) + 1
    key = tostring(key or "")
    local cached = type(statusCache) == "table" and statusCache[key] or nil
    if type(cached) ~= "table" or type(cached.statuses) ~= "table" then return {}, 0 end
    limit = math.max(1, math.min(64, math.floor(tonumber(limit) or 24)))
    local rows = {}
    for _, status in pairs(cached.statuses) do
        if type(status) == "table" then
            rows[#rows + 1] = {
                id = tonumber(status.id) or 0,
                name = tostring(status.name or status.id or "未知状态"),
                stack = tonumber(status.stack) or 1,
                sourceMask = tonumber(status.sourceMask) or 0,
                timeLeftMs = tonumber(status.timeLeft),
                timeKnown = status.timeKnown == true,
            }
        end
    end
    table.sort(rows, function(a, b)
        if a.name ~= b.name then return a.name < b.name end
        return a.id < b.id
    end)
    local total = #rows
    for index = total, limit + 1, -1 do rows[index] = nil end
    return rows, total
end

function P:Describe()
    return {
        version = tostring(self.Version or "?"),
        revisions = tonumber(self.metrics.revisions) or 0,
        recommendationSnapshots = tonumber(self.metrics.recommendationSnapshots) or 0,
        rosterSnapshots = tonumber(self.metrics.rosterSnapshots) or 0,
        memberSnapshots = tonumber(self.metrics.memberSnapshots) or 0,
        statusSnapshots = tonumber(self.metrics.statusSnapshots) or 0,
    }
end

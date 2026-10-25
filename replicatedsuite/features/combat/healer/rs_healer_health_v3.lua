-- Replicated Suite · 治疗助手健康观察
-- 作者：Replicated
-- QQ群：1104129461
-- 准确性优先的切片观察：成员仅来自 TeamRosterV3，治疗策略归 Recommendation；每 Scheduler 切片最多读取20人健康/距离，周期/定向 Aura 每片最多8人。
-- 本文件不持久化、不拥有 OnUpdate，仅在 combat_healer 启用时由共享 Scheduler 驱动；Generation 完整暂存后原子发布；不可读 Aura 为 unknown，禁止解释为无 Buff。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Features = S.Features or {}
S.Features.Healer = S.Features.Healer or {}
local F = S.Features.Healer

local H = {
    version = 1,
    running = false,
    taskName = "v3_healer_runtime",
    healthSliceMembers = 20,
    statusSliceMembers = 8,
    statusGeneration = 0,
    healthGeneration = 0,
    lastHealthStartedAt = -100000,
    lastStatusStartedAt = -100000,
    health = {
        active = false, cursor = 1, members = {}, snapshot = nil,
        recommendations = {}, unavailable = {}, candidateMemory = nil,
        statusUpdates = nil, pendingMember = nil, pendingSnapshot = nil,
        statusDisplayTracking = false, startedAt = 0,
    },
    status = { active = false, cursor = 1, members = {}, cache = nil, startedAt = 0 },
    metrics = {
        rosterChanges = 0, runtimeStarts = 0, runtimeStops = 0, runtimeResets = 0,
        healthCyclesStarted = 0, healthCyclesCompleted = 0, healthMembers = 0,
        maxHealthSlice = 0, nativeHealthReads = 0, nativeHealthFailures = 0,
        healthStatusRefreshes = 0, maxHealthStatusRefreshSlice = 0,
        statusCyclesStarted = 0, statusCyclesCompleted = 0, statusMembers = 0,
        maxStatusSlice = 0, sharedStatusAccepted = 0, nativeStatusFallbacks = 0,
        statusReadFailures = 0, unknownStatusMembers = 0,
    },
}
H.presentationBoundary = "feature_domain_runtime"
F.HealthRuntime = H

local function NowMs() return math.max(0, tonumber(S.NowMs and S.NowMs()) or 0) end
local function Settings() return type(F.GetSettings) == "function" and F:GetSettings() or {} end
local function Roster() return F.Roster end
local function Recommendation() return F.Recommendation end
local function AuraBridge() return S.Features and S.Features.HealerAuraBridge or nil end
local function Scheduler() return S.Scheduler end

-- 名单缓存仅归此 Runtime，保存公开 GetSnapshot 返回的独立副本；不借用 Roster 成员原表，
-- 也不把副本传给公开投影。健康/状态周期只读这些成员行，各自保留独立游标数组。
local cachedRoster, cachedRosterRevision, cachedRosterSnapshot
local function ClearRosterSnapshot()
    cachedRoster, cachedRosterRevision, cachedRosterSnapshot = nil, nil, nil
end

local function DiagnosticsCount(code, delta)
    local d = S.DiagnosticsManager
    if type(d) == "table" and type(d.Count) == "function" then d:Count("healer_v3", code, delta or 1) end
end

local function ClearArray(value)
    value = type(value) == "table" and value or {}
    for index = #value, 1, -1 do value[index] = nil end
    return value
end

local function CopyMembers(target)
    target = ClearArray(target)
    local roster = Roster()
    -- 对象身份与已提交 revision 同时匹配才复用；旧宿主无 revision 或职责仍在分片时逐次读取。
    -- 重新读取前先撤销旧缓存，防止暂时缺失的 revision 支持恢复后误用旧事实。
    local revision = type(roster) == "table" and type(roster.GetRevision) == "function" and roster:GetRevision() or nil
    local snapshot
    if type(revision) == "number" and roster == cachedRoster and revision == cachedRosterRevision then
        snapshot = cachedRosterSnapshot
    else
        ClearRosterSnapshot()
        snapshot = type(roster) == "table" and type(roster.GetSnapshot) == "function" and roster:GetSnapshot() or nil
        -- 只缓存同一完整版本；同步读取期间若名单被替换/失效，仍保留本次快照语义但不跨周期复用。
        if type(revision) == "number" and type(snapshot) == "table" and snapshot.revision == revision
            and Roster() == roster and roster:GetRevision() == revision then
            cachedRoster, cachedRosterRevision, cachedRosterSnapshot = roster, revision, snapshot
        end
    end
    for index, member in ipairs(type(snapshot) == "table" and type(snapshot.members) == "table" and snapshot.members or {}) do
        target[index] = member
    end
    return target
end

local function CapRead(capability, method, ...)
    if S.Api == nil or type(S.Api.CallCapability) ~= "function" then return nil, "api unavailable" end
    local ok, value, err = S.Api:CallCapability(capability, X2Unit, method, ...)
    if ok ~= true then return nil, err or (method .. " failed") end
    return value, nil
end

local function ReadDistance(unitToken, isSelf)
    local value, err = CapRead("X2Unit:UnitDistance", "UnitDistance", unitToken)
    if err ~= nil then
        if isSelf == true then return 0, nil end
        return nil, err
    end
    local distance = type(value) == "table" and tonumber(value.distance) or tonumber(value)
    if distance == nil and isSelf == true then return 0, nil end
    return distance ~= nil and math.max(0, distance) or nil, distance == nil and "distance unavailable" or nil
end

local function BuildHealthSnapshot(member)
    local current, currentErr = CapRead("X2Unit:UnitHealth", "UnitHealth", member.unitToken)
    local maximum, maximumErr = CapRead("X2Unit:UnitMaxHealth", "UnitMaxHealth", member.unitToken)
    local distance, distanceErr = ReadDistance(member.unitToken, member.isSelf)
    H.metrics.nativeHealthReads = (tonumber(H.metrics.nativeHealthReads) or 0) + 3
    current, maximum = tonumber(current), tonumber(maximum)
    if currentErr ~= nil or maximumErr ~= nil or distanceErr ~= nil
        or current == nil or maximum == nil or maximum <= 0 or distance == nil then
        H.metrics.nativeHealthFailures = (tonumber(H.metrics.nativeHealthFailures) or 0) + 1
        return nil, currentErr or maximumErr or distanceErr or "health snapshot unavailable"
    end
    local percent = current / maximum * 100
    if percent < 0 then percent = 0 elseif percent > 100 then percent = 100 end
    return {
        currentHealth = current,
        maxHealth = maximum,
        missingHealth = math.max(0, maximum - current),
        healthPercent = percent,
        distance = distance,
    }, nil
end

local function ReadAccurateStatuses(member)
    local bridge = AuraBridge()
    if type(bridge) ~= "table" or type(bridge.ReadAccurate) ~= "function" then return nil, nil, "healer aura bridge unavailable" end
    local statuses, coverage, err = bridge:ReadAccurate(member.unitToken, { ttlMs = 80, limit = 256 })
    if type(statuses) ~= "table" then
        H.metrics.statusReadFailures = (tonumber(H.metrics.statusReadFailures) or 0) + 1
        return nil, coverage, err or "status read unavailable"
    end
    if type(coverage) == "table" and coverage.source == "native_fallback" then
        H.metrics.nativeStatusFallbacks = (tonumber(H.metrics.nativeStatusFallbacks) or 0) + 1
        DiagnosticsCount("STATUS_NATIVE_FALLBACK", 1)
    else
        H.metrics.sharedStatusAccepted = (tonumber(H.metrics.sharedStatusAccepted) or 0) + 1
        DiagnosticsCount("STATUS_SHARED_ACCEPTED", 1)
    end
    return statuses, coverage, nil
end

function H:AbortCycles()
    local health = self.health
    health.active, health.cursor, health.snapshot = false, 1, nil
    health.recommendations = ClearArray(health.recommendations)
    health.unavailable = ClearArray(health.unavailable)
    health.candidateMemory, health.statusUpdates = nil, nil
    health.pendingMember, health.pendingSnapshot = nil, nil
    health.statusDisplayTracking = false
    health.members = ClearArray(health.members)

    local status = self.status
    status.active, status.cursor, status.cache = false, 1, nil
    status.members = ClearArray(status.members)
end

function H:Reset(reason, clearDomain)
    self:AbortCycles()
    -- Reset/Stop 终止派生缓存生命周期；AbortCycles 只丢暂存，可继续复用准确名单。
    ClearRosterSnapshot()
    self.statusGeneration, self.healthGeneration = 0, 0
    self.lastStatusStartedAt, self.lastHealthStartedAt = -100000, -100000
    self.metrics.runtimeResets = (tonumber(self.metrics.runtimeResets) or 0) + 1
    if clearDomain == true and type(Recommendation()) == "table" and type(Recommendation().ResetTransient) == "function" then
        Recommendation():ResetTransient(reason or "healer_runtime_reset")
    end
    return true
end

function H:OnRosterUpdated(reason)
    if self.running ~= true then return true end
    local roster = Roster()
    if type(roster) ~= "table" or type(roster.SyncFromShared) ~= "function" then return false, "healer roster domain unavailable" end
    local ok, err, changed = roster:SyncFromShared(reason or "team_roster_updated", true)
    if ok ~= true then return false, err end
    -- 即使 TeamRosterV3 已不发布无变化刷新，这里仍校验成员身份；不变名单不能清空全部推荐/健康颜色。
    if changed == false then return true end
    self.metrics.rosterChanges = (tonumber(self.metrics.rosterChanges) or 0) + 1
    -- 名单变化保留已提交快照直到下一代原子替换，避免清空后 300–600ms 闪烁。
    -- 中止旧名单周期并预置 lastHealthStartedAt，让 Step 立即重开；statusGeneration 不变。
    self:AbortCycles()
    self.lastHealthStartedAt = -100000
    DiagnosticsCount("ROSTER_GENERATION_CHANGED", 1)
    return true
end

function H:OnScoringPolicyChanged(reason)
    if self.running ~= true then return true end
    local roster = Roster()
    if type(roster) == "table" and type(roster.SyncFromShared) == "function" then
        local ok, err = roster:SyncFromShared("settings_changed:" .. tostring(reason or ""), true)
        if ok ~= true then return false, err end
    end
    self:AbortCycles()
    self.statusGeneration = 0
    self.lastHealthStartedAt, self.lastStatusStartedAt = -100000, -100000
    DiagnosticsCount("SCORING_POLICY_CHANGED", 1)
    return true
end

function H:StartStatusCycle(now)
    local cycle = self.status
    cycle.active, cycle.cursor = true, 1
    cycle.members = CopyMembers(cycle.members)
    cycle.cache = {}
    cycle.startedAt = tonumber(now) or NowMs()
    self.lastStatusStartedAt = cycle.startedAt
    self.metrics.statusCyclesStarted = (tonumber(self.metrics.statusCyclesStarted) or 0) + 1
    if #cycle.members == 0 then
        cycle.active, cycle.cache = false, nil
        if type(Recommendation()) == "table" then Recommendation():CommitStatusGeneration({}) end
        self.statusGeneration = self.statusGeneration + 1
        self.metrics.statusCyclesCompleted = (tonumber(self.metrics.statusCyclesCompleted) or 0) + 1
        self.lastHealthStartedAt = -100000
    end
    return true
end

function H:RunStatusSlice()
    local cycle = self.status
    if cycle.active ~= true then return false end
    local total = #cycle.members
    local first = cycle.cursor
    local last = math.min(total, first + math.max(1, math.floor(tonumber(self.statusSliceMembers) or 8)) - 1)
    local processed = 0
    for index = first, last do
        local member = cycle.members[index]
        if member ~= nil then
            local statuses, coverage, err = ReadAccurateStatuses(member)
            if type(statuses) == "table" then
                cycle.cache[member.key] = {
                    statuses = statuses,
                    scannedAt = type(coverage) == "table" and tonumber(coverage.scannedAt) or NowMs(),
                }
            else
                -- 当前读取 unknown 时保留最后准确行；缺失与不可读不是同一事实。
                local rec = Recommendation()
                local previous = type(rec) == "table" and rec:GetStatusRow(member.key) or nil
                if type(previous) == "table" then cycle.cache[member.key] = previous end
                self.metrics.unknownStatusMembers = (tonumber(self.metrics.unknownStatusMembers) or 0) + 1
                DiagnosticsCount("STATUS_ACCURACY_UNKNOWN", 1)
            end
            processed = processed + 1
        end
    end
    cycle.cursor = last + 1
    self.metrics.statusMembers = (tonumber(self.metrics.statusMembers) or 0) + processed
    self.metrics.maxStatusSlice = math.max(tonumber(self.metrics.maxStatusSlice) or 0, processed)

    if cycle.cursor > total then
        local committed = cycle.cache or {}
        cycle.active, cycle.cursor, cycle.cache = false, 1, nil
        cycle.members = ClearArray(cycle.members)
        Recommendation():CommitStatusGeneration(committed)
        self.statusGeneration = self.statusGeneration + 1
        self.metrics.statusCyclesCompleted = (tonumber(self.metrics.statusCyclesCompleted) or 0) + 1
        self.lastHealthStartedAt = -100000
        DiagnosticsCount("STATUS_GENERATION_COMMITTED", 1)
        return true
    end
    return false
end

function H:StartHealthCycle(now)
    local cycle = self.health
    cycle.active, cycle.cursor = true, 1
    cycle.members = CopyMembers(cycle.members)
    cycle.snapshot = {}
    cycle.recommendations = ClearArray(cycle.recommendations)
    cycle.unavailable = ClearArray(cycle.unavailable)
    cycle.candidateMemory = Recommendation():CopyCandidateMemorySnapshot()
    cycle.statusUpdates = {}
    cycle.pendingMember, cycle.pendingSnapshot = nil, nil
    cycle.statusDisplayTracking = Recommendation():HasActiveStatusDisplayTracking() == true
    cycle.startedAt = tonumber(now) or NowMs()
    self.lastHealthStartedAt = cycle.startedAt
    self.metrics.healthCyclesStarted = (tonumber(self.metrics.healthCyclesStarted) or 0) + 1
    if #cycle.members == 0 then
        cycle.active = false
        Recommendation():Publish({}, {}, {}, cycle.candidateMemory, nil)
        cycle.candidateMemory, cycle.statusUpdates = nil, nil
        self.healthGeneration = self.healthGeneration + 1
        self.metrics.healthCyclesCompleted = (tonumber(self.metrics.healthCyclesCompleted) or 0) + 1
    end
    return true
end

function H:RunHealthSlice()
    local cycle = self.health
    if cycle.active ~= true then return false end
    local total = #cycle.members
    local maxMembers = math.max(1, math.floor(tonumber(self.healthSliceMembers) or 20))
    local maxStatusRefresh = math.max(1, math.floor(tonumber(self.statusSliceMembers) or 8))
    local processed, refreshedStatuses = 0, 0

    while cycle.cursor <= total and processed < maxMembers do
        local member = cycle.members[cycle.cursor]
        if member == nil then
            cycle.cursor = cycle.cursor + 1
            processed = processed + 1
        else
            local snapshot, healthErr
            if cycle.pendingMember == member and cycle.pendingSnapshot ~= nil then
                snapshot = cycle.pendingSnapshot
            else
                snapshot, healthErr = BuildHealthSnapshot(member)
            end

            local statuses, statusReadFailed = nil, false
            if snapshot ~= nil then
                local cached = cycle.statusUpdates[member.key] or Recommendation():GetStatusRow(member.key)
                local shouldRefresh = Recommendation():ShouldRefreshMemberStatuses(
                    member, snapshot, cached, cycle.startedAt, cycle.statusDisplayTracking)
                if shouldRefresh and refreshedStatuses >= maxStatusRefresh then
                    cycle.pendingMember, cycle.pendingSnapshot = member, snapshot
                    break
                end
                if shouldRefresh then
                    local readStatuses, coverage, statusErr = ReadAccurateStatuses(member)
                    refreshedStatuses = refreshedStatuses + 1
                    if type(readStatuses) == "table" then
                        local update = {
                            statuses = readStatuses,
                            scannedAt = type(coverage) == "table" and tonumber(coverage.scannedAt) or NowMs(),
                        }
                        cycle.statusUpdates[member.key] = update
                        statuses = readStatuses
                    else
                        statusReadFailed = true
                    end
                else
                    statuses = type(cached) == "table" and cached.statuses or {}
                end
            end

            cycle.pendingMember, cycle.pendingSnapshot = nil, nil
            cycle.snapshot[member.key] = snapshot
            if snapshot == nil then
                cycle.candidateMemory[member.key] = nil
                cycle.unavailable[#cycle.unavailable + 1] = {
                    key = member.key, name = member.name, raidIndex = member.raidIndex,
                    reason = tostring(healthErr or "生命/距离读取不可用"),
                }
            elseif statusReadFailed == true then
                -- 未知状态集合不能按无保护评分，否则虚增候选分数，比暂时不可用的一行更糟。
                cycle.candidateMemory[member.key] = nil
                cycle.unavailable[#cycle.unavailable + 1] = {
                    key = member.key, name = member.name, raidIndex = member.raidIndex,
                    distance = snapshot.distance, healthPercent = snapshot.healthPercent,
                    reason = "状态读取暂不可用",
                }
                self.metrics.unknownStatusMembers = (tonumber(self.metrics.unknownStatusMembers) or 0) + 1
            else
                local candidate, unavailableCandidate = Recommendation():Evaluate(
                    member, snapshot, statuses or {}, cycle.candidateMemory, cycle.startedAt)
                if candidate ~= nil then cycle.recommendations[#cycle.recommendations + 1] = candidate end
                if unavailableCandidate ~= nil then cycle.unavailable[#cycle.unavailable + 1] = unavailableCandidate end
            end
            cycle.cursor = cycle.cursor + 1
            processed = processed + 1
        end
    end

    self.metrics.healthMembers = (tonumber(self.metrics.healthMembers) or 0) + processed
    self.metrics.maxHealthSlice = math.max(tonumber(self.metrics.maxHealthSlice) or 0, processed)
    self.metrics.healthStatusRefreshes = (tonumber(self.metrics.healthStatusRefreshes) or 0) + refreshedStatuses
    self.metrics.maxHealthStatusRefreshSlice = math.max(tonumber(self.metrics.maxHealthStatusRefreshSlice) or 0, refreshedStatuses)

    if cycle.cursor > total then
        local health = cycle.snapshot or {}
        local recommendations = cycle.recommendations or {}
        local unavailable = cycle.unavailable or {}
        local memory = cycle.candidateMemory or {}
        local statusUpdates = cycle.statusUpdates or {}
        cycle.active, cycle.cursor, cycle.snapshot = false, 1, nil
        cycle.candidateMemory, cycle.statusUpdates = nil, nil
        cycle.pendingMember, cycle.pendingSnapshot = nil, nil
        cycle.statusDisplayTracking = false
        cycle.recommendations, cycle.unavailable = {}, {}
        cycle.members = ClearArray(cycle.members)
        Recommendation():Publish(health, recommendations, unavailable, memory, statusUpdates)
        self.healthGeneration = self.healthGeneration + 1
        self.metrics.healthCyclesCompleted = (tonumber(self.metrics.healthCyclesCompleted) or 0) + 1
        DiagnosticsCount("HEALTH_GENERATION_COMMITTED", 1)
        if refreshedStatuses > 0 then DiagnosticsCount("HEALTH_TARGETED_STATUS_REFRESH", refreshedStatuses) end
        return true
    end
    if refreshedStatuses > 0 then DiagnosticsCount("HEALTH_TARGETED_STATUS_REFRESH", refreshedStatuses) end
    return false
end

function H:Step()
    if self.running ~= true then return true end
    local roster = Roster()
    if type(roster) ~= "table" then return false end

    roster:RefreshRolesIfDue()
    if roster:IsReady() ~= true then
        roster:RunRoleSlice()
        return true
    end

    local settings, now = Settings(), NowMs()
    local buffMs = math.max(200, tonumber(settings.buffScanMs) or 300)
    local healthMs = math.max(100, tonumber(settings.healthScanMs) or 150)

    if self.status.active ~= true and now - (tonumber(self.lastStatusStartedAt) or -100000) >= buffMs then
        self:StartStatusCycle(now)
    end

    -- 每代名单首次发布必须等待完整状态 Generation，保持已证明的原有顺序。
    if self.statusGeneration <= 0 then
        if self.status.active == true then self:RunStatusSlice() end
        return true
    end

    if self.health.active ~= true and now - (tonumber(self.lastHealthStartedAt) or -100000) >= healthMs then
        self:StartHealthCycle(now)
    end
    if self.health.active == true then
        self:RunHealthSlice()
        return true
    end
    if self.status.active == true then self:RunStatusSlice() end
    return true
end

function H:Start(reason)
    if self.running == true then return true end
    local scheduler = Scheduler()
    if type(scheduler) ~= "table" or type(scheduler.AddTask) ~= "function" then return false, "Suite Scheduler unavailable" end
    if type(Roster()) ~= "table" or type(Recommendation()) ~= "table" or type(AuraBridge()) ~= "table" then
        return false, "healer runtime domains unavailable"
    end
    local syncOk, syncErr = Roster():SyncFromShared(reason or "healer_start", true)
    if syncOk ~= true then return false, syncErr end
    self:Reset("healer_start", true)
    self.running = true
    local owner = self
    local added = scheduler:AddTask(self.taskName, 50, function() return owner:Step() end, true, self, "P1", 2)
    if added ~= true then self.running = false; return false, "healer scheduler task creation failed" end
    if type(scheduler.SetTaskModule) == "function" then scheduler:SetTaskModule(self.taskName, "healer") end
    self.metrics.runtimeStarts = (tonumber(self.metrics.runtimeStarts) or 0) + 1
    return true
end

function H:Stop(reason)
    -- 重复 Stop 也释放私有快照，避免停用态调用留下名单引用。
    if self.running ~= true then ClearRosterSnapshot(); return true end
    local scheduler = Scheduler()
    if type(scheduler) ~= "table" or type(scheduler.RemoveTask) ~= "function" then return false, "Suite Scheduler unavailable" end
    scheduler:RemoveTask(self.taskName)
    self.running = false
    self:Reset(reason or "healer_stop", true)
    self.metrics.runtimeStops = (tonumber(self.metrics.runtimeStops) or 0) + 1
    return true
end

function H:GetHealth()
    local m = self.metrics
    return {
        version = self.version, running = self.running == true,
        taskActive = type(Scheduler()) == "table" and type(Scheduler().tasks) == "table" and Scheduler().tasks[self.taskName] ~= nil or false,
        statusGeneration = self.statusGeneration, healthGeneration = self.healthGeneration,
        healthCycleActive = self.health.active == true, statusCycleActive = self.status.active == true,
        healthCyclesStarted = tonumber(m.healthCyclesStarted) or 0,
        healthCyclesCompleted = tonumber(m.healthCyclesCompleted) or 0,
        healthMembers = tonumber(m.healthMembers) or 0,
        maxHealthSlice = tonumber(m.maxHealthSlice) or 0,
        nativeHealthReads = tonumber(m.nativeHealthReads) or 0,
        nativeHealthFailures = tonumber(m.nativeHealthFailures) or 0,
        healthStatusRefreshes = tonumber(m.healthStatusRefreshes) or 0,
        maxHealthStatusRefreshSlice = tonumber(m.maxHealthStatusRefreshSlice) or 0,
        statusCyclesStarted = tonumber(m.statusCyclesStarted) or 0,
        statusCyclesCompleted = tonumber(m.statusCyclesCompleted) or 0,
        statusMembers = tonumber(m.statusMembers) or 0,
        maxStatusSlice = tonumber(m.maxStatusSlice) or 0,
        sharedStatusAccepted = tonumber(m.sharedStatusAccepted) or 0,
        nativeStatusFallbacks = tonumber(m.nativeStatusFallbacks) or 0,
        statusReadFailures = tonumber(m.statusReadFailures) or 0,
        unknownStatusMembers = tonumber(m.unknownStatusMembers) or 0,
        rosterChanges = tonumber(m.rosterChanges) or 0,
        runtimeStarts = tonumber(m.runtimeStarts) or 0,
        runtimeStops = tonumber(m.runtimeStops) or 0,
        runtimeResets = tonumber(m.runtimeResets) or 0,
    }
end

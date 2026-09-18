------------------------------------------------------------------------
-- Replicated Suite V3 - Team Roster Service
--
-- Lightweight read-only roster Authority shared by combat features.
-- Native TEAM_MEMBERS_CHANGED is treated only as an invalidation signal; the
-- actual UnitName scan runs from the unified Scheduler after the native raid UI
-- has settled. There is no Tick / OnUpdate loop and no write-side X2Team call.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Services = S.Services or {}

local T = {
    Id = "v3.team_roster",
    version = 7,
    members = {},
    ordered = {},
    revision = 0,
    scans = 0,
    scanFailures = 0,
    retries = 0,
    retryStreak = 0,
    retryMax = 3,
    lastRefreshAt = 0,
    consumerCount = 0,
    subscribed = false,
    refreshTask = "v3_team_roster_refresh",
    retryTask = "v3_team_roster_retry",
    settleTask = "v3_team_roster_settle",
    settleMaxPasses = 2,
    settleRefreshes = 0,
    settleScheduleFailures = 0,
    TeamEdgeSettleContractVersion = 1,
    visibleTeamIndex = nil,
    visibleTeamDetectionAvailable = false,
}
T.presentationBoundary = "service_only"
S.Services.TeamRosterV3 = T

local U = S.Utils
local function Trim(value)
    return U and U.Trim and U.Trim(value) or (tostring(value or ""):match("^%s*(.-)%s*$") or "")
end
local function NowMs() return math.max(0, tonumber(S.NowMs and S.NowMs()) or 0) end

local function SplitName(value)
    local full = string.lower(Trim(value))
    if full == "" then return "", "" end
    local base = string.match(full, "^(.-)@.+$")
    return full, (base ~= nil and base ~= "") and base or full
end

local function AddName(map, ordered, name, unitToken, teamIndex, memberIndex)
    local full, base = SplitName(name)
    if full == "" then return false end

    -- One canonical row must back both the ordered snapshot and the lookup map.
    -- The player is intentionally seeded first with the safest native token
    -- ("player"). When the same identity is later discovered in the real team
    -- slot, enrich that canonical row in place instead of replacing map[full]
    -- with a second table. Otherwise GetMember(name) and GetSnapshot().members
    -- disagree about teamIndex/memberIndex, which is fatal for role/readiness
    -- consumers even though relation membership still appears correct.
    local incomingToken = tostring(unitToken or "")
    local incomingTeam = tonumber(teamIndex) or 0
    local incomingMember = tonumber(memberIndex) or 0
    local row = map[full]
    if type(row) ~= "table" then
        row = {
            name = Trim(name),
            unitToken = incomingToken,
            teamIndex = incomingTeam,
            memberIndex = incomingMember,
        }
        ordered[#ordered + 1] = row
    else
        if Trim(row.name) == "" then row.name = Trim(name) end

        -- Preserve the special "player" token for local-unit reads. It is more
        -- stable than a raid token across party layout transitions. If the
        -- player token is discovered after a team token, promote it.
        local currentToken = tostring(row.unitToken or "")
        if incomingToken == "player" then
            row.unitToken = "player"
        elseif currentToken == "" then
            row.unitToken = incomingToken
        end

        -- A concrete team slot carries stronger roster metadata than the
        -- synthetic player seed (0/0). Keep it on the same canonical row.
        if incomingTeam > 0 and incomingMember > 0 then
            row.teamIndex = incomingTeam
            row.memberIndex = incomingMember
        end
    end

    map[full] = row
    -- COMBAT_MSG often supplies short names while UnitName may return Name@World.
    -- A short alias is safe only inside the current live roster snapshot.
    if base ~= full then map[base] = row end
    return true
end

local function ReadUnitName(unitToken)
    if S.Api == nil or type(S.Api.CallCapability) ~= "function" or X2Unit == nil then return nil end
    local ok, value = S.Api:CallCapability("X2Unit:UnitName", X2Unit, "UnitName", unitToken)
    if ok ~= true then return nil end
    value = Trim(value)
    return value ~= "" and value or nil
end

local function ResolveRosterToken(candidates)
    for _, token in ipairs(candidates) do
        local name = ReadUnitName(token)
        if name ~= nil then return token, name end
    end
    return nil, nil
end

local function ReadSingle(memberIndex)
    return ResolveRosterToken({
        string.format("team%02d", memberIndex),
        string.format("team%d", memberIndex),
    })
end

local function ReadCo(teamIndex, memberIndex)
    return ResolveRosterToken({
        string.format("team_%02d_%02d", teamIndex, memberIndex),
        string.format("team_%d_%d", teamIndex, memberIndex),
    })
end

local function DetectVisibleTeamIndex()
    local scores, comparisons = { [1] = 0, [2] = 0 }, 0
    -- In co-raid mode the unqualified teamN aliases mirror whichever native
    -- raid tab is currently visible. Compare at most ten aliases against the
    -- explicit team_1_N / team_2_N identities. This is bounded and only runs
    -- on roster refresh edges, never per frame.
    for memberIndex = 1, 10 do
        local _, aliasName = ReadSingle(memberIndex)
        if aliasName ~= nil then
            comparisons = comparisons + 1
            local _, team1Name = ReadCo(1, memberIndex)
            local _, team2Name = ReadCo(2, memberIndex)
            if team1Name ~= nil and aliasName == team1Name then scores[1] = scores[1] + 1 end
            if team2Name ~= nil and aliasName == team2Name then scores[2] = scores[2] + 1 end
        end
    end
    if comparisons > 0 and scores[1] ~= scores[2] and math.max(scores[1], scores[2]) >= 2 then
        return scores[1] > scores[2] and 1 or 2, true
    end
    return nil, false
end

function T:ScheduleRetry(delayMs, reason)
    if self.consumerCount <= 0 or self.retryStreak > self.retryMax then return false end
    if S.Scheduler == nil or type(S.Scheduler.AddOneShot) ~= "function" then return false end
    self.retries = self.retries + 1
    if type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(self.retryTask) end
    return S.Scheduler:AddOneShot(self.retryTask, math.max(200, tonumber(delayMs) or 450), function()
        return T:Refresh(reason or "retry")
    end, self, "P1", 1)
end

-- Roster identity snapshot comparison. TEAM_MEMBERS_CHANGED fires often while
-- the team layout is stable (combat callbacks, zone transitions, party-role
-- pulses). Publishing "v3.team_roster.updated" for every no-op refresh forces
-- Healer's OnRosterUpdated -> ResetTransient to wipe every recommendation/
-- health color, which the user sees as "all team colors disappear, then slowly
-- come back". Only bump revision and publish when the identity set changed.
local function SameRosterSnapshot(a, b)
    if type(a) ~= "table" or type(b) ~= "table" or #a ~= #b then return false end
    for index = 1, #a do
        local x, y = a[index], b[index]
        if type(x) ~= "table" or type(y) ~= "table" then return false end
        if tostring(x.name) ~= tostring(y.name)
            or tostring(x.unitToken) ~= tostring(y.unitToken)
            or tonumber(x.teamIndex) ~= tonumber(y.teamIndex)
            or tonumber(x.memberIndex) ~= tonumber(y.memberIndex) then
            return false
        end
    end
    return true
end

function T:Refresh(reason)
    if self.consumerCount <= 0 then return true, 0 end
    local previousVisibleTeamIndex = self.visibleTeamIndex
    local nextMembers, nextOrdered = {}, {}
    local playerName = ReadUnitName("player")
    if playerName == nil then
        -- A transient X2Unit/identity cold start must not erase a previously
        -- valid roster snapshot. Keep the last good Authority, surface the
        -- failure, and perform only a small bounded retry burst.
        self.scanFailures = self.scanFailures + 1
        self.retryStreak = self.retryStreak + 1
        self.lastRefreshAt = NowMs()
        if self.retryStreak <= self.retryMax then self:ScheduleRetry(450, "player_name_retry") end
        return true, #self.ordered
    end
    self.retryStreak = 0
    if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(self.retryTask) end
    AddName(nextMembers, nextOrdered, playerName, "player", 0, 0)

    -- Probe one packed co-raid token. If it exists, only scan that layout;
    -- otherwise scan the ordinary raid/party layout. This work happens only on
    -- demand start / roster edges, never on combat callbacks.
    local coToken = ReadCo(1, 1)
    if coToken ~= nil then
        self.visibleTeamIndex, self.visibleTeamDetectionAvailable = DetectVisibleTeamIndex()
        for teamIndex = 1, 2 do
            for memberIndex = 1, 50 do
                local token, name = ReadCo(teamIndex, memberIndex)
                if token ~= nil and name ~= nil then
                    AddName(nextMembers, nextOrdered, name, token, teamIndex, memberIndex)
                end
            end
        end
    else
        self.visibleTeamIndex, self.visibleTeamDetectionAvailable = 1, true
        for memberIndex = 1, 50 do
            local token, name = ReadSingle(memberIndex)
            if token ~= nil and name ~= nil then AddName(nextMembers, nextOrdered, name, token, 1, memberIndex) end
        end
    end

    local changed = not SameRosterSnapshot(nextOrdered, self.ordered)
        or tonumber(previousVisibleTeamIndex) ~= tonumber(self.visibleTeamIndex)
    self.members, self.ordered = nextMembers, nextOrdered
    self.lastRefreshAt = NowMs()
    -- Identity unchanged: keep the snapshot warm but do not churn consumers
    -- (Healer re-evaluation, UI refreshes) with a fake revision.
    if changed ~= true then return true, #nextOrdered end
    self.revision = self.revision + 1
    self.scans = self.scans + 1
    if S.Events ~= nil and type(S.Events.Publish) == "function" then
        S.Events:Publish("v3.team_roster.updated", self.revision, tostring(reason or "refresh"))
    end
    return true, #nextOrdered
end

function T:ScheduleRefresh(delayMs, reason)
    if self.consumerCount <= 0 then return true end
    if S.Scheduler == nil or type(S.Scheduler.AddOneShot) ~= "function" then
        return self:Refresh(reason or "refresh_without_scheduler")
    end
    S.Scheduler:RemoveTask(self.refreshTask)
    return S.Scheduler:AddOneShot(self.refreshTask, math.max(80, tonumber(delayMs) or 180), function()
        return T:Refresh(reason or "roster_settled")
    end, self, "P1", 2)
end

function T:ScheduleSettleRefresh(delayMs, reason, pass)
    if self.consumerCount <= 0 then return true end
    if S.Scheduler == nil or type(S.Scheduler.AddOneShot) ~= "function" then return false, "team roster settle scheduler unavailable" end
    pass = math.max(1, math.floor(tonumber(pass) or 1))
    if pass > math.max(1, tonumber(self.settleMaxPasses) or 2) then return true end
    -- 中文维护注释（2026-09-16，团队边沿稳定化）：RU 的 TEAM_MEMBERS_CHANGED 可能先于 teamN/native slot 真正就绪。
    -- TeamRosterV3 是团队身份 Authority，因此“晚到槽位”的补扫也必须留在 Service 内，而不是让 AutoRole/Healer 各自扫描 X2Unit。
    -- 每个原生边沿只允许最多两次 one-shot 尾随扫描：第1次约700ms、第2次再约900ms；没有 Tick/周期常驻，且新边沿会替换旧链。
    -- Refresh 仍通过 SameRosterSnapshot 只在身份/槽位真的变化时发布 v3.team_roster.updated，所以正常稳定团队不会引发额外 Consumer 重算。
    -- 兼容风险：若未来客户端槽位稳定时间超过该有界窗口，只增加此 Authority 的 pass/delay，不要在业务 Feature 新建第二套名单缓存。
    if pass == 1 and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(self.settleTask) end
    local taskReason = tostring(reason or "team_edge") .. ":settle:" .. tostring(pass)
    local scheduled = S.Scheduler:AddOneShot(self.settleTask, math.max(250, tonumber(delayMs) or 700), function()
        T.settleRefreshes = (tonumber(T.settleRefreshes) or 0) + 1
        local ok, count = T:Refresh(taskReason)
        if pass < math.max(1, tonumber(T.settleMaxPasses) or 2) and T.consumerCount > 0 then
            local nextOk = T:ScheduleSettleRefresh(900, reason, pass + 1)
            if nextOk ~= true then T.settleScheduleFailures = (tonumber(T.settleScheduleFailures) or 0) + 1 end
        end
        return ok, count
    end, self, "P2", 2)
    if scheduled ~= true then self.settleScheduleFailures = (tonumber(self.settleScheduleFailures) or 0) + 1 end
    return scheduled == true, scheduled == true and nil or "team roster settle task schedule failed"
end

function T:IsMemberName(name)
    local full, base = SplitName(name)
    if full == "" then return false end
    return self.members[full] ~= nil or self.members[base] ~= nil
end

function T:GetMember(name)
    local full, base = SplitName(name)
    local row = self.members[full] or self.members[base]
    return row ~= nil and (U and U.DeepCopy and U.DeepCopy(row) or row) or nil
end

function T:GetSnapshot()
    return {
        revision = self.revision,
        members = U and U.DeepCopy and U.DeepCopy(self.ordered) or self.ordered,
        count = #self.ordered,
        lastRefreshAt = self.lastRefreshAt,
        visibleTeamIndex = self.visibleTeamIndex,
        visibleTeamDetectionAvailable = self.visibleTeamDetectionAvailable == true,
    }
end

function T:_Start()
    if self.subscribed == true then
        local scheduled, err = self:ScheduleRefresh(80, "consumer_start")
        if scheduled ~= true then return false, err end
        return self:ScheduleSettleRefresh(700, "consumer_start", 1)
    end
    if S.Events == nil or type(S.Events.Subscribe) ~= "function" then return false, "team roster event bus unavailable" end
    local subscribed = S.Events:Subscribe("TEAM_MEMBERS_CHANGED", self, function(_, reason)
        local edgeReason = "team_members_changed:" .. tostring(reason or "")
        local primaryOk = T:ScheduleRefresh(180, edgeReason)
        local settleOk = T:ScheduleSettleRefresh(700, edgeReason, 1)
        if primaryOk ~= true or settleOk ~= true then T.settleScheduleFailures = (tonumber(T.settleScheduleFailures) or 0) + 1 end
    end)
    if subscribed ~= true then return false, "TEAM_MEMBERS_CHANGED subscribe failed" end
    self.subscribed = true
    local scheduled, err = self:ScheduleRefresh(80, "consumer_start")
    if scheduled ~= true then
        if type(S.Events.UnsubscribeOwner) == "function" then S.Events:UnsubscribeOwner(self) end
        self.subscribed = false
        return false, err or "team roster initial refresh schedule failed"
    end
    local settleScheduled, settleErr = self:ScheduleSettleRefresh(700, "consumer_start", 1)
    if settleScheduled ~= true then
        if type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(self.refreshTask) end
        if type(S.Events.UnsubscribeOwner) == "function" then S.Events:UnsubscribeOwner(self) end
        self.subscribed = false
        return false, settleErr or "team roster initial settle schedule failed"
    end
    return true
end

function T:_Stop()
    if S.Events ~= nil and type(S.Events.UnsubscribeOwner) == "function" then S.Events:UnsubscribeOwner(self) end
    if S.Scheduler ~= nil and type(S.Scheduler.RemoveOwner) == "function" then S.Scheduler:RemoveOwner(self) end
    self.subscribed = false
    self.retryStreak = 0
    self.members, self.ordered = {}, {}
    self.visibleTeamIndex, self.visibleTeamDetectionAvailable = nil, false
    self.revision = self.revision + 1
    return true
end

if S.Demand ~= nil and type(S.Demand.Create) == "function" then
    T.demand = S.Demand:Create({
        id = "service.team_roster_v3",
        owner = T,
        projectionOwner = T,
        projectionCountField = "consumerCount",
        reconcile = function(_, before, after)
            local b, a = tonumber(before and before.count) or 0, tonumber(after and after.count) or 0
            if b <= 0 and a > 0 then return T:_Start() end
            if b > 0 and a <= 0 then return T:_Stop() end
            return true
        end,
        quiesce = function() return T:_Stop() end,
    })
end

function T:AcquireConsumer(token, options)
    if self.demand == nil then return false, "team roster demand unavailable" end
    return self.demand:Acquire(token, options or {}, "team_roster_consumer")
end
function T:ReleaseConsumer(token)
    if self.demand == nil then return false, "team roster demand unavailable" end
    return self.demand:Release(token, "team_roster_consumer")
end

function T:GetHealth()
    return {
        version = self.version,
        consumers = self.consumerCount,
        members = #self.ordered,
        revision = self.revision,
        scans = self.scans,
        scanFailures = self.scanFailures,
        retries = self.retries,
        retryStreak = self.retryStreak,
        settleRefreshes = tonumber(self.settleRefreshes) or 0,
        settleScheduleFailures = tonumber(self.settleScheduleFailures) or 0,
        teamEdgeSettleContractVersion = tonumber(self.TeamEdgeSettleContractVersion) or 0,
        lastRefreshAt = self.lastRefreshAt,
        subscribed = self.subscribed == true,
        visibleTeamIndex = self.visibleTeamIndex,
        visibleTeamDetectionAvailable = self.visibleTeamDetectionAvailable == true,
    }
end

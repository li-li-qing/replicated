------------------------------------------------------------------------
-- Replicated Suite V3 - Raid Readiness Authority
--
-- Explicit, sliced raid inspection. There is no Tick and no permanent Aura
-- scan. TeamRoster owns roster identity; AuraObservation owns Buff facts; this
-- Authority only combines those shared facts with low-frequency read-only
-- role/gear/distance observations into a bounded session projection.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Features = S.Features or {}
S.Features.RaidReadiness = S.Features.RaidReadiness or {}
local F = S.Features.RaidReadiness
local U = S.Utils

local A = {
    version = 1,
    revision = 0,
    rows = {},
    byKey = {},
    summary = { total = 0, ready = 0, failed = 0, unknown = 0, info = 0 },
    scan = { active = false, generation = 0, cursor = 0, total = 0, completed = 0, reason = "idle" },
    metrics = { scans = 0, cancelled = 0, membersRead = 0, gearFailures = 0, roleFailures = 0, distanceFailures = 0, auraUnknown = 0 },
}
A.presentationBoundary = "feature_projection"
F.Authority = A

local function NowMs() return math.max(0, tonumber(S.NowMs and S.NowMs()) or 0) end
local function Trim(value)
    if U ~= nil and type(U.Trim) == "function" then return U.Trim(value) end
    return tostring(value or ""):match("^%s*(.-)%s*$") or ""
end
local function Copy(value)
    if U ~= nil and type(U.DeepCopy) == "function" then return U.DeepCopy(value) end
    return value
end
local function Number(value)
    local n = tonumber(value)
    if n == nil or n ~= n then return nil end
    return n
end

local ROLE_FALLBACK = { [0] = "未标记", [1] = "坦克", [2] = "治疗", [3] = "输出", [4] = "远程输出" }

local function RoleLabel(value, member)
    if member ~= nil and tonumber(member.teamIndex) == 0 then return "自己" end
    value = tonumber(value)
    if value == nil then return "未知" end
    if TMROLE_TANKER ~= nil and value == tonumber(TMROLE_TANKER) then return "坦克" end
    if TMROLE_HEALER ~= nil and value == tonumber(TMROLE_HEALER) then return "治疗" end
    if TMROLE_DEALER ~= nil and value == tonumber(TMROLE_DEALER) then return "输出" end
    if TMROLE_RANGED_DEALER ~= nil and value == tonumber(TMROLE_RANGED_DEALER) then return "远程输出" end
    if TMROLE_NONE ~= nil and value == tonumber(TMROLE_NONE) then return "未标记" end

    -- Some RU builds expose the numeric role but not the TMROLE_* globals.
    -- These values are already used by the existing team utility service; keep
    -- the fallback presentation-only so native authority remains X2Team:GetRole.
    return ROLE_FALLBACK[value] or ("职责 " .. tostring(value))
end

local function ReadCapability(capability, object, method, ...)
    if S.Api == nil or type(S.Api.CallCapability) ~= "function" then return nil, "api unavailable" end
    local ok, value, err = S.Api:CallCapability(capability, object, method, ...)
    if ok ~= true then return nil, err or "read failed" end
    return value, nil
end

local function ReadRole(member)
    if type(member) ~= "table" or tonumber(member.teamIndex) == 0 then return nil, nil end
    local role, err = ReadCapability("X2Team:GetRole", X2Team, "GetRole", tonumber(member.teamIndex) or 1, tonumber(member.memberIndex) or 0)
    return Number(role), err
end

local function ReadGear(member)
    local score, err = ReadCapability("X2Unit:UnitGearScore", X2Unit, "UnitGearScore", tostring(member.unitToken or ""), true)
    score = Number(score)
    if score ~= nil and score <= 0 then score = nil end
    return score, err
end

local function ReadDistance(member)
    local distance, err = ReadCapability("X2Unit:UnitDistance", X2Unit, "UnitDistance", tostring(member.unitToken or ""))
    distance = Number(distance)
    if distance ~= nil and distance < 0 then distance = nil end
    return distance, err
end

local function JoinIds(ids, maximum)
    local parts = {}
    for index, id in ipairs(type(ids) == "table" and ids or {}) do
        if index > (tonumber(maximum) or 6) then parts[#parts + 1] = "…"; break end
        parts[#parts + 1] = tostring(id)
    end
    return table.concat(parts, ",")
end

local function EvaluateMember(member, settings)
    local role, roleErr = ReadRole(member)
    local gear, gearErr = ReadGear(member)
    local distance, distanceErr = ReadDistance(member)
    local required = type(settings.requiredAuraIds) == "table" and settings.requiredAuraIds or {}
    local auraResult = { configured = #required > 0, ok = true, present = {}, missing = {}, meta = { available = true, complete = true, reliable = true } }

    if #required > 0 then
        local aura = S.Services and S.Services.AuraObservationV3 or nil
        if type(aura) ~= "table" or type(aura.GetSnapshot) ~= "function" or type(aura.EvaluateRequiredEffects) ~= "function" then
            auraResult.ok = nil
            auraResult.meta = { available = false, complete = false, reliable = false }
        else
            local snapshot = aura:GetSnapshot(tostring(member.unitToken or ""), {
                buff = true, debuff = false, hidden = settings.includeHidden == true,
                buffLimit = 64, hiddenLimit = 64, ttlMs = 0,
            })
            if type(snapshot) ~= "table" then
                auraResult.ok = nil
                auraResult.meta = { available = false, complete = false, reliable = false }
            else
                auraResult = aura:EvaluateRequiredEffects(snapshot, required, { buff = true, debuff = false, hidden = settings.includeHidden == true })
            end
        end
    end

    local failures, unknown = {}, {}
    local evaluated = 0
    local minGear = math.max(0, math.floor(tonumber(settings.minGearScore) or 0))
    if minGear > 0 then
        evaluated = evaluated + 1
        if gear == nil then unknown[#unknown + 1] = "装分不可读"
        elseif gear < minGear then failures[#failures + 1] = "装分不足 " .. tostring(math.floor(gear)) .. "/" .. tostring(minGear) end
    end
    if #required > 0 then
        evaluated = evaluated + 1
        if auraResult.ok == false then failures[#failures + 1] = "缺增益 " .. JoinIds(auraResult.missing, 6)
        elseif auraResult.ok == nil then
            unknown[#unknown + 1] = "增益扫描不完整"
            A.metrics.auraUnknown = (tonumber(A.metrics.auraUnknown) or 0) + 1
        end
    end

    if roleErr ~= nil then A.metrics.roleFailures = (tonumber(A.metrics.roleFailures) or 0) + 1 end
    if gearErr ~= nil then A.metrics.gearFailures = (tonumber(A.metrics.gearFailures) or 0) + 1 end
    if distanceErr ~= nil then A.metrics.distanceFailures = (tonumber(A.metrics.distanceFailures) or 0) + 1 end

    local status, statusText, tone
    if #failures > 0 then status, statusText, tone = "failed", "未通过", "red"
    elseif #unknown > 0 then status, statusText, tone = "unknown", "待确认", "warn"
    elseif evaluated > 0 then status, statusText, tone = "ready", "通过", "green"
    else status, statusText, tone = "info", "信息", "accent" end

    local auraText
    if #required == 0 then auraText = "未配置"
    elseif auraResult.ok == true then auraText = "齐全 " .. tostring(#auraResult.present) .. "/" .. tostring(#required)
    elseif auraResult.ok == false then auraText = "缺 " .. tostring(#auraResult.missing)
    else auraText = "待确认" end

    local details = {}
    for _, text in ipairs(failures) do details[#details + 1] = text end
    for _, text in ipairs(unknown) do details[#details + 1] = text end
    if #details == 0 then
        if evaluated > 0 then details[1] = "当前已配置检查项均满足" else details[1] = "尚未配置装分或关键增益判定规则" end
    end

    return {
        key = string.format("%d:%d:%s", tonumber(member.teamIndex) or 0, tonumber(member.memberIndex) or 0, Trim(member.name or member.unitToken or "")),
        name = Trim(member.name) ~= "" and Trim(member.name) or tostring(member.unitToken or "未知成员"),
        unitToken = tostring(member.unitToken or ""),
        teamIndex = tonumber(member.teamIndex) or 0,
        memberIndex = tonumber(member.memberIndex) or 0,
        role = role,
        roleText = RoleLabel(role, member),
        gearScore = gear,
        gearText = gear ~= nil and tostring(math.floor(gear)) or "—",
        distance = distance,
        distanceText = distance ~= nil and string.format("%.1fm", distance) or "—",
        auraText = auraText,
        requiredAuraCount = #required,
        missingAuraIds = Copy(auraResult.missing or {}),
        presentAuraIds = Copy(auraResult.present or {}),
        status = status,
        statusText = statusText,
        tone = tone,
        detailText = table.concat(details, " · "),
        checkedAt = NowMs(),
    }
end

local function RebuildSummary(rows)
    local summary = { total = #rows, ready = 0, failed = 0, unknown = 0, info = 0 }
    for _, row in ipairs(rows) do
        if row.status == "ready" then summary.ready = summary.ready + 1
        elseif row.status == "failed" then summary.failed = summary.failed + 1
        elseif row.status == "unknown" then summary.unknown = summary.unknown + 1
        else summary.info = summary.info + 1 end
    end
    return summary
end

function A:ResetTransient(reason)
    self.rows, self.byKey = {}, {}
    self.summary = { total = 0, ready = 0, failed = 0, unknown = 0, info = 0 }
    self.scan.active = false
    self.scan.cursor, self.scan.total, self.scan.completed = 0, 0, 0
    self.scan.reason = tostring(reason or "reset")
    self.revision = self.revision + 1
    return true
end

function A:IsScanning() return self.scan.active == true end

function A:CancelScan(reason)
    if self.scan.active ~= true then return true end
    self.scan.active = false
    self.scan.generation = (tonumber(self.scan.generation) or 0) + 1
    self.scan.reason = tostring(reason or "cancelled")
    self.metrics.cancelled = (tonumber(self.metrics.cancelled) or 0) + 1
    if S.Scheduler ~= nil and type(S.Scheduler.RemoveOwner) == "function" then S.Scheduler:RemoveOwner(self) end
    return true
end

function A:_Publish(reason)
    self.revision = self.revision + 1
    if S.Events ~= nil and type(S.Events.Publish) == "function" then
        S.Events:Publish("v3.raid_readiness.updated", self.revision, tostring(reason or "updated"))
    end
end

function A:_FinishScan(generation)
    if self.scan.active ~= true or tonumber(self.scan.generation) ~= tonumber(generation) then return false end
    self.scan.active = false
    self.scan.completed = self.scan.total
    self.scan.reason = "complete"
    self.summary = RebuildSummary(self.rows)
    self.metrics.scans = (tonumber(self.metrics.scans) or 0) + 1
    if F ~= nil and type(F.ReleaseAuraLease) == "function" then F:ReleaseAuraLease("scan_complete") end
    self:_Publish("scan_complete")
    return true
end

function A:_ScheduleSlice(generation, members, settings, batchSize)
    if S.Scheduler == nil or type(S.Scheduler.AddOneShot) ~= "function" then return false, "scheduler unavailable" end
    local name = "raid_readiness_scan_" .. tostring(generation)
    if type(S.Scheduler.SetTaskModule) == "function" then S.Scheduler:SetTaskModule(name, "combat_raid_readiness", true) end
    return S.Scheduler:AddOneShot(name, 50, function()
        if A.scan.active ~= true or tonumber(A.scan.generation) ~= tonumber(generation) then return true end
        local processed = 0
        while A.scan.cursor <= #members and processed < batchSize do
            local member = members[A.scan.cursor]
            local row = EvaluateMember(member, settings)
            A.rows[#A.rows + 1] = row
            A.byKey[row.key] = row
            A.scan.cursor = A.scan.cursor + 1
            A.scan.completed = A.scan.completed + 1
            A.metrics.membersRead = (tonumber(A.metrics.membersRead) or 0) + 1
            processed = processed + 1
        end
        A.summary = RebuildSummary(A.rows)
        A:_Publish("scan_progress")
        if A.scan.cursor > #members then return A:_FinishScan(generation) end
        return A:_ScheduleSlice(generation, members, settings, batchSize)
    end, self, "P2", batchSize > 4 and 2 or 3)
end

function A:StartScan(reason)
    if F == nil or F.enabled ~= true then return false, "团队战备检查未启用" end
    local roster = S.Services and S.Services.TeamRosterV3 or nil
    if type(roster) ~= "table" or type(roster.GetSnapshot) ~= "function" then return false, "团队名单服务不可用" end
    local snapshot = roster:GetSnapshot()
    local members = type(snapshot) == "table" and snapshot.members or nil
    if type(members) ~= "table" or #members == 0 then return false, "当前没有可检查的团队成员" end

    self:CancelScan("restart")
    local settings = Copy(F:GetSettings() or {})
    local auraNeeded = type(settings.requiredAuraIds) == "table" and #settings.requiredAuraIds > 0
    if auraNeeded then
        local held, holdErr = F:AcquireAuraLease("raid_readiness_scan")
        if held ~= true then return false, holdErr end
    end

    self.rows, self.byKey = {}, {}
    self.summary = { total = #members, ready = 0, failed = 0, unknown = 0, info = 0 }
    self.scan.generation = (tonumber(self.scan.generation) or 0) + 1
    local generation = self.scan.generation
    self.scan.active = true
    self.scan.cursor, self.scan.total, self.scan.completed = 1, #members, 0
    self.scan.reason = tostring(reason or "manual")
    -- Aura inspection can require dozens of native reads per member. Process
    -- exactly one member per slice when Aura rules are active so a 50-player
    -- raid cannot turn one scheduler callback into a visible frame spike.
    local batchSize = auraNeeded and 1 or 8
    self:_Publish("scan_started")
    local scheduled, scheduleErr = self:_ScheduleSlice(generation, Copy(members), settings, batchSize)
    if scheduled ~= true then
        self.scan.active = false
        if auraNeeded then F:ReleaseAuraLease("scan_schedule_failed") end
        return false, scheduleErr or "检查任务调度失败"
    end
    return true
end

function A:GetRows(showOnlyIssues)
    local rows = {}
    for _, row in ipairs(self.rows) do
        if showOnlyIssues ~= true or row.status == "failed" or row.status == "unknown" then rows[#rows + 1] = Copy(row) end
    end
    return rows, self.revision
end
function A:GetRow(key) return self.byKey[tostring(key or "")] and Copy(self.byKey[tostring(key or "")]) or nil end
function A:GetSummary()
    local out = Copy(self.summary)
    out.revision = self.revision
    out.scanning = self.scan.active == true
    out.completed = tonumber(self.scan.completed) or 0
    out.scanTotal = tonumber(self.scan.total) or 0
    out.reason = tostring(self.scan.reason or "")
    return out
end
function A:GetHealth()
    return {
        version = self.version, revision = self.revision, scanning = self.scan.active == true,
        completed = tonumber(self.scan.completed) or 0, total = tonumber(self.scan.total) or 0,
        scans = tonumber(self.metrics.scans) or 0, cancelled = tonumber(self.metrics.cancelled) or 0,
        membersRead = tonumber(self.metrics.membersRead) or 0, gearFailures = tonumber(self.metrics.gearFailures) or 0,
        roleFailures = tonumber(self.metrics.roleFailures) or 0, distanceFailures = tonumber(self.metrics.distanceFailures) or 0,
        auraUnknown = tonumber(self.metrics.auraUnknown) or 0,
    }
end

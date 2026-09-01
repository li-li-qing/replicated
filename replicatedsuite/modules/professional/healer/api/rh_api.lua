ReplicatedSuiteModuleSandbox:Enter('healer', {'ReplicatedHealerBoot', 'ReplicatedHealerConfig', 'ReplicatedHealerModule'})
------------------------------------------------------------------------
-- Replicated Healer - Native API Gateway v1
--
-- Single Proxy boundary for native X2Unit / X2Team reads used by Healer.
-- Domain code must not call X2Unit/X2Team directly after this file is loaded.
--
-- Hot-path rules:
--   * no diagnostic string formatting on successful reads;
--   * Observation cache is reused for common health/name/distance fields;
--   * failures are counted cheaply and only rate-limited warnings allocate logs;
--   * vararg calls avoid a temporary argument table for the common 0..3 args.
------------------------------------------------------------------------

if ReplicatedHealerCore1Loaded ~= true then return end

ReplicatedHealerApi = ReplicatedHealerApi or {}
local A = ReplicatedHealerApi

A.Version = "1.0"
A.metrics = A.metrics or {
    unitCalls = 0,
    unitFailures = 0,
    roleCalls = 0,
    roleFailures = 0,
    invalidRoleRequests = 0,
    screenCalls = 0,
    screenFailures = 0,
}

local function DiagnosticsCount(code, delta)
    local diagnostics = ReplicatedSuite and ReplicatedSuite.DiagnosticsManager or nil
    if diagnostics ~= nil and type(diagnostics.Count) == "function" then
        diagnostics:Count("healer_api", code, delta or 1)
    end
end

local function WarnRateLimited(code, message, context)
    local diagnostics = ReplicatedSuite and ReplicatedSuite.DiagnosticsManager or nil
    if diagnostics ~= nil and type(diagnostics.WarnRateLimited) == "function" then
        diagnostics:WarnRateLimited("healer_api", code, 10000, message, context)
    end
end


function A:CallUnit(methodName, unitId, ...)
    self.metrics.unitCalls = (tonumber(self.metrics.unitCalls) or 0) + 1
    if X2Unit == nil then
        self.metrics.unitFailures = (tonumber(self.metrics.unitFailures) or 0) + 1
        DiagnosticsCount("UNIT_API_MISSING", 1)
        return nil
    end

    local method = X2Unit[methodName]
    if type(method) ~= "function" then
        self.metrics.unitFailures = (tonumber(self.metrics.unitFailures) or 0) + 1
        DiagnosticsCount("UNIT_METHOD_MISSING", 1)
        return nil
    end

    local argCount = select("#", ...)
    local a1, a2, a3 = ...
    local extraArgs = nil
    if argCount > 3 then extraArgs = { ... } end
    local function Fetch()
        local ok, value
        if argCount == 0 then
            ok, value = pcall(method, X2Unit, unitId)
        elseif argCount == 1 then
            ok, value = pcall(method, X2Unit, unitId, a1)
        elseif argCount == 2 then
            ok, value = pcall(method, X2Unit, unitId, a1, a2)
        elseif argCount == 3 then
            ok, value = pcall(method, X2Unit, unitId, a1, a2, a3)
        else
            ok, value = pcall(function() return method(X2Unit, unitId, unpack(extraArgs, 1, argCount)) end)
        end
        if ok then return value end
        A.metrics.unitFailures = (tonumber(A.metrics.unitFailures) or 0) + 1
        DiagnosticsCount("UNIT_CALL_FAILED", 1)
        WarnRateLimited("UNIT_CALL_FAILED", "Healer Native Unit API 调用失败", {
            method = tostring(methodName or ""),
            unit = tostring(unitId or ""),
        })
        return nil
    end

    if ReplicatedSuiteEmbedded == true and ReplicatedSuite ~= nil and ReplicatedSuite.Observation ~= nil
        and (methodName == "UnitName" or methodName == "UnitDistance" or methodName == "UnitHealth" or methodName == "UnitMaxHealth") then
        local ttl = methodName == "UnitName" and 250 or 75
        return ReplicatedSuite.Observation:ReadField("professional:healer", unitId, methodName, Fetch, ttl)
    end
    return Fetch()
end

function A:GetScreenPosition(unitId)
    self.metrics.screenCalls = (tonumber(self.metrics.screenCalls) or 0) + 1
    if X2Unit == nil or type(X2Unit.GetUnitScreenPosition) ~= "function" then
        self.metrics.screenFailures = (tonumber(self.metrics.screenFailures) or 0) + 1
        return nil, nil, nil
    end
    local ok, x, y, z = pcall(X2Unit.GetUnitScreenPosition, X2Unit, unitId)
    if not ok then
        self.metrics.screenFailures = (tonumber(self.metrics.screenFailures) or 0) + 1
        DiagnosticsCount("SCREEN_POSITION_FAILED", 1)
        return nil, nil, nil
    end
    return tonumber(x), tonumber(y), tonumber(z)
end

function A:GetRole(teamIndex, memberIndex)
    teamIndex = math.floor(tonumber(teamIndex) or 0)
    memberIndex = math.floor(tonumber(memberIndex) or 0)
    if teamIndex < 1 or teamIndex > 2 or memberIndex < 1 or memberIndex > 50 then
        self.metrics.invalidRoleRequests = (tonumber(self.metrics.invalidRoleRequests) or 0) + 1
        DiagnosticsCount("INVALID_ROLE_REQUEST", 1)
        return nil
    end
    if X2Team == nil or type(X2Team.GetRole) ~= "function" then return nil end

    self.metrics.roleCalls = (tonumber(self.metrics.roleCalls) or 0) + 1
    local ok, value = pcall(X2Team.GetRole, X2Team, teamIndex, memberIndex)
    if ok then return value end

    self.metrics.roleFailures = (tonumber(self.metrics.roleFailures) or 0) + 1
    DiagnosticsCount("TEAM_ROLE_CALL_FAILED", 1)
    WarnRateLimited("TEAM_ROLE_CALL_FAILED", "Healer Native Team Role API 调用失败", {
        teamIndex = teamIndex,
        memberIndex = memberIndex,
    })
    return nil
end

function A:Describe()
    return {
        version = tostring(self.Version or "?"),
        unitCalls = tonumber(self.metrics.unitCalls) or 0,
        unitFailures = tonumber(self.metrics.unitFailures) or 0,
        roleCalls = tonumber(self.metrics.roleCalls) or 0,
        roleFailures = tonumber(self.metrics.roleFailures) or 0,
        invalidRoleRequests = tonumber(self.metrics.invalidRoleRequests) or 0,
        screenCalls = tonumber(self.metrics.screenCalls) or 0,
        screenFailures = tonumber(self.metrics.screenFailures) or 0,
    }
end

-- Compatibility names used by the remaining Core1/Core2 code. Their Authority
-- is this gateway; they are intentionally kept until the rest of Healer is
-- migrated away from historical file-level globals.
function SafeUnitCall(methodName, unitId, ...)
    return A:CallUnit(methodName, unitId, ...)
end

function SafeUnitScreenPosition(unitId)
    return A:GetScreenPosition(unitId)
end

function GetOfficialRole(raidIndex, memberIndex)
    return A:GetRole(raidIndex, memberIndex)
end

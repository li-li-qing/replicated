------------------------------------------------------------------------
-- Replicated Suite V3 - Butler Read-only Authority
-- Only the officially enabled charge-info getter is consumed. All other
-- Butler actions remain outside the public Feature until separately verified.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Features = S.Features or {}
S.Features.Butler = S.Features.Butler or {}
local F = S.Features.Butler
local A = { version = 1, revision = 0, snapshot = nil, metrics = { refreshes = 0, failures = 0 } }
F.Authority = A

local function Bounded(value, depth, seen, budget)
    if value == nil or type(value) == "string" or type(value) == "number" or type(value) == "boolean" then return value end
    if type(value) ~= "table" or depth >= 2 or budget.count >= 48 then return "[结构化字段]" end
    seen = seen or {}
    if seen[value] then return "[循环字段]" end
    seen[value], budget.count = true, budget.count + 1
    local out = {}
    for key, child in pairs(value) do
        if budget.count >= 48 then break end
        out[tostring(key)] = Bounded(child, depth + 1, seen, budget)
    end
    seen[value] = nil
    return out
end

function A:Refresh(reason)
    local value, err
    if S.Api == nil or type(S.Api.CallCapability) ~= "function" or X2Butler == nil then
        err = "butler API unavailable"
    else
        local ok, result, callErr = S.Api:CallCapability("X2Butler:GetChargeInfo", X2Butler, "GetChargeInfo")
        if ok == true then value = Bounded(result, 0, nil, { count = 0 }) else err = callErr or "butler getter failed" end
    end
    self.revision = self.revision + 1
    self.metrics.refreshes = self.metrics.refreshes + 1
    if value == nil then self.metrics.failures = self.metrics.failures + 1 end
    self.snapshot = { revision = self.revision, available = value ~= nil, status = value ~= nil and "ready" or "unavailable", charge = value, error = err, source = "X2Butler:GetChargeInfo", reason = tostring(reason or "refresh") }
    return true
end
function A:GetProjection()
    local p = self.snapshot or { revision = 0, available = false, status = "unavailable", charge = nil }
    return { revision = p.revision, available = p.available, status = p.status, charge = p.charge, error = p.error, source = p.source, reason = p.reason }
end
function A:GetHealth()
    return { version = self.version, revision = self.revision, available = self.snapshot ~= nil and self.snapshot.available == true, refreshes = self.metrics.refreshes, failures = self.metrics.failures }
end

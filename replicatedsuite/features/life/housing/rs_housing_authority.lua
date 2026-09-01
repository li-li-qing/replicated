------------------------------------------------------------------------
-- Replicated Suite V3 - Housing Read-only Authority
--
-- The RU client exposes these four housing getters without arguments. Their
-- return shape is not stable enough to place in Presentation, so this
-- Authority converts every result into a detached, bounded projection.
-- No polling or write API is used.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local A = { version = 1, revision = 0, snapshot = nil, metrics = { refreshes = 0, failures = 0 } }
S.Features = S.Features or {}
S.Features.Housing = S.Features.Housing or {}
local F = S.Features.Housing
F.Authority = A

local function Copy(value)
    return S.Utils and type(S.Utils.DeepCopy) == "function" and S.Utils.DeepCopy(value) or value
end

local function BoundedValue(value, depth, seen, budget)
    if value == nil or type(value) == "string" or type(value) == "number" or type(value) == "boolean" then return value end
    if type(value) ~= "table" or depth >= 2 or budget.count >= 48 then return "[结构化字段]" end
    seen = seen or {}
    if seen[value] then return "[循环字段]" end
    seen[value], budget.count = true, budget.count + 1
    local out = {}
    for key, child in pairs(value) do
        if budget.count >= 48 then break end
        out[tostring(key)] = BoundedValue(child, depth + 1, seen, budget)
    end
    seen[value] = nil
    return out
end

local function Read(capability, method)
    if S.Api == nil or type(S.Api.CallCapability) ~= "function" or X2House == nil then
        return nil, "housing API unavailable"
    end
    local ok, value, err = S.Api:CallCapability(capability, X2House, method)
    if ok ~= true then return nil, err or "housing getter failed" end
    return value, nil
end

local function SafeValue(value)
    if value == nil then return nil end
    if type(value) == "string" or type(value) == "number" or type(value) == "boolean" then return tostring(value) end
    if type(value) == "table" then return BoundedValue(value, 0, nil, { count = 0 }) end
    return nil
end

function A:Refresh(reason)
    local fields = {
        { key = "tax", capability = "X2House:GetCurrentHousingTaxInfo", method = "GetCurrentHousingTaxInfo" },
        { key = "owner", capability = "X2House:GetHouseOwnerName", method = "GetHouseOwnerName" },
        { key = "name", capability = "X2House:GetHouseName", method = "GetHouseName" },
        { key = "type", capability = "X2House:GetHouseType", method = "GetHouseType" },
    }
    local values, errors, available = {}, {}, 0
    for _, field in ipairs(fields) do
        local value, err = Read(field.capability, field.method)
        value = SafeValue(value)
        values[field.key] = value
        if value ~= nil then available = available + 1 elseif err ~= nil then errors[field.key] = tostring(err) end
    end
    self.metrics.refreshes = self.metrics.refreshes + 1
    if available == 0 then self.metrics.failures = self.metrics.failures + 1 end
    self.revision = self.revision + 1
    self.snapshot = {
        revision = self.revision,
        available = available > 0,
        status = available == #fields and "ready" or (available > 0 and "partial" or "unavailable"),
        values = values,
        errors = errors,
        source = "X2House read-only",
        reason = tostring(reason or "refresh"),
    }
    return true
end

function A:GetProjection() return Copy(self.snapshot or { revision = 0, available = false, status = "unavailable", values = {}, errors = {} }) end
function A:GetHealth()
    return { version = self.version, revision = self.revision, available = self.snapshot ~= nil and self.snapshot.available == true, refreshes = self.metrics.refreshes, failures = self.metrics.failures }
end

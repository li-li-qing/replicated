------------------------------------------------------------------------
-- Replicated Suite V3 - API Import Manager
--
-- Foundation imports only the tiny API set required to boot, persist identity,
-- diagnose and recover. Migrated Features explicitly declare business API
-- dependencies and acquire them through this manager on first Initialize().
-- ImportAPI is process-global and not reversible, so Disable() releases runtime
-- work/events/caches but deliberately does not pretend an imported API can be
-- unloaded. Ownership is still tracked for diagnostics and architecture audits.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite

S.ApiImports = {
    version = 1,
    imported = {},
    owners = {},
    failures = {},
}
local M = S.ApiImports

local CORE_APIS = { CHAT = true, OPTION = true, UNIT = true, LOCALE = true }
for name in pairs(CORE_APIS) do M.imported[name] = { core = true, imported = true } end

local function NormalizeName(value)
    return tostring(value or ""):upper():gsub("[^A-Z0-9_]", "")
end

local function CopyList(values)
    local out = {}
    if type(values) ~= "table" then return out end
    for _, value in ipairs(values) do
        local name = NormalizeName(value)
        if name ~= "" then out[#out + 1] = name end
    end
    return out
end

function M:IsImported(name)
    local row = self.imported[NormalizeName(name)]
    return row ~= nil and row.imported == true
end

function M:Acquire(ownerId, dependencies)
    ownerId = tostring(ownerId or "")
    if ownerId == "" then return false, "api import owner required" end
    local list = CopyList(dependencies)
    self.owners[ownerId] = self.owners[ownerId] or {}

    for _, name in ipairs(list) do
        local def = API_TYPE and API_TYPE[name] or nil
        if type(def) ~= "table" or def.id == nil then
            local err = "unknown API dependency: " .. name
            self.failures[name] = err
            return false, err
        end
        if self:IsImported(name) ~= true then
            if ADDON == nil or type(ADDON.ImportAPI) ~= "function" then
                local err = "ADDON:ImportAPI unavailable"
                self.failures[name] = err
                return false, err
            end
            local ok, result = pcall(function() return ADDON:ImportAPI(def.id) end)
            if not ok or result == false then
                local err = "ImportAPI " .. name .. " failed: " .. tostring(ok and "returned false" or result)
                self.failures[name] = err
                return false, err
            end
            self.imported[name] = { imported = true, core = false }
        end
        self.owners[ownerId][name] = true
    end
    return true
end

function M:GetOwnerApis(ownerId)
    local row = self.owners[tostring(ownerId or "")] or {}
    local result = {}
    for name in pairs(row) do result[#result + 1] = name end
    table.sort(result)
    return result
end

function M:Describe()
    local total, core, feature = 0, 0, 0
    for _, row in pairs(self.imported) do
        if row.imported == true then
            total = total + 1
            if row.core == true then core = core + 1 else feature = feature + 1 end
        end
    end
    local ownerCount = 0
    for _ in pairs(self.owners) do ownerCount = ownerCount + 1 end
    local failureCount = 0
    for _ in pairs(self.failures) do failureCount = failureCount + 1 end
    return { version = self.version, total = total, core = core, feature = feature, owners = ownerCount, failures = failureCount }
end

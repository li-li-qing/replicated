------------------------------------------------------------------------
-- Replicated Suite V3 - Native Import Registry
--
-- Single Authority for ADDON:ImportAPI / ADDON:ImportObject. Foundation imports
-- only the minimum objects/APIs required to boot. Migrated Features acquire
-- business APIs lazily through this same registry.
------------------------------------------------------------------------
if ReplicatedSuite == nil then return end
local S = ReplicatedSuite
local Contract = S.NativeContract
if type(Contract) ~= "table" then
    S.BootError = "native contract unavailable"
    return
end

S.NativeImports = {
    version = 3,
    optionalNegativeCacheContractVersion = 1,
    methodDependencyResolutionContractVersion = 1,
    generation = S.Generation,
    optionalFailureCacheHits = 0,
    source = "replicated_native",
    importedApis = {},
    importedObjects = {},
    apiOwners = {},
    failures = {},
    failureClasses = {},
    optionalObjectFailures = {},
}
local M = S.NativeImports

local function NormalizeName(value)
    return tostring(value or ""):upper():gsub("[^A-Z0-9_]", "")
end

local function RecordFailure(kind, name, detail, class)
    local key = tostring(kind) .. ":" .. tostring(name)
    M.failures[key] = tostring(detail or "unknown")
    M.failureClasses[key] = class == "foundation" and "foundation" or "feature"
end

function M:EnsureGeneration()
    if tonumber(self.generation) == tonumber(S.Generation) then return true end
    -- A reload may reuse the Lua table while the addon generation advances. Do
    -- not let an old optional probe suppress a capability probe in the new
    -- generation; imported object/API identities are generation-local too.
    self.generation = S.Generation
    self.optionalObjectFailures = {}
    self.optionalFailureCacheHits = 0
    self.importedObjects = {}
    self.importedApis = {}
    self.apiOwners = {}
    self.failures = {}
    self.failureClasses = {}
    return true
end

function M:IsApiImported(name)
    local row = self.importedApis[NormalizeName(name)]
    return row ~= nil and row.imported == true
end

function M:IsObjectImported(name)
    local row = self.importedObjects[NormalizeName(name)]
    return row ~= nil and row.imported == true
end

function M:AcquireObject(ownerId, name, required)
    self:EnsureGeneration()
    ownerId = tostring(ownerId or "native")
    local failureClass = ownerId == "foundation" and "foundation" or "feature"
    name = NormalizeName(name)
    local def = Contract:GetObject(name)
    if type(def) ~= "table" or def.id == nil then
        local err = "unknown native object: " .. name
        RecordFailure("object", name, err, failureClass)
        return false, err
    end
    if self:IsObjectImported(name) then return true end
    -- Optional native objects are capability probes. A failed optional import is
    -- stable for the current addon generation, so do not repeatedly cross the
    -- Lua/C++ boundary on every control construction. Required callers still
    -- retry so an optional probe can never suppress a later hard dependency.
    if required ~= true and self.optionalObjectFailures[name] ~= nil then
        self.optionalFailureCacheHits = (tonumber(self.optionalFailureCacheHits) or 0) + 1
        return false, tostring(self.optionalObjectFailures[name])
    end
    if ADDON == nil or type(ADDON.ImportObject) ~= "function" then
        local err = "ADDON:ImportObject unavailable"
        if required == true then RecordFailure("object", name, err, failureClass)
        else self.optionalObjectFailures[name] = err end
        return false, err
    end
    local ok, result = pcall(function() return ADDON:ImportObject(def.id) end)
    if ok ~= true or result == false then
        local err = "ImportObject " .. name .. " failed: " .. tostring(ok and "returned false" or result)
        if required == true then
            RecordFailure("object", name, err, failureClass)
        else
            self.optionalObjectFailures[name] = err
        end
        return false, err
    end
    self.optionalObjectFailures[name] = nil
    self.importedObjects[name] = { imported = true, owner = ownerId, required = required == true, id = def.id }
    return true
end

function M:AcquireApi(ownerId, name, core)
    self:EnsureGeneration()
    ownerId = tostring(ownerId or "")
    if ownerId == "" then return false, "api import owner required" end
    local failureClass = (core == true or ownerId == "foundation") and "foundation" or "feature"
    local requested = tostring(name or "")
    local apiKey = type(Contract.ResolveApiKey) == "function" and Contract:ResolveApiKey(requested) or NormalizeName(requested)
    if apiKey == nil then
        local err = "unknown API dependency: " .. NormalizeName(requested)
        RecordFailure("api", NormalizeName(requested), err, failureClass)
        return false, err
    end
    name = tostring(apiKey):upper()
    local def = Contract:GetApi(name)
    if type(def) ~= "table" or def.id == nil then
        local err = "unknown API namespace: " .. name .. " (requested " .. requested .. ")"
        RecordFailure("api", name, err, failureClass)
        return false, err
    end
    self.apiOwners[ownerId] = self.apiOwners[ownerId] or {}
    if self:IsApiImported(name) ~= true then
        if def.autoImported == true then
            self.importedApis[name] = { imported = true, core = core == true, id = def.id, nativeName = def.nativeName, autoImported = true }
            self.apiOwners[ownerId][name] = true
            return true
        end
        if ADDON == nil or type(ADDON.ImportAPI) ~= "function" then
            local err = "ADDON:ImportAPI unavailable"
            RecordFailure("api", name, err, failureClass)
            return false, err
        end
        local ok, result = pcall(function() return ADDON:ImportAPI(def.id) end)
        if ok ~= true or result == false then
            local err = "ImportAPI " .. name .. " failed: " .. tostring(ok and "returned false" or result)
            RecordFailure("api", name, err, failureClass)
            return false, err
        end
        self.importedApis[name] = { imported = true, core = core == true, id = def.id, nativeName = def.nativeName }
    elseif core == true then
        self.importedApis[name].core = true
    end
    self.apiOwners[ownerId][name] = true
    return true
end

-- Compatibility-shaped API used by FeatureRuntime. It is intentionally an
-- alias of the Native registry, not a second import Authority.
function M:Acquire(ownerId, dependencies)
    local list = type(dependencies) == "table" and dependencies or {}
    for _, value in ipairs(list) do
        local ok, err = self:AcquireApi(ownerId, value, false)
        if ok ~= true then return false, err end
    end
    return true
end

function M:GetOwnerApis(ownerId)
    local row = self.apiOwners[tostring(ownerId or "")] or {}
    local out = {}
    for name in pairs(row) do out[#out + 1] = name end
    table.sort(out)
    return out
end

function M:BootstrapFoundation()
    local requiredObjects = { "TEXT_STYLE", "BUTTON", "DRAWABLE", "COLOR_DRAWABLE", "WINDOW", "LABEL", "EMPTY_WIDGET" }
    local optionalObjects = { "ICON_DRAWABLE", "STATUS_BAR", "SLIDER", "EDITBOX", "EDITBOX_MULTILINE", "X2_EDITBOX" }
    for _, name in ipairs(requiredObjects) do
        local ok, err = self:AcquireObject("foundation", name, true)
        if ok ~= true then return false, err end
    end
    for _, name in ipairs(optionalObjects) do self:AcquireObject("foundation", name, false) end

    local coreApis = { "CHAT", "OPTION", "UNIT", "LOCALE" }
    for _, name in ipairs(coreApis) do
        local ok, err = self:AcquireApi("foundation", name, true)
        if ok ~= true then return false, err end
    end
    return true
end

function M:Describe()
    local totalApis, coreApis, featureApis = 0, 0, 0
    for _, row in pairs(self.importedApis) do
        if row.imported == true then
            totalApis = totalApis + 1
            if row.core == true then coreApis = coreApis + 1 else featureApis = featureApis + 1 end
        end
    end
    local totalObjects, requiredObjects = 0, 0
    for _, row in pairs(self.importedObjects) do
        if row.imported == true then
            totalObjects = totalObjects + 1
            if row.required == true then requiredObjects = requiredObjects + 1 end
        end
    end
    local owners, failures, foundationFailures, featureFailures, optionalFailures = 0, 0, 0, 0, 0
    for _ in pairs(self.apiOwners) do owners = owners + 1 end
    for key in pairs(self.failures) do
        failures = failures + 1
        if self.failureClasses[key] == "foundation" then foundationFailures = foundationFailures + 1 else featureFailures = featureFailures + 1 end
    end
    for _ in pairs(self.optionalObjectFailures) do optionalFailures = optionalFailures + 1 end
    return {
        version = self.version,
        source = self.source,
        total = totalApis,
        core = coreApis,
        feature = featureApis,
        owners = owners,
        failures = failures,
        foundationFailures = foundationFailures,
        featureFailures = featureFailures,
        objects = totalObjects,
        requiredObjects = requiredObjects,
        optionalObjectFailures = optionalFailures,
        optionalNegativeCacheContractVersion = tonumber(self.optionalNegativeCacheContractVersion) or 0,
        methodDependencyResolutionContractVersion = tonumber(self.methodDependencyResolutionContractVersion) or 0,
        optionalFailureCacheHits = tonumber(self.optionalFailureCacheHits) or 0,
        generation = self.generation,
    }
end

-- Preserve the FeatureRuntime-facing name while keeping one Authority.
S.ApiImports = M

S.BootStage = "native_imports"
local ok, err = M:BootstrapFoundation()
if ok ~= true then
    S.BootError = "native foundation import failed: " .. tostring(err or "unknown")
    if type(S.SafeChat) == "function" then S.SafeChat(S.BootError, "error", "native") end
end

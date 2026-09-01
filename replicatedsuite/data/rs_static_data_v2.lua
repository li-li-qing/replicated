------------------------------------------------------------------------
-- Replicated Suite - Static Game Data V2
--
-- Immutable-by-contract, indexed game-definition data for V3 and shared
-- Services. Runtime state (prices, ratios, inventory, quest progress, etc.)
-- must never be registered here.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite

S.StaticDataV2 = {
    version = 2,
    catalogs = {},
    order = {},
    sealed = false,
    sealedReason = nil,
    stats = { catalogs = 0, records = 0, references = 0, duplicateKeys = 0, duplicateIds = 0, missingRequiredIds = 0, sealViolations = 0 },
}
local D = S.StaticDataV2

local function Normalize(value)
    local text = tostring(value or ""):lower():gsub("[^%w_%.%-]", "_"):gsub("_+", "_")
    text = text:gsub("^_+", ""):gsub("_+$", "")
    return text
end

local function Copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] ~= nil then return seen[value] end
    local out = {}; seen[value] = out
    for k, v in pairs(value) do out[Copy(k, seen)] = Copy(v, seen) end
    return out
end

local function HashText(hash, text)
    text = tostring(text or "")
    for i = 1, #text do hash = (hash * 33 + string.byte(text, i)) % 2147483647 end
    return hash
end

local function HashValue(hash, value, seen)
    local t = type(value)
    hash = HashText(hash, t)
    if t == "nil" then return hash end
    if t == "string" or t == "number" or t == "boolean" then return HashText(hash, tostring(value)) end
    if t ~= "table" then return HashText(hash, "unsupported") end
    seen = seen or {}
    if seen[value] then return HashText(hash, "cycle") end
    seen[value] = true
    local keys = {}
    for k in pairs(value) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
        local ka, kb = type(a) .. ":" .. tostring(a), type(b) .. ":" .. tostring(b)
        return ka < kb
    end)
    for _, k in ipairs(keys) do
        hash = HashValue(hash, k, seen)
        hash = HashValue(hash, value[k], seen)
    end
    seen[value] = nil
    return hash
end

local function Emit(level, code, message, context)
    local d = S.DiagnosticsManager
    if type(d) == "table" and type(d.Emit) == "function" then d:Emit(level, "static_data_v2", code, message, context) end
end


local function RejectIfSealed(operation, context)
    if D.sealed ~= true then return false end
    D.stats.sealViolations = (tonumber(D.stats.sealViolations) or 0) + 1
    Emit("error", "STATIC_DATA_SEALED_WRITE", "Static Data V2 已封存，拒绝运行期修改", {
        operation = operation,
        catalog = context and context.catalog or nil,
        key = context and context.key or nil,
        reason = D.sealedReason,
    })
    return true
end

function D:ComputeFingerprint()
    local hash = 5381
    for _, catalogName in ipairs(self.order) do
        local catalog = self.catalogs[catalogName]
        hash = HashText(hash, catalogName)
        hash = HashText(hash, catalog.idField)
        hash = HashText(hash, tostring(catalog.requireId == true))
        for _, key in ipairs(catalog.order or {}) do
            hash = HashText(hash, key)
            hash = HashValue(hash, catalog.records[key])
        end
        hash = HashValue(hash, catalog.references or {})
    end
    return tostring(math.floor(hash))
end

function D:Seal(reason)
    if self.sealed == true then return true, self:Validate() end
    self.sealedReason = tostring(reason or "runtime_start")
    self.sealedAtGeneration = tonumber(S.Generation) or 0
    self.sealedFingerprint = self:ComputeFingerprint()
    self.sealed = true
    return true, self:Validate()
end

function D:IsSealed()
    return self.sealed == true
end

function D:DefineCatalog(name, spec)
    name = Normalize(name)
    if RejectIfSealed("define_catalog", { catalog = name }) then return nil, "static data sealed" end
    if name == "" then return nil, "catalog name required" end
    if self.catalogs[name] ~= nil then return nil, "duplicate catalog: " .. name end
    spec = type(spec) == "table" and spec or {}
    local catalog = {
        name = name,
        idField = tostring(spec.idField or "id"),
        requireId = spec.requireId == true,
        records = {},
        order = {},
        byId = {},
        references = {},
        metadata = Copy(spec.metadata or {}),
    }
    self.catalogs[name] = catalog
    self.order[#self.order + 1] = name
    table.sort(self.order)
    self.stats.catalogs = (tonumber(self.stats.catalogs) or 0) + 1
    return catalog
end

function D:GetCatalog(name)
    return self.catalogs[Normalize(name)]
end

-- Stable ASCII key for source names that may contain Chinese/Russian text.
-- We intentionally hash UTF-8 bytes instead of stripping non-ASCII characters;
-- this makes catalog identities deterministic across locales without putting
-- display text itself on hot lookup paths.
function D:StableTextKey(prefix, value)
    local text = tostring(value or "")
    local hash = 5381
    for i = 1, #text do hash = (hash * 33 + string.byte(text, i)) % 2147483647 end
    local cleanPrefix = Normalize(prefix)
    if cleanPrefix == "" then cleanPrefix = "key" end
    return cleanPrefix .. ".h" .. tostring(math.floor(hash))
end

function D:Register(catalogName, key, record)
    if RejectIfSealed("register", { catalog = tostring(catalogName), key = tostring(key) }) then return nil, "static data sealed" end
    local catalog = self:GetCatalog(catalogName)
    if catalog == nil then return nil, "unknown catalog: " .. tostring(catalogName) end
    key = Normalize(key)
    if key == "" then return nil, "record key required" end
    if catalog.records[key] ~= nil then
        self.stats.duplicateKeys = (tonumber(self.stats.duplicateKeys) or 0) + 1
        return nil, "duplicate key: " .. catalog.name .. "/" .. key
    end
    if type(record) ~= "table" then return nil, "record table required" end

    local stored = Copy(record)
    stored.key = key
    stored.catalog = catalog.name
    stored.static = true
    local id = tonumber(stored[catalog.idField])
    if id ~= nil then
        id = math.floor(id)
        stored[catalog.idField] = id
        if catalog.byId[id] ~= nil then
            self.stats.duplicateIds = (tonumber(self.stats.duplicateIds) or 0) + 1
            return nil, "duplicate id: " .. catalog.name .. "/" .. tostring(id)
        end
        catalog.byId[id] = stored
    elseif catalog.requireId == true then
        self.stats.missingRequiredIds = (tonumber(self.stats.missingRequiredIds) or 0) + 1
        return nil, "required id missing: " .. catalog.name .. "/" .. key .. "." .. catalog.idField
    end
    catalog.records[key] = stored
    catalog.order[#catalog.order + 1] = key
    table.sort(catalog.order)
    self.stats.records = (tonumber(self.stats.records) or 0) + 1
    return stored
end

function D:Get(catalogName, key)
    local catalog = self:GetCatalog(catalogName)
    return catalog and catalog.records[Normalize(key)] or nil
end

function D:FindById(catalogName, id)
    local catalog = self:GetCatalog(catalogName)
    return catalog and catalog.byId[tonumber(id)] or nil
end

-- Ordered read-only enumeration for setup/ViewModel construction. Returned
-- records remain owned by StaticDataV2 and must never be mutated by callers.
-- Hot paths should keep using Get()/FindById() O(1) indexes.
function D:List(catalogName)
    local catalog = self:GetCatalog(catalogName)
    if catalog == nil then return {} end
    local rows = {}
    for _, key in ipairs(catalog.order or {}) do
        local row = catalog.records[key]
        if row ~= nil then rows[#rows + 1] = row end
    end
    return rows
end

function D:GetCount(catalogName)
    local catalog = self:GetCatalog(catalogName)
    return catalog and #(catalog.order or {}) or 0
end

function D:AddReference(fromCatalog, fromKey, field, toCatalog, toKey, required)
    if RejectIfSealed("add_reference", { catalog = tostring(fromCatalog), key = tostring(fromKey) }) then return false, "static data sealed" end
    local catalog = self:GetCatalog(fromCatalog)
    if catalog == nil then return false, "unknown source catalog" end
    local source = catalog.records[Normalize(fromKey)]
    if source == nil then return false, "unknown source record" end
    local ref = {
        fromCatalog = catalog.name,
        fromKey = source.key,
        field = tostring(field or "ref"),
        toCatalog = Normalize(toCatalog),
        toKey = Normalize(toKey),
        required = required ~= false,
    }
    catalog.references[#catalog.references + 1] = ref
    self.stats.references = (tonumber(self.stats.references) or 0) + 1
    return true
end

function D:Validate()
    local errors, warnings, missingRefs = {}, {}, 0
    for _, catalogName in ipairs(self.order) do
        local catalog = self.catalogs[catalogName]
        for _, ref in ipairs(catalog.references) do
            local targetCatalog = self.catalogs[ref.toCatalog]
            local target = targetCatalog and targetCatalog.records[ref.toKey] or nil
            if target == nil then
                missingRefs = missingRefs + 1
                local row = ref.fromCatalog .. "/" .. ref.fromKey .. "." .. ref.field .. " -> " .. ref.toCatalog .. "/" .. ref.toKey
                if ref.required then errors[#errors + 1] = row else warnings[#warnings + 1] = row end
            end
        end
    end
    local currentFingerprint = self.sealed == true and self:ComputeFingerprint() or nil
    local mutationDetected = self.sealed == true and self.sealedFingerprint ~= nil and currentFingerprint ~= self.sealedFingerprint
    local ok = #errors == 0
        and (tonumber(self.stats.duplicateKeys) or 0) == 0
        and (tonumber(self.stats.duplicateIds) or 0) == 0
        and (tonumber(self.stats.missingRequiredIds) or 0) == 0
        and mutationDetected ~= true
    if not ok then
        Emit("warning", "STATIC_DATA_INVALID", "Static Data V2 校验存在问题", {
            errors = #errors,
            warnings = #warnings,
            missingRefs = missingRefs,
            duplicateKeys = tonumber(self.stats.duplicateKeys) or 0,
            duplicateIds = tonumber(self.stats.duplicateIds) or 0,
            missingRequiredIds = tonumber(self.stats.missingRequiredIds) or 0,
            mutationDetected = mutationDetected == true,
        })
    end
    return {
        ok = ok,
        errors = errors,
        warnings = warnings,
        missingRefs = missingRefs,
        catalogs = tonumber(self.stats.catalogs) or 0,
        records = tonumber(self.stats.records) or 0,
        references = tonumber(self.stats.references) or 0,
        duplicateKeys = tonumber(self.stats.duplicateKeys) or 0,
        duplicateIds = tonumber(self.stats.duplicateIds) or 0,
        missingRequiredIds = tonumber(self.stats.missingRequiredIds) or 0,
        sealed = self.sealed == true,
        sealViolations = tonumber(self.stats.sealViolations) or 0,
        mutationDetected = mutationDetected == true,
        fingerprint = currentFingerprint or self:ComputeFingerprint(),
        sealedFingerprint = self.sealedFingerprint,
    }
end

function D:Describe()
    local rows = {}
    for _, name in ipairs(self.order) do
        local catalog = self.catalogs[name]
        rows[#rows + 1] = {
            name = name,
            records = #catalog.order,
            references = #catalog.references,
            idField = catalog.idField,
            requireId = catalog.requireId == true,
        }
    end
    local validation = self:Validate()
    return {
        version = self.version,
        ok = validation.ok,
        catalogs = validation.catalogs,
        records = validation.records,
        references = validation.references,
        missingRefs = validation.missingRefs,
        duplicateKeys = validation.duplicateKeys,
        duplicateIds = validation.duplicateIds,
        missingRequiredIds = validation.missingRequiredIds,
        sealed = self.sealed == true,
        sealedReason = self.sealedReason,
        sealViolations = tonumber(self.stats.sealViolations) or 0,
        mutationDetected = validation.mutationDetected == true,
        fingerprint = validation.fingerprint,
        sealedFingerprint = validation.sealedFingerprint,
        rows = rows,
    }
end

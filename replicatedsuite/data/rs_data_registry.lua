------------------------------------------------------------------------
-- Replicated Suite - Shared Game Data Registry
--
-- Authority boundary:
--   * Registry owns reusable game-data identity/indexing only.
--   * Domain modules still own business policy and mutable runtime state.
--   * Relationship files may reference Registry IDs, but Registry must not
--     decide quest completion, healer priority, DPS classification, etc.
--
-- Performance rule:
--   All indexes are built at addon load/registration time. Hot paths query
--   prebuilt tables by id/key/tag/family and never scan the full catalog.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite

S.GameIds = S.GameIds or {}
S.GameDataRegistry = {
    types = {},
    invalid = {},
    duplicateKeys = {},
    duplicateIds = {},
    sequence = 0,
    sealed = false,
    sealedReason = nil,
    sealViolations = 0,
}
local R = S.GameDataRegistry

local DEFAULT_TYPES = { "quest", "skill", "buff", "item", "instance", "instance_zone", "trade_craft", "zone", "npc", "boss" }
local MAX_ISSUES = 128

local function NormalizeKind(value)
    local text = tostring(value or ""):lower():gsub("%s+", "")
    return text
end

local function NormalizeKey(value)
    local text = tostring(value or "")
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return nil end
    return text
end

local function NormalizeName(value)
    local text = tostring(value or "")
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return nil end
    return text:lower()
end

local function CopyArray(value)
    local out = {}
    if type(value) ~= "table" then return out end
    for i = 1, #value do out[i] = value[i] end
    return out
end

local function CopyMetadata(value)
    local out = {}
    if type(value) ~= "table" then return out end
    for key, item in pairs(value) do
        if type(item) == "table" then
            out[key] = CopyArray(item)
        elseif type(item) == "string" or type(item) == "number" or type(item) == "boolean" then
            out[key] = item
        end
    end
    return out
end

local function PushIssue(list, value)
    list[#list + 1] = value
    while #list > MAX_ISSUES do table.remove(list, 1) end
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

local function RejectIfSealed(operation, kind, key)
    if R.sealed ~= true then return false end
    R.sealViolations = (tonumber(R.sealViolations) or 0) + 1
    local d = S.DiagnosticsManager
    if type(d) == "table" and type(d.Emit) == "function" then
        d:Emit("error", "game_data", "REGISTRY_SEALED_WRITE", "共享游戏身份注册表已封存，拒绝运行期修改", {
            operation = operation, kind = kind, key = key, reason = R.sealedReason,
        })
    end
    return true
end

function R:ComputeFingerprint()
    local hash = 5381
    local kinds = {}
    for kind in pairs(self.types) do kinds[#kinds + 1] = kind end
    table.sort(kinds)
    for _, kind in ipairs(kinds) do
        local bucket = self.types[kind]
        hash = HashText(hash, kind)
        local ids = {}
        for id in pairs(bucket.byId or {}) do ids[#ids + 1] = id end
        table.sort(ids)
        for _, id in ipairs(ids) do hash = HashValue(hash, bucket.byId[id]) end
        local setKeys = {}
        for key in pairs(bucket.sets or {}) do setKeys[#setKeys + 1] = key end
        table.sort(setKeys)
        for _, key in ipairs(setKeys) do hash = HashText(hash, key); hash = HashValue(hash, bucket.sets[key]) end
    end
    return tostring(math.floor(hash))
end

function R:Seal(reason)
    if self.sealed == true then return true, self:Validate() end
    self.sealedReason = tostring(reason or "runtime_start")
    self.sealedAtGeneration = tonumber(S.Generation) or 0
    self.sealedFingerprint = self:ComputeFingerprint()
    self.sealed = true
    return true, self:Validate()
end

function R:IsSealed()
    return self.sealed == true
end

function R:RegisterType(kind)
    kind = NormalizeKind(kind)
    if kind == "" then return nil end
    local bucket = self.types[kind]
    if bucket ~= nil then return bucket end
    if RejectIfSealed("register_type", kind, nil) then return nil end
    bucket = {
        kind = kind,
        byId = {},
        byKey = {},
        byName = {},
        byTag = {},
        byFamily = {},
        sets = {},
        setMembership = {},
        recordCount = 0,
        setCount = 0,
    }
    self.types[kind] = bucket
    return bucket
end

local function IndexRecord(bucket, record)
    local normalizedName = NormalizeName(record.name)
    if normalizedName ~= nil then
        local names = bucket.byName[normalizedName]
        if names == nil then names = {}; bucket.byName[normalizedName] = names end
        local exists = false
        for _, item in ipairs(names) do if item == record then exists = true; break end end
        if not exists then names[#names + 1] = record end
    end

    if record.family ~= nil and tostring(record.family) ~= "" then
        local family = tostring(record.family)
        local members = bucket.byFamily[family]
        if members == nil then members = {}; bucket.byFamily[family] = members end
        members[record.id] = true
    end

    for _, tagValue in ipairs(record.tags or {}) do
        local tag = tostring(tagValue or "")
        if tag ~= "" then
            local members = bucket.byTag[tag]
            if members == nil then members = {}; bucket.byTag[tag] = members end
            members[record.id] = true
        end
    end
end

local function CreateGeneratedRecord(owner, bucket, kind, id, metadata)
    local existing = bucket.byId[id]
    local meta = CopyMetadata(metadata)
    if existing ~= nil then
        -- Generated set members can be discovered by a curated set before a
        -- database-verified set. Verification is monotonic: a later stronger
        -- source may promote the placeholder, but a weaker set never demotes it.
        if existing.generated == true and meta.verified == true and existing.verified ~= true then
            existing.source = meta.source or existing.source
            existing.confidence = meta.confidence or existing.confidence
            existing.verified = true
            existing.verifiedAt = meta.verifiedAt or existing.verifiedAt
            if meta.notes ~= nil then existing.notes = meta.notes end
        end
        return existing
    end
    owner.sequence = owner.sequence + 1
    local key = tostring(kind):upper() .. "_" .. tostring(id)
    local record = {
        kind = kind,
        key = key,
        id = id,
        name = nil,
        family = nil,
        tags = {},
        source = meta.source,
        confidence = meta.confidence,
        verified = meta.verified == true,
        verifiedAt = meta.verifiedAt,
        notes = meta.notes or "set member; individual metadata not registered",
        order = owner.sequence,
        aliases = {},
        generated = true,
    }
    bucket.byId[id] = record
    bucket.byKey[key] = record
    bucket.recordCount = bucket.recordCount + 1
    return record
end

function R:Register(kind, key, id, metadata)
    kind = NormalizeKind(kind)
    key = NormalizeKey(key)
    if RejectIfSealed("register", kind, key) then return nil, "registry sealed" end
    id = tonumber(id)
    if kind == "" or key == nil or id == nil or id ~= math.floor(id) then
        PushIssue(self.invalid, { kind = kind, key = key, id = id, reason = "invalid_record" })
        return nil, "invalid record"
    end

    local bucket = self:RegisterType(kind)
    local existingByKey = bucket.byKey[key]
    if existingByKey ~= nil then
        if tonumber(existingByKey.id) == id then return existingByKey end
        PushIssue(self.duplicateKeys, { kind = kind, key = key, oldId = existingByKey.id, newId = id })
        return nil, "duplicate key"
    end

    local meta = CopyMetadata(metadata)
    local existingById = bucket.byId[id]
    if existingById ~= nil then
        if existingById.generated == true then
            -- A set may introduce an ID before a richer semantic record is
            -- loaded. Promote that placeholder in place so every relationship
            -- keeps the same record identity and no false duplicate warning is
            -- emitted.
            local generatedKey = existingById.key
            existingById.aliases = existingById.aliases or {}
            if generatedKey ~= key then existingById.aliases[#existingById.aliases + 1] = generatedKey end
            existingById.key = key
            existingById.name = meta.name
            existingById.family = meta.family
            existingById.tags = CopyArray(meta.tags)
            existingById.source = meta.source or existingById.source
            existingById.confidence = meta.confidence or existingById.confidence
            existingById.verified = meta.verified == true
            existingById.verifiedAt = meta.verifiedAt
            existingById.notes = meta.notes
            existingById.generated = false
            bucket.byKey[key] = existingById
            if generatedKey ~= nil then bucket.byKey[generatedKey] = existingById end
            IndexRecord(bucket, existingById)
            return existingById
        end

        -- Multiple semantic names may intentionally point at one server ID.
        -- Preserve a single record Authority and make the additional key an alias.
        existingById.aliases = existingById.aliases or {}
        existingById.aliases[#existingById.aliases + 1] = key
        bucket.byKey[key] = existingById
        PushIssue(self.duplicateIds, { kind = kind, id = id, primaryKey = existingById.key, aliasKey = key })
        return existingById
    end

    self.sequence = self.sequence + 1
    local record = {
        kind = kind,
        key = key,
        id = id,
        name = meta.name,
        family = meta.family,
        tags = CopyArray(meta.tags),
        source = meta.source,
        confidence = meta.confidence,
        verified = meta.verified == true,
        verifiedAt = meta.verifiedAt,
        notes = meta.notes,
        order = self.sequence,
        aliases = {},
        generated = false,
    }
    bucket.byId[id] = record
    bucket.byKey[key] = record
    bucket.recordCount = bucket.recordCount + 1
    IndexRecord(bucket, record)
    return record
end

-- Register an intentional semantic alias for an already-known server ID.
-- Unlike Register(kind,key,sameId), this path does NOT emit duplicate-ID
-- warnings: callers are explicitly declaring that both keys are one identity.
-- This keeps accidental duplicate registration diagnosable while allowing
-- shared static catalogs (Trade/Bond/etc.) to converge on one item record.
function R:RegisterAlias(kind, key, id)
    kind = NormalizeKind(kind)
    key = NormalizeKey(key)
    if RejectIfSealed("register_alias", kind, key) then return nil, "registry sealed" end
    id = tonumber(id)
    if kind == "" or key == nil or id == nil or id ~= math.floor(id) then
        PushIssue(self.invalid, { kind = kind, key = key, id = id, reason = "invalid_alias" })
        return nil, "invalid alias"
    end
    local bucket = self:RegisterType(kind)
    local target = bucket.byId[id]
    if target == nil then
        PushIssue(self.invalid, { kind = kind, key = key, id = id, reason = "alias_target_missing" })
        return nil, "alias target missing"
    end
    local existing = bucket.byKey[key]
    if existing ~= nil then
        if existing == target then return target end
        PushIssue(self.duplicateKeys, { kind = kind, key = key, oldId = existing.id, newId = id, reason = "alias_key_conflict" })
        return nil, "alias key conflict"
    end
    target.aliases = target.aliases or {}
    target.aliases[#target.aliases + 1] = key
    bucket.byKey[key] = target
    return target
end

function R:RegisterSet(kind, key, ids, metadata)
    kind = NormalizeKind(kind)
    key = NormalizeKey(key)
    if RejectIfSealed("register_set", kind, key) then return nil, "registry sealed" end
    if kind == "" or key == nil or type(ids) ~= "table" then
        PushIssue(self.invalid, { kind = kind, key = key, reason = "invalid_set" })
        return nil, "invalid set"
    end

    local bucket = self:RegisterType(kind)
    if bucket.sets[key] ~= nil then
        PushIssue(self.duplicateKeys, { kind = kind, key = key, reason = "duplicate_set" })
        return nil, "duplicate set"
    end

    local clean, seen = {}, {}
    for _, value in ipairs(ids) do
        local id = tonumber(value)
        if id ~= nil and id == math.floor(id) and seen[id] ~= true then
            clean[#clean + 1] = id
            seen[id] = true
        else
            PushIssue(self.invalid, { kind = kind, key = key, id = value, reason = "invalid_set_member" })
        end
    end

    local meta = CopyMetadata(metadata)
    local set = {
        kind = kind,
        key = key,
        ids = clean,
        name = meta.name,
        source = meta.source,
        confidence = meta.confidence,
        verified = meta.verified == true,
        verifiedAt = meta.verifiedAt,
        notes = meta.notes,
        tags = CopyArray(meta.tags),
    }
    bucket.sets[key] = set
    bucket.setCount = bucket.setCount + 1

    for _, id in ipairs(clean) do
        CreateGeneratedRecord(self, bucket, kind, id, meta)
        local memberships = bucket.setMembership[id]
        if memberships == nil then memberships = {}; bucket.setMembership[id] = memberships end
        memberships[#memberships + 1] = set
    end
    return set
end

function R:Get(kind, keyOrId)
    local bucket = self.types[NormalizeKind(kind)]
    if bucket == nil then return nil end
    if type(keyOrId) == "number" then return bucket.byId[keyOrId] end
    local numeric = tonumber(keyOrId)
    if numeric ~= nil and tostring(keyOrId):match("^%d+$") then return bucket.byId[numeric] end
    return bucket.byKey[tostring(keyOrId or "")]
end

function R:FindById(kind, id)
    local bucket = self.types[NormalizeKind(kind)]
    return bucket and bucket.byId[tonumber(id)] or nil
end

function R:FindByName(kind, name)
    local bucket = self.types[NormalizeKind(kind)]
    if bucket == nil then return {} end
    return bucket.byName[NormalizeName(name) or ""] or {}
end

function R:GetSet(kind, key)
    local bucket = self.types[NormalizeKind(kind)]
    if bucket == nil then return nil end
    local set = bucket.sets[tostring(key or "")]
    return set and set.ids or nil
end

function R:FindSetsById(kind, id)
    local bucket = self.types[NormalizeKind(kind)]
    if bucket == nil then return {} end
    return bucket.setMembership[tonumber(id)] or {}
end

-- Intended for setup/import/diagnostics paths, not per-frame hot loops.
function R:List(kind)
    local bucket = self.types[NormalizeKind(kind)]
    if bucket == nil then return {} end
    local rows = {}
    for _, record in pairs(bucket.byId) do rows[#rows + 1] = record end
    table.sort(rows, function(a, b) return (tonumber(a.id) or 0) < (tonumber(b.id) or 0) end)
    return rows
end

function R:HasTag(kind, keyOrId, tag)
    local bucket = self.types[NormalizeKind(kind)]
    if bucket == nil then return false end
    local record = self:Get(kind, keyOrId)
    if record == nil then return false end
    local members = bucket.byTag[tostring(tag or "")]
    return members ~= nil and members[record.id] == true or false
end

function R:IsFamily(kind, keyOrId, family)
    local bucket = self.types[NormalizeKind(kind)]
    if bucket == nil then return false end
    local record = self:Get(kind, keyOrId)
    if record == nil then return false end
    local members = bucket.byFamily[tostring(family or "")]
    return members ~= nil and members[record.id] == true or false
end

function R:Describe()
    local result = {
        types = {},
        totalRecords = 0,
        totalSets = 0,
        invalid = #self.invalid,
        duplicateKeys = #self.duplicateKeys,
        duplicateIds = #self.duplicateIds,
        sealed = self.sealed == true,
        sealViolations = tonumber(self.sealViolations) or 0,
        fingerprint = self:ComputeFingerprint(),
        sealedFingerprint = self.sealedFingerprint,
    }
    for kind, bucket in pairs(self.types) do
        local row = { records = bucket.recordCount or 0, sets = bucket.setCount or 0 }
        result.types[kind] = row
        result.totalRecords = result.totalRecords + row.records
        result.totalSets = result.totalSets + row.sets
    end
    return result
end

function R:Validate()
    local report = self:Describe()
    report.mutationDetected = self.sealed == true and self.sealedFingerprint ~= nil and report.fingerprint ~= self.sealedFingerprint
    report.ok = report.invalid == 0 and report.duplicateKeys == 0 and report.mutationDetected ~= true
    report.errors = report.invalid + report.duplicateKeys + (report.mutationDetected and 1 or 0)
    report.warnings = report.duplicateIds
    report.sealed = self.sealed == true
    report.sealViolations = tonumber(self.sealViolations) or 0
    report.invalidEntries = CopyArray(self.invalid)
    report.duplicateKeyEntries = CopyArray(self.duplicateKeys)
    report.duplicateIdEntries = CopyArray(self.duplicateIds)
    return report
end

for _, kind in ipairs(DEFAULT_TYPES) do R:RegisterType(kind) end

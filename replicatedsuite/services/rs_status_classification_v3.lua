------------------------------------------------------------------------
-- Replicated Suite V3 - Status Classification Service
--
-- Shared single Authority for "what an effect is" across every consumer
-- (Buff Display, Plates, Import/Export). The user-facing world only has two
-- categories: Buff and Debuff. "Hidden" and "special rule" are NOT user
-- categories anymore - they are detection sources that describe WHERE a
-- classification came from:
--
--   category        : "buff" | "debuff"          (the only user-facing kinds)
--   detectionSource : "normal" | "hidden" | "special_rule"
--
-- Resolution order (first match wins):
--   1. User override (settings.classification[id], persisted, manually fixed)
--   2. Seeded registry (wiki-verified buffs, curated Plates compatibility IDs)
--   3. Snapshot sources heuristic (debuff lane beats buff lane)
--   4. Default: unknown hidden-sourced effects classify as debuff
--
-- No Native/API access: pure data service, safe for projection and stores.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Services = S.Services or {}

local Classification = {
    version = 1,
    registry = {},      -- [id] = { category, detectionSource, name, source }
    overrides = {},     -- [id] = "buff"|"debuff"   (user manual corrections)
    seedCount = 0,
}
S.Services.StatusClassificationV3 = Classification

local function NormalizeCategory(value)
    if value == "debuff" then return "debuff" end
    if value == "buff" then return "buff" end
    return nil
end

local function NormalizeSource(value)
    if value == "hidden" then return "hidden" end
    if value == "special_rule" then return "special_rule" end
    return "normal"
end

local function Seed(id, category, detectionSource, name, source)
    id = math.floor(tonumber(id) or 0)
    category = NormalizeCategory(category)
    if id <= 0 or category == nil then return end
    if Classification.registry[id] ~= nil then return end -- first seed wins
    Classification.registry[id] = {
        category = category,
        detectionSource = NormalizeSource(detectionSource),
        name = tostring(name or ""),
        source = tostring(source or "seed"),
    }
    Classification.seedCount = Classification.seedCount + 1
end

------------------------------------------------------------------------
-- Seeding. The Buff ID Registry adapter (rs_buff_ids.lua) is the wiki-verified
-- polarity source; Plates curated sets supply hidden/special-rule provenance.
------------------------------------------------------------------------
local function SeedFromBuffLibrary()
    local byId = S.GameIds and S.GameIds.Buff and S.GameIds.Buff.ById or nil
    if type(byId) ~= "table" then return end
    for id, record in pairs(byId) do
        local kind = type(record) == "table" and record.kind or nil
        local name = type(record) == "table" and record.name or nil
        if kind == "buff" then Seed(id, "buff", "normal", name, "seed_buff_library")
        elseif kind == "debuff" then Seed(id, "debuff", "normal", name, "seed_buff_library") end
    end
end

local function SeedFromPlates()
    local plates = S.GameIds and S.GameIds.Plates or nil
    if type(plates) ~= "table" then return end
    -- Hidden timer corrections: effects the RU client hides; they stay
    -- detectable and trackable but now classify as a normal category.
    local corrections = type(plates.EffectTimerCorrections) == "table" and plates.EffectTimerCorrections.hidden or nil
    for id in pairs(type(corrections) == "table" and corrections or {}) do
        Seed(id, "debuff", "hidden", nil, "seed_plates_hidden")
    end
    -- Magic circle buffs are curated special-rule effects (positive).
    for _, id in ipairs(type(plates.MagicCircleBuffIds) == "table" and plates.MagicCircleBuffIds or {}) do
        Seed(id, "buff", "special_rule", nil, "seed_plates_magic_circle")
    end
end

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

-- Resolve the user-visible category for an entry, honouring manual overrides.
-- `sources` is the AuraObservationV3 entry.sources table (buff/debuff/hidden).
function Classification:ClassifyEntry(entry, overrideMap)
    entry = type(entry) == "table" and entry or {}
    local id = math.floor(tonumber(entry.id or entry.effectId) or 0)
    local sources = type(entry.sources) == "table" and entry.sources or {}
    local overrides = type(overrideMap) == "table" and overrideMap or self.overrides

    -- 1. user override
    if id > 0 then
        local user = NormalizeCategory(overrides[id])
        if user ~= nil then
            return { category = user, detectionSource = NormalizeSource(sources.hidden == true and "hidden" or (sources.special ~= true and "normal" or "special_rule")) }
        end
    end

    -- 2. seeded registry
    local seeded = id > 0 and self.registry[id] or nil
    if seeded ~= nil then
        local detectionSource = sources.hidden == true and "hidden" or seeded.detectionSource
        return { category = seeded.category, detectionSource = detectionSource }
    end

    -- 3. snapshot sources heuristic
    if sources.debuff == true then return { category = "debuff", detectionSource = "normal" } end
    if sources.buff == true then return { category = "buff", detectionSource = "normal" } end

    -- 4. default: unknown hidden-sourced effects classify as debuff
    if sources.hidden == true then return { category = "debuff", detectionSource = "hidden" } end
    return { category = "buff", detectionSource = "normal" }
end

-- Same resolution for a bare id (imports/migration do not always have a
-- snapshot). Unknown ids classify as buff - migration keeps every previously
-- tracked id visible instead of dropping data.
function Classification:ClassifyId(id, overrideMap)
    id = math.floor(tonumber(id) or 0)
    if id <= 0 then return nil end
    local overrides = type(overrideMap) == "table" and overrideMap or self.overrides
    local user = NormalizeCategory(overrides[id])
    if user ~= nil then return { category = user, detectionSource = "normal" } end
    local seeded = self.registry[id]
    if seeded ~= nil then return { category = seeded.category, detectionSource = seeded.detectionSource } end
    return { category = "buff", detectionSource = "normal" }
end

function Classification:SetOverride(id, category)
    id = math.floor(tonumber(id) or 0)
    category = NormalizeCategory(category)
    if id <= 0 then return false, "Buff ID 无效" end
    if category == nil then return false, "分类必须是 buff 或 debuff" end
    self.overrides[id] = category
    return true
end

function Classification:ClearOverride(id)
    id = math.floor(tonumber(id) or 0)
    if id <= 0 then return false, "Buff ID 无效" end
    self.overrides[id] = nil
    return true
end

function Classification:GetOverrides()
    local out = {}
    for id, category in pairs(self.overrides) do out[tonumber(id) or id] = category end
    return out
end

-- Replace all persisted overrides (used by store apply/migrate). Empty table
-- clears corrections; invalid values are dropped, never preserved.
function Classification:ApplyOverrides(map)
    local nextOverrides = {}
    if type(map) == "table" then
        for id, category in pairs(map) do
            local numeric = math.floor(tonumber(id) or 0)
            local normalized = NormalizeCategory(category)
            if numeric > 0 and normalized ~= nil then nextOverrides[numeric] = normalized end
        end
    end
    self.overrides = nextOverrides
    return true
end

-- Full classification registry snapshot (export/import support). Returns rows
-- sorted by id with category/detectionSource/name and whether it is a user fix.
function Classification:GetRegistrySnapshot(includeSeeds)
    local rows = {}
    if includeSeeds == true then
        for id, record in pairs(self.registry) do
            rows[#rows + 1] = {
                id = id, category = record.category, detectionSource = record.detectionSource,
                name = tostring(record.name or ""), source = tostring(record.source or "seed"),
            }
        end
    end
    for id, category in pairs(self.overrides) do
        local record = self.registry[id]
        rows[#rows + 1] = {
            id = id, category = category,
            detectionSource = type(record) == "table" and record.detectionSource or "normal",
            name = type(record) == "table" and tostring(record.name or "") or "",
            source = "user",
        }
    end
    table.sort(rows, function(a, b) return (tonumber(a.id) or 0) < (tonumber(b.id) or 0) end)
    return rows
end

function Classification:GetHealth()
    local overrideCount, registryCount = 0, 0
    for _ in pairs(self.overrides or {}) do overrideCount = overrideCount + 1 end
    for _ in pairs(self.registry or {}) do registryCount = registryCount + 1 end
    return {
        ok = true, version = self.version, seedCount = self.seedCount,
        overrideCount = overrideCount, registryCount = registryCount,
    }
end

SeedFromBuffLibrary()
SeedFromPlates()

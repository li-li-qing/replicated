------------------------------------------------------------------------
-- Replicated Suite V3 - Status Classification Service
--
-- 纯分类 Authority：category=buff/debuff/unknown；hidden/special_rule 是来源。
-- 旧接口保留，未知不再默认 Buff，详见下方 v2 维护注释。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Services = S.Services or {}

-- 中文维护注释（分类 v2）：资源类型曾把 393 个 unknown 全部升级为正面 Buff。
-- Authority 仍是本纯服务；Native 事实来自 Aura，用户 override 来自 Feature Store。
-- 顺序：用户 > Native 无冲突 lane > 明确静态极性 > 特殊规则 > unknown。
-- Hidden 只说明探测来源，计时修正规则不证明负面极性。这里不调用 Native、不持久化事实，
-- 不根据名称/ID 规律推断分类；旧 ClassifyId/override 接口保持兼容。
local Classification = {
    version = 2, presentationBoundary = "service_only", registry = {}, overrides = {}, seedCount = 0,
    hits = { user=0, native=0, verified_static=0, special_rule=0, unknown=0 }, conflicts = 0,
}
S.Services.StatusClassificationV3 = Classification
local function NormalizeCategory(value)
    if value == "buff" or value == "debuff" then return value end
    return nil
end
local function NormalizeSource(value)
    if value == "hidden" or value == "special_rule" then return value end
    return "normal"
end
local function Seed(id, category, detectionSource, name, source, confidence)
    id = math.floor(tonumber(id) or 0)
    if id <= 0 or Classification.registry[id] ~= nil then return end
    Classification.registry[id] = { category=NormalizeCategory(category) or "unknown",
        detectionSource=NormalizeSource(detectionSource), name=tostring(name or ""),
        source=tostring(source or "seed"), confidence=confidence or "unknown" }
    Classification.seedCount = Classification.seedCount + 1
end
local function SeedFromBuffLibrary()
    local byId = S.GameIds and S.GameIds.Buff and S.GameIds.Buff.ById or {}
    for id, record in pairs(byId) do
        local category = type(record) == "table" and NormalizeCategory(record.effectCategory) or nil
        if category ~= nil then Seed(id, category, "normal", record.name, "skill_effects", "verified_static") end
    end
end
local function SeedFromPlates()
    local plates = S.GameIds and S.GameIds.Plates or {}
    local corrections = type(plates.EffectTimerCorrections) == "table" and plates.EffectTimerCorrections.hidden or {}
    for id in pairs(corrections) do Seed(id, "unknown", "hidden", nil, "timer_correction_only", "unknown") end
    for _, id in ipairs(plates.MagicCircleBuffIds or {}) do
        Seed(id, "buff", "special_rule", nil, "curated_magic_circle", "special_rule")
    end
end
local function Result(self, category, detectionSource, confidence, source, conflict)
    self.hits[confidence] = (self.hits[confidence] or 0) + 1
    if conflict == true then self.conflicts = self.conflicts + 1 end
    return { category=category, detectionSource=detectionSource, confidence=confidence, source=source, conflict=conflict==true }
end
function Classification:ClassifyEntry(entry, overrideMap)
    entry = type(entry) == "table" and entry or {}
    local id = math.floor(tonumber(entry.id or entry.effectId) or 0)
    local sources = type(entry.sources) == "table" and entry.sources or {}
    local overrides = type(overrideMap) == "table" and overrideMap or self.overrides
    local seeded = self.registry[id]
    local detection = sources.hidden == true and "hidden" or (sources.special == true and "special_rule" or "normal")
    local user = NormalizeCategory(overrides[id])
    if user ~= nil then return Result(self, user, detection, "user", "override") end
    if sources.buff == true and sources.debuff == true then
        return Result(self, "unknown", detection, "unknown", "native_lane_conflict", true)
    end
    if sources.debuff == true then return Result(self, "debuff", detection, "native", "native_debuff") end
    if sources.buff == true then return Result(self, "buff", detection, "native", "native_buff") end
    if seeded ~= nil then
        return Result(self, seeded.category, sources.hidden == true and "hidden" or seeded.detectionSource, seeded.confidence, seeded.source)
    end
    return Result(self, "unknown", detection, "unknown", "unverified")
end
function Classification:ClassifyId(id, overrideMap)
    id = math.floor(tonumber(id) or 0)
    if id <= 0 then return nil end
    return self:ClassifyEntry({id=id}, overrideMap)
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
    -- 中文维护注释：统计仅复制固定大小的计数，不把可变内部表交给诊断调用者。
    local hits = {}; for key,value in pairs(self.hits) do hits[key]=value end
    for _ in pairs(self.overrides or {}) do overrideCount = overrideCount + 1 end
    for _ in pairs(self.registry or {}) do registryCount = registryCount + 1 end
    return {
        ok = true, version = self.version, seedCount = self.seedCount, conflicts = self.conflicts, hits=hits,
        overrideCount = overrideCount, registryCount = registryCount,
    }
end

SeedFromBuffLibrary()
SeedFromPlates()

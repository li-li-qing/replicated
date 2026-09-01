------------------------------------------------------------------------
-- Replicated Suite V3 - Combat Source Proxy Catalog
--
-- Static identities for player-placed skill entities whose combat source name
-- is the skill object rather than a player. This catalog classifies the source;
-- it never guesses an owner.
--
-- Hot-path contract:
--   * O(1) exact lookup by source name / ability id
--   * no fuzzy/tag matching and no runtime Native lookup
--   * no owner inference from target, distance, timing or "latest caster"
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Data = S.Data or {}

local function Trim(value)
    local text = tostring(value or "")
    return text:match("^%s*(.-)%s*$") or ""
end

local C = {
    version = 1,
    Specs = {},
    BySourceName = {},
    ByAbilityId = {},
    ByAbilityName = {},
}

local function Register(spec)
    if type(spec) ~= "table" or tostring(spec.id or "") == "" then return end
    C.Specs[spec.id] = spec
    for _, name in ipairs(spec.sourceNames or {}) do
        name = Trim(name)
        if name ~= "" then C.BySourceName[name] = spec end
    end
    for _, abilityId in ipairs(spec.abilityIds or {}) do
        abilityId = tonumber(abilityId)
        if abilityId ~= nil and abilityId > 0 then C.ByAbilityId[math.floor(abilityId + 0.5)] = spec end
    end
    for _, name in ipairs(spec.abilityNames or {}) do
        name = Trim(name)
        if name ~= "" then C.ByAbilityName[name] = spec end
    end
end

-- RU client tooltip verified by the user on 2026-08-31: Healing Fountain is a
-- player-cast skill that persists for 60 seconds and periodically heals nearby
-- allies. The current API bundle exposes no reliable generic owner link from the
-- placed proxy entity back to its caster, so sourceName="治愈之泉" is classified
-- as a SKILL_PROXY and intentionally left unattributed rather than fabricated as
-- a player or guessed owner.
Register({
    id = "healing_fountain",
    kind = "PLAYER_PLACED_SKILL_PROXY",
    category = "heal",
    durationMs = 60000,
    ownerAttribution = "UNAVAILABLE_NO_RELIABLE_OWNER_LINK",
    sourceNames = { "治愈之泉", "治愈之泉：波涛", "治愈之泉：绿叶" },
    abilityNames = { "治愈之泉", "治愈之泉：波涛", "治愈之泉：绿叶" },
    abilityIds = { 11948, 41224, 41225 },
    verification = "ru_client_tooltip+static_skill_catalog:2026-08-31",
})

function C:ResolveSource(sourceName, category)
    local spec = self.BySourceName[Trim(sourceName)]
    if spec == nil then return nil end
    category = tostring(category or "")
    if category ~= "" and tostring(spec.category or "") ~= "" and category ~= spec.category then return nil end
    return spec
end

function C:ResolveAbility(abilityId, abilityName, category)
    local id = tonumber(abilityId)
    local spec = id ~= nil and self.ByAbilityId[math.floor(id + 0.5)] or nil
    if spec == nil then spec = self.ByAbilityName[Trim(abilityName)] end
    if spec == nil then return nil end
    category = tostring(category or "")
    if category ~= "" and tostring(spec.category or "") ~= "" and category ~= spec.category then return nil end
    return spec
end

function C:Get(id)
    return self.Specs[tostring(id or "")]
end

S.Data.CombatSourceProxyCatalog = C

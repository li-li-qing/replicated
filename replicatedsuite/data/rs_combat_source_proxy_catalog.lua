------------------------------------------------------------------------
-- Replicated Suite · 战斗来源代理目录
-- 作者：Replicated
-- QQ群：1104129461
--
-- 玩家放置的技能实体以技能对象名称作为战斗来源；本目录只分类来源，不猜测所属玩家。
-- 热路径仅按来源名称/ability ID 做 O(1) 精确查询；禁止模糊/标签匹配和运行时 Native 查询，也禁止按目标、距离、时间或最近施法者推断所有者。
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

-- 2026-08-31用户核实RU tooltip：治愈之泉由玩家施放，持续60秒，周期治疗附近盟友。当前API无可靠通用代理实体→施法者关联，因此sourceName=治愈之泉分类为SKILL_PROXY并明确未归属，禁止编造玩家或猜所属者。
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

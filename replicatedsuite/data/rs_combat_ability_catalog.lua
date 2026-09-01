------------------------------------------------------------------------
-- Replicated Suite V3 - Combat Ability Catalog
--
-- Load-time compiled O(1) combat metadata derived from the already bundled
-- SkillEffects registry. Runtime combat callbacks must never scan SkillEffects
-- or run broad tag/name matching. Classification produced from names is marked
-- inferred; verified Skill/Buff ids remain the identity authority.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Data = S.Data or {}

local Source = S.Data.SkillEffects
local C = {
    version = 1,
    BySkillId = {},
    ByBuffId = {},
    SongSkillByBuffId = {},
    counts = { skills = 0, buffs = 0, songs = 0, control = 0, utility = 0 },
}
S.Data.CombatAbilityCatalog = C

local CONTROL_RULES = {
    { type = "stun", tokens = { "眩晕", "stun" } },
    { type = "trip", tokens = { "倒地", "trip" } },
    { type = "charm", tokens = { "魅惑", "charm" } },
    { type = "sleep", tokens = { "催眠", "sleep" } },
    { type = "silence", tokens = { "沉默", "silence" } },
    { type = "fear", tokens = { "恐惧", "惊悚", "fear" } },
    { type = "root", tokens = { "束缚", "root" } },
    { type = "freeze", tokens = { "冻结", "冰冻", "freeze" } },
    { type = "petrify", tokens = { "石化", "petr" } },
    { type = "disarm", tokens = { "解除装备", "disarm" } },
    { type = "blind", tokens = { "视力模糊", "致盲", "blind" } },
    { type = "taunt", tokens = { "挑衅", "taunt" } },
    { type = "imprison", tokens = { "水之禁锢", "禁锢", "imprison" } },
    { type = "airborne", tokens = { "浮空", "腾空", "airborne" } },
}

local UTILITY_RULES = {
    { type = "interrupt", tokens = { "打断", "妨碍施法", "interrupt" } },
    { type = "dispel", tokens = { "驱散", "dispel" } },
    { type = "cleanse", tokens = { "净化", "解除负面", "cleanse", "purify" } },
    { type = "resurrection", tokens = { "复活", "resurrect", "revive" } },
    { type = "defensive", tokens = { "防御壁垒", "魔法防御", "护盾", "无敌", "defensive", "shield" } },
}

local function Text(value) return tostring(value or "") end
local function Lower(value) return string.lower(Text(value)) end
local function HasToken(text, token)
    return string.find(text, Lower(token), 1, true) ~= nil
end
local function AddUnique(list, seen, value)
    if value == nil or seen[value] == true then return end
    seen[value] = true
    list[#list + 1] = value
end
local function Classify(texts, rules)
    local out, seen = {}, {}
    for _, raw in ipairs(texts) do
        local text = Lower(raw)
        if text ~= "" then
            for _, rule in ipairs(rules) do
                for _, token in ipairs(rule.tokens) do
                    if HasToken(text, token) then AddUnique(out, seen, rule.type); break end
                end
            end
        end
    end
    return out
end
local function IsSongName(name)
    name = Text(name)
    return string.sub(name, 1, string.len("[演奏]")) == "[演奏]"
end

for buffId, row in pairs(type(Source) == "table" and type(Source.buffs) == "table" and Source.buffs or {}) do
    local id = tonumber(buffId)
    if id ~= nil then
        local name = Text(row and row.name)
        C.ByBuffId[id] = { id = id, name = name, kind = Text(row and row.kind or "unknown"), controlTypes = Classify({ name }, CONTROL_RULES), source = "SkillEffects.buffs", verification = "verified_id_name" }
        C.counts.buffs = C.counts.buffs + 1
    end
end

for treeKey, tree in pairs(type(Source) == "table" and type(Source.trees) == "table" and Source.trees or {}) do
    for skillId, skill in pairs(type(tree) == "table" and type(tree.skills) == "table" and tree.skills or {}) do
        local id = tonumber(skillId)
        if id ~= nil then
            local effects, texts = {}, { Text(skill.name) }
            for _, effect in ipairs(type(skill.effects) == "table" and skill.effects or {}) do
                local buffId = tonumber(effect.buffId)
                local item = {
                    buffId = buffId,
                    name = Text(effect.name),
                    target = Text(effect.target or "unknown"),
                    kind = Text(effect.kind or "unknown"),
                }
                effects[#effects + 1] = item
                texts[#texts + 1] = item.name
            end
            local controlTypes = Classify(texts, CONTROL_RULES)
            local utilityTypes = Classify(texts, UTILITY_RULES)
            local songcraft = IsSongName(skill.name)
            local row = {
                id = id,
                name = Text(skill.name),
                tree = Text(treeKey),
                treeName = Text(tree and tree.name_cn),
                effects = effects,
                songcraft = songcraft,
                controlTypes = controlTypes,
                utilityTypes = utilityTypes,
                controlConfidence = #controlTypes > 0 and "inferred_from_verified_effect_name" or "none",
                utilityConfidence = #utilityTypes > 0 and "inferred_from_verified_skill_effect_name" or "none",
                source = "SkillEffects",
                verification = "verified_skill_id_name",
            }
            C.BySkillId[id] = row
            C.counts.skills = C.counts.skills + 1
            if songcraft then
                C.counts.songs = C.counts.songs + 1
                for _, effect in ipairs(effects) do
                    if effect.buffId ~= nil then C.SongSkillByBuffId[effect.buffId] = id end
                end
            end
            if #controlTypes > 0 then C.counts.control = C.counts.control + 1 end
            if #utilityTypes > 0 then C.counts.utility = C.counts.utility + 1 end
        end
    end
end

function C:GetSkill(id) return self.BySkillId[tonumber(id)] end
function C:GetBuff(id) return self.ByBuffId[tonumber(id)] end
function C:GetSongSkillForBuff(id) return self.SongSkillByBuffId[tonumber(id)] end
function C:IsControlSkill(id) local row = self:GetSkill(id); return row ~= nil and #row.controlTypes > 0 end
function C:IsSongSkill(id) local row = self:GetSkill(id); return row ~= nil and row.songcraft == true end
function C:GetHealth()
    return { version = self.version, skills = self.counts.skills, buffs = self.counts.buffs, songs = self.counts.songs, control = self.counts.control, utility = self.counts.utility }
end

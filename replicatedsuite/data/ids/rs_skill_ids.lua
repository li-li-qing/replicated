------------------------------------------------------------------------
-- Replicated Suite - Skill ID Registry Adapter
--
-- rs_skill_effects.lua remains the relationship/source-data file. This adapter
-- imports its skill identities into the shared registry once, at addon load.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local Registry = S.GameDataRegistry
local Library = S.Data and S.Data.SkillEffects or nil
if Registry == nil or type(Library) ~= "table" or type(Library.trees) ~= "table" then return end

S.GameIds = S.GameIds or {}
S.GameIds.Skill = S.GameIds.Skill or { ById = {}, Trees = {} }
local Out = S.GameIds.Skill
local SOURCE = "wiki.archerage.to/ru-cn via rs_skill_effects.lua"

for treeKey, tree in pairs(Library.trees) do
    local treeIds = {}
    local skills = type(tree) == "table" and tree.skills or nil
    if type(skills) == "table" then
        for skillId, skill in pairs(skills) do
            local id = tonumber(skillId)
            if id ~= nil then
                local key = "SKILL_" .. tostring(id)
                local record = Registry:Register("skill", key, id, {
                    name = type(skill) == "table" and skill.name or nil,
                    family = tostring(treeKey),
                    tags = { "SKILL", "TREE_" .. tostring(treeKey):upper() },
                    source = SOURCE,
                    confidence = "database_verified",
                    verified = true,
                    verifiedAt = "2026-08-25",
                })
                Out.ById[id] = record or { id = id, name = skill and skill.name or nil }
                treeIds[#treeIds + 1] = id
            end
        end
    end
    table.sort(treeIds)
    Out.Trees[treeKey] = treeIds
    Registry:RegisterSet("skill", "TREE_" .. tostring(treeKey):upper(), treeIds, {
        name = type(tree) == "table" and tree.name_cn or tostring(treeKey),
        source = SOURCE,
        confidence = "database_verified",
        verified = true,
        verifiedAt = "2026-08-25",
        tags = { "SKILL_TREE" },
    })
end

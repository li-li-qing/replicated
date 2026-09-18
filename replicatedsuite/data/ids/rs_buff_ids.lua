------------------------------------------------------------------------
-- Replicated Suite - Buff/Debuff ID Registry Adapter
--
-- rs_skill_effects.lua remains the authoritative scraped effect source. This
-- adapter provides O(1) shared ID/name/tag/family lookup for every known buff.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local Registry = S.GameDataRegistry
local Library = S.Data and S.Data.SkillEffects or nil
if Registry == nil or type(Library) ~= "table" or type(Library.buffs) ~= "table" then return end

S.GameIds = S.GameIds or {}
S.GameIds.Buff = S.GameIds.Buff or { ById = {} }
local Out = S.GameIds.Buff
local SOURCE = "wiki.archerage.to/ru-cn via rs_skill_effects.lua"

for buffId, buff in pairs(Library.buffs) do
    local id = tonumber(buffId)
    if id ~= nil then
        local kind = type(buff) == "table" and tostring(buff.kind or "unknown") or "unknown"
        local tags = { "EFFECT" }
        if kind == "buff" then tags[#tags + 1] = "BUFF"
        elseif kind == "debuff" then tags[#tags + 1] = "DEBUFF"
        else tags[#tags + 1] = "KIND_UNKNOWN" end
        local record = Registry:Register("buff", "BUFF_" .. tostring(id), id, {
            name = type(buff) == "table" and buff.name or nil,
            tags = tags,
            source = SOURCE,
            confidence = "database_verified",
            verified = true,
            verifiedAt = "2026-08-25",
            notes = kind == "unknown" and "Buff/Debuff polarity not yet verified in-game" or nil,
        })
        -- 中文维护注释（资源身份与极性分离）：Registry.kind="buff" 是资源命名空间，
        -- 不是正面效果证明。Adapter 拥有独立元数据视图，保留 Registry identity 兼容旧消费者；
        -- effectCategory 只来自 SkillEffects 明示 kind。禁止把 unknown 用资源 kind 覆盖。
        local entry = {}
        for key, value in pairs(record or {}) do entry[key] = value end
        entry.id, entry.name = id, type(buff) == "table" and buff.name or nil
        entry.resourceKind, entry.effectCategory = "buff", kind
        Out.ById[id] = entry
    end
end

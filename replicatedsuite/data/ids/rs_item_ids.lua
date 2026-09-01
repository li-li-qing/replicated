------------------------------------------------------------------------
-- Replicated Suite - Shared Item IDs
--
-- Keep reusable item identities here. Business modules consume these values;
-- they must not duplicate magic item IDs in hot/runtime code.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
if S.GameDataRegistry == nil then return end

S.GameIds = S.GameIds or {}
local I = {
    BLUE_SALT_BOND = 41488,
    -- Lower-case keys intentionally preserve the historical Constants shape
    -- consumed by Resident/Trade services.
    BOND_MATERIAL = {
        fabric = 8256,
        leather = 16327,
        lumber = 8337,
        iron = 8318,
    },
}
S.GameIds.Item = I

local source = "legacy constants / ArcheRage RU curated data"
local function Register(key, id, name, tags)
    S.GameDataRegistry:Register("item", key, id, {
        name = name,
        tags = tags,
        source = source,
        confidence = "curated",
    })
end

Register("BLUE_SALT_BOND", I.BLUE_SALT_BOND, "蓝盐商会债券证书", { "BOND", "CURRENCY_ITEM" })
Register("BOND_MATERIAL_FABRIC", I.BOND_MATERIAL.fabric, "布料", { "BOND_MATERIAL" })
Register("BOND_MATERIAL_LEATHER", I.BOND_MATERIAL.leather, "皮革", { "BOND_MATERIAL" })
Register("BOND_MATERIAL_LUMBER", I.BOND_MATERIAL.lumber, "木材", { "BOND_MATERIAL" })
Register("BOND_MATERIAL_IRON", I.BOND_MATERIAL.iron, "铁锭", { "BOND_MATERIAL" })

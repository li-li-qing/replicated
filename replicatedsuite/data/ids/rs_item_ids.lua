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
    -- 中文维护注释（2026-09-24，原大陆居民板材料 Authority）：公开 ArcheRage 当前数据库确认
    -- 10504..10515 六组原大陆居民板任务分别消耗王子/女王/祖先的钱袋与箱子。旧 Bonds 只保存
    -- 任务 ID，却没有把这 6 个真实 ItemType 纳入统一背包快照，导致原大陆行即使出现也只能显示
    -- “持有 ? / 缺口 ?”。物品身份统一放在共享 GameIds.Item，Bonds 只消费映射，禁止在 Feature 热路径
    -- 重新散落魔数。兼容边界：仅新增静态身份，不改变 Store schema；后续 RU 若替换任务物品，必须先
    -- 重新核对数据库/实机再改这里，不能按文本猜 ItemType。
    AURORIA_BOND_MATERIAL = {
        prince_purse = 35461,
        prince_crate = 42076,
        queen_purse = 40928,
        queen_crate = 42077,
        ancestor_purse = 43176,
        ancestor_crate = 43177,
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
Register("AURORIA_BOND_PRINCE_PURSE", I.AURORIA_BOND_MATERIAL.prince_purse, "王子的钱袋", { "BOND_MATERIAL", "AURORIA" })
Register("AURORIA_BOND_PRINCE_CRATE", I.AURORIA_BOND_MATERIAL.prince_crate, "王子的箱子", { "BOND_MATERIAL", "AURORIA" })
Register("AURORIA_BOND_QUEEN_PURSE", I.AURORIA_BOND_MATERIAL.queen_purse, "女王的钱袋", { "BOND_MATERIAL", "AURORIA" })
Register("AURORIA_BOND_QUEEN_CRATE", I.AURORIA_BOND_MATERIAL.queen_crate, "女王的箱子", { "BOND_MATERIAL", "AURORIA" })
Register("AURORIA_BOND_ANCESTOR_PURSE", I.AURORIA_BOND_MATERIAL.ancestor_purse, "祖先的钱袋", { "BOND_MATERIAL", "AURORIA" })
Register("AURORIA_BOND_ANCESTOR_CRATE", I.AURORIA_BOND_MATERIAL.ancestor_crate, "祖先的箱子", { "BOND_MATERIAL", "AURORIA" })

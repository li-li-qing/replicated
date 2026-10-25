-- Replicated Suite · 物品身份注册
-- 作者：Replicated
-- QQ群：1104129461
-- 可复用物品身份集中在本表；业务模块消费这些值，禁止在运行时热路径重复散落魔数 Item ID。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
if S.GameDataRegistry == nil then return end

S.GameIds = S.GameIds or {}
local I = {
    BLUE_SALT_BOND = 41488,
    -- 小写键保留 Resident/Trade 服务使用的历史 Constants 数据形态。
    BOND_MATERIAL = {
        fabric = 8256,
        leather = 16327,
        lumber = 8337,
        iron = 8318,
    },
    -- RU 数据库的居民任务 10504..10515 消耗王子/女王/祖先钱袋和箱子；共享映射供 Bonds 背包持有量查询。
    -- 后续替换物品须先核实数据库或实机，不能按文本猜 ItemType。
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

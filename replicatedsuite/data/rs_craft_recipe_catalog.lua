-- 已核对的固定配方资料；按配方 ID 维护，拍卖价格不放在这里。
-- 新增记录格式：records["配方ID"] = {
--   product = { itemType=产物ID, count=每次产出, grade=明确品质或省略, name="名称" },
--   materials = { { itemType=材料ID, count=每次用量, grade=明确品质或省略, name="名称" } },
--   labor = 核对过的每次劳力或省略, feeCopper = 核对过的每次手续费铜币或省略
-- }
-- 未核实的数据保持缺项；角色实际劳力可在小窗人工覆盖，不能用 0 冒充未知。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
ReplicatedSuite.Data = ReplicatedSuite.Data or {}
ReplicatedSuite.Data.CraftRecipeCatalog = { schemaVersion=1, records={}, items={
    -- API 品质与官网图标分开：实机普通材料使用 0，不能按官网 Basic 图标 1 改成 API 品质 1。
    -- 固定品质只补齐缺项或配方占位；明确的非零品质仍须严格匹配。
    [46156]={fixedGrade=2,source='https://wiki.archerage.to/ru-en/db/items/46156'},
    [8319]={fixedGrade=0,source='https://wiki.archerage.to/ru-en/db/items/8319'},
    [44773]={fixedGrade=5,source='https://wiki.archerage.to/ru-en/db/items/44773'},
    [43476]={fixedGrade=3,source='https://wiki.archerage.to/ru-ru/db/items/43476'},
} }

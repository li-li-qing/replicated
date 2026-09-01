# Replicated Suite 静态 ID 权威（Static Data Authority）

> **Authority Level**: REFERENCE
> 这是静态身份命名空间与当前核验基线的**唯一权威查表**。逐条审计与数据源见 `Archive/2026-08-27/`（STATIC_ID_AUDIT）与 `Archive/Validation/`。
> 禁止在业务代码中用编号规律推测未核 ID；新增未核 ID 会触发 Foundation Gate 告警。

## 1. 身份命名空间（必须分离）

| 命名空间 | 含义 | 不可用 X 替代 |
|----------|------|---------------|
| `trade_craft.craftId` | Commerce 制作公式 ID | — |
| `trade_good.productItemId` | 产出货物 Item ID | 不能用 Craft ID |
| `trade_material.compactId` | 旧版材料兼容编号 1..74 | 不能当 Item ID |
| `trade_material.itemId` | 服务器物品 ID | — |
| `instance.databaseZoneId` | 数据库 Map Zone ID | 不能用 runtimeInstanceId |
| `instance.runtimeInstanceId` | 客户端 `X2BattleField` 运行时副本类型 | 不能用 databaseZoneId |
| `quest.id` | Quest ID | 数据库聚合/包装任务不得默认成为玩家完成判定 Authority |
| `combat_source_proxy` | 玩家放置技能实体 → proxy family / 已核 ability IDs | 不能把 proxy sourceName 当玩家 Actor，也不能据此猜 owner |

## 2. 当前核验基线（R4，2026-08-27）

| 域 | 基线 | 备注 |
|----|------|------|
| Trade Craft（Primary Recipe） | **98/98** database_verified | Commerce Craft Registry 共 161 条（98 Primary + 29 社区中心 + 34 肥料） |
| Ingredient Signature | **98/98** 独立冻结 | 位于 `data/ids/rs_trade_craft_ids.lua`；不能由 `rs_trade_materials.lua` 运行时生成（避免循环验证） |
| Trade Product ItemID | **98/98** verified，`pending=0`，`duplicates=0` | `rs_trade_product_ids.lua`；14 个 pending 已在 R4 全部逐项 wiki 核验补齐 |
| Quest | **214/214** database_verified，`curated_pending=0` | 共享 Quest Registry |
| Instance Database Zone | **19/19** verified | 原 9 + R2 新增 10 |
| Instance Runtime | verified=0，observed varies | session-only 候选，不自动提升为静态 |
| Legacy compact material | 74 个继续兼容 | `trade_material.compactId` |

## 3. 启动期契约

静态层顺序固定：`Register → Index → Validate → Seal`。运行期无网页查询、无新增 Tick 扫描/复杂 Tag 匹配/动态资源加载。

Foundation Gate 强约束：
- 98/98 Primary Craft ID 覆盖；
- 98/98 Ingredient Signature 完整覆盖，缺失/mismatch 均为 blocker；
- Quest 214/214 全 verified，新增 pending 产生 Gate 告警；
- ≥19 Database Zone identity，Runtime namespace 独立统计。

## 4. 数据文件指针（运行时）

- `data/ids/rs_trade_craft_ids.lua` — Craft + Ingredient Signature
- `data/ids/rs_trade_product_ids.lua` — Trade Product ItemID（与 CraftID 区分命名空间）
- `data/ids/rs_quest_ids.lua`（推断名）— Quest Registry
- `data/ids/rs_instance_ids.lua`（推断名）— Database Zone
- `rs_static_data_v2.lua` / `rs_data_registry.lua` — 统一注册/索引/校验入口
- `data/rs_combat_source_proxy_catalog.lua` — 战斗技能代理 exact index；当前治愈之泉 family=11948/41224/41225，owner 规则不在静态层猜测

## 5. 已修正的旧配方错误（供追溯）

- `9337` Aubre Commercial Local Specialty：`Ground Spices x150 + Egg x10`
- `11564` Sungold Coastal Gilda Specialty：`Crimson Petunia x3 + Gilda Star x5 + Medicinal Powder x300`
- `11580` Sungold Coastal Local Specialty：`Carrot x15 + Dried Flowers x150`
- `6270` Hasla Preserved Local Specialty：应为 `Orchard Puree x160 + Cornflower x5`（旧表误写 Medicinal Powder x150）

## 6. 禁止做法

- 用 Craft ID 替代 productItemId，或反之；
- 把大地图 Zone / Quest Category ID / 名称排序号冒充 `X2BattleField entry.type`；
- 用编号序列推断未核 Item/Quest/Instance ID；
- 在运行时由业务模块自行生成签名清单元（破坏循环验证）。

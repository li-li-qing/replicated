# Replicated Suite 静态 ID 审计（2026-08-27 / R2）

## 范围

本轮继续处理长期共享身份层：跑商 Craft / Recipe、Quest、Instance Database Zone。业务完成逻辑、UI 和实时 `X2BattleField` 解析不在本轮替换范围内。

## 身份命名空间

必须保持以下 ID 空间分离：

- `trade_craft.craftId`：Commerce 制作公式 ID。
- `trade_good.productItemId`：产出货物 Item ID；不能用 Craft ID 代替。
- `trade_material.compactId`：Replicated Suite 旧版材料兼容编号 1..74；不能当 Item ID。
- `trade_material.itemId`：服务器物品 ID。
- `instance.databaseZoneId`：ArcheRage 数据库 Map Zone ID。
- `instance.runtimeInstanceId`：客户端 `X2BattleField` 运行时副本类型；不能用 `databaseZoneId` 代替。
- `quest.id`：Quest ID；数据库聚合/包装任务必须显式区分，不能默认成为玩家完成判定 Authority。

## 跑商

当前语义配方：98 条；74 个 legacy compact material ID 继续兼容。

Commerce Craft Registry 仍为 161 条：

- 98 条当前语义配方 Primary Craft ID（98/98）。
- 29 条 Community Center Local Specialty 备用制作入口。
- 34 条 Fertilizer Craft ID。
- 98 条语义配方合计 127 个非 Fertilizer Craft 引用。

### R2 配方完整核验

98 条 Primary Recipe 均具有独立冻结的 Ingredient Signature，Foundation Gate 要求：

`verifiedIngredientSignatures == recipes == 98 && ingredientSignatureFailures == 0`

签名清单位于 `data/ids/rs_trade_craft_ids.lua`，不能在运行时由 `rs_trade_materials.lua` 自己生成，否则会形成循环验证。

累计确认并修正 4 条旧配方错误：

1. Craft `9337` Aubre Commercial Local Specialty：`Ground Spices x150 + Egg x10`。
2. Craft `11564` Sungold Coastal Gilda Specialty：`Crimson Petunia x3 + Gilda Star x5 + Medicinal Powder x300`。
3. Craft `11580` Sungold Coastal Local Specialty：`Carrot x15 + Dried Flowers x150`。
4. Craft `6270` Hasla Preserved Local Specialty：旧表误写为 `Medicinal Powder x150 + Cornflower x5`；当前数据库为 `Orchard Puree x160 + Cornflower x5`。

### Commerce 数据源

- https://wiki.archerage.to/ru-en/db/crafts/commerce-vocation
- https://wiki.archerage.to/ru-en/db/crafts/6270
- https://wiki.archerage.to/ru-en/db/crafts/9337
- https://wiki.archerage.to/ru-en/db/crafts/11564
- https://wiki.archerage.to/ru-en/db/crafts/11580

### 尚未伪造的数据

98 条 Trade Good 的 `productItemId` 仍保持 `nil / product_item_id_pending`。虽然数据库已能逐步解析部分产物 Item ID，本轮不使用编号规律推测剩余值；只有逐项独立核对后才允许写入 authoritative registry。

## Quest

共享 Quest Registry 静态身份为 214 条，本轮已全部完成数据库身份核验：

- `database_verified`：214。
- `curated_pending`：0。

R2 新提升的重点集合包括：

- Whalesong / Aegis / Void Corps 的完整现有静态集合。
- Cinderstone / Ynystere `9960,9962..9966` Industry Dynamo 日常。
- Lusca `5765`、Abyssal Seaknight `6973..6976`、Stopping Doomsday `6791`。
- Garden / Auroria Botanical Research `10145..10148,10188,10189`。
- Eastern / Western Hiram 与 Auroria Dashboard 周常集合：`9317,9318,9326,9077,11196,10334,10335,9131,9017,9019,9020,9021,9052,9053`。
- Akasch Invasion `9000449,10699..10705,10708,11200`。
- Guardian Scramble `11096,11098,11099,11116,11131..11133`。
- JMG / Prophecy `5969..5972,9000467`。
- Hasla / Anthalon / Path of Glory：`5884,5885,5886,7396,7648,7649,8909,9494`。
- Rookborne Festival `6758..6761,6784,6785,7802..7804`。
- Dashboard / event IDs `7736,7737,9000170,9000333,9000531`。

原有 Blue Salt Bond、Auroria Resident、Crimson Rift、Grimghast、Halcyona、世界 Boss 等已核数据继续保留。Foundation Gate 现在要求当前 214 条身份全部 verified，后续新增未核 ID 会重新出现验证告警。

`9000448 Crimson Omens` 继续作为数据库 aggregate/wrapper 身份，不作为玩家阶段完成 Authority。

### Quest 数据源

- https://wiki.archerage.to/ru-en/db/quests/daily-kind
- https://wiki.archerage.to/ru-cn/db/quests/11154
- https://wiki.archerage.to/na-en/db/quests/category-167
- https://wiki.archerage.to/na-en/db/quests/category-51
- https://wiki.archerage.to/na-en/db/quests/5969
- https://wiki.archerage.to/na-en/db/quests/5970
- https://wiki.archerage.to/na-en/db/quests/5971
- https://wiki.archerage.to/na-en/db/quests/5972
- https://wiki.archerage.to/ru-ru/db/quests/category-237

## Instance

`databaseZoneId` 已从 9 条扩展到 19 条；`runtimeInstanceId` 仍全部保持 `nil`。

原有 9 条：

- Red Dragon's Keep: 121
- Kadum: 132
- Mistmerrow: 78
- Mistsong Summit: 89
- Ipnysh Sanctuary: 105
- The Fall of Hiram City: 122
- Noryette Challenge: 125
- Hereafter Rebellion: 130
- Garden of the Gods: 133

R2 新增 10 条数据库 Map Zone：

- Burnt Castle Armory: 45
- Greater Burnt Castle Armory: 84
- Hadir Farm: 46
- Greater Hadir Farm: 83
- Palace Cellar: 47
- Greater Palace Cellar: 86
- Kroloal Cradle: 52
- Greater Kroloal Cradle: 88
- Greater Sharpwind Mines: 87
- Greater Howling Abyss: 58

这些值只属于数据库 Map Zone namespace。没有把入口所在大地图 Zone、Quest Category ID 或名称排序号冒充成 `X2BattleField entry.type`。

当前状态：

- Database Zone verified: 19
- Runtime Instance verified: 0
- Runtime Instance pending: 19

## 启动期契约

静态层继续保持：

`Register -> Index -> Validate -> Seal`

Foundation Gate R2 强化：

- 98/98 Primary Craft ID 覆盖。
- 98/98 Ingredient Signature 完整覆盖，任何签名缺失或 mismatch 均为 blocker。
- Quest 214/214 database verification 完整覆盖；任何新增 pending 会产生 Gate 告警。
- 至少 19 个 Database Zone identity，且 Runtime namespace 独立统计。

运行期没有网页查询，没有新增 Tick 扫描、复杂 Tag 匹配或动态资源加载。

## R3 - Trade Product ItemID / Runtime Instance Observation

- Added `rs_trade_product_ids.lua` as a dedicated product ItemID namespace.
- 84/98 trade products are directly verified from current ArcheRage Trademaster achievement item lists.
- 14 products intentionally remain pending: Silent Forest Aged Garlic; 3 Windscour products; 10 Auroria products.
- `rs_trade_static_v2.lua` now resolves verified product ItemIDs by canonical legacy name and preserves pending status for unresolved products.
- Foundation diagnostics now report `verifiedProductIds/pendingProductIds` separately.
- `X2BattleField entry.type` observations are session-only candidates. They are not promoted to static verified runtime IDs automatically.
- QuestService records a matched runtime candidate through `GameIds.Instance:ObserveRuntimeCandidate()` after localized-name resolution.

R3 expected baseline: Trade Product ItemID 84/98, pending 14; Quest 214/214; Instance DB 19, Runtime verified 0, Runtime observed varies by live client scan.
\n\n## R4 - Trade Product ItemID 98/98 / Runtime observation conflict guard\n\nR4 completes the remaining 14 Trade Product ItemID identities. Each row was verified against an ArcheRage Wiki item page and/or a Crafting Folio product link; no ID was inferred only from a numeric sequence.\n\n### Newly verified Product ItemIDs\n\n- Silent Forest Aged Garlic: `26485`\n- Windscour Preserved Gilda Specialty: `31849`\n- Windscour Preserved Specialty: `31872`\n- Windscour Preserved Local Specialty: `31912`\n- Aegis Coastal Gilda Specialty: `50652`\n- Whalesong Coastal Gilda Specialty: `50653`\n- Exeloch Coastal Gilda Specialty: `50654`\n- Sungold Coastal Gilda Specialty: `50655`\n- Golden Ruins Coastal Gilda Specialty: `50656`\n- Aegis Coastal Local Specialty: `50674`\n- Whalesong Coastal Local Specialty: `50675`\n- Exeloch Coastal Local Specialty: `50676`\n- Sungold Coastal Local Specialty: `50677`\n- Golden Ruins Coastal Local Specialty: `50678`\n\nCurrent Trade Product identity baseline: `98/98 database_verified`, `pending=0`, `duplicates=0`. Product ItemID remains a distinct namespace from CraftID. `trade_recipe` now also stores its resolved `productItemId`, product identity status, and identity source, so Product -> Craft(s) -> Recipe -> Material linkage is available without a runtime name scan.\n\n### Product identity sources\n\n- https://wiki.archerage.to/na-en/db/items/26485\n- https://wiki.archerage.to/na-en/db/items/31849\n- https://wiki.archerage.to/na-en/db/items/31872\n- https://wiki.archerage.to/na-en/db/items/31912\n- https://wiki.archerage.to/ru-en/db/crafts/commerce-vocation\n- https://wiki.archerage.to/na-en/db/items/50653\n- https://wiki.archerage.to/na-en/db/items/50675\n- https://wiki.archerage.to/na-en/db/items/50676\n\nSome Auroria item pages intermittently return an HTTP/application error through the public renderer, so those identities were additionally cross-checked against current ArcheRage Wiki Commerce/skill/object database rows that expose the same explicit ItemID/name pair.\n\n### Runtime Instance observation\n\n`X2BattleField entry.type` remains a session-only Proxy observation and is still never promoted into static `runtimeInstanceId` Authority automatically. R4 adds a candidate evidence table per semantic instance key:\n\n- repeated observations of the same runtime ID increment its count;\n- a second distinct runtime ID is retained as separate evidence;\n- conflicting observations set `observed_conflict_pending_static_verification`;\n- an ambiguous observation exposes no single `runtimeInstanceId`;\n- Foundation reports observed candidate conflicts separately.\n\nThis adds no new poller, Timer, Tick, or X2BattleField query. It only enriches the existing successful QuestService observation point with O(1) session-table updates.\n\nR4 expected static baseline: Trade Product ItemID `98/98`, pending `0`, duplicates `0`; Quest `214/214`; Instance DB `19`, Runtime static verified `0`, Runtime observed/conflicts depend on live client evidence.\n
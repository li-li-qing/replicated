# Phase 1 Batch A：源码故障域拆分报告（2026-09-28）

Build: `v3-m1.16.0.18.330-phase0-trust-baseline`（Phase 1 第一轮；本轮未推进新的正式 BuildTag）
范围：§23.4 通用装配骨架 + §23.8 Batch A（`tools_social`、`tools_market_analysis`）。**未进入 Batch B。**

---

## 1. 结论

```text
rs_business_bridge.lua  5223 → 4829 行（−394）
注册点                  15 → 13 个 Feature
新增独立单元            4 个（工厂 / 拍卖读模型 / social / market_analysis）
业务行为                1:1（契约表逐项对照，无一处放宽）
门禁                    默认 Full Runner exit=0；--feature-split 23/23；其余门禁全绿
```

---

## 2. 为什么先抽工厂（§23.4）

`rs_business_bridge.lua` 已是 Lua 5.1 单 chunk local 配额的主要风险点（FND-001）。如果继续把 Feature
写在同一个 chunk 里，新增少量顶层 local 就可能让**整片业务同时不可编译**。所以 Batch A 的第一件事
不是搬 Feature，而是把“与业务无关的装配骨架”先收敛成一个共享单元：

```text
features/shared/rs_feature_slice_factory.lua   →  S.FeatureSliceFactory
```

工厂内容（全部经代码证明通用，无业务判断）：

| 成员 | 依据 |
|---|---|
| `Copy` | 全项目深拷贝入口，自动走 `S.Utils.DeepCopy` |
| `Text` / `Number` / `Trim` | 分别被 bridge 内 15 / 13 / 17 处调用 |
| `Call` / `Action` | capability 适配；**保留**“能力名前缀回退到同名全局宿主”的既有语义 |
| `RegisterStore` / `Load` | 通用 Store 注册与读取，参数/Schema 与拆分前逐字一致 |
| `PersistentState` | 永久字段白名单快照 |
| `PersistStateMutation` | Feature State 快照事务（Persistence `MutateStore` 薄包装，无第二条 SaveData 旁路） |
| `NewFeature` | 装配骨架（Store → Authority → Demand → RegisterImplementation 顺序不变） |

禁止入厂（本轮也没入）：Bag 扫描/搬运、Craft 配方解析、Auction 搜索/报价、Range 圆数学、
Unit line 投影、Boss 规则表、Team 角色逻辑。

bridge 只保留同名 local 别名 → 本文件内剩余 13 个 Feature 的调用点**逐字不变**。

---

## 3. 拍卖共享读模型的归属判定（§23.7）

`tools_market_analysis` 与 `tools_auction` 共用一组 helper（Demand 绑定、快照读取、投影形状、设置命令）。
按 §23.7 决策树：

```text
A. 是共享“事实”？        否 —— 事实归 AuctionQueryV3 / PriceQuoteQueueV3 / AuctionSearchBridgeV3
B. 无状态通用装配工具？    否 —— 只服务拍卖语义
C. 某个 Feature 的私有判断？也不是 —— grep 证明恰好 2 个消费方
D. 无法判断 → STOP？      不适用：A/B/C 都有明确证据，且它不读任何 Feature 私有长期 State
```

处置：独立单元 `features/tools/auction/rs_auction_read_model.lua`（发布为 `S.AuctionReadModel`），
明确“**不拥有事实、不发起 Native 查询、不持有 Feature State 长期副本**”。这样同时避免了两种错误：

```text
✗ 让 market_analysis 反向依赖 tools_auction 的私有 helper（Feature → Feature 隐式耦合）
✗ 把 helper 复制两份（复制长期 Authority）
```

---

## 4. 契约前后对照（§31 模板，逐项已核）

### tools_social → `features/tools/social/rs_social_feature.lua`

| 契约 | 前 | 后 | 相同 |
|---|---|---|---|
| Feature ID | `tools_social` | `tools_social` | ✓ |
| Registry route | `tools.social` | 未改 | ✓ |
| Store ID / owner | `v3.business.tools_social` / `v3.tools_social` | 同 | ✓ |
| Store schema | schema1 / legacy0 / Account / Permanent / budget 不变 | 同 | ✓ |
| ApiDependencies | 8 × `X2Friend:*` | 同集合 | ✓ |
| Demand id/owner | `feature:tools_social` / feature | 同 | ✓ |
| Scheduler / Event | 无 / 无 | 无 / 无 | ✓ |
| UpdateTopic | `v3.business.tools_social.updated` | 同 | ✓ |
| Commands | Refresh, Block, Unblock, Mute, Unmute, IsFriend | 同（共 6） | ✓ |
| Projection 键 | revision/rows/status/error(有错才出现) | 同 | ✓ |
| Presentation | `rs_v3_business_pages.lua` | 未改 | ✓ |

### tools_market_analysis → `features/tools/market_analysis/rs_market_analysis_feature.lua`

| 契约 | 前 | 后 | 相同 |
|---|---|---|---|
| Feature ID | `tools_market_analysis` | 同 | ✓ |
| Registry route | `tools.market_analysis` | 未改 | ✓ |
| Store ID / owner | `v3.business.tools_market_analysis` / `v3.tools_market_analysis` | 同 | ✓ |
| ApiDependencies | 3 × `X2Auction:*` | 同 | ✓ |
| Demand id/owner | `feature:tools_market_analysis` / feature | 同 | ✓ |
| Event 订阅 | Demand 0→1 订阅 `v3.auction_query.updated` + `v3.price_quote.completed`；1→0 解绑 | 同（共享读模型统一实现） | ✓ |
| UpdateTopic | `v3.business.tools_market_analysis.updated` | 同 | ✓ |
| Commands | Refresh, SetKeyword, SetExactMatch, SetResultLimit, Search | 同（共 5） | ✓ |
| Projection 键 | 基础 4 键 + 读模型 15 键（keyword/favoriteMax/resultCount/quoteStatus…） | 同 | ✓ |
| 契约版本 | `AuctionQueryContractVersion = 1` | 同 | ✓ |
| Presentation | `rs_v3_business_pages.lua`（与 auction 共分页） | 未改 | ✓ |

---

## 5. 新增门禁：`tools/rs_feature_slice_split_tests.lua`

runner 新增 `--feature-split`，并**并入默认 Full Runner**（与 `--unfinished-closure` 分开计数，
避免把“拆分契约”和“未完成能力收口”混为一种语义）。23 条断言覆盖：

```text
每个被拆 Feature 只注册一次（RegisterImplementation 计数 == 1，且实现表就是该 Feature）
Feature/Store(owner,schema,lifetime,scope)/UpdateTopic/Demand/Commands/Projection/ApiDependencies 不变
读取路径：三种名单返回形态归一、allMember=true、等级取整、离线标记、未识别条目不泄露 table 地址
状态降级：ready / partial / empty / unavailable 一一对应，失败绝不伪装成空名单
边界：>200 条显式截断并给说明；nil 名单不伪造成员也不伪造失败
命令：写操作到达 X2Friend 且角色名被裁剪，空名被拒绝且不触达 Native；IsFriend 三种返回显式区分
market：投影同时保留基础键与读模型扩展键；无结果给“非历史成交价”提示；waiting→partial、failed→unavailable
market：Search 归一化后交给共享 AuctionQueryV3；共享读模型每次返回独立命令表实例
静态：bridge 不再定义被拆 Feature 的 helper/注册；三个新文件存在
静态：X2Friend 写能力仍在 core 能力表登记（拆分未绕过写边界）
```

---

## 6. 门禁结果（真实执行）

| 门禁 | 结果 |
|---|---|
| 默认 Full Runner | **PASS** exit=0，0 FAIL |
| `--feature-split` | **PASS** 23/23 |
| `--unfinished-closure` | **PASS** 14/14 |
| Lua 5.1 compile gate | **PASS** 265 shipped Lua files |
| Lua compatibility syntax | **PASS** 385 files（runtime = 真实 Lua 5.1） |
| Native Dependency Audit | **PASS** 0 ERROR / 0 BLOCKER / 0 WARN |
| Architecture Audit | **PASS** 49 既有债务（41 / 5 / 3），无新增 |
| Install Integrity | **PASS** 261/261 |
| Test Dependency Audit | **PASS** |

> bridge 仍是 GIANT_FILE（4829 行 > 4000），这是**已知债务**、也是 Phase 1 要继续消掉的目标；
> 本批次不允许为了让这个数字变好看而顺便改业务。

---

## 7. 修改文件

新增：

```text
features/shared/rs_feature_slice_factory.lua
features/tools/auction/rs_auction_read_model.lua
features/tools/social/rs_social_feature.lua
features/tools/market_analysis/rs_market_analysis_feature.lua
tools/rs_feature_slice_split_tests.lua
```

修改：

```text
toc.g                                        +6 行（装配顺序，各文件仍只登记一次）
features/rs_business_bridge.lua              别名化 + 删除已搬代码（5223 → 4829）
tools/rs_status_refactor_test_runner.py      +FEATURE_SPLIT_TESTS 常量、--feature-split、默认集合
tools/rs_udf_numeric_test_host.lua           补 Action / ActionCapability（写路径正式契约）
tools/rs_auction_favorites_tests.lua         按 toc 顺序补 factory/ARM/market 加载
tools/rs_craft_planner_tests.lua             同上（factory/ARM）
tools/rs_team_tools_tests.lua                同上（factory/ARM）
tools/rs_unit_lines_regression_tests.lua     同上（factory/ARM）
```

未改动（冻结项全部保持）：`core/**`、`services/**`、`presentation/**`、`ui/**`、`data/**`、
`native/**`、所有 Store ID/Schema、Feature ID、route、公开 Commands、Projection shape。

---

## 8. 未解决 / 下一批次注意

```text
1. 静态源码断言会随搬迁失效，必须“重定向”而不是删除：
   tools/rs_range_metric_calibration_tests.lua:219 与 tools/rs_window_viewport_tests.lua:436
   目前直接读 features/rs_business_bridge.lua 文本。拆 combat_range_assist / tools_bag 时必须改指向新文件。
2. 离线宿主必须复现 toc.g 顺序：已知 4 个 bridge 宿主已补 factory/ARM；后续新宿主同样要补。
3. tools_auction 仍留在 bridge（§23.8 排在第 12 位）。它的收藏 CRUD / Sidecar 命令是 tools_auction 私有，
   搬迁时不得并入 rs_auction_read_model.lua。
4. 下一批次（Batch B）建议：tools_reinforce_analysis、tools_portal_profiles、combat_siege_readiness
   —— 它们当前都是“runtime blocked / 只读占位”类，依赖最少。
5. 本轮仍无任何 RU 实机行为结论：所有结果都是离线契约证明。
```

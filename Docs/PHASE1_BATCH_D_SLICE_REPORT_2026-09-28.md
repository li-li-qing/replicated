# Phase 1 Batch D：源码故障域拆分报告（2026-09-28）

Build: `v3-m1.16.0.18.330-phase0-trust-baseline`（Batch 中间不推进新 BuildTag）
范围：§23.8 Batch D（`combat_team_tools`、`tools_craft`、`tools_auction`）+ 新增共享边界模块。
主记录见规划文档 §23.15。

---

## 1. 结论

```text
rs_business_bridge.lua   3940 → 2701 行（本轮 −1239；起点 5223）
注册点                   6 → 3 个 Feature（只剩 Batch E：tools_bag / combat_unit_lines / combat_range_assist）
FND-001                  主 chunk slots 187 → 104（本轮 −83；Batch A/B/C 合计只降 1，本轮才是真正的缓解）
新增共享归属              features/shared/rs_shared_bounds.lua（BagScanLimit = 240）
修复                     3 处拆分漏引用（Scalar / TeamCommandInteger / Trim）—— 由新的静态核查脚本发现
门禁                     默认 Full Runner exit=0；--feature-split 53/53；其余全绿
```

---

## 2. 本轮发现并修复的真实缺陷（重要）

### 2.1 tools_craft 运行期缺失 `Scalar`

C5 用例（背包持有量/缺口计算）在拆分后立即失败：

```text
features/tools/craft/rs_craft_feature.lua:40: attempt to call global 'Scalar' (a nil value)
```

根因：**依赖分析脚本第一版的正则要求 `local … =`，漏掉了所有 `local function X(...)` 定义**，
因此没发现 craft 引用了 bridge 的 chunk 级 `Scalar`。

修复：

```text
1. Scalar（从常见键名取第一个标量值的通用归一工具）按 §23.7-B 进工厂（FSF.Scalar），
   bridge 保留别名 —— 因为 bridge 内 bag 帮助函数仍在使用它；
2. 分析脚本修正为兼容 `local function` 与多赋值，并对全部 15 个拆出文件重跑核查 → 清零；
3. 把“静态核查脚本（比较 bridge 仍定义的 chunk 级 local 与拆出文件实际引用）”固化为
   后续每个批次的固定工序，且必须在跑测试之前执行。
```

### 2.2 team_tools 缺 `TeamCommandInteger` 与 `Trim`

同类问题：前者是 team_tools 专属的成员序号校验（1..maximum 正整数），按 §23.7-C **随 Feature 原样搬入**
（bridge 删除副本，避免第二份 Authority）；后者是工厂通用工具，补进 prologue。

### 2.3 复盘：为什么 Batch B/C 没有暴露同类问题

静态核查对全部 15 个拆出文件重跑后确认：除上述 3 个符号外没有其它缺失。
B/C 的 Feature 主体都在 `do ... end` 块里（自带私有 helper），对外依赖恰好只有工厂成员与宿主引用，
所以侥幸未触发；D 批的 craft 是第一个真正引用 bridge 顶层 helper 的搬迁。

---

## 3. `BAG_SCAN_LIMIT` 的归属判定（§23.7，本轮新增共享归属）

`BAG_SCAN_LIMIT = 240` 被 tools_bag（多处扫描/搬运）与 tools_craft 的持有量读取共同使用：

```text
A. 共享事实？            否 —— 它是“一次最多扫描多少背包槽位”的平台级上界（策略值），不是事实
B. 无状态通用装配工具？    否 —— 与 Bag 语义绑定，不能进工厂（工厂明确“不认识 Bag”）
C. 某个 Feature 的私有判断？ 否 —— 两个消费方
=> 结论：跨 Feature 共享的有界常量需要唯一归属 → features/shared/rs_shared_bounds.lua
   （S.SharedBounds.BagScanLimit = 240）；bridge 与 craft 文件都只从它读取。
```

这个共享模块只允许放“被多个 Feature 共享、且不属于任何单个 Feature”的有界常量；
不得演变成业务配置堆。

---

## 4. 契约前后对照表（§31 模板，已在 `--feature-split` 中逐项断言）

| 契约 | combat_team_tools | tools_craft | tools_auction |
|---|---|---|---|
| Feature ID / Store ID / owner | 不变 ✓ | 不变 ✓ | 不变 ✓ |
| Store schema | schema1 / Account / Permanent ✓ | 同 ✓ | 同 ✓ |
| ApiDependencies | 4 个（X2Team×2 + X2Unit×2）✓ | 6 个（X2Craft×4 + X2Bag×2）✓ | 6 个（X2Auction×4 + ADDON×2）✓ |
| Demand id/owner | `feature:<id>` / feature ✓ | 同 ✓ | 同 ✓ |
| UpdateTopic | `v3.business.<id>.updated` ✓ | 同 ✓ | 同 ✓ |
| Commands | 5 个 ✓（Refresh/SetAutoRoleEnabled/SetRole/MoveMember/MoveMemberToParty） | 7 个 ✓（Refresh/SelectRecipe/SetCraftType/SetItemType/SetDoodadId/QuoteMaterial/QuotePendingMaterials） | 13 个 ✓（Refresh/Search/SetKeyword/SetExactMatch/SetResultLimit/Quote/AddFavorite/RemoveFavorite/RenameFavorite/MoveFavorite/RemoveFavoriteByKeyword/ClearFavorites/SetSidecarEnabled） |
| 契约版本 | TeamRole 2 / AutoRoleCatalog 2 / AutoRoleDefaultOn 1 / AutoRoleRosterLease 1 / AutoRole 3 ✓ | CraftUserSelection 1 ✓ | SidecarPreference 1 / AuctionQuery 1 ✓ |
| 任务/令牌 | roster token `combat_team_tools:roster`、task `v3_team_auto_role_apply` ✓ | 无任务 ✓ | Sidecar 观察仍由 AuctionSurfaceV3 驱动 ✓ |
| Presentation | `rs_v3_business_pages.lua` | 同 + `rs_v3_craft_sidecar.lua` | 同 + `rs_v3_auction_sidecar.lua`（只读 facade）✓ |

---

## 5. tools_craft → PriceQuoteQueueV3 的传递归属（audit 新可见性）

tools_craft 拆出后，audit 第一次能按 Feature 归因这条传递边：

```text
WARN TRANSITIVE_SERVICE_NATIVE_UNCLASSIFIED  tools_craft  service=PriceQuoteQueueV3  namespaces=X2Auction
```

判定（按 audit 的 required/optional/lazy 定义）：**craft 从不直接调用 X2Auction** —— 报价请求由用户显式
触发并转发给共享 PriceQuoteQueueV3，结果也只从该队列的 read model 读取。因此按 **lazy** 分类，
X2Auction 的 ownership 归 PriceQuoteQueueV3 自己；**不得**升成 tools_craft 的 hard dependency
（否则会把队列的 namespace 伪装成 craft 的能力）。已在 `SERVICE_EDGE_NATIVE_POLICY` 增加该行，
分类后 audit 回到 `0 ERROR / 0 BLOCKER / 0 WARN`。

> 备注：队列侧真正的 lazy lease（`AcquireApi`）与其它 Service 一样属于 Phase 3 的 descriptor 收口项。
> 这条 WARN 是拆分带来的**新可见性**，不是新依赖——搬之前它藏在巨型 chunk 里无法归因。

---

## 6. 门禁结果（真实执行）

| 门禁 | 结果 |
|---|---|
| 默认 Full Runner | **PASS** exit=0，0 FAIL |
| `--feature-split` | **PASS** 53/53（A 23 + B 12 + C 11 + D 7） |
| `--unfinished-closure` | **PASS** 14/14 |
| Lua 5.1 compile gate | **PASS** 276 shipped Lua files |
| Lua compatibility syntax | **PASS** 396 files（runtime = 真实 Lua 5.1） |
| Native Dependency Audit | **PASS** 0 ERROR / 0 BLOCKER / 0 WARN |
| Architecture Audit | **PASS** 48 债务（GIANT_FILE 2：persistence / life bundle） |
| Install Integrity | **PASS** 261/261 |
| Test Dependency Audit | **PASS** |

---

## 7. 修改文件

新增：

```text
features/combat/team_tools/rs_team_tools_feature.lua   (467 行)
features/tools/craft/rs_craft_feature.lua              (676 行)
features/tools/auction/rs_auction_feature.lua          (177 行)
features/shared/rs_shared_bounds.lua                   (21 行)
```

修改：

```text
toc.g                                        +5 行（共享边界 + 三个新文件各登记一次）
features/rs_business_bridge.lua              删除三个 Feature 与 dead RestoreState（3940 → 2701）
features/shared/rs_feature_slice_factory.lua + FSF.Scalar（通用值归一工具，Batch D 补漏）
tools/rs_feature_slice_split_tests.lua       +7 条 Batch D 契约断言（累计 53）
tools/rs_native_dependency_audit.py          +SERVICE_EDGE_NATIVE_POLICY 一行（tools_craft → PriceQuoteQueueV3 lazy X2Auction）
Docs/Replicated_Suite_底层框架重构规划_v1.md   §23.15 + 状态表
Docs/Replicated_Suite_#U…_v1.md              别名同步
Docs/DOCS_FILE_INDEX.md                      新增本报告条目
```

未改动：`core/**`、`services/**`、`presentation/**`、`ui/**`、`data/**`、`native/**`、所有 Store ID/Schema、
Feature ID、route、公开 Commands、Projection shape、Scheduler/EventBus/Persistence 语义。

---

## 8. 未解决 / 下一批次注意

```text
1. 本轮仍无 RU 实机结论。
2. PriceQuoteQueueV3 及其它 Service 的 lazy lease（AcquireApi 收口）属于 Phase 3。
3. tools_bag / tools_craft 之外的 craft 相关文件（features/life/craft/rs_craft_assistant_surface_extension_v3.lua）
   仍是独立 extension，不属于 tools_craft Authority 本体；本轮未触碰。
4. 最后一批 Batch E：tools_bag（搬运事务/黑名单/快捷按钮，风险最高）、combat_unit_lines、
   combat_range_assist（高频投影，必须证明 cadence 与 projection 契约不变）。
   完成后 rs_business_bridge.lua 预计可以整体删除或退化为空壳。
5. 静态核查脚本已证明有效，建议在 Batch E 之前把它正式化（可并入 rs_test_dependency_audit 或独立工具）。
```

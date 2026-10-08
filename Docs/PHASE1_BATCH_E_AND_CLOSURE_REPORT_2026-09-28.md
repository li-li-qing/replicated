# Phase 1 Batch E 与 Phase 1 闭合报告（2026-09-28）

Build: `v3-m1.16.0.18.331-phase1-feature-slice-complete`（Phase 1 完成时的唯一一次正式 BuildTag 推进）
范围：§23.8 Batch E（`tools_bag`、`combat_unit_lines`、`combat_range_assist`）+ **rs_business_bridge.lua 退役**。

---

## 1. 一句话结论

**Phase 1 完成**：`rs_business_bridge.lua`（5223 行、15 个 Feature、188 chunk local slots）已全部拆成
15 个独立 Feature 源码单元并退役删除；全部门禁绿；未改任何 Store/Feature/route/Commands/Projection 契约。

---

## 2. Batch E 范围

```text
features/tools/bag/rs_bag_feature.lua                     tools_bag（1922 行，最后一个巨型 Feature）
features/combat/unit_lines/rs_unit_lines_feature.lua      combat_unit_lines
features/combat/range_assist/rs_range_assist_feature.lua  combat_range_assist
```

依赖分析结论（修正后的脚本）：三个区块对 bridge 的外部依赖只有
`S / P / AddonApi / BagApi / BankApi / CofferApi` + 工厂成员 —— 与前四批不同，这一批**没有**再发现漏引用，
说明 Batch D 引入的静态核查工序有效。

---

## 3. rs_business_bridge.lua 退役（Phase 1 的收口动作）

```text
- 文件整体删除（不留空壳），toc.g 同步移除；
- “文件不存在”是最强的禁止回填契约：它再出现就意味着有人把拆掉的 Feature 又塞回巨型 chunk；
- toc ↔ 磁盘一致性由 Install Integrity 重新验证：278/278 PASS。
```

连带收口（全部是“重定向”，没有删除断言）：

```text
1. 四个离线宿主：移除 dofile(bridge)，按 toc.g 顺序加载各自需要的 Feature 文件；
2. rs_range_metric_calibration_tests.lua：源码探针 → features/combat/range_assist/rs_range_assist_feature.lua（8/8 PASS）；
3. rs_window_viewport_tests.lua：外部几何校准探针 → features/tools/bag/rs_bag_feature.lua（66/66 PASS）；
4. --feature-split 的 4 处静态断言改为 bridge_retired()（文件不存在即通过），
   并新增“15 个 Feature 全部恰好注册一次”的总账断言（registrations 表恰好 30 个键）。
```

宿主改造过程中发现并修复了一个自伤：批量插入时把部分宿主的 Feature dofile 写重复了
（重复 dofile = 重复注册 = FeatureRuntime 报错），已去重并验证。

---

## 4. Batch E 契约对照（§31，已在 `--feature-split` 断言）

| 契约 | tools_bag | combat_unit_lines | combat_range_assist |
|---|---|---|---|
| Feature ID / Store ID / owner | 不变 ✓ | 不变 ✓ | 不变 ✓ |
| ApiDependencies | 12 个（X2Bag×4 / X2Bank×3 / X2Coffer×3 / ADDON×2）✓ | 2 个 ✓ | 3 个 ✓ |
| Scheduler task | `v3_business_bag_category_batch` / `…_quick_observe` / `…_quick_move` ✓ | `v3_business_unit_lines_refresh`（1ms 下限）✓ | `v3_business_range_assist_refresh`（16ms）✓ |
| Commands | 25 个 ✓ | 9 个 ✓ | 14 个 ✓（多圆 SetCircle*/AddCircle/RemoveCircle） |
| 契约版本 | BagMove 8 / BatchLifecycle 5 / NativeWindowQuick 7 / BagTaskMutex 2 等 ✓ | VisualGuide 5 / AdaptiveDensity 2 等 ✓ | VisualGuide 9 / WorldSpace 3 / ProjectionFacts 7 / MetricDistance 1 / MultiCircle 1 等 ✓ |
| 共享边界 | `S.SharedBounds.BagScanLimit`（唯一 Authority，禁写死数字）✓ | — | — |

---

## 5. Phase 1 前后总账

| 指标 | Phase 1 前（.330） | Phase 1 后（.331） |
|---|---|---|
| `rs_business_bridge.lua` | 5223 行 / 15 Feature / 188 chunk slots | **已删除** |
| Feature 源码单元 | 15 个挤在一个 chunk | 15 个独立文件（每文件 slots 16–98） |
| 共享装配 / 边界 | 无 | `rs_feature_slice_factory.lua` + `rs_shared_bounds.lua` + 拍卖读模型 |
| Architecture Audit | 49 债务（GIANT_FILE 3） | **48 债务**（GIANT_FILE 2） |
| 门禁 | 无拆分契约 | `--feature-split` 59 断言并入默认 Full Runner |

Phase 1 全程**没有**发现生产回归：两批失败分别是“测试过期”（B）与“宿主不完整”（C），均按 §30 分类处理；
D 批的 `Scalar` 是拆分可见性引出的真缺陷，当天修复并把核查工序固化。

---

## 6. 门禁结果（真实执行）

| 门禁 | 结果 |
|---|---|
| 默认 Full Runner | **PASS** exit=0，0 FAIL |
| `--feature-split` | **PASS** 59/59 |
| `--unfinished-closure` | **PASS** 14/14 |
| Lua 5.1 compile gate | **PASS** 278 shipped Lua files |
| Lua compatibility syntax | **PASS** 398 files（真实 Lua 5.1） |
| Native Dependency Audit | **PASS** 0 ERROR / 0 BLOCKER / 0 WARN |
| Architecture Audit | **PASS** 48 债务（41 / 5 / 2），无新增 |
| Install Integrity | **PASS** 278/278 |
| Test Dependency Audit | **PASS** |
| Range Metric（重定向后） | **PASS** 8/8 |
| Window Viewport | **PASS** 66/66 |

---

## 7. 修改文件

新增：

```text
features/tools/bag/rs_bag_feature.lua
features/combat/unit_lines/rs_unit_lines_feature.lua
features/combat/range_assist/rs_range_assist_feature.lua
```

删除：

```text
features/rs_business_bridge.lua        （5223 行 → 退役）
```

修改：

```text
toc.g                                        bridge 移除 + Batch E 三个新文件
replicatedsuite.lua                          BuildTag → v3-m1.16.0.18.331-phase1-feature-slice-complete
tools/rs_feature_slice_split_tests.lua       +6 条 Batch E 断言（累计 59）；4 处静态断言改为 bridge_retired()
tools/rs_udf_numeric_test_host.lua 等 4 个宿主  bridge dofile 移除，改为按 toc 顺序加载 Feature
tools/rs_range_metric_calibration_tests.lua  源码探针重定向
tools/rs_window_viewport_tests.lua           源码探针重定向
Docs/Replicated_Suite_底层框架重构规划_v1.md   §23.16 + 状态表 + 基线行
Docs/Replicated_Suite_#U…_v1.md              别名同步
Docs/DOCS_FILE_INDEX.md                      新增本报告条目
```

---

## 8. 遗留与下一步

```text
1. 全部为离线契约证明；各 Feature 的 RU 实机验收仍待用户侧确认（Phase 3 收口）。
2. 剩余 48 项 Architecture 债务属 Phase 3/5/6；Service 侧 lazy lease（PriceQuoteQueueV3 等）属 Phase 3。
3. Phase 2（Life Bundle 拆分，§24）现在可以开始：life_m16_bundle.lua 5633 行、5 个 life Feature。
   方法论与 Phase 1 完全一致（工厂/共享边界/静态核查/feature-split 契约测试都已就绪），
   预期同样能把 life bundle 拆成独立单元并显著降低 chunk local 压力。
```

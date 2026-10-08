# Phase 1 Batch B：源码故障域拆分报告（2026-09-28）

Build: `v3-m1.16.0.18.330-phase0-trust-baseline`（Batch 中间不推进新 BuildTag）
范围：§23.8 Batch B（`combat_siege_readiness`、`tools_reinforce_analysis`、`tools_portal_profiles`）。
主记录见规划文档 §23.13；本文件补充可复现证据与未覆盖项。

---

## 1. 结论

```text
rs_business_bridge.lua   4829 → 4716 行（Batch A 起点为 5223）
累计注册点               15 → 10 个 Feature
新增独立单元             3 个
业务行为                 1:1（blocker 文案、SlotProbeRuntimeBlocked、聚合读取阶梯全部逐项断言）
门禁                     默认 Full Runner exit=0；--feature-split 35/35；其余全绿
```

---

## 2. 本轮最容易出事的三个点（已专门加断言）

### 2.1 blocker 文案是用户可见事实

`combat_siege_readiness` / `tools_portal_profiles` 是 blocker-only spec：没有 `read/commands`，
`Authority:Refresh` 直接产出 `status = "runtime_blocked"` 与一行
`{ key = "<id>:blocked", name = "运行时阻塞", text = <blocker>, statusText = "Runtime Blocked", tone = "warn" }`。
`text` 就是页面上给用户看的阻塞原因，**不是内部注释**。测试逐字比对两个 blocker 字符串。

### 2.2 `SlotProbeRuntimeBlocked` 是 blocker 级门禁依赖

`core/rs_foundation_gate.lua:2331-2334`：

```lua
local reinforceTruth = S.Features and S.Features.tools_reinforce_analysis or nil
if type(reinforceTruth) ~= "table" or reinforceTruth.SlotProbeRuntimeBlocked ~= true then
    truthFailures[#truthFailures + 1] = "tools_reinforce_analysis:slot_probe_runtime_block"
end
```

搬迁时漏掉 `S.Features.tools_reinforce_analysis.SlotProbeRuntimeBlocked = true` 会让
`v3_feature_truth_contract` 整体判失败。测试同时断言标记为 true **且** FoundationGate 仍引用该契约。

### 2.3 “不探测槽位”是安全边界，必须可回归

`tools_reinforce_analysis` 只允许无参 getter 与已导出 `ESRA_*` 常参 getter。测试通过记录
**每一次 Native 调用的实参**并断言其中从未出现整数槽位来固定这条边界：

```text
允许：GetTotalReinforceLevel() / SuitableLevelForEquipSlotReinforce() / GetBundleEffectTopLevel()
允许：GetAttributeTotalLevel(ESRA_OFFENCE|ESRA_DEFENCE|ESRA_SUPPORT) 及其两个同参 getter
禁止：任何 equipSlotIndex 整数（搬迁前就被 PRODUCT_COMPLETION_MATRIX 围栏）
```

---

## 3. 契约前后对照（§31）

见规划文档 §23.13.3 的三列对照表。要点：

```text
三个 Feature 的 Feature ID / Store ID / owner / schema / lifetime / scope / Demand / UpdateTopic 全部不变
命令面仍只有内置 Refresh（三者都没有 spec.commands）
两个 blocked Feature 的实现层不声明 ApiDependencies（Registry 才是它们的 dependency Authority）
reinforce 的 6 个 X2EquipSlotReinforce method 集合不变
```

---

## 4. 门禁结果（真实执行）

| 门禁 | 结果 |
|---|---|
| 默认 Full Runner | **PASS** exit=0，0 FAIL |
| `--feature-split` | **PASS** 35/35（Batch A 23 条 + Batch B 12 条） |
| `--unfinished-closure` | **PASS** 14/14 |
| Lua 5.1 compile gate | **PASS** 268 shipped Lua files |
| Lua compatibility syntax | **PASS** 388 files（runtime = 真实 Lua 5.1） |
| Native Dependency Audit | **PASS** 0 ERROR / 0 BLOCKER / 0 WARN |
| Architecture Audit | **PASS** 49 既有债务，无新增 |
| Install Integrity | **PASS** 261/261 |
| Test Dependency Audit | **PASS** |

---

## 5. 修改文件

新增：

```text
features/combat/siege_readiness/rs_siege_readiness_feature.lua
features/tools/reinforce_analysis/rs_reinforce_analysis_feature.lua
features/tools/portal_profiles/rs_portal_profiles_feature.lua
```

修改：

```text
toc.g                                      +4 行（三个新文件各登记一次）
features/rs_business_bridge.lua            删除三个 Feature + Reinforce helper + 两个 dead local
tools/rs_feature_slice_split_tests.lua     +12 条 Batch B 契约断言
Docs/Replicated_Suite_底层框架重构规划_v1.md  §23.13 + 状态表
Docs/Replicated_Suite_#U…_v1.md            别名同步
```

未改动：`core/**`（含 FoundationGate 的引用）、`services/**`、`presentation/**`、`ui/**`、`data/**`、
`native/**`、tool 宿主加载顺序（Batch B 的三个 Feature 没有被任何离线宿主单独 dofile）。

---

## 6. 未覆盖 / 下一批次注意

```text
1. 本轮仍无 RU 实机结论：全部是离线契约证明。三个 Feature 的实机验收仍待用户侧确认。
2. 逐槽位强化详情的合法 equipSlotIndex 契约仍是 SPECIFIC_RUNTIME_BLOCKED（产品能力缺口，不是本轮范围）。
3. tools_portal_profiles 的 X2Option 语义未验证 —— 搬迁后依旧只显示阻塞原因，未新增任何 Option 调用。
4. 下一批次（Batch C）按 §23.8 顺序：combat_target_monitor → combat_buff_cap →
   combat_boss_alerts → combat_raid_recruitment。注意：
   * combat_target_monitor 自带 Scheduler 距离任务与 reconcileDemand；
   * combat_boss_alerts 带 BOSS_OBSERVE_TASK、Aura/Casting 事实订阅与 Alerts 服务依赖；
   * 两者都必须在契约快照里记录 task name / owner / 事件订阅，拆完逐项比对。
5. tools_craft / tools_auction / tools_bag / combat_unit_lines / combat_range_assist 留在后面批次
   （依赖更多、运行态与 UI 联动更多）。
```

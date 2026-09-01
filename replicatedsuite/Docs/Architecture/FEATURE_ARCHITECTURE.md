# Replicated Suite Feature 架构（统一权威）

## M1.16.0.18.17 Presentation Read Model 补充

Combat Analytics 的排行 value 列表属于 Feature 输出的 detached read model。Presentation 不允许引用 Feature 文件 local table；其它 Feature 也应遵循同样边界：展示选项由 Feature/Service 投影，用户 mutation 只经 Commands。


> **Authority Level**: ARCHITECTURE
> **范围**: Feature 模块分类与契约、专业模块（DPS / Gear / Healer / Plates）架构要点。
> 本文由 Plates 历史架构审计/运行时/UI Diff 三文档（2026-08-26）收敛为 Plates 章节，并补充 Feature 分类总则。
> Plates 三文档为历史迁移记录，保留以备追溯；当前 Plates 实现以代码为准。


## 0. 当前 V3 Feature 生命周期 Contract

2026-08-28 起，Active TOC 的 Feature 由 `FeatureRuntime` 管理；Legacy Professional 源码不是当前 Runtime。

- Feature 可以独立 Enable/Disable；UI Visible 不等于 Enabled。
- 页面/悬浮窗通过 `AcquireConsumer(token)` / `ReleaseConsumer(token)` 表达真实运行需求。
- Consumer 状态必须委托 `S.Demand`，禁止业务手工维护第二套 first/last-consumer 状态机。
- Activities / Tasks / Instance Browser 已作为首批迁移验证。
- Feature 关闭时必须先清 Consumer Demand，再解除 UI/事件/任务；失败必须 fail-closed，不留下半持有下游 Service。
- Feature Demand 必须为其下游资源提供 `quiesce` 兜底：Activity/Task/Instance/Raid Readiness 在正常 `Clear` 失败时分别清理 Scheduler/事件、QuestProgress、InstanceCatalog、Roster/Aura 与瞬态 Authority；`FeatureRuntime:DisableAll()` 会把残留 Demand 记为 shutdown failure，即使强制清理成功也不伪装为无错误。
- 共享 Aura 只提供事实。Healer/DPS/Plates/Boss 等业务结论仍在对应 Feature Domain。
- M1.15.1 起 CombatEventBus 同样只提供事实：低成本 Feature 可申请 `scope=self`，需要团队/全局流的 Feature 才申请 `scope=all`。死亡回顾必须作为 CombatEventBus 独立 Consumer，禁止 `DeathReview → DPS Runtime`。
- `UnitIdentityV3` 的 endpoint bind/explicit kind 只是共享身份事实；PVP/PVE、敌我、治疗优先级、排名和统计仍由对应 Feature Domain 决定。
- M1.15.2 的 `combat_death_review` 是该 Contract 的首个战斗消费者：Feature Enabled 只持有 `CombatEventBus scope=self`，`showDebuffs=true` 时额外持有 Aura Consumer；关闭后两者均由 Demand 释放。死亡回顾只拥有自身受伤 ring、死亡窗口规则和历史投影，严禁向 DPS 请求数据。
- M1.15.2H 起，V3 Presentation 标准边界为 **Feature Projection + Commands**。Page/Widget 不应直接调用 `Feature.Authority`/Store/Demand；Authority/Feature Domain 也不直接控制 `WidgetHost`。Domain 发布事实/状态变化，Presentation 决定是否显示、弹窗、选中或布局。DeathReview 已作为首个战斗 Feature 执行该边界。
- Native Combat callback 只能 capture/queue，不能在同一调用栈执行 SaveData、强制 Aura 扫描、复杂历史构建或首次 UI 创建。
- 当前已迁移 Feature 的页面/悬浮窗/Modal 关联矩阵由 `UIV3Acceptance.migratedPresentation` 统一维护；`v3_37_migrated_page_build_matrix` 负责真实 PageHost 导航构建、遍历 39 个 Active Route 与 WidgetHost 实例化，`v3_39_modal_build_matrix` 负责实际 Modal 构建与换装 Modal Open/Close 栈回归；planned Feature 继续允许 fallback placeholder，不以空壳页面冒充迁移完成。

## 目录

1. [Replicated Plates Architecture Audit v1](#sec-1)
2. [Replicated Plates Runtime Foundation v1](#sec-2)
3. [Replicated Plates UI Diff Migration v1](#sec-3)

<a id="sec-1"></a>
## 1. Replicated Plates Architecture Audit v1

> 来源（已合并至本权威文档，原文件已收口）：`replicatedsuite\Docs\Architecture\Historical\REPLICATED_PLATES_ARCHITECTURE_AUDIT_v1_20260826.md`

## Replicated Plates Architecture Audit v1

### Implementation status · 2026-08-26

This document remains the historical audit baseline. Confirmed remediation already completed:

- Phase 11A: `GetEffectIds` full-scan Authority + Aura Factory Reset P0 fixes;
- Phase 11B: FrameBudget lane admission + Watchdog warm recovery;
- Phase 11C: Lines/Circle active-range diff + Effect Slot native-write diff.

Remaining audit items, especially Aura Observation Domain, GameData migration, Manager decomposition and Storage concern separation, are still active.

Date: 2026-08-26
Baseline: Addon(20260826-064420).zip
Scope: `replicatedsuite/modules/professional/plates/`

### 1. Executive Summary

Replicated Plates is not a module that needs to be rebuilt from zero. It already has several strong foundations: Native API access is mostly centralized in `rp_api.lua`; target data can reuse Suite Observation/TargetService; UI already implements partial diff updates; storage uses mature sharded/double-bank commit protocols; Runtime uses one main host instead of per-plate OnUpdate loops.

The main architecture problem is that Plates independently grew several “half-frameworks” that now overlap with Suite Foundation v2: Diagnostics, Persistence, UI Diff/Lifecycle, FrameBudget, GameData Registry and Domain ownership. The migration should preserve Plates' proven storage and runtime behavior while removing duplicate infrastructure and clarifying Authority boundaries.

### 2. Current Size

- `replicatedplates.lua`: 118 lines
- `rp_api.lua`: 1092 lines
- `rp_diagnostics.lua`: 217 lines
- `rp_manager.lua`: 3044 lines
- `rp_runtime.lua`: 1548 lines
- `rp_storage.lua`: 1787 lines
- `rp_ui.lua`: 2510 lines
- Total: about 10.3k lines

### 3. What Is Already Good

#### Native API Gateway

Direct `X2Unit` / `X2Skill` access is mostly concentrated in `rp_api.lua`. This is a strong boundary and should be retained rather than replaced wholesale.

#### Shared Observation / TargetService Reuse

Target vitals, distance, profession, gear and some effects already reuse Suite `Observation` and `TargetService` when available. Plates is therefore already partially aligned with the Foundation v2 Authority model.

#### Runtime Isolation

The main Runtime has one principal OnUpdate host, per-lane error isolation and generation guards. Optional features generally short-circuit when disabled. This is much healthier than a design with one OnUpdate per plate/widget.

#### Storage Safety

The tracking/aura stores use partitioning, double-bank writes, manifest flip-after-verification, backup snapshots, future-schema write fences and no write-during-load migration. This protocol is mature and must not be thrown away merely to make the code look uniform.

#### Partial UI Diff / Pools

Target/player plates already cache several text/health/cast/effect values, and line/circle renderers use pools instead of allocating new widgets every update. The problem is incomplete diffing, not the absence of performance awareness.

### 4. P0 Correctness Findings

#### P0-1: Duplicate `GetEffectIds` definition changes semantics — resolved

`rp_api.lua` previously defined `A:GetEffectIds` twice. It now has one explicit implementation with two documented modes: omitted `scanLimit` performs a complete cheap scan for Alerts, while a supplied limit performs the bounded rolling scan for discovery/capture.

Runtime Alerts continues to call `GetEffectIds(unit, "debuff")` without a limit and therefore receives the complete visible Debuff ID set. Manager call sites pass their rolling scan limit/cursor and retain bounded tooltip fallback.

The regression is covered by the single-definition/full-scan contract in the local Factory/Plates harness set; Boss/mechanic/debuff alerts no longer inherit the old first-slice cap.

Future migration to shared Aura Observation remains desirable, but is no longer required to close this P0 correctness issue.

#### P0-2: Factory Reset does not clear Aura Library stores — resolved

`Storage:BuildFactoryResetKeys()` now includes the Aura Library manifest and the fixed bounded shard space in addition to Plates primary/backup and tracking keys.

Missing families include the equivalent of:
- `<platesKey>_aura_manifest`
- `<platesKey>_aura_a_p1..p32`
- `<platesKey>_aura_b_p1..p32`

The local Factory Reset contract harness verifies the manifest, `a/b/c × 32` shard edges, deleted Gear payloads, ClearData execution, old-generation quiescing, and the reset write fence. RU Fresh Reload remains the required in-client confirmation that the cleared stores do not reappear after reload.

The Suite-owned keys are enumerated through `Persistence:GetPersistentKeys()`. Professional module stores remain explicitly bounded by their own Authorities because those modules are not Suite Store registrations.

### 5. Runtime / Frame Budget Audit

`rp_runtime.lua` currently has many independent due lanes: position, health, metadata, target metadata, distance, cast, cooldowns, manager/discovery/capture, buff cap, magic circle, alerts, lines, circle and effects.

Each lane is individually bounded, but Plates does not use Suite FrameBudget admission. When accumulators align, or `ForceAll()` is used, many lanes can execute in one frame.

#### Watchdog recovery burst

A second watchdog OnUpdate runs independently. If the main heartbeat appears stale it rebinds OnUpdate, calls `ForceAll()`, and directly invokes the Runtime update. This can cause exactly the wrong recovery behavior after a stall: all lanes become due and heavy work is executed immediately, bypassing Suite FrameBudget.

Recommended model:
- P0/P1: identity, essential target state, user-triggered critical work
- P2: health/effect observation required for correctness
- P3: cooldown/discovery/manager maintenance
- P4: line/circle visual work
- P5: diagnostics/watchdog maintenance

Watchdog should become a low-priority liveness check and never directly invoke a full heavy update.

### 6. Aura Observation Duplication

Aura/effect data is currently scanned through several independent paths:

- normal target/player effect display
- manager capture/discovery
- alert scanning
- target combat loadout inference
- some hidden-buff correction/policy

This means the same unit can have Buff/Debuff/Hidden Buff data read multiple times within nearby intervals.

Recommended architecture: introduce a Plates Aura Observation Domain (or a shared Suite aura observation capability where safe) that owns generation/snapshot data. Consumers become read-only proxies:

`Native Aura API -> Aura Observation Authority -> Display / Alerts / Discovery / Loadout`

Accuracy-critical consumers can request a targeted refresh, but they should not independently rescan the entire aura list.

### 7. UI Audit

`rp_ui.lua` has useful manual diff caches but still performs many unconditional Native writes.

#### Line renderer hotspot

Four dot pools of up to 64 labels can exist (up to 256 labels). Every line refresh first hides the full pool, then reapplies font/color/anchors/show state to active dots.

After the pool has been created, disabling/emptying lines can still result in repeated `Show(false)` calls over the entire pool on each refresh.

#### Circle renderer hotspot

The circle pool can contain up to 128 labels and follows the same hide-all / rewrite-active pattern.

Combined, these paths can generate thousands of redundant Native UI writes per second in high-frequency visual modes and are plausible contributors to `MakeSprite - too many sprite update` style pressure.

#### Effect slot diff is incomplete

Effect slots still repeatedly write visibility, extent, color, border visibility, duration style and pick state even when unchanged.

Recommended migration:
- use Suite RSUI Diff primitives or the same cache semantics
- track previous active counts for pooled dots and only hide the retired range
- cache font/color/static extent once
- diff anchors/visibility rather than reapplying every refresh
- connect UI writes to Suite Diagnostics counters

### 8. Manager Authority Audit

`rp_manager.lua` is the largest architectural concentration point. It currently combines:

- legacy combat-effect catalog
- effect classification policy
- session discovery state
- capture state
- import/export serialization
- aura package checksum/staging
- tracking mutation
- layout/manager logic
- standalone Native UI compatibility
- Suite compatibility methods

This should be split by Authority rather than by arbitrary file size.

Recommended targets:
- `rp_aura_observation.lua`
- `rp_tracking_domain.lua`
- `rp_effect_classification.lua` or shared GameData relations
- `rp_transfer_service.lua` (import/export)
- `rp_manager_presenter.lua`
- legacy standalone UI kept separately until Suite migration is stable

Runtime and Manager currently call each other in both directions. This cyclic coupling should be replaced with Domain commands/events/read-only projections.

### 9. Game Data Registry Audit

Plates still contains many reusable hardcoded IDs outside the shared registry:

- important cooldown skill IDs in Runtime
- magic-circle default Buff IDs
- target armor/weapon state Buff IDs
- hidden Buff timer correction ID 22969
- a large legacy CORE_PRESET with hundreds of effect IDs

The legacy CORE_PRESET contains roughly 641 numeric effect entries (about 620 unique IDs), making it effectively a second game-ID database.

Required direction:
- identity records -> central GameData Catalog
- semantic sets/relations -> GameData Relations
- runtime code -> semantic keys/sets, not raw numbers

Candidate sets/relations:
- `PLATES_IMPORTANT_COOLDOWNS`
- `PLATES_MAGIC_CIRCLE_BUFFS`
- `TARGET_ARMOR_SET_EFFECTS`
- `TARGET_WEAPON_STYLE_EFFECTS`
- `EFFECT_TIMER_CORRECTIONS`
- combat effect tags such as HARD_CC / IMMUNITY / HEAL_REDUCE / BURST

Unknown/unverified IDs must not be assigned invented meanings; preserve source/confidence metadata.

2026-08-30 代码层收口：`data/ids/rs_plates_ids.lua` 已登记 `PLATES_IMPORTANT_COOLDOWNS`、`PLATES_MAGIC_CIRCLE_BUFFS`、`TARGET_ARMOR_SET_EFFECTS`、`TARGET_WEAPON_STYLE_EFFECTS` 与 `EFFECT_TIMER_CORRECTIONS`。Legacy Runtime/API/Storage 通过 `GameIds.Plates` 消费这些关系；集合仍明确标记 `curated / verified=false`，不会把运行时待核验的魔法阵或兼容装备状态提升为数据库事实。`CORE_PRESET` 的大规模用户追踪库仍保持用户/Manager Authority，不在本切片强行改写。

### 10. Persistence Audit

Plates storage safety is stronger than the generic Suite store and should be preserved. The correct migration is not to replace the double-bank/sharded protocol, but to separate the concerns inside `rp_storage.lua` and expose store state to Suite Persistence/Diagnostics.

Current mixed responsibilities include settings model, settings normalization, migration, tracking mutations, aura-library data model, shard protocol and save transaction logic.

Recommended split:
- Settings Model
- Persistence adapter/transaction engine
- Tracking Domain
- Aura Library Domain

Ordinary settings should use Dirty + Debounce. Explicit imports/tracking commits can remain transactional/forced. The current mix of immediate `Save(true)` and local delayed saves should be unified.

### 11. Diagnostics Audit

`rp_diagnostics.lua` remains useful as an expert one-shot report. As of M1.16.0.18.5, the embedded Plates Runtime is a first-class Suite Diagnostics producer through a read-only facade; the expert report remains reference-only and is not the ongoing observability Authority.

The following should be structured counters/snapshots:
- Runtime lane executions/deferred counts
- FrameBudget admissions/rejections
- Native aura reads / tooltip fallbacks
- watchdog recoveries
- UI native writes/skips
- storage schema, bank/manifest and write-fence status
- dirty/save/verify/fence states
- Manager catalog, discovery, capture and import-staging session state
- aura observation generations and consumers

Keep `BuildReport()` as an expert snapshot, but make Suite DiagnosticsHub the ongoing observability Authority. The current producer chain is `rp_storage:GetPersistenceHealth()` / `GetTrackingHealth()` / `GetAuraLibraryHealth()` + `rp_manager:GetCatalogHealth()` / `GetDiscoveryHealth()` / `GetCaptureHealth()` / `GetImportStageHealth()` → `rp_runtime:GetRuntimeDiagnostics()` (`storageConcerns` / `managerConcerns`) → `DiagnosticsManager`; all producer reads are bounded, detached where mutable maps are involved, and read-only.

### 12. Hot Reload / Lifecycle

Generation guards prevent stale code from continuing to update, which is good. However Native widgets cannot be truly destroyed with the available UI API. Large line/circle pools can therefore accumulate across repeated development hot reloads.

Use RSUI OwnerScope semantics (handler release + hide + unregister + generation isolation) and expose physical/pool counts in Diagnostics. Do not invent a non-existent universal Destroy API.

### 13. Proposed Migration Order

1. P0 correctness patch: split `GetEffectIds`; fix Factory Reset Aura keys.
2. FrameBudget integration + watchdog recovery redesign.
3. Line/circle/effect-slot Diff migration and UI diagnostics.
4. Aura Observation Domain; make Display/Alerts/Discovery/Loadout read snapshots.
5. Centralize Plates skill/buff/effect IDs and semantic relations into GameData Registry.
6. Split Manager into Tracking / Classification / Transfer / Presenter.
7. Split Storage concerns while retaining double-bank/sharded transaction protocol; register status with Suite Persistence/Diagnostics.
8. Move remaining standalone compatibility UI later, after embedded Suite behavior is proven.

### 14. Files / Documents Requiring Manual Deletion

None identified in this audit.

No existing document currently requires physical deletion. Future implementation patches should update the architecture index and explicitly report any file that becomes obsolete and cannot be removed by overwrite-only installation.



<a id="sec-2"></a>
## 2. Replicated Plates Runtime Foundation v1

> 来源（已合并至本权威文档，原文件已收口）：`replicatedsuite\Docs\Architecture\Historical\REPLICATED_PLATES_RUNTIME_FOUNDATION_v1_20260826.md`

## Replicated Plates Runtime Foundation v1

日期：2026-08-26  
状态：Phase 11A + 11B 已落地

### 1. 本阶段目标

本阶段不重写 Plates Domain，也不改 Buff/技能判定规则，只处理架构审计中已经确认的两个 P0 正确性问题，并把 Plates 的独立 Runtime 接入 Suite Foundation：

1. 修复 `GetEffectIds()` 同名覆盖导致的 Alerts Debuff 漏扫；
2. 修复 Factory Reset 未清理 Aura Library 的持久化残留；
3. Plates 单一 Runtime Host 接入 Suite `FrameBudget`；
4. Watchdog 从“故障后立即 ForceAll + 直接 Runtime Pass”改为“P5 健康检查 + 温和恢复”；
5. Plates Runtime 状态进入 Suite Structured Diagnostics。

### 2. P0-1：Effect ID Scan Authority

#### 历史问题

`rp_api.lua` 曾存在两个同名：

```lua
A:GetEffectIds(...)
```

后定义的滚动扫描版本会覆盖前定义的完整扫描版本。Alerts 调用：

```lua
A:GetEffectIds(unit, "debuff")
```

因此实际落入滚动扫描默认值，只读取约 12 行，而不是所有可见 Debuff。

#### 当前 Contract

`GetEffectIds()` 现在只有一个 Authority：

```text
scanLimit == nil
    -> 完整、廉价、ID-only 扫描
    -> 不做 Tooltip fallback
    -> Alerts 使用

scanLimit != nil
    -> 最多 32 行滚动窗口
    -> bounded Tooltip fallback
    -> Discovery / Capture 使用
```

返回值保持：

```lua
ids, nextCursor, totalCount
```

只读取第一个返回值的历史调用保持兼容。

### 3. P0-2：Factory Reset Aura Library

Plates Tracking 与 Aura Library 是两个独立持久化 Authority。

Factory Reset 过去只清：

- Plates main/backup；
- Tracking manifest；
- Tracking shards。

没有清：

- `<SaveKey>_aura_manifest`；
- `<SaveKey>_aura_a_p1..p32`；
- `<SaveKey>_aura_b_p1..p32`。

当前 Reset 会清 manifest，并清 `a/b/c × 32` 的固定 Aura shard 空间。`c` 当前并非 Aura v1 活跃 Bank，但作为 bounded defensive cleanup 保留，避免未来/历史布局残留。

Factory Reset 成功后还会同步关闭：

```lua
plates.Storage.dirty
plates.Storage.trackingDirty
plates.Storage.auraDirty
```

防止旧 generation 在 Reload 前重新写回刚刚清掉的数据。

### 4. Runtime FrameBudget Contract

Plates **继续保留一个 Native OnUpdate Host**。本阶段没有把它强行塞进 Suite Scheduler，因为：

- 位置、目标 HUD、施法等需要高频响应；
- 现有单 Host 生命周期已经稳定；
- Foundation 的目标是统一 Policy Authority，而不是把所有模块机械改成同一种执行器。

新的关系为：

```text
Plates Native Runtime Host
        ↓
Lane due?
        ↓
Suite FrameBudget.Request()
        ↓
grant -> 执行
reject -> 保留 accumulator，下一帧继续请求
```

#### Priority

| Lane | Priority | Cost | 说明 |
|---|---:|---:|---|
| position | P1 | 1 | 可读性/锚点关键 |
| health | P1 | 1 | 战斗 HUD 关键 |
| casting | P1 | 1 | 战斗响应关键 |
| distance | P2 | 1 | 战斗派生 |
| effects target/player | P2 | 2 | Aura 显示，允许削峰但不能丢 |
| alerts | P2 | 2 | 战斗警报派生 |
| metadata / target extras | P3 | 1 | 可延期 |
| equipment / cooldowns | P3 | 2 | 可延期派生 |
| magic circle / watchtarget | P3 | 1 | 可延期辅助 |
| capture | P4 | 2 | 用户开启的观察工作 |
| buffcap | P4 | 1 | 低频提示 |
| lines | P4 | 2 | 视觉辅助 |
| circle | P4 | 3 | 投影型视觉辅助 |
| discovery | P5 | 2 | 后台发现 |
| manager | P5 | 2 | Manager 投影维护 |
| watchdog | P5 | 1 | 健康检查 |

#### 不丢工作

被 FrameBudget 拒绝时：

```text
不清 accumulator
不清 pending semantic state
不假装 lane 已执行
```

因此下一帧仍然 due，并且 FrameBudget 的连续延期/lateRatio 会参与 starvation protection。

### 5. Watchdog Warm Recovery

#### 历史恢复

```text
heartbeat stalled
    -> rebind OnUpdate
    -> ForceAll()
    -> watchdog callback 内直接 R:OnUpdate(...)
```

这可能在一次长帧后制造第二次集中爆发。

#### 当前恢复

```text
Watchdog 每 ~1s 到期
    ↓
P5 FrameBudget admission
    ↓
heartbeat stalled
    ↓
只 rebind Runtime OnUpdate
    ↓
RequestWarmRecovery()
    ↓
position / health / metadata / distance / cast / effects 标记 due
    ↓
后续正常渲染帧按 FrameBudget 恢复
```

**Watchdog 永远不直接调用 `R:OnUpdate()`，也不在恢复路径调用 `ForceAll()`。**

### 6. Diagnostics

Plates 新增导出：

```lua
ReplicatedPlatesModule:GetRuntimeDiagnostics()
```

Suite `DiagnosticsManager` 只读取该只读 facade，不直接进入 Plates mutable Domain。

当前输出：

- Runtime running / heartbeat / successful updates；
- FrameBudget request / grant / defer / starvation；
- Top deferred lanes；
- Watchdog recoveries / attempts / successes；
- Watchdog budget deferrals；
- recovery pending；
- visibility repairs。

Watchdog rebind/recovery 还使用结构化 Code：

```text
WATCHDOG_REBIND
WATCHDOG_REBIND_FAILED
WATCHDOG_RECOVERY_OK
```

并使用限频日志避免错误状态自己制造日志压力。

### 7. Phase 11A/11B 边界与后续状态

Phase 11A/11B 当时明确没有：

- 拆 `rp_manager.lua`；
- 建 Aura Observation Domain；
- 把 CORE_PRESET / Cooldown IDs 全迁入 GameData；
- 重写 Plates 双 Bank / Shard Persistence 协议。

其中 UI 高频写入已在后续 **Phase 11C** 完成第一批迁移：Lines/Circle Active Range 与 Effect Slot Diff，详见 `REPLICATED_PLATES_UI_DIFF_v1_20260826.md`。其余项目继续进入 Phase 12/13/14。

### 8. 下一步

Phase 11C 已完成，下一步进入 **Phase 12：Aura Observation Domain**。

目标是把 HUD、Alerts、Discovery、Capture、Loadout 对同一 Unit Aura 的重复 Native 扫描收口到一个 Snapshot / Generation Authority。



<a id="sec-3"></a>
## 3. Replicated Plates UI Diff Migration v1

> 来源（已合并至本权威文档，原文件已收口）：`replicatedsuite\Docs\Architecture\Historical\REPLICATED_PLATES_UI_DIFF_v1_20260826.md`

## Replicated Plates UI Diff Migration v1

日期：2026-08-26  
状态：Phase 11C 已落地  
对应 BuildTag：`foundation-v2-plates-ui-diff-v1`

### 1. 目标

本阶段只迁移 Plates 的高频 HUD Native 写入路径，不改 Buff/技能判定、位置算法、颜色规则或用户配置语义。

目标：

1. Lines 不再每轮先隐藏 4×64 全池；
2. Circle 不再每轮先隐藏全部 Dot；
3. Effect Slot 不再在每次 Aura Refresh 重复写 Icon 可见性、Extent、Border Color、Duration Color、Pick 状态；
4. 保留 1s Native Visibility Reconcile 作为 RU 客户端 UI 漂移修复；
5. 所有迁移路径进入 Suite RSUI Diff Metrics，并额外输出 Plates 专项 active/peak/stale-hide 指标。

### 2. Lines Active Range Contract

历史行为：

```text
每次 UpdateLinesView
    -> 4 个 Pool × 64 Dot 全部 Show(false)
    -> 再为本帧有效 Dot 写 Font/Color/Anchor/Show(true)
```

最坏仅 Hide 就可能达到：

```text
256 Dot × 10Hz = 2560 次 Native Show(false)/秒
```

当前行为：

```text
Pool 保存 activeCount
    ↓
本帧 count == oldCount
    -> 只 Diff 活跃 Dot 的 Font/Color/Anchor/Visible

本帧 count < oldCount
    -> 只隐藏 [count+1 .. oldCount]

本帧没有该 Line
    -> 只隐藏该 Pool 上一轮 activeCount

从未激活的 Pool 尾部
    -> 完全不触碰
```

同一组屏幕点连续两帧不变时，Mock Native 验证为 **0 次 Native UI 写入**。

### 3. Circle Active Range Contract

Circle 使用同样的 active tail 模式：

```text
旧 active = 12
新 active = 8

只 Hide 9..12
1..8 仅在 Font/Color/Anchor/Visible 实际变化时写入
13..poolMax 永远不触碰
```

Dot Pool 仍然只增不减，保持零 Destroy/零重复创建的原有设计。

### 4. Effect Slot Diff Contract

Effect Slot 正常刷新路径现在遵守：

```text
Texture path 未变
    -> 不 ClearAllTextures / AddTexture

Icon size 未变
    -> 不 SetExtent

Border color 未变
    -> 不 SetColor

Border visibility 未变
    -> 不 SetVisible

Duration tone 未变
    -> 不 SetColor

Tooltip pick state 未变
    -> 不 EnablePick / Clickable

Frame visibility 未变
    -> 不 Show
```

仅剩余时间变化时，正常情况只需要更新 Duration Text。

专项 Mock 验证：

```text
完全相同 Effect Snapshot：0 次 Native 写入
仅 5.0s -> 4.0s：1 次 SetText
```

### 5. 为什么仍保留 Reconcile

RSUI Diff Cache 是正常热路径 Authority，但 ArcheRage RU 客户端可能在 Native UI 重建后出现：

```text
Lua 认为 visible=true
Native Widget 实际 IsVisible=false
```

因此 `ReconcileScope()` 仍然保留低频 Native 可见性核对。

规则：

- 正常 Effects Tick 不再调用 `IsVisible()`；
- 1s Sentinel 才允许执行 Native/Lua 漂移核对；
- Reconcile 只修复发现的真实漂移，不重新扫描 Aura Domain。

这是性能与客户端容错之间的正式边界。

### 6. Diagnostics

Plates UI 暴露只读：

```lua
P.UI:GetPerformanceSnapshot()
```

包含：

#### Effects

- updates
- visible
- peakVisible
- hidden
- textureChanges

#### Lines

- frames
- active
- peakActive
- staleHides

#### Circle

- frames
- active
- peakActive
- staleHides

同时从 Suite UI Framework 读取：

```text
plates:effects
plates:lines
plates:circle
```

三个 Owner 的：

- attempts
- writes
- skips
- nativeCalls

这些数据同时进入：

- Plates 手动专家诊断；
- Suite Diagnostics Summary；
- Suite “打印全部日志”。

### 7. 验证基线

Native UI Mock：

```text
Lines 相同帧：0 native writes
Lines 10 -> 6：仅 4 Hide

Circle 相同帧：0 native writes
Circle 12 -> 8：仅 4 Hide

Effect 相同 Snapshot：0 native writes
Effect 仅剩余时间变化：仅 1 SetText
```

Phase 11A/11B 回归：

```text
20 Debuff Full Scan：PASS
Factory Reset Aura 421 keys：PASS
FrameBudget：PASS
Watchdog Warm Recovery：PASS
Suite Plates Diagnostics：PASS
```

### 8. 明确未做

本阶段没有：

- 改 Aura Observation Authority；
- 改 Lines/Circle 世界坐标/投影算法；
- 改 Effect 分类和显示优先级；
- 把所有 Plates UI 一次性迁入 RSUI；
- 拆 `rp_manager.lua`；
- 改双 Bank/Sharded Storage 协议。

### 9. 下一步

下一阶段进入 **Phase 12：Aura Observation Domain**。

优先解决：

```text
普通 Buff/Debuff HUD
Alerts
Discovery
Capture
Loadout/装备效果判断
```

对同一 Unit Aura 的重复 Native 扫描问题。

目标结构：

```text
Native Aura API
      ↓
Aura Observation Domain
      ↓
Snapshot / Generation
      ↓
HUD / Alerts / Discovery / Capture / Loadout
```

只有准确性要求明确的消费者允许请求 targeted refresh；普通消费者禁止自行重复全扫。
## Phase 12B 首个 Consumer：团队战备检查（M1.16.0.14）

`combat_raid_readiness` 的目标不是复制 Legacy Raidchecker，而是验证共享 TeamRoster + Aura 事实层能被一个独立 Feature 正确消费。

```text
Page Visible / Feature Enabled
        ↓ lightweight lease
TeamRosterV3
        ↓ user clicks Run
RaidReadiness Authority (sliced one-shot)
  ├─ X2Team:GetRole       [read-only]
  ├─ X2Unit:UnitGearScore [read-only]
  ├─ X2Unit:UnitDistance  [read-only]
  └─ AuraObservationV3    [only when required IDs configured]
        ↓
Session-only readiness projection
        ↓
V3 Page
```

- Feature 默认关闭；打开页面不等于扫描 Buff。
- Aura lease 只能存在于一次显式 scan 的生命周期中，完成/取消/离页必须释放。
- 规则结果使用 `通过 / 未通过 / 待确认 / 信息` 四态。Native 能力缺失、扫描超过 limit 或 tooltip/data 不可靠时只能“待确认”。
- Store 只保存用户规则，不保存团队扫描事实；默认 required Aura ID 为空，直到静态数据/实机证据核验后才允许提供预设。
- Presentation 不直接访问 X2Team/X2Unit/Aura 私有状态；Authority 组合共享事实后提供有界 rows/summary。
- 后续 Healer/Plates 迁移应复用 Aura `GetStatusMap()`，但治疗推荐/显示策略仍由各 Feature Domain 自己拥有。

## Phase 12B Healer 迁移桥（M1.16.0.15）

本阶段只完成 Healer 的 Aura **事实读取边界**，不把尚未完成的 Legacy Healer 重新挂回 Active V3。

```text
Healer Runtime Enable
        ↓ transactional lease
HealerAuraBridge
        ↓
AuraObservationV3 Snapshot + StatusMap
        ↓ only when coverage is complete/reliable
Healer StatusCache
        ↓
Healer Recommendation Domain (unchanged business authority)

coverage degraded
        └─→ legacy direct read fallback (accuracy safety only)
```

- Bridge 无 Tick/周期任务；默认 `held=false`。
- **M1.16.0.15 当时** `combat_healer` 仍是 `legacy_detached`、FeatureRuntime 未实现，因此该桥接阶段不能描述成“治疗辅助已迁移完成”；当前状态见下方 M1.16.0.16 Phase 12C。
- 状态 absence 会影响规则匹配和救援评分，所以 Healer 比显示型 Consumer 更严格：共享快照必须 `available + complete + reliable` 才可作为最终评分事实；否则允许直接 Native fallback。
- Enable 先 Acquire Aura，再安装 Healer 事件/Update；后续安装失败必须 Release。Disable 先 Release Aura，失败则不继续伪装成功关闭。
- 后续完整 V3 Healer 应提取 Domain/Projection，复用 TeamRosterV3 + HealerAuraBridge；禁止重新加载 Professional Healer UI/Runtime 整包。

## Phase 12C Healer V3 Domain Runtime（M1.16.0.16）

M1.16.0.16 把旧 Professional Healer 中已验证的 Roster / Health / Recommendation **提取**成 Active V3 Domain，而不是把旧模块恢复到 TOC。

```text
combat_healer FeatureRuntime / Demand
    ├─ v3.healer Store                  [permanent policy only]
    ├─ HealerRosterV3
    │    └─ TeamRosterV3 + optional X2Team:GetRole
    ├─ HealerAuraBridge v2
    │    └─ AuraObservationV3 first / accurate native fallback
    ├─ HealerHealthRuntime
    │    └─ Suite Scheduler one task, 20 Health / 8 Status per slice
    └─ HealerRecommendationV3
         └─ pure treatment business authority + bounded projection
```

核心 Contract：

- Feature disabled/demand=0 时 TeamRoster/Aura/Event/Scheduler 全部冷态；隐藏未来 UI 不得自行维持高消耗 Domain。
- 每个 roster generation 的首次 Recommendation 只能在完整 Status generation 后发布；Health/Status staging 不污染上一代 committed projection。
- 低血量 targeted status refresh 每片仍最多 8 人；到预算后保留当前 Health Snapshot 跨帧继续，禁止重复 Native Health reads。
- Aura unknown 不等于 absent：shared coverage 不完整时走准确回退；回退失败时该成员进入 unavailable，不给 unprotected 假加分。
- `v3.healer` Store 不保存 Feature enabled；FeatureRuntime 是 enabled Authority。Legacy 策略只读导入，不清除旧存档。
- Recommendation 保持 Feature Authority；Shared Service 只提供 roster/aura 事实。Presentation 只能消费 `GetProjection()`/Commands。
- M1.16.0.16 registry 状态为 `migration_active_domain_m16_16`：当时 Domain 已运行但 Presentation 尚未进入 Active V3。当前状态见下方 Phase 12D。

## Phase 12D Healer V3 Presentation（M1.16.0.17）

M1.16.0.17 只把 **Presentation 第一层**接到现有 Healer Feature，不改变 Domain/Service Authority。

```text
HealerFeature Projection / Commands
    ├─ GetProjection(50)
    ├─ GetMemberDetail(key)
    ├─ GetHealth / GetSettings
    └─ ApplySettingFromBinding / RequestRosterRefresh
          ↓
V3 Page (combat.healer)
          +
WidgetHost/FloatingSurface (combat.healer)
```

核心 Contract：

- Page/Widget 禁止调用 X2Unit/X2Team/Aura、Recommendation 私有 Cache、Feature Demand/State 私有对象；窗口几何通过 `GetWidgetWindowState()` 窄接口交给 FloatingSurface adapter。
- M1.16.0.18.8 已将 Active V3 Page/Widget 的 `Feature.State` 读取收口到 Feature read-model getter，并将 Activity/Task 显隐写入收口到 Commands；后续新 Presentation 代码仍必须遵守本条边界。
- M1.16.0.18.9 已将 Activity/Task Page/Widget 的 `Feature.Authority` 直连收口到 Feature Projection/Commands；后续业务域应保持同样的 Authority 隔离，并在 getter 内明确刷新/扫描语义。
- M1.16.0.18.10 已将 Gear、Instance Browser、Raid Readiness 的 Active Page/Widget Authority 直连收口；Gear mutation 与 Raid Readiness temporary scan cancellation 均不再由 Presentation 直接触碰内部 Authority。
- `GetMemberDetail()` 只复制已提交 Health/Status 事实，选择成员不会触发 targeted Native scan。
- 页面实时路径最多投影前 50 名，悬浮窗最多显示 12 名；Domain 仍维护完整候选/统计，显示上限不改变业务累计。
- 推荐发布只刷新实时表格/状态卡；NumericSetting/Toggle 仅在页面激活或 `v3.healer.settings` 变化时 Render，避免 100 人场景下无意义 Native UI 写入。
- Widget 是独立 Presentation Consumer；显隐只能改变自己的 Demand token，不创建第二套 Healer Scheduler/Aura/Roster。Feature Disable 先清 Demand 时，Widget Release 必须按幂等收敛处理“token 已不存在”。
- `v3.healer` schema 2 只增加 `widgetWindow`，enabled 仍属于 FeatureRuntime；Persistent Binding 的 setter 不自行 MarkDirty，保证一次用户输入只进入一次持久化事务。
- registry=`migration_active_presentation_m16_17`；该历史阶段只完成 Page/Floating，Head Marker / Raid Overlay 在 Phase 12E 继续迁移。

当时下一阶段由 Phase 12E 执行 Head Marker / Raid Overlay 独立迁移；高级规则/颜色编辑继续复用单一 Store/Settings Authority。该迁移已完成代码收口，当前由 Phase 12F 的 `combat.buff_display` 开始验证 Plates/BUFF 共享 StatusMap 消费。



## Phase 12E Healer Visual Presentation Consumers（M1.16.0.18）

M1.16.0.18 把旧 Healer 的 Head Marker / Raid Overlay **视觉职责**迁入 V3，但不复制它们历史上可触达的事实读取能力。

```text
Healer Feature committed Projection
    ├─ HeadMarker Consumer ──→ ProjectUnitToScreen() ──→ HealerScreenProjection ──→ X2Unit screen position only
    └─ RaidOverlay Consumer ─→ committed whole-roster display projection + candidate rank
```

边界：

- Head 与 Raid 各持有独立 Presentation Demand token；关闭任一显示层只释放自己的 consumer/task，不改变另一显示层或 Domain Runtime。
- `HealerScreenProjection` 是 Feature-side Native bridge，只提供 unitToken→screen x/y/z，绝不拥有名单、血量、Aura 或治疗业务状态；Presentation 文件禁止直接引用 X2Unit/X2Team。
- Head Marker pool 必须在 visual task 之外预创建。50ms P4 task 只做已缓存候选的坐标投影、visible/anchor/text/color Diff；设置深拷贝和文字格式化不进入该 hot path。
- Raid Overlay 预创建 4×25 槽位；静态 effectMode=1 纯事件驱动且必须没有 Scheduler，动态模式只允许一个 100ms P4 alpha task。它不得为了 proximity/底色重新建立私有 Health/Status scan；Feature 从 Recommendation committed Health/Status 生成 whole-roster display projection，恢复非候选范围/低血/Buff 色，Presentation 只消费 detached rows。
- Calibration 只在用户显式开启时允许拖动，拖动结束才提交 section rect；UILayer/Raise 不允许每 tick 执行。
- `v3.healer` schema 3 增加 `presentation.head/raid`。schema2 已完成 legacy import 的用户通过一次只读 visual recovery 恢复旧视觉参数，之后 `visualImported` 阻止重复覆盖。
- Stop 是事务：先释放 Presentation Demand；失败且 Feature 仍启用时保持 task/listener/visible 状态，不能制造半关闭。Feature 已先清空 Demand 的 shutdown 路径按幂等收敛处理 token missing。

当前 metadata=`migrated_m16_18`。代码层高级编辑器已完成；仍待 Fresh Reload、保存回读与 50/100 人视觉实机验收。

## Phase 12F Buff/Plates StatusMap Consumer（M1.16.0.18.4）

FloatingSurface 状态属于 Feature-owned Presentation Store，但必须以 detached snapshot 通过 Feature.Commands:SetWidgetWindowState() 写回；Widget 不得把 State.widgetWindow 的 live 子表交给公共适配器。BuffDisplay Store 当前为 schema 2，使用 FloatingSurface 完整状态 Normalize，保留 locked/minimized/opacity/fontScale 等公共窗口字段；schema 1 矩形数据可迁移。

`combat.buff_display` 是 Plates/BUFF 的第一条 Active V3 消费路径。它只接收 `AuraObservationV3:GetStatusMap()` 的事实，不重新加载 `modules/professional/plates`，也不把显示策略提升到共享 Aura Service。

```text
AuraObservationV3 Snapshot / StatusMap
        ↓
BuffDisplay Feature Domain
  ├─ player / target scope policy
  ├─ Buff / Debuff / Hidden filters
  └─ bounded detached rows (64 → Page/Widget limit)
        ↓
V3 Page + Floating Widget
```

- Feature Demand 为唯一 Aura lease；页面/悬浮窗各自持有 consumer，隐藏/关闭后没有后台 Aura task。
- projection 只保留 `id/name/icon/stack/time/sourceMask` 等稳定事实；`complete/reliable` 不足时显示“待确认”，不把未知伪装成空状态。
- Store 只保存过滤器、行数和刷新周期；当前不猜测 Buff 语义、不预置未经 RU 验证的 ID。
- 本阶段没有迁移 Lines/Circle、Effect Slot Diff、Aura Library/Tracking 双 Bank、Manager 拆分或 Legacy standalone UI；这些仍沿用下方审计任务图。

### M1.16.0.18.14 Interaction polish

- DeathReview 的单条删除通过 `Feature.Commands:DeleteRecord(serial)` 进入 Store index transaction；Presentation 不直接改 history table。
- Activity/Task HUD 详情使用共享 session `QuestDetailFloatingV3`，只读 `QuestProgressV3` Projection；主 Page 的 Modal 交互保持独立，HUD 点击不再强制唤醒 Application Shell。
- 有限范围数值设置优先使用 RSUI CompactNumericSetting（Label + Slider + exact input）；没有可证明有限上限的自由几何字段继续 exact-input-only。

### M1.16.0.18.15 Floating chrome / Activity responsive / Analytics value

- Floating HUD 外观调整属于公共 WindowShell/FloatingSurface 能力；Feature 只继续拥有自己的 widgetWindow state/persistence，不创建第二份透明度/字号状态。
- Activity Widget 仍只消费 Feature rows/summary Projection；窗口宽高只影响 Presentation viewport/column solver，不反向改变 Activity Domain 数据或 persisted `widgetRows` 兼容字段。
- Combat Analytics 的 Metric value 切换只经 `Feature.Commands:SetSelectedValue`；Store 白名单是 persisted preference 的合法性边界，SegmentedSelector 仅拥有点击表现。

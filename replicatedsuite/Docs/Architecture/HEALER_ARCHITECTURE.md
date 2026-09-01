# Replicated Healer 架构（统一权威）

> **Authority Level**: ARCHITECTURE
> **范围**: Healer 专业模块——Domain / Runtime / Glue-Persistence / Roster API Gateway / Settings / V3 Presentation。
> 本文由 5 个文档（Settings + 4 个迁移阶段）收敛而成，保留全部原始知识。


## 目录

1. [Replicated Healer Settings Architecture v1](#sec-1)
2. [Replicated Healer Domain / Runtime Migration v1](#sec-2)
3. [Replicated Healer Domain Split / Presenter Migration v1](#sec-3)
4. [Replicated Healer Glue / Persistence Migration v1](#sec-4)
5. [Replicated Healer Roster / Native API Gateway v1](#sec-5)
6. [Aura Phase 12B 共享事实迁移桥](#sec-6)
7. [V3 Domain Runtime](#sec-7)
8. [V3 Presentation](#sec-8)
9. [V3 Head Marker / Raid Overlay](#sec-9)

<a id="sec-1"></a>
## 1. Replicated Healer Settings Architecture v1

> 来源（已合并至本权威文档，原文件已收口）：`replicatedsuite\Docs\Architecture\Healer\REPLICATED_HEALER_SETTINGS_ARCHITECTURE_v1_20260826.md`

## Replicated Healer Settings Architecture v1

> 日期：2026-08-26  
> 状态：CURRENT  
> 对应 BuildTag：`foundation-v2-healer-settings-v1`

### 1. 目标

本阶段把 Healer 最后一个高耦合区域——设置默认值、合法范围、历史迁移、启动读取、Suite 设置 Facade、持久化——从历史 `replicatedhealer_core1.lua / core2.lua` 中拆开。

核心原则：

```text
SettingsModel        = 设置语义 / 默认值 / 合法范围 Authority
SettingsMigrations   = 历史版本一次性迁移 Authority
SettingsBootstrap    = 启动期只读 Load Authority
SettingsStore        = Durable Persistence Authority
SettingsPresenter    = Suite UI Proxy / Command Presenter
Core1/Core2          = Compatibility + boot/runtime glue
```

禁止重新把版本迁移写回 Core1，也禁止 Suite UI 自己复制一份范围表。

---

### 2. 文件职责

#### `domain/rh_settings_model.lua`

负责：

- `BuildDefaults()`；
- Healing Rule factory；
- Rule / Tracked Buff / Weight / Color / Anchor Normalize；
- Suite-facing scalar setting schema；
- Rule setting schema；
- 交叉阈值约束；
- 颜色通道、等级阈值、Head Size 统一校验。

它是纯 Domain 层：

- 不调用 `SaveData`；
- 不创建 Native UI；
- 不执行历史版本迁移。

#### `persistence/rh_settings_migrations.lua`

只负责历史一次性迁移，例如：

- 209 Overlay 默认尺寸；
- 210 候选阈值与持续回血剩余时间；
- 211 治疗距离；
- 212 紧急阈值；
- 213 保护颜色；
- 215/216/218 Launcher 历史坐标；
- 217 Tracked Buff / Range Color；
- 218 forced-off 修复；
- 221 Raid Effect 默认值。

本阶段将 `SettingsVersion` 提升到 222，用于一次性持久化统一 Schema Normalize；以后新增 `SettingsVersion=223+` 的迁移必须追加在本文件，不允许塞回 Core1。

#### `persistence/rh_settings_bootstrap.lua`

启动期只读流程：

```text
Primary
  ↓ 无效
Backup
  ↓ 无效
Legacy v1（仅保留允许迁移的布局数据）
  ↓
Defaults
  ↓
Historical Migration
  ↓
SettingsModel.NormalizeState
  ↓
Validated Runtime State
```

Bootstrap 不写盘。它返回：

- source；
- loadedVersion；
- recoveredFromBackup；
- needsMigrationSave；
- future-schema Write Fence。

#### `persistence/rh_settings_store.lua`

继续负责 Permanent Store：

- Backup-first；
- Primary second；
- Dirty + 750ms Debounce；
- Force Flush；
- Write Fence；
- Suite Disable/Reload 收尾保存。

重要顺序：

```text
Bootstrap 完成
  ↓
Core1 建立 runtime state
  ↓
SettingsStore 注册
  ↓
若需要迁移：先保存 durable migration snapshot
  ↓
Suite mode 才把 state.enabled=false 作为 session-only override
```

这样不会把 Suite 生命周期的临时 `enabled=false` 错误写进迁移存档。

#### `presentation/rh_settings_presenter.lua`

负责 Suite 页面看到的窄接口：

- `Get/SetSuiteSetting`；
- Color / Head Size；
- Weight / Level / Role；
- Tracked Buff；
- Rule / Condition Group；
- Raid Calibration；
- `OpenSettings/Page`。

Presenter 不拥有 State。它必须：

```text
UI Command
  ↓
SettingsModel Coerce/Validate
  ↓
Healer Domain State mutation
  ↓
Visual Projection
  ↓
SettingsStore MarkDirty
```

---

### 3. 修复的历史 Schema 漂移

过去 Suite Facade 和 Core Load Normalize 各有一份范围表，已经发生漂移。例如：

```text
旧 Suite Facade       真正 Domain
raidEffectMode 1..4   1..3
headEffectMode 1..4   1..3
headShapeMode 1..8    1..4
rule.matchMode 1..4   1..2
rule.effectType 1..5  1..4
rule.scoreMode 1..4   1..2
rule.distanceMode 1..3 1..2
```

这会造成“当前会话接受非法值，下一次 Load 又被 Normalize 修回”的状态抖动。

v1 开始所有 Suite write 都使用 SettingsModel schema；Presenter 不再维护第二份数字范围。

---

### 4. Authority 规则

#### 允许

- Presenter 读取 `state` 做 Projection；
- Presenter 通过 SettingsModel 校验后修改 `state`；
- SettingsStore 读取完整 `state` 形成持久化快照；
- Migrations 根据 `loadedVersion` 修改 Boot staging state。

#### 禁止

- `rs_professional_pages.lua` 直接修改 Healer `state`；
- Core2 新增另一份 `SUITE_NUMBER_LIMITS`；
- SettingsStore 自己重新 Normalize 业务字段；
- Migrations 在正常 UI 设置变更时执行；
- Bootstrap 在 Load 中途写 SaveData。

---

### 5. Diagnostics

Healer Runtime diagnostics 现在同时暴露：

```text
SettingsModel
  normalizeState / normalizeRule / coerce / reject

SettingsMigrations
  runs / applied / legacyV1

SettingsBootstrap
  loads / primary / backup / legacy / failures / futureSchema

SettingsStore
  dirty / writeFence / flush / flushFailures / backupWrites / primaryWrites

SettingsPresenter
  reads / writes / rejects / projections
```

诊断报告应能回答：

1. 当前设置是不是从 Backup 恢复；
2. 是否遇到 future schema；
3. 是否执行了迁移；
4. 当前 Store 是否 Dirty / Write Fenced；
5. Suite UI 是否尝试写入非法枚举值。

---

### 6. 性能原则

Settings 不属于高频 Runtime lane，但仍遵守：

- 普通 +/- / Toggle 只 `MarkDirty`；
- 750ms Debounce 合并写盘；
- UI Refresh 不触发 Save；
- 不在 50ms Visual lane Serialize；
- Diagnostics 只做轻量 Counter；
- Force Flush 仅用于显式保存、Disable、Reload/Shutdown。

---

### 7. 兼容策略

保留：

- 原 SaveKey；
- 原 Backup Key；
- 根级 Healer settings payload；
- `settingsVersion`；
- Legacy v1 布局救援；
- Core2 使用的 `NewDefaultHealingRule / NormalizeRule / NormalizeWeights` 等 Compatibility Proxy。

因此本阶段不要求用户清空配置，也不改变已存在 SaveData key。

---

### 8. 验证要求

离线必须覆盖：

1. 全 Lua parse；
2. 无存档 → Defaults；
3. Primary current schema；
4. Backup recovery；
5. future schema → Write Fence；
6. v208/v209/v210/v217/v218/v221 关键迁移；
7. migration snapshot 保存时必须保留真实 persisted `enabled`；
8. migration 保存完成后 Suite session `enabled=false`；
9. Presenter 写入非法 enum 时按 Model clamp/reject；
10. Phase 6–9 Healer Roster/Status/Health 回归。

游戏内必须继续验证：

- 老用户配置直接覆盖升级；
- Backup 恢复提示；
- 快速连续设置后 ReloadAddon 最终值不丢；
- Module Disable 后不把 session-only 状态污染持久化；
- Suite Healer 页面所有设置项与重登值一致。

---

### 9. 下一阶段

Healer 大块架构债已经基本收口。下一步优先：

1. 对 Healer standalone 历史 Settings Native Window 做“保留/删除”审计；Suite 模式下不应成为第二 UI Authority；
2. 开始 Plates：API/Storage/Manager/Runtime/UI 按同样 Authority + FrameBudget + Diff 模式审计；
3. DPS 暂不大改核心统计，只迁移明确可延期的维护/Projection 路径。



<a id="sec-2"></a>
## 2. Replicated Healer Domain / Runtime Migration v1

> 来源（已合并至本权威文档，原文件已收口）：`replicatedsuite\Docs\Architecture\Historical\REPLICATED_HEALER_DOMAIN_RUNTIME_v1_20260826.md`

## Replicated Healer Domain / Runtime Migration v1

> 日期：2026-08-26  
> 状态：Foundation v2 第一批 Professional Domain 迁移已落地  
> 当前兼容 Build：`foundation-v2-healer-glue-persistence-v1`  
> Roster / Native API 已在 `REPLICATED_HEALER_ROSTER_API_GATEWAY_v1_20260826.md` 中进一步拆分；Status / Recommendation / Marker / Raid Presenter 又在 `REPLICATED_HEALER_DOMAIN_SPLIT_v1_20260826.md` 中完成第二轮职责迁移。

---

### 1. 本阶段目标

Healer 是 Foundation v2 第一个真正接入 Diagnostics、UI Diff 与 FrameBudget 的 Professional Domain。

本阶段的底线不是“降低刷新频率换性能”，而是：

1. **不修改治疗推荐评分、排序、颜色规则、距离规则与 Buff 判定业务语义**；
2. 保留原 `healthScanMs / buffScanMs` 的周期语义；
3. 将 50/100 人全量读取从单帧突发改为分帧 Slice；
4. 扫描中的中间结果不得污染当前 Recommendation；
5. 高频 Marker / Raid Overlay 默认走 Diff Rendering；
6. 关键治疗状态保持准确率优先，FrameBudget 只能延期可延期工作，不能丢事实。

---

### 2. Authority 边界

本阶段明确 Healer 内部三层 Authority：

```text
domain/rh_roster.lua
    │
    └─ Roster committed snapshot
            │
            ▼
domain/rh_status_cache.lua + domain/rh_recommendation.lua
    │
    ├─ Status committed snapshot
    ├─ Recommendation scoring / sorting
    └─ Atomic Health / Recommendation publication
            │
            ▼
runtime/rh_runtime.lua
    │
    ├─ Scan generation
    ├─ Slice cursor
    ├─ FrameBudget admission
    ├─ Dirty scheduling
    └─ Runtime diagnostics
            │
            ▼
presentation/*
    │
    ├─ UI Diff bridge
    ├─ Head Marker Presenter
    └─ Raid Overlay Presenter

replicatedhealer_core1/core2
    └─ remaining config / settings / legacy glue only
```

#### Domain Authority

Roster Authority 已迁移到 `domain/rh_roster.lua`；Native `X2Unit/X2Team` 入口已迁移到 `api/rh_api.lua`。详见 Roster/API Gateway 专项文档。

当前 Authority 已进一步迁移：

- `domain/rh_status_cache.lua`：Status Snapshot Authority；
- `domain/rh_recommendation.lua`：Recommendation Policy / Sort / Rank / Publish Authority；
- `healthSnapshot / recommendations / statusCache` 暂时仍以 sandbox global table 作为兼容 backing state，但新 Runtime 只通过 Domain facade 操作核心流程；
- `replicatedhealer_core1.lua` 不再实现 Status/Recommendation 算法。

Runtime 不复制这些业务规则。

#### Runtime Authority

`runtime/rh_runtime.lua` 只负责“什么时候、分多少、何时提交”：

- Health Generation；
- Status Generation；
- Slice 大小；
- FrameBudget 请求；
- Roster 变化失效；
- Visual Dirty；
- Runtime Metrics。

#### Presentation Authority

Native Presentation 已进一步迁移到 `presentation/rh_ui_bridge.lua`、`rh_marker_presenter.lua`、`rh_raid_presenter.lua`。`replicatedhealer_core2.lua` 继续保留设置编辑器与生命周期 Glue；Runtime 通过 Presenter facade 请求刷新，不直接操作 Native Widget。

---

### 3. Generation + Atomic Commit

旧实现会在一个 Refresh 中遍历全团并直接更新缓存。

v1 改为：

```text
Start Generation
      │
      ▼
Staging Generation
      │
      ├─ Frame N：成员 Health + 必要 Status + Candidate
      ├─ Frame N+1：继续下一批成员
      └─ ...
      │
      ▼
Generation Complete
      │
      ├─ merge fresher targeted Status
      ├─ sort / rank staged Candidate
      ▼
Atomic Commit
      │
      ▼
HealthSnapshot + Recommendation + CandidateMemory 一次发布
```

扫描过程中的 `staging` 数据不是当前 Domain State。

因此不会出现：

- 100 人团队只读完前 20 人时排行榜已经变化；
- Buff 只扫描一半时 Recommendation 混用新旧状态；
- 某一帧只更新一部分玩家导致治疗目标闪动。

---

### 4. 当前 Slice 策略

#### Status / Buff

默认：

```text
8 members / rendered frame
Priority：P2
Cost Units：2
```

完整周期仍由 `buffScanMs` 控制。

FrameBudget 在 Busy/Heavy/Critical 时可以延期该 Slice，但：

- 当前 Generation 不丢失；
- Cursor 不倒退；
- 已读取 staging 不发布；
- 后续继续完成；
- FrameBudget 自身具有 starvation protection。

#### Health / Recommendation

默认上限：

```text
最多 20 members / rendered frame
其中最多 8 个成员允许执行昂贵 Status 强制刷新
Priority：P1
Cost Units：1
```

Health Recommendation 是正确性路径，所以当前 v1 使用 P1：

> Slice 可以削掉单帧峰值，但不会因为 FrameBudget 忙而拒绝治疗关键健康状态。

旧 `EvaluateMember()` 有一个非常重要的准确性规则：紧急低血量成员在 Status 缓存超过约 80ms 时会立即强制重扫 Buff。v1 **保留该规则**，但把它放进 Recommendation Generation：

1. 当前成员先读取 Health / MaxHealth / Distance；
2. 使用原规则判断该成员是否必须刷新 Status；
3. 本帧昂贵 Status 刷新名额未超过 8 时执行 `ReadUnitStatuses()`；
4. 使用该成员同一分片内得到的 Health + Status 计算 Candidate；
5. 本帧如果已经达到 8 个 Status 刷新，则当前成员留到下一帧，且保留已读 Health Snapshot，避免重复 Native 读取；
6. 所有 Candidate 只进入 staging，完整 Generation 结束后统一排序并一次发布。

因此即使出现“100 人同时低血量”的极端情况，也不会在最终 Commit 时重新形成一次 100 人同步 Buff 扫描。

Candidate hysteresis 的时间基准固定为该 Recommendation Generation 的开始时间，避免分片导致前后成员 `minHoldMs` 语义发生漂移。

---

### 5. 新 Roster 的首次提交顺序

> 当前实现已进一步升级为独立 `domain/rh_roster.lua` 的 16 Slot / 8 Role Generation；本节的首次提交语义继续有效，具体实现以 `REPLICATED_HEALER_ROSTER_API_GATEWAY_v1_20260826.md` 为准。

旧逻辑的核心语义是：

```text
Roster
  ↓
Buff/Status
  ↓
Health Recommendation
```

v1 保持这一点。

当团队成员变化后：

1. 原 staging cycle 作废；
2. 已提交 Recommendation / Health / Status 清理，避免旧成员数据泄漏；
3. 等待 Native 团队列表 900ms settle；
4. 重建 Roster；
5. 首个 Status Generation 完整提交；
6. 再开始首个 Health Generation；
7. Health 完整提交后生成 Recommendation。

后续稳定运行时，新的 Health Generation 可以读取上一轮已完整提交的 Status Snapshot，同时下一轮 Status 在 staging 中进行。

---

### 6. UI Diff 迁移

#### Head Marker

旧模式存在典型热路径：

```text
每 50ms：
  先隐藏大量 Marker / Part
  再重新 Show
  再 SetColor
  再 SetText
  再 Layout
```

v1 改为：

- 只隐藏本轮已经不再使用的 stale rank；
- `Show / SetText / SetColor / SetExtent / SetAnchor / FontSize` 走 UI Framework Diff；
- Marker 几何布局根据 Shape / Size / Extra 信息开关缓存；
- 镜头移动时只更新必须变化的外层屏幕 Anchor；
- UI Framework 的 Color / Anchor 状态使用标量缓存，避免热路径临时 table；
- 不在 Marker Tick 中创建 Native Widget。

#### Raid Overlay

Raid Overlay 的：

- Visibility；
- Slot Color；
- Rank Text；
- Font / style；

开始通过统一 Diff helper 写入。

Calibration 与旧 UI 仍保持兼容。

---

### 7. FrameBudget 接入

当前 Healer lane：

| Lane | Priority | Cost | 策略 |
|---|---:|---:|---|
| Health Slice | P1 | 1 | 正确性优先，不拒绝 |
| Status Slice | P2 | 2 | 可延期，不丢 Generation |
| Visual | P2 | 2 | 可延期 |
| Settings Refresh | P4 | 默认 | 可延期 |
| Roster Slice | P2 | 1 | invalidation 立即生效；settle 后的扫描 Slice 可延期 |

这一层不替代正确的数据结构；它只是阻止多个可延期 Lane 与其它模块在同一长帧同时爆发。

---

### 8. Diagnostics

Healer Runtime 通过 `ReplicatedHealerModule:GetRuntimeDiagnostics()` 暴露**窄只读诊断 Projection**。

Suite Diagnostics 不直接读取 Healer Sandbox 内部可写状态。

当前诊断包含：

- Runtime Version；
- Enabled；
- Roster Count；
- Health Generation；
- Status Generation；
- 当前 Health cursor / total / active；
- 当前 Status cursor / total / active；
- Health / Status Slice Size；
- Max Slice；
- Health Generation 内 targeted Status refresh 总数；
- 单帧 targeted Status refresh 最大值；
- Status / Visual / Settings defer；
- Cycle started/completed；
- Roster change / Runtime reset 等 bounded counters。

这样出现卡顿或“推荐没刷新”时，可以先判断：

```text
是 Roster 没稳定？
是 Status Generation 没提交？
是 Health Generation 正在分片？
还是 P2 Visual 被长帧延期？
```

而不是直接猜业务算法。

---

### 9. 性能硬规则

Healer 后续开发继续遵守：

1. 不在 `OnUpdate` 中创建 Widget；
2. 不在每帧构造大型临时表；
3. 不在每个 Buff 上做复杂 Tag 遍历；
4. Registry 查询必须使用预建索引；
5. Native API 大量读取必须 Slice 或 Event-first；
6. UI 数据不变时不得重复 Native 写；
7. FrameBudget 只能延后派生工作，不能丢治疗事实；
8. 大 Raid 目标继续按约 200 玩家设计，不以“正常团队只有 50 人”为前提。

---

### 10. 本阶段明确没有做

为了降低一次性回归风险，v1 没有：

- 修改治疗 Recommendation 算法；
- 修改 Buff / Debuff 业务规则；
- 修改颜色优先级；
- 修改距离判定；
- 修改保存 Schema；
- 将 Healer Core1/Core2 一次性拆成很多小文件；
- 假设存在未验证的事件型 Health/Buff Native API；
- 删除 Healer 原单一 Native `OnUpdate` Host（现在由它委托 Runtime）；
- 强制 DPS/Plates/Gear 同时重构。

---

### 11. 后续 Healer 技术债

Phase 7–9 已经完成：

1. Roster Model 与 Team API Safe Gateway 收口；
2. StatusCache / Recommendation Engine 拆为明确 Domain；
3. Marker / Raid Overlay / Recommendation List / Buff Observer 拆为 Presenter；
4. Healer Settings 接入 Permanent Persistence Store，并采用 Dirty + Debounce + explicit Flush；
5. Presenter 热路径统一接入 Suite UI Diff Bridge。

接下来优先：

1. Settings Model / Settings Presenter 与历史 Core 的 boot-time normalization 继续分离；
2. 对可以确认有 Native Event 的路径逐步 Event-first，轮询只做恢复/校验；
3. 增加游戏内 50/100/200 玩家压力诊断基线；
4. 根据真实 ArcheRage 日志调整 Slice Size，而不是凭感觉降低准确率；
5. 在 Healer 游戏内验证稳定后，再按风险进入 Plates Runtime。

在 Healer 游戏内验证稳定之前，不建议对 DPS 做大规模结构迁移。

---

### 12. 验证要求

源码层必须通过：

- 全 Lua 语法；
- 100 人 Status Atomic Commit；
- 100 人 Health Atomic Commit；
- Status Slice `<= 8`；
- Health Slice `<= 20`；
- Health 内 targeted Status refresh `<= 8 / frame`；
- 100 人紧急状态不得在最终 Commit 重新聚合成同步 Buff 扫描；
- 首次 Roster 必须先 Status Commit 再 Health Commit；
- P2 Status 被 Budget 延期时 staging 不泄漏；
- UI Diff 同值写必须 Skip；
- Persistence / Storage / Factory Reset 回归；
- Diagnostics 能读取 Healer Runtime Projection。

游戏内还必须验证：

- 单团 / 双团；
- 团队快速进出；
- 死亡 / 复活；
- 切地图 / 传送；
- Head Marker 开关与移动；
- Calibration；
- 1024×768 与 1920×1080；
- 长时间运行后 UI NativeCalls / MakeSprite 日志变化。



<a id="sec-3"></a>
## 3. Replicated Healer Domain Split / Presenter Migration v1

> 来源（已合并至本权威文档，原文件已收口）：`replicatedsuite\Docs\Architecture\Historical\REPLICATED_HEALER_DOMAIN_SPLIT_v1_20260826.md`

## Replicated Healer Domain Split / Presenter Migration v1

> 日期：2026-08-26  
> 状态：已落地  
> 首次落地 Build：`foundation-v2-healer-domain-split-v1`  
> 当前兼容 Build：`foundation-v2-healer-glue-persistence-v1`

---

### 1. 本阶段目的

Phase 6/7 已经解决 Healer 的高频全团同步扫描、Roster 与 Native API 边界，但历史 `replicatedhealer_core1.lua / core2.lua` 仍同时承担过多职责。

本阶段不是修改治疗推荐业务规则，而是把已经稳定的职责从历史 Core 中真正移出，形成可以继续维护的 Domain / Presenter 边界：

```text
api/rh_api.lua
    Native X2Unit / X2Team Proxy

 domain/rh_roster.lua
    Roster Authority

 domain/rh_status_cache.lua
    Status Snapshot Authority

 domain/rh_recommendation.lua
    Recommendation Policy Authority

 runtime/rh_runtime.lua
    Generation / Slice / FrameBudget Authority

 presentation/rh_ui_bridge.lua
    Suite UI Diff Native bridge

 presentation/rh_marker_presenter.lua
    Head Marker Presentation Authority

 presentation/rh_raid_presenter.lua
    Raid Overlay / Calibration Presentation Authority
```

`replicatedhealer_core1.lua` 与 `replicatedhealer_core2.lua` 暂时保留配置 boot normalization、设置编辑器与生命周期 Glue；Recommendation List、Buff Observer 与正常设置持久化已在下一阶段迁出，详见 `REPLICATED_HEALER_GLUE_PERSISTENCE_v1_20260826.md`。它们不再是 Status、Recommendation、Marker、Raid Overlay、Recommendation List、Buff Observer 的实现 Authority。

---

### 2. Status Cache Domain

文件：`modules/professional/healer/domain/rh_status_cache.lua`

职责：

- Buff / Debuff / Hidden Buff 读取与合并；
- Tooltip + Extra 数据归一；
- `statusCache` 已提交快照；
- Status Generation Atomic Commit；
- newer targeted status observation 优先于 older staged full scan；
- Status 读取/提交诊断。

Runtime 热路径通过：

```lua
ReplicatedHealerStatusCache:Read(member)
ReplicatedHealerStatusCache:Commit(nextCache)
```

访问。

历史 `ReadUnitStatuses / CommitStatusSnapshot / GetStatuses` 等名字暂时保留为 Compatibility Proxy，目的是让尚未迁移的 Buff Observer / Settings 页面继续工作；新代码不得继续依赖这些裸全局入口。

---

### 3. Recommendation Domain

文件：`modules/professional/healer/domain/rh_recommendation.lua`

职责：

- Status Rule Match；
- Healing Display State；
- Health / Distance / MissingHealth / Role Score；
- Candidate hysteresis；
- Emergency / unavailable 判定；
- Stable Candidate Sort；
- Rank；
- Atomic Recommendation publication；
- CandidateMemory / PreviousRank 更新。

Runtime 只负责 staging 与分片，不复制评分规则：

```text
Runtime Health Slice
      │
      ├─ Native health observation
      ├─ optional Status refresh
      ▼
Recommendation:Evaluate(...)
      │
      ▼
staging candidates
      │
      ▼
Recommendation:Publish(...)
```

因此 Authority 仍是单向的：

```text
Native API → Observation/Status → Recommendation → Presentation
```

---

### 4. Presentation 拆分

#### UI Bridge

`presentation/rh_ui_bridge.lua`

只封装：

- `SetVisible`
- `SetText`
- `SetColor`
- `SetExtent`
- `SetAnchor`
- `SetFontSize`
- `CreateMovableColorPanel`

优先走 Suite UI Framework Diff；没有 Suite UI 时保留 Native fallback。

它不允许包含治疗业务判定。

#### Marker Presenter

`presentation/rh_marker_presenter.lua`

拥有：

- Head Marker Widget collection；
- Marker geometry cache；
- Marker layout；
- World screen position projection；
- Diff-based Marker refresh；
- Marker visibility lifecycle。

#### Raid Presenter

`presentation/rh_raid_presenter.lua`

拥有：

- 4 个 Raid Overlay；
- 25-slot × 4 layout；
- Calibration frame；
- Raid rank projection；
- Overlay z-order lifecycle；
- Diff-based slot / rank refresh。

---

### 5. 修复的历史边界问题：Z-Order helper

旧 `core2` 中：

```lua
local function EnsureRaidOverlayZOrder(...)
```

是一个 **Lua chunk-local** 函数。

但 `runtime/rh_runtime.lua` 属于另一个 Lua chunk，却尝试：

```lua
if type(EnsureRaidOverlayZOrder) == "function" then ... end
```

因此 Runtime 实际无法访问这个 local helper；该路径只能静默跳过。

本阶段将它正式提升为 Raid Presenter 生命周期接口：

```lua
ReplicatedHealerRaidPresenter.EnsureZOrder
```

Runtime 不再跨文件假设 local symbol 可见。

---

### 6. Runtime 接口变化

`rh_runtime.lua` Version：`1.2`

Runtime 现在优先通过稳定对象接口调用：

```text
ReplicatedHealerStatusCache
ReplicatedHealerRecommendation
ReplicatedHealerMarkerPresenter
ReplicatedHealerRaidPresenter
```

只有在这些对象不存在时才使用历史全局兼容入口。

这是一条迁移规则：

> 新代码使用 Domain/Presenter object；历史 Core global 只作为兼容层，不再扩展。

Runtime Diagnostics 现在同时返回：

- Status Domain；
- Recommendation Domain；
- Marker Presenter；
- Raid Presenter；
- Roster；
- Native API Gateway。

---

### 7. 文件规模变化

本阶段基线约为：

```text
replicatedhealer_core1.lua  2197 lines
replicatedhealer_core2.lua  3327 lines
```

迁移后约为：

```text
replicatedhealer_core1.lua  1533 lines
replicatedhealer_core2.lua  2597 lines
```

减少的代码不是删除业务能力，而是迁移到明确职责的 Domain / Presenter 文件。

下一轮不得为了追求文件更短，把多个 Domain 再合并成一个 “healer_common.lua”。

---

### 8. 性能规则保持不变

本阶段不改变 Phase 6/7 已验证的限制：

- Status：最多 8 members / rendered frame；
- Health：最多 20 members / rendered frame；
- Targeted emergency Status：最多 8 / frame；
- Roster：最多 16 slots / frame；
- Role：最多 8 Native reads / frame；
- Role Scoring 关闭时：0 Role Native reads；
- Recommendation staging 不允许 partial publish；
- Marker/Raid 高频写继续走 Diff Rendering；
- 高频路径禁止创建不必要的临时表和日志字符串。

---

### 9. 后续拆分状态

后续 Phase 9 已完成本文件原计划中的主要 Glue 收口：

1. Recommendation List 已迁移到独立 Presenter；
2. Buff Observer / Tracked Buff Editor 已迁移到独立 Presenter；
3. Healer Settings 已接入 Foundation Persistence 的 Permanent Store；
4. 普通设置写入已改成 Dirty + Debounce，显式收尾保存使用强制 Flush；
5. Presenter → Suite UI Diff Bridge 已修正并统一热路径写入。

仍待继续：

1. Settings Model 与 Settings Presenter 从历史 Core 中继续分离；
2. boot-time legacy load / normalization 逐步迁入正式 Settings/Persistence Authority；
3. 移除最终不再需要的 Compatibility Global。

只有当 Compatibility Global 的所有调用者都已迁移后才能物理删除；删除文件或旧文档时必须在补丁说明中明确列出手动删除路径。

---

### 10. 验证要求

源码侧必须通过：

- 全 Lua `loadfile()` 语法检查；
- Status newer-targeted-wins Commit 测试；
- Recommendation Sort / Rank / Publish 测试；
- TOC 顺序检查；
- moved implementation 唯一性检查；
- Phase 6/7 100 人压力规则回归。

游戏内仍必须验证：

- 50 / 100 人团队；
- 快速进退团；
- 1团/2团切页；
- Marker 20Hz 动画；
- Calibration 拖动；
- Native raid row 点击后 Overlay z-order 恢复；
- ReloadAddon 后所有 Presenter 生命周期正确。



<a id="sec-4"></a>
## 4. Replicated Healer Glue / Persistence Migration v1

> 来源（已合并至本权威文档，原文件已收口）：`replicatedsuite\Docs\Architecture\Historical\REPLICATED_HEALER_GLUE_PERSISTENCE_v1_20260826.md`

## Replicated Healer Glue / Persistence Migration v1

> 日期：2026-08-26  
> 状态：已落地  
> Build：`foundation-v2-healer-glue-persistence-v1`

---

### 1. 本阶段目标

Phase 6–8 已经把 Healer 的 Roster、Status、Recommendation、Marker、Raid Overlay 从历史超级 Core 中拆出。本阶段继续处理剩余 Glue，重点不是改变治疗规则，而是把以下重复机制收口：

```text
Recommendation List Native HUD
Buff Observer operator tool
Healer Settings durable save
Presenter → Suite UI Diff bridge
```

本阶段之后的主要结构：

```text
config/rh_config.lua
        │
        ▼
replicatedhealer_core1.lua
  boot-time defaults / legacy normalization
        │
        ├──────────────► persistence/rh_settings_store.lua
        │                    Permanent Store Authority after boot
        │
        ├──────────────► domain/rh_status_cache.lua
        ├──────────────► domain/rh_recommendation.lua
        │
        └──────────────► presentation/
                         ├─ rh_ui_bridge.lua
                         ├─ rh_marker_presenter.lua
                         ├─ rh_raid_presenter.lua
                         ├─ rh_recommendation_list_presenter.lua
                         └─ rh_buff_observer.lua
```

`core1/core2` 仍存在，但不再拥有 Recommendation List 与 Buff Observer 的 Native 实现，也不再作为正常设置修改的即时 SaveData Authority。

---

### 2. Healer Settings Store

文件：

`modules/professional/healer/persistence/rh_settings_store.lua`

Lifetime：

```text
Permanent
```

Store Id：

```text
healer.settings
```

#### 2.1 为什么仍然保留主槽 + 备份槽

ArcheRage RU 的表保存历史实现使用：

```text
ClearData(key)
SaveData(key, table)
```

如果客户端在 Clear 与 Save 之间失败，单槽数据存在被清空的风险。因此 Healer 已有的安全合同继续保留：

```text
当前完整 State Snapshot
        │
        ▼
Backup：Clear → Save
        │ 成功
        ▼
Primary：Clear → Save
```

只有备份成功后才允许替换主槽。

Persistence Framework v1 新增可选 `store.save` writer hook，使 Domain 可以保留这种特殊的事务式写入策略，而不用绕开统一 Dirty / Schema / Diagnostics 框架。

#### 2.2 Boot Load Authority 暂不一次性重写

当前阶段仍由 Core1 执行旧数据：

- primary / backup recovery；
- `settingsVersion` migration；
- 默认值补全；
- 坐标迁移；
- future settings schema write fence。

这是故意的分阶段迁移。上述历史迁移链已经积累多个生产版本，当前不为了“文件更短”一次性重写。

Core1 完成 normalization 后，Settings Store 将该已验证内存 State 标记为：

```text
legacy_bootstrap_normalized
```

从此之后正常持久化由 Persistence Store 接管。

后续阶段确认实机兼容后，才允许把 boot migration 本身进一步搬进独立 Settings Model / Migration 文件。

---

### 3. Dirty + Debounce

旧行为中大量设置按钮调用：

```lua
SaveState()
```

每次都会立即执行：

```text
Backup Clear + Save
Primary Clear + Save
```

连续点击 `+ / -`、RGBA、尺寸调整时会产生大量重复序列化与 SaveData 调用。

现在兼容入口仍叫：

```lua
SaveState()
```

但其语义变为：

```text
MarkDirty("healer.settings")
        │
        ▼
750ms coalescing window
        │
        ▼
Persistence Tick
        │
        ▼
一次 backup-first durable save
```

显式收尾路径使用：

```lua
SaveState(true, reason)
```

强制立即 Flush。

Suite ModuleManager 在真实 `user/shutdown` Disable 时会通过 `HM:SaveSuiteSettings()` 完成最终 Flush；`startup_disabled` 不做无意义写盘。

---

### 4. Legacy Save 格式兼容

Persistence 写入仍保持 Healer 字段在 table 根部：

```lua
{
    settingsVersion = 222,
    healthScanMs = 150,
    ...,
    __rsmeta = {
        store = "healer.settings",
        lifetime = "Permanent",
        schema = 222,
    }
}
```

没有改成：

```lua
{ payload = { ... } }
```

原因是现阶段 Core1 boot loader 仍读取根字段。`__rsmeta` 对旧 loader 是无害扩展，因此阶段迁移期间旧/新代码仍可读取同一保存格式。

---

### 5. Recommendation List Presenter

文件：

`presentation/rh_recommendation_list_presenter.lua`

负责历史 standalone Recommendation HUD 的：

- Widget 创建；
- layout；
- row projection；
- drag / resize；
- scroll；
- display sort；
- visibility。

Suite Embedded 模式继续遵循既有产品决定：

> 不创建独立 Recommendation 排行窗口；Recommendation Domain 数据继续服务于 Head Marker 与 Raid Overlay。

Runtime 新代码通过 Presenter facade 刷新，不再把 Core1 当 Presentation Authority。

---

### 6. Buff Observer Presenter

文件：

`presentation/rh_buff_observer.lua`

Buff Observer 是显式 Operator/Developer 工具，不是后台全团扫描器。

规则：

- 只在窗口可见时运行；
- 只观察当前选中的 1 个成员；
- Runtime 已启用时优先利用已提交 Status Cache；
- 需要即时读取时通过 `ReplicatedHealerStatusCache:Read(member)`；
- Observer 读取不写入 Runtime 的 staged/committed raid Status Generation；
- Observer 自己拥有 scan/roster cadence，Runtime 只传入 `deltaMs / runtimeEnabled / rosterStable` 上下文。

这样 Runtime 不再拥有：

```text
buffObserverScanElapsed
buffObserverRosterElapsed
```

这两个 Presenter-specific 状态。

---

### 7. UI Diff Bridge 修复

本阶段修复：

```lua
HealerHealerSuiteUI = ...
```

与后续代码读取：

```lua
HealerSuiteUI
```

不一致的问题。

正确入口现在统一为：

```lua
HealerSuiteUI = ReplicatedSuite.UI
```

因此 Marker / Raid / Observer 的 `SetText / SetVisible / SetColor / SetExtent / SetAnchor / Font` 才会真正进入 Suite UI Framework 的 Diff Cache 与 Native-write diagnostics，而不是静默使用 fallback 直接写 Native UI。

这是实际性能修复，不只是命名整理。

---

### 8. Persistence Framework 扩展边界

`core/rs_persistence.lua` 新增 Store 可选字段：

```lua
save = function(key, encodedPayload, domainValue, options)
    ...
end
```

只有存在特殊耐久性要求的 Store 才应使用 custom writer。

普通 Store 仍应走：

```text
S.Api:SaveData
```

禁止每个 Domain 因为“想自己控制”就重写 Persistence；Healer 使用 custom writer 的理由是已有且经过生产使用的 backup-first/clear-before-replace 合同。

---

### 9. 本阶段性能边界

#### 不允许

- 在 Healer 50ms Visual lane 中保存设置；
- Buff Observer 可见时扫描整团；
- Runtime 重新拥有 Presenter timer；
- 每次设置 +/- 点击执行四次 SaveData/ClearData；
- 为了诊断在 UI 热路径输出 Chat。

#### 允许

- 设置变化 `MarkDirty`；
- 750ms 后合并一次 durable save；
- 用户关闭模块/ReloadAddon 前强制 Flush；
- Buff Observer 显式读取单个成员；
- Presenter 使用轻量 Diff counter。

---

### 10. 验证要求

源码/离线测试必须至少覆盖：

1. 全工程 Lua parse；
2. 100 人 Status / Health Slice 原有回归；
3. Roster Role OFF=0 native role read；
4. Healer Store MarkDirty 不立即写盘；
5. debounce 到期先 Backup 后 Primary；
6. Force Flush 立即持久化最新 State；
7. future schema/write fence 时零写入；
8. Persistence / Factory Reset / UI / FrameBudget 回归；
9. UI Bridge 必须实际绑定 `ReplicatedSuite.UI`。

游戏内仍需验证：

- 连续快速调整颜色/尺寸后 ReloadAddon，最后值不丢；
- 主槽异常时 backup recovery；
- Module Disable / Reload 收尾保存；
- Buff Observer 打开/关闭与进退团；
- Marker/Raid 的 Sprite 更新量是否相对旧 Build 下降。

---

### 11. 后续状态（2026-08-26）

本节原计划的 Settings Model / Presenter / Core1 boot migration 拆分已经在 `REPLICATED_HEALER_SETTINGS_ARCHITECTURE_v1_20260826.md` 完成。

当前 Authority：

```text
SettingsModel -> 设置语义与合法范围
SettingsMigrations -> 历史一次性迁移
SettingsBootstrap -> 启动只读加载
SettingsStore -> Permanent durable save
SettingsPresenter -> Suite UI Proxy
```

因此不要再按旧 TODO 在 Core1/Core2 新增第二套 Settings migration 或 Suite setting limits。



<a id="sec-5"></a>
## 5. Replicated Healer Roster / Native API Gateway v1

> 来源（已合并至本权威文档，原文件已收口）：`replicatedsuite\Docs\Architecture\Historical\REPLICATED_HEALER_ROSTER_API_GATEWAY_v1_20260826.md`

## Replicated Healer Roster / Native API Gateway v1

> 日期：2026-08-26  
> 状态：Foundation v2 Healer 第二批 Domain 迁移已落地  
> 首次落地 Build：`foundation-v2-healer-roster-gateway-v1`  
> 当前兼容 Build：`foundation-v2-healer-glue-persistence-v1`

---

### 1. 本阶段目标

本阶段不修改治疗推荐评分公式，而是继续拆除 Healer 历史 Core 中的共享基础职责：

1. `X2Unit / X2Team` Native 读取必须经过单一 Healer API Gateway；
2. Roster 不再每 1 秒同步扫描 50/100 人并立即发布；
3. 团队名单使用 Generation + Slice + Atomic Commit；
4. Native `GetRole()` 不再在职责评分关闭时无意义执行；
5. 稳定团队复用已提交 Role，并只做低频安全刷新；
6. `TEAM_MEMBERS_CHANGED` 只作为 invalidation signal，不能在 Native 团队 UI 回调栈中立即扫描；
7. Diagnostics 必须能看到 Roster phase、Slice、Role 读取量和 API 失败量。

---

### 2. 新 Authority 边界

```text
ArcheAge Native API
 X2Unit / X2Team
        │
        ▼
api/rh_api.lua
Native API Proxy Authority
        │
        ▼
domain/rh_roster.lua
Roster Snapshot Authority
        │
        ▼
runtime/rh_runtime.lua
Generation / Frame Policy
        │
        ├─────────────┐
        ▼             ▼
Core1 Domain      Core2 Presentation
评分/状态规则       Native Widget
```

#### `api/rh_api.lua`

唯一负责：

- `X2Unit` 方法调用；
- `X2Team:GetRole()`；
- Screen Position；
- UnitName / Health / MaxHealth / Distance 与 Suite Observation 对接；
- Native API 调用计数与失败诊断；
- 非法 Role 索引在进入 Native API 前直接拒绝。

业务代码不得重新绕开 Gateway 调用 `X2Unit/X2Team`。

#### `domain/rh_roster.lua`

唯一负责：

- Raid / CoRaid / Solo token discovery；
- Roster Generation；
- Slot cursor；
- Role cursor；
- Member identity key；
- Role reuse；
- Atomic roster commit；
- Hard invalidation / soft fallback poll 区分；
- 只读 Roster Diagnostics Projection。

`replicatedhealer_core1.lua` 不再拥有 Native Team API 和 Roster 构建实现。

---

### 3. Roster Generation

旧模式：

```text
每 1000ms
   ↓
同一帧扫描 50/100 个 team token
   ↓
同一帧读取所有成员 Role
   ↓
直接替换 roster
```

新模式：

```text
Request Roster Generation
        │
        ▼
Detect Raid Mode
        │
        ▼
Slot Staging
  ≤ 16 slots / frame
        │
        ▼
Role Staging
  ≤ 8 Native Role reads / frame
        │
        ▼
Complete Generation
        │
        ▼
Atomic Commit
```

当前默认：

| 工作 | 上限 |
|---|---:|
| Roster Slot | 16 / frame |
| Native Role | 8 / frame |
| fallback poll | 1000ms |
| stable Role refresh | 5000ms |

这些是削峰参数，不改变成员识别语义。

---

### 4. Hard Invalidation 与 Soft Poll

二者不能混为一个概念。

#### Hard Invalidation

来源：

- `TEAM_MEMBERS_CHANGED`；
- Runtime enable；
- 开启职责评分，需要建立可信 Native Role Snapshot；
- 明确的 Roster generation 失效。

行为：

```text
旧 committed roster 可以暂存用于 UI
        │
        ├─ Recommendation Domain Gate = CLOSED
        │
        ▼
等待 native 900ms settle
        │
        ▼
完整 Roster Generation
        │
        ▼
Atomic Commit
        │
        ▼
Domain Gate = OPEN
```

Status / Health Generation 在 Gate 关闭期间不得从可能已失效的 member token 开始新周期。

#### Soft Fallback Poll

每秒安全检查只属于容错路径。

它构建下一份 staging roster，但：

- 当前 committed roster 仍然可信；
- Health/Status 不需要因为后台安全轮询暂停；
- staging 完成后才比较并 Commit；
- 如果身份和 Role 没变化，Runtime 不清空 Domain Cache。

这避免“为了检查有没有变化，反而每秒停一次治疗计算”。

---

### 5. Member Identity

历史 key 主要由：

```text
raidIndex : memberIndex : unitToken
```

组成。

但团队 slot token 可以被新成员复用。因此 v1 改为：

```text
raidIndex : memberIndex : unitToken : memberName
```

这样：

```text
team_1_1 = Alice
        ↓ Alice 离队
team_1_1 = Bob
```

不会因为 Native token 相同而误认为是同一个缓存实体。

这是 Session Runtime Identity，不写入永久存档。

---

### 6. Role / `X2Team:GetRole()` 规则

这是本阶段的重要性能与稳定性规则。

#### 6.1 职责评分关闭

默认配置：

```text
roleScoringEnabled = false
```

此时：

> **Healer 不允许调用 Native `X2Team:GetRole()`。**

原因：

- Role 对当前 Recommendation 得分没有任何影响；
- 无意义 Native 调用只增加主线程/API 压力；
- 旧日志曾反复出现 `teamIndex:1 invalid`，虽然无法仅凭日志证明来源，但减少无意义 Team Role 调用是正确边界。

#### 6.2 首次开启职责评分

开启时使用 Hard Invalidation：

```text
Role Scoring ON
   ↓
Roster Gate CLOSED
   ↓
Slot Generation
   ↓
Role Generation ≤ 8 reads/frame
   ↓
Atomic Commit
   ↓
新的 Recommendation Generation
```

不能在 Role 尚未完整刷新时用一半新 Role、一半旧 Role 生成排行榜。

#### 6.3 稳定团队

Role Snapshot 允许复用。

默认每 5 秒才允许一次完整 Native Role refresh；普通 1 秒 fallback roster poll 直接复用相同成员的 committed Role。

如果出现新成员，即使尚未达到 5 秒刷新时间，也只对新成员补读 Role。

---

### 7. API Gateway 热路径规则

`rh_api.lua` 必须保持轻量：

1. 成功调用只增加数值 Counter；
2. 高频成功调用不创建日志文本；
3. 常用 0~3 参数调用避免构造 vararg table；
4. `UnitName / UnitDistance / UnitHealth / UnitMaxHealth` 继续复用 Suite Observation；
5. Native 失败才进入 RateLimited Diagnostics；
6. 非法 `teamIndex/memberIndex` 在 Native 边界前拒绝；
7. Gateway 不解释治疗业务语义。

例如：

```text
API Gateway 可以知道：
GetRole(1, 10) -> role

API Gateway 不应该知道：
主坦 +15 分
```

后者仍属于 Healer Domain。

---

### 8. FrameBudget

Roster Lane 正式接入：

| Lane | Priority | Cost | 策略 |
|---|---:|---:|---|
| Health | P1 | 1 | 正确性优先 |
| Roster | P2 | 1 | Slice 可延期 |
| Status | P2 | 2 | Slice 可延期 |
| Visual | P2 | 2 | 可延期 |
| Settings | P4 | 1 | 可延期 |

重要：

`TEAM_MEMBERS_CHANGED` invalidation 本身不受 Budget 阻塞；Budget 只控制 settle 后的下一小片扫描工作。

---

### 9. Diagnostics

`ReplicatedHealerModule:GetRuntimeDiagnostics()` 现在额外暴露：

```text
Roster
  Generation
  Ready / Invalidated
  Request Pending
  Phase
  Slot Cursor / Max Slots
  Role Cursor
  Staged Count
  Need Native Roles
  Max Slot Slice
  Max Role Slice
  Role Reads
  Role Reused

Native API
  Unit Calls
  Unit Failures
  Role Calls
  Role Failures
  Invalid Role Requests
  Screen Calls
  Screen Failures

Runtime
  Roster Deferred
```

因此以后排查团队相关异常时，可以直接回答：

- 当前是不是正在重建 Roster；
- 是否卡在 Slot 还是 Role；
- 职责评分关闭时有没有异常 Role API 调用；
- Native API 是否出现失败；
- FrameBudget 是否大量延期 Roster；
- 是否发生了过多 Hard Invalidation。

---

### 10. 兼容策略

历史 Core2 中仍有一些显式用户动作调用 `RebuildRoster()`，例如 Buff Observer 首次打开。

v1 保留兼容 facade：

```text
RebuildRoster()
    ↓
ReplicatedHealerRoster:RebuildImmediate()
```

但该入口只允许用于低频、显式用户/开发操作。

周期 Runtime **禁止**再使用同步 `RebuildRoster()`；周期路径只能使用 sliced Roster Domain。

后续迁移可继续把这些兼容全局函数逐步删除。

---

### 11. 本阶段验证

源码/模拟测试：

- Lua syntax：PASS；
- 100 人 CoRaid Roster：PASS；
- Slot `<= 16 / frame`：PASS；
- Role `<= 8 / frame`：PASS；
- `roleScoringEnabled=false` 时 Native Role reads = 0：PASS；
- 稳定团队 Role reuse：PASS；
- Hard invalidation Gate：PASS；
- Soft fallback poll 不关闭 committed Domain Gate：PASS；
- slot token 相同但成员名变化可识别为新 Identity：PASS；
- 非法 Role index 不进入 X2Team：PASS；
- Phase 6 Health/Status 100 人极端压力回归：PASS；
- Persistence / Storage / Factory Reset / UI / Theme / FrameBudget / Diagnostics 回归：PASS。

仍需 ArcheRage 实机验证：

- 50 人 / 100 人真实团；
- 频繁进团退团换团；
- 团队合并/二团；
- 职责评分 ON/OFF；
- 团队成员 Role 改变；
- 传送 / 副本切换；
- 长时间运行；
- `teamIndex:1 invalid` 日志是否显著减少/消失。

---

### 12. 后续状态

本文件原计划中的前两项已经在后续 `REPLICATED_HEALER_DOMAIN_SPLIT_v1_20260826.md` 完成：

1. Status Cache / Buff Scan 已从 Core1 迁移到 `domain/rh_status_cache.lua`；
2. Recommendation 已迁移到 `domain/rh_recommendation.lua`；
3. Marker / Raid Overlay 已迁移到独立 Presenter；
4. Runtime 已改为优先通过 Domain / Presenter facade 调用。

后续阶段已经继续完成：

- Status Cache / Recommendation 已拆为独立 Domain；
- Marker / Raid Overlay / Recommendation List / Buff Observer 已拆为独立 Presenter；
- Healer Settings 已接入 Foundation Persistence 的 Permanent Store，并保留 backup-first 安全写入；
- 普通设置修改改为 Dirty + Debounce，显式收尾保存才强制 Flush；
- Suite UI Diff Bridge 已修正并成为 Presenter 的统一热路径写入入口。

仍待完成：

- 真实游戏 50/100 人压力验证；
- 剩余显式 `RebuildRoster()` 用户工具入口逐步改成异步 Projection；
- Settings Model / Settings Presenter 与 boot-time legacy normalization 继续收口；
- 验证稳定后再按风险进入 Plates Runtime。

任何进一步拆分继续遵循：

> **先确定 Authority，再迁移实现；不为了文件数量而拆文件。**

---

<a id="sec-6"></a>
## 6. Aura Phase 12B 共享事实迁移桥（M1.16.0.15）

> **M1.16.0.15 当时状态**：迁移桥代码完成；Active V3 Healer Feature 尚未实现。当前实现状态已推进到下方 M1.16.0.16；Legacy Professional Healer 仍不在 TOC。

Healer 的 `rh_status_cache.lua` 是 Buff/Debuff/Hidden 状态读取的 Domain 入口。M1.16.0.15 不修改治疗推荐算法，而是把该入口改成：

```text
Healer Status Read
    ↓
HealerAuraBridge (Healer-owned lease)
    ↓
AuraObservationV3:GetSnapshot
    ↓
AuraObservationV3:GetStatusMap
    ↓ complete + reliable ?
       ├─ yes → 直接作为 StatusCache 事实
       └─ no  → 历史 X2Unit 直读回退
```

### Authority 不变

- `AuraObservationV3`：只拥有 Native Aura 事实和 coverage；
- `HealerAuraBridge`：只拥有 Healer 的 Aura Consumer lease 与状态投影适配；
- `rh_status_cache.lua`：Healer 状态缓存/原子提交；
- `rh_recommendation.lua`：规则匹配、救援评分、距离与优先级；
- Presentation：只显示 Domain 结果。

### 为什么必须保留降级回退

Healer 的状态缺失会直接改变治疗候选与评分。若共享 Aura 因 API 能力、256 上限或 Tooltip/Data 不可靠而覆盖不完整，不能把“没有观察到”当成“确定不存在”。因此只有 `available=true + complete=true + reliable=true` 才接受共享 Map；其它情况才执行旧直读，属于准确率安全阀，不是常规双扫描。

### 生命周期

- Healer Runtime Enable：先 Acquire `feature:combat_healer:aura`；事件/Update Handler 后续建立失败必须回滚该 Lease。
- Healer Runtime Disable：先 Release Aura；Release 失败返回 false，不继续制造“逻辑已关但共享观察仍驻留”的假状态。
- Bridge 自身无 Tick/OnUpdate；未启用 Healer 时不持有 Aura Consumer。

### 阶段结果

该迁移桥已在 M1.16.0.16 被 Active V3 Healer Domain Runtime 正式消费；Legacy Professional Healer 整包仍保持 TOC 脱离。

---

<a id="sec-7"></a>
## 7. V3 Domain Runtime（M1.16.0.16）

> 当前状态：**Roster / Health / Recommendation / Store / Feature lifecycle 已进入 Active V3。** Presentation 曾在 M1.16.0.17 接入推荐 Page/Floating；M1.16.0.18.43 按用户产品决定删除推荐 Floating，并把主 Page 收敛为规则/颜色/校准入口。Head Marker / Raid Overlay 继续 Active，见第 8、9 节。

### 7.1 Authority 分层

```text
FeatureRuntime(combat_healer)
  ↓ Demand lifecycle
HealerRosterV3 ──→ TeamRosterV3 facts
HealerAuraBridge ─→ AuraObservationV3 facts / accurate fallback
HealerHealthRuntime ─→ health/distance observation + generation staging
HealerRecommendationV3 ─→ treatment scoring/rules/hysteresis/sort
v3.healer Store ─→ permanent treatment policy
Presentation (next phase) ─→ projection/commands only
```

- `TeamRosterV3` 只拥有名单/槽位事实；Healer Roster 投影职责，职责评分关闭时不产生 Role read。
- `AuraObservationV3` 只拥有 Buff/Debuff/Hidden 事实；Healer Bridge 决定是否需要准确性 fallback。
- `HealerRecommendationV3` 是治疗业务 Authority：规则匹配、保护状态、评分、职责加分、候选滞回、稳定排序都不进入共享 Service。
- FeatureRuntime 是 enabled Authority；`v3.healer` Store 明确不保存 enabled。

### 7.2 性能与原子发布

保留已验证旧 Runtime 的切片预算：

- Health：最多 20 成员/片；
- Status：最多 8 成员/片；
- 紧急 targeted Status：最多 8 成员/Health 片；
- 只注册一个 `v3_healer_runtime` Suite Scheduler 任务；无 Healer-owned OnUpdate/Tick。

每次 roster generation：

```text
完整 Status staging
    ↓ commit generation
Health staging + targeted accurate refresh
    ↓ complete
Recommendation evaluate
    ↓ atomic publish
```

Status 读取失败时禁止把空表当成“确定无 Buff”：周期扫描保留上一份准确状态；Health 正确性路径若无法取得准确状态，把该成员标记 unavailable，并清除当次 candidate memory，避免错误救援加分。

### 7.3 准确 Aura 读取

`HealerAuraBridge v2:ReadAccurate()`：

1. 先读 AuraObservationV3 Snapshot + StatusMap；
2. `available + complete + reliable` → 接受共享事实；
3. 否则执行有界 Native Buff/DeBuff/Hidden fallback；
4. Native count 无法读取、已有 row 但 data/tooltip 均不可用、或已有 Aura row 解析不到 Effect ID → fail closed。

因此性能优化不会以“把未知当不存在”为代价。

### 7.4 旧设置迁移

`v3.healer` 在本阶段为 schema 1；M1.16.0.17 升 schema 2 增加 `widgetWindow`，M1.16.0.18 再升 schema 3 增加 `presentation.head/raid`，治疗策略语义不变。首次空 Store 才尝试只读：

1. `replicated_healer_recommender_v2`；
2. primary 无效时 backup。

只迁治疗策略字段，不迁 `enabled`；不删除/覆盖 legacy source。旧 payload 若根本没有 `trackedBuffs` 字段，保持旧 SettingsModel 的空列表语义；只有全新 V3 默认才建立 25875/220 两条追踪。

### 7.5 生命周期事务

获取顺序：

```text
TeamRoster → Aura → Internal Events → Health Scheduler
```

释放严格逆序。Demand reconcile 失败会恢复 consumer snapshot 并反向 reconcile；故障注入已覆盖“Roster 已拿到但 Aura Start 失败”和“Disable 中 Aura Stop 失败”两种中间态，均能恢复一致状态。

### 7.6 后续状态

M1.16.0.17 曾完成推荐列表/详情与推荐悬浮窗；M1.16.0.18.43 已按用户决定从 Active Presentation 移除推荐悬浮窗，并停止在主 Page 创建推荐名单/成员详情表。Recommendation Domain 继续作为 Raid Overlay 颜色/优先级事实来源。**禁止**重新加载旧 Professional Healer UI/Runtime 整包。Head Marker / Raid Overlay 仍是独立 Presentation Consumer；完整 Healing Rule、颜色与 Tracked Buff 编辑继续复用同一 `v3.healer` Authority。

<a id="sec-8"></a>
## 8. V3 Presentation（M1.16.0.17）

### 8.1 页面边界

`presentation/v3/pages/rs_v3_healer_page.lua` 是 `combat.healer` 的 Active Page。它只能调用 Healer Feature 的公开 Projection/Commands：

```text
GetProjection(limit)
GetMemberDetail(key)
GetHealth / GetSettings
Commands:ApplySettingFromBinding
Commands:ApplyPresentationSettingFromBinding
Commands:SetRule / AddRule / RemoveRule
Commands:SetTrackedBuff / AddTrackedBuff / RemoveTrackedBuff
Commands:SetHealerColor / SetRaidSectionRect / ResetRaidLayout
Commands:RequestRosterRefresh
AcquireConsumer / ReleaseConsumer
```

禁止 Page 直接调用 X2Unit/X2Team/Aura、Recommendation 私有缓存、Legacy `ReplicatedHealerModule` 或 Professional UI。成员 Status 明细来自 committed cache 的 detached projection，因此“点一个玩家看状态”不会成为新的 Native scan 路径。

### 8.1.1 M1.16.0.18.14 设置布局 / Calibration

主 Page 的有限范围数值统一改为 `CompactNumericSetting`：同一 Binding 同时驱动 Slider 与精确输入框，不增加第二 Settings Authority。核心策略使用 2 列紧凑网格，视觉设置使用 3 列紧凑网格，并通过“治疗策略 / 战斗显示”切换避免两组同时占满页面；Advanced Editor 的有限范围数值同样使用 Slider+输入。Raid Calibration backdrop 使用 `artwork` 层和明确可见 Alpha，仍然只改变 Presentation Drawable，不新增 Health/Aura/Roster 扫描。

### 8.2 主 Page 当前职责（M1.16.0.18.43）

主 Page **不再显示治疗推荐名单或成员状态详情表**。页面只负责：

- 显式启停治疗 Runtime；
- 团队名单手动刷新；
- 治疗规则 / Tracked Buff / 颜色 / 距离和阈值设置；
- “校准团队色块”入口与当前校准/运行状态。

Recommendation/Status Domain 仍然运行，因为 Raid Overlay 的颜色和优先级来自已经提交的 recommendation facts；但这些事实不再复制成另一套排名 UI。这样治疗辅助的用户出口收敛到**屏幕团队颜色模块**，而不是列表。

### 8.3 Recommendation Floating 已移除

M1.16.0.18.43 按用户明确产品决定，`presentation/v3/widgets/rs_v3_healer_widget.lua` **不在 Active TOC**，`WidgetHost id=combat.healer` 不允许注册。旧源码和 `widgetWindow` Store 字段只为升级兼容/历史追溯保留，不能作为 Active capability。

```text
Healer Recommendation Domain
        ↓ committed priority / color facts
Raid Overlay / Head Marker
        ↓ screen treatment aid

(no recommendation Floating list)
```

`UIV3Acceptance v32` 与 Healer sequence acceptance 会把旧 `combat.healer` Widget 重新注册视为回归。

### 8.4 Persistence / Settings Authority

`v3.healer` schema 3：

- settings：治疗业务策略；
- widgetWindow：历史推荐 Floating 的兼容字段；M1.16.0.18.43 不再有 Active `combat.healer` Widget，新代码不得重新消费该字段创建推荐窗口；
- migration：旧策略迁移元数据；
- **不保存 enabled**。

Widget 通过 `GetWidgetWindowState()` 获取 live Presentation state，不直接访问 `Feature.State`。RSUI Persistent Binding 经 `Feature.Commands:ApplySettingFromBinding()` / `ApplyPresentationSettingFromBinding()` 进入绑定专用 raw setter，setter 只做 Normalize + publish，真正 `MarkDirty` 由 Binding transaction 执行；Feature Command `SetScalarSetting()` 仍自行持久化。两条写路径不能重复 MarkDirty。规则、Tracked Buff、颜色、布局和手动 Roster 刷新统一经 `Feature.Commands`。

### 8.5 M1.16.0.17 当时仍未迁移

该历史阶段当时仍缺 Head Marker、Raid Overlay、完整 Healing Rule 编辑器以及颜色 / Tracked Buff 高级编辑器。Head/Raid 已在 M1.16.0.18 完成，见第 9 节；剩余高级设置编辑器仍必须复用 `v3.healer` 的 Normalize/Command Authority，不建立第二套 Schema。

### 8.6 验收重点

- 50/100 人团队时 Raid Overlay 的 4×25 色块是否稳定且不卡顿；
- 校准模式在 Feature disabled 时是否显示四组区域并保持 `consumerHeld=false`；
- Live Overlay 是否只持有一个 Presentation Consumer，结束校准/关闭功能后是否全部释放；
- 快速修改数值设置是否一次输入只产生一次 Persistence dirty transaction；
- 状态详情选择是否不增加 Native Aura read；
- 老 schema 1/2 Store 覆盖升级后设置保留；历史 widgetWindow 可继续 Normalize/保存但不会创建 Active 推荐窗口；
- Professional Healer 与 `ui/rs_healer_workspace.lua` 仍不在 Active TOC。



<a id="sec-9"></a>
## 9. V3 Head Marker / Raid Overlay（M1.16.0.18）

### 9.1 Authority / Native 边界

视觉层只能走公开 Feature 面：

```text
Presentation
  ↓ GetProjection / GetRosterProjection / Commands
Healer Feature
  ↓ ProjectUnitToScreen(unitToken)
HealerScreenProjection
  ↓
X2Unit:GetUnitScreenPosition only
```

`HealerScreenProjection` 只是无业务状态的 Native 投影桥：不扫描团队、不读 Health/Aura、不缓存治疗结论。Head/Raid Presenter 中禁止出现 X2Unit/X2Team、AuraObservation、HealthRuntime 或 Recommendation 私有缓存引用。

### 9.2 Head Marker hot path

`rs_v3_healer_head_marker.lua` 持有独立 token `presentation:healer_head_marker`：

- Start 前按当前 count 预分配 Marker pool；50ms visual task 内禁止创建 Native Widget；
- Recommendation event 到来时缓存 projection 并预格式化 name/distance/score 文本；
- visual task 只做 `ProjectUnitToScreen`、anchor/visibility/text/color 必要 Diff；Store 深拷贝不进入该路径；
- 形状、大小、rank/health/可选名称/距离/分数保持 Presentation Authority，不反向影响 Recommendation；
- Head disabled 或 Feature disabled 时必须 `running=false / consumerHeld=false / taskActive=false`。

### 9.3 Raid Overlay / Calibration

`rs_v3_healer_raid_overlay.lua` 持有独立 token `presentation:healer_raid_overlay`：

- Start 时预分配 4 个 section × 25 个 slot/rank/calibration label；
- slot 映射仍按 raidIndex + memberIndex 进入 4 个 25 人区域；
- Feature 通过 `Recommendation:GetRaidDisplayProjection()` 从已提交 Health/Status + roster 生成全团 detached display rows：候选保留 rank/候选颜色，非候选恢复治疗范围、低血、紧急、Tracked Buff/显示规则颜色；`proximityMode=false` 只隐藏普通范围底色，高优先级状态仍显示。该路径纯 Lua，不新增 Native Health/Status 扫描；
- effectMode=1 完全事件驱动且 **不得存在 Scheduler task**；动态效果模式只允许一个 100ms P4 task，并只更新候选 slot alpha；
- calibration 开启时 section root 才可拖动；drag stop 通过 Layout logical rect → `Feature.Commands:SetRaidSectionRect()` 持久化；UILayer/Raise 只在生命周期/可见性边界执行。

### 9.4 Store schema 3 / 升级兼容

schema 3：

```text
v3.healer
  settings        treatment policy
  widgetWindow    floating recommendation presentation
  presentation
    head
    raid
      sections[4]
  migration
    legacyImported
    visualImported
```

全新 V3 用户 Head/Raid 默认关闭。旧版本首次 legacy import 会同时读取历史视觉字段；已经在 schema2 完成 `legacyImported=true` 的用户，由 schema3 recovery 再只读 legacy primary/backup 一次恢复 Marker 数量、显示选项与 Overlay rect，并写 `visualImported=true`。之后不会因为每次 Load 都再次覆盖用户在 V3 中的新视觉设置。

### 9.5 独立生命周期事务

Dormant controller 与 active realtime listener 使用不同 EventBus owner，解决“Stop active listener 时把自己的后续唤醒监听一起删掉”的 owner collision。

Stop 顺序：

```text
Release Presentation Demand
   ↓ success
Remove Visual Task
Unsubscribe active realtime owner
Hide visuals
```

Release 失败且 Feature 仍启用时必须保持旧显示层完整运行；若 FeatureRuntime 已先 clear 全 Demand，再广播 disabled lifecycle，则 token missing 视为 shutdown 已收敛成功。Head/Raid 之间互不拥有对方资源。

封版专项验证覆盖：100 人 whole-roster projection、`proximityMode=false` 高优先级颜色保留、双团 `1/25/26/50` 4×25 槽位边界、Head/Raid Demand Release 故障回滚、FeatureRuntime 先 clear Demand 的幂等停机、Raid 静态模式零动画任务、Head 20 次 visual tick 零 Native Widget 新分配/零 Store 与 Recommendation 重读、schema2→schema3 视觉参数恢复。

### 9.6 当前剩余

- ArcheRage RU 50/100 人 Head 跟随、4×25 Overlay、校准拖动、动态效果与资源释放实机验收；
- M1.16.0.18.2 的规则、颜色、Tracked Buff 编辑器已完成代码与本地命令回归；仍需 Fresh Reload 后做完整实机回归，确认长文本、下拉降级和保存回读。

当前 Feature metadata 为 `migrated_m16_18`，表示代码链路已迁移闭合；Fresh Reload、保存回读与 50/100 人视觉实机验收仍必须单独完成，不能由本地 Parse/Harness 替代。

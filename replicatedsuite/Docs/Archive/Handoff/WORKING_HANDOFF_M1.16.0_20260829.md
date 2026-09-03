# Replicated Suite — M1.16.0 Combat Analytics Foundation 阶段交接

> **正式封版说明**：本文件是开发中期快照。M1.16.0 正式架构已并入 `CURRENT_*`、`Rebuild/CURRENT_MILESTONE.md` 与 `Architecture/COMBAT_ANALYTICS_ARCHITECTURE.md`；冲突时以后者为准。

> 快照日期：2026-08-29  
> 当前工作 BuildTag：`v3-m1.16.0-combat-analytics-foundation`  
> 基线 BuildTag：`v3-m1.15.7-foundation-event-contract-hardening`  
> 状态：**Historical Working Checkpoint / 正式 M1.16.0 文档已接管权威**

---

## 0. 使用说明 / 当前权威关系

本文件用于防止 M1.16.0 开发上下文丢失，是当前工作快照的阶段交接文档。

后续 Agent/开发者恢复工作时必须：

1. 先阅读 `replicatedsuite/Docs/README.md`；
2. 再阅读 `Docs/CURRENT_ARCHITECTURE.md`、`Docs/CURRENT_REBUILD_STATUS.md`、`Docs/Rebuild/CURRENT_MILESTONE.md`；
3. **随后立即阅读本文件**；
4. 对 M1.16.0 Combat Analytics 范围，如果旧 CURRENT 文档仍停留在 M1.15.7，以本交接记录 + 当前实际代码为准；
5. M1.16.0 正式封版时，必须把本文件中的有效结论合并回 CURRENT/ARCHITECTURE 文档，不能长期保留“双权威”。

严禁仅凭这份文字猜测修改；恢复开发后仍需读取实际代码并重新执行门禁。

---

# 1. 当前阶段目标

M1.16.0 不再把 Replicated DPS 当作单纯的“伤害排行榜”。目标已经升级为：

**Combat Analytics / 战斗分析基础设施**。

最终需要支持并长期扩展：

- 伤害 / DPS；
- 承伤 / DTPS；
- 治疗 / HPS；
- 击杀 / 助攻 / 死亡；
- 技能释放次数 / 起手序列；
- 爆发窗口 / 最高单击；
- 控制释放 / 控制命中 / 控制持续时间；
- 乐器 / 歌曲演奏次数 / 演奏持续时间 / 覆盖；
- 打断 / 驱散 / 净化 / 解控 / 复活 / 防御技能；
- Buff / Debuff 观察持续时间；
- Boss 机制命中；
- Encounter 分段；
- 战斗 Timeline；
- 最近战斗历史；
- 玩家 A/B 横向比较；
- 后续更多独立 Metric。

重点不是“功能数量”，而是形成长期稳定、按需运行、共享底层的战斗分析框架。

---

# 2. 已确定的核心架构

```text
Native Combat / Optional Cast Events
            │
            ▼
      Core Events v3
            │
            ▼
   CombatEventBusV3 v6
            │
            │  ONE scope=all consumer
            ▼
   CombatAnalyticsV3 v1
            │
            ├── Metric Registry
            ├── Compiled Fact Dispatch Plans
            ├── Compiled Native Event Plans
            ├── Consumer / Metric Lifecycle
            └── Shared Projection Publish
                    │
                    ├── dps_core (隐藏适配器)
                    ├── encounter
                    ├── kills
                    ├── casts
                    ├── performance
                    ├── control
                    ├── songcraft
                    ├── utility
                    ├── aura
                    └── mechanics
```

关键原则：

- **不允许每个 Metric 自己注册 `COMBAT_MSG`**；
- 高级分析统一只向 `CombatEventBusV3` 保持一个 `scope=all` consumer；
- Metric Registry 根据事实类别预编译分发计划；
- `damage` 不应盲目 `xpcall` 所有 Metric；
- `aura` 只分发给声明需要 aura 的 Metric；
- Native `SPELLCAST_*` 只分发给声明该 Native Event 的 Metric；
- 原 DPS 的成熟 PVP/PVE/Replay 算法保留，不重写成新的一套；
- DeathReview 继续保持独立低成本 self-scope 生命周期，不依赖高性能 Combat Analytics。

---

# 3. 当前底层版本

当前实际代码版本：

```text
Core Events                 v3
FoundationGate              v23
CombatEventBusV3            v6
CombatAnalyticsV3           v1
Combat MetricCommon         v2
CombatAnalytics Store       schema 1
```

Bootstrap：

```text
v3-m1.16.0-combat-analytics-foundation
```

---

# 4. M1.16.0 当前新增的共享底层

## 4.1 CombatAnalyticsV3

文件：

`replicatedsuite/services/rs_combat_analytics_v3.lua`

职责：

- Metric 注册；
- Metric 独立启停；
- Consumer Lease 管理；
- 唯一 all-scope CombatEventBus 订阅；
- Optional Native Spellcast 增强事件；
- 编译 Fact Category Dispatch Plan；
- 编译 Native Event Dispatch Plan；
- Metric borrowed Fact mutation fence；
- 350ms 合并 Projection publish；
- Metric health / runtime health；
- Metric Projection 获取；
- 整体 session 状态释放。

Metric 不允许通过 Analytics Authority 反向直接调用 Presentation。

---

## 4.2 MetricCommon v2

文件：

`features/combat/analytics/rs_combat_metric_common.lua`

共享能力：

- Actor key；
- Actor 有界状态；
- 排行 Projection；
- 有界 Queue；
- Queue prune；
- Debounce / dedupe；
- 统一数值/时间辅助；
- Detail 容量控制。

### 重要修复

早期草稿使用“前端打洞数组 + `#table`”，Lua 对稀疏数组的长度未定义。

当前必须使用：

```text
head
+ tail
+ count
```

显式队列状态，不依赖 `#sparseTable`。

另一个禁止项：

```lua
table.remove(queue, 1)
```

不能出现在战斗高频有界队列里，否则满容量后每次淘汰都会 O(n) 移动数组。

---

# 5. 当前 9 个公开 Metric

## 5.1 Encounter — 战斗分段 / 历史 / Timeline

Metric ID：`encounter`

当前设计：

- 只有 `damage / heal / death` 是 Encounter 锚点；
- Aura 只能附着到已经存在的 Encounter；
- Aura 不允许自己开启一场战斗；
- Aura 不允许在战后延长战斗；
- 8 秒无有效战斗后 one-shot 收口；
- 无永久 Tick；
- 当前 Timeline 最大 512；
- Actor set 有界；
- 最近历史最大 20 场；
- History 只保存紧凑摘要，**不能复制每场完整 512 Timeline**。

历史可比较：

- 时长；
- 伤害；
- 治疗；
- 死亡等。

---

## 5.2 Kills — 击杀 / 助攻 / 死亡

Metric ID：`kills`

当前支持：

- kills；
- assists；
- deaths；
- 最近伤害归属；
- 目标分解；
- 直接/推导证据；
- death dedupe。

### 证据原则

如果死亡事件直接给出来源：

`direct_death_source`

如果没有直接来源，但最近伤害账本能推导：

`inferred_recent_damage`

**不能把推导击杀/助攻伪装成服务器直接事实。**

死亡双通道有约 1.2 秒去重，防止 `COMBAT_MSG death + UNIT_DEAD_NOTICE` 计为两次。

---

## 5.3 Casts — 技能释放 / 起手

Metric ID：`casts`

支持：

- 全局战斗活动推导技能次数；
- SELF Native `SPELLCAST_START` 精确增强；
- 每玩家技能次数；
- opener / 起手顺序；
- 时间点。

Native cast 必须严格确认 caster token 为 `player`。

不得将别人的 Native Cast 错记到自己。

---

## 5.4 Performance — 爆发 / 生存

Metric ID：`performance`

当前支持：

- 最高单次伤害；
- 5 秒峰值伤害；
- 5 秒峰值 DPS；
- 死亡次数；
- 观察到的战斗/存活时间。

### 5秒窗口设计

已经放弃“最多保存 96 hit”。

当前应使用：

```text
100ms 固定时间桶
约 5 秒窗口
硬边界约 64 桶
```

高频职业 5 秒打 200 / 500 次也应先聚合到时间桶，不应因为 hit count 上限漏伤害。

---

## 5.5 Control — 控制分析

Metric ID：`control`

当前范围：

- 控制技能活动次数；
- 控制命中；
- 控制目标；
- 控制类型；
- 如果真实观察到 Aura Apply / Remove：计算控制持续时间。

当前静态目录包含多类 CC，例如：

- Stun；
- Trip；
- Charm；
- Sleep；
- Silence；
- Fear；
- Root；
- Freeze；
- Petrify；
- Disarm；
- Blind；
- Taunt；
- 等。

如果 Aura 生命周期不可见，只能统计次数/活动，**不能虚构控制时长**。

---

## 5.6 Songcraft — 乐器 / 演奏

Metric ID：`songcraft`

当前支持：

- 演奏技能次数；
- 每首歌曲次数；
- 当前 SELF 演奏状态；
- START / STOP；
- 切歌；
- 演奏持续时间；
- 当前进行中的实时时长；
- Aura 观察覆盖；
- Coverage 状态。

### Native 可靠性规则

只有 `SPELLCAST_START + SPELLCAST_STOP` 都可用时，才可以把 SELF Native 演奏持续时间当作完整精确能力。

如果只有 START：

必须降级为类似：

```text
SELF_NATIVE_CAST_ONLY
```

不能假装有可靠 duration。

当前 Native caster 参数已参考项目旧 Plates 实码校对：

- `SPELLCAST_START` caster token：第 3 参数；
- `SPELLCAST_STOP / SUCCEEDED` caster token：第 1 参数。

只有 caster == `player` 才进入本机精确统计。

---

## 5.7 Utility — 辅助贡献

Metric ID：`utility`

计划/当前目录支持的类型：

- interrupt；
- dispel；
- cleanse；
- CC break；
- resurrection；
- defensive；
- 其它明确工具技能。

必须通过 `CombatAbilityCatalog` 的预建索引判定。

严禁 CombatFact 高频路径复杂字符串/Tag 扫描。

---

## 5.8 Aura — Buff / Debuff 覆盖

Metric ID：`aura`

CombatEventBusV3 v6 新增保守 Aura 归一化：

```text
aura_apply
aura_remove
buff
debuff
```

只有明确的客户端事件模式才归一化，例如类似：

```text
SPELL_DEBUFF_APPLIED
SPELL_BUFF_REMOVED
```

当前支持：

- Buff apply 次数；
- Debuff apply 次数；
- 当前 active aura；
- 观察到的 uptime；
- actor/detail 分解。

关键语义：

> 没观察到 Aura Event ≠ uptime 0%。

必须暴露 coverage / evidence，不能用 0% 伪装“确定没有覆盖”。

---

## 5.9 Mechanics — Boss 机制

Metric ID：`mechanics`

使用：

`data/rs_combat_mechanic_catalog.lua`

来源复用现有 BossAlerts/静态 Boss 机制数据。

要求：

- 预建 ID/精确索引；
- CombatFact 热路径 O(1) 或近似 O(1)；
- 禁止运行时对所有 Boss 文本做模糊字符串扫描。

---

# 6. 静态 Catalog

## 6.1 CombatAbilityCatalog

文件：

`data/rs_combat_ability_catalog.lua`

当前一次构建结果曾达到约：

```text
skills   464
buffs    393
songs      4
control  ~71
utility  ~14
```

这些数字是当前工作态的构建结果，不代表 RU 服最终一对一权威校验已完成。

后续必须继续遵守项目静态 ID 原则：

- ID 中心化；
- 语义 key；
- 来源；
- verification metadata；
- 预建索引；
- 不在业务模块散落魔法 ID。

尤其 Songcraft / Control / Utility 后续要继续结合 RU 数据验证。

---

## 6.2 CombatMechanicCatalog

文件：

`data/rs_combat_mechanic_catalog.lua`

职责：把 BossAlerts 机制数据转成 Combat Analytics 可使用的索引层。

不把 Boss-specific 逻辑硬编码进通用 Metric。

---

# 7. DPS 与 Analytics 的边界

这是 M1.16 最重要的架构约束之一。

原 DPS Domain 已经包含成熟逻辑：

- PVE / PVP；
- source.damage；
- target.taken；
- shared heal；
- provisional classification；
- Replay Ledger；
- relation evidence；
- team evidence；
- skill / target detail；
- active time。

**这些不能在 CombatAnalytics 里重写第二份。**

当前设计：

```text
DPS Feature
    │
    │ register/bind
    ▼
hidden dps_core Metric Adapter
    │
    ▼
CombatAnalyticsV3
```

Analytics Authority 本身不能硬编码知道具体 DPS Feature 实现。

DPS 关闭、Analytics 关闭、DeathReview 关闭必须保持相互独立的资源生命周期。

---

# 8. Optional Native Events / Events v3

M1.16 引入的重要 Core 能力。

目的：

某些客户端增强事件（例如 `SPELLCAST_START / STOP`）如果 RU Build 不提供：

- 不应该把整个 Foundation 判死；
- 只应该让对应 Metric 降级；
- 核心 CombatEvent 仍然保持强事务要求。

`Events v3` 当前新增：

- `RegisterOptional()`；
- `SubscribeOptional()`；
- optional failure counters；
- optional unavailable health；
- Required/Optional 同 Topic 事务语义。

### 已发现并修过的两个 Lua/状态风险

#### A. 禁止假三元

错误写法：

```lua
optional and RegisterOptional() or Register()
```

当 `RegisterOptional()` 返回 false 时，Lua 会继续调用 `Register()`。

必须显式 `if/else`。

#### B. Topic Required/Optional 不能靠漂移布尔状态

同一 Native Topic 可以同时有：

- optional listener；
- required listener。

Required listener 注册失败时，不能提前把 Topic 晋升 Required。

Required listener 离开后，如果只剩 Optional listener，Topic 必须恢复 optional。

当前代码已开始按“现有 listener 集合重新计算 Topic 语义”的方式收紧。

**这是最终封版前必须重新专项回归的重点。**

---

# 9. Store / 生命周期

Store：

`v3.combat_analytics`

schema：`1`

只保存永久配置，不保存战斗 Session 大数据。

公开 Metric：

```text
encounter
kills
casts
performance
control
songcraft
utility
aura
mechanics
```

每个 Metric 都应：

- 独立 persisted toggle；
- 独立 session state；
- Disable 后释放自己的 session 缓存；
- 配置仍保留；
- 不因为 UI 隐藏就默认继续高耗运行。

整个 Combat Analytics Disable 后：

- 释放全部 Analytics Metric session state；
- 释放唯一 all-scope CombatEventBus lease；
- 释放 Optional Native subscriptions；
- 不应该误清原 DPS 用户主动保留的成熟统计数据（具体 Bridge 生命周期需继续回归）。

---

# 10. UI 当前方向

新增页面：

`presentation/v3/pages/rs_v3_combat_analytics_page.lua`

Feature Registry 新入口：

```text
combat.analytics
战斗分析
```

UI 不采用“一张巨型表塞所有列”。

目标层次：

```text
战斗统计
├── 原伤害统计
│   ├── 伤害
│   ├── 承伤
│   └── 治疗
│
└── 战斗分析
    ├── 战斗历史
    ├── 击杀
    ├── 技能
    ├── 爆发 / 生存
    ├── 控制
    ├── 乐器
    ├── 辅助
    ├── Buff / Debuff
    └── Boss 机制
```

支持选择两个玩家做 A/B 指标比较。

仍必须以 1024×768 为硬实机验证场景，不得只按 1080p/2K 设计。

---

# 11. 证据等级

高级战斗分析必须严格区分：

## Direct / 直接事实

例如：

- 伤害；
- 治疗；
- 明确 death；
- 明确 Native self cast；
- 明确 Aura apply/remove。

## Observed / 观察状态

例如：

- Aura 从 Apply 到 Remove 的观察时长；
- SELF song start/stop 的观察时长；
- Encounter 内观察到的时间。

## Inferred / 推导

例如：

- 没有明确 killer 时从最近伤害推导最后一击；
- Assist；
- 由战斗活动推导的 cast/activity。

Projection/UI 必须能保留 `confidence/evidence`，不能把 Inferred 冒充 Direct。

---

# 12. 性能与内存硬约束

M1.16 必须继续遵守：

- 不新增永久 Tick；
- 不为每个 Metric 新建 Combat Handler；
- 不在 CombatFact 高频路径创建 Native UI；
- 不在 CombatFact 高频路径 SaveData；
- 不在 CombatFact 高频路径扫描 TeamRoster；
- 不在循环中运行 loader；
- 不在热路径复杂 Tag/名称模糊匹配；
- 所有长期队列必须有界；
- Metric Disable 后释放 Session cache；
- History 保存摘要而非完整 Timeline 深拷贝。

当前主要预算目标：

```text
Metric Actor state        <= 512
Encounter Timeline        <= 512
Encounter History         <= 20 summaries
Kill recent targets       <= 512
Death dedupe              <= 512
Control active Aura       <= 512
Song/Aura active          <= ~1024 hard bounded
5s burst                  ~50 x 100ms buckets, hard ~64
```

具体硬上限以当前源码常量为准，恢复后不要只信这张表。

---

# 13. GitHub / 外部设计研究结论

本阶段已经参考过公开 Combat Meter 思路，包括：

- Strawberry-devs / ArcheRage-addons 的 `dpsmeter`；
- Strawberry-devs / ArcheAge-GladiatorlosSA-PoC；
- ArcheRage Damage/Heal Meter Overlay；
- Details! Damage Meter；
- Skada；
- DPSMate；
- Lost Ark 类现代 Meter 的技能/Buff/历史分析思路。

主要吸收的不是代码，而是产品/架构模式：

- Meter 应该是 Combat Analyzer，不只是 Damage Ranking；
- 主榜 → Player Drilldown；
- Kill/Death/CC/Interrupt/Aura/Uptime 是正式维度；
- Combat History / Timeline 非常重要；
- 支持按指标切换而不是把几十列堆到一张表；
- 证据质量必须比“丰富但错误的数据”优先。

不应直接复制这些项目的全局变量、OnUpdate 或单文件巨型设计。

---

# 14. 当前 M1.16 相对 M1.15.7 的实际文件差异

## 修改文件（8）

```text
replicatedsuite/toc.g
replicatedsuite/replicatedsuite.lua
replicatedsuite/core/rs_events.lua
replicatedsuite/core/rs_foundation_gate.lua
replicatedsuite/services/rs_combat_event_bus_v3.lua
replicatedsuite/features/rs_feature_registry.lua
replicatedsuite/features/combat/dps/rs_dps_acceptance.lua
replicatedsuite/features/combat/dps/rs_dps_feature.lua
```

## 新增代码文件（9）

```text
replicatedsuite/data/rs_combat_ability_catalog.lua
replicatedsuite/data/rs_combat_mechanic_catalog.lua
replicatedsuite/services/rs_combat_analytics_v3.lua
replicatedsuite/features/combat/analytics/rs_combat_metric_common.lua
replicatedsuite/features/combat/analytics/rs_combat_analytics_metrics.lua
replicatedsuite/features/combat/analytics/rs_combat_analytics_store.lua
replicatedsuite/features/combat/analytics/rs_combat_analytics_feature.lua
replicatedsuite/features/combat/analytics/rs_combat_analytics_acceptance.lua
replicatedsuite/presentation/v3/pages/rs_v3_combat_analytics_page.lua
```

## 本次防丢失阶段文档（新增）

```text
replicatedsuite/Docs/WORKING_HANDOFF_M1.16.0_20260829.md
```

因此本次“Working Snapshot 增量包”总计：

```text
8 modified + 10 added = 18 files
```

删除：0。

---

# 15. 当前验证状态（非常重要）

当前重新构建后的工作树：

```text
Active TOC entries = 144
144 / 144 路径存在
```

此前 M1.16 工作过程中曾完成并通过的专项 Harness 包括：

- MetricCommon bounded queue；
- AbilityCatalog 构建；
- Analytics Metrics；
- 200-hit 5秒爆发；
- death dedupe；
- Encounter Aura 边界；
- realtime song duration；
- Events Optional；
- Analytics Runtime 单一 Bus Consumer。

但是：

> 当前新的执行容器已经没有 `lua` / `luac` 可执行文件。

因此在**最新一轮 Optional Required/Optional Topic 语义收紧之后**，无法在这个新容器里重新执行最终一次 Lua 语法/Harness。

所以这份包必须标记为：

**M1.16.0 Working Snapshot，而不是 Final Release。**

恢复工作后的第一优先级硬门：

1. 在有 Lua runtime 的环境对 144 Active Lua 全部 `loadfile`；
2. 重跑 Events Optional Harness；
3. 重跑 MetricCommon Harness；
4. 重跑 Analytics Metrics Harness；
5. 重跑 Analytics Runtime Harness；
6. 重跑 DPS Acceptance；
7. 重跑 FoundationGate v23；
8. 再进行 ArcheRage RU 实机。

---

# 16. M1.16.0 正式封版前剩余工作

按优先级：

## P0 — 必须先完成

- Events v3 Required/Optional 同 Topic 事务回归；
- 144 Active Lua 最终语法；
- FoundationGate v23；
- Analytics Acceptance；
- DPS Bridge 生命周期回归；
- Analytics all-scope Consumer 必须确认只有 1 份；
- Metric Disable / Analytics Disable 资源释放；
- borrowed CombatFact / NativeFact mutation fence；
- 所有 bounded queue 长时间压力。

## P1 — 文档 Authority 收口

当前旧 CURRENT 文档多数仍显示 M1.15.7。

正式 M1.16 封版必须更新：

```text
Docs/README.md
Docs/CHANGELOG.md
Docs/CURRENT_ARCHITECTURE.md
Docs/CURRENT_REBUILD_STATUS.md
Docs/Rebuild/CURRENT_MILESTONE.md
Docs/Architecture/CORE_ARCHITECTURE.md
Docs/Architecture/SERVICE_ARCHITECTURE.md
```

并新增/正式化：

```text
Docs/Architecture/COMBAT_ANALYTICS_ARCHITECTURE.md
```

## P2 — UI 实机

- 1024×768；
- 1920×1080；
- Scroll；
- Metric switching；
- A/B compare；
- Encounter History；
- Current Timeline；
- 长文本悬浮提示；
- 页面不裁切；
- 不新增无法拖动/无法关闭窗口。

## P3 — RU 数据准确性

- Song skill IDs；
- CC skill IDs；
- Utility skill IDs；
- Aura EventType；
- Native Spellcast 参数；
- Death source；
- Assist 推导窗口；
- Boss Mechanic IDs。

准确率优先，任何未知都应进入 provisional/inferred/coverage，而不是直接扔掉或装作确认。

---

# 17. 明确禁止的后续做法

恢复开发时不要：

1. 把 Kill/CC/Song/Aura 全塞回 `rs_dps_domain.lua`；
2. 每个 Metric 自己 `SetEventHandler(COMBAT_MSG)`；
3. 每个 Metric 各自 Acquire 一个 all-scope CombatEventBus；
4. 为 Combat Analytics 新增永久 Tick；
5. 为了“有控制时间”在没有 Apply/Remove 时自己猜持续时间；
6. 为了“有助攻”把推导 Assist 显示成服务器 Assist；
7. 用 `a and b or c` 模拟可能返回 false/nil 的 Lua 三元；
8. 在有界高频队列使用 `table.remove(1)`；
9. 用稀疏数组 `#table` 作为真实 count；
10. 在 CombatFact 事件中复杂遍历技能目录或 Boss 文本；
11. 因为 Analytics 页面隐藏就默认认为模块已关闭；
12. 因为关闭某一个 Metric 就清掉其它 Metric/DPS 的状态。

---

# 18. 下一阶段建议执行顺序

```text
1. 读取 Docs + 本交接 + 当前实际代码
2. 安装/找到 Lua syntax runtime
3. Events v3 Optional/Required Harness
4. 144 Active loadfile
5. Analytics Acceptance
6. FoundationGate v23
7. DPS Bridge lifecycle
8. Metric resource release stress
9. UI page static/layout acceptance
10. 更新 CURRENT/Architecture 权威文档
11. 打 M1.16.0 Final ModifiedFiles ZIP
12. ArcheRage RU 实机
13. 根据“待确认/coverage/evidence”继续校准 RU 事件
```

---

# 19. 当前快照结论

M1.16 的核心方向已经从：

```text
一个越来越大的 DPS 功能
```

转为：

```text
CombatEventBus
      ↓
CombatAnalytics Authority
      ↓
Independent Metric Modules
      ↓
Shared Projection / Drilldown UI
```

这符合 Replicated Suite 长期目标：

- 单入口；
- 模块化；
- 高性能；
- 按需加载；
- 可扩展；
- 统计证据可追踪；
- 不牺牲 DeathReview 等低成本功能；
- 不把所有战斗功能耦合成一个巨型 DPS 模块。

当前最重要的事情不是继续加入第 10、第 11 个 Metric，而是先把 M1.16.0 Foundation 最终门禁、文档 Authority 与 RU 实机证据收口。

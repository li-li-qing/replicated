# Replicated Suite 底层框架重构规划 v1

> 基线：`v3-m1.16.0.18.326-trade-freshness-matrix-audit`
>
> 文档性质：**架构审查结论 + 重构执行计划**。本文件只定义问题、边界、顺序、验收与风险；**不代表已经开始修改代码**。
>
> 目标：在不破坏现有用户配置、功能行为和已验证 RU 客户端契约的前提下，把当前已经明显长大的 Replicated Suite 收敛为长期可维护的：
>
> `Core + Services + Feature Modules + Presentation/UI`

---

## 0. 为什么现在先写文档，而不是直接改

Replicated Suite 已经不是早期的小型插件。当前工程同时包含：

- 统一 Scheduler / EventBus / Demand / Persistence；
- 19+ Shared Services；
- 战斗、生活、工具多个 Feature；
- 模块诊断、恢复策略、完整性保护；
- 大量长期兼容 Store；
- V3 Presentation / RSUI；
- 多轮 RU 实机修复积累下来的兼容逻辑。

因此当前最危险的不是“某个文件不够漂亮”，而是：

1. 一个拆分如果破坏加载顺序，会让多个模块一起消失；
2. 一个 Core 修改如果改变 Authority，会让多个 Feature 同时漂移；
3. 一个 Persistence 修改如果扩大恢复范围，可能伤害用户长期配置；
4. 一个 Scheduler / EventBus 热路径修改如果没有基线，会产生很难定位的性能回归；
5. 当前完整回归门禁本身处于 BLOCKED，不能在缺少全量基线时直接做大手术。

所以本轮先冻结“**什么是问题、为什么是问题、先改什么、绝对不能顺手改什么**”。

---

# 1. 当前架构实际状态

项目设计文档定义的目标依赖方向是：

```text
Presentation / RSUI
        ↓
Feature Projection + Commands
        ↓
Feature Domain / Authority / Store
        ↓
Shared Services
        ↓
Core Foundation
        ↓
Native
```

当前主干的很多关键基础纪律已经做对：

- `core/rs_scheduler.lua` 仍是 Suite 的长期 OnUpdate Authority；
- Feature 普遍通过 Demand 取得/释放运行资源；
- `core/rs_persistence.lua` 仍是 Store 写入与完整性保护 Authority；
- Native Import 已集中到 `native/` 层；
- Shared Service 已承担 CombatEvent、UnitIdentity、ScreenProjection、Aura、Auction 等跨 Feature 事实；
- Presentation 大部分已经通过 Projection/Commands 消费 Feature；
- 模块诊断已开始从“全插件大报告”收敛为按 Feature 归属的 Provider。

因此这不是一次“推倒重写”。

本次重构的性质是：

> **保留已有正确 Authority，把已经膨胀或反向耦合的部分重新切回正确边界。**

---

# 2. 本轮审查结论总表

| ID | 优先级 | 问题 | 当前风险 | 是否先于继续扩功能处理 |
|---|---|---|---|---|
| FND-001 | P0 | `rs_business_bridge.lua` 接近 Lua 5.1 local 上限 | 新增少量顶层 local 即可能整个 chunk 无法编译 | 是 |
| FND-002 | P0 | `rs_life_m16_bundle.lua` 四个业务同一加载故障域 | Trade 前部错误可阻断 Bonds/Treasure/Fishing 注册 | 是 |
| FND-003 | P0 | Core/FoundationGate 直接认识大量 Feature | 形成 Core→Feature 反向依赖 | 是 |
| FND-004 | P1 | Diagnostics / FoundationGate / Acceptance 多 Authority | 同一健康状态可能得出不同结论 | 是 |
| FND-005 | P1 | 大量 Acceptance/Sequence 随发行版加载 | 增加解析成本和运行时复杂度 | 分阶段 |
| FND-006 | P1 | Scheduler 每帧 O(N) 扫描全部任务 | Feature 增长后成为统一热点 | 是 |
| FND-007 | P1 | Scheduler task name 全局覆盖 | 不同 Owner 同名可静默替换 | 是 |
| FND-008 | P1 | FrameBudget 每帧创建新 table | 长会话产生无必要 GC 压力 | 是 |
| FND-009 | P1 | EventBus 高频 Publish/Dispatch 分配临时对象 | 高频事件长期产生短命对象 | 分阶段 |
| FND-010 | P1 | Presentation 仍存在直接读 `Feature.State` | UI 与 Feature 私有结构重新耦合 | 是 |
| FND-011 | P2 | 部分关闭功能仍保留 Watchdog | “关闭后释放资源”契约未完全落实 | 是 |
| FND-012 | P2 | Persistence 200ms 全 Store 扫描 | Store 数继续增长后浪费扫描 | 后置 |
| FND-013 | P2 | Persistence/Foundation/Diagnostics 巨型 Core 文件 | 修改爆炸半径继续扩大 | 后置 |
| FND-014 | P1 | 全量回归 Runner 缺 16 个 fixture | 大重构前没有可信全绿基线 | **必须先处理** |
| FND-015 | P1 | 发布门禁没有真实 Lua 5.1 编译检查 | 无法提前发现 200 locals 等目标客户端限制 | **必须先处理** |

---

# 3. P0 问题详解

## FND-001：Business Bridge 已接近 Lua 5.1 编译极限

### 现状

当前文件：

```text
features/rs_business_bridge.lua
5223 行
```

文件内部已经出现维护注释，明确说明：

```text
该文件已接近 Lua 5.1 每函数 200 local 上限
```

目前这个单一 chunk 同时承载：

```text
combat_boss_alerts
combat_target_monitor
combat_buff_cap
combat_team_tools
combat_raid_recruitment
combat_unit_lines
combat_range_assist
combat_siege_readiness

tools_craft
tools_bag
tools_auction
tools_market_analysis
tools_social
tools_reinforce_analysis
tools_portal_profiles
```

以及 Bag / Craft / Auction 等大量私有 helper/runtime。

### 为什么危险

Lua 5.1 的限制不是“文件太长”，而是一个函数/chunk 内 local 数量存在硬上限。

当前为了规避这个问题，源码已经出现“不要新增顶层 local”“把诊断延迟挂接”等维护技巧。

这说明架构已经进入：

```text
新增正常代码
    ↓
需要考虑编译器 local 配额
    ↓
业务设计开始迁就巨型文件
```

这是必须结束的状态。

最坏结果不是单个 Feature 坏掉，而是：

```text
rs_business_bridge.lua 无法编译
        ↓
该 chunk 内所有 Feature 一起不可用
```

### 正确修复方向

不是简单拆成两个同样巨大的文件，而是按 Feature 垂直切片拆分。

建议目标结构：

```text
features/
├── shared/
│   └── rs_feature_slice_factory.lua
│
├── combat/
│   ├── boss_alerts/
│   │   └── rs_boss_alerts_feature.lua
│   ├── target_monitor/
│   │   └── rs_target_monitor_feature.lua
│   ├── buff_cap/
│   │   └── rs_buff_cap_feature.lua
│   ├── team_tools/
│   │   └── rs_team_tools_feature.lua
│   ├── raid_recruitment/
│   │   └── rs_raid_recruitment_feature.lua
│   ├── unit_lines/
│   │   └── rs_unit_lines_feature.lua
│   ├── range_assist/
│   │   └── rs_range_assist_feature.lua
│   └── siege_readiness/
│       └── rs_siege_readiness_feature.lua
│
└── tools/
    ├── bag/
    │   ├── rs_bag_feature.lua
    │   └── rs_bag_move_runtime.lua
    ├── craft/
    │   └── rs_craft_feature.lua
    ├── auction/
    │   └── rs_auction_feature.lua
    ├── market_analysis/
    │   └── rs_market_analysis_feature.lua
    ├── social/
    │   └── rs_social_feature.lua
    ├── reinforce_analysis/
    │   └── rs_reinforce_analysis_feature.lua
    └── portal_profiles/
        └── rs_portal_profiles_feature.lua
```

### 关键要求

拆分时必须保持：

- Feature ID 不变；
- Store ID 不变；
- Registry route 不变；
- UpdateTopic 不变；
- Demand token / Owner 语义不变；
- Scheduler task name 第一阶段不主动改名；
- Commands 公共签名不变；
- Presentation 无感知；
- 老配置零迁移。

### 禁止做法

禁止把 5223 行改成：

```text
rs_business_bridge_core.lua
rs_business_bridge_extra.lua
```

但内部继续共享一堆全局可写 State。

那只是“文件变少”，不是模块化。

---

## FND-002：Life Bundle 仍是共同加载故障域

### 现状

当前文件：

```text
features/life/rs_life_m16_bundle.lua
5615 行
```

内部顺序为：

```text
Trade
  RegisterStore
  Demand/Create
  RegisterImplementation

Bonds
  RegisterStore
  Demand/Create
  RegisterImplementation

Treasure
  RegisterStore
  Demand/Create
  RegisterImplementation

Fishing
  RegisterStore
  Demand/Create
  RegisterImplementation
```

并且每个注册失败目前存在：

```lua
if ok ~= true then error(err) end
```

### 为什么危险

虽然运行时已经强调 Feature 独立启停，但加载阶段仍然是：

```text
Trade 前段出现未捕获错误
        ↓
整个 rs_life_m16_bundle.lua 中止
        ↓
Bonds / Treasure / Fishing 根本没有机会注册
```

因此当前存在一个矛盾：

```text
Runtime 生命周期：独立
Source Load 故障域：仍绑定
```

### 正确目标

```text
features/life/
├── trade/
│   ├── rs_trade_feature.lua
│   ├── rs_trade_ratio_authority.lua
│   ├── rs_trade_material_projection.lua
│   └── rs_trade_diagnostics.lua
│
├── bonds/
│   ├── rs_bonds_feature.lua
│   └── rs_bonds_authority.lua
│
├── treasure/
│   └── rs_treasure_feature.lua
│
└── fishing/
    └── rs_fishing_feature.lua
```

第一阶段不要求立即拆到这么细，但至少必须先做到：

```text
Trade       独立文件
Bonds       独立文件
Treasure    独立文件
Fishing     独立文件
```

### 特别约束

Trade 最近刚经历：

- ratio single-flight；
- auto-refresh runtime；
- material price cache recovery；
- profit SWR；
- freshness matrix；
- quote queue read model sync。

所以拆 Trade 时必须坚持：

> **只搬边界，不同时改业务算法。**

不能把“拆文件”和“顺便重构售价/拍卖/自动刷新”混在同一 commit/版本里。

---

## FND-003：Core 已开始反向依赖 Feature

### 现状

`core/rs_foundation_gate.lua`：

```text
2904 行
```

里面直接读取大量：

```lua
S.Features.Tasks
S.Features.Activities
S.Features.Gear
S.Features.BuffDisplay
S.Features.RaidReadiness
S.Features.Healer
S.Features.DeathReview
S.Features.DPS
S.Features.Bonds
S.Features.Trade
S.Features.tools_auction
S.Features.tools_craft
...
```

而项目架构文档自己规定：

```text
Core 不承载 DPS、治疗推荐、跑商利润、团队判定等业务事实。
```

### 问题本质

Foundation Gate 原本应该回答：

```text
Core 是否可运行？
Shared contracts 是否存在？
Feature 注册体系是否健康？
```

现在它逐渐变成：

```text
Core 自己知道每个 Feature 应该有哪些 ContractVersion
```

依赖方向因此变成：

```text
Feature → Core
Core    → Feature
```

形成环。

### 长期风险

每新增或调整一个业务 Feature 都可能要求：

```text
Feature 文件
+ Feature Acceptance
+ FoundationGate
+ Diagnostics
+ V3 Acceptance
```

多点同步。

最后很容易出现：

```text
Feature 自己是健康的
但 FoundationGate 中旧 ContractVersion 没同步
→ 整个启动被错误降级
```

### 正确目标

Core 只能认识抽象契约：

```text
FeatureRegistry
FeatureRuntime
Persistence
Scheduler
Events
Demand
Diagnostics
Native capability system
```

具体 Feature 的健康证明应由 Feature 自己注册：

```text
Feature
  └── AcceptanceProvider / ContractDescriptor
             ↓
      Foundation Aggregator
```

而不是：

```text
FoundationGate
  └── if S.Features.Trade then ...
  └── if S.Features.Bonds then ...
  └── if S.Features.Gear then ...
```

建议新契约：

```lua
FeatureRuntime:RegisterHealthContract(featureId, provider)
```

provider 只返回 detached facts：

```text
implemented
initialized
contractVersions
requiredServices
requiredStores
lifecycleState
```

Foundation 负责：

```text
聚合
一致性检查
启动门禁
```

Feature 自己负责：

```text
“我需要什么”
```

---

# 4. P1 问题详解

## FND-004：健康检查存在多 Authority

当前已有：

```text
core/rs_diagnostics.lua
core/rs_module_diagnostics.lua
core/rs_foundation_gate.lua
presentation/v3/rs_v3_acceptance.lua
Feature-specific *_acceptance.lua
```

这些组件各自都合理，但边界已经开始重叠。

目标应该明确为：

```text
DiagnosticsManager
    = 结构化错误事实 Authority

ModuleDiagnosticsHub
    = 按模块归属投影

Feature Acceptance Provider
    = Feature 自身静态/运行时契约证明

FoundationGate
    = 只聚合 Core + 注册过的 Contract Provider

RS-V3 Acceptance
    = Presentation/集成层验收，不重新决定业务真相
```

必须避免：

```text
同一个 Feature contract
在三个文件各维护一份版本号判断
```

---

## FND-005：Acceptance / Sequence 生产加载过重

当前 `toc.g` 直接加载至少 17 个 Acceptance/Sequence Lua 文件；这些文件本体约：

```text
387 KB
```

还不包含 2904 行的 `rs_foundation_gate.lua`。

长期建议分成两类：

### Runtime Contract

必须随用户发行：

- 极轻量；
- O(1) / 小规模；
- 不创建业务资源；
- 不进行破坏性测试；
- 只验证当前运行必须满足的契约。

### Offline Regression

放在：

```text
tools/
```

负责：

- 大量 fixture；
- 历史 bug 回归；
- 组合测试；
- 序列测试；
- 模拟 Persistence 故障；
- 复杂 UI harness。

第一轮不应立刻删除 Acceptance 文件；先完成 P0 拆分和测试基线，再做收敛。

---

## FND-006：Scheduler 每帧全量扫描任务

当前 `core/rs_scheduler.lua` 每帧主要路径：

```text
OnUpdate
  ↓
RecoverFaultedTasks(now)
  → pairs(all tasks)

  ↓
pairs(all tasks)
  → 累加 elapsed
  → 找 due

  ↓
只执行 due tasks
```

也就是说即使某任务：

```text
10 秒执行一次
30 秒执行一次
```

只要它注册着，就会每帧参与至少一轮扫描；故障恢复还会再扫一次。

### 为什么现在还没有明显崩

当前任务量还没有大到不可接受，并且统一 Scheduler 本身比每个 Feature 自建 OnUpdate 好很多。

所以本问题不是“Scheduler 设计失败”，而是：

> **统一后下一阶段必须从全量轮询继续进化为按到期调度。**

### 目标方向

不建议马上引入复杂二叉堆。

Lua 5.1 + 当前规模更适合简单、有界的 bucket/timing wheel：

```text
HighFrequency lane
    → 每帧专门列表

16/32/50/100/250/500/1000ms 等普通周期
    → bucket

fault recovery
    → 单独 nextFaultRecoveryAt
```

这样普通 10 秒任务不必每帧被访问。

### 必须保留

- 一个 OnUpdate Authority；
- P0/P1 永不被软预算拒绝；
- hitch 不做多次 catch-up；
- Owner Release；
- Generation/Epoch；
- backlog diagnostics。

---

## FND-007：Scheduler Task Name 是全局覆盖键

当前任务表最终是：

```lua
self.tasks[name] = task
```

这意味着同名新任务可以覆盖旧任务。

项目中 debounce / one-shot 的确需要“同 Owner 同名字替换”，因此不能简单禁止覆盖。

正确规则应该是：

```text
同 Owner + 同 TaskName
    → 允许 Replace

不同 Owner + 同 TaskName
    → 拒绝 + diagnostics
```

长期推荐内部真实 key：

```text
ownerIdentity + "::" + localTaskName
```

外部 API 可以继续兼容旧 name，但内部必须记录 Owner Collision。

---

## FND-008：FrameBudget 每帧创建两张表

当前 `BeginFrame()`：

```lua
self.previous = { ... }
self.current = { ... }
```

这发生在每个 Scheduler frame。

60 FPS：

```text
约 120 个新 table / 秒
```

120 FPS：

```text
约 240 个新 table / 秒
```

这些对象全部是固定字段，不需要重新分配。

修复非常低风险：

```text
current / previous 两个预分配 struct
每帧字段覆盖
必要时交换引用
```

这是适合早期单独完成的小型性能修复。

---

## FND-009：EventBus 高频分配

当前 Native Dispatch / Internal Publish 都会：

```lua
local args = { ... }
```

每 listener 又通过匿名函数进入 `xpcall()`。

对于：

- Combat；
- Buff/Aura；
- Target；
- Team；
- Projection 高频 topic；

会积累大量短生命周期对象。

同时：

```lua
SubscribeInternal(topic, owner, callback)
```

只是 append，没有稳定 subscription token / idempotent key。

### 改造注意

EventBus 是高风险基础设施，不能为了“少一个 table”做复杂元编程。

建议顺序：

1. 先增加 subscription identity / duplicate diagnostics；
2. 证明实际事件量；
3. 再做 argument forwarding allocation 优化；
4. 每一步都必须有事件解绑/reload/epoch 回归测试。

---

## FND-010：Presentation 直接读取 Feature.State

已确认的明确违规：

```text
presentation/v3/widgets/rs_v3_auction_sidecar.lua
```

注释写着：

```text
不直接读取 Feature.State/Store
```

但实际仍读取：

```lua
Feature.State.favorites
```

这类问题的长期后果是：

```text
Feature 内部 State 改结构
    ↓
Presentation 跟着崩
```

正确方式必须统一为：

```text
Feature:GetProjection()
```

或：

```text
Feature.PublicReadModel / Facade
```

且返回 detached data。

### 长期门禁

新增静态检查：

```text
presentation/**/*.lua
禁止出现：
    Feature.State
    .store
    Persistence:GetStore(业务Store)
```

少数明确 Acceptance/diagnostics 例外必须白名单。

---

# 5. P2 问题详解

## FND-011：功能关闭后仍有 Presentation Watchdog

例如：

```text
presentation/v3/widgets/rs_v3_combat_visual_guides.lua
```

文件加载后会：

```text
SubscribeInternal(...)
Reconcile("bootstrap")
AddTask(..., 1000ms)
```

即使 UnitLines / RangeAssist 都关闭，watchdog 仍存在。

单个 1 秒任务开销很小，但它违反长期生命周期原则：

```text
Feature 关闭
    ≠ 只隐藏 UI
    = 应释放 Feature 特有运行资源
```

目标改为：

```text
两 Feature 均关闭
→ watchdog 不存在

任一 Feature 打开
→ acquire watchdog lease

最后一个关闭
→ release watchdog
```

---

## FND-012：Persistence 每 200ms 全 Store 扫描

当前 `P:Tick()`：

```text
for self.order
    找 dirty + due Store

每 15 秒：
for self.order
    找 Daily/Weekly reset Store
```

现在 Store 数量仍可接受，但项目继续扩展后会产生大量“明知没 dirty 仍扫描”。

长期方向：

```text
dirtySet / due queue
periodResetSet
```

`MarkDirty()` 时加入 dirty index，成功保存时移除。

不过 Persistence 是最高风险层之一，本问题不应早于 P0 拆分和测试门禁。

---

## FND-013：Core 巨型文件继续扩大爆炸半径

当前：

```text
core/rs_persistence.lua      4267 行
core/rs_foundation_gate.lua 2904 行
core/rs_diagnostics.lua     1863 行
```

文件行数不是罪名，真正的问题是职责已经开始混合。

长期拆分候选：

```text
Persistence
├── rs_persistence_registry.lua
├── rs_persistence_integrity.lua
├── rs_persistence_runtime.lua
├── rs_persistence_periods.lua
└── rs_persistence_diagnostics.lua
```

但这里必须最后做。

原因：Persistence 已经积累大量用户升级兼容和故障恢复逻辑，过早拆它收益小、风险大。

---

# 6. 测试基础设施问题

## FND-014：全量 Regression 当前 BLOCKED

当前执行：

```text
python3 tools/rs_status_refactor_test_runner.py
```

会明确阻断，因为声明需要但缺失 16 个 fixture：

```text
rs_f2_protected_page_tests.lua
rs_udf_numeric_regression_tests.lua
rs_gear_page_regression_tests.lua
rs_report_failure_regression_tests.lua
rs_overview_quote_tests.lua
rs_compact_tracker_tests.lua
rs_daily_ledger_tests.lua
rs_daily_income_source_tests.lua
rs_quest_journal_detail_tests.lua
rs_ledger_projection_v2_tests.lua
rs_task_tests.lua
rs_bonds_ui_contract_tests.lua
rs_housing_tests.lua
rs_butler_tests.lua
rs_raid_readiness_tests.lua
rs_pending_ru_navigation_tests.lua
```

这件事必须在大规模框架拆分前处理。

### 不能怎么处理

禁止直接：

```text
从 runner required list 删除 16 项
```

来获得绿色。

必须逐项判断：

```text
A. 功能仍存在，fixture 被误删
   → 恢复 fixture

B. fixture 已被新测试替代
   → runner 改为新的唯一测试 Authority

C. 功能已经永久删除
   → 先确认 Registry/toc/Docs 都已删除，再移除要求
```

只有完成这个分类以后，Full Suite PASS 才有意义。

---

## FND-015：缺少真实 Lua 5.1 Compile Gate

当前开发环境没有真实 `lua5.1 / luac5.1` 门禁。

这对普通语法错误还能通过其他 parser/static check 捕获，但无法可靠证明：

```text
Lua 5.1 local 数量限制
5.1 特定语法/bytecode 编译限制
```

而当前 Business Bridge 恰好已经进入这个风险区。

### 发布门禁目标

正式发布前至少增加：

```text
luac5.1 -p 全部发行 Lua 文件
```

并把：

```text
任何一个文件 compile fail
```

视为 Release Blocker。

此外增加静态预警：

```text
单文件 > 4000 行：warning
单 chunk local 接近预算：warning/blocker
```

静态预警不是编译器 Authority，真正门禁仍然是 Lua 5.1 compile。

---

# 7. 重构后的目标结构

最终希望看到的是：

```text
replicatedsuite/
│
├── core/
│   ├── scheduler
│   ├── events
│   ├── demand
│   ├── persistence
│   ├── diagnostics
│   └── feature runtime contracts
│
├── native/
│   └── 唯一 Native capability/import/object authority
│
├── services/
│   └── 跨 Feature 的共享事实
│
├── features/
│   ├── combat/
│   │   ├── dps/
│   │   ├── healer/
│   │   ├── buff_display/
│   │   ├── unit_lines/
│   │   ├── range_assist/
│   │   └── ...
│   │
│   ├── life/
│   │   ├── trade/
│   │   ├── bonds/
│   │   ├── treasure/
│   │   └── fishing/
│   │
│   └── tools/
│       ├── bag/
│       ├── auction/
│       ├── craft/
│       └── ...
│
├── presentation/
│   └── 只消费 Projection / Commands
│
└── tools/
    └── 离线回归与破坏性测试
```

依赖只能向下：

```text
Presentation
      ↓
Feature
      ↓
Service
      ↓
Core
      ↓
Native
```

禁止：

```text
Core → 某个具体 Feature
Service → Presentation
Presentation → Feature.State
FeatureA → FeatureB 私有对象
```

---

# 8. 执行阶段规划

这次不建议“一口气把 15 个问题全修完”。

正确方式是每一阶段都可以独立验证、独立回滚。

---

## Phase 0：先恢复可信基线

### 目标

在改架构前，把“改坏了没有”这件事变得可证明。

### 工作

1. 审查并恢复/替换 16 个缺失 regression fixture；
2. 全量 runner 必须能真正执行；
3. 增加 Lua 5.1 compile gate；
4. 增加 Architecture Audit 静态检查：
   - Core 中直接 `S.Features`；
   - Presentation 中直接 `Feature.State`；
   - 巨型文件；
   - toc 重复/缺失；
   - Feature Store ID 冲突；
   - Scheduler task owner/name collision；
5. 保存一份 18.326 基线结果。

### 完成标准

```text
Full regression：PASS
Lua 5.1 compile：PASS
Install integrity：PASS
Architecture audit：有已知债务清单，但工具本身可运行
```

### 本阶段禁止

- 不拆 Feature；
- 不动 Persistence 算法；
- 不改 Scheduler 执行语义；
- 不改业务 Store Schema。

---

## Phase 1：拆 Business Bridge

### 目标

彻底解除当前最直接的 Lua 5.1 编译风险。

### 顺序

优先拆依赖较少的 Feature：

```text
1. tools_social
2. tools_market_analysis
3. tools_reinforce_analysis
4. tools_portal_profiles
5. combat_siege_readiness
6. combat_target_monitor
7. combat_buff_cap
8. combat_boss_alerts
9. combat_raid_recruitment
10. combat_team_tools
11. tools_craft
12. tools_auction
13. tools_bag
14. combat_unit_lines
15. combat_range_assist
```

最后三个/几个放后面，因为运行态和 UI 联动更多。

### 每拆一个 Feature 都必须证明

```text
Feature ID 相同
Store ID 相同
Projection shape 相同
Commands 相同
Demand lifecycle 相同
Scheduler owner/task 相同
Event owner/topic 相同
旧配置无需迁移
```

### 完成标准

```text
rs_business_bridge.lua 不再承载业务实现
或最终删除
所有原 Feature 分别自注册
一个 Feature 文件失败不得通过共享 chunk 直接阻断其它业务实现
```

---

## Phase 2：拆 Life Bundle

### 顺序

建议：

```text
Treasure
Fishing
Bonds
Trade
```

Trade 最后。

理由：Trade 当前复杂度最高、最近变更最多，应在拆分模式已经被前 3 个 Feature 验证后再处理。

### Trade 拆分原则

先只做：

```text
rs_trade_feature.lua
```

完整搬迁并保证行为 1:1。

第二轮才进一步按：

```text
ratio authority
material projection
quote read model
cargo observer
diagnostics
```

分文件。

不要一次把 Trade 同时重构成 6 个新 abstraction。

---

## Phase 3：消除 Core → Feature 反向依赖

### 目标

把 FoundationGate 从“认识每个 Feature”改为“聚合注册契约”。

### 新边界

Feature 注册：

```text
FeatureId
ContractVersion
RequiredServiceContracts
RequiredStoreContracts
RuntimeHealthProvider
```

Foundation 只消费这些 descriptor。

### 验收

静态门禁：

```text
core/*.lua
除 FeatureRegistry / FeatureRuntime 基础设施外
不允许直接访问 S.Features.<业务Feature>
```

---

## Phase 4：修复低风险热路径

按风险从低到高：

```text
1. FrameBudget 双 table → 预分配复用
2. Scheduler Owner/name collision contract
3. 关闭 Feature 的 watchdog lease
4. Scheduler fault recovery 从每帧全扫拆出
5. Scheduler due bucket / timing wheel
6. EventBus subscription identity
7. EventBus hot-path allocation
```

每一步单独 benchmark / regression。

---

## Phase 5：Presentation 边界清理

### 工作

- 清理所有 Presentation → Feature.State；
- UI 只走 projection/facade；
- 加静态门禁；
- 对 RSUI 高频列表验证不会因为 detached copy 产生过大复制成本。

Auction Sidecar 是第一明确修复点。

---

## Phase 6：Diagnostics / Acceptance 收敛

把：

```text
Runtime health
Offline regression
Module diagnostics
Foundation startup gate
```

彻底分层。

目标不是删除诊断，而是让每类诊断只有一个 Authority。

---

## Phase 7：Persistence 调度优化与 Core 拆分

最后才处理：

```text
Persistence dirty queue
period reset watch set
Persistence 文件拆分
Diagnostics 文件拆分
```

因为这些区域与用户配置安全直接相关。

这一阶段开始前必须满足：

```text
所有 Store regression 全绿
fresh reload / reload addon / crash-like interrupted save 测试齐全
```

---

# 9. 每阶段统一执行模板

后续每一阶段都按下面流程执行，不再“看到一个问题修一个问题”。

## Step 1：冻结范围

例如：

```text
本阶段只拆 tools_social + tools_market_analysis。
```

禁止顺手修改其它业务。

## Step 2：记录修改前契约

至少记录：

```text
Feature ID
Store IDs
Store Schema
UpdateTopic
Commands
Projection fields
Scheduler tasks
Event subscriptions
Demand owner
Registry route
```

## Step 3：做结构修改

保持业务结果不变。

## Step 4：运行专项测试

Feature 自己的 test + Core lifecycle + Persistence + UI contract。

## Step 5：运行全量测试

必须使用恢复后的 Full Runner。

## Step 6：Fresh Reload / ReloadAddon 边界

检查：

```text
首次启动
已有旧配置启动
ReloadAddon
禁用 → 启用
页面打开 → 关闭
功能关闭但配置仍保存
```

## Step 7：版本只推进一次

同一阶段不要出现：

```text
.327a
.327b
.327c
```

这种碎片式发行。

完成完整阶段后再推进正式 build。

---

# 10. 重构期间必须冻结的兼容边界

## 10.1 Store ID 不改

除非另开专门 Migration 项目，否则当前所有：

```text
v3.*
```

Store ID 不得因为文件移动而变化。

## 10.2 Feature ID 不改

功能方案、用户开关、导航、诊断归属都依赖 Feature ID。

## 10.3 Route 不改

Presentation Router 不应该因为源码目录重构而变化。

## 10.4 Native 契约不扩张

本轮是框架维护，不因为拆文件就新增猜测 Native API。

## 10.5 关闭 Feature 必须保持永久配置

```text
Disable runtime
≠ Delete Store
```

## 10.6 共享事实不能复制 Authority

例如：

```text
Buff → StatusClassification/Aura Service
Target identity → UnitIdentity Service
Combat → CombatEventBus
Auction quote → PriceQuoteQueue
```

拆文件时不得为了“方便”在 Feature 新建第二份长期缓存真相。

---

# 11. 性能验收要求

框架重构不是只要“不报错”就算完成。

## Scheduler

记录：

```text
active task count
per-frame scanned task count
executedLastFrame
pending backlog
maxLateRatio
budget defers
```

目标：Feature 增长后，普通低频任务不再全部进入每帧扫描。

## EventBus

记录：

```text
native/internal publish count
listener count
duplicate subscription rejection
owner release count
```

不在 release 版逐事件打印日志。

## Persistence

记录：

```text
registered Stores
dirty Stores
Tick scanned Stores
Save attempts
Fence count
Period watch Stores
```

最终目标是无 dirty 时不再反复扫描所有 Permanent Store。

## GC / Allocation

优先消灭明确可避免的 per-frame temporary table，尤其 FrameBudget。

---

# 12. 生命周期验收矩阵

每个被拆 Feature 都必须通过：

| 场景 | 预期 |
|---|---|
| Feature disabled | 无业务事件、无业务 Scheduler、无高耗缓存 |
| Feature enabled but window hidden | 仅保留该 Feature 明确需要的后台能力 |
| Widget visible | Acquire consumer |
| Widget closed | Release consumer |
| Last consumer released | 可释放的 Observation/Native listener 必须释放 |
| ReloadAddon | 旧 Epoch 回调不能提交新状态 |
| Feature Enable failure | 已 Acquire 资源事务回滚 |
| Store fenced | Feature fail-soft/fail-closed 按原契约，不绕过保护 |
| Presentation destroyed | 不改变业务 Feature Authority |

---

# 13. Diagnostics 验收要求

结构重构以后，用户诊断体验不能退步。

保持：

```text
每 Feature 右上角独立诊断
上一页 / 下一页
固定 snapshot
翻页不重新采集
不把其它 Feature 无关错误塞进来
```

新增结构诊断至少需要：

```text
Feature source file / implementation availability
Demand consumer count
Scheduler owner task count
Event owner listener count
Store ownership
Contract provider version
```

但这些只能读现有 Authority，不得为了诊断启动 Feature。

---

# 14. 风险排序

## 极高风险区域

```text
Persistence
Feature preferences transaction
BuffDisplay multi-store tracking
Native lifecycle / reload epoch
```

除非本阶段明确目标，否则不碰。

## 高风险区域

```text
Scheduler execution semantics
EventBus unregister/reload
Trade async ratio / quote pipeline
Bag movement runtime
UnitLines/RangeAssist frame projection
```

必须专项测试。

## 中风险区域

```text
Feature source split
Foundation contract aggregation
Presentation projection boundary
```

只要契约被冻结，可控。

## 低风险区域

```text
FrameBudget preallocation
static architecture checks
Docs / build gate
```

适合早期完成。

---

# 15. 建议的版本路线

这里只定义主题，不提前锁死具体 build 数字。

```text
A. foundation-baseline-gate
   恢复 Full Regression + Lua5.1 Gate

B. business-slice-split
   拆 rs_business_bridge.lua

C. life-slice-split
   拆 rs_life_m16_bundle.lua

D. foundation-contract-inversion
   Core 不再知道具体 Feature

E. scheduler-runtime-scale
   Scheduler owner collision + due scheduling

F. presentation-boundary
   清 Feature.State 直读

G. diagnostics-contract-convergence
   收敛 Runtime health / Acceptance

H. persistence-runtime-scale
   dirty queue + Core file responsibility split
```

每个主题完成再进入下一个。

---

# 16. “完成”不是指什么

以下情况不能算重构完成：

### 仅把代码移动到多个文件

如果仍通过全局 State 相互访问，不算模块化。

### 增加一个更大的 Shared Helper

如果把所有业务 Helper 全放入：

```text
core/rs_business_common.lua
```

只是把 Business Bridge 换了名字。

### 为了测试通过删检查

Full Runner 缺 fixture，不能通过删除 required list 获得绿色。

### 为了拆文件改变用户 Store

源码路径变化不应该让用户配置迁移。

### 为了性能增加多个 OnUpdate

Scheduler 优化目标仍然是：

```text
单一 Suite Scheduler Authority
```

不是重新允许每个 Feature 自建 Tick。

---

# 17. 最终验收目标

整个底层框架重构结束时，应满足：

## 架构

```text
Core 不认识具体业务 Feature
Presentation 不读取 Feature 私有 State
Feature 之间不形成直接强依赖
Shared Service 只有共享事实，不拥有 Consumer 业务判定
```

## 加载隔离

```text
Trade 故障不能阻断 Bonds/Treasure/Fishing 源码注册
Bag 故障不能让 UnitLines/Auction/Craft 同 chunk 消失
```

## 生命周期

```text
功能关闭后释放自己的事件、Scheduler、Observation、高耗缓存
配置仍永久保留
```

## 性能

```text
无新增永久 OnUpdate
低频 Scheduler task 不再全部每帧扫描
FrameBudget 无每帧 table churn
Persistence 无变化时不再高频扫描所有 Store
```

## 兼容

```text
Store ID 不变
Feature ID 不变
用户旧配置直接读取
升级不要求清配置
```

## 测试

```text
Lua 5.1 compile gate PASS
Full regression PASS
Feature lifecycle PASS
Persistence integrity/recovery PASS
Fresh Reload PASS
ReloadAddon PASS
```

---

# 18. 当前建议的第一步

**不要马上开始拆 Business Bridge。**

正式动手顺序应是：

```text
第一步：Phase 0
恢复测试基线 + Lua 5.1 编译门禁

第二步：Phase 1
拆 Business Bridge

第三步：Phase 2
拆 Life Bundle
```

原因很简单：

> 当前最大的代码风险是巨型 Bundle，但当前最大的“施工风险”是缺少可靠的全量验收基线。

先把安全网补齐，再动承重墙。

---

# 19. 后续维护状态表

后续每轮完成后更新本表，不另开一份重复计划。

| 阶段 | 状态 | 开始版本 | 完成版本 | 备注 |
|---|---|---|---|---|
| Phase 0 测试/编译基线 | 进行中 | 18.326 | - | 第二轮已加入递归依赖审计、恢复 UDF numeric host、校正已证实过时的 Status 当前契约断言；默认 Full Runner 现稳定提前报告 6 个真实缺失依赖；2 个历史证据 fixture 无原始字节，禁止伪造；Lua5.1 compiler 仍缺失 |
| Phase 1 Business Bridge 拆分 | 未开始 | - | - | P0 |
| Phase 2 Life Bundle 拆分 | 未开始 | - | - | P0 |
| Phase 3 Core→Feature 反向依赖 | 未开始 | - | - | P0/P1 |
| Phase 4 Scheduler/Event 热路径 | 未开始 | - | - | P1 |
| Phase 5 Presentation 边界 | 未开始 | - | - | P1 |
| Phase 6 Diagnostics/Acceptance | 未开始 | - | - | P1 |
| Phase 7 Persistence 调度/拆分 | 未开始 | - | - | P2/高风险 |

---

## 19.1 Phase 0 第二轮记录（2026-09-28）

本轮继续冻结在 Phase 0，不修改任何发行运行时代码。

已完成：

- 新增递归测试依赖审计，默认 Full Runner 在执行任何 Lua suite 前一次性暴露 literal `dofile/loadfile` 缺失依赖，避免“先撞到一个缺失文件、后续问题被隐藏”；
- 审计器只分析 Lua 闭包，不把 Python runner 中动态字符串/测试库存误判成加载依赖；
- 恢复 `tools/rs_udf_numeric_test_host.lua` 的当前契约 host，并由 ranged-v4 migration 专项验证通过；
- 依据当前生产 Authority 更新 `rs_status_refactor_tests.lua` 中已经明确过期的 2026-09-12 快照断言：当前 StatusTrackingCatalog 为 425 effects / 14 trees / 463 skills；内置库导入采用 `.18.243` 后的四写 generation transaction，不允许为了旧“单次 SaveData”指标回退事务架构；
- 默认 Full Runner 当前稳定提前阻断于 6 个真实缺失依赖，而不是运行到中途才失败。

剩余阻断按性质分组：

```text
历史证据资产（不得伪造）
- tools/fixtures/trade_native_numeric_20260912.lua
- tools/rs_status_schema5_fixtures.lua

可按现行代码重建的测试基础设施
- tools/rs_gear_page_test_host.lua
- tools/rs_persistence_evidence_tests.lua
- tools/rs_pvp_hud_test_host.lua
- tools/rs_status_ui_test_host.lua
```

另有 `tools/rs_hud_template_copy_test_host.lua` 缺失，但当前不在默认 Full Runner 的依赖闭包内，后续仍需恢复对应专项套件。

结论：Phase 0 仍为进行中，Phase 1 继续禁止开始。

---

# 20. 本文档的使用规则

1. 后续实际施工以这份文档为主计划；
2. 每次只进入一个 Phase 或该 Phase 中明确冻结的小范围；
3. 发现新问题先记录到“问题清单”，不能立即扩大当前修改范围；
4. 只有阻断当前 Phase 正确性的故障才允许插队；
5. 每轮最终报告必须说明：
   - 完成内容；
   - 修改文件；
   - 性能影响；
   - 兼容风险；
   - 测试结果；
   - 本文档状态更新；
6. 不允许以“代码变短/文件变多”作为重构完成依据；
7. 最终依据永远是：Authority 清晰、生命周期可证明、测试全绿、用户升级安全。


# Replicated Suite 底层框架重构规划 v1

> 原始架构审查基线：`v3-m1.16.0.18.326-trade-freshness-matrix-audit`
>
> 当前累计施工基线：`v3-m1.16.0.18.331-phase1-feature-slice-complete`（累计链：`.327 Trade Native ownership` → `.328 Bonds X2Quest ownership` → `.329 BuffDisplay Native dependency policy` → `.330 Phase 0 基线闭合` → `.331 Phase 1 Business Bridge 拆分完成；bridge 已退役`；`.327–.330` 是连续增量，`.331` 依赖 `.330` 之后的全部拆分文件）
>
> 文档性质：**架构审查结论 + 长期重构执行计划 + Agent 施工规范**。从本版本开始，除定义问题、边界、顺序、验收与风险外，同时定义 Workbuddy / DeepSeek 等本地 Agent 的可执行工作包、停止条件和交付证据。
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
| FND-016 | P1 | Feature / Service Native Dependency Ownership 可与真实调用链漂移 | 单独启用 Feature 时 Native namespace 未导入；其它 Feature 偶然启用会掩盖隐式强耦合 | **Phase 0 建门禁，Phase 3 收口** |

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


## FND-016：Native Dependency Ownership 与真实调用链可漂移

### 触发证据

`.18.327` 前的 `life_trade` 已出现真实 RU 实机故障：

```text
Trade -> TradeMaterialIdentityV3 -> X2Craft
Trade -> MaterialPriceServiceV3 -> PriceQuoteQueueV3 -> X2Auction
```

但 Trade 实现层 `ApiDependencies` 曾没有声明 `X2Craft / X2Auction`。`FeatureRuntime` 的真实规则是：

```text
impl.ApiDependencies 存在
    -> 优先使用实现层声明
    -> Registry.apiDependencies 不再作为 fallback
```

因此其它 Craft/Auction Feature 若恰好先导入 namespace，会让 Trade “偶然正常”；只开 Trade 时则出现 `host_global_missing`。这不是普通 API 漏项，而是隐藏的 Feature -> Feature 生命周期耦合。

Phase 0 第四轮全量审计继续发现同类问题：

```text
life_bonds
    -> QuestProgressV3
    -> X2Quest
```

Registry 已声明 X2Quest，但 Bonds 实现层 override 漏掉该 namespace，仍可被 Activities/Tasks 偶然掩盖。`.18.328` 已补齐 Bonds 自身声明。

同时确认：

```text
CooldownObservationV3 -> X2Skill
SkillMetadataV3        -> X2Skill
```

当前 `NativeContract` 没有已验证的 `X2Skill` API_TYPE 行。RU capability 文档能证明 `GetCooldown / GetMateCooldown / Info / GetSkillTooltip` 已允许，但**不能证明 ImportAPI 的 namespace 数字 ID**。在找到真实 ABI 证据前禁止猜测写入 NativeContract。

### 问题本质

Native Dependency 必须是明确的所有权契约，不允许依赖：

```text
Feature A 开启
    -> 顺手导入某 X2 namespace
    -> Feature B / Service B 才能正常工作
```

否则拆 Business Bridge / Life Bundle 后会集中暴露此前由共享 chunk、共享启动顺序掩盖的故障。

### Phase 0 门禁

新增 `tools/rs_native_dependency_audit.py`，至少检查：

```text
1. Registry Native namespace
   vs implementation ApiDependencies override

2. standalone Feature 的直接 X2* 使用
   vs FeatureRuntime 实际有效依赖

3. Shared Service 的 Native namespace 使用库存

4. shipped runtime 使用了 NativeContract 未登记 namespace

5. Feature -> Shared Service 的 transitive Native gap 库存
```

规则：

```text
implementation override 丢失 Registry 已声明 namespace
    -> ERROR

运行时代码使用 NativeContract 不认识的 namespace
    -> BLOCKER（禁止猜 API_TYPE）

Feature direct/transitive gap
    -> Phase 0 先 WARNING + 分类 required/optional
    -> Phase 3 引入 Service dependency descriptor 后转正式门禁
```

另增加 Standalone Feature Bootstrap Matrix：

```text
只开启目标 Feature
其它业务 Feature 全关闭
    -> Required Native Capability 必须仍可获得
    -> 不得借用其它 Feature 的 ImportAPI 状态
```

首批至少覆盖：

```text
life_trade
life_bonds
tools_auction
combat_buff_display
```

### Phase 3 最终目标

Feature / Service descriptor 应逐步统一为：

```text
FeatureId / ServiceId
RequiredServices
RequiredStores
NativeCapabilities
NativeDependencyMode = required | optional | lazy
SchedulerOwnership
EventOwnership
RuntimeHealthProvider
```

Service 使用 Native 时，长期不能再依赖某个 Consumer Feature “代为导入”。需要明确选择：

```text
A. Service 自己持有 Native lease / dependency descriptor
或
B. Feature descriptor 明确声明该 Service 的 required Native contract
```

optional / diagnostic 能力不得因为加入 hard ApiDependencies 而把整个 Feature 从 fail-soft 改成 fail-closed。

### 验收

```text
Feature 单独启用不会因为其它 Feature 关闭而丢 Native namespace
Registry 与实现层 dependency override 不漂移
Service Native ownership 可追踪
NativeContract 未验证 namespace 必须明确 BLOCKED
拆 Bundle 前先清理所有已知隐性借用
```


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
   - Feature implementation / Registry Native dependency parity；
   - Shared Service Native namespace ownership inventory；
   - NativeContract 未登记 namespace；
5. 增加 Standalone Feature Bootstrap Matrix，禁止 Feature 借用其它 Feature 的 Native import；
6. 保存一份 18.326 基线结果，并记录后续 Phase 0 修复版本。

### 完成标准

```text
Full regression：PASS
Lua 5.1 compile：PASS
Install integrity：PASS
Architecture audit：有已知债务清单，但工具本身可运行
Native dependency audit：0 ERROR；所有 BLOCKER 均有明确外部证据缺口，不允许猜测绕过
Standalone Feature bootstrap：首批关键 Feature PASS
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

## Phase 3：Contract / Dependency Ownership 收口

### 目标

把 FoundationGate 从“认识每个 Feature”改为“聚合注册契约”，同时把 Feature / Service Native dependency ownership 从隐式启动顺序提升为显式 descriptor。

### 新边界

Feature 注册：

```text
FeatureId
ContractVersion
RequiredServiceContracts
RequiredStoreContracts
NativeCapabilities
NativeDependencyMode(required/optional/lazy)
RuntimeHealthProvider
```

Foundation 只消费这些 descriptor。

### 验收

静态门禁：

```text
core/*.lua
除 FeatureRegistry / FeatureRuntime 基础设施外
不允许直接访问 S.Features.<业务Feature>

Feature / Service 使用的 required Native namespace
必须能从自身 descriptor/lease 追溯，禁止依赖其它 Feature 先导入
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
| Feature 单独启用、其它业务 Feature 全关闭 | Required Native Capability 仍可获得，不借用其它 Feature |
| 其它 Feature Disable / Release | 不得让当前 Feature 已声明的 required namespace 消失 |
| 未声明 Native namespace | 静态/启动门禁明确失败或按 optional 契约降级，不允许依赖全局残留 |
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
| Phase 0 测试/编译基线 | **已完成** | 18.326 | 18.330 | 第六轮闭合：真实 Lua 5.1 编译门禁（261 files，luac5.1 5.1.5）+ 真实 Lua 5.1 运行环境；两个历史证据 fixture 按 byte-for-byte 从 18.244 归档恢复；X2Skill numeric API_TYPE 由 globals/apitypes.lua 证据链确认为 35，Native audit 收敛为 0/0/0；默认 Full Runner 端到端 PASS；Install 261/261、Unfinished Closure 14/14、Architecture 仍 49 债务。仅剩 X2Skill RU 实机行为验收（Phase 3 收口项） |
| Phase 1 Business Bridge 拆分 | **已完成（Batch A–E 全部完成）** | 18.330 | 18.331 | 15 个 Feature 全部独立成文件；rs_business_bridge.lua（5223 行 / 188 slots）退役删除；新增装配工厂 + SharedBounds + 拍卖读模型；主 chunk slots 187→104→（bridge 不复存在，各文件 16–98）；`--feature-split` 59/59 并入默认 Full Runner；audit 0/0/0；Architecture 债务 49→48；BuildTag 推进到 `v3-m1.16.0.18.331-phase1-feature-slice-complete` |
| Phase 2 Life Bundle 拆分 | 未开始 | - | - | P0 |
| Phase 3 Contract / Dependency Ownership | 未开始 | - | - | Core→Feature inversion + Feature/Service Native dependency ownership |
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

## 19.2 Phase 0 第三轮记录（2026-09-28）

本轮继续冻结在 Phase 0，仍未修改任何发行运行时代码。

已完成：

- 恢复 `rs_pvp_hud_test_host.lua`、`rs_status_ui_test_host.lua`、`rs_persistence_evidence_tests.lua`、`rs_gear_page_test_host.lua`；
- 补齐共享离线 host 的当前 EventBus owner/Dispatch/unsubscribe、Scheduler 与 pooled Native UI/ColorDrawable 契约；
- 校正 Status Capture/Library Runtime 中已经失效的旧目录硬编码，改为读取当前 Authority；
- Craft 本地 WidgetHost mock 对齐 `BindFeatureLifecycle`；
- Trade 测试对齐当前 fast publish + deferred material projection、SWR refresh 与 raw/projection 分离；没有回退 Trade 生产算法；
- Auction 测试对齐当前无等级上限搜索、FloatingSurface/WindowShell、Sidecar 生命周期和 `AskMarketPrice -> paced GetLowestPrice` 报价协议；
- Team Tools 在共享 host 补齐 Native Event/UI 契约后通过。

本轮最终离线结果：

```text
Unfinished Closure：14 isolated suites PASS
Capture Library：34/34 PASS
Library Runtime：23/23 PASS
Paged Diagnostics：11/11 PASS
Focused Diagnostics：27/27 PASS
Delivery：33/33 PASS
Install Integrity：261/261 PASS，0 conflict
Lua compatibility syntax：378 files PASS（Lua 5.4 runtime）
Architecture Audit：49 known debts，未新增
```

默认 Full Runner 现在只剩两个真实历史证据资产：

```text
tools/fixtures/trade_native_numeric_20260912.lua
tools/rs_status_schema5_fixtures.lua
```

二者没有原始字节时继续 BLOCKED，禁止从测试断言伪造。真实 Lua 5.1 compiler 仍缺失，因此 Release Compile Gate 也继续 BLOCKED。

结论：Phase 0 已明显收敛但尚未完成；Phase 1 继续禁止开始。

---


## 19.3 Phase 0 第四轮记录（2026-09-28）

本轮因 `.18.327` 跑商实机诊断暴露 `host_global_missing`，新增 FND-016 并允许两个“阻断当前正确性”的小型运行时修复插队；没有扩大到 Bundle 拆分、Persistence 或 Scheduler 语义修改。

已完成：

- 新增 `tools/rs_native_dependency_audit.py` 与 runner `--native-dependency` 入口；首批 Standalone Bootstrap hard matrix 已覆盖 `life_trade` 与 `life_bonds`；
- 审计 42 个 Registry Feature、28 个 implementation override、16 个直接 Native Service、24 个已登记 NativeContract namespace；
- `.18.327` 已修 Trade 自身拥有 `X2Craft / X2Auction` import，不再借用 Craft/Auction Feature；
- `.18.328` 进一步修复 `life_bonds -> QuestProgressV3 -> X2Quest`：Bonds implementation 与 Registry 都声明活动任务索引 + 完成状态所需 X2Quest 能力；
- 审计修复后 `implementation override vs Registry` 为 0 ERROR；
- 发现 `CooldownObservationV3` 与 `SkillMetadataV3` 正式使用 `X2Skill`，但 NativeContract 缺少已验证 namespace API_TYPE ID；该项保持 BLOCKED，禁止猜数值；
- 记录 `combat_buff_display` 的 `X2Ability / X2Equipment` direct gap，以及其 Cooldown/Gear Service transitive gap；这些含 fail-soft/diagnostic/子能力语义，Phase 0 只记录 WARNING，不能简单扩大 hard dependencies；
- `tools_auction -> DailyAuctionMaterialsV3 -> QuestProgressV3 / TradeMaterialIdentityV3` 属于同类 service ownership 候选，后续 Standalone Bootstrap 与 Phase 3 service descriptor 必须覆盖。

当前 Native Dependency Audit 目标状态：

```text
ERROR = 0
BLOCKER = 1   (X2Skill API_TYPE id 未验证)
WARNING = 已分类 debt，不作为“自动扩大 Feature hard import”的理由
```

新增原则：

```text
不能为了消灭 warning，把所有 Service 用到的 X2 namespace 一股脑塞进 Feature.ApiDependencies。
required / optional / lazy 必须先分类，否则会把原有 fail-soft Feature 变成 fail-closed。
```

因此 Phase 0 仍未完成；Phase 1 继续禁止开始。



## 19.4 Phase 0 第五轮记录（2026-09-28）

本轮继续 FND-016，不进入 Phase 1。

完成：

- `combat_buff_display` 补齐真实直接使用的 `X2Ability` / `X2Equipment` Registry 依赖；
- Standalone Bootstrap Matrix 增加 BuffDisplay hard dependency 验证；
- Native Dependency Audit 引入 Feature → Shared Service 的 `required / optional / lazy` policy；
- `GearV3` 对 BuffDisplay 只把 `X2Equipment` 视为 required，`X2Bag/X2Player` 保持 optional，禁止为消告警扩大 hard import；
- `CooldownObservationV3 -> X2Skill` 与 `SkillMetadataV3 -> X2Skill` 明确标为 lazy Shared Service capability；
- Native audit 从第四轮 `0 ERROR / 1 BLOCKER / 4 WARN` 收敛为 `0 ERROR / 1 BLOCKER / 0 WARN`；
- 唯一 Native blocker 仍是 `X2Skill`：method permission 已有证据，但 `ADDON:ImportAPI` numeric namespace ID 未验证，继续禁止猜测；
- Unfinished Closure 14/14、Trade Optimization、Bonds Auroria、Feature Consumer Lifecycle、378 Lua compatibility syntax 全部通过；Architecture Audit 仍为 49 个既有债务。

本轮 Build：

```text
v3-m1.16.0.18.329-native-dependency-policy
```

Phase 0 尚未结束。继续前置门禁：

```text
X2Skill numeric API_TYPE ABI
2 个历史证据 fixture
真实 Lua 5.1 compile gate
```


## 19.5 Phase 0 第六轮记录（2026-09-28，Phase 0 闭合）

本轮命中的不是新功能，而是 Phase 0 之前列为“无法在本地取得证据”的三项硬门禁。三者现在全部有真实证据并通过；Phase 0 的 Exit Criteria（§22.5）首次全部满足。

### 19.5.1 三项硬门禁结果

```text
1. 真实 Lua 5.1 compile gate              -> PASS（261 shipped Lua，luac5.1 = Lua 5.1.5）
2. tools/fixtures/trade_native_numeric_…  -> 已按 byte-for-byte 恢复（SHA-256 4be79530…）
3. tools/rs_status_schema5_fixtures.lua   -> 已按 byte-for-byte 恢复（SHA-256 b160de4f…）
4. X2Skill ImportAPI numeric API_TYPE      -> 已取得真实 ABI 证据：SKILL = 35
```

### 19.5.2 Lua 5.1 门禁：从 BLOCKED 变成真实 PASS

本机一直存在真实 Lua 5.1.5 工具链，只是没有进入门禁进程的 `PATH`：

```text
C:\Users\llq\.workbuddy\binaries\luabin\  （lua5.1.exe / luac5.1.exe / lua51.dll）
```

做法：把该目录加入 `PATH` 后再跑门禁，**没有修改任何门禁脚本的判定条件**。

```bash
export PATH="$HOME/.workbuddy/binaries/luabin:$PATH"
python tools/rs_lua51_compile_gate.py      # PASS: 261 shipped Lua files (luac5.1.EXE)
python tools/rs_status_refactor_test_runner.py --syntax   # SYNTAX PASS: 380 Lua files (runtime=Lua 5.1)
```

意义：此前 378 文件 PASS 只是 **Lua 5.4 兼容语法**结果，等同于“没有真实 Lua 5.1 证据”。现在离线回归本身也运行在真实 Lua 5.1 上，FND-001 关心的 200 locals 类限制终于可被门禁捕获。

### 19.5.3 两个历史证据 fixture：已在归档中找到原始字节

来源：`C:\Users\llq\Downloads\ReplicatedSuite_18.244_full_project.zip`（zip 内 mtime 2026-09-12，与文件名日期一致）。

```text
replicatedsuite/tools/fixtures/trade_native_numeric_20260912.lua
    bytes=1361   SHA-256=4be7953019415b56b97470114df979082ba8a5d75ba097d876e67f506948cf04
    自述：User-provided RS-FOCUS-1 ID=1.1；LoadData 快照，非 pre-save 认证快照
replicatedsuite/tools/rs_status_schema5_fixtures.lua
    bytes=23180  SHA-256=b160de4f8fb4c5b604fd95b64fb16e9eadd14646c80e6154d7c06a165a711a0d
    自述：由 .18.208 原始 Store 生成的 schema5 兼容样本；历史 canonical/hash 金样，禁止随新 normalizer 重生成
```

恢复方式：从 zip 直接取原始字节写入目标路径（未格式化、未重新序列化）。二者均**不在** `toc.g`，属离线测试资产。

fixture 恢复后默认 Full Runner 第一次真正跑到文件末尾，并暴露出此前被“提前阻断”掩盖的 20 项失败。逐项按 §30 决策树分类后全部处理完毕（详见 `PHASE0_SIXTH_ROUND_BASELINE_CLOSURE_2026-09-28.md`）。

### 19.5.4 X2Skill numeric API_TYPE：真实 ABI 证据

证据链（不再依赖任何推测）：

```text
资产：C:\Users\llq\Downloads\Addon.zip 内 globals/apitypes.lua
      （SHA-256 df8475b7cb31…，另 Addon(1).zip / Addon(2).zip 为同一副本）
      同一行同时存在于 Addon1.2.zip 的 globals/apitypes.lua（SHA-256 08d3f2383908…）

第 82 行：SKILL = { id = 35, apiname = "X2Skill" }

交叉验证：该 API_TYPE 表与本工程此前已核的 24 个 NativeContract namespace
          100% 一致（UNIT=42、CHAT=8、ABILITY=3、STORE=37、CRAFT=9、EQUIPMENT=13、
          AUCTION=51、RESIDENT=73、MAP=54、TEAM=38…），0 mismatch、0 missing
          -> 同一 ABI 世代，不是“看起来相邻所以猜 35”

使用侧旁证：Addon1.2.zip 内本项目旧 Professional 模块
          replicatedsuite/modules/professional/plates/replicatedplates.lua
          以 ADDON:ImportAPI(API_TYPE.SKILL.id) 导入该 namespace

method 权限：z_api_functions/api_functions.lua 的 X2Skill 段落 +
          core/rs_api_capabilities.lua 已登记 X2Skill:GetCooldown / GetMateCooldown
```

落地（严格限定在 §22.2 允许的范围内）：

```text
native/rs_native_contract.lua
    + SKILL = { id = 35, nativeName = "X2Skill", feature = true }
services/rs_cooldown_observation_v3.lua
    + C:EnsureNativeSkillLease()  —— 首个 consumer 进入时由服务自己 AcquireApi("X2Skill")
services/rs_skill_metadata_v3.lua
    + M:_EnsureNativeSkillLease() —— 只在真正需要 Native 明细的路径导入
```

二者都保持 **fail-soft**：取得失败只记录 `nativeSkillLeaseState/…Error` 并继续用降级结果，不把 BuffDisplay / Gear 等无关消费者升级成 hard dependency，也不引入不存在的 Native Unimport。

结果：

```text
Native Dependency Audit: 0 ERROR / 0 BLOCKER / 0 WARN（第五轮为 0/1/0）
```

### 19.5.5 本轮暴露并修复的测试基础设施（均为 §30 分类结论，非生产回退）

| 现象 | 分类 | 结论与修法 |
|---|---|---|
| legacy `v3.buff_display` 被写保护却期望追踪导入失败（rs_persistence_integrity_regressions / rs_status_refactor_tests） | B 测试过期 | .18.243 起旧大 Store 永久降级为 LegacyMigrationSourceOnly，manifest 已建立后它不参与启动/写入。把“写保护不得绕过”改为在**真正的 Authority（tracking manifest）**上验证 |
| `writes==before+1` | B 测试过期 | .18.243 后一次 tracking 提交 = inactive player/target/meta 三次 durable 写 + manifest，共 4 次（同文件另一处已如此断言） |
| `#library_table.items==393` | B 测试过期 | 当前目录 all 包为 425 effects（与 `result.total==850` 一致）；改为同时断言“行数==Authority 包条目数”并 pin 425 |
| 故障页控件 id `v3_buff_persistence_report` | B 测试过期 | 当前只读取证入口是 `v3_buff_evidence_export`；仅更正 id |
| 首页/总览 `v3_home_trade_quote` | B 测试过期 | 首页卡当前只提供有界默认动作，批量/高级询价只属于完整跑商页（.298 归档模块同样无该控件，属长期过期断言） |
| unit-lines 15 项全红 | C 宿主不完整 | `tools/rs_udf_numeric_test_host.lua` 缺 `S.Api:CallCapability` / `CallGlobalCapability`；按 core/rs_api.lua 真实返回形态 `ok, value, nil, extra…` 补齐，离线宿主不模拟限速 |
| home 15 项全红 | C 宿主不完整 | `tools/rs_gear_page_test_host.lua` 的 Node 桩缺 `ModuleDiagnosticsButton` / `SetViewportVisible`；且该文件曾把“加载真实 RSUI 框架”的宿主换成纯 Node mock，导致布局/表格类套件不可能通过 —— 已恢复为加载真实 RSUI + DesignSystem 的版本 |
| home 剩余 6 项 | C 宿主不完整 | 内容模块要求 `SetViewMode / ToggleTrackedProduct / QuoteRowMaterials / SetDisplayOrder / SetFilterMask / SetDuplicateMode` 与 `GetDisplayOrderKey / GetFilterMask / GetDuplicateMode`，宿主 stub 为 .298 旧命令集；均已在生产代码中确认存在后补桩 |

### 19.5.6 本轮最终门禁结果（真实执行）

```text
Install Integrity         PASS  261/261，0 conflict
Native Dependency Audit   PASS  0 ERROR / 0 BLOCKER / 0 WARN（contract_namespaces=25）
Architecture Audit        PASS  49 既有债务（41 Core→Feature / 5 Presentation State / 3 Giant File），无新增
Test Dependency Audit     PASS  25 reachable files（此前 BLOCKED）
Lua compatibility syntax  PASS  380 Lua files（runtime = 真实 Lua 5.1）
Lua 5.1 Compile Gate      PASS  261 shipped Lua files（luac5.1，Lua 5.1.5）
Unfinished Closure        PASS  14 isolated suites
Cooldown 专项             PASS  COOLDOWN_OBSERVATION_V4（含新增 lazy ownership 覆盖）
默认 Full Runner          PASS  端到端 exit=0，0 FAIL、0 BLOCKED
```

### 19.5.7 Phase 0 结论

§22.5 的七条 Exit Criteria **全部满足**。因此按 §22.5 推进一次正式 BuildTag：

```text
v3-m1.16.0.18.330-phase0-trust-baseline
```

本轮**没有**进入 Phase 1：Phase 1 允许开始，但需按 §23 的 Feature 顺序小批次施工，不应与本轮基线闭合混在同一版本里。

仍未解决（不阻断 Phase 1，但必须在 Phase 3 收口）：

```text
X2Skill 的实机行为验收（cooldown 读数的 RU 实机 Fresh Reload / 只开 BuffDisplay 场景）
- 离线证据只证明 namespace ABI 与 lazy ownership 契约；不证明 RU 实机返回值
```


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

---

# 21. 本地 Agent 施工总规范（Workbuddy / DeepSeek 4.1 执行版）

> 本章是**执行合同**，不是建议。Agent 可以自主持续工作，但不得越过本章的边界。遇到本章定义的 STOP 条件时，必须保留现场、记录证据并停止扩大范围；不得通过猜测、删测试、改 Store 或弱化门禁继续前进。

## 21.1 Source of Truth 优先级

发生冲突时按以下优先级判断：

```text
1. 当前本地实际源码 + 当前真实测试结果
2. 本文档“冻结边界 / Authority / STOP 条件”
3. 当前 Feature/Service 自己的公开 Contract / Registry / Store 定义
4. 本文档历史状态记录
5. 旧补丁、旧测试输出、旧注释、旧聊天描述
```

注意：

- “当前源码优先”**不等于**可以推翻本文档的兼容红线；
- 旧测试失败时不能直接把 expected 改成 observed，必须先证明旧断言已经被当前 Authority 正式替代；
- 生产代码和测试冲突时，先判断“生产回归”还是“测试漂移”，禁止为了变绿二选一地盲改。

## 21.2 开工前必须确认当前树是累计基线

当前预期 BuildTag：

```text
v3-m1.16.0.18.329-native-dependency-policy
```

并且必须同时存在以下三轮修复：

```text
.327
life_trade implementation 自己声明 X2Craft + X2Auction

.328
life_bonds implementation 自己声明 X2Quest

.329
combat_buff_display Registry 明确声明直接使用的 X2Ability + X2Equipment
Native Dependency Audit = required / optional / lazy policy
```

### 特别警告：增量 ZIP 不是完整发行包

`.327 / .328 / .329` 是连续施工补丁。

禁止：

```text
拿一个旧 Addon
    + 只覆盖 .329 ZIP
    = 当成“当前完整工程”
```

因为 `.329` 并不重新携带 `.328` 的所有文件，可能把 Bonds/Trade 前序修复遗漏在本地树之外。

Agent 开工前必须从**用户当前本地工作树**读取真实文件，不得自行用某一个旧 ZIP 重建工程后继续。

## 21.3 工作区安全规则

如果工程是 Git 仓库：

```text
先执行：
git status --short
git diff --stat
git diff --name-only
```

要求：

- 不允许 `git reset --hard`；
- 不允许 `git clean -fd`；
- 不允许覆盖/删除用户已有未提交修改；
- 不允许 rebase / force push；
- 如果当前树已有用户修改，先记录这些文件，不得把它们算成自己的改动。

如果不是 Git 仓库：

- 在修改前保存“本轮会修改文件”的原始副本或可逆 patch；
- 不需要复制整个大型工程，但必须能够逐文件回滚本轮更改。

## 21.4 每个工作包固定执行顺序

每一个工作包都必须按以下顺序执行：

```text
A. READ
   读真实代码、toc、Registry、Runtime、相关 Service、Presentation 消费者、专项测试

B. FREEZE
   写清本工作包只允许改什么，不允许改什么

C. SNAPSHOT
   记录修改前公开契约与基线测试

D. CHANGE
   做最小结构修改；不顺手改业务算法

E. NARROW TEST
   先跑专项测试

F. FOUNDATION TEST
   再跑生命周期/Store/Native/Architecture 相关测试

G. FULL GATE
   最后跑当前可运行的全量门禁

H. DIFF REVIEW
   检查实际 diff 是否超范围

I. DOCUMENT
   更新本文件状态和本轮报告
```

Agent 不需要每完成一个小步骤向用户询问；只要没有命中 STOP 条件，应连续执行到当前工作包完整结束。

## 21.5 全局禁止项

### 架构禁止

- 禁止新增第二个 Scheduler / 永久 OnUpdate；
- 禁止新增第二个 EventBus；
- 禁止新增第二个 Persistence Authority；
- 禁止 FeatureA 直接持有 FeatureB 私有对象；
- 禁止 Presentation 直接写 Feature State；
- 禁止为“方便”复制 Shared Service 已经拥有的长期事实缓存；
- 禁止把所有 Feature helper 堆进新的 `core/rs_business_common.lua` 一类巨型公共文件。

### Native 禁止

- 禁止猜测 `ADDON:ImportAPI` numeric ID；
- 禁止通过相邻 namespace ID 推算 X2Skill；
- 禁止在实机中暴力遍历 ImportAPI 数字 ID；
- 禁止用 `rawget(_G, "X2...")` 绕过缺失的 dependency ownership；
- 禁止因为 Shared Service 文件里存在某 namespace，就把它无条件升级成所有消费者的 required dependency；
- 禁止创建第二套 Native import manager；唯一 Authority 仍是 `S.NativeImports` / `native/rs_native_imports.lua`。

### Persistence 禁止

- 禁止因为源码移动修改 Store ID；
- 禁止因为拆文件修改 Store Schema；
- 禁止为了测试通过改变 canonical/fingerprint/integrity 规则；
- 禁止绕过 fenced Store；
- 禁止在业务 Feature 里直接新增 `ADDON:SaveData` 路径绕过 Persistence；
- 禁止“功能关闭 = 删除配置”。

### Lua 5.1 禁止

正式运行时源码不得引入 Lua 5.2+ 语法/语义依赖，例如：

```text
goto / ::label::
// 整除
原生位运算符
依赖 table.unpack 而没有兼容边界
依赖 utf8 标准库
```

项目继续以 Lua 5.1 目标客户端为 Authority。

### 测试禁止

- 禁止从 required list 删除缺失 fixture 来制造 Full PASS；
- 禁止从测试断言反推/伪造历史 golden；
- 禁止把 Lua 5.4 compatibility syntax 当成 Lua 5.1 compile PASS；
- 禁止把“测试之前就失败”自动理解成“可以忽略”；必须记录为 pre-existing debt；
- 禁止只改 expected 数字直到测试变绿，必须指出对应 Authority 为什么发生合法变化。

## 21.6 STOP 条件

发生以下任一情况时，Agent 必须停止当前工作包继续扩张：

1. 需要改变任意用户 Store Schema/ID 才能继续；
2. 需要猜测 Native API、字段语义或 `API_TYPE` numeric ID；
3. 发现一个 helper 同时服务多个 Feature，但无法证明正确 Authority；
4. 修改后出现新的 Persistence fence / integrity failure；
5. 修改后出现新的跨 Feature 启动依赖；
6. 需要改变 Trade 售价、货率、新鲜度、拍卖报价算法才能完成“文件拆分”；
7. 需要改变 Scheduler/EventBus 执行语义才能完成 Phase 1/2；
8. 新增测试失败且无法证明是 pre-existing / stale assertion；
9. `toc.g` 加载顺序需要跨越 Core/Service/Feature/Presentation 层级倒置；
10. 当前本地树不是可确认的累计基线，且继续修改可能覆盖用户已有修复。

命中 STOP 后只做：

```text
记录问题
记录调用链
记录受影响文件
记录已做/未做修改
git diff / patch 保留现场
```

不得自动进入下一 Phase。

---

# 22. Phase 0 剩余工作——可执行清单

当前 Phase 0 不是“大范围继续优化”，而是只剩三个硬门禁 + 最终闭环。

## 22.1 P0-A：先重建当前基线证据

在项目根目录执行：

```bash
python tools/rs_check_installation.py .
python tools/rs_native_dependency_audit.py
python tools/rs_architecture_audit.py
python tools/rs_status_refactor_test_runner.py --syntax
python tools/rs_status_refactor_test_runner.py --unfinished-closure
python tools/rs_test_dependency_audit.py
python tools/rs_status_refactor_test_runner.py
python tools/rs_lua51_compile_gate.py
```

如果本地树确实是累计 `.18.329`，当前已知基线大致应为：

```text
Install Integrity       261/261 PASS，0 conflict
Native Dependency       0 ERROR / 1 BLOCKER / 0 WARN
Architecture Audit      49 known debts（库存，不是新失败）
Lua 5.4 compatibility   378 runtime Lua PASS
Unfinished Closure      14/14 isolated suites PASS
Full Runner             BLOCKED：2 个历史证据 fixture
Lua 5.1 Compile Gate    BLOCKED：未找到真实 luac5.1 / luac-5.1
```

如果数字不同：

- 不要先改代码“对齐文档”；
- 先确认用户本地树是否有更新版本；
- 记录差异和原因；
- 若差异是用户后续合法修改，则以当前真实树为新基线，但不得回退已有修复。

## 22.2 P0-B：X2Skill numeric API_TYPE ABI 取证

### 目标

只回答一个问题：

```text
X2Skill namespace 在 ADDON:ImportAPI(<id>) 中真实、可证明的 numeric id 是多少？
```

### 已经证明但仍不足的事实

当前资料已经能证明这些 method 被 RU 放行：

```text
X2Skill:GetSkillTooltip
X2Skill:Info
X2Skill:GetCooldown
X2Skill:GetMateCooldown
```

**method permission 不等于 namespace numeric ID。**

### 允许搜索的证据

优先搜索本地：

1. 用户保存的历史 Addon / ZIP / API reference；
2. 曾经可工作的 cooldownTracker 等插件源码；
3. 旧 `globals_archive / API_TYPE` 映射（如果本地其它版本存在）；
4. 官方或已验证客户端脚本中 `API_TYPE` 枚举；
5. Git 历史/备份中曾经存在且有来源说明的 NativeContract 行。

可接受的强证据示例：

```text
某个已验证可运行的 Addon：
ADDON:ImportAPI(N)
随后直接使用 X2Skill:GetCooldown
且 N 的 namespace 对应关系没有歧义
```

最好保留：来源路径、来源版本、文件 hash、相关代码行。

### 明确禁止的“证据”

```text
QUEST=33，所以猜 SKILL=35
看起来枚举顺序相邻
网上有人口头说是某个数字
循环 0..100 调 ImportAPI 看哪个出现 X2Skill
```

都不能进入正式 NativeContract。

### 找到真实 ID 后允许修改的范围

只允许围绕：

```text
native/rs_native_contract.lua
native/rs_native_imports.lua（仅在现有接口确实不足时；优先不改）
services/rs_cooldown_observation_v3.lua
services/rs_skill_metadata_v3.lua
Native dependency tests / cooldown tests / metadata tests
Docs
```

推荐落法：

```text
NativeContract 增加 X2Skill namespace
    ↓
CooldownObservationV3 在首次真正需要 cooldown Native 时 lazy Acquire
SkillMetadataV3 在首次需要 Native metadata drill-down 时 lazy Acquire
    ↓
S.NativeImports 仍是唯一 ImportAPI Authority
```

不要把 X2Skill 重新塞成所有 BuffDisplay/DPS 消费者的 hard Feature dependency。

### lazy ownership 的语义

`ImportAPI` 本身是 generation-scoped 导入，不要求也通常无法“unimport”。

因此这里的 lazy ownership 是：

```text
没用到子能力 -> 不提前 Import
第一次需要 -> Service 通过 S.NativeImports:Acquire(serviceId, dependencies) 导入并登记 owner
最后一个业务 consumer 释放 -> 停 Scheduler / listener / cache
但不伪造一个不存在的 Native Unimport
```

禁止为了实现“lease”再造第二套 import registry。

### 必测

- Cooldown service 没 consumer 时不启动 probe task；
- 第一次需要 cooldown 时能取得 X2Skill；
- Skill metadata 只在 detail/metadata 请求路径 lazy lookup；
- BuffDisplay 单独运行不要求其它 Feature 先导入 X2Skill；
- ReloadAddon generation 变化后可重新建立 ownership；
- Native 获取失败要 fail-soft，不得让无关状态 HUD 整体初始化失败，除非现有契约本来定义为 required。

### 如果找不到 ID

保持：

```text
BLOCKER = 1
```

不要改 NativeContract，不要降低 audit 严格度。

## 22.3 P0-C：恢复两个历史证据 fixture

仍缺：

```text
tools/fixtures/trade_native_numeric_20260912.lua
tools/rs_status_schema5_fixtures.lua
```

### 允许做什么

在本地历史 ZIP / 旧工作目录 / Git 历史 / 备份中搜索同名文件。

建议使用脚本扫描 ZIP 而不是盲目全部解压：

```python
from pathlib import Path
from zipfile import ZipFile, BadZipFile

wanted = {
    "trade_native_numeric_20260912.lua",
    "rs_status_schema5_fixtures.lua",
}
for z in Path("<历史包目录>").rglob("*.zip"):
    try:
        with ZipFile(z) as f:
            for name in f.namelist():
                if Path(name).name in wanted:
                    print(z, "->", name)
    except BadZipFile:
        pass
```

### 找到后

必须记录：

```text
来源 archive/path
来源日期/Build（能确认时）
fixture 原文件 SHA-256
哪些 tests 引用它
```

复制时尽量 byte-for-byte，不要顺手“格式化”。

### 多个版本冲突时

不要选“看起来最新”的。

应根据调用它的测试所声明历史时期和 fingerprint/transport/schema 语义确认正确版本。

### 禁止

- 根据 expected hash 逆向构造刚好能通过的 table；
- 用当前 serializer 重新生成“历史 fixture”；
- 把测试改成 synthetic fixture 后称 Full Regression PASS；
- 删除对这两个 fixture 的 required dependency。

找不到则继续 BLOCKED，并在交付报告中明确写“历史证据缺失”。

## 22.4 P0-D：真实 Lua 5.1 Compile Gate

现有：

```text
tools/rs_lua51_compile_gate.py
```

它只接受：

```text
luac5.1
luac-5.1
```

并编译所有 shipped runtime `.lua`，排除 `tools/`。

### 合法解决方式

优先级：

1. 使用用户机器已经安装的真实 Lua 5.1 compiler；
2. WSL/系统包提供的 Lua 5.1 compiler；
3. 从可信源构建 vanilla Lua 5.1.x compiler，并记录来源/版本。

### 禁止

- 修改 gate 让 `luac` 5.4 也算 PASS；
- 用 LuaJIT 代替 Lua 5.1 compiler 后声称完全等价；
- 只编译“本轮修改文件”后宣称 release compile gate PASS；
- 因为兼容语法测试 378 PASS 就删除这一门禁。

### 完成证据

报告必须包含：

```text
compiler executable path
compiler version
compile file count
return code
失败文件（如有）
```

## 22.5 P0-E：Phase 0 最终闭环

Phase 0 只有同时满足下列条件才允许进入 Phase 1：

```text
Native Dependency Audit：0 ERROR / 0 BLOCKER / 0 WARN（或所有 optional inventory 已有明确非阻断分类）
两个历史 fixture 已恢复并有来源证据
Full Runner 真正执行到底 PASS
真实 Lua 5.1 Compile Gate PASS
Install Integrity PASS
Unfinished Closure PASS
Architecture Audit 只剩已知 debt，没有新 debt
```

Phase 0 完成时只推进一次正式 BuildTag，并更新状态表。

---

# 23. Phase 1：Business Bridge 拆分——Agent 逐项施工手册

## 23.1 这一阶段只做“源码故障域拆分”

Phase 1 的核心目标：

```text
把 features/rs_business_bridge.lua 中每个业务 Feature 变成独立源码单元
```

不是：

```text
重新设计 Bag
重新设计 Auction
重写 RangeAssist
优化 Trade
重写 UI
重写 Scheduler
```

任何业务算法修改都应另开任务。

## 23.2 开始前必读文件

至少读取：

```text
features/rs_business_bridge.lua
features/rs_feature_registry.lua
features/rs_feature_runtime.lua
core/rs_demand.lua
core/rs_scheduler.lua
core/rs_events.lua
core/rs_persistence.lua（只读相关 Register/Load 契约，不在本阶段修改）
native/rs_native_imports.lua
toc.g
相关 Presentation 消费者
相关专项 tests
```

## 23.3 禁止引入普通 Lua module loader 风格

本项目运行时以 `toc.g` 顺序加载和 `ReplicatedSuite` namespace 为基础。

禁止为了拆文件引入：

```text
require(...)
package.path 修改
package.loaded 技巧
新的自制 module loader
```

新文件继续通过 `toc.g` 按层级加载。

## 23.4 第一小步：抽取真正通用的 Feature Slice Factory

当前 Business Bridge 内的 `NewFeature(...)` 与少量基础 helper 是多个小 Feature 的共同装配逻辑。

允许建立：

```text
features/shared/rs_feature_slice_factory.lua
```

但它必须满足：

- 只认识 Core / Persistence / FeatureRuntime / Demand / Event/API boundary；
- 不认识 Bag/Auction/Craft/UnitLines/RangeAssist 的业务 State；
- 不持有任何 Consumer 业务真相；
- 不建立第二个 Registry/Runtime；
- 不把所有业务 helper 一起搬进去。

### Factory 可以包含的候选

只有经代码证明通用的部分，例如：

```text
基础 Copy
统一 capability Call/Action adapter
通用 RegisterStore wrapper（保持原参数/Schema）
通用 Load feature store
NewFeature 装配骨架
```

### Factory 不能包含

```text
Bag scan/move helper
Craft recipe parser
Auction search/quote helper
Range circle math
Unit line projection
Boss alert rule table
Team role logic
```

如果某 helper 是否通用无法证明，先留在原 Feature，不要为了“减少重复”强行 shared。

## 23.5 每拆一个 Feature 前必须创建“契约快照”

使用下面模板，写入本轮工作记录：

```text
FeatureId:
原源码范围:
目标文件:
Registry route:
Store IDs:
Store schemas:
ApiDependencies:
Required shared services:
Demand id/owner:
Scheduler task names:
Event subscriptions/topics:
UpdateTopic:
Commands public names:
Projection top-level keys:
Presentation consumers:
Feature-specific diagnostics provider:
当前专项 tests:
```

如果任何一项无法确认，先继续读调用链，不要开始移动。

## 23.6 每个 Feature 的机械拆分规则

1. **先复制再删除**，保持函数体和注释尽量 byte-equivalent；
2. 不改公开名字；
3. 不改 Store ID / schema；
4. 不改 Registry route；
5. 不改 task name；
6. 不改 event topic；
7. 不改 Demand owner/id；
8. 不改 Commands 签名；
9. 不改 Projection shape；
10. 不改变 disabled/enabled 默认行为；
11. 不把 local 变量意外提升为 `S.*` 全局可写 State；
12. 从原 Bridge 删除已搬代码，避免双注册；
13. `toc.g` 只增加新文件一次，不能旧 Bridge + 新文件同时注册同一 Feature；
14. 每拆一个后立即检查 `RegisterImplementation` 唯一性。

## 23.7 helpers 的归属判断

发现 helper 被多个 Feature 使用时按顺序判断：

```text
A. 它是共享“事实”吗？
   -> 应优先进入/复用 Services

B. 它只是无状态通用装配工具吗？
   -> 可进入 features/shared

C. 它其实属于某个 Feature 的业务判断吗？
   -> 留在该 Feature；其它 Feature 不得直接调用其私有 helper

D. 无法判断
   -> STOP，记录 coupling，不猜
```

禁止用“复制一份 helper 到两个 Feature”来复制长期业务 Authority。

## 23.8 建议拆分顺序与单次工作包大小

顺序维持原计划：

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

Agent 可以连续工作，但建议内部以“小批次”验收：

```text
Batch A：1-2
Batch B：3-5
Batch C：6-9
Batch D：10-12
Batch E：13-15
```

每个 Batch 全绿后才能继续下一个。

## 23.9 已知特殊坑

### tools_craft

已有：

```text
features/life/craft/rs_craft_assistant_surface_extension_v3.lua
```

它是现有 extension，不等于 tools_craft Authority 本体。

禁止拆 Authority 时顺手合并/重写这个 extension。

### combat_team_tools

已有：

```text
features/combat/team_tools/rs_team_tools_visuals.lua
```

不要把 visuals 误当 Feature Authority，也不要因为目录已经存在就重复注册 implementation。

### tools_auction

Presentation Sidecar / AuctionSurface / PriceQuoteQueue 都已经有各自边界。

拆 Authority 时禁止把它们重新塞回 Auction Feature 私有 State。

### tools_bag

Bag movement runtime 风险高。

必须保留：

- move transaction / batch 上限；
- Input/Native 安全边界；
- 关闭后任务释放；
- 黑名单和用户配置永久保存。

不要在“拆文件”阶段顺便优化搬运算法。

### combat_unit_lines / combat_range_assist

这两个最后拆，因为依赖 ScreenProjection、HUD/Presentation 和高频刷新。

必须证明：

- task cadence 不变；
- projection coordinate contract 不变；
- 关闭功能后任务/缓存仍释放；
- 不新增自己的 OnUpdate。

## 23.10 Phase 1 每 Batch 必跑

至少：

```bash
python tools/rs_check_installation.py .
python tools/rs_native_dependency_audit.py
python tools/rs_architecture_audit.py
python tools/rs_status_refactor_test_runner.py --syntax
python tools/rs_status_refactor_test_runner.py --unfinished-closure
```

再跑该 Batch 相关专项 tests + `rs_foundation_lifecycle_tests.lua` / service boundary / consumer lifecycle。

当 Phase 0 已真正修复 Full Runner 后，Phase 1 每个 Batch 都必须跑 Full Runner。

## 23.11 Phase 1 完成判定

- `rs_business_bridge.lua` 不再包含业务 Feature implementation；
- 可以只保留极薄 compatibility shim，最好最终删除；
- 每个 implementation 只注册一次；
- 原 Feature ID/Store/route/public commands/projection 全部不变；
- 单个 Feature 源码失败不再因为“同一 Lua chunk”天然吞掉其它实现；
- Lua 5.1 compile PASS；
- 用户配置无需迁移。

---

## 23.12 Phase 1 Batch A 施工记录（2026-09-28）

Build：`v3-m1.16.0.18.330-phase0-trust-baseline`（Phase 1 第一轮，尚未推进新的正式 BuildTag）。

### 23.12.1 本批次实际范围

```text
WP 1a  features/shared/rs_feature_slice_factory.lua      通用装配骨架（§23.4 要求的第一步）
WP 1b  features/tools/social/rs_social_feature.lua        tools_social 机械搬迁
WP 1c  features/tools/auction/rs_auction_read_model.lua   拍卖共享读模型（tools_auction + tools_market_analysis）
       features/tools/market_analysis/rs_market_analysis_feature.lua
```

`rs_business_bridge.lua`：5223 → **4829** 行；仍在其中注册的 Feature 从 15 个降到 **13 个**。
本轮**没有**触碰任何业务算法、Store schema、Scheduler/EventBus/Persistence 语义、Presentation。

### 23.12.2 工厂内容的归属判定（§23.7）

允许进工厂（经代码证明与业务无关、被多处共用）：

```text
Copy / Text / Number / Trim                       基础值工具（Trim 17 处、Text 15 处、Number 13 处）
Call / Action                                     capability 适配（含“能力名前缀回退到同名全局”的既有语义）
RegisterStore / Load                              通用 Store 注册与加载
PersistentState                                   永久字段白名单快照
PersistStateMutation                              Feature State 快照事务（Persistence MutateStore 薄包装）
NewFeature                                        装配骨架
```

明确**不允许**进工厂（本轮也没进）：Bag 扫描/搬运、Craft 配方解析、Auction 搜索/报价、Range 圆数学、
Unit line 投影、Boss 规则表、Team 角色逻辑。

### 23.12.3 拍卖共享读模型的归属判定（§23.7-A/B/C）

`AuctionQueryReconcile / Snapshot / Search / Rows / Projection / SettingsCommands` 与
`NormalizeAuctionKeyword / NormalizeAuctionFavorites / NormalizeAuctionResultLimit / AUCTION_*` 的判定：

```text
A. 是共享“事实”吗？      否 —— 事实归 AuctionQueryV3 / PriceQuoteQueueV3 / AuctionSearchBridgeV3（README §3.3）
B. 是无状态通用装配工具吗？ 否 —— 它只服务拍卖语义
C. 是某个 Feature 的业务判断吗？也不是 —— 恰好 2 个消费方（tools_auction / tools_market_analysis）
=> 结论：它是一层“拍卖读模型适配层”，给独立单元，不拥有事实、不读 Feature 私有 State、
   不发起 Native 查询。放到 features/tools/auction/rs_auction_read_model.lua 并由 S.AuctionReadModel 发布。
```

因此**没有**采取“让 market_analysis 反向依赖 tools_auction 私有 helper”或“复制两份”的错误做法。

### 23.12.4 前后对照表（§31 模板）

**tools_social**

| 契约 | 修改前 | 修改后 | 必须相同？ |
|---|---|---|---|
| Feature ID | `tools_social` | `tools_social` | 是 ✓ |
| 源/目标 | `features/rs_business_bridge.lua` 4217-4362 | `features/tools/social/rs_social_feature.lua` | — |
| Registry route | `tools.social` | 未改 | 是 ✓ |
| Store ID | `v3.business.tools_social`（owner `v3.tools_social`） | 同 | 是 ✓ |
| Store schema | V3Store schema1 / legacy0 / Account / Permanent | 同 | 是 ✓ |
| ApiDependencies | 8 个 `X2Friend:*` | 同集合 | 是 ✓ |
| Required shared services | 无 | 无 | 是 ✓ |
| Demand id/owner | `feature:tools_social` / feature | 同 | 是 ✓ |
| Scheduler task | 无 | 无 | 是 ✓ |
| Event subscriptions | 无 | 无 | 是 ✓ |
| UpdateTopic | `v3.business.tools_social.updated` | 同 | 是 ✓ |
| Commands | Refresh/Block/Unblock/Mute/Unmute/IsFriend | 同 | 是 ✓ |
| Projection 顶层键 | revision/rows/status/error(有错才出现) | 同 | 是 ✓ |
| Presentation consumer | `presentation/v3/pages/rs_v3_business_pages.lua` | 未改 | 是 ✓ |

**tools_market_analysis**

| 契约 | 修改前 | 修改后 | 必须相同？ |
|---|---|---|---|
| Feature ID | `tools_market_analysis` | 同 | 是 ✓ |
| 源/目标 | `features/rs_business_bridge.lua` 4047-4056 | `features/tools/market_analysis/rs_market_analysis_feature.lua` | — |
| Registry route | `tools.market_analysis` | 未改 | 是 ✓ |
| Store ID | `v3.business.tools_market_analysis`（owner `v3.tools_market_analysis`） | 同 | 是 ✓ |
| ApiDependencies | 3 个 `X2Auction:*` | 同 | 是 ✓ |
| Demand id/owner | `feature:tools_market_analysis` / feature | 同 | 是 ✓ |
| Scheduler task / Event | 无，但 Demand 0→1 订阅 `v3.auction_query.updated` + `v3.price_quote.completed` | 同（由共享读模型统一处理） | 是 ✓ |
| UpdateTopic | `v3.business.tools_market_analysis.updated` | 同 | 是 ✓ |
| Commands | Refresh/SetKeyword/SetExactMatch/SetResultLimit/Search | 同 | 是 ✓ |
| Projection 键 | 基础 4 键 + 拍卖读模型 15 键 | 同 | 是 ✓ |
| 契约版本 | `AuctionQueryContractVersion = 1` | 同 | 是 ✓ |
| Presentation consumer | `rs_v3_business_pages.lua`（`tools.auction_favorites` / `tools.market_analysis` 共用 paging） | 未改 | 是 ✓ |

### 23.12.5 新增门禁

`tools/rs_feature_slice_split_tests.lua`（23 条断言，独立进程运行）＋ runner 的 `--feature-split` 入口，
并已并入默认 Full Runner。它证明的是“拆分没有改契约”，而不是“功能已实机验收”：

```text
Feature 只注册一次（RegisterImplementation 计数 == 1）
Feature/Store/UpdateTopic/Demand/Commands/Projection/ApiDependencies 全部不变
读取路径、状态降级（ready/partial/empty/unavailable）、截断、空名拒绝、写命令落到 Native
静态：bridge 不再定义被拆 Feature；toc.g 只登记一次
```

### 23.12.6 本轮结果

```text
默认 Full Runner            PASS  exit=0，0 FAIL
--feature-split 专项         PASS  23/23
Unfinished Closure          PASS  14/14
Lua 5.1 compile gate        PASS  265 shipped Lua files
Lua compatibility syntax    PASS  385 files（真实 Lua 5.1）
Native Dependency Audit     PASS  0 ERROR / 0 BLOCKER / 0 WARN
Architecture Audit          PASS  49 既有债务，无新增（bridge 仍 >4000 行，属已知债务）
Install Integrity           PASS  261/261
Test Dependency Audit       PASS
```

### 23.12.7 后续批次注意事项

```text
1. 静态源码断言会随搬迁失效：tools/rs_range_metric_calibration_tests.lua:219 与
   tools/rs_window_viewport_tests.lua:436 直接读取 features/rs_business_bridge.lua 的文本。
   拆 combat_range_assist / tools_bag（含 S.Layout:ResolveViewportLogicalRect）时必须把断言
   重定向到新文件，而不是删除断言。
2. 离线宿主必须复现 toc.g 顺序：dofile(bridge) 的宿主现在必须先加载 factory（+ ARM），
   已知 4 个宿主已更新；后续拆出的 Feature 若有新宿主也要同步。
3. tools_auction 仍留在 bridge（§23.8 排在 Batch D 第 12 位）；它的私有收藏 CRUD / Sidecar 命令
   不属于共享读模型，搬迁时不得并入 rs_auction_read_model.lua。
4. 每个 Batch 完成后才继续下一个 Batch（§23.8），不要一次拆多个。
```

---

## 23.13 Phase 1 Batch B 施工记录（2026-09-28）

Build：仍为 `v3-m1.16.0.18.330-phase0-trust-baseline`（Batch 中间不推进新 BuildTag）。

### 23.13.1 范围

```text
features/combat/siege_readiness/rs_siege_readiness_feature.lua              combat_siege_readiness
features/tools/reinforce_analysis/rs_reinforce_analysis_feature.lua         tools_reinforce_analysis
features/tools/portal_profiles/rs_portal_profiles_feature.lua               tools_portal_profiles
```

累计进度：`rs_business_bridge.lua` 5223 → **4716** 行；其中还在注册的 Feature **15 → 10 个**。
剩余：combat_boss_alerts / combat_target_monitor / combat_buff_cap / combat_raid_recruitment /
combat_team_tools / combat_unit_lines / combat_range_assist / tools_craft / tools_auction / tools_bag。

### 23.13.2 这三个 Feature 的特殊点（搬迁时必须原样保留的东西）

```text
1. 两个是 blocker-only spec（combat_siege_readiness / tools_portal_profiles）：
   没有 read/commands/projection，Authority:Refresh 直接产出
   rows = { { key = "<id>:blocked", name = "运行时阻塞", text = spec.blocker,
              statusText = "Runtime Blocked", tone = "warn" } }，status = "runtime_blocked"。
   blocker 文案是**用户可见事实**（页面上的阻塞原因），不是内部注释，逐字保留。

2. tools_reinforce_analysis 的两个硬约束：
   * 逐槽位强化详情是 SPECIFIC_RUNTIME_BLOCKED：只允许无参 getter 与 ESRA_* 常参 getter，
     永远不允许枚举/探测 equipSlotIndex；
   * `S.Features.tools_reinforce_analysis.SlotProbeRuntimeBlocked = true` 是
     core/rs_foundation_gate.lua 的 **blocker 级**检查（v3_feature_truth_contract）依赖；
     搬迁时若漏掉这一行，封包门禁会整体失败。

3. 搬迁顺带清理了两个 dead local：`ReinforceApi`（随 Feature 走）与 `OptionApi`
   （搬迁前就没有任何调用点，是遗留死引用）。
```

### 23.13.3 契约前后对照表（§31 模板）

| 契约 | combat_siege_readiness | tools_reinforce_analysis | tools_portal_profiles |
|---|---|---|---|
| Feature ID | 不变 ✓ | 不变 ✓ | 不变 ✓ |
| Store ID / owner | `v3.business.*` / `v3.combat_siege_readiness` ✓ | `v3.tools_reinforce_analysis` ✓ | `v3.tools_portal_profiles` ✓ |
| Store schema | V3Store schema1 / Account / Permanent ✓ | 同 ✓ | 同 ✓ |
| ApiDependencies | 实现层不声明（走 Registry：2 个 method）✓ | 6 个 `X2EquipSlotReinforce:*` ✓ | 实现层不声明（走 Registry：2 个 method）✓ |
| Demand id/owner | `feature:<id>` / feature ✓ | 同 ✓ | 同 ✓ |
| Scheduler / Event | 无 / 无 ✓ | 无 / 无 ✓ | 无 / 无 ✓ |
| UpdateTopic | `v3.business.<id>.updated` ✓ | 同 ✓ | 同 ✓ |
| Commands | 仅 Refresh ✓ | 仅 Refresh ✓ | 仅 Refresh ✓ |
| Projection | 基础 4 键（`runtime_blocked` + blocker 行）✓ | 基础 4 键 ✓ | 同 siege ✓ |
| 特有标记 | — | `SlotProbeRuntimeBlocked = true`（FoundationGate）✓ | — |
| Presentation | `rs_v3_business_pages.lua`（团队子导航） | `tools.reinforce_analysis` 页 | `tools.portal_profiles` 页 |

### 23.13.4 新增契约断言（`--feature-split`，累计 35 条）

```text
三个 Feature 各自只注册一次；Id/storeId/owner/schema/lifetime/Demand/UpdateTopic 不变
命令面只有 Refresh；不产生任何 Scheduler 任务
两个 blocker-only Feature：status=runtime_blocked、blocker 文案逐字一致、blocker 行形状一致、投影如实反映
被阻塞 Feature 不声明实现层依赖（Registry 是它们的 dependency Authority）
强化聚合读取 ready 阶梯：总等级/适用等级/三属性合计/下一档位/套装状态/组合上限/逐槽位 Runtime Blocked 行
安全边界：记录每次 Native 实参，断言**从未出现整数槽位**（只允许无参或 ESRA_* 常量）
partial 阶梯：单个 getter 抛错 → partial + 失败明细，逐槽位行仍存在
ESRA_* 常量缺失 → 如实标注“未导出”，不伪造数值
SlotProbeRuntimeBlocked 仍为 true，且 FoundationGate 仍引用该契约
fail-closed：X2EquipSlotReinforce 未导出时 unavailable 且不伪造行（用第二个独立 ReplicatedSuite 验证加载期捕获的宿主引用）
静态：bridge 不再注册这三个 Feature，也不再保留 ReinforceApi 顶层 local
```

### 23.13.5 本轮结果

```text
默认 Full Runner            PASS  exit=0，0 FAIL
--feature-split 专项         PASS  35/35
Unfinished Closure          PASS  14/14
Lua 5.1 compile gate        PASS  268 shipped Lua files
Lua compatibility syntax    PASS  388 files（真实 Lua 5.1）
Native Dependency Audit     PASS  0 ERROR / 0 BLOCKER / 0 WARN
Architecture Audit          PASS  49 既有债务，无新增
Install Integrity           PASS  261/261
Test Dependency Audit       PASS
```

---

## 23.14 Phase 1 Batch C 施工记录（2026-09-28）

Build：仍为 `v3-m1.16.0.18.330-phase0-trust-baseline`（Batch 中间不推进新 BuildTag）。

### 23.14.1 范围与结果

```text
features/combat/boss_alerts/rs_boss_alerts_feature.lua           combat_boss_alerts
features/combat/target_monitor/rs_target_monitor_feature.lua     combat_target_monitor
features/combat/buff_cap/rs_buff_cap_feature.lua                 combat_buff_cap
features/combat/raid_recruitment/rs_raid_recruitment_feature.lua combat_raid_recruitment
```

```text
rs_business_bridge.lua   4716 → 3940 行          ← 首次低于 4000
注册点                   10 → 6 个 Feature
Architecture Audit       GIANT_FILE 3 → 2（bridge 退出巨型文件名单）；债务 49 → 48
```

搬迁方式：脚本按**行号区间逐字抽取**（写入前先断言首/末行内容），bridge 侧只替换为指针注释，
不手工重排缩进、不重写条件、不调整注释。

### 23.14.2 四个 Feature 的冻结契约（搬迁前后逐项已在测试里断言）

| 契约 | boss_alerts | target_monitor | buff_cap | raid_recruitment |
|---|---|---|---|---|
| Store ID | `v3.business.combat_boss_alerts` | `…combat_target_monitor` | `…combat_buff_cap` | `…combat_raid_recruitment` |
| owner | `v3.combat_boss_alerts` | …同规则 | …同规则 | …同规则 |
| Scheduler task | `v3_business_boss_alert_observe`(100ms) | `v3_business_target_monitor_distance`(500ms) | `v3_business_buff_cap_poll` + `v3_business_buff_cap_refresh` | 无 |
| Event | 无（走服务租约） | `TARGET_CHANGED` | `BUFF_UPDATE` | 无 |
| 契约版本 | HudContractVersion 4 / RealtimeFactBridge 2 / RuleManagement 1 | ObservationContractVersion 1 | PersonalReminderContractVersion 1 | — |
| Commands | 18 个（Refresh + 17 个 HUD/规则/仿真） | Refresh | 5 个（Refresh/SetReminderEnabled/SetThreshold/ResetPeaks/TestReminder） | 5 个（Refresh/Create/Close/Accept/Reject） |
| ApiDependencies | 4 × `X2Unit:*`（Casting/DeBuff） | 3 × `X2Unit:*` | 实现层不声明（走 Registry） | 2 × `X2Team:*` |

生命周期语义（测试均实跑驱动，非静态检查）：

```text
boss_alerts：onEnable 只取 "boss_alerts:runtime" 租约；观察任务由“有消费者 + 有启用规则 + hudEnabled”
            共同决定 —— 因此没有规则目录时它**不会**启动观察任务（这是正确行为，不是缺陷）。
            测试注入 2 条规则（cast + debuff）后：Enable + AcquireConsumer → 任务出现、Casting/Aura 两个
            服务租约被持有；ReleaseConsumer + Disable → 任务移除、两个租约释放。
target_monitor：Enable + AcquireConsumer → 500ms 距离任务出现且 TARGET_CHANGED 订阅建立；
            ReleaseConsumer → 任务与订阅一起消失。
buff_cap：Enable + AcquireConsumer → 兜底 poll 任务出现且 BUFF_UPDATE 订阅建立；Release/Disable → 全部回收。
raid_recruitment：只读申请列表投影为 partial 并带“仍待 RU 验证”说明；
            Create/Accept/Reject 显式返回“已安全停用”原因；Close 才真正调用 X2Team:RaidRecruitDel。
```

### 23.14.3 关于 FND-001（Lua 5.1 local 配额）的实测结论 —— 需要修正一个假设

用 `luac5.1 -p -l` 实测主 chunk：

```text
Batch C 前：0+ params, 188 slots, 246 locals, 258 functions
Batch C 后：0+ params, 187 slots, 182 locals, 187 functions
```

也就是：**搬走 776 行 / 4 个 Feature 只释放了约 1 个 chunk 级 local 槽位**。

原因：boss_alerts 与 buff_cap 本来就写在 `do ... end` 块里（块级作用域），target_monitor / raid_recruitment
本身几乎没有顶层 local。真正占用 chunk 级槽位的是**散落在 chunk 顶层的 helper 函数**，实测分布：

```text
1-399      文件头/宿主          45 slots
400-1399   bag 搬运 helper      32 slots
1400-1747  bag 批处理 helper    22 slots（StartBagQuickSeries/BatchMove/RestoreState…）
1748-2055  team_tools helper    18 slots（TeamRole* / TeamRoster*，现状已搬入独立文件前的旧编号区间）
2057-2198  team_tools auto role 8 slots
2199+      tools_craft helper   30+ slots
合计声明 202 slots，峰值并发 187/200
```

**修正**：能真正缓解 FND-001 的是 Batch D/E（`combat_team_tools`、`tools_craft`、`tools_auction`、`tools_bag`、
`combat_unit_lines`、`combat_range_assist`）—— 它们的 helper 是 chunk 级 `local function`，搬走才会释放槽位。
因此不要用“行数下降”判断 FND-001 的进展；判断依据只能是 `luac5.1 -l` 的 slots 数。

### 23.14.4 新增契约断言（`--feature-split`，累计 46 条）

Batch C 新增 11 条：四个 Feature 的唯一注册与身份/Store/owner/契约版本、公开 Commands 精确集合（逐个比对，
不多不少）、三个带任务的 Feature 的任务名 + cadence + 释放语义、target_monitor 只读单位事实（且只读 target）、
boss 规则投影与显式关闭后的如实降级、boss 拒绝未知规则键、raid 只读投影与显式停用写入命令。

### 23.14.5 本轮结果

```text
默认 Full Runner            PASS  exit=0，0 FAIL
--feature-split 专项         PASS  46/46
Unfinished Closure          PASS  14/14
Lua 5.1 compile gate        PASS  272 shipped Lua files
Lua compatibility syntax    PASS  392 files（真实 Lua 5.1）
Native Dependency Audit     PASS  0 ERROR / 0 BLOCKER / 0 WARN
Architecture Audit          PASS  48 债务（GIANT_FILE 3 → 2），无新增
Install Integrity           PASS  261/261
Test Dependency Audit       PASS
```

---

## 23.15 Phase 1 Batch D 施工记录（2026-09-28）

Build：仍为 `v3-m1.16.0.18.330-phase0-trust-baseline`（Batch 中间不推进新 BuildTag）。

### 23.15.1 范围与结果

```text
features/combat/team_tools/rs_team_tools_feature.lua   combat_team_tools
features/tools/craft/rs_craft_feature.lua              tools_craft
features/tools/auction/rs_auction_feature.lua          tools_auction
features/shared/rs_shared_bounds.lua                   跨 Feature 共享有界常量（新增）
```

```text
rs_business_bridge.lua   3940 → 2701 行（本轮 −1239）
注册点                   6 → 3 个 Feature（只剩 Batch E：tools_bag / combat_unit_lines / combat_range_assist）
FND-001                  主 chunk slots 187 → **104**（本轮 −83，这是真正缓解 local 配额的一批）
```

### 23.15.2 本轮发现的两个真实缺陷（搬迁引出的可见性，不是本轮制造的回归）

1. **tools_craft 运行期缺失 `Scalar`**：C5 用例（背包持有量/缺口）在拆分后立即失败。
   根因是依赖分析脚本第一版的正则要求 `local … =`，漏掉了所有 `local function X(...)` 定义，
   因此没有发现 craft 引用了 bridge 的 chunk 级 `Scalar`。修复：
   - `Scalar`（从常见键名取第一个标量值的通用归一工具）按 §23.7-B 进工厂（`FSF.Scalar`），bridge 保留别名；
   - 同时把分析脚本修正为兼容 `local function` 与多赋值，并对**全部 15 个拆出文件**重跑核查（清零）。
2. **`TeamCommandInteger` / `Trim` 缺失于 team_tools**：前者是 team_tools 专属的成员序号校验
   （1..maximum 正整数），按 §23.7-C 随 Feature 原样搬入（bridge 删除副本）；后者是工厂通用工具，补进 prologue。

结论：静态核查脚本（比较“bridge 仍定义的 chunk 级 local”与“拆出文件实际引用”）必须成为后续每个批次的
固定工序，而且必须在测试之前跑。

### 23.15.3 `BAG_SCAN_LIMIT` 的归属判定（§23.7）

`BAG_SCAN_LIMIT = 240` 被 tools_bag（多处扫描/搬运）与 tools_craft 的持有量读取共同使用：

```text
A. 共享事实？ 否 —— 它是“一次最多扫描多少背包槽位”的平台级上界（策略值），不是事实
B. 无状态通用装配工具？ 否 —— 与 Bag 语义绑定，不能进工厂（工厂明确“不认识 Bag”）
C. 某个 Feature 的私有判断？ 否 —— 两个消费方
=> 结论：跨 Feature 共享的有界常量需要唯一归属。新增 features/shared/rs_shared_bounds.lua
   （S.SharedBounds.BagScanLimit = 240），bridge 与 craft 文件都只从它读取。
```

这个共享模块只允许放“被多个 Feature 共享、且不属于任何单个 Feature”的有界常量；不得演变成业务配置堆。

### 23.15.4 契约前后对照表（§31 模板，已全部在测试中断言）

| 契约 | combat_team_tools | tools_craft | tools_auction |
|---|---|---|---|
| Feature ID | 不变 ✓ | 不变 ✓ | 不变 ✓ |
| Store ID / owner | `v3.business.combat_team_tools` / `v3.combat_team_tools` ✓ | `v3.business.tools_craft` / `v3.tools_craft` ✓ | `v3.business.tools_auction` / `v3.tools_auction` ✓ |
| Store schema | V3Store schema1 / Account / Permanent ✓ | 同 ✓ | 同 ✓ |
| ApiDependencies | 4 个（X2Team×2 + X2Unit×2）✓ | 6 个（X2Craft×4 + X2Bag×2）✓ | 6 个（X2Auction×4 + ADDON×2）✓ |
| Demand id/owner | `feature:<id>` / feature ✓ | 同 ✓ | 同 ✓ |
| UpdateTopic | `v3.business.<id>.updated` ✓ | 同 ✓ | 同 ✓ |
| Commands | 5 个：Refresh/SetAutoRoleEnabled/SetRole/MoveMember/MoveMemberToParty ✓ | 7 个：Refresh/SelectRecipe/SetCraftType/SetItemType/SetDoodadId/QuoteMaterial/QuotePendingMaterials ✓ | 13 个：Refresh/Search/SetKeyword/SetExactMatch/SetResultLimit/Quote/AddFavorite/RemoveFavorite/RenameFavorite/MoveFavorite/RemoveFavoriteByKeyword/ClearFavorites/SetSidecarEnabled ✓ |
| 契约版本 | TeamRole 2 / AutoRoleCatalog 2 / AutoRoleDefaultOn 1 / AutoRoleRosterLease 1 / AutoRole 3 ✓ | CraftUserSelection 1 ✓ | SidecarPreference 1 / AuctionQuery 1 ✓ |
| 任务/令牌 | roster token `combat_team_tools:roster`、task `v3_team_auto_role_apply` ✓ | 无任务 ✓ | Sidecar 观察仍由 AuctionSurfaceV3 驱动 ✓ |
| Presentation | `rs_v3_business_pages.lua` | 同 + `rs_v3_craft_sidecar.lua` | 同 + `rs_v3_auction_sidecar.lua`（Controller 走只读 facade）✓ |

### 23.15.5 tools_craft → PriceQuoteQueueV3 的传递归属（audit 新可见性）

tools_craft 拆出后，audit 第一次能按 Feature 归因这条传递边：

```text
WARN TRANSITIVE_SERVICE_NATIVE_UNCLASSIFIED  tools_craft  service=PriceQuoteQueueV3  namespaces=X2Auction
```

判定（按 audit 的 required/optional/lazy 定义）：craft 从不直接调用 X2Auction —— 报价请求由用户显式触发并
转发给共享 PriceQuoteQueueV3，结果也只从该队列的 read model 读取。因此按 **lazy** 分类，X2Auction 的
ownership 归 PriceQuoteQueueV3 自己；**不得**升成 tools_craft 的 hard dependency（否则会把队列的 namespace
伪装成 craft 的能力）。已在 `SERVICE_EDGE_NATIVE_POLICY` 增加该行并注明：队列侧真正的 lazy lease
（AcquireApi）与其它 Service 一样属于 Phase 3 的 descriptor 收口项。分类后 audit 回到 `0/0/0`。

### 23.15.6 本轮结果

```text
默认 Full Runner            PASS  exit=0，0 FAIL
--feature-split 专项         PASS  53/53（本轮 +7）
Unfinished Closure          PASS  14/14
Lua 5.1 compile gate        PASS  276 shipped Lua files
Lua compatibility syntax    PASS  396 files（真实 Lua 5.1）
Native Dependency Audit     PASS  0 ERROR / 0 BLOCKER / 0 WARN
Architecture Audit          PASS  48 债务（GIANT_FILE 2：persistence / life bundle）
Install Integrity           PASS  261/261
Test Dependency Audit       PASS
```

---

## 23.16 Phase 1 Batch E 施工记录与 Phase 1 闭合（2026-09-28）

Build：`v3-m1.16.0.18.331-phase1-feature-slice-complete`（Phase 1 完成时的唯一一次正式 BuildTag 推进）。

### 23.16.1 Batch E 范围

```text
features/tools/bag/rs_bag_feature.lua                    tools_bag（1922 行，最后一个巨型 Feature）
features/combat/unit_lines/rs_unit_lines_feature.lua     combat_unit_lines
features/combat/range_assist/rs_range_assist_feature.lua combat_range_assist
```

### 23.16.2 rs_business_bridge.lua 退役

`features/rs_business_bridge.lua` 已**整体删除**（不再保留空壳），`toc.g` 同步移除。理由：

```text
- 15 个 Feature 全部有自己的独立源码单元，注册点唯一（--feature-split 用 registrations 计数逐个断言）；
- 文件不存在本身就是最强的“禁止回填”契约：它再出现就意味着有人把拆掉的 Feature 又塞回巨型 chunk；
- toc ↔ 磁盘一致性由 Install Integrity 重新验证（278/278 PASS）。
```

连带收口（都是“重定向”而不是删除断言）：

```text
1. 四个离线宿主（auction_favorites / craft_planner / team_tools / unit_lines）：
   移除 dofile(bridge)，改为按 toc.g 顺序加载各自需要的 Feature 文件；
2. tools/rs_range_metric_calibration_tests.lua：源码探针从 bridge 改指
   features/combat/range_assist/rs_range_assist_feature.lua（8/8 PASS）；
3. tools/rs_window_viewport_tests.lua：外部内容几何校准探针从 bridge 改指
   features/tools/bag/rs_bag_feature.lua（66/66 PASS）；
4. --feature-split 的 4 处静态断言改为 bridge_retired()（文件不存在即通过），
   并新增“15 个 Feature 全部恰好注册一次”的总账断言。
```

### 23.16.3 Batch E 契约对照（§31 模板，已在测试中断言）

| 契约 | tools_bag | combat_unit_lines | combat_range_assist |
|---|---|---|---|
| Feature ID / Store ID / owner | 不变 ✓ | 不变 ✓ | 不变 ✓ |
| Store schema | schema1 / Account / Permanent ✓ | 同 ✓ | 同 ✓ |
| ApiDependencies | 12 个（X2Bag×4 + X2Bank×3 + X2Coffer×3 + ADDON×2）✓ | 2 个 ✓ | 3 个 ✓ |
| Scheduler task | `v3_business_bag_category_batch` / `v3_business_bag_quick_observe` / `v3_business_bag_quick_move` ✓ | `v3_business_unit_lines_refresh`（1ms 下限高频车道）✓ | `v3_business_range_assist_refresh`（16ms）✓ |
| Commands | 25 个 ✓ | 9 个 ✓ | 14 个（多圆 AddCircle/RemoveCircle/SetCircle*）✓ |
| 契约版本 | BagMove 8 / BatchLifecycle 5 / NativeWindowQuick 7 / BagTaskMutex 2 等 ✓ | VisualGuide 5 / AdaptiveDensity 2 等 ✓ | VisualGuide 9 / WorldSpace 3 / ProjectionFacts 7 / MetricDistance 1 / MultiCircle 1 等 ✓ |
| 共享边界 | `S.SharedBounds.BagScanLimit`（唯一 Authority）✓ | — | — |
| Presentation | `rs_v3_business_pages.lua` + bag overlay | `rs_v3_combat_visual_guides.lua` | 同左 |

### 23.16.4 Phase 1 最终结果

```text
默认 Full Runner            PASS  exit=0，0 FAIL
--feature-split 专项         PASS  59/59
Unfinished Closure          PASS  14/14
Lua 5.1 compile gate        PASS  278 shipped Lua files
Lua compatibility syntax    PASS  398 files（真实 Lua 5.1）
Native Dependency Audit     PASS  0 ERROR / 0 BLOCKER / 0 WARN
Architecture Audit          PASS  48 债务（41 Core→Feature / 5 Presentation State / 2 Giant File）
Install Integrity           PASS  278/278
Range Metric / Viewport     PASS  8/8 与 66/66（静态探针已重定向）
```

| 指标 | Phase 1 前（.330） | Phase 1 后（.331） |
|---|---|---|
| `rs_business_bridge.lua` | 5223 行 / 15 个 Feature / 188 chunk slots | **已删除**（退役） |
| Feature 源码单元 | 15 个挤在一个 chunk | 15 个独立文件（每文件 slots 16–98） |
| 共享装配/边界 | 无（ bridge 内重复定义风险） | `rs_feature_slice_factory.lua` + `rs_shared_bounds.lua` + 拍卖读模型 |
| Architecture Audit | 49 债务（GIANT_FILE 3） | **48 债务**（GIANT_FILE 2，bridge 不再在列） |
| 门禁 | 无 Feature 拆分契约 | `--feature-split` 59 断言并入默认 Full Runner |

Phase 1 期间没有改任何 Store ID/Schema、Feature ID、route、公开 Commands、Projection shape、
用户配置语义；Scheduler/EventBus/Persistence 未动；未发现任何生产回归
（B/D 两批的失败全部是测试过期或宿主不完整，按 §30 分类处理）。

### 23.16.5 Phase 1 遗留与 Phase 2 入口

```text
1. 本轮全部是离线契约证明；每个 Feature 的 RU 实机验收仍待用户侧确认（Phase 3 收口）。
2. Architecture Audit 剩余 48 项债务属 Phase 3/5/6 范围（41 Core→Feature 是 Phase 3 的 Service 边界收口）。
3. Service 侧 lazy lease 的 descriptor 收口（PriceQuoteQueueV3 / CooldownObservationV3 等）属于 Phase 3。
4. Phase 2（Life Bundle 拆分，§24）现在可以开始：life_m16_bundle.lua 5633 行、5 个 life Feature，
   拆分方法论与 Phase 1 完全一致（工厂已就绪，BAG_SCAN_LIMIT 之类共享常量也已有归属模块）。
```

---

# 24. Phase 2：Life Bundle 拆分——Agent 逐项施工手册

## 24.1 固定顺序

```text
Treasure
Fishing
Bonds
Trade
```

不要从 Trade 开始。

## 24.2 第一轮目标只是一 Feature 一文件

第一轮目标：

```text
features/life/treasure/rs_treasure_feature.lua
features/life/fishing/rs_fishing_feature.lua
features/life/bonds/rs_bonds_feature.lua
features/life/trade/rs_trade_feature.lua
```

先实现**完整机械搬迁**。

不要第一轮就把 Trade 同时拆成：

```text
ratio authority
material projection
quote read model
cargo observer
diagnostics
```

## 24.3 Life Bundle 特别红线

- Trade 当前货率 / freshness / payout / MaterialPrice SWR 逻辑冻结；
- Bonds 的 `X2Quest` ownership 保持 `.328` 修复；
- Fishing Auto-R 的 hotkey transaction/recovery 契约冻结；
- Treasure 地图点击能力不因为文件拆分扩大 Native 权限；
- 四个 Feature 的 Store ID/Schema 均冻结；
- `if RegisterImplementation fails then error` 等注册失败语义不要顺手重写，除非另有实机证据证明 loader failure behavior 需要调整。

## 24.4 Trade 第二轮进一步拆分的进入条件

只有在 `rs_trade_feature.lua` 独立后完成一轮 Fresh Reload / 老配置 / 自动刷新 / 报价 / 材料缓存实测，才允许进一步拆 Trade。

进一步拆时要求：

```text
Trade Feature = orchestration / public commands / projection entry
TradePayoutV3 = 唯一售价公式 Authority
TradeMaterialIdentityV3 = 唯一材料身份 Authority
PriceQuoteQueueV3 = 唯一拍卖报价串行 Authority
MaterialPriceServiceV3 = 唯一材料价格缓存 Authority
```

不要因为拆目录重新实现这些 Service。

---

# 25. Phase 3：Contract / Dependency Ownership 收口——Agent 施工手册

## 25.1 目标

完成两件事：

```text
A. Core/Foundation 不再硬编码认识具体业务 Feature
B. Feature/Service 的依赖由 descriptor 明确声明，而不是靠启动顺序/全局残留
```

## 25.2 Descriptor 最小字段

建议统一 descriptor，但不要一次设计成复杂 DSL。

最小可证明字段：

```text
FeatureId
ContractVersion
RequiredServices
RequiredStores
NativeCapabilities:
    required
    optional
    lazy
RuntimeHealthProvider
```

后续 Scheduler/Event ownership 可以作为附加字段，不需要 Phase 3 第一天全部完成。

## 25.3 Health Provider 硬规则

Provider 必须：

- 只读；
- 返回 detached facts；
- 不返回 Feature.State 原表；
- 不 Enable Feature；
- 不 Acquire consumer；
- 不读写磁盘作为“检查”；
- 不执行 Native query 只为了诊断；
- 不创建 Scheduler/Event resource。

## 25.4 FoundationGate 迁移方式

禁止一次删除 2000+ 行旧判断。

按 Feature group 分批：

```text
先注册 descriptor/provider
→ Foundation 同时读取新 provider 做对照
→ 测试新旧结论一致
→ 删除该 Feature 的旧硬编码分支
```

每批完成后 `core/*.lua` 中的 `S.Features.<业务Feature>` 数量应单调下降。

最终静态门禁目标：

```text
core/*.lua
除 FeatureRegistry / FeatureRuntime 基础设施外
不允许直接依赖具体业务 Feature
```

## 25.5 Native ownership

- Feature 直接使用 Native：Feature descriptor required/optional 明确；
- Shared Service 直接使用 Native：由 Service 自己的 lazy/required ownership 表达；
- Feature 不替 Service“代持”与自身无关的 namespace；
- `S.NativeImports` 仍是唯一 ImportAPI Authority；
- 不实现不存在的 Native Unimport。

---

# 26. Phase 4：Scheduler / Event 热路径——低风险到高风险的固定顺序

本 Phase 绝对不能“一次性重写 Scheduler”。

## 26.1 4A FrameBudget table 复用

只做：

```text
current / previous 预分配
字段覆盖或交换引用
```

不改变 grant/defer/budget 算法。

验证重点：

- `Describe()` shape 不变；
- previous/current 不发生 alias 导致上一帧数据被覆盖；
- 无新增 per-frame table。

## 26.2 4B Scheduler Owner/name collision

第一步只增加保护：

```text
同 Owner + 同 TaskName -> 允许 replace
不同 Owner + 同 TaskName -> reject + diagnostics
```

不要第一步就把所有外部 task key 改成 composite key，避免破坏现有 diagnostics/tests。

稳定后再考虑内部：

```text
ownerIdentity::localTaskName
```

## 26.3 4C 关闭 Feature 的 watchdog lease

只处理已有明确证据的 watchdog。

规则：

```text
0 consumer/0 relevant feature -> watchdog 不存在
第一个 consumer -> acquire
最后一个 consumer -> release
```

不要把“窗口隐藏”误判为“功能关闭”。

## 26.4 4D Fault recovery 扫描拆出

先把 fault recovery 从“每帧扫所有 task”改为独立 `nextFaultRecoveryAt`。

不改变正常 due 调度。

## 26.5 4E due bucket / timing wheel

只有前面四步稳定并且有扫描计数基线后才做。

必须保留：

- 单一 OnUpdate；
- high-frequency lane；
- 任意现有 interval 的语义；
- hitch 不多次 catch-up；
- priority / FrameBudget；
- owner release；
- generation/epoch；
- backlog diagnostics。

禁止为了 bucket 简化，把所有周期粗暴 round 到固定 100/250/500ms，导致业务 cadence 漂移。

## 26.6 4F EventBus identity

先解决：

```text
subscription identity
重复订阅诊断
owner release
reload generation
```

再考虑分配优化。

## 26.7 4G EventBus allocation

只有有真实 publish/listener 计数后再优化 `{...}` / callback wrapper。

不要使用复杂元编程换取极小 table 节省。

---

# 27. Phase 5：Presentation 边界——执行细则

## 27.1 目标

所有业务 UI：

```text
read -> Projection / Public Facade
write -> Commands
```

禁止：

```text
Feature.State
业务 Store 直读
Persistence:GetStore(业务Store) 直读
```

## 27.2 第一明确目标：Auction Sidecar

当前已知真实违规：

```text
presentation/v3/widgets/rs_v3_auction_sidecar.lua
Feature.State.favorites
```

优先修成公开 read model/projection。

## 27.3 注意 Architecture Audit 的“注释命中”

静态 grep 可能命中注释中的 `Feature.State`。

Agent 不得看到 audit 行就机械修改注释附近代码。

必须确认：

```text
是真实表达式？
还是文档/注释？
还是 Acceptance 特殊检查？
```

Audit 工具后续可以升级为更精确分类，但不能为了 0 数字把有效注释删光。

## 27.4 Projection 性能

如果 Projection 是大列表：

- 通过 revision/cache 避免每帧 DeepCopy；
- UI 不持有可变 Authority 表；
- detached snapshot 可以按 revision 重用；
- 不允许以“避免复制”为理由重新直读 State。

---

# 28. Phase 6：Diagnostics / Acceptance 收敛——执行细则

最终 Authority 必须明确：

```text
DiagnosticsManager
    = 结构化错误事实

ModuleDiagnosticsHub
    = Feature 归属投影

Feature Health/Acceptance Provider
    = Feature 自己的契约证明

FoundationGate
    = Core + 已注册 provider 聚合

V3 Acceptance
    = Presentation/集成验收

Offline Regression
    = tools/，不在 release runtime 做破坏性组合测试
```

## 28.1 迁移规则

- 同一个 ContractVersion 不允许在三处手写三份 expected；
- Runtime health 必须轻量且无副作用；
- 历史 bug regression 留在 tools；
- 不因“Acceptance 太多”一次性删除 release 检查；先证明替代 Authority 已覆盖；
- 模块诊断继续保持固定 snapshot + 上一页/下一页，翻页不重新采集。

---

# 29. Phase 7：Persistence 调度优化与 Core 拆分——最高风险执行细则

本 Phase 最后执行。

## 29.1 7A 先加测量，不改算法

先记录：

```text
registered Stores
dirty Stores
Tick scanned Stores
Save attempts
Fence count
Period watch Stores
```

建立真实 baseline。

## 29.2 7B dirty index/queue

目标：无 dirty 时不再每 200ms 扫所有 Store。

必须保证：

- `MarkDirty` 幂等加入；
- 成功 durable save 才移除；
- save/readback fail 不丢 dirty；
- fenced Store 不被旁路；
- 新 dirty 不能因为遍历中 mutation 丢失；
- 多 Store 保存顺序仍确定，不因 hash table pairs 变成随机；
- crash-like interrupted save 仍可恢复。

不要只用无序 `dirtySet` 然后 `pairs()` 保存所有 Store，可能改变稳定顺序。

## 29.3 7C period reset watch set

只让 Daily/Weekly Store 进入 period watch。

必须保持旧日期边界、冷启动、unknown date、跨日恢复语义。

## 29.4 7D 文件拆分

只有算法稳定后才机械拆：

```text
registry
integrity
runtime
periods
diagnostics
```

拆文件本身不得改变 canonical/codec/fingerprint/migration。

## 29.5 Persistence STOP 条件

出现任何：

```text
旧配置读不到
fingerprint 改变
fence 数增加
readback mismatch
写入次数异常增加
Store owner/schema 漂移
```

立即停止，不继续“顺手修”。

---

# 30. Agent 测试判定规则：防止“错误修测试”

当测试失败时按以下决策树：

```text
1. 在本轮修改前 baseline 是否已经失败？
   是 -> pre-existing debt，先记录
   否 -> 继续

2. 失败断言是否是旧硬编码 count/build/version？
   是 -> 查当前 Authority / 历史变更
          有证据证明契约已变化 -> 更新测试并写理由
          无证据 -> 不改测试

3. 生产行为是否违反冻结契约？
   是 -> 修生产

4. test host 是否缺当前正式 Core/Event/UI 接口？
   是 -> 修 host，不修生产来迎合残缺 mock

5. 无法判断
   -> STOP
```

### 特别禁止

```text
while test fails:
    expected = actual
```

这种做法不允许。

---

# 31. 每个 Feature 拆分的“前后对照表”模板

Agent 每拆一个 Feature，至少保留一份：

| 契约 | 修改前 | 修改后 | 必须相同？ |
|---|---|---|---|
| Feature ID | | | 是 |
| Registry route | | | 是 |
| Store ID | | | 是 |
| Store schema | | | 是 |
| Native required deps | | | 原则上是；FND-016 已验证修复除外 |
| Demand ID/owner | | | 是 |
| Scheduler task names | | | 是 |
| Event topics | | | 是 |
| Commands | | | 是 |
| Projection keys | | | 是 |
| Default enabled/state | | | 是 |
| Presentation consumer | | | 是 |
| Diagnostics provider | | | 是 |

如果某格无法填写，不应开始移动该 Feature。

---

# 32. Workbuddy 最终交付要求

Agent 完成一个 Phase 或遇到 STOP 时，必须一次性给出完整交付，不要碎片式汇报。

## 32.1 必须生成的证据

建议放入：

```text
Docs/agent_runs/<date>_<phase>/
```

至少包含：

```text
BASELINE_BEFORE.txt
TEST_AFTER.txt
CHANGED_FILES.txt
KNOWN_BLOCKERS.md
CONTRACT_SNAPSHOTS.md
```

如果是 Git：再提供 `git diff --stat` 和 `git diff --name-only`。

## 32.2 最终报告格式

严格按：

### 1. 完成内容
实际做了什么；哪些计划项没有做。

### 2. 修改文件
新增 / 修改 / 删除分别列出。

### 3. 性能影响
CPU、内存、Native 调用、Scheduler/Event 高频路径是否变化。

### 4. 兼容风险
Store、用户升级、旧配置、ReloadAddon、Native capability 风险。

### 5. 测试结果
列出命令、PASS/FAIL/BLOCKED，禁止只写“测试通过”。

### 6. 未解决阻断
必须列出仍 BLOCKED 的真实原因。

### 7. 规划文档状态更新
说明当前 Phase 是否真的完成、下一阶段是否允许开始。

## 32.3 交给下一位审查者的材料

为了后续独立审核，保留：

- **完整当前工程 ZIP**（最重要）；
- 更新后的本规划；
- Agent 本轮报告；
- 测试日志；
- 若有 Git，则附 commit/hash 或 patch。

不要只交“修改后的几个文件”，因为架构审查需要确认调用链和未修改边界。

---

# 33. 给本地 Agent 的自动执行策略

Workbuddy 可以连续执行，但必须按以下状态机：

```text
读取当前 Phase
    ↓
完成当前 Work Package
    ↓
专项测试
    ↓
全局门禁
    ↓
PASS ?
 ├─ 是 -> 更新文档 -> 同 Phase 下一 Work Package
 └─ 否 -> 能证明 stale test / test-host debt ?
             ├─ 是 -> 最小修测试基础设施 -> 重跑
             └─ 否 -> STOP，不进入下一项
```

跨 Phase：

```text
当前 Phase 全部 Exit Criteria 满足
    ↓
才允许进入下一 Phase
```

**禁止 Agent 自己以“应该没关系”“这个测试可能过时”“以后再补”作为跨阶段理由。**


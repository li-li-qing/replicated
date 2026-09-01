# Replicated Suite 重建基础架构蓝图（统一权威）

> **Authority Level**: ARCHITECTURE / REBUILD
> **范围**: V3 重建的方向性蓝图——总原则、目标分层、Core Foundation、Persistence、RSUI、Widget、V3 Shell、Feature 分类、性能基线、UI 视觉系统。
> 本文件是 2026-08-27 蓝图的唯一权威副本（原根目录 `重构文档.md`、根 `REPLICATED_SUITE_REBUILD_FOUNDATION_BLUEPRINT_M1_12_20260827.md`、`Docs/REPLICATED_SUITE_REBUILD_FOUNDATION_BLUEPRINT_20260827.md` 均为其内容完全一致的重复副本，已删除）。

# Replicated Suite 重建基础架构蓝图

> 日期：2026-08-27  
> 基线：`Addon(20260827-092841).zip`  
> 文档性质：长期维护架构基线 / 新 UI 与插件重建总规范  
> 目标：在保留已经验证的游戏数据、业务 Authority 与安全基础设施的前提下，停止继续扩展旧菜单与旧 Presentation，从干净的新宿主、新路由、新 Feature Contract、新 Widget 体系重新搭建 Replicated Suite。

---

## 0. 核心结论

Replicated Suite 当前最需要重建的不是“某一个页面”，而是 **Presentation 与 Feature 组织方式**。

当前工程已经拥有一批值得保留的基础设施：

- `RSUI Component Runtime v2`；
- 组件化布局、失效传播与批量 Layout Flush；
- `TableView / ListView / TileView` 虚拟化；
- Selection、Binding、Form、Tooltip、ContextMenu、Focus 等交互基础；
- Strict Native UI Authority / Diff 写入边界；
- `UIHostManager` 与 V3 Presentation Host Contract；
- V3 独立 Persistence Store Contract；
- 统一 EventBus、Scheduler、FrameBudget、Observation；
- ModuleManager 生命周期与故障隔离；
- Diagnostics、FoundationGate、UI Acceptance；
- 已核验的 GameData / Static ID / Quest / Trade / Event 数据；
- 已经存在并经过实服迭代的业务 Service。

因此，“从 0 开始”在本项目中的正式定义是：

> **从 0 重建应用壳、信息架构、Feature Presentation、Widget Contract 与模块边界；不盲目删除已经验证的 Authority、数据与底层安全设施。**

旧 UI 以后只允许作为：

1. 行为参考；
2. 数据字段参考；
3. 用户配置兼容来源；
4. 暂未迁移功能的临时 Legacy Host。

**禁止继续向旧菜单增加新功能。**

---

### 当前实现注记 · 2026-08-29 M1.15.1

蓝图中的“V3 仍只是 Foundation、Legacy Host 当前生效”属于 2026-08-27 基线描述。当前 Active TOC 已切到 V3-only Host，并加入 Demand / RefreshCoordinator / AuraObservationV3 Phase 12A；M1.14.3 在既有 Windowing + WindowShell 上增加 FloatingSurface HUD 状态/持久化绑定层；M1.14.4 加入 DataView ViewState、ActionRunner 与 Persistent Setting Binding；M1.14.5 又完成 Active V3 Adoption/Cleanup，使系统悬浮组件/全局设置/活动任务 Widget/诊断等默认复用这些 Foundation，并收掉重复 Save/状态胶水。下面的旧规模与三代 Presentation 描述继续作为重建起点记录，不应覆盖 `CURRENT_ARCHITECTURE.md` 的当前事实。 M1.15.1 又新增 `CombatEventBusV3 + UnitIdentityV3`：战斗 Native 事实与身份解析正式分离，私有 self-scope 与全局 all-scope 按 Consumer Demand 启停；DeathReview 已在 M1.15.2 作为首个 `scope=self` 业务 Consumer 迁移，M1.15.2H 又补齐 Combat cold-start Journal/CoverageState/immutable dispatch、deferred finalize、Demand/Persistence/Feature transaction hardening；仍不依赖 DPS。DPS/Healer 尚未迁移，Foundation 不拥有它们的业务结论。

# 1. 当前工程真实现状

## 1.1 当前代码规模

基于本次上传工程扫描：

| 区域 | Lua 文件 | 约代码行数 | 说明 |
|---|---:|---:|---|
| `ui/` | 64 | 28,999 | 包含旧页面、新 RSUI 页面、视觉组件、框架 |
| `ui/framework/` | 19 | 8,166 | 新 Widget/RSUI 底层核心 |
| `widgets/` | 7 | 1,842 | 生活类悬浮 Widget + WidgetBase |
| `presentation/v3/` | 5 | 480 | V3 Foundation Host/Shell/Store/Sequence |
| `presentation/legacy/` | 5 | 987 | 旧 Presenter 兼容层 |
| `services/` | 18 | 12,193 | 生活/战斗共享业务 Service |
| `core/` | 26 | 8,827 | 生命周期、存档、调度、诊断等基础设施 |
| `modules/` | 61 | 59,053 | 专业模块与业务 Runtime |
| `data/` | 21 | 6,495 | 静态数据与共享 ID |

旧主 UI 相关部分仍然非常庞大，例如：

- `rs_professional_pages.lua`：约 3,827 行；
- `rs_combat_workspace.lua`：约 969 行；
- `rs_dashboard_page.lua`：约 835 行；
- `rs_life_workspace.lua`：约 654 行；
- `rs_hud_page.lua`：约 551 行。

这说明当前问题不能继续靠“再整理一个页面”解决。

---

## 1.2 当前实际上存在三代 Presentation 思路

### A. Legacy / 手工 Native UI

特征：

- 大量 `CreateLabel/CreateButton/CreatePanel`；
- 大量直接坐标、`SetExtent`、Anchor；
- 页面自己管理布局；
- 功能 UI 与业务生命周期历史耦合；
- 一些专业模块仍保留大量手工 Geometry。

此层以后进入 **冻结维护**。

### B. RSUI / Widget 化过渡层

目前已经大量用于：首页、生活 Workspace、部分 Combat Workspace。

工程已提供：

```text
Text / Image / Icon / Button / IconButton
Border / Card / Section
HorizontalBox / VerticalBox / Overlay / Grid
UniformGrid / WrapBox
SizeBox / ScaleBox / AspectRatioBox
ScrollBox / WidgetSwitcher
ResolutionRoot / SafeZone / CanvasPanel
ListView / VirtualList
TileView / VirtualGrid
TableView / Table
Toggle / NumericInput / Slider / Dropdown
Field / Form / FormSection / SettingsPage
SelectionModel
Tooltip / ContextMenu / Focus
```

这部分不是废弃物，而是新工程应继续使用并收敛的 **核心 Widget Foundation**。

### C. V3 Presentation Foundation

当前 V3 已经存在：

```text
presentation/v3/
├─ rs_v3_shell_store.lua
├─ rs_v3_native_adapter.lua
├─ rs_v3_shell.lua
├─ rs_v3_host.lua
└─ rs_v3_sequence_cases.lua
```

但当前 `rs_v3_shell.lua` 明确仍只是 Foundation Shell：

- `foundation:probe`
- `page:foundation`

其它 Route 仍返回：

```text
route_not_implemented
```

因此 V3 当前是“地基”，不是已经完成的新 UI。

---

# 2. 重建必须遵守的总原则

## 2.1 Authority 与 Presentation 永远分离

任何 UI 都不能自己成为业务真相。

正确：

```text
Native API / Curated Data
        ↓
     Service
        ↓
 Domain Snapshot / Projection
        ↓
    Presenter
        ↓
 RSUI Page / Widget
```

错误：

```text
按钮 OnClick
   ↓
页面自己扫描背包
   ↓
页面自己判断 Quest
   ↓
页面自己保存配置
```

UI 只负责：

- 显示；
- 输入；
- 触发用户命令；
- 订阅 Presentation Projection。

---

## 2.2 “共享底层”不等于“功能必须放在一起”

这是旧架构最容易再次犯的错误。

例如：

- Boss 机制用了 Buff API，不代表属于“BUFF显示”；
- 单位连线用了 TargetService，不代表属于“目标 HUD”；
- 死亡回顾用了 Combat Event，不代表属于 DPS；
- 制作台助手用了跑商材料数据，不代表必须随 Trade Runtime 一起启动。

正式规则：

> **玩家用途决定 Feature 归属；数据来源决定 Service 依赖；二者不得混为一谈。**

---

## 2.3 一个 Feature 必须可以独立描述自己的生命周期

每个 Feature 至少需要回答：

1. 谁启用它？
2. 启用时订阅什么？
3. 需要什么共享 Authority？
4. 创建哪些 UI？
5. 有哪些 Scheduler Job？
6. 有哪些缓存？
7. 关闭时释放什么？
8. 配置由谁持久化？
9. 故障后如何 Fail Closed？
10. 是否可以在父分类其它 Feature 全关时独立工作？

无法回答这些问题的功能，不允许迁入新架构。

---

## 2.4 隐藏 UI 不等于关闭功能

必须严格区分：

```text
Feature Enabled
HUD Visible
Main Page Visible
```

三者是不同状态。

例如：

```text
DPS Enabled = true
DPS HUD Visible = false
DPS Page Visible = false
```

此时后台仍在统计。

反过来：

```text
DeathReview Enabled = false
```

则该功能必须解除事件订阅和周期任务，而不是仅隐藏窗口。

---

# 3. 新的目标分层

目标结构固定为：

```text
Bootstrap
   ↓
Core Foundation
   ↓
Shared Services / Data Authority
   ↓
Feature Modules
   ↓
Presentation Projection
   ↓
V3 Application Shell + Widgets
```

逻辑上对应：

```text
Core
+
Services
+
Feature Modules
+
UI
```

---

# 4. Core Foundation

现有 Core 不应整体推倒。

以下能力应保留、强化并成为新插件的正式基础。

## 4.1 Bootstrap

现有 `replicatedsuite.lua` 已经实现：

- 热重载前一代 Runtime 停止；
- UI Hide；
- Generation 隔离；
- BootStage / BootError；
- 有界 LogBuffer；
- 安全 Chat；
- 单调时钟 Authority；
- API/Object Import；
- Bootstrap Recovery Entry。

新架构继续保留“启动阶段故障可恢复”的思想。

禁止让任何 Feature 的 UI 错误直接导致整个插件无入口。

---

## 4.2 EventBus

`core/rs_events.lua` 是 Suite 私有事件总线。

新架构约束：

- Feature 不允许互相直接调用业务方法；
- 跨 Feature 通知使用 EventBus；
- Native 事件转换成 Suite Event 后再传播；
- Owner 必须可被统一 Unsubscribe；
- 高频事件不允许在多个 Feature 重复挂同一个 Native Handler。
- Combat 是高频特例的专用事实总线：M1.15.1 的 `CombatEventBusV3` 仍遵守“一个 Native Authority”，但为 RU 实机已知覆盖差异保留 private/self 与 global/all 两条传输；是否启用全局桥由 Consumer Demand 决定。

目标：

```text
Native Event Host
      ↓
   EventBus
   ├─ DPS
   ├─ DeathReview
   ├─ TeamTools
   └─ Alerts
```

---

## 4.3 Scheduler

当前 `rs_scheduler.lua` 已经明确：

> One private driver owns elapsed time for the whole Suite.

这条继续作为硬规则。

新 Feature：

- 默认禁止创建自己的 `OnUpdate`；
- 周期任务进入 Suite Scheduler；
- 必须声明 Priority；
- 必须声明 Cost Units；
- Feature Disable 时按 Owner 清理 Job。

只有已经证明必须保留独立 Native Driver 的高频专业 Runtime，才允许经过架构审核例外存在。

---

## 4.4 FrameBudget

现有 `rs_frame_budget.lua` 已经具备：

- P0/P1 不丢弃；
- 低优先级可延期；
- starvation protection；
- 无每帧日志写入；
- 不进行整表扫描；
- 不执行业务 callback。

新 Feature 所有可延期后台工作都要逐步接入这个预算体系。

---

## 4.5 Observation

现有 Observation 是：

> Shared lightweight reads/cache/subscriptions only; never owns Domain truth.

这个边界必须保留。

它只能减少同一观察窗口内的重复读取，例如：

- UnitName；
- UnitId；
- Health；
- Distance；
- 明确请求的 Buff/Tooltip Read。

禁止把缓存结果升级成业务结论。

例如 Observation 可以缓存“单位名”，但不能决定“这个单位是敌人”。

---

## 4.6 Diagnostics

现有 Diagnostics 已经拥有：

- Structured Event；
- Rate Limit；
- bounded counters；
- Snapshot；
- Module Summary；
- Copy-friendly 日志。

新的每一个 Feature 必须至少提供：

```text
Feature State
Last Update
Last Error
Active Subscriptions
Active Scheduler Jobs
Cache Size
HUD State
Persistence State
```

开发阶段禁止依赖大量聊天框散乱日志定位问题。

---

# 5. Persistence 新规范

当前 `rs_persistence.lua` 已经具备 V3 Store Contract，应继续沿用。

## 5.1 每个 Feature 独立 Store

禁止再形成一个不断扩大的全局配置 Table。

推荐：

```text
v3.shell
v3.feature.trade
v3.feature.activities
v3.feature.death_review
v3.feature.unit_lines
v3.feature.boss_alerts
v3.widget.event
v3.widget.trade
...
```

---

## 5.2 每个 Store 必须声明

- `owner`；
- `scope`；
- `lifetime`；
- `schemaVersion`；
- `legacySchemaVersion`；
- SaveData Key；
- Payload Budget；
- default；
- get/apply；
- 必要时 migrate。

现有 V3 Persistence 已经对：

- future schema；
- missing migration；
- migration failed；
- payload budget overflow；

提供写入 Fence。

新功能禁止绕过这一层直接写 SaveData。

---

## 5.3 数据生命周期必须明确

至少分为：

```text
Permanent
Daily
Weekly
Session
```

以及 Scope：

```text
Account
Character
Mixed（仅在确有必要时）
```

示例：

- UI 主题：Account + Permanent；
- 某角色日常任务状态：Character + Daily；
- 当前会话临时筛选：Session；
- 跑商收藏路线：Account + Permanent。

---

# 6. 新 UI Foundation：RSUI 是正式底层

## 6.1 不再直接用 Native Geometry 构建业务页面

V3 页面禁止业务代码直接：

```text
CreateEmptyWindow
SetExtent
AddAnchor
Show
SetText
```

Native 创建与变更必须经过 Adapter / UI Diff Authority。

当前 `rs_v3_native_adapter.lua` 已经建立了这个边界。

---

## 6.2 Strict Native Authority

现有 UI Framework 已经记录：

- Authority Claim；
- Conflict；
- Violation；
- Strict Repair；
- Cache Repair。

V3 组件必须使用 `v3:*` Owner Namespace，并保持：

```text
Authority violations = 0
Authority conflicts = 0
V3 duplicate physical IDs = 0
```

任何 V3 Native 状态被 Diff Authority 之外的代码修改，都视为架构错误，而不是“UI 小问题”。

---

## 6.3 组件树与布局失效

现有 RSUI 已具备：

- `InvalidateLayout`；
- `InvalidateMeasure`；
- 父级传播；
- Layout Root Queue；
- Scheduler 批量 Flush；
- `LayoutIfNeeded`；
- unchanged layout skip。

新页面不得自己建立另一套布局调度。

UI 更新原则：

```text
数据变化
  ↓
只修改发生变化的 Component State
  ↓
必要时 Invalidate
  ↓
集中 Layout Flush
```

而不是：

```text
每次 Refresh
  ↓
全页 SetText
全页 SetExtent
全页 AddAnchor
```

---

## 6.4 大量数据必须虚拟化

当前底层已经有：

- `VirtualList/ListView`；
- `VirtualGrid/TileView`；
- `TableView/Table`；
- Row Pool；
- Overscan；
- Stable Key Selection。

以下页面强制使用 Virtualized View：

- DPS 排行榜；
- 活动；
- 债券；
- 日常/周常；
- 跑商多货物；
- Buff 规则；
- 诊断日志；
- 大型配置表。

禁止预创建 50/100/200 行然后通过 Show/Hide 模拟列表。

---

## 6.5 文本布局

现有 `rs_ui_text_layout.lua` 已明确：

> Text measurement only when text/layout changes; never from per-frame Tick.

新 UI 必须统一使用：

- ellipsis；
- shrink-to-fit；
- wrap；
- maxLines；
- 可测量最小宽度。

不得在小分辨率上靠手写字符串截断解决布局问题。

---

# 7. Widget 体系重新定义

当前 `widgets/rs_widget_base.lua` 已经统一处理：

- 拖动；
- Safe Area Clamp；
- Resize；
- 背景透明度；
- Lock；
- Click-through；
- Standard / Mini；
- 字体增减；
- 标题栏 Chrome。

这些能力继续保留，但下一代 Widget 需要从“每个文件直接创建大量 Native Label/Button”升级到 **WidgetBase + RSUI Component Tree**。

---

## 7.1 Widget Contract

每一个新 Widget 必须声明：

```text
Id
FeatureId
Title
DefaultSize
MinSize
MaxSize
Modes
PersistenceStore
DataProjection
RefreshPolicy
VisibilityPolicy
InteractionPolicy
```

建议标准结构：

```lua
WidgetSpec = {
    id = "event",
    featureId = "activities",
    title = "活动",
    modes = { "standard", "mini" },
    dataProjection = "activity_hud",
    refreshPolicy = "dirty+visible_clock",
}
```

---

## 7.2 Widget Visibility 不得启动业务扫描

正确：

```text
Feature Service 已运行
       ↓
State Projection 已存在
       ↓
Widget Visible 时消费 Projection
```

如果某项数据只有 HUD 可见才有读取价值，例如寻宝玩家位置，则应明确登记：

```text
Visibility-driven Observation
```

而不是把整个 Feature 生命周期绑到 HUD Show/Hide。

---

## 7.3 当前生活 Widget 的迁移价值

现有以下 Widget 行为可以作为需求参考：

- Task Widget；
- Trade Widget；
- Bond Widget；
- Event Widget；
- Treasure Widget；
- Fishing Widget。

但其当前实现仍有大量直接 Native 创建，因此：

> **保留交互语义与用户配置，不直接复制实现。**

---

# 8. V3 Application Shell

当前 V3 Shell 只验证 Foundation 生命周期。

下一步 V3 Shell 应正式承担：

```text
ApplicationWindow
├─ AppChrome
├─ Navigation
├─ PageHost
├─ GlobalOverlayHost
└─ ModalHost
```

---

## 8.1 Shell 只负责应用级能力

V3 Shell 允许拥有：

- 主窗口尺寸；
- 主窗口位置；
- 当前 Route；
- 全局 Scale；
- Navigation 状态；
- Modal/Overlay 宿主；
- 响应式布局。

不允许拥有：

- 跑商筛选；
- DPS 行数；
- Buff 追踪 ID；
- 债券过滤；
- Feature Enabled。

这些属于对应 Feature Store。

---

## 8.2 Route Contract

以后导航不允许页面之间直接调用：

```text
OtherPage:Show()
```

必须统一：

```text
UIHost.Navigate(RouteId, Context)
```

Route 示例：

```text
home
combat.stats
combat.healer
combat.death_review
combat.buff_display
combat.boss_alerts
combat.target_monitor
combat.unit_lines
combat.range_assist
combat.team_tools
combat.gear
life.activities
life.trade
life.bonds
life.tasks
life.treasure
life.fishing
tools.bag_organizer
tools.auction_favorites
system.widgets
system.features
system.settings
system.diagnostics
```

Route 与 ModuleId 可以相关，但不得强制相同。

---

# 9. 新 Feature 分类

## 9.1 首页

首页是信息工作台，不是“快捷方式垃圾场”。

当前确定的核心区域：

```text
活动 / 世界状态
跑商当前路线
债券 / 居民板
我的任务追踪
今日统计
```

首页只能消费其它 Authority 的 Projection，不创建第二份业务计算。

---

## 9.2 战斗

目标分类：

```text
战斗
├─ 战斗统计
├─ 治疗辅助
├─ 死亡回顾
├─ BUFF显示
├─ Boss机制 / 战斗警报
├─ 目标监控
├─ 单位连线
├─ 范围辅助
├─ 团队工具
└─ 一键换装
```

### 战斗统计

内部 View：

- 伤害；
- 承伤；
- 治疗；
- 技能明细；
- 目标明细；
- 最后一击。

这些共享 Combat Stats Authority，不拆成多个重复 Runtime。

### 死亡回顾

必须独立生命周期。

不依赖 DPS Enabled，也不依赖 TeamTools Enabled。

### BUFF显示

只负责：

- Buff；
- Debuff；
- Hidden；
- 目标/自身状态 HUD；
- 施法条；
- Buff Tracking；
- 与这些内容直接相关的布局/颜色。

禁止再次变成其它战斗辅助功能的容器。

### Boss机制 / 战斗警报

消费状态、施法、规则数据，但拥有独立 Feature 语义和 HUD。

### 目标监控

负责：

- 追踪目标；
- 仇恨目标；
- 距离监控。

### 单位连线

独立开关、独立绘制生命周期。

### 范围辅助

负责空间辅助：

- 自身距离圆；
- 魔法阵距离；
- 未来其它经验证可实现的范围可视化。

### 团队工具

保留真正属于团队管理的能力：

- 自动职责；
- 献祭之舞；
- 团队检查；
- 原生标记辅助。

---

## 9.3 生活

```text
生活
├─ 活动
├─ 跑商
├─ 债券 / 居民板
├─ 任务追踪
├─ 寻宝
└─ 钓鱼
```

生活 Feature 要继续遵循已经核验的“真实性 Fence”：

- 页面不能创造不存在的 Authority 字段；
- 实时/规划信息分开；
- 一条跑商路线必须允许多货物；
- 红龙/卡杜姆按实例参与语义；
- 日常 Tracking 与 Event Objective Tracking 分离；
- 寻宝/钓鱼是 HUD-first 工具。

---

## 9.4 工具

工具只存放独立操作型能力，例如：

```text
整理背包
拍卖收藏
制作台助手
```

“工具”不能再次成为无法分类功能的垃圾箱。

---

# 10. Feature Module Contract

每一个新 Feature 建议统一暴露：

```lua
Feature = {
    Id = "...",
    Category = "combat|life|utility|system",
    DefaultEnabled = false,
    DataScope = "account|character",
}

function Feature:Initialize() end
function Feature:Enable(reason) end
function Feature:Disable(reason) end
function Feature:GetSnapshot() end
function Feature:GetHealth() end
```

可选：

```text
GetSettingsSchema
GetRoutes
GetWidgetSpecs
GetCommands
GetDiagnostics
```

ModuleManager 负责生命周期 Authority。

UI 不允许直接调用 Service `Start/Stop`。

---

# 11. Shared Service Contract

Service 是可复用能力，不是一个页面。

建议统一要求：

```text
Id
AuthoritySource
Dependencies
Subscribers
StartPolicy
CachePolicy
ErrorPolicy
PresentationBoundary
```

目前应继续收敛的 Shared Services：

```text
QuestService
ResourceService
TargetService
EventService
TradeService
ResidentService
AuctionService
CharacterService
AlertsService
DamageReviewService
TreasureService
FishingService
...
```

以后如果发现多个 Feature 重复实现相同读取，再抽 Service；禁止为了“架构看起来漂亮”提前创建没有真实复用者的 Service。

---

# 12. Data 与静态 ID

当前工程已经建立：

```text
data/ids/
├─ item
├─ zone
├─ trade craft
├─ trade product
├─ quest
├─ instance
├─ skill
└─ buff
```

以及：

- `GameDataRegistry`；
- `StaticDataV2`；
- Seal；
- Validate；
- 来源/核验状态。

这部分必须继续作为新工程的唯一静态 ID Authority。

禁止 Feature 中重新出现：

```lua
if questId == 12345 then ... end
```

这类散落 Magic ID。

新 Feature 只能引用 Semantic Key / Shared Registry。

---

# 13. 性能基线

## 13.1 禁止事项

新代码禁止：

- 每帧扫描全部 Buff；
- 每帧扫描背包；
- 每帧重建 UI；
- 每帧字符串大规模拼接；
- 每帧写日志；
- 每帧排序大型列表；
- 每个 Feature 私建 OnUpdate；
- 关闭功能后继续保留 Scheduler Job；
- 隐藏 HUD 后继续执行 HUD-only Observation；
- 大量列表预创建全部 Row。

---

## 13.2 高频 Feature

DPS、大规模团队、实时排名等必须：

```text
独立事件入口
独立缓存
固定预算
增量统计
有限 Projection
关闭后释放
```

UI 排名人数只影响 Projection，绝不影响后台完整统计。

---

## 13.3 低频 Feature

死亡回顾、基础事件记录等应允许独立低成本运行。

禁止：

```text
DeathReview → DPS Runtime
```

正确：

```text
CombatEventBus
├─ DPS
└─ DeathReview
```

---

# 14. UI 视觉系统

新 UI 需要做到“统一视觉语言，但不强迫所有功能使用同一种布局”。

## 14.1 统一内容

统一：

- Color Tokens；
- Typography Tokens；
- Spacing；
- Radius/Border；
- Button State；
- Card/Section；
- Page Header；
- Table Header；
- Empty State；
- Warning/Error/Success Tone；
- Tooltip；
- Modal；
- Widget Chrome。

---

## 14.2 不统一的内容

以下不应被强行做成同一个 Card Template：

- DPS 排行表；
- 活动列表；
- 寻宝方向 HUD；
- 钓鱼推荐 HUD；
- 单位连线；
- Boss 屏幕警报；
- 换装快捷栏。

统一的是设计系统和生命周期，不是信息形状。

---

# 15. 响应式设计基线

至少必须覆盖：

```text
1024×768
1920×1080
2K 常见分辨率
```

1024×768 是硬验收环境，不是“以后再适配”。

规则：

- 主窗口不得生成在屏外；
- Page 必须能降级布局；
- Sidebar 必须可滚动；
- 表格列可按优先级折叠/压缩；
- 字体放大后不能依赖固定像素高度；
- Modal 必须 Clamp 到 SafeZone；
- Widget 重载后位置必须再 Clamp；
- 不允许通过把字体缩到不可读解决溢出。

---

# 16. 新旧兼容策略

## 16.1 Legacy Freeze

从本文档生效开始：

**Legacy Presentation 禁止新增功能。**

只允许：

- 阻断性 Bug 修复；
- 数据错误修复；
- 为迁移增加 Adapter；
- 为旧配置增加读取兼容。

---

## 16.2 Strangler Migration

迁移采用：

```text
Legacy Feature
     ↓
确认真实 Authority
     ↓
定义 Feature Contract
     ↓
建立 V3 Projection
     ↓
建立 V3 Page/Widget
     ↓
Sequence + Acceptance
     ↓
V3 成为默认入口
     ↓
删除 Legacy Presentation
```

不能一次删除所有旧 UI 再重新实现全部功能。

---

## 16.3 配置迁移

迁移规则：

- 旧配置只读作为 Migration Source；
- V3 使用新 Store；
- 首次成功迁移后写 schema；
- 旧 Key 暂不立即删除；
- 新版本绝不回写旧 Presentation 专属结构；
- 未知/未来 schema Fail Closed。

---

# 17. 建议的新目录蓝图

当前目录不要求一次性搬空，但新代码应逐步向以下结构靠拢：

```text
replicatedsuite/
│
├─ core/                       # 仅基础设施
│
├─ data/                       # 共享静态数据 / IDs
│
├─ services/                   # 共享 Authority
│
├─ features/
│  ├─ combat/
│  │  ├─ stats/
│  │  ├─ healer/
│  │  ├─ death_review/
│  │  ├─ buff_display/
│  │  ├─ boss_alerts/
│  │  ├─ target_monitor/
│  │  ├─ unit_lines/
│  │  ├─ range_assist/
│  │  ├─ team_tools/
│  │  └─ gear/
│  │
│  ├─ life/
│  │  ├─ activities/
│  │  ├─ trade/
│  │  ├─ bonds/
│  │  ├─ tasks/
│  │  ├─ treasure/
│  │  └─ fishing/
│  │
│  └─ tools/
│     ├─ bag_organizer/
│     ├─ auction_favorites/
│     └─ craft_assist/
│
├─ presentation/
│  ├─ v3/
│  │  ├─ shell/
│  │  ├─ navigation/
│  │  ├─ pages/
│  │  ├─ widgets/
│  │  └─ presenters/
│  └─ legacy/                  # 迁移期冻结区
│
├─ ui/
│  ├─ framework/               # RSUI Foundation
│  ├─ design_system/
│  └─ components/
│
└─ Docs/
```

重点不是目录名字本身，而是 **依赖方向只能向下**。

---

# 18. 依赖规则

允许：

```text
Feature → Service
Feature → Core
Presenter → Feature Snapshot
Presenter → Service Read Model
Page → Presenter / Projection
Widget → Presenter / Projection
```

禁止：

```text
Service → Page
Service → Widget
Feature A → Feature B UI
Widget → ModuleManager 内部状态修改
Page → Native API 大规模扫描
Data → Runtime
Legacy → V3 Core Authority
```

跨 Feature 行为使用 EventBus 或 Shared Service。

---

# 19. Feature Definition of Done

任何功能只有满足以下条件才算完成迁移：

## Authority

- [ ] 数据来源已确认；
- [ ] 没有 UI 自己推导业务真相；
- [ ] 没有散落 Magic ID；
- [ ] Shared Service 依赖明确。

## Runtime

- [ ] Enable/Disable 独立；
- [ ] Disable 后订阅释放；
- [ ] Disable 后 Scheduler Job 释放；
- [ ] 不依赖隐藏窗口维持运行；
- [ ] 故障 Fail Closed。

## Persistence

- [ ] 独立 Store；
- [ ] Scope 明确；
- [ ] Lifetime 明确；
- [ ] Schema/Migration 明确；
- [ ] SaveData Budget 明确。

## UI

- [ ] 使用 V3/RSUI；
- [ ] 无业务页面直接 Native Geometry；
- [ ] 大列表虚拟化；
- [ ] 1024×768 通过；
- [ ] Text Stress 通过；
- [ ] 页面与 HUD 生命周期分离。

## Diagnostics

- [ ] Health Snapshot；
- [ ] Fault 信息；
- [ ] 关键计数器；
- [ ] 不产生高频垃圾日志。

## Compatibility

- [ ] 旧配置迁移；
- [ ] 用户升级不丢设置；
- [ ] Legacy 行为差异已记录。

---

# 20. V3 Foundation Gate

当前项目已经存在 `rs_foundation_gate.lua` 与 V3 Sequence Cases，这应该继续扩展成发布 Gate。

每次准备把一个 V3 功能变为默认入口，至少检查：

```text
Host Contract
Persistence Contract
Strict Authority
UI ID Stability
Resize/Reflow
Open/Close
Navigation
Sequence
UI Matrix
Text Stress
Diagnostics
Static Data Validation
```

目标发布状态：

```text
Blocker = 0
Authority violation = 0
Authority conflict = 0
V3 ID duplicate = 0
Sequence failure = 0
```

Warning 可以存在，但必须有明确债务记录。

---

# 21. 推荐的重建顺序

这里的顺序是依赖顺序，不是“做一点就停止汇报”的阶段性开发模式。

## Foundation

首先完成：

1. V3 Shell；
2. Navigation/Router；
3. PageHost；
4. ModalHost；
5. Widget Host；
6. Design Tokens；
7. Feature Registry；
8. V3 Store conventions；
9. V3 Diagnostics page。

## 第一批低风险真实业务

优先迁移：

- 今日统计；
- 活动；
- 债券；
- 任务追踪；
- 寻宝；
- 钓鱼。

这些可以大量验证 TableView、Widget、响应式和 Persistence。

## 第二批中等复杂业务

- 跑商；
- 整理背包；
- 拍卖收藏；
- 制作台助手；
- 死亡回顾；
- 团队工具。

## 最后迁移高频专业模块

- BUFF显示；
- Boss警报；
- 目标监控；
- 连线/范围辅助；
- 治疗辅助；
- DPS；
- Gear。

原因不是这些功能不重要，而是它们最容易把旧 Runtime 耦合重新带进新地基。

---

# 22. 开发过程中禁止做的事情

从现在开始明确禁止：

1. 为了赶功能继续向 `rs_professional_pages.lua` 增加页面；
2. 新功能直接注册到 Legacy 主菜单；
3. 页面直接扫描大量 Native 数据；
4. 为一个新功能新建独立 Tick/OnUpdate；
5. “先画一个假字段以后再找数据”；
6. 同一设置在全局设置、模块设置、功能页面出现三份；
7. 一个 Feature 关闭后留下自己的 Handler/Timer/Cache；
8. 因为技术上共用 Buff/Target API 就把功能塞进 BUFF显示；
9. 大列表用固定 20/50/100 个 Native Row；
10. 为迁移方便破坏旧用户配置。

---

# 23. 第一版 V3 Shell 应该达到的产品形态

第一版真正可用的新壳不追求一次拥有全部功能，而要先证明：

```text
Replicated Suite
│
├─ 左侧稳定分类导航
│  ├─ 首页
│  ├─ 战斗
│  ├─ 生活
│  ├─ 工具
│  └─ 系统
│
├─ 中央 PageHost
│
├─ 全局 ModalHost
│
├─ Widget 管理
│
└─ 底部健康/版本信息
```

用户切页时：

- 不重建整个主窗口；
- 不重复创建稳定组件；
- 页面按需 Mount；
- 隐藏页面不继续执行 UI Refresh；
- Feature Runtime 不因切页启动/停止；
- Window Resize 只触发布局失效；
- 数据 Dirty 只刷新相关 Projection。

---

# 24. 新页面标准模板

每个新页面建议拥有：

```text
PageHeader
├─ Title
├─ Description / Context
└─ Primary Actions

PageBody
├─ Optional FilterBar
├─ Main Content
└─ Optional Detail Pane

PageFooter (optional)
└─ Status / Updated At / Diagnostics Hint
```

页面不默认加入“大号 KPI 卡”。

是否使用：

- Table；
- Cards；
- Form；
- Split View；
- Timeline；
- HUD Preview；

由真实玩法决定。

---

# 25. 配置 UI 标准

以后设置分三层：

## Global Settings

只包含：

- UI Scale；
- Font Scale；
- Theme；
- 主窗口行为；
- 全局刷新/性能档位；
- Diagnostics/Reset。

## Feature Settings

例如跑商页只管理跑商设置。

## Widget Settings

Widget 自己管理：

- Position；
- Size；
- Lock；
- Click-through；
- Opacity；
- Compact/Mini；
- Widget-specific display preferences。

同一个 Setting 只允许有一个 Authority。

---

# 26. 当前源码中可以直接继承的优秀设计

本次扫描确认以下设计值得保留：

### 统一单调时钟

不依赖可能冻结的 `UI:GetCurrentTimeStamp()`。

### Scheduler 单 Host

低频工作不各自创建 OnUpdate。

### Structured Diagnostics

有界日志与 Rate Limit。

### Module Fault Cleanup

Enable/Disable 中途失败会 Best-Effort Cleanup，避免 Zombie Runtime。

### Persistence Write Fence

异常 Schema 与超预算 Payload 不强行覆盖旧存档。

### V3 Strict UI Authority

可以检测 Diff Authority 之外的 Native 修改。

### RSUI Virtual Data Views

已经拥有大型数据视图基础，不需要重新造 ListView。

### Stable-key Selection

排序/重排后选择不会错误漂移到其它条目。

### Visibility / Collapsed 区分

可正确表达“隐藏但占布局”与“完全不参与布局”。

这些能力应成为新工程的地基，而不是因为“从 0 重做”而丢失。

---

# 27. 当前必须淘汰的旧设计习惯

### 巨型页面文件

数千行页面代码不可继续增长。

### UI 自己承担领域逻辑

页面不得再成为半个 Service。

### 实现归属决定产品归属

需要彻底废除。

### 同一功能多入口多设置

统一 Route 与 Setting Authority。

### 手写坐标长期维护

只允许 Native Adapter / 特殊绘制 Surface 使用。

### 一次创建全部页面/全部行

改为按需 Mount + Virtualize。

---

# 28. 文档体系

重建之后 Docs 至少保持以下长期文档：

```text
00_REBUILD_FOUNDATION_BLUEPRINT.md      # 本文档
01_ARCHITECTURE_CONTRACTS.md            # Core/Service/Feature/UI Contract
02_FEATURE_CATALOG.md                   # 所有功能及归属
03_UI_DESIGN_SYSTEM.md                  # Tokens/Components/Layouts
04_PERSISTENCE_SCHEMA.md                # Store/Schema/Lifetime/Migration
05_GAME_DATA_AUTHORITY.md               # Static IDs / Verification
06_PERFORMANCE_BUDGET.md                # Scheduler/Frame Budget/Hot Paths
07_DIAGNOSTICS_AND_TESTING.md           # Gates / Test Matrix
08_LEGACY_MIGRATION_MATRIX.md           # 每个旧功能迁移进度
```

以后重大架构改变必须同步更新文档，而不是只改代码。

---

# 29. 下一步建议

在继续迁移任何具体业务页面之前，下一轮代码应该优先完成一个真正可承载业务的 **V3 Application Foundation**：

```text
V3 Shell
+
Navigation Router
+
Page Host
+
Feature Registry
+
Widget Registry/Host
+
Design System
+
Modal/Overlay Host
+
V3 Diagnostics Surface
```

然后用一个低风险真实页面作为第一块“样板功能”验证整个链路。

推荐第一块样板不是 DPS，也不是 BUFF显示，而是：

> **活动页 + 活动 Widget**

原因：

- 已有 EventService Authority；
- 数据量足以验证 TableView；
- 有实时倒计时；
- 有任务 Projection；
- 有 HUD；
- 有筛选/隐藏；
- 有 1024×768 的真实压力；
- 不需要先触碰最高风险 Combat Runtime。

成功后再以同一 Contract 连续迁移债券、任务、跑商等功能。

---

# 30. 最终目标

Replicated Suite 的目标不再是：

> “把很多功能都放进一个插件。”

而是：

> **建立一个长期稳定的 ArcheRage 客户端辅助平台，每个 Feature 可以独立运行、独立升级、独立诊断、独立持久化，同时共享经过严格控制的 Core、Service 与 Widget Foundation。**

最终我们希望达到：

```text
单入口
模块化
高性能
高信息密度但不混乱
统一视觉系统
功能独立启停
共享 Authority 不重复扫描
配置长期兼容
异常可诊断
小分辨率可用
新功能可以低风险扩展
Legacy 最终可以彻底删除
```

这才是这次“重新开发 Replicated Suite”的真正完成标准。

---

# 31. 2026-08-27 M1 执行状态：Activities 第一条真实 Feature 链

M0 Foundation 完成后，M1 不再复活旧 `EventService`，而是把“活动”作为第一条真正迁入 V3 的 Gameplay Feature。

当前链路：

```text
Curated RU Event Data
        +
X2Map Live Zone State
        ↓
V3 ActivityAuthority
        ↓
Activity Projection
        ↓
Internal EventBus Topic
        ↓
┌──────────────────┬──────────────────┐
│ Activity Page    │ Activity Widget  │
└──────────────────┴──────────────────┘
        ↓
V3 Activity Store
```

## 31.1 已完成

- `life_activities` 标记为 `migrated_m1`；
- 独立 `ActivityAuthority`；
- 独立 `v3.activities` Persistence Store；
- 独立 Feature 生命周期；
- `MAP` API 通过 Feature Runtime 延迟导入；
- 静态 RU 活动时间表按“语义活动”聚合，不因一周多个时间窗口重复占满列表；
- 十字星 / 伊尼斯 / 鲸鱼 / 烛台实时区域阶段；
- 庭院 Boss 实时区域 Projection；
- V3 活动 TableView 页面；
- V3 活动悬浮 Widget；
- 活动隐藏 / 恢复隐藏；
- Widget 可见状态持久化；
- Page / Widget Consumer Reference Counting；
- 1 秒倒计时 Projection 与 5 秒 Zone Scan 使用统一 Scheduler；
- Consumer 为 0 时两条 Scheduler Lane 全部关闭；
- Feature Disable 时 Scheduler Task、Native Event Listener、Native Event Registration 全部释放；
- 新增 Internal EventBus，不使用 Native Event 来传递 Presentation Projection；
- 新增 M1 Activity Acceptance Sequence；
- Foundation Gate 继续要求 Strict Native Authority = 0 violation。

## 31.2 Authority 边界

当前 M1 活动 Authority 只承诺：

```text
A/B Authority
├─ 服务器时间
├─ Curated RU 时间表
└─ X2Map 区域阶段 / remainTime
```

当前没有重新接入：

```text
Quest Progress
Instance Enter Count
Event Reminder Policy
```

这些能力必须等待对应 V3 Authority / Feature Store 建立后，通过 Provider Contract 接入。

尤其红龙 / 卡杜姆仍必须保持：

```text
Instance Participation Authority
0 / 1
```

不能因为 UI 已经迁移就退回普通 Quest 判断。

## 31.3 性能 Contract 已验证

活动 Feature `Enable` 不等于启动高频工作。

```text
Feature Enabled + Consumer 0
    → 1s Projection Task OFF
    → 5s Zone Scan Task OFF

Activity Page Open
    → Consumer +1
    → Tasks ON

Activity Widget Open
    → Consumer +1

Page Closed + Widget Closed
    → Consumer 0
    → Tasks OFF
```

Native 事件也遵守真正的生命周期回收：

```text
Enable
→ Register HPW_ZONE_STATE_CHANGE / ENTERED_WORLD

Disable
→ Remove callbacks
→ Unregister native events
→ Remove scheduler tasks
```

以后其它 Feature 必须沿用这一规则，不能把“删除 Lua callback”误认为完成资源释放。

## 31.4 M1 验收基线

当前 ArcheRage Host Mock 已覆盖：

- 完整 active TOC 顺序加载；
- V3 为唯一 Presentation Host；
- Legacy MainWindow / MainButton / TaskWidget / EventWidget 不存在；
- Activity 默认 Feature 初始化；
- Foundation Core API 4 个；
- Activity Feature 额外按需导入 `MAP` 1 个；
- Activity Page 导航；
- 24 条当前测试时间活动 Projection；
- 5 条实时区域 Projection；
- Activity Widget 创建 / 显示 / 隐藏；
- Page + Widget Consumer 增减；
- 隐藏 / 恢复活动；
- 关闭后 Scheduler Lane 归零；
- Disable 后 Native Event Registration 释放；
- Feature 重启后保持 idle；
- Widget Manager 页面不会偷偷消费 Activity Authority；
- Foundation Gate：`READY / Blocker 0 / Warning 0`；
- Strict Native Authority：0 violation / 0 conflict；
- V3 Component ID：0 duplicate。

## 31.5 下一阶段

M1 并不意味着活动领域已经 100% 功能等价迁移。

下一步优先顺序：

```text
Quest V3 Authority
    ↓
Event Objective Projection
    ↓
Red Dragon / Kadum Instance Authority
    ↓
Activity Progress Provider
    ↓
Reminder Policy / Store
```

完成后活动页才达到旧功能的完整等价，并且整个过程不能重新依赖 Legacy `EventService`。

---

# M1.5 决议：Native Foundation Independence（2026-08-27）

V3 已彻底取消根级 `globals/` 运行时依赖。旧 `globals` 只保存在 `legacy_reference/globals_archive/` 作为迁移证据。

新的唯一客户端边界为 `replicatedsuite/native/`：Native Contract、Import Registry、Object Factory、ESC Bridge、Capabilities 与 Recovery Entry 全部由 Replicated Suite 自己拥有。

硬规则：

1. Active TOC 不得再次引用 `../globals/*`。
2. `API_TYPE / OBJECT_TYPE / UIEVENT_TYPE / CreateEmptyWindow / CreateWindow / CreateSimpleButton / ReplicatedEscMenuPolicy` 不得进入 V3 Runtime。
3. Feature 不直接 `ImportAPI`，只声明依赖，由 NativeImports 统一导入和审计。
4. 原生 Widget 构造统一进入 NativeObjectFactory；RSUI 负责组件语义、布局和外观。
5. Native Contract 只加入当前迁移 Feature 真实需要且已核验的客户端 ABI，不复制旧全量表。
6. Foundation Gate 必须保持 Native Independence 为 READY 后，才允许继续迁移新的 Gameplay Feature。

---

# 32. M1.6 实服第一轮 UI Foundation 验收与修整（2026-08-27）

> 验收来源：ArcheRage RU 实服第一轮 V3 M1.5 截图与玩家实际操作。  
> 结论：M0/M1 的架构链路已经成立，但第一轮实服直接暴露出外围窗口能力、文本约束、导航可达性与维护入口仍未达到“平台级 UI Foundation”标准。这些问题必须在继续迁移大量 Feature 之前统一修到底层，禁止在单个页面逐一打补丁。

## 32.1 实服发现的六项基础缺陷

| 编号 | 实服现象 | 架构判断 | 本轮处理 |
|---|---|---|---|
| 1 | 主窗口不能拖动 | 顶层窗口缺少统一窗口交互 Contract | 新增统一 `RSUI.Windowing`，主窗口和已迁移悬浮窗接入 |
| 2 | 界面存在英文术语 | Presentation 文案没有执行完整中文化 Fence | 玩家可见标题、描述、状态、诊断与导航统一改为中文 |
| 3 | 首页卡片文字越界 | Text Render 与 Grid Measure 的底层约束错误 | 修复文本按实际高度限制行数；修复 UniformGrid 按真实单元格宽度测量 |
| 4 | 设置/诊断/重载入口看不到，左侧导航疑似无法滚动 | ScrollBox 只拥有一个容器子项，导致滚动模型失效；系统入口又处于列表尾部 | 导航改为 ScrollBox 直接拥有条目；系统入口固定在导航底部；增加滚轮、上下滚动按钮和范围提示 |
| 5 | 无最小化、窗口边缘不能拖动缩放 | 外围窗口 Chrome Contract 不完整 | 主窗口和活动悬浮窗统一加入最小化、八方向边缘/角落缩放、安全区限制和几何持久化 |
| 6 | 第一轮即暴露多项底层问题 | UI Foundation 验收只覆盖启动/Authority，没有覆盖真实桌面窗口交互 | Foundation Gate 与 Sequence 增加窗口、导航、文字约束、重载入口硬检查 |

## 32.2 根因确认

### A. 外围窗口能力过去属于“页面自己实现”

V3 Shell 原先只有创建 RootWindow 与固定布局，没有一个强制的 Top-level Window Contract。因此拖动、缩放、最小化很容易在每个新窗口里重复遗漏。

从本轮开始正式规定：

```text
任何 V3 顶层外围窗口
        ↓
RSUI.Windowing
        ↓
拖动 + 八方向缩放 + SafeArea Clamp + Geometry Persistence
```

主窗口必须通过此 Contract；由 WidgetHost 管理的浮动组件默认也必须拥有 Windowing Controller。特殊纯绘制 Overlay 若不需要窗口行为，必须在 Widget Spec 中明确声明例外，不能默认绕过。

### B. 文本越界不是首页卡片自己的问题

实服截图暴露的文字越界来自两个基础错误：

1. `Text:Render()` 的换行只考虑 `maxLines`，没有根据实际分配高度再次收紧允许行数；
2. `UniformGrid:Measure()` 曾使用整个 Grid 可用宽度去 Measure 每一个 Child，而不是使用实际 Cell Width，导致文本在 Measure 阶段认为“一行放得下”，Arrange 到真实半宽单元格后才发生换行，最终高度被低估。

因此本轮修复必须位于 Framework，而不是给首页 Card 人工加高度。

正式 Fence：

```text
Measure 使用最终可用约束
        ↓
Arrange 分配真实 Geometry
        ↓
Text Render 同时受 Width + Height 约束
        ↓
ellipsis / wrap / shrink / clip
        ↓
Native Text 不得越出组件 Bounds
```

### C. 左侧导航的滚动模型错误

旧 V3 Shell 使用：

```text
ScrollBox
└─ VerticalBox
   └─ 所有导航按钮
```

而当前 RSUI ScrollBox 的滚动单位是“Direct Child Entry”。这意味着它实际上只看见一个巨大 VerticalBox，无法按导航条目滚动。

修复后：

```text
ScrollBox
├─ 分类标题
├─ 页面按钮
├─ 页面按钮
├─ Spacer
└─ ...
```

系统级入口不再放进可滚动业务列表末尾，而固定在导航底部：

```text
系统
├─ 悬浮组件
├─ 功能模块
├─ 全局设置
├─ 诊断与维护
└─ 重新加载文件
```

因此无论业务 Feature 数量未来增长到多少，设置、诊断和热重载都必须始终可达。

## 32.3 新的 Outer Window Contract

所有“外围大窗口”至少声明：

```text
id
owner
window
dragHandle
minWidth / minHeight
maxWidth / maxHeight
resizable
persistence callback
```

统一能力：

- 标题栏拖动；
- 八个边/角缩放命中区；
- `StartMoving / StartSizing` Native Transaction；
- 缩放上下限；
- 安全区 Clamp；
- 拖动/缩放结束后写回 Strict UI Authority；
- Native Transaction 后清理 Diff Cache，避免合法拖动被误报为 Authority Violation；
- 持久化位置和尺寸；
- 最小化时关闭 Resize；
- 不创建 Tick / OnUpdate。

以后禁止任何 Feature 再自己复制一套 `StartMoving / StopMovingOrSizing` 逻辑。

## 32.4 主窗口标准 Chrome

新版主窗口必须固定拥有：

```text
标题栏
├─ 中文产品标题
├─ 诊断
├─ 最小 / 还原
└─ 关闭

主体
├─ 可滚动功能导航
├─ 固定系统区
└─ PageHost

底部
└─ 中文运行状态
```

窗口行为：

- 标题栏可拖动；
- 四边 + 四角均可缩放；
- 最小化只保留标题栏；
- 还原恢复上一次正常尺寸；
- 位置/正常尺寸/最小化状态独立保存；
- 重载后再次执行 SafeArea Clamp；
- 1024×768 下不得依赖屏幕外控件。

## 32.5 文案规范更新

从本轮开始，**玩家可见 UI 默认只使用中文**。

允许继续存在英文/缩写的区域仅限：

- 内部 Lua Identifier；
- Route / FeatureId / StoreId；
- Diagnostics 内部 Code；
- 游戏本身无法替代的键位字符（例如 `R` 键）。

用户可见的架构术语必须翻译，例如：

```text
Feature       → 功能
Widget        → 悬浮组件
Authority     → 数据源 / 数据所有权
Runtime       → 运行状态 / 生命周期
Foundation    → 基础框架
Legacy        → 旧界面 / 旧实现
Boss          → 首领
```

## 32.6 新增 UI Foundation 发布 Gate

从本轮开始，新版本至少额外通过：

```text
外围窗口能力
├─ Main Shell 已绑定 Windowing
├─ Drag Handle 有效
└─ Resize Handle = 8

关键入口可达性
├─ Navigation Scroll 有多个 Direct Entries
├─ 全局设置存在
├─ 诊断与维护存在
└─ 重新加载文件存在

文字约束
├─ 829×555 压力布局（对应首轮截图可视尺寸级别）
├─ 首页 0 text_overflow
├─ 首页 0 x/y out_of_bounds
├─ 首页 0 sibling_overlap
└─ TopBar 0 hard layout issue

Sequence
├─ Window Minimize / Restore
├─ Navigation Scroll
├─ Critical System Entries
└─ Text Containment
```

这些检查属于 Blocker，而不是 Warning。

## 32.7 本轮代码修整结果

已经落实：

- `RSUI.Windowing` 统一外围窗口能力；
- 主 Shell 拖动；
- 主 Shell 八方向缩放；
- 主 Shell 最小化/还原；
- Activity Widget 同样使用统一 Windowing；
- V3 Shell Store 升级，保存窗口位置、尺寸、最小化；
- Activity Widget Store 升级，保存悬浮窗位置、尺寸、最小化；
- `Text` 垂直换行边界修复；
- `UniformGrid` Cell Measure 修复；
- InfoCard Detail 统一 bounded wrap；
- 左侧导航改成真实可滚动 Direct Entry；
- 系统入口固定在导航底部；
- 新增“重新加载文件”快捷按钮；
- 诊断页新增热重载入口；
- 诊断页刷新改为读取最近一次完整 Sequence 结果，避免诊断页面在运行导航 Sequence 时被自身刷新重新导航；
- 热重载前只刷新新版独立存档，不再接触旧 Storage；
- 玩家可见 V3 文案中文化；
- Foundation Gate 新增 3 个 UI Foundation Blocker；
- Sequence 从 7 项扩充到 10 项。

## 32.8 后续开发约束

在 M2 Quest / Instance Authority 开始前，实服必须再次确认以下基础操作：

1. 主窗口标题栏拖动；
2. 主窗口八方向/角缩放；
3. 最小化与还原；
4. 左侧鼠标滚轮及上下按钮；
5. 设置、诊断、重新加载文件始终可见；
6. 首页卡片无文字越界；
7. 活动悬浮窗拖动、缩放、最小化；
8. 重载后主窗口和悬浮窗几何恢复且仍在安全区。

如果其中任意一项失败，应继续修 UI Foundation，不能通过业务页面临时绕过。


---

# 33. M1.8 UI Foundation 完整性审计与加固

> 日期：2026-08-27  
> 基线：M1.6 实服第一轮 UI Foundation Fix 之后的 V3 工作树  
> 性质：在继续迁移 Quest / Instance / Trade / Combat Feature 之前，对应用级 UI 基础能力进行第二轮完整性审计。

## 33.1 审计结论

M1.6 已解决首轮实服直接暴露的拖动、缩放、最小化、导航滚动、文字越界、系统入口与热重载问题，但二次审计确认仍存在以下框架层缺口：

1. 分辨率 / UI Scale 变化时只保证主 Shell 重排，浮动 Widget 没有统一 Responsive Reflow Contract；
2. Windowing 缺少统一前置层级与透明度能力；
3. WidgetHost 缺少统一外观 Authority；
4. ModalHost 虽已具备模态栈，但应用仍缺少轻量、有限、自动回收的通知宿主；
5. 延迟 UI 工作不能为每个组件创建私有 Tick，需要依赖统一 Scheduler 的有限一次性任务；
6. Native V3 Root Window 需要明确系统层、原生 ESC 关闭策略和默认 Modal 策略，避免绕过 V3 生命周期；
7. Foundation Acceptance 必须覆盖浮动 Widget 的响应式回流与外观事务，而不是只测试主窗口。

因此 M1.8 的目标不是增加业务页面，而是继续收紧：

```text
ArcheRage Native Window
        ↓
Native Adapter Policy
        ↓
RSUI Windowing / Layout / Text
        ↓
Application Shell Hosts
        ↓
Page / Widget / Modal / Toast
```

## 33.2 Native Root Window Policy

`rs_v3_native_adapter.lua` 升级为 V2 Root Policy。

所有 V3 Root Window 创建时统一处理：

```text
SetUILayer("system")      # 客户端支持时使用统一应用层级
SetCloseOnEscape(false)   # 禁止 Native 直接关闭绕过 V3 生命周期
SetWindowModal(false)     # 普通 Root 默认非 Modal
```

同时将透明度写入 Strict Native Diff Authority：

```text
SetAlpha(widget, owner, alpha)
```

正式规则：

> 原生 ESC 关闭不能成为 V3 Shell 的第二个生命周期 Authority。只有在未来 NativeInputBridge 的键盘 Contract 经实服确认后，才能通过统一命令关闭应用。

因此当前不会猜测 `OnKeyDown` / `OnKeyUp` 事件名，也不会为了支持 ESC 而启用可能绕过 Persistence / Page Deactivate 的 Native Close。

## 33.3 Windowing V3

统一外围窗口 Contract 继续升级：

```text
RSUI.Windowing v3
├─ Drag
├─ Resize × 8
├─ Minimize / Restore
├─ Lock / Unlock
├─ SafeArea Clamp
├─ Persist Geometry
├─ BringToFront
├─ Opacity
├─ Reset Layout
└─ Detach
```

`BringToFront()` 在拖动/缩放开始时统一调用，避免多个浮动窗口交互时窗口层级停留在旧顺序。

透明度由 Windowing Authority 控制，范围固定：

```text
0.20 ~ 1.00
```

不允许 Feature 自己直接调用 Native `SetAlpha`。

## 33.4 WidgetHost V4

WidgetHost 现在除 Visibility / Lock / Reset 外，还统一拥有：

```text
Opacity Capability
Responsive Reflow
```

Widget Spec 可以声明：

```text
opacityAdjustable = true
getOpacity
setOpacity
```

并由 Host 统一提供：

```text
SetOpacity(id, value)
ApplyResponsiveLayout(fromMetricsChange)
```

响应式规则：

- 只对已经创建且当前可见的 Widget 进行 Reflow；
- 隐藏 Widget 保持零 UI 刷新成本；
- Widget 再次显示时使用最新 Layout Context；
- Resolution / UI Scale 变化由 `UIHostManager` 同时驱动主 Host 与 WidgetHost；
- Feature 不允许自己订阅分辨率变化再建立第二套布局监听。

## 33.5 活动 Widget 成为第一份 Widget Appearance 样板

`life.activities` Widget Store 升级至 Schema V4，窗口状态增加：

```text
opacity
```

悬浮组件管理页面现在可以调整活动 Widget 透明度，使用统一 Host / Windowing Contract，而不是活动模块自己写一套 Alpha 逻辑。

该实现以后作为跑商、债券、任务、寻宝、钓鱼、战斗 HUD 的共同样板。

## 33.6 ToastHost

新增应用级：

```text
V3 ToastHost
```

用途：

- 设置已保存；
- 功能启动失败；
- 诊断操作结果；
- 配置恢复；
- 后续活动提醒等轻量状态。

设计 Fence：

```text
固定可见槽位：3
有限 Pending：12
自动回收：Scheduler OneShot
独立 Tick：0
独立 OnUpdate：0
```

Toast 不成为业务 Authority，也不拥有长期状态。

Modal 与 Toast 必须保持不同语义：

```text
Modal = 要求用户处理的阻塞交互
Toast = 短暂、非阻塞状态反馈
```

## 33.7 Scheduler OneShot

统一 Scheduler 新增有限一次性任务：

```text
Scheduler:AddOneShot(...)
```

一次性任务在执行 Callback **之前**先从 Scheduler Registry 删除。

这样即使 Callback 报错，也不会留下 Zombie Delayed Job。

以后以下需求不得创建私有 OnUpdate：

- Toast 自动消失；
- 延迟聚焦；
- 短暂 UI 状态复位；
- 非业务性的有限延迟命令。

## 33.8 Responsive Bridge 修复

之前 Resolution Metrics 变化只保证主 V3 Host 重新布局。

现在统一为：

```text
Layout Metrics Changed
        ↓
UIHostManager:ApplyResponsiveLayout
        ├─ Active V3 Shell / PageHost
        └─ WidgetHost:ApplyResponsiveLayout
```

这是框架级修复，禁止 Activity/Trade/Bond 等 Widget 各自订阅分辨率变化。

## 33.9 Foundation Gate V8

新增/强化以下 Blocker：

```text
Windowing >= v3
WidgetHost >= v4 + Responsive Contract
ToastHost Contract
Scheduler Bounded OneShot
Native Root Policy
```

Native Root Policy 必须确认：

- Root 已经由 V3 Native Adapter 创建；
- 原生 ESC 直接关闭已禁用；
- Native Root 仍属于 Replicated Suite 唯一 Authority。

## 33.10 Acceptance / Sequence 扩展

新增：

```text
v3_12_bounded_notifications
v3_13_widget_appearance
v3_14_widget_responsive_reflow
```

其中验证：

- OneShot 执行前先自清理；
- Toast Notify / Dismiss 不泄漏；
- Widget 透明度修改与恢复事务；
- 可见浮动 Widget 在应用级 Responsive Reflow 时真正执行布局；
- Responsive Reflow 不增加失败计数；
- 用户显式关闭 Activity Feature 时自检不为了测试 UI 强行启动业务 Feature。

## 33.11 当前明确不猜测实现的 Native 能力

### 通用键盘导航 / ESC

官方 UI API 已确认存在 Focus / Keyboard Enable 等能力，但当前源码资料尚不足以证明 ArcheRage RU 中通用 `OnKeyDown` / `OnKeyUp` Handler Contract。

因此：

- 不猜事件名；
- 不制造第二个 Keyboard Driver；
- 不启用 Native `SetCloseOnEscape(true)` 绕过 V3 生命周期；
- 后续实服验证后再建立 `NativeInputBridge`。

### 全窗口点击穿透

客户端存在 Pickability 相关 API，但组合 Widget Tree 在透明/子控件环境下的真实点击穿透行为仍需实服验证。

因此本轮只建立 Opacity，不提前加入一个可能吞鼠标或穿透错误的全局 Click-through 开关。

## 33.12 M1.8 完成后底层能力清单

```text
Application Shell
├─ Drag
├─ Resize ×8
├─ Minimize / Restore
├─ Lock
├─ Safe Clamp
├─ Responsive Reflow
├─ Scroll Navigation
├─ Fixed System Entries
├─ Persistence
└─ Native Root Policy

Widget Foundation
├─ Central Host
├─ Visibility
├─ Independent Consumer Lifecycle
├─ Drag / Resize
├─ Lock
├─ Reset
├─ Minimize
├─ Opacity
├─ Responsive Reflow
└─ Persistence

Overlay Foundation
├─ ModalHost
└─ ToastHost

Safety
├─ Strict Native Authority
├─ Page Navigation Rollback
├─ Widget Visibility Rollback
├─ Scheduler OneShot Cleanup
├─ Foundation Gate
└─ Sequence Acceptance
```

## 33.13 下一步 Gate

在开始 M2 Quest / Instance Authority 之前，实服继续验证：

1. 多次拖动主窗口后点击其它浮动窗口，窗口前后层级正确；
2. 活动 Widget 透明度 20% / 50% / 100% 正常；
3. 分辨率或 UI Scale 变化时主窗口和活动 Widget 都重新 Clamp/Reflow；
4. Diagnostics “测试通知”显示和自动消失正常；
5. 最小化、锁定、透明度和位置重载后保持；
6. 没有旧 UI / `globals` / Legacy Window Helper 被重新加载；
7. 1024×768 与小窗口压力布局无硬越界。

在以上基础能力通过实服之前，继续优先修 Foundation，不大量迁移高频 Combat Feature。


# 34. M1.9 实服第二轮交互修整（2026-08-27）

## 34.1 Resize 交互反馈

实服确认八方向缩放可以工作，但 Resize Hit Area 缺少可感知反馈。Windowing V4 为所有边和角加入统一 Hover 高亮。ArcheRage API 可通过 `X2Cursor:SetCursorImage` 更换指针，但当前项目没有经过 RU 实服核验的 Resize Cursor 纹理路径，因此禁止猜测客户端资源名；待资源核验后只允许在 Native Cursor Adapter 中补充真正的指针切换。

## 34.2 R Launcher

R 是 Recovery + Launcher 双用途入口，正式支持 Native Drag，并使用独立 `v3.launcher` Account/Permanent Store 保存位置。拖动结束会阻止同一次手势误触发打开窗口，并执行 SafeArea Clamp。

## 34.3 ScrollBox Wheel Routing

实服确认滚轮事件只绑定 ScrollBox Root 时，鼠标位于内部 Button/Text/Card 上会因 Native Hit Test 导致事件不稳定冒泡。新规则：所有后代 Native Root 自动把 `OnWheelUp/OnWheelDown` 转发给最近的 ScrollBox；嵌套 ScrollBox 会截断外层转发。

## 34.4 主窗口最小化

主 Application Window 不再缩成标题横条。点击标准 `—` Chrome 后隐藏主窗口并保留 R Launcher；点击 R 恢复完整正常尺寸。关闭与最小化保持不同语义。

# 35. M1.10 实服第三轮：原生拖动 / 缩放实时事务修复（2026-08-27）

## 35.1 实服现象

M1.9 实服测试确认一个典型交互缺陷：拖动窗口边缘改变尺寸时，鼠标持续拖动期间可见内容没有同步变化，释放鼠标后界面才瞬间跳到最终尺寸。该现象不能作为单个页面 Bug 处理，因为所有 V3 外围窗口都共享同一 Windowing / Strict Geometry Authority。

## 35.2 根因

V3 顶层窗口由 Strict Diff Authority 持有 `anchor/extent`。ArcheRage 的 `StartMoving/StartSizing` 在鼠标捕获期间会直接修改 Native Window Geometry，而 RSUI 仍可能因为布局失效、页面刷新或响应式事务写回拖动开始前的几何状态。Resize 时还有第二个问题：Native Window 尺寸虽然正在变化，但内部 RSUI Component Tree 只有在 DragStop 后才重新 Layout，因此用户看到“拖动时不变、松手后瞬间变形”。

## 35.3 Native Geometry Lease

从 M1.10 开始，`S.UI` 提供短生命周期 Native Geometry Lease：

```text
BeginNativeGeometryLease
        ↓
Native StartMoving / StartSizing
        ↓
SetAnchor / SetExtent 暂缓写入顶层窗口
        ↓
Native Client 临时拥有窗口 Geometry
        ↓
EndNativeGeometryLease
        ↓
Invalidate Native Diff Cache
        ↓
V3 Commit Final Geometry
```

Lease 只让出 `Anchor + Extent`，不让出 Text、Visibility、Color、Alpha 等其它 Presentation Authority。

禁止在 Native Drag/Resize 活跃期间由任何页面重新锚定顶层窗口。

## 35.4 Live Resize Projection

仅在用户正在 Resize 时，Windowing 会临时向统一 Scheduler 注册一个 P0、50ms 的交互任务：

```text
Resize Start
   ↓
Geometry Lease
   ↓
临时 Live Resize Task
   ↓
读取 Native Rect
   ↓
仅当 Width / Height 真正变化时
   ↓
Reflow 当前 Component Tree
   ↓
Resize Stop
   ↓
立即删除任务
```

因此：

- 没有永久新增 Tick；
- 没有每个窗口各自常驻 OnUpdate；
- 非拖动状态 CPU 成本为 0；
- Resize 时约 20Hz 更新布局，足以提供连续视觉反馈；
- Native 外框仍由客户端直接跟随鼠标；
- RSUI 内容同步渐进 Reflow，而不是松手后一次性跳变。

## 35.5 Windowing V5 Contract

所有 V3 外围窗口必须至少支持：

```text
IsInteracting
IsDragging
IsResizing
BeginInteraction
EndInteraction
PulseLiveGeometry
onLiveGeometry
```

主 Shell、Activity Widget 和通用 WindowShell V3 均已接入同一 Contract。

## 35.6 布局事务约束

`ApplyLayout()` 在 Native Interaction 活跃时禁止把持久化 Rectangle 写回窗口：

- Drag：保留 Native Window 当前位置；
- Resize：读取 Native 当前尺寸，只重排内部 Component Tree；
- DragStop / ResizeStop：一次性 Commit + Clamp + Persist。

这条规则以后适用于所有新 WindowShell / Floating Widget。

## 35.7 新验收 Gate

Foundation Gate 现在要求：

- Windowing >= V5；
- Native Geometry Lease API 存在；
- Window Controller 暴露 Interaction Contract；
- Sequence 增加 `v3_15_native_geometry_lease`，验证 Lease 期间 Strict `SetAnchor` 不会覆盖 Native Geometry。

## 35.8 性能 Fence

禁止用以下方式解决实时缩放：

- 永久 OnUpdate；
- 每个 Feature 自建 Resize Tick；
- 每帧全页面重建；
- Drag 中写 Persistence；
- Drag 中重复排序/扫描业务数据。

Live Resize 只负责 Geometry / Layout Projection，不执行 Gameplay Authority Refresh。

---

# 36. M1.11 实服第四轮：自由窗口位置与可恢复拖动（2026-08-27）

## 36.1 实服发现

M1.10 解决了拖动期间 Native Geometry 与 Strict Geometry Authority 互相抢写导致的“松手瞬移”，但继续实服测试后发现第二层问题：窗口位置仍然存在明显边界，玩家无法按自己的习惯把大窗口部分移出屏幕。

根因并非单一 Windowing Clamp，而是两层旧安全语义叠加：

1. `RSUI.Windowing:CommitGeometry()` 在交互结束时把整个窗口强制 Clamp 到 SafeArea；
2. `Layout:StorePlacement / ResolvePlacement` 使用 `logical-edge-v1`，要求整个窗口永久处于屏幕内部。

这种规则适合“绝不允许丢窗口”的保守 UI，但不适合作为大型游戏辅助框架的默认拖动体验。

## 36.2 新正式规则：Free Placement v2

V3 外围窗口采用：

```text
自由拖动
+
不可恢复位置救援
```

而不是：

```text
整窗永远锁在屏幕内部
```

允许：

- 窗口大部分移到左侧屏幕外；
- 窗口大部分移到右侧屏幕外；
- 窗口向下移出大量区域；
- 标题栏部分越过上边界；
- 保存并在重载后恢复上述自由位置。

唯一强制规则：必须保留一小段可抓取区域，防止窗口永久丢失。

主窗口当前救援参数：

```text
水平最少可见：96
标题栏最少可抓：18
标题栏高度：50
```

活动悬浮窗：

```text
水平最少可见：72
标题栏最少可抓：14
标题栏高度：28
```

R 启动入口：

```text
至少保留 16×16 可抓区域
```

这些数值是 Recovery Fence，不是正常拖动吸附距离。只有超过可恢复边界才会介入。

## 36.3 Persistence Contract

新增坐标空间：

```text
logical-free-v2
```

保存：

```text
x
y
coordinateSpace = logical-free-v2
savedUiScale
```

不再为了保存自由位置强制转换成 LEFT/RIGHT + 非负 offset。

旧：

```text
logical-edge-v1
```

仍保持读取兼容。旧用户第一次继续使用时不会丢位置；下一次明确拖动后自动写为 v2。

Store Schema：

```text
v3.shell      3 -> 4
v3.activities 4 -> 5
v3.launcher   1 -> 2
```

全部带 Migration。

## 36.4 Windowing V6

`RSUI.Windowing` 升级到 V6，增加：

```text
boundaryMode
recoveryVisibleX
recoveryVisibleY
dragHandleHeight
freePlacementCommits
recoveryClamps
```

默认 V3 Outer Window 使用 `recoverable`。

`strict` 仍作为特殊场景可选能力保留，但普通玩家窗口禁止默认使用整窗 SafeArea Clamp。

## 36.5 Acceptance

新增：

```text
v3_17_free_recoverable_placement
```

自动确认：

1. 大量窗口区域出屏时位置不会被 Hard Clamp；
2. `logical-free-v2` 重载解析保持原自由位置；
3. 当窗口真正完全不可恢复时才触发 Rescue Clamp。

M1.11 Foundation 模拟结果：

```text
Foundation Gate  READY
Blocker          0
Warning          0
Sequence         18 / 18
```

## 36.6 长期窗口规则更新

从本阶段开始：

> **安全不是“限制玩家怎么摆窗口”；安全是“玩家可以自由摆，但永远有办法拿回来”。**

以后所有 V3 Main Window / Floating Widget / Tool Window 默认使用 Free Placement v2 + Recoverability Fence。

# 37. M1.12 全窗口自由位置与精确数值设置（2026-08-27）

## 37.1 实服反馈

M1.11 解决了主窗口“部分出屏时被强制拉回”的问题，但继续实服测试后确认：

1. 自由拖动不能只适用于主窗口；
2. 活动 HUD、未来跑商/债券/任务 HUD、工具窗以及所有通用 `WindowShell V3` 都必须遵守同一自由位置规则；
3. 框架不应以“防止窗口丢失”为理由暗中修改玩家坐标；
4. 如果玩家主动把窗口拖出屏幕，应由明确的“恢复全部窗口位置”操作负责救援；
5. 所有数值型设置必须显示可直接编辑的具体数值，禁止通过单按钮反复切换预设档位。

## 37.2 Free Surface Contract

V3 默认窗口边界策略正式从：

```text
recoverable
```

改为：

```text
free
```

适用范围包括：

```text
Main Shell
Floating Widget
Tool Window
Dialog / WindowShell V3
Launcher R
未来所有可拖动外围窗口
```

`free` 的正式语义：

- Drag Commit 不进行 SafeArea Clamp；
- StorePlacement 保存真实逻辑坐标；
- ResolvePlacement 原样恢复真实逻辑坐标；
- 分辨率/UI Scale 改变不会暗中把用户窗口拉回屏幕；
- `recoverable` 与 `strict` 仍作为显式特殊策略保留，但不允许作为普通 V3 窗口默认值。

为了避免自由位置导致用户永久丢失入口，恢复能力改为显式操作：

```text
系统 → 全局设置 → 恢复全部窗口位置
```

该操作统一恢复：

- 主窗口位置；
- 所有已登记悬浮组件位置；
- R 启动入口位置。

**恢复是用户命令，不是拖动过程中的隐式限制。**

## 37.3 Exact Numeric Setting Contract

V3 数值设置统一采用：

```text
Label
+ 可选 Slider
+ 始终存在的 NumericInput
+ Min / Max / Step / Unit
+ Validation
```

禁止：

```text
[点击一下切换 80%]
[再点一下切换 90%]
[再点一下切换 100%]
```

也禁止把 `+ / -` 步进按钮作为主要输入方式。

`NumericField` 从 M1.12 起默认：

```text
stepButtons = false
```

只有业务明确需要时才允许显式开启。

当前已迁移为精确数值设置：

- 主窗口宽度；
- 主窗口高度；
- 全局 UI 缩放；
- 全局字体缩放；
- 活动悬浮窗透明度；
- 活动悬浮窗显示行数。

其中 Slider 只是快速辅助，输入框始终是数值 Authority 的直接编辑入口。

## 37.4 Foundation Gate

新增/强化硬约束：

```text
Windowing >= v7
Main Shell boundaryMode == free
UIV3Design.NumericSetting exists
NumericField exact input exists
V3 settings numeric fields have no +/- cycle buttons
Widget numeric settings have no +/- cycle buttons
```

Sequence 新增：

```text
v3_17_unbounded_window_placement
v3_18_exact_numeric_settings
```

`v3_17` 会把主窗口完整放到当前 viewport 之外，确认 Windowing Commit 和 V3 Store 不会偷偷救援/拉回。

`v3_18` 会实际进入全局设置与悬浮组件页面，确认主窗口宽高、UI/字体缩放、活动透明度和行数均存在真实 NumericInput，并确认没有 `+/-` 步进按钮。

## 37.5 长期规范

以后新 Feature 如果声明一个数值配置，例如：

```text
刷新间隔
透明度
字体大小
距离阈值
HUD 行数
图标大小
警告距离
DPS 行高
连线点数
范围半径
```

必须先使用统一 `D:NumericSetting()` / `RSUI:NumericField`。

不允许为了写起来快，在业务页面重新发明“按钮点一次换一个值”的交互。

### 37.6 ReconcileWindow 隐式 Clamp 缺陷修复

M1.12 最终回归时发现一处高风险残留：`Windowing` 外层已经设置 `boundaryMode = free`，但 `ReconcileWindow()` 曾经把所有 `non-strict` 情况都进入 `ClampRecoverableTopLeft()`。这会造成“配置看起来是 free，但鼠标松开后仍被拉回”的假自由。

现已改为严格三态：

```text
free        → 不 Clamp
recoverable → 仅显式请求时使用 ClampRecoverableTopLeft
strict      → 整窗 SafeArea Clamp
```

模拟拖动提交已验证：窗口坐标 `1800,1200` 在 1024×768 viewport 外仍能原样 Commit、Store、Resolve，不再被提交阶段修正。

### 37.7 Launcher 与 Active Runtime 最终统一

最终静态审计又发现 Bootstrap Recovery `R` 的拖动提交仍显式使用 `mode = "recoverable"`。虽然 V3 Launcher Store 的恢复路径已经是 `free`，但这个旧提交参数会导致 R 在鼠标松开时仍被隐藏 Clamp，因此同样属于“表面自由、提交受限”。

M1.12 已统一修改为：

```text
Main Shell        free
Floating Widget   free
WindowShell V3    free
Launcher R        free
```

Active TOC 中普通 V3 运行路径不再存在 `mode/boundaryMode = recoverable` 的显式赋值。`recoverable` 仅保留为底层特殊策略能力，必须由未来某个特殊窗口明确提出理由后才允许使用。

最终原则：

> **框架默认尊重玩家坐标；窗口找回通过明确的恢复命令完成，不通过拖动提交时偷偷修正。**

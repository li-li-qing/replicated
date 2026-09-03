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

## 16.2 Strangler Migration（已完成 · 历史方法论见 `Docs/Archive/Rebuild-History/STRANGLER_MIGRATION.md`）

旧版（Legacy/Professional）源码已于 2026-09-01/02 全部物理删除，Strangler 渐进迁移阶段已结束。当前 Replicated Suite 仅运行 V3 Framework，不再保留任何旧 UI / runtime 双轨。上述历史迁移流程图与约束仅作档案留存，不再作为未来任务。

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


## 附录：M1 执行 / 验收日志已归档

本蓝图的 M1 施工与验收日志（原 §31–§37，覆盖 2026-08-27 M1.1–M1.12）已移至 [`Archive/2026-08-27/REBUILD_BLUEPRINT_EXECUTION_LOGS.md`](../Archive/2026-08-27/REBUILD_BLUEPRINT_EXECUTION_LOGS.md)。
当前文件仅保留 §0–§30 的「重建方向蓝图」，作为长期架构方向参考；逐里程碑的执行 / 验收细节见归档文件。

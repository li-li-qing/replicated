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

V3 已彻底取消根级 `globals/` 运行时依赖。旧 `globals/` 目录已于 2026-09-01/02 随旧版代码一并物理删除（用户持有全量离线备份，插件树内绝不重新引入），不再随包；当前 V3 不再有任何根级 `globals/` 运行时依赖。

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

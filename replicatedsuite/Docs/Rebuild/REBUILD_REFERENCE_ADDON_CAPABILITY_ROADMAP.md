# Replicated Suite 参考插件能力吸收路线图

> **Authority Level**: REBUILD / PLANNING  
> **用途**: 记录外部 ArcheAge / ArcheRage Addon 中值得研究、吸收、改良或明确拒绝的产品能力。  
> **重要**: 本文不是 Runtime Authority，也不是“照搬清单”。任何能力只有在完成真实代码/API/RU 运行时证据审查、架构归属确认和用户最终决策后，才允许进入 `PRODUCT_COMPLETION_MATRIX.md` 或实现计划。

---

## 0. 文档目标

本项目的目标不是把其它 Addon 拼接进 Replicated Suite，而是：

```text
参考插件中的优秀产品思路 / 交互 / 数据利用方式
                         ↓
                   提炼真实能力
                         ↓
        检查 RU API / 数据 / 性能 / 生命周期证据
                         ↓
  使用 Replicated Suite 自己的 Core + Services + Feature + RSUI
                         ↓
             重新设计成更完整的新功能
```

长期目标仍然是一个：

- 单入口；
- V3-only；
- 模块独立启停；
- Authority 与 Presentation 严格分离；
- 高性能、按需运行；
- 可扩展；
- 配置长期兼容；
- 可诊断、可验证；
- 不依赖旧插件运行时；
- 不重新引入 Legacy / Professional / `globals/`。

本文用于我们之后逐项讨论。**当前记录 ≠ 已批准开发。**

## 0.1 UI / UX 与能力设计合并原则

从本版开始，**不再单独维护一份脱离页面的 UI/UX 设计文档**。

原因：Replicated Suite 面向正在游戏中的玩家；换装、治疗辅助、DPS、状态显示、范围辅助、活动、跑商、寻宝、诊断等页面的任务、信息密度和交互完全不同。统一视觉基础仍由 `Architecture/RSUI_ARCHITECTURE.md` 负责，但产品级布局必须和对应功能能力写在一起。

因此每个功能章节必须同时记录：

- 用户在这个页面要完成什么任务；
- 页面属于 Gameplay HUD / Floating Utility / Main Dashboard / Analysis / Configuration / Edit Mode 中哪一种；
- 默认 Gameplay View 显示什么、隐藏什么；
- 主页面布局和信息层级；
- 设置 / Inspector / Layout Edit Mode 如何组织；
- 1024×768 / 1080p / 2K 下如何重排；
- Busy / Empty / Error / Runtime Blocked 等状态如何反馈；
- 高频数据如何更新而不造成跳动、抢焦点和重建 UI；
- 最终 UI 讨论状态。

参考插件的窗口只能作为功能与交互证据，**禁止原样搬布局**。

### UI 讨论状态

| 状态 | 含义 |
|---|---|
| `UI_DISCUSS` | 只确定页面目标，布局未定 |
| `UI_DRAFT` | 已有第一版页面结构，等待逐项讨论 |
| `UI_REVIEW` | 关键布局、交互、响应式已基本确认 |
| `UI_APPROVED` | 用户确认，可进入实现 |
| `UI_IMPLEMENTING` | 正在实现 |
| `UI_RU_VERIFY` | 已实现，等待 RU 实机验证 |
| `UI_IMPLEMENTED` | 实机通过 |

当前本文新增页面蓝图默认均为 `UI_DRAFT`，只是讨论起点，不视为最终方案。

---

# 1. 参考源与使用边界

本轮参考工程主要包含：

1. `ArcheRage-addons-master`
   - 多个独立 Addon；
   - 包含正式模块、`z_pub_wip`、`z_trash`；
   - 适合研究 API 用法、功能思路和交互模式；
   - WIP/Trash 只能作为实验性证据，不能视为成熟实现。

2. 独立 Addon 集合
   - `RaidSchedules`
   - `SmartFisherman`
   - `TreasureMapHunter`
   - `combatcloset`
   - `packratio`
   - `wbdebuff`
   - 以及同目录其它工具。

3. 旧式综合框架/公共 `globals`
   - 只允许作为**历史行为与 API 参考证据**；
   - Replicated Suite 当前 `globals/` 已物理删除；
   - **禁止重新加入 Active Runtime、禁止作为当前依赖、禁止当作当前迁移目标。**

## 1.1 参考代码的证据等级

| 等级 | 含义 | 可用于什么 |
|---|---|---|
| R0 | 仅文件名/README 描述 | 发现产品想法 |
| R1 | 读到实际 Lua 调用链 | 确认旧插件确实做过某件事 |
| R2 | 能确认使用的 Native API / 返回字段 | 建立 API 候选证据 |
| R3 | 与当前 `z_api_functions` / 当前 Suite API 治理一致 | 进入当前实现设计候选 |
| R4 | 当前 RU 客户端 Fresh Reload 实测通过 | 才能视为 Runtime Verified |

**旧插件能运行过，不等于当前 RU API 仍然可用。**

---

# 2. 能力决策状态

以后逐项讨论统一使用这些状态：

| 状态 | 含义 |
|---|---|
| `DISCUSS` | 已发现，等待我们讨论产品形态 |
| `ACCEPT` | 产品能力方向确认，准备进入设计 |
| `ACCEPT_MODIFIED` | 接受核心想法，但明确不照搬原实现 |
| `REJECT` | 明确不进入 Suite |
| `RUNTIME_BLOCKED` | 产品上希望保留，但缺当前 RU API/返回结构/权限证据 |
| `DESIGN_READY` | 架构归属、Authority、Service、Projection、RSUI、Persistence 已设计完成 |
| `IMPLEMENTING` | 已进入代码实现 |
| `RU_VERIFY` | 本地完成，等待 RU 实机验证 |
| `IMPLEMENTED` | 实现并通过所需验证 |

默认状态全部为 `DISCUSS`。

---

# 3. 优先级定义

- **P0**：直接对应当前用户回归问题，或能形成高复用 Foundation。
- **P1**：明显增强现有核心功能，价值高。
- **P2**：重要扩展能力，但可在核心体验稳定后推进。
- **P3**：低优先级便利功能、开发工具或实验能力。

优先级不等于开发顺序。实际开发前仍需结合：

- 当前 Bug；
- 共享底层价值；
- RU API 证据；
- 依赖范围；
- 性能成本；
- 用户最终决定。

---

# 3.1 游戏插件页面设计共同底线

这些是所有页面共享的最低要求，但**不规定页面必须长得一样**。

1. **Gameplay First**：正常游戏界面优先保证视野与决策速度，复杂设置进入设置页或编辑模式。
2. **任务优先于装饰**：先确定玩家要做的动作，再决定 Card / List / Table / Inspector。
3. **稳定几何**：实时数据变化不能让行高、列宽、窗口位置持续跳动。
4. **渐进披露**：默认只显示当前任务所需信息；高级参数、Raw ID、诊断证据后置。
5. **明确反馈**：写操作至少区分 Idle / Pending / Verified Success / Failed，不允许点击后“像没反应”。
6. **数值直接编辑**：字号、透明度、距离、刷新周期、Offset、尺寸等使用明确数值控件，不使用循环档位按钮。
7. **响应式重排**：1024×768 不是把 1080p 页面整体缩小，而是收起 Inspector、改双栏/单栏、允许详情抽屉。
8. **统一 RSUI Foundation**：WindowShell、FloatingSurface、Tooltip、NumericField、Dropdown、Scroll、DataView、IconPicker、Z-Layer、Diff Rendering 等只能使用统一底层。
9. **高频 HUD 不全量重建**：战斗、治疗、距离、Aura、连线和范围投影必须使用 diff / bounded refresh / demand-driven update。
10. **颜色只表达状态**：颜色不能同时承担分类、优先级、选中、告警四种含义；危险、选中、不可用必须能清楚区分。

## 3.2 主入口 / 首页 UI 蓝图

**页面目标**：玩家打开 Suite 后 1～2 秒内知道“现在最值得关注什么”，并快速进入对应模块。

**Surface**：Main Dashboard。  
**UI 状态**：`UI_DRAFT`。

### 桌面/1080p+

```text
┌────────────────────────────────────────────────────────────────────┐
│ Replicated Suite                  当前角色 / 区域 / 诊断状态      │
├──────────────┬─────────────────────────────────────────────────────┤
│ 战斗         │ 今日概览：收益 / 任务 / 活动 / 资源                │
│ 团队         ├──────────────────────────┬──────────────────────────┤
│ 生活         │ 即将发生 / 活动时间       │ 今日任务 / 周常          │
│ 工具         │                          │                          │
│ 设置         ├──────────────────────────┴──────────────────────────┤
│              │ 债券 / 居民板重点信息（允许占更大区域）            │
│              ├─────────────────────────────────────────────────────┤
│              │ 当前启用模块状态 / 快捷入口 / 最近异常              │
└──────────────┴─────────────────────────────────────────────────────┘
```

### 首页原则

- 不做“我的常用”这种需要用户二次维护的区域；
- “今日收益”集中展示，不散落到多个卡片；
- 债券 / 居民板因为信息量大，允许拥有更大的首页区域；
- 即将发生的活动按时间排序；
- 异常/未完成/即将发生优先于普通静态信息；
- 点击摘要直接进入对应页面或详情，不再经过多层菜单；
- 主导航保持稳定，不因模块开关重排位置。

### 1024×768

- 左侧导航缩窄但保留中文文字，不只显示难以理解的图标；
- 首页改为单主列 + 可折叠区块；
- 债券、活动、任务只保留摘要，点击后进入完整页面；
- 禁止为了塞入所有内容把字体整体缩得过小。

---


## 3.3 Foundation First：先把页面组合能力做强，再逐页定稿

当前阶段的正式执行策略改为：**先完善 RSUI 的页面级组合能力，再逐页把 UI 从 `UI_DRAFT` 推到 `UI_APPROVED`，最后才进入大规模业务实现。**

原因不是现有底层弱，而是现有底层已经具备很多类似 UMG 的 Primitive / Panel / DataView / Form 组件，现在最缺的是比 `HorizontalBox / VerticalBox` 再高一级的**稳定页面组合模板**。如果继续让每个页面自己手拼几十个 Box，最终仍会出现：

- 同类页面左右栏宽度完全不同；
- 同样的筛选条在不同页面高度、间距、按钮排列不同；
- Inspector 有的放右侧、有的塞正文、有的弹 Modal；
- 1024×768 的降级策略各写一套；
- 页面代码越来越长，业务 Presenter 被布局噪声淹没；
- 一个底层交互 Bug 需要修改十几个页面。

因此 UI Foundation 分成四层：

```text
L0 Native Adapter
   └─ CreateLabel / Button / Edit / Drawable / Window ...

L1 RSUI Primitive / Panel
   └─ Text / Icon / Button / Border / Grid / Overlay / Scroll / SplitView ...

L2 RSUI Composite / Workspace Template
   └─ FormRow / GroupBox / Toolbar / MasterDetail / InspectorWorkbench /
      SettingsWorkbench / CommandCenter ...

L3 Feature Page / HUD
   └─ Gear / Buff Display / Healer / DPS / Activities / Trade ...
```

**Feature 页面原则上只组合 L2，只有确实没有合适模板时才直接大量组合 L1。**

### 3.3.1 `.18.62` 已加入的页面级模板

`.18.62` 已加入四个低风险、复用率高的组合模板：

| 模板 | 结构 | 首批适用页面 |
|---|---|---|
| `MasterDetailWorkspace` | 左 Master + 右 Detail，可拖动 Split | Gear、DPS、Tasks、Bonds、Diagnostics |
| `InspectorWorkbench` | 左 Navigator + 中 Preview/Canvas + 右 Inspector | Buff Display、Range Assist、Unit Lines、Layout Editor |
| `SettingsWorkbench` | 左设置分类/元素列表 + 右属性内容 | 大型设置页、HUD 编辑器、规则编辑器 |
| `CommandCenterWorkspace` | Header + Status Strip + Overview/Exception Queue + Evidence | Raid Readiness、Boss Mechanic、Activities Command View |

这些模板只负责 Presentation 几何，不拥有业务状态，也不直接读 Native API。

### 3.3.2 统一 Breakpoint / Density

`.18.62` 已加入共享逻辑宽度带：

```text
compact    <= 720
regular    721..980
wide       981..1180
ultrawide  > 1180
```

这不是“屏幕分辨率硬编码”，而是**当前页面实际可用逻辑宽度**。同一个 1920×1080 屏幕上的窄悬浮窗仍可能属于 compact。

Density 统一为：

- `compact`：23～26 行高，缩减 P2/P3 文字，保持操作命中区；
- `normal`：28～32 行高，主页面默认；
- `spacious`：仅适用于超宽设置/编辑器，不用于战斗 HUD。

### 3.3.3 当前底层能力盘点

**已经足够强，直接复用：**

- `HorizontalBox / VerticalBox / Grid / Overlay / Border / SizeBox`；
- `UniformGrid / WrapBox / ScrollBox / WidgetSwitcher / ScaleBox / SplitView`；
- `ResolutionRoot / SafeZone / CanvasPanel / AspectRatioBox`；
- `VirtualList / TileView / TableView / SelectionModel`；
- `Toggle / SegmentedSelector / TextInput / NumericInput / Slider / Dropdown / ColorField`；
- `Field / ToggleField / NumericField / DropdownField / Form / FormSection`；
- `Tooltip / ContextMenu / Focus / ActionRunner / ViewState / Binding`；
- `WindowShell / FloatingSurface`；
- `FormRow / KeyValueRow / Toolbar / HeaderBodyFooter / GroupBox / CollapsibleGroup / DetailRow / Steps / SplitToolbar`。

**Composite Foundation 当前推进：**

1. `TreeModel + TreeView`：`.18.64` 当前为 **TreeModel v2 / TreeView v1**。稳定 Key 已升级为强制契约，Mutation 使用 staged build → validate → commit，失败完整回滚；展开态为 true/false/nil 三态 override，并有长期 expansion-state hard cap。首批目标仍是状态显示元素树、任务分组、规则树；`OutlineView` 不另造第二套 Authority，等真正需要 inline rename/drag-reorder 时扩展。
2. `StatusChip`：`.18.63` 已实现 v1；统一 neutral/info/pending/success/warning/error/blocked/unavailable 语义视觉。
3. `PopupCoordinator`：`.18.63` 已实现 v1；Dropdown / ColorField / ContextMenu 共用 single registry、互斥打开、统一 popup Z token。
4. `PickerModel`：`.18.64` 已实现 v1；稳定 Key、显式 Query、transactional SetItems/SetQuery、AND-token filter、stable selectedKey、bounded scan/results。它是 SearchablePicker / IconPicker 的共享数据 Authority。
5. `SearchablePicker / SearchableDropdown`：**`.18.65` SearchablePicker v1 已完成**。复用 PickerModel，使用 Enter/EditEnter 或显式搜索按钮提交；当前 RU 未验证 generic OnKeyDown/实时 OnTextChanged，因此不猜桌面式实时搜索/键盘导航。
6. `IconPicker`：**`.18.65` 已完成 v1 Presentation**；复用 `PickerModel + virtual TileView + Image + selected preview`，Gear、Buff、技能 CD、Profile 共用；业务只投影稳定 key、搜索文本与已解析 icon path，Foundation 不复制 Metadata/过滤/选择 Authority。
7. `Focus Contract`：`.18.64` 已升级 v2；Set/Clear/IsFocused 都按具体 target Native 能力判断。Foundation Audit 同时 fence 未验证 `OnKeyDown / OnKeyUp / OnTextChanged`。
8. `Drawer / ResponsiveInspector`：**`.18.65` 已完成第一版 Stable-Host Foundation**；compact 页面把右 Inspector 收为同实例抽屉，不复制详情组件、不做 Native reparent。后续若多个页面需要模态遮罩/点空白关闭，再下沉共享 Scrim/Drawer Surface。
9. `Breadcrumb / DetailHeader`：**`.18.82` Foundation v5 已落地 `DetailHeader` Composite**（`crumb={"A","B"}` 渲染 `A › B` + 标题 + 可选 StatusChip；`SetCrumb/SetTitle/SetStatus`）；深层详情页接入仍等具体页面迁移。
10. `Empty/Loading/Error/Blocked` 组合态模板：**`.18.82` 已落地 `StateNotice` Composite**（chip + message + 可选 hint；`ResolveStatusSemantic` 是 status→tone/默认文案唯一 Authority；未知状态 fail-closed 拒绝）。design_system `EmptyState` 保留为静态"尚未迁移"占位，不承担状态语义。
11. `LayoutEditorOverlay v1`：共享 Foundation 已完成；统一拖拽框、8 向 Handle、锚点/轴心、吸附、对齐线与事务 Preview/Commit；Buff/Healer/Range 只接 Projection/Persistence，不能各写一套。

### 3.3.4 页面布局统一栅格

不要求所有页面长一样，但必须遵守统一几何节奏：

```text
Page Padding       12
Section Gap        12
Panel Gap           8
Dense Gap           4~6
Standard Row       28
Compact Row        23~26
Toolbar             32~34
Section Header      28
Primary Action      30~34
```

左右栏不是用任意像素拍脑袋：

- 普通 Master Rail：约 220～260，最小 168～184；
- Inspector：约 260～320，最小 220；
- 主 Preview / Table：永远优先拿剩余空间；
- 主工作区不得因为左右工具栏过宽而缩成“中间一条缝”。

### 3.3.5 对齐硬规则

1. 同一列所有 Label 左边缘一致；
2. 同一组 NumericField 的输入框右边缘一致；
3. 表格中的数值默认右对齐，名称/描述左对齐；
4. Toolbar 的主操作靠左，页面级次操作靠右；
5. 同组按钮高度统一，不允许 24/26/31 混排；
6. 同一级 Section 的 Header 高度一致；
7. Card 只用于真正需要边界的“信息对象”，不能每一个设置项套 Card；
8. P3 ID / Raw Evidence 不进入默认行高，放 Tooltip / Detail / Advanced。

### 3.3.6 页面代码目标

以后页面代码应更接近：

```text
Build Workspace
→ Build Header / Filters
→ Bind Projection
→ Build DataView
→ Build Inspector
```

而不是：

```text
Create HorizontalBox
Create VerticalBox
Create HorizontalBox
Create Button
Create Button
Create Label
手算宽度
再 Create HorizontalBox ...
```

如果一个新的页面需要重复 3 次以上相同布局模式，应优先判断是否应该下沉 RSUI Composite。

---
# 4. Gear / 换装能力

| ID | 来源 | 参考能力 | 我们要吸收的价值 | Replicated Suite 方向 | 优先级 | 状态 |
|---|---|---|---|---|---|---|
| `REF-GEAR-001` | `gearswap` / `combatcloset` | 装备槽位记录 | 不只存名字，而是明确槽位身份 | 强化 `GearServiceV3` 的 Slot Authority | P0 | DISCUSS |
| `REF-GEAR-002` | `combatcloset` | 同名装备词条识别 | 解决同名不同词条/品质装备错配 | 建立 Item Fingerprint：slot + item identity + 可验证属性指纹 | P0 | DISCUSS |
| `REF-GEAR-003` | `gearswap` | 装备执行队列 | 换装不是一次性盲写，而是事务序列 | Gear Command Transaction / Queue | P0 | DISCUSS |
| `REF-GEAR-004` | `gearswap` | 失败重试 | Native 写入失败/冷却后恢复 | 有界 Retry + Cooldown + Failure Reason | P0 | DISCUSS |
| `REF-GEAR-005` | `titleswap` 的思想 | 执行后验证 | “调用成功”不等于“游戏状态已改变” | Request → Pending → Readback Verify → Success/Failed | P0 | DISCUSS |
| `REF-GEAR-006` | `gearswap` | 方案内容预览 | 用户能清楚看到一个方案有哪些装备 | Gear Projection 增加方案详情/缺失/匹配状态 | P0 | DISCUSS |
| `REF-GEAR-007` | `gearswap` / `combatcloset` | 自定义方案图标 | 快速识别方案 | 下沉公共 RSUI `IconPicker` | P0 | DISCUSS |
| `REF-GEAR-008` | 两者 | 方案排序 | 用户自定义快捷方案顺序 | Permanent `displayOrder` | P0 | DISCUSS |
| `REF-GEAR-009` | `gearswap` | 执行中禁用按钮/反馈 | 避免重复点击造成竞态 | ActionRunner/Command Projection 暴露 Pending | P0 | DISCUSS |
| `REF-GEAR-010` | 综合提炼 | 缺件定位 | 不只是“换装失败”，应指出哪件缺失/冲突 | Transaction Result 明确 slot/item/reason | P0 | DISCUSS |

## Gear 需要重点讨论

当前 Suite 已有 `.18.61` Gear 事务修复，但参考 Addon 暴露出一个更完整的方向：

```text
GearPreset
   ↓
Resolve Items
   ↓
Build Transaction Plan
   ↓
Execute one bounded step
   ↓
Native cooldown / retry
   ↓
Readback verification
   ↓
Success / Partial / Failed + exact reason
```

这套 Transaction 模式后续还可以复用于：Title、Team Role、Marker、Bag Move 等写操作。

---

## 4.1 换装页面 UI 蓝图

**页面目标**：快速选择方案、确认方案内容是否完整、执行换装，并能明确看到失败发生在哪个槽位。  
**Surface**：Main Dashboard + Floating Quick Bar。  
**UI 状态**：`UI_DRAFT`。

### 主页面

```text
┌ 方案列表 ─────────┬ 当前方案 / 装备槽预览 ─────────────┬ 方案检查 ─────────┐
│ PVP 奶            │ 头 / 胸 / 腿 / 手 / 脚            │ 完整 15/16        │
│ PVE 奶            │ 主手 / 副手 / 弓 / 乐器 / 背部    │ 缺：副手          │
│ 坦克              │ 饰品 / 称号 ...                   │ 冲突：主手×2      │
│ ...               │ [装备图标 + 当前匹配状态]         │                  │
├───────────────────┴────────────────────────────────────┴──────────────────┤
│ [立即换装] [仅检查] [编辑方案]      执行状态：Pending / 12/16 / Verified │
└───────────────────────────────────────────────────────────────────────────┘
```

### 交互

- 方案点击一次仅选择，不立即执行，避免误换；
- 双击/明确“立即换装”才执行；
- 执行期间按钮进入 Pending，显示当前槽位进度；
- 部分成功必须显示“哪些已经换、哪些没有换”；
- 方案详情允许直接查看 Item Fingerprint / 缺失原因，但 Raw ID 放高级详情；
- 图标、名称、排序在“编辑方案”中完成。

### 游戏内快捷条

```text
[PVP] [PVE] [坦克] [采集]   当前：PVP奶   ●已验证
```

默认不显示大标题，不显示全部装备详情；失败时只展开一条紧凑错误提示。

### 1024×768

方案列表 + 装备槽保留双栏；右侧“方案检查”改为可展开 Inspector Drawer。


## 4.2 换装页面详细布局规格 v2

#### A. 主页面组件树

```text
PageRoot
└─ VerticalBox
   ├─ PageHeader                         34
   ├─ SummaryStrip                      58~64
   ├─ MasterDetailWorkspace             Fill
   │  ├─ Master / PresetList            220~260
   │  └─ Detail
   │     ├─ DetailHeader                32
   │     ├─ EquipmentSlotGrid           Fill
   │     └─ TransactionPanel            90~130
   └─ FooterStatus                      28~30
```

推荐默认比例：方案列表约 **24%**，装备/事务区域约 **76%**。方案列表只负责“选择与管理”，不要同时塞完整装备详情。

#### B. 方案列表

每行固定 30 左右：

```text
[Icon 20]  PVP 奶                 [完整]
           当前装备匹配 15/16
```

默认只显示：Icon、方案名、完整性状态。装备数量、更新时间、Raw ID 进入 Tooltip/Inspector。选中使用背景/边框，不使用红绿颜色表达选中。

列表顶部：`搜索`、`+ 新建`；排序/导入/导出进入 `更多`，避免工具栏过满。

#### C. 装备槽预览

采用固定语义分组，而不是一个巨大 16 格无层级网格：

```text
防具：  头  胸  腿  手  脚  腰  腕
武器：  主手  副手  远程  乐器
其他：  项链  耳环...  背部  称号
```

每个 Slot Tile 至少包含：Icon、槽位名、匹配状态；鼠标悬浮再显示完整物品名/指纹。缺失用边框/小状态标记，不让整张 Tile 变大红块。

#### D. Transaction Panel

固定在详情下方，不因装备数量变化上下跳动：

```text
状态：正在换装  9/16
当前：副手 · XXXXX
[██████████████--------]
已完成 9  · 跳过 4 · 待处理 3
[取消/停止]                         [查看详情]
```

成功后收敛成一行；失败才展开 Error Detail。这样普通成功流程不占空间。

#### E. Compact / 1024×768

- Master 保持约 190～220；
- 装备区优先保留；
- Transaction detail 改为折叠区；
- “方案检查”不常驻第三栏，放 Detail 内部或 Drawer；
- 快捷条与主页面完全独立，不因为主页面开着而重复显示大块状态。

#### F. Foundation 依赖

`MasterDetailWorkspace + TileView/UniformGrid + ActionRunner + ViewState + Tooltip + IconPicker(v1 已有)`。

---

# 5. Buff Display / 状态显示 / Unit HUD

| ID | 来源 | 参考能力 | 我们要吸收的价值 | Replicated Suite 方向 | 优先级 | 状态 |
|---|---|---|---|---|---|---|
| `REF-STATUS-001` | `extendedplates` | Target Buff/Debuff 追踪 | 只显示关心的状态 | `AuraObservationV3` + Buff Display Tracking | P1 | DISCUSS |
| `REF-STATUS-002` | `extendedplates` | Self Buff/Debuff 追踪 | 自身也可独立追踪 | Scope=`player` | P1 | DISCUSS |
| `REF-STATUS-003` | `extendedplates` | WatchTarget Buff/Debuff | 焦点目标长期观察很有价值 | Scope=`watchtarget` | P1 | DISCUSS |
| `REF-STATUS-004` | `extendedplates` / `hiddendebufftracker` | Hidden 状态 | 独立显示隐藏效果 | 先验证 Aura contract，再纳入统一分类 | P1 | DISCUSS |
| `REF-STATUS-005` | `extendedplates` | 点击 Buff 即追踪/取消 | 交互成本极低 | Observation Browser Toggle | P1 | DISCUSS |
| `REF-STATUS-006` | `extendedplates` | 当前目标状态自动发现 | 不用手填大量 ID | 只做 session discovery，不自动写 Permanent | P1 | DISCUSS |
| `REF-STATUS-007` | `extendedplates` | Buff 导入/导出 | 快速迁移大量规则 | Profile + Preview + Merge/Replace | P1 | DISCUSS |
| `REF-STATUS-008` | `extendedplates` | 图标增长方向 | 布局更自由 | Flow Direction | P1 | DISCUSS |
| `REF-STATUS-009` | `extendedplates` | Buff 层数 | 战斗信息更完整 | Aura Projection 标准字段 | P1 | DISCUSS |
| `REF-STATUS-010` | `extendedplates` | Buff 剩余时间 | 状态判断更直观 | time + threshold formatting | P1 | DISCUSS |
| `REF-STATUS-011` | `buffcaptracker` | Buff Cap 提醒 | 接近状态上限时提醒 | 轻量 Status Alert Rule | P1 | DISCUSS |
| `REF-STATUS-012` | `bigcastbars` | 大号施法条 | 远距离/战斗更易读 | Buff Display CastBar Component | P1 | DISCUSS |
| `REF-STATUS-013` | `classtracker` / `extendedplates` | 职业识别 | 三技能树映射到职业/职责 | UnitIdentity/Class Metadata | P1 | DISCUSS |
| `REF-STATUS-014` | `extendedplates` | 装备分数 | 头顶快速判断 | Unit HUD 可选组件 | P1 | DISCUSS |
| `REF-STATUS-015` | `extendedplates` | 主手/副手/远程/背部装备 | 战场读人能力 | Unit Equipment Snapshot + HUD | P1 | DISCUSS |
| `REF-STATUS-016` | `disttracker` | 距离阈值颜色 | 超距立即可见 | 公共 `ThresholdColor` | P1 | DISCUSS |
| `REF-STATUS-017` | `extendedplates` | 技能 CD 观察器 | 记录目标近期技能并追踪 CD | Combat Cooldown Observation Feature | P1 | DISCUSS |
| `REF-STATUS-018` | `extendedplates` | 技能自动记录模式 | 不用提前知道所有技能 ID | EventBus recording session | P1 | DISCUSS |
| `REF-STATUS-019` | `extendedplates` | 自定义技能 ID | 高级用户手动补充 | SkillMetadataV3 | P1 | DISCUSS |
| `REF-STATUS-020` | `extendedplates` | CD 自定义图标 | 更清楚辨识技能 | 公共 IconPicker | P1 | DISCUSS |
| `REF-STATUS-021` | `extendedplates` | CD 横/竖布局 | 不同 HUD 使用方式 | RSUI Flow Layout | P1 | DISCUSS |

### 状态显示最终产品方向候选

状态显示不应只是“Buff 图标插件”，而应该逐渐成为：

```text
Unit HUD Composition
├── Identity：名字 / 职业 / 装分 / 距离
├── Equipment：主手 / 副手 / 远程 / 背部
├── Aura：Buff / Debuff / Hidden / Stack / Duration
├── Cast：施法条 / 技能信息
├── Cooldown：观察技能 CD
└── Layout：所有组件独立开关 / 位置 / 大小 / 字号 / 透明度
```

但各数据 Authority 仍然必须独立，Buff Display 只负责产品组合与 Presentation，不能变成超级 Service。

---

## 5.1 状态显示页面 UI_APPROVED v3

**页面目标**：让玩家在战斗中只看到真正有用的单位信息；配置页负责“发现/追踪状态”和“编辑 HUD 布局”，Gameplay HUD 本身保持低干扰。  
**Surface**：Gameplay HUD + Configuration + Layout Edit Mode。  
**UI 状态**：`UI_IMPLEMENTING`（2026-09-03，本地实现完成 / RU Fresh Reload 待验）。`.18.79` 完成 Authority Cleanup；`.18.80` 已落地三页签、单虚拟 Tracking Table 与 `LayoutEditorWorkspace v2 + LayoutEditSession`，并把 HUD Working 与 Persistence getter 隔离。

### 5.1.1 本轮先以真实现有代码为边界

本轮不是按旧截图或参考 Addon 猜页面，而是实际审查当前：

- `features/combat/buff_display/rs_buff_display_store.lua`（Store schema 4）；
- `features/combat/buff_display/rs_buff_display_feature.lua`（Demand / Projection / Commands）；
- `presentation/v3/pages/rs_v3_buff_display_page.lua`（当前四页签设置页）；
- `presentation/v3/widgets/rs_v3_buff_head_markers.lua`（真实头顶 HUD Renderer）；
- `services/rs_aura_observation_v3.lua` / `rs_buff_metadata_v3.lua` / `rs_status_classification_v3.lua`；
- `.18.75~.18.78` 的 `LayoutEditHistory / EditorCommandBar / LayoutEditSession / LayoutEditorWorkspace`。

因此当前 UI_REVIEW 固定以下**事实边界**：

| 当前事实 | UI_REVIEW 决定 |
|---|---|
| Store schema 4 只有 `player / target` 显示范围开关 | 本轮只设计“自己 / 当前目标”；`watchtarget` 不进入当前 UI，不因为参考插件存在就虚构能力 |
| `components` 几何当前是**一套共享 HUD 模板**，不是 player/target 两份布局 | Scope 只决定“渲染到哪里 / Preview 看谁”，**不复制两份几何 Store**；避免迁移成本、设置分叉与双 Authority |
| `plate` 是“原生血条代理矩形”，Renderer **不会画血条** | UI 改名为“对齐基准（原生血条）”；Preview 可以画辅助框，但 Gameplay HUD 不新增假血条 |
| `info` 已经统一负责“职业 · 装分 · 距离”的几何 | 删除页面上 `info.*` 与 `components.class/gearScore/distance` 的重复位置语义；三个子项只拥有显隐，位置/字号归 `顶部信息` 根节点 |
| `headIconSize / headMaxIcons` 实际只是 Buff/Debuff component 的代理写入 | UI 不再同时暴露“全局图标大小/最多图标”与 Buff/Debuff 卡片同名设置；只保留一套可解释字段 |
| `plate.enabled / opacity / showName` 当前为兼容字段，Renderer 不消费 | 不在普通 Inspector 暴露无效设置；只保留真实生效字段 |
| 当前目标装备图标因 RU `GetEquippedItemTooltipInfo` 作用域证据不足而 fail-closed；玩家自己装备可读 | Preview/Inspector 必须显示能力提示，**不能承诺目标武器/背部图标已可用**；取得 RU 证据前不伪造 |
| 当前 Tracking/Component 改动普遍立即 `MarkDirty` | 状态追踪操作可继续即时保存；**布局编辑必须改用 LayoutEditSession staged Working，只有 Apply 才持久化** |
| 当前页面“恢复默认”会同时清布局、追踪 ID、分类 | UI_REVIEW 禁止继续使用这个危险的混合按钮；Layout `Reset` 只恢复布局默认，追踪页“清空追踪”只清 tracked list |
| Cooldown / WatchTarget / Name HUD 不在当前实现 | 不放入当前一级 Tab/Element Tree；未来能力通过独立设计决策进入，禁止先造空壳 |

### 5.1.2 Gameplay HUD 的唯一默认几何

用户已明确希望以原生血条为视觉中心，因此 Review 采用**固定语义区域 + 可微调 Offset**，而不是让每个元素完全自由漂移后互相重叠：

```text
             职业 · 装分 · 距离
          [Buff][Buff][Buff][Buff]
 [主手][副手]   ┌ 原生血条 ┐   [背部]
                └─────────┘
        [Debuff][Debuff][Debuff]
                 施法条
```

规则：

1. 原生血条只作为**不可见运行时基准**；Preview 中显示虚线/辅助框帮助校准。
2. 顶部信息永远在“实际 Buff 最上行”之上；没有 Buff 时自动贴近血条上方，不为 MaxRows 预留空洞。
3. Buff 从血条上缘向上增长；Debuff 从血条下缘向下增长。
4. 主手 / 副手位于血条左侧；背部位于右侧。
5. 远程装备保留为可选组件：Fresh Default **关闭**；启用后位于左侧装备组外层，不挤占主手/副手靠血条的核心位置。`.18.79` 已统一 Runtime/Acceptance。
6. 施法条位于 Debuff 实际占用区域下方；不允许与 Debuff 最大行数按空白预留拉开巨大距离。
7. 所有位置遵守左上原点：`+X=右 / -X=左 / +Y=下 / -Y=上`；Inspector 标签必须继续显示方向语义。
8. 每个可见组件都可独立关闭；关闭后相邻布局应**折叠空位**，不得留下“看不见但占位”的洞。

### 5.1.3 一级页面收敛为 3 个用户任务

当前四页签：

```text
状态追踪 | 头顶显示 | 布局外观 | 导入导出
```

Review 后收敛为：

```text
[追踪管理] [HUD 布局] [导入 / 导出]
```

- **追踪管理**：发现状态、搜索、过滤、点击追踪/取消、冻结列表、清理追踪。
- **HUD 布局**：显示范围 + 元素树 + 实时 Preview + Inspector + Undo/Redo/Revert/Reset/Apply。
- **导入/导出**：快速 ID + 完整 Profile 文本迁移。

`头顶显示` 与 `布局外观` 不再分成两套设置，因为它们实际修改的是同一个 HUD Template；分开只会产生重复开关和重复 NumericField。

### 5.1.4 追踪管理：单表 Authority Projection

当前页面把“自己”和“目标”强行做成两张并排 Table；1024×768 下信息密度差，而且同一状态可能让用户来回找。现有 Feature 已提供 `GetProjection("all")` 与 `GetTrackedList()`，因此 Review 采用**一个虚拟 Table + 来源筛选**：

```text
┌──────────────────────────────────────────────────────────────┐
│ [全部] [自己] [当前目标] [已追踪]  [Buff] [Debuff] [隐藏] │
│ 搜索名称 / ID ...                         [冻结列表]        │
├────┬──────────────────┬────────┬──────┬────┬──────┬────────┤
│图标│ 名称             │ 类型   │ 来源 │ 层 │ 剩余 │ 追踪   │
├────┼──────────────────┼────────┼──────┼────┼──────┼────────┤
│    │ ...              │ Buff   │ 自己 │ 2  │ 8.4  │ 已追踪 │
└────┴──────────────────┴────────┴──────┴────┴──────┴────────┘
```

交互：

- 点击状态行 = 一次追踪；再次点击 = 取消追踪，不弹二次确认；
- `ID` 默认不占主列宽，可通过 Tooltip / Advanced Detail 查看；搜索仍支持 ID；
- `只看隐藏` 不再伪装成永久显示策略，而是 Tracking Browser 的来源/筛选条件；Hidden detection source 与 Buff/Debuff category 继续分离；
- `清空追踪` 只影响 tracked IDs，不触碰布局、分类、Widget Window；
- `冻结列表` 只控制浏览器观察体验，不改变头顶白名单语义；
- Table 继续使用有界/虚拟列表，刷新只 Diff 当前 projection，不按状态数量创建永久 Native Row。

### 5.1.5 HUD 布局：Element Tree + LayoutEditorWorkspace

Review 不再让页面自己手拼 10 张 Numeric Card，而是消费已经完成的 `.18.78 LayoutEditorWorkspace v2`。

```text
┌ 元素树 ───────────┬ LayoutEditorWorkspace ───────────────────────────────┐
│ Unit HUD          │ [撤销][重做][还原][重置][应用]  Preview Scope:自己 │
│ ├ 对齐基准        │ ┌──────────────────────────────────────────────────┐ │
│ ├ 顶部信息        │ │              职业 · 装分 · 距离                │ │
│ │ ├ 职业          │ │           [Buff][Buff][Buff]                   │ │
│ │ ├ 装分          │ │ [主手][副手]  - - 原生血条 - -   [背部]        │ │
│ │ └ 距离          │ │          [Debuff][Debuff]                      │ │
│ ├ Buff            │ │                 施法条                         │ │
│ ├ 装备            │ └──────────────────────────────────────────────────┘ │
│ │ ├ 主手          │                         Inspector → wide inline     │
│ │ ├ 副手          │                         / compact drawer           │
│ │ ├ 远程          │                                                    │
│ │ └ 背部          │                                                    │
│ ├ Debuff          │                                                    │
│ └ 施法条          │                                                    │
└───────────────────┴────────────────────────────────────────────────────┘
```

**Element Tree 规则**：

- Tree 使用稳定 Element Key：`anchor/info/class/gearScore/distance/buffs/equipment/mainHand/offHand/ranged/wings/debuffs/castBar`；
- 展开/选择属于 Session UI state，不写 Feature Store；
- 点击节点只选择 Inspector 目标；显隐操作走明确 Toggle，不把“选中”当“开关”；
- `对齐基准` 不提供显隐开关，因为 Gameplay 不绘制它；只编辑 proxy width/height/x/y；
- `顶部信息` 根节点拥有 X/Y/Font，职业/装分/距离子节点只拥有 enabled；
- `装备` group 只用于导航，不建立第二份 group Store；孩子继续映射现有 component keys；
- 不出现 `HealthBar / Name / CooldownRegion / WatchTarget` 等当前没有真实 Runtime owner 的节点。

**Inspector 分组**：

- `对齐基准`：Width / Height / X / Y / Global Scale；
- `顶部信息`：Enabled / X / Y / Font Size；子节点只显示 Enabled + 当前能力状态；
- `Buff / Debuff`：Enabled / X / Y / Icon Size / Alpha / Spacing / Max Per Row / Max Rows；
- `主手 / 副手 / 远程 / 背部`：Enabled / X / Y / Icon Size / Alpha；
- `施法条`：Enabled / X / Y / Width / Height / Font Size / Alpha / Show Spell Name；
- `全局 Aura 文本`：Stack / Remaining Time 两个真实全局开关放到 Aura section，不再和组件卡片重复；
- 刷新周期等性能参数进入 `Advanced`，明确单位与合法范围，不占主操作区。

### 5.1.6 Layout Edit Session / Persistence

HUD 布局是 `.18.78` Foundation 的第一个正式业务 Consumer，必须严格使用：

```text
Persisted
   ↓ open editor
SessionBaseline
   ↓ drag / numeric / toggle
Working  ── Preview only
   │
   ├─ Undo / Redo   → History only
   ├─ Revert        → SessionBaseline，不写 Store
   ├─ Reset         → Layout Defaults staged，不写 Store
   └─ Apply         → 唯一 durable persistence crossing
```

禁止继续沿用当前“每动一个 Slider 就 `MarkDirty`”的布局编辑路径。Tracking/Classification 属于独立产品操作，可以继续即时持久化；**Layout Working 与 Tracking Store Mutation 不得混成一个事务**。

`Reset` 的作用域只包含 HUD 布局/外观/显示范围；**绝不清 tracked IDs / classification / floating-window state**。全量 Feature Factory Reset 若未来需要，应进入全局设置/维护工具，不放在 Layout Command Bar。

### 5.1.7 Preview 场景

Preview 是设计态投影，不调用高频 Native Metadata，也不为了“看起来真实”反复扫描 Aura。编辑器打开时使用有界样例数据：

- 普通：2 Buff / 1 Debuff；
- 多状态：8+ Buff / 6+ Debuff，验证多行与折叠；
- 长名字 / 俄文名字；
- 施法中；
- 装备槽缺失；
- 自己 / 当前目标 Scope 切换。

Preview Scope 只改变样例/当前事实来源，不改变共享几何 Authority。

### 5.1.8 1024×768 / 1080p / 2K

- **1024×768**：元素树约 170~190；Canvas 优先；Inspector 使用 `ResponsiveInspector` 同实例 Drawer；Tracking 为单 Table，不再并排两表；
- **1080p**：元素树 + Preview + Inline Inspector；Preview 占最大宽度；
- **2K/宽屏**：不无限增宽 Inspector，额外空间优先给 Preview/Table；
- 不通过整体缩小字体解决拥挤；高级设置折叠/抽屉化；
- Native popup / tooltip 继续走 PopupCoordinator / Safe Area，不让 Inspector Drawer 与 Popup 竞争第二 Z Authority。

### 5.1.9 实现前阻断项（`.18.79` 已收口）

UI_REVIEW 期间发现现有代码已有“设计 / Runtime / Acceptance”分叉，**进入 UI_IMPLEMENTING 前必须一次收口**：

1. `rs_v3_buff_head_markers.lua` 当前装备分组为：左 `offHand/mainHand`，右 `wings/ranged`；
2. `rs_buff_display_acceptance.lua` 当前却断言：左 `ranged/offHand/mainHand`，右 `wings`；
3. Store 注释仍写“ranged 默认 OFF”，实际 `COMPONENT_DEFAULTS.ranged.enabled = true`；
4. Page 注释出现“Schema 5”，真实 Store 仍是 schema 4；
5. `headIconSize/headMaxIcons` 与 `components.buffs/debuffs` 形成重复可写入口；
6. 当前 `ResetAllSettings` 会把 tracked/classification 一起清掉，不符合 `.18.77` Layout Reset 语义。

`.18.79` 已按上述清单完成代码收口：装备布局/默认值/字段 Authority/Reset scope 已统一；额外修复 Full Import 32-ID 截断与组件专属字段 round-trip。Store 保持 schema 4，下一步才接 Workspace。

### 5.1.10 UI_APPROVED 产品决策（已确认）

其它 Authority/性能/响应式边界已经可以从真实代码与 Foundation 确定；进入实现前只剩以下产品视觉决策需要显式确认：

1. **确认**：一级页面采用 `追踪管理 / HUD 布局 / 导入导出` 三页签，取消独立“头顶显示”页；
2. **确认**：`自己 / 当前目标` 共用一套 HUD 几何模板，只分别控制显示与 Preview Scope；
3. **确认**：主手+副手在左、背部在右；远程 Fresh Default 关闭，启用后位于左侧外层；
4. **确认**：Layout `Reset` 只恢复 HUD 布局默认，不清 tracked/classification。

`.18.79` 已完成上述决策对应的 Authority Cleanup；`.18.80` 已完成页面 `UI_IMPLEMENTING` 的本地代码接入，下一 Gate 是 RU Fresh Reload，而不是再复制第二套页面实现。

---

## 5.2 状态显示实现映射（UI_APPROVED → UI_IMPLEMENTING）

`.18.80` 的 UI_IMPLEMENTING 已按下面 Authority 映射落地；后续维护不得重新创建页面副本：

| UI 区域 | Authority / Projection | Persistence | 高频规则 |
|---|---|---|---|
| 观察/追踪 Table | `BuffDisplay:GetProjection("all")` / `GetTrackedList()` | tracked/classification 继续 Feature Commands 即时持久化 | Aura facts 来自 `AuraObservationV3`；Table virtual/diff |
| 分类 | `StatusClassificationV3` | override 仍归 BuffDisplay Store | 页面不自行判断 hidden=buff/debuff |
| HUD Preview 数据 | bounded design/sample projection + 当前 detached projection | Session only | 不在 Preview bind 中调用 Native Metadata |
| Element Selection | RSUI `TreeModel/TreeView + SelectionModel` | Session UI state | stable key，不存 row index |
| Transform | `LayoutEditorWorkspace → PreviewAdapter/AnchorPivot/MultiSelection` | Working only | Gesture pulse 不持久化 |
| Undo/Redo | `LayoutEditHistoryModel` | Session only | 只记录成功 Commit |
| Reset/Revert/Apply | `LayoutEditSessionModel` | Apply 唯一写 Permanent Store | 页面不得直接 `MarkDirty` 模拟 Apply |
| Gameplay HUD | `BuffHeadMarkersV3` | 只读 Settings Projection | Demand-scoped、bounded icon pool、Consumer=0 释放 |
| 屏幕坐标 | `ScreenProjectionV3` | Session facts | 左上原点，严禁页面另算坐标系 |

**性能预算**：

- Tracking Table：O(visible/projected rows)，继续 bounded；
- Editor：正常游戏态 0 sampling，只有 Gesture Active 才 16ms InteractiveTask；
- Preview：固定样例集 / detached projection，不扫描完整 Buff Metadata Catalog；
- Gameplay HUD：继续复用现有 icon pool，不为每个 Aura 创建永久 Widget；
- Layout Apply：单次 bounded snapshot normalize + Store write，不进入 Tick；
- Feature 关闭/Consumer=0：Aura Demand、事件、Scheduler、HeadMarkers 必须继续释放。

**兼容原则**：

- 现有 Store schema 4 的 tracked/classification 必须原样保留；
- 若 Layout Session 需要新 schema，只允许新增/规范化布局字段，不得重置追踪 ID；
- 老用户现有 component 值必须迁移为新 Working/Persisted Snapshot；
- 任何默认布局变化只作用于 fresh/default Reset，不能静默覆盖老用户已保存位置；
- `.18.80` 仍不改 schema；兼容旧用户存档。页面构造前先 Load Store；HUD 编辑只在 Apply 时跨 durable persistence boundary。

---

# 6. Unit Lines / 目标关系图

| ID | 来源 | 参考能力 | 我们要吸收的价值 | Replicated Suite 方向 | 优先级 | 状态 |
|---|---|---|---|---|---|---|
| `REF-LINE-001` | `extendedplates` | Player → Target | 基础目标关系 | Unit Relationship Graph | P0 | DISCUSS |
| `REF-LINE-002` | `extendedplates` | Target → TargetTarget | 判断目标正在攻击谁 | Relationship Edge | P0 | DISCUSS |
| `REF-LINE-003` | `extendedplates` | Player → WatchTarget | 焦点目标可视连接 | Relationship Edge | P0 | DISCUSS |
| `REF-LINE-004` | `extendedplates` | WatchTarget → WatchTargetTarget | Boss 焦点目标仇恨关系 | Relationship Edge | P0 | DISCUSS |
| `REF-LINE-005` | `extendedplates` | 四种线独立开关 | 用户自由组合 | Per-edge Enable | P0 | DISCUSS |
| `REF-LINE-006` | `extendedplates` | 点数量 | 调整视觉密度 | 更推荐改为 spacing/density + budget | P0 | DISCUSS |
| `REF-LINE-007` | `extendedplates` | 点大小 | 视觉可调 | Appearance Contract | P0 | DISCUSS |
| `REF-LINE-008` | `extendedplates` | 透明度/颜色 | 区分关系 | RGBA Appearance | P0 | DISCUSS |
| `REF-LINE-009` | `aggroholder` / `extendedplates` | 焦点目标正在攻击谁 | Boss 战高价值信息 | Unit Relationship HUD 小组件 | P0 | DISCUSS |
| `REF-LINE-010` | `extendedplates` | WatchTarget 距离 | 焦点目标独立 HUD | ScreenProjectionV3 + Identity | P0 | DISCUSS |

建议后续将当前“单位连线”从固定四条逻辑提升为：

```text
UnitGraph
  Node: player / target / targettarget / watchtarget / watchtargettarget
  Edge: source → destination
  EdgeStyle: enabled / color / alpha / density / pointSize
```

这样未来加入 Party Target、Boss Target、Healer Recommendation 等关系时不需要再复制一套代码。

---

## 6.1 单位连线页面 UI 蓝图

**页面目标**：让玩家直观看清 Player / Target / WatchTarget 之间的目标关系，而不是面对一堆“连线1/2/3/4”开关。  
**Surface**：Gameplay Overlay + Configuration。  
**UI 状态**：`UI_DRAFT`。

### 正常 Gameplay View

只显示线、端点和可选的小型关系标签；设置 UI 完全隐藏。

### 设置页

```text
┌ 关系列表 ─────────────┬ 关系示意 / Preview ────────────┬ 样式 ─────────────┐
│ ✓ 我 → 当前目标       │ Player ─────→ Target           │ 颜色 RGBA          │
│ ✓ 目标 → 目标的目标   │                  │              │ 粗细 / 点大小      │
│ ✓ 我 → 焦点目标       │                  ↓              │ 密度 / 间距        │
│ ✓ 焦点 → 焦点的目标   │             TargetTarget       │ 更新频率           │
│                       │ WatchTarget ─→ ...              │                    │
└───────────────────────┴────────────────────────────────┴────────────────────┘
```

关系命名必须使用玩家能理解的自然语言；内部 Graph Edge 名称只出现在诊断。

### 焦点仇恨 HUD

可选小组件：

```text
焦点目标：黑龙   27.4m
正在攻击：玩家A
```

它独立于线条开关，因此不想看连线的玩家也能使用。


## 6.2 单位连线页面详细布局规格 v2

#### A. 主页面不是“参数墙”

顶部先展示四种 Relationship Edge 的启用状态：

```text
[✓ 玩家→目标] [✓ 目标→目标的目标] [✓ 玩家→焦点] [✓ 焦点→焦点目标]
```

下面采用 `InspectorWorkbench`：

- 左：Edge List；
- 中：关系预览图；
- 右：选中 Edge 的 Appearance Inspector。

#### B. Edge List

每行：关系 Icon/名称 + Enabled + 当前 Runtime 状态。比如目标不存在时显示 `无目标`，不是 Error。

#### C. Preview

中间用固定模拟节点：Player / Target / TargetTarget / WatchTarget / WatchTargetTarget，选中某条线后只高亮这条 Edge，其他降噪。这样用户能理解“这个开关到底控制哪条线”。

#### D. Inspector

```text
显示
Enabled       [✓]
Only Combat   [ ]

线条
Style         [点线 ▼]
Density       [----|---] [12]
Dot Size      [  3 ]
Thickness     [  2 ]
Opacity       [ 75 ]
Color         [■]

刷新
Projection Hz [ 10 ]
Budget        [Auto]
```

刷新频率不能用“低/中/高”循环按钮，必须 NumericField/Dropdown 明确值；底层仍由 ScreenProjection/FrameBudget 做安全范围归一化。

#### E. Gameplay HUD 设置

焦点仇恨小窗属于 Floating Utility，不塞进线条 Inspector。它独立管理：显示字段、字体、背景、锁定、位置、透明度。

#### F. Compact

Preview 可缩小，但 Inspector 不得压到 220 以下；不足时改 Settings Tab。关系四个快捷开关保持第一屏可见。

#### G. Foundation

`InspectorWorkbench + SegmentedSelector/Toggle + NumericField + ColorField + FloatingSurface + LayoutEditorOverlay(v1 已有，共享 Foundation；页面待接入)`。

---

# 7. Range Assist / World Overlay

| ID | 来源 | 参考能力 | 我们要吸收的价值 | Replicated Suite 方向 | 优先级 | 状态 |
|---|---|---|---|---|---|---|
| `REF-RANGE-001` | `EasyPull` | 多圆同时存在 | 不局限单个范围圈 | Shape Collection | P0 | DISCUSS |
| `REF-RANGE-002` | `EasyPull` | Player Anchor | 围绕自己 | Anchor=`player` | P0 | DISCUSS |
| `REF-RANGE-003` | `EasyPull` | Target Anchor | 围绕目标 | Anchor=`target` | P0 | DISCUSS |
| `REF-RANGE-004` | 综合扩展 | WatchTarget Anchor | Boss/焦点机制 | Anchor=`watchtarget` | P0 | DISCUSS |
| `REF-RANGE-005` | `routetracker` | World Anchor / Freeze | 固定世界坐标机制范围 | Anchor=`world` | P1 | DISCUSS |
| `REF-RANGE-006` | `EasyPull` | 独立半径 | 每个 Shape 自己配置 | CompactNumericSetting | P0 | DISCUSS |
| `REF-RANGE-007` | `EasyPull` | 前后左右 Offset | 不是所有技能都以单位中心 | Local/World Offset | P0 | DISCUSS |
| `REF-RANGE-008` | `EasyPull` | 点密度 | 平衡性能与视觉 | Sample Budget | P0 | DISCUSS |
| `REF-RANGE-009` | `EasyPull` | 每圆颜色 | 不同范围清楚区分 | RGBA ColorField | P0 | DISCUSS |
| `REF-RANGE-010` | `routetracker` | 扇形/锥形 | 技能方向性范围 | Shape=`cone` | P1 | DISCUSS |
| `REF-RANGE-011` | `routetracker` | 直线/方向图形 | 冲锋/炮击/路径判断 | Shape=`line` | P1 | DISCUSS |
| `REF-RANGE-012` | 综合扩展 | 圆环/弧线 | 安全区/危险区更准确 | Shape=`ring/arc` | P1 | DISCUSS |

最终方向候选：将“范围辅助”升级成通用 `WorldOverlay / VisualGuide`，而不是只修一个圆圈。

---

## 7.1 范围辅助页面 UI 蓝图

**页面目标**：创建、预览和管理多个世界空间 Shape，游戏中只留下干净的范围图形。  
**Surface**：Gameplay Overlay + Shape Editor。  
**UI 状态**：`UI_DRAFT`。

### Shape Editor

```text
┌ Shape 列表 ───────────┬ Preview / 示意 ────────────────┬ Inspector ─────────┐
│ ● 治疗 30m 圆         │                                │ 类型：Circle       │
│ ● Boss 正面扇形       │           Player ●             │ Anchor: Player      │
│ ○ 焦点 15m 圆         │          ( 30m )               │ Radius: 30.0       │
│ + 新建 Shape          │                                │ Offset X/Y         │
│                       │                                │ RGBA / Alpha       │
│                       │                                │ Density / Budget   │
└───────────────────────┴────────────────────────────────┴────────────────────┘
```

### 创建流程

`新建 → 选择 Shape 类型 → 选择 Anchor → 数值参数 → 颜色 → 实时 Preview → 保存`。

后续 Circle / Ring / Cone / Line / Arc / World Marker 使用同一编辑器，不为每种形状造独立设置页。

### Gameplay View

- 不显示 Shape 名称，除非用户主动开启；
- 不显示边框手柄；
- 多 Shape 同时开启时需要预算提示，避免过量 Drawable；
- Runtime Blocked 的 Anchor 显示为灰色且解释原因，不静默失效。


## 7.2 范围辅助页面详细布局规格 v2

Range Assist 应像轻量“场景编辑器”，而不是一页半径输入框。

#### A. Shape Editor 工作台

```text
InspectorWorkbench
├─ Shape List  190~230
│  ├─ + Circle / Ring / Cone / Line / Arc
│  ├─ 搜索/分组
│  └─ 每 Shape: Icon + Name + Visible
├─ Preview / World Overlay Canvas  Fill
│  ├─ Anchor mock
│  ├─ Shape preview
│  ├─ Handle / direction
│  └─ distance scale
└─ Inspector  270~310
   ├─ Geometry
   ├─ Anchor
   ├─ Appearance
   ├─ Visibility Conditions
   └─ Performance
```

#### B. Shape List

不要每个 Shape 展开全部属性。列表只放：名称、类型、颜色点、启用、Anchor 摘要。详细属性统一右侧 Inspector。

#### C. Geometry Inspector

按 Shape 类型动态显示：

- Circle：Radius；
- Ring：Inner / Outer Radius；
- Cone：Radius / Angle / Direction；
- Line：Length / Width / Direction；
- Arc：Radius / Angle / Thickness。

所有值使用 NumericField，明确单位 `m / ° / px`。

#### D. Anchor

```text
Anchor Type   [Player ▼]
Target        [当前目标 / 焦点 / World]
Offset X      [0.0 m]
Offset Y      [0.0 m]
Rotation      [0°]
Follow        [✓]
```

World Anchor 时增加“冻结当前位置”动作；这是 Command，不应与普通数值字段混在一行。

#### E. Appearance

颜色必须是 ColorField；Opacity 单独 NumericField/Slider；点密度应显示预算提示，例如 `12 点/圆 · 预计 48 drawables`，用户能理解性能影响。

#### F. Gameplay

正常游戏完全不出现编辑边框、坐标、控制点。只有 Edit Mode 才显示 Handles/Grid。

#### G. Compact

Shape List 保持，Inspector 变独立 Tab；Preview 不能为了保持三栏而缩小到不可操作。

#### H. Foundation

`InspectorWorkbench + ColorField + NumericField + Dropdown + LayoutEditorOverlay(v1 已有，共享 Foundation；页面待接入) + WorldOverlay/Shape Framework(待实现业务 Foundation)`。

---

# 8. Raid / Team / Healer

| ID | 来源 | 参考能力 | 我们要吸收的价值 | Replicated Suite 方向 | 优先级 | 状态 |
|---|---|---|---|---|---|---|
| `REF-RAID-001` | `customraid` | 自定义 100 人团队面板 | 治疗辅助无需完全依赖原生团队 UI | TeamRosterV3 + RSUI RaidGrid | P1 | DISCUSS |
| `REF-RAID-002` | `customraid` | 每成员状态图标 | 治疗/团队准备直观 | Member Overlay Slot | P1 | DISCUSS |
| `REF-RAID-003` | `customraid` | 自定义 Buff ID | 灵活规则 | 改良成状态选择器，而非逗号字符串 | P1 | DISCUSS |
| `REF-RAID-004` | `customraid` | Grid 尺寸/偏移 | 适配 1k/1080p/2k | RSUI Adaptive Grid | P1 | DISCUSS |
| `REF-RAID-005` | `customraid` | 预览/锁定 | 校准时编辑，实战时不误拖 | Healer Calibration Mode | P1 | DISCUSS |
| `REF-RAID-006` | `raidmanager` / `raidchecker` | 团队 Buff 检查 | 开团前快速检查 | Raid Readiness Rule Registry | P1 | DISCUSS |
| `REF-RAID-007` | 两者 | 团队职业组成 | 检查阵容 | Composition Projection | P1 | DISCUSS |
| `REF-RAID-008` | `raidmanager` | 装备状态检查 | 团队准备度 | Readiness Rule | P1 | DISCUSS |
| `REF-RAID-009` | `raidmanager` | 团队成员 Marker | 指挥效率 | Leader capability gate + Command | P1 | DISCUSS |
| `REF-RAID-010` | `raidmanager` | 按职责整理队伍 | 团队组织效率 | Team Tools Command，严格权限门 | P1 | DISCUSS |
| `REF-RAID-011` | `raidmanager` | 黑/白名单 | 人员规则长期维护 | Identity Rules Service 候选 | P1 | DISCUSS |
| `REF-RAID-012` | `raidmanager` | 团队距离检查 | 找掉队成员 | TeamRoster + UnitDistance Projection | P1 | DISCUSS |
| `REF-RAID-013` | `autorole` | 自动职责 | 入团/切职业自动选择职责 | Team Tools，用户已明确希望拥有 | P1 | DISCUSS |
| `REF-RAID-014` | `shinysac` | 特定团队施法高亮 | 指挥快速识别关键技能 | Raid Cast Highlight Rule | P1 | DISCUSS |
| `REF-RAID-015` | `customraid` + 当前 Healer | 团队面板与团队身份解耦 | 解决 1团/2团/单列表/双列表校准问题 | 继续坚持 RaidTeam ≠ RaidPanel ≠ Calibration | P0 | DISCUSS |

---

## 8.1 团队 / 治疗辅助页面 UI 蓝图

这里不强行把所有团队功能塞进一个画面，而是拆成三个任务页。  
**UI 状态**：`UI_DRAFT`。

### A. 治疗辅助

**核心问题**：谁现在最需要治疗？

```text
┌ 团队 1 / 团队 2 / 双团100人 ───────────────────────────────────────────┐
│ [1][2][3][4][5] ... 每格：名字 + 血量 + 必要状态图标                 │
│ [6][7][8][9][10] ...                                                  │
│                                                                       │
├───────────────────────────────────────────────┬───────────────────────┤
│ 当前推荐：1. 玩家A 42%  2. 玩家B 53%          │ 推荐规则摘要          │
│ 距离 / 解控 / 关键 Buff 状态                   │ [校准] [布局编辑]      │
└───────────────────────────────────────────────┴───────────────────────┘
```

- 默认成员格不显示装备分、职业等非治疗决策信息；
- 颜色首先表达治疗优先级/状态，不拿来装饰；
- “双团100人”必须真正表示两个独立 50 人 roster surface，不能假设 UI 当前显示哪一团；
- 校准模式必须允许用户明确指定 Surface A/B 当前对应团队1还是团队2。

### B. 团队准备检查 / Raid Readiness

```text
顶部：成员数 | 缺Buff | 职责异常 | 超距 | 装备异常
左：规则列表                  中：成员矩阵/表格             右：选中成员详情
```

适合 Table + Filter，不适合每个规则做巨大 Card。

### C. 团队管理

- 自动职责、Marker、队伍整理、黑白名单属于这里；
- 所有写操作必须显示权限/Leader Capability；
- 执行前显示计划，执行后显示逐项验证结果。


## 8.2 团队 / 治疗页面详细布局规格 v2

该域至少存在三种不同 Surface，不能强行统一成一个页面：治疗设置、团队准备检查、团队管理。

#### A. 治疗辅助设置页

一级结构：

```text
PageHeader
SummaryStrip: Runtime / Roster / Observation / Overlay
SettingsWorkbench
├─ Navigation
│  ├─ 推荐规则
│  ├─ 颜色与阈值
│  ├─ 团队面板
│  ├─ Buff/Debuff 追踪
│  └─ 高级
└─ Content
   └─ FormSections / Preview
```

不要把所有高级规则一次展开成长页面。

#### B. 100 人 Raid Overlay 编辑

布局编辑时优先显示实际 10×5 小队结构：

```text
团队1                         团队2
1队 [5 slots]                1队 [5 slots]
2队 [5 slots]                2队 [5 slots]
...
10队[5 slots]                10队[5 slots]
```

双面板模式下 A/B 是**屏幕容器**，不是 Team1/Team2 身份本身。UI 文案必须明确“面板 A 绑定团队：自动/1/2”。

#### C. Calibration Mode

校准页面只做几何：选择面板 A/B → 识别矩形 → 调整边界/行列 → 显示槽位序号。不要在校准模式混入治疗优先级设置。

#### D. 治疗 Gameplay Overlay

成员 Slot 默认信息层级：

```text
Name / ShortName
████ Health
关键状态角标 / 小图标
```

不要默认给 100 人同时显示职业、装分、武器、距离文字、多个 Buff 名称。P0/P1 只用颜色、边框、角标表达。

#### E. Raid Readiness

采用 `CommandCenterWorkspace`：

- Status Strip：在线、距离合格、关键 Buff、职责完整；
- Overview：团队 Grid/分组；
- Queue：缺 Buff / 职责异常 / 过远成员；
- Evidence：选中成员的详细缺项。

正常成员降噪，异常成员优先。

#### F. Team Management

采用 MasterDetail：左边团队/小队树，右边成员/职责 Inspector。批量操作必须明确 Selection Count，不允许误把全团命令当单人按钮。

#### G. Compact

- 治疗主设置采用单 SettingsWorkbench；
- Raid Grid 可以水平滚动/缩放预览，但 Gameplay Overlay 本身按真实屏幕几何；
- Readiness 的 Exception Queue 进入下方 Tab。

#### H. Foundation

`SettingsWorkbench + CommandCenterWorkspace + MasterDetailWorkspace + VirtualList + SelectionModel + ColorField + LayoutEditorOverlay(v1 已有，共享 Foundation；页面待接入) + TreeView(v1 已有)`。

---

# 9. Combat Mechanics / Boss Assistance

| ID | 来源 | 参考能力 | 我们要吸收的价值 | Replicated Suite 方向 | 优先级 | 状态 |
|---|---|---|---|---|---|---|
| `REF-MECH-001` | `magiccircle` | 记录技能/状态产生起点 | 判断离技能中心的距离 | Anchor Radius Rule | P1 | DISCUSS |
| `REF-MECH-002` | `magiccircle` | 接近边界预警 | 防止走出有效范围 | Distance Threshold Alert | P1 | DISCUSS |
| `REF-MECH-003` | `wbdebuff` | Boss 特定 Debuff 提醒 | 机制提示 | Combat Mechanic Rule Registry | P1 | DISCUSS |
| `REF-MECH-004` | `wbdebuff` / 类似模块 | Boss 施法倒计时 | 预判机制 | Combat Cast Fact → Mechanic Projection | P1 | DISCUSS |
| `REF-MECH-005` | 参考插件综合 | 机制按 Boss/副本组织 | 避免硬编码散落 | `rs_combat_mechanic_catalog.lua` 继续中心化 | P1 | DISCUSS |

原则：Boss Assistance 不应因为用了 Buff API 就被塞进 Buff Display；Feature 归属按玩家用途，数据来源由共享 Service 提供。

---

## 9.1 Boss / 战斗机制页面 UI 蓝图

**页面目标**：战斗中只让“现在必须处理的机制”抢占注意力；配置时再看到完整规则。  
**Surface**：Gameplay Alert Stack + Rule Manager。  
**UI 状态**：`UI_DRAFT`。

### Gameplay Alert Stack

```text
[高] 黑龙 · 正面喷吐  2.4s
[中] 你身上有 XXX Debuff  7s
[低] 即将离开魔法阵范围  28.6m / 30m
```

- 同时出现多个提示时按危险级排序；
- P0 机制允许短时进入屏幕中心安全区，其余靠外围；
- 重复事件合并，不连续刷屏；
- 声音/闪烁可独立关闭。

### Rule Manager

左侧 Boss/规则树，中间条件与证据，右侧 Alert 表现；高级用户才看到 BuffID / SkillID / CastID。


## 9.2 Boss / 战斗机制页面详细布局规格 v2

#### A. 规则管理页

使用 MasterDetail：

- 左：Boss / 副本 / Rule Group；
- 右：规则列表与选中规则详情。

Rule List 每行只显示：启用、机制名、Trigger 类型、严重度、是否 Runtime Verified。

#### B. 规则 Inspector

```text
基本
Name / Boss / Enabled

触发
Aura / Cast / Unit / Timer
Source ID / Evidence

表现
Alert Level
Text / Icon
Countdown
Sound（若 Runtime 支持）

加载条件
Instance / Boss / Combat only
```

Raw ID 始终标记证据等级，不能让普通用户把猜测 ID 当已验证配置。

#### C. Gameplay Alert Stack

P0 Alert 可以短时接近中心，但规则：

- 同一时刻最多 1 个中心 P0；
- 其它告警进入边缘 Alert Stack；
- 倒计时宽度固定，不因秒数变化跳动；
- 正常/已解除机制快速淡出，不占持久空间。

#### D. Command Center 模式

需要同时监控多机制时使用 `CommandCenterWorkspace`：Overview 为当前机制时间线，Queue 为即将触发/异常，Evidence 为选中机制事实。

#### E. Foundation

`MasterDetailWorkspace + CommandCenterWorkspace + ActionRunner/ViewState + StatusChip(v1 已有) + Rule Registry`。

---

# 10. DPS / Combat Analytics / Death Review

| ID | 来源 | 参考能力 | 我们要吸收的价值 | Replicated Suite 方向 | 优先级 | 状态 |
|---|---|---|---|---|---|---|
| `REF-COMBAT-001` | `dpsmeter` | 战斗自动结束 | Encounter 自动收口 | CombatAnalytics Encounter Lifecycle | P1 | DISCUSS |
| `REF-COMBAT-002` | `dpsmeter` | 排名相对条 | 一眼看出差距 | RSUI RankingBar | P1 | DISCUSS |
| `REF-COMBAT-003` | `dpsmeter` | 伤害占比 | 团队贡献更直观 | Metric Share | P1 | DISCUSS |
| `REF-COMBAT-004` | 综合扩展 | 治疗/承伤等占比 | 所有 Metric 统一 | Generic Metric Share | P1 | DISCUSS |
| `REF-DEATH-001` | `deathlog` | 死亡前大伤害记录 | 快速知道致死链 | Death Review History | P1 | DISCUSS |
| `REF-DEATH-002` | `deathlog` | 死亡时 Debuff 快照 | 判断死亡机制 | Aura History Ring Buffer | P1 | DISCUSS |
| `REF-DEATH-003` | `deathlog` | 点击图标看状态详情 | 提升复盘效率 | Modal/Tooltip 显示来源、时间、施法者、ID | P1 | DISCUSS |

当前 Suite 的 Combat Analytics 已经比旧 `dpsmeter` 更完整，因此主要吸收**信息表达和 Encounter UX**，不复制其统计架构。

---

## 10.1 DPS / Combat Analytics / Death Review UI 蓝图

**Surface**：Main Dashboard + Analysis + Floating Utility。  
**UI 状态**：`UI_DRAFT`。

### DPS 主页面

```text
┌ Encounter 摘要：时长 / 总伤害 / DPS / 击杀 / 治疗 / 承伤 ────────────┐
├ 排名 / Metric ───────────────────────────┬ 选中玩家详情 ─────────────┤
│ # 名字       DPS       占比     Bar      │ 技能 / 目标 / 击杀 / 控制 │
│ 1 玩家A      ...       ...               │ 乐器时间 / Buff uptime    │
│ 2 玩家B      ...       ...               │                          │
├──────────────────────────────────────────┴───────────────────────────┤
│ [玩家] [技能] [目标] [事件证据] [Encounter]                          │
└──────────────────────────────────────────────────────────────────────┘
```

排序列必须真正可点击并给出方向反馈；点击玩家后右侧立即更新，不另开多个重复大窗口。

### Floating DPS

只保留：排名 / 名字 / 当前 Metric / 相对条；详细信息一律回主页面。

### Death Review

```text
死亡时间线
-3.2s  受到 12,430 伤害  技能A  来源B
-1.8s  获得 Debuff C
-0.4s  受到 20,221 伤害  技能D
 0.0s  死亡
```

顶部提供“死亡时 Aura 快照”，点击图标进入证据详情。

### 1024×768

排名表占主屏；玩家详情改为下方 Tab/Drawer，避免三栏挤压。


## 10.2 DPS / Combat Analytics / Death Review 详细布局规格 v2

#### A. DPS 主页面

顶层只保留一个固定 Toolbar：Encounter、Scope、Mode、Clear/Export。设置不直接展开在排行榜上方长期占空间。

主区域使用 MasterDetail：

```text
Master 60~68%                     Detail 32~40%
┌ Ranking/Table ───────────────┬ Player Inspector ─────────────┐
│ Rank Name Value Share Bar    │ Summary                       │
│ ...                          │ [技能] [目标] [时间线]        │
│                              │ Detail Table                  │
└──────────────────────────────┴───────────────────────────────┘
```

排行榜是 P1，玩家详情是 P2，Raw Combat Events 是 P3。

#### B. Ranking Table

固定列宽策略：Rank、Icon 固定；Name fill；Value/DPS/HPS/Share 数值列固定并右对齐。刷新时列宽绝不变化。

自动排序时：用户正在 Hover/Selected/滚动时应有稳定策略，不能每次事件都把行从鼠标下移走。

#### C. Player Inspector

不再横向并排两个窄表。使用二级 Tab：`技能 / 目标 / 控制 / Buff / 事件`。这样 1024 宽度仍可读。

#### D. Combat Analytics

采用 `CommandCenterWorkspace` 更合适：StatusStrip 展示伤害/治疗/承伤/击杀等 KPI；Overview 显示趋势/排名；Queue 显示异常或关键事件；Evidence 下钻原始事实。

#### E. Death Review

使用 MasterDetail：左死亡历史 220~260；右侧为选中死亡的时间轴。时间轴每行固定时间列 + 来源 + 技能 + 数值；Debuff 快照作为时间线顶部/侧栏，不单独塞第三张表。

#### F. Floating DPS

默认只保留 `Rank | Name | Value`；窗口变宽才增加 Share/Bar。标题高度紧凑，字体/背景透明度独立。

#### G. Foundation

`MasterDetailWorkspace + CommandCenterWorkspace + TableView + ViewState + SelectionModel + FloatingSurface + StatusChip(v1 已有)`。

---

# 11. Activities / Tasks / Reminder

| ID | 来源 | 参考能力 | 我们要吸收的价值 | Replicated Suite 方向 | 优先级 | 状态 |
|---|---|---|---|---|---|---|
| `REF-ACT-001` | `RaidSchedules` | 大量活动时间表 | 集中掌握服务器活动 | Activities 数据/Projection | P1 | DISCUSS |
| `REF-ACT-002` | `RaidSchedules` | 区域战争状态 | 纷争/战争/和平直接展示 | Zone State | P1 | DISCUSS |
| `REF-ACT-003` | `RaidSchedules` | 活动任务进度 | 活动与任务上下文结合 | QuestProgressV3 | P1 | DISCUSS |
| `REF-ACT-004` | `RaidSchedules` | 点击活动看详情 | 减少主面板拥挤 | Modal Details | P1 | DISCUSS |
| `REF-ACT-005` | `RaidSchedules` | 自定义显示活动 | 用户只看关心内容 | Visibility Profile | P1 | DISCUSS |
| `REF-ACT-006` | `RaidSchedules` | 活动倒计时悬浮 HUD | 不打开主窗口也能看 | WidgetHost | P1 | DISCUSS |
| `REF-ACT-007` | `RaidSchedules` | 今日收益 | 首页快速汇总 | Resource/Daily Projection | P1 | DISCUSS |
| `REF-ACT-008` | `RaidSchedules` | 装扮/内衣过期提醒 | 防止有效期忘记 | General Reminder Rule | P2 | DISCUSS |
| `REF-TASK-001` | `guildquesttracker` / `RaidSchedules` | 公会任务未接提醒 | 减少遗漏 | Task Notification | P1 | DISCUSS |
| `REF-TASK-002` | `RaidSchedules` | 每日任务提醒 | 集中待办 | Task Notification | P1 | DISCUSS |
| `REF-TASK-003` | `RaidSchedules` | 钓鱼/跑商专项提醒 | 生活任务更清晰 | Life Dashboard | P1 | DISCUSS |
| `REF-TASK-004` | `choretracker` | 自定义任务组 | 玩家自己组织内容 | Task Group Authority | P1 | DISCUSS |
| `REF-TASK-005` | `choretracker` | 分组折叠 | 大量任务更易读 | RSUI Tree/List | P1 | DISCUSS |
| `REF-TASK-006` | `choretracker` | 分组排序 | 用户排序习惯持久化 | Permanent displayOrder | P1 | DISCUSS |
| `REF-TASK-007` | `choretracker` | 从当前任务快速加入 | 不手填 ID | Quest Picker / Context Action | P1 | DISCUSS |
| `REF-TASK-008` | `choretracker` | 高级用户手动任务 ID | 兼容特殊任务 | Advanced Setting | P1 | DISCUSS |
| `REF-TASK-009` | `choretracker` | 独立任务悬浮窗 | 实战/生活时快速查看 | WidgetHost | P1 | DISCUSS |

---

## 11.1 活动 / 日常 / 周常 UI 蓝图

**Surface**：Main Dashboard + Floating Utility + Detail Modal。  
**UI 状态**：`UI_DRAFT`。

### 活动页面

顶部只保留筛选：`全部 / 即将开始 / 进行中 / 已完成` + 大陆/类别。

主区域优先使用高密度两列条目，而不是巨大卡片：

```text
鲸鱼湾        战争 · 18:42    任务 2/3     |  烛台          准备 · 08:10   0/2
征兆          进行中           3/6          |  伊尼斯        和平 · 24:31
```

窗口拉宽时增加可见条目数量；拉窄时自然变单列。

点击任一活动打开详情 Modal：阶段、关联任务、Boss/公会任务、完成状态、奖励/说明。

### 任务页面

```text
[每日] [周常] [自定义组]
▼ 公会任务        4/6
   ✓ 任务A
   ○ 任务B  2/5
▶ 钓鱼            1/3
▶ 跑商            0/2
```

支持从当前任务列表直接“加入追踪”，不要求普通用户手输 Quest ID。

### Floating Window

只显示用户选中的活动/任务；标题区域紧凑，内容数量随窗口高度变化。


## 11.2 活动 / 任务页面详细布局规格 v2

#### A. 活动页面

结构：

```text
Header
FilterToolbar                         32~34
StatusStrip: 进行中 / 30min内 / 今日剩余
ActivityList / ResponsiveGrid          Fill
```

活动条目使用紧凑“横向信息条”，默认高度约 48~56，而不是大卡片。

```text
[状态条] 鲸鱼湾
         战争 · 18:42        任务 2/3        >
```

两列时每个条目字段位置一致；变成单列时只是增加描述，不改变核心字段顺序。

#### B. 活动详情

详情不默认 Modal 阻断。优先 Detail Drawer / 右侧 Inspector；只有确认类操作才用 Modal。当前 Drawer 未完成前，可使用独立 Detail Modal 作为兼容实现，但文档目标仍是非阻断 Detail Surface。

#### C. 任务页面

目标使用 `.18.64` 的 `TreeModel v2 / TreeView v1`：Group → Quest → Subtask。必须用稳定 Key 保存展开态和 Selection，不能以 index 作为身份；大列表继续依靠 TreeModel bounded flatten + ListView virtual pool。

工具栏：Scope、搜索、`从当前任务加入`。手动 ID 放 Advanced。

#### D. Floating Utility

窗口宽度决定显示字段：

- compact：名称 + 倒计时/进度；
- normal：增加阶段；
- wide：增加任务进度。

高度决定可见行数，使用 VirtualList/Scroll，不裁切最后一行。

#### E. Foundation

`Toolbar/SplitToolbar + VirtualList + TreeView(v1 已有) + ViewState + FloatingSurface + ResponsiveGrid`。

---

# 12. Bonds / Resident Board

| ID | 来源 | 参考能力 | 我们要吸收的价值 | Replicated Suite 方向 | 优先级 | 状态 |
|---|---|---|---|---|---|---|
| `REF-BOND-001` | `residentboard` | 多 Board Index 实际读取 | RU 居民板结构证据 | 继续用于 Bonds Authority 验证 | P0 | DISCUSS |
| `REF-BOND-002` | `residentboard` | 空内容与读取失败区分 | 防止把“无任务”误判 API 坏了 | Fail-closed + explicit state | P0 | DISCUSS |
| `REF-BOND-003` | 当前 Suite + 参考行为 | 大陆自动识别 | 自动切正确居民板 | 保持 Runtime evidence 驱动 | P0 | DISCUSS |

`.18.61` 已经参考此类 RU 行为修过一轮，后续重点是实机字段和内容验证，而不是重新复制 `residentboard` UI。

---

## 12.1 债券 / 居民板 UI 蓝图

**页面目标**：快速判断当前大陆/地区今天有哪些可做内容、收益和缺失数据。  
**Surface**：Main Dashboard。  
**UI 状态**：`UI_DRAFT`。

```text
顶部：大陆 [西大陆▼]   当前地区：XXX   今日预计收益：XXXX
┌ 地区 / 居民板 ───────────────────────────────────────────────────────┐
│ 地区        内容          需求/数量       奖励       状态           │
│ ...                                                                │
└────────────────────────────────────────────────────────────────────┘
底部：最后刷新 / 数据来源 / 读取异常
```

- 自动识别大陆后仍允许手动切换；
- 排序设置只在用户点“排序”时打开，不自动弹窗；
- “该地区今天没有内容”和“API 读取失败”必须是两种完全不同的 Empty State；
- 首页摘要可直接复用这里的 Projection。


## 12.2 债券 / 居民板页面详细布局规格 v2

#### A. 顶部 Context Bar

```text
大陆 [西大陆 ▼]   当前地区：XXX   最后刷新 14:32
今日可获得：XX 债券                     [刷新] [排序]
```

上下文信息和操作在同一 Toolbar，不另外套大 Card。

#### B. 主表

使用 TableView：

`地区 | 居民板/任务 | 需求 | 奖励 | 状态 | 更新时间`

地区列左对齐，数量/奖励右对齐，状态固定宽。未知/失败不显示 0。

#### C. Detail

选中一行后打开右侧/下方 Detail：任务来源、所需物品、完整名称、证据状态。首页摘要和该页面必须消费同一个 Projection。

#### D. Empty State

至少三个视觉不同的状态：

- 今日无内容：正常 Empty；
- 尚未刷新：Neutral；
- API/Board 读取失败：Warning/Error + 原因 + 重试。

不能全部显示“暂无数据”。

#### E. Foundation

`MasterDetailWorkspace + TableView + ViewState + Toolbar + StatusChip(v1 已有)`。

---

# 13. Trade / Craft / Economy

| ID | 来源 | 参考能力 | 我们要吸收的价值 | Replicated Suite 方向 | 优先级 | 状态 |
|---|---|---|---|---|---|---|
| `REF-ECON-001` | `omnicraft` | 配方→材料→数量 | 制作规划基础 | Craft Planner | P2 | DISCUSS |
| `REF-ECON-002` | `omnicraft` | 多件材料汇总 | 批量制作总需求 | Aggregated Material Projection | P2 | DISCUSS |
| `REF-ECON-003` | `omnicraft` | 背包已有材料对比 | 直接看到还缺多少 | ResourceService + Craft Projection | P2 | DISCUSS |
| `REF-ECON-004` | `omnicraft` | 拍卖价格辅助成本 | 买/做决策 | 只能经过 AuctionQueryV3 + PriceQuoteQueueV3 | P2 | DISCUSS |
| `REF-ECON-005` | `packratio` | 起点/终点货率 | 跑商核心信息 | Trade Route Projection | P2 | DISCUSS |
| `REF-ECON-006` | `packratio` | 图标化货率结果 | 信息密度高 | Trade Tile/List | P2 | DISCUSS |
| `REF-ECON-007` | `packratio` | 货率→预计金币 | 更接近实际决策 | Verified Product/BasePrice + ratio | P2 | DISCUSS |
| `REF-ECON-008` | `packratio` | 大陆/地区快捷选择 | 快速选择路线 | Searchable Dropdown | P2 | DISCUSS |
| `REF-ECON-009` | 综合改良 | 显式未知报价 | 没询价不能伪造最低价 | 保持 PriceQuoteQueueV3 read-model 原则 | P1 | DISCUSS |

原则：参考 Addon 的经济功能可以吸收 UX，但不能绕过当前 Auction 限速/事件所有权/报价队列治理。

---

## 13.1 跑商 / 制作 / 经济 UI 蓝图

这一类数据量大，核心必须是搜索、筛选、比较，不能全做成卡片。  
**Surface**：Main Dashboard + Inspector。  
**UI 状态**：`UI_DRAFT`。

### 跑商货率

```text
起点大陆 [▼]  起点地区 [搜索▼]  →  终点地区 [搜索▼]   [刷新]
┌ 货物结果 ────────────────────────────────────────┬ 选中货物详情 ───────┐
│ 图标  货物名      货率   基础价   预计收益       │ 材料 / CraftID      │
│ ...                                              │ 拍卖报价            │
│                                                  │ 成本 / 利润          │
└──────────────────────────────────────────────────┴─────────────────────┘
```

地区数据量大时必须使用可搜索 Dropdown，不做几十项长滚动菜单。

### Craft Planner

左：配方搜索/收藏；中：材料需求表；右：库存/拍卖/买或做比较。数量直接输入。

### 1024×768

Inspector 变成下方详情 Tab；结果表保持主要空间。


## 13.2 跑商 / 制作 / 经济页面详细布局规格 v2

#### A. Trade Route

顶部 FilterToolbar 分两层，避免所有 Dropdown 挤成一行：

```text
起点：大陆 [▼]  地区 [搜索选择器]
终点：大陆 [▼]  地区 [搜索选择器]      [查询]
```

主区域采用 MasterDetail，结果表占 65~72%，右 Inspector 28~35%。

#### B. 结果表

列：`Icon | 货物 | 货率 | 基础价 | 预计收益 | 报价状态`。成本/利润需要拍卖数据时，不要直接多加五六列；放 Inspector，否则主表失去扫描效率。

#### C. Price Quote 状态

报价是异步/受限能力，UI 必须明确：`未询价 / 排队 / 查询中 / 已报价 / 过期 / 失败`。未询价不得显示 0 金。

#### D. Craft Planner

三栏 Workbench：

```text
Recipe/Search  220~260 | Material Plan Fill | Cost Inspector 280~320
```

材料表是主工作区。库存/拍卖只改变数值字段，不重建整行。

#### E. Searchable Picker

地区、配方、物品量大，普通 Dropdown 已不足。`SearchablePicker` 是该域进入 `UI_APPROVED` 前的重要 Foundation blocker。

#### F. Compact

Trade：结果表主导，Inspector 下移为 Tab；Craft：Recipe Rail 可收窄，Cost Inspector 下移。

#### G. Foundation

`MasterDetailWorkspace / InspectorWorkbench + TableView + SearchablePicker v1 + PriceQuote ViewState + NumericField`。

---

# 14. Treasure / Fishing / Route

| ID | 来源 | 参考能力 | 我们要吸收的价值 | Replicated Suite 方向 | 优先级 | 状态 |
|---|---|---|---|---|---|---|
| `REF-TREASURE-001` | `TreasureMapHunter` | 自动识别背包藏宝图 | 不需用户手动录入 | TreasureService + bounded bag snapshot | P2 | DISCUSS |
| `REF-TREASURE-002` | `TreasureMapHunter` | 按距离排序 | 最近目标优先 | Distance sort | P2 | DISCUSS |
| `REF-TREASURE-003` | `TreasureMapHunter` | 指南针 | 方向直观 | Treasure HUD | P2 | DISCUSS |
| `REF-TREASURE-004` | `TreasureMapHunter` | 距离显示 | 判断接近程度 | Screen/World distance | P2 | DISCUSS |
| `REF-TREASURE-005` | `TreasureMapHunter` | 距离颜色渐变 | 越近越明显 | Generic Distance Visual Rule | P2 | DISCUSS |
| `REF-TREASURE-006` | `TreasureMapHunter` | 接近目标动画/闪烁 | 到点不容易错过 | Proximity Indicator | P2 | DISCUSS |
| `REF-TREASURE-007` | `TreasureMapHunter` | 世界地图定位 | 一键打开准确位置 | Verified ShowWorldmapLocation path | P2 | DISCUSS |
| `REF-TREASURE-008` | `TreasureMapHunter` | 坐标→区域匹配 | 自动归类藏宝图 | Structured Treasure Location DB | P2 | DISCUSS |
| `REF-FISH-001` | `SmartFisherman` | 根据鱼状态识别推荐技能 | 减少观察负担 | Fishing State Machine | P2 | DISCUSS |
| `REF-FISH-002` | `SmartFisherman` | 推荐技能提示 | 比自动乱按更安全 | 推荐优先，自动化需单独 capability gate | P2 | DISCUSS |
| `REF-FISH-003` | `SmartFisherman` | 区域不同技能映射 | 适配不同钓鱼环境 | Fishing Profile | P2 | DISCUSS |
| `REF-ROUTE-001` | `routehistorytracker` | 玩家历史轨迹 | 跑商/寻宝路线回顾 | Optional Route History | P2 | DISCUSS |
| `REF-ROUTE-002` | `routehistorytracker` | 地图校准 | 自绘地图的坐标映射 | 仅在自定义地图需要时采用 | P2 | DISCUSS |

---

## 14.1 寻宝 / 钓鱼 / 路线 UI 蓝图

这三个功能同属生活类，但交互不同，**不使用同一套页面强行套模板**。  
**UI 状态**：`UI_DRAFT`。

### Treasure

主页面：藏宝图列表按距离排序 + 区域 + 距离 + 世界地图定位。

Gameplay HUD：

```text
              ↑ 23°
藏宝点：XXX   126m
```

接近目标后才增加颜色/轻动画，不常驻闪烁。

### Fishing

主页面显示：当前钓鱼目标、检测到的鱼状态、推荐技能、区域 Profile。

Gameplay HUD 只显示一个明确推荐：

```text
目标状态：挣扎
推荐技能：[图标] 收线
```

优先做“推荐”，不把自动改 Hotkey 作为默认交互。

### Route

主页面管理路线/轨迹记录；Gameplay 只保留方向、下一节点、距离或必要的世界投影。


## 14.2 寻宝 / 钓鱼 / 路线详细布局规格 v2

#### A. Treasure

主页面 MasterDetail：左藏宝图列表，右详情/地图定位信息。列表默认按距离排序但用户交互期间避免跳行。

HUD 只显示：方向、距离、目标名三层；接近阈值后颜色变化，不持续闪烁。

#### B. Fishing

页面不是数据大屏，而是状态机 Inspector：顶部当前目标卡；中间“当前状态 → 推荐技能”；下方 Profile/规则。Gameplay HUD 只保留一个推荐动作。

#### C. Route

路线管理适合 MasterDetail：左路线列表，右节点/记录。未来如果自绘地图成为主工作区，再升级为 Map + LayerTree + Inspector，不提前造地图框架。

#### D. Foundation

`MasterDetailWorkspace + VirtualList + FloatingSurface + DistanceVisualRule + SearchablePicker(可选)`。

---

# 15. Title / Profile / Convenience

| ID | 来源 | 参考能力 | 我们要吸收的价值 | Replicated Suite 方向 | 优先级 | 状态 |
|---|---|---|---|---|---|---|
| `REF-TITLE-001` | `titleswap` | 保存标题快捷方案 | 快速切换 | 独立 Title Profile 或 Gear Profile 子域 | P1 | DISCUSS |
| `REF-TITLE-002` | `titleswap` | 名称/昵称/顺序/图标 | 更好管理大量标题 | Profile UX | P1 | DISCUSS |
| `REF-TITLE-003` | `titleswap` | 写入后延迟验证 | 高价值可靠性模式 | 通用 Command Verification | P0 | DISCUSS |
| `REF-PORTAL-001` | `personalportals` | Personal Portal 快速设置 | 便利 | 当前仍需 Option contract 证据 | P3 | RUNTIME_BLOCKED |
| `REF-SCALE-001` | `scalinglock` | UI Scale 保持 | 避免登录后失效 | 只在 RU 证明需要时做安全检测/恢复 | P3 | DISCUSS |

---

## 15.1 标题 / Profile / 便利功能 UI 蓝图

这些功能不是高频核心页面，应保持轻量。  
**UI 状态**：`UI_DRAFT`。

- Title/Profile 采用搜索列表 + 当前选择 + 收藏/排序；
- 切换操作复用 Command Pending/Verify 状态；
- Personal Portal、UI Scale 等便利功能归入 Tools，不独立占主导航一级入口；
- 开发/实验功能必须有“开发者”标识，避免普通玩家误操作。


## 15.2 Title / Profile / Convenience 详细布局规格 v2

标题/Profile 使用 MasterDetail：左搜索/收藏列表，右当前 Profile 信息和验证状态。切换是 Command Transaction，按钮旁显示 Pending/Verified，而不是 Toast 一闪而过后用户不知道当前到底是什么。

便利功能都放 Tools 的 Section 中，不为每个小功能建立独立大页面。

Foundation：`MasterDetailWorkspace + ActionRunner + StatusChip(v1 已有) + IconPicker(v1 已有)`。

---

# 16. Diagnostics / Development Tools

| ID | 来源 | 参考能力 | 我们要吸收的价值 | Replicated Suite 方向 | 优先级 | 状态 |
|---|---|---|---|---|---|---|
| `REF-DEV-001` | `statspy` | UnitInfo / Modifier 字段浏览 | 非常适合研究 RU Native 字段 | Diagnostics Unit Inspector | P2 | DISCUSS |
| `REF-DEV-002` | `statspy` | 关注属性列表 | 保存常用观察字段 | Dev-only Inspector Profile | P2 | DISCUSS |
| `REF-DEV-003` | `luaerrorprinter` | 游戏内 Lua 错误显示 | 不用每次翻日志 | Diagnostics Error Summary | P2 | DISCUSS |
| `REF-DEV-004` | `uirefresh` | 快速 UI Refresh | 开发方便 | Dev Tool，不进入普通用户核心 | P3 | DISCUSS |
| `REF-DEV-005` | `reloadcfg` | 场景变化后恢复配置 | 可研究某些 RU 配置丢失问题 | 仅有真实复现后再实现 | P3 | DISCUSS |

Diagnostics 工具必须与普通用户功能隔离，不能为了调试让 Runtime 热路径永久增加成本。

---

## 16.1 诊断页面 UI 蓝图

**页面目标**：普通玩家一眼知道“正常/哪里坏了”，开发时又能继续下钻到证据。  
**Surface**：Main Dashboard + Analysis。  
**UI 状态**：`UI_DRAFT`。

```text
顶部：Foundation 正常 · Blocker 0 · Warning 2 · Runtime 125/125
┌ 问题列表 ───────────────────────────────────────┬ 证据详情 ────────────┐
│ 严重度  模块       问题                         │ Rule / Source        │
│ ⚠      Trade      PriceQuote ...               │ Raw Evidence         │
│ ...                                             │ 调用链 / 建议        │
└─────────────────────────────────────────────────┴──────────────────────┘
[复制摘要] [复制完整诊断] [重新运行]
```

游戏 Log 的诊断仍应支持一条可完整复制的合并摘要，页面只是更易读的 Presentation。


## 16.2 Diagnostics 页面详细布局规格 v2

#### A. 普通用户模式

第一屏只回答三个问题：

1. Suite 是否正常；
2. 哪些功能不可用；
3. 用户现在能做什么。

顶部 Status Strip：Foundation / Runtime / Persistence / Native Capability。

主区域 MasterDetail：左 Issue List，右 Evidence Inspector。

#### B. Issue List

固定列：`Severity | Module | Summary | State`。不要在列表行塞调用链和 Raw JSON。

#### C. Evidence Inspector

二级 Tab：`摘要 / 证据 / 调用链 / 性能 / 原始`。普通用户默认摘要，开发者才进入 Raw。

#### D. 复制

`复制摘要` 必须始终生成单段可复制文本；`复制完整诊断` 才输出展开证据。游戏 Log 仍保留一条合并摘要。

#### E. Developer Inspector

Unit/StatSpy 类工具使用 InspectorWorkbench：左观察对象，中间属性表，右选中字段解释/来源。必须 Demand 开启，关闭页面后不保持高频扫描。

#### F. Foundation

`MasterDetailWorkspace + InspectorWorkbench + TableView + ViewState + StatusChip(v1 已有)`。

---

# 17. 低优先级 / 特殊功能

| ID | 来源 | 参考能力 | 处理建议 | 优先级 | 状态 |
|---|---|---|---|---|---|
| `REF-MISC-001` | `dressup` | Item ID 外观预览 | 有趣但非当前核心 | P3 | DISCUSS |
| `REF-MISC-002` | `lootr` | Loot 掉率查询 | 只有可靠数据库后才考虑 | P3 | DISCUSS |
| `REF-MISC-003` | `translate` | 自动翻译 | 外部 PowerShell/文件/API 方案不适合直接进入 Suite Runtime | P3 | DISCUSS |

---

# 18. 明确不应照搬的实现方式

以下不是“功能拒绝”，而是**实现方式明确禁止照搬**。

| ID | 旧式做法 | 为什么不能照搬 | Suite 正确方向 |
|---|---|---|---|
| `REF-ANTI-001` | 每帧扫描全部 Buff | 玩家/单位多时成本失控 | AuraObservation Demand / Event / bounded fallback |
| `REF-ANTI-002` | 固定扫描背包 1..150 | 容量不一定固定且浪费 Native 调用 | `Capacity()` + bounded snapshot |
| `REF-ANTI-003` | 每插件复制窗口/UI 框架 | 样式/拖动/缩放/持久化会不断分叉 | 统一 RSUI / WindowShell / FloatingSurface |
| `REF-ANTI-004` | 各插件直接写 TXT/Lua 配置 | 无生命周期、迁移、写入治理 | Persistence Store + Lifetime + Migration |
| `REF-ANTI-005` | Feature 直接调用任意 X2 写 API | 权限、参数、冷却、回滚都不可控 | API Capability + Service/Command Boundary |
| `REF-ANTI-006` | 每模块自己 OnUpdate 高频轮询 | 产生重复扫描和 Cache/Native 调用浪费 | Demand + Scheduler + RefreshCoordinator + Event |
| `REF-ANTI-007` | UI 页面自己扫描/判断业务 | Presentation 变成第二 Authority | Service/Domain → Projection → RSUI |
| `REF-ANTI-008` | 根据字段名或旧版本猜 API | RU 版本可能不同 | Evidence + fail-closed + RU test |
| `REF-ANTI-009` | `globals/` 作为公共框架重新接回 | 当前架构已明确物理删除 | 只允许历史参考，公共能力必须重做进 Core/Service/RSUI |
| `REF-ANTI-010` | 隐藏窗口就停止/启动业务 | Presentation 与 Feature 生命周期耦合 | Enabled / Visible / Collapsed 严格分离 |
| `REF-ANTI-011` | 控件失败后偷偷换成另一种交互（例如 Dropdown → 循环按钮） | 用户无法预测点击结果，错误路径反而可能改数据 | fail-closed + 明确 unavailable/error state + 保留只读值 |

---


## 18.1 UI Foundation 实施状态（先于页面定稿）

当前 UI 讨论不会直接把 `UI_DRAFT` 页面全部写进 Runtime。先按下表补底层：

| Foundation | 当前 | 目标 | 页面阻塞关系 |
|---|---|---|---|
| MasterDetailWorkspace | **`.18.62` 已加入 v1** | 稳定左右主从布局 | Gear/DPS/Bonds/Diagnostics |
| InspectorWorkbench | **`.18.62` 已加入 v1** | 三栏编辑器骨架 | Buff/Range/UnitLines |
| SettingsWorkbench | **`.18.62` 已加入 v1** | 大型设置分类/内容骨架 | Healer/Status/全局设置 |
| CommandCenterWorkspace | **`.18.62` 已加入 v1** | 态势/异常/证据骨架 | Raid/Boss/Analytics |
| Breakpoint/Density Policy | **`.18.62` 已加入** | 页面统一宽度/密度决策 | 全部页面 |
| PopupCoordinator + Popup Z Token | **`.18.63` 已加入 v1** | Dropdown/Color/Context single registry + mutual exclusion + tokenized priority | 所有 picker/popover |
| TreeModel / TreeView | **`.18.64`：TreeModel v2 / TreeView v1** | Mandatory stable-key + transactional mutation + tri-state expansion + bounded long-lived state + virtualized row pool | Buff/Tasks/Team |
| OutlineView 高级编辑能力 | 暂缓 | 仅在 inline rename / drag reorder 等真实需求出现后扩展 TreeView | Buff/Rules |
| PickerModel | **`.18.64` 已加入 v1** | Stable-key + transactional query/items + bounded filter + stable selection | SearchablePicker/IconPicker/Trade/Buff/Skill/Items |
| SearchablePicker | **`.18.65` 已加入 v1** | PickerModel 单 Authority + TextInput/Search/Clear/StatusChip + virtual ListView；首版显式提交 query | Trade/Buff/Skill/Items |
| IconPicker | **`.18.65` 已加入 v1** | PickerModel + virtual TileView + Image + selected preview；业务只投影 icon path | Gear/Buff/CD/Profile |
| Focus Contract / Input Fence | **`.18.64`：Focus v2 + Audit fence；`.18.65` Picker 遵守该契约** | Target-aware focus；未验证通用键盘/TextChanged 不进入 Active Runtime | Picker/Editor/所有输入控件 |
| ResponsiveInspector/Drawer | **`.18.65` ResponsiveInspector v1 / Workspace v2** | Stable Host：wide inline / compact drawer；不重建、不复制、不 reparent | 多数 MasterDetail/Editor 页 |
| StatusChip | **`.18.63` 已加入 v1** | 统一状态语义视觉，不让 Feature 自造颜色协议 | 全部实时/命令页面 |
| LayoutEditorOverlay | v1 已实现（Foundation） | Handle/Anchor/Grid/Guide/Gesture/Single-Multi Adapter | Buff/Healer/Range |

原则：**组件缺失不是让页面临时手写一套的理由。** 如果某页面需要的新能力能被至少两个 Feature 复用，就优先进入 RSUI Foundation 设计。

### 18.1.1 `.18.63` Foundation 审计结论

本轮没有实现新的业务功能，目标是继续减少底层分叉并补足下一阶段页面设计真正会重复使用的能力。

- **已退休第二组件体系**：旧 `UI.ComponentsV2` 只剩 RSUI 自身 Card/Section/FormSection 间接 Consumer，迁移到 `ContainerSurface` 后已从 Active TOC / 物理工程删除。以后不得因为“旧代码方便”重新依赖 `Create*V2`。
- **Dropdown 降级交互收口**：Popup 不可用时必须 fail-closed。一个 Dropdown 不能在失败时悄悄变成 Choice Cycle Button；这会改变用户心智模型并制造误操作。
- **Tree 先拆 Model / View**：层级 projection 可以无 UI 单测；Native 行只由虚拟 ListView 为可见区域创建/复用。宽树再使用 frame-cursor DFS，避免“输出 64 行却先压 20,000 children”的伪有界实现。这样状态显示几十项、任务上百项、规则树增长时不需要推翻实现。
- **Status 语义先统一**：Pending/Success/Warning/Blocked 等以后由 `StatusChip` 统一表达；Feature 只提供 semantic status，不应该各自硬编码红黄绿。
- **不为了“框架强大”无限造组件**：新 Composite 仍需至少两个真实页面 Consumer，或一个明确的跨 Feature 编辑器模式；否则保留在 Feature 内部草案，避免过度抽象。

下一轮底层优先审计顺序：

```text
Input / Focus / Popup lifecycle（`.18.63` 已完成 Popup single-registry 第一轮；Keyboard/TextChanged 继续 evidence-gated）
        ↓
SearchablePicker + IconPicker 的共享选择模型
        ↓
ResponsiveInspector / Drawer
        ↓
LayoutEditorOverlay（Selection / Handle / Snap / Guide）
        ↓
再开始 UI_APPROVED 页面接入
```

其中 `LayoutEditorOverlay` 必须建立在统一 Pointer Capture、Window/Popup Z-Layer 与 Geometry Authority 都确认稳定之后，不能为了早做可视化编辑器复制第二套 Drag/Resize Runtime。

### 18.1.2 `.18.64` UI Model Integrity Foundation

这一轮仍然**零业务 Feature 接入**，先把 Tree / Picker / Focus 这三类未来复杂编辑器必然共享的状态模型做成可证明的底层契约。

#### A. TreeModel v2：稳定身份成为硬要求

禁止 path/index fallback。合法 identity 只允许：

```text
node.key
或 node.id
或 caller getKey(node)
```

原因是视觉 path 不是数据身份：在父节点插入、排序、过滤后，`1/3/2` 这类路径会变化。如果 expanded/selected 用路径保存，用户看到的是“我没动它，状态自己跳了”。因此 missing key、duplicate key、getKey/getChildren 异常全部 fail-closed。

#### B. Tree Mutation 必须事务化

```text
旧稳定状态
    ↓
构造 Candidate Mutation
    ↓
Bounded Rebuild + Validate
  ↙                    ↘
PASS                    FAIL
 ↓                       ↓
Commit                 Rollback
```

`SetNodes / SetExpanded / ToggleExpanded / ExpandAll / CollapseAll` 都遵守该流程。尤其要覆盖“duplicate key 藏在当前折叠子树里，用户展开后才暴露”的延迟错误：返回失败时 revision、rows、expanded override 仍保持操作前状态。

#### C. defaultExpandedDepth 不再覆盖用户意图

展开覆盖是三态：

- `true`：用户/调用方显式展开；
- `false`：显式折叠；
- `nil`：没有 override，才使用 `defaultExpandedDepth`。

另外 `maxExpansionState` 默认 `maxNodes*2`，hard cap `32768`。动态数据集持续换 key 时，旧 expansion override 会有界清理，不允许长期 session 无限增长。

#### D. PickerModel v1 先于 SearchablePicker 视觉实现

PickerModel 是**纯数据选择 Authority**，不创建 Native Widget：

```text
Items
  ↓ stable key / search text
PickerModel
  ├ query tokens
  ├ bounded scan
  ├ bounded results
  ├ selectedKey
  └ truncation/error snapshot
        ↓
SearchablePicker / IconPicker / RoutePicker / SkillPicker
```

当前默认/硬上限：

| 项 | 默认 | Hard Cap |
|---|---:|---:|
| maxScan | 8192 | 32768 |
| maxResults | 128 | 512 |
| maxTokens | 8 | 16 |
| maxQueryBytes | 256 | 1024 |

`SetItems / SetQuery` 同样 transaction commit；missing/duplicate key fail-closed。过滤采用 AND-token plain substring，业务如需中文/RU 名称归一化，通过 `getSearchText` 在 Model 输入侧明确提供，不在 UI 控件里偷做业务判断。

#### E. Focus Contract v2 与 Input Evidence Fence

Focus 能力必须针对具体 target：

```text
CanSet(target)
CanClear(target)
GetTargetWidgetId(target)
IsFocused(target)
```

不能再用“框架有 FocusService，所以所有控件都 setFocus=true”这种全局能力假设。当前 RU 仍没有通用 `OnKeyDown / OnKeyUp / OnTextChanged` 的 verified contract，因此 Foundation Audit 已把这三个 Active Runtime 绑定设为静态违规。

这会直接约束后续 Picker：第一版搜索必须使用已验证 Enter/EditEnter/LostFocus 或显式按钮提交，不能为了看起来像桌面软件就猜事件。

#### F. 下一步底层顺序

```text
PickerModel v1                      ✅
TreeModel v2 / TreeView v1         ✅
Focus Contract v2                  ✅
Input Evidence Fence               ✅
        ↓
SearchablePicker Presentation
        ↓
IconPicker = PickerModel + TileView
        ↓
Responsive Inspector / Drawer
        ↓
LayoutEditorOverlay
```

ResponsiveInspector 不能先假设“把同一个 Inspector 从右栏移到 Drawer”是安全的。下一轮应先审计 RSUI 现有 Slot/Host 对 RemoveChild / Reparent / Ownership 的实际 Contract；如果不足，先补共享 Host 机制。

### 18.1.3 `.18.65` Host / Slot / Responsive Picker Foundation

本轮仍不进入 Feature，实现目标是让后续页面可以像 UMG 一样“组合复杂布局”，但不把 UE 的 Reparent 假设硬套到 RU Native UI 上。

#### A. Host / Slot Ownership：单父节点是硬边界

Native Widget 在创建时就绑定物理 Parent，而项目目前没有已验证的通用 Native Reparent。所以底层明确：

```text
Logical Parent Authority
        +
Native Creation Parent
        ↓
必须始终一致
```

每次 Attach 验证 parent/child live、cycle、existing parent、Native content root。跨 Parent 不做“尽力而为”，而是立即返回 `reparent_not_supported`。`RemoveChild` 只用于终止拥有关系并释放子树，不作为可重挂载 API。

这会直接影响所有页面 UI 设计：**响应式重排必须优先通过同一 Host 内 Layout/Switch/Visibility 完成，而不是把现有组件搬家。**

#### B. ResponsiveInspector：页面详细几何模板

这是状态显示、范围辅助、单位连线、Diagnostics 等“主画布 + 属性面板”页面的共享结构。

**Wide（建议 ≥ regular breakpoint 且实际空间足够）**

```text
┌────────────────────────────────────────────────────────────────────────────┐
│ Page Toolbar / Context                                                     │ 36~44
├──────────────────────────────────────────────────────┬─────────────────────┤
│                                                      │ Inspector           │
│ Content / Preview / Table                            │ default ≈ 286       │
│ min ≈ 360                                            │ min ≈ 220           │
│                                                      │                     │
│                                                      │ Section             │
│                                                      │ Field               │
│                                                      │ Field               │
│                                                      │ Advanced ▾          │
└──────────────────────────────────────────────────────┴─────────────────────┘
                          gap = workspace token
```

**Compact / 1024×768 小窗口**

```text
┌──────────────────────────────────────────────────────────────────────┐
│ Page Toolbar                                      [属性]              │
├──────────────────────────────────────────────────────────────────────┤
│ Content / Preview                                                     │
│                                                                       │
│                                ┌─────────────────────────────────────┐│
│                                │ Inspector Drawer                    ││
│                                │ 仍是同一实例                         ││
│                                │ Section / Field / Scroll            ││
│                                └─────────────────────────────────────┘│
└──────────────────────────────────────────────────────────────────────┘
```

要求：

- Content / Inspector 构建一次；
- Inspector 的 Binding/Selection/Scroll Draft 不复制；
- inline → drawer 时只改 bounds/visibility；
- Drawer 最多占 `drawerMaxFraction≈0.92`，保留 `drawerMinReveal` 让玩家仍知道背后是主工作区；
- Inspector width 由统一 token/数值设置控制，页面不得自己写散乱宽度；
- 如果某页需要真正 Modal Drawer/Scrim，再判断是否至少两个页面复用后下沉新的 Overlay Surface。

#### C. SearchablePicker：详细控件排列

适合 Buff/Skill/Item/地区/路线等几十到几千候选项。第一版不是“输入每个字符立刻重筛”，而是 RU-evidence-safe 的显式提交。

```text
┌──────────────────────────────────────────────────────────────┐
│ [ 搜索关键词................................ ] [搜索] [清空] │ 30~34
├──────────────────────────────────────────────────────────────┤
│  23 项 / 128+ 项 / 查询失败                                 │ StatusChip
├──────────────────────────────────────────────────────────────┤
│ 结果名称                                      可选辅助信息   │ 26~30/row
│ ──────────────────────────────────────────────────────────── │
│ Healing Light                                                │
│ Fireball                                                     │
│ Ice Lance                                                    │
│ ... virtual ListView ...                                     │
└──────────────────────────────────────────────────────────────┘
```

交互：

1. TextInput 只保存 Draft；
2. Enter/EditEnter 或“搜索”提交；
3. PickerModel transactional SetQuery；
4. 失败时保留旧可用结果并 StatusChip=error，不清空成假“0 项”；
5. 结果按 stable key 选择；
6. 清空按钮显式 query=""；
7. Focus 只在具体 Native target 支持 SetFocus 时请求；
8. 不绑定 `OnTextChanged / OnKeyDown / OnKeyUp`。

#### D. IconPicker：图标网格布局模板

图标选择属于至少 Gear / Buff Display / Cooldown / Profile 共用的高价值模式，因此直接下沉 Foundation。

```text
┌──────────────────────────────────────────────────────────────┐
│ [ 搜索图标................................ ] [搜索] [清空]  │ 30~34
├──────────────────────────────────────────────────────────────┤
│ 64 项 / 256+ 项                                             │ StatusChip
├──────────────────────────────────────────────────────────────┤
│ [ 44px ] [ 44px ] [ 44px ] [ 44px ] [ 44px ]              │
│  图标名    图标名    图标名    图标名    图标名             │ 68×76/tile 默认
│                                                              │
│ ... TileView viewport pool + overscan ...                    │
├──────────────────────────────────────────────────────────────┤
│ [32px Selected]  当前选择名称                                │ 42
└──────────────────────────────────────────────────────────────┘
```

底层约束：

- `PickerModel` 仍是 query/results/selectedKey Authority；
- `TileView` 负责 viewport pool，禁止全量 Native Tile；
- `Image` 只消费已解析 icon path；
- `getIcon()` 只能从 Projection 取路径，不允许在 bindTile 中调 X2/Metadata Service；
- `showLabels=false` 可切纯图标密度；
- 首版搜索仍是 Enter/按钮显式提交；
- 选中预览与 tile selection 复用同一个 selectedKey；
- 分类/最近使用尚未加入 v1，等 Gear/Buff 页面真实需要时设计独立 Projection，不先膨胀 Foundation。

#### E. 页面层禁止出现的新反模式

从 `.18.65` 开始，下列做法在后续页面设计中直接判为需要返工：

- 为 wide/compact 各建一份 Inspector；
- Feature 自己维护搜索结果 + PickerModel 又维护一份；
- 通过 Lua 改 `parentComponent` 模拟 Reparent；
- RemoveChild 后把同一个 Native Widget 加到另一个 Container；
- 搜索框为了“更像桌面软件”猜 `OnTextChanged`；
- 长列表搜索结果使用普通 VerticalBox 全量创建 row；
- 不稳定 index 当 picker/tree identity。

#### F. 下一阶段基础组件优先级

```text
IconPicker v1                                           ✅
  = PickerModel + TileView + Preview + bounded asset rows
        ↓
Overlay/Drawer Scrim（只有确认两个以上 Consumer 后才下沉）
        ↓
LayoutEditorOverlay
  ├ SelectionModel
  ├ Selection Rect
  ├ 8-way Handle
  ├ Anchor
  ├ Snap/Grid/Guide
  └ Geometry Transaction
        ↓
Pointer/Drag 与 Windowing 统一审计
        ↓
状态显示页面 UI_REVIEW
```

本轮仍不改变任何 Product Capability 状态。

---

### 18.1.4 `.18.66` Coordinate / Pointer / RectTransform Foundation

这一轮解决一个以后所有可视化编辑器都会踩到、而且非常容易被自然语言误导的问题：**ArcheAge/CryEngine UI 的二维坐标方向必须成为 Foundation Contract，而不是靠每个 Agent 记忆。**

#### A. 坐标方向是硬规则

```text
左上角 = (0,0)

X 增大 → 向右
X 减小 → 向左
Y 增大 → 向下
Y 减小 → 向上
```

以后需求写“Buff 图标向上 8px”，设计和实现统一解释为：

```text
MoveUp(8)
→ offsetY = -8
```

而不是“给 Y 加 8”。

页面 UI 文档也应尽量使用：

- `上移 8px（ΔY=-8）`；
- `下移 8px（ΔY=+8）`；
- `左移 8px（ΔX=-8）`；
- `右移 8px（ΔX=+8）`。

这样即使后续交给不同 Agent，也不再只有“上移一点”这种容易被传统数学坐标系误解的描述。

#### B. Inspector 中 Position 字段也必须表达方向

以后状态显示 / Healer / Range / Unit Lines 的 Transform Inspector 推荐统一：

```text
位置
┌──────────────────────────────────┐
│ X     [ -12.0 ]   ← 左 / 右 →    │
│ Y     [  -8.0 ]   ↑ 上 / 下 ↓    │
│                                  │
│ 快捷移动                         │
│ [↑ 1] [↓ 1] [← 1] [→ 1]         │
│ [↑ 5] [↓ 5] [← 5] [→ 5]         │
└──────────────────────────────────┘
```

数值字段仍然允许精确输入；方向按钮只作为 editor nudge，不作为“循环档位设置”。Tooltip 应明确：`Y 数值越小越靠上`。

#### C. RectTransform Transaction 是所有 Editor 的共享数学

候选 Consumer：

- Buff Display 元素布局；
- Healer Calibration；
- Range Shape editor；
- Unit HUD；
- 将来的 Floating HUD composition。

统一 transaction：

```text
Begin(startRect, move/resize, handle)
        ↓
PreviewDelta(dx,dy)
        ↓
┌──────────────────────────┐
│ Live Preview             │
│ Selection Rect           │
│ Inspector Numeric Fields │
└──────────────────────────┘
        ↓
Commit
或
Cancel → 完整 startRect
```

这里的 Transaction **只计算 Rect**，Native Capture/StartMoving/StartSizing 继续由 Windowing/Input Authority 控制。

#### D. 8-way Handle 统一几何语义

```text
┌●──────────●──────────●┐
│ top_left   top   top_right
│                       │
● left             right ●
│                       │
│ bottom_left bottom bottom_right
└●──────────●──────────●┘
```

例如拖 `top_left` 向左上：

- Pointer `dx < 0`；
- Pointer `dy < 0`；
- `x/y` 同步减小；
- `width/height` 同步增加；
- opposite edge 保持固定。

这条数学不能在状态显示、治疗校准、范围辅助各写一次。

#### E. Pointer Contract 当前只负责采样，不负责 Capture

```text
RSUI.Pointer
├─ GetLogicalPosition
├─ Delta(start,current)
└─ genericCapture = false
```

这是刻意的。当前已验证 Native Windowing/drag proxy 已有 `StartMoving/StartSizing/StopMovingOrSizing`，所以 LayoutEditorOverlay 后续应该“复用 capture + 共享 Rect math”，而不是再注册一套 permanent OnUpdate/raw mouse system。

#### F. Drawer / Scrim 当前不新增 Foundation

Application `ModalHost` 已有唯一 modal scrim。ResponsiveInspector Drawer 默认非模态，继续 Stable Host。除非之后至少两个明确 Consumer 都需要局部遮罩与输入阻断，否则不再新增一个 Generic Scrim Service。

#### G. 下一轮 UI Foundation 顺序

```text
Coordinate / Pointer / RectTransform          ✅
        ↓
Selection Geometry Model
        ↓
Selection Overlay + 8-way Handles
        ↓
Grid / Snap / Alignment Guides
        ↓
LayoutEditorOverlay
        ↓
Editor Workspace Template
        ↓
状态显示 UI_REVIEW
```

页面布局文档从此必须同时写**视觉方向**与**实际坐标符号**，尤其是 Anchor/Offset/Transform 设置。

本轮仍不改变 Product Capability Matrix。

---

### 18.1.5 `.18.67` Selection Geometry / Handle / Snap Foundation

这一轮继续只建设底层，不把任何 Feature 页面提前接入。目标是把将来状态显示、治疗校准、范围辅助、Unit HUD 都会重复使用的 **Selection Geometry** 做成一份共享实现。

#### A. 先区分“选中谁”和“选中框在哪里”

```text
SelectionModel                  SelectionGeometryModel
──────────────                  ──────────────────────
selectedKey                     rectByKey
selectedKeys        ───────→    aggregate bounds
primaryKey                      primaryRect

Who                             Where
```

因此 Layout Editor 不允许把坐标、宽高、Handle 状态写回 SelectionModel。Geometry 只是 Selection + Caller `getRect` 的派生 Projection。

#### B. SelectionOverlay 的实际层级

```text
SelectionOverlay Root（比目标 Rect 四边扩出 inset）
└─ Exact Frame
   ├─ Border Top / Bottom / Left / Right
   ├─ Move Hit Surface（整框移动；`.18.68` 接 Gesture）
   └─ Resize Handles × 8
      ├─ larger transparent hit rect
      └─ smaller visible handle
```

为什么 Root 要扩 inset：如果 Handle 的命中区直接伸出 Frame，而 Native Parent 存在 clip，用户会出现“看得到角点但点不到”的体验。当前做法让所有 Hit Surface 都落在物理 Root 范围内，而可见 Frame 仍保持精确 Rect。

Handle 顺序固定：四角优先，再四边；Move Surface 创建在 Handle 之前，因此边缘 resize handle 的 Native hit order 高于整框 move。

#### C. Snap / Guide Resolver

可吸附来源：

- sibling / candidate 左、中心、右；
- sibling / candidate 上、中心、下；
- Grid；
- Canvas 边/中心（Caller 选择是否加入）。

性能预算：

```text
默认 candidate scan = 256
hard cap               = 1024
每帧输出 guide          <= 2（X 1 + Y 1）
```

Resolver 不搜索 Widget Tree、不读取 Feature Store、不调用 Native metadata。候选由上层提供，Resolver 只做 bounded math。

#### D. 多轮覆盖后的 Foundation 回流修复

重新读取用户最新整包后发现，`.18.63` 的旧 UI 文件组部分回流，而 `.18.64~.18.66` 新代码仍在，形成“文档版本新、底层局部旧”的分叉。当前已按真实文件/调用链恢复：

- `UI.ComponentsV2` 再次从 TOC 和物理目录退出；
- `ContainerSurface / PopupCoordinator / Dropdown fail-closed / UITokens v4` 恢复；
- Foundation Audit 增加 **Disk Lua 必须属于 Active TOC** 的双向门禁。

以后“旧 Lua 文件只是没加载”也不再被视为安全状态，避免下一次 TOC 合并又把历史层复活。

---

### 18.1.6 `.18.68` Layout Editor Gesture Transaction Foundation

这一轮把 `.18.67` 的纯数学/视觉 Surface 接到已经验证的 RU Drag Capture，但仍然**没有实现某个业务页面的 Layout Editor**。

#### A. 完整手势生命周期

```text
OnDragStart
  ↓
canBegin
  ↓
Get Start Rect
  ↓
Get Pointer（viewport logical）
  ↓
Freeze Snap Options / Candidates   ← 每手势只做一次
  ↓
RectTransform.Begin
  ↓
BeginNativeGeometryLease
  ↓
Native StartMoving                 ← capture authority
  ↓
InteractiveTask 16 ms
  ├ Pointer current
  ├ dx / dy
  ├ PreviewDelta
  ├ Resolve Snap/Guide
  ├ OverridePreview
  ├ SelectionOverlay.SetRect
  ├ GuideOverlay.SetGuides
  └ onPreview
  ↓
OnDragStop
  ├ final pulse
  ├ Remove InteractiveTask / OnUpdate fallback
  ├ StopMovingOrSizing
  ├ EndNativeGeometryLease
  ├ Commit
  ├ Clear Guides
  └ Caller onCommit（这里才允许 Persistence）
```

Cancel 与 Release 必须走相反路径并恢复 Start Rect，不能留下 task / lease / OnUpdate handler。

#### B. 坐标空间 Contract

自然语言方向已经统一为：`上=-Y / 下=+Y`；这轮继续把**坐标空间**也做成硬规则。

```text
Pointer = viewport-logical
```

如果编辑目标也是 viewport Rect：

```text
coordinateSpace = "viewport"
```

如果编辑目标位于 Preview Canvas / Panel 内：

```text
pointerToLocal(viewportX, viewportY)
→ canvasLocalX, canvasLocalY
```

没有任何转换声明时 Controller 直接拒绝创建。禁止页面偷偷把 viewport mouse 坐标减一个“猜测的窗口位置”。

#### C. 为什么 RectTransform 升 v2

视觉 Snap 和事务 Commit 必须是同一个最终 Rect：

```text
错误：
Preview x=97
Guide 显示 x=100
Commit x=97

正确：
Preview x=97
Guide Resolver → x=100
OverridePreview x=100
Commit x=100
```

因此 v2 新增 `OverridePreview()`，并继续保持 left/top resize 的 opposite-edge 固定语义。

#### D. 高频性能边界

Gesture Controller 允许的高频工作只有真实用户正在拖动时：

- Pointer sample；
- delta；
- 1024 hard-cap 内 Snap math；
- 1 个 selection frame + 8 handles + 最多 2 guide line 的 diff geometry；
- Caller lightweight preview callback。

禁止在 16ms pulse 中：

- 枚举 Feature/Widget Tree；
- 查询 Buff/Skill/Item metadata；
- 读写 Store/Persistence；
- 动态发现 Snap Candidate；
- 新建/销毁 Handle/Guide Widget；
- 注册第二个永久 Tick。

#### E. 下一层页面级底座

`.18.69/.18.70` 已完成 Anchor/Pivot、Snap Settings 与 Transform Inspector。现在不应该因为这些依赖齐了就马上拼完整 Overlay；还必须先解决**多选整体 Transform**：

```text
Selection Overlay + Gesture                     ✅
Anchor / Pivot Model                           ✅
Grid / Alignment / Guide Settings              ✅
Transform Inspector                            ✅
                 ↓
MultiSelectionTransformModel                        ✅
                 ↓
LayoutEditorOverlay（只组合，不造新 Authority）
                 ↓
Editor Workspace Template
                 ↓
状态显示 UI_REVIEW
```

原因：单元素的 Anchor/Pivot/Offset 是真实 Child Placement；多选时 Selection Bounds 只是 Group Projection，不能把 Group Bounds 直接写进某一个 Child 的 AnchorPivotModel。这个边界必须先成为 Foundation Contract。

本轮仍不改变 Product Capability Matrix。

---

### 18.1.7 `.18.69` Anchor / Pivot / Snap Settings Foundation

这一轮继续零业务迁移，补齐 Layout Editor 最容易被页面重复实现、也最容易出现坐标错误的两份共享 Model。

#### A. Anchor/Pivot 只做 Point Anchor v1

当前 Suite 大量历史布局都以 top-left Rect 保存，因此 v1 **不直接实现 Stretch Anchor**。第一版只支持：

```text
┌──────────── Parent Rect ────────────┐
│ ● top_left   ● top   ● top_right    │
│                                     │
│ ● left       ● center ● right       │
│                                     │
│ ● bottom_left● bottom ● bottom_right│
└─────────────────────────────────────┘

anchorX / anchorY : 0..1
pivotX  / pivotY  : 0..1
```

Anchor/Pivot 修改默认 `preserveVisual=true`：

```text
修改前 visual Rect
      ↓
改变 anchor/pivot
      ↓
重新计算 anchor-relative offset
      ↓
visual Rect 保持不动
```

这能避免玩家只是从“左上锚点”换成“中心锚点”，图标却突然飞到屏幕中央。

父容器 resize 则必须显式选择：

- **Preserve Visual**：仍停在当前 local Rect；
- **Follow Anchor**：保持 Anchor-relative Offset，让控件随 parent 尺寸移动。

页面不得自己写第三种隐式规则。

#### B. 坐标方向继续语义化

```text
ArcheAge / CryEngine UI
左上 = (0,0)

MoveUp(8)    => ΔY=-8
MoveDown(8)  => ΔY=+8
MoveLeft(8)  => ΔX=-8
MoveRight(8) => ΔX=+8
```

任何页面文档中出现“向上/向下”时，建议同时写实际符号。

#### C. Snap Settings Model

统一字段：

| 设置 | 语义 | 范围/默认 |
|---|---|---|
| enabled | 总吸附开关 | true |
| gridEnabled | 网格吸附 | true |
| alignmentEnabled | sibling/candidate 对齐 | true |
| canvasEnabled | Canvas 边/中心对齐 | true |
| showGuides | 显示 X/Y Guide | true |
| gridSize | 网格间距 | 1~128，默认 8 |
| threshold | 吸附距离 | 0~32，默认 6 |
| maxCandidates | 最大候选 | 1~1024，默认 256 |

性能契约新增：

```text
alignmentEnabled=false
      ↓
Gesture Begin 不调用 getSnapCandidates()
      ↓
Grid-only 手势 = 0 sibling discovery
```

不是“拿到 1000 个候选以后再不使用”，而是根本不发现。

---

### 18.1.8 `.18.70` Transform Inspector v1

这一轮把前面的 Model 接成一份真正可跨页面复用的 Inspector，但仍然没有接入状态显示/治疗/范围辅助等业务页面。

#### A. Inspector 的详细排列

默认 Inspector 设计宽度约 **286px**，由 ResponsiveInspector 在 wide/compact 之间切换位置。内容本身保持同一个实例。

```text
┌──────────────── 变换 ────────────────┐
│ X（左-/右+）        Y（上-/下+）     │  46px row
│ [      120 ]        [       92 ]     │
│                                      │
│ 宽度                高度             │
│ [       80 ]        [       40 ]     │
└──────────────────────────────────────┘
               8px section gap
┌──────────── 锚点与轴心 ──────────────┐
│ 锚点预设 [中心 ▼]   锚点 X [0.50]    │
│ 锚点 Y [0.50]       Pivot X [0.50]  │
│ Pivot Y [0.50]      锚点偏移 X [...]│
│ 锚点偏移 Y [...]                     │
└──────────────────────────────────────┘
               8px section gap
┌──────────── 吸附与参考线 ────────────┐
│ 启用吸附 [ON]       网格吸附 [ON]    │
│ 对象对齐 [ON]       画布对齐 [ON]    │
│ 显示参考线 [ON]     网格尺寸 [ 8 ]   │
│ 吸附阈值 [ 6 ]      候选上限 [256]   │
└──────────────────────────────────────┘
```

布局要求：

- 每 Section 默认 2 列；
- cell 最小约 104px；
- field 行高约 46px；
- section 内 gap 6px；
- section gap 8px；
- Exact NumericInput 始终可见，不用 +/- 循环档位代替；
- X/Y/Offset 允许负数；
- Anchor/Pivot 限 0..1；
- compact drawer 中如果可用宽度不足，交给 Form/ResponsiveGrid 降列，不复制第二套字段。

#### B. 为什么必须显示两套“位置”

```text
X/Y
= 当前 parent coordinate space 的 top-left visual Rect

Anchor Offset X/Y
= Anchor absolute point → Pivot point 的相对距离
```

二者不是重复字段。Center Anchor 下出现负 Offset 很正常。隐藏 Offset 会让高级用户无法判断 resize/reflow 后为什么位置变化；只显示 Offset 又会让普通用户难以理解“屏幕上到底在哪里”。

#### C. UI Binding Authority

```text
NumericField / DropdownField / ToggleField
                ↓
           RSUI Binding
                ↓
 AnchorPivotModel / SnapSettingsModel
                ↓
 onTransformChanged / onSnapChanged
          （notification only）
```

回调不能成为第二 mutation Authority。TransformInspector 不直接 SaveStore，也不持有 Feature layout config。后续完整 Editor Session 决定 Preview/Commit/Persistence。

#### D. 当前 LayoutEditorOverlay 暂缓原因

单选时：

```text
AnchorPivotModel ⇄ one real child rect
```

多选时：

```text
Selection Bounds = derived group rect
              ≠ any one child rect
```

下一步必须先做 Group Transform Mapping：

```text
Start Group Bounds
 + each child start rect
        ↓
Group move/resize preview
        ↓
relative position/scale mapping
        ↓
per-child preview rects
        ↓
transaction Commit / Cancel
```

这一层已经在 `.18.71` 完成；因此下一步可以进入 `LayoutEditorOverlay`，但 Overlay 只能做 Coordinator/Composition，不能重新定义 Group Transform 数学。

---

# 19. 从参考项目提炼出的共享 Foundation 候选

这些可能比“新增某个页面”更值得优先讨论，因为它们可以同时改善多个功能。

## 19.1 Command Transaction + Verification

来源：`gearswap`、`titleswap` 等。

候选契约：

```text
BuildPlan()
   ↓
ValidatePreconditions()
   ↓
ExecuteStep()
   ↓
Cooldown / bounded retry
   ↓
Readback()
   ↓
VerifyExpectedState()
   ↓
Success / Partial / Failed
```

潜在 Consumer：

- Gear；
- Title；
- Team Role；
- Marker；
- Bag Move；
- 将来其它有 Native 写操作的 Feature。

## 19.2 RSUI IconPicker

来源：Gear、Cooldown Tracker 等多个插件。

统一支持：

- 复用 `.18.64` `PickerModel` 作为唯一搜索/选择数据 Authority，并复用 `.18.65` `SearchablePicker` 的显式提交/状态/Focus 语义；
- 使用 `TileView`/虚拟池显示图标，不为全部候选常驻创建 Native Widget；
- 搜索（首版显式提交，不猜 OnTextChanged）；
- 最近使用；
- 图标预览；
- Item/Skill/Buff Icon Candidate；
- 默认/自定义图标；
- Persistent selected icon。

`IconPicker` 只负责 Presentation、分类投影和视觉预览；不得再内部维护另一份 query/results/selected index。

## 19.3 Unit Relationship Graph

统一表达：

- player；
- target；
- targettarget；
- watchtarget；
- watchtargettarget；
- 将来的 team member / recommendation target。

供 Unit Lines、Aggro HUD、Healer、Boss Mechanic 等复用。

## 19.4 World Overlay / Shape Framework

统一表达：

- Circle；
- Ring；
- Cone；
- Line；
- Arc；
- Anchor；
- Offset；
- Color；
- Sampling Budget；
- ScreenProjection batch。

供 Range Assist、Boss Mechanics、Treasure/Route Visual Guide 复用。

## 19.5 Rule Registry

适合统一：

- Raid Readiness Rule；
- Boss Mechanic Rule；
- Status Alert Rule；
- Reminder Rule；
- Threshold Color Rule。

注意：Registry 只负责规则描述/注册，不允许变成超级业务 Authority。

## 19.6 Raid Grid / Member Slot

供：

- Healer Overlay；
- Custom 100-man Raid View；
- Raid Readiness；
- Buff Check；
- Cast Highlight。

必须复用 `TeamRosterV3`，不能复制团队成员 Authority。

## 19.7 Distance / Proximity Visual Rule

供：

- Healer；
- Treasure；
- WatchTarget；
- Raid member distance；
- Range boundary；
- Unit HUD。

## 19.8 Dev Inspector

把 `statspy` 这一类能力吸收到 Diagnostics，而不是普通产品 Runtime：

- Unit Inspector；
- Aura Inspector；
- API Result Inspector；
- Projection Inspector；
- Capability Evidence capture。

---

# 20. 当前最值得优先讨论的 10 个方向

这只是**讨论顺序建议**，不是自动批准开发。

1. **Gear Transaction / 同名装备识别 / 执行后验证**  
   直接对应当前换装失败问题。

2. **Unit Relationship Graph + Unit Lines**  
   直接对应焦点目标、目标的目标、布局与刷新问题。

3. **World Overlay / Range Assist**  
   直接对应颜色、分辨率中心偏移，并为未来 Boss 范围机制铺底层。

4. **Buff Display → 完整 Unit HUD Composition**  
   结合 Buff/Debuff、职业、装分、距离、装备、施法、CD。

5. **Healer / 100 人 Raid Grid**  
   继续完善 `RaidTeam ≠ RaidPanel ≠ Calibration`，解决单列表/双列表/1团/2团组合。

6. **Raid Readiness / Team Tools Rule Registry**  
   Buff、职业、职责、距离、Marker、整理团队统一设计。

7. **Activities + Tasks + Reminder UX**  
   活动、任务、分组、详情、悬浮窗、提醒形成完整工作流。

8. **Treasure Assistant 完整工作流**  
   自动识别 → 最近优先 → 指南针 → 距离 → 地图定位。

9. **Craft / Trade / Economy**  
   材料、库存、报价、货率、利润全部通过已有 V3 Economy Services 管理。

10. **Diagnostics Inspector**  
    用来帮助我们后续验证 RU API/字段，降低“猜代码”概率。

---

# 21. 与当前 Product Capability Matrix 的关系

当前 `PRODUCT_COMPLETION_MATRIX.md` 的 125 条能力仍然是现有产品完成度 Authority。

本文中的 `REF-*` 项：

- **不会自动加入 125 条能力；**
- 不会因为参考 Addon 做过就标记 Suite 为缺失；
- 只有用户明确接受某能力后，才判断：
  1. 是否已经被当前能力覆盖；
  2. 是否应作为现有能力的增强；
  3. 是否需要新增 Product Capability Row；
  4. 是否因为 RU API 缺失进入 `SPECIFIC_RUNTIME_BLOCKED`。

这样可以避免参考插件把 Suite 的产品范围无限膨胀。

---

# 22. 后续逐项讨论模板

以后我们每讨论一个 `REF-*`，建议在本文相应条目下补一个决策块：

```text
### REF-XXXX-000 — <能力名>

#### A. 页面/UI

- 页面目标：
- Surface：
- UI 状态：`UI_DISCUSS`
- 默认 Gameplay View：
- 主页面 Wireframe：
- Settings / Inspector：
- 1024×768：
- Empty / Error / Pending / Runtime Blocked：


用户目标：
- ...

最终产品形态：
- ...

不采用的旧插件行为：
- ...

Authority：
- ...

Shared Services：
- ...

Feature Consumer：
- ...

Projection：
- ...

RSUI：
- ...

### 18.1.9 `.18.71` Multi Selection Transform Model v1

这一轮继续不做业务页面，而是把 Layout Editor 最后一个关键“数学/事务边界”补齐：**多选 Selection Bounds 不是某一个真实 Child Rect**。

#### A. 单选与多选明确分权

```text
单选
Selection key
   ↓
AnchorPivotModel
   ↓
真实 Child Rect / Anchor / Pivot / Offset

多选
Selection keys (2+)
   ↓
SelectionGeometryModel
   ↓ derived
Group Bounds
   ↓ Gesture / Snap
Target Group Bounds
   ↓
MultiSelectionTransformModel
   ↓
每个 Child 的 preview / committed Rect
```

禁止把 Group Bounds 写进任意一个 Child 的 AnchorPivotModel。

#### B. Projection Session

多选变换使用显式 session，而不是每个 Child 边拖边永久写：

```text
BeginProjectionSession
├─ freeze stable-key child rects
├─ freeze start group bounds
├─ freeze base revision
└─ calculate min group extent

Project(target bounds)
├─ O(N selected) pure math
├─ 生成 preview child rects
└─ committed model 不变

Commit
├─ revision check
├─ 一次性 commit 全 child rect
└─ session close

Cancel
└─ committed model 0 修改
```

因此未来拖动 30 个 HUD 元素时，不会出现前 20 个已经写入、后 10 个失败的半状态。

#### C. Resize 映射规则

```text
scaleX = targetGroup.width  / startGroup.width
scaleY = targetGroup.height / startGroup.height

childX = targetGroup.x + (startChild.x - startGroup.x) * scaleX
childY = targetGroup.y + (startChild.y - startGroup.y) * scaleY
childW = startChild.width  * scaleX
childH = startChild.height * scaleY
```

所以：

- Group Move：宽高不变，Child 只平移；
- 左/右 Resize：只改变 X 轴组内比例；
- 上/下 Resize：只改变 Y 轴组内比例；
- Corner Resize：X/Y 同时按 Group 比例映射。

当前 v1 **不做 Rotation / arbitrary pivot group transform**。这些必须有明确产品需求后再进入 Foundation。

#### D. Group 最小尺寸不是固定 1px

若某个 Child 最小允许 20px，而它在 start group 中只有 40px，则 Group 在该轴最多缩到 50%。模型会在 session begin 时从所有 child 反推出：

```text
minGroupWidth
minGroupHeight
```

未来 LayoutEditorOverlay 应在 Gesture Begin 前把这两个值交给 RectTransformTransaction，从源头限制 Group resize；禁止先让 Group 缩过头再逐 Child clamp，因为那会破坏相对比例。

#### E. 大量选择的性能/安全边界

| 项 | 规则 |
|---|---|
| 最小选择数 | 2；单选拒绝 |
| 默认 maxItems | 256 |
| hard cap | 1024 |
| identity | stable key/id |
| duplicate | fail-closed |
| 超上限 | fail-closed，不截断 |
| Project | O(N selected) |
| Tick/OnUpdate | 0 |
| Native Widget | 0 |
| Metadata/API 查询 | 0 |
| Persistence | 0，外层 Commit 才决定 |

#### F. 多选时 Inspector 的布局必须改变

多选不是“把单选 Inspector 原样留下”：

```text
┌────────── 多选变换 ──────────┐
│ 已选择  12 个                │
│ Group X       Group Y        │
│ [ 120 ]       [ 80 ]         │
│ Group Width   Group Height   │
│ [ 640 ]       [ 260 ]        │
├──────────────────────────────┤
│ 吸附与参考线                 │
│ ...与单选复用同一 Snap Model │
└──────────────────────────────┘

Anchor / Pivot
→ 不显示，或明确“多选不可直接编辑”
```

因为每个 Child 可能拥有不同 Anchor/Pivot；人为制造一个“Group Anchor”并写回所有 Child 会破坏已有布局。

#### G. `.18.72` Layout Editor Preview Adapter + Transaction v2

`.18.71` 解决了多选数学，但仍缺少一个统一协调层来回答：**当前选中对象到底是单选还是多选，Inspector/Gesture 应该对谁 Preview、谁 Commit，Persistence 拒绝时谁负责回滚？**

因此 `.18.72` 新增 `LayoutEditorPreviewAdapter v1`，并同步升级：

- `LayoutEditorGestureContractVersion = 2`；
- `AnchorPivotContractVersion = 2`；
- `TransformInspectorContractVersion = 2`。

统一 Authority 链：

```text
SelectionModel
    │ stable key + selection revision
    ▼
LayoutEditorPreviewAdapter
    ├─ single → AnchorPivotModel
    ├─ multi  → MultiSelectionTransformModel / ProjectionSession
    └─ working rect projection
         │
         ├─ TransformInspector v2
         └─ LayoutEditorGesture v2
                  │
                  ▼
          Preview / Commit / Cancel
                  │
                  ▼
      Feature Projection / Persistence Adapter
```

这里的关键约束不是“多一个 Adapter”，而是**只允许一条事务链**：

1. Gesture Begin 记录 selection revision；
2. Preview 只更新 editor working projection；
3. Feature Store 不允许在拖动每一帧写入；
4. Commit 先经过 Feature/Persistence 回调明确接受；
5. Persistence 拒绝时 Adapter 完整恢复 start items；
6. 手势中选择集合发生变化时 fail-closed；
7. Cancel 不留下半事务；
8. Adapter 自己不拥有业务 Store。

`Gesture v2` 同时增加**手势开始时动态尺寸约束**：

```text
Begin Gesture
   ↓
Adapter:GetTransformConstraints()
   ├─ single → item constraints
   └─ multi  → MultiSelection:GetGroupConstraints()
   ↓
RectTransformTransaction
```

因此不需要为了“单选/多选最小尺寸不同”反复销毁 Gesture Controller。

Anchor/Pivot 也新增完整 `ApplySnapshot()`：Persistence 拒绝 Anchor 修改时，不仅恢复 Rect，还恢复 `anchorX/Y + pivotX/Y + placement offsets`，防止出现“屏幕位置恢复了但锚点元数据已损坏”。

#### H. `.18.73` LayoutEditorOverlay v1

这一层终于开始“组合”，但**不创建新的 Geometry/Pointer/Snap Authority**。

组件树：

```text
LayoutEditorOverlay
├─ LayoutGuideOverlay          ← 最底层视觉参考线
├─ SelectionOverlay           ← Selection Frame
│  ├─ Move Hit Surface
│  └─ 8-way Resize Handles
├─ LayoutEditorPreviewAdapter ← 单/多选事务桥
├─ LayoutEditorGesture v2     ← 唯一 editor gesture bridge
└─ SnapSettingsModel          ← 与 Inspector 共享同一实例
```

严格分工：

| 层 | 唯一职责 |
|---|---|
| SelectionModel | 选中了谁 |
| SelectionGeometry | 选中对象 Bounds/Handle Geometry |
| Pointer | logical pointer + delta |
| RectTransform | move/resize 数学 |
| GuideResolver | grid/sibling/canvas snap |
| Gesture | Native capture + 手势期采样 |
| PreviewAdapter | single/multi projection + transaction |
| Overlay | 组合/刷新/visual routing |
| Feature | 业务 Projection/Persistence |

Overlay 不允许调用新的 `StartMoving/StartSizing`；这些仍属于 Gesture/已有 Native Windowing Capture 路径。

对象对齐候选只在 Gesture Begin 冻结一次，并且：

- 排除当前 Selection 自身；
- 检查数量有界；
- hard cap 继续是 1024；
- `alignmentEnabled=false` 时不调用 candidate discovery；
- drag pulse 中不重新扫描 Widget Tree。

坐标空间继续 fail-closed：

```text
Viewport Logical Pointer
        │
        ├─ target coordinateSpace=viewport → 直接使用
        │
        └─ target coordinateSpace=local
                 ↓
             pointerToLocal()
```

Overlay 不允许自己猜 `mouse - windowPos`。

#### I. `.18.74` LayoutEditorWorkspace v1

`WorkspaceTemplates v3` 新增 `CreateLayoutEditorWorkspace()`，目标不是“给状态显示做一个页面”，而是提供 **Buff Display / Healer Calibration / Range Shape / Unit HUD 等页面都能复用的编辑器页面骨架**。

##### Wide / Regular 布局

逻辑宽度足够时：

```text
┌──────────────────────────── Toolbar 30px ─────────────────────────────┬──────────────┐
│ [状态：单选 1 / 多选 N]          左上(0,0) · X→右 · Y→下             │              │
├───────────────────────────────────────────────────────────────────────┤ Transform    │
│                                                                       │ Inspector    │
│                        Preview Canvas                                 │ ~286px       │
│                                                                       │              │
│  Feature Preview Host                                                 │ X / Y        │
│        +                                                              │ W / H        │
│  LayoutEditorOverlay                                                  │ Anchor*      │
│        +                                                              │ Pivot*       │
│  Guides / Handles                                                     │ Snap         │
│                                                                       │              │
└───────────────────────────────────────────────────────────────────────┴──────────────┘
```

`* Anchor/Pivot` 只在单选显示。

推荐初始规格：

| 区域 | 建议 |
|---|---:|
| Toolbar | 30～34px |
| Inspector | 约 286px |
| Inspector 最小宽度 | 220px |
| Preview 最小逻辑宽度 | 360px |
| 内部 Gap/Padding | 使用 UITokens，不散落页面魔法值 |

##### Compact 布局

窄页面不创建第二份 Inspector：

```text
┌────────────────────────────────────────┐
│ Toolbar                                │
├────────────────────────────────────────┤
│                                        │
│          Preview Canvas                │
│                                        │
│                   ┌──────────────────┐ │
│                   │ SAME Inspector   │ │
│                   │ Drawer           │ │
│                   │                  │ │
│                   └──────────────────┘ │
└────────────────────────────────────────┘
```

即：

```text
Wide Inspector instance
==
Compact Drawer Inspector instance
```

只变 `Geometry / Visibility / Raise`，不复制 Selection、Scroll、Binding 或状态。

##### 单选 / 多选 Inspector 规则

单选：

```text
Transform
├ X / Y
├ Width / Height
├ Anchor preset
├ Anchor X/Y
├ Pivot X/Y
├ Anchor-relative Offset X/Y
└ Snap Settings
```

多选：

```text
Group Transform
├ Group X / Y
├ Group Width / Height
└ Snap Settings

Anchor / Pivot
→ collapsed
```

原因是不同 Child 可以拥有不同 Anchor/Pivot；Editor 不制造虚假的 Group Anchor。

无选择：

- SelectionOverlay 隐藏；
- TransformInspector disabled；
- StatusChip 显示“未选择”；
- 不启动 Gesture sampling。

##### Preview Host 与 Editor Overlay 的层级

```text
Canvas Overlay
├─ PreviewHost          ← Feature 自己的视觉 Projection
└─ LayoutEditorOverlay  ← Editor interaction / selection / guides
```

Feature 不应该把 Handle/Guide 塞回自己的 Preview Tree。

#### J. `.18.74` 之后的 Foundation 边界

到这一阶段，Layout Editor 已经具备完整的：

```text
Selection
Geometry
Pointer Direction / Coordinate Space
Move / Resize Transaction
Grid / Alignment
Anchor / Pivot
Single / Multi Projection
Transform Inspector
Responsive Inspector
Overlay Composition
Editor Workspace
```

但仍然**没有自动批准任何业务页面迁移**。

下一轮 Foundation 应优先讨论的是编辑操作的可恢复性，而不是马上给 Feature 写更多设置：

```text
LayoutEditHistory / Undo-Redo
        ↓
Editor Command Bar
        ↓
Reset / Revert / Apply semantics
        ↓
再进入状态显示 UI_REVIEW
```

这样玩家调整几十个 HUD 元素时才不会因为一次误拖就只能手工找回原值。

#### K. `.18.75` LayoutEditHistory / Undo-Redo

`.18.75` 已完成第一层可恢复编辑 Foundation：

- `LayoutEditHistoryModel v1` 只记录**成功 Commit**，Preview/Drag Pulse/Cancel 不入历史；
- stable-key before/after 必须同集合；默认 64、hard cap 256；
- Undo/Redo 只有在 caller apply transaction 接受后才移动 cursor；拒绝时保持 cursor 并 best-effort rollback；
- Anchor/Pivot 使用最小完整恢复状态，不把 revision/lastSource 等瞬态值写进 History；
- `LayoutEditorPreviewAdapter` 已提供可选 History 集成，单选、多选、Inspector Rect、Anchor/Pivot Commit 均可生成可逆命令；History replay 本身不会二次 Record。

因此路线推进为：

```text
LayoutEditHistory / Undo-Redo          ✅ .18.75
        ↓
Editor Command Bar                    ✅ .18.76
        ↓
Reset / Revert / Apply semantics      ✅ .18.77
        ↓
LayoutEditorWorkspace 接入            ✅ .18.78
        ↓
状态显示 UI_REVIEW                    NEXT
```

Persistence Lifetime：
- Foundation 只维护 Session/working projection；
- Permanent Feature Store 只允许 Commit 后写入；
- Preview / Drag Pulse 不允许持久化。

Demand / Scheduler / Event：
- 正常游戏态：0 editor sampling；
- Gesture Active：只存在手势期 InteractiveTask/validated fallback；
- Gesture End/Cancel：sampling 立即释放。

性能预算：
- Selection/Projection：O(selected)，有 hard cap；
- Snap candidates：Begin 时一次性有界冻结；
- Pulse：纯 pointer/rect/snap math；
- Metadata/API 查询：0；
- Feature Tree 全量扫描：0。

RU API / 数据证据：
- 继续只使用已验证 `StartMoving/StartSizing/StopMovingOrSizing` 路径；
- generic pointer capture / generic reparent / OnTextChanged / OnKeyDown 仍未解封。

兼容要求：
- 不改变现有 Feature Store Schema；
- 不重新解释老用户 top-left rect；
- 不创建第二套 Inspector/Selection/Drag Authority。

Acceptance：
- `LayoutEditorPreviewAdapter v1`；
- `LayoutEditorGesture v2`；
- `AnchorPivot v2`；
- `TransformInspector v2`；
- `LayoutEditorOverlay v1`；
- `WorkspaceTemplates v3`；
- Foundation Audit / Lua Parse / transaction harness 全通过。

当前状态：**Foundation IMPLEMENTED；业务页面尚未迁移**。

---

# 23. 开发前统一检查清单

任何 Feature 在开始正式代码实现前，对应页面原则上应至少达到 `UI_REVIEW`；直接影响核心操作流程的页面（Gear、Healer、Status Display、Range、Unit Lines、DPS）应达到 `UI_APPROVED` 后再进入大规模 UI 实现。


任何被接受的参考能力，在动代码前都必须确认：

1. 真实读取当前 Suite 代码，不凭插件名称猜现有能力；
2. 确认是否已有 Core / Service / RSUI 可复用；
3. 确认 Authority 在哪里；
4. 确认 Feature 是否能独立启停；
5. 确认关闭后释放哪些 Consumer / Event / Scheduler / Cache；
6. 确认 UI 只消费 Projection；
7. 确认写操作走 API Capability / Command Boundary；
8. 确认 Runtime API 是否有当前 RU 证据；
9. 高频数据是否 Event/Demand 驱动；
10. 是否需要 bounded / pooled / virtualized；
11. 配置属于 Permanent / Daily / Weekly / Session / Checkpoint 哪种 Lifetime；
12. 老用户升级时如何迁移；
13. 是否有明确 Acceptance / Diagnostics；
14. Active Lua 修改后跑 Foundation Audit；
15. RU Fresh Reload 才能确认 Native/UI/多人性能事实。

---

# 24. 页面 UI 优先讨论顺序

当前阶段优先目标是**先把页面设计成熟，再按确认后的页面反推 Projection / Service / Command 需求**。推荐讨论顺序：

1. **状态显示**：复杂度最高，会决定 Layout Editor / Inspector / Aura Browser 的公共形态；
2. **治疗辅助**：决定 50/100 人 Raid Surface、校准和高频状态呈现；
3. **换装**：解决当前实际不可用问题，同时建立 Command Transaction Feedback；
4. **单位连线**：确定 Relationship Graph 的玩家表达；
5. **范围辅助**：确定通用 Shape Editor；
6. **DPS / Combat Analytics**：确定高密度分析型页面；
7. **活动 / 任务**：确定生活类 Dashboard 与 Floating List；
8. **债券 / 居民板**；
9. **跑商 / 制作 / 经济**；
10. **寻宝 / 钓鱼 / 路线**；
11. **Boss Mechanics**；
12. **Diagnostics / Tools**。

每讨论完一个页面，更新：

```text
UI_DRAFT → UI_REVIEW → UI_APPROVED
```

只有确认后的 UI 才反向约束实现，不允许“代码先写完，再随便拼一个界面”。

---

# 25. 当前阶段结论

当前这份总路线图已经同时承担：

- 参考 Addon 能力整理与 `REF-*` 决策状态；
- 各功能页面的详细 UI 草案；
- RSUI / Editor Foundation 的实现记录与几何契约；
- 当前页面进入 `UI_REVIEW / UI_APPROVED` 前所缺的共享组件。

当前实际开发阶段仍是 **Foundation First**：Workspace、Tree/Picker、ResponsiveInspector、Selection/Guide/Gesture、Anchor/Pivot/Snap、Single/Multi Preview Adapter、TransformInspector、LayoutEditorOverlay 与 LayoutEditorWorkspace 已形成同一条共享编辑器链，但没有因为这些底层能力而提前把任何参考功能自动批准进入产品范围。

共享可恢复编辑语义 `LayoutEditHistory / Undo-Redo → Editor Command Bar → LayoutEditSession` 已完成；下一步先把三者接回 `LayoutEditorWorkspace`，随后再从状态显示开始逐页把 `UI_DRAFT → UI_REVIEW → UI_APPROVED`。

#### L. `.18.76` Editor Command Bar

`.18.76` 完成共享命令投影层，但**仍不定义 Reset/Revert/Apply 的持久化语义**：

- `LayoutEditHistoryModel` 增加 Observable Contract：成功 `Record / Undo / Redo / Clear` 事件驱动通知 Consumer；无 Tick/OnUpdate；
- `EditorCommandBar v1` 固定五命令入口 `Undo / Redo / Revert / Reset / Apply`；按钮状态完全由 History/Session Snapshot 投影；
- 没有 Session Authority 时 `Revert / Reset / Apply` 全部 fail-closed，避免页面以 callback/布尔变量临时模拟会话状态；
- Session busy 或 History busy 时五个命令统一 disabled，防止并发编辑事务；
- 新增纯 `ProjectEditorCommandState()`，便于 Gate/Sequence 在不创建 Native Widget 的情况下验证投影规则；
- 下一层才建立 Session Authority，并明确 Baseline / Working / Defaults / Persisted 四个状态边界。

性能：Authority 变化时 O(1) 状态投影 + 最多五个 Button enabled 写入；正常游戏态 0 polling。

#### M. `.18.77` LayoutEditSession / Persistence Boundary

`.18.77` 完成第三层编辑恢复语义：

- 四态固定为 `Persisted / SessionBaseline / Working / Defaults`，不再用一个模糊 dirty snapshot 同时承担“存档”“本次编辑起点”“当前预览”“默认值”；
- `Revert` 只恢复 SessionBaseline，`Reset` 只把 Defaults staged 到 Working，两者均不写 Store；
- `Apply` 是唯一 durable persistence crossing；callback 明确成功后才推进 Persisted/Baseline；
- `dirty` 对比 Working/Persisted，`sessionChanged` 对比 Working/SessionBaseline，因此“会话没改但当前 Working 尚未保存”的场景仍能 Apply，而不会错误开放 Revert；
- Revert/Reset/Apply 建立 History barrier；异常时优先 rollback 或 integrity block，禁止 stale Undo 穿过新基线；
- Session 只依赖 caller callback，不直接调用 Persistence/SaveData，所以具体 Feature Store 仍拥有持久化 Authority。

路线更新：

```text
LayoutEditHistory / Undo-Redo          ✅ .18.75
        ↓
Editor Command Bar                    ✅ .18.76
        ↓
LayoutEditSession semantics           ✅ .18.77
        ↓
LayoutEditorWorkspace 接入            ✅ .18.78
        ↓
状态显示 UI_REVIEW                    NEXT
```

#### N. `.18.78` LayoutEditorWorkspace v2 Integration

`.18.78` 完成共享编辑器恢复链的最终 Foundation 接线：

- `WorkspaceTemplates v4 / LayoutEditorWorkspace v2` 创建唯一 bounded History 并注入 PreviewAdapter，页面不再维护第二 Undo stack；
- `EditorCommandBar v2` 固定置于稳定 Command Host；History-only 模式仍兼容，但 Revert/Reset/Apply fail-closed；
- 完整 Session 模式要求 caller 一次性提供 `getWorkingSnapshot / getPersistedSnapshot / getDefaultSnapshot / applyWorkingSnapshot / persistSnapshot`，partial callback contract preflight 直接拒绝；
- History `record/undo/redo` 只刷新 Adapter→Overlay/Inspector；Reset/Revert/Rebase 才显式从 Feature Working 回读，避免把普通 Undo 重走 Source/Store；
- caller 主动 Source Refresh 会同步 `LayoutEditSession:RefreshWorking()`，避免外部布局刷新后 dirty/canApply 投影滞后；
- Workspace 不出现 `S.Persistence / SaveStore / MarkDirty`，durable Apply 仍必须由 Feature callback 明确确认；
- root teardown 负责释放 CommandBar UI 后再释放 Session/History listener/model，隐藏/关闭页面不遗留活动编辑状态；
- 仍无常驻 editor sampling；1024 宽内容区使用紧凑 CommandBar 尺寸，PreviewHost/Overlay/Inspector 单实例结构不变。

因此 Foundation 路线从“建立编辑能力”切换为“逐页 UI_REVIEW”。第一目标固定为**状态显示**，先验证页面布局、设置分组、Preview/Inspector 使用方式与交互密度，不因参考插件能力直接扩大业务范围。


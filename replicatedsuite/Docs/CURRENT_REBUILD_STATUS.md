# Replicated Suite 重建进度（唯一当前状态）

> **Authority: CURRENT**  
> 本文只保存“现在完成到哪里、现在还缺什么、下一步做什么”。逐版本实现过程见 [`CHANGELOG.md`](CHANGELOG.md)，历史阶段交接与验证记录见 `Archive/`。

## 1. 当前基线

| 项 | 当前状态 |
|---|---|
| Architecture | V3-only / `v3_rebuild` |
| Runtime Addon | `replicatedsuite/` |
| Legacy / Professional / `globals/` | 已物理删除，Active dependency = 0 |
| BuildTag | `v3-m1.16.0.18.74-ui-layout-editor-workspace-foundation` |
| Active TOC Lua | 207 |
| Active / All Lua | 207 / 207 |
| Foundation Audit | PASS |
| Product Capability Matrix | 125 条：77 IMPLEMENTED / 35 PARTIAL / 2 TODO / 11 SPECIFIC_RUNTIME_BLOCKED |
| RU Fresh Reload | PENDING |

当前 Foundation 结构指标：

```text
toc=207
activeLua=207
allLua=207
globals=0
presentation=0
rawNative=0
rawScope=0
detachedWidgetState=0
apiDependency=0
apiCapability=0
businessIds=0
auctionEventOwners=0
```

## 2. 已完成的框架级收口

当前已经完成以下长期架构基础，不再作为“待迁移”事项：

- 单一 V3 Application / Presentation Host；
- Core / Native / Services / Feature / Presentation 分层；
- FeatureRegistry + FeatureRuntime 独立生命周期；
- Demand / Scheduler / RefreshCoordinator / Observation / Events；
- Persistence Lifetime / Store / Migration / Write Fence；
- Native Import / Capability / Object Factory / Build Fence；
- RSUI WindowShell / FloatingSurface / DataView / ViewState / Binding / ActionRunner / Layout Templates；
- RSUI Workspace Composition v2：MasterDetail / InspectorWorkbench / ResponsiveInspector / SettingsWorkbench / CommandCenter + Breakpoint/Density Policy；
- RSUI Composite Foundation v4：`StatusChip` + `PickerModel` + `SearchablePicker` + `IconPicker` + transactional/stable/bounded `TreeModel` + virtualized `TreeView`；
- Host / Slot Attachment Contract v1：Component 单父节点、跨 Parent reparent fail-closed、每次 Attach 校验 Native creation parent；Release/RemoveChild 清理父容器强引用；
- ResponsiveInspector v1：同一个 Inspector 实例在 wide inline / compact drawer 间切换，只重排 Geometry/Visibility，不重建、不复制、不 reparent；
- SearchablePicker v1：复用 PickerModel + virtual ListView；只用已验证 Enter/EditEnter 或显式搜索按钮提交 Query，不绑定未经验证的实时 TextChanged/通用 KeyDown；
- IconPicker v1：复用 PickerModel + virtual TileView + Image Adapter；Icon path 由 Caller Projection 提供，默认只创建 viewport tile pool，并提供选中预览，不在 Foundation 读取 Skill/Buff/Item 元数据；
- Coordinate System Contract v1：ArcheAge/CryEngine 逻辑 UI 原点固定为左上 `(0,0)`；`+X=右 / -X=左 / +Y=下 / -Y=上`。页面禁止自行解释“向上/向下”的正负号，统一走 Layout semantic helpers；
- RectTransform Transaction v2：纯数学 staged `Begin → PreviewDelta → OverridePreview → Commit/Cancel`，支持 move + 8-way resize；Snap/Guide 可以覆盖 staged preview 后再 Commit，不拥有 Native capture，不与 Windowing `StartMoving/StartSizing` 竞争 Authority；
- Selection Geometry Foundation v1：`SelectionModel=Who`、`SelectionGeometryModel=Where` 分离；多选 Bounds、8-way Handle、Move Hit Surface、Grid/Sibling/Canvas Alignment Guide 均下沉共享层，候选 hard cap=1024；
- Layout Editor Gesture v2：只在实际拖拽期复用 RU 已验证 Native `StartMoving` capture 与 16ms InteractiveTask，Scheduler 不可用时才绑定 gesture-only `OnUpdate`；候选集合 Begin 时冻结，支持动态单/多选尺寸约束与 strict Preview/Commit rejection，停止时 Commit/Cancel 并释放 task/lease，不负责业务 Persistence；
- Anchor / Pivot Model v1：点锚点（9 presets + custom normalized anchor）与 Pivot/Rect/anchor-relative offset 统一为同一纯数据 Authority；切换 Anchor/Pivot 默认保持视觉 Rect，不让 HUD 元素跳位；父容器 resize 时由 Caller 明确选择 preserve-visual 或 follow-anchor reflow。Stretch Anchor 当前明确不支持，避免重新解释现有 top-left Rect 持久化。
- Layout Editor Snap Settings Model v1：`enabled / grid / alignment / canvas / guides / gridSize / threshold / maxCandidates` 统一为有界 editor-state；对象对齐关闭时 Gesture Begin 不再调用 candidate provider，grid-only 手势不扫描兄弟组件。
- Transform Inspector v1：复用 FormSection/NumericField/DropdownField/ToggleField，统一编辑 local X/Y、Width/Height、Anchor/Pivot、anchor-relative offset 与 Snap Settings；`Y（上-/下+）` 等标签直接表达 CryEngine 坐标方向。Inspector 只绑定共享 Model，不复制 Geometry/Persistence Authority；
- Multi Selection Transform Model v1：专门处理 2+ selection 的 Group Bounds → per-child Rect 投影；稳定 Key、最多 256 默认/1024 hard cap、单 session、原子 Commit/Cancel。Group Rect 的 move/resize/snap 仍归 RectTransform/Gesture，模型只负责按 Group 比例映射 Child，不拥有 Pointer/Native/Persistence；
- Layout Editor Preview Adapter v1：统一 Single/Multi working projection 与事务；Gesture 开始冻结 Selection revision，Preview 不持久化，外部 Commit 拒绝时恢复 start items；单选 Anchor/Pivot 修改可用完整 Snapshot Restore 回滚元数据。
- Layout Editor Gesture v2：手势 Begin 动态读取单选/多选 transform constraints；Preview/Commit 可以 strict reject；sampling/capture 失败会同步 Abort Adapter Session，不留半事务。
- Transform Inspector v2：改为一个 rectModel + 可选 anchorModel；同一个 Inspector 在单选显示 Anchor/Pivot，在多选折叠 Anchor/Pivot，不建立 Group Anchor。
- LayoutEditorOverlay v1：组合 SelectionOverlay/GuideOverlay/Gesture/PreviewAdapter/SnapModel；不拥有新的 Pointer Capture、RectTransform 或 Snap Resolver，非 viewport 坐标空间必须显式 pointerToLocal。
- WorkspaceTemplates v3 / LayoutEditorWorkspace v1：PreviewHost 位于 Editor Overlay 下层；Wide inline 与 Compact Drawer 使用同一个 Responsive TransformInspector 实例；Toolbar 明示 `左上(0,0) · X→右 · Y→下`。
- Pointer Contract v1：只负责事件驱动的逻辑坐标采样与 start→current delta；通用 pointer capture 明确 `false`，Native movement/sizing 继续由 Windowing 负责；
- Focus Contract v2：Focus 能力按真实 target Native 能力判断，不再把 `setFocus` 硬编码成全局可用；
- Input Event Fence：未获 RU 证据前，Active Runtime 禁止猜测绑定通用 `OnKeyDown / OnKeyUp / OnTextChanged`；
- Dropdown degraded path 改为 fail-closed/read-only，禁止弹层失败后偷偷退化成循环切换按钮；
- PopupCoordinator v1 统一 Dropdown / ColorField / ContextMenu 的互斥弹层生命周期；`DropdownService` 仅保留兼容 alias，不再是第二 registry；
- UITokens v4 增加统一 `layer.popupPriority`，Popup 不再散落硬编码 Z priority；
- 历史 `UI.ComponentsV2` 已退出 Active Runtime，Card/Section/FormSection 收敛回 RSUI `ContainerSurface`；
- Foundation Audit / UIV3 Acceptance / Diagnostics；
- Shared Static ID Registry；
- CombatEventBusV3 + CombatAnalyticsV3 单 all-scope 共享入口；
- TeamRosterV3 / AuraObservationV3 / CombatRelationV3 / ScreenProjectionV3 等共享事实服务；
- AuctionQueryV3 + PriceQuoteQueueV3 的显式、限速服务器查询路径；
- Legacy / Professional / `globals/` 物理删除与文档 Authority 收口。

## 3. 当前主要业务状态

### 3.1 Combat

- **DPS**：Domain / Store / Projection / Page / Floating Widget 已在 V3；PVP/PVE、伤害、承伤、治疗、技能/目标明细和技能代理 fail-closed 归属已实现。RU 多人 Combat Fact 语义与真实 UI 交互仍需 Fresh Reload / 实战样本。
- **Combat Analytics**：单 `scope=all` Consumer + 独立 Metric 生命周期已实现；Encounter、Kills、Casts、Performance、Control、Utility、Aura、Mechanics 等已接入。Songcraft 精确持续时间仍取决于 RU START/STOP 覆盖。
- **Death Review**：独立 `scope=self` 低开销链路、历史分片、单条删除/全部清除、Page/Widget/Modal 已实现；真实死亡事件字段仍需 RU 样本确认。
- **Healer**：Recommendation、Roster、Health、Aura、Page、Head Marker、Raid Overlay 已迁 V3。当前 Raid Overlay 使用 `RaidTeam ≠ RaidPanel ≠ Calibration` 模型，Panel A/B 几何与团队绑定解耦，并支持 `auto / single / dual`。下一关键点是 RU 50/100 人覆盖层、颜色、坐标、事件刷新与保存回读实测。
- **Buff Display**：四页签、分类追踪、头顶组件、导入导出与独立 Demand 已实现；StatusClassificationV3 为唯一分类 Authority。RU 图标、时间、目标切换、头顶 anchor / scale 仍需实机确认。
- **Raid Readiness / Boss Alerts / Team Tools**：安全子集已实现；未验证能力继续保持 Partial / Runtime Blocked，不使用猜测字段或禁止 API 补齐表面功能。
- **Unit Lines / Range Assist**：`.18.61` 重新整理单位连线设置页为两列卡片，避免每线点数/大小/颜色挤在单行；Range Assist 的颜色进入永久 Store default contract，ColorField 即使客户端无色块 Drawable 也显示“颜色 + HEX”可点击文本。

### 3.2 Life / Economy

- Activities / Tasks / Housing / Butler 已有 V3 垂直切片与对应 Acceptance。
- **Bonds / Resident Board**：`.18.61` 改为每个 board type 单次读取并归一化 `contents/content/rows/items`；大陆识别遵循 RU 既有插件行为（3+4 非空为大陆，5/6 非空为原大陆），空内容与 API 不可用不再混为同一状态。
- Trade / Bonds / Treasure / Fishing 通过生活/业务桥接提供独立能力，不要求主页面常驻；服务器查询与普通 Refresh 分离。
- Trade 材料成本与 Craft 材料报价已接入共享 `PriceQuoteQueueV3` read-model；未询价项保持明确未知，不从列表刷新自动批量请求拍卖行。
- 静态数据当前基线：Trade Product 98/98、Quest 214/214、Instance Database 19/19；Runtime Instance 仍只作为 session observation，不自动提升为静态 verified ID。

### 3.3 Tools

- **Gear**：`.18.61` 修复换装事务回归：GearV3 以 RU 已验证的 `bagId=1` 作为物理槽候选权威，并使用 `X2Bag:Capacity()` 有界扫描；不再因 bagId 0/1 逻辑视图差异整单取消。战斗中只执行主手/副手/远程/乐器武器队列，防具/饰品/称号显式延后，脱战后再次执行补齐。RU 真机仍需验证实际装备写入/cooldown。
- Instance Browser、Social、Random Shop 等已有 V3 路径。
- Bag / Auction / Market / Craft / Reinforce Analysis 等按已验证 RU API 提供安全子集。
- Hotkey Profiles、Portal Profiles、Siege Readiness 等仍有明确 Runtime blocker，保持 fail-closed。

## 4. Product Capability Gate

[`Rebuild/PRODUCT_COMPLETION_MATRIX.md`](Rebuild/PRODUCT_COMPLETION_MATRIX.md) 是产品能力完成度 Authority。

当前 125 条能力：

| 状态 | 数量 | 含义 |
|---|---:|---|
| IMPLEMENTED | 77 | 真实代码路径已存在；仍可能需要 RU 运行时验证 |
| PARTIAL | 35 | 只实现安全/已验证子集， advertised capability 尚不完整 |
| TODO | 2 | 产品范围内但暂无安全实现 |
| SPECIFIC_RUNTIME_BLOCKED | 11 | 缺少具体 RU API / 返回结构 / 权限 / 场景证据 |
| UNREVIEWED | 0 | 当前没有未审能力 |

Gate 仍为 **INCOMPLETE - CONTINUATION REQUIRED**。不得为了 Gate 变绿删除、降级或合并真实产品能力。

## 5. 本地已验证

本轮文档收口前的最新本地证据已经确认：

- `toc.g ↔ Active Lua`：205 ↔ 205，双向 0 差异；
- Foundation Audit：PASS，全部结构越界计数为 0；
- `RSUI_COMPOSITE_MODEL_HARNESS PASS rows=2 treeRebuilds=4`；
- `RSUI_TREE_TRANSACTION_HARNESS PASS contract=2 stable=1`，隐藏 duplicate 在展开阶段暴露时完整回滚；
- `RSUI_TREE_DEFAULT_COLLAPSE_HARNESS PASS overrides=2 bounded=3`，显式折叠覆盖默认展开并验证长期 expansion state 有界；
- `RSUI_TREE_BOUNDED_MEMORY_HARNESS PASS rows=64 siblings=20000 peakFrames=2 exactTruncated=true`；
- `RSUI_PICKER_MODEL_HARNESS PASS contract=1 scan=10`，稳定 Key、显式 query、AND token、有界 scan/results 与 selection 通过；
- `RSUI_FOCUS_SERVICE_HARNESS PASS contract=2`，target-aware Set/Clear/IsFocused 能力路径通过；
- `RSUI_HOST_SLOT_STRICT_HARNESS PASS attachRejects=4 mode=drawer`，跨父节点/循环 Parent 均 fail-closed，Release 能解除父容器强引用，ResponsiveInspector 切换时逻辑与 Native Parent 保持稳定；
- `RSUI_WORKSPACE_18_65_HARNESS PASS contract=2`，ResponsiveInspectorWorkspace 与既有 Workspace Composition 共存；
- `RSUI_SEARCHABLE_PICKER_HARNESS PASS results=2 selected=fire`，显式 Query、虚拟结果列表与 stable selection 正常；
- `RSUI_ICON_PICKER_HARNESS PASS results=2 selected=fire binds=8`，PickerModel 查询、TileView 绑定、图标 Projection、预览与 stable selection 正常；
- `RSUI_GEOMETRY_POINTER_HARNESS PASS upY=92 resize=90,85,90,75`，Top-Left 坐标方向、语义移动、8-way RectTransform、min-size 对侧边缘固定、Pointer delta 全通过；
- `RSUI_SELECTION_GEOMETRY_HARNESS PASS handles=8 alignX=200 grid=100,120`，多选 Bounds、8 Handle、Grid/Alignment snap 通过；
- `RSUI_SELECTION_GEOMETRY_BOUND_HARNESS PASS source=1100 bounded=1024 canvasBound=1024`，候选在建立临时副本之前即 hard-cap，Canvas 加入后总候选仍不超过 1024；
- `RSUI_SELECTION_OVERLAY_MOVE_HARNESS PASS moveIndex=3 handleIndex=4 upY=92`，整框 Move Hit Surface 在 resize handles 之前创建，边缘 Handle 保持命中优先级；
- `RSUI_RECT_TRANSFORM_V2_HARNESS PASS upY=92 commit=92,87,88,73`，Snap 后 `OverridePreview` 成为 Commit authority；
- `RSUI_LAYOUT_EDITOR_GESTURE_HARNESS PASS x=100 y=95 candidates=1 preview=3 leases=1/1`，候选 provider 每手势只调用一次、负 Y 上移、snap commit、geometry lease/task lifecycle 全通过；
- `RSUI_LAYOUT_EDITOR_FALLBACK_HARNESS PASS x=5 y=12 fallback=1`，Scheduler 拒绝时仅在手势期间绑定 OnUpdate，结束后立即解除；
- `RSUI_LAYOUT_EDITOR_SAMPLING_FAIL_HARNESS PASS leases=0 begins=0`，Scheduler 与 OnUpdate fallback 都不可用时 Begin fail-closed，Native movement/geometry lease 完整回滚；
- `RSUI_ANCHOR_SNAP_HARNESS PASS upY=142 gridX=200 scanned=0`，Anchor/Pivot preserve-visual、parent resize follow-anchor、四方向 Nudge 与 alignment-off 零候选扫描通过；
- `RSUI_TRANSFORM_INSPECTOR_HARNESS PASS fields=19 align=false`，Transform/Anchor/Pivot/Offset/Snap 19 个共享字段全部绑定同一 Anchor/Snap Model；
- `RSUI_GESTURE_CANDIDATE_SKIP_HARNESS PASS candidateCalls=0`，关闭对象对齐时 Gesture Begin 不执行候选发现；
- `RSUI_SNAP_STRICT_HARNESS PASS revision=1 grid=12 align=false`，非法 Snap 类型不产生半提交，显式 `false` 不被 Lua truthy/fallback 逻辑吞掉；
- `RSUI_MULTI_SELECTION_TRANSFORM_HARNESS PASS min=80x40 commit=200,150,800,400`，2-item bounds、比例缩放、child minimum、single/duplicate/cap fail-closed、Commit/Cancel 全通过；
- 全量 Lua：205/205 Parse PASS；Markdown 相对链接 0 断链；
- `RSUI_CONTAINER_SURFACE_HARNESS PASS created=7`，旧 `_card/_section` Native identity 保持；
- `RSUI_POPUP_COORDINATOR_HARNESS PASS closed=b`，单 registry / CloseAll(except) / unregister snapshot 正常；
- Product Matrix 统计可解析为 77 / 35 / 2 / 11，共 125 条；
- 当前 BuildTag 与 `replicatedsuite.lua` 一致：`v3-m1.16.0.18.74-ui-layout-editor-workspace-foundation`。

历史专项 harness、每个 M1.x 的逐轮数字与修复详情不再复制到本文，统一查 [`CHANGELOG.md`](CHANGELOG.md)。

## 5.1 当前 UI Foundation 先行状态

`.18.71` 继续保持 **Foundation First / 零业务 Feature 迁移**。`.18.69/.18.70` 已补 Anchor/Pivot、Snap Settings 与 TransformInspector；`.18.71` 正式增加 `MultiSelectionTransformModel v1`，把“Selection Bounds 只是 Group Projection、不能直接写回某一个 Child”变成代码契约。现在单选与多选的 Geometry Authority 已分开，下一层才允许组合 `LayoutEditorOverlay`。


### Coordinate / Pointer / RectTransform Contract

ArcheAge/CryEngine 逻辑 UI 统一为左上 `(0,0)`：`+X=右 / -X=左 / +Y=下 / -Y=上`。因此需求“向上移动 8”必须写成 `ΔY=-8`；Foundation 提供 semantic helper，Feature/页面不再自行解释正负号。

`RectTransformTransaction v2` 只做 staged geometry math：`Begin → PreviewDelta → OverridePreview → Commit/Cancel`。`OverridePreview` 专门接收 Snap/Alignment Resolver 的最终 Rect，使“视觉吸附结果”和最终保存坐标保持一致。Pointer capture 仍归既有 Windowing/native `StartMoving/StartSizing`，避免第二拖拽 Authority。`RSUI.Pointer v1` 只提供 absolute logical position + start→current delta，`captureSupported=false`。

### Host / Slot Attachment Contract v1

RU 客户端当前没有项目已验证的通用 Native `RemoveFromParent → AddChild` / Reparent API。因此 RSUI 不允许仅修改 Lua `parentComponent` 来伪造 UMG Reparent。现行契约：

```text
Create Child under Host A native content root
                 ↓
      parentComponent = Host A
                 ↓
      ┌──────────┴──────────┐
      │                     │
AddChild(Host A)        AddChild(Host B)
      │                     │
      PASS              FAIL-CLOSED
                            │
                  native_reparent_unverified
```

每次 `AddChild` 同时验证：

- Parent / Child 都是 live RSUI Component；
- self-cycle / ancestor-cycle 禁止；
- Child 已有其它 Parent 时禁止跨 Parent；
- Child 的 immutable Native creation parent 必须与目标 Host 的 `GetContentRoot()` 一致；
- `RemoveChild` 是**终止拥有关系 + Release**，不是“摘下来以后可以挂到别处”；
- Child 单独 `Release()` 会先从 live Parent 的 `children/slots` 中解除引用，避免逻辑对象已死但父容器仍强持有。

Static Foundation Audit 同时 fence Active Runtime 中未经验证的 `RemoveFromParent / Reparent / SetParent` 调用。后续如果 RU/官方证据确认安全 Native Reparent，必须先升级 Reparent Contract，再改变此策略。

### ResponsiveInspector v1：Stable Host，不复制状态

复杂页面常见结构是“主工作区 + 属性 Inspector”。宽屏需要右栏，1024×768 / 窄窗口下需要 Drawer。错误实现是构建两份 Inspector 或运行时把同一个 Native Widget 从右栏搬到 Drawer。现行实现改为：

```text
ResponsiveInspector（唯一 Native Host）
├─ content    ← 一次创建
└─ inspector  ← 一次创建

wide / inline
┌────────────────────────────┬──────────────┐
│ Content                    │ Inspector    │
│ min ≈ 360                  │ 286 default  │
└────────────────────────────┴──────────────┘

compact / drawer closed
┌───────────────────────────────────────────┐
│ Content                                   │
└───────────────────────────────────────────┘

compact / drawer open
┌──────────────────────────────┬────────────┐
│ Content                      │ Inspector  │
│ 保留至少 drawerMinReveal      │ overlay    │
└──────────────────────────────┴────────────┘
```

切换只修改 `Layout + Visibility + Raise`，不做：

- Native Reparent；
- Inspector 重建；
- 第二份 Binding / Draft State；
- 第二份 Scroll / Selection；
- Feature Store 镜像。

默认 breakpoint 读取 Workspace token（regular≈980），同时检查 `contentMinWidth + gap + inspectorMinWidth`，所以即使窗口宽于 breakpoint，但实际不足以容纳两栏，也会安全切 Drawer。

`WorkspaceTemplates v2` 已提供 `CreateResponsiveInspectorWorkspace()`，未来 Buff Display / Range Assist / Unit Lines / Diagnostics 等页面不得自己手写第二套宽窄屏 Inspector。

### SearchablePicker v1：显式提交 + PickerModel 单 Authority

大量选项选择现在形成完整两层：

```text
PickerModel v1
  stable key / query / bounded results / selection
                 ↓
SearchablePicker v1
  TextInput + Search/Clear + StatusChip + virtual ListView
```

首版交互严格基于当前 RU 已验证输入能力：

```text
输入关键词
   ↓
Enter / EditEnter 或点击“搜索”
   ↓
PickerModel:SetQuery()
   ↓
Virtual ListView diff/复用结果行
   ↓
选择 row.key
```

明确**不实现**未经验证的 `OnTextChanged` 实时搜索、通用 `OnKeyDown` 上下选择、Esc 关闭等桌面行为。未来获得 RU evidence 后，再升级 Input Contract；页面不得绕过 Foundation 自己猜事件。

SearchablePicker 本身不拥有业务名称解析或元数据：Buff / Skill / Item / Region 等 Caller 只通过 `getKey/getText/getSearchText` 提供 Projection。查询/结果/选择身份仍由 PickerModel 唯一拥有。

### IconPicker v1：PickerModel + Virtual TileView + Preview

IconPicker 也已经在本轮下沉，但只负责**通用图标选择 Presentation**：

```text
Caller Projection
 key / text / searchText / iconPath
             ↓
        PickerModel
             ↓
┌──────────────────────────────────┐
│ Search / Clear / Status          │
├──────────────────────────────────┤
│ Virtual TileView                 │
│ [icon] [icon] [icon] [icon]      │
│ [name] [name] [name] [name]      │
│ ... only viewport pool ...       │
├──────────────────────────────────┤
│ [selected icon]  Selected Name   │
└──────────────────────────────────┘
```

Foundation 不知道“这是 Buff、Skill 还是 Item”。业务 Caller 通过 `getIcon()` 或 item 的 `icon/iconPath/texture/path` 提供已经解析好的图标路径。这样 SkillMetadataV3/BuffMetadataV3 仍是元数据 Authority，IconPicker 不会在 Tile bind 热路径里调用 Native 元数据查询。

Tile 使用 `TileView` 的有界 pool/overscan；搜索仍为显式提交。默认 tile 约 68×76、图标约 44px，标签 ellipsis；`showLabels=false` 可用于纯图标密集模式。选中项底部预览只更新当前 selected key，不建立第二份 SelectionModel。真实 RU 图标渲染层级仍需 Fresh Reload 验证。

### `.18.67` 最新基线覆盖回流修复

用户提供的最新整包重新读取后，发现 `.18.63` 的一组旧文件在多轮覆盖中回流：`UI.ComponentsV2` 又进入 TOC、PopupCoordinator/Dropdown fail-closed/UITokens v4 局部回退，而 `.18.64~.18.66` 新层仍然存在。当前已按真实调用链恢复自洽基线，而不是拿旧整包覆盖新工程：

- 再次物理移除 `rs_ui_components_v2.lua` 并删除 Active TOC / metrics hooks；
- 恢复 `ContainerSurface`、Dropdown degraded fail-closed、单一 PopupCoordinator 与 tokenized popup priority；
- Foundation Audit 新增 **disk Lua ↔ Active TOC 双向 fence**：磁盘上存在但 TOC 未加载的 `.lua` 也直接 FAIL，避免历史源码“躺在目录里等待以后复活”。

该修复不改变任何 Feature Store/业务行为，只修复 Foundation 自身版本分叉。

### 当前下一批 Foundation 依赖顺序

```text
Host/Slot/Reparent Contract                 ✅
ResponsiveInspector Stable Host             ✅
SearchablePicker / IconPicker               ✅
Coordinate / Pointer / RectTransform v2      ✅
Selection Geometry / Overlay / Guides        ✅
LayoutEditor Gesture Transaction             ✅
              ↓
Anchor / Pivot / Grid Config Model
              ↓
LayoutEditorOverlay（组合现有底层，不再造 Authority）
              ↓
Editor Workspace Template / Inspector binding
              ↓
状态显示页面 UI_REVIEW
```

下一轮仍优先检查 Foundation；除非用户明确切换阶段，不应先回到 Healer/Gear/Buff 等业务页面实现。

## 6. 仍待 RU Fresh Reload 的最高优先级验收

### P0 — .18.61 Runtime Recovery

Fresh Reload 后优先验证本轮四项用户回归：

1. Gear：非战斗整套换装；战斗中主手/副手/远程/乐器优先切换；脱战后补齐防具/饰品/称号；同名多件与背包超过 150 格场景。
2. Unit Lines：1024×768 与 1920×1080 下四类开关、公共设置和四张每线外观卡片无重叠/裁切；颜色弹层可用。
3. Range Assist：颜色按钮显示 HEX、RGB/HEX 修改即时生效，Reload 后颜色保持；半径圆中心与 UI Scale 无漂移。
4. Bonds：大陆/原大陆居民板能够读出真实 `contents`，空地区显示“无内容”而非“API 不可用”，材料/数量/任务完成状态继续正确。

### P0 — Healer Raid Panel Model

完整 Reload 后重点验证：

1. `auto / single / dual` 三模式；
2. Panel A/B 团队绑定切换不重新校准几何；
3. 1 团 / 2 团 / 仅单团 / 双列表显示时成员落位正确；
4. 50 / 100 人色块、槽位号、`showMyself`、`locate_self`；
5. 校准矩形拖动/缩放与真实名单对齐；
6. 保存、Reload、旧 schema→新 panels 模型迁移回读；
7. 事件驱动刷新下的 100 人性能与资源释放。

### P0 — Buff Display

验证：

- 状态追踪行 Toggle、关键词搜索、“只看隐藏”；
- 头顶 Buff/Debuff/距离/职业/装分/装备/施法条等组件；
- 10 组件位置/大小/字号/透明度持久化；
- player / target anchor 与 icon/time；
- 导入导出和快速 ID 合并/覆盖；
- Consumer=0 后 Aura Demand、事件与 Scheduler 任务释放。

### P0 — V3 Foundation / Presentation

依次打开 Home / Healer / DeathReview / CombatAnalytics / Tasks / DPS / Activity / Gear / Instance / RaidReadiness / BuffDisplay 与对应 Floating Widget，确认：

- 页面/悬浮窗可构建、可关闭、可重新打开；
- `activeBuildScopes=0`；
- Page / Widget quarantine = 0；
- Table/DataView 无 nil；
- `v3_authority_clean` 无 violation；
- 拖动、缩放、滚动、Tooltip、ColorField、NumericSetting 在真实 Native UI 下行为正确。

## 7. 当前 Runtime Blocker 原则

任何 Runtime Blocked 能力只有在获得以下证据之一后才能解除：

- 当前 RU 客户端实测 API 参数与返回结构；
- 官方当前版本 Addon API 文档；
- 可复现的 Native 事件/字段样本；
- 明确权限 / cooldown / 场景契约。

禁止：

- 根据旧版 Legacy 能力推测当前 API；
- 根据字段名、ID 连号或社区描述猜参数；
- 用当前挂单冒充历史成交；
- 用聊天文本猜 Boss 机制；
- 用“最近/唯一候选”猜技能代理 owner；
- 为了 UI 看起来完整创建不可执行空壳。

## 8. 风险与未决

- RU 客户端缺少项目已验证的通用 `DestroyWidget` 能力；Release 仍采用解绑、隐藏、Lua 引用释放与 Generation 隔离策略。
- 工程目标是 Lua 5.1；其它 Lua 版本的 `luac -p` 只能作为语法辅助门禁，不能替代 RU Lua 运行时。
- Activities / Tasks 等仍有 Demand-scoped 周期采样；是否进一步事件化应先补齐 rows/sec、facts/sec、Native calls/sec 等 Diagnostics，再以实测决定，不能仅凭感觉重构。
- 历史独立 Addon 的持久化命名空间能否被 Suite 自动读取仍需 RU 实机确认；不得把历史旧源码重新接回 Runtime 来解决迁移问题。

## 9. 下一开发顺序

当前用户已明确把阶段目标调整为“先完善强大的底层框架，再逐页 UI_APPROVED，再做业务功能”。`.18.74` 已经把完整 LayoutEditor Workspace 组合出来，因此当前顺序更新为：

1. 新增共享 `LayoutEditHistoryModel / Undo-Redo`：只记录成功 Commit 的可逆 Layout Command，不记录 Drag Pulse；需要 stable selection/key、bounded history、transaction rollback；
2. 新增 `Editor Command Bar`：Undo / Redo / Revert / Reset / Apply 的状态与可用性由 History/Session Authority 投影，不让页面自己维护按钮状态；
3. 定义 `Reset / Revert / Apply` 三种语义及 Persistence 边界，避免“恢复默认”“撤销本次编辑”“保存当前布局”互相混淆；
4. 将 History/Command 能力接回 `LayoutEditorWorkspace`，仍保持 PreviewHost/Overlay/Inspector 单实例结构；
5. 把新增 Foundation 继续写回 `REBUILD_REFERENCE_ADDON_CAPABILITY_ROADMAP.md`，不新拆一套 UI 文档；
6. Foundation 稳定后，从状态显示开始把 `UI_DRAFT → UI_REVIEW → UI_APPROVED`；只有 UI_APPROVED 且 Authority/Service/Projection/Performance Contract 完整后，才进入业务页面重构；
7. RU Fresh Reload 仍是 Native 输入、Z-order、Handle hit、Focus、Icon Drawable、Selection Overlay、100 人等事实的最终验证边界。

当前明确不做：Buff Display / Healer / Gear / Unit Lines / Range / DPS 等业务 Feature 的 UI 迁移。


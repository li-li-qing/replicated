# Replicated Suite 重建进度（唯一当前状态）

> **Authority: CURRENT**  
> 本文只保存“现在完成到哪里、现在还缺什么、下一步做什么”。逐版本实现过程见 [`CHANGELOG.md`](CHANGELOG.md)，历史阶段交接与验证记录见 `Archive/`。

## 1. 当前基线

| 项 | 当前状态 |
|---|---|
| Architecture | V3-only / `v3_rebuild` |
| Runtime Addon | `replicatedsuite/` |
| Legacy / Professional / `globals/` | 已物理删除，Active dependency = 0 |
| BuildTag | `v3-m1.16.0.18.145-numeric-apply-adaptive-point-size` |
| Active TOC Lua | 222 |
| Active / All Lua | 222 / 222 |
| Foundation Audit | PASS |
| Python Harness | 35 / 35 PASS |
| Product Capability Matrix | 126 条：80 IMPLEMENTED / 35 PARTIAL / 0 TODO / 11 SPECIFIC_RUNTIME_BLOCKED |
| RU Fresh Reload | PENDING |
| Current UI Gate | **Fresh Reload/真实回归仍为 P0**：`.18.145` 首先验证范围辅助“点大小 2..10 → 输入 15 → 点应用 → Authority 15 / Slider 2..15 / 实际圆点明显变大”，并抽查其它 Compact Numeric 的“应用”按钮在窄布局下无重叠；`.18.144` 已由实机确认 TableView 拖列通过且 EditBox 不再卡游戏输入，继续保留焦点回归。`.18.143` Hover Fence、`.18.141` Range 锚点与此前换装/Healer/Trade/Bonds/Boss 回归继续保留。当前本地 35/35 Harness PASS 不替代 RU 证据。 |

`.18.112` 已把本轮两个表面回归收敛到底层 Interaction Lifecycle：主菜单拖动不再依赖调用者恰好把 Border 创建成 pickable，Windowing 在建立 Drag Gesture 前自己验证 hit-test surface；所有 Suite EditBox/MultiEditBox 进入 tracked physical-focus 生命周期，隐藏/禁用/释放/Runtime Stop/hot reload 都只对可证明属于 Suite 的输入对象清理 Focus。`.18.110` 的 Recovery Reload 与 Persistence 保存解耦继续保留：保存失败只保留证据并警告潜在未保存数据丢失，不阻断覆盖修复文件后的 recovery reload；strict durability 模式仍可 fail-closed.

当前 Foundation 结构指标：

```text
toc=222
activeLua=222
allLua=222
globals=0
presentation=0
rawNative=0
rawScope=0
detachedWidgetState=0
apiDependency=0
apiCapability=0
businessIds=0
serviceUpward=0
productTruth=0
auctionEventOwners=0
retiredUiLayer=0
rsuiComponentApi=1
presentationFeatureApi=1
rsuiLoadDeps=2
presentationRootHandlers=0
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
- RSUI Composite Foundation v5：`StatusChip` + `PickerModel` + `SearchablePicker` + `IconPicker` + transactional/stable/bounded `TreeModel` + virtualized `TreeView`；
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
- WorkspaceTemplates v6 / LayoutEditorWorkspace v4：在原 `PreviewHost + LayoutEditorOverlay + SAME TransformInspector` 稳定宿主上接入 Workspace-owned History、可选完整 LayoutEditSession 与 EditorCommandBar；构建边界新增 Component Public API fence，Compact Toggle 统一走 `SetVisible`；Toolbar 继续明示 `左上(0,0) · X→右 · Y→下`。Compact 模式新增稳定 `[属性]` Drawer 入口，仍只显示同一个 Inspector、不 reparent/复制状态；History replay 只从 Adapter 刷 Presentation，Reset/Revert 只在显式 Session 命令边界重新读取 Feature Working。
- LayoutEditHistoryModel v1 + Observable Contract v1：stable-key 可逆命令只在成功 Commit 后记录；Preview/Drag Pulse 不入历史；默认 64 / hard cap 256；Undo/Redo 外部 apply 被拒绝时 cursor 不移动并执行 best-effort rollback；Anchor/Pivot 使用最小完整状态快照而非仅 Rect；成功 Record/Undo/Redo/Clear 通过 Subscribe/Unsubscribe 事件通知消费者，不新增轮询。
- LayoutEditSessionModel v1：统一四态 `Persisted / SessionBaseline / Working / Defaults`。`Revert` 只把 Working 恢复到 SessionBaseline；`Reset` 只把 Defaults 暂存到 Working；二者都禁止跨越 Persistence Boundary。只有 `Apply` 可以调用 caller 提供的 durable persistence callback，明确成功后才推进 Persisted/SessionBaseline；History 在 Revert/Reset/Apply 成功时形成 barrier，避免 Undo 跨语义基线。
- EditorCommandBar v2：五个编辑命令只消费 History/Session Authority Projection；Undo/Redo 来自 History Snapshot，Revert/Reset/Apply 来自 LayoutEditSession；Busy 或 Session integrity blocked 时五个命令统一 fail-closed。Command Bar 不保存 dirty/canUndo/canApply 第二份状态，也不直接写 Persistence。
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
- **Buff Display**：`.18.124` 将自身主手/副手/远程装备读取收敛到共享 `GearV3`，HUD Layout 增加四个显式装备开关；背部继续只使用运行时 `ES_BACKPACK`，不猜 slot。`.18.80` 已把兼容四页签收敛为 `追踪管理 / HUD 布局 / 导入导出` 三页签；Tracking 使用单虚拟 Table。`.18.89` 根据 RU 实机反馈把 HUD Layout 接到共享 `Element Tree + LayoutEditorWorkspace + LayoutEditSession`；`.18.90` 将共享 Workspace 升到 v4 并补 Component API 构建门禁：Compact 模式恢复 `[属性]` Drawer 与 X/Y/宽高等 TransformInspector 参数；RSUI Interactive Draft v1 阻止环境刷新覆盖正在拖动的 Slider Preview / focused Edit 草稿，Aura 更新不再重绘 Layout 页。Working/Undo/Redo/Reset/Revert 不进入 Persistence getter，只有 Apply 才执行 durable layout write。StatusClassificationV3 仍是唯一分类 Authority。RU Native 拖拽、精确输入与真实 SaveData 回读仍需 Fresh Reload。
- **Raid Readiness / Boss Alerts / Team Tools**：安全子集已实现；未验证能力继续保持 Partial / Runtime Blocked，不使用猜测字段或禁止 API 补齐表面功能。
- **Unit Lines / Range Assist**：`.18.126` 修复 Range Assist 的 local/global 世界坐标混用，并把 `ScreenProjectionV3` 升到 v7：`ProjectWorldBatch` 对每个输入索引返回 visible/sentinel，Range 显式按原始索引消费，behind-camera 点不再因 Lua 稀疏数组截断后续圆弧。`.18.124` 根据 RU “只剩自身单点”的实机复现把 `ScreenProjectionV3` 升到 v6：同 batch 的不同 Unit Token 若 world fact 异常重合、但 Native screen point 明确分离，则启动 World Alias Guard，禁止 stale world 覆盖正确端点；无跨帧缓存或额外全局扫描。`.18.87` 根据 RU 真机反馈完成两层修复：①旧 `pointCount` 改为基础密度，屏幕空间长线自动补点并先裁剪 viewport 可见段；②多人/低帧压力下不再把整条 HighFrequency 刷新作为 P3 延后，而是 P1 保持连续 cadence，Presenter 本地 Diff 跳过未变化 Native 属性、点池渐进扩容，并只削减远距离额外补点。`.18.88` 修复“目标在相机背后却被 Native 投影成正 depth 边角点”；`.18.96` 根据新的 RU 战斗截图继续修复前方端点偏移：ScreenProjectionV3 v5 统一所有 unit world read 为 global (`isLocal=false`)，并在同一 batch 内以 camera-world logical 投影校验 Native screen point；UI-scale 候选明显更一致时做 scale reconcile，仍严重偏离时退回 camera consistency projection。该 gate 只在 Unit Lines batch 启用，不改变 Healer/Buff Display 普通 Unit projection。`.18.61` 的两列外观卡片与 Range Assist 永久颜色 Store contract 保持不变。

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

- `toc.g ↔ Active Lua`：210 ↔ 210，双向 0 差异；
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
- `RSUI_LAYOUT_EDIT_HISTORY_HARNESS PASS cursor=1 x=1`，验证 bounded history、Undo/Redo 与失败 apply 的 rollback/cursor fence；
- `RSUI_LAYOUT_EDITOR_HISTORY_ADAPTER_HARNESS PASS count=2 cursor=1 x=10 anchor=0`，验证 Preview/Cancel 不入历史、成功 Gesture Commit 入历史、Anchor/Pivot 可逆；
- `RSUI_LAYOUT_EDITOR_MULTI_HISTORY_HARNESS PASS cursor=1 a=10 b=210`，验证多选 Group Commit 的 stable-key Undo/Redo；
- `.18.76` 的 `v3_52_ui_editor_command_bar_contract` 继续验证 History observable、无 Session fail-closed、Session Projection 与 Busy/blocked fence；
- `.18.77` 新增 `v3_53_ui_layout_edit_session_contract`：验证 Reset/Revert 不持久化、Apply durable boundary、Persistence write fence、Apply 失败不推进 Baseline、成功 Apply 建立 History barrier，以及 `SessionBaseline ≠ Persisted` 的四态投影；
- `.18.78` 新增 `v3_54_ui_layout_editor_workspace_integration_contract`：验证 Workspace v2/v4 契约、完整/空 Session preflight 与 partial Session fail-closed；静态 Audit 同时验证 History→Adapter、Session→source refresh、Release 清理与 no-sampling/no-direct-persistence boundary；
- `.18.78` 非 Native Workspace 集成 harness：`LAYOUT_EDITOR_WORKSPACE_HARNESS PASS adapterRefresh=3 sourceRefresh=3 persist=1 historyOnly=true partialRejected=true`，真实加载 History/Session/WorkspaceTemplates，验证 Record→Session dirty、Undo→Adapter replay、Reset/Revert 零持久化、外部 source refresh→Session dirty、Apply 唯一持久化以及 root Release 清理；
- `LAYOUT_EDIT_SESSION_HARNESS PASS 2 30 1 2`；`LAYOUT_EDIT_SESSION_FOUR_STATE PASS 1 50`；`LAYOUT_EDIT_SESSION_FAILURE_HARNESS PASS 3 3 true`；
- 全量 Lua：210/210 Parse PASS；Foundation Audit PASS；Markdown 相对链接 0 断链；
- `RSUI_CONTAINER_SURFACE_HARNESS PASS created=7`，旧 `_card/_section` Native identity 保持；
- `RSUI_POPUP_COORDINATOR_HARNESS PASS closed=b`，单 registry / CloseAll(except) / unregister snapshot 正常；
- Product Matrix 统计可解析为 77 / 35 / 2 / 11，共 125 条；
- `.18.83` `PERSISTENCE_RUNTIME_ACCEPTANCE_HARNESS PASS`：失败 Flush 保留 exact `v3.test:injected_save_failure`，成功 Flush 清空失败列表；Reload 入口静态契约确认诊断页不再预 Flush；
- `.18.84` `PERSISTENCE_ACCEPTANCE_SNAPSHOT_HARNESS PASS 14/14`：Domain 指纹对 table 插入顺序稳定、字段变化会改变指纹、cyclic/unsupported payload fail-closed、未加载 Store 不生成伪指纹、exact missing 与动态 prefix coverage 可见；
- `.18.86` `BAG_MOVE_QUEUE_V5_HARNESS PASS 4/4`：覆盖 quick 同类槽位压缩、mixed itemType 动态解析、category + blacklist 动态解析、真实写失败保持 fail-closed；Foundation Audit 同步禁止把 serial plan 回退为 transient slot queue。
- `.18.87` `UNIT_LINE_SAMPLING_HARNESS PASS 11/11`：直接用 texlua 加载真实 `rs_v3_combat_visual_guides.lua`，除近/远距离、自适应预算和 viewport 裁剪外，新增验证 Critical 压力只削减 adaptive extra、不低于 persisted base density；Critical 点池单轮增长≤16、Normal≤48；稳定几何下一轮 `anchor/style/visibility writes=0`；线段移动时仅 Anchor 变化、Style/Visibility 保持 0。Foundation Audit 同时禁止 Unit Line HighFrequency task 回退 P3。
- `.18.96` `SCREEN_PROJECTION_FRONT_HEMISPHERE_HARNESS PASS 14/14`：真实加载 `rs_screen_projection_v3.lua`，模拟 RU 对背后目标仍返回正 depth + 边角屏幕点以及“in-bounds 但处于 physical/UI-scale 或 stale”的 Native 点；验证 Camera Frame 每 batch 只读取一次、token 去重、所有 world read 均为 global、behind 在 Native screen read 前拒绝、UI-scale reconcile、严重偏移 camera fallback、前方出屏端点仍交给 Presenter clipping、旋转相机后原 behind 目标重新可见。
- `.18.89` `INTERACTIVE_DRAFT_HARNESS PASS 13/13`：真实加载 `rs_ui_controls.lua`，验证 focused Text/Numeric draft 在 ambient refresh 中保持、失焦后可重新同步；Slider active preview 不被旧 Binding 回灌，final commit 可明确覆盖；`.18.90` 再增加 `RSUI_WORKSPACE_SMOKE_HARNESS` 与 `PERSISTENCE_ACCEPTANCE_SNAPSHOT_HARNESS`；`.18.91` 将 Workspace Smoke 扩至全部 6 类公共模板并新增全 Presentation Component API + RSUI TOC dependency-order 静态 Gate；`.18.92` 新增 Presentation→Feature API Audit 与 5/5 self-test，并修复 Tasks/Activities/Gear 三条真实缺失 Command。
- `.18.94` Fresh Reload preflight：Foundation Audit 新增 DPS schema/`widgetVisible`/WidgetHost lifecycle 一致性以及 Trade Dropdown-only/Quote/Server route Authority package-coherence；UIV3 Acceptance v58 同步增加 `dps_widget_visibility_preference_contract` 与 `trade_dropdown_quote_preflight_contract`。本地回归：Workspace 27/27、Presentation→Feature 5/5、Persistence 19/19、Interactive Draft 13/13、Bag 4/4、Unit Lines 11/11、Front-Hemisphere 10/10。
- 当前 BuildTag 与 `replicatedsuite.lua` 一致：`v3-m1.16.0.18.145-numeric-apply-adaptive-point-size`。

历史专项 harness、每个 M1.x 的逐轮数字与修复详情不再复制到本文，统一查 [`CHANGELOG.md`](CHANGELOG.md)。

## 5.1 当前 UI Foundation 先行状态

`.18.79` 已由用户“按照文档继续”确认状态显示 UI_REVIEW 的产品方向，状态正式进入 **UI_APPROVED**。本轮先执行文档规定的实现前 Authority Cleanup：统一装备左右分组与 Acceptance、Fresh Default 的 ranged=OFF、移除 `headIconSize/headMaxIcons` 双重 live Authority、把 Layout Reset 收窄为仅 HUD 布局并保留 tracked/classification，同时修复完整导入仍截断 32 个追踪 ID 与组件专属字段无法完整 round-trip 的兼容问题。Store 继续保持 schema 4；三页签 + `LayoutEditorWorkspace v2` 的完整页面迁移进入下一步 `UI_IMPLEMENTING`。

`.18.80` 已完成该 `UI_IMPLEMENTING` 的本地代码接入，并同步把用户最新反馈的 Persistence 数据丢失问题提升为 P0 Foundation：页面构造前确保 Buff Display Store 已读取；HUD Layout 使用隔离 Working Snapshot，只有 `Apply` 跨 durable boundary；底层 Persistence Reliability v1 负责 Load-before-Write、dirty reload fence、失败重试、损坏 payload 保护和 Reload durability barrier。当前 UI 仍保持 `UI_IMPLEMENTING` 而非宣告最终完成，因为 RU Fresh Reload 尚未验证真实 SaveData/Native 行为。

`.18.81` 根据 RU 实机失败日志完成针对性热修：`rs_v3_buff_display_page.lua:273` 的 `TreeView=nil` 根因是 Composite Foundation 在 `ListView/Controls` 之前加载并 fail-closed return，已修正 TOC 顺序并加入静态顺序 Gate；页面同时增加 Selection/Tree 依赖显式 preflight，避免再以 nil method 形式污染 Build Transaction。`UITokens` Gate 未绑定 Authority 与 `StatusClassificationV3` 缺 `service_only` 声明也已修正。Persistence Reliability 提升到 v2：Domain budget 与框架编码 envelope budget 分离，避免合法配置因 `payload/__rsmeta` 外壳被误判超预算后进入 Write Fence；新增 `MutateStore()` 统一 `PrepareWrite → snapshot → mutate → MarkDirty/Save → rollback`，并已迁移 Buff Display、Healer、DPS、Combat Analytics、Raid Readiness、Tasks、Activities、Gear 关键 Quick HUD、Death Review 关键索引以及 Life/Business 的高风险命令路径。当前仍不把保存系统标记为“RU 已完成”，跨进程 SaveData/LoadData 回读必须以 Fresh Reload/重新登录验证为准。


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

### Foundation 依赖状态（非独立 ToDo）

本段只描述依赖是否已经具备，**不再维护第二份“下一批顺序”**；实际施工顺序统一看 §9.2。

```text
Host/Slot/Reparent Contract                  ✅
ResponsiveInspector Stable Host              ✅
SearchablePicker / IconPicker                ✅
Coordinate / Pointer / RectTransform v2       ✅
Selection Geometry / Overlay / Guides         ✅
LayoutEditor Gesture Transaction              ✅
Anchor / Pivot / Grid Config Model            ✅
LayoutEditorOverlay / PreviewAdapter          ✅
LayoutEditorWorkspace / Inspector binding     ✅
              ↓
LayoutEditHistory / Undo-Redo                 ✅ `.18.75`
              ↓
Editor Command Bar                            ✅ `.18.76`
              ↓
Reset / Revert / Apply Session Semantics      ✅ `.18.77`
              ↓
LayoutEditorWorkspace Integration             ✅ `.18.78`
              ↓
状态显示页面 UI_REVIEW
```

Foundation First 阶段仍有效；任何用户新回归、RU 验收结果或业务 backlog 的抢占规则统一由 §9 管理。

## 6. 仍待 RU Fresh Reload 的最高优先级验收

### P0 — `.18.100` Persistence v7 + Gear Critical Journal

当前第一优先级继续验证用户确认的真实回归：**方案名称 Reload 后仍在，但内部装备身份丢失/无法换装**。`.18.95` 建立 Gear Index + A/B verified payload journal；`.18.97` 加入跨进程 encoded integrity 与 fenced inactive bank self-heal；`.18.98` 加入 durability barrier/verified clear；`.18.99` 进一步封住 metadata-only 截断、decode 后 Domain 膨胀、durable mutation 假承诺与 Character scope 跨角色误写；`.18.100` 再禁止 pending durability Store 在 barrier 前被普通 LoadStore 用潜在旧磁盘值覆盖，并把 migration/reset dirty intent 延后到成功 Apply 后提交，同时抑制 terminal/fenced dirty Store 的 Tick 自动重试。Fresh Reload 必须按以下顺序验证：

1. 新建或选一套正常方案，`获取当前 → 保存方案`；保存当次不能出现 `readback_verify_failed`。
2. 立即换另一身装备，再执行该方案，确认当前进程可正确换回。
3. 执行插件 Reload 后再次执行该方案；名称、19 槽 managed 身份、称号与实际换装结果必须一致。
4. **完整退出客户端再进入**后重复第 3 步，作为真正跨进程证据。
5. 再次 `获取当前 → 保存方案` 形成第二个 revision，使 active bank 从 A/B 翻转；Reload 后必须仍能应用，新 active 异常时只允许回退上一 verified bank，不允许把空 payload 当成“已配置”。
6. 对已经在旧版本中损坏、只剩名称的方案：旧装备明细无法从名称自动恢复；用户明确选中它并执行一次 `获取当前 → 保存方案` 后，应可重建进入 A/B journal，之后 Reload 不再丢。
7. Foundation `persistence_reliability_v7` 中普通保存后可出现 `pending>0`；用户显式 Reload 前 `barrier` success/attempt 应增长并最终放行，Critical Gear 不应因此重复 readback；正常产品调用链不得在 pending barrier 前重新 Load 同一 Store。新进程要求 `integrityFail=0 / envelopeFail=0 / encodedLoadReject=0 / decodedReject=0 / verifyFail=0 / durableFail=0 / barrierFail=0 / clearVerifyFail=0 / scopeMismatch=0 / unverifiedReloadReject=0`。任何 `integrity_failed / envelope_integrity_failed / encoded_load_rejected / decoded_load_rejected / readback_verify_failed / barrier_verify_failed / scope_binding_* / Fence / FlushFail` 都必须保留 `store id + reason`，禁止清空配置规避。

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

## 9. 统一 ToDo Authority 与下一开发顺序

本节是 **Replicated Suite 唯一活动 ToDo / 当前施工队列 Authority**。其它文档只能提供能力库存、专项设计或历史证据，不能再维护第二套“下一步顺序”。

### 9.1 Authority 分工

| 文档 | 职责 | 是否决定当前施工顺序 |
|---|---|---|
| `CURRENT_REBUILD_STATUS.md` §9 | 当前施工队列、用户新反馈入口、阶段优先级、延期理由 | **是，唯一 Authority** |
| `Rebuild/PRODUCT_COMPLETION_MATRIX.md` | 126 项产品能力库存与完成状态 | 否，只提供 backlog 候选与证据 |
| `Rebuild/REBUILD_REFERENCE_ADDON_CAPABILITY_ROADMAP.md` | Foundation / UI / 参考能力方向 | 否 |
| `Archive/Handoff/*` | 历史交接、旧阶段记录 | 否 |

规则：

- 用户新反馈先进入本节，再判断属于 Foundation、RU 验收还是业务能力；
- `PARTIAL / TODO / SPECIFIC_RUNTIME_BLOCKED` **不等于立即开工**，必须服从当前阶段目标与依赖顺序；
- 业务能力状态仍只在 Product Matrix 中维护，避免 CURRENT 复制 125 行形成双 Authority；
- 临时 Handoff 中仍有效的事项必须收拢到这里后再归档，禁止长期留在 `Docs/Handoff/` 形成隐形待办。

### 9.2 当前阶段：Foundation First

当前用户已明确把阶段目标调整为“先完善强大的底层框架，再逐页 UI_APPROVED，再做业务功能”。`.18.78` 已把 History / Session / Command Bar 接回共享 LayoutEditorWorkspace，因此当前执行顺序为：

1. **已完成 `.18.75`**：共享 `LayoutEditHistoryModel / Undo-Redo` 只记录成功 Commit 的可逆 Layout Command，不记录 Drag Pulse；stable selection/key、bounded history、transaction rollback 已落地；
2. **已完成 `.18.76`**：`Editor Command Bar` 统一投影 Undo / Redo / Revert / Reset / Apply 可用性；History 增加事件订阅，页面不再需要 Tick 或自存 `canUndo/canRedo/dirty`；Session 未接入时持久化类命令 fail-closed；
3. **已完成 `.18.77`**：`LayoutEditSessionModel` 定义 `Persisted / SessionBaseline / Working / Defaults` 四态；`Reset` 仅暂存 Defaults、`Revert` 仅回到 SessionBaseline、二者绝不写 Store；只有 `Apply` 在 durable persistence callback 明确成功后推进 Persisted/Baseline，并建立 History barrier；
4. **已完成 `.18.78`**：History / LayoutEditSession / EditorCommandBar 已接回 `LayoutEditorWorkspace v2`；Workspace 自建有界 History，完整 `editSession` callback 才创建 Session，partial contract 创建前拒绝；History replay 从 Adapter 刷新 Overlay/Inspector，Reset/Revert 从 Feature Working 显式回读；root Release 同步释放 Session/History listener；
5. **已完成 `.18.78`**：新增 Workspace Integration 已回写 `REBUILD_REFERENCE_ADDON_CAPABILITY_ROADMAP.md` 与 RSUI/CURRENT Architecture，不新拆第二套 UI 文档；
6. **已完成 UI_REVIEW（2026-09-03）**：状态显示真实代码已逐项审查；Review 收敛为 `追踪管理 / HUD 布局 / 导入导出` 三个用户任务，HUD 布局指定 `Element Tree + LayoutEditorWorkspace v2`，player/target 共用一套几何模板，原生血条只作不可见对齐基准；同时记录现有 Runtime/Acceptance 装备分组分叉、重复设置 Authority 与 Reset 作用域冲突；
7. **已完成 `.18.79` — UI_APPROVED + Authority Cleanup**：用户已允许按 Review 继续；确认三页签、player/target 共用单一几何模板、主手+副手在左/背部在右、Layout Reset 不清追踪。远程采用保守产品默认：Fresh Default `OFF`，启用时归左侧外层且不挤占主/副手靠血条位置。Runtime/Acceptance 已统一；`headIconSize/headMaxIcons` 只保留旧存档/旧导入兼容映射，不再作为 live writable Authority；完整导入上限与 Store 统一到 1024/category；Store schema 仍为 4。
8. **已完成 `.18.80` — Persistence Reliability v1 + Buff Display UI_IMPLEMENTING**：用户补充“配置经常在下次进游戏/重载后丢失”后，Persistence 提升为 P0 Foundation 事项。Runtime Stop 改为 Feature teardown 前 durability barrier；Persistent Store 强制 Load-before-Write；dirty Store 禁止普通 reload；SaveData 临时失败保留 dirty 并进入有界重试；非空损坏 payload 不再按空存档处理；显式 ReloadCodeFromDisk 必须 Flush 全成功才允许继续；Persistent Binding 在 Domain mutation 前 PrepareWrite，并在 MarkDirty 失败时 best-effort rollback。状态显示同轮完成三页签、单虚拟 Tracking Table 与 `LayoutEditorWorkspace v2 + LayoutEditSession` 接入，未 Apply 的 HUD Working 不进入 Store getter。
9. **已完成 `.18.81` — RU Hotfix + Persistence Reliability v2 Foundation**：修复 Buff Display `TreeView=nil` 的真实 TOC dependency-order 根因、UITokens Gate 与 StatusClassification boundary；Persistence 增加 Domain/Envelope 双预算与 `MutateStore()` 原子业务 mutation 契约，并迁移一批高风险保存路径。故障注入验证合法 Domain 不再被框架 envelope 误拒绝，冷 Store mutation 必须先回读磁盘，durable SaveData 失败会恢复 Domain/dirty metadata。
10. **已完成 `.18.82` — Persistence mutation 收口 + §9.3 本地回归修复**：剩余 mutation→MarkDirty 路径（FeatureRuntime 偏好、Trade 起点、Fishing ArmAuto）收敛到 `MutateStore`；Bag 整理/快捷取放前置失败可见化（feature 侧写 stopped+error，页面写状态文本，`SafeHandler` 绑定失败进 Diagnostics）；Trade 金银铜格式、可售地区会话缓存、`QuoteMaterial` 显式接入 PriceQuoteQueueV3 与"材料询价"按钮；Auction 报价快照进 projection + `v3.price_quote.completed` 自动刷新 + "结果询价"按钮 + 删除收藏两击确认。新增 `PERSISTENCE_V2_MIGRATION_TEST`（20/20）、`BUSINESS_BRIDGE_BAG_TRADE_TEST`（9/9）、`RSUI_COMPOSITE_STATE_HARNESS`（24/24）与 `LAYOUT_EDIT_SESSION_MODEL_HARNESS`（24/24）harness。同轮完成 RSUI Composite 收尾：`ResolveStatusSemantic` 唯一状态语义 Authority、`StateNotice`（Empty/Loading/Error/Blocked 组合态）、`DetailHeader`（Breadcrumb+标题+StatusChip），Composite Foundation 升 v5。
11. **已完成 `.18.83` — Persistence Runtime Acceptance Diagnostics**：`Persistence:Flush()` 现在保存**最近一次**有界 runtime-only 结果（`ok/at/owner/failures`），只用于验收诊断，不成为 Store/dirty 第二 Authority；`Describe()` 暴露 `RuntimeAcceptanceDiagnosticsContractVersion=1 + lastFlush`。Foundation Gate v81 新增 runtime acceptance diagnostics contract，并在一键复制摘要中直接附带最多 3 条 `store id:reason`；最近故障也会保留 `context.store` 与 bounded `context.failures`。诊断页显示“最近存档落盘”具体失败项。与此同时删除诊断页重载按钮的额外预 `Flush()`，`ReloadCodeFromDisk()` 恢复为**唯一 Reload/Flush Authority**，避免一次点击双写/双失败计数及首个失败原因被吞。
12. **已完成 `.18.84` — Persistence Fresh Reload Fingerprint**：新增通用只读 `FingerprintPayload / BuildRuntimeAcceptanceSnapshot`，对 Domain `get()` save snapshot 做 budget-bound、key-order-independent 稳定指纹；不写 Store、不自动 Load、不读取 `__rsmeta` envelope，也不形成第二 Persistence Authority。诊断页新增独立第三行“输出存档验收”，覆盖 Buff Display、Healer、Gear Index、Activities、Tasks、DPS、Trade，并把当前已注册 `v3.gear.payload.*` 纳入总指纹；输出包含 `ALL + per-store fingerprint + loaded/dirty/fence/schema/revision`。Foundation Gate 升 v82 门禁 snapshot contract。
13. **已完成 `.18.85` — Buff Display Coordinate-Space RU Hotfix**：用户 Fresh Reload 首次实测命中 `layout_editor_overlay_coordinate_space_required`，BuildTransaction 正确回滚并隔离 `combat.buff_display`。真实根因是状态显示调用 `LayoutEditorWorkspace` 声明 `coordinateSpace="local"`，却遗漏契约要求的 `pointerToLocal`；共享 Overlay/Gesture 契约无误，禁止放宽。页面现显式把 viewport-logical Pointer 转为 live LayoutEditorOverlay-local 坐标：每次手势采样通过 Native editor root 的 `Layout:GetLogicalRect()` 读取当前 logical origin/extent，再映射到声明的 640×320 editor-local rect；不缓存 geometry，因此响应窗口移动、Responsive reflow、ScaleBox 与 UI Scale。Foundation Audit 增加该首个真实 Consumer 的 local-space regression fence。
14. **已完成 `.18.86` — Bag Dynamic Source Resolution RU Hotfix**：用户 RU 实测确认“存放/放同类每点一次只移动一个物品”。真实根因不是按钮或 Scheduler，而是 quick/category serial plan 把 `slot` 当成稳定身份：第一件成功移动后 ArcheAge 会压缩/重投影源容器，原槽位可能立即被另一件物品补位；旧 verifier 因此把成功移动误判成失败并停止，预计算的后续 slot 也随之失效。Bag Move Contract v5 现改为 `itemType/category stable intent → 每步执行前重新解析 live source slot → 250ms 单步 Action → post-write verification`。如果原槽为空/身份变化直接确认；若同类物品补到原槽，则只在这一歧义路径做 bounded source-population count，只有源数量没有减少才 fail-closed。Quick/Category 仍互斥，黑名单在真实 live row 上再次检查，窗口关闭/切换/Feature Disable 仍立即释放任务。
15. **已完成 `.18.87` — Unit Lines Adaptive Density + Crowd Smooth Refresh RU Hotfix**：用户 RU 实测先确认固定点数导致“近距离像连续线、远距离点稀到看不清，某些角度整段消失”，随后补充“人多时刷新一卡一卡”。`CombatVisualGuidesV3 v5` 先用 Liang-Barsky 裁剪 logical viewport 可见段，再按 240px 参考间距做自适应补点；单边 hard cap=160。进一步确认 HighFrequency task 被错误显式注册为 P3，FrameBudget 在拥挤/低帧压力下会不规则延后整次刷新；现改为 P1 连续视觉 cadence，并把负载控制收进 Presenter：Normal/Busy/Heavy/Critical 只按比例削减 adaptive extra（persisted base density 不降）、Native dot pool 每轮最多渐进增长 48/32/24/16、Presenter-local render cache 跳过 unchanged Extent/Color/Visible 以及同像素 Anchor。稳定线下一轮无冗余 per-dot Native 属性调用，移动线只更新 Anchor。不新增 Store/schema/Tick。
16. **已完成 `.18.88` — Unit Lines Front-Hemisphere Cull RU Hotfix**：RU 实测确认选中目标位于相机背后时，Native `GetUnitScreenPosition` 仍可能给出正 depth 且落在屏幕边角，`.18.87` 的 viewport clipping 因而把镜像端点错误裁成边角指向。ScreenProjectionV3 升至 v4，新增 `ProjectUnitBatch()`：每轮只捕获一次 Camera Frame，对启用关系所需 token 去重，先读取 world position 并计算 `dot(unit-camera, cameraForward)`；`forward<=epsilon` 直接返回 `behind_camera`，不再让该端点进入 Native screen projection/Presentation clipping。前方但真实出屏的端点仍使用 camera-world fallback 保留超屏坐标，继续由 `.18.87` Liang-Barsky 只绘可见段。无新 Tick/Store/schema。
17. **已完成 `.18.89` — RSUI Interactive Draft + Compact Layout Inspector RU Hotfix**：RU 实测确认状态显示 HUD 布局在 Compact 窗口下无法看到 Transform 参数，并且 Slider 拖动与 EditBox 输入会被环境刷新逐帧回灌旧 Binding。RSUI v43/API12.7 新增 Interactive Draft Contract v1：focused Text/Numeric draft 与 active Slider preview 拒绝 ambient Render 覆盖；NumericField v4 传播 binding/interaction/commit render source。WorkspaceTemplates v5 / LayoutEditorWorkspace v3 在稳定 Toolbar 补 `[属性]` Drawer 入口，状态显示进入 Layout 时 Compact 自动打开，并把 Aura 更新刷新限制在 Tracking 页；不新增页面级编辑状态、Tick、OnTextChanged 或第二 Inspector。
18. **已完成 `.18.90` — RSUI Component API + Package Coherence RU Hotfix**：用户第六次遇到“状态显示页面打不开”，本次真实堆栈为 `rs_ui_workspace_templates.lua:341 attempt to call method 'Show' (a nil value)`。根因是 `.18.89` 新增的 Inspector Toggle 为标准 `Button` Component，只保证共享 `SetVisible`，Workspace 却直接调用并不存在的 `Show()`；Lua 语法/旧静态 Gate 无法发现动态方法缺失。RSUI 升 v44/API12.8，新增 `ComponentApiContractVersion=1`：所有 Component Base 统一提供 `Show/Hide → SetVisible` 兼容 facade，`RequireComponentMethods()` 在 composite/workspace 构建边界显式验证必需方法；LayoutEditorWorkspace v4/WorkspaceTemplates v6 改用 `SetVisible` 并验证 ResponsiveInspector/Toggle/Status/Overlay/Inspector/CommandBar API。新增真实 Lua `RSUI_WORKSPACE_SMOKE_HARNESS`，其 Button mock **故意没有 Show()**，以确保这类回归在封包前失败。同轮诊断还确认 `.18.84` 的 Persistence Fingerprint 仅存在于 Gate/Docs、未进入用户当前完整工程；已恢复 `RuntimeAcceptanceSnapshotContractVersion/FingerprintPayload/BuildRuntimeAcceptanceSnapshot` 及“输出存档验收”诊断 UI，并加入 Audit + `PERSISTENCE_ACCEPTANCE_SNAPSHOT_HARNESS` 的 package-coherence fence，禁止以后出现“文档/Gate 已升级但运行时实现漏包”。
19. **已完成 `.18.91` — RSUI Prepackage Contract Audit**：继续按“第六次页面打不开”的故障类别扫描全部 `presentation/v3`，新增 `rs_rsui_component_api_audit.py`：按实际 Component Base 公共方法 + 已审类型公共 API 检查 29 个 Presentation 文件、501 个已识别构造、466 个方法调用，未知方法若无 `type(component.Method)=="function"` capability guard 会在封包前直接失败；当前扫描 **0 未保护 API 越界**。Workspace Smoke 不再只构造 LayoutEditor，而是实际构建 MasterDetail / InspectorWorkbench / ResponsiveInspector / LayoutEditor / SettingsWorkbench / CommandCenter 六类模板，升为 `27/27 PASS`。Foundation Audit 同时新增 RSUI 顶层 fail-closed 依赖的 **TOC provider-before-consumer** 门禁，锁住历史 `TreeView/ListView` 类加载顺序回归。检查中另发现 Unit Lines 与 Front-Hemisphere 两个专项 Harness 默认 `--root=replicatedsuite` 依赖调用目录，可能造成封包机从工程根运行时假失败/漏跑；已改为基于 `__file__` 的稳定工程根，工程根与父目录两种调用均通过。
20. **已完成 `.18.92` — Presentation→Feature API Contract Audit + Command Repair**：继续在不跳过 RU Gate 的前提下完成本地可证明的 Foundation 收口。新增 `rs_presentation_feature_api_audit.py`，从真实 Feature provider（含 split Feature、`S.Features.Name=LocalFeature` bundle 与 `NewFeature("id", spec)` business provider）提取 Public method/Commands，再扫描全部 `presentation/v3` 静态 Feature consumer；缺失方法若无显式 capability guard 则封包失败。首轮真实扫描直接抓出 3 个此前 Lua Parse/Component API Audit 都看不到的 Command 漏接：Tasks/Activities 浮窗调用 `Commands:SetWidgetWindowState` 但 Commands 未导出；Gear 快捷设置 Modal 调用 `Commands:ResetQuickSnapSettings` 但 Commands 未导出。三条已补齐并回写各自 Runtime Acceptance，Foundation Gate v88 增加 `v3_presentation_feature_api_contract` package-coherence 检查。新增 auditor self-test `5/5 PASS`；当前真实扫描 `providers=36/used=25/aliases=45/calls=353`，静态消费者 **0 缺失 API**。动态 `S.Features[expr]` 五处继续由现有 BusinessPages/矩阵 Acceptance 管理，不猜运行时 Feature 名。
21. **已完成 `.18.93` — DPS Visibility + Trade Dropdown/Quote RU Hotfix**：根据本轮 RU 实机反馈核查真实调用链。DPS 根因不是 Domain 自启，而是 `combat.dps` Widget lifecycle 的 `preference()` 永远返回 `true`；现将 `widgetVisible` 纳入 `v3.dps` schema 4，并把 Show/Hide/Native Close 与生命周期 auto-show 统一接到同一持久化偏好，旧 schema 无字段默认迁移为 hidden。Trade 删除主页面和 HUD 的四个起/终点循环按钮，改为两行 dropdown-only 路线布局；`RefreshZones()` 在 RU `GetProductionZoneGroups` 调用失败时也允许使用既有 sealed Zone 候选，避免地区 API 失败直接把下拉禁死，最终路线仍由服务器 `GetSpecialtyRatioBetween` 判定。`QuotePendingMaterials` 收敛页面/HUD 批量询价，HUD 补“材料询价”；同时修复材料成本累计初始状态/小计未累加、报价完成只发布 revision 却未重建行的问题。Presentation Feature API Audit 当前 `calls=358`、RSUI Component API Audit `calls=470`，均 PASS。
22. **已完成 `.18.94` — Trade/DPS Fresh Reload Preflight Contract**：没有越过 RU Gate 开新业务功能，而是把 `.18.93` 两条用户回归固定成封包一致性门禁。Foundation Audit 现在拒绝 DPS schema/`widgetVisible`/lifecycle preference 漂移，拒绝 Trade 四个循环按钮或 Presentation `CycleFrom/CycleTo` 回归，并要求 Dropdown/Quote、sealed candidate fallback、服务器 `GetSpecialtyRatioBetween` Authority 与报价后受影响行重建同时存在。UIV3 Acceptance v58 增加运行时只读 preflight，要求 `v3.dps` schema 4 与 WidgetHost preference==Feature visibility，同时要求 Trade public Commands/Projection/HUD consumer 契约完整；Native popup 本身仍只由 RU 实机点击证明。
23. **已完成 `.18.95` — Persistence Reliability v3 + Gear A/B Payload Journal**：针对“换装名称保留但内部装备 Reload 后不可用”的 RU 实机回归，Persistence 新增 Critical Store opt-in post-write readback verify：`SaveData=true` 后必须以同 key `LoadData` 并验证 metadata/decode/Domain fingerprint，验证过程不 Apply；失败不推进可靠 commit。Gear Index 升 schema 5 且自身启用 verify，Payload 升 schema 2 compact format，并使用 A/B bank：inactive bank 先写+验证，再提交 Index pointer/fingerprint，上一 verified bank 保留为 backup；configured 空壳/缺 name/缺 title effect id fail-closed。旧 `gear_payload_N` 继续只读兼容；已经物理丢失的旧 Payload 无法从名称恢复，但允许用户明确“获取当前→保存方案”重建。新增 Persistence Reliability v3 故障注入 `22/22 PASS`。
24. **已完成 `.18.96` — Unit Lines Coordinate Consistency + Team Auto-Role Ranged RU Hotfix**：用户新的战斗截图证明 `.18.88` 只解决 behind-camera 还不够。ScreenProjectionV3 v5 取消 player-only `isLocal=true`，所有 token world position 统一 global；在已有 camera frame/world read 上增加 Native↔camera logical consistency gate，优先纠正可证明的 UI-scale 空间差异，仍严重偏移时 camera fallback。普通 `ProjectUnit` 不变，影响面只锁在 Unit Lines batch。团队职责目录 v2 将用户报告的 `name_6_8_9`（吟游+暗杀+野性）及其它明确 `classType=Archer` 精确项改为 ranged，不做“含野性即 ranged”的模糊规则。
25. **已完成 `.18.97` — Persistence Reliability v4 Cross-Reload Integrity + Gear Journal Self-Heal**：继续检查真实保存链后确认 v3 immediate readback 不能证明下一进程磁盘完整性；`IsStoreLoaded()` 还会把 decode/meta/future-schema 等失败终态误报为业务 ready；Gear active bank 损坏回退 backup 后，损坏 inactive bank 的 write fence 会阻止下一次 journal 自愈。v4 对所有新 save envelope 持久化 encoded integrity stamp；健康 loaded 语义收紧；Gear A/B 支持严格的 verified replacement。新增 v4 fault injection `35/35 PASS`。
26. **已完成 `.18.98` — Persistence Reliability v5 Durability Barrier + Verified Clear**：继续审计发现普通 Store 一旦较早 SaveData 成功并变 clean，旧 Flush 在 Reload 时不会再检查该 key；同时 v4 integrity 源码顺序仍晚于 custom decode，ClearStore 只信 ClearData=true。v5 保持普通 Save 的单次 SaveData fast path，但用 runtime-only `needsBarrierVerify` 记录“本 generation 已触碰但尚未最终耐久证明”的 key；Flush 先存 dirty，再 bounded readback pending key，失败直接阻止 Reload并把健康 Domain requeue。Critical Store immediate verify 成功后不重复读取。Integrity v1 接受 v4/v5 stamp 且校验正式前移到 decode 前；ClearStore 必须物理回读 nil 才 Apply defaults；Core/UI 写路径统一健康 ready 语义。新增 v5 fault injection `42/42 PASS`。
27. **已完成 `.18.99` — Persistence Reliability v6 Envelope Seal + Durable Commit + Character Scope Binding**：继续审计 v5 后确认 `durable=true` 未真正强制 readback、business fingerprint 不覆盖 metadata、custom decoder/migration 可膨胀越过 Domain budget、Character Store 缺 loaded-scope identity binding。v6 新增 metadata Envelope Seal、decode/final Domain budget gate、真实 durable mutation readback+rollback、exact world-qualified identity fingerprint 与 bound-scope flush/debounce。旧 v4/v5 stamped save 继续可读；历史 physical Character key 算法不变，identity-only collision fail-closed。新增 v6 fault injection 覆盖 metadata truncation、decoded expansion、durable rollback、v5 compatibility、角色 A/B rebind 与 lossy-key collision。
28. **已完成 `.18.100` — Persistence Reliability v7 Generation Reload Fence + Deferred Dirty Commit**：继续审计 v6 后确认普通 Store SaveData 成功但尚未 barrier proof 时，业务若再次直接 LoadStore 仍可能把潜在旧物理值 Apply 到较新的健康 Domain；同时 migration/period-reset 在 Apply 成功前提交 dirty intent，Apply 失败可留下 terminal+dirty，Tick 随后重复自动 Save。v7 对 `needsBarrierVerify` 加普通 LoadStore fail-closed fence；migration/reset dirty 只在最终 budget + Apply 成功后提交；Tick 对 terminal/write-fenced dirty Store 只保留 evidence 并有界后移 dueAt，不再重复 Native Save。新增 v7 fault injection，v3-v7 全部继续通过。
29. **已完成 `.18.101` — Gear TextInput Native Interaction RU Hotfix**：RU 实机确认换装“新建方案/改名”输入框可绘制但鼠标无法取得编辑 Focus。共享 `CreateEditBox()` 补齐 Enable/Focus/Keyboard/Pick/Clickable/ReClickable/ReadOnly 契约，不在 Gear 页面维护第二套点击特例；TextInput/NumericInput 全部继承。
30. **已完成 `.18.102` — RSUI Native Interaction ABI + Fail-Closed Hardening**：基于 `.18.101` 同类故障继续扫描全部 Active Lua，发现 Slider/Scrollbar/Table resize/SplitView/Runtime Host 多处把 RU 单参数 `EnablePick/Clickable` 以双参数形式放在 `pcall` 中，可能静默形成“显示正常但无法交互”；已统一一参数 ABI并收敛到 UI Diff Authority。Multiline Edit 补齐完整 interaction flags；自定义 Slider 增加 composite enabled adapter，禁用会关闭真实 drag child 并终止临时交互；degraded primitive 改为注册 Native identity 后返回 nil，RSUI custom factory 再加 degraded/rejected/stale root fail-closed。Foundation Gate v93 新增 `v3_native_interaction_contract`，静态 Audit 增加参数个数/contract coherence 扫描，Interactive Draft Harness 扩展 42/42；同时修复 handler 首次绑定失败残留订阅、`WarnOnce` dot/colon ABI 与 Slider 必需 Drag handler fail-open。
31. **已完成 `.18.103` — RSUI State/Geometry Transaction + 全功能交互底层收敛**：继续检查所有 Active V3 页面/Widget 的 Native/Composite 状态发布顺序。`UI` 新增 `EnsureAlpha/EnsureAnchor/EnsureExtent`；Windowing v16、WindowShell v22、FloatingSurface v10、Dropdown/ColorField/Tooltip/ContextMenu/ModalHost、Scrollbar/SelectionOverlay 统一为“Native/Composite/Layout/State callback 成功后才发布 logical state”，失败回滚或 fail-closed。额外修复 WindowShell `NotifyState()` 过去用 `pcall` 吞掉业务 `false`、Windowing geometry callback 不传播拒绝、Application Shell 几何/最小化/锁定先写 State 后验证等事务断点。Activities/Tasks/Life/Buff/DeathReview/DPS/QuestDetail 的 `visible` 也不再先于 FloatingSurface 成功发布。本交付同时包含上一阶段尚未正式发出的 Binding Read-Before-Render、Persistent write rollback、Button Action Authority、WidgetHost preference load、DataView/SplitView/LayoutEditor critical interaction 等共享修复。Foundation Gate 升 v98，Interactive Draft Harness 104/104；最终 210/210 texluac Parse 与全套本地 Harness 通过。
32. **已完成 `.18.104` — RU Native Boolean Setter Return + V3 Startup Hotfix**：针对“Fresh Reload 后只剩 `R`、主界面打不开、ESC 插件项消失”的 P0 回归，确认 `.18.103` 把 Native Setter 的 `false` 返回统一当作拒绝，和 RU 可能“返回最终 bool 状态”的 ABI 语义冲突。主 V3 Root 初始化需要 `Pickable=false / Visible=false / CloseOnEscape=false / Modal=false`，因此在 Host 创建期被错误 fail-closed。UI Framework v10 现在只对白名单 false-state setter 把 false 当作状态值；true-state false return、Action false return、Lua Composite adapter false veto 仍保持 fail-closed。NativeAdapter Root Policy 升 v2；Foundation Gate 升 v99 并锁定 Native boolean setter/Interaction v4/Root Policy v2；Interactive Draft Harness 新增该真实启动形态与 Composite veto 回归，升为 110/110；Foundation Audit 增加对应 fence。
33. **已完成 `.18.105` — Runtime Entry Lifecycle + ESC/Recovery Hardening**：继续沿启动链检查，确认 `Runtime:Start()` 过去忽略 ESC 注册的业务 false，允许 `Ready=true` 与 ESC 项缺失并存；同时 `Ready=false` 的 R/Refresh 可以打开半初始化 Host。NativeEscBridge v2 改为 generation-local 幂等注册 Proxy，部分 content/button 注册失败可以只补偿未完成阶段；Runtime v4 记录 ESC 健康与尝试数，首次失败后只在共享 Scheduler 上做一次 750ms one-shot，R 主动点击还能低频机会性修复。bootstrap 删除 partial-shell reveal。继续追到 `rs_native_recovery.lua` 又修复 installer `pcall=true + returned false` 被静默吞掉的问题，并用 `RecoveryEntryHealthy/Error` 暴露 R 健康；Recovery 失败只告警，不 poison 完整 Runtime。Foundation Gate v100 与复制诊断现同时显示 `Ready/Runtime/R/ESC/尝试/重试`；专项真实 Lua Harness `20/20 PASS`。
34. **已完成 `.18.106` — Recovery Launcher Input + Compact Sizing**：RU 继续实测确认 `R` 仍点不动且尺寸过大。真实调用链显示 OnDragStop 无条件 `rsIgnoreClick=true` 会在 RU 普通点击也发 Drag 生命周期时永久吞掉 OnClick；同时 launcher placement 将屏幕入口再次乘 Suite content scale，且 bootstrap 未关闭 Native AutoResize。现改为起止位置差超过 2 才认定真实拖动，零位移不 suppress、不 snap、不写 Store；真实拖动只 suppress 一次 synthetic click。R 固定 30×30，并显式关闭 AutoResize/强制 Width/Height；LauncherStore 不再二次 scale。专项 `rs_recovery_launcher_harness.py` 15/15，Foundation Gate v101。
35. **已完成 `.18.107` — Startup Fault Isolation + Session-Safe Foundation Stores**：多轮自检确认默认 Feature 与启动关键 Store 仍可能反向阻断 Core：换装/活动/任务追踪任一默认 Feature 初始化失败会让 Runtime 整体失败；`v3.app/v3.shell/v3.launcher` 任何读取异常也会使主菜单不可达。现改为 Feature 故障记录 degradation 后继续 Ready；App/Shell/Launcher Store 失败使用会话默认值，原 Persistence load-failure write fence 不变，不主动覆盖旧数据。新增 Startup Fault Isolation harness 14/14；Gate v102，复制诊断增加 `/降级N`。
36. **已完成 `.18.108` — Bootstrap Recovery Command Bar**：用户因主菜单不可达需要每次重启客户端，新增独立于 R/ESC/Host/Feature Runtime 的 bootstrap `RS>` 输入栏。当前 RU API/客户端脚本没有可验证的插件 Slash 注册 Authority，因此不猜 `SlashCmdList`/聊天 Hook；只使用客户端已验证的 EditBox `OnEnterPressed`。Runtime 未 Ready/Stop/启动失败时显示，Ready 后隐藏。输入 `reload`（兼容 `/rsreload`/`rs reload`）统一走 `ReloadCodeFromDisk`；另有 `diag/open/help`。Gate v103，复制诊断新增 `/CMD`，Recovery Command harness 17/17。
37. **已完成 `.18.110` — Recovery Reload / Persistence Save Decoupling**：恢复重载仍 best-effort Flush，但单个 Store 保存/耐久验证失败只记录 store+reason 并提示未保存修改可能丢失，不再把加载覆盖后的修复文件锁死；显式 strict durability 与 Runtime Stop 的强耐久边界不降级。
38. **已完成 `.18.111` — Recovery Keyboard Isolation + Explicit Drag Condition**：bootstrap Recovery EditBox 默认 Focus/Keyboard 关闭，仅 Startup Failure 显式启用；Windowing/R launcher 补齐 `SetDragCondition(DC_ALWAYS)`。后续深审确认这属于必要防线但不能单独覆盖全局输入生命周期和 hit-test 参数丢失。
39. **已完成 `.18.112` — Input Lifecycle + Drag Hit-Test Foundation**：`Border` 恢复 `pickable/owner` 透传，Generic WindowShell title bar 显式 pickable；Windowing v18 在 Attach 时自己确保 drag handle `Enabled+Pickable` 后才 `EnableDrag/DC_ALWAYS`。UI Framework v11 对 Suite EditBox/MultiEditBox 建立 physical-id tracked focus lifecycle：hide/disable/pickfalse 在 cache early-return 前先释放所属 Suite focus，Owner/Component teardown 与 old-generation hot reload 永久 disarm，Runtime Ready/Stop quiesce；绝不对无法证明属于 Suite 的游戏输入执行 ClearFocus。专项静态 Contract Harness `48/48 PASS`。
40. **已完成 `.18.113` — Persistence Reliability v8 / Integrity v2 Serializer Recovery**：RU 实机出现 `death_review/healer/launcher fingerprint_mismatch` 后，确认旧 v1 exact number hash 会把 Native 非整数表示归一化误判为跨重载损坏。v8 保留 exact `FingerprintPayload` 给 Gear 等业务 fingerprint，只把 Persistence encoded/readback integrity 升为 serializer-stable non-integral token；v6/v7 普通设置在 envelope 完整时可一次兼容读取并在完整 decode/budget/apply 后 restamp v2，Critical/Journal 仍 fail-closed。App/Shell/Launcher session fallback 改为 memory-only mutation，杜绝保护性 load failure 后的 write-before-load 噪声。v8 harness PASS，Startup Fault Isolation `17/17`。
41. **NEXT — RU Fresh Reload + Persistence v8 / Input / Drag / Recovery Matrix**：使用 `.18.113` 累计修改文件启动**新进程**。第一步不要打开插件，直接验证 WASD/技能键/聊天输入；再打开主菜单拖标题栏、打开任一 Generic WindowShell 拖动/缩放；把焦点放进 TextInput/NumericInput 后切页、关闭主窗口、执行 hot reload，随后立即验证游戏键盘已归还。Modal backdrop 必须能点击命中。若主 Runtime 未 Ready，则用小型 `R/RS>` 取 `BootStage/R/CMD/BootError` 并验证保存失败时 `reload` 仍能加载新文件。之后再确认 `Readytrue/Runtimetrue/Rtrue/CMDtrue/ESCtrue` 与 Gear/Persistence 矩阵；正常保存路径继续要求 integrity/readback/durable/barrier/scope/unverified reload failures 为 0。任何“可见但点不动/键盘被吞/关闭后仍占输入”一律继续按 Foundation Regression 处理，不下沉业务页打特例。
**并行验收说明**：RU Fresh Reload 与 §9.3 业务回归并行：重点验证 SaveData 真实回读、连续 Slider/拖动后立即重载、Feature Disabled 状态编辑、HUD Apply/Reset/Revert，以及 Native 输入、Z-order、Handle hit、Focus、Icon Drawable、Selection Overlay、100 人等事实。

### 9.3 已收拢的用户遗留事项

以下事项原记录于 `Docs/Handoff/2026-09-03-pending-handoff.md`，现已进入 CURRENT Authority。它们**不会丢失**，但在 Foundation First 阶段暂不抢占 §9.2 的执行顺序。

`.18.82` 已在本地完成其中的三项本地可解决部分（实机复验仍属 §6 P0 验收）：

- **Bag 整理/存放 RU 回归**：`.18.82` 已修复“按钮静默失败”；`.18.86` 用户进一步实测确认按钮能执行但 serial plan 每次只移动 1 件。根因已收敛为 transient `slot` 被错误当作稳定身份；当前改为 stable `itemType/category` 意图 + 每步 live slot 解析 + 歧义时源数量下降验证，仍保留 250ms 限速、互斥、黑名单和关闭即停。
- **Trade 下拉/格式/材料入口**：`.18.93` 删除页面/HUD 四个循环按钮并改成 dropdown-only 两行布局；生产地区 API 失败也进入 sealed Zone candidate fallback，悬浮窗新增“材料询价”，页面与 HUD 共用 `QuotePendingMaterials`；报价完成会重建受影响材料成本/毛利。Trade route / 材料成本 / live ratio 在 Matrix 中仍保持 PARTIAL，等待 RU 数据回读。
- **Auction 收藏 UX + lowest-price projection**：报价快照进 projection、询价完成自动刷新、"结果询价"按钮、删除两击确认、结果行回填关键词已落地；interactive search 的 RU 结果语义仍为 PARTIAL。

| 队列项 | 当前归类 | 进入业务阶段后的动作 | Product Matrix 对应 |
|---|---|---|---|
| Gear 换装/称号“设置位置 UI”与高密度双栏体验 | UI_REVIEW 候选 | 先基于真实截图/实机布局确认问题，再从共享 Workspace/Inspector 能力改，不猜测重构 | Gear 多项能力已 IMPLEMENTED/PARTIAL；此项主要是 Presentation UX |
| Trade 下拉框不弹、按钮切换笨重、悬浮询价缺失 | `.18.93` 已做本地代码修复，待 RU Fresh Reload | 验证 popup 真展开、API-failure fallback、两行布局、HUD 询价异步回写；不得普通刷新隐式扇出 Auction Query | Trade route=PARTIAL；材料/成本=PARTIAL；current/full mode=TODO |
| Bag 整理按钮点击没反应 | Tools 业务回归 | 先验证 `OnClick → Feature Command → Consumer/Lifecycle → Action Result` 全链，修真实断点；保留批处理互斥与限速 | Bag 主能力已 IMPLEMENTED，native-window quick overlay=PARTIAL |
| Auction 收藏 UX | Tools/Market UI_REVIEW 候选 | 保留现有 Favorite Store Authority，优化选择/删除/分页/上下文，不复制第二份收藏状态 | favorite add/remove=IMPLEMENTED；paging/context=IMPLEMENTED；interactive search=PARTIAL |

#### 9.3.1 2026-09-05 RU 实机新增问题队列（用户当前基线 `.18.117`）

来源：用户在 ArcheRage RU 实机中对当前新版主菜单/悬浮窗进行连续操作后的截图与复现描述。**这些结果覆盖旧的“本地已修复/Matrix 已 IMPLEMENTED”乐观结论**：只要 RU 实机仍能复现，就重新进入当前队列，不允许用旧 Harness PASS 直接关闭问题。

执行原则：

- 先修共享 Foundation，再修业务页面；同一类问题跨 2 个以上 Consumer 复现时，禁止分别打页面特例；
- 参考旧项目只用于确认**产品行为、旧版交互和可复用算法**，不得把 Legacy/Professional 源码重新接回 Active Runtime；
- 主菜单页面与悬浮窗共享同一 Feature/Service Authority，不复制第二份业务状态；Presentation 可以组合，但 Feature 的 Demand / Consumer / Cache / 生命周期仍需独立；
- `SPECIFIC_RUNTIME_BLOCKED` 项继续保持 fail-closed，不能因为合并 UI 或参考旧项目就解除 Native/API Blocker；
- 每项完成后必须回写 Product Matrix 状态/证据，并进行 RU Fresh Reload；仅本地 Harness PASS 不算关闭。

| ID | 优先级 | 用户实机问题 | 当前代码/Authority 线索 | 目标方案 | 关闭条件 / RU 验收 |
|---|---|---|---|---|---|
| `RU-UI-01` | **P0 Foundation** | **共享下拉框无法展开**：跑商“起点/目的地”、制作规划、制作台助手均点击无弹层。三个独立 Consumer 同时失败，优先视为 Dropdown/Popup Foundation 回归，不按页面分别修。 | `RSUI:Dropdown` / PopupCoordinator / WindowShell hit-test 与 Z-order；消费者包括 `rs_v3_life_m16_pages.lua`、`rs_v3_life_economy_widgets.lua`、Craft Planner/Craft Assist 页面。 | 从 `Button action → popup create/show → parent/content-root → Pickable/Enabled → Raise/Z-order → outside-close` 全链审计并补共享 Harness；不得在 Trade/Craft 页面手工造第二套菜单。 | 主菜单跑商、跑商悬浮窗、制作规划、制作台助手 **4 处**下拉都能展开/选择/关闭；1024×768 与 1080p 不被裁剪；打开/关闭后 WASD 不被吞；切页/关闭窗口后 popup 不残留。 |
| `RU-UI-02` | **P0 Foundation** | **悬浮窗被主菜单压在后面**：用户点击“打开悬浮窗”实际已创建，但因为位于主菜单后方而误以为无效。 | `RSUI.FloatingSurface` + `rs_v3_widget_host.lua` + PageHost/Shell Window layer；属于跨 Feature 的共享窗口层级问题。 | 建立明确的 `Shell < FloatingSurface < Popup/Modal` 层级与 open-time `Raise` 契约；悬浮窗打开/重新显示时由 Host 统一提升，不让 Feature 自己控制 Native 层级。 | 主菜单保持打开时，从任意页面打开 Trade/Tasks/Bonds 等悬浮窗，窗口立即位于主菜单上方且可点击/拖动；关闭/重开/最小化恢复层级稳定；无全局输入锁。 |
| `RU-BAG-01` | **P0 业务回归** | **整理背包仍然每点一次只移动 1 个物品，且有时存在同类物品也不继续移动。** 这条实机结果重新打开 `.18.86` 曾宣称修复的问题。 | `tools_bag`、`InventorySnapshotV3`、Bag Move Queue v7、`rs_v3_bag_quick_overlay.lua`；Matrix 当前把 category batch/quick take-put 记为 IMPLEMENTED/PARTIAL，但 RU 证据优先。 | 重新追踪 `stable intent → live source slot resolve → native move → client slot compaction → post-write verify → next step`；增加真实“同类堆叠/槽位压缩/目标已有同类/目标容量临界/黑名单”诊断，不降低 250ms 串行限速，不改成 Tick。 | 单击一次“放同类/取同类/分类存放”能按设置上限持续执行直到完成/容量不足/明确失败；中途相同物品换槽仍继续；失败必须显示具体原因而不是静默停止。 |
| `RU-PERSIST-01` | **P0 Foundation** | **Fresh Reload 后 `v3.tasks` 触发 `fingerprint_mismatch:7776FEE0>2981E9D5`（`v3.death_review` 同类 4AEAFC3B>161B2763），导致 Feature Defaults 降级、Store Fence 与 Persistence Blocker。`.18.124` 的 strict shape-repair 实机被拒（STORE_INTEGRITY_SERIALIZER_REPAIR_REJECTED）——旧 stamp 属于旧代码形状，重建候选原理上无法逐字复现。** | Persistence Integrity v2 原始包封指纹对结构级表示漂移（map→sequence/空表丢失/版本形状漂移）本质脆弱。 | **Integrity v3 canonical**（2026-09-05，PERSISTENCE_ARCHITECTURE §0.11）：保存/加载两侧都按 `CanonicalIntegrityValue`（codec encode / migrate normalize）计算指纹，逻辑等价漂移被吸收；旧 v2 档在 Envelope Seal + decode + budget + schema 全链通过后默认按 `integrity_upgrade_recovery` 接受一代并立即重盖 v3（2026-09-05 第二份实机横幅证明漂移为序列化器普遍行为：bonds/gear.payload/record 分片同轮 mismatch，白名单不可扩展；journal 分片亦纳入，优于 replaceCorrupt 破坏性覆盖；Domain 可显式 `allowIntegrityUpgrade=false` 退出）。禁止清 Store、关闭 integrity 或无条件接受 mismatch。 | Fresh Reload 后：`v3Upgrade` 持续增长（本轮全部 v2 旧档分批升级）随后 `integrityFail=0`、`Fence=0`，任务/债券/装备方案/死亡回顾数据保留；第二次 Reload 起不再进入 upgrade recovery（`verified_canonical`）；诊断页 Store 行显示 `完整性 verified_canonical`。 |
| `RU-SVC-01` | **P0 Foundation** | **诊断 `service_presentation_boundary[invalid=AuctionSurfaceV3:missing,CraftSurfaceV3:missing]`。** | 两个 Surface 都是 Native Window 只读观察 Service，Sidecar 渲染在 Presentation；漏的是显式 `presentationBoundary` 声明。 | 两个 Service 统一声明 `service_only`；Acceptance + static audit 同时要求，避免仅靠通用运行时扫描到用户机器才发现。 | Fresh Reload 后 `service_presentation_boundary` 通过且 Auction/Craft Sidecar 行为不退化。 |
| `RU-LINE-01` | **P0 Combat** | **单位连线偶发失效：切换目标后只在自己身上留下一个点，且需要重载才能恢复。** | `.18.124` Alias Guard 已修主要坍缩，但实机仍复发：①alias 候选未确认时 camera consistency oracle / camera fallback 仍可把端点锚到玩家（`native+world` 双 alias 未覆盖）；②**Scheduler 熔断 3 连败即永久禁用且无自愈**（`rs_scheduler.lua` RunTask），才是"偶发永久失效"的真正载体。 | v6.1：alias 候选 native 屏幕证据成功即直接采信（`native_alias_candidate`），native 失败 fail-closed（`aliasNativeKept/aliasNativeRejects` 计数）；Scheduler 熔断改为指数退避自动恢复（2s→60s 封顶，`faultResumes` 指标）；read() 对端点 ≤1px 重合输出 ENDPOINT_COLLAPSED 拒绝。新增 `SCHEDULER_FAULT_RECOVERY_HARNESS`、投影 harness 增至 21/21（含 alias kept/reject 用例）。 | 连续快速切换目标/焦点/目标的目标不再塌成自身单点；注入 3 次回调异常后任务 2–4s 内自动恢复；诊断面 `UnitLines:` 单行可复制（enabled/consumer/rows/status/collapsed/aliasKept/aliasReject/lastFailure）。 |
| `RU-BUFF-EQUIP-01` | **P0 Combat/UX** | **状态显示没有显示自己的主手/副手/远程/背部；`.18.124` 收敛 GearV3 + 快捷开关后实机仍不显示。** | 静态链路（store 默认注入→lane 调度→ReadEquippedIcon→投影→渲染）逐层审计自洽，剩余未知只能实机回答：RU tooltip 的 icon 字段名、装备 lane 是否真正 tick、读取是否报错。 | 2026-09-05：装备 lane 全链诊断插桩（reads/icons/empty/errors/unresolvedSlots/iconField/lastError/sampleItemKeys），诊断面 `BuffGear:` 单行可复制；数据层升级路径由 `BUFF_EQUIPMENT_PROJECTION_HARNESS` 锁定（旧配置缺组件键→默认注入）。禁止在拿到实机证据前盲改字段名。 | 实机读取 `BuffGear:` 行：若 `errors>0` 按错误收敛 API 面；若 `itemKeys=...` 显示无已知 icon 字段则按真实字段名修复并升级 `EquipmentReadContractVersion`；`icons>0` 且开关开启后 Self HUD 显示已开启槽位。 |
| `RU-ACT-01` | **P1 复用/交互** | **活动悬浮窗点击任务不弹任务详情；主菜单活动页能显示详情，但详情依附主菜单子窗口，不利于悬浮窗复用。** | 工程已经同时存在 `QuestDetailFloatingV3` 与 `QuestDetailModalV3`；Activity Widget 已尝试调用 Floating，而 Activity Page 仍调用 Modal，形成双 Presentation 路径。 | 收敛为**一个共享的任务详情悬浮窗 Authority**：活动主页面、活动悬浮窗、任务追踪悬浮窗都调用 `QuestDetailFloatingV3`；旧 Modal 仅在确认无 Consumer 后退役/归档。 | 从主菜单活动列表和活动悬浮列表点击同一任务，都打开同一个独立详情悬浮窗；主菜单关闭后详情仍可按既定生命周期存在；重复选择只刷新同一实例，不叠多窗。 |
| `RU-TASK-01` | **P1 UX + 功能** | **任务追踪启用按钮位置与其它 Feature 不一致，难以发现；任务追踪悬浮窗打不开；不能自定义要看的任务。** | `life.tasks` 已有 Store/Feature/FloatingSurface，Matrix 目前把 daily/weekly selection、detail、independent widget 标为 IMPLEMENTED，但实机与文档结论冲突。 | 统一 Feature Header 的“启用/关闭 + 打开悬浮窗”位置；先修 WidgetHost/Z-order 后验证任务悬浮窗；把“日常/周常总类开关”扩展为**用户明确选择的追踪任务集合**，仍由 Task Store 单一持久化 Authority 管理。 | 用户无需寻找特殊位置即可启用；“打开悬浮窗”立即可见；可从已核验任务目录中逐项加入/移除追踪，重载后选择保留；主页面与悬浮窗显示同一集合。 |
| `RU-BOND-01` | **P1 悬浮窗操作一致性** | **债券/居民板悬浮窗缺少排序/筛选/重复优先等控制，每次都要回主菜单设置。很多悬浮窗存在“只能看不能操作”的同类问题。** | 主页面已有 `SetSortMode / SetBondFilterOption / SetDuplicatePriority`；`rs_v3_life_economy_widgets.lua` Bonds Widget 当前只有表格，没有对应控制条。 | Bonds 悬浮窗直接复用同一 Feature Commands 增加紧凑 Toolbar（排序、20/60/100、原大陆、去重、优先东/西）；随后审计其它悬浮窗，只补**高频且安全**的操作，不复制业务状态。 | 在 Bonds 悬浮窗内即可完成主页面常用筛选/排序，主页面即时同步；重载后状态一致；Toolbar 在 1024 宽度下可用且不挤压表格。 |
| `RU-BOND-02` | **P1 数据正确性** | **债券悬浮窗“有/缺”长期为 `?`；用户已经交过任务，但状态仍显示“未接”。** | `life_bonds` 使用 ResidentBoard + `QuestProgressV3` + bounded Bag scan；Product Matrix 当前把 completion/resource quantities 标为 IMPLEMENTED，但明确仍缺 RU 字段/回读证明。 | 按真实数据流逐层记录 `board row → governed questId → QuestProgress state → bag itemType/stack`；区分 `unknown/unavailable/not accepted/completed`，不得把读取失败映射成“未接”；补任务交付后的刷新边。 | 已交任务在下一次有效 Quest/Board 刷新后显示“完成/已交”或其它经 API 证明的状态；只有事实未知时显示 `?`/未知，不能错误显示“未接”；可验证材料应显示确定“有/缺”数量。 |
| `RU-TEAM-01` | **P1 信息架构** | **团队管理、团队战备检查、团队招募助手、攻城战备检查四个入口各占一行，但单页信息量很小。** | Registry 已把四项放在 `combat_team` group，但 Router/左侧导航仍作为 4 个独立页；其中 `combat_siege_readiness` 仍为 `SPECIFIC_RUNTIME_BLOCKED`。 | Presentation 合并为一个“**团队中心**”（暂名），内部使用 Tab/Section：`团队管理 / 战备检查 / 招募 / 攻城战备`。**只合并 UI，不合并 Feature 生命周期**；每个子页进入时才 Acquire 自己的 Consumer，离开即释放。 | 左侧导航只占一个团队入口；四块内容均可访问；切 Tab 不启动无关高消耗模块；攻城战备仍显示精确 Blocker，不因合并页面解锁未知 Native API。 |
| `RU-TARGET-01` | **P2 产品价值审查** | **“目标监控”当前只显示目标身份/名称/距离，对用户实际帮助很低，单独占一个战斗导航入口价值不足。** | `combat_target_monitor` 当前是 Demand-scoped 目标名称/距离只读 Feature；同类目标事实还会被状态显示、单位连线等功能消费。 | 先对照参考旧项目和当前消费者做产品审查：优先考虑把可用事实并入“状态显示/目标信息”或其它战斗页，移除单独导航；如无独立价值可保留底层轻量 Observation 而退役页面。禁止直接删 Service 导致其它 Consumer 断链。 | 确认所有调用关系后，用户不再看到低价值独立入口；需要目标事实的其它功能不退化；旧配置有明确兼容/忽略策略。 |
| `RU-AUCTION-01` | **P1 旧版能力迁移** | **拍卖收藏缺少旧版“打开拍卖行时左侧跟随出现”的收藏小窗。** | `.18.118` 已新增 `AuctionSurfaceV3 v2` + `tools.auction_sidecar`，复用现有 Favorite Store + `AuctionQueryV3`；仍等待 RU 原生拍卖窗几何/可见性实证。 | 参考项目已定位旧版 `AuctionFavoritesService` 的四值 MainScript + `ADDON:GetContent` 父链可见性/几何回退；新版以独立 Auction Sidecar Consumer 复用现有 Favorite Store/AuctionQuery，不建立第二套收藏/搜索状态。Observer 只读、250ms Demand-scoped，无法证明原生拍卖窗存在时 fail-closed。 | 打开原生拍卖行时 Sidecar 在其左侧/安全位置出现，关闭拍卖行后释放；收藏增删/搜索与主菜单即时同步；不在普通刷新中扇出服务器查询；不同分辨率不遮挡原生关键控件。 |

**共享问题合并规则**：`RU-UI-01` 修复前，跑商/制作规划/制作台助手的“下拉框打不开”不分别建立三个临时补丁；`RU-UI-02` 修复前，任务追踪/跑商/债券等“悬浮窗看不到”先验证统一层级，不分别强行设置 Z-order。完成 Foundation 修复后再逐 Consumer 做回归矩阵。

**参考项目到位后的第一轮映射**：只针对上表中确实需要旧版行为证据的项目建立 `旧版文件/函数 → 当前 V3 Feature/Service → 可复用算法 → 禁止直接迁入的 Legacy 依赖 → 新版验收` 对照，优先顺序为 `Auction Sidecar → Team Center 信息架构 → Task 自定义选择 → Target Monitor 产品去留`。Dropdown/Z-order/Bag 数据链属于当前 V3 自身回归，不等待参考项目即可修。

**`.18.118 本地修复状态（仍需 RU Fresh Reload）**：

- `RU-UI-01`：Dropdown / ColorField / ContextMenu 的 UIParent 级交互弹层改为真实 Native `window`，统一 `system` layer，关闭态默认 hidden + unpickable；不再依赖 root `emptywidget` 的不可靠跨根层级。
- `RU-UI-02`：明确 `Shell(100) < Floating(1000) < Popup(10000) < Modal(12000)`；所有独立 `WindowShell` 进入 `system` layer，FloatingSurface 使用 floating role，应用主 Shell 固定 shell role。
- `RU-ACT-01`：主菜单活动页改为与活动/任务悬浮组件共同调用 `QuestDetailFloatingV3`，不再创建第二套 Modal-only 任务详情路径。
- `RU-TASK-01`（部分）：Task 主页面的 Feature/Widget 主操作移到第一组最前，并统一使用 Floating 任务详情；既有逐任务选择追踪能力保留，等待 RU 验证入口可发现性与悬浮窗层级。
- `RU-BOND-01`：Bonds 悬浮窗增加排序/类别/去重/大陆优先 Toolbar，直接复用现有 Feature Commands/Store。
- `RU-BOND-02`（部分）：修正材料扫描的“无关物品无 stackCount 导致全表 `?`”污染；新增 V3 同日正向完成 latch，并把无法证明的 `NOT_ACCEPTED` 显示为“待确认”而非错误“未接”。
- `RU-BAG-01`（`.18.123` 本地修复，仍待 RU）：新增 `InventorySnapshotV3` 作为背包/银行/箱子的共享只读快照 Authority；背包优先使用 GearV3 已验证的物理 `bagId=1`，首选视图无可读物品时才有界回退 `bagId=0`。Quick/Category Batch 升级 Bag Move Queue v7：一次显式 snapshot 在同一遍扫描建立 identity/category indexes，队列按稳定 identity/category 分组，只保存 `remaining + slotHint`；每个 250ms 写步骤先验证 hint，失效才 bounded wrap scan，只有移动后同槽仍是同物品的歧义分支才做 population count，并可在达到旧计数时提前停止。保留 `itemType` 优先、`name + grade + category` 保守 fallback、最多 2 次 no-op retry、单写/fail-closed。专项 Harness 10/10 PASS；不能在 RU 连续移动实测前关闭该回归。
- `RU-TEAM-01`：左侧导航收敛为单一“团队中心”；四个原 semantic route 保留为中心内 Tab，页面切换继续由 PageHost 控制各自 Consumer 生命周期，攻城战备仍 Runtime Blocked。
- `RU-TARGET-01`：独立“目标监控”导航入口退役；底层 route/Feature/目标事实仍保留，不影响其它 Consumer，后续只在有明确独立产品价值时再恢复入口。
- `RU-AUCTION-01`：已对照参考项目恢复 V3 Auction Sidecar。`AuctionSurfaceV3 v2` 只读观察原生 `UIC_AUCTION`，兼容 RU `GetContentMainScriptPosVis` 仅返回四值的情况，并以 `ADDON:GetContent` 的短父链 `IsVisible`/几何作为更强事实；Sidecar 复用现有 Favorite Store + `AuctionQueryV3`，不复制状态、不后台扇出查询，手动关闭后当前拍卖会话不反复弹回。专项 Harness 23/23 PASS，仍等待 RU 原生拍卖窗位置/可见性实测。
- 本轮静态回归：Foundation Audit `PASS`，`toc=212 / activeLua=212 / allLua=212`；19 个 Python Harness 文件全部 PASS。上述项目只记为“本地修复完成 / 等待 RU 实机复验”，**未用 Harness PASS 代替真实关闭条件**。

**`.18.124 本地热修状态（等待当前 RU 实机复验）**：

- `RU-PERSIST-01`：Tasks Store 使用 codec v2 sorted-sequence 持久化；Persistence 只允许 Envelope 已验证的 ordinary Store 通过 Store 专属 hook 重建候选，并要求候选精确复现旧 stamped fingerprint。`TASK_PERSISTENCE_CODEC_HARNESS PASS`，真实业务字段改变的对照样本仍被拒绝。
- `RU-SVC-01`：`AuctionSurfaceV3/CraftSurfaceV3` 明确 `presentationBoundary=service_only`，Acceptance/static audit 已加入永久 fence。
- `RU-LINE-01`：`ScreenProjectionV3 v6` 增加 World Alias Guard；专项 Harness 对“player/target world 重合但 native screen 分离”的 RU 故障样本通过，当前 18/18。
- `RU-BUFF-EQUIP-01`：BuffDisplay 自身装备读取收敛到 `GearV3`；HUD Layout 增加主手/副手/远程/背部四快捷开关。背部没有合法 slot 事实时继续 fail-closed。
- 全量本地回归：Active/All Lua `220/220` Parse PASS；Foundation Audit PASS；25 个 Python Harness 文件全部 PASS。

### 9.4 Product Matrix 后续入口

当 §9.2 Foundation + UI_REVIEW 阶段允许重新进入业务功能后，按以下规则从 [`Rebuild/PRODUCT_COMPLETION_MATRIX.md`](Rebuild/PRODUCT_COMPLETION_MATRIX.md) 取下一项：

1. 优先用户当前真实回归问题；
2. 然后选择**非 Runtime Blocked**、依赖已满足、代码 owner 清晰的 `PARTIAL / TODO`；
3. 高消耗模块必须继续保持独立 Demand / Consumer / Cache / Lifecycle，关闭后释放资源；
4. 每项完成真实调用链、Persistence、Acceptance Harness 后才允许更新 Matrix 状态；
5. `SPECIFIC_RUNTIME_BLOCKED` 只有获得 RU 客户端/官方 API/可复现字段证据后才能解除，禁止猜字段、猜 ID、猜行为；
6. 每轮修改后继续执行 Foundation Audit、Active/All Lua Parse、TOC/Boundary 扫描和对应专项 Harness。

### 9.5 RU Fresh Reload 验收队列

§6 中列出的 P0 验收仍然有效，并与开发队列并行存在：**本地 Harness PASS 不替代 RU 真机证据**。当用户提供 Fresh Reload 结果时，应优先处理明确的真实运行时回归，并将结论回填到 CURRENT / Product Matrix 对应项。

当前阶段允许继续从 Product Matrix 收敛非 Runtime Blocked 的 `PARTIAL`，但每轮仍优先用户真实 RU 回归；参考项目只给行为证据，禁止以旧架构替换当前 V3 Foundation/Service/Feature/RSUI 边界。

42. **已完成 `.18.114` — ColorField Event / Build Rollback Input Quiescence**：RU 实机定位 `v3_business_combat_range_assist_color:done` 为 ColorField 把 RSUI Button Component 错当 Native Widget 二次 `RequireOn(OnClick)`；改为 ButtonActionContract v2 的 `onClick`。ColorField 隐藏 Popup 不再提前创建键盘 EditBox，HEX 改为只读显示 + RGB Slider。BuildScope v4 / Transaction v2 在回滚阶段对所有已创建 Native Widget 执行 input retire + pick/enable/visible fail-closed quiescence，防止页面半构建失败后残留键盘/鼠标所有权。
43. **NEXT — RU Range Assist + Rollback Recovery Matrix**：Fresh Reload 后先验证游戏 WASD，再打开 战斗→范围辅助；页面必须正常构建、颜色按钮可打开/关闭，关闭页面后 WASD 立即可用。诊断要求 `pageQ=0 / txFail=0 / rollback` 仅保留历史累计前需重置诊断或新 Generation；若出现新的 required_component_event_bind_failed，按具体 logicalId 继续审计，不绕过 Build Transaction。
44. **已完成 `.18.115` — Border Click Action + Popup Hit-Test Quiescence（`.18.114` 同类扫描加固）**：全工程事件绑定调用点扫描未发现同类真违规后，把剩余两处契约缺口收进 Foundation：`RSUI:Border` 新增 `SetOnClick/GetOnClick/Click` Public Action（`BorderClickActionContractVersion=1`，pickable 时 factory 内一次性绑定），Modal Host scrim 改走 `SetOnClick`，Presentation 层由此零处 `:RequireOn(`（component API audit 新增静态禁令）；Dropdown/ColorField popup 与 ContextMenu 关闭时显式 unpick、打开时 re-pick（`PopupHitTestQuiescenceContractVersion=1`，失败 fail-closed），隐藏 popup 不再依赖 native 隐式命中语义；Diagnostics Snapshot 补挂 CombatRelationV3/TeamRosterV3/ScreenProjectionV3 GetHealth。Input Focus Drag Harness 扩为 72/72。
45. **已完成 `.18.116` — Product Truth Runtime Block Hardening**：审查 Zcode 新增能力后，把两条缺少 RU 证据的危险路径重新收回权威边界。Fishing 当前只保留目标 Buff 识别与推荐技能栏，不再调用 `X2Hotkey` 读取/覆盖/删除/保存快捷键；历史 experimental recovery marker 只读保留，不自动执行恢复写入。Reinforcement Analysis 删除 `0..31` 猜测槽位以及 `GetReinforceInfo/GetMaterialInfo` 逐槽探测，只保留已验证的聚合只读 Getter。Foundation Audit / Runtime Gate 新增 Product Truth 锁定检查，`SPECIFIC_RUNTIME_BLOCKED` 在无 RU evidence 时不得被代码暗中解除；同时 GearService 去除 `Service -> Feature` 反向依赖，由 Gear Feature 订阅 `v3.gear.updated/runtime_finished` 自主管理 transient lifecycle。
46. **已完成 `.18.117` — Deferred Keyboard Activation Foundation**：修复点击“伤害统计”后 WASD/技能/聊天全部失效。`CreateEditBox/CreateMultiEditBox` 不再在构造阶段启用 Keyboard；所有 TextInput/NumericInput 只在明确点击后 `ArmInputWidget -> SetFocus`，LostFocus/隐藏/禁用/失去 Pick/切页/Runtime Stop/Release 全部 disarm。状态显示的 raw multiline 导入框接入同一公共 lifecycle helper。Native Interaction v6、UI Framework v12、Input Focus/Hidden Isolation v2、Gate v109；专项输入 Harness 88/88，全部现有 Harness PASS。
47. **已完成 `.18.118` — Top-Level Layer / RU Regression Pack**：共享 Dropdown/Popup 改为 root transient Native window，固定 `Shell < Floating < Popup < Modal`；任务详情统一 Floating；团队四入口收敛团队中心但 Consumer 生命周期独立；Bonds Widget 增加排序/筛选并修 unknown 污染/完成锁存；Bag Move Queue v6 增加 stable identity fallback + bounded no-op retry；参考旧项目恢复 Auction Sidecar，`AuctionSurfaceV3 v2` 兼容四值 MainScript 返回并只读复用 `ADDON:GetContent` 可见性/几何。Foundation Gate v111、UIV3 Acceptance v66，Foundation Audit PASS，19 个 Python Harness 文件全部 PASS。
48. **NEXT — RU `.18.118` Fresh Reload Regression**：优先实测跑商/制作规划/制作台助手下拉框、任意 Floating 是否始终位于主菜单上方、Bag 一次点击连续移动同类、Auction House 打开/关闭时 Sidecar 跟随、Bonds 有/缺与已交状态。随后继续 Fishing/Reinforcement Blocker Evidence：Auto-R 与逐槽强化在 RU 合法 API 证据齐全前保持 fail-closed/blocked。
49. **已完成 `.18.119` — Trade/Craft User Workflow**：Trade 增加 current/full(130%) 持久模式与经商熟练度只读观察，未验证的熟练度收益倍率保持 unknown；Craft Planner/Assistant 共用 PriceQuoteQueueV3 做显式批量材料询价与成本回写；Tasks 逐项追踪/取消追踪入口显式化。`rs_business_bridge.lua` Lua 5.1 local budget 继续锁在 200/200，自动制作台事件仍未越过 Runtime Blocker。
50. **已完成 `.18.120` — Trade Detail / Favorites Shared Workflow**：对照旧版可安全复用行为，把路线收藏收回 `life.trade` 单 Authority（stable `from:to`、去重、max 12），主页面与 `life.trade` HUD 共用收藏/排序命令；新增 `TradeDetailFloatingV3`，主页面/HUD 选中贸易品都打开同一悬浮详情，详情只在显示期持有 `floating:trade_detail` Consumer，并只通过 Feature `QuoteRowMaterials` 显式询价当前材料。Origin 改变会在持久化前清理旧 Destination，避免 Durable Store 保留无效路线。无新 Native API、无隐式 Auction fan-out。
51. **NEXT — RU `.18.120` Trade Workflow Regression**：Fresh Reload 后验证跑商起点/目的地下拉、收藏加入/取消/选择与重载保持、货率/售价排序、主页面与 HUD 行点击打开同一 Trade Detail、详情始终在 Shell 上层、关闭后不残留 Consumer、显式材料询价能完成且普通 Refresh 不自动查拍卖。继续并行验证 `.18.118` Bag/Auction/Bonds；Fishing Hotkey、Reinforcement slot 与 Trade 自动制作台/叛乱记录在获得合法 RU API/事件证据前继续 blocked。

52. **已完成 `.18.121` — Craft Multi-Plan / Native Craft Sidecar**：`life_craft_planner` 新增 `CraftPlanContract v1`，永久 Store 只保存最多 12 个 `{recipeKey, quantity}` 稳定条目（1–999），同配方合并数量；投影通过 `StaticDataV2 trade_recipe/trade_material` 聚合材料需求，并复用现有 Craft 单次 bounded Bag scan 的 held 数据计算缺口。计划材料报价必须由用户显式触发 `QuotePlanMaterials`，经 `PriceQuoteQueueV3` 去重/限速，普通 Refresh 不发服务器查询。`tools_craft` 新增 `CraftSurfaceV3` + `tools.craft_sidecar`：只读观察 `UIC_MAKE_CRAFT_ORDER / UIC_CRAFT_ORDER / UIC_CRAFT_BOOK`，400ms P2 Scheduler 仅在功能启用且 `autoSidecar=true` 时运行；四值 RU 构建必须得到 Content/父链可见性正事实，geometry-only fail-closed。Sidecar 复用同一 Craft Feature/Store/Quote Command，关闭释放 Consumer，本次原生窗口会话手动关闭后不反复弹回。无 Craft Event 猜测、无背景 Auction fan-out。
53. **NEXT — RU `.18.121` Craft Workflow Regression**：Fresh Reload 后验证制作规划“加入计划/移除/清空/计划询价”与重载保存；多个配方共享材料必须正确合并数量，持有/缺口不能重复扣背包。开启“制作台侧窗：自动”后依次打开可触发的原生制作窗口，Sidecar 应在 Native 窗左/右安全位置出现，关闭原生窗释放、手动关 Sidecar 当前会话不重弹；普通刷新不得触发 Auction 查询。若 RU 只返回四值几何且 `ADDON:GetContent` 父链可见性不可读，保持 fail-closed 并采集真实返回证据，不改成 geometry-only 猜开窗。叛乱记录仍为未实现的 PARTIAL 子能力。

54. **已完成 `.18.122` — Team Sac Highlight / Verified Marker Snapshot**：对照参考项目只迁移已有 API 证据的团队辅助能力。`combat_team_tools` 保持单一 Feature Authority，新 `TeamVisuals` 子 Store 只保存 `sacEnabled + savedMarks`；Spelldance 候选由 TeamRoster 边沿/10s safety scan 发现，Sac Buff 事实复用 AuraObservationV3，Presentation 仅在 active Sac 存在时运行 50ms bounded head overlay。头标保存只读当前非零 marker，最多 16 条并 durable commit；恢复队列按官方 1000ms cooldown 使用 1100ms 节拍，写前读、已正确零写、写后下一拍读回验证，任何未知/失败立即停止；不调用 `RemoveAllOverHeadMarker`。Demand release 和 Sac setting/persistence 之间新增回滚，防止 Feature/Service/Store 分叉。Foundation Gate v114、UIV3 Acceptance v69、`TEAM_VISUAL_MARKER_HARNESS 34/34`，219/219 Lua Parse 与 Foundation/Presentation/RSUI audits PASS。
55. **已完成 `.18.123` — Inventory Snapshot V3 / Bag Move Queue v7**：参考项目仅保留“一次点击连续取/放同类”的产品行为目标，没有迁移其旧 Service、重复遍历或队列结构。新增共享只读 `InventorySnapshotV3`，统一物理 bagId Authority、Native row normalization 和单遍 identity/category index；Quick 与 Category Batch 使用 grouped stable intent、live slot hint + wraparound revalidation、250ms 单写串行及歧义分支 bounded count，直接移动的黑名单读取也不再硬编码 bagId=0。Foundation Gate v115、UIV3 Acceptance v70、`BAG_MOVE_QUEUE_V7_HARNESS 10/10`，220/220 Lua Parse 与 Foundation Audit PASS。
56. **历史 `.18.123` Bag Regression（由 `.18.127` v8 取代）**：原 v7 对任何 Native no-op 采取 bounded retry 后全局停止；`.18.127` 已收敛为稳定 identity 局部失败/满仓拒绝只跳过该 identity 并继续后续候选，只有读取失败、能力缺失或 identity 不可稳定确认时才保持 fail-closed。当前活动 Bag 验收并入 `.18.128` Fresh Reload Regression。
57. **已完成 `.18.124` — RU Integrity / UnitLine Alias / Buff Equipment Hotfix**：修复 Auction/Craft Service 边界声明；Tasks 持久化改 codec2 并加入 exact-fingerprint-proven 旧形态恢复；ScreenProjectionV3 v6 增加 batch World Alias Guard；BuffDisplay 自身装备读取收敛到 GearV3 并增加四个显式装备开关。Foundation Gate v116 / UIV3 Acceptance v71，220/220 Lua Parse、Foundation Audit、25/25 Python Harness 文件全部 PASS。
58. **已完成 `.18.129d` — 连线/画圈参考对齐（label 句点模型）**：通读 easypull（真实可用画圈）与 plates 旧版连线，实机可用的点阵全部是 LABEL + '.' 字形（15–22px）；新版 emptywidget+4×4 colorDrawable 无参考先例且 1080p 下不可见。`EnsureUnitPairPool`/`EnsurePool` 改 `S.UI:CreateLabel`，`PlaceUnitDot`/`PlaceDot` 改 style 字号/着色；投影路径不动（两参考各证一条）。端到端 15/15、采样 11/11、Audit PASS。
59. **已完成 `.18.129` — 真实故障收口**：单位连线"单点"三根因（近重合段漏过滤/缓存无条件提交失同步/growth 独占）+ 投影视口边界 + Reconcile 保留重试；Boss 按 wbdebuff 四单位事实模型重建消费端（去 showTargetCastingTime 门、大小写归一、buff_id 优先、四 scope 施法租约）；治疗校准模式 Preview 租约分离（healer_v3_visual_lifecycle 误报根因）+ 布局常量对齐旧版实测；Form/FieldGroup/FormSection 真实 Measure（HUD 布局重叠根因）；Trade SetFrom 保留 latest-route + 失败重排；Bonds widgetWindow 归一；Gear 旧序指纹桥；Bag 不确定错误跳过继续；Tooltip 指针缓存。Foundation Audit PASS（toc 221/221）、luacheck 0 errors、31 harness 中 28 全绿（3 个 .18.104 遗留）。新增 `GEAR_SLOT_ORDER_HARNESS`。
59. **已完成 `.18.125` — Integrity v3 Canonical + UnitLine 自愈 + Buff 装备诊断**：`.18.124` 的 strict shape-repair 被 RU 实机拒绝后，按 canonical 管线重做完整性（v3 盖章/校验均在 `CanonicalIntegrityValue` 上进行），v2 旧档走受控升级一代重盖（仅 v3.tasks / v3.death_review opt-in）；Unit Lines 闭合 alias 候选残余坍缩路径并给 Scheduler 熔断加指数退避自愈；Buff 装备 lane 全链诊断插桩。当前 supplied baseline 复跑后 28/28 Python Harness 全部 PASS；`.18.125` Changelog 中 25/28 是当时记录，不再作为当前阻断。
59. **历史 `.18.127` — Runtime Continuation / Native Raid Geometry**：Gear 缺件只跳过单槽、Trade 增加当前路线重试/6.5s timeout、Bag 满仓按稳定 identity 局部跳过并继续仍保留；Healer 的 10×5/670×180 推断经用户与参考项目证明错误，已由 `.18.128` schema 6 / Overlay v4 迁移修正。
60. **已完成 `.18.128` — Runtime Follow-up / Shared Facts / Layout Repair**：换装方案按 EquipmentSlots 语义顺序稳定；Healer 恢复单团 50=上25+下25；ScreenProjection v8 加 Camera-unavailable bounded Native fallback；Trade 改 single-flight/latest-route；Bonds 增加服务器日大陆快照并按材料+数量跨大陆去重；Bag/Activity Tooltip 修复；新增共享 CastingObservationV3 并让 Boss/BuffDisplay 复用；TransformInspector v3 通过 Measure 修复 HUD 设置重叠。Foundation v119 / Acceptance v74 / 221 Lua / 30 Harness 全绿。
61. **已完成 `.18.126` — Range Assist Global World / Dense Projection**：修复 Range Assist 的 player local-space 与 global Camera Frame 混用；ScreenProjectionV3 v7 为每个批量输入返回稳定索引（不可见点用 sentinel），Range consumer 改显式 `1..count` 遍历；Foundation Audit/Runtime Gate/UI Acceptance 同步加 fence，投影专项 25/25。
62. **NEXT — RU `.18.128` Fresh Reload Regression**：先按本轮十项真实复现路径逐项验证；特别记录 Boss 的 RU 本地化施法名/预警时机、Trade timeout 后是否存在极晚旧回调、Bonds 实际居民板文本、Healer 原生 1/2 团切页以及 Unit Lines/Range Camera Frame fallback。随后继续 `.18.125` Integrity/BuffGear 与 `.18.123` Bag 多堆实机矩阵。
63. **已完成 `.18.141` — Range Assist 1280×768 Anchor Calibration**：`.18.140` 已能稳定显示完整圆，但 RU 1280×768 实机反馈圆心偏离玩家。恢复 `.18.136/.18.137` 已有实机正证据并下沉到 `ScreenProjectionV3 v12`：仅纯 EasyPull Camera fallback 批次用同一 Camera Frame 投影世界圆心，再与原生 `GetUnitScreenPosition("player")` 求单一 `(dx,dy)`，整批刚性平移；mixed native/camera 明确跳过，异常 delta 有边界保护。Range 与 PVP 50ms 不回退。ScreenProjection 29/29、UnitLine/Range 30/30、EasyPull/PVP50 19/19，完整 34/34 Harness + Foundation Audit PASS。
64. **NEXT — RU `.18.141` Resolution Matrix**：Fresh Reload 后优先验证 1280×768 圆心是否钉在玩家；再切 1024×768、1920×1080 与常用 2K 分辨率，分别执行旋转镜头、拉近/拉远、移动角色。范围诊断应出现 `校准=dx,dy` 且 `锚校applied`；若为 `unavailable/rejected/mixed_source_skipped`，复制整行作为下一轮唯一实机证据。
65. **已完成 `.18.142` — RSUI Hover / Numeric Draft / Adaptive Range Foundation**：修复按钮停留时 NORMAL/HIGHLIGHT 来回闪烁；Button/Toggle/Dropdown/ColorField 统一逻辑 Hover，hover 期间两张 Native 背景视觉幂等。Interactive Draft 升 v2，以 component-local editing ownership 解决 NumericInput 删除/输入时被父级 Refresh 立即回灌旧值。NumericField 升 Inline v5 / AdaptiveRange v1：精确输入经 Domain 接受后可把默认 Slider 端点向外扩展，`v3.rsui.numeric_ranges` 单独保存展示范围，Fresh Reload 恢复且不复制业务数值；真实 Domain clamp/拒绝仍是最终 Authority。RSUI v45/API12.9；`UI_INTERACTION_RANGE_HARNESS 34/34`、Interactive Draft 115/115、Foundation Audit PASS。
66. **历史 `.18.142` UI Interaction Regression（由 `.18.143` Hover v2 取代）**：Numeric Draft / Adaptive Range 验收仍有效；按钮悬停部分因 UnitLines/RangeAssist 高频 Projection 触发 RU 假 `OnLeave -> OnEnter` 已由 `.18.143` 新的 leave fence + 设置页刷新隔离重新定义，当前只执行 §68 的 `.18.143` Hover Regression。
67. **已完成 `.18.143` — Hover Leave Fence / 高频设置页隔离**：`.18.142` 实机证明 UnitLines/RangeAssist 仍会因高频 Projection 刷新触发 RU 假 `OnLeave -> OnEnter`。Stable Button Hover 升 v2：120ms one-shot leave grace、重入取消、`IsMouseOver()` 物理复核；禁用/释放清理待提交任务，无 Tick。UnitLines/RangeAssist 世界视觉刷新保持原高频，但 Business Settings 的 `visual_tick` 只 160ms 合并刷新，直接设置操作仍即时。UI Interaction Harness 44/44、Foundation Audit PASS。
68. **已完成 `.18.144` — Edit Commit Focus Fence / Table Preview Authority**：单行 EditBox 显式关闭 Native clear-on-enter；Text/Numeric Enter、失焦与输入切换统一进入 Draft→Commit/rollback→tracked Focus release→Keyboard disarm 生命周期，绝不全局清游戏/聊天 Focus。DataView 拖列期间 Preview 成为唯一 Geometry Authority，普通 Layout 与虚拟行重绑不得重新发布旧 committed widths；DragStop 后才成对 Commit。RSUI v46 / API 13.0、Foundation v120 / Acceptance v75；35/35 Harness + Foundation Audit PASS，仍等待 RU Fresh Reload 实机关闭回归。
69. **已完成 `.18.145` — Numeric Explicit Apply / Adaptive Visual Point Size**：Compact Numeric Setting 默认在 Exact EditBox 右侧提供“应用”，不再把未验证的 RU Enter 事件作为唯一提交入口；Apply 仍沿 Binding→Domain→Persistence 单 Authority，并对 LostFocus-before-OnClick 做相同值去重。RangeAssist/UnitLines 点大小的旧 Domain 10 上限与 Presenter 40px flatten 同步移除，统一由 `Constants.VisualGuide` 约束 2..24；默认 Slider 仍 2..10，输入 15 并应用后 Authority=15、Slider 展示端点扩为 2..15 且持久化，Presenter 显示为 55px。RSUI v47 / API 13.1、Foundation v121 / Acceptance v76；35/35 Harness + Foundation Audit PASS，等待 RU Fresh Reload 验证实际视觉与多分辨率紧凑布局。
68. **NEXT — RU `.18.143` Hover Regression**：Fresh Reload 后分别在“单位连线”四个 Pair Toggle、颜色按钮、顶部启停按钮，以及“范围辅助”启停/颜色按钮上连续悬停 10 秒；视觉不得在默认/高亮之间闪烁。随后快速移入/移出确认 hover 最迟约 120ms 清除且点击不受影响。PVP/Range 世界视觉刷新频率不得下降。


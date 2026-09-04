# Replicated Suite 重建进度（唯一当前状态）

> **Authority: CURRENT**  
> 本文只保存“现在完成到哪里、现在还缺什么、下一步做什么”。逐版本实现过程见 [`CHANGELOG.md`](CHANGELOG.md)，历史阶段交接与验证记录见 `Archive/`。

## 1. 当前基线

| 项 | 当前状态 |
|---|---|
| Architecture | V3-only / `v3_rebuild` |
| Runtime Addon | `replicatedsuite/` |
| Legacy / Professional / `globals/` | 已物理删除，Active dependency = 0 |
| BuildTag | `v3-m1.16.0.18.104-native-bool-setter-startup-hotfix` |
| Active TOC Lua | 210 |
| Active / All Lua | 210 / 210 |
| Foundation Audit | PASS |
| Product Capability Matrix | 125 条：77 IMPLEMENTED / 35 PARTIAL / 2 TODO / 11 SPECIFIC_RUNTIME_BLOCKED |
| RU Fresh Reload | PENDING |
| Current UI Gate | Buff Display `UI_IMPLEMENTING` · **Fresh Reload/真实回归为当前 P0**：`.18.104` 已修复 `.18.103` Native boolean false-state return 被误判为拒绝、导致 V3 Host 无法创建且只剩 `R` 的启动阻断；`.18.103` 的 Native/Composite state + geometry transaction 与 fail-closed 继续保留；`.18.100` Persistence v7 generation reload fence 及 v6/v5 durability/integrity 链继续生效；`.18.96` Unit Lines/Archer 与 `.18.94` Trade/DPS preflight 继续生效；仍需 RU Fresh Reload 证明主界面/ESC 注册、保存、换装、共享控件、连线、职责与 Native Trade popup |

当前 Foundation 结构指标：

```text
toc=210
activeLua=210
allLua=210
globals=0
presentation=0
rawNative=0
rawScope=0
detachedWidgetState=0
apiDependency=0
apiCapability=0
businessIds=0
auctionEventOwners=0
retiredUiLayer=0
rsuiComponentApi=1
presentationFeatureApi=1
rsuiLoadDeps=2
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
- **Buff Display**：`.18.80` 已把兼容四页签收敛为 `追踪管理 / HUD 布局 / 导入导出` 三页签；Tracking 使用单虚拟 Table。`.18.89` 根据 RU 实机反馈把 HUD Layout 接到共享 `Element Tree + LayoutEditorWorkspace + LayoutEditSession`；`.18.90` 将共享 Workspace 升到 v4 并补 Component API 构建门禁：Compact 模式恢复 `[属性]` Drawer 与 X/Y/宽高等 TransformInspector 参数；RSUI Interactive Draft v1 阻止环境刷新覆盖正在拖动的 Slider Preview / focused Edit 草稿，Aura 更新不再重绘 Layout 页。Working/Undo/Redo/Reset/Revert 不进入 Persistence getter，只有 Apply 才执行 durable layout write。StatusClassificationV3 仍是唯一分类 Authority。RU Native 拖拽、精确输入与真实 SaveData 回读仍需 Fresh Reload。
- **Raid Readiness / Boss Alerts / Team Tools**：安全子集已实现；未验证能力继续保持 Partial / Runtime Blocked，不使用猜测字段或禁止 API 补齐表面功能。
- **Unit Lines / Range Assist**：`.18.87` 根据 RU 真机反馈完成两层修复：①旧 `pointCount` 改为基础密度，屏幕空间长线自动补点并先裁剪 viewport 可见段；②多人/低帧压力下不再把整条 HighFrequency 刷新作为 P3 延后，而是 P1 保持连续 cadence，Presenter 本地 Diff 跳过未变化 Native 属性、点池渐进扩容，并只削减远距离额外补点。`.18.88` 修复“目标在相机背后却被 Native 投影成正 depth 边角点”；`.18.96` 根据新的 RU 战斗截图继续修复前方端点偏移：ScreenProjectionV3 v5 统一所有 unit world read 为 global (`isLocal=false`)，并在同一 batch 内以 camera-world logical 投影校验 Native screen point；UI-scale 候选明显更一致时做 scale reconcile，仍严重偏离时退回 camera consistency projection。该 gate 只在 Unit Lines batch 启用，不改变 Healer/Buff Display 普通 Unit projection。`.18.61` 的两列外观卡片与 Range Assist 永久颜色 Store contract 保持不变。

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
- 当前 BuildTag 与 `replicatedsuite.lua` 一致：`v3-m1.16.0.18.104-native-bool-setter-startup-hotfix`。

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
| `Rebuild/PRODUCT_COMPLETION_MATRIX.md` | 125 项产品能力库存与完成状态 | 否，只提供 backlog 候选与证据 |
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
33. **NEXT — RU Fresh Reload + Startup/State/Interaction/Persistence Matrix**：使用 `.18.104` 修改文件启动**新进程**。第一优先确认 `R` 点击可以打开主界面且 ESC 插件项重新出现；随后验证 Gear 新建/改名、快捷按钮恢复与分辨率锚点，再执行 Text/Numeric/MultiEdit、Slider、Scrollbar、Dropdown、ColorField、Table resize、SplitView、Window drag/resize/minimize/lock/appearance、Modal/ContextMenu 的真实鼠标矩阵。之后执行 Gear Persistence：新保存→本进程应用→Reload→完整退出重进→再次保存翻转 A/B。正常路径要求 `integrityLoadFailures=0 / envelopeIntegrityLoadFailures=0 / encodedLoadRejects=0 / decodedLoadRejects=0 / readbackVerifyFailures=0 / durableVerifyFailures=0 / barrierVerifyFailures=0 / clearVerifyFailures=0 / scopeBindingMismatches=0 / unverifiedReloadRejects=0`。任何“可见但点不动/状态不一致”继续按 Foundation Regression 处理，不下沉业务页打特例；任何 Runtime Blocked 能力仍须取得具体 RU API 证据后才解锁。
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

当前阶段明确不做：在 §9.2 Foundation 收口前，直接开始 Buff Display / Healer / Gear / Unit Lines / Range / DPS 等业务 Feature 的大规模 UI 迁移。

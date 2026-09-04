# Replicated Suite 当前架构（唯一权威）

> **Authority: CURRENT**  
> 本文只描述“当前系统是什么、责任归谁、运行时如何组织”。历史版本、实施过程与逐条修复统一见 [`CHANGELOG.md`](CHANGELOG.md) 和 `Archive/`。  
> 当前代码与 `toc.g` 是加载真相；若本文与真实代码冲突，以代码为准，并在同一修改轮次修正文档。

## 1. 当前形态

- **运行时 Addon 只有 `replicatedsuite/`**；`z_api_functions/` 是开发期 API Reference / Evidence，不进入 `toc.g`，不进入运行时。
- 当前架构模式为 `v3_rebuild`，Active TOC 只加载新版 V3 Framework。
- 旧版 Legacy / Professional / `globals/` 已物理删除，不再随包、不作为当前迁移依赖，也不得重新接回 Active Runtime。
- 当前目录遵循长期分层：**Core + Services + Feature Modules + Presentation / RSUI**。
- Feature 必须独立启停、独立持有生命周期资源；“页面打开”“悬浮窗可见”“Feature Enabled”不是同一个状态。

## 2. 加载模型

ArcheAge Addon 按 **目录树 + `toc.g`** 依序执行 Lua 文件，本项目不使用 `require` / `dofile` / `loadfile` 组织运行时模块。

文件通过顶层注册写入 `ReplicatedSuite` 命名空间，例如：

```text
ReplicatedSuite
├── Core / Runtime Foundation
├── Native Foundation
├── Services
├── Features
├── Presentation V3
└── Diagnostics / Acceptance
```

因此判断代码是否属于 Active Runtime 必须同时检查：

1. 文件是否在 `toc.g`；
2. 文件是否在加载时注册对象/服务/Feature；
3. 运行时调用链与生命周期是否真实可达。

封包要求 `toc.g ↔ 磁盘 Active Lua` 双向 0 差异。磁盘存在但不在 `toc.g` 的运行时 Lua 视为死文件；`toc.g` 引用不存在文件视为阻断。

## 3. 分层与依赖方向

```text
V3 Application Shell / Router / PageHost / WidgetHost / ModalHost
                         │
                         ▼
             Presentation / RSUI Consumers
                         │
                         ▼
           Feature Projection + Commands Facade
                         │
                         ▼
          Feature Domain / Authority / Store
                         │
                         ▼
              Shared V3 Services
                         │
                         ▼
 Demand / Scheduler / Events / Observation / Persistence / Diagnostics
                         │
                         ▼
       Native Contract / Imports / Object Factory / Write Fence
```

依赖只能沿受控方向向下。特别禁止：

- Presentation 直接读取 `Feature.State`、Store 私有字段或 Service 私有缓存；
- Presentation 直接执行业务 Native 写操作；
- Domain / Service 直接控制 Page、Widget 或 Modal 的可见性；
- Feature 之间直接互相调用形成强耦合；共享事实应进入 Service / EventBus；
- 为了 UI 便利复制第二份业务 Authority。

## 4. Core / Runtime Foundation

Core 负责跨功能共享但不包含具体业务结论的基础能力：

- `rs_runtime.lua`：统一启动/停止与运行阶段编排；
- `rs_demand.lua`：Consumer Lease / Demand 生命周期；
- `rs_scheduler.lua`：共享调度与 one-shot / 周期任务；
- `rs_refresh_coordinator.lua`：刷新合并与协调；
- `rs_events.lua`：Native 事件桥与 Suite 内事件分发；
- `rs_observation.lua`：按需 Observation 基础设施；
- `rs_frame_budget.lua` / `rs_performance.lua`：高频工作预算与性能治理；
- `rs_persistence.lua`：统一 Store / Lifetime / Dirty / Write Fence；
- `rs_api.lua` / `rs_api_capabilities.lua`：Runtime API 调用与能力门；
- `rs_diagnostics.lua`：结构化诊断；
- `rs_foundation_gate.lua`：封包级架构回归门禁。

Core 不承载 DPS、治疗推荐、跑商利润、团队判定等业务事实。

## 5. Native Foundation

Native Foundation 是所有原生对象、能力导入和写入边界的唯一治理层：

- `native/rs_native_contract.lua`
- `native/rs_native_imports.lua`
- `native/rs_native_object_factory.lua`
- `native/rs_native_capabilities.lua`
- `native/rs_native_recovery.lua`

关键契约：

- 逻辑 ID 与物理 Native ID 分离；物理 ID 不持久化、不反向解析为业务身份；
- Native 对象必须经 Object Factory / Parent Fence / Build Scope 创建；
- Runtime capability 以 `core/rs_api_capabilities.lua` 为静态基线，并区分 Official / Static / Runtime 证据；
- 未验证 RU 参数、返回结构、权限或 cooldown 时 fail-closed，不猜字段、不猜写法；
- `z_api_functions/` 只提供开发参考，不自动提升为 Runtime Verified。

详见 [`Architecture/NATIVE_ARCHITECTURE.md`](Architecture/NATIVE_ARCHITECTURE.md)。

## 6. Shared Services

当前 `services/` 有 16 个 Active Service：

| 服务 | 当前责任 |
|---|---|
| `SkillMetadataV3` | 技能名称/Icon 等懒解析与有界缓存 |
| `BuffMetadataV3` | Buff 元数据懒解析与有界缓存 |
| `StatusClassificationV3` | Buff / Debuff 分类唯一 Authority |
| `AuraObservationV3` | 按需 Aura 状态事实 |
| `UnitIdentityV3` | 保守单位身份事实 |
| `CombatEventBusV3` | Combat Fact 唯一共享入口 |
| `CombatAnalyticsV3` | 单 all-scope Consumer + Metric 分发 |
| `TeamRosterV3` | 团队/成员快照事实 |
| `CombatRelationV3` | SELF / TEAM / FRIENDLY / OPPONENT / UNKNOWN 关系事实 |
| `InstanceCatalogV3` | 运行时副本目录事实 |
| `QuestProgressV3` | 任务进度共享读取 |
| `GearServiceV3` | 装备读取/换装受控能力 |
| `AlertsService` | 短生命周期 Alert 状态 |
| `ScreenProjectionV3` | Native world/screen → RSUI logical projection；v5 unit batch 同一 global world space + bounded Native/Camera consistency reconciliation |
| `AuctionQueryV3` | 当前挂单查询、事件所有权、串行化与限速边界 |
| `PriceQuoteQueueV3` | 共享按需报价队列与 bounded quote read-model |

Service 只提供共享事实/基础操作，不拥有 Consumer 的业务判定和 Presentation。

Metadata 缓存当前**不抽公共基类**：`BuffMetadataV3` 与 `SkillMetadataV3` 虽有同构有界缓存框架，但 Native 源、解析、安全策略和公开契约不同；出现第三个同构 Metadata Service、公共缓存 Bug 或统一调参需求时再重新评估。

详见 [`Architecture/SERVICE_ARCHITECTURE.md`](Architecture/SERVICE_ARCHITECTURE.md)。

## 7. Feature Runtime

`features/rs_feature_registry.lua` 是 Feature 元数据 Authority，`features/rs_feature_runtime.lua` 管理 Feature 生命周期。

Feature 的标准责任边界：

```text
Store / Settings
      +
Domain / Authority
      +
Projection
      +
Commands
      +
Demand / Consumer lifecycle
```

当前主要 Active 垂直切片包括：

- 战斗：DPS、Combat Analytics、Death Review、Raid Readiness、Healer、Buff Display、Gear；
- 生活：Activities、Tasks、Housing、Butler，以及生活/经济共享 bundle；
- 工具：Instance Browser、Random Shop，以及 Business Bridge 下的受控工具能力。

长期规则：

- 高消耗模块必须独立监听、独立缓存、独立生命周期，关闭后释放资源；
- 低消耗模块不得依赖 DPS 等高性能模块才能运行；
- `Feature Enabled ≠ Presentation Visible`；隐藏窗口不代表关闭 Feature，关闭 Feature 也不等于删除永久配置；
- Runtime Blocked / Partial 必须保留真实 blocker，不允许用空壳页面冒充完成。

## 8. Combat 共享架构

### 8.1 Combat Event Authority

`CombatEventBusV3` 是 `COMBAT_MSG` / `UNIT_DEAD_NOTICE` 的共享 Combat Fact 入口。

`CombatAnalyticsV3` 只持有一个 `scope=all` Consumer，并将事实按预编译计划分发给独立 Metric。DPS 通过隐藏 `dps_core` adapter 复用该入口，避免第二套 all-scope 总线消费；Death Review 保持独立 `scope=self` 的低开销链路。

### 8.2 DPS

DPS Domain 负责：PVP/PVE、伤害、承伤、治疗、Shared Heal Ledger、Relation Replay、技能/目标明细等业务事实。

玩家放置技能实体如果缺少可靠 proxy→caster owner link，必须显式保留为“未归属技能代理”，禁止按最近施法者、距离、目标或唯一候选猜主人。

### 8.3 Healer

Healer 复用 `TeamRosterV3 + AuraObservationV3`，Recommendation 自己拥有治疗优先级业务判定。

当前团队覆盖层采用：

```text
RaidTeam（成员身份）
≠ RaidPanel（屏幕容器 A/B）
≠ Calibration（面板几何）
```

Panel A/B 保存整面板矩形，50 个槽位由几何派生；`auto / single / dual` 只改变团队绑定，不要求重新校准。Calibration 可作为独立 Presentation Preview 运行，不应强制启动治疗推荐 Consumer。

### 8.4 Buff Display

`StatusClassificationV3` 是“效果是什么”的唯一分类 Authority。Buff Display Store 使用分类分桶追踪，并保存头顶组件布局；Presentation 只消费 bounded detached projection。Aura 事件按需订阅并合并刷新，Consumer=0 时释放事件和任务。

## 9. Presentation / RSUI

当前 UI 只有 V3 Presentation Host：

- Router：`presentation/v3/navigation/rs_v3_router.lua`
- Page：`PageHost`
- Floating Widget：`WidgetHost`
- Modal：`ModalHost`
- Shell：`rs_v3_shell.lua` / `rs_v3_host.lua`

RSUI 是唯一通用 UI Foundation。页面应优先组合：

- DataView / TableView / List / Tile；
- Binding / Persistent Binding；
- ViewState；
- ActionRunner；
- WindowShell / FloatingSurface；
- 声明式 Form / Layout Templates / Adaptive Panels；
- Tooltip、ColorField、CompactNumericSetting 等公共组件。
- Workspace Composition Templates：MasterDetail / InspectorWorkbench / SettingsWorkbench / CommandCenter + 统一 Breakpoint/Density Policy。
- Composite Foundation：`StatusChip`、显式查询且有界的 `PickerModel`、`SearchablePicker`、`IconPicker`、stable-key/transactional/bounded `TreeModel`、基于虚拟 ListView 的 `TreeView`。Tree 身份禁止 row-index/path fallback；展开状态使用 true/false/nil 三态覆盖并有 hard cap。
- Host / Slot Attachment Contract：RSUI Component 只有一个逻辑 Parent；RU Native 没有已验证通用 Reparent API，所以跨 Parent 重挂载一律 fail-closed。每次 Attach 同时核对 immutable Native creation parent，防止逻辑/物理 Parent Authority 分裂；`RemoveChild` 是释放语义，不返回可重挂载 Widget。
- ResponsiveInspector：采用 **Stable Host**，Content 与 Inspector 在构建时一次创建于同一物理 Host；宽屏为 inline 右栏，compact 为 overlay drawer，只改变几何/可见性，不复制 Inspector 状态、不重建、不 reparent。
- Workspace Composition v2：除 MasterDetail / InspectorWorkbench / SettingsWorkbench / CommandCenter 外，增加 `ResponsiveInspectorWorkspace`，页面只组合公共模板，不自行写第二套 responsive reparent 逻辑。
- Geometry Authority：ArcheAge/CryEngine UI 使用左上角原点；`+X→右、+Y→下`。`S.Layout.CoordinateSystemContract v1` 统一方向语义，`RectTransformTransaction v2` 统一编辑器 move/8-way resize + snapped OverridePreview 的 staged math；任何 Feature/Presentation 不自行翻译“向上=加 Y”。
- Pointer Boundary：`RSUI.Pointer v1` 只暴露逻辑绝对坐标与 start→current delta；generic pointer capture 当前未验证且显式 unsupported，Native drag/resize capture 继续归 `RSUI.Windowing`。
- Editor Transform Models：`AnchorPivotModel v1` 统一 point-anchor / Pivot / Rect / anchor-relative offset；`LayoutEditorSnapSettingsModel v1` 统一 Grid / Alignment / Canvas / Guide 与 bounded candidate 参数。Stretch Anchor 暂不进入 v1，避免重解释现有 Rect Store。
- Transform Inspector：`TransformInspector v2` 只绑定上述 Editor Model/Preview Adapter，并复用 Form/Numeric/Dropdown/Toggle；页面不得为了状态显示、治疗校准、范围辅助各复制一套 X/Y/Anchor/Snap 设置。
- Multi Selection Transform：`MultiSelectionTransformModel v1` 只负责 2+ selected child 的 Group Bounds → Child Rect 映射与原子 Projection Session；Group move/resize/snap 仍属于 Gesture/RectTransform，Feature Store 仍只在外层 Commit 后写入。
- Container Surface Authority：Card / Section / FormSection 均由 RSUI 直接拥有；历史 `UI.ComponentsV2` 已退休，不允许重新进入 Active TOC。
- 选择控件降级必须 fail-closed；Dropdown Popup 不可构建时只读显示当前值与明确警告，不允许偷偷改变为循环切换交互。大量选项的共享搜索/选择状态先进入 `PickerModel`，SearchablePicker/IconPicker 只做 Presentation，不复制筛选 Authority。
- Focus 使用 target-aware capability：是否可 `SetFocus/ClearFocus` 由具体 Native target 决定，禁止全局硬编码“支持”。RU 尚未验证 generic `OnKeyDown/OnKeyUp/OnTextChanged`，Foundation Audit 当前直接禁止 Active Runtime 绑定这三类事件。
- Exclusive Popup Authority：`RSUI.PopupCoordinator` 统一 Dropdown / ColorField / ContextMenu 的 Register/CloseAll/Unregister；历史 `DropdownService` 只作为同一对象的兼容 alias。
- Popup Z Priority 由 `UITokens v4.layer.popupPriority` 统一提供，页面/组件不得继续硬编码独立 priority。
- Focus/Keyboard 能力必须按 RU 已验证事件 fail-closed；当前不假设 generic OnKeyDown/OnKeyUp 或实时文本变化事件。

重要规则：

- UI 默认 Diff Rendering，不用循环重复写相同 Native 状态；
- 大量数据必须 bounded / pooled / virtualized；
- 严格 BuildScope 对 required component 采用 fail-fast，失败 Generation quarantine，不提交半成品；
- Window geometry / appearance 持久化属于统一窗口体系，不允许每个模块复制第二套位置状态；
- 鼠标悬浮、颜色选择、数值设置等可复用交互应优先沉到 RSUI，而不是在业务页重复手写。

详见 [`Architecture/RSUI_ARCHITECTURE.md`](Architecture/RSUI_ARCHITECTURE.md)。

## 10. Persistence

持久化先定义 Lifetime，再决定是否保存：

- Permanent
- Daily
- Weekly
- Session
- Checkpoint

统一采用 Store Contract、Dirty + Debounce、Schema Migration、Write Fence 和失败 rollback。`.18.81` 建立 **Persistence Reliability Contract v2**：保留 `.18.80` 的 Load-before-Write、dirty Reload fence、失败重试、损坏 payload fail-closed、Reload/Runtime durability barrier，并新增 Domain Budget 与 Encoded Envelope Budget 分离以及 `MutateStore()` 原子 mutation transaction。`.18.83` 追加 runtime acceptance diagnostics；`.18.84` 增加只读 `Runtime Acceptance Snapshot`。`.18.95` 升级为 **Persistence Reliability Contract v3**：Critical Store 可 opt-in `SaveData → immediate LoadData → metadata/decode/Domain fingerprint` 回读验证，验证只读不 Apply。`.18.97` 升级为 **Reliability v4 + Integrity v1**：所有新持久化 envelope 写入 `reliabilityContract/integrityVersion/encodedFingerprint`；`.18.98` 再升级 **Reliability v5 Durability Barrier**：v4/v5 Integrity v1 save 均先在任何 custom decode/migrate/apply 之前验证 encoded budget + fingerprint，v4 stamped 数据保持向前可读；`.18.99` 升级 **Reliability v6**：在 business fingerprint 之外增加 metadata Envelope Seal，custom decode 与 migration/period transform 后再次按 Domain budget 检查，`durable=true` mutation 必须 immediate readback 成功才提交，并把 Character Store loaded Domain 绑定 exact world-qualified identity fingerprint；角色切换时旧 dirty/barrier 只可写回 bound old key，禁止投影到新角色。`.18.100` 升级 **Reliability v7**：任何 `needsBarrierVerify` persistent Store 在 durability barrier 通过前禁止普通 `LoadStore()` 重新 Apply 磁盘值；migration/period reset 的 dirty intent 只有在最终 budget + Apply 成功后才提交；Tick 对 terminal/write-fenced dirty Store 不再重复触发 Native Save，只保留失败 evidence 并有界延后。v4/v5 stamped 数据继续向前可读；普通 Store SaveData 成功后只标记 `needsBarrierVerify`，显式 Reload/Runtime Stop 的 `Flush()` 必须对本 generation 尚未证明耐久的 key 进行一次 bounded readback，失败则阻止 Reload 并 requeue 当前健康 Domain，Critical `verifyAfterSave` Store 不重复读取。`ClearStore()` 也必须在 Apply defaults 前证明 `ClearData` 后物理 key 已为 nil。`IsStoreLoaded()` 仅对健康状态返回 true，Core/UI 通用写路径统一使用该语义。Gear 继续作为 Critical Journal Consumer：Index schema 5 + Payload schema 2 使用 compact A/B bank，active 损坏时可回退 verified backup；损坏 inactive bank 只有在 `recoverableReplacement + replaceCorrupt + verifyAfterSave` 全满足时才允许 verified full replacement 自愈，future schema/瞬时读取错误禁止覆盖。历史 pre-v4/legacy shard 保持只读兼容，已物理丢失的旧装备明细仍只能由用户显式“获取当前→保存”重建。公共业务写入仍优先走 `PrepareWrite → snapshot → mutate → MarkDirty/Save → rollback`；Binding/FloatingSurface 的 `MarkDirty` 仅作为已完成 preflight/rollback 的 commit adapter。Feature 关闭不应清除永久用户配置；版本升级必须通过 Normalize / Migration 保持旧配置兼容。

详见 [`Architecture/PERSISTENCE_ARCHITECTURE.md`](Architecture/PERSISTENCE_ARCHITECTURE.md)。

## 11. Static Data / ID

任务、技能、Buff、物品、副本、区域、Boss/NPC、Craft/Product 等共享 ID 必须进入结构化 Registry，不散落在业务模块。

关键原则：

- 不同 ID 命名空间不可互换；
- 不通过编号规律推测未核 ID；
- verified / curated / runtime-observed 必须区分；
- Runtime Instance ID 与静态 Database Zone ID 严格分离；
- 热路径使用预建 exact lookup / index，禁止复杂动态 Tag 匹配。

详见 [`STATIC_DATA.md`](STATIC_DATA.md)。

## 11.1 当前 UI Editor Foundation（`.18.78`）

当前 RSUI 已进入 **v44 / API 12.8**。Interactive Draft Contract v1 在共享 Control 层保护 focused Text/Numeric draft 与 active Slider preview 不被环境刷新用旧 Binding 回灌；Component API Contract v1 统一所有 RSUI Component 的 `Show/Hide → SetVisible` 可见性 facade，并允许 Composite/Workspace 在构建边界通过 `RequireComponentMethods()` 显式验证真实 Public API，避免 Lua 动态方法缺失直到 RU 才暴露。Editor Foundation 已从“独立数学零件”收敛成一条完整、可由业务页面注入持久化边界但不夺取业务 Store Authority 的共享编辑链：

- `SelectionModel`：只回答 **Who**（选中了谁），stable key + revision 是编辑事务的身份边界；
- `SelectionGeometry / SelectionOverlay / LayoutGuideResolver`：只回答 **Where**（Bounds、8-way handle、move surface、grid/sibling/canvas guide）；candidate hard cap=1024；
- `LayoutEditorGestureController v2 + RectTransformTransaction v2`：唯一 editor gesture bridge；复用 RU 已验证 Native capture；Begin 时冻结 candidate 并动态读取单选/多选最小尺寸；Preview 拒绝、sampling 失败或 Commit 拒绝均进入 Cancel/rollback；
- `AnchorPivotModel v2`：point-anchor（9 presets + custom normalized anchor）+ Pivot + anchor-relative offsets；支持完整 Snapshot Restore，使 Persistence 拒绝 Anchor/Pivot 修改时元数据与 Rect 一起回滚；ArcheAge/CryEngine 坐标固定 `左上(0,0), +X=右, +Y=下`；
- `LayoutEditorSnapSettingsModel v1`：共享 enabled/grid/alignment/canvas/guides/gridSize/threshold/maxCandidates；alignment 关闭时 candidate provider 调用次数为 0；
- `MultiSelectionTransformModel v1`：2+ stable-key selection 的 Group Bounds → per-child Rect 投影；ProjectionSession 原子 Commit/Cancel，按 Group scale 映射 Child，并反推出 group min constraints；
- `LayoutEditorPreviewAdapter v1`：Single/Multi 统一事务桥。单选接 AnchorPivot，多选接 MultiSelection Session；selection revision 在手势中变化时 fail-closed；Preview 不写 Feature Store，外部 Commit 明确接受后才 finalize；
- `LayoutEditHistoryModel v1 + Observable Contract v1`：只在成功 Commit 后记录 stable-key before/after command；Preview/Drag Pulse 不入历史；默认 64、hard cap 256；Undo/Redo 的外部 apply 失败时 cursor 不移动并 best-effort rollback；Anchor/Pivot 保存可恢复最小状态快照；成功状态变化通过 Subscribe/Unsubscribe 事件通知 Consumer，无轮询；
- `LayoutEditSessionModel v1`：四态 `Persisted / SessionBaseline / Working / Defaults` 的唯一 Session Authority。`Revert` 只回 SessionBaseline，`Reset` 只把 Defaults staged 到 Working，二者不写 Store；只有 `Apply` 可跨 Persistence Boundary，且 caller 必须在 durable write 明确成功后返回 true。成功 Revert/Reset/Apply 均建立 History barrier；若 durable Apply 后 History barrier 异常则 Session integrity blocked，编辑命令 fail-closed。
- `EditorCommandBar v2`：统一投影 `Undo / Redo / Revert / Reset / Apply` 五个命令状态。Undo/Redo 只读 History Snapshot；Revert/Reset/Apply 只读 LayoutEditSession Snapshot；Busy/blocked 时全部 disabled；组件不拥有 Store/Persistence/dirty Authority。
- `TransformInspector v2`：一个 `rectModel` + 可选 `anchorModel`。单选显示 Transform/Anchor/Pivot/Snap，多选复用同一个 Inspector 实例但折叠 Anchor/Pivot；不复制 Geometry/Persistence Authority；
- `LayoutEditorOverlay v1 + History Binding Contract v1`：只组合 GuideOverlay + SelectionOverlay + Gesture v2 + PreviewAdapter + SnapModel，不创建第二套 Pointer/Rect/Snap/Native capture Authority；Workspace 可把唯一 History 注入 Adapter，Preview/Cancel 不入历史；坐标空间非 viewport 时必须提供 `pointerToLocal`；
- `WorkspaceTemplates v6 / LayoutEditorWorkspace v4`：`Toolbar + EditorCommandBar + PreviewHost + LayoutEditorOverlay + SAME Responsive TransformInspector`。构建时显式校验 ResponsiveInspector/Toggle/Status/Overlay/Inspector/CommandBar 所需 Component API；Compact `[属性]` Toggle 使用共享 `SetVisible`，不依赖 primitive 私有方法。Workspace 自建唯一 bounded History；当 caller 提供完整 `editSession` 五回调时创建唯一 LayoutEditSession，否则维持 history-only 且持久化命令 fail-closed。Undo/Redo 事件只从 Adapter 刷 Presentation；Reset/Revert 后才从 Feature Working 显式回读；root 生命周期同步释放 CommandBar/Session/History listener。Wide inline 与 Compact Drawer 仍是同一个 Inspector 实例，只改变 Geometry/Visibility/Layer，不 reparent、不复制状态；Compact Toolbar 通过稳定 `[属性]` 按钮显式开关该 SAME Drawer。

当前编辑器页面骨架：

```text
Wide / Regular
┌──────────────────────── Toolbar ─────────────────────────┬──────────────┐
│ Selection Status      左上(0,0) · X→右 · Y→下           │              │
├──────────────────── Editor Command Bar ──────────────────┤ Transform    │
│ 撤销 · 重做 · 还原 · 重置 · 应用 · Session Status      │ Inspector    │
├───────────────────────────────────────────────────────────┤              │
│                    PreviewHost                            │ single:      │
│                         +                                 │ Anchor/Pivot │
│                 LayoutEditorOverlay                       │ multi:       │
│                                                           │ Group Rect   │
└───────────────────────────────────────────────────────────┴──────────────┘

Compact
┌────────────────────────────────────────────┐
│ Toolbar                                    │
├────────────────────────────────────────────┤
│ Editor Command Bar                         │
├────────────────────────────────────────────┤
│ Preview + Overlay             ┌──────────┐ │
│                               │ SAME     │ │
│                               │ Inspector│ │
│                               │ Drawer   │ │
│                               └──────────┘ │
└────────────────────────────────────────────┘
```

Editor Foundation 目前仍不直接迁移 Healer/Range 等后续业务页面。`LayoutEditHistory / Undo-Redo → Editor Command Bar → LayoutEditSession → LayoutEditorWorkspace v4` 已形成共享闭环；状态显示在 `.18.79` 完成 UI_APPROVED + Authority Cleanup，`.18.80` 完成本地 `UI_IMPLEMENTING` 接入，`.18.81` 修复 `TreeView=nil` 依赖顺序，`.18.89` 根据 RU 实机反馈补齐 Compact `[属性]` Drawer 与 RSUI Interactive Draft v1，`.18.90` 再根据真实 `Button:Show(nil)` 堆栈补齐 Component API Contract 与 LayoutEditorWorkspace 真构建 Smoke Gate，并恢复此前漏入用户完整包的 Persistence Fresh Reload Snapshot 实现；`.18.91` 将防线扩到全 Presentation Component API 静态扫描、全部 6 类 Workspace 真构建 Smoke 与 RSUI 顶层依赖 TOC 顺序检查；`.18.92` 再补 Presentation→Feature Public API 封包门禁，从真实 Feature provider 自动核对页面/Widget 的直接方法与 `Commands` 调用，并修复 Tasks/Activities 浮窗窗口状态 Command 与 Gear 快捷设置 Reset Command 的真实漏接。 `.18.94` 继续沿 Fresh Reload Gate 增加 Trade/DPS package-coherence 与 UIV3 runtime preflight：DPS WidgetHost lifecycle preference 必须与 durable `widgetVisible` 一致；Trade 页面/HUD 必须保持 Dropdown-only + 显式材料询价，sealed Zone 只提供候选，服务器 `GetSpecialtyRatioBetween` 仍是最终路线 Authority。页面仍为 `追踪管理 / HUD 布局 / 导入导出` 三页签，Tracking 为单虚拟 Table；Aura facts 更新不再重绘 Layout editor，focused Edit draft / active Slider preview 由共享控件层保护。HUD Working 与 Store getter 隔离，Preview/Undo/Redo/Reset/Revert 均不持久化，只有 Apply 执行 Feature durable callback。Store 仍为 schema 4；真实 SaveData 回读与 Native 编辑体验继续以 RU Fresh Reload 为准。

## 12. 性能与生命周期基线

- 禁止无必要 Tick / OnUpdate 常驻；优先事件驱动、Demand-scoped Scheduler、one-shot coalesce。
- 高频逻辑只做 bounded work；昂贵 Native 查询、拍卖查询、Metadata 解析不得在列表刷新循环中 fan-out。
- Consumer `0→1` 是初始化观察的主要边界；`1→0` 必须释放事件、Scheduler、缓存/临时状态中属于该 Consumer 的资源。
- 200 玩家视为正常容量；团队 50/100 人 UI 必须使用固定池、diff、分片或有界刷新，不为每帧全量重建。
- Diagnostics 热路径只累计指标，不刷屏日志。

## 13. 当前验证基线

当前代码 BuildTag：`v3-m1.16.0.18.96-unit-lines-projection-team-role-hotfix`。

当前本地结构门禁基线：

```text
FOUNDATION_AUDIT PASS
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
```

本地静态/纯 Lua 门禁不能替代 RU 客户端 Fresh Reload、Native 构造、字段语义、视觉与多人性能验证。

## 14. 权威文档索引

| 主题 | Authority |
|---|---|
| 当前架构 | 本文 |
| 当前开发状态 / 下一步 | [`CURRENT_REBUILD_STATUS.md`](CURRENT_REBUILD_STATUS.md) |
| 逐版本历史 | [`CHANGELOG.md`](CHANGELOG.md) |
| 工程硬规则 | [`ENGINEERING_RULES.md`](ENGINEERING_RULES.md) |
| Core | [`Architecture/CORE_ARCHITECTURE.md`](Architecture/CORE_ARCHITECTURE.md) |
| Native | [`Architecture/NATIVE_ARCHITECTURE.md`](Architecture/NATIVE_ARCHITECTURE.md) |
| Services | [`Architecture/SERVICE_ARCHITECTURE.md`](Architecture/SERVICE_ARCHITECTURE.md) |
| Persistence | [`Architecture/PERSISTENCE_ARCHITECTURE.md`](Architecture/PERSISTENCE_ARCHITECTURE.md) |
| RSUI | [`Architecture/RSUI_ARCHITECTURE.md`](Architecture/RSUI_ARCHITECTURE.md) |
| Healer | [`Architecture/HEALER_ARCHITECTURE.md`](Architecture/HEALER_ARCHITECTURE.md) |
| Combat Analytics | [`Architecture/COMBAT_ANALYTICS_ARCHITECTURE.md`](Architecture/COMBAT_ANALYTICS_ARCHITECTURE.md) |
| Feature | [`Architecture/FEATURE_ARCHITECTURE.md`](Architecture/FEATURE_ARCHITECTURE.md) |
| Static Data / IDs | [`STATIC_DATA.md`](STATIC_DATA.md) |
| 产品能力完成度 | [`Rebuild/PRODUCT_COMPLETION_MATRIX.md`](Rebuild/PRODUCT_COMPLETION_MATRIX.md) |
| RU 实机验收 | [`Rebuild/RU_RUNTIME_ACCEPTANCE.md`](Rebuild/RU_RUNTIME_ACCEPTANCE.md) |

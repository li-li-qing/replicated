# Replicated Suite 当前架构（总览）

## M1.16.0.18.46 Buff Display Schema 4 / Four-Tab Page

- **StatusClassificationV3 是"效果是什么"唯一 Authority**：用户可见分类只有 buff/debuff；hidden/special_rule 是 detection source（客户端隐藏来源/魔法阵特殊规则），不再是用户分类。解析顺序 = 用户覆盖 → 种子库（Buff ID 库 + Plates 兼容集）→ 快照来源启发式 → 默认未知 hidden 归 debuff。所有 Consumer（Buff Display、Plates、导入导出）共用该服务。
- **BuffDisplay Store schema 4**：tracked 按 `{ buff = {...}, debuff = {...} }` 分类分桶；10 个头顶组件（buffs/debuffs/distance/class/gearScore/mainHand/offHand/ranged/wings/castBar）各带 enabled/x/y/size/fontSize/alpha；schema 1/2/3 无损迁移（历史追踪 ID 经分类服务落桶）。`SetTrackedId(id, category, enabled)` 必须显式传 category，禁止旧 2 参布尔误用。
- **页面四页签 + 行点击 Toggle**：状态追踪（Buff/Debuff/只看隐藏筛选 + 关键词搜索 + 单击行切换追踪）/ 头顶显示（开关 + 图标大小/数量/位置/刷新）/ 布局外观（10 组件卡片，滚动承载，每卡启用 + 5 数值）/ 导入导出（快速 ID 导入合并/覆盖 + 完整导出/导入文本往返）。写入全部经 `Feature.Commands`；"只看隐藏"按 detectionSource=="hidden" 过滤，与覆盖率 Hidden 计数一致。
- **运行时**：Scheduler 支持 1ms 高频 Lane；头顶位置刷新与单位连线可用 1ms 档；Feature Runtime Lane 按组件启停消费数据，Demand=0 释放。
- `UIV3Acceptance v36 / FoundationGate v62`；Acceptance/Foundation 与 Store schema 必须同版本（当前均为 4）。


## M1.16.0.18.45 Product Usability Recovery

- **Presentation Demand 不等于 Feature preference**：Healer calibration 通过独立 Preview Consumer 读取真实 Team/Aura projection；用户可以在治疗功能关闭时只开启校准，结束后立即释放。Buff Head Marker、Trade/Bonds/Treasure/Fishing HUD、Bag Quick Overlay 也各自持有/释放自己的 Presentation Consumer，不以“打开页面”偷启 Feature。
- **BuffDisplay schema 3**：Feature 拥有精确 tracked Buff ID 与 head-marker 用户设置；`BuffHeadMarkersV3` 只消费 detached projection，使用有界图标池显示玩家/目标头顶状态。Aura 观察继续事件驱动并 coalesce；位置刷新独立低频、无 Tick。Acceptance/Foundation 与 Store schema 必须同版本，禁止再次出现 Store 已升级而门禁仍验旧 schema。
- **ScreenProjectionV3 v3**：服务统一 Native screen/world 位置与逻辑 UI space，禁止 Presentation 自己混用物理分辨率。Unit Lines 当前支持 self-target、target-targettarget、self-watchtarget、watchtarget-watchtargettarget 四条可开关关系；Range Assist 仍只承诺用户指定自身半径，不猜技能半径。Feature 拥有 50–1000ms/有界采样节奏，Service 自身无 Scheduler。
- **Team Auto Role**：职业组合→职责为静态 exact catalog；Team/AbilitySet 变化时只为当前玩家调用 `SetRole(role)`。全队角色读取和当前玩家角色写入严格分权，任意成员改职责任然不是已证明能力。
- **Life economy widgets**：Trade/Bonds/Treasure/Fishing 均有独立 FloatingSurface；Trade Widget 可直接选择路线，Treasure/Fishing 不再依赖主页面常开。路线候选可以使用 sealed zone 目录兼容 RU getter 形态，但真实 ratio 仍只认服务器结果。
- **Bag task ownership**：`tools.bag` 的原生背包跟随 Quick Overlay 只提供“取同类/放同类/停止”；类别批量整理是另一条受控任务。两类 Scheduler 互斥，仓储关闭/切换、Feature Disable、任务创建失败都必须 Force Stop。Presentation 不直接移动物品。
- **AuctionQueryV3**：无 token 的 `AUCTION_ITEM_SEARCHED` 只能由该 Service 订阅。所有当前挂单查询统一走 9 参数 Search、单 pending、超时/限流与 detached requester snapshot；收藏/行情只是 Consumer。当前挂单事实不能升级成历史成交事实。封包 Audit 对该事件 Authority 做单一所有者检查。
- **Craft UX boundary**：用户选择已核制作物，内部解析 CraftID/ItemID；raw id setters 只留兼容/诊断，不是产品入口。市场材料报价仍走显式 Auction quote/query，不允许普通 Refresh 批量服务器请求。
- `UIV3Acceptance v35 / FoundationGate v61`；Product Matrix 125 条：77 Implemented / 35 Partial / 2 Todo / 11 Runtime Blocked。


## M1.16.0.18.44 DPS Skill Proxy Source Classification

- **Actor Authority 修复**：DPS Domain v7 不再把“玩家放置技能实体”直接按 `sourceName` 建立玩家排行 Actor。新增 `CombatSourceProxyCatalog v1` 以 O(1) 精确索引描述此类代理源；首个已核 family 为“治愈之泉”11948 / 41224 / 41225。
- **归属严格 fail-closed**：当前 bundled RU API 没有可靠的通用“放置技能实体 → 施放玩家”owner link。即使观察到本机施法，也不能证明随后同名 proxy heal 一定来自自己的实体（团队中可同时存在其它玩家的治愈之泉）。因此代理 source **不归并给任何玩家**，直到未来获得显式 owner identity；禁止按目标、距离、时间、最近施法者或“当前只有一个已观察候选”猜主人。
- **关系边界**：代理事件在进入 CombatRelation 前被截断，不调用 `ApplyKind/RecordCombatFact`，避免把“治愈之泉”学习成 PLAYER/FRIENDLY 单位。DPS 仍保留事件量与治疗量到 `proxySourceHeals / proxySourceHealAmount`，页面以“技能代理未归属”明确显示，不静默吞掉。真实 `sourceName=玩家` 的同技能 Combat Fact 仍按玩家正常统计。
- **热路径边界**：代理目录为预建 exact lookup；无 Tick、无 Native cast 监听、无 Native 扫描、无复杂 Tag 匹配。`UIV3Acceptance v33 / FoundationGate v59` 门禁该契约。

## M1.16.0.18.43 Combat / Life Usability Recovery

- **Presentation density**：DPS / DeathReview 默认把高级设置和诊断折叠，主纵向空间归还排行、明细和死亡时间线。Healer 页面不再创建推荐名单/详情表；`combat.healer` 推荐 Floating Widget 从 Active TOC 删除。历史 `widgetWindow` Store 字段只为升级兼容保留，不代表 Active Presentation capability。
- **Healer calibration boundary**：Raid Overlay 的 calibration 是 Presentation-only 模式，可以在 Feature disabled 时独立显示 4 个团队区域，且 `consumerHeld=false / taskActive=false`；Live overlay 才通过一个 Presentation Consumer 读取已提交的推荐/颜色事实。校准与 live 模式切换必须先释放旧资源再获取新资源。
- **Dynamic status facts**：BuffDisplay 只在 Consumer 存在时订阅 `BUFF_UPDATE/TARGET_CHANGED`，Buff burst 使用 120ms one-shot coalesce；关闭后事件和任务归零。UI 必须区分 unavailable 与 empty，不能把 API/coverage 失败显示成“没有状态”。
- **Alert presentation**：`AlertsService` 仍是共享短生命周期 Alert 状态；新 `AlertHudV3` 是纯 Presentation。Boss Feature 只拥有机制说明、HUD 用户设置与显式测试命令；自动 Boss 触发必须来自未来已验证的 cast/Aura fact bridge，禁止聊天文本猜测。
- **ScreenProjectionV3**：共享只读投影服务集中治理 `GetUnitScreenPosition`、`GetUnitWorldPositionByTarget`、可选 `ConvertWorldToScreen` 与 Camera fallback。批量世界点使用 `ProjectWorldBatch()` 一次捕获相机 basis；服务本身没有 Tick/Scheduler，采样节奏归 Feature Demand。
- **Combat Visual Guides**：`combat.unit_lines` 当前只承诺“自己 ↔ 当前目标”，`combat.range_assist` 当前只承诺用户指定自身半径；两者分别以 100ms/200ms Demand Scheduler 更新 detached projection，`CombatVisualGuidesV3` 只渲染最多 48 点/层。附近单位枚举、技能/魔法阵自动半径仍不猜测。
- **Life economy HUD**：Trade/Bonds 通过 Feature 公共 `GetProjection/Commands/GetWidget*` 注册独立 FloatingSurface；Widget 自己 Acquire/Release Consumer，主 Page 关闭不等于 HUD 关闭。Trade 地区 normalization 接受 RU boolean-set 返回，但 fallback 只生成可选目的地，服务器 ratio 仍是路线真实性 Authority。
- **Truth gate**：UIV3Acceptance v32 / FoundationGate v58 要求上述 runtime surface 真正注册；产品能力 Matrix 以 RU 负面证据降级相关能力，不用“本地代码存在”冒充实机完成。

## M1.16.0.18.42 Business Page Logical Identity / Strict Build Fail-Fast

- Active Business 共享页的 logical component id 必须在 route id 展开后仍唯一；`tools.social` 曾同时生成通用 `v3_business_tools_social_actions` 与同名 Social 专用 Row，RU 因此在 Native allocation 前触发 Preflight。Social 专用容器现使用独立 `v3_business_tools_social_member_actions`，封包静态 Audit 会展开 Registry route id 检查动态/固定 ID 冲突。
- Strict `RSUI:WithBuildScope()` 现在对非 `buildOptional` 组件采用 first-failure fail-fast：组件 Factory/Preflight/Native 创建任一失败立即终止 Page/Widget/Modal 构建，不允许 nil parent/control 继续传播并制造二次 Lua 异常。`buildOptional=true` 是唯一显式降级通道。
- BuildTransaction 诊断以第一个 `scope.failure` 为主因；callback 后续异常只作为 secondary context。这样事务回滚/Generation quarantine 继续保持 fail-closed，同时实机故障摘要直接暴露真实 component id/reason。

## M1.16.0.18.38 Life Feature Projection / Page Preflight

- Trade / Bonds / Treasure / Fishing 的 Active V3 Presentation 统一只消费 Feature 公共 `GetProjection()` + `Commands`；Bonds/Treasure/Fishing 不再只有 Authority 级投影而缺少 Feature facade。
- M1.16 生活共享页面在创建 `PageRoot` 之前验证 exact Feature read-model / Consumer / Command 契约。契约漂移直接 fail-closed，不等到 `OnActivated()` 才以 nil method 破坏导航事务。
- `UIV3Acceptance v27` 将四个生活 Feature 公共契约纳入 Foundation Matrix；`FoundationGate v53` 要求该 Acceptance 版本。页面 Factory 注册成功不再单独视为生活页面契约完成证据。

## M1.16.0.18.27 Foundation Gate / BuffDisplay Schema Parity

- Foundation Gate 的 BuffDisplay 合同现在要求 `v3.buff_display` Store schema 2，与 Store/Feature Acceptance 保持同一迁移事实；避免代码已升级而基础门禁仍按 schema 1 误报 blocker。
- 修复后重新执行 Foundation Audit 与 24 个本地 Harness，均通过；RU Fresh Reload 仍是运行时页面/Native 证据的必要条件。

## M1.16.0.18.26 Detached Floating State / BuffDisplay Persistence

- FloatingSurface 的 getState 可以只返回 detached snapshot；需要写回时通过可选 setState(snapshot, reason) 回到 Feature Commands。Surface 和 CreateStateAdapter 都在持久化回调失败时恢复旧 snapshot，不把 Presentation 变更遗留在 Feature 内存中。
- Activity、Task、DPS、DeathReview、BuffDisplay、Healer 的 Floating Widget 已使用 Feature.Commands:SetWidgetWindowState()；Presentation 不再把 Feature 的 live widgetWindow 子表交给公共 UI 适配器。
- BuffDisplay Store schema 2 复用 FloatingSurface:NormalizeState()，不再因旧矩形专用 Normalize 丢失锁定、最小化、透明度或字号状态；schema 1 仍可迁移。

> **Authority Level**: CURRENT
> 这是“系统现在长什么样”的落地总览。细节按域查 `Architecture/*.md`；重建方向查 `Rebuild/REBUILD_BLUEPRINT.md`。

## M1.16.0.18.17 Floating / Combat Analytics Stability

- Floating 外观设置只允许走 `WindowShell -> FloatingSurface -> Feature Store`；业务 Widget 不再自建第二套透明度/字号编辑器。窄 HUD 使用 NumericInline v3 让 Slider 拖动面积优先于短标签和精确输入。
- Combat Analytics Presentation 只消费 Feature detached value-selector model；`VALUE_OPTIONS` 保持 Feature 私有，所有用户写入继续走 `Feature.Commands:SetSelectedValue`。


## M1.16.0.18.18 Foundation Regression Gate 补充

- Active V3 的页面/Widget/Modal 构建默认使用 `RSUI:WithBuildScope()`；业务 Host 不再手动承担 Begin/End 配对。仅 ComponentCore、WindowShell、MainShell 等少量底层 builder 允许 raw BuildScope，并由静态审计白名单锁定。
- 当前已迁移 Presentation 路由由 `UIV3Acceptance.migratedPresentation` 维护单一矩阵；Foundation Sequence `v3_37_migrated_page_build_matrix` 会在客户端实际导航构建 13 个页面，并遍历 FeatureRegistry 当前 39 个 Active Route（planned 路由走 fallback），同时对 7 个悬浮窗执行 `WidgetHost:EnsureInstance()`。注册存在不再被当作页面构建成功的替代证据。
- `RSUI:ValidateSpec()` 是 Native allocation 之前的 Definition Fence；公共组件先验证 identity/parent 与组件专属结构，再进入 Factory。NativeObjectFactory 仍是唯一 C++ Widget constructor Authority。
- Presentation 的代码边界新增封包级 bytecode/source audit：Active Presentation 不允许意外 `_ENV` 全局、`X2Unit/X2Team`、`Feature.State/Authority` 或 `Store.State` 直连；Feature 必须输出 detached Projection/Commands。
- Build transaction 的“回滚”不伪装成 Native Destroy；RU 无可靠 DestroyWidget 时仍以 Generation quarantine 为最后安全边界，但前置 Preflight 要尽可能让错误发生在第一个 Native allocation 之前。
- Persistence 的本地迁移回归覆盖 empty/N-1/future schema/metadata mismatch/显式空表/cyclic payload；写保护与迁移失败仍由 Persistence Framework 统一裁决。
- AuraObservationV3 / HealerAuraBridge 的 Tooltip 缺失路径已修复 Lua 5.1 nil 截断，StatusMap 继续优先使用已捕获 Data Row；共享事实层不把 Tooltip 缺失误报成 Aura 字段不存在。
- RU 日志曾证明 `Theme:StyleLabel` 把字符串对齐值直接交给 Native `SetAlign`；共享 Theme 现在统一归一化 `left/center/right/top-left` 为数值常量，修复后本地 alignment contract 为 `4/4`，但修复后的 Fresh Reload 仍待实机确认。

## M1.16.0.18.19 Presentation Boundary / Read-only Features 补充

- 已迁移矩阵现覆盖 13 个专用页面关联、7 个悬浮窗和两个实际 Modal；`v3_37_migrated_page_build_matrix` 负责页面/悬浮窗，`v3_39_modal_build_matrix` 负责任务详情与换装设置 Modal 构建，并对换装 Modal 执行 Open/Close 栈回归。
- 新增 `life.housing`、`life.butler`、`tools.random_shop` 窄只读 Feature，均按页面 Consumer 按需读取已登记 getter，输出 detached ready/partial/unavailable 状态，不推断未证实字段、不执行写操作或后台轮询。
- 本地最终 Foundation Audit 为 `TOC 182/182`、Active Lua `182/182`、全 Lua `338/338`；23 个本地 Lua harness、Presentation boundary `34/34` 均通过。PageHost 导航现在对旧页停用后的 Switch/Activation 失败执行恢复；WidgetHost 生命周期回调有逐绑定错误隔离；Feature Demand 与 QuestProgress/InstanceCatalog Service 均提供强制静默清理；Activity/Task 表格列使用 fill + absoluteMinWidth；上述序列和真实 RU 字段/视觉仍待 Fresh Reload。

## M1.16.0.18.24 Presentation Private-Field Fence Follow-up

- Foundation 页面持久化绑定不再从 Feature 实现对象读取 `StoreId` / `IndexStoreId`，活动窗口策略不再读取 `WidgetWindowSizePolicy`；稳定 Store ID 保留在 Presentation 绑定契约中，窗口策略通过公开 Feature getter 输出。
- Foundation Audit 与 Presentation boundary Harness 已覆盖 `S.Features.<Feature>.<private>` 访问形态；当前本地证据保持 `182/182 + 338/338`、23 个 Harness 全绿、boundary `34/34`。这仍不替代 RU Fresh Reload 的真实页面构建与交互。

## M1.16.0.18.25 Active Presentation Command Fence Follow-up

- Foundation/Gear HUD/Gear Snap Modal 的 Feature 写入统一走 `Feature.Commands`；Activity/Gear/Instance/Buff 的刷新、显隐、尺寸、Snap 与外观设置不再绕过 Command facade。
- Gear QuickHud 的公开读取通过 detached `GetQuickHudProjection()`，避免 Presentation 持有并修改 Feature 内部状态表；本地 Foundation Audit 与 23 个 Harness 保持全绿。

## 1. 形态与阶段

- 单一公开 Addon：`globals` + `replicatedsuite` + `z_api_functions`（发布白名单见 `CORE_ARCHITECTURE.md` § Public Release 约束）。
- 架构模式：`v3_rebuild`。**Active TOC 只加载 V3 Application/Presentation Host**；Legacy/Professional 源码仍随包保留用于行为、数据和迁移参考，但不属于当前正常 Runtime。已迁移 Feature 由 `FeatureRuntime` 管理独立生命周期。

## 2. 加载模型

- 引擎按 **目录树 + `toc.g`** 加载 addon；**无** `require`/`dofile`/`loadfile`。
- 文件在顶层自注册（如 `S.Services.Alerts = {...}`）；专业模块首行 `ReplicatedSuiteModuleSandbox:Enter(id, {...})` 进入隔离 Lua 环境。
- 含义：判断“是否还在用”必须查 `toc.g` + 自注册路径 + 运行时引用，**不能**凭文件名。

## 3. 分层（自上而下）

```
V3 Application Shell + Router + Page/Widget/Modal Hosts
        │
FeatureRuntime + migrated/active Feature Modules（Activities / Tasks / Instance Browser / Gear / DeathReview / DPS / CombatAnalytics / RaidReadiness / Healer / BuffDisplay Domain + Presentation）
        │   └─ Healer Page/Head Marker/Raid Overlay 已迁；推荐列表 Floating Widget 已从 Active Runtime 删除，校准色块可独立运行且不获取 Healer Consumer；Domain 复用 TeamRosterV3 + AuraObservationV3
        │
Shared Services（QuestProgressV3 / InstanceCatalogV3 / AuraObservationV3 v2 / UnitIdentityV3 / CombatEventBusV3 / TeamRosterV3 / CombatRelationV3 / SkillMetadataV3）
        │
Shared Runtime Foundation（Demand / RefreshCoordinator / Scheduler / Events / Observation）
        │
Core Foundation（Bootstrap / Persistence / Diagnostics / FrameBudget / Native Identity / RSUI Windowing + WindowShell + FloatingSurface + ViewState + ActionRunner + Persistent Binding）
        │
Native Foundation（NativeObjectFactory / Write Fence / Strict Native Authority）
```

## 4. 关键子系统（权威文档索引）

| 子系统 | 权威文档 | 一句话 |
|--------|----------|--------|
| 产品/模块/UI/HUD/Runtime/API/Engineering | `Architecture/CORE_ARCHITECTURE.md` | v1/v1.1 已确认的产品与底层规范全集 |
| Native Identity / Object Factory / Crash Guard | `Architecture/NATIVE_ARCHITECTURE.md` | 逻辑↔物理 ID 投影、构造/写入栅栏、fail-closed |
| 服务 / Demand / Refresh / Aura / Combat Facts | `Architecture/SERVICE_ARCHITECTURE.md` | V3 Shared Service、Consumer Lease、RefreshCoordinator、Aura Facts、UnitIdentity 与 CombatEventBus |
| 持久化 | `Architecture/PERSISTENCE_ARCHITECTURE.md` | 五 Lifetime、Store Contract、Write Fence |
| RSUI | `Architecture/RSUI_ARCHITECTURE.md` | UMG 风格 Widget 基础层；Windowing/WindowShell/FloatingSurface 管窗口契约，ViewState/ActionRunner/Persistent Binding 已成为 Active V3 的标准数据状态、操作边界与设置持久化路径 |
| Healer | `Architecture/HEALER_ARCHITECTURE.md` | Domain/Runtime/Glue/Roster/Settings/V3 Presentation |
| Combat Analytics | `Architecture/COMBAT_ANALYTICS_ARCHITECTURE.md` | 单 all-scope Consumer + Metric Registry；击杀/控制/乐器/Aura/Encounter 等独立生命周期 |
| Feature 分类 + 专业要点 | `Architecture/FEATURE_ARCHITECTURE.md` | Plates 等历史架构审计 + Feature 契约 |
| 静态 ID | `STATIC_DATA.md` | 身份命名空间与当前核验基线 |

## 5. 导航与信息架构

- `features/rs_feature_registry.lua` 是当前 Feature 元数据 Authority；`presentation/v3/navigation/rs_v3_router.lua` 是 V3 semantic route Authority。
- 战斗底座在 M1.15.2H2 建立、M1.15.6–M1.15.7 继续硬化，M1.16.0 升级为 Combat Analytics：`CombatEventBusV3 v6` 仍是 COMBAT_MSG/UNIT_DEAD_NOTICE 唯一 V3 Combat Fact 入口；Core `Events v3` 在原 required Native 注册事务上增加 Optional Native Event，增强事件失败只降级而不阻断 Foundation，Required/Optional Topic 属性由当前已提交 listener 集合计算。`CombatAnalyticsV3 v3` 只持有一个 `scope=all` Consumer，并按预编译 fact/native plan 分发到独立 Metric；DPS 通过隐藏 `dps_core` adapter 复用入口，PVP/PVE/Relation Replay/Shared Heal Ledger 与技能代理归属仍由 DPS Domain v7 负责；DeathReview 继续独立 `scope=self`。公开 Analytics Metric 包含 Encounter、击杀/助攻/死亡、技能/起手、爆发/生存、控制、乐器、辅助技能活动、Aura uptime、Boss 机制。所有 Metric Session 状态有界且可独立启停；关闭后释放自己的缓存；M1.16.0.1 进一步规定空 Metric Consumer 不得驻留，公开指标全关时 Feature 必须释放自身 all-scope Lease。Encounter 只有 damage/heal/death 能开战或续战，并同时用事件 gap 与 8 秒 one-shot 防止 Scheduler 延迟合并两场战斗；History 只保存 20 场紧凑摘要。演奏时长只有 START+STOP 都可用时才计算；控制/Aura 时长只来自观察到的 apply/remove，当前 open interval 可在 Projection 实时展示。M1.16.0.11 增加 bounded Actor Drilldown Projection；DPS 的技能 ID 只保存事件语义可信值，`SkillMetadataV3` 仅在 UI 明细路径懒解析 X2Skill 名称/Icon，并使用 512 上限缓存，禁止进入 Combat 热路径。完整契约见 `Architecture/COMBAT_ANALYTICS_ARCHITECTURE.md`。
- 一级分组：首页 / 战斗 / 生活 / 工具 / 系统；已迁移页面由 V3 PageHost/WidgetHost/ModalHost 只消费 Feature Projection/Commands；Presentation 不应直接触达 Store/Demand/Authority 内部对象，Domain 也不直接控制 WidgetHost —— Feature 生命周期统一经 `v3.feature.lifecycle` 由 `WidgetHost:BindFeatureLifecycle` 在 Presentation 侧反应。
- Native API Import（M1.16.0.18.37）：Feature 继续声明 method-level capability（例如 `X2Friend:GetFriendList`），`NativeImports v3` 只在 Initialize 时将其映射到 Suite-owned namespace contract（`FRIEND`/`AUCTION`/`STORE` 等）后调用 `ImportAPI`。Active Feature 不能把 load-time `rawget(_G, "X2*") == nil` 当永久不可用；所有 governed Call/Action 由 `S.Api:ResolveCapabilityHost()` 在调用时解析 lazy-loaded host。Feature import failure 只 fault 自身；Foundation import failure 才阻断全局 Native Foundation。
- 业务迁移真实性（2026-08-31 / M1.16.0.18.39）：Feature 有页面/Commands 不等于业务完成；Registry 必须区分 `migrated_partial`、`runtime_blocked` 与已完成能力。Trade/Bonds/Treasure/Fishing 仍是独立垂直切片，其余业务可经 bridge + 通用 V3 page 接入，但普通页面打开不得自动 Enable 用户已关闭 Feature。Runtime Blocked/Partial 必须暴露当前可用能力与 remainingCapability；缺少 RU 参数/权限/返回契约时 fail-closed，不猜测字段或执行写入。cooldown-bound/server-query API（例如 Auction 报价）不得从普通 Refresh 的列表循环 fan-out，必须进入显式限速查询 Authority。
- Demand Observation / API pacing（2026-08-31 / M1.16.0.18.40）：Active V3 Presentation 不得直接 `FeatureRuntime:Enable/Disable`，用户偏好只经 `SetPreferredEnabled` 改变，页面生命周期只拥有 Consumer Lease。Acquire 的 `0→1` 是初始 read/observation 的唯一 Authority，不允许页面随后再做一次重复 Refresh。需要动态变化的只读能力必须声明 Observation contract 并以 Event + 共享 Scheduler 按需运行：Target/Treasure 为 500ms 低频采样，Fishing 的高频 Buff edge 合并为 100ms one-shot；Consumer=0 后事件/任务必须全部释放。`ApiCapabilities.Cooldown` 由 `S.Api` 中央执行，不允许每个 Feature 自己选择是否遵守原生 cooldown。
- Action Direction / Specialized Persistence（2026-08-31 / M1.16.0.18.41）：库存移动必须显式区分 `source container` 与 `target policy scope`，禁止用目标容器替代源槽读取；异步批量任务的 Scheduler 创建、取消和 Feature Disable 都属于同一可释放生命周期。Team role 的读取契约允许 `(teamIndex, memberIndex)`，写契约只按 bundled `SetRole(role)` 定义为当前玩家职责，不把读索引虚构成写参数。Activity/Tasks 等专用 Feature 的配置 mutation 必须采用 `snapshot -> mutate -> MarkDirty -> rollback on failure`，不允许 UI 内存态先成功而永久 Store 写入失败。动态 Buff 数量观察使用事件合并 one-shot，不允许 Tick。
- M1.16.0.14 新增 `combat_raid_readiness` 作为 Aura Phase 12B 首个按需 Consumer：页面只维持 TeamRoster 轻量租约；显式运行检查时分片读取职责/装分/距离，只有配置关键 Buff ID 时短暂 Acquire AuraObservation。Aura v2 提供纯事实 `GetStatusMap/EvaluateRequiredEffects`，不拥有团队通过/失败业务结论；未知 Native/扫描覆盖必须显示“待确认”。
- M1.16.0.15–M1.16.0.18.3 完成 Healer Aura Bridge → V3 Domain Runtime → Page/Floating → Visual Consumers → Advanced Editors/Build Fence：`combat_healer` 已注册 FeatureRuntime 实现，Roster 复用 TeamRosterV3，Health/Status 由 Suite Scheduler 以 20/8 分片运行，Recommendation 保持评分/规则/距离/滞回 Authority；Aura 共享事实不完整时只走准确性 fallback。V3 Page/Floating/Head Marker/Raid Overlay 全部只经 Feature Projection/Commands 取数；Head 的 50ms Visual Task 只做 Feature-side ScreenProjection + Diff，Raid 静态模式事件驱动且 4×25 槽位预分配，动态效果才建立 100ms 视觉任务。高级编辑器已通过同一 Store Command/Normalize/MarkDirty 写入；严格 BuildScope 对非可选组件失败拒绝 Commit 并回滚。**Professional Healer 整包仍未接回 TOC**；当前剩余是 RU Fresh Reload、保存回读与视觉交互验收。
- M1.16.0.18.1 对 V3 UI Foundation 做 Recovery：所有 TableView 仍共享同一 DataView Authority，`NormalizeColumn` 的同步字段只读当前 column，只有 Native 延迟 callback 才捕获 iteration-local `columnRef`；Generic WindowShell 的 BuildScope 成功/失败均必须闭合，禁止把构建事务遗留到下一 Page。NativeImports v2 / NativeObjectFactory v3 增加 Optional negative cache 与 ImportObject result fence；运行期 DataView/Scrollbar 显隐只能经过 `UI:SetVisible` Strict Write Fence。
- M1.16.0.18.13 进一步收口 Active V3 Presentation mutation：Page/Widget 的 Feature Binding setter 与 Store dirty 写入统一经 Feature `Commands` facade；读取仍走 Projection/getter，生命周期仍走 Feature lease，Domain/Store 的 Normalize、rollback 与持久化协议不变。
- M1.16.0.18.14 统一 HUD 交互：FloatingSurface 的公共 Chrome 默认 compact-minimize 为小方块；有限范围 Numeric 通过 `CompactNumericSetting` 复用 Slider+精确输入的单一 Binding Authority。Healer 设置面改为紧凑网格/策略与显示分组，Raid Calibration 背景仍只属于 Presentation；DeathReview 单条删除进入 Feature Command + Store transaction；Activity/Task HUD 详情进入独立 session FloatingSurface，主 Page 仍可继续使用 ModalHost。
- M1.16.0.18.15 继续收敛 HUD Chrome：所有 FloatingSurface 默认只在标题栏增加轻量“外”入口，外观面板首次点击才构建，透明度/字号最终仍通过 WindowShell→FloatingSurface state/persist 单 Authority；Activity TableView 的滚动条改为 overlay、列宽随 viewport 重算，不再为滚动条保留黑边；Combat Analytics 排行 value 改用 Feature Command 驱动的 SegmentedSelector，Presentation 不持有第二份选择状态。
- M1.16.0.18.16 修复窄 HUD 外观 NumericRow 的空间分配：`NumericInlineContractVersion v2` 允许紧凑 Consumer 配置 label/input/slider minimum 与 label share；Floating Appearance 使用更窄的两字标签与精确输入，把剩余宽度优先交给 Slider，普通设置页继续保持旧默认下限。
- M1.16.0.18.3 扩展该构建契约：Page/Widget/Modal/Main Shell 的严格作用域遇到非 `buildOptional=true` 的 RSUI 组件失败时不得提交半成品；Host 检查 `EndBuildScope(..., true)` 结果并对失败页面/悬浮窗做 Generation quarantine。表单关键控件在构造阶段向上传播失败，只有显式可选控件允许降级。
- M1.16.0.18.4 开始 Plates/BUFF 的第一条 Active V3 消费路径：`combat.buff_display` 只经 `AuraObservationV3:GetStatusMap()` 读取 player/target Buff、Debuff、Hidden 事实，Feature Demand 管理唯一 Aura lease，Page/Widget 只消费 bounded detached projection；Legacy Plates Runtime 仍不在 Active TOC。
- M1.16.0.18.5 将 Legacy Plates 的重要冷却、魔法阵候选、目标装备状态与计时修正登记为 `GameDataRegistry` 语义集合；集合保留 `curated / verified=false`，Legacy 消费端不再重复维护这些 ID，且不因此把 Legacy Runtime 接回 Active TOC。
- M1.16.0.18.5 同时为 Legacy Plates Manager/Storage/Runtime 暴露只读 Diagnostics Facade；Suite 摘要可观察目录、发现/捕获 staging、分片、Dirty、write fence、FrameBudget 与关系集合计数，诊断读取不执行持久化 API或新的 RU 扫描。
- M1.16.0.18.6 收紧 V3 Visibility Authority：BuildScope rollback、Owner Release、重复注册拒绝和 Primitive degraded 隔离统一经过 `UI:SetVisible()` / `SetEnabled()` / `SetPickable()`；`false` 的 Diff cache 无变化/拒绝语义不再被上层误判为原生 `Show(false)` 旁路许可。
- M1.16.0.18.8 收紧 Active V3 Presentation read model：Page/Widget 不直接访问 `Feature.State`；窗口几何、Activity/Task 行数与显隐偏好、Task 作用域和 Gear 方案计数通过 Feature getter 获取，显隐写入通过 Commands；新增 boundary Harness `12/12`。更深的 Authority projection 拆分仍按各业务域独立推进。
- M1.16.0.18.9 收紧 Activity/Task Projection boundary：Page/Widget 不直接持有 `Feature.Authority`；rows/summary/lookup/widget projection 经 Feature getter，刷新/隐藏/恢复/展开经 Commands，且 Activity 手动刷新与脏事件刷新保持不同扫描语义。
- M1.16.0.18.10 将同一边界扩展到 Gear、Instance Browser、Raid Readiness：Active Page/Widget 只使用 Feature Projection/Commands，Gear 操作与 Raid Readiness 的取消扫描/Aura 释放仍由 Feature 统一拥有。
- M1.16.0.18.11 收口 Factory Reset/P0 persistence contract：Suite-owned keys 由 `Persistence:GetPersistentKeys()` 纳入，Plates Aura Library 的 manifest 与 `a/b/c × 32` bounded shards 显式清理，reset 后旧 generation 通过 fence/quiesce 防止回写；`GetEffectIds` 只保留一个 Authority，Alerts 使用 full-scan mode。
- M1.16.0.18.12 收紧 Healer Presentation mutation boundary：规则、Tracked Buff、颜色、布局、Roster 刷新、Persistent Binding setter 与 widget dirty callback 均经 `v3.healer.Feature.Commands`，Store 继续拥有 Normalize/MarkDirty rollback，Presentation 只消费 Projection/Commands。
- M1.16.0.2 起，V3 Design Root 支持 `id` 或 spec table 两种兼容入口；可选 Native 控件（例如 RU Build 的 EditBox）必须 fail-open，单个可选控件不可让整个 Page Factory 失败。用户触发的路由失败必须进入 Diagnostics + Toast/状态栏，禁止再静默返回 false。
- Legacy UI/Professional 源码不在 Active TOC；禁止新功能回写 Legacy Presentation。

## 6. 性能基线

- 约 200 玩家为正常容量；共享 Observation + Domain Authority 分离；订阅驱动；FrameBudget 软准入 + Starvation Protection；大量数据虚拟化。详见 `CORE_ARCHITECTURE.md` 与 `RSUI_ARCHITECTURE.md`。

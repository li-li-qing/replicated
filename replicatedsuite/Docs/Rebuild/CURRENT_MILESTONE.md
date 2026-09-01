# Replicated Suite 当前重建里程碑

- **Product Usability Recovery（M1.16.0.18.45）**：恢复用户明确指出的旧版高价值能力：真实团队校准、Buff 头顶追踪、四类目标/焦点连线与刷新频率、逻辑坐标范围圆、自动职责、Trade/Treasure/Fishing HUD、Craft 去 raw ID、Bag 原生窗口取放、Auction current-listing 查询；同时以单一事件 Authority/任务互斥/Store schema parity 门禁防止“看起来能用但运行态不真实”。`UIV3Acceptance v35 + FoundationGate v61`。
- **DPS Skill Proxy Source Classification（M1.16.0.18.44）**：RU 实机证明“治愈之泉”是玩家施放的 60s 技能实体，却被 DPS 以 sourceName 当成独立玩家。DPS Domain v7 现在先查 `CombatSourceProxyCatalog v1`；当前无可靠 proxy→caster owner API，因此技能实体不再进入玩家排行/CombatRelation，也不按最近施法者猜主人，而进入显式“技能代理未归属”统计。无新增 Native consumer。`UIV3Acceptance v33 + FoundationGate v59`；产品能力计数不因本次 correctness hotfix 改变。
- **Combat / Life Usability Recovery（M1.16.0.18.43）**：按 RU 实机负面证据恢复产品可用性：DPS/DeathReview 默认折叠高占用设置；Healer 删除推荐悬浮窗与页面名单、standalone 校准独立显示团队色块；BuffDisplay 补事件观察；Boss 接入共享 Alert HUD 与测试；Unit Lines/Range Assist 收缩为可证明的当前目标连线/用户半径圆；Trade/Bonds 新增独立 FloatingSurface，Trade 兼容 RU boolean-set zone payload。`UIV3Acceptance v32` + `FoundationGate v58`，Foundation Audit `190/190 + 346/346` 与 5 组定向契约 PASS；RU Fresh Reload 仍是视觉/字段最终证据。
- **Business Page Logical ID / Strict Build Fail-Fast Recovery（M1.16.0.18.42）**：RU Fresh Reload 已证明 `tools.social` 的通用工具条与专用操作 Row 展开为同一 logical id，形成 `preflight=3 / Native failure=0 / page quarantine=1`。专用 Row 已改唯一 ID；ComponentCore strict BuildScope 对 required component 改为 first-failure fail-fast，并保留第一组件失败原因为诊断主因；静态 Foundation Audit 新增 Business route-expanded ID 冲突扫描。故障注入与 required/optional BuildScope 行为测试均 PASS；`UIV3Acceptance v31` + `FoundationGate v57`，RU Fresh Reload 待最终关闭 blocker。
- **Life Projection Contract Recovery（M1.16.0.18.38）**：修复 RU Fresh Reload 暴露的 M1.16 生活共享页面契约漂移。Bonds/Treasure/Fishing 现在与 Trade 一样通过 Feature 公共 `GetProjection()` 输出 detached read model；页面在 PageRoot/Native allocation 前验证 exact Projection/Consumer/Commands 契约。`UIV3Acceptance v27` + `FoundationGate v53` 防止“Factory 已注册但 Feature facade 缺失”继续绿灯。专项故障注入 4/4、Native allocation 0，Foundation Audit `186/186 + 342/342` PASS；RU Fresh Reload 仍需逐页验证四条生活路由。
- **Foundation Runtime Import / Authority Recovery（M1.16.0.18.37）**：修复 RU Fresh Reload 暴露的 method capability→namespace Import 错配、lazy-loaded X2 host 的 load-time nil 捕获、Bag 虚构 capability metadata、Gear Quick HUD acceptance spec 漂移，以及 strict Authority cache-hit 对 addonScale 的二次缩放。Native Feature import failure 现在与 Foundation failure 隔离；Foundation 摘要会输出 matrix 首批失败标签与 authority field 分布。本地 Foundation Audit `186/186 + 342/342`、34 Feature Initialize mock 全通过；RU Fresh Reload 是关闭本轮 blocker 的唯一证据。
- **Craft Recursive Known-Record Graph（M1.16.0.18.36）**：Active Craft 对已返回且字段完整的 recipe records 暴露有界递归图；按产物批量数向上取整材料需求，循环、歧义、缺失材料、数量溢出及深度/节点上限均可见并 fail-closed，不调用未验证的全量目录接口。`craft_v3_recursive_graph_test.lua` 与全量 42/42 harness 通过，Foundation Audit `186/186 + 342/342` 通过；完整 recipe enumeration、递归市场总成本和 RU 字段 parity 仍待验收。
- **Bag Window Context / Embedded Quick Actions（M1.16.0.18.35）**：Active `tools_bag` 增加四个 Command 驱动的嵌入式快捷动作和受能力治理的 `ADDON:GetContentMainScriptPosVis` 窗口诊断；原生跟随保持 `diagnostic_only`，未知嵌入保持 `fail_closed`。`bag_v3_window_context_test.lua` 与当前全量 42/42 harness 通过，Foundation Audit `186/186 + 342/342` 通过；RU 原生重挂载/嵌入 API 和多分辨率视觉跟随仍待验收。
- **Team Actions / Party Movement（M1.16.0.18.34）**：Active `combat_team_tools` 增加受约束的职责设置、成员互换和移入小队真实 Command/UI 路径；职责 1–999、成员/小队索引 1–50 在 Presentation 与 Command Authority 双重校验，Native 或投影刷新失败不会伪造成功。`team_tools_roster_roles_test.lua` 与全量 40/40 harness 通过，Foundation Audit `186/186 + 342/342` 通过；RU 权限/冷却/结果和视觉往返仍待验收。
- **Auction Favorite / Context UX（M1.16.0.18.33）**：Active `tools_auction` 增加规范化并持久化的关键词/收藏（上限 20）、显式搜索 pending/unknown 状态、稳定索引收藏删除与 8 行分页；`auction_v3_favorite_context_test.lua` 与全量 40/40 harness 通过，Foundation Audit `186/186 + 342/342` 通过；RU 原生搜索结果 schema 与视觉往返仍待验收。
- **Craft Product / Cost / Shortage Projection（M1.16.0.18.32）**：Active Craft 读取现在对有界结构化产物/材料行汇总背包持有量、缺口、grade-aware 最低价与行成本；Bag 槽位读取失败、未知占用、报价未知、opaque/truncated payload 均保持 `incomplete/unknown`，页面新增成本/持有/缺口列。`craft_v3_cost_shortage_test.lua` 与全量 39/39 harness 通过，Foundation Audit `186/186 + 342/342` 通过；递归子配方、总成本图和 RU 字段/报价 parity 仍待验收。
- **Bag Category Batch Deposit（M1.16.0.18.31）**：Active V3 `tools_bag` 增加精确 category、bank/coffer 目标与 1–40 上限配置；目标窗口/容量/空槽受治理验证，类别不可读和黑名单项 fail-closed；共享 Scheduler 逐步移动、严格空槽验证、失败即停、取消与状态投影闭环。`bag_v3_category_batch_test.lua` 与全量 38/38 harness 通过，Foundation Audit `186/186 + 342/342` 通过；RU 字段、窗口与移动时序仍待验收。

- **Bonds Filter / Duplicate Priority（M1.16.0.18.30）**：Active V3 Bonds 增加可持久化的 20/60/100/Auroria 过滤、数量/大陆排序、重复材质数量的西/东优先级；页面按钮通过 Commands 写入并刷新，缺少可靠大陆身份时保留重复行并输出诊断。`bonds_v3_filters_test.lua`、全量 37/37 harness 与 Foundation Audit `186/186 + 342/342` 通过；RU 字段和视觉往返仍待验收。

- **Bonds Completion / Resource Projection（M1.16.0.18.29）**：Active V3 Bonds 现在自包含解析受治理的 mainland/Auroria 债券任务映射，读取 `QuestProgressV3` 的完成/可交付/进行中/未接/未知状态；按需有界扫描 240 个背包槽位，投影需求、持有量、缺口与 `partial/unknown` 诊断；每日 mainland `materialKey:quantity` 完成键经过 `S.State.life.bondCache` 持久化并跨大陆复用。页面新增任务状态列，Registry 依赖与证据同步。定向 Bonds harness、全量 36/36 harness 与 Foundation Audit `186/186 + 342/342` 通过；RU Fresh Reload、真实字段/视觉和剩余过滤优先级仍待验收。

- **Foundation Gate / BuffDisplay Schema Parity（M1.16.0.18.27）**：发现并修复 Foundation Gate 仍按 schema 1 检查 `v3.buff_display` 的门禁漂移，使其与当前 Store schema 2 和 Feature Acceptance 对齐；Foundation Gate 已升至 v51。修复后 Foundation Audit `182/182 + 338/338`、24 个 Harness 全部通过，RU Fresh Reload 仍待实机验收。

- **Detached Floating State / BuffDisplay Persistence（M1.16.0.18.26）**：公共 FloatingSurface 支持 detached getState 与 setState Command 回写；所有 Active Floating Widget 的状态变更都经过 Feature Commands，持久化失败会回滚 detached snapshot。BuffDisplay schema 2 改用完整 Floating state normalization，保留锁定/最小化/透明度/字号。新增 detached state contract 7/7；最终本地 Foundation Audit 182/182 + 338/338，24 个 Harness 全部通过，RU Fresh Reload 仍待实机验收。

> **Authority Level**: CURRENT
> 进度总表与“下一步”以 [`../CURRENT_REBUILD_STATUS.md`](../CURRENT_REBUILD_STATUS.md) 为准。

## M1.16.0.18.45 Product Usability Recovery（当前）

1. Healer calibration 通过独立 Preview Consumer 读取真实团队/Aura 色块；BuffDisplay schema 3 恢复 tracked Buff head markers，并把 Acceptance/Foundation 的旧 schema 2 要求同步修正。
2. ScreenProjectionV3 v3 统一 logical UI projection；Unit Lines 支持 target/targettarget/watchtarget/watchtargettarget 四条有界关系与 50–1000ms refresh，Range Assist 保持用户半径语义。
3. Team Auto Role 使用 86 个 exact class-combination catalog，仅写当前玩家职责；Trade/Treasure/Fishing 独立 HUD 恢复，Trade HUD 内可直接选/循环路径。
4. Craft 普通交互不再输入 raw ID；Bag 恢复跟随原生背包的“取同类/放同类/停止”，Quick 与类别 Batch 任务互斥且任务创建失败/仓储关闭/Disable 都会回滚。
5. `AuctionQueryV3 v2` 是 Active `AUCTION_ITEM_SEARCHED` 唯一 Authority，统一 9 参数当前挂单搜索、串行 pending、超时和 bounded rows；收藏与行情共享查询，历史成交行情继续因时间样本/交易 identity 不足而 Blocked。
6. Product Matrix 重新纳入 3 项此前遗漏的旧版/用户能力，共 125 条：`77 IMPLEMENTED / 35 PARTIAL / 2 TODO / 11 SPECIFIC_RUNTIME_BLOCKED / 0 UNREVIEWED`。
7. 本地最终门禁：Foundation Audit `195/195 Active TOC + 351/351 Lua`；AuctionQuery、Bag mutex、Healer calibration、ScreenProjection batch、Trade zone-shape、VisualGuide rollback、Alerts duration 专项 PASS；Auction event Authority 反向故障注入能精确阻断第二所有者。BuildTag：`v3-m1.16.0.18.45-product-usability-recovery`。

## M1.16.0.18.44 DPS Skill Proxy Source Classification（当前）

1. `治愈之泉` / `治愈之泉：波涛` / `治愈之泉：绿叶` 注册为 `PLAYER_PLACED_SKILL_PROXY`，对应已核技能 ID 11948 / 41224 / 41225；目录只做 exact O(1) lookup。
2. 当前 bundled RU API 未提供可证明的通用 proxy entity→caster owner link。观察到某玩家施法并不能证明随后同名 Healing Fountain heal 属于该玩家，因为多人可并存同技能实体；因此当前版本**不做 owner 归并**。
3. 代理 heal 仍计入 DPS session 事件/分段与 `proxySourceHealAmount`，但不创建 Actor、不写 CombatRelation；页面显示“技能代理未归属”。真实玩家 source 的同技能 heal 不受影响。
4. 热路径没有 Tick/Native 扫描/施法监听/Tag 匹配；只有一次 exact source-name hash lookup。未来只有拿到显式 owner identity 才允许升级归属。
5. 本地目标门禁：Foundation Audit `191/191 Active TOC + 347/347 Lua`；Domain 故障注入验证 proxy 不成 Actor、不污染 Relation、player-source 同技能仍统计。BuildTag：`v3-m1.16.0.18.44-dps-skill-proxy-source-classification`。

## M1.16.0.18.43 Combat / Life Usability Recovery（历史）

1. 战斗 Presentation 信息密度收口：DPS/DeathReview 默认折叠高级设置；Healer 不再创建推荐名单/成员详情表，旧推荐 Floating Widget 不在 Active TOC。Healer Raid calibration 可在 Feature disabled 时独立显示四个团队区域且不获取 Healer Consumer。
2. 状态/Boss 可用性：BuffDisplay 以 `BUFF_UPDATE/TARGET_CHANGED` + 120ms coalesce 更新；Boss 静态规则按真实字段展示，并通过 `AlertsService → AlertHudV3` 提供可配置 HUD 与手动大字/倒计时测试，自动触发仍等待 cast/Aura fact bridge。
3. 新共享 `ScreenProjectionV3 v2` 治理 unit/world→screen；Unit Lines 只绘制 self↔target，Range Assist 只绘制用户半径，两者 Demand-scoped、无 Tick，批量范围点只读取一次 Camera basis；`CombatVisualGuidesV3 v2` 是 render-only bounded dot pool。
4. Trade/Bonds 注册 `life.trade/life.bonds` FloatingSurface，窗口独立持有 Consumer；Trade normalization 支持 RU `{[zoneId]=true}`，fallback 只生成候选，货率真实性仍由服务器 ratio 决定。普通 Trade/Craft Refresh 继续禁止 Auction quote fan-out。
5. 产品 Matrix 因用户明确删除治疗推荐悬浮能力变为 122 条：`77 IMPLEMENTED / 31 PARTIAL / 3 TODO / 11 SPECIFIC_RUNTIME_BLOCKED / 0 UNREVIEWED`。`.18.43` 修复过但有先前 RU 负面证据的 Healer calibration、BuffDisplay、Trade dropdown 均保持 Partial，等待 Fresh Reload。
6. 本地最终目标门禁：Foundation Audit `190/190 Active TOC + 346/346 Lua`；Healer calibration、Alerts expiry、ScreenProjection batch、VisualGuide rollback、Trade zone-shape 定向测试必须全部 PASS。BuildTag：`v3-m1.16.0.18.43-combat-life-usability-recovery`。

## M1.16.0.18.42 Business Page Logical ID / Strict Build Fail-Fast Recovery（历史）

1. `tools.social` 页面真实根因为 logical ID 冲突：通用 `v3_business_<id>_actions` 在 `id=tools_social` 时等于 `v3_business_tools_social_actions`，与 Social 专用 Row 重名。第一次 Preflight 拒绝 Row 后，旧代码继续构建导致两个 parent-required Preflight 与最终 `button=nil` 二次异常；现改为 `v3_business_tools_social_member_actions`。
2. ComponentCore strict BuildScope 对 required component 实施 first-failure fail-fast；`buildOptional=true` 保留降级语义。BuildTransaction 报错优先输出第一个 `scope.failure`，避免原始 ID/Preflight/Native 原因被后续 nil exception 覆盖。
3. Foundation Audit 会展开 Business Registry route id 与简单动态 ID 表达式，检查 fixed-vs-expanded collision；恢复旧 Social ID 的故障注入必须失败。当前全量 Audit `186/186 Active TOC + 342/342 Lua` PASS、`businessIds=0`，Strict BuildScope `required=1 / optional=1` 行为测试 PASS。
4. `UIV3Acceptance v31` / `FoundationGate v57` 要求 `BusinessPagesContract.componentIdContractVersion>=1` 与 `RSUI.StrictBuildFailFastContractVersion>=1`。产品能力 Matrix 不因本次 UI Foundation 修复改变，仍为 82 IMPLEMENTED / 25 PARTIAL / 3 TODO / 13 SPECIFIC_RUNTIME_BLOCKED / 0 UNREVIEWED。

## M1.16.0.18.41 Bag / Team / Persistence Integrity

1. Bag 单槽存入已修正为“背包源槽读取 + 目标仓储黑名单策略”两套身份，bank/coffer 不再被误作源容器；category batch 的 Scheduler 创建失败、Cancel、Feature Disable 都会释放任务与 queue/runtime，页面不再把刚启动的异步批量任务描述为已完成。
2. Team role 明确区分读取/写入签名：全队职责通过 `GetRole(teamIndex, memberIndex)` 只读，写入只使用 bundled 单参数 `SetRole(role)` 并在 UI 中明确为“我的职责”；Demand 存在时观察 `v3.team_roster.updated`，延迟首刷与后续 Roster 变化都会重建职责投影。
3. Buff Cap 以 `BUFF_UPDATE` + 150ms one-shot 合并刷新普通/隐藏/总数量，Consumer=0 后无事件/任务；仍不猜测 RU 容量阈值。Activity/Tasks 专用设置 mutation 采用持久化失败回滚，避免 session 内存态和 Store 分裂；公共 Demand v2 的反向 reconcile 经复核正确，因此不重复造回滚层。
4. Craft Presentation 删除一次 Command 后的重复 Authority Refresh；Bag/Team/Buff/Persistence 专项 harness 均通过。产品能力状态不因底层修复而虚假升级，Matrix 仍保持 82 IMPLEMENTED / 25 PARTIAL / 3 TODO / 13 SPECIFIC_RUNTIME_BLOCKED / 0 UNREVIEWED。
5. `UIV3Acceptance v30` / `FoundationGate v56` 新增 Bag action/batch、Team role、Buff dynamic observation、specialized persistence mutation contract；Foundation Audit `186/186 Active TOC + 342/342 Lua` PASS。RU Fresh Reload 仍是 Native/事件/视觉往返的最终证据。

## M1.16.0.18.39 Feature Truth / Lifecycle Recovery

1. `v3_live_ui` 只把 stale/unscheduled layout roots 当 warning；正常 fresh pending 是异步 reflow 的中间态。
2. Business/Life 页面不再 `page_enter -> Enable`；用户关闭状态保持关闭，只有显式开关才写 preference，Demand 随真实 Consumer 建立/释放。
3. Trade/Craft 从 ordinary Refresh 移除循环 `GetLowestPrice`；Auction 一参数 Search、Team 未授权成员移动、Raid 未验证写入、Fishing 假 Auto-R、Boss Chat matcher、Buff Cap 猜阈值全部停止伪完成。
4. Registry/产品 Matrix 按真实能力降级；Acceptance v28 / FoundationGate v54 的 `v3_feature_truth_contract` 阻止未来再次把这些缺口标成完整。
5. 下一步必须用 RU Fresh Reload 验证真实用户流程；本地 Foundation PASS 不能替代产品行为验收。


## Product Capability Gate（2026-08-31）

产品能力范围锁见 [`PRODUCT_COMPLETION_MATRIX.md`](PRODUCT_COMPLETION_MATRIX.md)。`.18.45` 将此前遗漏但用户明确要求恢复的 Buff 头顶追踪、Treasure HUD、Fishing HUD 纳入范围，同时不恢复已删除的治疗推荐悬浮窗，因此当前共 125 条：77 `IMPLEMENTED`、35 `PARTIAL`、2 `TODO`、11 `SPECIFIC_RUNTIME_BLOCKED`、0 `UNREVIEWED`。新恢复能力在 RU Fresh Reload 前保持 Partial；本里程碑仍只代表代码/契约门禁，不代表产品完成，继续执行 `INCOMPLETE - CONTINUATION REQUIRED`。

此外，源码 `S.BuildTag` 已同步为 `v3-m1.16.0.18.45-product-usability-recovery`。本地门禁已恢复，但 RU Fresh Reload 必须确认四个生活路由不再出现 `GetProjection` 激活失败，并继续确认 `native import failures=0`、`ui_foundation_matrix=0` 与 `v3_authority_clean=0`；产品能力 Matrix 仍有 PARTIAL/TODO/Runtime Blocked，因此最终 Completion Gate 仍未通过。

## 历史详细记录：M1.16.0.18.38 — Life Projection Contract Recovery（2026-08-31 本地完成 / RU Fresh Reload 待验收）

### 追加复核：M1.16.0.18.25 Active Presentation Command Fence Follow-up

- Foundation/Gear HUD/Gear Snap Modal 不再直接调用 Feature 的写方法；Activity/Gear/Instance/Buff 的刷新、显隐、尺寸、外观和 Snap 设置统一经 `Feature.Commands`。
- Gear QuickHud 对外读取改为 detached `GetQuickHudProjection()`；Widget 不再通过 Feature getter 保留可写内部状态表。
- Foundation Audit `TOC 182/182`、Active Lua `182/182`、全 Lua `338/338`；Presentation boundary `34/34`；完整 23 个本地 Lua harness 全部通过，RU Fresh Reload 仍待验收。

### 追加复核：M1.16.0.18.24 Presentation Private-Field Fence Follow-up

- Foundation 页面不再读取 `S.Features.Activities.StoreId`、`S.Features.Gear.IndexStoreId` 或 `S.Features.Activities.WidgetWindowSizePolicy`；持久化绑定继续使用稳定本地 Store ID，活动窗口策略改走公开 `GetWidgetWindowPolicy()`。
- `v3_presentation_boundary_test.lua` 保持 `34/34`；`rs_foundation_audit.py` 新增 `S.Features.<Feature>.<private>` 静态围栏，避免 Lua 可解析但页面构建时越过 Feature 边界的回归。
- Foundation Audit `TOC 182/182`、Active Lua `182/182`、全 Lua `338/338`；23 个本地 Lua harness 全部通过，RU Fresh Reload 与真实 Native 页面/Widget/Modal 仍待验收。

### 追加复核：M1.16.0.18.19 Presentation Boundary / Housing Read-only

- Active V3 Presentation 现在由静态 Gate 拒绝内部 Feature 字段、旧 Settings getter 和直接 Refresh getter；设置/策略读取统一走 detached `*Projection`，写入统一走 `Feature.Commands`。边界 harness 为 `34/34`；页面/Widget/Modal 构建矩阵已覆盖实际两个 V3 Modal；Activity/Task 的主表与 HUD 表采用 fill + absoluteMinWidth 响应式列。
- 新增 `life.housing` 只读 Feature/Authority/Page，四个 `X2House` getter 只在页面 Consumer 存在时按需读取；ready/partial/unavailable 均保留事实状态，不执行写操作或后台轮询。
- 当前本地 Foundation Audit：`TOC 182/182`、Active Lua `182/182`、全 Lua `338/338`，Unexpected global / Presentation escape / Raw Native / Raw BuildScope 为 `0`；最终完整 23 个 Lua harness 为 `23/23`。
- `tools.reinforce_analysis` 继续列为 Runtime Pending：官方 getter 的槽位入参、返回结构与 RU 上下文约束尚未得到真机确认，不用猜测实现页面。
- `tools.random_shop` 已接入窄只读页面，仅展示官方刷新次数；其它随机商店字段仍保持未推断状态，须 RU 上下文 Fresh Reload 验收。
- `life.butler` 已接入窄只读页面，仅展示官方 `GetChargeInfo()` 的返回状态；其它管家能力仍保持关闭并须 RU 上下文 Fresh Reload 验收。
- `v3_39_modal_build_matrix` 实际构建任务详情与换装设置 Modal；换装设置执行完整 Open/Close 栈事务，任务详情仅执行容器构建，不伪造未经 RU 证实的任务 key。


- **静态 Regression Gate 正式加入工程**：新增 `tools/rs_foundation_audit.py`（开发工具，不进 TOC），每次封包前统一检查 Active TOC/全 Lua Parse、bytecode `_ENV` 意外全局、Presentation→Native/私有状态越界、Raw Native constructor、Raw BuildScope 使用与已知 Lua5.1 capture 回归。该门禁在本轮实际抓出并修复了 Active Healer `Recommendation()` 未定义全局。
- **RSUI 构建事务硬化**：BuildScope Contract 升 v3，新增 `WithBuildScope/BuildTransaction`；PageHost、WidgetHost、ModalHost 不再手写 scope 配对。Close-order 泄漏会 fail-closed 回滚泄漏子 scope 并恢复栈一致性，同时作为 Foundation Blocker 计数，避免一个漏关 scope 污染整个 Generation。
- **Native Allocation 前置 Preflight**：RSUI v24 / API 10.9 在组件 factory 前执行 `ValidateSpec`，并用 generation-consumed logical-id fence 先拒绝本代重复 identity、缺 parent/id 与组件专属无效定义；首批 Table/TableView、SegmentedSelector、NumericField validator 已接入，失败时 Native factory 调用为 0。WidgetHost 的统一 Windowing 契约也移入 BuildTransaction 内，在 Commit 前拒绝半有效 Surface。
- **Runtime Gate 同步加强**：FoundationGate v50 / UIV3Acceptance v25 门禁 BuildScope v3、Transaction/Preflight、PageHost v4、WidgetHost v13、ModalHost v5，以及 close-order recovery / preflight / transaction failure / quarantine Fresh Generation 必须为 0；新增已迁移路由专用 PageHost/WidgetHost 覆盖检查；没有降低任何既有 Gate。
- **本地验证**：`FOUNDATION_AUDIT PASS`（TOC 170、Active Lua 170、全 Lua 326、Unexpected global 0、Presentation escape 0、Raw Native 0、Raw BuildScope 0）；负向注入可正确抓出未定义全局；BuildScope Harness 验证 close-order 双 scope fail-closed 回滚、自动 transaction commit/reject、preflight-before-factory。
- **迁移路由覆盖复核**：UIV3Acceptance v25 的当前矩阵必须命中专用 PageHost factory；具备悬浮窗的已迁移路由必须有 WidgetHost spec，Modal 关联必须有实际模块契约，planned 路由才允许使用 fallback placeholder。开发审计工具在无 `texluac` 的环境下安全回退到 `luac`，审计规则保持不变。
- **实页构建序列**：`v3_37_migrated_page_build_matrix` 客户端实际导航创建当前 13 个已迁移页面并遍历 FeatureRegistry 当前 39 个 Active Route（planned 路由仅使用 fallback placeholder），同时对 7 个已迁移悬浮窗执行 `WidgetHost:EnsureInstance()`；`v3_39_modal_build_matrix` 实际构建两个已迁移 Modal 并回归换装 Modal 的 Open/Close 栈；另有 `v3_38_floating_policy_zero_defaults` 直接验证共享 Floating 策略的零值语义。这不是 Lua Parse 或注册表存在性证明，任何 Build/Quarantine/恢复失败都会直接报告。
- **本轮实证**：Foundation Audit `182/182 + 338/338`；23 个本地 Lua harness 全部通过，框架生命周期回归 `112/112`，Persistence `12/12`、Aura `18/18`、Floating policy `6/6`、Theme alignment `4/4`、FeatureRuntime shutdown `14/14`、Feature Demand quiesce contract `22/22`、Service Demand quiesce contract `9/9`、PageHost navigation rollback `16/16`、WidgetHost callback fence `13/13`。旧 RU 日志曾报告 `rs_theme.lua:219` 向 Native `SetAlign` 传字符串，已由共享 Theme 归一化；这只证明本地代码/契约链，不替代修复后的 RU Fresh Reload、逐路由页面真实 Native 构建和真实客户端字段验证。
- **Persistence 迁移复核**：新增本地迁移矩阵，覆盖空存档、N-1、future schema、metadata mismatch、显式空表与 cyclic payload，共 `12/12`；未改变写保护策略。
- **Aura 共享事实复核**：发现并修复 Tooltip 缺失时 Lua 5.1 `ipairs({nil, data})` 截断问题；AuraObservationV3 与 HealerAuraBridge 现在都能保留 Data Row 的 stack/timeLeft/name/icon，共享 Aura 与 Healer fallback 回归 `18/18`。
- **回归门禁补强**：Foundation Audit 现在静态拒绝高信号的 `ipairs({primary, secondary})` / `ipairs({first, second})` nil-unsafe fallback 形态，避免相同 Lua 5.1 问题重新进入 Active TOC。


- **Combat Analytics 页面恢复**：排行切换 Presentation 不再越过 Feature 边界读取不可见的 `VALUE_OPTIONS`；Feature 新增 detached `GetValueSelectorModels()`，Page 只消费公开模型并保留 `SetSelectedValue` Command Authority。修复实机 `pairs(nil)` 导致的 Page quarantine。
- **DPS 悬浮窗单一外观 Authority**：移除业务 Widget 内旧的第二套“外观”编辑区。透明度/字号/锁定/重置全部只由公共 `FloatingSurface -> WindowShell` 标题栏外观面板提供，避免重复 Native 控件及同 Generation 构建失败后的 identity duplicate。
- **Floating Appearance 窄窗可操作性**：NumericInline v3 支持 `sliderPreferredShare`；公共外观行将 2 字标签压到 24–26px、精确输入 42–46px，并优先把约 46% 行宽留给 Slider。WindowShell v19 / titleAppearanceContract v3。
- **Appearance parity 收口**：Tasks / DeathReview Widget 补齐 `fontScaleAdjustable + get/setFontScale`，与 Activity/DPS 的公共标题栏能力一致。
- **同 Generation 失败保护**：lazy Appearance 首次构建失败后记录失败状态，本 Generation 不再用已被 Native 注册过的逻辑 ID 重试构建；Fresh Reload 后由新 Generation 正常重建。

- **窄 HUD Slider 空间优先**：`NumericInlineContractVersion v2` 允许紧凑 Consumer 单独声明 label/input/slider 的最小宽度与标签最大占比；WindowShell 外观行不再被通用 44/54px 固定下限挤压，2 字标签只保留约 26–30px，精确输入 44–48px，剩余宽度优先交给 Slider（最低 44px）。普通页面默认布局不变。

- **统一 Floating 标题栏外观入口**：WindowShell v18 / FloatingSurface v9 为所有 HUD FloatingSurface 默认提供“外”按钮；整体、背景、文字透明度与局部字号使用同一组 Slider + 精确输入。面板首次点击才 lazy 构建，未使用窗口只增加一个标题按钮，不预分配隐藏 NumericField。锁定/重置布局一并进入公共 Chrome，业务 Widget 不再各做外观弹窗。
- **Activity 紧凑自适应**：活动 HUD title/footer/padding 继续收紧；TableView 开启 overlay scrollbar，不再在右侧预留滚动条黑槽；活动/状态/进度列用 fill + absolute minimum 随 viewport 宽度实时求解，禁用手工列宽，窗口缩小时优先压缩列而不是保留旧空边。可见行数仍完全由 viewport 高度决定。
- **Combat Analytics 直接切换排行值**：去掉“击杀”二级 Dropdown；每个 Metric 使用 bounded SegmentedSelector 直接切换击杀/助攻/死亡等 value，写入只经 Feature Command。Store 对每个 Metric 的 value key 做白名单 Normalize/Reject，防止无效状态让页面看似切换但 Projection 回落。
- **Foundation 契约**：FoundationGate v48 门禁 WindowShell `titleAppearanceContract`、FloatingSurface `TitleAppearanceContractVersion` 与 DataView overlay scrollbar；UIV3Acceptance v22 同步。
- **本地门禁**：本轮最终封版必须重新执行 Active TOC、全项目 Lua、analytics value switch Harness、旧 `handleDefinition/NormalizeColumn` 回归扫描与 Floating title appearance 静态契约；ArcheRage RU 的标题面板 Native 层级、Slider 拖动、Activity 极窄布局和战斗分析实际点击仍保留为 Fresh Reload 验收。

- **公共 Page 根因已定位并修复**：`RSUI:TableView()` 的 `NormalizeColumn()` 读取了不存在的 `columnRef.align`。`columnRef` 只应该存在于后续 Native 延迟表头回调的 Lua5.1 capture 循环；同步 Normalize 必须读取当前 `column.align`。Healer / DeathReview / CombatAnalytics / Tasks 的 nil upvalue 都是同一前置构造失败的二次症状，另外 10 个 TableView Surface 同样受影响。
- **Build Transaction 泄漏已修**：Generic WindowShell 创建成功后此前遗漏 `EndBuildScope(scope,true)`，导致外层 Main Shell scope 无法按栈顺序提交，实机诊断出现 `activeBuildScopes=2`。成功路径现在 Commit；Windowing Attach 失败走 Rollback。
- **Strict Authority 修复**：TableView resize handle 与 Shared Scrollbar 的运行期 Show/Hide 统一走 `UI:SetVisible()`。实机旧 Generation 的 `v3_authority_clean[viol=3]` 可能包含这些越权缓存修复记录，但必须 Fresh Reload 后以新计数判断，本文不把未实机验证内容写成 PASS。
- **Foundation Contract 对齐**：NativeImports v2（Optional negative cache）、NativeObjectFactory v3（Object import result fence）、WidgetHost v12（lifecycle bind transaction）、Windowing/WindowShell/FloatingSurface idempotence、Events v4 release observability、RSUI v23/WrappedText v2/callback capture/Strict BuildScope v2，以及 BuffDisplay StatusMap/资源 scope contract 均已按 FoundationGate v45 真实实现；没有降低 Gate。
- **高级编辑器与严格构建已收口**：M1.16.0.18.2 已补齐 Healing Rule、Tracked Buff、颜色编辑器；M1.16.0.18.3 为 Page/Widget/Modal/Main Shell 加入非可选组件失败拒绝 Commit 的 Strict BuildScope，并让表单关键控件 fail-fast、可选文本输入可降级。
- **状态显示迁移已接入**：`combat.buff_display` 只从 `AuraObservationV3:GetStatusMap()` 读取 player/target Buff、Debuff、Hidden 事实，Feature Demand 管理唯一 Aura lease；V3 Page/Floating Widget 只消费 bounded detached projection，Legacy Plates Runtime 仍不在 Active TOC。
- **Plates GameData 收口**：`data/ids/rs_plates_ids.lua` 将重要冷却、魔法阵、目标装备状态和计时修正登记为共享语义集合；Legacy Runtime/API/Storage 消费共享关系，不再各自拥有同一批 ID。来源/置信度保留为 `curated / verified=false`，魔法阵候选继续要求 RU 实机确认。
- **Plates Diagnostics Facade**：Storage 提供只读 `GetHealth()`，Manager 提供只读 session concern 快照，Runtime 将分片、Dirty、write fence、目录/发现/捕获 staging 与关系集合计数交给已有 Suite Diagnostics 摘要；诊断路径不触发持久化 API或新的 RU 扫描。
- **Plates Concern Facades**：Storage 暴露 Persistence/Tracking/Aura Library 只读快照，Manager 暴露 Catalog/Discovery/Capture/Import Staging 只读快照，Runtime Diagnostics 同时保留扁平兼容字段和 `storageConcerns` / `managerConcerns`；Discovery cursor 为 detached copy，不可由诊断调用者反向修改会话。
- **V3 Presentation Read Models**：Active V3 Page/Widget 不再直接访问 `Feature.State`；窗口几何、Activity/Task 行数与显隐偏好、Task 作用域、Gear 方案计数均通过 Feature 窄 getter 获取，Activity/Task 显隐写入统一走 Commands；新增 Presentation boundary Harness `12/12`。
- **Activity/Task Projection Boundary**：Activity/Task Active V3 Page/Widget 不再直接持有 `Feature.Authority`；Activity/Task 的 rows/summary/row lookup/widget projection 经 Feature getter，刷新、活动隐藏/恢复、任务展开经 Feature Commands；Activity 手动刷新保留区域扫描，脏事件刷新不增加扫描。
- **Active Presentation Authority Boundary**：Gear、Instance Browser、Raid Readiness 的 Page/Widget 不再直接持有 `Feature.Authority`；Gear 的方案/快捷按钮操作、Instance rows/summary、Raid Readiness rows/summary/cancel scan 均经 Feature Projection/Commands，保留原有保存、扫描与 Aura 释放语义。
- **Factory Reset / Aura Store Contract**：Suite Factory Reset 通过 `Persistence:GetPersistentKeys()` 纳入 Suite-owned Store，并显式清理 Plates Aura Library manifest 与 `a/b/c × 32` bounded shard space；完成后清除旧代 dirty 状态、设置 reset generation fence 并 quiesce 旧 Runtime。`factory_reset_contract_test.lua` `13/13`，P0-1 `GetEffectIds` 单一 Authority/full-scan 语义也由同一门禁锁定。
- **Healer Command Authority Boundary**：Healer Active V3 Page/Widget/Raid Overlay 的规则、Tracked Buff、颜色、布局、Roster 刷新、Binding setter 与 widget dirty 写入统一经 `Feature.Commands`；Store 仍保留 Normalize/MarkDirty rollback，生命周期 Acquire/Release 保持独立。Presentation boundary Harness `21/21`，Healer direct mutation scan `0`。
- **Active Presentation Mutation Authority**：DPS、DeathReview、Gear、Raid Readiness、Activity、Task、BuffDisplay 的 Page/Widget Binding setter 与 Store dirty 写入统一经 `Feature.Commands`；新增 Active mutation scan、command facade 合同与 Acceptance guard，Presentation boundary Harness `25/25`，保留既有 Domain/Store 语义。
- **V3 Visibility Authority 收口**：BuildScope rollback、Owner Release、V3 重复注册拒绝与 Primitive degraded 隔离统一经过 RSUI Visibility/Interaction Authority；不再把 `UI:SetVisible()` 的 Diff cache 无变化/拒绝返回值当作原生 `Show(false)` 兜底许可，degraded 标记在 fail-closed 隔离完成后才设置。
- **本地门禁**：Active TOC 169/169，Active Lua 169/169，全项目 Lua 325/325；TableView Normalize / Native negative cache / Object import fence / Widget lifecycle bind / Event release / WrappedText v2 / Strict BuildScope / BuffDisplay projection / Feature lifecycle / Diagnostics / WindowShell Authority / Plates UI Diff / Plates GameData / Plates Diagnostics Harness 全部 PASS；Plates GameData/Diagnostics Harness `21/21`；Plates Concern Facade `14/14`；V3 Presentation Boundary `25/25`；Factory Reset/P0 scan contract `13/13`；旧框架 112/112、Healer 高级命令 18/18；Visibility Authority `8/8`，13 个本地 Harness 合计 `244/244`；Active V3 direct State/Authority `0`、mutation scan `0`；关键延迟 callback 捕获变量 `columnRef/routeRef/handleDefinition` 前置误用扫描 0。
- **WindowShell Authority 回归**：构建失败的早期原生窗口隐藏已统一走 `UI:SetVisible(window, false, owner)`；`.workbuddy/tmp/window_shell_authority_test.lua` `5/5` 确认不会调用 `window:Show(false)`，并保留 BuildScope rollback。
- **上一业务里程碑保持不变**：M1.16.0.18 Healer Head Marker / Raid Overlay 的 Domain/Presentation 设计不回退；本轮只修 Foundation/Page 公共阻断。


## 下一候选

1. 先完整 Fresh Reload 验收 M1.16.0.18.29 Foundation/业务增量：所有 TableView 页面/悬浮窗逐路由打开，包含 `combat.buff_display` 与 `life.bonds`，确认 Foundation `activeBuildScopes=0`、page/widget quarantine=0，并重新确认 Authority clean；通过后再继续业务实机验收。
2. Fresh Reload 后回读 Healer 高级编辑器的长文本、下拉降级、颜色与 Store schema 3 保存结果；Head Marker / Raid Overlay 继续做 RU 50/100 人视觉验收。
3. `combat.buff_display` 代码已完成；Fresh Reload 后验证共享 StatusMap 的真实字段、图标/时间、目标切换与 Page/Widget Demand 释放，不复活 Legacy Plates Runtime，也不把显示策略塞回共享 Aura Service。
4. 随后按待办图继续评估 Plates 更深的 Manager/Storage Authority 拆分；需要 RU API、服务器数据或真实团队规模的部分保持显式待验收状态。

## 当前未闭环任务图（代码层 vs RU 实机）

```text
M1.16.0.18.3–18.13 Active V3 code gates
        ↓ Fresh Reload（RU 客户端）
Foundation / Page / Widget / Healer / BuffDisplay 实机验收
        ├─ TableView / BuildScope / quarantine / Authority clean
        ├─ Healer settings + Head/Raid visuals + save round-trip
        └─ BuffDisplay StatusMap / icon / time / Demand release
                ↓ 外部证据门
RU API/服务器/玩家数据依赖：raid 50/100、真实 Buff/图标/tooltip、远端装备/招募/住宅等
                ↓ 新业务模型与证据齐备后再评估
Feature Registry planned 项与 Plates 更深迁移
```

- 已完成但仍待 RU 证据：Healer V3 全视觉链、页面/悬浮窗 Fresh Reload、50/100 人性能与真实 Aura 字段。
- 当前 Active V3 代码层门禁已覆盖 `combat.buff_display` StatusMap consumer、Plates GameData/Diagnostics/Concern Facade 与 Presentation mutation boundary；剩余关闭条件主要是 RU Fresh Reload、真实字段/视觉/性能和新业务模型证据。
- 暂不虚构实现：Feature Registry 中 `planned_verified` / `planned_research` 的独立功能，若缺少当前 Docs 定义之外的业务模型、运行时 API 返回形态或安全写入证据，保留为计划/研究。

## Feature Registry 迁移闭环审计（2026-08-31）

Registry 共 39 项；其中 foundation/system 维持基础状态，34 项 combat/life/tools 业务条目按当前代码为 29 项非阻塞 V3 链、5 项严格 Runtime Blocked，业务 `Planned=0`。旧 CHANGELOG 或旧 Agent 结论不作为证据；本地完成度由注册表契约测试直接读取当前 Registry，并要求每个 blocker 同时提供 blocker/current/remaining 三段审计信息。

已接入的主要代码链路：

- `life.trade` / `life.bonds` / `life.treasure` / `life.fishing`：独立 V3 Authority、Demand、V3 持久化、Commands 和专用页面；Fishing 的完整自动 R 槽位事务仍阻塞。
- `combat.boss_alerts`、`combat.target_monitor`、`combat.buff_cap`、`combat.team_tools`、`combat.raid_recruitment`、`life.craft_planner`、`tools.bag`、`tools.auction`、`tools.craft`、`tools.social`：独立业务桥、按需读取/显式命令和通用 V3 页面。
- `combat.unit_lines` / `combat.range_assist` 已收缩为 current-target line / user-radius Partial；`combat.siege_readiness`、`tools.market_analysis`、`tools.hotkey_profiles`、`tools.reinforce_analysis`、`tools.portal_profiles` 继续 Runtime Blocked，不猜测装备、结果、槽位或 Option 写入契约。

当前仍需 RU Fresh Reload / 真实 Native 构建与字段证据；本地 Gate 只能证明加载边界、Lua 逻辑和契约，不能把页面运行时验收提前宣称完成。下一条可代码收口线是取得上述 blocker 的具体 RU 证据后逐项关闭，或继续处理 Plates residual。

## 权威文档

- [`../CURRENT_REBUILD_STATUS.md`](../CURRENT_REBUILD_STATUS.md) — 当前总体进度/下一步。
- [`../CURRENT_ARCHITECTURE.md`](../CURRENT_ARCHITECTURE.md) — 当前落地架构总览。
- [`../Architecture/HEALER_ARCHITECTURE.md`](../Architecture/HEALER_ARCHITECTURE.md) — Healer Domain / Presentation 当前权威。
- [`../Architecture/SERVICE_ARCHITECTURE.md`](../Architecture/SERVICE_ARCHITECTURE.md) — TeamRoster/Aura/Demand 服务边界。

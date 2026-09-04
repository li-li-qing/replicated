# Replicated Suite RU Runtime Acceptance Plan

状态：计划文件，不是实机通过证明。执行目标是 ArcheRage RU 中文客户端；每项结果必须在修改后重新 Fresh Reload 采集，不得沿用旧日志。

## 统一前置

1. 备份当前 addon 与用户配置；只加载 `replicatedsuite/`（单一 V3 Host）。`z_api_functions/` 仅作开发期 API 参考，**不进入运行时**；旧 `globals/` 与 Legacy UI/runtime 已于 2026-09-01/02 物理删除，不再随包，绝不重新引入。
2. 使用当前 `replicatedsuite/replicatedsuite.lua` 的 BuildTag 启动新客户端（见 `S.BuildTag`，当前为 `v3-m1.16.0.18.100-persistence-v7-generation-reload-fence`），记录 `ArcheRage.log`、`Chat.log` 和崩溃文件。
3. 在 1024×768、1920×1080、2K 逐路由打开首页、战斗、生活、工具、系统页；记录页面/Widget/Modal 是否构建、文本裁切、列宽、黑边和关闭后资源释放。
4. 每次测试前后记录 Foundation：`activeBuildScopes`、page/widget quarantine、Authority violation、Presentation boundary、Raw Native、Unexpected Global 和 Scheduler active tasks。
5. 失败记录格式：时间、BuildTag、路由/动作、API 名、输入、原生返回值（脱敏）、日志错误码、是否可复现、恢复动作。
6. 封包前必须从 `replicatedsuite/` 工程根执行 Foundation Audit；其内部必须连带通过全 Presentation `RSUI_COMPONENT_API_AUDIT`、`PRESENTATION_FEATURE_API_AUDIT` 与 RSUI 顶层依赖 TOC 顺序检查；另执行 `rs_rsui_workspace_smoke_harness.py` 与 `rs_presentation_feature_api_audit_harness.py`，六类公共 Workspace 必须真实构建通过，Feature API auditor 的 valid/missing/guarded/NewFeature/bundle 五类 self-test 必须通过。Unit Lines / Front-Hemisphere 专项 Harness 必须支持从工程根直接运行，不得依赖调用者当前工作目录。

## 通用通过条件

- 只读功能在 API/字段未知时显示 `partial/unavailable/unknown`，不显示伪造的 0 或完成。
- 写操作只经 Feature Commands/API capability，尊重权限和至少 200ms 冷却；失败停止并显示结果，不继续盲发。
- 关闭页面/Feature 后无残留 Scheduler、Event、Demand lease 或隐藏窗口；重新打开能恢复投影和持久化设置。
- 所有 TableView/浮窗在三种分辨率可读，长中文/俄文/英文不重叠、不把数值列裁成省略号。

## Persistence Reliability v7 Fresh Reload 矩阵（当前 P0）

使用 `.18.100` **新进程**执行，禁止用同一热重载世代的旧状态冒充跨进程回读。**第一步执行下方 `.18.100 Gear Critical Journal + Persistence v7 专项`**，确认换装 Payload 能保存、Reload、完整退出重进并再次应用；通过后再继续状态显示及 `.18.94` Trade/DPS 回归。进入 `combat.buff_display` 时页面必须成功构建，`v3_build_transaction_contract` 的 Page failure/quarantine/transaction/preflight 计数在新 Generation 中保持 0；进入“HUD 布局”后拖动/缩放 Selection Overlay，指针移动与元素变化方向必须一致（左上原点：X+ 向右，Y+ 向下）。当前截图宽度属于 Compact 模式时，Toolbar 必须出现 `[属性]`/`[收起属性]`，进入 HUD 布局后属性 Drawer 应自动打开；选中元素后必须能看到并编辑 X/Y/宽度/高度以及适用的 Anchor/Pivot/Snap 参数。

**`.18.89` Interactive Draft 专项**：保持状态显示功能开启并让 Aura 事实持续更新。① 连续拖动 HUD 页任意 NumericField Slider，滑块必须稳定跟随鼠标，不能一帧预览值、一帧旧值来回闪跳；② 点击同一字段的精确 NumericInput，删除/输入部分字符后停留至少 1 秒，文本必须保持当前 draft，不能被旧 Binding 回灌；按 Enter/EditEnter 或失焦后才按既有规则 Commit/校验并格式化；③ 在 Compact Drawer 开/关、切换选择元素、普通 Refresh 后重复测试。

| 域 | 重点 Store | 操作 | 必须通过 |
|---|---|---|---|
| Buff Display | `v3.buff_display` | 改追踪/分类；HUD Layout 做 Preview→Reset/Revert→Apply；立即点“重新加载文件” | 未 Apply 的 Working 不进 Store；Apply 后 Reload 回读一致；Flush 失败时重载必须取消 |
| Healer | `v3.healer` | 改标量/规则/raid panel 几何与团队绑定；Feature Disabled 状态也编辑一次 | disabled 不清永久配置；Reload 后 panel 模型/颜色/设置一致 |
| Gear | `v3.gear.index` + legacy `v3.gear.payload.N` + 新 `v3.gear.payload.N.a/.b` | `获取当前→保存`；本进程应用；Reload 应用；完整退出重进应用；再次保存让 A/B 翻转 | Index 与 active/backup Domain 指纹一致；Critical verifyFail=0；v7 integrity/envelope/decoded/unverified reload failures 均为 0；新 active 只有回读验证后才能提交；Reload 后真实换装仍成功 |
| Activities / Tasks | `v3.activities` / `v3.tasks` | 改悬浮窗尺寸/透明度、追踪/隐藏项，连续拖动后立即重载 | debounce 未完成时 Reload barrier 先安全 Flush；回读保持 |
| DPS | `v3.dps` | 改模式/指标/side/self/rows 后立即重载 | 页面与 Widget 使用同一 Store 结果，不出现当下成功、重载回退 |
| Trade | `v3.life.trade` | 改生产地/售卖地/排序/收藏并重载；退出客户端再进入 | route/favorites 跨进程一致；普通 Refresh 不触发隐式拍卖扇出 |

每轮修改后先到“诊断与维护”观察 **新版存档 / 最近存档落盘**，并点一次 **“输出存档验收”** 保存 Fresh Reload 前的只读 Domain 指纹。随后执行“重新加载文件”或完整退出客户端再进入；进入后先重新打开本轮涉及的 Feature，使它们按正常业务路径完成 Store Load，再次点“输出存档验收”。同一个 Store 的指纹必须一致；`ALL` 只有在 Store coverage 相同（尤其 `v3.gear.payload.*` 注册/Load 数量相同）时才直接比较。连续 Slider/拖动后立即重载的测试允许前置快照 `Dirty=1`，但重载成功后的快照必须 `Dirty=0/Fence=0` 且 Domain 指纹一致。若 `Fence>0`、`FlushFail>0` 或重载被取消，立即点“输出诊断摘要”；`.18.90` 摘要必须直接带出 `存档故障 <store id>:<reason>`。**不要清空 Store、不要重置默认值来让 Gate 变绿**。

### `.18.100` Gear Critical Journal + Persistence v7 Durability/Integrity/Scope/Generation Fence 专项

1. **正常新保存**：选择方案，先穿一套容易辨认的装备，执行“获取当前→保存方案”。诊断中 `readbackVerifyAttempts/readbackVerifySuccesses` 与 `integrityStampedSaves` 应增加，`readbackVerifyFailures=0`。若保存 UI 报 `readback_verify_failed`，不要继续覆盖该方案，复制 `v3.gear.index` 或 `v3.gear.payload.N.a/.b` 的具体 reason。
2. **同进程应用**：换成另一套装备后点击该方案；必须根据保存的装备 name/grade/modifier/itemType 找回真实背包物品，而不是只显示“已配置”。
3. **Reload + 跨进程**：先 Reload 再应用一次；随后完整退出客户端、重新启动、打开 Gear 后再应用一次。两次都必须成功；v4/v5 stamped save 在每次新进程读取后 `integrityLoadChecks` 应增长，`integrityLoadFailures=0 / encodedLoadRejects=0`。方案名称存在但 `LoadPayloadForSet` 报 empty/structure invalid/fingerprint mismatch/integrity_failed 均视为失败。
4. **A/B 翻转与自愈**：在同一方案重新“获取当前→保存”，确认新 revision 写到另一 bank；保存 Index 之前 bank 必须已经 readback verified。Reload 后 active bank 可用。若 active bank 确认损坏而 backup 指纹完整，允许出现 `GEAR_PAYLOAD_BANK_RECOVERED` 并继续使用上一份 verified payload；下一次显式保存可出现一次 `STORE_VERIFIED_REPLACEMENT_RECOVERED`，但只能在新 bank 回读成功后清 fence。`future_schema/load_failed` 不得触发 replacement。
5. **历史损坏方案修复**：如果旧版本已经只剩方案名称，原装备明细无法被代码推导恢复。选中该方案后由用户明确执行“获取当前”，再保存一次；这一步才允许 `GEAR_PAYLOAD_REINITIALIZED`，之后它必须进入 A/B journal。直接点击“换装”或“验证”不得自动以当前装备覆盖历史方案。
6. **性能边界**：readback 只应随显式 Gear/critical save 增长；普通页面刷新、Tick、Gear 快捷按钮 idle 不得持续增加 verify attempts。普通非 Critical Store 正常 debounce 保存仍只增加 bounded integrity stamp，不应立即产生 `LoadData`；但用户显式 Reload/Runtime Stop 时，若 `barrierPending>0`，Flush 必须各做一次 bounded readback。Critical Gear immediate verify 已成功的 Store 不得被 barrier 重复读。
7. **失败证据**：任一 `integrity_failed / encoded_load_rejected / readback_verify_failed` 都视为本轮 P0 失败；立即复制 Foundation 摘要中的 store id + reason，不要 ClearStore/恢复默认。pre-v4 老 Store 首次读取出现 `integrityLegacyLoads` 属兼容路径，不是失败；v4 stamped Store 在 v5 中必须继续可读，它下一次保存自然升级为 v5 stamp。

8. **Durability Barrier 专项**：修改任意普通 Store（例如 DPS/Trade/窗口设置），等待 debounce Save 完成后先观察 `barrierPending>0`，再点击“重新加载文件”。重载前 Flush 必须使 `barrierVerifyAttempts/Successes` 增长；如果回读不一致，重载必须取消并输出 `barrier_verify_failed:<reason>`，同时该 Store 重新 dirty 等待有界重写。不得出现“Flush 认为 clean 所以直接放行”的旧行为。
9. **Envelope Seal 专项**：新保存后诊断应出现 `envelopeIntegrityStampedSaves>0`；Reload/重新登录后 `envelopeIntegrityLoadChecks` 应增长，且 `envelopeIntegrityLoadFailures=0`。若出现 `envelope_integrity_failed:*`，保留原 Store，不 Reset。
10. **Decoded Domain Budget 专项**：正常用户配置要求 `decodedLoadRejects=0`。出现 `decoded_load_rejected:*` 代表磁盘 envelope 虽可读但业务 decode/migration 结果越过 Store budget，必须按具体 Store 调整 codec/budget，不得放宽全局上限掩盖。
11. **True Durable 专项**：所有明确 durable 的 UI 操作（例如 Buff Display HUD Layout Apply、DPS Boss 名单显式 durable mutation）只有 immediate readback 通过后才允许提示保存成功；`durableVerifyAttempts` 应随这些动作增长，`durableVerifyFailures=0`。
12. **Character Scope 专项**：Gear `v3.gear.index` 与 payload bank 的 v6 save 应携带 exact character scope fingerprint。正常单角色 Reload 要求 `scopeBindingMismatches=0 / unverifiedReloadRejects=0`；若同一 Addon generation 发生角色身份变化，旧 dirty/barrier 必须先完成旧 key durability，绝不把旧 Domain 写入新角色。`scope_binding_identity_collision` 属于硬阻断证据，不允许自动覆盖。
13. **Generation Reload Fence 专项**：修改一个普通持久化设置并等待 debounce Save 后，`barrierPending` 可以暂时大于 0，但任何 Consumer 都不应在 barrier 前主动重新 `LoadStore` 同一 Store；正常流程要求 `unverifiedReloadRejects=0`。若该值增加，保留 `STORE_UNVERIFIED_RELOAD_REJECTED + store id`，修调用链，禁止用 `discardUnverified` 掩盖。
14. **Migration/Reset Dirty Commit 专项**：正常加载/migration/reset 后不得出现 terminal Store 同时因 load transform 留下自动 dirty；正常流程 `terminalAutoRetrySuppressions` 应为 0。若真实故障使该计数增加，Native Save 调用不应随 Tick 周期持续增长。`deferredLoadResaves` 只在合法 migration/period reset Apply 成功后增加。
15. **Verified Clear 专项**：仅在有备份的测试 Store 上执行一次明确“重置/清空”命令。`ClearData` 成功后必须出现一次 `clearVerifyAttempts`；正常客户端应 `clearVerifyFailures=0`。若失败，当前 Domain 不得先变默认值，必须保持原设置并报告 `clear_verify_failed`。不要用该步骤处理已经损坏的 Gear 证据。

### `.18.92` Presentation→Feature Command 专项

Fresh Reload 新进程还需验证三条本轮真实漏接链：① 打开 `life.tasks` 悬浮任务追踪并拖动/缩放窗口，`setState` 必须能经 `Tasks.Commands:SetWidgetWindowState` 正常保存，不得出现 nil method；② 对 `life.activities` 悬浮活动窗口做同样拖动/缩放与重载；③ 打开 Gear 快捷设置 Modal，执行“重置吸附/布局相关设置”入口，必须经 `Gear.Commands:ResetQuickSnapSettings` 返回真实结果。Foundation 摘要中的 `v3_presentation_feature_api_contract` 必须为通过。

### `.18.93/.18.94` DPS + Trade Fresh Reload 专项

1. **DPS 可见性**：先打开伤害统计悬浮窗，再通过正常关闭按钮关闭；保持 DPS Feature 本身仍启用。执行“重新加载文件”，随后完整退出客户端再进入各测试一次。两种情况下悬浮窗都不得仅因 Feature Enabled 自动重新出现；只有用户显式打开时才显示。Foundation Acceptance 的 `dps_widget_visibility_preference_contract` 必须通过。
2. **Trade 主页面**：进入主菜单→跑商并启用 Feature。点击“起点”必须真正展开 Native Dropdown；选定起点后“目的地”必须真正展开并列出候选；页面不得再出现 `起点◀/起点▶/终点◀/终点▶`。若 `GetProductionZoneGroups` 在 RU 失败，sealed Zone 只能保证候选可选，最终路线仍必须等 `GetSpecialtyRatioBetween` 服务器事实。
3. **Trade HUD**：打开悬浮窗，必须是稳定的起点/目的地两行 Dropdown 布局并存在“材料询价”。选择一条有效路线后点击询价；普通 Refresh 不得自动扇出 Auction Query，显式询价完成后仅受影响路线行的材料成本/毛利应异步更新，未完成报价继续显示 unknown。Foundation Acceptance 的 `trade_dropdown_quote_preflight_contract` 必须通过。
4. 若 Native Dropdown 仍不展开，记录点击前后 `Feature:GetProjection().zones/sellableZones` 数量、Dropdown enabled/open 状态、首个 Popup/BuildTransaction 失败原因；不得恢复四个循环按钮作为降级方案。

## 逐域验收

### Combat / Team

| 区域 | 步骤 | 预期事实与日志 | 失败诊断 |
|---|---|---|---|
| DPS / Combat Analytics | 开启每个 Metric，造成伤害、治疗、死亡、控制和演奏事件，再关闭全部 Metric | Encounter、技能、死亡、控制、Aura、演奏状态按事件更新；全部关闭后 lease/task 为 0 | 查 `COMBAT_MSG` topic、Metric consumer、Encounter gap/one-shot 和 `combat_analytics` 诊断 |
| Death Review | 产生两次死亡，打开详情，删除单条、删除全部，重载 | 时间线、最后一击、技能 ID/名称、详情与持久化一致；删除失败回滚 | 查 `DEATH_REVIEW_*`、Store schema、Finalize queue |
| Healer | 50 人名单下启用 Health/Aura/Recommendation/编辑器/Head Marker/Raid Overlay/Calibration | 分片扫描、未知 Aura 显式显示；编辑保存/重载一致；关闭释放 lease | 查 TeamRoster/Aura lease、FrameBudget、marker screen projection |
| Buff / Buff Cap | 切换 player/target、过滤、tooltip、上限阈值和长文本 | 状态、图标/时间、阈值色彩与当前目标一致；未知 tooltip 不误报 | 查 `buff_display` schema、StatusMap、Tooltip 返回结构 |
| Boss / Target | 触发静态 Boss/聊天事件，切换目标和观察仇恨目标 | 匹配、倒计时、目标距离/目标的目标只显示真实返回；无事件不残留旧错误 | 查 alert matcher、TargetService、watch-target 返回字段 |
| Unit Lines | 同一目标依次置于前方、侧方、前方屏外、相机背后，再旋转相机重新看到目标；多人场景保持开启 | 前方屏外但线穿过 viewport 时保留可见段；相机背后必须整条隐藏且不指向边角；重新进入前半球后恢复；高负载刷新连续 | 查 `ScreenProjectionV3:GetHealth().behindCameraRejects/unitBatches/nativeScaleReconciles/nativeConsistencyFallbacks`、Presenter `unitRequestedDots/unitVisibleDots/unitAnchorWrites` |
| Unit Lines / Range Assist | 在 1024×768 / 1920×1080 / 2K 与不同 UI scale 放置已知目标；Unit Lines 分别测试近距离、远距离、端点出屏但线段穿屏、斜角贴边；记录 `CombatVisualGuidesV3:Describe()` 的 visibleDots/visibleEdges/clippedEdges/budget；Range 继续记录世界/屏幕坐标与已知半径 | Unit Lines 近距离保持基础密度，远距离自动增加 dots；端点出屏但可见段穿过 viewport 时只裁剪到边缘而不整段消失；refresh≤16ms 时总 dots≤256，默认 100ms 时≤480；真正整段出屏或 `behind_camera` 继续隐藏。Range 缩放/裁切正确 | 若 watchtarget/屏幕坐标字段不符，保留 blocker；不得为了解除消失问题绕过 ScreenProjectionV3 v5 front-hemisphere/consistency fence，也不得重新启用 `GetUnitsInSight` |
| Team Management | 2 个 team、多个成员时刷新职责；再测试 SetRole、MoveMember/party | 每个真实 team/member index 有独立行；写动作按权限/冷却执行并显示成功/失败 | 查 TeamRoster snapshot、`X2Team:GetRole`、写 API result/permission |
| Team Auto Role | 当前玩家切到 吟游+暗杀+野性（catalog key `name_6_8_9`），入团/切职业各触发一次自动职责 | 必须选择“远程输出”/`TMROLE_RANGED_DEALER`，不得落到普通输出；再抽测其它 catalog `classType=Archer` 组合 | 查 `AutoRoleClassKey/AutoRoleLabel`、TeamAutoRoleCatalog v2、`X2Team:SetRole` 返回 |
| Raid Readiness / Recruitment | 50 人名单、角色/装分/距离/Aura；招募创建、关闭、接受、拒绝 | readiness 分片结果和 unknown 覆盖正确；招募列表/动作刷新一致 | 查 roster fields、recruit permission/cooldown/result |

### Gear

| 区域 | 步骤 | 预期事实与日志 | 失败诊断 |
|---|---|---|---|
| Gear Sets / Titles | 创建、保存、切换、重载方案与称号；测试 HUD/Snap/Reset | 装备槽、称号、快捷操作和外观设置可恢复；失败回滚 detached state | 查 Gear Store schema、Command result、WindowShell/FloatingSurface |
| Reinforcement Analysis | 枚举合法装备槽，比较原生强化面板字段 | 只有槽位范围与字段逐项匹配后才显示等级/材料/套效 | 缺字段或槽位不符时记录 `tools_reinforce_analysis` blocker |

### Life

| 区域 | 步骤 | 预期事实与日志 | 失败诊断 |
|---|---|---|---|
| Activity / Tasks | 刷新活动、展开子任务、选择追踪、打开详情/浮窗并重载 | `x/y` 语义、完成/进行中/未知与原生任务一致；关闭释放 Quest lease | 查 `QuestProgressV3`、event refresh、detail floating state |
| Trade | 选择生产地/可售地，触发多货物比例，打开材料/价格/毛利详情 | 所有有界货物、数量、单位成本、总成本、截断状态一致；未知价格不伪造利润 | 查 `Trade:OnRatio`、`materialRows`、auction quote event/recipe identity |
| Bonds | 进入西/东/原大陆居民板，刷新 7 类板；验证 20/60/100 与 Auroria token，完成/待交付后重载 | 每行显示 questId、真实状态、所需/背包数量/缺口；同 material+quantity 每日共享完成正确，日期切换清理 | 查 `Bonds` projection、QuestProgress state、Bag scan、bond cache 日期/保存日志 |
| Treasure | 背包放入多张地图，选择不同地图，在三种坐标/scale 更新位置 | 地图全集有界列出，坐标、方向、距离随选择刷新；无坐标时 unknown | 查 bag slot signature、world position tuple、selectedKey persistence |
| Fishing | 观察鱼动作 Buff；只在非战斗时测试自动 R，注入写入失败并重载 | Buff 推荐正确；R 替换必须完整快照、写入、恢复、失败回滚，否则保持 blocker | 查 Buff IDs、hotkey snapshot/recovery marker、combat guard |
| Craft | 用 itemType 解析多个 craftType，再显式指定 craftType/doodadId；测试空/opaque/失败/超限返回 | 材料/产物每行显示 itemType/name/count 或明确 unknown；上下文保存；不固定首配方 | 查 `GetCraftTypeByItemType` 多返回值、Product/Material schema、doodadId 语义 |
| Housing / Butler | 在住宅/管家上下文打开页面，切换上下文并关闭 | 仅显示已证明的只读字段，离开上下文停止读取 | 查 context detector、getter result 和 Demand release |

### Tools / Resources

| 区域 | 步骤 | 预期事实与日志 | 失败诊断 |
|---|---|---|---|
| Bag Organizer | 分别打开银行/箱子，读取 240+ 槽；准备至少 3 个会在移动后发生源槽补位的同类物品，一次点“放同类/取同类”；再测分类批量、四个单槽移动、黑名单、取消/失败重试 | 一次点击应以 250ms 串行继续移动多件（上限 40），不能每件都要求重新点击；slot 补位不误报失败；真实写失败仍停止；容量/读取失败/截断与黑名单状态可见 | 查 Bag Contract v5 stable itemType/category intent、live source resolution、ambiguous population-decrease verifier、storage window/cooldown |
| Auction | 添加/删除收藏，搜索已知物品，查询最低价，重复搜索并重载 | 收藏持久化；搜索所有返回行；价格字段和历史样本有身份/时间证据 | 缺 `GetSearchedItem*` 字段时只显示 blocker，查 auction event/result |
| Social | 读取好友/屏蔽/静音，执行四类增删动作并重载 | 列表身份正确；写动作结果、冷却、刷新可见 | 查 list schema、permission/cooldown、refresh projection |
| Hotkey Profiles | 枚举完整动作，快照、修改、保存、重载、恢复并在每个失败点注入 | 只有全动作枚举和可恢复事务通过才允许完成 | 缺 action registry 或 snapshot contract 时保持 blocker |
| Portal Profiles | 枚举个人传送候选，选一个、读回、重载、恢复 | 只修改目标 option，不碰其他设置 | 查 `X2Option` optionType/candidate/readback |
| Resource dashboard | 触发金币/经验/荣誉/生活点事件，刷新背包资源与首页 | 日统计 delta、资源数量和日期切换正确；容量/仓库未知不伪造 | 查 Resource event 参数、bag identity/category、首页 refresh |

## 最终采集

执行完上表后重新运行：

1. `replicatedsuite/tools/rs_foundation_audit.py`；
2. 当前交付记录声明的专项 harness（以 `CURRENT_REBUILD_STATUS.md` §5 / `CHANGELOG.md` 为准；临时 harness 不属于运行时包）；
3. 所有 Active TOC/Lua/Presentation/Boundary/Acceptance 检查；
4. 从新客户端日志确认 `unexpected global=0`、`authority violation=0`、`presentation boundary=0`、`quarantine=0`；
5. 将每一项实际结果回填到 `PRODUCT_COMPLETION_MATRIX.md` 的 Runtime verification 列。未执行的项目仍为 PENDING，不能改成 IMPLEMENTED。

### `.18.90` Component API / Package Coherence 专项

1. 使用全新进程打开“状态显示”，页面不得再出现 `rs_ui_workspace_templates.lua:* attempt to call method 'Show' (a nil value)`；`v3_build_transaction_contract` 的 `pageQ/txFail/rollback` 应在新 Generation 恢复为 0。
2. 进入 `HUD 布局`，Compact 模式 `[属性] / [收起属性]` 按钮必须可见且可反复切换 SAME Inspector；不能创建第二 Inspector、不能 reparent。
3. Foundation Gate 的 `persistence_runtime_acceptance_snapshot` 必须恢复通过：`contract>=1/fingerprint=true/snapshot=true`。诊断页必须存在“输出存档验收”按钮。
4. 点击“输出存档验收”只读当前已 Load Domain，不得触发 Flush/Save/Load；Fresh Reload 前后按既有矩阵比较单 Store 与 ALL 指纹。
5. 如果以上任意一项失败，保留完整一键诊断与首个 PAGE_NAVIGATION_FAILED；不要清配置或重置 Store 来规避。

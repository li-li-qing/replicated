# Replicated Suite RU Runtime Acceptance Plan

状态：计划文件，不是实机通过证明。执行目标是 ArcheRage RU 中文客户端；每项结果必须在修改后重新 Fresh Reload 采集，不得沿用旧日志。

## 统一前置

1. 备份当前 addon 与用户配置；只加载 `replicatedsuite/`（单一 V3 Host）。`z_api_functions/` 仅作开发期 API 参考，**不进入运行时**；旧 `globals/` 与 Legacy UI/runtime 已于 2026-09-01/02 物理删除，不再随包，绝不重新引入。
2. 使用当前 `replicatedsuite/replicatedsuite.lua` 的 BuildTag 启动新客户端（见 `S.BuildTag`，当前为 `v3-m1.16.0.18.128-runtime-followup-shared-facts-layout`），记录 `ArcheRage.log`、`Chat.log` 和崩溃文件。
3. 在 1024×768、1920×1080、2K 逐路由打开首页、战斗、生活、工具、系统页；记录页面/Widget/Modal 是否构建、文本裁切、列宽、黑边和关闭后资源释放。
4. 每次测试前后记录 Foundation：`activeBuildScopes`、page/widget quarantine、Authority violation、Presentation boundary、Raw Native、Unexpected Global 和 Scheduler active tasks。
5. 失败记录格式：时间、BuildTag、路由/动作、API 名、输入、原生返回值（脱敏）、日志错误码、是否可复现、恢复动作。
6. 封包前必须从 `replicatedsuite/` 工程根执行 Foundation Audit；其内部必须连带通过全 Presentation `RSUI_COMPONENT_API_AUDIT`、`PRESENTATION_FEATURE_API_AUDIT` 与 RSUI 顶层依赖 TOC 顺序检查；另执行 `rs_rsui_workspace_smoke_harness.py` 与 `rs_presentation_feature_api_audit_harness.py`，六类公共 Workspace 必须真实构建通过，Feature API auditor 的 valid/missing/guarded/NewFeature/bundle 五类 self-test 必须通过。Unit Lines / Front-Hemisphere 专项 Harness 必须支持从工程根直接运行，不得依赖调用者当前工作目录。

## 通用通过条件

- 只读功能在 API/字段未知时显示 `partial/unavailable/unknown`，不显示伪造的 0 或完成。
- 写操作只经 Feature Commands/API capability，尊重权限和至少 200ms 冷却；失败停止并显示结果，不继续盲发。
- 关闭页面/Feature 后无残留 Scheduler、Event、Demand lease 或隐藏窗口；重新打开能恢复投影和持久化设置。
- 所有 TableView/浮窗在三种分辨率可读，长中文/俄文/英文不重叠、不把数值列裁成省略号。

## `.18.129` 真实故障收口 Fresh Reload 专项（当前第一 P0）

1. **单位连线（.18.129d label 点模型）**：选中远距离目标应出现**一排清晰可见的彩色句点**（15px 起，≥8 个，`UnitLines:` 行 uniquePositions ≈ visibleDots）；制造一次渲染失败（切屏）后自动恢复。若仍不可见，此轮已排除点模型问题，剩余嫌疑集中在引擎宿主层级——`UnitLines:` 行必发。
2. **Boss 机制（黑龙 3 天一刷，改为三段式无 Boss 验证；RU 名称以 wbdebuff 数据为事实源，实机名称证据到位前不再盲改）**：
   ① **事实管道**：开启首领机制 → 打任意会读条的普通怪并选中 → `Boss:` 行 `ticks` 增长且 `casting=` 显示该怪的技能名、`seenCast=` 记录真实 RU 名称（这证明四 scope UnitCastingInfo 读取在实机可用）；身上随便中一个可显示 debuff 后 `debuff=/source=player_debuff` 应有反应。
   ② **规则→弹窗链路**：设置页点「仿真读条」→ 应弹出"大地强击"类倒计时；点「仿真Debuff」→ 弹"撞鬼"大字（两者走真实 BossCastIndex 匹配 + AlertsService 推送，与实况同一条管线）。
   ③ **真名对照**：`seenCast=` 累积到真实 RU 名称后与 wbdebuff 表（Сотрясение / Электрические разряды / Сбрасывание чешуи）比对；命中即完成验收，不命中把实机名称发回按证据修表。任何一次真实 Boss 战斗（不必是黑龙）都可完成这一步。
3. **治疗辅助**：开启校准不再触发 healer_v3_visual_lifecycle 失败（校准=previewHeld）；实况开启 head/raid running=true；格距与旧版一致。Reconcile 失败出现 HEAD/RAID_RECONCILE_FAILED 告警（不再静默）。
4. **Gear/Bonds 指纹**：Fresh Reload 后 v3Upgrade 增长、`integrityFail=0`、`Fence=0`；如仍有 mismatch，复制 Store 行的 `lastIntegrityDivergence`（第一个不同字段）。
5. **Gear 顺序**：获取当前 → 保存方案 → Reload 三步顺序全一致（旧序档由指纹桥迁移）。
6. **Trade**：快速 A→B→C / 1→2→3 最终落在 C→3；同路线在飞时点刷新显示排队状态而非无响应。
7. **HUD 布局**：展开 TransformInspector 后下一节顶边 ≥ 上一节底边+间距；1024×768 可滚动。
8. **整理背包**：仓库满格但有未满堆可继续放入；identity 异常跳过继续。
9. **Activity Tooltip**：悬浮说明跟随鼠标。

## `.18.128` 用户复现回归（历史）

1. **换装顺序 + 缺件继续**：同一方案连续执行 `获取当前 → 保存方案 → 获取当前 → 保存 → Reload`，槽位顺序必须稳定；再移走中间一件目标装备，只有该槽记为跳过，其余可证明候选继续换上。`ambiguous/read_error` 仍必须 fail-closed。
2. **治疗辅助真实团队结构**：单团 50 人必须呈现“上 1–25 / 下 26–50”，两个半区均 5×5，整体对齐约 340×400 原生名单。切原生“团队1/团队2”标签时 Auto Panel 必须跟随；启用额外友军团队 UI 后，用 A/B 同时对齐两个完整 50 人团队。Reload 后位置保持，`.18.127` 生成的 670×180 应自动迁回正确尺寸。
3. **Unit Lines + Range Assist 投影恢复**：连续切换 target/focus、360°转镜头、进出室内/副本；Camera Frame 短暂无效后两个功能必须能自行恢复点/线。Camera Frame 正常时背后目标仍应被 front-hemisphere fence 隐藏，禁止永久 Native-only 绕过。
4. **跑商快速切路线**：快速连续切起点 A→B→C 与终点 1→2→3，最终只能显示 C→3。请求期间不得并发发出不可区分的 Native ratio 请求；6.5s timeout 后可继续。若测试环境能观察到 timeout 后极晚旧回调，必须记录时间线，因为 Native 事件无 request-id，Lua 无法完全归因。
5. **债券日快照/去重**：当天首次进入某大陆后记录读取；Reload、切筛选、改排序不应再次读取该大陆居民板。切到当天尚未采集的另一大陆允许读一次。验证西/东“皮革20”只保留优先大陆且完成状态共享，但皮革20/60/100必须仍为三项。跨服务器日期后快照应失效并重新采集。
6. **整理背包 UX + 满仓继续**：鼠标分别悬停 `取/放/停`，应在指针附近显示准确说明。仓库无空槽但 B 物品存在未满同类堆时，A 无法放入只能局部跳过，B 必须继续堆叠；Native 读失败/identity 不可证明仍全局停止。
7. **活动悬浮 Tooltip**：第一列、最后一列以及窗口边缘的活动行分别悬停，说明框应跟随真实鼠标并做屏幕边界约束，不得再跑到左侧远处。
8. **首领机制**：开启 Boss 模块与 HUD，选择一个 Catalog 中有规则的真实 Boss；记录目标开始施法时的本地化技能名、警报是否在施法开始阶段出现、自身获得规则 Debuff 时是否触发。关闭 HUD/Feature 后 Casting/Aura Demand 与 Boss Scheduler 必须释放。若不触发，保存 `CastingObservationV3` / Aura / Boss health 证据，不用聊天字符串兜底。
9. **状态显示 HUD Inspector**：进入 `状态显示 → HUD布局`，依次选 Buff、Debuff、职业、装备等元素；右侧 Transform/Anchor/吸附设置必须按真实 Measure 向下布局，不能再出现控件互相覆盖。Compact Drawer、滚动、Apply/Reload 均需验证。
10. **门禁**：Fresh Reload 记录 Foundation v119 / UIV3 Acceptance v74；当前本地基线为 Active/All Lua 221/221 Parse PASS、Foundation Audit PASS、30/30 Python Harness PASS。

## `.18.126` Range Assist Global Projection Fresh Reload 专项（历史；范围辅助当前验收走 `.18.129` §1 与 `.18.129d` label 点模型）

1. **圆心/世界空间**：打开 战斗→范围辅助，保持自身移动并依次朝东/西/南/北方向转动相机。范围圆必须持续以自身脚下/角色位置为中心，不得随镜头方向产生固定偏移或漂移。重点对比非 1.0 UI scale。
2. **360° 相机 + 稠密索引**：缓慢旋转相机 360°。圆周位于相机背后的采样点可以隐藏，但后续重新进入前半球的点必须继续显示；不得因为第一个不可见点导致整圆消失或只剩固定短弧。正常视角至少应有 3 个可见点。
3. **分辨率矩阵**：分别在 1024×768、1920×1080、2K 验证半径、点大小、透明度、颜色以及 Apply/Reload；视觉圆心与半径变化方向应一致。
4. **生命周期/诊断**：打开 Range Assist 时才允许存在其 200ms Demand task；关闭页面 Consumer/Feature 后对应任务必须释放。若投影不足，记录 `ScreenProjectionV3:GetHealth()` 与页面 `partial/unavailable` 原因，不允许回退到 local-space 或稀疏 batch。

## `.18.125` Integrity v3 Canonical Fresh Reload 专项（历史；Integrity 部分已被 .18.129a 的 v4 契约取代——以最新横幅 `integrity=4` 与 v3Upgrade 计数为准）

1. **禁止清 `v3.tasks` / `v3.death_review`**：直接覆盖 `.18.125` 后 Fresh Reload。旧 v2 档应出现一次 `v3Upgrade>=1/1`（`integrity_upgrade_recovery` → `integrity_v3_upgrade` 重盖）且 `integrityFail=0 / Fence=0`；第二次 Reload 起应为 `verified_canonical`，不再重复 upgrade recovery。诊断页 Store 行可复制 `完整性 verified_canonical`。
2. **默认恢复范围（2026-09-05 第二份横幅后翻转）**：所有 v2 旧档 mismatch（含 bonds / gear.payload / death_review.record 分片）都应出现一次 `v3Upgrade` 增长并恢复，第二次 Reload 起为 `verified_canonical`；只有显式 `allowIntegrityUpgrade=false` 的 Store 才保持 fail-closed。真实内容损坏（decode/budget/schema 不过）在任何策略下都继续 `STORE_INTEGRITY_FAILED`。
3. **Unit Lines**：连续快速切换目标/焦点并穿插清空目标。`UnitLines:` 诊断行 `aliasKept/aliasReject` 允许增长；注入性验证：制造 3 次调度回调异常后任务应于 2–4s 自动恢复（`GetHealth().faultResumes` 增长），不再需要 reloadui。
4. **Buff 装备证据优先**：开启功能后复制 `BuffGear:` 行。`icons>0`：验证 Self HUD 四开关；`errors>0`：按 lastError 收敛；`itemKeys=...`：说明 RU tooltip 无已知 icon 字段，按样本键名修复（下一轮）。`unresolvedSlots>0` 即 `ES_BACKPACK` 缺失，背部保持 unavailable，不猜 slot。

## `.18.124` RU Hotfix Fresh Reload 专项（历史，被 .18.125 覆盖的 Integrity 部分以 .18.125 为准）

1. **禁止清 `v3.tasks`**：直接覆盖 `.18.124` 后 Fresh Reload。旧 Store 若正是本轮已证明的 tracking-map serializer shape mismatch，可看到 `shapeRepair>=1`，随后 `shapeResave>=1`；必须同时满足 `integrityFail=0 / Fence=0`。再次 Reload 后不应为同一个 Store重复 shape repair。
2. **Service Boundary**：复制 Foundation 诊断，`service_presentation_boundary` 必须通过，不能再出现 `AuctionSurfaceV3:missing` 或 `CraftSurfaceV3:missing`。随后分别打开拍卖行/制作窗口，Sidecar 仍只在原生窗存在时按既有生命周期显示。
3. **Unit Lines World Alias**：打开 self↔target 连线，连续快速选择多个玩家/NPC并穿插清空目标，至少复现原来“只剩自身一个点”的切换节奏。线端点不得再被压到自身；若 RU 提供 stale world fact，`ScreenProjectionV3:GetHealth().worldAliasGuards` 应增长。相机背后目标仍必须隐藏，不能用 alias guard 绕过 front-hemisphere fence。
4. **Buff Display 自身装备**：进入 `状态显示 → HUD 布局`，无需先在树里找元素即可看到 `主手/副手/远程/背部` 四开关。开启主手/副手/远程→Apply，自己的对应图标应出现；换武器后应在事件刷新或 1000ms drift backstop 内更新。关闭→Apply 后图标消失，Reload 后开关保持。
5. **背部 Slot 不猜测**：如果本 RU 客户端导出 `ES_BACKPACK`，开启背部后验证真实背部装备；若没有该常量，记录诊断并保持 unavailable，禁止把 `EST_BACKPACK` 或任意整数当 slot。
6. **失败证据**：若 `v3.tasks` 仍 fence，复制 `oldFingerprint>loadedFingerprint`、`shapeRepair/shapeRepairFail`、Envelope 计数；不要重置任务追踪。若 Unit Line 仍塌缩，记录两个端点 token、Native screen/world reason 与 `worldAliasGuards`。

## `.18.113` Persistence v8 / Integrity v2 Fresh Reload 专项（历史 P0，继续保留）

1. **先保留旧 Store，禁止 Reset/Clear**：直接覆盖 `.18.113` 并 Reload。首个新 generation 必须能读取此前报 `fingerprint_mismatch` 的 ordinary Store；允许看到 `v1Compat>0`，但必须 `integrityFail=0 / envelopeFail=0 / fenced=0`。旧 `death_review/healer/launcher` 不应再因相同 hash mismatch 进入 write fence。
2. **升级落盘**：等待一次正常 Persistence Tick/Flush 后，`v1Resave` 应增加；再次 Reload 后这些已升级 Store 不应重复增加同一批 `v1Compat`，并继续保持 `integrityFail=0`。不要通过清配置让数字归零。
3. **启动写隔离**：若 App/Shell/Launcher 任一 Store 仍因其它真实原因进入 session fallback，本会话导航、拖主菜单、移动 R 都不得继续增加 `writeBeforeLoadReject`。Fresh generation 正常目标是 `writeBeforeLoadReject=0`。
4. **Build Transaction 下游恢复**：依次打开此前失败页面。Fresh generation 要求 `页面失败=0 / 隔离=0 / 事务回滚=0 / 事务失败=0 / pageQ=0 / txFail=0`。若仍失败，复制第一个具体 page transaction reason；禁止给页面绕过 `EnsureStoreLoaded()`。
5. **Startup degradation**：若 `runtime_startup_degradation` 仍为 warning，复制 `startupWarnings` 中首个 `feature id:reason`；v8 只消除由旧 Integrity false fence 引发的降级，不应吞掉真正独立的 Feature 启动故障。
6. **Critical Store 保持 fail-closed**：Gear Index/Payload 等 `verifyAfterSave/recoverableReplacement` Store 不允许使用 v1 compatibility mismatch 逃生。若这些 Store 报 integrity mismatch，仍按 Critical Journal 故障处理并保留证据。

## `.18.112` Input Focus + Drag Hit-Test Fresh Reload 专项（当前第一交互验收）

1. **新进程键盘基线**：完整退出客户端后以当前 `.18.113` 累计包启动，先不要打开 Replicated Suite；测试 WASD、技能快捷键、聊天框输入/发送。插件不得在未打开任何输入页面时占用键盘。
2. **主菜单拖动**：R 左键打开主菜单，从顶部 title bar 空白区域连续拖动至少 5 次；必须每次立即跟随。再从 8 个 resize edge/corner 测试缩放。拖动/缩放结束后不得继续黏鼠标。
3. **Generic WindowShell**：至少打开一个 FloatingSurface/通用 WindowShell，拖 title bar 与 resize handle；验证不是只有主 Shell 特例可拖。
4. **Focus 归还**：点击任意 TextInput/NumericInput 取得编辑焦点，分别执行“切换页面”“关闭主窗口”“关闭所属 Modal/FloatingSurface”。每次动作后立刻测试 WASD/技能键；隐藏控件不得继续吃键盘。
5. **Diff-cache 边界**：重复关闭同一页面/窗口两次（第二次 logical visible 已为 false），键盘仍必须正常；这是验证 focus cleanup 发生在 Ensure* cache early-return 之前。
6. **Hot Reload 旧世代退休**：让 TextInput 保持 focus 时执行恢复 reload；Reload 完成后不打开 Suite，立即测试游戏键盘。旧 generation 的 EditBox 不得残留 keyboard/focus ownership。
7. **Modal Scrim**：打开含 backdrop-dismiss 的 Modal，点击遮罩区域应能命中/关闭；验证 `Border(pickable=true)` 已真实下沉，而不是只在 Lua spec 中存在。
8. **Recovery Failure 模式**：仅在真实 Startup Failure 时 Recovery Command Bar 才允许取得键盘；恢复/隐藏后必须归还。若 Persistence Flush 故障，`reload` 仍应告警并加载覆盖后的新文件，strict durability 路径才允许阻断。
9. **失败证据**：出现“可见但拖不动”“关闭窗口后键盘仍失效”“只有点击聊天框后才恢复”等任一现象，记录具体 Widget/页面、是否刚聚焦 EditBox、BuildTag 与 `BootStage/R/CMD/ESC`；禁止在业务页面再加 `ClearFocus/EnablePick` 特例，继续回到 Input Lifecycle/Windowing Foundation 排查。

## Persistence Reliability v7 Fresh Reload 矩阵（当前 P0）

使用 `.18.100` **新进程**执行，禁止用同一热重载世代的旧状态冒充跨进程回读。**第一步执行下方 `.18.100 Gear Critical Journal + Persistence v7 专项`**，确认换装 Payload 能保存、Reload、完整退出重进并再次应用；通过后再继续状态显示及 `.18.94` Trade/DPS 回归。进入 `combat.buff_display` 时页面必须成功构建，`v3_build_transaction_contract` 的 Page failure/quarantine/transaction/preflight 计数在新 Generation 中保持 0；进入“HUD 布局”后拖动/缩放 Selection Overlay，指针移动与元素变化方向必须一致（左上原点：X+ 向右，Y+ 向下）。当前截图宽度属于 Compact 模式时，Toolbar 必须出现 `[属性]`/`[收起属性]`，进入 HUD 布局后属性 Drawer 应自动打开；选中元素后必须能看到并编辑 X/Y/宽度/高度以及适用的 Anchor/Pivot/Snap 参数。

**`.18.89` Interactive Draft 专项**：保持状态显示功能开启并让 Aura 事实持续更新。① 连续拖动 HUD 页任意 NumericField Slider，滑块必须稳定跟随鼠标，不能一帧预览值、一帧旧值来回闪跳；② 点击同一字段的精确 NumericInput，删除/输入部分字符后停留至少 1 秒，文本必须保持当前 draft，不能被旧 Binding 回灌；按 Enter/EditEnter 或失焦后才按既有规则 Commit/校验并格式化；③ 在 Compact Drawer 开/关、切换选择元素、普通 Refresh 后重复测试。

| 域 | 重点 Store | 操作 | 必须通过 |
|---|---|---|---|
| Buff Display | `v3.buff_display` | 改追踪/分类；HUD Layout 做 Preview→Reset/Revert→Apply；立即点“重新加载文件” | 未 Apply 的 Working 不进 Store；Apply 后 Reload 回读一致；Flush 失败时应记录 Store+原因并继续 Recovery Reload，未保存修改允许丢失 |
| Healer | `v3.healer` | 改标量/规则/raid panel 几何与团队绑定；Feature Disabled 状态也编辑一次 | disabled 不清永久配置；Reload 后 panel 模型/颜色/设置一致 |
| Gear | `v3.gear.index` + legacy `v3.gear.payload.N` + 新 `v3.gear.payload.N.a/.b` | `获取当前→保存`；本进程应用；Reload 应用；完整退出重进应用；再次保存让 A/B 翻转 | Index 与 active/backup Domain 指纹一致；Critical verifyFail=0；v7 integrity/envelope/decoded/unverified reload failures 均为 0；新 active 只有回读验证后才能提交；Reload 后真实换装仍成功 |
| Activities / Tasks | `v3.activities` / `v3.tasks` | 改悬浮窗尺寸/透明度、追踪/隐藏项，连续拖动后立即重载 | debounce 未完成时 Reload barrier 先安全 Flush；回读保持 |
| DPS | `v3.dps` | 改模式/指标/side/self/rows 后立即重载 | 页面与 Widget 使用同一 Store 结果，不出现当下成功、重载回退 |
| Trade | `v3.life.trade` | 改生产地/售卖地/排序/收藏并重载；退出客户端再进入 | route/favorites 跨进程一致；普通 Refresh 不触发隐式拍卖扇出 |

每轮修改后先到“诊断与维护”观察 **新版存档 / 最近存档落盘**，并点一次 **“输出存档验收”** 保存 Fresh Reload 前的只读 Domain 指纹。随后执行“重新加载文件”或完整退出客户端再进入；进入后先重新打开本轮涉及的 Feature，使它们按正常业务路径完成 Store Load，再次点“输出存档验收”。同一个 Store 的指纹必须一致；`ALL` 只有在 Store coverage 相同（尤其 `v3.gear.payload.*` 注册/Load 数量相同）时才直接比较。连续 Slider/拖动后立即重载的测试允许前置快照 `Dirty=1`，但重载成功后的快照必须 `Dirty=0/Fence=0` 且 Domain 指纹一致。若 `Fence>0`、`FlushFail>0` 或 strict durability 重载被取消，立即点“输出诊断摘要”；`.18.90` 摘要必须直接带出 `存档故障 <store id>:<reason>`。**不要清空 Store、不要重置默认值来让 Gate 变绿**。

### `.18.100` Gear Critical Journal + Persistence v7 Durability/Integrity/Scope/Generation Fence 专项

1. **正常新保存**：选择方案，先穿一套容易辨认的装备，执行“获取当前→保存方案”。诊断中 `readbackVerifyAttempts/readbackVerifySuccesses` 与 `integrityStampedSaves` 应增加，`readbackVerifyFailures=0`。若保存 UI 报 `readback_verify_failed`，不要继续覆盖该方案，复制 `v3.gear.index` 或 `v3.gear.payload.N.a/.b` 的具体 reason。
2. **同进程应用**：换成另一套装备后点击该方案；必须根据保存的装备 name/grade/modifier/itemType 找回真实背包物品，而不是只显示“已配置”。
3. **Reload + 跨进程**：先 Reload 再应用一次；随后完整退出客户端、重新启动、打开 Gear 后再应用一次。两次都必须成功；v4/v5 stamped save 在每次新进程读取后 `integrityLoadChecks` 应增长，`integrityLoadFailures=0 / encodedLoadRejects=0`。方案名称存在但 `LoadPayloadForSet` 报 empty/structure invalid/fingerprint mismatch/integrity_failed 均视为失败。
4. **A/B 翻转与自愈**：在同一方案重新“获取当前→保存”，确认新 revision 写到另一 bank；保存 Index 之前 bank 必须已经 readback verified。Reload 后 active bank 可用。若 active bank 确认损坏而 backup 指纹完整，允许出现 `GEAR_PAYLOAD_BANK_RECOVERED` 并继续使用上一份 verified payload；下一次显式保存可出现一次 `STORE_VERIFIED_REPLACEMENT_RECOVERED`，但只能在新 bank 回读成功后清 fence。`future_schema/load_failed` 不得触发 replacement。
5. **历史损坏方案修复**：如果旧版本已经只剩方案名称，原装备明细无法被代码推导恢复。选中该方案后由用户明确执行“获取当前”，再保存一次；这一步才允许 `GEAR_PAYLOAD_REINITIALIZED`，之后它必须进入 A/B journal。直接点击“换装”或“验证”不得自动以当前装备覆盖历史方案。
6. **性能边界**：readback 只应随显式 Gear/critical save 增长；普通页面刷新、Tick、Gear 快捷按钮 idle 不得持续增加 verify attempts。普通非 Critical Store 正常 debounce 保存仍只增加 bounded integrity stamp，不应立即产生 `LoadData`；但用户显式 Reload/Runtime Stop 时，若 `barrierPending>0`，Flush 必须各做一次 bounded readback。Critical Gear immediate verify 已成功的 Store 不得被 barrier 重复读。
7. **失败证据**：任一 `integrity_failed / encoded_load_rejected / readback_verify_failed` 都视为本轮 P0 失败；立即复制 Foundation 摘要中的 store id + reason，不要 ClearStore/恢复默认。pre-v4 老 Store 首次读取出现 `integrityLegacyLoads` 属兼容路径，不是失败；v4 stamped Store 在 v5 中必须继续可读，它下一次保存自然升级为 v5 stamp。

8. **Durability Barrier 专项**：修改任意普通 Store（例如 DPS/Trade/窗口设置），等待 debounce Save 完成后先观察 `barrierPending>0`，再点击“重新加载文件”。重载前 Flush 必须使 `barrierVerifyAttempts/Successes` 增长；如果回读不一致，必须输出 `barrier_verify_failed:<reason>`，同时该 Store 重新 dirty 等待有界重写；Recovery Reload 仍继续加载新文件，strict durability 路径才取消。不得出现“Flush 认为 clean 所以直接放行”的旧行为。
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
| Unit Lines / Range Assist | 在 1024×768 / 1920×1080 / 2K 与不同 UI scale 放置已知目标；Unit Lines 分别测试近距离、远距离、端点出屏但线段穿屏、斜角贴边；记录 `CombatVisualGuidesV3:Describe()` 的 visibleDots/visibleEdges/clippedEdges/budget；Range 继续记录世界/屏幕坐标与已知半径 | Unit Lines 近距离保持基础密度，远距离自动增加 dots；端点出屏但可见段穿过 viewport 时只裁剪到边缘而不整段消失；refresh≤16ms 时总 dots≤256，默认 100ms 时≤480；真正整段出屏或 `behind_camera` 继续隐藏。Range 缩放/裁切正确 | 若 watchtarget/屏幕坐标字段不符，保留 blocker；不得为了解除消失问题绕过 ScreenProjectionV3 v6 front-hemisphere/consistency/world-alias fence，也不得重新启用 `GetUnitsInSight` |
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

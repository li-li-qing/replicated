# 战斗统计与分析整合清单

用户于 2026-10-05 明确要求开始实施；后续明确“标记完成”指导航中的功能方案。

| 编号 | 工作及验收 | 状态 |
|---|---|---|
| CS-001 | 复用唯一 CombatEventBus/CombatAnalytics，默认 self，all 显式选择；范围保存失败回滚原订阅 | 已实现，离线验证通过 |
| CS-002 | 自身模式在指标分发和 Actor 建表前过滤；不记录别人的排行行 | 已实现，离线验证通过 |
| CS-003 | 个人永久 Store：伤害、承伤、治疗、玩家击杀、死亡、推断助攻、记录起止时间；重载回读，实时清空隔离 | 已实现，正式存储封装回读通过 |
| CS-004 | 合并为一个主导航与统一启停；页内战斗总览/专项分析/个人历史/统计设置视图，支持日期查询 | 已实现，正式 RSUI 回归通过；RU 布局待验 |
| CS-005 | 功能方案导航开发状态按用户裁定改为 complete；不把离线测试写成 RU 实测 | 完成 |
| CS-006 | Lua 5.1 编译、迁移/死亡去重/存储失败/通道与生命周期回归，记录真机待验步骤 | 离线通过；RU 实机 not_run |
| CS-007 | 用户补充：只统计自己时不累计助攻，所有人模式保留推断；禁用自身助攻排行，保留历史 | 已实现，指标与正式 RSUI 回归通过 |
| CS-008 | 回放用户导出：战斗设置 schema1 原章恢复、参考价格旧规则迁移、统一导航自检 | 已实现，正式 Persistence 导出回放通过；RU 重载待验 |
| CS-009 | 新诊断与截图：梳理结果/采集/悬浮/首领设置，四个页内视图，共享范围 | 已实施；导出快照无记录错误，非完整战斗覆盖 |
| CS-010 | 自身默认明细、空明细收起、低频配置独立设置页；原全员双栏方案 | 历史阶段离线通过；双栏呈现已由 CS-012 替代 |
| CS-011 | 正式 RSUI 宽/窄窗口、选中状态与设置命令回归；不新增采集监听 | 940/620/480 客户区离线通过；RU 实机 not_run |
| CS-012 | 用户修正：以玩家为一行，同时显示伤害/击杀/治疗/助攻/承伤/死亡；一个全宽总览、阵营筛选、基础统计同周期 | 已实现，15项脚本回归和303个TOC编译通过；RU 实机 not_run |

事实边界：只记录功能开启且客户端可见的事件；NPC 不计入个人“杀人”；只统计自己时不统计助攻，所有人模式按已有10秒伤害窗口推断助攻，历史已保存助攻保留。缺失最后一击来源时不把自己的最近伤害当成确定击杀。服务器日期时间以分钟精度记录；无时钟样本时保留未定日期统计。最多保留2048个日摘要，超出后累积进明确标注的早期归档；全期累计不丢失，涉及早期归档的日期筛选标为不完整。

复用的 API/事实：UnitIdentityV3 缓存、CombatFact、S.Utils.GetServerTime、Persistence；不增加原生监听或全场轮询。2026-09-22 官方公告未涉及本路径；2026-09-29 公告只变更 X2Map:ShowWorldmapLocation 可选 isGlobal 参数，与本任务无关。原始证据：[09-22](https://ru.archerage.to/forums/threads/server-update-22-09-2026.17582/) / [09-29](https://ru.archerage.to/forums/threads/technical-restart-29-09-2026.17596/)。旧日期 overlay 仍按最新公开公告核对，不将本轮当成全 API 清仓。

能力与职责：本地读写/PowerShell/真实 Lua 5.1.5 可用；测试使用替身 Native，RU 实机与帧耗未验证。已读取并应用 skillforge-orchestrator（路由/清单）、Replicated Suite 维护技能（V3 边界/存储）、UI 设计（统一视图/可读状态）、测试与完成核验技能（失败用例先行、真实验证）。上下文 KEEP，未宣称执行压缩或交接；无子代理，未新增仓库分支、提交或发布。

实现边界：两项旧 Feature ID/route 保留，主导航仅显示战斗统计与分析。Registry.preferenceGroup 声明组合，FeatureRuntime 在既有 durable 批量事务中扩展目标；旧矛盾目标以主功能为准，旧分析单选方案以只读解释继承。存档 v3.combat_analytics schema1→2 保留指标选择/开关，新增 scope 默认 self；v3.dps schema4 和原窗口状态不变。个人历史使用 v3.combat_personal_history schema1、Character/Permanent。未知目标类型击杀单列；死亡 notice 有界暂存1.5秒等直接来源，全体共享一个 Scheduler one-shot。

验证脚本（不进 TOC / 发布运行时）：

本轮命令输出已保存到 `.workbuddy/tmp/combat_statistics_verification_2026-10-05.log`，四组验证退出码均为0。

- Addon 根目录：`lua .workbuddy/tmp/combat_statistics_history_test.lua` — 迁移、范围、KDA、回读、清空隔离、原生/持久化失败回滚、死亡去重与 notice-first。
- Addon 根目录：`lua .workbuddy/tmp/combat_statistics_dps_pipeline_test.lua` — 正式 DPS Store/Feature/Domain 通过共享指标流，只积累自己/恢复所有人/停止清理。
- Addon 根目录：`lua .workbuddy/tmp/combat_statistics_runtime_group_test.lua` — 组合启停、旧路由/矛盾方案、偏好事务回滚、旧分析单选方案兼容。
- replicatedsuite 目录：`lua ../.workbuddy/tmp/combat_history_persistence_ui_test.lua` — 正式 Persistence envelope/Flush/回读、日范围和 RSUI 历史页。
- replicatedsuite 目录：`lua ../.workbuddy/tmp/combat_statistics_pages_test.lua` — 正式伤害排行/行为分析页构建、激活、范围更新、停用；打开页面没有开启采集。
- replicatedsuite 目录：`lua tools/rs_feature_profiles_tests.lua`、`lua tools/rs_navigation_status_acceptance_tests.lua`、`lua tools/rs_service_boundary_contract_tests.lua`、`lua tools/rs_core_feature_decoupling_tests.lua` — 既有回归；分别通过，解耦128项、服务边界5项、导航11项。
- 真实 `luac -p` 检查当前 TOC 的302个 Lua 文件，均通过；新增4个运行时文件已登记依赖顺序。

本日用户错误导出复核：接收工具从游戏已提交快照生成 `诊断报告/RS-20261005-055832-042369-1.3.txt`（347562字节，正文校验通过）。报告有5项 blocker、1项 warning、4条已记录错误；2条页面失败由战斗偏好完整性失败级联产生，另有参考价格存档失败和旧双导航按钮检查。

- 战斗偏好：原章 `43314CB5`，新增 scope 后 `06DA8E1A`；schema1 固定字段投影去除新增字段后精确复现原章。Store 提供旧投影与当前 Domain，Core 仍验证 metadata / envelope / budget / 完整原章，再按 schema2 保存。
- 参考价格：原章 `7BB8B6E7`，当前过滤旧 `name_search_direct` 错误整单价后 `1957E030`。按旧来源保留规则和既有时间取整复现原章；迁移结果仍剔除已证实的错误来源，正常单价来源与样本保留。未修改用户原始存档、未清档、未增加未知 Hash 放行。
- 导航自检：`v3_combat_navigation_contract` 改为一个主导航与伤害/分析/历史三项页面工厂；重复左栏入口或任一缺失仍为失败。
- 新增离线反例 `.workbuddy/tmp/combat_export_replay_test.lua`：解析数据协议，不执行报告内容；正式 Persistence 精确复现修复前失败。修复后导出加载/重新保存/回读均通过，未知原章仍 fence，正常价格保留。
- 新增 `.workbuddy/tmp/combat_navigation_contract_test.lua`：执行正式 Foundation 检查段，修复前正确合并导航误报失败，修复后通过；重复导航与缺失工厂反例被拒绝。
- 重跑7项战斗定向脚本、报价安全23项、材料队列17项、正式诊断17项、方案与服务边界/解耦回归均通过。日志 `.workbuddy/tmp/combat_statistics_correction_verification_2026-10-05.log`。原先只验证新建存档的通过不足以覆盖旧版 canonical 迁移，本轮增加真实导出回放；没有把离线成功当作 RU 修复确认。

本轮模块整理与布局：

| 页内视图 | 主任务 | 保留的常用操作 |
|---|---|---|
| 战斗总览 | 每个玩家/单位一行，伤害、击杀、治疗、助攻、承伤、死亡同时显示，附DPS | 六项列头排序、全部/友方/敌方筛选、所选人的PVP/PVE技能明细、悬浮窗、实时清空、待确认数据 |
| 专项分析 | 战斗段、技能、控制、演奏、辅助和机制等深入明细 | 项目下拉、可换行数值按钮、当前/全部分析清空、全员玩家对比 |
| 个人历史 | 当前角色长期战绩与日期范围累计 | 日期筛选、全期累计与早期归档说明 |
| 统计设置 | 低频采集与显示配置 | 九项分析启停、排行行数、悬浮阵营、始终显示自己、首领名称 |

- 四页共享“只统计自己 / 统计所有人”。九项采集分为战绩与输出（击杀/死亡、战斗过程、输出表现）、技能与控制（技能活动、控制贡献、辅助贡献）、状态与机制（演奏、Buff/Debuff、首领机制）。设置只调用既有 Commands/Binding，不增加 Native API、Consumer、定时采集或默认值副本。
- CS-012 采用一个全宽总览，友方/敌方改为过滤条件，宽窄窗口都不拆两表。自身默认选中自己，助攻显示“未统计”，而非0；六项表头可排序。技能/目标明细与PVP/PVE筛选归所选人的详情区域，基础列表不再按伤害/治疗分开切换。未选中时收起详情；仅有战绩记录的人仍保留在表中。
- 布局回归发现范围切换仅清掉分析指标，而 DPS 的 Reset 只结束战斗段，旧全员 Actor 仍存在。DPS 指标现在仅对 `collection_scope_changed` 调用既有 ClearStats；暂停/释放仍走 ResetTransient。两方向范围切换均清空实时排行，个人历史仍保留。未改 Store schema。
- 接收 `诊断报告/RS-20261005-061323-182268-MD1.1.combat_statsr1.txt`，21607字节、正文校验通过：错误/警告/写入保护/采集失败均0，enabled/initialized为true、scope=self。但快照 events=0，只有伤害模块及其Store，不能证明全场战斗、分析/历史全部路径或CPU/FPS。`busSubscribed=false` 是 DPS 已取消直接订阅的预期状态，`analyticsHeld=true` 表示由共享分析服务承载。
- 新增离线 `.workbuddy/tmp/combat_statistics_workspace_layout_test.lua`，真实 RSUI Measure/Arrange、TableView、Commands、ActionRunner、正式 Persistence + 共享指标/DPS Domain；Native 绘制为替身。验证940/620/480客户区实际父链裁剪、九项设置、首领添加/移除与成功清空输入、自身选中/明细、全员宽窄切换、辅助八维按钮换行、范围清空/暂停保留/个人历史隔离和停用后零Consumer。
- 最终真实 Lua 5.1.5 对当前 TOC 303 个 Lua 文件编译通过；新增设置页已登记依赖顺序。8项战斗定向脚本 +6项相邻回归（诊断17、导航11、服务边界5、Core解耦128、功能方案、保护页）全部退出0；改动的跟踪源码 diff whitespace 检查通过。输出保存在 `.workbuddy/tmp/combat_statistics_workspace_layout_verification_2026-10-05.log`。
- 当前 V3 使用 Router + PageHost + RSUI 自适应布局，不再存在旧 SearchSettings/OpenSuitePage/ApplyLayout 派发接口；新设置注册隐藏子路由并由四页导航可达。旧维护手册文件在当前工作区不存在，未依据旧技能路径创建替代手册；本页记录实际模块映射与实现边界。

RU 实机待验（本轮未运行）：重载后确认一个主导航及四个页内视图、功能方案无未完成标签；自身模式打一场确认自己的明细自动显示且没有空敌方栏；全员模式缩窄窗口，点击友方/敌方核对两侧数据；设置页滚动核对九项启停、首领输入与鼠标命中；分析页切辅助八维看按钮换行；用两种范围各打一场并看多人团战帧耗；重登后按日期回读，再切另一角色核对隔离；清空实时统计后确认历史保留。

CS-012 实现与验收（用户要求改变信息组织，继续原任务）：

- `DPS:GetCombatOverview()` 组合已有 Domain 与共享 kills 指标投影；不另建长期累计或新监听。按精确名字与世界连接，保留显式不同世界的同名玩家。PVP/PVE 的伤害、承伤相加，共享治疗只合并一次；DPS按两个模式的有效伤害活动时长合计。只读候选每个模式/阵营有界512，显示行数仍1~150，原采集数据没有被截断或清档。组合投影按generation/伤害revision/战绩revision/范围/指标偏好缓存。
- 公共伤害排行保持既有默认投影；总览只读路径使用 includeZero 候选，不提前丢掉纯治疗和只承伤的人，KDA projection 的 includeZero 加入仅有死亡的人。六项统一排序后再截显示行数，明细选择、阵营过滤与主列表排序互相独立；修正旧排序比较器and/or导致的升序非严格排序问题。
- 生命周期 resetKind 区分停用和显式清空。kills 停用只释放推断目标账本/死亡通知任务，保留实时战绩；暂停与恢复不导致基础六项期间不同。主列表两次确认清空通过 ClearOverview 一起清伤害和战绩；范围切换仍统一清空。个人长期历史Store完全隔离，schema不变；九指标关闭战绩时列显示“关闭”，不把未采集值冒充0。
- 新测试用一次 NPC 死亡复现实时kills包含NPC而个人历史不包含NPC的口径差异。实时玩家K/D/A现只计可靠玩家目标和玩家来源，已知NPC不计玩家击杀/死亡/助攻；未知目标仍按原个人历史未确认分类，不伪装成确定杀人。
- 所选人的PVP/PVE和技能数值筛选放在详情内；悬浮窗PVP/PVE设置移入集中设置，仍写原 v3.dps.mode。旧route/id与所有存档键保留。没有新增运行时文件、Native API或采集Consumer。
- `.workbuddy/tmp/combat_statistics_overview_test.lua` 实际加载共享指标、DPS Domain/Feature、正式 RSUI/Commands/Persistence：验证六项同人、PVP/PVE合并、共享治疗不重复、NPC不计玩家击杀、零伤害治疗者、仅死亡、跨世界同名、六项排序/升序、明细不改变主排序、940/620/480真实父链裁剪与每个表头、停用恢复保留战绩、两次清空与历史隔离、无额外Consumer。旧布局测试同步替代为单列表要求。
- 最终9项定向+6项相邻脚本退出码全部0；真实Lua5.1.5编译303个TOC文件、修改源码diff空白检查通过。日志 `.workbuddy/tmp/combat_statistics_overview_verification_2026-10-05.log`。RU未运行，请重点看同一行六个数值、表头排序、详情模式切换、全员筛选及窄窗口字体/鼠标命中；团战帧耗待实测。

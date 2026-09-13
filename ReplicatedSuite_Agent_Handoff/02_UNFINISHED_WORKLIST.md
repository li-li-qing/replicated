# 未完成功能：历史种子与执行顺序

来源：本会话原包 + 9份后续补丁组成的参考树，2026-09-13读取。通过真实Registry注册逻辑离线求值得到 **40条功能记录、24条未完成：19条可见、5条隐藏子项**。它不是用户本机扫描结果，不代表24项都没有实现。

完整字段在 [feature_inventory.json](evidence/feature_inventory.json)。判定沿`ResolveNavigationDevelopmentState`：显式complete/incomplete优先，再看blocked/status/readiness/verification/remaining。不要只搜中文“未完成”，也不要绕开显式用户验收覆盖重新给已完成项降级。该判定只服务导航，不是API或生命周期Authority。

## 开工前重新分类

读取当前本地Registry、实际页面/Commands、Authority/Service、测试与TODO；为每个任务写四项：**已存在的可操作能力、真实剩余缺口、可以离线验证什么、需要RU/权限证明什么**。下面所有条目初始均为`NOT_REVIEWED`。建议分组是排期建议，不是新发现的bug结论。

不要把“verification默认pending”的输出字段再单独重算一套导航：Registry使用注册时的spec得出展示状态，元数据默认值和显式覆盖可能不同。直接消费真实计算结果，并解释缺口。

## 建议顺序

开工P0只处理确会阻断本轮的入口/存档/诊断/测试基础问题。之后先核对A组的保护性回归与用户反馈，不持续无证据改动；有可执行代码任务时进入B组，建议从活动、任务、债券开始。C组边调查边登记最小补证需求，不堵住B组，也不为了“全部完成”解除门禁。

“完成目标模式”意味着安全可实施队列有真实交付、剩余项有精确阻塞与接续点；不意味着必须把所有导航标签去掉。已实现待实机单独计数，不与新开发完成、真实验收或研究阻塞混在一起。

## A：已有最近实现，先核对回归和实机缺口，不从零重写

| 功能/route | 入口 | 本轮可查证并推进的范围 | 保留边界 |
|---|---|---|---|
| **状态显示**<br>`combat.buff_display` | 侧栏可见 | PVP事实时效、职业图标校准、连续留存、导入/取消追踪、技能CD及重载逐项核对；保留近期修补，只修有证据的新缺口。 | 未完成元数据并不表示旧功能全坏；需要现场身份/延迟证据。 |
| **增益容量监控**<br>`combat.buff_cap` | 侧栏可见 | 两类计数、个人阈值、峰值、隐藏/后台需求、保存和界面验收。 | 未证明RU真实容量、共享槽位和顶替规则，不能扩大结论。 |
| **首领机制 / 战斗警报**<br>`combat.boss_alerts` | 侧栏可见 | 六秒测试、任务/文字提交、同名下一次施法、HUD调整保存、五条规则和可选未收录读条验收。 | 黑龙全技能库缺证据；不能用当前五条规则宣布覆盖完整。 |
| **随机商店计数**<br>`tools.random_shop` | 侧栏可见 | 原始读数、可见页自动读取、阈值草稿/保存、下降/断档、新观察段验收。 | 商店身份和周期未知，不能改成每日额度/自动刷新。 |

## B：优先推进有可靠事实来源的产品闭环（全部11项已完成闭环，待RU实机验证）

| 功能/route | 入口 | 本轮闭环结果与单测证据 | 待RU实机验证边界 | 状态 |
|---|---|---|---|---|
| **活动**<br>`life.activities` (B1) | 侧栏可见 | 关联海之烛台/鲸鱼歌湾任务组；支持任务进行期90m持续期保持；悬浮窗/详情/Demand增减/Schema8持久化全部闭环；单测 7/7 PASS (`tools/rs_activity_tests.lua`)；`v3_m1_activities` 门禁通过 | 需实机上报 102/103 区域阶段与真实进度显示截图 | `IMPLEMENTED_PENDING_RU` |
| **任务追踪**<br>`life.tasks` (B2) | 侧栏可见 | 日常/周常独立筛选与追踪；子任务与父组追踪联动；查看详情按钮/弹窗联动；跨日降级与持久化恢复；单测 10/10 PASS (`tools/rs_task_tests.lua`)；`v3_m1_tasks` 门禁通过 | 需实机验证日常/周常切换与任务详情浮窗 | `IMPLEMENTED_PENDING_RU` |
| **债券 / 居民板**<br>`life.bonds` (B3) | 侧栏可见 | 居民板1-7号板读取与空板/就绪区分；QuestProgress activeIndex 真实完成追踪；背包材料双槽位统计与缺口试探；每日快照与跨日刷新；单测 10/10 PASS (`tools/rs_bonds_tests.lua`)；`v3_m1_bonds` 门禁通过 | 需实机上报居民板交互及浮窗详情截图 | `IMPLEMENTED_PENDING_RU` |
| **住宅 / 税务**<br>`life.housing` (B4) | 侧栏可见 | X2House 4只读getter有界Authority投影；住宅信息与税务结构化展示；不在住宅旁显式降级；按需Demand生命周期；单测 10/10 PASS (`tools/rs_housing_tests.lua`)；`v3_housing_read_only_contract` 门禁通过 | 需住宅旁实机读取并验证税务字段返回结构 | `IMPLEMENTED_PENDING_RU` |
| **管家助手**<br>`life.butler` (B5) | 侧栏可见 | X2Butler:GetChargeInfo只读投影；动态host解析；充能点数/时间结构化解析；未召唤管家显式降级；内部事件按需发布；单测 10/10 PASS (`tools/rs_butler_tests.lua`)；`v3_butler_read_only_contract` 门禁通过 | 需召唤管家实机核对 GetChargeInfo 返回键值结构 | `IMPLEMENTED_PENDING_RU` |
| **制作规划**<br>`life.craft_planner` (B6) | 侧栏可见 | FindRecipes物品/编号/地区模糊检索；修复持有量为0时的缺口精准计算；递归成本图展开与防环截断；计划增删改清持久化与显式限速询价；单测 10/10 PASS (`tools/rs_craft_planner_tests.lua`)；三大制作门禁通过 | 需制作台实机核对原生制作配方树与材料展示 | `IMPLEMENTED_PENDING_RU` |
| **制作台助手**<br>`tools.craft_assist` (B7) | 侧栏可见 | 原生制作台（UIC_MAKE_CRAFT_ORDER等）几何+可见性双事实Fail-Closed观察；独立材料侧窗随原生制作窗口动态定位与关闭释放；单测 10/10 PASS (`tools/rs_craft_planner_tests.lua`)；`v3_craft_sidecar_contract` 门禁通过 | 需打开真实制作台核对侧窗停靠几何与位置 | `IMPLEMENTED_PENDING_RU` |
| **跑商**<br>`life.trade` (B8) | 侧栏可见 | SingleFlight路线查询并发与超时防卡；130%满货率模式/货率事件/三态排序；经商熟练度预计售价；材料显式限速报价队列（单批最多4项）；最多12条收藏持久化与HUD联动；单测 10/10 PASS (`tools/rs_trade_tests.lua`)；门禁双绿 | 需实机核对生产/可售地区payload与静态底价一致性 | `IMPLEMENTED_PENDING_RU` |
| **拍卖收藏**<br>`tools.auction_favorites` (B9) | 侧栏可见 | 收藏上限20条与去重持久化；9参数显式搜索；AuctionQueryV3单飞与超时看门狗；嵌套itemInfo与PriceQuoteQueueV3显式限速询价；随原生拍卖行停靠与销毁的AuctionSidecar；单测 10/10 PASS (`tools/rs_auction_favorites_tests.lua`)；门禁双绿 | 需打开拍卖行实机验证侧窗跟随与搜索/询价表现 | `IMPLEMENTED_PENDING_RU` |
| **团队中心**<br>`combat.team_tools` (B10) | 侧栏可见 | 全队职责只读；当前玩家自身职责设置（500ms冷却防抖）；职业模板自动职责匹配；头标快照上限16保存、1100ms串行恢复及逐项回读校验；牺牲之舞候选发现与共享Aura投影；成员移动严格保持Fail-Closed停用；单测 10/10 PASS (`tools/rs_team_tools_tests.lua`)；门禁双绿 | 需实机进组验证职责读取/设置、头标读写与牺牲之舞屏幕投影 | `IMPLEMENTED_PENDING_RU` |
| **团队战备检查**<br>`combat.raid_readiness` (B11) | 隐藏子项，保留路由 | 按需分片异步扫描团队装分（含RU千分位防御性解析）、职责/职业降级、关键增益（AuraObservationV3共享按需租约，仅扫描期持有）、距离与多状态收敛（ready/failed/unknown/info）、列表过滤（只看问题）、防抖持久化；单测 10/10 PASS (`tools/rs_raid_readiness_tests.lua`)；门禁双绿 | 需实机进团验证成员分片扫描与关键Buff检测准确度 | `IMPLEMENTED_PENDING_RU` |

## C：证据/权限优先；可调查但不得强行补齐写能力

| 功能/route | 入口 | 本轮可查证并推进的范围 | 保留边界 |
|---|---|---|---|
| **今日收支**<br>`home.daily_stats` | 隐藏子项，保留路由 | 保持服务器日账本，逐一查证金币/荣誉/经验/生活点合法实际变更来源及重复/重载策略。 | 缺provider时显示未接入；任务预计奖励或文本数字不是到账。 |
| **目标监控**<br>`combat.target_monitor` | 隐藏子项，保留路由 | 保留当前目标身份/距离，查仇恨目标是否有独立合法来源。 | 没有来源就保留范围限制，不猜目标关系。 |
| **团队招募助手**<br>`combat.raid_recruitment` | 隐藏子项，保留路由 | 可核对现有读取申请和关闭招募；调查创建9字段及接受/拒绝charIds形态。 | 不得拿不明参数尝试真实招募写入。 |
| **攻城战备检查**<br>`combat.siege_readiness` | 隐藏子项，保留路由 | 调查合法远程装备字段与攻城场景事实，定义可证明的最小只读范围。 | Registry为runtime_blocked；页面/静态词匹配不解除它。 |
| **钓鱼**<br>`life.fishing` | 侧栏可见 | 保留鱼Buff识别与技能推荐；自动R只做源槽位/空绑定/回读/回滚证据研究。 | 热键写入子能力继续SPECIFIC_RUNTIME_BLOCKED，不能猜绑定范围。 |
| **快捷键方案**<br>`tools.hotkey_profiles` | 侧栏可见 | 查官方action registry或完整profile契约；只能在获得证据后设计事务和恢复。 | 整个完整方案能力当前runtime_blocked；禁用随机action名/数字遍历和测试写入。 |
| **装备强化分析**<br>`tools.reinforce_analysis` | 侧栏可见 | 维护现有聚合只读；查合法equipSlotIndex来源及逐槽返回结构。 | 逐槽位独立阻塞；不能枚举猜测0..31，不能调用强化写接口。 |
| **传送配置**<br>`tools.portal_profiles` | 侧栏可见 | 查个人传送候选、稳定optionType、读取和写入回读证据。 | 当前runtime_blocked；不走未授权X2Warp或猜Option写入。 |
| **拍卖行情**<br>`tools.market_analysis` | 侧栏可见 | 只读当前挂单继续准确标示；调查有身份/时间/成交语义的历史来源。 | 没有成交来源就不画历史成交趋势、不把反复搜索样本伪装为成交。 |

## 每项的执行卡片

```text
Task ID / Feature ID / route：
当前状态：NOT_REVIEWED → READY / BLOCKED_...
当前范围、明确不做的范围：
真实入口/Authority/Service/Store/UI路径与符号：
用户可见完成条件：
缺口依据：用户观察 / 本轮源码 / 本轮执行 / 历史记录 / 假设
反例与预期失败：
最小实现及影响范围：
回归命令、解释器、替换层、退出码、日志：
保存/升级/停用/性能/隐私结果：
剩余实机步骤或最小补证：
变更文件与最终包：
```

## 两类不得自动重做的工作

当前参考中治疗辅助、单位连线、范围辅助、整理背包有明确导航完成覆盖。它们仍可能有范围外能力限制；不能仅因remainingCapability非空就推翻已确认范围。只有新的相关故障或共享底层受影响时做相应回归/修正。

此前首领、增益容量、随机商店、PVP/职业图标及模板默认已交付实现。遇到本地尚未覆盖，要先识别基线差异，不根据旧总结重造一份替代实现，也不默认用户已覆盖后重复迁移。

## 收尾分账

单独列：新完成代码闭环数；修复的复现问题；已有实现本轮只回归的项；待RU验收项；按API/证据/环境/授权分别阻塞的项。不要把加了占位页、采样按钮、静态规则文本或更新标签算作产品已完成。

# 来源、采纳与验证范围

**分轮阅读：** 下方首批/第二轮及“用户项目取材”保留原技能当时的研究记录，不是本次重新联网或运行结果。本次连续开发反馈的增补在文末，当前行为契约见[维护案例](maintenance-lessons-2026-09.md)。

取材日期：2026-09-12。正文为针对本任务重新组织的规则，未复制社区 Lua 实现或整段文档。许可证逐项记录；未找到明确授权的仓库不能因“公开可读”就任意复用。以后直接复用须重新核对并保留适用许可与署名。

## 社区项目比较

| 固定来源 | 阅读范围与采纳 | 未采纳/限制 |
|---|---|---|
| [Strawberry-devs/ArcheRage-addons](https://github.com/Strawberry-devs/ArcheRage-addons/tree/6e7813108325d1631f10735cfe99aa48b0dd2ce4)，提交日期 2026-09-10 | README、extendedplates 与 dpsmeter 的 toc、luaerrorprinter/errorprinter.lua。采纳按实际清单判断依赖顺序、错误需要可观察的思路；改为项目现有加载链和有界取证 | README 指向 RU，但“应兼容 NA”不是实测。错误打印器有定时截断日志行为，不适合直接作为保全故障证据的工具；不照搬高频读取、宿主导入和文件 IO 假设 |
| [belovres/ArcheRage-addons](https://github.com/belovres/ArcheRage-addons/tree/ed7c2a9ec5ac54e548d772906e80182177bcd40b)，提交日期 2025-07-08 | README、targetdebufftracker/toc.g。用于比较旧插件拆分与加载约定 | Strawberry 的 fork，不能把同源代码算作独立验证；年代更早，API 状态须重新核对 |
| [Noviern/exampleaddon](https://github.com/Noviern/exampleaddon/tree/7558cbb880085a8f701ee21103c04c951d36de52)，提交日期 2026-03-14 | README、toc.g、exampleaddon.lua 起始部分、settings.lua。采纳界面/逻辑/设置职责分开和 locale 的显式加载顺序 | 示例出现的生命周期、删除处理和 UI 事件仍是候选用法；没有当前 RU 运行验证，不推广其具体 API |

三者仅提取组织方法和可检查的问题，不打包其源码。比较依据是任务适配、当前契约、上下文成本和能否实际验证；仓库数量不能代替独立证据。

## 第二轮：按具体机制深入取材

用户明确：个人项目主要用于了解开发背景，持续研究社区更有价值的实现；以解决问题的准确性为首要目标，资料总量不作限制。下面记录的是机制层面的优点与边界，不给整个仓库作质量背书。

本轮额外筛选公开 ArcheRage Lua 仓库，并对以下四项阅读具体代码。未克隆或执行其程序；未找到许可证的三项仅作分析来源。跨游戏来源只提取可迁移的机制，不移植宿主 API。

| 固定来源 | 具体阅读与采纳 | 修改点、未采纳与验证状态 |
|---|---|---|
| [rumor88/raidautosort](https://github.com/rumor88/raidautosort/tree/18fe635987cbd06e06e689dd50a1643f9891e4f7)，2026-07-16 | README、raid_sorter_core.lua 规划/恢复分支、raid_sorter.lua 的 pending 验证与推进、tests/core_test.lua。采纳规划与游戏调用分开、观测实际位置后推进、成员变化使旧计划失效，以及正常/阻止/溢出用例 | README 目标为 ArcheRage 10.5，不能据此证明当前 RU 契约。固定槽位、姓名键、冷却和重试值不推广；规划浅复制成员数组后写 member.role，说明无游戏调用不等于输入不可变。仅源码和测试内容核对，未运行；未找到明确许可证 |
| [P-Raphael/OSO-TradePack-Ledger](https://github.com/P-Raphael/OSO-TradePack-Ledger/tree/3338880db4a6e24857afe7a7ce24e7d5d331506e)，2026-06-14 | README、utils.lua，以及 TradePacks.lua 的 auctionResultMatchesLookup、searchedAuctionPrice、handleLowestPrice 和启动修复段。采纳报价事件身份匹配、当前缓存与历史快照分离 | 源码注释记录过用户拍卖搜索事件污染其他 pending 报价。规则进一步要求明确关联证据及未知状态；不复制物品特例、启动迁移、默认价格和 IO 路径。未核验游戏返回或实际到账；未找到明确许可证 |
| [Dakuczen/damagelog](https://github.com/Dakuczen/damagelog/tree/af3ecd22b43d5126dd406d08ddd14d1f0f86f9a7)，2026-06-12 | damagelog.lua 的 isTick、onCombat、miss/crit 分支和事件注册。用作区分逐击展示与完整统计口径的具体案例 | 过滤周期事件、按 SELF_NAME 匹配、金额位置分支及尾参首个正数启发式都不能默认成为完整 DPS/HPS 契约；参数表含 nil 时 ipairs 还可能提前结束。保留原始参数与解析未知是改进方向。未找到明确许可证，未游戏内验证 |
| [WoWUIDev/Ace3](https://github.com/WoWUIDev/Ace3/tree/88e0a1733fcfc8b8f09dd86ae71eee7a780c2980)，2026-09-08 | AceTimer 的 new/cancel 路径、CallbackHandler 的 Fire/register/unregister、AceGUI 的 Create/Release、tests/AceGUI-3.0-recycle.lua 和 LICENSE.txt。采纳回调前后取消检查、活动/待加入订阅同时清理、控件释放重置和复用回归思路 | WoW 的 C_Timer、securecallfunction、Frame、LibStub 不是 RU API；复用测试确认对象被重用，不证明自定义业务字段全部清理。许可证含独立分发限制等附加条款，不标成普通 BSD/MIT；此处不复制源码。已静态阅读，未运行其测试或 WoW/RU 客户端 |

[Lua 5.1 官方手册](https://www.lua.org/manual/5.1/manual.html#pdf-next) 核对了 next 遍历期间新增字段的限制；参数数量参考同手册的 select。相关资料写成[回调与请求契约](callback-and-request-contracts.md)、[战斗与价格口径](combat-and-price-contracts.md)。本轮没有以二手帖子代替技术依据。

新增 AR-06 至 AR-08 是从这些风险构造的验收情景，不是用户已提供的现场日志。既有游戏 API 禁用状态仍沿用有日期的证据，未因阅读社区代码而宣称重新开放。

[AAClassic Addon API](https://wiki.aa-classic.com/Addon_API) 的加载和 `ADDON_API` 是不同宿主的反例，不是 RU 接口来源。AAEmu 的服务端实现也不作为客户端可调用性证据。

## RU 官方更新

公告日期采用标题中的更新日期，而非论坛提前发布的日期。以下为已读取的具体页面，不宣称完整覆盖所有更新，也未在客户端验证。

| 官方页面 | 与本技能相关的结论 |
|---|---|
| [2026-06-10 更新](https://ru.archerage.to/forums/threads/obnovlenie-10-06-2026.17439/) | 加入 GetUnitsInSight，移除 sight 相关事件；旧事件订阅不能靠轮询恢复其可用性 |
| [2026-08-19 更新](https://ru.archerage.to/forums/threads/obnovlenie-19-08-2026.17526/) | GetUnitsInSight 被禁用，说明同名能力会随更新改变 |
| [2026-08-26 更新](https://ru.archerage.to/forums/threads/obnovlenie-26-08-2026.17543/) | 公告开放 X2Butler:GetChargeInfo、X2Store:GetRandomShopStoreRefreshCount、X2Input:GetMousePos；存在时间边界，鼠标坐标契约仍须核对 |
| [2026-09-09 更新](https://ru.archerage.to/forums/threads/obnovlenie-09-09-2026.17558/) | 公告开放 X2Faction:GetExpeditionMemberCount、X2Quest:GetQuestJournalObjectiveCount/Text；不能将旧 API 快照视为当前完整列表 |

本轮 2026-09-02 公告未能可靠取得正文，不对其内容作推断。任务使用这些能力时应复查后续公告、项目门禁与当前客户端结果。

## 用户项目取材

用户授权读取现有 Addon 工程。采样时 HEAD 为 `9cc174f`，工作树有未提交改动，因此该提交不能单独重建所读状态。以下路径相对于 Addon 项目根；不写入用户个人绝对路径，不复制源文件或原始用户载荷。

| 读取文件 | SHA-256 |
|---|---|
| `replicatedsuite/toc.g` | `1f0feab5c323e4f254d7107a725690a0cd9d7fc2f26acd3fa34afb698d3c001c` |
| `replicatedsuite/replicatedsuite.lua` | `52ae417f5046ef3a88841dfb289190c5451ac8b36d601a11841752e8ce14c1a0` |
| `replicatedsuite/core/rs_api.lua` | `23aefd3973d1551e273189d1744a872f26656911d6f39687dcb9a4fcb57a8213` |
| `replicatedsuite/core/rs_api_capabilities.lua` | `745c11671d55bf74a1a5d6f28ec70c9d5737977045f62796e3a4a92369d1ea4e` |
| `replicatedsuite/core/rs_persistence.lua` | `99082bca98871a889ea96025d140240f3be7b21f2dde3ccc917e4ba490bbc6e8` |
| `replicatedsuite/core/rs_self_check_report.lua` | `eeea3b5d975b979d3ba816567060943e1daf795e6778170dd81072eea709d216` |

辅助阅读项目根 SKILL、Docs/README，以及 Docs 下 2026-09-12 的 PERSISTENCE_READBACK_STAMP_AUDIT、PERSISTENCE_NATIVE_NUMERIC_EVIDENCE、PERSISTENCE_WINDOW_NUMERIC_RECOVERY、SELF_CHECK_REPORT_DELIVERY 报告。它们是项目自述及已有实验记录，本次未重跑；当前源码发现与旧说明的冲突已在[项目边界](replicated-suite.md)标明。

## 首批案例状态

| 症状/触发条件 | 依据与原因范围 | 修复经验与验证结果 |
|---|---|---|
| AI 在 V3 工程要求修改旧页或运行不存在的审计 | 当前树、TOC、架构标记与旧技能冲突；另有“tools 已删除”说明落后于实际文件 | 先核对活跃代码和具体检查用途。完成静态核对，未执行插件修复 |
| 旧代码依赖视野 API/事件，当前数据不可得 | RU 2026-06-10 与 08-19 公告、项目 capability 记录 | 保留禁用状态，核对后续更新并明确降级；未游戏内调用 |
| canonical 回读业务值匹配却在下次加载拒绝 | 项目报告的模拟与当前实现：漏绑定声明 S 与预期 E 可漏检坏元数据 | 当前代码已有 S/E 绑定；本次源码核对，未重跑模拟或恢复用户坏档 |
| 旧存档数值与 canonical 校验不一致 | 项目收到的 Native 返回表示及模拟报告；部分格式转换可以复现特定差异，内部实现仍属推断 | Transport 3 与受限旧格式恢复是项目已有方案，不推广为任意 hash 修复；本次未客户端验证 |
| 报告有首尾却缺少故障原文 | 当前报告逻辑和项目记录明确 raw copy budget 与 numeric 摘要分开 | 区分传输完整、证据覆盖和修复完成；最小定向只读取证。本次源码/文档核对 |

UI 坐标、输入所有权与 generation 清理依据项目当前约定及启动代码，属于有依据的检查方法；新 eval 中的重载双击等情景是合成验收题，不能写成用户已实测的历史故障。

技能文本与结构验证见库内评测报告；其通过不证明任何游戏功能已修复。以后根据[反馈流程](feedback.md)补充实际版本和客户端结果。

## 连续开发反馈增补（2026-09-12）

用户本次提供 `Skills.zip`，要求从这轮Replicated Suite开发经验补充对应技能。已定位正式目录 `skills/skillforge-archerage-addon`，不是另一工作树里的旧路由/布局技能，也不恢复已取材删除的 `replicated-suite-maintenance` 目录。

新增材料分三类：用户在本会话给出的截图、分页日志及需求更正；实际可读取的交付ZIP中的相关Lua实现；交付说明内的既有实验记录。只读分析前两类并交叉核对第三类，没有执行旧项目的全量测试或当前RU客户端。

| 素材 | 本次读取重点 | 可支持的范围 |
|---|---|---|
| `PagedReports_UDFRecovery`补丁/说明 | 固定分页、报告收集与字节交付、旧数值恢复证据 | 代码结构与历史实验说明；用户后续报告的成功只覆盖其本次运行 |
| `Gear_Plan_Editor_Fix` | Gear容器、命令反馈、返回值包装 | 局部布局/返回契约，后续输入Authority还须单独处理 |
| `StatusLibrary_EventImport_Fix` | 实际owner/reason接收、成功/失败刷新 | 解释元数据留在缓存的机制，不能据界面旧值推断保存必失败 |
| `Gear_Input_BuffLibrary_Durable_Fix`补丁/说明 | 原生草稿租约、每Store传输选择、长ID块、占位缓存 | 指定实现与故障模型；188不是通用表上限，最新坏档未重取 |
| `StatusLibrary_ContinuousCapture` | 持续观察留存、实时HUD隔离与已有事件 | 产品语义及生命周期，而非保证所有短效果都可观测 |
| `UnitLines_Projection_Viewport_Fix` | 独立屏幕坐标、同源视口、深度与裁剪 | 已确认机制与受限回归方法，不作为未看到目标时的通用修复 |
| `CompactTracking_TradeBudget_Overview` | 共享询价批次/取消、简易追踪小窗 | 当前队列合同，预算值以后仍需实测 |
| `Overview_Workbench_Tasks`补丁/说明 | 命名工作区、任务索引、账本纯读与来源边界 | 源码接入及历史官方许可说明，四项真实收益仍未接通 |

完整文件名、原包和成员SHA-256见[本轮证据清单](maintenance-evidence.json)。清单只定位取材版本；必要规则和最小情景已在技能内自包含，复制技能后不需要能访问作者的原包。没有复制Native保存数据库或私人原档，也没有改变旧评测结果。

新案例RS-L01～16和AR-09～26的来源/假设界限见[维护案例](maintenance-lessons-2026-09.md)。现有社区与官方日期证据照原记录保留；需要最新API结论的后续任务必须重新核对，不能把本次收录动作当成在线验证。

## 2026-09-13本次技能维护

实际取材基线、9份补丁顺序、相关文件字节数/SHA256与符号索引见[新增证据登记](maintenance-evidence-2026-09-13.json)。旧`maintenance-evidence.json`保留其原取材范围；未取得的旧源包没有假称重新核对。代码中的注释只作索引，已读执行分支与用户症状仍分别说明。

本轮在线核对的一手资料：[Lua5.1参考手册](https://www.lua.org/manual/5.1/manual.html)、[Agent Skills格式规范](https://agentskills.io/specification)，日期2026-09-13。前者不证明RU使用相同数值构建/开放标准库；后者不证明每个Agent宿主都有同一安装路径或热重载能力。未新增“当前RU允许”的断言，也未将社区API用例升级为权限依据。

本机Lua5.1解释器缺失，尝试获取官方源码因DNS不可用失败；随包语法门禁保持blocked。只有单独记录的Python工具测试/协议互通实验属于本次执行，历史游戏补丁说明的数百PASS不重复计数。未执行独立Agent A/B，不宣称正确率增长。

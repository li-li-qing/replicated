# 证据索引、查证工具与发布口径

## 1. 本次交接实际做了什么

本次只制作交接资料，没有修改游戏运行代码，也没有操作用户本地工程或RU客户端。

实际读取了本会话可用的项目原包、后续9个增量补丁、现有升级说明和 `skillforge-archerage-addon_20260913-r2.zip`。在独立临时目录按顺序构建历史参考树，检查归档CRC/成员路径，读取入口、TOC、Registry、相关权限/业务实现与测试入口。

用 **texlua / Lua 5.3** 只执行了无Native调用的Registry元数据注册，得到40条记录、24条未完成（19可见、5隐藏）。**这是离线目录盘点，不是Lua5.1测试、功能测试或RU验收。** Registry中的currentImplementation文字可能滞后于后续补丁，任务范围必须再跟踪本地代码。

本包的技能副本为r2原样复制；旧validation文件是技能上一轮的历史记录，不能当成新Agent的项目测试。

## 2. 历史覆盖顺序

这里只用于解释文件来源；不指示Agent对当前本地工程重新执行覆盖。

| 顺序 | 历史归档 |
|---|---|
| 0 | Addon(20260912-140314).zip |
| 1 | ReplicatedSuite_20260912_BossAlerts_Patch.zip |
| 2 | ReplicatedSuite_20260912_BuffCap_Patch.zip |
| 3 | ReplicatedSuite_20260912_Persistence_Copy_Patch.zip |
| 4 | ReplicatedSuite_20260912_RandomShop_Patch.zip |
| 5 | ReplicatedSuite_20260913_EnemyTypes_BossHud_Patch.zip |
| 6 | ReplicatedSuite_20260913_PvpHud_Patch.zip |
| 7 | ReplicatedSuite_20260913_HudTemplate_Patch.zip |
| 8 | ReplicatedSuite_20260913_HudTemplate_CopyFix_Patch.zip |
| 9 | ReplicatedSuite_20260913_HudDefaults_Patch.zip |

完整归档SHA-256和文件摘要见 [reference_baseline.json](evidence/reference_baseline.json)。清单不含源码正文，排除`.workbuddy`临时记录；历史归档自身不放入本交接ZIP。实际本地更改不匹配时先定位版本，不用这个清单强行恢复。

## 3. 读哪些源码解决哪些问题

以下路径以工程中的 `replicatedsuite/` 为根；文件变动时按符号继续查调用，不凭旧行号改代码。

| 问题 | 首读位置/符号 |
|---|---|
| 运行入口、加载、标记 | `replicatedsuite.lua`、`toc.g`、`native/` |
| “未完成”判定 | `features/rs_feature_registry.lua`：`ResolveNavigationDevelopmentState`、`Register`、`Add` |
| API类别、调用包装与冷却 | `core/rs_api.lua`、`core/rs_api_capabilities.lua`；工程外侧`z_api_functions/` |
| 原生事件与任务取消 | `core/rs_events.lua`、`core/rs_scheduler.lua`、`core/rs_demand.lua`、`core/rs_frame_budget.lua` |
| 存档回读、负数、写保护 | `core/rs_persistence.lua`；相关Feature的Store；`core/rs_diagnostics.lua` |
| 报告采集、分页与选区 | `core/rs_self_check_report.lua`、`core/rs_report_copy_transport.lua`、`presentation/v3/pages/rs_v3_foundation_pages.lua`、`ui/rs_ui_framework.lua` |
| PVP时效、图标跟随 | `features/combat/buff_display/rs_buff_display_feature.lua::_QueueEventRefresh`、`presentation/v3/widgets/rs_v3_buff_head_markers.lua` |
| 敌人类型/职业图标 | 同上Projection、`data/rs_team_auto_role_catalog.lua`、现有状态分类目录 |
| HUD校准/模板/默认 | `presentation/v3/widgets/rs_v3_buff_hud_calibration.lua`、`features/combat/buff_display/rs_buff_display_store.lua::VERIFIED_HUD_DEFAULT_PROFILE/NormalizeSettings` |
| 首领告警 | `features/rs_business_bridge.lua`、`services/rs_alerts_service.lua::EnsureTimer/Tick`、`presentation/v3/widgets/rs_v3_alert_hud.lua` |
| 状态/读条/团队共享事实 | `services/rs_aura_observation_v3.lua`、`rs_casting_observation_v3.lua`、`rs_team_roster_v3.lua` |
| 活动/任务 | `features/life/activities/`、`features/life/tasks/`、对应V3 page/widget、`services/rs_quest_progress_v3.lua` |
| 生活汇总/跑商/债券 | `features/life/rs_life_m16_bundle.lua`、相关服务和V3页面，不能只看Registry |
| 住宅/管家 | `features/life/housing/rs_housing_authority.lua`、`features/life/butler/rs_butler_authority.lua`与各自Feature/Page |
| 制作与拍卖 | `features/life/craft/`、`services/rs_craft_surface_v3.lua`、`rs_auction_query_v3.lua`、`rs_auction_surface_v3.lua`、`rs_price_quote_queue_v3.lua` |
| 当日真实收益 | `features/life/rs_daily_ledger.lua`，核对provider来源而非只看UI总数 |

`pvp-hud-1`、`boss-hud-clock-1`、`report-selection-1`、`random-shop-observer-1`、`hud-template-copy-2`、`hud-default-template-2`都是源码定位线索，不自动证明当前客户端加载/效果正确。

## 4. 旧说明的几个实际陷阱

- 历史Docs/README里某些固定通过数量、工具路径和覆盖规则滞后，不能照抄成今天的结论。
- 本历史树没有 `tools/rs_foundation_audit.py`，也没有旧 `tools/rs_lua_runner.py`。不要为了执行旧文档命令重新发明一整套旧审计。
- `tools/rs_status_refactor_test_runner.py` 是手动分支选择，不是argparse CLI；**未知参数（包括未实现的`--help`）可能落到默认运行分组，多个选项只走首个匹配分支。** 先读脚本，只传一个已确认选项，不能用“命令退出0”推定所有选项都执行。
- 该runner先找名为lua5.1、luajit、lua的可执行文件，随后可能使用liblua5.4。名称叫`lua`不能证明版本；实际 `_VERSION`/jit/shim要记录。
- 默认分组引用的 `tools/rs_report_failure_regression_tests.lua` 在此历史树缺失；`rs_compact_tracker_tests.lua` 还引用缺失的 `tools/rs_report_failure_test_host.lua`。保留这些缺口，不伪造“全量通过”，不删除测试回避。
- 本次Registry盘点中的texlua实际是Lua5.3；工具名与Lua版本不是同一件事。
- 哈希对账使用原始字节，不以换行归一化掩盖无关全文件改动；阅读diff可以辅助归一显示。维护原文件编码/换行风格，避免批量格式化。

## 5. 技能工具：已随包提供

在包内 `skills/skillforge-archerage-addon/` 目录使用Python 3.10+运行。以下仅为明确支持的命令；涉及文件路径时用真实路径替换示例并加引号，不直接执行示例占位路径。

```text
python scripts/verify_skill.py .
python -m unittest discover -s tests -v
python scripts/verify_report.py pages.txt --hud --output verified-layout.txt
python scripts/check_lua51.py --lua /trusted/path/to/lua5.1 /actual/path/to/changed.lua
python scripts/audit_patch.py --base /actual/baseline --current /actual/current --zip /actual/patch.zip
```

四个脚本支持`--help`；项目runner不是这些脚本，不能混同。报告验证输出文件默认不覆盖，保护已有证据。解释器由宿主/用户提供可信版本，工具不联网安装。技能工具回归不执行游戏功能，也不证明AI遵守规则。

### Lua门禁

真Lua5.1工具会打印并核对版本、编译文本但不执行插件，缺解释器返回blocked。这不意味着要冻结所有代码阅读和其他回归；但结果必须写成“Lua5.1门禁未完成”，不能用Lua5.4语法换成通过。

即使Lua5.1编译成功，还要检查标准库、环境表、可变参数、中间nil、事件契约及Native行为。不要把LuaJIT或RU定制构建默认为等价证明。

### 当前存在的项目回归选项

从 `replicatedsuite/` 目录运行，先核对本地runner与所需脚本存在。每条单独执行、记录解释器、stdout/stderr、退出码和代码摘要。

| 改动范围 | 参考命令 |
|---|---|
| 当前选定解释器的全树语法，仅辅助 | `python tools/rs_status_refactor_test_runner.py --syntax` |
| PVP调度/图标/校准 | `python tools/rs_status_refactor_test_runner.py --pvp-hud` |
| 目标装备类型及首领HUD | `python tools/rs_status_refactor_test_runner.py --enemy-boss` |
| 首领规则与页面 | `python tools/rs_status_refactor_test_runner.py --boss-alerts` |
| 存档数值和报告输入 | `python tools/rs_status_refactor_test_runner.py --persistence-copy` |
| 固定报告分页 | `python tools/rs_status_refactor_test_runner.py --paged` |
| HUD复制 | `python tools/rs_status_refactor_test_runner.py --hud-template-copy` |
| 默认模板/旧配置 | `python tools/rs_status_refactor_test_runner.py --hud-defaults` |
| 增益数量 | `python tools/rs_status_refactor_test_runner.py --buff-cap` |
| 随机商店 | `python tools/rs_status_refactor_test_runner.py --random-shop` |
| 状态持续留存/元数据导入 | 分别执行 `--capture-library`、`--library-runtime` |
| 任务详情/首页/日期投影 | 分别执行 `--overview`、`--overview-v2` |
| 换装页面 | `python tools/rs_status_refactor_test_runner.py --gear-page` |

不是每轮都必须跑所有功能；涉及公共Core/RSUI/Store时扩大到受影响正常路径。缺文件要指出确切依赖，补测试必须证明覆盖真实问题，不用空文件或恒真断言补齐。

## 6. 每项功能最小回归矩阵

正常结果、合法空结果、不可用、错误返回、回调晚到、连续事件合并、快速切目标/选项、启用→隐藏→禁用、停用后无残留、重载恢复、保存失败、升级旧配置、窄屏/缩放、输入草稿与复制选区。

按业务再增加：价格身份/过期与队列取消；任务index重排；首领时钟推进/长帧/同名下一次；Buff持续留存与live显示隔离；装备拒写与真实类型切换。未覆盖项写明，不用矩阵标题代替测试执行。

## 7. 最终ZIP怎么证明是这次的代码

1. 保留本次开工时的真实基线。当前文件若遭并行修改，先消解，不把别人的变化打成自己的补丁。
2. 计算最终diff，只包含实际变更/新增；删除需获准并单列。基线和当前根层级相同，例如都包含 `replicatedsuite/`。
3. 创建最终ZIP，检查路径穿越、大小写冲突、重复成员、缓存和隐私；用随包 `audit_patch.py`核对内容摘要及漏打/多打。
4. 在新的临时目录恢复该基线并覆盖**刚生成的ZIP**；核对TOC及未修改文件摘要，执行相关回归。此操作不覆盖用户正在运行的游戏目录。
5. 收尾再看Git/diff和摘要，确保测试后没有未进入包的代码。若之后重新改文件或打包，重新检查与复测相关结果。
6. 输出实际包名、适用基线、摘要、新增/修改/删除列表与集中实机测试表。只有本轮实际执行的结果才放进通过数。

## 8. 给用户的最终报告必须说明

- 做到了哪些可操作行为，哪些仅有离线证据，哪些仍阻塞。
- 修改文件与删除清单；没有代码改动就明确是文档/技能更新。
- 任务频率/复杂度/缓存上限变化；未测CPU、内存、帧率就写未测，不声称提升百分比。
- 是否迁移配置、个人设置是否保持、如何正常覆盖/重载、不可做的恢复操作。
- 用户可以依次执行的集中测试步骤、期望结果、失败时最小证据及如何保存同ID完整分页。

没有源码或工具时坦诚列缺口；没有独立评审工具就标自审，不能伪造另一Agent审核结果。没有实机就明确待RU验收，允许交付有清楚边界的代码成果。

# Replicated Suite RU Runtime Acceptance Plan

状态：计划文件，不是实机通过证明。执行目标是 ArcheRage RU 中文客户端；每项结果必须在修改后重新 Fresh Reload 采集，不得沿用旧日志。

## 统一前置

1. 备份当前 addon 与用户配置；只加载 `replicatedsuite/`（单一 V3 Host）。`z_api_functions/` 仅作开发期 API 参考，**不进入运行时**；旧 `globals/` 与 Legacy UI/runtime 已于 2026-09-01/02 物理删除，不再随包，绝不重新引入。
2. 使用当前 `replicatedsuite/replicatedsuite.lua` 的 BuildTag 启动新客户端（见 `S.BuildTag`，当前为 `v3-m1.16.0.18.60-healer-raid-panel-model`），记录 `ArcheRage.log`、`Chat.log` 和崩溃文件。
3. 在 1024×768、1920×1080、2K 逐路由打开首页、战斗、生活、工具、系统页；记录页面/Widget/Modal 是否构建、文本裁切、列宽、黑边和关闭后资源释放。
4. 每次测试前后记录 Foundation：`activeBuildScopes`、page/widget quarantine、Authority violation、Presentation boundary、Raw Native、Unexpected Global 和 Scheduler active tasks。
5. 失败记录格式：时间、BuildTag、路由/动作、API 名、输入、原生返回值（脱敏）、日志错误码、是否可复现、恢复动作。

## 通用通过条件

- 只读功能在 API/字段未知时显示 `partial/unavailable/unknown`，不显示伪造的 0 或完成。
- 写操作只经 Feature Commands/API capability，尊重权限和至少 200ms 冷却；失败停止并显示结果，不继续盲发。
- 关闭页面/Feature 后无残留 Scheduler、Event、Demand lease 或隐藏窗口；重新打开能恢复投影和持久化设置。
- 所有 TableView/浮窗在三种分辨率可读，长中文/俄文/英文不重叠、不把数值列裁成省略号。

## 逐域验收

### Combat / Team

| 区域 | 步骤 | 预期事实与日志 | 失败诊断 |
|---|---|---|---|
| DPS / Combat Analytics | 开启每个 Metric，造成伤害、治疗、死亡、控制和演奏事件，再关闭全部 Metric | Encounter、技能、死亡、控制、Aura、演奏状态按事件更新；全部关闭后 lease/task 为 0 | 查 `COMBAT_MSG` topic、Metric consumer、Encounter gap/one-shot 和 `combat_analytics` 诊断 |
| Death Review | 产生两次死亡，打开详情，删除单条、删除全部，重载 | 时间线、最后一击、技能 ID/名称、详情与持久化一致；删除失败回滚 | 查 `DEATH_REVIEW_*`、Store schema、Finalize queue |
| Healer | 50 人名单下启用 Health/Aura/Recommendation/编辑器/Head Marker/Raid Overlay/Calibration | 分片扫描、未知 Aura 显式显示；编辑保存/重载一致；关闭释放 lease | 查 TeamRoster/Aura lease、FrameBudget、marker screen projection |
| Buff / Buff Cap | 切换 player/target、过滤、tooltip、上限阈值和长文本 | 状态、图标/时间、阈值色彩与当前目标一致；未知 tooltip 不误报 | 查 `buff_display` schema、StatusMap、Tooltip 返回结构 |
| Boss / Target | 触发静态 Boss/聊天事件，切换目标和观察仇恨目标 | 匹配、倒计时、目标距离/目标的目标只显示真实返回；无事件不残留旧错误 | 查 alert matcher、TargetService、watch-target 返回字段 |
| Unit Lines / Range Assist | 在三种分辨率和 UI scale 放置已知目标，记录单位集合、世界/屏幕坐标、已知半径 | 只有 API 与坐标契约证明后才绘制；缩放/裁切正确 | 若 `GetUnitsInSight` disabled 或坐标字段不符，保留 blocker，不启用猜测绘制 |
| Team Management | 2 个 team、多个成员时刷新职责；再测试 SetRole、MoveMember/party | 每个真实 team/member index 有独立行；写动作按权限/冷却执行并显示成功/失败 | 查 TeamRoster snapshot、`X2Team:GetRole`、写 API result/permission |
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
| Bag Organizer | 分别打开银行/箱子，读取 240+ 槽；测试四个单槽移动、黑名单、分类批量、自动计划/取消/失败重试 | 容量/读取失败/截断可见；移动尊重冷却、源槽复核、黑名单；批量失败停止并显示成功/失败/跳过 | 查 bag/storage capacity、source identity、ActionRunner cooldown、rollback queue |
| Auction | 添加/删除收藏，搜索已知物品，查询最低价，重复搜索并重载 | 收藏持久化；搜索所有返回行；价格字段和历史样本有身份/时间证据 | 缺 `GetSearchedItem*` 字段时只显示 blocker，查 auction event/result |
| Social | 读取好友/屏蔽/静音，执行四类增删动作并重载 | 列表身份正确；写动作结果、冷却、刷新可见 | 查 list schema、permission/cooldown、refresh projection |
| Hotkey Profiles | 枚举完整动作，快照、修改、保存、重载、恢复并在每个失败点注入 | 只有全动作枚举和可恢复事务通过才允许完成 | 缺 action registry 或 snapshot contract 时保持 blocker |
| Portal Profiles | 枚举个人传送候选，选一个、读回、重载、恢复 | 只修改目标 option，不碰其他设置 | 查 `X2Option` optionType/candidate/readback |
| Resource dashboard | 触发金币/经验/荣誉/生活点事件，刷新背包资源与首页 | 日统计 delta、资源数量和日期切换正确；容量/仓库未知不伪造 | 查 Resource event 参数、bag identity/category、首页 refresh |

## 最终采集

执行完上表后重新运行：

1. `replicatedsuite/tools/rs_foundation_audit.py`；
2. 全部 `.workbuddy/tmp/*.lua` harness；
3. 所有 Active TOC/Lua/Presentation/Boundary/Acceptance 检查；
4. 从新客户端日志确认 `unexpected global=0`、`authority violation=0`、`presentation boundary=0`、`quarantine=0`；
5. 将每一项实际结果回填到 `PRODUCT_COMPLETION_MATRIX.md` 的 Runtime verification 列。未执行的项目仍为 PENDING，不能改成 IMPLEMENTED。

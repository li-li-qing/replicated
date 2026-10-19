# 寻宝坐标归组与逐箱目录实施清单

> 执行方式：本会话直接实施。用户已明确要求按已讨论方案开始，不再重复请求同一范围的确认。

**Goal:** 提供大陆分类、完整坐标归组、多个保管箱库存汇总排序及从当前已登记箱子按坐标取图。

**Architecture:** 复用 Treasure Feature、InventorySnapshotV3、Persistence、Scheduler 和现有 RSUI。新增寻宝库存模块拥有角色级箱子快照与取图会话；原寻宝 Store 的结构和指纹不变。页面和浮窗只消费同一分组投影。

**Tech Stack:** ArcheRage RU / Lua 5.1 / RSUI / Python + lupa.lua51 离线验证。

**Spec:** 本文件的已确认设计及本会话用户要求。

## 已确认设计与边界

- 原请求：自动标记；原大陆、西大、东大、海上选择；同位置宝图放一起；例如三个保管箱，统计相同坐标总数、按数量排序并选择坐标取图。
- 当前授权：先实现四项库存功能；原生队伍自动共享标记保留待验证，不接入调用。
- B级；逐箱打开，手动指定箱号并登记。重复扫描替换同箱快照，不累加。箱号不假称原生唯一身份。
- 相同位置按完整全局 XY 精确归组，不使用取整后的显示文字或距离阈值。分组不会改变原生物品堆叠或挖宝刷新规则。
- 分类使用图本身的区域组及已有地区表；未知保留未分类，允许手动归类；禁止用玩家所在大陆判断远处藏宝图。
- 总量是背包实采 + 各箱上次成功扫描记录；界面明示快照属性和各箱来源。
- 取图只操作当前打开且显式登记的箱子；逐步重查坐标及槽位，遵守冷却，观察源减少与背包增加后才确认移动。
- 关闭箱子、内容意外变化、能力拒绝、背包满、保存失败、超时、取消、停用或需求释放时停止；不以 pcall 成功当作物品已转移。
- 保存采用独立角色级 Store 和有界短字符串块，保留完整数量；失败不覆盖旧快照，不自动删档。
- 不修改无关功能、通用调度/事件/持久化实现。开发阶段原要求不提交；用户后续已明确授权将本次功能与调查记录提交并推送至当前 `main`。

## Review Focus

- 两个相邻坐标显示相同整数秒时仍不得归为一组。
- 同一箱反复登记及箱子扫描中途失败，不得增加总数或丢掉旧记录。
- 一张图取出后既不重复计入箱子，也不能在服务端拒绝/超时时显示取出成功。
- 关闭或切换箱子、手动整理和原生异步搬运不得让旧槽号取出别的物品。
- 新 Store 的保存回读、角色隔离、异常载荷以及旧寻宝偏好保持独立。

## 工作项

### TI-01 坐标目录与持久化

- [x] 写并运行会失败的真实模块用例：精确归组、分类、跨箱替换、失败保留、存档重载。
- [x] 新增 `replicatedsuite/features/life/treasure/rs_treasure_inventory.lua`，接入 `toc.g`；向现有 Feature 提供 `Inventory`、分组投影和明确 Commands。
- [x] 运行 Lua 5.1 目录与存档回归。

### TI-02 按坐标取图

- [x] 写并运行会失败的用例：两张同点图、槽位压缩、原生拒绝、延迟确认、满背包、内容变化、关闭、取消和停用。
- [x] 实现有界串行搬运、即时重查、确认后更新箱子快照和停止清理；声明自身 Native 依赖。
- [x] 运行库存移动及相邻寻宝回归。

### TI-03 页面与浮窗

- [x] 主页面接入大陆/排序、箱号登记、数量选择、按坐标取图、取消和手动分类。
- [x] 主页面及浮窗显示相同坐标分组、数量、箱子来源和快照提示；保留海虫、沉船和双击地图定位。
- [x] 使用真实 RSUI 离线宿主检查按钮调用、刷新、600 宽布局及保存失败反馈；原生像素显示未验收。

### TI-04 交付验证

- [x] 新增用例、寻宝/地图冷却/偏好/海上资料点/背包相邻回归及 Lua 5.1 全 TOC 编译。
- [x] `git diff --check`、TOC 文件存在和唯一性、自审 Native 所有权与无关变动。
- [x] 更新本清单实际结果，交付修改文件包及游戏内验收步骤；明确 RU 实机与组队验证未执行。

## 当前状态

2026-10-19：TI-01～04 已完成本地实现及离线验证，基线 main `61d130d`。用户已追加提交推送授权；提交前再次运行 82 项寻宝测试、517 个 Lua 文件编译及 319 个 TOC 成员检查，均通过。最终提交号及远端状态以 Git 历史为准。

## 实际验证

- `python -X utf8 -m unittest discover -s tools -p 'test_rs_treasure*.py' -q`：82 项通过，其中新增库存模块 24 项。使用真实 Lua 5.1 / Persistence / Scheduler / InventorySnapshotV3 / RSUI，原生容器及存盘为测试宿主。
- Lua 5.1 独立套件：双击地图 10、地图冷却 11、偏好重载 18、背包设置页 5、Feature 拆分 56、加载就绪 5、Core 解耦 125；7 组均通过。
- 517 个 Lua 文件编译通过；319 个 TOC 成员均存在且唯一，库存组件位于 Feature 后、Acceptance 前。
- 150 个不同坐标的满箱快照，分块保存后在全新 Lua VM 回读通过；两个角色互不读入对方箱子记录。
- 独立只读审查发现并修复三项：相同取整文本换槽导致选中点跳变、四返回值开箱状态被拒、catalog 区域组证据不随登记更新。复查无阻断项。
- 增量包含 8 个运行文件；逐成员 SHA256 与当前工作区一致。将包覆盖 `git archive HEAD` 的干净基线，再运行相同 82 项测试、7 组 Lua 套件、全 Lua 编译及 TOC 检查，均通过。
- 标准 runner 未检测到系统 Lua CLI；上述 Lua 验证实际由 `lupa.lua51` 执行，不宣称完整标准 runner 通过。
- 尚未执行 RU 客户端原生开箱、真实物品转移、原生界面显示或组队验收；原生自动共享标记保持待验证，无对应调用实现。

## 交付与游戏内验收

- 增量包：`.workbuddy/deliveries/treasure-inventory-20261019/ReplicatedSuite-Treasure-Inventory.zip`。解压到 `Addon` 目录覆盖；当前工作区已经包含同样修改。包不含 UDF、测试或个人设置。
- 依次打开三个箱子，每次在寻宝页选择对应箱号并点“登记/更新本箱”。再次登记同一箱替换其记录。箱号由用户维护，插件无法证明两次打开的是同一个原生箱子。
- 选择原大陆、西大陆、东大陆或海上；无区域依据的坐标显示“未分类”，可选中后手动指定。检查同坐标合并、背包/各箱来源及总数，数量排序默认从多到少。
- 打开目标箱，选择原箱号重新登记，选中坐标，选择“最多1张 / 最多2张 / 本箱该点全部”，点“取本箱同坐标”。检查只取出该点图，并在原生库存反馈后更新数量。
- 对含其他坐标的箱子重复取图，期间测试关箱、停止、背包满，确认任务停止且不误取其他图。若显示未确认移动，重新登记该箱核对。
- 关闭并重载插件，检查箱子快照和大陆筛选仍保留，但必须重新开箱登记才能取图。总数包含各箱最后扫描记录，未打开箱子的后续手动变动需重新登记才更新。

## TI-05 自动共享标记接口调查（2026-10-19）

用户续接请求：继续查原生接口，判断是否能在打开藏宝图后自动标记位置，让队友看到。沿用 B 级；本轮仅调查和保存证据，未增加生产调用，TI-01～04 的代码与增量包未变化。

- [x] 核对当前 API 白名单、Worldmap / Map 控件方法、客户端 UI 落标调用及权限检查。
- [x] 查询 RU 官方更新至当前列表的 2026-10-13/14，核对 09-29、10-06 和 10-13/14 正文。
- [x] 核对公开 TreasureMapHunter 当前源码及插件目录中的来源。
- [ ] RU 实机确认落点来源、打开实物宝图的事件参数及队友端可见性；尚无这些运行证据，全自动共享标记仍待验证。

### 已证实的接口及边界

| 接口 / 事件 | 当前证据 | 不能据此认定的行为 |
|---|---|---|
| `Worldmap:SetPingBtn(clicked, pingType)` | 本地 `z_api_functions/ui_functions.lua:1735` 列为 Allowed；客户端 `ping.lua` 同步设置大地图与小地图。普通标记类型为 1，敌人 2，攻击 3，路线 4。 | 参数中没有藏宝图 XY；设置模式不能等同于已在目标坐标落标。 |
| `Worldmap:OnLeftClick()` | 本地 `ui_functions.lua:1738` 列为 Allowed；原生 ping 图标左键处理直接调用它，不传坐标。 | 未读到 C++ 实现，无法证明额外参数会被接纳，或打开位置箭头会改变它的落点；不能把无异常当成落标正确。 |
| `Worldmap:GetCursorSextants()` | 本地 `ui_functions.lua:1758` 列为 Allowed；原生 UI 用于显示地图光标经纬度。 | 这是读取接口，不是写入目标落点的接口。与 `OnLeftClick` 的内部取点关系仍需实机确认。 |
| `SHOW_WORLDMAP_LOCATION(zoneId,x,y,z)` | 原生 `world_map.lua` 消费此事件并调用 `ToggleMapWithLocation`；后者只打开地图、显示 Portal 箭头特效。 | 该事件不是宝图专用；不能让所有任务/传送/普通地图定位都自动广播。打开实物宝图是否同样发出此事件尚待实机确认。 |
| `UPDATE_PING_INFO` / `UpdatePingInfo()` | 原生大小地图收到事件后刷新标记；大地图还刷新按钮可用状态。 | 刷新事件没有目标 XY、请求关联或队友端回执；自己收到事件不能证明队友已看到所选宝点。 |
| `SetPingWidget` / `SetTempNotifyCoord` / `X2Map:SetNotifyCoords` | 分别绑定标记显示控件，配置临时任务显示/图集；原生 `common.lua` 的 `SetNotifyCoords` 参数是纹理路径和图集键。 | 没有证据表明这些显示设置会向队伍广播藏宝图坐标；`X2Map:SetNotifyCoords` 还属于本地 Not allowed 分类，不接入。 |

原生 `ping.lua::EnablePingBtn` 的逻辑：组队/团队时检查队长；联合团队额外检查联合队长；`IsHeadMarker` 可开放普通标记。**这解释了为什么玩家身份可能影响按钮，但只是公开客户端 UI 的源码证据，尚非本机 RU 运行确认。** 本地 API 清单把 `X2Team:IsPartyTeam/IsRaidTeam/IsTeamOwner/IsJointLeader/IsHeadMarker/GetMyTeamJointOrder/GetTeamPlayerIndex` 等相关 Getter 列在 Not allowed 下，插件不能照搬原生脚本调用这些 Getter；后续应在允许的 UI 路径验证原生按钮状态，并由原生权限处理，不绕过禁用状态。

### 公开插件与最新公告交叉核对

- [原生 ping.lua 固定版本](https://github.com/Noviern/scriptsbin/blob/945dcab54cd23f5a275d486feee33ebf85c38d05/x2ui/map/ping.lua)：落标模式、类型、权限与无参数点击调用链。公开客户端源码不代表当前 RU 为插件开放全部内部 API。
- [原生 world_map.lua 固定版本](https://github.com/Noviern/scriptsbin/blob/945dcab54cd23f5a275d486feee33ebf85c38d05/x2ui/map/world_map.lua)：`SHOW_WORLDMAP_LOCATION`、`ToggleMapWithLocation`、`UPDATE_PING_INFO` 的实际消费。
- [Map 定义固定版本](https://github.com/Noviern/x2/blob/9ee3d7aa29b69a1450094834ed734da49fa51657/src/types/Map.lua)：`OnLeftClick()`、`SetPingBtn(clicked,pingType)` 签名，与本地导出表一致；不是带 XY 的发送接口。
- [TreasureMapHunter 固定版本](https://github.com/Koalazau/ArcheRageAddons/blob/6f1a34d80c2a8993d02c992f241aa93f6d496244/TreasureMapHunter/TreasureMapHunter.lua)：当前主文件仅 1 处 `ShowWorldmapLocation`，无 `SetPingBtn` 或 `OnLeftClick` 调用。README 将 Test 按钮称为实验性 ping，实际代码仍不能证明原生队伍共享。
- [09-29 官方公告](https://ru.archerage.to/forums/threads/technical-restart-29-09-2026.17596/) 只确认 `ShowWorldmapLocation` 新增可选 `isGlobal`，没有说明该参数会开启队伍共享。[10-06](https://ru.archerage.to/forums/threads/technical-restart-06-10-2026.17605/)、[10-13](https://ru.archerage.to/forums/threads/technical-restart-on-13-10-2026.17623/) 和 [10-14 RU](https://ru.archerage.to/forums/threads/texnicheskii-restart-14-10-2026.17624/) 本轮已读正文没有公布新的按坐标落标接口。
- 本轮下载证据与 SHA256 清单在 `.workbuddy/research/treasure-ping-20261019/manifest.json`；GitHub 全仓搜索曾遇公开 API 限流，之后使用已确认仓库的树与固定提交源码完成核对。不把检索范围写成“所有软件都没有”。

### 可行性判断与下一步

**当前可以确认原生标记操作入口存在，但不能确认纯插件能把藏宝图完整坐标直接写成共享标记；尚不足以接入全自动。** 简单串联 `ShowWorldmapLocation -> SetPingBtn -> OnLeftClick` 没有传入指定坐标的依据，不作为完成实现交付。

下一步最小验证需要 RU 客户端：记录打开实物宝图时事件参数；核对当前原生地图对象、允许的方法和按钮状态；分别在宝点与其他位置放置鼠标，比较地图光标坐标与人工普通标记的实际落点；由另一队员确认可见性和位置。只有落点规则明确后再决定能否实现无鼠标干预的自动发送。半自动“打开图后进入原生标记模式，再由用户点一次宝点”是可研究的备选，但改变用户要求的操作方式，B 级下未擅自替换目标或实施。

# Hotfix — 红龙巢穴 / 血之使者卡杜姆：从任务判定改为团队副本入场次数判定

## 问题

活动时间表中的“红龙”行此前用任务完成度判定（`9215 / 7654 / 8958 / 47243`）。
但“红龙巢穴”并不是任务，而是 ArcheRage 的团队副本：

- 星期一、星期三、星期五、星期天限时开放；
- 每个账号只有一次入场机会；
- 进入副本后实例面板显示 `1/1`，这才是“完成”。

另有同类型的团队副本“血之使者卡杜姆”（Kadum），此前完全没有接入。

## 证据来源（调研结论）

1. **API 面**：RU 客户端自 2026-05-19 起官方开放以下只读接口
   （`api_capabilities_ru_20260815/20260823.lua`、官方更新帖）：
   - `X2BattleField:GetInstanceUiKindList()`
   - `X2BattleField:GetInstanceListByKind(kind)`
   - `X2BattleField:GetDetailInstanceInfo(instanceType)`
   - `X2BattleField:GetInstanceName(instanceType)`
2. **返回结构**：对照 ArcheAge 客户端 UI 源码
   （`x2ui/battlefield/entrance_new.lua`），实例入场面板正是用
   `GetDetailInstanceInfo(instanceType)` 的 `enterCount / maxEnterCount`
   渲染“入场次数 cur/max”。`max == 1000` 表示“不限次”。
   因此“进入过一次”即 `enterCount >= maxEnterCount`（`1/1`）。
3. **副本识别**：instanceType id 是服务器数据、未公开，因此运行时按名称匹配
   （zh_cn / en_us / ru 候选名），命中后会话内缓存 instanceType。
   - 红龙巢穴：`Red Dragon's Keep`（NA 官方活动指南），中文名“红龙巢穴”；
   - 卡杜姆：`Kadum`（NA 官方活动指南），中文名“血之使者卡杜姆”。
4. **卡杜姆时间**：NA 指南为周日/周二/周四/周六，与红龙巢穴（周日/周一/周三/周五）
   错开；RU 时间窗沿用红龙行（02:00 / 10:30 / 20:00，30 分钟）。
   > 若 RU 实服时间不同，只需改 `data/rs_event_data.lua` 中 `kadum` 行的
   > `Times(...)` 参数；判定逻辑与时间无关。

## 修改内容

- `data/rs_quest_data.lua`
  - `Activity()` 支持 `options.kind` 与 `options.instanceRaid`；
  - `red_dragon` 改为 `kind = "instanceRaid"`（删除任务 ID 映射），
    标题改为“红龙巢穴”，带多语言 `matchNames`；
  - 新增 `kadum`（血之使者卡杜姆），同样为 `instanceRaid`。
- `data/rs_event_data.lua`
  - 新增“血之使者卡杜姆”活动行（`questKey = "kadum"`，周日/周二/周四/周六）。
- `core/rs_api_capabilities.lua`
  - 注册 4 个 `X2BattleField` 实例接口（OfficialEnabled / SideEffectFree）。
- `replicatedsuite.lua`
  - bootstrap 导入 `API_TYPE.BATTLE_FIELD`。
- `services/rs_quest_service.lua`
  - `RefreshEventQuestProgress` 跳过 `instanceRaid` 组（避免空任务投影覆盖）；
  - 新增 `Q:ScanInstanceRaids()`：发现（按名称匹配）→ 读取入场计数 →
    向 `S.State.data.eventQuestProgress` 发布 `0/1` 或 `1/1`；
  - `Refresh` 与 `SetEventObjectiveTracked` 之后调用扫描；
  - `FindGroup / GetGroupDetail` 支持 `instanceRaid` 详情行；
  - 订阅 `UPDATE_INSTANCE_VISIT_COUNT` / `INSTANT_GAME_VISIT_COUNT_RESET`
    事件，入场后尽快刷新。
- `core/rs_state.lua`
  - `data.instanceRaidEntries` 运行时快照默认键。
- `ui/rs_quest_detail_window.lua`
  - `instanceRaid` 详情的提示文案（入场次数以客户端实例面板为准）。
- `Addon.zip` 已按当前源码重建（构建产物，未入库）。

## 判定规则

- 完成 = `maxEnterCount > 0` 且 `maxEnterCount ~= 1000` 且
  `enterCount >= maxEnterCount`（即 `1/1`）。
- 未进入 = `0/1`。
- 未识别（名称不匹配 / 数据未推送）= 活动行显示 `--`，并在诊断页记录
  当前实例面板名称列表，便于校正 `matchNames`。

## 实机优先验证

1. 覆盖本版后进入游戏，打开活动列表 / 事件 HUD。
2. “红龙”行：未进入时应显示 `0/1`；进入红龙巢穴后（或服务器推送
   `UPDATE_INSTANCE_VISIT_COUNT` 后）应显示 `1/1`。
3. “血之使者卡杜姆”行同样显示 `0/1` / `1/1`。
4. 若两行一直显示 `--`，打开诊断页查看
   “instance raid 未识别”记录里的实例面板名称，更新 `matchNames` 后重载。
5. 点击活动行进入详情：应显示“副本入场次数（每账号 1 次）”与当前计数。

## 静态门禁

- 修改文件 Lua 语法：全部通过（luaparse 5.1）。
- 集成自测（fengari 加载真实数据/服务文件 + mock X2BattleField）：
  - 红龙进入 → `1/1`（completed=1）；
  - 卡杜姆未进入 → `0/1`（completed=0）；
  - 不限次（max=1000）实例不会误匹配；
  - 详情行状态正确。

## 补充 Hotfix（同日晚些时候）：受管对话框渲染成“一条线”

### 现象

点击任务/活动行后，任务详情窗口只出现一条细线、没有窗口框。经排查为
此前“受管窗口（CreateManagedWindow）”重构（commit `a81a09b`）引入的
Lua 多返回值陷阱，与红龙/卡杜姆改动无关，影响所有受管对话框。

### 根因

`ui/rs_ui_factory.lua` 的 `managed:ApplyPlacement`：

```lua
width, height = width or self:GetSize()   -- 错误
```

Lua 中 `a or f()` 是逻辑表达式，**只产生一个返回值**（已用 fengari 验证：
`a, b = nil or f()` 时 `b` 为 `nil`）。因此无论带不带参数调用，
`height` 恒为 `nil` → `SetExtent(宽度, nil)` → 窗口高度 0/1px，
只渲染出顶部一条线，无框。

### 修复

```lua
if width == nil or height == nil then
    local sizeW, sizeH = self:GetSize()
    width = width or sizeW
    height = height or sizeH
end
```

- 修复后窗口尺寸恢复 540×420（窗口测试台断言 `FINAL extent = 540 x 420`）。
- 该修复同时恢复 任务详情 / 自定义日常 / 交易详情 / 制作台助手 / 拍卖收藏
  等所有受管对话框。
- 全库扫描确认无其他 `x, y = ... or f()` 多返回值陷阱。

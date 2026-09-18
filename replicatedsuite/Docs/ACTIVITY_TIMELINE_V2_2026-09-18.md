# Activity Timeline v2（2026-09-18）

## 目标

活动模块继续以 `v3.activity` 为唯一 Authority，但把“可比较的活动时间点”和“实时区域阶段”拆成两个只读投影，避免旧版用业务分带把不同语义硬塞进同一个排序器。

本轮参考 `timeUntil` 的优点是：**时间表按时间排序，区域状态单独展示；只有能得到明确时间的实时事件才进入时间线。**

不复制它的 `OnUpdate`、每秒任务遍历、跨日算法或直接 Native 扫描。

## Authority / 数据流

```text
CuratedSchedule(data/rs_event_data.lua)
          +
ServerClock(low-frequency anchor)
          +
ZoneSnapshot(X2Map, 5s while demanded)
          +
QuestProgressV3(on-demand)
          |
          v
Activity Authority
   |                 |
   v                 v
Timeline Rows       Live Rows
   |                 |
active/upcoming     danger/conflict/war/peace
纯时间排序           curated 区域顺序
   \                 /
    \               /
      one revision snapshot
             |
      Page / Floating Widget
```

1 秒刷新只做纯 Lua 投影和倒计时，不调用 Native；区域 Native 读取仍由现有 5 秒任务与区域事件触发。

## Timeline 排序契约

`ActivityTimelineSortContractVersion = 2`

1. `active`：按 `secondsUntilEnd` 升序，越快结束越靠前。
2. `upcoming`：按 `secondsUntilStart` 升序，越快开始越靠前。
3. 同一时间再用来源、名称、scheduleText 做稳定 tie-break。
4. Live row 永远不进入 Timeline comparator。

`sortSeconds` 仅作为旧诊断/Presentation 兼容字段，不再是跨语义排序 Authority。

## Live 区域契约

实时区域只表达：

- 危险1~5阶段
- 纷争
- 战争
- 和平
- 对应 remainTime（若 Native 提供）

顺序来自 `ZoneStateWatch` 的 curated 顺序，不按 remainTime 动态换位。Garden live row 置于该列表之后。

## Live-derived occurrence

只有从当前 Zone snapshot 能**确定唯一时间**时才构造独立 Timeline row；原 Live row 同时保留。

当前支持：

- 十字星 / 伊尼斯：BATTLE remainTime -> 净化 upcoming。
- 海之烛台：BATTLE -> upcoming；WAR 开场阶段 -> active，并使用已维护的 `warTotalMinutes / activeWarMinutes`。
- 鲸鱼歌湾：WAR remainTime 与已维护的 `bossWarRemainMinutes / bossActiveUntilWarRemainMinutes` -> Boss upcoming/active。
- 庭院 Boss：PEACE/BATTLE -> next War upcoming；WAR -> active。

禁止：

- 从 UI 文案、颜色或名称猜时间。
- 仅因“某阶段通常持续 N 分钟”就从观察时刻制造倒计时。
- 根据 timeUntil 的旧实现直接复制未验证的 `+5 分钟` 等规则。
- 把实时区域的红/橙/蓝颜色传播给 Timeline；Timeline 时间保持中性颜色。

## 兼容

- `GetRows()` 仍返回单一列表，但顺序固定为 `timelineRows` 后接 `liveRows`，兼容旧页面/悬浮窗。
- 新增 `GetTimelineRows()` / `GetLiveRows()` 作为 Presentation 的只读分段接口。
- `summary.active` 保留历史兼容；新 UI 使用 `timelineActive / liveActive / timelineTotal / liveZones`。
- Store schema、隐藏活动、窗口配置、QuestProgress Authority 均不变。

## 回归重点

- 同一语义活动仍由 `BetterOccurrence()` 合并为最近一次。
- 跨日/跨周继续使用 Suite 的 `NormalizeWeekSeconds`，不采用 timeUntil 的 dayOffset 算法。
- active 按剩余结束时间排序；upcoming 按开始时间排序。
- Live rows 永远在 Timeline 之后且顺序稳定。
- 动态 occurrence 与对应 Live row 同时存在。
- 关闭 Consumer 后 Scheduler 任务继续释放，不新增 Tick。

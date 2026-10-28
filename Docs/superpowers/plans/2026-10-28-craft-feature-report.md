# CC-02 Feature 交付报告

范围：在既有未提交输入上增量修改 `replicatedsuite/features/tools/craft/rs_craft_plan_feature.lua`，新增 `replicatedsuite/tools/rs_craft_compare_feature_tests.lua`。未修改计算层、小窗、既有配方库/小窗测试；未提交、推送、发布。

## 完成行为

- `purchaseBlocks` 为可选 bool 表，旧存档无需迁移；校验拒绝非表/非 bool，解除限制删除键。持久化快照保留被限制材料的自动目录身份。设置限制经过真实 Store durable 事务，失败回滚。
- 投影新增 `purchasePolicies`、`purchaseBlocks`、`comparison`；计算 facts 新增 `purchasePolicies`、`quoteStates`。价格失败/无结果仍保留旧价格和 freshness 作参考，不转成绑定，不伪造零价。
- 静态 `TradeStaticV2:GetMaterialByItemId` 必须返回相同明确 `itemId`，才接受其 `auctionable` / `bound_resource`。手动限制为 `source=manual`、`不可拍卖(手动)`；没有静态绑定证据时 binding 仍为 unknown。
- 禁买材料跳过主动询价和拍卖搜索；限制改变取消整轮未完成询价，旧回调不能复活。手动正 buy 分配拒绝，库存足够且实际购买量为零的 buy 路径允许。
- `PlanCompare` 改为 Create/Step/Snapshot job；普通 Scheduler 50ms，单块最多 200 units，可用计时器下 2ms 软限，每轮 10 秒调用 `PauseCompareJob`。100000 states 预算归 solver。支持继续、取消、重复启动取消旧 job。
- 输入变化取消旧 job；价格服务版本每块和采纳前主动校验，不依赖价格事件。进度仅发布显示事件，不递增输入 revision。树展开也是显示变化，不改变输入 revision、建议、撤销记录。
- `PlanApplyRecommendation(expected,key,objective)` 显式选择 cash/combined，缺省 cash；拒绝旧版本和取消任务，拒绝缺失分配。采纳、撤销都使用 durable 保存，失败保持原状态和可重试的撤销记录。
- EventBus 发布期间消费者取消/修改输入时再次检查任务身份，避免将已退役的 job 重新调度。

## TDD 与实际验证

新测试先在旧 Feature 观察失败，再实施。最初 job 算法尚未落盘时使用形状明确的 job 桩验证 Feature 生命周期；桩不证明求解正确性。最终新增两组真实 solver + Feature + Scheduler + Store 集成用例。

Lua 运行时：`lupa.lua51`（Python 3.12），真实 Lua 5.1；Native 仍为受控宿主，未运行 RU 客户端。

- 新 Feature：19/19 通过，包含暂停/继续/取消、版本失效、软预算、双目标分别采纳、禁买、旧存档、保存拒绝、足量库存、目录保护、未知枚举、事件重入与展开独立。
- `python -X utf8 -B tools/rs_craft_cost_test_runner.py`：TOC 325 项编译通过；Feature 19/19、Library 64/64、Window 56/56、Planner 通过。
- 该次统一 runner 为 4/5 套件通过：唯一失败为并行计算任务的 `rs_craft_optimizer_tests.lua:141`，用例 `state pauses wall-clock pauses cancellation and snapshots are explicit`，已向集成负责人报告，未修改其文件。最终统一结果由 CC-04 再读最新代码执行。

## 接口与实机边界

job 活动态按固定约定 `preparing/searching`，停止态接受 `paused/completed/cancelled` 及 solver 返回的其它终态；额外调用已约定的 `PauseCompareJob(job,reason)`。无接口偏差。

`soul_bind_type=1/2`、`soul_bound`、`soul_bind`、`auction_only=false` 的通用自动绑定规则尚未核实，本次不根据它们推禁买，也不新增 Native 扫描或调用禁止 API。静态已核材料之外的自动绑定仍须 RU 枚举取证。

本报告的产物和用例为离线证据；真实拍卖请求、库存 Native 读数、窗口视觉与用户操作体验仍待 RU 实机验收。合成制作链不代替真实赤石链。

## 最终审查修正：帧内软预算时钟

审查发现原 2ms 软限误用了 `S.NowMs`；其生产实现来自 `OnUpdate` 的 `Clock.elapsedMs`，同一 Scheduler 回调内恒定，原递增 NowMs 宿主不能证明该限制在生产有效。

已先将测试改成帧内 NowMs 恒定、`PerformanceMonitor.timer` 随计算 unit 前进，实际观察失败后修复。Feature 只复用 `core/rs_performance.lua` 中 `ResolveTimer` 已校验的毫秒 timer，不新增 Native 或独立时钟来源。每块推进用该 timer 检查 2ms；缺失、nil、非有限值或运行中倒退时只采用 200 units 硬上限。跨帧 10 秒暂停继续使用 NowMs。

投影 `comparison.softBudgetClock` 标识最近推进块为 `performance_timer` 或 `unavailable`；未采到有效值前明确为 unavailable，不声称具有帧内计时能力。

修正后 Feature **20/20** 通过：新增固定帧钟与有效 timer 的 2ms 让出反例，并覆盖 timer 缺失、nil、NaN、倒退的 200 units 降级。此前 19/19 与统一回归结果是修正前快照；最终集成负责人会用最新代码重新运行统一回归。

# 制作成本独立算法与整体审查

审查日期：2026-10-28。只读检查源码与最小内存反例；未改实现、未提交、未重跑整套回归。两项 P2 已在作者给定的最终稳定点读取实际源码并做定点复核。问题段落保留发现时行号，修复段落使用最终源码行号。

## 最终结论

CC-01 spec：通过本轮源码与离线审查。CC-01 quality：通过。两项 P2 均为 **ADDRESSED**，复核没有新增阻断。整体未发现 Crash/Exploit 或共享 job API 的关键断裂。此结论不替代集成负责人的最终五套回归，也不把合成配方、受控时钟或静态身份检查提升为 RU 实机验收。

## P2：劳力总量上限错误删除现金合法方案

- File：`replicatedsuite/features/tools/craft/rs_craft_plan_solver.lua:227-230`、`:248-250`、`:305`。
- Issue：`valid` 将 `nextLabor <= D.MaxQuantity` 作为整个买做分支的必要条件，越界后直接丢弃该候选；只要还有别的可行候选，最终仍可标记 `optimal`。这使现金优化依赖劳力统计是否落在上限内，与现金应独立计算的要求及 `D.Evaluate` 的现有行为冲突。
- 本轮实际复现：真实 `lupa.lua51` 加载当前 Domain/Solver。目标物品 1 数量 2；配方每批产出 1、劳力 `1000000000`、手续费 0、消耗物品 2 数量 1；物品 1 买价 10、物品 2 买价 0，价格 fresh；物品 2 明确 base；库存完整且为空；劳力折价 0。比较结果为 `cash optimal 10 batches=1`，同一输入的 `D.Evaluate(...,'raw')` 为 `cashCopper=0, costComplete=true, laborComplete=false`。
- 建议：累计劳力超界只把劳力信息降为未知，保留现金分支，并使 combined 无法伪证最优；如明确决定该分支不受支持，则不得在丢弃后仍宣称完整搜索最优。
- 状态：**ADDRESSED**。最终 `rs_craft_plan_solver.lua:229-233` 将劳力超界转为 `nextLabor=nil` 并设置 `unknownCombined`，`valid` 不再排除现金合法分支。
- 本轮定点复核：真实 Lua 5.1 重跑原反例，分别使用劳力折价 0 和 1；两次均得到 `cash optimal 0, batches=2, costComplete=true, laborComplete=false`，combined 为 `incomplete_data`。现金与劳力完整性已分离，未知劳力未被伪称已证明含劳力最优。

## P2：2ms 检测使用帧时钟，真实回调内不会推进

- File：`replicatedsuite/features/tools/craft/rs_craft_plan_feature.lua:1166-1176`；时钟依据 `replicatedsuite/replicatedsuite.lua:214-228`。
- Issue：Feature 用 `S.NowMs()` 测量块内耗时，但生产实现直接读取由 `OnUpdate` 推进的 `S.Clock.elapsedMs`。在同一个 Scheduler 回调内，连续调用不会增加，因此 `S.NowMs()-now>=2` 不会触发。测试宿主若每次取时自动增加，则无法证明此保护在真实宿主存在。
- 影响：50ms 调度、200 units 上限和跨帧 10 秒暂停仍成立；当前没有证据支持实际块内 2ms 软限。
- 建议：只在已有、已允许且可在回调内推进的计时能力存在时使用该保护；否则明确标记降级为 200 units，不引入未核验 Native API，也不把此分支测试表述为实际 2ms 性能证据。
- 状态：**ADDRESSED**。最终 `rs_craft_plan_feature.lua:1160-1164,1177-1197` 复用 `S.PerformanceMonitor.timer`，检查有限值和回调内单调性；缺失、异常、倒退时退回 200 units，并在 envelope 中提供 `softBudgetClock='performance_timer'|'unavailable'`。`S.NowMs` 仅保留跨帧 10 秒暂停职责。
- 已读取计时来源 `core/rs_performance.lua:23-34`：现有 `ResolveTimer` 验证 `os.clock` 并返回毫秒计时器，未新增 Native API。
- 本轮定点复核：在内存中选择性执行现有 Feature 测试的两个计时用例，保持真实 Feature/Store/Scheduler 宿主路径，跳过其它套件项；帧时钟恒定而独立 timer 推进时正确在 2ms 让出；缺失、nil、NaN、倒退 timer 均按 200 units 降级。结果 2/2 通过。该证据确认控制逻辑，不是 RU 客户端帧耗时测量。

## 已检查的实现性质

- 以完整选定配方 DAG 做反向 postorder，所有上游需求先汇总后处理节点；单节点按统一库存扣一次，不是各树分支重复扣。多目标同键先累计，混合买做枚举至当前需求的最少覆盖批次。
- 剪枝只用已经发生的非负现金/劳力成本；两个目标都不能改善时才返回；批次只递增，同价少批次判断在该前提下安全。非整数价格/折价禁下界剪枝，最新版本按展示评估器成本比较叶候选。
- 未知配方、未知价格/手续费、未知劳力分别影响证明状态；绑定/手动禁买独立于报价缺失；已有旧价、候选价和失败/查询中的 quoteStates 阻止当前最优证明。
- 身份冲突、模糊库存匹配、图深度/边数/节点数使用显式 unsupported，未假装已解决模糊品质分配。保留现有固定品质与配方产物品质边界。
- 图遍历、库存匹配、传播、回滚和评估主循环均有 coroutine 检查点；状态预算暂停保留同一协程，Resume 重置本轮计数，Cancel 删除协程并关闭推荐可用状态。
- TOC 当前 Domain → Solver → Feature 的顺序正确；Feature 通过 job API 调度，小窗按 cash/combined 读取推荐并传回显式 objective，未发现此共享接口的关键断裂。

## 验证边界

- 作者提供的 optimizer/独立随机 DAG/其它回归结果仅作为已有证据线索，本审查没有复述为自己重新运行通过。
- 本审查实际执行：初审一个 Lua 5.1 内存最小反例；复核时同一反例的折价 0/1 两个分支，以及两个计时定向用例。未重复作者的完整 18/18 optimizer 或 20/20 Feature 套件。
- 没有经过核验的完整赤石真实链；Native 绑定枚举仍待核验；RU 原生 UI、实机帧耗时和交互观感没有由静态代码或合成测试证明。

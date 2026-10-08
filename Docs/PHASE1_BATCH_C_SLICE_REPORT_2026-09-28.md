# Phase 1 Batch C：源码故障域拆分报告（2026-09-28）

Build: `v3-m1.16.0.18.330-phase0-trust-baseline`（Batch 中间不推进新 BuildTag）
范围：§23.8 Batch C（`combat_boss_alerts`、`combat_target_monitor`、`combat_buff_cap`、`combat_raid_recruitment`）。
主记录见规划文档 §23.14；本文件补充搬迁方法、证据与未覆盖项。

---

## 1. 结论

```text
rs_business_bridge.lua   4716 → 3940 行   ← 首次低于 4000，退出 Architecture Audit 的 GIANT_FILE 名单
注册点                   10 → 6 个 Feature
Architecture Audit       GIANT_FILE 3 → 2；债务 49 → 48
门禁                     默认 Full Runner exit=0；--feature-split 46/46；其余全绿
业务行为                 1:1（身份/Store/owner/契约版本/Commands 精确集合/任务名/cadence/释放语义全部实跑断言）
```

---

## 2. 搬迁方法（本轮刻意改成脚本抽取，降低手工转录风险）

四个 Feature 共约 790 行，手工复制容易出现缩进、条件或注释漂移。实际做法：

```text
1. 先用分析脚本确认每个区块引用了哪些 chunk 级 local（含多赋值 `local A, B = ...`，这是第一版脚本漏掉的地方）；
2. 用抽取脚本按行号区间取原始文本，写入前断言区块首行/末行内容（do / end / NewFeature("... / })）；
3. 新文件 = 文件头注释 + prologue（工厂别名 + rawget 宿主）+ 原始区块逐字；
4. bridge 侧把区间替换成两行指针注释，不重排缩进、不改条件、不动注释。
```

这样“只改源码边界”是可验证的：`grep` 确认全树只有一个 `NewFeature("<id>"` 注册点，且 bridge 内不再残留
`TARGET_MONITOR_TASK` / `BOSS_OBSERVE_TASK` / `BUFF_CAP_POLL_TASK` / `BUFF_CAP_REFRESH_TASK` 等符号。

---

## 3. 生命周期实跑证据（不是静态检查）

| Feature | 驱动方式 | 断言结果 |
|---|---|---|
| boss_alerts | `Enable()` + `AcquireConsumer()` | 任务 `v3_business_boss_alert_observe` 出现（100ms）、CastingObservationV3 + AuraObservationV3 两个租约被持有；`ReleaseConsumer` + `Disable` 后任务消失、两个租约释放 |
| target_monitor | `Enable()` + `AcquireConsumer()` | 任务 `v3_business_target_monitor_distance` 出现（500ms）、`TARGET_CHANGED` 订阅建立；释放后任务与订阅一起消失 |
| buff_cap | `Enable()` + `AcquireConsumer()` | 兜底任务 `v3_business_buff_cap_poll` 出现、`BUFF_UPDATE` 订阅建立；释放/停用后全部回收 |
| raid_recruitment | `Refresh()` + 四个命令 | 只读申请列表投影为 `partial` 并带“仍待 RU 验证”；`Create/Accept/Reject` 显式返回“已安全停用”；`Close` 才真正调用 `X2Team:RaidRecruitDel` |

一个值得记录的语义：**boss_alerts 在没有规则目录时不会启动观察任务** —— `BossSyncObservation` 要求
“enabled + 有消费者 + hudEnabled + 有启用规则（或有 showObservedCasts）”。这是正确的“无规则即无观察”，
测试因此注入了 2 条规则（cast + debuff）才能驱动观察任务。

---

## 4. FND-001 实测修正（重要）

```text
Batch C 前：luac5.1 -l → 188 slots / 246 locals / 258 functions
Batch C 后：luac5.1 -l → 187 slots / 182 locals / 187 functions
```

**搬走 776 行只释放了约 1 个 chunk 级槽位。** 原因：boss_alerts 与 buff_cap 本来就写在 `do ... end` 块内
（块级作用域不占 chunk 槽位），另外两个几乎没有顶层 local。真正占槽位的是散落 chunk 顶层的 helper：

```text
1-399      文件头/宿主              45 slots
400-1399   bag 搬运 helper          32 slots
1400-1747  bag 批处理 helper        22 slots
1748-2055  team_tools helper        18 slots
2057-2198  team_tools auto role      8 slots
2199+      tools_craft helper       30+ slots
声明合计 202 slots，峰值并发 187/200（剩余约 13 个槽位）
```

结论：**FND-001 的进展只能用 `luac5.1 -l` 的 slots 数衡量，不能用行数**。真正的缓解在 Batch D/E
（team_tools / craft / auction / bag / unit_lines / range_assist，其 helper 是 chunk 级 `local function`）。

---

## 5. 修改文件

新增：

```text
features/combat/boss_alerts/rs_boss_alerts_feature.lua
features/combat/target_monitor/rs_target_monitor_feature.lua
features/combat/buff_cap/rs_buff_cap_feature.lua
features/combat/raid_recruitment/rs_raid_recruitment_feature.lua
```

修改：

```text
toc.g                                         +5 行（四个新文件各登记一次）
features/rs_business_bridge.lua               删除四个区块（4716 → 3940）
tools/rs_feature_slice_split_tests.lua        +11 条 Batch C 契约断言（累计 46）
tools/rs_udf_numeric_test_host.lua            补 BindOwner / UnsubscribeInternal / UnsubscribeInternalOwner / CountOwner
Docs/Replicated_Suite_底层框架重构规划_v1.md   §23.14 + 状态表
Docs/Replicated_Suite_#U…_v1.md               别名同步
Docs/DOCS_FILE_INDEX.md                       新增本报告条目
```

未改动：`core/**`、`services/**`、`presentation/**`、`ui/**`、`data/**`、`native/**`、所有 Store ID/Schema、
Feature ID、route、公开 Commands、Projection shape。四个新 Feature 没有被任何离线宿主单独 dofile，
所以本轮无需改宿主加载顺序（只有测试宿主补了事件契约）。

---

## 6. 未覆盖 / 下一批次注意

```text
1. 本轮仍无 RU 实机结论。四个 Feature 的实机验收（尤其 boss 读条/Debuff 触发与 buff 计数容量语义）仍待用户侧确认。
2. 盘上本来就缺 boss/cap 相关专项套件（rs_boss_alerts_regression_tests.lua / rs_boss_alerts_ui_tests.lua /
   rs_boss_hud_tests.lua / rs_buff_cap_regression_tests.lua / rs_buff_cap_ui_tests.lua 等），
   因此 runner 的 --boss-alerts / --buff-cap / --enemy-boss 入口仍是既有债务（不在默认门禁内）。
   本轮没有伪造这些套件，只把“拆分没有改契约”写进 --feature-split。
   若后续要恢复它们，按 §22.3 的方式从 18.244 归档逐字恢复并逐项分类断言。
3. 下一批 Batch D（§23.8 第 10-12 位）：combat_team_tools、tools_craft、tools_auction。
   注意：team_tools 有 roster lease + auto-role 任务；craft 有 resolution/graph 与 CraftSurface 扩展；
   auction 的收藏 CRUD/Sidecar 命令仍属该 Feature 私有（不得并入 rs_auction_read_model.lua）。
4. 最后一批 Batch E：tools_bag（搬运事务/黑名单，风险最高）、combat_unit_lines、combat_range_assist
   （高频投影，必须证明 cadence 与 projection 契约不变）。
```

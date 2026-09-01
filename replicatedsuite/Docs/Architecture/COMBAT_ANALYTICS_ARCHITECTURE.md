# Combat Analytics Architecture — M1.16.0.11

## M1.16.0.18.44 Player-Placed Skill Proxy Source Classification

Combat Fact 的 `sourceName` 不等于 Actor Authority。RU 已实机证明部分玩家放置技能会以技能实体名作为治疗 source。`CombatEventBusV3` 继续保持中立、不可修改事实；`DPS Domain v7` 在自己的业务入口先通过 `CombatSourceProxyCatalog` 识别代理源。

当前 API 契约没有可靠的 generic owner link，可以把某次 placed proxy heal 精确关联到其 caster。**本机观察到一次同技能施法也不是充分证据**：团队里其它玩家可能同时放置同名实体，因此“唯一已观察候选”仍可能是假唯一。准确率优先，所以代理源当前不归并任何玩家，不以 proximity/latest-caster/目标关系/时间窗口猜测；只进入 bounded session diagnostic。真实 sourceName 已经是玩家的同技能事实照常处理。

代理 source 在 DPS 内早于 CombatRelation 处理被识别并终止 Actor 路径，因此不会把技能对象学习成 PLAYER/FRIENDLY。该设计不增加 Native handler 或 CombatAnalytics metric 订阅；热路径只有预建 exact lookup。未来只有在 RU 暴露显式 owner identity（或事件本身携带可验证 owner）后，才允许新增 owner attribution。

## M1.16.0.18.17 Presentation Selector Boundary

排行 value 选择模型属于 Feature 对 Presentation 的 detached read model。`VALUE_OPTIONS` 保持 Feature 私有 local；页面必须通过 `Feature:GetValueSelectorModels()` / `GetValueOptions()` 读取，写入仍只经 `Feature.Commands:SetSelectedValue()`。Presentation 不允许复制第二份 value map，也不允许直接引用 Feature 文件 local。该契约修复了实机 `rs_v3_combat_analytics_page.lua:146 pairs(nil)`。


> **Authority Level**: ARCHITECTURE  
> 适用范围：Active V3 战斗统计 / 战斗贡献分析。  
> 当前实现：`CombatEventBusV3 v6` + `CombatAnalyticsV3 v3` + Metric Registry + 有界 Actor Drilldown Projection。

## 1. 目标

Replicated Suite 的战斗系统不再等同于单一 DPS 排行。M1.16.0 建立可长期扩展的 **Combat Analytics**：伤害、承伤、治疗继续由成熟 DPS Domain 负责；击杀/助攻/死亡、技能活动、爆发、控制、乐器、辅助、Aura、Boss 机制与 Encounter 由独立 Metric 插件负责。

最高原则：**统一事实入口，独立业务状态，独立生命周期，统一 Projection。**

```text
Native Combat + Optional Native Cast Events
                 │
                 ▼
          Core Events v3
                 │
                 ▼
       CombatEventBusV3 v6
                 │
                 │ ONE scope=all consumer
                 ▼
       CombatAnalyticsV3 v3
                 │
                 ├─ compiled fact dispatch plans
                 ├─ compiled native dispatch plans
                 ├─ metric lifecycle / health
                 └─ merged projection publish
                     ├─ dps_core (hidden adapter)
                     ├─ encounter
                     ├─ kills
                     ├─ casts
                     ├─ performance
                     ├─ control
                     ├─ songcraft
                     ├─ utility
                     ├─ aura
                     └─ mechanics
```

## 2. Authority / Presentation 边界

- `CombatEventBusV3`：唯一 Active V3 Combat Fact Authority；不做 DPS/PVP/CC/击杀等业务结论。
- `CombatAnalyticsV3`：Metric 注册、单 all-scope Lease、分发计划、Optional Native 增强、Metric health、Projection publish 与 bounded actor drilldown Authority。
- Metric：只拥有自己的 Session 状态与业务推导；禁止直接创建 UI、保存 Permanent 设置或自行注册 `COMBAT_MSG`。
- Feature：拥有用户启停偏好、Metric 开关和 Projection/Commands 边界。
- Presentation：只消费 Feature Projection/Commands；不得直接触达 Metric State、Demand 或 Native combat handler。玩家明细必须走 `Feature:GetActorDetail -> CombatAnalyticsV3:GetMetricActorDetail`，不能直接读 `metric.state`。
- `DeathReview` 保持独立 `scope=self` 低成本 Consumer，不依赖高成本 Combat Analytics。

## 3. 单一 all-scope 消费者

公开 Metric 数量增加时，不允许形成：

```text
Kill -> COMBAT_MSG
CC -> COMBAT_MSG
Song -> COMBAT_MSG
Aura -> COMBAT_MSG
...
```

正确结构是 CombatAnalytics 只向 `CombatEventBusV3` 持有 **一个** `scope=all` Consumer，然后按预编译 category plan 分发。`damage` 不应调用只关心 aura 的 Metric；`aura` 不应调用只关心 death 的 Metric。

DPS 使用隐藏 `dps_core` Adapter 复用这个 all-scope 入口，但 PVP/PVE/Relation Replay/Shared Heal Ledger 仍归原 DPS Domain 所有。

## 4. Metric 生命周期

- 每个公开 Metric 都有独立 persisted preference。
- Feature 启用时只激活用户打开的 Metric。
- 单 Metric 关闭后必须 `Reset` 自己的 Session 缓存。
- 整体 Combat Analytics 关闭后释放唯一 all-scope Lease，并释放全部 Analytics Session 状态。
- **空 Metric 集合不构成 Consumer**：Acquire 空集合必须拒绝；已持有 Consumer Update 到空集合必须事务式 Release。公开指标全关时 Feature 不得继续占用 Bus；DPS 的隐藏 `dps_core` token 独立计算。
- Permanent 设置继续保存；Session 统计不写 Permanent Store。
- DPS 自身统计生命周期独立，不因 Combat Analytics 页面关闭而被清空。
- 批量清理通过 Authority 公共 `ResetMetrics(ids)`；异步 Metric 通过 `NotifyMetricChanged` 请求合并 Projection 发布；Feature/Presentation/Metric 禁止调用 `_SchedulePublish` 等私有实现。Metric Reset 返回 `false` 或抛错必须向上层传播，Demand 可回滚生命周期迁移。

## 5. 证据等级

不得为了“数据丰富”把推导值伪装成服务器事实。Projection/Detail 应保留证据来源。

1. **Direct**：CombatFact/Native Event 明确给出，例如 damage、heal、death、Aura apply/remove。
2. **Observed**：由明确 Start/End 计算，例如观察到的控制时长、Buff uptime、完整 START+STOP 的本机演奏时长。
3. **Inferred**：由有界上下文推导，例如死亡缺直接来源时的最近伤害最后一击、最近参与伤害助攻、全局技能活动次数。

“未观察到”不能解释为“0% uptime”。

## 6. Optional Native Event

`SPELLCAST_START/STOP/SUCCEEDED` 等属于增强证据，不是 Foundation 必需事件。`Core Events v3` 提供 Optional Subscription：

- Required 注册失败：事务失败，不提交 listener。
- Optional 注册失败：记录 degraded health，但不阻断 Foundation。
- Topic 同时存在 Required/Optional listener 时，required/optional 属性由**当前已提交 listener 集合重新计算**。
- 禁止用 Lua `a and b or c` 模拟可能返回 `false/nil` 的事务分支；必须显式 `if/else`。

乐器时长尤其遵守：只有 `SPELLCAST_START` 与 `SPELLCAST_STOP` 都是 `FULL` 时，才能产生 SELF 精确演奏持续时间；只有 START 时只记录开始次数，**不得根据下一次 START 或墙钟时间猜持续时间**。

## 7. 有界数据结构 / 高频性能

Combat 热路径禁止 `table.remove(queue, 1)`、稀疏数组 `#table`、模糊 Tag/字符串目录全扫描和无界历史。`MetricCommon v2` 的 Queue 使用显式 `head/tail/count`。

当前主要硬边界：

- Actor/Metric：512。
- Encounter 当前 Timeline：512。
- Encounter History：20 条紧凑摘要，不复制 Timeline。
- Kill 最近目标：512；每目标最近来源：64。
- Death dedupe：512。
- Control active Aura：512。
- Song/Aura active observation：1024。
- 5 秒爆发：100ms 时间桶，硬上限 64 桶；不以 hit 数截断真实伤害。

没有新增永久 Tick。Encounter 使用 idle one-shot；Projection 350ms 合并发布。

## 8. Encounter 契约

- 只有 `damage / heal / death` 可以开启或延长 Encounter。
- Aura 只能附着当前 Encounter，不能在战后自己开启/续命。
- 8 秒无锚点事件关闭。
- one-shot 只是及时关闭辅助；**新事件本身也必须检查与 `combatLastAt` 的 8 秒 gap**，防止 Scheduler starvation 把两场战斗合并。
- History 只保留紧凑摘要；当前 Timeline 结束后释放。

## 8.1 排行值选择交互（M1.16.0.18.15）

一个 Metric 内的 `valueKey`（例如 kills 的 `kills / assists / deaths`）属于 Feature persisted preference，不是 Presentation 私有状态。Active Page 使用有界 `SegmentedSelector` 直接切换，点击必须进入 `Feature.Commands:SetSelectedValue(metricId, valueKey)`；Presentation 不得绕过 Command 写 Store，也不得用本地按钮状态制造第二 Authority。

Store 对每个公开 Metric 维护明确 value-key 白名单。迁移/读取遇到未知旧值时 Normalize 到该 Metric 默认值；用户交互写入未知 key 必须拒绝，而不是先保存无效字符串再依赖 Projection 隐式回落。这样“击杀按钮看起来没切换”的 UI 问题不会被非法 persisted value 放大。

## 9. 当前内置 Metric

| Metric | 主要能力 | 证据说明 |
|---|---|---|
| encounter | 当前战斗、20 场历史、Timeline | Direct anchors |
| kills | 击杀、推导助攻、死亡 | Direct death + bounded inference |
| casts | 技能活动、SELF 精确施法、起手 | Inferred + Optional Native |
| performance | 最高单击、5 秒峰值、死亡 | Direct damage/death |
| control | 控制释放、命中、观察时长 | Catalog activity + observed Aura |
| songcraft | 演奏活动、SELF 开始/停止、覆盖 | Optional Native + observed Aura |
| utility | 打断/驱散/净化/复活/防御**技能活动** | 当前不等同成功效果 |
| aura | Buff/Debuff apply/remove/观察 uptime | Observed Aura only |
| mechanics | Boss 机制精确命中 | exact catalog only；有目标优先记受影响目标 |

## 10. 准确性细节

- 同一技能 inferred activity 后 250ms 内出现 SELF Native START：起手序列升级证据，不重复插入。
- Death 多通道证据约 1.2 秒去重。
- 控制/Aura 正在持续时，Projection 可加入当前 open interval；结束后再提交正式累计。
- Boss 机制有明确目标时排行受影响目标；无目标才回退来源，避免把“被机制命中”统计到 Boss 本身。
- Analytics Actor key 优先完整 display name，并保留 `Name@World`；只有名字缺失时才退回 stable id。DPS 的更严格 UnitIdentity/Replay 逻辑不由 Analytics 替代。

## 11. 玩家 Drilldown / 技能元数据边界（M1.16.0.11）

Combat Analytics 的 Metric state 继续属于各 Metric/Analytics Authority。为了让页面真正可用，`CombatAnalyticsV3 v3` 提供 `GetMetricActorDetail(metricId, actorKey, options)`：只在用户选中玩家/刷新详情时，把最多 12 个 section、每 section 最多 64 行、起手最多 12 项复制成只读 Projection；不得把整张 Metric state 暴露给 Presentation。

DPS 技能明细单独遵守事件语义：RU `MELEE_DAMAGE` 的 raw `abilityId` 实际承载伤害值，不能当 Skill ID；只有已确认携带真实技能 ID 的 Fact 类型才允许进入 Domain detail。`SkillMetadataV3` 只负责 UI Drilldown 的名称/Icon 补全，缓存上限 512，并缓存 negative lookup；`X2Skill` 调用禁止出现在 Combat Bus/Domain 的逐事件路径。

页面上的“开始/暂停/单项启停/清空”是用户命令，必须进入 ActionRunner 给出 Busy/成功/失败反馈；“当前项目没有数据”必须区分 Analytics 未启动、Metric 被暂停、正在采集但尚无匹配事件三种空态。

## 12. 后续扩展规则

新增 Metric 前必须回答：

1. 证据来自哪个已有 Fact/Optional Event？
2. 是否真的需要新的 Native Event？如果只是增强，必须 Optional。
3. Session 状态上限是什么？
4. 关闭 Metric 时释放什么？
5. Projection 是否把 inferred/observed/direct 标清？
6. 是否能复用 Ability/Mechanic Catalog，而不是热路径重新做复杂匹配？

禁止为了新增统计重新建立第二套 Combat Event Host。

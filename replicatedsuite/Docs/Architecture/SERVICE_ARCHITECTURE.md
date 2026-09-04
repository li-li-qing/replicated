# Replicated Suite 服务架构（Service Architecture）

> **Authority Level**: ARCHITECTURE
> 当前权威：V3 Active TOC 的 Shared Services / Shared Runtime Foundation。Legacy ServiceModule / Professional 源码仅作迁移参考。

## 1. 当前 V3 服务分层

```text
Feature Modules
    ↓ Consumer Demand
QuestProgressV3 / InstanceCatalogV3 / AuraObservationV3 / UnitIdentityV3 / CombatEventBusV3 / TeamRosterV3 / CombatRelationV3
    ↓
Demand / RefreshCoordinator / Scheduler / Events / Observation
    ↓
API Capability Boundary / Native read-only API
```

- Service 只拥有共享事实、共享投影或共享访问生命周期；不得拥有某个 Feature 的业务结论。
- Feature Enabled、HUD Visible、Consumer Demand 三者严格分离。隐藏 UI 不能冒充停止 Service；最后一个 Consumer 离开后，高成本 Service 必须停止事件/周期任务并释放下游 Lease。

## 2. Demand / Consumer Lease Contract

`core/rs_demand.lua` 是共享引用计数 Authority。

- Token Acquire 幂等；同 token 可更新 Options。
- 0→1 / Options Change / 1→0 都经 Owner `reconcile`。
- Reconcile 失败时先恢复 Consumer State，再以 reverse transition 调用 reconcile 回滚下游 Acquire/Start/Subscribe 等副作用。
- `consumerCount` / `consumers` 可作为兼容诊断投影，但业务不得再手工维护第二套计数。
- Runtime Stop 会按 Demand 创建顺序的**逆序** ClearAll，使 Feature→Service→Foundation 依赖先上后下释放；Bootstrap 新 Generation 重新创建 Registry，禁止跨代复用 Consumer。
- Demand v2 不再把内部 Consumer Table 直接暴露给 owner，诊断投影使用 DeepCopy。正常 Clear 失败时可进入 owner 提供的 `quiesce`，尽最大努力解除 Native Handler/下游 Lease 后再 ForceClear 逻辑意图；`quiesceFailures` 必须可诊断。FeatureRuntime 还会把清理前已残留的 Feature Demand 标记为 `stale_demand` shutdown failure，避免安全兜底被误报为正常生命周期。

## 3. RefreshCoordinator Contract

`core/rs_refresh_coordinator.lua` 在现有唯一 `Scheduler` 上提供滑动防抖与原因合并。

- Identity = `owner + stable key`；**callback closure 地址不是冲突条件**。
- 重复 Request 只重排同一个 one-shot，并合并 reason set。
- 无第二 Tick / OnUpdate；Owner Release 或 Runtime Stop 必须取消 pending refresh。
- 周期任务仍归 Scheduler；RefreshCoordinator 只处理有限的 debounce/coalesce work。
- M1.15.7：`Scheduler v3` 的动态 one-shot module metadata 必须标记 transient 并随任务回收；静态模块任务映射可跨停启保留。`Events v2` 的 Native RegisterEvent 是订阅事务的一部分，Register 失败不得出现逻辑 listener 已提交的“假订阅”。

## 4. Aura Observation Domain（Phase 12B）

`services/rs_aura_observation_v3.lua` 是 Buff / Debuff / Hidden Buff 的共享**事实层**。

- 无后台扫描；只有持有 Consumer 且业务显式 `GetSnapshot()` 时读取 Native Aura。
- 短 TTL、有界 Cache；Cache 带每 lane 的 scan coverage，低 limit 快照不能满足后续更深请求。
- 每 lane 先做一次 Capability Gate；循环内走低级 `S.Api:Call`，避免每个 Aura 重复 Registry 查找。
- 优先读取低成本 `UnitBuff/UnitDeBuff/UnitHiddenBuff` Data Row；仅 Effect ID 缺失时使用 Tooltip fallback。
- Healer 推荐、Plates 显示、Boss 规则、团队战备判断等仍属于各自 Domain，绝不提升到 Aura Service。
- Phase 12B 新增 `GetStatusMap(snapshot, options)`：只消费已捕获 Snapshot，统一 effect id / stack / timeLeft / name / icon / source mask；**不产生 Native read**。
- `EvaluateRequiredEffects()` 使用保守三态：全覆盖下缺失=`false`，扫描/能力不完整下缺失=`nil/unknown`，全部存在=`true`；用于团队战备及后续 Healer/Plates 迁移，禁止因覆盖不全伪造“缺 Buff”。
- M1.16.0.18.4 的 `combat.buff_display` 是首个 StatusMap consumer：Aura Service 只提供 snapshot/status facts；过滤器、显示上限、scope 与“待确认”投影语义由 Feature 自己拥有，Page/Widget 不直接读取 X2Unit。
- 首个 Phase 12B Consumer 为 `combat_raid_readiness`：页面只持有 TeamRoster；手动扫描且配置关键 Buff 规则时才短暂持有 Aura lease，完成后立即释放。
- M1.16.0.15 新增 Healer-owned `HealerAuraBridge` 作为**迁移桥**：桥本身 dormant，不因 Active TOC 加载而 Acquire；该阶段仅为未来 Healer Runtime 准备 lease。历史 Healer StatusCache 只接受 `available+complete+reliable` 的共享状态作为评分输入；否则回退旧直读以保准确率。Aura Service 仍不拥有任何治疗语义。
- M1.16.0.16 `combat_healer` 已成为 Active V3 Consumer：Feature Enabled 才持有 Healer Aura lease；`HealerAuraBridge v2:ReadAccurate()` 首选共享 StatusMap，覆盖不完整才执行 Feature-owned Native fallback。Fallback 是准确性安全阀，不回写 Aura Service Cache，也不把治疗规则提升到 Service。Health Runtime 通过一个 Suite Scheduler 任务消费该事实，关闭 Feature 后 Aura/TeamRoster/Event/Scheduler 资源全部释放。
- M1.16.0.17 曾让 Healer Page/Floating Widget 读取已提交 Projection；M1.16.0.18.43 已按用户决定移除推荐 Floating 与主 Page 的名单/详情表。Recommendation committed facts 仍服务 Raid Overlay 颜色/优先级，但不再复制成列表 Presentation，也不会建立第二套 Aura scan。
- M1.16.0.18 Head Marker / Raid Overlay 同样只增加 **Presentation Demand**，不增加 Aura Service consumer/cache 或第二套 Health/Status scan。Head 所需屏幕位置由 Feature-side `HealerScreenProjection` 单次调用 Native screen-position capability，它不是 Aura/Observation Service，也不缓存业务事实；Raid 只消费 Feature 从 Recommendation committed Health/Status + roster 生成的 detached display projection（含 candidate/rank 与非候选基础状态色）。关闭显示层后其独立 Presentation Demand/视觉 Task 必须释放。
- M1.16.0.18.18 follow-up 修复了共享状态解析的 Lua 5.1 nil 截断：Tooltip 缺失时 `GetStatusMap()` 和 HealerAuraBridge 的 Data Row fallback 仍会读取 stack/timeLeft/name/icon，不把“Tooltip 不可用”错误地降级成字段缺失；Aura 回归覆盖完整、部分和不可用扫描三态。


## 4.5 Screen Projection Service（M1.16.0.18.45 / v3）

`services/rs_screen_projection_v3.lua` 是共享、只读的 **坐标投影能力边界**，不是业务事实 Service：

```text
Feature Demand (Healer marker / UnitLines / RangeAssist)
        ↓
ScreenProjectionV3
        ├─ X2Unit:GetUnitScreenPosition
        ├─ X2Unit:GetUnitWorldPositionByTarget
        ├─ optional global ConvertWorldToScreen
        └─ UIParent Camera fallback
        ↓ detached x/y/depth
Presentation
```

- Service 自己没有 Tick、Scheduler、事件订阅或跨帧业务 Cache；采样 cadence 完全归调用 Feature 的 Demand 生命周期。
- `ProjectWorldBatch(points)` 在 native global projector 不可用时，一批点只捕获一次 Camera pos/dir/fov；范围圆不能对每个点重复读取相机 getter。
- `combat.unit_lines` 当前消费有界的 `player/target/targettarget/watchtarget/watchtargettarget` token，可分别形成 self↔target、target↔targettarget、self↔watchtarget、watchtarget↔watchtargettarget 四条关系；`.18.87` 的 Presentation 先裁剪 logical viewport 可见段，再以 Store 中旧 `pointCount/pairPoints` 作为基础密度做屏幕空间自适应采样；HighFrequency producer 使用 P1 保持视觉 cadence，帧压力只削减 adaptive extra，Presenter-local Diff 与渐进点池控制 Native 峰值；`.18.88` 的 ScreenProjectionV3 v4 在同一 caller-demand batch 内以 Camera Frame + world position 提供 front-hemisphere 端点事实，behind_camera 在进入 Presentation clipping 前 fail-closed；`.18.96` v5 进一步要求所有 unit world read 使用同一 global 坐标空间，并在同一 batch 已有 camera/world 事实上校验 Native screen point：可证明的 UI-scale 差异先 reconcile，仍严重偏移才 camera consistency fallback。ScreenProjectionV3 不拥有点密度/预算。禁止为了“全单位连线”重新调用已被证据阻塞的附近单位枚举。
- v5 输出统一到 RSUI logical UI space；Unit Lines batch 可显式启用 Native/Camera consistency gate，避免“数值仍落在 logical bounds 内但实际属于 physical/UI-scale 空间”的歧义；`combat.range_assist` 只投影用户指定半径，不拥有技能/魔法阵半径语义。未来技能范围事实必须来自独立已验证 Domain，不能塞进 ScreenProjectionV3。
- 投影失败返回 unavailable/partial；Presentation 隐藏点，不猜坐标。

## 4.6 Auction Query Service（M1.16.0.18.45）

`services/rs_auction_query_v3.lua` 是 Active V3 **当前拍卖挂单查询**的唯一事件 Authority：

```text
Auction Favorites / Market Analysis
        ↓ request(requester, query)
AuctionQueryV3
        ├─ SearchAuctionArticle(9 args)
        ├─ one global pending request
        ├─ AUCTION_ITEM_SEARCHED  ← 唯一 Active subscriber
        ├─ timeout / cooldown / bounded result read
        └─ requester-keyed detached snapshot
        ↓
Feature Projection / Page
```

- `AUCTION_ITEM_SEARCHED` 没有 requester token，因此不能让多个 Feature 各自订阅后猜“这次结果是不是我的”；Service 必须串行化 pending，并由 Foundation Audit 锁定单一 Active owner。
- 当前只证明“当前挂单结果”；`GetSearchedItemInfo` 行不带已验证的成交时间/交易 identity 时，禁止把它包装成历史成交价、趋势样本或时间序列。
- Service 自己拥有超时和清理；Scheduler 创建失败必须把 pending/event lease 一起恢复，不留下永久 busy。
- Result rows 有界（当前最多 30），Feature 只消费 detached snapshot；收藏、筛选、产品解释属于各 Feature。

## 5. Combat Facts Foundation（M1.15.1）

### 5.1 UnitIdentityV3

`services/rs_unit_identity_v3.lua` 只拥有保守身份事实：Native unit id 对应的官方名字、显式 Unit Kind、当前玩家身份缓存，以及 COMBAT_MSG raw id 的端点名称验证。

- raw id 不能仅因“看起来像 source/target”就绑定；必须用 `GetUnitNameById(id)` 与 source/target 名字做唯一匹配。
- 名字解析允许 `Name@World` 与短名比较，但两个不同、都明确带 World 的名字绝不合并。
- `GetUnitInfoById` 只接受显式 kind 字段；字段冲突时 fail-closed，不猜 PLAYER/NPC。
- 不拥有阵营、敌我、PVP/PVE、Boss、Healer priority 等业务结论。
- Cache 有界；无后台扫描。

### 5.2 CombatEventBusV3

`services/rs_combat_event_bus_v3.lua` 是 V3 Combat Native Fact Authority。

```text
private hidden COMBAT_MSG / UNIT_DEAD_NOTICE  -- scope=self
                  │
                  ├──── normalized Combat Fact ──── Consumer
                  │
global UI + UIParent COMBAT_MSG              -- only scope=all
```

- `scope=self` Consumer 只启动私有 Native Host，适合 DeathReview 等低成本 Feature。
- 只有至少一个 `scope=all` Consumer 时才注册全局 `UI/UIParent` Handler；最后一个 all Consumer 离开立即释放。
- RU 历史实机证据显示团队其它成员行可能只出现在全局路径，因此 DPS 未来必须使用 all scope，而不能把私有 Host 当全量事件源。
- Global 路径过滤当前玩家端点，避免与 private slice 重叠。M1.15.7 的 `CombatEventBusV3 v5` 使用每 Host FIFO token 做 UI/UIParent 短窗口 1:1 配对：同一 Host 的真实连续相同行不去重，跨 Host 镜像按 multiplicity 逐条抵消；未配对 token 受 50ms TTL、256 容量与 backing-order 压缩约束，并暴露 pending/evicted。
- 输出只包含 kind/category/amount/raw payload/sourceId/targetId 等事实；PVP/PVE、敌我、排名、统计属于各 Feature Domain。
- 无 Tick/OnUpdate；Consumer Demand 决定 Native Handler 生命周期。全局桥启动失败时 Demand 整体回滚。
- M1.15.2 首个实际消费者为 `combat_death_review`：只申请 `scope=self`。这验证了共享 Combat 底座不会因为低成本 Feature 启用而启动 DPS 所需的 all-scope 全局桥。

### 5.3 M1.15.2H Combat Hardening

- `scope=all` 在玩家身份尚未准备好时不得静默丢行：使用最多 256 条、TTL 1500ms 的 Pre-Identity Journal；Identity Ready 后按原顺序重放。过期或溢出必须计 `journalDropped`。
- `GetCoverageState()` 是 all-scope 数据质量 Authority：`FULL / DEGRADED / IDENTITY_COLD / UNAVAILABLE / INACTIVE`。只注册成功 UI 或 UIParent 单 Host、或者当前 Journal 发生 Drop 时必须 `DEGRADED`，未来 DPS 不得把它显示成完整统计。
- CombatFact 是 **borrowed + immutable**：Consumer 只能读取；长期保存必须复制自己需要的字段。Bus 按稳定订阅 serial 分发，当前 dispatch 中新订阅者不参与；错误 Consumer 修改任何公开标量字段（主语义、raw payload、death notice）都会被恢复并记录 `factMutationErrors`，但 Release 热路径不为每个 Consumer DeepCopy 全表。
- Native combat callback 必须保持轻量。死亡回顾等业务只能 capture/queue；Aura 强制读取、Persistence、复杂聚合与 UI 创建必须离开 Native callback，在共享 Scheduler/FrameBudget 安全执行点完成。

### 5.4 M1.15.2H2 Runtime Lifecycle Hardening

**1) 强制失活（Forced Inert）**

Demand 在 `Clear` 失败时会降级到 `ForceQuiesce`。此时即使 Native Host 摘不掉，战斗回调也**必须**停止业务处理：

- `quiesce` 先按常规 `_Stop()` 尽力释放，再无条件调用 `_MarkInert()`：`running=false`、`globalActive=false`、清空 Journal / 跨 Host 去重表。
- 释放的真实错误照常返回 → 计入 `Demand.quiesceFailures` 并发出 Diagnostics，**不静默吞错**。
- `_OnCombatRaw` / `_OnDeathNotice` 再加一道 `running` 闸门。此前只有 Native 闭包检查 running/Generation，Journal 重放等内部入口会绕过闸门把事实派发给已被丢弃租约的 Consumer。

**2) 释放结果分类（A / B）**

| 情况 | 判定 | 处理 | 指标 |
|------|------|------|------|
| A：Release API **存在**但调用返回 false / 抛异常 | 真实事务失败 | 返回 false → Demand 回滚消费者状态 → 反向 reconcile；Feature 停用如实失败，不假装成功 | `releaseCallFailures` |
| B：RU Build **根本不暴露** Release API | 能力缺口，**不是**业务失败 | generation-local 隐藏停放，下次 0→1 复用同一 Host；回调由 `running` + Generation 闸门保持惰性 | `releaseApiMissing`、`privateParked`、`globalParkedHosts` |

两种结果都必须可诊断；`stopFailures`、`forcedInert` 同时上报。**不允许**再次出现「API 不存在 → 用户关闭/切换功能直接失败」。

**3) scope 是分发契约，不只是传输提示**

`C:AcceptsTransport(options, transport)`：

- `scope=self` → 只接收 private 传输（含 `UNIT_DEAD_NOTICE` 的 `private`）；
- `scope=all` → 接收 private + global。

DPS 启用全局桥后，DeathReview 等低成本 `scope=self` Consumer 不再为每一行 all-scope 战斗事实付代价。过滤量计 `scopeFiltered`。

**4) 热路径诊断必须限流**

`COMBAT_CONSUMER_CALLBACK_FAILED` / `COMBAT_FACT_MUTATED` 走 `DiagnosticsManager:RateLimited`（3s 窗口）。直接 `Emit` 会在战斗高峰期每秒产生数百条落盘日志。计数器（`callbackErrors` / `factMutationErrors`）仍逐条精确，只是日志行被聚合。

## 6. 当前 V3 Service

| Service | Authority | 生命周期 | 说明 |
|---|---|---|---|
| `QuestProgressV3` | Quest/Activity progress projection | Demand | 事件 + 15s safety；事件刷新经 RefreshCoordinator |
| `InstanceCatalogV3` | X2BattleField entrance facts | Demand | 事件 + 30s safety；发现/计数刷新经 RefreshCoordinator |
| `AuraObservationV3 v2` | Aura native facts + normalized status projection | Demand | 无周期任务；显式读取 + 短 TTL Cache；StatusMap/Evaluate 不新增 Native read |
| `UnitIdentityV3` | Conservative unit identity facts | Read-through cache | 有界 cache；无后台扫描；只做唯一端点验证与显式 kind |
| `CombatEventBusV3 v5` | Native combat facts | Demand (`self` / `all`) | 私有事件始终按需；全局桥仅 all scope；UI/UIParent FIFO token 1:1 去重且有 TTL/容量边界；已验证端点可附加显式 Kind；无业务结论 |
| `TeamRosterV3 v4` | 当前本机可见团队成员名字/槽位事实 | Demand | Consumer 持有时才扫描；player 与团队槽位命中同一身份时原位合并为唯一 canonical row（保留 `player` Native token，同时补齐 team/member slot）；瞬时 player-name 失败保留最后有效快照并最多 3 次 one-shot 重试；TEAM_MEMBERS_CHANGED 只做失效信号；无 Tick |
| `CombatRelationV3 v4` | Unit relation facts (SELF/TEAM/FRIENDLY/OPPONENT/UNKNOWN) | Demand | MANUAL 最高优先；SELF 来自 UnitIdentity，TEAM 来自 TeamRoster；`RecordCombatFact` 返回关系变化元数据供 Consumer 合并重放；Kind 与 Relation 分权；不拥有 DPS 业务结论 |
| `ScreenProjectionV3 v5` | Native world/screen → RSUI logical projection | Caller Demand | 自身无 Scheduler/cache；支持 unit token、batched world projection、front-hemisphere unit batch 与 opt-in Native/Camera consistency reconciliation；Camera Frame 仅在 caller batch 内复用，behind_camera fail-closed |
| `AuctionQueryV3 v2` | Current auction listing search + un-tokened completion event Authority | Explicit query | 单 pending、9 参数 Search、8s timeout、5–30 bounded rows；只证明当前挂单，不证明历史成交 |

## 6.5 DeathReview 采样边界（M1.15.2H2）

`rs_death_review_authority.lua` 的 COMBAT_MSG 回调只允许做 capture。常规 Debuff 采样虽然原本有 150ms 节流，但**节流不等于离开回调** —— 它仍会在 Native 战斗事件派发过程中触发 Native Aura 扫描。

现在的契约：

```text
OnCombatFact (Native callback)
    └─ 只记录 incoming + RequestDebuffSample(now)
                                    ↓
                       Scheduler one-shot（FrameBudget 安全点）
                                    ↓
                            SampleDebuffs → Aura:GetSnapshot
```

- `RequestDebuffSample` 保持 `debuffSampleMinIntervalMs=150` 节流，且同一时刻只允许一个待执行采样（`debuffSampleScheduled`）。
- Scheduler 不可用时退化为直接读取，并计 `debuffDeferFailures`，不静默丢采样。
- `FinalizeDeath` 的强制 Aura 读取保留在原地 —— 它本来就在 Scheduler one-shot 上执行。
- 新增指标：`debuffDeferred`、`debuffDeferFailures`、`debuffSampleScheduled`。

## 6.6 DPS V3 Migration + Hardening（M1.15.3–M1.15.6）

`combat_stats` 是首个 `CombatEventBus scope=all` 业务 Consumer，分层与边界如下：

```text
CombatEventBusV3 (scope=all)
    ↓ immutable CombatFact (+ verified sourceKind/targetKind when available)
CombatRelationV3 ← TeamRosterV3 / UnitIdentityV3
    ↓ relation facts
DPS Domain (rs_dps_domain.lua)  —— 逐事件伤害分类 + shared heal ledger + bounded replay + detail
    ↓ GetProjection / ClearStats / GetHealth
DPS Feature (rs_dps_feature.lua) —— 生命周期 / 设置 / Commands / Projection 边界
    ↓ S.Persistence (v3.dps: 设置 + Boss 名 + widgetVisible + widgetWindow)
V3 Presentation (Widget/Page) —— FloatingSurface + WidgetHost + PageHost + ViewState/ActionRunner
```

- **Relation / Kind 分权**：`CombatRelationV3 v4` 只回答 SELF/TEAM/FRIENDLY/OPPONENT/UNKNOWN；Unit Kind 是独立事实，NPC/MATE/SLAVE Kind 不自动等于 OPPONENT。SELF 来自 `UnitIdentityV3`；TEAM 来自按需 `TeamRosterV3 v4` 动态快照。`RecordCombatFact` 应用首击证据后重新读取关系，并返回 `relationChanged` 元数据；DPS 只据此请求 Scheduler 合并重放，不在 CombatFact 回调里扫描账本。damage 的关系反推只允许 SELF/TEAM 可信锚，第三方 FRIENDLY/OPPONENT 不得给 UNKNOWN 端点递归贴阵营。
- **逐事件贡献与可重放分类**：DPS Domain v5 对伤害按来源×目标返回 PVP/PVE/UNKNOWN；每条伤害事实分别累计 `source.damage` 与 `target.taken`。治疗只写一次 Shared Heal Ledger，PVE/PVP Projection 合并同一份数据。模式/阵营未决时数值进入 `unclassified`/side-unknown 保留桶，同时最多保留 512 条**自有标量快照** Replay；禁止持有 borrowed CombatFact。关系/Kind 更新后在 Scheduler 安全点搬桶。provisional contribution 在最终归类前**不提交 active clock**，因此 PVE→PVP 搬迁不会留下无法回滚的旧活动时间；技能/目标明细与主贡献共用回滚引用，零值 detail row 删除并归还有界计数。账本溢出不删除已累计数值，只计 `pendingEvicted`。
- **显示上限只截 Projection**：`GetProjection` 的 `displayRows`（默认 12，硬顶 `MAX_RANKING_ROWS=150`）只截断返回行数；`modes[].*.actorCount` 累积永不受限。
- **统计生命周期独立**：`DPS:ClearStats` 只在用户显式清空时重置 Domain 统计且不停 Consumer；Feature Disable/Quiesce 释放 Consumer/Relation/TeamRoster 与 Replay/Segment 临时状态，但保留本次 Session 已累计统计，重新启用可继续查看。
- **无持久化运行总量**：`rs_dps_store.lua` schema 4 经 `S.Persistence:RegisterV3Store` 只存设置（含 mode/side/metric/displayRows/alwaysShowSelf）、Boss 名、悬浮窗 `widgetVisible` 偏好和 FloatingSurface `widgetWindow` 状态（Account/Permanent），不得直接 `LoadData/SaveData/ClearData`。
- **零 Tick**：事实回调只做有界 `OnCombatFact`；Projection 用 400ms `Scheduler:AddOneShot` 合并发布，关系/Kind 证据重放用 160ms one-shot。`TeamRosterV3 v4` 只在 Demand 0→1 / TEAM_MEMBERS_CHANGED 后的安全点扫描；冷启动失败最多追加 3 次约 450ms one-shot 重试并保留最后有效快照，不在 CombatFact 回调扫描单位。
- **身份键保守性**：DPS 聚合键不再裁掉 `@World`；两个都明确带 World 且 World 不同的名字绝不合并。短名与带 World 名在没有稳定 ID 证据时宁可暂时分行，也不把两个跨服角色错误合并。

## 7. 旧版架构（已删除）

`modules/professional/`、旧 `services/`、`ModuleManager`、`rs_state`、`rs_storage`、`rs_module_manager`、`rs_module_sandbox` 等旧版代码已于 2026-09-01/02 全部物理删除（commit 09010c0），不再随包。用户持有全量离线备份，插件树内绝不重新引入。V3 共享服务见 `services/` 目录与 [`../CURRENT_ARCHITECTURE.md`](../CURRENT_ARCHITECTURE.md) 附录 §G 共享服务层。重建被删功能时必须拆分"共享事实 Service"和"Feature 业务判断"，禁止重新建立超级 Service/Core。


## CombatEventBus RU Release Compatibility（M1.15.2H1）

`CombatEventBusV3` 的正常目标仍是 Demand 0 时解除 Native handler。实际 RU Client Build 若根本不提供 `UnregisterEvent` / `ReleaseEventHandler`，不得把“能力不存在”误判为业务关闭失败；此时允许 generation-local retained host 进入隐藏停放模式：

- `running/globalActive=false` 时 callback 由 runtime/generation guard 立即返回；
- 下次 Demand 0→1 复用同一个 Native host/handler，避免重复物理 ID；
- Diagnostics 暴露 `privateParked/globalParkedHosts`；
- 如果 release API **存在但调用返回 false/异常**，仍然视为真实释放失败并触发 Demand 事务回滚，不能静默吞错。


## M1.16.0 Combat Analytics Service Contract

- `CombatEventBusV3 v6` 继续是唯一 Combat Fact Authority，并增加保守 Aura `apply/remove` 归一化；不做 CC/击杀/乐器等业务结论。
- `CombatAnalyticsV3 v2` 是高级分析聚合 Authority：一个 `scope=all` Bus Consumer、多 Metric compiled dispatch、Optional Native cast enrichment、350ms merged publish。
- Metric 必须声明 `factCategories/nativeEvents`；禁止自行注册 Native `COMBAT_MSG`。
- `Events v3` 的 Optional Native Event 只用于增强证据；Required/Optional 事务与降级契约见 `COMBAT_ANALYTICS_ARCHITECTURE.md`。
- `dps_core` 是隐藏 Adapter，不改变 DPS Domain 的业务 Authority；DeathReview 不依赖 Analytics。
- Session State 必须有界且在 Metric Disable/Analytics Quiesce 时释放。
- M1.16.0.1：Consumer 必须至少包含 1 个 Metric；Update 到空集合等价于 Release。批量清理必须走公共 `ResetMetrics`，异步 Metric 变化走 `NotifyMetricChanged`；Feature/Presentation/Metric 禁止调用 `_SchedulePublish` 等 Service 私有方法；Reset 失败必须传播，禁止假成功。

---

## 8. Metadata 服务公共缓存基类评估结论（2026-09-02）

`services/rs_buff_metadata_v3.lua` 与 `rs_skill_metadata_v3.lua` 的 cache 框架（`cache/order/orderHead/serial/cacheCount/cacheMax=512/hits/misses/nativeLookups/nativeFailures/evictions` + `_EvictIfNeeded`/`_Store`/`GetHealth` 基础字段）**完全同构（约 57 行重复）**，但二者的 Native 源、解析逻辑、cache 行结构、公开 API 签名、安全策略、探测策略、fallback **全部不同**。

**结论：当前不建议抽公共 `RsLruCache` 基类。**
- 净去重仅约 54 行，对 197 文件工程是噪音级收益，且引入 metatable 继承 + 子类 override 增加阅读复杂度（YAGNI）。
- 行为冻结风险高：LRU eviction/compact 顺序在生产环境运行，抽基类要求逐字节不变，但当前无专门测 cache 行为的 Harness。
- 触发重评估条件：出现第 3 个 metadata 服务且其 cache 框架同构 / 二者 cache 框架出现 bug / 需统一调优 cacheMax。

完整评估见 `../Archive/Evaluations/METADATA_CACHE_EVALUATION_20260902.md`（原 `Architecture/METADATA_CACHE_EVALUATION.md`，2026-09-03 归档）。

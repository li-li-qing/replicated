# Replicated Suite Persistence 架构（统一权威）

> **Authority Level**: ARCHITECTURE
> **范围**: 持久化框架——五种 Lifetime、Store Contract、Write Fence、Dirty+Debounce、Factory Reset、Diagnostics 联动。
> 本文由 `Architecture/Core/REPLICATED_SUITE_PERSISTENCE_FRAMEWORK_v1_20260826.md` 提升为独立权威文档，内容完整保留。

# Replicated Suite Persistence Framework v1

日期：2026-08-26  
状态：**基础框架已落地；`.18.81` Persistence Reliability v2 Foundation 已启用，RU 跨进程回读仍待 Fresh Reload 验收**

当前本地回归已补齐 empty/N-1/future schema/metadata mismatch/显式空表/cyclic payload 六类边界，共 `12/12`；RU SaveData 真实序列化、账号/角色作用域回读仍需客户端数据验证。

## 当前 UI Setting Binding 边界（M1.14.4–M1.14.5）

- Persistence Store 是“能否写、何时写、是否 dirty”的唯一 Authority；UI Binding 不得绕过 Store write fence。
- `CreatePersistentSettingBinding` 在调用 Domain setter 前执行 `PrepareWrite()`：Store 冷态先 Load+Apply，再检查 write fence；Domain mutation 成功后只 `MarkDirty`，默认延迟合并保存，不在输入热路径直接 `SaveData`。
- `Commit` 只通过 `Persistence:SaveStore`；MarkDirty 失败时 Binding best-effort 回滚 Domain 值与自身 revision/dirty 投影。
- 业务 Feature 的兼容公共 setter 可以继续提供“立即保存”语义，但 RSUI Settings Page 应优先使用 Domain-only setter + Persistent Binding，避免一套设置出现双重 Save Authority。
- M1.14.5 已把该边界扩展到系统“悬浮组件”与全局设置：WidgetHost/FloatingSurface 允许 `persist=false` 只应用 Domain/Presentation 状态，绑定层随后统一 `MarkDirty`；主窗口尺寸、UI 缩放/字体缩放、活动 Widget 行数/尺寸、Activity/Gear Widget 外观成为首批更广泛消费者。
- **绑定字段与一次性命令严格区分**：连续输入型字段（Numeric/Toggle/Appearance）不得在 setter 内再次 Save；“恢复默认布局/主窗口居中/重置全部位置”等一次性事务命令可以由自身 Domain Transaction 显式持久化，但必须检查失败并通过 ActionRunner/Diagnostics 暴露，不要伪装成 Setting Binding。
- **M1.15.2H raw API 边界**：业务 Store 不再直接 `S.Api:LoadData/ClearData` 或修改 `store.loaded/dirty/loadStatus`。旧插件迁移桥已退出 Active Runtime；物理清理统一走 `Persistence:ClearStore()`，写入前用 `PrepareWrite()/CanWrite()`，缓存读取只查询 `IsStoreLoaded()`。Persistence 是这些存储机械状态的唯一 Authority。
- `FeatureRuntime:SetPreferredEnabled()` 同样属于持久化事务：生命周期切换前先 `CanWrite(v3.features)`；MarkDirty 失败时恢复显式 preference，并把 Feature lifecycle 回滚到原状态，禁止“本次看起来启用成功、Reload 后又消失”。

---

## 0. `.18.80` Persistence Reliability Contract v1（当前生产约束）

用户实测暴露的最高风险不是“少保存一次”，而是**未读取旧 Store 就写、Feature teardown 后再 Flush、dirty Working 被 Reload 覆盖、SaveData 临时失败后修改被遗忘、损坏 payload 被误判为空存档**。这些路径都会表现为“当下设置正常，下一次进游戏/重载后全部丢失”。`.18.80` 将以下规则提升为 Foundation 强制契约：

1. **Load-before-Write**：Persistent Store `loaded ~= true` 时，`CanWrite / MarkDirty / 普通 SaveStore` 均 fail-closed。通用 UI Binding 必须在 Domain mutation **之前**调用 `PrepareWrite()`，由 Persistence 完成 Load + Apply，再允许修改。
2. **Dirty Reload Fence**：Store 仍有未落盘修改时，普通 `LoadStore()` 被拒绝；只有明确声明 `discardDirty=true` 的恢复/诊断路径才允许丢弃 Working。
3. **Durability before Teardown**：`Runtime:Stop()` 必须先 `Persistence:Flush()`，再 `FeatureRuntime:DisableAll()`；禁止 Feature 释放/重置 Domain 后又用 Store getter 把 teardown/default 状态写回磁盘。
4. **Explicit Reload Barrier**：`ReloadCodeFromDisk()` 在触发原生 UI reload 前必须 Flush 全部 dirty Store；任一失败直接取消用户主动重载并显示原因。
5. **Retry on SaveData Failure**：dirty Store 保存失败后继续保持 dirty，并设置 2–30s 有界 retry cadence；不得把失败写视为已消费。
6. **Corrupt ≠ Empty**：SaveData 返回非空但类型/结构不可解码时进入 Store write fence；绝不套 default 再覆盖旧 key。
7. **True Debounce + Max Delay**：连续 Slider/拖动以最后一次修改重新计算 dueAt，但由 `maxDebounceMs` 限制最长延期，避免长时间交互无限不落盘。
8. **Binding rollback**：Persistent Setting Binding 在 mutation 后 `MarkDirty` 被拒绝时，best-effort 恢复旧 Domain value 与 binding revision；不能让 UI 报告“已改成功”但 Reload 必然回退。
9. **Full-replacement Exception**：DeathReview Record Slot / Gear Payload 这类“完整独立分片替换”可显式使用 `allowUnloadedWrite=true`，但普通设置/index Store 禁止使用该逃生口。

该段是 `.18.80` Reliability v1 的历史边界说明；其所列 v2 工作已在下方 `.18.81` 开始收口：审计业务 public mutation，消除“先改 Domain、后裸 MarkDirty、失败无 rollback”的高风险路径，并统一为 `PrepareWrite → mutate → MarkDirty/Save → rollback`。仍未迁移的历史调用者继续按 fail-closed 处理，因此不能把 v2 Foundation 误写成“所有业务保存问题已经完成 RU 实机验证”。

### 本地故障注入证据

开发 harness 当前覆盖：未加载写入拒绝、Persistent Binding 自动 Load、dirty reload 拒绝、SaveData 一次失败后保留 dirty+retry、非表非空 payload 损坏保护、允许的完整分片替换。结果：

```text
PERSISTENCE_RELIABILITY_HARNESS PASS
```

RU 客户端 `SaveData / LoadData` 的真实账号/角色作用域、退出游戏时机与跨进程回读仍必须通过 Fresh Reload/重新登录验证。

---


## 0.1 `.18.81` Persistence Reliability Contract v2（当前生产约束）

`.18.80` RU 实机出现 `persistence_v2[encoded=1/fenced=1] → FlushFail=1`。真实根因不是业务配置天然过大，而是旧实现先用业务 Domain budget 验证 Domain，随后又拿**同一个 budget**验证 `{ payload = Domain, __rsmeta = ... }`。当 Domain 已接近合法 `maxDepth/maxNodes/stringBytes` 时，Persistence 自己追加的 wrapper/metadata 会把合法数据挤出预算并永久写保护。`.18.81` 将此类机械错误从业务 Store 中移除：

1. **Domain Budget ≠ Encoded Envelope Budget**：`store.budget` 只约束业务 Domain；`store.encodedBudget` 在 Domain budget 上增加固定、有界的 framework overhead。自定义 `encodedBudget` 也不得小于 Domain budget。
2. **Registration Envelope Preflight**：Store 注册时同时验证 default Domain 与编码后的 default envelope；预算配置错误在 Boot Gate 即可见，不再等用户第一次保存才触发 Fence。
3. **Atomic `MutateStore()`**：公共业务 mutation 优先走 `PrepareWrite → snapshot Domain + dirty metadata → mutate → MarkDirty/SaveStore → rollback on any failure`。durable command 只有 SaveData 明确成功才提交。
4. **Rollback Fence**：普通 mutation/commit 失败只恢复 Working；只有 rollback 本身失败才设置 `mutation_rollback_failed` Write Fence，避免一次临时 SaveData 故障把 Store 永久锁死。
5. **Incident ≠ Structural Blocker**：历史 `payloadRejected/encodedPayloadRejected` 计数保留在 diagnostics warning；当前 Store `fenced=0`、预算/metadata/key contract 正常才是结构 blocker。这样已安全处理的历史拒绝不会让整个 session 永久红灯。
6. **TOC/UI 故障不污染 Persistence 判断**：`.18.81` 同轮修复 Composite Foundation 依赖顺序，避免页面 build failure 与保存故障同时出现后被误当成一个问题。

当前已迁移到 v2 transaction 的高风险路径包括：Buff Display tracking/classification/components/full import/HUD Apply、Healer scalar/rules/tracked/presentation/raid layout、DPS scalar/Boss list、Combat Analytics selectors/metric enable、Raid Readiness setting、Tasks tracking/scope/widget、Activities rows/size/visibility/hidden events、Gear Quick HUD 的关键持久化命令、Death Review 关键 index mutation、Life M16 通用 mutation 与 Business Bridge blacklist/craft context。`MarkDirty` 仍允许作为 **Persistent Binding/FloatingSurface 已完成 preflight + rollback 的 commit adapter**，不能仅凭源码出现 `MarkDirty` 判定为第二 Authority。

### Reliability v2 本地故障注入

```text
PERSISTENCE_RELIABILITY_V2_HARNESS PASS
```

覆盖：合法 Domain 达到业务深度边界时 framework envelope 仍可保存；cold Store mutation 会先 LoadData/Apply；durable SaveData 注入失败后 Domain 与 dirty metadata 恢复；mutation callback 主动拒绝也不会留下半状态。

> RU 客户端的真实 `SaveData / LoadData` 生命周期、客户端退出时序、跨进程/跨重新登录回读仍必须以 Fresh Reload 作为最终证据。

---
## 1. 目的

Replicated Suite 已经是大型工程，不能继续让每个模块自己决定：

- SaveData key 怎么命名；
- 什么数据该永久保留；
- 什么数据每天/每周重置；
- 什么时候保存；
- Schema 怎么升级；
- 读取失败后是否还能继续写；
- ReloadAddon 时什么数据需要恢复。

Persistence Framework 只拥有**持久化机制 Authority**，业务 Domain 仍然拥有数据含义和业务重置规则。

```text
Domain State Authority
        │
        ├── get/apply/default/migrate
        ▼
Persistence Store
        │
        ├── Lifetime
        ├── ResetPolicy / PeriodId
        ├── Schema / Write Fence
        ├── Dirty / Debounce
        └── SaveData Key
```

---

## 2. 五种正式 Lifetime

### Permanent

长期保留：

- 设置；
- HUD 位置/大小；
- 人工名单；
- Gear 方案；
- DeathReview V3 的死亡历史：轻量 Account Index + 31 个固定循环 Record Slot；最多 30 条被索引引用，1 个备用槽用于“先写 Record、后提交 Index”的跨 Key 事务安全，禁止恢复为单个大聚合表；
- 自定义 Buff；
- 收藏；
- 用户长期规则。

### Daily

以**服务器日周期**为边界：

- 今日金币/荣誉/生活点/经验；
- 每日业务状态；
- 明确按服务器每日 Reset 的统计。

Daily Store 必须显式声明 ResetPolicy，不允许业务模块用本机 `os.date()` 自己判断。

### Weekly

以**服务器周 Reset**为边界：

- 周常；
- 周统计；
- 每周限制数据。

Weekly Store 必须明确：

- `weekday`：1=Sunday ... 7=Saturday（沿用当前 Suite `DayOfWeek` 约定）；
- `hour`；
- `minute`。

在 RU 服务器真实周 Reset 时间未核验前，**禁止为了方便编造一个默认周 Reset 时间并注册生产 Store**。

### Session

仅当前 Lua generation / 当前 Runtime 使用：

- Buff 扫描缓存；
- DPS 排序缓存；
- 当前 Target；
- 临时队列；
- Hover/UI transient state。

Session 永远不写 SaveData。

### Checkpoint

用于：

- ReloadAddon 短期恢复；
- 编辑中的未提交数据；
- 短期异常恢复。

Checkpoint 不是 Permanent。当前 Framework 已预留 Lifetime，但**自动 TTL/过期算法尚未启用**，因为跨重启可靠的服务器绝对时间策略还需要单独验证。没有明确 Expiry Policy 前不得滥用 Checkpoint 存长期数据。

---

## 3. ResetPolicy / PeriodId

Framework 当前支持：

### Daily `server_date`

```lua
resetPolicy = { kind = "server_date" }
```

PeriodId：

```text
2026-08-26
```

当前资源“今日收益”使用该策略，行为与原来的 `ServerDateKey()` 保持一致。

### Daily `server_reset`

```lua
resetPolicy = {
    kind = "server_reset",
    hour = 6,
    minute = 0,
}
```

在 Reset 时刻之前，仍属于前一个 Period。

### Weekly `server_weekly`

```lua
resetPolicy = {
    kind = "server_weekly",
    weekday = 2,
    hour = 6,
    minute = 0,
}
```

`weekday/hour/minute` 必须来自已验证的服务器规则。

Framework 的日期计算只在低频 period check 中执行，不进入战斗/BUFF/API hot loop。

---

## 4. Store Contract

正式 Store 注册形式：

```lua
Persistence:RegisterStore({
    id = "domain.store_name",
    owner = "DomainName",
    lifetime = Persistence.Lifetime.Permanent,
    schemaVersion = 1,
    key = "replicated_suite_...",

    default = function()
        return {}
    end,

    get = function()
        return Domain:BuildSaveSnapshot()
    end,

    apply = function(value, reason)
        Domain:ApplySaved(value, reason)
    end,

    migrate = function(value, fromVersion, toVersion)
        return value
    end,
})
```

规则：

1. Persistence 不直接理解业务字段；
2. Domain 不直接管理通用 SaveData 生命周期；
3. `get()` 必须提供可序列化快照；
4. `apply()` 必须只应用该 Domain 拥有的数据；
5. Daily/Weekly 必须有 ResetPolicy；
6. Session 不允许 SaveData key。

---

## 5. Schema 与 Write Fence

每个独立 Store 保存 `__rsmeta`：

```lua
__rsmeta = {
    framework = 1,
    store = "suite.daily_counters",
    owner = "Resource",
    lifetime = "Daily",
    schema = 1,
    periodId = "2026-08-26",
}
```

### 以下情况必须 Store 级写保护

- `LoadData` 明确报错；
- Decode 失败；
- 存档 Schema 高于当前代码；
- Migration 失败；
- Apply 失败。

原则：

> **读不明白的数据绝不覆盖。**

主 Suite Payload 正常不代表某个 dedicated Store 一定正常；写保护必须细到 Store。

---

## 6. Dirty + Debounce

Framework 提供：

```lua
Persistence:MarkDirty(storeId, delayMs)
Persistence:Tick()
Persistence:Flush(owner)
```

未来连续 UI 编辑、设置输入等统一使用：

```text
Change
  ↓
MarkDirty
  ↓
Debounce
  ↓
SaveStore
```

Persistence 不新建 OnUpdate。`Persistence:Tick()` 已接入现有 `Storage` Scheduler lane，因此不会为了保存系统再增加一套 Runtime。

显式 Reload 会在触发原生界面重载前要求 `Flush()` 全成功；Runtime Stop 在任何 Feature teardown 前先执行 durability barrier。保存失败的 dirty Store 保留并进入有界重试。

---

## 7. Factory Reset

`Storage:BuildFactoryResetKeys()` 已改为读取：

```lua
Persistence:GetPersistentKeys()
```

以后新的 Suite Store 注册后会自动进入“恢复出厂设置”清理范围，不再要求每加一个 SaveData key 就手改硬编码列表。

专业模块 DPS / Gear / Plates / Healer 目前仍保留自己的 Persistence Authority，出厂重置继续按各自已验证逻辑处理，不能强行并入 Suite Store。

---

## 8. Diagnostics 联动

Diagnostics Snapshot 现在包含：

- Store 数；
- Dirty 数；
- Write Fenced 数；
- Load/Save Failure；
- Migration 次数；
- Period Reset 次数；
- 每个 Store 的 Lifetime / Schema / Period / LoadStatus / Error。

关键错误使用稳定 Code：

```text
STORE_REGISTER_INVALID
STORE_DUPLICATE
STORE_LOAD_FAILED
STORE_FUTURE_SCHEMA
STORE_DECODE_FAILED
STORE_MIGRATION_MISSING
STORE_MIGRATION_FAILED
STORE_APPLY_FAILED
STORE_GET_FAILED
STORE_ENCODE_FAILED
STORE_SAVE_FAILED
STORE_PERIOD_RESET
```

以后存储问题必须先查这些 Code，而不是继续增加零散聊天打印。

---

## 9. 本轮已迁移 Store

### `suite.daily_counters`

物理 key 保持：

```text
<SaveKey>_daily
```

Lifetime：`Daily`  
Owner：`Resource`  
ResetPolicy：`server_date`  
Schema：1

为了零行为变化：

- 当前 Resource Domain 仍拥有最终跨日清零动作；
- Framework 提供统一 PeriodId；
- `autoReset=false`；
- 等 Resource 的 reload/冷启动路径完全验证后，再考虑让 Framework 自动 reset。

旧格式：

```lua
{ dailyCounters = ... }
```

继续可读；新格式只额外加入 `__rsmeta`，旧版本仍可读取 `dailyCounters`。

### `suite.favorites`

物理 key 保持：

```text
<SaveKey>_favorites
```

Lifetime：`Permanent`  
Owner：`Trade`  
Schema：1

旧 `tradeFavorites / auctionFavorites` 字段保持原样，只增加 `__rsmeta`。

---

## 10. 当前明确不做的事情

本轮**没有**：

- 改主 Suite Schema 21 的字段结构；
- 把所有 life/settings 一次拆成几十个 key；
- 改 DPS/Gear/Plates/Healer 自己的可靠存储协议；
- 编造 RU Weekly Reset 时间；
- 自动把所有 Daily/Weekly 数据清零；
- 给 Checkpoint 编造不可靠 TTL。

原因：Persistence 是高风险基础设施，应先建立 Contract 和兼容层，再逐 Domain 迁移。

---

## 11. 下一批迁移建议

优先级：

1. 将明确的 Daily/Weekly 业务状态登记 Store/Lifetime 清单；
2. 核验 RU 服务器每日/每周真实 Reset Policy；
3. 将 UI Layout / 用户设置定义为 Permanent Store 规划，但暂不拆主 Payload；
4. 建立 Checkpoint 的可靠 server-time expiry 方案；
5. 等存储框架稳定后，再进入 RSUI / Diff Rendering 大规模迁移。

---

## 12. 新功能开发前的 Persistence Checklist

每个新数据必须回答：

- 谁是 Domain Authority？
- Lifetime 是 Permanent / Daily / Weekly / Session / Checkpoint 哪一种？
- 是否真的需要写磁盘？
- Daily/Weekly 的服务器 ResetPolicy 是什么，是否已验证？
- SchemaVersion 是多少？
- Migration 失败时怎么保护旧数据？
- 连续变化是否使用 Dirty + Debounce？
- Factory Reset 是否能自动找到这个 key？
- Diagnostics 是否能看到它的 Store 状态？

任何一项没有答案，都不应该直接新增裸 `ADDON:SaveData()`。


---

## Healer Settings Store 扩展（2026-08-26）

Healer 设置已作为 `Permanent` Store 接入：

```text
Store Id: healer.settings
Key: replicated_healer_recommender_v2
```

由于 ArcheRage RU 历史 Healer 配置依赖 backup-first + clear-before-replace 安全策略，Framework 增加可选 `save` writer hook。该 hook 只用于保留特殊 Durable Contract；普通 Store 仍应使用默认 `S.Api:SaveData`。

Healer 普通设置修改现在走 `MarkDirty + 750ms coalescing`，显式 Suite 收尾保存走 Force Flush。Boot-time 历史 migration 已迁入独立 `SettingsBootstrap + SettingsMigrations + SettingsModel`：Bootstrap 只读，Store 注册成功后才持久化迁移快照，并在最后应用 Suite session-only `enabled=false`。详见 `REPLICATED_HEALER_GLUE_PERSISTENCE_v1_20260826.md` 与 `REPLICATED_HEALER_SETTINGS_ARCHITECTURE_v1_20260826.md`。

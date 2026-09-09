# Replicated Suite Persistence 架构（统一权威）

> **Authority Level**: ARCHITECTURE
> **范围**: 持久化框架——五种 Lifetime、Store Contract、Write Fence、Dirty+Debounce、Factory Reset、Diagnostics 联动。
> 本文由 `Architecture/Core/REPLICATED_SUITE_PERSISTENCE_FRAMEWORK_v1_20260826.md` 提升为独立权威文档，内容完整保留。

# Replicated Suite Persistence Framework v1

日期：2026-08-26  
状态：**基础框架已落地；2026-09-06 起为 Persistence Reliability v8 + Integrity v4 Canonical Fingerprint（v3 内容盲世代与 v2/v1 均为受识别旧世代，走封印+全量业务校验的一次代受控升级；见 §0.11/§0.12），保留 v7 Generation Reload Fence、v6 Envelope Seal/Decoded Budget/True Durable/Scope Binding 与 Gear A/B verified self-heal；RU 跨进程回读仍需客户端验收**

当前本地回归已补齐 empty/N-1/future schema/metadata mismatch/显式空表/cyclic payload 六类边界，共 `12/12`；RU SaveData 真实序列化、账号/角色作用域回读仍需客户端数据验证。

## Startup-critical Store Session Fallback（.18.107）

`v3.app`、`v3.shell`、`v3.launcher` 属于“进入主界面所需的展示/基础状态”，其物理 Store 不得成为主界面的单点故障。LoadStore 若因完整性、解码、迁移、作用域或底层读取失败而返回失败，Domain 在**本次会话**使用 Normalize(default) 继续运行，并记录 `sessionFallback/lastLoadError`。Persistence Authority 原有 `writeFenced/writeFenceReason` 继续保护失败 Store；降级逻辑不得清除 fence，也不得主动 MarkDirty 默认值；`.18.113` 起 session fallback 内的 App mutation / Shell route+geometry / Launcher placement mutation 全部 memory-only，避免“为了能打开 UI 而覆盖最后一份可恢复存档”以及反复 `WRITE_BEFORE_LOAD_REJECTED`。

Feature 业务 Store 不统一自动降级：其失败应隔离对应 Feature，而不是伪造业务数据。

## Canonical / Schema 演进强制规则（`.18.188` 起）

持久化 Store 的 `migrate/encode` 输出不是普通实现细节，而是 **Integrity Authority 的一部分**。因此从 `.18.188` 起执行以下长期规则：

1. **Canonical 形状或字段语义发生变化必须升 schema**：新增/删除可持久化字段、默认值语义改变、布尔/数值 sentinel 改变、窗口坐标表示改变，都不能继续沿用原 schema。仅新增最终恒为 `nil` 且不进入 table 的临时计算不算 canonical 变化。
2. **旧 canonical 必须冻结为只读 historical normalizer/codec**：升级时不得用当前 normalizer 猜旧 Hash。需要兼容时只能通过 `rebuildCanonicalForIntegrity` 构造确定性历史候选，并由 Core 用原 stamped fingerprint 精确认证。
3. **未知 fingerprint 继续 fail-closed**：禁止为了升级方便清 Store、关闭 Integrity、`pcall` 后无条件吞错，或把任意 mismatch 当作 serializer drift。若连续多轮 RU 实机证明同一旧 stamp 是固定迁移身份，可按 Death Review / Shell 的模式增加 Store-owned `recoverKnownLegacyCanonical`，但必须 exact allowlist + legacy shape/metadata validation + current canonical recheck + immediate restamp。
4. **Schema 迁移必须有 Gate + Acceptance + 回归 Harness**：任何 canonical schema bump 都要在 Foundation/Acceptance 钉死版本与恢复 hook，并至少有一个真实 Lua 行为用例覆盖 `旧 envelope → Load → migration → unfenced Apply`。仅搜索源码 token 不能作为完整回归证据。
5. **Presentation-only Store 也遵守同一规则**：`v3.shell` 虽然只保存窗口位置/尺寸/route，不得因为“不是业务数据”而在同一 schema 内随 UI 重构任意改变 canonical。Startup session fallback 只是可用性保护，不是 schema 纪律的替代品。

该规则直接来自 `.18.157 → .18.184/.18.187` 的 `v3.shell` 事故以及 Death Review `.18.146-.18.151` 的历史恢复链，目的是让后续版本升级不再靠用户重置配置解决。


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

## 0. `.18.80` Persistence Reliability Contract v1（历史基础，规则仍有效）

用户实测暴露的最高风险不是“少保存一次”，而是**未读取旧 Store 就写、Feature teardown 后再 Flush、dirty Working 被 Reload 覆盖、SaveData 临时失败后修改被遗忘、损坏 payload 被误判为空存档**。这些路径都会表现为“当下设置正常，下一次进游戏/重载后全部丢失”。`.18.80` 将以下规则提升为 Foundation 强制契约：

1. **Load-before-Write**：Persistent Store `loaded ~= true` 时，`CanWrite / MarkDirty / 普通 SaveStore` 均 fail-closed。通用 UI Binding 必须在 Domain mutation **之前**调用 `PrepareWrite()`，由 Persistence 完成 Load + Apply，再允许修改。
2. **Dirty Reload Fence**：Store 仍有未落盘修改时，普通 `LoadStore()` 被拒绝；只有明确声明 `discardDirty=true` 的恢复/诊断路径才允许丢弃 Working。
3. **Durability before Teardown**：`Runtime:Stop()` 必须先 `Persistence:Flush()`，再 `FeatureRuntime:DisableAll()`；禁止 Feature 释放/重置 Domain 后又用 Store getter 把 teardown/default 状态写回磁盘。
4. **Explicit Reload Recovery Barrier**：`ReloadCodeFromDisk()` 在触发原生 UI reload 前先执行一次 best-effort Flush。成功时正常进入 reload；失败时必须保留 exact Store ID/原因并明确提示未保存修改可能丢失，但**恢复/开发重载仍继续**，避免“Persistence 故障阻断加载修复文件”的恢复死锁。只有显式 `requireDurable=true` 的调用方才允许把 Flush 失败作为重载硬门禁。
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


## 0.1 `.18.81` Persistence Reliability Contract v2（v3 的基础层，历史仍有效）

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

## 0.2 `.18.83` Runtime Acceptance Diagnostics（不新增持久化 Authority）

`.18.83` 不改变 SaveData 格式、Store schema 或业务 mutation 语义，只补齐 RU Fresh Reload 验收所需的**可复制故障证据**：

1. `Persistence:Flush()` 每次结束后保存最近一次 runtime-only `lastFlush = { at, ok, owner, failures }`；`failures` 内容直接沿用 `store id:reason`，不持久化、不驱动写策略。
2. `Persistence:Describe()` 暴露 `RuntimeAcceptanceDiagnosticsContractVersion=1` 与 `lastFlush`，Foundation/Diagnostics 只读消费。Store `loaded/dirty/writeFenced` 仍是唯一机械状态 Authority。
3. Foundation Gate 一键摘要在 Flush/Fence 异常时附带最多 3 条 `store id:reason`；Recent Fault 同时保留 `context.store` 与 bounded `context.failures`，避免只看到 `FlushFail=1` 却不知道是哪一个 Store。
4. Diagnostics 页面显示“最近存档落盘”具体失败项；用户点击“重新加载文件”时**不再由页面预先 Flush**，只调用 `ReloadCodeFromDisk()`。后者继续负责唯一一次 Flush Authority；恢复重载在 Flush 失败时保留故障证据并继续加载磁盘新文件，严格耐久调用方可显式 `requireDurable=true` 取消重载。
5. 该诊断快照不是重试队列、不是历史账本、不是第二份 Store 状态；下一次 Flush 会覆盖上一条 evidence，避免无界增长。

本轮仍不能代替 RU 真机；该 Runtime Acceptance 现已由 `.18.95` Reliability v3 继续承接，只有 Fresh Reload/退出重进后的 `SaveData → LoadData` 回读一致才能关闭。


## 0.3 `.18.84` Fresh Reload Domain Fingerprint（只读验收证据）

`.18.84` 继续服务于同一个 RU Runtime Acceptance Gate，不修改 SaveData key、Store schema、编码 envelope 或业务 mutation。新增能力只用于回答一个问题：**Fresh Reload 前 Working/待落盘的 Domain 内容，与新进程 LoadData 回读后的 Domain 内容是否完全一致**。

1. `Persistence:FingerprintPayload(value, budget)` 先复用 Store 的 SaveData Domain budget 做结构检查，再按类型、长度与稳定 key 顺序计算有界指纹；table 的插入/遍历顺序不会改变结果，字段/值变化会改变结果。
2. `Persistence:BuildRuntimeAcceptanceSnapshot(options)` 只查看已注册 Store；默认不会自动 `LoadStore()`、不会 `Flush()`、不会 `SaveStore()`。未加载 Store 返回 `store_not_loaded`，禁止拿 default/冷态 Domain 冒充磁盘回读。
3. 指纹输入是 Store `get()` 的 **Domain save snapshot**，明确排除 `{payload,__rsmeta}` 编码 envelope；因此 framework/schema metadata、运行时 timestamp 不会制造 Fresh Reload 假差异。
4. Snapshot 同时给出 `loaded/dirty/fence/schema/dirtyRevision/lastSavedRevision`。`Dirty=1` 可以作为“连续拖动后立即重载”测试的合法前置状态；重载成功后应回到 `Dirty=0/Fence=0` 且 Domain 指纹一致。
5. Presentation 的“输出存档验收”只维护当前验收计划里的稳定 Store ID 列表；Persistence Core 不硬编码 Buff/Healer/Gear/Trade 等业务 ID。已注册的 `v3.gear.payload.*` 通过 prefix 动态纳入总指纹，详细输出有界，避免 40 套方案造成无界 Chat 文本。
6. 本节的 `FingerprintPayload()` 仍不是密码学完整性机制、不是 revision Authority，也不作为人工验收之外的持久化事实；`.18.97` 另行使用 `FingerprintEncodedPayload()` 生成 `__rsmeta.encodedFingerprint` 作为机械 cross-reload integrity stamp，两者职责不可混用。

`PERSISTENCE_ACCEPTANCE_SNAPSHOT_HARNESS PASS 14/14` 已验证：顺序无关稳定性、字段变化敏感性、cyclic payload fail-closed、exact missing、prefix coverage、未加载 Store 不伪造指纹。RU 客户端最终结论仍必须由 Fresh Reload/完整退出重进产生。

---

## 0.4 `.18.95` Persistence Reliability Contract v3 + Critical Journal

`.18.95` 来自新的 RU 实机证据：**Gear 方案名称能跨 Reload 保留，但内部装备 Payload 在 Reload 后不可用**。这说明“某个轻量 Store 保存成功”不能证明与它配对的独立 shard 同样可靠。Gear 的真实结构本来就是 Index 与 Payload 分离，因此底层必须把 `SaveData` 的“调用成功”和“数据确实可回读”区分开。

Reliability v3 新增以下约束：

1. **Critical Store 可 opt-in readback verification**：Store 声明 `verifyAfterSave=true`，或单次 `SaveValue/SaveStore` 明确传入该选项后，`SaveData=true` 只代表写调用已接受；Persistence 必须立刻用同一 resolved key `LoadData`，再检查 `__rsmeta` 的 store/owner/lifetime/scope/schema/contractVersion，并对解码后的 Domain snapshot 与预期值计算同一稳定 fingerprint。
2. **Verify 是 decode-only**：`VerifyPersistedValue()` 不调用 `store.apply()`，不修改业务 Working，不成为第二 Domain Authority。它只回答“刚刚写入的值是否能按当前契约完整读回”。
3. **Verify 失败不提交成功状态**：`readback_missing / metadata mismatch / decode failure / fingerprint mismatch` 都变为 `readback_verify_failed:*`；不会推进 `lastSavedRevision`、不会清除 dirty，也不会增加成功 save 计数。dirty Store 保留 bounded retry；显式 transaction 由调用者收到失败并执行自身 rollback/保留旧 journal。
4. **普通 Store 默认不验证**：`verifyAfterSave=false` 仍是默认值，避免所有 Slider、窗口外观和 debounce 设置每次保存再发一次 LoadData。只有会造成高价值数据不可恢复、且用户动作本身低频的 Critical Store 承担额外一次 read I/O。
5. **Gear Index + Payload 都是 Critical**：Index schema 5 自身启用 readback verification；每个 Payload 从历史单 key 升为 A/B bank。写方案时只覆盖 inactive bank，且只有该 bank SaveData + readback fingerprint 全通过后，才把 Index 的 `payloadBank/payloadFingerprint` 指向它；上一 active bank 以 `backupPayloadBank/backupPayloadFingerprint` 保留。Index commit 失败时新 bank 只是 orphan，不允许为了“rollback”再覆盖旧 bank。
6. **Compact Payload schema 2**：19 槽固定 slot metadata 不再在每个 item 重复序列化；on-disk 仅保存动态身份字段，降低 RU SaveData 节点/字符串压力。历史 `gear_payload_N` schema 1 仍是只读兼容源，读取正常时下一次用户保存自然转入 A/B。
7. **Reload 结构完整性**：configured Gear Payload 必须至少包含一个有效 managed item 或可应用称号；managed item 必须有 slot + name；apply-title 必须有 effect id。残缺 shard fail-closed，并尝试上一个 verified bank。历史单 bank 已经丢失的数据无法凭名称恢复，只能由用户显式“获取当前 → 保存方案”重建。
8. **不新增 Tick**：readback 只发生在显式 Critical Save 边界；A/B fallback 只发生在方案读取；无新增轮询、Scheduler 或 Native 高频扫描。

本地新增故障注入：

```text
PERSISTENCE_RELIABILITY_V3_HARNESS PASS 22/22
```

它可以证明 framework 能识别“SaveData 返回 true，但刚写入 payload 被静默裁掉字段”的模拟故障；**不能替代 RU 客户端是否同步回读、真实磁盘生命周期与跨进程保存语义**。因此当前 NEXT 仍是 Fresh Reload。

---

## 0.5 `.18.97` Persistence Reliability Contract v4 — Cross-Reload Encoded Integrity + Journal Repair

继续审计 v3 后确认还存在四个底层缺口：immediate readback 不能证明**下一次进程**读到的仍是完整表；Load 边界没有先验证 encoded envelope budget；`IsStoreLoaded()` 把“LoadData 已终止但 decode/meta/future-schema 失败”也暴露成 ready；Gear A/B 在 active 损坏后虽可回退 backup，但损坏 inactive bank 的 read fence 会让下一次保存无法覆盖它，从而 journal 不能自愈。v4 将这些机械语义统一收进 Persistence，而不是让 Gear/UI 各自补丁。

1. **Persisted Reliability Marker**：所有 v4 新写入的 `__rsmeta` 带 `reliabilityContract=4`、`integrityVersion=1`、`encodedFingerprint`。pre-v4 未带 marker 的既有 Store 继续读取，避免升级清配置；它们下一次正常 save 自动进入 v4。
2. **Fingerprint 编码业务 envelope，而不是当前 decoder 产物**：先完成 Store custom/default encode，再对顶层排除 `__rsmeta` 的业务字段做稳定 fingerprint。这样 SaveData 若在后续 Reload/重启后丢失 `it/ti/payload` 内部字段，Load 可以在 decode 前识别；同时未来合法 decoder normalize/schema migration 改动不会让旧完整数据误触 integrity failure。
3. **Load Preflight 顺序**：`LoadData → raw type → encodedBudget Inspect → metadata/future contract → encoded integrity → decode → migrate/reset → apply`。`encoded_load_rejected` / `integrity_failed` 均 fail-closed + write-fence，绝不先 Apply 空/残缺 Domain 再继续保存。
4. **Critical immediate verify 继续保留**：v4 没有删除 v3。Critical Store 保存时仍 `SaveData → immediate LoadData`；先核对 v4 metadata + encoded fingerprint，再 decode，并用 Domain fingerprint 对比本次预期值。它仍然不调用 `apply()`，所以 Persistence 只拥有 durability mechanism，不夺取 Gear Domain Authority。
5. **Healthy `IsStoreLoaded()`**：内部 `store.loaded` 仍可表示一次读取已到 terminal state，但公开 `IsStoreLoaded()` 只有 `loaded/empty/saved/session` 返回 true。`decode_failed / metadata_mismatch / integrity_failed / future_schema / apply_failed` 不再允许 Feature 复用默认/空 cache。
6. **Verified Replacement 只用于可恢复 Journal shard**：Store 必须注册 `recoverableReplacement=true`，调用者必须显式 `replaceCorrupt=true + verifyAfterSave=true`，且现有 fence 原因只能是已确认的 `decode_failed / metadata_mismatch / integrity_failed / encoded_load_rejected`。`future_schema`、`load_failed`、save-side budget fence 等都不能走覆盖逃生口。只有新完整 shard readback 验证通过才清 fence。
7. **Gear A/B 自愈链**：若 Index active bank integrity 失败，`LoadPayloadForSet()` 先用 Index 保存的 backup bank/fingerprint 继续工作；下一次显式保存选择相反 bank（即损坏 inactive bank），Persistence 允许上述 verified full replacement，成功后才提交 Index 新 active/backup pointer。用户无需先 ClearStore，也不会因为 recovery 覆盖最后一份 verified backup。
8. **性能边界**：普通 Store 仍只有一次 SaveData；v4 增加的是 save/load 边界上的 bounded fingerprint walk，不增加 LoadData。只有 Critical Gear 继续承担原有一次 immediate readback。所有逻辑都不进入 Feature Tick/Native 扫描循环。

本地故障注入：

```text
PERSISTENCE_RELIABILITY_V3_HARNESS PASS 22/22
PERSISTENCE_RELIABILITY_V4_HARNESS PASS 35/35
PERSISTENCE_ACCEPTANCE_SNAPSHOT_HARNESS PASS 19/19
```

v4 本地可模拟“保存时完整、下一进程字段被裁掉”、malformed encoded envelope、failed-load false-ready、旧 unstamped 兼容与 fenced journal verified replacement；**仍不能替代 RU 客户端真实 SaveData 生命周期**。`.18.98` 的 v5 durability barrier 在下一节继续收口“已经 clean 的普通 Store 如何在 Reload 前得到最终耐久证明”。

---

## 0.6 `.18.98` Persistence Reliability Contract v5 — Durability Barrier + Verified Clear

继续沿真实 `SaveStore → Flush → ReloadCodeFromDisk/Runtime:Stop` 调用链审计后发现，v4 仍不能覆盖“普通 Store 较早已经 SaveData=true 并变 clean，但物理内容被静默裁掉”的窗口：用户之后点 Reload 时，旧 Flush 只扫描 dirty Store，因此不会再读这个 key。v5 把 Flush 从“只把 dirty 写出去”提升为**显式 generation durability barrier**，但不把额外 I/O 放进输入热路径。

1. **普通 Store 延迟证明**：非 Critical Store SaveData 成功后保留 `needsBarrierVerify=true`。正常 debounce/Tick 不额外 LoadData；只有显式 `Flush()`（Reload/Stop）才验证。
2. **Flush 两阶段**：Phase 1 保存 dirty；Phase 2 对本 generation 所有 pending key 运行 `VerifyPersistedValue()`。验证包括 metadata、encoded fingerprint、decode 与 Domain fingerprint，但不 Apply。任一失败都使 Flush 返回 false，并保留 dirty/retry/故障 evidence；Recovery Reload 记录该失败后继续重新加载磁盘代码，只有显式 strict durability 调用才阻止 reload。
3. **Barrier Failure 可恢复而非永久 Fence**：readback mismatch 可能来自 RU 即时可见性差异，故不直接设置结构性 write fence；只保留 `needsBarrierVerify`，把当前健康 Domain requeue 为 dirty，5 秒后可再次写入/验证。下一次 barrier 未通过前仍禁止用户主动 Reload。
4. **Critical 不重复 I/O**：Gear Index/Payload 等 `verifyAfterSave=true` Store 成功 immediate readback 后 `needsBarrierVerify=false`；后续 Flush 不做第二次 LoadData。
5. **v4→v5 向前兼容**：Integrity 格式仍为 v1，`MinIntegrityReliabilityContractVersion=4`。v5 读取 v4/v5 stamped save；future contract `> current` 继续 fail-closed。encoded integrity 的执行顺序严格为 `raw/encodedBudget → metadata/future → integrity → decode → migrate → apply`。
6. **Verified Clear**：`ClearData=true` 之后先用同 key `LoadData` 验证 nil，只有通过才 Apply default。物理 key 仍存在或 read error 时进入 `clear_verify_failed`，保留现有 Domain，避免“本进程已重置、Reload 后旧配置复活”。
7. **统一 Ready 语义**：Core 的 CanWrite/PrepareWrite/SaveStore/MarkDirty/period reset/Describe/Acceptance Snapshot，以及 Persistent UI Binding 都使用健康 `IsStoreLoaded()`；`integrity_failed/decode_failed/future_schema/clear_verify_failed` 等 terminal state 不属于 ready。
8. **诊断**：新增 `barrierPending`、`barrierVerifyAttempts/Successes/Failures/Requeued`、`clearVerifyAttempts/Failures` 与每 Store `lastBarrierVerify*`。这些仅为 runtime evidence，不成为业务数据 Authority。
9. **性能边界**：普通保存仍是一次 SaveData；额外 LoadData 只发生在用户显式 Reload/Runtime Stop barrier。Critical Store仍只承担原有 immediate readback，不被 barrier 重复验证。无新增 Tick、Native 扫描或 Feature fan-out。

本地故障注入：

```text
PERSISTENCE_RELIABILITY_V3_HARNESS PASS 22/22
PERSISTENCE_RELIABILITY_V4_HARNESS PASS 35/35
PERSISTENCE_RELIABILITY_V5_HARNESS PASS 42/42
PERSISTENCE_ACCEPTANCE_SNAPSHOT_HARNESS PASS 19/19
```

v5 harness 已覆盖 v4 stamped 向前兼容、integrity-before-custom-decode、普通 Store 静默截断在 Flush 被检测并 requeue/恢复、Critical Store 不重复 barrier read、ClearData fake-success 不 Apply defaults。**最终 SaveData/LoadData 同步与跨进程事实仍只以 RU Fresh Reload/完整退出重进为准。**

---

## 0.7 `.18.99` Persistence Reliability Contract v6 — Envelope Seal + Decoded Budget + Durable Commit + Character Scope Binding

v6 不改变业务 Store Authority，也不把额外 I/O 放进 Tick；它继续收紧 Persistence Boundary：

1. **Envelope Seal**：v4/v5 `encodedFingerprint` 继续只覆盖 encoded business fields；v6 另写 `envelopeIntegrityVersion=1 + envelopeFingerprint`，封印 framework/store/owner/contract/lifetime/scope/schema/period/reliability/integrity/business fingerprint 与 Character identity fingerprint。v6-stamped load/readback 在业务 decoder 前验证 seal；metadata-only truncation 不再降级成 legacy schema。
2. **Decoded Domain Budget**：encoded budget 通过并不代表 custom decoder/migration 输出安全。decode 后与最终 migrate/reset 后各运行一次 Store Domain budget；越界/循环/unsupported shape 进入 `decoded_load_rejected`，不 Apply、不自动保存。
3. **True Durable Commit**：`MutateStore(...,{durable=true})` 必须走 `SaveData → immediate LoadData → envelope/business/decode/Domain fingerprint`；任一失败事务 rollback Domain，并保留 `needsBarrierVerify` 让 Reload/Stop 继续 fail-closed。
4. **Character Scope Binding**：Character Store v6 metadata 保存 exact `UnitNameWithWorld(player)` 的 bounded fingerprint。Runtime Store 同时记 `resolvedKey + resolvedScopeFingerprint`；public readiness/write 在角色变化时 fail-closed。Clean Store 可由 `PrepareWrite` 先 load 新角色后 rebind；旧 scope 若仍 dirty/barrier pending，必须先完成旧 key durability。Debounce/Flush 使用 bound old key，禁止把 A 的 Domain 写进 B。
5. **历史 key 兼容**：为避免升级后现有 Gear 数据失联，v6 不改 historical Character physical key 算法。若 exact identity 改变但历史 normalization 恰好落在同一 physical key，视为 identity collision，直接 `scope_binding_identity_collision` fence；绝不猜归属或覆盖。
6. **Journal 自愈**：`envelope_integrity_failed` 与 `decoded_load_rejected` 加入 recoverable inactive-shard fence 集；仍只有 `recoverableReplacement + replaceCorrupt + verifyAfterSave` 的完整 A/B replacement 才能修复，future schema/transient load error 禁止覆盖。
7. **性能边界**：普通 debounce 保存仍 `SaveData ×1`；额外 readback 只属于 explicit durable/Critical save 或 Flush durability barrier。Scope identity 查询只在 Character readiness/write/load 边界，不新增 Feature Tick 扫描。

本地故障注入新增：

```text
PERSISTENCE_RELIABILITY_V6_HARNESS PASS
```

覆盖 metadata-only truncation、decoded expansion、durable immediate verify/rollback、v5 stamped compatibility、Character A/B rebind 与 lossy-key collision fence。RU 客户端真实同步/跨进程持久性仍以 Fresh Reload/完整退出重进为最终 Authority。

---
## 0.8 `.18.100` Persistence Reliability Contract v7 — Generation Reload Fence + Deferred Dirty Commit

v7 不改变 v6 的 business/envelope integrity、Character scope 或 Gear A/B Authority；它封住的是**同一 generation 内“已经写过但还没有通过耐久屏障”的新 Domain 再次被旧磁盘值覆盖**，并清理失败 Store 的自动保存生命周期。

1. **Pending Durability Reload Fence**：Persistent Store `SaveData=true` 但没有 immediate verify 时保持 `needsBarrierVerify=true`。在显式 Flush barrier 成功前，普通 `LoadStore()` 必须返回 `unverified store reload rejected`，不得 Apply 物理值。只有明确 destructive recovery 才允许 `discardUnverified=true`；正常 Feature/UI 路径不得使用该逃生口。
2. **Barrier 仍是提交边界**：`Flush()` Phase 2 继续对 pending Store 执行 bounded readback + envelope/business/decode/Domain fingerprint；成功后清 `needsBarrierVerify`，随后普通 LoadStore 才重新合法。Critical/durable Store immediate verify 成功时仍不产生 pending obligation。
3. **Migration/Period Reset Dirty 延后提交**：Load 中的 schema migration 与 Daily/Weekly reset 可以改变 Working value，但不再提前设置 `store.dirty`。只有最终 decoded budget 通过且 `ApplyValue(..., "load")` 成功后，才提交 dirty revision/dueAt/reason。Apply 失败时 Store 可 terminal/write-fenced，但不会同时制造待自动保存状态。
4. **Terminal Tick Suppression**：Tick 只对 `IsStoreReady()==true && writeFenced~=true` 的 dirty Store执行既有 debounce SaveStore。terminal/fenced Store 保留 dirty evidence，`dueAt` 至少有界后移 5 秒并统计 `terminalAutoRetrySuppressions`；恢复必须走显式 Load/Revalidate/Clear，而不是周期性 Native Save hammer。
5. **诊断**：新增 `unverifiedReloadRejects / deferredLoadResaves / terminalAutoRetrySuppressions`。正常产品 Fresh Reload 路径要求 `unverifiedReloadRejects=0`；该值非零表示某个 Consumer 在 generation durability 尚未证明时主动 reload 了同一 Store，应修调用链而不是绕过 fence。
6. **性能边界**：v7 不新增 LoadData/SaveData 次数，也不增加 Tick/Scheduler。Reload fence 只是状态判断；Tick suppression 反而减少异常状态下的重复 Native 保存调用。

本地故障注入新增：

```text
PERSISTENCE_RELIABILITY_V7_HARNESS PASS
```

覆盖 pending ordinary save 的 reload 拒绝与 Domain 保持、Flush 后恢复正常 load、migration Apply failure 不遗留 dirty、write-fenced dirty Tick 不重复 Native Save，以及 Contract v7 描述。RU 客户端真实 durability 仍必须用 Fresh Reload/完整退出重进证明。

---

## 0.9 `.18.113` Persistence Reliability Contract v8 — Integrity v2 Serializer Recovery

1. **Integrity v1 根因**：旧 business fingerprint 用 `%.17g` 对 Lua number 做 exact token。RU SaveData/LoadData 对窗口坐标、透明度、缩放等非整数值发生表示归一化时，业务值仍处于同一可接受精度，但 exact hash 会变化，造成 `fingerprint_mismatch → write fence → Feature/Page build rollback` 的级联。
2. **Integrity v2 数值规则**：整数（绝对值 ≤ 2^53-1）继续 exact；非整数仅在 Persistence integrity 层使用 6 significant digit serializer-stable token。该规则不改变 Domain、Store Normalize、业务计算或 UI 几何精度。
3. **业务 fingerprint 不变**：`FingerprintPayload()` 保持 v1 exact number 语义，因为 Gear A/B journal index 使用它作为业务 payload identity。新增 `FingerprintDurablePayload()` 仅用于 Native serializer 跨边界的 encoded integrity/readback proof。
4. **历史 v1 compatibility**：只允许 `reliabilityContract>=6 + Envelope Seal 完整 + 非 verifyAfterSave + 非 recoverableReplacement` 的 ordinary Store 进入 compatibility。之后仍必须通过 encoded budget、metadata/schema、decode、Domain budget、migration/reset、final budget 与 apply；任何一步失败继续 fence。Critical/Journal mismatch 永远 fail-closed。
5. **升级写入时机**：健康/compatibility v1 ordinary Store 仅在 Apply 成功后排队 `integrity_v2_upgrade`，由正常 Persistence debounce/Tick 写成 v8/v2；不会在 decode 前盲目覆盖旧物理 Store。
6. **真实损坏仍可检测**：结构/类型/budget/metadata/envelope 破坏继续由既有 fence 检出；v2 对 item/skill id、revision、计数等整数值仍逐值 exact，因此真实整数业务字段变化不会被非整数 canonicalization 隐藏。
7. **Session fallback no-persist**：App/Shell/Launcher fallback 是纯会话安全状态。用户仍可导航/拖动/调整本会话 UI，但不向 failed/not-loaded Store 发送 MarkDirty/MutateStore。下一 generation 重新从物理 Store 按正常 Authority 尝试读取。
8. **Runtime Acceptance Snapshot v2**：Fresh Reload 的只读验收快照改用 `FingerprintDurablePayload()`，避免相同 Native 数值表示归一化再次污染人工跨重载对比；Gear/业务 exact fingerprint 不受影响。
9. **性能边界**：无 Tick 新扫描、无额外常驻 SaveData/LoadData。Fingerprint 仍只在 persistence load/save/readback/显式验收边界执行有界遍历；compatibility restamp 每个旧普通 Store 最多在升级 generation 产生一次正常保存。


## 0.10 `.18.124` Store-specific Serializer Shape Repair + Stable Task Codec

1. **不是新的通用容错开关**：Integrity v2 `fingerprint_mismatch` 仍默认 `integrity_failed + write fence`。只有 Store 显式注册 `rebuildEncodedForIntegrity` 才进入候选重建，而且该能力不得用于 `verifyAfterSave` Critical Store 或 `recoverableReplacement` Journal shard。
2. **双重证明边界**：只有 reliability `>=6` 且独立 Envelope Seal 已完整验证的 v2 Store 才允许尝试；hook 只生成候选，Persistence 自己再次执行 encoded budget，并用当前 `FingerprintEncodedPayload()` 计算候选哈希。候选必须**逐字等于原 stamped encoded fingerprint**才可加载。也就是说 hook 不能“解释成差不多”，更不能把未知损坏 normalize 掉。
3. **真实业务变化继续被拒绝**：只要任一 tracking key、布尔值、窗口状态或其它业务字段真的变化，重建候选就无法复现原 fingerprint，流程回到原有 `STORE_INTEGRITY_FAILED`。Harness 必须同时包含“已知序列化形态变化可恢复”和“业务字段变化不可恢复”两组样本。
4. **Tasks codec v2**：`v3.tasks` Domain 为了高频 membership 判定继续使用 `{[key]=true}` map；Persistence encode 时把 daily/weekly key set 转成排序字符串 array，decode 再恢复 map。这样业务查询仍 O(1)，而 SaveData 物理 representation 是确定性的。
5. **一次性升级**：已写入的 pre-codec Tasks 若通过 exact-fingerprint reconstruction 成功加载，会立即以 `integrity_serializer_repair` 标记 dirty，并在正常 Persistence 机制中重写 codec2；下一 Reload 不应再次走 shape repair。
6. **性能**：重建只发生在 Load 边界已经出现 fingerprint mismatch 时；没有 Tick、没有 Feature 扫描、没有额外常驻 LoadData。Tasks 的排序只发生在保存 encode，tracking 集合有现有 Store budget 上限。

## 0.11 `2026-09-05` Integrity v3 — Canonical Fingerprint 与受控旧档升级通道

RU 实机（横幅证据）确认 v2 原始包封指纹对**结构级**表示漂移仍然脆弱：`v3.tasks`(7776FEE0>2981E9D5) 与 `v3.death_review`(4AEAFC3B>161B2763) 在 Envelope Seal 健康的前提下跨重载 mismatch 并被写保护。v2 的 `%.6g` 数值 token 只吸收浮点精度漂移，无法吸收字符串键 map→序列、空表丢失、版本形状漂移等结构类漂移。本轮以 §14 的 canonical 管线收口：

1. **Integrity v3 = canonical fingerprint**：保存时对 `CanonicalIntegrityValue(store, domain)` 计算 `FingerprintDurablePayload` 并盖章 `integrityVersion=3`；加载时在 Envelope Seal + 原始预算检查通过后 **decode → store normalize/encode（canonical）→ hash → 比对**。磁盘表示漂移只要不改变规范化后的逻辑内容即被吸收；真实内容变化仍 fail-closed。canonical 的定义：有类型化 codec 的 Store 取 `encode(decode(raw))`，无 codec 的 Store 取 `migrate(domain)`（固定形状 normalize），都没有则原样 Domain。
2. **v3 管线 = Decode → Normalize → Verify → Apply**：v3 校验通过后，无 codec Store 直接 apply 规范化 canonical 值（不再只依赖 schema bump 才 normalize）；有 codec Store apply decode 输出（decode 自身规范化）。
3. **v2 世代仍可读**：`integrityVersion=2` 继续按 v2 原始包封语义校验；校验通过的 v2 Store 在 Apply 成功后排队 `integrity_v3_upgrade`（deferred save 重盖 v3 canonical），防止下一次表示漂移再次误伤。
4. **受控升级恢复（allowIntegrityUpgrade，默认开启、可显式退出）**：v2 盖章 + mismatch 时，若 Envelope Seal 有效、reliability>=6、decode + Domain budget 全部通过，则按 `integrity_upgrade_recovery` 接受加载并立即以 `integrity_v3_upgrade` 重盖——一次性、重新武装 strict 校验。**2026-09-05 实机复核（第二份横幅）证明该漂移是序列化器普遍行为**：`v3.life.bonds`、`v3.gear.payload.1/3`、`v3.death_review.record.9` 等上一代会话首次落盘的 v2 Store 在首次跨重载即全部 mismatch，逐 Store 白名单只会把用户数据逐批封存到后续版本，因此策略翻转为默认开启；`verifyAfterSave`/`recoverableReplacement` journal 分片同样纳入——对它们而言本路径严格优于替代的 `replaceCorrupt` 破坏性覆盖恢复。确需绝对 fail-closed 旧档语义的 Domain 可显式 `allowIntegrityUpgrade=false` 退出（v9 harness 同时锁定默认恢复与显式退出两个方向）。
5. **修复钩子保留并强化**：`rebuildEncodedForIntegrity` 现支持 `{candidates={...}}` 多历史形态候选（pre-codec 裸 Domain 形与中间包装形），仍要求候选哈希**逐字等于**原 stamp；修复失败才落入第 4 条的受控升级。`DecodeTaskState` 同时兼容 codec 包封、中间包装形与裸 Domain 形，旧用户数据无需重置。
6. **decoder 契约收窄（显式记录）**：v2 时代"损坏数据永不进入自定义 decoder"的保证，在 v3 下收窄为"**损坏数据永不进入 apply/Domain**"。前提：所有 decode/encode 钩子为纯规范化函数且 `DecodeValue` pcall 包裹 + 前后预算检查；v5 harness 的对应断言已更新为该不变量。
7. **回读/耐久口径统一**：`VerifyPersistedValue` 对 v3 盖章比较 canonical 值（期望=盖章时 canonical(Domain)，实际=canonical(decode(readback))），屏障回读不再因表示漂移假失败；v2 盖章保留原始比较分支。
8. **可观察性**：`Describe()` 行本就携带 `lastIntegrityStatus/lastIntegrityError`；诊断页 per-store 行追加完整性状态；门禁 persistence_reliability 行新增 `v3Upgrade=<recoveries>/<resaves>`。新增 harness：`rs_persistence_reliability_v9_harness.py`（canonical 吸收 / 未 opt-in fail-closed / v3 损坏拒绝）、`rs_task_persistence_codec_harness.py` 重写（严格修复、版本漂移受控升级、v3 漂移吸收、损坏 fail-closed、耐久回读）。
9. **已知残余风险（如实记录）**：受控升级一次性接受旧档时，真实损坏若恰好通过 Envelope Seal + decode + normalize + budget + schema 全链（即业务等价的损坏），会被接受一代；重盖 v3 后恢复 strict。这是"用户数据可恢复"与"绝对 fail-closed"之间的显式取舍；2026-09-05 起默认对所有 v2 旧档生效，Domain 可显式退出。

## 0.12 `2026-09-06` Integrity v4 — 内容盲 canonical 修复与契约升版

实机横幅链（172E3CEB>1EC94F52 → 172E3CEB>1FA5386F，trade 新增 1D5E8884>04762FCF，`v3UpgradeFail=0` 且 fence 无 upgrade_gate 后缀）完整揭示了 v3 世代的缺陷：life bundle 的 store 注册助手把 `migrate = default`（一个忽略输入、恒返回全新默认表的函数）传给了 canonical 管线，导致：

1. **内容盲盖章**：v3 盖章哈希的是 store 的**默认表形状**，不是实际内容——真实损坏会被"验证通过"（比 drift 更严重的完整性漏洞）；
2. **默认形状变更即假损坏**：`.18.127/.18.128` 调整 bonds 默认形状后，旧盖章（旧默认形状哈希）与验证（新默认形状哈希）必然失配 → fence；
3. **修复 canonical 即再失配**：换上真规范化函数后，验证目标从"默认形状哈希"变为"内容哈希"，与旧盖章再次失配。

处置：`IntegrityContractVersion = 4`（canonical = 修复后的 per-store 纯规范化）；`ContentBlindCanonicalContractVersion = 3` 登记 v3 世代。v3 盖章的哈希不构成完整性证据，因此该世代跳过指纹比对、直接走受控一代升级（Envelope Seal + decode + Domain budget + apply 全链通过 → `integrity_contract_upgrade_recovery` → 重盖 v4）。v4 验证 = Decode → Normalize → Verify → Apply，内容敏感且吸收表示漂移。四个 life store 已显式传入真 migrate；注册助手支持自定义 migrate/budget。v9 harness 新增内容盲恢复用例（含"内容在恢复后完整保留"断言——旧路径会把内容重置为默认）。

## 0.13 `.18.146` Death Review Canonical Window + Terminal Load Memoization

2026-09-07 RU Fresh Reload 再次出现 `v3.death_review:integrity_failed:fingerprint_mismatch:770CB0B8>20692C15`。这次不是 Integrity v1/v2 数值规则，也不是 v3 内容盲 canonical，而是 **Store 自己的 canonical 仍含 Presentation 状态 passthrough**：Feature 写入 `widgetWindow` 前使用 `FloatingSurface:NormalizeState()`，但 DeathReview `NormalizeIndex()` 原样保留该表。Native SaveData 若省略 `false/default/空字段`，逻辑窗口状态等价，但 v4 canonical hash 变化。

1. DeathReview Store 现在拥有唯一 `WidgetWindowSizePolicy`，`NormalizeIndex()` 对 `widgetWindow` 始终调用共享 FloatingSurface 纯 normalizer；Feature Get/Set 复用同一 policy。
2. 不新增 Store key/schema，不清旧档，不关闭 integrity。`.18.145` 及之前近期版本在 Feature mutation 边界写入的本来就是完整 FloatingSurface logical shape，所以加载侧重建被 Native 省略的默认字段后，可直接验证旧 v4 stamp。真实业务字段变化仍 fail-closed。
3. Persistence 新增 terminal-load memoization：同 generation 已经 terminal + write-fenced 的结构性 Load failure，再次 LoadStore 直接返回首个错误，不重复 Native LoadData/故障计数。它只去除重复 incident，不把 terminal Store 暴露为 ready，也不修改 ClearStore / verified replacement 的恢复 Authority。
4. 性能：canonical normalize 只发生在原有 persistence save/load/readback 边界；terminal memoization 减少失败状态下重复 Native I/O。无新增 Tick/Scheduler。

## 0.14 `.18.147` Historical Canonical Exact Recovery

`.18.146` 在 RU Fresh Reload 后仍返回同一个 `770CB0B8>20692C15`，因此必须撤销“`.18.145` 旧 Death Review stamp 来自完整 FloatingSurface logical shape”的假设。实际 `.18.145` Store `NormalizeIndex()` 对 `widgetWindow` 是 opaque passthrough：Feature/Native 往返可能留下 `{}`、partial 表或省略 false/default 字段，旧 v4 stamp 因而合法地对应**历史 opaque canonical**，不能靠当前 normalizer 直接复现。

Persistence 增加 `HistoricalCanonicalRecoveryContractVersion=1`，并允许单个 Store 显式提供 `rebuildCanonicalForIntegrity(decoded, stampedFingerprint, currentCanonical)`。该能力不是通用“忽略 mismatch”，而是受以下边界约束：

1. Envelope/Seal 必须先通过；decode 必须成功；Domain budget 必须通过；Store 必须显式 `allowIntegrityUpgrade=true`。
2. 当前 canonical fingerprint 正常不匹配后，才允许构造一个**历史 canonical 候选**；Core 仍使用当前确定性 `FingerprintCanonicalValue()` 计算候选 hash。
3. 只有候选 hash **精确等于 envelope 中已经 stamped 的 fingerprint** 才允许恢复；否则继续 `integrity_failed`、write fence，真实内容损坏不会被吞掉。
4. Death Review 的 opt-in hook 只复原 `.18.145` 的 opaque `widgetWindow` canonical；成功后实际应用的是当前 `FloatingSurface:NormalizeState()` canonical，并立即以既有 `integrity_v4_upgrade` 流程重盖当前 stamp。下一次 Reload 必须走普通 `verified_canonical`，不应每代重复兼容。
5. 该路径只发生在 Load 边界，无 Tick/轮询；错误 Store 不提供 hook 就完全不受影响。

`.18.146` 的 terminal-load memoization 保留：同 generation terminal+fenced failure 仍只产生一次物理 Load/incident；历史精确恢复成功不是 terminal failure，会进入正常 apply + restamp 路径。

## 0.19 `.18.193` Activities / DeathReview Canonical Generation Boundary

`.18.192` RU 诊断同时出现 `v3.activities:6271E40B>7E85D975` 与 `v3.death_review:014277AB>0CF5BCC1`，并伴随 `toggle_binding_failed` 页面事务回滚。根因不是 Toggle：两个永久 Store 的窗口 canonical 跟随共享 `FloatingSurface` 增长，但 schema 没有表达 canonical generation 变化。Store 被 Integrity v4 Fence 后，RSUI Persistent Binding 的 `PrepareRead` 正确 fail-closed，页面构建失败只是上游存档故障的可见结果。

1. **Store-owned projection**：Activities/DeathReview 都先调用共享 Floating normalizer获得逻辑窗口状态，再通过固定字段白名单投影为本 schema canonical。以后 Foundation 新增字段不会自动改变现有 Store fingerprint。
2. **Activities**：`schema 7 -> 8`。historical-v7 projection 不包含 `savedLogicalWidth/Height + normalizedCenterX/Y`；current schema8 包含这些 v11 响应式元数据。exact historical candidate 仍由 Core 重新 Hash 并必须精确等于旧 stamp。
3. **Activities known pair**：exact reconstruction 失败后，仅允许 `old=6271E40B / current=7E85D975 / schema=7 / store=v3.activities / owner=v3.activities`，同时 strict validate 根字段、hiddenEvents、窗口字段及类型。任一条件不匹配即返回 nil。
4. **DeathReview**：Index `schema 1 -> 2`，codec 仍为 v1，record store schema1 不变。historical router 区分 pre-codec opaque 世代与 schema1+codec1 世代；后者只回退窗口投影，不猜 settings/history。
5. **DeathReview known pair**：保留 `770CB0B8` pre-codec allowlist，并新增 `014277AB -> 0CF5BCC1` schema1+codec1 pair。新 pair 必须通过 codec1 root/settings/history/window 严格形状验证，再校验 current canonical Hash。
6. **保存优先级**：若 historical/known-stamp recovery 已把 `deferredSaveReason` 设为 `integrity_v4_upgrade` + 0ms，后续 schema migration 只能迁移 Domain，不能覆盖该立即重盖语义；纯 migration 才使用默认 debounce。
7. **禁止方案**：不得清 Activities/DeathReview Store、关闭 Integrity、修改 Core 为“同 Store mismatch 自动接受”、让 RSUI Binding 在 Fence 时套默认值、或把 known pair 扩成前缀/范围匹配。
8. **性能**：字段投影是固定约 20 项，仅在 Store Normalize/Save/Load 边界执行；known-pair shape 验证只在 current-v4 mismatch 冷路径执行。无 Tick、Scheduler、CombatEventBus 或列表刷新成本。

## 0.18 `.18.188` Shell Schema 7 / Known Legacy Stamp Recovery

`.18.184` 与 `.18.187` 两次 RU Fresh Reload 都稳定报告 `v3.shell:integrity_failed:fingerprint_mismatch:2EA0A82A>2EC2F5C5`。同时源码历史确认 `.18.157` 的 Resolution/Coordinate Foundation 给 Shell canonical 增加 `savedLogicalWidth/Height + normalizedCenterX/Y` 时仍保留 schema 6。新增字段若在旧 payload 中不存在并不必然改变 Hash，但同 schema 已经无法表达 canonical generation 边界，因此必须修正。

1. `v3.shell` 升为 `schemaVersion=7 / legacySchemaVersion=6`；当前 schema7 normalizer 保留响应式 viewport metadata，另冻结一个 historical-v6 normalizer，只包含 schema6 时代的窗口字段。
2. current-v4 mismatch 时先走 `rebuildCanonicalForIntegrity`。候选必须在 Envelope Seal 已通过后由 Core 重新计算 fingerprint，并**精确等于旧 stamp**才可恢复；它不会因为 Store 是 UI 状态而放宽。
3. 对连续两轮完全一致的真实事故 pair `2EA0A82A > 2EC2F5C5`，exact reconstruction 若仍无法命中，再走 Store-owned `recoverKnownLegacyCanonical`。该 hook 只允许 `schema=6 + store=v3.shell + owner=v3.shell + old stamp=2EA0A82A + current canonical=2EC2F5C5`，然后返回当前 Normalize 后的 Shell Domain。任何其它 old/new pair 立即返回 nil，继续 Fence。
4. 成功恢复后 Core 仍执行 Domain/current-canonical budget 检查，随后 schema6→7 migrate 并立即保存新 envelope。下一个 Fresh Reload 必须成为普通 schema7 `verified_canonical`，该 one-time bridge 不应每代重复触发。
5. `rs_regression_18_188_harness.py` 使用 real Lua + real `rs_persistence.lua` 模拟一个 schema6 历史 canonical 与含新响应字段的磁盘 payload，验证 exact reconstruction 可以 unfence 并只保留旧 stamp 已认证的字段；同时直接执行 Bag Gate 证明跨 lexical-scope 的 false blocker 不再出现。

该恢复不清 `v3.shell`，不修改其它 37 个 Store，也不把 session fallback 默认值写回旧存档。

## 0.17 `.18.151` Death Review Known Legacy Canonical Stamp Migration

`.18.150` RU Fresh Reload 仍稳定报告 `v3.death_review:770CB0B8>368335F2`。连续 `.18.146-.18.150` 五轮旧 stamp 完全不变，而 current canonical 随修复已稳定到 `368335F2`；继续扩大表形子集搜索会把一次性兼容逻辑变成不可维护的 brute force。`.18.151` 因此把 `770CB0B8` 视为**该 Store 的已知历史迁移身份**，而不是放宽通用 Integrity。

1. `HistoricalCanonicalRecoveryContractVersion=3` / `KnownLegacyCanonicalRecoveryContractVersion=1`：current-v4 mismatch 先执行既有 exact historical reconstruction；只有 exact 路径失败后，且 Envelope Seal、metadata/store/owner/scope/schema、decode 与 Domain budget 已全部通过，才允许调用 Store 显式 `recoverKnownLegacyCanonical`。
2. Death Review allowlist 当前只有 `770CB0B8`。hook 额外验证 pre-codec schema1 Index 的字段白名单、标量类型、history≤30、summary serial/storageId 合法且唯一、widgetWindow 仅允许历史 FloatingSurface 字段/opacity alias。其它 fingerprint 或 shape 失败继续原样 Fence。
3. 该迁移无法恢复 Native 已不可逆删除且旧 Hash solver 也无法反演的单个字段；它只保留磁盘仍存在的 settings/history/window，并通过当前 Normalize + codec v1 形成长期稳定表示。这里的安全边界与历史 Integrity v3 content-blind 一代升级类似：承认旧世代证明不可再完整重放，但不允许未知 stamp 借此通过。
4. 成功后 `preDecodedValue` 仍经 Core budget + current canonical 检查，设置 `integrity_v4_upgrade` 立即重盖；下一 Fresh Reload 必须 `verified_canonical`。该桥不进入 Save/Tick/Feature 热路径。
5. Diagnostics Snapshot 暴露 runtime-only `historicalRecoveryProbe`；A2 固定纳入 `v3.death_review` 并在存在时输出 `DRProbe`，避免 Foundation 长摘要 180/130 字符截断导致关键 shape evidence 丢失。

## 0.16 `.18.150` Death Review Historical Sequence/Map Recovery + Shape-Only Probe

`.18.149` RU Fresh Reload 后，页面 Build 事务已全部恢复为 0 故障，唯一剩余 Store Fence 为 `v3.death_review:770CB0B8>368335F2`。因此 `.18.150` 不改变正常 Integrity v4/codec 管线，只扩展 Death Review 的 **Store-owned historical reconstruction hook**。

1. 正常 `NormalizeIndex/DecodeIndex/EncodeIndex` 仍以 sequence 为业务结构，不使用 `pairs()` 代替 Authority 语义。
2. 仅当 Envelope Seal 已通过、当前 Integrity v4 canonical mismatch、Store 显式存在 historical hook 时，额外把 `history.entries` 通过 bounded `pairs()` 收集为第二个历史候选基底；最多 30 条，按 `serial/storageId` 稳定排序。
3. 该候选没有信任权。只有完整 historical canonical fingerprint 与磁盘原 stamped fingerprint **逐字相等**时，Persistence 才把 recovered Domain 交给当前 codec 重新 canonicalize/Apply，并立即排队重盖当前 stamp。
4. `.149` 的 default-TRUE boolean false 恢复与 opaque window subset 仍然是同一 bounded mutation（≤12 位/基底），current codec envelope 禁止进入旧形恢复。
5. 最终仍 mismatch 时，错误串可附 `historical_probe=histIpairs=.../histPairs=.../rawEntryKeys=.../winKeys=.../defaultTrueMissing=.../winRecoverable=.../bases=...`。这是 runtime-only 形状证据，不包含玩家、技能、伤害或死亡记录内容。

该机制是兼容性恢复器，不是第二套 History Authority，也不在 Tick/事件热路径执行。

## 0.15 `.18.149` Death Review Serializer-Stable Index Codec / Historical Domain Recovery

`.18.148` 在同一真实旧 Store 上仍复现 `770CB0B8>20692C15`。窗口 subset 搜索本身保持 exact-match，但遗漏了 Store 内两个 default-TRUE 业务布尔：`autoShow` 与 `showDebuffs`。历史盖章若包含显式 `false`，RU 落盘省略该字段后，当前 Normalize 会把 `nil` 解释为默认 `true`，因此仅重建窗口永远无法命中旧 Hash。

1. `HistoricalCanonicalRecoveryContractVersion=2`：hook 仍必须先精确复现旧 stamped fingerprint；v2 额外允许返回 recovered Domain，并接收只读 raw envelope。Core 只在旧 Hash 精确匹配后，预算检查 recovered Domain，再对它运行当前 canonical，最后 Apply；禁止从已丢信息的 `canonical(decoded)` 猜业务值。
2. Death Review 将缺失 `autoShow/showDebuffs` 的 `false` 候选与 legacy opaque-window 缺失字段放进同一 bounded mutation set，最多 12 位/4096 候选；候选不精确命中旧 stamp 就继续 Fence。
3. Index codec v1 将 default-TRUE 布尔改为稳定负向数值 sentinel：`autoShowDisabled=1`、`showDebuffsDisabled=1`。未出现 sentinel 明确表示 true，因此 Native 省略 Lua `false` 不再造成业务歧义。Store id/key/schema 不变；Decode 同时接受 pre-codec V3 plain envelope，用户无需清配置。
4. FloatingSurface `minimized/locked/userMoved` 等默认 false 字段继续使用共享 NormalizeState；这类 false 被 Native 省略时语义仍可由默认值唯一恢复。
5. 首次从 `.18.145` opaque canonical 恢复时会以当前 codec 重盖；随后 Save/Barrier/Reload 均按 codec canonical 验证。该兼容搜索只位于 mismatch load 路径，无 Tick/OnUpdate。

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
    framework = 2,
    store = "v3.example.daily_counters",
    owner = "v3.example",
    contractVersion = 3,
    lifetime = "Daily",
    scope = "Account",
    schema = 1,
    periodId = "2026-08-26",
    reliabilityContract = 4,
    integrityVersion = 1,
    encodedFingerprint = "XXXXXXXX",
}
```

### 以下情况必须 Store 级写保护

- `LoadData` 明确报错；
- Encoded envelope 超出读取预算或结构非法；
- v4 encoded integrity fingerprint 不一致；
- Decode 失败；
- 存档 Schema / Reliability contract 高于当前代码；
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

显式 Recovery Reload 会在触发原生界面重载前先尝试 `Flush()`；Flush 失败保留 dirty Store、故障 evidence 与有界重试，但不会阻断加载修复文件。显式 strict durability 调用仍可要求 `Flush()` 全成功；Runtime Stop 在任何 Feature teardown 前继续执行独立 durability barrier。

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

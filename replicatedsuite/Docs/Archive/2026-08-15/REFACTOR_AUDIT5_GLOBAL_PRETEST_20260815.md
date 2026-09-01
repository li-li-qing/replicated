# Replicated Suite v1.1 — Audit5 全局测试前深审

版本：`1.0.3-architecture-v1.1-audit5`  
日期：2026-08-15  
基线：`Replicated_Suite_Architecture_Final_v1.1_20260815` + Audit4

## 1. 本轮目标

Audit5 不再重复 Audit1–Audit4 已经完成的模块拆分，而是从冻结架构文档反向审计 Runtime，重点寻找“静态结构已经重构、真实时序仍可能回退”的问题：

- Character Scope 冷启动、同 generation 切角色、运行时投影同步；
- ModuleManager 启停幂等与 fault cleanup；
- Disabled 模块是否仍保留事件 / OnUpdate / 周期保存；
- 保存读取失败、未来 Schema 的不可逆覆盖风险；
- Capability Registry 是否真正成为 Suite 内置服务的 API 边界；
- Team / Range 的 DPS Scope 硬隔离；
- Scheduler 与高频 HUD 路径的无意义分配；
- Quiet by Default；
- TOC、Sandbox、死文件、旧入口、私有模块与 UI 自动省略残留。

冻结的四份 Architecture 文档未修改，最终逐字节一致。

---

## 2. Audit5 关键修复

### 2.1 Save Schema 20：修复 Audit4 Character Override 的 `false` 丢失

Audit4 Schema19 的 `BuildCharacterOverride()` 使用了等价于：

```lua
value = settings[key] or nil
```

Lua 中合法的 `false` 会被折叠为 `nil`，因此下列角色级 OFF 状态可能没有写入 Override：

- `teamAutoRoleEnabled = false`
- `sacMarkerEnabled = false`

Audit5：

- Save Schema 升级到 **20**；
- 显式保留 `false`；
- 对 Schema19 做确定性修复：该 writer 版本中 `true` 一定存在，缺失值只可能来自被吞掉的 `false`，因此缺失字段可安全补回 `false`；
- 新写入始终显式序列化角色布尔值。

### 2.2 Character Scope 冷启动不再覆盖已有角色 Override

Audit4 已覆盖“旧 Schema → 新 Schema”的延迟身份迁移，但未覆盖：

> 已经是 Schema19/20 + 已有角色 Override + 启动早期 `UnitNameWithWorld` 暂不可用。

旧路径可能先显示 Account Base，身份稍后恢复时再把这个 Base 当成当前角色值保存，覆盖已有角色 Override。

Audit5 增加：

- `deferredCharacterSnapshot` 冷启动有效状态快照；
- `MergeColdEdits()`：已有 Override 为 Authority，只叠加身份冷启动期间用户真正修改过的字段；
- Account Base 与有效 Character State 永远分离；
- `BuildSavePayload()` 返回 detached deep-copy，不允许序列化过程反写 Runtime State。

### 2.3 同一 Addon generation 内 A → B → A 角色切换

不再假定客户端一定会通过完整 Addon reload 隔离角色。

Audit5：

1. 低频 `character_scope_watch` 每 15 秒检查 world-qualified identity；
2. `ENTERED_WORLD` 后执行有限次数身份重试；
3. A → B 时先快照 A Override；
4. 恢复稳定 Account Base；
5. 应用 B Override；
6. 只 reconcile 角色域 Module；
7. 再延迟 500ms 重建角色相关 Runtime 投影。

投影固定顺序：

`Quest → Resource → Event`

并在刷新 Resource 前废弃旧角色 bag snapshot，防止 A 的日常追踪、活动完成标记、每日资源计数暂时残留到 B。

### 2.4 Character Scope API 进入 Capability Registry

`X2Unit:UnitNameWithWorld` 正式注册为 Capability，Storage 不再私自判断函数存在性。

Character identity 只接受 world-qualified 值，不退回裸 `UnitName`，避免：

- 不同世界同名冲突；
- 冷启动先生成裸名 Key，稍后又生成 world Key 的双身份。

---

## 3. 保存安全：Suite 与四个专业 Domain

### 3.1 Suite 主存档

新增两类写保护：

- **LoadData 读取异常**：允许本次会话使用默认内存状态，但禁止 `SaveData` 覆盖原存档；
- **Future Schema**：较旧 Audit 可以只读投影已知字段，但绝不把更高 Schema 重写成当前 Schema。

写保护不是重试型错误；Storage 不会每个周期继续无意义唤醒 SaveData。

### 3.2 Healer

新增：

- future `settingsVersion` 写保护；
- LoadState 异常写保护；
- 正常当前版本 / 全新配置 **启动时不再无条件 SaveState**；
- 只有版本迁移或从备份恢复时，启动才提交一次。

这修复了“模块 Disabled，但每次进游戏仍 Clear + Save 主/备配置”的 Quiet/数据风险。

### 3.3 Gear

新增：

- future root schema 写保护；
- root 读取失败写保护；
- 每个套装 Payload 独立 future schema 写保护；
- 删除未来 Payload 对应索引时，不顺手 Clear 未知未来 Payload Key。

旧版索引/嵌入式 Payload 的必要迁移仍保留；如果命中写保护，迁移只读不覆盖。

### 3.4 Plates

新增：

- future settings schema 写保护；
- settings load failure 写保护；
- future tracking manifest 写保护；
- tracking manifest / shard 部分读取失败写保护。

因此“只读到一部分追踪表”不会再被当成完整 Authority 回写并覆盖原追踪分片。

### 3.5 DPS

Audit5 将 DPS 的前向保护补齐到三个小配置域：

- `config`
- `ui`
- `rules`

原逻辑会拒绝 future config，但可能退回旧 backup，然后通过正常事务把 future primary 覆盖成旧版本。现在：

- 任一槽发现 future schema → 对该域写保护；
- 任一槽发生 LoadData 读取异常 → 对该域写保护；
- 仍可只读采用当前可验证的 primary / pending / backup 供本次会话使用；
- Dirty/SaveNow 不会在写保护状态持续重试；
- `ClearSlots()` / `SaveTransactional()` 都无法绕过写栅栏。

DPS 大型 stats 持久化仍保持其现有 rotating / recovery / shard 门禁，不在实机测试前做机械重写。

---

## 4. Lifecycle / Authority

### 4.1 ModuleManager Disable 真正幂等

Audit4 的代码注释声明 Disable 幂等，但已 Initialize 的模块即使已经 Disabled，第二次 Disable 仍会再次进入业务 Disable Hook。

Audit5 改为：

- `Initialized / Enabled → Disabled`：首次执行 Hook；
- 已经 `Disabled`：再次 Disable 不重复进入业务 Hook；
- `Faulted`：仍允许 best-effort cleanup 重试；
- Enable 后再次 Disable：正常重新执行一次清理。

行为仿真同时验证 Enable fault 会清理：

- Event owner；
- Scheduler owner；
- Service owner；
- Professional Observation subscription。

### 4.2 Runtime / Event / Scheduler Stop

复核并保持：

- Suite Runtime 即使只启动到一半，Stop 仍做 best-effort quiescence；
- Event host Stop 释放 `OnEvent`，隐藏并断开 host；
- Scheduler Stop 释放 `OnUpdate`，清任务并断开 driver；
- Gear / Healer / Plates / DPS Disable 均释放自己的 Runtime Handler；
- Disabled 不清 Domain 数据。

### 4.3 Safe UI Refresh 单事务 Authority

Audit4 的 VSync 安全刷新在极短时间连续触发时可能存在两个 RestoreHost，各自捕获不同“原值”。Audit5：

- 同一时间只允许一个 Refresh transaction；
- 第二次请求在前一事务恢复前直接拒绝；
- generation 变化也先恢复原 VSync，再释放 OnUpdate Host；
- helper host 创建失败时同步恢复；
- bootstrap 会清理上一 generation 遗留 RestoreHost。

没有重新启用危险的 `ADDON:ReloadAddon()` 路径。

---

## 5. Quiet by Default

冻结架构要求专业 / 新增高频功能默认关闭。

Audit5 新装默认值调整为：

- DPS：OFF
- Gear：OFF
- Healer：OFF
- Plates：OFF
- Team Utility：OFF
- 自动职责：OFF
- 牺牲之舞标记：OFF
- 六个生活/活动 HUD：全部 `visible=false`

基础生活数据服务仍可按架构默认 Enabled，但不会自己弹出 HUD。

**已有用户存档优先。** Audit5 不会强制关闭用户过去明确保存为开启的模块或团队辅助设置。

---

## 6. 高频路径与性能

### 6.1 Scheduler

统一 Scheduler 原来每一帧都会：

- 新建 `dueNames`；
- 新建 backlog table；
- 创建排序闭包；

即使本帧没有任何任务到期也会产生 GC 压力。

Audit5：

- 复用 `dueScratch`；
- backlog 原地更新；
- 只有两个以上到期任务才排序；
- 排序比较器提升为复用函数。

行为测试验证回调中自删 / 新增任务不会破坏遍历语义，新任务不会错误地在同一帧执行。

### 6.2 Team Utility 牺牲之舞 HUD

位置跟随仍保持 50ms，但倒计时文字只在显示的 0.1 秒值变化时 `string.format + SetText`，避免每 50ms 无意义重建字符串与 Label invalidation。

### 6.3 DPS Team / Range 硬栅栏

正常 UI 切换原本已经会取消 sight task；Audit5 再把 invariant 放到 Runtime：

- Team Mode 发现任何遗留 `sightTask` 立即丢弃；
- Team Mode 永不进入 `StepSightTask`；
- 因此配置恢复 / 程序化切换也不能继续消费 Range 快照。

整包业务代码中 `GetUnitsInSight` 的正式广域使用仍只存在于 DPS Nearby/Range 链。

---

## 7. API Capability Registry

Suite 自有 Service 的可选 API 已统一到：

- `IsCapabilityAllowed`
- `CallCapability`
- `ActionCapability`

当前验证：

- Capability Registry：51 条记录；
- Suite-owned 代码发现的 literal capability 使用全部已注册；
- 使用项在 bundled `z_api_functions/api_functions.lua` 静态快照中均能找到对应 namespace/method token；
- Suite service/core（除中央 `rs_api.lua` 低级实现自身）直接 `S.Api:Call/Action` 绕过 capability boundary：0 个文件；
- 写操作 / server query 不自动 Probe。

专业模块历史 API Adapter 暂不在测试前做机械替换，避免改变已经验证过的高频业务路径。

---

## 8. 清理

删除 3 个 TOC 从未加载、Runtime 无消费者的死文件：

- `core/rs_recovery_entry.lua`
- `data/rs_daily_quest_ids.lua`
- `data/rs_weekly_quest_ids.lua`

同时清理 `rs_quest_data.lua` 对旧 `DailyQuestIds` 的误导注释。

最终：

- Suite Lua：104
- TOC Lua 条目：111（其中 7 个是 `../globals`）
- TOC 缺失：0
- Suite Lua 未被 TOC 引用：0
- Professional Lua：41
- Sandbox：41/41
- `SetEllipsis(true)`：0
- 私有 AutoPotion Runtime 痕迹：0
- Active `ADDON:ReloadAddon()`：0
- Professional Domain 互相直接引用：0

---

## 9. 自动验证结果

最终验证：**39 / 39 PASS**。

四组行为仿真：

1. `AUDIT5_STORAGE_SCOPE_TESTS=PASS`
   - Schema19 false 修复；
   - Schema19/20 冷身份；
   - A→B→A；
   - 新角色 Account Base；
   - LoadData 失败写保护；
   - Future Schema 写保护；
   - Runtime started 后角色模块 reconcile。
2. `AUDIT5_SCHEDULER_TEST=PASS`
   - 优先级；
   - 回调自删/新增；
   - scratch 复用；
   - Stop Handler 释放。
3. `AUDIT5_RUNTIME_SCOPE_PROJECTION_TEST=PASS`
   - Team settings 立即 reconcile；
   - 500ms P2 scope projection；
   - Quest→Resource→Event 顺序；
   - Resource cache 先失效；
   - Disabled module 不刷新。
4. `AUDIT5_MODULE_MANAGER_TEST=PASS`
   - Disable 幂等；
   - re-enable 后再 disable；
   - Enable fault cleanup Event/Scheduler/Observation owner。

完整机器结果见：

`Docs/VALIDATION_ARCH_V1_1_AUDIT5_20260815.json`

---

## 10. 本轮刻意不做的高风险改动

### 10.1 不强制迁移专业 Domain 的历史 SaveKey

DPS / Healer / Plates 历史存档仍保留原 Domain key；Gear 继续使用自身角色隔离。

原因：当前没有足够实机证据证明跨旧 Addon namespace 的历史 `ADDON:LoadData` 迁移语义。测试前强行换 Key 的数据丢失风险高于架构收益。

### 10.2 不机械改写专业模块全部 API Adapter

Suite built-in 已统一 Capability Registry；DPS/Gear/Healer/Plates 的成熟 Adapter 先保持业务兼容，后续应基于实机 API 证据逐 Domain 收口。

### 10.3 不删除专业模块内部仍存在的历史 launcher/window 结构依赖

嵌入 Suite 后这些旧独立 launcher 不再拥有公开可见 Authority，也不承担周期业务 Runtime；部分对象仍被旧 UI 结构引用。测试前强删会扩大 UI 回归面。

### 10.4 保留 Event Widget 的可见态本地 OnUpdate fallback

它只在 Widget 有效可见时运行，用于 Scheduler clock 没推进时的显示时钟兜底，不修改 Suite Clock Authority；冻结架构只要求“尽量减少 Module 内独立 OnUpdate”，不是绝对禁止。当前实现会在不可见时释放 Handler。

---

## 11. 实机测试优先顺序

1. **Audit4 → Audit5 原存档升级**：特别验证“自动职责=关 / 牺牲标记=关”没有重新变成开。
2. **角色 A/B**：A、B 设置不同的专业模块开关、团队辅助、日常追踪；A→B→A，检查不串号。
3. **角色投影**：切角色后任务、资源统计、活动日完成状态约 0.5 秒内刷新成当前角色。
4. **Fresh / 无旧档**：只有 R 入口可恢复；四专业模块和 Team Utility 默认 OFF；没有自动职责写操作；六个 HUD 不自动弹出。
5. **安全 UI 刷新**：连续快速点两次，第二次应被拒绝；刷新后 VSync 应恢复到原值。
6. **生命周期**：Gear / Plates / Healer / DPS 分别执行 `开 → 关 → 再开 → 再关`，确认 UI、事件、OnUpdate 都能恢复/释放。
7. **DPS Range → Team**：在 Range 正在观察时立即切 Team；不得继续广域 sight task，不自动清历史统计。
8. **Healer**：团队高亮、头顶标记仍正常；Suite 模式不出现旧独立推荐排行 HUD。
9. **Plates**：Buff/Debuff/PVP发现/重要冷却反复启停，关闭后不应继续 Runtime 处理。
10. **长战斗**：5 人 → 100 人 → 200 人；观察卡顿出现时间、Scheduler Backlog、DPS Scope、Module 状态。

如果实机出现问题，优先提供：

- 复现操作顺序；
- 当前角色；
- Module Enabled 状态；
- DPS Team/Range；
- 诊断页 Storage / Character Scope / Backlog / Module Fault；
- 是否由 Audit4 原存档直接升级。


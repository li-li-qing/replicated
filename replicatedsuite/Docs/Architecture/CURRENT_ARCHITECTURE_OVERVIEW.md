# 当前架构总览（V3）

> **Authority: CURRENT** · 本页是新人上手 Replicated Suite 的唯一入口。
> 旧版（modules/professional、legacy_reference、旧 ui/rs_*、旧 services）已于 2026-09-01/02 全部物理删除，不再随包。任何描述旧架构的文档章节均以本页为准。
> 代码与 `toc.g` 是唯一加载真相；本页与代码冲突时以代码为准，改完代码再回头修本页。

---

## 1. 形态

- 单一公开 Addon：`globals` + `replicatedsuite` + `z_api_functions`。
- 架构模式：`v3_rebuild`，Active TOC 只加载 V3 Application/Presentation Host。
- **旧版代码已全部删除**（163 文件、−10.3 万行），不存在"Legacy 保留为参考"。用户持有全量离线备份，插件树内绝不重新引入旧逻辑或迁移桥。

## 2. 加载模型

- 引擎按 **目录树 + `toc.g`** 加载，**无** `require`/`dofile`/`loadfile`。
- 文件在顶层自注册（如 `S.Services.Alerts = {...}`）。
- 判断"是否在用"只看 `toc.g` + 运行时调用链，**不凭文件名**。
- `toc.g` 与磁盘必须双向 0 差异：磁盘有但 toc.g 没有即死文件，必须删除或登记。对账时 toc.g 是 CRLF 行尾，比较前先 `tr -d '\r'`。

## 3. 加载顺序（toc.g 物理顺序）

```
1. config/rs_config.lua
2. native/            — Native 契约/导入/对象工厂/ESC 桥/能力宿主/恢复（6 文件）
3. data/              — GameDataRegistry + StaticDataV2 + ids/* 静态 ID（8 文件）
4. core/              — 基础设施层：constants/utils/reuse/demand/api/api_capabilities/
                       diagnostics/persistence/app_state_v3/ui_host_manager/performance/
                       frame_budget/observation/layout/scheduler/refresh_coordinator/events
5. ui/framework + ui/ — RSUI 框架：tokens/theme/native_primitives/framework/layout_v2/
                       binding_v2/components_v2/component_core/.../window_shell_v3/
                       floating_surface + design_system_v3
6. data/（业务静态）  — official_names/localization/quest/event/trade/skill_effects/
                       combat_catalogs/ids/{skill,buff,plates}
7. services/          — V3 共享服务（15 个，见 §6）
8. features/          — FeatureRegistry + FeatureRuntime + combat/life/tools 各域
9. presentation/v3/   — shell_store/launcher_store/native_adapter/router/widgets/
                       shell/modals/pages/host/acceptance
10. core/rs_foundation_gate.lua   — 启动前契约门禁
11. presentation/v3/rs_v3_sequence_cases.lua
12. features/*/acceptance         — 各 Feature 验收契约
13. core/rs_runtime.lua           — 最后加载，调 R:Start()
```

## 4. Runtime 启动阶段（rs_runtime.lua:Start）

```
api_validate      → S.Api:Validate()
static_validate   → GameDataRegistry / StaticDataV2 校验
static_seal       → 静态数据封印（不可再写）
app_state_load    → V3 AppState.EnsureLoaded()
layout_prime      → Layout.Invalidate + PrimeCurrentSignature + LauncherStore
presentation_hosts → 注册 V3 Host（legacy host 必须不存在）
event_bus_start   → S.Events:Start()
scheduler_tasks   → 安装 layout/persistence/observation 三个基础周期任务
scheduler_start   → 单一 Scheduler 启动
feature_defaults  → FeatureRuntime:EnableDefaults
foundation_refresh → UIHostManager:RefreshData
layout_finalize   → ApplyResponsiveLayout
esc_register      → 系统菜单入口注册
→ S.Ready = true
```

任一阶段失败 → `S.BootError` + `S.SafeChat` 告警 + 全部回滚 + 激活恢复入口。

## 5. 持久化契约

**唯一入口：`P:RegisterV3Store(def)`**（`core/rs_persistence.lua`）。禁止绕过它直调 `ADDON:SaveData/LoadData/ClearData`——这三个原语只允许出现在 `core/rs_api.lua` 与 `core/rs_persistence.lua`。

### Store 定义必填字段

| 字段 | 说明 |
|------|------|
| `id` / `owner` | 唯一标识 + 归属模块 |
| `lifetime` | `Permanent` / `Daily` / `Weekly` / `Session` / `Checkpoint` |
| `scope` | `Account` / `Character` |
| `schemaVersion` | Store 自身契约版本（升级时同步 FoundationGate 断言） |
| `default()` | 返回默认 payload（用于初始化与预算自检） |
| `load` / `save` / `apply` | 读写回灌回调 |
| `encode` / `decode` | 可选，默认包 `{ payload = value }` |
| `budget` | 可选，缺省走 `DefaultBudget` |

### 预算（DefaultBudget）

| 项 | 值 |
|----|----|
| maxDepth | 12 |
| maxNodes | 4096 |
| maxStringBytes | 65536 |
| maxEntriesPerTable | 1024 |

### 三道安全闸

1. **注册时预算自检**（`STORE_DEFAULT_BUDGET_EXCEEDED`）：注册即对 `default()` payload 跑 `InspectPayload`，超预算发 error 诊断（Session lifetime 豁免）。这把"首次保存才暴露的预算不足"前移到启动即可见。
2. **保存前 InspectPayload**：每次 save 前 O(n) 遍历检查 depth/nodes/stringBytes/entries，超预算拒绝写入并 `writeFenced=true`（整个会话禁止后续保存）。
3. **保存失败聊天告警**：`S.WarnOnce` 输出 `[v3.<store>] 存档超出安全预算`，不再静默只发诊断。

> 反模式警示：`NormalizeXxx` 归一化函数**只清洗格式，不许丢数据**。曾发生 `NormalizeTrackedIds` 硬截断 32，在 load/save 的 get() 里都跑，砍掉 713 个追踪 ID（commit 785c642 修复）。

## 6. 能力门（API Governance）

**所有 Native API 调用必须经 `S.Api:CallCapability` / `ActionCapability` / `CallGlobalCapability`**，禁止裸 `X2*:Method()`。

### 三步检查（CallCapability 内部）

```
① IsCapabilityAllowed(name)
   → ApiCapabilities:IsAllowed
     · 必须已登记（records 有条目）
     · OfficialState 非 Removed/OfficialDisabled
     · ObserveStaticState：宿主存在且方法是 function
     · RuntimeState 非 RuntimeFailed/CrashRisk
② ResolveCapabilityHost(name, object)
   · namespace → _G / UI / UIParent / ADDON
③ ConsumeCapabilityCooldown(name)
   · 按 ApiCapabilities.Cooldown 节流，消费在调用前
→ 通过后 S.Api:Call(object, methodName, ...) pcall 包裹
```

- 能力登记在 `core/rs_api_capabilities.lua`（records 表），来源 `z_api_functions` + RU 官方 overlay。
- 新功能需要的 API 必须先登记进 records，否则被门拦截。
- `S.Api:Call` 是低级原语（不做能力检查），仅 `CallCapability`/`ActionCapability` 内部和 rs_persistence 的 `ADDON:LoadData` 等已登记原语使用。

## 7. 事件桥（S.Events v4）

**双轨制**：原生主题与内部主题严格分离。

| 轨 | API | 特性 |
|----|-----|------|
| 原生主题 | `Subscribe` / `SubscribeOptional` / `Register` | 调 `host:RegisterEvent(eventName)` 注册游戏原生事件（COMBAT_MSG / BUFF_UPDATE / UNIT_EQUIPMENT_CHANGED 等）。Subscribe 失败回滚订阅；Optional 失败只降级不阻断。 |
| 内部主题 | `SubscribeInternal` / `Publish` / `UnsubscribeInternalOwner` | 纯 Lua 进程内消息，**不调 Native RegisterEvent**。Feature 发投影变更，Presentation 订阅，不会扩张游戏事件面。 |

- owner 绑定：`BindOwner(owner, moduleId)`，`UnsubscribeOwner` 批量释放。
- 事件总线用独立隐藏 Window，不替换其他 addon 的 `UIParent:SetEventHandler`。
- 启动在 Runtime `event_bus_start` 阶段；停止时 `S.Events:Stop()`。

## 8. 诊断入口

- **`S.DiagnosticsManager`**：`Emit(level, category, code, message, context)` / `Count(category, code, delta)` / `RateLimited`（战斗热路径必须用 RateLimited 限流，`Emit` 不限流）/ `Warn` / `WarningRateLimited` / `ErrorRateLimited`。
- **`rs_diagnostics.lua`**：诊断页面 Authority，聚合各服务 `GetHealth()` 输出。
- 各服务通过 `Emit`/`Count` 上报到自己的 category（`persistence` / `events` / `aura` 等）。
- `S.WarnOnce(key, message)`：聊天框一次性告警（用户可见）。
- `S.SafeChat(message)`：聊天框直接输出。

## 9. 共享服务层（services/，15 个）

| 服务 | 职责 |
|------|------|
| SkillMetadataV3 / BuffMetadataV3 | 技能/Buff id→名称/图标 解析（512 有界缓存 + 负缓存） |
| StatusClassificationV3 | Buff/Debuff 分类唯一 Authority |
| AuraObservationV3 | 玩家/目标 Aura 事实层（GetStatusMap/GetSnapshot） |
| UnitIdentityV3 | 单位身份归一（NormalizeUnitName） |
| CombatEventBusV3 | COMBAT_MSG/UNIT_DEAD 唯一 V3 战斗事实入口 |
| CombatAnalyticsV3 | 单 all-scope Consumer + Metric Registry |
| TeamRosterV3 / CombatRelationV3 | 团名册 / 战斗关系 |
| InstanceCatalogV3 / QuestProgressV3 | 副本目录 / 任务进度 |
| GearServiceV3 | 装备只读查询 |
| AlertsService | 共享短生命周期 Alert 状态 |
| ScreenProjectionV3 | 世界→屏幕投影（无自身 Tick） |
| AuctionQueryV3 | 拍卖查询（限速 + 单 pending） |

## 10. Feature 层结构

每个 Feature 遵循 `store / authority(or projection) / feature / acceptance` 四件套，由 `FeatureRuntime` 管理生命周期（`Initialize` / `Enable` / `Disable` 三方法契约）。

- `features/rs_feature_registry.lua`：Feature 元数据 Authority。
- `features/rs_feature_runtime.lua`：生命周期调度。
- Feature 只输出 `GetProjection()` + `Commands` facade；Presentation 只消费这两个，不直访 Store/Authority 内部。
- Demand 驱动：`Acquire(0→1)` 是初始读取唯一 Authority，`Release(1→0)` 必须释放事件/任务。

## 11. Presentation 层（presentation/v3/）

- `rs_v3_shell.lua` + `rs_v3_host.lua`：V3 主壳与 Host。
- `navigation/rs_v3_router.lua`：语义路由 Authority。
- `widgets/` / `modals/` / `pages/`：各 Feature 的 UI 承载。
- 构建经 `RSUI:WithBuildScope()`，非 `buildOptional` 组件失败即 fail-fast 回滚。
- 边界：Presentation 不得直连 `Feature.State/Authority`、`Store.State`、`X2Unit/X2Team`；必须走 Projection/Commands。

## 12. 红线（长期有效）

1. **禁止重新引入旧版逻辑/迁移桥**：不新建 ReadLegacy 类接口，不写"从旧存档迁移"的代码，不恢复 modules/ 下任何文件。
2. **toc.g 双向 0 差异**：新增文件必须登记 toc.g，删文件必须同步。
3. **持久化只用 `P:RegisterV3Store`**：schema 化 + 预算 + 自检；禁止绕过能力门直调未登记 X2 API。
4. **测试/调试脚本一律放 `.workbuddy/tmp/`**，绝不放插件树内。

## 13. 验证工作流（每轮改动必做）

1. 改动文件 `lua -e "loadfile(...)"` 语法检查（本机 lua 5.4.5）。
2. 回归测试 4 套全绿（`.workbuddy/tmp/`）：
   - `buff_display_persistence_713_test.lua`（13 断言）
   - `buff_display_refresh_cadence_test.lua`（8 断言）
   - `aura_name_resolution_test.lua`（11 断言）
   - `buff_metadata_service_test.lua`（8 断言）
3. toc.g ↔ 磁盘双向 0 差异对账。
4. 提交信息中文一行式，改完即 push。

## 14. 权威文档索引

| 文档 | 用途 |
|------|------|
| 本页 | 新人上手总览 |
| `Docs/CURRENT_ARCHITECTURE.md` | 架构落地条目（按版本号） |
| `Docs/CURRENT_REBUILD_STATUS.md` | 重建进度 |
| `Docs/CHANGELOG.md` | 变更记录（历史日志，不逐条回改） |
| `Docs/ENGINEERING_RULES.md` | 工程规则 |
| `Docs/Architecture/*.md` | 各域深度规范（注意：部分仍含旧架构描述，以本页 §12 红线为准） |
| `Docs/Rebuild/REBUILD_ROADMAP_LIFE_ECONOMY.md` | 12 个待重建服务路线表 |
| `Docs/Rebuild/REBUILD_BLUEPRINT.md` | 重建蓝图 |

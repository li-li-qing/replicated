# Buff Display Persistence Split Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** 将状态显示从反复损坏的 `v3.buff_display` 单体 Store 迁移到 settings/layout/tracking A/B + manifest，并让旧 Store 在迁移后永久只读。

**Architecture:** 旧 Store 只作为迁移输入；新 tracking 采用 player/target/meta 三组 A/B slot，全部 inactive slot durable 验证成功后才提交 manifest。HUD layout 继续使用已有独立 Store，settings 拆为小 Store。当前损坏旧档按已批准方案 A 用完整 target.auto 作为一次性 player.auto 基线。

**Tech Stack:** Lua 5.1, Replicated Suite Persistence v3, ArcheRage RU SaveData/LoadData

**Spec:** `Docs/superpowers/specs/2026-09-18-buff-display-persistence-split-design.md`

## Global Constraints
- 旧 `v3.buff_display` 迁移后禁止写入。
- Tracking 必须 inactive-slot durable verify 后再 commit manifest。
- 当前坏档只允许一次性 A 方案，禁止把 target twin 提升为常规 Authority。
- 不新增 Tick/后台扫描；迁移只在冷启动执行。
- 所有实际修改点必须有完整中文维护注释。

---

### Task 1: 新 Store 合同与测试红灯
**Files:**
- Modify: `features/combat/buff_display/rs_buff_display_store.lua`
- Create: `tools/rs_buff_persistence_split_tests.lua`

**Interfaces:**
- Produces: `F.SettingsStoreId`, `F.TrackingManifestStoreId`, `F.TrackingPersistenceContractVersion`

- [x] 写失败测试：旧 Store fenced 时可从 raw + target.auto 执行方案 A 迁移；迁移后旧 Store写次数保持0。
- [x] 写失败测试：tracking 提交只在 player/target/meta inactive slots 均 durable 成功后切 manifest。
- [x] 写失败测试：任一 inactive slot SaveData/readback 失败时 manifest 不变。
- [x] 运行测试确认 RED。

### Task 2: 注册 settings/tracking A/B/manifest Store
**Files:**
- Modify: `features/combat/buff_display/rs_buff_display_store.lua`

**Interfaces:**
- Produces: `EnsurePersistenceStoresRegistered`, `LoadTrackingAuthority`, `CommitTrackingSnapshot`

- [x] 注册 settings 小 Store。
- [x] 注册 player/target/meta A/B Stores。
- [x] 注册 manifest Store，默认 generation=0/slot=nil。
- [x] 加完整 Authority/数据流/风险维护注释。
- [x] 运行 Task 1 测试至 GREEN。

### Task 3: 一次性 Legacy 迁移与方案 A
**Files:**
- Modify: `features/combat/buff_display/rs_buff_display_store.lua`

**Interfaces:**
- Consumes: `P:DecodePhysicalEnvelope`, legacy main Store key
- Produces: `MigrateLegacyBuffDisplayOnce()`

- [x] 健康旧 Store优先使用已验证 Domain。
- [x] 旧 Store integrity_fenced 时直接只读 LoadData + DecodePhysicalEnvelope。
- [x] 若 target.auto 是完整 dense 列表而 player.auto 是 T5 残片，则仅在 manifest 未建立时按 A 复制 target.auto 到 player.auto。
- [x] 写 new stores，最后 commit manifest；失败不得改变旧 Store。
- [x] 运行迁移/拒绝测试。

### Task 4: Runtime Authority 切换与禁写旧 Store
**Files:**
- Modify: `features/combat/buff_display/rs_buff_display_store.lua`
- Modify: `features/combat/buff_display/rs_buff_display_acceptance.lua`
- Modify: `features/rs_feature_registry.lua`

**Interfaces:**
- `EnsureStoreLoaded()` 只依赖 new stores；legacy 仅在 manifest 缺失时迁移。
- tracking mutation -> `CommitTrackingSnapshot()`。
- non-layout settings mutation -> settings Store。

- [x] `SetTrackedChannel/SetTrackedId/ClearTrackedIds/Import` 等 tracking mutation 改为新 tracking commit。
- [x] classification/library/meta 按 Authority 写对应新 Store。
- [x] `MutateStore` 改为 settings Store 或标记 legacy 禁写。
- [x] Acceptance 检查新 Store contract。
- [x] Registry authority 文案更新。
- [x] 运行状态显示现有回归。

### Task 5: 版本、诊断、全量专项验证与交付
**Files:**
- Modify: `replicatedsuite.lua`
- Modify: `Docs/README.md`（仅新增持久化边界短节）

- [x] BuildTag 升级到 `.18.243-buff-persistence-sharded-authority`。
- [x] 诊断暴露 manifest slot/generation 与 legacyMigration 状态。
- [x] 运行 tracking、status、persistence、layout、self-check、report 专项测试。
- [x] 对全部 Lua 做语法静态扫描（若当前容器无 Lua 解释器，明确记录限制）。
- [x] 打包只含实际修改文件，保持相对路径。

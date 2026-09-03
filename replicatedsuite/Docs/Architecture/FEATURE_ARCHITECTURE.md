# Feature 架构（旧 Plates 已删除 · V3 对应物索引）

> **Authority Level**: ARCHITECTURE
> **状态**：旧 Plates 模块（`rp_api.lua` / `rp_manager.lua` / `rp_runtime.lua` / `rp_storage.lua` / `rp_ui.lua` / `rp_diagnostics.lua` / `replicatedplates.lua` 等）已于 2026-09-01 随旧版架构全量删除（commit 09010c0），不再随包。本文不再保留旧 Plates 架构描述。
> 新人上手见 [`../CURRENT_ARCHITECTURE.md`](../CURRENT_ARCHITECTURE.md)。

## 旧 Plates 能力的 V3 对应物

| 旧 Plates 职责 | V3 对应物 | 文件 |
|----------------|-----------|------|
| Buff/Debuff/Hidden 状态读取 | AuraObservationV3 | `services/rs_aura_observation_v3.lua` |
| Buff id→名称/图标解析 | BuffMetadataV3 | `services/rs_buff_metadata_v3.lua` |
| Buff 分类（buff/debuff） | StatusClassificationV3 | `services/rs_status_classification_v3.lua` |
| 头顶状态显示 | BuffHeadMarkersV3 | `presentation/v3/widgets/rs_v3_buff_head_markers.lua` |
| 状态追踪/布局/导入导出页面 | buff_display feature | `features/combat/buff_display/` |
| 重要冷却/魔法阵/目标装备 ID 集合 | GameDataRegistry 语义集合 | `data/ids/rs_plates_ids.lua` |
| 屏幕投影 | ScreenProjectionV3 | `services/rs_screen_projection_v3.lua` |
| 目标身份归一 | UnitIdentityV3 + NormalizeUnitName | `services/rs_unit_identity_v3.lua` / `core/rs_utils.lua` |

## Feature 契约（仍然有效）

- 每个 Feature 遵循 `store / authority(or projection) / feature / acceptance` 四件套。
- Feature 必须实现 `Initialize / Enable / Disable` 三方法契约（缺 Initialize 是静默报废式 bug）。
- Feature 只输出 `GetProjection()` + `Commands` facade；Presentation 只消费这两个。
- Demand 驱动：`Acquire(0→1)` 初始读取，`Release(1→0)` 释放事件/任务。
- Feature Registry（`features/rs_feature_registry.lua`）是 Feature 元数据 Authority。

## 已删除的旧 Feature 分类（仅记录，不恢复）

旧 `modules/professional/` 下四个专业模块（plates / healer / dps / gear）的旧实现已全部删除。它们的 V3 对应物分散在 `features/combat/` 与 `services/` 下，见上表与 [`HEALER_ARCHITECTURE.md`](HEALER_ARCHITECTURE.md)。

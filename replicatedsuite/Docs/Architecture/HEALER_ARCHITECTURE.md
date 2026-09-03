# Healer 架构（旧 Healer 模块已删除 · V3 对应物索引）

> **Authority Level**: ARCHITECTURE
> **状态**：旧 Healer 模块（`rh_settings_model.lua` / `rh_settings_migrations.lua` / `rh_settings_bootstrap.lua` / `rh_settings_store.lua` / `rh_settings_presenter.lua` / `rh_roster.lua` / `rh_status_cache.lua` / `rh_recommendation.lua` / `rh_runtime.lua` / `rh_api.lua` / `rh_ui_bridge.lua` / `rh_marker_presenter.lua` / `rh_raid_presenter.lua` / `rh_recommendation_list_presenter.lua` / `rh_buff_observer.lua` / `rh_config.lua` 等，原位于 `modules/professional/healer/`）已于 2026-09-01 随旧版架构全量删除（commit 09010c0），不再随包。本文不再保留旧 Healer 架构描述。
> 新人上手见 [`../CURRENT_ARCHITECTURE.md`](../CURRENT_ARCHITECTURE.md)。

## 旧 Healer 能力的 V3 对应物

| 旧 Healer 职责 | V3 对应物 | 文件 |
|----------------|-----------|------|
| 治疗设置持久化 | healer store | `features/combat/healer/rs_healer_store.lua` |
| 团队名册投影 | healer roster v3 | `features/combat/healer/rs_healer_roster_v3.lua` |
| 治疗推荐算法 | healer recommendation v3 | `features/combat/healer/rs_healer_recommendation_v3.lua` |
| Aura 消费桥接 | healer aura bridge | `features/combat/healer/rs_healer_aura_bridge.lua` |
| 生命值运行时 | healer health v3 | `features/combat/healer/rs_healer_health_v3.lua` |
| 屏幕投影 | healer screen projection | `features/combat/healer/rs_healer_screen_projection.lua` |
| Feature 生命周期 | healer feature | `features/combat/healer/rs_healer_feature.lua` |
| 头顶标记 | healer head marker widget | `presentation/v3/widgets/rs_v3_healer_head_marker.lua` |
| 团队覆盖层 | healer raid overlay widget | `presentation/v3/widgets/rs_v3_healer_raid_overlay.lua` |
| 治疗页面 | healer page | `presentation/v3/pages/rs_v3_healer_page.lua` |
| 验收契约 | healer acceptance | `features/combat/healer/rs_healer_acceptance.lua` |

## V3 Healer 关键契约（仍然有效）

- `combat_healer` 已注册 FeatureRuntime，Roster 复用 TeamRosterV3。
- Health/Status 由 Suite Scheduler 以 20/8 分片运行（每片最多 20 health / 8 status）。
- Recommendation 保持评分/规则/距离/滞回 Authority。
- Aura 共享事实不完整时只走准确性 fallback（AuraObservationV3:GetSnapshot + GetStatusMap）。
- V3 Page/Floating/Head Marker/Raid Overlay 全部只经 Feature Projection/Commands 取数。
- Head 的 50ms Visual Task 只做 Feature-side ScreenProjection + Diff。
- Raid 静态模式事件驱动且 4×25 槽位预分配，动态效果才建立 100ms 视觉任务。
- 高级编辑器通过同一 Store Command/Normalize/MarkDirty 写入。
- fresh 存档 head/raid enabled=false（安静默认），需用户手动开。

## Aura Lease 事务

- `EnableRuntime` 后续失败会释放 Aura lease。
- `DisableRuntime` 先释放 Aura，Release 失败不会继续伪装成功关闭。
- 运行诊断增加 shared accepted/fallback/error 与 bridge health。

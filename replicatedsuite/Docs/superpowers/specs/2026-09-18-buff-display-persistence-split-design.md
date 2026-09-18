# 状态显示持久化拆分设计（2026-09-18）

## 目标
彻底停止把 HUD/追踪/分类/窗口全部写回 `v3.buff_display` 单体大 Store。旧 Store 仅作为一次性迁移源；迁移完成后，运行时 Authority 分为 settings、layout、tracking 三类。对当前已损坏的 `player.auto` 采用用户确认的方案 A：以完整 `target.auto` 作为一次性迁移基线，不把该规则提升为通用运行时恢复。

## Authority
- `v3.buff_display.settings`：非 HUD、非 tracking 的小型永久配置与分类/库水位/窗口。
- `v3.buff_display.layout`：HUD 几何与显示策略。
- `v3.buff_display.tracking.player.a|b`：player 的 buff/debuff/auto。
- `v3.buff_display.tracking.target.a|b`：target 的 buff/debuff/auto。
- `v3.buff_display.tracking.meta.a|b`：trackedCooldowns 与 library.importedPacks/catalogVersion。
- `v3.buff_display.tracking.manifest`：唯一提交 Authority，记录当前激活 slot 与 generation。
- `v3.buff_display`：LegacyMigrationSourceOnly。新代码不得把任何用户修改写回此 Store。

## 数据流
首次启动若 manifest 不存在：读取旧 Store。若旧 Store健康则直接迁移；若当前已知损坏为 `player.auto` T5 前缀/中 token 截断且 target 完整，则按用户确认方案 A 使用 target.auto 作为 player.auto 基线。先写 inactive A/B tracking 三组并逐个 durable readback；全部成功后写 manifest；再写 settings/layout。Manifest 提交前任意失败都不改变 active generation。

后续启动：只加载 settings/layout/manifest 与 manifest 指向的 tracking slot。旧 Store 即使继续物理损坏也不参与运行时启动门禁。

## 安全边界
- 不根据 Hash 猜状态 ID。
- 不把 target 作为日常 player Authority；仅一次性迁移事故入口允许 A 方案。
- Tracking 写入采用 inactive slot -> durable verify -> manifest final commit。
- Manifest 不提交则旧 active slot 始终保持可靠。
- HUD 保存不得调用旧主 Store。
- 迁移完成后禁止自动清理旧 Store，保留取证与回退证据。

## 维护注释要求
所有新 Store 注册、迁移、A/B 提交、Authority 切换和旧 Store 禁写处必须写中文维护注释，至少包含：问题原因、Authority、数据流、兼容边界、实现理由、风险、禁止事项。

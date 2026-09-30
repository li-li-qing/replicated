# Docs 文件索引

> **2026-09-30 复核入口：**先读 `REFACTOR_REVIEW_2026-09-30.md`。本轮修复与待验项以该报告核对；长期施工合同仍是实际主规划，不要把旧 .329 开工提示当当前基线。

## 当前施工入口

- `WORKBUDDY_START_HERE.md`：Workbuddy / DeepSeek 启动入口。
- `Replicated_Suite_底层框架重构规划_v1.md`：当前唯一施工计划与边界合同。
- `README.md`：项目背景、架构与 Authority 说明。

## Phase 0 施工证据

- `PHASE0_BASELINE_REPORT_2026-09-28.md`
- `PHASE0_SECOND_ROUND_REPORT_2026-09-28.md`
- `PHASE0_THIRD_ROUND_REPORT_2026-09-28.md`
- `PHASE0_FOURTH_ROUND_NATIVE_DEPENDENCY_REPORT_2026-09-28.md`
- `PHASE0_FIFTH_ROUND_NATIVE_POLICY_REPORT_2026-09-28.md`
- `PHASE0_SIXTH_ROUND_BASELINE_CLOSURE_2026-09-28.md` ← **Phase 0 闭合报告（当前最新）**
- `TRADE_NATIVE_DEPENDENCY_FIX_2026-09-28.md`

这些报告是历史证据，不是新的施工 Authority。

## Phase 1 施工证据

- `PHASE1_BATCH_A_SLICE_REPORT_2026-09-28.md` ← **Batch A（工厂 + tools_social + tools_market_analysis）**
- `PHASE1_BATCH_B_SLICE_REPORT_2026-09-28.md` ← **Batch B（siege_readiness + reinforce_analysis + portal_profiles）**
- `PHASE1_BATCH_C_SLICE_REPORT_2026-09-28.md` ← **Batch C（boss_alerts + target_monitor + buff_cap + raid_recruitment）**
- `PHASE1_BATCH_D_SLICE_REPORT_2026-09-28.md` ← **Batch D（team_tools + craft + auction + SharedBounds）**
- `PHASE1_BATCH_E_AND_CLOSURE_REPORT_2026-09-28.md` ← **Batch E + Phase 1 闭合（bag + unit_lines + range_assist；bridge 退役）**

## Phase 2 施工证据

Phase 2（Life Bundle 拆分）的完整施工记录写在主规划文档 **§24.5（Step 1）与 §24.6（Step 2–4 与首轮闭合）**，
不另开重复文件。要点：

- Step 1 `life_treasure` + life 共享装配工厂 → §24.5
- Step 2 `life_fishing` → §24.6
- Step 3 `life_bonds` → §24.6
- Step 4 `life_trade` + `rs_life_m16_bundle.lua` 退役 → §24.6（含 §31 前后对照的真实 diff 证据）

## 兼容规划别名

- `Replicated_Suite_底层框架重构规划_v1.md` ← **实际存在于磁盘的 Authority 文件名**
- 历史压缩包遗留的 `Replicated_Suite_#U....md`（与上面同一份内容的兼容副本）

> 2026-09-30 复核修正：入口现已统一指向实际存在的主规划文件。原先带 `_Workbuddy执行版` 的文件名仅是错误引用，并不存在，不要再创建第二份施工 Authority。
> 本轮未修改主规划及兼容副本的内容；复核证据和当前待验项见 `REFACTOR_REVIEW_2026-09-30.md`。

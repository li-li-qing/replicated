# Replicated Suite 文档总入口

> 这是 `Docs/` 唯一可读入口。所有当前权威文档都在本页可直达；历史/审计/验证报告统一在 `Archive/`。

## 这个项目一句话

Replicated Suite 是 ArcheRage RU 客户端的一个公开 Addon（`globals` + `replicatedsuite` + `z_api_functions`），当前处于 **V3 重建（v3_rebuild）** 阶段：Active TOC 只加载单一 V3 Host；**旧版（Legacy/Professional）源码已于 2026-09-01/02 全部物理删除**（用户持有全量离线备份，插件树内绝不重新引入），在 ArcheAge 有限原生 UI API 之上继续建设 RSUI、共享 Runtime Foundation 与独立 Feature 生命周期。新人上手见 [`Architecture/CURRENT_ARCHITECTURE_OVERVIEW.md`](Architecture/CURRENT_ARCHITECTURE_OVERVIEW.md)。

## 文档权威等级（Authority Levels）

| 等级 | 含义 | 示例 |
|------|------|------|
| CURRENT | 当前状态/决策，日常以它为准 | `CURRENT_ARCHITECTURE.md`、`CURRENT_REBUILD_STATUS.md`、`CHANGELOG.md`、`ENGINEERING_RULES.md` |
| ARCHITECTURE | 已经确认的架构规范 | `Architecture/*.md` |
| REFERENCE | 静态数据/ID 权威查表 | `STATIC_DATA.md` |
| REBUILD | 重建方向性蓝图 | `Rebuild/REBUILD_BLUEPRINT.md` |
| HISTORICAL / GENERATED | 历史/审计/验证，仅追溯 | `Archive/` |

冲突解释顺序：`用户最新明确决定 → Foundation Decisions v2/更高 → 专项 Framework → Engineering Skill → v1/v1.1 规范 → 历史 Audit/Hotfix/Validation`。

## 日常管理只看这些（当前权威）

- **架构总览**：[`CURRENT_ARCHITECTURE.md`](CURRENT_ARCHITECTURE.md)
- **重建进度**：[`CURRENT_REBUILD_STATUS.md`](CURRENT_REBUILD_STATUS.md)
- **变更记录**：[`CHANGELOG.md`](CHANGELOG.md)
- **工程与文档规则**：[`ENGINEERING_RULES.md`](ENGINEERING_RULES.md)
- **静态 ID 权威**：[`STATIC_DATA.md`](STATIC_DATA.md)

## 架构细节（按域查）

- Core（产品/UI/HUD/Runtime/API/Foundation/Engineering）：[`Architecture/CORE_ARCHITECTURE.md`](Architecture/CORE_ARCHITECTURE.md)
- Native Foundation（Identity/Object Factory/Write Fence/Crash Guard）：[`Architecture/NATIVE_ARCHITECTURE.md`](Architecture/NATIVE_ARCHITECTURE.md)
- 服务（ServiceModule 生命周期/内置模块）：[`Architecture/SERVICE_ARCHITECTURE.md`](Architecture/SERVICE_ARCHITECTURE.md)
- 持久化（Lifetime/Store/Write Fence）：[`Architecture/PERSISTENCE_ARCHITECTURE.md`](Architecture/PERSISTENCE_ARCHITECTURE.md)
- RSUI（UMG 风格 Widget 基础层）：[`Architecture/RSUI_ARCHITECTURE.md`](Architecture/RSUI_ARCHITECTURE.md)
- Healer（Domain/Runtime/Glue/Roster/Settings）：[`Architecture/HEALER_ARCHITECTURE.md`](Architecture/HEALER_ARCHITECTURE.md)
- Combat Analytics（Encounter/Metric Registry/击杀/控制/乐器/Aura）：[`Architecture/COMBAT_ANALYTICS_ARCHITECTURE.md`](Architecture/COMBAT_ANALYTICS_ARCHITECTURE.md)
- Feature（分类契约 + 专业模块要点）：[`Architecture/FEATURE_ARCHITECTURE.md`](Architecture/FEATURE_ARCHITECTURE.md)

## 重建方向

- 重建蓝图：[`Rebuild/REBUILD_BLUEPRINT.md`](Rebuild/REBUILD_BLUEPRINT.md)
- 当前里程碑：[`Rebuild/CURRENT_MILESTONE.md`](Rebuild/CURRENT_MILESTONE.md)

## 历史追溯

- 审计/修复/验证报告：`Archive/`（按 `2026-08-15` / `2026-08-26` / `2026-08-27` / `Hotfixes` / `Validation` 组织）。

## 加载模型（新同学必读）

引擎按 **目录树 + `toc.g`** 加载 addon，**没有** `require` / `dofile` / `loadfile`。文件在顶层自行注册（如 `S.Services.Alerts = {...}`）。因此：**不要凭文件名猜测"孤儿文件"**——任何在 `toc.g` 或自注册路径上的 `.lua` 都可能是运行时责任；反过来说，磁盘上有但 `toc.g` 没有的 `.lua` 即死文件。

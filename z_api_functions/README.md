# z_api_functions — Developer API Reference / Evidence

> **定位**：开发者 API 参考与证据库，**不进入 Addon 运行时**。

## 这是什么

`z_api_functions/` 是 ArcheRage RU 客户端的 **API 参考与证据库**，供开发期核对原生 API 名称、签名、能力状态与控制台变量。**它不是插件运行时的一部分，也不被 `toc.g` 加载。**

- 它**不进入 Addon Runtime**，不参与加载模型（引擎按目录树 + `toc.g` 加载，`z_api_functions/` 不在 active TOC 中）。
- 它**不是旧 `globals/` 目录的替代或延续**——旧 `globals/` 与 Legacy/Professional 源码已于 2026-09-01/02 全部物理删除，不再随包。
- **绝对禁止**重新建立 `globals ↔ z_api_functions` 或 `z_api_functions ↔ globals` 这类旧架构依赖关系。

## 文件职责

| 文件 | 职责 |
|------|------|
| `api_functions.lua` | RU 客户端导出函数清单（client export manifest）= 官方 **Allowed** 列表；`Global variables` + `Allowed functions` 合集。判断某 Native API 是否「客户端已导出、可调用」以本文件为准。 |
| `ui_functions.lua` | UI API 参考（`Global variables` + `Allowed functions` for UI，如 Avi 等）。 |
| `console_vars.lua` | 控制台变量（console variables）参考：`REQUIRE_NET_SYNC` / `SAVEGAME` / `READONLY` 等命令与变量。 |
| `api_capabilities_ru_20260828.lua` | RU 官方公告叠加快照（status reflects official announcements），**最新且唯一保留在根目录**；记录 enabled/disabled/removed 与 cooldown / 签名歧义 / 核验备注。旧 `_20260815` / `_20260823` 已归档至 `Archive/`。 |
| `API_CHANGELOG_20260828.md` | API 参考变更日志，**最新且唯一保留在根目录**；旧 `_20260815` / `_20260823` 已归档至 `Archive/`。 |
| `Archive/api_capabilities_ru_20260815.lua` / `_20260823.lua` / `Archive/API_CHANGELOG_20260815.md` / `_20260823.md` / `Archive/VALIDATION_20260815.json` | 早期 API 快照 / 变更日志 / 静态校验输出（历史，归档不删除）。 |

## 与运行时 Authority 的关系

```text
z_api_functions/api_functions.lua           → 客户端已导出清单（Allowed）
z_api_functions/api_capabilities_ru_*.lua    → RU 官方能力快照（enabled/disabled/removed）
        ↓ 二者共同作为「API 是否可用」的官方判定来源
replicatedsuite/core/rs_api_capabilities.lua → Replicated Suite 真正 Runtime Capability Authority
        ↓ 所有 Native 调用必经能力门 S.Api:CallCapability
ArcheAge / ArcheRage RU Native API
```

- **真正的运行时能力权威是 `replicatedsuite/core/rs_api_capabilities.lua`**（gate `records` 表）。每个被调用的 API 必须在此登记，并经能力门（`S.Api:CallCapability`）调用；未登记的调用会被门阻断。
- `z_api_functions/` 仅用于**开发期核对签名与官方状态**，是「参考 / 证据」，不是运行时模块。

## API 可用性判定（官方方法）

某 RU Native API 可用 ⟺ 它出现在 `api_functions.lua`（**EXPORTED**）**且**不在 `api_capabilities_ru_20260828.lua` 的 disabled / removed 列表。

- 全 RU 当前仅 `X2Unit:GetUnitsInSight` 被官方 disabled（2026-08-19），`UNIT_ENTERED_SIGHT` / `UNIT_LEAVED_SIGHT` 被 removed。
- 参考项目（`供参考的项目/`）里的 `Unknown` 标法**不是 RU 禁用结论**；应以本库 + `rs_api_capabilities.lua` 登记为准，实机验证后改 `OfficialEnabled`。

## 红线

- `z_api_functions/` 不进 `toc.g`，不进运行时。
- 不把 `z_api_functions` 当成 `globals` 的延续或替代。
- 不重新接回任何旧 `globals/` / Legacy runtime / 迁移桥（ReadLegacy 等）。

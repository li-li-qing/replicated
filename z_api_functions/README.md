# z_api_functions — ArcheRage RU API Reference

> 开发期 API 参考 / 证据库。**不进入 Replicated Suite 运行时，也不应加入 `toc.g`。**

## 当前状态

- 维护日期：**2026-09-18**
- 已核对 ArcheRage RU 官方更新至：**2026-09-16**
- 最近一次影响 Addon API 权限的官方更新：**2026-09-09**
- Native API 分区：**83**
- Native Allowed 函数：**358**
- Native Available / not allowed 函数：**2331**
- UI API 分区：**44**
- UI Allowed 函数：**960**
- 当前已清除：同分区重复签名、Allowed / Not allowed 同时重复条目、过期历史快照

## 文件职责

| 文件 | 用途 | Authority |
|---|---|---|
| `api_functions.lua` | 客户端 Native API 导出参考；按 namespace 分为 `Global variables`、`Allowed functions`、`Available/not allowed functions` | 判断“客户端是否存在/导出” |
| `ui_functions.lua` | UI Widget / Drawable / EditBox 等 UI API 参考 | UI 接口签名参考 |
| `api_capabilities_ru.lua` | ArcheRage RU 官方公告能力覆盖层；记录 enabled / disabled / removed / restricted / cooldown | 判断“RU 服务器当前是否允许” |
| `console_vars.lua` | 客户端控制台变量原始参考 dump | 仅诊断研究，不是 Addon API allow-list |
| `API_CHANGELOG.md` | 本参考库的同步与清理记录、官方来源 | 维护记录 |
| `README.md` | 使用规则与判定方法 | 文档入口 |

## API 可用性判定

不要只看 `api_functions.lua` 的 `Allowed functions`。

正确判定：

```text
客户端导出/存在
    api_functions.lua
        +
RU 服务器公告状态
    api_capabilities_ru.lua
        ↓
Replicated Suite Runtime Capability Authority
    replicatedsuite/core/rs_api_capabilities.lua
        ↓
S.Api:CallCapability(...)
```

因此：

1. API 必须能在 `api_functions.lua` 中找到。
2. 再检查 `api_capabilities_ru.lua` 的 last-write-wins 状态。
3. `official_disabled` / `removed` 不得进入运行时调用。
4. `official_enabled_restricted` 必须遵守战斗限制 / cooldown 等约束。
5. `official_enabled` 仍不等于当前客户端已经完成项目内实机验证；关键路径继续通过 Runtime Capability Gate。

### 特殊例外：`X2Unit:GetUnitsInSight`

`X2Unit:GetUnitsInSight(unitOwner)` 仍存在于客户端导出参考中，但 ArcheRage RU 已在 **2026-08-19** 官方禁用。

所以：

```text
EXPORTED = true
SERVER_ENABLED = false
RUNTIME_CALL = forbidden
```

不要因为它还出现在 `api_functions.lua` 就直接调用。

`UNIT_ENTERED_SIGHT` / `UNIT_LEAVED_SIGHT` 同期被移除。

## 2026-09-09 新开放 API

以下三个函数已从 `Available/not allowed functions` 移到 `Allowed functions`：

```text
X2Faction:GetExpeditionMemberCount()
X2Quest:GetQuestJournalObjectiveCount(idx)
X2Quest:GetQuestJournalObjectiveText(idx, objIdx)
```

`api_capabilities_ru.lua` 已同步登记。

## 文件格式注意

`api_functions.lua`、`ui_functions.lua`、`console_vars.lua` 是**参考清单 / dump**，不是可执行 Lua 模块。保留 `.lua` 文件名是为了延续项目现有开发工作流和搜索路径，但严禁加入运行时加载链。

## 官方来源

当前同步窗口使用 ArcheRage RU 官方论坛更新：

- 2026-08-19  
  https://ru.archerage.to/forums/threads/obnovlenie-19-08-2026.17526/
- 2026-08-26  
  https://ru.archerage.to/forums/threads/obnovlenie-26-08-2026.17543/
- 2026-09-02  
  https://ru.archerage.to/forums/threads/obnovlenija-02-09-2026.17555/
- 2026-09-09  
  https://ru.archerage.to/forums/threads/obnovlenie-09-09-2026.17558/
- 2026-09-16  
  https://ru.archerage.to/forums/threads/obnovlenie-16-09-2026.17572/

其中 2026-09-02 与 2026-09-16 公告没有 Addon API 权限变更；2026-09-09 是当前最新的 API 权限变更。

## 清理策略

本版不再在发布目录保留日期快照 `Archive/`。历史状态已经由 `api_capabilities_ru.lua -> changes` 保存，重复的旧快照只会增加 AI / 人工检索噪声。

以后更新只维护稳定文件名：

```text
api_functions.lua
ui_functions.lua
api_capabilities_ru.lua
console_vars.lua
API_CHANGELOG.md
README.md
```

不要恢复 `api_functions2.lua`、旧日期 capability 副本或 `globals/` 桥接结构。

## Replicated Suite 维护红线

- `z_api_functions/` 永远只做开发证据库。
- Runtime 原生调用仍由 `replicatedsuite/core/rs_api_capabilities.lua` 统一控制。
- 禁止 Feature Module 绕过 `S.Api:CallCapability` 直接建立新的 Native 调用路径。
- 新增官方 API 时，先更新本目录，再更新 Runtime Capability Registry，最后通过实机验证提升为 runtime verified。
- 官方公告与 bundled signature 冲突时，不猜签名；保留已验证签名并在 capability note / changelog 中记录差异。

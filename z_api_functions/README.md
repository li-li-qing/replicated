# z_api_functions — ArcheRage RU API Reference

> 开发期 API 参考 / 证据库。**不进入 Replicated Suite 运行时，也不应加入 `toc.g`。**

## 当前状态

- 维护日期：**2026-09-18**
- 官方更新索引已检查至：**2026-09-16**
- 本轮可直接读取并逐条核对的最新更新正文：**2026-09-09**
- 最近一次已直接确认影响 Addon API 权限的官方更新：**2026-09-09**
- Native API 分区：**83**
- Native Allowed 函数：**358**
- Native Available / not allowed 函数：**2330**
- UI API 分区：**44**
- UI Allowed 函数：**956**
- 二次审计额外清理 `Drawable` 中残余的 `SetCoords` 同义重复和畸形 `SetSnap( used)`，保留规范签名。
- 当前已清除：同分区重复/语义重复签名、Allowed / Not allowed 同时重复条目、过期历史快照

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

## 2026-09-18 二次审计结论

### 当前最新 API 变动

2026-09-09 的官方 RU 更新正文已再次核对，仍然只有以下三个新增开放接口：

```text
X2Faction:GetExpeditionMemberCount()
X2Quest:GetQuestJournalObjectiveCount(idx)
X2Quest:GetQuestJournalObjectiveText(idx, objIdx)
```

当前 `api_functions.lua` 已全部放在对应 namespace 的 `Allowed functions` 中。

官方索引已经出现 **2026-09-16** 更新，但本轮联网工具暂时无法直接读取该帖正文；搜索索引也没有发现 `X2` / `Addon` 变更片段。因此本库继续保留 `latest_api_change = 2026-09-09`，同时在 capability 元数据中区分“看到最新官方更新”和“本轮已直接读取正文”，避免把未重新读取的正文写成硬证据。

### 补齐的历史能力链

二次审计发现旧版 `api_capabilities_ru.lua` 从 2025-04 到 2026-02 之间缺少多轮官方记录。已补入：

- 任务追踪 / 单位 ID 查询
- 拍卖搜索与最低价/市场价
- 战斗资源 / Craft 查询
- 9.5 新增的 Unit 世界坐标与 ADDON UI 注册接口
- ADDON 持久化 GetName / LoadData / SaveData / ClearData 及 2025-07-08 修复记录
- Hotkey / Skill cooldown / Mate cooldown
- WorldmapLocation 两次签名演进
- Mate 装备接口
- 10.0 的 `X2Resident:RefreshResidentMembers` / `GetResidentMembers`

这些 API 在当前 `api_functions.lua` 中原本就已经位于 `Allowed functions`；本轮主要修复的是 Authority 时间线，不改变当前导出清单。

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

2026-09-09 正文已在本轮再次直接核对。2026-09-16 更新已由官方索引确认存在，但本轮工具无法直接读取该帖正文；因此只把它记为“latest official update seen”，不把“正文无 API 变化”作为本轮独立验证结论。当前没有发现晚于 2026-09-09 的已确认 API 权限变化。

## 本轮补核的关键官方历史来源

- 2025-04-16：Quest tracking / `X2Unit:GetUnitInfoById`
- 2025-04-30：Ability / Auction Search / CombatResource / Craft / Quest
- 2025-05-07：Auction searched-item getters
- 2025-06-08：9.5 custom addon APIs
- 2025-07-01 / 07-08：ADDON 持久化接口与修复
- 2025-07-16：`GetUnitWorldPositionByTarget` 签名调整
- 2025-08-12 / 08-20：Auction price / Hotkey / Skill cooldown
- 2025-09-17：`SaveHotKey` / `GetMateCooldown`
- 2025-10-07：Hotkey binding conversion
- 2025-11-05 / 11-12：World map location 新增与签名调整
- 2025-12-03：Mate equipment APIs
- 2026-02-16：10.0 custom `X2Resident` APIs

详细状态以 `api_capabilities_ru.lua -> changes` 为准。

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

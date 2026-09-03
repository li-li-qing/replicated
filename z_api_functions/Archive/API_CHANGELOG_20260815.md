# ArcheRage RU `z_api_functions` 更新记录 — 2026-08-15

## 本次处理范围

- 更新 `api_functions.lua` 的 Allowed / Not Allowed 分类。
- 重新同步生成 `api_functions2.lua`，使其明确成为 `api_functions.lua` Allowed 区的精简索引。
- 新增 `api_capabilities_ru_20260815.lua`，记录官方启用日期、冷却、战斗限制、移除事件和已知歧义。
- 保留 `console_vars.lua`、`ui_functions.lua` 原样不动。
- 原始 `api_functions.lua` / `api_functions2.lua` 保存到 `snapshot_before_20260815_update/`。

## 重要原则

### 1. Official Enabled 不等于 Runtime Verified

官方公告确认开放后，本次会将函数移动到 Allowed；但能力表仍区分官方状态与项目实测状态。高风险 API 后续仍应以当前客户端实测为准。

### 2. `X2Bag:GetBagItemInfo` 参数差异

2024-11-12 官方曾明确公布 `X2Bag:GetBagItemInfo(bagId, slot)`；当前项目和 bundled reference 也使用此形式。2026-04-07 公告使用了 `GetBagItemInfo(slot)` 的简写。

本次 **不破坏已经验证的 `(bagId, slot)` 形式**。如果未来实测确认当前客户端同时存在其它 overload，再补 Registry，不在本次凭公告简写硬改签名。

### 3. Esc Menu 命名空间差异

2026-03-31 官方公告使用 `X2:AddEscMenuButton` / `X2:UpdateEscMenuButton` 的文字；当前 bundled API 和 Replicated 项目实际使用 `ADDON:AddEscMenuButton`。

本次保持项目兼容：

```text
ADDON:AddEscMenuButton(categoryId, uiContentType, iconKey, name)
ADDON:UpdateEscMenuButton(uiContentType, buttonValue, colorKey)
```

并在能力表记录命名空间歧义。`AddEscMenuButton` 的新增 config table 作为可选扩展能力记录，不删除已验证 4 参数调用。

### 4. 2026-06-09 视野事件变化

新增：

```text
X2Unit:GetUnitsInSight(unitOwner)
```

并新增 `UO_*` 类型常量。

同时官方移除：

```text
UNIT_ENTERED_SIGHT
UNIT_LEAVED_SIGHT
```

因此后续大型单位观察体系不能再把这两个事件当成长期可靠入口。

## 2026 官方 Addon 变更汇总

### 2026-02-24

开放 Team 移动、踢人和 TeamRole 查询。

### 2026-03-24

开放头顶 Marker 设置 / 清除 / 查询。

### 2026-03-31

开放 `IsReadyForCompleteQuest`；新增 Esc Menu 更新函数；扩展 AddEscMenuButton 配置。

### 2026-04-07

开放 Raid Recruit、Bag / Bank / GuildBank / Coffer 的部分物品读取接口。

### 2026-04-28

开放 EquipSlotReinforce 的 20 个查询接口，以及 Friend / Family / Faction 查询。

### 2026-05-12

开放 Bag/Bank/Coffer 移动物品、Capacity、修饰键状态和 Hotkey RemoveOptionBinding；修复两个 Reinforce 崩溃接口。

### 2026-05-19

修复四个 MoveToEmpty* 接口，解除需要打开银行/箱子窗口的限制，并将冷却降至 200ms；同时开放 BattleField 查询与 Squad 创建。

### 2026-05-26

开放 `X2World:GetCurrentWorldName()`；Bag / Bank / Coffer 的 GetBagItemInfo 返回信息新增 `category_id`。

### 2026-06-02

修复 CraftMaterialInfo 崩溃和部分 Bank/Bag 移动异常；开放 `X2Unit:UnitInfo`、`UnitModifierInfo`。

### 2026-06-09

开放 CraftTypeByItemType、PlayerInCombat、GetUnitsInSight；ChangeAppellation / EquipBagItem 改为战斗中不可使用；ChangeAppellation 冷却改为 2 秒；移除两个 Sight 事件。

### 2026-07-07

开放 Raid Recruit 聊天链接和 Raid Applicant 管理。

### 2026-07-14

开放 MakeTeamOwner；RaidRecruitDel 不再要求确认。

### 2026-07-21

开放 InviteToTeam。

### 2026-08-05

开放 Friend Block / Mute 查询与增删接口。

## 后续仍需 Runtime 验证

以下类型不能仅凭静态列表假设完全安全：

- 有冷却的写操作
- 战斗中受限 API
- 历史曾导致客户端崩溃的 API
- 公告与 bundled signature 不一致的 API
- `GetUnitsInSight` 的实际返回结构、200单位边界和 Unknown 行为
- UnitInfo / UnitModifierInfo 在不同对象类型上的返回差异

这些应进入后续 API Capability Registry + 游戏内安全采样流程。

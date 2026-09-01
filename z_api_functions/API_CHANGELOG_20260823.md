# ArcheRage RU `z_api_functions` 更新记录 — 2026-08-23

## 本次处理范围(2026-08-19 官方更新同步)

- 新建 `api_capabilities_ru_20260823.lua`(继承 2026-08-15 全部事实,last-write-wins;旧 `api_capabilities_ru_20260815.lua` 保留为历史快照,不覆盖)。
- `api_functions.lua` 的 X2House 区 Allowed 区补四个零参数签名。
- 运行时 Registry(`rs_api_capabilities.lua`)按 last-write-wins 同步。

## 官方 2026-08-19 变更(last-write-wins)

来源:https://ru.archerage.to/forums/threads/obnovlenie-19-08-2026.17526/

### 1. X2Unit:GetUnitsInSight → Disabled

- 2026-06-10 曾 Enabled;2026-08-19 官方重新 Disabled。
- 最终状态:**Disabled**。生产路径已全部删除,DPS Nearby 降级为目标+团队观察。
- Registry 保留 Disabled tombstone 防未来误接。

### 2. X2Hotkey 11 项 → 战斗限制

以下 11 项战斗中不可使用(combat_restricted=true):

```text
X2Hotkey:SaveHotKey
X2Hotkey:BindingToOption
X2Hotkey:OptionToBinding
X2Hotkey:RemoveOptionBinding
X2Hotkey:SetOptionBindingButtonWithIndex
X2Hotkey:SetOptionBindingWithIndex
X2Hotkey:EnableHotkey
X2Hotkey:SetBindingUiEvent
X2Hotkey:SetBindingUiEventWithIndex
X2Hotkey:SetOptionBindingUiEvent
X2Hotkey:SetOptionBindingUiEventWithIndex
```

- `X2Hotkey:GetOptionBinding` **不在**限制名单,仍是只读 getter。
- 项目生产使用的 4 个(BindingToOption/SetOptionBindingWithIndex/RemoveOptionBinding/SaveHotKey)Registry 已加 `Restrictions={ combat=true }`;钓鱼服务已加战斗门控(战斗中零写入,脱战恢复)。

### 3. X2House 4 项 → Enabled(零参数 getter)

```text
X2House:GetCurrentHousingTaxInfo()
X2House:GetHouseOwnerName()
X2House:GetHouseName()
X2House:GetHouseType()
```

- 静态清单 Allowed 区已补签名。
- Registry 仅作候选登记(OfficialEnabled/RuntimeState Unknown/SideEffectFree),未接任何业务,等待住宅旁真机只读验证。

### 4. sight 两事件继续 Removed

`UNIT_ENTERED_SIGHT` / `UNIT_LEAVED_SIGHT` 保持 Removed(2026-06-09)。

## 原则

- Official Enabled ≠ Runtime Verified:未验证 API 不进入关键路径。
- last-write-wins:同一 API 以最后公告为准;历史公告保留不覆盖。

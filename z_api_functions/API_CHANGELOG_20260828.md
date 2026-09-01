# ArcheRage RU `z_api_functions` 更新记录 — 2026-08-28

## 本次同步

权威来源：ArcheRage RU 官方更新 `Обновление 26.08.2026`。

官方新增 Allowed：

```text
X2Butler:GetChargeInfo()
X2Store:GetRandomShopStoreRefreshCount()
X2Input:GetMousePos()
```

处理：

- `api_functions.lua`：三项从 Available/not allowed 移入 Allowed。
- `api_functions2.lua`：同步 compact Allowed index。
- `api_capabilities_ru_20260828.lua`：继承 2026-08-23 snapshot，并追加 2026-08-26 last-write-wins 事实。
- 官方 Enabled 仍不等于 Runtime Verified；三项只登记为候选 capability，不自动进入高频或写入路径。
- `X2Input:GetMousePos()` 仅作为未来 RSUI 指针/交互诊断能力候选，不因此替换当前已经稳定的 Native drag transaction。

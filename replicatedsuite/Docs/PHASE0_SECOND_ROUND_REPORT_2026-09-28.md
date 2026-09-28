# Phase 0 第二轮基线恢复报告（2026-09-28）

基线：`v3-m1.16.0.18.326-trade-freshness-matrix-audit`

## 范围

本轮仍只处理测试/编译安全网，不进入 Phase 1，不修改 `toc.g`、Feature、Store Schema、Persistence、Scheduler、EventBus 或任何游戏运行时业务。

## 完成项

1. 新增 `tools/rs_test_dependency_audit.py`，递归扫描测试 Lua 的 literal `dofile/loadfile` 依赖。
2. `tools/rs_status_refactor_test_runner.py` 在 Full Runner 和 unfinished closure 执行前加入递归依赖门禁；缺历史 host/fixture 时在运行任何 suite 前一次性 BLOCKED。
3. 修正依赖审计边界：只追踪 Lua 文件，Python runner 内的动态 `{path}` 与库存字符串不再造成假缺失。
4. 恢复 `tools/rs_udf_numeric_test_host.lua` 当前契约 host；`rs_ranged_v4_migration_tests.lua` 实测 3/3 PASS。该 host 不声称是 2026-09-12 历史文件逐字节恢复。
5. 核对当前生产 Authority 后，更新 `tools/rs_status_refactor_tests.lua` 中明确已经过期的旧断言：
   - StatusTrackingCatalog 当前为 `425 effects / 14 trees / 463 skills`；
   - `.18.243` 后内置库导入是 `inactive player + inactive target + meta + manifest` 的四写 generation transaction；不能为了旧的“单次 SaveData”测试指标回退正确事务边界；
   - 当前一次 all import 的契约基线为 total 850，单 scope 为 auto 388 / buff 25 / debuff 12。
6. Install integrity 再验证：261/261 PASS、0 conflict。
7. Architecture Audit 再验证：49 个既有债务，未新增 runtime debt。
8. Lua 兼容语法：374 个 Lua 文件在现有 Lua 5.4 compatibility runtime PASS。

## 默认 Full Runner 当前真实阻断

```text
tools/fixtures/trade_native_numeric_20260912.lua
tools/rs_gear_page_test_host.lua
tools/rs_persistence_evidence_tests.lua
tools/rs_pvp_hud_test_host.lua
tools/rs_status_schema5_fixtures.lua
tools/rs_status_ui_test_host.lua
```

其中以下两项是历史证据资产，当前工程/可访问历史文件中没有原始内容，禁止根据断言反推伪造：

```text
tools/fixtures/trade_native_numeric_20260912.lua
tools/rs_status_schema5_fixtures.lua
```

后者是冻结的 `.208` schema5 golden；前者承载 2026-09-12 Trade numeric 实际快照及已知 fingerprint。没有原始字节就不能把对应恢复测试声明为可信 PASS。

## 仍未完成

- Full Regression：BLOCKED（6 个默认闭包依赖缺失）；
- Lua 5.1 Compile Gate：BLOCKED（当前环境无 `luac5.1/luac-5.1`）；
- `rs_hud_template_copy_test_host.lua` 仍缺失，但当前不属于默认 Full Runner 闭包；
- Phase 1 Business Bridge：未开始。

## 下一轮

优先恢复可由当前真实代码重建的测试 host：`rs_gear_page_test_host.lua`、`rs_status_ui_test_host.lua`、`rs_pvp_hud_test_host.lua`、`rs_persistence_evidence_tests.lua`。历史证据 fixture 继续寻找原始来源；找不到时保持明确 BLOCKED，不制造绿色。

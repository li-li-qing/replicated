# Phase 0 基线恢复报告（2026-09-28）

基线：`v3-m1.16.0.18.326-trade-freshness-matrix-audit`

## 已完成

1. 恢复默认 Full Runner 声明缺失的 16 个顶层 fixture 文件名，使 Runner 能越过第一层“required fixture missing”阻断并继续暴露真实后续故障。
2. 新增 `tools/rs_fixture_contract_helpers.lua`，恢复 fixture 仅用于离线契约核对，不进入 `toc.g`，不改变运行时 Authority。
3. 新增 `tools/rs_lua51_compile_gate.py`：只接受真实 `luac5.1/luac-5.1`，缺编译器时明确返回 BLOCKED(2)，绝不把 Lua 5.4 兼容语法检查冒充 Lua 5.1 发布门禁。
4. 新增 `tools/rs_architecture_audit.py`：当前先做债务库存，检查 Core→Feature、Presentation→Feature.State、>4000 行巨型文件、toc 重复/缺失。Phase 0 只把 toc 完整性作为 hard failure，其余已知债务先报告。
5. 验证 `tools/rs_check_installation.py .`：PASS，261/261 安装文件齐全，无冲突标记。
6. 验证 `python3 tools/rs_status_refactor_test_runner.py --syntax`：373 个 Lua 文件在现有 Lua 5.4 兼容环境语法加载 PASS；此结果不是 Lua 5.1 compile PASS。

## 当前仍阻断 Phase 0 完成的问题

默认 Full Runner 通过 16 个顶层缺失 fixture 后继续运行，暴露第二层基线损坏：

- 缺失历史测试依赖：
  - `tools/fixtures/trade_native_numeric_20260912.lua`
  - `tools/rs_gear_page_test_host.lua`
  - `tools/rs_hud_template_copy_test_host.lua`
  - `tools/rs_persistence_evidence_tests.lua`
  - `tools/rs_pvp_hud_test_host.lua`
  - `tools/rs_status_schema5_fixtures.lua`
  - `tools/rs_status_ui_test_host.lua`
  - `tools/rs_udf_numeric_test_host.lua`
- `tools/rs_status_refactor_tests.lua` 中至少存在与 18.326 当前数据/事务行为不一致的历史断言（例如 catalog 数量与 durable write 次数）。这些不能直接改成新数字，必须先确认当前 Authority 与历史测试意图后再更新。
- 当前施工环境无真实 Lua 5.1 编译器，因此 `tools/rs_lua51_compile_gate.py` 正确返回 BLOCKED；发布门禁尚未获得 PASS 证据。

## Architecture Audit 当前库存

本轮扫描得到 49 项已知债务（不视为本阶段新增回归）：

- Core 对具体 Feature 的直接读取仍集中在 `core/rs_foundation_gate.lua` 和部分 diagnostics；
- Presentation 仍存在 `Feature.State` 直读，其中 Auction Sidecar 是明确真实违规点；
- 巨型文件仍包括 `core/rs_persistence.lua`、`features/rs_business_bridge.lua`、`features/life/rs_life_m16_bundle.lua`；
- `toc.g` 当前无重复/缺失，因此 Architecture Audit 返回 PASS（债务库存模式）。

## 结论

Phase 0 **已开始但未完成**。当前不能进入 Phase 1 拆 Business Bridge，因为 Full Regression 与真实 Lua 5.1 compile gate 仍未达到 PASS。

下一轮仍应留在 Phase 0：先恢复 8 个间接 fixture/host，并逐项校正已漂移的历史断言，直到默认 Full Runner 真正执行到底；随后在具备 Lua 5.1 编译器的发布环境执行 compile gate。

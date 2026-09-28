# Replicated Suite Phase 0 第三轮基线恢复报告

日期：2026-09-28
基线：v3-m1.16.0.18.326-trade-freshness-matrix-audit
阶段：Phase 0（进行中）

## 1. 本轮冻结范围

本轮只恢复测试基础设施、校正已经被当前生产契约明确淘汰的历史测试假设，并推进离线回归闭包。

未修改发行运行时代码；未拆 Business Bridge；未修改 Persistence/Scheduler/EventBus 执行语义；未修改任何 Store ID、Schema、Feature ID、Route 或 Native 契约。

## 2. 已完成

### 2.1 恢复可由当前工程证明的 Test Host

恢复：

- `tools/rs_pvp_hud_test_host.lua`
- `tools/rs_status_ui_test_host.lua`
- `tools/rs_persistence_evidence_tests.lua`
- `tools/rs_gear_page_test_host.lua`

共享 Gear/Page host 补齐当前离线契约，包括 owner-first EventBus、Dispatch、内部取消订阅、Scheduler 任务、基础 Native Widget/ColorDrawable 与 UI 写入能力。

### 2.2 校正测试基础设施漂移

- `rs_status_capture_library_tests.lua`：EventBus mock 返回真实成功状态；目录/追踪计数改为从当前 Authority 动态读取，不再硬编码旧 397/794。
- `rs_library_runtime_contract_tests.lua`：同上，按当前目录 Authority 验证。
- `rs_craft_planner_tests.lua`：本地 WidgetHost mock 补齐当前 `BindFeatureLifecycle`。
- `rs_trade_tests.lua`：对齐当前 ratio fast-publish + 60ms deferred material projection、同路线 SWR refresh、raw/projection 分离等已经存在的生产契约；没有回退业务算法。
- `rs_auction_favorites_tests.lua`：对齐当前 Auction Search 无等级上限 `0/0`、FloatingSurface/WindowShell 契约、AskMarketPrice -> paced GetLowestPrice readback 报价协议和 Sidecar 生命周期。

## 3. 回归结果

### Unfinished Closure

`python3 tools/rs_status_refactor_test_runner.py --unfinished-closure`

PASS：14 个隔离 suite。

其中：

- Activities 16/16
- Bonds 23/23
- Craft Assist 8/8
- Trade 22/22
- Fishing 19/19
- Auction 20/20
- Team Tools 12/12
- Task/Bonds UI/Housing/Butler/Raid Readiness/Pending RU Navigation/Navigation Status 均通过

### Status / Diagnostics 专项

- `--capture-library`：34/34 PASS
- `--library-runtime`：23/23 PASS
- `--paged`：11/11 PASS
- `--focus`：27/27 PASS
- `--delivery`：33/33 PASS

### 静态/安装门禁

- `python3 tools/rs_check_installation.py .`：PASS，261/261，0 missing，0 conflict
- `--syntax`：PASS，378 Lua files（Lua 5.4 compatibility runtime，仅兼容语法检查）
- `rs_architecture_audit.py`：PASS（债务库存模式），49 个已知债务，无新增债务

## 4. 仍然 BLOCKED 的真实门禁

默认 Full Runner 当前只剩两个缺失的历史证据资产：

```text
tools/fixtures/trade_native_numeric_20260912.lua
  required by tools/rs_native_numeric_transport_tests.lua

tools/rs_status_schema5_fixtures.lua
  required by tools/rs_persistence_integrity_regressions.lua
  required by tools/rs_status_refactor_tests.lua
  required by tools/rs_window_numeric_recovery_tests.lua
```

这两个文件承载历史真实 snapshot/fingerprint/golden 证据。没有原始字节时不得从断言反推或造一个“能通过”的 fixture。

Lua 5.1 Compile Gate 仍 BLOCKED：当前施工环境不存在 `luac5.1/luac-5.1`。Lua 5.4 compatibility syntax PASS 不能替代发布级 Lua 5.1 compile。

## 5. 风险与兼容

本轮没有修改发行运行时代码，所以对游戏运行时 CPU、内存、Scheduler/EventBus/Native 调用频率没有影响。

用户升级兼容边界全部保持：Store ID/Schema、Feature ID、Route、配置结构均未改。

## 6. 阶段结论

Phase 0 仍为进行中，但测试基础设施已从“多层缺失 host + 大量旧契约漂移”收敛为两个不可伪造历史证据文件 + 一个真实 Lua 5.1 compiler 环境问题。

在这三个发布门禁解除前，不进入 Phase 1 Business Bridge 拆分。

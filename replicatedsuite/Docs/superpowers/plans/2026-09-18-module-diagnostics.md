# Module Diagnostics Infrastructure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为每个 Feature 页面提供独立模块诊断悬浮窗，并用完全隔离的 DiagnosticCopyBox 解决报告复制生命周期污染。

**Architecture:** `DiagnosticsManager` 保持全局 Authority；新增 `ModuleDiagnosticsHub` 做模块归属与按需快照；`PageHost` 发布 build context，DesignSystem 自动注入右上角诊断按钮；单一 `ModuleDiagnosticsWindowV3` 复用 FloatingSurface；专用 `DiagnosticCopyBox` 不进入普通输入/DraftSession 生命周期。

**Tech Stack:** Lua 5.1, Replicated Suite V3 Core/RSUI/FloatingSurface, existing ReportCopyTransport.

**Spec:** `Docs/superpowers/specs/2026-09-18-module-diagnostics-design.md`

## Global Constraints

- 禁止修改普通 EditBox / MultiEditBox / DraftSession 的现有输入语义来修复诊断复制。
- 模块诊断不得启动关闭中的 Feature，不得 Acquire Consumer。
- 翻页不得重新采集 Provider/Store/Feature 状态。
- 共享错误只有可证明归属时才能进入业务模块；其余留在 system。
- 所有新增/修改位置写中文维护注释，说明原因、Authority、数据流、兼容边界和风险。

---

### Task 1: ModuleDiagnosticsHub

**Files:**
- Create: `core/rs_module_diagnostics.lua`
- Modify: `core/rs_diagnostics.lua`
- Modify: `toc.g`
- Test: `tools/rs_module_diagnostics_tests.lua`

**Interfaces:**
- Produces: `S.ModuleDiagnosticsHub:Observe(entry)`, `RegisterProvider(moduleId,id,fn)`, `BuildReport(moduleId)`, `Capture(moduleId,capacity)`.
- Consumes: `FeatureRegistry`, `FeatureRuntime`, `Persistence`, `ReportCopyTransport` only on explicit capture where applicable.

- [x] Write failing tests for bounded module routing, unrelated-module isolation, disabled-feature no-start, Provider capture, Store filtering and immutable paging.
- [x] Run test and verify RED.
- [x] Implement bounded routing and report/capture API.
- [x] Hook `DiagnosticsManager:_Append()` to `Hub:Observe` without changing global event semantics.
- [x] Run tests and verify GREEN.

### Task 2: Dedicated DiagnosticCopyBox

**Files:**
- Create: `ui/framework/rs_ui_diagnostic_copy_box.lua`
- Modify: `toc.g`
- Test: `tools/rs_diagnostic_copy_box_tests.lua`

**Interfaces:**
- Produces: `S.UI:CreateDiagnosticCopyBox(spec)` returning controller with `SetPageText`, `Clear`, `Layout`, `Activate`, `Deactivate`, `GetDiagnostics`.
- Consumes: existing raw `CreateMultiEditBox`, `SafeHandler`, ownership/focus helpers; never `BindDeferredInputActivation` or DraftSession.

- [x] Write failing test reproducing delayed `OnLostFocus` followed by Ctrl+A/C copy loss.
- [x] Verify RED.
- [x] Implement read-only dedicated lifecycle and geometry diffing.
- [x] Add tests proving ordinary input binder is untouched and no delayed scheduler is registered.
- [x] Verify GREEN.

### Task 3: Shared Module Diagnostic Window

**Files:**
- Create: `presentation/v3/widgets/rs_v3_module_diagnostics_window.lua`
- Modify: `presentation/v3/rs_v3_aux_window_store.lua`
- Modify: `toc.g`
- Test: `tools/rs_module_diagnostics_window_tests.lua`

**Interfaces:**
- Produces: `S.UIV3.ModuleDiagnosticsWindowV3:Open(moduleId)`, `Generate()`, `ShowPage(index)`, `Close()`.
- Consumes: `ModuleDiagnosticsHub`, `DiagnosticCopyBox`, `FloatingSurface`, `AuxWindowStoreV3`.

- [x] Write failing tests for lazy open, no auto-capture, generate, stable previous/next paging, module switch reset and close deactivation.
- [x] Verify RED.
- [x] Implement one shared floating window and aux policy; if AuxWindow persistence is degraded, fail-open to Session-only window geometry so diagnostics remains usable.
- [x] Verify GREEN.

### Task 4: Automatic Page Header Diagnostics Entry

**Files:**
- Modify: `presentation/v3/shell/rs_v3_page_host.lua`
- Modify: `ui/design_system/rs_ui_design_system_v3.lua`
- Test: `tools/rs_module_diagnostics_header_tests.lua`

**Interfaces:**
- Produces: `PageHost:GetBuildContext()`; `PageHeader` auto-injects diagnostics button for current Feature.
- Consumes: `FeatureRegistry` metadata and `ModuleDiagnosticsWindowV3` at click time.

- [x] Write failing tests showing multiple feature pages get a right-side diagnostics button without per-page code.
- [x] Verify RED.
- [x] Add build-context fence and automatic PageHeader button.
- [x] Test protected/disabled/runtime-blocked pages do not start Feature and still open diagnostics.
- [x] Verify GREEN.

### Task 5: System Diagnostics Scope + Maintenance Gates

**Files:**
- Modify: `presentation/v3/pages/rs_v3_foundation_pages.lua`
- Modify: `Docs/README.md`
- Modify: `replicatedsuite.lua`
- Test: existing report/input tests + new module diagnostics tests.

**Interfaces:**
- System diagnostics remains available for Foundation/full self-check; module UI becomes default business fault workflow.

- [x] Update system diagnostics copy wording to direct business faults to module diagnostics; do not remove full maintenance report.
- [x] Update BuildTag and documentation.
- [x] Run dedicated module tests, ordinary input/report regression tests, Foundation/Persistence/Feature tests and Lua syntax/TOC audit.
- [x] Package only actually modified/new files preserving relative paths.

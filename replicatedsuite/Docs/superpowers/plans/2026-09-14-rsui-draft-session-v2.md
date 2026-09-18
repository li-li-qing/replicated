# RSUI DraftSession V2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Make RSUI explicit-confirm edit fields preserve user drafts across RU Native LostFocus and ambient high-frequency page refreshes until Apply/Enter/cancel.

**Architecture:** `TextInput` and `NumericInput` gain a Lua-owned DraftSession independent from Native focus. The weak DraftCoordinator tracks active sessions, suspends keyboard ownership when switching fields, and drives the existing page-level refresh fence. NumericField maps Apply-button fields to explicit commit mode and lets slider/step Authority changes supersede stale drafts.

**Tech Stack:** ArcheAge RU Lua 5.1, RSUI V3 component/binding system, existing Lua regression hosts and `texluac -p` syntax checks.

**Spec:** `docs/superpowers/specs/2026-09-14-rsui-draft-session-v2-design.md`

## Global Constraints

- No Persistence Store/schema changes.
- No new Tick or polling task.
- LostFocus for explicit fields must never write Authority or restore Authority text.
- Existing blur-commit fields keep legacy commit semantics.
- UnitLines/RangeAssist world rendering cadence remains unchanged.
- Every production change includes maintenance comments describing cause, Authority, data flow, compatibility boundary, implementation reason, and risk.

---

### Task 1: Shared DraftSession lifecycle

**Files:**
- Modify: `ui/framework/rs_ui_controls.lua`
- Test: `tools/rs_draft_session_v2_tests.lua`

**Interfaces:**
- Produces: `component:HasDraftSession()`, `component:SuspendEditing(reason)`, `RSUI:GetInputDraftSessionSnapshot()`.
- Keeps: `BeginEditing`, `EndEditing`, `CancelEditing`, `CommitAndEndEditing`, `GetDraftValue`, `IsEditing`.

- [x] **Step 1: Write failing lifecycle tests** covering explicit NumericInput LostFocus preservation, refocus recovery, explicit TextInput preservation, and switching fields without auto-commit.
- [x] **Step 2: Run `texlua tools/rs_draft_session_v2_tests.lua` and confirm failures come from missing DraftSession V2 behavior.**
- [x] **Step 3: Implement Lua-owned draft state and coordinator suspend semantics in `rs_ui_controls.lua`.**
- [x] **Step 4: Re-run the new tests until all pass.**

### Task 2: NumericField explicit Apply integration

**Files:**
- Modify: `ui/framework/rs_ui_forms.lua`
- Test: `tools/rs_draft_session_v2_tests.lua`
- Test: `tools/rs_visual_settings_input_tests.lua`

**Interfaces:**
- Consumes: `NumericInput:HasDraftSession`, `CommitAndEndEditing`, `CancelEditing`.
- Produces: Apply-button numeric fields use `draftCommitMode="explicit"`; slider/step commits supersede text drafts.

- [x] **Step 1: Add failing tests for blurred draft + Apply and slider superseding a pending text draft.**
- [x] **Step 2: Run the two targeted test files and verify RED.**
- [x] **Step 3: Pass explicit commit mode from NumericField and clear superseded drafts on slider/step Authority commits.**
- [x] **Step 4: Re-run targeted tests and verify GREEN.**

### Task 3: High-frequency visual-page fence uses draft lifetime

**Files:**
- Modify only if necessary: `presentation/v3/pages/rs_v3_business_pages.lua`
- Test: `tools/rs_visual_settings_input_tests.lua`

**Interfaces:**
- Consumes: `RSUI:HasActiveInputDraftWithin(root)`.
- Produces: UnitLines/RangeAssist ambient visual refresh remains fenced after Native blur while draft exists, then resumes after Apply/cancel.

- [x] **Step 1: Add a failing test that blurs a RangeAssist numeric field, waits in draft state, and verifies visual Refresh remains fenced.**
- [x] **Step 2: Run the visual settings test and verify RED.**
- [x] **Step 3: Update coordinator query/business-page fence only if the shared lifecycle change does not satisfy the test automatically.**
- [x] **Step 4: Verify the visual test suite passes.**

### Task 4: Diagnostics, Build tag, and regressions

**Files:**
- Modify: `replicatedsuite.lua`
- Modify: `core/rs_self_check_report.lua` if snapshot integration is needed.
- Test: existing input, Gear, Overview, business-page, self-check, navigation, and Python tool suites.

**Interfaces:**
- Produces: Build tag `.18.219-rsui-draft-session-v2` and read-only DraftSession diagnostics.

- [x] **Step 1: Add/verify DraftSession snapshot assertions.**
- [x] **Step 2: Update BuildTag and maintenance comments.**
- [x] **Step 3: Run `texluac -p` on every modified runtime Lua file.**
- [x] **Step 4: Run targeted and broad regression suites; separately report pre-existing missing-fixture failures instead of hiding them.**
- [x] **Step 5: Package only modified/new files preserving project-relative paths and verify archive contents byte-for-byte.**

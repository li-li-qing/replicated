#!/usr/bin/env python3
"""Static contract harness for RSUI keyboard-focus and drag-surface ownership.

The RU client has no headless Native Widget runtime in CI. This harness therefore
checks the cross-file invariants that previously regressed independently:
  * keyboard-capable primitives publish identity + parent ancestry before adopt;
  * UI Lifecycle clears only tracked Suite focus on hide/disable/pick loss;
  * teardown/hot reload permanently disarms old-generation input widgets;
  * Border forwards pickability and Windowing establishes drag hit-testing;
  * no unsupported generic keyboard event ABI is introduced.
"""
from __future__ import annotations

from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]


def read(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8-sig", errors="replace")


def block(source: str, start: str, end: str | None = None) -> str:
    pos = source.find(start)
    if pos < 0:
        return ""
    if end is None:
        return source[pos:]
    end_pos = source.find(end, pos + len(start))
    return source[pos:] if end_pos < 0 else source[pos:end_pos]


checks: list[tuple[str, bool]] = []


def check(name: str, condition: bool) -> None:
    checks.append((name, bool(condition)))


framework = read("ui/rs_ui_framework.lua")
primitives = read("ui/rs_ui_native_primitives.lua")
panels = read("ui/framework/rs_ui_panels.lua")
windowing = read("ui/framework/rs_ui_windowing.lua")
window_shell = read("ui/framework/rs_ui_window_shell_v3.lua")
component_core = read("ui/framework/rs_ui_component_core.lua")
app_shell = read("presentation/v3/rs_v3_shell.lua")
modal_host = read("presentation/v3/shell/rs_v3_modal_host.lua")
runtime = read("core/rs_runtime.lua")
bootstrap = read("replicatedsuite.lua")
foundation_gate = read("core/rs_foundation_gate.lua")
controls = read("ui/framework/rs_ui_controls.lua")
acceptance = read("presentation/v3/rs_v3_acceptance.lua")
buff_page = read("presentation/v3/pages/rs_v3_buff_display_page.lua")
data_views = read("ui/framework/rs_ui_data_views.lua")

# Primitive identity / registration.
check("native_contract_v6", "NativeInteractionContractVersion = 6" in primitives)
for fn in ("CreateEditBox", "CreateMultiEditBox"):
    body = block(primitives, f"function UIX:{fn}", "\nfunction UIX:")
    check(fn + "_marks_keyboard_input", "edit.rsUiKeyboardInput = true" in body)
    check(fn + "_publishes_parent", "edit.rsUiParent = stateParent" in body)
    check(fn + "_physical_anchor_state", "anchorTopLeft = { parent = stateParent" in body)
    register_pos = body.find("return self:Register(id, edit)")
    marker_pos = body.find("edit.rsUiKeyboardInput = true")
    check(fn + "_marker_before_register", marker_pos >= 0 and register_pos > marker_pos)
    check(fn + "_keyboard_starts_inert", 'CallNativeAccepted(edit, "EnableKeyboard", false)' in body)
    check(fn + "_publishes_inert_state", "edit.rsUiKeyboardArmed = false" in body)

editbox_body = block(primitives, "function UIX:CreateEditBox", "\nfunction UIX:")
check("editbox_preserves_enter_draft", 'CallNativeAccepted(edit, "ClearTextOnEnter", false)' in editbox_body)

# Lifecycle focus fence.
check("focus_contract_v2", "InputFocusLifecycleContractVersion = 2" in framework)
check("hidden_focus_contract_v2", "HiddenInputFocusIsolationContractVersion = 2" in framework)
check("deferred_keyboard_contract", "DeferredKeyboardActivationContractVersion = 1" in framework)
check("explicit_commit_focus_contract", "ExplicitInputCommitFocusContractVersion = 1" in framework)
check("tracked_physical_focus_map", "focusTargetsByPhysicalId" in framework)
check("bounded_ancestry", "MAX_INPUT_ANCESTRY_DEPTH = 32" in framework)
check("ancestry_stops_before_uiparent", 'current ~= UIParent and current ~= "UIParent"' in framework)
check("subtree_fast_gate", "rsUiKeyboardInputSubtreeCount" in framework)
check("adopt_registers_input", "RegisterInputTarget(widget)" in block(framework, "function UI:AdoptWidget", "\nfunction UI:"))
register_input = block(framework, "local function RegisterInputTarget", "\nlocal function UnregisterInputTarget")
check("register_rearms_retire_marker", "rsUiInputLifecycleRetired = false" in register_input)
check("release_owner_retires_input", "self:RetireInputWidget(widget" in block(framework, "function UI:ReleaseOwner", "\nfunction UI:"))
check("component_release_bridge", "InputLifecycleBridgeContractVersion = 1" in component_core and "UI:RetireInputWidget(self.root" in component_core)

release_focus = block(framework, "function UI:ReleaseFocusWithin", "\nfunction UI:")
check("focus_only_tracked_suite_target", "lifecycle.focusTargetsByPhysicalId[focusedId]" in release_focus)
check("focus_descendant_proof", "FocusedInputDescendsFrom" in release_focus)
check("focus_clear_verified", "afterId" in release_focus and "focus_retained" in release_focus)
deactivate_input = block(framework, "function UI:DeactivateInputWidget", "\nfunction UI:")
check("explicit_commit_releases_tracked_focus", "self:ReleaseFocusWithin(widget" in deactivate_input)
check("explicit_commit_disarms_keyboard", "self:DisarmInputWidget(widget" in deactivate_input)

# Critical regression: cleanup must run before Ensure* cache early-return.
for fn, token in (
    ("EnsureVisible", 'self:ReleaseFocusWithin(widget, owner, "visibility_hide_ensure")'),
    ("EnsureEnabled", 'self:ReleaseFocusWithin(widget, owner, "enabled_false_ensure")'),
    ("EnsurePickable", 'self:ReleaseFocusWithin(widget, owner, "pickable_false_ensure")'),
):
    body = block(framework, f"function UI:{fn}", "\nfunction UI:")
    clean = body.find(token)
    cache = body.find("if row.")
    check(fn + "_cleanup_before_cache_hit", clean >= 0 and cache > clean)

retire = block(framework, "function UI:RetireInputWidget", "\nfunction UI:")
check("retire_disables_keyboard", "self:DisarmInputWidget(widget" in retire and "widget:EnableFocus(false)" in retire)
check("retire_idempotent", "rsUiInputLifecycleRetired == true" in retire and "rsUiInputLifecycleRetired = true" in retire)
check("retire_unregisters", "UnregisterInputTarget(widget)" in retire)
check("quiesce_available", "function UI:QuiesceKeyboardInput(reason, retire)" in framework)
check("explicit_arm_api", "function UI:ArmInputWidget(widget, owner, reason)" in framework)
check("explicit_disarm_api", "function UI:DisarmInputWidget(widget, owner, reason)" in framework)
check("explicit_activate_api", "function UI:ActivateInputWidget(widget, owner, reason)" in framework)
check("subtree_disarm_api", "function UI:DisarmInputWithin(widget, owner, reason)" in framework)
check("raw_multiline_activation_api", "function UI:BindDeferredInputActivation(widget, owner, label)" in framework)
check("text_input_activates_on_click", 'c:RequireOn(edit, "OnClick", function() return c:BeginEditing("text_input_click") end' in controls)
check("text_input_disarms_on_lost_focus", 'c:EndEditing("text_input_lost_focus")' in controls)
check("interactive_draft_v3", "InteractiveDraftContractVersion = 3" in controls and "InputDraftCommitContractVersion = 1" in controls)
check("text_enter_commits_and_ends", 'return c:CommitAndEndEditing("enter")' in block(controls, 'RSUI:RegisterType("TextInput"', 'RSUI:RegisterType("NumericInput"'))
check("numeric_input_activates_on_click", 'c:RequireOn(edit, "OnClick", function() return c:BeginEditing("numeric_input_click") end' in controls)
check("numeric_input_disarms_on_lost_focus", 'c:EndEditing("numeric_input_lost_focus")' in controls)
check("numeric_enter_commits_and_ends", 'return c:CommitAndEndEditing("enter")' in block(controls, 'RSUI:RegisterType("NumericInput"', 'RSUI:RegisterType("Slider"'))
check("multiline_uses_deferred_activation", "BindDeferredInputActivation(transferEdit" in buff_page)
check("multiline_fails_closed_on_activation_error", "RetireInputWidget(transferEdit" in buff_page and "transferEditAvailable = false" in buff_page)
check("runtime_stop_quiesces", 'S.UI:QuiesceKeyboardInput("runtime_stop", false)' in runtime)
check("runtime_ready_quiesces", 'S.UI:QuiesceKeyboardInput("runtime_ready", false)' in runtime)
check("bootstrap_retires_previous_generation", 'previousUI:QuiesceKeyboardInput("bootstrap_hot_reload", true)' in bootstrap)

# Border / drag interaction ownership.
check("border_forward_contract", "BorderInteractionForwardingContractVersion = 1" in panels)
check("border_click_action_contract", "BorderClickActionContractVersion = 1" in panels)
border = block(panels, 'RSUI:RegisterType("Border"', '\nRSUI:RegisterType(')
check("border_forwards_pickable", "pickable=spec.pickable == true" in border)
check("border_forwards_owner", "owner=spec.owner" in border)
check("border_public_click_action", "function c:SetOnClick(fn)" in border and "function c:Click(" in border)
check("border_internal_bind_only", 'c:RequireOn(root, "OnClick", function(...) return c:Click(...)' in border)
check("modal_scrim_uses_public_action", "self.scrim:SetOnClick(function()" in modal_host)
check("modal_scrim_no_raw_requireon", ":RequireOn(" not in modal_host)
check("main_shell_requests_pickable_topbar", re.search(r'id\s*=\s*"v3_shell_top_bar".*?pickable\s*=\s*true', app_shell, re.S) is not None)
check("generic_shell_requests_pickable_titlebar", re.search(r'shell\.titleBar\s*=\s*RSUI:Border\(\{.*?pickable\s*=\s*true', window_shell, re.S) is not None)
check("modal_scrim_requests_pickable", re.search(r'id\s*=\s*"v3_modal_scrim".*?pickable\s*=\s*true', modal_host, re.S) is not None)
check("windowing_v18", "RSUI.Windowing.version = 18" in windowing)
check("windowing_hit_test_contract", "DragSurfaceHitTestContractVersion = 1" in windowing)
attach = block(windowing, "function W:Attach", "\nfunction W:")
handle_pick = attach.find("UI:EnsurePickable(dragHandle, true, owner)")
enable_drag = attach.find('UI:TryInteractionCall(dragHandle, "EnableDrag", true)')
condition = attach.find('UI:TryInteractionCall(dragHandle, "SetDragCondition", DC_ALWAYS)')
check("windowing_ensures_enabled", "UI:EnsureEnabled(dragHandle, true, owner)" in attach)
check("windowing_pickable_before_drag", handle_pick >= 0 and enable_drag > handle_pick)
check("windowing_drag_condition_after_enable", condition > enable_drag >= 0)

# Table resize preview must remain the only visible geometry Authority while a
# drag is active; ambient Layout cannot repaint committed widths in between the
# 16ms interactive samples. Newly rebound pooled rows inherit that same preview.
check("table_resize_preview_authority_contract", "DataViewResizePreviewAuthorityContractVersion = 1" in data_views)
check("table_layout_prefers_preview", 'local previewActive = type(self.previewResolvedWidths) == "table"' in data_views and 'widths = self.previewResolvedWidths' in data_views)
check("table_layout_solver_only_when_not_preview", re.search(r'if previewActive then\s+widths = self\.previewResolvedWidths\s+else\s+widths, resolvedOverflow, compressed, emergencyClamp = ResolveColumnWidths\(self\.columns, columnW, self\.columnGap\)', data_views) is not None)
check("table_rows_keep_preview_during_rebind", 'row:SetResolvedWidths(c.previewResolvedWidths or c.resolvedWidths, c.previewResolvedWidths ~= nil)' in data_views)

# Foundation gate must reject future regressions.
gate_match = re.search(r"S\.FoundationGate\s*=\s*\{\s*version\s*=\s*(\d+)", foundation_gate, re.S)
check("gate_v113_plus", gate_match is not None and int(gate_match.group(1)) >= 113)
check("gate_input_focus_drag", '"v3_input_focus_drag_foundation_contract"' in foundation_gate)
check("gate_native_v6", "NativeInteractionContractVersion) or 0) >= 6" in foundation_gate)
check("gate_drag_hit_test", "DragSurfaceHitTestContractVersion) or 0) >= 1" in foundation_gate)

# Unsupported generic key handlers remain forbidden in active Lua. Comments are
# removed before scanning so architecture documentation text does not false-hit.
forbidden_refs: list[str] = []
for path in ROOT.rglob("*.lua"):
    rel = path.relative_to(ROOT).as_posix()
    if rel.startswith("Docs/") or "/Archive/" in rel:
        continue
    src = path.read_text(encoding="utf-8-sig", errors="replace")
    code = re.sub(r"--\[\[.*?\]\]", "", src, flags=re.S)
    code = re.sub(r"--[^\n]*", "", code)
    if re.search(r'["\']On(?:KeyDown|KeyUp|TextChanged|Char)["\']', code):
        forbidden_refs.append(rel)
check("no_unverified_generic_key_events", not forbidden_refs)

# Failed composite/page construction must never leave a half-built Native input
# or hit-test surface alive after transaction rollback.
rollback = block(component_core, "local function RollbackBuildScope", "function RSUI:EndBuildScope")
check("build_scope_v4", "BuildScopeContractVersion = 4" in component_core)
check("build_transaction_v2", "BuildTransactionContractVersion = 2" in component_core)
check("rollback_input_quiescence_contract", "BuildRollbackInputQuiescenceContractVersion = 1" in component_core)
check("rollback_retires_raw_inputs", 'UI:RetireInputWidget(widget, owner, "build_scope_rollback")' in rollback)
check("rollback_disables_pick", "UI:SetPickable(widget, false, owner)" in rollback)
check("rollback_disables_widget", "UI:SetEnabled(widget, false, owner)" in rollback)
check("rollback_hides_widget", "UI:SetVisible(widget, false, owner)" in rollback)
check("foundation_requires_rollback_input", "BuildRollbackInputQuiescenceContractVersion" in foundation_gate)
check("acceptance_requires_rollback_input", "BuildRollbackInputQuiescenceContractVersion" in acceptance)

# ColorField must use ButtonActionContract for its nested Done button. It is a
# Component, not a Native widget, so passing it to RequireOn always fails.
colorfield = block(controls, 'RSUI:RegisterType("ColorField"', '\nend)')
check("colorfield_done_component_action", 'onClick = function() return c:Close() end' in colorfield)
check("colorfield_no_component_requireon", 'c:RequireOn(doneBtn, "OnClick"' not in colorfield)
check("colorfield_mouse_only", 'RSUI:TextInput({ id = spec.id .. "_hex"' not in colorfield and 'id = spec.id .. "_hex_value"' in colorfield)

# Popup hit-test quiescence: hidden popups must be explicitly unpicked, and
# every open path must re-pick before showing. This keeps an invisible surface
# from ever intercepting input even if native hidden-hit-test semantics change.
dropdown = block(controls, 'RSUI.DropdownContractVersion = 2', 'RSUI:RegisterType("ColorField"')
check("popup_quiescence_contract", "RSUI.PopupHitTestQuiescenceContractVersion = 1" in controls)
# Anchor on the fail-closed detail tokens: they only exist in the real (non
# degraded stub) Open/Close implementations.
check("dropdown_open_repicks", "dropdown_popup_repick_failed:" in dropdown)
check("dropdown_close_unpicks", "dropdown_popup_unpick_failed:" in dropdown)
colorfield_popup = block(controls, 'RSUI:RegisterType("ColorField"', '\nend)')
check("colorfield_open_repicks", "colorfield_popup_repick_failed:" in colorfield_popup)
check("colorfield_close_unpicks", "colorfield_popup_unpick_failed:" in colorfield_popup)
interactions = read("ui/framework/rs_ui_interactions.lua")
context_menu = block(interactions, "function ContextMenu:Open", "function ContextMenu:Close")
check("context_menu_open_repicks", "context_menu_repick_failed:" in context_menu)
check("context_menu_close_unpicks", "context_menu_unpick_failed:" in interactions)

failed = [name for name, ok in checks if not ok]
if failed:
    print(f"INPUT_FOCUS_DRAG_HARNESS FAIL {len(checks)-len(failed)}/{len(checks)}")
    for name in failed:
        print("FAIL |", name)
    if forbidden_refs:
        for rel in forbidden_refs[:12]:
            print("FORBIDDEN |", rel)
    sys.exit(1)

print(f"INPUT_FOCUS_DRAG_HARNESS PASS {len(checks)}/{len(checks)}")

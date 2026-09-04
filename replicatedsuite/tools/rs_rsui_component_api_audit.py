#!/usr/bin/env python3
"""Static RSUI component API usage audit for Presentation code.

This gate targets a failure class Lua syntax cannot catch: a component is built
successfully, then a page/workspace calls a method that is not part of that
component's public contract (for example Button:Show before Show belonged to the
common Base contract).  Such errors otherwise survive parse-only checks and fail
only when a user opens the page in the RU client.

The scanner deliberately stays high-signal:
* only variables whose nearest assignment is a known RSUI component constructor
  are checked;
* common Base methods are extracted from rs_ui_component_core.lua;
* type-specific methods used by Presentation are an explicit reviewed contract;
* guarded capability calls (type(x.Method) == "function") remain valid for
  degraded/fallback controls.

It is a developer-only package gate and is not loaded by toc.g.
"""
from __future__ import annotations

import argparse
import re
from dataclasses import dataclass
from pathlib import Path

DEFAULT_ROOT = Path(__file__).resolve().parents[1]

# Public type-specific surface actually allowed to be consumed by Presentation.
# Common lifecycle/layout/visibility methods come from Base and are extracted
# from the runtime source, so this table does not duplicate those APIs.
TYPE_METHODS: dict[str, set[str]] = {
    "Text": {"SetText", "SetTone", "SetFontSize"},
    "Button": {"SetText", "SetSelected", "Click"},
    "IconButton": {"SetText", "SetSelected", "SetIcon", "Click"},
    "ScrollBox": {"GetScrollableEntries", "ScrollBy", "SetScrollOffset", "GetScrollOffset"},
    "ListView": {
        "SetItems", "RefreshVisible", "SetViewState", "GetItem", "GetItemCount", "GetItemKey",
        "GetSelectionModel", "GetSelectedIndex", "SetSelectedIndex", "ClearSelection",
        "ScrollToTop", "EnsureIndexVisible",
    },
    "TableView": {
        "SetItems", "RefreshVisible", "SetViewState", "GetItem", "GetItemCount", "GetItemKey",
        "GetSelectionModel", "GetSelectedIndex", "SetSelectedIndex", "ClearSelection",
        "ScrollToTop", "EnsureIndexVisible",
    },
    "Dropdown": {"SetItems", "GetValue", "SetValue", "SetSelectedValue", "Open", "Close", "ToggleOpen", "Scroll"},
    "TextInput": {"GetDraftValue", "GetValue", "SetValue", "Submit", "Commit", "IsEditing", "IsInteracting"},
    "NumericInput": {"GetDraftValue", "GetValue", "SetValue", "Submit", "Commit", "IsEditing", "IsInteracting"},
    "Slider": {"GetValue", "SetValue", "Preview", "CommitValue", "IsInteracting"},
    "WidgetSwitcher": {"SetActiveIndex", "SetActiveWidget", "GetActiveIndex", "GetActiveWidget"},
    "TreeView": {"SetSelectedKey", "SetNodes", "SetExpanded", "ToggleExpanded", "ExpandAll", "CollapseAll", "EnsureKeyVisible", "GetVisibleRows"},
    "StatusChip": {"SetStatus"},
    "TransformInspector": {"SetModels", "SetEnabled", "GetSnapshot"},
    "EditorCommandBar": {"Execute", "GetSnapshot"},
    "ResponsiveInspector": {"GetMode", "IsDrawerOpen", "SetDrawerOpen", "ToggleDrawer", "SetInspectorWidth", "GetResponsiveSnapshot"},
    # Workspace facade, not a registered component type, but it is returned by a
    # public RSUI constructor and consumed by pages exactly like one.
    "CreateLayoutEditorWorkspace": {
        "SetDrawerOpen", "ToggleDrawer", "GetMode", "GetHistoryModel", "GetSessionModel",
        "GetCommandBar", "ExecuteCommand", "RebaseEditSession", "RefreshFromSource", "GetSnapshot", "Release",
    },
    # These controls currently expose no Presentation-specific API beyond Base
    # (Render is also a Base method). Keeping them explicit makes constructor
    # recognition intentional rather than silently skipping them.
    "Toggle": set(),
    "SegmentedSelector": set(),
    "NumericField": set(),
    "DropdownField": set(),
    "HorizontalBox": set(),
    "VerticalBox": set(),
    "Overlay": set(),
    "Border": set(),
    "GroupBox": set(),
    "UniformGrid": set(),
    "SplitView": set(),
}

ASSIGN_RE = re.compile(
    r"\b(?:local\s+)?([A-Za-z_]\w*)\s*(?:,\s*[A-Za-z_]\w*)?\s*=\s*RSUI:([A-Z][A-Za-z0-9_]*)\s*\("
)
CALL_RE = re.compile(r"\b([A-Za-z_]\w*):([A-Za-z_]\w*)\s*\(")
BASE_METHOD_RE = re.compile(r"^\s*function\s+Base:([A-Za-z_]\w*)\s*\(", re.M)


@dataclass(frozen=True)
class Assignment:
    position: int
    line: int
    var: str
    kind: str


def line_for(text: str, pos: int) -> int:
    return text.count("\n", 0, pos) + 1


def strip_comments_preserve_lines(text: str) -> str:
    text = re.sub(r"--\[\[.*?\]\]", lambda m: "\n" * m.group(0).count("\n"), text, flags=re.S)
    return re.sub(r"--[^\n]*", "", text)


def guarded_capability(lines: list[str], line_no: int, var: str, method: str) -> bool:
    # Look at the current and four preceding source lines. This covers both
    # inline guards and the fail-closed idiom:
    #   if type(x.Submit) ~= "function" then return ... end
    #   return x:Submit(...)
    start = max(0, line_no - 5)
    window = "\n".join(lines[start:line_no])
    escaped = rf"{re.escape(var)}\s*\.\s*{re.escape(method)}"
    if re.search(rf"type\s*\(\s*{escaped}\s*\)\s*(?:==|~=)\s*[\"']function[\"']", window):
        return True
    if re.search(rf"{escaped}\s*~=\s*nil", window):
        return True
    return False


def audit(root: Path) -> tuple[list[str], dict[str, int]]:
    core = root / "ui/framework/rs_ui_component_core.lua"
    if not core.is_file():
        return ["component core missing: ui/framework/rs_ui_component_core.lua"], {}
    core_source = core.read_text(encoding="utf-8-sig", errors="replace")
    base_methods = set(BASE_METHOD_RE.findall(core_source))
    required_base = {"SetVisible", "Show", "Hide", "SetEnabled", "SetVisibility", "Render", "Release", "On"}
    missing_base = sorted(required_base - base_methods)
    failures: list[str] = []
    if missing_base:
        failures.append("common Base API missing: " + ",".join(missing_base))

    files = sorted((root / "presentation/v3").rglob("*.lua"))
    files_scanned = assignments_seen = calls_checked = guarded_calls = 0
    for path in files:
        original = path.read_text(encoding="utf-8-sig", errors="replace")
        text = strip_comments_preserve_lines(original)
        lines = text.splitlines()
        assignments_by_var: dict[str, list[Assignment]] = {}
        for match in ASSIGN_RE.finditer(text):
            kind = match.group(2)
            if kind not in TYPE_METHODS:
                continue
            item = Assignment(match.start(), line_for(text, match.start()), match.group(1), kind)
            assignments_by_var.setdefault(item.var, []).append(item)
            assignments_seen += 1
        if not assignments_by_var:
            continue
        files_scanned += 1
        for match in CALL_RE.finditer(text):
            var, method = match.group(1), match.group(2)
            candidates = assignments_by_var.get(var)
            if not candidates:
                continue
            # Nearest preceding constructor assignment is the best lightweight
            # approximation of Lua lexical scope and handles fallback replacement
            # (TextInput -> Text) without requiring a full Lua parser.
            prior = [item for item in candidates if item.position < match.start()]
            if not prior:
                continue
            assignment = prior[-1]
            calls_checked += 1
            if method in base_methods or method in TYPE_METHODS[assignment.kind]:
                continue
            call_line = line_for(text, match.start())
            if guarded_capability(lines, call_line, var, method):
                guarded_calls += 1
                continue
            rel = path.relative_to(root).as_posix()
            failures.append(
                f"unguarded component API call {rel}:{call_line} {var}:{assignment.kind}:{method} "
                f"(constructed at line {assignment.line})"
            )

    metrics = {
        "files": files_scanned,
        "assignments": assignments_seen,
        "calls": calls_checked,
        "guarded": guarded_calls,
        "baseMethods": len(base_methods),
    }
    return failures, metrics


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=None)
    args = parser.parse_args()
    root = Path(args.root).resolve() if args.root else DEFAULT_ROOT
    failures, m = audit(root)
    print(
        "RSUI_COMPONENT_API_AUDIT " + ("PASS" if not failures else "FAIL")
        + f" | files={m.get('files',0)} assignments={m.get('assignments',0)}"
        + f" calls={m.get('calls',0)} guarded={m.get('guarded',0)} baseMethods={m.get('baseMethods',0)}"
    )
    for failure in failures:
        print("FAIL | " + failure)
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())

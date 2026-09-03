#!/usr/bin/env python3
"""Replicated Suite V3 static foundation audit.

This developer-only gate is intentionally outside toc.g.  It catches failure
classes that Lua syntax checks alone cannot see before a package reaches the RU
client: accidental globals/undefined locals, Presentation→Native escapes,
raw Native constructors, raw BuildScope usage outside low-level builders, and
known Lua 5.1 callback-capture regressions.
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

BUILTIN_GLOBALS = {
    "_G", "debug", "error", "ipairs", "math", "next", "pairs", "pcall",
    "rawget", "select", "setmetatable", "string", "table", "tonumber",
    "tostring", "type", "unpack", "xpcall",
}
PROJECT_GLOBALS = {
    "ADDON", "ALIGN_CENTER", "ALIGN_LEFT", "ALIGN_RIGHT", "ALIGN_TOP_LEFT",
    "CMF_SYSTEM", "DC_ALWAYS", "GetFocusedWidgetId", "ReplicatedSuite",
    "ReplicatedSuiteConfig", "ReplicatedSuiteRecovery", "SetTooltip", "UI",
    "UIEVENT_TYPE", "UIParent", "TMROLE_DEALER", "TMROLE_HEALER",
    "TMROLE_NONE", "TMROLE_RANGED_DEALER", "TMROLE_TANKER",
    "X2Ability", "X2Auction", "X2Bag", "X2Bank", "X2BattleField", "X2Butler",
    "X2Chat", "X2Coffer", "X2Craft", "X2EquipSlotReinforce", "X2Equipment",
    "X2Friend", "X2Hotkey", "X2House", "X2Input", "X2Map", "X2Option", "X2Player",
    "X2Quest", "X2Resident", "X2Skill", "X2Store", "X2Team", "X2Unit",
    "X2Locale", "UnitDistance",
}
ALLOWED_GLOBALS = BUILTIN_GLOBALS | PROJECT_GLOBALS
PRESENTATION_ALLOWED_GLOBALS = BUILTIN_GLOBALS | {
    "ReplicatedSuite", "UIParent", "ALIGN_CENTER", "DC_ALWAYS",
}

RAW_NATIVE_PATTERNS = (
    re.compile(r"\bUIParent\s*:\s*CreateWidget\s*\("),
    re.compile(r"\:\s*CreateChildWidget\s*\("),
    re.compile(r"\:\s*CreateChildWidgetByType\s*\("),
)
NATIVE_FACTORY_ALLOW = "native/rs_native_object_factory.lua"
RAW_SCOPE_ALLOW = {
    "ui/framework/rs_ui_component_core.lua",
    "ui/framework/rs_ui_window_shell_v3.lua",
    "presentation/v3/rs_v3_shell.lua",
    "core/rs_foundation_gate.lua",
}
PRESENTATION_FORBIDDEN_SOURCE = (
    (re.compile(r"\bFeature\s*\.\s*State\b"), "Feature.State"),
    (re.compile(r"\bFeature\s*\.\s*Authority\b"), "Feature.Authority"),
    (re.compile(r"\bFeature\s*\.\s*(?:Domain|Store|Id|enabled|revision|projections|consumerCount|consumers|StoreId|IndexStoreId|WidgetWindowSizePolicy|QuickButtonPolicy|quickButtonLastError|disableWhenIdle)\b"), "Feature internal field"),
    (re.compile(r"\bS\s*\.\s*Features\s*\.\s*\w+\s*\.\s*(?:State|Authority|Domain|Store|Id|enabled|revision|projections|consumerCount|consumers|StoreId|IndexStoreId|WidgetWindowSizePolicy|QuickButtonPolicy|quickButtonLastError|disableWhenIdle)\b"), "S.Features internal field"),
    (re.compile(r"\bStore\s*\.\s*State\b"), "Store.State"),
    (re.compile(r"\bFeature\s*:\s*GetSettings\s*\("), "Feature:GetSettings"),
    (re.compile(r"\bFeature\s*:\s*RefreshProjection\s*\("), "Feature:RefreshProjection"),
    (re.compile(r"\bFeature\s*:\s*GetPresentationSettings\s*\("), "Feature:GetPresentationSettings"),
    (re.compile(r"\bX2Unit\b"), "X2Unit"),
    (re.compile(r"\bX2Team\b"), "X2Team"),
    (re.compile(r"\bS\s*\.\s*FeatureRuntime\s*:\s*(?:Enable|Disable)\s*\("), "FeatureRuntime direct lifecycle"),
)
ENV_RE = re.compile(r';\s*_ENV\s+"([^"]+)"')


def strip_lua_comments(text: str) -> str:
    # Good enough for structural audit: remove long comments and line comments.
    text = re.sub(r"--\[\[.*?\]\]", lambda m: "\n" * m.group(0).count("\n"), text, flags=re.S)
    return re.sub(r"--[^\n]*", "", text)


def strip_lua_strings(text: str) -> str:
    # Structural source fences must ignore diagnostic strings such as
    # "X2Unit:Get...". Preserve newlines so reported line numbers remain useful.
    text = re.sub(r"\[\[.*?\]\]", lambda m: "\n" * m.group(0).count("\n"), text, flags=re.S)
    text = re.sub(r'"(?:\\.|[^"\\])*"', '""', text)
    return re.sub(r"'(?:\\.|[^'\\])*'", "''", text)


def read_toc(root: Path) -> list[str]:
    entries: list[str] = []
    for raw in (root / "toc.g").read_text(encoding="utf-8-sig").splitlines():
        value = raw.strip()
        if not value or value.startswith("#") or value.startswith("--"):
            continue
        entries.append(value.replace("\\", "/"))
    return entries


def texluac(args: list[str], cwd: Path) -> subprocess.CompletedProcess[str]:
    # The RU/reference toolchain may expose TeX LuaTeX as ``texluac`` while
    # the local Codex runtime commonly provides the compatible ``luac``
    # executable only.  Keep the gate compiler-agnostic; otherwise a missing
    # developer binary prevents the actual Foundation checks from running.
    compiler = shutil.which("texluac") or shutil.which("luac")
    if compiler is None:
        return subprocess.CompletedProcess(
            args=["<missing-lua-compiler>", *args], returncode=127,
            stdout="Lua compiler unavailable: expected texluac or luac",
        )
    return subprocess.run(
        [compiler, "-o", os.devnull, *args], cwd=str(cwd), text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )


def line_for(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def parse_native_api_contract(root: Path) -> tuple[set[str], set[str]]:
    path = root / "native/rs_native_contract.lua"
    source = path.read_text(encoding="utf-8-sig", errors="replace") if path.is_file() else ""
    keys = set(re.findall(r"^\s*([A-Z][A-Z0-9_]*)\s*=\s*\{\s*id\s*=", source, re.M))
    namespaces = set(re.findall(r'nativeName\s*=\s*"((?:X2[A-Za-z0-9_]+)|ADDON|UI|UIParent)"', source))
    return keys, namespaces


def scan_feature_api_dependencies(root: Path, active_lua: list[str]) -> list[str]:
    keys, namespaces = parse_native_api_contract(root)
    failures: list[str] = []
    block_re = re.compile(r"(?:ApiDependencies|apiDependencies)\s*=\s*\{(.*?)\}", re.S)
    value_re = re.compile(r'"([^"\n]+)"')
    for rel in active_lua:
        if not rel.startswith("features/"):
            continue
        source = strip_lua_comments((root / rel).read_text(encoding="utf-8-sig", errors="replace"))
        for block in block_re.finditer(source):
            for value in value_re.findall(block.group(1)):
                compact = re.sub(r"\s+", "", value)
                if ":" in compact:
                    namespace = compact.split(":", 1)[0]
                    if namespace not in namespaces:
                        failures.append(f"{rel}:{line_for(source, block.start())}:{value}")
                elif compact and compact.upper() not in keys:
                    failures.append(f"{rel}:{line_for(source, block.start())}:{value}")
    return failures



def parse_api_capability_registry(root: Path) -> set[str]:
    path = root / "core/rs_api_capabilities.lua"
    source = path.read_text(encoding="utf-8-sig", errors="replace") if path.is_file() else ""
    return set(re.findall(r'^\s*\["([^"\n]+)"\]\s*=\s*\{', source, re.M))


def scan_feature_api_capabilities(root: Path, active_lua: list[str]) -> list[str]:
    registered = parse_api_capability_registry(root)
    failures: list[str] = []
    block_re = re.compile(r"(?:ApiDependencies|apiDependencies)\s*=\s*\{(.*?)\}", re.S)
    value_re = re.compile(r'"([^"\n]+)"')
    for rel in active_lua:
        if not rel.startswith("features/"):
            continue
        source = strip_lua_comments((root / rel).read_text(encoding="utf-8-sig", errors="replace"))
        for block in block_re.finditer(source):
            for value in value_re.findall(block.group(1)):
                compact = re.sub(r"\s+", "", value)
                if ":" in compact and compact not in registered:
                    failures.append(f"{rel}:{line_for(source, block.start())}:{value}")
    return failures


def scan_auction_event_authority(root: Path, active_lua: list[str]) -> list[str]:
    """The RU auction completion edge is un-tokened, so exactly one Active owner may subscribe."""
    owners: list[str] = []
    subscribe_re = re.compile(r'\bSubscribe(?:Optional)?\s*\(\s*["\']AUCTION_ITEM_SEARCHED["\']')
    for rel in active_lua:
        source = strip_lua_comments((root / rel).read_text(encoding="utf-8-sig", errors="replace"))
        code = strip_lua_strings(source)
        # strip_lua_strings removes the event literal, so inspect comment-free source
        if subscribe_re.search(source):
            owners.append(rel)
    expected = "services/rs_auction_query_v3.lua"
    if owners == [expected]:
        return []
    return ["owners=" + ",".join(sorted(owners)) + "; expected=" + expected]


def scan_business_page_component_ids(root: Path) -> list[str]:
    """Detect fixed-vs-route-expanded logical ID collisions in the shared Business page.

    The Business builder mixes generic IDs such as ``v3_business_<id>_actions``
    with feature-specific literal IDs.  A collision is a strict RSUI preflight
    failure even though both source strings look unique before ``id`` is
    substituted.  Keep the parser intentionally narrow/high-signal: only simple
    string-literal + ``id`` concatenations and literal IDs are evaluated.
    """
    rel = "presentation/v3/pages/rs_v3_business_pages.lua"
    path = root / rel
    if not path.is_file():
        return [f"{rel}:missing"]
    source = strip_lua_comments(path.read_text(encoding="utf-8-sig", errors="replace"))
    route_ids = re.findall(r'\{\s*route\s*=\s*"[^"]+"\s*,\s*id\s*=\s*"([^"]+)"\s*\}', source)
    component_re = re.compile(r'RSUI:\w+\s*\(\s*\{\s*id\s*=\s*(.*?),\s*parent\s*=', re.S)
    expressions: list[tuple[str, int]] = []
    for match in component_re.finditer(source):
        expressions.append((" ".join(match.group(1).split()), line_for(source, match.start())))

    fixed: dict[str, list[int]] = {}
    dynamic: list[tuple[str, int]] = []
    literal_re = re.compile(r'^"([^"]*)"$')
    for expr, line in expressions:
        literal = literal_re.fullmatch(expr)
        if literal is not None:
            fixed.setdefault(literal.group(1), []).append(line)
        elif re.fullmatch(r'(?:\s*"[^"]*"\s*\.\.\s*)*id(?:\s*\.\.\s*"[^"]*")*\s*', expr):
            dynamic.append((expr, line))

    failures: list[str] = []
    for logical_id, lines in fixed.items():
        if len(lines) > 1:
            failures.append(f"{rel}:{'/'.join(map(str, lines))}:duplicate_literal:{logical_id}")

    def expand(expr: str, feature_id: str):
        parts = [part.strip() for part in expr.split("..")]
        out: list[str] = []
        for part in parts:
            if part == "id":
                out.append(feature_id)
                continue
            literal = literal_re.fullmatch(part)
            if literal is None:
                return None
            out.append(literal.group(1))
        return "".join(out)

    for expr, line in dynamic:
        for feature_id in route_ids:
            logical_id = expand(expr, feature_id)
            if logical_id is None:
                continue
            for fixed_line in fixed.get(logical_id, []):
                failures.append(
                    f"{rel}:{line}/{fixed_line}:route={feature_id}:expanded_collision:{logical_id}"
                )
    return sorted(set(failures))

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=None, help="replicatedsuite directory")
    ns = parser.parse_args()
    root = Path(ns.root).resolve() if ns.root else Path(__file__).resolve().parents[1]
    failures: list[str] = []
    notes: list[str] = []

    toc = read_toc(root)
    duplicate_toc = sorted({x for x in toc if toc.count(x) > 1})
    missing = sorted(x for x in toc if not (root / x).is_file())
    if duplicate_toc:
        failures.append("TOC duplicate: " + ", ".join(duplicate_toc[:12]))
    if missing:
        failures.append("TOC missing: " + ", ".join(missing[:12]))

    active_lua = [x for x in toc if x.endswith(".lua") and (root / x).is_file()]
    active_parse_fail: list[str] = []
    for rel in active_lua:
        proc = texluac(["-p", rel], root)
        if proc.returncode != 0:
            active_parse_fail.append(f"{rel}: {proc.stdout.strip()}")
    if active_parse_fail:
        failures.extend("Active Lua parse: " + x for x in active_parse_fail[:12])

    all_lua = sorted(root.rglob("*.lua"))
    all_lua_rel = [path.relative_to(root).as_posix() for path in all_lua]
    dead_lua = sorted(rel for rel in all_lua_rel if rel not in toc)
    if dead_lua:
        failures.append("Disk Lua not in Active TOC: " + ", ".join(dead_lua[:12]))
    all_parse_fail: list[str] = []
    for path in all_lua:
        rel = path.relative_to(root).as_posix()
        proc = texluac(["-p", rel], root)
        if proc.returncode != 0:
            all_parse_fail.append(f"{rel}: {proc.stdout.strip()}")
    if all_parse_fail:
        failures.extend("All Lua parse: " + x for x in all_parse_fail[:12])

    unresolved: list[str] = []
    presentation_globals: list[str] = []
    for rel in active_lua:
        proc = texluac(["-l", rel], root)
        if proc.returncode != 0:
            continue
        names = sorted(set(ENV_RE.findall(proc.stdout)))
        bad = [name for name in names if name not in ALLOWED_GLOBALS]
        if bad:
            unresolved.append(f"{rel}: {','.join(bad)}")
        if rel.startswith("presentation/v3/"):
            bad_p = [name for name in names if name not in PRESENTATION_ALLOWED_GLOBALS]
            if bad_p:
                presentation_globals.append(f"{rel}: {','.join(bad_p)}")
    if unresolved:
        failures.extend("Unexpected active global: " + x for x in unresolved[:20])
    if presentation_globals:
        failures.extend("Presentation global escape: " + x for x in presentation_globals[:20])

    raw_native: list[str] = []
    raw_scope: list[str] = []
    presentation_escape: list[str] = []
    callback_regressions: list[str] = []
    detached_widget_state: list[str] = []
    for rel in active_lua:
        path = root / rel
        source = path.read_text(encoding="utf-8-sig", errors="replace")
        code = strip_lua_strings(strip_lua_comments(source))
        if rel != NATIVE_FACTORY_ALLOW:
            for pattern in RAW_NATIVE_PATTERNS:
                for match in pattern.finditer(code):
                    raw_native.append(f"{rel}:{line_for(code, match.start())}")
        if rel not in RAW_SCOPE_ALLOW:
            for token in ("BeginBuildScope", "EndBuildScope"):
                for match in re.finditer(r"\b" + token + r"\b", code):
                    raw_scope.append(f"{rel}:{line_for(code, match.start())}:{token}")
        if rel.startswith("presentation/v3/"):
            for pattern, label in PRESENTATION_FORBIDDEN_SOURCE:
                for match in pattern.finditer(code):
                    presentation_escape.append(f"{rel}:{line_for(code, match.start())}:{label}")
        if rel.startswith("presentation/v3/widgets/") and "GetWidgetWindowState" in source:
            if not re.search(r"setState\s*=\s*function\s*\([^)]*\).*?Feature\.Commands:SetWidgetWindowState", source, re.S):
                detached_widget_state.append(f"{rel}: getState requires Feature.Commands:SetWidgetWindowState")

        # Known regression shapes: these names are valid only after stable-local
        # capture in delayed callbacks, never in the synchronous layout paths.
        if "self.handles[handleDefinition.key]" in code:
            callback_regressions.append(f"{rel}: handleDefinition synchronous misuse")
        if rel == "ui/framework/rs_ui_data_views.lua":
            m = re.search(r"local function NormalizeColumn\b(.*?)(?:\nlocal function|\nfunction )", code, re.S)
            if m and re.search(r"\bcolumnRef\b", m.group(1)):
                callback_regressions.append(f"{rel}: columnRef used inside NormalizeColumn")
        # Lua 5.1's ipairs stops at the first nil array element. A common
        # fallback shape such as ipairs({ tooltip, data }) therefore silently
        # drops the Data Row whenever tooltip is unavailable. Keep this exact
        # high-signal fence in the static gate; callers must probe each source
        # explicitly or use a nil-safe helper.
        if re.search(r"\bipairs\s*\(\s*\{\s*(?:primary\s*,\s*secondary|first\s*,\s*second)\s*\}", code):
            callback_regressions.append(f"{rel}: nil-unsafe fallback list passed to ipairs")

    if raw_native:
        failures.append("Raw native constructor outside factory: " + ", ".join(raw_native[:20]))
    if raw_scope:
        failures.append("Raw BuildScope outside low-level allowlist: " + ", ".join(raw_scope[:20]))
    if presentation_escape:
        failures.append("Presentation private/native source escape: " + ", ".join(presentation_escape[:20]))
    if detached_widget_state:
        failures.append("Detached widget state contract: " + ", ".join(detached_widget_state[:20]))
    # Explicit Lua 5.1 stable-capture anchors for the three framework loops that
    # previously regressed in production. These are deliberately exact and
    # conservative instead of a noisy generic closure heuristic.
    stable_capture_contracts = {
        "ui/framework/rs_ui_windowing.lua": "local handleDefinition = definition",
        "ui/framework/rs_ui_data_views.lua": "local columnRef = column",
        "presentation/v3/rs_v3_shell.lua": "local routeRef = route",
    }
    for rel, token in stable_capture_contracts.items():
        source = (root / rel).read_text(encoding="utf-8-sig", errors="replace") if (root / rel).is_file() else ""
        if token not in source:
            callback_regressions.append(f"{rel}: stable capture missing: {token}")

    if callback_regressions:
        failures.extend("Callback capture regression: " + x for x in callback_regressions)

    # Runtime-import regression fences. Feature files load before their lazy API
    # namespaces are imported, so a nil load-time rawget must be resolvable at
    # the central capability boundary rather than rejected by a local helper.
    api_source = (root / "core/rs_api.lua").read_text(encoding="utf-8-sig", errors="replace")
    life_source = (root / "features/life/rs_life_m16_bundle.lua").read_text(encoding="utf-8-sig", errors="replace")
    if "ResolveCapabilityHost" not in api_source:
        failures.append("Dynamic capability host contract missing: core/rs_api.lua")
    if "CapabilityCooldownContractVersion = 1" not in api_source or "ConsumeCapabilityCooldown" not in api_source:
        failures.append("Capability cooldown contract missing: core/rs_api.lua")
    if re.search(r'type\(S\.Api\.CallCapability\).*?or\s+object\s*==\s*nil', life_source, re.S):
        failures.append("Life lazy API host regression: local Call helper rejects nil before central resolution")

    # Strict-authority Native getters must compare against client UI scale, not
    # apply the Suite addonScale a second time to already-laid-out coordinates.
    framework_source = (root / "ui/rs_ui_framework.lua").read_text(encoding="utf-8-sig", errors="replace")
    anchor_match = re.search(r'local function TryNativeAnchorMatches\(.*?\nend', framework_source, re.S)
    extent_match = re.search(r'function UI:SetExtent\(.*?\nend', framework_source, re.S)
    for label, match in (("anchor", anchor_match), ("extent", extent_match)):
        body = match.group(0) if match else ""
        if "context.uiScale" not in body or "context.addonScale" in body:
            failures.append(f"Strict authority scale contract regression: {label}")

    api_dependency_failures = scan_feature_api_dependencies(root, active_lua)
    if api_dependency_failures:
        failures.append("Feature API dependency has no NativeContract namespace: " + ", ".join(api_dependency_failures[:24]))
    api_capability_failures = scan_feature_api_capabilities(root, active_lua)
    if api_capability_failures:
        failures.append("Feature API dependency missing from ApiCapabilities: " + ", ".join(api_capability_failures[:24]))

    business_page_id_failures = scan_business_page_component_ids(root)
    if business_page_id_failures:
        failures.append("Business page logical ID collision: " + ", ".join(business_page_id_failures[:24]))

    auction_event_authority_failures = scan_auction_event_authority(root, active_lua)
    if auction_event_authority_failures:
        failures.append("Auction un-tokened event Authority violation: " + ", ".join(auction_event_authority_failures[:8]))

    # ------------------------------------------------------------------
    # Retired Foundation layer fence (`.18.63` ComponentsV2 retirement).
    #
    # Historical `UI.ComponentsV2` has been physically removed.  Its return
    # would recreate a second Presentation Authority and a second component
    # system competing with RSUI.  Earlier delivery rounds saw the file
    # silently re-appear through archive overwrite while the docs already
    # claimed it was gone, so this fence asserts three independent
    # conditions and refuses every combination:
    #
    #   1. the retired file must not exist on disk at all -- any size counts,
    #      including a zero-byte placeholder that only "fakes" the deletion;
    #   2. it must not appear in the Active TOC;
    #   3. active Runtime Lua may not reference the retired surface.
    #
    # Comments and string literals are stripped before matching, so historical
    # architecture notes stay valid documentation instead of tripping the gate.
    # ------------------------------------------------------------------
    RETIRED_UI_LAYERS = (
        {
            "path": "ui/framework/rs_ui_components_v2.lua",
            "label": "UI.ComponentsV2",
            "patterns": (
                (re.compile(r"\bUI\s*\.\s*ComponentsV2\b"), "UI.ComponentsV2"),
                (re.compile(r"\bCreate(?:Card|Section|FormRow|ChoiceField|ToggleField|NumericField)V2\b"), "Create*V2 component helper"),
            ),
        },
    )
    retired_ui_layer_failures: list[str] = []
    for layer in RETIRED_UI_LAYERS:
        retired_path = layer["path"]
        if (root / retired_path).exists():
            retired_ui_layer_failures.append(
                f"{retired_path}: retired {layer['label']} file re-appeared on disk"
            )
        if retired_path in toc:
            retired_ui_layer_failures.append(
                f"{retired_path}: retired {layer['label']} layer re-entered Active TOC"
            )
        for rel in active_lua:
            source = (root / rel).read_text(encoding="utf-8-sig", errors="replace")
            code = strip_lua_strings(strip_lua_comments(source))
            for pattern, label in layer["patterns"]:
                for match in pattern.finditer(code):
                    retired_ui_layer_failures.append(
                        f"{rel}:{line_for(code, match.start())}:{label}"
                    )
    if retired_ui_layer_failures:
        failures.append(
            "Retired UI component layer reflow: "
            + ", ".join(sorted(set(retired_ui_layer_failures))[:20])
        )

    composite_entry = "ui/framework/rs_ui_composite_foundation.lua"
    composite_source = (root / composite_entry).read_text(encoding="utf-8-sig", errors="replace") if (root / composite_entry).is_file() else ""
    if composite_entry not in toc:
        failures.append("Composite Foundation missing from Active TOC: " + composite_entry)
    if not re.search(r"RSUI\.CompositeFoundation\s*=\s*\{\s*version\s*=\s*4", composite_source, re.S):
        failures.append("Composite Foundation version regression: expected version 4")

    for token in (
        "StatusChipContractVersion = 1",
        "PickerModelContractVersion = 1",
        "SearchablePickerContractVersion = 1",
        "IconPickerContractVersion = 1",
        "TreeViewContractVersion = 1",
        "TreeStableIdentityContractVersion = 1",
        "TreeMutationTransactionContractVersion = 2",
        "TreeExpansionStateBoundContractVersion = 1",
        "RSUI.PickerModel",
        "RSUI.TreeModel",
        "RSUI.CompositeFoundation",
    ):
        if token not in composite_source:
            failures.append(f"Composite Foundation contract missing: {token}")

    if 'return tostring(path)' in composite_source:
        failures.append("Tree stable identity regression: index-path fallback reintroduced")

    layout_source = (root / "core/rs_layout.lua").read_text(encoding="utf-8-sig", errors="replace")
    interactions_source = (root / "ui/framework/rs_ui_interactions.lua").read_text(encoding="utf-8-sig", errors="replace")
    for token in (
        "CoordinateSystemContractVersion = 1",
        "RectTransformTransactionContractVersion = 2",
        'origin = "top_left"',
        'xPositive = "right"',
        'yPositive = "down"',
        "function L:OffsetPoint(x, y, direction, distance)",
        "function L:CreateRectTransformTransaction(spec)",
        "function tx:OverridePreview(rect)",
    ):
        if token not in layout_source:
            failures.append(f"Layout geometry contract missing: {token}")
    for token in (
        "RSUI.PointerContractVersion = 1",
        "captureSupported = false",
        "function Pointer:GetLogicalPosition()",
        "function Pointer:Delta(startX, startY, currentX, currentY)",
    ):
        if token not in interactions_source:
            failures.append(f"RSUI pointer contract missing: {token}")

    selection_geometry_entry = "ui/framework/rs_ui_selection_geometry.lua"
    selection_geometry_source = (root / selection_geometry_entry).read_text(encoding="utf-8-sig", errors="replace") if (root / selection_geometry_entry).is_file() else ""
    if selection_geometry_entry not in toc:
        failures.append("Selection Geometry Foundation missing from Active TOC: " + selection_geometry_entry)
    for token in (
        "RSUI.SelectionGeometryContractVersion = 1",
        "RSUI.LayoutGuideResolverContractVersion = 1",
        "function SelectionGeometry:GetHandleRects(rect, options)",
        "function SelectionGeometry:HitTestHandle(x, y, rect, options)",
        "function RSUI:CreateSelectionGeometryModel(options)",
        "function GuideResolver:Resolve(proposedRect, handle, options)",
        "RSUI.SelectionOverlayContractVersion = 1",
        "RSUI.LayoutGuideOverlayContractVersion = 1",
        'RSUI:RegisterType("SelectionOverlay"',
        'RSUI:RegisterType("LayoutGuideOverlay"',
        "HARD_MAX_CANDIDATES = 1024",
    ):
        if token not in selection_geometry_source:
            failures.append(f"Selection geometry contract missing: {token}")

    layout_editor_gesture_entry = "ui/framework/rs_ui_layout_editor_gesture.lua"
    layout_editor_gesture_source = (root / layout_editor_gesture_entry).read_text(encoding="utf-8-sig", errors="replace") if (root / layout_editor_gesture_entry).is_file() else ""
    if layout_editor_gesture_entry not in toc:
        failures.append("Layout Editor Gesture Foundation missing from Active TOC: " + layout_editor_gesture_entry)
    for token in (
        "RSUI.LayoutEditorGestureContractVersion = 2",
        "function RSUI:CreateLayoutEditorGestureController(options)",
        "function GestureController:Pulse(force)",
        "function GestureController:FreezeSnapState(kind, handle, startRect, constraints)",
        "function GestureController:ResolveTransformConstraints(kind, handle, startRect)",
        "UI:BeginNativeGeometryLease",
        "AddInteractiveTask",
        'coordinateSpace ~= "viewport"',
        "HARD_MAX_FROZEN_CANDIDATES = 1024",
    ):
        if token not in layout_editor_gesture_source:
            failures.append(f"Layout editor gesture contract missing: {token}")
    if "getSnapCandidates" in layout_editor_gesture_source and "FreezeSnapState" not in layout_editor_gesture_source:
        failures.append("Layout editor snap candidates must be frozen at gesture begin")

    layout_editor_models_entry = "ui/framework/rs_ui_layout_editor_models.lua"
    layout_editor_models_source = (root / layout_editor_models_entry).read_text(encoding="utf-8-sig", errors="replace") if (root / layout_editor_models_entry).is_file() else ""
    if layout_editor_models_entry not in toc:
        failures.append("Layout Editor Models Foundation missing from Active TOC: " + layout_editor_models_entry)
    for token in (
        "RSUI.AnchorPivotContractVersion = 2",
        "RSUI.LayoutEditorSnapSettingsContractVersion = 1",
        "function AnchorPivotModel:ApplySnapshot(snapshot, source)",
        "function AnchorPivotModel:MoveUp(distance)",
        "function SnapSettingsModel:SetPatch(patch, source)",
        "ValidateSnapPatch",
        "HARD_MAX_CANDIDATES = 1024",
    ):
        if token not in layout_editor_models_source:
            failures.append(f"Layout editor model contract missing: {token}")

    transform_inspector_entry = "ui/framework/rs_ui_transform_inspector.lua"
    transform_inspector_source = (root / transform_inspector_entry).read_text(encoding="utf-8-sig", errors="replace") if (root / transform_inspector_entry).is_file() else ""
    if transform_inspector_entry not in toc:
        failures.append("Transform Inspector Foundation missing from Active TOC: " + transform_inspector_entry)
    for token in (
        "RSUI.TransformInspectorContractVersion = 2",
        'RSUI:RegisterTypeValidator("TransformInspector"',
        'RSUI:RegisterType("TransformInspector"',
        'function c:SetModels(nextRectModel, nextAnchorModel)',
        '"Y（上-/下+）"',
    ):
        if token not in transform_inspector_source:
            failures.append(f"Transform Inspector contract missing: {token}")

    multi_transform_entry = "ui/framework/rs_ui_multi_selection_transform.lua"
    multi_transform_source = (root / multi_transform_entry).read_text(encoding="utf-8-sig", errors="replace") if (root / multi_transform_entry).is_file() else ""
    if multi_transform_entry not in toc:
        failures.append("Multi Selection Transform Foundation missing from Active TOC: " + multi_transform_entry)
    for token in (
        "RSUI.MultiSelectionTransformContractVersion = 1",
        "HARD_MAX_ITEMS = 1024",
        "multi_transform_requires_multiple_items",
        "function Model:GetGroupConstraints(options)",
        "function Model:BeginProjectionSession(options)",
        "function Session:Project(targetBounds)",
        "function Session:Commit(targetBounds, source)",
        "function Session:Cancel()",
    ):
        if token not in multi_transform_source:
            failures.append(f"Multi selection transform contract missing: {token}")
    layout_editor_adapter_entry = "ui/framework/rs_ui_layout_editor_adapter.lua"
    layout_editor_adapter_source = (root / layout_editor_adapter_entry).read_text(encoding="utf-8-sig", errors="replace") if (root / layout_editor_adapter_entry).is_file() else ""
    if layout_editor_adapter_entry not in toc:
        failures.append("Layout Editor Preview Adapter missing from Active TOC: " + layout_editor_adapter_entry)
    for token in (
        "RSUI.LayoutEditorPreviewAdapterContractVersion = 1",
        "function Adapter:SyncSelection(source)",
        "function Adapter:BeginGesture(kind, handle)",
        "function Adapter:CommitGesture(rect)",
        "function Adapter:CommitSingleAnchorEdit(source, previousSnapshot)",
        "layout_editor_adapter_selection_revision_changed",
    ):
        if token not in layout_editor_adapter_source:
            failures.append(f"Layout editor preview adapter contract missing: {token}")

    layout_editor_overlay_entry = "ui/framework/rs_ui_layout_editor_overlay.lua"
    layout_editor_overlay_source = (root / layout_editor_overlay_entry).read_text(encoding="utf-8-sig", errors="replace") if (root / layout_editor_overlay_entry).is_file() else ""
    if layout_editor_overlay_entry not in toc:
        failures.append("LayoutEditorOverlay missing from Active TOC: " + layout_editor_overlay_entry)
    for token in (
        "RSUI.LayoutEditorOverlayContractVersion = 1",
        'RSUI:RegisterTypeValidator("LayoutEditorOverlay"',
        'RSUI:RegisterType("LayoutEditorOverlay"',
        "previewMustSucceed = true",
        "commitMustSucceed = true",
        "HARD_MAX_CANDIDATES = 1024",
        "function c:RefreshFromSource(source)",
    ):
        if token not in layout_editor_overlay_source:
            failures.append(f"LayoutEditorOverlay contract missing: {token}")
    overlay_code = strip_lua_strings(strip_lua_comments(layout_editor_overlay_source))
    if re.search(r"\bStartMoving\s*\(", overlay_code) or re.search(r"\bStartSizing\s*\(", overlay_code):
        failures.append("LayoutEditorOverlay must not own Native drag capture; GestureController is the sole editor capture authority")

    for rel, source in ((layout_editor_models_entry, layout_editor_models_source), (multi_transform_entry, multi_transform_source), (layout_editor_adapter_entry, layout_editor_adapter_source)):
        code = strip_lua_strings(strip_lua_comments(source))
        if re.search(r"\bOnUpdate\b", code) or re.search(r"\bAddInteractiveTask\b", code):
            failures.append("Pure layout editor model must not own sampling loop: " + rel)

    component_core_source = (root / "ui/framework/rs_ui_component_core.lua").read_text(encoding="utf-8-sig", errors="replace")
    adaptive_source = (root / "ui/framework/rs_ui_adaptive_panels.lua").read_text(encoding="utf-8-sig", errors="replace")
    workspace_source = (root / "ui/framework/rs_ui_workspace_templates.lua").read_text(encoding="utf-8-sig", errors="replace")
    for token in (
        "AttachmentContractVersion = 1",
        "ReparentPolicyContractVersion = 1",
        "NativeReparentSupported = false",
        "function RSUI:ValidateAttachment(parent, component)",
        "function Base:CanReparentTo(parent)",
        "function Base:RemoveChild(component)",
    ):
        if token not in component_core_source:
            failures.append(f"RSUI host/slot attachment contract missing: {token}")
    if "ResponsiveInspectorContractVersion = 1" not in adaptive_source or 'RegisterType("ResponsiveInspector"' not in adaptive_source:
        failures.append("Stable-host ResponsiveInspector contract missing: ui/framework/rs_ui_adaptive_panels.lua")
    if (
        "contractVersion = 3" not in workspace_source
        or "CreateResponsiveInspectorWorkspace" not in workspace_source
        or "CreateLayoutEditorWorkspace" not in workspace_source
        or "function T:LayoutEditor(spec)" not in workspace_source
    ):
        failures.append("WorkspaceTemplates v3 layout-editor contract missing")

    # The RU client has no validated generic native reparent API. Active Runtime
    # must therefore not introduce desktop/UMG-style reparent calls. Logical
    # attachment is allowed only through RSUI's single-parent contract above.
    unverified_reparent_patterns = (
        re.compile(r"\bRemoveFromParent\s*\("),
        re.compile(r"\bReparent(?:Widget)?\s*\("),
        re.compile(r"\bSetParent\s*\("),
    )
    reparent_refs: list[str] = []
    for rel in active_lua:
        source = (root / rel).read_text(encoding="utf-8-sig", errors="replace")
        code = strip_lua_strings(strip_lua_comments(source))
        for pattern in unverified_reparent_patterns:
            for match in pattern.finditer(code):
                reparent_refs.append(f"{rel}:{line_for(code, match.start())}")
    if reparent_refs:
        failures.append("Unverified native UI reparent operation: " + ", ".join(reparent_refs[:20]))

    token_source = (root / "ui/framework/rs_ui_tokens.lua").read_text(encoding="utf-8-sig", errors="replace")
    if "version = 4" not in token_source or "popupPriority = 10000" not in token_source:
        failures.append("UI token layer contract missing: ui/framework/rs_ui_tokens.lua")

    controls_source = (root / "ui/framework/rs_ui_controls.lua").read_text(encoding="utf-8-sig", errors="replace")
    if "DropdownDegradedFailClosedContractVersion = 1" not in controls_source:
        failures.append("Dropdown degraded fail-closed contract missing: ui/framework/rs_ui_controls.lua")
    if "PopupCoordinatorContractVersion = 1" not in controls_source or "RSUI.DropdownService = PopupCoordinator" not in controls_source:
        failures.append("Popup coordinator single-registry contract missing: ui/framework/rs_ui_controls.lua")
    if "PopupCoordinator:Unregister(self)" not in controls_source:
        failures.append("Popup component release unregister contract missing: ui/framework/rs_ui_controls.lua")
    interaction_source = (root / "ui/framework/rs_ui_interactions.lua").read_text(encoding="utf-8-sig", errors="replace")
    for token in (
        "FocusContractVersion = 2",
        "function Focus:CanSet(target)",
        "function Focus:CanClear(target)",
        "function Focus:IsFocused(target)",
    ):
        if token not in interaction_source:
            failures.append(f"Focus target-capability contract missing: {token}")
    if "setFocus = true" in interaction_source:
        failures.append("Focus capability regression: setFocus hard-coded true")

    # RU input evidence currently covers Enter/EditEnter/LostFocus but not the
    # generic desktop-style events below. Keep this as a hard fence so future
    # SearchablePicker/IconPicker work cannot silently invent an event name.
    unverified_ui_events: list[str] = []
    unverified_event_re = re.compile(r"[\"'](OnKeyDown|OnKeyUp|OnTextChanged)[\"']")
    for rel in active_lua:
        source = (root / rel).read_text(encoding="utf-8-sig", errors="replace")
        code = strip_lua_comments(source)
        for match in unverified_event_re.finditer(code):
            unverified_ui_events.append(f"{rel}:{line_for(code, match.start())}:{match.group(1)}")
    if unverified_ui_events:
        failures.append("Unverified RU UI event binding: " + ", ".join(unverified_ui_events[:20]))
    if "SetDrawPriority(10000" in controls_source or "SetDrawPriority(10000" in interaction_source:
        failures.append("Popup Z priority literal escaped UITokens.layer.popupPriority")

    if "StrictBuildFailFastContractVersion = 1" not in component_core_source or "required_component_build_failed:" not in component_core_source:
        failures.append("Strict BuildScope fail-fast contract missing: ui/framework/rs_ui_component_core.lua")

    # The three hosts were specifically migrated to the transaction wrapper.
    host_contract = {
        "presentation/v3/shell/rs_v3_page_host.lua": "WithBuildScope",
        "presentation/v3/widgets/rs_v3_widget_host.lua": "WithBuildScope",
        "presentation/v3/shell/rs_v3_modal_host.lua": "WithBuildScope",
    }
    for rel, token in host_contract.items():
        source = (root / rel).read_text(encoding="utf-8-sig", errors="replace") if (root / rel).is_file() else ""
        if token not in source:
            failures.append(f"BuildTransaction host contract missing: {rel}")

    print(
        "FOUNDATION_AUDIT " + ("PASS" if not failures else "FAIL")
        + f" | toc={len(toc)} activeLua={len(active_lua)} allLua={len(all_lua)}"
        + f" globals={len(unresolved)} presentation={len(presentation_globals)}"
        + f" rawNative={len(raw_native)} rawScope={len(raw_scope)}"
        + f" detachedWidgetState={len(detached_widget_state)}"
        + f" apiDependency={len(api_dependency_failures)}"
        + f" apiCapability={len(api_capability_failures)}"
        + f" businessIds={len(business_page_id_failures)}"
        + f" auctionEventOwners={len(auction_event_authority_failures)}"
        + f" retiredUiLayer={len(retired_ui_layer_failures)}"
    )
    for item in failures:
        print("FAIL | " + item)
    for item in notes:
        print("NOTE | " + item)
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())

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

    component_core_source = (root / "ui/framework/rs_ui_component_core.lua").read_text(encoding="utf-8-sig", errors="replace")
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
    )
    for item in failures:
        print("FAIL | " + item)
    for item in notes:
        print("NOTE | " + item)
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())

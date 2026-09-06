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



def scan_service_upward_dependencies(root: Path, active_lua: list[str]) -> list[str]:
    """Services may publish facts/events, but must never reach upward into Feature consumers."""
    failures: list[str] = []
    patterns = (
        re.compile(r"\bS\s*\.\s*Features\b"),
        re.compile(r"\bReplicatedSuite\s*\.\s*Features\b"),
    )
    for rel in active_lua:
        if not rel.startswith("services/"):
            continue
        source = (root / rel).read_text(encoding="utf-8-sig", errors="replace")
        code = strip_lua_strings(strip_lua_comments(source))
        for pattern in patterns:
            for match in pattern.finditer(code):
                failures.append(f"{rel}:{line_for(code, match.start())}")
    return sorted(set(failures))


def scan_locked_product_truth(root: Path) -> list[str]:
    """Fence concrete Runtime Blockers whose RU contracts are still unverified.

    The Product Matrix is the locked capability evidence. These high-risk rows
    must remain SPECIFIC_RUNTIME_BLOCKED until the matrix itself is changed with
    RU evidence; Active implementation must not silently reintroduce the blocked
    Native calls in the meantime.
    """
    failures: list[str] = []
    matrix_path = root / "Docs/Rebuild/PRODUCT_COMPLETION_MATRIX.md"
    matrix = matrix_path.read_text(encoding="utf-8-sig", errors="replace") if matrix_path.is_file() else ""
    locked_rows = (
        "Fishing full R source-slot enumeration/snapshot",
        "Fishing R write/restore/error recovery",
        "Reinforcement slot levels/materials/set effects",
    )
    for label in locked_rows:
        row = re.search(r"^\|\s*" + re.escape(label) + r"\s*\|\s*([^|]+)\|", matrix, re.M)
        status = row.group(1).strip() if row else "missing"
        if status != "SPECIFIC_RUNTIME_BLOCKED":
            failures.append(f"matrix:{label}:status={status}")

    life_path = root / "features/life/rs_life_m16_bundle.lua"
    life = strip_lua_comments(life_path.read_text(encoding="utf-8-sig", errors="replace")) if life_path.is_file() else ""
    if "Fishing.HotkeyRuntimeBlocked = true" not in life or "Fishing.HotkeyContractVersion = 2" not in life:
        failures.append("fishing:runtime-block marker missing")
    for token in (
        'Call("X2Hotkey:GetOptionBinding"',
        'Action("X2Hotkey:BindingToOption"',
        'Action("X2Hotkey:SetOptionBindingWithIndex"',
        'Action("X2Hotkey:RemoveOptionBinding"',
        'Action("X2Hotkey:SaveHotKey"',
    ):
        if token in life:
            failures.append("fishing:blocked hotkey Native path active:" + token)

    bridge_path = root / "features/rs_business_bridge.lua"
    bridge = strip_lua_comments(bridge_path.read_text(encoding="utf-8-sig", errors="replace")) if bridge_path.is_file() else ""
    if "S.Features.tools_reinforce_analysis.SlotProbeRuntimeBlocked = true" not in bridge:
        failures.append("reinforce:runtime-block marker missing")
    for token in (
        'Call("X2EquipSlotReinforce:GetReinforceInfo"',
        'Call("X2EquipSlotReinforce:GetMaterialInfo"',
        "REINFORCE_SLOT_PROBE_MAX",
    ):
        if token in bridge:
            failures.append("reinforce:blocked slot probe active:" + token)
    return failures

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

    service_upward_failures = scan_service_upward_dependencies(root, active_lua)
    if service_upward_failures:
        failures.append("Service -> Feature upward dependency: " + ", ".join(service_upward_failures[:24]))

    product_truth_failures = scan_locked_product_truth(root)
    if product_truth_failures:
        failures.append("Locked Product Truth violation: " + ", ".join(product_truth_failures[:24]))

    # Bag Move Contract v8 + InventorySnapshotV3: old/reference product behavior
    # may define the user goal, but Active V3 owns observation, physical bagId
    # authority and indexed planning.  Plans keep grouped stable intent rather
    # than physical slots; slots are revalidated immediately before each write.
    inventory_path = root / "services/rs_inventory_snapshot_v3.lua"
    inventory_source = inventory_path.read_text(encoding="utf-8-sig", errors="replace") if inventory_path.is_file() else ""
    for token in (
        'Id = "v3.inventory_snapshot"',
        "SnapshotContractVersion = 1",
        "PhysicalBagAuthorityContractVersion = 1",
        "IndexContractVersion = 1",
        "PreferredBagId = 1",
        "FallbackBagId = 0",
        "function I:BuildSnapshot(scope, options)",
        "function I:FindLiveRow(scope, matcher, options)",
        "function I:CountLive(scope, matcher, options)",
        "function I:ReadPhysicalBagSlot(slot, bagIdHint)",
        "stopAt",
    ):
        if token not in inventory_source:
            failures.append("Inventory snapshot contract missing: " + token)

    bag_bridge_path = root / "features/rs_business_bridge.lua"
    bag_bridge_source = bag_bridge_path.read_text(encoding="utf-8-sig", errors="replace") if bag_bridge_path.is_file() else ""
    for token in (
        "local BagMoveRuntime = {}",
        "local function StableItemIdentity(info)",
        "function BagMoveRuntime.FindLiveMoveSource(feature, sourceScope, blacklistScope, identity, category, bagId, startSlot, blockedIdentities)",
        "function BagMoveRuntime.CountLiveMatches(scope, identity, category, bagId, stopAt)",
        "queueByIdentity",
        "remaining = 0, slotHint = row.slot",
        "feature._quickBagId = bagId",
        "feature._batchBagId = bagSnapshot.bagId",
        "BagTools.BagMoveContractVersion = 8",
        "BagTools.DynamicSourceResolutionContractVersion = 3",
        "BagTools.QuickIdentityFallbackContractVersion = 1",
        "BagTools.InventorySnapshotContractVersion = 1",
        "BagTools.GroupedIntentQueueContractVersion = 1",
        "BagTools.FullStorageContinuationContractVersion = 1",
        "function BagMoveRuntime.IsNativeMoveRejected(err)",
        "function BagMoveRuntime.BlockBatchIdentity(feature, entry, identity, reason)",
    ):
        if token not in bag_bridge_source:
            failures.append("Bag v8 grouped-intent/full-storage contract missing: " + token)
    bag_bridge_code = strip_lua_strings(strip_lua_comments(bag_bridge_source))
    forbidden_slot_queue_patterns = (
        re.compile(r"queue\s*\[\s*#queue\s*\+\s*1\s*\]\s*=\s*\{\s*slot\s*="),
        re.compile(r"queue\s*\[\s*#queue\s*\+\s*1\s*\]\s*=\s*slot\b"),
    )
    for pattern in forbidden_slot_queue_patterns:
        if pattern.search(bag_bridge_code):
            failures.append("Bag move regression: transient slot stored in serial move plan")
            break
    if 'GetBagItemInfo", BagApi, "GetBagItemInfo", 0, sourceSlot' in bag_bridge_source:
        failures.append("Bag physical authority regression: direct move blacklist read hardcodes bagId=0")

    # Auction Sidecar v2: native Auction House remains Authority.  The sidecar
    # must observe verified geometry/visibility only, reuse tools_auction state,
    # and tolerate the RU build that omits the final MainScript visibility bool.
    auction_surface_path = root / "services/rs_auction_surface_v3.lua"
    auction_sidecar_path = root / "presentation/v3/widgets/rs_v3_auction_sidecar.lua"
    auction_surface_source = auction_surface_path.read_text(encoding="utf-8-sig", errors="replace") if auction_surface_path.is_file() else ""
    auction_sidecar_source = auction_sidecar_path.read_text(encoding="utf-8-sig", errors="replace") if auction_sidecar_path.is_file() else ""
    for token in (
        'V.presentationBoundary = "service_only"',
        "VisibilityContractVersion = 2",
        'IsCapabilityAllowed("ADDON:GetContent")',
        "ReadContentChainVisible",
        "ResolveContentRect",
        "main-script-geometry",
    ):
        if token not in auction_surface_source:
            failures.append("Auction surface v2 contract missing: " + token)
    for token in (
        'Feature:AcquireConsumer("widget:auction_sidecar")',
        'Feature:ReleaseConsumer("widget:auction_sidecar")',
        "Feature:GetProjection()",
        "Controller.dismissed = true",
    ):
        if token not in auction_sidecar_source:
            failures.append("Auction sidecar reuse contract missing: " + token)
    if "SearchAuctionArticle" in auction_surface_source or "GetLowestPrice" in auction_surface_source:
        failures.append("Auction surface regression: observer must not issue server auction queries")

    # Craft Sidecar has the same Service/Presentation boundary as Auction:
    # observe verified native visibility/geometry in Service, render in UIV3.
    craft_surface_path = root / "services/rs_craft_surface_v3.lua"
    craft_surface_source = craft_surface_path.read_text(encoding="utf-8-sig", errors="replace") if craft_surface_path.is_file() else ""
    for token in (
        'V.presentationBoundary = "service_only"',
        "VisibilityContractVersion = 1",
        "function V:GetSnapshot()",
        "function V:Start()",
        "function V:Stop(reason)",
    ):
        if token not in craft_surface_source:
            failures.append("Craft surface service-boundary contract missing: " + token)

    # ScreenProjectionV3 v8 / Unit Line front-hemisphere + coordinate-consistency + world-alias +
    # index-stable world batch contract: RU may
    # return a positive native screen depth for a unit physically behind the
    # camera.  Unit Lines must classify camera-forward world position in one
    # batched Service call before Presentation clipping; never infer "behind"
    # from a mirrored screen coordinate or depth alone.
    projection_path = root / "services/rs_screen_projection_v3.lua"
    projection_source = projection_path.read_text(encoding="utf-8-sig", errors="replace") if projection_path.is_file() else ""
    for token in (
        "P.version = 8",
        "function P:ProjectUnitBatch(unitTokens, options)",
        "local function CameraForwardDistance(frame, wx, wy, wz)",
        'reason="behind_camera"',
        "P.FrontHemisphereBatchContractVersion = 1",
        "P.UnitProjectionConsistencyContractVersion = 1",
        "P.UnitWorldAliasGuardContractVersion = 1",
        "P.WorldBatchIndexContractVersion = 1",
        "P.CameraUnavailableNativeFallbackContractVersion = 1",
        "aliasCandidate=false, worldAliased=false",
        "native_world_alias_guard",
        "local wx,wy,wz,worldErr=self:GetUnitWorldPosition(token,false)",
        "native_scale_reconciled",
        "camera_consistency_fallback",
    ):
        if token not in projection_source:
            failures.append("Screen projection front-hemisphere contract missing: " + token)

    # Unit Line Adaptive/Smooth Rendering Contract v2: fixed final point count
    # made long-distance lines sparse; whole-task P3 deferral and redundant
    # Native property touches made crowd scenes pulse/stutter. Keep adaptive
    # density + clipping in Presentation, keep the high-frequency refresh P1,
    # and shed only adaptive EXTRA quality under frame pressure.
    unit_guide_path = root / "presentation/v3/widgets/rs_v3_combat_visual_guides.lua"
    unit_guide_source = unit_guide_path.read_text(encoding="utf-8-sig", errors="replace") if unit_guide_path.is_file() else ""
    for token in (
        "P.version = 5",
        "local UNIT_LINE_PAIR_HARD_CAP = 160",
        "local function ClipSegmentToRect(x1, y1, x2, y2, left, top, right, bottom)",
        "local function UnitLineTotalBudget(refreshMs)",
        "local function UnitLinePressureBudget(baseBudget, totalBase, pressure)",
        "local function UnitLinePoolGrowthBudget(pressure)",
        "local function DesiredUnitLinePointCount(length, baseCount)",
        "function P:BuildUnitLineSamplePlan(rows, projection, logicalW, logicalH, pressure)",
        "function P:PlaceUnitDot(dot, x, y, size, opacity, pairKey, r, g, b)",
        "P.AdaptiveUnitLineSamplingContractVersion = 2",
        "P.UnitLineVisibleSegmentClippingContractVersion = 1",
        "P.UnitLinePressureBudgetContractVersion = 1",
        "P.UnitLineDiffRenderContractVersion = 1",
        "P.UnitLineProgressivePoolContractVersion = 1",
    ):
        if token not in unit_guide_source:
            failures.append("Unit line adaptive sampling contract missing: " + token)
    unit_guide_code = strip_lua_strings(strip_lua_comments(unit_guide_source))
    if re.search(r"function\s+P:RenderUnit\(\).*?local\s+count\s*=\s*math\.max\(8\s*,\s*math\.min\(48", unit_guide_code, re.S):
        failures.append("Unit line regression: RenderUnit restored fixed final 8..48 point count")
    for token in (
        'UnitLines.VisualGuideContractVersion = 4',
        'UnitLines.AdaptiveDensityContractVersion = 2',
        'UnitLines.SmoothRefreshContractVersion = 1',
        'UnitLines.FrontHemisphereContractVersion = 1',
        'UnitLines.ProjectionConsistencyContractVersion = 1',
        'projection:ProjectUnitBatch(tokens,{ requireFrontHemisphere=true, worldZOffset=1, validateNativeAgainstCamera=true, reconcileNativeScale=true })',
        'pointBudgetMode="cadence_pressure_bounded"',
    ):
        if token not in bag_bridge_source:
            failures.append("Unit line smooth-refresh feature contract missing: " + token)
    unit_line_task = re.search(
        r'AddHighFrequencyTask\s*\(\s*UNIT_LINE_TASK\s*,\s*UnitLineInterval\(feature\).*?end\s*,\s*false\s*,\s*feature\s*,\s*"(P[0-5])"\s*,\s*1\s*\)',
        strip_lua_comments(bag_bridge_source), re.S)
    if unit_line_task is None:
        failures.append("Unit line smooth-refresh feature contract missing: UNIT_LINE_TASK scheduler registration")
    elif unit_line_task.group(1) != "P1":
        failures.append("Unit line regression: high-frequency visual task priority is " + unit_line_task.group(1) + ", expected P1")
    unit_line_read = re.search(r'local\s+UnitLines\s*=\s*NewFeature\(\"combat_unit_lines\"\s*,\s*\{(.*?)\n\}\)\nUnitLines\.VisualGuideContractVersion', strip_lua_comments(bag_bridge_source), re.S)
    if unit_line_read is not None and "ProjectUnitFlexible(" in unit_line_read.group(1):
        failures.append("Unit line regression: per-endpoint ProjectUnitFlexible bypasses front-hemisphere batch")

    # Range Assist must stay in the same GLOBAL world space as the camera frame
    # and must consume every requested batch index. A circle naturally has
    # behind-camera points; ipairs() over a sparse numeric batch truncates at the
    # first hole and can make the guide disappear or render only a short arc.
    range_read = re.search(r'local\s+RangeAssist\s*=\s*NewFeature\("combat_range_assist"\s*,\s*\{(.*?)\n\}\)\nRangeAssist\.VisualGuideContractVersion', strip_lua_comments(bag_bridge_source), re.S)
    if range_read is None:
        failures.append("Range Assist contract missing: feature block unavailable")
    else:
        range_source = range_read.group(1)
        for token in (
            'projection:GetUnitWorldPosition("player", false)',
            'for index=1,count do',
            'local screenPoint=projected[index]',
        ):
            if token not in range_source:
                failures.append("Range Assist global/index-stable projection contract missing: " + token)
        if 'projection:GetUnitWorldPosition("player", true)' in range_source:
            failures.append("Range Assist regression: local player world position mixed with global camera frame")
        if re.search(r'ipairs\s*\(\s*type\s*\(\s*projected\s*\)', range_source):
            failures.append("Range Assist regression: sparse world projection consumed with ipairs")
    for token in (
        'RangeAssist.VisualGuideContractVersion = 4',
        'RangeAssist.WorldSpaceContractVersion = 1',
    ):
        if token not in bag_bridge_source:
            failures.append("Range Assist projection contract missing: " + token)

    # Team auto-role catalog v2: rows explicitly classified as Archer must map
    # to the dedicated TMROLE_RANGED_DEALER path.  The 6/8/9
    # (Wild/Shadowplay/Songcraft) regression is the concrete RU report that
    # exposed the old dealer mapping.
    team_catalog_path = root / "data/rs_team_auto_role_catalog.lua"
    team_catalog_source = team_catalog_path.read_text(encoding="utf-8-sig", errors="replace") if team_catalog_path.is_file() else ""
    for token in (
        "local C={ version=2, byClassKey={} }",
        'C.byClassKey["name_6_8_9"]={role="ranged", classType="Archer"}',
        "TeamTools.AutoRoleCatalogContractVersion = 1",
    ):
        source = team_catalog_source if token.startswith("local C=") or token.startswith("C.byClassKey") else bag_bridge_source
        if token not in source:
            failures.append("Team auto-role ranged catalog contract missing: " + token)
    if '{role="dealer", classType="Archer"}' in team_catalog_source:
        failures.append("Team auto-role regression: Archer row mapped to melee/general dealer")

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
    else:
        # Composite Foundation is intentionally fail-closed when its base
        # controls are not registered yet. A wrong TOC order therefore looks
        # like a perfectly valid file that silently exports zero contracts at
        # runtime (RU .18.80: TreeView nil on Buff Display open). Keep the
        # dependency order as a static package gate instead of relying on a
        # page crash to reveal it.
        composite_index = toc.index(composite_entry)
        for prerequisite in (
            "ui/framework/rs_ui_component_core.lua",
            "ui/framework/rs_ui_primitives.lua",
            "ui/framework/rs_ui_selection.lua",
            "ui/framework/rs_ui_data_views.lua",
            "ui/framework/rs_ui_controls.lua",
        ):
            if prerequisite not in toc:
                failures.append("Composite Foundation prerequisite missing from Active TOC: " + prerequisite)
            elif toc.index(prerequisite) >= composite_index:
                failures.append(
                    f"Composite Foundation TOC order regression: {prerequisite} must load before {composite_entry}"
                )
    if not re.search(r"RSUI\.CompositeFoundation\s*=\s*\{\s*version\s*=\s*5", composite_source, re.S):
        failures.append("Composite Foundation version regression: expected version 5")

    for token in (
        "StatusChipContractVersion = 1",
        "StatusSemanticsContractVersion = 1",
        "StateNoticeContractVersion = 1",
        "DetailHeaderContractVersion = 1",
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
    layout_templates_source = (root / "ui/framework/rs_ui_layout_templates.lua").read_text(encoding="utf-8-sig", errors="replace")
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
        "RSUI.InteractionServiceContractVersion = 3",
        "RSUI.InteractionPopupVisibilityContractVersion = 1",
        "local function EnsureVisible(widget, visible, owner)",
        "if okA == true and okB == true then",
        "tooltip_handler_pair_required",
        "UI:EnsureEnabled(row.button",
        "local function ApplyFocusInteraction(native, methodName)",
    ):
        if token not in interactions_source:
            failures.append(f"RSUI interaction contract missing: {token}")
    for token in (
        "RSUI.CollapsibleGroupInteractionContractVersion = 2",
        'c:RequireOn(headerHit, "OnClick"',
        'c.rsUiDegradedReason = "collapsible_header_create_failed"',
    ):
        if token not in layout_templates_source:
            failures.append(f"RSUI CollapsibleGroup interaction contract missing: {token}")

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
        "RSUI.TransformInspectorContractVersion = 3",
        'RSUI:RegisterTypeValidator("TransformInspector"',
        'RSUI:RegisterType("TransformInspector"',
        'function c:SetModels(nextRectModel, nextAnchorModel)',
        'function c:Measure(availableWidth, availableHeight)',
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
    layout_edit_history_entry = "ui/framework/rs_ui_layout_edit_history.lua"
    layout_edit_history_source = (root / layout_edit_history_entry).read_text(encoding="utf-8-sig", errors="replace") if (root / layout_edit_history_entry).is_file() else ""
    if layout_edit_history_entry not in toc:
        failures.append("Layout Edit History Foundation missing from Active TOC: " + layout_edit_history_entry)
    for token in (
        "RSUI.LayoutEditHistoryContractVersion = 1",
        "RSUI.LayoutEditHistoryObservableContractVersion = 1",
        "DEFAULT_MAX_COMMANDS = 64",
        "HARD_MAX_COMMANDS = 256",
        "function Model:Record(change)",
        "function Model:Subscribe(token, listener)",
        "function Model:Unsubscribe(token)",
        "function Model:Undo()",
        "function Model:Redo()",
        "function Model:_Rollback(command, state, items, direction, primaryError)",
        "layout_edit_history_key_set_changed",
    ):
        if token not in layout_edit_history_source:
            failures.append(f"Layout edit history contract missing: {token}")

    layout_edit_session_entry = "ui/framework/rs_ui_layout_edit_session.lua"
    layout_edit_session_source = (root / layout_edit_session_entry).read_text(encoding="utf-8-sig", errors="replace") if (root / layout_edit_session_entry).is_file() else ""
    if layout_edit_session_entry not in toc:
        failures.append("Layout Edit Session Foundation missing from Active TOC: " + layout_edit_session_entry)
    for token in (
        "RSUI.LayoutEditSessionContractVersion = 1",
        "RSUI.LayoutEditSessionPersistenceBoundaryContractVersion = 1",
        "RSUI.LayoutEditSessionLimits = {",
        "function Model:GetCommandSnapshot()",
        "function Model:GetStateSnapshot()",
        "function Model:RefreshWorking(source)",
        "function Model:ExecuteCommand(command, context)",
        "function Model:Rebase(source)",
        "function RSUI:CreateLayoutEditSessionModel(options)",
        'command ~= "revert" and command ~= "reset" and command ~= "apply"',
        'persist = false',
        'durable = true',
        'session_barrier:',
    ):
        if token not in layout_edit_session_source:
            failures.append(f"Layout Edit Session contract missing: {token}")
    layout_edit_session_code = strip_lua_strings(strip_lua_comments(layout_edit_session_source))
    if re.search(r"\bOnUpdate\b", layout_edit_session_code) or re.search(r"\bAddInteractiveTask\b", layout_edit_session_code):
        failures.append("Layout Edit Session must be event/command driven; no sampling loop allowed")
    for forbidden in ("S.Persistence", "S.Api", "SaveData", "ClearData", "SaveStore", "MarkDirty"):
        if forbidden in layout_edit_session_code:
            failures.append("Layout Edit Session crossed Persistence boundary directly: " + forbidden)

    editor_command_bar_entry = "ui/framework/rs_ui_editor_command_bar.lua"
    editor_command_bar_source = (root / editor_command_bar_entry).read_text(encoding="utf-8-sig", errors="replace") if (root / editor_command_bar_entry).is_file() else ""
    if editor_command_bar_entry not in toc:
        failures.append("Editor Command Bar missing from Active TOC: " + editor_command_bar_entry)
    for token in (
        "RSUI.EditorCommandBarContractVersion = 2",
        "RSUI.EditorCommandSessionProjectionContractVersion = 2",
        "blocked = blocked",
        "function RSUI.ProjectEditorCommandState(history, session)",
        'RSUI:RegisterTypeValidator("EditorCommandBar"',
        'RSUI:RegisterType("EditorCommandBar"',
        'self.historyModel:Unsubscribe(self.historyToken)',
        'self.sessionModel:Unsubscribe(self.sessionToken)',
        'self.sessionModel:ExecuteCommand(command',
    ):
        if token not in editor_command_bar_source:
            failures.append(f"Editor Command Bar contract missing: {token}")
    editor_command_bar_code = strip_lua_strings(strip_lua_comments(editor_command_bar_source))
    if re.search(r"\bOnUpdate\b", editor_command_bar_code) or re.search(r"\bAddInteractiveTask\b", editor_command_bar_code):
        failures.append("Editor Command Bar must be authority-event driven; no sampling loop allowed")

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
        "RSUI.LayoutEditorOverlayHistoryBindingContractVersion = 1",
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

    for rel, source in ((layout_editor_models_entry, layout_editor_models_source), (multi_transform_entry, multi_transform_source), (layout_edit_history_entry, layout_edit_history_source), (layout_editor_adapter_entry, layout_editor_adapter_source)):
        code = strip_lua_strings(strip_lua_comments(source))
        if re.search(r"\bOnUpdate\b", code) or re.search(r"\bAddInteractiveTask\b", code):
            failures.append("Pure layout editor model must not own sampling loop: " + rel)

    component_core_source = (root / "ui/framework/rs_ui_component_core.lua").read_text(encoding="utf-8-sig", errors="replace")
    adaptive_source = (root / "ui/framework/rs_ui_adaptive_panels.lua").read_text(encoding="utf-8-sig", errors="replace")
    workspace_source = (root / "ui/framework/rs_ui_workspace_templates.lua").read_text(encoding="utf-8-sig", errors="replace")
    for token in (
        "RSUI.ComponentApiContractVersion = 1",
        "function RSUI:RequireComponentMethods(component, methods, context)",
        "function Base:Show(visible)",
        "function Base:Hide()",
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
        "contractVersion = 6" not in workspace_source
        or "RSUI.LayoutEditorWorkspaceContractVersion = 4" not in workspace_source
        or "RSUI.LayoutEditorWorkspaceSessionBindingContractVersion = 1" not in workspace_source
        or "function T:ValidateLayoutEditorEditSessionSpec(editSessionSpec)" not in workspace_source
        or "CreateResponsiveInspectorWorkspace" not in workspace_source
        or "CreateLayoutEditorWorkspace" not in workspace_source
        or "function T:LayoutEditor(spec)" not in workspace_source
        or "historyModel = historyModel" not in workspace_source
        or "RSUI:CreateLayoutEditSessionModel" not in workspace_source
        or "RSUI:EditorCommandBar" not in workspace_source
        or "workspace_history:" not in workspace_source
        or "workspace_session:" not in workspace_source
        or "workspace.RebaseEditSession" not in workspace_source
        or "workspace.ExecuteCommand" not in workspace_source
        or "sessionModel:RefreshWorking" not in workspace_source
        or "workspace.sessionModel, workspace.historyModel = nil, nil" not in workspace_source
        or 'id = id .. "_inspector_toggle"' not in workspace_source
        or 'root:ToggleDrawer(true)' not in workspace_source
        or 'inspectorToggle:SetVisible(drawer)' not in workspace_source
        or 'RSUI:RequireComponentMethods(inspectorToggle' not in workspace_source
    ):
        failures.append("WorkspaceTemplates v5 layout-editor integration/drawer-affordance contract missing")
    workspace_code = strip_lua_strings(strip_lua_comments(workspace_source))
    if re.search(r"\bOnUpdate\b", workspace_code) or re.search(r"\bAddInteractiveTask\b", workspace_code):
        failures.append("LayoutEditorWorkspace integration must be authority-event driven; no sampling loop allowed")
    for forbidden in ("S.Persistence", "SaveData", "ClearData", "SaveStore", "MarkDirty"):
        if forbidden in workspace_code:
            failures.append("LayoutEditorWorkspace crossed Persistence boundary directly: " + forbidden)
    if "historyModel = spec.historyModel" not in layout_editor_overlay_source:
        failures.append("LayoutEditorOverlay must inject Workspace History into PreviewAdapter")
    if "inspectorToggle:Show(" in workspace_code:
        failures.append("LayoutEditorWorkspace must use common Component visibility API; inspectorToggle:Show is forbidden")

    # Developer package gate: Presentation variables constructed from a known
    # RSUI component type may only call Base/public type methods unless the call
    # is explicitly capability-guarded. This catches Lua-valid runtime failures
    # such as Button:UnknownMethod() before the page reaches the RU client.
    component_api_gate_ok = False
    component_api_audit = root / "tools/rs_rsui_component_api_audit.py"
    if not component_api_audit.is_file():
        failures.append("RSUI component API audit missing: tools/rs_rsui_component_api_audit.py")
    else:
        proc = subprocess.run(
            [sys.executable, str(component_api_audit), "--root", str(root)],
            capture_output=True, text=True, cwd=str(root),
        )
        output = (proc.stdout + proc.stderr).strip()
        if proc.returncode != 0:
            failures.append("RSUI component API audit failed: " + (output.replace("\n", " | ")[:1200] or "unknown"))
        elif "RSUI_COMPONENT_API_AUDIT PASS" not in output:
            failures.append("RSUI component API audit missing PASS marker")
        else:
            component_api_gate_ok = True

    # Developer package gate: Presentation must only call Feature/Commands
    # methods that are actually exported by the corresponding runtime feature.
    # This catches Lua-valid failures such as Feature.Commands:MissingMethod()
    # before a page/widget interaction reaches the RU client.
    presentation_feature_api_gate_ok = False
    presentation_feature_api_audit = root / "tools/rs_presentation_feature_api_audit.py"
    if not presentation_feature_api_audit.is_file():
        failures.append("Presentation Feature API audit missing: tools/rs_presentation_feature_api_audit.py")
    else:
        proc = subprocess.run(
            [sys.executable, str(presentation_feature_api_audit), "--root", str(root)],
            capture_output=True, text=True, cwd=str(root),
        )
        output = (proc.stdout + proc.stderr).strip()
        if proc.returncode != 0:
            failures.append("Presentation Feature API audit failed: " + (output.replace("\n", " | ")[:1600] or "unknown"))
        elif "PRESENTATION_FEATURE_API_AUDIT PASS" not in output:
            failures.append("Presentation Feature API audit missing PASS marker")
        else:
            presentation_feature_api_gate_ok = True

    # RSUI files are loaded by toc.g, and several foundations intentionally
    # fail closed at top-level when an upstream public constructor/table is not
    # available. Validate those dependencies against actual TOC order so a
    # harmless-looking file reorder cannot silently turn a later component into
    # nil at runtime (the historic TreeView/ListView class of failure).
    toc_index = {rel: idx for idx, rel in enumerate(toc)}
    dependency_guard_re = re.compile(
        r'if[^\n]*type\(RSUI\.([A-Za-z_]\w*)\)\s*~=\s*["\'](function|table)["\'][^\n]*then\s+return\s+end'
    )
    rsui_provider_cache = {}
    def _rsui_provider_before(name, kind, consumer_idx):
        cache_key = (name, kind, consumer_idx)
        if cache_key in rsui_provider_cache:
            return rsui_provider_cache[cache_key]
        patterns = []
        if kind == "function":
            patterns.extend((
                re.compile(r'RSUI:RegisterType\(\s*["\']' + re.escape(name) + r'["\']'),
                re.compile(r'RSUI:ReplaceType\(\s*["\']' + re.escape(name) + r'["\']'),
                re.compile(r'function\s+RSUI:' + re.escape(name) + r'\s*\('),
            ))
        else:
            patterns.append(re.compile(r'RSUI\.' + re.escape(name) + r'\s*='))
        found = None
        for provider_idx, provider_rel in enumerate(toc[:consumer_idx]):
            provider_path = root / provider_rel
            if not provider_path.is_file() or provider_path.suffix.lower() != ".lua":
                continue
            provider_source = provider_path.read_text(encoding="utf-8-sig", errors="replace")
            if any(pattern.search(provider_source) for pattern in patterns):
                found = provider_rel
                break
        rsui_provider_cache[cache_key] = found
        return found

    rsui_dependency_checks = 0
    for consumer_rel in toc:
        if not consumer_rel.startswith("ui/framework/") or not consumer_rel.endswith(".lua"):
            continue
        consumer_path = root / consumer_rel
        if not consumer_path.is_file():
            continue
        consumer_source = consumer_path.read_text(encoding="utf-8-sig", errors="replace")
        consumer_head = "\n".join(consumer_source.splitlines()[:60])
        consumer_idx = toc_index[consumer_rel]
        for dep_name, dep_kind in dependency_guard_re.findall(consumer_head):
            rsui_dependency_checks += 1
            provider = _rsui_provider_before(dep_name, dep_kind, consumer_idx)
            if provider is None:
                failures.append(
                    f"RSUI TOC dependency order invalid: {consumer_rel} requires RSUI.{dep_name} ({dep_kind}) before load"
                )

    # Package-coherence fence: `.18.84` declared the Fresh Reload fingerprint
    # contract in CURRENT/Gate. All runtime pieces must ship together; otherwise
    # a later incremental package can accidentally retain the Gate/docs while
    # dropping the Persistence implementation or diagnostics action.
    persistence_source = (root / "core/rs_persistence.lua").read_text(encoding="utf-8-sig", errors="replace")
    foundation_pages_source = (root / "presentation/v3/pages/rs_v3_foundation_pages.lua").read_text(encoding="utf-8-sig", errors="replace")
    for token in (
        "RuntimeAcceptanceSnapshotContractVersion = 2",
        "function P:FingerprintPayload(value, budget)",
        "function P:BuildRuntimeAcceptanceSnapshot(options)",
        "runtimeAcceptanceSnapshotContractVersion = self.RuntimeAcceptanceSnapshotContractVersion",
    ):
        if token not in persistence_source:
            failures.append("Persistence Runtime Acceptance Snapshot implementation missing: " + token)
    for token in (
        "PERSISTENCE_ACCEPTANCE_STORE_IDS",
        "local function BuildPersistenceAcceptanceCopyText()",
        'text = "输出存档验收"',
        "BuildRuntimeAcceptanceSnapshot",
    ):
        if token not in foundation_pages_source:
            failures.append("Persistence Runtime Acceptance diagnostics UI missing: " + token)

    # Buff Display is currently the first real consumer of LayoutEditorWorkspace.
    # Its edited rects live in editor-local coordinates while PointerService is
    # viewport-logical. Never regress to declaring `local` without an explicit
    # conversion; doing so passes source review but is correctly rejected by the
    # strict runtime type validator and quarantines the whole page on RU.
    buff_display_source = (root / "presentation/v3/pages/rs_v3_buff_display_page.lua").read_text(encoding="utf-8-sig", errors="replace")
    if 'coordinateSpace = "local"' in buff_display_source and "pointerToLocal = ViewportPointerToEditorLocal" not in buff_display_source:
        failures.append("BuffDisplay LayoutEditorWorkspace local coordinate space missing pointerToLocal conversion")
    for token in (
        "local function ViewportPointerToEditorLocal(viewportX, viewportY, controller)",
        "S.Layout:GetLogicalRect(nativeRoot)",
        "(viewportX - originX) * editorWidth / liveWidth",
        "(viewportY - originY) * editorHeight / liveHeight",
        "autoOpenInspectorOnSelection = true",
        'if layoutWorkspace:GetMode() == "drawer" then layoutWorkspace:SetDrawerOpen(true, true) end',
        'if root.activeTab == "track" then root:Refresh() end',
    ):
        if token not in buff_display_source:
            failures.append("BuffDisplay editor interaction contract missing: " + token)

    buff_feature_source = (root / "features/combat/buff_display/rs_buff_display_feature.lua").read_text(encoding="utf-8-sig", errors="replace")
    for token in (
        'id = "v3_buff_display_equipment_toggles"',
        'id = "v3_buff_display_equipment_toggle_" .. componentKey',
        '{ key = "mainHand", label = "主手" }',
        '{ key = "offHand", label = "副手" }',
        '{ key = "ranged", label = "远程" }',
        '{ key = "wings", label = "背部" }',
    ):
        if token not in buff_display_source:
            failures.append("BuffDisplay self-equipment quick toggle contract missing: " + token)
    for token in (
        "F.EquipmentReadContractVersion = 1",
        "local gear = S.Services and S.Services.GearV3 or nil",
        "item, readErr = gear:GetEquipped(slotId)",
    ):
        if token not in buff_feature_source:
            failures.append("BuffDisplay GearV3 read authority contract missing: " + token)

    task_store_source = (root / "features/life/tasks/rs_task_store.lua").read_text(encoding="utf-8-sig", errors="replace")
    for token in (
        "local TASK_CODEC_VERSION = 2",
        "local function SortedKeyArray(value)",
        "local function EncodeTaskState(value)",
        "local function RebuildLegacyEncodedForIntegrity(raw)",
        "rebuildEncodedForIntegrity = RebuildLegacyEncodedForIntegrity",
    ):
        if token not in task_store_source:
            failures.append("Task persistence stable-codec contract missing: " + token)
    for token in (
        "rebuildEncodedForIntegrity = def.rebuildEncodedForIntegrity",
        'store.lastIntegrityStatus = "serializer_repair_verified"',
        'deferredSaveReason = "integrity_serializer_repair"',
    ):
        if token not in persistence_source:
            failures.append("Persistence proven serializer-repair contract missing: " + token)

    # .18.94 Trade/DPS Fresh Reload package-coherence preflight.  These are
    # user-visible regressions that are syntactically valid Lua, so lock the
    # exact Authority/Presentation shape before a package reaches the RU client.
    dps_store_source = (root / "features/combat/dps/rs_dps_store.lua").read_text(encoding="utf-8-sig", errors="replace")
    dps_widget_source = (root / "presentation/v3/widgets/rs_v3_dps_widget.lua").read_text(encoding="utf-8-sig", errors="replace")
    trade_feature_source = (root / "features/life/rs_life_m16_bundle.lua").read_text(encoding="utf-8-sig", errors="replace")
    trade_page_source = (root / "presentation/v3/pages/rs_v3_life_m16_pages.lua").read_text(encoding="utf-8-sig", errors="replace")
    trade_widget_source = (root / "presentation/v3/widgets/rs_v3_life_economy_widgets.lua").read_text(encoding="utf-8-sig", errors="replace")
    trade_detail_source = (root / "presentation/v3/widgets/rs_v3_trade_detail_floating.lua").read_text(encoding="utf-8-sig", errors="replace")
    business_feature_source = (root / "features/rs_business_bridge.lua").read_text(encoding="utf-8-sig", errors="replace")
    business_page_source = (root / "presentation/v3/pages/rs_v3_business_pages.lua").read_text(encoding="utf-8-sig", errors="replace")
    task_authority_source = (root / "features/life/tasks/rs_task_authority.lua").read_text(encoding="utf-8-sig", errors="replace")
    task_page_source = (root / "presentation/v3/pages/rs_v3_task_page.lua").read_text(encoding="utf-8-sig", errors="replace")
    acceptance_source = (root / "presentation/v3/rs_v3_acceptance.lua").read_text(encoding="utf-8-sig", errors="replace")

    for token in (
        "local SCHEMA = 4",
        "widgetVisible = value.widgetVisible == true",
        "function F:GetWidgetVisible()",
    ):
        if token not in dps_store_source and token not in (root / "features/combat/dps/rs_dps_feature.lua").read_text(encoding="utf-8-sig", errors="replace"):
            failures.append("DPS durable widget visibility contract missing: " + token)
    expected_dps_preference = "preference = function() return Feature:GetWidgetVisible() == true end"
    if expected_dps_preference not in dps_widget_source:
        failures.append("DPS lifecycle preference no longer reads durable widget visibility")
    if re.search(r"preference\s*=\s*function\s*\(\s*\)\s*return\s+true\s+end", strip_lua_comments(dps_widget_source)):
        failures.append("DPS lifecycle preference regressed to unconditional auto-show")

    for token in (
        'id = "v3_trade_from"',
        'id = "v3_trade_to"',
        'id = "v3_trade_ratio_mode"',
        'id = "v3_trade_commerce_mode"',
        "feature.Commands:QuotePendingMaterials()",
    ):
        if token not in trade_page_source:
            failures.append("Trade main-page dropdown/quote contract missing: " + token)
    for token in (
        'id = "v3_life_trade_widget_from"',
        'id = "v3_life_trade_widget_to"',
        'id = "v3_life_trade_widget_ratio_mode"',
        'id = "v3_life_trade_widget_commerce_mode"',
        'id = "v3_life_trade_widget_quote"',
        "Feature.Commands:QuotePendingMaterials()",
    ):
        if token not in trade_widget_source:
            failures.append("Trade floating dropdown/quote contract missing: " + token)
    for forbidden in ("起点◀", "起点▶", "终点◀", "终点▶"):
        if forbidden in trade_page_source or forbidden in trade_widget_source:
            failures.append("Trade redundant cycle-button UI regressed: " + forbidden)
    if "Commands:CycleFrom" in trade_page_source or "Commands:CycleTo" in trade_page_source \
            or "Commands:CycleFrom" in trade_widget_source or "Commands:CycleTo" in trade_widget_source:
        failures.append("Trade Presentation regressed to cycle-button route selection")
    for token in (
        "self.zones = NormalizeTradeZones(StaticTradeZones())",
        'Action("X2Store:GetSpecialtyRatioBetween"',
        "function Trade:QuotePendingMaterials()",
        "ApplyTradeMaterialProjectionToRow(row)",
        "local TRADE_FULL_RATIO = 130",
        "function TA:RefreshCommerceSkill()",
        "function Trade:SetRatioMode(mode)",
        "function Trade:SetCommerceMode(mode)",
        'commercePriceFormulaStatus = "unverified"',
    ):
        if token not in trade_feature_source:
            failures.append("Trade route/quote Authority contract missing: " + token)
    for token in (
        "TradeDpsFreshReloadPreflightContractVersion = 1",
        '"dps_widget_visibility_preference_contract"',
        '"trade_dropdown_quote_preflight_contract"',
    ):
        if token not in acceptance_source:
            failures.append("Trade/DPS runtime acceptance preflight missing: " + token)

    # .18.119 Trade/Craft/Task local continuation.  Explicit market queries
    # stay user-triggered; current/full comparison is local-only; commerce skill
    # remains observation-only until the exact RU payout formula is proven.
    for token in (
        "local function CraftProjection(feature)",
        "QuotePendingMaterials = function(feature)",
        'feature.Id .. ":craft"',
        'feature:Refresh("craft_quote_batch_completed")',
        'quote = " · 未询价"',
    ):
        if token not in business_feature_source:
            failures.append("Craft explicit batch quote contract missing: " + token)
    for token in (
        'id = "v3_business_" .. id .. "_material_quote"',
        "feature.Commands:QuotePendingMaterials()",
        "projection.pendingQuoteCount",
        "projection.quotedMaterialCostCopper",
    ):
        if token not in business_page_source:
            failures.append("Craft batch quote Presentation contract missing: " + token)
    for token in ('trackedText = tracked and "✓ 已追踪" or "＋ 可添加"',):
        if token not in task_authority_source:
            failures.append("Task custom tracking discoverability projection missing: " + token)
    for token in ('先选中父任务，再点“加入追踪/取消追踪”', 'width = 78'):
        if token not in task_page_source:
            failures.append("Task custom tracking discoverability UI missing: " + token)

    # .18.120 restores the safe/local portion of the old Trade workflow without
    # importing Legacy services: bounded persisted route favorites, explicit
    # sort selection, row detail and selected-row material quote all stay under
    # life_trade + PriceQuoteQueueV3 ownership.
    for token in (
        "function Trade:NormalizeFavorites(value)",
        "if #result >= 12 then break end",
        "function Trade:ToggleCurrentFavorite()",
        "function Trade:SelectFavorite(key)",
        "function Trade:SetSortMode(mode)",
        "function Trade:QuoteRowMaterials(rowKey)",
        "function Trade:GetRow(key)",
        "selectedKey = nil",
    ):
        if token not in trade_feature_source:
            failures.append("Trade detail/favorites Authority contract missing: " + token)
    for token in (
        'id = "v3_trade_favorite_dropdown"',
        'id = "v3_trade_favorite_toggle"',
        'id = "v3_trade_sort_mode"',
        "TradeDetailFloatingV3",
    ):
        if token not in trade_page_source:
            failures.append("Trade detail/favorites page contract missing: " + token)
    for token in (
        'id = "v3_life_trade_widget_favorite"',
        'id = "v3_life_trade_widget_favorite_toggle"',
        'id = "v3_life_trade_widget_sort"',
        "selectable = true",
        "TradeDetailFloatingV3",
    ):
        if token not in trade_widget_source:
            failures.append("Trade detail/favorites widget contract missing: " + token)
    for token in (
        "TradeDetailContractVersion = 1",
        'feature:AcquireConsumer("floating:trade_detail")',
        'feature.Commands:QuoteRowMaterials(M.rowKey)',
        'feature.Commands:ToggleCurrentFavorite()',
        "S.Events:SubscribeInternal",
    ):
        if token not in trade_detail_source:
            failures.append("Trade floating detail contract missing: " + token)
    for forbidden in ("X2Store", "X2Auction", "GetLowestPrice", "RequestQuote("):
        code = strip_lua_comments(trade_detail_source)
        if forbidden in code:
            failures.append("Trade floating detail bypasses Feature/Quote ownership: " + forbidden)

    # rs_business_bridge.lua intentionally sits on the Lua 5.1 top-level-local
    # ceiling. New business helpers must be nested/reused rather than pushing the
    # chunk past 200 active locals (which can make the whole addon fail to load).
    top_level_locals = 0
    for line in business_feature_source.splitlines():
        if not line.startswith("local "):
            continue
        declaration = line[6:]
        if declaration.startswith("function "):
            top_level_locals += 1
        else:
            lhs = declaration.split("=", 1)[0]
            top_level_locals += len([part for part in lhs.split(",") if part.strip()])
    if top_level_locals > 200:
        failures.append("Lua 5.1 business bridge top-level local budget exceeded: " + str(top_level_locals) + "/200")

    # .18.95-.18.100 + .18.113 Persistence Reliability v3-v8 + Gear dual-bank journal.
    # Package coherence must lock both the immediate readback contract and the
    # persisted cross-reload integrity / verified shard-replacement contract.
    gear_store_source = (root / "features/combat/gear/rs_gear_store.lua").read_text(encoding="utf-8-sig", errors="replace")
    gear_authority_source = (root / "features/combat/gear/rs_gear_authority.lua").read_text(encoding="utf-8-sig", errors="replace")
    gear_acceptance_source = (root / "features/combat/gear/rs_gear_acceptance.lua").read_text(encoding="utf-8-sig", errors="replace")
    for token in (
        "ReliabilityContractVersion = 8",
        "IntegrityContractVersion = 4",
        "ContentBlindCanonicalContractVersion = 3",
        "PreCanonicalIntegrityContractVersion = 2",
        "LegacyIntegrityContractVersion = 1",
        "SerializerNumericFingerprintContractVersion = 1",
        "EnvelopeIntegrityContractVersion = 1",
        "ScopeBindingContractVersion = 1",
        "function P:CanonicalIntegrityValue(store, domainValue)",
        "function P:FingerprintCanonicalValue(store, canonical, budget)",
        "function P:FingerprintEncodedPayload(raw, budget)",
        "function P:FingerprintEncodedPayloadV1(raw, budget)",
        "function P:FingerprintDurablePayload(value, budget)",
        "function P:FingerprintEnvelopeIntegrity(raw)",
        "raw.__rsmeta.reliabilityContract = self.ReliabilityContractVersion",
        "raw.__rsmeta.encodedFingerprint = encodedFingerprint",
        "function P:VerifyPersistedValue(storeOrId, expectedValue, resolvedKey)",
        "verifyAfterSave = def.verifyAfterSave == true",
        "recoverableReplacement = def.recoverableReplacement == true",
        "allowIntegrityUpgrade = def.allowIntegrityUpgrade ~= false",
        'store.loadStatus = "integrity_failed"',
        'store.loadStatus = "envelope_integrity_failed"',
        'store.loadStatus = "encoded_load_rejected"',
        'store.loadStatus = "decoded_load_rejected"',
        "readbackVerifyFailures = 0",
        "MinIntegrityReliabilityContractVersion = 4",
        "barrierVerifyAttempts = 0",
        "clearVerifyAttempts = 0",
        "durableVerifyAttempts = 0",
        "scopeBindingMismatches = 0",
        "unverifiedReloadRejects = 0",
        "STORE_UNVERIFIED_RELOAD_REJECTED",
        "deferredLoadResaves = 0",
        "terminalAutoRetrySuppressions = 0",
        "integrityCompatibilityLoads = 0",
        "integrityUpgradeRecoveries = 0",
        "integrityUpgradeValidationFailures = 0",
        "integrityUpgradeResaves = 0",
        "integrityCompatibilityResaves = 0",
        'store.lastIntegrityStatus = "legacy_v1_compatibility"',
        'deferredSaveReason = "integrity_v2_upgrade"',
        "needsBarrierVerify = false",
        "durability_barrier_verify_failed",
        'store.loadStatus = "clear_verify_failed"',
    ):
        if token not in persistence_source:
            failures.append("Persistence Reliability v8 integrity/barrier/scope contract missing: " + token)
    acceptance_version = re.search(r"S\.UIV3Acceptance\s*=\s*\{\s*version\s*=\s*(\d+)", acceptance_source, re.S)
    if acceptance_version is None or int(acceptance_version.group(1)) < 68:
        failures.append("Persistence Reliability runtime acceptance requires Foundation Acceptance >=68")
    for token in (
        "A.PersistenceReliabilityV3ContractVersion = 1",
        "A.PersistenceReliabilityV4ContractVersion = 1",
        "A.PersistenceReliabilityV5ContractVersion = 1",
        "A.PersistenceReliabilityV6ContractVersion = 1",
        "A.PersistenceReliabilityV7ContractVersion = 1",
        '"persistence_hardening_contract"',
    ):
        if token not in acceptance_source:
            failures.append("Persistence Reliability v7 runtime acceptance contract missing: " + token)
    for token in (
        "local PAYLOAD_SCHEMA = 2",
        "F.PayloadJournalContractVersion = 2",
        "F.PayloadIntegrityContractVersion = 1",
        "schemaVersion = 5",
        "function F:LoadPayloadForSet(set)",
        "function F:SavePayload(storageId, payload, bank)",
        "function F:ValidatePayloadStructure(payload)",
        "budget = INDEX_BUDGET,\n        verifyAfterSave = true",
        "verifyAfterSave = true",
        "recoverableReplacement = bankName ~= \"legacy\"",
        "replaceCorrupt = true",
        "local function EncodeCompactPayload(value)",
    ):
        if token not in gear_store_source:
            failures.append("Gear dual-bank payload journal contract missing: " + token)
    for token in (
        'local nextBank = previousBank == "a" and "b" or "a"',
        "F:SavePayload(set.storageId, payload, nextBank)",
        "gear_save_payload_bank_commit",
        "GEAR_PAYLOAD_REINITIALIZED",
    ):
        if token not in gear_authority_source:
            failures.append("Gear journal commit/recovery contract missing: " + token)
    for token in (
        '"gear_payload_journal_contract"',
        '"gear_compact_payload_roundtrip"',
        '"gear_payload_structure_corrupt_empty"',
    ):
        if token not in gear_acceptance_source:
            failures.append("Gear runtime acceptance journal guard missing: " + token)

    reliability_v3_harness = root / "tools/rs_persistence_reliability_v3_harness.py"
    if not reliability_v3_harness.is_file():
        failures.append("Persistence Reliability v3 fault-injection harness missing")
    reliability_v4_harness = root / "tools/rs_persistence_reliability_v4_harness.py"
    if not reliability_v4_harness.is_file():
        failures.append("Persistence Reliability v4 cross-reload integrity harness missing")
    reliability_v5_harness = root / "tools/rs_persistence_reliability_v5_harness.py"
    if not reliability_v5_harness.is_file():
        failures.append("Persistence Reliability v5 durability-barrier harness missing")
    reliability_v6_harness = root / "tools/rs_persistence_reliability_v6_harness.py"
    if not reliability_v6_harness.is_file():
        failures.append("Persistence Reliability v6 envelope/scope/durable harness missing")
    reliability_v7_harness = root / "tools/rs_persistence_reliability_v7_harness.py"
    if not reliability_v7_harness.is_file():
        failures.append("Persistence Reliability v7 generation-reload fence harness missing")

    controls_entry = "ui/framework/rs_ui_controls.lua"
    controls_source = (root / controls_entry).read_text(encoding="utf-8-sig", errors="replace") if (root / controls_entry).is_file() else ""
    forms_entry = "ui/framework/rs_ui_forms.lua"
    forms_source = (root / forms_entry).read_text(encoding="utf-8-sig", errors="replace") if (root / forms_entry).is_file() else ""
    for token in (
        "RSUI.InteractiveDraftContractVersion = 1",
        "RSUI.ControlTransactionContractVersion = 1",
        "RSUI.DropdownRuntimeInteractionContractVersion = 1",
        "function c:FailDropdownInteraction(reason)",
        "function c:EnsureChildEnabled(widget, desired, role)",
        "local function IsFocusedDraft(component)",
        "function c:IsEditing() return IsFocusedDraft(self) end",
        "function c:IsInteracting() return self.root ~= nil and self.root.rsDragging == true end",
        "CountDraftSuppression()",
        'self:Render(value, "interaction")',
        'self:Render(value, "commit")',
    ):
        if token not in controls_source:
            failures.append("RSUI Interactive Draft contract missing: " + token)
    for token in (
        "RSUI.NumericInlineContractVersion = 4",
        "RSUI.NumericStepPairFallbackContractVersion = 1",
        "buildOptional = true",
        "c.minus, c.plus = nil, nil",
        'SyncControls(Current(), "binding_refresh")',
        'c.input:Render(value, "interaction")',
        'SyncControls(actual, "commit")',
    ):
        if token not in forms_source:
            failures.append("RSUI NumericField draft-preservation contract missing: " + token)

    # Native Interaction ABI hard fence. RU WidgetBase documents EnablePick /
    # Clickable as one-argument calls. Extra arguments were historically hidden
    # inside pcall(), leaving sliders/scrollbars/editors visibly present but
    # non-interactive while every static/runtime summary still reported green.
    native_primitives_source = (root / "ui/rs_ui_native_primitives.lua").read_text(encoding="utf-8-sig", errors="replace")
    ui_framework_source = (root / "ui/rs_ui_framework.lua").read_text(encoding="utf-8-sig", errors="replace")
    native_adapter_source = (root / "presentation/v3/rs_v3_native_adapter.lua").read_text(encoding="utf-8-sig", errors="replace")
    app_shell_source = (root / "presentation/v3/rs_v3_shell.lua").read_text(encoding="utf-8-sig", errors="replace")
    esc_bridge_source = (root / "native/rs_native_esc_bridge.lua").read_text(encoding="utf-8-sig", errors="replace")
    native_recovery_source = (root / "native/rs_native_recovery.lua").read_text(encoding="utf-8-sig", errors="replace")
    runtime_source = (root / "core/rs_runtime.lua").read_text(encoding="utf-8-sig", errors="replace")
    bootstrap_source = (root / "replicatedsuite.lua").read_text(encoding="utf-8-sig", errors="replace")
    foundation_gate_source = (root / "core/rs_foundation_gate.lua").read_text(encoding="utf-8-sig", errors="replace")
    for token in (
        "NativeInteractionContractVersion = 6",
        "CriticalInteractionDeliveryContractVersion = 1",
        "local NATIVE_BOOLEAN_STATE_SETTERS = {",
        "if not falseStateSetter then return false",
        "function UIX:TryInteractionCall(widget, methodName, ...)",
        "function UIX:RequireHandler(widget, eventName, fn, label)",
        "if ConfigureNativePickable(edit, true) ~= true then error",
        'CallNativeAccepted(edit, "EnableKeyboard", false)',
        "edit.rsUiKeyboardInput = true",
        "edit.rsUiParent = stateParent",
        'CallNativeAccepted(edit, "SetReadOnly", false)',
        "slider.rsUiSetEnabledAdapter = ApplySliderEnabled",
        "local dragStartBound = UIX:SafeHandler",
        "local dragStopBound = UIX:SafeHandler",
        "PrimitiveFailureDetail",
        "return FailPrimitive(",
    ):
        if token not in native_primitives_source:
            failures.append("Native primitive interaction/fail-closed contract missing: " + token)
    for token in (
        "NativeBooleanSetterReturnContractVersion = 1",
        "InputFocusLifecycleContractVersion = 2",
        "HiddenInputFocusIsolationContractVersion = 2",
        "function UI:ReleaseFocusWithin(widget, owner, reason)",
        "function UI:RetireInputWidget(widget, owner, reason)",
        "function UI:QuiesceKeyboardInput(reason, retire)",
        "DeferredKeyboardActivationContractVersion = 1",
        "function UI:ArmInputWidget(widget, owner, reason)",
        "function UI:DisarmInputWidget(widget, owner, reason)",
        "function UI:ActivateInputWidget(widget, owner, reason)",
        "function UI:DisarmInputWithin(widget, owner, reason)",
        "function UI:BindDeferredInputActivation(widget, owner, label)",
        "rsUiKeyboardInputSubtreeCount",
        "RegisterInputTarget(widget)",
        "CompositeEnabledAdapterContractVersion = 2",
        "local enabledAdapter = widget.rsUiSetEnabledAdapter",
        "if calls == 0 then",
    ):
        if token not in ui_framework_source:
            failures.append("UI interaction adapter contract missing: " + token)
    if 'if result == false then return false, tostring(methodName) .. "_rejected" end' in native_primitives_source:
        failures.append("Native primitive setter return contract regressed: boolean false must not be treated as transport rejection")
    for function_name in ("SetVisible", "SetPickable"):
        match = re.search(
            rf"function UI:{function_name}\b(.*?)(?=\nfunction UI:|\Z)",
            ui_framework_source,
            re.S,
        )
        if match is None:
            failures.append("UI boolean setter contract missing function: " + function_name)
        elif "result == false" in match.group(1):
            failures.append("UI boolean setter return contract regressed in " + function_name)
    for token in (
        "S.NativeEscBridge = {",
        "version = 2",
        "IdempotentRegistrationContractVersion = 1",
        "function E:IsReady(contentId)",
        "content id already bound to another widget this generation",
    ):
        if token not in esc_bridge_source:
            failures.append("Native ESC idempotent registration contract missing: " + token)
    for token in (
        "local callOk, installed, installErr = pcall",
        "if callOk ~= true or installed ~= true then",
        "S.RecoveryEntryHealthy = false",
        "S.RecoveryEntryError = detail",
    ):
        if token not in native_recovery_source:
            failures.append("Native recovery result contract missing: " + token)
    for token in (
        "version = 5",
        "function R:RegisterEscMenu(reason)",
        "function R:ScheduleEscRegistrationRetry(delayMs)",
        "function R:Describe()",
        'self:RegisterEscMenu("startup")',
        'self:ScheduleEscRegistrationRetry(750)',
        'S.Runtime:RegisterEscMenu("recovery_click")',
        'BootstrapNativeAccepted(button, "Show", true)',
        'S.RecoveryEntryHealthy = true',
    ):
        source = bootstrap_source if ("recovery_click" in token or "BootstrapNativeAccepted" in token or "RecoveryEntryHealthy" in token) else runtime_source
        if token not in source:
            failures.append("Runtime entry lifecycle contract missing: " + token)
    if "RevealExistingSuiteShell" in bootstrap_source:
        failures.append("Runtime fail-closed regression: bootstrap may reveal a partially initialized Suite shell")
    for token in (
        "S.RecoveryLauncherContractVersion = 2",
        "S.RecoveryLauncherLogicalSize = RECOVERY_BUTTON_SIZE",
        "button:SetAutoResize(false)",
        "button:SetWidth(RECOVERY_BUTTON_SIZE)",
        "button:SetHeight(RECOVERY_BUTTON_SIZE)",
        "button.rsIgnoreClick = moved == true",
        'if moved == true and S.Layout ~= nil and type(S.Layout.StorePlacement) == "function"',
        "math.abs(endX - startX) > RECOVERY_DRAG_MOVE_EPSILON",
    ):
        if token not in bootstrap_source:
            failures.append("Recovery launcher input contract missing: " + token)
    for token in (
        "S.RecoveryCommandContractVersion = 2",
        "S.RecoveryInputIsolationContractVersion = 1",
        "function S.ExecuteRecoveryCommand(text)",
        'command == "reload" or command == "rsreload" or command == "rs reload"',
        'return ReloadCodeFromDisk("recovery_command")',
        "S.RecoveryReloadContractVersion = 1",
        "local requireDurable = options.requireDurable == true",
        "reload continuing after persistence flush failure",
        "function S.InstallRecoveryCommandBar()",
        'edit.SetHandler, edit, "OnEnterPressed", SubmitRecoveryCommand',
        "function S.SetRecoveryCommandBarVisible(visible)",
    ):
        if token not in bootstrap_source:
            failures.append("Recovery command contract missing: " + token)
    for forbidden in ("SlashCmdList", "GetChatCommands", 'SetHandler("OnUpdate"'):
        if forbidden in bootstrap_source[bootstrap_source.find("function S.InstallRecoveryCommandBar()"):bootstrap_source.find("local function ReadRecoveryPosition")]:
            failures.append("Recovery command bar must not depend on unverified chat/polling ABI: " + forbidden)
    if 'S.InstallRecoveryCommandBar()' not in native_recovery_source:
        failures.append("Native recovery installer missing independent command bar install")
    for token in (
        'S.SetRecoveryCommandBarVisible(true)',
        'S.SetRecoveryCommandBarVisible(false)',
    ):
        if token not in runtime_source:
            failures.append("Runtime recovery command visibility contract missing: " + token)
    app_state_source = (root / "core/rs_app_state_v3.lua").read_text(encoding="utf-8-sig", errors="replace")
    shell_store_source = (root / "presentation/v3/rs_v3_shell_store.lua").read_text(encoding="utf-8-sig", errors="replace")
    launcher_store_source = (root / "presentation/v3/rs_v3_launcher_store.lua").read_text(encoding="utf-8-sig", errors="replace")
    for source_name, source_text, token in (
        ("app", app_state_source, "if self.sessionFallback == true then return ApplyMutation() end"),
        ("shell", shell_store_source, 'if self.ShellStoreSessionFallback == true then return true, "session_fallback_no_persist" end'),
        ("launcher", launcher_store_source, 'if self.LauncherStoreSessionFallback == true then return true, "session_fallback_no_persist" end'),
    ):
        if token not in source_text:
            failures.append("Startup session-fallback no-persist contract missing: " + source_name)
    for token in (
        "local LAUNCHER_LOGICAL_SIZE = 30",
        "local size = LAUNCHER_LOGICAL_SIZE",
        "LAUNCHER_LOGICAL_SIZE, LAUNCHER_LOGICAL_SIZE",
    ):
        if token not in launcher_store_source:
            failures.append("Recovery launcher sizing contract missing: " + token)
    apply_launcher = launcher_store_source[launcher_store_source.find("function V3:ApplyLauncherPlacement"):launcher_store_source.find("function V3:ResetLauncherPlacement")]
    if "addonScale" in apply_launcher:
        failures.append("Recovery launcher sizing regression: ApplyLauncherPlacement must not multiply by addonScale")
    foundation_gate_version = re.search(r"S\.FoundationGate\s*=\s*\{\s*version\s*=\s*(\d+)", foundation_gate_source, re.S)
    if foundation_gate_version is None or int(foundation_gate_version.group(1)) < 113:
        failures.append("Foundation ESC lifecycle gate requires version >=113")
    for token in (
        '"native_esc_bridge_contract"',
        '"runtime_entry_lifecycle_contract"',
        '"native_esc_menu_runtime"',
        '"bootstrap_recovery_entry"',
        '"recovery_launcher_input_contract"',
        '"runtime_startup_degradation"',
    ):
        if token not in foundation_gate_source:
            failures.append("Foundation ESC lifecycle gate missing: " + token)

    for token in (
        "DegradedRootFailClosedContractVersion = 1",
        "EventBindingContractVersion = 1",
        "PostFactoryRejectReleaseContractVersion = 1",
        "local function RejectComponent(reason)",
        "component_root_unusable:",
        "if channel.handlers[index] == subscription then table.remove(channel.handlers, index); break end",
    ):
        if token not in component_core_source:
            failures.append("RSUI degraded-root fail-closed contract missing: " + token)

    controls_source = (root / "ui/framework/rs_ui_controls.lua").read_text(encoding="utf-8-sig", errors="replace")
    for token in (
        "RSUI.PopupVisibilityTransactionContractVersion = 1",
        "local function EnsureRawVisible(widget, visible, owner)",
        'EnsureRawVisible(self.popup, true, self.owner)',
        'EnsureRawVisible(self.popup, false, self.owner)',
    ):
        if token not in controls_source:
            failures.append("RSUI popup visibility transaction contract missing: " + token)

    primitives_source = (root / "ui/framework/rs_ui_primitives.lua").read_text(encoding="utf-8-sig", errors="replace")
    for token in (
        "RSUI.ButtonActionContractVersion = 2",
        "function c:SetOnClick(fn)",
        "function c:GetOnClick()",
        "function c:Click(...)",
        'c:RequireOn(button, "OnClick", function(...) return c:Click(...) end',
    ):
        if token not in primitives_source:
            failures.append("RSUI Button action ownership contract missing: " + token)

    widget_host_source = (root / "presentation/v3/widgets/rs_v3_widget_host.lua").read_text(encoding="utf-8-sig", errors="replace")
    for token in (
        "version = 14",
        "preferenceInitializationContractVersion = 2",
        "self.stats.preferenceLoadFailures",
        "local prepared, prepareErr = EnsurePreferences(spec)",
        'V3_WIDGET_PREFERENCE_LOAD_FAILED',
    ):
        if token not in widget_host_source:
            failures.append("WidgetHost preference initialization contract missing: " + token)

    windowing_source = (root / "ui/framework/rs_ui_windowing.lua").read_text(encoding="utf-8-sig", errors="replace")
    scrollbar_source = (root / "ui/framework/rs_ui_scrollbar.lua").read_text(encoding="utf-8-sig", errors="replace")
    adaptive_source = (root / "ui/framework/rs_ui_adaptive_panels.lua").read_text(encoding="utf-8-sig", errors="replace")
    data_views_source = (root / "ui/framework/rs_ui_data_views.lua").read_text(encoding="utf-8-sig", errors="replace")
    for source_name, source, tokens in (
        ("Windowing", windowing_source, ("CriticalInteractionContractVersion = 3", "DragSurfaceHitTestContractVersion = 1", "ExplicitDragConditionContractVersion = 1", "StateMutationTransactionContractVersion = 1", "GeometryCallbackTransactionContractVersion = 1", "local function EnsureNativeResizing", "UI:EnsureEnabled(dragHandle, true, owner)", "UI:EnsurePickable(dragHandle, true, owner)", "UI:RequireHandler(dragHandle", "UI:TryInteractionCall(window, \"StartMoving\")", "UI:TryInteractionCall(window, \"StartSizing\", handleDefinition.direction)", "geometryCallbackRejects")),
        ("Scrollbar", scrollbar_source, ("criticalInteractionContractVersion = 1", "UI:RequireHandler(drag", "UI:TryInteractionCall(drag, \"StartMoving\")")),
        ("SplitView", adaptive_source, ("UI:RequireHandler(dividerDrag", "UI:TryInteractionCall(dividerDrag, \"StartMoving\")", "scrollbar_attach_failed:")),
        ("DataView", data_views_source, ("UI:RequireHandler(handle,\"OnDragStart\"", "UI:TryInteractionCall(handle, \"StartMoving\")", "table_column_resize_handle_create_failed:", "scrollbar_attach_failed:")),
    ):
        for token in tokens:
            if token not in source:
                failures.append(source_name + " critical interaction contract missing: " + token)

    window_shell_source = (root / "ui/framework/rs_ui_window_shell_v3.lua").read_text(encoding="utf-8-sig", errors="replace")
    floating_surface_source = (root / "ui/framework/rs_ui_floating_surface.lua").read_text(encoding="utf-8-sig", errors="replace")
    modal_host_source = (root / "presentation/v3/shell/rs_v3_modal_host.lua").read_text(encoding="utf-8-sig", errors="replace")
    panels_source = (root / "ui/framework/rs_ui_panels.lua").read_text(encoding="utf-8-sig", errors="replace")
    component_core_source = (root / "ui/framework/rs_ui_component_core.lua").read_text(encoding="utf-8-sig", errors="replace")
    ui_framework_source = (root / "ui/rs_ui_framework.lua").read_text(encoding="utf-8-sig", errors="replace")
    for token in ("BorderInteractionForwardingContractVersion = 1", "pickable=spec.pickable == true", "owner=spec.owner"):
        if token not in panels_source:
            failures.append("Border interaction forwarding contract missing: " + token)
    for token in ("InputLifecycleBridgeContractVersion = 1", "UI:RetireInputWidget(self.root"):
        if token not in component_core_source:
            failures.append("RSUI input lifecycle bridge missing: " + token)
    for token in ('inputQuiescenceContractVersion = 1', 'S.UI:QuiesceKeyboardInput("runtime_stop", false)', 'S.UI:QuiesceKeyboardInput("runtime_ready", false)'):
        if token not in runtime_source:
            failures.append("Runtime input quiescence contract missing: " + token)
    if 'previousUI:QuiesceKeyboardInput("bootstrap_hot_reload", true)' not in bootstrap_source:
        failures.append("Bootstrap old-generation input retirement missing")
    for source_name, source, tokens in (
        ("UIFacade", ui_framework_source, ("NativeBooleanSetterReturnContractVersion = 1", "InputFocusLifecycleContractVersion = 2", "HiddenInputFocusIsolationContractVersion = 2", "GeometryStateTransactionContractVersion = 1", "function UI:EnsureVisible", "function UI:EnsureEnabled", "function UI:EnsurePickable", "function UI:EnsureAlpha", "function UI:EnsureAnchor", "function UI:EnsureExtent")),
        ("WindowShell", window_shell_source, ("version = 24", "titleBarInteractionContract = 1", "pickable = true", "visibilityTransactionContract = 1", "stateMutationTransactionContract = 1", "stateCallbackTransactionContract = 1", "topLevelLayerContractVersion = 1", "EnsureWindowVisible", "EnsureComponentVisibility", "stateCallbackRejects", "window_lock_native_rejected")),
        ("FloatingSurface", floating_surface_source, ("StateMutationTransactionContractVersion = 1", "local function CommitState", "rollback")),
        ("ModalHost", modal_host_source, ("version = 6", "visibilityTransactionContractVersion = 1", "local function SetVisible(instance, visible)")),
        ("NativeAdapter", native_adapter_source, ("RootInteractionPolicyContractVersion = 2", "UI:EnsureVisible(window, false, owner)", "UI:EnsureAnchor(widget, UIParent", "UI:EnsureExtent(widget")),
        ("ApplicationShell", app_shell_source, ("Shell.StateMutationTransactionContractVersion = 1", "EnsureComponentVisibility", "local previous = {}", "主窗口几何提交失败")),
    ):
        for token in tokens:
            if token not in source:
                failures.append(source_name + " state transaction contract missing: " + token)

    # Presentation must never bind native events directly to an RSUI component
    # root. Doing so overwrites the component-owned event mux and bypasses the
    # enabled/release/action fences. Native widgets created intentionally by a
    # specialized Presenter remain allowed; this scan is narrowly scoped to
    # `.root` escapes from RSUI components.
    presentation_root_handler_refs: list[str] = []
    component_root_safe_re = re.compile(r"\bSafeHandler\s*\(\s*(?:[A-Za-z_]\w*\.)+root\s*,")
    presentation_root_set_re = re.compile(r"\b(?:[A-Za-z_]\w*\.)+root\s*:\s*(SetHandler|ReleaseHandler)\s*\(")
    for rel in active_lua:
        source = strip_lua_comments((root / rel).read_text(encoding="utf-8-sig", errors="replace"))
        for match in component_root_safe_re.finditer(source):
            presentation_root_handler_refs.append(f"{rel}:{line_for(source, match.start())}:SafeHandler")
        if rel.startswith("presentation/v3/"):
            for match in presentation_root_set_re.finditer(source):
                presentation_root_handler_refs.append(f"{rel}:{line_for(source, match.start())}:{match.group(1)}")
    if presentation_root_handler_refs:
        failures.append("Native handler escaped RSUI component root/action ownership: " + ", ".join(presentation_root_handler_refs[:30]))

    ignored_critical_handlers: list[str] = []
    critical_handler_re = re.compile(r"(?m)^\s*(?!local\s+\w+\s*=|return\s+)(?:S\.)?UI:SafeHandler\s*\([^\n]*[\"'](OnClick|OnDragStart|OnDragStop)[\"']")
    for rel in active_lua:
        source = strip_lua_comments((root / rel).read_text(encoding="utf-8-sig", errors="replace"))
        for match in critical_handler_re.finditer(source):
            ignored_critical_handlers.append(f"{rel}:{line_for(source, match.start())}:{match.group(1)}")
    if ignored_critical_handlers:
        failures.append("Critical native handler binding result ignored: " + ", ".join(ignored_critical_handlers[:30]))

    invalid_interaction_arity: list[str] = []
    direct_arity_re = re.compile(r":(EnablePick|Clickable|EnableFocus|EnableKeyboard|EnableDrag|SetDragCondition|SetReClickable|SetReadOnly)\s*\([^\n]*,")
    native_safe_arity_re = re.compile(r"NativeSafe\.Call\s*\([^\n]*[\"'](EnablePick|Clickable|EnableFocus|EnableKeyboard|EnableDrag|SetDragCondition|SetReClickable|SetReadOnly)[\"'][^\n]*,[^\n]*,")
    for rel in active_lua:
        source = (root / rel).read_text(encoding="utf-8-sig", errors="replace")
        code = strip_lua_strings(strip_lua_comments(source))
        for match in direct_arity_re.finditer(code):
            invalid_interaction_arity.append(f"{rel}:{line_for(code, match.start())}:{match.group(1)}")
        # NativeSafe method names are string arguments, so use comment-stripped
        # source rather than string-stripped code for this narrow pattern.
        commentless = strip_lua_comments(source)
        for match in native_safe_arity_re.finditer(commentless):
            invalid_interaction_arity.append(f"{rel}:{line_for(commentless, match.start())}:NativeSafe.{match.group(1)}")
    if invalid_interaction_arity:
        failures.append("Invalid RU WidgetBase interaction call arity: " + ", ".join(invalid_interaction_arity[:20]))

    warn_once_colon_refs: list[str] = []
    for rel in active_lua:
        source = (root / rel).read_text(encoding="utf-8-sig", errors="replace")
        code = strip_lua_strings(strip_lua_comments(source))
        for match in re.finditer(r"\bS\s*:\s*WarnOnce\s*\(", code):
            warn_once_colon_refs.append(f"{rel}:{line_for(code, match.start())}")
    if warn_once_colon_refs:
        failures.append("WarnOnce dot/colon ABI regression: " + ", ".join(warn_once_colon_refs[:20]))

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
    if any(token not in token_source for token in (
        "version = 5", "shellPriority = 100", "floatingPriority = 1000",
        "popupPriority = 10000", "modalPriority = 12000",
    )):
        failures.append("UI token top-level layer contract missing: ui/framework/rs_ui_tokens.lua")

    controls_source = (root / "ui/framework/rs_ui_controls.lua").read_text(encoding="utf-8-sig", errors="replace")
    if "DropdownDegradedFailClosedContractVersion = 1" not in controls_source:
        failures.append("Dropdown degraded fail-closed contract missing: ui/framework/rs_ui_controls.lua")
    if "PopupCoordinatorContractVersion = 1" not in controls_source or "RSUI.DropdownService = PopupCoordinator" not in controls_source:
        failures.append("Popup coordinator single-registry contract missing: ui/framework/rs_ui_controls.lua")
    if "PopupCoordinator:Unregister(self)" not in controls_source:
        failures.append("Popup component release unregister contract missing: ui/framework/rs_ui_controls.lua")

    native_primitives_source = (root / "ui/rs_ui_native_primitives.lua").read_text(encoding="utf-8-sig", errors="replace")
    window_shell_source = (root / "ui/framework/rs_ui_window_shell_v3.lua").read_text(encoding="utf-8-sig", errors="replace")
    floating_surface_source = (root / "ui/framework/rs_ui_floating_surface.lua").read_text(encoding="utf-8-sig", errors="replace")
    app_shell_source = (root / "presentation/v3/rs_v3_shell.lua").read_text(encoding="utf-8-sig", errors="replace")
    interaction_source_for_popup = (root / "ui/framework/rs_ui_interactions.lua").read_text(encoding="utf-8-sig", errors="replace")
    top_level_tokens = (
        "TopLevelTransientWindowContractVersion = 1",
        "opts.transientWindow == true",
        "factory:CreateWindow",
        'SetUILayer(tostring(opts.uiLayer or "system"))',
        "panel.rsUiTransientWindow = transientWindow == true",
    )
    for token in top_level_tokens:
        if token not in native_primitives_source:
            failures.append("Top-level transient native window contract missing: " + token)
    for source_name, source_text, tokens in (
        ("Dropdown/ColorField", controls_source, ("PopupNativeWindowContractVersion = 1", "transientWindow = true", "visible = false", "pickable = false")),
        ("ContextMenu", interaction_source_for_popup, ("transientWindow = true", "visible = false", "pickable = false")),
        ("WindowShell layer", window_shell_source, ("topLevelLayerContractVersion = 1", 'window:SetUILayer("system")', 'layerRole or "window"', 'layer.floatingPriority')),
        ("FloatingSurface layer", floating_surface_source, ('layerRole = "floating"',)),
        ("Application Shell layer", app_shell_source, ('layer.shellPriority', 'window.rsUiLayerRole = "shell"')),
    ):
        for token in tokens:
            if token not in source_text:
                failures.append(source_name + " top-level layer contract missing: " + token)
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
        + f" serviceUpward={len(service_upward_failures)}"
        + f" productTruth={len(product_truth_failures)}"
        + f" auctionEventOwners={len(auction_event_authority_failures)}"
        + f" retiredUiLayer={len(retired_ui_layer_failures)}"
        + f" rsuiComponentApi={1 if component_api_gate_ok else 0}"
        + f" presentationFeatureApi={1 if presentation_feature_api_gate_ok else 0}"
        + f" rsuiLoadDeps={rsui_dependency_checks}"
        + f" presentationRootHandlers={len(presentation_root_handler_refs)}"
    )
    for item in failures:
        print("FAIL | " + item)
    for item in notes:
        print("NOTE | " + item)
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())

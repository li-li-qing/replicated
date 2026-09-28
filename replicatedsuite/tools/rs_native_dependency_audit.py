#!/usr/bin/env python3
"""Replicated Suite Phase 0 native dependency ownership audit.

Purpose:
- prove that an implementation-level ApiDependencies override cannot silently
  drop a namespace already declared by FeatureRegistry;
- inventory shared-service Native usage and Feature -> Service transitive gaps;
- detect Native namespaces used by shipped runtime code but absent from the
  curated NativeContract.

The audit is deliberately namespace-scoped because ADDON:ImportAPI imports a
namespace, while feature metadata remains method-capability scoped.
It does not mutate runtime files and it does not infer unknown API_TYPE ids.
"""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import re
import sys
from typing import Dict, Iterable, List, Optional, Sequence, Set, Tuple

ROOT = Path(__file__).resolve().parents[1]
FEATURES = ROOT / "features"
SERVICES = ROOT / "services"
NATIVE_CONTRACT = ROOT / "native" / "rs_native_contract.lua"
REGISTRY = FEATURES / "rs_feature_registry.lua"

FOUNDATION_NATIVE_NAMES = {"ADDON", "X2Chat", "X2Locale", "X2Option", "X2Unit"}

# Phase 0 first standalone-bootstrap matrix. These rows are limited to call chains
# already proven by production diagnostics/source tracing; optional sub-capabilities
# are intentionally not promoted to hard requirements here.
STANDALONE_REQUIRED_NAMESPACES = {
    "life_trade": {"X2Store", "X2Ability", "X2Equipment", "X2Craft", "X2Auction"},
    "life_bonds": {"X2Resident", "X2Bag", "X2Quest"},
    "combat_buff_display": {"X2Ability", "X2Equipment"},
}

# Proven Feature -> Shared Service Native edge policy. The same service file may
# expose methods with different Native needs, so source-wide namespace union must
# never be promoted wholesale into a Feature hard dependency.
#
# required: namespace used by the exact service method path this Feature consumes.
# optional: namespace belongs to other service methods / graceful enrichment paths.
# lazy: namespace is needed only when a user-enabled sub-capability or drill-down
#       actually executes; it must be owned by the service/lazy capability boundary.
SERVICE_EDGE_NATIVE_POLICY = {
    ("combat_buff_display", "GearV3"): {
        "required": {"X2Equipment"},
        "optional": {"X2Bag", "X2Player"},
        "lazy": set(),
    },
    ("combat_buff_display", "CooldownObservationV3"): {
        "required": set(),
        "optional": set(),
        "lazy": {"X2Skill"},
    },
    ("combat_stats", "SkillMetadataV3"): {
        "required": set(),
        "optional": set(),
        "lazy": {"X2Skill"},
    },
    # Phase 1 Batch D（2026-09-28）：tools_craft 拆出独立文件后，audit 第一次能按 Feature 归因这条边。
    # craft 从不直接调用 X2Auction：报价请求由用户显式触发并转发给共享 PriceQuoteQueueV3，
    # 结果也只从该队列的 read model 读取（features/tools/craft/rs_craft_feature.lua 的 CraftQuote/QuoteMaterial）。
    # 因此 X2Auction 的 lazy ownership 归 PriceQuoteQueueV3 自己，不得升成 tools_craft 的 hard dependency。
    # 维护备注：队列侧真正的 lazy lease（AcquireApi）与其它 Service 一样，属于 Phase 3 的 descriptor 收口项。
    ("tools_craft", "PriceQuoteQueueV3"): {
        "required": set(),
        "optional": set(),
        "lazy": {"X2Auction"},
    },
}


@dataclass(frozen=True)
class Finding:
    severity: str
    kind: str
    owner: str
    detail: str


def _mask_comments(text: str) -> str:
    """Replace Lua comments with spaces while preserving strings/newlines.

    This is a small lexer, not a Lua parser. It is sufficient for source-level
    dependency tokens and avoids counting `X2Foo` names that only appear in
    maintenance comments.
    """
    out = list(text)
    i, n = 0, len(text)
    quote: Optional[str] = None
    while i < n:
        c = text[i]
        if quote is not None:
            if c == "\\":
                i += 2
                continue
            if c == quote:
                quote = None
            i += 1
            continue
        if c in ("'", '"'):
            quote = c
            i += 1
            continue
        if c == "-" and i + 1 < n and text[i + 1] == "-":
            # Long comment --[[ ... ]] or line comment.
            if text.startswith("--[[", i):
                j = text.find("]]", i + 4)
                end = n if j < 0 else j + 2
                for k in range(i, end):
                    if out[k] != "\n":
                        out[k] = " "
                i = end
                continue
            j = text.find("\n", i + 2)
            end = n if j < 0 else j
            for k in range(i, end):
                out[k] = " "
            i = end
            continue
        i += 1
    return "".join(out)


def _balanced(text: str, open_at: int, open_ch: str, close_ch: str) -> Optional[int]:
    depth = 0
    quote: Optional[str] = None
    i, n = open_at, len(text)
    while i < n:
        c = text[i]
        if quote is not None:
            if c == "\\":
                i += 2
                continue
            if c == quote:
                quote = None
            i += 1
            continue
        if c in ("'", '"'):
            quote = c
        elif c == open_ch:
            depth += 1
        elif c == close_ch:
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return None


def _quoted_values(table_text: str) -> List[str]:
    return [m.group(2) for m in re.finditer(r"(['\"])(.*?)\1", table_text, re.S)]


def _extract_table_expr(text: str, expr_start: int, constants: Dict[str, List[str]]) -> Optional[List[str]]:
    i = expr_start
    while i < len(text) and text[i].isspace():
        i += 1
    if i >= len(text):
        return None
    if text[i] == "{":
        end = _balanced(text, i, "{", "}")
        if end is None:
            return None
        return _quoted_values(text[i : end + 1])
    m = re.match(r"([A-Za-z_][A-Za-z0-9_]*)", text[i:])
    if m:
        return list(constants.get(m.group(1), [])) or None
    return None


def _constants(text: str) -> Dict[str, List[str]]:
    result: Dict[str, List[str]] = {}
    masked = _mask_comments(text)
    for m in re.finditer(r"\blocal\s+([A-Z][A-Z0-9_]*)\s*=\s*\{", masked):
        brace = masked.find("{", m.start())
        end = _balanced(masked, brace, "{", "}")
        if end is not None:
            result[m.group(1)] = _quoted_values(masked[brace : end + 1])
    return result


def _namespace_maps() -> Tuple[Dict[str, str], Set[str]]:
    text = _mask_comments(NATIVE_CONTRACT.read_text(encoding="utf-8", errors="replace"))
    aliases: Dict[str, str] = {}
    native_names: Set[str] = set()
    for m in re.finditer(
        r"\b([A-Z][A-Z0-9_]*)\s*=\s*\{[^{}]*?nativeName\s*=\s*['\"]([^'\"]+)['\"]",
        text,
        re.S,
    ):
        aliases[m.group(1)] = m.group(2)
        native_names.add(m.group(2))
    return aliases, native_names


ALIASES, CONTRACT_NATIVE_NAMES = _namespace_maps()


def _namespace(dep: str) -> Optional[str]:
    value = dep.strip()
    if not value:
        return None
    direct = value.upper()
    if direct in ALIASES:
        return ALIASES[direct]
    return value.split(":", 1)[0]


def _namespace_set(deps: Iterable[str]) -> Set[str]:
    return {ns for dep in deps if (ns := _namespace(dep))}


def _find_named_calls(text: str, name: str) -> List[str]:
    masked = _mask_comments(text)
    out: List[str] = []
    pattern = re.compile(rf"\b{re.escape(name)}\s*\(")
    for m in pattern.finditer(masked):
        open_at = masked.find("(", m.start())
        end = _balanced(masked, open_at, "(", ")")
        if end is not None:
            out.append(masked[open_at + 1 : end])
    return out


def _extract_api_deps_from_segment(segment: str, constants: Dict[str, List[str]]) -> Optional[List[str]]:
    m = re.search(r"\bapiDependencies\s*=\s*", segment)
    if not m:
        m = re.search(r"\bApiDependencies\s*=\s*", segment)
    if not m:
        return None
    return _extract_table_expr(segment, m.end(), constants)


def load_registry() -> Dict[str, List[str]]:
    text = REGISTRY.read_text(encoding="utf-8", errors="replace")
    result: Dict[str, List[str]] = {}
    for call in _find_named_calls(text, "Add"):
        first = re.match(r"\s*(['\"])(.*?)\1", call, re.S)
        if not first:
            continue
        feature_id = first.group(2)
        deps = _extract_api_deps_from_segment(call, {})
        result[feature_id] = deps or []
    return result


def load_implementation_overrides() -> Tuple[Dict[str, List[str]], Dict[str, str]]:
    """Return feature_id -> explicit implementation deps and source path.

    A missing row means the implementation has no override and FeatureRuntime
    correctly falls back to FeatureRegistry metadata.
    """
    result: Dict[str, List[str]] = {}
    sources: Dict[str, str] = {}
    for path in FEATURES.rglob("*.lua"):
        if path.name in {"rs_feature_registry.lua", "rs_feature_runtime.lua"}:
            continue
        raw = path.read_text(encoding="utf-8", errors="replace")
        text = _mask_comments(raw)
        constants = _constants(raw)

        # NewFeature("id", { apiDependencies = ... }) used by business bridge.
        for call in _find_named_calls(raw, "NewFeature"):
            first = re.match(r"\s*(['\"])(.*?)\1", call, re.S)
            if not first:
                continue
            deps = _extract_api_deps_from_segment(call, constants)
            if deps is not None:
                result[first.group(2)] = deps
                sources[first.group(2)] = str(path.relative_to(ROOT))

        # Named Feature tables registered later (Trade/Bonds/... and standalone F).
        var_to_id: Dict[str, str] = {}
        for m in re.finditer(r"\b([A-Za-z_][A-Za-z0-9_]*)\.Id\s*=\s*(['\"])(.*?)\2", text):
            var_to_id[m.group(1)] = m.group(3)
        # local F = { Id = "...", ..., ApiDependencies = {...} }
        for m in re.finditer(r"\blocal\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\{", text):
            var = m.group(1)
            brace = text.find("{", m.start())
            end = _balanced(text, brace, "{", "}")
            if end is None:
                continue
            body = text[brace : end + 1]
            idm = re.search(r"\bId\s*=\s*(['\"])(.*?)\1", body)
            if idm:
                var_to_id[var] = idm.group(2)
                deps = _extract_api_deps_from_segment(body, constants)
                if deps is not None:
                    result[idm.group(2)] = deps
                    sources[idm.group(2)] = str(path.relative_to(ROOT))

        # RegisterImplementation("literal", Var) can recover ids if Id assignment is indirect.
        for m in re.finditer(
            r"RegisterImplementation\s*\(\s*(['\"])(.*?)\1\s*,\s*([A-Za-z_][A-Za-z0-9_]*)",
            text,
        ):
            var_to_id.setdefault(m.group(3), m.group(2))

        for m in re.finditer(r"\b([A-Za-z_][A-Za-z0-9_]*)\.ApiDependencies\s*=\s*", text):
            var = m.group(1)
            feature_id = var_to_id.get(var)
            if not feature_id:
                continue
            deps = _extract_table_expr(text, m.end(), constants)
            if deps is not None:
                result[feature_id] = deps
                sources[feature_id] = str(path.relative_to(ROOT))
    return result, sources


def _mask_strings(text: str) -> str:
    out = list(text)
    i, n = 0, len(text)
    quote: Optional[str] = None
    while i < n:
        c = text[i]
        if quote is None:
            if c in ("'", '"'):
                quote = c
                out[i] = " "
            i += 1
            continue
        out[i] = " " if c != "\n" else "\n"
        if c == "\\":
            if i + 1 < n:
                out[i + 1] = " " if text[i + 1] != "\n" else "\n"
            i += 2
            continue
        if c == quote:
            quote = None
        i += 1
    return "".join(out)


def _runtime_x2_names(path: Path) -> Set[str]:
    raw = _mask_comments(path.read_text(encoding="utf-8", errors="replace"))
    # Bare object references such as X2Skill.Info. Strings are masked here so
    # documentation text cannot invent a dependency.
    bare = set(re.findall(r"\b(X2[A-Z][A-Za-z0-9_]*)\b", _mask_strings(raw)))
    # Capability-mediated calls intentionally carry namespace in a string. Only
    # count strings at actual API boundary call sites, not arbitrary prose.
    mediated = set()
    call_pat = re.compile(
        r"(?:CallCapability|ActionCapability|IsCapabilityAllowed|_Call|Call|Action)\s*\(\s*['\"](X2[A-Z][A-Za-z0-9_]*):",
        re.S,
    )
    mediated.update(m.group(1) for m in call_pat.finditer(raw))
    return bare | mediated


def service_native_inventory() -> Dict[str, Set[str]]:
    out: Dict[str, Set[str]] = {}
    for path in SERVICES.glob("*.lua"):
        names = _runtime_x2_names(path)
        if names:
            # Use the service export name when it is statically visible; otherwise filename.
            text = _mask_comments(path.read_text(encoding="utf-8", errors="replace"))
            m = re.search(r"S\.Services\.([A-Za-z_][A-Za-z0-9_]*)\s*=", text)
            key = m.group(1) if m else path.stem
            out[key] = names
    return out


def load_feature_sources() -> Dict[str, str]:
    registry = load_registry()
    sources: Dict[str, str] = {}
    for path in FEATURES.rglob("*.lua"):
        if path.name in {"rs_feature_registry.lua", "rs_feature_runtime.lua"} or path.name.endswith("_acceptance.lua"):
            continue
        raw = path.read_text(encoding="utf-8", errors="replace")
        text = _mask_comments(raw)
        ids: Set[str] = set()
        for m in re.finditer(r"\.Id\s*=\s*(['\"])(.*?)\1", text):
            if m.group(2) in registry:
                ids.add(m.group(2))
        for m in re.finditer(r"\bId\s*=\s*(['\"])(.*?)\1", text):
            if m.group(2) in registry:
                ids.add(m.group(2))
        for call in _find_named_calls(raw, "NewFeature"):
            first = re.match(r"\s*(['\"])(.*?)\1", call, re.S)
            if first and first.group(2) in registry:
                ids.add(first.group(2))
        for feature_id in ids:
            sources[feature_id] = str(path.relative_to(ROOT))
    return sources


def feature_service_refs(feature_sources: Dict[str, str]) -> Dict[str, Set[str]]:
    registry = load_registry()
    out: Dict[str, Set[str]] = {fid: set() for fid in registry}
    by_source: Dict[str, List[str]] = {}
    for feature_id, source in feature_sources.items():
        by_source.setdefault(source, []).append(feature_id)
    for source, feature_ids in by_source.items():
        path = ROOT / source
        if not path.is_file():
            continue
        text = _mask_comments(path.read_text(encoding="utf-8", errors="replace"))
        refs = set(re.findall(r"S\.Services\.([A-Za-z_][A-Za-z0-9_]*)", text))
        if not refs:
            continue
        if len(feature_ids) == 1:
            out[feature_ids[0]].update(refs)
            continue
        # Shared bundles cannot be safely attributed by file-wide grep. Record only
        # the currently proven cross-service edge that motivated FND-016; Phase 1/2
        # vertical slicing will make the remaining ownership mechanically auditable.
        if source.endswith("features/life/rs_life_m16_bundle.lua") and "life_bonds" in feature_ids and "QuestProgressV3" in refs:
            out["life_bonds"].add("QuestProgressV3")
    return out


def audit() -> Tuple[List[Finding], Dict[str, object]]:
    findings: List[Finding] = []
    registry = load_registry()
    impl, impl_sources = load_implementation_overrides()
    services = service_native_inventory()
    feature_sources = load_feature_sources()
    refs = feature_service_refs(feature_sources)

    for feature_id, deps in sorted(registry.items()):
        unknown = sorted(ns for ns in _namespace_set(deps) if ns not in CONTRACT_NATIVE_NAMES)
        if unknown:
            findings.append(Finding("ERROR", "REGISTRY_UNKNOWN_NATIVE_NAMESPACE", feature_id, ",".join(unknown)))
    for feature_id, deps in sorted(impl.items()):
        unknown = sorted(ns for ns in _namespace_set(deps) if ns not in CONTRACT_NATIVE_NAMES)
        if unknown:
            findings.append(Finding("ERROR", "IMPLEMENTATION_UNKNOWN_NATIVE_NAMESPACE", feature_id, ",".join(unknown)))

    for feature_id, required_names in sorted(STANDALONE_REQUIRED_NAMESPACES.items()):
        effective = impl.get(feature_id, registry.get(feature_id, []))
        effective_names = _namespace_set(effective) | FOUNDATION_NATIVE_NAMES
        missing = sorted(required_names - effective_names)
        if missing:
            findings.append(Finding(
                "ERROR", "STANDALONE_REQUIRED_NAMESPACE_MISSING", feature_id,
                "missing=" + ",".join(missing),
            ))

    parity_checked = 0
    for feature_id, deps in sorted(impl.items()):
        if feature_id not in registry:
            findings.append(Finding("WARN", "IMPL_NOT_IN_REGISTRY", feature_id, impl_sources.get(feature_id, "?")))
            continue
        parity_checked += 1
        registry_ns = _namespace_set(registry[feature_id]) - FOUNDATION_NATIVE_NAMES
        impl_ns = _namespace_set(deps) - FOUNDATION_NATIVE_NAMES
        missing = sorted(registry_ns - impl_ns)
        if missing:
            findings.append(
                Finding(
                    "ERROR",
                    "IMPLEMENTATION_DROPS_REGISTRY_NAMESPACE",
                    feature_id,
                    f"missing={','.join(missing)} source={impl_sources.get(feature_id,'?')}",
                )
            )

    # Standalone feature source direct Native usage must be covered by its effective
    # FeatureRuntime import contract. Shared bundle files are skipped because source-wide
    # attribution would assign one slice's API use to every sibling; Phase 1/2 splitting
    # will remove that ambiguity.
    by_feature_source: Dict[str, List[str]] = {}
    for fid, source in feature_sources.items():
        by_feature_source.setdefault(source, []).append(fid)
    for source, feature_ids in sorted(by_feature_source.items()):
        if len(feature_ids) != 1:
            continue
        fid = feature_ids[0]
        direct_names = _runtime_x2_names(ROOT / source) - FOUNDATION_NATIVE_NAMES
        effective_names = _namespace_set(impl.get(fid, registry.get(fid, []))) | FOUNDATION_NATIVE_NAMES
        gap = sorted(direct_names - effective_names)
        if gap:
            findings.append(Finding(
                "WARN", "FEATURE_DIRECT_NATIVE_GAP", fid,
                f"namespaces={','.join(gap)} source={source}"
            ))

    # Runtime source must never depend on an X2 namespace that NativeContract cannot name.
    runtime_roots = [ROOT / "features", ROOT / "services", ROOT / "presentation"]
    used_names: Dict[str, List[str]] = {}
    for base in runtime_roots:
        for path in base.rglob("*.lua"):
            if path == REGISTRY:
                continue
            for name in _runtime_x2_names(path):
                used_names.setdefault(name, []).append(str(path.relative_to(ROOT)))
    for name in sorted(used_names):
        if name not in CONTRACT_NATIVE_NAMES:
            sample = ",".join(sorted(set(used_names[name]))[:4])
            findings.append(
                Finding(
                    "BLOCKER",
                    "NATIVE_CONTRACT_MISSING_NAMESPACE",
                    name,
                    f"used_by={sample}; verified API_TYPE id required before adding contract row",
                )
            )

    # Service transitive ownership is policy-aware. A service file can contain
    # methods for several consumers; only the exact required edge belongs in the
    # Feature hard dependency set. Optional/lazy namespaces stay service-owned.
    for feature_id, service_names in sorted(refs.items()):
        effective = impl.get(feature_id, registry.get(feature_id, []))
        effective_ns = _namespace_set(effective) | FOUNDATION_NATIVE_NAMES
        for service_name in sorted(service_names):
            needed = services.get(service_name, set()) - FOUNDATION_NATIVE_NAMES
            policy = SERVICE_EDGE_NATIVE_POLICY.get((feature_id, service_name))
            if policy is None:
                gap = sorted(needed - effective_ns)
                if gap:
                    findings.append(Finding(
                        "WARN", "TRANSITIVE_SERVICE_NATIVE_UNCLASSIFIED", feature_id,
                        f"service={service_name} namespaces={','.join(gap)}; add required/optional/lazy edge policy before widening imports",
                    ))
                continue
            required = set(policy.get("required", set()))
            optional = set(policy.get("optional", set()))
            lazy = set(policy.get("lazy", set()))
            declared = required | optional | lazy
            unclassified = sorted(needed - declared)
            if unclassified:
                findings.append(Finding(
                    "WARN", "TRANSITIVE_SERVICE_NATIVE_POLICY_INCOMPLETE", feature_id,
                    f"service={service_name} namespaces={','.join(unclassified)}",
                ))
            missing_required = sorted(required - effective_ns)
            if missing_required:
                findings.append(Finding(
                    "ERROR", "TRANSITIVE_REQUIRED_NAMESPACE_MISSING", feature_id,
                    f"service={service_name} missing={','.join(missing_required)}",
                ))
            # Lazy namespace absence is represented by the global NativeContract
            # blocker if the namespace itself is unknown. Do not duplicate it as a
            # Feature warning: lazy ownership must remain at the service boundary.

    stats: Dict[str, object] = {
        "registry_features": len(registry),
        "implementation_overrides": len(impl),
        "parity_checked": parity_checked,
        "services_with_native_usage": len(services),
        "contract_namespaces": len(CONTRACT_NATIVE_NAMES),
    }
    return findings, stats


def main() -> int:
    findings, stats = audit()
    print(
        "NATIVE DEPENDENCY AUDIT: "
        f"registry={stats['registry_features']} impl_overrides={stats['implementation_overrides']} "
        f"parity_checked={stats['parity_checked']} services={stats['services_with_native_usage']} "
        f"contract_namespaces={stats['contract_namespaces']}"
    )
    for row in findings:
        print(f"{row.severity}\t{row.kind}\t{row.owner}\t{row.detail}")
    errors = [x for x in findings if x.severity == "ERROR"]
    blockers = [x for x in findings if x.severity == "BLOCKER"]
    warnings = [x for x in findings if x.severity == "WARN"]
    print(f"RESULT errors={len(errors)} blockers={len(blockers)} warnings={len(warnings)}")
    if errors:
        return 1
    if blockers:
        # 2 means the audit itself worked but Phase 0 cannot claim a green Native gate.
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())

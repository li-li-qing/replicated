#!/usr/bin/env python3
# ---------------------------------------------------------------------
# Replicated Suite · 原生依赖审查
# 作者：Replicated
# QQ群：1104129461
# ---------------------------------------------------------------------
"""原生依赖归属审查。

验证实现中的 ApiDependencies 覆盖不能悄然丢失 FeatureRegistry 已声明的命名空间；
盘点共享服务原生调用及 Feature→Service 传递依赖缺口；
发现运行时代码使用但 NativeContract 尚未声明的命名空间。

ADDON:ImportAPI 按命名空间导入，因此审查以命名空间为范围，功能元数据仍按方法能力声明。
不修改运行时文件，不推断未知 API_TYPE ID。"""
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

# 独立启动依赖矩阵仅包含已由生产诊断或源码追踪
# 证明的调用链；可选子能力
# 不能在此升级为强制依赖。
STANDALONE_REQUIRED_NAMESPACES = {
    "life_trade": {"X2Store", "X2Ability", "X2Equipment", "X2Craft", "X2Auction"},
    "life_bonds": {"X2Resident", "X2Bag", "X2Quest"},
    "combat_buff_display": {"X2Ability", "X2Equipment"},
}

# 按已证明的 Feature→共享服务原生调用路径判断依赖；同一服务文件
# 可能为不同方法使用不同原生命名空间，不能把整个文件的命名空间并集
# 全部提升为某个功能的强制依赖。
#
# required：此功能实际消费的确切服务方法路径所使用的命名空间。
# optional：属于其它服务方法或允许优雅降级的增强路径。
# lazy：只有用户启用子能力或实际进入详情路径时才需要，
# 其导入责任必须留在服务或延迟能力边界。
SERVICE_EDGE_NATIVE_POLICY = {
    # 中文维护（2026-10-13）：人员备注选家族时才调用ReadFamilyList，由名单Service取得Native lease。
    # 好友、黑名单、团队及已保存备注不能为此强制导入FAMILY；此策略与实际AcquireApi边界成对维护。
    ("tools_player_notes", "PlayerNotesSurfaceV3"): {
        "required": set(),
        "optional": set(),
        "lazy": {"X2Family"},
    },
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
    """将 Lua 注释替换为空格，保留字符串及换行。

这是面向源码依赖标记的轻量词法分析器，不是 Lua 解析器；避免把维护注释中的 X2Foo 名称计为依赖。"""
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
            # 识别长注释 --[[ ... ]] 和单行注释。
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
    """返回 feature_id 对应的显式实现依赖和源码路径。

缺少条目表示实现没有覆盖声明，FeatureRuntime 应回退到 FeatureRegistry 元数据。"""
    result: Dict[str, List[str]] = {}
    sources: Dict[str, str] = {}
    for path in FEATURES.rglob("*.lua"):
        if path.name in {"rs_feature_registry.lua", "rs_feature_runtime.lua"}:
            continue
        raw = path.read_text(encoding="utf-8", errors="replace")
        text = _mask_comments(raw)
        constants = _constants(raw)

        # 业务桥接使用的声明形状：NewFeature("id", { apiDependencies = ... })。
        for call in _find_named_calls(raw, "NewFeature"):
            first = re.match(r"\s*(['\"])(.*?)\1", call, re.S)
            if not first:
                continue
            deps = _extract_api_deps_from_segment(call, constants)
            if deps is not None:
                result[first.group(2)] = deps
                sources[first.group(2)] = str(path.relative_to(ROOT))

        # 识别随后注册的具名功能表，包括 Trade、Bonds 和独立 F。
        var_to_id: Dict[str, str] = {}
        for m in re.finditer(r"\b([A-Za-z_][A-Za-z0-9_]*)\.Id\s*=\s*(['\"])(.*?)\2", text):
            var_to_id[m.group(1)] = m.group(3)
        # 功能表声明示例：local F = { Id = "...", ..., ApiDependencies = {...} }。
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

        # Id 间接赋值时，可通过 RegisterImplementation("literal", Var) 恢复功能 ID。
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
    # 识别 X2Skill.Info 等直接对象引用时屏蔽字符串，
    # 避免文档说明凭空产生依赖。
    bare = set(re.findall(r"\b(X2[A-Z][A-Za-z0-9_]*)\b", _mask_strings(raw)))
    # 通过能力包装调用时，命名空间有意放在字符串中；仅统计
    # 真实 API 边界调用位置的字符串，不能统计任意说明文字。
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
            # 静态可见时使用服务导出名，否则退回文件名。
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
        # 中文维护注释（2026-09-28，Phase 2 Step 4）：Phase 1/2 之后已经不存在“一个源码单元注册多个
        # Feature”的情况，原先为 life_bonds→QuestProgressV3 写死的 bundle 特例已成为死代码并删除 ——
        # 那个边现在由 1:1 文件归属机械推出，不再需要人工白名单。若将来又出现共享 chunk，
        # 这里保持“不归属、不猜测”的安全语义，并由 --feature-split 的静态断言直接报出。
        continue
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

    # 独立功能直接使用的原生命名空间必须被有效 FeatureRuntime
    # 导入契约覆盖；跳过共享打包文件，避免全文件归属分析
    # 把一个分片的 API 使用归给每个相邻分片；
    # 后续拆分共享包时应消除该歧义。
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

    # 运行时源码不能依赖 NativeContract 无法声明的 X2 命名空间。
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

    # 服务传递依赖按策略判断：一个服务文件可包含多个消费者的方法，
    # 只有确切 required 路径应进入 Feature 的强制依赖集合，
    # optional 和 lazy 命名空间仍由服务负责。
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
            # lazy 命名空间本身未知时，由全局 NativeContract
            # 检查报告阻断，不应再重复成 Feature 警告，
            # 延迟依赖的责任须保留在服务边界。

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
        # 返回码 2 表示审查工具成功执行，但原生门禁仍未通过。
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())

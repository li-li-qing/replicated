#!/usr/bin/env python3
"""Presentation -> Feature public API contract audit.

Catches a Lua failure class that parse-only checks cannot: Presentation calls a
Feature/Commands method that the corresponding runtime feature never exports.
Those mistakes otherwise survive packaging and fail only when the user opens,
moves or interacts with a page/widget.

Coverage:
* statically named ``S.Features.<Name>`` and literal ``S.Features["name"]``;
* direct providers split across feature/store/authority files;
* ``S.Features.Name = LocalFeature`` providers (Treasure/Fishing style);
* generic ``NewFeature("id", spec)`` business providers, including spec.commands;
* explicit capability guards remain valid for intentionally optional calls.

Dynamic ``S.Features[expr]`` consumers are counted but not guessed; their exact
runtime contracts stay under BusinessPages/Acceptance contracts.
"""
from __future__ import annotations

import argparse
import re
from dataclasses import dataclass, field
from pathlib import Path

DEFAULT_ROOT = Path(__file__).resolve().parents[1]

STATIC_ALIAS_PATTERNS = (
    re.compile(r"\blocal\s+([A-Za-z_]\w*)\s*=\s*S\.Features\s+and\s+S\.Features\.([A-Za-z_]\w*)\s+or\s+nil"),
    re.compile(r"\blocal\s+([A-Za-z_]\w*)\s*=\s*S\.Features\.([A-Za-z_]\w*)"),
    re.compile(r"\blocal\s+([A-Za-z_]\w*)\s*=\s*S\.Features\s+and\s+S\.Features\[\s*[\"']([^\"']+)[\"']\s*\]\s+or\s+nil"),
    re.compile(r"\blocal\s+([A-Za-z_]\w*)\s*=\s*S\.Features\[\s*[\"']([^\"']+)[\"']\s*\]"),
)
DYNAMIC_ALIAS_RE = re.compile(r"\blocal\s+([A-Za-z_]\w*)\s*=\s*S\.Features(?:\s+and\s+S\.Features)?\[\s*([^\"'][^\]]*)\]")
FEATURE_EXPORT_RE = re.compile(r"\bS\.Features\.([A-Za-z_]\w*)\s*=\s*([A-Za-z_]\w*)")
NEW_FEATURE_RE = re.compile(r"(?:\blocal\s+([A-Za-z_]\w*)\s*=\s*)?NewFeature\(\s*[\"']([^\"']+)[\"']\s*,\s*\{")

GENERIC_NEW_FEATURE_METHODS = {
    "Initialize", "ReconcileDemand", "Enable", "Disable", "AcquireConsumer",
    "ReleaseConsumer", "Refresh", "GetProjection",
}


@dataclass
class Surface:
    methods: set[str] = field(default_factory=set)
    commands: set[str] = field(default_factory=set)
    files: set[str] = field(default_factory=set)


def strip_comments_preserve_lines(text: str) -> str:
    text = re.sub(r"--\[\[.*?\]\]", lambda m: "\n" * m.group(0).count("\n"), text, flags=re.S)
    return re.sub(r"--[^\n]*", "", text)


def line_for(text: str, pos: int) -> int:
    return text.count("\n", 0, pos) + 1


def static_aliases(text: str) -> dict[str, tuple[str, int]]:
    result: dict[str, tuple[str, int]] = {}
    for pattern in STATIC_ALIAS_PATTERNS:
        for match in pattern.finditer(text):
            result[match.group(1)] = (match.group(2), match.start())
    return result


def balanced_block(text: str, opening_brace: int) -> tuple[str, int] | None:
    if opening_brace < 0 or opening_brace >= len(text) or text[opening_brace] != "{":
        return None
    depth = 0
    quote: str | None = None
    escape = False
    i = opening_brace
    while i < len(text):
        ch = text[i]
        if quote is not None:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == quote:
                quote = None
        else:
            if ch in ("'", '"'):
                quote = ch
            elif ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    return text[opening_brace + 1:i], i
        i += 1
    return None


def top_level_function_keys(block: str) -> set[str]:
    # All public command specs in the current codebase use identifier keys.
    # Requiring `= function` avoids treating state/default table members as API.
    return set(re.findall(r"(?m)^\s*([A-Za-z_]\w*)\s*=\s*function\b", block))


def command_table_keys(text: str, alias: str) -> set[str]:
    keys: set[str] = set()
    for match in re.finditer(r"\b" + re.escape(alias) + r"\.Commands\s*=\s*\{", text):
        opening = text.find("{", match.start(), match.end())
        found = balanced_block(text, opening)
        if found is not None:
            keys.update(top_level_function_keys(found[0]))
    return keys


def spec_command_keys(spec_block: str) -> set[str]:
    for match in re.finditer(r"\bcommands\s*=\s*\{", spec_block):
        opening = spec_block.find("{", match.start(), match.end())
        found = balanced_block(spec_block, opening)
        if found is not None:
            return top_level_function_keys(found[0])
    return set()


def guarded(lines: list[str], line_no: int, expr: str) -> bool:
    start = max(0, line_no - 6)
    window = "\n".join(lines[start:line_no])
    escaped = re.escape(expr)
    patterns = (
        rf"type\s*\(\s*{escaped}\s*\)\s*(?:==|~=)\s*[\"']function[\"']",
        rf"{escaped}\s*~=\s*nil",
    )
    return any(re.search(pattern, window) for pattern in patterns)


def add_alias_surface(surfaces: dict[str, Surface], key: str, alias: str, text: str, rel: str) -> None:
    surface = surfaces.setdefault(key, Surface())
    direct = set(re.findall(r"\bfunction\s+" + re.escape(alias) + r":([A-Za-z_]\w*)\s*\(", text))
    commands = set(re.findall(r"\bfunction\s+" + re.escape(alias) + r"\.Commands:([A-Za-z_]\w*)\s*\(", text))
    commands.update(command_table_keys(text, alias))
    if direct or commands:
        surface.methods.update(direct)
        surface.commands.update(commands)
        surface.files.add(rel)


def discover_surfaces(root: Path) -> dict[str, Surface]:
    surfaces: dict[str, Surface] = {}
    for path in sorted((root / "features").rglob("*.lua")):
        raw = path.read_text(encoding="utf-8-sig", errors="replace")
        text = strip_comments_preserve_lines(raw)
        rel = path.relative_to(root).as_posix()

        # Normal split features: `local F = S.Features.Name`.
        for alias, (key, _) in static_aliases(text).items():
            add_alias_surface(surfaces, key, alias, text, rel)

        # Bundle features: local table first, exported later as S.Features.Name.
        for match in FEATURE_EXPORT_RE.finditer(text):
            key, alias = match.group(1), match.group(2)
            add_alias_surface(surfaces, key, alias, text, rel)

        # Generic business features generated by NewFeature(id, spec).
        for match in NEW_FEATURE_RE.finditer(text):
            alias, key = match.group(1), match.group(2)
            opening = text.find("{", match.start(), match.end())
            found = balanced_block(text, opening)
            surface = surfaces.setdefault(key, Surface())
            surface.methods.update(GENERIC_NEW_FEATURE_METHODS)
            surface.commands.add("Refresh")
            if found is not None:
                surface.commands.update(spec_command_keys(found[0]))
            # Some generated features add/override methods after construction.
            if alias is not None:
                surface.methods.update(re.findall(r"\bfunction\s+" + re.escape(alias) + r":([A-Za-z_]\w*)\s*\(", text))
                surface.commands.update(re.findall(r"\bfunction\s+" + re.escape(alias) + r"\.Commands:([A-Za-z_]\w*)\s*\(", text))
            surface.files.add(rel)
    return surfaces


def audit(root: Path) -> tuple[list[str], dict[str, int]]:
    surfaces = discover_surfaces(root)
    failures: list[str] = []
    aliases_seen = calls_checked = guarded_calls = dynamic_aliases = 0
    provider_keys_used: set[str] = set()

    for path in sorted((root / "presentation/v3").rglob("*.lua")):
        raw = path.read_text(encoding="utf-8-sig", errors="replace")
        text = strip_comments_preserve_lines(raw)
        lines = text.splitlines()
        aliases = static_aliases(text)
        aliases_seen += len(aliases)

        for match in DYNAMIC_ALIAS_RE.finditer(text):
            dynamic_aliases += 1

        for alias, (key, assignment_pos) in aliases.items():
            surface = surfaces.get(key)
            rel = path.relative_to(root).as_posix()
            if surface is None:
                failures.append(f"feature provider missing {rel}:{line_for(text, assignment_pos)} {alias}=S.Features.{key}")
                continue
            provider_keys_used.add(key)

            direct_re = re.compile(r"\b" + re.escape(alias) + r":([A-Za-z_]\w*)\s*\(")
            command_re = re.compile(r"\b" + re.escape(alias) + r"\.Commands:([A-Za-z_]\w*)\s*\(")
            for match in direct_re.finditer(text, assignment_pos):
                method = match.group(1)
                call_line = line_for(text, match.start())
                calls_checked += 1
                if method in surface.methods or guarded(lines, call_line, f"{alias}.{method}"):
                    if method not in surface.methods:
                        guarded_calls += 1
                    continue
                failures.append(f"feature API missing {rel}:{call_line} S.Features.{key}:{method}")

            for match in command_re.finditer(text, assignment_pos):
                method = match.group(1)
                call_line = line_for(text, match.start())
                calls_checked += 1
                if method in surface.commands or guarded(lines, call_line, f"{alias}.Commands.{method}"):
                    if method not in surface.commands:
                        guarded_calls += 1
                    continue
                failures.append(f"feature Command API missing {rel}:{call_line} S.Features.{key}.Commands:{method}")

    metrics = {
        "providers": len(surfaces),
        "usedProviders": len(provider_keys_used),
        "aliases": aliases_seen,
        "calls": calls_checked,
        "guarded": guarded_calls,
        "dynamicAliases": dynamic_aliases,
    }
    return failures, metrics


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=None)
    args = parser.parse_args()
    root = Path(args.root).resolve() if args.root else DEFAULT_ROOT
    failures, m = audit(root)
    print(
        "PRESENTATION_FEATURE_API_AUDIT " + ("PASS" if not failures else "FAIL")
        + f" | providers={m.get('providers',0)} usedProviders={m.get('usedProviders',0)}"
        + f" aliases={m.get('aliases',0)} calls={m.get('calls',0)} guarded={m.get('guarded',0)}"
        + f" dynamicAliases={m.get('dynamicAliases',0)}"
    )
    for failure in failures:
        print("FAIL | " + failure)
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())

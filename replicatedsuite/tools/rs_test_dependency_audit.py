#!/usr/bin/env python3
"""Phase 0: recursively audit literal Lua dofile/loadfile dependencies for regression suites.

This is test/build infrastructure only. It never edits toc.g and never fabricates missing fixtures.
The purpose is to fail the full runner before partial execution when a nested historical host/fixture
is absent, so a later early failure cannot hide additional missing dependencies.
"""
from __future__ import annotations
import argparse
import re
from pathlib import Path
from collections import deque

ROOT = Path(__file__).resolve().parents[1]
CALL_RE = re.compile(r"\b(?:dofile|loadfile)\s*\(\s*(['\"])([^'\"]+)\1\s*\)")


def literal_dependencies(path: Path) -> list[str]:
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        text = path.read_text(encoding="utf-8", errors="replace")
    return [m.group(2).replace('\\', '/') for m in CALL_RE.finditer(text)]


def audit(entries: list[str]) -> tuple[list[str], dict[str, list[str]]]:
    queue = deque(entries)
    visited: set[str] = set()
    missing_parents: dict[str, set[str]] = {}
    while queue:
        rel = queue.popleft().replace('\\', '/')
        if rel in visited:
            continue
        visited.add(rel)
        path = ROOT / rel
        # This gate is intentionally a Lua dependency audit. Python runners may contain
        # dynamic format strings or inventory literals that are not load-time dependencies.
        if path.suffix.lower() != '.lua':
            continue
        if not path.is_file():
            missing_parents.setdefault(rel, set()).add('<entry>')
            continue
        for dep in literal_dependencies(path):
            # Only repository-relative Lua/tool/data dependencies participate.
            # Dynamic/runtime paths remain the responsibility of their owning tests.
            if dep.startswith('/') or ':' in dep[:3]:
                continue
            dpath = ROOT / dep
            if not dpath.is_file():
                missing_parents.setdefault(dep, set()).add(rel)
            elif dep not in visited:
                queue.append(dep)
    return sorted(visited), {k: sorted(v) for k, v in sorted(missing_parents.items())}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('entries', nargs='*')
    parser.add_argument('--entry-file', help='newline separated repository-relative entries')
    args = parser.parse_args()
    entries = list(args.entries)
    if args.entry_file:
        for line in (ROOT / args.entry_file).read_text(encoding='utf-8').splitlines():
            line=line.strip()
            if line and not line.startswith('#'):
                entries.append(line)
    if not entries:
        entries=['tools/rs_status_refactor_tests.lua']
    visited, missing = audit(entries)
    if missing:
        print(f'TEST DEPENDENCY AUDIT: BLOCKED ({len(missing)} missing nested dependency file(s))')
        for path, parents in missing.items():
            print('  - '+path)
            for parent in parents[:6]:
                print('      required by '+parent)
            if len(parents) > 6:
                print(f'      ... +{len(parents)-6} more parent(s)')
        return 2
    print(f'TEST DEPENDENCY AUDIT: PASS ({len(visited)} reachable file(s))')
    return 0

if __name__ == '__main__':
    raise SystemExit(main())

#!/usr/bin/env python3
# Replicated Suite · 测试依赖审查
# 作者：Replicated
# QQ群：1104129461
"""递归审查回归套件中 Lua dofile/loadfile 的字面依赖。

仅供测试和构建使用，不修改 toc.g，不伪造缺失测试数据。
嵌套历史宿主或数据文件缺失时，在完整运行器开始执行前失败，避免后续早期错误掩盖其它缺失依赖。"""
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
        # 本门禁只审查 Lua 依赖；Python 运行器可能包含
        # 动态格式字符串或盘点字面量，它们不属于加载期依赖。
        if path.suffix.lower() != '.lua':
            continue
        if not path.is_file():
            missing_parents.setdefault(rel, set()).add('<entry>')
            continue
        for dep in literal_dependencies(path):
            # 仅统计仓库相对路径的 Lua、工具和数据依赖。
            # 动态及运行时路径仍由相应用例负责。
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

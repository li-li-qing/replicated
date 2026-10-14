#!/usr/bin/env python3
# ---------------------------------------------------------------------
# Replicated Suite · 安装完整性检查
# 作者：Replicated
# QQ群：1104129461
# ---------------------------------------------------------------------
"""只读检查 TOC 完整性，不加载 Lua、不修改插件、不读取存档。

可传入 Addon 目录或 replicatedsuite 子目录。
这是部署检查，不能替代 Lua 语法检查或客户端启动和 UI 测试。
同时检查清单缺文件与未解决的合并标记，避免文件齐全但 Lua 无法解析。
仅作为开发和安装工具使用，不进入 toc.g、不联网，不自动选择冲突版本或修改文件。
PASS 只代表上述静态检查通过，后续仍需实际 Lua 及客户端启动验证。"""
import argparse
import json
import re
import sys
from pathlib import Path, PurePosixPath


def check(root: Path) -> dict:
    root = root.resolve()
    if (root / 'replicatedsuite' / 'toc.g').is_file():
        root = root / 'replicatedsuite'
    toc = root / 'toc.g'
    if not toc.is_file():
        return {'status': 'FAIL', 'errors': ['toc.g not found'], 'root': str(root)}
    entries = []
    errors = []
    seen = set()
    for line_no, line in enumerate(toc.read_text(encoding='utf-8-sig').splitlines(), 1):
        line = line.strip()
        if not line or line.startswith('--'):
            continue
        path = PurePosixPath(line.replace('\\', '/'))
        if path.is_absolute() or '..' in path.parts or ':' in line or path.suffix != '.lua':
            errors.append(f'invalid entry at line {line_no}: {line}')
            continue
        if path.as_posix().lower() in seen:
            errors.append(f'duplicate entry at line {line_no}: {line}')
        seen.add(path.as_posix().lower())
        entries.append(path.as_posix())
    missing = [rel for rel in entries if not (root / rel).is_file()]
    empty = [rel for rel in entries if (root / rel).is_file() and (root / rel).stat().st_size == 0]
    conflicts = []
    marker = re.compile(r'^(?:<{7}(?:\s|$)|\|{7}(?:\s|$)|={7}$|>{7}(?:\s|$))')
    runtime_entries = set(entries)
    for source in sorted(root.rglob('*')):
        if not source.is_file() or (source.suffix not in ('.lua', '.py') and source.name != 'toc.g'):
            continue
        relative = source.relative_to(root).as_posix()
        try:
            lines = source.read_text(encoding='utf-8-sig').splitlines()
        except (OSError, UnicodeError) as exc:
            errors.append(f'cannot read {relative}: {exc}')
            continue
        hits = [i for i, line in enumerate(lines, 1) if marker.match(line)]
        if hits:
            conflicts.append({'path': relative, 'lines': hits, 'runtime': relative in runtime_entries})
    return {'status': 'FAIL' if errors or missing or empty or conflicts else 'PASS',
            'root': str(root), 'expected': len(entries), 'present': len(entries) - len(missing),
            'missing_count': len(missing), 'missing': missing, 'empty': empty, 'errors': errors,
            'conflict_file_count': len(conflicts),
            'runtime_conflict_file_count': sum(1 for row in conflicts if row['runtime']),
            'conflicts': conflicts}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    try:
        result = check(args.root)
    except (OSError, UnicodeError) as exc:
        result = {'status': 'FAIL', 'errors': [str(exc)]}
    text = json.dumps(result, indent=2, ensure_ascii=False)
    print(text)
    if args.output:
        args.output.write_text(text + '\n', encoding='utf-8')
    return 0 if result['status'] == 'PASS' else 1

if __name__ == '__main__':
    sys.exit(main())

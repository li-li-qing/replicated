#!/usr/bin/env python3
# Replicated Suite · 制作成本与材料状态定向回归
# 作者：Replicated
# QQ群：1104129461
"""使用真实 Lua 5.1 编译 TOC，并隔离运行制作相关套件；不操作游戏客户端。"""
from __future__ import annotations

import argparse
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
SUITES = (
    "rs_craft_optimizer_tests.lua",
    "rs_craft_compare_feature_tests.lua",
    "rs_craft_library_tests.lua",
    "rs_craft_window_tests.lua",
    "rs_craft_planner_tests.lua",
)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--syntax-only", action="store_true")
    args = parser.parse_args()
    try:
        from lupa.lua51 import LuaRuntime
    except ImportError:
        print("BLOCKED: 需要 lupa.lua51，不使用 Lua 5.4 兼容层代替。", file=sys.stderr)
        return 2

    lua = LuaRuntime(unpack_returned_tuples=True)
    compile_file = lua.eval("function(path) local f,e=loadfile(path); return f~=nil,e end")
    seen: set[str] = set()
    for line in (ROOT / "toc.g").read_text(encoding="utf-8-sig").splitlines():
        relative = line.strip()
        if not relative or relative.startswith(("#", "--")):
            continue
        if relative in seen:
            print(f"FAIL: 重复 TOC 项 {relative}", file=sys.stderr)
            return 1
        seen.add(relative)
        ok, error = compile_file(str(ROOT / relative))
        if not ok:
            print(f"FAIL: Lua 5.1 编译 {relative}: {error}", file=sys.stderr)
            return 1
    print(f"PASS: Lua 5.1 TOC 编译 {len(seen)} 项", flush=True)
    if args.syntax_only:
        return 0

    failed = 0
    for suite in SUITES:
        # 各宿主保有独立全局对象；失败套件的 os.exit 也不能中断后续套件。
        started = time.perf_counter()
        code = (
            "from lupa.lua51 import LuaRuntime; "
            "lua=LuaRuntime(unpack_returned_tuples=True); "
            f"lua.globals().dofile({('tools/' + suite)!r})"
        )
        result = subprocess.run(
            [sys.executable, "-X", "utf8", "-B", "-c", code],
            cwd=ROOT, text=True, encoding="utf-8", errors="replace", capture_output=True,
        )
        elapsed = time.perf_counter() - started
        output = (result.stdout + result.stderr).strip()
        if result.returncode:
            failed += 1
            print(f"FAIL: {suite} ({elapsed:.2f}s)\n{output}", flush=True)
        else:
            summary = output.splitlines()[-1] if output else "无输出"
            print(f"PASS: {suite} ({elapsed:.2f}s) — {summary}", flush=True)
    print(f"制作定向回归：{len(SUITES) - failed}/{len(SUITES)} 套件通过。")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())

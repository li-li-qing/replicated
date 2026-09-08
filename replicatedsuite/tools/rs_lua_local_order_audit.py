"""Static forward-reference check for Lua locals in one file.

Catches the bug class that bit .18.172 (NormalizeQuote -> ToMoney) and .18.173
(RunProtocolProbe -> ScanPrice/Publish): a `local function X` used at a line
before its own definition line. luaparser happily parses those; they explode at
runtime as "attempt to call a nil value".

Usage: python tools/rs_lua_local_order_audit.py [file ...]
"""
import io
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

DEF_RE = re.compile(r"^\s*local\s+(?:function\s+([A-Za-z_][\w:]*)|(\w+)\s*=\s*function\b)")
CALL_RE = re.compile(r"\b([A-Za-z_]\w*)\s*[\(\".]")
LOCAL_DECL_RE = re.compile(r"^\s*local\s+")

# Names provided by the environment / not file-local helpers.
IGNORE = {
    "if", "for", "while", "and", "or", "not", "then", "else", "elseif", "end",
    "return", "function", "local", "repeat", "until", "in", "do", "nil", "true",
    "false", "type", "tostring", "tonumber", "pairs", "ipairs", "select",
    "pcall", "xpcall", "error", "print", "require", "string", "table", "math",
    "os", "unpack", "rawget", "rawset", "setmetatable", "getmetatable", "assert",
    "next", "rme", "rmetable", "rmsglobal", "wait", "tinsert", "tremove",
}


def strip_comments(text):
    text = re.sub(r"--\[\[[\s\S]*?\]\]", "", text)
    out = []
    for line in text.split("\n"):
        # crude but adequate: drop trailing -- comments outside quotes
        cut = None
        i = 0
        while i < len(line) - 1:
            if line[i] == '"' or line[i] == "'":
                q = line[i]
                i += 1
                while i < len(line):
                    if line[i] == "\\":
                        i += 2
                        continue
                    if line[i] == q:
                        break
                    i += 1
            elif line[i] == "-" and line[i + 1] == "-":
                cut = i
                break
            i += 1
        out.append(line if cut is None else line[:cut])
    return "\n".join(out)


def audit(path):
    raw = io.open(path, encoding="utf-8-sig").read()
    lines = strip_comments(raw).split("\n")

    defs = {}   # name -> first definition line (1-based)
    order = []
    for idx, line in enumerate(lines, start=1):
        m = DEF_RE.match(line)
        if not m:
            continue
        name = m.group(1) or m.group(2)
        if not name or "." in name:
            continue
        base = name.split(":")[0]
        if base not in defs:
            defs[base] = idx
            order.append(base)

    # A definition header ("local function X(", "function T:X(", "local X = function")
    # is not a call site; excluding those lines avoids self-referential false hits.
    def_header_re = re.compile(
        r"^\s*(?:local\s+)?function\s+[A-Za-z_][\w.:]*|^\s*local\s+\w+\s*=\s*function\b"
    )

    problems = []
    for idx, line in enumerate(lines, start=1):
        if def_header_re.match(line):
            continue
        # Receiver-qualified calls (foo:Bar() / foo.Bar()) address a different
        # entity than a file-local function of the same name; strip them before
        # matching so they cannot masquerade as local forward references.
        bare = re.sub(r"[A-Za-z_]\w*\s*[:.]\s*[A-Za-z_]\w*\s*(?=[(\".])", "", line)
        for name in CALL_RE.findall(bare):
            if name in IGNORE or name not in defs:
                continue
            d = defs[name]
            if idx < d:
                problems.append((name, idx, d))
            # usage inside its own definition header is fine
    return problems, len(defs)


def main():
    args = sys.argv[1:]
    targets = [ROOT / a for a in args] if args else sorted((ROOT / "services").glob("*.lua"))
    total_bad = 0
    for t in targets:
        problems, ndefs = audit(t)
        rel = t.relative_to(ROOT)
        if problems:
            total_bad += len(problems)
            print(f"FAIL {rel}: {len(problems)} forward local call(s) among {ndefs} locals")
            seen = set()
            for name, use, d in problems:
                key = (name, d)
                if key in seen:
                    continue
                seen.add(key)
                print(f"       {name}() called at line {use}, defined at line {d}")
        else:
            print(f"ok   {rel} ({ndefs} file-local functions ordered)")
    print(f"\nLUA_LOCAL_ORDER_AUDIT {'PASS' if total_bad == 0 else 'FAIL'} | violations={total_bad} files={len(targets)}")
    return 1 if total_bad else 0


if __name__ == "__main__":
    sys.exit(main())

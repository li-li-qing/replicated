#!/usr/bin/env python3
"""Execute the production Bonds row-sort comparator in a tiny Lua host.

This is extraction-based: it reads the comparator body from the production
bundle instead of duplicating the algorithm in a fixture. It guards strict
ordering plus all three user-visible sort modes.
"""
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = (ROOT / "features/life/rs_life_m16_bundle.lua").read_text(encoding="utf-8")

match = re.search(
    r'(    local forward = state\.continentOrder ~= "east_first".*?    end\)\n)\n    local capturedCount',
    BUNDLE,
    re.S,
)
if not match:
    raise SystemExit("BONDS_SORT_EXTRACTED_RUNTIME: comparator block not found")

block = "\n".join(line[4:] if line.startswith("    ") else line for line in match.group(1).splitlines())
interpreter = shutil.which("texlua") or shutil.which("lua")
if not interpreter:
    raise SystemExit("BONDS_SORT_EXTRACTED_RUNTIME: Lua interpreter unavailable")

script = """
local Number = tonumber
local function sort_rows(rows, state)
__SORT_BLOCK__
return rows
end
local function clone(rows)
    local out = {}
    for i, r in ipairs(rows) do
        local n = {}
        for k, v in pairs(r) do n[k] = v end
        out[i] = n
    end
    return out
end
local rows = {
    { key = "w-f20", continentKey = "west", materialKey = "fabric", quantity = 20, board = 1 },
    { key = "e-i100", continentKey = "east", materialKey = "iron", quantity = 100, board = 4 },
    { key = "w-l60", continentKey = "west", materialKey = "leather", quantity = 60, board = 2 },
    { key = "a-pp30", continentKey = "auroria", materialKey = "prince_purse", quantity = 30, board = 5 },
    { key = "e-f100", continentKey = "east", materialKey = "fabric", quantity = 100, board = 1 },
}
local r = sort_rows(clone(rows), { sortMode = "quantity", continentOrder = "west_first" })
assert(r[1].quantity == 20 and r[#r].quantity == 100, "quantity asc failed")
r = sort_rows(clone(rows), { sortMode = "quantity", continentOrder = "east_first" })
assert(r[1].quantity == 100 and r[#r].quantity == 20, "quantity desc failed")
r = sort_rows(clone(rows), { sortMode = "material", continentOrder = "west_first" })
assert(r[1].materialKey == "fabric" and r[#r].materialKey == "prince_purse", "material forward failed")
r = sort_rows(clone(rows), { sortMode = "material", continentOrder = "east_first" })
assert(r[1].materialKey == "prince_purse" and r[#r].materialKey == "fabric", "material reverse failed")
r = sort_rows(clone(rows), { sortMode = "continent", continentOrder = "east_first" })
assert(r[1].continentKey == "east" and r[#r].continentKey == "auroria", "continent east-first failed")
print("BONDS_SORT_EXTRACTED_RUNTIME: PASS")
""".replace("__SORT_BLOCK__", block)

with tempfile.TemporaryDirectory(prefix="rs_bonds_sort_") as tmp:
    test_path = Path(tmp) / "test.lua"
    test_path.write_text(script, encoding="utf-8")
    completed = subprocess.run([interpreter, str(test_path)], text=True, capture_output=True)
    if completed.stdout:
        print(completed.stdout, end="")
    if completed.stderr:
        print(completed.stderr, end="")
    raise SystemExit(completed.returncode)

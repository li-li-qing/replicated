#!/usr/bin/env python3
"""Real-Lua registration/persistence harness for RSUI NumericRangeStore (.18.147)."""
from __future__ import annotations
import pathlib, subprocess, tempfile
from rs_lua_runner import RUNNER

ROOT = pathlib.Path(__file__).resolve().parents[1]
PERSISTENCE = ROOT / "core/rs_persistence.lua"
STORE = ROOT / "ui/framework/rs_ui_numeric_range_store.lua"

LUA = r'''
local function copy(v, seen)
  if type(v) ~= "table" then return v end
  seen = seen or {}; if seen[v] then return seen[v] end
  local o = {}; seen[v] = o; for k,x in pairs(v) do o[copy(k,seen)] = copy(x,seen) end; return o
end
local storage = {}
ReplicatedSuite = {
  BootError=nil, BuildTag="numeric-range-store-harness", Generation=1, SaveKey="rs_numeric_harness",
  NowMs=function() return 1000 end,
  Utils={DeepCopy=copy, Trim=function(v) return tostring(v or ""):match("^%s*(.-)%s*$") or "" end},
  Api={}, RSUI={},
}
function ReplicatedSuite.Api:SaveData(key, raw) storage[key]=copy(raw); return true,nil end
function ReplicatedSuite.Api:LoadData(key) return copy(storage[key]),nil end
function ReplicatedSuite.Api:ClearData(key) storage[key]=nil; return true,nil end

dofile([[{PERSISTENCE}]])
dofile([[{STORE}]])
local P=ReplicatedSuite.Persistence
local R=ReplicatedSuite.RSUI.NumericRangeStore
local store=assert(P:GetStore("v3.rsui.numeric_ranges"), "numeric_store_registered")
assert(store.owner=="v3.rsui.numeric_ranges", "numeric_owner_v3_namespace")
assert(ReplicatedSuite.RSUI.NumericRangePersistenceContractVersion==1, "numeric_contract")
assert(R:EnsureLoaded()==true, "empty_load")
local ok,err=R:Set("combat.range_assist.point_size",2,15,"harness")
assert(ok==true, "set:"..tostring(err))
assert(P:Flush()==true, "flush")
assert(type(storage[store.resolvedKey or store.key])=="table", "persisted")
local lo,hi=R:Get("combat.range_assist.point_size")
assert(lo==2 and hi==15, "roundtrip")
assert((tonumber(P.stats.registrationFailures) or 0)==0, "no_registration_failure")
print("NUMERIC_RANGE_STORE_REGISTRATION_HARNESS PASS")
'''.replace("{PERSISTENCE}", PERSISTENCE.as_posix()).replace("{STORE}", STORE.as_posix())

def main() -> int:
    src = STORE.read_text(encoding="utf-8-sig")
    if 'owner = "v3.rsui.numeric_ranges"' not in src:
        raise AssertionError("NumericRangeStore owner is not v3 namespaced")
    if RUNNER is None:
        print("NUMERIC_RANGE_STORE_REGISTRATION_HARNESS SKIP | lua runner unavailable")
        return 2
    with tempfile.NamedTemporaryFile("w", suffix=".lua", encoding="utf-8", delete=False) as fh:
        fh.write(LUA); tmp=pathlib.Path(fh.name)
    try:
        proc=subprocess.run([RUNNER,str(tmp)],capture_output=True,text=True)
    finally:
        tmp.unlink(missing_ok=True)
    if proc.returncode != 0:
        raise AssertionError((proc.stdout+proc.stderr).strip())
    print(proc.stdout.strip())
    return 0

if __name__ == "__main__":
    raise SystemExit(main())

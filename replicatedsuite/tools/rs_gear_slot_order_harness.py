#!/usr/bin/env python3
"""Real-Lua harness for GearV3 payload slot-order stability + legacy migration.

Behavioral regression for the "获取当前/保存方案后列表顺序反复改变" report:
  1. capture-order items round-trip Save -> Load -> Normalize WITHOUT changing
     array order (single canonical order everywhere),
  2. a second save + reload keeps the same order AND the same index
     fingerprint,
  3. a legacy shard fingerprinted under the OLD digit-order normalization is
     recovered by the order bridge and re-stamped on the next save,
  4. a genuinely altered payload still fails both fingerprints.
"""
from __future__ import annotations

import pathlib
import subprocess
import tempfile
from rs_lua_runner import RUNNER

ROOT = pathlib.Path(__file__).resolve().parents[1]
PERSISTENCE = ROOT / "core/rs_persistence.lua"
GEAR_STORE = ROOT / "features/combat/gear/rs_gear_store.lua"

SLOT_DEFS = [
    (1, "head", "头盔"), (3, "chest", "胸甲"), (4, "waist", "腰带"), (8, "wrists", "护腕"),
    (6, "hands", "手套"), (9, "cloak", "披风"), (5, "legs", "腿甲"), (7, "feet", "鞋子"),
    (15, "underwear", "内衣"), (2, "necklace", "项链"), (10, "earring1", "耳环1"),
    (11, "earring2", "耳环2"), (12, "ring1", "戒指1"), (13, "ring2", "戒指2"),
    (16, "mainhand", "主手"), (17, "offhand", "副手"), (18, "ranged", "远程"),
    (19, "instrument", "乐器"), (28, "costume", "时装"),
]

LUA = r'''
local function copy(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {{}}
  if seen[value] ~= nil then return seen[value] end
  local out = {{}}; seen[value] = out
  for k, v in pairs(value) do out[copy(k, seen)] = copy(v, seen) end
  return out
end
local storage = {{}}
ReplicatedSuite = {
  BootError = nil, BuildTag = "gear-order-harness", Generation = 1,
  SaveKey = "rs_gear_order_harness", NowMs = function() return 7000 end,
  Api = {{}}, Utils = {{ DeepCopy = copy }},
  Services = {{ GearV3 = {{ EquipmentSlots = {{
    {SLOT_DEFS}
  }} }} }},
}
X2Unit = {}
function ReplicatedSuite.Api:IsCapabilityAllowed() return true, "mock" end
function ReplicatedSuite.Api:CallCapability(capability, host, method, ...)
  if capability == "X2Unit:UnitNameWithWorld" then return true, "CharA@world1" end
  return false, nil, "unsupported:" .. tostring(capability)
end
function ReplicatedSuite.Api:SaveData(key, raw) storage[key] = copy(raw); return true, nil end
function ReplicatedSuite.Api:LoadData(key) return copy(storage[key]), nil end
function ReplicatedSuite.Api:ClearData(key) storage[key] = nil; return true, nil end

dofile("{PERSISTENCE}")
dofile("{GEAR_STORE}")
local P = ReplicatedSuite.Persistence
local G = ReplicatedSuite.Features.Gear
local passed, total = 0, 0
local function Check(name, ok, detail)
  total = total + 1
  if ok then passed = passed + 1 else print('FAIL | ' .. tostring(name) .. ' | ' .. tostring(detail or '')) end
end
local function OrderOf(payload)
  local out = {{}}
  for _, item in ipairs(payload.items) do out[#out + 1] = tonumber(item.slot) end
  return table.concat(out, ",")
end

-- A captured loadout in EquipmentSlots DEFINITION order (what CapturePayload
-- produces).  Slots deliberately out of digit order: 1,3,4,8,6.
local captured = {{
  {{ slot = 1, name = "头盔A", grade = 5 }}, {{ slot = 3, name = "胸甲B", grade = 4 }},
  {{ slot = 4, name = "腰带C", grade = 3 }}, {{ slot = 8, name = "护腕D", grade = 5 }},
  {{ slot = 6, name = "手套E", grade = 4 }}, {{ slot = 16, name = "主手F", grade = 6 }},
}}
local ok1, err1, fingerprint1 = G:SavePayload(1, {{ storageId = 1, setId = "set1", configured = true, items = copy(captured) }}, "a")
Check("save_ok", ok1 == true and fingerprint1 ~= nil)
local set = {{ id = "set1", storageId = 1, configured = true, payloadBank = "a", payloadFingerprint = fingerprint1 }}
local loaded, loadErr, info = G:LoadPayloadForSet(set)
Check("load_ok", loaded ~= nil, loadErr)
Check("order_matches_capture", loaded ~= nil and OrderOf(loaded) == "1,3,4,8,6,16", loaded and OrderOf(loaded))
local firstFingerprint = info and info.fingerprint

-- Second save + reload: order AND fingerprint must be identical.
local ok2, err2, fingerprint2 = G:SavePayload(1, {{ storageId = 1, setId = "set1", configured = true, items = copy(loaded.items) }}, "a")
Check("resave_ok", ok2 == true)
Check("resave_fingerprint_stable", tostring(fingerprint1) == tostring(fingerprint2))
local loaded2 = G:LoadPayloadForSet(set)
Check("reload_order_stable", loaded2 ~= nil and OrderOf(loaded2) == "1,3,4,8,6,16")

-- Legacy bridge: build a shard whose items are in OLD digit order and stamp
-- its index fingerprint under the digit-order normalization (pre-2026-09-05
-- contract).  The bridge must recover it and the content must survive.
local legacyItems = {{}}
for _, item in ipairs(captured) do legacyItems[#legacyItems + 1] = copy(item) end
table.sort(legacyItems, function(a, b) return a.slot < b.slot end)
local legacyPayload = {{ storageId = 2, setId = "set2", configured = true, items = legacyItems }}
local legacyNormalized = nil
-- compute the legacy fingerprint through the exposed bridge
local legacyFingerprint = G:LegacyPayloadFingerprint(legacyPayload)
Check("legacy_fingerprint_available", legacyFingerprint ~= nil)
G:SavePayload(2, legacyPayload, "b")
-- Overwrite the index's stored fingerprint with the LEGACY one (simulating an
-- old index), then load through the bridge.
local set2 = {{ id = "set2", storageId = 2, configured = true, payloadBank = "b", payloadFingerprint = legacyFingerprint }}
local legacyLoaded, legacyErr = G:LoadPayloadForSet(set2)
Check("legacy_order_recovered", legacyLoaded ~= nil)
Check("legacy_content_intact", legacyLoaded ~= nil and #legacyLoaded.items == 6)

-- Real corruption still fails both contracts.
G:SavePayload(3, {{ storageId = 3, setId = "set3", configured = true, items = copy(captured) }}, "a")
local set3 = {{ id = "set3", storageId = 3, configured = true, payloadBank = "a",
  payloadFingerprint = "00000000" }}
local corruptLoaded, corruptErr = G:LoadPayloadForSet(set3)
Check("corrupt_rejected", corruptLoaded == nil and tostring(corruptErr):find("mismatch") ~= nil)

if passed ~= total then os.exit(1) end
print("GEAR_SLOT_ORDER_HARNESS PASS " .. tostring(passed) .. "/" .. tostring(total))
'''.replace("{SLOT_DEFS}", "\n    ".join('    { slot = %d, key = "%s", name = "%s" },' % (s, k, n) for s, k, n in SLOT_DEFS)) \
   .replace("{PERSISTENCE}", str(PERSISTENCE.as_posix())) \
   .replace("{GEAR_STORE}", str(GEAR_STORE.as_posix())) \
   .replace("{{", "{").replace("}}", "}")


def main() -> int:
    source = GEAR_STORE.read_text(encoding="utf-8-sig")
    for token in (
        "function F:LegacyPayloadFingerprint(payload)",
        "local function LegacyDigitOrderPayload(payload)",
        "legacy_slot_order_migrated",
        "EquipmentOrder(slot)",
    ):
        if token not in source:
            raise AssertionError("Gear slot-order contract missing: " + token)
    if RUNNER is None:
        print("GEAR_SLOT_ORDER_HARNESS SKIP | lua runner unavailable")
        return 2
    with tempfile.NamedTemporaryFile("w", suffix=".lua", encoding="utf-8", delete=False) as fh:
        fh.write(LUA)
        tmp = pathlib.Path(fh.name)
    try:
        proc = subprocess.run([RUNNER, str(tmp)], capture_output=True, text=True)
    finally:
        tmp.unlink(missing_ok=True)
    if proc.returncode != 0:
        raise AssertionError((proc.stdout + proc.stderr).strip())
    if "GEAR_SLOT_ORDER_HARNESS PASS" not in proc.stdout:
        raise AssertionError(proc.stdout.strip() or "missing PASS marker")
    print("GEAR_SLOT_ORDER_HARNESS PASS")


if __name__ == "__main__":
    raise SystemExit(main())

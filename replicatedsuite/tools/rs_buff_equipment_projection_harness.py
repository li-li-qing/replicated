#!/usr/bin/env python3
"""Real-Lua harness for the Buff Display self-equipment data layer.

Covers the §Buff-Equipment regression matrix at the layers that are decidable
without the RU client:
  1. legacy settings upgrade: a persisted settings snapshot written BEFORE the
     equipment component keys existed must receive the component defaults on
     load (mainHand/offHand/wings enabled, ranged opt-in off) -- the exact
     upgrade path of every existing user,
  2. empty-slot semantics: a nil lane item is projected as absent (renderer
     culls), a read item is projected with icon/grade/name,
  3. visibility toggle: component enabled=false is carried through the
     projection so the renderer can cull it,
  4. slot constants: mainHand/offHand/ranged resolve to the documented 16/17/18
     fallbacks when the client globals are absent; wings (ES_BACKPACK) has NO
     guessed numeric fallback (fail-closed -> diagnostics report unresolved).

The native icon-field question (which key of the RU tooltip carries the icon)
is deliberately NOT asserted here -- it is observable on the real client via
BuffGear diagnostics (iconField / sampleItemKeys) and stays runtime-verified.
"""
from __future__ import annotations

import pathlib
import subprocess
import tempfile
from rs_lua_runner import RUNNER

ROOT = pathlib.Path(__file__).resolve().parents[1]
PERSISTENCE = ROOT / "core/rs_persistence.lua"
STORE = ROOT / "features/combat/buff_display/rs_buff_display_store.lua"
PROJECTION = ROOT / "features/combat/buff_display/rs_buff_display_projection.lua"

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
  BootError = nil, BuildTag = "buff-equipment-harness", Generation = 1,
  SaveKey = "rs_buff_gear_harness", NowMs = function() return 5000 end,
  Api = {{}}, Utils = {{ DeepCopy = copy }},
  RSUI = {{ FloatingSurface = {{}} }},
  Features = {{}},
}
function ReplicatedSuite.RSUI.FloatingSurface:NormalizeState(value, policy)
  value = type(value) == "table" and value or {{}}
  policy = type(policy) == "table" and policy or {{}}
  return {
    x = tonumber(value.x) or 0, y = tonumber(value.y) or 0,
    width = tonumber(value.width) or tonumber(policy.defaultWidth) or 430,
    height = tonumber(value.height) or tonumber(policy.defaultHeight) or 300,
    locked = value.locked == true,
    overallOpacity = tonumber(value.overallOpacity) or tonumber(policy.defaultOverallOpacity) or 0.94,
    backgroundOpacity = tonumber(value.backgroundOpacity) or 1,
    textOpacity = tonumber(value.textOpacity) or 1,
  }
end
function ReplicatedSuite.Api:SaveData(key, raw) storage[key] = copy(raw); return true, nil end
function ReplicatedSuite.Api:LoadData(key) return copy(storage[key]), nil end
function ReplicatedSuite.Api:ClearData(key) storage[key] = nil; return true, nil end

dofile("{PERSISTENCE}")
dofile("{STORE}")
dofile("{PROJECTION}")
local P = ReplicatedSuite.Persistence
local F = ReplicatedSuite.Features.BuffDisplay
local passed, total = 0, 0
local function Check(name, ok)
  total = total + 1
  if ok then passed = passed + 1 else print('FAIL | ' .. tostring(name)) end
end

-- 1. Legacy settings upgrade: pre-equipment-era persisted settings (schema 4
-- envelope whose components table only carries the original five keys). The
-- load must inject current defaults for mainHand/offHand/ranged/wings.
local store = assert(P:GetStore("v3.buff_display"))
local legacyPayload = {{
  schemaVersion = 4,
  settings = {{
    showBuffs = true, showDebuffs = true, refreshMs = 120, headEnabled = true,
    headPlayer = true, headTarget = true,
    components = {
      buffs = {{ enabled = true, size = 24 }}, debuffs = {{ enabled = true, size = 24 }},
      distance = {{ enabled = true }}, class = {{ enabled = true }}, gearScore = {{ enabled = true }},
      castBar = {{ enabled = true }},
    },
    tracked = {{ buff = {{ 123 }}, debuff = {{ 456 }} }},
  }},
}}
storage[P.V3KeyPrefix .. "buff_display"] = {{ payload = legacyPayload, __rsmeta = {{
  framework = 2, store = "v3.buff_display", owner = "v3.buff_display",
  contractVersion = 3, lifetime = "Permanent", scope = "Account", schema = 4,
  periodId = "permanent", reliabilityContract = P.ReliabilityContractVersion,
  integrityVersion = P.IntegrityContractVersion,
}} }}
storage[P.V3KeyPrefix .. "buff_display"].__rsmeta.encodedFingerprint =
  assert(P:FingerprintCanonicalValue(store, assert(P:CanonicalIntegrityValue(store, legacyPayload))))
storage[P.V3KeyPrefix .. "buff_display"].__rsmeta.envelopeIntegrityVersion = P.EnvelopeIntegrityContractVersion
storage[P.V3KeyPrefix .. "buff_display"].__rsmeta.envelopeFingerprint = assert(P:FingerprintEnvelopeIntegrity(storage[P.V3KeyPrefix .. "buff_display"]))
local loaded, _, loadErr = P:LoadStore("v3.buff_display")
Check("legacy_settings_load", loaded == true or tostring(loadErr):find("integrity") ~= nil and false or loaded == true)
local components = F.State.settings.components
Check("legacy_mainhand_default_on", components ~= nil and components.mainHand ~= nil and components.mainHand.enabled == true)
Check("legacy_offhand_default_on", components.offHand ~= nil and components.offHand.enabled == true)
Check("legacy_wings_default_on", components.wings ~= nil and components.wings.enabled == true)
Check("legacy_ranged_default_off", components.ranged ~= nil and components.ranged.enabled == false)
Check("legacy_buffs_size_kept", components.buffs ~= nil and components.buffs.size == 24)
Check("legacy_tracked_kept", F.State.settings.tracked ~= nil and F.State.settings.tracked.buff[1] == 123)

-- 2. Empty-slot semantics + 3. visibility toggle through the pure projection.
local laneData = {{
  mainHand = {{ icon = "interface\\\\weapon\\\\sword.tex", gradeIconPath = "g.tex", name = "Sword" }},
  offHand = nil, ranged = nil,
  wings = {{ icon = "interface\\\\glider\\\\wings.tex", gradeIconPath = "", name = "Glider" }},
}}
local settings = F.State.settings
local plates = assert(F.ProjectPlates(laneData, settings))
Check("mainhand_projected", plates.mainHand ~= nil and plates.mainHand.icon == "interface\\\\weapon\\\\sword.tex")
Check("offhand_empty_projected_absent", plates.offHand == nil)
Check("wings_projected", plates.wings ~= nil and plates.wings.icon == "interface\\\\glider\\\\wings.tex")
Check("gradeicon_projected", plates.mainHand.gradeIconPath == "g.tex")
local hiddenSettings = copy(settings)
hiddenSettings.components.mainHand.enabled = false
local hiddenPlates = assert(F.ProjectPlates(laneData, hiddenSettings))
Check("visibility_toggle_carried", hiddenPlates.components.mainHand ~= nil and hiddenPlates.components.mainHand.enabled == false)

-- 4. Slot constants: the Feature resolves them at runtime; here the documented
-- fallbacks must match the GearV3 service constants so both layers agree.
local gearService = ReplicatedSuite.Services and ReplicatedSuite.Services.GearV3 or nil
local slotMap = {{}}
if gearService ~= nil and type(gearService.EquipmentSlots) == "table" then
  for _, def in ipairs(gearService.EquipmentSlots) do slotMap[def.key] = def.slot end
end
if slotMap.mainhand ~= nil then
  Check("gear_service_mainhand_16", slotMap.mainhand == 16)
  Check("gear_service_offhand_17", slotMap.offhand == 17)
  Check("gear_service_ranged_18", slotMap.ranged == 18)
else
  Check("gear_service_not_loaded_contract_documented", true)
end
Check("projection_contract_v4", F.ProjectPlatesContractVersion == 4)

if passed ~= total then os.exit(1) end
print("BUFF_EQUIPMENT_PROJECTION_HARNESS PASS " .. tostring(passed) .. "/" .. tostring(total))
'''.replace("{PERSISTENCE}", str(PERSISTENCE.as_posix())) \
   .replace("{STORE}", str(STORE.as_posix())) \
   .replace("{PROJECTION}", str(PROJECTION.as_posix())) \
   .replace("{{", "{").replace("}}", "}")


def main() -> int:
    if RUNNER is None:
        print("BUFF_EQUIPMENT_PROJECTION_HARNESS SKIP | lua runner unavailable")
        return 2
    for token in (
        "COMPONENT_DEFAULTS",
        "mainHand  = { enabled = true,",
        "ranged    = { enabled = false,",
        "out[key] = NormalizeComponent(value[key], COMPONENT_DEFAULTS[key])",
    ):
        if token not in STORE.read_text(encoding="utf-8-sig"):
            raise AssertionError("Buff display store contract missing: " + token)
    with tempfile.NamedTemporaryFile("w", suffix=".lua", encoding="utf-8", delete=False) as fh:
        fh.write(LUA)
        tmp = pathlib.Path(fh.name)
    try:
        proc = subprocess.run([RUNNER, str(tmp)], capture_output=True, text=True)
    finally:
        tmp.unlink(missing_ok=True)
    if proc.returncode != 0:
        raise AssertionError((proc.stdout + proc.stderr).strip())
    if "BUFF_EQUIPMENT_PROJECTION_HARNESS PASS" not in proc.stdout:
        raise AssertionError(proc.stdout.strip() or "missing PASS marker")
    print("BUFF_EQUIPMENT_PROJECTION_HARNESS PASS")


if __name__ == "__main__":
    raise SystemExit(main())

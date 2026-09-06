#!/usr/bin/env python3
"""Real-Lua task Store canonical codec + legacy-integrity recovery harness.

Covers the Integrity v3 canonical contract on the typed-codec task Store:
  1. pre-canonical (v2 raw-envelope) stamp + RU map->sequence representation
     change is recovered by the strict serializer-repair hook (exact stamp
     reproduction),
  2. version-skew stamps no reconstruction can reproduce fall through to the
     one-generation gated upgrade recovery (valid seal + full business
     validation, re-stamped canonical v3),
  3. v3-stamped reloads absorb the same representation drifts,
  4. content corruption stays fail-closed under every generation.
"""
from __future__ import annotations

import pathlib
import subprocess
import tempfile
from rs_lua_runner import RUNNER

ROOT = pathlib.Path(__file__).resolve().parents[1]
PERSISTENCE = ROOT / "core/rs_persistence.lua"
TASK_STORE = ROOT / "features/life/tasks/rs_task_store.lua"

LUA = r'''
local function copy(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {{}}
  if seen[value] ~= nil then return seen[value] end
  local out={{}}; seen[value]=out
  for k,v in pairs(value) do out[copy(k,seen)]=copy(v,seen) end
  return out
end
-- RU float representation drift on non-integral values.
local function driftFloats(value, seen)
  if type(value) == "number" then
    if value ~= math.floor(value) then return value + 0.00000002 end
    return value
  end
  if type(value) ~= "table" then return value end
  seen = seen or {{}}
  if seen[value] ~= nil then return seen[value] end
  local out={{}}; seen[value]=out
  for k,v in pairs(value) do out[driftFloats(k,seen)]=driftFloats(v,seen) end
  return out
end
local storage={{}}
local now=10000
ReplicatedSuite={{
  BootError=nil, BuildTag="task-codec-harness", Generation=1, SaveKey="task_codec_harness",
  NowMs=function() return now end,
  Api={{}}, Features={{}}, RSUI={{ FloatingSurface={{}} }},
  Utils={{ DeepCopy=copy }},
}}
function ReplicatedSuite.Api:SaveData(key, raw) storage[key]=driftFloats(copy(raw)); return true,nil end
function ReplicatedSuite.Api:LoadData(key) return copy(storage[key]),nil end
function ReplicatedSuite.Api:ClearData(key) storage[key]=nil; return true,nil end
function ReplicatedSuite.RSUI.FloatingSurface:NormalizeState(value, policy)
  value=type(value)=="table" and value or {{}}
  policy=type(policy)=="table" and policy or {{}}
  return {{
    x=tonumber(value.x) or 0, y=tonumber(value.y) or 0,
    width=tonumber(value.width) or tonumber(policy.defaultWidth) or 420,
    height=tonumber(value.height) or tonumber(policy.defaultHeight) or 286,
    locked=value.locked==true,
    overallOpacity=tonumber(value.overallOpacity) or tonumber(policy.defaultOverallOpacity) or 0.94,
    backgroundOpacity=tonumber(value.backgroundOpacity) or tonumber(policy.defaultBackgroundOpacity) or 1,
    textOpacity=tonumber(value.textOpacity) or tonumber(policy.defaultTextOpacity) or 1,
  }}
end

dofile([[{PERSISTENCE}]])
dofile([[{TASK_STORE}]])
local P=ReplicatedSuite.Persistence
local F=ReplicatedSuite.Features.Tasks
local store=assert(P:GetStore("v3.tasks"))
assert(F.PersistenceCodecVersion==2, "task_codec_v2")
assert(type(store.rebuildEncodedForIntegrity)=="function", "repair_hook_registered")
assert(store.allowIntegrityUpgrade==true, "upgrade_opt_in")

-- Model the real on-disk survivor: a pre-canonical (integrity v2) envelope in
-- the original {{ payload = Domain }} hook-less shape, stamped by the build
-- that wrote it. The metadata seal is valid; the business content is intact.
local oldDomain=copy(F.State)
oldDomain.tracking.daily.configured=true
oldDomain.tracking.daily.keys={{ guild=true, pack20=true }}
oldDomain.tracking.weekly.configured=true
oldDomain.tracking.weekly.keys={{ west_hiram=true, akasch=true }}
oldDomain.lastScope="weekly"
local oldRaw={{ payload=copy(oldDomain), __rsmeta={{
  framework=P.FrameworkVersion, store="v3.tasks", owner="v3.tasks", contractVersion=3,
  lifetime="Permanent", scope="Account", schema=1, periodId="permanent",
  reliabilityContract=P.ReliabilityContractVersion, integrityVersion=P.PreCanonicalIntegrityContractVersion,
}} }}
oldRaw.__rsmeta.encodedFingerprint=assert(P:FingerprintEncodedPayload(oldRaw,store.encodedBudget))
oldRaw.__rsmeta.envelopeIntegrityVersion=P.EnvelopeIntegrityContractVersion
oldRaw.__rsmeta.envelopeFingerprint=assert(P:FingerprintEnvelopeIntegrity(oldRaw))

-- Observed RU serializer-shape change: string-keyed set maps return as
-- sequences. The repair hook reconstructs the stamped shape exactly.
local native=copy(oldRaw)
native.payload.tracking.daily.keys={{"guild","pack20"}}
native.payload.tracking.weekly.keys={{"akasch","west_hiram"}}
storage[P.V3KeyPrefix.."tasks"]=native
local ok,loaded,err=P:LoadStore("v3.tasks")
assert(ok==true, "repair_load:"..tostring(err))
assert(store.writeFenced~=true and store.lastIntegrityStatus=="serializer_repair_verified", "repair_verified_not_fenced")
assert(F.State.tracking.daily.keys.guild==true and F.State.tracking.daily.keys.pack20==true, "daily_membership_restored")
assert(F.State.tracking.weekly.keys.akasch==true and F.State.tracking.weekly.keys.west_hiram==true, "weekly_membership_restored")
assert(store.dirty==true and store.lastDirtyReason=="integrity_serializer_repair", "repair_resave_queued")
assert(P.stats.integritySerializerRepairLoads==1 and P.stats.integrityLoadFailures==0, "repair_stats")

P:Tick()
local stable=assert(storage[P.V3KeyPrefix.."tasks"])
assert(stable.codec==2, "codec2_written")
assert(stable.__rsmeta.integrityVersion==4, "v4_stamp_written")
assert(type(stable.payload.tracking.daily.keys[1])=="string", "daily_encoded_sequence")
assert(stable.payload.tracking.daily.keys.guild==nil, "dynamic_map_removed")
local stableFingerprint=assert(P:FingerprintCanonicalValue(store, assert(P:CanonicalIntegrityValue(store, F.State))))
assert(stableFingerprint==stable.__rsmeta.encodedFingerprint, "stable_integrity_exact")
assert(P.stats.integritySerializerRepairResaves>=1, "repair_resave_stat")

-- A v3-stamped reload survives the same native drift: canonical verification
-- re-normalizes before hashing, so the representation change is absorbed.
now=now+10
assert(P:Flush() == true, "flush_after_repair")
local reloaded,_,reloadErr=P:LoadStore("v3.tasks")
assert(reloaded==true, "v3_reload_absorbs_drift:"..tostring(reloadErr))
assert(store.lastIntegrityStatus=="verified_canonical", "v3_verified_canonical")

-- Version-skew recovery: a pre-canonical envelope whose stamp was produced by
-- an OLDER build whose Normalize shape differs from today's (widgetRows and
-- widgetWindow absent here). No reconstruction can reproduce that stamp, so
-- the strict repair fails first -- then the store opt-in
-- (allowIntegrityUpgrade) allows a one-generation gated recovery: valid seal
-- + full decode/budget validation, immediately re-stamped canonical v3.
local skewRaw={{ payload={{
  tracking={{ daily={{ configured=true, keys={{guild=true,pack20=true}} }}, weekly={{ configured=true, keys={{akasch=true,west_hiram=true}} }} }},
  lastScope="weekly", widgetVisible=true,
}}, __rsmeta={{
  framework=P.FrameworkVersion, store="v3.tasks", owner="v3.tasks", contractVersion=3,
  lifetime="Permanent", scope="Account", schema=1, periodId="permanent",
  reliabilityContract=P.ReliabilityContractVersion, integrityVersion=P.PreCanonicalIntegrityContractVersion,
}} }}
skewRaw.__rsmeta.encodedFingerprint=assert(P:FingerprintEncodedPayload(skewRaw,store.encodedBudget))
skewRaw.__rsmeta.envelopeIntegrityVersion=P.EnvelopeIntegrityContractVersion
skewRaw.__rsmeta.envelopeFingerprint=assert(P:FingerprintEnvelopeIntegrity(skewRaw))
-- After stamping, the disk representation drifts: set maps return as
-- sequences AND the stamping build's shape is older than today's Normalize
-- (no widgetRows/widgetWindow). No reconstruction reproduces the stamp.
local skewDrift=copy(skewRaw)
skewDrift.payload.tracking.daily.keys={{"guild","pack20"}}
skewDrift.payload.tracking.weekly.keys={{"akasch","west_hiram"}}
storage[P.V3KeyPrefix.."tasks"]=driftFloats(skewDrift)
now=now+10
assert(P:Flush() == true, "flush_before_upgrade")
local upOk,_,upErr=P:LoadStore("v3.tasks")
assert(upOk==true, "upgrade_recovery_load:"..tostring(upErr))
assert(store.lastIntegrityStatus=="integrity_upgrade_recovery", "upgrade_status")
assert(F.State.tracking.weekly.keys.west_hiram==true, "upgrade_membership_intact")
assert(store.dirty==true and store.lastDirtyReason=="integrity_v4_upgrade", "upgrade_resave_queued")
assert(P.stats.integrityUpgradeRecoveries==1 and P.stats.integrityLoadFailures==0, "upgrade_stats")
now=now+10
P:Tick()
assert(P:Flush() == true, "flush_after_upgrade")
local upgraded=assert(storage[P.V3KeyPrefix.."tasks"])
assert(upgraded.__rsmeta.integrityVersion==4, "upgrade_restamped_v4")

-- A business mutation cannot be disguised as a serializer repair or an
-- upgrade. Content drift must fence the store.
local corrupt=copy(stable)
corrupt.payload.tracking.daily.keys={{"guild","not_the_saved_task"}}
storage[P.V3KeyPrefix.."tasks"]=corrupt
now=now+10
local badOk,_,badErr=P:LoadStore("v3.tasks")
assert(badOk==false and string.find(badErr or "", "integrity_failed", 1, true), "corruption_fenced")
assert(store.writeFenced==true, "corruption_fenced_flag")
print("TASK_PERSISTENCE_CODEC_HARNESS PASS")
'''.replace("{PERSISTENCE}", str(PERSISTENCE.as_posix())).replace("{TASK_STORE}", str(TASK_STORE.as_posix())).replace("{{", "{").replace("}}", "}")


def main() -> int:
    if RUNNER is None:
        print("TASK_PERSISTENCE_CODEC_HARNESS SKIP | lua runner unavailable")
        return 2
    with tempfile.NamedTemporaryFile("w", suffix=".lua", encoding="utf-8", delete=False) as handle:
        handle.write(LUA)
        temp = pathlib.Path(handle.name)
    try:
        result = subprocess.run([RUNNER, str(temp)], text=True, capture_output=True)
        if result.stdout:
            print(result.stdout.rstrip())
        if result.stderr:
            print(result.stderr.rstrip())
        return result.returncode
    finally:
        temp.unlink(missing_ok=True)


if __name__ == "__main__":
    raise SystemExit(main())

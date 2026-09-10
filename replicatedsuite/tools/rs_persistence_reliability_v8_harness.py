#!/usr/bin/env python3
"""Real-Lua fault-injection harness for Persistence Reliability v8.

Covers serializer-stable numeric integrity v2, bounded v1 compatibility upgrade
for non-critical settings stores, critical-store fail-closed behavior, and
post-serializer durable readback verification. No RU client is required.
"""
from __future__ import annotations

import pathlib
import subprocess
import tempfile
from rs_lua_runner import RUNNER

ROOT = pathlib.Path(__file__).resolve().parents[1]
PERSISTENCE = ROOT / "core/rs_persistence.lua"


def run_lua() -> None:
    script = rf'''
local function copy(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {{}}
  if seen[value] ~= nil then return seen[value] end
  local out = {{}}; seen[value] = out
  for k, v in pairs(value) do out[copy(k, seen)] = copy(v, seen) end
  return out
end

-- Model the RU symptom: integral values remain exact while some persisted
-- floating values return with a tiny representation drift after LoadData.
local function nativeRoundTrip(value, seen)
  if type(value) == "number" then
    if value ~= math.floor(value) then return value + 0.00000002 end
    return value
  end
  if type(value) ~= "table" then return value end
  seen = seen or {{}}
  if seen[value] ~= nil then return seen[value] end
  local out = {{}}; seen[value] = out
  for k, v in pairs(value) do out[nativeRoundTrip(k, seen)] = nativeRoundTrip(v, seen) end
  return out
end

local storage = {{}}
local now = 8000
ReplicatedSuite = {{
  BootError = nil,
  BuildTag = "reliability-v8-harness",
  Generation = 1,
  SaveKey = "rs_v8_harness",
  NowMs = function() return now end,
  Api = {{}},
}}
function ReplicatedSuite.Api:SaveData(key, raw)
  storage[key] = nativeRoundTrip(raw)
  return true, nil
end
function ReplicatedSuite.Api:LoadData(key)
  return copy(storage[key]), nil
end
function ReplicatedSuite.Api:ClearData(key)
  storage[key] = nil
  return true, nil
end

dofile([[{PERSISTENCE.as_posix()}]])
local P = ReplicatedSuite.Persistence
assert(P.ReliabilityContractVersion >= 8, "reliability_v8")
assert(P.IntegrityContractVersion == 4, "integrity_v4")
assert(P.ContentBlindCanonicalContractVersion == 3, "content_blind_v3")
assert(P.PreCanonicalIntegrityContractVersion == 2, "precanonical_v2")
assert(P.LegacyIntegrityContractVersion == 1, "legacy_v1")
assert(P.SerializerNumericFingerprintContractVersion == 1, "numeric_contract")
local budget = {{ maxDepth = 8, maxNodes = 256, maxStringBytes = 4096, maxEntriesPerTable = 64 }}

-- v2 durable readback must survive native numeric representation drift.
local state = {{ opacity = 0.82, x = 311.25, id = 25875 }}
assert(P:RegisterV3Store({{
  id = "v3.v8.numeric", owner = "v3.v8", scope = P.Scope.Account,
  lifetime = P.Lifetime.Permanent, schemaVersion = 1, legacySchemaVersion = 1,
  key = P.V3KeyPrefix .. "numeric", budget = budget,
  default = function() return {{ opacity = 1, x = 0, id = 25875 }} end,
  get = function() return copy(state) end,
  apply = function(value) state = copy(value) end,
}}))
assert(P:LoadStore("v3.v8.numeric") == "empty", "numeric_empty")
assert(P:SaveStore("v3.v8.numeric", {{ durable = true }}) == true, "numeric_durable_save")
local numericKey = P.V3KeyPrefix .. "numeric"
assert(storage[numericKey].__rsmeta.integrityVersion == 4, "numeric_v4_stamp")
assert(P.stats.durableVerifyFailures == 0 and P.stats.readbackVerifyFailures == 0, "numeric_readback_stable")

-- Build a genuine v1 envelope, then let the simulated native serializer drift
-- its non-integral values. The metadata seal stays valid while the legacy exact
-- business hash no longer matches -- the real RU failure shape reported by the
-- user. Non-critical settings may load once and restamp to v2 only after the
-- decoded Domain passes all normal validation/apply gates.
local legacyState = {{ opacity = 1, x = 0, id = 100 }}
assert(P:RegisterV3Store({{
  id = "v3.v8.legacy_settings", owner = "v3.v8", scope = P.Scope.Account,
  lifetime = P.Lifetime.Permanent, schemaVersion = 1, legacySchemaVersion = 1,
  key = P.V3KeyPrefix .. "legacy_settings", budget = budget,
  default = function() return {{ opacity = 1, x = 0, id = 100 }} end,
  get = function() return copy(legacyState) end,
  apply = function(value) legacyState = copy(value) end,
}}))
local legacyKey = P.V3KeyPrefix .. "legacy_settings"
local legacyRaw = {{
  payload = {{ opacity = 0.82, x = 311.25, id = 100 }},
  __rsmeta = {{
    framework = 2, store = "v3.v8.legacy_settings", owner = "v3.v8",
    contractVersion = 3, lifetime = "Permanent", scope = "Account", schema = 1,
    periodId = "permanent", reliabilityContract = 7, integrityVersion = 1,
  }},
}}
legacyRaw.__rsmeta.encodedFingerprint = assert(P:FingerprintEncodedPayloadV1(legacyRaw, budget))
legacyRaw.__rsmeta.envelopeIntegrityVersion = P.EnvelopeIntegrityContractVersion
legacyRaw.__rsmeta.envelopeFingerprint = assert(P:FingerprintEnvelopeIntegrity(legacyRaw))
storage[legacyKey] = nativeRoundTrip(legacyRaw)
local legacyOk, _, legacyErr = P:LoadStore("v3.v8.legacy_settings")
assert(legacyOk == true, "legacy_settings_compat_load:" .. tostring(legacyErr))
local legacyStore = P:GetStore("v3.v8.legacy_settings")
assert(legacyStore.writeFenced ~= true, "legacy_settings_not_fenced")
assert(legacyStore.dirty == true and legacyStore.lastDirtyReason == "integrity_v2_upgrade", "legacy_upgrade_queued")
assert(P.stats.integrityCompatibilityLoads == 1, "legacy_compat_stat")
assert(P.stats.integrityLoadFailures == 0, "legacy_not_failure")
P:Tick()
assert(storage[legacyKey].__rsmeta.integrityVersion == 4, "legacy_restamped_v4")
assert(P.stats.integrityCompatibilityResaves >= 1, "legacy_resave_stat")

-- Critical stores never use the v1 compatibility escape hatch.
local criticalState = {{ opacity = 0.82, id = 200 }}
assert(P:RegisterV3Store({{
  id = "v3.v8.critical", owner = "v3.v8", scope = P.Scope.Account,
  lifetime = P.Lifetime.Permanent, schemaVersion = 1, legacySchemaVersion = 1,
  key = P.V3KeyPrefix .. "critical", budget = budget, verifyAfterSave = true,
  default = function() return {{ opacity = 1, id = 200 }} end,
  get = function() return copy(criticalState) end,
  apply = function(value) criticalState = copy(value) end,
}}))
local criticalKey = P.V3KeyPrefix .. "critical"
local criticalRaw = {{
  payload = {{ opacity = 0.82, id = 200 }},
  __rsmeta = {{
    framework = 2, store = "v3.v8.critical", owner = "v3.v8",
    contractVersion = 3, lifetime = "Permanent", scope = "Account", schema = 1,
    periodId = "permanent", reliabilityContract = 7, integrityVersion = 1,
  }},
}}
criticalRaw.__rsmeta.encodedFingerprint = assert(P:FingerprintEncodedPayloadV1(criticalRaw, budget))
criticalRaw.__rsmeta.envelopeIntegrityVersion = P.EnvelopeIntegrityContractVersion
criticalRaw.__rsmeta.envelopeFingerprint = assert(P:FingerprintEnvelopeIntegrity(criticalRaw))
storage[criticalKey] = nativeRoundTrip(criticalRaw)
local criticalOk, _, criticalErr = P:LoadStore("v3.v8.critical")
assert(criticalOk == false and string.find(criticalErr or "", "integrity_failed", 1, true), "critical_v1_mismatch_fenced")
assert(P:GetStore("v3.v8.critical").writeFenced == true, "critical_fence")

-- v2 still detects real business corruption. Integer identity changes are exact
-- and cannot be hidden by numeric canonicalization.
local corruptState = {{ opacity = 0.75, id = 300 }}
assert(P:RegisterV3Store({{
  id = "v3.v8.corrupt", owner = "v3.v8", scope = P.Scope.Account,
  lifetime = P.Lifetime.Permanent, schemaVersion = 1, legacySchemaVersion = 1,
  key = P.V3KeyPrefix .. "corrupt", budget = budget,
  default = function() return {{ opacity = 1, id = 300 }} end,
  get = function() return copy(corruptState) end,
  apply = function(value) corruptState = copy(value) end,
}}))
assert(P:LoadStore("v3.v8.corrupt") == "empty", "corrupt_empty")
assert(P:SaveStore("v3.v8.corrupt", {{ durable = true }}) == true, "corrupt_save")
local corruptKey = P.V3KeyPrefix .. "corrupt"
storage[corruptKey].payload.id = 301
local corruptOk, _, corruptErr = P:LoadStore("v3.v8.corrupt")
assert(corruptOk == false and string.find(corruptErr or "", "integrity_failed", 1, true), "v2_corruption_rejected")

local desc = P:Describe()
assert(desc.reliabilityContractVersion >= 8 and desc.integrityContractVersion == 4, "describe_v8")
assert(desc.serializerNumericFingerprintContractVersion == 1, "describe_numeric")
print("PERSISTENCE_RELIABILITY_V8_LUA PASS")
'''
    with tempfile.NamedTemporaryFile("w", suffix=".lua", encoding="utf-8", delete=False) as fh:
        fh.write(script)
        tmp = pathlib.Path(fh.name)
    try:
        proc = subprocess.run([RUNNER, str(tmp)], capture_output=True, text=True)
    finally:
        tmp.unlink(missing_ok=True)
    if proc.returncode != 0:
        raise AssertionError((proc.stdout + proc.stderr).strip())
    if "PERSISTENCE_RELIABILITY_V8_LUA PASS" not in proc.stdout:
        raise AssertionError(proc.stdout.strip() or "missing PASS marker")


def main() -> int:
    source = PERSISTENCE.read_text(encoding="utf-8-sig")
    for token in (
        "ReliabilityContractVersion = 8",
        "IntegrityContractVersion = 4",
        "ContentBlindCanonicalContractVersion = 3",
        "PreCanonicalIntegrityContractVersion = 2",
        "function P:CanonicalIntegrityValue(store, domainValue)",
        "allowIntegrityUpgrade = def.allowIntegrityUpgrade ~= false",
        "LegacyIntegrityContractVersion = 1",
        "SerializerNumericFingerprintContractVersion = 1",
        "function P:FingerprintDurablePayload(value, budget)",
        "function P:FingerprintEncodedPayloadV1(raw, budget)",
        'store.lastIntegrityStatus = "legacy_v1_compatibility"',
        'deferredSaveReason = "integrity_v2_upgrade"',
        "integrityCompatibilityLoads = 0",
        "integrityCompatibilityResaves = 0",
    ):
        if token not in source:
            raise AssertionError("Reliability v8 implementation missing: " + token)
    run_lua()
    print("PERSISTENCE_RELIABILITY_V8_HARNESS PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

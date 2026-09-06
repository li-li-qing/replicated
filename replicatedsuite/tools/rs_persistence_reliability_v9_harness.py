#!/usr/bin/env python3
"""Real-Lua harness for Persistence Reliability v9 (Integrity v3 canonical).

Complements v8 by locking the canonical-verification contract itself:
  1. hook-less stores with a fixed-shape migrate normalizer keep a stable
     canonical fingerprint across representation drift (dropped empty table,
     float renormalization) -- the death_review index shape,
  2. legacy v2 raw-envelope mismatches recover by default (serializer-general
     drift, 2026-09-05 real-machine evidence); stores that explicitly opt OUT
     with allowIntegrityUpgrade=false stay fail-closed,
  3. v3 stamps are written by ordinary saves and verify at the durability
     barrier after the drift,
  4. content corruption under v3 remains fail-closed.
"""
from __future__ import annotations

import pathlib
import subprocess
import tempfile
from rs_lua_runner import RUNNER

ROOT = pathlib.Path(__file__).resolve().parents[1]
PERSISTENCE = ROOT / "core/rs_persistence.lua"

LUA = r'''
local function copy(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {{}}
  if seen[value] ~= nil then return seen[value] end
  local out = {{}}; seen[value] = out
  for k, v in pairs(value) do out[copy(k, seen)] = copy(v, seen) end
  return out
end
local function drift(value, seen)
  -- Non-integral float renormalization plus map->sequence conversion for
  -- string-keyed associative tables, as observed on the RU client.
  if type(value) == "number" then
    if value ~= math.floor(value) then return value + 0.00000002 end
    return value
  end
  if type(value) ~= "table" then return value end
  seen = seen or {{}}
  if seen[value] ~= nil then return seen[value] end
  local out = {{}}; seen[value] = out
  for k, v in pairs(value) do out[drift(k, seen)] = drift(v, seen) end
  return out
end
local storage = {{}}
local now = 9000
ReplicatedSuite = {{
  BootError = nil, BuildTag = "reliability-v9-harness", Generation = 1, SaveKey = "rs_v9_harness",
  NowMs = function() return now end, Api = {{}},
}}
function ReplicatedSuite.Api:SaveData(key, raw) storage[key] = drift(copy(raw)); return true, nil end
function ReplicatedSuite.Api:LoadData(key) return copy(storage[key]), nil end
function ReplicatedSuite.Api:ClearData(key) storage[key] = nil; return true, nil end

dofile([[{PERSISTENCE}]])
local P = ReplicatedSuite.Persistence
assert(P.IntegrityContractVersion == 4, "integrity_v4")
assert(P.ContentBlindCanonicalContractVersion == 3, "content_blind_v3")
local budget = {{ maxDepth = 8, maxNodes = 256, maxStringBytes = 4096, maxEntriesPerTable = 64 }}

-- Hook-less store with a fixed-shape normalize (death_review index shape).
local indexState = {{ settings = {{ autoShow = true, windowMs = 10000 }}, history = {{ serial = 3, entries = {{}} }}, widgetWindow = {{}} }}
assert(P:RegisterV3Store({{
  id = "v3.v9.index", owner = "v3.v9", scope = P.Scope.Account,
  lifetime = P.Lifetime.Permanent, schemaVersion = 1, legacySchemaVersion = 1,
  key = P.V3KeyPrefix .. "index", budget = budget,
  default = function()
    return {{ settings = {{ autoShow = true, windowMs = 10000 }}, history = {{ serial = 0, entries = {{}} }}, widgetWindow = {{}} }}
  end,
  get = function() return copy(indexState) end,
  apply = function(value) indexState = copy(value) end,
  migrate = function(value)
    value = type(value) == "table" and value or {{}}
    local settings = type(value.settings) == "table" and value.settings or {{}}
    local history = type(value.history) == "table" and value.history or {{}}
    return {{
      settings = {{ autoShow = settings.autoShow ~= false, windowMs = math.floor(tonumber(settings.windowMs) or 10000) }},
      history = {{ serial = math.floor(tonumber(history.serial) or 0), entries = type(history.entries) == "table" and history.entries or {{}} }},
      widgetWindow = type(value.widgetWindow) == "table" and value.widgetWindow or {{}},
    }}
  end,
}}))
assert(P:LoadStore("v3.v9.index") == "empty", "index_empty")
indexState.history.serial = 3
indexState.history.entries = {{ {{ serial = 3, storageId = 1 }}, {{ serial = 2, storageId = 2 }} }}
assert(P:SaveStore("v3.v9.index", {{ durable = true }}) == true, "index_save")
local indexKey = P.V3KeyPrefix .. "index"
assert(storage[indexKey].__rsmeta.integrityVersion == 4, "index_v4_stamp")

-- Simulate cross-reload drift: RU drops the empty widgetWindow table and
-- drifts floats. The canonical (normalized) value is unchanged, so the
-- reload verifies.
storage[indexKey].payload.widgetWindow = nil
now = now + 10
local indexOk, _, indexErr = P:LoadStore("v3.v9.index")
assert(indexOk == true, "index_drift_absorbed:" .. tostring(indexErr))
assert(indexState.widgetWindow ~= nil, "normalize_fills_defaults")
assert(indexState.history.entries[1].serial == 3, "entries_intact")
assert(P:GetStore("v3.v9.index").lastIntegrityStatus == "verified_canonical", "verified_canonical")

-- Legacy v2 raw-envelope envelope WITHOUT an explicit flag: since the
-- 2026-09-05 real-machine run proved the drift is serializer-general, the
-- gated upgrade is the DEFAULT and this store RECOVERS (seal + decode +
-- budget validated, then re-stamped canonical v3 at the deferred save).
local unoptedInState = {{ opacity = 0.82, id = 77 }}
assert(P:RegisterV3Store({{
  id = "v3.v9.default_upgrade", owner = "v3.v9", scope = P.Scope.Account,
  lifetime = P.Lifetime.Permanent, schemaVersion = 1, legacySchemaVersion = 1,
  key = P.V3KeyPrefix .. "default_upgrade", budget = budget,
  default = function() return {{ opacity = 1, id = 77 }} end,
  get = function() return copy(unoptedInState) end,
  apply = function(value) unoptedInState = copy(value) end,
}}))
local strictRaw = {{
  payload = {{ opacity = 0.82, id = 77, extra = {{ tag = "x" }} }},
  __rsmeta = {{
    framework = P.FrameworkVersion, store = "v3.v9.default_upgrade", owner = "v3.v9",
    contractVersion = 3, lifetime = "Permanent", scope = "Account", schema = 1,
    periodId = "permanent", reliabilityContract = P.ReliabilityContractVersion,
    integrityVersion = P.PreCanonicalIntegrityContractVersion,
  }},
}}
strictRaw.__rsmeta.encodedFingerprint = assert(P:FingerprintEncodedPayload(strictRaw, budget))
strictRaw.__rsmeta.envelopeIntegrityVersion = P.EnvelopeIntegrityContractVersion
strictRaw.__rsmeta.envelopeFingerprint = assert(P:FingerprintEnvelopeIntegrity(strictRaw))
local strictDrift = copy(strictRaw)
strictDrift.payload.extra = nil -- representation/version drift after stamping
storage[P.V3KeyPrefix .. "default_upgrade"] = drift(strictDrift)
now = now + 10
local strictOk, _, strictErr = P:LoadStore("v3.v9.default_upgrade")
assert(strictOk == true, "default_upgrade_recovers:" .. tostring(strictErr))
assert(P:GetStore("v3.v9.default_upgrade").lastIntegrityStatus == "integrity_upgrade_recovery", "default_upgrade_status")
assert(P.stats.integrityUpgradeRecoveries >= 1, "default_upgrade_counted")

-- Explicit opt-out keeps absolute fail-closed legacy handling for domains that
-- request it: representation drift still fences the Store.
local optOutState = {{ opacity = 0.82, id = 78 }}
assert(P:RegisterV3Store({{
  id = "v3.v9.strict", owner = "v3.v9", scope = P.Scope.Account,
  lifetime = P.Lifetime.Permanent, schemaVersion = 1, legacySchemaVersion = 1,
  key = P.V3KeyPrefix .. "strict", budget = budget,
  allowIntegrityUpgrade = false,
  default = function() return {{ opacity = 1, id = 78 }} end,
  get = function() return copy(optOutState) end,
  apply = function(value) optOutState = copy(value) end,
}}))
local optOutRaw = {{
  payload = {{ opacity = 0.82, id = 78, extra = {{ tag = "x" }} }},
  __rsmeta = {{
    framework = P.FrameworkVersion, store = "v3.v9.strict", owner = "v3.v9",
    contractVersion = 3, lifetime = "Permanent", scope = "Account", schema = 1,
    periodId = "permanent", reliabilityContract = P.ReliabilityContractVersion,
    integrityVersion = P.PreCanonicalIntegrityContractVersion,
  }},
}}
optOutRaw.__rsmeta.encodedFingerprint = assert(P:FingerprintEncodedPayload(optOutRaw, budget))
optOutRaw.__rsmeta.envelopeIntegrityVersion = P.EnvelopeIntegrityContractVersion
optOutRaw.__rsmeta.envelopeFingerprint = assert(P:FingerprintEnvelopeIntegrity(optOutRaw))
local optOutDrift = copy(optOutRaw)
optOutDrift.payload.extra = nil
storage[P.V3KeyPrefix .. "strict"] = drift(optOutDrift)
now = now + 10
local optOutOk, _, optOutErr = P:LoadStore("v3.v9.strict")
assert(optOutOk == false and string.find(optOutErr or "", "integrity_failed", 1, true), "optout_fenced")
assert(P:GetStore("v3.v9.strict").writeFenced == true, "optout_fenced_flag")

-- Content-blind v3 stamp recovery (the real bonds/trade scenario): a v3-era
-- envelope whose fingerprint was derived from the DEFAULT table shape (the
-- broken `migrate = default` canonical) carries no integrity evidence. The
-- repaired canonical function hashes REAL content, so the stale stamp cannot
-- verify -- the contract-upgrade gate recovers it through the seal + full
-- business validation and re-stamps v4.
local blindState = {{ settings = {{ autoShow = true, windowMs = 8000 }}, history = {{ serial = 1, entries = {{}} }}, widgetWindow = {{}} }}
assert(P:RegisterV3Store({{
  id = "v3.v9.blind", owner = "v3.v9", scope = P.Scope.Account,
  lifetime = P.Lifetime.Permanent, schemaVersion = 1, legacySchemaVersion = 1,
  key = P.V3KeyPrefix .. "blind", budget = budget,
  default = function()
    return {{ settings = {{ autoShow = true, windowMs = 10000 }}, history = {{ serial = 0, entries = {{}} }}, widgetWindow = {{}} }}
  end,
  get = function() return copy(blindState) end,
  apply = function(value) blindState = copy(value) end,
  migrate = function(value)
    value = type(value) == "table" and value or {{}}
    local settings = type(value.settings) == "table" and value.settings or {{}}
    local history = type(value.history) == "table" and value.history or {{}}
    return {{
      settings = {{ autoShow = settings.autoShow ~= false, windowMs = math.floor(tonumber(settings.windowMs) or 10000) }},
      history = {{ serial = math.floor(tonumber(history.serial) or 0), entries = type(history.entries) == "table" and history.entries or {{}} }},
      widgetWindow = type(value.widgetWindow) == "table" and value.widgetWindow or {{}},
    }}
  end,
}}))
local blindRaw = {{
  payload = {{ settings = {{ autoShow = true, windowMs = 8000 }}, history = {{ serial = 5, entries = {{ {{ serial = 5, storageId = 1 }} }} }}, widgetWindow = {{ x = 12 }} }},
  __rsmeta = {{
    framework = P.FrameworkVersion, store = "v3.v9.blind", owner = "v3.v9",
    contractVersion = 3, lifetime = "Permanent", scope = "Account", schema = 1,
    periodId = "permanent", reliabilityContract = P.ReliabilityContractVersion,
    integrityVersion = P.ContentBlindCanonicalContractVersion,
  }},
}}
-- Stamp = hash of the DEFAULT shape (content-blind era), NOT the content.
blindRaw.__rsmeta.encodedFingerprint = assert(P:FingerprintDurablePayload(P:CanonicalIntegrityValue(assert(P:GetStore("v3.v9.blind")), {{}}), budget))
blindRaw.__rsmeta.envelopeIntegrityVersion = P.EnvelopeIntegrityContractVersion
blindRaw.__rsmeta.envelopeFingerprint = assert(P:FingerprintEnvelopeIntegrity(blindRaw))
storage[P.V3KeyPrefix .. "blind"] = drift(blindRaw)
now = now + 10
local blindOk, _, blindErr = P:LoadStore("v3.v9.blind")
assert(blindOk == true, "blind_v3_recovers:" .. tostring(blindErr))
assert(P:GetStore("v3.v9.blind").lastIntegrityStatus == "integrity_contract_upgrade_recovery", "blind_recovery_status")
assert(blindState.history.serial == 5, "blind_content_intact")
assert(blindState.settings.windowMs == 8000, "blind_real_content_applied")
assert(P.stats.integrityUpgradeRecoveries >= 1, "blind_recovery_counted")
now = now + 10
P:Tick()
assert(P:Flush() == true, "blind_flush")
assert(storage[P.V3KeyPrefix .. "blind"].__rsmeta.integrityVersion == 4, "blind_restamped_v4")
now = now + 10
local blindReload = P:LoadStore("v3.v9.blind")
assert(blindReload == true, "blind_v4_reload_verifies:")

-- v3 content corruption stays fail-closed.
local corruptState = {{ value = 12 }}
assert(P:RegisterV3Store({{
  id = "v3.v9.corrupt", owner = "v3.v9", scope = P.Scope.Account,
  lifetime = P.Lifetime.Permanent, schemaVersion = 1, legacySchemaVersion = 1,
  key = P.V3KeyPrefix .. "corrupt", budget = budget,
  default = function() return {{ value = 0 }} end,
  get = function() return copy(corruptState) end,
  apply = function(value) corruptState = copy(value) end,
}}))
assert(P:LoadStore("v3.v9.corrupt") == "empty", "corrupt_empty")
corruptState.value = 12
assert(P:SaveStore("v3.v9.corrupt", {{ durable = true }}) == true, "corrupt_save")
local corruptKey = P.V3KeyPrefix .. "corrupt"
storage[corruptKey].payload.value = 13
now = now + 10
local corruptOk, _, corruptErr = P:LoadStore("v3.v9.corrupt")
assert(corruptOk == false and string.find(corruptErr or "", "integrity_failed", 1, true), "v3_corruption_fenced")
assert(corruptState.value == 12, "v3_corruption_never_applied")

local desc = P:Describe()
assert(desc.integrityContractVersion == 4, "describe_v9")
print("PERSISTENCE_RELIABILITY_V9_LUA PASS")
'''.replace("{PERSISTENCE}", str(PERSISTENCE.as_posix())).replace("{{", "{").replace("}}", "}")


def main() -> int:
    source = PERSISTENCE.read_text(encoding="utf-8-sig")
    for token in (
        "IntegrityContractVersion = 4",
        "ContentBlindCanonicalContractVersion = 3",
        "PreCanonicalIntegrityContractVersion = 2",
        "function P:CanonicalIntegrityValue(store, domainValue)",
        "function P:FingerprintCanonicalValue(store, canonical, budget)",
        'store.lastIntegrityStatus = "integrity_upgrade_recovery"',
        'deferredSaveReason = "integrity_v4_upgrade"',
        "integrityUpgradeRecoveries = 0",
        "integrityUpgradeResaves = 0",
        "allowIntegrityUpgrade = def.allowIntegrityUpgrade ~= false",
    ):
        if token not in source:
            raise AssertionError("Reliability v9 implementation missing: " + token)
    if RUNNER is None:
        print("PERSISTENCE_RELIABILITY_V9_HARNESS SKIP | lua runner unavailable")
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
    if "PERSISTENCE_RELIABILITY_V9_LUA PASS" not in proc.stdout:
        raise AssertionError(proc.stdout.strip() or "missing PASS marker")
    print("PERSISTENCE_RELIABILITY_V9_HARNESS PASS")


if __name__ == "__main__":
    raise SystemExit(main())

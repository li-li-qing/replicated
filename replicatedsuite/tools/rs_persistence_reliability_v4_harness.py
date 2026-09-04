#!/usr/bin/env python3
"""Real-Lua fault-injection harness for Persistence Reliability v4.

Covers persisted cross-reload fingerprints, encoded-load preflight, healthy
IsStoreLoaded semantics, backward-compatible unstamped loads, and verified
replacement recovery for journal shards. No RU client is required.
"""
from __future__ import annotations

import pathlib
import subprocess
import tempfile

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

local storage = {{}}
local loadCalls = 0
ReplicatedSuite = {{
  BootError = nil,
  BuildTag = "reliability-v4-harness",
  Generation = 1,
  SaveKey = "rs_harness",
  NowMs = function() return 45678 end,
  Api = {{}},
}}
function ReplicatedSuite.Api:SaveData(key, raw)
  storage[key] = copy(raw)
  return true, nil
end
function ReplicatedSuite.Api:LoadData(key)
  loadCalls = loadCalls + 1
  return copy(storage[key]), nil
end
function ReplicatedSuite.Api:ClearData(key)
  storage[key] = nil
  return true, nil
end

dofile([[{PERSISTENCE.as_posix()}]])
local P = ReplicatedSuite.Persistence
assert(P.ReliabilityContractVersion >= 4, "contract")
assert(P.IntegrityContractVersion == 1, "integrity_contract")
local budget = {{ maxDepth = 8, maxNodes = 256, maxStringBytes = 4096, maxEntriesPerTable = 64 }}

-- Ordinary stores get a persisted integrity stamp without opt-in readback I/O.
local ordinary = {{ value = 1, nested = {{ a = "A", b = "B" }} }}
assert(P:RegisterV3Store({{
  id = "v3.harness.ordinary", owner = "v3.harness", scope = P.Scope.Account,
  lifetime = P.Lifetime.Permanent, schemaVersion = 1, legacySchemaVersion = 1,
  key = P.V3KeyPrefix .. "ordinary", budget = budget,
  default = function() return {{ value = 0 }} end,
  get = function() return copy(ordinary) end,
  apply = function(value) ordinary = copy(value) end,
}}))
assert(P:LoadStore("v3.harness.ordinary") == "empty", "ordinary_empty")
ordinary = {{ value = 2, nested = {{ a = "A", b = "B" }} }}
local beforeSaveLoads = loadCalls
assert(P:SaveStore("v3.harness.ordinary") == true, "ordinary_save")
assert(loadCalls == beforeSaveLoads, "ordinary_no_readback")
local ordinaryKey = P.V3KeyPrefix .. "ordinary"
assert(type(storage[ordinaryKey].__rsmeta) == "table", "ordinary_meta")
assert(storage[ordinaryKey].__rsmeta.integrityVersion == 1, "ordinary_integrity_version")
assert(storage[ordinaryKey].__rsmeta.reliabilityContract == P.ReliabilityContractVersion, "ordinary_reliability_contract")
assert(type(storage[ordinaryKey].__rsmeta.encodedFingerprint) == "string", "ordinary_fingerprint")
assert(P:Flush() == true, "ordinary_barrier_before_cross_reload")

-- Simulate a later-process field truncation while leaving metadata intact.
storage[ordinaryKey].payload.nested = nil
local reloadOk, _, reloadErr = P:LoadStore("v3.harness.ordinary")
assert(reloadOk == false and string.find(reloadErr or "", "integrity_failed", 1, true), "cross_reload_corruption_rejected")
local ordinaryReady, ordinaryStatus = P:IsStoreLoaded("v3.harness.ordinary")
assert(ordinaryReady == false and ordinaryStatus == "integrity_failed", "failed_load_not_ready")
assert(P.stats.integrityLoadFailures == 1, "integrity_failure_stat")

-- Pre-v4 metadata remains readable so upgrades do not discard existing config.
local legacyState = {{}}
assert(P:RegisterV3Store({{
  id = "v3.harness.legacy", owner = "v3.harness", scope = P.Scope.Account,
  lifetime = P.Lifetime.Permanent, schemaVersion = 1, legacySchemaVersion = 1,
  key = P.V3KeyPrefix .. "legacy", budget = budget,
  default = function() return {{}} end,
  get = function() return copy(legacyState) end,
  apply = function(value) legacyState = copy(value) end,
}}))
local legacyKey = P.V3KeyPrefix .. "legacy"
storage[legacyKey] = {{
  payload = {{ kept = "yes" }},
  __rsmeta = {{ framework = P.FrameworkVersion, store = "v3.harness.legacy", owner = "v3.harness",
    contractVersion = 3, lifetime = "Permanent", scope = "Account", schema = 1, periodId = "permanent" }},
}}
assert(P:LoadStore("v3.harness.legacy") == true, "legacy_unstamped_load")
assert(legacyState.kept == "yes", "legacy_value_applied")
assert(P.stats.integrityLegacyLoads >= 1, "legacy_integrity_stat")

-- A malformed encoded table is rejected before Domain decode/apply.
local malformedState = {{}}
assert(P:RegisterV3Store({{
  id = "v3.harness.malformed", owner = "v3.harness", scope = P.Scope.Account,
  lifetime = P.Lifetime.Permanent, schemaVersion = 1, legacySchemaVersion = 1,
  key = P.V3KeyPrefix .. "malformed", budget = budget,
  default = function() return {{}} end,
  get = function() return copy(malformedState) end,
  apply = function(value) malformedState = copy(value) end,
}}))
local malformedKey = P.V3KeyPrefix .. "malformed"
local cyclic = {{ payload = {{ value = 1 }} }}
cyclic.self = cyclic
storage[malformedKey] = cyclic
local malformedOk = P:LoadStore("v3.harness.malformed")
assert(malformedOk == false, "encoded_load_rejected")
local malformedReady, malformedStatus = P:IsStoreLoaded("v3.harness.malformed")
assert(malformedReady == false and malformedStatus == "encoded_load_rejected", "encoded_reject_not_ready")
assert(P.stats.encodedLoadRejects == 1, "encoded_load_reject_stat")

-- Journal shards can repair a corrupt INACTIVE copy only through a verified
-- full replacement. The fence remains intact until readback succeeds.
local shard = {{ revision = 1, data = {{ x = "good" }} }}
assert(P:RegisterV3Store({{
  id = "v3.harness.shard", owner = "v3.harness", scope = P.Scope.Account,
  lifetime = P.Lifetime.Permanent, schemaVersion = 1, legacySchemaVersion = 1,
  key = P.V3KeyPrefix .. "shard", budget = budget, verifyAfterSave = true,
  recoverableReplacement = true,
  default = function() return {{ revision = 0, data = {{}} }} end,
  get = function() return copy(shard) end,
  apply = function(value) shard = copy(value) end,
}}))
assert(P:LoadStore("v3.harness.shard") == "empty", "shard_empty")
assert(P:SaveStore("v3.harness.shard") == true, "shard_seed")
local shardKey = P.V3KeyPrefix .. "shard"
storage[shardKey].payload.data = nil
local shardLoad, _, shardErr = P:LoadStore("v3.harness.shard")
assert(shardLoad == false and string.find(shardErr or "", "integrity_failed", 1, true), "shard_corrupt_detected")
local shardStore = P:GetStore("v3.harness.shard")
assert(shardStore.writeFenced == true, "shard_fenced")
shard = {{ revision = 2, data = {{ x = "repaired" }} }}
local repairOk, repairErr = P:SaveStore("v3.harness.shard", {{ replaceCorrupt = true, verifyAfterSave = true, reason = "repair" }})
assert(repairOk == true and repairErr == nil, "verified_replacement")
assert(shardStore.writeFenced == false and shardStore.loadStatus == "saved", "replacement_clears_fence")
local shardReady = P:IsStoreLoaded("v3.harness.shard")
assert(shardReady == true, "replacement_ready")
assert(P.stats.verifiedReplacementRecoveries == 1, "replacement_stat")

local desc = P:Describe()
assert(desc.reliabilityContractVersion >= 4 and desc.integrityContractVersion == 1, "describe_contract")
print("PERSISTENCE_RELIABILITY_V4_LUA PASS 25/25")
'''
    with tempfile.NamedTemporaryFile("w", suffix=".lua", encoding="utf-8", delete=False) as fh:
        fh.write(script)
        tmp = pathlib.Path(fh.name)
    try:
        proc = subprocess.run(["texlua", str(tmp)], capture_output=True, text=True)
    finally:
        tmp.unlink(missing_ok=True)
    if proc.returncode != 0:
        raise AssertionError((proc.stdout + proc.stderr).strip())
    if "PERSISTENCE_RELIABILITY_V4_LUA PASS 25/25" not in proc.stdout:
        raise AssertionError(proc.stdout.strip() or "missing PASS marker")


def main() -> int:
    source = PERSISTENCE.read_text(encoding="utf-8-sig")
    for token in (
        "ReliabilityContractVersion = 7",
        "IntegrityContractVersion = 1",
        "raw.__rsmeta.reliabilityContract = self.ReliabilityContractVersion",
        "raw.__rsmeta.encodedFingerprint = encodedFingerprint",
        "FingerprintEncodedPayload",
        'store.loadStatus = "integrity_failed"',
        'store.loadStatus = "encoded_load_rejected"',
        "recoverableReplacement = def.recoverableReplacement == true",
        "replaceCorrupt == true",
        "verifiedReplacementRecoveries = 0",
    ):
        if token not in source:
            raise AssertionError("Reliability v4 implementation missing: " + token)
    run_lua()
    print("PERSISTENCE_RELIABILITY_V4_HARNESS PASS 35/35")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

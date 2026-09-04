#!/usr/bin/env python3
"""Real-Lua fault-injection harness for Persistence Reliability v5.

Covers v4->v5 integrity compatibility, pre-decode corruption rejection,
Reload/Stop durability-barrier verification for ordinary stores, no duplicate
barrier I/O for critical readback stores, and verified ClearData semantics.
No RU client is required.
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
local fakeClearSuccess = false
ReplicatedSuite = {{
  BootError = nil,
  BuildTag = "reliability-v5-harness",
  Generation = 1,
  SaveKey = "rs_harness_v5",
  NowMs = function() return 56789 end,
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
  if fakeClearSuccess ~= true then storage[key] = nil end
  return true, nil
end

dofile([[{PERSISTENCE.as_posix()}]])
local P = ReplicatedSuite.Persistence
assert(P.ReliabilityContractVersion >= 5, "contract")
assert(P.MinIntegrityReliabilityContractVersion == 4, "compat_floor")
assert(P.IntegrityContractVersion == 1, "integrity_contract")
local budget = {{ maxDepth = 8, maxNodes = 256, maxStringBytes = 4096, maxEntriesPerTable = 64 }}

-- v4-stamped data must remain readable after the runtime contract advances.
local compatState = {{}}
assert(P:RegisterV3Store({{
  id = "v3.v5.compat", owner = "v3.v5", scope = P.Scope.Account,
  lifetime = P.Lifetime.Permanent, schemaVersion = 1, legacySchemaVersion = 1,
  key = P.V3KeyPrefix .. "compat", budget = budget,
  default = function() return {{ value = 0 }} end,
  get = function() return copy(compatState) end,
  apply = function(value) compatState = copy(value) end,
}}))
assert(P:LoadStore("v3.v5.compat") == "empty", "compat_empty")
compatState = {{ value = 44 }}
assert(P:SaveStore("v3.v5.compat") == true, "compat_seed")
local compatKey = P.V3KeyPrefix .. "compat"
assert(P:Flush() == true, "compat_barrier_before_cross_reload")
storage[compatKey].__rsmeta.reliabilityContract = 4
storage[compatKey].__rsmeta.envelopeIntegrityVersion = nil
storage[compatKey].__rsmeta.envelopeFingerprint = nil
storage[compatKey].__rsmeta.scopeBindingContract = nil
storage[compatKey].__rsmeta.scopeIdentityFingerprint = nil
assert(P:LoadStore("v3.v5.compat") == true, "v4_stamp_loads_under_v5")
assert(compatState.value == 44, "v4_value_applied")

-- Integrity must reject a corrupted v5 envelope before custom decode executes.
local decodeCalls = 0
local decodeState = {{}}
assert(P:RegisterV3Store({{
  id = "v3.v5.predecode", owner = "v3.v5", scope = P.Scope.Account,
  lifetime = P.Lifetime.Permanent, schemaVersion = 1, legacySchemaVersion = 1,
  key = P.V3KeyPrefix .. "predecode", budget = budget,
  default = function() return {{ value = 0, nested = {{ keep = true }} }} end,
  get = function() return copy(decodeState) end,
  apply = function(value) decodeState = copy(value) end,
  decode = function(raw)
    decodeCalls = decodeCalls + 1
    return copy(raw.payload)
  end,
}}))
assert(P:LoadStore("v3.v5.predecode") == "empty", "predecode_empty")
decodeState = {{ value = 5, nested = {{ keep = true }} }}
assert(P:SaveStore("v3.v5.predecode") == true, "predecode_seed")
local predecodeKey = P.V3KeyPrefix .. "predecode"
assert(P:Flush() == true, "predecode_barrier_before_cross_reload")
local decodeBeforeCorruptLoad = decodeCalls
storage[predecodeKey].payload.nested = nil
local corruptOk, _, corruptErr = P:LoadStore("v3.v5.predecode")
assert(corruptOk == false and string.find(corruptErr or "", "integrity_failed", 1, true), "corrupt_rejected")
assert(decodeCalls == decodeBeforeCorruptLoad, "decoder_not_called_before_integrity")

-- Ordinary saves stay one-write/no-read in the hot path, but Flush is now a
-- hard durability barrier. A silently truncated physical write blocks reload,
-- requeues the current Domain snapshot, and a subsequent Flush can repair it.
local ordinary = {{}}
assert(P:RegisterV3Store({{
  id = "v3.v5.ordinary", owner = "v3.v5.ordinary_owner", scope = P.Scope.Account,
  lifetime = P.Lifetime.Permanent, schemaVersion = 1, legacySchemaVersion = 1,
  key = P.V3KeyPrefix .. "ordinary", budget = budget,
  default = function() return {{ value = 0 }} end,
  get = function() return copy(ordinary) end,
  apply = function(value) ordinary = copy(value) end,
}}))
assert(P:LoadStore("v3.v5.ordinary") == "empty", "ordinary_empty")
ordinary = {{ value = 9, nested = {{ x = "safe" }} }}
local beforeOrdinarySaveLoads = loadCalls
assert(P:SaveStore("v3.v5.ordinary") == true, "ordinary_save")
assert(loadCalls == beforeOrdinarySaveLoads, "ordinary_save_no_immediate_readback")
local ordinaryStore = P:GetStore("v3.v5.ordinary")
assert(ordinaryStore.needsBarrierVerify == true, "ordinary_barrier_pending")
local ordinaryKey = P.V3KeyPrefix .. "ordinary"
storage[ordinaryKey].payload.nested = nil
local flush1, failures1 = P:Flush("v3.v5.ordinary_owner")
assert(flush1 == false and #failures1 >= 1, "barrier_detects_truncation")
assert(ordinaryStore.dirty == true, "barrier_requeues_domain")
assert(ordinaryStore.needsBarrierVerify == true, "barrier_stays_pending")
assert(P.stats.barrierVerifyFailures >= 1 and P.stats.barrierVerifyRequeued >= 1, "barrier_failure_stats")
local flush2, failures2 = P:Flush("v3.v5.ordinary_owner")
assert(flush2 == true and #failures2 == 0, "barrier_rewrite_recovers")
assert(ordinaryStore.dirty == false and ordinaryStore.needsBarrierVerify == false, "barrier_recovery_clean")
assert(P.stats.barrierVerifySuccesses >= 1, "barrier_success_stat")

-- Critical stores prove the write immediately and therefore must not receive a
-- duplicate barrier LoadData at Flush.
local critical = {{}}
assert(P:RegisterV3Store({{
  id = "v3.v5.critical", owner = "v3.v5.critical_owner", scope = P.Scope.Account,
  lifetime = P.Lifetime.Permanent, schemaVersion = 1, legacySchemaVersion = 1,
  key = P.V3KeyPrefix .. "critical", budget = budget, verifyAfterSave = true,
  default = function() return {{ value = 0 }} end,
  get = function() return copy(critical) end,
  apply = function(value) critical = copy(value) end,
}}))
assert(P:LoadStore("v3.v5.critical") == "empty", "critical_empty")
critical = {{ value = 7 }}
local beforeCriticalSaveLoads = loadCalls
assert(P:SaveStore("v3.v5.critical") == true, "critical_save")
assert(loadCalls == beforeCriticalSaveLoads + 1, "critical_immediate_readback")
local criticalStore = P:GetStore("v3.v5.critical")
assert(criticalStore.needsBarrierVerify == false, "critical_no_barrier_pending")
local beforeCriticalFlushLoads = loadCalls
assert(P:Flush("v3.v5.critical_owner") == true, "critical_flush")
assert(loadCalls == beforeCriticalFlushLoads, "critical_no_duplicate_flush_readback")

-- A fake-success ClearData must not apply defaults in-memory. Only a verified
-- physical nil may transition the Domain to its default/empty state.
local clearState = {{}}
assert(P:RegisterV3Store({{
  id = "v3.v5.clear", owner = "v3.clear", scope = P.Scope.Account,
  lifetime = P.Lifetime.Permanent, schemaVersion = 1, legacySchemaVersion = 1,
  key = P.V3KeyPrefix .. "clear", budget = budget,
  default = function() return {{ value = "default" }} end,
  get = function() return copy(clearState) end,
  apply = function(value) clearState = copy(value) end,
}}))
assert(P:LoadStore("v3.v5.clear") == "empty", "clear_empty")
clearState = {{ value = "kept" }}
assert(P:SaveStore("v3.v5.clear") == true, "clear_seed")
fakeClearSuccess = true
local clearBad, clearBadErr = P:ClearStore("v3.v5.clear")
assert(clearBad == false and string.find(clearBadErr or "", "clear_verify", 1, true), "fake_clear_rejected")
assert(clearState.value == "kept", "fake_clear_preserves_domain")
local clearReady, clearStatus = P:IsStoreLoaded("v3.v5.clear")
assert(clearReady == false and clearStatus == "clear_verify_failed", "fake_clear_not_ready")
fakeClearSuccess = false
assert(P:ClearStore("v3.v5.clear") == true, "verified_clear")
assert(clearState.value == "default", "verified_clear_applies_default")
assert(P.stats.clearVerifyAttempts == 2 and P.stats.clearVerifyFailures == 1, "clear_verify_stats")

local desc = P:Describe()
assert(desc.reliabilityContractVersion >= 5 and desc.integrityContractVersion == 1, "describe_contract")
assert(type(desc.lastFlush) == "table" and desc.lastFlush.ok == true, "last_flush_diagnostics")
print("PERSISTENCE_RELIABILITY_V5_LUA PASS 33/33")
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
    if "PERSISTENCE_RELIABILITY_V5_LUA PASS 33/33" not in proc.stdout:
        raise AssertionError(proc.stdout.strip() or "missing PASS marker")


def main() -> int:
    source = PERSISTENCE.read_text(encoding="utf-8-sig")
    for token in (
        "ReliabilityContractVersion = 7",
        "MinIntegrityReliabilityContractVersion = 4",
        "needsBarrierVerify = false",
        "barrierVerifyAttempts = 0",
        "clearVerifyAttempts = 0",
        "durability_barrier_verify_failed",
        'store.loadStatus = "clear_verify_failed"',
        "FingerprintEncodedPayload(raw, store.encodedBudget)",
        "performs verification BEFORE any custom decoder",
    ):
        if token not in source:
            raise AssertionError("Reliability v5 implementation missing: " + token)
    run_lua()
    print("PERSISTENCE_RELIABILITY_V5_HARNESS PASS 42/42")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

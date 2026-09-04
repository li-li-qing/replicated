#!/usr/bin/env python3
"""Real-Lua fault-injection harness for Persistence Reliability v3.

Covers the critical-store post-write readback contract without requiring the RU
client: successful roundtrip, silent SaveData truncation detection, decode-only
verification (no second Domain apply), and ordinary opt-out stores avoiding the
extra LoadData read.
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
local truncateNext = false
ReplicatedSuite = {{
  BootError = nil,
  BuildTag = "reliability-v3-harness",
  Generation = 1,
  SaveKey = "rs_harness",
  NowMs = function() return 12345 end,
  Api = {{}},
}}
function ReplicatedSuite.Api:SaveData(key, raw)
  local saved = copy(raw)
  if truncateNext == true then
    truncateNext = false
    if type(saved.payload) == "table" then saved.payload.nested = nil end
  end
  storage[key] = saved
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
assert(P.ReliabilityContractVersion >= 3, "contract")
assert(type(P.VerifyPersistedValue) == "function", "verify_fn")
local budget = {{ maxDepth = 8, maxNodes = 128, maxStringBytes = 4096, maxEntriesPerTable = 64 }}

local criticalState = {{ value = 1, nested = {{ a = "A", b = "B" }} }}
local applyCount = 0
assert(P:RegisterV3Store({{
  id = "v3.harness.critical", owner = "v3.harness", scope = P.Scope.Account,
  lifetime = P.Lifetime.Permanent, schemaVersion = 1, legacySchemaVersion = 1,
  key = P.V3KeyPrefix .. "harness_critical", budget = budget, verifyAfterSave = true,
  default = function() return {{ value = 0, nested = {{}} }} end,
  get = function() return copy(criticalState) end,
  apply = function(value) criticalState = copy(value); applyCount = applyCount + 1 end,
}}))
local status = P:LoadStore("v3.harness.critical")
assert(status == "empty", "critical_load_empty")
criticalState = {{ value = 1, nested = {{ a = "A", b = "B" }} }}
local beforeApply = applyCount
local ok, err = P:SaveStore("v3.harness.critical")
assert(ok == true and err == nil, "critical_save_verified")
assert(applyCount == beforeApply, "verify_decode_only")
assert(P.stats.readbackVerifyAttempts == 1 and P.stats.readbackVerifySuccesses == 1 and P.stats.readbackVerifyFailures == 0, "verify_stats_success")
local criticalStore = P:GetStore("v3.harness.critical")
assert(criticalStore.lastVerifyOk == true and criticalStore.lastVerifyFingerprint ~= nil, "verify_store_success")

criticalState = {{ value = 2, nested = {{ a = "A", b = "B", c = "C" }} }}
truncateNext = true
local failed, failedErr = P:SaveStore("v3.harness.critical")
assert(failed == false and string.find(failedErr or "", "readback_verify_failed", 1, true), "silent_truncation_rejected")
assert(P.stats.readbackVerifyAttempts == 2 and P.stats.readbackVerifySuccesses == 1 and P.stats.readbackVerifyFailures == 1, "verify_stats_failure")
assert(criticalStore.lastVerifyOk == false and criticalStore.lastVerifyError ~= nil, "verify_store_failure")
assert(P.stats.saves == 1, "failed_verify_not_committed")

local ordinaryState = {{ value = 5 }}
assert(P:RegisterV3Store({{
  id = "v3.harness.ordinary", owner = "v3.harness", scope = P.Scope.Account,
  lifetime = P.Lifetime.Permanent, schemaVersion = 1, legacySchemaVersion = 1,
  key = P.V3KeyPrefix .. "harness_ordinary", budget = budget,
  default = function() return {{ value = 0 }} end,
  get = function() return copy(ordinaryState) end,
  apply = function(value) ordinaryState = copy(value) end,
}}))
local ordinaryLoad = P:LoadStore("v3.harness.ordinary")
assert(ordinaryLoad == "empty", "ordinary_load_empty")
ordinaryState = {{ value = 6 }}
local loadBeforeOrdinarySave = loadCalls
assert(P:SaveStore("v3.harness.ordinary") == true, "ordinary_save")
assert(loadCalls == loadBeforeOrdinarySave, "ordinary_no_readback")

local desc = P:Describe()
assert(desc.reliabilityContractVersion >= 3, "describe_contract")
assert(desc.stats.readbackVerifyFailures == 1, "describe_stats")
print("PERSISTENCE_RELIABILITY_V3_LUA PASS 15/15")
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
    if "PERSISTENCE_RELIABILITY_V3_LUA PASS 15/15" not in proc.stdout:
        raise AssertionError(proc.stdout.strip() or "missing PASS marker")


def main() -> int:
    source = PERSISTENCE.read_text(encoding="utf-8-sig")
    for token in (
        "ReliabilityContractVersion = 7",
        "function P:VerifyPersistedValue(storeOrId, expectedValue, resolvedKey)",
        "readbackVerifyAttempts = 0",
        "readbackVerifySuccesses = 0",
        "readbackVerifyFailures = 0",
        "verifyAfterSave = def.verifyAfterSave == true",
        "readback_verify_failed:",
    ):
        if token not in source:
            raise AssertionError("Reliability v3 implementation missing: " + token)
    run_lua()
    print("PERSISTENCE_RELIABILITY_V3_HARNESS PASS 22/22")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

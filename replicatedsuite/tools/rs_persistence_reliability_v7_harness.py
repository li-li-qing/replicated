#!/usr/bin/env python3
"""Real-Lua fault-injection harness for Persistence Reliability v7.

Covers generation-local unverified-write reload fencing, migration/apply dirty
commit ordering, and suppression of terminal/fenced debounce save storms.
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

local now = 1000
local storage = {{}}
local saveCalls = 0
ReplicatedSuite = {{
  BootError = nil,
  BuildTag = "reliability-v7-harness",
  Generation = 1,
  SaveKey = "rs_harness_v7",
  NowMs = function() return now end,
  Api = {{}},
}}
function ReplicatedSuite.Api:SaveData(key, raw)
  saveCalls = saveCalls + 1
  storage[key] = copy(raw)
  return true, nil
end
function ReplicatedSuite.Api:LoadData(key) return copy(storage[key]), nil end
function ReplicatedSuite.Api:ClearData(key) storage[key] = nil; return true, nil end

dofile([[{PERSISTENCE.as_posix()}]])
local P = ReplicatedSuite.Persistence
assert(P.ReliabilityContractVersion == 7, "contract")
local budget = {{ maxDepth = 8, maxNodes = 128, maxStringBytes = 4096, maxEntriesPerTable = 64 }}

-- Ordinary one-write saves are healthy Domain state but not durability proof.
-- LoadStore must not re-apply disk state until Flush verifies that write.
local reloadState = {{ value = "default" }}
assert(P:RegisterV3Store({{
  id = "v3.v7.reload_fence", owner = "v3.v7", scope = P.Scope.Account,
  lifetime = P.Lifetime.Permanent, schemaVersion = 1, legacySchemaVersion = 1,
  key = P.V3KeyPrefix .. "reload_fence", budget = budget,
  default = function() return {{ value = "default" }} end,
  get = function() return copy(reloadState) end,
  apply = function(value) reloadState = copy(value) end,
}}))
assert(P:LoadStore("v3.v7.reload_fence") == "empty", "reload_empty")
reloadState.value = "newer-domain"
assert(P:SaveStore("v3.v7.reload_fence") == true, "reload_save")
assert(P:GetStore("v3.v7.reload_fence").needsBarrierVerify == true, "reload_pending")
local key = P.V3KeyPrefix .. "reload_fence"
local savedRaw = copy(storage[key])
storage[key].payload.value = "older-disk"
local blocked, _, blockedErr = P:LoadStore("v3.v7.reload_fence")
assert(blocked == false and blockedErr == "unverified store reload rejected", "pending_reload_fenced")
assert(reloadState.value == "newer-domain", "pending_reload_keeps_domain")
assert(P.stats.unverifiedReloadRejects >= 1, "pending_reload_stat")
storage[key] = savedRaw
assert(P:Flush() == true, "pending_flush_verifies")
assert(P:GetStore("v3.v7.reload_fence").needsBarrierVerify == false, "pending_cleared")
assert(P:LoadStore("v3.v7.reload_fence") == true and reloadState.value == "newer-domain", "post_barrier_reload")

-- Migration dirty intent is committed only after apply succeeds. A failed apply
-- must not leave a terminal Store dirty and accidentally queue disk writes.
local migrationState = {{ value = 0 }}
local migrationKey = P.V3KeyPrefix .. "migration_apply_fail"
storage[migrationKey] = {{
  payload = {{ value = 7 }},
  __rsmeta = {{ framework = P.FrameworkVersion, store = "v3.v7.migration_apply_fail", owner = "v3.v7",
    contractVersion = 3, lifetime = P.Lifetime.Permanent, scope = P.Scope.Account, schema = 1 }}
}}
assert(P:RegisterV3Store({{
  id = "v3.v7.migration_apply_fail", owner = "v3.v7", scope = P.Scope.Account,
  lifetime = P.Lifetime.Permanent, schemaVersion = 2, legacySchemaVersion = 1,
  key = migrationKey, budget = budget,
  default = function() return {{ value = 0 }} end,
  get = function() return copy(migrationState) end,
  migrate = function(value) value.value = value.value + 1; return value end,
  apply = function(_value) error("apply boom") end,
}}))
local migratedOk = P:LoadStore("v3.v7.migration_apply_fail")
assert(migratedOk == false, "migration_apply_rejected")
local migrationStore = P:GetStore("v3.v7.migration_apply_fail")
assert(migrationStore.writeFenced == true and migrationStore.dirty == false, "migration_failure_not_dirty")

-- A dirty Store that becomes payload-fenced after a debounce attempt retains
-- its evidence, but Tick must not hammer SaveStore on every runtime cadence.
local stormState = {{ value = "ok" }}
assert(P:RegisterV3Store({{
  id = "v3.v7.retry_storm", owner = "v3.v7", scope = P.Scope.Account,
  lifetime = P.Lifetime.Permanent, schemaVersion = 1, legacySchemaVersion = 1,
  key = P.V3KeyPrefix .. "retry_storm",
  budget = {{ maxDepth = 5, maxNodes = 18, maxStringBytes = 128, maxEntriesPerTable = 8 }},
  default = function() return {{ value = "ok" }} end,
  get = function() return copy(stormState) end,
  apply = function(value) stormState = copy(value) end,
}}))
assert(P:LoadStore("v3.v7.retry_storm") == "empty", "storm_empty")
assert(P:MarkDirty("v3.v7.retry_storm", 0, "storm") == true, "storm_dirty")
stormState = {{}}
for i = 1, 16 do stormState["k" .. tostring(i)] = i end
local beforeCalls = saveCalls
P:Tick()
local stormStore = P:GetStore("v3.v7.retry_storm")
assert(stormStore.writeFenced == true and stormStore.dirty == true, "storm_fenced_dirty")
local afterFirst = saveCalls
assert(afterFirst == beforeCalls, "payload_preflight_prevents_native_save")
now = now + 6000
local failuresBefore = P.stats.saveFailures
P:Tick()
assert(saveCalls == afterFirst, "terminal_tick_no_native_retry")
assert(P.stats.saveFailures == failuresBefore, "terminal_tick_no_save_failure_storm")
assert(P.stats.terminalAutoRetrySuppressions >= 1, "terminal_retry_suppressed_stat")

local desc = P:Describe()
assert(desc.reliabilityContractVersion == 7, "describe_contract")
print("PERSISTENCE_RELIABILITY_V7_LUA PASS")
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
    if "PERSISTENCE_RELIABILITY_V7_LUA PASS" not in proc.stdout:
        raise AssertionError(proc.stdout.strip() or "missing PASS marker")


def main() -> int:
    source = PERSISTENCE.read_text(encoding="utf-8-sig")
    for token in (
        "ReliabilityContractVersion = 7",
        "unverifiedReloadRejects = 0",
        "STORE_UNVERIFIED_RELOAD_REJECTED",
        "deferredLoadResaves = 0",
        "deferredSaveReason = \"migration\"",
        "terminalAutoRetrySuppressions = 0",
        "IsStoreReady(store) == true and store.writeFenced ~= true",
    ):
        if token not in source:
            raise AssertionError("Reliability v7 implementation missing: " + token)
    run_lua()
    print("PERSISTENCE_RELIABILITY_V7_HARNESS PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

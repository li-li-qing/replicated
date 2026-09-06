#!/usr/bin/env python3
"""Real-Lua contract test for the Fresh Reload persistence fingerprint.

This specifically prevents package drift where CURRENT/Foundation Gate mention
RuntimeAcceptanceSnapshot but core/diagnostics files are absent from a later
incremental delivery.
"""
from __future__ import annotations

import pathlib
import subprocess
import tempfile
from rs_lua_runner import RUNNER

ROOT = pathlib.Path(__file__).resolve().parents[1]
PERSISTENCE = ROOT / "core/rs_persistence.lua"
FOUNDATION_PAGE = ROOT / "presentation/v3/pages/rs_v3_foundation_pages.lua"


def run_lua() -> None:
    script = r'''
ReplicatedSuite = {
  BootError = nil,
  BuildTag = "harness",
  Generation = 7,
  SaveKey = "rs_harness",
  NowMs = function() return 12345 end,
}
'''
    script += f'dofile([[{PERSISTENCE.as_posix()}]])\n'
    script += r'''
local P = ReplicatedSuite.Persistence
assert(P.RuntimeAcceptanceSnapshotContractVersion == 2, "contract")
assert(type(P.FingerprintPayload) == "function", "fingerprint_fn")
assert(type(P.FingerprintDurablePayload) == "function", "durable_fingerprint_fn")
assert(type(P.BuildRuntimeAcceptanceSnapshot) == "function", "snapshot_fn")
local budget = { maxDepth = 8, maxNodes = 128, maxStringBytes = 4096, maxEntriesPerTable = 64 }
local a = { alpha = 1, beta = { x = true, y = "ok" } }
local b = {}; b.beta = {}; b.beta.y = "ok"; b.beta.x = true; b.alpha = 1
local fa = assert(P:FingerprintPayload(a, budget))
local fb = assert(P:FingerprintPayload(b, budget))
assert(fa == fb, "order_independent")
local fc = assert(P:FingerprintPayload({ alpha = 2, beta = { x = true, y = "ok" } }, budget))
assert(fc ~= fa, "value_sensitive")

P.stores = {
  ["v3.loaded"] = {
    id = "v3.loaded", owner = "v3.harness", scope = "Account", lifetime = "Permanent",
    schemaVersion = 1, loaded = true, loadStatus = "loaded", dirty = false,
    writeFenced = false, dirtyRevision = 2, lastSavedRevision = 2,
    get = function() return a end, budget = budget,
  },
  ["v3.cold"] = {
    id = "v3.cold", owner = "v3.harness", scope = "Account", lifetime = "Permanent",
    schemaVersion = 1, loaded = false, loadStatus = "not_loaded", dirty = false,
    writeFenced = false, dirtyRevision = 0, lastSavedRevision = 0,
    get = function() return { should = "not_hash" } end, budget = budget,
  },
}
P.order = { "v3.cold", "v3.loaded" }
local snap = P:BuildRuntimeAcceptanceSnapshot({ ids = { "v3.loaded", "v3.cold", "v3.missing" } })
assert(snap.contractVersion == 2 and snap.fingerprintMode == "serializer_stable_numeric_v2", "snapshot_contract")
assert(snap.total == 2 and snap.loaded == 1 and snap.fingerprinted == 1, "coverage")
assert(#snap.exactMissing == 1 and snap.exactMissing[1] == "v3.missing", "missing")
local cold = snap.rows[1]
assert(cold.id == "v3.cold" and cold.fingerprint == nil and string.find(cold.error or "", "store_not_loaded", 1, true), "cold_fail_closed")
local desc = P:Describe()
assert(desc.runtimeAcceptanceSnapshotContractVersion == 2, "describe_contract")
local driftA = assert(P:FingerprintDurablePayload({ opacity = 0.82, id = 25875 }, budget))
local driftB = assert(P:FingerprintDurablePayload({ opacity = 0.82000002, id = 25875 }, budget))
assert(driftA == driftB, "serializer_stable_numeric")
print("PERSISTENCE_ACCEPTANCE_SNAPSHOT_LUA PASS 13/13")
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
    if "PERSISTENCE_ACCEPTANCE_SNAPSHOT_LUA PASS 13/13" not in proc.stdout:
        raise AssertionError(proc.stdout.strip() or "missing PASS marker")


def main() -> int:
    persistence = PERSISTENCE.read_text(encoding="utf-8-sig")
    page = FOUNDATION_PAGE.read_text(encoding="utf-8-sig")
    for token in (
        "RuntimeAcceptanceSnapshotContractVersion = 2",
        "function P:FingerprintPayload(value, budget)",
        "function P:FingerprintDurablePayload(value, budget)",
        "function P:BuildRuntimeAcceptanceSnapshot(options)",
        "runtimeAcceptanceSnapshotContractVersion = self.RuntimeAcceptanceSnapshotContractVersion",
    ):
        if token not in persistence:
            raise AssertionError("runtime snapshot implementation missing: " + token)
    for token in (
        "PERSISTENCE_ACCEPTANCE_STORE_IDS",
        "local function BuildPersistenceAcceptanceCopyText()",
        'text = "输出存档验收"',
        "BuildRuntimeAcceptanceSnapshot",
    ):
        if token not in page:
            raise AssertionError("diagnostics snapshot integration missing: " + token)
    run_lua()
    print("PERSISTENCE_ACCEPTANCE_SNAPSHOT_HARNESS PASS 21/21")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

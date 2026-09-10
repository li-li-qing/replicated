#!/usr/bin/env python3
"""Regression harness for .18.188 bag-gate scope + shell persistence evolution.

Catches two classes of regressions that static feature harnesses missed:
1) a Foundation check referencing a local outside its lexical scope and therefore
   producing a false blocker even when the runtime service exists;
2) changing the canonical shape of a persistent Store without a schema boundary
   or a narrowly authenticated migration path.
"""
from __future__ import annotations

import pathlib
import subprocess
import tempfile
from rs_lua_runner import RUNNER

ROOT = pathlib.Path(__file__).resolve().parents[1]
GATE = ROOT / "core/rs_foundation_gate.lua"
PERSISTENCE = ROOT / "core/rs_persistence.lua"
SHELL = ROOT / "presentation/v3/rs_v3_shell_store.lua"
ACCEPTANCE = ROOT / "presentation/v3/rs_v3_acceptance.lua"
LIFE_BUNDLE = ROOT / "features/life/rs_life_m16_bundle.lua"


def source_checks() -> int:
    gate = GATE.read_text(encoding="utf-8-sig", errors="replace")
    shell = SHELL.read_text(encoding="utf-8-sig", errors="replace")
    acceptance = ACCEPTANCE.read_text(encoding="utf-8-sig", errors="replace")
    life_bundle = LIFE_BUNDLE.read_text(encoding="utf-8-sig", errors="replace")
    checks: list[str] = []

    def check(name: str, condition: bool) -> None:
        if not condition:
            raise AssertionError(name)
        checks.append(name)

    check("bag_gate_isolated", "function G:EvaluateBagActionContract()" in gate)
    helper_start = gate.index("function G:EvaluateBagActionContract()")
    helper_end = gate.index("function G:Run(options)", helper_start)
    helper = gate[helper_start:helper_end]
    check("bag_gate_resolves_page_contract_in_own_scope", 'local businessPagesContract = S.UIV3 and S.UIV3.BusinessPagesContract or nil' in helper)
    check("bag_gate_reports_exact_missing_tokens", 'return false, "missing=" .. Join(missing, 16)' in helper)
    check("bag_gate_run_uses_helper", "local bagContractOk, bagContractDetail = self:EvaluateBagActionContract()" in gate)
    check("old_misleading_bag_failure_removed", "quick-window host v9 / InventorySnapshotV3 unavailable" not in gate)

    check("shell_schema_v7", "schemaVersion = 7" in shell and "legacySchemaVersion = 6" in shell)
    check("shell_historical_v6_normalizer", "local function NormalizeHistoricalV6(value)" in shell)
    check("shell_exact_historical_hook", "rebuildCanonicalForIntegrity = function" in shell)
    check("shell_known_legacy_hook", "recoverKnownLegacyCanonical = RecoverKnownV6Shell" in shell)
    check("shell_known_stamp_exact", 'local KNOWN_V6_STAMP = "2EA0A82A"' in shell)
    check("shell_known_current_exact", 'local KNOWN_V7_CANONICAL = "2EC2F5C5"' in shell)
    check("shell_known_hook_schema_guard", 'tonumber(meta.schema) ~= 6' in shell)
    check("shell_known_hook_store_owner_guard", 'tostring(meta.store or "") ~= STORE_ID' in shell and 'tostring(meta.owner or "") ~= "v3.shell"' in shell)
    check("shell_contract_versions", "ShellCanonicalMigrationContractVersion = 1" in shell and "ShellKnownLegacyRecoveryContractVersion = 1" in shell and "ShellStoreSchemaContractVersion = 7" in shell)
    check("acceptance_fences_shell_schema", "shell_persistence_schema_v7_contract" in acceptance and "ShellKnownLegacyRecoveryContractVersion" in acceptance)

    # Full-suite sealing caught two pre-existing lexical leaks in the life bundle.
    # Keep these assertions in the same regression pack because they are exactly
    # the class of silent Lua scope mistake that can make a later feature change
    # look guilty while the actual defect lives elsewhere in the active runtime.
    check("trade_name_helper_is_file_local", "local function LocalizedTradeItemName(itemType, fallbackText)" in life_bundle)
    check("trade_price_provenance_iteration_scope", "local priceProvenance = nil" in life_bundle)
    check("trade_price_provenance_not_redeclared_in_branch", "local quotedPrice, priceProvenance" not in life_bundle)

    print(f"REGRESSION_18_188_SOURCE PASS {len(checks)}/{len(checks)}")
    return len(checks)


LUA = r'''
local function copy(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {}
  if seen[value] ~= nil then return seen[value] end
  local out = {}; seen[value] = out
  for k, v in pairs(value) do out[copy(k, seen)] = copy(v, seen) end
  return out
end

local storage = {}
local now = 1000
ReplicatedSuite = {
  BootError = nil,
  BuildTag = "regression-18-188-harness",
  Generation = 1,
  SaveKey = "rs_18_188_harness",
  NowMs = function() return now end,
  Api = {}, Utils = {}, Services = {}, Features = {}, UIV3 = {},
  SafeTraceback = function(err) return tostring(err) end,
}
function ReplicatedSuite.Utils.DeepCopy(value) return copy(value) end
function ReplicatedSuite.Utils.Trim(value) return tostring(value or ""):match("^%s*(.-)%s*$") or "" end
function ReplicatedSuite.Api:SaveData(key, raw) storage[key] = copy(raw); return true, nil end
function ReplicatedSuite.Api:LoadData(key) return copy(storage[key]), nil end
function ReplicatedSuite.Api:ClearData(key) storage[key] = nil; return true, nil end

dofile([[{PERSISTENCE}]])
dofile([[{SHELL}]])
local P = ReplicatedSuite.Persistence
local V3 = ReplicatedSuite.UIV3
local shellStore = assert(P:GetStore("v3.shell"))
assert(shellStore.schemaVersion == 7 and shellStore.legacySchemaVersion == 6, "shell_schema_boundary")
assert(type(shellStore.rebuildCanonicalForIntegrity) == "function", "shell_historical_hook")
assert(type(shellStore.recoverKnownLegacyCanonical) == "function", "shell_known_hook")

-- Exercise the one-time known-stamp gate itself. We stub only the current hash
-- primitive here because the real user's decoded shell payload is not available
-- offline; the production path still computes that hash with real Persistence.
local originalDurable = P.FingerprintDurablePayload
P.FingerprintDurablePayload = function() return "2EC2F5C5" end
local knownRaw = { __rsmeta = { schema=6, store="v3.shell", owner="v3.shell" } }
local knownState = { width=1040, height=700, lastRoute="tools.bag_organizer", minimized=false, locked=false, userMoved=false }
local knownRecovered, knownReason = shellStore.recoverKnownLegacyCanonical(knownState, "2EA0A82A", knownState, knownRaw)
assert(type(knownRecovered) == "table" and knownReason == "shell_v6_known_stamp_2EA0A82A", "known_stamp_pair_accept")
assert(shellStore.recoverKnownLegacyCanonical(knownState, "DEADBEEF", knownState, knownRaw) == nil, "unknown_stamp_rejected")
assert(shellStore.recoverKnownLegacyCanonical(knownState, "2EA0A82A", knownState, {__rsmeta={schema=7,store="v3.shell",owner="v3.shell"}}) == nil, "wrong_schema_rejected")
P.FingerprintDurablePayload = originalDurable

-- Model the schema-6 canonical generation that existed before responsive source
-- viewport metadata became canonical. The disk payload contains the newer fields,
-- while the old integrity stamp authenticates only the historical v6 projection.
local decoded = {
  width = 1040, height = 700, lastRoute = "tools.bag_organizer",
  minimized = false, locked = false, userMoved = true,
  x = 120, y = 80, coordinateSpace = "logical-free-v2", savedUiScale = 0.8,
  savedLogicalWidth = 1600, savedLogicalHeight = 900,
  normalizedCenterX = 0.4, normalizedCenterY = 0.5,
}
local historical = {
  width = 1040, height = 700, lastRoute = "tools.bag_organizer",
  minimized = false, locked = false, userMoved = true,
  x = 120, y = 80, coordinateSpace = "logical-free-v2", savedUiScale = 0.8,
}
local historicalFp = assert(P:FingerprintCanonicalValue(shellStore, historical))
local currentCanonical = assert(P:CanonicalIntegrityValue(shellStore, decoded))
local currentFp = assert(P:FingerprintCanonicalValue(shellStore, currentCanonical))
assert(historicalFp ~= currentFp, "schema_generations_must_differ_when_new_fields_exist")

local raw = {
  payload = copy(decoded),
  __rsmeta = {
    framework = 2, store = "v3.shell", owner = "v3.shell",
    contractVersion = shellStore.contractVersion, lifetime = P.Lifetime.Permanent,
    scope = P.Scope.Account, schema = 6, periodId = "permanent",
    reliabilityContract = P.ReliabilityContractVersion,
    integrityVersion = P.IntegrityContractVersion,
    encodedFingerprint = historicalFp,
    envelopeIntegrityVersion = P.EnvelopeIntegrityContractVersion,
  },
}
raw.__rsmeta.envelopeFingerprint = assert(P:FingerprintEnvelopeIntegrity(raw))
storage[P.V3KeyPrefix .. "shell"] = raw
local ok, value, err = P:LoadStore("v3.shell")
assert(ok == true, "historical_shell_load_failed:" .. tostring(err))
assert(shellStore.writeFenced ~= true, "historical_shell_must_not_remain_fenced")
assert(V3.ShellState.userMoved == true and V3.ShellState.x == 120 and V3.ShellState.y == 80, "historical_shell_position_preserved")
-- New responsive fields were not authenticated by the historical stamp, so the
-- exact-reconstruction path correctly does not preserve them. A later drag can
-- regenerate them under schema 7.
assert(V3.ShellState.savedLogicalWidth == nil and V3.ShellState.normalizedCenterX == nil, "unauthenticated_new_fields_not_adopted")

-- Runtime-evaluate the bag gate with every dependency present only through the
-- real ReplicatedSuite tables. No global `businessPagesContract` is created.
local noop = function() return true end
ReplicatedSuite.Services.InventorySnapshotV3 = {
  SnapshotContractVersion=1, PhysicalBagAuthorityContractVersion=1, IndexContractVersion=1,
  PreferredBagId=1, FallbackBagId=0, BuildSnapshot=noop, FindLiveRow=noop,
  CountLive=noop, ReadPhysicalBagSlot=noop,
}
ReplicatedSuite.Features.tools_bag = {
  BagMoveContractVersion=8, BatchLifecycleContractVersion=5, NativeWindowQuickContractVersion=7,
  ReloadQuickObserverContractVersion=3, ResponsiveWindowObserverContractVersion=1,
  ProductBlacklistUxContractVersion=1, BlacklistNameMetadataContractVersion=1,
  BlacklistExplicitLookupContractVersion=1, RUFourValueWindowVisibilityContractVersion=2,
  NativeVisibilityShapeContractVersion=1, SurfaceVisibilitySplitContractVersion=1,
  StorageSessionBagSurfaceContractVersion=1, BagActionPhysicalReadAuthorityContractVersion=1,
  VisiblePresenterRetryContractVersion=1, DynamicSourceResolutionContractVersion=3,
  QuickIdentityFallbackContractVersion=1, BagTaskMutexContractVersion=2,
  QuickRunSelfHealContractVersion=1, QuickTwoButtonContractVersion=1,
  QuickReasonVisibilityContractVersion=1, QuickStatusTimestampContractVersion=1,
  InventorySnapshotContractVersion=1, GroupedIntentQueueContractVersion=1,
  FullStorageContinuationContractVersion=1, BatchTargetAutoContractVersion=1,
  Commands = {
    QuickWithdraw=noop, QuickDeposit=noop, QuickCancel=noop,
    ResolveAndAddBlacklistItem=noop, AddGlobalBlacklistItem=noop, RemoveGlobalBlacklistItem=noop,
    SetBatchCategory=noop, SetBatchTarget=noop, SetBatchLimit=noop, DepositCategoryCurrent=noop,
  },
}
ReplicatedSuite.UIV3.BusinessPagesContract = { bagProductUxContractVersion=2 }
ReplicatedSuite.UIV3.BagQuickOverlay = {
  version=9, ReleasedRootRecoveryContractVersion=1, ReloadVisibilityContractVersion=2,
  NativeTransientHostContractVersion=1, VisibleRetryContractVersion=1, TwoButtonContractVersion=1,
  DiffRenderContractVersion=1, HintYieldContractVersion=1, QuietByDefaultContractVersion=1,
  ExternalNativeWindowGeometryContractVersion=1,
}
_G.businessPagesContract = nil
dofile([[{GATE}]])
local bagOk, bagDetail = ReplicatedSuite.FoundationGate:EvaluateBagActionContract()
assert(bagOk == true, "bag_gate_false_blocker:" .. tostring(bagDetail))

print("REGRESSION_18_188_RUNTIME PASS")
'''.replace("{PERSISTENCE}", PERSISTENCE.as_posix()).replace("{SHELL}", SHELL.as_posix()).replace("{GATE}", GATE.as_posix())


def runtime_check() -> bool:
    if RUNNER is None:
        print("REGRESSION_18_188_RUNTIME SKIP | lua runner unavailable")
        return False
    with tempfile.NamedTemporaryFile("w", suffix=".lua", encoding="utf-8", delete=False) as fh:
        fh.write(LUA)
        path = pathlib.Path(fh.name)
    try:
        proc = subprocess.run([RUNNER, str(path)], capture_output=True, text=True)
    finally:
        path.unlink(missing_ok=True)
    if proc.returncode != 0:
        raise AssertionError((proc.stdout + proc.stderr).strip())
    if "REGRESSION_18_188_RUNTIME PASS" not in proc.stdout:
        raise AssertionError(proc.stdout.strip())
    print("REGRESSION_18_188_RUNTIME PASS")
    return True


def main() -> int:
    source_checks()
    runtime_check()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

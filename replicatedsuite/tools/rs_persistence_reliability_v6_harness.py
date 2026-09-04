#!/usr/bin/env python3
"""Real-Lua fault-injection harness for Persistence Reliability v6.

Covers metadata-envelope sealing, decoded-domain budgets, explicit durable
mutation readback semantics, v5 compatibility, and Character scope binding /
collision fences. No RU client is required.
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
local corruptReadbackKey = nil
local currentIdentity = "Alpha@World"
X2Unit = {{}}
ReplicatedSuite = {{
  BootError = nil,
  BuildTag = "reliability-v6-harness",
  Generation = 1,
  SaveKey = "rs_harness_v6",
  NowMs = function() return 67890 end,
  Api = {{}},
}}
function ReplicatedSuite.Api:SaveData(key, raw)
  storage[key] = copy(raw)
  return true, nil
end
function ReplicatedSuite.Api:LoadData(key)
  loadCalls = loadCalls + 1
  local raw = copy(storage[key])
  if key == corruptReadbackKey and type(raw) == "table" and type(raw.payload) == "table" then
    raw.payload.value = "corrupt-readback"
  end
  return raw, nil
end
function ReplicatedSuite.Api:ClearData(key)
  storage[key] = nil
  return true, nil
end
function ReplicatedSuite.Api:CallCapability(_capability, _object, _method, _unit)
  return true, currentIdentity
end

dofile([[{PERSISTENCE.as_posix()}]])
local P = ReplicatedSuite.Persistence
assert(P.ReliabilityContractVersion >= 6, "contract")
assert(P.IntegrityContractVersion == 1, "business_integrity")
assert(P.EnvelopeIntegrityContractVersion == 1, "envelope_integrity")
assert(P.ScopeBindingContractVersion == 1, "scope_binding")
local budget = {{ maxDepth = 8, maxNodes = 128, maxStringBytes = 4096, maxEntriesPerTable = 64 }}

-- v6 save must stamp both business integrity and metadata-envelope integrity.
local sealState = {{}}
local sealDecodeCalls = 0
assert(P:RegisterV3Store({{
  id = "v3.v6.seal", owner = "v3.v6", scope = P.Scope.Account,
  lifetime = P.Lifetime.Permanent, schemaVersion = 2, legacySchemaVersion = 1,
  key = P.V3KeyPrefix .. "seal", budget = budget,
  default = function() return {{ value = 0 }} end,
  get = function() return copy(sealState) end,
  apply = function(value) sealState = copy(value) end,
  decode = function(raw) sealDecodeCalls = sealDecodeCalls + 1; return copy(raw.payload) end,
}}))
assert(P:LoadStore("v3.v6.seal") == "empty", "seal_empty")
sealState = {{ value = 91 }}
assert(P:SaveStore("v3.v6.seal", {{ durable = true }}) == true, "seal_save")
local sealKey = P.V3KeyPrefix .. "seal"
local sealMeta = storage[sealKey].__rsmeta
assert(sealMeta.reliabilityContract == P.ReliabilityContractVersion, "seal_reliability")
assert(sealMeta.integrityVersion == 1 and type(sealMeta.encodedFingerprint) == "string", "seal_business_stamp")
assert(sealMeta.envelopeIntegrityVersion == 1 and type(sealMeta.envelopeFingerprint) == "string", "seal_envelope_stamp")

-- Metadata-only truncation must fail before the custom business decoder runs.
local beforeSealDecode = sealDecodeCalls
storage[sealKey].__rsmeta.schema = nil
local sealOk, _, sealErr = P:LoadStore("v3.v6.seal")
assert(sealOk == false and string.find(sealErr or "", "envelope_integrity_failed", 1, true), "metadata_truncation_rejected")
assert(sealDecodeCalls == beforeSealDecode, "metadata_rejected_before_decode")
assert(P.stats.envelopeIntegrityLoadFailures >= 1, "envelope_failure_stat")

-- A compact encoded payload may expand in a custom decoder. The decoded Domain
-- still must satisfy the Store's own budget before migration/apply.
local expandedState = {{ seed = 1 }}
assert(P:RegisterV3Store({{
  id = "v3.v6.expand", owner = "v3.v6", scope = P.Scope.Account,
  lifetime = P.Lifetime.Permanent, schemaVersion = 1, legacySchemaVersion = 1,
  key = P.V3KeyPrefix .. "expand",
  budget = {{ maxDepth = 6, maxNodes = 16, maxStringBytes = 1024, maxEntriesPerTable = 8 }},
  encodedBudget = {{ maxDepth = 8, maxNodes = 64, maxStringBytes = 2048, maxEntriesPerTable = 32 }},
  default = function() return {{ seed = 1 }} end,
  get = function() return copy(expandedState) end,
  apply = function(value) expandedState = copy(value) end,
  encode = function(value) return {{ compact = tonumber(value.seed) or 1 }} end,
  decode = function(_raw)
    local out = {{}}
    for i = 1, 24 do out["k" .. tostring(i)] = i end
    return out
  end,
}}))
assert(P:LoadStore("v3.v6.expand") == "empty", "expand_empty")
assert(P:SaveStore("v3.v6.expand") == true, "expand_seed")
P:GetStore("v3.v6.expand").needsBarrierVerify = false -- simulate next process after a prior write
local expandOk, _, expandErr = P:LoadStore("v3.v6.expand")
assert(expandOk == false and string.find(expandErr or "", "decoded_load_rejected", 1, true), "decoded_expansion_rejected")
assert(P.stats.decodedLoadRejects >= 1, "decoded_reject_stat")

-- durable=true is an actual immediate durability promise for ordinary stores,
-- not merely a SaveData(true) call followed by a deferred Reload barrier.
local durableState = {{ value = "old" }}
assert(P:RegisterV3Store({{
  id = "v3.v6.durable", owner = "v3.v6", scope = P.Scope.Account,
  lifetime = P.Lifetime.Permanent, schemaVersion = 1, legacySchemaVersion = 1,
  key = P.V3KeyPrefix .. "durable", budget = budget,
  default = function() return {{ value = "old" }} end,
  get = function() return copy(durableState) end,
  apply = function(value) durableState = copy(value) end,
}}))
assert(P:LoadStore("v3.v6.durable") == "empty", "durable_empty")
local beforeDurableLoads = loadCalls
local durableOk = P:MutateStore("v3.v6.durable", function()
  durableState.value = "new"
  return true
end, {{ durable = true, reason = "harness_durable" }})
assert(durableOk == true, "durable_mutation")
assert(loadCalls == beforeDurableLoads + 1, "durable_immediate_readback")
assert(P:GetStore("v3.v6.durable").needsBarrierVerify == false, "durable_no_deferred_barrier")
assert(P.stats.durableVerifyAttempts >= 1 and P.stats.durableVerifyFailures == 0, "durable_stats")

-- If the immediate readback cannot prove the write, durable mutation rolls the
-- Domain back and reports failure while retaining a barrier obligation.
local durableKey = P.V3KeyPrefix .. "durable"
corruptReadbackKey = durableKey
local failedOk, failedErr = P:MutateStore("v3.v6.durable", function()
  durableState.value = "must-rollback"
  return true
end, {{ durable = true, reason = "harness_durable_fail" }})
corruptReadbackKey = nil
assert(failedOk == false and string.find(failedErr or "", "readback_verify_failed", 1, true), "durable_readback_failure")
assert(durableState.value == "new", "durable_domain_rollback")
assert(P:GetStore("v3.v6.durable").needsBarrierVerify == true, "durable_failure_keeps_barrier")
assert(P.stats.durableVerifyFailures >= 1, "durable_failure_stat")

-- v5-stamped saves remain readable. Real v5 saves had the business fingerprint
-- but did not contain v6 envelope/scope fields.
local compatState = {{}}
assert(P:RegisterV3Store({{
  id = "v3.v6.compat", owner = "v3.v6", scope = P.Scope.Account,
  lifetime = P.Lifetime.Permanent, schemaVersion = 1, legacySchemaVersion = 1,
  key = P.V3KeyPrefix .. "compat", budget = budget,
  default = function() return {{ value = 0 }} end,
  get = function() return copy(compatState) end,
  apply = function(value) compatState = copy(value) end,
}}))
assert(P:LoadStore("v3.v6.compat") == "empty", "compat_empty")
compatState = {{ value = 55 }}
assert(P:SaveStore("v3.v6.compat") == true, "compat_seed")
P:GetStore("v3.v6.compat").needsBarrierVerify = false -- simulate next process after a prior write
local compatKey = P.V3KeyPrefix .. "compat"
storage[compatKey].__rsmeta.reliabilityContract = 5
storage[compatKey].__rsmeta.envelopeIntegrityVersion = nil
storage[compatKey].__rsmeta.envelopeFingerprint = nil
storage[compatKey].__rsmeta.scopeBindingContract = nil
storage[compatKey].__rsmeta.scopeIdentityFingerprint = nil
assert(P:LoadStore("v3.v6.compat") == true and compatState.value == 55, "v5_compat_load")

-- Character stores bind loaded Domain state to the exact world-qualified
-- identity. A clean store can rebind through PrepareWrite; A and B remain
-- physically independent and switching back reloads A rather than saving B over it.
local characterState = {{ value = "default" }}
assert(P:RegisterV3Store({{
  id = "v3.v6.character", owner = "v3.v6", scope = P.Scope.Character,
  lifetime = P.Lifetime.Permanent, schemaVersion = 1, legacySchemaVersion = 1,
  key = P.V3KeyPrefix .. "character", budget = budget,
  default = function() return {{ value = "default" }} end,
  get = function() return copy(characterState) end,
  apply = function(value) characterState = copy(value) end,
}}))
currentIdentity = "Alpha@World"
assert(P:LoadStore("v3.v6.character") == "empty", "char_a_empty")
characterState.value = "A"
assert(P:SaveStore("v3.v6.character", {{ durable = true }}) == true, "char_a_save")
local charStore = P:GetStore("v3.v6.character")
local keyA = charStore.resolvedKey
local fingerprintA = charStore.resolvedScopeFingerprint
assert(type(keyA) == "string" and type(fingerprintA) == "string", "char_a_binding")
currentIdentity = "Beta@World"
local loadedB = P:IsStoreLoaded("v3.v6.character")
assert(loadedB == false, "char_switch_invalidates_readiness")
assert(P:PrepareWrite("v3.v6.character") == true, "char_b_rebind")
assert(characterState.value == "default", "char_b_default_applied")
local keyB = charStore.resolvedKey
assert(keyB ~= keyA and charStore.resolvedScopeFingerprint ~= fingerprintA, "char_b_distinct_binding")
assert(P:MutateStore("v3.v6.character", function() characterState.value = "B"; return true end, {{ durable = true }}) == true, "char_b_save")
currentIdentity = "Alpha@World"
assert(P:IsStoreLoaded("v3.v6.character") == false, "char_back_invalidates_readiness")
assert(P:PrepareWrite("v3.v6.character") == true, "char_a_rebind")
assert(characterState.value == "A", "char_a_restored")
assert(P.stats.scopeRebinds >= 2, "scope_rebind_stat")

-- Lossy historical key normalization can collapse non-ASCII identities. v6
-- never silently rebinds when the physical key is unchanged but exact identity
-- fingerprint differs.
local collisionState = {{ value = "default" }}
assert(P:RegisterV3Store({{
  id = "v3.v6.collision", owner = "v3.v6", scope = P.Scope.Character,
  lifetime = P.Lifetime.Permanent, schemaVersion = 1, legacySchemaVersion = 1,
  key = P.V3KeyPrefix .. "collision", budget = budget,
  default = function() return {{ value = "default" }} end,
  get = function() return copy(collisionState) end,
  apply = function(value) collisionState = copy(value) end,
}}))
currentIdentity = "甲@世界"
assert(P:LoadStore("v3.v6.collision") == "empty", "collision_a_empty")
collisionState.value = "first"
assert(P:SaveStore("v3.v6.collision", {{ durable = true }}) == true, "collision_a_save")
local collisionKey = P:GetStore("v3.v6.collision").resolvedKey
currentIdentity = "乙@世界"
local collisionOk, _, collisionErr = P:LoadStore("v3.v6.collision")
assert(collisionOk == false and collisionErr == "scope_binding_identity_collision", "lossy_collision_fenced")
assert(P:GetStore("v3.v6.collision").resolvedKey == collisionKey, "collision_never_rebound")
assert(P.stats.scopeBindingMismatches >= 1, "scope_collision_stat")

local desc = P:Describe()
assert(desc.reliabilityContractVersion >= 6, "describe_reliability")
assert(desc.envelopeIntegrityContractVersion == 1, "describe_envelope")
assert(desc.scopeBindingContractVersion == 1, "describe_scope")
print("PERSISTENCE_RELIABILITY_V6_LUA PASS")
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
    if "PERSISTENCE_RELIABILITY_V6_LUA PASS" not in proc.stdout:
        raise AssertionError(proc.stdout.strip() or "missing PASS marker")


def main() -> int:
    source = PERSISTENCE.read_text(encoding="utf-8-sig")
    for token in (
        "ReliabilityContractVersion = 7",
        "EnvelopeIntegrityContractVersion = 1",
        "ScopeBindingContractVersion = 1",
        "function P:FingerprintEnvelopeIntegrity(raw)",
        'store.loadStatus = "envelope_integrity_failed"',
        'store.loadStatus = "decoded_load_rejected"',
        "durableVerifyAttempts = 0",
        "scopeBindingMismatches = 0",
        "scopeIdentityFingerprint",
        "scope_change_pending_persistence",
        "useBoundScope = true",
    ):
        if token not in source:
            raise AssertionError("Reliability v6 implementation missing: " + token)
    run_lua()
    print("PERSISTENCE_RELIABILITY_V6_HARNESS PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

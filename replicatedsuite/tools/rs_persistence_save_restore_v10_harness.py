#!/usr/bin/env python3
"""Framework3 save/restore regression for RU false/empty-table omission.

Validates the physical transport boundary, Framework2 one-time rewrite intent,
nullable Business feature whitelist, DPS durable close/policy authority, Gear
compact-v2 historical managed=false recovery hook wiring, and auxiliary movable
window Presentation persistence.
"""
from __future__ import annotations
import pathlib, subprocess, tempfile
from rs_lua_runner import RUNNER

ROOT = pathlib.Path(__file__).resolve().parents[1]
PERSISTENCE = ROOT / "core/rs_persistence.lua"
BUSINESS = ROOT / "features/rs_business_bridge.lua"
FEATURE_RUNTIME = ROOT / "features/rs_feature_runtime.lua"
DPS_STORE = ROOT / "features/combat/dps/rs_dps_store.lua"
DPS_FEATURE = ROOT / "features/combat/dps/rs_dps_feature.lua"
DPS_WIDGET = ROOT / "presentation/v3/widgets/rs_v3_dps_widget.lua"
GEAR = ROOT / "features/combat/gear/rs_gear_store.lua"
AUX = ROOT / "presentation/v3/rs_v3_aux_window_store.lua"
TOC = ROOT / "toc.g"

LUA = rf'''
local function copy(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {{}}
  if seen[value] ~= nil then return seen[value] end
  local out = {{}}; seen[value] = out
  for k,v in pairs(value) do out[copy(k,seen)] = copy(v,seen) end
  return out
end
local function ruSerialize(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {{}}
  if seen[value] ~= nil then return seen[value] end
  local out = {{}}; seen[value] = out
  for k,v in pairs(value) do
    if v ~= false then
      local nextValue = ruSerialize(v, seen)
      if type(nextValue) ~= "table" or next(nextValue) ~= nil then out[k] = nextValue end
    end
  end
  return out
end
local storage = {{}}
ReplicatedSuite = {{ BootError=nil, BuildTag="save-restore-v10", Generation=1, SaveKey="rs_save_restore_v10", NowMs=function() return 1000 end, Api={{}} }}
function ReplicatedSuite.Api:SaveData(key, raw) storage[key]=ruSerialize(copy(raw)); return true,nil end
function ReplicatedSuite.Api:LoadData(key) return copy(storage[key]),nil end
function ReplicatedSuite.Api:ClearData(key) storage[key]=nil; return true,nil end

dofile([[{PERSISTENCE.as_posix()}]])
local P=ReplicatedSuite.Persistence
assert(P.FrameworkVersion==3 and P.TransportContractVersion==1, "transport_contract")
local state={{ enabled=true, empty={{}}, window={{ minimized=false, locked=false, userMoved=false }}, literal="__rs_t1:f" }}
assert(P:RegisterV3Store({{
  id="v3.transport.test", owner="v3.transport.test", scope=P.Scope.Account, lifetime=P.Lifetime.Permanent,
  schemaVersion=1, legacySchemaVersion=0, key=P.V3KeyPrefix.."transport_test",
  budget={{maxDepth=6,maxNodes=128,maxStringBytes=2048,maxEntriesPerTable=32}},
  default=function() return {{enabled=true,empty={{}},window={{minimized=false,locked=false,userMoved=false}},literal="__rs_t1:f"}} end,
  get=function() return copy(state) end, apply=function(v) state=copy(v) end,
}}))
assert(P:LoadStore("v3.transport.test")=="empty", "initial_empty")
state.enabled=false; state.empty={{}}; state.window.minimized=false; state.window.locked=false; state.window.userMoved=false
assert(P:SaveStore("v3.transport.test")==true, "save")
assert(P:Flush()==true, "flush")
local key=P.V3KeyPrefix.."transport_test"
assert(type(storage[key])=="table" and storage[key].__rsmeta.framework==3 and storage[key].__rsmeta.transportVersion==1, "physical_meta")
assert(storage[key].payload.enabled~=nil and storage[key].payload.enabled~=false, "false_physically_preserved")
assert(storage[key].payload.empty~=nil and type(storage[key].payload.empty)~="table", "empty_table_physically_preserved")
assert(storage[key].payload.literal~="__rs_t1:f", "reserved_string_escaped")
state={{ enabled=true, empty={{bad=true}}, window={{minimized=true,locked=true,userMoved=true}}, literal="bad" }}
assert(P:LoadStore("v3.transport.test", {{discardDirty=true,discardUnverified=true}})==true, "reload")
assert(state.enabled==false, "false_restored")
assert(type(state.empty)=="table" and next(state.empty)==nil, "empty_restored")
assert(state.window.minimized==false and state.window.locked==false and state.window.userMoved==false, "window_false_restored")
assert(state.literal=="__rs_t1:f", "reserved_string_restored")

-- 中文维护测试：模拟 .18.193/Framework2 的真实磁盘。先把当前逻辑 envelope 降成
-- Framework2 并重盖 metadata seal，再经过会吞 false/空表的 RU serializer；LoadStore
-- 必须依赖旧 fingerprint 精确复原，而不是因为默认值“看起来合理”就放行。
local legacy=P:DecodePhysicalEnvelope(copy(storage[key]))
legacy.__rsmeta.framework=2; legacy.__rsmeta.transportVersion=nil; legacy.__rsmeta.envelopeFingerprint=nil
local legacyEnvelope=P:FingerprintEnvelopeIntegrity(legacy)
assert(legacyEnvelope~=nil, "legacy_envelope_fingerprint")
legacy.__rsmeta.envelopeFingerprint=legacyEnvelope
storage[key]=ruSerialize(copy(legacy))
assert(storage[key].payload.enabled==nil and storage[key].payload.empty==nil, "legacy_ru_omission_simulated")
state={{ enabled=true, empty={{bad=true}}, window={{minimized=true,locked=true,userMoved=true}}, literal="bad" }}
assert(P:LoadStore("v3.transport.test", {{discardDirty=true,discardUnverified=true}})==true, "legacy_reload")
assert(state.enabled==false and type(state.empty)=="table" and next(state.empty)==nil, "legacy_default_shape_restored")
assert(state.window.minimized==false and state.window.locked==false and state.window.userMoved==false, "legacy_false_shape_restored")

-- 中文维护测试：FeatureRuntime 的 preference map 是动态 key，default={{}} 无法由 Core
-- 推导丢掉了哪个 false；专用 hook 只能枚举 Registry 中 defaultEnabled=true 的极小集合，
-- 并仍要求 exact fingerprint。这里验证两个默认开启 Feature 同时关闭后跨 Framework2
-- RU 省略仍能恢复，避免登录时被默认启用逻辑反向覆盖。
ReplicatedSuite.FeatureRegistry={{
  rows={{
    combat_gear={{id="combat_gear",defaultEnabled=true}},
    life_tasks={{id="life_tasks",defaultEnabled=true}},
    combat_stats={{id="combat_stats",defaultEnabled=false}},
  }}
}}
function ReplicatedSuite.FeatureRegistry:Get(id) return self.rows[tostring(id or ""):lower()] end
function ReplicatedSuite.FeatureRegistry:List()
  return {{self.rows.combat_gear,self.rows.life_tasks,self.rows.combat_stats}}
end
dofile([[{FEATURE_RUNTIME.as_posix()}]])
local F=ReplicatedSuite.FeatureRuntime
assert(F:EnsurePreferencesLoaded()==true, "feature_pref_initial_load")
F.preferences={{combat_gear=false,life_tasks=false}}
assert(P:SaveStore(F.preferenceStoreId)==true, "feature_pref_save")
local featureKey=P.V3KeyPrefix.."features"
local featureLegacy=P:DecodePhysicalEnvelope(copy(storage[featureKey]))
featureLegacy.__rsmeta.framework=2; featureLegacy.__rsmeta.transportVersion=nil; featureLegacy.__rsmeta.envelopeFingerprint=nil
local featureEnvelope=P:FingerprintEnvelopeIntegrity(featureLegacy)
assert(featureEnvelope~=nil, "feature_legacy_envelope_fingerprint")
featureLegacy.__rsmeta.envelopeFingerprint=featureEnvelope
storage[featureKey]=ruSerialize(copy(featureLegacy))
assert(storage[featureKey].payload==nil, "feature_false_payload_removed")
F.preferences={{}}
assert(P:LoadStore(F.preferenceStoreId, {{discardDirty=true,discardUnverified=true}})==true, "feature_legacy_reload")
assert(F.preferences.combat_gear==false and F.preferences.life_tasks==false, "feature_disabled_defaults_restored")
print("PERSISTENCE_SAVE_RESTORE_V10_LUA PASS 21/21")
'''


def require(name: str, condition: bool) -> None:
    if not condition:
        raise AssertionError(name)
    print("PASS", name)


def main() -> int:
    p = PERSISTENCE.read_text(encoding="utf-8-sig")
    b = BUSINESS.read_text(encoding="utf-8-sig")
    fr = FEATURE_RUNTIME.read_text(encoding="utf-8-sig")
    ds = DPS_STORE.read_text(encoding="utf-8-sig")
    df = DPS_FEATURE.read_text(encoding="utf-8-sig")
    dw = DPS_WIDGET.read_text(encoding="utf-8-sig")
    g = GEAR.read_text(encoding="utf-8-sig")
    a = AUX.read_text(encoding="utf-8-sig")
    toc = TOC.read_text(encoding="utf-8-sig")
    require("framework3", "FrameworkVersion = 3" in p and "TransportContractVersion = 1" in p)
    require("physical_boundary", "EncodePhysicalEnvelope" in p and "DecodePhysicalEnvelope" in p and "framework_transport_upgrade" in p)
    require("framework2_exact_omission_recovery", "RebuildFramework2SerializerOmissions" in p and "framework2_serializer_omissions" in p)
    require("feature_preference_false_recovery", "RebuildFeaturePreferenceCanonical" in fr and "rebuildCanonicalForIntegrity = RebuildFeaturePreferenceCanonical" in fr)
    require("business_nullable_contract", "spec.persistentKeys" in b and 'persistentKeys = { "selectedRecipeKey", "craftType", "itemType" }' in b and 'persistentKeys = { "role" }' in b and 'persistentKeys = { "batchCategory" }' in b)
    require("dps_policy_single_authority", "F.WidgetWindowPolicy" in ds and "self.WidgetWindowPolicy or {}" in df and "Feature.WidgetWindowPolicy" in dw)
    require("dps_close_durable", 'NotifyWindowClosed(WIDGET_ID, { persist = true' in dw)
    require("gear_managed_false_recovery", "RebuildCompactV2Canonical" in g and "rebuildCanonicalForIntegrity = RebuildCompactV2Canonical" in g and "row.m = false" in g)
    require("aux_store_contract", 'STORE_ID = "v3.presentation.aux_windows"' in a and "function A:EnsureLoaded()" in a and "function A:PersistWindow" in a)
    require("aux_toc_order", "presentation/v3/rs_v3_aux_window_store.lua" in toc and toc.index("presentation/v3/rs_v3_aux_window_store.lua") < toc.index("presentation/v3/widgets/rs_v3_trade_detail_floating.lua"))
    for rel, wid in (("rs_v3_trade_detail_floating.lua", "trade_detail"), ("rs_v3_trade_diagnostics.lua", "trade_diagnostics"), ("rs_v3_quest_detail_floating.lua", "quest_detail")):
        text=(ROOT/"presentation/v3/widgets"/rel).read_text(encoding="utf-8-sig")
        require("aux_binding_"+wid, f'AuxStore:PersistWindow("{wid}"' in text and "persist = function() return true end" not in text)
    if RUNNER is None:
        raise AssertionError("lua_runner_unavailable")
    with tempfile.NamedTemporaryFile("w", suffix=".lua", encoding="utf-8", delete=False) as fh:
        fh.write(LUA); tmp=pathlib.Path(fh.name)
    try:
        proc=subprocess.run([RUNNER,str(tmp)],capture_output=True,text=True,timeout=30)
    finally:
        tmp.unlink(missing_ok=True)
    if proc.returncode != 0:
        raise AssertionError((proc.stdout+proc.stderr).strip())
    require("real_lua_transport", "PERSISTENCE_SAVE_RESTORE_V10_LUA PASS" in proc.stdout)
    print("PERSISTENCE_SAVE_RESTORE_V10_HARNESS PASS")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())

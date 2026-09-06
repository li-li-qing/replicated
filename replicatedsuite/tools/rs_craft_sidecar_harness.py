#!/usr/bin/env python3
"""Static native-surface/sidecar safety harness for .18.121 Craft Assistant."""
from pathlib import Path
import sys

ROOT=Path(__file__).resolve().parents[1]
SERVICE=(ROOT/"services/rs_craft_surface_v3.lua").read_text(encoding="utf-8-sig")
EXT=(ROOT/"features/life/craft/rs_craft_assistant_surface_extension_v3.lua").read_text(encoding="utf-8-sig")
WIDGET=(ROOT/"presentation/v3/widgets/rs_v3_craft_sidecar.lua").read_text(encoding="utf-8-sig")
BRIDGE=(ROOT/"features/rs_business_bridge.lua").read_text(encoding="utf-8-sig")
REG=(ROOT/"features/rs_feature_registry.lua").read_text(encoding="utf-8-sig")
TOC=(ROOT/"toc.g").read_text(encoding="utf-8-sig")
GATE=(ROOT/"core/rs_foundation_gate.lua").read_text(encoding="utf-8-sig")
ACCEPT=(ROOT/"presentation/v3/rs_v3_acceptance.lua").read_text(encoding="utf-8-sig")

checks=[]
def check(name, cond): checks.append((name,bool(cond)))

check("service_before_features", TOC.index("services/rs_craft_surface_v3.lua") < TOC.index("features/rs_business_bridge.lua"))
check("extensions_after_business", TOC.index("features/rs_business_bridge.lua") < TOC.index("features/life/craft/rs_craft_assistant_surface_extension_v3.lua"))
check("widget_after_host", TOC.index("presentation/v3/widgets/rs_v3_widget_host.lua") < TOC.index("presentation/v3/widgets/rs_v3_craft_sidecar.lua"))
check("visibility_contract", "VisibilityContractVersion = 1" in SERVICE and "version = 1" in SERVICE)
check("three_governed_candidates", all(x in SERVICE for x in ["UIC_MAKE_CRAFT_ORDER","UIC_CRAFT_ORDER","UIC_CRAFT_BOOK"]))
check("candidate_priority", SERVICE.index("UIC_MAKE_CRAFT_ORDER") < SERVICE.index("UIC_CRAFT_ORDER") < SERVICE.index("UIC_CRAFT_BOOK"))
check("only_governed_addon_reads", 'IsCapabilityAllowed("ADDON:GetContentMainScriptPosVis")' in SERVICE and 'CallCapability("ADDON:GetContent"' in SERVICE)
check("four_value_fail_closed", 'source = "geometry-only"' in SERVICE and "Geometry alone is not enough" in SERVICE)
check("parent_visibility_chain", "ReadContentChainVisible" in SERVICE and "node:GetParent()" in SERVICE and "widget:IsVisible()" in SERVICE)
check("bounded_400ms", "intervalMs = 400" in SERVICE and "AddTask(self.taskId, self.intervalMs" in SERVICE)
check("no_unverified_craft_events", "SubscribeOptional" not in SERVICE and "CRAFTING_START" not in SERVICE and "TOGGLE_CRAFT" not in SERVICE)
check("observer_no_craft_or_bag_scan", "X2Craft" not in SERVICE and "X2Bag" not in SERVICE)
check("observer_no_auction", "GetLowestPrice" not in SERVICE and "SearchAuctionArticle" not in SERVICE)
check("feature_persists_auto_sidecar", 'autoSidecar = true' in BRIDGE and 'reason = "craft_auto_sidecar"' in EXT)
check("feature_starts_observer", "Surface:Start()" in EXT)
check("feature_stops_observer", 'Surface:Stop("feature_disabled")' in EXT)
check("sidecar_contract_marker", "Feature.CraftSidecarContractVersion = 1" in EXT)
check("widget_reuses_projection", "Feature:GetProjection()" in WIDGET)
check("widget_reuses_recipe_selection", "Feature.Commands:SelectRecipe" in WIDGET)
check("widget_explicit_quote_only", "Feature.Commands:QuotePendingMaterials" in WIDGET and "RequestQuote(" not in WIDGET and "GetLowestPrice" not in WIDGET)
check("widget_consumer_lifecycle", 'Feature:AcquireConsumer("widget:craft_sidecar")' in WIDGET and 'Feature:ReleaseConsumer("widget:craft_sidecar")' in WIDGET)
check("widget_session_dismiss", "Controller.dismissed = true" in WIDGET)
check("widget_left_right_follow", "nativeX - WIDTH - gap" in WIDGET and "nativeX + nativeWidth + gap" in WIDGET)
check("widget_no_store", "RegisterV3Store" not in WIDGET and "MutateStore" not in WIDGET)
check("registry_declares_addon_reads", '"ADDON:GetContent", "ADDON:GetContentMainScriptPosVis"' in REG)
check("foundation_gate", '"v3_craft_sidecar_contract"' in GATE)
check("acceptance_gate", '"craft_sidecar_contract_v1"' in ACCEPT)
check("no_tick", "OnTick" not in SERVICE and "OnUpdate" not in SERVICE and "OnTick" not in WIDGET)

failed=[n for n,ok in checks if not ok]
if failed:
    print(f"CRAFT_SIDECAR_HARNESS FAIL | {len(checks)-len(failed)}/{len(checks)}")
    for n in failed: print(" -",n)
    sys.exit(1)
print(f"CRAFT_SIDECAR_HARNESS PASS | {len(checks)}/{len(checks)}")

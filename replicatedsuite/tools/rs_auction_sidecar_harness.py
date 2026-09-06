#!/usr/bin/env python3
"""Static contract harness for Auction Favorites Sidecar v2."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
SERVICE = (ROOT / "services/rs_auction_surface_v3.lua").read_text(encoding="utf-8")
WIDGET = (ROOT / "presentation/v3/widgets/rs_v3_auction_sidecar.lua").read_text(encoding="utf-8")
BUSINESS = (ROOT / "features/rs_business_bridge.lua").read_text(encoding="utf-8")
TOC = (ROOT / "toc.g").read_text(encoding="utf-8")

checks = []
def check(name, condition):
    checks.append((name, bool(condition)))

check("service_loaded_before_feature", TOC.index("services/rs_auction_surface_v3.lua") < TOC.index("features/rs_business_bridge.lua"))
check("widget_loaded_after_host", TOC.index("presentation/v3/widgets/rs_v3_widget_host.lua") < TOC.index("presentation/v3/widgets/rs_v3_auction_sidecar.lua"))
check("service_visibility_contract_v2", "VisibilityContractVersion = 2" in SERVICE and "version = 2" in SERVICE)
check("service_uses_verified_content_getter", 'GetContentMainScriptPosVis(contentId)' in SERVICE and 'rawget(_G, "UIC_AUCTION")' in SERVICE)
check("service_capability_gated", 'IsCapabilityAllowed("ADDON:GetContentMainScriptPosVis")' in SERVICE)
check("service_reads_content_proxy", 'IsCapabilityAllowed("ADDON:GetContent")' in SERVICE and 'CallCapability("ADDON:GetContent"' in SERVICE)
check("service_parent_visibility_chain", "ReadContentChainVisible" in SERVICE and "widget:IsVisible()" in SERVICE and "node:GetParent()" in SERVICE)
check("service_nil_boolean_compat", 'elseif contentKnown == true then' in SERVICE and 'elseif mainRect == true then' in SERVICE)
check("service_parent_geometry_fallback", "ResolveContentRect" in SERVICE and "GetLogicalRect(node)" in SERVICE)
check("service_bounded_250ms", 'AddTask(self.taskId, 250' in SERVICE)
check("service_no_server_search", "SearchAuctionArticle" not in SERVICE and "GetLowestPrice" not in SERVICE)
check("service_no_tick", "OnUpdate" not in SERVICE and "OnTick" not in SERVICE)
check("widget_reuses_feature_projection", "Feature:GetProjection()" in WIDGET)
check("widget_reuses_feature_search", "Feature:Search(" in WIDGET)
check("widget_reuses_favorite_mutations", "Feature:AddFavorite(" in WIDGET and "Feature:RemoveFavorite(" in WIDGET)
check("widget_has_no_persistence_store", "RegisterV3Store" not in WIDGET and "SaveData" not in WIDGET)
check("widget_acquires_consumer", 'Feature:AcquireConsumer("widget:auction_sidecar")' in WIDGET)
check("widget_releases_consumer", 'Feature:ReleaseConsumer("widget:auction_sidecar")' in WIDGET)
check("widget_follows_left_or_right", "auctionX - WIDTH - gap" in WIDGET and "auctionX + auctionWidth + gap" in WIDGET)
check("widget_close_session_dismiss", "Controller.dismissed = true" in WIDGET)
check("feature_starts_observer", "AuctionSurfaceV3" in BUSINESS and "surface:Start()" in BUSINESS)
check("feature_stops_observer", 'surface:Stop("feature_disabled")' in BUSINESS)
check("feature_declares_surface_apis", '"ADDON:GetContent"' in BUSINESS and '"ADDON:GetContentMainScriptPosVis"' in BUSINESS)

failed = [name for name, ok in checks if not ok]
if failed:
    print(f"AUCTION_SIDECAR_V2_HARNESS FAIL {len(checks)-len(failed)}/{len(checks)}")
    for name in failed: print("FAIL", name)
    sys.exit(1)
print(f"AUCTION_SIDECAR_V2_HARNESS PASS {len(checks)}/{len(checks)}")

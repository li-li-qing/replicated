#!/usr/bin/env python3
"""Static ownership/identity harness for .18.165 Trade material identity.

RU runtime evidence (user screenshot .18.164): every route row showed 材料待确认
and the quote button stayed disabled. Root causes recovered from the legacy
implementation: (1) localized server pack names never matched the EN legacy
recipe keys; (2) static recipe ingredient keys ("material.xxx") never matched
the EN-keyed auction meta table. This harness locks the recovered three-layer
identity chain and its ownership boundaries.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
service = (ROOT / "services/rs_trade_material_identity_v3.lua").read_text(encoding="utf-8-sig")
quote_queue = (ROOT / "services/rs_price_quote_queue_v3.lua").read_text(encoding="utf-8-sig")
trade = (ROOT / "features/life/rs_life_m16_bundle.lua").read_text(encoding="utf-8-sig")
page = (ROOT / "presentation/v3/pages/rs_v3_life_m16_pages.lua").read_text(encoding="utf-8-sig")
widget = (ROOT / "presentation/v3/widgets/rs_v3_life_economy_widgets.lua").read_text(encoding="utf-8-sig")
detail = (ROOT / "presentation/v3/widgets/rs_v3_trade_detail_floating.lua").read_text(encoding="utf-8-sig")
diag_panel = (ROOT / "presentation/v3/widgets/rs_v3_trade_diagnostics.lua").read_text(encoding="utf-8-sig")
diagnostics = (ROOT / "core/rs_diagnostics.lua").read_text(encoding="utf-8-sig")
toc_lines = (ROOT / "toc.g").read_text(encoding="utf-8-sig").splitlines()

checks = []
def require(name, cond): checks.append((name, bool(cond)))

def strip_comments(text):
    return re.sub(r"--\[\[[\s\S]*?\]\]", "", re.sub(r"--[^\n]*", "", text))

# --- TOC: service is active and loads before its Feature consumer -------------
service_idx = next((i for i, line in enumerate(toc_lines) if "rs_trade_material_identity_v3.lua" in line), None)
bundle_idx = next((i for i, line in enumerate(toc_lines) if "rs_life_m16_bundle.lua" in line), None)
require("toc_service_active", service_idx is not None)
require("toc_before_bundle", service_idx is not None and bundle_idx is not None and service_idx < bundle_idx)

# --- Service: recovered semantics ---------------------------------------------
require("service_contract", "IdentityContractVersion = 1" in service)
# The accessor FACADE is S.Data.TradeStaticV2; S.StaticDataV2 is the registry
# and has no recipe/material accessors — resolving through it silently returns
# nil for every pack (.18.165 bug class, now pinned by the Real-Lua harness).
require("service_facade_captured", "local StaticFacade = S.Data and S.Data.TradeStaticV2 or nil" in service)
require("service_facade_accessors", "StaticFacade:GetRecipeByLegacyName" in service)
require("service_no_registry_accessors", "local Static = S.StaticDataV2" not in service)
require("service_boundary", 'presentationBoundary = "service_only"' in service)
# Tail word -> legacy family mapping (verified working pairs from the legacy code).
require("service_tail_gilda", '"特制特产", tail = "Gilda Specialty"' in service)
require("service_tail_local", '"传统特产", tail = "Local Specialty"' in service)
require("service_tail_specialty", '"特产", tail = "Specialty"' in service)
# Region comes from the zone Authority (originZoneId -> nameEn + tradeQuality),
# never from localized zone text (the historical [十字星]→Hasla mis-map).
require("service_zone_authority", 'S.GameIds.Zone.ById' in service or "GameIds.Zone.ById" in service)
require("service_zone_quality", "tradeQuality" in service and "nameEn" in service)
require("service_no_localized_region_map", all(token not in strip_comments(service) for token in ('["十字星"]', '["黄金"]', "Hasla")))
# Shared families identical in every zone.
require("service_families", all(token in service for token in ("肥料特产", "蜂蜜", "奶酪", "药材", "时空碎片", "蓝盐商会运输品")))
# Live craft chain: capability-gated, product-verified, bounded single lane.
# Live craft reads must stay capability-gated. Locked semantically rather than by
# one literal call shape: the gate may be expressed per-capability or through a
# required-capability table, but every X2Craft getter used live has to pass it,
# and a refusal must carry the underlying reason instead of a bare label.
LIVE_CRAFT_CAPS = (
    "X2Craft:GetCraftTypeByItemType",
    "X2Craft:GetCraftMaterialInfo",
    "X2Craft:GetCraftProductInfo",
)
require("service_live_gated",
        all(cap in service for cap in LIVE_CRAFT_CAPS)
        and "IsCapabilityAllowed" in service)
require("service_gate_reason_propagated",
        "function CapabilityBlockReason" in service
        and "StaticState" in service
        and ("host_global_missing" in service and "method_missing_on_host" in service))
require("service_no_bare_block_label",
        "能力未放行：" not in strip_comments(service))
require("service_product_verify", "CollectProductItemTypes" in service and "productTrusted" in service)
require("service_single_lane", service.count("S.Scheduler:AddTask") == 1)
require("service_cancel_requester", "function M:CancelRequester(requester)" in service)
require("service_cache_readonly_peek", "function M:GetCachedLive(itemType)" in service)
require("service_health", "function M:GetHealth()" in service)

# --- Trade feature: row itemType capture + layered projection + lifecycle -----
require("trade_row_item_type", "local rowItemType = Number(item.itemType" in trade)
require("trade_projection_uses_row", "local function BuildTradeMaterialProjection(row)" in trade)
require("trade_static_layer", "identity:ResolveStatic(name, row.originZone)" in trade)
require("trade_live_peek", "identity:GetCachedLive(row.itemType)" in trade)
require("trade_ingredient_record_fix", "local function ResolveTradeIngredient(static, meta, ingredient)" in trade
        and "static:GetMaterialByCompactId(ingredient.compactId)" in trade)
require("trade_no_raw_meta_key_trust", "local item = type(meta) == \"table\" and meta[ingredient.materialKey] or nil" not in strip_comments(trade))
require("trade_honest_identity_states", "配方未匹配" in trade and "配方解析中…" in trade)
require("trade_live_request_pass", "local function RequestPendingLiveIdentities()" in trade
        and 'identity:RequestLive("life_trade", itemType' in trade)
require("trade_live_apply", "function TA:ApplyLiveIdentity(itemType)" in trade)
require("trade_identity_cancel_count", strip_comments(trade).count("TA:CancelLiveIdentities()") >= 2)
require("trade_projection_unresolved_count", "unresolvedIdentityCount = UnresolvedTradeIdentityCount(self.rows)" in trade)
require("trade_describe_identity", "function TA:DescribeIdentityState()" in trade)

# --- Ownership: X2Craft lives only in the identity service ---------------------
for label, source in (("bundle", trade), ("page", page), ("widget", widget), ("detail", detail)):
    require(f"ownership_{label}_no_x2craft", "X2Craft" not in strip_comments(source))

# --- Presentation/diagnostics surface the unresolved state --------------------
require("page_unresolved_hint", "projection.unresolvedIdentityCount" in page)
require("widget_unresolved_hint", "projection.unresolvedIdentityCount" in widget)
require("diag_identity_line", "DescribeIdentityState" in diagnostics and "配方 " in diagnostics)

# --- Class fence: every S.Services registration declares a boundary -----------
# The runtime gate blocks on missing presentationBoundary (RU-SVC-01 class);
# TradePayoutV3 shipped .18.163 without it and was only caught in-game. Sweep
# every service file here so the next service cannot repeat it.
service_dir = ROOT / "services"
missing_boundary = []
for path in sorted(service_dir.glob("*.lua")):
    source_text = path.read_text(encoding="utf-8-sig")
    if not re.search(r"S\.Services\.[A-Za-z_][A-Za-z0-9_]*\s*=", strip_comments(source_text)):
        continue
    if "presentationBoundary" not in source_text:
        missing_boundary.append(path.name)
require("class_fence_all_services_declare_boundary", not missing_boundary)

# --- Class fence: diagnostics describe helpers live on the Feature table ------
# The 跑商 row read feature.DescribeRequestState while the method only existed
# on Trade.Authority, so the row could never render. Lock feature-table
# reachability for every describe helper diagnostics consumes.
require("trade_feature_describe_request", "function Trade:DescribeRequestState() return TA:DescribeRequestState() end" in trade)
require("trade_feature_describe_identity", "function Trade:DescribeIdentityState() return TA:DescribeIdentityState() end" in trade)
require("bonds_feature_describe_cache", "function Bonds:DescribeDailyCache()" in trade)

# --- .18.168: dedicated trade diagnostics panel -------------------------------
# Quote debugging contract: the queue records the RAW native return shape and a
# bounded recent ring; the panel is a read-only FloatingSurface whose copyable
# report carries per-layer facts. No native access, no Commands, no persistence.
require("queue_raw_shape_capture", "local function ShapeOf(value)" in quote_queue and "Q.lastRawReturn = " in quote_queue)
require("queue_recent_ring", "recentMax = 12" in quote_queue and "table.insert(Q.recent, 1," in quote_queue)
require("queue_stats", 'stats = { attempts = 0, ready = 0, failed = 0 }' in quote_queue)
require("queue_describe_observability", "stats = Copy(self.stats)" in quote_queue and "recent = recent" in quote_queue)
panel_idx = next((i for i, line in enumerate(toc_lines) if "rs_v3_trade_diagnostics.lua" in line), None)
detail_idx = next((i for i, line in enumerate(toc_lines) if "rs_v3_trade_detail_floating.lua" in line), None)
pages_idx = next((i for i, line in enumerate(toc_lines) if "rs_v3_life_m16_pages.lua" in line), None)
require("panel_toc_active", panel_idx is not None)
require("panel_toc_order", None not in (panel_idx, detail_idx, pages_idx) and detail_idx < panel_idx < pages_idx)
require("panel_contract", "TradeDiagnosticsContractVersion = 1" in diag_panel)
require("panel_floating", "Floating:Create({" in diag_panel)
require("panel_read_only", "feature.Commands" not in strip_comments(diag_panel)
        and "AcquireConsumer" not in strip_comments(diag_panel))
require("panel_no_native", all(token not in strip_comments(diag_panel)
        for token in ("X2Auction", "X2Craft", "GetLowestPrice", "RequestQuote(")))
require("panel_copy_via_safe_chat", "S.SafeChat(report" in diag_panel)
require("panel_subscribes_quote_topic", "queue.Topic" in diag_panel)
require("page_opens_panel", 'id = "v3_trade_diagnostics"' in page and "panel:Open()" in page)
require("diag_row_raw_shape", "形态=" in diagnostics)

# --- .18.171: grade-probe quote protocol + identity lane priority -------------
# RU evidence (.18.170 report): GetLowestPrice returned nil for ALL 15 probes.
# The verified legacy semantics: nil at one grade = "no listing at that grade";
# the request must walk a bounded grade ladder and scan every return slot for
# the price. The identity lane must not sit on the starvable P3 maintenance lane.
require("queue_grade_ladder", "gradeIndex" in quote_queue and "request.grades" in quote_queue)
require("queue_grade_requeue", "table.insert(Q.queue, 1, request)" in quote_queue)
require("queue_scan_all_returns", "local function ScanPrice(" in quote_queue)
require("queue_no_listing_message", "档品质均无在售挂单" in quote_queue)
require("queue_default_ladder", "AddGrade(0)" in quote_queue)
require("trade_grade_candidates", "gradeCandidates[#gradeCandidates + 1] = math.floor(n)" in trade)
require("identity_lane_p2", ', false, M.owner, "P2", 1)' in service)

failures = [name for name, ok in checks if not ok]
for name, ok in checks:
    print(("PASS " if ok else "FAIL ") + name)
print(f"{len(checks) - len(failures)}/{len(checks)} checks passed")
sys.exit(1 if failures else 0)

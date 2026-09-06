#!/usr/bin/env python3
"""Static ownership/UX harness for .18.120 Trade detail + route favorites.

The restored behavior is intentionally local-only: favorites/sort live in the
Trade store, detail owns only a Presentation consumer, and all price requests
remain explicit Feature commands backed by PriceQuoteQueueV3.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
trade = (ROOT / "features/life/rs_life_m16_bundle.lua").read_text(encoding="utf-8-sig")
page = (ROOT / "presentation/v3/pages/rs_v3_life_m16_pages.lua").read_text(encoding="utf-8-sig")
widget = (ROOT / "presentation/v3/widgets/rs_v3_life_economy_widgets.lua").read_text(encoding="utf-8-sig")
detail = (ROOT / "presentation/v3/widgets/rs_v3_trade_detail_floating.lua").read_text(encoding="utf-8-sig")
toc = (ROOT / "toc.g").read_text(encoding="utf-8-sig")
gate = (ROOT / "core/rs_foundation_gate.lua").read_text(encoding="utf-8-sig")
acceptance = (ROOT / "presentation/v3/rs_v3_acceptance.lua").read_text(encoding="utf-8-sig")

checks = []
def require(name, cond): checks.append((name, bool(cond)))

# Authority/store: bounded stable route identity, not localized labels.
require("authority_v5", "Trade.Authority = { version = 5" in trade)
require("favorite_normalizer", "function Trade:NormalizeFavorites(value)" in trade)
require("favorite_bound_12", "if #result >= 12 then break end" in trade and "收藏路线最多保存 12 条" in trade)
require("favorite_numeric_identity", 'local key = tostring(from) .. ":" .. tostring(to)' in trade)
require("favorite_persisted", 'PersistLifeMutation(self, "trade_favorite_toggle"' in trade)
require("favorite_toggle", "function Trade:ToggleCurrentFavorite()" in trade)
require("favorite_select", "function Trade:SelectFavorite(key)" in trade)
require("favorite_projection", "favoriteItems = Trade:GetFavoriteItems()" in trade and "currentRouteFavorite = Trade:IsFavorite" in trade)
require("sort_persisted", "function Trade:SetSortMode(mode)" in trade and 'PersistLifeMutation(self, "trade_sort_mode"' in trade)
require("origin_change_clears_destination", "if Number(state.fromZone) ~= nextFrom then state.toZone = nil end" in trade)
require("row_session_selection", "function Trade:SelectRow(key)" in trade and "selectedKey = nil" in trade)
require("row_quote_explicit", "function Trade:QuoteRowMaterials(rowKey)" in trade and "self:QuoteMaterial(key)" in trade)
require("commands_public", all(token in trade for token in (
    "ToggleCurrentFavorite = function()", "SelectFavorite = function(_, key)", "SetSortMode = function(_, mode)",
    "SelectRow = function(_, key)", "QuoteRowMaterials = function(_, rowKey)",
)))

# Main page and HUD expose the same commands instead of duplicating state.
require("page_favorite_dropdown", 'id = "v3_trade_favorite_dropdown"' in page)
require("page_favorite_toggle", 'id = "v3_trade_favorite_toggle"' in page)
require("page_sort", 'id = "v3_trade_sort_mode"' in page)
require("page_trade_selectable", 'selectable = kind == "treasure" or kind == "trade"' in page)
require("page_opens_shared_detail", "S.UIV3.TradeDetailFloatingV3" in page and "detail:Open(row.key)" in page)
require("widget_favorite_dropdown", 'id = "v3_life_trade_widget_favorite"' in widget)
require("widget_favorite_toggle", 'id = "v3_life_trade_widget_favorite_toggle"' in widget)
require("widget_sort", 'id = "v3_life_trade_widget_sort"' in widget)
require("widget_selectable", "selectable = true" in widget and "onSelection = function(instance, row, Feature)" in widget)
require("widget_opens_shared_detail", "S.UIV3.TradeDetailFloatingV3" in widget and "detail:Open(row.key)" in widget)
require("widget_contract_v3", "S.UIV3.LifeEconomyWidgetsV3 = { version = 3" in widget)

# Floating detail has its own Demand lease while visible but no Native business API.
require("detail_contract", "TradeDetailContractVersion = 1" in detail)
require("detail_floating", "Floating:Create({" in detail and 'owner = "v3:trade_detail:floating"' in detail)
require("detail_consumer", 'feature:AcquireConsumer("floating:trade_detail")' in detail and 'feature:ReleaseConsumer("floating:trade_detail")' in detail)
require("detail_subscription", "S.Events:SubscribeInternal" in detail and "UnsubscribeInternalOwner" in detail)
require("detail_explicit_quote", "feature.Commands:QuoteRowMaterials(M.rowKey)" in detail)
require("detail_shared_favorite", "feature.Commands:ToggleCurrentFavorite()" in detail)
require("detail_no_direct_native", not re.search(r"\b(?:X2Store|X2Auction)\b|GetLowestPrice|RequestQuote\s*\(", re.sub(r"--[^\n]*", "", detail)))
require("toc_loaded", "presentation/v3/widgets/rs_v3_trade_detail_floating.lua" in toc)
gate_match = re.search(r"S\.FoundationGate\s*=\s*\{\s*version\s*=\s*(\d+)", gate, re.S)
require("gate_v113_plus", gate_match is not None and int(gate_match.group(1)) >= 113)
require("gate_trade_detail", '"v3_trade_detail_favorites_contract"' in gate and "TradeDetailContractVersion" in gate)
acceptance_match = re.search(r"S\.UIV3Acceptance\s*=\s*\{\s*version\s*=\s*(\d+)", acceptance, re.S)
require("acceptance_v68_plus", acceptance_match is not None and int(acceptance_match.group(1)) >= 68 and "TradeDetailFavoritesContractVersion = 1" in acceptance)

failed = [name for name, ok in checks if not ok]
if failed:
    print(f"TRADE_DETAIL_FAVORITES_HARNESS FAIL | {len(checks)-len(failed)}/{len(checks)}")
    for name in failed: print(" -", name)
    sys.exit(1)
print(f"TRADE_DETAIL_FAVORITES_HARNESS PASS | {len(checks)}/{len(checks)}")

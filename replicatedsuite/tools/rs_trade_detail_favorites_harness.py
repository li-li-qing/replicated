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

# Multi-line literals below are newline-sensitive: this checkout is CRLF on
# Windows (git core.autocrlf=true), so every source read normalizes to \n.
def read_lua(rel):
    return (ROOT / rel).read_text(encoding="utf-8-sig").replace("\r\n", "\n")

trade = read_lua("features/life/rs_life_m16_bundle.lua")
page = read_lua("presentation/v3/pages/rs_v3_life_m16_pages.lua")
widget = read_lua("presentation/v3/widgets/rs_v3_life_economy_widgets.lua")
detail = read_lua("presentation/v3/widgets/rs_v3_trade_detail_floating.lua")
toc = (ROOT / "toc.g").read_text(encoding="utf-8-sig")
gate = (ROOT / "core/rs_foundation_gate.lua").read_text(encoding="utf-8-sig")
acceptance = (ROOT / "presentation/v3/rs_v3_acceptance.lua").read_text(encoding="utf-8-sig")
identity_service = (ROOT / "services/rs_trade_material_identity_v3.lua").read_text(encoding="utf-8-sig")
diagnostics_panel = (ROOT / "presentation/v3/widgets/rs_v3_trade_diagnostics.lua").read_text(encoding="utf-8-sig")

checks = []
def require(name, cond): checks.append((name, bool(cond)))

# Authority/store: bounded stable route identity, not localized labels.
require("authority_v6", "Trade.Authority = { version = 6" in trade)
require("favorite_normalizer", "function Trade:NormalizeFavorites(value)" in trade)
require("favorite_bound_12", "if #result >= 12 then break end" in trade and "收藏路线最多保存 12 条" in trade)
require("favorite_numeric_identity", 'local key = tostring(from) .. ":" .. tostring(to)' in trade)
require("favorite_persisted", 'PersistLifeMutation(self, "trade_favorite_toggle"' in trade)
require("favorite_toggle", "function Trade:ToggleCurrentFavorite()" in trade)
require("favorite_select", "function Trade:SelectFavorite(key)" in trade)
require("favorite_projection", "favoriteItems = Trade:GetFavoriteItems()" in trade and "currentRouteFavorite = Trade:IsFavorite" in trade)
require("sort_persisted", "function Trade:SetSortMode(mode)" in trade and 'PersistLifeMutation(self, "trade_sort_mode"' in trade)
# .18.181: sort is a closed three-mode set (ratio/price/name) and name mode
# must float bracket-prefixed goods before everything else (byte compare alone
# would sink "[黄金]…" behind CJK names on this client).
require("sort_modes_closed_set", 'local TRADE_SORT_MODES = { ratio = true, price = true, name = true }' in trade
        and "mode = TRADE_SORT_MODES[mode] and mode or nil" in trade)
require("sort_name_bracket_first", 'return (name:find("^%[") ~= nil) and 1 or 0, name' in trade
        and "if ap ~= bp then return ap > bp end" in trade)
require("sort_store_normalized", "Trade.State.sortMode = TRADE_SORT_MODES[value.sortMode] and value.sortMode or \"ratio\"" in trade)
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
# Both surfaces render sort as a one-of-many segmented selector with the same
# three values; a regression back to a cycle button must fail here.
require("page_sort_segmented", 'RSUI:SegmentedSelector({\n            id = "v3_trade_sort_mode"' in page
        and '{ value = "name", text = "名字" }' in page)
require("page_trade_selectable", 'selectable = kind == "treasure" or kind == "trade"' in page)
require("page_opens_shared_detail", "S.UIV3.TradeDetailFloatingV3" in page and "detail:Open(row.key)" in page)
require("widget_favorite_dropdown", 'id = "v3_life_trade_widget_favorite"' in widget)
require("widget_favorite_toggle", 'id = "v3_life_trade_widget_favorite_toggle"' in widget)
require("widget_sort", 'id = "v3_life_trade_widget_sort"' in widget)
require("widget_sort_segmented", 'RSUI:SegmentedSelector({\n            id = "v3_life_trade_widget_sort"' in widget
        and '{ value = "name", text = "名字" }' in widget)
require("widget_selectable", "selectable = true" in widget and "onSelection = function(instance, row, Feature)" in widget)
require("widget_opens_shared_detail", "S.UIV3.TradeDetailFloatingV3" in widget and "detail:Open(row.key)" in widget)
require("widget_contract_v3", "S.UIV3.LifeEconomyWidgetsV3 = { version = 3" in widget)

# Floating detail has its own Demand lease while visible but no Native business API.
require("detail_contract", "TradeDetailContractVersion = 2" in detail)
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

# --- .18.175 player-facing wording -------------------------------------------
# Users are players on a Chinese RU client, not developers of this Suite. Raw
# data keys ("Chopped Produce"), internal status codes ("explicit_quote_required")
# and factor notation ("熟练×0.875") used to land straight on tables and HUD rows.
# Internal identifiers now live on diagnostics-only fields; these checks scan the
# player surfaces instead of matching one fixed string, so a reworded regression
# cannot slip through the way a literal-match fence would.
PLAYER_SURFACES = {
    "trade_detail_floating": detail,
    "life_m16_pages": page,
    "life_economy_widgets": widget,
}
# A player surface may *read* an internal code to decide what to show; it may not
# *emit* one. So the leak patterns are restricted to display-text positions:
# assignments into name/text/label fields and string concatenations. Comparisons
# (`if status == "quote_failed" then return "询价失败" end`) and table row keys stay
# legal -- an earlier literal-substring version flagged exactly those and was
# wrong, which is why this matches shapes rather than bare tokens.
# A player surface may *read* an internal code to decide what to show; it may
# not *emit* one. Matching display-text shapes (not bare tokens) keeps legal
# comparisons like `if status == "quote_failed" then return "询价失败" end` and
# table row keys out of the result -- a literal-substring version flagged those
# and was wrong.
_NL = chr(92) + 'n'          # two-char Lua/Python newline escape source
_INTERNAL = ('materialKey|internalKey|static_family|static_recipe|live_pending|'
             'explicit_quote_required|quote_failed|price_pending|identitySource|recipeLabel')
DISPLAY_ASSIGN_RE = re.compile(
    r'(?:name|text|label|title|summary|statusText)'
    + r'\s*=\s*' + '[^' + _NL + ']*?' + '(' + _INTERNAL + ')'
)
for surface_name, surface_text in PLAYER_SURFACES.items():
    body = re.sub(r'--[^' + _NL + ']*', '', surface_text)   # drop comments
    leaked = DISPLAY_ASSIGN_RE.findall(body)
    require(f"player_surface_clean_{surface_name}", not leaked)

# The material row must render a resolved display name, never the raw key.
require("material_row_uses_localized_name",
        'name = BoundedTradeText(displayName or "材料"' in trade
        and "internalKey = BoundedTradeText(materialKey" in trade)
require("localization_authority_used",
        'S.Localization:GetName("item"' in trade and "ResolveMaterialDisplayName" in identity_service)
require("product_display_resolver_exists",
        "function M:ResolveMaterialDisplayName" in identity_service
        and "function M:ResolveProductDisplayName" in identity_service)
require("unknown_status_not_echoed_verbatim",
        "function PlayerPriceStatusText" in detail and "暂无法估价" in detail)
require("no_factor_table_on_player_surface",
        "commerceMultiplier" not in detail and "packMultiplier" not in detail)

# Diagnostics keeps the internal detail -- that is its purpose. Asserting it still
# carries the tokens prevents a future "just delete the jargon" change from
# destroying the only place anyone can read real state from.
require("diagnostics_keeps_internal_detail",
        "internalKey or material.materialKey" in diagnostics_panel
        and "identityDetail" in diagnostics_panel)

failed = [name for name, ok in checks if not ok]
if failed:
    print(f"TRADE_DETAIL_FAVORITES_HARNESS FAIL | {len(checks)-len(failed)}/{len(checks)}")
    for name in failed: print(" -", name)
    sys.exit(1)
print(f"TRADE_DETAIL_FAVORITES_HARNESS PASS | {len(checks)}/{len(checks)}")

#!/usr/bin/env python3
"""Static ownership/observability harness for .18.164 Trade quote state.

材料询价 was locally wired (.18.82/.18.93/.18.120) but quote failures were
invisible: the queue failed closed into an endless 待询价 with no diagnostics.
This harness locks the shared per-itemType quote lifecycle state (queued /
inflight / ready / failed) in PriceQuoteQueueV3, its consumption by the Trade
material projection and the three quote entries, the diagnostics row, and the
Presentation ownership fences (no native auction access outside the service).
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
service = (ROOT / "services/rs_price_quote_queue_v3.lua").read_text(encoding="utf-8-sig")
trade = (ROOT / "features/life/rs_life_m16_bundle.lua").read_text(encoding="utf-8-sig")
page = (ROOT / "presentation/v3/pages/rs_v3_life_m16_pages.lua").read_text(encoding="utf-8-sig")
widget = (ROOT / "presentation/v3/widgets/rs_v3_life_economy_widgets.lua").read_text(encoding="utf-8-sig")
detail = (ROOT / "presentation/v3/widgets/rs_v3_trade_detail_floating.lua").read_text(encoding="utf-8-sig")
diagnostics = (ROOT / "core/rs_diagnostics.lua").read_text(encoding="utf-8-sig")
trade_panel = (ROOT / "presentation/v3/widgets/rs_v3_trade_diagnostics.lua").read_text(encoding="utf-8-sig")
detail_widget = (ROOT / "presentation/v3/widgets/rs_v3_trade_detail_floating.lua").read_text(encoding="utf-8-sig")
foundation_audit = (ROOT / "tools/rs_foundation_audit.py").read_text(encoding="utf-8-sig")
acceptance = (ROOT / "presentation/v3/rs_v3_acceptance.lua").read_text(encoding="utf-8-sig")

checks = []
def require(name, cond): checks.append((name, bool(cond)))

def strip_comments(text):
    return re.sub(r"--\[\[[\s\S]*?\]\]", "", re.sub(r"--[^\n]*", "", text))

# --- Shared queue: honest per-itemType lifecycle state -----------------------
require("service_state_map", "quoteStateByItemType = {}" in service)
require("service_last_completed", "lastCompleted = nil" in service)
require("service_queued_state", 'status = "queued", itemGrade = itemGrade, requester = requester, at = NowMs()' in service)
require("service_inflight_state", 'status = "inflight", itemGrade = request.itemGrade, requester = request.requester, at = NowMs()' in service)
require("service_ready_state", 'status = "ready", price = quote.value, priceSource = quote.source,' in service)
require("service_failed_state", 'status = "failed", code = tostring(status or "failed"), error = err,' in service)
require("service_state_accessor", "function Q:GetQuoteStateByItemType(itemType, itemGrade)" in service)
require("service_state_grade_filter", "tonumber(entry.itemGrade) ~= tonumber(itemGrade)" in service)
require("service_health_alias", "function Q:GetHealth()" in service)
require("service_describe_last", "lastCompleted = self.lastCompleted and Copy(self.lastCompleted) or nil" in service)
# Fail-closed price contract untouched: only ready completions may index a price.
require("service_price_fail_closed", 'if status == "ready" and quote ~= nil and pending.itemType ~= nil then' in service)
# Single drain lane unchanged: exactly one AddTask for the quote queue.
require("service_single_lane", service.count("S.Scheduler:AddTask") == 1)
# State reads must stay inside the service boundary (features call accessors).
require("service_no_external_state_write", all(
    token not in strip_comments(trade)
    for token in ("quoteStateByItemType[", "lastCompleted =")
))

# --- Trade feature: projection + commands ------------------------------------
require("trade_state_read", "quoteQueue:GetQuoteStateByItemType(itemType, itemGrade)" in trade)
require("trade_quote_pending_status", '"quote_pending"' in trade)
require("trade_quote_failed_status", '"quote_failed"' in trade)
require("trade_quote_error_row", "quoteError = quoteError ~= nil and BoundedTradeText(quoteError" in trade)
require("trade_detail_pending_text", "（询价" in trade and "（询价失败）" in trade)
require("trade_pending_counts_failed", 'material.costStatus == "explicit_quote_required" or material.costStatus == "quote_failed"' in trade)
require("trade_inflight_counter", "local function InFlightTradeQuoteCount(rows)" in trade)
require("trade_projection_inflight", "quoteInFlightCount = InFlightTradeQuoteCount(self.rows)" in trade)
require("trade_quote_material_dedup", "已在报价队列中" in trade)
require("trade_still_explicit_only", "function Trade:QuotePendingMaterials()" in trade and "function Trade:QuoteRowMaterials(rowKey)" in trade)

# --- Detail floating: six-honest-state rendering + failure reason -------------
require("detail_state_mapping", "询价排队中" in detail and '"询价失败", "red"' in detail)
require("detail_actionable_counts", 'costStatus == "explicit_quote_required" or costStatus == "quote_failed"' in detail)
require("detail_status_failed_segment", "· 询价失败 " in detail)
require("detail_failure_hint", "self.hint:SetText(\"询价失败原因：\"" in detail)
require("detail_static_hint_restored", "材料价格只有在用户显式询价后才读取" in detail)

# --- Page / HUD share the in-flight hint --------------------------------------
require("page_inflight_hint", "projection.quoteInFlightCount" in page)
require("widget_inflight_hint", "projection.quoteInFlightCount" in widget)

# --- Diagnostics: queue health is copyable ------------------------------------
require("diag_snapshot_health", "S.Services.PriceQuoteQueueV3:GetHealth()" in diagnostics)
require("diag_feature_row", 'FeatureRow("price_quote", "报价队列"' in diagnostics)
require("diag_last_completed_line", '"最近=" .. tostring(last.requester) .. "#" .. tostring(last.itemType)' in diagnostics)

# --- Ownership fences: Presentation/diagnostics never touch the native API ----
for label, source in (("page", page), ("widget", widget), ("detail", detail), ("diagnostics", diagnostics)):
    code = strip_comments(source)
    require(f"ownership_{label}_no_native_quote",
            "GetLowestPrice" not in code and "RequestQuote(" not in code and "X2Auction" not in code)

# --- .18.172: money coercion + name-search fallback + TTL cache --------------
# RU evidence is still that quotes come back empty, so every extraction path
# must go through the legacy-verified ToNumber semantics (comma-grouped strings
# and gold/silver/copper composites are real RU shapes, and bare tonumber()
# silently turns a live listing into a false "no listing").
require("service_to_money_before_users",
        service.index("local function ToMoney") < service.index("local function NormalizeQuote"))
require("service_scan_uses_to_money", "ToMoney(select(index, ...))" in service)
require("service_no_bare_tonumber_in_scan",
        "tonumber(select(index, ...))" not in strip_comments(service))
require("service_to_money_comma_string", 'value:gsub(",", "")' in service)
require("service_to_money_gsc_composite", "* 10000 + (silver or 0) * 100" in service)

# The verified legacy protocol falls back to ONE bounded name search after the
# whole grade ladder proves there is no direct listing. The un-tokened
# AUCTION_ITEM_SEARCHED edge stays owned by AuctionQueryV3: this service may only
# call its Search/GetSnapshot accessors, never subscribe or search natively.
require("fallback_begins_after_ladder", "BeginSearchFallback(request)" in service)
require("fallback_uses_auction_query_authority",
        "S.Services.AuctionQueryV3" in service.replace(" ", "")
        and 'query:Search("price_quote_fallback"' in service)
require("fallback_never_subscribes_native_event",
        "AUCTION_ITEM_SEARCHED" not in strip_comments(service))
require("fallback_identity_guard", "\u641c\u7d22\u7ed3\u679c\u8eab\u4efd\u4e0d\u5339\u914d" in service
        or "搜索结果身份不匹配" in service)
require("fallback_bid_price_is_estimate", '"name_search_bid"' in service)
require("fallback_no_second_lane", service.count("S.Scheduler:AddTask") == 1)
require("fallback_keyword_bounded", "#text > 64" in service)
require("trade_passes_search_name", "{ searchName = searchName }" in trade)
# The search keyword must come from the Localization Authority (never the raw
# English data key). Locked through the shared helper rather than one call-site
# spelling: LocalizedTradeItemName is the single wrapper and it queries
# S.Localization:GetName internally.
require("trade_search_name_via_localization",
        "local searchName = LocalizedTradeItemName(itemType, nil)" in trade
        and "function LocalizedTradeItemName(itemType, fallbackText)" in trade
        and 'S.Localization:GetName("item"' in trade)
# A canonical English data key must never become an auction keyword.
require("search_keyword_not_english_key",
        "local searchName = LocalizedTradeItemName(itemType, nil)" in trade
        and "searchName = materialKey" not in trade)

# Session TTL cache is a passive read model only; explicit quotes bypass it and
# a fallback estimate must never be reused as a fresh direct quote.
require("cache_ttl_bounded", "cacheTtlMs = 120000" in service)
require("cache_skips_fallback_origin", 'if origin ~= "fallback" then' in service)
require("cache_passive_peek_accessor", "function Q:PeekCached(itemType, itemGrade)" in service)

# --- .18.173: bounded protocol discrimination probe -------------------------
# .172 evidence: every GetLowestPrice return slot is a real nil while ok==true.
# That cannot be fixed by more parsing guesses; it needs one bounded control
# query against an itemType that must be listed. The probe may never become a
# price source, a second lane, or an unbounded loop.
require("probe_exists", "function Q:RunProtocolProbe()" in service)
require("probe_bounded_control_set", "PROBE_CONTROL_ITEM_TYPES" in service)
require("probe_self_terminates", "ProbeState.done = true" in service)
require("probe_attempt_cap", "maxAttempts" in service and "ProbeState.attempts >=" in service)
require("probe_rides_existing_lane", service.count("S.Scheduler:AddTask") == 1
        and "Q:RunProtocolProbe()" in service)
# .176 RU evidence: probe + real quote fired in the same drain tick and the second
# call died on "capability cooldown active: 500ms remaining". The probe must own
# its tick exclusively, and spacing must be measured against the monotonic clock
# rather than scheduler ticks (a budget-deferred tick can otherwise bunch two
# native calls far inside the official window).
def _probe_branch_returns(text):
    """The probe call site must be immediately followed by a bare `return`, and the
    queue pop must still come after it. An earlier version accepted "no pop found
    within the window", which passed even when the `return` was deleted -- exactly
    the regression this guard exists to catch."""
    # Locate the *call site* inside Drain, not the function definition header
    # (`function Q:RunProtocolProbe()` also contains this substring).
    drain_at = text.find("local function Drain()")
    if drain_at < 0:
        return False
    at = text.find("Q:RunProtocolProbe()", drain_at)
    if at < 0:
        return False
    after = text[at + len("Q:RunProtocolProbe()"):]
    head = after[:40]
    # allow only whitespace / a line comment between the call and `return`
    stripped = head.split("--")[0].strip().lstrip(")").strip()
    if not stripped.startswith("return"):
        return False
    pop = after.find("table.remove(Q.queue")
    ret = after.find("return")
    return pop >= 0 and ret >= 0 and ret < pop


require("probe_owns_its_tick", _probe_branch_returns(service))
require("wall_clock_cooldown_fence",
        "lastNativeCallAt" in service
        and "(now - Q.lastNativeCallAt) < Q.intervalMs" in service)
require("single_native_call_per_tick",
        service.count("Q.lastNativeCallAt = NowMs()") == 2)   # probe path + quote path
require("probe_shape_recorded", "shape = ShapeOf(value)" in service)
require("probe_exposed_in_describe", "protocolProbe =" in service)
require("probe_reported_in_diagnostics", "\u534f\u8bae\u63a2\u9488:" in trade_panel)

# The probe must never write the shared read model: it is evidence, not a quote.
_probe_body = service.split("function Q:RunProtocolProbe()")[1].split("function Q:GetProtocolProbe()")[0] \
    if "function Q:RunProtocolProbe()" in service else ""
require("probe_never_writes_read_model",
        _probe_body != ""
        and "pricesByItemType" not in _probe_body
        and "quoteStateByItemType" not in _probe_body
        and "CompletePending" not in _probe_body
        and "Q.snapshots" not in _probe_body)

# --- .18.174: forward-reference class eliminated by a standing gate ---------
# .173's own report exposed that its probe never produced results: RunProtocolProbe
# called ScanPrice/Publish defined later in the file, so Drain died on every tick
# (尝试=0 while 排队=15). The same class had already broken the .172 name-search
# fallback (CompletePending used before definition) -- that path was dead code the
# whole time. Text fences and luaparser cannot see this; the gate must be static
# analysis of local declaration order.
require("probe_after_its_dependencies",
        service.index("local function ScanPrice") < service.index("function Q:RunProtocolProbe()")
        and service.index("local function Publish()") < service.index("function Q:RunProtocolProbe()"))
require("fallback_after_complete_pending",
        service.index("local function CompletePending") < service.index("function Q:_CheckFallback()"))
require("local_order_gate_exists",
        (ROOT / "tools/rs_lua_local_order_audit.py").is_file())
require("local_order_gate_wired",
        "rs_lua_local_order_audit.py" in foundation_audit)

# --- .18.177: the fallback path is the ONLY one that can price materials ------
# Legacy proof (参考的项目1): QuoteSelectedPack -> Auction:QuotePack walks the grade
# ladder and, on total nil, falls back to a name search whose first-row bidPrice
# becomes the material cost. GetLowestPrice returning all-nil on RU therefore does
# NOT mean "unpriceable" -- it means our fallback never actually ran. Three bugs
# made it dead code, and no existing check caught any of them:
#   1) CompletePending forward reference (.174 fixed the crash but not the gap)
#   2) retrying Search while AuctionQueryV3 still holds its pending slot can only
#      ever be rejected, so three guaranteed failures ended in "unquotable"
#   3) an identity guard that failed closed on rowType==nil, i.e. on the current
#      RU client's unreadable GetSearchedItemInfo shape, rejected every real hit
require("fallback_no_retry_while_waiting",
        'if status == "waiting"' in service
        and "BeginSearchFallback(pending)" not in service.split('if status == "waiting"')[1].split("end")[0])
require("fallback_waits_on_deadline", "fallbackDeadlineAt" in service)
require("fallback_identity_guard_allows_unknown_shape",
        "rowType ~= nil and math.floor(rowType) ~= expected" in service)
require("fallback_name_cross_check", "搜索结果名称不符" in service)
# (superseded by attempts_only_for_direct_probe below: the .178 version indexed a
# duplicate fallback branch that the reachability fix removed.)

# The legacy chain must stay reachable end to end: ladder exhausted -> search ->
# first-row bid price -> ready with an explicit estimate provenance.
require("legacy_chain_reachable",
        "BeginSearchFallback(request)" in service
        and '"name_search_bid"' in service
        and 'origin ~= "fallback"' in service)   # estimate must not enter the TTL cache

# --- .18.179: fallback polling must be REACHABLE ------------------------------
# .178's own report proved a structural stall rather than a wrong predicate:
# 已报=0 AND 失败=0 with one request parked in flight. After the ladder exhausted,
# BeginSearchFallback left Q.pending pointing at that request, so every following
# Drain exited at the generic `if Q.pending ~= nil then return end` long before
# the polling branch -- an unreachable code path no text-order check could see.
# Lock reachability by line position inside Drain, not by mere presence of both.
_drain_body = service.split("local function Drain()")[1] if "local function Drain()" in service else ""
_pending_guard = _drain_body.find("if Q.pending ~= nil")
_fallback_service = _drain_body.find('Q.pending.fallbackState == "searching"')
_queue_pop = _drain_body.find("table.remove(Q.queue")
require("fallback_serviced_before_pending_return",
        _drain_body != "" and _pending_guard >= 0 and _fallback_service >= 0
        and _queue_pop >= 0
        and _pending_guard < _fallback_service < _queue_pop)
require("no_duplicate_fallback_branch",
        _drain_body.count('fallbackState == "searching"') == 1)
# The attempt counter must stay on the direct-probe path only, otherwise a long
# fallback wait inflates stats.attempts and the report stops being trustworthy.
require("attempts_only_for_direct_probe",
        _drain_body.find("Q.stats.attempts = Q.stats.attempts + 1") > _queue_pop)

# --- .18.180: persistent reference-price table -------------------------------
# A paced auction search is slow, so the player must not wait for it every
# session: confirmed prices persist and replay immediately, then a live quote
# replaces them. User-locked decisions that must not regress silently:
# never expires (listings are manipulable, so an old sample stays visibly old),
# keyed by itemType+grade, bounded history, per-account runtime data that is
# never shipped inside the addon package.
require("reference_store_registered",
        'StoreId = "v3.trade_reference_prices"' in service
        and "RegisterV3Store" in service)
require("reference_key_includes_grade",
        'tostring(id) .. ":" .. tostring(grade or -1)' in service)
require("estimate_never_persisted",
        'source == "name_search_bid"' in service
        and "estimate_not_persisted" in service)
require("reference_samples_bounded", "MAX_REFERENCE_SAMPLES" in service)
require("reference_load_failure_does_not_clear_disk",
        'status ~= true and status ~= "empty"' in service)
require("reference_write_is_coalesced",
        "MarkDirty(Q.StoreId, 1200" in service)
# Fresh session quotes win over stored values; a reference must be labelled.
require("live_wins_over_reference",
        'priceProvenance ~= "reference"' in trade)
require("reference_status_is_distinct",
        "quoted_reference" in trade
        and "\u53c2\u8003\u4ef7" in detail_widget)
# Backlog counting must ignore materials already covered by a reference price,
# otherwise the quote button inflates with work nobody asked for.
require("reference_not_counted_as_backlog",
        'material.costStatus == "quoted_reference"' not in trade)
# Persistence invariant: no raw SaveData call from a service.
require("no_raw_savedata_in_service",
        "SaveData" not in strip_comments(service))
# --- Existing acceptance contracts survive ------------------------------------
require("acceptance_pending_count_contract", "tradeProjection.pendingQuoteCount == nil" in acceptance)
require("acceptance_quote_commands", "QuotePendingMaterials" in acceptance and "QuoteRowMaterials" in acceptance)

failures = [name for name, ok in checks if not ok]
for name, ok in checks:
    print(("PASS " if ok else "FAIL ") + name)
print(f"{len(checks) - len(failures)}/{len(checks)} checks passed")
sys.exit(1 if failures else 0)

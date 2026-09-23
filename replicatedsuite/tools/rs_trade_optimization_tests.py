#!/usr/bin/env python3
"""Static/geometry regressions for Trade optimization .18.295.

These checks intentionally avoid mocking ArcheRage native calls. They protect the
architecture contracts that can be verified off-client: historical Store
compatibility, one-lane scheduling, event-driven observation, bounded local
projection and opt-in TableView tail fitting. RU native acceptance/callback
semantics still require the module diagnostics captured in game.
"""
from __future__ import annotations

from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = (ROOT / "features/life/rs_life_m16_bundle.lua").read_text(encoding="utf-8")
STATIC = (ROOT / "data/rs_trade_static_v2.lua").read_text(encoding="utf-8")
TABLE = (ROOT / "ui/framework/rs_ui_data_views.lua").read_text(encoding="utf-8")
PAGE = (ROOT / "presentation/v3/pages/rs_v3_life_m16_pages.lua").read_text(encoding="utf-8")
WIDGET = (ROOT / "presentation/v3/widgets/rs_v3_life_economy_widgets.lua").read_text(encoding="utf-8")
DETAIL = (ROOT / "presentation/v3/widgets/rs_v3_trade_detail_floating.lua").read_text(encoding="utf-8")
DIAGNOSTICS = (ROOT / "presentation/v3/widgets/rs_v3_trade_diagnostics.lua").read_text(encoding="utf-8")
REGISTRY = (ROOT / "features/rs_feature_registry.lua").read_text(encoding="utf-8")
FOUNDATION = (ROOT / "presentation/v3/pages/rs_v3_foundation_pages.lua").read_text(encoding="utf-8")
PRODUCT_IDS = (ROOT / "data/ids/rs_trade_product_ids.lua").read_text(encoding="utf-8")
MATERIALS = (ROOT / "data/rs_trade_materials.lua").read_text(encoding="utf-8")
MATERIAL_IDENTITY = (ROOT / "services/rs_trade_material_identity_v3.lua").read_text(encoding="utf-8")
ZONE_IDS = (ROOT / "data/ids/rs_zone_ids.lua").read_text(encoding="utf-8")
BOOT = (ROOT / "replicatedsuite.lua").read_text(encoding="utf-8")


def require(cond: bool, name: str) -> None:
    if not cond:
        raise AssertionError(name)
    print(f"PASS {name}")


def section(text: str, begin: str, end: str) -> str:
    i = text.index(begin)
    j = text.index(end, i)
    return text[i:j]


def adaptive_tail(viewport: float, count: int, base: float, gap: float, soft_min: float, soft_max: float):
    """Python mirror of RSUI ResolveAdaptiveTailRowHeight for geometry regression."""
    h = max(1.0, float(viewport))
    count = max(0, int(count))
    base = max(12.0, float(base))
    gap = max(0.0, float(gap))
    soft_min = max(12.0, float(soft_min))
    soft_max = max(soft_min, float(soft_max))
    if count <= 0:
        return base, 0, h
    hard_min = 12.0
    max_candidate = min(count, 32, max(1, int((h + gap) // (hard_min + gap))))
    best = None
    for rows in range(1, max_candidate + 1):
        candidate = (h - max(0, rows - 1) * gap) / rows
        if candidate < hard_min:
            continue
        score = abs(candidate - base)
        if candidate < soft_min:
            score += (soft_min - candidate) * 2.5
        if candidate > soft_max:
            score += (candidate - soft_max) * 2.5
        score -= rows * 0.0001
        if best is None or score < best[0]:
            best = (score, candidate, rows)
    if best is None:
        height = max(hard_min, min(base, h))
        return height, 1, max(0.0, h - height)
    _, height, rows = best
    if height > soft_max and count == rows:
        height = soft_max
    used = rows * height + max(0, rows - 1) * gap
    return height, rows, max(0.0, h - used)


def main() -> int:
    # Build/version and historical Store boundary.
    require("v3-m1.16.0.18.295-trade-native-lease-headroom" in BOOT, "build tag advanced")
    require('preferenceStoreId = "v3.trade_preferences"' in BUNDLE, "trade preferences split into independent store")
    old_store = section(BUNDLE, 'RegisterStore(Trade.storeId, "v3.life.trade"', 'RegisterStore(Trade.preferenceStoreId')
    require("schemaVersion" not in old_store, "historical trade registration still uses shared schema1 helper")
    require("Trade.State.fromZone" in old_store and "Trade.State.widgetWindow" in old_store, "historical route/window fields preserved")
    require('RegisterStore(Trade.preferenceStoreId, "v3.life.trade.preferences"' in BUNDLE, "new preference store registered")
    require('"v3.trade_preferences"' in FOUNDATION, "trade preference store participates in persistence acceptance")

    # Bound/non-market resources retain recipe requirements without auction fan-out.
    require(re.search(r'\["Gilda Star"\].*includeInCost=false.*auctionable=false.*costKind="bound_resource".*itemType=23633', STATIC) is not None,
            "Gilda Star is a verified bound crafting resource")
    require('materialKeyByItemId' in STATIC and 'function S.Data.TradeStaticV2:GetMaterialByItemId' in STATIC,
            "trade material static authority supports itemType reverse lookup")
    require('StaticFacade:GetMaterialByItemId(itemType)' in MATERIAL_IDENTITY,
            "live craft ingredient resolves curated bound/non-market policy by itemType")
    require('record = static:GetMaterialByItemId(ingredient.itemType)' in BUNDLE,
            "trade projection preserves curated itemType cost policy for detached live material rows")
    require('status = costKind == "bound_resource" and "bound_resource" or "non_market_resource"' in BUNDLE,
            "excluded resource semantics replaced with explicit resource states")
    require('row.materialCostBasis = (row.boundResourceCount > 0 or row.nonMarketResourceCount > 0) and "gold_only_with_resources"' in BUNDLE,
            "profit labels gold-only basis when extra resources exist")

    # User-focused local projection; native still returns route bundle.
    require("function Trade:SetViewMode" in BUNDLE and "function Trade:ToggleTrackedProduct" in BUNDLE, "tracked/all/cargo commands exist")
    rebuild = section(BUNDLE, "function TA:RebuildDisplayRows", "function TA:RefreshCommerceSkill")
    require('if mode == "all" or Trade:IsTrackedProduct(raw.itemType) then' in rebuild, "tracked view filters before heavy display enrichment")
    require(rebuild.index('if mode == "all" or Trade:IsTrackedProduct(raw.itemType) then') < rebuild.index('ApplyTradeDisplayModeToRow(row)'),
            "heavy row projection occurs only after visibility filter")
    require("TA.rawRows" in BUNDLE and "rawRowCount" in BUNDLE, "raw server snapshot separated from display rows")

    # Route scheduler: one native lane; RU native cooldown is respected, while cached routes render immediately.
    request = section(BUNDLE, "function TA:Request(force, reason)", "function TA:OnCargoRatio")
    require('if self.inFlight ~= nil then' in request and 'self.pendingRoute = { from = from, to = to' in request,
            "SingleFlight keeps latest pending route")
    require('if cooldownRemaining > 0 then' in request and 'route_request_deferred_cooldown' in request,
            "all native route calls respect the proven RU cooldown window")
    require('self:RestoreRouteCache(from, to, "route_cache_before_cooldown")' in request,
            "route switch restores a session snapshot before cooldown deferral")
    require('return TA:Request(true, "route_change")' in BUNDLE, "destination switch uses route_change reason")
    require("requestTrace" in BUNDLE and "cooldown_deferred" in request, "cooldown scheduling evidence is diagnosed")

    # Native callback ownership must outlive transient page/widget Consumer churn. The 18.294 field report
    # proved native_accepted -> no_consumers could otherwise discard the only callback subscription.
    reconcile = section(BUNDLE, "function Trade:ReconcileDemand", "function Trade:Enable")
    require('Trade.nativeRatioEventOwner = { Id = "life_trade.native_ratio_callback" }' in BUNDLE,
            "trade has a dedicated lightweight native-callback owner")
    require('function Trade:EnsureNativeRatioSubscription()' in BUNDLE and 'self.nativeRatioEventOwner' in BUNDLE,
            "native ratio callback subscription is independent from business observation events")
    require('local preserveNativeFlight = type(TA.inFlight) == "table" or type(TA.timedOutFlight) == "table"' in reconcile,
            "Consumer release detects an accepted native flight")
    require('consumer_release_preserve_flight' in reconcile and 'TA.inFlight = nil' not in section(reconcile, 'elseif beforeCount > 0 and afterCount <= 0 then', 'end\n    return true'),
            "Consumer release preserves accepted in-flight ownership instead of orphaning the callback")
    require('stale_callback_consumed_no_consumers' in BUNDLE,
            "late stale callback cannot launch a background replacement route after consumers disappear")

    # Automatic refresh leaves user-interaction headroom instead of continuously occupying a 5s native window.
    auto = section(BUNDLE, "function TA:ArmAutoRefresh", "function TA:ArmCargoPump")
    require('TA.autoRefreshTargetMs = 10000' in BUNDLE and 'TA.autoRefreshCooldownFactor = 2' in BUNDLE,
            "automatic route refresh has an explicit interaction headroom budget")
    require('cooldownTarget = math.max(0, tonumber(self.lastNativeCooldownMs) or 0) * math.max(1, tonumber(self.autoRefreshCooldownFactor) or 2)' in auto,
            "automatic refresh waits at least two native cooldown windows")

    # Timeout quarantine: callback has no request id, so a timed-out lane must not be
    # immediately reused and let its late payload attach to the next route/cargo request.
    timeout_arm = section(BUNDLE, "function TA:ArmRequestTimeout", "function TA:Request(force, reason)")
    timeout_drain = section(BUNDLE, "function TA:ArmTimeoutDrain", "function TA:CancelDeferredRequest")
    on_ratio = section(BUNDLE, "function TA:OnRatio", "function TA:DescribeRequestState")
    require('timeoutDrainMs = 2000' in BUNDLE and 'function TA:GetTimeoutDrainRemaining()' in BUNDLE,
            "timed-out native lane has a bounded late-callback drain window")
    require('return TA:ArmTimeoutDrain(flight)' in timeout_arm,
            "route/cargo response timeout enters quarantine before native lane reuse")
    cargo_timeout = section(timeout_arm, 'if tostring(flight.kind or "route") == "cargo" then', 'local currentFrom, currentTo')
    require('cargo.queueIndex' not in cargo_timeout,
            "cargo timeout does not advance queue before late-callback drain resolves")
    require('cargo.queueIndex = (tonumber(cargo.queueIndex) or 1) + 1' in timeout_drain
            and 'cargo_request_timeout_committed' in timeout_drain,
            "cargo timeout advances exactly at drain expiry when no late callback arrived")
    require('timeoutDrainRemaining = self:GetTimeoutDrainRemaining()' in request
            and 'if self.inFlight == nil and type(self.timedOutFlight) == "table" then' in request
            and 'route_request_deferred_timeout_drain' in request,
            "new route request cannot steal a quarantined timed-out callback even if scheduler is late")
    require('flight = self.timedOutFlight' in on_ratio and 'acceptedLate = true' in on_ratio
            and 'self:CancelTimeoutDrain()' in on_ratio,
            "late callback is consumed by its timed-out flight and cancels quarantine")

    # Stale-while-refresh: same route is not blanked before request.
    require('local keepRows = self:HasRawRowsForRoute(from, to)' in request, "same-route refresh detects reusable snapshot")
    require('self.status, self.error = keepRows and "refreshing" or "loading", nil' in request,
            "same-route refresh keeps old rows visible")

    # Event-driven proficiency/backpack updates; never a Trade Tick loop.
    require('SubscribeOptional("UNIT_EQUIPMENT_CHANGED"' in BUNDLE, "equipment change event subscribed")
    require('AddOneShot(self.equipmentRefreshTask, 220' in BUNDLE, "equipment refresh is debounced")
    require('SubscribeOptional("ENTER_ANOTHER_ZONEGROUP"' in BUNDLE, "zone transition event subscribed")
    require('X2Equipment:GetEquippedItemType' in BUNDLE and 'EST_BACKPACK' in BUNDLE, "backpack identity uses equipment ItemID authority")
    require('not identityChanged and (oldStatus == "scanning" or oldStatus == "complete")' in BUNDLE,
            "unrelated equipment changes preserve active/completed cargo scan state")
    product_names = set(re.findall(r'RegisterProduct\(\d+,\s*"([^"]+)"', PRODUCT_IDS))
    recipe_names = set(re.findall(r'^\s*\["([^"]+)"\]\s*=\s*\{', MATERIALS, re.M))
    zone_names = re.findall(r'\{\s*\d+,\s*"[^"]+",\s*"([^"]+)"', ZONE_IDS)
    require(len(product_names) == 98 and not (product_names - recipe_names), "all 98 verified trade-product ItemIDs resolve to recipe names")
    require(all(any(name.startswith(zone + " ") for zone in zone_names) for name in product_names),
            "all verified trade products resolve to an origin-zone prefix")
    trade_slice = section(BUNDLE, "-- Trade", "-- Bonds")
    require("OnUpdate" not in trade_slice and "OnTick" not in trade_slice, "trade slice introduces no Tick/OnUpdate polling")

    # Cargo route scan shares the same inFlight lane and is serial/cooldown paced.
    cargo_start = section(BUNDLE, "function TA:StartCargoNativeRequest", "function TA:ArmRequestTimeout")
    require('if self.inFlight ~= nil then return false, "Native 查询通道占用中" end' in cargo_start,
            "cargo scan cannot overlap native route request")
    require(cargo_start.count('Action("X2Store:GetSpecialtyRatioBetween"') == 1, "cargo request issues one native call per pump")
    pump = section(BUNDLE, "function TA:PumpCargoQueue", "function TA:RecordNativeAccepted")
    require('if remaining > 0 then return self:ArmCargoPump(remaining + 50) end' in pump, "cargo background scan obeys throttle")
    require('cargoMinIntervalMs = 1000' in BUNDLE and 'tonumber(self.cargoMinIntervalMs) or 1000' in BUNDLE,
            "cargo background scan has a defensive minimum native interval")
    require('if type(self.pendingRoute) == "table" then' in pump, "user route pending preempts cargo queue")
    require('if cargo.scanning ~= true then return true end' in pump, "stale cargo pump cannot resurrect a stopped scan")
    require('if type(self.timedOutFlight) == "table" then return true end' in pump,
            "cargo pump cannot reopen native lane while timeout quarantine ownership exists")
    require('function TA:StopCargoScan(reason, preserveStatus)' in BUNDLE and 'cargo.generation = (tonumber(cargo.generation) or 0) + 1' in BUNDLE,
            "stopping cargo invalidates late native callbacks by generation")
    cargo_scan = section(BUNDLE, "function TA:StartCargoScan", "function TA:PumpCargoQueue")
    require('self:CancelCargoTasks()' in cargo_scan, "new cargo scan cancels stale pump/rescan one-shots before rebuilding queue")
    require('self:StopCargoScan("cargo_not_ready", true)' in cargo_scan and 'self:StopCargoScan("cargo_origin_missing", true)' in cargo_scan,
            "cargo observation failure invalidates scan generation without overwriting truthful status")
    cargo_result = section(BUNDLE, "function TA:OnCargoRatio", "function TA:OnRatio")
    require('if cargo.scanning ~= true then return true end' in cargo_result, "late cargo callback cannot re-arm a stopped scan")

    # Localized bounded text must preserve UTF-8 codepoint boundaries.
    require('local function TradeUtf8Prefix' in BUNDLE and 'string.byte(text, index + offset)' in BUNDLE,
            "trade material truncation is UTF-8 boundary aware")
    require('string.sub(text, 1, limit)' not in section(BUNDLE, "local function BoundedTradeText", "local function ResolveTradeIngredient"),
            "bounded trade text no longer byte-cuts localized codepoints")
    require('local function Utf8Prefix' in DIAGNOSTICS and 'Utf8Prefix(report, REPORT_MAX_BYTES)' in DIAGNOSTICS,
            "trade diagnostics report truncation preserves localized UTF-8")
    require('timeoutDrainRemainingMs' in DIAGNOSTICS and 'timedOutRoute' in DIAGNOSTICS,
            "trade diagnostics exposes timeout quarantine evidence")

    # Commerce multiplier is owned by TradePayoutV3 and merely projected to both UIs.
    projection = section(BUNDLE, "function TA:GetProjection", "local function NormalizeTradeState")
    require('commerceMultiplier = payoutService:GetCommerceMultiplier' in projection and 'commerceMultiplier = commerceMultiplier' in projection,
            "trade projection exposes the payout-service commerce multiplier")
    require('skill / 10000' not in PAGE and 'skill / 10000' not in WIDGET,
            "trade presentation no longer duplicates commerce business formula")
    require('commerceMultiplier = commerceMultiplier' in projection,
            "commerce multiplier remains available as detached projection even when compact UI hides it")

    # Sparse live-identity cache must obey its declared memory budget.
    require('#M.liveCache' not in MATERIAL_IDENTITY, "trade live identity cache does not use Lua length on a hash table")
    require('local function TrimLiveCacheForInsert()' in MATERIAL_IDENTITY and 'count = count + 1' in MATERIAL_IDENTITY,
            "trade live identity cache counts sparse entries explicitly")
    require('local evictKey = oldestFailedKey or oldestAnyKey' in MATERIAL_IDENTITY,
            "trade live identity cache remains bounded even when every cached entry is ready")

    # Explicit quotes must accept live-craft materials that have an itemType but no static English key.
    quote_slice = section(BUNDLE, "local function ResolveTradeQuoteIdentity", "-- Diagnostics reads describe helpers")
    require('itemType, itemGrade = tonumber(material.itemType), tonumber(material.itemGrade)' in quote_slice,
            "material quote identity prefers projected itemType/itemGrade authority")
    require('selected[#selected+1]={materialKey=materialKey,itemType=id,itemGrade=grade}' in quote_slice,
            "material quote batch carries live material identities instead of static keys only")
    require('self:QuoteMaterial(material,mode,batch)' in quote_slice,
            "material quote batch submits detached identity records")

    # Automatic refresh is Demand-scoped and one-shot scheduled.
    require('requestAutoTask = "v3_trade_route_auto_refresh"' in BUNDLE, "auto refresh has dedicated scheduler task")
    require('AddOneShot(self.requestAutoTask' in BUNDLE and 'TA:Request(false, "auto_refresh")' in BUNDLE,
            "auto refresh uses one-shot scheduler rather than loop")
    require("TA:CancelAutoRefresh()" in section(BUNDLE, "function Trade:ReconcileDemand", "function Trade:Enable"),
            "auto refresh releases when consumers drop to zero")

    # UI tail-fit is reusable but opt-in; trade surfaces opt in.
    require("ResolveAdaptiveTailRowHeight" in TABLE and 'rowFitMode == "adaptive_tail"' in TABLE,
            "TableView exposes reusable adaptive-tail geometry")
    require('rowFitMode = kind == "trade" and "adaptive_tail" or "fixed"' in PAGE, "main trade table opts into adaptive tail")
    require('rowFitMode = spec.featureName == "Trade" and "adaptive_tail" or "fixed"' in WIDGET, "trade HUD table opts into adaptive tail")
    require('rowFitMode = "adaptive_tail"' in DETAIL, "trade detail material table opts into adaptive tail")
    require('local callback = c.onSelectionChanged' in TABLE and 'local callback = c.onItemActivated' in TABLE,
            "TableView dispatch reads post-construction callbacks at runtime")
    require('tableView.onItemActivated = function(item, index, key, view, reason)' in PAGE and 'QuoteRowMaterials(row.key)' in PAGE,
            "main trade table double-click path reaches single-row quote command")
    require('function Trade:SelectFavorite(key)' in BUNDLE and 'PersistLifeMutation(self, "trade_select_favorite"' in BUNDLE
            and 'TA:RestoreRouteCache(from, to, "favorite_route_cache")' in BUNDLE,
            "favorite route selection is atomic and restores session cache before native refresh")
    h, rows, tail = adaptive_tail(223, 20, 26, 0, 22, 30)
    require(22 <= h <= 30 and rows > 0 and abs(tail) < 1e-9 and abs(rows * h - 223) < 1e-6,
            "adaptive tail removes representative 223px bottom gap")
    h, rows, tail = adaptive_tail(235, 8, 26, 0, 22, 30)
    require(rows == 8 and 22 <= h <= 30 and abs(tail) < 1e-9 and abs(rows * h - 235) < 1e-6,
            "adaptive tail stretches a near-full eight-row trade list instead of leaving one-row blank tail")
    h, rows, tail = adaptive_tail(235, 2, 26, 0, 22, 30)
    require(rows == 2 and h <= 30 and tail > 100,
            "adaptive tail preserves genuine content-shortage whitespace instead of over-stretching a tiny list")

    # Registry metadata matches implementation dependencies.
    life_trade = section(REGISTRY, 'Add("life_trade"', 'Add("life_bonds"')
    require('"X2Equipment:GetEquippedItemType"' in life_trade, "feature registry exposes equipment dependency")
    require("v3.trade_preferences" in life_trade and "SingleFlight" in life_trade, "feature metadata documents new authority boundaries")

    print("TRADE OPTIMIZATION REGRESSION: PASS")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"FAIL {exc}", file=sys.stderr)
        raise

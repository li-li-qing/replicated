#!/usr/bin/env python3
"""Static contract harness for .18.119 Trade/Craft/Task continuation.

This harness intentionally checks ownership and negative-space rules as well as
UI presence: Trade full-ratio comparison must stay local, commerce proficiency
must remain observation-only, and Craft market requests must remain explicit and
rate-limited through PriceQuoteQueueV3 rather than leaking into ordinary Refresh.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
trade = (ROOT / "features/life/rs_life_m16_bundle.lua").read_text(encoding="utf-8-sig")
payout = (ROOT / "services/rs_trade_payout_v3.lua").read_text(encoding="utf-8-sig")
business = (ROOT / "features/rs_business_bridge.lua").read_text(encoding="utf-8-sig")
trade_page = (ROOT / "presentation/v3/pages/rs_v3_life_m16_pages.lua").read_text(encoding="utf-8-sig")
trade_widget = (ROOT / "presentation/v3/widgets/rs_v3_life_economy_widgets.lua").read_text(encoding="utf-8-sig")
business_page = (ROOT / "presentation/v3/pages/rs_v3_business_pages.lua").read_text(encoding="utf-8-sig")
task_authority = (ROOT / "features/life/tasks/rs_task_authority.lua").read_text(encoding="utf-8-sig")
task_page = (ROOT / "presentation/v3/pages/rs_v3_task_page.lua").read_text(encoding="utf-8-sig")

checks = []

def require(name: str, condition: bool):
    checks.append((name, bool(condition)))

require("trade_full_ratio_130", "local TRADE_FULL_RATIO = 130" in trade)
require("trade_persisted_ratio_mode", 'ratioMode = "current"' in trade and '"trade_ratio_mode"' in trade)
require("trade_persisted_commerce_mode", 'commerceMode = "observe"' in trade and '"trade_commerce_mode"' in trade)
require("trade_commerce_official_getter", 'Call("X2Ability:GetAllMyActabilityInfos"' in trade)
require("trade_commerce_projection_working_formula", 'commercePriceFormulaStatus = "supplied_working_v1"' in trade and 'packPriceMultiplierStatus = "supplied_working_v1"' in trade)
require("trade_keeps_current_ratio_fact", "currentRatio = ratio" in trade and "row.currentRatio = current" in trade)
require("trade_local_rebuild", "function TA:RebuildDisplayRows(reason)" in trade)
require("trade_main_mode_controls", 'id = "v3_trade_ratio_mode"' in trade_page and 'id = "v3_trade_commerce_mode"' in trade_page)
require("trade_widget_mode_controls", 'id = "v3_life_trade_widget_ratio_mode"' in trade_widget and 'id = "v3_life_trade_widget_commerce_mode"' in trade_widget)
require("trade_payout_isolated_service", 'function P:Estimate(spec)' in payout and '1 + (skill / 10000 * 0.05)' in payout)
require("trade_pack_multiplier_restored", 'S.Data and S.Data.TradeNameMultipliers' in payout)
require("trade_larder_key_resolver_restored", 'function P:ResolvePriceKey(destination, itemName, originZoneName)' in payout)
require("trade_bundle_uses_payout_service", 'S.Services and S.Services.TradePayoutV3' in trade and 'row.priceBreakdown' in trade)

craft_read_start = business.find("local function CraftRead(feature)")
craft_commands_start = business.find("local function CraftCommands()")
craft_read = business[craft_read_start:craft_commands_start] if craft_read_start >= 0 and craft_commands_start > craft_read_start else ""
require("craft_refresh_no_server_quote", "RequestQuote(" not in craft_read and "GetLowestPrice" not in craft_read)
require("craft_batch_command", "QuotePendingMaterials = function(feature)" in business)
require("craft_batch_queue_bound", "queue.maxQueue" in business and "index > limit" in business)
require("craft_batch_dedupe", 'tostring(itemType) .. ":" .. tostring(itemGrade or 0)' in business and "seen[key]" in business)
require("craft_batch_coalesced_refresh", 'feature:Refresh("craft_quote_batch_completed")' in business)
require("craft_quote_requester_is_feature_scoped", 'feature.Id .. ":craft"' in business)
require("craft_cost_visible", 'quote = " · 未询价"' in business and '" · 单价 "' in business and '" · 小计 "' in business)
require("craft_ui_batch_button", 'id = "v3_business_" .. id .. "_material_quote"' in business_page and "projection.pendingQuoteCount" in business_page)
require("craft_ui_cost_summary", "projection.quotedMaterialCostCopper" in business_page and "projection.pricedMaterialCount" in business_page)

# ArcheAge ships Lua 5.1 semantics; keep this mega-bridge at/below its known
# top-level local ceiling until it is decomposed into smaller modules.
top_level_locals = 0
for line in business.splitlines():
    if not line.startswith("local "):
        continue
    declaration = line[6:]
    if declaration.startswith("function "):
        top_level_locals += 1
    else:
        lhs = declaration.split("=", 1)[0]
        top_level_locals += len([part for part in lhs.split(",") if part.strip()])
require("business_lua51_local_budget", top_level_locals <= 200)

require("task_tracking_projection_discoverable", 'trackedText = tracked and "✓ 已追踪" or "＋ 可添加"' in task_authority)
require("task_tracking_ui_discoverable", '先选中父任务，再点“加入追踪/取消追踪”' in task_page and 'width = 78' in task_page)

failed = [name for name, ok in checks if not ok]
if failed:
    print(f"TRADE_CRAFT_MODES_HARNESS FAIL | {len(checks)-len(failed)}/{len(checks)}")
    for name in failed:
        print(" -", name)
    sys.exit(1)
print(f"TRADE_CRAFT_MODES_HARNESS PASS | {len(checks)}/{len(checks)} | businessLocals={top_level_locals}/200")

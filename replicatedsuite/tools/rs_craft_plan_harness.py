#!/usr/bin/env python3
"""Static ownership/safety harness for .18.121 Craft Planner multi-recipe plan."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = (ROOT / "features/rs_business_bridge.lua").read_text(encoding="utf-8-sig")
PLAN = (ROOT / "features/life/craft/rs_craft_planner_extension_v3.lua").read_text(encoding="utf-8-sig")
PAGE = (ROOT / "presentation/v3/pages/rs_v3_business_pages.lua").read_text(encoding="utf-8-sig")
TOC = (ROOT / "toc.g").read_text(encoding="utf-8-sig")
GATE = (ROOT / "core/rs_foundation_gate.lua").read_text(encoding="utf-8-sig")
ACCEPT = (ROOT / "presentation/v3/rs_v3_acceptance.lua").read_text(encoding="utf-8-sig")

checks=[]
def check(name, cond): checks.append((name, bool(cond)))

check("extension_after_business_bridge", TOC.index("features/rs_business_bridge.lua") < TOC.index("features/life/craft/rs_craft_planner_extension_v3.lua"))
check("persistent_plan_declared_only_planner", 'NewFeature("life_craft_planner"' in BRIDGE and 'planItems = {}' in BRIDGE)
check("bounded_12_plan", "local MAX_PLAN_ITEMS = 12" in PLAN and "#plan >= MAX_PLAN_ITEMS" in PLAN)
check("bounded_quantity", "local MAX_QUANTITY = 999" in PLAN and "n > MAX_QUANTITY" in PLAN)
check("stable_recipe_key_serialization", "recipeKey = key, quantity = amount" in PLAN and "craftId" not in PLAN.split("Serialization contract:",1)[1].split("------------------------------------------------------------------------",1)[0])
check("governed_static_recipe", 'S.StaticDataV2:Get("trade_recipe"' in PLAN)
check("governed_static_material", 'S.StaticDataV2:Get("trade_material"' in PLAN)
check("aggregate_material_required", "row.required + count * entry.quantity" in PLAN)
check("reuse_base_held_projection", "base.craft.held" in PLAN and "X2Bag" not in PLAN)
check("shortage_is_nonnegative", "math.max(0, row.required - row.held)" in PLAN)
check("no_native_craft_calls", "X2Craft" not in PLAN)
check("no_direct_auction_call", "GetLowestPrice" not in PLAN and "SearchAuctionArticle" not in PLAN)
check("shared_quote_read_model", "PriceQuoteQueueV3" in PLAN and "GetPriceByItemType" in PLAN)
check("explicit_quote_command", "function Feature.Commands:QuotePlanMaterials()" in PLAN and "RequestQuote(" in PLAN)
check("quote_queue_bounded", "queue.maxQueue" in PLAN and "index > limit" in PLAN)
check("quote_deduped", 'tostring(row.itemType) .. ":" .. tostring(row.itemGrade or 0)' in PLAN and "seen[key]" in PLAN)
check("quote_completion_coalesced", "sealed == true" in PLAN and 'Feature:Refresh("craft_plan_quote_batch_completed")' in PLAN)
check("plan_contract_marker", "Feature.CraftPlanContractVersion = 1" in PLAN)
check("plan_ui_add_remove_clear", "_plan_add" in PAGE and "_plan_remove" in PAGE and "_plan_clear" in PAGE)
check("plan_ui_quantity", "_plan_qty" in PAGE and "max = 999" in PAGE)
check("plan_ui_table", "_plan_table" in PAGE and 'title = "计划制作物"' in PAGE)
check("plan_ui_explicit_quote", "_plan_quote" in PAGE and "QuotePlanMaterials" in PAGE)
check("foundation_gate", '"v3_craft_plan_contract"' in GATE)
check("acceptance_gate", '"craft_plan_contract_v1"' in ACCEPT)
check("no_tick", "OnTick" not in PLAN and "OnUpdate" not in PLAN)

failed=[n for n,ok in checks if not ok]
if failed:
    print(f"CRAFT_PLAN_HARNESS FAIL | {len(checks)-len(failed)}/{len(checks)}")
    for n in failed: print(" -", n)
    sys.exit(1)
print(f"CRAFT_PLAN_HARNESS PASS | {len(checks)}/{len(checks)}")

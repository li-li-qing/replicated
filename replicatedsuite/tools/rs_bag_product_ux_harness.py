#!/usr/bin/env python3
"""Bag organizer product-UX regression (.18.187).

Guards the simplified player page, explicit blacklist lookup boundary, name
metadata persistence, and backwards-compatible runtime commands. This harness
is intentionally source-contract based: RU Native inventory APIs are not
available in the offline test environment.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = (ROOT / "features/rs_business_bridge.lua").read_text(encoding="utf-8-sig", errors="replace")
PAGE = (ROOT / "presentation/v3/pages/rs_v3_business_pages.lua").read_text(encoding="utf-8-sig", errors="replace")
REGISTRY = (ROOT / "features/rs_feature_registry.lua").read_text(encoding="utf-8-sig", errors="replace")

checks = []

def check(name, condition):
    if not condition:
        raise AssertionError(name)
    checks.append(name)

check("ux_contract_v2", "bagProductUxContractVersion = 2" in PAGE)
check("quick_actions_plain_language", 'text="取出同类"' in PAGE and 'text="存入同类"' in PAGE)
check("blacklist_plain_title", 'text = "整理黑名单"' in PAGE)
check("id_or_name_input", "输入物品ID或当前背包/仓储中的物品名称" in PAGE)
check("bag_row_direct_select", 'id == "tools_bag" then\n        tableView.onSelectionChanged' in PAGE and '"bag_item_row_select"' in PAGE)
check("bag_table_human_columns", 'title = "当前背包物品（ID · 名称）"' in PAGE and 'title = "数量"' in PAGE and 'title = "类别"' not in PAGE[PAGE.find('columns = id == "tools_bag"'):PAGE.find('} or {', PAGE.find('columns = id == "tools_bag"'))])
check("legacy_scope_ui_removed", "v3_business_tools_bag_blacklist_scope_row" not in PAGE)
check("legacy_category_ui_removed", "v3_business_tools_bag_blacklist_category_row" not in PAGE)
check("advanced_batch_ui_removed", "v3_business_tools_bag_batch_row" not in PAGE and "v3_business_tools_bag_batch_limit_row" not in PAGE)
check("product_status_no_native_dump", "storageFacts" not in PAGE and "背包显示=" not in PAGE)

check("name_metadata_contract", "BagTools.BlacklistNameMetadataContractVersion = 1" in BRIDGE and "itemName = {}" in BRIDGE)
check("product_blacklist_contract", "BagTools.ProductBlacklistUxContractVersion = 1" in BRIDGE)
check("explicit_lookup_contract", "BagTools.BlacklistExplicitLookupContractVersion = 1" in BRIDGE)
check("global_add_remove_commands", "ResolveAndAddBlacklistItem = function" in BRIDGE and "AddGlobalBlacklistItem = function" in BRIDGE and "RemoveGlobalBlacklistItem = function" in BRIDGE)
check("itemtype_is_authority", "Runtime blocking continues to" in BRIDGE and "use itemType/category as the sole Authority" in BRIDGE)
check("name_lookup_is_explicit_bounded", 'inventory:BuildSnapshot("bag", { maxSlots = BAG_SCAN_LIMIT })' in BRIDGE and "CurrentStorageContext()" in BRIDGE)
check("numeric_id_does_not_require_snapshot", BRIDGE.find("local numeric = NormalizeItemType(raw)", BRIDGE.find("function BagMoveRuntime.ResolveAndAddBlacklistItem")) < BRIDGE.find("local inventory = S.Services and S.Services.InventorySnapshotV3 or nil", BRIDGE.find("function BagMoveRuntime.ResolveAndAddBlacklistItem")))
check("global_rule_mirrors_storage", 'for _, scope in ipairs({ "bank", "coffer" }) do' in BRIDGE and 'config.enabled = true' in BRIDGE)
check("human_item_projection", 'local display = tostring(key) .. " · " .. tostring(item.itemName or "名称未知")' in BRIDGE)
check("legacy_batch_commands_preserved", "DepositCategoryCurrent = function" in BRIDGE and "SetBatchCategory = SetBatchCategory" in BRIDGE)
check("registry_product_copy", "快速在背包与当前银行/保管箱之间整理同类物品" in REGISTRY and "product_blacklist_ux" in REGISTRY)

observer_start = BRIDGE.find("local function StartBagQuickObserver(feature)")
observer_end = BRIDGE.find("local function StopBagQuickAll", observer_start)
check("observer_block_found", observer_start >= 0 and observer_end > observer_start)
observer = BRIDGE[observer_start:observer_end]
check("observer_stays_window_only", "BuildSnapshot" not in observer and "ResolveAndAddBlacklistItem" not in observer and "MoveToEmpty" not in observer)

print(f"BAG_PRODUCT_UX_HARNESS PASS {len(checks)}/{len(checks)}")

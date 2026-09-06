#!/usr/bin/env python3
"""Developer-only Bag Move Contract v8 regression harness.

Contract v8 keeps the old/reference project only as product-behaviour evidence.
Active V3 owns the implementation through InventorySnapshotV3: a single bounded
snapshot builds identity/category indexes, bagId=1 is the physical authority
with a bounded bagId=0 compatibility fallback, and quick/category operations
queue grouped business intent rather than transient slots.  Slot hints are
revalidated before every write and post-compaction ambiguity is verified by
bounded source-population decrease.
"""
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "features/rs_business_bridge.lua").read_text(encoding="utf-8-sig")
INVENTORY = (ROOT / "services/rs_inventory_snapshot_v3.lua").read_text(encoding="utf-8-sig")
TOC = (ROOT / "toc.g").read_text(encoding="utf-8-sig")


def require_source_contract() -> None:
    inventory_required = (
        'Id = "v3.inventory_snapshot"',
        "SnapshotContractVersion = 1",
        "PhysicalBagAuthorityContractVersion = 1",
        "IndexContractVersion = 1",
        "PreferredBagId = 1",
        "FallbackBagId = 0",
        "function I:BuildSnapshot(scope, options)",
        "function I:FindLiveRow(scope, matcher, options)",
        "function I:CountLive(scope, matcher, options)",
        "function I:ReadPhysicalBagSlot(slot, bagIdHint)",
        "stopAt",
    )
    for token in inventory_required:
        assert token in INVENTORY, f"missing InventorySnapshotV3 contract: {token}"
    assert "services/rs_inventory_snapshot_v3.lua" in TOC

    bridge_required = (
        "local function StableItemIdentity(info)",
        "function BagMoveRuntime.FindLiveMoveSource(feature, sourceScope, blacklistScope, identity, category, bagId, startSlot, blockedIdentities)",
        "function BagMoveRuntime.CountLiveMatches(scope, identity, category, bagId, stopAt)",
        "queueByIdentity",
        "remaining = 0, slotHint = row.slot",
        "feature._quickBagId = bagId",
        "feature._batchBagId = bagSnapshot.bagId",
        "BagTools.BagMoveContractVersion = 8",
        "BagTools.DynamicSourceResolutionContractVersion = 3",
        "BagTools.QuickIdentityFallbackContractVersion = 1",
        "BagTools.InventorySnapshotContractVersion = 1",
        "BagTools.GroupedIntentQueueContractVersion = 1",
        "BagTools.FullStorageContinuationContractVersion = 1",
        "function BagMoveRuntime.IsNativeMoveRejected(err)",
        "function BagMoveRuntime.BlockBatchIdentity(feature, entry, identity, reason)",
    )
    for token in bridge_required:
        assert token in SOURCE, f"missing Bag v8 contract: {token}"

    code = re.sub(r"--\[\[.*?\]\]", "", SOURCE, flags=re.S)
    code = re.sub(r"--[^\n]*", "", code)
    assert re.search(r"queue\s*\[\s*#queue\s*\+\s*1\s*\]\s*=\s*\{\s*slot\s*=", code) is None
    assert re.search(r"queue\s*\[\s*#queue\s*\+\s*1\s*\]\s*=\s*slot\b", code) is None
    assert 'GetBagItemInfo", BagApi, "GetBagItemInfo", 0, sourceSlot' not in SOURCE


def identity(row: dict) -> str | None:
    item_type = row.get("itemType")
    if item_type is not None:
        return f"type:{item_type}"
    name = str(row.get("name") or "").strip()
    if not name:
        return None
    return "\x1f".join(("fallback", name, str(row.get("grade") or ""), str(row.get("category") or "")))


def build_snapshot(rows: list[dict]) -> dict:
    identity_set: set[str] = set()
    identity_count: dict[str, int] = {}
    category_count: dict[str, int] = {}
    for row in rows:
        token = identity(row)
        if token:
            identity_set.add(token)
            identity_count[token] = identity_count.get(token, 0) + 1
        category = row.get("category")
        if category is not None:
            category_count[category] = category_count.get(category, 0) + 1
    return {"identitySet": identity_set, "identityCount": identity_count, "categoryCount": category_count}


def grouped_plan(rows: list[dict], target_identity_set: set[str], limit: int = 40) -> list[dict]:
    queue: list[dict] = []
    by_identity: dict[str, int] = {}
    planned = 0
    for slot, row in enumerate(rows, start=1):
        token = identity(row)
        if token is None or token not in target_identity_set or planned >= limit:
            continue
        if token not in by_identity:
            by_identity[token] = len(queue)
            queue.append({"identity": token, "remaining": 0, "slotHint": slot})
        queue[by_identity[token]]["remaining"] += 1
        planned += 1
    return queue


def find_with_hint(rows: list[dict], wanted: str, hint: int) -> int | None:
    if not rows:
        return None
    hint_index = max(0, min(len(rows) - 1, hint - 1))
    order = list(range(hint_index, len(rows))) + list(range(0, hint_index))
    for index in order:
        if identity(rows[index]) == wanted:
            return index
    return None


def test_physical_bag_authority_contract() -> None:
    assert "PreferredBagId = 1" in INVENTORY
    assert "FallbackBagId = 0" in INVENTORY
    # Preferred view is selected whenever it has readable rows; fallback exists
    # only for the compatibility case where that view yields no rows.
    assert "#preferred.rows > 0" in INVENTORY
    assert "#fallback.rows > 0" in INVENTORY


def test_single_pass_indexes() -> None:
    rows = [
        {"itemType": 100, "category": "mat"},
        {"itemType": 100, "category": "mat"},
        {"itemType": 200, "category": "food"},
    ]
    snap = build_snapshot(rows)
    assert snap["identityCount"]["type:100"] == 2
    assert snap["categoryCount"]["mat"] == 2
    assert snap["identitySet"] == {"type:100", "type:200"}


def test_grouped_same_type_plan() -> None:
    rows = [
        {"itemType": 100, "category": "mat"},
        {"itemType": 100, "category": "mat"},
        {"itemType": 100, "category": "mat"},
        {"itemType": 900, "category": "misc"},
    ]
    queue = grouped_plan(rows, {"type:100"})
    assert len(queue) == 1
    assert queue[0]["remaining"] == 3
    assert queue[0]["slotHint"] == 1


def test_grouped_plan_respects_limit() -> None:
    rows = [{"itemType": 100, "category": "mat"} for _ in range(80)]
    queue = grouped_plan(rows, {"type:100"}, limit=40)
    assert len(queue) == 1 and queue[0]["remaining"] == 40


def test_slot_hint_survives_compaction() -> None:
    rows = [
        {"itemType": 100, "category": "mat"},
        {"itemType": 100, "category": "mat"},
        {"itemType": 900, "category": "misc"},
    ]
    wanted = "type:100"
    hint = 1
    moved = 0
    for _ in range(2):
        index = find_with_hint(rows, wanted, hint)
        assert index is not None
        before = sum(identity(r) == wanted for r in rows)
        rows.pop(index)  # compaction may refill the same physical locator
        after = sum(identity(r) == wanted for r in rows)
        assert after < before
        hint = index + 1
        moved += 1
    assert moved == 2 and all(identity(r) != wanted for r in rows)


def test_hint_wraps_when_sort_moves_item() -> None:
    rows = [
        {"itemType": 100, "category": "mat"},
        {"itemType": 900, "category": "misc"},
        {"itemType": 901, "category": "misc"},
    ]
    assert find_with_hint(rows, "type:100", 3) == 0


def test_fallback_identity_is_conservative() -> None:
    a = identity({"name": "铁锭", "grade": 1, "category": "material"})
    b = identity({"name": "铁锭", "grade": 2, "category": "material"})
    c = identity({"name": "铜锭", "grade": 1, "category": "material"})
    assert a and a.startswith("fallback\x1f")
    assert len({a, b, c}) == 3


def test_category_batch_blacklist() -> None:
    bag = [
        {"itemType": 1, "category": "ore"},
        {"itemType": 99, "category": "food"},
        {"itemType": 2, "category": "ore"},
        {"itemType": 3, "category": "ore"},
    ]
    blocked = {2}
    allowed = [row for row in bag if row["category"] == "ore" and row["itemType"] not in blocked]
    assert [row["itemType"] for row in allowed] == [1, 3]


def test_no_progress_skips_identity_and_continues() -> None:
    bag = [{"itemType": 100}, {"itemType": 100}, {"itemType": 200}]
    blocked = {"type:100"}
    remaining = [row for row in bag if identity(row) not in blocked]
    assert [identity(row) for row in remaining] == ["type:200"]
    assert "retries < 2" in SOURCE
    assert "目标堆已满，已跳过并继续" in SOURCE
    assert "feature._batchBlockedIdentities" in SOURCE


def test_full_storage_is_not_global_preflight_rejection() -> None:
    assert 'if free <= 0 then return false, "目标仓储没有可验证的空槽" end' not in SOURCE
    assert "local queueLimit = requestedLimit" in SOURCE


def test_no_tick_or_onupdate_inventory_service() -> None:
    code = re.sub(r"--\[\[.*?\]\]", "", INVENTORY, flags=re.S)
    code = re.sub(r"--[^\n]*", "", code).lower()
    assert "onupdate" not in code
    assert "tick(" not in code
    assert "scheduler:addtask" not in code


def main() -> int:
    require_source_contract()
    tests = (
        test_physical_bag_authority_contract,
        test_single_pass_indexes,
        test_grouped_same_type_plan,
        test_grouped_plan_respects_limit,
        test_slot_hint_survives_compaction,
        test_hint_wraps_when_sort_moves_item,
        test_fallback_identity_is_conservative,
        test_category_batch_blacklist,
        test_no_progress_skips_identity_and_continues,
        test_full_storage_is_not_global_preflight_rejection,
        test_no_tick_or_onupdate_inventory_service,
    )
    for test in tests:
        test()
    print(f"BAG_MOVE_QUEUE_V8_HARNESS PASS {len(tests)}/{len(tests)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

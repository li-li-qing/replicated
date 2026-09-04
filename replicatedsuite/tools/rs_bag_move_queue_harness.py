#!/usr/bin/env python3
"""Developer-only Bag Move Contract v5 regression harness.

The RU client can compact/reproject inventory slots after MoveToEmpty*.  The
runtime source must therefore plan stable intent (itemType/category), resolve a
live source slot immediately before each write, and verify ambiguous same-slot
post-state by source-population decrease.
"""
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "features/rs_business_bridge.lua").read_text(encoding="utf-8-sig")


def require_source_contract() -> None:
    required = (
        "function BagMoveRuntime.FindLiveMoveSource(feature, sourceScope, blacklistScope, itemType, category)",
        "function BagMoveRuntime.CountLiveMatches(scope, itemType, category)",
        "feature._quickSourceCounts=Copy(sourceCounts)",
        "feature._batchSourceCount = sourceCategoryCount",
        "BagTools.DynamicSourceResolutionContractVersion = 1",
    )
    for token in required:
        assert token in SOURCE, f"missing source contract: {token}"
    code = re.sub(r"--\[\[.*?\]\]", "", SOURCE, flags=re.S)
    code = re.sub(r"--[^\n]*", "", code)
    assert re.search(r"queue\s*\[\s*#queue\s*\+\s*1\s*\]\s*=\s*\{\s*slot\s*=", code) is None
    assert re.search(r"queue\s*\[\s*#queue\s*\+\s*1\s*\]\s*=\s*slot\b", code) is None


def count_type(slots: list[dict], item_type: int) -> int:
    return sum(1 for row in slots if row["itemType"] == item_type)


def count_category(slots: list[dict], category: str) -> int:
    return sum(1 for row in slots if row["category"] == category)


def find_type(slots: list[dict], item_type: int) -> int | None:
    for i, row in enumerate(slots):
        if row["itemType"] == item_type:
            return i
    return None


def find_category(slots: list[dict], category: str, blocked_types: set[int] | None = None) -> int | None:
    blocked_types = blocked_types or set()
    for i, row in enumerate(slots):
        if row["category"] == category and row["itemType"] not in blocked_types:
            return i
    return None


def verify_population_decrease(before: int, after: int) -> bool:
    return after < before


def test_quick_same_type_compaction() -> None:
    bag = [
        {"itemType": 100, "category": "mat"},
        {"itemType": 100, "category": "mat"},
        {"itemType": 100, "category": "mat"},
        {"itemType": 900, "category": "misc"},
    ]
    plan = [100, 100, 100]
    moved = 0
    for item_type in plan:
        slot = find_type(bag, item_type)
        assert slot is not None
        before = count_type(bag, item_type)
        bag.pop(slot)  # ArcheAge may compact later rows into this locator.
        after = count_type(bag, item_type)
        assert verify_population_decrease(before, after)
        moved += 1
    assert moved == 3 and count_type(bag, 100) == 0


def test_quick_mixed_type_live_resolution() -> None:
    bag = [
        {"itemType": 100, "category": "mat"},
        {"itemType": 200, "category": "mat"},
        {"itemType": 100, "category": "mat"},
    ]
    plan = [100, 200, 100]
    for item_type in plan:
        slot = find_type(bag, item_type)
        assert slot is not None
        before = count_type(bag, item_type)
        bag.pop(slot)
        assert count_type(bag, item_type) < before
    assert bag == []


def test_batch_category_compaction_and_blacklist() -> None:
    bag = [
        {"itemType": 1, "category": "ore"},
        {"itemType": 99, "category": "food"},
        {"itemType": 2, "category": "ore"},
        {"itemType": 3, "category": "ore"},
    ]
    blocked = {2}
    plan_count = 2  # itemType 1 and 3 are allowed; type 2 remains.
    moved = 0
    for _ in range(plan_count):
        slot = find_category(bag, "ore", blocked)
        assert slot is not None
        before = count_category(bag, "ore")
        bag.pop(slot)
        assert verify_population_decrease(before, count_category(bag, "ore"))
        moved += 1
    assert moved == 2
    assert [r["itemType"] for r in bag if r["category"] == "ore"] == [2]


def test_failed_write_stays_fail_closed() -> None:
    bag = [{"itemType": 100, "category": "mat"}, {"itemType": 100, "category": "mat"}]
    before = count_type(bag, 100)
    # Failed/intermittent MoveToEmpty*: source population does not change.
    after = count_type(bag, 100)
    assert verify_population_decrease(before, after) is False


def main() -> int:
    require_source_contract()
    tests = (
        test_quick_same_type_compaction,
        test_quick_mixed_type_live_resolution,
        test_batch_category_compaction_and_blacklist,
        test_failed_write_stays_fail_closed,
    )
    for test in tests:
        test()
    print(f"BAG_MOVE_QUEUE_V5_HARNESS PASS {len(tests)}/{len(tests)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

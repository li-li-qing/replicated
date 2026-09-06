#!/usr/bin/env python3
"""Regression harness for .18.127 user-reported runtime fixes.

Covers four independently-owned contracts without invoking Native APIs:
Gear partial application, Trade manual retry/timeout, Bag full-storage
continuation, and Healer native-roster geometry/index mapping.
"""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
GEAR = (ROOT / "services/rs_gear_service_v3.lua").read_text(encoding="utf-8-sig")
TRADE = (ROOT / "features/life/rs_life_m16_bundle.lua").read_text(encoding="utf-8-sig")
BAG = (ROOT / "features/rs_business_bridge.lua").read_text(encoding="utf-8-sig")
HEALER_STORE = (ROOT / "features/combat/healer/rs_healer_store.lua").read_text(encoding="utf-8-sig")
HEALER_UI = (ROOT / "presentation/v3/widgets/rs_v3_healer_raid_overlay.lua").read_text(encoding="utf-8-sig")
GATE = (ROOT / "core/rs_foundation_gate.lua").read_text(encoding="utf-8-sig")
ACCEPTANCE = (ROOT / "presentation/v3/rs_v3_acceptance.lua").read_text(encoding="utf-8-sig")


def check_static_contracts() -> None:
    gear_tokens = (
        "G.version = 4",
        "G.PartialApplyContractVersion = 1",
        'if blocked.code ~= "not_found" then',
        "function G:ValidateReachableSession(session)",
        "function G:PartialSummary(session, prefix)",
        'if reasonCode == "not_found" then',
    )
    for token in gear_tokens:
        assert token in GEAR, f"missing Gear partial contract: {token}"
    assert "if #session.blocked > 0 then\n        local first" not in GEAR

    trade_tokens = (
        "Trade.Authority = { version = 5",
        "TA.RouteRefreshRetryContractVersion = 2",
        "TA.RequestTimeoutContractVersion = 1",
        "function TA:ArmRequestTimeout(serial)",
        "6500",
        "TA.SingleFlightLatestRouteContractVersion = 1",
        "function TA:Request(force)",
        "return TA:Request(true)",
        '"服务器货率查询超时，请点刷新重试"',
    )
    for token in trade_tokens:
        assert token in TRADE, f"missing Trade retry contract: {token}"

    bag_tokens = (
        "BagTools.BagMoveContractVersion = 8",
        "BagTools.FullStorageContinuationContractVersion = 1",
        "function BagMoveRuntime.IsNativeMoveRejected(err)",
        "function BagMoveRuntime.SkipQuickIdentity(feature, entry, reason)",
        "function BagMoveRuntime.BlockBatchIdentity(feature, entry, identity, reason)",
        "local queueLimit = requestedLimit",
        "feature._batchBlockedIdentities",
    )
    for token in bag_tokens:
        assert token in BAG, f"missing Bag continuation contract: {token}"
    assert 'if free <= 0 then return false, "目标仓储没有可验证的空槽" end' not in BAG

    healer_tokens = (
        "local SCHEMA = 6",
        "width = 340, height = 400",
        "P.version = 4",
        "P.NativeRosterGeometryContractVersion = 2",
        "P.ColumnMajorSlotContractVersion = 2",
        "P.StackedHalfRosterContractVersion = 1",
        "local within = ((i - 1) % HALF_SLOTS) + 1",
        "local half = i > HALF_SLOTS and 1 or 0",
        "Feature:GetRosterProjection()",
    )
    combined = HEALER_STORE + "\n" + HEALER_UI
    for token in healer_tokens:
        assert token in combined, f"missing Healer native roster contract: {token}"

    assert "version = 119" in GATE
    assert "gear_partial_apply_contract" in GATE
    assert "BagMoveContractVersion) or 0) >= 8" in GATE
    assert "schemaVersion) == 6" in GATE
    assert "S.UIV3Acceptance = { version = 74 }" in ACCEPTANCE
    assert "bag_quick_take_put_contract_v8" in ACCEPTANCE
    assert "healer_native_roster_geometry_contract" in ACCEPTANCE


def test_healer_native_grid_model() -> None:
    # One native team is two stacked 25-player halves. Each half is a 5x5
    # column-major roster: 1-25 upper, 26-50 lower.
    half_slots, rows = 25, 5
    positions = []
    for member_index in range(1, 51):
        section = (member_index - 1) // half_slots
        half_index = ((member_index - 1) % half_slots) + 1
        col = (half_index - 1) // rows
        row = (half_index - 1) % rows
        positions.append((section, col, row))
    assert positions[0] == (0, 0, 0)
    assert positions[24] == (0, 4, 4)
    assert positions[25] == (1, 0, 0)
    assert positions[49] == (1, 4, 4)


def test_bag_blocked_identity_continuation_model() -> None:
    identities = ["full:A", "stackable:B", "stackable:B", "full:C", "stackable:D"]
    rejected = {"full:A", "full:C"}
    attempted, moved = [], []
    blocked = set()
    for token in identities:
        if token in blocked:
            continue
        attempted.append(token)
        if token in rejected:
            blocked.add(token)
            continue
        moved.append(token)
    assert moved == ["stackable:B", "stackable:B", "stackable:D"]
    assert attempted[-1] == "stackable:D"


def test_trade_refresh_is_bounded() -> None:
    request = re.search(r"function TA:Request\(force\)(.*?)\nend\n\nfunction TA:OnRatio", TRADE, re.S)
    assert request is not None
    body = request.group(1)
    assert "self.requestSerial" in body
    assert "self:ArmRequestTimeout(serial)" in body
    assert "self:CancelRequestTimeout()" in body


def main() -> int:
    check_static_contracts()
    tests = (
        test_healer_native_grid_model,
        test_bag_blocked_identity_continuation_model,
        test_trade_refresh_is_bounded,
    )
    for test in tests:
        test()
    print(f"RUNTIME_BUGFIX_18_127_HARNESS PASS {len(tests)}/{len(tests)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Static/model regression harness for .18.128 user-reported runtime fixes."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
read = lambda p: (ROOT / p).read_text(encoding="utf-8-sig")

GEAR = read("features/combat/gear/rs_gear_store.lua")
HEALER_STORE = read("features/combat/healer/rs_healer_store.lua")
HEALER_FEATURE = read("features/combat/healer/rs_healer_feature.lua")
HEALER_OVERLAY = read("presentation/v3/widgets/rs_v3_healer_raid_overlay.lua")
ROSTER = read("services/rs_team_roster_v3.lua")
PROJECTION = read("services/rs_screen_projection_v3.lua")
LIFE = read("features/life/rs_life_m16_bundle.lua")
BAG_UI = read("presentation/v3/widgets/rs_v3_bag_quick_overlay.lua")
DATA_VIEWS = read("ui/framework/rs_ui_data_views.lua")
TRANSFORM = read("ui/framework/rs_ui_transform_inspector.lua")
CASTING = read("services/rs_casting_observation_v3.lua")
BUFF = read("features/combat/buff_display/rs_buff_display_feature.lua")
BUSINESS = read("features/rs_business_bridge.lua")
TOC = read("toc.g")
GATE = read("core/rs_foundation_gate.lua")
ACCEPTANCE = read("presentation/v3/rs_v3_acceptance.lua")


def require(source: str, *tokens: str) -> None:
    for token in tokens:
        assert token in source, f"missing contract token: {token}"


def static_contracts() -> None:
    require(GEAR, "local SLOT_ORDER = {}", "local function EquipmentOrder(slot)", "local ao, bo = EquipmentOrder")
    require(HEALER_STORE, "local SCHEMA = 6", "width = 340, height = 400")
    require(HEALER_OVERLAY, "P.version = 4", "P.StackedHalfRosterContractVersion = 1",
            "local HALF_COLS, HALF_ROWS, HALF_SLOTS = 5, 5, 25", "local half = i > HALF_SLOTS and 1 or 0")
    require(HEALER_FEATURE, "follow the ONE native raid list's currently visible 1/2 tab", "roster.visibleTeamIndex")
    require(ROSTER, "version = 6", "local function DetectVisibleTeamIndex()", "previousVisibleTeamIndex",
            "or tonumber(previousVisibleTeamIndex) ~= tonumber(self.visibleTeamIndex)")

    require(PROJECTION, "P.version = 12", "P.CameraUnavailableNativeFallbackContractVersion = 1",
            'source="native_camera_unavailable"')
    require(LIFE, "TA.RouteRefreshRetryContractVersion = 2", "TA.SingleFlightLatestRouteContractVersion = 1",
            "self.pendingRoute = { from = from, to = to }", '"route_result_superseded"')
    require(LIFE, "dailyDateKey = nil, dailySnapshots = {}", "CurrentBondContinentKey()",
            "local function BondCompletionKey(materialKey, quantity, continentKey)",
            "Capture at most once per continent/server day", "tostring(row.materialKey) .. \":\" .. tostring(row.quantity)")

    require(BAG_UI, "取：从当前打开的银行/箱子", "放：把背包中的同类物品", "停：立即停止当前批量",
            "allowRaw=true, cursorFollow=true")
    tip_start = DATA_VIEWS.index("function c:EnsureAutoTooltip()")
    tip_end = DATA_VIEWS.index("c.onClick = spec.onClick", tip_start)
    assert "cursorFollow = true" in DATA_VIEWS[tip_start:tip_end]
    require(TRANSFORM, "RSUI.TransformInspectorContractVersion = 3", "function c:Measure(availableWidth, availableHeight)",
            "self.form:Measure(w, availableHeight)")

    require(CASTING, 'Id = "v3.casting_observation"', "DemandScopedPollingContractVersion = 1",
            '"X2Unit:UnitCastingInfo"', "function C:AcquireConsumer", "function C:_Desired(after)")
    assert "services/rs_casting_observation_v3.lua" in TOC
    assert 'CallCapability("X2Unit:UnitCastingInfo"' not in BUFF, "BuffDisplay bypassed shared CastingObservationV3"
    require(BUFF, "F.castingHeld = false", 'casting:AcquireConsumer("buff_display:casting"', "self:_ReleaseCasting()")
    require(BUSINESS, "BossAlerts.RealtimeFactBridgeContractVersion = 1", 'feature.Demand:Acquire("boss_alerts:runtime"',
            'casting:AcquireConsumer("boss_alerts:casting"', 'aura:AcquireConsumer("boss_alerts:aura"',
            "local rule = BossCastIndex[NormalizeCastKey(cast.spellName)]",
            "targettarget = true, watchtarget = true")
    assert "string.find(cast.spellName" not in BUSINESS

    require(GATE, "CameraUnavailableNativeFallbackContractVersion", "RealtimeFactBridgeContractVersion")
    gate_version = re.search(r"S\.FoundationGate\s*=\s*\{\s*version\s*=\s*(\d+)", GATE)
    assert gate_version and int(gate_version.group(1)) >= 119
    require(ACCEPTANCE, "RealtimeFactBridgeContractVersion")
    acceptance_version = re.search(r"S\.UIV3Acceptance\s*=\s*\{\s*version\s*=\s*(\d+)", ACCEPTANCE)
    assert acceptance_version and int(acceptance_version.group(1)) >= 74


def healer_model() -> None:
    positions = []
    for i in range(1, 51):
        half = 1 if i > 25 else 0
        within = ((i - 1) % 25) + 1
        col = (within - 1) // 5
        row = (within - 1) % 5
        positions.append((half, col, row))
    assert positions[0] == (0, 0, 0)
    assert positions[24] == (0, 4, 4)
    assert positions[25] == (1, 0, 0)
    assert positions[49] == (1, 4, 4)


def bond_identity_model() -> None:
    key = lambda material, qty: f"{material}:{qty}"
    assert key("leather", 20) == key("leather", 20)  # west/east same daily identity
    assert key("leather", 20) != key("leather", 60)
    assert key("leather", 60) != key("leather", 100)


def trade_latest_route_model() -> None:
    inflight = (1, 2)
    pending = None
    for desired in ((3, 4), (5, 6), (7, 8)):
        if desired != inflight:
            pending = desired
    assert pending == (7, 8)
    # Once the serialized old flight finishes, only the last selected route starts.
    inflight = pending
    assert inflight == (7, 8)


def main() -> int:
    static_contracts()
    tests = (healer_model, bond_identity_model, trade_latest_route_model)
    for test in tests:
        test()
    print(f"RUNTIME_BUGFIX_18_128_HARNESS PASS {len(tests)}/{len(tests)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

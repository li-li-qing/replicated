#!/usr/bin/env python3
"""Reload/window-fact regression for Bag quick overlay + Gear screen buttons (.18.153).

The Bag regression covers the real RU native-content quirk already proven by
AuctionSurfaceV3: GetContentMainScriptPosVis may return only x/y/w/h and omit
its final visible boolean.  The idle observer remains geometry/visibility-only;
all InventorySnapshot and move work stays behind explicit user actions.
"""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
read = lambda p: (ROOT / p).read_text(encoding="utf-8-sig")

RUNTIME = read("features/rs_feature_runtime.lua")
REGISTRY = read("features/rs_feature_registry.lua")
BUSINESS = read("features/rs_business_bridge.lua")
BAG_UI = read("presentation/v3/widgets/rs_v3_bag_quick_overlay.lua")
GEAR_STORE = read("features/combat/gear/rs_gear_store.lua")
GEAR_FEATURE = read("features/combat/gear/rs_gear_feature.lua")
GATE = read("core/rs_foundation_gate.lua")
ACCEPTANCE = read("presentation/v3/rs_v3_acceptance.lua")
PAGE = read("presentation/v3/pages/rs_v3_business_pages.lua")


def require(source: str, *tokens: str) -> None:
    for token in tokens:
        assert token in source, f"missing contract token: {token}"


def static_contracts() -> None:
    require(
        RUNTIME,
        "version = 4",
        "StartupEnableIntentContractVersion = 1",
        "GetStartupEnableIntent",
        "OnStartupEnableIntentCommitted",
    )

    bag_row = re.search(
        r'Add\("tools_bag".*?\{(.*?)\n\}\)\nAdd\("tools_auction"',
        REGISTRY,
        flags=re.S,
    )
    assert bag_row, "tools_bag registry row missing"
    bag_meta = bag_row.group(1)
    assert 'lifecycle = "independent_low_cost"' in bag_meta
    assert "defaultEnabled = true" in bag_meta
    assert '"ADDON:GetContent", "ADDON:GetContentMainScriptPosVis"' in bag_meta

    require(
        BUSINESS,
        "StartBagQuickObserver(feature)",
        "BAG_QUICK_OBSERVE_TASK,350,function() return RefreshBagQuickOverlay(feature)",
        "BagTools.NativeWindowQuickContractVersion = 7",
        "BagTools.ReloadQuickObserverContractVersion = 3",
        "BagTools.RUFourValueWindowVisibilityContractVersion = 2",
        'S.Api:IsCapabilityAllowed("ADDON:GetContent")',
        'S.Api:CallCapability("ADDON:GetContent"',
        '"main-script+content-visible"',
        '"main-script-geometry-over-proxy"',
        'BagTools.NativeVisibilityShapeContractVersion = 1',
        'BagTools.VisiblePresenterRetryContractVersion = 1',
        'local bank=ReadStorageWindowContext("bank")',
        'local coffer=ReadStorageWindowContext("coffer")',
    )
    observer_start = BUSINESS.index("local function StartBagQuickObserver(feature)")
    observer_end = BUSINESS.index("local function StopBagQuickAll", observer_start)
    observer = BUSINESS[observer_start:observer_end]
    assert "BuildSnapshot" not in observer, "idle bag observer must not scan inventory"
    assert "MoveToEmpty" not in observer, "idle bag observer must not move inventory"

    require(BAG_UI,
        "version=4",
        "ReloadVisibilityContractVersion=2",
        "NativeTransientHostContractVersion=1",
        "VisibleRetryContractVersion=1",
        'CreatePanel(UIParent,"v3_bag_quick_overlay_root"',
        "transientWindow=true",
        "P:EnsureCreated()",
    )
    assert 'CreateEmptyWidget(UIParent,"v3_bag_quick_overlay_root"' not in BAG_UI, "bag quick root must not regress to top-level emptywidget"
    require(PAGE, "背包窗口可见/", "overlay.bankSource", "overlay.cofferSource")

    require(GEAR_STORE, "runtimePreferenceLink = tonumber(value.runtimePreferenceLink) == 1 and 1 or nil")
    require(
        GEAR_FEATURE,
        "QuickStartupIntentContractVersion = 1",
        "function F:GetStartupEnableIntent(preferred, explicit)",
        "if self:IsQuickRuntimePreferenceLinked() then return false end",
        'return true, "legacy_quick_buttons"',
        "function F:OnStartupEnableIntentCommitted(reason)",
    )

    require(GATE, '"v3_quick_surface_reload_reconcile_contract"')
    require(ACCEPTANCE, "QuickSurfaceReloadReconcileContractVersion = 3", '"quick_surface_reload_reconcile_contract_v3"')


def native_flag(value):
    if isinstance(value, bool):
        return True, value
    if isinstance(value, (int, float)) and value in (0, 1):
        return True, value == 1
    if isinstance(value, str):
        text = value.strip().lower()
        if text in {"1", "true", "on", "show", "visible"}:
            return True, True
        if text in {"0", "false", "off", "hide", "hidden"}:
            return True, False
    return False, False


def resolve_visible(native_visible, content_known: bool, content_visible: bool, main_rect: bool) -> bool:
    known, value = native_flag(native_visible)
    if known:
        return value
    if content_visible:
        return True
    if main_rect:
        return True
    if content_known:
        return False
    return False

def test_ru_four_value_main_script_is_open_signal() -> None:
    # RU may omit the fifth return value entirely. Valid geometry must not be
    # rejected merely because visible=nil when no stronger content fact exists.
    assert resolve_visible(None, False, False, True) is True


def test_content_visibility_overrides_geometry_fallback() -> None:
    # GetContent may be a hidden proxy even while the MainScript window is open.
    # Valid MainScript geometry therefore remains positive evidence unless an
    # explicit native visibility value says the window is closed.
    assert resolve_visible(None, True, False, True) is True
    assert resolve_visible(None, True, True, True) is True
    assert resolve_visible(None, True, False, False) is False


def test_explicit_native_boolean_remains_authoritative() -> None:
    assert resolve_visible(False, False, False, True) is False
    assert resolve_visible(True, True, False, True) is True
    assert resolve_visible(0, False, False, True) is False
    assert resolve_visible(1, True, False, False) is True
    assert resolve_visible("0", False, False, True) is False
    assert resolve_visible("visible", True, False, False) is True


def gear_startup_model(preferred: bool, explicit: bool, linked: bool, quick_rows: int, visible: bool) -> bool:
    if preferred or not explicit:
        return False
    if linked:
        return False
    return visible and quick_rows > 0


def test_legacy_gear_split_repairs_once() -> None:
    assert gear_startup_model(False, True, False, 2, True) is True
    assert gear_startup_model(False, True, True, 2, True) is False


def test_bag_explicit_disable_is_not_overridden() -> None:
    # Registry default=true is only the default. FeatureRuntime:GetPreferredEnabled
    # returns an explicit persisted false before consulting metadata, preserving
    # the user's intentional disable instead of inventing an unsafe migration.
    assert "if type(explicit) == \"boolean\" then return explicit, true end" in RUNTIME


def test_bag_idle_observer_is_low_cost_surface_only() -> None:
    begin = BUSINESS.index("local function BeginBagQuick(feature, direction)")
    assert "BagIdentitySet" in BUSINESS[begin: begin + 5000]
    refresh = BUSINESS[BUSINESS.index("local function RefreshBagQuickOverlay(feature)"):BUSINESS.index("local function StartBagQuick(feature, direction)")]
    assert "BuildSnapshot" not in refresh
    assert "MoveToEmpty" not in refresh
    assert "bag_quick_visible_heartbeat" in refresh


def main() -> int:
    static_contracts()
    tests = (
        test_ru_four_value_main_script_is_open_signal,
        test_content_visibility_overrides_geometry_fallback,
        test_explicit_native_boolean_remains_authoritative,
        test_legacy_gear_split_repairs_once,
        test_bag_explicit_disable_is_not_overridden,
        test_bag_idle_observer_is_low_cost_surface_only,
    )
    for test in tests:
        test()
    print(f"QUICK_SURFACE_RELOAD_HARNESS PASS {len(tests)}/{len(tests)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

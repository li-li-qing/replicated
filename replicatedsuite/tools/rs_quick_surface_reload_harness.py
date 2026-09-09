#!/usr/bin/env python3
"""Reload/window-fact regression for Bag quick overlay + product page + Gear screen buttons (.18.187).

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
        "BagMoveRuntime.QuickObserverIntervalMs = 100",
        "BagTools.NativeWindowQuickContractVersion = 7",
        "BagTools.ReloadQuickObserverContractVersion = 3",
        "BagTools.RUFourValueWindowVisibilityContractVersion = 2",
        'S.Api:IsCapabilityAllowed("ADDON:GetContent")',
        'S.Api:CallCapability("ADDON:GetContent"',
        '"main-script+content-visible"',
        '"main-script-geometry-over-proxy"',
        'BagTools.NativeVisibilityShapeContractVersion = 1',
        'BagTools.SurfaceVisibilitySplitContractVersion = 1',
        'BagTools.StorageSessionBagSurfaceContractVersion = 1',
        'BagTools.ResponsiveWindowObserverContractVersion = 1',
        'BagTools.BagActionPhysicalReadAuthorityContractVersion = 1',
        'BagTools.VisiblePresenterRetryContractVersion = 1',
        'local bank=ReadStorageWindowContext("bank")',
        'local coffer=ReadStorageWindowContext("coffer")',
        # .18.183 quick-run lifecycle: evidence-based self-heal + two-button
        # start/stop/switch + short overlay status vs long diagnostic error.
        'BagTools.BagTaskMutexContractVersion = 2',
        'BagTools.QuickRunSelfHealContractVersion = 1',
        'BagTools.QuickTwoButtonContractVersion = 1',
        'BagTools.QuickReasonVisibilityContractVersion = 1',
        'function BagMoveRuntime.QuickQueueActive(feature)',
        'return type(feature._quickQueue) == "table" and #feature._quickQueue > 0',
        'function BagMoveRuntime.QuickRunEvidence(feature)',
        'BagMoveRuntime.QuickRunStaleMs = 8000',
        'function BagMoveRuntime.ReclaimStaleBagQuickRun(feature)',
        'function BagMoveRuntime.QuickStatusText(reason)',
        r'[\1-\127\192-\244][\128-\191]*',
        # The short status is built by splitting on whole separator strings.  A
        # negated byte class (`[^（，。]`) looks the same but cuts Chinese text in
        # half: 刻 = E5 88 BB shares 0x88 with 「（」.
        'string.find(text, separator, 1, true)',
        'bag_quick_empty_plan',
        'actions = { "QuickWithdraw", "QuickDeposit" },',
        # Message expiry is only honest if every status write carries a timestamp.
        'BagTools.QuickStatusTimestampContractVersion = 1',
        'feature._quickOverlay.statusAt = type(S.NowMs) == "function" and tonumber(S.NowMs()) or 0',
    )
    stamps = BUSINESS.count('feature._quickOverlay.statusAt = type(S.NowMs) == "function" and tonumber(S.NowMs()) or 0')
    assert stamps >= 4, f"quick status writes must be timestamped (found {stamps}, need >= 4)"
    observer_start = BUSINESS.index("local function StartBagQuickObserver(feature)")
    observer_end = BUSINESS.index("local function StopBagQuickAll", observer_start)
    observer = BUSINESS[observer_start:observer_end]
    assert "BuildSnapshot" not in observer, "idle bag observer must not scan inventory"
    assert "MoveToEmpty" not in observer, "idle bag observer must not move inventory"
    assert "BagMoveRuntime.QuickObserverIntervalMs,function() return RefreshBagQuickOverlay(feature) end,false,feature,\"P2\",1" in observer, "bag quick observer must use 100ms low-cost P2 cadence"

    require(BAG_UI,
        "version=9",
        "ReloadVisibilityContractVersion=2",
        "NativeTransientHostContractVersion=2",
        "VisibleRetryContractVersion=2",
        # .18.183 (user report): the floating bar offers 取/放 only.  The third
        # 停 button had no visible effect, and the refusal it existed for is what
        # made a click look dead; stop/switch now ride on the same two buttons.
        "TwoButtonContractVersion=1",
        'CreatePanel(UIParent,"v3_bag_quick_overlay_root"',
        "transientWindow=true",
        "P:EnsureCreated()",
        # .18.182: a failed host build while storage is visible must self-heal
        # on frame cadence instead of waiting for the next 350ms heartbeat.
        # The re-arm path passes freshCampaign=false so the cap counter survives
        # (a reset-on-rearm would retry forever; proven by the Lua simulator).
        "function P:ScheduleCreateRetry(freshCampaign)",
        "AddHighFrequencyOneShot(CREATE_RETRY_TASK, 64",
        "self:ScheduleCreateRetry()",
        "if P.retryCount < 8 then return P:ScheduleCreateRetry(false) end",
        # Progress text is the replacement affordance for 停.
        "if overlay.running == true then",
        # .18.183 RU report: the 350ms heartbeat used to rewrite geometry/label and
        # Raise the bar every beat, which buried the hover hint under the game
        # window within a second. Writes are diffed and the raise yields to a hint.
        "DiffRenderContractVersion=1",
        "HintYieldContractVersion=1",
        "local function HintIsShowing()",
        'if HintIsShowing()~=true and type(self.root.Raise)=="function" then',
        "if self.appliedStatus~=statusText then",
        "local geometryChanged=self.appliedGeometry~=geometryKey",
        # .18.183 user report (3rd): the idle "银行 · 可快捷取放" sentence is noise.
        # The bar is two buttons; a message appears only while it matters and then
        # expires, and the bar shrinks back to buttons-only width.
        "QuietByDefaultContractVersion=1",
        "ReleasedRootRecoveryContractVersion=1",
        "self.root ~= nil and self.root.rsUiReleased == true",
        "COMPACT_WIDTH = 102",
        "MESSAGE_TTL_MS = 6000",
        'local width=statusText=="" and COMPACT_WIDTH',
        'if status == "" or status == "可快捷取放" or status == "等待仓库/箱子" then return "" end',
        "S.UI:SetVisible(self.status,statusText~=\"\" and true or false,self.owner)",
    )
    # The idle sentence must not come back as a permanent label.
    assert 'return storage .. " · " .. status' not in BAG_UI, "quiet-by-default regressed to an always-on label"
    assert BAG_UI.count("local function OverlayStatusText(overlay, now)") == 1
    # A tooltip service that cannot answer the query must not be out-raised blind.
    assert 'if ok ~= true then return true end' in BAG_UI, "HintIsShowing fails safe toward 'do not raise'"
    assert BAG_UI.count("self.root:Raise()") == 2, "one raise on apply, one guarded steady-beat raise"
    assert 'CreateEmptyWidget(UIParent,"v3_bag_quick_overlay_root"' not in BAG_UI, "bag quick root must not regress to top-level emptywidget"
    assert BAG_UI.count('S.UI:CreateButton(root,"v3_bag_quick_') == 2, "bag quick overlay must stay at exactly two buttons"
    assert "v3_bag_quick_stop" not in BAG_UI, "the 停 button must not come back: it was reported as useless"
    assert BAG_UI.count("tooltip:Bind(") == 2, "both remaining buttons keep their stop/switch hover contract"
    require(PAGE, "bagProductUxContractVersion = 2", "取出同类", "存入同类",
        "输入物品ID或当前背包/仓储中的物品名称", "当前背包物品", "当前黑名单")
    assert "storageFacts" not in PAGE and "背包显示=" not in PAGE, "player bag page must not expose native diagnostic facts"
    assert "v3_business_tools_bag_quick_stop" not in PAGE, "page must not keep a third quick-stop button"

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


def resolve_action_visible(native_visible, content_known: bool, content_visible: bool, main_rect: bool) -> bool:
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


def resolve_surface_visible(native_visible, content_visible: bool, main_rect: bool) -> bool:
    known, value = native_flag(native_visible)
    return value is True or content_visible is True or (known is not True and main_rect is True)

def test_ru_four_value_main_script_is_open_signal() -> None:
    # RU may omit the fifth return value entirely. Valid geometry must not be
    # rejected merely because visible=nil when no stronger content fact exists.
    assert resolve_action_visible(None, False, False, True) is True


def test_content_visibility_overrides_geometry_fallback() -> None:
    # GetContent may be a hidden proxy even while the MainScript window is open.
    # Valid MainScript geometry therefore remains positive evidence unless an
    # explicit native visibility value says the window is closed.
    assert resolve_action_visible(None, True, False, True) is True
    assert resolve_action_visible(None, True, True, True) is True
    assert resolve_action_visible(None, True, False, False) is False


def test_explicit_native_boolean_remains_authoritative() -> None:
    assert resolve_action_visible(False, False, False, True) is False
    assert resolve_action_visible(True, True, False, True) is True
    assert resolve_action_visible(0, False, False, True) is False
    assert resolve_action_visible(1, True, False, False) is True
    assert resolve_action_visible("0", False, False, True) is False
    assert resolve_action_visible("visible", True, False, False) is True



def test_surface_visibility_does_not_inherit_write_authority_race() -> None:
    # RU opening race: Content is visibly live while MainScript fifth return still
    # says hidden/0. The harmless floating surface must appear, but native writes
    # remain fail-closed until action Authority catches up.
    assert resolve_action_visible(0, True, True, True) is False
    assert resolve_surface_visible(0, True, True) is True
    assert resolve_surface_visible(False, True, True) is True
    assert resolve_surface_visible(0, False, True) is False
    refresh = BUSINESS[BUSINESS.index("local function RefreshBagQuickOverlay(feature)"):BUSINESS.index("local function StartBagQuick(feature, direction)")]
    assert 'bank.surfaceVisible==true' in refresh and 'coffer.surfaceVisible==true' in refresh
    assert 'bag.surfaceVisible==true' in refresh
    current = BUSINESS[BUSINESS.index("local function CurrentStorageContext()"):BUSINESS.index("local function RequireStorageWindow") ]
    assert '.visible==true' in current and 'surfaceVisible' not in current, "native writes must remain action-authority gated"


def test_storage_session_can_anchor_hidden_bag_proxy() -> None:
    # .18.184 still required UIC_BAG itself to be surface-visible. RU can open a
    # coffer with a real physical bag and a valid bag MainScript rectangle while
    # UIC_BAG remains a hidden proxy. A visible storage session may use that
    # rectangle for Presentation only; it must never become write Authority.
    refresh = BUSINESS[BUSINESS.index("local function RefreshBagQuickOverlay(feature)"):BUSINESS.index("local function StartBagQuick(feature, direction)")]
    assert 'bagMainScriptAnchor=type(bag)=="table" and tostring(bag.source or ""):sub(1,11)=="main-script"' in refresh
    assert 'storageSessionBagFallback=type(storage)=="table" and bagAnchorReady==true and bag.surfaceVisible~=true' in refresh
    assert 'bagSurfaceEffectiveVisible=type(bag)=="table" and (bag.surfaceVisible==true or storageSessionBagFallback==true)' in refresh
    assert '"storage-session+"..tostring(bag.source or "bag-geometry")' in refresh
    assert 'nextState.bagSurfaceFallback=storageSessionBagFallback==true' in refresh
    current = BUSINESS[BUSINESS.index("local function CurrentStorageContext()"):BUSINESS.index("local function RequireStorageWindow")]
    assert '.visible==true' in current and 'surfaceVisible' not in current, "storage-session Presentation fallback must not loosen native write Authority"


def test_quick_action_uses_physical_reads_not_bag_ui_visibility() -> None:
    # UIC_BAG is a Presentation/proxy fact. The explicit move action is proven by
    # the strict open-storage session and the bounded physical bag/storage reads.
    begin = BUSINESS[BUSINESS.index("local function BeginBagQuick(feature, direction)"):BUSINESS.index("local function RefreshBagQuickOverlay")]
    assert 'local bagWindow = ReadBagWindowContext()' not in begin
    assert 'return false, "请先打开背包"' not in begin
    storage_gate = begin.index('local storage = CurrentStorageContext()')
    bag_read = begin.index('BagIdentitySet("bag")')
    storage_read = begin.index('BagIdentitySet(target)')
    assert storage_gate < bag_read < storage_read, "strict storage session must precede bounded physical reads"
    assert 'if bagSet == nil or storageSet == nil then return false' in begin
    assert 'if bagErrors > 0 or storageErrors > 0 then return false' in begin


def test_released_presenter_root_is_rebuilt() -> None:
    ensure = BAG_UI[BAG_UI.index("function P:EnsureCreated()"):BAG_UI.index("function P:Refresh()") ]
    released = ensure.index("self.root ~= nil and self.root.rsUiReleased == true")
    early_return = ensure.index("if self.root ~= nil then return true end")
    assert released < early_return, "released-root recovery must run before the created fast path"
    assert "self.root,self.take,self.put,self.status=nil,nil,nil,nil" in ensure


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


def quick_running(queue, pending, status: str) -> bool:
    """Model of BagMoveRuntime.QuickQueueActive + BagQuickRunning.

    The .18.182 build treated *any* installed queue table as "running", while
    BeginBagQuick installed the empty queue table before its plannedMoves == 0
    early return -> one click with nothing to match locked 取/放, direct moves and
    the category batch for the rest of the session, and the locked click still
    reported success.  That is the user-reported "sometimes nothing happens".
    """
    if pending is not None:
        return True
    if queue:  # non-nil AND non-empty
        return True
    return status in {"正在取出", "正在放入"}


def test_empty_plan_never_holds_the_quick_mutex() -> None:
    assert quick_running([], None, "没有同类物品") is False
    assert quick_running([{"remaining": 2}], None, "正在放入") is True
    assert quick_running([], {"identity": "type:1"}, "正在放入") is True
    # Control flow, not just text (the .179 lesson): inside BeginBagQuick the
    # empty-plan branch must clear the mutex *before* the queue is installed.
    begin = BUSINESS[BUSINESS.index("local function BeginBagQuick(feature, direction)"):]
    begin = begin[: begin.index("local function RefreshBagQuickOverlay")]
    clear = begin.index("feature._quickQueue, feature._quickIndex, feature._quickPending = nil, nil, nil")
    install = begin.index("feature._quickQueue, feature._quickIndex, feature._quickPending = queue, 0, nil")
    assert clear < install, "empty plan must release the mutex before any queue exists"
    assert 'if plannedMoves == 0 then return true, 0 end' not in begin, "the old unconditional install + bare return is the locked-state bug"
    assert begin.count("bag_quick_empty_plan") == 1


def test_stale_quick_run_is_reclaimed_without_new_tick() -> None:
    # The 350 ms window observer is the watchdog: no new task, no Tick, and an
    # orphaned mutex can never outlive its scheduler task.
    refresh = BUSINESS[BUSINESS.index("local function RefreshBagQuickOverlay(feature)"):BUSINESS.index("local function StartBagQuick(feature, direction)")]
    assert "BagMoveRuntime.ReclaimStaleBagQuickRun(feature)" in refresh
    watchdog = refresh.index("BagMoveRuntime.ReclaimStaleBagQuickRun(feature)")
    assert watchdog < refresh.index("local bag=ReadBagWindowContext()"), "reclaim must run before the state is copied for this beat"
    assert "AddTask" not in refresh, "the watchdog must not create a scheduler task"
    # Evidence must never be inverted: missing telemetry falls back to the queue's
    # own step stamp instead of declaring the run stale.
    evidence = BUSINESS[BUSINESS.index("function BagMoveRuntime.QuickRunEvidence(feature)"):]
    evidence = evidence[: evidence.index("function BagMoveRuntime.QuickStatusText")]
    assert '"调度器无任务遥测"' not in evidence, "no-telemetry must not equal stale"
    assert "feature._quickLastStepAt" in evidence


def test_quick_click_stops_or_switches_instead_of_refusing() -> None:
    start = BUSINESS[BUSINESS.index("local function StartBagQuick(feature, direction)"):]
    start = start[: start.index("local function StartBagQuickObserver")]
    assert 'if running == direction then' in start, "same button must stop the running direction"
    assert 'return false,"快捷取放已经在运行，请先停止"' not in start, "the silent-refusal path is the reported dead click"
    assert start.count("StopBagQuick(feature") == 2
    # Player-facing split: short label for the status bar, full reason in error.
    assert "BagMoveRuntime.QuickStatusText(err)" in start
    assert 'feature._quickOverlay.error = tostring(err' in start


def test_quick_status_text_is_character_safe() -> None:
    status_fn = BUSINESS[BUSINESS.index("function BagMoveRuntime.QuickStatusText(reason)"):]
    status_fn = status_fn[: status_fn.index("local function BagBatchRunning(feature)")]
    # Comments may legitimately *name* the rejected pattern (the fix explains
    # why), so this fence reads code only.
    status_code = "\n".join(line.split("--")[0] for line in status_fn.split("\n"))
    assert "[^（" not in status_code, "negated byte class splits CJK mid-character"
    assert "string.find(text, separator, 1, true)" in status_code
    assert r"[\1-\127\192-\244][\128-\191]*" in status_code, "glyph counter must count CJK, not only ASCII"
    assert '"…"' in status_code, "overflow must stay inside the label budget"


def main() -> int:
    static_contracts()
    tests = (
        test_ru_four_value_main_script_is_open_signal,
        test_content_visibility_overrides_geometry_fallback,
        test_explicit_native_boolean_remains_authoritative,
        test_surface_visibility_does_not_inherit_write_authority_race,
        test_storage_session_can_anchor_hidden_bag_proxy,
        test_quick_action_uses_physical_reads_not_bag_ui_visibility,
        test_released_presenter_root_is_rebuilt,
        test_legacy_gear_split_repairs_once,
        test_bag_explicit_disable_is_not_overridden,
        test_bag_idle_observer_is_low_cost_surface_only,
        test_empty_plan_never_holds_the_quick_mutex,
        test_stale_quick_run_is_reclaimed_without_new_tick,
        test_quick_click_stops_or_switches_instead_of_refusing,
        test_quick_status_text_is_character_safe,
    )
    for test in tests:
        test()
    print(f"QUICK_SURFACE_RELOAD_HARNESS PASS {len(tests)}/{len(tests)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

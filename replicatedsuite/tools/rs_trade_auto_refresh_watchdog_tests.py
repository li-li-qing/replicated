from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
# 中文维护注释（2026-09-28，Phase 2 Step 4）：life_trade 已搬到独立源码单元。
BUNDLE = (ROOT / "features/life/trade/rs_trade_feature.lua").read_text(encoding="utf-8")
PAGE = (ROOT / "presentation/v3/pages/rs_v3_life_m16_pages.lua").read_text(encoding="utf-8")
ACCEPTANCE = (ROOT / "presentation/v3/rs_v3_acceptance.lua").read_text(encoding="utf-8")
FOUNDATION = (ROOT / "core/rs_foundation_gate.lua").read_text(encoding="utf-8")


def require(cond, msg):
    if not cond:
        raise AssertionError(msg)

require('TA.AutoRefreshWatchdogContractVersion = 3' in BUNDLE, "missing watchdog v3 contract")
require('Trade.AutoRefreshBackgroundLeaseContractVersion = 2' in BUNDLE, "missing background-runtime compatibility contract")
require('Trade.AutoRefreshRuntimeContractVersion = 1' in BUNDLE, "missing independent auto-refresh runtime contract")
require('Trade.autoRefreshRuntimeOwner = { Id = "life_trade.auto_refresh" }' in BUNDLE, "missing independent runtime owner")
require('autoRefreshConsumerToken' not in BUNDLE, "auto-refresh must not masquerade as a page Demand consumer")
require('function Trade:ShouldRunAutoRefreshBackground' in BUNDLE, "missing background eligibility authority")
require('function Trade:ReconcileAutoRefreshRuntime' in BUNDLE and 'function Trade:StopAutoRefreshRuntime' in BUNDLE,
        "missing independent auto-refresh runtime lifecycle")
require('function Trade:EnsureAutoRefreshWorldSubscription' in BUNDLE, "missing bounded world-boundary accelerator")
require('function TA:HandleAutoRefreshBoundary' in BUNDLE, "missing lightweight world-boundary handler")
require('function TA:ScheduleNextAutoRefresh(reason)' in BUNDLE, "missing watchdog scheduler")
require('function TA:GetAutoRefreshWatchTaskState()' in BUNDLE, "watchdog must expose Scheduler task health")
require('staleRegisteredTask' in BUNDLE and 'diagnostics.staleRestarts' in BUNDLE,
        "watchdog must self-heal a registered-but-stale scheduler task")
require('Trade.autoRefreshRuntimeOwner or Trade, "P2", 1' in BUNDLE,
        "watchdog O(1) liveness check uses P2 so quote background work cannot starve it")
require('S.Scheduler:AddTask(self.requestAutoTask' in BUNDLE, "watchdog must use shared Scheduler AddTask")
require('Trade.autoRefreshRuntimeOwner or Trade' in BUNDLE, "watchdog must be owned by independent runtime owner")
require('TA:Request(false, "auto_refresh")' in BUNDLE, "watchdog must refresh through route SingleFlight Authority")
require('TA.inFlight ~= nil or TA.pendingRoute ~= nil or TA.timedOutFlight ~= nil' in BUNDLE,
        "watchdog must respect SingleFlight/quarantine")
require('(tonumber(Trade.consumerCount) or 0) <= 0' not in BUNDLE.split('function TA:ScheduleNextAutoRefresh(reason)', 1)[1].split('function TA:ArmCargoPump', 1)[0],
        "watchdog liveness must not depend on page/widget consumer count")
require('self:ReconcileAutoRefreshRuntime("feature_enable")' in BUNDLE,
        "feature enable must restore saved background runtime")
require('self:StopAutoRefreshRuntime("trade_auto_refresh_disabled")' in BUNDLE,
        "turning auto-refresh off must stop background runtime")
require('self:StopAutoRefreshRuntime("trade_view_cargo")' in BUNDLE,
        "cargo mode must stop ordinary route background runtime")
require('self:ReleasePriceQuoteSubscription()' in BUNDLE.split('function Trade:ReconcileDemand', 1)[1].split('function Trade:Enable', 1)[0],
        "page Demand release must still release QuoteQueue subscription")
require('TA:CancelLiveIdentities()' in BUNDLE.split('function Trade:ReconcileDemand', 1)[1].split('function Trade:Enable', 1)[0],
        "page Demand release must still release live identity work")
require('backgroundActive = self:ShouldRunAutoRefreshBackground() == true' in BUNDLE,
        "Demand release must preserve only the lightweight background runtime")
request = BUNDLE.split('function TA:Request(force, reason)', 1)[1].split('function TA:OnCargoRatio', 1)[0]
require('self:CancelAutoRefresh()' not in request, "Native request must not cancel watchdog")
require('if (tonumber(Trade.consumerCount) or 0) <= 0 then return end' in BUNDLE,
        "hidden auto-refresh must not keep LiveIdentity work active")
require('if Trade.enabled ~= true or (tonumber(Trade.consumerCount) or 0) <= 0 then return false, "no_consumers" end' in BUNDLE,
        "hidden auto-refresh must not start material-price SWR without a visible trade consumer")
require('autoRefreshState = self:GetAutoRefreshState()' in BUNDLE, "projection must expose watchdog state")
require('自动刷新约 ' in PAGE and '自动刷新：待机' in PAGE, "UI must expose watchdog liveness without extra polling")
require('AutoRefreshRuntimeContractVersion' in ACCEPTANCE and 'AutoRefreshWatchdogContractVersion' in ACCEPTANCE,
        "acceptance must reject mixed old/new auto-refresh runtime packages")
require('AutoRefreshRuntimeContractVersion' in FOUNDATION and 'AutoRefreshWatchdogContractVersion' in FOUNDATION,
        "foundation gate must reject mixed old/new auto-refresh runtime packages")
print("PASS: trade auto-refresh independent runtime / watchdog contracts")

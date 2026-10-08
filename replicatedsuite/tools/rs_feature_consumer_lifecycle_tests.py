#!/usr/bin/env python3
"""Static regression checks for Feature/Profile -> Presentation consumer lifecycle.

The ArcheAge client is Lua 5.1 and owns Native runtime behavior, so this test does
not pretend to emulate game APIs. It protects the source-level ownership contract
that prevents stale Presentation booleans from surviving FeatureRuntime Disable.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def text(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8")


def require(rel: str, *needles: str) -> None:
    source = text(rel)
    for needle in needles:
        assert needle in source, f"{rel}: missing contract marker {needle!r}"


def forbid(rel: str, *needles: str) -> None:
    source = text(rel)
    for needle in needles:
        assert needle not in source, f"{rel}: stale direct lifecycle path remains: {needle!r}"


def main() -> None:
    host = "presentation/v3/shell/rs_v3_page_host.lua"
    require(
        host,
        "version = 6",
        "featureConsumerLifecycleContractVersion = 1",
        "function H:SyncFeatureConsumer",
        "function H:ReleaseFeatureConsumer",
        "function H:BindFeatureConsumerLifecycle",
        "demand:Has(token) == true",
        "page.consumerHeld = false",
        "V3_PAGE_CONSUMER_REACQUIRE_FAILED",
    )

    # These pages may remain constructed/active while Feature Profiles changes
    # Runtime state. They must all use the shared lease/lifecycle bridge.
    bridged_pages = [
        "presentation/v3/pages/rs_v3_life_m16_pages.lua",
        "presentation/v3/pages/rs_v3_business_pages.lua",
        "presentation/v3/pages/rs_v3_activity_page.lua",
        "presentation/v3/pages/rs_v3_task_page.lua",
        "presentation/v3/pages/rs_v3_housing_page.lua",
        "presentation/v3/pages/rs_v3_instance_page.lua",
        "presentation/v3/pages/rs_v3_healer_page.lua",
        "presentation/v3/pages/rs_v3_raid_readiness_page.lua",
        "presentation/v3/pages/rs_v3_buff_display_page.lua",
    ]
    for rel in bridged_pages:
        require(rel, "BindFeatureConsumerLifecycle", "SyncFeatureConsumer", "ReleaseFeatureConsumer")

    # User retired Butler on 2026-10-02. Its old lifecycle must not be revived.
    assert not (ROOT / "presentation/v3/pages/rs_v3_butler_page.lua").exists()
    forbid("features/rs_feature_registry.lua", 'Add("life_butler"')
    forbid("toc.g", "features/life/butler/rs_butler_feature.lua")

    # The four M1.16 life routes share one Build() closure. Marker-only checks were
    # insufficient: 18.310 contained lifecycle calls but no local binding object,
    # so every page failed only when activated in the client. Pin both the binding
    # declaration and the legacy-stable per-kind Demand token.
    require(
        "presentation/v3/pages/rs_v3_life_m16_pages.lua",
        "LifeM16PagesContract",
        "featureConsumerBindingContractVersion = 1",
        "local consumerBinding = {",
        "featureId = tostring(feature.Id or \"\")",
        'token = "page:" .. tostring(kind)',
    )

    # Once a page adopts PageHost's lease contract it must not keep an independent
    # Feature:Acquire/Release path, otherwise Feature Profiles can reintroduce
    # duplicate ownership and strict-Demand double release.
    for rel in bridged_pages:
        forbid(rel, "Feature:AcquireConsumer(", "Feature:ReleaseConsumer(")

    require(
        "presentation/v3/pages/rs_v3_buff_display_page.lua",
        "Feature:SetManagementPageActive(false)",
        "Feature:SetCooldownManagementActive(false)",
        'featureId = "combat_buff_display"',
        'token = "page:buff_display"',
    )

    # Auxiliary windows that bypass normal PageHost need an explicit lifecycle
    # boundary of their own, or a WidgetHost binding.
    require(
        "presentation/v3/widgets/rs_v3_trade_detail_floating.lua",
        "feature-profile-lifecycle-1",
        "lifecycleTopic",
        "M.acquired = false",
        "M.surface:Show(false)",
    )
    require(
        "presentation/v3/widgets/rs_v3_auction_sidecar.lua",
        "Host:BindFeatureLifecycle(WIDGET_ID",
        'featureId = "tools_auction"',
    )
    require(
        "presentation/v3/widgets/rs_v3_craft_sidecar.lua",
        "Host:BindFeatureLifecycle(WIDGET_ID",
        'featureId = "tools_craft"',
        'Feature:HasConsumer("widget:craft_sidecar")',
    )

    require(
        "presentation/v3/rs_v3_acceptance.lua",
        "page_host_feature_consumer_lifecycle_contract",
        "life_m16_page_feature_consumer_binding_contract",
        "featureConsumerLifecycleContractVersion",
        "SyncFeatureConsumer",
        "ReleaseFeatureConsumer",
        "BindFeatureConsumerLifecycle",
    )

    # 中文维护注释（2026-09-28，Phase 2 Step 4）：本条按 §30 分类 B（旧硬编码 version）更新。
    # Authority：BuildTag 已按 Phase 0 闭合（.330）、Phase 1 闭合（.331）、Phase 2 首轮闭合（.332）
    # 连续合法推进，继续 pin .329 只会持续误报。
    require(
        "replicatedsuite.lua",
        'v3-m1.16.0.18.332-phase2-life-bundle-slice-complete',
    )

    print("PASS: feature consumer lifecycle regression contract")


if __name__ == "__main__":
    main()

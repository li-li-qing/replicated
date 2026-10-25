#!/usr/bin/env python3
# Replicated Suite · 功能消费者生命周期测试
# 作者：Replicated
# QQ群：1104129461
"""功能或预设切换与表现层消费者生命周期的静态回归。

ArcheAge 客户端采用 Lua 5.1，原生运行行为由客户端负责，本测试不模拟游戏 API。
保护源码中的所有权契约，避免 FeatureRuntime Disable 后表现层保留过期布尔状态。"""
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

    # 功能预设改变 Runtime 状态时，这些页面可能仍已构建或保持激活；
    # 所有页面必须通过共享需求租约及生命周期桥接管理消费者。
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

    # 用户于 2026-10-02 停用 Butler，不能恢复其旧生命周期。
    assert not (ROOT / "presentation/v3/pages/rs_v3_butler_page.lua").exists()
    forbid("features/rs_feature_registry.lua", 'Add("life_butler"')
    forbid("toc.g", "features/life/butler/rs_butler_feature.lua")

    # 四个 M1.16 生活路由共用同一 Build() 闭包，仅检查标记不足以验证契约；
    # 旧 18.310 虽包含生命周期调用，却没有本地绑定对象，
    # 因此各页面仅在客户端激活时失败；必须同时核对绑定对象声明
    # 和每种类型原有稳定的 Demand token。
    require(
        "presentation/v3/pages/rs_v3_life_m16_pages.lua",
        "LifeM16PagesContract",
        "featureConsumerBindingContractVersion = 1",
        "local consumerBinding = {",
        "featureId = tostring(feature.Id or \"\")",
        'token = "page:" .. tostring(kind)',
    )

    # 页面采用 PageHost 租约契约后，不能再保留独立的
    # Feature:Acquire/Release 路径，否则功能预设会重新引入
    # 重复所有权和严格 Demand 下的重复释放。
    for rel in bridged_pages:
        forbid(rel, "Feature:AcquireConsumer(", "Feature:ReleaseConsumer(")

    require(
        "presentation/v3/pages/rs_v3_buff_display_page.lua",
        "Feature:SetManagementPageActive(false)",
        "Feature:SetCooldownManagementActive(false)",
        'featureId = "combat_buff_display"',
        'token = "page:buff_display"',
    )

    # 绕过普通 PageHost 的辅助窗口必须自行声明生命周期边界，
    # 或使用 WidgetHost 绑定。
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

    require(
        "replicatedsuite.lua",
        'v3-m1.16.0.18.332-phase2-life-bundle-slice-complete',
    )

    print("PASS: feature consumer lifecycle regression contract")


if __name__ == "__main__":
    main()

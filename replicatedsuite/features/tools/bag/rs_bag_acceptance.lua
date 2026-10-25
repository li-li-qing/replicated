-- Replicated Suite · 背包整理契约验收
-- 作者：Replicated
-- QQ群：1104129461
-- 验证背包Feature自身25项契约版本下限与10条命令；实现缺失不得静默返回，失败为blocker，由sequence_harness报告。
-- InventorySnapshotV3物理背包权威、BagQuickOverlay和BusinessPagesContract等Service/UI契约仍归Foundation。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local G = S.FoundationGate
if type(G) ~= "table" or type(G.RegisterSequenceCase) ~= "function" then return end
local F = S.Features and S.Features.tools_bag or nil

local function Fail(message) return false, tostring(message or "bag_acceptance_failed") end

-- 运行时只做只读诊断；完整序列测试仅离线执行。
G:RegisterSequenceCase("v3_tools_bag_action_contract", function()
    if type(F) ~= "table" then return Fail("implementation_not_registered") end
    if (tonumber(F.BagMoveContractVersion) or 0) < 8 then return Fail("bag.move_v8") end
    if (tonumber(F.BatchLifecycleContractVersion) or 0) < 5 then return Fail("bag.batch_lifecycle_v5") end
    if (tonumber(F.NativeWindowQuickContractVersion) or 0) < 7 then return Fail("bag.native_quick_v7") end
    if (tonumber(F.ReloadQuickObserverContractVersion) or 0) < 3 then return Fail("bag.reload_observer_v3") end
    if (tonumber(F.ResponsiveWindowObserverContractVersion) or 0) < 1 then return Fail("bag.responsive_observer_v1") end
    if (tonumber(F.ProductBlacklistUxContractVersion) or 0) < 1 then return Fail("bag.product_blacklist_v1") end
    if (tonumber(F.BlacklistNameMetadataContractVersion) or 0) < 1 then return Fail("bag.blacklist_name_meta_v1") end
    if (tonumber(F.BlacklistExplicitLookupContractVersion) or 0) < 1 then return Fail("bag.blacklist_lookup_v1") end
    if (tonumber(F.RUFourValueWindowVisibilityContractVersion) or 0) < 2 then return Fail("bag.ru_visibility_v2") end
    if (tonumber(F.NativeVisibilityShapeContractVersion) or 0) < 1 then return Fail("bag.visibility_shape_v1") end
    if (tonumber(F.SurfaceVisibilitySplitContractVersion) or 0) < 1 then return Fail("bag.surface_split_v1") end
    if (tonumber(F.StorageSessionBagSurfaceContractVersion) or 0) < 1 then return Fail("bag.storage_session_surface_v1") end
    if (tonumber(F.BagActionPhysicalReadAuthorityContractVersion) or 0) < 1 then return Fail("bag.physical_read_authority_v1") end
    if (tonumber(F.VisiblePresenterRetryContractVersion) or 0) < 1 then return Fail("bag.presenter_retry_v1") end
    if (tonumber(F.DynamicSourceResolutionContractVersion) or 0) < 3 then return Fail("bag.dynamic_source_v3") end
    if (tonumber(F.QuickIdentityFallbackContractVersion) or 0) < 1 then return Fail("bag.identity_fallback_v1") end
    if (tonumber(F.BagTaskMutexContractVersion) or 0) < 2 then return Fail("bag.mutex_v2") end
    if (tonumber(F.QuickRunSelfHealContractVersion) or 0) < 1 then return Fail("bag.self_heal_v1") end
    if (tonumber(F.QuickTwoButtonContractVersion) or 0) < 1 then return Fail("bag.two_button_v1") end
    if (tonumber(F.QuickReasonVisibilityContractVersion) or 0) < 1 then return Fail("bag.reason_visibility_v1") end
    if (tonumber(F.QuickStatusTimestampContractVersion) or 0) < 1 then return Fail("bag.status_timestamp_v1") end
    if (tonumber(F.InventorySnapshotContractVersion) or 0) < 1 then return Fail("bag.inventory_bridge_v1") end
    if (tonumber(F.GroupedIntentQueueContractVersion) or 0) < 1 then return Fail("bag.grouped_intent_v1") end
    if (tonumber(F.FullStorageContinuationContractVersion) or 0) < 1 then return Fail("bag.full_storage_continue_v1") end
    if (tonumber(F.BatchTargetAutoContractVersion) or 0) < 1 then return Fail("bag.batch_target_auto_v1") end
    if (tonumber(F.AllDepositContractVersion) or 0) < 1 then return Fail("bag.deposit_all_v1") end
    if (tonumber(F.NativeBagAnchorContractVersion) or 0) < 1 or type(F.GetQuickBagAnchor) ~= "function" then return Fail("bag.native_anchor_v1") end
    if type(F.Commands) ~= "table" then return Fail("commands_table_missing") end
    for _, name in ipairs({ "QuickWithdraw", "QuickDeposit", "QuickDepositAll", "QuickCancel", "ResolveAndAddBlacklistItem", "AddGlobalBlacklistItem", "RemoveGlobalBlacklistItem", "SetBatchCategory", "SetBatchTarget", "SetBatchLimit", "DepositCategoryCurrent" }) do
        if type(F.Commands[name]) ~= "function" then return Fail("command." .. name) end
    end
    return true
end, { runtime = true })

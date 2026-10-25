-- Replicated Suite · 背包操作测试宿主
-- 作者：Replicated
-- QQ群：1104129461
-- 使用真实 Bag、InventorySnapshot、Demand、Persistence 和 Scheduler；仅原生容器由测试数据替代。
return function(options)
    options=options or {}
    local h=dofile('tools/rs_gear_page_test_host.lua')({disk=options.disk})
    local S=h.S
    if options.diagnostics then
        dofile('features/rs_feature_registry.lua')
        dofile('core/rs_diagnostic_detail.lua');dofile('core/rs_module_diagnostics.lua')
    end
    h.bag=h.Copy(options.bag or {});h.storage=h.Copy(options.storage or {})
    h.capacity=options.capacity or 64;h.storageCapacity=options.storageCapacity or 100
    h.storageVisible=true;h.inventoryReads=0;h.moves={};h.rejected=options.rejected or {}
    X2Bag={Capacity=function()return h.capacity end,GetBagItemInfo=function(_,_,slot)
        h.inventoryReads=h.inventoryReads+1;return h.Copy(h.bag[slot] or {}) end}
    X2Coffer={Capacity=function()return h.storageCapacity end,GetBagItemInfo=function(_,slot)
        h.inventoryReads=h.inventoryReads+1;return h.Copy(h.storage[slot] or {}) end}
    X2Bank={Capacity=function()return 0 end,GetBagItemInfo=function()return {}end}
    function X2Bag:MoveToEmptyCofferSlot(slot)
        local item=h.bag[slot];assert(item,'native move used stale slot')
        h.moves[#h.moves+1]=item.itemType
        if h.rejected[item.itemType] then return false end
        if #h.storage>=h.storageCapacity then return false end
        h.storage[#h.storage+1]=table.remove(h.bag,slot) -- 模拟原生背包操作后的槽位压缩。
        return true
    end
    UIC_BAG,UIC_BANK,UIC_COFFER='bag','bank','coffer'
    UIParent=h.Native(nil,'UIParent',0,0,1920,1080)
    function ADDON:GetContentMainScriptPosVis(id)
        if id=='bag' then return 700,420,400,530,true end
        if id=='coffer' then return 100,100,400,500,h.storageVisible end
        return nil,nil,nil,nil,false
    end
    function ADDON:GetContent()return nil end
    S.Api.IsCapabilityAllowed=function()return true end
    -- 使用真实 API 派发、冷却及 false 返回语义；仅原生宿主为测试替身。
    dofile('core/rs_demand.lua')
    dofile('features/shared/rs_feature_slice_factory.lua');dofile('features/shared/rs_shared_bounds.lua')
    dofile('services/rs_inventory_snapshot_v3.lua');dofile('features/tools/bag/rs_bag_feature.lua')
    h.F=assert(S.Features.tools_bag);assert(h.F:Initialize());assert(h.F:Enable())
    if options.diagnostics then
        S.FeatureRuntime.implementations={tools_bag=h.F,combat_gear=S.Features.Gear}
        S.FeatureRuntime.state={tools_bag={initialized=true,enabled=true},combat_gear={initialized=true,enabled=true}}
    end
    assert(h.inventoryReads==0,'enabling must not scan inventory')
    function h:Drain()
        for step=1,600 do
            if not S.Scheduler.tasks.v3_business_bag_quick_move then return end
            self.ms=self.ms+250
            assert(S.Scheduler:RunTask('v3_business_bag_quick_move'))
        end
        error('queue did not terminate')
    end
    return h
end

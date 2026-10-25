-- Replicated Suite · 目标监控功能入口
-- 作者：Replicated
-- QQ群：1104129461
-- 由 TARGET_CHANGED 和 Demand 驱动目标只读观察，不保留跨帧目标或枚举全部单位。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local FSF = S.FeatureSliceFactory
if type(FSF) ~= "table" then error("FeatureSliceFactory unavailable for combat_target_monitor") end
local Call, Text, NewFeature = FSF.Call, FSF.Text, FSF.NewFeature
local UnitApi = rawget(_G, "X2Unit")

local TARGET_MONITOR_TASK = "v3_business_target_monitor_distance"
NewFeature("combat_target_monitor", { apiDependencies = { "X2Unit:GetTargetUnitId", "X2Unit:UnitName", "X2Unit:UnitDistance" },
    observationContractVersion = 1,
    event = "TARGET_CHANGED",
    reconcileDemand = function(feature, before, after)
        local beforeCount = tonumber(before and before.count) or 0
        local afterCount = tonumber(after and after.count) or 0
        if beforeCount <= 0 and afterCount > 0 then
            if S.Scheduler == nil or type(S.Scheduler.AddTask) ~= "function" then return false, "目标距离刷新 Scheduler 不可用" end
            local added = S.Scheduler:AddTask(TARGET_MONITOR_TASK, 500, function()
                if feature.enabled == true and (tonumber(feature.consumerCount) or 0) > 0 then feature.Authority:Refresh("target_distance") end
            end, false, feature, "P1", 1)
            if added ~= true then return false, "目标距离刷新任务创建失败" end
            if type(S.Scheduler.SetTaskModule) == "function" then S.Scheduler:SetTaskModule(TARGET_MONITOR_TASK, feature.Id, false) end
        elseif beforeCount > 0 and afterCount <= 0 and S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then
            S.Scheduler:RemoveTask(TARGET_MONITOR_TASK)
        end
        return true
    end,
    onDisable = function()
        if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(TARGET_MONITOR_TASK) end
        return true
    end,
    onEvent = function(feature) return feature.Authority:Refresh("target_changed") end,
    read = function()
        local okId, id = Call("X2Unit:GetTargetUnitId", UnitApi, "GetTargetUnitId")
        local okName, name = Call("X2Unit:UnitName", UnitApi, "UnitName", "target")
        local okDistance, distance = Call("X2Unit:UnitDistance", UnitApi, "UnitDistance", "target")
        local has = okId and id ~= nil or okName and name ~= nil
        if not has then return {}, "empty", "当前没有可读目标" end
        return { { key = "target", name = Text(name, "目标"), text = "ID：" .. Text(id, "--"), statusText = okDistance and Text(distance, "--") or "--", tone = "default" } }, "ready"
    end,
})

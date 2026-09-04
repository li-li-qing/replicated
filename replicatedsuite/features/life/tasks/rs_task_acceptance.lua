------------------------------------------------------------------------
-- Replicated Suite V3 - Task Tracker Acceptance / Sequence Contract
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local G = S.FoundationGate
local F = S.Features and S.Features.Tasks or nil
if type(G) ~= "table" or type(G.RegisterSequenceCase) ~= "function" or type(F) ~= "table" then return end

local function Fail(message) return false, tostring(message or "task_acceptance_failed") end

G:RegisterSequenceCase("v3_m1_tasks", function()
    local meta = S.FeatureRegistry and S.FeatureRegistry:Get("life_tasks") or nil
    if meta == nil or tostring(meta.status) ~= "migrated_m1" or tostring(meta.authority) ~= "v3.tasks" then return Fail("metadata_contract") end
    if S.FeatureRuntime == nil or S.FeatureRuntime:IsImplemented("life_tasks") ~= true then return Fail("implementation_missing") end
    if type(F.ApiDependencies) ~= "table" or #F.ApiDependencies ~= 1 or F.ApiDependencies[1] ~= "QUEST" then return Fail("native_import_contract") end
    local store = S.Persistence and S.Persistence:GetStore(F.StoreId or "v3.tasks") or nil
    if store == nil or tostring(store.owner or "") ~= "v3.tasks" or tonumber(store.schemaVersion) ~= 1 then return Fail("store_contract") end
    if S.Services ~= nil and S.Services.Quest ~= nil then return Fail("legacy_quest_authority_loaded") end
    local progress = S.Services and S.Services.QuestProgressV3 or nil
    if type(progress) ~= "table" or type(progress.GetProgress) ~= "function" or type(progress.GetGroupDetail) ~= "function" then return Fail("progress_contract") end
    if S.UIV3 == nil or S.UIV3.PageHost == nil or S.UIV3.PageHost.factories["life.tasks"] == nil then return Fail("page_contract") end
    if S.UIV3.WidgetHost == nil or S.UIV3.WidgetHost:GetSpec("life.tasks") == nil then return Fail("widget_contract") end
    if type(F.Commands) ~= "table" or type(F.Commands.MarkStoreDirty) ~= "function"
        or type(F.Commands.SetWidgetWindowState) ~= "function" then return Fail("presentation_command_contract") end

    if S.FeatureRuntime:IsEnabled("life_tasks") ~= true then return true end

    local beforeFeatureConsumers = tonumber(F.consumerCount) or 0
    local beforeProgressConsumers = tonumber(progress.consumerCount) or 0
    local token, acquired = "acceptance:m1_tasks", false
    if beforeFeatureConsumers == 0 then
        local ok = F:AcquireConsumer(token)
        if ok ~= true then return Fail("consumer_acquire") end
        acquired = true
    end

    local dailyHealth, weeklyHealth = progress:GetHealth("daily"), progress:GetHealth("weekly")
    if type(dailyHealth) ~= "table" or tonumber(dailyHealth.projections) == nil or dailyHealth.running ~= true then
        if acquired then F:ReleaseConsumer(token) end
        return Fail("daily_progress_unavailable")
    end
    if type(weeklyHealth) ~= "table" or tonumber(weeklyHealth.projections) == nil then
        if acquired then F:ReleaseConsumer(token) end
        return Fail("weekly_progress_unavailable")
    end

    F.Authority:Refresh("acceptance")
    local dailyRows = F.Authority:GetRows("daily")
    local weeklyRows = F.Authority:GetRows("weekly")
    if type(dailyRows) ~= "table" or #dailyRows == 0 then if acquired then F:ReleaseConsumer(token) end; return Fail("daily_projection_empty") end
    if type(weeklyRows) ~= "table" or #weeklyRows == 0 then if acquired then F:ReleaseConsumer(token) end; return Fail("weekly_projection_empty") end
    for _, row in ipairs(dailyRows) do
        if row.parent == true and (tostring(row.groupKey or "") == "" or tostring(row.progressText or "") == "") then
            if acquired then F:ReleaseConsumer(token) end
            return Fail("daily_row_contract")
        end
    end

    if acquired then F:ReleaseConsumer(token) end
    if beforeFeatureConsumers == 0 and tonumber(F.consumerCount) ~= 0 then return Fail("feature_consumer_leak") end
    if tonumber(progress.consumerCount) ~= beforeProgressConsumers then return Fail("progress_consumer_leak") end
    return true
end)

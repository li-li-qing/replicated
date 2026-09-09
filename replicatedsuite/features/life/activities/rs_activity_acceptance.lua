------------------------------------------------------------------------
-- Replicated Suite V3 - Activity Acceptance / Sequence Contract
--
-- Bounded M1 probe. It never creates a second event Authority and never owns
-- presentation. When Activity is enabled and idle, the probe temporarily
-- acquires one synthetic consumer, validates projection identity/lifecycle, and
-- releases it before returning.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local G = S.FoundationGate
local F = S.Features and S.Features.Activities or nil
if type(G) ~= "table" or type(G.RegisterSequenceCase) ~= "function" or type(F) ~= "table" then return end

local function Fail(message) return false, tostring(message or "activity_acceptance_failed") end

G:RegisterSequenceCase("v3_m1_activities", function()
    local meta = S.FeatureRegistry and S.FeatureRegistry:Get("life_activities") or nil
    if meta == nil or tostring(meta.status) ~= "migrated_m1" or tostring(meta.authority) ~= "v3.activity" then
        return Fail("metadata_contract")
    end
    if S.FeatureRuntime == nil or S.FeatureRuntime:IsImplemented("life_activities") ~= true then
        return Fail("implementation_missing")
    end
    local store = S.Persistence and S.Persistence:GetStore(F.StoreId or "v3.activities") or nil -- 中文维护注释：Acceptance 只读取 Persistence 注册事实，不创建第二 Store Authority，也不触发额外 Load/Save。
    if store == nil or tostring(store.owner or "") ~= "v3.activities" or tonumber(store.schemaVersion) ~= 8 -- 中文维护注释：`.18.193` 当前活动偏好必须是 schema8，避免共享 FloatingSurface 增字段后继续在 schema7 内偷换 canonical。
        or (tonumber(F.PersistenceStoreSchemaContractVersion) or 0) < 8 -- 中文维护注释：Feature 显式暴露 schema 契约，防止只改注册数字却漏掉维护边界声明。
        or (tonumber(F.PersistenceWindowCanonicalContractVersion) or 0) < 1 -- 中文维护注释：窗口持久化必须经过 Store-owned 字段投影，而不是直接 Hash 可演进 Foundation 返回表。
        or (tonumber(F.KnownLegacyCanonicalRecoveryContractVersion) or 0) < 1 -- 中文维护注释：要求活动 Store 保留严格 old/new fingerprint 一次性迁移桥，旧档不得靠清档恢复。
        or type(store.rebuildCanonicalForIntegrity) ~= "function" -- 中文维护注释：schema7 历史 canonical 必须先走 exact Hash 重建，known-pair 只能作为其后的最后恢复边界。
        or type(store.recoverKnownLegacyCanonical) ~= "function" then -- 中文维护注释：实机 6271E40B→7E85D975 必须由 Store-owned hook 验证，Persistence Core 不增加通用 bypass。
        return Fail("store_contract") -- 中文维护注释：任何契约缺失都阻断发布，避免下一轮再次把持久化 Fence 表现误诊成页面/Toggle 故障。
    end -- 中文维护注释：结束活动 schema8 + canonical recovery Acceptance 门禁。
    -- Legacy EventService is reference-only in V3 rebuild mode. A stale runtime
    -- Authority would make both event clocks compete, so fail the gate loudly.
    if S.Services ~= nil and S.Services.Event ~= nil then return Fail("legacy_event_authority_loaded") end
    local progress = S.Services and S.Services.QuestProgressV3 or nil
    if type(progress) ~= "table" or type(progress.GetQuestProgress) ~= "function" or type(progress.GetInstanceProgress) ~= "function"
        or type(progress.GetGroupDetail) ~= "function" then
        return Fail("v3_progress_service_missing")
    end
    local instanceCatalog = S.Services and S.Services.InstanceCatalogV3 or nil
    if type(instanceCatalog) ~= "table" or type(instanceCatalog.GetEntryProgress) ~= "function" then
        return Fail("v3_instance_catalog_missing")
    end
    local detailModal = S.UIV3 and S.UIV3.QuestDetailModalV3 or nil
    if type(detailModal) ~= "table" or type(detailModal.Open) ~= "function" then
        return Fail("v3_quest_detail_modal_missing")
    end
    if type(F.Commands) ~= "table" or type(F.Commands.MarkStoreDirty) ~= "function"
        or type(F.Commands.SetWidgetWindowState) ~= "function" then
        return Fail("presentation_command_contract")
    end

    if S.FeatureRuntime:IsEnabled("life_activities") ~= true then
        -- A user-disabled Feature is valid. The contracts above are still
        -- checked, while no gameplay API is touched just to satisfy diagnostics.
        return true
    end

    local beforeConsumers = tonumber(F.consumerCount) or 0
    local token = "acceptance:m1_activity"
    local acquired = false
    if beforeConsumers == 0 then
        local ok = F:AcquireConsumer(token)
        if ok ~= true then return Fail("consumer_acquire") end
        acquired = true
    end

    local progressHealth = progress:GetHealth()
    local instanceHealth = instanceCatalog:GetHealth()
    if type(progressHealth) ~= "table" or progressHealth.running ~= true or (tonumber(progressHealth.consumers) or 0) < 1 then
        if acquired then F:ReleaseConsumer(token) end
        return Fail("progress_service_not_acquired")
    end
    if progressHealth.instanceDemand ~= true or type(instanceHealth) ~= "table" or instanceHealth.running ~= true then
        if acquired then F:ReleaseConsumer(token) end
        return Fail("instance_catalog_not_acquired")
    end

    local rows = F.Authority and F.Authority:GetRows() or {}
    local seen = {}
    local staticCount, liveCount = 0, 0
    for _, row in ipairs(type(rows) == "table" and rows or {}) do
        local key = tostring(row and row.key or "")
        if key == "" then if acquired then F:ReleaseConsumer(token) end; return Fail("empty_row_key") end
        if seen[key] then if acquired then F:ReleaseConsumer(token) end; return Fail("duplicate_row_key:" .. key) end
        seen[key] = true
        if row.zoneState == true then liveCount = liveCount + 1 else staticCount = staticCount + 1 end
    end

    if acquired then F:ReleaseConsumer(token) end
    if staticCount == 0 then return Fail("static_projection_empty") end
    if liveCount < #(S.Data and S.Data.ZoneStateWatch or {}) then return Fail("live_projection_incomplete") end

    if beforeConsumers == 0 and S.Scheduler ~= nil and S.Scheduler.tasks ~= nil then
        local timer = S.Scheduler.tasks[F.timerTask]
        local zones = S.Scheduler.tasks[F.zoneTask]
        if timer == nil or zones == nil or timer.enabled == true or zones.enabled == true then return Fail("idle_tasks_not_released") end
    end
    return true
end)

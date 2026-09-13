------------------------------------------------------------------------
-- Replicated Suite V3 - Bonds / Resident Board Acceptance / Sequence Contract
--
-- 中文维护注释：该门禁验证债券 / 居民板（life.bonds）在 V3 架构下的生命周期、
-- Authority 契约、Store 注册、命令完整性、悬浮窗/页面规格以及空板/就绪/不可用状态。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local G = S.FoundationGate
local F = S.Features and S.Features.Bonds or nil
if type(G) ~= "table" or type(G.RegisterSequenceCase) ~= "function" or type(F) ~= "table" then return end

local function Fail(message) return false, tostring(message or "bonds_acceptance_failed") end

G:RegisterSequenceCase("v3_m1_bonds", function()
    local meta = S.FeatureRegistry and S.FeatureRegistry:Get("life_bonds") or nil
    if meta == nil or tostring(meta.authority) ~= "v3.life.bonds" then return Fail("metadata_contract") end
    if S.FeatureRuntime == nil or S.FeatureRuntime:IsImplemented("life_bonds") ~= true then return Fail("implementation_missing") end

    local store = S.Persistence and S.Persistence:GetStore(F.storeId or "v3.life.bonds") or nil
    if store == nil or tostring(store.owner or "") ~= "v3.life.bonds" then return Fail("store_contract") end

    if S.UIV3 == nil or S.UIV3.PageHost == nil or S.UIV3.PageHost.factories["life.bonds"] == nil then return Fail("page_contract") end
    if S.UIV3.WidgetHost == nil or S.UIV3.WidgetHost:GetSpec("life.bonds") == nil then return Fail("widget_contract") end

    if type(F.Commands) ~= "table"
        or type(F.Commands.Refresh) ~= "function"
        or type(F.Commands.SetSortMode) ~= "function"
        or type(F.Commands.SetBondFilterOption) ~= "function"
        or type(F.Commands.SetDuplicatePriority) ~= "function"
        or type(F.Commands.SelectRow) ~= "function"
        or type(F.Commands.GetSelectedRow) ~= "function"
        or type(F.Commands.GetRow) ~= "function"
        or type(F.Commands.MarkStoreDirty) ~= "function"
        or type(F.Commands.SetWidgetWindowState) ~= "function" then
        return Fail("presentation_command_contract")
    end

    if S.FeatureRuntime:IsEnabled("life_bonds") ~= true then return true end

    local beforeConsumers = tonumber(F.consumerCount) or 0
    local token, acquired = "acceptance:m1_bonds", false
    if beforeConsumers == 0 then
        local ok, err = F:AcquireConsumer(token)
        if ok ~= true then return Fail("consumer_acquire: " .. tostring(err)) end
        acquired = true
    end

    F.Authority:Refresh()
    local projection = F:GetProjection()
    if type(projection) ~= "table" then
        if acquired then F:ReleaseConsumer(token) end
        return Fail("projection_missing")
    end
    if type(projection.rows) ~= "table" then
        if acquired then F:ReleaseConsumer(token) end
        return Fail("projection_rows_missing")
    end
    local status = tostring(projection.status or "")
    if status ~= "ready" and status ~= "empty" and status ~= "unavailable" then
        if acquired then F:ReleaseConsumer(token) end
        return Fail("invalid_projection_status: " .. status)
    end

    local cacheDesc = type(F.DescribeDailyCache) == "function" and F:DescribeDailyCache() or nil
    if type(cacheDesc) ~= "table" or cacheDesc.dayKey == nil then
        if acquired then F:ReleaseConsumer(token) end
        return Fail("cache_description_missing")
    end

    -- Test row lookup & selection contract
    if #projection.rows > 0 then
        local first = projection.rows[1]
        F.Commands:SelectRow(first.key)
        local selected = F.Commands:GetSelectedRow()
        if selected == nil or tostring(selected.key or "") ~= tostring(first.key or "") then
            if acquired then F:ReleaseConsumer(token) end
            return Fail("row_selection_failed")
        end
        local found = F.Commands:GetRow(first.key)
        if found == nil or tostring(found.key or "") ~= tostring(first.key or "") then
            if acquired then F:ReleaseConsumer(token) end
            return Fail("row_lookup_failed")
        end
    end

    if acquired then F:ReleaseConsumer(token) end
    return true
end)

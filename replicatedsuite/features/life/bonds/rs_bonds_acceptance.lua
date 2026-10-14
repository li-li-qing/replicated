------------------------------------------------------------------------
-- Replicated Suite · 债券与居民委托板契约验收
-- 作者：Replicated
-- QQ群：1104129461
--
-- 合并前必须清除冲突标记，核对源码与加载清单完整性。
-- Authority、调用数据流与存档协议保持下方实现的原有责任，
-- 禁止通过清配置、跳过加载或恢复Legacy绕过故障；源码与toc.g、UI实现必须成套，
-- 合并后先检查Lua语法，再做运行时验收。
-- 该门禁验证债券 / 居民板（life.bonds）在 V3 架构下的生命周期、
-- Authority 契约、Store 注册、命令完整性、悬浮窗/页面规格以及空板/就绪/不可用状态。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local G = S.FoundationGate
if type(G) ~= "table" or type(G.RegisterSequenceCase) ~= "function" then return end
-- 本文件是 life_bonds 的
-- **唯一契约 Authority**。原先 F 缺失时这里静默 return，把“实现根本没注册”留给 Foundation 的
-- 硬编码独立契约检查；这里必须**无条件注册** case，并在实现缺失时明确失败
-- （注意：注释里不要写成带点号的“表名+字段”形式，rs_architecture_audit 是行级正则且不跳过注释）。
local F = S.Features and S.Features.Bonds or nil

local function Fail(message) return false, tostring(message or "bonds_acceptance_failed") end

G:RegisterSequenceCase("v3_m1_bonds", function(runtimeOnly)
    if type(F) ~= "table" then return Fail("implementation_not_registered") end
    local meta = S.FeatureRegistry and S.FeatureRegistry:Get("life_bonds") or nil
    if meta == nil or tostring(meta.authority) ~= "v3.life.bonds" then return Fail("metadata_contract") end
    if S.FeatureRuntime == nil or S.FeatureRuntime:IsImplemented("life_bonds") ~= true then return Fail("implementation_missing") end

    local store = S.Persistence and S.Persistence:GetStore(F.storeId or "v3.life.bonds") or nil
    if store == nil or tostring(store.owner or "") ~= "v3.life.bonds" then return Fail("store_contract") end
    -- 债券曾在 schema=1 内新增 canonical 字段。
    -- Historical bridge 属于 Bonds Store 自己的兼容契约；若未来重构漏注册，旧合法存档会再次被 Core 正确地 fence。
    -- Acceptance 因此只检查 hook 存在，不在此绕过/模拟 Hash；exact old-stamp 认证仍完全由 Persistence Core 执行。
    if type(store.rebuildCanonicalForIntegrity) ~= "function" then return Fail("store_historical_canonical_contract") end

    if S.UIV3 == nil or S.UIV3.PageHost == nil or S.UIV3.PageHost.factories["life.bonds"] == nil then return Fail("page_contract") end
    if S.UIV3.WidgetHost == nil or S.UIV3.WidgetHost:GetSpec("life.bonds") == nil then return Fail("widget_contract") end

    -- 原大陆板族识别、六种材料身份与
    -- Dropdown 原子命令必须整套存在；否则部分覆盖文件会让 UI 看似可用却继续漏原大陆/写多次 Store。
    if (tonumber(F.MultiContinentSnapshotContractVersion) or 0) < 3
        or (tonumber(F.ResidentBoardFamilyContractVersion) or 0) < 1
        or (tonumber(F.AuroriaMaterialContractVersion) or 0) < 1
        or (tonumber(F.DropdownPresentationContractVersion) or 0) < 2
        or type(F.Commands) ~= "table"
        or type(F.Commands.Refresh) ~= "function"
        or type(F.Commands.SetDisplayOrder) ~= "function"
        or type(F.Commands.SetFilterMask) ~= "function"
        or type(F.Commands.SetDuplicateMode) ~= "function"
        or type(F.GetDisplayOrderKey) ~= "function"
        or type(F.GetFilterMask) ~= "function"
        or type(F.GetDuplicateMode) ~= "function"
        or type(F.Commands.SetSortMode) ~= "function"
        or type(F.Commands.SetContinentOrder) ~= "function"
        or type(F.Commands.SetBondFilterOption) ~= "function"
        or type(F.Commands.SetDuplicatePriority) ~= "function"
        or type(F.Commands.SelectRow) ~= "function"
        or type(F.Commands.GetSelectedRow) ~= "function"
        or type(F.Commands.GetRow) ~= "function"
        or type(F.Commands.MarkStoreDirty) ~= "function"
        or type(F.Commands.SetWidgetWindowState) ~= "function" then
        return Fail("presentation_command_contract")
    end

    -- 玩家诊断到此只读返回；下方租约/刷新/选择测试仅离线执行。
    if runtimeOnly == true then return true end
    if S.FeatureRuntime:IsEnabled("life_bonds") ~= true then return true end

    local beforeConsumers = tonumber(F.consumerCount) or 0
    local token, acquired = "acceptance:m1_bonds", false
    if beforeConsumers == 0 then
        local ok, err = F:AcquireConsumer(token)
        if ok ~= true then return Fail("consumer_acquire: " .. tostring(err)) end
        acquired = true
        -- 债券任务状态的 Authority 在 QuestProgressV3；
        -- 第一个 Bonds Consumer 必须同步持有该服务并订阅内部更新，否则真实交任务后只能等偶发刷新。
        local progress = S.Services and S.Services.QuestProgressV3 or nil
        if type(progress) ~= "table" or F.progressConsumerHeld ~= true or F.progressSubscribed ~= true
            or (tonumber(progress.consumerCount) or 0) <= 0 then
            F:ReleaseConsumer(token)
            return Fail("quest_progress_lifecycle_not_held")
        end
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

    -- 测试行查询与选择契约。
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

    if acquired then
        local released, releaseErr = F:ReleaseConsumer(token)
        if released ~= true then return Fail("consumer_release: " .. tostring(releaseErr)) end
        if F.progressConsumerHeld == true or F.progressSubscribed == true then return Fail("quest_progress_lifecycle_not_released") end
    end
    return true
end, { runtime = true })

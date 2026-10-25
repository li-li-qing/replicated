-- Replicated Suite · 基础设施就绪门禁
-- 作者：Replicated
-- QQ群：1104129461
-- 按需检查基础设施并生成可复制结果，不加载 Store、获取消费者或写 Native。
-- rs_architecture_audit 也扫描注释，避免在 Core 注释中写具体业务表的点号字段访问。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite

S.FoundationGate = {
    version = 147,
    last = nil,
    sequenceCases = {},
    sequenceOrder = {},
    runtimeCases = {},
}
local G = S.FoundationGate

local function AddCheck(report, id, ok, severity, detail)
    local row = { id=tostring(id), ok=ok == true, severity=tostring(severity or "blocker"), detail=tostring(detail or "") }
    report.checks[#report.checks + 1] = row
    if not row.ok then
        if row.severity == "blocker" then report.blockers = report.blockers + 1 else report.warnings = report.warnings + 1 end
    end
    return row
end

local function Join(values, maxItems)
    local out = {}
    for i=1,math.min(#values, math.max(1, tonumber(maxItems) or #values)) do out[#out+1] = tostring(values[i]) end
    if #values > #out then out[#out+1] = "+" .. tostring(#values - #out) end
    return table.concat(out, ",")
end

-- skipSequences=true 时仅运行显式声明 runtime=true 的只读 case。
-- 这些 case 必须跳过恢复探针、消费者和状态修改，避免玩家诊断清空统计或改写配置。
function G:RegisterSequenceCase(id, fn, options)
    id = tostring(id or "")
    if id == "" or type(fn) ~= "function" then return false end
    if self.sequenceCases[id] == nil then self.sequenceOrder[#self.sequenceOrder+1] = id; table.sort(self.sequenceOrder) end
    self.sequenceCases[id] = fn
    self.runtimeCases[id] = type(options) == "table" and options.runtime == true or nil
    return true
end

function G:RunRuntimeContracts(report)
    local result = { total=0, passed=0, failed=0, failures={} }
    for _, id in ipairs(self.sequenceOrder) do
        if self.runtimeCases[id] == true then
            result.total = result.total + 1
            -- Lua 5.1 的 xpcall 不转发附加参数，必须用闭包传只读模式。
            local ok, value, detail = xpcall(function() return self.sequenceCases[id](true) end, S.SafeTraceback)
            local passed = ok and value == true
            local reason = ok and tostring(detail or (passed and "readonly_contract_ok" or "returned_non_true")) or tostring(value)
            if passed then result.passed = result.passed + 1
            else
                result.failed = result.failed + 1
                result.failures[#result.failures+1] = id .. ":" .. reason
            end
            AddCheck(report, "runtime_contract:" .. id, passed, "blocker", reason)
        end
    end
    report.runtimeContracts = result
    return result
end

function G:RunSequences()
    local result = { total=0, passed=0, failed=0, failures={} }
    for _, id in ipairs(self.sequenceOrder) do
        result.total = result.total + 1
        local ok, value, detail = xpcall(self.sequenceCases[id], S.SafeTraceback)
        local passed = ok and value ~= false
        if passed then
            result.passed = result.passed + 1
        else
            result.failed = result.failed + 1
            local reason = ok and tostring(detail or "returned_false") or tostring(value)
            result.failures[#result.failures+1] = id .. ":" .. reason
        end
    end
    return result
end

-- durableVerifyFailures/readbackVerifyFailures 是本次加载以来的历史计数，重试成功也不清零。
-- 当前健康按 Describe 的 currentFailures 及结构失败判断，历史事件另报 warning。
-- 旧 Persistence 缺少当前故障汇总能力时按不可用处理；这里只读，不重试保存或加载。
function G:EvaluatePersistenceReliabilityV6(persistence)
    persistence = type(persistence) == "table" and persistence or nil
    local stats = persistence and type(persistence.stats) == "table" and persistence.stats or {}
    local contract = persistence and (tonumber(persistence.reliabilityContractVersion) or 0) or 0
    local envelope = persistence and (tonumber(persistence.envelopeIntegrityContractVersion) or 0) or 0
    local scope = persistence and (tonumber(persistence.scopeBindingContractVersion) or 0) or 0
    local currentContract = persistence and (tonumber(persistence.currentFailureSummaryContractVersion) or 0) or 0
    local currentFailures = persistence and tonumber(persistence.currentFailures) or nil
    local ok = persistence ~= nil
        and contract >= 6
        and envelope >= 1
        and scope >= 1
        and currentContract >= 1
        and type(S.Persistence) == "table"
        and type(S.Persistence.FingerprintEnvelopeIntegrity) == "function"
        and (tonumber(stats.envelopeIntegrityLoadFailures) or 0) == 0
        and (tonumber(stats.decodedLoadRejects) or 0) == 0
        and currentFailures ~= nil and currentFailures == 0
        and (tonumber(stats.scopeBindingMismatches) or 0) == 0
    local detail = "contract=" .. tostring(contract)
        .. "/envelope=" .. tostring(envelope)
        .. "/scope=" .. tostring(scope)
        .. "/currentContract=" .. tostring(currentContract)
        .. "/currentFail=" .. tostring(currentFailures == nil and "missing" or currentFailures)
        .. "/envelopeStamped=" .. tostring(stats.envelopeIntegrityStampedSaves or 0)
        .. "/envelopeCheck=" .. tostring(stats.envelopeIntegrityLoadChecks or 0)
        .. "/envelopeFail=" .. tostring(stats.envelopeIntegrityLoadFailures or 0)
        .. "/decodedReject=" .. tostring(stats.decodedLoadRejects or 0)
        .. "/durable=" .. tostring(stats.durableVerifyAttempts or 0)
        .. "/durableFail=" .. tostring(stats.durableVerifyFailures or 0)
        .. "/scopeMismatch=" .. tostring(stats.scopeBindingMismatches or 0)
        .. "/scopeRebind=" .. tostring(stats.scopeRebinds or 0)
    return ok, detail
end


-- 依赖须在本作用域独立解析；引用其它词法块的局部变量会退化为 nil 全局，误报背包服务不可用。
function G:EvaluateBagActionContract()
    local missing = {}
    local function Require(ok, token)
        if ok ~= true then missing[#missing + 1] = tostring(token) end
    end

    -- 背包动作由 features/tools/bag/rs_bag_acceptance.lua 检查；此处只验共享服务和 UI 契约。
    local inventorySnapshot = S.Services and S.Services.InventorySnapshotV3 or nil
    local bagQuickPresenter = S.UIV3 and S.UIV3.BagQuickOverlay or nil
    local bagSettingsPresenter = S.UIV3 and S.UIV3.BagSettingsFloatingV3 or nil
    local businessPagesContract = S.UIV3 and S.UIV3.BusinessPagesContract or nil

    Require(type(inventorySnapshot) == "table", "inventory.service")
    Require(type(inventorySnapshot) == "table" and (tonumber(inventorySnapshot.SnapshotContractVersion) or 0) >= 1, "inventory.snapshot_v1")
    Require(type(inventorySnapshot) == "table" and (tonumber(inventorySnapshot.PhysicalBagAuthorityContractVersion) or 0) >= 1, "inventory.physical_bag_v1")
    Require(type(inventorySnapshot) == "table" and (tonumber(inventorySnapshot.IndexContractVersion) or 0) >= 1, "inventory.index_v1")
    Require(type(inventorySnapshot) == "table" and tonumber(inventorySnapshot.PreferredBagId) == 1 and tonumber(inventorySnapshot.FallbackBagId) == 0, "inventory.bag_id_authority")
    Require(type(inventorySnapshot) == "table" and type(inventorySnapshot.BuildSnapshot) == "function", "inventory.BuildSnapshot")
    Require(type(inventorySnapshot) == "table" and type(inventorySnapshot.FindLiveRow) == "function", "inventory.FindLiveRow")
    Require(type(inventorySnapshot) == "table" and type(inventorySnapshot.CountLive) == "function", "inventory.CountLive")
    Require(type(inventorySnapshot) == "table" and type(inventorySnapshot.ReadPhysicalBagSlot) == "function", "inventory.ReadPhysicalBagSlot")



    Require(type(businessPagesContract) == "table" and (tonumber(businessPagesContract.bagProductUxContractVersion) or 0) >= 2, "pages.bag_product_ux_v2")
    Require(type(bagQuickPresenter) == "table" and (tonumber(bagQuickPresenter.version) or 0) >= 10, "presenter.v10")
    Require(type(bagQuickPresenter) == "table" and (tonumber(bagQuickPresenter.ReleasedRootRecoveryContractVersion) or 0) >= 1, "presenter.root_recovery_v1")
    Require(type(bagQuickPresenter) == "table" and (tonumber(bagQuickPresenter.ReloadVisibilityContractVersion) or 0) >= 2, "presenter.reload_visibility_v2")
    Require(type(bagQuickPresenter) == "table" and (tonumber(bagQuickPresenter.NativeTransientHostContractVersion) or 0) >= 1, "presenter.native_host_v1")
    Require(type(bagQuickPresenter) == "table" and (tonumber(bagQuickPresenter.VisibleRetryContractVersion) or 0) >= 1, "presenter.visible_retry_v1")
    Require(type(bagQuickPresenter) == "table" and (tonumber(bagQuickPresenter.TwoButtonContractVersion) or 0) >= 1, "presenter.two_button_v1")
    Require(type(bagQuickPresenter) == "table" and (tonumber(bagQuickPresenter.DiffRenderContractVersion) or 0) >= 1, "presenter.diff_render_v1")
    Require(type(bagQuickPresenter) == "table" and (tonumber(bagQuickPresenter.HintYieldContractVersion) or 0) >= 1, "presenter.hint_yield_v1")
    Require(type(bagQuickPresenter) == "table" and (tonumber(bagQuickPresenter.QuietByDefaultContractVersion) or 0) >= 1, "presenter.quiet_default_v1")
    Require(type(bagQuickPresenter) == "table" and (tonumber(bagQuickPresenter.FreePlacementContractVersion) or 0) >= 1, "presenter.free_placement_v1")
    Require(type(bagQuickPresenter) == "table" and (tonumber(bagQuickPresenter.FourButtonContractVersion) or 0) >= 1, "presenter.four_button_v1")
    Require(type(bagQuickPresenter) == "table" and (tonumber(bagQuickPresenter.DurablePlacementContractVersion) or 0) >= 1, "presenter.durable_placement_v1")
    Require(type(bagQuickPresenter) == "table" and type(bagQuickPresenter.ResetPosition) == "function"
        and type(bagQuickPresenter.CommitPosition) == "function", "presenter.placement_commands")
    local positionStore = S.Persistence and type(S.Persistence.GetStore) == "function"
        and S.Persistence:GetStore("v3.presentation.bag_quick_overlay") or nil
    Require(type(positionStore) == "table" and positionStore.registrationBudgetOk == true, "presenter.placement_store")
    Require(type(bagSettingsPresenter) == "table" and type(bagSettingsPresenter.Open) == "function" and type(bagSettingsPresenter.GetHealth) == "function", "presenter.bag_settings")

    if #missing == 0 then
        return true, "shared physical-bag snapshot + durable free placement + four-button overlay + grouped-intent quick/category queues + live slot revalidation + start/stop/switch + floating blacklist settings present"
    end
    return false, "missing=" .. Join(missing, 16)
end

function G:Run(options)
    options = type(options) == "table" and options or {}
    local report = { version=self.version, checks={}, blockers=0, warnings=0, status="BLOCKED" }

    local host = S.UIHostManager and S.UIHostManager:Describe() or nil
    local v3HostRegistered = S.UIHostManager ~= nil
        and type(S.UIHostManager.IsRegistered) == "function"
        and S.UIHostManager:IsRegistered("v3")
    AddCheck(report, "presentation_host", host ~= nil and tonumber(host.total) and host.total >= 1 and host.activeId ~= nil,
        "blocker", host and ("active=" .. tostring(host.activeId) .. "/hosts=" .. tostring(host.total) .. "/fail=" .. tostring(host.stats and host.stats.failures or 0)) or "missing")
    if host ~= nil then
        AddCheck(report, "presentation_navigation_authority",
            (tonumber(host.contractV2) or 0) == (tonumber(host.total) or 0)
                and (tonumber(host.navigationReady) or 0) == (tonumber(host.total) or 0),
            "blocker", "v2=" .. tostring(host.contractV2 or 0) .. "/" .. tostring(host.total or 0)
                .. "/nav=" .. tostring(host.navigationReady or 0)
                .. "/routeFail=" .. tostring(host.stats and host.stats.routeFailures or 0))
    end

    if tostring(S.ArchitectureMode or "") == "v3_rebuild" then
        local legacyRegistered = S.UIHostManager ~= nil and type(S.UIHostManager.IsRegistered) == "function" and S.UIHostManager:IsRegistered("legacy")
        local staleLegacyEntry = S.MainWindow ~= nil or S.MainButton ~= nil or S.TaskWidget ~= nil or S.EventWidget ~= nil
        AddCheck(report, "legacy_presentation_detached", legacyRegistered ~= true and staleLegacyEntry ~= true, "blocker",
            "host=" .. tostring(legacyRegistered == true) .. "/stale=" .. tostring(staleLegacyEntry == true))
    end

    local nativeInfo = S.NativeCapabilities and type(S.NativeCapabilities.Describe) == "function" and S.NativeCapabilities:Describe() or nil
    local nativeOk, nativeErr = false, "native capabilities missing"
    if S.NativeCapabilities ~= nil and type(S.NativeCapabilities.Validate) == "function" then
        nativeOk, nativeErr = S.NativeCapabilities:Validate()
    end
    AddCheck(report, "native_foundation", nativeOk == true, "blocker",
        nativeOk == true and ("owner=" .. tostring(nativeInfo and nativeInfo.owner or "?") .. "/contract=" .. tostring(nativeInfo and nativeInfo.contract and nativeInfo.contract.version or "?"))
            or tostring(nativeErr or "invalid"))
    AddCheck(report, "native_independence", nativeInfo ~= nil
            and tonumber(nativeInfo.externalGlobalsConsumed) == 0
            and tonumber(nativeInfo.legacyUiHelpersConsumed) == 0
            and nativeInfo.contract ~= nil
            and tonumber(nativeInfo.contract.externalGlobalsConsumed) == 0
            and tonumber(nativeInfo.contract.legacyUiHelpersConsumed) == 0,
        "blocker", "external=" .. tostring(nativeInfo and nativeInfo.externalGlobalsConsumed or "?")
            .. "/legacyHelpers=" .. tostring(nativeInfo and nativeInfo.legacyUiHelpersConsumed or "?"))

    local escBridge = S.NativeEscBridge
    local escInfo = type(escBridge) == "table" and type(escBridge.Describe) == "function" and escBridge:Describe(91730) or nil
    AddCheck(report, "native_esc_bridge_contract", escInfo ~= nil
            and (tonumber(escInfo.version) or 0) >= 2
            and (tonumber(escInfo.idempotentRegistrationContractVersion) or 0) >= 1
            and type(escBridge.RegisterContent) == "function"
            and type(escBridge.RegisterButton) == "function"
            and type(escBridge.IsReady) == "function",
        "blocker", escInfo and ("v=" .. tostring(escInfo.version or 0)
            .. "/idempotent=" .. tostring(escInfo.idempotentRegistrationContractVersion or 0)
            .. "/content=" .. tostring(escInfo.contentRegistrations or 0)
            .. "/button=" .. tostring(escInfo.buttonRegistrations or 0)
            .. "/reuse=" .. tostring(escInfo.reuses or 0)
            .. "/partialRetry=" .. tostring(escInfo.partialRetries or 0)) or "missing")

    local runtime = S.Runtime
    local runtimeInfo = type(runtime) == "table" and type(runtime.Describe) == "function" and runtime:Describe() or nil
    AddCheck(report, "runtime_entry_lifecycle_contract", runtimeInfo ~= nil
            and (tonumber(runtimeInfo.version) or 0) >= 4
            and type(runtime.RegisterEscMenu) == "function"
            and type(runtime.ScheduleEscRegistrationRetry) == "function",
        "blocker", runtimeInfo and ("v=" .. tostring(runtimeInfo.version or 0)
            .. "/started=" .. tostring(runtimeInfo.started == true)
            .. "/escAttempts=" .. tostring(runtimeInfo.escRegistrationAttempts or 0)) or "missing")
    AddCheck(report, "native_esc_menu_runtime", S.Ready ~= true or (runtimeInfo ~= nil and runtimeInfo.escRegistered == true),
        "warning", runtimeInfo and ("ready=" .. tostring(S.Ready == true)
            .. "/registered=" .. tostring(runtimeInfo.escRegistered == true)
            .. "/attempts=" .. tostring(runtimeInfo.escRegistrationAttempts or 0)
            .. "/retry=" .. tostring(runtimeInfo.escRetryScheduled == true)
            .. "/last=" .. tostring(runtimeInfo.lastEscError or "none")) or "runtime missing")
    local startupFirst = runtimeInfo and type(runtimeInfo.startupWarnings) == "table" and runtimeInfo.startupWarnings[1] or nil
    local startupFirstText = startupFirst and (tostring(startupFirst.stage or "unknown") .. ":" .. tostring(startupFirst.detail or "degraded")) or "none"
    if #startupFirstText > 180 then startupFirstText = startupFirstText:sub(1, 180) .. "..." end
    -- 聊天会截断摘要后半段，因此把写保护 Store 的恢复探针放进第一个失败项。
    -- 只带字段名、候选数和 schema/framework/transport 元数据，不含玩家或业务内容。
    local startupProbeParts, startupTraceParts = {}, {}
    do
        local persistenceDescribe = S.Persistence ~= nil and type(S.Persistence.Describe) == "function" and S.Persistence:Describe() or nil
        for _, probeRow in ipairs(persistenceDescribe and persistenceDescribe.rows or {}) do
            if probeRow.writeFenced == true and probeRow.integrityRecoveryTrace ~= nil then
                local trace = tostring(probeRow.integrityRecoveryTrace):gsub("[\r\n]+", " ")
                if #trace > 150 then trace = trace:sub(1, 147) .. "..." end
                startupTraceParts[#startupTraceParts + 1] = tostring(probeRow.id or "?") .. ":" .. trace
                if #startupTraceParts >= 2 then break end
            end
        end
        for _, probeRow in ipairs(persistenceDescribe and persistenceDescribe.rows or {}) do
            if probeRow.writeFenced == true and probeRow.historicalRecoveryProbe ~= nil then
                startupProbeParts[#startupProbeParts + 1] = tostring(probeRow.id or "?") .. ":" .. tostring(probeRow.historicalRecoveryProbe):gsub("[\r\n]+", " ")
                if #startupProbeParts >= 2 then break end -- 给完整指纹留出聊天长度。
            end
        end
    end
    local startupTraceSuffix = #startupTraceParts > 0 and ("/itrace=" .. table.concat(startupTraceParts, " ;; ")) or ""
    local startupProbeSuffix = #startupProbeParts > 0 and ("/probe=" .. table.concat(startupProbeParts, " ;; ")) or "" -- 用 ;; 分隔多 Store，避免与既有 | 字段分隔符混淆。
    AddCheck(report, "runtime_startup_degradation", runtimeInfo == nil or runtimeInfo.startupDegraded ~= true,
        "warning", runtimeInfo and ("degraded=" .. tostring(runtimeInfo.startupDegraded == true)
            .. "/warnings=" .. tostring(runtimeInfo.startupWarningCount or 0)
            .. "/first=" .. startupFirstText .. startupTraceSuffix .. startupProbeSuffix) or ("runtime missing" .. startupTraceSuffix .. startupProbeSuffix))
    AddCheck(report, "bootstrap_recovery_entry", S.RecoveryEntryHealthy == true, "warning",
        "healthy=" .. tostring(S.RecoveryEntryHealthy == true) .. "/error=" .. tostring(S.RecoveryEntryError or "none"))
    AddCheck(report, "recovery_launcher_input_contract",
        (tonumber(S.RecoveryLauncherContractVersion) or 0) >= 2
            and (tonumber(S.RecoveryLauncherLogicalSize) or 0) >= 24
            and (tonumber(S.RecoveryLauncherLogicalSize) or 0) <= 36
            and (tonumber(S.RecoveryLauncherDragThreshold) or 0) >= 1,
        "blocker", "v=" .. tostring(S.RecoveryLauncherContractVersion or 0)
            .. "/size=" .. tostring(S.RecoveryLauncherLogicalSize or 0)
            .. "/drag=" .. tostring(S.RecoveryLauncherDragThreshold or 0))
    AddCheck(report, "bootstrap_recovery_command", S.RecoveryCommandHealthy == true, "warning",
        "healthy=" .. tostring(S.RecoveryCommandHealthy == true) .. "/error=" .. tostring(S.RecoveryCommandError or "none"))
    AddCheck(report, "recovery_command_contract",
        (tonumber(S.RecoveryCommandContractVersion) or 0) >= 2
            and (tonumber(S.RecoveryInputIsolationContractVersion) or 0) >= 1
            and type(S.ExecuteRecoveryCommand) == "function"
            and type(S.InstallRecoveryCommandBar) == "function"
            and type(S.SetRecoveryCommandBarVisible) == "function",
        "blocker", "v=" .. tostring(S.RecoveryCommandContractVersion or 0)
            .. "/inputIsolation=" .. tostring(S.RecoveryInputIsolationContractVersion or 0))
    local nativeImports = nativeInfo and nativeInfo.imports or nil
    AddCheck(report, "native_import_authority", nativeImports ~= nil
            and (tonumber(nativeImports.version) or 0) >= 3
            and (tonumber(nativeImports.optionalNegativeCacheContractVersion) or 0) >= 1
            and (tonumber(nativeImports.methodDependencyResolutionContractVersion) or 0) >= 1
            and tostring(nativeImports.source or "") == "replicated_native"
            and (tonumber(nativeImports.foundationFailures) or 0) == 0
            and (tonumber(nativeImports.requiredObjects) or 0) >= 7,
        "blocker", nativeImports and ("v=" .. tostring(nativeImports.version or 0)
            .. "/negCache=" .. tostring(nativeImports.optionalNegativeCacheContractVersion or 0)
            .. "/methodMap=" .. tostring(nativeImports.methodDependencyResolutionContractVersion or 0)
            .. "/cacheHit=" .. tostring(nativeImports.optionalFailureCacheHits or 0)
            .. "/api=" .. tostring(nativeImports.total or 0)
            .. "/core=" .. tostring(nativeImports.core or 0)
            .. "/feature=" .. tostring(nativeImports.feature or 0)
            .. "/objects=" .. tostring(nativeImports.objects or 0)
            .. "/required=" .. tostring(nativeImports.requiredObjects or 0)
            .. "/fail=" .. tostring(nativeImports.failures or 0)
            .. "/foundationFail=" .. tostring(nativeImports.foundationFailures or 0)
            .. "/featureFail=" .. tostring(nativeImports.featureFailures or 0)) or "missing")
    AddCheck(report, "feature_native_import_health", nativeImports ~= nil and (tonumber(nativeImports.featureFailures) or 0) == 0,
        "warning", nativeImports and ("featureFail=" .. tostring(nativeImports.featureFailures or 0)) or "missing")

    local identityInfo = type(S.DescribeNativeIdentity) == "function" and S.DescribeNativeIdentity() or nil
    local factoryInfo = S.NativeObjectFactory and type(S.NativeObjectFactory.Describe) == "function" and S.NativeObjectFactory:Describe() or nil
    AddCheck(report, "native_widget_identity", identityInfo ~= nil and (tonumber(identityInfo.version) or 0) >= 2
            and (tonumber(identityInfo.maxPhysicalLength) or 99) <= 23
            and (tonumber(identityInfo.maxObservedLength) or 0) <= (tonumber(identityInfo.maxPhysicalLength) or 23)
            and (tonumber(identityInfo.collisions) or 0) == 0
            and factoryInfo ~= nil and (tonumber(factoryInfo.version) or 0) >= 3
            and (tonumber(factoryInfo.objectImportFenceContractVersion) or 0) >= 1
            and (tonumber(factoryInfo.duplicateRejects) or 0) == 0
            and (tonumber(factoryInfo.invalidIdentityRejects) or 0) == 0
            and (tonumber(factoryInfo.staleParentRejects) or 0) == 0,
        "blocker", "identity=" .. tostring(identityInfo and identityInfo.version or "?")
            .. "/max=" .. tostring(identityInfo and identityInfo.maxObservedLength or "?") .. "/" .. tostring(identityInfo and identityInfo.maxPhysicalLength or "?")
            .. "/collision=" .. tostring(identityInfo and identityInfo.collisions or "?")
            .. "/factory=" .. tostring(factoryInfo and factoryInfo.version or "?")
            .. "/importFence=" .. tostring(factoryInfo and factoryInfo.objectImportFenceContractVersion or 0)
            .. "/dupReject=" .. tostring(factoryInfo and factoryInfo.duplicateRejects or "?")
            .. "/invalidReject=" .. tostring(factoryInfo and factoryInfo.invalidIdentityRejects or "?")
            .. "/staleParent=" .. tostring(factoryInfo and factoryInfo.staleParentRejects or "?"))

    local ui = S.UI
    local authority = ui and type(ui.GetAuthoritySnapshot) == "function" and ui:GetAuthoritySnapshot() or nil
    AddCheck(report, "v3_strict_authority", authority ~= nil and type(ui.AdoptV3Widget) == "function" and type(ui.ClaimNativeAuthority) == "function",
        "blocker", authority and ("claims=" .. tostring(authority.claims or 0) .. "/viol=" .. tostring(authority.violations or 0) .. "/conflict=" .. tostring(authority.conflicts or 0)) or "missing")
    if authority ~= nil then
        local byField = type(authority.byField) == "table" and authority.byField or {}
        AddCheck(report, "v3_authority_clean", (tonumber(authority.violations) or 0) == 0 and (tonumber(authority.conflicts) or 0) == 0,
            "blocker", "viol=" .. tostring(authority.violations or 0)
                .. "/conflict=" .. tostring(authority.conflicts or 0)
                .. "/field[t=" .. tostring(byField.text or 0)
                .. ",v=" .. tostring(byField.visible or 0)
                .. ",e=" .. tostring(byField.extent or 0)
                .. ",a=" .. tostring(byField.anchor or 0) .. "]")
    end
    local registrySnapshot = ui and type(ui.GetRegistrySnapshot) == "function" and ui:GetRegistrySnapshot() or nil
    AddCheck(report, "v3_component_ids", registrySnapshot ~= nil and (tonumber(registrySnapshot.v3Duplicates) or 0) == 0,
        "blocker", registrySnapshot and ("dup=" .. tostring(registrySnapshot.duplicates or 0) .. "/v3=" .. tostring(registrySnapshot.v3Duplicates or 0)
            .. "/degraded=" .. tostring(registrySnapshot.degraded or 0)) or "missing")
    local frameworkSnapshot = ui and type(ui.GetFrameworkSnapshot) == "function" and ui:GetFrameworkSnapshot() or nil
    local nativeSafety = frameworkSnapshot and frameworkSnapshot.nativeSafety or nil
    AddCheck(report, "v3_native_write_safety", frameworkSnapshot ~= nil and (tonumber(frameworkSnapshot.version) or 0) >= 7
            and nativeSafety ~= nil and (tonumber(nativeSafety.callFailures) or 0) == 0
            and (tonumber(nativeSafety.staleRejects) or 0) == 0
            and (tonumber(nativeSafety.registrationRejects) or 0) == 0,
        "blocker", nativeSafety and ("framework=" .. tostring(frameworkSnapshot.version)
            .. "/callFail=" .. tostring(nativeSafety.callFailures or 0)
            .. "/stale=" .. tostring(nativeSafety.staleRejects or 0)
            .. "/registration=" .. tostring(nativeSafety.registrationRejects or 0)
            .. "/parentRepair=" .. tostring(nativeSafety.anchorParentRepairs or 0)) or "missing")
    AddCheck(report, "v3_native_primitive_health", nativeSafety ~= nil and (tonumber(nativeSafety.degradedRejects) or 0) == 0
            and registrySnapshot ~= nil and (tonumber(registrySnapshot.degraded) or 0) == 0,
        "warning", nativeSafety and ("degradedRejects=" .. tostring(nativeSafety.degradedRejects or 0)
            .. "/degradedPrimitives=" .. tostring(registrySnapshot and registrySnapshot.degraded or 0)) or "missing")

    if v3HostRegistered then
        local shell = S.UIV3 and S.UIV3.Shell or nil
        local windowing = S.RSUI and S.RSUI.Windowing or nil
        local controller = shell and shell.windowController or nil
        local resizeHandles = 0
        for _ in pairs(controller and controller.handles or {}) do resizeHandles = resizeHandles + 1 end
        AddCheck(report, "v3_outer_window_foundation", type(windowing) == "table" and (tonumber(windowing.version) or 0) >= 13 and type(controller) == "table"
                and controller.dragHandle ~= nil and resizeHandles == 8
                and (tonumber(windowing.IdempotentStateContractVersion) or 0) >= 1
                and (tonumber(windowing.CallbackCaptureContractVersion) or 0) >= 1
                and (tonumber(windowing.StateMutationTransactionContractVersion) or 0) >= 1
                and (tonumber(windowing.GeometryCallbackTransactionContractVersion) or 0) >= 1
                and (tonumber(shell.StateMutationTransactionContractVersion) or 0) >= 1
                and type(controller.SetLocked) == "function" and type(controller.SetResizeEnabled) == "function" and type(controller.IsInteracting) == "function"
                and type(controller.PulseLiveGeometry) == "function" and type(windowing.Detach) == "function"
                -- Windowing 提交的矩形直接用于保存；提交后重读 Native 曾导致坐标漂移。
                and S.Layout ~= nil and type(S.Layout.ResolvePlacement) == "function" and type(S.Layout.StorePlacementRect) == "function"
                and tostring(S.Layout.defaultFloatingBoundary or "") == "free" and tostring(controller.boundaryMode or "") == "free"
                and type(ui.BeginNativeGeometryLease) == "function" and type(ui.EndNativeGeometryLease) == "function",
            "blocker", "version=" .. tostring(windowing and windowing.version or "?")
                .. "/drag=" .. tostring(controller ~= nil and controller.dragHandle ~= nil)
                .. "/resizeHandles=" .. tostring(resizeHandles)
                .. "/idem=" .. tostring(windowing and windowing.IdempotentStateContractVersion or 0)
                .. "/capture=" .. tostring(windowing and windowing.CallbackCaptureContractVersion or 0)
                .. "/stateTx=" .. tostring(windowing and windowing.StateMutationTransactionContractVersion or 0)
                .. "/geometryCbTx=" .. tostring(windowing and windowing.GeometryCallbackTransactionContractVersion or 0)
                .. "/shellStateTx=" .. tostring(shell and shell.StateMutationTransactionContractVersion or 0)
                .. "/lock=" .. tostring(controller ~= nil and type(controller.SetLocked) == "function"))

        local design = S.UIV3Design
        AddCheck(report, "v3_exact_numeric_settings", type(design) == "table" and type(design.NumericSetting) == "function",
            "blocker", "numeric values require direct NumericInput; preset cycling buttons are forbidden")

        AddCheck(report, "v3_ui_state_transaction_contract", type(S.UI) == "table"
                and type(S.UI.EnsureVisible) == "function" and type(S.UI.EnsureEnabled) == "function"
                and type(S.UI.EnsurePickable) == "function" and type(S.UI.EnsureAlpha) == "function"
                and type(S.UI.EnsureAnchor) == "function" and type(S.UI.EnsureExtent) == "function"
                and (tonumber(S.UI.NativeBooleanSetterReturnContractVersion) or 0) >= 1
                and (tonumber(S.UI.GeometryStateTransactionContractVersion) or 0) >= 1
                and type(S.RSUI) == "table"
                and (tonumber(S.RSUI.VisibilityStateTransactionContractVersion) or 0) >= 1
                and (tonumber(S.RSUI.PopupVisibilityTransactionContractVersion) or 0) >= 1
                and (tonumber(S.RSUI.InteractionPopupVisibilityContractVersion) or 0) >= 1
                and (tonumber(S.RSUI.PopupNativeWindowContractVersion) or 0) >= 1
                and (tonumber(S.UI.TopLevelTransientWindowContractVersion) or 0) >= 1,
            "blocker", "visibility=" .. tostring(S.RSUI and S.RSUI.VisibilityStateTransactionContractVersion or 0)
                .. "/popup=" .. tostring(S.RSUI and S.RSUI.PopupVisibilityTransactionContractVersion or 0)
                .. "/interactionPopup=" .. tostring(S.RSUI and S.RSUI.InteractionPopupVisibilityContractVersion or 0)
                .. "/popupNativeWindow=" .. tostring(S.RSUI and S.RSUI.PopupNativeWindowContractVersion or 0)
                .. "/topTransient=" .. tostring(S.UI and S.UI.TopLevelTransientWindowContractVersion or 0)
                .. "/nativeBoolSetter=" .. tostring(S.UI and S.UI.NativeBooleanSetterReturnContractVersion or 0)
                .. "/alpha=" .. tostring(type(S.UI and S.UI.EnsureAlpha) == "function")
                .. "/geometryTx=" .. tostring(S.UI and S.UI.GeometryStateTransactionContractVersion or 0))

        local popupPositioning = S.RSUI and S.RSUI.PopupPositioning or nil
        AddCheck(report, "v3_popup_coordinate_contract", type(S.Layout) == "table"
                and (tonumber(S.Layout.ViewportLogicalRectContractVersion) or 0) >= 1 -- 外部控件需校准 Effective Geometry；Suite 控件使用完整父链缓存，最终统一为 viewport-logical-v1。
                -- Dropdown/Tooltip/ContextMenu 走 Native-relative；ColorField 顶层窗口走 viewport-resolved，不能跨层锚到 Button。
                -- 屏幕边缘修正统一经 UIBounds:CorrectOffsetByScreen；专项复制报告也是发布所需接口。
                and (tonumber(S.Layout.EffectiveGeometryCalibrationContractVersion) or 0) >= 1
                and (tonumber(S.Layout.SuiteOwnedViewportAnchorContractVersion) or 0) >= 1
                and type(S.Layout.ResolveViewportLogicalRect) == "function"
                and type(S.Layout.ResolveSuiteOwnedViewportLogicalRect) == "function"
                and type(popupPositioning) == "table"
                and (tonumber(S.RSUI.PopupPositioningContractVersion) or 0) >= 4
                and (tonumber(S.RSUI.PopupNativeRelativeAnchorContractVersion) or 0) >= 1
                and (tonumber(S.RSUI.PopupViewportResolvedAnchorContractVersion) or 0) >= 1
                and (tonumber(S.RSUI.ColorFieldContractVersion) or 0) >= 2
                and (tonumber(S.RSUI.PopupSuiteAnchorAuthorityContractVersion) or 0) >= 1
                and (tonumber(S.RSUI.PopupCoordinateSpaceContractVersion) or 0) >= 1
                and (tonumber(S.RSUI.PopupCoordinateConsumerContractVersion) or 0) >= 3
                and (tonumber(S.RSUI.InteractionPopupCoordinateConsumerContractVersion) or 0) >= 2
                and type(popupPositioning.ApplyNativeRelativePopup) == "function"
                and type(popupPositioning.ApplyResolvedViewportPopup) == "function"
                and type(popupPositioning.CorrectNativePopupToScreen) == "function"
                and type(S.DiagnosticsManager) == "table" and type(S.DiagnosticsManager.BuildPopupPositioningReport) == "function"
                and type(popupPositioning.ResolveAnchorRect) == "function"
                and type(popupPositioning.ResolveAnchored) == "function"
                and type(popupPositioning.ResolveDropdown) == "function"
                and type(popupPositioning.ResolvePoint) == "function",
            "blocker", "layoutRect=" .. tostring(S.Layout and S.Layout.ViewportLogicalRectContractVersion or 0)
                .. "/calibration=" .. tostring(S.Layout and S.Layout.EffectiveGeometryCalibrationContractVersion or 0)
                .. "/suiteAnchor=" .. tostring(S.Layout and S.Layout.SuiteOwnedViewportAnchorContractVersion or 0)
                .. "/positioning=" .. tostring(S.RSUI and S.RSUI.PopupPositioningContractVersion or 0)
                .. "/nativeRelative=" .. tostring(S.RSUI and S.RSUI.PopupNativeRelativeAnchorContractVersion or 0)
                .. "/viewportResolved=" .. tostring(S.RSUI and S.RSUI.PopupViewportResolvedAnchorContractVersion or 0)
                .. "/colorField=" .. tostring(S.RSUI and S.RSUI.ColorFieldContractVersion or 0)
                .. "/suitePopup=" .. tostring(S.RSUI and S.RSUI.PopupSuiteAnchorAuthorityContractVersion or 0)
                .. "/space=" .. tostring(S.RSUI and S.RSUI.PopupCoordinateSpaceContractVersion or 0)
                .. "/controls=" .. tostring(S.RSUI and S.RSUI.PopupCoordinateConsumerContractVersion or 0)
                .. "/interactions=" .. tostring(S.RSUI and S.RSUI.InteractionPopupCoordinateConsumerContractVersion or 0))

        local genericShell = S.UI and S.UI.WindowShell or nil
        local genericShellInfo = genericShell and type(genericShell.Describe) == "function" and genericShell:Describe() or nil
        AddCheck(report, "v3_generic_window_shell", genericShellInfo ~= nil and (tonumber(genericShellInfo.version) or 0) >= 17
                and (tonumber(genericShellInfo.idempotentMutationContract) or 0) >= 1
                and (tonumber(genericShellInfo.compactMinimizeContract) or 0) >= 1
                and (tonumber(genericShellInfo.titleAppearanceContract) or 0) >= 3
                and (tonumber(genericShellInfo.visibilityTransactionContract) or 0) >= 1
                and (tonumber(genericShellInfo.stateMutationTransactionContract) or 0) >= 1
                and (tonumber(genericShellInfo.stateCallbackTransactionContract) or 0) >= 1
                and (tonumber(genericShellInfo.topLevelLayerContractVersion) or 0) >= 2
                and (tonumber(genericShellInfo.topmostPreferenceContractVersion) or 0) >= 1
                and type(S.RSUI.WindowPreferences) == "table"
                and (tonumber(S.RSUI.WindowPreferencePersistenceContractVersion) or 0) >= 1
                and (tonumber(S.RSUI.WindowLayerPreferenceContractVersion) or 0) >= 1
                and type(S.RSUI.WindowPreferences.GetTopmost) == "function" and type(S.RSUI.WindowPreferences.SetTopmost) == "function"
                and type(S.UI.CreateWindowShell) == "function",
            "blocker", genericShellInfo and ("version=" .. tostring(genericShellInfo.version)
                .. "/idem=" .. tostring(genericShellInfo.idempotentMutationContract or 0)
                .. "/compact=" .. tostring(genericShellInfo.compactMinimizeContract or 0)
                .. "/appearance=" .. tostring(genericShellInfo.titleAppearanceContract or 0)
                .. "/visibilityTx=" .. tostring(genericShellInfo.visibilityTransactionContract or 0)
                .. "/stateTx=" .. tostring(genericShellInfo.stateMutationTransactionContract or 0)
                .. "/stateCbTx=" .. tostring(genericShellInfo.stateCallbackTransactionContract or 0)
                .. "/topLayer=" .. tostring(genericShellInfo.topLevelLayerContractVersion or 0)
                .. "/topPref=" .. tostring(genericShellInfo.topmostPreferenceContractVersion or 0)
                .. "/windowPref=" .. tostring(S.RSUI and S.RSUI.WindowPreferencePersistenceContractVersion or 0)
                .. "/fail=" .. tostring(genericShellInfo.failures or 0)) or "missing")

        local floatingSurface = S.RSUI and S.RSUI.FloatingSurface or nil
        local floatingInfo = floatingSurface and type(floatingSurface.GetSnapshot) == "function" and floatingSurface:GetSnapshot() or nil
        AddCheck(report, "v3_floating_surface_contract", floatingInfo ~= nil and (tonumber(floatingInfo.version) or 0) >= 9
                and tonumber(floatingSurface.generation) == tonumber(S.Generation)
                and (tonumber(floatingSurface.IdempotentMutationContractVersion) or 0) >= 1
                and (tonumber(floatingSurface.CompactMinimizeContractVersion) or 0) >= 1
                and (tonumber(floatingSurface.TitleAppearanceContractVersion) or 0) >= 1
                and (tonumber(floatingSurface.DetachedStateContractVersion) or 0) >= 1
                and (tonumber(floatingSurface.StateMutationTransactionContractVersion) or 0) >= 1
                and (tonumber(floatingSurface.ResponsivePlacementIntentContractVersion) or 0) >= 1
                and (tonumber(floatingSurface.CommittedGeometryPersistenceContractVersion) or 0) >= 1
                and type(floatingSurface.Create) == "function" and type(floatingSurface.NormalizeState) == "function"
                and type(floatingSurface.CreateStateAdapter) == "function",
            "blocker", floatingInfo and ("version=" .. tostring(floatingInfo.version) .. "/active=" .. tostring(floatingInfo.active or 0)
                .. "/idem=" .. tostring(floatingSurface and floatingSurface.IdempotentMutationContractVersion or 0)
                .. "/compact=" .. tostring(floatingSurface and floatingSurface.CompactMinimizeContractVersion or 0)
                .. "/appearance=" .. tostring(floatingSurface and floatingSurface.TitleAppearanceContractVersion or 0)
                .. "/detached=" .. tostring(floatingSurface and floatingSurface.DetachedStateContractVersion or 0)
                .. "/stateTx=" .. tostring(floatingSurface and floatingSurface.StateMutationTransactionContractVersion or 0)
                .. "/responsivePlacement=" .. tostring(floatingSurface and floatingSurface.ResponsivePlacementIntentContractVersion or 0)
                .. "/committedGeometry=" .. tostring(floatingSurface and floatingSurface.CommittedGeometryPersistenceContractVersion or 0)
                .. "/close=" .. tostring(floatingInfo.closeRequests or 0)
                .. "/veto=" .. tostring(floatingInfo.closeVetoes or 0)
                .. "/fail=" .. tostring(floatingInfo.failures or 0)) or "missing")

        local auxWindowStore = S.UIV3 and S.UIV3.AuxWindowStoreV3 or nil
        local auxStoreRegistration = S.Persistence and type(S.Persistence.GetStore) == "function"
            and S.Persistence:GetStore("v3.presentation.aux_windows") or nil
        local auxTradePolicy = type(auxWindowStore) == "table" and type(auxWindowStore.GetPolicy) == "function" and auxWindowStore:GetPolicy("trade_detail") or nil
        local auxDiagPolicy = type(auxWindowStore) == "table" and type(auxWindowStore.GetPolicy) == "function" and auxWindowStore:GetPolicy("trade_diagnostics") or nil
        local auxQuestPolicy = type(auxWindowStore) == "table" and type(auxWindowStore.GetPolicy) == "function" and auxWindowStore:GetPolicy("quest_detail") or nil
        AddCheck(report, "v3_aux_window_persistence_contract", type(auxWindowStore) == "table"
                and (tonumber(auxWindowStore.contractVersion) or 0) >= 2
                and (tonumber(auxWindowStore.HistoricalPolicyRecoveryContractVersion) or 0) >= 1
                and type(auxStoreRegistration) == "table" and auxStoreRegistration.owner == "v3.presentation.aux_windows"
                and tonumber(auxStoreRegistration.schemaVersion) == 2
                and auxStoreRegistration.allowIntegrityUpgrade == true
                and type(auxStoreRegistration.rebuildCanonicalForIntegrity) == "function"
                and type(auxWindowStore.EnsureLoaded) == "function" and type(auxWindowStore.GetWindowState) == "function"
                and type(auxWindowStore.SetWindowState) == "function" and type(auxWindowStore.PersistWindow) == "function"
                and type(auxTradePolicy) == "table" and tonumber(auxTradePolicy.defaultWidth) == 620
                and type(auxDiagPolicy) == "table" and tonumber(auxDiagPolicy.defaultWidth) == 700
                and type(auxQuestPolicy) == "table" and tonumber(auxQuestPolicy.defaultWidth) == 560,
            "blocker", type(auxWindowStore) == "table" and ("contract=" .. tostring(auxWindowStore.contractVersion or 0)
                .. "/hist=" .. tostring(auxWindowStore.HistoricalPolicyRecoveryContractVersion or 0)
                .. "/schema=" .. tostring(auxStoreRegistration and auxStoreRegistration.schemaVersion or 0)
                .. "/registered=" .. tostring(type(auxStoreRegistration) == "table")
                .. "/loaded=" .. tostring(auxWindowStore.loaded == true)) or "missing")

        local viewState = S.RSUI and S.RSUI.ViewState or nil
        local viewStateInfo = viewState and type(viewState.GetSnapshot) == "function" and viewState:GetSnapshot() or nil
        AddCheck(report, "v3_view_state_contract", viewStateInfo ~= nil and (tonumber(viewStateInfo.version) or 0) >= 2
                and tonumber(viewStateInfo.generation) == tonumber(S.Generation) and type(S.RSUI.CreateViewState) == "function",
            "blocker", viewStateInfo and ("version=" .. tostring(viewStateInfo.version) .. "/active=" .. tostring(viewStateInfo.active or 0)
                .. "/ready=" .. tostring(viewStateInfo.states and viewStateInfo.states.ready or 0)
                .. "/empty=" .. tostring(viewStateInfo.states and viewStateInfo.states.empty or 0)
                .. "/error=" .. tostring(viewStateInfo.states and viewStateInfo.states.error or 0)) or "missing")

        local actionRunner = S.ActionRunner
        local actionInfo = actionRunner and type(actionRunner.GetSnapshot) == "function" and actionRunner:GetSnapshot() or nil
        AddCheck(report, "v3_action_runner_contract", actionInfo ~= nil and (tonumber(actionInfo.version) or 0) >= 1
                and type(actionRunner.Run) == "function" and type(actionRunner.IsBusy) == "function",
            "blocker", actionInfo and ("version=" .. tostring(actionInfo.version) .. "/runs=" .. tostring(actionInfo.runs or 0)
                .. "/failed=" .. tostring(actionInfo.failed or 0) .. "/duplicate=" .. tostring(actionInfo.duplicates or 0)) or "missing")

        local binding = S.UI and S.UI.Binding or nil
        local bindingInfo = binding and type(binding.GetSnapshot) == "function" and binding:GetSnapshot() or nil
        AddCheck(report, "v3_persistent_setting_binding", bindingInfo ~= nil and (tonumber(bindingInfo.version) or 0) >= 2.4
                and type(S.UI.CreatePersistentSettingBinding) == "function",
            "blocker", bindingInfo and ("version=" .. tostring(bindingInfo.version) .. "/active=" .. tostring(bindingInfo.active or 0)
                .. "/persistent=" .. tostring(bindingInfo.persistentActive or 0) .. "/dirty=" .. tostring(bindingInfo.dirty or 0)
                .. "/error=" .. tostring(bindingInfo.errored or 0) .. "/markFail=" .. tostring(bindingInfo.persistenceFailures or 0)) or "missing")

        AddCheck(report, "legacy_window_runtime_detached", S.State == nil and S.Storage == nil
                and S.UI ~= nil and S.UI.CreateManagedWindow == nil and S.UI.AttachManagedWindow == nil and S.UI.WindowManager == nil,
            "blocker", "state=" .. tostring(S.State ~= nil) .. "/storage=" .. tostring(S.Storage ~= nil)
                .. "/managed=" .. tostring(S.UI and S.UI.CreateManagedWindow ~= nil) .. "/manager=" .. tostring(S.UI and S.UI.WindowManager ~= nil))

        local widgetHost = S.UIV3 and S.UIV3.WidgetHost or nil
        local widgetInfo = widgetHost and type(widgetHost.Describe) == "function" and widgetHost:Describe() or nil
        AddCheck(report, "v3_widget_management_contract", widgetInfo ~= nil and (tonumber(widgetInfo.version) or 0) >= 13
                and (tonumber(widgetInfo.buildTransactionContractVersion) or 0) >= 1
                and type(widgetHost.NotifyWindowClosed) == "function" and type(widgetHost.SetLocked) == "function" and type(widgetHost.SetMinimized) == "function"
                and type(widgetHost.ResetLayout) == "function" and type(widgetHost.ApplyResponsiveLayout) == "function"
                and type(widgetHost.ResetAllLayouts) == "function"
                -- 功能生命周期桥：Domain 发布，Presentation 响应。
                and type(widgetHost.BindFeatureLifecycle) == "function"
                and type(widgetHost.RequestClose) == "function"
                and type(widgetHost.NotifyProjectionChanged) == "function"
                and ((tonumber(widgetInfo.featureBindings) or 0) == 0 or widgetInfo.lifecycleBound == true)
                and (tonumber(widgetInfo.stats and widgetInfo.stats.lifecycleBindFailures) or 0) == 0,
            "blocker", widgetInfo and ("version=" .. tostring(widgetInfo.version) .. "/registered=" .. tostring(widgetInfo.registered or 0)
                .. "/bindings=" .. tostring(widgetInfo.featureBindings or 0)
                .. "/reactions=" .. tostring(widgetInfo.stats and widgetInfo.stats.lifecycleReactions or 0)
                .. "/bound=" .. tostring(widgetInfo.lifecycleBound == true)
                .. "/bindFail=" .. tostring(widgetInfo.stats and widgetInfo.stats.lifecycleBindFailures or 0)
                .. "/reactionFail=" .. tostring(widgetInfo.stats and widgetInfo.stats.lifecycleReactionFailures or 0)
                .. "/lockable=" .. tostring(widgetInfo.lockable or 0) .. "/resettable=" .. tostring(widgetInfo.resettable or 0)) or "missing")

        local modalHost = S.UIV3 and S.UIV3.ModalHost or nil
        local modalInfo = modalHost and type(modalHost.Describe) == "function" and modalHost:Describe() or nil
        AddCheck(report, "v3_modal_host_contract", modalInfo ~= nil and (tonumber(modalInfo.version) or 0) >= 6
                and (tonumber(modalInfo.buildTransactionContractVersion) or 0) >= 1
                and (tonumber(modalInfo.visibilityTransactionContractVersion) or 0) >= 1
                and modalInfo.attached == true and type(modalHost.GetContentRoot) == "function"
                and type(modalHost.DismissTop) == "function" and type(modalHost.EnsureApplicationVisible) == "function",
            "blocker", modalInfo and ("version=" .. tostring(modalInfo.version) .. "/attached=" .. tostring(modalInfo.attached)
                .. "/visibilityTx=" .. tostring(modalInfo.visibilityTransactionContractVersion or 0)
                .. "/count=" .. tostring(modalInfo.count or 0) .. "/wakeFail=" .. tostring(modalInfo.hostWakeFailures or 0)) or "missing")

        local toastHost = S.UIV3 and S.UIV3.ToastHost or nil
        local toastInfo = toastHost and type(toastHost.Describe) == "function" and toastHost:Describe() or nil
        AddCheck(report, "v3_toast_host_contract", toastInfo ~= nil and (tonumber(toastInfo.version) or 0) >= 1
                and toastInfo.attached == true and tonumber(toastInfo.maxVisible) == 3
                and type(toastHost.Notify) == "function" and type(toastHost.Dismiss) == "function",
            "blocker", toastInfo and ("version=" .. tostring(toastInfo.version) .. "/attached=" .. tostring(toastInfo.attached)
                .. "/visible=" .. tostring(toastInfo.visible or 0) .. "/pending=" .. tostring(toastInfo.active or 0)) or "missing")

        local scheduler = S.Scheduler
        local schedulerHealth = scheduler and type(scheduler.GetHealth) == "function" and scheduler:GetHealth() or nil
        AddCheck(report, "v3_bounded_delayed_work", type(scheduler) == "table" and type(scheduler.AddOneShot) == "function",
            "blocker", "shared one-shot scheduler required")
        AddCheck(report, "v3_interactive_scheduler_contract", type(scheduler) == "table" and (tonumber(scheduler.version) or 0) >= 3
                and type(scheduler.AddInteractiveTask) == "function" and type(scheduler.RemoveTask) == "function"
                and type(scheduler.SetTaskModule) == "function" and schedulerHealth ~= nil,
            "blocker", schedulerHealth and ("version=" .. tostring(schedulerHealth.version or 0)
                .. "/tasks=" .. tostring(schedulerHealth.activeTasks or 0)
                .. "/modules=" .. tostring(schedulerHealth.moduleMappings or 0)
                .. "/transient=" .. tostring(schedulerHealth.transientMappings or 0))
                or "background >=50ms; finite interactive gestures may borrow >=16ms")
        AddCheck(report, "v3_scheduler_metadata_health", schedulerHealth ~= nil
                and (tonumber(schedulerHealth.transientOrphans) or 0) == 0,
            "warning", schedulerHealth and ("transient=" .. tostring(schedulerHealth.transientMappings or 0)
                .. "/orphan=" .. tostring(schedulerHealth.transientOrphans or 0)) or "missing")

        local eventBus = S.Events
        local eventHealth = eventBus and type(eventBus.GetHealth) == "function" and eventBus:GetHealth() or nil
        AddCheck(report, "v3_event_bus_contract", type(eventBus) == "table" and (tonumber(eventBus.version) or 0) >= 4
                and type(eventBus.Subscribe) == "function" and type(eventBus.SubscribeOptional) == "function" and type(eventBus.SubscribeInternal) == "function"
                and type(eventBus.GetHealth) == "function" and eventHealth ~= nil,
            "blocker", eventHealth and ("version=" .. tostring(eventHealth.version or 0)
                .. "/native=" .. tostring(eventHealth.nativeListeners or 0)
                .. "/registered=" .. tostring(eventHealth.registered or 0)
                .. "/parked=" .. tostring(eventHealth.parkedRegistrations or 0)
                .. "/internal=" .. tostring(eventHealth.internalListeners or 0)) or "missing")
        AddCheck(report, "v3_event_bus_runtime_health", eventHealth ~= nil
                and (tonumber(eventHealth.startFailures) or 0) == 0
                and (tonumber(eventHealth.subscribeFailures) or 0) == 0
                and (tonumber(eventHealth.registerFailures) or 0) == 0
                and (tonumber(eventHealth.unregisterFailures) or 0) == 0,
            "warning", eventHealth and ("startFail=" .. tostring(eventHealth.startFailures or 0)
                .. "/subFail=" .. tostring(eventHealth.subscribeFailures or 0)
                .. "/registerFail=" .. tostring(eventHealth.registerFailures or 0)
                .. "/unregisterFail=" .. tostring(eventHealth.unregisterFailures or 0)
                .. "/parked=" .. tostring(eventHealth.parkedRegistrations or 0)
                .. "/nativeUnreg=" .. tostring(eventHealth.nativeUnregisterSupported)) or "missing")
        AddCheck(report, "v3_event_release_contract", eventHealth ~= nil
                and (tonumber(eventHealth.version) or 0) >= 4
                and eventHealth.parkedRegistrations ~= nil and eventHealth.unregisterSkipped ~= nil
                and (tonumber(eventHealth.ownerReleaseContractVersion) or 0) >= 1
                and (tonumber(eventHealth.unregisterFailures) or 0) == 0,
            "blocker", eventHealth and ("parked=" .. tostring(eventHealth.parkedRegistrations or 0)
                .. "/skipped=" .. tostring(eventHealth.unregisterSkipped or 0)
                .. "/nativeUnreg=" .. tostring(eventHealth.nativeUnregisterSupported)
                .. "/ownerRelease=" .. tostring(eventHealth.ownerReleaseContractVersion or 0)
                .. "/realFail=" .. tostring(eventHealth.unregisterFailures or 0)) or "missing")

        local rsui = S.RSUI
        local uiTokens = S.UITokens
        local scrollbar = rsui and rsui.ScrollbarBehavior or nil
        local workspaceTemplates = rsui and rsui.WorkspaceTemplates or nil
        local compositeFoundation = rsui and rsui.CompositeFoundation or nil
        AddCheck(report, "v3_advanced_ui_contract", type(rsui) == "table" and (tonumber(rsui.version) or 0) >= 30
                and type(rsui.SplitView) == "function" and type(rsui.types) == "table" and rsui.types["SplitView"] ~= nil
                and type(rsui.SplitViewPolicy) == "table" and type(rsui.SplitViewPolicy.Resolve) == "function"
                and type(scrollbar) == "table" and (tonumber(scrollbar.version) or 0) >= 2 and type(scrollbar.ComputeGeometry) == "function"
                and type(workspaceTemplates) == "table" and (tonumber(workspaceTemplates.contractVersion) or 0) >= 2
                and type(rsui.CreateMasterDetailWorkspace) == "function"
                and type(rsui.CreateInspectorWorkbench) == "function"
                and type(rsui.CreateResponsiveInspectorWorkspace) == "function"
                and type(rsui.CreateSettingsWorkbench) == "function"
                and (tonumber(rsui.ResponsiveInspectorContractVersion) or 0) >= 1
                and type(rsui.ResponsiveInspector) == "function"
                and (tonumber(rsui.AttachmentContractVersion) or 0) >= 1
                and (tonumber(rsui.ReparentPolicyContractVersion) or 0) >= 1
                and rsui.NativeReparentSupported == false
                and type(rsui.CreateCommandCenterWorkspace) == "function"
                and type(uiTokens) == "table" and (tonumber(uiTokens.version) or 0) >= 8
                and type(uiTokens.layer) == "table"
                and (tonumber(uiTokens.layer.shellPriority) or 0) > 0
                and (tonumber(uiTokens.layer.floatingPriority) or 0) > (tonumber(uiTokens.layer.shellPriority) or 0)
                and (tonumber(uiTokens.layer.popupPriority) or 0) > (tonumber(uiTokens.layer.floatingPriority) or 0)
                and (tonumber(uiTokens.layer.modalPriority) or 0) >= (tonumber(uiTokens.layer.popupPriority) or 0),
            "blocker", "RSUI v30 + SplitView + stable-host ResponsiveInspector + Attachment/Reparent fence + WorkspaceTemplates v2 + UITokens v8 settings/layer hierarchy required")
        local settingsFoundation = rsui and rsui.SettingsFoundation or nil
        local settingsDesign = S.UIV3Design
        AddCheck(report, "v3_settings_page_foundation_contract", type(settingsFoundation) == "table"
                and (tonumber(settingsFoundation.contractVersion) or 0) >= 3
                and (tonumber(rsui.SettingsFoundationContractVersion) or 0) >= 3
                and (tonumber(rsui.SettingsResponsiveContractVersion) or 0) >= 2
                and (tonumber(rsui.SettingsDiagnosticsDisclosureContractVersion) or 0) >= 1
                and (tonumber(rsui.SettingsStyleCardContractVersion) or 0) >= 3
                and (tonumber(rsui.SettingsCompactToggleContractVersion) or 0) >= 1
                and (tonumber(rsui.SettingsScrollSafeCardContractVersion) or 0) >= 2
                and (tonumber(rsui.SettingsSectionHierarchyContractVersion) or 0) >= 1
                -- min/max 是显示软范围，合法精确输入可经 NumericRangeStore 扩展。
                -- v1/v2 混装会使页面范围与 Domain 夹紧不一致，须阻止启动。
                and (tonumber(rsui.SettingsNumericSliderContractVersion) or 0) >= 2
                and (tonumber(rsui.FormRowResponsiveContractVersion) or 0) >= 1
                and (tonumber(rsui.NumericResponsiveStackContractVersion) or 0) >= 1
                and type(rsui.CreateFeatureSettingsHeader) == "function"
                and type(rsui.CreateSettingsToggleGrid) == "function"
                and type(rsui.CreateSettingsStyleCardGrid) == "function"
                and type(rsui.CreateSettingsStyleCard) == "function"
                and type(rsui.CreateSettingsDiagnosticsDisclosure) == "function"
                and type(rsui.CreateResponsiveSettingRow) == "function"
                and type(rsui.CreateResponsiveNumericSetting) == "function"
                and type(rsui.CreateSettingsNumericSlider) == "function"
                and type(settingsDesign) == "table" and (tonumber(settingsDesign.version) or 0) >= 10
                and type(settingsDesign.FeatureSettingsHeader) == "function"
                and type(settingsDesign.SettingsToggleGrid) == "function"
                and type(settingsDesign.SettingsStyleCard) == "function"
                and type(settingsDesign.SettingsDiagnostics) == "function"
                and type(settingsDesign.ResponsiveNumericSetting) == "function"
                and type(settingsDesign.SettingsNumericSlider) == "function"
                and type(uiTokens) == "table" and type(uiTokens.settings) == "table",
            "blocker", "settings=" .. tostring(settingsFoundation and settingsFoundation.contractVersion or 0)
                .. "/responsive=" .. tostring(rsui and rsui.SettingsResponsiveContractVersion or 0)
                .. "/formRow=" .. tostring(rsui and rsui.FormRowResponsiveContractVersion or 0)
                .. "/numericStack=" .. tostring(rsui and rsui.NumericResponsiveStackContractVersion or 0)
                .. "/design=" .. tostring(settingsDesign and settingsDesign.version or 0)
                .. "/tokens=" .. tostring(uiTokens and uiTokens.version or 0))
        local settingsBusinessContract = S.UIV3 and S.UIV3.BusinessPagesContract or nil
        AddCheck(report, "v3_unit_line_settings_page_contract", type(settingsBusinessContract) == "table"
                and (tonumber(settingsBusinessContract.version) or 0) >= 6
                and (tonumber(settingsBusinessContract.unitLineSettingsFoundationConsumerContractVersion) or 0) >= 3,
            "blocker", "businessPages=" .. tostring(settingsBusinessContract and settingsBusinessContract.version or 0)
                .. "/unitLinesSettings=" .. tostring(settingsBusinessContract and settingsBusinessContract.unitLineSettingsFoundationConsumerContractVersion or 0))


        AddCheck(report, "v3_ui_geometry_pointer_contract", type(rsui) == "table"
                and type(S.Layout) == "table"
                and (tonumber(S.Layout.CoordinateSystemContractVersion) or 0) >= 1
                and (tonumber(S.Layout.RectTransformTransactionContractVersion) or 0) >= 2
                and (tonumber(S.Layout.ScreenToWidgetLocalContractVersion) or 0) >= 1
                and (tonumber(S.Layout.ResponsivePlacementIntentContractVersion) or 0) >= 1
                and (tonumber(S.Layout.ViewportLogicalRectContractVersion) or 0) >= 1
                and (tonumber(S.Layout.EffectiveGeometryCalibrationContractVersion) or 0) >= 1
                and type(S.Layout.GetCoordinateSystemSnapshot) == "function"
                and type(S.Layout.ResolveViewportLogicalRect) == "function"
                and type(S.Layout.GetUiParentLocalOrigin) == "function"
                and type(S.Layout.ScreenPointToWidgetLocal) == "function"
                and type(S.Layout.OffsetPoint) == "function"
                and type(S.Layout.CreateRectTransformTransaction) == "function"
                and (tonumber(rsui.PointerContractVersion) or 0) >= 1
                and type(rsui.Pointer) == "table"
                and type(rsui.Pointer.GetLogicalPosition) == "function"
                and type(rsui.Pointer.Delta) == "function"
                and rsui.Pointer.captureSupported == false,
            "blocker", "coordinate=" .. tostring(S.Layout and S.Layout.CoordinateSystemContractVersion or 0)
                .. "/rectTx=" .. tostring(S.Layout and S.Layout.RectTransformTransactionContractVersion or 0)
                .. "/screenLocal=" .. tostring(S.Layout and S.Layout.ScreenToWidgetLocalContractVersion or 0)
                .. "/responsivePlacement=" .. tostring(S.Layout and S.Layout.ResponsivePlacementIntentContractVersion or 0)
                .. "/viewportRect=" .. tostring(S.Layout and S.Layout.ViewportLogicalRectContractVersion or 0)
                .. "/effectiveCalibration=" .. tostring(S.Layout and S.Layout.EffectiveGeometryCalibrationContractVersion or 0)
                .. "/pointer=" .. tostring(rsui and rsui.PointerContractVersion or 0)
                .. "/capture=" .. tostring(rsui and rsui.Pointer and rsui.Pointer.captureSupported))

        AddCheck(report, "v3_ui_selection_geometry_contract", type(rsui) == "table" and (tonumber(rsui.version) or 0) >= 31
                and (tonumber(rsui.SelectionGeometryContractVersion) or 0) >= 1
                and type(rsui.SelectionGeometry) == "table"
                and type(rsui.SelectionGeometry.GetHandleRects) == "function"
                and type(rsui.SelectionGeometry.HitTestHandle) == "function"
                and type(rsui.CreateSelectionGeometryModel) == "function"
                and type(rsui.SelectionGeometryModel) == "table"
                and (tonumber(rsui.LayoutGuideResolverContractVersion) or 0) >= 1
                and type(rsui.LayoutGuideResolver) == "table"
                and type(rsui.LayoutGuideResolver.Resolve) == "function"
                and (tonumber(rsui.SelectionOverlayContractVersion) or 0) >= 1
                and type(rsui.SelectionOverlay) == "function"
                and (tonumber(rsui.LayoutGuideOverlayContractVersion) or 0) >= 1
                and type(rsui.LayoutGuideOverlay) == "function",
            "blocker", "selectionGeometry=" .. tostring(rsui and rsui.SelectionGeometryContractVersion or 0)
                .. "/guideResolver=" .. tostring(rsui and rsui.LayoutGuideResolverContractVersion or 0)
                .. "/selectionOverlay=" .. tostring(rsui and rsui.SelectionOverlayContractVersion or 0)
                .. "/guideOverlay=" .. tostring(rsui and rsui.LayoutGuideOverlayContractVersion or 0)
                .. "/rsui=" .. tostring(rsui and rsui.version or 0))

        AddCheck(report, "v3_ui_layout_editor_gesture_contract", type(rsui) == "table" and (tonumber(rsui.version) or 0) >= 36
                and (tonumber(rsui.LayoutEditorGestureContractVersion) or 0) >= 2
                and type(rsui.CreateLayoutEditorGestureController) == "function"
                and type(rsui.LayoutEditorGestureController) == "table"
                and type(rsui.SelectionOverlay) == "function"
                and type(rsui.LayoutGuideOverlay) == "function"
                and type(S.Layout) == "table"
                and (tonumber(S.Layout.RectTransformTransactionContractVersion) or 0) >= 2,
            "blocker", "gesture=" .. tostring(rsui and rsui.LayoutEditorGestureContractVersion or 0)
                .. "/rectTx=" .. tostring(S.Layout and S.Layout.RectTransformTransactionContractVersion or 0)
                .. "/rsui=" .. tostring(rsui and rsui.version or 0))

        AddCheck(report, "v3_ui_layout_editor_model_contract", type(rsui) == "table" and (tonumber(rsui.version) or 0) >= 36
                and (tonumber(rsui.AnchorPivotContractVersion) or 0) >= 2
                and type(rsui.CreateAnchorPivotModel) == "function"
                and type(rsui.AnchorPivotModel) == "table"
                and type(rsui.AnchorPresets) == "table"
                and (tonumber(rsui.LayoutEditorSnapSettingsContractVersion) or 0) >= 1
                and type(rsui.CreateLayoutEditorSnapSettingsModel) == "function"
                and type(rsui.LayoutEditorSnapSettingsModel) == "table",
            "blocker", "anchorPivot=" .. tostring(rsui and rsui.AnchorPivotContractVersion or 0)
                .. "/snapSettings=" .. tostring(rsui and rsui.LayoutEditorSnapSettingsContractVersion or 0)
                .. "/rsui=" .. tostring(rsui and rsui.version or 0))

        AddCheck(report, "v3_ui_transform_inspector_contract", type(rsui) == "table" and (tonumber(rsui.version) or 0) >= 36
                and (tonumber(rsui.TransformInspectorContractVersion) or 0) >= 3
                and type(rsui.TransformInspector) == "function"
                and type(rsui.types) == "table" and rsui.types["TransformInspector"] ~= nil
                and type(rsui.AnchorPivotModel) == "table"
                and type(rsui.LayoutEditorSnapSettingsModel) == "table",
            "blocker", "transformInspector=" .. tostring(rsui and rsui.TransformInspectorContractVersion or 0)
                .. "/rsui=" .. tostring(rsui and rsui.version or 0))

        AddCheck(report, "v3_ui_multi_selection_transform_contract", type(rsui) == "table" and (tonumber(rsui.version) or 0) >= 35
                and (tonumber(rsui.MultiSelectionTransformContractVersion) or 0) >= 1
                and type(rsui.CreateMultiSelectionTransformModel) == "function"
                and type(rsui.MultiSelectionTransformModel) == "table"
                and type(rsui.MultiSelectionTransformSession) == "table",
            "blocker", "multiSelectionTransform=" .. tostring(rsui and rsui.MultiSelectionTransformContractVersion or 0)
                .. "/rsui=" .. tostring(rsui and rsui.version or 0))

        AddCheck(report, "v3_ui_layout_editor_preview_adapter_contract", type(rsui) == "table" and (tonumber(rsui.version) or 0) >= 36
                and (tonumber(rsui.LayoutEditorPreviewAdapterContractVersion) or 0) >= 1
                and type(rsui.CreateLayoutEditorPreviewAdapter) == "function"
                and type(rsui.LayoutEditorPreviewAdapter) == "table"
                and (tonumber(rsui.LayoutEditorGestureContractVersion) or 0) >= 2
                and (tonumber(rsui.AnchorPivotContractVersion) or 0) >= 2
                and (tonumber(rsui.TransformInspectorContractVersion) or 0) >= 3,
            "blocker", "previewAdapter=" .. tostring(rsui and rsui.LayoutEditorPreviewAdapterContractVersion or 0)
                .. "/gesture=" .. tostring(rsui and rsui.LayoutEditorGestureContractVersion or 0)
                .. "/anchor=" .. tostring(rsui and rsui.AnchorPivotContractVersion or 0)
                .. "/inspector=" .. tostring(rsui and rsui.TransformInspectorContractVersion or 0)
                .. "/rsui=" .. tostring(rsui and rsui.version or 0))

        AddCheck(report, "v3_ui_layout_edit_history_contract", type(rsui) == "table" and (tonumber(rsui.version) or 0) >= 39
                and (tonumber(rsui.LayoutEditHistoryContractVersion) or 0) >= 1
                and type(rsui.CreateLayoutEditHistoryModel) == "function"
                and type(rsui.LayoutEditHistoryModel) == "table"
                and type(rsui.LayoutEditHistoryLimits) == "table",
            "blocker", "layoutEditHistory=" .. tostring(rsui and rsui.LayoutEditHistoryContractVersion or 0)
                .. "/rsui=" .. tostring(rsui and rsui.version or 0))

        AddCheck(report, "v3_ui_layout_edit_session_contract", type(rsui) == "table" and (tonumber(rsui.version) or 0) >= 41
                and (tonumber(rsui.LayoutEditSessionContractVersion) or 0) >= 1
                and (tonumber(rsui.LayoutEditSessionPersistenceBoundaryContractVersion) or 0) >= 1
                and type(rsui.CreateLayoutEditSessionModel) == "function"
                and type(rsui.LayoutEditSessionModel) == "table"
                and type(rsui.LayoutEditSessionLimits) == "table",
            "blocker", "layoutEditSession=" .. tostring(rsui and rsui.LayoutEditSessionContractVersion or 0)
                .. "/persistenceBoundary=" .. tostring(rsui and rsui.LayoutEditSessionPersistenceBoundaryContractVersion or 0)
                .. "/rsui=" .. tostring(rsui and rsui.version or 0))

        AddCheck(report, "v3_ui_editor_command_bar_contract", type(rsui) == "table" and (tonumber(rsui.version) or 0) >= 41
                and (tonumber(rsui.LayoutEditHistoryObservableContractVersion) or 0) >= 1
                and (tonumber(rsui.EditorCommandBarContractVersion) or 0) >= 2
                and (tonumber(rsui.EditorCommandSessionProjectionContractVersion) or 0) >= 2
                and type(rsui.ProjectEditorCommandState) == "function"
                and type(rsui.EditorCommandBar) == "function"
                and type(rsui.types) == "table" and rsui.types["EditorCommandBar"] ~= nil,
            "blocker", "commandBar=" .. tostring(rsui and rsui.EditorCommandBarContractVersion or 0)
                .. "/historyObservable=" .. tostring(rsui and rsui.LayoutEditHistoryObservableContractVersion or 0)
                .. "/sessionProjection=" .. tostring(rsui and rsui.EditorCommandSessionProjectionContractVersion or 0)
                .. "/rsui=" .. tostring(rsui and rsui.version or 0))

        AddCheck(report, "v3_ui_layout_editor_overlay_contract", type(rsui) == "table" and (tonumber(rsui.version) or 0) >= 37
                and (tonumber(rsui.LayoutEditorOverlayContractVersion) or 0) >= 1
                and type(rsui.LayoutEditorOverlay) == "function"
                and type(rsui.types) == "table" and rsui.types["LayoutEditorOverlay"] ~= nil
                and (tonumber(rsui.LayoutEditorPreviewAdapterContractVersion) or 0) >= 1
                and (tonumber(rsui.LayoutEditorGestureContractVersion) or 0) >= 2,
            "blocker", "layoutEditorOverlay=" .. tostring(rsui and rsui.LayoutEditorOverlayContractVersion or 0)
                .. "/previewAdapter=" .. tostring(rsui and rsui.LayoutEditorPreviewAdapterContractVersion or 0)
                .. "/gesture=" .. tostring(rsui and rsui.LayoutEditorGestureContractVersion or 0)
                .. "/rsui=" .. tostring(rsui and rsui.version or 0))

        AddCheck(report, "v3_ui_layout_editor_workspace_contract", type(rsui) == "table" and (tonumber(rsui.version) or 0) >= 44
                and (tonumber(rsui.ComponentApiContractVersion) or 0) >= 1
                and type(rsui.RequireComponentMethods) == "function"
                and (tonumber(rsui.WorkspaceTemplateContractVersion) or 0) >= 6
                and (tonumber(rsui.LayoutEditorWorkspaceContractVersion) or 0) >= 4
                and (tonumber(rsui.LayoutEditorWorkspaceSessionBindingContractVersion) or 0) >= 1
                and type(rsui.CreateLayoutEditorWorkspace) == "function"
                and type(rsui.WorkspaceTemplates) == "table"
                and type(rsui.WorkspaceTemplates.ValidateLayoutEditorEditSessionSpec) == "function"
                and (tonumber(rsui.LayoutEditorOverlayContractVersion) or 0) >= 1
                and (tonumber(rsui.LayoutEditorOverlayHistoryBindingContractVersion) or 0) >= 1
                and (tonumber(rsui.LayoutEditHistoryContractVersion) or 0) >= 1
                and (tonumber(rsui.LayoutEditSessionContractVersion) or 0) >= 1
                and (tonumber(rsui.EditorCommandBarContractVersion) or 0) >= 2
                and (tonumber(rsui.TransformInspectorContractVersion) or 0) >= 3,
            "blocker", "workspace=" .. tostring(rsui and rsui.WorkspaceTemplateContractVersion or 0)
                .. "/layoutEditor=" .. tostring(rsui and rsui.LayoutEditorWorkspaceContractVersion or 0)
                .. "/componentApi=" .. tostring(rsui and rsui.ComponentApiContractVersion or 0)
                .. "/sessionBinding=" .. tostring(rsui and rsui.LayoutEditorWorkspaceSessionBindingContractVersion or 0)
                .. "/overlayHistory=" .. tostring(rsui and rsui.LayoutEditorOverlayHistoryBindingContractVersion or 0)
                .. "/history=" .. tostring(rsui and rsui.LayoutEditHistoryContractVersion or 0)
                .. "/session=" .. tostring(rsui and rsui.LayoutEditSessionContractVersion or 0)
                .. "/commands=" .. tostring(rsui and rsui.EditorCommandBarContractVersion or 0)
                .. "/rsui=" .. tostring(rsui and rsui.version or 0))

        AddCheck(report, "v3_ui_composite_foundation_contract", type(rsui) == "table"
                and type(compositeFoundation) == "table" and (tonumber(compositeFoundation.version) or 0) >= 4
                and (tonumber(rsui.StatusChipContractVersion) or 0) >= 1 and type(rsui.StatusChip) == "function"
                and (tonumber(rsui.PickerModelContractVersion) or 0) >= 1 and type(rsui.PickerModel) == "table"
                and (tonumber(rsui.SearchablePickerContractVersion) or 0) >= 1 and type(rsui.SearchablePicker) == "function"
                and (tonumber(rsui.IconPickerContractVersion) or 0) >= 1 and type(rsui.IconPicker) == "function"
                and (tonumber(rsui.TreeViewContractVersion) or 0) >= 1 and type(rsui.TreeModel) == "table"
                and (tonumber(rsui.TreeStableIdentityContractVersion) or 0) >= 1
                and (tonumber(rsui.TreeMutationTransactionContractVersion) or 0) >= 2
                and (tonumber(rsui.TreeExpansionStateBoundContractVersion) or 0) >= 1
                and type(rsui.TreeView) == "function",
            "blocker", "statusChip=" .. tostring(rsui and rsui.StatusChipContractVersion or 0)
                .. "/pickerModel=" .. tostring(rsui and rsui.PickerModelContractVersion or 0)
                .. "/searchablePicker=" .. tostring(rsui and rsui.SearchablePickerContractVersion or 0)
                .. "/iconPicker=" .. tostring(rsui and rsui.IconPickerContractVersion or 0)
                .. "/treeView=" .. tostring(rsui and rsui.TreeViewContractVersion or 0)
                .. "/treeIdentity=" .. tostring(rsui and rsui.TreeStableIdentityContractVersion or 0)
                .. "/treeTx=" .. tostring(rsui and rsui.TreeMutationTransactionContractVersion or 0)
                .. "/treeExpandBound=" .. tostring(rsui and rsui.TreeExpansionStateBoundContractVersion or 0)
                .. "/composite=" .. tostring(compositeFoundation and compositeFoundation.version or 0))

        -- 打包已删除的旧 UI 仍可能驻留客户端；若旧 reflow 可达，必须阻断，避免与 RSUI 同时管理组件和弹窗。
        local retiredUiAdapter = S.UI
        local retiredNames = { "CreateCardV2", "CreateSectionV2", "CreateFormRowV2",
                               "CreateChoiceFieldV2", "CreateToggleFieldV2", "CreateNumericFieldV2" }
        local presentRetired = {}
        for _, name in ipairs(retiredNames) do
            if type(retiredUiAdapter) == "table" and retiredUiAdapter[name] ~= nil then
                presentRetired[#presentRetired + 1] = name
            end
        end
        AddCheck(report, "v3_retired_ui_layer_absent",
                type(rsui) == "table"
                and rsui.ComponentsV2 == nil
                and type(retiredUiAdapter) == "table" and retiredUiAdapter.ComponentsV2 == nil
                and #presentRetired == 0
                and type(rsui.ContainerSurface) == "table"
                and type(rsui.ContainerSurface.CreateCard) == "function"
                and type(rsui.ContainerSurface.CreateSection) == "function"
                and (tonumber(rsui.PopupCoordinatorContractVersion) or 0) >= 1
                and type(rsui.PopupCoordinator) == "table"
                and rsui.DropdownService == rsui.PopupCoordinator,
            "blocker", "retiredComponentsV2=" .. tostring((rsui and rsui.ComponentsV2 ~= nil)
                    or (type(retiredUiAdapter) == "table" and retiredUiAdapter.ComponentsV2 ~= nil))
                .. "/retiredHelpers=" .. tostring(#presentRetired)
                .. (presentRetired[1] and (":" .. tostring(presentRetired[1])) or "")
                .. "/containerSurface=" .. tostring(type(rsui) == "table" and type(rsui.ContainerSurface) == "table")
                .. "/popupRegistry=" .. tostring(type(rsui) == "table" and rsui.DropdownService == rsui.PopupCoordinator))

        local uiAdapter = S.UI
        local selectionType = rsui and rsui.SelectionModel or nil
        AddCheck(report, "v3_ui_adapter_selection_contract", type(uiAdapter) == "table"
                and type(uiAdapter.TrySetUILayer) == "function"
                and type(selectionType) == "table" and type(selectionType.GetPrimaryKey) == "function"
                and (tonumber(rsui.DataViewSelectionContractVersion) or 0) >= 2
                and (tonumber(rsui.DropdownContractVersion) or 0) >= 4
                and (tonumber(rsui.DropdownCloseBeforeCommitContractVersion) or 0) >= 1
                and (tonumber(rsui.DropdownDegradedFailClosedContractVersion) or 0) >= 1
                and (tonumber(rsui.DropdownRuntimeInteractionContractVersion) or 0) >= 1
                and (tonumber(rsui.PopupCoordinatorContractVersion) or 0) >= 1
                and type(rsui.PopupCoordinator) == "table" and type(rsui.PopupCoordinator.CloseAll) == "function"
                and (tonumber(rsui.FocusContractVersion) or 0) >= 3
                and type(rsui.Focus) == "table" and type(rsui.Focus.CanSet) == "function"
                and type(rsui.Focus.CanClear) == "function" and type(rsui.Focus.IsFocused) == "function",
            "blocker", "adapterLayer=" .. tostring(type(uiAdapter) == "table" and type(uiAdapter.TrySetUILayer) == "function")
                .. "/selection=" .. tostring(type(selectionType) == "table" and type(selectionType.GetPrimaryKey) == "function")
                .. "/viewContract=" .. tostring(rsui and rsui.DataViewSelectionContractVersion or 0)
                .. "/dropdown=" .. tostring(rsui and rsui.DropdownContractVersion or 0)
                .. "/dropCloseCommit=" .. tostring(rsui and rsui.DropdownCloseBeforeCommitContractVersion or 0)
                .. "/dropFailClosed=" .. tostring(rsui and rsui.DropdownDegradedFailClosedContractVersion or 0)
                .. "/dropRuntime=" .. tostring(rsui and rsui.DropdownRuntimeInteractionContractVersion or 0)
                .. "/popupCoordinator=" .. tostring(rsui and rsui.PopupCoordinatorContractVersion or 0)
                .. "/focus=" .. tostring(rsui and rsui.FocusContractVersion or 0))
        AddCheck(report, "v3_native_interaction_contract", type(uiAdapter) == "table"
                and (tonumber(uiAdapter.NativeInteractionContractVersion) or 0) >= 7
                and (tonumber(uiAdapter.NativeBooleanSetterReturnContractVersion) or 0) >= 1
                and (tonumber(uiAdapter.CriticalInteractionDeliveryContractVersion) or 0) >= 1
                and (tonumber(uiAdapter.CompositeEnabledAdapterContractVersion) or 0) >= 2
                and (tonumber(uiAdapter.InputFocusLifecycleContractVersion) or 0) >= 3
                and (tonumber(uiAdapter.HiddenInputFocusIsolationContractVersion) or 0) >= 2
                and (tonumber(uiAdapter.DeferredKeyboardActivationContractVersion) or 0) >= 1
                and (tonumber(uiAdapter.ExplicitInputCommitFocusContractVersion) or 0) >= 1
                and (tonumber(uiAdapter.InputFocusIdentityCompatibilityContractVersion) or 0) >= 1
                and (tonumber(uiAdapter.NativeCaretPlacementPreservationContractVersion) or 0) >= 2
                and (tonumber(uiAdapter.PostArmFocusPromotionContractVersion) or 0) >= 1
                and (tonumber(uiAdapter.InputActivationDiagnosticsContractVersion) or 0) >= 1
                and (tonumber(uiAdapter.EditBoxCaretVisualContractVersion) or 0) >= 1
                and (tonumber(uiAdapter.EditBoxNormalSelectionContractVersion) or 0) >= 1
                and type(uiAdapter.IsInputWidgetFocused) == "function"
                and type(uiAdapter.SetEditBoxFocusVisual) == "function"
                and type(uiAdapter.ReleaseFocusWithin) == "function"
                and type(uiAdapter.DeactivateInputWidget) == "function"
                and type(uiAdapter.RetireInputWidget) == "function"
                and type(uiAdapter.QuiesceKeyboardInput) == "function"
                and type(uiAdapter.ArmInputWidget) == "function"
                and type(uiAdapter.DisarmInputWidget) == "function"
                and type(uiAdapter.ActivateInputWidget) == "function"
                and type(uiAdapter.DisarmInputWithin) == "function"
                and type(uiAdapter.BindDeferredInputActivation) == "function"
                and type(rsui) == "table"
                and (tonumber(rsui.DeferredKeyboardActivationContractVersion) or 0) >= 1
                and (tonumber(rsui.DegradedRootFailClosedContractVersion) or 0) >= 1
                and (tonumber(rsui.EventBindingContractVersion) or 0) >= 1
                and (tonumber(rsui.PostFactoryRejectReleaseContractVersion) or 0) >= 1
                and (tonumber(rsui.InputLifecycleBridgeContractVersion) or 0) >= 1
                and (tonumber(rsui.BorderInteractionForwardingContractVersion) or 0) >= 1
                and type(rsui.Windowing) == "table" and (tonumber(rsui.Windowing.CriticalInteractionContractVersion) or 0) >= 3
                and (tonumber(rsui.Windowing.DragSurfaceHitTestContractVersion) or 0) >= 1
                and (tonumber(rsui.Windowing.ExplicitDragConditionContractVersion) or 0) >= 1
                and (tonumber(rsui.Windowing.ResizeHitSurfaceContractVersion) or 0) >= 2
                and (tonumber(rsui.Windowing.ResizeCaptureStabilityContractVersion) or 0) >= 2
                and type(rsui.ScrollbarBehavior) == "table" and (tonumber(rsui.ScrollbarBehavior.criticalInteractionContractVersion) or 0) >= 1
                and (tonumber(rsui.ButtonActionContractVersion) or 0) >= 2
                and (tonumber(rsui.ControlTransactionContractVersion) or 0) >= 1
                and (tonumber(rsui.InputDraftCommitContractVersion) or 0) >= 2
                and (tonumber(rsui.InteractiveDraftContractVersion) or 0) >= 4
                and (tonumber(rsui.InputFocusVisualContractVersion) or 0) >= 1
                and (tonumber(rsui.InputDisableDraftCleanupContractVersion) or 0) >= 1
                and (tonumber(rsui.InteractionServiceContractVersion) or 0) >= 2
                and (tonumber(rsui.CollapsibleGroupInteractionContractVersion) or 0) >= 2,
            "blocker", "nativeInteraction=" .. tostring(uiAdapter and uiAdapter.NativeInteractionContractVersion or 0)
                .. "/boolSetter=" .. tostring(uiAdapter and uiAdapter.NativeBooleanSetterReturnContractVersion or 0)
                .. "/criticalDelivery=" .. tostring(uiAdapter and uiAdapter.CriticalInteractionDeliveryContractVersion or 0)
                .. "/compositeEnabled=" .. tostring(uiAdapter and uiAdapter.CompositeEnabledAdapterContractVersion or 0)
                .. "/inputFocus=" .. tostring(uiAdapter and uiAdapter.InputFocusLifecycleContractVersion or 0)
                .. "/hiddenInput=" .. tostring(uiAdapter and uiAdapter.HiddenInputFocusIsolationContractVersion or 0)
                .. "/deferredKeyboard=" .. tostring(uiAdapter and uiAdapter.DeferredKeyboardActivationContractVersion or 0)
                .. "/commitFocus=" .. tostring(uiAdapter and uiAdapter.ExplicitInputCommitFocusContractVersion or 0)
                .. "/focusIdentity=" .. tostring(uiAdapter and uiAdapter.InputFocusIdentityCompatibilityContractVersion or 0)
                .. "/caretPlacement=" .. tostring(uiAdapter and uiAdapter.NativeCaretPlacementPreservationContractVersion or 0)
                .. "/postArmFocus=" .. tostring(uiAdapter and uiAdapter.PostArmFocusPromotionContractVersion or 0)
                .. "/inputDiag=" .. tostring(uiAdapter and uiAdapter.InputActivationDiagnosticsContractVersion or 0)
                .. "/caret=" .. tostring(uiAdapter and uiAdapter.EditBoxCaretVisualContractVersion or 0)
                .. "/degradedRoot=" .. tostring(rsui and rsui.DegradedRootFailClosedContractVersion or 0)
                .. "/eventBinding=" .. tostring(rsui and rsui.EventBindingContractVersion or 0)
                .. "/rejectRelease=" .. tostring(rsui and rsui.PostFactoryRejectReleaseContractVersion or 0)
                .. "/inputBridge=" .. tostring(rsui and rsui.InputLifecycleBridgeContractVersion or 0)
                .. "/borderPick=" .. tostring(rsui and rsui.BorderInteractionForwardingContractVersion or 0)
                .. "/windowCritical=" .. tostring(rsui and rsui.Windowing and rsui.Windowing.CriticalInteractionContractVersion or 0)
                .. "/dragHitTest=" .. tostring(rsui and rsui.Windowing and rsui.Windowing.DragSurfaceHitTestContractVersion or 0)
                .. "/resizeHit=" .. tostring(rsui and rsui.Windowing and rsui.Windowing.ResizeHitSurfaceContractVersion or 0)
                .. "/resizeCapture=" .. tostring(rsui and rsui.Windowing and rsui.Windowing.ResizeCaptureStabilityContractVersion or 0)
                .. "/scrollCritical=" .. tostring(rsui and rsui.ScrollbarBehavior and rsui.ScrollbarBehavior.criticalInteractionContractVersion or 0)
                .. "/buttonAction=" .. tostring(rsui and rsui.ButtonActionContractVersion or 0)
                .. "/controlTx=" .. tostring(rsui and rsui.ControlTransactionContractVersion or 0)
                .. "/draftCommit=" .. tostring(rsui and rsui.InputDraftCommitContractVersion or 0)
                .. "/draft=" .. tostring(rsui and rsui.InteractiveDraftContractVersion or 0)
                .. "/focusVisual=" .. tostring(rsui and rsui.InputFocusVisualContractVersion or 0)
                .. "/interactionSvc=" .. tostring(rsui and rsui.InteractionServiceContractVersion or 0)
                .. "/collapseCritical=" .. tostring(rsui and rsui.CollapsibleGroupInteractionContractVersion or 0))
        local runtime = S.Runtime
        local genericShell = uiAdapter and uiAdapter.WindowShell or nil
        AddCheck(report, "v3_input_focus_drag_foundation_contract", type(runtime) == "table"
                and (tonumber(runtime.inputQuiescenceContractVersion) or 0) >= 1
                and type(genericShell) == "table" and (tonumber(genericShell.titleBarInteractionContract) or 0) >= 1
                and type(rsui) == "table" and (tonumber(rsui.BorderInteractionForwardingContractVersion) or 0) >= 1
                and type(rsui.Windowing) == "table" and (tonumber(rsui.Windowing.DragSurfaceHitTestContractVersion) or 0) >= 1,
            "blocker", "runtimeInput=" .. tostring(runtime and runtime.inputQuiescenceContractVersion or 0)
                .. "/shellTitle=" .. tostring(genericShell and genericShell.titleBarInteractionContract or 0)
                .. "/borderPick=" .. tostring(rsui and rsui.BorderInteractionForwardingContractVersion or 0)
                .. "/dragHitTest=" .. tostring(rsui and rsui.Windowing and rsui.Windowing.DragSurfaceHitTestContractVersion or 0))
        local navigationShell = S.UIV3 and S.UIV3.Shell or nil
        AddCheck(report, "v3_lua51_callback_capture_contract", type(windowing) == "table"
                and (tonumber(windowing.CallbackCaptureContractVersion) or 0) >= 1
                and type(rsui) == "table" and (tonumber(rsui.DataViewCallbackCaptureContractVersion) or 0) >= 1
                and type(navigationShell) == "table" and (tonumber(navigationShell.NavigationCallbackCaptureContractVersion) or 0) >= 1
                and (tonumber(rsui.DropdownContractVersion) or 0) >= 2,
            "blocker", "window=" .. tostring(windowing and windowing.CallbackCaptureContractVersion or 0)
                .. "/data=" .. tostring(rsui and rsui.DataViewCallbackCaptureContractVersion or 0)
                .. "/nav=" .. tostring(navigationShell and navigationShell.NavigationCallbackCaptureContractVersion or 0)
                .. "/dropdown=" .. tostring(rsui and rsui.DropdownContractVersion or 0))
        local missingPublicFactories = {}
        if type(rsui) == "table" and type(rsui.types) == "table" then
            for typeName, factory in pairs(rsui.types) do
                if type(factory) == "function" and type(rsui[typeName]) ~= "function" then missingPublicFactories[#missingPublicFactories + 1] = tostring(typeName) end
            end
            table.sort(missingPublicFactories)
        end
        AddCheck(report, "v3_rsui_public_factory_contract", type(rsui) == "table"
                and type(rsui.TextInput) == "function" and #missingPublicFactories == 0,
            "blocker", "textInput=" .. tostring(type(rsui) == "table" and type(rsui.TextInput) == "function")
                .. "/missing=" .. tostring(#missingPublicFactories)
                .. (#missingPublicFactories > 0 and ("[" .. Join(missingPublicFactories, 6) .. "]") or ""))
        AddCheck(report, "v3_rsui_strict_build_scope_contract", type(rsui) == "table"
                and (tonumber(rsui.BuildScopeContractVersion) or 0) >= 4
                and (tonumber(rsui.BuildTransactionContractVersion) or 0) >= 2
                and (tonumber(rsui.BuildRollbackInputQuiescenceContractVersion) or 0) >= 1
                and (tonumber(rsui.PreflightContractVersion) or 0) >= 1
                and (tonumber(rsui.LogicalIdGenerationFenceVersion) or 0) >= 1
                and type(rsui.BeginBuildScope) == "function" and type(rsui.EndBuildScope) == "function"
                and type(rsui.WithBuildScope) == "function" and type(rsui.ValidateSpec) == "function"
                and type(rsui.RegisterTypeValidator) == "function",
            "blocker", "buildScope=" .. tostring(rsui and rsui.BuildScopeContractVersion or 0)
                .. "/tx=" .. tostring(rsui and rsui.BuildTransactionContractVersion or 0)
                .. "/rollbackInput=" .. tostring(rsui and rsui.BuildRollbackInputQuiescenceContractVersion or 0)
                .. "/preflight=" .. tostring(rsui and rsui.PreflightContractVersion or 0)
                .. "/logicalFence=" .. tostring(rsui and rsui.LogicalIdGenerationFenceVersion or 0)
                .. "/begin=" .. tostring(type(rsui) == "table" and type(rsui.BeginBuildScope) == "function")
                .. "/wrapper=" .. tostring(type(rsui) == "table" and type(rsui.WithBuildScope) == "function"))
        local preflightValidators = rsui and rsui.typeValidators or nil
        AddCheck(report, "v3_rsui_preflight_contract", type(preflightValidators) == "table"
                and type(preflightValidators.TableView) == "function"
                and type(preflightValidators.Table) == "function"
                and type(preflightValidators.SegmentedSelector) == "function"
                and type(preflightValidators.NumericField) == "function",
            "blocker", "table=" .. tostring(type(preflightValidators) == "table" and type(preflightValidators.TableView) == "function")
                .. "/tableAlias=" .. tostring(type(preflightValidators) == "table" and type(preflightValidators.Table) == "function")
                .. "/segment=" .. tostring(type(preflightValidators) == "table" and type(preflightValidators.SegmentedSelector) == "function")
                .. "/numeric=" .. tostring(type(preflightValidators) == "table" and type(preflightValidators.NumericField) == "function"))
        local textLayout = rsui and rsui.TextLayout or nil
        local designContract = S.UIV3Design
        local numericRangeStore = S.Persistence and type(S.Persistence.GetStore) == "function" and S.Persistence:GetStore("v3.rsui.numeric_ranges") or nil
        AddCheck(report, "v3_typography_form_layout_contract", type(S.Theme) == "table" and type(S.Theme.ResolveFontSize) == "function"
                and type(textLayout) == "table" and (tonumber(textLayout.version) or 0) >= 3
                and (tonumber(rsui.FormLayoutContractVersion) or 0) >= 2
                and (tonumber(rsui.NumericInlineContractVersion) or 0) >= 6
                and (tonumber(rsui.NumericStepPairFallbackContractVersion) or 0) >= 1
                -- 通用 Form 契约须与 SettingsFoundation 对齐；范围端点仍为 Presentation 元数据，这里不隐含
                -- Feature Store 迁移。
                and (tonumber(rsui.NumericAdaptiveRangeContractVersion) or 0) >= 2
                and (tonumber(rsui.NumericExplicitApplyContractVersion) or 0) >= 1
                and (tonumber(rsui.NumericRangePersistenceContractVersion) or 0) >= 1
                and type(numericRangeStore) == "table" and tostring(numericRangeStore.owner or "") == "v3.rsui.numeric_ranges"
                and (tonumber(rsui.InteractiveDraftContractVersion) or 0) >= 4
                and (tonumber(rsui.InputDraftCommitContractVersion) or 0) >= 2
                and (tonumber(rsui.NumericInputDraftReadContractVersion) or 0) >= 1
                and (tonumber(rsui.StableButtonHoverContractVersion) or 0) >= 2
                and (tonumber(rsui.WidgetSwitcherContractVersion) or 0) >= 2
                and type(designContract) == "table" and (tonumber(designContract.version) or 0) >= 7
                and type(designContract.CompactNumericSetting) == "function",
            "blocker", "text=" .. tostring(textLayout and textLayout.version or 0)
                .. "/form=" .. tostring(rsui and rsui.FormLayoutContractVersion or 0)
                .. "/numericInline=" .. tostring(rsui and rsui.NumericInlineContractVersion or 0)
                .. "/stepPair=" .. tostring(rsui and rsui.NumericStepPairFallbackContractVersion or 0)
                .. "/adaptiveRange=" .. tostring(rsui and rsui.NumericAdaptiveRangeContractVersion or 0)
                .. "/explicitApply=" .. tostring(rsui and rsui.NumericExplicitApplyContractVersion or 0)
                .. "/rangeStore=" .. tostring(rsui and rsui.NumericRangePersistenceContractVersion or 0)
                .. "/rangeOwner=" .. tostring(numericRangeStore and numericRangeStore.owner or "missing")
                .. "/draft=" .. tostring(rsui and rsui.InteractiveDraftContractVersion or 0)
                .. "/draftCommit=" .. tostring(rsui and rsui.InputDraftCommitContractVersion or 0)
                .. "/draftRead=" .. tostring(rsui and rsui.NumericInputDraftReadContractVersion or 0)
                .. "/hover=" .. tostring(rsui and rsui.StableButtonHoverContractVersion or 0)
                .. "/switch=" .. tostring(rsui and rsui.WidgetSwitcherContractVersion or 0)
                .. "/design=" .. tostring(designContract and designContract.version or 0))
        local tooltipService = rsui and rsui.Tooltip or nil
        AddCheck(report, "v3_floating_text_layout_contract", type(rsui) == "table"
                and (tonumber(rsui.WrappedTextContractVersion) or 0) >= 2
                and type(rsui.NormalizeWrappedTextSizing) == "function"
                and genericShellInfo ~= nil and (tonumber(genericShellInfo.version) or 0) >= 15
                and floatingInfo ~= nil and (tonumber(floatingInfo.version) or 0) >= 7
                and type(floatingSurface.GetSnapshot) == "function"
                and type(tooltipService) == "table" and (tonumber(tooltipService.version) or 0) >= 6
                and (tonumber(tooltipService.TransientLayerContractVersion) or 0) >= 1
                and (tonumber(tooltipService.LineEstimateContractVersion) or 0) >= 1
                and (tonumber(tooltipService.IsShowingContractVersion) or 0) >= 1
                and type(tooltipService.IsShowing) == "function",
            "blocker", "wrapped=" .. tostring(rsui and rsui.WrappedTextContractVersion or 0)
                .. "/shell=" .. tostring(genericShellInfo and genericShellInfo.version or 0)
                .. "/floating=" .. tostring(floatingInfo and floatingInfo.version or 0)
                .. "/tooltip=" .. tostring(tooltipService and tooltipService.version or 0))
        AddCheck(report, "v3_floating_shell_appearance_contract", type(rsui) == "table"
                and (tonumber(rsui.version) or 0) >= 23
                and (tonumber(rsui.FloatingFontScaleContractVersion) or 0) >= 1
                and type(rsui.ApplyFontScale) == "function"
                and genericShellInfo ~= nil and (tonumber(genericShellInfo.version) or 0) >= 15
                and floatingInfo ~= nil and (tonumber(floatingInfo.version) or 0) >= 7
                and widgetInfo ~= nil and (tonumber(widgetInfo.version) or 0) >= 12
                and (tonumber(widgetHost.preferenceInitializationContractVersion) or 0) >= 2
                and type(widgetHost.SetFontScale) == "function",
            "blocker", "rsui=" .. tostring(rsui and rsui.version or 0)
                .. "/font=" .. tostring(rsui and rsui.FloatingFontScaleContractVersion or 0)
                .. "/shell=" .. tostring(genericShellInfo and genericShellInfo.version or 0)
                .. "/floating=" .. tostring(floatingInfo and floatingInfo.version or 0)
                .. "/widget=" .. tostring(widgetInfo and widgetInfo.version or 0))
        local floatingAppearanceIds = { "life.activities", "life.tasks", "combat.death_review", "combat.dps" }
        local floatingAppearanceMissing = {}
        if type(widgetHost) == "table" and type(widgetHost.GetSpec) == "function" then
            for _, widgetId in ipairs(floatingAppearanceIds) do
                local spec = widgetHost:GetSpec(widgetId)
                if type(spec) ~= "table" or spec.fontScaleAdjustable ~= true
                        or type(spec.getFontScale) ~= "function" or type(spec.setFontScale) ~= "function" then
                    floatingAppearanceMissing[#floatingAppearanceMissing + 1] = widgetId
                end
            end
        else
            floatingAppearanceMissing = floatingAppearanceIds
        end
        AddCheck(report, "v3_floating_appearance_parity", #floatingAppearanceMissing == 0,
            "blocker", "missing=" .. tostring(#floatingAppearanceMissing)
                .. (#floatingAppearanceMissing > 0 and ("[" .. Join(floatingAppearanceMissing, 4) .. "]") or ""))

        AddCheck(report, "v3_compact_selector_contract", type(rsui) == "table"
                and (tonumber(rsui.version) or 0) >= 20
                and (tonumber(rsui.SegmentedSelectorContractVersion) or 0) >= 1
                and type(rsui.SegmentedSelector) == "function",
            "blocker", "rsui=" .. tostring(rsui and rsui.version or 0)
                .. "/segmented=" .. tostring(rsui and rsui.SegmentedSelectorContractVersion or 0)
                .. "/factory=" .. tostring(type(rsui) == "table" and type(rsui.SegmentedSelector) == "function"))
        AddCheck(report, "v3_floating_interaction_contract", type(rsui) == "table"
                and (tonumber(rsui.DataViewViewportContractVersion) or 0) >= 2
                and (tonumber(rsui.DataViewOverlayScrollbarContractVersion) or 0) >= 1
                and (tonumber(rsui.DataViewResizePreviewAuthorityContractVersion) or 0) >= 2
                and genericShellInfo ~= nil and (tonumber(genericShellInfo.version) or 0) >= 17
                and floatingInfo ~= nil and (tonumber(floatingInfo.version) or 0) >= 7
                and modalInfo ~= nil and (tonumber(modalInfo.version) or 0) >= 4
                and type(modalHost.EnsureApplicationVisible) == "function",
            "blocker", "viewport=" .. tostring(rsui and rsui.DataViewViewportContractVersion or 0)
                .. "/overlayScroll=" .. tostring(rsui and rsui.DataViewOverlayScrollbarContractVersion or 0)
                .. "/resizePreview=" .. tostring(rsui and rsui.DataViewResizePreviewAuthorityContractVersion or 0)
                .. "/shell=" .. tostring(genericShellInfo and genericShellInfo.version or 0)
                .. "/floating=" .. tostring(floatingInfo and floatingInfo.version or 0)
                .. "/modal=" .. tostring(modalInfo and modalInfo.version or 0))
        local rsuiInfo = type(rsui.GetSnapshot) == "function" and rsui:GetSnapshot() or nil
        local pageInfo = S.UIV3 and S.UIV3.PageHost and type(S.UIV3.PageHost.Describe) == "function" and S.UIV3.PageHost:Describe() or nil
        local businessPagesContract = S.UIV3 and S.UIV3.BusinessPagesContract or nil
        AddCheck(report, "v3_build_transaction_contract", rsuiInfo ~= nil and type(rsui.WithBuildScope) == "function"
                and type(rsui.TrackBuildWidget) == "function"
                and (tonumber(rsui.StrictBuildFailFastContractVersion) or 0) >= 1
                and type(businessPagesContract) == "table" and (tonumber(businessPagesContract.componentIdContractVersion) or 0) >= 1
                and (tonumber(rsuiInfo.activeBuildScopes) or 0) == 0
                and (tonumber(rsuiInfo.buildScopeCloseOrderRecoveries) or 0) == 0
                and (tonumber(rsuiInfo.buildScopeCleanupFailures) or 0) == 0
                and (tonumber(rsuiInfo.buildTransactionFailures) or 0) == 0
                and (tonumber(rsuiInfo.preflightFailures) or 0) == 0
                and pageInfo ~= nil and (tonumber(pageInfo.version) or 0) >= 4
                and (tonumber(pageInfo.buildTransactionContractVersion) or 0) >= 1 and (tonumber(pageInfo.quarantined) or 0) == 0
                and widgetInfo ~= nil and (tonumber(widgetInfo.version) or 0) >= 13
                and (tonumber(widgetInfo.buildTransactionContractVersion) or 0) >= 1 and (tonumber(widgetInfo.quarantined) or 0) == 0,
            "blocker", rsuiInfo and ("scope=" .. tostring(rsuiInfo.activeBuildScopes or 0)
                .. "/rollback=" .. tostring(rsuiInfo.buildScopesRolledBack or 0)
                .. "/closeRecover=" .. tostring(rsuiInfo.buildScopeCloseOrderRecoveries or 0)
                .. "/cleanupFail=" .. tostring(rsuiInfo.buildScopeCleanupFailures or 0)
                .. "/txFail=" .. tostring(rsuiInfo.buildTransactionFailures or 0)
                .. "/preflightFail=" .. tostring(rsuiInfo.preflightFailures or 0)
                .. "/failFastCount=" .. tostring(rsuiInfo.strictBuildFailFast or 0)
                .. "/pageQ=" .. tostring(pageInfo and pageInfo.quarantined or 0)
                .. "/widgetQ=" .. tostring(widgetInfo and widgetInfo.quarantined or 0)
                .. "/failFast=" .. tostring(rsui and rsui.StrictBuildFailFastContractVersion or 0)
                .. "/businessIds=" .. tostring(businessPagesContract and businessPagesContract.componentIdContractVersion or 0)) or "missing")

        -- 模块诊断跨 Core/RSUI/PageHost/Design/Presentation，需整套接口匹配，避免有按钮却无 CopyBox，或归属到错误 Feature。
        -- 这里只验版本和 Aux policy，不创建窗口或调用 Provider。
        local moduleDiagnosticsHub = S.ModuleDiagnosticsHub
        local moduleDiagnosticsWindow = S.UIV3 and S.UIV3.ModuleDiagnosticsWindowV3 or nil
        local moduleDiagnosticsPolicy = type(auxWindowStore) == "table" and type(auxWindowStore.GetPolicy) == "function"
            and auxWindowStore:GetPolicy("module_diagnostics") or nil
        local moduleDiagnosticsRegistryAlias = false
        local buffDiagnosticsMeta = S.FeatureRegistry and type(S.FeatureRegistry.Get) == "function"
            and S.FeatureRegistry:Get("combat_buff_display") or nil
        for _, source in ipairs(type(buffDiagnosticsMeta) == "table" and type(buffDiagnosticsMeta.diagnosticSources) == "table"
            and buffDiagnosticsMeta.diagnosticSources or {}) do
            if tostring(source) == "buff_display_v3" then moduleDiagnosticsRegistryAlias = true; break end
        end
        AddCheck(report, "v3_module_diagnostics_contract",
            type(moduleDiagnosticsHub) == "table" and (tonumber(moduleDiagnosticsHub.contractVersion) or 0) >= 1
                and type(moduleDiagnosticsHub.Capture) == "function" and type(moduleDiagnosticsHub.GetPage) == "function"
                and type(S.UI) == "table" and (tonumber(S.UI.DiagnosticCopyBoxContractVersion) or 0) >= 3
                and type(S.UI.CreateDiagnosticCopyBox) == "function"
                and pageInfo ~= nil and (tonumber(pageInfo.buildContextContractVersion) or 0) >= 1
                and type(S.UIV3Design) == "table" and (tonumber(S.UIV3Design.diagnosticHeaderContractVersion) or 0) >= 1
                and type(S.UIV3Design.ModuleDiagnosticsButton) == "function"
                and type(moduleDiagnosticsWindow) == "table" and (tonumber(moduleDiagnosticsWindow.contractVersion) or 0) >= 2
                and (tonumber(moduleDiagnosticsWindow.AutoReadbackRepageContractVersion) or 0) >= 1
                and type(moduleDiagnosticsWindow.Open) == "function" and type(moduleDiagnosticsPolicy) == "table"
                and moduleDiagnosticsRegistryAlias == true,
            "blocker", "hub=" .. tostring(moduleDiagnosticsHub and moduleDiagnosticsHub.contractVersion or 0)
                .. "/copy=" .. tostring(S.UI and S.UI.DiagnosticCopyBoxContractVersion or 0)
                .. "/page=" .. tostring(pageInfo and pageInfo.buildContextContractVersion or 0)
                .. "/design=" .. tostring(S.UIV3Design and S.UIV3Design.diagnosticHeaderContractVersion or 0)
                .. "/window=" .. tostring(moduleDiagnosticsWindow and moduleDiagnosticsWindow.contractVersion or 0)
                .. "/policy=" .. tostring(type(moduleDiagnosticsPolicy) == "table")
                .. "/registryAlias=" .. tostring(moduleDiagnosticsRegistryAlias))

        -- 业务表现命令分别由 tasks、activities、gear 的 acceptance 检查，sequence 失败同样阻断。
        -- Gear 的快速启动意图仍由独立 v3_quick_surface_reload_reconcile_contract 检查。
        local gearService = S.Services and S.Services.GearV3 or nil
        AddCheck(report, "gear_partial_apply_contract", type(gearService) == "table" and (tonumber(gearService.version) or 0) >= 5
                and (tonumber(gearService.PartialApplyContractVersion) or 0) >= 1
                and (tonumber(gearService.TitleEffectAuthorityContractVersion) or 0) >= 1
                and type(gearService.ValidateReachableSession) == "function" and type(gearService.PartialSummary) == "function"
                and type(gearService.GetCurrentShowingAppellationType) == "function",
            "blocker", "GearV3 v5 must keep title effect authoritative and preserve current display nameType (including 0)")

        local nativeAdapter = S.UIV3NativeAdapter
        local adapterInfo = nativeAdapter and type(nativeAdapter.Describe) == "function" and nativeAdapter:Describe() or nil
        -- 主 Shell 显式启用原生 Esc，并在 OnHide 交回输入/可见性所有权；两种已接受的策略都有效。
        -- 不能用“禁用次数为零”否决仅创建主 Shell 的正常启动，缺少原生策略证据仍然阻断。
        AddCheck(report, "v3_native_root_policy", adapterInfo ~= nil and (tonumber(adapterInfo.version) or 0) >= 3
                and (tonumber(adapterInfo.rootInteractionPolicyContractVersion) or 0) >= 2
                and (tonumber(adapterInfo.rootsCreated) or 0) >= 1
                and ((tonumber(adapterInfo.nativeEscapeCloseDisabled) or 0)
                    + (tonumber(adapterInfo.nativeEscapeCloseEnabled) or 0)) >= 1,
            "blocker", adapterInfo and ("version=" .. tostring(adapterInfo.version) .. "/roots=" .. tostring(adapterInfo.rootsCreated)
                .. "/policy=" .. tostring(adapterInfo.rootInteractionPolicyContractVersion or 0)
                .. "/escapeFence=" .. tostring(adapterInfo.nativeEscapeCloseDisabled)
                .. "/escapeEnabled=" .. tostring(adapterInfo.nativeEscapeCloseEnabled or 0)) or "missing")

        local design = S.UIV3Design
        AddCheck(report, "v3_scrollable_page_contract", type(design) == "table" and (tonumber(design.version) or 0) >= 4 and type(design.ScrollablePageRoot) == "function",
            "blocker", "Design v4: page roots accept id/spec and settings/forms can scroll at minimum viewport")

        local navEntries = shell and shell.navScroll and shell.navScroll.GetScrollableEntries and shell.navScroll:GetScrollableEntries() or {}
        local router = S.UIV3 and S.UIV3.Router or nil
        AddCheck(report, "v3_navigation_critical_access", shell ~= nil and shell.navScroll ~= nil and #navEntries >= 12
                and (tonumber(shell.NavigationCallbackCaptureContractVersion) or 0) >= 1
                and (tonumber(shell.DevelopmentNavigationPresentationContractVersion) or 0) >= 1 -- navigationTitle 独立于页面 title，避免“未完成”标记污染页标题。
                and type(router) == "table" and (tonumber(router.DevelopmentOrderContractVersion) or 0) >= 1
                and shell.navButtons ~= nil and shell.navButtons["system.settings"] ~= nil
                and shell.navButtons["system.diagnostics"] ~= nil and shell.reloadButton ~= nil,
            "blocker", "entries=" .. tostring(#navEntries) .. "/capture=" .. tostring(shell and shell.NavigationCallbackCaptureContractVersion or 0)
                .. "/devNav=" .. tostring(shell and shell.DevelopmentNavigationPresentationContractVersion or 0) .. "/" .. tostring(router and router.DevelopmentOrderContractVersion or 0)
                .. "/settings=" .. tostring(shell and shell.navButtons and shell.navButtons["system.settings"] ~= nil)
                .. "/diagnostics=" .. tostring(shell and shell.navButtons and shell.navButtons["system.diagnostics"] ~= nil)
                .. "/reload=" .. tostring(shell and shell.reloadButton ~= nil))

        local pageHost = S.UIV3 and S.UIV3.PageHost or nil
        -- 统一统计只保留一个主导航，分析/历史是页内视图；旧双按钮断言会把正确整合误报为阻断。
        AddCheck(report, "v3_combat_navigation_contract", shell ~= nil and shell.navButtons ~= nil
                and shell.navButtons["combat.stats"] ~= nil and shell.navButtons["combat.analytics"] == nil
                and shell.navButtons["combat.personal_history"] == nil
                and shell.navButtons["combat.statistics_settings"] == nil
                and pageHost ~= nil and type(pageHost.factories) == "table"
                and type(pageHost.factories["combat.stats"]) == "function"
                and type(pageHost.factories["combat.analytics"]) == "function"
                and type(pageHost.factories["combat.personal_history"]) == "function"
                and type(pageHost.factories["combat.statistics_settings"]) == "function"
                and S.UIV3Acceptance ~= nil and (tonumber(S.UIV3Acceptance.version) or 0) >= 34,
            "blocker", "dpsButton=" .. tostring(shell and shell.navButtons and shell.navButtons["combat.stats"] ~= nil)
                .. "/analyticsButton=" .. tostring(shell and shell.navButtons and shell.navButtons["combat.analytics"] ~= nil)
                .. "/dpsFactory=" .. tostring(pageHost and pageHost.factories and type(pageHost.factories["combat.stats"]) == "function")
                .. "/analyticsFactory=" .. tostring(pageHost and pageHost.factories and type(pageHost.factories["combat.analytics"]) == "function")
                .. "/historyFactory=" .. tostring(pageHost and pageHost.factories and type(pageHost.factories["combat.personal_history"]) == "function")
                .. "/settingsFactory=" .. tostring(pageHost and pageHost.factories and type(pageHost.factories["combat.statistics_settings"]) == "function"))
        AddCheck(report, "v3_reload_authority", type(S.ReloadCodeFromDisk) == "function"
                and S.Persistence ~= nil and type(S.Persistence.Flush) == "function"
                and (tonumber(S.RecoveryReloadContractVersion) or 0) >= 1,
            "blocker", "reload=" .. tostring(type(S.ReloadCodeFromDisk) == "function")
                .. "/flush=" .. tostring(S.Persistence ~= nil and type(S.Persistence.Flush) == "function")
                .. "/recovery=" .. tostring(S.RecoveryReloadContractVersion or 0))

        local appState = S.AppState and type(S.AppState.Describe) == "function" and S.AppState:Describe() or nil
        AddCheck(report, "v3_app_ui_settings", appState ~= nil and appState.loaded == true
                and tonumber(appState.addonScale) ~= nil and tonumber(appState.fontScale) ~= nil
                and S.Layout ~= nil and type(S.Layout.RefreshNow) == "function",
            "blocker", appState and ("scale=" .. tostring(appState.addonScale) .. "/font=" .. tostring(appState.fontScale) .. "/appearance=" .. tostring(appState.appearance)) or "missing")

        local featureRuntime = S.FeatureRuntime and type(S.FeatureRuntime.Describe) == "function" and S.FeatureRuntime:Describe() or nil
        local featureStore = S.Persistence and type(S.Persistence.GetStore) == "function" and S.Persistence:GetStore("v3.features") or nil
        AddCheck(report, "v3_feature_preferences", featureRuntime ~= nil and featureRuntime.preferencesLoaded == true and featureStore ~= nil,
            "blocker", featureRuntime and ("loaded=" .. tostring(featureRuntime.preferencesLoaded) .. "/explicit=" .. tostring(featureRuntime.explicitPreferences or 0)) or "missing")

        local demand = S.Demand and type(S.Demand.Describe) == "function" and S.Demand:Describe() or nil
        AddCheck(report, "v3_demand_hardening_contract", S.Demand ~= nil and (tonumber(S.Demand.version) or 0) >= 2
                and type(S.Demand.Create) == "function" and type(S.Demand.ClearAll) == "function"
                and demand ~= nil and demand.quiesceFailures ~= nil,
            "blocker", demand and ("version=" .. tostring(demand.version) .. "/leases=" .. tostring(demand.leases or 0)
                .. "/quiesceFail=" .. tostring(demand.quiesceFailures or 0)) or "missing")
    end

    local unitIdentity = S.Services and S.Services.UnitIdentityV3 or nil
    local unitIdentityHealth = unitIdentity and type(unitIdentity.GetHealth) == "function" and unitIdentity:GetHealth() or nil
    AddCheck(report, "combat_unit_identity_contract", unitIdentity ~= nil and (tonumber(unitIdentity.version) or 0) >= 1
            and type(unitIdentity.ResolveCombatEndpoint) == "function" and type(unitIdentity.GetById) == "function"
            and type(unitIdentity.ParseExplicitKind) == "function" and unitIdentityHealth ~= nil,
        "blocker", unitIdentityHealth and ("cache=" .. tostring(unitIdentityHealth.cache or 0)
            .. "/bind=" .. tostring(unitIdentityHealth.endpointBinds or 0)
            .. "/ambiguous=" .. tostring(unitIdentityHealth.endpointAmbiguous or 0)) or "missing")

    local combatBus = S.Services and S.Services.CombatEventBusV3 or nil
    local combatHealth = combatBus and type(combatBus.GetHealth) == "function" and combatBus:GetHealth() or nil
    local combatCapsRegistered = true
    for _, capability in ipairs({ "X2Unit:GetUnitNameById", "X2Unit:GetUnitInfoById", "UI:SetEventHandler", "UI:ReleaseEventHandler", "UIParent:SetEventHandler", "UIParent:ReleaseEventHandler" }) do
        if S.ApiCapabilities == nil or S.ApiCapabilities:Get(capability) == nil then combatCapsRegistered = false; break end
    end
    AddCheck(report, "combat_event_bus_contract", combatBus ~= nil and (tonumber(combatBus.version) or 0) >= 6
            and type(combatBus.Subscribe) == "function" and type(combatBus.Unsubscribe) == "function"
            and type(combatBus.DescribeEventType) == "function" and type(combatBus.ParseAmount) == "function"
            and type(combatBus.GetCoverageState) == "function" and type(combatBus.GetHealth) == "function"
            and combatBus.demand ~= nil and combatCapsRegistered == true,
        "blocker", combatHealth and ("version=" .. tostring(combatHealth.version or 0)
            .. "/consumer=" .. tostring(combatHealth.consumers or 0)
            .. "/scope=" .. tostring(combatHealth.scope or "none")
            .. "/coverage=" .. tostring(combatHealth.coverageState or "?")
            .. "/global=" .. tostring(combatHealth.globalHosts or 0)
            .. "/caps=" .. tostring(combatCapsRegistered)) or "missing")
    -- 释放兼容性必须可观察：“API 缺失”（宿主停放）与“API 存在但调用失败”须区分，只有后者可报告真实事务失败。
    AddCheck(report, "combat_event_bus_release_contract", combatBus ~= nil
            and type(combatBus._MarkInert) == "function"
            and combatHealth ~= nil and combatHealth.releaseApiMissing ~= nil
            and combatHealth.releaseCallFailures ~= nil and combatHealth.forcedInert ~= nil,
        "blocker", combatHealth and ("apiMissing=" .. tostring(combatHealth.releaseApiMissing or 0)
            .. "/callFail=" .. tostring(combatHealth.releaseCallFailures or 0)
            .. "/stopFail=" .. tostring(combatHealth.stopFailures or 0)
            .. "/forcedInert=" .. tostring(combatHealth.forcedInert or 0)
            .. "/parkedPrivate=" .. tostring(combatHealth.privateParked == true)
            .. "/parkedGlobal=" .. tostring(combatHealth.globalParkedHosts or 0)) or "missing")
    AddCheck(report, "combat_event_bus_runtime_health", combatHealth ~= nil
            and (tonumber(combatHealth.callbackErrors) or 0) == 0
            and (tonumber(combatHealth.factMutationErrors) or 0) == 0
            and (tonumber(combatHealth.startFailures) or 0) == 0,
        "warning", combatHealth and ("callbackErr=" .. tostring(combatHealth.callbackErrors or 0)
            .. "/mutationErr=" .. tostring(combatHealth.factMutationErrors or 0)
            .. "/startFail=" .. tostring(combatHealth.startFailures or 0)
            .. "/scopeFiltered=" .. tostring(combatHealth.scopeFiltered or 0)
            .. "/unknown=" .. tostring(combatHealth.unknownKinds or 0)) or "missing")
    AddCheck(report, "combat_event_bus_coverage_health", combatHealth ~= nil
            and (combatHealth.globalActive ~= true or tostring(combatHealth.coverageState or "") ~= "UNAVAILABLE"),
        "warning", combatHealth and ("coverage=" .. tostring(combatHealth.coverageState or "?")
            .. "/hosts=" .. tostring(combatHealth.globalHosts or 0)
            .. "/journal=" .. tostring(combatHealth.journalPending or 0)
            .. "/replay=" .. tostring(combatHealth.journalReplayed or 0)
            .. "/drop=" .. tostring(combatHealth.journalDropped or 0)) or "missing")

    local analytics = S.Services and S.Services.CombatAnalyticsV3 or nil
    local analyticsHealth = analytics and type(analytics.GetHealth) == "function" and analytics:GetHealth() or nil
    local abilityCatalog = S.Data and S.Data.CombatAbilityCatalog or nil
    local abilityHealth = abilityCatalog and type(abilityCatalog.GetHealth) == "function" and abilityCatalog:GetHealth() or nil
    local mechanicCatalog = S.Data and S.Data.CombatMechanicCatalog or nil
    local analyticsStore = S.Persistence and type(S.Persistence.GetStore) == "function" and S.Persistence:GetStore("v3.combat_analytics") or nil
    local analyticsMeta = S.FeatureRegistry and S.FeatureRegistry:Get("combat_analytics") or nil
    local analyticsPage = S.UIV3 and S.UIV3.PageHost and S.UIV3.PageHost.factories and S.UIV3.PageHost.factories["combat.analytics"] or nil
    AddCheck(report, "combat_analytics_contract", analytics ~= nil and (tonumber(analytics.version) or 0) >= 3
            and type(analytics.RegisterMetric) == "function" and type(analytics.AcquireConsumer) == "function"
            and type(analytics.ResetMetrics) == "function" and type(analytics.HasConsumer) == "function"
            and type(analytics.NotifyMetricChanged) == "function"
            and type(analytics.ReleaseConsumer) == "function" and type(analytics.GetMetricProjection) == "function"
            and type(analytics.GetMetricActorDetail) == "function"
            and analytics.Demand ~= nil and analyticsHealth ~= nil and (tonumber(analyticsHealth.registeredMetrics) or 0) >= 9
            and analyticsStore ~= nil and analyticsMeta ~= nil and analyticsPage ~= nil,
        "blocker", analyticsHealth and ("version=" .. tostring(analyticsHealth.version or 0)
            .. "/registered=" .. tostring(analyticsHealth.registeredMetrics or 0)
            .. "/active=" .. tostring(analyticsHealth.activeMetrics or 0)
            .. "/consumer=" .. tostring(analyticsHealth.consumers or 0)) or "missing")
    AddCheck(report, "combat_analytics_catalogs", abilityHealth ~= nil and (tonumber(abilityHealth.skills) or 0) >= 100
            and (tonumber(abilityHealth.songs) or 0) >= 4 and mechanicCatalog ~= nil
            and type(mechanicCatalog.FindCast) == "function" and type(mechanicCatalog.FindDebuff) == "function",
        "blocker", abilityHealth and ("skills=" .. tostring(abilityHealth.skills or 0)
            .. "/control=" .. tostring(abilityHealth.control or 0)
            .. "/utility=" .. tostring(abilityHealth.utility or 0)
            .. "/songs=" .. tostring(abilityHealth.songs or 0)) or "missing")
    local skillMetadata = S.Services and S.Services.SkillMetadataV3 or nil
    local skillMetadataHealth = type(skillMetadata) == "table" and type(skillMetadata.GetHealth) == "function" and skillMetadata:GetHealth() or nil
    AddCheck(report, "skill_metadata_v3_contract", type(skillMetadata) == "table" and (tonumber(skillMetadata.version) or 0) >= 1
            and type(skillMetadata.GetSkillInfo) == "function" and skillMetadataHealth ~= nil
            and (tonumber(skillMetadataHealth.cacheMax) or 0) >= 128 and (tonumber(skillMetadataHealth.cacheMax) or 0) <= 1024,
        "blocker", skillMetadataHealth and ("version=" .. tostring(skillMetadataHealth.version or 0)
            .. "/cache=" .. tostring(skillMetadataHealth.cacheCount or 0) .. "/" .. tostring(skillMetadataHealth.cacheMax or 0)
            .. "/lookups=" .. tostring(skillMetadataHealth.nativeLookups or 0)) or "missing")
    AddCheck(report, "combat_analytics_runtime_health", analyticsHealth ~= nil
            and (tonumber(analyticsHealth.metricErrors) or 0) == 0
            and (tonumber(analyticsHealth.metricMutations) or 0) == 0
            and (tonumber(analyticsHealth.emptyConsumers) or 0) == 0,
        "warning", analyticsHealth and ("errors=" .. tostring(analyticsHealth.metricErrors or 0)
            .. "/mutations=" .. tostring(analyticsHealth.metricMutations or 0)
            .. "/emptyConsumers=" .. tostring(analyticsHealth.emptyConsumers or 0)
            .. "/facts=" .. tostring(analyticsHealth.factsReceived or 0)
            .. "/damagePlan=" .. tostring(analyticsHealth.damageDispatchMetrics or 0)
            .. "/auraPlan=" .. tostring(analyticsHealth.auraDispatchMetrics or 0)) or "missing")

    local teamRoster = S.Services and S.Services.TeamRosterV3 or nil
    local teamHealth = teamRoster and type(teamRoster.GetHealth) == "function" and teamRoster:GetHealth() or nil
    AddCheck(report, "combat_team_roster_contract", teamRoster ~= nil and (tonumber(teamRoster.version) or 0) >= 4
            and type(teamRoster.AcquireConsumer) == "function" and type(teamRoster.ReleaseConsumer) == "function"
            and type(teamRoster.GetSnapshot) == "function" and teamRoster.demand ~= nil and teamHealth ~= nil,
        "blocker", teamHealth and ("version=" .. tostring(teamHealth.version or 0)
            .. "/consumer=" .. tostring(teamHealth.consumers or 0)
            .. "/members=" .. tostring(teamHealth.members or 0)
            .. "/subscribed=" .. tostring(teamHealth.subscribed == true)) or "missing")

    local auraObservation = S.Services and S.Services.AuraObservationV3 or nil
    local auraHealth = auraObservation and type(auraObservation.GetHealth) == "function" and auraObservation:GetHealth() or nil
    AddCheck(report, "aura_observation_phase12b_contract", auraObservation ~= nil and (tonumber(auraObservation.version) or 0) >= 2
            and type(auraObservation.AcquireConsumer) == "function" and type(auraObservation.ReleaseConsumer) == "function"
            and type(auraObservation.GetSnapshot) == "function" and type(auraObservation.GetStatusMap) == "function"
            and type(auraObservation.EvaluateRequiredEffects) == "function" and auraObservation.Demand ~= nil and auraHealth ~= nil,
        "blocker", auraHealth and ("version=" .. tostring(auraObservation.version or 0)
            .. "/consumer=" .. tostring(auraHealth.consumers or 0)
            .. "/cache=" .. tostring(auraHealth.cache or 0)
            .. "/native=" .. tostring(auraHealth.nativeReads or 0)) or "missing")

    -- 健康与版本分别由 buff_display_health、buff_display_contract_versions provider 提供。
    local buffDisplayHealth = S.FeatureHealthProviders and S.FeatureHealthProviders:Get("buff_display_health") or nil
    local buffDisplayContracts = S.FeatureHealthProviders and S.FeatureHealthProviders:Get("buff_display_contract_versions") or nil
    local function BuffContract(name)
        return type(buffDisplayContracts) == "table" and (tonumber(buffDisplayContracts[name]) or 0) or 0
    end
    local buffDisplayMeta = S.FeatureRegistry and S.FeatureRegistry:Get("combat_buff_display") or nil
    local buffDisplayStore = S.Persistence and type(S.Persistence.GetStore) == "function" and S.Persistence:GetStore("v3.buff_display") or nil
    local buffDisplayLayoutStore = S.Persistence and type(S.Persistence.GetStore) == "function" and S.Persistence:GetStore("v3.buff_display.layout") or nil
    local buffDisplayPageHost = S.UIV3 and S.UIV3.PageHost or nil
    local buffDisplayWidgetHost = S.UIV3 and S.UIV3.WidgetHost or nil
    local buffDisplayPage = type(buffDisplayPageHost) == "table" and type(buffDisplayPageHost.factories) == "table"
        and buffDisplayPageHost.factories["combat.buff_display"] or nil
    local buffDisplayWidget = type(buffDisplayWidgetHost) == "table" and type(buffDisplayWidgetHost.GetSpec) == "function"
        and buffDisplayWidgetHost:GetSpec("combat.buff_display") or nil
    -- 每次 BuildReport 读取当前已加载 UIV3，避免局部未绑定或跨重载旧引用误报 font=0。
    local buffHeadMarkers = S.UIV3 and S.UIV3.BuffHeadMarkersV3 or nil
    local buffHudCalibration = S.UIV3 and S.UIV3.BuffHudCalibrationV3 or nil
    -- 校准契约需同时覆盖屏幕 Y、标题栏拖动、上下文、全局预览、正式渲染抑制与 Border Measure，防止旧页面保存错误几何。
    -- 装备 x/y 仅作局部微调，模板只读 Draft；目标默认布局仅用于新档/重置，不覆盖已有布局。
    -- 装分读取保持 UnitGearScore(unit, comma=false)，数字经 Utils parser 归一化。Gate 只验版本，不调用 Native。
    AddCheck(report, "buff_display_v3_statusmap_contract", S.FeatureRuntime ~= nil
            and S.FeatureRuntime:IsImplemented("combat_buff_display") == true
            -- 只验 schema8 六通道声明；混入 schema7 或文本 v2 时阻断，不触发扫描或写入。
            and buffDisplayStore ~= nil and tonumber(buffDisplayStore.schemaVersion) == 8
            and tonumber(buffDisplayStore.transportVersion) == 5
            and type(buffDisplayStore.repairPhysicalTransport) == "function"
            -- 布局使用独立小 Store；混入旧 Store 会把校准写回追踪大表。这里只读注册元数据并阻断混装。
            and buffDisplayLayoutStore ~= nil
            and tostring(buffDisplayLayoutStore.owner or "") == "v3.buff_display.layout"
            and tonumber(buffDisplayLayoutStore.schemaVersion) == 1
            and tonumber(buffDisplayLayoutStore.transportVersion) == 3
            -- 小布局 Store 无法修复主 Store 已被 SaveData 省略的 distance.x=-1；恢复仍需 schema8/tv5、单字段省略和整 Store 旧指纹唯一命中。
            -- marker/count 可能被省略，chunks 也可能在 token 边界或十进制 ID 中间截断，只允许严格字节前缀候选，不能作 substring 或近似匹配。
            -- 可解码 twin 仍可能落到错误 scope；先验 twin，再以旧指纹精确匹配 Catalog，最后由 Core 验 Envelope/fingerprint。
            -- 已知事故恢复须由 Store 的 exact-pair hook 处理。这里只验能力版本，不读取或修复 Store；缺版本则阻断。
            and type(S.Data and S.Data.StatusTrackingCatalogV3) == "table"
            and type(buffDisplayStore.rebuildCanonicalForIntegrity) == "function"
            and type(buffDisplayStore.recoverKnownLegacyCanonical) == "function"
            and type(S.Utils) == "table" and (tonumber(S.Utils.GearScoreParseContractVersion) or 0) >= 1
            and type(S.Utils.ParseGearScore) == "function"
            and type(buffHeadMarkers) == "table" and (tonumber(buffHeadMarkers.BuffIconFontSizeContractVersion) or 0) >= 1
            and (tonumber(buffHeadMarkers.GearScoreFormatContractVersion) or 0) >= 1
            and (tonumber(buffHeadMarkers.LiveHudSuppressionContractVersion) or 0) >= 1
            and (tonumber(buffHeadMarkers.EquipmentIndependentOffsetContractVersion) or 0) >= 1
            and (tonumber(buffHeadMarkers.SplitInfoTextLayoutContractVersion) or 0) >= 2
            and (tonumber(buffHeadMarkers.TargetDistanceStableSlotContractVersion) or 0) >= 1
            and (tonumber(buffHeadMarkers.MirroredInfoSlotContractVersion) or 0) >= 1
            and (tonumber(buffHeadMarkers.IndependentHudSlotContractVersion) or 0) >= 1
            and type(buffHeadMarkers.SetCalibrationSuppressed) == "function"
            and type(buffHudCalibration) == "table" and (tonumber(buffHudCalibration.version) or 0) >= 3
            and (tonumber(buffHudCalibration.DiagnosticsContractVersion) or 0) >= 4
            and (tonumber(buffHudCalibration.ScreenCoordinateAdapterContractVersion) or 0) >= 1
            and (tonumber(buffHudCalibration.PanelDragContractVersion) or 0) >= 1
            and (tonumber(buffHudCalibration.ContextualControlsContractVersion) or 0) >= 1
            and (tonumber(buffHudCalibration.GlobalPreviewContractVersion) or 0) >= 1
            and (tonumber(buffHudCalibration.LiveHudSuppressionContractVersion) or 0) >= 1
            and (tonumber(buffHudCalibration.TemplateSnapshotContractVersion) or 0) >= 1
            and (tonumber(buffHudCalibration.SplitInfoTextCalibrationContractVersion) or 0) >= 1
            and (tonumber(buffHudCalibration.IndependentHudSlotPreviewContractVersion) or 0) >= 1
            and type(buffHudCalibration.BuildTemplateSnapshotLines) == "function"
            and type(buffHudCalibration.OutputTemplateSnapshot) == "function"
            and type(buffHudCalibration.ToggleGlobalPreview) == "function"
            and type(buffHudCalibration.Open) == "function" and type(buffHudCalibration.Exit) == "function"
            and type(buffHudCalibration.GetDiagnostics) == "function"
            and type(S.DiagnosticsManager) == "table" and type(S.DiagnosticsManager.BuildBuffHudReport) == "function"
            and buffDisplayPage ~= nil and type(buffDisplayWidget) == "table"
            and buffDisplayMeta ~= nil and tostring(buffDisplayMeta.status) == "migrated_m16_18"
            and tostring(buffDisplayMeta.lifecycle) == "demand_scoped"
            and tostring(buffDisplayMeta.authority):find("v3.buff_display", 1, true) ~= nil,
        "blocker", buffDisplayHealth and ("enabled=" .. tostring(buffDisplayHealth.ok == true)
            .. "/consumer=" .. tostring(buffDisplayHealth.consumers or 0)
            .. "/aura=" .. tostring(buffDisplayHealth.auraHeld == true)
            .. "/task=" .. tostring(buffDisplayHealth.taskActive == true)
            .. "/schema=" .. tostring(buffDisplayStore and buffDisplayStore.schemaVersion or 0)
            .. "/tv=" .. tostring(buffDisplayStore and buffDisplayStore.transportVersion or 0)
            .. "/tv5Recover=" .. tostring(BuffContract("schema8Transport5Recovery"))
            .. "/tv5Prefix=" .. tostring(BuffContract("schema8Transport5ScopedPrefixRecovery"))
            .. "/distXRecover=" .. tostring(BuffContract("schema8Transport5DistanceXOmissionRecovery"))
            .. "/v4Probe=" .. tostring(BuffContract("schema8Transport4RecoveryProbe"))
            .. "/v4Known=" .. tostring(BuffContract("schema8KnownTransport4IncidentRecovery"))
            .. "/hist=" .. tostring(type(buffDisplayStore) == "table" and type(buffDisplayStore.rebuildCanonicalForIntegrity) == "function" and 1 or 0)
            .. "/known=" .. tostring(type(buffDisplayStore) == "table" and type(buffDisplayStore.recoverKnownLegacyCanonical) == "function" and 1 or 0)
            .. "/mig=" .. tostring(BuffContract("schema5DualHudMigration"))
            .. "/targetTpl=" .. tostring(BuffContract("targetDefaultTemplate"))
            .. "/gearApi=" .. tostring(BuffContract("gearScoreApi"))
            .. "/gearParse=" .. tostring(type(S.Utils) == "table" and S.Utils.GearScoreParseContractVersion or 0)
            .. "/layout=" .. tostring(BuffContract("layoutAuthority"))
            .. "/layoutStore=" .. tostring(type(buffDisplayLayoutStore) == "table" and buffDisplayLayoutStore.schemaVersion or 0)
            .. "/layoutBoundary=" .. tostring(BuffContract("layoutPersistenceBoundary"))
            .. "/hud=" .. tostring(BuffContract("hudCalibration"))
            .. "/marker=" .. tostring(BuffContract("buffHeadMarker"))
            .. "/font=" .. tostring(type(buffHeadMarkers) == "table" and buffHeadMarkers.BuffIconFontSizeContractVersion or 0)
            .. "/suppress=" .. tostring(type(buffHeadMarkers) == "table" and buffHeadMarkers.LiveHudSuppressionContractVersion or 0)
            .. "/equipLocal=" .. tostring(type(buffHeadMarkers) == "table" and buffHeadMarkers.EquipmentIndependentOffsetContractVersion or 0)
            .. "/infoSplit=" .. tostring(type(buffHeadMarkers) == "table" and buffHeadMarkers.SplitInfoTextLayoutContractVersion or 0)
            .. "/targetDistanceStable=" .. tostring(type(buffHeadMarkers) == "table" and buffHeadMarkers.TargetDistanceStableSlotContractVersion or 0)
            .. "/independentSlots=" .. tostring(type(buffHeadMarkers) == "table" and buffHeadMarkers.IndependentHudSlotContractVersion or 0)
            .. "/cal=" .. tostring(type(buffHudCalibration) == "table" and buffHudCalibration.version or 0)
            .. "/hudDiag=" .. tostring(buffHudCalibration and buffHudCalibration.DiagnosticsContractVersion or 0)
            .. "/coord=" .. tostring(buffHudCalibration and buffHudCalibration.ScreenCoordinateAdapterContractVersion or 0)
            .. "/panelDrag=" .. tostring(buffHudCalibration and buffHudCalibration.PanelDragContractVersion or 0)
            .. "/context=" .. tostring(buffHudCalibration and buffHudCalibration.ContextualControlsContractVersion or 0)
            .. "/global=" .. tostring(buffHudCalibration and buffHudCalibration.GlobalPreviewContractVersion or 0)
            .. "/liveHide=" .. tostring(buffHudCalibration and buffHudCalibration.LiveHudSuppressionContractVersion or 0)
            .. "/template=" .. tostring(buffHudCalibration and buffHudCalibration.TemplateSnapshotContractVersion or 0)
            .. "/infoCal=" .. tostring(buffHudCalibration and buffHudCalibration.SplitInfoTextCalibrationContractVersion or 0)
            .. "/slotPreview=" .. tostring(buffHudCalibration and buffHudCalibration.IndependentHudSlotPreviewContractVersion or 0)
            .. "/pageMeasure=" .. tostring(BuffContract("hudLayoutPageMeasure"))
            .. "/page=" .. tostring(buffDisplayPage ~= nil and 1 or 0)
            .. "/widget=" .. tostring(type(buffDisplayWidget) == "table" and 1 or 0)
            .. "/meta=" .. tostring(buffDisplayMeta ~= nil and 1 or 0)) or "missing")
    -- 运行状态取 Feature 的 health 投影。taskActive 当前不在 GetHealth 返回值中，不能据此推断任务正常。
    AddCheck(report, "buff_display_v3_runtime_scope", buffDisplayHealth ~= nil
            and (((tonumber(buffDisplayHealth.consumers) or 0) > 0
                    and buffDisplayHealth.auraHeld == true and buffDisplayHealth.taskActive == true)
                or ((tonumber(buffDisplayHealth.consumers) or 0) <= 0
                    and buffDisplayHealth.auraHeld ~= true and buffDisplayHealth.taskActive ~= true)),
        "warning", buffDisplayHealth and ("enabled=" .. tostring(buffDisplayHealth.ok == true)
            .. "/consumer=" .. tostring(buffDisplayHealth.consumers or 0)
            .. "/aura=" .. tostring(buffDisplayHealth.auraHeld == true)
            .. "/task=" .. tostring(buffDisplayHealth.taskActive == true)) or "missing")

    -- 团队就绪和治疗 Aura 分别由 raid_readiness、healer 的 acceptance 检查；健康状态由 Feature 注册 provider。
    -- 实现缺失或 sequence 失败必须阻断，共享服务版本、Store、Native 宿主和休眠租约仍由各自 case 校验。
    local healerHealth = S.FeatureHealthProviders and S.FeatureHealthProviders:Get("healer_health") or nil
    -- 运行期健康子表仍由上面的 health 投影派生 —— 删掉它会让下面 detail 的 task 观测永远退化成 false。
    local healerRuntimeHealth = healerHealth and healerHealth.runtime or nil
    local healerMeta = S.FeatureRegistry and S.FeatureRegistry:Get("combat_healer") or nil
    local healerStore = S.Persistence and type(S.Persistence.GetStore) == "function" and S.Persistence:GetStore("v3.healer") or nil
    AddCheck(report, "healer_v3_domain_runtime", S.FeatureRuntime ~= nil
            and S.FeatureRuntime:IsImplemented("combat_healer") == true
            and healerStore ~= nil
            and healerMeta ~= nil and tostring(healerMeta.status) == "migrated_m16_18"
            and tostring(healerMeta.lifecycle) == "independent"
            and tostring(healerMeta.authority):find("v3.healer", 1, true) ~= nil,
        "blocker", healerHealth and ("enabled=" .. tostring(healerHealth.enabled == true)
            .. "/consumer=" .. tostring(healerHealth.consumers or 0)
            .. "/roster=" .. tostring(healerHealth.rosterHeld == true)
            .. "/aura=" .. tostring(healerHealth.auraHeld == true)
            .. "/task=" .. tostring(healerRuntimeHealth and healerRuntimeHealth.taskActive == true or false)) or "missing")
    local healerPageHost = S.UIV3 and S.UIV3.PageHost or nil
    local healerWidgetHost = S.UIV3 and S.UIV3.WidgetHost or nil
    local healerPageRegistered = type(healerPageHost) == "table" and type(healerPageHost.factories) == "table"
        and type(healerPageHost.factories["combat.healer"]) == "function"
    local healerWidgetSpec = type(healerWidgetHost) == "table" and type(healerWidgetHost.specs) == "table"
        and healerWidgetHost.specs["combat.healer"] or nil
    AddCheck(report, "healer_v3_presentation", healerPageRegistered == true and healerWidgetSpec == nil
            and healerStore ~= nil and tonumber(healerStore.schemaVersion) == 6,
        "blocker", "page=" .. tostring(healerPageRegistered == true)
            .. "/recommendationWidgetRemoved=" .. tostring(healerWidgetSpec == nil)
            .. "/store=" .. tostring(healerStore and healerStore.schemaVersion or "missing"))
    local healerHead = S.UIV3 and S.UIV3.HealerHeadMarker or nil
    local healerRaid = S.UIV3 and S.UIV3.HealerRaidOverlay or nil
    local healerPresentation = S.FeatureHealthProviders and S.FeatureHealthProviders:Get("healer_presentation") or nil
    local healerScreenCapable = S.FeatureHealthProviders and S.FeatureHealthProviders:Get("healer_screen_capable")
    AddCheck(report, "healer_v3_visual_consumers", type(healerHead) == "table" and type(healerHead.Describe) == "function"
            and type(healerRaid) == "table" and (tonumber(healerRaid.version) or 0) >= 3 and type(healerRaid.Describe) == "function"
            and (tonumber(healerRaid.NativeRosterGeometryContractVersion) or 0) >= 2
            and (tonumber(healerRaid.StackedHalfRosterContractVersion) or 0) >= 1
            and (tonumber(healerRaid.ColumnMajorSlotContractVersion) or 0) >= 1,
        "blocker", "head=" .. tostring(type(healerHead) == "table")
            .. "/raid=" .. tostring(type(healerRaid) == "table")
            .. "/screen=" .. tostring(healerScreenCapable == true))
    local headHealth = type(healerHead) == "table" and healerHead:Describe() or nil
    local raidHealth = type(healerRaid) == "table" and healerRaid:Describe() or nil
    local headSettings = type(healerPresentation) == "table" and healerPresentation.head or nil
    local raidSettings = type(healerPresentation) == "table" and healerPresentation.raid or nil
    local healerRuntimeEnabled = healerHealth and healerHealth.enabled == true
    local headExpected = healerRuntimeEnabled and headSettings and headSettings.enabled == true
    local raidCalibrationExpected = raidSettings and raidSettings.calibration == true
    local raidLiveExpected = raidCalibrationExpected ~= true and healerRuntimeEnabled and raidSettings and raidSettings.enabled == true
    local raidExpected = raidCalibrationExpected == true or raidLiveExpected == true
    local headLifecycleOk = type(headHealth) ~= "table"
        or (headExpected and headHealth.running == true and headHealth.consumerHeld == true and headHealth.taskActive == true)
        or (not headExpected and headHealth.running ~= true and headHealth.consumerHeld ~= true and headHealth.taskActive ~= true)
    local raidTaskExpected = raidLiveExpected and tonumber(raidSettings.effectMode) ~= 1
    local raidLifecycleOk = type(raidHealth) ~= "table"
        or (raidCalibrationExpected and raidHealth.running == true and raidHealth.calibrationMode == true
            and raidHealth.consumerHeld ~= true and raidHealth.taskActive ~= true)
        or (raidLiveExpected and raidHealth.running == true and raidHealth.calibrationMode ~= true and raidHealth.consumerHeld == true
            and ((raidTaskExpected and raidHealth.taskActive == true) or (not raidTaskExpected and raidHealth.taskActive ~= true)))
        or (not raidExpected and raidHealth.running ~= true and raidHealth.consumerHeld ~= true and raidHealth.taskActive ~= true)
    AddCheck(report, "healer_v3_visual_lifecycle", headLifecycleOk and raidLifecycleOk,
        "warning", "head=" .. tostring(headHealth and headHealth.running == true or false)
            .. "/raid=" .. tostring(raidHealth and raidHealth.running == true or false)
            .. "/raid_task=" .. tostring(raidHealth and raidHealth.taskActive == true or false))

    local combatRelation = S.Services and S.Services.CombatRelationV3 or nil
    local relationHealth = combatRelation and type(combatRelation.GetHealth) == "function" and combatRelation:GetHealth() or nil
    AddCheck(report, "combat_relation_contract", combatRelation ~= nil and (tonumber(combatRelation.version) or 0) >= 4
            and type(combatRelation.AcquireConsumer) == "function" and type(combatRelation.ReleaseConsumer) == "function"
            -- v4 关系查询携带时间戳；ResolveName 属于已放弃的中间契约，不是当前 CombatRelationV3 的接口。
            and type(combatRelation.GetRelationAt) == "function" and combatRelation.demand ~= nil and relationHealth ~= nil,
        "blocker", relationHealth and ("version=" .. tostring(relationHealth.version or 0)
            .. "/consumer=" .. tostring(relationHealth.consumers or 0)
            .. "/units=" .. tostring(relationHealth.units or 0)
            .. "/rosterHeld=" .. tostring(relationHealth.rosterHeld == true)) or "missing")

    -- 死亡复盘的存档、窗口、预算及零值省略恢复由 features/combat/death_review/rs_death_review_acceptance.lua 检查。
    -- DPS 的版本和命令由 features/combat/dps/rs_dps_acceptance.lua 检查，健康状态经 provider 读取。
    -- 实现缺失或 sequence 失败均须阻断。
    local dpsMeta = S.FeatureRegistry and S.FeatureRegistry:Get("combat_stats") or nil
    local dpsPage = S.UIV3 and S.UIV3.PageHost and S.UIV3.PageHost.factories and S.UIV3.PageHost.factories["combat.stats"] or nil
    local dpsWidget = S.UIV3 and S.UIV3.WidgetHost and type(S.UIV3.WidgetHost.GetSpec) == "function" and S.UIV3.WidgetHost:GetSpec("combat.dps") or nil
    local dpsStore = S.Persistence and type(S.Persistence.GetStore) == "function" and S.Persistence:GetStore("v3.dps") or nil
    local dpsHealth = S.FeatureHealthProviders and S.FeatureHealthProviders:Get("dps_health") or nil
    local dpsRuntime = S.FeatureHealthProviders and S.FeatureHealthProviders:Get("dps_runtime_snapshot") or nil
    AddCheck(report, "dps_v3_contract", dpsStore ~= nil and dpsPage ~= nil and dpsWidget ~= nil
            and dpsMeta ~= nil and tostring(dpsMeta.status) == "migrated_m16"
            and tostring(dpsMeta.authority):find("v3.dps", 1, true) ~= nil
            and S.Services ~= nil and type(S.Services.CombatRelationV3) == "table"
            and type(S.Services.CombatAnalyticsV3) == "table",
        "blocker", dpsHealth and ("enabled=" .. tostring(dpsRuntime and dpsRuntime.enabled == true)
            .. "/consumer=" .. tostring(dpsHealth.consumers or 0)
            .. "/scope=" .. tostring(dpsHealth.busScope or "none")
            .. "/pvp=" .. tostring(dpsHealth.classificationPVP or 0)
            .. "/pve=" .. tostring(dpsHealth.classificationPVE or 0)
            .. "/pending=" .. tostring(dpsHealth.pendingRows or 0)) or "missing")
    local proxyCatalog = S.Data and S.Data.CombatSourceProxyCatalog or nil
    local fountainProxy = type(proxyCatalog) == "table" and type(proxyCatalog.Get) == "function" and proxyCatalog:Get("healing_fountain") or nil
    AddCheck(report, "dps_skill_proxy_source_contract", type(proxyCatalog) == "table" and (tonumber(proxyCatalog.version) or 0) >= 1
            and type(proxyCatalog.ResolveSource) == "function" and type(proxyCatalog.ResolveAbility) == "function"
            and type(fountainProxy) == "table" and tostring(fountainProxy.kind) == "PLAYER_PLACED_SKILL_PROXY"
            and tostring(fountainProxy.ownerAttribution) == "UNAVAILABLE_NO_RELIABLE_OWNER_LINK"
            and tonumber(fountainProxy.durationMs) == 60000 and dpsHealth ~= nil
            and dpsHealth.proxySourceHeals ~= nil and dpsHealth.proxySourceHealAmount ~= nil,
        "blocker", "catalog=" .. tostring(proxyCatalog and proxyCatalog.version or 0)
            .. "/domain=" .. tostring(dpsRuntime and dpsRuntime.domainVersion or 0)
            .. "/proxyEvents=" .. tostring(dpsHealth and dpsHealth.proxySourceHeals or 0)
            .. "/proxyHeal=" .. tostring(dpsHealth and dpsHealth.proxySourceHealAmount or 0))

    AddCheck(report, "dps_v3_runtime_scope", dpsHealth ~= nil
            and (dpsRuntime ~= nil and dpsRuntime.enabled ~= true or (dpsHealth.analyticsHeld == true and (tostring(dpsHealth.busScope) == "self" or tostring(dpsHealth.busScope) == "all")))
            and type(dpsRuntime) == "table" and dpsRuntime.busSubscribed ~= true
            and (dpsRuntime ~= nil and dpsRuntime.enabled == true or (tonumber(dpsHealth.consumers) or 0) == 0),
        "warning", dpsHealth and ("enabled=" .. tostring(dpsRuntime ~= nil and dpsRuntime.enabled == true)
            .. "/analytics=" .. tostring(dpsHealth.analyticsHeld == true)
            .. "/directBus=" .. tostring(dpsRuntime and dpsRuntime.busSubscribed == true)
            .. "/scope=" .. tostring(dpsHealth.busScope or "none")
            .. "/pvp=" .. tostring(dpsHealth.classificationPVP or 0)
            .. "/pve=" .. tostring(dpsHealth.classificationPVE or 0)
            .. "/unknown=" .. tostring(dpsHealth.classificationUnknown or 0)
            .. "/pending=" .. tostring(dpsHealth.pendingRows or 0)) or "missing")

    local gameValidation = S.GameDataRegistry and type(S.GameDataRegistry.Validate) == "function" and S.GameDataRegistry:Validate() or nil
    AddCheck(report, "game_identity_registry", gameValidation ~= nil and gameValidation.ok == true
            and gameValidation.sealed == true and (tonumber(gameValidation.sealViolations) or 0) == 0
            and gameValidation.mutationDetected ~= true,
        "blocker", gameValidation and ("records=" .. tostring(gameValidation.totalRecords or 0)
            .. "/sets=" .. tostring(gameValidation.totalSets or 0)
            .. "/sealed=" .. tostring(gameValidation.sealed == true)
            .. "/sealViol=" .. tostring(gameValidation.sealViolations or 0)
            .. "/mut=" .. tostring(gameValidation.mutationDetected == true)
            .. "/warn=" .. tostring(gameValidation.warnings or 0)) or "missing")

    local zoneCatalog = S.StaticDataV2 and S.StaticDataV2:GetCatalog("zone") or nil
    local zoneIds = S.GameIds and S.GameIds.Zone or nil
    local zoneCount = zoneCatalog and #(zoneCatalog.order or {}) or 0
    AddCheck(report, "zone_identity_catalog", zoneCount >= 34 and type(zoneIds) == "table" and type(zoneIds.ById) == "table",
        "blocker", "zones=" .. tostring(zoneCount) .. "/shared=" .. tostring(type(zoneIds) == "table"))

    AddCheck(report, "static_data_api", S.StaticDataV2 ~= nil
            and type(S.StaticDataV2.Get) == "function" and type(S.StaticDataV2.FindById) == "function"
            and type(S.StaticDataV2.List) == "function" and type(S.StaticDataV2.GetCount) == "function",
        "blocker", "indexed read API")

    local staticValidation = S.StaticDataV2 and S.StaticDataV2:Validate() or nil
    AddCheck(report, "static_data_v2", staticValidation ~= nil and staticValidation.ok == true
            and staticValidation.sealed == true and (tonumber(staticValidation.sealViolations) or 0) == 0
            and staticValidation.mutationDetected ~= true
            and (tonumber(staticValidation.records) or 0) > 0,
        "blocker", staticValidation and ("catalogs=" .. tostring(staticValidation.catalogs or 0)
            .. "/records=" .. tostring(staticValidation.records or 0)
            .. "/refs=" .. tostring(staticValidation.references or 0)
            .. "/missing=" .. tostring(staticValidation.missingRefs or 0)
            .. "/missingId=" .. tostring(staticValidation.missingRequiredIds or 0)
            .. "/sealed=" .. tostring(staticValidation.sealed == true)
            .. "/sealViol=" .. tostring(staticValidation.sealViolations or 0)
            .. "/mut=" .. tostring(staticValidation.mutationDetected == true)) or "missing")

    local tradeStatic = S.Data and S.Data.TradeStaticV2 and type(S.Data.TradeStaticV2.Describe) == "function" and S.Data.TradeStaticV2:Describe() or nil
    local tradeReady = tradeStatic ~= nil
        and (tonumber(tradeStatic.materials) or 0) > 0
        and (tonumber(tradeStatic.goods) or 0) > 0
        and (tonumber(tradeStatic.recipes) or 0) > 0
    AddCheck(report, "trade_static_catalog", tradeReady, "blocker", tradeStatic and
        ("materials=" .. tostring(tradeStatic.materials or 0) .. "/goods=" .. tostring(tradeStatic.goods or 0) .. "/recipes=" .. tostring(tradeStatic.recipes or 0)) or "missing")
    if tradeReady then
        AddCheck(report, "trade_origin_zone_links", (tonumber(tradeStatic.pendingOriginZones) or 0) == 0, "blocker",
            "pending=" .. tostring(tradeStatic.pendingOriginZones or 0))
        AddCheck(report, "trade_craft_ids",
            (tonumber(tradeStatic.recipes) or 0) >= 98
                and (tonumber(tradeStatic.primaryCraftIds) or 0) == (tonumber(tradeStatic.recipes) or 0)
                and (tonumber(tradeStatic.missingCraftIds) or 0) == 0,
            "blocker", "primary=" .. tostring(tradeStatic.primaryCraftIds or 0) .. "/" .. tostring(tradeStatic.recipes or 0)
                .. "/refs=" .. tostring(tradeStatic.totalRecipeCraftIds or 0)
                .. "/alt=" .. tostring(tradeStatic.alternateRecipeCraftIds or 0))
        AddCheck(report, "trade_recipe_signatures",
            (tonumber(tradeStatic.verifiedIngredientSignatures) or 0) == (tonumber(tradeStatic.recipes) or 0)
                and (tonumber(tradeStatic.recipes) or 0) >= 98
                and (tonumber(tradeStatic.ingredientSignatureFailures) or 0) == 0,
            "blocker", "verified=" .. tostring(tradeStatic.verifiedIngredientSignatures or 0)
                .. "/fail=" .. tostring(tradeStatic.ingredientSignatureFailures or 0))
        -- R4 为当前 98 个配方提供权威 Product ItemID。覆盖或重复回归须阻断，避免已审计产品在运行时退回歧义名称。
        AddCheck(report, "trade_product_ids",
            (tonumber(tradeStatic.pendingProductIds) or 0) == 0
                and (tonumber(tradeStatic.productIdDuplicates) or 0) == 0,
            "blocker", "verified=" .. tostring(tradeStatic.verifiedProductIds or 0)
                .. "/pending=" .. tostring(tradeStatic.pendingProductIds or 0)
                .. "/duplicates=" .. tostring(tradeStatic.productIdDuplicates or 0))
    end
    report.tradeStatic = tradeStatic

    local questIds = S.GameIds and S.GameIds.Quest and type(S.GameIds.Quest.Describe) == "function" and S.GameIds.Quest:Describe() or nil
    AddCheck(report, "quest_id_verification",
        questIds ~= nil
            and (tonumber(questIds.total) or 0) >= 214
            and (tonumber(questIds.verified) or 0) == (tonumber(questIds.total) or 0)
            and (tonumber(questIds.pending) or 0) == 0,
        "warning",
        questIds and ("verified=" .. tostring(questIds.verified or 0) .. "/pending=" .. tostring(questIds.pending or 0) .. "/total=" .. tostring(questIds.total or 0)) or "missing")
    report.questIds = questIds

    local instanceIds = S.GameIds and S.GameIds.Instance and type(S.GameIds.Instance.Describe) == "function" and S.GameIds.Instance:Describe() or nil
    AddCheck(report, "instance_database_zone_ids", instanceIds ~= nil and (tonumber(instanceIds.databaseVerified) or 0) >= 19, "blocker",
        instanceIds and ("db=" .. tostring(instanceIds.databaseVerified or 0) .. "/runtime=" .. tostring(instanceIds.runtimeVerified or 0)
            .. "/pending=" .. tostring(instanceIds.runtimePending or 0)) or "missing")
    AddCheck(report, "instance_runtime_observation_conflicts",
        instanceIds ~= nil and (tonumber(instanceIds.runtimeObservedConflicts) or 0) == 0,
        "warning", instanceIds and ("observed=" .. tostring(instanceIds.runtimeObserved or 0)
            .. "/conflicts=" .. tostring(instanceIds.runtimeObservedConflicts or 0)) or "missing")
    report.instanceIds = instanceIds

    local persistence = S.Persistence and S.Persistence:Describe() or nil
    local persistenceStats = persistence and persistence.stats or {}
    AddCheck(report, "persistence_v3_contract_api",
        S.Persistence ~= nil and type(S.Persistence.RegisterV3Store) == "function"
            and type(S.Persistence.InspectPayload) == "function"
            and type(S.Persistence.ClearStore) == "function"
            and type(S.Persistence.CanWrite) == "function" and type(S.Persistence.PrepareWrite) == "function"
            and type(S.Persistence.MutateStore) == "function"
            and type(S.Persistence.IsStoreLoaded) == "function"
            and type(S.Persistence.VerifyPersistedValue) == "function"
            and type(S.Persistence.FingerprintEncodedPayload) == "function"
            and type(S.Persistence.FingerprintEnvelopeIntegrity) == "function"
            and type(S.Persistence.EncodePhysicalEnvelope) == "function" and type(S.Persistence.DecodePhysicalEnvelope) == "function"
            and type(S.Persistence.RebuildFramework2SerializerOmissions) == "function"
            and (tonumber(S.Persistence.FrameworkVersion) or 0) >= 3
            and (tonumber(S.Persistence.TransportContractVersion) or 0) >= 2 -- 新写使用 Transport v2，保护 false、空表、0 和空字符串；v1 仅保留加载兼容。
            -- 回读指纹不符时须报告首个字段差异及状态机轨迹；差异比较只在失败路径执行。
            and (tonumber(S.Persistence.ReadbackDivergenceDiagnosticsContractVersion) or 0) >= 1 and type(S.Persistence.DescribeCanonicalDivergence) == "function"
            and (tonumber(S.Persistence.IntegrityRecoveryTraceContractVersion) or 0) >= 1
            and (tonumber(S.Persistence.ReliabilityContractVersion) or 0) >= 6
            and (tonumber(S.Persistence.IntegrityContractVersion) or 0) >= 1
            and (tonumber(S.Persistence.EnvelopeIntegrityContractVersion) or 0) >= 1
            and (tonumber(S.Persistence.ScopeBindingContractVersion) or 0) >= 1
            and (tonumber(S.Persistence.RuntimeAcceptanceDiagnosticsContractVersion) or 0) >= 1
            and type(S.Persistence.V3KeyPrefix) == "string",
        "blocker", "v3 owner/scope/domain+envelope budgets + Framework3 physical transport + exact Framework2 serializer-omission recovery + transactional load-before-write + post-write verify + persisted cross-reload integrity + runtime acceptance diagnostics")
    local featurePreferenceStore = S.Persistence ~= nil and type(S.Persistence.GetStore) == "function"
        and S.Persistence:GetStore("v3.features") or nil
    -- 功能开关是动态 key map，default={} 不能用 Core 的固定形状恢复。
    -- 只验 Store 已挂接精确指纹恢复 hook，不加载 Store。
    AddCheck(report, "feature_preference_persistence_recovery_contract",
        type(featurePreferenceStore) == "table"
            and type(featurePreferenceStore.rebuildCanonicalForIntegrity) == "function",
        "blocker", type(featurePreferenceStore) == "table" and "framework2 dynamic-false exact recovery registered" or "v3.features store missing")
    local payloadSafe, payloadCycleRejected = false, false
    if S.Persistence ~= nil and type(S.Persistence.InspectPayload) == "function" then
        local safe = S.Persistence:InspectPayload({ probe = true, nested = { value = 1 } })
        local cycle = {}; cycle.self = cycle
        local rejected = S.Persistence:InspectPayload(cycle)
        payloadSafe = type(safe) == "table" and safe.ok == true
        payloadCycleRejected = type(rejected) == "table" and rejected.ok == false and rejected.reason == "cyclic_table"
    end
    AddCheck(report, "persistence_preflight", payloadSafe and payloadCycleRejected, "blocker",
        "safe=" .. tostring(payloadSafe) .. "/cycleReject=" .. tostring(payloadCycleRejected))

    AddCheck(report, "persistence_v2", persistence ~= nil
            and (tonumber(persistence.fenced) or 0) == 0
            and (tonumber(persistence.legacyContracts) or 0) == 0
            and (tonumber(persistence.budgetProtected) or 0) == (tonumber(persistence.total) or 0)
            and (tonumber(persistence.envelopeBudgetProtected) or 0) == (tonumber(persistence.total) or 0)
            and (tonumber(persistence.registrationBudgetFailed) or 0) == 0
            and (tonumber(persistenceStats.metadataMismatches) or 0) == 0
            and (tonumber(persistenceStats.keyCollisions) or 0) == 0,
        "blocker", persistence and ("stores=" .. tostring(persistence.total or 0)
            .. "/v2=" .. tostring(persistence.contractV2 or 0)
            .. "/budget=" .. tostring(persistence.budgetProtected or 0)
            .. "/envelope=" .. tostring(persistence.envelopeBudgetProtected or 0)
            .. "/registrationBudgetFail=" .. tostring(persistence.registrationBudgetFailed or 0)
            .. "/legacy=" .. tostring(persistence.legacyContracts or 0)
            .. "/fenced=" .. tostring(persistence.fenced or 0)
            .. "/reject=" .. tostring(persistenceStats.payloadRejected or 0)
            .. "/encoded=" .. tostring(persistenceStats.encodedPayloadRejected or 0)
            .. "/keyCollision=" .. tostring(persistenceStats.keyCollisions or 0)
            .. "/meta=" .. tostring(persistenceStats.metadataMismatches or 0)) or "missing")


    AddCheck(report, "persistence_reliability_v3", persistence ~= nil
            and (tonumber(persistence.reliabilityContractVersion) or 0) >= 3
            and type(S.Persistence.MutateStore) == "function"
            and type(S.Persistence.VerifyPersistedValue) == "function"
            and (tonumber(persistence.unloadedDirty) or 0) == 0,
        "blocker", persistence and ("contract=" .. tostring(persistence.reliabilityContractVersion or 0)
            .. "/dirty=" .. tostring(persistence.dirty or 0)
            .. "/unloadedDirty=" .. tostring(persistence.unloadedDirty or 0)
            .. "/writeBeforeLoadReject=" .. tostring(persistenceStats.unloadedWriteRejects or 0)
            .. "/dirtyReloadReject=" .. tostring(persistenceStats.dirtyReloadRejects or 0)
            .. "/flushFail=" .. tostring(persistenceStats.flushFailures or 0)
            .. "/verify=" .. tostring(persistenceStats.readbackVerifySuccesses or 0) .. "/" .. tostring(persistenceStats.readbackVerifyAttempts or 0)
            .. "/verifyFail=" .. tostring(persistenceStats.readbackVerifyFailures or 0)
            .. "/retry=" .. tostring(persistenceStats.retryQueued or 0)) or "missing")

    AddCheck(report, "persistence_reliability_v4", persistence ~= nil
            and (tonumber(persistence.reliabilityContractVersion) or 0) >= 4
            and (tonumber(persistence.integrityContractVersion) or 0) >= 1
            and (tonumber(persistence.historicalCanonicalRecoveryContractVersion) or 0) >= 3
            and (tonumber(persistence.knownLegacyCanonicalRecoveryContractVersion) or 0) >= 1
            and (tonumber(persistenceStats.integrityLoadFailures) or 0) == 0
            and (tonumber(persistenceStats.encodedLoadRejects) or 0) == 0,
        "blocker", persistence and ("contract=" .. tostring(persistence.reliabilityContractVersion or 0)
            .. "/integrity=" .. tostring(persistence.integrityContractVersion or 0)
            .. "/historicalCanonical=" .. tostring(persistence.historicalCanonicalRecoveryContractVersion or 0)
            .. "/knownLegacy=" .. tostring(persistence.knownLegacyCanonicalRecoveryContractVersion or 0)
            .. "/knownRecover=" .. tostring(persistenceStats.knownLegacyCanonicalRecoveries or 0)
            .. "/knownReject=" .. tostring(persistenceStats.knownLegacyCanonicalRecoveryRejects or 0)
            .. "/stamped=" .. tostring(persistenceStats.integrityStampedSaves or 0)
            .. "/loadCheck=" .. tostring(persistenceStats.integrityLoadChecks or 0)
            .. "/legacy=" .. tostring(persistenceStats.integrityLegacyLoads or 0)
            .. "/integrityFail=" .. tostring(persistenceStats.integrityLoadFailures or 0)
            .. "/v1Compat=" .. tostring(persistenceStats.integrityCompatibilityLoads or 0)
            .. "/v1Resave=" .. tostring(persistenceStats.integrityCompatibilityResaves or 0)
            .. "/shapeRepair=" .. tostring(persistenceStats.integritySerializerRepairLoads or 0)
            .. "/shapeRepairFail=" .. tostring(persistenceStats.integritySerializerRepairFailures or 0)
            .. "/shapeResave=" .. tostring(persistenceStats.integritySerializerRepairResaves or 0)
            .. "/v3Upgrade=" .. tostring(persistenceStats.integrityUpgradeRecoveries or 0)
            .. "/" .. tostring(persistenceStats.integrityUpgradeResaves or 0)
            .. "/v3UpgradeFail=" .. tostring(persistenceStats.integrityUpgradeValidationFailures or 0)
            .. "/barrierFail=" .. tostring(persistenceStats.barrierVerifyFailures or 0)
            .. "/clearVerifyFail=" .. tostring(persistenceStats.clearVerifyFailures or 0)
            .. "/encodedLoadReject=" .. tostring(persistenceStats.encodedLoadRejects or 0)
            .. "/replacementRecover=" .. tostring(persistenceStats.verifiedReplacementRecoveries or 0)) or "missing")

    -- schema-6 扩展曾导致旧 stamp 失配；外壳现要求 schema7、精确历史重建和已知 stamp 白名单桥。
    -- 不能原地改变 canonical 代际，也不能放行所有指纹不符的值。
    local shellStore = S.Persistence and type(S.Persistence.GetStore) == "function" and S.Persistence:GetStore("v3.shell") or nil
    local shellUi = S.UIV3
    AddCheck(report, "v3_shell_persistence_schema_contract",
        type(shellStore) == "table"
            and tonumber(shellStore.schemaVersion) == 7
            and tonumber(shellStore.legacySchemaVersion) == 6
            and type(shellStore.rebuildCanonicalForIntegrity) == "function"
            and type(shellStore.recoverKnownLegacyCanonical) == "function"
            and type(shellUi) == "table"
            and (tonumber(shellUi.ShellCanonicalMigrationContractVersion) or 0) >= 1
            and (tonumber(shellUi.ShellKnownLegacyRecoveryContractVersion) or 0) >= 1
            and (tonumber(shellUi.ShellStoreSchemaContractVersion) or 0) >= 7,
        "blocker", "schema=" .. tostring(shellStore and shellStore.schemaVersion or 0)
            .. "/legacy=" .. tostring(shellStore and shellStore.legacySchemaVersion or 0)
            .. "/historical=" .. tostring(type(shellStore) == "table" and type(shellStore.rebuildCanonicalForIntegrity) == "function")
            .. "/known=" .. tostring(type(shellStore) == "table" and type(shellStore.recoverKnownLegacyCanonical) == "function")
            .. "/contract=" .. tostring(shellUi and shellUi.ShellCanonicalMigrationContractVersion or 0)
            .. "/knownContract=" .. tostring(shellUi and shellUi.ShellKnownLegacyRecoveryContractVersion or 0))

    AddCheck(report, "persistence_reliability_v5", persistence ~= nil
            and (tonumber(persistence.reliabilityContractVersion) or 0) >= 5
            and (tonumber(S.Persistence.MinIntegrityReliabilityContractVersion) or 0) <= 4
            and type(S.Persistence.Flush) == "function"
            and (tonumber(persistenceStats.barrierVerifyFailures) or 0) == 0
            and (tonumber(persistenceStats.clearVerifyFailures) or 0) == 0,
        "blocker", persistence and ("contract=" .. tostring(persistence.reliabilityContractVersion or 0)
            .. "/compatFloor=" .. tostring(S.Persistence.MinIntegrityReliabilityContractVersion or 0)
            .. "/pending=" .. tostring(persistence.barrierPending or 0)
            .. "/barrier=" .. tostring(persistenceStats.barrierVerifySuccesses or 0) .. "/" .. tostring(persistenceStats.barrierVerifyAttempts or 0)
            .. "/barrierFail=" .. tostring(persistenceStats.barrierVerifyFailures or 0)
            .. "/requeue=" .. tostring(persistenceStats.barrierVerifyRequeued or 0)
            .. "/clearVerify=" .. tostring(persistenceStats.clearVerifyAttempts or 0)
            .. "/clearVerifyFail=" .. tostring(persistenceStats.clearVerifyFailures or 0)) or "missing")

    local persistenceV6Ok, persistenceV6Detail = self:EvaluatePersistenceReliabilityV6(persistence)
    AddCheck(report, "persistence_reliability_v6", persistenceV6Ok, "blocker", persistenceV6Detail)

    AddCheck(report, "persistence_reliability_v7", persistence ~= nil
            and (tonumber(persistence.reliabilityContractVersion) or 0) >= 7
            and (tonumber(persistenceStats.unverifiedReloadRejects) or 0) == 0,
        "blocker", persistence and ("contract=" .. tostring(persistence.reliabilityContractVersion or 0)
            .. "/unverifiedReloadReject=" .. tostring(persistenceStats.unverifiedReloadRejects or 0)
            .. "/deferredResave=" .. tostring(persistenceStats.deferredLoadResaves or 0)
            .. "/terminalRetrySuppress=" .. tostring(persistenceStats.terminalAutoRetrySuppressions or 0)) or "missing")

    AddCheck(report, "persistence_reliability_v8", persistence ~= nil
            and (tonumber(persistence.reliabilityContractVersion) or 0) >= 8
            and (tonumber(persistence.integrityContractVersion) or 0) >= 2
            and (tonumber(persistence.serializerNumericFingerprintContractVersion) or 0) >= 1
            and type(S.Persistence.FingerprintDurablePayload) == "function"
            and type(S.Persistence.FingerprintEncodedPayloadV1) == "function"
            and type(S.Persistence.CanonicalIntegrityValue) == "function"
            and type(S.Persistence.FingerprintCanonicalValue) == "function"
            and (tonumber(S.Persistence.TerminalLoadMemoizationContractVersion) or 0) >= 1,
        "blocker", persistence and ("contract=" .. tostring(persistence.reliabilityContractVersion or 0)
            .. "/integrity=" .. tostring(persistence.integrityContractVersion or 0)
            .. "/numeric=" .. tostring(persistence.serializerNumericFingerprintContractVersion or 0)
            .. "/v1Compat=" .. tostring(persistenceStats.integrityCompatibilityLoads or 0)
            .. "/v1Resave=" .. tostring(persistenceStats.integrityCompatibilityResaves or 0)
            .. "/shapeRepair=" .. tostring(persistenceStats.integritySerializerRepairLoads or 0)
            .. "/shapeRepairFail=" .. tostring(persistenceStats.integritySerializerRepairFailures or 0)
            .. "/shapeResave=" .. tostring(persistenceStats.integritySerializerRepairResaves or 0)
            .. "/v3Upgrade=" .. tostring(persistenceStats.integrityUpgradeRecoveries or 0)
            .. "/" .. tostring(persistenceStats.integrityUpgradeResaves or 0)
            .. "/terminalMemo=" .. tostring(persistenceStats.terminalLoadShortCircuits or 0)) or "missing")

    AddCheck(report, "persistence_reliability_incidents",
        (tonumber(persistenceStats.flushFailures) or 0) == 0
            and (tonumber(persistenceStats.corruptEmptyRejects) or 0) == 0
            and (tonumber(persistenceStats.readbackVerifyFailures) or 0) == 0
            and (tonumber(persistenceStats.integrityLoadFailures) or 0) == 0
            and (tonumber(persistenceStats.encodedLoadRejects) or 0) == 0
            and (tonumber(persistenceStats.barrierVerifyFailures) or 0) == 0
            and (tonumber(persistenceStats.clearVerifyFailures) or 0) == 0
            and (tonumber(persistenceStats.envelopeIntegrityLoadFailures) or 0) == 0
            and (tonumber(persistenceStats.decodedLoadRejects) or 0) == 0
            and (tonumber(persistenceStats.durableVerifyFailures) or 0) == 0
            and (tonumber(persistenceStats.scopeBindingMismatches) or 0) == 0
            and (tonumber(persistenceStats.unverifiedReloadRejects) or 0) == 0,
        "warning", "flushFail=" .. tostring(persistenceStats.flushFailures or 0)
            .. "/payloadReject=" .. tostring(persistenceStats.payloadRejected or 0)
            .. "/encodedReject=" .. tostring(persistenceStats.encodedPayloadRejected or 0)
            .. "/corruptReject=" .. tostring(persistenceStats.corruptEmptyRejects or 0)
            .. "/writeBeforeLoadReject=" .. tostring(persistenceStats.unloadedWriteRejects or 0)
            .. "/dirtyReloadReject=" .. tostring(persistenceStats.dirtyReloadRejects or 0)
            .. "/readbackVerifyFail=" .. tostring(persistenceStats.readbackVerifyFailures or 0)
            .. "/integrityFail=" .. tostring(persistenceStats.integrityLoadFailures or 0)
            .. "/v1Compat=" .. tostring(persistenceStats.integrityCompatibilityLoads or 0)
            .. "/v1Resave=" .. tostring(persistenceStats.integrityCompatibilityResaves or 0)
            .. "/shapeRepair=" .. tostring(persistenceStats.integritySerializerRepairLoads or 0)
            .. "/shapeRepairFail=" .. tostring(persistenceStats.integritySerializerRepairFailures or 0)
            .. "/shapeResave=" .. tostring(persistenceStats.integritySerializerRepairResaves or 0)
            .. "/v3Upgrade=" .. tostring(persistenceStats.integrityUpgradeRecoveries or 0)
            .. "/" .. tostring(persistenceStats.integrityUpgradeResaves or 0)
            .. "/v3UpgradeFail=" .. tostring(persistenceStats.integrityUpgradeValidationFailures or 0)
            .. "/barrierFail=" .. tostring(persistenceStats.barrierVerifyFailures or 0)
            .. "/clearVerifyFail=" .. tostring(persistenceStats.clearVerifyFailures or 0)
            .. "/encodedLoadReject=" .. tostring(persistenceStats.encodedLoadRejects or 0)
            .. "/envelopeFail=" .. tostring(persistenceStats.envelopeIntegrityLoadFailures or 0)
            .. "/decodedReject=" .. tostring(persistenceStats.decodedLoadRejects or 0)
            .. "/durableFail=" .. tostring(persistenceStats.durableVerifyFailures or 0)
            .. "/scopeMismatch=" .. tostring(persistenceStats.scopeBindingMismatches or 0)
            .. "/retry=" .. tostring(persistenceStats.retryQueued or 0))

    local lastFlush = persistence and persistence.lastFlush or nil
    AddCheck(report, "persistence_runtime_acceptance_diagnostics",
        persistence ~= nil
            and (tonumber(persistence.runtimeAcceptanceDiagnosticsContractVersion) or 0) >= 1
            and type(lastFlush) == "table" and type(lastFlush.failures) == "table",
        "blocker", persistence and ("contract=" .. tostring(persistence.runtimeAcceptanceDiagnosticsContractVersion or 0)
            .. "/lastOk=" .. tostring(lastFlush and lastFlush.ok)
            .. "/failures=" .. tostring(lastFlush and #(lastFlush.failures or {}) or 0)) or "missing")

    AddCheck(report, "persistence_runtime_acceptance_snapshot",
        persistence ~= nil
            and (tonumber(persistence.runtimeAcceptanceSnapshotContractVersion) or 0) >= 2
            and S.Persistence ~= nil
            and type(S.Persistence.FingerprintPayload) == "function"
            and type(S.Persistence.FingerprintDurablePayload) == "function"
            and type(S.Persistence.BuildRuntimeAcceptanceSnapshot) == "function",
        "blocker", persistence and ("contract=" .. tostring(persistence.runtimeAcceptanceSnapshotContractVersion or 0)
            .. "/fingerprint=" .. tostring(type(S.Persistence and S.Persistence.FingerprintPayload) == "function")
            .. "/snapshot=" .. tostring(type(S.Persistence and S.Persistence.BuildRuntimeAcceptanceSnapshot) == "function")) or "missing")

    if v3HostRegistered then
        AddCheck(report, "persistence_v3_store",
            persistence ~= nil and (tonumber(persistence.contractV3) or 0) >= 1,
            "blocker", "registered=" .. tostring(persistence and persistence.contractV3 or 0))
    end

    local invalidBoundaries = {}
    local allowedBoundary = { service_only = true, event_host_only = true }
    for name, service in pairs(S.Services or {}) do
        if type(service) == "table" then
            local boundary = tostring(service.presentationBoundary or "missing")
            if allowedBoundary[boundary] ~= true then invalidBoundaries[#invalidBoundaries+1] = tostring(name) .. ":" .. boundary end
        end
    end
    if type(S.TargetService) == "table" then
        local boundary = tostring(S.TargetService.presentationBoundary or "missing")
        if allowedBoundary[boundary] ~= true then invalidBoundaries[#invalidBoundaries+1] = "TargetService:" .. boundary end
    end
    table.sort(invalidBoundaries)
    AddCheck(report, "service_presentation_boundary", #invalidBoundaries == 0, "blocker",
        #invalidBoundaries == 0 and "all services explicitly presentation-free" or ("invalid=" .. Join(invalidBoundaries, 8)))
    report.legacyPresentationDebt = invalidBoundaries

    local acceptance = S.UIV3Acceptance or S.UIAcceptance
    if acceptance ~= nil then
        local matrix = type(acceptance.RunMatrix) == "function" and acceptance:RunMatrix() or nil
        local text = type(acceptance.RunTextStress) == "function" and acceptance:RunTextStress() or nil
        local live = type(acceptance.InspectLive) == "function" and acceptance:InspectLive() or nil
        local coreOk = matrix ~= nil and matrix.ok == true and text ~= nil and text.ok == true
        local matrixDetail = matrix and type(matrix.details) == "table" and Join(matrix.details, 5) or ""
        AddCheck(report, "ui_foundation_matrix", coreOk, "blocker",
            "matrix=" .. tostring(matrix and matrix.failures or "?") .. "/text=" .. tostring(text and text.failures or "?")
                .. (matrixDetail ~= "" and ("/first=" .. matrixDetail) or ""))
        if live ~= nil then
            local liveOk = (tonumber(live.hardIssues) or 0) == 0
                and (tonumber(live.staleLayoutRoots) or 0) == 0
                and (tonumber(live.unscheduledLayoutRoots) or 0) == 0
            AddCheck(report, "v3_live_ui", liveOk, "warning",
                "hard=" .. tostring(live.hardIssues or 0)
                    .. "/pending=" .. tostring(live.pendingLayoutRoots or 0)
                    .. "/fresh=" .. tostring(live.freshLayoutRoots or 0)
                    .. "/stale=" .. tostring(live.staleLayoutRoots or 0)
                    .. "/unscheduled=" .. tostring(live.unscheduledLayoutRoots or 0)
                    .. "/oldestMs=" .. tostring(live.oldestLayoutAgeMs or 0)
                    .. "/repairs=" .. tostring(live.cacheRepairs or 0))
        end
    else
        AddCheck(report, "ui_foundation_matrix", false, "blocker", "acceptance unavailable")
    end

    local truthExpected = {
        combat_boss_alerts = "migrated_partial", combat_buff_cap = "migrated_partial", combat_team_tools = "migrated_partial",
        combat_unit_lines = "migrated_partial", combat_range_assist = "migrated_partial",
        combat_raid_recruitment = "migrated_partial", life_trade = "migrated_partial", life_fishing = "migrated_partial",
        -- life_craft_planner 已移除，不再将缺失视为阻断。
        tools_bag = "migrated_partial", tools_auction = "migrated_m1", tools_market_analysis = "migrated_partial", tools_craft = "migrated_partial",
    }
    local truthFailures = {}
    for id, expected in pairs(truthExpected) do
        local row = S.FeatureRegistry and S.FeatureRegistry:Get(id) or nil
        if row == nil or tostring(row.status or "") ~= expected then truthFailures[#truthFailures + 1] = id .. ":" .. tostring(row and row.status or "missing") end
    end
    -- Auto-R 事务由 fishing acceptance 检查，强化 slot-probe 阻断由 reinforce_analysis acceptance 检查。
    -- 这里只验声明，不执行 Native 热键读写；sequence 失败仍阻断，Registry 检查独立保留。
    table.sort(truthFailures)
    AddCheck(report, "v3_feature_truth_contract", #truthFailures == 0, "blocker", #truthFailures == 0 and "partial capabilities labeled honestly; risky Native transactions fail closed" or ("invalid=" .. Join(truthFailures, 8)))

    local apiCooldownOk = type(S.Api) == "table" and (tonumber(S.Api.CapabilityCooldownContractVersion) or 0) >= 1
        and type(S.Api.ConsumeCapabilityCooldown) == "function" and type(S.Api.GetCapabilityCooldownState) == "function"
    AddCheck(report, "api_capability_cooldown_contract", apiCooldownOk, "blocker",
        apiCooldownOk and "registered capability cooldowns enforced centrally" or "central capability cooldown fence unavailable")

    -- 目标探测、Buff 上限、寻宝和钓鱼由各自 acceptance 检查观察契约。
    -- 须覆盖版本、topic、Demand 及 Acquire/Release；缺实现或 sequence 失败不能静默通过。

    local usabilityFailures = {}
    local screenProjection = S.Services and S.Services.ScreenProjectionV3 or nil
    local alerts = S.Services and S.Services.Alerts or nil
    local alertHud = S.UIV3 and S.UIV3.AlertHudV3 or nil
    local visualGuides = S.UIV3 and S.UIV3.CombatVisualGuidesV3 or nil
    local lifeWidgets = S.UIV3 and S.UIV3.LifeEconomyWidgetsV3 or nil
    local widgetHost = S.UIV3 and S.UIV3.WidgetHost or nil
    -- 首领、连线、范围和 Buff 显示由各自 acceptance 检查；此处只验共享 Service/UIV3。
    -- Foundation 不读 target；UnitDistance 样本由 RangeAssist 在持有 Demand 时采集。
    if type(screenProjection) ~= "table" or (tonumber(screenProjection.version) or 0) < 15 or tostring(screenProjection.presentationBoundary or "") ~= "service_only"
        or type(screenProjection.ProjectUnitFlexible) ~= "function" or type(screenProjection.ProjectUnitBatch) ~= "function"
        or (tonumber(screenProjection.FrontHemisphereBatchContractVersion) or 0) < 1
        or (tonumber(screenProjection.UnitProjectionConsistencyContractVersion) or 0) < 1
        or (tonumber(screenProjection.UnitWorldAliasGuardContractVersion) or 0) < 1
        or (tonumber(screenProjection.WorldBatchIndexContractVersion) or 0) < 1
        or (tonumber(screenProjection.WorldBatchFactsContractVersion) or 0) < 2
        or (tonumber(screenProjection.WorldBatchAnchorCalibrationContractVersion) or 0) < 2
        or (tonumber(screenProjection.RangeMetricCalibrationContractVersion) or 0) < 1
        or (tonumber(screenProjection.RangeMetricScreenScaleContractVersion) or 0) < 1
        or (tonumber(screenProjection.RangeMetricWorldUnitContractVersion) or 0) < 1
        or (tonumber(screenProjection.RangeMetricScreenScaleApplyContractVersion) or 0) < 1
        or (tonumber(screenProjection.RangeAspectSafeCameraContractVersion) or 0) < 1
        or type(screenProjection.GetRangeMetricCalibration) ~= "function"
        or (tonumber(screenProjection.CameraUnavailableNativeFallbackContractVersion) or 0) < 1
        or (tonumber(screenProjection.UiParentScreenCoordinateContractVersion) or 0) < 1
        or type(screenProjection.ProjectWorld) ~= "function" or type(screenProjection.ProjectWorldBatch) ~= "function" then usabilityFailures[#usabilityFailures + 1] = "screen_projection" end
    if type(alerts) ~= "table" or type(alerts.Push) ~= "function" or type(alertHud) ~= "table" or (tonumber(alertHud.version) or 0) < 1
        or type(S.Services and S.Services.CastingObservationV3) ~= "table" then usabilityFailures[#usabilityFailures + 1] = "boss_hud" end
    if type(visualGuides) ~= "table" or (tonumber(visualGuides.version) or 0) < 15
        or (tonumber(visualGuides.UiEnvironmentStyleRecoveryContractVersion) or 0) < 1
        or (tonumber(visualGuides.ManualPointTypographyContractVersion) or 0) < 1
        -- 点字体由 Presenter 管理，Layout 提供 UI 环境 revision，Theme 保留手动字号。
        -- 任一契约缺失时阻断，防止切画质后点静默缩小。
        or type(S.Layout) ~= "table" or (tonumber(S.Layout.UiEnvironmentRevisionContractVersion) or 0) < 1
        or type(S.Layout.GetUiEnvironmentRevision) ~= "function"
        or type(S.Theme) ~= "table" or (tonumber(S.Theme.ManualTypographyOwnershipContractVersion) or 0) < 1
        or (tonumber(visualGuides.AdaptiveUnitLineSamplingContractVersion) or 0) < 2
        or (tonumber(visualGuides.UnitLineVisibleSegmentClippingContractVersion) or 0) < 1
        or (tonumber(visualGuides.UnitLinePressureBudgetContractVersion) or 0) < 1
        or (tonumber(visualGuides.UnitLineDiffRenderContractVersion) or 0) < 1
        or (tonumber(visualGuides.UnitLineProgressivePoolContractVersion) or 0) < 1
        or (tonumber(visualGuides.ScreenCoordinateAuthorityContractVersion) or 0) < 1
        or (tonumber(visualGuides.UnitLineRawProjectedAnchorContractVersion) or 0) < 2
        or (tonumber(visualGuides.ScreenToOverlayHostContractVersion) or 0) < 1
        or (tonumber(visualGuides.ResolutionIndependentOverlayContractVersion) or 0) < 1
        -- VisualGuide 需 world-HUD game-layer 宿主，避免点覆盖原生窗口。这里只读版本，不创建窗口或调用 Native。
        or (tonumber(S.UI and S.UI.WorldHudNativeLayerContractVersion) or 0) < 1
        or type(visualGuides.BuildUnitLineSamplePlan) ~= "function" then usabilityFailures[#usabilityFailures + 1] = "visual_guides" end
    local tradeWidget = type(widgetHost) == "table" and type(widgetHost.GetSpec) == "function" and widgetHost:GetSpec("life.trade") or nil
    local bondsWidget = type(widgetHost) == "table" and type(widgetHost.GetSpec) == "function" and widgetHost:GetSpec("life.bonds") or nil
    -- Bonds 的多大陆与浮窗菜单版本需匹配；这里只验声明，不读 ResidentBoard/背包。
    -- Feature 检查由 features/life/bonds/rs_bonds_acceptance.lua 负责，sequence 失败同样阻断。
    if type(lifeWidgets) ~= "table" or (tonumber(lifeWidgets.version) or 0) < 9
        or (tonumber(lifeWidgets.bondsMultiContinentContractVersion) or 0) < 3
        or (tonumber(lifeWidgets.bondsDropdownControlsContractVersion) or 0) < 3
        or (tonumber(lifeWidgets.bondsFloatingSettingsMenuContractVersion) or 0) < 1
        or (tonumber(lifeWidgets.bondsResidentBoardFamilyContractVersion) or 0) < 1
        or type(tradeWidget) ~= "table" or type(bondsWidget) ~= "table" then
        usabilityFailures[#usabilityFailures + 1] = "life_widgets"
    end
    -- Trade 的业务版本和命令由 features/life/trade/rs_trade_acceptance.lua 检查；共享报价与 UI 契约仍在此检查。
    local tradePayout = S.Services and S.Services.TradePayoutV3 or nil
    local tradeDetail = S.UIV3 and S.UIV3.TradeDetailFloatingV3 or nil
    local tradeDetailOk = type(tradePayout) == "table" and (tonumber(tradePayout.PriceFormulaContractVersion) or 0) >= 3
        and type(tradePayout) == "table" and (tonumber(tradePayout.PriceFormulaContractVersion) or 0) >= 3
        and (tonumber(tradePayout.StaticPriceKeyResolverContractVersion) or 0) >= 2
        and (tonumber(tradePayout.CommerceMultiplierContractVersion) or 0) >= 1
        and (tonumber(tradePayout.PackCategoryMultiplierContractVersion) or 0) >= 3
        -- 多个 RowJob 可并存，但 PriceQuoteQueueV3 仍须串行访问 Native，并按 itemType+grade 去重。
        -- 版本不匹配时先阻断，避免连续查询两个货物时取消上一任务或重复查价。
        and type(S.Services and S.Services.MaterialPriceServiceV3) == "table"
        and (tonumber(S.Services.MaterialPriceServiceV3.ContractVersion) or 0) >= 1
        and (tonumber(S.Services.MaterialPriceServiceV3.FreshnessContractVersion) or 0) >= 1
        and (tonumber(S.Services.MaterialPriceServiceV3.BackgroundRevalidateContractVersion) or 0) >= 1
        and (tonumber(S.Services.MaterialPriceServiceV3.AnomalyGuardContractVersion) or 0) >= 1
        and type(S.Services and S.Services.PriceQuoteQueueV3) == "table"
        and (tonumber(S.Services.PriceQuoteQueueV3.RequestIdentityDedupContractVersion) or 0) >= 1
        and (tonumber(S.Services.PriceQuoteQueueV3.EventPayloadContractVersion) or 0) >= 1
        and (tonumber(S.Services.PriceQuoteQueueV3.MaterialPriceAuthorityContractVersion) or 0) >= 1
        and (tonumber(S.Services.PriceQuoteQueueV3.PriorityQueueContractVersion) or 0) >= 1
        and type(S.UIV3 and S.UIV3.LifeM16PagesContract) == "table"
        and (tonumber(S.UIV3.LifeM16PagesContract.tradeMultiQuoteUiContractVersion) or 0) >= 1
        and type(tradeDetail) == "table" and (tonumber(tradeDetail.TradeDetailContractVersion) or 0) >= 2
        and type(tradeDetail.Open) == "function" and type(tradeDetail.Close) == "function"
    AddCheck(report, "v3_trade_detail_favorites_contract", tradeDetailOk, "blocker",
        tradeDetailOk and "TradePayoutV3 + durable material-price SWR + economics revisions + multi-row quote jobs present" or "trade payout/material-price/economics/multi-row quote contract unavailable")
    -- Buff 显示的健康与观察契约由 features/combat/buff_display/rs_buff_display_acceptance.lua 检查。
    local healerFloatingSpec = type(widgetHost) == "table" and type(widgetHost.GetSpec) == "function" and widgetHost:GetSpec("combat.healer") or nil
    if healerFloatingSpec ~= nil then usabilityFailures[#usabilityFailures + 1] = "healer_recommendation_widget" end
    AddCheck(report, "v3_combat_life_usability_contract", #usabilityFailures == 0, "blocker",
        #usabilityFailures == 0 and "screen HUD/visual guides/life widgets/status observation contracts present" or ("missing=" .. Join(usabilityFailures, 8)))

    local bagContractOk, bagContractDetail = self:EvaluateBagActionContract()
    AddCheck(report, "v3_bag_action_contract", bagContractOk, "blocker", bagContractDetail)
    -- Gear 快速启动意图由 features/combat/gear/rs_gear_acceptance.lua 检查；此处只验 FeatureRuntime 公共接口。
    local startupIntentOk = type(S.FeatureRuntime) == "table" and (tonumber(S.FeatureRuntime.StartupEnableIntentContractVersion) or 0) >= 1
    AddCheck(report, "v3_quick_surface_reload_reconcile_contract", startupIntentOk, "blocker",
        startupIntentOk and "Gear legacy quick intent is one-time repaired and persistent quick visibility remains preference-authoritative"
            or "quick-surface reload reconcile contract unavailable")

    local auctionQuery = S.Services and S.Services.AuctionQueryV3 or nil
    -- 拍卖和市场分析的实现由各自 acceptance 检查；此处只验 AuctionQueryV3。
    local auctionQueryOk = type(auctionQuery) == "table" and (tonumber(auctionQuery.version) or 0) >= 2
        and (tonumber(auctionQuery.EventAuthorityContractVersion) or 0) >= 1
        and tostring(auctionQuery.presentationBoundary or "") == "service_only" and type(auctionQuery.Search) == "function" and type(auctionQuery.GetSnapshot) == "function"
    AddCheck(report, "v3_auction_query_contract", auctionQueryOk, "blocker",
        auctionQueryOk and "single event Authority + timeout-fenced explicit current-listing query" or "auction query contract v2 unavailable")

    local auctionSurface = S.Services and S.Services.AuctionSurfaceV3 or nil
    local auctionSidecar = S.UIV3 and S.UIV3.AuctionSidecar or nil
    local auctionSidecarOk = type(auctionSurface) == "table" and (tonumber(auctionSurface.version) or 0) >= 2
        and (tonumber(auctionSurface.VisibilityContractVersion) or 0) >= 2
        and type(auctionSurface.GetSnapshot) == "function" and type(auctionSurface.Start) == "function" and type(auctionSurface.Stop) == "function"
        and type(auctionSidecar) == "table" and (tonumber(auctionSidecar.SidecarControlContractVersion) or 0) >= 2
        and type(auctionSidecar.GetControlState) == "function" and type(auctionSidecar.RequestShow) == "function"
    AddCheck(report, "v3_auction_sidecar_contract", auctionSidecarOk, "blocker",
        auctionSidecarOk and "native-auction observer + persistent user-controlled sidecar lifecycle present" or "auction sidecar control contract unavailable")

    -- Sidecar 收藏由 tools_auction 保存，今日任务只读 QuestProgress/配方，临时清单不存档。这里只验接口，不要求玩家当天有任务。
    -- Native 搜索框同步失败仅报 warning：仍可经 AuctionQueryV3 查询，不能因 RU EditBox 差异阻断启动。
    local auctionSession = S.Services and S.Services.AuctionSessionListV3 or nil
    local auctionDaily = S.Services and S.Services.DailyAuctionMaterialsV3 or nil
    local questProgress = S.Services and S.Services.QuestProgressV3 or nil
    local auctionWorkspaceOk = type(auctionSidecar) == "table" and (tonumber(auctionSidecar.AuctionWorkspaceContractVersion) or 0) >= 1
        and type(auctionSession) == "table" and (tonumber(auctionSession.SessionListContractVersion) or 0) >= 1
        and auctionSession.PersistenceStoreId == nil and type(auctionSession.AddTradeRow) == "function" and type(auctionSession.AddMaterial) == "function"
        and type(auctionDaily) == "table" and (tonumber(auctionDaily.DailyMaterialContractVersion) or 0) >= 2
        and type(auctionDaily.AcquireConsumer) == "function" and type(auctionDaily.ReleaseConsumer) == "function"
        and type(auctionDaily.SelectRecipe) == "function" and type(auctionDaily.GetSnapshot) == "function"
        and type(questProgress) == "table" and type(questProgress.GetActiveQuestStates) == "function" and type(questProgress.GetActiveQuestList) == "function"
    AddCheck(report, "v3_auction_workspace_contract", auctionWorkspaceOk, "blocker",
        auctionWorkspaceOk and "favorites CRUD + demand-scoped daily materials + session-only temporary groups + three-tab sidecar present"
            or "auction workspace contract v2 unavailable")

    local auctionSearchBridge = S.Services and S.Services.AuctionSearchBridgeV3 or nil
    local nativeSyncEnhancementOk = type(auctionSearchBridge) == "table" and (tonumber(auctionSearchBridge.SearchBridgeContractVersion) or 0) >= 1
        and (tonumber(auctionSearchBridge.NativeSyncContractVersion) or 0) >= 1 and type(auctionSearchBridge.Search) == "function"
        and type(auctionSearchBridge.GetSnapshot) == "function"
    AddCheck(report, "v3_auction_native_search_sync_enhancement", nativeSyncEnhancementOk, "warning",
        nativeSyncEnhancementOk and "verified native EditBox sync bridge present; runtime candidate failure safely falls back to AuctionQueryV3"
            or "native search-box synchronization enhancement unavailable; direct AuctionQueryV3 remains authoritative")

    -- 只检查现有 tools_craft；保留已移除的 craft_plan 空壳会永久阻断并迫使注册无用 Store。
    -- 业务契约由 features/tools/craft/rs_craft_acceptance.lua 检查。

    local craftSurface = S.Services and S.Services.CraftSurfaceV3 or nil
    local craftSidecar = S.UIV3 and S.UIV3.CraftSidecar or nil
    -- 制作侧车由 craft acceptance 检查；此处只验 Service/UIV3。
    local craftSidecarOk = type(craftSurface) == "table" and (tonumber(craftSurface.version) or 0) >= 1
        and (tonumber(craftSurface.VisibilityContractVersion) or 0) >= 1
        and type(craftSurface.GetSnapshot) == "function" and type(craftSurface.Start) == "function" and type(craftSurface.Stop) == "function"
        and type(craftSidecar) == "table"
    AddCheck(report, "v3_craft_sidecar_contract", craftSidecarOk, "blocker",
        craftSidecarOk and "bounded native-craft observer + shared-authority sidecar present" or "craft sidecar contract unavailable")

    -- 团队版本和命令由 team_tools acceptance 检查；此处只验团队边沿、静态职责目录和叠层 UI。
    local teamRoster = S.Services and S.Services.TeamRosterV3 or nil
    local teamRoleCatalog = S.Data and S.Data.TeamAutoRoleCatalog or nil
    local archerRole = type(teamRoleCatalog) == "table" and type(teamRoleCatalog.byClassKey) == "table"
        and teamRoleCatalog.byClassKey["name_6_8_9"] or nil
    local dancerHealerRole = type(teamRoleCatalog) == "table" and type(teamRoleCatalog.byClassKey) == "table"
        and teamRoleCatalog.byClassKey["name_8_9_14"] or nil
    -- 只验两个已确认职业组合、TeamRoster 租约和团队边沿声明，不扫描名单或调用 X2Team 写接口。
    -- 页面关闭后的入团监听仍须随服务生命周期释放。
    local teamRoleOk = type(teamRoster) == "table" and (tonumber(teamRoster.TeamEdgeSettleContractVersion) or 0) >= 1
        and type(teamRoleCatalog) == "table" and (tonumber(teamRoleCatalog.version) or 0) >= 3
        and type(archerRole) == "table" and tostring(archerRole.role or "") == "ranged"
        and type(dancerHealerRole) == "table" and tostring(dancerHealerRole.role or "") == "healer"
    AddCheck(report, "v3_team_role_contract", teamRoleOk, "blocker",
        teamRoleOk and "independent roster lease + bounded team-edge settle + ranged/healer exact class-role semantics present" or "team role/catalog lifecycle contract unavailable")

    local teamSacOverlay = S.UIV3 and S.UIV3.TeamSacOverlay or nil
    -- 默认开启和业务命令由 team_tools acceptance 检查；此处只验 UIV3。
    local teamVisualOk = type(teamSacOverlay) == "table" and (tonumber(teamSacOverlay.TeamSacPresentationContractVersion) or 0) >= 1
    AddCheck(report, "v3_team_visual_marker_contract", teamVisualOk, "blocker",
        teamVisualOk and "bounded Sac overlay + persistent marker snapshot/verified serial restore present" or "team visual/marker contract unavailable")

    -- 活动业务存档由 activities acceptance 检查；此处仍须验证注册 Store 的 schema、恢复 hook 和完整性升级许可。
    -- 只读 spec，确认 exact-pair 桥已挂接，不触发 LoadData。
    local activityStore = S.Persistence ~= nil and type(S.Persistence.GetStore) == "function" and S.Persistence:GetStore("v3.activities") or nil
    local activityRecoveryOk = type(activityStore) == "table" and tonumber(activityStore.schemaVersion) == 8
        and type(activityStore.recoverKnownLegacyCanonical) == "function" and activityStore.allowIntegrityUpgrade == true -- 恢复须同时通过 Store hook 和 Core 精确指纹验证，Feature/UI 不能直接放行。
    AddCheck(report, "v3_activity_persistence_recovery_contract", activityRecoveryOk, "blocker",
        activityRecoveryOk and "schema8 exact canonical/Transport-v1 incident recovery + Transport v2 rewrite present" or "activity persistence recovery contract unavailable")

    -- 活动和任务的存档 case 须显式声明只读运行资格，否则玩家诊断会跳过。

    AddCheck(report, "diagnostics", S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Snapshot) == "function", "blocker", "structured diagnostics")

    local sequenceAuthorityBefore = ui and type(ui.GetAuthoritySnapshot) == "function" and ui:GetAuthoritySnapshot() or nil
    local sequenceRegistryBefore = ui and type(ui.GetRegistrySnapshot) == "function" and ui:GetRegistrySnapshot() or nil
    -- 同一次只读报告包含业务门禁，不能用“序列未执行”代替“业务已通过”。
    self:RunRuntimeContracts(report)
    local sequences
    local registeredSequenceCount = #(self.sequenceOrder or {})
    if options.skipSequences == true then
        sequences = { total = registeredSequenceCount, passed = 0, failed = 0, failures = {}, skipped = true, registered = registeredSequenceCount }
    else
        sequences = self:RunSequences()
        sequences.registered = registeredSequenceCount
        self.lastSequences = sequences
    end
    report.sequences = sequences
    local sequenceAuthorityAfter = ui and type(ui.GetAuthoritySnapshot) == "function" and ui:GetAuthoritySnapshot() or nil
    local sequenceRegistryAfter = ui and type(ui.GetRegistrySnapshot) == "function" and ui:GetRegistrySnapshot() or nil
    if v3HostRegistered then
        AddCheck(report, "sequence_authority_clean",
            sequenceAuthorityBefore ~= nil and sequenceAuthorityAfter ~= nil
                and (tonumber(sequenceAuthorityAfter.violations) or 0) == (tonumber(sequenceAuthorityBefore.violations) or 0)
                and (tonumber(sequenceAuthorityAfter.conflicts) or 0) == (tonumber(sequenceAuthorityBefore.conflicts) or 0)
                and sequenceRegistryBefore ~= nil and sequenceRegistryAfter ~= nil
                and (tonumber(sequenceRegistryAfter.v3Duplicates) or 0) == (tonumber(sequenceRegistryBefore.v3Duplicates) or 0),
            "blocker", "viol+=" .. tostring((tonumber(sequenceAuthorityAfter and sequenceAuthorityAfter.violations) or 0) - (tonumber(sequenceAuthorityBefore and sequenceAuthorityBefore.violations) or 0))
                .. "/conflict+=" .. tostring((tonumber(sequenceAuthorityAfter and sequenceAuthorityAfter.conflicts) or 0) - (tonumber(sequenceAuthorityBefore and sequenceAuthorityBefore.conflicts) or 0))
                .. "/iddup+=" .. tostring((tonumber(sequenceRegistryAfter and sequenceRegistryAfter.v3Duplicates) or 0) - (tonumber(sequenceRegistryBefore and sequenceRegistryBefore.v3Duplicates) or 0)))
    end
    if sequences.failed > 0 then
        AddCheck(report, "sequence_harness", false, "blocker",
            "cases=" .. tostring(sequences.total) .. "/pass=" .. tostring(sequences.passed) .. "/fail=" .. tostring(sequences.failed))
    elseif v3HostRegistered and registeredSequenceCount == 0 then
        AddCheck(report, "sequence_harness", false, "blocker", "v3 host registered but no sequence cases")
    elseif registeredSequenceCount == 0 then
        AddCheck(report, "sequence_harness", false, "warning", "waiting_for_v3_host")
    elseif sequences.skipped == true then
        AddCheck(report, "sequence_harness", true, "blocker",
            "registered=" .. tostring(registeredSequenceCount) .. "/live_run=disabled")
    else
        AddCheck(report, "sequence_harness", true, "blocker",
            "cases=" .. tostring(sequences.total) .. "/pass=" .. tostring(sequences.passed) .. "/fail=0")
    end

    report.status = report.blockers == 0 and "READY" or "BLOCKED"
    self.last = report
    return report
end

function G:GetLastSummary()
    local r = self.last
    if type(r) ~= "table" then return "未运行" end
    return (tostring(r.status) == "READY" and "正常" or "阻断") .. " · 阻断 " .. tostring(r.blockers or 0) .. " · 警告 " .. tostring(r.warnings or 0)
end

function G:BuildCopyText(runNow)
    local r = runNow ~= false and self:Run({ skipSequences = true }) or self.last
    if type(r) ~= "table" then return "新版基础框架｜未运行" end
    local statusText = tostring(r.status) == "READY" and "正常" or "阻断"
    -- BuildTag 随诊断横幅输出；每条复制内容须标识产生它的构建，避免将不同客户端版本误作同一修复结果。
    local parts = { "新版基础框架｜" .. statusText .. " · 阻断 " .. tostring(r.blockers) .. " · 警告 " .. tostring(r.warnings)
        .. " · " .. tostring(S.BuildTag or "BuildTag未知") }
    local failed = {}
    for _, row in ipairs(r.checks or {}) do
        if not row.ok then failed[#failed+1] = row.id .. "[" .. row.detail .. "]" end
    end
    if #failed > 0 then parts[#parts+1] = "未通过：" .. Join(failed, 8) end
    local static = S.StaticDataV2 and S.StaticDataV2:Describe() or nil
    local persistence = S.Persistence and S.Persistence:Describe() or nil
    local authority = S.UI and type(S.UI.GetAuthoritySnapshot)=="function" and S.UI:GetAuthoritySnapshot() or nil
    local uiRegistry = S.UI and type(S.UI.GetRegistrySnapshot)=="function" and S.UI:GetRegistrySnapshot() or nil
    local trade = r.tradeStatic or (S.Data and S.Data.TradeStaticV2 and type(S.Data.TradeStaticV2.Describe)=="function" and S.Data.TradeStaticV2:Describe() or nil)
    local gameData = S.GameDataRegistry and type(S.GameDataRegistry.Validate)=="function" and S.GameDataRegistry:Validate() or nil
    local host = S.UIHostManager and type(S.UIHostManager.Describe)=="function" and S.UIHostManager:Describe() or nil
    parts[#parts+1] = "界面宿主 " .. tostring(host and host.activeId == "v3" and "新版" or host and host.activeId or "?") .. "/契约 " .. tostring(host and host.contractV2 or 0) .. "/导航 " .. tostring(host and host.navigationReady or 0)
    local runtimeInfo = S.Runtime and type(S.Runtime.Describe)=="function" and S.Runtime:Describe() or nil
    parts[#parts+1] = "入口 Ready" .. tostring(S.Ready == true)
        .. "/Runtime" .. tostring(runtimeInfo and runtimeInfo.started == true)
        .. "/R" .. tostring(S.RecoveryEntryHealthy == true)
        .. "/CMD" .. tostring(S.RecoveryCommandHealthy == true)
        .. "/ESC" .. tostring(runtimeInfo and runtimeInfo.escRegistered == true)
        .. "/尝试" .. tostring(runtimeInfo and runtimeInfo.escRegistrationAttempts or 0)
        .. "/重试" .. tostring(runtimeInfo and runtimeInfo.escRetryScheduled == true)
        .. "/降级" .. tostring(runtimeInfo and runtimeInfo.startupWarningCount or 0)
    local native = S.NativeCapabilities and type(S.NativeCapabilities.Describe)=="function" and S.NativeCapabilities:Describe() or nil
    local nativeImports = native and native.imports or nil
    parts[#parts+1] = "原生层 " .. tostring(native and native.owner or "?")
        .. "/外部 " .. tostring(native and native.externalGlobalsConsumed or "?")
        .. "/旧助手 " .. tostring(native and native.legacyUiHelpersConsumed or "?")
        .. "/接口 " .. tostring(nativeImports and nativeImports.total or 0)
        .. "/对象 " .. tostring(nativeImports and nativeImports.objects or 0)
    local zones = S.StaticDataV2 and S.StaticDataV2:GetCatalog("zone") or nil
    parts[#parts+1] = "IDs " .. tostring(gameData and gameData.totalRecords or 0) .. "/Zone " .. tostring(zones and #(zones.order or {}) or 0) .. "/封存" .. tostring(gameData and gameData.sealed == true) .. "/违规" .. tostring(gameData and gameData.sealViolations or 0)
    parts[#parts+1] = "Data " .. tostring(static and static.records or 0) .. "条/缺引用" .. tostring(static and static.missingRefs or 0) .. "/缺ID" .. tostring(static and static.missingRequiredIds or 0) .. "/封存" .. tostring(static and static.sealed == true)
    parts[#parts+1] = "跑商 材" .. tostring(trade and trade.materials or 0)
        .. "/货" .. tostring(trade and trade.goods or 0)
        .. "/配" .. tostring(trade and trade.recipes or 0)
        .. "/Craft " .. tostring(trade and trade.primaryCraftIds or 0) .. "/" .. tostring(trade and trade.recipes or 0)
        .. "/引用" .. tostring(trade and trade.totalRecipeCraftIds or 0)
        .. "/配方核验" .. tostring(trade and trade.verifiedIngredientSignatures or 0)
        .. "/失败" .. tostring(trade and trade.ingredientSignatureFailures or 0)
        .. "/地区待核" .. tostring(trade and trade.pendingOriginZones or 0)
        .. "/货物ID" .. tostring(trade and trade.verifiedProductIds or 0) .. "/" .. tostring(trade and trade.goods or 0)
        .. "/待核" .. tostring(trade and trade.pendingProductIds or 0)
        .. "/货物重复" .. tostring(trade and trade.productIdDuplicates or 0)
    local quest = r.questIds or (S.GameIds and S.GameIds.Quest and type(S.GameIds.Quest.Describe)=="function" and S.GameIds.Quest:Describe() or nil)
    parts[#parts+1] = "任务 总" .. tostring(quest and quest.total or 0) .. "/已核" .. tostring(quest and quest.verified or 0) .. "/待核" .. tostring(quest and quest.pending or 0)
    local instance = r.instanceIds or (S.GameIds and S.GameIds.Instance and type(S.GameIds.Instance.Describe)=="function" and S.GameIds.Instance:Describe() or nil)
    parts[#parts+1] = "副本 数据库核验 " .. tostring(instance and instance.databaseVerified or 0)
        .. "/Runtime已核" .. tostring(instance and instance.runtimeVerified or 0)
        .. "/观察" .. tostring(instance and instance.runtimeObserved or 0)
        .. "/冲突" .. tostring(instance and instance.runtimeObservedConflicts or 0)
        .. "/待核" .. tostring(instance and instance.runtimePending or 0)
    parts[#parts+1] = "存档 " .. tostring(persistence and persistence.total or 0) .. "/V2 " .. tostring(persistence and persistence.contractV2 or 0) .. "/V3 " .. tostring(persistence and persistence.contractV3 or 0) .. "/Budget " .. tostring(persistence and persistence.budgetProtected or 0) .. "/Fence " .. tostring(persistence and persistence.fenced or 0) .. "/Dirty " .. tostring(persistence and persistence.dirty or 0) .. "/UnloadedDirty " .. tostring(persistence and persistence.unloadedDirty or 0) .. "/FlushFail " .. tostring(persistence and persistence.stats and persistence.stats.flushFailures or 0)
    local persistenceIncidents, seenPersistenceIncident = {}, {}
    local lastFlush = persistence and persistence.lastFlush or nil
    for _, failure in ipairs(type(lastFlush) == "table" and type(lastFlush.failures) == "table" and lastFlush.failures or {}) do
        local item = tostring(failure):gsub("[\r\n]+", " ")
        if item ~= "" and seenPersistenceIncident[item] ~= true then
            seenPersistenceIncident[item] = true
            persistenceIncidents[#persistenceIncidents + 1] = item
            if #persistenceIncidents >= 3 then break end
        end
    end
    if #persistenceIncidents < 3 then
        for _, row in ipairs(persistence and persistence.rows or {}) do
            if row.writeFenced == true or (tonumber(row.consecutiveSaveFailures) or 0) > 0 then
                local reason = tostring(row.writeFenceReason or row.lastError or "save_failed")
                local item = tostring(row.id or "?") .. ":" .. reason:gsub("[\r\n]+", " ")
                if seenPersistenceIncident[item] ~= true then
                    seenPersistenceIncident[item] = true
                    persistenceIncidents[#persistenceIncidents + 1] = item
                    if #persistenceIncidents >= 3 then break end
                end
            end
        end
    end
    if #persistenceIncidents > 0 then parts[#parts+1] = "存档故障 " .. table.concat(persistenceIncidents, " | ") end
    -- Core 状态机轨迹先于 Store 恢复探针输出，便于摘要被截断时仍能定位失败阶段。
    do
        local traceParts = {}
        for _, row in ipairs(persistence and persistence.rows or {}) do
            if row.writeFenced == true and row.integrityRecoveryTrace ~= nil then
                traceParts[#traceParts + 1] = tostring(row.id or "?") .. ":" .. tostring(row.integrityRecoveryTrace):gsub("[\r\n]+", " ")
                if #traceParts >= 3 then break end
            end
        end
        if #traceParts > 0 then parts[#parts+1] = "完整性轨迹 " .. table.concat(traceParts, " | ") end
    end
    -- 恢复探针单独成行，避免挂在长行尾部被 UI 截断。
    -- 只输出写保护 Store 的字段名、候选数和版本元数据。
    do
        local probeParts, seenProbe = {}, {}
        for _, row in ipairs(persistence and persistence.rows or {}) do
            -- 读取 Describe 的 historicalRecoveryProbe；Store 内部名 lastHistoricalRecoveryProbe 在此无效。
            if row.writeFenced == true and row.historicalRecoveryProbe ~= nil then
                local item = tostring(row.id or "?") .. ":" .. tostring(row.historicalRecoveryProbe):gsub("[\r\n]+", " ")
                if seenProbe[item] ~= true then
                    seenProbe[item] = true
                    probeParts[#probeParts + 1] = item
                    if #probeParts >= 3 then break end -- 与存档故障行同口径，最多 3 条，防止损坏档在摘要里刷屏。
                end
            end
        end
        if #probeParts > 0 then parts[#parts+1] = "恢复探针 " .. table.concat(probeParts, " | ") end
    end
    -- 汇总功能诊断的非 OK 项，含 Store 写保护行；最多取前三条，并带出原因。
    do
        local diag = S.DiagnosticsManager
        local featureRows = diag ~= nil and type(diag.BuildFeatureStatusRows) == "function" and diag:BuildFeatureStatusRows() or nil
        local badParts, seenBad = {}, {}
        for _, featureRow in ipairs(featureRows or {}) do
            if featureRow.verdict == "down" or featureRow.verdict == "degraded" then
                local item = (featureRow.verdict == "down" and "✗" or "△") .. tostring(featureRow.label)
                    .. " " .. tostring(featureRow.text):gsub("[\r\n]+", " ")
                if seenBad[item] ~= true then
                    seenBad[item] = true
                    badParts[#badParts + 1] = item
                    if #badParts >= 3 then break end
                end
            end
        end
        if #badParts > 0 then parts[#parts+1] = "功能诊断 " .. table.concat(badParts, " | ") end
    end
    parts[#parts+1] = "界面所有权 违规 " .. tostring(authority and authority.violations or 0) .. "/冲突 " .. tostring(authority and authority.conflicts or 0) .. "/编号重复 " .. tostring(uiRegistry and uiRegistry.v3Duplicates or 0)
    local pageInfo = S.UIV3 and S.UIV3.PageHost and type(S.UIV3.PageHost.Describe) == "function" and S.UIV3.PageHost:Describe() or nil
    local factoryInfo = S.NativeObjectFactory and type(S.NativeObjectFactory.Describe) == "function" and S.NativeObjectFactory:Describe() or nil
    local rsuiInfo = S.RSUI and type(S.RSUI.GetSnapshot) == "function" and S.RSUI:GetSnapshot() or nil
    parts[#parts+1] = "界面构建 页面失败 " .. tostring(pageInfo and pageInfo.buildFailures or 0)
        .. "/隔离 " .. tostring(pageInfo and pageInfo.quarantined or 0)
        .. "/Native失败 " .. tostring(factoryInfo and factoryInfo.failures or 0)
        .. "/重复拒绝 " .. tostring(factoryInfo and factoryInfo.duplicateRejects or 0)
        .. "/事务回滚 " .. tostring(rsuiInfo and rsuiInfo.buildScopesRolledBack or 0)
        .. "/闭合恢复 " .. tostring(rsuiInfo and rsuiInfo.buildScopeCloseOrderRecoveries or 0)
        .. "/前检拒绝 " .. tostring(rsuiInfo and rsuiInfo.preflightFailures or 0)
        .. "/事务失败 " .. tostring(rsuiInfo and rsuiInfo.buildTransactionFailures or 0)
        .. "/活动事务 " .. tostring(rsuiInfo and rsuiInfo.activeBuildScopes or 0)

    -- 可复制摘要须携带实际运行故障，不能只显示 pageQ=2 等聚合计数；仅附最近四条 warning/error，使单行适合从
    -- ArcheAge 客户端日志复制。
    local diagnostics = S.DiagnosticsManager
    local recentFaults = {}
    if type(diagnostics) == "table" and type(diagnostics.recent) == "table" then
        for index = #diagnostics.recent, 1, -1 do
            local row = diagnostics.recent[index]
            if type(row) == "table" and (row.level == "error" or row.level == "warning") then
                local context = type(row.context) == "table" and row.context or {}
                local detailParts = {}
                if context.store ~= nil then detailParts[#detailParts + 1] = "store=" .. tostring(context.store) end
                if type(context.failures) == "table" and #context.failures > 0 then
                    detailParts[#detailParts + 1] = "fail=" .. Join(context.failures, 2)
                end
                local primaryDetail = context.error or context.reason or context.detail or context.route or context.id
                -- 存档隔离后的完整性分歧报告第一个不同字段；这条可操作的持久化证据必须保留在复制文本中。
                if primaryDetail == nil and context.divergence ~= nil then
                    primaryDetail = "divergence=" .. tostring(context.divergence)
                end
                if primaryDetail ~= nil and tostring(primaryDetail) ~= "" then detailParts[#detailParts + 1] = tostring(primaryDetail) end
                local detail = table.concat(detailParts, ";")
                detail = detail:gsub("[\r\n]+", " ↳ ")
                if #detail > 130 then detail = detail:sub(1, 127) .. "..." end
                local item = tostring(row.code or "FAULT") .. ":" .. tostring(row.message or "")
                if detail ~= "" then item = item .. "[" .. detail .. "]" end
                recentFaults[#recentFaults + 1] = item
                if #recentFaults >= 4 then break end
            end
        end
    end
    if #recentFaults > 0 then parts[#parts+1] = "最近故障 " .. table.concat(recentFaults, " | ") end
    -- 逐功能判定与修复提示随同一复制文本输出；计数变化之外还须说明哪个功能失效以及下一步操作。
    local diagnosticsManager = S.DiagnosticsManager
    if type(diagnosticsManager) == "table" and type(diagnosticsManager.BuildFeatureStatusRows) == "function" then
        local okRows, featureRows = pcall(function() return diagnosticsManager:BuildFeatureStatusRows() end)
        if okRows == true and type(featureRows) == "table" then
            parts[#parts+1] = "功能 " .. (diagnosticsManager:FormatFeatureStatusRows(featureRows))
            parts[#parts+1] = "修复引导 " .. (diagnosticsManager:BuildRepairGuidance(featureRows))
        end
    end
    if r.sequences ~= nil and r.sequences.skipped == true then
        parts[#parts+1] = "序列测试 已登记 " .. tostring(r.sequences.registered or r.sequences.total or 0) .. " · 实机诊断不执行破坏性序列"
    else
        parts[#parts+1] = "序列测试 " .. tostring(r.sequences and r.sequences.passed or 0) .. "/" .. tostring(r.sequences and r.sequences.total or 0)
    end
    if r.sequences ~= nil and tonumber(r.sequences.failed) and r.sequences.failed > 0 then
        parts[#parts+1] = "序列失败 " .. Join(r.sequences.failures or {}, 4)
    end
    -- os.* 是受限全局；允许的时钟使用引擎服务器时间表，以 NowMs 提供日内时间。
    local sampleDate = S.Utils and type(S.Utils.ServerDateKey) == "function" and S.Utils:ServerDateKey() or "unknown"
    local sampleMs = S.NowMs and tonumber(S.NowMs()) or 0
    local sampleSec = math.floor(sampleMs / 1000) % 86400
    local hh, mm, ss = math.floor(sampleSec / 3600), math.floor((sampleSec % 3600) / 60), sampleSec % 60
    parts[#parts+1] = "采样 " .. sampleDate .. " " .. string.format("%02d:%02d:%02d", hh, mm, ss)
    return table.concat(parts, " ║ ")
end

function G:PrintReport()
    local text = self:BuildCopyText(true)
    if type(S.SafeChat) == "function" then S.SafeChat(text, self.last and self.last.status == "READY" and "info" or "warning", "foundation") end
    return text
end
